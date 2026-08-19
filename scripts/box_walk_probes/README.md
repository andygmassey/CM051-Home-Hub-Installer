# Box walk probes

Automated checks that run against a freshly installed Hub and answer questions a
human walking the box cannot answer by looking.

```sh
# on the box
./run_box_walk.sh

# from anywhere
OSTLER_BOX_HOST=user@192.168.1.215 ./run_box_walk.sh

./run_box_walk.sh --list              # what each probe asks
./run_box_walk.sh --only pair_state   # one probe, substring match
```

Exit code is 0 only when `FAIL` and `BROKEN` are both zero.

## What this suite is for

The human box walk covers what a person can see: does it install, does the modal
appear, does the assistant answer. This suite covers the opposite — defects
whose failure mode is **invisible at install time**:

- a LaunchAgent that works today and vanishes at the next reboot
- a panel that renders `unknown` instead of erroring
- a pair state that says "connected" over an empty device table
- a summary that reports clean over a log that is not

Every one of those looks like a healthy box.

## Two directories, and what each one means

```
probes/*.sh    every probe with a --self-test negative control.
               run_box_walk.sh globs THIS directory and nothing else,
               because phase 1 demands a --self-test from everything it finds.
*.sh           people_seed_and_retrieval.sh, alone. A real 735-line
               implementation with graded exit codes and no --self-test,
               so the runner would mark it BROKEN and discard its result.
```

The split is deliberate. What was not deliberate, and is fixed in #778, is that
the cut gate `scripts/verify_cut_manifest.py` used to resolve `probe: <name>`
against the flat directory ONLY. The gate and the runner therefore had **zero
probes in common**: the gate could resolve only the probe the runner never
executes, and the seven the runner does execute could not be named by any
manifest, so nobody wrote the rows. Nothing failed. There was nothing to fail.

The gate now searches `probes/` first and the flat directory second, and
`test_every_probe_on_disk_is_declared_in_permanent_manifest` fails if a probe
lands here without a `permanent.yaml` row. Adding a probe means adding a row.

Giving `people_seed_and_retrieval.sh` a `--self-test` and moving it into
`probes/` would collapse the two directories into one, and is the right end
state. It is not done here.

## The rule this suite is built around

`people_seed_and_retrieval.sh` is not replaced by this framework.

What it does not have -- and what none of the gates that burnt four consecutive
release tags had -- is a **negative control**. Nothing in it, or in them, ever
demonstrated the ability to return a FAIL. That is the gap this framework
closes, and it is the only gap it claims to close.

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
| `people_count_agreement` | do the graph and the API agree on the count? | #273 |
| `daemon_is_listening` | does the gateway accept connections, and can the daemon load its config at all? | #363 |
| `installed_bundle_seal_intact` | does the installed bundle's signature still verify? | #375 |
| `people_seed_and_retrieval` | can a seeded person be retrieved through the tool-call path? (flat, no `--self-test`) | v1.0.12 |

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
| `OSTLER_FRESHNESS_URL` | `http://127.0.0.1:8089/doctor/api/freshness` | freshness panel |
| `OSTLER_OXIGRAPH_URL` | `http://127.0.0.1:7878/query` | SPARQL endpoint |
| `OSTLER_PEOPLE_TOLERANCE_PCT` | `2` | allowed people-count drift |

The install log lives under `$HOME/.ostler/`, per `install.sh:962`. It is **not**
under `$HOME/Documents/Ostler/logs/` — that path was searched twice during the
v1.0.31 walk and reported a false absence both times.

## Compatibility

Runs under **bash 3.2**, the system bash on macOS and the shell the installed
box provides. No associative arrays, no `mapfile`, no `${var,,}`. A syntax error
in a probe means it never ran, which is the exact failure this suite exists to
prevent, so `bash -n` every probe before committing it.
