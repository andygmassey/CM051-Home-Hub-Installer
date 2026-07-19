# Prompt 02 — Enrich: work + one-on-one

**Stage:** enrichment (runs after classifier, before relationship /
coach / fact extraction).
**Model:** large. `qwen3.5:35b-a3b` on the Hub.
**Input:** full transcript + classifier output + metadata.
**Output:** single markdown document matching the structure below.
**Scope:** Tier-1 (conversation) content only. This prompt does NOT
produce relationship signals (handled by `03_relationship_signal.md`)
or coaching observations (handled by `04_coaching.md`) or structured
fact extractions (handled by `05_fact_extraction.md`). Separate
prompts keep each one focused.

**Precedence:** `_conventions.md` rules apply. Read those first if
you haven't.

---

## What this conversation type is

Two people, work context, substantive content. Examples:

- Reporting to a manager / being reported to
- Coaching a direct report
- Consulting call with a client or vendor
- Peer catch-up on shared work
- Kickoff for a new engagement
- Interview (either direction) — treat the interviewer's notes as the
  structured summary; treat the interviewee's responses as primary
  content

Stakes typically `medium` but can be `high` (coaching a struggling
report, difficult feedback, breakup from a client). Stakes modulates
depth, not structure — a `high`-stakes `work+one-on-one` gets longer
summaries and more thoroughly called-out decisions; a `low`-stakes
check-in gets terse ones.

---

## Sections to produce (in order)

### `## Summary`

Open with a `### Participants` subsection (an explicit bulleted list
of who was in the conversation, with role labels if obvious from
context – `{user_name} (user)`, `Alex Chen (colleague)` – and a `### Location`
subsection with the captured location metadata rendered human-readable
(`Remote (Zoom, user at home)` or `Riverside Cafe, Old Town`).

Then two to four sentences of factual, third-person summary. What was
the conversation for, what got discussed, what came out. No value
judgement.

Final structure of this section:

```
## Summary

### Participants
- {user_name} (user)
- Alex Chen (friend, fellow consultant)

### Location
Remote – Zoom call. User's GPS-inferred location: home.

### Narrative
Two to four sentences here.
```

### `## Key topics`

Each substantive topic as a `### Topic name` subheading with
bullets. Topics are grouped thematically, not chronologically. A
topic gets its own subsection only if it warrants more than a single
sentence of treatment. One-liner topics go in a final `### Other
topics discussed` bullet list.

Target: 3-6 topic subsections for a 30-minute conversation, 5-10 for
a 60-minute one. Don't pad; coverage is more important than
completeness.

Within a topic:

- Lead bullet: what the topic is about in one sentence.
- Following bullets: substantive points raised, decisions mooted,
  concerns expressed, evidence cited. Attribute when attribution
  matters (`{other_name} noted...`, `{user_name} pushed back...`),
  leave ambient observations unattributed.
- Nested bullets (one level only) for sub-points.

### `## Decisions`

Two subsections:

#### `### Made`

Bullet list of decisions that were actually concluded in the
conversation. Format: `**Decision:** what was decided. _Context:_ one
line on why / what it unblocks.` If none made, `_Nothing to report._`.

#### `### Pending`

Bullet list of decisions that were discussed but not concluded.
Format: `**Question:** what needs deciding. _Needs:_ what's missing
to decide (data, sign-off, another conversation, etc.).` If none
pending, `_Nothing to report._`.

### `## Action items`

Markdown table with columns: Owner | Action | Deadline | Priority |
Notes. Priority is inferred from language cues (`urgent`, `ASAP`,
`this week`, `whenever`, `low priority`). Use `—` when any cell is
unknown.

If the transcript contains committal phrases without a clear owner or
deadline ("someone should look at..."), infer conservatively:
owner = the person who raised it if context suggests they'll do it,
otherwise `—`; deadline `—`. Don't invent specifics.

**Reminders integration (downstream).** Action items where
`owner == {user_name}` are candidates for Apple Reminders sync via
a dedicated `PWG` list (the ingest layer handles this, not this
prompt). Emit a structured sidecar alongside the markdown so ingest
can create Reminders entries without re-parsing the table:

```yaml
reminders_candidates:
  - action: "Run price prediction extractor against Sarah's luxury resale DB"
    deadline: 2026-04-16
    priority: high
    source_conversation_id: {conversation_id}
  - ...
```

Include only actions where the user is the owner. Actions owned by
others stay in the conversation MD but are not synced to the user's
Reminders.

### `## Key quotes`

Between 0 and 5 notable verbatim quotes. Each on its own paragraph,
attributed like:

> "The quote itself, cleaned of filler but not paraphrased, preserving
> the speaker's voice." — Sam

Quotes should be selected because:
- They capture a perspective concisely that the summary cannot
- They're likely to be useful when retrieving this conversation later
  ("Sam said [X]")
- They reveal character, intent, or a distinctive turn of phrase

Don't include quotes just for length. Fewer, better quotes.

### `## Key insights`

Bullet list of the 2-5 most important takeaways a reader who skims
only this section should walk away with. These are meta-observations,
not repetitions of individual points.

Example phrasings that work:
- `The main tension is between [X] and [Y]; no resolution yet.`
- `{user_name} has committed to three client projects in parallel —
  capacity risk.`
- `{other_name}'s delegation pattern continues: they hand off
  implementation and keep the relationship management.`

If the conversation was truly routine and lacks insights worth
surfacing, `_Nothing to report._` is acceptable.

### `## Next steps`

Two subsections:

#### `### Immediate (next 48 hours)`

What happens in the next two days. Usually echoes the highest-priority
Action items, but phrased as "what now" rather than "who does what."

#### `### Near-term (next 2 weeks)`

What happens in the next fortnight. Scheduled meetings, planned
deliverables, follow-ups.

If either window is empty, `_Nothing scheduled._`.

### `## Cleaned transcript`

The full transcript, speaker-labelled with display names (not
`Speaker 1`), punctuated properly, with filler removed and
paragraph breaks inserted where the speaker shifts topic or takes a
substantive pause.

Rules for cleaning:

- **Preserve meaning and voice.** Don't paraphrase. Change punctuation,
  paragraphing, filler-word removal only. The reader should be able
  to hear the speaker's personality.
- **Filler words to remove:** `um`, `uh`, `er`, `like` (when used as
  filler — keep when used as comparator), `you know` (when used as
  filler), `sort of` (when meaningless), `basically` (when
  meaningless), repeated words ("the the"), false starts ("I was
  going to- I mean").
- **Don't remove:** pauses that carry meaning (`... well, I mean, yes`),
  tonal markers (`obviously`, `actually`), direct quotes of others,
  British idioms.
- **Time markers:** if the source transcript had `[00:15]` style
  timestamps, preserve them at the start of each speaker-turn.
- **Redaction:** per `_conventions.md`. `[redacted: amount]`,
  `[redacted: phone]`, etc.
- **Format:**
  ```
  **{user_display_name}**: [00:00] Cleaned paragraph. Second sentence of same turn.

  New paragraph of same turn if a clear topic shift within the turn.

  **{other_display_name}**: [01:30] Response starts here.
  ```

---

## Sensitivity-aware modifications

- `sensitivity.level = normal`: default. Run all sections.
- `sensitivity.level = personal`: default. All sections. Redaction
  per conventions if specific amounts/contacts mentioned.
- `sensitivity.level = sensitive`: still run all sections BUT:
  - `## Summary` avoids specific numbers, diagnoses, legal details
  - `## Key topics` preserves structure but masks specifics
  - `## Cleaned transcript` redacts liberally
  - `## Key quotes` drops any quote containing specific redactable
    items unless it's essential to the summary
- `sensitivity.level = highly-sensitive`: produce ONLY `## Summary`
  (2-3 sentences) and `## Next steps` (if any action-items the user
  clearly committed to). Do NOT produce topics, decisions, quotes,
  insights, or cleaned transcript. Emit `review_required: true` in
  the front matter.

---

## Output frontmatter

Every enrichment markdown starts with a YAML frontmatter block:

```yaml
---
conversation_id: 2026-04-15_alex_chen_zoom
classification:
  setting: work
  shape: one-on-one
  stakes: medium
  suggested_type_slug: work_one-on-one_medium
sensitivity:
  level: normal
  categories: []
participants:
  - id: user
    display: {user_display_name}
    role: user
  - id: alex_chen
    display: Alex Chen
    role: other
location:
  mode: remote              # remote | in-person
  source: zoom_call          # zoom_call | facetime | in-person | apple_watch | wearable | other
  user_gps:
    latitude: 51.5074
    longitude: -0.1278
    altitude_m: 34
    accuracy_m: 12
    captured_via: ios_companion   # ios_companion | macos_sync | inferred_ip | user_entry
  user_address: "Home"   # reverse-geocoded, null if unknown
  venue: null                         # business/venue name, null if not at one
  other_party_location: null          # when known for in-person
prompt_version: 02-work_one-on-one@1.0
locale: en-GB
redaction_policy_version: default@1.0
enrichment_model: qwen3.5:35b-a3b
enrichment_completed_at: 2026-04-15T15:45:00+08:00
retention_tier: tier-2-decade
retention_score_inputs:
  signal_density: 0.68
  centrality_refs:
    - person:alex_chen
    - topic:pwg
    - topic:marvin-tool-calling
    - org:contactco-f
  fact_count: 0             # populated by fact-extraction pass
  is_pinned: false
related_conversation_ids: []   # populated post-enrichment by similarity search
review_required: false
---
```

Then the `## Summary` heading begins. No preamble between frontmatter
and first heading.

**Notes on specific fields:**

- `location.user_gps` is captured at the moment of transcription by
  the iOS Companion app (in-person) or inferred from network
  metadata for remote calls. Reverse-geocoded to `user_address` and
  (if applicable) `venue` before reaching this prompt.
- `related_conversation_ids` is left empty by the enrichment LLM.
  The orchestrator populates it after enrichment via Qdrant
  similarity search on the summary + topics — separate, deterministic
  step; no LLM involvement needed here.
- `retention_score_inputs.centrality_refs` is derived from entity
  extraction (a later pipeline step). The enrichment LLM produces a
  first-pass list; the entity-extraction step refines it with
  canonical IDs from the Person Graph.

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

If the transcript exceeds the model's context window, the orchestrator
chunks it with 2-sentence overlap and this prompt is run per chunk;
then a reduce pass merges the per-chunk outputs using a separate
merge prompt (`02b_merge_chunks.md`, TBD).
