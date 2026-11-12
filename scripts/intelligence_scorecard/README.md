# Intelligence scorecard

Is the Ostler assistant up to the bar on the things a tester felt it failed at?
27 scripted scenarios, each graded by deterministic checks, each reported as
PASS, FAIL or CANNOT-RUN. CANNOT-RUN is never a pass.

Files: `scenarios.py` (the spec, data only), `scorecard.py` (runner, scorer,
live driver), `stub_hub.py` (a canned Hub that proves the scorer works).
Self-test: `tests/test_intelligence_scorecard_selftest.sh`, run by
walk-record-gate.

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

Run time: 34 chat turns, 10 brief runs, 6 daemon restarts, 12 seeds. On a Mac
mini expect roughly 2 to 4 hours (a chat turn takes 2 to 5 minutes there). Measure
the first run and write the number here.

Without the box, check the scorer: `python3 scripts/intelligence_scorecard/scorecard.py --self-test`.

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
