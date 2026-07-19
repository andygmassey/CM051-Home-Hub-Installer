# Prompt 05 — Fact extraction

**Stage:** final LLM pass in the enrichment pipeline.
**Model:** medium. `qwen3.5:9b` or `qwen3.5:35b-a3b` depending on
configured fact-extraction model.
**Output scope:** spans Tier-1 (conversation facts) and Tier-2
(person facts — attached to the Person they're about). Written to
Qdrant (for semantic retrieval) and Oxigraph (for structured graph
queries). Compatible with CM040's existing fact schema so downstream
consumers (assistant context lookup, `/people/context` API) don't need
to distinguish between sources.
**Precedence:** `_conventions.md`.

---

## What this prompt extracts

Durable, retrievable facts with the 30-day-test filter from CM040.
Scan the transcript systematically for EVERY instance of these
categories:

- **Job title / role / employer** of any person mentioned ("Diana
  worked in new business development at a creative agency for seven
  years", "Marco maintains banking relationships for crypto
  companies")
- **Company / organisation details** about any org mentioned ("The
  bank is the sixth largest in their country", "The agency was making
  staff redundant")
- **Personal preferences** held by named participants ("Alex prefers
  static generation via Cloudflare over traditional CMSes for client
  sites")
- **Decisions** concluded in the conversation (both parties' and
  each individually)
- **Relationships between people** ("Diana was introduced to her
  employer through Robert at the sports club", "Pierre judges MBA
  pitches for an executive programme")
- **Life events / milestones** ("Alex is giving his first public talk
  at the local tech meetup", "Diana was made redundant a few months
  ago")
- **Plans with lasting relevance** ("{user} applied to an accelerator
  programme", "Diana and {user} plan to pitch a bank together")
- **Professional expertise / background** of anyone mentioned ("Pierre
  has experience in luxury brands in APAC and corporate venture
  capital", "{user} set up a consultancy in September")
- **Beliefs / positions** expressed that are stable ("Pierre believes
  most people do not care about privacy until something goes wrong")
- **Family / personal circumstances** mentioned in passing ("Diana
  moved for her partner after five years of long distance", "Marco's
  son was diagnosed with ADHD at 10")
- **Skills / capabilities** demonstrated or claimed ("Alex has a
  team of four people for client work", "{user} has a network of
  designers, developers, and creative technologists")
- **Location / geography** details that are durable ("{user} lives in
  Riverside", "Pierre works across regional markets")
- **Upcoming events / meetings** with concrete dates ("Co-working
  session planned for tomorrow at 9am", "Workshop being rescheduled
  to next week")

The 30-day test: if the fact won't matter in 30 days, don't extract.
Greetings, meeting logistics, fleeting opinions, error messages -
all out.

---

## Attribution

Every fact carries a `subject` field identifying who the fact is
about. Not who said it — who it's about. Examples:

| Said by | About whom | subject |
|---|---|---|
| {user} said "I love Quiet" | {user} | `user` |
| {other} said "Sam hates Rails" | Sam (the other) | `other:alex_chen` |
| {other} said "Diana is a connector" | Diana (a 3rd party) | `person:diana_lastname` |
| {user} said "Our Mac Mini has 24GB" | the user's household | `household:user` |
| {other} said "ContactCo-F is doing a revamp" | an org | `org:contactco-f` |

When the subject is a third party (mentioned but not present), the
fact still gets extracted — it enriches the Person / Org graph even
though that person wasn't in the conversation.

---

## Extraction priority: other people first

Facts about the OTHER person in the conversation are **high value** -
the user already knows their own job title, their own plans, their
own preferences. What they will forget is what the other person told
them. Prioritise:

1. **Facts about the other participant(s)** - their role, company,
   background, plans, preferences, family situation, expertise.
   These are the facts the user will search for later ("what does
   Diana do?" / "where did Marco work before?").
2. **Facts about third parties mentioned** - people not present but
   discussed. These enrich the Person graph for people the user
   hasn't even spoken to directly yet.
3. **Facts about the user** - extract these too (they confirm and
   update the user's own record) but they are lower priority. The
   user won't be searching for facts about themselves.
4. **Facts about organisations** - company details, industry context,
   project specifics. Useful for the Org graph.

---

## Worked examples

These examples show the expected extraction depth from real
conversation patterns.

### Example A: Coffee with a new contact (work, one-on-one)

From a 20-minute coffee where Diana described her career:

```json
[
  {
    "text": "Diana Thompson transitioned from IT roles at multinational tech companies to new business development, spending her longest stint of seven years at one company.",
    "type": "fact",
    "subject": "other:diana_thompson",
    "domain": "work",
    "confidence": "stated",
    "privacy_level": "L0",
    "signal_strength": "strong",
    "temporal": false,
    "evidence": "Diana described her career path: 'My career path has always been with large corporates... longest stint was seven years.'"
  },
  {
    "text": "Diana Thompson relocated for her partner after five years of long distance.",
    "type": "event",
    "subject": "other:diana_thompson",
    "domain": "family",
    "confidence": "stated",
    "privacy_level": "L1",
    "signal_strength": "strong",
    "temporal": false,
    "evidence": "Diana said 'My partner has always been here. We did long distance for five years.'"
  },
  {
    "text": "Diana Thompson was made redundant from her agency role a few months ago but retains client relationships who still approach her for work.",
    "type": "event",
    "subject": "other:diana_thompson",
    "domain": "work",
    "confidence": "stated",
    "privacy_level": "L0",
    "signal_strength": "strong",
    "temporal": true,
    "expires_at": "2027-04-15",
    "evidence": "Diana said 'they made me redundant a few months ago' and 'some of my clients still come to me.'"
  },
  {
    "text": "Diana Thompson and {user} plan to pitch jointly to a bank for a mobile app revamp project, presenting directly to the bank's president.",
    "type": "plan",
    "subject": "other:diana_thompson",
    "domain": "work",
    "confidence": "stated",
    "privacy_level": "L1",
    "signal_strength": "strong",
    "temporal": true,
    "expires_at": "2026-07-15",
    "evidence": "Diana asked 'Would you be interested in going in together on this?' and {user} agreed."
  }
]
```

That is 4 facts from a short conversation. Note: each person
mentioned by name likely warrants at least one fact.

### Example B: Lunch covering personal health and tech projects

From a 45-minute lunch touching ADHD, drone patents, and a personal
AI demo:

Expected facts (abbreviated): Marco maintains banking relationships
for crypto companies (role); Marco previously worked on drone
agriculture with a state-owned company (career); Marco holds a
patent for close-proximity drone scanning (expertise); Marco holds a
second patent for projectile detection (expertise); Marco's son was
diagnosed with ADHD and is talented at baseball (family); Marco was
himself diagnosed with ADD (health, L1); Marco offered to forward
materials to his brother-in-law who runs a startup accelerator
(relationship + plan); {user} built an elder-care transcription tool
that got 5,500 GitHub upvotes (milestone).

That is 8 facts from one lunch. Each substantive topic yields at
least one fact.

### Example C: Nothing extractable

If a transcript is a 2-minute "running late, be there in 10" exchange:

```json
[]
```

An empty array is correct when nothing passes the 30-day test. Do
not pad with low-quality facts to hit a minimum.

---

## Output format

Single JSON array of fact objects:

```json
[
  {
    "text": "Alex Chen holds CMSes are obsolete in the AI era, preferring static generation via Cloudflare for client sites.",
    "type": "belief",
    "subject": "other:alex_chen",
    "domain": "tech",
    "confidence": "stated",
    "privacy_level": "L0",
    "signal_strength": "strong",
    "temporal": false,
    "evidence": "Sam asked 'is a CMS still valid, given Claude?' and agreed with {user}'s push that static generation via Cloudflare is cleaner."
  },
  {
    "text": "{user} has applied for a non-dilutive innovation grant focused on patent applications and productising their main project.",
    "type": "plan",
    "subject": "user",
    "domain": "work",
    "confidence": "stated",
    "privacy_level": "L1",
    "signal_strength": "strong",
    "temporal": true,
    "expires_at": "2027-04-15",
    "evidence": "Direct statement from {user} describing the grant application and intended uses of the funds."
  },
  {
    "text": "Diana (introduced via ContactGrp-A) was previously in business development at ContactCo-R and is currently placing redundant clients with boutique agencies.",
    "type": "relationship",
    "subject": "person:diana_contactgrp",
    "domain": "work",
    "confidence": "stated",
    "privacy_level": "L0",
    "signal_strength": "medium",
    "temporal": false,
    "evidence": "{user} described Diana's background and current activity during a portion of the call where {user} was describing potential networking."
  }
]
```

---

## Field definitions

- `type`: `fact` | `preference` | `decision` | `plan` | `event` |
  `relationship` | `belief` | `milestone`
- `subject`: `user` | `other:{slug}` | `person:{slug}` | `org:{slug}`
  | `household:{household_id}`. The slug is either a canonical ID
  from the Person/Org graph (if already known) or a new-entity
  placeholder (resolved by the entity-linking post-step).
- `domain`: `food` | `entertainment` | `tech` | `family` | `work` |
  `health` | `travel` | `finance` | `social` | `general` | `politics`
  | `creative` | `education`
- `confidence`: `stated` (explicitly said) | `inferred` (derived
  from context with high certainty)
- `privacy_level`: `L0` (public), `L1` (personal), `L2` (private /
  sensitive). **Home addresses, phone numbers, financial amounts,
  medical details → ALWAYS L2** regardless of speaker.
- `signal_strength`: `strong` (explicitly stated conviction) |
  `medium` (clearly implied from context) | `weak` (inferred,
  uncertain — usually skip)
- `temporal`: `true` if the fact has a time component that might
  expire. When true, include `expires_at` ISO date.
- `evidence`: one sentence grounded in the transcript — which part of
  the conversation supports this fact.

---

## Extraction volume

A typical 30-minute work conversation should yield **5-15 facts**.
A rich 60-minute conversation may yield 15-30. A light social
catch-up may yield 3-8.

**Minimum expectations by conversation length:**

| Duration | Minimum facts | Typical range |
|----------|--------------|---------------|
| < 10 min | 0 (may be empty) | 0-3 |
| 10-20 min | 2 | 2-6 |
| 20-40 min | 3 | 5-12 |
| 40-60 min | 5 | 8-20 |
| 60+ min | 8 | 12-30 |

If you are producing fewer than the minimum from a substantive
conversation, you are being too conservative. **Go back through the
transcript person by person** and ask:

1. What is this person's job / role / company? (fact)
2. What is their professional background? (fact)
3. What are they working on right now? (fact or plan)
4. What opinions or preferences did they express? (belief or preference)
5. What personal details did they share? (fact, L1)
6. Who else did they mention, and in what context? (relationship)
7. What did they commit to doing? (plan or decision)
8. What upcoming events or meetings were discussed? (event or plan)

Every person mentioned by name is likely worth at least one fact
(their role, their company, their relationship to the user). Every
decision or commitment is a fact. Every professional detail shared
about a third party is a fact.

## Quality gates

Before including a fact in the output, it must pass ALL of these:

1. **30-day test:** will this fact still matter in 30 days? If not, skip.
2. **Evidence test:** can you point to a specific speaker turn that
   supports this? If the evidence is "general vibe of the conversation,"
   skip.
3. **Attribution test:** is the `subject` field clearly identifiable?
   If you can't determine who the fact is about, skip.
4. **Novelty test:** does this fact add information beyond what's
   obvious from the metadata? "John and Sam had a work meeting" is
   already in the metadata — don't extract it as a fact.
5. **Specificity test:** is this specific enough to be useful in
   retrieval? "They discussed work" is useless. "Sam is migrating
   ContactCo-F's client to a Laravel framework" is useful.

Better to emit 5 high-quality facts than 15 that include filler.
Better to emit 0 than to emit low-quality facts that pollute the
knowledge graph.

## Discipline

- **Third person, full names or slugs.** Never `I` or `you`.
- **Never fabricate.** If unsure, omit. But "unsure" means "the
  transcript doesn't say this" — not "I'm being cautious." If the
  transcript clearly states something, extract it.
- **Don't double-extract.** If `{user}` stated a preference that
  `{other}` already stated elsewhere in the conversation, one fact
  is enough — don't emit it as two separate entries.
- **Don't extract from quoted speech of absent parties.** If `{other}`
  says `"My sister always says X"`, don't extract that the sister
  believes X — the evidence is too indirect.
- **Redaction per policy.** Facts that survive redaction become
  extracted; facts that depend on redacted specifics (`{user}
  discussed a [redacted: amount] figure`) become weak-signal and
  usually skipped.
- **Facts about minors** always `privacy_level: L2` regardless of
  content.

---

## Integration with fact-centrality scoring

Each fact feeds into the conversation's `retention_score_inputs.fact_count`
and `retention_score_inputs.signal_density` once the orchestrator tallies
the post-extraction output. A conversation producing 12 facts from 30
minutes of content has high signal density; one producing 1 fact from
60 minutes has low.

Facts also update `centrality_refs` on the parent conversation
frontmatter — each unique `subject` becomes a centrality reference.

---

## Input the LLM receives

```
--- CLASSIFICATION ---
{classifier_json_output}

--- METADATA ---
{conversation_metadata}

--- TRANSCRIPT ---
{raw conversation transcript with speaker labels}
```

Note: fact extraction receives the raw transcript, not the enriched
summary. This ensures the model has access to the actual dialogue
turns and speaker attributions needed for evidenced extraction.

---

## Compatibility with CM040

The output schema is deliberately aligned with CM040's
`extractor.py` output shape. The same Qdrant `conversations`
collection receives facts from both sources. Downstream consumers
(`/people/context`, wiki compiler, assistant retrieval) filter by
`source == "ai_chat"` or `source == "human_conversation"` when they
care; otherwise treat facts uniformly.

Key difference from CM040: `subject` field. CM040 facts are all about
the user (implicit). CM048 facts can be about anyone mentioned.
Downstream consumers that didn't expect `subject` default to treating
`subject == user` for legacy compatibility — no breakage.
