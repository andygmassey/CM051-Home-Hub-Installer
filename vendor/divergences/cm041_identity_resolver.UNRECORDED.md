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
