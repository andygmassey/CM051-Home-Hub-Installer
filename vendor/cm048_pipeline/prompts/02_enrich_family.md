# Prompt 02 — Enrich: family (any shape)

**Stage:** enrichment.
**Model:** large.
**Output scope:** Tier-1 only. Family conversations emphatically do NOT
trigger the coaching pass — coaching observations about how the user
handled a conversation with their partner, child, or parent would feel
intrusive. Family conversations DO still produce relationship signals
(separate prompt) because knowing a family member's evolving
preferences and concerns is exactly the kind of context the assistant should
surface before the next conversation.
**Precedence:** `_conventions.md`.

---

## What this conversation type is

Family members and very-close-friends-who-count-as-family. Partner,
children, parents, siblings, in-laws, godparents, close-family-friends
who've earned that status.

Shape can be any (`one-on-one`, `group-convo`, `meeting`). Stakes
varies from `low` (dinner banter) to `high` (family meeting about
eldercare, a medical diagnosis, schooling decisions).

Family is the setting with the highest privacy floor. Facts default
to L1 privacy-level even when content seems benign. Treat names of
minors with particular care — they appear in the Participants and
narrative but are flagged so downstream wiki publishing can
respect visibility rules.

---

## Sections to produce (in order)

### `## Summary`

`### Participants` (with role labels — partner, son, daughter, mother,
father, sibling, etc. when obvious from context or supplied metadata),
`### Location`, then two-to-three-sentence narrative. Tone is warm
and neutral, not cold or analytical. This is your family member's
life being recorded; treat the record with that respect.

### `## Topics covered`

Flat bulleted list. Attribute when attribution matters but don't
over-attribute — family members often co-produce a conversation.

### `## Practicalities`

Any household / logistics content discussed: pickups, trips, errands,
appointments, shopping, repairs. This is the family-specific
equivalent of "action items" — named `Practicalities` because "action
item" feels too corporate for family context. Bullet list,
optionally with a `Who:` marker for who's doing what.

Emit `reminders_candidates` for items where
`owner == {user_name}`. Family reminders are a common cross-domain
use case (user buys groceries, picks kid up, books dentist).

### `## Moments to remember`

0-3 items. Different emphasis from "notable moments" in other types —
this section is about the texture of family life. A funny thing a
kid said, a tender moment, a shared laugh, a small milestone.
`_Nothing specific._` when the conversation was just routine
logistics. Don't force emotional content where there wasn't any.

### `## People and places mentioned`

Third-parties and locations. Be gentle about flagging: Gran, the
next-door neighbour, the teacher at school, the plumber. Small stakes,
meaningful context.

### `## Cleaned transcript`

Per conventions. Family cleaned transcripts often benefit from
looser punctuation — the conversational rhythm is part of the record.
Don't aggressively formalise the speech.

---

## What this prompt does NOT produce

- No Key insights — family life isn't a surface that rewards
  meta-observation.
- No Decisions — the `Practicalities` section covers concrete
  agreements; formal "decisions" rarely apply.
- No Next steps — redundant with Practicalities.
- No Communication dynamics or speaking-ratio analysis — family
  conversations aren't a coaching surface.

---

## Stakes escalation (`high`)

When a family conversation is `stakes: high` (eldercare decision,
a child's difficult school situation, a medical matter, a
relationship crisis), these modifications apply:

- Add a `## Decisions` section — this is one of the times family
  conversations produce real decisions that need recording.
- Add a `## Support commitments` section — who's going to help whom,
  when, how.
- Sensitivity often bumps to `sensitive` or `highly-sensitive` and
  the corresponding redaction + Coach-skip rules apply.

---

## Frontmatter

`classification.setting: family`. Shape per classifier.
`prompt_version: 02-family@1.0`.

Extra frontmatter field: `contains_minors: true|false` — populated by
the classifier if any participant is flagged as a minor. CM044 wiki
compiler uses this to suppress publication of pages that would
surface minor's data beyond their own private graph.
