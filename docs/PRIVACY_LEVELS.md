# The two privacy scales, and why they disagree

Written 2026-09-16 after Andy asked which end of the scale is private, because
nothing in this repository answered it. Both scales below were read out of the
code, not recalled.

## The short version

There are **two different privacy scales**, they run in **opposite directions**,
and they are **both written `L<number>`**.

| | `privacy_level` | `compartment_level` |
|---|---|---|
| range | L0 to L3 | 0 to 6 |
| written as | a string, `"L2"` | an integer, `2` |
| direction | **higher is MORE private** | **lower is MORE private** |
| most private | `L3` | `0` |
| most public | `L0` | `6` |
| missing value | treated as `L3`, hidden | matches nothing, silently dropped |
| authority | `vendor/cm041/pwg_privacy.py` | `vendor/cm019_preferences/.../parsers/base.py` |

**`L3` means "hide this" on one scale and "share with your community" on the
other.** That is the hazard. Anything that reads one value as the other gets the
answer exactly backwards, and backwards on a privacy control means disclosure.

## `privacy_level`: L0 to L3, higher is more private

Defined in `vendor/cm041/pwg_privacy.py`, which calls itself "the ONE helper
every L3 read-side decision routes through" and is operator-approved doctrine
dated 2026-06-28.

    L0  least private
    L1
    L2
    L3  most private, hidden

**It is FAIL-CLOSED, and deliberately so.** From the file:

> Missing / empty / unparseable / any value not in {L0,L1,L2,L3} -> treat as L3
> (hidden). Only an explicit, parseable L0/L1/L2 passes.

The previous helper kept untagged facts, which is fail-OPEN, and that was the
leak class this replaced. Most-restrictive wins when a fact and its owning node
both carry a level.

**If you are thinking "L0 to L3", this is the scale you mean.** It is the one
that governs whether a person fact is shown.

## `compartment_level`: 0 to 6, lower is more private

Defined in `vendor/cm019_preferences/services/ingest/src/parsers/base.py`, in
`_compartment_uri()`:

    0  L0Personal     most private
    1  L1Family
    2  L2Trusted      the default
    3  L3Community
    4  L4Public
    5  L5Commercial
    6  L6Broadcast    most public

This is a SHARING-AUDIENCE scale, not a secrecy scale, which is why it runs the
other way: it names who a thing may be shared with, and the list widens as the
number rises.

**It is not fail-closed.** A point with no `compartment_level` matches neither
arm of the search filter and is silently excluded. Excluding is the safe
direction, but nothing tells anyone it happened.

## Three ways this is currently wrong

Each measured on `origin/main`, 2026-09-16.

**1. One constant feeds both scales.** `vendor/ostler_fda/pwg_ingest.py:77`:

    DEFAULT_PRIVACY = os.getenv("DEFAULT_PRIVACY_LEVEL", "L2")

That single string is written to `pwg:privacyLevel` (the L0-L3 scale) at six
sites AND to `compartment_level` (the 0-6 integer scale) at lines 1948 and 2252.
One environment variable therefore moves a value on two scales that mean
different things and point in opposite directions.

On the L0-L3 scale `"L2"` is the second-least private of four. On the 0-6 scale
`2` is L2Trusted, third-most-private of seven. They are not the same statement
and one constant cannot be both.

**2. The type is wrong on one of them.** `compartment_level` is declared `int`
in `base.py:67` and indexed as `"integer"` in `qdrant_loader.py:74`, and all 23
parsers pass integers. The FDA writer puts the string `"L2"` there. Qdrant's
range operator does not match a string, so for a long time every
compartment-scoped search returned nothing at all. Measured on a live box: 4,804
points carried the string form, and a `range gte 0` query matched 0 of them,
with a control query on a different field matching 5,733.

The reader now accepts both forms. The writer has not been changed, so the two
forms coexist on disk.

**3. Some records get no label at all.** In `pwg_ingest.py`, four payload sites
set `privacy_level` and only two of them also set `compartment_level`. Lines
1714 and 2707 write a privacy level and no compartment level. On the box that
was measured, 934 of 9,948 points had the field absent, and those points match
neither filter arm and never appear in results.

**That is the root cause worth fixing.** Everything downstream of it is
argument about what to do with data that should not have been unlabelled.

**4. A third naming, in a third place.**
`vendor/cm024_knowledge/.../markdown_writer.py:78` documents the parameter as
"Privacy level (0-4), default 2 (personal)". That is a different range again,
and it calls 2 "personal" where `base.py` calls 0 "Personal" and 2 "Trusted".

## Rules, until someone with authority changes them

- **Never read one scale's value as the other's.** They disagree about direction
  and about range. If you are handed an `L<n>` string, establish which scale it
  came from before comparing it to anything.
- **`privacy_level` fails closed and must stay that way.** Absent means hidden.
  That was a deliberate correction to a leak and is not a default to tidy away.
- **`compartment_level` should never be absent.** A writer that emits a point
  without one has produced a record nobody can find. Fix the writer rather than
  widening the reader.
- **Do not "fix" the direction of either scale in isolation.** Each has readers
  that assume its current direction. Changing one end without the other is a
  silent disclosure change, which is the worst kind.

## What is not settled

**Whether the two scales should be merged.** They serve different questions,
"is this secret" and "who may see this", so having two is defensible. Having two
that are both spelled `L<n>` and run in opposite directions is not.

**What an absent `compartment_level` should mean**, once the writers are fixed
and it can only happen to legacy records. Excluding is the current behaviour and
the safe one. Including it would return a customer's own data to them and is the
kinder one. It is a product decision and it is Andy's.
