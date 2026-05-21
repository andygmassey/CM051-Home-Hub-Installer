# Prompt 02 — Enrich: work + meeting

**Stage:** enrichment.
**Model:** large. `qwen3.5:35b-a3b` on the Hub.
**Output scope:** Tier-1 (conversation) content only. Relationship
signals, coaching, and fact extraction handled by later prompts.
**Precedence:** `_conventions.md`.

---

## What this conversation type is

Three or more participants, work context, agenda or semi-agenda
driven. Examples:

- Regular team stand-ups and working sessions
- Client kickoffs, vendor pitches, sales calls
- Board meetings, partners meetings, leadership off-sites
- Workshop facilitation, design reviews, project retrospectives

Distinguishing feature from `work + group-convo`: a meeting has an
agenda (explicit or implicit) and decisions expected. A group-convo is
3+ people talking about work without a decision-making frame.

---

## Sections to produce (in order)

### `## Summary`

Open with `### Participants` (list all with role — chair, presenter,
contributor, observer), `### Location`, `### Agenda` (if the
transcript makes the agenda discernible, either stated up-front or
inferable from topic sequence), then a two-to-four sentence narrative
of what the meeting was for and what came out.

### `## Key topics`

`### Topic name` subheadings as in `work_one-on-one`, but with an
added **Contributors:** line per topic listing who spoke meaningfully
on that topic. Topics are grouped thematically.

### `## Decisions`

Two subsections (`### Made`, `### Pending`). Decisions in a meeting
carry more weight than in a one-on-one — be thorough. Per decision:

- **Decision:** what was decided
- **Supported by:** who aligned (if distinguishable)
- **Raised concerns:** who pushed back and why (if anyone)
- **Context:** one line on why / what it unblocks

### `## Action items`

Same table format as `work_one-on-one` (Owner | Action | Deadline |
Priority | Notes). Meetings produce more action items per
participant — expect 3-8 total for a 60-minute meeting.

Emit `reminders_candidates` sidecar for items where
`owner == {user_name}`.

### `## Communication dynamics`

New section specific to meetings with 3+ participants. Bullet list
covering:

- Rough speaking distribution (e.g. "`{user_name}` ~40%, `{other_1}`
  ~30%, `{other_2}` ~20%, `{other_3}` ~10% — estimate, not precise")
- Who drove which topics (`{other_1}` drove the budget discussion;
  `{user_name}` drove the timeline question)
- Interaction patterns (collaborative / directive / analytical /
  combative / deferential)
- Who was quiet and might have had more to contribute
- Who dominated

This observational note goes into the conversation MD. The per-person
relationship signals with each individual are produced separately by
the `03_relationship_signal` prompt.

### `## Key quotes`

0-5 verbatim quotes, attributed. Same selection criteria as
`work_one-on-one`.

### `## Key insights`

2-5 meta-observations.

### `## Next steps`

`### Immediate (next 48 hours)` and `### Near-term (next 2 weeks)`.

### `## Cleaned transcript`

Per conventions. Multi-speaker sections get more paragraph breaks —
one per speaker turn, plus internal breaks on substantive topic shift
within a long turn.

---

## Frontmatter

Same schema as `02_enrich_work_one-on-one.md`. `participants` array
holds all attendees with their roles. `classification.shape` is
`meeting`. `prompt_version: 02-work_meeting@1.0`.

---

## Stakes modulation

- `low` (routine recurring stand-up): shorter Summary (2 sentences),
  Topics capped at 5, Decisions likely empty, Action items brisk.
- `medium` (normal project meeting): default depth.
- `high` (board meeting, crisis meeting, kickoff of major engagement):
  Summary fuller (4-5 sentences), topics thoroughly covered,
  Decisions section expected to be substantive, Action items owners
  explicit wherever possible.
