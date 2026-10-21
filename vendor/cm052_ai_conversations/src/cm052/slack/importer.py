"""Orchestration for both Slack routes: build conversations, post each one
through the CM052 wire (which hands it to CM048 for the 4-artefact bundle),
and keep the idempotency state.

Idempotency: ``state["posted"]`` maps ``conversation_id -> content digest``.
A conversation whose digest is unchanged is not posted again, so a second
run over the same data posts 0. An edit, a new reply or reaction, or a
change of privacy level changes the digest and re-posts the SAME id, which
CM048 writes into the same bundle folder (no duplicate).

Failure accounting (poison vs outage): a conversation that raised is
``failed`` and is NOT recorded, so the next run retries it. ``paused``
(subscription gate) is also not recorded. On the API route a channel's
cursor advances only when every conversation from it was recorded.
"""
from __future__ import annotations

import json
import logging
import os
from collections import Counter
from collections.abc import Callable
from datetime import datetime, timezone
from pathlib import Path

from .. import wire
from ..schemas import Conversation
from . import model
from .api import SlackApiError, SlackClient

log = logging.getLogger(__name__)

PostFn = Callable[[Conversation], dict]

# Errors after which nothing else in the workspace can be read either.
FATAL_API_ERRORS = frozenset({
    "invalid_auth", "not_authed", "token_revoked", "token_expired",
    "account_inactive", "missing_scope", "no_permission", "ekm_access_denied",
})


def state_path() -> Path:
    raw = os.environ.get("CM052_STATE_DIR") or "~/.pwg/cm052"
    return Path(raw).expanduser() / "slack_state.json"


def load_state(path: Path) -> dict:
    empty = {"posted": {}, "cursors": {}, "workspaces": {}}
    if not path.is_file():
        return empty
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        log.warning("slack state unreadable; starting empty (re-post is idempotent)")
        return empty
    for key in empty:
        if not isinstance(data.get(key), dict):
            data[key] = {}
    return data


def save_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(path)


def day_zone(state: dict):
    """The zone Slack days are cut in: the owner's, fixed at first import.

    Red team, 19 Oct: days were cut at UTC midnight, so for a UTC+8 owner a
    working day was split at 8am and the morning filed under yesterday. The
    zone is recorded in the state on first use and reused after, because a
    day unit's id contains its date: re-deriving it on every run would mint
    new ids (duplicate bundles) the first time the owner travelled.
    Order: recorded; ``OSTLER_TIMEZONE``; ``TZ``; the Mac's /etc/localtime;
    UTC.
    """
    from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

    def _zone(name):
        try:
            return ZoneInfo(name) if name else None
        except (ZoneInfoNotFoundError, ValueError):
            return None

    recorded = _zone(state.get("day_tz"))
    if recorded is not None:
        return recorded
    candidates = [os.environ.get("OSTLER_TIMEZONE"), os.environ.get("TZ")]
    try:
        target = os.path.realpath("/etc/localtime")
        if "zoneinfo/" in target:
            candidates.append(target.split("zoneinfo/", 1)[1])
    except OSError:
        pass
    for name in candidates:
        zone = _zone(name)
        if zone is not None:
            state["day_tz"] = name
            return zone
    state["day_tz"] = "UTC"
    return ZoneInfo("UTC")


def privacy_level() -> str | None:
    return model.resolve_privacy_level(os.environ.get("OSTLER_SLACK_PRIVACY_LEVEL"))


def new_counts() -> dict:
    return {
        "conversations": 0, "posted": 0, "unchanged": 0, "l3_files_only": 0,
        "paused": 0, "failed": 0,
    }


def post_all(
    convs: list[Conversation], state: dict, post_fn: PostFn, counts: dict,
    *, dry_run: bool = False,
) -> bool:
    """Post new/changed conversations. Returns True when every one of them
    is now recorded (or unchanged)."""
    all_ok = True
    for conv in convs:
        counts["conversations"] += 1
        d = model.digest(conv)
        if state["posted"].get(conv.conversation_id) == d:
            counts["unchanged"] += 1
            continue
        if dry_run:
            counts["posted"] += 1
            continue
        try:
            result = post_fn(conv) or {}
        except Exception as exc:  # one bad conversation never aborts the run
            log.warning("slack: post failed for %s: %s", conv.conversation_id, type(exc).__name__)
            counts["failed"] += 1
            all_ok = False
            continue
        status = result.get("status")
        if status == "paused":
            counts["paused"] += 1
            all_ok = False
            continue
        # ``posted`` = handed to CM048. ``l3_files_only`` is the subset at L3:
        # CM048 writes the 4-artefact bundle and skips the gist.
        counts["posted"] += 1
        if result.get("gist_level") == "L3" or result.get("reason") == "privacy_level_l3":
            counts["l3_files_only"] += 1
        state["posted"][conv.conversation_id] = d
    return all_ok


# ---------------------------------------------------------------------------
# Route 1: export
# ---------------------------------------------------------------------------


class OwnerUnknown(Exception):
    """The export route could not tell which Slack account is the owner's.

    Red team, 19 Oct: this used to carry on with ``self_id=None``, so every
    one of the owner's own messages was attributed to "a participant" and the
    owner became a contact in their own People graph. Now it refuses before
    anything is posted."""


def resolve_export_owner(
    users: dict, raw_users: list[dict], state: dict, *,
    self_user_id: str | None, self_emails: list[str],
) -> tuple[str, str]:
    """Return ``(user_id, how)``. Order: an explicit ``--self-user-id``; the
    user id ``token-set`` recorded for the SAME workspace (``auth.test``, an
    authoritative answer); then an email match. Raises ``OwnerUnknown``."""
    if self_user_id:
        if self_user_id in users:
            return self_user_id, "flag"
        raise OwnerUnknown("that Slack member ID is not in this export")
    teams = {u.get("team_id") for u in raw_users if isinstance(u, dict) and u.get("team_id")}
    for team, ws in (state.get("workspaces") or {}).items():
        uid = (ws or {}).get("user_id")
        if team in teams and uid in users:
            return uid, "token"
    wanted = {e.strip().lower() for e in self_emails if e and e.strip()}
    hits = [u.user_id for u in users.values() if u.email and u.email in wanted]
    if len(hits) == 1:
        return hits[0], "email"
    if len(hits) > 1:
        raise OwnerUnknown("more than one Slack account in this export uses your email")
    raise OwnerUnknown("none of the accounts in this export uses your email")


def import_export(
    path: Path, *, self_email: str | None, state: dict,
    post_fn: PostFn = wire.post, dry_run: bool = False,
    self_user_id: str | None = None, extra_emails: list[str] | None = None,
) -> dict:
    from .export_zip import ExportReader

    counters = model.ImportCounters()
    counts = new_counts()
    with ExportReader(path) as reader:
        users = model.parse_users(reader.users)
        self_id, how = resolve_export_owner(
            users, reader.users, state, self_user_id=self_user_id,
            self_emails=[self_email or "", *(extra_emails or [])],
        )
        ctx = model.BuildContext(
            users=users, self_user_id=self_id, privacy_level=privacy_level(),
            route="export", day_tz=day_zone(state),
        )
        # Streamed: one channel in memory at a time.
        for _folder, info, msgs in reader.iter_folders():
            convs = model.build_conversations(info, msgs, ctx, counters)
            post_all(convs, state, post_fn, counts, dry_run=dry_run)
        counts.update({
            "route": "export",
            "containers": dict(reader.kinds),
            "unmatched_folders": reader.unmatched_folders,
            "skipped_files": reader.skipped_files,
            "bad_day_files": reader.bad_day_files,
            "owner_found_by": how,
            "messages": counters.to_dict(),
        })
    return counts


# ---------------------------------------------------------------------------
# Route 2: owner's internal-app user token
# ---------------------------------------------------------------------------


def _kind(conv: dict) -> str:
    if conv.get("is_im"):
        return "im"
    if conv.get("is_mpim"):
        return "mpim"
    if conv.get("is_private") or conv.get("is_group"):
        return "private"
    return "public"


def _day_floor(epoch: float, zone=timezone.utc) -> float:
    d = datetime.fromtimestamp(max(epoch, 0), tz=zone)
    return d.replace(hour=0, minute=0, second=0, microsecond=0).timestamp()


def sync_api(
    client: SlackClient, *, state: dict, post_fn: PostFn = wire.post,
    rescan_days: int = 7, dry_run: bool = False,
    save: Callable[[dict], None] | None = None,
) -> dict:
    """Backfill on first run (``oldest=0``), then incremental.

    Each run re-reads from the start of the owner's day ``rescan_days`` before
    the channel's cursor, so day conversations are always rebuilt whole and
    edits/reactions/replies inside the window are picked up. A reply to a
    thread whose root is older than the window is NOT seen (documented
    limit; ``--rescan-days`` widens it).
    """
    me = client.auth_test()
    team = str(me.get("team_id") or "")
    self_id = me.get("user_id")
    state["workspaces"][team] = {"team": me.get("team"), "user_id": self_id}
    users = model.parse_users(client.users())
    zone = day_zone(state)
    ctx = model.BuildContext(
        users=users, self_user_id=self_id, privacy_level=privacy_level(),
        route="api", workspace=me.get("team"), day_tz=zone,
    )
    counters = model.ImportCounters()
    counts = new_counts()
    channel_errors: Counter = Counter()
    channels = client.my_conversations()
    for raw in channels:
        cid = raw.get("id")
        if not isinstance(cid, str):
            continue
        kind = _kind(raw)
        members: list[str] = []
        if kind == "im":
            members = [m for m in (self_id, raw.get("user")) if isinstance(m, str)]
        elif kind == "mpim":
            try:
                # An MPIM has at most 9 members: one page is the whole list.
                payload = client.call("conversations.members", {"channel": cid, "limit": 200})
                members = [m for m in payload.get("members") or [] if isinstance(m, str)]
            except SlackApiError:
                members = []
        info = model.ChannelInfo(
            channel_id=cid, name=str(raw.get("name") or cid), kind=kind, members=members,
        )
        key = f"{team}:{cid}"
        cursor = state["cursors"].get(key)
        oldest = "0" if cursor is None else str(
            int(_day_floor(model.ts_float(cursor) - rescan_days * 86400, zone))
        )
        try:
            msgs = client.history(cid, oldest)
            for m in list(msgs):
                if (m.get("reply_count") or 0) > 0 and m.get("ts"):
                    msgs.extend(client.replies(cid, m["ts"]))
        except SlackApiError as exc:
            if exc.error in FATAL_API_ERRORS:
                raise
            channel_errors[exc.error] += 1
            continue
        for uid in {m.get("user") for m in msgs if isinstance(m.get("user"), str)} - set(users):
            raw_user = client.user_info(uid)
            parsed = model.parse_user(raw_user) if raw_user else None
            if parsed:
                users[uid] = parsed
        convs = model.build_conversations(info, msgs, ctx, counters)
        ok = post_all(convs, state, post_fn, counts, dry_run=dry_run)
        if ok and msgs and not dry_run:
            newest = max((str(m.get("ts")) for m in msgs if m.get("ts")), key=model.ts_float)
            state["cursors"][key] = newest
        if save and not dry_run:
            save(state)
    counts.update({
        "route": "api",
        "channels": len(channels),
        "channel_errors": dict(channel_errors),
        "api_calls": client.calls,
        "messages": counters.to_dict(),
    })
    return counts
