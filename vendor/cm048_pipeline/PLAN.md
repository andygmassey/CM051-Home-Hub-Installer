# CM048 — Build Plan

**Goal:** ship a pipeline that takes a raw human-to-human conversation
transcript and produces the three-tier output described in
`CLAUDE.md`, good enough to be the canonical processing path for every
conversation the user has going forward.

**Test corpus:** the user's 3 conversations from 2026-04-15 + 2 from
previous days. These live in `tests/fixtures/` as markdown files with
frontmatter metadata. They're the acceptance bar.

---

## Phase A — Foundation (user reviews before Phase B starts)

**A.1 Classifier prompt draft.** One prompt, small-model friendly.
Inputs: transcript + participant list + (optional) known context type.
Outputs: `{setting, shape, stakes, confidence, reasoning}`.
- Deliverable: `prompts/01_classify.md`
- Review gate: user signs off on the taxonomy (3 axes + values) and
  the prompt's edge-case handling (what about "work drink in a social
  setting" — setting=social or work?). Worked example on the Alex Chen
  transcript.

**A.2 Per-type enrichment prompts.** One prompt per
`setting+shape` combination (stakes modulates depth, not structure).
- `prompts/02_enrich_work_meeting.md`
- `prompts/02_enrich_work_one-on-one.md`
- `prompts/02_enrich_work_group-convo.md`
- `prompts/02_enrich_social_casual.md`
- `prompts/02_enrich_social_networking.md`
- `prompts/02_enrich_family.md`
- `prompts/02_enrich_public_presentation.md`
- `prompts/02_enrich_public_audience.md`
- Review gate: user reviews two (work_one-on-one as the richest,
  social_casual as the lightest) and they serve as templates for the
  rest.

**A.3 Relationship-signal prompt.** Per-person, runs once per non-user
participant. Outputs structured RDF-ready JSON.
- Deliverable: `prompts/03_relationship_signal.md`
- Review gate: user confirms the axes (warmth / reciprocity / energy
  / power / topics-of-interest / notable moments), and the per-axis
  scale (qualitative vs numeric).

**A.4 Coaching prompt.** User-as-conversational-actor. Conditional on
classification.
- Deliverable: `prompts/04_coaching.md`
- Review gate: this is the most sensitive — user decides tone
  (`direct` vs `supportive` per-invocation, per the design decision),
  and whether the coach references prior conversations (Phase B
  pattern matching) or only the current one (simpler).

**A.5 Fact extraction prompt** (reuse-and-adapt from CM040).
- Deliverable: `prompts/05_fact_extraction.md`
- Review gate: minor — just confirm the fact schema matches what
  CM040 emits so Oxigraph + Qdrant consumers stay uniform.

**A.6 Speaker-label-feedback schema.** Not a prompt; a JSON schema for
the iOS feedback queue.
- Deliverable: `docs/speaker_label_feedback.schema.json`
- Review gate: skim for completeness.

Phase A output is entirely review-before-build. Zero code shipped. At
the end, the user either green-lights Phase B or asks for prompt
iteration.

---

## Phase B — Implementation

**B.1 `src/processor.py`** — orchestration entry point. Takes a
transcript + metadata, runs the pipeline steps, returns a structured
result. Pure Python, no side effects (doesn't write to storage yet).

**B.2 `src/ollama_client.py`** — thin Ollama client. Targets
Ollama by default (`http://localhost:11434`, configurable). Supports
classification-small-model + enrichment-large-model routing.

**B.3 `src/chunker.py`** — for conversations too long to fit in the
enrichment model's context. Chunks preserve speaker turn boundaries
and emit a 2-sentence overlap for coherence.

**B.4 `src/schemas.py`** — Pydantic models for every structured output
(Classification, EnrichedConversation, RelationshipSignal,
CoachObservation, FactExtraction, SpeakerLabelFeedback).

**B.5 `src/ingest.py`** — side-effect module. Writes:
- Conversation MD to `~/.pwg/conversations/`
- Qdrant points (chunks + facts) to `conversations` collection
- Oxigraph triples (relationship signals, facts, participant links)
- Coach observations to SQLite
- Speaker-label feedback to a queue file / API endpoint
- All writes idempotent (hash-keyed), safe to re-run

**B.6 Tests.** Each stage has a unit test against a fixture transcript.
End-to-end test runs the Alex Chen transcript through and asserts the
expected output tier shapes.

**B.7 Unified API endpoint.** `POST /api/v1/conversation/process` on
`ical-server.py` (Mac Mini, localhost:8089). Accepts transcript MD +
metadata, enqueues processing job, returns `{job_id, status}`. A
`GET /api/v1/conversation/status/{job_id}` endpoint returns progress
and final output paths.

**B.8 CM042 cleanup.** `ExtractionService.swift` deleted (or gutted
into a thin client that just POSTs to the new endpoint). Keeps CM042
as the pure capture surface.

---

## Phase B.5 — User settings consumers

Before Phase C wiring, CM048 needs to read three settings from the
user's PWG preferences store (schema TBD in a separate project — for
v1 a YAML file at `~/.pwg/settings.yaml` is fine):

- `locale` — e.g. `en-GB`, defaults to user's OS locale
- `redaction_policy` — per-category redaction levels (see
  `prompts/_conventions.md`)
- `coaching_tone` — `direct` | `supportive` | `configurable` (ask
  per-invocation)
- `work_geofence` — the user's work location(s) + "don't transcribe
  when here" toggle. CM048 doesn't enforce this; CM031/CM042 do at
  capture time. But CM048 should refuse to process a transcript that
  arrives tagged with `captured_at_work_geofenced_location: true` —
  defensive belt-and-braces.

**Deliverable:** `src/settings.py` — loads settings.yaml, provides a
typed accessor. Defaults when file missing.

## Phase C — Integration

**C.1 Wire CM042 to call the endpoint** on transcript finalisation.
Replace its in-app extraction call with an HTTP POST.

**C.2 Wire CM031 to call the endpoint** on iOS-side transcript
finalisation (same POST). Speaker-label feedback consumed by the
iOS app on next sync.

**C.2a Speaker-identity inference - BUILT (2026-06-18).** The `06_speaker_feedback`
step is no longer an empty placeholder. `processor._step_speaker_feedback`
now runs a real LLM pass (prompt `prompts/06_speaker_inference.md`) that,
for each generic "Speaker N" turn in the transcript, infers the most
likely real person from the dialogue context plus a candidate list
assembled from the request participants and the `pwg:Person` people
graph. It emits a schema-valid `SpeakerLabelFeedback`
(`docs/speaker_label_feedback.schema.json`): resolved speakers go in
`labels` with `apply_mode` derived from confidence (>=0.9 auto, >=0.7
suggest, else review_required); the rest go in `unresolved_labels`. This
is the producer half of the TEXT-only speaker-naming round-route
(HR015 `DESIGN_capture_ingest_and_speaker_identity.md` section 4). PRIVACY: no
voice embedding is read or emitted; each label only carries the opaque,
device-supplied `voice_fingerprint_ref`, which the step re-stamps from
the device's own metadata (the model cannot influence it). The Hub
serves this artefact over `GET /api/v1/conversation/{id}/speakers`
(CM041 ical-server + CM051 vendored twin); CM031 fetches it on
processing-complete and binds the confirmed name to the LOCAL voiceprint
via the ref. Tests: `tests/test_speaker_inference.py`.

**C.3 CM044 wiki compiler patches:**
- New section on Person pages: "Relationship signals" (rolled up from
  Oxigraph)
- New section on Person pages: "Recent conversations" (most recent
  N from Qdrant where participant is this person)
- New page: `User Coach` (or per-user: `Coach (Andy)`, `Coach
  ({partner})` when multi-user lands) — roll-up of `observations.db`,
  with frequency/trend per tag

**C.4 Marvin wiring:**
- `/people/context?name=X` (unified API) already exists — extend to
  include relationship-signals rollup
- New: `/coach/recent?days=7` — returns recent User-Coach
  observations
- Marvin system prompt includes "before responding to a
  person-mention, check `/people/context` — include warmth + last
  topic summary"

**C.5 Apple Reminders sync.**
- iOS-side component (lives in CM031) reads the
  `reminders_candidates` sidecar from each processed conversation
  where `owner == {user}` and creates entries in a dedicated
  `PWG` list inside the Reminders app.
- Dedicated list ensures automated items don't pollute the user's
  manually-entered todos.
- Syncs back: if the user marks a Reminder complete, CM048 updates
  the action-item status in Oxigraph so Marvin stops nagging.
- Respect iOS Reminders permissions — user must have granted
  Reminders access to the Companion app.

**C.6 Cross-conversation linking.**
- After enrichment, the orchestrator runs a Qdrant similarity
  search on the new conversation's summary + topics against
  the existing `conversations` collection.
- Top-N results (threshold on cosine similarity, e.g. >0.7) get
  written to the conversation's frontmatter `related_conversation_ids`.
- CM044 wiki compiler uses this to cross-link conversation pages.
- Graph edges (`pwg:relatedTo`) also emitted to Oxigraph for graph
  queries.
- Pure deterministic similarity search — no LLM involved. Runs as a
  fast post-enrichment step.

**C.7 Work-geofence coordination (with CM031 / CM042).**
- CM031/CM042 enforce the "don't capture at work" rule at capture
  time (the right place — if we never capture, we never process).
- CM048 defensively rejects any transcript tagged
  `captured_at_work_geofenced_location: true`, logs the rejection,
  notifies the user.
- Work address discovery: user enters it once in settings, OR
  CM031 offers a nudge after detecting 5+ weekdays at the same
  address during working hours.

---

## Phase D — Historic backfill (optional, after C)

- Import the user's 3 + 2 test fixtures as real production data (not
  just test data).
- Optionally: backfill any transcripts sitting in Evernote, Zo, or
  Obsidian wearable-memories.

---

## Phase E — Knowledge graph optimisation (after D, when graph is populated)

**Prerequisite:** 50+ conversations processed, Marvin actively querying
the graph for briefings and person context.

**E.1 Graph salience tuning ("memify").**
Inspired by Cognee's `memify()` concept (Apache 2.0, open source).
Run a periodic optimisation pass over the Oxigraph + Qdrant stores:

- **Strengthen frequently-traversed paths.** If Marvin's person-context
  queries consistently follow `conversation → participant → relationship
  signal → topic`, boost those edges' retrieval priority.
- **Decay stale edges.** Relationship signals from conversations >12
  months old with no subsequent interaction get lower salience; they're
  still there but don't dominate retrieval results.
- **Derive consolidated facts.** If 5+ conversations mention "Sam
  delegates implementation to others," consolidate from episodic
  (per-conversation) to semantic (a durable trait on Sam's person
  record). This is **memory consolidation** — the bridge between
  episodic and semantic memory (per Lilian Weng's agent memory
  taxonomy).
- **Auto-tune retrieval weights** based on actual query patterns from
  Marvin's logs — which person-context queries returned useful results
  vs. which ones the user ignored or re-queried differently.

**Inputs already available from day one:**
- `retention_score_inputs` on every stored item (signal_density,
  centrality_refs, fact_count, is_pinned)
- Marvin query logs (which endpoints called, which person IDs queried)
- Conversation frequency per person (from Oxigraph relationship signals)
- User pin/unpin actions

**Implementation options:**
- Use Cognee directly (`pip install cognee`, four-call API, pluggable
  backends including Qdrant) — evaluate whether it can sit alongside
  existing stores or would require migration.
- Build a simpler bespoke pass that reads `retention_score_inputs` +
  Marvin query logs and updates Qdrant payload weights + Oxigraph edge
  annotations. Less sophisticated but no new dependency.
- Hybrid: use Cognee for the graph intelligence, keep existing stores
  as the source of truth.

**E.2 Cross-conversation pattern detection.**
Build on Phase C.6 (similarity linking) to detect recurring themes
across conversations — e.g., "the user mentions PWG in 80% of work
conversations" or "trust with Sam has been trending upward over 6
months." Surface these as User Coach meta-observations.

---

## Backlog — ideas from competitive analysis (not yet phased)

**From Foundry / James Bedford Karpathy-vault implementation (2026-04-22 scan, see `HR015/.claude/.../reference_foundry_vault.md`):**

1. **The "Candidate" pattern.** Single-source facts are written into the
   graph immediately today. Foundry holds single-source themes as
   "Candidates" until a second source corroborates, then promotes to a
   confirmed concept. Add `candidate: bool` to `ExtractedFact` schema +
   a promotion step in `src/linker.py` that checks for matching
   subject+predicate from a different `conversation_id` and flips the
   flag. Big quality win on graph hygiene; low risk; ~2-3 hours of code +
   tests. Post-launch.

2. **"Prompts for [year]" per-concept questions.** Foundry compiles
   essay-shaped questions on each concept page where the concept
   intersects with the user's existing writing. Direct fit for Ostler's
   User Coach tier — coaching-as-questions instead of coaching-as-tips.
   Could be a new `07b_prompts_for_user.md` enrichment template that
   runs after fact extraction. Post-launch.

3. **Two-vault one-way rule (design call, not just code).** Foundry
   keeps user-written content fully separate from agent-written content;
   Claude can read the personal vault but not write to it. Ostler's
   wiki currently mixes the two surfaces. Worth a design pass on whether
   to mark agent-authored content visually or carve out a "your voice"
   read-only surface. Sunday whiteboard topic, not autonomous work.

**From Omi open-source repo (2026-04-16 scan):**

1. **Prompt caching for pipeline steps.** Omi caches static instruction
   prefixes across conversations so repeated runs skip re-encoding the
   prompt template. We should do the same — our 14 prompt templates are
   static per version; only the transcript/metadata changes. Ollama
   supports context caching; investigate whether we can keep the prompt
   prefix warm across runs. Estimated speedup: 20-40% on LLM call
   latency.

2. **Quality gates on fact extraction.** Omi's extraction prompts
   include explicit "better 0 than low-quality" thresholds. Add similar
   gates to `05_fact_extraction.md` — if confidence is below a
   threshold, emit nothing rather than a dubious fact. Better for graph
   hygiene downstream.

3. **Fact deduplication against existing graph.** When the same fact
   appears across multiple conversations (e.g., "Sam works at Firm
   Studio"), Omi deduplicates against existing graph nodes rather than
   storing duplicates. Relevant for Phase E (memify) and for the Qdrant
   upsert path in `src/ingest.py` — currently we deduplicate by
   deterministic ID per-conversation, but not across conversations.

4. **Omi wearable integration.** Their BLE protocol and iOS app are
   open source. Future path: fork their iOS app to route transcripts
   to CM048's API endpoint, or integrate their necklace BLE protocol
   directly into CM031 Companion. This makes the Omi necklace a
   capture device for PWG without their cloud in the middle.

---

## Design decisions (locked in 2026-04-16)

9. **Everything local. No cloud LLM routing.** Even for non-personal
   conversations. This is a core product principle, not a cost
   trade-off. The pipeline must work within the hardware the user has.
10. **Hardware-adaptive pipeline.** Different hardware profiles should
    get the best possible output without prompt rewrites. Adaptations
    are settings-level: model selection, step selection (skip coaching
    on social/low-stakes when constrained), chunk sizing for smaller
    context windows, output depth expectations. A `hardware_profile`
    setting in `settings.yaml` (e.g. `mac_mini_24gb`, `gaming_pc_12gb`)
    sets sensible defaults. Prompts stay the same across profiles —
    output quality scales with model capability, not prompt changes.
    This is a productisation concern, not blocking current work, but
    must not be forgotten.

## Design decisions (locked in 2026-04-15)

1. **3-axis classifier** (setting / shape / stakes) — approved.
2. **User Coach tone: configurable per-invocation** (`direct` vs
   `supportive`). Stored with each observation so user can A/B.
   Renamed from "Andy Coach" to "User Coach" for productisation.
3. **Relationship signal: per-conversation records with explicit
   `confidence` field.** Low-confidence filtered out of Person-page
   rollups.
4. **LLM budget acceptable** (~7 calls / 2-4min on gamingrig per
   work-meeting). Watch backlog growth; participate in hub-wide
   priority scheduling from day one.
5. **Bulletproof failure handling:** per-step state persistence,
   idempotent sinks, auto-retry once, manual retry CLI, state never
   deleted. See CLAUDE.md "Bulletproof processing" section for the
   full model.
6. **Sensitivity flag** on classifier output — separate from the 3
   axes (cross-cuts all settings). 4 levels (`normal` / `personal` /
   `sensitive` / `highly-sensitive`) + categories array. Drives
   privacy-level forcing, redaction in cleaned transcripts, Coach
   suppression on sensitive, `review_before_ingest` on highly-sensitive.
7. **Re-processing policy:** no automatic re-runs on prompt changes.
   Explicit CLI (`pwg-convo-reprocess`) only, defaulting to `deferred`
   priority (overnight), throttled one-at-a-time. `prompt_version`
   recorded per step output so re-runs can filter.
8. **Data retention participation** from day one. Every datum carries
   `retention_tier` + `retention_score_inputs`. See
   `HR015/DATA_RETENTION.md` for the cross-cutting spec.

Phase A kicks off now — A.1 complete, A.2 (enrichment prompts) in
progress.
