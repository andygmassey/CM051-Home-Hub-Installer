#!/usr/bin/env python3
"""Proactive "knows-me" meeting-prep brain (v1.0.1, task #669) -- PRODUCTISED.

Architecture A (Andy's decision): the brain NOTICEs an upcoming meeting,
PREFILTERs, JUDGEs whether it is worth a nudge, and -- when it fires -- hands the
DAEMON a nudge via POST /internal/nudge. The daemon owns the send path + is
authoritative over restraint (caps / quiet hours / dedup); the brain never sends
directly, which preserves the prototype's shadow-safety property.

This is the productised port of the founder prototype on the Mini
(~/projects/people-graph/: observer_loop.py / meeting_wow.py / person_brief.py).
Founder hardcodes (RECIPIENT, OWNER_NAME, IPs, paths) are env/config here.

IMPORTANT (honest note): the two-pass person_brief LLM PROMPT WORDING in this
file is a faithful-intent reconstruction from launch/BRIEF_proactive_nudge_daemon_v1.0.1.md,
NOT a byte-copy of the Mini prototype (the Mini was unreachable under the
no-auth-prompt constraint when this was written, 2026-06-11). Reconcile the exact
prompt text against the Mini prototype in an awake pass before shipping. The
control flow, judge, renderer, and daemon client below are complete + tested.

Flow per run:
  1. fetch upcoming meetings from ical-server (/api/v1/timeline or /calendar)
  2. for each, judge(): is it within the nudge lead-time window + has a named
     human counterpart + not already nudged?  (the daemon re-checks dedup/caps)
  3. resolve the person via /api/v1/people/context (identifiers + wiki_url)
  4. person_brief: two marvin passes -> durable facts + live "Last time, ..."
  5. render the block (wiki link + numbered actions) and POST /internal/nudge
     -- unless OSTLER_NUDGE_SHADOW=1, in which case log only (QA / first-run).
"""

from __future__ import annotations

import datetime as _dt
import json
import logging
import os
import urllib.request

log = logging.getLogger("nudge_brain")

# ── Config (env, conservative defaults) ──────────────────────────────────────
ICAL_BASE = os.environ.get("OSTLER_ICAL_BASE", "http://127.0.0.1:8089")
NUDGE_ENDPOINT = os.environ.get("OSTLER_NUDGE_ENDPOINT", "http://127.0.0.1:8000/internal/nudge")
OLLAMA_BASE = os.environ.get("OSTLER_OLLAMA_BASE", "http://127.0.0.1:11434")
BRAIN_MODEL = os.environ.get("OSTLER_NUDGE_MODEL", "qwen3.5:9b")
NUDGE_CHANNEL = os.environ.get("OSTLER_NUDGE_CHANNEL", "imessage")
OWNER_NAME = os.environ.get("OSTLER_OWNER_NAME", "")  # never hardcode a real name
SHADOW = os.environ.get("OSTLER_NUDGE_SHADOW", "0") in ("1", "true", "yes")

# Fire only when the meeting starts within [MIN, MAX] minutes from now: late
# enough to be actionable, early enough to be useful. ~90 min is the sweet spot.
LEAD_MIN_MINUTES = int(os.environ.get("OSTLER_NUDGE_LEAD_MIN", "30"))
LEAD_MAX_MINUTES = int(os.environ.get("OSTLER_NUDGE_LEAD_MAX", "120"))

# The three standard follow-up actions (index 0 == reply "1").
DEFAULT_ACTIONS = ["Draft an agenda", "Research them + their company", "Everything you've discussed"]


# ── Judge (pure, testable) ───────────────────────────────────────────────────
def minutes_until(start_iso: str, now: _dt.datetime) -> float | None:
    """Minutes from `now` until an ISO-8601 start time; None if unparseable."""
    try:
        start = _dt.datetime.fromisoformat(start_iso.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None
    if start.tzinfo is None:
        start = start.replace(tzinfo=_dt.timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=_dt.timezone.utc)
    return (start - now).total_seconds() / 60.0


def judge(meeting: dict, now: _dt.datetime) -> tuple[bool, str]:
    """Decide whether a meeting is nudge-worthy. Returns (fire, reason).

    The daemon re-enforces caps/quiet/dedup; this is the brain's PREFILTER:
    in the lead-time window AND has a resolvable human counterpart. Pure.
    """
    mins = minutes_until(meeting.get("start", ""), now)
    if mins is None:
        return False, "unparseable start time"
    if mins < LEAD_MIN_MINUTES:
        return False, f"too soon ({mins:.0f}m < {LEAD_MIN_MINUTES}m)"
    if mins > LEAD_MAX_MINUTES:
        return False, f"too far out ({mins:.0f}m > {LEAD_MAX_MINUTES}m)"
    if not (meeting.get("person_slug") or meeting.get("attendee")):
        return False, "no resolvable human counterpart"
    return True, f"in window ({mins:.0f}m out)"


# ── Block renderer (pure, testable) ──────────────────────────────────────────
def render_block(display_name: str, wiki_url: str | None, brief_lines: list[str]) -> str:
    """The nudge body sans the numbered actions (the daemon appends those).

    Mirrors the prototype's "wow block": who + a couple of durable facts + the
    live 'Last time, ...' line + a wiki deep link. Lines are pre-trimmed; empty
    lines dropped so a thin brief still reads cleanly.
    """
    out = [f"{display_name} in a bit." if display_name else "Coming up."]
    for line in brief_lines:
        line = (line or "").strip()
        if line:
            out.append(line)
    if wiki_url:
        out.append(f"More: {wiki_url}")
    return "\n".join(out)


# ── ical-server + ollama clients (thin; network) ─────────────────────────────
def _get_json(url: str, timeout: float = 8.0):
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 (loopback only)
        return json.loads(r.read().decode("utf-8"))


def _post_json(url: str, payload: dict, timeout: float = 30.0):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 (loopback only)
        return json.loads(r.read().decode("utf-8"))


def fetch_upcoming_meetings() -> list[dict]:
    try:
        data = _get_json(f"{ICAL_BASE}/api/v1/timeline")
    except Exception as e:  # noqa: BLE001 - best-effort brain, never crash the loop
        log.warning("could not fetch timeline: %s", e)
        return []
    items = data.get("events") or data.get("items") or data if isinstance(data, list) else data.get("events", [])
    return items if isinstance(items, list) else []


def get_person_context(slug: str) -> dict:
    try:
        return _get_json(f"{ICAL_BASE}/api/v1/people/context?slug={slug}")
    except Exception as e:  # noqa: BLE001
        log.warning("could not fetch person context for %s: %s", slug, e)
        return {}


def person_brief(display_name: str, context: dict) -> list[str]:
    """Two-pass marvin brief: durable facts, then the live 'Last time' line.

    NOTE: prompt wording is intent-faithful, not byte-identical to the Mini
    prototype (see module docstring). Returns [] on any failure -- a thin brief
    is acceptable; a crash is not.
    """
    # Pass 1: durable facts the user should remember about this person.
    facts_prompt = (
        f"In two short bullet points, what are the most useful durable facts "
        f"{OWNER_NAME or 'the user'} should remember about {display_name} before a meeting? "
        f"Context: {json.dumps(context)[:2000]}. Reply with the two bullets only, no preamble."
    )
    # Pass 2: the single 'Last time, ...' continuity line from recent contact.
    last_prompt = (
        f"In one short sentence beginning 'Last time,', summarise the most recent "
        f"interaction with {display_name} from this context: {json.dumps(context)[:2000]}. "
        f"If there is nothing recent, reply with an empty line."
    )
    lines: list[str] = []
    for prompt in (facts_prompt, last_prompt):
        text = _marvin(prompt)
        if text:
            lines.append(text)
    return lines


def _marvin(prompt: str) -> str:
    """One non-streaming, think:false generate against the local model."""
    try:
        resp = _post_json(
            f"{OLLAMA_BASE}/api/generate",
            {"model": BRAIN_MODEL, "prompt": prompt, "stream": False, "think": False},
        )
        return (resp.get("response") or "").strip()
    except Exception as e:  # noqa: BLE001
        log.warning("marvin generate failed: %s", e)
        return ""


def deliver(channel: str, to: str, message: str, person_slug: str, actions: list[str]) -> dict:
    """Hand the nudge to the daemon (or log it, in shadow mode)."""
    payload = {
        "channel": channel,
        "to": to,
        "message": message,
        "person_slug": person_slug,
        "actions": actions,
    }
    if SHADOW:
        log.info("SHADOW nudge (not sent): %s", json.dumps(payload))
        return {"delivered": False, "shadow": True}
    return _post_json(NUDGE_ENDPOINT, payload)


def run_once(now: _dt.datetime | None = None) -> int:
    """One pass over upcoming meetings. Returns the number of nudges handed off."""
    now = now or _dt.datetime.now(_dt.timezone.utc)
    fired = 0
    for meeting in fetch_upcoming_meetings():
        ok, reason = judge(meeting, now)
        if not ok:
            log.debug("skip %s: %s", meeting.get("title", "?"), reason)
            continue
        slug = meeting.get("person_slug") or ""
        ctx = get_person_context(slug) if slug else {}
        display = ctx.get("display_name") or meeting.get("attendee") or "your meeting"
        to = ctx.get("imessage") or ctx.get("phone") or meeting.get("to") or ""
        if not to:
            log.info("no contact handle for %s; skipping", display)
            continue
        brief = person_brief(display, ctx)
        body = render_block(display, ctx.get("wiki_url"), brief)
        try:
            res = deliver(NUDGE_CHANNEL, to, body, slug, DEFAULT_ACTIONS)
            if res.get("delivered") or res.get("shadow"):
                fired += 1
        except Exception as e:  # noqa: BLE001
            log.warning("deliver failed for %s: %s", display, e)
    return fired


if __name__ == "__main__":
    logging.basicConfig(level=os.environ.get("OSTLER_NUDGE_LOGLEVEL", "INFO"))
    n = run_once()
    log.info("nudge_brain run complete: %d nudge(s) handed to the daemon%s", n, " (shadow)" if SHADOW else "")
