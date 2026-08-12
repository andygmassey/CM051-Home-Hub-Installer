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

## Implementation sites, located 2026-08-13

Both paths must write the record. Located so step 1 is a bounded edit rather than
a hunt through 19,688 lines.

**Fresh install: `_finalise_daemon_staging()`, install.sh ~line 14009.**
Its own header states the invariant: "EVERY path that stages a daemon into
`${ASSISTANT_APP_BUNDLE}` (DMG-bundled .app, DMG-bundled bare binary wrapped
locally, or the curl recovery download) MUST funnel through this gate". That is
the chokepoint, so one insertion covers all three fresh routes. Write the record
in the success arm, after `_verify_daemon_signature` passes and alongside the
existing quarantine strip, so an unverified bundle never gets a provenance
record.

**Upgrade / Sparkle: `_upg_stage_daemon()`, install.sh ~line 219.**
Stages to `~/.ostler/OstlerAssistant.app.new` via ditto, then a later arm swaps
it in. The record must be written on the SWAP, not the stage, or a failed
upgrade leaves a record describing a daemon that never became live. Note this
function deliberately returns non-zero with nothing moved on verify failure
(20/21/22), and that property must not be disturbed.

**The installer already knows the value it is failing to record.**
`OSTLER_ASSISTANT_VERSION` is in scope at the staging gate and is already
interpolated into the success message. What is missing is the commit and the
durable write, not the knowledge.

**A live lead worth following, not yet measured.** The run-source preflight
comment inside `_finalise_daemon_staging` names `v0.4.34 / v0.4.1` as known
`OSTLER_ASSISTANT_VERSION` pin-skew values, and warns that such a daemon passes
`--version` but clap-REJECTS `run-source`, so "every ingest tick would silently
no-op". The box reports exactly `0.4.1`. That may mean the Mini is carrying the
precise skew this gate was written to catch, which would make it an ingest
defect and not only a provenance one. I have NOT confirmed the daemon rejects
`run-source` on that box, so this is a lead, not a finding. Confirm before
acting on it.

### The run-source lead above is REFUTED. Do not chase it.

Tested on the box the same day it was raised, with controls on both sides:

    ostler-assistant run-source --help              rc=0, prints full help
    ostler-assistant setup --help                   rc=0   <- known-good control
    ostler-assistant <bogus-subcommand> --help      rc=2   <- known-bad control

Both controls behaved, so the probe discriminates and the rc=0 is real: clap on
the installed daemon KNOWS `run-source`. The v0.4.34/v0.4.1 pin-skew failure
described in the `_finalise_daemon_staging` comment is NOT present on this box.

Consequence, and it narrows an open task: `0.4.1` here is a LABELLING defect
(task #254, version string not tracking the build), not a capability defect.
Ingest ticks are not silently no-oping for this reason. Task #254 should be read
as provenance/cosmetic, not functional.

Left in the document deliberately. A refuted lead that is silently deleted gets
re-raised by the next person who reads the same suggestive comment, and they pay
the same investigation cost again.

## Step 1 has a prerequisite of its own: the commit never reaches the installer

Measured 2026-08-13, before writing the install.sh edit rather than after.

    grep -E 'DAEMON_COMMIT|daemon_commit|build-info|OSTLER_ASSISTANT_COMMIT' install.sh
        -> NO MATCHES

`install.sh` has no commit variable of any kind. `build-info.json` appears only in
`verify_cut_freshness.sh` and its test, where it is fetched as a RELEASE ASSET
over the API. It is not in the DMG payload, so nothing in the install path can
read it.

**Consequence: install.sh cannot write a commit today. It could only write
`OSTLER_ASSISTANT_VERSION`** -- and that is the exact field refuted above as a
discriminator, because the box reports `0.4.1` for a binary built 2026-08-10.
Shipping that record would produce a provenance file that cannot answer the one
question it exists to answer. Worse than nothing, because it would look
authoritative.

### Corrected sequencing

    1a. THE CUT stages the daemon commit into the DMG payload, beside
        OstlerAssistant.app. The cut already knows it: cuts/<tag>/cut.env
        carries DAEMON_COMMIT (e.g. v1.0.24 -> DAEMON_COMMIT=e0234e71c66d) and
        check_daemon_recency already resolves pin -> commit. The value exists;
        it simply is not carried across the DMG boundary.

    1b. install.sh reads that payload file and writes
        ~/.ostler/daemon-provenance.json, at the two sites already located:
          fresh    _finalise_daemon_staging()  ~14009, success arm after verify
          upgrade  the swap at line 455, `mv "$_UPG_APP_NEW" "$_UPG_APP"`,
                   NOT the earlier ditto-stage at ~224

    2.  the probe reads the record and applies the directional contract

Step 1a is the real head of this chain and it belongs to the cut, which is my
surface. 1b belongs to install.sh, which is TNM's.

### What must NOT be done

Do not ship 1b alone with a version-only record to "make progress". A record
whose only field is known-unreliable manufactures false confidence at exactly
the point where the system is currently honest about not knowing. The absence of
a record is a true statement today; a version-only record would be a false one.

## 1a fully specified: where the commit enters the cut

Measured 2026-08-13. The chain is now closed end to end; what follows is a
bounded edit, not an investigation.

**The cut Makefile does not know the commit either.** `grep -E '^DAEMON_[A-Z_]+ *[:?]?=' gui/Makefile`
yields VERSION, REPO, TARGET, TARBALL_NAME, TARBALL_CACHE, RELEASE_TAG,
RELEASE_URL, LOCAL_CACHE_DIR. No commit. So 1a is not "write a variable we
already have"; it is "fetch the sibling asset that carries it".

**`build-info.json` is a release asset on the same tag** as the daemon tarball
(`hub-v$(DAEMON_VERSION)` in `$(DAEMON_REPO)`), which is exactly how
`check_daemon_recency` already reads the commit. The cut fetches the tarball
from that release and ignores its sibling.

### The edit

`download-daemon` (gui/Makefile:428) acquires the tarball by THREE paths, and
all three need the sibling or the record is missing on whichever path a given
cut took:

    1. gh release download            --pattern "$(DAEMON_TARBALL_NAME)"
    2. curl + $GH_TOKEN               asset-id resolution via the releases API
    3. $(DAEMON_LOCAL_CACHE_DIR)      local pre-staged tarball (+ .sha256 today)

Path 3 already demonstrates the pattern: it copies `<tarball>.sha256` alongside
the tarball when present. `build-info.json` follows the same shape.

`stage-daemon` (gui/Makefile:509) then copies it into `$$SRC_DIR`
(`../assistant-agent/`), which becomes
`OstlerInstaller.app/Contents/Resources/assistant-agent/` in the DMG. That is
the directory install.sh already reads the daemon from, so 1b needs no new path
knowledge.

### One decision this needs, and my call

Older pins predate `build-info.json`, so a hard fail-closed on a missing sibling
would block cutting from them. My call: **fail closed, with an explicit
per-tag escape**, matching the hold_ack pattern the vendor trees, wiki images
and daemon recency all already use. A silent WARN here reproduces precisely the
defect this whole note exists to fix, and "the gate was noisy so we softened it"
is how the previous daemon-recency check died. A loud decision with a name on it
is the house style; a quiet default is not.

### Why this was not implemented in the same pass

This touches the cut's artefact-acquisition path, which is on the critical path
to shipping a DMG, and the correct change spans three acquisition branches plus
a fail-closed policy. It wants its own pass with room to run the cut-gate tests,
not the tail end of one. Specified rather than half-written, deliberately.
