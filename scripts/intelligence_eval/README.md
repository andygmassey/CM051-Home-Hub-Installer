# Intelligence eval: brief usefulness and owner knowledge (I4)

One command scores a brief or a judgement build in minutes, with no DMG cut.
Gates the I1 to I3 work (EVAL_INTELLIGENCE_SPEC section 3). Stdlib only.

    python3 -I scripts/intelligence_eval/run.py --self-test
    python3 -I scripts/intelligence_eval/run.py --mode synthetic
    python3 -I scripts/intelligence_eval/run.py --mode synthetic --model qwen3.5:4b --ollama http://127.0.0.1:11434
    python3 -I scripts/intelligence_eval/run.py --mode owner --host USER@BOX   # preflight, then CANNOT-RUN

Wired: `tests/test_intelligence_eval_selftest.sh` runs in `.github/workflows/owner-score-instrument.yml`.

## Modes

- **synthetic**: the `owner_synthetic_v1` fixture (24 invented people, owner "Test Owner"), a 30-day replay world generated from it (`world.py`, seed fixed). Runs anywhere; the controls and self-test need no model.
- **owner**: refuses unless the box answers as Mini16 (hardware UUID) and no walk is running. Then prints CANNOT-RUN with the reason. Owner aggregates are not produced yet (see "Not yet measurable").

## Brief metrics (brief_eval.py)

Each morning d (09:00), the builder sees only items visible at d. The scorer then looks at what happened in the two days after.

| metric | counts | denominator |
|---|---|---|
| acted_precision | picks the owner acted on in [d, d+2] | picks |
| acted_recall | acted-on items visible that morning that were picked | acted-on visible items |
| handled_shown | picks already closed before the brief | picks |
| stale_fact | picks citing a superseded wording | picks |
| guess_as_fact | inference items picked without guess=true | picks |
| duplicate | picks on a person already picked that morning | picks |
| phantom | picks whose id is not a real item | picks |

acted_recall rewards volume (a brief that picks four items beats one that picks two). Read it with picks per day, which is capped at 3.

## Owner knowledge (knowledge_eval.py)

Questions generated from the fixture (76 answerable, 12 absent). Each graded RIGHT, WRONG, FABRICATED or ABSTAINED. Fabrication is the worst error: a committed answer to a question the fixture cannot answer. Grading is text matching (WEAK, spec section 7).

## Controls (must hold; asserted by run.py)

- good: a hand policy over as-of data. bad: fixed four sections, reads the whole store, first wording only, an inference listed as a fact.
- phantom: the good policy plus one invented id a day, so the phantom metric is shown to move.
- knowledge oracle (all right), fabricator (commits on every absent question), abstainer (declines everything).
- Mutants in the self-test: a scorer that never counts acted picks, and a grader that calls every refusal fabricated. Both turn the self-test red.

## Not yet measurable

- A replay of the SHIPPED brief: the daily-brief route renders now only (zeroclaw-gateway pwg_proxy.rs:410). No as-of parameter.
- Ground truth from the owner's own stores: needs a ruling before any direct read.
- Owner knowledge questions: need the owner's own question file and a ruling on what leaves the box.

Synthetic data only. Nothing from a real box is written to this directory.
