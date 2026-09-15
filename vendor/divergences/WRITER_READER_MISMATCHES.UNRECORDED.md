# Writer/reader vocabulary fixes NOT captured by a divergence patch

**Hand-built 2026-09-16, CM051 #1974. Location and shape only, never content.**

Three vendored trees were edited by that PR. For each one, the proper record is
its `divergence_patch`, and for each one the regeneration tool was RUN and
could not produce it here. This file is the missing half, written by hand,
following the pattern already set by `cm041_contact_syncer.UNRECORDED.md`.

It is a record, not an instrument. Nothing reads it and it cannot be applied.
Its whole job is to stop the next `sync_vendor.sh` deleting these edits without
anyone knowing they existed.

## Why there is no patch, per tree, measured rather than assumed

Each line below is the actual outcome of
`scripts/regenerate_divergence_patch.sh <tree> --write`, run on 2026-09-16 with
`HR015` and `CM041` exported to the local source checkouts.

| tree | outcome | what the tool said |
|---|---|---|
| `ostler_fda` | **REFUSED**, exit 1 | "the written patch does not reconstruct the vendored tree", then "RESTORED the previous patch -- nothing was left broken". Its self-verification step caught its own output and rolled back. |
| `cm041/assistant_api` | **CANNOT-RUN**, exit 2 | `pinned_sha 9be482d3 not present in` the local CM041 checkout. The pin cannot be materialised, so there is nothing to diff against. |
| `doctor` | **REFUSED**, exit 1 | "this is a RE-PIN, not a graft to record. Regenerating here would fold those upstream commits into the divergence patch and record them as local edits to this repo." The source has ADVANCED past the pin, so the tool refuses on its advance limb. |

All three refusals are DIFFERENT, and that matters: this is not one broken
environment producing one symptom three times. One tool failed its own
round-trip check, one could not find the pin, one found the source ahead of the
pin. Each is the tool working correctly and declining to write a patch that
would be a lie. None of them is a reason to skip recording the divergence,
which is what this file is for.

Two further facts about the environment, because a reader deciding whether to
retry needs them:

- The `ostler_fda` DRY RUN completed and proposed a 1169-line change whose
  bulk was the REMOVAL of an `apple_mail_mbox.py` delta. That is a retraction,
  not a new claim, and it is consistent with the vendored file having been
  reconciled with source since the patch was last written. It is NOT evidence
  that this PR's edits were captured.
- The local `$HR015` checkout is 81 commits ahead of the `ostler_fda` pin but
  **zero** of those 81 touch `ostler_fda`, so the subtree at HEAD equals the
  subtree at the pin. The source was fit for the comparison; the failure is in
  the patch round-trip, not in the source.

**A grep of any of these three patches for the lines below will return
nothing, and that means NOT RECORDED. It does not mean NOT DIVERGED.**

## The edits, by location and shape

### `vendor/ostler_fda/pwg_ingest.py` -- the people payload gained the key its reader filters on

- `_load_people_from_oxigraph()`: one added SPARQL query selecting
  `MAX(?d)` over `pwg:lastContactIMessage|WhatsApp|Calendar|Email`, grouped by
  person; result folded onto each person dict as `last_contact`.
- new module-level helper `_last_contact_epoch()`: ISO date to epoch seconds,
  returning `0` for absent or unparseable rather than `now()`.
- `ingest_people_to_qdrant()` payload: `"last_contact"` stops being a hardcoded
  empty string and carries the real date; `"last_contact_ts"` is added.

Shape: +1 query, +1 helper, 2 changed payload keys. No I/O boundary moved, no
new dependency, no change to the collection, the point ids or the vector size.

### `vendor/cm041/assistant_api/ical-server.py` -- the facts query gained the vocabulary customers' data is actually in

- `_memory_query_facts()`: the single-arm `pwg:PersonFact` SPARQL becomes a
  two-arm UNION. Arm one is the previous query, character for character. Arm
  two reads `<urn:ostler:Fact>` inside `GRAPH ?g`, scoped by a case-folded
  comparison on `<urn:ostler:userId>`, withholding `privacyLevel` `L3`, and
  mapping `signalStrength` to a numeric `?conf`.

Shape: one function, one string literal. No route, no response shape, no
handler and no storage call changed.

### `vendor/doctor/agent/import_notion.py` and `import_obsidian.py` -- the knowledge imports point at the collection that is read

- new module constant `KNOWLEDGE_COLLECTION = "evernote_knowledge"`.
- `_collection_for_source()` returns it instead of `f"{source}_knowledge"`.
  The parameter is kept for call-site compatibility and ignored.

Shape: +1 constant and 1 changed return, in each of two sibling files.
`import_evernote.py` is NOT touched: it already returned this collection.

## What a future sync must preserve

If `sync_vendor.sh` refuses on any of these three trees, the refusal is
EXPECTED and correct, and `SYNC_ACCEPT_DIVERGENCE_LOSS=1` would silently
restore all five defects this PR closed. The remedy is to re-run the
regeneration once the blockers above are cleared -- fetch the CM041 pin, and
establish why the `ostler_fda` patch does not round-trip -- not to accept the
loss.

`vendor/cm019_preferences` is the fourth tree edited and is NOT listed here: it
carries `verify = "skip"` and an empty `divergence_patch` by design, and its
record lives in `CM019_DIVERGENCE_REGISTRY.md`, which this PR also updates.
