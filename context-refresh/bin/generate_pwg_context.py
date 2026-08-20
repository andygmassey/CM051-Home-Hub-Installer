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
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
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
MAX_PREFERENCES = 6
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

# Exit codes. The LaunchAgent's exit status is the only signal launchd and
# the Doctor get, so it has to carry the verdict rather than always saying
# "fine". Documented here because the wrapper and the plist both cite them.
EXIT_OK = 0                 # digest written, every source answered
EXIT_WRITE_FAILED = 1       # digest built but could not be written to disk
EXIT_NOTHING_PRODUCED = 2   # zero of six sections; no digest exists to write
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


def _reset_measurements() -> None:
    """Clear the measured-outcome ledgers. Called at the top of build_digest so
    a second call in one process reports that call, not the accumulated pair."""
    _READS.clear()
    _FAILURES.clear()
    _SECTION_COUNTS.clear()


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

    Oxigraph is unauthenticated on the Hub (measured 2026-08-18 on a v1.0.36
    install: a bare SPARQL POST to 127.0.0.1:7878/query returns 200), so no
    bearer is attached here. If that ever changes, this is the second site to
    teach about ``service_token()``.
    """
    label = "POST oxigraph /query"
    req = urllib.request.Request(
        OXIGRAPH_URL.rstrip("/") + "/query",
        data=sparql.encode("utf-8"),
        headers={
            "Content-Type": "application/sparql-query",
            "Accept": "application/sparql-results+json",
        },
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
        'SELECT ?text ?name ?rel ?created WHERE {{\n'
        '  ?f a pwg:PersonFact ;\n'
        '     pwg:factSource "user_asserted" ;\n'
        '     pwg:factText ?text .\n'
        '  OPTIONAL {{ ?f pwg:aboutPerson ?p .\n'
        '             OPTIONAL {{ ?p pwg:displayName ?name }}\n'
        '             OPTIONAL {{ ?p pwg:relationshipType ?rel }} }}\n'
        '  OPTIONAL {{ ?f pwg:createdAt ?created }}\n'
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
        if not isinstance(row, dict):
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


def _people_section() -> list[str]:
    """Recently-active people: name, role, last contact.

    Uses /api/v1/suggestions which already composes recent meetings (the
    people the customer actually interacts with). Falls back to nothing if the
    endpoint is unavailable.
    """
    data = _get_json("/api/v1/suggestions")
    if not data:
        return []
    contacts = data.get("recent_meetings") or data.get("follow_up") or []
    if not isinstance(contacts, list):
        return []

    lines: list[str] = []
    for c in contacts:
        if not isinstance(c, dict) or _is_withheld(c):
            continue
        name = (c.get("name") or "").strip()
        if not name:
            continue
        role = (c.get("role") or c.get("title") or "").strip()
        org = (c.get("organisation") or c.get("organization") or "").strip()
        last = (c.get("last_contact") or c.get("meeting_date") or "").strip()
        bits = [name]
        if role:
            bits.append(role)
        if org:
            bits.append(org)
        suffix = f" (last contact {last})" if last else ""
        lines.append(f"- {', '.join(bits)}{suffix}")
        if len(lines) >= MAX_PEOPLE:
            break
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
    if not data:
        return []
    items = data.get("items")
    if not isinstance(items, list):
        return []

    recent: list[str] = []
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
        if len(recent) < MAX_MEETINGS:
            recent.append(label)
    return recent


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
    )
    if not rows:
        return []

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
    data = _get_json("/api/v1/coach/recent?hours=336&limit=8")
    if not data:
        return []
    observations = data.get("observations")
    if not isinstance(observations, list):
        return []

    lines: list[str] = []
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
    """Key organisations, derived from the people the customer meets.

    The graph does not expose a dedicated "top orgs" endpoint, so we aggregate
    the organisations seen across recent meetings. This keeps the digest local
    and avoids a separate query.
    """
    data = _get_json("/api/v1/suggestions")
    if not data:
        return []
    pools = []
    for key in ("recent_meetings", "reconnect", "birthdays"):
        section = data.get(key)
        if isinstance(section, list):
            pools.extend(section)

    seen: list[str] = []
    for c in pools:
        if not isinstance(c, dict) or _is_withheld(c):
            continue
        org = (c.get("organisation") or c.get("organization") or "").strip()
        if org and org not in seen:
            seen.append(org)
        if len(seen) >= MAX_ORGS:
            break
    return [f"- {o}" for o in seen]


# ── Digest assembly ──────────────────────────────────────────────────────────


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

    user_asserted = _user_asserted_section()
    people = _people_section()
    recent = _meetings_section()
    calendar_by_owner = _calendar_by_owner_section()
    preferences = _preferences_section()
    orgs = _orgs_section()

    _SECTION_COUNTS.extend([
        ("confirmed-by-you", len(user_asserted)),
        ("people", len(people)),
        ("recent-meetings", len(recent)),
        ("calendar-by-owner", len(calendar_by_owner)),
        ("preferences", len(preferences)),
        ("key-organisations", len(orgs)),
    ])

    if not (user_asserted or people or recent
            or calendar_by_owner or preferences or orgs):
        return None

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    out: list[str] = []
    out.append("# Personal Context")
    out.append("")
    out.append(
        "Baseline awareness of the people, meetings, and preferences that "
        "matter to the person you assist. Generated locally from their "
        "personal graph; treat it as background, not a transcript."
    )
    out.append(f"_Last updated: {now}._")
    out.append("")

    # User-asserted facts are authoritative -- things the customer told the
    # assistant directly -- so they lead the digest, above anything mined or
    # derived from activity.
    if user_asserted:
        out.append("## Confirmed by you")
        out.append("")
        out.append(
            "Facts the person confirmed to you directly. Treat these as "
            "authoritative; they override anything inferred below."
        )
        out.append("")
        out.extend(user_asserted)
        out.append("")

    if people:
        out.append("## People you interact with most")
        out.append("")
        out.extend(people)
        out.append("")

    # NOTE: there is deliberately no "## Upcoming meetings" section. Future
    # calendar events are rendered only via "## Calendar events by owner"
    # below, which carries per-owner attribution and L3 fail-closed filtering.
    # The old un-attributed upcoming section leaked shared-calendar events as
    # the operator's own (BATCH1 #3 F1) and has been retired.
    if recent:
        out.append("## Recent meetings (last 7 days)")
        out.append("")
        out.extend(recent)
        out.append("")

    if calendar_by_owner:
        out.append("## Calendar events by owner")
        out.append("")
        out.append(
            "Each item is labelled with WHOSE calendar it came from. Use only "
            "these facts; never merge two people's events, never reassign one "
            "person's trip to another, and do not invent flight numbers, "
            "routings, destinations or times. If an item is under another "
            "person's calendar, attribute it to that person, not to the "
            "person you assist."
        )
        out.append("")
        out.extend(calendar_by_owner)
        out.append("")

    if preferences:
        out.append("## Preferences and things to keep in mind")
        out.append("")
        out.extend(preferences)
        out.append("")

    if orgs:
        out.append("## Key organisations")
        out.append("")
        out.extend(orgs)
        out.append("")

    out.append("## Looking something up")
    out.append("")
    out.append(
        "For a specific person or detail not listed above, you can fetch it "
        "live with the http_request tool against the local graph: "
        "`GET http://127.0.0.1:8090/api/v1/people/search?q=NAME` for a person, "
        "or `GET http://127.0.0.1:8090/api/v1/people/context?name=NAME` for "
        "their full context. These are local, read-only lookups."
    )
    out.append("")

    digest = "\n".join(out)

    # Enforce the size cap on a line boundary so we never inject a half-line.
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


def main() -> int:
    digest = build_digest()

    if digest is None:
        # Zero of six sections. The prior CONTEXT.md is left in place (a stale
        # digest beats none), but this is a FAILED run and the exit code says
        # so. It used to return 0, which is why nothing ever noticed that this
        # script had not produced a digest on a single install.
        for line in _measured_report():
            print(line, file=sys.stderr)
        print(
            "generate_pwg_context: no digest assembled; CONTEXT.md not "
            "written and any prior copy left unchanged",
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
