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

---

## BLOCKER found on measurement: the probe above cannot be built yet

Added 2026-08-13, after measuring the box rather than assuming the artefact
carried what the release does.

The contract above assumes the installed daemon can be resolved to a commit. On
Andy's Mini today it cannot. Measured:

    ~/.ostler/OstlerAssistant.app/Contents/Info.plist
        CFBundleShortVersionString   0.4.1
        CFBundleVersion              0.4.1
    ostler-assistant --version       ostler 0.4.1
    build-info.json in the bundle    ABSENT
    build-info.json under ~/.ostler  ABSENT  (control: 45 entries listed, probe can see)
    only install-time record         .installer-tree-created, Aug 9 00:40, 126 bytes

The binary was built 2026-08-10 22:34 while the pin was in the 0.4.5x range, so
the version string is not tracking the build either. That is task #254 and it
means version cannot be used as the discriminator even as a fallback.

**Consequence: there is no way, on a customer box, to say which daemon is
installed.** Not by commit, not by version. That is the actual root blocker
under every delivery-stage failure we have been chasing one row at a time, and
it is larger than this probe.

### Why the provenance is missing, and where it belongs

`check_daemon_recency` reads `build-info.json` from the RELEASE artefact. The
install does not carry that forward, so provenance stops at the release boundary
and the installed copy is anonymous.

It must not be fixed by writing the record INSIDE the .app. A signed bundle
cannot hold a mutable record: it drifts by construction and invalidates the
signature. The record belongs in the writable directory of the component it
describes, which here is `~/.ostler/`.

### Prerequisite, which is now the real work

`install.sh` must write the daemon's identity at install time, into a writable
record outside the signed bundle. Minimum content:

    daemon_commit    the commit the installed binary was built from
    daemon_pin       the tag/pin it was installed from
    installed_at     timestamp
    source           dmg | sparkle | manual

Only once that record exists can the running-vs-pin probe read it and compare.
Until then the probe would have to return `2` (CANNOT-VERIFY) on every box,
forever, which is not a gate.

### Revised sequencing

1. `install.sh` writes `~/.ostler/daemon-provenance.json`. **<- do this first**
2. Sparkle's update path writes it too, or the record goes stale on every
   auto-update and reintroduces exactly this defect one release later.
3. The probe in this note reads it and applies the directional contract.
4. Positive control: the Mini as of 2026-08-13 has NO record, so step 1 is
   verified by the record appearing with a commit that matches the installed
   binary, not by the installer exiting 0.

Recording the measurement rather than the assumption, because the version
string looked authoritative and was wrong twice over.
