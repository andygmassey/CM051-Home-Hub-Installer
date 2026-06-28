#!/usr/bin/env python3
"""Unified Assistant API - calendar, email, and People Graph endpoints.
Runs on localhost:8089.

Endpoints:
  GET /calendar?days=7             – events for next N days from ALL calendars
  GET /calendar/today              – today's events
  GET /people/search?q=...         – semantic search across People Graph
  GET /people/context?name=..      – everything known about a person
  GET /people/stale?months=3       – contacts not spoken to recently
  GET /people/recent?days=7        – recently met people
  GET /people/birthdays?days=7     – upcoming birthdays
  GET /email?q=...                 – Gmail query
  GET /api/v1/email/recent         – recent emails (subject + snippet only)
  GET /api/v1/suggestions          – composite today-view payload
  GET /api/v1/timeline?days=7      – merged calendar + meetings
  GET /api/v1/coach/recent         – coaching observations (CM048)
  GET /api/v1/conversation/status/{id} – conversation processing status (CM048)
  GET /api/v1/conversation/{id}/speakers – Hub-inferred speaker-identity suggestions (CM048, text-only)
  GET /api/v1/hub/health           – Hub status for iOS Companion pill (HR015 Hub portability)
  GET /api/v1/hydration/status     – First-run wiki hydration progress for the homepage panel (CM044 #624)
  GET /api/v1/recording/active     – Current capture state for the iOS Recording Live Activity (CM042 → CM031)
  POST /api/v1/conversation/process – submit conversation for processing (CM048)
  POST /api/v1/ingest/ios          – batch upload from iOS companion
  POST /api/v1/people/{slug}/forget – GDPR Art. 17 right-of-erasure (one-click forget)
  GET /health                      – health check (pass ?detailed=1 for deps)
"""

import subprocess
import json
import re
import os
import hashlib
import sqlite3
import sys
import unicodedata

# SECURITY: encrypted database wrapper from ostler_security.
#
# Before 2026-04-28 this was wrapped in `try: ... except ImportError:
# pass` which silently fell through to plaintext SQLite when the
# package was not on PYTHONPATH. The package not being importable
# is a deploy bug, not a graceful-degrade scenario, so we now
# hard-fail at import time. Missing env-var key is a separate
# (config) condition that does fall through to plaintext with a
# loud warning, since users may legitimately want to run dev
# instances unencrypted.
try:
    from ostler_security.database import get_db_connection as _secure_connect
    from ostler_security.posture import record_posture
except ImportError as exc:
    raise RuntimeError(
        "ostler_security is required but not installed in this Python "
        "environment. Refusing to start ical-server with potentially "
        "unencrypted databases. Install with: "
        "pip install /path/to/HR015/ostler_security/"
    ) from exc

# Read the database encryption key. Clean cut from LIFELINE_DB_KEY
# 2026-05-01 (no beta testers were dispatched, so no deprecation
# window is required).
_ENCRYPTION_KEY = os.environ.get("OSTLER_DB_KEY")
_KEY_SOURCE = "OSTLER_DB_KEY" if _ENCRYPTION_KEY else None
_PLAINTEXT_WARNED = False

# Record the security posture for Doctor / external introspection.
# Done at import time so the marker is up-to-date the moment the
# service is launched, even if the first DB open is much later.
if _ENCRYPTION_KEY:
    record_posture(
        "ical-server",
        "enabled",
        key_source=_KEY_SOURCE,
        backend="sqlcipher",
    )
else:
    record_posture(
        "ical-server",
        "disabled",
        reason="no_key",
        backend="plaintext",
    )


def _warn_plaintext_once(db_path: str) -> None:
    """Print a one-shot stderr warning when the coach DB falls through
    to plaintext SQLite. Loud is the right level here: silent plaintext
    is the bug we are fixing.

    Reachable only when ostler_security imported but no key was set;
    a missing module hard-fails at import."""
    global _PLAINTEXT_WARNED
    if _PLAINTEXT_WARNED:
        return
    _PLAINTEXT_WARNED = True
    print(
        f"WARNING: opening {db_path} as plaintext SQLite "
        "(OSTLER_DB_KEY env var not set). Set OSTLER_DB_KEY to "
        "enable at-rest encryption.",
        file=sys.stderr,
        flush=True,
    )
import threading
import urllib.request
import uuid
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from datetime import datetime, timedelta, timezone

# Port is env-overridable so the customer-install path can bind
# this service to a different port (8090) and let Doctor's
# reverse-proxy on :8089 forward iOS-bound /api/v1/* traffic to
# it. The default is preserved for the legacy operator-instance
# usage where ical-server owns :8089 directly. See CM051 install
# phase 3.13a + Doctor's DOCTOR_PROXY_PATHS env-var wiring.
def _resolve_port() -> int:
    raw = os.environ.get("OSTLER_API_PORT", "8089")
    try:
        port = int(raw)
    except (TypeError, ValueError):
        print(
            f"WARNING: OSTLER_API_PORT={raw!r} is not an integer; "
            "falling back to 8089.",
            file=sys.stderr,
            flush=True,
        )
        return 8089
    if not (1 <= port <= 65535):
        print(
            f"WARNING: OSTLER_API_PORT={port} is out of range; "
            "falling back to 8089.",
            file=sys.stderr,
            flush=True,
        )
        return 8089
    return port


PORT = _resolve_port()
ICAL_SCRIPT = os.environ.get(
    "ICAL_SCRIPT", os.path.expanduser("~/.zeroclaw/ical-query.sh")
)
WIKI_BASE_URL = os.environ.get("WIKI_BASE_URL", "http://localhost:8044")

# People Graph backend (storage server)
QDRANT_URL = os.environ.get("QDRANT_URL", "http://localhost:6333")
OXIGRAPH_URL = os.environ.get("OXIGRAPH_URL", "http://localhost:7878")
EMBED_OLLAMA_URL = os.environ.get("EMBED_OLLAMA_URL", "http://localhost:11434")


# Non-decomposable Latin letters that NFKD leaves intact (they are atomic
# code points, not base+combining-mark). Mapped to an ASCII transliteration
# so an accented international name yields a clean, stable, collision-resistant
# slug rather than a hyphen-riddled or empty one.
_SLUG_TRANSLIT = {
    "ø": "o", "Ø": "o",
    "ß": "ss",
    "æ": "ae", "Æ": "ae",
    "œ": "oe", "Œ": "oe",
    "ð": "d", "Ð": "d",
    "þ": "th", "Þ": "th",
    "ł": "l", "Ł": "l",
    "đ": "d", "Đ": "d",
    "ı": "i",
    "ŋ": "n",
}


def _wiki_slug(name):
    """Compute a wiki page slug from a display name.

    Mirrors the wiki compiler's intent (filesystem-/URL-safe ASCII slug) but
    is Unicode-correct for international names, which the prior naive
    ``[^a-z0-9]`` filter was not:

      * accented Latin letters are folded to their ASCII base via NFKD
        decomposition + combining-mark removal ("Jorg" not "j-rg"); the
        non-decomposable letters (ø ß æ ł ...) are transliterated first.
        So "Muller" and "Müller" both slug to "muller" (correct -- the slug
        is the URL key, accent-insensitive matching is desirable).
      * a name that folds to nothing under the ASCII filter (e.g. a CJK or
        Cyrillic name such as "山田太郎" or "Владимир") would previously have
        collapsed to the literal "unknown", so EVERY such person collided on
        a single "unknown" slug. We now derive a short, stable hex suffix
        from the original name ("person-ad8d3fea7a") so distinct non-Latin
        names get distinct slugs.

    The stored ``pwg:displayName`` keeps the original accents verbatim -- this
    function only governs the URL/page key.
    """
    if not name:
        return "unknown"
    pre = "".join(_SLUG_TRANSLIT.get(c, c) for c in name)
    folded = unicodedata.normalize("NFKD", pre)
    folded = "".join(c for c in folded if not unicodedata.combining(c))
    s = folded.strip().lower()
    s = re.sub(r"[^a-z0-9]+", "-", s)
    s = re.sub(r"-+", "-", s).strip("-")
    if s:
        return s[:80]
    digest = hashlib.sha1(name.strip().encode("utf-8")).hexdigest()[:10]
    return f"person-{digest}"


# Characters allowed in a "bare identifier" (phone-like) handle.
_NAMELESS_BARE_ID_CHARS = frozenset("0123456789+-(). ")


def _is_nameless_name(display_name):
    """True when ``display_name`` is a raw handle, not a human name.

    Canonical "non-displayable name" predicate. Byte-identical to
    ``compiler/nameless.py`` (CM044 wiki) and ``PersonNameFilter`` (CM031
    iOS); locked to prevent cross-surface drift. Ref #664.

    Non-displayable when:
      1. empty / whitespace-only, or
      2. lowercased form contains ``@s.whatsapp.net`` or ``@lid`` (a
         WhatsApp JID), or
      3. a bare identifier: every character is in ``[0-9 + - ( ) . space]``
         AND it contains at least 6 digits (a phone number / numeric handle).

    Rows are hidden at render time (the People list); the Qdrant point /
    graph node is never deleted. Composes after the exact-identifier merge
    (#168/#280): only residual nameless rows are filtered, no double-count.
    """
    if not display_name:
        return True
    s = display_name.strip()
    if not s:
        return True
    low = s.lower()
    if "@s.whatsapp.net" in low or "@lid" in low:
        return True
    if all(c in _NAMELESS_BARE_ID_CHARS for c in s) and \
            sum(c.isdigit() for c in s) >= 6:
        return True
    return False


def _event_has_human_attendee(event):
    """True when a calendar event has at least one named/emailed attendee.

    Personal-admin entries (public holidays, parcel deliveries, reminders,
    haircuts, car-hire confirmations) are typically all-day events with NO
    attendee list. Real meetings either carry attendees or are timed. We treat
    "has an attendee with a name or email" as the human-meeting signal; the
    operator-self filtering is left to the meeting_syncer (which keys on
    OWNER_EMAILS), because at the read-API layer we do not always know the
    operator's own address and would rather keep a borderline event than drop a
    real one.
    """
    attendees = event.get("attendees")
    if not isinstance(attendees, list):
        return False
    for a in attendees:
        if isinstance(a, dict) and (a.get("name") or a.get("email")):
            return True
        if isinstance(a, str) and a.strip():
            return True
    return False


def _is_personal_admin_event(event):
    """True when a calendar event is personal-admin, not a meeting.

    Conservative rule (v152 wiki junk-data fix): an event is personal-admin
    when it is ALL-DAY *and* has no human attendee. This catches public
    holidays ("Father's Day", "Dragon Boat Festival"), deliveries
    ("HKTV Mall delivery", "M&S Delivery"), reminders ("Haircut") and
    all-day confirmations -- all of which the calendar source emits as
    attendee-less all-day entries.

    Deliberately narrow to avoid dropping real events:
      * a TIMED event is NEVER filtered, regardless of attendees (a solo
        "Dentist 3pm" stays -- it is a real diary entry the user blocked);
      * an all-day event WITH a human attendee is NEVER filtered (an all-day
        offsite / workshop with colleagues stays).

    Trade-off it accepts: a genuinely solo all-day block the user created
    (e.g. an all-day "Focus: write report" with no attendees) is also hidden
    from the meetings/timeline surface. That is acceptable -- such blocks are
    not meetings either, and the user still sees them in their own calendar
    app. We tag-and-drop at the read layer only; nothing is deleted upstream.
    """
    if not event.get("all_day"):
        return False
    return not _event_has_human_attendee(event)


EMBED_MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text")
PWG_NS = "https://pwg.dev/ontology#"

# ── Security & config (added 2026-04-14) ─────────────────────────────
MAX_POST_BYTES = int(os.environ.get("MAX_POST_BYTES", "1048576"))  # 1 MB
# Default to UTC for region-agnostic deploys; users in specific timezones should set TIMEZONE in their plist EnvironmentVariables (IANA name e.g. America/New_York, Europe/London, Asia/Hong_Kong)
TIMEZONE = os.environ.get("TIMEZONE", "UTC")
INGEST_DIR = os.environ.get(
    "INGEST_DIR", os.path.expanduser("~/.zeroclaw/ingest")
)

# ── CM048 conversation processing integration ────────────────────────
PWG_HOME = Path(os.environ.get("PWG_HOME", os.path.expanduser("~/.pwg")))
COACH_DB = PWG_HOME / "coach" / "observations.db"
PROCESSING_DIR = PWG_HOME / "processing"
CONVERSATIONS_DIR = PWG_HOME / "conversations"

# ── Wiki hydration status (CM044 #624) ───────────────────────────────
# The wiki compiler writes a small JSON progress file as it builds; this
# endpoint reads it cross-process and combines it with live data-source
# counts to drive the first-run hydration panel on the wiki homepage.
# Host-anchored path, shared with the compiler via the same env var: the
# compiler runs in a container and bind-mounts this host location, so the
# file it writes is the file this endpoint reads. Mirrors CM044's
# compiler/hydration.py::status_path. Default kept in lockstep with it.
WIKI_HYDRATION_STATUS_FILE = (
    os.environ.get("WIKI_HYDRATION_STATUS_FILE")
    or os.path.expanduser("~/.ostler/state/wiki_hydration.json")
)

# Browser origins allowed to read the hydration endpoint. The wiki is
# served on :8044; the Tauri Hub webview uses the tauri:// origin (and
# https://tauri.localhost on Windows). This is an allowlist reflected
# back when matched, NOT '*': the route sits behind the Doctor auth
# proxy, but the CORS scope stays tight as defence in depth. The payload
# carries no PII (counts / phase / state / eta only), so the exposure if
# an unexpected origin ever slipped through is a progress bar, nothing
# personal.
WIKI_HYDRATION_ALLOWED_ORIGINS = {
    "http://localhost:8044",
    "http://127.0.0.1:8044",
    "tauri://localhost",
    "https://tauri.localhost",
}

# CM048 ships as its own venv'd service installed by CM051 install.sh
# phase 3.10b. The installer symlinks
# ${OSTLER_DIR}/services/cm048/.venv/bin/pwg-convo → /usr/local/bin/pwg-convo,
# so any caller (this assistant_api, Doctor, ZeroClaw) invokes the
# conversation pipeline as a CLI subprocess rather than importing it
# as a library. The override exists for dev / private-beta installs
# where CM048 may be installed elsewhere on PATH.
PWG_CONVO_BIN = os.environ.get("PWG_CONVO_BIN", "/usr/local/bin/pwg-convo")

# ── Hub health endpoint (HR015 Hub portability) ──────────────────────
# Source of truth for the iOS Companion's Hub status pill.
# See HR015/HUB_PORTABILITY_PLAN.md for the contract.
HUB_VERSION = os.environ.get("HUB_VERSION", "0.5.9")
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
ZEROCLAW_PROCESS_NAME = os.environ.get("ZEROCLAW_PROCESS_NAME", "zeroclaw")
PWG_EXPECTED_CONTAINERS = int(
    os.environ.get("PWG_EXPECTED_CONTAINERS", "9")
)
# On-disk marker files updated by the sync paths. Absence is treated as
# "never synced" rather than an error. Using sentinel files keeps this
# endpoint free of runtime coupling to the sync code.
SYNC_STATE_DIR = Path(os.environ.get(
    "SYNC_STATE_DIR", os.path.expanduser("~/.zeroclaw/sync-state")
))
CALDAV_LAST_REFRESH_FILE = SYNC_STATE_DIR / "caldav.last_refresh"
LAST_SYNC_FILE = SYNC_STATE_DIR / "last_sync"
# Aggressive per-check timeout. The endpoint itself must stay under 500ms
# end-to-end even when a dependency hangs; we cap every network / shell
# call at this value and run them in parallel so one slow check cannot
# drag the whole response down.
HUB_CHECK_TIMEOUT_SECONDS = float(
    os.environ.get("HUB_CHECK_TIMEOUT_SECONDS", "2.0")
)
# Queue-depth source. ZeroClaw does not yet expose a queryable endpoint
# for pending actions, so v1 reads from an on-disk marker file written
# by the catch-up replay path. Missing file means queue empty.
# TODO(hub-portability): replace with a ZeroClaw HTTP endpoint once it
# exposes one. Tracked alongside Step 3 in HUB_PORTABILITY_PLAN.md.
QUEUE_DEPTH_FILE = SYNC_STATE_DIR / "queue_depth"

# ── Recording state endpoint (CM042 → CM031 Live Activity) ───────────
# Source of truth for the iOS Companion's Recording Live Activity. The
# CM042 producer writes ~/.ostler/recording_state.json atomically
# (.tmp + rename, mode 0600) whenever a meeting capture transitions
# state. Readers (this endpoint) treat a missing file as "no active
# recording" and a stale file (older than RECORDING_STALE_SECONDS) as
# the producer having crashed mid-stream, again returning null so the
# Live Activity collapses rather than going stuck.
RECORDING_STATE_FILE = Path(os.environ.get(
    "RECORDING_STATE_FILE",
    os.path.expanduser("~/.ostler/recording_state.json"),
))
RECORDING_STALE_SECONDS = float(
    os.environ.get("RECORDING_STALE_SECONDS", "30")
)
# Allowed values for the `state` field. Anything else is treated as
# malformed and the endpoint returns null + logs a warning. Kept in
# sync with the CM042 producer enum and the CM031 consumer model.
RECORDING_VALID_STATES = frozenset({
    "recording", "processing", "transcript_saved", "error",
})
RECORDING_VALID_CONSENT = frozenset({"one_party", "all_party"})

try:
    from zoneinfo import ZoneInfo
    _LOCAL_TZ = ZoneInfo(TIMEZONE)
except Exception:
    _LOCAL_TZ = None


def _safe_int(params, key, default):
    """Parse a query param as int, returning (value, error_dict_or_None).

    error_dict is a ready-to-serialise JSON error when parsing fails.
    """
    raw = params.get(key, [str(default)])[0]
    try:
        return int(raw), None
    except (ValueError, TypeError):
        return default, {"error": f"Invalid integer value for '{key}': {raw!r}"}



def _safe_float(params, key, default):
    """Parse a query param as float, returning (value, error_dict_or_None).

    Mirrors _safe_int's contract (ready-to-serialise JSON error on failure).
    """
    raw = params.get(key, [str(default)])[0]
    try:
        return float(raw), None
    except (ValueError, TypeError):
        return default, {"error": f"Invalid float value for '{key}': {raw!r}"}


# ── Reply debt (CM048 reply-debt detector, JTBD#1) ───────────────────
#
# "Remember what I owe a reply on." Relationship *decay* (DORMANT badges)
# already tells the operator who they have not spoken to in a while. Reply
# *debt* is the missing twin: threads where the LAST message is inbound
# (from the other person) and has gone unanswered past a threshold -- the
# ball is in your court and you have dropped it. This lights up the
# proactive daily-brief headline ("You owe a reply to N people").
#
# The detector itself lives in CM048 (src/reply_debt.py + adapters +
# service). It is deliberately source-agnostic stdlib-only code (no LLM,
# no network): the iMessage adapter reads Apple's chat.db READ-ONLY and
# the core scores the normalised threads. We invoke it in-process by
# importing CM048's reply-debt service from OSTLER_PROJECT_DIR -- the same
# env var the existing CM048 conversation-processing integration uses to
# locate the CM048 checkout on the box. CM048's
# ``handle_reply_debt``/``compute_reply_debts`` were written for exactly
# this seam (see src/reply_debt_service.py docstring).
#
# Single-machine architecture (v1.0.3): chat.db lives at
# ~/Library/Messages/chat.db on the same Mac the Assistant API runs on, so
# the data is reachable from this process given Full Disk Access. No second
# host, no cross-machine sync.
#
# HONESTY: we distinguish "no data source reachable" (degraded:true -- the
# CM048 checkout is not on the path, or chat.db cannot be read) from "zero
# replies owed" (degraded:false, debts:[] -- you are caught up). The brief
# leads with the headline only when debts is non-empty; an empty-but-not-
# degraded result is the honest "all caught up" state.

# Where the CM048 checkout lives on the box. Mirrors OSTLER_PROJECT_DIR
# used by _conversation_process_background; that env var points at the
# CM048 repo root (parent of its ``src`` package).
REPLY_DEBT_PROJECT_DIR = os.environ.get(
    "REPLY_DEBT_PROJECT_DIR",
    os.environ.get("OSTLER_PROJECT_DIR", ""),
)

# Cached import handle: None = not yet attempted, False = attempted and
# unavailable, module = loaded. Avoids re-walking sys.path on every call.
_reply_debt_service = None


def _load_reply_debt_service():
    """Import CM048's reply-debt service from the on-box checkout.

    Returns the ``reply_debt_service`` module, or None when the CM048
    checkout is not locatable / importable (a fresh box where the
    OSTLER_PROJECT_DIR is unset, or a partial install). Never raises:
    callers degrade to an empty payload so the daily brief simply omits
    the section rather than going red.

    The lookup is cached so repeated polls (the brief cron) do not
    re-import. Import failure is cached as a sentinel so we do not retry
    a doomed import on every request.
    """
    global _reply_debt_service
    if _reply_debt_service is not None:
        return _reply_debt_service or None

    project_dir = (REPLY_DEBT_PROJECT_DIR or "").strip()
    if not project_dir or not os.path.isdir(project_dir):
        _reply_debt_service = False
        return None

    try:
        import sys as _sys
        if project_dir not in _sys.path:
            _sys.path.insert(0, project_dir)
        # CM048 exposes its modules as the ``src`` package; the service
        # uses relative imports (``from . import reply_debt``) so it must
        # be imported as ``src.reply_debt_service``, not by file path.
        import importlib
        module = importlib.import_module("src.reply_debt_service")
        _reply_debt_service = module
        return module
    except Exception as exc:
        print(
            f"[reply-debt] CM048 service unavailable: "
            f"{type(exc).__name__}: {exc}",
            file=sys.stderr,
            flush=True,
        )
        _reply_debt_service = False
        return None


def api_reply_debt(threshold_hours=None, lookback_days=None,
                   include_group=False, limit=None):
    """Compute the operator's outstanding reply debts.

    Read-only. Returns ``({"count": N, "brief_line": str,
    "debts": [...]}, 200)`` -- the same shape CM048's
    ``reply_debt_payload`` emits -- so the daily-brief generator can lead
    with "You owe a reply to N people" and name the top few.

    When the CM048 reply-debt detector is not reachable from this process
    (no on-box checkout, or chat.db cannot be read) the payload carries
    ``degraded: true`` with an empty ``debts`` list, so the consumer can
    tell "no data source" apart from "caught up". A genuinely empty result
    (detector ran, nothing owed) returns ``degraded: false`` with an empty
    ``debts`` list. Status is always 200: the brief must degrade quietly,
    never surface a 5xx that would raise the Hub-offline pill.
    """
    service = _load_reply_debt_service()
    if service is None:
        return {
            "count": 0,
            "brief_line": "",
            "debts": [],
            "degraded": True,
            "reason": "reply_debt_detector_unavailable",
        }, 200

    # Optional knobs; fall back to the detector's own defaults so the
    # surface stays a thin pass-through.
    kwargs = {"include_group": bool(include_group)}
    if threshold_hours is not None:
        kwargs["threshold_hours"] = threshold_hours
    if lookback_days is not None:
        kwargs["lookback_days"] = lookback_days

    try:
        debts = service.compute_reply_debts(**kwargs)
        if limit is not None and limit >= 0:
            debts = debts[:limit]
        payload = service.reply_debt_payload(debts)
    except Exception as exc:
        # Any failure inside the detector (a chat.db read error, a bad
        # adapter) degrades to caught-up rather than 5xx.
        print(
            f"[reply-debt] computation failed: "
            f"{type(exc).__name__}: {exc}",
            file=sys.stderr,
            flush=True,
        )
        return {
            "count": 0,
            "brief_line": "",
            "debts": [],
            "degraded": True,
            "reason": f"reply_debt_failed: {str(exc)[:200]}",
        }, 200

    payload.setdefault("degraded", False)
    return payload, 200


def _to_iso8601(raw):
    """Convert one of the date-ish strings we emit into ISO-8601.

    Inputs we have to handle:
      - "20260428T093000"  – iCal-style local time
      - "20260428"         – iCal-style all-day date
      - "2026-04-28"       – meeting date (already ISO short form)
      - ""                 – nothing parseable
    Anything we can't parse is returned unchanged so the iOS side can
    display the raw value rather than silently nil-ing.
    """
    if not raw:
        return ""
    s = str(raw)
    try:
        if len(s) == 15 and "T" in s:
            dt = datetime.strptime(s, "%Y%m%dT%H%M%S")
            return dt.strftime("%Y-%m-%dT%H:%M:%S")
        if len(s) == 8 and s.isdigit():
            dt = datetime.strptime(s, "%Y%m%d")
            return dt.strftime("%Y-%m-%d")
        # Already looks ISO-ish: leave it alone.
        return s
    except ValueError:
        return s


# Google Calendar via gws CLI
GWS_BIN = "/usr/local/bin/gws"
GWS_ENV = {
    "PATH": "/usr/local/bin:/usr/bin:/bin",
    "HOME": os.path.expanduser("~"),
    "GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND": "file",
}


def _parse_attendee(line):
    """Parse an ATTENDEE or ORGANIZER iCal line into a dict.

    Examples:
      ATTENDEE;CN=Alice Example;CUTYPE=INDIVIDUAL;EMAIL=alice@example.com;PARTSTAT=ACCEPTED:mailto:alice@example.com
      ORGANIZER;CN=Bob Example;EMAIL=bob@example.com:/principal/path
    """
    result = {}
    # Extract CN=Name
    cn_match = re.search(r'CN=([^;:]+)', line)
    if cn_match:
        result["name"] = cn_match.group(1).strip()
    # Extract EMAIL= parameter (most reliable source)
    email_match = re.search(r'EMAIL=([^;:]+)', line)
    if email_match:
        result["email"] = email_match.group(1).strip().lower()
    elif 'mailto:' in line.lower():
        # Fallback: extract from mailto: value
        mailto_match = re.search(r'mailto:([^\s]+)', line, re.IGNORECASE)
        if mailto_match:
            result["email"] = mailto_match.group(1).strip().lower()
    # Extract PARTSTAT
    status_match = re.search(r'PARTSTAT=([^;:]+)', line)
    if status_match:
        result["status"] = status_match.group(1).strip()
    # Default role
    if line.startswith("ORGANIZER"):
        result["role"] = "organizer"
    else:
        result["role"] = "attendee"
    # Only return if we got at least a name or email
    return result if result.get("email") or result.get("name") else None


def query_google_calendar(days):
    """Query Google Calendar via gws CLI."""
    events = []
    now = datetime.utcnow()
    end = now + timedelta(days=days)

    try:
        params = json.dumps({
            "calendarId": "primary",
            "maxResults": 50,
            "timeMin": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "timeMax": end.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "singleEvents": True,
            "orderBy": "startTime",
        })
        result = subprocess.run(
            [GWS_BIN, "calendar", "events", "list", "--params", params],
            capture_output=True, text=True, timeout=30, env=GWS_ENV
        )
        if result.returncode != 0:
            return events

        data = json.loads(result.stdout)
        for item in data.get("items", []):
            if item.get("eventType") in ("birthday", "focusTime", "outOfOffice"):
                continue
            event = {
                "summary": item.get("summary", ""),
                "location": item.get("location", ""),
                "source": "Google Calendar",
            }
            # UID
            if item.get("iCalUID"):
                event["uid"] = item["iCalUID"]
            start = item.get("start", {})
            end_t = item.get("end", {})
            if "dateTime" in start:
                dt = datetime.fromisoformat(start["dateTime"].replace("Z", "+00:00"))
                event["start"] = dt.strftime("%Y%m%dT%H%M%S")
                event["start_formatted"] = dt.strftime("%a %b %d, %H:%M")
            elif "date" in start:
                dt = datetime.strptime(start["date"], "%Y-%m-%d")
                event["start"] = dt.strftime("%Y%m%d")
                event["start_formatted"] = dt.strftime("%a %b %d") + " (all day)"
                event["all_day"] = True
            if "dateTime" in end_t:
                dt = datetime.fromisoformat(end_t["dateTime"].replace("Z", "+00:00"))
                event["end"] = dt.strftime("%Y%m%dT%H%M%S")
                event["end_formatted"] = dt.strftime("%H:%M")
            # Google Calendar attendees
            if item.get("attendees"):
                attendees = []
                for att in item["attendees"]:
                    a = {}
                    if att.get("displayName"):
                        a["name"] = att["displayName"]
                    if att.get("email"):
                        a["email"] = att["email"].lower()
                    if att.get("organizer"):
                        a["role"] = "organizer"
                    else:
                        a["role"] = "attendee"
                    if att.get("responseStatus"):
                        a["status"] = att["responseStatus"].upper()
                    if a.get("email") or a.get("name"):
                        attendees.append(a)
                if attendees:
                    event["attendees"] = attendees
            if event.get("summary"):
                events.append(event)
    except (subprocess.SubprocessError, json.JSONDecodeError, ValueError, KeyError) as e:
        # Log + continue: a Google Calendar fetch failure (gws CLI error,
        # malformed JSON, unexpected payload shape) must NOT break iCloud
        # results. Surface the error on stderr so deploys notice it
        # instead of silently dropping Google events.
        print(
            f"[ical-server] Google Calendar fetch failed: {type(e).__name__}: {e}",
            file=sys.stderr,
            flush=True,
        )
    except Exception as e:
        # Defensive fallback: any other unexpected error in the Google
        # path also gets logged and swallowed so iCloud results survive.
        print(
            f"[ical-server] Google Calendar fetch failed (unexpected): {type(e).__name__}: {e}",
            file=sys.stderr,
            flush=True,
        )

    return events


def parse_ical_output(raw):
    """Parse the ical-query.sh output into structured events.

    The grep output comes as: DTEND, DTSTART, LOCATION, SUMMARY per event,
    now also ATTENDEE, ORGANIZER, and UID lines.
    SUMMARY marks the END of each event block (it's the last field grep finds).
    So we accumulate fields and flush on SUMMARY.
    """
    events = []
    current = {"source": "iCloud"}

    for line in raw.strip().split("\n"):
        line = line.strip()
        if not line:
            continue

        if line.startswith("DTSTART") and "202" in line:
            match = re.search(r"(\d{8}T\d{6})", line)
            if match:
                current["start"] = match.group(1)
                tz_match = re.search(r"TZID=([^:]+)", line)
                if tz_match:
                    current["timezone"] = tz_match.group(1)
        elif line.startswith("DTSTART;VALUE=DATE:"):
            date_str = line.split(":")[-1].strip()
            if "202" in date_str:
                current["start"] = date_str
                current["all_day"] = True
        elif line.startswith("DTEND") and "202" in line:
            match = re.search(r"(\d{8}T\d{6})", line)
            if match:
                current["end"] = match.group(1)
        elif line.startswith("DTEND;VALUE=DATE:"):
            date_str = line.split(":")[-1].strip()
            if "202" in date_str:
                current["end"] = date_str
        elif line.startswith("LOCATION:"):
            current["location"] = line[9:].replace("\\,", ",").replace("\\n", ", ").strip()
        elif line.startswith("UID:"):
            current["uid"] = line[4:].strip()
        elif line.startswith("ATTENDEE"):
            attendee = _parse_attendee(line)
            if attendee:
                current.setdefault("attendees", []).append(attendee)
        elif line.startswith("ORGANIZER"):
            organizer = _parse_attendee(line)
            if organizer:
                current.setdefault("attendees", []).append(organizer)
        elif line.startswith("SUMMARY:"):
            current["summary"] = line[8:]
            # SUMMARY is the last field — flush this event
            if current.get("summary"):
                events.append(current)
            current = {"source": "iCloud"}

    # Flush any remaining event
    if current.get("summary"):
        events.append(current)

    # Filter: only events from today onwards
    now = datetime.now()
    filtered = []
    for e in events:
        start = e.get("start", "")
        if not start:
            continue
        try:
            if len(start) == 15:
                dt = datetime.strptime(start, "%Y%m%dT%H%M%S")
            elif len(start) == 8:
                dt = datetime.strptime(start, "%Y%m%d")
            else:
                continue
            if dt >= now - timedelta(days=1):
                filtered.append(e)
        except ValueError:
            continue
    events = filtered

    # Format dates
    for e in events:
        if "start" in e and len(e["start"]) == 15:
            try:
                dt = datetime.strptime(e["start"], "%Y%m%dT%H%M%S")
                e["start_formatted"] = dt.strftime("%a %b %d, %H:%M")
            except ValueError:
                pass
        elif "start" in e and len(e["start"]) == 8:
            try:
                dt = datetime.strptime(e["start"], "%Y%m%d")
                e["start_formatted"] = dt.strftime("%a %b %d") + " (all day)"
            except ValueError:
                pass
        if "end" in e and len(e["end"]) == 15:
            try:
                dt = datetime.strptime(e["end"], "%Y%m%dT%H%M%S")
                e["end_formatted"] = dt.strftime("%H:%M")
            except ValueError:
                pass

    return events


def query_gmail(query="is:unread", max_results=10):
    """Query Gmail via gws CLI."""
    try:
        params = json.dumps({"userId": "me", "q": query, "maxResults": max_results})
        result = subprocess.run(
            [GWS_BIN, "gmail", "users", "messages", "list", "--params", params],
            capture_output=True, text=True, timeout=30, env=GWS_ENV
        )
        if result.returncode != 0:
            return {"error": result.stderr[:200], "count": 0}

        data = json.loads(result.stdout)
        messages = data.get("messages", [])
        count = data.get("resultSizeEstimate", len(messages))

        # Fetch subject lines for the first few messages
        summaries = []
        for msg in messages[:5]:
            try:
                detail_params = json.dumps({"userId": "me", "id": msg["id"], "format": "metadata", "metadataHeaders": ["Subject", "From", "Date"]})
                detail = subprocess.run(
                    [GWS_BIN, "gmail", "users", "messages", "get", "--params", detail_params],
                    capture_output=True, text=True, timeout=15, env=GWS_ENV
                )
                if detail.returncode == 0:
                    detail_data = json.loads(detail.stdout)
                    headers = {h["name"]: h["value"] for h in detail_data.get("payload", {}).get("headers", [])}
                    summaries.append({
                        "subject": headers.get("Subject", "(no subject)"),
                        "from": headers.get("From", ""),
                        "date": headers.get("Date", ""),
                    })
            except Exception:
                continue

        return {"count": count, "messages": summaries, "query": query}
    except Exception as e:
        return {"error": str(e), "count": 0}


# ===========================================================================
# People Graph endpoints (CM041 Phase 3)
# ===========================================================================

def _embed_text(text):
    """Embed text via Ollama and return the vector."""
    data = json.dumps({"model": EMBED_MODEL, "input": [text]}).encode()
    req = urllib.request.Request(
        EMBED_OLLAMA_URL.rstrip("/") + "/api/embed",
        data=data,
        headers={"Content-Type": "application/json"},
    )
    resp = urllib.request.urlopen(req, timeout=30)
    return json.loads(resp.read())["embeddings"][0]


def _sparql_select(sparql):
    """Run a SPARQL SELECT on Oxigraph, return list of binding dicts."""
    req = urllib.request.Request(
        OXIGRAPH_URL.rstrip("/") + "/query",
        data=sparql.encode("utf-8"),
        headers={
            "Content-Type": "application/sparql-query",
            "Accept": "application/sparql-results+json",
        },
    )
    resp = urllib.request.urlopen(req, timeout=30)
    data = json.loads(resp.read())
    return [{k: v["value"] for k, v in b.items()}
            for b in data.get("results", {}).get("bindings", [])]


def _sparql_update(sparql):
    """Run a SPARQL UPDATE (DELETE WHERE / INSERT) on Oxigraph.

    Returns when Oxigraph responds with 200 or 204 No Content. Lets
    urllib.error.HTTPError propagate on 4xx/5xx so callers can decide
    how to degrade.
    """
    req = urllib.request.Request(
        OXIGRAPH_URL.rstrip("/") + "/update",
        data=sparql.encode("utf-8"),
        headers={"Content-Type": "application/sparql-update"},
        method="POST",
    )
    urllib.request.urlopen(req, timeout=30)


# Wiki-recompile queue lives under ~/.ostler/queue/. The customer install
# (CM051) creates this directory. The daily wiki-recompile LaunchAgent
# picks up `wiki_recompile_pending` and triggers a rebuild.
_RECOMPILE_QUEUE_DIR = Path(
    os.environ.get("OSTLER_QUEUE_DIR", os.path.expanduser("~/.ostler/queue"))
)

# Slug = lowercase ASCII letters, digits, hyphens. Max 80 chars (matches
# the ceiling in _wiki_slug). Rejects path-traversal seeds, SPARQL
# injection seeds, Qdrant filter abuse, and the empty string.
_SLUG_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,79}$")


def people_search(query, limit=10):
    """Semantic search across the Qdrant people collection."""
    vector = _embed_text(query)
    body = json.dumps({
        "vector": vector,
        "limit": limit,
        "with_payload": {"include": [
            "display_name", "organization", "job_title", "relationship",
            "how_we_met", "phones", "emails", "facts", "last_contact",
            "contact_type", "person_uri",
        ]},
        "filter": {"must": [
            {"key": "contact_type", "match": {"value": "person"}}
        ]},
    }).encode()
    req = urllib.request.Request(
        QDRANT_URL.rstrip("/") + "/collections/people/points/search",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    resp = urllib.request.urlopen(req, timeout=30)
    data = json.loads(resp.read())

    # Qdrant payload keys are stored in American English ("organization",
    # "job_title") for historical reasons. The JSON API surface is British
    # English ("organisation", "role") and always includes a "slug" so the
    # iOS companion can use it as its Identifiable id. See #ARCH-01 in
    # HR015/ARCHITECTURE_DRIFT.md.
    _SEARCH_PAYLOAD_TO_API = (
        ("organization", "organisation"),
        ("job_title",    "role"),
        ("relationship", "relationship"),
        ("last_contact", "last_contact"),
    )

    results = []
    for pt in data.get("result", []):
        p = pt.get("payload", {})
        dn = p.get("display_name", "")
        # Hide raw-handle "people" (WhatsApp JIDs, bare phone numbers) from
        # the People list / search results. Render-time filter only; the
        # Qdrant point is never deleted. Ref #664.
        if _is_nameless_name(dn):
            continue
        entry = {
            "name": dn,
            "slug": _wiki_slug(dn),
            "score": round(pt.get("score", 0), 3),
            "wiki_url": f"{WIKI_BASE_URL}/People/{_wiki_slug(dn)}/",
        }
        for src_key, api_key in _SEARCH_PAYLOAD_TO_API:
            if p.get(src_key):
                entry[api_key] = p[src_key]
        if p.get("facts"):
            entry["facts"] = p["facts"]
        results.append(entry)
    return {"query": query, "results": results, "count": len(results)}


# ── Coach observations (CM048 tier 3) ────────────────────────────────

def coach_recent(user_id=None, hours=168, limit=10):
    """Return recent coaching observations from the SQLite DB.

    Defaults to last 7 days (168 hours). Each observation contains
    what_went_well, what_to_work_on, tip, and conversation context.

    Productisation guard (rebrand sweep PR-2 / audit P1-6): a
    silently-defaulted ``user_id`` was Andy's instance name; on a
    customer Hub the same default would scope queries to a
    non-existent user and return empty results without warning.
    Callers must now pass an explicit ``user_id`` (the Flask route
    layer pulls it from the request, and CLI / test fixtures pass
    explicit values).
    """
    if not user_id:
        raise ValueError("user_id is required")
    if not COACH_DB.exists():
        return {"observations": [], "note": "Coach database not found"}

    cutoff = (datetime.utcnow() - timedelta(hours=hours)).isoformat()

    # ostler_security is guaranteed importable (hard-fails at module
    # load if not). The remaining branch is whether a key is set.
    if _ENCRYPTION_KEY:
        conn = _secure_connect(str(COACH_DB), _ENCRYPTION_KEY)
    else:
        _warn_plaintext_once(str(COACH_DB))
        conn = sqlite3.connect(str(COACH_DB))
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            "SELECT * FROM observations "
            "WHERE user_id = ? AND observed_at > ? "
            "ORDER BY observed_at DESC LIMIT ?",
            (user_id, cutoff, limit),
        ).fetchall()
    finally:
        conn.close()

    observations = []
    for row in rows:
        obs = dict(row)
        # Parse JSON fields
        for json_field in ("what_went_well_json", "what_to_work_on_json",
                           "tip_json", "tags_json", "flags_json"):
            raw = obs.pop(json_field, None)
            clean_key = json_field.replace("_json", "")
            if raw:
                try:
                    obs[clean_key] = json.loads(raw)
                except (json.JSONDecodeError, TypeError):
                    obs[clean_key] = raw
            else:
                obs[clean_key] = None
        observations.append(obs)

    return {"observations": observations, "count": len(observations)}


# ── Conversation processing (CM048 tier 1) ───────────────────────────

def _invoke_pwg_convo(args, timeout=900):
    """Invoke the pwg-convo CLI (CM048) as a subprocess.

    Centralises the subprocess pattern so every caller within this
    process uses the same binary discovery + timeout + capture rules.
    Returns subprocess.CompletedProcess. Raises FileNotFoundError if
    pwg-convo is not on PATH (caller decides how to surface that).
    """
    return subprocess.run(
        [PWG_CONVO_BIN, *args],
        capture_output=True, text=True, timeout=timeout,
    )


def _conversation_process_background(conversation_id, transcript, metadata):
    """Run CM048 processing in a background thread.

    Saves the raw transcript + metadata to the state directory, then
    invokes the CM048 processor. Updates state.json on completion or
    failure.

    Invokes the pwg-convo CLI installed by CM051 install.sh phase 3.10b
    at /usr/local/bin/pwg-convo (overridable via PWG_CONVO_BIN env
    var). The CLI runs src.processor.process() with the full pipeline
    (classify, enrich, signals, coach, facts, sinks).
    """
    state_dir = PROCESSING_DIR / conversation_id
    state_dir.mkdir(parents=True, exist_ok=True)

    # Save raw transcript
    (state_dir / "00_raw_transcript.md").write_text(transcript, encoding="utf-8")

    # Save metadata. CM048's CLI (src/cli.py cmd_process) rejects any
    # metadata.json that lacks a truthy ``conversation_id`` with exit
    # code 2 ("metadata.json must include a conversation_id"). The
    # caller (api_conversation_process) already derives the canonical
    # conversation_id but historically only passed it as the state-dir
    # name, never into the metadata dict, so every POSTed transcript
    # (e.g. the iOS Watch path) failed at the processor hop and was
    # silently dropped after the raw-file write. Inject it here so the
    # persisted metadata always satisfies the processor contract.
    # Default channel to "spoken" so an iOS/CM042 transcript routes
    # through CM048's spoken channel adapter when the caller omits it.
    metadata_out = dict(metadata)
    metadata_out["conversation_id"] = conversation_id
    metadata_out.setdefault("channel", "spoken")
    (state_dir / "00_metadata.json").write_text(
        json.dumps(metadata_out, indent=2, default=str), encoding="utf-8"
    )

    # Initial state
    state = {
        "conversation_id": conversation_id,
        "created_at": datetime.utcnow().isoformat() + "Z",
        "last_updated_at": datetime.utcnow().isoformat() + "Z",
        "current_step": "00_raw",
        "completed_steps": ["00_raw"],
        "failed_step": None,
        "failure_reason": None,
        "retry_count": 0,
        "prompt_versions": {},
        "sink_idempotency_keys": {},
    }
    (state_dir / "state.json").write_text(
        json.dumps(state, indent=2), encoding="utf-8"
    )

    # Invoke pwg-convo (CM048) as a CLI subprocess.
    transcript_path = str(state_dir / "00_raw_transcript.md")
    metadata_path = str(state_dir / "00_metadata.json")
    try:
        result = _invoke_pwg_convo(
            ["process", transcript_path, metadata_path],
            timeout=900,  # 15 min max
        )
        if result.returncode == 0:
            state["current_step"] = "completed"
            state["last_updated_at"] = datetime.utcnow().isoformat() + "Z"
        else:
            state["failed_step"] = "processor"
            state["failure_reason"] = result.stderr[:500] or "Non-zero exit"
            state["last_updated_at"] = datetime.utcnow().isoformat() + "Z"
    except FileNotFoundError:
        # pwg-convo not on PATH. CM048 not installed (or install.sh
        # 3.10b was skipped via --allow-plaintext). Log + surface as
        # a failed step rather than crashing the whole assistant_api
        # process; the rest of the API remains usable.
        state["failed_step"] = "processor"
        state["failure_reason"] = (
            "Conversation processing service (pwg-convo) is not "
            "installed. Re-run the Ostler installer or set "
            "PWG_CONVO_BIN to its path."
        )
        state["last_updated_at"] = datetime.utcnow().isoformat() + "Z"
    except subprocess.TimeoutExpired:
        state["failed_step"] = "processor"
        state["failure_reason"] = "Processing timed out (15 min limit)"
        state["last_updated_at"] = datetime.utcnow().isoformat() + "Z"
    except Exception as exc:
        state["failed_step"] = "processor"
        state["failure_reason"] = str(exc)[:500]
        state["last_updated_at"] = datetime.utcnow().isoformat() + "Z"

    (state_dir / "state.json").write_text(
        json.dumps(state, indent=2), encoding="utf-8"
    )


def api_conversation_process(payload):
    """Handle POST /api/v1/conversation/process.

    Accepts {transcript, metadata}. Saves raw inputs, spawns background
    processing, returns job_id immediately.
    """
    transcript = payload.get("transcript", "")
    metadata = payload.get("metadata", {})

    if not transcript:
        return {"error": "Missing 'transcript' field"}, 400

    # Front-load the CM048-installed check so the caller gets an
    # immediate 503 instead of a queued job that fails later in the
    # background. We probe pwg-convo --help (argparse-provided, exits
    # 0); FileNotFoundError means the binary is not on PATH. Short
    # timeout so a hung pwg-convo never blocks this endpoint.
    try:
        _invoke_pwg_convo(["--help"], timeout=5)
    except FileNotFoundError:
        return {
            "error": "Conversation processing service (pwg-convo) is not "
                     "installed. Re-run the Ostler installer or set "
                     "PWG_CONVO_BIN to its path."
        }, 503
    except (subprocess.TimeoutExpired, subprocess.SubprocessError):
        return {
            "error": "Conversation processing service (pwg-convo) is "
                     "installed but not responding. Check ~/.ostler/logs."
        }, 503

    # Generate conversation_id from metadata or UUID
    date = metadata.get("date", datetime.utcnow().strftime("%Y-%m-%d"))
    participants = metadata.get("participants", [])
    conv_type = metadata.get("type", "conversation")
    if participants:
        slug = "_".join(p.replace(" ", "_").lower() for p in participants[:2])
        conversation_id = f"{date}_{slug}_{conv_type}"
    else:
        conversation_id = f"{date}_{uuid.uuid4().hex[:8]}"

    # Spawn background processing
    thread = threading.Thread(
        target=_conversation_process_background,
        args=(conversation_id, transcript, metadata),
        daemon=True,
    )
    thread.start()

    return {
        "job_id": conversation_id,
        "status": "accepted",
        "state_url": f"/api/v1/conversation/status/{conversation_id}",
    }, 202


def _queue_wiki_recompile(slug):
    """Drop a marker so the daily wiki-recompile LaunchAgent picks up the
    deletion on its next run.

    Returns True if the marker landed; False if the queue dir is
    missing or unwritable. We degrade rather than fail because the
    daily recompile still runs even without the marker – the marker
    is a hint, not a precondition.
    """
    try:
        _RECOMPILE_QUEUE_DIR.mkdir(parents=True, exist_ok=True)
        (_RECOMPILE_QUEUE_DIR / "wiki_recompile_pending").touch()
        # Per-slug audit line for debug. Append-only, never rotated by
        # us. The OS log rotator handles that if customer wires one.
        audit = _RECOMPILE_QUEUE_DIR / "forget_audit.log"
        with audit.open("a", encoding="utf-8") as f:
            f.write(f"{datetime.utcnow().isoformat()}Z forget {slug}\n")
        return True
    except OSError:
        return False


def api_people_forget(slug):
    """Handle POST /api/v1/people/{slug}/forget.

    Customer's GDPR Art. 17 + UK GDPR right-of-erasure one-click
    commitment from `legal-privacy.html:213`. Deletes the person's
    records across the customer-Mac stores:

      - Oxigraph: every triple where this person is subject OR object
      - Qdrant: every vector in `people` with payload.person_uri match
      - Wiki: queue a recompile so the person's page disappears

    Idempotent: a second call with no matching person returns 200 with
    `forgotten=False` + `already_forgotten=True`. The iOS Companion
    (PR #90 ForgetPersonService) treats both as benign success.

    Response shape matches the iOS contract:
      `{forgotten, wiki_recompile_queued, stores_purged: [...]}`
    """
    # Validate slug (rejects path traversal, SPARQL injection, empty).
    if not _SLUG_PATTERN.match(slug or ""):
        return {
            "error": "Invalid slug. Expected lowercase ASCII letters, "
                     "digits, hyphens (max 80 chars)."
        }, 400

    # Look up the person URI by recomputing _wiki_slug(displayName) and
    # filtering to the exact match. We don't store slug in the graph
    # directly; it's derived from displayName by the wiki compiler.
    try:
        candidates = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?person ?name WHERE {{\n'
            '  ?person a pwg:Person ; pwg:displayName ?name .\n'
            '}}'.format(ns=PWG_NS)
        )
    except Exception as exc:
        return {
            "forgotten": False,
            "wiki_recompile_queued": False,
            "stores_purged": [],
            "degraded": True,
            "reason": f"oxigraph_lookup_failed: {exc}",
        }, 503

    person_uri = None
    for cand in candidates:
        if _wiki_slug(cand.get("name", "")) == slug:
            person_uri = cand["person"]
            break

    if person_uri is None:
        # No matching person. Idempotent: treat as already-forgotten +
        # still queue a wiki recompile in case a stale page exists.
        queued = _queue_wiki_recompile(slug)
        return {
            "forgotten": False,
            "already_forgotten": True,
            "wiki_recompile_queued": queued,
            "stores_purged": [],
        }, 200

    stores_purged = []
    degraded_reasons = []

    # Oxigraph: delete every triple where this URI is subject, then
    # every triple where it's object (incoming relationships, mentions).
    # Both in one UPDATE so partial-failure is less likely.
    esc_uri = person_uri.replace("\\", "\\\\").replace(">", "%3E")
    sparql_update = (
        "DELETE {{ <{uri}> ?p ?o }} WHERE {{ <{uri}> ?p ?o }};\n"
        "DELETE {{ ?s ?p <{uri}> }} WHERE {{ ?s ?p <{uri}> }};"
    ).format(uri=esc_uri)
    try:
        _sparql_update(sparql_update)
        stores_purged.append("oxigraph")
    except Exception as exc:
        degraded_reasons.append(f"oxigraph_update_failed: {exc}")

    # Qdrant: delete every point in `people` whose payload.person_uri
    # matches. `wait=true` so the response reflects the actual purge.
    qdrant_body = json.dumps({
        "filter": {
            "must": [
                {"key": "person_uri", "match": {"value": person_uri}}
            ]
        }
    }).encode()
    try:
        req = urllib.request.Request(
            QDRANT_URL.rstrip("/")
            + "/collections/people/points/delete?wait=true",
            data=qdrant_body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=30)
        stores_purged.append("qdrant")
    except Exception as exc:
        degraded_reasons.append(f"qdrant_delete_failed: {exc}")

    queued = _queue_wiki_recompile(slug)

    forgotten = bool(stores_purged)
    response = {
        "forgotten": forgotten,
        "wiki_recompile_queued": queued,
        "stores_purged": stores_purged,
    }
    if degraded_reasons:
        response["degraded"] = True
        response["reason"] = "; ".join(degraded_reasons)

    # 200 if at least one store was purged, 503 if both failed (so the
    # iOS Companion shows the gatewayError banner per PR #90 contract).
    status_code = 200 if forgotten else 503
    return response, status_code


def api_conversation_status(conversation_id):
    """Handle GET /api/v1/conversation/status/{id}."""
    state_file = PROCESSING_DIR / conversation_id / "state.json"
    if not state_file.exists():
        return {"error": f"Conversation '{conversation_id}' not found"}, 404
    try:
        state = json.loads(state_file.read_text())
    except Exception as exc:
        return {"error": f"Failed to read state: {exc}"}, 500
    return state, 200


def _safe_conversation_dir(conversation_id):
    """Resolve PROCESSING_DIR/<conversation_id> with path-traversal defence.

    The conversation_id arrives in the URL path and is used as a directory
    name. A malformed id ('../', absolute path, separators) must not let a
    caller read outside the processing root. Returns the resolved Path or
    None if it would escape PROCESSING_DIR.
    """
    candidate = (PROCESSING_DIR / conversation_id).resolve()
    root = PROCESSING_DIR.resolve()
    try:
        candidate.relative_to(root)
    except ValueError:
        return None
    return candidate


def api_conversation_speakers(conversation_id):
    """Handle GET /api/v1/conversation/{id}/speakers.

    Serves the speaker-identity feedback CM048 produced for this
    conversation (06_speaker_feedback.json) back to the capture device so
    it can bind each Hub-inferred name to its LOCAL voiceprint, keyed by
    the opaque voice_fingerprint_ref the device originally attached.

    PRIVACY (locked invariant, HR015 DESIGN section 4): this route only
    ever returns TEXT identity suggestions plus the opaque ref the device
    itself supplied. No voice embedding is stored on the Hub or returned;
    the Hub holds no voiceprint registry. The biometric never crosses the
    wire in either direction.

    Response shape mirrors docs/speaker_label_feedback.schema.json
    (CM048). Returns 202 (not 404) when the conversation exists but the
    speaker-feedback step has not produced its artefact yet, so the device
    knows to poll again rather than give up.
    """
    conv_dir = _safe_conversation_dir(conversation_id)
    if conv_dir is None:
        return {"error": "Invalid conversation_id"}, 400
    if not conv_dir.exists():
        return {"error": f"Conversation '{conversation_id}' not found"}, 404
    feedback_file = conv_dir / "06_speaker_feedback.json"
    if not feedback_file.exists():
        return {
            "conversation_id": conversation_id,
            "status": "pending",
            "labels": [],
            "unresolved_labels": [],
        }, 202
    try:
        feedback = json.loads(feedback_file.read_text())
    except Exception as exc:
        return {"error": f"Failed to read speaker feedback: {exc}"}, 500
    return feedback, 200


def _max_past_last_contact(dates):
    """Return the most recent last-contact date that is not in the future.

    ``last_contact`` answers "when did I last interact with this person",
    so a future-dated event (an upcoming calendar meeting that leaked into
    a ``pwg:lastContact*`` predicate) must never win the max(). Upcoming
    meetings are a "next meeting" signal carried by the Meeting nodes, not
    a last-contact one.

    ``dates`` is an iterable of ISO ``YYYY-MM-DD`` (or longer ISO) strings.
    ISO date strings sort lexicographically the same as chronologically, so
    the today cap and the max() are both plain string comparisons. Returns
    the max of the past-or-today dates, or ``None`` when every candidate is
    future-dated (or the input is empty).
    """
    today = datetime.utcnow().strftime("%Y-%m-%d")
    past = [d for d in dates if d and str(d)[:10] <= today]
    return max(past) if past else None


def person_context(name):
    """Gather everything known about a person by name."""
    esc = name.replace("\\", "\\\\").replace('"', '\\"')
    # last_contact is the MAX of the four per-source predicates, computed
    # in Python after the query so each source remains independently
    # OPTIONAL (a missing source must not exclude the row).
    persons = _sparql_select(
        'PREFIX pwg: <{ns}>\n'
        'SELECT ?person ?name ?org ?title ?rel ?howMet ?notes ?bday\n'
        '       ?lcCalendar ?lcWhatsApp ?lcEmail ?lcIMessage WHERE {{\n'
        '  ?person a pwg:Person ; pwg:displayName ?name .\n'
        '  FILTER(CONTAINS(LCASE(?name), LCASE("{q}")))\n'
        '  OPTIONAL {{ ?person pwg:organization ?org }}\n'
        '  OPTIONAL {{ ?person pwg:jobTitle ?title }}\n'
        '  OPTIONAL {{ ?person pwg:relationship ?rel }}\n'
        '  OPTIONAL {{ ?person pwg:howWeMet ?howMet }}\n'
        '  OPTIONAL {{ ?person pwg:lastContactCalendar ?lcCalendar }}\n'
        '  OPTIONAL {{ ?person pwg:lastContactWhatsApp ?lcWhatsApp }}\n'
        '  OPTIONAL {{ ?person pwg:lastContactEmail ?lcEmail }}\n'
        '  OPTIONAL {{ ?person pwg:lastContactIMessage ?lcIMessage }}\n'
        '  OPTIONAL {{ ?person pwg:notes ?notes }}\n'
        '  OPTIONAL {{ ?person pwg:birthday ?bday }}\n'
        '}} LIMIT 5'.format(ns=PWG_NS, q=esc)
    )
    if not persons:
        return {"query": name, "found": False,
                "message": "No person found matching '{}'.".format(name)}

    results = []
    for person in persons:
        uri = person["person"]
        pname = person.get("name", "")
        entry = {
            "name": pname,
            "slug": _wiki_slug(pname),
            "person_uri": uri,
            "wiki_url": f"{WIKI_BASE_URL}/People/{_wiki_slug(pname)}/",
        }
        # API surface is British English and matches the iOS Codable
        # expectations (see CM031 docs/API_CONTRACT.md). Per #ARCH-01:
        # search uses "role", context uses "title" – the iOS structs
        # currently decoding this endpoint (PersonDetail,
        # PersonContextResponse) both key on "title".
        for src, dst in [("org", "organisation"), ("title", "title"),
                         ("rel", "relationship"), ("howMet", "how_we_met"),
                         ("notes", "notes"), ("bday", "birthday")]:
            if person.get(src):
                entry[dst] = person[src]

        # MAX across the four per-source last-contact predicates, capped
        # at today so a future-dated event never wins (see
        # _max_past_last_contact). ISO date strings sort lexicographically.
        # Missing sources contribute nothing.
        per_source = [
            person.get(k) for k in
            ("lcCalendar", "lcWhatsApp", "lcEmail", "lcIMessage")
            if person.get(k)
        ]
        last_contact = _max_past_last_contact(per_source)
        if last_contact:
            entry["last_contact"] = last_contact

        # Identifiers
        ids = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?type ?value WHERE {{\n'
            '  <{uri}> pwg:hasIdentifier ?id .\n'
            '  ?id pwg:identifierType ?type ; pwg:identifierValue ?value .\n'
            '}}'.format(ns=PWG_NS, uri=uri)
        )
        if ids:
            entry["identifiers"] = [{"type": i["type"], "value": i["value"]} for i in ids]

        # Facts
        facts = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?text WHERE {{\n'
            '  ?f a pwg:PersonFact ; pwg:aboutPerson <{uri}> ; pwg:factText ?text .\n'
            '  FILTER NOT EXISTS {{ ?f pwg:validTo ?end }}\n'
            '}}'.format(ns=PWG_NS, uri=uri)
        )
        if facts:
            entry["facts"] = [f["text"] for f in facts]

        # Meetings
        meetings = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?summary ?date ?location WHERE {{\n'
            '  ?m a pwg:Meeting ; pwg:meetingAttendee <{uri}> ; pwg:meetingSummary ?summary .\n'
            '  OPTIONAL {{ ?m pwg:meetingDate ?date }}\n'
            '  OPTIONAL {{ ?m pwg:meetingLocation ?location }}\n'
            '}} ORDER BY DESC(?date) LIMIT 10'.format(ns=PWG_NS, uri=uri)
        )
        if meetings:
            entry["meetings"] = [{
                "summary": m["summary"],
                "date": m.get("date", "")[:10] if m.get("date") else "",
                "location": m.get("location", ""),
            } for m in meetings]

        # Relationship signal (CM048 tier 2 — warmth/trust from conversations)
        person_slug = _wiki_slug(pname)
        signals = _sparql_select(
            'SELECT ?warmth ?trust ?observedAt WHERE {{\n'
            '  ?signal <urn:pwg:about> ?person .\n'
            '  ?signal <urn:pwg:warmth> ?warmth .\n'
            '  ?signal <urn:pwg:trust> ?trust .\n'
            '  ?signal <urn:pwg:observedAt> ?observedAt .\n'
            '  FILTER(CONTAINS(STR(?person), "{slug}"))\n'
            '}} ORDER BY DESC(?observedAt) LIMIT 1'.format(slug=person_slug)
        )
        if signals:
            sig = signals[0]
            entry["relationship_signal"] = {
                "warmth": sig.get("warmth", ""),
                "trust": sig.get("trust", ""),
                "observed_at": sig.get("observedAt", ""),
            }

        results.append(entry)

    if len(results) == 1:
        # CM031 PWG Companion's PersonContextResponse decodes a flat shape
        # ({name, slug, organisation, title, last_contact, ...}). Marvin /
        # ZeroClaw and the existing test suite expect the nested shape
        # ({found, person: {...}}). Return both: nested for backwards
        # compatibility, flat fields at top-level for the iOS client.
        person = results[0]
        out = {"query": name, "found": True, "person": person}
        for k, v in person.items():
            # Don't shadow envelope keys.
            if k not in ("query", "found", "person", "matches", "count"):
                out[k] = v
        return out
    return {"query": name, "found": True, "matches": results, "count": len(results)}


def people_stale(months=3, limit=5):
    """Find contacts not spoken to in N months (from Qdrant last_contact)."""
    import time
    cutoff_ts = int(time.time()) - (months * 30 * 86400)
    try:
        body = {
            "filter": {
                "must": [
                    {"key": "last_contact_ts", "range": {"gt": 0, "lt": cutoff_ts}},
                    {"key": "contact_type", "match": {"value": "person"}},
                ]
            },
            "limit": limit,
            "with_payload": True,
            "with_vector": False,
        }
        data = json.dumps(body).encode()
        req = urllib.request.Request(
            QDRANT_URL.rstrip("/") + "/collections/people/points/scroll",
            data=data,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read())
    except Exception as exc:
        return {"contacts": [], "degraded": True, "reason": str(exc), "error": str(exc)}

    contacts = []
    now = time.time()
    for pt in result.get("result", {}).get("points", []):
        p = pt.get("payload", {})
        name = p.get("display_name", "")
        lc_ts = p.get("last_contact_ts", 0)
        if not name or not lc_ts:
            continue
        # Hide raw-handle "people" (WhatsApp JIDs, bare numbers) from the
        # Stale / reconnect list. Render-time filter only. Ref #664.
        if _is_nameless_name(name):
            continue
        months_since = int((now - lc_ts) / (30 * 86400))
        contacts.append({
            "name": name,
            "slug": _wiki_slug(name),
            "wiki_url": f"{WIKI_BASE_URL}/People/{_wiki_slug(name)}/",
            "last_contact": p.get("last_contact", ""),
            "months_since_contact": months_since,
            # F-2 (2026-05-27): emit `organisation` (en-GB) to match the iOS
            # Reconnect strip's subtitle decoder. The RHS still reads the
            # Qdrant payload's American-spelled key (set upstream by CM041).
            "organisation": p.get("organization", ""),
        })
    contacts.sort(key=lambda c: c["months_since_contact"], reverse=True)
    return {"contacts": contacts[:limit]}


def _recency_label(last_contact_ts):
    """Coarse uppercase relative-time label for the Hub People row.

    Mirrors the terse iOS Reconnect strip style ("3D AGO", "2MO AGO").
    Returns "" when no timestamp is known, so the row simply omits it.
    """
    if not last_contact_ts:
        return ""
    import time
    delta = int(time.time()) - int(last_contact_ts)
    if delta < 0:
        return ""
    hours = delta // 3600
    if hours < 1:
        return "JUST NOW"
    if hours < 24:
        return f"{hours}H AGO"
    days = hours // 24
    if days < 30:
        return f"{days}D AGO"
    months = days // 30
    if months < 12:
        return f"{months}MO AGO"
    return f"{months // 12}Y AGO"


# Per-source last-contact predicates surfaced by person_enrichment. The
# label is the en-GB channel name the iOS / Hub card groups by; ISO date
# strings sort lexicographically so max() over the present sources is the
# overall last-contact.
_LAST_CONTACT_SOURCES = (
    ("lcCalendar", "calendar"),
    ("lcWhatsApp", "whatsapp"),
    ("lcEmail", "email"),
    ("lcIMessage", "imessage"),
)


def person_enrichment(slug):
    """Handle GET /api/v1/people/{slug}/enrichment.

    Per-slug enrichment payload for the iOS / Hub person card. Where
    `/people/context?name=` is a fuzzy name search that can return
    several matches, this endpoint resolves a single canonical person by
    wiki slug (the same slug the People list, search results, and wiki
    URLs already use as the stable identifier) and returns the richer
    body the card wants beyond the list basics: organisation, role,
    relationship, how-we-met, notes, birthday, identifiers, recent
    meetings, the relationship signal, the MAX last-contact, and the
    per-source last-contact breakdown.

    Reader contract (verified against CM031 PWG Companion):
      - `PersonResult` (Views/People/PeopleView.swift) decodes
        {name, slug, organisation, role, last_contact}.
      - `PersonDetail` (Views/People/PersonDetailView.swift) decodes
        {name, phone, email, organisation, title, location, notes,
        last_contact}.
    Every flat field this endpoint emits maps to one of those keys or to
    the existing `/people/context` shape; `last_contact_by_source`,
    `identifiers`, `meetings`, `facts`, and `relationship_signal` are
    additive and only present when the graph has the data, so an older
    client that ignores them is unaffected.

    Returns (response_dict, status_code):
      - 400 if the slug is malformed (path-traversal / injection seeds).
      - 404 {found: False} if no person resolves to the slug.
      - 503 {degraded: True, ...} if Oxigraph is unreachable.
      - 200 {found: True, person: {...}} on success.

    Optional Qdrant enrichment (phone/email and a precomputed
    `last_contact_ts` recency) is best-effort: a Qdrant failure never
    fails the request, it just omits those fields. This mirrors the
    degraded:true fallback contract used across the people readers.
    """
    # Validate slug (rejects path traversal, SPARQL injection, empty).
    # Same guard as api_people_forget so the two slug-keyed routes agree.
    if not _SLUG_PATTERN.match(slug or ""):
        return {
            "found": False,
            "error": "Invalid slug. Expected lowercase ASCII letters, "
                     "digits, hyphens (max 80 chars).",
        }, 400

    # Resolve slug -> person URI by recomputing _wiki_slug(displayName).
    # Slug is not stored in the graph directly; it is derived from the
    # display name by the wiki compiler (see api_people_forget).
    try:
        candidates = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?person ?name WHERE {{\n'
            '  ?person a pwg:Person ; pwg:displayName ?name .\n'
            '}}'.format(ns=PWG_NS)
        )
    except Exception as exc:
        return {
            "found": False,
            "degraded": True,
            "reason": f"oxigraph_lookup_failed: {exc}",
            "error": str(exc),
        }, 503

    person_uri = None
    pname = ""
    for cand in candidates:
        cand_name = cand.get("name", "")
        if _wiki_slug(cand_name) == slug:
            person_uri = cand["person"]
            pname = cand_name
            break

    if person_uri is None:
        return {
            "slug": slug,
            "found": False,
            "message": "No person found for slug '{}'.".format(slug),
        }, 404

    entry = {
        "name": pname,
        "slug": slug,
        "person_uri": person_uri,
        "wiki_url": f"{WIKI_BASE_URL}/People/{slug}/",
    }

    # Core attributes + per-source last-contact predicates, in one query.
    # Each source predicate is OPTIONAL so a missing channel does not
    # drop the row. Mirrors the SELECT in person_context.
    try:
        rows = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?org ?title ?rel ?howMet ?notes ?bday\n'
            '       ?lcCalendar ?lcWhatsApp ?lcEmail ?lcIMessage WHERE {{\n'
            '  OPTIONAL {{ <{uri}> pwg:organization ?org }}\n'
            '  OPTIONAL {{ <{uri}> pwg:jobTitle ?title }}\n'
            '  OPTIONAL {{ <{uri}> pwg:relationship ?rel }}\n'
            '  OPTIONAL {{ <{uri}> pwg:howWeMet ?howMet }}\n'
            '  OPTIONAL {{ <{uri}> pwg:lastContactCalendar ?lcCalendar }}\n'
            '  OPTIONAL {{ <{uri}> pwg:lastContactWhatsApp ?lcWhatsApp }}\n'
            '  OPTIONAL {{ <{uri}> pwg:lastContactEmail ?lcEmail }}\n'
            '  OPTIONAL {{ <{uri}> pwg:lastContactIMessage ?lcIMessage }}\n'
            '  OPTIONAL {{ <{uri}> pwg:notes ?notes }}\n'
            '  OPTIONAL {{ <{uri}> pwg:birthday ?bday }}\n'
            '}} LIMIT 1'.format(ns=PWG_NS, uri=person_uri)
        )
    except Exception as exc:
        return {
            "found": False,
            "degraded": True,
            "reason": f"oxigraph_query_failed: {exc}",
            "error": str(exc),
        }, 503

    row = rows[0] if rows else {}
    # British-English keys, matching person_context / the iOS Codables.
    for src, dst in [("org", "organisation"), ("title", "title"),
                     ("rel", "relationship"), ("howMet", "how_we_met"),
                     ("notes", "notes"), ("bday", "birthday")]:
        if row.get(src):
            entry[dst] = row[src]
    # `role` alias: PersonResult (search-result shape) keys on "role";
    # PersonDetail keys on "title". Emit both off the same job-title
    # predicate so either client decodes a value. Per #ARCH-01.
    if row.get("title"):
        entry["role"] = row["title"]

    # Per-source last-contact + MAX, capped at today so a future-dated
    # event never wins the flat last_contact (see _max_past_last_contact).
    # ISO date strings sort lexicographically. The by-source breakdown
    # keeps each channel's raw stored date.
    by_source = {}
    for src_key, label in _LAST_CONTACT_SOURCES:
        val = row.get(src_key)
        if val:
            by_source[label] = val
    if by_source:
        last_contact = _max_past_last_contact(by_source.values())
        if last_contact:
            entry["last_contact"] = last_contact
        entry["last_contact_by_source"] = by_source

    # Identifiers, facts, meetings, relationship signal: same sub-queries
    # as person_context, keyed on the resolved URI. Each is independently
    # OPTIONAL so a missing one never drops the payload.
    try:
        ids = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?type ?value WHERE {{\n'
            '  <{uri}> pwg:hasIdentifier ?id .\n'
            '  ?id pwg:identifierType ?type ; pwg:identifierValue ?value .\n'
            '}}'.format(ns=PWG_NS, uri=person_uri)
        )
        if ids:
            entry["identifiers"] = [
                {"type": i["type"], "value": i["value"]} for i in ids
            ]
            # Surface the first phone / email at top level for the
            # PersonDetail card (it decodes flat `phone` / `email`).
            for ident in ids:
                itype = (ident.get("type") or "").lower()
                if itype == "phone" and "phone" not in entry:
                    entry["phone"] = ident["value"]
                elif itype == "email" and "email" not in entry:
                    entry["email"] = ident["value"]

        facts = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?text WHERE {{\n'
            '  ?f a pwg:PersonFact ; pwg:aboutPerson <{uri}> ; pwg:factText ?text .\n'
            '  FILTER NOT EXISTS {{ ?f pwg:validTo ?end }}\n'
            '}}'.format(ns=PWG_NS, uri=person_uri)
        )
        if facts:
            entry["facts"] = [f["text"] for f in facts]

        meetings = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?summary ?date ?location WHERE {{\n'
            '  ?m a pwg:Meeting ; pwg:meetingAttendee <{uri}> ; pwg:meetingSummary ?summary .\n'
            '  OPTIONAL {{ ?m pwg:meetingDate ?date }}\n'
            '  OPTIONAL {{ ?m pwg:meetingLocation ?location }}\n'
            '}} ORDER BY DESC(?date) LIMIT 10'.format(ns=PWG_NS, uri=person_uri)
        )
        if meetings:
            entry["meetings"] = [{
                "summary": m["summary"],
                "date": m.get("date", "")[:10] if m.get("date") else "",
                "location": m.get("location", ""),
            } for m in meetings]

        signals = _sparql_select(
            'SELECT ?warmth ?trust ?observedAt WHERE {{\n'
            '  ?signal <urn:pwg:about> ?person .\n'
            '  ?signal <urn:pwg:warmth> ?warmth .\n'
            '  ?signal <urn:pwg:trust> ?trust .\n'
            '  ?signal <urn:pwg:observedAt> ?observedAt .\n'
            '  FILTER(CONTAINS(STR(?person), "{slug}"))\n'
            '}} ORDER BY DESC(?observedAt) LIMIT 1'.format(slug=slug)
        )
        if signals:
            sig = signals[0]
            entry["relationship_signal"] = {
                "warmth": sig.get("warmth", ""),
                "trust": sig.get("trust", ""),
                "observed_at": sig.get("observedAt", ""),
            }
    except Exception as exc:
        # The core attributes already succeeded; treat a sub-query
        # failure as a partial degrade rather than failing the card.
        entry.setdefault("degraded", True)
        entry.setdefault("reason", f"enrichment_subquery_failed: {exc}")

    # Best-effort Qdrant top-up: phone / email if the graph lacked them,
    # and the precomputed last_contact display string. A Qdrant failure
    # is swallowed (the graph data is the source of truth here).
    try:
        body = json.dumps({
            "filter": {"must": [
                {"key": "person_uri", "match": {"value": person_uri}}
            ]},
            "limit": 1,
            "with_payload": True,
            "with_vector": False,
        }).encode()
        req = urllib.request.Request(
            QDRANT_URL.rstrip("/") + "/collections/people/points/scroll",
            data=body,
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            qresult = json.loads(resp.read())
        points = qresult.get("result", {}).get("points", [])
        if points:
            payload = points[0].get("payload", {})
            if payload.get("phones") and "phone" not in entry:
                phones = payload["phones"]
                entry["phone"] = phones[0] if isinstance(phones, list) else phones
            if payload.get("emails") and "email" not in entry:
                emails = payload["emails"]
                entry["email"] = emails[0] if isinstance(emails, list) else emails
            if payload.get("last_contact") and "last_contact" not in entry:
                entry["last_contact"] = payload["last_contact"]
    except Exception:
        # Qdrant unreachable / collection missing on a fresh box: the
        # graph-derived fields stand on their own. Do not degrade the
        # response over an optional top-up.
        pass

    out = {"slug": slug, "found": True, "person": entry}
    # Flatten the person fields to the envelope top-level too, matching
    # person_context's dual-shape contract so a client decoding either
    # the nested or flat form works.
    for k, v in entry.items():
        if k not in ("slug", "found", "person"):
            out[k] = v
    return out, 200


def people_list(sort=None, ceiling=10000):
    """List every person in the Qdrant `people` collection for the Hub.

    The Hub dashboard People page reads this; its header count is the length
    of `people`, so we return the FULL set (paginated scroll, not a top-N) and
    let the page count it. Same `contact_type == "person"` filter as
    people_search / people_stale, so the Hub count matches the wiki People
    count and the iOS People tab once #600 hydrate has populated Qdrant.

    Counts + light rows only (id, name, role, recency); no facts or notes
    cross this boundary. A missing `people` collection (fresh box, contacts
    not yet granted) is the empty-by-design path: return an empty list
    calmly, NOT an error, so all three surfaces show a calm empty-state.
    """
    points = []
    next_offset = None
    page = 256
    try:
        while len(points) < ceiling:
            body = {
                "filter": {
                    "must": [
                        {"key": "contact_type", "match": {"value": "person"}},
                    ]
                },
                "limit": page,
                "with_payload": True,
                "with_vector": False,
            }
            if next_offset is not None:
                body["offset"] = next_offset
            data = json.dumps(body).encode()
            req = urllib.request.Request(
                QDRANT_URL.rstrip("/") + "/collections/people/points/scroll",
                data=data,
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                result = json.loads(resp.read()).get("result", {}) or {}
            batch = result.get("points", []) or []
            points.extend(batch)
            next_offset = result.get("next_page_offset")
            if not batch or not next_offset:
                break
    except Exception as exc:
        # A 404 here means the `people` collection does not exist yet, which is
        # the empty-by-design path (no contacts granted). Report it calmly, not
        # as a fault. Anything else (Qdrant down, etc.) is a genuine degrade.
        if getattr(exc, "code", None) == 404:
            return {"people": [], "total": 0}
        return {"people": [], "total": 0, "degraded": True,
                "reason": str(exc), "error": str(exc)}

    # Batched identifier join (one query, grouped in Python -- never N+1).
    # The Qdrant payload already carries phones/emails for CardDAV-sourced
    # points, but LinkedIn URLs (and identifiers for non-CardDAV people, e.g.
    # email/LinkedIn-only contacts) live only in Oxigraph as pwg:hasIdentifier
    # nodes. Pull every identifier in a single SELECT and group by person URI;
    # a degraded Oxigraph just leaves the payload values untouched.
    ident_by_uri = {}
    try:
        ident_rows = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?person ?type ?value WHERE {{\n'
            '  ?person pwg:hasIdentifier ?id .\n'
            '  ?id pwg:identifierType ?type ; pwg:identifierValue ?value .\n'
            '}}'.format(ns=PWG_NS)
        )
        for r in ident_rows:
            uri = r.get("person")
            typ = (r.get("type") or "").strip()
            val = (r.get("value") or "").strip()
            if not uri or typ not in ("phone", "email", "linkedin_url") or not val:
                continue
            bucket = ident_by_uri.setdefault(
                uri, {"phone": [], "email": [], "linkedin_url": []}
            )
            if val not in bucket[typ]:
                bucket[typ].append(val)
    except Exception:
        # Identifiers are enrichment, not load-bearing: a degraded Oxigraph
        # must not blank the People list. Fall back to payload-only contact info.
        ident_by_uri = {}

    # Merged-away records (M-3a): graph dedup is correct -- a deduped Person
    # node carries a pwg:mergedInto tombstone in Oxigraph pointing at the
    # surviving node. But the Qdrant `people` collection still holds a point
    # for every merged-away record (different ID space), so without this
    # filter all ~996 of them render as live duplicate rows in the Hub People
    # tab. Fetch the tombstone set once and skip any point whose person_uri is
    # in it. A degraded Oxigraph yields an empty set -> no filtering, which
    # calmly preserves the list rather than blanking it (same posture as the
    # identifier join above).
    merged_away_uris = set()
    try:
        for r in _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?person WHERE {{ ?person pwg:mergedInto ?_target }}'.format(ns=PWG_NS)
        ):
            u = (r.get("person") or "").strip()
            if u:
                merged_away_uris.add(u)
    except Exception:
        merged_away_uris = set()

    people = []
    for pt in points:
        p = pt.get("payload", {}) or {}
        name = p.get("display_name") or p.get("name") or ""
        if not name:
            continue
        # Drop merged-away records: their Qdrant point lingers but the graph
        # has tombstoned the node (pwg:mergedInto). The surviving node has no
        # tombstone and is kept. Only filter when we actually have a uri to
        # match -- a point with no person_uri predates merge and is left alone.
        if merged_away_uris and (p.get("person_uri") or "") in merged_away_uris:
            continue
        # slug + wiki_url let the Hub People row click through to the
        # person's wiki page. Same slug derivation and WIKI_BASE_URL the
        # sibling readers (people_search, people_recent, people_stale)
        # already emit, so every people surface links the same way.
        slug = _wiki_slug(name)
        row = {
            "id": str(pt.get("id")),
            "name": name,
            "slug": slug,
            "wiki_url": f"{WIKI_BASE_URL}/People/{slug}/",
        }
        role = p.get("job_title") or p.get("organization") or ""
        if role:
            row["role"] = role
        lc_ts = p.get("last_contact_ts", 0) or 0
        recency = _recency_label(lc_ts)
        if recency:
            row["recency"] = recency
        row["_lc_ts"] = lc_ts

        # Sort keys -- prefer the parsed given/family name, fall back to a
        # split of the display name so LinkedIn/email-only people still sort.
        given = (p.get("given_name") or "").strip()
        family = (p.get("family_name") or "").strip()
        if not given and not family:
            parts = name.strip().split()
            given = parts[0] if parts else ""
            family = parts[-1] if len(parts) > 1 else ""
        row["_first"] = given.casefold()
        row["_last"] = (family or given).casefold()

        # Contact fields: payload first (CardDAV), Oxigraph identifiers backfill.
        uri = p.get("person_uri") or ""
        ids = ident_by_uri.get(uri, {})
        phones = [x for x in (p.get("phones") or []) if x]
        emails = [x for x in (p.get("emails") or []) if x]
        for x in ids.get("phone", []):
            if x not in phones:
                phones.append(x)
        for x in ids.get("email", []):
            if x not in emails:
                emails.append(x)
        linkedin = ids.get("linkedin_url", [])
        if phones:
            row["phone"] = phones[0]
        if emails:
            row["email"] = emails[0]
        if linkedin:
            row["linkedin"] = linkedin[0]

        people.append(row)

    reverse = False
    key = None
    if sort == "recency":
        key = lambda r: r.get("_lc_ts", 0)
        reverse = True
    elif sort == "firstname":
        key = lambda r: (r.get("_first", ""), r.get("_last", ""))
    elif sort == "lastname":
        key = lambda r: (r.get("_last", ""), r.get("_first", ""))
    if key is not None:
        people.sort(key=key, reverse=reverse)

    # Per-row jump letter for the A|B|C rail (alphabetical sorts only). The
    # client renders the rail from these and scrolls to the first match.
    for row in people:
        if sort in ("firstname", "lastname"):
            src = row.get("_first" if sort == "firstname" else "_last", "")
            ch = src[:1].upper()
            row["jump"] = ch if "A" <= ch <= "Z" else "#"
        row.pop("_lc_ts", None)
        row.pop("_first", None)
        row.pop("_last", None)
    return {"people": people, "total": len(people)}


def people_recent(days=7, limit=5):
    """Find people with recent meetings (for follow-up suggestions)."""
    from datetime import datetime, timedelta, timezone
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d")
    try:
        rows = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?name ?summary ?date ?location WHERE {{\n'
            '  ?m a pwg:Meeting ; pwg:meetingAttendee ?p ;\n'
            '     pwg:meetingDate ?date .\n'
            '  ?p pwg:displayName ?name .\n'
            '  OPTIONAL {{ ?m pwg:meetingSummary ?summary }}\n'
            '  OPTIONAL {{ ?m pwg:meetingLocation ?location }}\n'
            '  FILTER(?date >= "{cutoff}")\n'
            '}} ORDER BY DESC(?date) LIMIT {limit}'.format(
                ns=PWG_NS, cutoff=cutoff, limit=limit * 3
            )
        )
    except Exception as exc:
        return {"contacts": [], "degraded": True, "reason": str(exc), "error": str(exc)}

    seen = set()
    contacts = []
    for r in rows:
        name = r.get("name", "")
        if not name or name in seen:
            continue
        if _is_nameless_name(name):
            continue
        seen.add(name)
        contacts.append({
            "name": name,
            "slug": _wiki_slug(name),
            "wiki_url": f"{WIKI_BASE_URL}/People/{_wiki_slug(name)}/",
            "last_meeting": r.get("summary", ""),
            "meeting_date": (r.get("date") or "")[:10],
            "location": r.get("location", ""),
        })
        if len(contacts) >= limit:
            break
    return {"contacts": contacts}


def people_birthdays(days=7):
    """Find contacts with upcoming birthdays."""
    from datetime import datetime, timedelta
    today = datetime.now()
    results = []
    try:
        rows = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?name ?bday WHERE {{\n'
            '  ?p a pwg:Person ; pwg:displayName ?name ; pwg:birthday ?bday .\n'
            '}}'.format(ns=PWG_NS)
        )
    except Exception as exc:
        return {"people": [], "degraded": True, "reason": str(exc), "error": str(exc)}

    for r in rows:
        name = r.get("name", "")
        bday = r.get("bday", "")
        if not name or not bday or len(bday) < 5:
            continue
        # Hide raw-handle "people" (bare phone numbers, WhatsApp JIDs) from the
        # Birthdays surface, same render-time filter the People search / stale /
        # recent endpoints use. Ref #664. The Qdrant point / graph node is never
        # deleted -- only withheld from this listing.
        if _is_nameless_name(name):
            continue
        try:
            # Parse MM-DD or YYYY-MM-DD
            parts = bday.split("-")
            if len(parts) >= 2:
                month = int(parts[-2])
                day = int(parts[-1])
            else:
                continue
            this_year = today.replace(month=month, day=day)
            if this_year < today:
                this_year = this_year.replace(year=today.year + 1)
            days_until = (this_year - today).days
            if 0 <= days_until <= days:
                results.append({
                    "name": name,
                    "slug": _wiki_slug(name),
                    "wiki_url": f"{WIKI_BASE_URL}/People/{_wiki_slug(name)}/",
                    "birthday": f"{month:02d}-{day:02d}",
                    "days_until": days_until,
                })
        except (ValueError, TypeError):
            continue

    results.sort(key=lambda r: r["days_until"])
    # Dedup by name (multiple Oxigraph nodes for same person)
    seen = set()
    deduped = []
    for r in results:
        if r["name"] not in seen:
            seen.add(r["name"])
            deduped.append(r)
    return {"people": deduped}



def fetch_recent_emails(hours=24, limit=20):
    """Fetch recent emails via gws CLI. Returns subjects/snippets only (no body)."""
    query = f"newer_than:{hours}h"
    try:
        params = json.dumps({
            "userId": "me",
            "q": query,
            "maxResults": min(limit, 50),
        })
        result = subprocess.run(
            [GWS_BIN, "gmail", "users", "messages", "list", "--params", params],
            capture_output=True, text=True, timeout=30, env=GWS_ENV,
        )
        if result.returncode != 0:
            return {"emails": [], "count": 0, "hours": hours,
                    "error": result.stderr[:200]}

        data = json.loads(result.stdout)
        messages = data.get("messages", [])

        emails = []
        for msg in messages[:limit]:
            try:
                detail_params = json.dumps({
                    "userId": "me",
                    "id": msg["id"],
                    "format": "metadata",
                    "metadataHeaders": ["Subject", "From", "Date"],
                })
                detail = subprocess.run(
                    [GWS_BIN, "gmail", "users", "messages", "get",
                     "--params", detail_params],
                    capture_output=True, text=True, timeout=15, env=GWS_ENV,
                )
                if detail.returncode != 0:
                    continue

                detail_data = json.loads(detail.stdout)
                headers = {
                    h["name"]: h["value"]
                    for h in detail_data.get("payload", {}).get("headers", [])
                }
                # Extract snippet (safe — no body content)
                snippet = detail_data.get("snippet", "")
                labels = detail_data.get("labelIds", [])

                emails.append({
                    "subject": headers.get("Subject", "(no subject)"),
                    "from": headers.get("From", ""),
                    "date": headers.get("Date", ""),
                    "snippet": snippet[:200],  # Truncate snippets
                    "labels": labels,
                })
            except Exception:
                continue

        return {
            "emails": emails,
            "count": len(emails),
            "hours": hours,
        }
    except Exception as e:
        return {"emails": [], "count": 0, "hours": hours, "error": str(e)}



def api_suggestions():
    """Composite: upcoming birthdays + stale contacts + recent meetings.

    Useful as a single 'what should I do today' endpoint for the iOS
    companion and for quick dashboard summaries. Each section is
    best-effort; partial failures return a partial payload with
    per-section errors.
    """
    out = {"birthdays": [], "stale_contacts": [], "recent_meetings": []}
    try:
        out["birthdays"] = people_birthdays(days=14).get("people", [])[:5]
    except Exception as exc:
        out["birthdays_error"] = str(exc)
    try:
        out["stale_contacts"] = people_stale(months=3, limit=5).get("contacts", [])
    except Exception as exc:
        out["stale_error"] = str(exc)
    try:
        out["recent_meetings"] = people_recent(days=14, limit=5).get("contacts", [])
    except Exception as exc:
        out["recent_error"] = str(exc)
    # CM031 PWG Companion's SuggestionsResponse keys on `reconnect` and
    # `follow_up`. Marvin / wiki tooling uses the legacy `stale_contacts`
    # and `recent_meetings` keys. Surface both so neither client has to
    # change. Aliases share the same list reference – cheap, no copy.
    out["reconnect"] = out["stale_contacts"]
    out["follow_up"] = out["recent_meetings"]
    return out


def _timeline_from_graph(past_days=730, limit=200):
    """Historic timeline rows from the People Graph - one entry PER MEETING.

    The Timeline is mainly a HISTORIC view, so its primary source is the graph
    (pwg:Meeting nodes ingested from the user's calendar history at install),
    NOT the live calendar API - that only looks forward and is usually
    unconfigured on a fresh customer box. One row per meeting (collapsing
    attendees with GROUP_CONCAT) over a wide window (default ~2 years), newest
    first. Per-meeting collapse also avoids the timeline double-entry bug
    (#663 / BW-3) at the source instead of post-hoc in Python.

    Returns ``(rows, error)`` - ``error`` is a string when the graph query
    failed (so the caller can surface a degraded marker), else None.
    """
    from datetime import datetime, timedelta, timezone
    cutoff = (datetime.now(timezone.utc)
              - timedelta(days=max(1, past_days))).strftime("%Y-%m-%d")
    try:
        rows = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?m ?date (SAMPLE(?summary) AS ?summary) '
            '(SAMPLE(?location) AS ?location) '
            '(GROUP_CONCAT(DISTINCT ?name; SEPARATOR="|") AS ?attendees)\n'
            'WHERE {{\n'
            '  ?m a pwg:Meeting ; pwg:meetingDate ?date .\n'
            '  OPTIONAL {{ ?m pwg:meetingAttendee ?p . ?p pwg:displayName ?name }}\n'
            '  OPTIONAL {{ ?m pwg:meetingSummary ?summary }}\n'
            '  OPTIONAL {{ ?m pwg:meetingLocation ?location }}\n'
            '  FILTER(?date >= "{cutoff}")\n'
            '}} GROUP BY ?m ?date ORDER BY DESC(?date) LIMIT {limit}'.format(
                ns=PWG_NS, cutoff=cutoff, limit=max(1, limit)
            )
        )
    except Exception as exc:
        return [], str(exc)

    out = []
    for r in rows:
        attendees_raw = r.get("attendees", "") or ""
        participants = [a for a in attendees_raw.split("|")
                        if a and not _is_nameless_name(a)]
        out.append({
            "kind": "meeting",
            "date": (r.get("date") or "")[:10],
            "summary": r.get("summary", ""),
            "participants": participants,
            "location": r.get("location", ""),
        })
    return out, None


def api_timeline(days=7, past_days=730, limit=200):
    """Mainly-historic life timeline: past meetings/events + a short forward look.

    The Timeline is a HISTORIC view first. Its backbone is the People Graph
    (meeting/event nodes ingested from the user's calendar history at install),
    queried back ``past_days`` days (default ~2 years) - NOT the live calendar
    API, which only looks forward and is usually unconfigured on a fresh box.
    The live calendar is still queried for the next ``days`` days as a
    best-effort "upcoming" strip where it is configured.

    Output shape: {items: [{kind, date, summary, participants?, location?}],
                   entries: [...CM031 shape...], days, past_days, limit, count}
    Rows are newest-first and capped at ``limit``.
    """
    items = []

    # Future: calendar events
    try:
        cal_events = []
        try:
            result = subprocess.run(
                [ICAL_SCRIPT, str(days)],
                capture_output=True, text=True, timeout=30,
            )
            cal_events.extend(parse_ical_output(result.stdout))
        except Exception:
            pass
        try:
            cal_events.extend(query_google_calendar(days))
        except Exception:
            pass
        for e in cal_events:
            # Skip personal-admin all-day, attendee-less entries (holidays,
            # deliveries, reminders) so "This Week" shows meetings only. See #v152.
            if _is_personal_admin_event(e):
                continue
            items.append({
                "kind": "calendar",
                "date": e.get("start", ""),
                "summary": e.get("summary", ""),
                "location": e.get("location", ""),
                "attendees": e.get("attendees", []),
            })
    except Exception as exc:
        items.append({"kind": "calendar_error", "error": str(exc)})

    # Past (the main event): historic meetings/events from the graph, one row
    # per meeting, back `past_days` days. This is what makes the Timeline a
    # historic view rather than a 7-day-forward calendar peek. The graph query
    # (GROUP BY ?m) collapses attendees at the source, so the per-meeting
    # double-entry (#663 / BW-3) cannot recur.
    past_rows, past_err = _timeline_from_graph(past_days=past_days, limit=limit)
    if past_err is not None:
        items.append({"kind": "meeting_error", "error": past_err})
    else:
        items.extend(past_rows)

    # Newest first (it is mainly a historic timeline), then cap.
    items.sort(key=lambda i: i.get("date") or "", reverse=True)
    if limit:
        items = items[:limit]

    # CM031 PWG Companion decodes `entries: [{type, timestamp, title,
    # subtitle, attendees}]`. Map our `items: [{kind, date, summary,
    # location, attendees, participants}]` shape into that vocabulary
    # alongside the legacy field so both clients work. `timestamp` is
    # emitted as ISO-8601 where we can parse the existing date string.
    entries = []
    for it in items:
        kind = it.get("kind") or ""
        if kind in ("calendar_error", "meeting_error"):
            # Surface but skip – CM031 does not render error sentinels.
            continue
        entry_type = "meeting" if kind == "meeting" else "calendar"
        raw_date = it.get("date") or ""
        timestamp = _to_iso8601(raw_date)
        # Attendee names come in two shapes:
        #   calendar items: list-of-dicts {name?, email?, role?}
        #   meeting items: a `participants` list-of-strings
        attendee_names = []
        if isinstance(it.get("participants"), list):
            attendee_names = [str(p) for p in it["participants"] if p]
        elif isinstance(it.get("attendees"), list):
            for a in it["attendees"]:
                if isinstance(a, dict):
                    nm = a.get("name") or a.get("email") or ""
                    if nm:
                        attendee_names.append(nm)
                elif isinstance(a, str):
                    attendee_names.append(a)
        entries.append({
            "type": entry_type,
            "timestamp": timestamp,
            "title": it.get("summary") or "",
            "subtitle": it.get("location") or "",
            "attendees": attendee_names,
        })

    return {
        "items": items,
        "entries": entries,
        "days": days,
        "past_days": past_days,
        "limit": limit,
        "count": len(items),
    }


def api_ingest_ios(payload):
    """Accept a batch of items from the CM031 iOS companion app.

    Payload shape: {items: [{kind, text, timestamp?, metadata?}, ...]}

    Writes the batch as a JSON line to INGEST_DIR for downstream
    processing. Keeps the API dumb — enrichment happens elsewhere.
    """
    import time
    import uuid

    if not isinstance(payload, dict):
        return {"error": "body must be a JSON object"}, 400

    items = payload.get("items")
    if items is None:
        # Alias for iOS PWGUploadService.UploadBatch, which sends `points`.
        # Wire-shape contract (F-10b, 2026-05-27): server accepts either key.
        items = payload.get("points")
    if not isinstance(items, list):
        return {"error": "items must be an array"}, 400

    if len(items) > 1000:
        return {"error": "too many items in one batch (max 1000)"}, 400

    try:
        os.makedirs(INGEST_DIR, exist_ok=True)
        batch_id = str(uuid.uuid4())
        ts = int(time.time())
        path = os.path.join(INGEST_DIR, f"ios-{ts}-{batch_id[:8]}.jsonl")
        record = {
            "batch_id": batch_id,
            "received_at": ts,
            "source": "ios",
            "items": items,
        }
        with open(path, "w", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")
        # `accepted` mirrors `item_count` for the iOS UploadResult decoder
        # (F-10, 2026-05-27). Keep both keys for downstream compatibility.
        return {
            "ok": True,
            "batch_id": batch_id,
            "item_count": len(items),
            "accepted": len(items),
            "path": path,
        }, 200
    except Exception as exc:
        return {"error": str(exc)}, 500


def api_subscription_receipt(payload):
    """Accept a StoreKit receipt push from the iOS Companion (G1).

    Payload shape (from CM031's SubscriptionService): ``{"receipt_b64":
    "<base64 receipt>", "expires_at": "<ISO-8601 datetime>"}``.

    On a valid body the handler persists state via
    ``subscription_gate.refresh_from_companion`` and replies with the
    resulting status dict (``{"status": "active|grace|inactive"}``).

    Apple-restraint posture: the Hub never forwards the receipt to
    Apple's verifyReceipt endpoint. Server-side StoreKit 2 validation is
    the Companion's responsibility; the Hub trusts the paired-channel
    handshake (see install-time pairing) and uses the receipt only as a
    support breadcrumb in the on-disk state file.

    Returns (body, status_code) for the do_POST dispatcher.
    """
    # subscription_gate is lazily imported so missing-helper installs (or
    # very old vendor snapshots) cannot break unrelated POST routes at
    # module load time.
    try:
        # The vendored module sits alongside ical-server.py; the do_POST
        # dispatcher runs with the assistant_api/ directory on sys.path
        # already (because the file imports sibling modules elsewhere).
        import subscription_gate  # type: ignore[import-not-found]
    except ImportError as exc:
        return {"error": f"subscription_gate unavailable: {exc}"}, 500

    if not isinstance(payload, dict):
        return {"error": "body must be a JSON object"}, 400

    receipt_b64 = payload.get("receipt_b64")
    expires_at = payload.get("expires_at")

    if not isinstance(receipt_b64, str) or not receipt_b64.strip():
        return {"error": "receipt_b64 must be a non-empty string"}, 400

    if not isinstance(expires_at, str) or not expires_at.strip():
        return {"error": "expires_at must be an ISO-8601 string"}, 400

    # Validate expires_at parses as ISO-8601. Mirrors the parse rule used
    # by subscription_gate._parse_iso so we 400 before writing state.
    try:
        datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return {"error": "expires_at is not a valid ISO-8601 datetime"}, 400

    try:
        subscription_gate.refresh_from_companion(receipt_b64, expires_at)
        status = subscription_gate.state_dict().get("status", "inactive")
        return {"status": status}, 200
    except Exception as exc:
        return {"error": f"refresh failed: {exc}"}, 500


# ── Hub health helpers ───────────────────────────────────────────────
# Each helper returns a (key, result_dict) tuple so the parallel runner
# can fan out work and collect named results. Every helper is wrapped in
# a blanket try/except – a misbehaving dependency must NEVER propagate
# up to the endpoint handler.


def _read_sync_marker(path):
    """Read raw stripped contents from a marker file.

    Returns the stripped contents if the file exists and is readable,
    otherwise None. Never raises.

    NOTE: this helper is intentionally permissive – it is also used by
    `_hub_queue_depth()` which writes integer text, not ISO-8601. For
    callers that want an ISO-8601 timestamp specifically, use
    `_read_iso8601_marker()` which validates + normalises the value.
    """
    try:
        if path.exists():
            text = path.read_text(encoding="utf-8", errors="replace").strip()
            return text or None
    except Exception:
        return None
    return None


def _read_iso8601_marker(path):
    """Read and validate an ISO-8601 UTC timestamp from a marker file.

    F-3 (2026-05-27): hardens the iOS-facing health surface against
    malformed marker contents. A garbled marker file now returns None
    rather than leaking an unparseable string back to the Companion
    (which would then fail JSON-decoding into Date).

    Returns a normalised "%Y-%m-%dT%H:%M:%SZ" string on success, or
    None if the file is missing, empty, unreadable, or contains a value
    that is not a recognised ISO-8601 form. Never raises.
    """
    raw = _read_sync_marker(path)
    if not raw:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%SZ", "%Y%m%dT%H%M%S"):
        try:
            dt = datetime.strptime(raw, fmt)
        except ValueError:
            continue
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return None


def api_recording_active():
    """Read the current recording state for the CM031 Live Activity.

    Wire contract (shared with the CM042 producer + CM031 consumer):

    - State file path: ``RECORDING_STATE_FILE``
      (default ``~/.ostler/recording_state.json``).
    - File missing → ``{"recording": null}``.
    - File mtime older than ``RECORDING_STALE_SECONDS`` (default 30s) →
      ``{"recording": null}``. We treat a stale heartbeat as a crashed
      producer rather than a live recording.
    - Malformed JSON, missing ``meeting_id`` / ``started_at`` / ``state``,
      or an unknown ``state`` value → ``{"recording": null}`` (logged at
      WARN, never 5xx).
    - Active body shape:

      ``{
          "recording": {
            "meeting_id": "<ULID>",
            "started_at": "<RFC3339 UTC>",
            "state": "recording" | "processing" | "transcript_saved" | "error",
            "hub_machine_name": "<string>",
            "participant_count": <int>?,
            "consent_basis": "one_party" | "all_party" | null,
            "jurisdiction": "<ISO>" | null
          }
      }``

    Read-only. Never raises. Returns a JSON-serialisable dict in every
    branch so the handler can wrap it in a 200 unconditionally.
    """
    from datetime import datetime, timezone

    # File missing → null (not a 404; the iOS Live Activity treats null
    # as "collapse the surface"). Use os.stat so we can read mtime in
    # the same syscall block.
    try:
        st = RECORDING_STATE_FILE.stat()
    except FileNotFoundError:
        return {"recording": None}
    except OSError as exc:
        print(
            f"WARNING: recording state stat failed at "
            f"{RECORDING_STATE_FILE}: {exc}",
            file=sys.stderr,
            flush=True,
        )
        return {"recording": None}

    # Staleness check. The producer is expected to heartbeat by
    # re-writing the file (atomic .tmp + rename bumps mtime) every few
    # seconds while the capture is active. A mtime older than the
    # staleness window means the producer is dead or stuck and the iOS
    # Live Activity should collapse.
    now_utc = datetime.now(timezone.utc)
    try:
        mtime = datetime.fromtimestamp(st.st_mtime, tz=timezone.utc)
    except (OverflowError, OSError, ValueError):
        return {"recording": None}
    age_seconds = (now_utc - mtime).total_seconds()
    if age_seconds > RECORDING_STALE_SECONDS:
        return {"recording": None}

    # File present and fresh: parse + validate. Any structural problem
    # demotes to null so the consumer never sees half-populated bodies.
    try:
        raw = RECORDING_STATE_FILE.read_text(encoding="utf-8")
    except OSError as exc:
        print(
            f"WARNING: recording state read failed at "
            f"{RECORDING_STATE_FILE}: {exc}",
            file=sys.stderr,
            flush=True,
        )
        return {"recording": None}

    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(
            f"WARNING: recording state JSON malformed at "
            f"{RECORDING_STATE_FILE}: {exc}",
            file=sys.stderr,
            flush=True,
        )
        return {"recording": None}

    if not isinstance(data, dict):
        print(
            f"WARNING: recording state top-level not an object at "
            f"{RECORDING_STATE_FILE}",
            file=sys.stderr,
            flush=True,
        )
        return {"recording": None}

    # Required fields. The producer is contractually obliged to emit
    # all three on every write; if any is missing we treat the whole
    # payload as unusable rather than guessing.
    meeting_id = data.get("meeting_id")
    started_at = data.get("started_at")
    state = data.get("state")
    if not (
        isinstance(meeting_id, str) and meeting_id
        and isinstance(started_at, str) and started_at
        and isinstance(state, str) and state in RECORDING_VALID_STATES
    ):
        print(
            f"WARNING: recording state missing or invalid required "
            f"fields at {RECORDING_STATE_FILE}: "
            f"meeting_id={type(meeting_id).__name__} "
            f"started_at={type(started_at).__name__} "
            f"state={state!r}",
            file=sys.stderr,
            flush=True,
        )
        return {"recording": None}

    # Optional fields. Coerce to None on a type mismatch rather than
    # propagating wrong-shape values to iOS, which would force a
    # Codable failure on the consumer side.
    hub_machine_name = data.get("hub_machine_name")
    if not isinstance(hub_machine_name, str):
        hub_machine_name = ""

    participant_count = data.get("participant_count")
    if not isinstance(participant_count, int) or isinstance(participant_count, bool):
        # bool is a subclass of int in Python; reject it explicitly so
        # the iOS Codable Int decode does not silently take True/False.
        participant_count = None

    consent_basis = data.get("consent_basis")
    if consent_basis is not None and consent_basis not in RECORDING_VALID_CONSENT:
        consent_basis = None

    jurisdiction = data.get("jurisdiction")
    if jurisdiction is not None and (
        not isinstance(jurisdiction, str) or not jurisdiction
    ):
        jurisdiction = None

    recording = {
        "meeting_id": meeting_id,
        "started_at": started_at,
        "state": state,
        "hub_machine_name": hub_machine_name,
        "participant_count": participant_count,
        "consent_basis": consent_basis,
        "jurisdiction": jurisdiction,
    }
    return {"recording": recording}


def _hub_check_zeroclaw():
    """Is ZeroClaw running? Uses pgrep rather than parsing ps output.

    Returns {"healthy": bool, "pid": int?} or {"healthy": False, "error": str}.
    """
    try:
        result = subprocess.run(
            ["pgrep", "-x", ZEROCLAW_PROCESS_NAME],
            capture_output=True, text=True,
            timeout=HUB_CHECK_TIMEOUT_SECONDS,
        )
        if result.returncode == 0 and result.stdout.strip():
            first_pid = result.stdout.strip().splitlines()[0]
            try:
                return {"healthy": True, "pid": int(first_pid)}
            except ValueError:
                return {"healthy": True}
        return {"healthy": False, "error": "process not found"}
    except subprocess.TimeoutExpired:
        return {"healthy": False, "error": "timeout"}
    except FileNotFoundError:
        return {"healthy": False, "error": "pgrep unavailable"}
    except Exception as exc:
        return {"healthy": False, "error": str(exc)[:80]}


def _hub_check_ollama():
    """Ping Ollama /api/tags. Reports the first model name if any."""
    url = OLLAMA_URL.rstrip("/") + "/api/tags"
    try:
        with urllib.request.urlopen(
            url, timeout=HUB_CHECK_TIMEOUT_SECONDS
        ) as resp:
            if resp.status != 200:
                return {"healthy": False, "error": f"http {resp.status}"}
            try:
                data = json.loads(resp.read())
            except (ValueError, json.JSONDecodeError):
                return {"healthy": True}
            models = data.get("models") or []
            first = ""
            if models and isinstance(models[0], dict):
                first = models[0].get("name") or models[0].get("model") or ""
            out = {"healthy": True}
            if first:
                out["model"] = first
            return out
    except Exception as exc:
        # urllib raises socket.timeout as URLError("timed out") on 3.10+;
        # surface that consistently.
        msg = str(exc)
        if "timed out" in msg.lower() or "timeout" in msg.lower():
            return {"healthy": False, "error": "timeout"}
        return {"healthy": False, "error": msg[:80]}


def _hub_check_pwg():
    """Count running Docker containers. Uses `docker ps -q`.

    A container count below the expected number flags the service as
    unhealthy but still reports the delta so the iOS side can show a
    helpful tooltip ("7 of 9 services up").
    """
    try:
        result = subprocess.run(
            ["docker", "ps", "-q"],
            capture_output=True, text=True,
            timeout=HUB_CHECK_TIMEOUT_SECONDS,
        )
        if result.returncode != 0:
            err = (result.stderr or "").strip()[:80] or "docker ps failed"
            return {
                "healthy": False,
                "containers_up": 0,
                "containers_expected": PWG_EXPECTED_CONTAINERS,
                "error": err,
            }
        up = len([line for line in result.stdout.splitlines() if line.strip()])
        return {
            "healthy": up >= PWG_EXPECTED_CONTAINERS,
            "containers_up": up,
            "containers_expected": PWG_EXPECTED_CONTAINERS,
        }
    except subprocess.TimeoutExpired:
        return {
            "healthy": False,
            "containers_up": 0,
            "containers_expected": PWG_EXPECTED_CONTAINERS,
            "error": "timeout",
        }
    except FileNotFoundError:
        return {
            "healthy": False,
            "containers_up": 0,
            "containers_expected": PWG_EXPECTED_CONTAINERS,
            "error": "docker not installed",
        }
    except Exception as exc:
        return {
            "healthy": False,
            "containers_up": 0,
            "containers_expected": PWG_EXPECTED_CONTAINERS,
            "error": str(exc)[:80],
        }


def _hub_check_caldav():
    """Report the last CalDAV refresh timestamp from the sync marker.

    Absence of a marker is treated as unhealthy but not an error – fresh
    installs have never synced.
    """
    ts = _read_iso8601_marker(CALDAV_LAST_REFRESH_FILE)
    if ts:
        return {"healthy": True, "last_refresh": ts}
    return {"healthy": False, "last_refresh": None, "error": "no refresh recorded"}


def _hub_power_state():
    """Parse `pmset -g batt` to classify power source.

    Returns "ac" | "battery" | "unknown". Never raises.
    """
    try:
        result = subprocess.run(
            ["pmset", "-g", "batt"],
            capture_output=True, text=True,
            timeout=HUB_CHECK_TIMEOUT_SECONDS,
        )
        if result.returncode != 0:
            return "unknown"
        text = result.stdout.lower()
        if "'ac power'" in text or "ac power" in text:
            return "ac"
        if "'battery power'" in text or "battery power" in text:
            return "battery"
        return "unknown"
    except Exception:
        return "unknown"


def _hub_queue_depth():
    """Read pending Marvin actions from the catch-up replay marker file.

    ZeroClaw does not currently expose a queryable endpoint for this, so
    v1 reads from an on-disk marker written by the catch-up path. Missing
    or unreadable file returns 0 (treat as empty queue). See TODO near
    QUEUE_DEPTH_FILE for follow-up.
    """
    raw = _read_sync_marker(QUEUE_DEPTH_FILE)
    if raw is None:
        return 0
    try:
        value = int(raw)
        return value if value >= 0 else 0
    except (TypeError, ValueError):
        return 0


# Map from unhealthy service to features unavailable while that service
# is down. Keep this centralised so the iOS side can rely on a stable
# vocabulary and we can grow it without chasing callers.
_DEGRADED_FEATURE_MAP = {
    "ollama":   ["assistant_chat", "it_guy"],
    "zeroclaw": ["assistant_chat", "it_guy", "email_triage"],
    "pwg":      ["people_search", "timeline", "wiki_live"],
    "caldav":   ["calendar_live"],
}


def _compute_degraded_features(services):
    """Collect the union of features unavailable given which services are down."""
    features = []
    seen = set()
    for name, status in services.items():
        if status.get("healthy"):
            continue
        for feat in _DEGRADED_FEATURE_MAP.get(name, []):
            if feat not in seen:
                seen.add(feat)
                features.append(feat)
    return features


def api_hub_health():
    """Compose the Hub health payload for the iOS Companion pill.

    Contract: HR015/HUB_PORTABILITY_PLAN.md "Health endpoint contract".
    Target: ≤500 ms end-to-end, ≤2 s per service, never raises.
    """
    from concurrent.futures import ThreadPoolExecutor, TimeoutError as FuturesTimeout

    services = {}
    checks = {
        "zeroclaw": _hub_check_zeroclaw,
        "ollama":   _hub_check_ollama,
        "pwg":      _hub_check_pwg,
        "caldav":   _hub_check_caldav,
    }

    # Run in parallel – one slow check must not drag the others.
    # We deliberately do NOT use `with ThreadPoolExecutor(...) as pool`
    # because its __exit__ calls shutdown(wait=True) and would block on
    # any misbehaving check that ignores our per-future deadline. Daemon
    # threads + wait=False means a truly-hung check becomes orphaned
    # (best-effort) rather than blocking the HTTP response.
    pool = ThreadPoolExecutor(max_workers=len(checks))
    try:
        futures = {name: pool.submit(fn) for name, fn in checks.items()}
        # Outer bound is generous; individual checks time out internally.
        deadline = HUB_CHECK_TIMEOUT_SECONDS + 0.5
        for name, fut in futures.items():
            try:
                services[name] = fut.result(timeout=deadline)
            except FuturesTimeout:
                services[name] = {"healthy": False, "error": "timeout"}
            except Exception as exc:
                services[name] = {"healthy": False, "error": str(exc)[:80]}
    finally:
        # wait=False: don't block on stuck checks. cancel_futures cancels
        # any that haven't started yet (no-op here since max_workers ==
        # len(checks) so everything starts immediately).
        pool.shutdown(wait=False, cancel_futures=True)

    # Power state and queue depth are cheap – run inline.
    try:
        power_state = _hub_power_state()
    except Exception:
        power_state = "unknown"

    try:
        queue_depth = _hub_queue_depth()
    except Exception:
        queue_depth = 0

    # F-3 (2026-05-27): validate + normalise so the Companion never gets a
    # garbled timestamp string back from /api/v1/hub/health.
    last_sync = _read_iso8601_marker(LAST_SYNC_FILE)

    # Derive hub_status from service health + queue depth.
    all_healthy = all(s.get("healthy") for s in services.values())
    any_healthy = any(s.get("healthy") for s in services.values())
    if not any_healthy:
        hub_status = "offline_local"
    elif all_healthy and queue_depth == 0:
        hub_status = "online"
    else:
        # Either catching up (queue non-empty) or some upstream down.
        hub_status = "catching_up"

    return {
        "hub_status": hub_status,
        "hub_version": HUB_VERSION,
        "last_sync": last_sync,
        "queue_depth": queue_depth,
        "power_state": power_state,
        "services": services,
        "degraded_features": _compute_degraded_features(services),
    }


def api_health_detailed():
    """Enhanced /health: check each dependency reachable."""
    import time
    out = {"status": "ok", "timestamp": int(time.time()), "timezone": TIMEZONE, "checks": {}}

    # Qdrant
    try:
        with urllib.request.urlopen(QDRANT_URL.rstrip("/") + "/", timeout=3) as resp:
            out["checks"]["qdrant"] = {"ok": resp.status == 200}
    except Exception as exc:
        out["checks"]["qdrant"] = {"ok": False, "error": str(exc)[:80]}
        out["status"] = "degraded"

    # Oxigraph
    try:
        with urllib.request.urlopen(OXIGRAPH_URL.rstrip("/") + "/", timeout=3) as resp:
            out["checks"]["oxigraph"] = {"ok": resp.status in (200, 404)}
    except Exception as exc:
        out["checks"]["oxigraph"] = {"ok": False, "error": str(exc)[:80]}
        out["status"] = "degraded"

    # Ollama (for embeddings)
    try:
        with urllib.request.urlopen(EMBED_OLLAMA_URL.rstrip("/") + "/", timeout=3) as resp:
            out["checks"]["ollama"] = {"ok": resp.status == 200}
    except Exception as exc:
        out["checks"]["ollama"] = {"ok": False, "error": str(exc)[:80]}
        out["status"] = "degraded"

    # gws CLI
    try:
        r = subprocess.run(
            [GWS_BIN, "--version"],
            capture_output=True, text=True, timeout=3, env=GWS_ENV,
        )
        out["checks"]["gws"] = {"ok": r.returncode == 0}
    except Exception as exc:
        out["checks"]["gws"] = {"ok": False, "error": str(exc)[:80]}
        out["status"] = "degraded"

    # ical-query.sh
    out["checks"]["ical_script"] = {"ok": os.path.exists(ICAL_SCRIPT)}
    if not out["checks"]["ical_script"]["ok"]:
        out["status"] = "degraded"

    return out


# ── Wiki hydration status endpoint (CM044 #624 Part B) ───────────────


def _wiki_people_count():
    """Qdrant people-collection point count, or None if unreachable.

    None (unreachable) is reported as 'pending', never 'done': we must
    not claim contacts are loaded when we cannot actually see them.
    """
    try:
        with urllib.request.urlopen(
            QDRANT_URL.rstrip("/") + "/collections/people", timeout=3
        ) as resp:
            data = json.loads(resp.read())
        return int(data.get("result", {}).get("points_count", 0) or 0)
    except Exception:
        return None


def _wiki_triples_count():
    """Oxigraph total triple count, or None if unreachable."""
    try:
        rows = _sparql_select("SELECT (COUNT(*) AS ?n) WHERE { ?s ?p ?o }")
        return int(rows[0]["n"]) if rows else 0
    except Exception:
        return None


def _wiki_read_compiler_status():
    """Read the wiki compiler's hydration status file (CM044 Part A), or
    None if it is absent or unreadable. This is the cross-process read:
    the file was written by the containerised compiler onto the shared
    host path."""
    try:
        p = Path(WIKI_HYDRATION_STATUS_FILE)
        if not p.is_file():
            return None
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None


def _wiki_eta_seconds(eta_utc):
    """Seconds from now until eta_utc (clamped at 0), or None."""
    if not eta_utc:
        return None
    try:
        eta = datetime.fromisoformat(str(eta_utc).replace("Z", "+00:00"))
        # Derive "now" in the parsed value's own tz so this does not
        # depend on a module-level timezone import.
        now = datetime.now(eta.tzinfo)
        return max(0, int((eta - now).total_seconds()))
    except Exception:
        return None


def _wiki_conversations_progress():
    """Aggregate CM048 conversation processing state.json files."""
    dispatched = completed = failed = running = 0
    try:
        if PROCESSING_DIR.exists():
            for d in PROCESSING_DIR.iterdir():
                sf = d / "state.json"
                if not sf.is_file():
                    continue
                dispatched += 1
                try:
                    st = json.loads(sf.read_text())
                except Exception:
                    # An unreadable state file is in-flight, not a success.
                    running += 1
                    continue
                if st.get("failed_step"):
                    failed += 1
                elif st.get("current_step") == "completed":
                    completed += 1
                else:
                    running += 1
    except Exception:
        pass
    return {"dispatched": dispatched, "completed": completed,
            "failed": failed, "running": running}


def api_hydration_status():
    """Composite first-run hydration status for the wiki panel (CM044 #624).

    Combines live data-source counts (Qdrant people, Oxigraph triples),
    the wiki compiler's own progress file (org / person LLM summaries),
    and the CM048 conversation-processing state into a per-phase view so
    the wiki homepage can show a calm, honest progress panel during the
    first build.

    Honesty rules (no fake spinners, no premature 'done'):
      * an upstream we cannot reach is 'pending', never 'done';
      * an empty Qdrant collection is 'pending', never 'done with 0';
      * a phase is only 'running' when there is real in-flight work
        (total > 0 and not yet finished) -- total == 0 stays 'pending';
      * conversation failures surface as 'needs_attention', not swallowed
        into 'pending'.

    The payload is non-PII by construction: counts, phase keys, states,
    and an ETA only. No names, no content.
    """
    phases = []

    # 1. Contacts -- Qdrant people collection. Binary: the collection
    #    either has points (done) or does not (pending). We cannot know a
    #    target count, so we never report a partial 'running' here.
    people = _wiki_people_count()
    phases.append({
        "key": "contacts",
        "state": "done" if (people or 0) > 0 else "pending",
        "count": people if people is not None else 0,
    })

    # 2. Graph -- Oxigraph triples. Same binary shape as contacts.
    triples = _wiki_triples_count()
    phases.append({
        "key": "graph",
        "state": "done" if (triples or 0) > 0 else "pending",
        "count": triples if triples is not None else 0,
    })

    # 3. AI summaries -- the wiki compiler's own progress file. This is
    #    the slow phase (per-org / per-person LLM prose) and the one that
    #    carries an ETA.
    comp = _wiki_read_compiler_status()
    ai = {"key": "ai_summaries", "done": 0, "total": 0,
          "eta_utc": None, "eta_seconds": None}
    if comp is None:
        ai["state"] = "pending"            # compiler has not started yet
    elif comp.get("complete"):
        ai["state"] = "done"
    else:
        done = int(comp.get("stage_done", 0) or 0)
        total = int(comp.get("stage_total", 0) or 0)
        ai["done"], ai["total"] = done, total
        if total <= 0:
            ai["state"] = "pending"        # no fake spinner with total 0
        else:
            ai["state"] = "running"
            ai["eta_utc"] = comp.get("eta_utc")
            ai["eta_seconds"] = _wiki_eta_seconds(comp.get("eta_utc"))
    phases.append(ai)

    # 4. Conversations -- CM048 processing. Failures surface loudly.
    conv = _wiki_conversations_progress()
    if conv["failed"] > 0:
        conv_state = "needs_attention"
    elif conv["dispatched"] == 0:
        conv_state = "pending"
    elif conv["completed"] >= conv["dispatched"]:
        conv_state = "done"
    else:
        conv_state = "running"
    phases.append({"key": "conversations", "state": conv_state, **conv})

    # Overall. Contacts / graph / ai_summaries gate completion; the
    # conversations phase is surfaced but a pending (zero-dispatched)
    # conversations phase does NOT hold the panel open, because a fresh
    # box may legitimately have no conversations to process. An actively
    # running or failing conversations phase still shows through.
    by_key = {p["key"]: p["state"] for p in phases}
    gating = [by_key["contacts"], by_key["graph"], by_key["ai_summaries"]]
    if any(p["state"] == "needs_attention" for p in phases):
        overall = "needs_attention"
    elif all(s == "done" for s in gating) and by_key["conversations"] != "running":
        overall = "complete"
    elif any(p["state"] in ("running", "done") for p in phases):
        overall = "running"
    else:
        overall = "pending"

    return {
        "overall_state": overall,
        "phases": phases,
        "generated_at": datetime.utcnow().isoformat() + "Z",
    }


# ── BEGIN GRAFT: #51 POST /api/v1/memory/assert (learning-loop write, layer 1) ──
# Grafted VERBATIM from CM041 origin/main assistant_api/ical-server.py (commit 4931c53+).
# Banks user-asserted facts durably into Oxigraph. See do_POST dispatch below.
# USER_ID/USER_URI are required by api_memory_assert (pwg:belongsToUser).

USER_ID = os.environ.get("USER_ID", "").strip()
USER_URI = (
    f"https://pwg.dev/ontology#user_{USER_ID}" if USER_ID else ""
)


_SPARQL_CONTROL_CHARS = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def _sparql_escape_literal(value):
    """Escape a Python string so it is safe inside a double-quoted SPARQL
    literal (``"..."``).

    This is the single load-bearing defence against SPARQL injection on
    the user-asserted-fact write path: every user-supplied string flows
    through here before it is interpolated into a SPARQL UPDATE. A naive
    f-string would let a value such as ``foo" . <x> <y> <z> . #`` break out
    of the literal and inject arbitrary triples.

    Per the SPARQL 1.1 grammar (STRING_LITERAL with ECHAR), inside a
    double-quoted literal we must escape backslash and double-quote, and
    represent the line-structural characters (newline, carriage return,
    tab) with their backslash escapes -- a raw newline is not permitted in
    a single-line STRING_LITERAL. Backslash is escaped FIRST so we do not
    double-process the escapes we introduce afterwards.

    Returns the escaped string (without the surrounding quotes). The caller
    is expected to have already length-checked and control-char-rejected
    the value via ``_validate_asserted_string``; this function is a pure
    escaper and does not validate.
    """
    if value is None:
        return ""
    s = str(value)
    s = s.replace("\\", "\\\\")   # backslash first
    s = s.replace('"', '\\"')     # then double-quote
    s = s.replace("\r", "\\r")
    s = s.replace("\n", "\\n")
    s = s.replace("\t", "\\t")
    return s


def _validate_asserted_string(value, *, field, required=True, max_len=200):
    """Validate + normalise a user-supplied string for the assert path.

    Returns ``(cleaned, None)`` on success or ``(None, error_dict)`` on
    failure, where ``error_dict`` is a ready-to-return ``{"error": ...}``
    body. Rules:

      - Must be a string (or None when ``required`` is False).
      - Stripped of surrounding whitespace.
      - Non-empty when ``required``.
      - No control characters (defence in depth alongside the SPARQL
        escaper -- a control byte is rejected, never silently stripped).
      - No longer than ``max_len`` characters (after stripping).
    """
    if value is None:
        if required:
            return None, {"error": f"'{field}' is required."}
        return "", None
    if not isinstance(value, str):
        return None, {"error": f"'{field}' must be a string."}
    cleaned = value.strip()
    if required and not cleaned:
        return None, {"error": f"'{field}' must not be empty."}
    if len(cleaned) > max_len:
        return None, {
            "error": f"'{field}' too long (max {max_len} characters)."
        }
    if _SPARQL_CONTROL_CHARS.search(cleaned):
        return None, {
            "error": f"'{field}' contains disallowed control characters."
        }
    return cleaned, None


# Wiki-recompile queue lives under ~/.ostler/queue/. The customer install
# (CM051) creates this directory. The daily wiki-recompile LaunchAgent
# picks up `wiki_recompile_pending` and triggers a rebuild.


_ASSERT_STRONG_MATCH_SCORE = float(
    os.environ.get("ASSERT_STRONG_MATCH_SCORE", "0.80")
)
# Two hits are "plausibly the same person" (so we disambiguate rather than
# pick the top one) when the runner-up is within this margin of the leader.
_ASSERT_DISAMBIGUATION_MARGIN = float(
    os.environ.get("ASSERT_DISAMBIGUATION_MARGIN", "0.05")
)


def _mint_person_uri():
    """Mint a new Person URI in the same shape contact_syncer uses.

    contact_syncer mints ``https://pwg.dev/ontology#person_<12-hex>`` from
    a uuid4. We keep that shape so a user-asserted Person node is
    indistinguishable from a contact-synced one downstream. Returns
    ``(person_uri, person_id)``.
    """
    person_id = uuid.uuid4().hex[:12]
    return f"{PWG_NS}person_{person_id}", person_id


def _resolve_person_uri_by_name(name):
    """Return the Person URI whose displayName equals *name*, or None.

    Mirrors the slug-recompute lookup in ``api_people_forget`` but matches
    on the raw displayName so we attach to the exact node people_search
    pointed at. On more-than-one displayName collision we return the first
    -- the disambiguation decision has already been taken upstream by the
    people_search scoring, so any residual tie here is between identical
    display names and either node is an acceptable attach point.
    """
    rows = _sparql_select(
        'PREFIX pwg: <{ns}>\n'
        'SELECT ?person WHERE {{\n'
        '  ?person a pwg:Person ; pwg:displayName "{name}" .\n'
        '}} LIMIT 1'.format(ns=PWG_NS, name=_sparql_escape_literal(name))
    )
    if rows:
        return rows[0].get("person")
    return None


def _candidate_person_uri(result):
    """Return the stable Person URI for a single people_search *result*.

    Prefer the result's OWN ``person_uri`` (carried straight from the Qdrant
    payload, distinct per node) and only fall back to a displayName lookup
    when an older point lacks it.

    Why this matters for the merge loop: ``_resolve_person_uri_by_name`` does
    ``displayName "<name>" LIMIT 1``, so when the duplicates share a display
    name -- exactly the duplicate-contact case (e.g. two nodes that share one
    display name) -- every disambiguation candidate would collapse to the
    SAME uri. ``merge_people`` then de-duplicates those identical uris and
    refuses with "those URIs all point at the same record, nothing to merge",
    so the user can never resolve the duplicate from chat. Keying on the
    per-result ``person_uri`` keeps the candidate uris DISTINCT so the merge
    can actually be enacted.
    """
    if isinstance(result, dict):
        own = result.get("person_uri")
        if own:
            return own
    return _resolve_person_uri_by_name(result.get("name", "") if isinstance(result, dict) else "")


def api_memory_assert(payload, now=None):
    """Handle POST /api/v1/memory/assert.

    Durably bank a user-asserted fact into Oxigraph. ``payload`` is the
    parsed JSON body; ``now`` is an injectable datetime (defaults to
    ``datetime.now(timezone.utc)``) so tests can pin the timestamp.

    Returns ``(body, status)``. See the module-level comment above for the
    behaviour contract. Degrades gracefully (no 5xx) on Oxigraph failure,
    mirroring ``api_people_forget``'s degraded_reasons pattern.
    """
    from datetime import timezone

    if not isinstance(payload, dict):
        return {"error": "Request body must be a JSON object."}, 400

    # 0. USER_ID guard. The asserted fact carries ``pwg:belongsToUser
    # <USER_URI>``. With USER_ID unset, USER_URI is "" and we would emit
    # ``pwg:belongsToUser <>`` -- an empty *relative* IRI that Oxigraph's
    # /update endpoint silently resolves against the request URL, writing
    # garbage provenance. The read path (api_memory_list) already guards on
    # USER_URI and degrades; the WRITE path must too, so a mis-onboarded Hub
    # fails loudly instead of corrupting the graph.
    if not USER_URI:
        return {
            "status": "error",
            "degraded": True,
            "reason": "user_id_not_configured",
        }, 503

    # 1. Validate + sanitise every string. subject + fact_text required.
    subject, err = _validate_asserted_string(
        payload.get("subject"), field="subject", required=True
    )
    if err:
        return err, 400
    fact_text, err = _validate_asserted_string(
        payload.get("fact_text"), field="fact_text", required=True
    )
    if err:
        return err, 400
    relationship, err = _validate_asserted_string(
        payload.get("relationship"), field="relationship", required=False
    )
    if err:
        return err, 400
    asserted_via, err = _validate_asserted_string(
        payload.get("asserted_via"), field="asserted_via",
        required=False, max_len=80
    )
    if err:
        return err, 400

    # 2. Identity-resolve `subject` via people_search.
    try:
        search = people_search(subject, limit=5)
    except Exception as exc:
        return {
            "status": "error",
            "degraded": True,
            "reason": f"identity_resolution_failed: {exc}",
        }, 503

    results = search.get("results", []) if isinstance(search, dict) else []
    strong = [r for r in results
              if r.get("score", 0) >= _ASSERT_STRONG_MATCH_SCORE]

    created_person = False
    person_uri = None
    person_slug = None

    if len(strong) >= 2:
        # Two or more plausible matches within the disambiguation margin ->
        # ask, write NOTHING. If the leader is clearly ahead of the
        # runner-up we still proceed with the leader.
        strong_sorted = sorted(
            strong, key=lambda r: r.get("score", 0), reverse=True
        )
        leader = strong_sorted[0].get("score", 0)
        runner_up = strong_sorted[1].get("score", 0)
        if (leader - runner_up) <= _ASSERT_DISAMBIGUATION_MARGIN:
            candidates = []
            for r in strong_sorted:
                # Use the per-result person_uri so same-named duplicates carry
                # DISTINCT uris -- otherwise merge_people can't tell them apart
                # and refuses the merge. See _candidate_person_uri.
                candidates.append({
                    "name": r.get("name", ""),
                    "slug": r.get("slug", ""),
                    "uri": _candidate_person_uri(r),
                })
            return {
                "status": "needs_disambiguation",
                "candidates": candidates,
            }, 200
        # Clear leader: fall through and attach to it.
        chosen = strong_sorted[0]
        person_slug = chosen.get("slug")
        person_uri = _candidate_person_uri(chosen)
    elif len(strong) == 1:
        chosen = strong[0]
        person_slug = chosen.get("slug")
        person_uri = _candidate_person_uri(chosen)

    # A strong search hit whose name no longer resolves in Oxigraph (stale
    # Qdrant point) falls through to minting -- better a fresh node than a
    # dropped fact.
    if person_uri is None:
        created_person = True
        person_uri, _person_id = _mint_person_uri()
        person_slug = _wiki_slug(subject)

    now = now or datetime.now(timezone.utc)
    now_iso = now.isoformat()

    # 3. Build the SPARQL UPDATE. Mint a uuid fact id (shape matches the
    # existing fact_<hex> ids the readers expect). All user strings are
    # escaped via _sparql_escape_literal -- the single injection defence.
    fact_id = "fact_" + uuid.uuid4().hex[:12]
    fact_uri = f"{PWG_NS}{fact_id}"

    esc_subject = _sparql_escape_literal(subject)
    esc_fact = _sparql_escape_literal(fact_text)
    esc_rel = _sparql_escape_literal(relationship) if relationship else ""
    esc_via = _sparql_escape_literal(asserted_via) if asserted_via else ""

    # When we minted a new Person, give it the minimal node shape
    # contact_syncer writes so the wiki + people list can render it.
    person_seed_triples = ""
    if created_person:
        person_seed_triples = (
            f'  <{person_uri}> a pwg:Person ;\n'
            f'    pwg:displayName "{esc_subject}" ;\n'
            f'    pwg:source "user_asserted" ;\n'
            f'    pwg:createdAt "{now_iso}" .\n'
        )

    # The reified PersonFact. We write BOTH pwg:factConfidence (the brief's
    # canonical confidence predicate, typed xsd:decimal) AND pwg:confidence
    # (the predicate the Memory-tab reader selects), so the fact is both
    # spec-correct and visible to the existing read path. pwg:authoritative
    # true + factSource "user_asserted" mark it as outranking mined facts.
    fact_triples = (
        f'  <{fact_uri}> a pwg:PersonFact ;\n'
        f'    pwg:aboutPerson <{person_uri}> ;\n'
        f'    pwg:factText "{esc_fact}" ;\n'
        f'    pwg:factSource "user_asserted" ;\n'
        f'    pwg:factConfidence "1.0"^^xsd:decimal ;\n'
        f'    pwg:confidence "1.0"^^xsd:decimal ;\n'
        f'    pwg:authoritative true ;\n'
        f'    pwg:factDomain "relationship" ;\n'
        f'    pwg:createdAt "{now_iso}" ;\n'
        f'    pwg:validFrom "{now_iso}" ;\n'
        f'    pwg:belongsToUser <{USER_URI}> .\n'
    )
    if esc_via:
        fact_triples += (
            f'  <{fact_uri}> pwg:assertedVia "{esc_via}" .\n'
        )

    insert_block = (
        "PREFIX pwg: <{ns}>\n"
        "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
        "INSERT DATA {{\n"
        "{person}{fact}"
        "}}"
    ).format(ns=PWG_NS, person=person_seed_triples, fact=fact_triples)

    # The relationship scalars live on the Person, so they are
    # DELETE-then-INSERT (replace any prior value) rather than additive.
    # Done as a separate UPDATE statement in the same request, sequenced
    # after the INSERT so a fresh Person node already exists.
    relationship_update = ""
    if relationship:
        relationship_update = (
            ";\n"
            "PREFIX pwg: <{ns}>\n"
            "DELETE {{ <{uri}> pwg:relationship ?r }}\n"
            "WHERE {{ <{uri}> pwg:relationship ?r }};\n"
            "PREFIX pwg: <{ns}>\n"
            "DELETE {{ <{uri}> pwg:relationshipType ?rt }}\n"
            "WHERE {{ <{uri}> pwg:relationshipType ?rt }};\n"
            "PREFIX pwg: <{ns}>\n"
            'INSERT DATA {{ <{uri}> pwg:relationship "{rel}" ;\n'
            '  pwg:relationshipType "{rel}" . }}'
        ).format(ns=PWG_NS, uri=person_uri, rel=esc_rel)

    sparql = insert_block + relationship_update

    # 4 + 5. Write, queue recompile, respond. Degrade on Oxigraph error.
    try:
        _sparql_update(sparql)
    except Exception as exc:
        return {
            "status": "error",
            "degraded": True,
            "reason": f"oxigraph_update_failed: {exc}",
        }, 503

    queued = _queue_wiki_recompile(person_slug or _wiki_slug(subject))

    return {
        "status": "created_person" if created_person else "stored",
        "person_uri": person_uri,
        "person_slug": person_slug,
        "fact_id": fact_id,
        "relationship": relationship or None,
        "wiki_recompile_queued": queued,
    }, 200


# ── END GRAFT: #51 POST /api/v1/memory/assert ──


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def _send_hydration_cors(self):
        """Emit Access-Control-Allow-Origin for the hydration route ONLY.

        The request Origin is reflected back only when it is in the
        allowlist (wiki + Tauri Hub webview). Scoped to this single route
        so no other endpoint leaks CORS -- a guard test asserts exactly
        that.
        """
        origin = self.headers.get("Origin")
        if origin in WIKI_HYDRATION_ALLOWED_ORIGINS:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")

    def do_OPTIONS(self):
        # Preflight support for the hydration route (browsers may send it
        # if a custom header ever creeps into the fetch). Other paths get
        # a plain 405 with no CORS headers.
        parsed = urlparse(self.path)
        if parsed.path == "/api/v1/hydration/status":
            self.send_response(204)
            self._send_hydration_cors()
            self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.end_headers()
            return
        self.send_response(405)
        self.end_headers()

    # Map /api/v1/... paths the iOS app calls to the legacy unprefixed
    # paths so existing handler blocks serve both. Legacy callers keep
    # working; CM031 (PWG Companion) gets its versioned URLs.
    _VERSIONED_TO_LEGACY = {
        "/api/v1/people":           "/people",
        "/api/v1/people/search":    "/people/search",
        "/api/v1/people/context":   "/people/context",
        "/api/v1/people/stale":     "/people/stale",
        "/api/v1/people/recent":    "/people/recent",
        "/api/v1/people/birthdays": "/people/birthdays",
        "/api/v1/calendar":         "/calendar",
        "/api/v1/calendar/today":   "/calendar/today",
    }

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path in self._VERSIONED_TO_LEGACY:
            parsed = parsed._replace(path=self._VERSIONED_TO_LEGACY[parsed.path])

        if parsed.path == "/health":
            try:
                detailed = parse_qs(parsed.query).get("detailed", ["0"])[0] in ("1", "true")
                result = api_health_detailed() if detailed else {"status": "ok"}
            except Exception as exc:
                result = {"status": "error", "error": str(exc)}
            status_code = 200 if result.get("status") == "ok" else 503 if result.get("status") == "error" else 200
            self.send_response(status_code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        if parsed.path.startswith("/email"):
            params = parse_qs(parsed.query)
            query = params.get("q", ["is:unread"])[0]
            max_results, err = _safe_int(params, "max", 10)
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return

            result = query_gmail(query, max_results)

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        if parsed.path.startswith("/calendar"):
            params = parse_qs(parsed.query)
            days, err = _safe_int(params, "days", 7)
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            if parsed.path == "/calendar/today":
                days = 1

            all_events = []

            # 1. iCloud Calendar
            try:
                result = subprocess.run(
                    [ICAL_SCRIPT, str(days)],
                    capture_output=True, text=True, timeout=30
                )
                all_events.extend(parse_ical_output(result.stdout))
            except Exception as e:
                pass  # iCloud failure shouldn't break response

            # 2. Google Calendar
            try:
                all_events.extend(query_google_calendar(days))
            except Exception:
                pass

            # Sort all events by start time
            all_events.sort(key=lambda e: e.get("start", ""))

            # Drop personal-admin entries (all-day, attendee-less holidays /
            # deliveries / reminders) so the calendar surface shows meetings,
            # not "Father's Day" / "M&S Delivery". Conservative: timed events
            # and all-day events with attendees are kept. See #v152.
            all_events = [
                e for e in all_events if not _is_personal_admin_event(e)
            ]

            # Deduplicate by summary + start (in case same event in both)
            seen = set()
            deduped = []
            for e in all_events:
                key = (e.get("summary", ""), e.get("start", ""))
                if key not in seen:
                    seen.add(key)
                    deduped.append(e)

            # CM031 PWG Companion's CalendarEvent decodes `title` and ISO
            # timestamps. Add the iOS-friendly aliases without removing
            # the legacy `summary` / iCal-style `start` / `end` fields
            # used by Marvin and the wiki tools. attendee_names is the
            # CM031 `attendees: [String]` shape; legacy `attendees` (list
            # of {name, email, role} dicts) is left alone.
            for e in deduped:
                if "summary" in e and "title" not in e:
                    e["title"] = e["summary"]
                if "start" in e:
                    e["start_iso"] = _to_iso8601(e["start"])
                if "end" in e:
                    e["end_iso"] = _to_iso8601(e["end"])
                attendees = e.get("attendees")
                if isinstance(attendees, list) and attendees:
                    names = []
                    for a in attendees:
                        if isinstance(a, dict):
                            nm = a.get("name") or a.get("email") or ""
                            if nm:
                                names.append(nm)
                        elif isinstance(a, str):
                            names.append(a)
                    if names:
                        e["attendee_names"] = names

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "events": deduped,
                "count": len(deduped),
                "period_days": days,
                "sources": ["iCloud", "Google Calendar"],
            }, indent=2).encode())
            return

        if parsed.path == "/people/search":
            params = parse_qs(parsed.query)
            q = params.get("q", [""])[0]
            if not q:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"error": "Missing ?q= parameter"}).encode())
                return
            limit, err = _safe_int(params, "limit", 5)
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            try:
                result = people_search(q, limit=limit)
            except Exception as e:
                result = {"results": [], "count": 0, "query": q,
                          "degraded": True, "reason": str(e), "error": str(e)}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        if parsed.path == "/people/context":
            params = parse_qs(parsed.query)
            name = params.get("name", [""])[0]
            if not name:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"error": "Missing ?name= parameter"}).encode())
                return
            try:
                result = person_context(name)
            except Exception as e:
                result = {"query": name, "found": False,
                          "degraded": True, "reason": str(e), "error": str(e)}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        if parsed.path == "/people/stale":
            params = parse_qs(parsed.query)
            months, err = _safe_int(params, "months", 3)
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            limit, err = _safe_int(params, "limit", 5)
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            try:
                result = people_stale(months=months, limit=limit)
            except Exception as e:
                result = {"contacts": [], "degraded": True, "reason": str(e), "error": str(e)}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        if parsed.path == "/people":
            params = parse_qs(parsed.query)
            sort = params.get("sort", [None])[0]
            try:
                result = people_list(sort=sort)
            except Exception as e:
                result = {"people": [], "total": 0, "degraded": True,
                          "reason": str(e), "error": str(e)}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        if parsed.path == "/people/recent":
            params = parse_qs(parsed.query)
            days, err = _safe_int(params, "days", 7)
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            limit, err = _safe_int(params, "limit", 5)
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            try:
                result = people_recent(days=days, limit=limit)
            except Exception as e:
                result = {"contacts": [], "degraded": True, "reason": str(e), "error": str(e)}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        if parsed.path == "/people/birthdays":
            params = parse_qs(parsed.query)
            days, err = _safe_int(params, "days", 7)
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            try:
                result = people_birthdays(days=days)
            except Exception as e:
                result = {"people": [], "degraded": True, "reason": str(e), "error": str(e)}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        if parsed.path == "/api/v1/email/recent":
            params = parse_qs(parsed.query)
            hours, err = _safe_int(params, "hours", 24)
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            limit, err = _safe_int(params, "limit", 20)
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            try:
                result = fetch_recent_emails(hours=hours, limit=limit)
            except Exception as e:
                self.send_response(500)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e)}).encode())
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        # GET /api/v1/reply-debt?limit=N&threshold_hours=F&lookback_days=N&include_group=0|1
        # The daily-brief headline: "you owe a reply to N people". Read-only;
        # degrades to {count:0, debts:[], degraded:true} when the CM048
        # detector / chat.db is not reachable so the brief omits the line
        # rather than going red. (CM048 reply-debt detector, JTBD#1.)
        if parsed.path == "/api/v1/reply-debt":
            params = parse_qs(parsed.query)
            limit, err = _safe_int(params, "limit", 50)
            if not err:
                lookback_days, err = _safe_int(params, "lookback_days", 90)
            threshold_hours = None
            if not err and "threshold_hours" in params:
                threshold_hours, err = _safe_float(
                    params, "threshold_hours", 6.0
                )
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            include_group = params.get(
                "include_group", ["0"]
            )[0].strip().lower() in ("1", "true", "yes")
            try:
                result, status = api_reply_debt(
                    threshold_hours=threshold_hours,
                    lookback_days=lookback_days,
                    include_group=include_group,
                    limit=limit,
                )
            except Exception as exc:
                result, status = {
                    "count": 0, "brief_line": "", "debts": [],
                    "degraded": True,
                    "reason": f"reply_debt_failed: {str(exc)[:200]}",
                }, 200
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        if parsed.path == "/api/v1/suggestions":
            try:
                result = api_suggestions()
            except Exception as exc:
                result = {"birthdays": [], "stale_contacts": [], "recent_meetings": [],
                          "degraded": True, "reason": str(exc), "error": str(exc)}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        if parsed.path == "/api/v1/timeline":
            params = parse_qs(parsed.query)
            days, err = _safe_int(params, "days", 7)
            if not err:
                past_days, err = _safe_int(params, "past_days", 730)
            if not err:
                limit, err = _safe_int(params, "limit", 200)
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            try:
                result = api_timeline(days=days, past_days=past_days, limit=limit)
            except Exception as exc:
                # `entries` mirrors `items` per the iOS ServerTimelineResponse
                # decoder (F-1, 2026-05-27). Without it the Companion drops
                # straight to its hard-error path instead of the soft-degraded
                # empty state.
                result = {"items": [], "entries": [], "days": days, "count": 0,
                          "degraded": True, "reason": str(exc), "error": str(exc)}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        # Coach recent observations (CM048 tier 3)
        if parsed.path == "/api/v1/coach/recent":
            params = parse_qs(parsed.query)
            # user_id is required (rebrand sweep PR-2 / audit P1-6).
            # Previously coach_recent silently defaulted to "andy"; on
            # a customer Hub that scopes the query to a non-existent
            # user and returns empty without warning.
            user_id_values = params.get("user_id") or []
            user_id = user_id_values[0].strip() if user_id_values else ""
            if not user_id:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({
                    "error": "user_id query parameter is required",
                }).encode())
                return
            hours, err = _safe_int(params, "hours", 168)  # default 7 days
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            limit, err = _safe_int(params, "limit", 10)
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            try:
                result = coach_recent(
                    user_id=user_id, hours=hours, limit=limit
                )
            except Exception as exc:
                result = {"observations": [], "error": str(exc)}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        # Hub health endpoint (HR015 Hub portability). Must never 5xx;
        # on catastrophic failure we fall through to offline_local so the
        # iOS pill can still make a decision.
        if parsed.path == "/api/v1/hub/health":
            try:
                result = api_hub_health()
            except Exception as exc:
                result = {
                    "hub_status": "offline_local",
                    "hub_version": HUB_VERSION,
                    "last_sync": None,
                    "queue_depth": 0,
                    "power_state": "unknown",
                    "services": {},
                    "degraded_features": [],
                    "error": str(exc)[:200],
                }
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        # Wiki first-run hydration panel (CM044 #624). Reachable through
        # the Doctor auth proxy at /api/v1/* (DOCTOR_PROXY_PATHS includes
        # this path). CORS is emitted on this route only, allowlisted to
        # the wiki and Tauri Hub origins. Degrades calm: any failure
        # returns a pending payload with 200 so the panel never breaks
        # the homepage.
        if parsed.path == "/api/v1/hydration/status":
            try:
                result = api_hydration_status()
            except Exception as exc:
                result = {"overall_state": "pending", "phases": [],
                          "error": str(exc)[:200]}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self._send_hydration_cors()
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        # Recording state (CM042 producer → CM031 Live Activity).
        # Read-only. Never 5xx: any failure demotes to recording=null so
        # the iOS Live Activity collapses cleanly. See api_recording_active
        # for the full wire contract.
        if parsed.path == "/api/v1/recording/active":
            try:
                result = api_recording_active()
            except Exception as exc:
                # Defensive belt-and-braces: api_recording_active is
                # already written to never raise, but if a future
                # refactor regresses that guarantee we still hand the
                # consumer a usable null response rather than 500.
                print(
                    f"WARNING: api_recording_active raised "
                    f"unexpectedly: {exc}",
                    file=sys.stderr,
                    flush=True,
                )
                result = {"recording": None}
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        # Conversation processing status (CM048)
        if (
            parsed.path.startswith("/api/v1/conversation/")
            and parsed.path.endswith("/speakers")
        ):
            # /api/v1/conversation/{id}/speakers -> Hub-inferred speaker
            # identity feedback for the device to confirm + bind locally.
            middle = parsed.path[len("/api/v1/conversation/"):-len("/speakers")]
            conversation_id = middle.strip("/")
            if not conversation_id:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"error": "Missing conversation_id"}).encode())
                return
            result, status = api_conversation_speakers(conversation_id)
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        if parsed.path.startswith("/api/v1/conversation/status/"):
            conversation_id = parsed.path.split("/api/v1/conversation/status/", 1)[1]
            conversation_id = conversation_id.strip("/")
            if not conversation_id:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"error": "Missing conversation_id"}).encode())
                return
            result, status = api_conversation_status(conversation_id)
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        # Per-slug person enrichment for the iOS / Hub person card.
        # GET /api/v1/people/{slug}/enrichment
        if (parsed.path.startswith("/api/v1/people/")
                and parsed.path.endswith("/enrichment")):
            slug = parsed.path[len("/api/v1/people/"):-len("/enrichment")]
            try:
                result, status = person_enrichment(slug)
            except Exception as exc:
                result, status = {
                    "found": False,
                    "degraded": True,
                    "reason": str(exc),
                    "error": str(exc),
                }, 503
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"error": "Not found", "endpoints": {
            "/calendar?days=N": "Events for next N days (iCloud + Google Calendar)",
            "/calendar/today": "Today's events",
            "/people/search?q=fintech": "Semantic people search",
            "/people/context?name=Danny": "Everything known about a person (+ relationship signals)",
            "/people/stale?months=3&limit=5": "Contacts not spoken to in N months",
            "/people/recent?days=7&limit=5": "Recently met people (from meetings)",
            "/people/birthdays?days=7": "Upcoming birthdays",
            "/api/v1/people/{slug}/enrichment": "Per-slug person card payload (org, role, identifiers, meetings, per-source last-contact)",
            "/email?q=is:unread": "Gmail query (default: unread)",
            "/api/v1/email/recent?hours=24&limit=20": "Recent emails (subject + snippet only)",
            "/api/v1/suggestions": "Composite: birthdays + stale contacts + recent meetings",
            "/api/v1/timeline?days=7": "Merged calendar + meetings timeline",
            "/api/v1/coach/recent?hours=168&limit=10": "Recent coaching observations (CM048)",
            "/api/v1/conversation/status/{id}": "Conversation processing status (CM048)",
            "/api/v1/conversation/{id}/speakers": "Hub-inferred speaker-identity suggestions for the device to confirm (CM048, text-only, opaque voice_fingerprint_ref)",
            "/api/v1/hub/health": "Hub status for iOS Companion pill (online / catching_up / offline_local)",
            "/api/v1/recording/active": "Current capture state for the iOS Recording Live Activity (CM042 producer → CM031 consumer)",
            "POST /api/v1/conversation/process": "Submit conversation for processing (CM048)",
            "POST /api/v1/ingest/ios": "Batch upload from the iOS companion (application/json)",
            "/health": "Health check (pass ?detailed=1 for dependency checks)",
        }}).encode())

    def do_POST(self):
        parsed = urlparse(self.path)

        # Route: POST /api/v1/people/{slug}/forget – no body required.
        # Handled before body validation because the iOS contract
        # (CM031 ForgetPersonService PR #90) sends an empty body, and
        # the validation below would 411 it on Content-Length: 0.
        if (parsed.path.startswith("/api/v1/people/")
                and parsed.path.endswith("/forget")):
            slug = parsed.path[len("/api/v1/people/"):-len("/forget")]
            try:
                result, status = api_people_forget(slug)
            except Exception as exc:
                result, status = {"error": str(exc)}, 500
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        # Security: content-type must be JSON
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ctype != "application/json":
            self.send_response(415)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": "Content-Type must be application/json"}).encode())
            return

        # Security: reject oversized bodies
        try:
            clen = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            clen = 0
        if clen <= 0:
            self.send_response(411)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": "Content-Length required"}).encode())
            return
        if clen > MAX_POST_BYTES:
            self.send_response(413)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": f"Body too large (max {MAX_POST_BYTES} bytes)"}).encode())
            return

        # Read and parse body
        try:
            body = self.rfile.read(clen)
            payload = json.loads(body)
        except json.JSONDecodeError as exc:
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": f"Invalid JSON: {exc}"}).encode())
            return
        except Exception as exc:
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": f"Body read failed: {exc}"}).encode())
            return

        # Route
        if parsed.path == "/api/v1/conversation/process":
            try:
                result, status = api_conversation_process(payload)
            except Exception as exc:
                result, status = {"error": str(exc)}, 500
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        if parsed.path == "/api/v1/ingest/ios":
            try:
                result, status = api_ingest_ios(payload)
            except Exception as exc:
                result, status = {"error": str(exc)}, 500
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        if parsed.path == "/api/v1/subscription/receipt":
            # G1 (2026-05-27): iOS Companion pushes a fresh StoreKit
            # receipt after every transaction success / restore + on
            # every app foreground. The Hub's subscription_gate (G0,
            # PR #190) persists the state for ongoing-intelligence
            # pipelines to consult via is_active_or_grace().
            try:
                result, status = api_subscription_receipt(payload)
            except Exception as exc:
                result, status = {"error": str(exc)}, 500
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        # User-asserted fact: POST /api/v1/memory/assert (CM041 #51, grafted).
        # Banks a fact the user stated in chat (e.g. "<name> is my partner")
        # as an authoritative, user_asserted PersonFact in Oxigraph -- the
        # write half of the learning loop (layer 1). Mirrors the POST
        # branches above for body-read + response style.
        if parsed.path == "/api/v1/memory/assert":
            try:
                result, status = api_memory_assert(payload)
            except Exception as exc:
                result, status = {"error": str(exc)}, 500
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"error": "Not found (POST)"}).encode())


if __name__ == "__main__":
    # Bind to loopback by default (audit finding §5.1: loopback-only is
    # safer for the productised single-Mac topology). The iOS Companion
    # reaches the Hub over Tailscale, which gives the Mac a stable
    # 100.x private IP; setting OSTLER_API_BIND="0.0.0.0" enables direct
    # LAN exposure for dev or for users who don't want Tailscale.
    BIND_HOST = os.environ.get("OSTLER_API_BIND", "127.0.0.1")
    print(f"Assistant API running on http://{BIND_HOST}:{PORT}")
    print("Endpoints: /calendar, /people/{search,context,stale,recent,birthdays}, /email, /api/v1/email/recent, /api/v1/suggestions, /api/v1/timeline, /api/v1/hub/health, /api/v1/recording/active, POST /api/v1/ingest/ios, POST /api/v1/subscription/receipt, POST /api/v1/people/{slug}/forget, POST /api/v1/memory/assert, /health")
    if BIND_HOST == "0.0.0.0":
        print(
            "WARNING: OSTLER_API_BIND=0.0.0.0 exposes the Assistant API on "
            "every network interface. Default is 127.0.0.1 (loopback). "
            "Use Tailscale for remote access where possible.",
            file=sys.stderr,
            flush=True,
        )
    HTTPServer((BIND_HOST, PORT), Handler).serve_forever()
