# 2026-10-21: Facebook watched rows emit `facebook_watched` (personal-world-graph #419, 5d1cdf13)

Tree `cm019_preferences`. Pin HELD at 7fd66daf; 5d1cdf13 added to `hold_ack_shas` (grafted, pin held).

- `services/ingest/src/parsers/meta.py`: the single upstream hunk (the movie_tv Like rows from Facebook watched history use `source="facebook_watched"`), applied by exact replacement because the vendored file carries earlier CM051 grafts. Measured: the changed lines equal upstream's for this file. The upstream test file is not in the vendored set.
- Why not re-pin: main is 10 commits past the pin, nine of them the smart-prefs derive engine this row holds.
- Paired in the same CM051 change: the data_conservation `expected.json` movie_tv row moves from `facebook` to `facebook_watched`, and cm059_editor is re-pinned to 5f3e94ce (#36), which pins `facebook_watched` as observed and local-only.
- Retire: a re-pin past 5d1cdf13 once the smart-prefs hold is lifted.
