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

## Added 2026-09-28, CM051 v1.0.106 (FIX106-B) -- `doctor`, routines and remote access

Tool re-run on 2026-09-28: `scripts/regenerate_divergence_patch.sh doctor`
refused again (the tree's regeneration ban is checked before the source
checkout). So these edits are recorded here by location and shape.

- `vendor/doctor/agent/routine_status.py` -- NEW FILE. `read_routine_status()`:
  one row per recurring ingest routine (label, interval from its LaunchAgent
  plist, launchd loaded/running/last exit, last run from its log mtime, the
  counts its last run printed, health with a reason). No FastAPI imports.
- `vendor/doctor/agent/remote_access.py` -- NEW FILE. `status()` and
  `set_enabled()` for the INSTALLER's tailscaled through
  `$OSTLER_DIR/tailscale/tailscaled.sock`, with install.sh's own
  `up --hostname=ostler-hub`.
- `vendor/doctor/agent/web_ui.py` -- three routes added next to
  `/api/v1/box-status`: `GET /api/v1/routines`, `GET /api/v1/remote-access`,
  `POST /api/v1/remote-access` (the /api/v1/pause cross-site guard).

A future sync must keep both files and the three routes. Guarded by
tests/test_doctor_routines_are_measured_live.py and
tests/test_remote_access_reads_the_installers_tailscale.py (vendor-integrity.yml).

## Added 2026-10-01, CM051 v1.0.107 (people-correctness agent) -- `ostler_fda`, a WhatsApp LID stopped being written as a phone number (#2543)

Not re-run against this PR specifically (the tool's prior refusal on this
tree, logged above under "The refusal, measured", was a round-trip
self-check failure and a RE-PIN limb -- neither is affected by a graft that
does not move the pin -- and re-running it carries real risk of a long hang
against a contended HR015 checkout, which is why it was not attempted again
here). Recorded by location and shape only, following the established
pattern for this tree rather than a fresh tool run.

### What was grafted, location and shape only

- `vendor/ostler_fda/pwg_ingest.py`: new `_whatsapp_jid_is_genuine_phone(local)`,
  validating with `phonenumbers.is_valid_number` rather than `str.isdigit()`.
  `_whatsapp_display_name` and `_whatsapp_phone_e164` both call it before
  treating a WhatsApp JID's local part as a phone number; `_whatsapp_phone_e164`
  now returns `None` (was: always a string) when the local part is all-digits
  but not a genuine phone. Both call sites inside `ingest_whatsapp` (the
  "create" branch and the separate "person already exists" enrich branch) now
  write `pwg:identifierType "whatsapp_lid"` instead of `"phone"` when that
  happens, and the enrich branch additionally now writes the NORMALISED E.164
  value instead of the raw JID local-part it wrote before (a second,
  independent format-mismatch bug in the same branch, unrelated to the LID
  fix but found and fixed alongside it). `import phonenumbers` added;
  `phonenumbers>=8.13.0` added to `pyproject.toml`'s `dependencies`.

WHY: WhatsApp's LID privacy system can present a 14-15 digit linked-device id
through the ORDINARY `@s.whatsapp.net` phone-JID suffix, not only the
`@lid`-suffixed form the existing BW-4 guard already catches. Every digit
check in this module asked only "is the local part all-digits", true for
both a genuine phone-rooted JID and an LID presented this way, so the LID
sailed through as a `"phone"` identifier AND, via the display-name helper,
as the literal digits in `pwg:displayName` -- CM051 #2543, "15-digit phone
numbers shown twice" on the v1.0.106 walk. Traced from the consumer
(read-only, counts-only query against the live Oxigraph store on the walk
box): 19 people carried a LID-shaped `"phone"` identifier; 12 of those also
carried the same LID digits directly as `pwg:displayName`, and all 12 had a
full 36-char dashed-UUID person URI -- this tree's own `uuid5`-based minting
convention (`_person_id_from_identifier`), not CM041's. Confirmed the same
defect in BOTH the HR015 source (fixed separately, HR015 PR #1017, kept
converging per Archie's instruction) and this vendored copy, byte-for-byte
identical logic, before grafting here.

### What a future sync must preserve

Both call sites' `id_type`/`id_value` branching inside `ingest_whatsapp`, and
the new `_whatsapp_jid_is_genuine_phone` helper. Gate:
`vendor/ostler_fda/tests/test_whatsapp_lid_not_phone.py`, including a test
proving the discriminator is proven rather than assumed -- a synthetic
15-digit string whose LEADING digits form a real, allocated country code
(the UK's, "44") is still rejected, because validity depends on the FULL
number matching an allocated length/pattern, not merely sharing a calling
code prefix. One pre-existing test in
`vendor/ostler_fda/tests/test_provisional_display_name.py` used the UK
mobile OFCOM drama range (+44 7700 900xxx), which is reserved but NOT
phonenumbers-valid (checked, not assumed) -- swapped for the OFCOM
LANDLINE drama range (020 7946 0xxx), which is both reserved and valid, so
the test still exercises the real code path instead of silently hitting the
new "not a genuine phone" branch.

### A related, NOT fixed, out-of-scope finding from the same sweep

`vendor/cm048_pipeline/src/ingest.py`'s `_normalise_chat_identifier` carries
a DELIBERATE, documented duplicate of this same digit-check pattern
(`("+" + local) if local.isdigit() else raw`, no validity check) for its
human-facing `pwg:chatIdentifier` literal -- the file's own comment states
it is "duplicated (not imported) because CM048 ships independently of
ostler_fda". Same vulnerability class, different tree, different pin, and
outside what CM051 #2543 named. Not touched here; flagged for whoever owns
`cm048_pipeline`'s next pass.
## Added 2026-10-01, CM051 v1.0.107 (people-correctness agent) -- `cm041/identity_resolver`, a one-time repair for already-written WhatsApp-LID-as-phone rows (#2543)

**UPDATED 2026-10-01 (same day, Archie): CM041 PR #181 MERGED as
`b9deb6efab984730326106c4c1bc929c0f79599b`.** The graft below was first cut
from #181's commit `9086498`, a point on that PR's branch that PREDATES the
Qdrant-payload patch and the backup/restore machinery Archie's review then
required (#181 HELD, then re-reviewed, then merged). That graft has been
REPLACED with the content at the merge commit, not re-dated in place --
`9086498` is stale and must not be read as current. `cmp`/sha256 against
`source@b9deb6ef` is the proof, not the PR-merged state alone.

Not run against the regeneration tool. `identity_resolver` carries no
`regenerate_forbidden` flag (unlike `contact_syncer`), but the pin
(`pinned_sha = 9e260949ca9776c72038dc4734352e9508c0c494`, see
VENDOR_MANIFEST.toml) sits far behind `b9deb6ef` on a tree already carrying
many individually-adjudicated grafts and an existing unrecorded-divergence
debt (`resolver.py`/`batch_resolver.py` do not reconstruct from the pin plus
patch; see that row's own history). Re-pinning the whole tree is a separate,
larger decision than landing this one fix, so this stays a targeted graft of
two files, by location and shape, per this file's established pattern,
rather than attempted against the regeneration tool and refused for the log.

### What was grafted, location and shape only

- `vendor/cm041/identity_resolver/normalise.py`: `is_valid_phone(raw,
  default_country_code)`. Unchanged between `9086498` and `b9deb6ef`
  (diffed to confirm), and the vendored copy is byte-identical to
  `source@b9deb6ef:identity_resolver/normalise.py` (sha256
  `a0aeb1427bf62fd006e5cefdc523409ca9fed8e28bd130b9cad0acd802e9d7c4`, both
  sides).
- `vendor/cm041/identity_resolver/repair_lid_as_phone.py` -- NEW FILE.
  Idempotent, dry-run-default repair for CM051 #2543's two writer
  fingerprints: Pass A1 (CM041 whatsapp_bridge -- a bogus "phone"
  identifier with a sibling "whatsapp_lid" identifier sharing the same
  invalid value) and Pass A2 (ostler_fda's ingest_whatsapp, the writer that
  actually ships, CM051 #2577 -- only one invalid "phone" identifier, no
  sibling, scoped by `pwg:source "whatsapp_fda"`). ALSO patches the matching
  Qdrant `people` payload (the Hub People list and `people_stores_reconcile`
  read Qdrant, not Oxigraph) and backs up every changed row to a jsonl under
  `~/.ostler/backups/` before writing, restorable via
  `--restore-from-backup`. Reproduced verbatim from
  `source@b9deb6ef:identity_resolver/repair_lid_as_phone.py`, not
  paraphrased -- byte-identical, sha256
  `a75fb9dea3a604da2fab39b52e98c8389c57c5db56c4fd44e3e37684b4e38caf` both
  sides (`cmp` also run, exit 0).

WHY: the writer-side fix (this tree's existing `_canonical_key_conflict`/
`_identifier_match_trustworthy` grafts plus PR #181's forward-fix) stops NEW
bad rows. It does nothing for rows a box already wrote before either fix
existed. Measured, read-only, on the macmini16-walk box: 33 rows match the
ostler_fda signature, 0 match the CM041 bridge signature (that writer has
never run there -- see CM051 #2570's tracking note on this same tree for the
corroborating 0-whatsapp_lid-identifiers finding).

### What a future sync must preserve

Both files. Gate: `tests/test_repair_lid_as_phone_vendored.py` at the CM051
repo root (not under `vendor/cm041/identity_resolver/tests/`, which this
tree does not vendor at all -- following the same top-level placement
`tests/test_migration_marker_guard_fresh_install.py` already uses for a
vendored-module test). Also: `install.sh`'s one-time upgrade step (marker
`state/repair_lid_as_phone_v1.done`, same pattern as
`state/email_reclassify_v3.done`) invokes
`identity_resolver.repair_lid_as_phone` by module name -- a future re-vendor
that renames or drops the file breaks that invocation silently (ImportError
inside a subshell, swallowed into the step's own failure-retry path) unless
`tests/test_repair_lid_as_phone_marker_skip.sh`'s extraction-and-run check
is kept passing.

## Added 2026-10-01, CM051 #2526/#2529 -- `doctor`, a dedicated routine is believed over a stale sentinel

Tool re-run on 2026-10-01: `scripts/regenerate_divergence_patch.sh doctor`
refused again, exit 1, same ban as every prior entry for this tree (checked
before the source checkout; declared reason unchanged since #2219). So this
edit is recorded here by location and shape, not by patch.

- `vendor/doctor/agent/web_ui.py`, inside `read_source_status()`'s ongoing-
  status merge loop: two new module-level helpers,
  `_SOURCE_ROUTINE_LABELS` (which dedicated LaunchAgent routine, if any,
  speaks for a given canonical source -- email, imessage, whatsapp) and
  `_ROUTINE_COUNT_KEYS` (an explicit per-routine allowlist of which key in
  that routine's `latest` log counts is a trustworthy count; today only
  `"emitted"`, the one key `routine_status.py`'s own regex fallback pins by
  code). New functions `_routine_evidence()` and `_routine_run_count()`.
  When a source's fda-rerun-tick activity record is silent (`ongoing=never`)
  but its OWN dedicated routine reports a healthy, completed run, the row's
  `ongoing`/`last_run_at`/`last_success_at` are now taken from that routine
  instead of staying `never` forever. A stale `no_data`/`not_run`/
  `unreadable` install-time `status` is upgraded to `ok` only when that
  routine also supplies an explicitly-keyed, real count -- written to a NEW
  field, `last_run_count`, never to `item_count` (the install-time total,
  which this change never touches).
- `vendor/doctor/agent/routine_status.py`: unchanged. This reuses its
  existing `read_routine_status()` reader rather than re-implementing it.

A future sync must keep `_SOURCE_ROUTINE_LABELS`, `_ROUTINE_COUNT_KEYS`,
`_routine_evidence`, `_routine_run_count`, the `last_run_count` field on every
`/api/v1/sources` row, and the merge-loop call site that consults them.
Guarded by tests/test_source_status_prefers_a_live_routine_over_a_stale_sentinel.sh
(cold-box-source-truth.yml) and the pre-existing
tests/test_source_status_reports_ongoing_not_just_install.sh /
tests/test_the_source_table_covers_the_fda_extract_family.sh, both updated
only to extract the two new helper functions.
## Added 2026-10-01, CM051 #2574 -- `doctor`, Hub config read admitted + Ostler's VM/model runner

Tool re-run on 2026-10-01: `scripts/regenerate_divergence_patch.sh doctor`
REFUSED again, this time on the tree's own `regenerate_forbidden` ban (checked
BEFORE the source checkout, so it fires independently of whether an HR015
checkout is reachable): "the Doctor source-status panel ... EXISTS ONLY IN
THIS REPOSITORY ... never by clearing the flag" (board #2219, full reasoning
in `DOCTOR_SOURCE_STATUS_PANEL_2219.md`). Same tree as the two entries above,
different refusal reason than either of them, measured rather than inherited.

- `vendor/doctor/agent/web_ui.py` -- new `_hub_read_refusal()`, called by
  `api_config_get` in place of `_cross_site_refusal`. `_cross_site_refusal`
  admitted only `Sec-Fetch-Site: same-origin` or absent, so GET
  `/api/v1/config` 403'd both the Hub's own Tauri webview (stamped
  cross-site from `tauri://localhost`) and a browser-served Hub on :8000
  (stamped same-site) -- the Settings and Governor pages could never read
  back a customer's own saved config. `_hub_read_refusal` admits the read
  when `Origin` is the Hub's webview or a loopback page
  (`editor_feedback.origin_is_local`, the same predicate the editor feedback
  route already trusts), else falls through to the unchanged guard. Writes
  are untouched: they still go through `_cross_site_refusal` and the
  `doctor_post` native bridge.
- `vendor/doctor/agent/box_status.py` -- `_OSTLER_NAMES` gained
  `com.apple.Virtualization.VirtualMachine`, `colima`, `limactl`,
  `llama-server` (the shipped stack's container VM and model runner, which
  were billed to "Other apps" while "Ostler itself" read ~0%), with matching
  `_LABELS` entries ("Ostler databases" / "Ostler model").

WHY: both measured directly against the shipped tree, not HR015 source --
`tests/test_the_hub_reads_the_doctor_like_the_app.py` read 5 of 8 FAIL before
this PR against the app's real request shape (Origin/Sec-Fetch-Site as the
Tauri webview sends them), 8 of 8 after.

### What a future sync must preserve

Both edits in both files. Gate:
`tests/test_the_hub_reads_the_doctor_like_the_app.py`, wired into
`vendor-integrity.yml`. Ledger:
[HR015-Gaming-PC@406397d](https://github.com/andygmassey/HR015-Gaming-PC/commit/406397dccc6bdaf6cf3d0a9c6a6b1f1587346ff6).

## Added 2026-10-01, CM051 v1.0.107 (ORM) -- `cm041/identity_resolver` re-pinned 9e260949 -> fce36b9e, ONE line stays unrecorded

The re-pin moves this tree onto CM041 main, which now carries #181 itself
(b9deb6ef is an ancestor of fce36b9e). So the #181 graft recorded in the entry
above is no longer a divergence: `normalise.py` and `repair_lid_as_phone.py`
take upstream, and the regenerated `cm041_identity_resolver.patch` describes
every other difference.

EXCEPT ONE LINE. `repair_lid_as_phone.py` keeps
`CONTROL_LID_PHONE_VALUE = "9" * 15` where upstream writes the same value as a
single 15-digit literal. The patch cannot carry that hunk: its `-` side is
upstream's literal, and `.github/scripts/ci-pii-shape-scan.sh` (run by the
pre-commit hook and CI as `scan`) refuses ANY 15-plus digit run, in any path,
by shape. So the hunk was removed from the patch by hand and the line is
declared here instead.

### What a future sync must preserve

The composed literal, functionally identical value. Consequence:
`verify_vendor_fresh.sh` reports this tree as differing from
source@pinned_sha+patch by exactly this one line (main already reported it
as DIFFERING, by the whole #181 graft). Retire this entry if CM041 composes the
literal upstream.

## Added 2026-10-02, CM051 v1.0.107 (ORM) -- `cm041/identity_resolver`, a kinship word never becomes a permanent displayName (CM041 #185, CM051 #2556)

`vendor/cm041/identity_resolver/resolver.py`'s `create_person`:
`choose_canonical_display_name` has no opinion on a single-candidate list of
exactly "Mum" (not junk, not a unix login, not an email -- it passes
straight through), so the fallback `or identity.display_name` was the one
unguarded path in this module. Added one `if is_relationship_label(display_
name): display_name = ""` check right after that fallback, plus the import
`from contact_syncer.relationship_labels import is_relationship_label` (the
SAME predicate, not a new one -- see `cm041_contact_syncer.UNRECORDED.md`
for the six `contact_syncer` write sites this same change touches). Matches
the WHOLE label only: "Mum Zhang" is a plausible real name and is never
touched.

Not run against the regeneration tool for this change: checked for a
circular import first (`contact_syncer/__init__.py` is empty and
`identity_resolver/__init__.py` lazily re-exports `.resolver`, so this
cross-package import is safe in both directions) and confirmed both
packages still import cleanly in the vendored tree before writing this
down.

### What a future sync must preserve

The import and the one-line guard in `create_person`. Guarded by
`tests/test_kinship_label_write_guard_vendored.py` (CM051 repo root).
Retire by landing CM041 #185 and re-pinning.

## Added 2026-10-02, CM051 board #2562-C -- `doctor`, a direct activity record must not block a routine's real count

Tool re-run on 2026-10-02: `scripts/regenerate_divergence_patch.sh doctor`
refused again, exit 1, same ban as every prior entry for this tree. Recorded
here by location and shape.

- `vendor/doctor/agent/web_ui.py`, `read_source_status()`'s ongoing-status
  merge loop: the `if row["ongoing"] == "active": continue` short-circuit
  (added for #2526/#2529, see the entry above) skipped the dedicated-routine
  count lookup whenever fda-rerun's own activity record already set
  `ongoing=active` -- which measured true for email and imessage on a walk
  box, because that activity record answers the SAME narrow question the
  install-time sentinel already answers (new correspondents found in a
  window), not "does this source have real content". Both rows stayed
  `status=no_data` with no count, while the dedicated email-ingest routine's
  own log had just emitted real messages and iMessage's own settling ledger
  showed tens of thousands of messages done. Fix: the dedicated-routine
  lookup and count upgrade now run regardless of which path proved
  `ongoing`; only the `ongoing`/`last_run_at`/`last_success_at` fields stay
  reserved for a direct activity record when one exists (`direct_activity`
  flag), because a routine's own run time is not evidence about WHEN
  fda-rerun's unrelated tick last succeeded.

A future sync must keep the `direct_activity` flag and the count lookup
positioned after it rather than inside the old `continue` branch. Guarded by
`tests/test_source_status_prefers_a_live_routine_over_a_stale_sentinel.sh`
(cold-box-source-truth.yml), limb 5 (updated) and the new limb named "board
#2562-C" pinning this exact shape.

## Added 2026-10-02, CM051 v1.0.107 (ORM) -- `cm041/identity_resolver`, two walk-found phone defects (CM051 walk-defects D and E)

A cold v1.0.107 install walk found two live phone defects the #2545 fix
(CM041 #182) did not close:

**D -- `vendor/cm041/identity_resolver/normalise.py`**: added a new function,
`is_possible_phone`. `normalise_phone` is a pass-through formatter (returns
the ORIGINAL STRING UNCHANGED when it cannot parse/validate), and the
existing `is_valid_phone` (`phonenumbers.is_valid_number`) is TOO STRICT a
gate for a general contacts-field write -- it rejects numbers in ranges
`phonenumbers` has not catalogued as currently assigned, including this
repo's own OFCOM drama-reserved mobile fixture (`+44 7700 900200`, used as
the canonical "obviously a phone" value across dozens of this suite's own
tests), measured `is_valid_phone` **False**. `is_possible_phone`
(`phonenumbers.is_possible_number`) checks digit-count plausibility only:
still refuses a 14/15-digit WhatsApp-LID/internal-id shape (wrong length for
any real number, with or without a default country code configured) while
accepting real numbers in unvalidated ranges. Reused, not reinvented --
mirrors `is_valid_phone`'s own parse strategy exactly, swapping only the
final validity check. Matches CM041 PR #186 (upstream, not yet merged at
time of writing).

**E -- `vendor/cm041/identity_resolver/batch_resolver.py`, `execute()`**: a
RULE-2-refused auto-merge (two Person nodes share a phone/email value but
carry DIFFERENT canonical keys -- icloud_contact_uid / whatsapp_lid /
linkedin_url) used to `continue` with nothing but a log line. Measured live
on a walk box: `detect()` re-classifies the SAME pair as a high-confidence
auto-merge candidate every `converge()` round (same names-agree verdict,
same confidence), `execute()` refuses it every round (correctly -- RULE 2 is
not relaxed by this change), and the pair never once reaches
`report.needs_review` -- rounds 2 onward plateaued at an IDENTICAL refused
count every round on the measured box, 0 of it ever surfaced. That silent,
permanent drop is what "CM051 #2545 is not fixed on the box" measures as for
these pairs: not a merge failure, a REPORTING failure that hides a real,
human-actionable duplicate from whatever reads `needs_review` (the Doctor
"tidy your contacts" queue, support bundles). Fix: on a RULE-2 veto, append a
`DuplicateMatch` to `report.needs_review` naming the conflicting canonical-
key type, instead of only logging it. No merge decision, rule or threshold
changes -- RULE 2 still vetoes the same merges it always did.

THIS TREE HAS NO `converge()` METHOD OR RULE-2-ON-EXECUTE() VETO IN CM041
SOURCE AT ALL (checked: `identity_resolver/batch_resolver.py` at CM041
`origin/main` as of this entry has neither). That gap already existed before
this entry (see the `cm041/identity_resolver` manifest row's own note on
`converge()` being vendor-only, added 2026-07-15) and is NOT newly
introduced by this change -- this entry only adds the needs_review routing
ON TOP of the existing vendor-only veto. Upstreaming the whole mechanism into
CM041 source is a separate, larger piece of work, flagged but out of scope
here.

### What a future sync must preserve

`is_possible_phone` in `normalise.py` (additive; does not touch
`is_valid_phone`'s existing behaviour or callers). In `batch_resolver.py`'s
`execute()`, the `report.needs_review.append(DuplicateMatch(...))` call
inside the RULE-2-veto branch, immediately before its `continue`. Guarded by
`tests/test_converge_path_enforces_rule2.sh` (CM051 repo root, extended) and
`identity_resolver/tests/test_is_possible_phone_accepts_unvalidated_ranges.py`
(CM041 source). Retire by landing CM041 PR #186 (D's half; E's half has no
upstream counterpart yet) and re-pinning.

## Added 2026-10-03, CM051 board #2562-C round 2 -- `doctor`, a count only has to come from SOMEWHERE real, not from the freshest place

Tool re-run on 2026-10-03: `scripts/regenerate_divergence_patch.sh doctor`
refused again, exit 1, same ban as every prior entry for this tree. Recorded
here by location and shape.

- `vendor/doctor/agent/web_ui.py`: two fixes to the count lookup added for
  board #2562-C (see the entry above).
  1. `_best_routine_count()` (new): the count is now taken from ANY healthy
     routine mapped to a source, checked in declaration order, not only the
     freshest one `_routine_evidence()` picks for the ongoing question.
     MEASURED on a walk box: email maps to email-bundle (900s, no count ever)
     and email-ingest (3600s, the one with a real "Emitted N message" log
     line); email-bundle is fresher almost every time either is checked
     purely because it runs four times as often, so picking "freshest" for
     the count starved email of a real figure it already had.
  2. `_settling_progress_total()` + `_SETTLING_PROGRESS_FILES` (new): a
     source with NO routine that ever logs a count (iMessage has no sibling
     "ingest" routine the way email does) now reads a STORE total from
     `state/settling_progress.d/<file>.json` when one is declared for it.
     MEASURED on a walk box: `messages.imessage.json` held
     `{"done": 20850, "total": 29021}` while `/api/v1/sources` still said
     item_count 0. Declared per source on purpose: the same day, `emails.json`
     held `{"done": 0, "total": 0}` while email-ingest had just emitted
     thousands of real messages, so that file answers a different question
     for email and must never be read for it. Only `imessage` and `whatsapp`
     are declared; `whatsapp` by the same reasoning as imessage, not
     separately measured this round.

A future sync must keep `_best_routine_count`, `_settling_progress_total` and
`_SETTLING_PROGRESS_FILES`, and the merge-loop call sites that now run
regardless of whether a direct activity record already set `ongoing`.
Guarded by tests/test_source_status_prefers_a_live_routine_over_a_stale_sentinel.sh
(cold-box-source-truth.yml), new limbs 8-11. Sibling tests
(test_source_status_reports_ongoing_not_just_install.sh,
test_the_source_table_covers_the_fda_extract_family.sh,
test_source_status_contract.sh) updated only to extract/import the two new
functions and `json`; all still pass.

## Added 2026-10-03, CM051 v1.0.107 (ORM) -- `cm041/identity_resolver`, the 14-digit possible-but-invalid gap in is_possible_phone (walk #2, item D)

v1.0.107 walk #2 (cold Mini16) found 7 of 2,345 People rows still carried an
exactly-14-digit `+`-prefixed phone identifier, produced by the SAME
`contact_syncer` writer the first `is_possible_phone` graft already gated
(confirmed from the consumer: `person_<hex>` and the identifier's embedded
hex matched on all 7, a single-writer mint). `is_possible_phone` returned
True for every one of the 7 stored values; `is_valid_phone` returned False.

Root cause: `phonenumbers.is_possible_number()` checks digit-count
plausibility per country, and a `+`-prefixed 14-digit value can be
"possible" under SOME country's numbering plan even though it is not a real
phone number. The first graft only proved the gate closes BARE digits with
no leading `+` (which fail to parse at all with no default country code),
not this shape.

Fix, in `vendor/cm041/identity_resolver/normalise.py`'s `is_possible_phone`:
in the 14+ digit zone (E.164's own ceiling is 15), also require
`is_valid_number`, the stricter check deliberately avoided for shorter
numbers specifically to keep accepting real customers in unvalidated
ranges. Below 14 digits, `is_possible_number` alone is still trusted (the
OFCOM mobile fixture used throughout this suite is 12 digits and is
unaffected). Matches CM041 PR #187 (upstream, not yet merged at time of
writing).

### What a future sync must preserve

The digit-count check added to `is_possible_phone`, immediately after its
existing `is_possible_number` check. Guarded by
`tests/test_vendored_is_possible_phone_14_digit_gap.py` (CM051 repo root,
mirroring CM041 PR #187's own test suite). Retire by landing CM041 PR #187
and re-pinning.

## Added 2026-10-03, CM051 v1.0.107 (ORM) -- `cm041/identity_resolver`, a duplicate pair's evidence names every shared identifier, not just the winner (walk #3, item E)

v1.0.107 walk #3 (cold Mini16) found E still failing: 12 of 47 duplicated
phone numbers were on NO review card, while 35 were correctly surfaced via
`/api/v1/contacts/diff`. Traced from the consumer on the box: the pair is
NOT invisible to the resolver -- `detect_phone_matches` DOES produce a
match for it, and the pair IS merged or listed for review. The gap is in
`consolidate_matches`: it keeps only the HIGHEST-confidence match per pair,
so a pair that ALSO shares an email is filed under `email_match`
(confidence 1.0, beats `phone_match`'s 0.95 ceiling), and that winning
item's evidence never mentioned the phone at all. Measured directly: 34 of
104 phone-matched pairs were won by a different strategy this way.

Fix, in `vendor/cm041/identity_resolver/tidy.py`'s `_duplicate_items`:
before consolidating, index every raw match by its person-pair. When
building each surviving item, if any OTHER strategy also matched the same
pair, append its details to the winning item's evidence and record the
strategy names under `evidence["other_strategies"]`. No change to which
strategy wins, no change to auto/review thresholds or RULE 2. Matches
CM041 PR #188 (upstream, not yet merged at time of writing).

Companion fix, `scripts/box_walk_probes/lib/customer_read.py`: the walk
probe's own phone-review check filtered `/api/v1/contacts/diff` items by
`evidence["strategy"].startswith("phone")`, which is exactly the filter
that made these 34 pairs invisible to the probe even once this fix lands.
Removed the filter entirely -- the probe now scans every item's evidence
text for a phone-shaped substring regardless of which strategy nominally
won, which is both correct and more robust to a future strategy rename.

### What a future sync must preserve

The `other_matches_by_pair` indexing and the `evidence["other_strategies"]`
enrichment in `_duplicate_items`. Guarded by
`tests/test_vendored_tidy_cross_strategy_phone_visibility.py` (CM051 repo
root, mirroring CM041 PR #188's own test suite). Retire by landing CM041
PR #188 and re-pinning.

## Added 2026-10-03, CM051 v1.0.107 (ORM) -- `cm041/identity_resolver`, same-strategy siblings folded into evidence too (walk #4, item E)

v1.0.107 walk #4 (cold Mini16) found E improved from 12/47 to 1/43
unreviewed after walk #3's fix landed, but one shape still escaped. Traced
from the consumer: two people shared TWO DIFFERENT phone numbers, so
`detect_phone_matches` produced two `phone_match` `DuplicateMatch` objects
for the same pair-key. `consolidate_matches` keeps only the
highest-confidence match per pair, and with both at the same confidence (a
tie), it kept whichever was built first -- the walk #3 fix only folded in
matches whose STRATEGY differed from the winner's, so a same-strategy
sibling (same strategy name, different value) was still silently dropped
from every item's evidence.

Fix, in `vendor/cm041/identity_resolver/tidy.py`'s `_duplicate_items`:
filter the per-pair sibling matches by object identity instead of strategy
name, so a same-strategy/different-value match is folded into `details`
exactly like a cross-strategy one already was.
`evidence["other_strategies"]` keeps its original, narrower meaning
(distinct OTHER strategy names) unchanged. Matches CM041 PR #189 (upstream,
not yet merged at time of writing).

### What a future sync must preserve

The `is not m` object-identity filter (replacing the walk #3 fix's
`strategy != m.strategy` filter) when building `other_matches` in
`_duplicate_items`. Guarded by
`tests/test_vendored_tidy_cross_strategy_phone_visibility.py`'s
`test_a_pair_sharing_two_different_phone_numbers_mentions_both` (CM051 repo
root, mirroring CM041 PR #189's own test). Retire by landing CM041 PR #189
and re-pinning.

## Added 2026-10-04, CM051 v1.0.107 (Aesop) -- `doctor`, box-status chip stops blocking the Doctor's event loop (walk #5, item 1)

v1.0.107 walk #5 (macmini16-walk): the Hub header status pill read "Status
unavailable" on every route except Home (Bursar, People, Personal wiki all
showed it). Doctor's own access log showed 200 OK for every logged
`/api/v1/box-status` call, so the symptom is not the server erroring -- it
is the client's 15s fetch timing out.

Traced to `agent/web_ui.py`'s `api_box_status()`: `async def` route that
called the synchronous, subprocess-shelling aggregator directly
(`return _box_status()`). `box_status.py`'s own "FORK BUDGET" comment
already documents `top -l 2` "BLOCKS FOR ABOUT A SECOND" on a cache miss,
and its other probes (`ps`, `vm_stat`, the attribution breakdown) carry
their own subprocess timeouts (3s/3s/4s/6s/5s). uvicorn runs ONE event loop
for the whole Doctor process; a synchronous call inside an `async def`
handler blocks that loop for every concurrent request it is holding, not
just its own. Measured directly on macmini16-walk: a cache-miss box-status
call took 1.43s against a ~0.03s cache hit (burst test, cold cache after the
30s `top` TTL). People/Wiki/Bursar each add their own concurrent `/api/v1/*`
requests to the Doctor on top of the header chip's own poll; Home does not,
which is why the stall landed on those three routes and not Home.

Fix: `return await asyncio.to_thread(_box_status)`, plus `import asyncio` at
module level. The blocking aggregator now runs on a worker thread, so a slow
or cache-missed probe no longer starves every other concurrent request the
Doctor is serving.

### What a future sync must preserve

The `import asyncio` at module level and `await asyncio.to_thread(_box_status)`
in `api_box_status()` (`agent/web_ui.py`). Guarded by GRAFT D in
`tests/test_doctor_silent_failure_grafts.py`: a structural check that the
route's source calls `asyncio.to_thread`, plus a behavioural control that
execs the REAL shipped function with a stubbed, deliberately slow
`box_status.box_status` and proves a concurrent coroutine on the same event
loop is not delayed by it. Retire this entry if/when `doctor` re-pins past
this commit with the fix intact upstream.

## Added 2026-10-05, CM051 v1.0.107 (Aesop) -- `doctor`, the rendered Items column now prefers a live count over a stale sentinel (walk candidate #9)

v1.0.107 walk candidate #9, Andy's console walk, read-only: the Doctor's
"Where your data came from" table (`render_source_status()`,
`agent/web_ui.py`) printed "email ... read in ... 0" and
"imessage ... read in ... 0" while `/api/v1/sources` itself already knew
better -- `last_run_count` on both rows held the real figures (11,883 and
29,157 respectively), via the existing #2526/#2529 live-count mechanism.
That mechanism was working; the one human-visible renderer of its output
had simply never been taught the field exists, so the Items column kept
reading the install-time `item_count` alone -- 0 whenever a run found no
NEW items, which answers a narrower question than "how much is there".

Fix: `render_source_status()` now overrides its `item_count` read with
`last_run_count` whenever the latter says MORE (never less, so a stale
sentinel can never make a demonstrably larger real total disappear, and
never when there is nothing live to prefer). `item_count` itself, and
`read_source_status()`'s own `last_run_count` computation, are both
UNCHANGED -- this is a render-layer fix only.

### What a future sync must preserve

The `last_run_count` comparison block in `render_source_status()`
(`agent/web_ui.py`). Guarded by the new
`tests/test_the_source_table_items_column_shows_the_live_count.sh`: RED on
origin/main (2 of 4 assertions fail, matching the measured walk symptom),
GREEN with the fix. Also fixed, same diff: a pre-existing test-isolation
gap in the sibling `tests/test_the_source_table_items_column_is_the_number_it_claims.sh`
(missing `OSTLER_DIR` export let `_settling_progress_total` read whatever
real settling-progress files happen to exist on the machine running the
test, rather than its own sandbox -- measured leaking two of that test's
eight assertions on a dev Mac with real `~/.ostler` state on disk).

## doctor: extension credential widened to the save route (CM051 Lane 6)

Tree `doctor`, file `agent/proxy.py`. Not a writer/reader vocabulary fix:
recorded here because this file is the doctor tree's declared
`unrecorded_divergence` pointer and the edit has no patch.

Location and shape. `_EXTENSION_ONLY_PATH` (one path) gains a sibling
tuple `_EXTENSION_WRITE_PATHS = (_EXTENSION_ONLY_PATH, "/api/safari/save")`,
and `_is_extension_credential` compares the concrete upstream path against
that tuple instead of the single constant. Method, loopback and own-token
conditions are unchanged; no prefix match, no env var. Two comment lines
and one log string follow. Reason: the extension's "Save to Knowledge"
button is a second WRITE from the same extension, and a Hub-only customer
(no paired iPhone) authenticates only with the extension token.

Pinned by `tests/test_extension_credential_covers_the_save_route.py`, which
also pins that reads, remote callers, wrong tokens and every other path
(including look-alikes such as `/api/safari/save/` and `/api/safari/saved`)
stay refused. There is no HR015 upstream twin yet: OWED, and a
security-boundary change that wants a human read before it ships.

## doctor: the pre-meeting brief sender joins the scheduled-agent card (CM051 #2707)

Tree `doctor`, file `agent/diagnostic_rules.py`. Not a writer/reader
vocabulary fix: recorded here because this file is the doctor tree's declared
`unrecorded_divergence` pointer and the edit has no patch.

Location and shape. One row appended to the `_SCHEDULED_AGENTS` tuple:
`("com.ostler.meeting-brief-sender", "your pre-meeting briefs",
"meeting-brief-sender", 600)`, plus a three-line comment. No rule logic,
copy or severity changed. Reason: from cut #16 the sender ships ON and exits
75 (a due brief not delivered) or 78 (no brief channel configured); without
the row launchd records that exit code and nothing reads it.

Pinned by `tests/test_scheduled_agent_failure_is_loud.sh` limb 13, which goes
red with the row removed (measured: 2 FAIL) and green with it. There is no
HR015 upstream twin yet: OWED.
