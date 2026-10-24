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

## 2026-10-24: I22b, one-time all-day backfill for Meeting nodes written before I22

New file `vendor/ostler_fda/allday_backfill.py`, called once from the hourly tick in
`install.sh` after `ingest_all`, only when that tick's calendar extract was `ok`. It adds
`pwg:meetingAllDay` to `pwg:Meeting` nodes that have none, matched to a wide (5 year)
re-read of the calendar by the same uuid5 `ingest_calendar` uses. Adds only: no deletes,
no rewrite of an existing flag, no new Meeting or Person. Marker
`~/.ostler/state/allday_backfill_v1.done`; failures write no marker and retry next tick.

Why: the tick re-ingests only the extract window, so older all-day Meetings stay unflagged
and the Timeline shows them as timed.

Owed upstream: yes, HR015 `ostler_fda/allday_backfill.py`. Retire when it lands there and
the tree is re-pinned past it.
