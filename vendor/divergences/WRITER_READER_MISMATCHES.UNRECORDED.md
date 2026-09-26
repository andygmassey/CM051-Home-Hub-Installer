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

## ADDED 2026-09-18, CM051 #2129. `cm041/identity_resolver`, and the tool was RE-RUN.
## ADDED 2026-09-18, CM051 #2131. `cm041/assistant_api`, and the tool was RE-RUN.

Per the rule at the top of this file, the refusal below was measured TODAY
rather than inherited from the 2026-09-16 entry. Inheriting a refusal is
inheriting an ack: a debt with nobody's name on it.

SCOPE NARROWED AFTER REVIEW. This entry first covered BOTH this tree and
`cm041/assistant_api`. Archie caught the hazard: #2131 makes the assistant_api
graft and touched no register file, so if it merged first, or if this PR were
held or closed, that graft would have shipped unrecorded. Worse, it is the one
graft a pin can never describe even in principle, because it has no upstream
commit. Its record now lives in #2131 itself. Each PR carries its own half and
the merge order stops mattering.
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

`scripts/regenerate_divergence_patch.sh cm041/identity_resolver`, CM041
exported to that checkout:

| tree | outcome | what the tool said |
|---|---|---|
| `cm041/identity_resolver` | **REFUSED**, exit 1 | "this is a RE-PIN, not a graft to record. Regenerating here would fold those upstream commits into the divergence patch and record them as local edits to this repo. Move the pin first, re-apply the graft on the new base, then run this tool if a divergence remains." It listed 16 unshipped commits touching this tree. |

### Why the pin was NOT moved, which is what the tool's advice assumes

Measured: 16 commits sit between this tree's pin and CM041 main, and FOURTEEN of
them are on this tree's own `hold_ack_shas` list, which has exactly 14 entries.
Moving the pin to main would have silently un-held every commit classified
individually on 2026-09-06 and pulled them into the cut.

A pin naming an older commit than the content is a recorded debt. A pin moved to
main would be an unrecorded scope change that also undoes a deliberate hold.

There is a second reason, independent of the hold: `pinned_sha` and
`divergence_patch` are a RECONSTRUCTION PAIR, not a label. Editing the SHA alone
leaves the patch as diff(old pin, old tree), so the pair reconstructs nothing and
the manifest asserts a round-trip that no longer holds.

### What was grafted, location and shape only, never content

`vendor/cm041/identity_resolver/`, carrying CM041 #162 (`cc0150f2`) and #163
(`aee68c24`), applied as those PRs' source hunks rather than by syncing the
tree, for the reason above:

- `batch_resolver.py`: +1 function, `sweep_qdrant_orphans_of_merged_people`, and
  its report type. One new `httpx.Client(trust_env=False)` against the
  customer's local Oxigraph.
- `resolver.py`: +1 step in `merge_persons` retiring the discard's type; and
  `find_by_identifier` now follows `mergedInto` to the survivor via a new
  `follow_merge_chain`.
- `repair_merge_consistency.py`: new file, 8238 bytes, byte-identical to CM041
  main.
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
`SYNC_ACCEPT_DIVERGENCE_LOSS=1` would restore a people count that is wrong in
both stores at once, and a sync that resurrects people the graph merged away.
The remedy is to re-pin DELIBERATELY, with the 14 held commits adjudicated one
at a time the way they were held, then re-apply this graft on the new base.
`SYNC_ACCEPT_DIVERGENCE_LOSS=1` would restore a forget that tells a customer it
erased somebody it never found. The remedy is to re-pin DELIBERATELY, with the
held commit adjudicated the way it was held, then re-apply this graft on the
new base.

---

## Added 2026-09-19, CM051 #2133 -- `doctor`, the year-2318 sentinel

### The refusal, RE-MEASURED rather than inherited

This file's own header says an entry must re-state the refusal it was measured
against, because inheriting an earlier PR's refusal is inheriting an ack: a debt
with nobody's name on it. So the tool was run again, today, for this tree:

    scripts/regenerate_divergence_patch.sh doctor
      exit 1, REFUSED
      "this is a RE-PIN, not a graft to record"
      48 upstream commits listed
      vendor/divergences/doctor.patch: 0 lines of diff, nothing written

It is a DIFFERENT refusal from the three above. Those were a patch that would
not reconstruct the tree, a pin that could not be materialised, and a scrubbed
value that must not be copied back. This one is the tool correctly refusing to
fold 48 upstream commits into the patch and record them as local edits.

The pin is `b0b383109e6e1e6ec296af0b0944df9291356042`. The count was checked
against the tracker rather than a local cache: an earlier reading of 24 came
from an `origin/main` this account cannot refresh, and was wrong by exactly
half. A figure computed against an unfetchable remote is a figure about a
moment nobody chose.

### What was grafted, location and shape only, never content

`vendor/doctor/agent/box_status.py`:

- `+1` helper that formats an Ollama keep-alive sentinel for a person, and the
  one call site that used to put `expires_at` on the wire raw.
- Measured on a live box: the box-status endpoint emitted a `keep_alive` in the
  year 2318. `install.sh` starts Ollama with `OLLAMA_KEEP_ALIVE=-1`, which
  Ollama expresses as an `expires_at` roughly three centuries out. The value is
  correct and it is an internal sentinel; piping it to a customer surface
  unchanged is the defect.

Shape: +1 helper, +1 changed call site, in one module.

### What a future sync must preserve

A `sync_vendor.sh` refusal on this tree is EXPECTED and correct while the pin is
48 commits behind. `SYNC_ACCEPT_DIVERGENCE_LOSS=1` would delete this graft and
put the year 2318 back on a customer's own status page. The remedy is the
re-pin, which is separately blocked: two vendored importers under this tree hold
content that exists in NO upstream commit, confirmed by an exhaustive blob walk
with a control, so a re-pin today reverts two working files while advancing the
rest.

## Added 2026-09-19, CM051. `doctor`, FIVE grafts recorded NOWHERE

Found while working row 2219, which names ONE unrecorded delta in this tree.
There are more, and this entry is the rest of them.

### The refusal, RE-MEASURED rather than inherited

Per this file's own rule, the tool was run again today rather than the earlier
refusal being reused:

    HR015=<the HR015 checkout> scripts/regenerate_divergence_patch.sh doctor
      exit 1, REFUSED
      "The SOURCE has advanced past the pin. Unshipped commits touching this tree:"
      48 upstream commits listed
      nothing written

It is the same refusal the #2133 entry above measured, and that is the point
worth stating: the mechanism that would record a graft is unavailable EXACTLY
while the pin is held, and a held pin is this tree's normal state. So every
edit made to this tree between re-pins is unrecordable by the tool, by
construction, and has to arrive here by hand or not at all.

### How these five were found, and what the search could not see

Eight commits have touched `vendor/doctor/` since 2026-09-16. Each was probed
by taking up to five of its own added lines, longer than 45 characters and
neither blank nor a comment, and searching `vendor/divergences/doctor.patch`
for them.

  * ALL EIGHT scored 0 of 5. None is in the patch.
  * CONTROLS, both directions: a line lifted from the patch itself scores 1,
    and a fabricated line scores 0. The probe discriminates.

Of the eight, two are already recorded in this file by PR number (#2133, #2027)
and one by description (the Notion and Obsidian importers, in the section
above). The remaining FIVE are recorded in neither the patch nor this file.

  * THE SEARCH WAS WIDENED BEFORE THE CLAIM WAS MADE, because a PR-number probe
    would miss anything recorded by prose. Each of the five was searched for
    again by description: keepalive, fork budget, forked, pairing QR, beta,
    licence acknowledgement. All zero, against a control term from this file
    that scores 1 and a fabricated term that scores 0. That is how the Notion
    and Obsidian entry was found and excluded.

### What was grafted, location and shape only, never content

`c56ddecb` (#2061), `vendor/doctor/agent/dashboard_components.py`: +60 / -36.
The licence acknowledgement panel, and a map that existed in two places.

`b3c80daa` (#2019), `diagnostic_copy.py` +46, `diagnostic_rules.py` +177.
The beta window as the entitlement, with the tester warned first.

`4fbb5d3e` (#2042), `pair_status.py`: +57. The pairing QR could carry an
address the phone cannot open.

`1828fc9d` (#1984), four modules: `dashboard_components.py` +189,
`web_ui.py` +16, `web_ui_copy.py` +75, `whatsapp_pair.py` +165. The keepalive
that diagnosed the wrong object, fixed nothing and exited 0.

`c7a961cd` (#1979), `box_status.py`: +107 / -5. The status daemon fork budget,
after 58,914 forks in 40 hours got it killed by macOS.

Shape: five grafts, 892 added lines, across seven modules in one tree.

### What a future sync must preserve

A `sync_vendor.sh` refusal on this tree is EXPECTED and correct while the pin
is 48 commits behind. `SYNC_ACCEPT_DIVERGENCE_LOSS=1` would delete all five.
What a customer would get back, in the order above: a Doctor that cannot check
the licence acknowledgement, no beta entitlement window, a pairing QR their
phone cannot open, a keepalive that reports on an object nobody runs, and a
status daemon that forks until macOS kills it and the Doctor goes quiet.

None of the five is a candidate for the patch until the pin moves, and the
re-pin is separately blocked for the reason the #2133 entry records.

## Added 2026-09-24. `ostler_fda`, the photo-event writer that was never merged

### The refusal, measured

`HR015="<HR015 checkout>" scripts/regenerate_divergence_patch.sh ostler_fda`
was run and REFUSED with "this is a RE-PIN, not a graft to record": the source
has advanced past pin c4e7396f by one commit touching this tree (28662818,
HR015 #977). Regenerating would fold that commit into ostler_fda.patch as a
local edit, so the graft is recorded here and a grep of the patch for it
returns nothing, which means NOT RECORDED, not NOT DIVERGED.

### What was grafted, location and shape only

- `vendor/ostler_fda/pwg_ingest.py`: new `ingest_photo_events` (writes one
  `pwg:PhotoEvent` per row of photos_events.json with `pwg:photoDate`,
  `pwg:photoLatitude`, `pwg:photoLongitude`, `pwg:photoPlace`, and
  `pwg:photoAttendee` only with the faces opt-in), new `ingest_photos`
  (events plus face people), and the `"photos"` dispatch entry now names
  `ingest_photos`. `ingest_photos_people` and `ingest_photo_events` join
  `_DISPATCH_EXEMPT` because `ingest_photos` runs both.
- `vendor/ostler_fda/extract_all.py`: with faces off, face labels are cleared
  from every event before photos_events.json is written.

WHY: photos_events.json had no reader. CM044's wiki queries `pwg:PhotoEvent`
and nothing wrote one; HR015 PR #143 built the writer and was closed unmerged
as a stale draft. Measured on a walked box: "[ok] Photos: 0 people, 1298
events (faces=off)" then "No Photos data to ingest", 10 of 10 runs.

### What a future sync must preserve

Both edits. Upstream HR015 `ostler_fda` should take them back; until it does,
a sync that accepts divergence loss restores the dark writer. Gate:
`tests/test_photo_events_reach_the_graph.py`, wired in privacy-spine.yml.

## Added 2026-09-26. `ostler_fda`, photo events carry a place name (#2415)

### The refusal, measured

`HR015="<HR015 checkout>" scripts/regenerate_divergence_patch.sh ostler_fda --write`
was re-run for this PR against a fresh HR015 checkout and REFUSED with "this
is a RE-PIN, not a graft to record": the source is still one commit past pin
c4e7396f on this tree (2866281, HR015 #977). Same limb as the 2026-09-24
entry, measured again rather than inherited.

### What was grafted, location and shape only

- `vendor/ostler_fda/photos_metadata.py`: new `_place_label` (decodes the
  NSKeyedArchiver reverse-geocode archive to a city-level "City, Country"
  label; street, postcode and formatted address are never read), the macOS 26
  query in `extract_photo_events` joins `ZADDITIONALASSETATTRIBUTES` for
  `ZREVERSELOCATIONDATA`, and `PhotoEvent.location` is set from
  `_place_label` instead of `None`. `import plistlib` added.

WHY: `pwg:photoPlace` is written only when a label exists, and CM044 matches a
photo to a place page only by that label, so "Photos here" was always empty.
Local macOS 26.4 library: 0 of 1291 events labelled before, 970 after.

### What a future sync must preserve

The edit above. Gate: `tests/test_photo_events_carry_place_names.py`, wired in
privacy-spine.yml.
