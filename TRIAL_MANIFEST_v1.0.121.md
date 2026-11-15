# v1.0.121 integration manifest

Branch `integration/v1.0.121-trial`, built on `origin/main` a03122e5d664d6f60bd8d2edf2701fb04e60d8f0
(which already carries #3241 and the hub-v0.5.31 re-pin #3243). Every constituent was merged with a
MERGE COMMIT (no squash, no rebase), in the order below, at the head read with
`gh pr view N --json headRefOid` at the moment of its merge.

| order | PR | head sha (read at merge time) | read at (UTC) | title |
|---|---|---|---|---|
| 1 | #3232 | `77de7542170a9bb8dffefd389ef4e5c3a97c7ccc` | 2026-10-30T07:24:06Z | reminders: a valid todo is never dropped for length (v1.0.121) |
| 2 | #3239 | `7ea9846356e3899629d9be1b3f0b116c1d8fc5ce` | 2026-10-30T07:24:10Z | resolver: a "different people" decision blocks the converge re-merge and the ingest re-merge (v1.0.121) |
| 3 | #3230 | `4f7fa1be1a4c5536c76c81e55712b6ba82edf2ae` | 2026-10-30T07:24:14Z | derive tick: record every early exit with its cause, and a ceiling that runs it under taskpolicy -b (v1.0.121) |
| 4 | #3231 | `6143afaa5c1d8db4e141c9c5975ca8ea87167e74` | 2026-10-30T07:24:18Z | walk harness: two-cards probe CANNOT-RUN on a vacuous graph; triage never baselines a vacuous pass |
| 5 | #3228 | `7bb78bdc4db82905a82595766d5f53a080942b42` | 2026-10-30T07:24:21Z | harness: declare com.ostler.derive-preferences in the install manifest |
| 6 | #3229 | `cd5cbd5bf60f7f9b48858c7ebf398f5e5e96ca42` | 2026-10-30T07:24:25Z | harness: customer-read assertion count is one integer |
| 7 | #3237 | `8e21c9631b3d0e8c74717ebccc6fdd74627e0311` | 2026-10-30T07:24:42Z | harness: todos probe text fits the product title limit |
| 8 | #3238 | `0d854f3a808f18abe32914f945c61480ee586110` | 2026-10-30T07:24:45Z | harness hygiene: shell-safe launchd read, print hdiutil stderr, prove no ostler-dmg leak |
| 9 | #3235 | `0cd9abfa1c87a6356ede84c0f552227cb287ad1e` | 2026-10-30T07:24:49Z | people stores: a merge deletes the loser's vector, undo restores it, the upgrade repair deletes only provable losers (v1.0.121) |
| 10 | #3236 | `da75bc688c598e904c30524c577ab79d5c09dbfe` | 2026-10-30T07:25:03Z | harness: grade reply debt only for resolved people; read the age-out window from shipped code |
| 11 | #3245 | `0b960a87373f29844884dcc1ae81ac95ed3ade32` | 2026-10-30T07:25:06Z | people count: one definition of a person; the probe counts the graph and the Doctor counts Qdrant with it (v1.0.121) |

Not included (awaiting approval at build time): #3244, #3240, #3234, #3242.

## Conflicts and how each was resolved

Both resolutions keep both sides; neither takes a whole side.

1. #3229 against #3241 (on main): `.github/workflows/hub-screens-and-106c.yml` (trigger paths list)
   and `tests/TEST_WIRING.tsv`. Each side adds one new test. Both lines kept; TEST_WIRING.tsv
   regenerated with `scripts/verify_test_wiring.sh --regenerate` (sorted), and
   `git diff --exit-code tests/TEST_WIRING.tsv` is clean after a second regenerate. Both run steps
   (merged without conflict) are present.
2. #3235 against #3239 (merged earlier in this branch):
   - `.github/workflows/exact-identifier-merge.yml`: each PR adds one test path (plus #3235's
     `tests/_fake_oxigraph.py`) and one pytest step. Both kept, #3239's first.
   - `vendor/cm041/identity_resolver/resolver.py`: the import line only. Resolved to
     `from . import forget_tombstone, merge_journal, retirement` plus
     `from .decisions import blocks_merge, load_duplicate_decisions_strict`. Every other hunk in
     resolver.py and batch_resolver.py merged without conflict.
   - `vendor/divergences/cm041_identity_resolver.UNRECORDED.md`: both new 2026-10-30 sections kept,
     #3239's first.
   Proof on the merged tree: the five resolver test files, including both PRs' new tests
   (`test_different_people_decision_blocks_remerge.py`, `test_a_merge_deletes_the_loser_vector.py`),
   63 passed, 1 skipped (vobject absent, an unrelated case), with pyoxigraph, qdrant-client and
   rdflib installed.
