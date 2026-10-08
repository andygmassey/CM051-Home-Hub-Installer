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

## Added 2026-10-02, CM051 v1.0.107 (ORM): one phone number, one person (CM041 #182, CM051 #2545)

`vendor/cm041/contact_syncer/syncer.py`, two hand-grafted edits from CM041
86499ed6. This tree is `regenerate_forbidden`, so the patch cannot record them.

1. The Qdrant payload `"phones"` list is normalised to E.164 with
   `normalise_phone(..., self.resolver.default_country_code)`, and empty values
   are dropped, so the payload agrees with the Oxigraph identifier it mirrors.
2. The Oxigraph create path keeps a `seen_phones` set and writes a number
   once, even when one vCard carries it in two formats.

The normalisation on the create and update paths (the BW-1 graft) was already
here and is unchanged.

### What a future sync must preserve

Both edits. Retire this entry when the pin moves past 86499ed6.

## Added 2026-10-02, CM051 v1.0.107 (ORM): a kinship word never becomes a permanent displayName (CM041 #185, CM051 #2556)

`vendor/cm041/contact_syncer/relationship_labels.py` -- NEW FILE, reproduced
verbatim from CM041 main (the predicate, `_load()`'s default kinship set and
`_load()`/`explain()` plumbing; no logic change needed, so no divergence of
its own). `name_election.py` already used this predicate in this vendored
tree before this change; it did not exist at this tree's pin, so this entry
also newly vendors the file itself, not only the six call sites below.

Six write sites, each one hand-grafted (this tree is `regenerate_forbidden`,
so the patch cannot record them), all routing through the SAME
`is_relationship_label` rather than a new predicate:

- `instagram_social.py`, `facebook_friends.py`, `linkedin_connections.py`:
  `create_person_oxigraph` -- `fn = "" if is_relationship_label(...) else
  _escape(...)`.
- `linkedin_career.py`: `_create_person_from_endorser`, same shape.
- `owner_node.py`: `build_owner_sparql` -- special-cased. This function's own
  contract is "decline, never overwrite" (`INSERT..WHERE FILTER NOT
  EXISTS`), so a refused name skips the name clause ENTIRELY rather than
  inserting an empty string, which would satisfy the filter forever and
  permanently lock the owner out of a later, corrected name.
- `syncer.py`: `_create_person_oxigraph` (new node, `""` is safe) AND
  `_update_person_oxigraph` -- the sharper bug: the update path deletes
  `pwg:displayName` unconditionally then only re-inserts `if fn:`, so an
  incoming "Mum" used to DELETE an existing GOOD name and replace it with
  nothing. Fixed by dropping `pwg:displayName` from that run's delete set
  entirely when the incoming value is a relationship label, leaving
  whatever is already on the node untouched.

WHY: "Mum", "Wife", "Dad" and similar bare kinship/household terms say how
SOMEBODY refers to this person, not who they are -- and on a shared
household device that somebody is usually not the account owner. Matches
the WHOLE label only: "Mum Zhang" is a plausible real name and is never
touched.

A SEVENTH site, `identity_resolver/resolver.py`'s `create_person`, is
recorded separately in `WRITER_READER_MISMATCHES.UNRECORDED.md` (that
tree's own `unrecorded_divergence` pointer), not here.

### What a future sync must preserve

`relationship_labels.py` in full, the import in each of the six files
above, and every write-site guard described. Guarded by
`tests/test_kinship_label_write_guard_vendored.py` (CM051 repo root,
mirroring CM041 PR #185's own test suite). Retire by landing CM041 #185
and re-pinning.

## Added 2026-10-02, CM051 v1.0.107 (ORM) -- `cm041/contact_syncer`, a non-phone value never reaches identifierType "phone" (CM051 walk-defect D)

`vendor/cm041/contact_syncer/syncer.py`. A cold v1.0.107 install walk found 8 of 3,307 phone identifiers on the box
were exactly 14 digits -- a WhatsApp-LID/internal-id shape, never a phone
number -- all on this file's own `id_<person_id>_phoneN` identifier naming.
`normalise_phone()` is a pass-through formatter: when `phonenumbers` cannot
parse/validate a value it returns the ORIGINAL STRING UNCHANGED rather than
refusing it, so a vCard "phone" field holding a LID or another app's
internal id sailed straight through into `identifierType "phone"` at all
three of this file's phone-writing sites.

Fix: gate all three on the new `is_possible_phone` (see
`WRITER_READER_MISMATCHES.UNRECORDED.md`'s `cm041/identity_resolver` entry
for why `is_possible_phone`, not the stricter `is_valid_phone`), added
immediately before each existing `normalise_phone(...)` call:

- the Qdrant payload's `"phones"` list comprehension (filter clause)
- `_create_person_oxigraph`'s phone-identifier loop (`continue` on refusal)
- `_update_person_oxigraph`'s phone-merge loop (`v = None` on refusal)

Matches CM041 PR #186 (upstream, not yet merged at time of writing).

NOT GRAFTED into the repo-root (dev-tree) `./contact_syncer/syncer.py`
twin: that tree's three phone-writing sites do not call `normalise_phone`
at all (writes the raw vCard value directly), which is a separate,
pre-existing, larger gap -- the dev-tree twin never received the #2545
normalisation graft either. Flagged, not fixed here: the dev-tree twin is
not what `gui/project.yml` bundles into the shipped app (see this file's
and `tests/test_a_second_contact_card_cannot_be_written_onto_one_person.py`'s
own history), so it is not the surface the walk measured.

### What a future sync must preserve

The `is_possible_phone` import and the three gate checks listed above.
Guarded by `tests/test_vendored_syncer_refuses_a_non_phone_value_as_a_phone_identifier.py`
(CM051 repo root, mirroring CM041 PR #186's own test suite). Retire by
landing CM041 #186 and re-pinning.

## Lane 18 forget tombstone

See the Thirteenth graft in cm041_assistant_api.UNRECORDED.md: the tombstone check in this tree (forget_tombstone.py, and the "forgotten" skip at each create path) is grafted from CM041 PR #200 with the rest of that graft.
