"""Writer-side gate + idempotency layer for the EventKit / Apple
Reminders push.

This module owns the *decision* of which extracted todos should be
pushed to Apple Reminders, plus the SQLite state machine that makes
the push idempotent across re-runs of the same conversation. It does
NOT call EventKit. The actual EKEventStore work lives in
``ostler-assistant`` (signed Apple Silicon binary, has the TCC
entitlement path established) and follows in a separate PR. The
two-process split exists because a plain ``python -m cm048``
interpreter has no Info.plist with ``NSRemindersUsageDescription``,
so its TCC permission prompt is fragile and breaks across Python
upgrades. The signed assistant binary owns the EventKit invocation;
this module owns the privacy / owner / demo-mode gate and the
push-state ledger that the assistant reads from.

Privacy ladder (HARD rule, locked 2026-05-09):
    L3                    -- never pushed (Reminders.app iCloud-syncs
                             by default; pushing L3 violates the L3
                             contract). Todos stay file-only in
                             ``todos.md``.
    L2                    -- pushed with redacted title (owner +
                             "Follow up" phrase; the deadline is its
                             own due-date field, never in the title; no body
                             text).
    L1 / L0               -- pushed with full title + notes.
    Unknown level         -- treated as L3 (no push). Defence in
                             depth: a malformed bundle cannot
                             accidentally publish.

Owner buckets:
    "user" / config user_id -- pushed (Owed to me).
    "both"                  -- pushed (Shared).
    Anything else           -- skipped (Owed by them; pushing those
                                clutters the user's list with stuff
                                they aren't doing).

Demo mode hard-suppresses the entire push pipeline. Synthetic
fixtures shouldn't pollute an App Store reviewer's Reminders.

Idempotency contract (the part the assistant-side PR depends on):
The mapping table key is ``(user_id, source_session_id, todo_id)``.
``todo_id`` is already stable across re-runs (derived from
conversation_id + owner + text by ``conversation_writer.make_todo_id``).
So re-processing the same bundle finds the same row, never creates
duplicates. The assistant-side flips the row's ``status`` from
``pending`` to ``pushed`` and records the
``calendar_item_identifier`` it got back from EKEventStore. On the
next writer run, this module reads that status and flips the
in-memory ``Todo.status`` to ``"pushed-to-reminders"`` so the
re-rendered ``todos.md`` reflects reality and the CM044 wiki
"Reminders" pill shows the right state.
"""
from __future__ import annotations

import logging
import re
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import TYPE_CHECKING, Callable, Optional

from . import ostler_paths

if TYPE_CHECKING:  # avoid a circular import at runtime
    from .conversation_writer import ConversationBundle, Todo


log = logging.getLogger(__name__)


_VALID_PRIVACY_LEVELS = ("L0", "L1", "L2", "L3")
_DEFAULT_USER_ID = "user"


# ``status`` values stored in the mapping table. The assistant-side
# PR adds two more transient values during retry; for the writer
# side these five are the contract surface.
STATUS_PENDING = "pending"
STATUS_PUSHED = "pushed"
STATUS_SKIPPED = "skipped"
STATUS_FAILED = "failed"
# Permission-denied is a distinct terminal-ish outcome the assistant
# records when EKEventStore reports the operator has not granted (or
# has revoked) Reminders access. It is split out from STATUS_FAILED
# so callers and Doctor can tell "you need to grant Reminders access"
# apart from a transient / generic push failure: the former is fixed
# by the operator in System Settings, the latter is retried on the
# assistant's own cadence.
STATUS_PERMISSION_DENIED = "permission_denied"


# ``skip_reason`` values stored alongside ``status='skipped'``.
SKIP_REASON_L3 = "l3"
SKIP_REASON_UNKNOWN_LEVEL = "unknown_privacy_level"
SKIP_REASON_OWNER_OTHER = "owed_by_other"
SKIP_REASON_EMPTY_TEXT = "empty_text"
# An organisation or automated sender (the People list's own rules say so).
SKIP_REASON_NON_HUMAN = "non_human_sender"
# The People rules could not be loaded: fail closed, never push unchecked.
SKIP_REASON_UNVERIFIABLE = "person_check_unavailable"
# Another open reminder already exists for this person / thread.
SKIP_REASON_DUPLICATE_THREAD = "duplicate_thread"


# ---------------------------------------------------------------------------
# Push decision dataclass
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class PushDecision:
    """The writer-side gate's verdict for one extracted todo.

    ``eligible``: True when the assistant should call EKEventStore
    for this todo, False when it should skip (the row still lands in
    the mapping table with ``status='skipped'`` for auditability so
    the operator can answer "why isn't this in my Reminders?").

    ``push_title`` / ``push_notes`` / ``push_deadline``: pre-formatted
    payload the assistant will push verbatim. Computing the payload
    here -- not on the assistant side -- means the privacy ladder
    logic stays in CM048 where the tests live; the assistant becomes
    a dumb pusher whose only job is the EventKit invocation. This
    also keeps the redaction rules unit-testable without an EventKit
    runtime.
    """

    eligible: bool
    skip_reason: Optional[str]
    push_title: str
    push_notes: str
    push_deadline: Optional[str]
    # Stable person/thread id (see ``thread_key_for``); "" when not computed.
    thread_key: str = ""


# ---------------------------------------------------------------------------
# Decision logic
# ---------------------------------------------------------------------------


def _is_user_owned(owner: str, *, user_id: str) -> bool:
    """A todo is "owed to me" when its owner string matches the
    operator's user_id. The writer convention defaults user_id to
    the literal ``"user"``; multi-user installs override via the
    ``user_id`` parameter on ``apply_push_status_to_todos``.
    """
    owner_lc = (owner or "").strip().lower()
    if owner_lc in ("user", "me", "self"):
        return True
    return bool(user_id) and owner_lc == user_id.lower()


def _is_shared(owner: str) -> bool:
    return (owner or "").strip().lower() == "both"


def _other_participants(
    participants: tuple, *, user_id: str
) -> list[str]:
    """Return the participant labels that are NOT the operator.

    This is the "with whom" axis: the conversation partner(s) you
    might follow up with. Distinct from the "by whom" axis the
    Todo.owner field captures. We strip whitespace + lowercase the
    operator-side synonyms so multi-user installs and the literal
    ``"user"`` convention both work.
    """
    user_synonyms = {"user", "me", "self"}
    if user_id:
        user_synonyms.add(user_id.lower())
    return [
        p for p in participants
        if p and p.strip().lower() not in user_synonyms
    ]


# ---------------------------------------------------------------------------
# Participant label -> display name (never a raw handle in a customer title)
# ---------------------------------------------------------------------------

GENERIC_FOLLOW_UP_TITLE = "Follow up on a conversation"

_BARE_ID_CHARS = frozenset("0123456789+-(). ")


def _is_handle_shaped(label: str) -> bool:
    """True when ``label`` is a messaging handle, not a human name.

    Superset of the LOCKED "non-displayable name" predicate
    (ical-server ``_is_nameless_name`` == CM044 ``compiler/nameless.py`` ==
    CM031 ``PersonNameFilter``, Ref #664): empty, a WhatsApp JID
    (``@s.whatsapp.net`` / ``@lid``), or a bare identifier of phone
    characters with at least 6 digits. Widened here because a customer
    title must never carry ANY handle: any ``@`` (an email address) and any
    phone-character-only string holding a digit (a short number) also count.
    ical-server.py is a script, not an importable module, so the predicate
    is mirrored, not imported.
    """
    s = (label or "").strip()
    if not s:
        return True
    if "@" in s:
        return True
    if all(c in _BARE_ID_CHARS for c in s) and any(c.isdigit() for c in s):
        return True
    return False


def _handle_variants(handle: str) -> list[str]:
    h = handle.strip()
    out = [h, h.lower()]
    digits = "".join(c for c in h if c.isdigit())
    if digits and "@" not in h:
        out += [digits, "+" + digits]
    seen: list[str] = []
    for v in out:
        if v and v not in seen:
            seen.append(v)
    return seen


def _people_store_record(handle: str) -> Optional[dict]:
    """The People-store record for ``handle``, or None.

    The Hub People list (ical-server ``people_list``) scrolls the Qdrant
    ``people`` collection. This asks the same collection for the record whose
    payload ``phones`` / ``emails`` / ``display_name`` holds ``handle``. Any
    failure (store down, no match) returns None.
    """
    import json
    import os
    import urllib.request

    # Same override Settings applies (OSTLER_QDRANT_URL), read directly:
    # load_settings() raises without a configured user_id, and a title must
    # not depend on that.
    base = os.environ.get("OSTLER_QDRANT_URL")
    if not base:
        try:
            from .settings import load_settings

            base = load_settings().qdrant_url
        except Exception:  # noqa: BLE001 -- settings trouble must not block a title
            base = "http://localhost:6333"
    variants = _handle_variants(handle)
    body = {
        "filter": {"should": [
            {"key": "phones", "match": {"any": variants}},
            {"key": "emails", "match": {"any": variants}},
            {"key": "display_name", "match": {"any": variants}},
        ]},
        "limit": 5,
        "with_payload": True,
        "with_vector": False,
    }
    try:
        req = urllib.request.Request(
            base.rstrip("/") + "/collections/people/points/scroll",
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
        )
        # No proxy: the people store is local, and an HTTP(S)_PROXY in the
        # environment must not answer for it.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=3) as resp:
            points = (json.loads(resp.read()).get("result") or {}).get("points") or []
    except Exception as exc:  # noqa: BLE001
        log.info("reminders_push: people lookup unavailable (%s)", exc)
        return None
    for pt in points:
        p = pt.get("payload") or {}
        if p:
            return p
    return None


# ---------------------------------------------------------------------------
# The People list's own "is this a person" predicates, IMPORTED not copied
# ---------------------------------------------------------------------------

_ICAL_MODULE = None
_ICAL_TRIED = False


def _ical_server_candidates() -> list[Path]:
    import os

    here = Path(__file__).resolve()
    out: list[Path] = []
    env = os.environ.get("OSTLER_ICAL_SERVER_PATH")
    if env:
        out.append(Path(env))
    services = here.parents[2]  # <...>/services (installed) or vendor (repo)
    out.append(services / "ical-server" / "ical-server.py")
    out.append(services / "cm041" / "assistant_api" / "ical-server.py")
    return out


def _load_ical_server():
    """Import ical-server.py (the module that owns the People list rules).

    Returns the module or None. NEVER silently treated as "is a person":
    callers fail closed on None (see ``_record_verdict``).
    """
    global _ICAL_MODULE, _ICAL_TRIED
    if _ICAL_TRIED:
        return _ICAL_MODULE
    _ICAL_TRIED = True
    import importlib.util
    import sys

    for cand in _ical_server_candidates():
        if not cand.is_file():
            continue
        added = str(cand.parent)
        sys.path.insert(0, added)
        try:
            spec = importlib.util.spec_from_file_location(
                "_ostler_ical_server_rules", cand
            )
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            _ICAL_MODULE = mod
            return mod
        except Exception as exc:  # noqa: BLE001
            log.warning(
                "reminders_push: cannot import People rules from %s (%s)",
                cand, exc,
            )
        finally:
            if added in sys.path:
                sys.path.remove(added)
    return None


def is_listed_as_a_person(payload: dict, name: str) -> Optional[bool]:
    """Would the Hub People list show this record as a person?

    Calls the imported ical-server predicates in the order ``people_list``
    applies them. True = a person, False = organisation / automated sender /
    nameless, None = the rules could not be loaded (caller fails closed).
    ``tests/test_cm048_reminder_push_person_parity.py`` pins this against
    ``people_list`` itself.
    """
    srv = _load_ical_server()
    if srv is None:
        return None
    p = payload or {}
    given = (p.get("given_name") or "").strip()
    family = (p.get("family_name") or "").strip()
    nm = (name or "").strip()
    if (given or family) and srv._looks_like_bare_email_or_phone(nm):
        nm = " ".join(x for x in (given, family) if x)
    if srv._is_nameless_name(nm):
        return False
    if srv._is_role_address_name(nm):
        return False
    has_card = bool((p.get("icloud_uid") or "").strip())
    has_person_name = bool(given or family)
    if not has_person_name and srv._is_organisation_name(nm):
        return False
    if not has_card and not has_person_name and (
        srv._is_automated_or_service_name(nm) or srv._is_service_mailbox_name(nm)
    ):
        return False
    if has_card and srv._is_non_human_person(p, nm) == "organisation_card":
        return False
    if not has_card:
        phones = [x for x in (p.get("phones") or []) if x]
        emails = [x for x in (p.get("emails") or []) if x]
        if srv._is_non_human_person(p, nm, phones, emails):
            return False
    return True


NameResolver = Callable[[str], Optional[str]]

KIND_PERSON = "person"
KIND_UNKNOWN = "unknown"
KIND_NON_HUMAN = "non_human"
KIND_UNVERIFIABLE = "unverifiable"


def _record_name(p: dict) -> str:
    name = (p.get("display_name") or p.get("name") or "").strip()
    given = (p.get("given_name") or "").strip()
    family = (p.get("family_name") or "").strip()
    if (given or family) and _is_handle_shaped(name):
        name = " ".join(x for x in (given, family) if x)
    return name


def _classify_participant(
    label: str, resolver: Optional[NameResolver]
) -> tuple[str, Optional[str]]:
    """(kind, display name) for one participant label.

    PERSON: a human display name safe to show. UNKNOWN: a handle that does
    not resolve (generic title, never the handle). NON_HUMAN: an organisation
    or automated sender per the People list's own rules (no push at all).
    UNVERIFIABLE: the People rules could not be loaded (no push, fail closed).
    """
    if resolver is not None:
        try:
            name = (resolver(label) or "").strip()
        except Exception as exc:  # noqa: BLE001
            log.info("reminders_push: name resolver failed (%s)", exc)
            name = ""
        if name and not _is_handle_shaped(name):
            return KIND_PERSON, name
        return KIND_UNKNOWN, None
    payload = _people_store_record(label)
    if payload is not None:
        name = _record_name(payload)
        verdict = is_listed_as_a_person(payload, name)
        if verdict is None:
            return KIND_UNVERIFIABLE, None
        if not verdict:
            return KIND_NON_HUMAN, None
        if name and not _is_handle_shaped(name):
            return KIND_PERSON, name
        return KIND_UNKNOWN, None
    if _is_handle_shaped(label):
        return KIND_UNKNOWN, None
    # A name-shaped label with no store record: the People rules still
    # decide whether it reads as an organisation / automated sender.
    verdict = is_listed_as_a_person({}, label.strip())
    if verdict is None:
        return KIND_UNVERIFIABLE, None
    if not verdict:
        return KIND_NON_HUMAN, None
    return KIND_PERSON, label.strip()


# ---------------------------------------------------------------------------
# Short commitment text for a private 1:1 title, and the stable thread key
# ---------------------------------------------------------------------------

_MAX_TITLE_TEXT = 60
_EMAIL_RE = re.compile(r"\S+@\S+")
_AT_HANDLE_RE = re.compile(r"(?<!\w)@\w[\w.]*")
_PHONE_RE = re.compile(r"\+?\d[\d\s().-]{4,}\d")
_ISO_RE = re.compile(r"\b20\d\d-\d\d-\d\d(?:[T ][\d:.]+Z?)?\b")


def _short_text(text: str) -> str:
    """Commitment text safe for a title: no email/phone/handle/ISO date,
    collapsed whitespace, about 60 characters."""
    t = text or ""
    for rx in (_EMAIL_RE, _AT_HANDLE_RE, _ISO_RE, _PHONE_RE):
        t = rx.sub(" ", t)
    t = " ".join(t.split()).strip(" ,;:-")
    if len(t) > _MAX_TITLE_TEXT:
        cut = t[:_MAX_TITLE_TEXT].rsplit(" ", 1)[0] or t[:_MAX_TITLE_TEXT]
        t = cut.rstrip(" ,;:-") + "..."
    return t


def _norm_identity(label: str) -> str:
    s = (label or "").strip().lower()
    if "@" in s:
        local, _, host = s.partition("@")
        if host in ("s.whatsapp.net", "lid") and local.isdigit():
            return local
        return s
    digits = "".join(c for c in s if c.isdigit())
    if digits and all(c in _BARE_ID_CHARS for c in s):
        return digits
    return s


def thread_key_for(bundle: "ConversationBundle", user_id: str) -> str:
    """Stable id of the person / thread a reminder is about.

    Derived only from the counterpart identities, so it is identical after
    the mapping DB is wiped or the box is reinstalled. The EventKit side
    uses it to find an existing open reminder before creating another.
    """
    import hashlib

    others = sorted(
        {_norm_identity(o) for o in _other_participants(bundle.participants, user_id=user_id)}
    )
    basis = "|".join(others) if others else f"solo:{bundle.conversation_id}"
    return hashlib.sha256(("ostler-thread:" + basis).encode()).hexdigest()[:16]


def _format_push_title(
    todo: "Todo",
    privacy_level: str,
    *,
    bundle: "ConversationBundle",
    user_id: str,
    name_resolver: Optional[NameResolver] = None,
    participant: Optional[tuple] = None,
) -> str:
    """Title for the EKReminder.

    L0 / L1 use the raw todo text -- the user has authorised full
    detail at those levels.

    L2, private 1:1 whose partner resolves to a person: ``"<Name>: <short
    commitment text>"`` (Andy's decision, 2026-10-11: the commitment text of
    a 1:1 now syncs to iCloud with the reminder; truncated to about 60
    characters with any phone / email / handle / ISO date stripped).
    L2, 1:1 whose partner does not resolve: the generic title, never the
    handle. L2 multi-party / solo: generic by design, no names, no text.

    ``participant`` is ``(kind, name)`` from ``_classify_participant`` when
    the caller already classified (avoids a second store lookup).

    Apple Restraint: no emoji prefix, no ``[Ostler]`` tag, no
    source label in the title.
    """
    if privacy_level == "L2":
        others = _other_participants(bundle.participants, user_id=user_id)
        if len(others) == 1:
            kind, name = participant or _classify_participant(others[0], name_resolver)
            if kind == KIND_PERSON and name:
                text = _short_text(todo.text or "")
                return f"{name}: {text}" if text else f"Follow up with {name}"
            return GENERIC_FOLLOW_UP_TITLE
        if others:
            return GENERIC_FOLLOW_UP_TITLE
        # Solo / no-other-party (e.g. a meeting note where the user is the
        # only labelled participant). Don't name anyone.
        return "Follow up on commitment"
    return (todo.text or "").strip() or "(empty commitment)"


def _format_push_notes(
    todo: "Todo",
    bundle: "ConversationBundle",
    *,
    privacy_level: str,
    summary_path: Path,
    name_resolver: Optional[NameResolver] = None,
    participant: Optional[tuple] = None,
) -> str:
    """Notes body. Short context line + a ``file://`` deep link back
    to the bundle's ``summary.md`` so a tap in Reminders.app opens
    the source. No transcript dump.

    L2 emits a neutral context line. L3 never reaches here. L0 / L1 name
    the partner only when they resolve to a person; never a raw handle.
    """
    started = (bundle.started_at or "")[:10] or "unknown date"
    if privacy_level == "L2":
        context = f"From a private conversation on {started}"
    else:
        others = _other_participants(bundle.participants, user_id="")
        who = "the group"
        if len(others) == 1:
            kind, name = participant or _classify_participant(others[0], name_resolver)
            who = name if (kind == KIND_PERSON and name) else "a contact"
        context = f"From conversation with {who} on {started}"
    file_link = f"file://{summary_path}"
    return f"{context}\n\n{file_link}"


def decide_push(
    todo: "Todo",
    bundle: "ConversationBundle",
    *,
    demo_mode: bool,
    user_id: str,
    summary_path: Path,
    name_resolver: Optional[NameResolver] = None,
) -> PushDecision:
    """Run the writer-side gate for one todo.

    Demo mode is checked OUTSIDE this function (callers don't even
    open the SQLite DB when demo mode is on). This function assumes
    demo_mode=False and returns a decision purely on the privacy +
    owner + content rules.
    """
    text = (todo.text or "").strip()
    if not text:
        return PushDecision(
            eligible=False,
            skip_reason=SKIP_REASON_EMPTY_TEXT,
            push_title="",
            push_notes="",
            push_deadline=None,
        )

    raw_level = bundle.privacy_level
    if not isinstance(raw_level, str) or raw_level.upper() not in _VALID_PRIVACY_LEVELS:
        return PushDecision(
            eligible=False,
            skip_reason=SKIP_REASON_UNKNOWN_LEVEL,
            push_title="",
            push_notes="",
            push_deadline=None,
        )
    level = raw_level.upper()
    if level == "L3":
        return PushDecision(
            eligible=False,
            skip_reason=SKIP_REASON_L3,
            push_title="",
            push_notes="",
            push_deadline=None,
        )

    owner = todo.owner or ""
    if not (_is_user_owned(owner, user_id=user_id) or _is_shared(owner)):
        return PushDecision(
            eligible=False,
            skip_reason=SKIP_REASON_OWNER_OTHER,
            push_title="",
            push_notes="",
            push_deadline=None,
        )

    others = _other_participants(bundle.participants, user_id=user_id)
    classified = [(_classify_participant(o, name_resolver)) for o in others]
    kinds = [k for k, _ in classified]
    if KIND_UNVERIFIABLE in kinds:
        return PushDecision(
            eligible=False, skip_reason=SKIP_REASON_UNVERIFIABLE,
            push_title="", push_notes="", push_deadline=None,
        )
    # 1:1 with an organisation / automated sender, or a group that is
    # nothing but such senders: no push.
    if kinds and all(k == KIND_NON_HUMAN for k in kinds):
        return PushDecision(
            eligible=False, skip_reason=SKIP_REASON_NON_HUMAN,
            push_title="", push_notes="", push_deadline=None,
        )
    participant = classified[0] if len(classified) == 1 else None

    return PushDecision(
        eligible=True,
        skip_reason=None,
        push_title=_format_push_title(
            todo, level, bundle=bundle, user_id=user_id,
            name_resolver=name_resolver, participant=participant,
        ),
        push_notes=_format_push_notes(
            todo, bundle, privacy_level=level, summary_path=summary_path,
            name_resolver=name_resolver, participant=participant,
        ),
        push_deadline=todo.deadline,
        thread_key=thread_key_for(bundle, user_id),
    )


# ---------------------------------------------------------------------------
# SQLite mapping table
# ---------------------------------------------------------------------------


_SCHEMA = """
CREATE TABLE IF NOT EXISTS reminders_map (
    user_id           TEXT NOT NULL,
    source_session_id TEXT NOT NULL,
    todo_id           TEXT NOT NULL,
    status            TEXT NOT NULL,
    skip_reason       TEXT,
    push_title        TEXT,
    push_notes        TEXT,
    push_deadline     TEXT,
    calendar_item_identifier TEXT,
    pushed_at         TEXT,
    last_seen_at      TEXT NOT NULL,
    failure_reason    TEXT,
    PRIMARY KEY (user_id, source_session_id, todo_id)
);
"""


def default_db_path() -> Path:
    """Default location for the mapping DB. Lives under the engine
    room (``~/.ostler/``) per the two-zone layout -- it's engine
    state, not customer-facing content."""
    return ostler_paths.ostler_root() / "reminders_map.db"


def _open_db(db_path: Path) -> sqlite3.Connection:
    """Open the mapping DB, creating the table on first call.

    The DB path's parent is created on demand so the writer doesn't
    require the engine room to be pre-bootstrapped.
    """
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path), timeout=5.0)
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute(_SCHEMA)
    # thread_key: stable person/thread id (additive; the assistant's
    # REQUIRED_COLUMNS do not include it, so an older reader is unaffected).
    cols = {r[1] for r in conn.execute("PRAGMA table_info(reminders_map)")}
    if "thread_key" not in cols:
        conn.execute("ALTER TABLE reminders_map ADD COLUMN thread_key TEXT")
    conn.commit()
    return conn


def _open_thread_exists(
    conn: sqlite3.Connection,
    *,
    user_id: str,
    thread_key: str,
    session_id: str,
    todo_id: str,
) -> bool:
    """True when another todo already holds an open reminder for this
    person / thread. Open = pending or pushed and not completed."""
    if not thread_key:
        return False
    cols = {r[1] for r in conn.execute("PRAGMA table_info(reminders_map)")}
    done = " AND completed_at IS NULL" if "completed_at" in cols else ""
    row = conn.execute(
        "SELECT 1 FROM reminders_map WHERE user_id=? AND thread_key=? "
        "AND status IN (?, ?)" + done +
        " AND NOT (source_session_id=? AND todo_id=?) LIMIT 1",
        (user_id, thread_key, STATUS_PENDING, STATUS_PUSHED, session_id, todo_id),
    ).fetchone()
    return row is not None


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _upsert_skipped(
    conn: sqlite3.Connection,
    *,
    user_id: str,
    session_id: str,
    todo_id: str,
    reason: str,
) -> None:
    """Insert or update a skipped row.

    A skipped row is auditable (operator can answer "why isn't this
    in my Reminders?"). If a row already exists with status='pushed'
    -- i.e. the gate later changed and we now want to skip something
    that was previously pushed -- we leave the existing row alone:
    the assistant should remove the EKReminder, not us, and the
    semantics of "we used to push this and now don't" deserve
    explicit handling rather than silent drift. v1.x can ship without
    that path; this PR keeps the row stable instead.
    """
    now = _now_iso()
    cur = conn.execute(
        "SELECT status FROM reminders_map WHERE user_id=? AND source_session_id=? AND todo_id=?",
        (user_id, session_id, todo_id),
    )
    existing = cur.fetchone()
    if existing is not None and existing[0] == STATUS_PUSHED:
        # Don't downgrade a previously-pushed row to skipped here.
        # Just bump last_seen_at so the assistant knows the writer
        # is still aware of this todo.
        conn.execute(
            "UPDATE reminders_map SET last_seen_at=? "
            "WHERE user_id=? AND source_session_id=? AND todo_id=?",
            (now, user_id, session_id, todo_id),
        )
        conn.commit()
        return
    conn.execute(
        "INSERT INTO reminders_map "
        "(user_id, source_session_id, todo_id, status, skip_reason, last_seen_at) "
        "VALUES (?, ?, ?, ?, ?, ?) "
        "ON CONFLICT(user_id, source_session_id, todo_id) DO UPDATE SET "
        "  status=excluded.status, "
        "  skip_reason=excluded.skip_reason, "
        "  last_seen_at=excluded.last_seen_at",
        (user_id, session_id, todo_id, STATUS_SKIPPED, reason, now),
    )
    conn.commit()


def _row_exists(conn, *, user_id, session_id, todo_id) -> bool:
    return conn.execute(
        "SELECT 1 FROM reminders_map WHERE user_id=? AND source_session_id=? "
        "AND todo_id=?", (user_id, session_id, todo_id),
    ).fetchone() is not None


def _upsert_pending(
    conn: sqlite3.Connection,
    *,
    user_id: str,
    session_id: str,
    todo_id: str,
    decision: PushDecision,
) -> str:
    """Upsert an eligible todo into the mapping table.

    First insertion for a (user_id, session_id, todo_id) lands as
    ``status='pending'`` -- the assistant picks it up on its next
    sweep. A re-run of the writer for an already-pending row simply
    updates the payload (in case the todo text or deadline changed
    in re-extraction) but PRESERVES the existing status. A re-run
    for an already-pushed row also preserves the status; the
    assistant may want to UPDATE the EKReminder if the payload
    changed, but that's a refinement for the assistant-side PR.

    Returns the current status post-upsert so the caller can use it
    to decide whether to flip the in-memory Todo.status.
    """
    now = _now_iso()
    cur = conn.execute(
        "SELECT status FROM reminders_map WHERE user_id=? AND source_session_id=? AND todo_id=?",
        (user_id, session_id, todo_id),
    )
    existing = cur.fetchone()
    if existing is None:
        conn.execute(
            "INSERT INTO reminders_map "
            "(user_id, source_session_id, todo_id, status, push_title, push_notes, push_deadline, last_seen_at, thread_key) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                user_id, session_id, todo_id, STATUS_PENDING,
                decision.push_title, decision.push_notes,
                decision.push_deadline, now, decision.thread_key or None,
            ),
        )
        conn.commit()
        return STATUS_PENDING

    # Existing row: refresh payload + last_seen_at, preserve status.
    conn.execute(
        "UPDATE reminders_map SET "
        "  push_title=?, push_notes=?, push_deadline=?, last_seen_at=?, "
        "  thread_key=COALESCE(?, thread_key), skip_reason=NULL "
        "WHERE user_id=? AND source_session_id=? AND todo_id=?",
        (
            decision.push_title, decision.push_notes,
            decision.push_deadline, now, decision.thread_key or None,
            user_id, session_id, todo_id,
        ),
    )
    conn.commit()
    return existing[0]


# ---------------------------------------------------------------------------
# Public entry point: applied during write_conversation
# ---------------------------------------------------------------------------


def apply_push_status_to_todos(
    todos: tuple,
    bundle: "ConversationBundle",
    *,
    summary_path: Path,
    demo_mode: bool = False,
    user_id: str = _DEFAULT_USER_ID,
    db_path: Optional[Path] = None,
) -> tuple:
    """Walk the bundle's todos through the push gate and return a
    new (immutable) tuple with statuses updated to reflect the
    mapping DB state.

    Demo mode short-circuits BEFORE the DB is opened -- nothing
    gets recorded, no rows polluted, so flipping demo off later
    doesn't auto-push anything. The writer continues to render
    todos.md with statuses as supplied (typically "extracted").

    The returned tuple is newly constructed; the input tuple is
    untouched so the caller can keep the original around for log
    / diagnostic purposes.

    Side effects:
        * Creates ``db_path`` (and its parent directory) on first
          call.
        * Inserts or updates one row per todo.
        * Logs at DEBUG for normal upserts, INFO for demo-mode
          short-circuit, WARNING for unknown / malformed levels
          (which are downgraded to L3 here).
    """
    # Avoid the runtime import at module load -- conversation_writer
    # imports us, so a top-level import of Todo would loop.
    from .conversation_writer import Todo

    if demo_mode:
        log.info(
            "reminders_push: demo mode -- skipping push pipeline for "
            "%s (%d todos)",
            bundle.conversation_id, len(todos),
        )
        return todos

    if db_path is None:
        db_path = default_db_path()

    try:
        conn = _open_db(db_path)
    except (sqlite3.Error, OSError) as exc:
        # An unwriteable DB is an operator-level problem. Catches
        # both sqlite errors AND filesystem errors (parent dir
        # creation, permission denied, etc.). Log loud and return
        # the todos unchanged -- the conversation still writes to
        # disk, the push side is just paused.
        log.warning(
            "reminders_push: cannot open mapping DB at %s (%s); "
            "todos remain at their input status",
            db_path, exc,
        )
        return todos

    try:
        out: list = []
        session_id = bundle.source_session_id
        for todo in todos:
            decision = decide_push(
                todo,
                bundle,
                demo_mode=False,
                user_id=user_id,
                summary_path=summary_path,
            )
            if not decision.eligible:
                _upsert_skipped(
                    conn,
                    user_id=user_id,
                    session_id=session_id,
                    todo_id=todo.id,
                    reason=decision.skip_reason or "unknown",
                )
                # Skipped todos retain their input status (typically
                # "extracted"). The wiki will not show a Reminders
                # pill on them.
                out.append(todo)
                continue

            if _open_thread_exists(
                conn, user_id=user_id, thread_key=decision.thread_key,
                session_id=session_id, todo_id=todo.id,
            ) and not _row_exists(
                conn, user_id=user_id, session_id=session_id, todo_id=todo.id,
            ):
                log.info(
                    "reminders_push: %s/%s skipped, an open reminder already "
                    "exists for thread %s",
                    session_id, todo.id, decision.thread_key,
                )
                _upsert_skipped(
                    conn, user_id=user_id, session_id=session_id,
                    todo_id=todo.id, reason=SKIP_REASON_DUPLICATE_THREAD,
                )
                out.append(todo)
                continue

            current_status = _upsert_pending(
                conn,
                user_id=user_id,
                session_id=session_id,
                todo_id=todo.id,
                decision=decision,
            )
            if current_status == STATUS_PUSHED:
                # The assistant pushed this row on a prior sweep and
                # recorded calendar_item_identifier. Reflect that in
                # the rendered todos.md so the wiki pill flips.
                out.append(_replace_status(todo, "pushed-to-reminders"))
            elif current_status == STATUS_PERMISSION_DENIED:
                # The assistant reached EKEventStore but the operator
                # has not granted (or has revoked) Reminders access.
                # The writer renders the todo at its input status
                # ("extracted") just like the generic-failed path, but
                # the row keeps the distinct status so Doctor can tell
                # the operator to grant access rather than implying a
                # transient hiccup that will retry itself.
                out.append(todo)
            elif current_status == STATUS_FAILED:
                # The assistant tried and failed for a transient or
                # otherwise generic reason. We still let the writer
                # render the todo at "extracted"; the assistant
                # retries on its own cadence. A future Doctor surface
                # will show this to the operator.
                out.append(todo)
            else:
                # 'pending' or anything else: writer leaves the
                # status as supplied.
                out.append(todo)
        return tuple(out)
    finally:
        conn.close()


def _replace_status(todo: "Todo", new_status: str):
    """Return a new Todo with ``status`` replaced.

    The Todo dataclass is frozen, so we can't mutate; rebuild
    instead. ``dataclasses.replace`` would also work but importing
    ``dataclasses`` only for that is more import surface for one
    call site -- a manual rebuild keeps the dependency graph small
    and the intent explicit.
    """
    from .conversation_writer import Todo
    return Todo(
        id=todo.id,
        text=todo.text,
        owner=todo.owner,
        deadline=todo.deadline,
        source_anchor=todo.source_anchor,
        status=new_status,
    )


__all__ = [
    "PushDecision",
    "STATUS_PENDING", "STATUS_PUSHED", "STATUS_SKIPPED", "STATUS_FAILED",
    "STATUS_PERMISSION_DENIED",
    "SKIP_REASON_L3", "SKIP_REASON_UNKNOWN_LEVEL",
    "SKIP_REASON_OWNER_OTHER", "SKIP_REASON_EMPTY_TEXT",
    "apply_push_status_to_todos",
    "decide_push",
    "default_db_path",
]
