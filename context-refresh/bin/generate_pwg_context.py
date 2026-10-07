#!/usr/bin/env python3
"""Generate a compact personal-context digest for the local assistant.

This script queries the local ical-server (the Hub's personal-graph API
that already runs on 127.0.0.1:8090) and writes a small markdown digest to
``~/.zeroclaw/workspace/CONTEXT.md``. The ZeroClaw daemon injects that file
verbatim into every system prompt (see
``crates/zeroclaw-runtime/src/agent/system_prompt.rs``), giving the assistant
baseline awareness of the people, meetings, and preferences that matter to the
customer without the 9B local model having to choose to call a tool every turn.

Design constraints (TNM brief, locked 2026-05-31):
  - Local only. The only host contacted is 127.0.0.1. No outbound calls.
  - Compact. CONTEXT.md rides in every prompt, so it is capped at a few KB.
  - Privacy aware. Nothing derived from L3 ("private") content is emitted.
  - Degrades without crashing, but NEVER silently. A section that could not
    be read is reported by name with the status code that was actually
    observed, and the exit code carries the verdict. The prior CONTEXT.md is
    left untouched when nothing could be assembled, because a stale digest
    beats no digest -- but the run does not exit 0.

AUTHENTICATION (the defect this file carried until 2026-08-18)
--------------------------------------------------------------
The ical-server's data plane has been behind a bearer token since v1.0.10
(#200): ``_PUBLIC_GET_PATHS`` there is exactly ``{"/health",
"/api/v1/hydration/status"}`` and every other route fails CLOSED with 401.
This script sent no ``Authorization`` header, so all four of its
``/api/v1/*`` reads returned 401 on every install, every tick, since the
day the token landed. The token was sitting on disk the whole time.

AND THE FIX ALREADY EXISTED. This is a VENDOR STALENESS defect, not a
missed bug. Upstream ``ostler-assistant scripts/generate_pwg_context.py``
has carried ``_service_token()`` since PR #232 ("v1.0.11 data-dark fix"),
and upstream CI has a job named "Context Digest Auth" whose step is
"Digest writer sends service-token auth". That gate has been green the
whole time. It guards the copy that does NOT ship: the release tarball
carries the daemon binary and its .app, never ``scripts/``, so the copy
customers actually run is this vendored one, pinned at ``f441f09f`` from
BEFORE #232, in a repo with no such gate.

So the gate and the defect were not merely on different surfaces, they
were in different repositories. Worth stating plainly, because the next
person to "fix" this by re-vendoring will take the auth and silently drop
the three CM051-local read-side divergences below it.

Measured on a v1.0.36 install, 2026-08-18, before the fix:

    GET /health                    -> 200   (unauthenticated, always was)
    GET /api/v1/timeline           -> 401
    GET /api/v1/suggestions        -> 401
    GET /api/v1/coach/recent       -> 401
    GET /api/v1/people/recent      -> 401
    ... and with `Authorization: Bearer <secrets/service_token>`:
    GET /api/v1/timeline           -> 200, 200 items (61 of kind "meeting")
    GET /api/v1/suggestions        -> 200, 5 recent_meetings + 5 birthdays

ONE 401 IN THAT LIST WAS HIDING A SECOND, DIFFERENT DEFECT. Re-measured on a
v1.0.37 box 2026-08-20, with the auth fix in place and the same token:

    GET /api/v1/timeline           -> 200
    GET /api/v1/suggestions        -> 200
    GET /api/v1/coach/recent       -> 400  {"error": "user_id query parameter
                                            is required"}

The auth fix turned five of six 401s into 200s and left this one red for an
unrelated reason: the call has always omitted a REQUIRED query parameter, and
while everything returned 401 there was no way to see it. Fixing a whole class
at once hides any member that was broken twice. The tick's
`last exit code = 2` came from this single call; see ``_preferences_section``.

Three separate things kept that invisible, and all three are fixed here:
  1. ``_get_json`` swallowed the HTTPError and returned None, which the
     callers read as "this section is unavailable". Degrading gracefully
     from SIX of six sections is total failure wearing partial success.
  2. The failure line named two causes -- "ical-server down or empty
     graph" -- that this script never measured. On the install that
     surfaced it, ical-server answered /health 200 and the graph held
     6,549 person nodes, so BOTH named causes were false and every reader
     was sent the wrong way. A message must name what it MEASURED.
  3. It returned 0, so the LaunchAgent reported success.

The gate/defect split that hid it: the install-time health check probes
``/health``, which is unauthenticated and returns 200. The consumer uses
``/api/v1/*``, which is authenticated. Gate and defect sat on different
surfaces, so the gate was green forever.

The token is read from the environment first (matching the daemon and the
Doctor, which both accept OSTLER_SERVICE_TOKEN then legacy
PWG_SERVICE_TOKEN) and then from ``~/.ostler/secrets/service_token``,
which install.sh writes 0600. It is deliberately NOT rendered into this
LaunchAgent's plist: INSTALL_SNIPPET chmods plists 0644, and a 0600 secret
does not belong in a 0644 file when the process can simply read the
original. The token value is never logged.

Run it after each hydrate and on an interval (the CM051 installer wires a
LaunchAgent that calls this; see the hand-off note in the builder report).

WHAT THIS DIGEST NOW SAYS ABOUT ITS OWN GAPS (HR015 #948)
---------------------------------------------------------
Four daily briefs reached a customer as messages. One announced "trips to
places like New York in September 2026 and Singapore later that year". There
are no such trips; "places like" is the tell that the model was generating
examples and the brief was presenting them as recall.

The cause is in this file, not in the prompt. Every section below renders only
when it has content, so a section whose source returned 401 or 400 was, in the
document the model reads, byte for byte identical to a section whose source
answered and held nothing. The difference was measured all along -- it went to
``_FAILURES``, to the stderr report and to the exit code -- and none of those
three reach the one consumer that can act on it. launchd hears the exit code;
the model writing the customer's message hears nothing.

So the fact is now put in the document. ``_unreadable_and_empty_block`` renders
three states rather than two (items / nothing stored / COULD NOT BE READ, with
the status actually observed), early enough that the MAX_CHARS clip cannot
remove it. And when NO section produced content, the prior digest is still kept
-- a stale digest beats no digest -- but it is stamped NOT REFRESHED in the
file itself, so an hour-old refusal cannot be recited as today's news.

Guarded by ``tests/test_a_brief_cannot_fill_a_gap_it_was_never_shown.sh``,
wired into ``.github/workflows/context-digest-auth.yml``.

SHIP-GATE (divergent-twin / paired fix): the per-owner calendar labelling
below is the READ-SIDE half of a two-repo fix. The WRITE-SIDE half (which
stamps pwg:sourceCalendar / pwg:calendarType and fails calendar privacy
CLOSED to L3) lives in CM041 ``contact_syncer/google_calendar.py`` and
ships to a customer Hub only via CM051 ``vendor/cm041/`` + the HR015
tarball. This context-refresh script ships from CM051 ``context-refresh/``.
Neither half is safe alone -- land + re-vendor + re-cut BOTH. If the CM041
write-side has not landed, calendar rows carry no owner and fall under the
"Your calendar" bucket, silently misattributing a partner's diary to the
operator; do not ship this read-side change without its write-side twin.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

# ── Configuration ───────────────────────────────────────────────────────────

# The ical-server binds to loopback only. Allow an override for non-default
# deployments but keep the default pinned to localhost so the digest can never
# be assembled from a remote host.
BASE_URL = os.environ.get("OSTLER_ICAL_BASE_URL", "http://127.0.0.1:8090")

# Oxigraph (the PWG triple store) also binds to loopback. User-asserted facts
# -- things the customer explicitly confirmed to the assistant ("Robin is my
# wife"), banked by CM041's assert endpoint as pwg:PersonFact nodes -- live
# here, not behind an ical-server endpoint. We read them directly with a small
# SPARQL SELECT, mirroring the ical-server's own query helper. Default is
# pinned to localhost so the digest can never be assembled from a remote host.
OXIGRAPH_URL = os.environ.get("OXIGRAPH_URL", "http://127.0.0.1:7878")

# The PWG ontology namespace, matching the ical-server / contact_syncer.
PWG_NS = "https://schema.ostler.ai/ontology#"

# Hard cap on the digest size. CONTEXT.md is injected into every system prompt,
# so it must stay small. BOOTSTRAP_MAX_CHARS in the daemon defaults to 20000;
# we stay well under that on purpose so the digest never dominates the prompt.
MAX_CHARS = int(os.environ.get("OSTLER_CONTEXT_MAX_CHARS", "6000"))

# Per-request timeout. The server is local, so this is generous; it exists only
# to stop a wedged server from hanging the LaunchAgent.
REQUEST_TIMEOUT_SECS = 8

# How many of each section to surface. Kept small to respect MAX_CHARS.
MAX_PEOPLE = 6
MAX_MEETINGS = 5
MAX_PREFERENCES = 8
MAX_ORGS = 6
# Calendar events (flights, trips, appointments) surfaced grouped by whose
# calendar they came from, so the brief never merges one person's trip into
# another's. Bounded per-owner and overall to respect MAX_CHARS.
MAX_CALENDAR_PER_OWNER = 6
MAX_CALENDAR_TOTAL = 14

# User-asserted facts are authoritative and go at the top of the digest, so we
# allow more of them than the mined sections -- but still bounded so a runaway
# graph cannot blow the prompt budget.
MAX_USER_ASSERTED = 50

# Privacy levels we will NOT surface in the digest. The digest is baseline
# always-on context, so anything marked private (L3) is withheld. Endpoints
# generally pre-filter, but we double-check any per-record level field.
WITHHELD_PRIVACY_LEVELS = {"l3", "private"}

WORKSPACE_DIR = Path(
    os.environ.get("ZEROCLAW_WORKSPACE_DIR")
    or (Path.home() / ".zeroclaw" / "workspace")
)
CONTEXT_PATH = WORKSPACE_DIR / "CONTEXT.md"

# Env vars the service token may be seeded under. Same names, same
# precedence, as the Doctor proxy (vendor/doctor/agent/proxy.py
# _SERVICE_TOKEN_ENV_VARS) and the ical-server itself
# (vendor/cm041/assistant_api/ical-server.py _expected_service_token).
# OSTLER_SERVICE_TOKEN wins; PWG_SERVICE_TOKEN is the legacy name still
# rendered into the assistant LaunchAgent by install.sh.
_SERVICE_TOKEN_ENV_VARS = ("OSTLER_SERVICE_TOKEN", "PWG_SERVICE_TOKEN")

# Fallback: the file install.sh writes 0600 in the auth_tokens phase. This
# is the path the daemon's own code-side fallback reads, so a Hub where the
# env was never seeded still authenticates.
#
# Override env var is OSTLER_SERVICE_TOKEN_FILE, matching the name upstream
# already uses in ostler-assistant scripts/generate_pwg_context.py. Same name
# on both sides keeps the eventual re-vendor a merge rather than a puzzle.
SERVICE_TOKEN_PATH = Path(
    os.environ.get("OSTLER_SERVICE_TOKEN_FILE")
    or (Path.home() / ".ostler" / "secrets" / "service_token")
)

# OXIGRAPH NOW REQUIRES A BEARER (measured 2026-10-07 on a v1.0.107 candidate:
# a bare SPARQL POST to 127.0.0.1:7878/query -> 401, the same POST carrying
# `Authorization: Bearer <secrets/oxigraph_token>` -> 200). install.sh seeds the
# token 0600 and fronts the store with a proxy that refuses anything else. This
# script sent no header, so both of its SPARQL sections would have rendered
# COULD NOT BE READ on every tick after the store restarted with auth on.
_OXIGRAPH_TOKEN_ENV_VARS = ("OSTLER_OXIGRAPH_TOKEN", "OXIGRAPH_TOKEN")
OXIGRAPH_TOKEN_PATH = Path(
    os.environ.get("OSTLER_OXIGRAPH_TOKEN_FILE")
    or (Path.home() / ".ostler" / "secrets" / "oxigraph_token")
)

# Exit codes. The LaunchAgent's exit status is the only signal launchd and
# the Doctor get, so it has to carry the verdict rather than always saying
# "fine". Documented here because the wrapper and the plist both cite them.
EXIT_OK = 0                 # digest written, every source answered
EXIT_WRITE_FAILED = 1       # digest built but could not be written to disk
EXIT_NOTHING_PRODUCED = 2   # zero of eleven sections; no digest exists to write
EXIT_DEGRADED = 3           # digest written, but one or more sources failed


# ── Measured outcomes ────────────────────────────────────────────────────────
#
# Every source read appends one factual line here: what was asked, and what
# came back. Nothing in these lists is inferred -- a line is appended only by
# the code that performed the read and saw the answer. This exists because the
# message it replaces named causes ("ical-server down or empty graph") that the
# script had never checked, and both were false on the install that surfaced
# the defect.

_READS: list[str] = []
_FAILURES: list[str] = []
# Per-section item counts from the last build_digest() call, in digest order.
_SECTION_COUNTS: list[tuple[str, int]] = []
# Per-section (digest heading, item count, failed reads) from the last
# build_digest() call. This is what lets the DIGEST itself tell "the source
# answered and held nothing" apart from "the source did not answer"; see
# _unreadable_and_empty_block.
_SECTION_STATUS: list[tuple[str, int, list[str]]] = []
# /api/v1/preferences is read by two sections (Tastes, Preferences); one read
# per build, so the ledger counts one read and one failure, not two.
_PREFS_CACHE: dict = {}


def _reset_measurements() -> None:
    """Clear the measured-outcome ledgers. Called at the top of build_digest so
    a second call in one process reports that call, not the accumulated pair."""
    _READS.clear()
    _FAILURES.clear()
    _SECTION_COUNTS.clear()
    _SECTION_STATUS.clear()
    _PREFS_CACHE.clear()


def _note_read(line: str) -> None:
    _READS.append(line)


def _note_failure(line: str) -> None:
    _READS.append(line)
    _FAILURES.append(line)


def _tilde(path: Path) -> str:
    """Render a path with the home prefix collapsed to ``~``, so a log line
    never carries the operator's home directory."""
    try:
        return "~/" + str(path.relative_to(Path.home()))
    except ValueError:
        return str(path)


# ── Service token ────────────────────────────────────────────────────────────


def service_token() -> str:
    """Return the ical-server service bearer, or "" when none can be found.

    Environment first (OSTLER_SERVICE_TOKEN, then legacy PWG_SERVICE_TOKEN),
    then the 0600 file install.sh writes. Mirrors the resolution order the
    daemon and the Doctor already use, so there is one scheme on this box and
    not three. The value is never logged, only its provenance.
    """
    for name in _SERVICE_TOKEN_ENV_VARS:
        raw = (os.environ.get(name) or "").strip()
        if raw:
            return raw
    try:
        return SERVICE_TOKEN_PATH.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def _token_provenance() -> str:
    """Where the token came from, for the measured report. Never the value."""
    for name in _SERVICE_TOKEN_ENV_VARS:
        if (os.environ.get(name) or "").strip():
            return f"service token: resolved from ${name}"
    try:
        if SERVICE_TOKEN_PATH.read_text(encoding="utf-8").strip():
            return f"service token: resolved from {_tilde(SERVICE_TOKEN_PATH)}"
    except OSError:
        pass
    return (
        "service token: NOT FOUND ("
        + " and ".join(f"${n}" for n in _SERVICE_TOKEN_ENV_VARS)
        + f" unset or empty; {_tilde(SERVICE_TOKEN_PATH)} unreadable or empty)"
    )


def oxigraph_token() -> str:
    """The Oxigraph store bearer, or "" when none can be found. Env first,
    then the 0600 file install.sh writes. The value is never logged."""
    for name in _OXIGRAPH_TOKEN_ENV_VARS:
        raw = (os.environ.get(name) or "").strip()
        if raw:
            return raw
    try:
        return OXIGRAPH_TOKEN_PATH.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


# ── Owner identity ───────────────────────────────────────────────────────────
#
# The digest has to know WHO the owner is to say anything about them. This
# LaunchAgent's plist carries only PATH, so the identity is read the same way
# the other consumers on the box get it: the environment first, then the
# installer-written env files under $OSTLER_DIR (config/.env carries USER_ID
# and USER_NAME; .env carries WIKI_OPERATOR_NAME and WIKI_OPERATOR_EMAILS).
# Parsed as KEY=value text, never sourced, so nothing in them executes.

_IDENTITY_KEYS = ("USER_ID", "USER_NAME", "USER_EMAIL",
                  "WIKI_OPERATOR_NAME", "WIKI_OPERATOR_EMAILS")


def _read_env_file(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return out
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        if line.startswith("export "):
            line = line[len("export "):]
        key, _, value = line.partition("=")
        key = key.strip()
        if key not in _IDENTITY_KEYS:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        out.setdefault(key, value.strip())
    return out


def _owner_identity() -> dict:
    """Return {"user_id", "name", "emails"} for the owner. Empty values when
    nothing on this box names them; never raises."""
    ostler_dir = Path(os.environ.get("OSTLER_DIR") or (Path.home() / ".ostler"))
    merged: dict[str, str] = {}
    for key in _IDENTITY_KEYS:
        val = (os.environ.get(key) or "").strip()
        if val:
            merged[key] = val
    for path in (ostler_dir / "config" / ".env", ostler_dir / ".env"):
        for key, val in _read_env_file(path).items():
            if val and key not in merged:
                merged[key] = val
    emails: list[str] = []
    for raw in (merged.get("USER_EMAIL", ""),
                merged.get("WIKI_OPERATOR_EMAILS", "")):
        for part in raw.replace(";", ",").split(","):
            e = part.strip().lower()
            if "@" in e and e not in emails:
                emails.append(e)
    return {
        "user_id": merged.get("USER_ID", "").strip().lower(),
        "name": (merged.get("USER_NAME") or merged.get("WIKI_OPERATOR_NAME")
                 or "").strip(),
        "emails": emails,
    }


def _sparql_literal(value: str) -> str:
    """A SPARQL string literal, escaped. Values come from env files and the
    graph, so they are escaped rather than trusted."""
    esc = (value.replace("\\", "\\\\").replace('"', '\\"')
           .replace("\n", "\\n").replace("\r", "\\r"))
    return f'"{esc}"'


def _iri_ok(uri: str) -> bool:
    return bool(uri) and not any(c in uri for c in '<>"{}|^`\\ \n')


def _owner_uris(identity: dict) -> list[str] | None:
    """Every Person node that is the owner. None when the read failed.

    Same three arms the ical-server uses to exclude the owner from their own
    People list (_load_people_list_self_uris), plus pwg:isOwner: the anchor
    node pwg:user_<USER_ID>, a Person whose displayName is the owner's name,
    and a Person carrying one of the owner's email identifiers. A box's owner
    is routinely spread over several nodes (identity_fragmented), so this is
    a set, not a single URI.
    """
    uris: list[str] = []
    if identity["user_id"]:
        uris.append(f"{PWG_NS}user_{identity['user_id']}")
    arms = ["{ ?p pwg:isOwner true }"]
    if identity["name"]:
        arms.append(
            "{ ?p a pwg:Person ; pwg:displayName ?n . "
            f"FILTER(LCASE(STR(?n)) = {_sparql_literal(identity['name'].lower())}) }}"
        )
    if identity["emails"]:
        vals = ", ".join(_sparql_literal(e) for e in identity["emails"])
        arms.append(
            "{ ?p pwg:hasIdentifier ?id . ?id pwg:identifierValue ?v . "
            f"FILTER(LCASE(STR(?v)) IN ({vals})) }}"
        )
    rows = _sparql_select(
        f"PREFIX pwg: <{PWG_NS}>\nSELECT DISTINCT ?p WHERE {{\n  "
        + "\n  UNION\n  ".join(arms)
        + "\n} LIMIT 50"
    )
    if rows is None:
        return None
    for row in rows:
        uri = (row.get("p") or "").strip() if isinstance(row, dict) else ""
        if _iri_ok(uri) and uri.startswith("http") and uri not in uris:
            uris.append(uri)
    return uris


def _values_clause(var: str, uris: list[str]) -> str:
    return "VALUES ?%s { %s }" % (var, " ".join(f"<{u}>" for u in uris if _iri_ok(u)))


def _today() -> datetime:
    return datetime.now(timezone.utc)


# ── HTTP helper ──────────────────────────────────────────────────────────────


def _get_json(path: str) -> dict | None:
    """GET a JSON endpoint on the local ical-server.

    Returns the parsed object on success, or None when the read could not
    deliver data. Does not raise -- a section that cannot be read is omitted
    rather than crashing the tick -- but every non-delivery is RECORDED in
    ``_FAILURES`` with the status actually observed, and the recorded failures
    are what drive the exit code. Silence is what made this defect invisible;
    "returns None" is not the same thing as "there is nothing there".
    """
    url = f"{BASE_URL}{path}"
    headers = {"Accept": "application/json"}
    token = service_token()
    if token:
        # Both accepted forms, matching upstream. The ical-server's
        # _presented_token reads Authorization: Bearer first and falls back to
        # X-Ostler-Service, so sending both works regardless of build.
        headers["Authorization"] = f"Bearer {token}"
        headers["X-Ostler-Service"] = token
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_SECS) as resp:
            if resp.status != 200:
                _note_failure(f"GET {path} -> HTTP {resp.status}")
                return None
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        # Must be caught BEFORE URLError: HTTPError subclasses it, and the
        # old combined tuple is precisely how six 401s vanished without trace.
        hint = ""
        if exc.code in (401, 403):
            # The provenance line is printed once, at the head of the report;
            # repeating it on every refused route buries the reads it is
            # meant to explain.
            hint = " -- the ical-server data plane requires the service bearer"
        _note_failure(f"GET {path} -> HTTP {exc.code}{hint}")
        return None
    except (urllib.error.URLError, OSError) as exc:
        _note_failure(f"GET {path} -> unreachable ({type(exc).__name__}: {exc})")
        return None
    except ValueError as exc:
        _note_failure(f"GET {path} -> bad request ({type(exc).__name__}: {exc})")
        return None
    try:
        parsed = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        _note_failure(f"GET {path} -> HTTP 200 but body was not JSON")
        return None
    if not isinstance(parsed, dict):
        _note_failure(f"GET {path} -> HTTP 200 but body was not a JSON object")
        return None
    _note_read(f"GET {path} -> HTTP 200")
    return parsed


def _sparql_select(sparql: str) -> list[dict] | None:
    """Run a SPARQL SELECT on the local Oxigraph, return list of binding dicts.

    Mirrors the ical-server's own ``_sparql_select`` shape (one value per
    binding key) but degrades like ``_get_json``: returns None on any failure
    (store down, timeout, non-200, malformed JSON) so the section can be
    omitted without crashing the LaunchAgent. Does not raise, and like
    ``_get_json`` it RECORDS every non-delivery rather than absorbing it.

    Oxigraph WAS unauthenticated on the Hub (measured 2026-08-18 on a v1.0.36
    install). It no longer is (measured 2026-10-07, bare POST -> 401), so the
    per-install store bearer is attached when one can be found. Absent a
    token the request still goes out and the 401 is recorded, so the section
    says COULD NOT BE READ rather than "nothing stored".
    """
    label = "POST oxigraph /query"
    headers = {
        "Content-Type": "application/sparql-query",
        "Accept": "application/sparql-results+json",
    }
    token = oxigraph_token()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(
        OXIGRAPH_URL.rstrip("/") + "/query",
        data=sparql.encode("utf-8"),
        headers=headers,
    )
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_SECS) as resp:
            if resp.status != 200:
                _note_failure(f"{label} -> HTTP {resp.status}")
                return None
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        _note_failure(f"{label} -> HTTP {exc.code}")
        return None
    except (urllib.error.URLError, OSError) as exc:
        _note_failure(f"{label} -> unreachable ({type(exc).__name__}: {exc})")
        return None
    except ValueError as exc:
        _note_failure(f"{label} -> bad request ({type(exc).__name__}: {exc})")
        return None
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        _note_failure(f"{label} -> HTTP 200 but body was not JSON")
        return None
    if not isinstance(data, dict):
        _note_failure(f"{label} -> HTTP 200 but body was not a JSON object")
        return None
    bindings = data.get("results", {}).get("bindings", [])
    if not isinstance(bindings, list):
        _note_failure(f"{label} -> HTTP 200 but results.bindings was not a list")
        return None
    _note_read(f"{label} -> HTTP 200, {len(bindings)} binding(s)")
    return [
        {k: v["value"] for k, v in b.items() if isinstance(v, dict) and "value" in v}
        for b in bindings
        if isinstance(b, dict)
    ]


def _is_withheld(record: dict) -> bool:
    """True when a record is marked private (L3) and must not be surfaced."""
    level = str(record.get("privacy_level") or record.get("level") or "").lower()
    return level in WITHHELD_PRIVACY_LEVELS


# ── Section builders ─────────────────────────────────────────────────────────


def _user_asserted_section() -> list[str]:
    """Facts the customer explicitly confirmed to the assistant.

    These are pwg:PersonFact nodes carrying pwg:factSource "user_asserted"
    (banked by CM041's assert endpoint when the customer says something like
    "Robin is my wife"). They are authoritative, so they sit at the very top
    of the digest -- the assistant should always know them. Most-recent-first,
    bounded by MAX_USER_ASSERTED, de-duplicated on the rendered line.
    """
    rows = _sparql_select(
        'PREFIX pwg: <{ns}>\n'
        'SELECT ?text ?name ?rel ?created ?level WHERE {{\n'
        '  ?f a pwg:PersonFact ;\n'
        '     pwg:factSource "user_asserted" ;\n'
        '     pwg:factText ?text .\n'
        '  OPTIONAL {{ ?f pwg:aboutPerson ?p .\n'
        '             OPTIONAL {{ ?p pwg:displayName ?name }}\n'
        '             OPTIONAL {{ ?p pwg:relationshipType ?rel }} }}\n'
        '  OPTIONAL {{ ?f pwg:createdAt ?created }}\n'
        '  OPTIONAL {{ ?f pwg:privacyLevel ?level }}\n'
        '  FILTER NOT EXISTS {{ ?f pwg:validTo ?end }}\n'
        '}} ORDER BY DESC(?created) LIMIT {limit}'.format(
            ns=PWG_NS, limit=MAX_USER_ASSERTED * 3
        )
    )
    if not rows:
        return []

    lines: list[str] = []
    seen: set[str] = set()
    for row in rows:
        if not isinstance(row, dict) or _is_withheld({"level": row.get("level")}):
            continue
        text = (row.get("text") or "").strip()
        if not text:
            continue
        line = f"- {text}"
        key = line.lower()
        if key in seen:
            continue
        seen.add(key)
        lines.append(line)
        if len(lines) >= MAX_USER_ASSERTED:
            break
    return lines


# Interaction weights for ranking people. A meeting is a deliberate block of
# the owner's time and much rarer than a message, so one meeting is worth
# MEETING_WEIGHT messages. Tuned to keep a weekly 1:1 above a noisy group
# thread, not derived from data.
MEETING_WEIGHT = 5
_RANK_POOL = 200


def _ranked_people(owner_uris: list[str], owner_name: str) -> list[dict] | None:
    """People ranked by REAL interaction counts in the graph.

    Two counts, both read off the default graph CM041 writes:
      messages: SUM of pwg:totalMessages on pwg:RelationshipSignal ?s
                pwg:about ?person (the per-thread message tallies);
      meetings: COUNT of pwg:Meeting nodes listing the person as a
                pwg:meetingAttendee.
    L3 signals, L3 meetings and L3 people are dropped. The owner is
    excluded by URI and by name, and a "name" that is an email address is
    an organiser mailbox, not a person, so it is excluded too.

    Returns None when any read failed (the caller then reports COULD NOT
    BE READ); [] when the store answered and held no interactions.

    This replaces /api/v1/suggestions.recent_meetings, which lists the
    ORGANISERS of recent calendar entries: on the box that surfaced it,
    four of five rows were mailbox addresses and the fifth was the owner.
    """
    not_l3 = 'FILTER(!BOUND(?l) || UCASE(STR(?l)) != "L3")'
    msg_rows = _sparql_select(
        f"PREFIX pwg: <{PWG_NS}>\n"
        "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
        "SELECT ?p (SUM(xsd:integer(?t)) AS ?n) WHERE {\n"
        "  ?s a pwg:RelationshipSignal ; pwg:about ?p ; pwg:totalMessages ?t .\n"
        f"  OPTIONAL {{ ?s pwg:privacyLevel ?l }} {not_l3}\n"
        f"}} GROUP BY ?p ORDER BY DESC(?n) LIMIT {_RANK_POOL}"
    )
    meet_rows = _sparql_select(
        f"PREFIX pwg: <{PWG_NS}>\n"
        "SELECT ?p (COUNT(DISTINCT ?m) AS ?n) WHERE {\n"
        "  ?m a pwg:Meeting ; pwg:meetingAttendee ?p .\n"
        f"  OPTIONAL {{ ?m pwg:privacyLevel ?l }} {not_l3}\n"
        f"}} GROUP BY ?p ORDER BY DESC(?n) LIMIT {_RANK_POOL}"
    )
    if msg_rows is None or meet_rows is None:
        return None

    def _int(v) -> int:
        try:
            return int(float(v))
        except (TypeError, ValueError):
            return 0

    owners = set(owner_uris)
    tally: dict[str, list[int]] = {}
    for rows, idx in ((msg_rows, 0), (meet_rows, 1)):
        for row in rows:
            if not isinstance(row, dict):
                continue
            uri = (row.get("p") or "").strip()
            if not _iri_ok(uri) or uri in owners:
                continue
            tally.setdefault(uri, [0, 0])[idx] += _int(row.get("n"))
    if not tally:
        return []
    ranked = sorted(tally.items(),
                    key=lambda kv: kv[1][0] + MEETING_WEIGHT * kv[1][1],
                    reverse=True)[:_RANK_POOL]
    detail = _sparql_select(
        f"PREFIX pwg: <{PWG_NS}>\n"
        "SELECT ?p ?name ?org ?l WHERE {\n"
        f"  {_values_clause('p', [u for u, _ in ranked])}\n"
        "  ?p pwg:displayName ?name .\n"
        "  OPTIONAL { ?p pwg:organization ?org }\n"
        "  OPTIONAL { ?p pwg:privacyLevel ?l }\n"
        "  FILTER NOT EXISTS { ?p pwg:mergedInto ?x }\n"
        "}"
    )
    if detail is None:
        return None
    info: dict[str, dict] = {}
    for row in detail:
        if not isinstance(row, dict):
            continue
        uri = row.get("p") or ""
        if uri in info:
            continue
        info[uri] = row
    owner_norm = " ".join(owner_name.lower().split())
    out: list[dict] = []
    for uri, (msgs, meets) in ranked:
        row = info.get(uri)
        if not row or _is_withheld({"level": row.get("l")}):
            continue
        name = (row.get("name") or "").strip()
        if not name or "@" in name:
            continue
        if owner_norm and " ".join(name.lower().split()) == owner_norm:
            continue
        out.append({
            "uri": uri, "name": name,
            "org": (row.get("org") or "").strip(),
            "messages": msgs, "meetings": meets,
            "score": msgs + MEETING_WEIGHT * meets,
        })
    return out


def _people_section() -> list[str]:
    """The people the owner interacts with most, by messages and meetings."""
    identity = _owner_identity()
    owners = _owner_uris(identity)
    if owners is None:
        return []
    people = _ranked_people(owners, identity["name"])
    if not people:
        return []
    lines: list[str] = []
    for p in people[:MAX_PEOPLE]:
        bits = [p["name"]] + ([p["org"]] if p["org"] else [])
        counts = []
        if p["messages"]:
            counts.append(f"{p['messages']} messages")
        if p["meetings"]:
            counts.append(f"{p['meetings']} meetings")
        lines.append(f"- {', '.join(bits)} ({', '.join(counts)})")
    return lines


def _norm_org(org: str) -> str:
    return " ".join(org.lower().replace(",", " ").split())


def _about_you_section() -> list[str]:
    """Who the owner is: name, work history, places, family and close people.

    THIS SECTION DID NOT EXIST, and it is why the assistant answered "Where
    have I worked?" with "I have no record" on a box whose graph held the
    owner's LinkedIn positions and whose ical-server resolved their employer.

    Sources, each read and each recorded:
      * /api/v1/employer: the ical-server's deterministic current-employer
        resolver (corrections and hygiene applied), plus former employers.
      * pwg:PersonFact factType "career_position" about any owner node (the
        LinkedIn Positions.csv import): organisation, title, dates.
      * pwg:organization / pwg:jobTitle on the owner's own Person nodes (the
        Contacts me-card).
      * urn:ostler:Fact in the owner's named graph, type "location" (places)
        and domain "family" or type "relationship" (family and close people).
    L3 is withheld everywhere. The "- Work:" line lists organisations
    comma-separated, current first; roles and dates go on their own line so
    the list stays machine-readable.
    """
    identity = _owner_identity()
    lines: list[str] = []
    if identity["name"]:
        lines.append(f"- Name: {identity['name']}")

    # entries: (org, title, start, end, is_current)
    entries: list[tuple[str, str, str, str, bool]] = []

    employer = _get_json("/api/v1/employer")
    former_from_endpoint: list[str] = []
    if isinstance(employer, dict) and employer.get("found") and not _is_withheld(employer):
        org = str(employer.get("employer") or "").strip()
        if org:
            entries.append((org, str(employer.get("job_title") or "").strip(),
                            str(employer.get("start_date") or "").strip(), "", True))
        for f in employer.get("former_employers") or []:
            name = (f.get("employer") if isinstance(f, dict) else f) or ""
            if str(name).strip():
                former_from_endpoint.append(str(name).strip())

    owners = _owner_uris(identity)
    careers_open: list[tuple] = []
    careers_closed: list[tuple] = []
    mecard: list[tuple] = []
    if owners:
        values = _values_clause("p", owners)
        career_rows = _sparql_select(
            f"PREFIX pwg: <{PWG_NS}>\n"
            "SELECT ?org ?title ?start ?end ?l WHERE {\n"
            f"  {values}\n"
            '  ?f a pwg:PersonFact ; pwg:factType "career_position" ;\n'
            "     pwg:aboutPerson ?p ; pwg:organization ?org .\n"
            "  OPTIONAL { ?f pwg:jobTitle ?title }\n"
            "  OPTIONAL { ?f pwg:startDate ?start }\n"
            "  OPTIONAL { ?f pwg:endDate ?end }\n"
            "  OPTIONAL { ?f pwg:privacyLevel ?l }\n"
            "  FILTER NOT EXISTS { ?f pwg:validTo ?gone }\n"
            "} LIMIT 60"
        ) or []
        for row in career_rows:
            if not isinstance(row, dict) or _is_withheld({"level": row.get("l")}):
                continue
            org = (row.get("org") or "").strip()
            if not org:
                continue
            item = (org, (row.get("title") or "").strip(),
                    (row.get("start") or "").strip(), (row.get("end") or "").strip())
            (careers_closed if item[3] else careers_open).append(item)
        mecard_rows = _sparql_select(
            f"PREFIX pwg: <{PWG_NS}>\n"
            "SELECT ?org ?title ?l WHERE {\n"
            f"  {values}\n"
            "  ?p pwg:organization ?org .\n"
            "  OPTIONAL { ?p pwg:jobTitle ?title }\n"
            "  OPTIONAL { ?p pwg:privacyLevel ?l }\n"
            "} LIMIT 20"
        ) or []
        for row in mecard_rows:
            if not isinstance(row, dict) or _is_withheld({"level": row.get("l")}):
                continue
            org = (row.get("org") or "").strip()
            if org:
                mecard.append((org, (row.get("title") or "").strip(), "", ""))

    careers_open.sort(key=lambda e: e[2], reverse=True)
    careers_closed.sort(key=lambda e: e[3] or e[2], reverse=True)
    for org, title, start, end in careers_open + mecard:
        entries.append((org, title, start, end, True))
    for org, title, start, end in careers_closed:
        entries.append((org, title, start, end, False))
    for org in former_from_endpoint:
        entries.append((org, "", "", "", False))

    seen: set[str] = set()
    orgs: list[str] = []
    roles: list[str] = []
    for org, title, start, end, current in entries:
        key = _norm_org(org)
        if not key or key in seen:
            # A later duplicate can still contribute the title the first lacked.
            continue
        seen.add(key)
        orgs.append(org.replace(",", ""))
        if title:
            span = ""
            if start or end or current:
                span = f" ({start[:4] or '?'} to {end[:4] if end else 'present'})"
            roles.append(f"{title} at {org}{span}")
    if orgs:
        lines.append(f"- Work: {', '.join(orgs[:8])}")
    if roles:
        lines.append(f"- Roles: {'; '.join(roles[:5])}")

    uid = identity["user_id"]
    if uid:
        fact_rows = _sparql_select(
            "SELECT ?text ?t ?d ?l ?at WHERE {\n"
            "  GRAPH ?g {\n"
            "    ?f a <urn:ostler:Fact> ; <urn:ostler:text> ?text ;\n"
            "       <urn:ostler:userId> ?uid .\n"
            "    OPTIONAL { ?f <urn:ostler:type> ?t }\n"
            "    OPTIONAL { ?f <urn:ostler:domain> ?d }\n"
            "    OPTIONAL { ?f <urn:ostler:privacyLevel> ?l }\n"
            "    OPTIONAL { ?f <urn:ostler:observedAt> ?at }\n"
            "  }\n"
            f"  FILTER(LCASE(STR(?uid)) = {_sparql_literal(uid)})\n"
            '  FILTER(STR(?t) = "location" || STR(?t) = "relationship" || STR(?d) = "family")\n'
            "} ORDER BY DESC(?at) LIMIT 40"
        ) or []
        places: list[str] = []
        family: list[str] = []
        for row in fact_rows:
            if not isinstance(row, dict) or _is_withheld({"level": row.get("l")}):
                continue
            text = " ".join((row.get("text") or "").split())
            if not text:
                continue
            if len(text) > 110:
                text = text[:107].rstrip() + "..."
            bucket = places if row.get("t") == "location" else family
            if text not in bucket and len(bucket) < 4:
                bucket.append(text)
        if places:
            lines.append(f"- Places: {'; '.join(places)}")
        if family:
            lines.append(f"- Family and close people: {'; '.join(family)}")
    return lines


def _meetings_section() -> list[str]:
    """Recent (past) meetings from the merged timeline.

    The timeline endpoint returns both calendar (future) and meeting (past)
    kinds. We render ONLY the meeting kind here.

    The future / ``kind == "calendar"`` events are DELIBERATELY NOT rendered
    from this endpoint. The timeline endpoint carries no owner attribution,
    so surfacing calendar events here re-introduces the exact travel/flight
    conflation the pair fixes: a partner's shared-calendar flight would land
    under an un-labelled "Upcoming meetings" heading and the model would
    default it to the operator (BATCH1 #3 F1). Owner-labelling this endpoint
    is not feasible in this pass (no owner field on timeline rows), so the
    un-attributed upcoming section is RETIRED. Future calendar events reach
    the brief exclusively via ``_calendar_by_owner_section`` below, which
    reads the CM041 owner + type provenance and fails closed on L3.
    """
    data = _get_json("/api/v1/timeline?days=7")
    items = data.get("items") if isinstance(data, dict) else None
    if not isinstance(items, list):
        items = []

    recent: list[str] = []
    seen: set[str] = set()
    for item in items:
        if not isinstance(item, dict) or _is_withheld(item):
            continue
        summary = (item.get("summary") or "").strip()
        if not summary:
            continue
        # Only past meetings (kind == "meeting"). Calendar-kind rows are
        # skipped here -- see the docstring: they leak un-attributed.
        if item.get("kind") != "meeting":
            continue
        date = (item.get("date") or "").strip()
        label = f"- {summary}" + (f" ({date})" if date else "")
        if len(recent) < MAX_MEETINGS and summary.lower() not in seen:
            seen.add(summary.lower())
            recent.append(label)

    # Second source: the pwg:Meeting nodes themselves, last 7 days. The
    # section says "nothing stored" only when EVERY source behind it is
    # empty, so the graph is asked directly rather than trusting one
    # endpoint's window.
    for row in _meeting_rows(past=True):
        if len(recent) >= MAX_MEETINGS:
            break
        summary = row["summary"]
        if summary.lower() in seen:
            continue
        seen.add(summary.lower())
        recent.append(f"- {summary} ({row['date']})")
    return recent


def _meeting_rows(*, past: bool, days: int = 7, limit: int = 20) -> list[dict]:
    """pwg:Meeting rows in the last (past=True) or next ``days`` days.

    Read off the default graph CM041's meeting syncer writes (pwg:Meeting,
    pwg:meetingSummary, pwg:meetingDate "YYYY-MM-DD HH:MM:SS+ZZ:ZZ"). Day
    granularity on the date string, L3 withheld. Returns [] on a failed read
    (the failure is recorded by _sparql_select and surfaces as COULD NOT BE
    READ for the calling section).
    """
    today = _today().date()
    if past:
        lo, hi = today - timedelta(days=days), today + timedelta(days=1)
        order = "DESC(?d)"
    else:
        lo, hi = today, today + timedelta(days=days + 1)
        order = "?d"
    rows = _sparql_select(
        f"PREFIX pwg: <{PWG_NS}>\n"
        "SELECT ?summary ?d ?l WHERE {\n"
        "  ?m a pwg:Meeting ; pwg:meetingSummary ?summary ; pwg:meetingDate ?d .\n"
        "  OPTIONAL { ?m pwg:privacyLevel ?l }\n"
        f'  FILTER(STR(?d) >= "{lo.isoformat()}" && STR(?d) < "{hi.isoformat()}")\n'
        f"}} ORDER BY {order} LIMIT {limit}"
    ) or []
    now_s = _today().strftime("%Y-%m-%d %H:%M")
    out: list[dict] = []
    for row in rows:
        if not isinstance(row, dict) or _is_withheld({"level": row.get("l")}):
            continue
        summary = " ".join((row.get("summary") or "").split())
        date = (row.get("d") or "").strip().replace("T", " ")[:16]
        if not summary or not date:
            continue
        # Same-day split: past means already started, upcoming means not yet.
        if past and date > now_s:
            continue
        if not past and date < now_s:
            continue
        out.append({"summary": summary, "date": date})
    return out


def _calendar_by_owner_section() -> list[str]:
    """Calendar events (flights, trips, appointments) grouped by OWNER.

    This is the fix for travel/flight conflation in the daily brief. Calendar
    events are stored as pwg:PersonFact rows with pwg:factDomain "calendar";
    the CM041 ingest now stamps each with pwg:sourceCalendar (whose calendar
    it came from) and, when the operator has confirmed it at install,
    pwg:calendarType. We select those, drop L3, and render them GROUPED and
    LABELLED by owner so the model is handed pre-attributed facts and can
    never merge one person's trip into another's.

    Events with no owner label are grouped under "Unattributed" -- an
    unknown-owner event is NEVER silently labelled as the operator's own
    diary (that was a fail-open misattribution: a partner-diary event whose
    owner label was lost would have rendered as "Your calendar").
    """
    rows = _sparql_select(
        'PREFIX pwg: <{ns}>\n'
        'SELECT ?text ?owner ?type ?level ?valid WHERE {{\n'
        '  ?f a pwg:PersonFact ;\n'
        '     pwg:factDomain "calendar" ;\n'
        '     pwg:factText ?text .\n'
        '  OPTIONAL {{ ?f pwg:sourceCalendar ?owner }}\n'
        '  OPTIONAL {{ ?f pwg:calendarType ?type }}\n'
        '  OPTIONAL {{ ?f pwg:privacyLevel ?level }}\n'
        '  OPTIONAL {{ ?f pwg:validFrom ?valid }}\n'
        '}} ORDER BY DESC(?valid) LIMIT {limit}'.format(
            ns=PWG_NS, limit=MAX_CALENDAR_TOTAL * 4
        )
    ) or []

    # Group by owner, preserving most-recent-first order, honouring caps and
    # dropping L3. "Unattributed" is the bucket for unlabelled-owner events --
    # never attributed to the operator.
    order: list[str] = []
    grouped: dict[str, list[str]] = {}
    seen: set[tuple[str, str]] = set()
    total = 0
    for row in rows:
        if not isinstance(row, dict):
            continue
        if _is_withheld({"level": row.get("level")}):
            continue
        text = (row.get("text") or "").strip()
        if not text:
            continue
        owner = (row.get("owner") or "").strip() or "Unattributed"
        key = (owner.lower(), text.lower())
        if key in seen:
            continue
        seen.add(key)
        bucket = grouped.setdefault(owner, [])
        if owner not in order:
            order.append(owner)
        if len(bucket) >= MAX_CALENDAR_PER_OWNER:
            continue
        bucket.append(f"- {text}")
        total += 1
        if total >= MAX_CALENDAR_TOTAL:
            break

    # Second source: the owner's synced diary, pwg:Meeting, next 7 days.
    # On the box that surfaced #10 the factDomain "calendar" path held 0 rows
    # while 3,989 pwg:Meeting rows existed, and the digest told the model
    # "Calendar events by owner: nothing stored", which it is instructed to
    # treat as the answer. pwg:Meeting carries no owner field, so these go in
    # the "Unattributed" bucket: never presented as the operator's own diary.
    for row in _meeting_rows(past=False, limit=MAX_CALENDAR_PER_OWNER * 2):
        if total >= MAX_CALENDAR_TOTAL:
            break
        text = f"{row['summary']} ({row['date']})"
        key = ("unattributed", text.lower())
        if key in seen:
            continue
        seen.add(key)
        bucket = grouped.setdefault("Unattributed", [])
        if "Unattributed" not in order:
            order.append("Unattributed")
        if len(bucket) >= MAX_CALENDAR_PER_OWNER:
            break
        bucket.append(f"- {text}")
        total += 1

    if not grouped:
        return []

    # Render named owners in first-seen order, with the unknown-owner
    # "Unattributed" bucket LAST -- it is not privileged as the operator's
    # own. Each owner is a labelled sub-block so the attribution survives
    # into the prompt.
    def _owner_sort_key(o: str) -> tuple[int, int]:
        return (1 if o == "Unattributed" else 0, order.index(o))

    lines: list[str] = []
    for owner in sorted(order, key=_owner_sort_key):
        lines.append(f"**{owner}:**")
        lines.extend(grouped[owner])
    return lines


def _preferences_section() -> list[str]:
    """Top preferences from the coaching / observation surface.

    Best-effort: the endpoint may be absent on some Hubs. Each observation is
    summarised to a single short line.
    """
    # `user_id` IS REQUIRED BY THE SERVER AND WAS NEVER SENT.
    #
    # MEASURED on the live v1.0.37 box 2026-08-20, against the port this file
    # actually calls (BASE_URL = 127.0.0.1:8090, NOT the daemon on :8000):
    #
    #   curl 'http://127.0.0.1:8090/api/v1/coach/recent?hours=336&limit=8' \
    #        -H 'Authorization: Bearer <service_token>'
    #     -> 400 {"error": "user_id query parameter is required"}
    #
    #   same call + &user_id=me
    #     -> 200 {"observations": [], "note": "Coach database not found"}
    #
    # and on the same box, at the same moment, with the same token:
    #
    #   /api/v1/timeline?days=7   -> 200
    #   /api/v1/suggestions       -> 200
    #
    # So this was NOT the auth class the docstring above documents. Auth is
    # fine; one call of six was malformed. The tick's `last exit code = 2`
    # (launchctl print gui/<uid>/com.creativemachines.ostler.context-refresh)
    # came from this single 400.
    #
    # WHY A CONSTANT, AND WHY THIS ONE. The server accepts ANY value -- me,
    # default, owner, self and the login name all returned 200 with identical
    # bodies -- so the parameter is a required-but-unused positional in this
    # release. Ostler is single-machine and single-owner, so a fixed sentinel
    # is honest; a login name would put the operator's account name into a URL
    # for no gain, and a real identity here would be a claim the server does
    # not actually consult.
    #
    # Note what this fix does NOT do: the section stays EMPTY, because the
    # coach database does not exist on this box. The server says so in the
    # body rather than pretending. That is a declared empty-reason, not a
    # silent zero -- and whether the coach DB should exist at all is a
    # separate question, filed, not answered here.
    # FIRST SOURCE (#10, 2026-10-07): the compiled interest profile. This
    # section read ONLY the coach surface above, whose database does not exist
    # on a customer box, so it said "nothing stored" beside an interest
    # profile of 4,628 entries that /api/v1/preferences serves score-sorted.
    lines: list[str] = []
    interests = _interests()
    seen: set[str] = set()
    for it in interests:
        if not isinstance(it, dict):
            continue
        if _taste_domain(it) is not None:
            continue  # already rendered, with strength, under "Tastes"
        if _is_withheld({"level": it.get("privacy") or it.get("privacy_level")}):
            continue
        subject = " ".join(str(it.get("subject") or "").split())
        if not subject or subject.lower() in seen:
            continue
        seen.add(subject.lower())
        domain = str(it.get("domain") or "").strip()
        polarity = str(it.get("polarity") or "").lower()
        label = f"{subject} ({domain})" if domain else subject
        if polarity.startswith(("neg", "dis")) or polarity == "-1":
            lines.append(f"- Not keen on: {label}")
        else:
            lines.append(f"- {label}")
        if len(lines) >= MAX_PREFERENCES:
            return lines

    data = _get_json("/api/v1/coach/recent?hours=336&limit=8&user_id=me")
    if not data:
        return lines
    observations = data.get("observations")
    if not isinstance(observations, list):
        return lines

    for obs in observations:
        if not isinstance(obs, dict) or _is_withheld(obs):
            continue
        tip = (obs.get("tip") or obs.get("what_to_work_on") or "").strip()
        if not tip:
            continue
        lines.append(f"- {tip}")
        if len(lines) >= MAX_PREFERENCES:
            break
    return lines


def _orgs_section() -> list[str]:
    """Key organisations: where the people the owner interacts with work.

    Ranked by the summed interaction score of those people (the same ranking
    as the People section), so an organisation shows up because the owner
    actually deals with it. The old version aggregated an ``organisation``
    field from /api/v1/suggestions rows that do not carry one, so it said
    "nothing stored" beside 4,652 pwg:organization triples.
    """
    identity = _owner_identity()
    owners = _owner_uris(identity)
    if owners is None:
        return []
    people = _ranked_people(owners, identity["name"])
    if not people:
        return []
    score: dict[str, list] = {}
    for p in people:
        org = p["org"]
        key = _norm_org(org)
        if not key:
            continue
        slot = score.setdefault(key, [org, 0, 0])
        slot[1] += p["score"]
        slot[2] += 1
    ranked = sorted(score.values(), key=lambda v: v[1], reverse=True)
    return [f"- {org} ({n} {'person' if n == 1 else 'people'})"
            for org, _, n in ranked[:MAX_ORGS]]



# ── Owner brief: tastes, routines, priorities, autonomy, channel style ───────
#
# Four sections that turn the digest from "facts about the graph" into a brief
# on the owner. Every one reads a source that ships in this Hub and cites it
# below; a fact with no shipped source is a GAP, listed in the section or in
# the PR, never read from a guessed field.


def _interests() -> list:
    """The compiled interest profile, score-sorted, read once per build.

    GET /api/v1/preferences (vendor/cm041/assistant_api/ical-server.py
    api_preferences): {"interests": [{subject, domain, polarity, privacy,
    score, confidence, ...}]}, sorted by score descending, written by CM059
    (vendor/cm059_editor/compiler/interest_profile.py:757-771).
    """
    if "interests" not in _PREFS_CACHE:
        prefs = _get_json("/api/v1/preferences?limit=300")
        got = prefs.get("interests") if isinstance(prefs, dict) else None
        _PREFS_CACHE["interests"] = got if isinstance(got, list) else []
    return _PREFS_CACHE["interests"]


# CM059 category_domain() values (interest_profile.py:331-333): "Food", "Music",
# "Film & TV". Matched case-insensitively on the whole domain string.
_TASTE_DOMAINS = (("food", "Food"), ("music", "Music"), ("film & tv", "Film and TV"))
MAX_TASTES_PER_DOMAIN = 3


def _taste_domain(it: dict) -> str | None:
    dom = " ".join(str(it.get("domain") or "").lower().split())
    for key, label in _TASTE_DOMAINS:
        if dom == key:
            return label
    return None


def _is_negative(it: dict) -> bool:
    polarity = str(it.get("polarity") or "").lower()
    return polarity.startswith(("neg", "dis")) or polarity == "-1"


def _tastes_section() -> list[str]:
    """Top food, music and film preferences, each with its stored strength.

    Strength is the profile's own ``score``, printed as stored (two decimals).
    No scale is assumed: the digest does not turn it into "strong" or "mild"
    because the shipped profile does not define such bands.
    """
    by_domain: dict[str, list[str]] = {}
    seen: set[tuple[str, str]] = set()
    for it in _interests():
        if not isinstance(it, dict):
            continue
        if _is_withheld({"level": it.get("privacy") or it.get("privacy_level")}):
            continue
        label = _taste_domain(it)
        subject = " ".join(str(it.get("subject") or "").split())
        if label is None or not subject or (label, subject.lower()) in seen:
            continue
        seen.add((label, subject.lower()))
        bucket = by_domain.setdefault(label, [])
        if len(bucket) >= MAX_TASTES_PER_DOMAIN:
            continue
        try:
            score = f" {float(it.get('score')):.2f}"
        except (TypeError, ValueError):
            score = " unscored"
        bucket.append(f"{'dislikes ' if _is_negative(it) else ''}{subject[:40]} ({score.strip()})")
    return [f"- {label}: {'; '.join(items)}"
            for _, label in _TASTE_DOMAINS if (items := by_domain.get(label))]


ROUTINE_WINDOW_DAYS = 90
_ROUTINE_MIN_SAMPLE = 5
_WEEKDAYS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday",
             "Saturday", "Sunday")
MAX_COMMITMENTS = 4


def _routines_lines() -> list[str]:
    """When the owner's diary is busy, from pwg:Meeting dates they attend.

    Source: pwg:Meeting / pwg:meetingAttendee / pwg:meetingDate, the same
    triples the People ranking reads (_ranked_people). Timing only: counts of
    weekday and start hour, never a title or an attendee.
    """
    owners = _owner_uris(_owner_identity())
    if not owners:
        return []
    today = _today().date()
    lo = (today - timedelta(days=ROUTINE_WINDOW_DAYS)).isoformat()
    rows = _sparql_select(
        f"PREFIX pwg: <{PWG_NS}>\n"
        "SELECT DISTINCT ?m ?d ?l WHERE {\n"
        f"  {_values_clause('p', owners)}\n"
        "  ?m a pwg:Meeting ; pwg:meetingAttendee ?p ; pwg:meetingDate ?d .\n"
        "  OPTIONAL { ?m pwg:privacyLevel ?l }\n"
        '  FILTER(!BOUND(?l) || UCASE(STR(?l)) != "L3")\n'
        f'  FILTER(STR(?d) >= "{lo}" && STR(?d) < "{today.isoformat()}")\n'
        "} LIMIT 2000"
    ) or []
    days = [0] * 7
    hours: dict[int, int] = {}
    total = 0
    for row in rows:
        if not isinstance(row, dict) or _is_withheld({"level": row.get("l")}):
            continue
        raw = (row.get("d") or "").strip().replace("T", " ")
        try:
            when = datetime.strptime(raw[:16], "%Y-%m-%d %H:%M")
        except ValueError:
            continue
        total += 1
        days[when.weekday()] += 1
        hours[when.hour] = hours.get(when.hour, 0) + 1
    if not total:
        return []
    per_week = total / (ROUTINE_WINDOW_DAYS / 7)
    line = (f"- Routines: {total} meetings in the last {ROUTINE_WINDOW_DAYS} "
            f"days (about {per_week:.1f} a week)")
    if total >= _ROUTINE_MIN_SAMPLE:
        top = sorted(range(7), key=lambda i: (-days[i], i))[:2]
        busiest = " and ".join(_WEEKDAYS[i] for i in top if days[i])
        peak = max(hours, key=lambda h: (hours[h], -h))
        line += f"; busiest {busiest}; most often start around {peak:02d}:00"
    return [line + ". Timing only, taken from the diary."]


def _commitment_lines() -> list[str]:
    """Open commitments the owner owes, from GET /api/v1/commitments.

    Row shape (ical-server commitments_list): {action, owner, due, status,
    source}; owner=user selects what the operator owes. That endpoint is
    deliberately not privacy-gated (see its comment: the rows carry no
    privacyLevel), so the text is capped to 90 characters and the route's own
    privacy_level is honoured when present.
    """
    data = _get_json(f"/api/v1/commitments?owner=user&status=open&limit=50")
    if not isinstance(data, dict) or _is_withheld(data):
        return []
    rows = data.get("commitments")
    if not isinstance(rows, list):
        return []
    today = _today().date().isoformat()
    # An open commitment more than 90 days overdue is stale, not a priority.
    stale_before = (_today().date() - timedelta(days=90)).isoformat()
    items: list[tuple[tuple, str]] = []
    seen: set[str] = set()
    for r in rows:
        if not isinstance(r, dict) or _is_withheld(r):
            continue
        action = " ".join(str(r.get("action") or "").split())
        if not action or action.lower() in seen:
            continue
        seen.add(action.lower())
        due = str(r.get("due") or "").strip()[:10]
        if due and due < stale_before:
            continue
        if len(action) > 90:
            action = action[:87].rstrip() + "..."
        # Soonest upcoming first, then overdue, then undated.
        key = (0, due) if due >= today else ((1, due) if due else (2, ""))
        items.append((key, f"- Open: {action}" + (f" (due {due})" if due else "")))
    items.sort(key=lambda kv: kv[0])
    out = [text for _, text in items[:MAX_COMMITMENTS]]
    if len(items) > MAX_COMMITMENTS:
        out.append(f"- ({len(items) - MAX_COMMITMENTS} more open commitments not shown)")
    return out


def _routines_priorities_section() -> list[str]:
    """Routines (from diary timing) and open commitments. Upcoming diary items
    are in "Calendar events by owner", not repeated here."""
    return _routines_lines() + _commitment_lines()


# What the assistant may do unasked is a daemon setting, not a fact the digest
# can infer. install.sh writes only [autonomy].non_cli_excluded_tools
# (install.sh:16442-16443) and leaves level / auto_approve to the daemon's
# defaults (install.sh:16438-16440), so those two are read if, and only if,
# they are present in the config. The file is parsed line by line and ONLY the
# [autonomy] table is looked at: the same file holds [gateway].paired_tokens.
_AUTONOMY_SCALARS = ("level", "auto_approve")
_NOTABLE_EXCLUDED = ("shell", "file_write", "file_edit", "browser", "git_operations")


def _assistant_config_path() -> Path:
    ostler_dir = Path(os.environ.get("OSTLER_DIR") or (Path.home() / ".ostler"))
    return ostler_dir / "assistant-config" / "config.toml"


def _stored_autonomy() -> tuple[dict[str, str], list[str]] | None:
    """({level, auto_approve} as written, excluded tool names), or None when the
    config is unreadable. An absent [autonomy] table gives ({}, [])."""
    path = _assistant_config_path()
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        _note_read(f"read {_tilde(path)} -> absent")
        return {}, []
    except OSError as exc:
        _note_failure(f"read {_tilde(path)} -> unreadable ({type(exc).__name__})")
        return None
    _note_read(f"read {_tilde(path)} -> ok")
    scalars: dict[str, str] = {}
    excluded: list[str] = []
    in_table = False
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("["):
            in_table = line.rstrip().startswith("[autonomy]")
            continue
        if not in_table or "=" not in line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        key, value = key.strip(), value.strip()
        if key in _AUTONOMY_SCALARS:
            scalars[key] = value.strip("\"'")[:60]
        elif key == "non_cli_excluded_tools":
            excluded = [t for t in re.findall(r'"([a-z_]+)"', value)]
    return scalars, excluded


def _autonomy_section() -> list[str]:
    """What the owner has confirmed or corrected, and the stored limits.

    Confirmed: pwg:PersonFact factSource "user_asserted" (the same rows as
    "Confirmed by you", counted). Corrected: /api/v1/memory facts with
    corrected == true (ical-server api_memory_list; the route returns at most
    MEMORY_LIMIT facts and hides ones the owner asked to forget, so this is a
    floor). Limits: the [autonomy] table of the assistant config. Nothing here
    is a rule the digest made up; with no stored setting it says so.
    """
    lines: list[str] = []
    rows = _sparql_select(
        f"PREFIX pwg: <{PWG_NS}>\n"
        "SELECT (COUNT(DISTINCT ?f) AS ?n) WHERE {\n"
        '  ?f a pwg:PersonFact ; pwg:factSource "user_asserted" .\n'
        "  OPTIONAL { ?f pwg:privacyLevel ?l }\n"
        '  FILTER(!BOUND(?l) || UCASE(STR(?l)) != "L3")\n'
        "  FILTER NOT EXISTS { ?f pwg:validTo ?end }\n"
        "}"
    )
    confirmed = 0
    if rows:
        try:
            confirmed = int(float(rows[0].get("n", 0)))
        except (TypeError, ValueError):
            confirmed = 0
    mem = _get_json("/api/v1/memory")
    corrected = 0
    if isinstance(mem, dict) and isinstance(mem.get("facts"), list):
        corrected = sum(1 for f in mem["facts"]
                        if isinstance(f, dict) and f.get("corrected") is True
                        and not _is_withheld(f))
    if confirmed or corrected:
        lines.append(f"- The owner has confirmed {confirmed} fact(s) and corrected "
                     f"{corrected} (at least). Confirmed facts are listed "
                     "above and override anything inferred.")
    stored = _stored_autonomy()
    if stored is not None:
        scalars, excluded = stored
        for key in _AUTONOMY_SCALARS:
            if key in scalars:
                lines.append(f"- Stored setting {key} = {scalars[key]}")
        if excluded:
            named = [t for t in _NOTABLE_EXCLUDED if t in excluded]
            lines.append(
                f"- Chat is configured without {len(excluded)} tools"
                + (f", including {', '.join(named)}" if named else "") + ".")
    if lines:
        lines.append("- No other permission is recorded here; an action not "
                     "covered above has no stored approval.")
    return lines


_CHANNEL_LABELS = {"linkedin_messaging": "LinkedIn messages"}


def _channel_style_section() -> list[str]:
    """How much the owner writes on each channel, as counts only.

    Source: pwg:RelationshipSignal pwg:signalType / pwg:userMessages /
    pwg:otherMessages (vendor/cm041/contact_syncer/linkedin_messages.py:184-189),
    summed per signalType, L3 dropped. userMessages is the owner's own sent
    count. No message text is read or stored by this section.

    GAP, stated in the section: the Hub stores no per-message length,
    formality, emoji or language measure for the owner on any channel (iMessage
    and WhatsApp read the owner's sent text at ingest, vendor/imessage_source/
    reader.py:60 and vendor/whatsapp_source/reader.py:77, and persist only
    utterances for the extractor, no style statistic), and only LinkedIn writes
    a sent/received split. So those descriptors are declared unmeasured.
    """
    rows = _sparql_select(
        f"PREFIX pwg: <{PWG_NS}>\n"
        "PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\n"
        "SELECT ?t (SUM(xsd:integer(?u)) AS ?sent) (SUM(xsd:integer(?o)) AS ?got)\n"
        "       (COUNT(DISTINCT ?s) AS ?threads) WHERE {\n"
        "  ?s a pwg:RelationshipSignal ; pwg:signalType ?t ;\n"
        "     pwg:userMessages ?u ; pwg:otherMessages ?o .\n"
        "  OPTIONAL { ?s pwg:privacyLevel ?l }\n"
        '  FILTER(!BOUND(?l) || UCASE(STR(?l)) != "L3")\n'
        "} GROUP BY ?t ORDER BY DESC(?sent) LIMIT 8"
    )
    if not rows:
        return []

    def _int(v) -> int:
        try:
            return int(float(v))
        except (TypeError, ValueError):
            return 0

    out: list[str] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        sent, got, threads = _int(row.get("sent")), _int(row.get("got")), _int(row.get("threads"))
        if sent + got == 0:
            continue
        kind = re.sub(r"[^a-z_]", "", str(row.get("t") or "").lower()) or "other"
        label = _CHANNEL_LABELS.get(kind, kind.replace("_", " "))
        share = round(100 * sent / (sent + got))
        out.append(f"- {label}: the owner sent {sent}, received {got} "
                   f"({share}% yours) across {threads} thread(s)")
    if out:
        out.append("- Length, formality, emoji and language: not measured; "
                   "the Hub stores no such statistic for their messages.")
    return out


# ── Digest assembly ──────────────────────────────────────────────────────────


def _run_section(heading: str, builder) -> list[str]:
    """Run one section builder and record what it produced AND what refused it.

    The failure ledger is global and append-only, so the slice taken across the
    call is exactly the reads that failed inside this builder. Nothing is
    inferred: a section is marked unreadable only when a read performed while
    it ran recorded a failure with the status it actually observed.
    """
    before = len(_FAILURES)
    lines = builder()
    _SECTION_STATUS.append((heading, len(lines), _FAILURES[before:]))
    return lines


def _unreadable_and_empty_block() -> list[str]:
    """Declare, INSIDE the digest, every section that is empty or unreadable.

    THIS IS THE FIX FOR THE FABRICATED BRIEF, AND IT IS A DATA-PATH FIX.

    Every section of this digest renders only when it has content. A section
    whose source returned 401, 400 or nothing at all therefore looks, to the
    only consumer that matters, EXACTLY like a section whose source answered
    and held nothing. The difference was measured, named and carried -- into
    _FAILURES, the stderr report and the exit code. None of those three reach
    the model. The model is handed a document headed "Baseline awareness of the
    people, meetings and preferences that matter", told by the cron prompt to
    use only the facts in its context, and asked for three or four sentences
    about the day. Given a void where a section should be, it produces the most
    plausible thing, and the brief presents that as recall.

    That is not a prompt-tuning problem and it is not fixed by a firmer
    sentence in the prompt. The document is missing a fact it was holding all
    along, so the fact is put in the document. Three states, three renderings:

        items                -> the section renders, as before
        read OK, zero items  -> declared here as "nothing stored"
        read did not answer  -> declared here as "COULD NOT BE READ", with
                                the status that was actually observed

    POSITION: this block is emitted EARLY, before the content sections, on
    purpose. build_digest clips to MAX_CHARS from the END, so a block placed
    after the content would be the first thing a busy graph deletes, and the
    honesty would go missing on exactly the installs with the most to say.
    """
    gaps: list[str] = []
    for heading, count, failed in _SECTION_STATUS:
        if failed:
            observed = "; ".join(failed)
            gaps.append(f"- {heading}: COULD NOT BE READ ({observed})")
        elif count == 0:
            gaps.append(f"- {heading}: nothing stored.")
    if not gaps:
        return []

    out = [
        "## What is not in this digest",
        "",
        "These lines are the measured state of this digest. They are facts "
        "about what was read, not judgements about the person you assist.",
        "",
        "\"Nothing stored\" means the source answered and held nothing for "
        "that section. \"COULD NOT BE READ\" means the source did not answer, "
        "so this digest does not know either way. Treat that as UNKNOWN. It is "
        "not the same as empty and it is not the same as none.",
        "",
        "Do not fill either kind of gap. Do not offer an example, a typical "
        "case, an illustration or a phrase of the form \"places like\" in "
        "place of a stored fact. If you are asked about something only one of "
        "these sections could answer, say in one short sentence that you have "
        "nothing stored for it, or that you could not check it. Saying that is "
        "a complete and correct answer.",
        "",
    ]
    out.extend(gaps)
    out.append("")
    return out


def build_digest() -> str | None:
    """Assemble the CONTEXT.md body.

    Returns the markdown string when at least one section has real data, or
    None when no section produced anything, so the caller can leave any prior
    digest in place.

    Returning None says only "there is nothing to write". It does NOT say why,
    and it must never be read as "everything is fine": the per-section counts
    land in ``_SECTION_COUNTS`` and every source read lands in ``_READS`` /
    ``_FAILURES``, and those are what ``main`` reports and exits on.
    """
    _reset_measurements()

    # Each builder runs through _run_section so the digest can report three
    # states rather than two. The heading passed here is the one the reader
    # sees, so the gap declaration below names sections the way the document
    # names them and not by an internal key.
    about = _run_section("About you", _about_you_section)
    autonomy = _run_section("Autonomy calibration", _autonomy_section)
    user_asserted = _run_section("Confirmed by you", _user_asserted_section)
    routines = _run_section("Routines and priorities",
                            _routines_priorities_section)
    people = _run_section("People you interact with most", _people_section)
    tastes = _run_section("Tastes", _tastes_section)
    channel = _run_section("Channel style", _channel_style_section)
    recent = _run_section("Recent meetings (last 7 days)", _meetings_section)
    calendar_by_owner = _run_section(
        "Calendar events by owner", _calendar_by_owner_section)
    preferences = _run_section(
        "Preferences and things to keep in mind", _preferences_section)
    orgs = _run_section("Key organisations", _orgs_section)

    _SECTION_COUNTS.extend([
        ("about-you", len(about)),
        ("autonomy-calibration", len(autonomy)),
        ("confirmed-by-you", len(user_asserted)),
        ("routines-and-priorities", len(routines)),
        ("people", len(people)),
        ("tastes", len(tastes)),
        ("channel-style", len(channel)),
        ("recent-meetings", len(recent)),
        ("calendar-by-owner", len(calendar_by_owner)),
        ("preferences", len(preferences)),
        ("key-organisations", len(orgs)),
    ])

    if not (about or autonomy or user_asserted or routines or people or tastes
            or channel or recent or calendar_by_owner or preferences or orgs):
        return None

    # Content blocks in order of usefulness: (name, heading, intro, lines).
    # Order is the order they are rendered. When the digest is over MAX_CHARS
    # the LAST-listed blocks are dropped whole, one at a time, and the drop is
    # declared in the digest, rather than the tail being clipped mid-section.
    calendar_intro = (
        "Each item is labelled with WHOSE calendar it came from. Use only "
        "these facts; never merge two people's events, never reassign one "
        "person's trip to another, and do not invent flight numbers, "
        "routings, destinations or times. If an item is under another "
        "person's calendar, attribute it to that person, not to the "
        "person you assist."
    )
    blocks: list[tuple[str, str, str, list[str]]] = [
        ("About you", "About you", "", about),
        ("Autonomy calibration", "Autonomy calibration",
         "What the owner has confirmed or corrected, and the limits stored for "
         "them. Read from stored settings and confirmed facts only.", autonomy),
        ("Confirmed by you", "Confirmed by you",
         "Facts the person confirmed to you directly. Treat these as "
         "authoritative; they override anything inferred below.",
         user_asserted),
        ("Routines and priorities", "Routines and priorities", "", routines),
        ("People you interact with most", "People you interact with most",
         "", people),
        ("Tastes", "Tastes",
         "The owner's top stored preferences, with the profile's own score.", tastes),
        ("Channel style", "Channel style",
         "Counts of the owner's own sent messages per channel; no message text.",
         channel),
        ("Recent meetings (last 7 days)", "Recent meetings (last 7 days)",
         "", recent),
        ("Calendar events by owner", "Calendar events by owner",
         calendar_intro, calendar_by_owner),
        ("Preferences and things to keep in mind",
         "Preferences and things to keep in mind", "", preferences),
        ("Key organisations", "Key organisations", "", orgs),
    ]
    # NOTE: there is deliberately no "## Upcoming meetings" section. Future
    # calendar events are rendered only via "## Calendar events by owner",
    # which carries per-owner attribution and L3 fail-closed filtering. The old
    # un-attributed upcoming section leaked shared-calendar events as the
    # operator's own (BATCH1 #3 F1) and has been retired.

    # ONE ROUTE TO THE GRAPH, AND IT IS THE pwg_ TOOLS.
    #
    # This paragraph used to name a SECOND route: `http_request` against
    # http://127.0.0.1:8090/api/v1/people/*. It works, but it is invisible to
    # everything downstream that asks WHICH tool answered a turn:
    # assistant_answers_grounded grades a turn on whether a tool named pwg_*
    # ran, so a correct answer fetched this way scores memory_only; and the
    # daemon's consolidation gate keyed live-graph state on the same prefix, so
    # a count fetched this way was memorised as a durable fact. THIS FILE IS THE
    # COPY THAT SHIPS (ostler-assistant#394 carries the same edit upstream, but
    # the release tarball never carries scripts/).
    footer = [
        "## Looking something up",
        "",
        "For a specific person or detail not listed above, call the "
        "`pwg_people` tool with the person's name, or `pwg_person_timeline` "
        "for the user's full history with them. Do not fetch graph data over "
        "`http_request`: the pwg_ tools are the route to the graph.",
        "",
    ]

    def _render(omitted: list[str]) -> str:
        now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        out: list[str] = [
            "# Personal Context",
            "",
            "Baseline awareness of the people, meetings, and preferences that "
            "matter to the person you assist. Generated locally from their "
            "personal graph; treat it as background, not a transcript.",
            f"_Last updated: {now}._",
            "",
        ]
        # Before any content: what this digest does NOT hold, and which of
        # those gaps are "nothing there" versus "we could not look". Placed
        # here so a size clip, which cuts from the end, can never remove it.
        gaps = _unreadable_and_empty_block()
        if omitted:
            note = ("- Left out to fit the size cap (they hold data; ask with "
                    "the pwg_ tools): " + ", ".join(omitted) + ".")
            if gaps:
                gaps.insert(len(gaps) - 1, note)
            else:
                gaps = ["## What is not in this digest", "", note, ""]
        out.extend(gaps)
        for name, heading, intro, lines in blocks:
            if not lines or name in omitted:
                continue
            out.append(f"## {heading}")
            out.append("")
            if intro:
                out.append(intro)
                out.append("")
            out.extend(lines)
            out.append("")
        out.extend(footer)
        return "\n".join(out)

    omitted: list[str] = []
    digest = _render(omitted)
    droppable = [b[0] for b in reversed(blocks) if b[3] and b[0] != "About you"]
    while len(digest) > MAX_CHARS and droppable:
        omitted.insert(0, droppable.pop(0))
        digest = _render(omitted)

    # Last resort, only when every droppable section is already gone: clip on
    # a line boundary so we never inject a half-line.
    if len(digest) > MAX_CHARS:
        clipped = digest[:MAX_CHARS]
        nl = clipped.rfind("\n")
        if nl > 0:
            clipped = clipped[:nl]
        digest = clipped + "\n\n_(digest truncated to fit the prompt budget)_\n"

    return digest


def _measured_report() -> list[str]:
    """The run's measured outcome, line by line.

    Every line here is something this process OBSERVED. There is deliberately
    no sentence of the form "the server is probably down" or "the graph is
    empty" -- the message this replaced asserted exactly that pair of causes
    without measuring either, and both were false on the install where the
    digest had never once been produced.
    """
    filled = sum(1 for _, n in _SECTION_COUNTS if n > 0)
    total = len(_SECTION_COUNTS) or 6
    out = [
        f"generate_pwg_context: {filled} of {total} sections produced content.",
        f"generate_pwg_context:   {_token_provenance()}",
        "generate_pwg_context:   sections:",
    ]
    for name, count in _SECTION_COUNTS:
        out.append(f"generate_pwg_context:     {name}: {count} item(s)")
    out.append("generate_pwg_context:   source reads:")
    if _READS:
        for line in _READS:
            out.append(f"generate_pwg_context:     {line}")
    else:
        out.append(
            "generate_pwg_context:     (none recorded -- no source read was "
            "attempted in this run)"
        )
    if _FAILURES:
        out.append(
            f"generate_pwg_context:   {len(_FAILURES)} of {len(_READS)} "
            "source read(s) did not deliver data."
        )
    return out


STALE_BANNER_OPEN = "<!-- ostler:context-refresh-status -->"
STALE_BANNER_CLOSE = "<!-- /ostler:context-refresh-status -->"


def _strip_stale_banner(body: str) -> str:
    """Remove a previously stamped banner so stamps cannot accumulate.

    Idempotence matters here: this runs on a schedule, so a banner that
    appended rather than replaced would grow the digest by a paragraph an hour
    until the MAX_CHARS clip ate the customer's actual data.
    """
    start = body.find(STALE_BANNER_OPEN)
    if start == -1:
        return body
    end = body.find(STALE_BANNER_CLOSE, start)
    if end == -1:
        return body
    return body[:start] + body[end + len(STALE_BANNER_CLOSE):].lstrip("\n")


def _stamp_prior_digest_as_stale() -> bool:
    """Mark an EXISTING CONTEXT.md as not refreshed, in the file itself.

    Leaving the prior digest in place when nothing could be assembled is the
    right call and is not being changed: a stale digest beats no digest.
    Leaving it UNMARKED is the defect. The daemon injects this file verbatim
    into every system prompt, including the 09:00 brief the customer receives
    as a message on their phone, and the file opens by calling itself
    "Baseline awareness" with a Last updated stamp the reader has no reason to
    treat as old. So the one reader that can act on the difference is told, in
    the document it actually reads, rather than in a stderr line and an exit
    code that only launchd sees.

    Creates NOTHING when there is no prior digest. An absent CONTEXT.md on a
    box where no source answered is a state this repo's gates assert on
    purpose, and manufacturing a file here would be a fresh defect of the same
    family as the one being fixed.

    Returns True when an existing digest was stamped.
    """
    try:
        body = CONTEXT_PATH.read_text(encoding="utf-8")
    except OSError:
        return False

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    banner = [
        STALE_BANNER_OPEN,
        "> NOT REFRESHED. Every source was asked and none delivered data at "
        f"{now}, so everything below stands as it was at the Last updated "
        "stamp and may no longer be true.",
        ">",
        "> Do not present anything below as today's news, and do not fill the "
        "gap with an example, a typical case or an illustration. If you are "
        "asked about something only a fresh read could answer, say in one "
        "short sentence that you could not check it.",
        ">",
        "> What did not answer:",
    ]
    if _FAILURES:
        banner.extend(f"> - {line}" for line in _FAILURES)
    else:
        banner.append(
            "> - no read recorded a failure, and no section produced content."
        )
    banner.append(STALE_BANNER_CLOSE)
    banner.append("")

    stamped = "\n".join(banner) + "\n" + _strip_stale_banner(body).lstrip("\n")
    try:
        tmp_path = CONTEXT_PATH.with_suffix(".md.tmp")
        tmp_path.write_text(stamped, encoding="utf-8")
        os.replace(tmp_path, CONTEXT_PATH)
    except OSError:
        return False
    return True


def main() -> int:
    digest = build_digest()

    if digest is None:
        # Zero of eleven sections. The prior CONTEXT.md is left in place (a stale
        # digest beats none), but this is a FAILED run and the exit code says
        # so. It used to return 0, which is why nothing ever noticed that this
        # script had not produced a digest on a single install.
        for line in _measured_report():
            print(line, file=sys.stderr)
        stamped = _stamp_prior_digest_as_stale()
        if stamped:
            print(
                "generate_pwg_context: no digest assembled; the prior "
                "CONTEXT.md was kept and stamped NOT REFRESHED so the "
                "assistant is not told stale facts are current",
                file=sys.stderr,
            )
        else:
            print(
                "generate_pwg_context: no digest assembled; CONTEXT.md not "
                "written and no prior copy exists to stamp",
                file=sys.stderr,
            )
        return EXIT_NOTHING_PRODUCED

    try:
        WORKSPACE_DIR.mkdir(parents=True, exist_ok=True)
        tmp_path = CONTEXT_PATH.with_suffix(".md.tmp")
        tmp_path.write_text(digest, encoding="utf-8")
        # Atomic replace so a reader never sees a partial file.
        os.replace(tmp_path, CONTEXT_PATH)
    except OSError as exc:
        print(f"generate_pwg_context: failed to write digest: {exc}", file=sys.stderr)
        return EXIT_WRITE_FAILED

    print(f"generate_pwg_context: wrote {len(digest)} chars to {CONTEXT_PATH}")

    if _FAILURES:
        # A digest exists, so the assistant is not blind -- but it was built
        # from fewer sources than it asked for, and a partial digest that
        # reports success is the shape of the original defect.
        for line in _measured_report():
            print(line, file=sys.stderr)
        return EXIT_DEGRADED

    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
