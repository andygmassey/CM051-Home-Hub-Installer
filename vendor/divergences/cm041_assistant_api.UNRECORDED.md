# cm041/assistant_api: a divergence the patch tool REFUSED to record

**Hand-built 2026-09-19, CM051 #2220. Location and shape only, never content.**

Per-tree record, following `cm041_contact_syncer.UNRECORDED.md`. It does not
supersede `WRITER_READER_MISMATCHES.UNRECORDED.md`, which still stands, still
mentions `cm041/assistant_api`, and is still the pointer for `ostler_fda` and
`doctor`. Only this tree's pointer moved here.

It is a record, not an instrument. Nothing reads it and it cannot be applied.
Its whole job is to stop the next `sync_vendor.sh` deleting this edit without
anyone knowing it existed. That matters more here than on the other entries in
this directory, because the edit it protects is a GDPR Article 17 erasure.

## What diverges

`vendor/cm041/assistant_api/ical-server.py`, the function
`_forget_person_update`, and nothing else in the tree.

Board rows 960 and 2217. The shipped erasure deleted every triple where the
person is the SUBJECT and every triple where the person is the OBJECT. The
second removes a fact's LINK to the person and leaves the fact NODE, so the
sentence a customer asked to have erased stayed in the graph and kept being
returned by a reader that lists facts by `belongsToUser`.

The graft adds fact-collecting clauses that run BEFORE the link delete, scoped
by fact TYPE plus the fact-to-person PREDICATE, for both vocabularies. The
scoping is the design, not a detail: keying on any predicate instead erases a
meeting both people attended and a bystander's entire record through a
`spouseOf` edge, which is a worse defect than the one being fixed.

## Why it is GRAFTED rather than re-vendored

The vendored copy is 1,151 lines ahead of CM041 main (board row 2218), so a
re-vendor destroys shipped behaviour and no upstream fix reaches a customer
without a graft. `VENDOR_MANIFEST.toml` records `shipping_bugfixes_grafted` for
this tree. The same fix is still owed UPSTREAM so the two converge.

## The refusal, re-measured rather than inherited

Run 2026-09-19 against a CM041 worktree checked out at EXACTLY the pinned sha
`9be482d3`, so no upstream work could be folded in:

    CM041=<worktree at the pin> scripts/regenerate_divergence_patch.sh \
        cm041/assistant_api --write

It exited non-zero and wrote nothing. `vendor/divergences/cm041_assistant_api.patch`
is byte-identical before and after: 3,040 lines, 137,506 bytes, zero differing
lines. Nothing was published.

THE REASON IS THE ONE THAT MATTERS, and it is not about this fix at all. The
tool detected a value of personal-contact shape on the MINUS side of the
regenerated diff: UPSTREAM still carries it and the vendored tree has it
scrubbed. Recording the divergence would therefore have copied a scrubbed value
back into a PUBLIC repo. The pattern name is deliberately not reproduced here,
for the same reason.

The tool's own instruction is followed rather than worked around: do NOT
re-sync to clear it, because a re-sync deletes the vendored side, which is where
the scrub lives. `SYNC_ACCEPT_DIVERGENCE_LOSS=1` was not used and must not be.

## What is owed, and by whom

1. Remove the personal-contact value from CM041 at SOURCE, then re-pin, then
   bring this graft forward. Until that happens this tree can never have its
   divergence properly recorded, and every future edit to it lands here instead.
   That is a debt against CM041, not against this repo.
2. Push the same erasure fix upstream to CM041 so the two converge.

Neither is done. Recording that plainly is the whole point of this file.
