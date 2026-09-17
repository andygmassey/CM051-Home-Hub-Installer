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

---

## This is not the end state

Two scales in opposite directions, sharing a spelling, with a conversion
between them, is a defect in the design rather than in any one file. It is
recorded for re-examination **immediately after a launch DMG ships**, tracked as
HR015 issue #960. It is not being restructured before the cut, because
re-scoping every privacy-filtered read in the product is not a launch-week
change, and both directions look like a working filter from the outside.
