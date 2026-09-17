# Writer/reader vocabulary fixes NOT captured by a divergence patch

**Hand-built 2026-09-16, CM051 #1974. Location and shape only, never content.**

Three vendored trees were edited by that PR, and this file has since been
extended in place by later PRs that hit the same refusals. For each one, the
proper record is its `divergence_patch`, and for each one the regeneration tool
was RUN and could not produce it here. This file is the missing half, written
by hand, following the pattern already set by
`cm041_contact_syncer.UNRECORDED.md`.

Each later entry states when it was added and re-states the refusal it was
measured against. Inheriting an earlier PR's refusal without re-running the
tool would be the same thing as inheriting an ack: a debt with nobody's name
on it.

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

### `vendor/doctor/agent/web_ui.py` -- the source table covers the FDA extract family (CM051 #1587, 2026-09-16)

Same tree, same reason there is no patch, and the refusal was RE-MEASURED for
this entry rather than inherited. `scripts/regenerate_divergence_patch.sh
doctor`, run 2026-09-16 with `HR015` pointed at the local source checkout,
printed the 43 upstream commits past the pin and then:

    REFUSED: this is a RE-PIN, not a graft to record.

so the advance limb still holds and there is still no patch to write here.

- new module constant `_FDA_EXTRACT_KINDS`, a two-entry dict beside
  `_SOURCE_KINDS`. It is the CONDITIONAL row register: a name in it joins the
  table only when its hydrate sentinel exists on disk, because those sources
  are the ones the customer picks and an unconditional row would show amber
  "not run yet" for a source somebody declined.
- `read_source_status()`: builds a local `kinds` dict from `_SOURCE_KINDS` plus
  any `_FDA_EXTRACT_KINDS` entry whose sentinel is present, and iterates that
  instead of `_SOURCE_KINDS` directly. Two added lines of loop, one changed
  iteration target.
- `render_source_status()`: `_LABEL` and `_COLOUR` each gain `cannot_run` and
  `timeout`. Both are declared install.sh statuses that had no entry, so the
  cell fell through to the raw identifier and a customer with Full Disk Access
  ungranted read the word "cannot_run" in their own panel.
- `render_source_status()`: the Items cell prints nothing for `cannot_run`,
  `not_run` and `unreadable`. The cannot-run recorder writes `item_count=0`
  because the change-detection helper it shares needs a number; printing that
  0 beside "could not look" is a fabricated count.

Shape: +1 constant, +1 loop in one reader, +4 label/colour entries and +1
guard in one renderer.

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

---

## ADDED 2026-09-18, CM051 #2131. `cm041/assistant_api`, and the tool was RE-RUN.

Per the rule at the top of this file, the refusal below was measured TODAY
rather than inherited from the 2026-09-16 entry. Inheriting a refusal is
inheriting an ack: a debt with nobody's name on it.

THIS ENTRY LIVES IN THE PR THAT MAKES THE GRAFT, DELIBERATELY. It was first
written into CM051 #2129 alongside the identity_resolver half, and Archie
caught the hazard in that: #2131 touches no register file at all, so if it
merged first, or if #2129 were held or closed, this graft would ship with
nothing recording it. An ordering requirement that lives only in a merge loop
is not recorded anywhere. Each PR now carries its own record and the order
stops mattering.

The local CM041 checkout was UNSHALLOWED first, because a `--depth 1` clone
cannot materialise a historic pin and the tool would have reported CANNOT-RUN
for a reason that was mine and not the repo's. The pin resolves in it now and a
fabricated SHA does not, so the check discriminates.

`scripts/regenerate_divergence_patch.sh cm041/assistant_api`, CM041 exported to
that checkout:

| tree | outcome | what the tool said |
|---|---|---|
| `cm041/assistant_api` | **REFUSED**, exit 1 | "this is a RE-PIN, not a graft to record. Regenerating here would fold those upstream commits into the divergence patch and record them as local edits to this repo. Move the pin first, re-apply the graft on the new base, then run this tool if a divergence remains." It listed one unshipped commit: `82f4537 feat(cost): complete the CM041 usage-journal producers`. |

### Why the pin was NOT moved, which is what the tool's advice assumes

Measured: this tree has exactly ONE commit between its pin and CM041 main, and
it IS the single entry on its own `hold_ack_shas` list. Moving the pin would
have silently un-held the one commit somebody held deliberately on 2026-09-06.

A pin naming an older commit than the content is a recorded debt. A pin moved
to main would be an unrecorded scope change that also undoes a hold.

There is a second reason, independent of the hold: `pinned_sha` and
`divergence_patch` are a RECONSTRUCTION PAIR, not a label. Editing the SHA
alone leaves the patch as diff(old pin, old tree), so the pair reconstructs
nothing and the manifest asserts a round-trip that no longer holds.

### The case a pin cannot describe even in principle

This graft has NO upstream commit. `_forget_audit_has` was written in CM051,
not in CM041, so no CM041 SHA describes the vendored `ical-server.py` and none
ever will. A vendored tree can contain code that exists nowhere upstream, which
means `pinned_sha` is not and can never be a description of what is vendored.
Only pin plus patch is, and where the code is locally authored, only a record
is. This file is that record.

### What was grafted, location and shape only, never content

`vendor/cm041/assistant_api/ical-server.py`:

- `+1` function, `_forget_audit_has`, THREE-state: True when an audit line for
  the slug exists, False when the log is readable and holds none, None when the
  log could not be read at all.
- The not-found arm of `api_people_forget` now distinguishes "never found" from
  "already erased" and reports `not_found` rather than `already_forgotten`.
  HTTP status deliberately unchanged at 200, because the iOS Companion's
  ForgetPersonService was written against that and cannot be re-tested from
  here; the BODY is what lied, so the body is what changed.

Shape: +1 function, +1 rewritten branch in one handler.

### What a future sync must preserve

A `sync_vendor.sh` refusal on this tree is EXPECTED and correct.
`SYNC_ACCEPT_DIVERGENCE_LOSS=1` would restore a forget that tells a customer it
erased somebody it never found. The remedy is to re-pin DELIBERATELY, with the
held commit adjudicated the way it was held, then re-apply this graft on the
new base.
