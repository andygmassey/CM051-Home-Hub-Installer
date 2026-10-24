# cm041/identity_resolver: a divergence recorded ahead of the next patch regen

Hand-built 2026-10-04, walk #6. Per-tree record, following
`cm041_assistant_api.UNRECORDED.md`'s own precedent for a SECOND
divergence on a tree whose `unrecorded_divergence` pointer already named
another file: `WRITER_READER_MISMATCHES.UNRECORDED.md` is NOT superseded
by this file. It still stands, still names `cm041/identity_resolver` (the
CM041 #181 `normalise.py`/`repair_lid_as_phone.py` PII-shape-scan line),
and is still the pointer for the other trees that cite it. Only this
tree's manifest pointer moved to this file, because the pointer is
per-tree and can name only one file; the #181 divergence's own record is
unchanged and unaffected by this graft.

Following the same escape-hatch shape as `cm041_assistant_api.UNRECORDED.md`
and `cm041_contact_syncer.UNRECORDED.md`:
`scripts/regenerate_divergence_patch.sh cm041/identity_resolver` needs a local
CM041 checkout sitting EXACTLY at this tree's pinned sha
(`5cb0c24a75b2af997ea0103f322a5d25a8e733cd`) to regenerate
`cm041_identity_resolver.patch` safely; none was available in this walk's
environment, and the script's own documented reasons for refusing a stale or
advanced checkout (re-pin risk, PII-leak risk on an export from a checkout
ahead of the pin) are exactly why this is a record, not an attempt to force
the regen. Retire this file the next time `cm041_identity_resolver.patch` is
regenerated against a checkout at or past CM041 PR #191 (the upstream of this
graft).

## What diverges

`vendor/cm041/identity_resolver/resolver.py`, two additions, nothing else in
the tree:

1. A new method, `IdentityResolver._sync_qdrant_display_name(person_uri,
   display_name)`.
2. One call to it, added at the end of `canonicalise_display_name`'s
   collapse branch (after the Oxigraph DELETE/INSERT, before the existing
   `logger.info`).

## Why

Walk #6, bug 2: the People list a customer sees first (the Hub's
`people_list`, `vendor/cm041/assistant_api/ical-server.py`) showed a person
by their bare email address even though a real name was available elsewhere
in the graph for the SAME person (measured on macmini16-walk: two distinct
Contacts-linked records, each proven by an `icloud_contact_uid` identifier,
still displayed by email despite carrying `given_name`/`family_name`).

`IdentityResolver` (this file) is Oxigraph-only by construction -- its
`__init__` takes no Qdrant URL and nothing else in the module ever touches
Qdrant. `batch_resolver.py` has a SEPARATE merge path with its OWN Qdrant
sync (`_merge_qdrant`); `canonicalise_display_name` (THIS file's merge/
collapse path, also live in production) had no equivalent. A canonicalise
that only writes Oxigraph leaves the Hub's People list -- which reads ONLY
Qdrant, never Oxigraph -- showing the old name forever.

## Shape of the fix

Deliberately narrow: the new method touches ONLY the `display_name` /
`name` fields of the ONE Qdrant point matching `person_uri` (via the same
deterministic `uuid5(NAMESPACE_URL, person_uri)` id every other Qdrant-
people writer in this tree already uses), and only when a point exists.
It does not merge phones/emails/other scalars across two points and does
not delete a duplicate point -- `batch_resolver._merge_qdrant` already owns
that, and duplicating it here would be a second place for the two to drift
apart. Best-effort and silent-but-logged on failure (missing qdrant-client,
unreachable Qdrant, or any other exception), matching `_merge_qdrant`'s own
stance: the graph-side fix has already landed and must not be undone by a
Qdrant hiccup.

## Guarded by

`tests/test_canonicalise_syncs_qdrant.py` (CM051 top-level `tests/`,
following the `sys.path.insert(..., "vendor" / "cm041")` shim already
established by `tests/test_resolver_robustness.py`). RED confirmed against
the unmodified vendored `resolver.py` via `git stash`, GREEN after. Matches
CM041 PR #191 (upstream, not yet merged at time of writing) and the
identical graft's own tests in CM041 source
(`identity_resolver/tests/test_canonicalise_syncs_qdrant.py`).

Recorded here, not as a patch, for the same reason as the assistant_api
grafts above. Retire by landing CM041 PR #191 and re-pinning (which should
also regenerate `cm041_identity_resolver.patch` from a checkout at the new
pin, folding this note back into the normal patch-tracked history).

## Lane 18 forget tombstone

See the Nineteenth graft in cm041_assistant_api.UNRECORDED.md: the tombstone check in this tree (forget_tombstone.py, and the "forgotten" skip at each create path) is grafted from CM041 PR #200 with the rest of that graft.

Tree `cm041/identity_resolver`: new `forget_tombstone.py` (byte-identical to CM041) and `resolver.py` (`_resolve_tiers` returns `forgotten`; `create_person` raises).
## Person-removal audit (CM051 cut #15 follow-up, walk #15 orphan vector)
## Person-removal audit (CM051 cut #15 follow-up, walk #15 orphan vector; CM041 #210, squash e1107d6c)

Tree `cm041/identity_resolver`. NEW CM041/HR015-side behaviour, not a graft of merged upstream: calls in `resolver.py` `merge_persons`, `batch_resolver.py` `_merge_oxigraph` and `repair_merge_consistency.py` `repair` before each `retirement.retire_update` (type removal of the discard). `repair_lid_as_phone.py` and both `canonicalise_display_name` paths replace a name in one update and remove no one, so they are deliberately not audited.
Added `person_audit.py` (byte-identical copy in every tree that carries one;
`tests/test_person_removal_audit.py::test_the_four_copies_are_byte_identical`
pins that) and ONE `record_person_removal(uri, component, reason)` call placed
immediately BEFORE the removal. It appends a digest-and-shape-only JSON line to
`~/.ostler/logs/person-deletions.jsonl`; never a name, never the URI; never
raises. No SPARQL, no store write and no control flow of the writer changed.

### What a future sync must preserve

The `record_person_removal` call at each site above, and `person_audit.py`.
Guarded by `tests/test_person_removal_audit.py` (each writer's removal lands in
the log: red against origin/main, green here), which also covers the
`people_stores_reconcile` join. Retire by re-pinning past the upstream merge.


## Second graft (DMG #27, 2026-10-13): a merge must not lose the human name

NOT UPSTREAM yet; CM041 needs the same change. A census on a candidate box found
150 of 787 merges putting a named person into a survivor whose displayName was a
phone (145) or an email (5): the name-tier rule (phone < email < human) was not
applied when naming the survivor.

Files, all under `vendor/cm041/identity_resolver/`:

1. `canonical_name.py`: `name_tier`, `upward_name` (appended; nothing existing touched).
2. `resolver.py`: `rename_survivor_upward` (+ `_display_names`), called as step 4b
   of `merge_persons`, before the discard is marked merged.
3. `batch_resolver.py`: `_rename_survivor_upward_oxigraph`, called as step 5b of
   `_merge_oxigraph` (which now returns the new name); `_set_qdrant_display_name`
   syncs the Hub's People list (it reads Qdrant); the call site uses it.
4. `repair_merge_consistency.py`: `misnamed_survivors` / `rename_survivors_upward`,
   run on every repair pass (idempotent), so EXISTING merges are renamed on upgrade.

Rule: the survivor takes the discard's best name only when it is a HIGHER tier than
anything the survivor carries; two human names keep the existing rule; a survivor
with no name is left to the existing copy step. NOT done here (v1.0.108): following
`mergedInto` to a differently-named survivor on lookup (may be an over-merge), and
the wiki compiler emitting pages for retired-only people (CM044).

Guarded by `tests/test_merge_survivor_takes_highest_name_tier.py` and the walk
assertion in `scripts/box_walk_probes/probes/no_person_holds_two_contact_cards.sh`.

## The owner anchor is never an auto-merge candidate (CM051, 2026-10-14)

Tree `cm041/identity_resolver`, file `batch_resolver.py`, function
`_fetch_all_persons`: one added `FILTER NOT EXISTS { ?person pwg:isOwner true }`.

- Why: install.sh now mints the owner anchor (`pwg:user_<id>`, `pwg:isOwner
  true`, the owner's name and nothing else) through
  `contact_syncer/owner_node.py`, which had no call site (walk #27: 0 isOwner
  triples). exact_name scores 0.9, over the 0.8 auto-merge threshold, so the
  next batch pass would pair the anchor with the owner's own contact card (or
  a namesake) and `pick_canonical` could keep the card and tombstone the
  anchor. Relating fragments to the owner stays with
  `lib/ostler-confirm-identity.py`, behind the owner's confirmation.
- No patch: same refusal as the entries above. Upstream mirror owed in CM041.
- Test: `tests/test_owner_node_is_minted_and_read.py`.

## An identical name is a "Same person?" suggestion, never an automatic merge (DMG #27 item 4)

File `vendor/cm041/identity_resolver/batch_resolver.py`. `import re` added.
`PersonRecord` gains `organizations` and `contact_card_uids` (sets, default
empty), filled by `_fetch_all_persons` from every `pwg:organization` row and
every `icloud_contact_uid` identifier. New `DEFAULT_CONFIG`
`same_name_suggest_confidence` (0.6: above `review_threshold`, below
`auto_merge_threshold`). New helpers `_ORG_SUFFIXES`, `_org_tokens`,
`employers_overlap`, `_has_employer` placed before
`detect_exact_name_matches`, whose pair loop now: skips a pair whose
employers are both present and disjoint unless both are Contacts cards (a
common name at different employers stays apart; it used to auto-merge at 0.9
when neither held an identifier); emits a `same_name_suggest` match (review
only) for that card pair and for two different cards with overlapping or
absent employers; otherwise unchanged. `has_hard_conflict` still vetoes first.

WHY: one real contact split across three nodes (identical full name,
different employer cards, no shared phone or email). Archie's ruling: no
automatic merge, a suggestion the owner confirms through the existing
duplicates review (`needs_review`, `duplicates.yaml` decisions).

Guarded by `tests/test_same_name_is_a_suggestion_not_a_merge.py`, wired in
`.github/workflows/walk-defect-e-duplicate-evidence-guard.yml`. Upstream CM041
mirror OWED; no re-vendor.

## cm041/identity_resolver: an unreadable forget tombstone is never overwritten (walk #28, sweep V22)

`vendor/cm041/identity_resolver/forget_tombstone.py`: `record()` used to log
"starting a new one" on a `TombstoneUnreadable` and write a fresh file over
it, wiping every earlier Forget. It now leaves the file in place (so
`is_forgotten()` stays fail-closed for every syncer), copies its bytes to
`<file>.unreadable-<sha12>` (new `_set_aside()`), and returns False. New
`problem()` returns the reason for callers that must say why. The
`vendor/ostler_fda/forget_tombstone.py` copy is kept byte-identical. Guarded
by `vendor/cm041/assistant_api/tests/test_forget_reports_only_what_it_erased.py`
(job `forget-reports-only-what-it-erased` in
`.github/workflows/forget-tombstone.yml`). Upstream CM041 mirror OWED.

## cm041/identity_resolver: an exact shared identifier merges two Contacts cards of one person (v1.0.107 #30)

`batch_resolver.py`: `execute()` used to refuse every planned merge whose nodes
carried different `icloud_contact_uid` values (RULE 2). Measured on the Mini16,
66 of 70 same-name pairs sharing an exact email or phone were refused that way
(one person, two Contacts cards). New `_exact_identifier_override()` and
`_all_canonical_conflicts()` let an exact shared identifier override a refusal
whose ONLY conflicting canonical key is the card uid; policy is in the new
vendor-only module `exact_identifier.py` (full-name equality, usable shared key,
no hard veto, key not held by 3+ distinct names). `detect_email_matches`,
`detect_phone_matches` and `detect_linkedin_url_matches` downgrade a key held by
3+ distinct names to review. Every merge now calls the new vendor-only
`merge_journal.record_merge()` BEFORE the first write (no snapshot, no merge);
`--undo-merge ID` / `--list-merges` added to `main()`; `converge()` stops when a
round executes nothing; `MergeAction.merge_id` added; the converge summary counts
executed merges, not planned ones. Linkedin conflicts are compared in canonical
form on this path only.

Guarded by `tests/test_exact_identifier_merge.py` (rdflib-backed store, 23
tests, wired in `.github/workflows/exact-identifier-merge.yml`).
`tests/test_converge_path_enforces_rule2.sh` now stubs `record_merge` like it
already stubs `_backup_triples`. Upstream CM041 mirror OWED; no re-vendor.
Update: the journal snapshot also carries the pair's Qdrant `people` points
(id, vector, payload); `--undo-merge` restores them before the graph. New
vendor-only code in `merge_journal.py`; `batch_resolver.py` passes
`qdrant_url`/`qdrant_collection` to `record_merge` and `qdrant_url` to undo.
Update: no vector snapshot, no merge. `record_merge` raises `SnapshotUnavailable`
when Qdrant cannot be read; `execute()` skips the pair, journals a `skip`
(reason `qdrant_unavailable`), and the next converge retries. Not a RULE 2
refusal, not a pin.

## Nameless pair on one number resolves to one person (CM051 #2545, 2026-10-21)

NO UPSTREAM COUNTERPART (checked CM041 origin/main e2dffc0, 2026-10-21):
`_identifier_match_trustworthy` and the BW-1 name-agreement guard exist only in this
vendored tree (graft from CM051 #2663); upstream `resolve()` Tier 1 merges on a shared
exact identifier after RULE 2 alone, so the nameless pair already merges there and
there is nothing to port. Upstreaming this change means upstreaming the whole BW-1
guard first, which reverses upstream's RULE 1 and is a decision for Andy/Archie, not
a like-for-like port. This record stays until that decision is made.

Tree `cm041/identity_resolver`, `resolver.py` only: `_identifier_match_trustworthy`
gains one early return, a new `_person_display_names` reads EVERY displayName on the
node (the old unordered LIMIT 1 let store order decide whether a node holding both a
phone-shaped and a human name read as nameless; `_person_display_name` stays as a
deterministic wrapper), and the module imports `name_tier` and `NAME_TIER_HUMAN`
from `canonical_name.py` (already in the tree, nothing there touched).

Why: the BW-1 guard trusted a shareable (phone/email) match only when both display
names were present and equal. A Contacts card with no name (job title only) and a
messaging handle on the same number are both nameless, so the guard declined and a
second person was minted: two "Unknown contact" rows on one number on the v1.0.106
walk box. Measured by reproduction against the shipped syncer and resolver over an
rdflib store: card `""` + phone, then handle `""`/phone-as-name + same phone gave
`match_type=new`.

Fix: when NEITHER the incoming name nor the matched node's name is human-tier
(blank, phone, email or system alias), there is no name to disagree about and the
match is trusted. RULE 2 runs first and is untouched, so two Contacts cards with
different `icloud_contact_uid` still never merge. A human name on either side keeps
the existing name-agreement rule: different human names on one line stay two people,
and a nameless handle beside a NAMED card still declines.

Guarded by `tests/test_nameless_records_sharing_a_number_are_one_person.py` (3 red on
the unmodified resolver for the single-name cases and 3 more for the two-name node
in every store order; all green here; mutant dropping the matched-node side goes
red on the named-card control). Does NOT repair duplicates already in an installed
graph: the BatchResolver exact-identifier tier requires the same full name, so
existing nameless pairs are not collapsed by this change.

## 2026-10-22: re-vendor to CM041 main 07a22b4c (pin 5cb0c24a -> 07a22b4c)

3-way merge result is byte-identical to the tree before the re-pin: every
upstream change in the range (#186 to #191, #200, #210) was already grafted.
KEPT: exact_identifier / merge_journal imports in batch_resolver.py,
rename_survivor_upward and the degraded-resolve wrapper in resolver.py, the
upward_name import in repair_merge_consistency.py, the unreadable-tombstone
set-aside in forget_tombstone.py, the composed 15-digit control in
repair_lid_as_phone.py. NOT VENDORED, now declared in `exclude`:
repair_kinship_display_names.py, repair_misformatted_phones.py,
reconcile_people_stores.py (operator repair tools, never shipped).

WHY THE PATCH IS NOT REGENERATED: regenerate_divergence_patch.sh refuses
(the 15-digit literal upstream keeps in repair_lid_as_phone.py would land on
the MINUS side). The checked-in patch is stale against the new pin; the
content gate reads RED for this tree, as on main before this change.
