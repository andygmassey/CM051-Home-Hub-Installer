# Prompt 02 — Enrich: work + group-convo

**Stage:** enrichment.
**Model:** large.
**Output scope:** Tier-1 only.
**Precedence:** `_conventions.md`.

---

## What this conversation type is

Three or more people, work-adjacent context, but NOT agenda-driven.
Examples:

- Informal work drink with colleagues
- Post-meeting debrief in the corridor
- Industry conference after-hours gathering
- Lunch with multiple colleagues / clients / peers
- Shared car/taxi journey with work contacts

Typically `stakes: low` or `medium`. If stakes escalate because a real
decision got made or a crisis emerged, consider reclassifying to
`work + meeting`.

---

## Sections to produce (in order)

### `## Summary`

`### Participants`, `### Location`, then two-to-three-sentence
narrative — what the gathering was, what texture it had, what came
out if anything.

### `## Topics covered`

Flat bulleted list (like `social_casual`), not organised into
subheadings. Each bullet: topic + brief content + contributor when
attribution matters. Target 5-10 bullets.

### `## Decisions`

Often empty in this conversation type — group-convos rarely produce
formal decisions. If something was agreed (a colleague promised to
send something, the group agreed to repeat the gathering), record it
lightly. `_Nothing to report._` is common and fine.

### `## Action items`

Usually a handful of loose commitments rather than a formal table.
Use the same table structure but expect most cells `—`. Emit
`reminders_candidates` for user-owned items.

### `## Notable moments`

0-3 distinctive moments: a revealing admission, a memorable exchange,
a warm connection, a tension point. One line each, quote when the
moment was the quote.

### `## People and orgs mentioned`

Bullet list of third parties and organisations that came up but
weren't present. One-line context per entry. Feeds the wiki's
cross-linking.

### `## Cleaned transcript`

Per conventions. Multi-speaker handling same as `work_meeting`.

---

## What this prompt does NOT produce

- No Key insights section — a work group-convo rarely warrants the
  "big takeaway" framing.
- No Next steps section — commitments + actions is enough.
- No Communication dynamics section — the atmosphere is informal
  enough that dominance/deference analysis would be overreach.
  Relationship signals per-person handled by the `03_relationship_signal`
  prompt as usual.

---

## Frontmatter

`classification.shape: group-convo`. `prompt_version:
02-work_group-convo@1.0`.
