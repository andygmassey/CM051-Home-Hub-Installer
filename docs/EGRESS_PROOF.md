# Can this instrument fail? Run it yourself and watch it

A privacy report that has never come back red is not evidence. It is a program
that prints "clean", and from outside there is no way to tell that apart from a
program that looked and found nothing.

So this page does not ask you to believe a pass. It hands you the instrument we
use to check what leaves the Mac, five readings whose correct answers are known
in advance, and asks you to watch it get two of them **wrong on purpose** —
because an instrument that cannot come back red cannot make a green mean
anything.

```
bash tests/test_the_egress_proof_can_go_red.sh
```

No network. No installed copy of the product. No privileges, no simulator, no
account. It reads files that are in this repository and exits 0, 1 or 2.

---

## The five readings

Four of them are a real capture. On 2026-08-17 an install was running on a
16 GB M4 Mini and every established TCP socket on the machine was sampled five
times, about two seconds apart. That capture is committed verbatim at
`scripts/box_walk_probes/fixtures/egress_2026-08-17_mid_install.tsv`, and it is
in this repository because it is the reading that caught our own instrument
being blind: under the filter we shipped before it, it flagged **nothing**.

| # | Reading | Wanted | Why that is the right answer |
|---|---------|--------|------------------------------|
| 1 | the capture, unmodified | **RED** | six connections left the boundary. An instrument that passes here is blind |
| 2 | the same capture, those six rows removed | GREEN | if it also flagged this, it is flagging everything and arm 1 proved nothing |
| 3 | the customer's own Mail and WhatsApp | GREEN | those leave the machine and are **not ours**. Blaming them for our claim would be dishonest in our favour |
| 4 | reading 2, with one destination planted | **RED** | the deliberate leak. One undeclared address, carrying our own lineage |
| 5 | a reading with nothing of ours in it | **CANNOT-RUN** | it observed no connection of ours, so it knows nothing. A quiet 0 here would report blindness as safety |

Reading 5 is the one we would most like you to notice. Most gates have two
states, and a gate with two states must call "I could not measure" something —
and it nearly always calls it a pass.

## What it prints

Recorded on `994bb65c`, 2026-09-07:

```
the egress instrument, exercised against five readings with known verdicts

  [PASS] recorded       rows=22  flagged=6  rc=1   MUST CATCH: the real 2026-08-17 capture that proved the old filter blind
  [PASS] inside-only    rows=16  flagged=0  rc=0   MUST MISS: the same reading with those six rows removed
  [PASS] third-party    rows=4   flagged=0  rc=0   MUST NOT BLAME US: the customer's own Mail and WhatsApp leave the boundary
  [PASS] planted        rows=17  flagged=1  rc=1   THE PLANTED LEAK: one undeclared destination carrying our lineage
  [PASS] no-subject     rows=3   flagged=1  rc=2   REFUSES: no connection of ours observed, so it says nothing and admits it

  PASS: 5/5
  and the arms disagree: 2 wanted RED, 2 wanted GREEN, 1 wanted CANNOT-RUN.
```

The planted destination is `203.0.113.77`. That is TEST-NET-3, reserved by
RFC 5737 for documentation and routed nowhere on the public internet, so
nothing in this repository can be mistaken for a real destination by you or by
a later reader.

## And we broke it on purpose, twice

Five green arms would be worth very little if we had never seen them go red for
a reason we caused. Two single-line edits to the instrument, each with the edit
proved to have landed before the result was read:

**Make the boundary swallow everything** — the instrument now believes every
address is inside the machine:

```
  [FAIL] recorded       rows=22  flagged=0  rc=0 wanted=1
  [PASS] inside-only    rows=16  flagged=0  rc=0
  [PASS] third-party    rows=4   flagged=0  rc=0
  [FAIL] planted        rows=17  flagged=0  rc=0 wanted=1
  [PASS] no-subject     rows=3   flagged=1  rc=2
  PASS: 3/5
```

**Make attribution claim everything is ours** — the instrument now blames us for
the customer's Mail:

```
  [PASS] recorded       rows=22  flagged=9  rc=1
  [FAIL] inside-only    rows=16  flagged=3  rc=1 wanted=0
  [FAIL] third-party    rows=4   flagged=3  rc=1 wanted=0
  [PASS] planted        rows=17  flagged=4  rc=1
  [FAIL] no-subject     rows=3   flagged=3  rc=1 wanted=2
  PASS: 2/5
```

The two failures land on **different arms**, which is the part worth reading
twice: the arms are not five copies of one check. Blinding the boundary is
invisible to arms 2, 3 and 5; over-claiming attribution is invisible to arms 1
and 4. Neither mutant could hide behind the other.

## What this does not prove

Stated here rather than left for you to find, because the limits are the reason
to trust the rest.

- **It does not observe content.** It sees that a connection existed and where
  it went. What crossed it is a claim we make in
  `scripts/box_walk_probes/egress_hosts.tsv`, not a measurement.
- **A shared CDN address serves many tenants**, so matching a declared host is
  "consistent with", never "was".
- **Sampling cannot see a connection that opens and closes between two
  samples**, which is most of an install. That is why the declared ledger is
  built from call sites in the source and not from sampling alone.
- **It is TCP only.** No UDP, no DNS, no request proxied through another
  process.
- **These five readings exercise the instrument, not a release.** They prove it
  can fail. Whether a given build passes is a separate question, answered per
  cut by the same probe running against a real machine.
- **The inventory it joins against is still marked NOT PUBLISHED** in
  `docs/EGRESS_INVENTORY.md`, and that status is accurate: one section needs a
  measured run before we put a number on it. This page publishes the
  verification, not a finished claim about the product.

## Where the pieces live

| | |
|---|---|
| the instrument | `scripts/box_walk_probes/probes/no_unexpected_egress.sh` |
| the recorded capture | `scripts/box_walk_probes/fixtures/egress_2026-08-17_mid_install.tsv` |
| the declared destinations | `scripts/box_walk_probes/egress_hosts.tsv` |
| the inventory and its status | `docs/EGRESS_INVENTORY.md` |
| this proof | `tests/test_the_egress_proof_can_go_red.sh` |

The proof runs on every pull request, in
`.github/workflows/install-abort-and-egress.yml`. If it ever stops being
runnable, this page is a promise we are no longer keeping, and the build says
so before you have to find out.
