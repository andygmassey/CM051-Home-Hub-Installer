# Intelligence scorecard

Is the Ostler assistant up to the bar on the things a tester felt it failed at?
27 scripted scenarios, each graded by deterministic checks, each reported as
PASS, FAIL or CANNOT-RUN. CANNOT-RUN is never a pass.

Files: `scenarios.py` (the spec, data only), `scorecard.py` (runner, scorer,
live driver), `stub_hub.py` (a canned Hub that proves the scorer works).
Self-test: `tests/test_intelligence_scorecard_selftest.sh`, run by its own
workflow `intelligence-scorecard-selftest.yml` (path-scoped; not inside the walk
record gate, not in any smoke tier). Scope row: `scripts/walk_promote_scope.tsv`,
advisory.

## Run it on the box, after the walk

Only on a box declared throwaway (the seeds stay in its graph):

    touch ~/.ostler/state/synthetic-box
    python3 scripts/intelligence_scorecard/scorecard.py --driver live --model qwen3.5:9b \
        --json ~/walkdriver/evidence/scorecard-$(date -u +%Y%m%dT%H%M%SZ).json

`--model` is required and must be the model the box runs, or the run refuses.
The model size is read from `ollama list`. To compare models, run the same
suite again with another `--model` after switching the box's model. Set
`OSTLER_SCORECARD_IMPORT_DIR` to a directory on the box to exercise the import
scenarios; without it they are CANNOT-RUN. Verbatim replies go to an owner-only
evidence directory (`~/.ostler/state/intelligence-scorecard/<utc>/`), never to
stdout. `--only P03,C02` runs a subset.

Run time (live, unmeasured): 34 chat turns, 10 brief runs, 6 daemon restarts, 12 seeds. On a Mac
mini expect roughly 2 to 4 hours (a chat turn takes 2 to 5 minutes there). Measure
the first run and write the number here.

Without the box, check the scorer: `python3 scripts/intelligence_scorecard/scorecard.py --self-test`.

## Verdicts and controls

- PASS: every check ran and held.
- FAIL: a check ran and the Hub did not do the thing. A product control (the
  output must show what the predicate is measured against) that is missing is
  also FAIL: the product omitted it. A dumb assistant that drops the control
  item too is therefore FAIL, not CANNOT-RUN.
- CANNOT-RUN: a seed could not be made or read back, the box has no
  writer or import dir, the model does not match, the assistant was
  unreachable, or a premise control failed (the setup did not reproduce the
  case, so there is nothing to grade).

Timing: `--self-test` and the stub prints seconds per scenario and a total. A
live run is dominated by chat turns and brief runs, not by the scorer.

## Memory-tier comparison (documented mode)

Every run records the box's physical RAM and RAM tier, the model's quantisation
and on-disk size, the resident model memory (peak and steady, from Ollama
`/api/ps`), ollama process RSS and CPU time (from `ps`, sampled every 2 s), and
time-to-first-token and total time per chat turn. A source that does not answer
prints `NOT INSTRUMENTED`, never 0.

One table, one row per model:

    # 1. save each model's run (the box runs ONE model at a time)
    python3 scripts/intelligence_scorecard/scorecard.py --driver live --model qwen3.5:9b --json r-qwen.json
    # 2. or let the runner do the switch for a list of models:
    export OSTLER_SCORECARD_SET_MODEL_CMD='/path/to/operator-switch-model.sh'   # called as: <cmd> <model>
    python3 scripts/intelligence_scorecard/scorecard.py --driver live --models qwen3.5:9b,gemma4:e2b --json-dir DIR
    # 3. the table, from saved runs
    python3 scripts/intelligence_scorecard/scorecard.py --table r-qwen.json r-gemma.json

The switch hook is the operator's: it must change the box's model and restart the
daemon. The runner then refuses to score unless the box really runs the named
model. A failed switch is a CANNOT-RUN row, never a silent run.

The RAM tiers come from what the installer does today: below 16 GB the install
aborts (install.sh:6472); 16 to 23 GB installs gemma4:e2b; 24 GB and up installs
qwen3.5:9b (lib/ostler-model-fit.sh:76-93, picker at :173, called at
install.sh:10223). The table prints the tier next to every score, so a 16 GB
result is read against the model that tier actually gets.

Caveat: the telemetry readers are stub-tested only. Their live field names
(`/api/ps` size, `/api/tags` details) and the `ps` filter are unverified on a box.

## What the founder reads

1. The TOTALS block: PASS / FAIL / CANNOT-RUN, split PLUMBING and REASONING.
   PLUMBING means a state, memory or context bug, fixable in code. REASONING
   means a model capability, where a larger model should help.
2. Every FAIL, by scenario id and check id. The reason names the needle index,
   not the reply. Open the evidence file for the words.
3. Every CANNOT-RUN reason. These are instruments that do not exist yet, not
   verdicts on the assistant. A CANNOT is not a pass and must not be quoted as one.

## Known gaps, measured on the source (2026-11-12)

- RSVP state is not modelled. `contact_syncer/google_calendar.py` reads ATTENDEE
  lines and ignores PARTSTAT and responseStatus; no RSVP route exists in
  ostler-assistant. C01 and C02 cannot be seeded live until one does.
- No calendar-event seed writer in this runner (P03, P04 need one). No
  conversation seed writer (G03). These are CANNOT-RUN, reported as such.
- Preferences are read at `/api/v1/preferences`. The write path is the assistant's
  own tool, which the scorecard exercises through chat.
- The day boundary is a daemon restart plus a fresh brief run. The box clock is
  not moved.
- Person facts written by `memory/assert` are not removed by this runner. The box
  must be throwaway. Todo seeds are removed.
- Nothing here measures whether an answer "feels intelligent". There is no LLM
  judge, so that dimension is not scored. The checks look for what was asked
  (the right item, no re-asked question, no invented time), not for style.

## Reused, not reinvented

`box_walk_probes/lib/wow_moments.py` (Hub and store HTTP, secrets, one-shot brief
job), `box_walk_probes/lib/assistant_chat.py` (config and model), and the seed
routes in `OS003/gates/seed/README.md`. The WebSocket session follows the framing
in `scripts/owner_score/owner_score.py`, extended to keep one conversation open.
