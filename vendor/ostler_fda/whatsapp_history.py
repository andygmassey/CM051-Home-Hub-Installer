"""Extract WhatsApp historical conversation metadata from the macOS app's
ChatStorage.sqlite.

The macOS WhatsApp Desktop client stores all messages, chat sessions,
group info, and group memberships locally in a Core-Data-backed
SQLite database at::

    ~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite

Mirrors the imessage.py extractor pattern. Requires Full Disk Access
(FDA) -- the same permission grant that gives access to iMessage's
chat.db covers WhatsApp's container, so no new TCC prompt is needed
at install time.

Three-tier ingest model (Andy 2026-05-26)
=========================================

Andy locked a three-tier quality discipline for the WhatsApp graph.
This module's classifier returns one of three tier values per chat:

T1 -- DM (1:1 chat)
    Trigger:        chat_session.ZGROUPINFO IS NULL
    Ingest:         the DM partner + lastContactWhatsApp.
    Confidence:     1.0 (implicit; no `pwg:confidence` triple emitted).
    Source tier:    "whatsapp_dm".

T2 -- Intimate OR Active group
    Trigger:        ZGROUPINFO present AND any of:
                      participant_count < 10                            (intimate path)
                      user_sent_90d >= 20                               (engagement-absolute)
                      user_sent_90d / total_msgs_90d >= 0.02            (engagement-relative)
    Ingest:         every active group member + lastContactWhatsApp.
    Confidence:     0.7 (explicit `pwg:confidence` triple emitted).
    Source tier:    "whatsapp_group_intimate" (intimate path) or
                    "whatsapp_group_active"   (engagement path).

T3 -- Large + Passive group
    Trigger:        ZGROUPINFO present AND none of the T2 paths hit
                    (participant_count >= 10 AND user_sent_90d < 20
                    AND user_sent_90d / total_msgs_90d < 0.02).
    Ingest:         **NONE.** Group is invisible to the graph.

The OR-pattern in T2 catches both shapes of valuable group:

- absolute floor (>= 20 user-sent in 90 days) catches "I moderate this
  50-person group", where the user posts often even though the group
  is large;
- relative floor (>= 2% user-sent ratio) catches "family group of 30
  where I post a lot proportionally", even if absolute count is low.

Threshold lock-ins (do NOT tune without Andy sign-off): intimate cutoff
< 10 participants, engagement window 90 days, engagement-absolute floor
20 user-sent messages, engagement-relative floor 0.02 (2%), T2
confidence 0.7, T3 = complete skip (NOT "ingest with confidence 0.3").

Schema additions
================

This extractor enables two new schema properties downstream in
``pwg_ingest.ingest_whatsapp``:

- ``pwg:confidence`` (xsd:float, 0.0-1.0). Optional; absence implies 1.0.
  Future non-DM sources should adopt the same property.
- ``pwg:contactSourceTier`` (xsd:string). One of "whatsapp_dm",
  "whatsapp_group_intimate", "whatsapp_group_active". Used by CM044's
  wiki renderer for per-source attribution + future Marvin retrieval
  down-weighting.

T3 chats are filtered out at extraction time -- they never make it
into the JSON written for ``pwg_ingest`` to consume, so the SPARQL
layer cannot accidentally emit T3 triples.

Privacy
=======

The extractor reads chat metadata + participant JIDs only. It does
NOT read message bodies, subjects, group names, or display names
into the JSON output. Body extraction is a v1.1 task (deferred
ConversationBundle path). The 90-day engagement counts the
extractor needs are computed inside this module and never persisted
to the JSON file.
"""
from __future__ import annotations

import logging
import sqlite3
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable, List, Optional

logger = logging.getLogger(__name__)

# Mac absolute time epoch -- seconds between 2001-01-01 and 1970-01-01.
# Same offset iMessage uses; the WhatsApp schema treats timestamps
# identically (ZMESSAGEDATE is "seconds since 2001-01-01 UTC").
MAC_EPOCH_OFFSET = 978307200

DEFAULT_CHAT_DB = (
    Path.home()
    / "Library"
    / "Group Containers"
    / "group.net.whatsapp.WhatsApp.shared"
    / "ChatStorage.sqlite"
)

# Three-tier classifier constants (Andy's threshold lock-ins).
INTIMATE_PARTICIPANT_MAX = 10
ENGAGEMENT_WINDOW_DAYS = 90
ENGAGEMENT_FLOOR_ABSOLUTE = 20
ENGAGEMENT_FLOOR_RELATIVE = 0.02
T2_CONFIDENCE = 0.7

# Tier literals -- match the `pwg:contactSourceTier` values documented
# in the module docstring. Used as JSON output keys + as the literal
# emitted on triples downstream.
TIER_T1_DM = "whatsapp_dm"
TIER_T2_INTIMATE = "whatsapp_group_intimate"
TIER_T2_ACTIVE = "whatsapp_group_active"
TIER_T3_SKIP = "whatsapp_skipped"  # internal-only -- never emitted

# JID suffixes we recognise. `@s.whatsapp.net` is a personal-account
# DM/member; `@broadcast` and `status@broadcast` are non-conversation
# surfaces (the customer's own status feed + WhatsApp-Business
# broadcast lists) and we drop them.
JID_SUFFIX_PERSON = "@s.whatsapp.net"
JID_SUFFIX_GROUP = "@g.us"
JID_SUFFIX_BROADCAST = "@broadcast"
# `@lid` is WhatsApp's opaque "linked-id": a privacy identifier that is NOT a
# phone number and carries no recognisable name. As the sole identity of a
# contact it is pure noise -- a 15-digit integer the customer cannot place --
# so it must never produce a Person node (BW-4: "random numbers in People").
JID_SUFFIX_LID = "@lid"


@dataclass
class WhatsAppChat:
    """A single WhatsApp chat thread + its classifier verdict.

    Carries everything pwg_ingest needs to emit triples; carries no
    message bodies (privacy) and no engagement-window counts (they
    were used to classify and then discarded).
    """
    chat_id: str             # Stable Z_PK as string for cross-source dedup.
    tier: str                # One of the TIER_* constants above.
    is_group: bool
    contact_jid: Optional[str]              # T1 only -- the DM partner.
    participants: List[str] = field(default_factory=list)  # T2 -- active members.
    last_message: Optional[datetime] = None
    participant_count: int = 0
    confidence: float = 1.0  # 0.7 for T2; 1.0 implicit otherwise.


def _convert_timestamp(raw: Optional[float]) -> Optional[datetime]:
    """Convert a WhatsApp Mac-epoch timestamp to a tz-aware datetime.

    ChatStorage stores ZMESSAGEDATE / ZLASTMESSAGEDATE as REAL
    (seconds since 2001-01-01 UTC). Some rows are NULL or 0 on
    archived sessions; we surface those as None.
    """
    if raw is None or raw == 0:
        return None
    unix_ts = raw + MAC_EPOCH_OFFSET
    try:
        return datetime.fromtimestamp(unix_ts, tz=timezone.utc)
    except (OSError, ValueError):
        # Out-of-range timestamps (e.g. corrupt row, very-old test
        # fixtures with a 0 sentinel) -- skip rather than crash.
        return None


def _now_mac_ts(now_utc: datetime) -> float:
    """Convert a UTC datetime to WhatsApp's Mac-epoch float."""
    return now_utc.timestamp() - MAC_EPOCH_OFFSET


def _open_readonly(db_path: Path) -> sqlite3.Connection:
    """Open ChatStorage.sqlite read-only.

    Identical to imessage.py's pattern. The `?mode=ro` URI guarantees
    we never accidentally mutate the customer's WhatsApp Desktop
    database -- writes are silently dropped by SQLite's URI handler.
    """
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    except sqlite3.OperationalError as exc:
        msg = str(exc).lower()
        if "authorization denied" in msg or "permission" in msg:
            raise PermissionError(
                "Cannot read WhatsApp history. Grant Full Disk Access "
                "(System Settings > Privacy & Security > Full Disk Access)."
            ) from exc
        raise
    conn.row_factory = sqlite3.Row
    return conn


def _is_real_participant_jid(jid: Optional[str]) -> bool:
    """Reject broadcast / status / empty JIDs.

    Status feed (`status@broadcast`) and broadcast lists
    (`<number>@broadcast`) are not conversations -- they should
    never produce Person nodes. Group JIDs (`@g.us`) are the chat's
    own identity, not a participant, and are also rejected.
    """
    if not jid:
        return False
    if jid.endswith(JID_SUFFIX_BROADCAST):
        return False
    if jid.endswith(JID_SUFFIX_GROUP):
        return False
    if jid.endswith(JID_SUFFIX_LID):
        # Opaque linked-id with no phone/name -- never a usable contact.
        return False
    return True


def classify_chat(
    *,
    chat_pk: int,
    group_info_id: Optional[int],
    contact_jid: Optional[str],
    last_message: Optional[datetime],
    conn: sqlite3.Connection,
    now_utc: datetime,
    intimate_max: int = INTIMATE_PARTICIPANT_MAX,
    engagement_window_days: int = ENGAGEMENT_WINDOW_DAYS,
    engagement_floor_abs: int = ENGAGEMENT_FLOOR_ABSOLUTE,
    engagement_floor_rel: float = ENGAGEMENT_FLOOR_RELATIVE,
) -> WhatsAppChat:
    """Classify one chat session into T1 / T2 (intimate or active) / T3.

    Public for testability; the AC table in the brief lists this as
    "5 unit tests" worth of coverage. The kwargs let the test
    suite override thresholds without monkey-patching module globals.

    Returns a fully-populated WhatsAppChat including the participants
    list (empty when tier is T3 -- the SPARQL emit layer filters T3
    out and the empty list is the explicit signal that nothing
    should be persisted).
    """
    if group_info_id is None:
        # T1 -- DM. Single participant: the contact's JID.
        return WhatsAppChat(
            chat_id=str(chat_pk),
            tier=TIER_T1_DM,
            is_group=False,
            contact_jid=contact_jid if _is_real_participant_jid(contact_jid) else None,
            participants=[contact_jid] if _is_real_participant_jid(contact_jid) else [],
            last_message=last_message,
            participant_count=1 if _is_real_participant_jid(contact_jid) else 0,
            confidence=1.0,
        )

    # Group. Fetch the active member JIDs.
    members = [
        row[0] for row in conn.execute(
            "SELECT ZMEMBERJID FROM ZWAGROUPMEMBER "
            "WHERE ZCHATSESSION = ? AND ZISACTIVE = 1 AND ZMEMBERJID IS NOT NULL",
            (chat_pk,),
        ).fetchall()
        if _is_real_participant_jid(row[0])
    ]
    # +1 to include the user themselves -- ZWAGROUPMEMBER lists OTHER
    # members on Andy's instance (verified by manual probe). We
    # treat participant_count as "total including self" because that's
    # the number Andy uses informally for the < 10 cutoff.
    participant_count = len(members) + 1

    # Intimate path -- promotes regardless of engagement floor.
    if participant_count < intimate_max:
        return WhatsAppChat(
            chat_id=str(chat_pk),
            tier=TIER_T2_INTIMATE,
            is_group=True,
            contact_jid=None,
            participants=members,
            last_message=last_message,
            participant_count=participant_count,
            confidence=T2_CONFIDENCE,
        )

    # Engagement floors. ZMESSAGEDATE > cutoff_mac_ts is the index
    # path on Z_WAMessage_byMessageDateIndex.
    cutoff_mac_ts = _now_mac_ts(now_utc - timedelta(days=engagement_window_days))
    user_sent_90d = conn.execute(
        "SELECT COUNT(*) FROM ZWAMESSAGE "
        "WHERE ZCHATSESSION = ? AND ZISFROMME = 1 AND ZMESSAGEDATE > ?",
        (chat_pk, cutoff_mac_ts),
    ).fetchone()[0]
    total_msgs_90d = conn.execute(
        "SELECT COUNT(*) FROM ZWAMESSAGE "
        "WHERE ZCHATSESSION = ? AND ZMESSAGEDATE > ?",
        (chat_pk, cutoff_mac_ts),
    ).fetchone()[0]

    if user_sent_90d >= engagement_floor_abs:
        return WhatsAppChat(
            chat_id=str(chat_pk),
            tier=TIER_T2_ACTIVE,
            is_group=True,
            contact_jid=None,
            participants=members,
            last_message=last_message,
            participant_count=participant_count,
            confidence=T2_CONFIDENCE,
        )
    if total_msgs_90d > 0 and (user_sent_90d / total_msgs_90d) >= engagement_floor_rel:
        return WhatsAppChat(
            chat_id=str(chat_pk),
            tier=TIER_T2_ACTIVE,
            is_group=True,
            contact_jid=None,
            participants=members,
            last_message=last_message,
            participant_count=participant_count,
            confidence=T2_CONFIDENCE,
        )

    # T3 -- large + passive. SKIP. Returned with empty participants
    # so the SPARQL emit layer naturally drops it.
    return WhatsAppChat(
        chat_id=str(chat_pk),
        tier=TIER_T3_SKIP,
        is_group=True,
        contact_jid=None,
        participants=[],
        last_message=last_message,
        participant_count=participant_count,
        confidence=0.0,  # unused -- T3 emits nothing
    )


def extract_conversations(
    db_path: Optional[Path] = None,
    since_days: Optional[int] = None,
    now_utc: Optional[datetime] = None,
) -> List[WhatsAppChat]:
    """Extract + classify all WhatsApp chat sessions.

    Args:
        db_path: Path to ChatStorage.sqlite. Defaults to the standard
            container path; tests pass an in-memory or tmp_path fixture.
        since_days: If set, drop sessions whose last_message is older
            than N days. Mirrors the imessage.py extractor's filter.
        now_utc: Override "now" for deterministic tests.

    Returns:
        List of WhatsAppChat (including T3 skipped chats -- the
        downstream JSON writer filters them out so test fixtures can
        inspect the classifier verdict without re-running the
        extractor).

    Raises:
        PermissionError: FDA not granted.
        FileNotFoundError: ChatStorage.sqlite missing.
    """
    db_path = Path(db_path) if db_path else DEFAULT_CHAT_DB
    if not db_path.exists():
        raise FileNotFoundError(
            f"WhatsApp ChatStorage.sqlite not found at {db_path}. "
            "Install WhatsApp Desktop from the Mac App Store, then re-run."
        )
    now_utc = now_utc or datetime.now(timezone.utc)

    conn = _open_readonly(db_path)
    try:
        # Pull a minimal session row -- we resolve participants per
        # session inside the classifier so the query plan stays
        # index-driven.
        sessions = conn.execute(
            "SELECT Z_PK, ZGROUPINFO, ZCONTACTJID, ZLASTMESSAGEDATE "
            "FROM ZWACHATSESSION "
            "ORDER BY ZLASTMESSAGEDATE DESC"
        ).fetchall()
    finally:
        # Hold the connection across the classifier loop; the
        # participants + engagement queries reuse it. Close after.
        pass

    chats: List[WhatsAppChat] = []
    cutoff_ts: Optional[float] = None
    if since_days is not None:
        cutoff_ts = (now_utc - timedelta(days=since_days)).timestamp()

    for row in sessions:
        last_dt = _convert_timestamp(row["ZLASTMESSAGEDATE"])
        if cutoff_ts is not None and last_dt is not None:
            if last_dt.timestamp() < cutoff_ts:
                continue

        chat = classify_chat(
            chat_pk=row["Z_PK"],
            group_info_id=row["ZGROUPINFO"],
            contact_jid=row["ZCONTACTJID"],
            last_message=last_dt,
            conn=conn,
            now_utc=now_utc,
        )
        # Drop T1 chats with no real contact JID (status@broadcast et al.)
        if chat.tier == TIER_T1_DM and not chat.contact_jid:
            continue
        chats.append(chat)

    conn.close()
    logger.info(
        "Extracted %d WhatsApp chats (t1_dm=%d, t2_intimate=%d, t2_active=%d, t3_skip=%d)",
        len(chats),
        sum(1 for c in chats if c.tier == TIER_T1_DM),
        sum(1 for c in chats if c.tier == TIER_T2_INTIMATE),
        sum(1 for c in chats if c.tier == TIER_T2_ACTIVE),
        sum(1 for c in chats if c.tier == TIER_T3_SKIP),
    )
    return chats


def chat_to_dict(chat: WhatsAppChat) -> dict:
    """Serialise a WhatsAppChat to a JSON-safe dict for pwg_ingest.

    last_message is ISO-formatted; the dataclass keeps it as a
    datetime so the classifier can do arithmetic on it.
    """
    d = asdict(chat)
    d["last_message"] = (
        chat.last_message.isoformat() if chat.last_message else None
    )
    return d


def conversation_stats(chats: Iterable[WhatsAppChat]) -> dict:
    """Tier-bucketed summary for the install summary screen.

    Privacy: counts only, no JIDs, no names. Mirrors the contract
    the install.sh hydrate_whatsapp sub-phase consumes via stdout
    JSON.
    """
    chats = list(chats)
    t1 = [c for c in chats if c.tier == TIER_T1_DM]
    t2_intimate = [c for c in chats if c.tier == TIER_T2_INTIMATE]
    t2_active = [c for c in chats if c.tier == TIER_T2_ACTIVE]
    t3 = [c for c in chats if c.tier == TIER_T3_SKIP]

    unique_people = set()
    for c in t1:
        if c.contact_jid:
            unique_people.add(c.contact_jid)
    for c in t2_intimate + t2_active:
        unique_people.update(c.participants)

    return {
        "tier_t1_dm_chats": len(t1),
        "tier_t2_intimate_chats": len(t2_intimate),
        "tier_t2_active_chats": len(t2_active),
        "tier_t3_skipped_chats": len(t3),
        # Collapsed totals matching the contract sketch in the
        # CX-85 dispatch (Andy 2026-05-26 -- install.sh parses
        # the collapsed fields, the per-subtype keys are kept for
        # the Doctor diagnostic + future analytics).
        "tier_t1_chats": len(t1),
        "tier_t2_chats": len(t2_intimate) + len(t2_active),
        "groups_classified": len(t2_intimate) + len(t2_active) + len(t3),
        "people_added": len(unique_people),
    }


def main(argv: Optional[List[str]] = None) -> int:
    """Self-contained CLI for the install.sh hydrate_whatsapp sub-phase.

    Mirrors the B2 ``pwg-email-ingest`` shape (CX-83): a single
    invocation that extracts + classifies + writes the JSON the
    pwg_ingest layer consumes, and emits a structured-JSON status
    line to stdout for install.sh to parse.

    The CLI does NOT perform the SPARQL upsert -- that stays in
    pwg_ingest where it belongs. install.sh's hydrate_whatsapp
    block runs ``python -m ostler_fda.whatsapp_history --json``
    first (the extract leg) and ``python -m ostler_fda.pwg_ingest``
    second (the ingest leg, which is shared across all FDA
    sources). Keeping the two legs separate matches the existing
    extract_all / pwg_ingest split and avoids a fork in the
    customer install timeline if Oxigraph is briefly unreachable.

    Privacy contract (mirror of B2's AC6): the --json stdout
    payload contains tier counts + people-added counts only. It
    MUST NOT contain JIDs, phone numbers, message bodies, group
    names, or person display names. stderr is allowed to log path
    + count diagnostics (launchd captures it).

    Exit codes
    ----------
    0    success or graceful-skip (FDA pending, ChatStorage.sqlite
         missing, encrypted database). install.sh reads the JSON
         and decides which MSG_HYDRATE_WHATSAPP_SKIPPED_* to render.
    2    argparse failure (Python default).
    other: an unexpected crash. launchd / install.sh treats this
         as a hard fail.
    """
    import argparse
    import json as _json
    import sys

    parser = argparse.ArgumentParser(
        prog="pwg-whatsapp-history",
        description=(
            "Extract + classify WhatsApp historical conversations from the "
            "macOS app's ChatStorage.sqlite (CX-85). Three-tier model: "
            "T1 DM (confidence 1.0), T2 intimate-or-active group (0.7), "
            "T3 large+passive group (SKIP)."
        ),
    )
    parser.add_argument(
        "--db-path",
        type=Path,
        default=None,
        help=(
            "Override the default ChatStorage.sqlite path "
            "(useful for tests + custom installs)."
        ),
    )
    parser.add_argument(
        "--since-days",
        type=int,
        default=None,
        help=(
            "Only ingest chats whose last message is within the last "
            "N days. Default: all chats."
        ),
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help=(
            "Directory to write whatsapp_conversations.json. "
            "Default: ~/.ostler/imports/fda/"
        ),
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help=(
            "Emit a single structured JSON status line to stdout. Counts "
            "only -- privacy contract per CX-85 AC."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Classify but do not write the JSON output file.",
    )
    args = parser.parse_args(argv)

    result: dict = {
        "tier_t1_chats": 0,
        "tier_t2_chats": 0,
        "tier_t1_dm_chats": 0,
        "tier_t2_intimate_chats": 0,
        "tier_t2_active_chats": 0,
        "tier_t3_skipped_chats": 0,
        "groups_classified": 0,
        "people_added": 0,
        "errors": [],
        "status": "ok",
    }

    def _stderr(msg: str) -> None:
        print(msg, file=sys.stderr, flush=True)

    try:
        chats = extract_conversations(
            db_path=args.db_path, since_days=args.since_days,
        )
    except PermissionError as exc:
        # FDA not granted -- install.sh renders SKIPPED_FDA_PENDING.
        _stderr(f"pwg-whatsapp-history: FDA pending ({exc})")
        result["status"] = "fda_pending"
        if args.json:
            print(_json.dumps(result))
        return 0
    except FileNotFoundError as exc:
        # WhatsApp Desktop not installed -- install.sh renders SKIPPED_NO_APP.
        _stderr(f"pwg-whatsapp-history: WhatsApp Desktop not installed ({exc})")
        result["status"] = "no_app"
        if args.json:
            print(_json.dumps(result))
        return 0
    except sqlite3.DatabaseError as exc:
        # Encrypted db (older WhatsApp Desktop / mid-migration).
        # Privacy: do NOT echo the exception body -- it can contain
        # the database path which is on the customer's home dir.
        msg = type(exc).__name__
        _stderr(f"pwg-whatsapp-history: database read failed ({msg})")
        result["status"] = "db_error"
        result["errors"].append(msg)
        if args.json:
            print(_json.dumps(result))
        return 0
    except Exception as exc:
        # Surface the exception type only (no instance message) to
        # avoid leaking any embedded paths or JIDs.
        msg = type(exc).__name__
        _stderr(f"pwg-whatsapp-history: unexpected failure ({msg})")
        result["status"] = "error"
        result["errors"].append(msg)
        if args.json:
            print(_json.dumps(result))
        return 1

    stats = conversation_stats(chats)
    result.update(stats)

    if not args.dry_run:
        output_dir = args.output_dir or (
            Path.home() / ".ostler" / "imports" / "fda"
        )
        output_dir.mkdir(parents=True, exist_ok=True)
        ingestible = [c for c in chats if c.tier != TIER_T3_SKIP]
        try:
            (output_dir / "whatsapp_conversations.json").write_text(
                __import__("json").dumps(
                    [chat_to_dict(c) for c in ingestible],
                    indent=2,
                )
            )
        except OSError as exc:
            msg = type(exc).__name__
            _stderr(f"pwg-whatsapp-history: could not write JSON ({msg})")
            result["status"] = "write_error"
            result["errors"].append(msg)
            if args.json:
                print(_json.dumps(result))
            return 0

    _stderr(
        f"pwg-whatsapp-history: classified {len(chats)} chats "
        f"(t1={stats['tier_t1_chats']}, "
        f"t2={stats['tier_t2_chats']}, "
        f"t3_skipped={stats['tier_t3_skipped_chats']}, "
        f"people_added={stats['people_added']})"
    )

    if args.json:
        print(_json.dumps(result))
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
