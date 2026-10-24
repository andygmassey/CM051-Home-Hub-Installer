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
