# Prompt 04 — User Coach observation

**Stage:** after enrichment + relationship signal. Runs conditionally
based on classification.
**Model:** medium-large. `qwen3.5:35b-a3b`.
**Output scope:** Tier-3 (User Coach). Written to
`~/.pwg/coach/observations.db` (SQLite) and rolled up into the User
Coach wiki page by CM044.
**Precedence:** `_conventions.md`.

---

## When this prompt runs

Conditional on classification. Runs for:
- `work + one-on-one` (any stakes)
- `work + meeting` (stakes `medium` or `high`)
- `work + presentation` / `public + presentation` (user speaking — prime
  coaching surface)
- `social + one-on-one + high` (difficult conversations, coaching
  sessions where user is the client)

Does NOT run for:
- `family` (off-limits — family conversations aren't a coaching
  surface)
- `social + *` except the explicit high-stakes case above
- `public + meeting` (user in audience, not speaking)
- `service` (transactional)
- Any `sensitivity.level == sensitive` or `highly-sensitive`

When in doubt, SKIP. Better to miss a coaching opportunity than to
produce unwelcome coaching on sensitive content.

---

## Configurable tone

The user sets `coaching_tone` in their PWG preferences, OR overrides
per-invocation. Values:

- `direct` — honest, unvarnished. "You talked 65% of the time in a
  call meant to draw Sam out. That's higher than your 10-conversation
  baseline of 52%. Work on pausing after making a point and letting
  silence do the asking."
- `supportive` — noticing-and-reframing. "You brought strong energy
  and shared a lot of context about the PWG work. In a conversation
  where Sam was looking for advice on his own projects, pausing to
  draw him out further might have surfaced more of what he needed
  from you."
- `configurable` — prompt asks per-invocation. Useful when the user
  wants to toggle mood-by-mood. Fallback to `supportive` if not
  answered within a short window.

Tone applies to the **narrative** sections of the output (`What you
did well`, `What to work on`, `Tip`). The structured observation
metadata (tags, severity, pattern refs) is tone-agnostic.

---

## What this prompt produces

Single JSON object. Schema:

```json
{
  "observation_id": "{uuid}",
  "conversation_id": "2026-04-15_alex_chen_zoom",
  "observed_at": "2026-04-15T14:00:00+08:00",
  "conversation_type": "work_one-on-one_medium",
  "tone": "supportive",

  "what_went_well": [
    {
      "tag": "clear_explanation",
      "text": "You gave a tight, structured walkthrough of PWG's three layers when Sam asked how it worked. No jargon-dumping, good abstraction level for his technical background.",
      "evidence": "~5-minute architecture explanation near minute 14; Sam asked two follow-ups that suggested he followed along."
    },
    {
      "tag": "reciprocity_repair",
      "text": "You noticed mid-call that Sam hadn't got to talk about his own projects, and you actively pivoted to let him lead the latter half.",
      "evidence": "Transition at ~45 minutes: 'Okay, cool. What else should you work on?'"
    }
  ],

  "what_to_work_on": [
    {
      "tag": "front-loaded_monologue",
      "severity": 2,
      "text": "The first 20 minutes were heavily {user}-led. Sam initiated the call but you drove most of it. In a work one-on-one where the other person reached out, consider a 'what's on your mind?' opener to hand them the floor first.",
      "evidence": "Sam opened with 'Hey, how you doing?' and {user}'s first substantive answer was 35 seconds of new-project context.",
      "pattern_match": {
        "previously_observed": 3,
        "last_seen": "2026-04-08_brian_catchup",
        "trend": "stable"
      }
    }
  ],

  "tip": {
    "text": "Next one-on-one you initiate OR that someone else initiates with you: try 30 seconds of genuine question-asking before saying anything about yourself. Ask, then listen, then respond. The inversion changes the shape of the whole first 10 minutes.",
    "attachable_to_reminder": true
  },

  "tags": ["reciprocity", "front-loading", "talk-share"],
  "overall_severity": 2,
  "confidence": 0.8,

  "flags": {
    "cross_conversation_pattern": true,
    "recommend_surfacing_to_user_soon": false,
    "sensitive_to_state_aloud": false
  }
}
```

---

## Field definitions

### `what_went_well`

0-3 items. Specific, evidence-grounded. Not flattery. If the user
genuinely did nothing notable well (rare but possible), empty array
is acceptable.

### `what_to_work_on`

0-3 items. Specific, evidence-grounded, actionable.

- `severity` 1-3. `1` = minor noticing, `2` = worth attending to,
  `3` = recurring pattern that affects outcomes.
- `pattern_match` populated by the orchestrator post-enrichment via
  lookup in `observations.db` — the LLM doesn't need to compute this
  itself. Leave `previously_observed: null` if cross-conversation
  context isn't supplied in the input.

### `tip`

One concrete tip the user can try next time, short enough to carry in
their head. This tip may appear in the user's daily morning brief
via the assistant, so it must be:
- **Immediately actionable** -- something to try today, not a life
  philosophy
- **Specific to the observed pattern** -- not generic advice like
  "listen more" or "be present"
- **Framed as a single behaviour change** -- "try X before Y" or
  "next time Z happens, do W"

Bad tips (generic platitudes): "Try to be a better listener."
/ "Remember to ask more questions." / "Be more present in meetings."

Good tips: "Next time Alex starts describing a client problem, count
to three after he finishes before you respond -- you tend to jump in
with solutions before he's finished framing." / "Before your next
one-on-one with someone who requested the meeting, open with 'What's
on your mind?' and let them talk for at least 2 minutes."

`attachable_to_reminder: true` flags whether it would make sense to
put this into a reminder for the next similar conversation.

### `tags`

Short labels for the kind of observation. Tag library (evolving):

- `talk-share`, `reciprocity`, `front-loading`, `interrupting`,
  `filler`, `hedging`, `over-explaining`, `under-explaining`,
  `asking-closed-questions`, `asking-open-questions`, `listening`,
  `reflection`, `empathy`, `pace`, `directness`, `vulnerability`,
  `story-telling`, `data-first`, `audience-read`, `energy-management`,
  `humour`, `decisiveness`, `commitment-tracking`

Use 1-4 tags per observation.

### `overall_severity`

1-3 for the whole observation. Drives whether the assistant surfaces this
proactively vs just logs it.

### `flags.cross_conversation_pattern`

`true` if this observation echoes at least 2 previous observations
with overlapping tags. Orchestrator computes; LLM leaves null.

### `flags.recommend_surfacing_to_user_soon`

`true` if the pattern is worth an assistant nudge before the user's next
conversation of the same type. Threshold: `severity >= 2` AND
`cross_conversation_pattern == true`.

### `flags.sensitive_to_state_aloud`

`true` if this observation is about something the user might not want
the assistant to announce via voice. Observations about partner relationship
dynamics, parenting tensions, or body language would flag this.
Observations about talk-share or filler words would not.

---

## Evidence discipline

Every entry in `what_went_well` and `what_to_work_on` requires
concrete `evidence` grounded in the transcript. Timestamps, quotes,
behaviours. No impressionistic coaching ("you seemed a bit off") —
that's advice dressed as observation.

---

## Cross-conversation context

If the orchestrator supplies recent observations (via a
`recent_user_observations` input array — last 10 observations about
the user), the LLM uses them to:

- Reference patterns (`this is the 4th time I've noticed this`)
- Vary tips (don't suggest the same tip as last time)
- Celebrate improvement (`last month you were front-loading 60% of
  openings; this conversation was 40% — good shift`)

When no prior context is supplied, the observation is self-contained
and the `pattern_match` fields stay null.

---

## Input the LLM receives

```
--- CLASSIFICATION ---
{classifier_json_output}

--- METADATA ---
{conversation_metadata}
coaching_tone: supportive|direct

--- CONVENTIONS ---
{contents of _conventions.md}

--- ENRICHED CONTENT ---
{enrichment output}

--- RELATIONSHIP SIGNALS (per participant) ---
{optional — signals produced by 03_relationship_signal for context}

--- RECENT USER OBSERVATIONS ---
{optional — up to 10 recent coach observations about the same user,
 feeding pattern-match reasoning}
```

---

## Privacy and retention

Coach observations are inherently private to the user. Stored as:

```yaml
user_id: {user_id}
visibility: private           # never shared, not even family:shared
retention_tier: tier-1-forever  # longitudinal data IS the product
retention_score_inputs:
  signal_density: (computed)
  centrality_refs:
    - user:{user_id}
  fact_count: 0
  is_pinned: false
```

Coach observations never attach to a Person record — they attach to
the user. Other people mentioned in the observation are referenced by
ID (for context) but the observation is not a signal about them; it's
a signal about the user.

---

## Output when input is unsuitable

If the coaching prompt is run on a conversation that shouldn't have
triggered it (classifier error, sensitivity missed, etc.), the LLM
emits:

```json
{
  "observation_id": null,
  "skipped": true,
  "skip_reason": "sensitive content detected in conversation — coaching would be intrusive",
  "recommend_reclassify_sensitivity": true
}
```

The orchestrator discards the invocation and flags the classifier
output for review.

---

## Daily brief integration

Coach observations feed into the assistant's daily morning brief. The brief
renderer selects the most recent unread observation (or the
highest-severity one from the past 48 hours) and presents:

1. The `tip.text` as the primary content
2. One `what_to_work_on` item as context (if severity >= 2)
3. One `what_went_well` item as balance

This means the `tip` field is the single most important output of
this prompt -- it is the line the user will actually read. Make it
count. If the conversation genuinely offers no coaching surface
(everything was routine and competent), a nil observation is better
than a forced tip.
