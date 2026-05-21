# Prompt 02b — Merge multi-chunk enrichment outputs

**Stage:** enrichment post-processing (runs only when the transcript
was chunked into 2+ pieces by `chunker.py`).
**Model:** large. Same enrichment model (`qwen3.5:35b-a3b` on the Hub).
**Input:** the concatenated per-chunk enrichment outputs + original
classification + metadata.
**Output:** single unified markdown document matching the same section
structure as the per-type enrichment prompt that generated the chunks.
**Scope:** Tier-1 (conversation) only. Does not affect relationship
signals, coaching, or fact extraction — those run on the merged output.

**Precedence:** `_conventions.md` rules apply.

---

## When this runs

The orchestrator (`processor.py`) invokes per-type enrichment on each
chunk separately. When `len(chunks) > 1`, the per-chunk outputs are
joined with `---` delimiters and passed to this merge prompt. The
merge prompt produces one coherent document that looks identical to
what a single-chunk enrichment would have produced.

v1 of the pipeline concatenates chunks with delimiters and skips the
merge step. This prompt upgrades that to a proper re-synthesis.

---

## What the merge must do

1. **Deduplicate.** Each chunk's output has its own `## Summary`,
   `## Key topics`, `## Decisions`, etc. The merge combines them into
   one set of sections. Duplicate topics, action items, and quotes
   across chunks must be merged, not repeated.

2. **Reconcile conflicts.** If chunk 1's summary says "the meeting
   focused on X" and chunk 3 says "the primary topic was Y", the
   merged summary covers both — the conversation evolved.

3. **Preserve section structure.** The merged output must have exactly
   the same sections (in the same order) as the original enrichment
   prompt specified. No section may be dropped or added.

4. **Maintain frontmatter.** Use the frontmatter from chunk 1 (it has
   the canonical classification, participants, location). Update:
   - `enrichment_completed_at` → now
   - `retention_score_inputs.signal_density` → recalculate across the
     full conversation duration, not per-chunk
   - `prompt_version` → append `+merge@1.0`

5. **Respect sensitivity.** If any chunk flagged `review_required: true`,
   the merged output must also flag it. Use the highest sensitivity
   level observed across all chunks.

6. **Merge action items.** Combine all action-item tables into one.
   Deduplicate by (owner, action) — if the same item appears in
   multiple chunks (due to overlap), keep the most detailed version.
   Re-emit the `reminders_candidates` sidecar for the merged set.

7. **Merge quotes.** Select the best 3-5 quotes across all chunks.
   Don't exceed 5 even if individual chunks each had 5.

8. **Merge cleaned transcript.** Concatenate the per-chunk cleaned
   transcripts in order. The 2-sentence overlap between chunks means
   some speaker turns appear in both — deduplicate these by dropping
   the repeated turns from the start of chunk N+1 when they match the
   end of chunk N.

---

## Input the LLM receives

```
--- MERGE TASK ---
You are merging {chunk_count} enrichment outputs from a conversation
that was too long to process in a single pass. The chunks overlap by
approximately 2 speaker turns. Produce a single unified document.

--- CLASSIFICATION ---
{classifier_json_output}

--- METADATA ---
Date: {date}
Source: {source}
Location: {location}
Participants: {participant_list}
User name: {user_name}
Other name: {other_name}
Locale: {target_locale}
Redaction policy: {redaction_policy_summary}

--- CONVENTIONS ---
{contents of _conventions.md}

--- CHUNK 1 OF {chunk_count} ---
{chunk_1_enrichment_output}

--- CHUNK 2 OF {chunk_count} ---
{chunk_2_enrichment_output}

... (up to chunk N)
```

---

## Output

A single markdown document with YAML frontmatter, identical in
structure to what the per-type enrichment prompt would have produced
for this conversation type. The reader should not be able to tell that
the output was originally processed in chunks.

---

## Edge cases

- **2 chunks with minimal overlap:** straightforward merge. Most
  conversations fall here (80K-160K chars).
- **5+ chunks (very long recordings, 2+ hours):** the merge itself may
  approach context limits. If so, the orchestrator should run a
  two-level merge: merge chunks 1-3, merge chunks 4-6, then merge
  those two merged outputs. This prompt works recursively — it can
  merge already-merged outputs.
- **Chunk produced `_Nothing to report._` for a section:** drop that
  chunk's contribution to the section. If ALL chunks say nothing,
  the merged output also says `_Nothing to report._`.
- **Conflicting action items:** keep both with a note
  `(raised in two parts of the conversation)`.
