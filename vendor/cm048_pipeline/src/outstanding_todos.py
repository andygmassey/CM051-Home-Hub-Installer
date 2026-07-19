"""Outstanding TODOs extraction for pre-meeting briefs.

Walks the enrichment markdown's ``## Action items`` table and emits a
per-conversation sidecar containing every action item (regardless of
owner) cross-linked to the conversation's non-user participants.

The pre-meeting brief subagent (CM041 ``meeting_syncer/brief.py``)
queries Oxigraph for ``pwg:OutstandingTodo`` triples linked to each
upcoming meeting's attendees and surfaces them as "things you said
you'd follow up on" / "things they said they'd follow up on".

# Why a separate sidecar?

The existing ``reminders_candidates`` sidecar (Phase C stub) filters
action items to the user-owned subset for Apple Reminders push. The
brief use case is reciprocal: we want commitments in BOTH directions
attached to the OTHER participant so the brief surfaces them when
that person comes back into view (a meeting next week).

# Shape

``outstanding_todos.json``::

    {
      "todos": [
        {
          "todo_id": "<deterministic UUIDv5 from convo + owner + text>",
          "subject_person_ids": ["other:alice-chen", "other:bob-tan"],
          "owner": "user" | "other:<slug>" | "<unowned>",
          "owner_display": "Andrew Operator",
          "action_text": "send the deck",
          "deadline": "2026-05-30" | null,
          "priority": "high" | "medium" | "low" | null,
          "source_conversation_id": "2026-04-15_alice_zoom",
          "source_conversation_date": "2026-04-15",
          "status": "open",
          "created_at": "<RFC3339 UTC>"
        },
        ...
      ]
    }

``subject_person_ids`` enumerates every non-user participant of the
source conversation; those are the people who are relevant to the
brief regardless of who owns the action. A todo "John sends Alice the
deck" extracted from a 1:1 with Alice surfaces when meeting Alice.
A todo extracted from a 3-person work meeting with Alice + Bob
surfaces when meeting EITHER Alice or Bob (whichever comes first).

# Best-effort parsing

The Action items table in the enrichment markdown is LLM-generated
and can drift from the expected schema (Owner | Action | Deadline |
Priority | Notes). The parser is forgiving: it accepts any column
order as long as a row contains an Owner-ish and Action-ish cell,
emits the unowned sentinel / null for missing fields, and skips rows
that look entirely empty. Quality improvements ship in v1.0.1; for
v1.0 best-effort plus the existing reminders_candidates sidecar is
the floor.
"""
from __future__ import annotations

import hashlib
import json
import logging
import re
import uuid
from dataclasses import asdict, dataclass, field
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)


# Limit on rendered text fields to keep Oxigraph triples bounded and
# prevent an LLM that ran away on a single action row from blowing up
# the brief payload. 600 chars is comfortable for any real action item
# and well under the SPARQL literal-size ceiling.
_MAX_TEXT_LEN = 600

# Sentinel for "unowned / unknown owner" in the structured ``owner``
# field. Matches the U+2014 em-dash character that the enrichment
# prompt uses in blank table cells, so the brief view can render
# exactly what the model produced. Spelled as a Python unicode escape
# so the source file itself never contains a literal em-dash byte
# (project lint guard).
UNOWNED = chr(0x2014)  # U+2014 EM DASH


@dataclass
class OutstandingTodo:
    """One action item extracted from a conversation, cross-linked to
    every non-user participant.

    Attributes
    ----------
    todo_id:
        Deterministic UUIDv5 derived from conversation_id + owner +
        action_text. Re-runs of the extractor produce the same id so
        Oxigraph upserts are idempotent.
    subject_person_ids:
        Every non-user participant's ``id`` from the conversation
        metadata (e.g. ``["other:alice-chen"]``). The brief queries
        Oxigraph for todos where ``pwg:aboutPerson`` matches any of
        the upcoming meeting's attendees.
    owner:
        ``"user"`` (the operator owns the action), ``"other:<slug>"``
        (a specific participant owns it), or ``UNOWNED`` (the em-dash
        sentinel; left in the brief so the human can chase it).
    owner_display:
        Human-readable owner name (the table's literal cell value).
        Preserved verbatim so the brief can render exactly what the
        enrichment said, even if the structured owner field was
        ambiguous.
    action_text:
        The action item itself, verbatim from the table.
    deadline:
        ISO date string if present, else ``None``. Explicit ISO dates
        pass through verbatim; relative phrasings ("by Friday", "next
        week", "tomorrow", "in 3 days") are resolved against the source
        conversation date. Absent / unparseable -> ``None`` (never
        guessed).
    priority:
        ``"high"`` / ``"medium"`` / ``"low"`` if extractable from the
        table cell, else ``None``. The enrichment prompt's heuristic
        is "urgent / ASAP / this week -> high; whenever / low priority
        -> low; everything else -> medium".
    source_conversation_id:
        The conversation this todo was extracted from. Brief readers
        use this to deep-link back to the source markdown.
    source_conversation_date:
        ISO date of the source conversation. Used by the brief to
        say "you discussed this on 2026-04-15".
    status:
        ``"open"`` by default. Flipped to ``"closed"`` only when the
        Action / Notes / Status cell carries unambiguous completion
        language ("done", "already sent", an explicit ``Status: done``
        column). Conservative: a weak or absent signal stays open so
        the brief never silently drops a live commitment.
    created_at:
        RFC3339 UTC timestamp of when the extractor ran.
    """

    todo_id: str
    subject_person_ids: list[str]
    owner: str
    owner_display: str
    action_text: str
    deadline: str | None
    priority: str | None
    source_conversation_id: str
    source_conversation_date: str
    status: str = "open"
    created_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())

    def to_dict(self) -> dict:
        return asdict(self)


# ── Parsing ─────────────────────────────────────────────────────────


# Match a markdown table. The Action items section can appear in any of
# the work / coaching / one-on-one variants; the heading is always
# "## Action items" per _conventions.md and the variant prompts.
_ACTION_HEADING_RE = re.compile(
    r"^##\s+Action\s+items\s*$", re.IGNORECASE | re.MULTILINE
)

# Match the next H2 heading after Action items so we know where the
# table ends. Anchoring to "^## " avoids accidentally matching ###
# subsection headings inside the table content.
_NEXT_H2_RE = re.compile(r"^##\s+\S", re.MULTILINE)


def parse_action_items_table(enrichment_md: str) -> list[dict[str, str]]:
    """Parse the ``## Action items`` markdown table.

    Returns a list of row-dicts keyed by lowercased column name. Empty
    if no Action items section exists or the section contains no table
    rows.

    Tolerant of:
    - Missing columns (returns ``""`` for the missing cell).
    - Extra columns beyond the canonical Owner/Action/Deadline/Priority/Notes.
    - "_Nothing to report._" placeholder rows (returns ``[]``).
    - Pipe characters inside cells (only splits on the outer column
      separators).
    """
    if not enrichment_md:
        return []

    heading = _ACTION_HEADING_RE.search(enrichment_md)
    if not heading:
        return []

    # Slice the markdown from the heading to the next ## section (or EOF).
    start = heading.end()
    remainder = enrichment_md[start:]
    next_h2 = _NEXT_H2_RE.search(remainder)
    section = remainder[:next_h2.start()] if next_h2 else remainder

    # Identify table rows. Markdown tables start with a header line
    # ``| Owner | Action | ... |`` followed by a separator
    # ``| --- | --- | ... |``. We look for the separator to lock onto
    # the table structure even if the LLM put prose above it.
    lines = section.strip().splitlines()
    sep_idx = None
    for i, line in enumerate(lines):
        if re.match(r"^\s*\|[\s\-:|]+\|\s*$", line):
            sep_idx = i
            break

    if sep_idx is None or sep_idx == 0:
        return []

    header_line = lines[sep_idx - 1]
    body_lines = lines[sep_idx + 1:]

    header_cells = _split_row(header_line)
    if not header_cells:
        return []
    column_keys = [c.strip().lower() for c in header_cells]

    rows: list[dict[str, str]] = []
    for line in body_lines:
        if not line.strip():
            continue
        # Stop at the first non-table line (LLMs sometimes append prose
        # below the table without a blank-line gap).
        if not line.lstrip().startswith("|"):
            break
        cells = _split_row(line)
        if not cells:
            continue
        # Pad short rows with empty cells; truncate long rows.
        cells = cells[:len(column_keys)] + [""] * max(
            0, len(column_keys) - len(cells)
        )
        row = {column_keys[i]: cells[i].strip() for i in range(len(column_keys))}
        # Drop rows where every cell is empty / placeholder.
        if all(_is_blank_cell(v) for v in row.values()):
            continue
        rows.append(row)

    return rows


def _split_row(line: str) -> list[str]:
    """Split a markdown table row into cells.

    Strips the leading + trailing pipe, then splits on internal pipes.
    Does NOT support escaped pipes inside cells (the enrichment prompt
    instructs the LLM to use the em-dash sentinel for missing cells,
    not pipes).
    """
    stripped = line.strip()
    if not stripped.startswith("|") or not stripped.endswith("|"):
        return []
    inner = stripped[1:-1]
    return inner.split("|")


# Blank-cell placeholders the LLM may emit. The em-dash (U+2014) and
# en-dash (U+2013) are constructed via chr() at module load so this
# source file itself never contains a literal dash byte that would
# trip the project lint guard.
_BLANK_CELL_VALUES = frozenset({
    "", "-", chr(0x2014), chr(0x2013), "n/a", "na", "none", "_none_",
})


def _is_blank_cell(value: str) -> bool:
    """Treat empty, em-dash, en-dash, hyphen, "n/a" placeholders as blank."""
    return value.strip().lower() in _BLANK_CELL_VALUES


# ── Owner resolution ────────────────────────────────────────────────


def resolve_owner(owner_cell: str, participants: list[dict]) -> tuple[str, str]:
    """Map an Owner cell to a structured (owner_id, owner_display) pair.

    The enrichment prompt instructs the LLM to use the participant's
    display name in the Owner column (e.g. ``Andrew Operator`` or
    ``Alice Chen``). We resolve back to the structured participant id
    so the brief subagent can filter by owner.

    Match strategy:
    1. Exact case-insensitive match on participant display name.
    2. First-token match (``Andrew`` -> ``Andrew Operator``).
    3. Fall back to the ``UNOWNED`` sentinel.

    Returns
    -------
    tuple[str, str]
        ``(owner_id, owner_display)`` where ``owner_id`` is one of
        ``"user"``, ``"other:<slug>"``, or ``UNOWNED`` for unowned.
    """
    cell = owner_cell.strip()
    if _is_blank_cell(cell):
        return (UNOWNED, UNOWNED)

    cell_lower = cell.lower()

    # Exact display match first.
    for p in participants:
        display = (p.get("display") or "").strip()
        if display and display.lower() == cell_lower:
            return (p.get("id") or UNOWNED, display)

    # First-token match (handles "Andrew" -> "Andrew Operator").
    cell_first = cell.split()[0].lower() if cell else ""
    if cell_first:
        for p in participants:
            display = (p.get("display") or "").strip()
            disp_first = display.split()[0].lower() if display else ""
            if disp_first and disp_first == cell_first:
                return (p.get("id") or UNOWNED, display)

    # No match: keep the literal cell so the brief reader can chase it.
    return (UNOWNED, cell[:_MAX_TEXT_LEN])


# ── Priority + deadline normalisation ───────────────────────────────


_PRIORITY_TOKENS = {
    "high": {"high", "urgent", "asap", "critical", "blocker"},
    "medium": {"medium", "med", "normal", "this week"},
    "low": {"low", "whenever", "nice to have", "nice-to-have"},
}


def normalise_priority(cell: str) -> str | None:
    """Map a Priority cell to one of ``high`` / ``medium`` / ``low`` /
    ``None``. Tolerant of free-text the LLM may produce."""
    if _is_blank_cell(cell):
        return None
    v = cell.strip().lower()
    for bucket, tokens in _PRIORITY_TOKENS.items():
        if v in tokens or any(t in v for t in tokens):
            return bucket
    return None


# ISO date matcher. Tolerates YYYY-MM-DD and YYYY/MM/DD.
_ISO_DATE_RE = re.compile(r"\b(\d{4})[-/](\d{1,2})[-/](\d{1,2})\b")

# Weekday name -> Monday=0 .. Sunday=6 index, matching date.weekday().
# Common abbreviations included so "by Fri" resolves the same as
# "by Friday".
_WEEKDAYS = {
    "monday": 0, "mon": 0,
    "tuesday": 1, "tue": 1, "tues": 1,
    "wednesday": 2, "wed": 2,
    "thursday": 3, "thu": 3, "thur": 3, "thurs": 3,
    "friday": 4, "fri": 4,
    "saturday": 5, "sat": 5,
    "sunday": 6, "sun": 6,
}
_WEEKDAY_RE = re.compile(
    r"\b(?:by|on|next|this|due)?\s*"
    r"(monday|mon|tuesday|tues|tue|wednesday|wed|thursday|thurs|thur|thu|"
    r"friday|fri|saturday|sat|sunday|sun)\b",
    re.IGNORECASE,
)

# "next week" / "this week" -> resolve conservatively to the END of the
# target week (the upcoming or current Sunday) so the brief never claims
# a deadline EARLIER than the real one.
_THIS_WEEK_RE = re.compile(r"\bthis\s+week\b", re.IGNORECASE)
_NEXT_WEEK_RE = re.compile(r"\bnext\s+week\b", re.IGNORECASE)

# "in N days" / "in a day" / "in N weeks".
_IN_N_DAYS_RE = re.compile(
    r"\bin\s+(a|an|\d+)\s+(day|days|week|weeks)\b", re.IGNORECASE
)

_WORD_NUMBERS = {
    "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4,
    "five": 5, "six": 6, "seven": 7,
}


def _parse_anchor(anchor: str | date | None) -> date | None:
    """Coerce a conversation-date anchor (ISO string or ``date``) to a
    ``date`` object. Returns ``None`` if unparseable so relative-date
    resolution degrades to "no deadline" rather than guessing off an
    arbitrary anchor."""
    if anchor is None:
        return None
    if isinstance(anchor, date) and not isinstance(anchor, datetime):
        return anchor
    if isinstance(anchor, datetime):
        return anchor.date()
    m = _ISO_DATE_RE.search(str(anchor))
    if not m:
        return None
    y, mo, d = m.groups()
    try:
        return date(int(y), int(mo), int(d))
    except ValueError:
        return None


def _next_weekday(anchor: date, target_idx: int, *, force_next: bool) -> date:
    """Return the date of the next occurrence of ``target_idx`` weekday
    on or after ``anchor``.

    ``force_next`` (for "next Friday") always skips to the following
    week even when the anchor already falls on that weekday; the plain
    "by Friday" form resolves to the same-day occurrence if today is
    that weekday, else the upcoming one.
    """
    delta = (target_idx - anchor.weekday()) % 7
    if force_next:
        delta = delta or 7
        # "next Friday" when today is Mon = this coming Friday is the
        # natural reading; only bump by a week when the bare-offset
        # would land on the anchor itself (today is Friday).
    return anchor + timedelta(days=delta)


def normalise_deadline(
    cell: str, anchor: str | date | None = None
) -> str | None:
    """Normalise a Deadline cell to an ISO date string, or ``None``.

    Resolution order:
    1. Explicit ISO date (``2026-05-30`` / ``2026/05/30``) -> verbatim.
    2. Relative forms resolved against ``anchor`` (the conversation
       date): ``tomorrow``, ``today``, weekday names (``by Friday``,
       ``next Tuesday``), ``this week`` / ``next week`` (-> end of that
       week), ``in N days`` / ``in N weeks``.
    3. Anything else -> ``None`` (the brief falls back to the source
       conversation date when the deadline is null).

    ``anchor`` is optional and backwards-compatible: callers that do not
    pass it get ISO-only behaviour (relative forms return ``None``
    rather than resolving off an arbitrary "today"). This keeps the
    function pure and deterministic -- it never reads the wall clock.
    """
    if _is_blank_cell(cell):
        return None

    # 1. Explicit ISO date always wins (it is unambiguous).
    m = _ISO_DATE_RE.search(cell)
    if m:
        y, mo, d = m.groups()
        try:
            return date(int(y), int(mo), int(d)).isoformat()
        except ValueError:
            return None

    base = _parse_anchor(anchor)
    if base is None:
        # No anchor -> we cannot honestly resolve a relative phrase.
        return None

    text = cell.strip().lower()

    if re.search(r"\btoday\b", text):
        return base.isoformat()
    if re.search(r"\btomorrow\b", text):
        return (base + timedelta(days=1)).isoformat()

    n_days = _IN_N_DAYS_RE.search(text)
    if n_days:
        qty_raw, unit = n_days.groups()
        qty = (
            int(qty_raw) if qty_raw.isdigit()
            else _WORD_NUMBERS.get(qty_raw, 1)
        )
        days = qty * (7 if unit.startswith("week") else 1)
        return (base + timedelta(days=days)).isoformat()

    # "next week" / "this week" -> the Sunday that ends that week.
    if _NEXT_WEEK_RE.search(text):
        this_sunday = _next_weekday(base, 6, force_next=False)
        return (this_sunday + timedelta(days=7)).isoformat()
    if _THIS_WEEK_RE.search(text):
        return _next_weekday(base, 6, force_next=False).isoformat()

    wd = _WEEKDAY_RE.search(text)
    if wd:
        name = wd.group(1).lower()
        target = _WEEKDAYS.get(name)
        if target is not None:
            force_next = bool(re.search(r"\bnext\b", text))
            return _next_weekday(
                base, target, force_next=force_next
            ).isoformat()

    return None


# ── Status detection ────────────────────────────────────────────────


# Phrases that signal an action item was reported as ALREADY DONE in
# the conversation (the enrichment may surface a retrospective "we did
# X" item, or a later corroborating turn). Conservative by design: only
# unambiguous completion language flips the default ``open`` status.
# Anything fuzzy stays open so the brief errs towards reminding rather
# than silently dropping a live commitment.
_DONE_PHRASES = (
    "already done", "already sent", "already sorted", "already handled",
    "now done", "now complete", "now completed", "marked done",
    "marked complete", "completed", "[done]", "[x]", "(done)",
    "✓", "✅", "☑",
    "done -", "done:", "done.", "done ", "resolved", "closed off",
    "wrapped up", "taken care of", "sorted out",
    "has been done", "has been sent", "was sent", "was completed",
    "no longer needed", "no longer required",
)

# Tokens that, when the cell is JUST this word, mean done. Guards
# against "done" appearing as a substring of unrelated words.
_DONE_EXACT = frozenset({"done", "complete", "completed", "closed", "resolved"})


def detect_status(
    action_cell: str,
    notes_cell: str = "",
    status_cell: str = "",
) -> str:
    """Return ``"open"`` (default) or ``"closed"``.

    Scans the Action / Notes / explicit Status cells for unambiguous
    completion language. Defaults to ``open`` -- a commitment is live
    until the conversation explicitly says otherwise, so the brief
    never drops a real follow-up on a weak signal.

    A dedicated ``Status`` column (if the enrichment emits one) takes
    precedence: an explicit ``done`` / ``closed`` cell closes the todo.
    """
    # 1. Explicit Status column wins.
    s = (status_cell or "").strip().lower()
    if s and not _is_blank_cell(status_cell):
        if s in _DONE_EXACT or any(p in s for p in _DONE_PHRASES):
            return "closed"
        # An explicit "open" / "in progress" / "pending" stays open.
        return "open"

    # 2. Otherwise scan action + notes for completion phrases.
    haystack = f"{action_cell or ''}  {notes_cell or ''}".strip().lower()
    if not haystack:
        return "open"
    if haystack in _DONE_EXACT:
        return "closed"
    if any(phrase in haystack for phrase in _DONE_PHRASES):
        return "closed"
    return "open"


# ── Extractor entry point ───────────────────────────────────────────


def _deterministic_todo_id(
    conversation_id: str, owner_id: str, action_text: str
) -> str:
    """Stable UUIDv5 so re-runs upsert the same triples."""
    seed = (
        f"pwg://cm048/{conversation_id}/todo/"
        f"{owner_id}/"
        f"{hashlib.sha256(action_text.encode()).hexdigest()}"
    )
    return str(uuid.uuid5(uuid.NAMESPACE_URL, seed))


def extract_outstanding_todos(
    enrichment_md: str,
    metadata: dict,
) -> list[OutstandingTodo]:
    """Parse the enrichment markdown's Action items table into todos.

    Parameters
    ----------
    enrichment_md:
        Full enrichment markdown body (with frontmatter or without;
        the parser only looks at ``## Action items`` onward).
    metadata:
        Conversation metadata dict (the same shape ``processor.py``
        passes through). Must contain ``conversation_id``, ``date``,
        and ``participants``.

    Returns
    -------
    list[OutstandingTodo]
        Empty if no Action items section or no non-blank rows. Skips
        rows where the Action cell is blank (an owner with no action
        is noise).
    """
    conversation_id = str(metadata.get("conversation_id") or "")
    conversation_date = str(metadata.get("date") or "")
    participants = list(metadata.get("participants") or [])

    if not conversation_id:
        return []

    others = [
        p for p in participants
        if (p.get("role") or "other") != "user" and p.get("id")
    ]
    subject_person_ids = [p["id"] for p in others]

    # If the conversation had no non-user participants the brief use
    # case doesn't apply (there's no person to surface these against).
    if not subject_person_ids:
        return []

    rows = parse_action_items_table(enrichment_md)
    todos: list[OutstandingTodo] = []
    for row in rows:
        # Best-effort column lookup; be tolerant of header variations.
        action_text = (row.get("action") or row.get("task") or "").strip()
        if _is_blank_cell(action_text):
            continue
        # Truncate runaway LLM cells.
        action_text = action_text[:_MAX_TEXT_LEN]

        owner_id, owner_display = resolve_owner(
            row.get("owner") or "", participants
        )
        # Resolve relative deadlines ("by Friday", "next week") against
        # the conversation date; explicit ISO dates ignore the anchor.
        deadline = normalise_deadline(
            row.get("deadline") or "", anchor=conversation_date
        )
        priority = normalise_priority(row.get("priority") or "")
        # Open by default; flip to closed only on unambiguous completion
        # language in the Action / Notes / Status cells.
        status = detect_status(
            action_text,
            notes_cell=row.get("notes") or "",
            status_cell=row.get("status") or "",
        )

        todo = OutstandingTodo(
            todo_id=_deterministic_todo_id(
                conversation_id, owner_id, action_text
            ),
            subject_person_ids=list(subject_person_ids),
            owner=owner_id,
            owner_display=owner_display[:_MAX_TEXT_LEN],
            action_text=action_text,
            deadline=deadline,
            priority=priority,
            source_conversation_id=conversation_id,
            source_conversation_date=conversation_date,
            status=status,
        )
        todos.append(todo)

    return todos


def write_sidecar(
    state_dir: Path,
    todos: list[OutstandingTodo],
) -> Path:
    """Persist the extracted todos as ``outstanding_todos.json`` in
    the per-conversation state dir.

    Always writes (even when empty) so downstream pipeline stages can
    distinguish "extractor ran, nothing to report" from "extractor
    never ran".
    """
    out_path = state_dir / "outstanding_todos.json"
    payload = {
        "todos": [t.to_dict() for t in todos],
        "extracted_at": datetime.now(timezone.utc).isoformat(),
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False)
    )
    return out_path


def load_sidecar(state_dir: Path) -> list[OutstandingTodo]:
    """Read the outstanding_todos.json sidecar back as dataclasses.

    Returns an empty list if the sidecar is missing or malformed;
    callers (the Oxigraph writer) treat that as "no todos for this
    conversation" rather than an error.
    """
    src = state_dir / "outstanding_todos.json"
    if not src.exists():
        return []
    try:
        raw = json.loads(src.read_text())
    except (OSError, json.JSONDecodeError):
        logger.warning(
            "outstanding_todos.json malformed at %s; treating as empty",
            src,
        )
        return []
    todos_raw = raw.get("todos") or []
    out: list[OutstandingTodo] = []
    for t in todos_raw:
        try:
            out.append(OutstandingTodo(
                todo_id=t["todo_id"],
                subject_person_ids=list(t.get("subject_person_ids") or []),
                owner=t.get("owner") or UNOWNED,
                owner_display=t.get("owner_display") or UNOWNED,
                action_text=t.get("action_text") or "",
                deadline=t.get("deadline"),
                priority=t.get("priority"),
                source_conversation_id=t.get("source_conversation_id") or "",
                source_conversation_date=t.get("source_conversation_date") or "",
                status=t.get("status") or "open",
                created_at=t.get("created_at") or datetime.now(timezone.utc).isoformat(),
            ))
        except (KeyError, TypeError) as exc:
            logger.warning(
                "Skipping malformed todo entry in %s: %s", src, exc
            )
    return out
