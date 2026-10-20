# ostler_fda: divergence NOT captured by the patch (streaming history)

`vendor/ostler_fda` is `HR015 ostler_fda @ c4e7396f` plus
`vendor/divergences/ostler_fda.patch`. Two vendored files below carry a change
that exists on an HR015 branch (PR "recognise streaming and listening taste
from browser history") and therefore on no commit at or before the pin, so the
pin-relative patch cannot describe them. Declared here so the undescribed-
divergence gate has something to find, and so the next re-vendor knows the
bytes are meant to match the source PR.

## What changed

- `vendor/ostler_fda/streaming_history.py`: NEW. Byte-identical to
  `ostler_fda/streaming_history.py` in the HR015 PR (compare with `cmp`).
  Pure stdlib, no network. Recognises Netflix, Prime Video, Max, Disney+,
  Apple TV+, YouTube and YouTube Music visits from URL shape plus page title,
  one preference per viewing session, no watch time.
- `vendor/ostler_fda/pwg_ingest.py`: ONE hunk, identical text to the HR015
  PR's hunk: `ingest_streaming()` inserted before the iMessage social-graph
  section, and `("streaming", "ingest_streaming")` after the `bookmarks`
  entry of `_INGEST_DISPATCH`. Nothing else in the file moved.
- `vendor/ostler_fda/catchup_browser.py` (vendor-only file, no upstream):
  calls `pwg_ingest.ingest_streaming` on each catch-up window, so history
  older than the install window reaches the same preferences path.
  HR015 has no `catchup_browser.py` at all (checked: `git ls-tree -r
  origin/main` has no catchup file), so the HR015 twin of this PR cannot carry
  this hunk and the two PRs are NOT byte-identical by design: HR015 gets
  `streaming_history.py`, the `pwg_ingest` hunk and the HR015 tests; CM051
  adds this hunk and `tests/test_streaming_history_vendored.py`. The
  `pwg_ingest.py` and `streaming_history.py` bytes ARE identical (`cmp`).

## Proof

- `tests/test_streaming_history_vendored.py`: runs the vendored copy, and
  feeds the written payloads through the REAL vendored
  `project_preferences.to_triples` and `interest_profile.compile_profile`.
- Wired by `.github/workflows/streaming-history.yml` and a TEST_WIRING row.

## Retire when

HR015 merges the PR and a re-vendor moves the pin past its merge commit: the
two shared-file hunks then ARE source, and this file is deleted.
