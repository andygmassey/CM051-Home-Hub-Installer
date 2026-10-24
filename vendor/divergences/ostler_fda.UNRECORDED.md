# ostler_fda: divergence not captured by the patch (ingest contract, 2026-10-22)

`ostler_fda` has a generated patch (`ostler_fda.patch`). This file records ONE
further hand edit made after it, so the divergence gate has something to find.
Regenerating the patch was not attempted: its source ($HR015/ostler_fda) has
advanced past the pinned sha, which `regenerate_divergence_patch.sh` refuses as
a re-pin and not a graft.

## What changed

`vendor/ostler_fda/pwg_ingest.py`:

- New helpers `_compartment_int`, `_owner_user_id`, `_iso_or_none`, directly
  after `DEFAULT_PRIVACY`.
- `ingest_bookmarks`: `compartment_level` is an int (was the string "L2"),
  `observed_at` is the bookmark's `date_added` or None (was the import time),
  `extra.observed_at_known` added, `user_id` set when the owner is known.
- `ingest_social`: same level and owner change; `observed_at` is the latest
  `last_message` over the handle's 1:1 conversations (was the import time).

## Why it matters

Derivation decays from `observed_at` and attributes by `user_id`. Measured on
a walk box 2026-10-22: 4,723 bookmark points and 37 iMessage points carried
the import time as their event time, had no `user_id`, and stored the level as
a string while every CM019 writer stores an int.

## Owed upstream

Yes: HR015 `ostler_fda/pwg_ingest.py`. Retire this file when the same change
lands there and the tree is re-pinned past it.

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
