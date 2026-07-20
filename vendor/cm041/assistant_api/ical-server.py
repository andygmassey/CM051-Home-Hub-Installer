#!/usr/bin/env python3
"""Unified Assistant API - calendar, email, and People Graph endpoints.
Runs on localhost:8089.

Endpoints:
  GET /calendar?days=7             – events for next N days from ALL calendars
  GET /calendar/today              – today's events
  GET /people/search?q=...         – semantic search across People Graph
  GET /people/context?name=..      – everything known about a person
  GET /api/v1/people/{slug}/enrichment – per-slug person card payload (org, role, identifiers, meetings, per-source last-contact)
  GET /api/v1/person/{slug}/timeline?limit=50&days=N – unified cross-channel relationship timeline (meetings + conversations + last-contact markers, newest-first)
  GET /people/stale?months=3       – contacts not spoken to recently
  GET /people/recent?days=7        – recently met people
  GET /people/birthdays?days=7     – upcoming birthdays
  GET /email?q=...                 – Gmail query
  GET /api/v1/email/recent         – recent emails (subject + snippet only)
  GET /api/v1/suggestions          – composite today-view payload
  GET /api/v1/timeline?days=7      – merged calendar + meetings
  GET /api/v1/meeting/upcoming?within_minutes=120 – pre-meeting briefs (next N minutes)
  GET /api/v1/reply-debt?limit=N   : outstanding reply debts for the daily-brief headline (CM048 detector)
  GET /api/v1/coach/recent         – coaching observations (CM048)
  GET /api/v1/conversation/status/{id} – conversation processing status (CM048)
  GET /api/v1/conversation/{id}/speakers – Hub-inferred speaker-identity suggestions (CM048, text-only)
  GET /api/v1/hub/health           – Hub status for iOS Companion pill (HR015 Hub portability)
  GET /api/v1/hydration/status     – First-run wiki hydration progress for the homepage panel (CM044 #624)
  GET /api/v1/recording/active     – Current capture state for the iOS Recording Live Activity (CM042 → CM031)
  GET /api/v1/memory               – list facts Ostler has learnt about the user (CM031 iOS Memory tab v1.0)
  POST /api/v1/conversation/process – submit conversation for processing (CM048)
  POST /api/v1/ingest/ios          – batch upload from iOS companion
  GET  /api/v1/health/day?date=    – day's physiology joined to its context (#680)
  POST /api/v1/people/{slug}/forget – GDPR Art. 17 right-of-erasure (one-click forget)
  POST /api/v1/memory/correct/{id} – correct ({"newValue":...}) or forget ({"forget":true}) a fact
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

# Canonical fail-closed L3 privacy helper (single source of truth). Lives
# at the repo root so both this server and meeting_syncer/brief.py import
# the SAME doctrine -- see pwg_privacy.py. Add the repo root to sys.path at
# import time so `import pwg_privacy` resolves whether the server is run as
# a script (script dir on sys.path) or imported by the test harness.
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)
import pwg_privacy

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


def _pipeline_import_roots():
    """Directories that must be on sys.path to import the import-pipeline
    packages (``contact_syncer``, ``meeting_syncer``, ``identity_resolver``).

    Two deploy layouts exist and BOTH must resolve, or the every-boot privacy
    backfill (and the reader-side privacy-coverage counter) go silently inert:

      * Dev / repo layout: this file is ``<repo>/assistant_api/ical-server.py``
        and the pipeline packages are siblings at the repo root, i.e.
        ``Path(__file__).parent.parent``.

      * Shipping layout (CM051 install.sh): this file is copied to
        ``${OSTLER_DIR}/services/ical-server/ical-server.py`` (install.sh:
        ``ICAL_SERVER_DIR="${OSTLER_DIR}/services/ical-server"``) while the
        pipeline packages ship at ``${OSTLER_DIR}/import-pipeline/`` (install.sh:
        ``PIPELINE_DIR="${OSTLER_DIR}/import-pipeline"`` + ``cp -R contact_syncer
        "$PIPELINE_DIR/"``). From this file that is
        ``Path(__file__).parent.parent.parent / "import-pipeline"``.

    The ical-server launchd plist does not export ``OSTLER_DIR`` /
    ``PIPELINE_DIR`` / ``IMPORT_PIPELINE`` (only OSTLER_API_*, ICAL_SCRIPT,
    INGEST_DIR, SYNC_STATE_DIR), so there is no install-provided env var to
    reuse; the roots are derived from ``__file__``. An optional
    ``OSTLER_IMPORT_PIPELINE_DIR`` override is honoured first for non-standard
    installs. Returns roots that exist, most-specific first, deduped.
    """
    here = Path(__file__).resolve().parent
    candidates = []
    env_dir = os.environ.get("OSTLER_IMPORT_PIPELINE_DIR", "").strip()
    if env_dir:
        candidates.append(Path(env_dir))
    # Shipping layout: services/ical-server/ -> ${OSTLER_DIR} -> import-pipeline/
    candidates.append(here.parent.parent / "import-pipeline")
    # Dev / repo layout: assistant_api/ -> repo root (pipeline pkgs are siblings)
    candidates.append(here.parent)
    roots = []
    seen = set()
    for c in candidates:
        try:
            rc = c.resolve()
        except OSError:
            continue
        s = str(rc)
        if s in seen or not rc.is_dir():
            continue
        seen.add(s)
        roots.append(s)
    return roots


def _ensure_pipeline_on_path():
    """Insert every existing import-pipeline root onto sys.path (idempotent)."""
    for root in _pipeline_import_roots():
        if root not in sys.path:
            sys.path.insert(0, root)


# Non-decomposable Latin letters that NFKD leaves intact (they are atomic
# code points, not base+combining-mark). Mapped to an ASCII transliteration
# so an accented international name yields a clean, stable, collision-resistant
# slug rather than a hyphen-riddled or empty one. British-English / European
# names dominate, but the table is script-agnostic where a sensible Latin
# transliteration exists.
_SLUG_TRANSLIT = {
    "ø": "o", "Ø": "o",   # ø Ø
    "ß": "ss",                  # ß
    "æ": "ae", "Æ": "ae",  # æ Æ
    "œ": "oe", "Œ": "oe",  # œ Œ
    "ð": "d", "Ð": "d",    # ð Ð
    "þ": "th", "Þ": "th",  # þ Þ
    "ł": "l", "Ł": "l",    # ł Ł
    "đ": "d", "Đ": "d",    # đ Đ
    "ı": "i",                   # ı (dotless i)
    "ŋ": "n",                   # ŋ
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
    # Non-Latin name: derive a stable per-name suffix so different names do
    # not all collide on "unknown".
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
    holidays ("Father's Day", "New Year's Day"), deliveries
    ("Grocery delivery", "Parcel delivery"), reminders ("Haircut") and
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

# ── Preferences read-path (CM059 producer / daemon pwg_preferences tool) ──
# CM059 compiles the interest profile and writes a stable JSON artefact;
# this server serves it read-only at /api/v1/preferences. Path precedence
# mirrors the CM059 emitter exactly: OSTLER_INTEREST_PROFILE (full path) >
# OSTLER_PREFERENCES_DIR/interest_profile.json > the default.
INTEREST_PROFILE_PATH = (
    os.environ.get("OSTLER_INTEREST_PROFILE")
    or os.path.join(
        os.environ.get(
            "OSTLER_PREFERENCES_DIR",
            os.path.expanduser("~/.ostler/preferences"),
        ),
        "interest_profile.json",
    )
)

# ── CM048 conversation processing integration ────────────────────────
PWG_HOME = Path(os.environ.get("PWG_HOME", os.path.expanduser("~/.pwg")))
COACH_DB = PWG_HOME / "coach" / "observations.db"
PROCESSING_DIR = PWG_HOME / "processing"
CONVERSATIONS_DIR = PWG_HOME / "conversations"
OSTLER_VENV_PYTHON = os.environ.get("OSTLER_PYTHON", "")
OSTLER_PROJECT_DIR = os.environ.get("OSTLER_PROJECT_DIR", "")

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

# ── Memory tab (CM031 iOS Companion v1.0 LB) ─────────────────────────
# The Memory tab is the customer's window into what Ostler has inferred
# about them. GET returns the user's own PersonFact rows from Oxigraph
# (capped at MEMORY_LIMIT, sorted by confidence x recency). POST writes
# an append-only correction row to MEMORY_CORRECTIONS_DB; the next GET
# overlays the correction so the displayed fact reflects the user's
# edit (or is dropped if the action was "forget").
#
# USER_ID is the same env var the contact_syncer + meeting_syncer +
# CM048 sinks all key on. On a customer Hub the installer sets this
# from the assistant-naming step. On Andy's instance it's "andy" by
# convention. We never silently default; the endpoint surfaces an
# empty list + `degraded:true` if USER_ID is unset, the same shape the
# other endpoints use for upstream-unavailable fallback.
# Normalised through the SAME idempotent helper the compartment / owner_node
# paths use, so a human-typed value (``Jane Doe``, ``jane@home`` from CM051
# install.sh) yields the SAME owner IRI here as the writers mint -- otherwise
# this reader's USER_URI would never match the owner node on the graph and
# every owner-scoped read would silently return empty. Empty stays empty so
# the existing degraded-when-USER_ID-unset path is preserved (normalise folds
# "" -> the "primary" label, which is wrong for a graph IRI here).
from identity_resolver.compartment import normalise_user_id as _normalise_user_id

_raw_user_id = os.environ.get("USER_ID", "").strip()
USER_ID = _normalise_user_id(_raw_user_id) if _raw_user_id else ""
USER_URI = (
    f"https://pwg.dev/ontology#user_{USER_ID}" if USER_ID else ""
)
MEMORY_LIMIT = int(os.environ.get("MEMORY_LIMIT", "50"))
MEMORY_CORRECTIONS_DB = Path(os.environ.get(
    "MEMORY_CORRECTIONS_DB",
    str(PWG_HOME / "memory" / "corrections.db"),
))

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
      ATTENDEE;CN=Jane Doe;CUTYPE=INDIVIDUAL;EMAIL=jane@example.com;PARTSTAT=ACCEPTED:mailto:jane@example.com
      ORGANIZER;CN=John Smith;EMAIL=john@example.com:/principal/path
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


# Control characters that must never reach a SPARQL literal. We reject the
# input outright rather than silently stripping, so a caller sending a
# control byte gets a clear validation error instead of mangled data.
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
_RECOMPILE_QUEUE_DIR = Path(
    os.environ.get("OSTLER_QUEUE_DIR", os.path.expanduser("~/.ostler/queue"))
)

# Slug = lowercase ASCII letters, digits, hyphens. Max 80 chars (matches
# the ceiling in _wiki_slug). Rejects path-traversal seeds, SPARQL
# injection seeds, Qdrant filter abuse, and the empty string.
_SLUG_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,79}$")


# Privacy handling is delegated wholesale to the canonical pwg_privacy
# helper (fail-closed L3 doctrine, single source of truth). These names are
# kept as thin, back-compat wrappers so every existing call site and the
# test suite route through the ONE helper rather than a second copy.


def _qdrant_fact_is_explicit_l3(fact):
    """Deprecated shim -> pwg_privacy.is_l3 (fail-closed).

    Historically this returned True only on an *explicit* L3 tag and the
    caller KEPT everything else (fail-OPEN on a missing/garbage tag -- the
    leak Archie caught). It now delegates to the fail-closed doctrine: a
    fact is "L3 for hiding purposes" whenever it carries no parseable,
    non-L3 clearance of its own. Kept only for call-site/back-compat.
    """
    return pwg_privacy.is_l3(fact)


def _filter_qdrant_facts(facts, owner_level=None):
    """Fail-closed L3 filter for a Qdrant person payload's ``facts`` field.

    Read-side guard for people_search(). The /people/search reader copies
    the Qdrant `people` payload's `facts` field verbatim into the response
    and no downstream consumer re-checks privacy on the bare list. Today no
    writer populates that field (audited across the six Qdrant
    people-writers, 2026-07-13), but the reader explicitly SELECTs it in
    `with_payload.include` and the people-writers SPARQL over `pwg:Person`
    WITHOUT selecting `pwg:privacyLevel` -- so the moment any writer
    flattens Oxigraph facts into this payload, an untagged (or L3-tagged)
    fact would serialise in cleartext here.

    FAIL-CLOSED (operator doctrine, Archie F8): only a fact carrying its
    own explicit, parseable L0/L1/L2 clearance survives. A missing / empty
    / unparseable tag -- including a bare-string fact whose tag was lost in
    flattening -- is dropped. ``owner_level`` is not passed on this path by
    default: a denormalised Qdrant blob is not a trustworthy place to
    inherit a coarse person-level clearance from, so each fact must clear
    itself. Non-list shapes are dropped whole (un-auditable).
    """
    return pwg_privacy.filter_l3_facts(facts, owner_level)


def people_search(query, limit=10):
    """Semantic search across the Qdrant people collection."""
    vector = _embed_text(query)
    body = json.dumps({
        "vector": vector,
        "limit": limit,
        "with_payload": {"include": [
            "display_name", "organization", "job_title", "relationship",
            "how_we_met", "phones", "emails", "facts", "last_contact",
            "contact_type", "person_uri", "privacy_level",
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
        # Person-level L3 (F5): an L3-classified person must not surface in
        # search at all. Only an EXPLICIT L3 person-tag drops the person
        # here -- an untagged person is still searchable (search coverage
        # must not collapse for the many points that predate the
        # privacy_level default), and their individual facts are still
        # fail-closed filtered below. Default person tag today is L2.
        if pwg_privacy.parse_privacy_level(p.get("privacy_level")) == "L3":
            continue
        entry = {
            "name": dn,
            "slug": _wiki_slug(dn),
            "score": round(pt.get("score", 0), 3),
            "wiki_url": f"{WIKI_BASE_URL}/People/{_wiki_slug(dn)}/",
        }
        # Emit the stable person_uri so consumers (pwg_people dedup #6, the
        # citation slug->uri chain #4) can key on identity, not display name.
        if p.get("person_uri"):
            entry["person_uri"] = p["person_uri"]
        for src_key, api_key in _SEARCH_PAYLOAD_TO_API:
            if p.get(src_key):
                entry[api_key] = p[src_key]
        # Fail-closed L3 filter: the Qdrant `facts` payload is copied
        # verbatim into the response with no downstream privacy re-check.
        # Drop explicit-L3 facts, keep untagged. See _filter_qdrant_facts.
        facts = _filter_qdrant_facts(p.get("facts"))
        if facts:
            entry["facts"] = facts
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


# ── User-asserted facts (learning-loop write path) ───────────────────
#
# POST /api/v1/memory/assert lets the assistant durably bank a fact the
# user states in chat ("Jane is my wife") into Oxigraph as a HIGH-
# CONFIDENCE, AUTHORITATIVE fact. This is the missing write half of the
# learning loop: the read half (person pages, memory tab, person_context)
# already surfaces pwg:PersonFact rows; this writes them with
# pwg:factSource "user_asserted" so they outrank mined facts everywhere.
#
# A strong people_search hit attaches the fact to the existing Person; no
# hit mints a minimal Person node (same URI shape as contact_syncer); two+
# plausible hits return needs_disambiguation and write NOTHING -- we never
# guess which "Alex" the user meant.

# Score at or above which a single people_search hit is treated as a
# confident identity match. people_search returns cosine similarity in
# [0, 1]; 0.80 is the same confidence floor the iOS People view uses.
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


# Near-miss field aliases the assistant's ``remember_fact`` tool (and the
# #606 batch shape) have been observed POSTing instead of the canonical
# flat fields. We normalise rather than 400 so a small client/server schema
# drift does not silently drop every user-asserted fact (the live v1.0.1
# symptom: HTTP 400 "couldn't store that fact", nothing banked, no log).
# Canonical field -> ordered list of accepted aliases (first non-empty wins).
_ASSERT_FIELD_ALIASES = {
    "subject": ("subject", "person", "name", "who", "entity"),
    "fact_text": ("fact_text", "fact", "text", "object", "value", "statement"),
    "relationship": ("relationship", "rel", "relation"),
    "asserted_via": ("asserted_via", "via", "source", "channel"),
}


def _coalesce_assert_fields(raw):
    """Normalise a single assert-body dict to the canonical flat fields.

    Accepts the canonical ``{subject, fact_text, relationship?,
    asserted_via?}`` shape AND tolerant near-miss aliases (e.g. ``fact``/
    ``text``/``object`` for ``fact_text``; ``person``/``name`` for
    ``subject``). Unknown keys are ignored. Returns a NEW dict containing
    only the canonical keys that were present (non-empty). This never
    raises and never validates -- validation stays in
    ``_validate_asserted_string`` so the named-field 400s are unchanged.
    """
    out = {}
    if not isinstance(raw, dict):
        return out
    for canonical, aliases in _ASSERT_FIELD_ALIASES.items():
        for alias in aliases:
            if alias in raw and raw[alias] is not None:
                # First alias that is present + not None wins. We keep the
                # raw value (string-or-not) so the validator can reject a
                # non-string with its existing clear message.
                val = raw[alias]
                if isinstance(val, str) and not val.strip():
                    continue  # treat blank-string alias as absent, try next
                out[canonical] = val
                break
    return out


def _normalise_assert_payload(payload):
    """Coerce the many client shapes into ONE canonical flat assert dict.

    Handles:
      - the canonical flat shape (pass-through after aliasing),
      - the #606 batch shape ``{"operations": [ {...}, ... ]}`` -- we take
        the FIRST operation (the assert endpoint is single-fact; a batch
        wrapper around one assert is the observed client bug, not a real
        multi-write),
      - a bare ``[ {...} ]`` list (some clients drop the wrapper),
      - near-miss field names via ``_coalesce_assert_fields``.

    Returns ``(normalised_dict_or_None, error_or_None)``. ``error`` is a
    ready-to-return ``({"error": ...}, 400)`` body only for structurally
    un-handleable input (e.g. a batch with no operations); field-level
    validation (missing subject/fact_text) is left to the caller so the
    error names the field.
    """
    # Unwrap a batch / list wrapper down to a single operation dict.
    if isinstance(payload, dict) and "operations" in payload:
        ops = payload.get("operations")
        if not isinstance(ops, list) or not ops:
            return None, {"error": "'operations' must be a non-empty list."}
        first = ops[0]
        if not isinstance(first, dict):
            return None, {"error": "'operations[0]' must be a JSON object."}
        return _coalesce_assert_fields(first), None
    if isinstance(payload, list):
        if not payload or not isinstance(payload[0], dict):
            return None, {
                "error": "Request body list must contain a JSON object."
            }
        return _coalesce_assert_fields(payload[0]), None
    if isinstance(payload, dict):
        return _coalesce_assert_fields(payload), None
    return None, {"error": "Request body must be a JSON object."}


def _log_assert_request(raw_payload, normalised, *, missing=None):
    """L1-safe diagnostic log for a /api/v1/memory/assert request.

    Logs the SHAPE of the request -- the raw top-level keys, the canonical
    keys that survived normalisation, and (for a 400) which required field
    was missing -- but never the PII VALUES. ``fact_text`` is logged as a
    length, never its content; ``subject`` is logged only as present/absent.
    This makes a live 400 diagnosable from the server log (the v1.0.1 bug
    was un-diagnosable because the handler logged nothing).
    """
    try:
        if isinstance(raw_payload, dict):
            raw_keys = sorted(raw_payload.keys())
        elif isinstance(raw_payload, list):
            raw_keys = ["<list>"]
        else:
            raw_keys = [f"<{type(raw_payload).__name__}>"]
        norm = normalised or {}
        fact = norm.get("fact_text")
        fact_len = len(fact) if isinstance(fact, str) else (
            "non-str" if fact is not None else "absent"
        )
        detail = (
            f"raw_keys={raw_keys} "
            f"normalised={sorted(norm.keys())} "
            f"subject={'present' if norm.get('subject') else 'absent'} "
            f"fact_text_len={fact_len}"
        )
        if missing:
            detail += f" REJECTED missing={missing}"
        print(f"[memory/assert] {detail}", file=sys.stderr, flush=True)
    except Exception:
        # Logging must never break the request path.
        pass


def api_memory_assert(payload, now=None):
    """Handle POST /api/v1/memory/assert.

    Durably bank a user-asserted fact into Oxigraph. ``payload`` is the
    parsed JSON body; ``now`` is an injectable datetime (defaults to
    ``datetime.now(timezone.utc)``) so tests can pin the timestamp.

    The body is first normalised (``_normalise_assert_payload``) so the
    canonical flat shape, the #606 batch shape, and near-miss field names
    all resolve to ``{subject, fact_text, relationship?, asserted_via?}``
    before validation. A truly missing required field still returns 400
    naming that field.

    Returns ``(body, status)``. See the module-level comment above for the
    behaviour contract. Degrades gracefully (no 5xx) on Oxigraph failure,
    mirroring ``api_people_forget``'s degraded_reasons pattern.
    """
    from datetime import timezone

    raw_payload = payload
    normalised, norm_err = _normalise_assert_payload(payload)
    if norm_err is not None:
        _log_assert_request(raw_payload, None, missing="<malformed body>")
        return norm_err, 400
    payload = normalised
    _log_assert_request(raw_payload, payload)

    if not isinstance(payload, dict):
        return {"error": "Request body must be a JSON object."}, 400

    # 0. USER_ID guard. The asserted fact carries ``pwg:belongsToUser
    # <USER_URI>``. With USER_ID unset, USER_URI is "" and we would emit
    # ``pwg:belongsToUser <>`` -- an empty *relative* IRI that Oxigraph's
    # /update endpoint silently resolves against the request URL, writing
    # garbage provenance such as ``<http://localhost:7878/update>``. The
    # read path (api_memory_list) already guards on USER_URI and degrades;
    # the WRITE path must too, so a mis-onboarded Hub fails loudly instead
    # of corrupting the graph. Mirrors api_memory_list's degraded shape.
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
        _log_assert_request(raw_payload, payload, missing="subject")
        return err, 400
    fact_text, err = _validate_asserted_string(
        payload.get("fact_text"), field="fact_text", required=True
    )
    if err:
        _log_assert_request(raw_payload, payload, missing="fact_text")
        return err, 400
    relationship, err = _validate_asserted_string(
        payload.get("relationship"), field="relationship", required=False
    )
    if err:
        _log_assert_request(raw_payload, payload, missing="relationship")
        return err, 400
    asserted_via, err = _validate_asserted_string(
        payload.get("asserted_via"), field="asserted_via",
        required=False, max_len=80
    )
    if err:
        _log_assert_request(raw_payload, payload, missing="asserted_via")
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
                candidates.append({
                    "name": r.get("name", ""),
                    "slug": r.get("slug", ""),
                    "uri": _resolve_person_uri_by_name(r.get("name", "")),
                })
            return {
                "status": "needs_disambiguation",
                "candidates": candidates,
            }, 200
        # Clear leader: fall through and attach to it.
        chosen = strong_sorted[0]
        person_slug = chosen.get("slug")
        person_uri = _resolve_person_uri_by_name(chosen.get("name", ""))
    elif len(strong) == 1:
        chosen = strong[0]
        person_slug = chosen.get("slug")
        person_uri = _resolve_person_uri_by_name(chosen.get("name", ""))

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
    # User-asserted facts come from a private channel (the owner typing a
    # fact to the assistant), so per the canonical privacy model they are
    # L1 = private/assistant-usable, never L2/publishable. This is the
    # contact_syncer.privacy_model rule for source "user_asserted",
    # inlined here because ical-server.py is a hyphenated, non-importable
    # script and the value is unconditional. Keep in sync with
    # privacy_model.level_for(source="user_asserted") -> "L1".
    fact_triples = (
        f'  <{fact_uri}> a pwg:PersonFact ;\n'
        f'    pwg:aboutPerson <{person_uri}> ;\n'
        f'    pwg:factText "{esc_fact}" ;\n'
        f'    pwg:factSource "user_asserted" ;\n'
        f'    pwg:privacyLevel "L1" ;\n'
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


# ── Memory tab (CM031 iOS Companion v1.0 LB) ─────────────────────────
#
# The Memory tab is the user's transparency surface: "what has Ostler
# actually inferred about me?" GET returns the user's own PersonFact
# rows from Oxigraph, overlaid with any corrections the user has
# previously made via POST /api/v1/memory/correct/{id}. The correction
# table is append-only, so the original fact is never overwritten in
# storage -- only the response shape reflects the latest correction.
#
# Wire shape (GET):
#   {
#     "facts": [
#       {
#         "id": <stable fact id, used as path-param for correct/forget>,
#         "predicate": <factDomain e.g. "calendar" / "career" / "address">,
#         "object": <human-readable fact text>,
#         "source": <factSource enum, e.g. "google_calendar">,
#         "source_label": <UI-friendly label, e.g. "from your calendar">,
#         "confidence": <0.0-1.0 float>,
#         "corrected": <bool, true if the user has corrected this fact>
#       }, ...
#     ],
#     "count": <int>,
#     "degraded": <bool, only present if upstream unreachable>
#   }
#
# Wire shape (POST /api/v1/memory/correct/{id}):
#   request:  {"newValue": "<new text>"}   OR  {"forget": true}
#   response: {"ok": true, "id": "<id>", "action": "correct"|"forget"}

# Map factSource enum -> UI-friendly label.
# Kept in sync with the CM031 MemoryFactSource enum so iOS renders the
# same label even if the wire `source_label` is empty (defence in
# depth -- iOS still maps `source` independently).
_MEMORY_SOURCE_LABELS = {
    "google_calendar":     "from your calendar",
    "icloud_calendar":     "from your calendar",
    "imessage":            "from your iMessage",
    "whatsapp":            "from your WhatsApp",
    "email":               "from your email",
    "gmail":               "from your email",
    "linkedin":            "from your LinkedIn",
    "facebook":            "from Facebook",
    "safari":              "from your browser",
    "wiki":                "from your wiki",
    "manual":              "you told Ostler",
    "inferred":            "inferred",
}


def _memory_source_label(source: str) -> str:
    """Map a factSource enum value to a UI-friendly label.

    Unknown sources fall back to a generic "from <source>" rather than
    leaking the raw enum to the customer.
    """
    if not source:
        return "inferred"
    return _MEMORY_SOURCE_LABELS.get(
        source, f"from {source.replace('_', ' ')}"
    )


def _memory_corrections_connect():
    """Open the memory_corrections SQLite database.

    Uses the encrypted-DB wrapper from ostler_security when a key is
    configured, falling back (with a loud warning) to plaintext SQLite
    when running unencrypted. Mirrors the COACH_DB pattern in
    ``coach_recent`` so a customer Hub with no key set still works.
    """
    MEMORY_CORRECTIONS_DB.parent.mkdir(parents=True, exist_ok=True)
    db_path = str(MEMORY_CORRECTIONS_DB)
    if _ENCRYPTION_KEY:
        conn = _secure_connect(db_path, _ENCRYPTION_KEY)
    else:
        _warn_plaintext_once(db_path)
        conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn


def _ensure_memory_corrections_schema(conn) -> None:
    """Create the corrections table if it does not yet exist.

    Append-only: every correction is a new row. Reads collapse to the
    latest row per ``fact_id`` (corrected_at DESC). The
    ``previous_value`` column captures what the user replaced so we can
    surface "you corrected this" without re-reading Oxigraph.

    TODO(security, v1.0.1): chain rows with an HMAC over the previous
    row's digest so tamper-detection is possible. The brief calls this
    out but ostler_security does not yet expose an HMAC-chain helper;
    encryption-at-rest via SQLCipher is the v1.0 floor.
    """
    conn.execute(
        "CREATE TABLE IF NOT EXISTS memory_corrections (\n"
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,\n"
        "  fact_id TEXT NOT NULL,\n"
        "  action TEXT NOT NULL,\n"
        "  previous_value TEXT,\n"
        "  new_value TEXT,\n"
        "  created_at TEXT NOT NULL\n"
        ")"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_memory_corrections_fact_id "
        "ON memory_corrections(fact_id)"
    )
    conn.commit()


def _memory_load_corrections() -> dict:
    """Return the latest correction per fact_id as a dict.

    Returns ``{fact_id: {"action": "correct"|"forget", "new_value":
    str|None, "created_at": str}}`` so callers can look up corrections
    by O(1). Missing DB or any read error returns an empty dict
    (corrections degrade silently; the user still sees their facts).
    """
    if not MEMORY_CORRECTIONS_DB.exists():
        return {}
    try:
        conn = _memory_corrections_connect()
    except Exception:
        return {}
    try:
        _ensure_memory_corrections_schema(conn)
        # latest row per fact_id (group-by-max pattern). SQLite handles
        # the correlated subquery efficiently because of the index.
        rows = conn.execute(
            "SELECT fact_id, action, new_value, created_at "
            "FROM memory_corrections AS c1 "
            "WHERE id = (SELECT MAX(id) FROM memory_corrections AS c2 "
            "            WHERE c2.fact_id = c1.fact_id)"
        ).fetchall()
    except Exception:
        return {}
    finally:
        conn.close()
    return {
        row["fact_id"]: {
            "action": row["action"],
            "new_value": row["new_value"],
            "created_at": row["created_at"],
        }
        for row in rows
    }


def _memory_fact_id(uri: str) -> str:
    """Stable id derived from the fact URI.

    The full URI is too long + injection-shaped for a URL path param,
    so we strip the namespace prefix when present and use what remains
    (which is itself a UUID + "fact_" prefix from the writers). Both
    forms are accepted on the POST path -- we round-trip them through
    the corrections table verbatim.
    """
    prefix = "https://pwg.dev/ontology#"
    if uri.startswith(prefix):
        return uri[len(prefix):]
    return uri


def _memory_query_facts() -> list:
    """SPARQL: every PersonFact about the configured user.

    Returns a list of raw fact dicts (uri, text, source, domain,
    confidence, validFrom). Empty list on any failure -- callers wrap
    into a degraded response. We accept facts where source/domain are
    missing (older writers may not have set them) and fall back to
    sensible defaults so the row still renders.
    """
    if not USER_URI:
        return []
    # Confidence is optional on the writer side; coalesce in Python
    # rather than the SPARQL query so we don't drop rows that lack it.
    sparql = (
        'PREFIX pwg: <{ns}>\n'
        'SELECT ?fact ?text ?source ?domain ?conf ?validFrom WHERE {{\n'
        '  ?fact a pwg:PersonFact ; pwg:aboutPerson <{user}> ; '
        'pwg:factText ?text .\n'
        '  OPTIONAL {{ ?fact pwg:factSource ?source }}\n'
        '  OPTIONAL {{ ?fact pwg:factDomain ?domain }}\n'
        '  OPTIONAL {{ ?fact pwg:confidence ?conf }}\n'
        '  OPTIONAL {{ ?fact pwg:validFrom ?validFrom }}\n'
        '  FILTER NOT EXISTS {{ ?fact pwg:validTo ?end }}\n'
        '}}'.format(ns=PWG_NS, user=USER_URI)
    )
    return _sparql_select(sparql)


def _hygiene_reader():
    """Import the canonical memory-hygiene read-side consumer.

    ``ostler_hygiene`` lives at the repo root (``../ostler_hygiene``);
    mirror the meeting_syncer/identity_resolver import idiom used
    elsewhere in this file. Returns the module, or ``None`` on any
    failure (package absent on this deployment, import error) so the
    caller degrades to raw source facts -- absence of the overlay must
    never break a read.
    """
    try:
        import sys as _sys
        from pathlib import Path as _P
        _repo_root = _P(__file__).resolve().parent.parent
        if str(_repo_root) not in _sys.path:
            _sys.path.insert(0, str(_repo_root))
        from ostler_hygiene import reader as _reader
        return _reader
    except Exception:
        return None


def _hygiene_overlay():
    """Load the hygiene verdict overlay for the memory read path.

    Returns ``(reader_module_or_None, verdicts_dict)``. Reading the
    overlay is best-effort and side-effect-free: a missing package,
    an unreachable Oxigraph or a graph that has never been written all
    collapse to ``{}`` so the memory list behaves exactly as it did
    before the overlay existed (facts active, ranked by raw confidence).
    """
    reader = _hygiene_reader()
    if reader is None:
        return None, {}
    return reader, reader.load_verdicts(_sparql_select)


# ---------------------------------------------------------------------------
# Memory-Hygiene supersession overlay + deterministic current-employer read.
#
# BUG: the daily brief surfaced a stale/arbitrary employer as "current".
# Root cause (see CM061 design/SAMANTHA_STALE_FACT_FINDINGS.md): employer
# was read either as an *arbitrary* name-matched scalar ``pwg:organization``
# triple (Surface B, person_context/person_enrichment) or confidence-first
# from undated self-facts (Surface A, api_memory_list) -- neither respected
# recency, validity, supersession, or cross-signal corroboration, and the
# already-built Memory-Hygiene verdicts (urn:pwg:hygiene) had ZERO read
# consumers.
#
# The fix reads the CURRENT employer deterministically from the reified,
# dated ``career_position`` PersonFacts that hang off the *operator's own
# URI* (never an arbitrary name match -- so a namesake person's node can
# never leak in), overlays the hygiene supersession verdicts, and
# corroborates with the operator's email-domain identity. A closed career
# fact (one carrying ``pwg:endDate`` / "…to <year>") is treated as
# end-of-validity and can never be selected as current.
# ---------------------------------------------------------------------------

# Employer is a LONG-half-life fact, not evergreen (Q4 resolved by the
# operator: people change jobs). We keep the current employer sticky for
# ~3 years of corroboration but let a newer, corroborated employer
# supersede it. This constant documents that policy for the clarify
# trigger designed in EMPLOYER_IDENTITY_MERGE_PLAN.md.
EMPLOYER_HALF_LIFE_DAYS = 365 * 3

_HYGIENE_GRAPH = "urn:pwg:hygiene"
# Verdict statuses that must drop a fact from every read surface. Mirrors
# ostler_hygiene.model STATUS_SUPERSEDED / STATUS_ARCHIVED / STATUS_DELETED.
_HYGIENE_DROP_STATUSES = frozenset({"superseded", "archived", "deleted"})


def _hygiene_verdicts() -> dict:
    """LEFT-JOIN source: the Memory-Hygiene verdict overlay.

    Returns ``{fact_uri: {"status": str, "effective_weight": float|None,
    "superseded_by": str|None}}`` read from the isolated
    ``<urn:pwg:hygiene>`` named graph. Never raises: any failure (graph
    absent, Oxigraph down, hygiene never run) yields ``{}`` so the read
    paths degrade to raw source facts exactly as before this overlay
    existed -- absence of a verdict means "active + full weight" per the
    hygiene contract (ostler_hygiene/weight.py).
    """
    try:
        rows = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?fact ?status ?eff ?supBy WHERE {{\n'
            '  GRAPH <{g}> {{\n'
            '    ?v a pwg:HygieneVerdict ; pwg:verdictFact ?fact ; '
            'pwg:factStatus ?status .\n'
            '    OPTIONAL {{ ?v pwg:effectiveWeight ?eff }}\n'
            '    OPTIONAL {{ ?v pwg:supersededBy ?supBy }}\n'
            '  }}\n'
            '}}'.format(ns=PWG_NS, g=_HYGIENE_GRAPH)
        )
    except Exception:
        return {}
    out = {}
    for r in rows:
        uri = r.get("fact")
        if not uri:
            continue
        try:
            eff = float(r["eff"]) if r.get("eff") not in (None, "") else None
        except (TypeError, ValueError):
            eff = None
        out[uri] = {
            "status": (r.get("status") or "active").strip().lower(),
            "effective_weight": eff,
            "superseded_by": r.get("supBy") or None,
        }
    return out


def _hygiene_dropped(uri: str, verdicts: dict) -> bool:
    """True if the fact carries a superseded/archived/deleted verdict."""
    v = verdicts.get(uri)
    return bool(v) and v.get("status") in _HYGIENE_DROP_STATUSES


def _hygiene_weight(uri: str, verdicts: dict, fallback: float) -> float:
    """effectiveWeight from the overlay, else the raw confidence fallback.

    This is the rank key the hygiene design specifies consumers use in
    place of raw confidence (weight.py:166).
    """
    v = verdicts.get(uri)
    if v and v.get("effective_weight") is not None:
        return v["effective_weight"]
    return fallback


def _hygiene_drop_retired(fact_rows):
    """Drop the fact rows the Memory-Hygiene pass retired.

    Read-side consumer for the person-page fact lists (``person_context`` /
    ``person_enrichment``). ``build_facts_query`` (ostler_hygiene/graph_io)
    scores facts about EVERY person, not just the operator, so a person
    page must honour the same superseded/archived/deleted verdicts the
    memory tab (``api_memory_list``) already does -- otherwise a fact the
    pass retired keeps surfacing on the person card ("ships dark" on these
    two surfaces).

    Each row is keyed by its ``f`` binding (the fact URI selected by the
    caller's SPARQL). Routed through the ONE canonical overlay reader
    (``_hygiene_overlay`` -> ``ostler_hygiene.reader``); no second, drifting
    verdict parser. Fail-safe: an empty overlay (hygiene never run, Oxigraph
    down, absent graph) or a row with no ``f`` binding is kept unchanged --
    absence of a verdict means "active" per the hygiene contract. Never
    raises.
    """
    hygiene, verdicts = _hygiene_overlay()
    if hygiene is None or not verdicts:
        return fact_rows
    return [
        r for r in fact_rows
        if not hygiene.is_dropped(r.get("f", ""), verdicts)
    ]


def _career_month(value: str) -> str:
    """Normalise a career date to a lexically-sortable ``YYYY-MM`` prefix.

    Accepts ``YYYY`` / ``YYYY-MM`` / ``YYYY-MM-DD`` / ISO datetimes.
    Returns ``""`` when absent so undated facts sort last.
    """
    if not value:
        return ""
    return str(value).strip()[:7]


_ALNUM = re.compile(r"[^a-z0-9]+")


def _norm_org(org: str) -> str:
    """Lower-case, strip punctuation/whitespace for org comparison."""
    return _ALNUM.sub("", (org or "").lower())


def _operator_email_domains() -> set:
    """Email-domain identities on the operator's OWN node.

    An ``acme.com`` email identity corroborates an "ACME" career fact.
    Read strictly off ``USER_URI`` so a namesake's contact email can
    never contribute. Never raises.
    """
    if not USER_URI:
        return set()
    try:
        rows = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?value WHERE {{\n'
            '  <{user}> pwg:hasIdentifier ?id .\n'
            '  ?id pwg:identifierType ?type ; pwg:identifierValue ?value .\n'
            '  FILTER(LCASE(STR(?type)) = "email")\n'
            '}}'.format(ns=PWG_NS, user=USER_URI)
        )
    except Exception:
        return set()
    domains = set()
    for r in rows:
        val = (r.get("value") or "").strip().lower()
        if "@" in val:
            dom = val.rsplit("@", 1)[1]
            if dom:
                domains.add(dom)
    return domains


# Free/consumer email hosts never corroborate an *employer* -- someone
# emailing from gmail.com does not work at "Gmail".
_GENERIC_EMAIL_DOMAINS = frozenset({
    "gmail.com", "googlemail.com", "outlook.com", "hotmail.com",
    "live.com", "yahoo.com", "icloud.com", "me.com", "proton.me",
    "protonmail.com", "aol.com", "msn.com", "gmx.com",
})


def _domain_corroborates(org: str, domains: set):
    """Return the matching domain if an email domain backs this org.

    ``ACME`` ↔ ``acme.com`` corroborates; consumer hosts never do.
    """
    o = _norm_org(org)
    if not o:
        return None
    for dom in domains:
        if dom in _GENERIC_EMAIL_DOMAINS:
            continue
        label = _norm_org(dom.split(".")[0])
        if label and (label in o or o in label):
            return dom
    return None


def _query_operator_career_facts() -> list:
    """Reified, dated ``career_position`` facts about the operator.

    Read off ``USER_URI`` only. Returns raw binding dicts (fact, org,
    title, startDate, endDate, factText, conf). Never raises.

    F6 (Archie re-review — keying decision, RESOLVED):
    The resolver keys on ``pwg:factType "career_position"``, NOT
    ``pwg:factDomain = "relationship"``. This is CORRECT per CM061
    design/EMPLOYER_IDENTITY_MERGE_PLAN.md §0/§2/§3/§4: the operator's
    employer history is modelled as reified, dated ``career_position``
    PersonFacts hanging off the operator's own URI (Node-A owns "the
    reified ``career_position`` facts"), and an onboarding current-employer
    correction writes a ``career_position`` supersession (§3.3, §4). The
    generic ``factDomain = "relationship"`` stamp on the
    ``POST /api/v1/memory/assert`` write path is a SEPARATE, broader bucket
    (any user-asserted relationship fact) and is deliberately NOT the key
    here — narrowing to ``career_position`` is what keeps a namesake's
    generic relationship facts out of the employer resolution. Making a
    user-typed "I now work at X" reach this resolver is a WRITE-side change
    to that assert endpoint (emit a ``career_position`` fact), out of scope
    for this read-path PR; tracked as the first-pass MED finding, not a
    defect in the resolver's keying.
    """
    if not USER_URI:
        return []
    try:
        return _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?fact ?org ?title ?startDate ?endDate ?factText ?conf '
            'WHERE {{\n'
            '  ?fact a pwg:PersonFact ; pwg:aboutPerson <{user}> ; '
            'pwg:factType "career_position" .\n'
            '  OPTIONAL {{ ?fact pwg:organization ?org }}\n'
            '  OPTIONAL {{ ?fact pwg:jobTitle ?title }}\n'
            '  OPTIONAL {{ ?fact pwg:startDate ?startDate }}\n'
            '  OPTIONAL {{ ?fact pwg:endDate ?endDate }}\n'
            '  OPTIONAL {{ ?fact pwg:factText ?factText }}\n'
            '  OPTIONAL {{ ?fact pwg:confidence ?conf }}\n'
            '  FILTER NOT EXISTS {{ ?fact pwg:validTo ?vt }}\n'
            '}}'.format(ns=PWG_NS, user=USER_URI)
        )
    except Exception:
        return []


def _select_current_employer() -> dict:
    """Deterministically resolve the operator's CURRENT employer.

    Combines three signals (the operator's stated corroboration
    requirement): the dated LinkedIn ``career_position`` facts, the
    Memory-Hygiene supersession overlay, and the operator's own
    email-domain identity. Selection is fully deterministic:

      1. drop career facts the hygiene overlay marks
         superseded/archived/deleted;
      2. keep only OPEN-ENDED facts (no ``pwg:endDate`` -> "to present")
         as current-employer candidates -- a fact carrying an end date is
         a *former* role and can never be selected as current;
      3. rank the survivors by (email-domain corroboration, latest
         ``startDate``, effectiveWeight/confidence, org name) and take
         the top;
      4. if two *different* open-ended orgs tie on all of the above,
         surface a conflict instead of guessing.

    Because candidates are gathered strictly off ``USER_URI`` and the
    reified career facts, an arbitrary name-matched scalar
    ``pwg:organization`` -- including a namesake real person's employer
    wrongly sharing the operator's name-space -- can never be returned.

    Returns a dict; ``found: False`` when no evidence exists. Never
    raises.
    """
    result = {"found": False}
    if not USER_URI:
        return result

    verdicts = _hygiene_verdicts()
    domains = _operator_email_domains()
    raw = _query_operator_career_facts()
    # F3 (Archie re-review): the operator's OWN memory-tab corrections are
    # authoritative over the source triples. A career fact the operator has
    # explicitly forgotten via POST /api/v1/memory/correct/{id} MUST never be
    # selectable as the current employer. Before this fix the corrections
    # overlay was consulted only by ``api_memory_list``, so a user's manual
    # "forget" silently bypassed the resolver and the forgotten employer kept
    # surfacing on the brief. Load the overlay fresh here and drop any
    # forgotten career fact BEFORE ranking. Degrades safely: a missing
    # corrections DB yields ``{}`` so the behaviour is unchanged.
    corrections = _memory_load_corrections()

    # Was ANY operator email-domain identity linked to USER_URI to attempt
    # corroboration with? On the operator's REAL, fragmented graph the
    # employer-email identity lives on a separate, un-merged fragment node
    # (EMPLOYER_IDENTITY_MERGE_PLAN.md -- "Node-D"), NOT on USER_URI, so
    # ``domains`` is empty and multi-signal corroboration is IMPOSSIBLE --
    # not merely unmatched. We track that distinction so an uncorroborated
    # result on a fragmented graph can be flagged honestly instead of
    # silently no-opping to a bare, over-confident ``career_fact``.
    corroboration_available = bool(domains)

    candidates = []
    former = []
    for r in raw:
        uri = r.get("fact", "")
        if uri and _hygiene_dropped(uri, verdicts):
            continue
        # F3: a user-forgotten career fact drops out entirely -- not even a
        # ``former`` candidate. Corrections are keyed by the namespace-
        # stripped fact id (see ``_memory_fact_id`` / ``api_memory_correct``).
        # ``forget`` is the memory tab's "this is wrong, drop it" instruction;
        # it must supersede the source triple on the resolver too.
        if uri:
            _corr = corrections.get(_memory_fact_id(uri))
            if _corr and _corr.get("action") == "forget":
                continue
        org = (r.get("org") or "").strip()
        if not org:
            continue
        try:
            conf = float(r["conf"]) if r.get("conf") not in (None, "") else 0.5
        except (TypeError, ValueError):
            conf = 0.5
        end = (r.get("endDate") or "").strip()
        text = (r.get("factText") or "").strip()
        cand = {
            "employer": org,
            "job_title": (r.get("title") or "").strip(),
            "start_date": _career_month(r.get("startDate", "")),
            "end_date": _career_month(end),
            "fact_uri": uri,
            "weight": _hygiene_weight(uri, verdicts, conf),
            "corroborating_domain": _domain_corroborates(org, domains),
            "fact_text": text,
        }
        if end:
            former.append(cand)
        else:
            candidates.append(cand)

    if not candidates:
        # No open-ended career fact. If a single non-generic employer
        # email domain exists, surface it as a weak, email-only signal
        # rather than falling back to an arbitrary scalar org.
        emp_domains = [d for d in domains if d not in _GENERIC_EMAIL_DOMAINS]
        if len(emp_domains) == 1:
            dom = emp_domains[0]
            return {
                "found": True,
                "employer": dom.split(".")[0].upper(),
                "job_title": "",
                "start_date": "",
                "confidence": 0.4,
                "conflict": False,
                "corroboration": [f"email_domain ({dom})"],
                "signal": "email_only",
                # Weak email-only signal: no career fact to corroborate,
                # but the identity IS on USER_URI so this is not the
                # fragmented-graph no-op.
                "verified": False,
                "corroboration_available": True,
                "identity_fragmented": False,
                "source_fact": None,
                "former_employers": [c["employer"] for c in former],
            }
        return result

    # Deterministic rank: corroborated-first, then latest start, then
    # weight, then org name (final tie-break for total determinism).
    def _rank(c):
        return (
            1 if c["corroborating_domain"] else 0,
            c["start_date"],
            c["weight"],
            c["employer"],
        )

    candidates.sort(key=_rank, reverse=True)
    best = candidates[0]

    # Conflict: another open-ended candidate with a DIFFERENT org that
    # ranks identically (same corroboration + same start) -- genuinely
    # indistinguishable, so surface rather than guess.
    best_key = _rank(best)[:2]
    best_norm = _norm_org(best["employer"])
    conflicting = [
        c["employer"] for c in candidates[1:]
        if _rank(c)[:2] == best_key and _norm_org(c["employer"]) != best_norm
    ]

    corroborated = bool(best["corroborating_domain"])

    # A career fact stands, but if the operator has NO email-domain
    # identity linked to USER_URI at all, multi-signal corroboration was
    # IMPOSSIBLE (not merely unmatched). That is the operator's real,
    # fragmented graph: the employer-email identity sits on an un-merged
    # fragment node, so ``domains`` came back empty and the corroboration
    # step silently no-ops. Make the no-op HONEST -- flag the result
    # unverified, cap its confidence below the confident band, add a
    # corroboration note, and leave a stderr marker. Full efficacy of this
    # resolver depends on the onboarding identity-merge (CM051 end-of-
    # install confirmation, EMPLOYER_IDENTITY_MERGE_PLAN.md) collapsing the
    # fragments onto USER_URI so ``domains`` is populated and this branch
    # stops firing.
    identity_fragmented = (not corroborated) and (not corroboration_available)

    corroboration = ["linkedin_career (to present)"]
    if corroborated:
        corroboration.append(f"email_domain ({best['corroborating_domain']})")
    if best["start_date"]:
        corroboration.append(f"recency (start {best['start_date']})")
    if identity_fragmented:
        corroboration.append(
            "uncorroborated: no operator email identity linked to USER_URI "
            "(corroboration impossible pending identity merge)"
        )

    # Confidence blends the signals: an open-ended career fact that a
    # non-generic email domain corroborates is high-confidence current,
    # even when the source fact carries no pwg:confidence of its own
    # (the confirmed shape) -- the two independent signals are what
    # earn the confidence. effectiveWeight/confidence only lifts the
    # base, never caps it.
    confidence = max(best["weight"], 0.5)    # open-ended career fact base
    confidence += 0.2                        # "to present" open-ended
    if corroborated:
        confidence += 0.25                   # email-domain corroboration
    if conflicting:
        confidence = min(confidence, 0.5)    # unresolved conflict caps it
    if identity_fragmented:
        # An uncorroborated guess on a fragmented graph must never read as
        # a confident answer. Cap it below the corroborated/normal band.
        confidence = min(confidence, 0.4)
    confidence = round(max(0.0, min(0.99, confidence)), 3)

    if identity_fragmented:
        signal = "career_fact_unverified"
    elif corroborated:
        signal = "corroborated"
    else:
        signal = "career_fact"

    if identity_fragmented:
        print(
            "[current-employer] uncorroborated result for operator employer "
            f"{best['employer']!r}: no email identity linked to USER_URI -- "
            "corroboration impossible on a fragmented graph. Result flagged "
            "unverified pending identity merge "
            "(EMPLOYER_IDENTITY_MERGE_PLAN.md).",
            file=sys.stderr,
            flush=True,
        )

    return {
        "found": True,
        "employer": best["employer"],
        "job_title": best["job_title"],
        "start_date": best["start_date"],
        "confidence": confidence,
        "conflict": bool(conflicting),
        "conflicting_employers": conflicting,
        "corroboration": corroboration,
        "signal": signal,
        # Honest corroboration status. ``verified`` is True only when an
        # operator email domain actually backs the org. ``identity_
        # fragmented`` marks the specific no-op case where corroboration
        # could not even be attempted because no operator email identity
        # is linked to USER_URI (pending identity merge).
        "verified": corroborated,
        "corroboration_available": corroboration_available,
        "identity_fragmented": identity_fragmented,
        "source_fact": best["fact_uri"] or None,
        "former_employers": [c["employer"] for c in former],
    }


def _current_employer_safe() -> dict:
    """``_select_current_employer`` wrapped so no read path can 5xx."""
    try:
        return _select_current_employer()
    except Exception:
        return {"found": False}


def api_memory_list():
    """Handle GET /api/v1/memory.

    Returns the user's own facts overlaid with any user-applied
    corrections. Sorted by (confidence desc, validFrom desc) and capped
    at ``MEMORY_LIMIT``. Never 5xx: on upstream failure returns 200
    with ``{"facts": [], "count": 0, "degraded": true, "reason": ...}``
    so the iOS Memory tab can decide between empty-state and
    degraded-banner UX.

    USER_ID guard: a Hub with no USER_ID configured cannot answer this
    endpoint meaningfully (we'd return a global fact dump). We return
    the degraded shape with reason="user_id_not_configured" so the iOS
    tab can prompt the user to finish onboarding.
    """
    if not USER_URI:
        return {
            "facts": [],
            "count": 0,
            "degraded": True,
            "reason": "user_id_not_configured",
        }
    try:
        raw_facts = _memory_query_facts()
    except Exception as exc:
        return {
            "facts": [],
            "count": 0,
            "degraded": True,
            "reason": f"oxigraph_unreachable: {exc}",
        }

    corrections = _memory_load_corrections()
    # Memory-Hygiene overlay (LEFT JOIN urn:pwg:hygiene). Empty {} when
    # hygiene has never run -> behaviour is unchanged from pre-overlay.
    # A verdict lets the pass RETIRE a fact (superseded/archived/deleted)
    # and re-rank survivors by effectiveWeight instead of raw confidence.
    # Routed through the canonical ostler_hygiene reader (Phase 2); the
    # employer resolver's own inline overlay is orthogonal.
    hygiene, verdicts = _hygiene_overlay()

    out = []
    for row in raw_facts:
        uri = row.get("fact", "")
        if hygiene is not None and hygiene.is_dropped(uri, verdicts):
            # Retired by the hygiene pass -- withheld from the surface
            # exactly like a user "forget" (the source triple stays put).
            continue
        fact_id = _memory_fact_id(uri)
        text = row.get("text", "") or ""
        source = row.get("source", "") or ""
        domain = row.get("domain", "") or "fact"
        try:
            confidence = float(row.get("conf", 0.5))
        except (TypeError, ValueError):
            confidence = 0.5
        valid_from = row.get("validFrom", "") or ""
        # Rank key: the overlay's effectiveWeight where present, else raw
        # confidence (unchanged pre-hygiene ordering for un-scored facts).
        rank = (
            hygiene.rank_weight(uri, verdicts, confidence)
            if hygiene is not None else confidence
        )

        corrected = False
        correction = corrections.get(fact_id)
        if correction:
            if correction["action"] == "forget":
                # Hide forgotten facts. The row stays in Oxigraph (we
                # don't delete the original triple); the user's
                # explicit "forget" instruction simply withholds it
                # from this surface.
                continue
            if correction["action"] == "correct" and correction.get(
                "new_value"
            ):
                text = correction["new_value"]
                source = "user_correction"
                corrected = True

        out.append({
            "id": fact_id,
            "predicate": domain,
            "object": text,
            "source": source,
            "source_label": (
                "you corrected this"
                if corrected else _memory_source_label(source)
            ),
            "confidence": round(confidence, 3),
            "corrected": corrected,
            "valid_from": valid_from,
            # Private sort key (hygiene effectiveWeight or confidence);
            # popped before the response so the wire shape is unchanged.
            "_rank": rank,
        })

    # Sort by (rank desc, valid_from desc) where rank is the hygiene
    # overlay's effectiveWeight when present, else raw confidence
    # (unchanged pre-hygiene ordering). Stable for ties so the order
    # stays deterministic between calls -- the iOS list uses the order
    # to drive its diffable data source.
    out.sort(
        key=lambda f: (f["_rank"], f["valid_from"]),
        reverse=True,
    )
    out = out[:MEMORY_LIMIT]
    for f in out:
        f.pop("_rank", None)
    response = {"facts": out, "count": len(out)}
    # Overlay the deterministically-resolved current employer so the
    # brief LLM never has to guess it from the flat fact list. Guarded:
    # a failure here must not degrade the Memory tab.
    employer = _current_employer_safe()
    if employer.get("found"):
        response["current_employer"] = employer
    return response


def api_memory_correct(fact_id: str, payload: dict):
    """Handle POST /api/v1/memory/correct/{fact_id}.

    Body shape: ``{"newValue": "<text>"}`` for an edit OR
    ``{"forget": true}`` for a "this is wrong, forget it" instruction.
    Returns ``{"ok": true, "id": <fact_id>, "action": "correct"|"forget"}``.

    Append-only: every call is a new row in the corrections table. The
    next GET /api/v1/memory overlays the latest correction per fact_id
    onto the underlying PersonFact, so the user sees the corrected
    value immediately without us mutating the Oxigraph triple.

    Validation: fact_id must be non-empty + slug-shaped (the writers
    produce uuid5-derived hex strings prefixed with ``fact_``). We
    accept the URI form too in case the iOS client forgets to strip the
    prefix; both round-trip cleanly because we key on the literal value.
    """
    if not fact_id or len(fact_id) > 200:
        return {"error": "Invalid fact_id"}, 400

    is_forget = bool(payload.get("forget"))
    new_value = payload.get("newValue")
    if not is_forget and (not isinstance(new_value, str) or not new_value.strip()):
        return {
            "error": "Body must include either 'newValue' (string) "
                     "or 'forget' (boolean true)."
        }, 400
    if new_value and len(new_value) > 4096:
        return {"error": "newValue too long (max 4096 chars)."}, 400

    action = "forget" if is_forget else "correct"
    stored_new_value = None if is_forget else new_value.strip()
    now = datetime.utcnow().isoformat() + "Z"

    try:
        conn = _memory_corrections_connect()
    except Exception as exc:
        return {
            "ok": False,
            "degraded": True,
            "reason": f"corrections_db_unreachable: {exc}",
        }, 503
    try:
        _ensure_memory_corrections_schema(conn)
        conn.execute(
            "INSERT INTO memory_corrections "
            "(fact_id, action, previous_value, new_value, created_at) "
            "VALUES (?, ?, ?, ?, ?)",
            (fact_id, action, None, stored_new_value, now),
        )
        conn.commit()
    except Exception as exc:
        conn.close()
        return {
            "ok": False,
            "degraded": True,
            "reason": f"corrections_db_write_failed: {exc}",
        }, 503
    conn.close()

    return {"ok": True, "id": fact_id, "action": action}, 200


def person_context(name):
    """Gather everything known about a person by name."""
    esc = name.replace("\\", "\\\\").replace('"', '\\"')
    # last_contact is the MAX of the four per-source predicates, computed
    # in Python after the query so each source remains independently
    # OPTIONAL (a missing source must not exclude the row).
    persons = _sparql_select(
        'PREFIX pwg: <{ns}>\n'
        'SELECT ?person ?name ?org ?title ?rel ?howMet ?notes ?bday ?priv\n'
        '       ?mergedInto\n'
        '       ?lcCalendar ?lcWhatsApp ?lcEmail ?lcIMessage WHERE {{\n'
        '  ?person a pwg:Person ; pwg:displayName ?name .\n'
        '  FILTER(CONTAINS(LCASE(?name), LCASE("{q}")))\n'
        '  OPTIONAL {{ ?person pwg:organization ?org }}\n'
        '  OPTIONAL {{ ?person pwg:jobTitle ?title }}\n'
        '  OPTIONAL {{ ?person pwg:relationship ?rel }}\n'
        '  OPTIONAL {{ ?person pwg:howWeMet ?howMet }}\n'
        '  OPTIONAL {{ ?person pwg:mergedInto ?mergedInto }}\n'
        '  OPTIONAL {{ ?person pwg:lastContactCalendar ?lcCalendar }}\n'
        '  OPTIONAL {{ ?person pwg:lastContactWhatsApp ?lcWhatsApp }}\n'
        '  OPTIONAL {{ ?person pwg:lastContactEmail ?lcEmail }}\n'
        '  OPTIONAL {{ ?person pwg:lastContactIMessage ?lcIMessage }}\n'
        '  OPTIONAL {{ ?person pwg:notes ?notes }}\n'
        '  OPTIONAL {{ ?person pwg:birthday ?bday }}\n'
        '  OPTIONAL {{ ?person pwg:privacyLevel ?priv }}\n'
        '}} LIMIT 5'.format(ns=PWG_NS, q=esc)
    )
    if not persons:
        return {"query": name, "found": False,
                "message": "No person found matching '{}'.".format(name)}

    results = []
    # F2 (Archie re-review): captured once so a MULTI-match on the operator's
    # own name can surface the deterministically-resolved current employer at
    # the envelope top level -- the brief LLM is handed the answer, not N
    # candidate orgs to guess between.
    operator_employer = None
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

        # OPERATOR OVERRIDE (Surface B fix). For a by-name lookup that
        # resolves to the operator's OWN node, the scalar
        # ``pwg:organization`` is an arbitrary/first-returned pick among
        # possibly-conflicting triples (a stale ex-employer, a namesake
        # real person wrongly in the name-space, an email-identity node).
        # Never trust it for the operator: resolve the CURRENT employer
        # deterministically from the reified, corroborated career facts
        # instead, so the daily brief cannot surface a stale or
        # namesake employer.
        if USER_URI and uri == USER_URI:
            # F2 (Archie re-review): unambiguously tag the operator's own row
            # so a multi-match on the operator's name is disambiguable and the
            # brief LLM never has to guess which candidate is "you".
            entry["is_operator"] = True
            emp = _current_employer_safe()
            operator_employer = emp
            if emp.get("found"):
                entry["organisation"] = emp["employer"]
                if emp.get("job_title"):
                    entry["title"] = emp["job_title"]
                entry["employer_confidence"] = emp["confidence"]
                if emp.get("conflict"):
                    entry["employer_conflict"] = emp.get(
                        "conflicting_employers", []
                    )
                # Surface honest corroboration status so the brief LLM
                # never presents a fragmented-graph guess as a confident
                # answer.
                if not emp.get("verified"):
                    entry["employer_unverified"] = True
                if emp.get("identity_fragmented"):
                    entry["employer_identity_fragmented"] = True
        elif person.get("mergedInto"):
            # F2: a node carrying pwg:mergedInto is a DEPRECATED fragment that
            # a confirmed identity-merge redirected to a canonical node (see
            # CM061 EMPLOYER_IDENTITY_MERGE_PLAN.md §4 / schema pwg:mergedInto).
            # Mark it so the brief LLM discounts a stale fragment's scalar org.
            entry["deprecated_fragment"] = True
            entry["merged_into"] = person["mergedInto"]

        # MAX across the four per-source last-contact predicates, capped
        # at today so a future-dated event never wins (see
        # _max_past_last_contact). Missing sources contribute nothing.
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

        # Facts -- fail-closed L3 filter (pwg_privacy, single helper).
        # Select each fact's own pwg:privacyLevel and inherit the owning
        # person's level (most-restrictive wins). An untagged fact on an
        # L2 person stays visible (People section is L2); an L3 fact, or
        # any fact whose owning person is L3, or a fact with no parseable
        # clearance on either axis, is dropped. ``?f`` (the fact URI) is
        # selected so the Memory-Hygiene overlay can be keyed per fact.
        facts = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?f ?text ?fpriv WHERE {{\n'
            '  ?f a pwg:PersonFact ; pwg:aboutPerson <{uri}> ; pwg:factText ?text .\n'
            '  OPTIONAL {{ ?f pwg:privacyLevel ?fpriv }}\n'
            '  FILTER NOT EXISTS {{ ?f pwg:validTo ?end }}\n'
            '}}'.format(ns=PWG_NS, uri=uri)
        )
        if facts:
            # Memory-Hygiene overlay (LEFT JOIN <urn:pwg:hygiene>): drop any
            # fact the pass retired (superseded/archived/deleted) BEFORE the
            # L3 filter, via the canonical ostler_hygiene reader. build_facts_
            # query() scores facts about EVERY person, not just the operator,
            # so a person page must honour the same verdicts the memory tab
            # does. Empty overlay (hygiene never run / Oxigraph down) => the
            # list is unchanged; the reader never raises.
            facts = _hygiene_drop_retired(facts)
            visible = pwg_privacy.filter_l3_facts(
                [{"text": f["text"], "privacy_level": f.get("fpriv")}
                 for f in facts],
                owner_level=person.get("priv"),
            )
            if visible:
                entry["facts"] = [f["text"] for f in visible]

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
        if operator_employer and operator_employer.get("found"):
            out["current_employer"] = operator_employer
        return out
    out = {"query": name, "found": True, "matches": results,
           "count": len(results)}
    # F2: when the operator's own name multi-matches, hand the brief LLM the
    # resolved current employer at the top level instead of N candidate orgs.
    if operator_employer and operator_employer.get("found"):
        out["current_employer"] = operator_employer
    return out


# Per-source last-contact predicates. The graph keeps one timestamp per
# channel; the API surfaces both the MAX (flat `last_contact`, which the
# iOS Codable already decodes) and the per-source breakdown (additive,
# only emitted when at least one source binds). Source labels are the
# British-English channel names the rest of the API uses.
_LAST_CONTACT_SOURCES = (
    ("lcCalendar", "calendar"),
    ("lcWhatsApp", "whatsapp"),
    ("lcEmail", "email"),
    ("lcIMessage", "imessage"),
)


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
            'SELECT ?org ?title ?rel ?howMet ?notes ?bday ?priv ?mergedInto\n'
            '       ?lcCalendar ?lcWhatsApp ?lcEmail ?lcIMessage WHERE {{\n'
            '  OPTIONAL {{ <{uri}> pwg:organization ?org }}\n'
            '  OPTIONAL {{ <{uri}> pwg:jobTitle ?title }}\n'
            '  OPTIONAL {{ <{uri}> pwg:relationship ?rel }}\n'
            '  OPTIONAL {{ <{uri}> pwg:howWeMet ?howMet }}\n'
            '  OPTIONAL {{ <{uri}> pwg:mergedInto ?mergedInto }}\n'
            '  OPTIONAL {{ <{uri}> pwg:lastContactCalendar ?lcCalendar }}\n'
            '  OPTIONAL {{ <{uri}> pwg:lastContactWhatsApp ?lcWhatsApp }}\n'
            '  OPTIONAL {{ <{uri}> pwg:lastContactEmail ?lcEmail }}\n'
            '  OPTIONAL {{ <{uri}> pwg:lastContactIMessage ?lcIMessage }}\n'
            '  OPTIONAL {{ <{uri}> pwg:notes ?notes }}\n'
            '  OPTIONAL {{ <{uri}> pwg:birthday ?bday }}\n'
            '  OPTIONAL {{ <{uri}> pwg:privacyLevel ?priv }}\n'
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

    # OPERATOR OVERRIDE (Surface B fix). Mirrors person_context: for the
    # operator's own node the arbitrary scalar org is untrustworthy, so
    # resolve the current employer from the corroborated career facts.
    if USER_URI and person_uri == USER_URI:
        # F2 (Archie re-review): tag the operator's own card (mirrors
        # person_context) so any consumer can disambiguate it.
        entry["is_operator"] = True
        emp = _current_employer_safe()
        if emp.get("found"):
            entry["organisation"] = emp["employer"]
            if emp.get("job_title"):
                entry["title"] = emp["job_title"]
                entry["role"] = emp["job_title"]
            entry["employer_confidence"] = emp["confidence"]
            entry["current_employer"] = emp
            if emp.get("conflict"):
                entry["employer_conflict"] = emp.get(
                    "conflicting_employers", []
                )
            # Honest corroboration status (mirrors person_context).
            if not emp.get("verified"):
                entry["employer_unverified"] = True
            if emp.get("identity_fragmented"):
                entry["employer_identity_fragmented"] = True
    elif row.get("mergedInto"):
        # F2: deprecated fragment redirected by a confirmed identity-merge.
        entry["deprecated_fragment"] = True
        entry["merged_into"] = row["mergedInto"]

    # Per-source last-contact + MAX, capped at today so a future-dated
    # event never wins the flat last_contact (see _max_past_last_contact).
    # The per-source breakdown still surfaces every channel's raw value so
    # the card can show an upcoming-meeting date under its own channel.
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

        # Facts -- fail-closed L3 filter via the shared pwg_privacy helper,
        # inheriting the owning person's privacyLevel (most-restrictive
        # wins). Mirrors person_context exactly, including the Memory-Hygiene
        # overlay drop that precedes the L3 filter. ``?f`` (the fact URI) is
        # selected so the overlay can be keyed per fact.
        facts = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?f ?text ?fpriv WHERE {{\n'
            '  ?f a pwg:PersonFact ; pwg:aboutPerson <{uri}> ; pwg:factText ?text .\n'
            '  OPTIONAL {{ ?f pwg:privacyLevel ?fpriv }}\n'
            '  FILTER NOT EXISTS {{ ?f pwg:validTo ?end }}\n'
            '}}'.format(ns=PWG_NS, uri=person_uri)
        )
        if facts:
            # Drop facts the hygiene pass retired before the L3 filter (same
            # verdicts the memory tab and person_context honour). Empty
            # overlay => unchanged; never raises.
            facts = _hygiene_drop_retired(facts)
            visible = pwg_privacy.filter_l3_facts(
                [{"text": f["text"], "privacy_level": f.get("fpriv")}
                 for f in facts],
                owner_level=row.get("priv"),
            )
            if visible:
                entry["facts"] = [f["text"] for f in visible]

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


# Channel-label vocabulary for the unified person timeline. Each entry maps a
# per-source last-contact predicate to the {type, channel} the event carries.
# The graph stores ONE most-recent date per channel (pwg:lastContact*), not a
# per-message series, so email / WhatsApp / iMessage surface as a single
# "last contact" marker event rather than a per-message stream. Meetings and
# conversations DO carry per-event nodes and so produce one event each.
_TIMELINE_LAST_CONTACT = (
    # (predicate-localname, event_type, channel)
    ("lastContactEmail", "email", "email"),
    ("lastContactWhatsApp", "conversation", "whatsapp"),
    ("lastContactIMessage", "conversation", "imessage"),
    # Calendar last-contact is omitted here: the meeting events below already
    # carry the dated calendar interactions one row each, so a synthetic
    # "last calendar contact" marker would just duplicate the newest meeting.
)


def _timeline_human_date(iso_date):
    """Human-readable label for a timeline event date.

    Accepts an ISO date / datetime string and returns e.g. "14 Feb 2026".
    Falls back to the raw string when it is not parseable so the client
    still shows something rather than an empty cell.
    """
    if not iso_date:
        return ""
    s = str(iso_date)[:10]
    try:
        dt = datetime.strptime(s, "%Y-%m-%d")
        return dt.strftime("%-d %b %Y")
    except ValueError:
        return str(iso_date)


def person_timeline(slug, limit=50, days=None):
    """Handle GET /api/v1/person/{slug}/timeline.

    A UNIFIED, cross-channel relationship timeline for one person: every
    captured interaction (meetings, conversations, and the per-channel
    last-contact markers the graph holds) merged into a single list sorted
    newest-first. This is the relationship-recall surface the iOS / Hub
    person card and the wiki person page read to answer "when did I last
    deal with this person, and through which channel?".

    Person resolution mirrors ``person_enrichment``: the path segment is a
    wiki slug (the stable identifier the People list, search, and wiki URLs
    share), resolved to a person URI by recomputing ``_wiki_slug`` over the
    graph's display names. The same ``_SLUG_PATTERN`` guard rejects
    path-traversal / injection seeds before any query runs.

    Sources actually queryable from the graph today:
      - meetings: ``pwg:Meeting`` nodes with ``pwg:meetingAttendee`` ->
        one dated event per meeting (summary + location).
      - conversations: CM048 writes ``<fact> urn:pwg:about <person> ;
        urn:pwg:fromConversation <conv>`` with an optional ``urn:pwg:date``
        on the conversation; we collapse to one dated event per distinct
        conversation and deep-link the wiki Conversations page.
      - email / WhatsApp / iMessage: the graph holds only a single
        most-recent ``pwg:lastContact*`` date per channel (not a per-message
        series), so each present channel contributes ONE "last contact"
        marker event. A true per-message email/call stream is a follow-up
        once those channels write per-event nodes.

    Per-source degradation: a failure in any one source sets ``degraded:
    true`` and adds a note to ``degraded_sources`` but never fails the
    request, so a person with meetings still gets their meetings when the
    conversation query is down. This mirrors how ``/meeting/upcoming``
    degrades around a People Graph failure.

    Returns (response_dict, status_code):
      - 400 if the slug is malformed.
      - 404 {found: False} for an unknown slug.
      - 503 {degraded: True} only when the load-bearing slug-resolution
        query itself fails (Oxigraph unreachable).
      - 200 {found: True, person, events, count} otherwise. ``events`` is
        an empty list for a known person with no captured interactions.
    """
    # Same slug guard as person_enrichment / api_people_forget.
    if not _SLUG_PATTERN.match(slug or ""):
        return {
            "found": False,
            "error": "Invalid slug. Expected lowercase ASCII letters, "
                     "digits, hyphens (max 80 chars).",
        }, 400

    # Resolve slug -> person URI by recomputing _wiki_slug(displayName).
    # This is the load-bearing query: if it fails we cannot identify the
    # person at all, so degrade the whole request (503) rather than return
    # a misleading empty timeline.
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

    person = {
        "name": pname,
        "slug": slug,
        "person_uri": person_uri,
        "wiki_url": f"{WIKI_BASE_URL}/People/{slug}/",
    }

    events = []
    degraded_sources = []

    # --- Meetings (one dated event per meeting) -------------------------
    try:
        meetings = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?summary ?date ?location WHERE {{\n'
            '  ?m a pwg:Meeting ; pwg:meetingAttendee <{uri}> ; '
            'pwg:meetingSummary ?summary .\n'
            '  OPTIONAL {{ ?m pwg:meetingDate ?date }}\n'
            '  OPTIONAL {{ ?m pwg:meetingLocation ?location }}\n'
            '}} ORDER BY DESC(?date)'.format(ns=PWG_NS, uri=person_uri)
        )
        for m in meetings:
            iso = (m.get("date") or "")[:10]
            if not iso:
                continue
            events.append({
                "type": "meeting",
                "channel": "calendar",
                "when_iso": iso,
                "when_human": _timeline_human_date(iso),
                "title": m.get("summary", "") or "Meeting",
                "summary": m.get("summary", ""),
                "location": m.get("location", ""),
            })
    except Exception as exc:
        degraded_sources.append(f"meetings: {exc}")

    # --- Conversations (one dated event per distinct conversation) ------
    # CM048 writes <fact> urn:pwg:about <person> ; urn:pwg:fromConversation
    # <conv>. The same person can have many facts from one conversation, so
    # we collapse to one event per conversation URI, keeping its date.
    try:
        conv_rows = _sparql_select(
            'SELECT DISTINCT ?conv ?date WHERE {{\n'
            '  ?fact <urn:pwg:about> <{uri}> ; '
            '<urn:pwg:fromConversation> ?conv .\n'
            '  OPTIONAL {{ ?conv <urn:pwg:date> ?date }}\n'
            '}}'.format(uri=person_uri)
        )
        seen_convs = set()
        for r in conv_rows:
            conv_uri = r.get("conv", "")
            if not conv_uri or conv_uri in seen_convs:
                continue
            seen_convs.add(conv_uri)
            iso = (r.get("date") or "")[:10]
            if not iso:
                continue
            prefix = "urn:pwg:conversation/"
            conv_id = (conv_uri[len(prefix):]
                       if conv_uri.startswith(prefix) else conv_uri)
            events.append({
                "type": "conversation",
                "channel": "conversation",
                "when_iso": iso,
                "when_human": _timeline_human_date(iso),
                "title": "Conversation",
                "summary": "",
                "conversation_id": conv_id,
                "wiki_url": (f"{WIKI_BASE_URL}/Conversations/{conv_id}/"
                             if conv_id else ""),
            })
    except Exception as exc:
        degraded_sources.append(f"conversations: {exc}")

    # --- Per-channel last-contact markers (email / WhatsApp / iMessage) -
    # The graph holds a single most-recent date per channel, so each present
    # channel contributes ONE marker event. Queried in one OPTIONAL SELECT.
    try:
        lc_rows = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?lcEmail ?lcWhatsApp ?lcIMessage WHERE {{\n'
            '  OPTIONAL {{ <{uri}> pwg:lastContactEmail ?lcEmail }}\n'
            '  OPTIONAL {{ <{uri}> pwg:lastContactWhatsApp ?lcWhatsApp }}\n'
            '  OPTIONAL {{ <{uri}> pwg:lastContactIMessage ?lcIMessage }}\n'
            '}} LIMIT 1'.format(ns=PWG_NS, uri=person_uri)
        )
        lc_row = lc_rows[0] if lc_rows else {}
        for localname, etype, channel in _TIMELINE_LAST_CONTACT:
            # Predicate localnames map to the SELECT vars lcEmail / lcWhatsApp
            # / lcIMessage. Build the var name the same way the SELECT does.
            var = "lc" + localname[len("lastContact"):]
            iso = (lc_row.get(var) or "")[:10]
            if not iso:
                continue
            events.append({
                "type": etype,
                "channel": channel,
                "when_iso": iso,
                "when_human": _timeline_human_date(iso),
                "title": f"Last {channel} contact",
                "summary": "",
                "marker": True,
            })
    except Exception as exc:
        degraded_sources.append(f"last_contact: {exc}")

    # Optional days window: keep only events on/after the cutoff. ISO date
    # strings sort and compare lexicographically, so a string compare is
    # correct here.
    if days:
        try:
            from datetime import timedelta, timezone
            cutoff = (datetime.now(timezone.utc)
                      - timedelta(days=max(1, int(days)))).strftime("%Y-%m-%d")
            events = [e for e in events if e["when_iso"] >= cutoff]
        except (ValueError, TypeError):
            pass

    # Newest first. Then cap at the limit (default 50).
    events.sort(key=lambda e: e.get("when_iso") or "", reverse=True)
    try:
        cap = max(1, int(limit))
    except (ValueError, TypeError):
        cap = 50
    events = events[:cap]

    out = {
        "slug": slug,
        "found": True,
        "person": person,
        "events": events,
        "count": len(events),
    }
    if degraded_sources:
        out["degraded"] = True
        out["degraded_sources"] = degraded_sources
    return out, 200
# ---------------------------------------------------------------------------
# Moat read endpoints (v1.0.1). Three read-only graph queries that give the
# daemon's recall tools (pwg_decisions / pwg_topics / pwg_commitments) a Hub
# surface to call. Each mirrors the person_enrichment / person_timeline
# conventions: _sparql_select helper, PWG_NS prefix, graceful empty/unknown,
# 503 {degraded: True} on Oxigraph failure, never a 5xx leak to the client.
#
# The writers for these node types live on unmerged branches (CM041
# feat/decision-nodes-v1.0.1, CM040 feat/conversation-topic-extraction,
# CM048 commitment enrichment), so the live graph may not yet hold any of
# these nodes. That is by design: each endpoint SPARQLs for the node TYPE
# and returns an empty list (200) when none are present. We do not import
# the writer modules; the contract is the graph predicate names only.
# ---------------------------------------------------------------------------

# Cap on rows any moat endpoint will return, regardless of a larger ?limit.
# Keeps a runaway query from returning the whole graph to the daemon.
_MOAT_MAX_LIMIT = 200
_MOAT_DEFAULT_LIMIT = 50


def _moat_limit(params):
    """Parse + clamp the shared ?limit param for the moat endpoints.

    Returns ``(limit, error_dict_or_None)``. A non-integer is a 400 (same
    contract as _safe_int elsewhere); a valid value is clamped to
    ``1 .. _MOAT_MAX_LIMIT`` so the caller never has to re-check bounds.
    """
    limit, err = _safe_int(params, "limit", _MOAT_DEFAULT_LIMIT)
    if err:
        return _MOAT_DEFAULT_LIMIT, err
    if limit < 1:
        limit = 1
    if limit > _MOAT_MAX_LIMIT:
        limit = _MOAT_MAX_LIMIT
    return limit, None


def decisions_list(about=None, query=None, limit=_MOAT_DEFAULT_LIMIT):
    """Handle GET /api/v1/decisions?about=<slug>&q=<text>&limit=N.

    Read-only listing of ``pwg:Decision`` nodes (the typed "what did we
    decide about X?" promotion written by CM041
    ``meeting_syncer/decision_extractor.py``). Node shape (NS
    ``https://pwg.dev/ontology#`` == PWG_NS):

      <pwg:decision_<id>> a pwg:Decision ;
          pwg:decisionSummary "..." ;
          pwg:decisionDate    "..."^^xsd:dateTime ;   # optional
          pwg:decisionStatus  "active" ;               # optional
          pwg:decisionSource  <meeting-uri> ;          # optional
          pwg:decisionAbout   <person-uri> ; ...       # 0..n

    Filters (both optional, AND-combined):
      - ``about``: a wiki slug; only decisions whose ``decisionAbout``
        resolves (via _wiki_slug on the linked person's displayName) to
        that slug. An unknown slug yields an empty list, not a 404 --
        these are discovery endpoints, not single-resource lookups.
      - ``query``: a case-insensitive substring of ``decisionSummary``.

    Newest first by ``decisionDate`` (ISO strings sort lexicographically;
    nodes without a date sort last). Returns
    ``({"decisions": [...], "count": N}, 200)`` or, on Oxigraph failure,
    ``({"decisions": [], "count": 0, "degraded": True, "reason": ...},
    503)`` -- mirroring the degraded contract used across the readers.

    Privacy: decisions are derived from meeting summaries already held in
    the graph; the extractor mints no L3-withheld content. There is no
    per-decision privacy predicate to gate on, so all stored decisions
    are surfaced (consistent with the meetings sub-query in
    person_enrichment).
    """
    # Resolve the optional about-slug to a person URI up front so we can
    # FILTER the main query on it. A slug that resolves to nobody short
    # circuits to an empty list (a valid, non-error "no decisions" answer).
    about_uri = None
    if about:
        if not _SLUG_PATTERN.match(about):
            return {
                "decisions": [],
                "count": 0,
                "error": "Invalid 'about' slug. Expected lowercase ASCII "
                         "letters, digits, hyphens (max 80 chars).",
            }, 400
        try:
            candidates = _sparql_select(
                'PREFIX pwg: <{ns}>\n'
                'SELECT ?person ?name WHERE {{\n'
                '  ?person a pwg:Person ; pwg:displayName ?name .\n'
                '}}'.format(ns=PWG_NS)
            )
        except Exception as exc:
            return {
                "decisions": [],
                "count": 0,
                "degraded": True,
                "reason": f"oxigraph_lookup_failed: {exc}",
            }, 503
        for cand in candidates:
            if _wiki_slug(cand.get("name", "")) == about:
                about_uri = cand["person"]
                break
        if about_uri is None:
            return {"decisions": [], "count": 0}, 200

    # One query for the decision attributes; decisionAbout is collected in
    # a second pass so a multi-attendee decision is not row-multiplied here.
    about_clause = (
        '  ?d pwg:decisionAbout <{uri}> .\n'.format(uri=about_uri)
        if about_uri else ''
    )
    try:
        rows = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'SELECT ?d ?summary ?date ?source ?status WHERE {{\n'
            '  ?d a pwg:Decision ; pwg:decisionSummary ?summary .\n'
            '{about_clause}'
            '  OPTIONAL {{ ?d pwg:decisionDate ?date }}\n'
            '  OPTIONAL {{ ?d pwg:decisionSource ?source }}\n'
            '  OPTIONAL {{ ?d pwg:decisionStatus ?status }}\n'
            '}}'.format(ns=PWG_NS, about_clause=about_clause)
        )
    except Exception as exc:
        return {
            "decisions": [],
            "count": 0,
            "degraded": True,
            "reason": f"oxigraph_query_failed: {exc}",
        }, 503

    # Optional summary substring filter (case-insensitive), applied in
    # Python so a malformed ?q can never reach the SPARQL grammar.
    q_lower = (query or "").strip().lower()

    decisions = []
    for r in rows:
        summary = r.get("summary", "")
        if q_lower and q_lower not in summary.lower():
            continue
        decision_uri = r.get("d")
        # Per-decision attendee list (0..n). A sub-query failure degrades
        # only the about list for this one decision, not the whole call.
        about_people = []
        try:
            arows = _sparql_select(
                'PREFIX pwg: <{ns}>\n'
                'SELECT ?name WHERE {{\n'
                '  <{uri}> pwg:decisionAbout ?p .\n'
                '  ?p pwg:displayName ?name .\n'
                '}}'.format(ns=PWG_NS, uri=decision_uri)
            )
            about_people = [a["name"] for a in arows if a.get("name")]
        except Exception:
            about_people = []
        decisions.append({
            "summary": summary,
            "date": (r.get("date") or "")[:10],
            "about": about_people,
            "source": r.get("source", ""),
            "status": r.get("status", ""),
        })

    # Newest first; undated decisions sort last (empty string < any date).
    decisions.sort(key=lambda d: d["date"], reverse=True)
    decisions = decisions[:limit]
    return {"decisions": decisions, "count": len(decisions)}, 200


def topics_list(query=None, limit=_MOAT_DEFAULT_LIMIT):
    """Handle GET /api/v1/topics?q=<text>&limit=N.

    Read-only listing of ``pwg:ConversationTopic`` nodes ranked by total
    mention weight. Node shape (CM040
    ``services/conversation_memory/storage.py``, NS PWG_NS):

      pwg:topic_<slug> a pwg:ConversationTopic ;
          pwg:topicSlug "<slug>" ; rdfs:label "<label>" .
      pwg:topiclink_<id> a pwg:TopicMention ;
          pwg:mentionsTopic pwg:topic_<slug> ;
          pwg:inConversation pwg:batch_<id> ;
          pwg:topicWeight "<n>"^^xsd:integer .

    Note CM040's topic local-names are hyphenated
    (``pwg:topic_apple-mail``) -- we never parse the IRI, we read the
    ``pwg:topicSlug`` literal, so the hyphen is irrelevant to this reader.

    ``query`` is an optional case-insensitive substring of the label or
    slug. Topics are ranked by summed ``topicWeight`` (then mention
    count), highest first. Returns
    ``({"topics": [{slug, label, weight, mentions}], "count": N}, 200)``
    or the 503 degraded shape on Oxigraph failure.
    """
    try:
        rows = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>\n'
            'SELECT ?topic ?slug ?label\n'
            '       (SUM(?w) AS ?weight) (COUNT(?m) AS ?mentions) WHERE {{\n'
            '  ?topic a pwg:ConversationTopic .\n'
            '  OPTIONAL {{ ?topic pwg:topicSlug ?slug }}\n'
            '  OPTIONAL {{ ?topic rdfs:label ?label }}\n'
            '  OPTIONAL {{\n'
            '    ?m a pwg:TopicMention ; pwg:mentionsTopic ?topic .\n'
            '    OPTIONAL {{ ?m pwg:topicWeight ?w }}\n'
            '  }}\n'
            '}} GROUP BY ?topic ?slug ?label'.format(ns=PWG_NS)
        )
    except Exception as exc:
        return {
            "topics": [],
            "count": 0,
            "degraded": True,
            "reason": f"oxigraph_query_failed: {exc}",
        }, 503

    q_lower = (query or "").strip().lower()
    topics = []
    for r in rows:
        slug = r.get("slug", "")
        label = r.get("label", "")
        if q_lower and q_lower not in label.lower() and q_lower not in slug.lower():
            continue
        topics.append({
            "slug": slug,
            "label": label,
            "weight": _as_int(r.get("weight")),
            "mentions": _as_int(r.get("mentions")),
        })

    topics.sort(key=lambda t: (t["weight"], t["mentions"]), reverse=True)
    topics = topics[:limit]
    return {"topics": topics, "count": len(topics)}, 200


def topic_mentions(slug, limit=_MOAT_DEFAULT_LIMIT):
    """Handle GET /api/v1/topics/<slug>/mentions.

    The conversations a single topic appears in, newest first. Resolves
    the topic by its ``pwg:topicSlug`` literal (not the IRI local-name,
    which CM040 hyphenates). Returns
    ``({"slug", "label", "mentions": [{conversation, weight, channel,
    sender, date}], "count": N}, 200)``. An unknown slug returns an empty
    mentions list (200), consistent with the discovery-endpoint posture.
    """
    if not _SLUG_PATTERN.match(slug or ""):
        return {
            "slug": slug,
            "mentions": [],
            "count": 0,
            "error": "Invalid slug. Expected lowercase ASCII letters, "
                     "digits, hyphens (max 80 chars).",
        }, 400

    try:
        rows = _sparql_select(
            'PREFIX pwg: <{ns}>\n'
            'PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>\n'
            'SELECT ?label ?conversation ?weight ?channel ?sender ?date WHERE {{\n'
            '  ?topic a pwg:ConversationTopic ; pwg:topicSlug "{slug}" .\n'
            '  OPTIONAL {{ ?topic rdfs:label ?label }}\n'
            '  OPTIONAL {{\n'
            '    ?m a pwg:TopicMention ; pwg:mentionsTopic ?topic ;\n'
            '       pwg:inConversation ?conversation .\n'
            '    OPTIONAL {{ ?m pwg:topicWeight ?weight }}\n'
            '    OPTIONAL {{ ?m pwg:viaChannel ?channel }}\n'
            '    OPTIONAL {{ ?m pwg:senderName ?sender }}\n'
            '    OPTIONAL {{ ?m pwg:validFrom ?date }}\n'
            '  }}\n'
            '}}'.format(ns=PWG_NS, slug=slug)
        )
    except Exception as exc:
        return {
            "slug": slug,
            "mentions": [],
            "count": 0,
            "degraded": True,
            "reason": f"oxigraph_query_failed: {exc}",
        }, 503

    label = ""
    mentions = []
    for r in rows:
        if r.get("label") and not label:
            label = r["label"]
        conv = r.get("conversation")
        if not conv:
            continue
        mentions.append({
            "conversation": conv,
            "weight": _as_int(r.get("weight")),
            "channel": r.get("channel", ""),
            "sender": r.get("sender", ""),
            "date": (r.get("date") or "")[:10],
        })

    mentions.sort(key=lambda m: m["date"], reverse=True)
    mentions = mentions[:limit]
    return {
        "slug": slug,
        "label": label,
        "mentions": mentions,
        "count": len(mentions),
    }, 200


def commitments_list(owner=None, due_before=None, status="open",
                     limit=_MOAT_DEFAULT_LIMIT):
    """Handle GET /api/v1/commitments?owner=<user|other>&due_before=<iso>&status=open&limit=N.

    Read-only listing of ``pwg:OutstandingTodo`` nodes -- the
    open-commitments wing CM048 writes (and ``meeting_syncer/brief.py``
    already reads for the pre-meeting brief). This reuses that query
    shape. Note the OutstandingTodo predicates live under the ``urn:pwg:``
    namespace (not PWG_NS, which the typed Person/Decision/Topic nodes
    use) -- ``<urn:pwg:OutstandingTodo>``, ``<urn:pwg:todoText>``,
    ``<urn:pwg:owner>``, ``<urn:pwg:deadline>``, ``<urn:pwg:status>``,
    matching brief._get_outstanding_todos.

    Filters (all optional, AND-combined):
      - ``status``: defaults to ``"open"`` so closed-out todos do not
        clutter the recall surface. Pass ``status=all`` (or empty) to
        drop the filter.
      - ``owner``: ``user`` (commitments the operator owes) or ``other``
        (owed to the operator). The brief writes ``pwg:owner`` as a
        token; we match it case-insensitively in Python so a writer-side
        vocabulary tweak does not silently drop rows.
      - ``due_before``: ISO date/datetime; only commitments with a
        ``deadline`` strictly before it (undated commitments are dropped
        when this filter is set, kept otherwise).

    Newest first by deadline then created-at. Returns
    ``({"commitments": [{action, owner, due, status, source}], "count":
    N}, 200)`` or the 503 degraded shape on Oxigraph failure.
    """
    status_norm = (status or "").strip().lower()
    status_filter = ''
    if status_norm and status_norm != "all":
        status_filter = '  FILTER (LCASE(STR(?status)) = "{}")\n'.format(
            status_norm.replace('"', '')
        )

    try:
        rows = _sparql_select(
            'SELECT ?todo ?action ?owner ?deadline ?status ?source ?createdAt WHERE {\n'
            '  ?todo a <urn:pwg:OutstandingTodo> ;\n'
            '        <urn:pwg:todoText> ?action ;\n'
            '        <urn:pwg:owner> ?owner ;\n'
            '        <urn:pwg:status> ?status .\n'
            '  OPTIONAL { ?todo <urn:pwg:deadline> ?deadline }\n'
            '  OPTIONAL { ?todo <urn:pwg:sourceConversationDate> ?source }\n'
            '  OPTIONAL { ?todo <urn:pwg:todoCreatedAt> ?createdAt }\n'
            + status_filter +
            '}'
        )
    except Exception as exc:
        return {
            "commitments": [],
            "count": 0,
            "degraded": True,
            "reason": f"oxigraph_query_failed: {exc}",
        }, 503

    owner_norm = (owner or "").strip().lower()
    due_norm = (due_before or "").strip()

    commitments = []
    for r in rows:
        if owner_norm and (r.get("owner", "") or "").strip().lower() != owner_norm:
            continue
        deadline = r.get("deadline", "")
        if due_norm:
            # Undated commitments cannot satisfy a "due before" window.
            if not deadline or deadline >= due_norm:
                continue
        commitments.append({
            "action": r.get("action", ""),
            "owner": r.get("owner", ""),
            "due": deadline,
            "status": r.get("status", ""),
            "source": r.get("source", ""),
            "_created": r.get("createdAt", ""),
        })

    # Newest first: by deadline, then created-at. Strip the private sort
    # key from the wire shape afterwards.
    commitments.sort(key=lambda c: (c["due"], c["_created"]), reverse=True)
    commitments = commitments[:limit]
    for c in commitments:
        c.pop("_created", None)
    return {"commitments": commitments, "count": len(commitments)}, 200


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


def _as_int(value):
    """Coerce a SPARQL aggregate binding (string, possibly typed) to an
    int, defaulting to 0. SUM/COUNT come back as plain decimal strings
    via _sparql_select; a missing or unparseable value is treated as 0
    so the ranking never raises."""
    if value in (None, ""):
        return 0
    try:
        return int(float(value))
    except (ValueError, TypeError):
        return 0


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


def people_list(sort=None, ceiling=10000):
    """List every person in the Qdrant `people` collection for the Hub.

    The Hub dashboard People page reads this; its header count is the length
    of `people`, so we return the FULL set (paginated scroll, not a top-N) and
    let the page count it. Same `contact_type == "person"` filter as
    people_search / people_stale, so the Hub count matches the wiki People
    count and the iOS People tab once #600 hydrate has populated Qdrant.

    Each row carries slug + wiki_url (same _wiki_slug derivation and
    WIKI_BASE_URL the sibling readers emit) so the Hub People tab can link the
    row through to the person's wiki page, and the slug resolves the
    GET /api/v1/people/{slug}/enrichment person-detail card.

    Counts + light rows only (id, name, slug, wiki_url, role, recency); no
    facts or notes cross this boundary. A missing `people` collection (fresh
    box, contacts not yet granted) is the empty-by-design path: return an empty
    list calmly, NOT an error, so all three surfaces show a calm empty-state.
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

    people = []
    for pt in points:
        p = pt.get("payload", {}) or {}
        name = p.get("display_name") or p.get("name") or ""
        if not name:
            continue
        # slug + wiki_url let the Hub People row click through to the
        # person's wiki page (and resolve the enrichment card). Same slug
        # derivation and WIKI_BASE_URL as people_search / people_recent.
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


def api_meeting_upcoming(within_minutes=120):
    """Return enriched pre-meeting briefs for events starting within
    ``within_minutes`` from now.

    This is the read side of the pre-meeting brief wiring: CM048
    extracts outstanding TODOs and writes them to Oxigraph; the
    CM041 ``meeting_syncer/brief.py`` generator gathers calendar +
    People Graph + TODO context into a structured brief payload;
    this endpoint exposes that payload to two consumers:

    1. The CM051 LaunchAgent cron sender, which polls every ~10 min
       and pushes a WhatsApp message ~15-20 min before each meeting.
    2. The CM031 iOS Companion ``MeetingBriefService``, which polls
       on a 5-minute cadence and surfaces a local notification +
       in-app brief view.

    Time-window semantics:
    - ``within_minutes`` is the LOOK-AHEAD window from now.
    - Events whose ``start_iso`` is in the past are filtered out
      (the brief is read once the meeting starts).
    - Default 120 minutes matches the iOS poll cadence (5-minute
      poll + 15-minute notify trigger + headroom).

    Read-only. Falls through to a degraded payload (``meetings: []``
    + ``degraded: true``) on People Graph failure rather than 5xx --
    the iOS notification surface treats a degraded response as
    "no upcoming meetings" and the cron sender skips delivery.
    """
    from datetime import datetime, timezone, timedelta

    # Re-import the brief module fresh per call so test patches on
    # brief.pre_meeting_brief / brief._sparql_query take effect
    # without a server restart. Cheap (module already in sys.modules
    # after first call).
    try:
        import sys as _sys
        from pathlib import Path as _P
        # The brief module lives next to this server file in the
        # repo: ../meeting_syncer/brief.py. Add the repo root once.
        _repo_root = _P(__file__).resolve().parent.parent
        if str(_repo_root) not in _sys.path:
            _sys.path.insert(0, str(_repo_root))
        from meeting_syncer import brief as _brief
    except Exception as exc:
        return {
            "meetings": [],
            "within_minutes": within_minutes,
            "degraded": True,
            "reason": f"brief module unavailable: {exc}",
        }

    # Look-ahead window. brief.pre_meeting_brief takes a `days`
    # parameter; convert minutes to days (ceil to ensure we don't
    # miss an event right at the boundary).
    days_lookahead = max(1, int((within_minutes + 1439) // 1440))

    try:
        all_briefs = _brief.pre_meeting_brief(days=days_lookahead)
    except Exception as exc:
        return {
            "meetings": [],
            "within_minutes": within_minutes,
            "degraded": True,
            "reason": str(exc)[:200],
        }

    # Filter to events starting within the window.
    now = datetime.now(timezone.utc)
    window_end = now + timedelta(minutes=within_minutes)

    def _parse_start(b):
        """Return a tz-aware UTC datetime, or None if unparseable."""
        raw = b.get("start_iso") or b.get("start") or ""
        if not raw:
            return None
        # iCal-style local time, e.g. "20260530T103000"
        if len(raw) == 15 and "T" in raw and raw.replace("T", "").isdigit():
            try:
                dt = datetime.strptime(raw, "%Y%m%dT%H%M%S")
                # Assume local-tz; convert to UTC. Without tz info
                # we can't be exact -- treat as UTC for filtering.
                return dt.replace(tzinfo=timezone.utc)
            except ValueError:
                return None
        # ISO-8601 with offset
        try:
            return datetime.fromisoformat(raw.replace("Z", "+00:00"))
        except (ValueError, AttributeError):
            return None

    upcoming = []
    for b in all_briefs:
        dt = _parse_start(b)
        if dt is None:
            # Unparseable start: include rather than silently drop
            # so the operator can see a malformed event. The cron
            # sender skips events without a parseable start.
            upcoming.append(b)
            continue
        if now <= dt <= window_end:
            upcoming.append(b)

    return {
        "meetings": upcoming,
        "within_minutes": within_minutes,
        "count": len(upcoming),
    }


def _timeline_from_graph(past_days=730, limit=200):
    """Historic timeline rows from the People Graph - one entry PER MEETING.

    The Timeline is mainly a HISTORIC view, so its primary source is the graph
    (pwg:Meeting nodes ingested from the user's calendar history at install),
    NOT the live calendar API - that only looks forward and is usually
    unconfigured on a fresh customer box. One row per meeting (collapsing
    attendees with GROUP_CONCAT) - the old per-person path emitted the same
    meeting once per attendee, which was the #663 double-entry bug.

    Returns ``(rows, error)`` - newest first. ``error`` is a string when the
    graph query failed (so the caller can surface a degraded marker), else None.
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
    # historic view rather than a 7-day-forward calendar peek.
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


# ── Health x life-context convergence (#680) ─────────────────────────
# Apple Health daily summaries (from the CM031 companion) land in the
# graph as one HealthObservation per day, keyed by date so they JOIN the
# context already keyed by date (pwg:Meeting.meetingDate etc). Design
# contract: help, not score – store raw aggregates only, never derived
# "scores", rings, or goals. Health is L3 (private) by default.

_HEALTH_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

# Map the iOS HealthFields payload keys -> (graph predicate, kind).
# kind: "int" | "float" -> typed numeric literal; "str" -> escaped string.
_HEALTH_FIELDS = (
    ("steps",              "steps",            "int"),
    ("distance_metres",    "distanceMetres",   "float"),
    ("active_energy_kcal", "activeEnergyKcal", "float"),
    ("resting_heart_rate", "restingHeartRate", "float"),
    ("sleep_hours",        "sleepHours",       "float"),
    ("workout_minutes",    "workoutMinutes",   "float"),
    ("workout_types",      "workoutTypes",     "str"),
)


def _sparql_str_literal(value):
    """Escape a Python str as a quoted SPARQL string literal."""
    s = str(value)
    s = (s.replace("\\", "\\\\")
          .replace('"', '\\"')
          .replace("\n", "\\n")
          .replace("\r", "\\r")
          .replace("\t", "\\t"))
    return '"{}"'.format(s)


def _write_health_observation(fields):
    """Write one day's Apple Health summary into the graph (idempotent).

    `fields` is the iOS HealthFields payload (snake_case keys). Keyed by
    date so a re-POST of the same day overwrites it cleanly (HealthKit
    revises late-arriving samples, e.g. sleep). Returns True on write,
    False if there is no usable date. Raises on a graph failure so the
    caller can record it as degraded.
    """
    date = str(fields.get("date") or "").strip()[:10]
    if not _HEALTH_DATE_RE.match(date):
        return False

    subject = "{ns}health_obs_{date}".format(ns=PWG_NS, date=date)
    triples = [
        "<{s}> a pwg:HealthObservation .".format(s=subject),
        '<{s}> pwg:observationDate "{d}" .'.format(s=subject, d=date),
    ]
    for src_key, predicate, kind in _HEALTH_FIELDS:
        value = fields.get(src_key)
        if value is None:
            continue
        if kind == "int":
            try:
                lit = str(int(value))
            except (TypeError, ValueError):
                continue
        elif kind == "float":
            try:
                lit = repr(float(value))
            except (TypeError, ValueError):
                continue
        else:  # str
            text = str(value).strip()
            if not text:
                continue
            lit = _sparql_str_literal(text)
        triples.append(
            "<{s}> pwg:{p} {v} .".format(s=subject, p=predicate, v=lit)
        )

    level = str(fields.get("privacy_level") or "L3").strip() or "L3"
    triples.append('<{s}> pwg:privacyLevel {v} .'.format(
        s=subject, v=_sparql_str_literal(level)))
    triples.append('<{s}> pwg:source "ios" .'.format(s=subject))

    sparql = (
        "PREFIX pwg: <{ns}>\n"
        "DELETE {{ <{s}> ?p ?o }} WHERE {{ <{s}> ?p ?o }};\n"
        "INSERT DATA {{\n{body}\n}}"
    ).format(ns=PWG_NS, s=subject, body="\n".join(triples))
    _sparql_update(sparql)
    return True


# Read keys -> the JSON shape the iOS app / assistant consume. Graph
# predicates are camelCase; the API surface is snake_case (matches the
# rest of the iOS-facing surface).
_HEALTH_READ_FIELDS = (
    ("steps",            "steps",            int),
    ("distanceMetres",   "distance_metres",  float),
    ("activeEnergyKcal", "active_energy_kcal", float),
    ("restingHeartRate", "resting_heart_rate", float),
    ("sleepHours",       "sleep_hours",      float),
    ("workoutMinutes",   "workout_minutes",  float),
    ("workoutTypes",     "workout_types",    str),
)


def api_health_day(date):
    """Join a day's physiology with that day's life-context (#680).

    Returns the HealthObservation for `date` (physiology) alongside the
    meetings already in the graph for that date (context), so the
    assistant can explain the *why* behind the numbers – never a score.
    """
    date = str(date or "").strip()[:10]
    if not _HEALTH_DATE_RE.match(date):
        return {"error": "date must be YYYY-MM-DD"}, 400

    subject = "{ns}health_obs_{date}".format(ns=PWG_NS, date=date)
    physiology = {}
    try:
        rows = _sparql_select(
            "PREFIX pwg: <{ns}>\n"
            "SELECT ?p ?o WHERE {{ <{s}> ?p ?o }}".format(ns=PWG_NS, s=subject)
        )
    except Exception as exc:
        return {"date": date, "physiology": {}, "context": {"meetings": []},
                "has_data": False, "degraded": True, "reason": str(exc),
                "error": str(exc)}, 200

    by_pred = {r["p"].rsplit("#", 1)[-1]: r["o"] for r in rows if r.get("p")}
    for graph_key, api_key, caster in _HEALTH_READ_FIELDS:
        if graph_key in by_pred:
            try:
                physiology[api_key] = caster(by_pred[graph_key])
            except (TypeError, ValueError):
                physiology[api_key] = by_pred[graph_key]

    meetings = []
    try:
        mrows = _sparql_select(
            "PREFIX pwg: <{ns}>\n"
            "SELECT ?summary ?date ?location WHERE {{\n"
            "  ?m a pwg:Meeting ; pwg:meetingDate ?date .\n"
            "  OPTIONAL {{ ?m pwg:meetingSummary ?summary }}\n"
            "  OPTIONAL {{ ?m pwg:meetingLocation ?location }}\n"
            '  FILTER(STRSTARTS(STR(?date), "{date}"))\n'
            "}} ORDER BY ?date".format(ns=PWG_NS, date=date)
        )
        for r in mrows:
            meetings.append({
                "summary": r.get("summary", ""),
                "date": (r.get("date") or "")[:10],
                "location": r.get("location", ""),
            })
    except Exception:
        # Context is best-effort; physiology alone is still useful.
        pass

    return {
        "date": date,
        "physiology": physiology,
        "context": {"meetings": meetings},
        "has_data": bool(physiology),
    }, 200


def api_contacts_diff():
    """Tidy Contacts report: the contact-hygiene findings a Doctor UI renders.

    READ-ONLY. Wraps ``identity_resolver.tidy.TidyEngine.build_report()``, which
    reuses the existing identity resolver for duplicate detection and layers the
    low-quality (bare-handle) and incomplete (recoverable-field) passes on top.
    It writes NOTHING to the graph - every proposed merge / enrich is surfaced
    for an explicit, per-item user action via the separate apply path. This
    endpoint is the "diff" the user reviews before accepting anything.

    Returns ``TidyReport.to_dict()``:
        {schema_version, total_persons, counts, items: [TidyItem, ...]}
    On any failure (engine unavailable, Oxigraph down) it returns the degraded
    contract used across this server rather than raising, so the Doctor tab can
    render an honest "couldn't build the report" state instead of a 500.
    """
    try:
        # identity_resolver ships alongside contact_syncer under the import
        # pipeline, so it needs the SAME dual-layout resolution: dev repo root
        # (sibling of assistant_api/) OR the shipping ${OSTLER_DIR}/import-
        # pipeline/ (install.sh: `cp -R identity_resolver "$PIPELINE_DIR/"`).
        # Without the shipping root this import raises ModuleNotFoundError on a
        # real Hub and the Doctor tidy report silently degrades. See
        # _pipeline_import_roots().
        _ensure_pipeline_on_path()
        from identity_resolver.tidy import TidyEngine
    except Exception as exc:
        return {
            "schema_version": 1,
            "total_persons": 0,
            "counts": {},
            "items": [],
            "degraded": True,
            "reason": f"tidy engine unavailable: {exc}",
        }

    engine = None
    try:
        engine = TidyEngine(oxigraph_url=OXIGRAPH_URL, qdrant_url=QDRANT_URL)
        return engine.build_report().to_dict()
    except Exception as exc:
        return {
            "schema_version": 1,
            "total_persons": 0,
            "counts": {},
            "items": [],
            "degraded": True,
            "reason": str(exc)[:200],
            "error": str(exc),
        }
    finally:
        if engine is not None:
            try:
                engine.close()
            except Exception:
                pass


def api_ingest_ios(payload):
    """Accept a batch from the CM031 iOS companion app.

    Two envelope shapes are accepted, normalised to one list:
      - {"points": [{"id", "payload": {"type", ...}}, ...]}  (the shape
        PWGUploadService actually sends: Qdrant-style points)
      - {"items":  [{"kind", "text", ...}, ...]}             (legacy)

    Every entry is spooled as a JSON line to INGEST_DIR for downstream
    enrichment – the API stays dumb. The ONE exception is health: a
    point whose payload.type == "health_daily_summary" is ALSO written
    straight into the graph as a per-day HealthObservation (#680), so
    the day's physiology becomes joinable with the day's life-context
    (meetings, calendar) already keyed by date. The graph write is
    best-effort: a graph failure never fails the ingest (the JSONL spool
    is the durable record).
    """
    import time
    import uuid

    if not isinstance(payload, dict):
        return {"error": "body must be a JSON object"}, 400

    # Accept the real iOS envelope ("points") or the legacy one ("items").
    batch = payload.get("points")
    if batch is None:
        batch = payload.get("items")
    if not isinstance(batch, list):
        return {"error": "body must contain a 'points' (or 'items') array"}, 400

    if len(batch) > 1000:
        return {"error": "too many items in one batch (max 1000)"}, 400

    # Route health points into the graph (idempotent per day). Best-effort:
    # collect failures but never abort the spool.
    health_written = 0
    health_errors = []
    for entry in batch:
        if not isinstance(entry, dict):
            continue
        fields = entry.get("payload")
        if not isinstance(fields, dict):
            continue
        if fields.get("type") != "health_daily_summary":
            continue
        try:
            if _write_health_observation(fields):
                health_written += 1
        except Exception as exc:  # noqa: BLE001 - never fail ingest on graph error
            health_errors.append(str(exc)[:120])

    try:
        os.makedirs(INGEST_DIR, exist_ok=True)
        batch_id = str(uuid.uuid4())
        ts = int(time.time())
        path = os.path.join(INGEST_DIR, f"ios-{ts}-{batch_id[:8]}.jsonl")
        record = {
            "batch_id": batch_id,
            "received_at": ts,
            "source": "ios",
            "items": batch,
        }
        with open(path, "w", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")
        result = {
            "ok": True,
            "batch_id": batch_id,
            "item_count": len(batch),
            # `accepted` mirrors `item_count` for the iOS UploadResult decoder
            # (F-10, 2026-05-27). Keep both keys for downstream compatibility.
            "accepted": len(batch),
            "path": path,
        }
        if health_written:
            result["health_observations"] = health_written
        if health_errors:
            # Surface degraded graph writes without failing the request –
            # the spool succeeded, so the data is not lost.
            result["health_degraded"] = health_errors
        return result, 200
    except Exception as exc:
        return {"error": str(exc)}, 500


# ── Hub health helpers ───────────────────────────────────────────────
# Each helper returns a (key, result_dict) tuple so the parallel runner
# can fan out work and collect named results. Every helper is wrapped in
# a blanket try/except – a misbehaving dependency must NEVER propagate
# up to the endpoint handler.


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

    # Privacy coverage (reader-side observability). Untagged fact/signal
    # nodes are hidden by the fail-closed L3 reader as unknown-privacy. A
    # non-zero count is exactly the number of facts being silently withheld
    # -- surface it so a mass-hide is diagnosable rather than invisible. The
    # startup backfill should drive this to 0; a persistent non-zero count
    # means a producer is emitting untagged facts (see the CM048
    # RelationshipSignal residual).
    try:
        # Same dual-layout resolution as the startup backfill so this
        # reader-side coverage counter is not silently absent on a real Hub.
        _ensure_pipeline_on_path()
        from contact_syncer import backfill_privacy as _bf
        _untagged = _bf.count_untagged(OXIGRAPH_URL)
        _n = _untagged.get("total", 0)
        out["checks"]["privacy_coverage"] = {
            "ok": True,  # informational: does not degrade overall health
            "untagged_fact_nodes": _n,
            "by_type": {t: _untagged.get(t, 0) for t in ("PersonFact",
                                                         "RelationshipSignal")},
            "note": (
                f"{_n} fact/signal node(s) carry no privacyLevel and are "
                "hidden by the fail-closed reader; run the privacy backfill"
                if _n else "all fact/signal nodes carry a privacyLevel"
            ),
        }
    except Exception as exc:
        out["checks"]["privacy_coverage"] = {"ok": True, "error": str(exc)[:80]}

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


def api_preferences(domain=None, min_confidence=0.0, limit=0, polarity=None):
    """Read the CM059 interest-profile artefact and return a flat, filtered,
    score-sorted list of interest records for the daemon's pwg_preferences
    tool.

    Read-only and degrades calm:
      * artefact absent  -> {"interests": [], "count": 0} with 200, never 5xx,
        so the daemon's tool returns "I don't have a preference profile yet"
        rather than erroring;
      * unreadable/corrupt artefact -> the same empty shape + a "degraded"
        flag and reason.

    Provenance is preserved verbatim: every record keeps its `sources`
    (platform provenance), `confidence`, `polarity` and `evidence` untouched.

    Filters (all optional, applied before the limit):
      * domain          - exact match on the record's `domain`
      * min_confidence  - keep records with confidence >= threshold
      * polarity        - "like" | "dislike"
    Sorted by `score` descending; `limit` (>0) truncates after sorting.
    """
    try:
        with open(INTEREST_PROFILE_PATH, encoding="utf-8") as fh:
            artefact = json.load(fh)
    except FileNotFoundError:
        return {"interests": [], "count": 0, "source_path": INTEREST_PROFILE_PATH}
    except Exception as exc:
        return {
            "interests": [],
            "count": 0,
            "degraded": True,
            "reason": str(exc)[:200],
            "source_path": INTEREST_PROFILE_PATH,
        }

    interests = artefact.get("interests", [])
    if not isinstance(interests, list):
        interests = []

    if domain:
        interests = [it for it in interests if it.get("domain") == domain]
    if polarity:
        interests = [it for it in interests if it.get("polarity") == polarity]
    if min_confidence > 0.0:
        interests = [
            it for it in interests
            if float(it.get("confidence") or 0.0) >= min_confidence
        ]

    interests.sort(key=lambda it: float(it.get("score") or 0.0), reverse=True)
    if limit and limit > 0:
        interests = interests[:limit]

    return {
        "interests": interests,
        "count": len(interests),
        "generated_at": artefact.get("generated_at"),
        "schema_version": artefact.get("schema_version"),
    }


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

        # Pre-meeting brief endpoint. Read-only; degrades to
        # meetings=[] on People Graph failure rather than 5xx so the
        # iOS notification surface and the cron sender can keep
        # polling without raising the operator-visible Hub-offline
        # pill on a transient Oxigraph blip.
        if parsed.path == "/api/v1/meeting/upcoming":
            params = parse_qs(parsed.query)
            within_minutes, err = _safe_int(params, "within_minutes", 120)
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            try:
                result = api_meeting_upcoming(within_minutes=within_minutes)
            except Exception as exc:
                result = {
                    "meetings": [],
                    "within_minutes": within_minutes,
                    "degraded": True,
                    "reason": str(exc)[:200],
                }
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

        # Health x life-context join (#680): a day's physiology + that
        # day's context. Default date = today (UTC). Help, not score.
        if parsed.path == "/api/v1/health/day":
            params = parse_qs(parsed.query)
            date = params.get("date", [datetime.utcnow().strftime("%Y-%m-%d")])[0]
            try:
                result, status = api_health_day(date)
            except Exception as exc:
                result, status = {"date": date, "physiology": {},
                                  "context": {"meetings": []}, "has_data": False,
                                  "degraded": True, "reason": str(exc),
                                  "error": str(exc)}, 200
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        # Tidy Contacts report (#588): read-only contact-hygiene findings.
        if parsed.path == "/api/v1/contacts/diff":
            try:
                result = api_contacts_diff()
            except Exception as exc:
                result = {"schema_version": 1, "total_persons": 0,
                          "counts": {}, "items": [],
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

        # Memory tab: list facts about the user (CM031 iOS Companion
        # v1.0 LB). Never 5xx -- api_memory_list returns the degraded
        # shape on any upstream failure so the iOS Memory tab can pick
        # between empty-state and degraded-banner UX.
        if parsed.path == "/api/v1/memory":
            try:
                result = api_memory_list()
            except Exception as exc:
                result = {
                    "facts": [],
                    "count": 0,
                    "degraded": True,
                    "reason": f"unexpected_error: {exc}",
                }
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        # Deterministic current-employer resolution for the operator.
        # The daily-brief agent calls this instead of guessing an
        # employer from the flat fact list. Never 5xx: returns
        # {"found": false} when there is no evidence.
        if parsed.path == "/api/v1/employer":
            result = _current_employer_safe()
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
        # the Doctor auth proxy at /api/v1/* (add to DOCTOR_PROXY_PATHS).
        # CORS is emitted on this route only, allowlisted to the wiki and
        # Tauri Hub origins. Degrades calm: any failure returns a pending
        # payload with 200 so the panel never breaks the homepage.
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

        # Unified cross-channel relationship timeline for one person.
        # GET /api/v1/person/{slug}/timeline?limit=N&days=N
        if (parsed.path.startswith("/api/v1/person/")
                and parsed.path.endswith("/timeline")):
            slug = parsed.path[len("/api/v1/person/"):-len("/timeline")]
            params = parse_qs(parsed.query)
            try:
                limit = int(params.get("limit", ["50"])[0])
            except (ValueError, TypeError):
                limit = 50
            days_raw = params.get("days", [None])[0]
            days = None
            if days_raw is not None:
                try:
                    days = int(days_raw)
                except (ValueError, TypeError):
                    days = None
            try:
                result, status = person_timeline(slug, limit=limit, days=days)
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
        # ── Moat read endpoints (v1.0.1) ────────────────────────────────
        # Read-only graph queries backing the daemon recall tools. Each
        # wraps its handler in a try/except so a handler bug degrades to a
        # 503 JSON body rather than leaking a 500/stack to the client.
        # NOTE: these /api/v1/* paths need DOCTOR_PROXY_PATHS entries so the
        # daemon can reach them through the Doctor auth proxy.
        # GET /api/v1/decisions?about=<slug>&q=<text>&limit=N
        if parsed.path == "/api/v1/decisions":
            params = parse_qs(parsed.query)
            limit, err = _moat_limit(params)
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            about = params.get("about", [None])[0]
            query = params.get("q", [None])[0]
            try:
                result, status = decisions_list(
                    about=about, query=query, limit=limit
                )
            except Exception as exc:
                result, status = {
                    "decisions": [], "count": 0, "degraded": True,
                    "reason": str(exc)[:200],
                }, 503
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        # GET /api/v1/topics/<slug>/mentions  (checked before the bare
        # /api/v1/topics list so the longer path wins).
        if (parsed.path.startswith("/api/v1/topics/")
                and parsed.path.endswith("/mentions")):
            slug = parsed.path[len("/api/v1/topics/"):-len("/mentions")]
            params = parse_qs(parsed.query)
            limit, err = _moat_limit(params)
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            try:
                result, status = topic_mentions(slug, limit=limit)
            except Exception as exc:
                result, status = {
                    "slug": slug, "mentions": [], "count": 0,
                    "degraded": True, "reason": str(exc)[:200],
                }, 503
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        # GET /api/v1/topics?q=<text>&limit=N
        if parsed.path == "/api/v1/topics":
            params = parse_qs(parsed.query)
            limit, err = _moat_limit(params)
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            query = params.get("q", [None])[0]
            try:
                result, status = topics_list(query=query, limit=limit)
            except Exception as exc:
                result, status = {
                    "topics": [], "count": 0, "degraded": True,
                    "reason": str(exc)[:200],
                }, 503
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        # GET /api/v1/commitments?owner=<user|other>&due_before=<iso>&status=open&limit=N
        if parsed.path == "/api/v1/commitments":
            params = parse_qs(parsed.query)
            limit, err = _moat_limit(params)
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            owner = params.get("owner", [None])[0]
            due_before = params.get("due_before", [None])[0]
            status_param = params.get("status", ["open"])[0]
            try:
                result, status = commitments_list(
                    owner=owner, due_before=due_before,
                    status=status_param, limit=limit,
                )
            except Exception as exc:
                result, status = {
                    "commitments": [], "count": 0, "degraded": True,
                    "reason": str(exc)[:200],
                }, 503
            self.send_response(status)
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

        # Preferences read-path (CM059 producer -> daemon pwg_preferences
        # tool). Serves the stable interest-profile artefact, filtered and
        # sorted. Absent artefact -> empty list + 200 so the daemon degrades
        # gracefully; provenance (sources/confidence/polarity) is preserved.
        # Sits behind the Doctor auth proxy at /api/v1/* like the rest.
        if parsed.path == "/api/v1/preferences":
            params = parse_qs(parsed.query)
            limit, err = _safe_int(params, "limit", 0)
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            min_conf, err = _safe_float(params, "min_confidence", 0.0)
            if err:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(err).encode())
                return
            domain_vals = params.get("domain") or []
            domain = domain_vals[0].strip() if domain_vals else None
            polarity_vals = params.get("polarity") or []
            polarity = polarity_vals[0].strip() if polarity_vals else None
            try:
                result = api_preferences(
                    domain=domain or None,
                    min_confidence=min_conf,
                    limit=limit,
                    polarity=polarity or None,
                )
            except Exception as exc:
                result = {
                    "interests": [],
                    "count": 0,
                    "degraded": True,
                    "reason": str(exc)[:200],
                }
            self.send_response(200)
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
            "/api/v1/people?sort=recency": "Full people list for the Hub People tab (id, name, slug, wiki_url, role, recency)",
            "/people/search?q=fintech": "Semantic people search",
            "/people/context?name=Jane": "Everything known about a person (+ relationship signals)",
            "/api/v1/people/{slug}/enrichment": "Per-slug person card payload (org, role, identifiers, meetings, per-source last-contact)",
            "/api/v1/person/{slug}/timeline?limit=50&days=N": "Unified cross-channel relationship timeline for one person (meetings + conversations + last-contact markers, newest-first)",
            "/api/v1/decisions?about=<slug>&q=<text>&limit=N": "Typed pwg:Decision nodes (what was decided), newest first",
            "/api/v1/topics?q=<text>&limit=N": "Conversation topics ranked by mention weight",
            "/api/v1/topics/{slug}/mentions": "Conversations a topic appears in, newest first",
            "/api/v1/commitments?owner=<user|other>&due_before=<iso>&status=open&limit=N": "Open commitments (pwg:OutstandingTodo), newest first",
            "/people/stale?months=3&limit=5": "Contacts not spoken to in N months",
            "/people/recent?days=7&limit=5": "Recently met people (from meetings)",
            "/people/birthdays?days=7": "Upcoming birthdays",
            "/email?q=is:unread": "Gmail query (default: unread)",
            "/api/v1/email/recent?hours=24&limit=20": "Recent emails (subject + snippet only)",
            "/api/v1/suggestions": "Composite: birthdays + stale contacts + recent meetings",
            "/api/v1/timeline?days=7": "Merged calendar + meetings timeline",
            "/api/v1/contacts/diff": "Tidy Contacts report (read-only hygiene findings)",
            "/api/v1/meeting/upcoming?within_minutes=120": "Enriched pre-meeting briefs for events starting within the window",
            "/api/v1/coach/recent?hours=168&limit=10": "Recent coaching observations (CM048)",
            "/api/v1/conversation/status/{id}": "Conversation processing status (CM048)",
            "/api/v1/conversation/{id}/speakers": "Hub-inferred speaker-identity suggestions for the device to confirm (CM048, text-only, opaque voice_fingerprint_ref)",
            "/api/v1/hub/health": "Hub status for iOS Companion pill (online / catching_up / offline_local)",
            "/api/v1/memory": "Facts Ostler has learnt about the user (CM031 Memory tab)",
            "/api/v1/preferences?domain=Music&min_confidence=0.3&limit=20": "Compiled interest profile from the CM059 artefact (score-sorted; preserves sources/confidence/polarity provenance)",
            "POST /api/v1/conversation/process": "Submit conversation for processing (CM048)",
            "POST /api/v1/ingest/ios": "Batch upload from the iOS companion (application/json)",
            "/api/v1/health/day?date=YYYY-MM-DD": "A day's Apple Health physiology joined to that day's life-context (defaults to today)",
            "POST /api/v1/memory/correct/{id}": "Correct or forget a memory fact (body: {\"newValue\":...} or {\"forget\":true})",
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

        # User-asserted fact: POST /api/v1/memory/assert. Banks a fact the
        # user stated in chat ("Jane is my wife") as an authoritative,
        # user_asserted PersonFact in Oxigraph. Body shape:
        #   {"subject": ..., "fact_text": ..., "relationship"?: ...,
        #    "asserted_via"?: ...}
        # Registered before the prefix-matched /memory/correct/ route below
        # so the exact path wins.
        if parsed.path == "/api/v1/memory/assert":
            # Router-level breadcrumb: record that the route was reached and
            # the raw top-level body shape BEFORE handing to the handler, so
            # even a handler exception leaves a trace in the log. L1-safe:
            # keys/shape only, never PII values.
            try:
                if isinstance(payload, dict):
                    _shape = f"keys={sorted(payload.keys())}"
                elif isinstance(payload, list):
                    _shape = f"list[{len(payload)}]"
                else:
                    _shape = f"<{type(payload).__name__}>"
                print(
                    f"[memory/assert] POST received: {_shape}",
                    file=sys.stderr, flush=True,
                )
            except Exception:
                pass
            try:
                result, status = api_memory_assert(payload)
            except Exception as exc:
                result, status = {"error": str(exc)}, 500
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result, indent=2).encode())
            return

        # Memory tab correction: POST /api/v1/memory/correct/{fact_id}.
        # Body is {"newValue": "..."} or {"forget": true}. The fact_id
        # is the URI suffix (or the full URI) returned by
        # GET /api/v1/memory. Append-only: every call is a new row in
        # memory_corrections, with the latest row per fact_id winning
        # on the next GET.
        if parsed.path.startswith("/api/v1/memory/correct/"):
            fact_id = parsed.path[len("/api/v1/memory/correct/"):]
            fact_id = fact_id.strip("/")
            try:
                result, status = api_memory_correct(fact_id, payload)
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


def _run_privacy_backfill_on_startup():
    """Tag any untagged PersonFact/RelationshipSignal nodes BEFORE serving.

    The person-fact readers fail closed on unknown privacy: an untagged
    fact is treated as L3 and hidden. On any hydrated graph ~85% of
    historical fact/signal nodes carry no pwg:privacyLevel, so serving
    /people/* before they are tagged would silently hide most facts.

    Running the idempotent backfill here -- in the reader's own process,
    before serve_forever() -- is the tightest possible ordering guarantee:
    the graph is fully tagged before the first /people/* request is
    answered. Idempotent (only untagged nodes match, so a re-run on the
    next boot is a no-op) and fail-safe (any error is logged and the
    server still starts; the reader stays fail-closed so a failed backfill
    hides facts, it never leaks them). Opt out with
    OSTLER_PRIVACY_BACKFILL=0.
    """
    flag = os.environ.get("OSTLER_PRIVACY_BACKFILL", "1").strip().lower()
    if flag in ("0", "false", "no", "off"):
        print("privacy backfill: disabled via OSTLER_PRIVACY_BACKFILL",
              flush=True)
        return
    try:
        # Resolve contact_syncer on BOTH the dev repo layout and the CM051
        # shipping layout (services/ical-server/ vs import-pipeline/) -- see
        # _pipeline_import_roots(). Without the shipping root this import raises
        # ModuleNotFoundError on a real Hub and the every-boot sweep is inert.
        _ensure_pipeline_on_path()
        from contact_syncer import backfill_privacy as _bf
        result = _bf.run_startup_backfill(OXIGRAPH_URL, apply=True)
        print(
            "privacy backfill: {status} (untagged={total}, "
            "applied={applied}, levels={by_level})".format(
                status=result.get("status"),
                total=result.get("total", 0),
                applied=result.get("applied", 0),
                by_level=result.get("by_level", {}),
            ),
            flush=True,
        )
    except Exception as exc:  # never block startup on the backfill.
        print(
            f"WARNING: privacy backfill skipped ({exc}); readers remain "
            "fail-closed, so untagged facts stay hidden (not leaked).",
            file=sys.stderr,
            flush=True,
        )


if __name__ == "__main__":
    # Bind to loopback by default (audit finding §5.1: loopback-only is
    # safer for the productised single-Mac topology). The iOS Companion
    # reaches the Hub over Tailscale, which gives the Mac a stable
    # 100.x private IP; setting OSTLER_API_BIND="0.0.0.0" enables direct
    # LAN exposure for dev or for users who don't want Tailscale.
    BIND_HOST = os.environ.get("OSTLER_API_BIND", "127.0.0.1")
    # Tag the historical privacy coverage gap before answering /people/*.
    _run_privacy_backfill_on_startup()
    print(f"Assistant API running on http://{BIND_HOST}:{PORT}")
    print("Endpoints: /calendar, /people/{search,context,stale,recent,birthdays}, /email, /api/v1/email/recent, /api/v1/suggestions, /api/v1/timeline, /api/v1/contacts/diff, /api/v1/meeting/upcoming, /api/v1/reply-debt, /api/v1/hub/health, /api/v1/health/day, /api/v1/memory, POST /api/v1/ingest/ios, POST /api/v1/people/{slug}/forget, POST /api/v1/memory/correct/{id}, POST /api/v1/memory/assert, /health")
    if BIND_HOST == "0.0.0.0":
        print(
            "WARNING: OSTLER_API_BIND=0.0.0.0 exposes the Assistant API on "
            "every network interface. Default is 127.0.0.1 (loopback). "
            "Use Tailscale for remote access where possible.",
            file=sys.stderr,
            flush=True,
        )
    HTTPServer((BIND_HOST, PORT), Handler).serve_forever()
