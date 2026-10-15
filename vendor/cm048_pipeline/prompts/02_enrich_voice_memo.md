# Prompt 02 – Enrich: a single-speaker capture (voice memo or note)

**Stage:** enrichment. Chosen by the PIPELINE, not by the classifier:
the capture has one speaker label and one participant, so it is a memo.
**Input:** transcript + classifier output + metadata.
**Output:** one markdown document matching the structure below.

**Precedence:** `_conventions.md` rules apply.

---

## What this capture is

One person speaking, recorded by themself: a voice memo, a dictated
note, a test recording, a reminder to self. There is NO second person
in the room or on a line.

Hard rules, because the pipeline checks them:

- Do NOT describe this as a call, meeting, chat or conversation between
  people. Nobody "caught up with" anybody.
- Do NOT invent a second participant, a relationship, a role, a company,
  a setting or a location. If the speaker greets or names someone, that
  person was ADDRESSED or MENTIONED, not present.
- Do NOT guess where the speaker was or what device they used.
- If the memo is a test, say so plainly ("A short test recording.").

---

## Sections to produce (in order)

### `## Summary`

One to three sentences, in the third person about the speaker or as a
plain description of the memo ("A short test recording checking whether
capture works."). No participants list, no location.

### `## Topics covered`

Bulleted list of what the speaker talked about. One bullet per topic.

### `## Commitments`

Anything the speaker said they would do, as bullets. If none, write
`_Nothing to report._`

### `## Cleaned transcript`

The transcript with filler words removed and obvious transcription
errors left as spoken (do not guess at words). Keep the single speaker
label exactly as it appears in the input.

---

## Output frontmatter

Start with a YAML frontmatter block. The pipeline overwrites every field
it knows (ids, model, timestamps, participants, location), so write only
what you read from the memo:

```yaml
---
sensitivity:
  level: normal
  categories: []
review_required: false
---
```

Then `## Summary`. No preamble.
