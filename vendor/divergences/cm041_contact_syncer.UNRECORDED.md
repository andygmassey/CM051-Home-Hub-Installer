# cm041/contact_syncer — divergence NOT captured by the patch

**Hand-built 2026-08-28. Board #530. NOT generated, and it must never be.**

`cm041/contact_syncer` carries `regenerate_forbidden = true`. Regenerating
`cm041_contact_syncer.patch` exports personal data from private CM041 into this
PUBLIC repo — see the row's `regenerate_forbidden_reason` in
`vendor/VENDOR_MANIFEST.toml`. So the patch can never be refreshed, and it has
therefore aged into a **false negative**: it records less divergence every time
the tree moves, while reporting nothing.

This file is the missing half, written by hand, **location and shape only —
never content, never a value**. It is a record, not an instrument: nothing reads
it, and it cannot be applied.

## Why a grep of the patch is not a safety check on this tree

A `grep <file> cm041_contact_syncer.patch` returning nothing means
**NOT RECORDED**. It does not mean **NOT DIVERGED**. On a `regenerate_forbidden`
row those are different statements, and the first reads as the second.

Any "check the recorded X" rule silently inherits the refresh policy of the
record it consults. Where refresh is banned, the check inverts toward "all
clear". That is the whole of #530.

**The only valid instrument here is a direct vendored-vs-source diff at the
pin.** That is what produced the table below.

## Method, so the numbers can be re-derived or refuted

- vendored tree: `vendor/cm041/contact_syncer` at CM051 `origin/main` `41f1c67d`
- source: `andygmassey/CM041-People-Graph` at the pin `f83d5aee`, in a detached
  worktree (CM041 never modified)
- excludes applied, as declared on the row: `tests/`, `__pycache__/`, `*.egg-info/`
- unified diff at `n=0`, so counts are changed lines, not context

```
EXAMINED shared=26   vendor-only=1   source-only=0
  identical            8
  DIFFER              18
    recorded in patch   6   (+455 -94)
    NOT RECORDED       12   (+134 -38, sum 172)
```

## The unrecorded 12

| file | + | − | sum |
|---|---|---|---|
| `carddav.py` | 80 | 0 | 80 |
| `linkedin_career.py` | 15 | 15 | 30 |
| `requirements.txt` | 21 | 5 | 26 |
| `facebook_events.py` | 4 | 4 | 8 |
| `google_calendar.py` | 3 | 3 | 6 |
| `twitter_contacts.py` | 3 | 3 | 6 |
| `whatsapp_contacts.py` | 3 | 3 | 6 |
| `backfill_photos.py` | 1 | 1 | 2 |
| `backfill_privacy.py` | 1 | 1 | 2 |
| `dedup.py` | 1 | 1 | 2 |
| `owner_node.py` | 1 | 1 | 2 |
| `places_ingest.py` | 1 | 1 | 2 |

The eight single-line and small symmetric deltas are consistent in shape with
the `b6ae1f91` namespace graft, which `regenerate_forbidden` makes permanently
unrecordable. `carddav.py` at +80/−0 is additive vendor-side work with no
upstream counterpart in the delta. **Neither characterisation is a content
claim; both are inferences from shape and should be re-measured before being
relied on.**

## A vendor-only file protected by NOTHING

`test_carddav_snapshot.py` exists in the vendored tree and has **no upstream
counterpart at the pin**. It is protected by neither available mechanism:

- `vendor/VENDOR_ONLY.tsv` rows naming it: **0**
- new-file hunks for it in the patch: **0** (of 649 lines)

`sync_vendor.sh` uses `vlib_patch_new_files` to tell a carried vendor-only file
from one lost by the tree swap. With no row and no hunk, **the next full sync
deletes it silently.** A row is added in the same change as this file.

Measured with controls, because a bare zero here would be worth nothing:
`VENDOR_ONLY.tsv` holds 24 non-comment rows and 3 for `cm019` added earlier the
same night, so the file is readable and the convention is live.

**And a correction, recorded because the wrong version is the more dangerous
one:** a first pass reported "1 contact_syncer row" in `VENDOR_ONLY.tsv`. That
was a **false positive from prose** — the matching row is
`cm041/test_vendor_import.sh`, whose *description* mentions contact_syncer. No
row protects any file under this tree. The true count is zero.

## Limits

- The patch's own headers say 6 files / 24 hunks / +405 −44. The direct diff
  says +455 −94 for those same 6 files. **The patch does not reconcile with the
  tree at the pin**, which is consistent with 1 of its 17 `syncer.py` hunks
  failing to apply — a known, pre-existing condition, unchanged by the PII
  scrub in #1186.
- This file is a snapshot. It carries no freshness gate and nothing verifies it.
  It will age exactly as the patch did. Re-measure before trusting it; the
  method above is written down so that is cheap.
- `verify = "full"` on this row is therefore a claim the tree does not meet.
  Retiring that properly needs the CM041 owner, not a cut-time edit.
