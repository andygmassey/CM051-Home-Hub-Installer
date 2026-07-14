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
  - Graceful. If the server is down or an endpoint errors, the prior
    CONTEXT.md is left untouched and the script exits 0 rather than crashing.
    A digest is only written when at least one section returned real data.

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
PWG_NS = "https://pwg.dev/ontology#"

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


# ── HTTP helper ──────────────────────────────────────────────────────────────


def _get_json(path: str) -> dict | None:
    """GET a JSON endpoint on the local ical-server.

    Returns the parsed object on success, or None on any failure (server down,
    timeout, non-200, malformed JSON). Never raises: callers treat None as
    "this section is unavailable" and the digest degrades gracefully.
    """
    url = f"{BASE_URL}{path}"
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_SECS) as resp:
            if resp.status != 200:
                return None
            raw = resp.read()
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, ValueError):
        return None
    try:
        parsed = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return None
    return parsed if isinstance(parsed, dict) else None


def _sparql_select(sparql: str) -> list[dict] | None:
    """Run a SPARQL SELECT on the local Oxigraph, return list of binding dicts.

    Mirrors the ical-server's own ``_sparql_select`` shape (one value per
    binding key) but degrades like ``_get_json``: returns None on any failure
    (store down, timeout, non-200, malformed JSON) so the section can be
    omitted without crashing the LaunchAgent. Never raises.
    """
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
                return None
            raw = resp.read()
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, ValueError):
        return None
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    bindings = data.get("results", {}).get("bindings", [])
    if not isinstance(bindings, list):
        return None
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
    None when nothing useful could be gathered (server down / empty graph), so
    the caller can leave any prior digest in place.
    """
    user_asserted = _user_asserted_section()
    people = _people_section()
    recent = _meetings_section()
    calendar_by_owner = _calendar_by_owner_section()
    preferences = _preferences_section()
    orgs = _orgs_section()

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


def main() -> int:
    digest = build_digest()
    if digest is None:
        # Server down or empty graph. Leave any prior CONTEXT.md untouched and
        # succeed quietly so the LaunchAgent does not flag a transient outage.
        print(
            "generate_pwg_context: no data available "
            "(ical-server down or empty graph); leaving CONTEXT.md unchanged",
            file=sys.stderr,
        )
        return 0

    try:
        WORKSPACE_DIR.mkdir(parents=True, exist_ok=True)
        tmp_path = CONTEXT_PATH.with_suffix(".md.tmp")
        tmp_path.write_text(digest, encoding="utf-8")
        # Atomic replace so a reader never sees a partial file.
        os.replace(tmp_path, CONTEXT_PATH)
    except OSError as exc:
        print(f"generate_pwg_context: failed to write digest: {exc}", file=sys.stderr)
        return 1

    print(f"generate_pwg_context: wrote {len(digest)} chars to {CONTEXT_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
