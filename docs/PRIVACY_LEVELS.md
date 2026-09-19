# The two privacy scales, and why they are dangerous together

**Read this before touching anything with `level` in its name.**

Ostler has **two** numeric privacy scales. They run in **opposite directions**,
they are **both spelled `L<n>`**, and one of them is **converted into the
other**. That is not a design; it is an accident that has already produced at
least one real defect, described at the bottom.

---

## Scale 1: `privacy_level` - L0, L1, L2, L3

**HIGHER IS MORE PRIVATE. `L3` is hidden.**

| value | meaning |
|---|---|
| `L0` | least private |
| `L1` | |
| `L2` | publishable |
| **`L3`** | **hidden - withheld from reads** |

Defined and enforced in `vendor/cm041/pwg_privacy.py`, whose own docstring calls
itself "the ONE helper every L3 read-side decision in the CM041 Hub server
routes through".

**It is FAIL-CLOSED, and that is deliberate.** Missing, empty, unparseable, or
any value outside `{L0,L1,L2,L3}` is treated as **L3 and hidden**. Only an
explicit, parseable `L0`/`L1`/`L2` passes. Any `L3` on any axis hides the
record.

So on this scale, **a broken label hides data**. The failure direction is safe.

---

## Scale 2: `compartment_level` - 0 to 6

**LOWER IS MORE PRIVATE. `0` is the most private.**

It widens the audience as it counts up. From `base.py`:

| value | name | |
|---|---|---|
| **`0`** | **L0Personal** | **most private** |
| `1` | L1Family | |
| `2` | L2Trusted | the default |
| `3` | L3Community | |
| `4` | L4Public | publishable |
| `5` | L5Commercial | publishable |
| `6` | L6Broadcast | publishable |

Defined in
`vendor/cm019_preferences/services/ingest/src/parsers/base.py` (`_compartment_uri`).

So on this scale, **a wrong label can expose data**. The failure direction is
unsafe, and there is no fail-closed default equivalent to scale 1's.

---

## Why the pair is worse than either

**1. `L2` means opposite things.**
`privacy_level` `L2` is *publishable* (because `L3` is the hidden one).
`compartment_level` `2` is `L2Trusted`, which is *fairly private* (because `0`
is the most private). Same two characters, near-opposite meanings.

**2. One is converted into the other.**
`vendor/cm041/contact_syncer/privacy_model.py` maps compartment numbers onto
`privacy_level` strings, and collapses the top of one scale onto the middle of
the other:

```python
4: LEVEL_L2,  # L4Public      (publishable)
5: LEVEL_L2,  # L5Commercial  (publishable)
6: LEVEL_L2,  # L6Broadcast   (publishable)
```

Its own comment calls this "the inverted sense".

**3. Reading either name alone tells you nothing.**
`level = 5` is nearly the most private on one reading and nearly the most
public on the other. You cannot tell which without knowing the field name AND
which scale that field belongs to.

---

## The defect this already caused

`apple.py` wrote `compartment_level=5` at four sites, each commented
`# HIGHEST PRIVACY`:

- Notes - "notes contain personal info"
- Health data, three sites

`5` is `L5Commercial`, which `privacy_model.py` maps to the **publishable**
level. So a customer's **Apple Health and Notes** were labelled one step from
Broadcast.

**The comment is why it survived review.** The prose stated the intent
correctly and the number said the opposite, so a reviewer checking intent found
the right words sitting next to the wrong value. Three docstrings taught the
same inversion to whoever read them next.

Fixed on 2026-09-16. Guarded by
`tests/test_no_parser_labels_private_data_publishable.py`, which derives the
publishable set **from the model** rather than hard-coding it, so the two
cannot silently diverge.

---

## Rules until this is unified

1. **Never write a bare `level`.** Use the full field name,
   `privacy_level` or `compartment_level`, every time.
2. **Never copy a number between the scales.** They are not interchangeable and
   `5` is not `5`.
3. **State the direction in the comment**, not the intent. Write
   `# 0 = L0Personal, the most private` rather than `# HIGHEST PRIVACY`. The
   intent is what made the defect above invisible.
4. **A guard on `compartment_level` must derive its sets from
   `privacy_model.py`**, never type them, because that file is where the
   conversion lives.
5. **`privacy_level` fails closed and must stay that way.** Absent means
   hidden. That was a deliberate correction to a leak, not a default to tidy
   away.
6. **`compartment_level` should never be absent.** A writer that emits a point
   without one has produced a record nobody can find. Fix the writer rather
   than widening the reader.
7. **Do not "fix" the direction of either scale in isolation.** Each has
   readers that assume its current direction. Changing one end without the
   other is a silent disclosure change, which is the worst kind.

---

## This is not the end state

Two scales in opposite directions, sharing a spelling, with a conversion
between them, is a defect in the design rather than in any one file. It is
recorded for re-examination **immediately after a launch DMG ships**, tracked as
HR015 issue #960. It is not being restructured before the cut, because
re-scoping every privacy-filtered read in the product is not a launch-week
change, and both directions look like a working filter from the outside.

---

## What is measurably wrong today

Four findings, each measured on `origin/main` on 2026-09-16. They are listed
here rather than in an issue because this file is what a reader opens when
they are about to touch one of these fields.

**1. One constant feeds both scales.** `vendor/ostler_fda/pwg_ingest.py:77`:

```python
DEFAULT_PRIVACY = os.getenv("DEFAULT_PRIVACY_LEVEL", "L2")
```

That single string is written to `pwg:privacyLevel` (the L0 to L3 scale) at six
sites AND to `compartment_level` (the 0 to 6 integer scale) at lines 1948 and
2252. One environment variable therefore moves a value on two scales that mean
different things and point in opposite directions. On the L0 to L3 scale `"L2"`
is the second-least private of four; on the 0 to 6 scale `2` is L2Trusted,
third-most-private of seven. One constant cannot be both statements.

**2. The type is wrong on one of them.** `compartment_level` is declared `int`
in `base.py:67`, indexed as `"integer"` in `qdrant_loader.py:74`, and all 23
parsers pass integers. The FDA writer puts the string `"L2"` there. Qdrant's
range operator does not match a string, so for a long time every
compartment-scoped search returned nothing. Measured on a live box: 4,804
points carried the string form and a `range gte 0` query matched 0 of them,
with a control query on a different field matching 5,733.

The reader now accepts both forms. The writer has not been changed, so the two
forms coexist on disk. **Re-measured on the shipped tree 2026-09-18: the
reader's L3 decisions route through `pwg_privacy.filter_l3_facts`, which is
string-based throughout, and a search for numeric comparisons on any privacy
field in the shipped tree returns none.** So the live artefact is consistent
string-to-string; this finding describes the writer's type, not a live break.

**3. Some records get no label at all.** In `pwg_ingest.py`, four payload sites
set `privacy_level` and only two of them also set `compartment_level`. Lines
1714 and 2707 write a privacy level and no compartment level. On the box that
was measured, 934 of 9,948 points had the field absent, and those points match
neither filter arm and never appear in results.

**That is the root cause worth fixing.** Everything downstream of it is an
argument about what to do with data that should never have been unlabelled.

**4. A third naming, in a third place.**
`vendor/cm024_knowledge/.../markdown_writer.py:78` documents the parameter as
"Privacy level (0-4), default 2 (personal)". A different range again, and it
calls `2` "personal" where `base.py` calls `0` "Personal" and `2` "Trusted".

---

## What is not settled

**Whether the two scales should be merged.** They answer different questions,
"is this secret" and "who may see this", so having two is defensible. Having
two that are both spelled `L<n>` and run in opposite directions is not.

**What an absent `compartment_level` should mean**, once the writers are fixed
and it can only happen to legacy records. Excluding is the current behaviour
and the safe one. Including would return a customer their own data and is the
kinder one. That is a product decision and it is Andy's.
