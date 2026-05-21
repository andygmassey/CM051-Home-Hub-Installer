# Prompt 02 — Enrich: public + meeting (user in audience)

**Stage:** enrichment.
**Model:** large, but smaller-context is fine — most audience-
capture transcripts are monological presenter content.
**Output scope:** Tier-1 only. Neither Coaching nor Relationship
signals run — the user is a listener, not a participant in a
relationship sense.
**Precedence:** `_conventions.md`.

---

## What this conversation type is

The user is in the audience at a talk, panel, keynote, or broadcast.
The captured content is predominantly someone else speaking; the user
may interject with a question during Q&A or to a neighbour.

Examples:

- Attending a conference talk
- Watching a keynote live
- Listening to a podcast the user hasn't been invited onto
- Attending a public lecture or industry event
- Watching a film screening with Q&A

Treat this as **note-taking on what the user learned**, not as
conversation processing. The output reads like the user's own notes
from the event, not a meeting summary.

---

## Sections to produce (in order)

### `## Summary`

`### Event` (event name, venue/source, presenter/speaker names,
date), `### Location` (where the user was physically, since this
matters for Ostler context), then two-to-three-sentence narrative
of what the event was and what the user took from it.

### `## Key themes the speaker(s) presented`

`### Theme name` subheadings. Each covers the main arguments the
presenter made, with their supporting evidence or examples. Not
the user's commentary — what the speaker said.

### `## Notable quotes from the speaker(s)`

First-class section. 3-8 verbatim quotes attributed to the speaker
(never to the user). Each with one-line context.

### `## Points worth remembering`

The user's own takeaways, not the speaker's points. Bullet list:
- What struck the user as useful / novel / worth exploring later
- Connections to the user's own work
- Disagreements or scepticism

This is the section the assistant will retrieve from when the user says
"what did that conference talk last month teach me about X?"

### `## People and orgs encountered`

People the user met at the event (networking), speakers met or
encountered, organisations represented. One line per entry.

Separate from the speaker(s) listed in Summary — this section is
specifically about people the user physically interacted with
during the event (coffee break introductions, Q&A pre-chat, hallway
conversations that weren't substantive enough for their own
conversation_id).

### `## Follow-ups`

Things the user wants to do as a result of attending:
- Read the speaker's book
- Look up a concept
- Reach out to someone met there
- Apply a framework to their own project

Emit `reminders_candidates` for user-initiated follow-ups.

### `## Selected transcript (speaker content)`

Not full transcript. Trim to the substantive content from the
speaker(s). Skip intros, logistics, thank-yous, applause breaks, the
user's own questions during Q&A (those go in a separate `## User
questions` sub-section if any). Speaker-attribution per conventions,
redaction per policy.

If the audio was poor and transcript quality is low, note that in the
frontmatter (`transcript_quality: low`) and produce shorter selected
transcript.

---

## What this prompt does NOT produce

- No Decisions, Action items (only Follow-ups) — the user wasn't a
  participant in decision-making.
- No Communication dynamics — not relevant.
- No Relationship signals — handled by a different type if the user
  met specific people.

---

## Frontmatter

`classification.setting: public`, `classification.shape: meeting`.
`prompt_version: 02-public_audience@1.0`.

Extra frontmatter:
- `event_name`, `event_url`, `event_organiser`
- `speakers` array (the people who spoke, not the user)
- `recording_url` (if available — links back to source)
- `transcript_quality: good|medium|low`
