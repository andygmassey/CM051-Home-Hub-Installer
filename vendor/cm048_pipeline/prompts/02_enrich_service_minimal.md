# Prompt 02 — Enrich: service (minimal processing)

**Stage:** enrichment, lightweight variant.
**Model:** small (`qwen3.5:9b` is fine — minimal extraction, no
narrative generation).
**Output scope:** Tier-1 only, very thin. Neither Relationship signals
nor Coaching run. Processing_depth is `minimal` per the classifier.
**Precedence:** `_conventions.md`.

---

## What this conversation type is

Transactional service interaction. The other party is fulfilling a
function. Examples:

- Customer support call (bank, insurance, utility, software vendor)
- Delivery driver arranging a drop-off
- Taxi driver small-talk and logistics
- Doctor's reception booking an appointment
- Restaurant booking call
- Call centre of any sort

Characteristics:
- User won't retroread this for warmth or coaching.
- The value to PWG is the **transactional artefacts**: who the user
  spoke to, what company, any reference numbers, decisions made,
  action items.
- A narrative summary is overkill. Fractional sentences suffice.

---

## Sections to produce (in order)

### `## Service record`

Fixed-structure bullet list. Each bullet either filled or `—`. Do
NOT write a narrative paragraph.

- **Provider organisation:** company or agency name
- **Provider contact:** individual's name and role if identified
  ("Sarah, technical support L2"), otherwise `—`
- **Channel:** phone / in-person / chat / video
- **Reference number(s):** any case IDs, order numbers, booking
  references mentioned
- **Purpose:** one phrase — what the user was trying to accomplish
- **Outcome:** resolved / partial / unresolved / escalated
- **Next action:** what was agreed will happen next, by whom, by when

### `## Action items`

Short bullet list for anything the user needs to do as a follow-up.
Emit `reminders_candidates` for user-owned items.

Common service-interaction reminder candidates: "call back if not
fixed by Friday," "send a photo of the damaged item," "confirm the
appointment 24h before."

### `## Notes`

Optional one-paragraph free text IF the interaction contained
information worth preserving beyond the Service record fields. Most
service interactions don't need this section — `_Nothing to report._`
is the common case.

Examples of when Notes is warranted:
- The support agent gave a workaround that should be documented
- The provider promised something unusual worth recording
- The user noticed something odd about the service

---

## What this prompt does NOT produce

- No Summary section (Service record + Outcome covers it)
- No Key topics / Decisions / Key quotes / Insights / Next steps
- No cleaned transcript (transactional interactions rarely reward
  full transcript cleaning; if the user specifically wants one,
  they can flag the conversation for `processing_depth: full` on
  re-ingest)
- No Participants / Location subsections in their full form —
  the Service record's Provider fields capture what matters

---

## Frontmatter

Shorter than other types:

```yaml
---
conversation_id: {id}
classification:
  setting: service
  shape: one-on-one
  stakes: low
  suggested_type_slug: service_one-on-one_low
sensitivity:
  level: {level}
  categories: []
participants:
  - id: user
    display: {user_display_name}
    role: user
  - id: {provider_slug}
    display: {provider_contact_name_or_org}
    role: service_provider
    organisation: {provider_organisation}
location: {...}
prompt_version: 02-service_minimal@1.0
locale: {locale}
redaction_policy_version: {policy_version}
enrichment_model: qwen3.5:9b
enrichment_completed_at: {iso8601}
retention_tier: tier-3-years      # default for service; elevate if
                                   # reference_numbers present (may need
                                   # retention for warranty/proof)
retention_score_inputs:
  signal_density: 0.3              # service interactions have low
                                   # signal density by design
  centrality_refs:
    - org:{provider_org_slug}
  fact_count: 0
  is_pinned: false
related_conversation_ids: []
processing_depth: minimal
review_required: false
---
```

---

## Special cases to route differently

If what seemed like a service interaction turns out to contain
substantive content worth fuller processing — e.g. the support call
became a longer-than-expected discussion, or the taxi driver is an
old friend — the classifier should have caught it and routed away
from `service`. If the enrichment finds the service-minimal structure
is a poor fit (too many important details, complex decisions), emit
`reclassify_recommended: true` in the output frontmatter so the
orchestrator can queue a full-processing re-run.

---

## Why this prompt exists separately

Two reasons:

1. **Cost.** Running full enrichment on a 2-minute taxi call wastes
   LLM budget. Minimal output matches minimal information density.
2. **Signal.** A directory of well-structured Service records becomes
   its own useful surface — "what was that case number the ISP gave me
   last month?" — which a pile of narrative summaries wouldn't.
