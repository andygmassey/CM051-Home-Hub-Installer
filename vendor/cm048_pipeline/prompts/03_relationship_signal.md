# Prompt 03 — Relationship signal (per non-user participant)

**Stage:** after enrichment, before coaching. Runs once per non-user
participant — three participants means three independent invocations.
**Model:** medium-large. `qwen3.5:35b-a3b` on the Hub. Outputs
structured JSON, not markdown.
**Output scope:** Tier-2 (Person). Written to Oxigraph as
`pwg:RelationshipSignal` triples and rolled into that person's wiki
page by CM044.
**Precedence:** `_conventions.md`.

---

## When this prompt runs

Runs for `setting` in (`work`, `social`, `family`) when
`processing_depth == full`.

Does NOT run for:
- `public` (audience or presenter — audience is one-to-many, doesn't
  fit relationship model)
- `service` (transactional, not relational)
- Conversations where `sensitivity.level == highly-sensitive`

For a 3-participant work meeting (user + 2 others), this prompt
invokes twice — once with `target_participant = other_1`, once with
`target_participant = other_2`. Each invocation produces a signal
record for that one relationship.

---

## What this prompt produces

A single JSON object per invocation. No markdown, no narrative — just
the structured signal. Schema:

```json
{
  "target_participant": "alex_chen",
  "target_display_name": "Alex Chen",
  "observed_in": "2026-04-15_alex_chen_zoom",
  "observed_at": "2026-04-15T14:00:00+08:00",

  "warmth": {
    "score": "warm",
    "confidence": 0.9,
    "evidence": "Extended, relaxed exchange. Personal health anecdote from {user} early in call. No tension or wariness. First-name terms throughout."
  },

  "reciprocity": {
    "user_talk_share": 0.55,
    "other_talk_share": 0.45,
    "balance": "roughly_balanced",
    "confidence": 0.75,
    "evidence": "Rough estimate — {user} carried the PWG explanation section (~8 mins continuous), {other} drove client-work logistics discussion."
  },

  "energy": {
    "level": "high",
    "valence": "positive",
    "confidence": 0.85,
    "evidence": "Both parties engaged throughout. Laughter multiple times. {other} proactively suggested intros (Diana, vetting-committee friend)."
  },

  "power_dynamic": {
    "shape": "peer",
    "notes": "Some asymmetry around technical expertise (user deeper on AI/infra, other deeper on day-to-day consulting logistics). Neither party deferred overall.",
    "confidence": 0.8
  },

  "topics_of_interest_to_other": [
    {"topic": "CMS in the AI era", "salience": "strong"},
    {"topic": "Laravel framework migration", "salience": "strong"},
    {"topic": "innovation grant routes", "salience": "medium"},
    {"topic": "UK networking contacts", "salience": "medium"}
  ],

  "communication_style_observed": {
    "style_tags": ["collaborative", "practical", "question-driven"],
    "notes": "Asks short clarifying questions rather than monologuing. Pulls {user} back to practical implementation when talk drifts abstract."
  },

  "notable_moments": [
    "Delegated three active client projects ({project_A}, {project_B}, {project_C}) during the call — consistent with a pattern {user} may already be tracking."
  ],

  "trust_and_rapport": {
    "signal": "stable_high",
    "confidence": 0.85,
    "notes": "No tests of trust in this conversation — but rapport is comfortable. {other} shared frustrations about the previous manager openly, consistent with prior conversations (per metadata)."
  },

  "initiative": {
    "who_initiated": "other",
    "who_suggested_next": "both",
    "follow_up_commitment": "Co-working session planned for tomorrow 9am.",
    "confidence": 0.9
  },

  "trajectory": {
    "warmth_shift": "stable",
    "notes": "Warmth was consistent throughout — no notable warming or cooling during the conversation."
  },

  "conversation_depth": {
    "level": "substantive",
    "evidence": "Covered active client projects, delegation decisions, new business opportunities, and personal project updates. Both parties shared professional challenges openly."
  },

  "relationship_category_hint": "work_friend",
  "overall_confidence": 0.82,

  "flags": {
    "reclassify_relationship_needed": false,
    "signal_too_weak_to_publish": false,
    "sensitive_content_present": false
  }
}
```

---

## Field definitions

### `warmth.score`

One of: `cold`, `cool`, `neutral`, `warm`, `very_warm`. Qualitative —
don't try to be numeric about emotional temperature.

### `reciprocity`

- `user_talk_share`: rough fraction of total spoken output attributed
  to the user. Estimate, not precise — don't try to be more accurate
  than to two decimal places.
- `balance`: one of `other_dominant`, `roughly_balanced`,
  `user_dominant`.

### `energy.level`

One of: `low`, `medium`, `high`. Combined energy of both parties.

### `energy.valence`

One of: `negative`, `neutral`, `positive`. Tone of the energy.

### `power_dynamic.shape`

One of: `other_leads`, `peer`, `user_leads`, `shifting`. This is
about who's driving the conversation, NOT about hierarchical position
(though they often correlate).

### `topics_of_interest_to_other`

Topics the OTHER party cared about — what they raised, what they
returned to, what got their energy up. Up to 5 topics, each with
`salience` of `weak` / `medium` / `strong`. This is the most useful
field for the assistant's pre-meeting briefings ("before you see Sam, note
he's still focused on Laravel migrations and the CMS question").

### `communication_style_observed`

From a library of tags including: `collaborative`, `directive`,
`analytical`, `anecdotal`, `question-driven`, `story-driven`,
`interrupting`, `listening`, `jargon-heavy`, `accessible`,
`formal`, `informal`, `abstract`, `practical`, `cautious`, `decisive`.
Pick 1-4 that fit.

### `trust_and_rapport.signal`

One of:
- `new` -- this is an early-stage relationship, no strong signal yet
- `building` -- trust is growing
- `stable_low` -- guarded, cautious, transactional
- `stable_medium` -- working relationship, polite and functional
- `stable_high` -- comfortable, open, mutual regard
- `eroding` -- something has cooled
- `fragile` -- tension present, trust in question

### `initiative`

Tracks who drives the relationship forward:

- `who_initiated`: `user` | `other` | `unclear` -- who arranged /
  requested this conversation.
- `who_suggested_next`: `user` | `other` | `both` | `neither` -- who
  proposed a follow-up meeting or next step.
- `follow_up_commitment`: free text describing the next meeting or
  follow-up if one was agreed, or `null` if none.
- `confidence`: 0.0-1.0.

Over time, initiative patterns reveal who is investing more in the
relationship. If one side always initiates and the other never
suggests follow-up, that is a meaningful asymmetry the assistant can surface
in briefings.

### `trajectory`

Did the emotional temperature of the conversation change during it?

- `warmth_shift`: `warming` | `cooling` | `stable` | `mixed`.
  `warming` = started cool/neutral and ended warmer (e.g. a first
  meeting that found common ground). `cooling` = started warm and
  ended with tension or withdrawal. `stable` = consistent throughout.
  `mixed` = oscillated.
- `notes`: one sentence on what drove the shift, if any.

This is about within-conversation change, not the relationship
trend over time (which is computed by the accumulation layer from
multiple records).

### `conversation_depth`

How substantive was the exchange?

- `level`: `superficial` | `routine` | `substantive` | `deep`.
  `superficial` = small talk, logistics only. `routine` = normal
  work coordination. `substantive` = shared real opinions, discussed
  plans, exchanged useful information. `deep` = vulnerability,
  personal disclosure, difficult topics.
- `evidence`: one sentence grounding the assessment in specific
  transcript content.

This helps downstream distinguish between a 30-minute meeting where
nothing of substance was discussed and one where both parties were
genuinely engaged. A `deep` rating on a `social` conversation is
more signal-rich than a `routine` `work` check-in.

### `relationship_category_hint`

From: `stranger`, `acquaintance`, `colleague`, `work_friend`, `client`,
`vendor`, `manager`, `report`, `friend`, `close_friend`,
`family_member`, `partner`, `unknown`. Hint only — the actual
canonical relationship lives in the Person graph and may override.

### `overall_confidence`

0.0 to 1.0. Reflects how confident the LLM is in its overall read of
the relationship from this single conversation. Short conversations,
noisy transcripts, and first encounters produce lower confidence.

### `flags`

- `reclassify_relationship_needed`: if this conversation reveals the
  current Person-graph relationship label is wrong, flag for human
  review. E.g. the Person graph says `colleague` but this conversation
  reveals they're now `close_friend`.
- `signal_too_weak_to_publish`: overall_confidence < 0.5 — CM044 wiki
  compiler should not roll this signal into the Person page.
- `sensitive_content_present`: the conversation contained sensitive
  content that colours the relationship signal; downstream consumers
  should not publicly surface specifics.

---

## Evidence discipline

Every scored field has an `evidence` or `notes` sub-field. This
evidence MUST be grounded in the transcript. If the LLM cannot find
evidence, the confidence should drop and the field is populated with
a placeholder `unclear` value, not a fabricated one.

Good evidence: concrete behaviours observed in the transcript (`asked
3 clarifying questions in the first 10 minutes`, `paused for 4
seconds before disagreeing with the pricing point`).

Bad evidence: impressionistic summaries (`seemed friendly`, `felt
tense`) without concrete behaviour anchors.

---

## Accumulation

This prompt produces ONE record per conversation per target
participant. Over time, many records accumulate for the same person.
CM044 wiki compiler rolls them up into the Person page's
"Relationship" section with:

- Rolling-average warmth trend over last 10 conversations
- Rolling-average reciprocity
- Trust trajectory graph (stable / rising / falling)
- Topics that consistently surface (filtered across records)
- Communication-style patterns that repeat
- Last 3 notable moments

Low-confidence records (`overall_confidence < 0.5` or
`flags.signal_too_weak_to_publish == true`) are retained in Oxigraph
but excluded from the rollup.

---

## Input the LLM receives

```
--- CLASSIFICATION ---
{classifier_json_output}

--- METADATA ---
{conversation_metadata}
target_participant: alex_chen
target_display_name: Alex Chen
target_role_hint: other
prior_relationship_label: work_friend    # from Person graph, if any

--- CONVENTIONS ---
{contents of _conventions.md}

--- ENRICHED CONTENT (from 02_enrich_*) ---
{summary + topics + quotes + notable moments + cleaned transcript}
```

Receiving the enriched content (not just the raw transcript) lets
this prompt reason efficiently without re-reading the whole
transcript for the third or fourth time in the pipeline.

---

## Privacy and retention

Relationship signals carry:

```yaml
user_id: {user_id}
visibility: private                 # signals are never family:shared
                                    # by default — they're about how
                                    # the USER perceives the other,
                                    # which isn't the other's to share
retention_tier: tier-2-decade       # signals are small; keep them
retention_score_inputs:
  signal_density: {per-conversation signal density}
  centrality_refs:
    - person:{target_participant}
  fact_count: 0
  is_pinned: false
```

Signals about minors (`target.is_minor == true`) get
`visibility: private` enforced and `tier-1 forever` retention.
