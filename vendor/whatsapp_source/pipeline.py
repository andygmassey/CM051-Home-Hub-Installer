"""Drive WhatsApp ChatStorage -> CM048 four-artefact bundle on the Hub.

This is the product-path conversation-memory feed for the WHATSAPP leg,
wired by a LaunchAgent tick (mirrors the email-bundle + spoken-bundle +
imessage-bundle ticks; see
``launchd/com.creativemachines.ostler.whatsapp-bundle.plist``). On each
tick it:

  1. Reads the macOS WhatsApp Desktop ChatStorage.sqlite (FDA granted at
     install) for in-tier chats (T1 DM + T2 intimate/active group),
     WITH message bodies. T3 large-passive chats are skipped at read
     time, never read.
  2. Renders each chat into a cleaned speaker-labelled transcript +
     CM048 metadata (``channel="whatsapp"`` plus chat_jid, participants,
     timestamps, the tier label, and any operator contact/group label).
  3. Invokes ``pwg-convo process <transcript> <metadata>`` so CM048
     emits the four artefacts under
     ``~/Documents/Ostler/Conversations/<date>/<slug>-<short-id>/``.

CM048 owns classification, enrichment, the L3 short-circuit, the
WhatsApp privacy ladder, and the four-artefact write. This module only
produces transcript + metadata and hands off. It is intentionally
subprocess-coupled (not an import) so the WhatsApp source and CM048 stay
independently deployable, exactly like the email + spoken feeds. It does
NOT capture or sync anything from Meta; the read is local-file-only
against WhatsApp Desktop's already-synced store.

Privacy: bodies are sensitive, so the tier gate (T3 skip) + the
L1/L2/L3 ladder gate them as strictly as any source. An operator
contacts.yaml can mark a JID's ``contact_label`` (DM) or a chat's
``group_label`` (group) -- a family / partner / sensitive label
escalates the thread to L3 via CM048's ladder, so its bundle lands on
disk but never reaches Qdrant / Oxigraph. An explicit ``privacy_level``
in the same map always wins.

State: a watermark file records, per chat, the last-bundled message
timestamp. A tick only re-dispatches a chat when it carries a message
newer than the watermark (a fresh reply re-bundles the whole chat so
the four-artefact output stays complete).
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable, Optional

from .reader import WhatsAppConversation, read_chats
from .renderer import build_metadata, render_transcript

try:  # progress signal is best-effort; never break a tick on its absence
    from . import hydration_progress as _hp
except Exception:  # pragma: no cover - defensive
    _hp = None

logger = logging.getLogger(__name__)

_PROGRESS_CHANNEL = "whatsapp"


def _emit_progress(summary: dict) -> None:
    """Report this feed's slice of the shared hydration progress signal.

    ``queued`` is everything seen this tick (dispatched + skipped + failed);
    ``done`` is everything not failed. Best-effort; a failure is swallowed.
    """
    if _hp is None:
        return
    try:
        d = int(summary.get("chats_dispatched", 0))
        s = int(summary.get("chats_skipped", 0))
        f = int(summary.get("chats_failed", 0))
        _hp.update_channel(_PROGRESS_CHANNEL, queued=d + s + f, done=d + s)
    except Exception:  # pragma: no cover - defensive
        pass


# Engine-zone state under ~/.ostler/ (two-zone architecture). The
# watermark records the last-bundled message timestamp per chat id.
def _default_state_dir() -> Path:
    override = os.getenv("OSTLER_STATE_DIR") or os.getenv("STATE_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / ".ostler" / "workspace"


def _state_path() -> Path:
    return _default_state_dir() / "whatsapp_source_state.json"


def _load_state(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {"chats": {}}


def _save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2))


def _load_contacts_map(path: Optional[Path]) -> dict[str, str]:
    """Load a JID -> display-name map from a contacts.yaml.

    Reuses the email feed's contacts.yaml shape under a ``whatsapp`` key
    so one operator file can drive every feed::

        whatsapp:
          contacts:
            "447700900123@s.whatsapp.net":
              name: Alex Synthetic
              contact_label: Partner          # -> L3 via CM048 ladder
              privacy_level: L3               # explicit override (wins)
          groups:
            "group:42":
              group_label: Family             # -> L3 via CM048 ladder

    Keys are lower-cased. Missing file / PyYAML -> empty map (JIDs render
    as their phone-number local part, no L3 overrides).
    """
    return _load_whatsapp_section(path, "contacts", "name")


def _load_label_map(
    path: Optional[Path], section: str, label_key: str
) -> dict[str, str]:
    """Load a JID/chat -> label-or-privacy map from the contacts.yaml."""
    return _load_whatsapp_section(path, section, label_key)


def _load_whatsapp_section(
    path: Optional[Path], section: str, value_key: str
) -> dict[str, str]:
    if path is None or not path.exists():
        return {}
    try:
        import yaml
    except ImportError:
        logger.warning("PyYAML not installed; WhatsApp %s map ignored", section)
        return {}
    try:
        data = yaml.safe_load(path.read_text()) or {}
    except yaml.YAMLError as exc:
        logger.warning("Could not parse contacts file %s: %s", path, exc)
        return {}
    wa = data.get("whatsapp") or {}
    mapping = wa.get(section) or {}
    out: dict[str, str] = {}
    if isinstance(mapping, dict):
        for key, entry in mapping.items():
            if isinstance(entry, dict) and entry.get(value_key):
                out[str(key).strip().lower()] = str(entry[value_key]).strip()
    return out


def _name_resolver(contacts: dict[str, str]) -> Callable[[str], Optional[str]]:
    def resolve(jid: Optional[str]) -> Optional[str]:
        return contacts.get((jid or "").strip().lower())

    return resolve


def _label_lookup(label_map: dict[str, str], key: Optional[str]) -> Optional[str]:
    if not key:
        return None
    return label_map.get(key.strip().lower())


def _dispatch_to_cm048(
    transcript_md: str,
    metadata: dict,
    *,
    pwg_convo_cmd: list[str],
    dry_run: bool,
) -> int:
    """Write transcript + metadata to temp files and invoke
    ``pwg-convo process``. Returns the subprocess return code (0 ok).

    Temp files live in the engine-zone tmp and are cleaned up after;
    CM048 copies the raw transcript into its own state dir at step 00.
    """
    with tempfile.TemporaryDirectory(prefix="hr015_whatsapp_") as tmp:
        tdir = Path(tmp)
        tpath = tdir / "transcript.md"
        mpath = tdir / "metadata.json"
        tpath.write_text(transcript_md, encoding="utf-8")
        mpath.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
        cmd = list(pwg_convo_cmd) + ["process", str(tpath), str(mpath)]
        if dry_run:
            cmd.append("--dry-run")
        logger.info(
            "Dispatching %s to CM048 (%s)",
            metadata["conversation_id"],
            " ".join(pwg_convo_cmd),
        )
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            logger.error(
                "pwg-convo failed for %s (rc=%d): %s",
                metadata["conversation_id"],
                proc.returncode,
                proc.stderr.strip()[:500],
            )
        return proc.returncode


def _latest_ts_iso(conv: WhatsAppConversation) -> str:
    ended = conv.ended_at
    return ended.isoformat().replace("+00:00", "Z") if ended else ""


def process_whatsapp(
    *,
    db_path: Optional[Path] = None,
    contacts_path: Optional[Path] = None,
    user_display_name: str = "You",
    since_days: int = 365,
    max_messages_per_chat: Optional[int] = 2000,
    pwg_convo_cmd: Optional[list[str]] = None,
    state_path: Optional[Path] = None,
    now_utc=None,
    dry_run: bool = False,
) -> dict:
    """Read WhatsApp chats (with bodies) and dispatch new/updated chats.

    Returns a summary dict: chats scanned, dispatched, skipped (no new
    message since last bundle), failed.
    """
    pwg_convo_cmd = pwg_convo_cmd or _resolve_pwg_convo_cmd()
    state_file = state_path or _state_path()
    state = _load_state(state_file)
    chat_state: dict[str, str] = state.setdefault("chats", {})

    contacts = _load_contacts_map(contacts_path)
    contact_labels = _load_label_map(contacts_path, "contacts", "contact_label")
    contact_privacy = _load_label_map(contacts_path, "contacts", "privacy_level")
    group_labels = _load_label_map(contacts_path, "groups", "group_label")
    group_privacy = _load_label_map(contacts_path, "groups", "privacy_level")
    name_for_jid = _name_resolver(contacts)

    conversations = read_chats(
        db_path=db_path,
        since_days=since_days,
        now_utc=now_utc,
        max_messages_per_chat=max_messages_per_chat,
    )

    scanned = dispatched = skipped = failed = 0
    for conv in conversations:
        scanned += 1
        latest = _latest_ts_iso(conv)
        last_bundled = chat_state.get(conv.chat_id)
        # Re-dispatch only when this chat carries a message newer than
        # the last bundled one (a fresh reply, or a brand-new chat).
        if last_bundled and latest and latest <= last_bundled:
            skipped += 1
            continue

        # Resolve operator labels + explicit privacy, keyed on the chat's
        # identity (DM partner JID for T1, "group:<id>" for groups).
        if conv.is_group:
            group_key = f"group:{conv.chat_id}"
            group_label = _label_lookup(group_labels, group_key)
            explicit_privacy = _label_lookup(group_privacy, group_key)
            contact_label = None
        else:
            contact_label = _label_lookup(contact_labels, conv.chat.contact_jid)
            explicit_privacy = _label_lookup(contact_privacy, conv.chat.contact_jid)
            group_label = None

        transcript_md = render_transcript(
            conv,
            name_for_jid=name_for_jid,
            user_display_name=user_display_name,
        )
        metadata = build_metadata(
            conv,
            name_for_jid=name_for_jid,
            user_display_name=user_display_name,
            privacy_level=explicit_privacy,
            contact_label=contact_label,
            group_label=group_label,
        )
        rc = _dispatch_to_cm048(
            transcript_md,
            metadata,
            pwg_convo_cmd=pwg_convo_cmd,
            dry_run=dry_run,
        )
        if rc == 0:
            dispatched += 1
            if not dry_run and latest:
                chat_state[conv.chat_id] = latest
        else:
            failed += 1
            # Leave the watermark untouched so the next tick retries.

    if not dry_run:
        _save_state(state_file, state)

    summary = {
        "chats_scanned": scanned,
        "chats_dispatched": dispatched,
        "chats_skipped": skipped,
        "chats_failed": failed,
    }
    logger.info("whatsapp source tick complete: %s", summary)
    return summary


def _resolve_pwg_convo_cmd() -> list[str]:
    """Resolve how to invoke CM048's CLI.

    Priority:
      1. ``PWG_CONVO_CMD`` env (space-split) -- the installer sets this
         to the absolute venv path on the Hub.
      2. ``pwg-convo`` on PATH (installed console script).
    """
    override = os.getenv("PWG_CONVO_CMD")
    if override:
        return override.split()
    return ["pwg-convo"]


def run(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="hr015-whatsapp-source",
        description="Feed WhatsApp Desktop chats (DMs + active/intimate "
        "groups) into the CM048 four-artefact conversation pipeline.",
    )
    parser.add_argument("--db-path", type=Path, default=None)
    parser.add_argument("--contacts", type=Path, default=None)
    parser.add_argument(
        "--user-name", default=os.getenv("OSTLER_USER_DISPLAY_NAME", "You")
    )
    parser.add_argument("--since-days", type=int, default=365)
    parser.add_argument("--max-messages-per-chat", type=int, default=2000)
    parser.add_argument("--state-path", type=Path, default=None)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    try:
        summary = process_whatsapp(
            db_path=args.db_path,
            contacts_path=args.contacts,
            user_display_name=args.user_name,
            since_days=args.since_days,
            max_messages_per_chat=args.max_messages_per_chat,
            state_path=args.state_path,
            dry_run=args.dry_run,
        )
    except FileNotFoundError as exc:
        # WhatsApp Desktop not installed -- not an error, just nothing
        # to do. Mirror the metadata extractor's graceful skip.
        logger.info("%s", exc)
        print(json.dumps({
            "chats_scanned": 0, "chats_dispatched": 0,
            "chats_skipped": 0, "chats_failed": 0, "status": "no_app",
        }, indent=2))
        return 0
    except PermissionError as exc:
        logger.error("%s", exc)
        return 2
    if not args.dry_run:
        _emit_progress(summary)
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(run())
