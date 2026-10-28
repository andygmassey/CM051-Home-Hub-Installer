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

## ingest_food (2026-10-23, food evidence for smart preferences)

- `pwg_ingest.py`: new `ingest_food(fda_dir)` and one `_INGEST_DISPATCH` entry
  `("food", "ingest_food")`, placed after `bookmarks`. It writes NO point itself. It links
  (symlink, no copy of the large mail export) exactly the extracts the CM019
  `food_evidence` parser claims (`calendar_events.json`, `apple_mail.json`,
  `safari_history.json`, `safari_bookmarks.json`, and `imports/email/*.mbox.txt`) into a temp
  dir and calls the existing `apple_music_refresh.run_cm019_ingest` once. The writer, the
  privacy filter and the embed stay CM019's: one writer path.
- Counts only: status ok, error or no_data, and the number staged.
- Proof: `tests/test_vendored_food_evidence_reaches_smart_preferences.py` (wired in
  `derived-preferences.yml`), RED on main (no `ingest_food`), GREEN here.
- Retire: when the same function lands in HR015 `ostler_fda/pwg_ingest.py` (follow-up, size S)
  and the tree is re-pinned past it.

## 2026-10-24: I22, the calendar ingest writes the calendar's all-day flag

`vendor/ostler_fda/pwg_ingest.py`, `ingest_calendar`, in the Meeting-node triples right
after `pwg:meetingDate`. When the extract row carries a bool `is_all_day` (every row
`extract_all.py` writes does, from `CalendarEvent.is_all_day`), the node gains
`pwg:meetingAllDay "true"|"false"^^xsd:boolean`. Nothing else changes.

Why: `meetingDate` is the full start. Without the flag the Timeline could not tell a timed
meeting from an all-day item, and the app showed every past meeting as "All day" (I22, F&F
TestFlight walk 2026-10-24). The reader half is the cm041/assistant_api graft of the same date.

Owed upstream: yes, HR015 `ostler_fda/pwg_ingest.py`, the same seven lines (HR015 PR linked
from CM051's I22 PR). Retire when it lands there and the tree is re-pinned past it.
