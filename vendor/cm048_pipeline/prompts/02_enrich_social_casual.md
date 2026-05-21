# Prompt 02 – Enrich: social + (one-on-one | group-convo)

**Stage:** enrichment (runs after classifier, before relationship /
fact extraction). Coach step is SKIPPED for social_casual.
**Model:** large. `qwen3.5:35b-a3b` on the Hub.
**Input:** full transcript + classifier output + metadata.
**Output:** single markdown document matching the structure below.
**Scope:** Tier-1 (conversation) content only, deliberately lighter
than the work variants. Relationship signals handled by the separate
`03_relationship_signal.md` prompt (social contexts are where
relationship signals are most useful).

**Precedence:** `_conventions.md` rules apply.

---

## What this conversation type is

Friendship or networking context, light stakes, catching-up energy.
Not business-driven though work topics often drift in. Examples:

- Coffee with a friend
- Dinner party conversation
- Dragon-boat team catch-up
- Drinks with an ex-colleague who's become a friend
- Casual networking at an event
- Meeting a new person via an introduction, getting to know each
  other

The user typically didn't have an explicit agenda and won't retroread
this looking for decisions. They'll retroread it to remember **who
said what**, **what was interesting**, and **to reconnect with how
the other person is**.

Stakes typically `low` or `medium`. High-stakes social conversations
(a breakup, a falling-out, a crisis call with a friend) should be
classified `social + one-on-one + high` and routed to a different
prompt (`02_enrich_social_high-stakes.md`, TBD) – this prompt is for
ordinary catching-up.

---

## Sections to produce (in order)

### `## Summary`

Open with a `### Participants` subsection (bullet list of who was
there, with role labels when obvious – `{user_name} (user)`,
`{other_name} (new acquaintance, ex-[company])`) and a `### Location`
subsection (human-readable rendering of the captured location –
`{venue_name}, {neighbourhood}` or `Remote – WhatsApp voice call`).

Then one to three sentences of narrative summary: who was caught up
with, what the broad texture was (warm / tense / rushed / meandering),
what came out if anything. No value judgement.

### `## Topics covered`

Single bulleted list, not organised into subheadings (too much for a
casual conversation). Each bullet captures a topic area that came up,
who raised it if relevant, and a line or two on what was said. Target:
5-10 bullets for a 30-minute chat, 8-15 for a 60-minute one.

Format:
- **Topic name.** What was said. Attribution when it matters.

Examples of good topic bullets (names here are just illustration):
- **[Other]'s upcoming talk.** [Other] is giving their first
  20-minute public talk tomorrow evening. Nervous, well-prepared.
  [User] encouraged attendance and may present an existing deck as a
  1-hour slot if useful.
- **The wearable coffee-table idea.** [User] revived a 3-year-old
  concept (touchscreen E-ink coffee-table) now that affordable
  E-ink panels have turned up. Target market: luxury retailers and
  members' clubs.

### `## Notable moments`

Zero to three items. Only include if something distinctive happened:
a memorable exchange, a revealing admission, a decision, a moment of
warmth or tension. If the conversation was routine pleasant
catching-up, `_Nothing specific._` is the right answer.

Format:
- Brief description, plus (optionally) a one-line quote if it was the
  moment.

### `## Commitments`

Things either party said they'd do, formally or informally. Much
lighter than work action items – often just "let's do this again
in a couple of weeks" or "I'll send you that link."

Format as a simple bullet list with `Owner: what, by when if stated`.
`_Nothing specific._` if neither party made any.

**Reminders integration (downstream).** Same as work one-on-one –
emit a `reminders_candidates` sidecar for any commitment where
`owner == {user_name}` so the ingest layer can push to the user's
Apple Reminders PWG list. Social commitments are often looser
("let's catch up in a few weeks") – include only when there's a
concrete action, not aspirational "we should do this again." The
noise floor for Reminders entries is higher than for the
conversation MD itself.

### `## People and places mentioned`

Bullet list of third parties and locations name-dropped during the
conversation. Useful for the wiki's cross-linking. Includes:

- People not present who came up in conversation (with one-line
  context: "Diana – mutual acquaintance, ex-ContactCo-R, looking for
  agency placements")
- Organisations mentioned (one line on what/why)
- Venues / locations mentioned

If nothing of note, `_Nothing specific._`.

### `## Cleaned transcript`

Same treatment as the work one-on-one prompt: speaker-labelled,
punctuated, filler-stripped, paragraph breaks on topic shift, time
markers preserved, redaction per conventions.

---

## What this prompt DOES NOT produce

Compared to `02_enrich_work_one-on-one.md`:

- **No Decisions section** – casual conversations don't normally
  produce decisions in the business sense. If they did, the
  classifier probably should have marked it `work` or higher
  stakes.
- **No Key insights section** – the "what's the big takeaway"
  framing is overkill for a coffee catch-up. Topics covered is
  sufficient.
- **No Next steps section** – commitments (above) is enough. A
  casual conversation rarely needs a planning surface.

The conversation MD is lighter by design. Downstream consumers
(wiki Person page, Ostler, assistant retrieval) don't lose anything –
relationship signals come from the separate relationship prompt and
will capture the interpersonal texture.

---

## Sensitivity-aware modifications

- `sensitivity.level = normal` or `personal`: default. Run all sections.
- `sensitivity.level = sensitive`: run all sections but redact
  liberally in the cleaned transcript. Topics covered stays
  structurally intact; specific content masked. **Consider whether
  this was misclassified** – casual social doesn't often contain
  genuinely sensitive content, so if the classifier flagged
  `sensitive` on a `social+casual` conversation, double-check and
  possibly escalate to the user for review.
- `sensitivity.level = highly-sensitive`: produce ONLY `## Summary`
  (2-3 sentences). Do NOT produce topics, notable moments,
  commitments, people/places, or cleaned transcript. Emit
  `review_required: true`.

---

## Output frontmatter

Same schema as `02_enrich_work_one-on-one.md` – see that prompt for
full field docs. Variant values for this type:

```yaml
---
conversation_id: {id}
classification:
  setting: social
  shape: {one-on-one|group-convo}
  stakes: {low|medium}
  suggested_type_slug: social_{shape}_{stakes}
sensitivity:
  level: {level}
  categories: []
participants: [...]        # same structure as work prompt
location: {...}            # same structure
prompt_version: 02-social_casual@1.0
locale: {locale}
redaction_policy_version: {policy_version}
enrichment_model: qwen3.5:35b-a3b
enrichment_completed_at: {iso8601}
retention_tier: {tier-2-decade or tier-3-years if stakes=low}
retention_score_inputs: {...}
related_conversation_ids: []
review_required: false
---
```

---

## Input the LLM receives

```
--- CLASSIFICATION ---
{classifier_json_output}

--- METADATA ---
Date: {date}
Source: {source}
Location: {location}
Participants: {participant_list}
Duration: {duration_minutes}m
User hint: {hint_or_none}

--- CONVENTIONS ---
{contents of _conventions.md}

--- TRANSCRIPT ---
{full_transcript}
```

---

## Why this prompt exists separately from work_one-on-one

Two reasons:

1. **Different reader expectations.** A work conversation is retroread
   for decisions and commitments. A social conversation is retroread
   for warmth and remembering what matters to the other person.
   Structure should match the reading.
2. **Different noise tolerance.** Work conversations reward
   thoroughness. Social conversations reward compression. A 30-page
   summary of a coffee chat is worse than useless – it buries the
   warmth in administrative structure.

The two prompts share conventions (see `_conventions.md`), share the
same cleaned-transcript treatment, and produce compatible frontmatter
– but their Tier-1 content differs in what it surfaces and at what
depth.
