# Prompt 02 — Enrich: public + presentation (user speaking)

**Stage:** enrichment.
**Model:** large.
**Output scope:** Tier-1 only. Coaching runs for this type — public
speaking is a prime coaching surface. Relationship signals do NOT
run (one-to-many audience isn't a per-person relationship model).
**Precedence:** `_conventions.md`.

---

## What this conversation type is

The user is the speaker (or a speaker among a panel). Audience is
present but not individually tracked. Examples:

- Conference talks and keynotes
- Panel appearances (user is on the panel)
- Podcast appearances (user is the guest or co-host)
- Pitch meetings where the user is primary presenter
- Internal all-hands where the user is presenting
- Press interviews, radio/TV interviews

Distinguishing from `work + presentation + high` (a pitch to a small
room): `public + presentation` implies a broader audience — conference,
podcast, livestream, recording intended for distribution. Treat the
content as having a public-ish surface.

---

## Sections to produce (in order)

### `## Summary`

`### Event` (event name, venue, host/organiser, date), `### Participants`
(user + any co-panellists + identified moderator/interviewer by name),
`### Audience` (approximate size + character — "40-person meetup, mostly
frontend developers" or "live-streamed podcast, est. 5K listeners"),
then two-to-four-sentence narrative.

### `## Key themes presented`

`### Theme name` subheadings covering the main arcs the user
articulated. Each theme:

- Lead: the claim or argument the user made
- Supporting bullets: evidence, examples, stories, analogies used
- Counter-points acknowledged (if any)
- How it landed (audience reaction, questions received — per
  transcript, not inferred)

### `## Key quotes`

**First-class section for this type.** 3-8 verbatim quotes from the
user that are likely to be useful for downstream publication, deck
building, or future reference. Each quote carries a note on context
(`— responding to Q from audience about pricing`,
`— opening line`). Preserve the user's phrasing and cadence exactly.

### `## Q&A highlights`

If the event included audience questions, capture each notable Q+A
as a bullet:

- **Q** (paraphrased, attributed to audience if identifiable):
  `"question content"`
- **A** (user's answer, verbatim or near-verbatim): `"answer content"`
- Note: one-line observation on how the user handled it, if notable

### `## Delivery observations`

Terse notes on how the user delivered, for the Coach pass to consume.
Not full coaching content (that's in the separate coach prompt) — but
flags the coach should attend to:

- Pacing, filler frequency, audible nerves, moments of flow
- Structural strength/weakness (strong open, weak close, tangential
  middle)
- Audience engagement arc
- Use of data, stories, analogies, humour — ratio and effect

Keep this to 4-8 bullets. The coaching prompt synthesises these into
proper coaching content.

### `## Post-event commitments`

Bullet list of things the user promised an audience member, a host,
or a co-panellist. `"{user_name} said they'd send the deck to the moderator"` —
that sort of thing. Emit `reminders_candidates` for user-owned
items.

### `## Cleaned transcript`

Full presentation transcript with speaker labels and punctuation per
conventions. Preserve the user's speaking cadence — aggressive
filler-removal on a recorded public talk kills the human voice of it.
Be lighter than on private conversations.

---

## What this prompt does NOT produce

- No Decisions section — presentations don't make group decisions
  about the subject matter (though a presentation might trigger a
  follow-on decision, which shows up in Post-event commitments).
- No Next steps — commitments covers it.
- No per-audience-member relationship signals — one-to-many audience
  doesn't fit the relationship model.

---

## Frontmatter

`classification.setting: public`, `classification.shape: presentation`.
`prompt_version: 02-public_presentation@1.0`.

Extra frontmatter:
- `event_name`, `event_url` (if known), `event_organiser`
- `recording_url` (if there's a public recording)
- `is_live: true|false`
- `is_recorded: true|false`

Public presentations are prime candidates for sharing — downstream
consumers (wiki, portfolio, speaking history) will use these fields.
