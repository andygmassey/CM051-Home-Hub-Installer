# Box walk probes

Automated checks that run against a freshly installed Hub and answer questions a
human walking the box cannot answer by looking.

## ▶ BEFORE ANY OF THAT: WALK THE DMG ITSELF

```sh
scripts/walk_dmg.sh <path-to.dmg>
```

The suite below needs a box that has already been installed onto. **Everything
in this file assumes the artefact was worth installing**, and v1.0.45 proved
that assumption can be false: it was correctly signed, stapled, and accepted by
Gatekeeper as `source=Notarized Developer ID`, and it bricked the Mac it was
installed on.

`walk_dmg.sh` walks the artefact first. Its arm 8 runs the bundle and checks
whether it survives its own first use, which is the only arm that catches that
class. On v1.0.45 five arms pass and arm 8 vetoes.

## ▶ AFTER A DMG WALK, RUN THIS ONE COMMAND

```sh
scripts/post_walk_qa.sh <box-host> [cut-version]

scripts/post_walk_qa.sh <user>@<hub-host> v1.0.38
```

**`scripts/post_walk_qa.sh` is the post-walk QA suite.** It is the single entry
point that joins the two halves that existed separately and were never invoked
together:

| half | what it checks |
|---|---|
| `run_box_walk.sh` | every probe in `probes/`, each with a negative control first |
| `verify_cut_manifest.py --require-runtime-proofs` | the cut's manifest rows, re-driven against the real box |

Exit codes, and the middle one is the point:

| rc | meaning |
|---|---|
| 0 | clean walk — everything ran, everything passed |
| 1 | at least one real FAIL |
| **2** | **PARTIAL — nothing failed, but not everything ran. Coverage was LOST. Not a pass.** |
| 3 | usage error, or the box was unreachable (nothing was measured) |

`<box-host>` is required and there is no default. A suite that silently falls
back to "this machine" is how `installed_bundle_seal_intact` once ran its
self-test on the wrong computer, found no Ostler bundles, and reported BROKEN
instead of a verdict.

**And it was worse than the self-test.** v1.0.46 BOM row 6 recorded a
contradiction that blocked a claim: the probe reported all three bundles
`MISSING` from `/Applications` while a direct SSH read found
`/Applications/Ostler.app` present. The probe was the wrong reader, and not
because it was denied — it named no `ssh`, no `box_run` and no
`OSTLER_BOX_HOST`, so `[[ -d ... ]]` had always been a question about the
operator's own laptop. Pointed at a hostname that does not resolve, it still
produced a confident three-line verdict.

Two rules came out of it, and they apply to every probe here:

1. **Reach the box through `box_run` / `box_run_v`.** A probe that stats a path
   directly is measuring whichever machine invoked it.
2. **A reader must print what it looked at.** `lib/bundle_inspect.py` is the
   reference shape: hostname, uid/euid, transport, SIP and TCC state, the
   RESOLVED path after expansion, the raw errno and strerror of any failing
   syscall, and — for an absence — the ancestor directory it enumerated and how
   many entries were in it. `PRESENT` / `ABSENT` / `CANNOT-LOOK` are three
   verdicts, and **a refused read exits 78, never "missing"**. Pinned by
   `tests/test_a_denied_read_is_not_an_absence.sh`.

`box_run` discards the remote command's stderr; **`box_run_v` does not**. Use
the latter whenever the reason a read failed is part of the answer.

**Rule 1 broke again in 2026-09, and prose was all that had ever enforced it.**
`doctor_page_renders_for_a_customer` ran bare `curl` against `127.0.0.1:8089`,
which is the DRIVER's loopback, and recorded CANNOT-RUN on the v1.0.100 and
v1.0.101 walks saying "the Doctor is not serving: /api/v1/sources answered
000". The Doctor was serving both times, and
`source_status_artefact_is_served`, which GETs that same URL on that same box
through `box_run`, passed in the same walk. Two builds of coverage lost to a
connection the driver refused to itself, and the refusal named a cause the
probe had no instrument to see: `000` is curl reporting that no status line
arrived, and refused, timed out, proxied and never-issued all print it.

Pointing a probe at the box's LAN address is NOT the repair. The Doctor binds
`127.0.0.1` on the box deliberately, as the single auth boundary; the request
has to be ISSUED ON the box. Enforced from now on by
`tests/test_a_probe_must_measure_the_box_not_the_driver.sh`, which stubs `ssh`
and requires every HTTP read the probe makes to have crossed it.

**Why this file had to be written.** #719: nothing invoked `run_box_walk.sh` at
all. #713: every `box_walk_probe` manifest row had ALWAYS returned SKIP, and
SKIP does not fail a cut. The suite was not missing — it was **built and dark**,
which is why a human kept finding things by hand instead.

⚠️ The suite **writes**: `people_seed_and_retrieval` seeds a synthetic person
into the live store and cleans up on the happy path only (#829). Do not run it
against a box mid-demo.

---

```sh
# on the box
./run_box_walk.sh

# from anywhere
OSTLER_BOX_HOST=user@192.168.1.215 ./run_box_walk.sh

./run_box_walk.sh --list              # what each probe asks
./run_box_walk.sh --only pair_state   # one probe, substring match
```

Exit code is 0 only when `FAIL` and `BROKEN` are both zero.

## ▶ BROWSING CAPTURE: FORCE THE HARVEST, OR YOU WILL READ A TRUE ZERO

If the walk browses a page and then looks for it in `safari_history`, **it will not
be there yet, and the product is not broken.** Measured on `install.sh` 2026-09-02:

    com.ostler.fda-rerun plist (install.sh:14869)
      ProgramArguments  ${OSTLER_DIR}/OstlerAssistant.app/Contents/MacOS/ostler-assistant
                        run-source fda-rerun
      StartInterval     ${OSTLER_FDA_RERUN_INTERVAL_S}     (default 3600 = 1 hour)
      RunAtLoad         ABSENT -- 0 occurrences in that block

`RunAtLoad` appears 35 times elsewhere in `install.sh`, so the zero above is a real
absence in this plist and not a dead grep. **No RunAtLoad plus a 1-hour interval means
the first harvest tick is up to an hour after install.** The reader is incremental
(`vendor/ostler_fda/safari_history.py:120`, `WHERE hv.visit_time > ?`, checkpointed on
`last_visit`), so the just-browsed page IS picked up -- on the next tick, not now.

So between "browse a page" and "look in safari_history", force the harvest:

```sh
# SAFE: run the same program the plist runs, directly. No launchd involved.
"${OSTLER_DIR}/OstlerAssistant.app/Contents/MacOS/ostler-assistant" run-source fda-rerun
```

⚠️ **DO NOT use `launchctl kickstart -k` for this.** It BLOCKS on a penalty-boxed job,
which is a measured finding, not a worry: see
`experiments/kickstart_k_blocks_on_penalty_box.sh` in this directory, which
demonstrates it against a healthy control that returns fast. A walk that kickstarts a
penalty-boxed `fda-rerun` hangs, and a hung walk looks exactly like a slow one.

**WHY THIS SECTION EXISTS.** Without it the walk reads an empty `safari_history`,
records a FAIL, and the failure names browsing capture when the real answer is a
schedule. That is a true zero reported as a defect, and it costs a walk to discover.

**AND IT IS A CUSTOMER FACT, not only a walk fact:** a real customer's browsed page
appears within about an hour, at the next tick -- not instantly. That is fine for
history capture, but it is the actual latency and it should be described that way
rather than implied to be live.

## What this suite is for

The human box walk covers what a person can see: does it install, does the modal
appear, does the assistant answer. This suite covers the opposite — defects
whose failure mode is **invisible at install time**:

- a LaunchAgent that works today and vanishes at the next reboot
- a panel that renders `unknown` instead of erroring
- a pair state that says "connected" over an empty device table
- a summary that reports clean over a log that is not

Every one of those looks like a healthy box.

## One directory, and why it used to be two

```
probes/*.sh    every probe, each with a --self-test negative control.
               run_box_walk.sh globs THIS directory and nothing else,
               because phase 1 demands a --self-test from everything it finds.
```

There used to be a second population: `people_seed_and_retrieval.sh` sat alone
in the flat directory, a real implementation with graded exit codes and no
`--self-test`, kept out of `probes/` because the runner would have marked it
BROKEN and discarded its result.

**The cost of that split was total.** `run_box_walk.sh` globs `probes/` only, so
the one probe that asserts semantic people search actually works had never
executed in a box walk -- not once, on any cut. The other half of the same hole
is recorded in `verify_cut_manifest.py`: the manifest rows naming it fire only
when `OSTLER_BOX_HOST` is set, and it was set nowhere, so those rows "have
returned SKIP on every cut that has ever run". Two instruments, neither of them
ever pointed at the thing.

#778 fixed the resolution half: the cut gate now searches `probes/` first and
the flat directory second, and
`test_every_probe_on_disk_is_declared_in_permanent_manifest` fails if a probe
lands here without a `permanent.yaml` row. Adding a probe means adding a row.

The directories are now collapsed, which this file used to call "the right end
state ... not done here". Collapsing them was not a `git mv`: the probe had
to gain a `--self-test`, which meant every judgement inside it had to become a named
function over a response file, so the control can drive the same adjudicators
the live run uses without standing up a box. Its exit codes also became the
contract's `0 / 1 / 78` rather than a graded `2/3/4/5` that every caller only
ever read as "non-zero", and `OSTLER_BOX_HOST` unset now means **this machine**
rather than "refuse to report", which is what the rest of the suite means by it.

## The rule this suite is built around

None of the gates that burnt four consecutive release tags had a **negative
control**. Nothing in them ever demonstrated the ability to return a FAIL. That
is the gap this framework closes, and it is the only gap it claims to close.

The four burns were all one shape: a gate grepping inside a container that never
started; a test skipping on a runner with no docker and reporting SUCCESS; a
function returning 127, inverted into "refuse every tree". Each was an instrument
returning a confident verdict from a measurement that never ran.

> **A zero that means "did not look" is indistinguishable from a zero that means
> "found nothing", and the only defence is a control that must still fire.**

So phase 1 of every run tries to **break** every probe before trusting any of
them. Each is invoked with `--self-test`, which runs its real logic against a
known-bad fixture and must come back `FAIL`. A probe that cannot produce a
`FAIL` is marked `BROKEN` and its result is discarded. A probe that is silently
a no-op -- the classic `echo "TODO"; exit 0` -- is caught in phase 1 rather than
counted green in phase 2.

## Four outcomes, never one

```
PASS        the assertion held
FAIL        the assertion did not hold
CANNOT-RUN  a prerequisite was absent (exit 78) -- coverage lost, NOT a pass
BROKEN      the probe could not demonstrate a FAIL, so it is not trusted
```

`CANNOT-RUN` exists because a skip destroys information. "We did not measure
this" is something an operator needs to know, and a suite that folds it into
green is lying by omission. A run of 9 `PASS` and 3 `CANNOT-RUN` measured nine
things and did not measure three; the report says so in its own block.

## Writing a probe

Drop an executable in `probes/`. Source the contract, define `run_probe` and
`self_test`, end with `probe_main "$@"`.

```sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"
PROBE_NAME="my_probe"
PROBE_QUESTION="the one question this answers"

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing inspected"
    probe_examined "$n" "things inspected"       # the denominator, always
    [ "$bad" -gt 0 ] && probe_fail "$bad of $n <name the artefact measured>"
    probe_pass "all $n <name the artefact measured>"
}

self_test() {
    # Run THE SAME function the real probe uses, over a known-bad fixture.
    # Must reach probe_fail. If the scanner misses the planted defect, call
    # probe_pass with a message explaining that the control did not fire --
    # the runner reads that as BROKEN.
}
```

Three requirements, each earned the hard way:

1. **Print your denominator.** `probe_examined` is mandatory; reporting a
   verdict without it is refused outright. An unstated denominator is how "0 of
   0" reads as success.
2. **Absent prerequisite means `probe_cannot_run`, never a silent pass.** And a
   count of zero is usually a prerequisite problem, not a clean result — an
   installed Hub always has LaunchAgents, always tracks freshness sources,
   always has people. Zero means you are looking in the wrong place.
3. **Name the artefact you measured** in the verdict text, not the abstract
   condition. "found 0 plists in `$HOME/Library/LaunchAgents`" is actionable;
   "check failed" is not.

### Measure the surface the defect lives on

`launchd_no_ephemeral_paths` got this wrong twice on its way to being correct,
and both mistakes are worth knowing before you write your own:

- **v1 grepped raw XML** and flagged a healthy agent because a *comment* cited a
  `/tmp/` path. The defect lives in executable values; grep was reading prose.
- **v2 parsed with `plistlib`** and failed 8 of 20 agents as malformed. Those
  plists carry `--` inside XML comments, which the XML spec forbids but Apple's
  parser accepts — `plutil -lint` returns OK and the agents run with live PIDs.
- **v3 shells out to `plutil`.** launchd decides whether an agent runs, so
  launchd's own parser is the only authority that matters.

A probe stricter than the system it models invents defects. A probe looser than
the system it models misses them. Both cost the same amount of trust.

## Current probes

| probe | question | defect it exists for |
|---|---|---|
| `launchd_no_ephemeral_paths` | does any LaunchAgent execute from `/tmp`? | #177 |
| `install_error_honesty` | does the installer's summary agree with its own log? | #270 |
| `pair_state_agreement` | do the pairing signals agree with each other? | #265, #208 |
| `freshness_panel_has_dates` | does every source report a date, not `unknown`? | #349, #266 |
| `front_page_not_me_is_saved` | does a Not me tap from the Hub app's origin (`tauri://localhost`) land in `interest_corrections.json` and `card_states.json` and survive a reload? | #2470 |
| `people_count_agreement` | do the graph and the API agree on the count? | #273 |
| `daemon_is_listening` | does the gateway accept connections, and can the daemon load its config at all? | #363 |
| `installed_bundle_seal_intact` | does the installed bundle's signature still verify **on the box**, and can the reader prove what it looked at? | #375, v1.0.46 BOM row 6 |
| `people_seed_and_retrieval` | can a person seeded on the box be retrieved again through the route the daemon really uses? | v1.0.12 |
| `data_conservation` | per source and category, do IN (importer logs), STORED (Qdrant, Oxigraph, bundles) and SHOWN (wiki text, Doctor) agree, or is there an unexplained loss or duplication? | the 2026-10-15 sweep: about eleven silent drops, e.g. 68,314 of 70,667 music prefs hidden by one missing allow-list entry |

### data_conservation: how to run it

Read-only (GET, Qdrant scroll, SPARQL SELECT, file reads; never writes, never
creates a payload index). Verdicts per row: CONSERVED, EXPLAINED (a declared
exclusion with its reason matches the gap), LOST (fewer than expected, or than
the previous stage less declared exclusions), INFLATED (more than expected, e.g.
Oxigraph holding every like twice), KNOWN-GAP (declared, visible, non-failing),
NOT-MEASURED (an instrument could not read; CANNOT-RUN, never a pass). Exit 1 on
any LOST or INFLATED.

    # the walk runs it automatically (probes/*.sh is globbed). By hand, on the Studio marta80q install:
    OSTLER_BOX_HOST=marta80q@macstudio \
      OSTLER_CONSERVATION_PROFILE=chain \
      OSTLER_CONSERVATION_TABLE_OUT=/tmp/conservation.md \
      scripts/box_walk_probes/probes/data_conservation.sh

    scripts/box_walk_probes/probes/data_conservation.sh --self-test   # mutations MUST be LOST

Profiles live in `fixtures/data_conservation/expected.json`. `chain` (default)
compares the box with itself and is valid on ANY box: it expands one row per
(source, category) the preferences store actually holds, so a category nobody
listed is still checked. `full` is the golden profile for a box loaded with the
synthetic demo-life set plus the GDPR export fixtures (built by
`gen/build_conservation_expected.py` in the walkdriver tree, counts only). Denied
wiki rows are explained with CM044's own `preference_filter.noise_reason()`
loaded from the install; on a build without it those rows are NOT-MEASURED, not
assumed zero. Registered as `advisory` in `walk_promote_scope.tsv` until the
first golden-loaded walk calibrates `full`.

Each asserts **agreement or absence of a lie**, not a particular value. An
unpaired box is fine; a box claiming to be paired over an empty table is not. A
box with 12 install errors is fine if it says so; one claiming clean over the
same log is not.

## Environment

| variable | default | purpose |
|---|---|---|
| `OSTLER_BOX_HOST` | unset (this machine) | ssh target |
| `OSTLER_SSH_TIMEOUT` | `8` | ssh connect timeout, seconds |
| `OSTLER_INSTALL_LOG` | `$HOME/.ostler/logs/install.log` | install log |
| `OSTLER_LAUNCHAGENT_DIR` | `$HOME/Library/LaunchAgents` | agent directory |
| `OSTLER_HEALTH_URL` | `http://127.0.0.1:8089/doctor/api/health` | Doctor health |
| ~~`OSTLER_FRESHNESS_URL`~~ | -- | **removed.** No such route exists: the API at :8089 serves 57 routes and this is not one of them. `freshness_panel_has_dates` now reads the compiled wiki panel and `~/.ostler/state/settling_progress.d` directly, so there is nothing to point at. |
| `OSTLER_OXIGRAPH_URL` | `http://127.0.0.1:7878/query` | SPARQL endpoint |
| `OSTLER_PEOPLE_TOLERANCE_PCT` | `2` | allowed people-count drift |
| `OSTLER_PROBE_API_BASE` | `http://127.0.0.1:8090` | Assistant API, `people_seed_and_retrieval` |
| `OSTLER_PROBE_QDRANT_BASE` | `http://127.0.0.1:6333` | Qdrant, same probe |
| `OSTLER_PROBE_EMBED_BASE` | `http://127.0.0.1:11434` | Ollama embeddings, same probe |
| `OSTLER_SERVICE_TOKEN` | read from the box | overrides the on-box service token |

`people_seed_and_retrieval` WRITES to the box: it mints a synthetic person and
upserts a synthetic Qdrant point, then removes both and verifies the removal.
Every identity it uses is constructed -- reserved `.example` / `.test` domains
and Ofcom drama-range numbers -- and it sweeps before seeding so a crashed
earlier run cannot fake a pass. It is the only probe here that is not read-only.

The install log lives under `$HOME/.ostler/`, per `install.sh:962`. It is **not**
under `$HOME/Documents/Ostler/logs/` — that path was searched twice during the
v1.0.31 walk and reported a false absence both times.

## Compatibility

Runs under **bash 3.2**, the system bash on macOS and the shell the installed
box provides. No associative arrays, no `mapfile`, no `${var,,}`. A syntax error
in a probe means it never ran, which is the exact failure this suite exists to
prevent, so `bash -n` every probe before committing it.

## Safari on the walk account: seeded, source-absent, or FDA-blocked

`ingest_coverage` reads the box's own `~/.ostler/imports/fda/extraction_summary.json`
when `safari_history` answers HTTP 404 (no collection):

| extract status for safari_history | walk seed marker | verdict |
|---|---|---|
| `not_found` | not `planted` | CANNOT-RUN, SOURCE-ABSENT (Safari never opened, nothing to ingest) |
| `no_fda` | any | CANNOT-RUN, FDA-BLOCKED (macOS refused the read) |
| `ok`, `error`, anything else, or no readable summary | any | FAIL (v1.0.101 rule: a 404 over a source that was read is EMPTY) |
| `not_found` | `planted` | FAIL (the reader missed a file the walk put there) |

A FAIL elsewhere (another store EMPTY, dying top-up) still wins over these CANNOT-RUNs.

`scripts/ttywalk.sh` plants a SYNTHETIC `History.db` (example domains only,
`scripts/box_walk_probes/lib/safari_history_fixture.py`) into the walk account's
`~/Library/Safari` before install (`scripts/lib_walk_safari_seed.sh`) and records the
outcome in `~/.walk-safari-seed-run` (`planted(visits=N)`, `skipped-real-history-present`
or `cannot-plant:<reason>`). It never overwrites a History.db that lacks the synthetic
marker table. `~/Library/Safari` is TCC-protected: the plant can be refused over ssh, and
even a planted file is unreadable to an installer without Full Disk Access (status
`no_fda`). Which of these happens on a given walk account is NOT KNOWN until a walk runs;
the record says which, and neither outcome is read as a pass.
