# ostler_fda: ingest_food (2026-10-23, food evidence for Smart Preferences)

Tree `ostler_fda`. Pin NOT moved; the divergence patch is NOT regenerated
(`regenerate_forbidden`, unchanged). This is a DIVERGENCE from source at the pin.

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
