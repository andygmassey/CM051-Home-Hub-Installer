# Design note: does the daemon RUNNING on a box match the pin that was cut?

Status: design only. No probe exists yet. This note settles the assertion shape
so the probe gets built once, correctly.

Author: Archie, 2026-08-13.

## The gap, and why three existing gates do not close it

Four stages, and each one can fail on its own: `merged -> delivered -> wired -> run`.
Everything we have sits on the cut side of the `delivered` boundary.

| gate | stage | compares |
|---|---|---|
| `scripts/verify_cut_freshness.sh` :: `check_daemon_recency()` | cut time | the cut's pin vs `ostler-ai/ostler-assistant` tracked-branch HEAD |
| `scripts/verify_commit_parity.sh` | post-cut | daemon commit vs Tauri wrapper embedded-frontend commit, both inside the cut |
| `scripts/box_walk_probes/` | on box | `people_seed_and_retrieval.sh` only; nothing about daemon version |

None asks whether the binary EXECUTING on a box matches the pin that was cut.
Cutting and installing are separate events, so a cut can be perfectly fresh and
the box still run something older.

Measured on Andy's Mini 2026-08-13, which is what prompted this note:

    executing binary (pid 29872)   built 2026-08-10 22:34:58 +0800
    D038 parser f78f56b5           landed 2026-08-10 23:49:15 +0800   (+74 min)

The executing artefact was resolved from the live process, not assumed from a
path. The same timestamp shows the D017 scrub (Aug 9 20:55) IS in that binary,
which is what makes it a usable fixture: one binary, one fix in, one fix out.

## Why this is one cause and not three bugs

v1018-D038 is not running on the box. D011's remedy is a box recompile. D014c is
merged in CM051 and absent from the installed cm048 (task #330). Three rows,
three separate investigations, one stage. An uncovered stage never presents as
itself, only as a run of unrelated-looking rows that each stall at the last step.

## The decision: what should the probe assert?

**Option A, strict equality.** RED unless `running == last cut pin`.

Rejected. A customer who has not taken the latest update yet is not a defect, and
Sparkle delivery is asynchronous by design. On a customer box this fires RED as
the NORMAL state, and a gate whose RED is the normal state gets ignored, then
deleted. That is exactly how the previous daemon-recency check died: it was
anchored to a hand-maintained branch name, started reading "diverged, ahead 3,
behind 123" on a healthy daemon, and was removed at v1.0.16 rather than
re-anchored (see the header of `verify_cut_freshness.sh`).

It is also the v1018-D011 failure shape: a gate stricter than the defect it
names. That one flagged 81 hits of which 36 were legitimate middle names.

**Option B, directional. RECOMMENDED.** RED only when the running binary is
BEHIND the last cut pin. Equal is green. Ahead is green with a note, because a
developer box legitimately runs a locally-built newer daemon and that is not a
delivery defect.

This is quiet on a fresh install, quiet on a dev box, and loud in exactly the
condition that has now bitten three rows.

## Contract

Exit codes follow the house convention, and the third is the load-bearing one:

    0  running is at or ahead of the pin
    1  running is BEHIND the pin            <- the defect this exists to catch
    2  CANNOT-VERIFY                        <- never a pass

`2` is required whenever the probe cannot look: pin unresolvable, no daemon
process found, binary present but its commit not determinable. A gate that
cannot look must not return a verdict. Two failures this week came from probes
that answered confidently while blind.

## Two traps the implementer must avoid

**Do not identify the binary by symbol presence.** `strings <binary> | grep` on
an optimised Rust build returns 0 for a symbol that IS compiled in. Verified
2026-08-13: the D038 symbol AND a control symbol known to be present both
returned 0. That probe cannot see either, so its answer is a cannot-run, not an
absence. Use the commit recorded in the artefact (`build-info.json` / the
`.sha256` sidecar chain already relied on by `check_daemon_recency`), or fall
back to build timestamp vs commit date.

**Resolve the executing artefact, do not assume the path.** Take the live pid and
read its `comm`, then confirm that path is the file being measured. Presence at a
known path is not proof that it is the copy that runs.

## Positive control, non-negotiable

The probe ships with a demonstrated RED before it is believed. Andy's Mini as of
2026-08-13 is the fixture: a binary at `2026-08-10 22:34:58 +0800` against any
pin newer than that must exit 1. If it cannot be shown failing on that input, it
is not a gate.
