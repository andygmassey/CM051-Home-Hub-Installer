# ostler_fda: divergence not captured by the patch

`ostler_fda` has a generated patch (`ostler_fda.patch`) and `regenerate_forbidden`
stands, so hand edits made after it are recorded here, by location and shape.

## 2026-10-24: strip tracking params at ingest (CM051 #3043; upstream HR015 #1176, OPEN)

Pin NOT moved. Grafted ahead of the upstream merge. Upstream head at graft:
HR015 #1176 5c9f5eae.

- `url_clean.py`: NEW file, byte-identical to `ostler_fda/url_clean.py` at 5c9f5eae
  (diff -q against the upstream blob: identical, 106 lines). `strip_tracking(url)`
  removes known tracking params (utm_*, fbclid, gclid, host-scoped si/spm, text
  fragments); a URL with nothing to strip is returned byte-identical.
- `chrome_history.py`, `safari_history.py`, `safari_bookmarks.py`: one import of
  `strip_tracking` and the read of each row's url wrapped in it (one line each).
- `pwg_ingest.py`: one import; `ingest_browser_history` and the bookmarks ingest wrap
  the url read in `strip_tracking`, so the point id (the dedupe key) is the cleaned
  url, which also cleans JSON files written by an older extractor.
- Proof: `tests/test_url_clean.py` (copy parity with the cm041 copy, readers, sink
  dedupe, 4 mutants) and `tests/test_backfill_strip_tracking_urls.py`, wired in
  `url-clean.yml`.
- Retire: when HR015 #1176 merges, re-pin past it; these edits are then source.
