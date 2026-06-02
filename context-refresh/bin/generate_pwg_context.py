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


def _is_withheld(record: dict) -> bool:
    """True when a record is marked private (L3) and must not be surfaced."""
    level = str(record.get("privacy_level") or record.get("level") or "").lower()
    return level in WITHHELD_PRIVACY_LEVELS


# ── Section builders ─────────────────────────────────────────────────────────


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


def _meetings_section() -> tuple[list[str], list[str]]:
    """Upcoming and recent meetings from the merged timeline.

    Returns (upcoming_lines, recent_lines). The timeline endpoint returns both
    calendar (future) and meeting (past) kinds.
    """
    data = _get_json("/api/v1/timeline?days=7")
    if not data:
        return ([], [])
    items = data.get("items")
    if not isinstance(items, list):
        return ([], [])

    upcoming: list[str] = []
    recent: list[str] = []
    for item in items:
        if not isinstance(item, dict) or _is_withheld(item):
            continue
        summary = (item.get("summary") or "").strip()
        if not summary:
            continue
        date = (item.get("date") or "").strip()
        kind = item.get("kind")
        label = f"- {summary}" + (f" ({date})" if date else "")
        if kind == "calendar" and len(upcoming) < MAX_MEETINGS:
            upcoming.append(label)
        elif kind == "meeting" and len(recent) < MAX_MEETINGS:
            recent.append(label)
    return (upcoming, recent)


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
    people = _people_section()
    upcoming, recent = _meetings_section()
    preferences = _preferences_section()
    orgs = _orgs_section()

    if not (people or upcoming or recent or preferences or orgs):
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

    if people:
        out.append("## People you interact with most")
        out.append("")
        out.extend(people)
        out.append("")

    if upcoming:
        out.append("## Upcoming meetings (next 7 days)")
        out.append("")
        out.extend(upcoming)
        out.append("")

    if recent:
        out.append("## Recent meetings (last 7 days)")
        out.append("")
        out.extend(recent)
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
