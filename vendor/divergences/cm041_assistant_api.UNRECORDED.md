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

THE REASON, AND THE FIRST VERSION OF THIS PARAGRAPH WAS WRONG IN A WAY THAT
MATTERS MORE THAN THE REFUSAL. It said the tool had detected a value of
personal-contact shape that upstream still carried and the vendored tree had
scrubbed, and that a re-vendor was blocked until CM041 removed it at source.

**There was never any PII in CM041.** Board row 2207 had already established
this before the sentence above was written, and states the cost of getting it
wrong exactly: the wrong wording sends the next reader hunting a breach that
does not exist.

What is actually true. Upstream `assistant_api/API.md` carried an ALL-ZEROS
NANP placeholder, which CM041's own fixture gate tolerates BY NAME at
`tests/test_fixtures_have_no_real_contact_detail.py:173` as an obvious
placeholder. The vendored copy had changed it, so it landed on the MINUS side
of the regenerated diff and the tool refused. **The tool was not detecting a
leak. It was refusing to certify an uncertifiable shape**, because its allowlist
admits only STANDARDS-RESERVED values, and a convention is not a standard.

The MEASUREMENT above is unchanged and nothing was published. Only the reading
of why it refused was wrong, and the corrected reading makes the remaining work
smaller rather than larger.

`SYNC_ACCEPT_DIVERGENCE_LOSS=1` was not used and must not be, which is unchanged
and is about this graft rather than about the placeholder.

## What is owed, and by whom

1. Re-pin, which is a small job rather than a project. Row 2207 measures this
   tree as ONE commit behind, and CM041 #173 already moves four occurrences of
   the placeholder to a NANP 555-01xx value, checked as a PROPERTY rather than
   as a string, with that repo's own PII gate passing. So this constraint
   retires on a re-pin and needs no new work here.
2. Push the same erasure fix upstream to CM041 so the two converge.

Neither is done. Recording that plainly, including the part where the first
account of it was wrong, is the whole point of this file.

## 2026-09-19 -- L3 filter on the two relationship-signal readers (CM051 #2266, board row 2213)

WHAT: `?spriv` added to both signals SELECTs, `OPTIONAL {{ ?signal
<urn:ostler:privacyLevel> ?spriv }}` added to both WHERE clauses, `LIMIT 1`
raised to `LIMIT 10`, and `pwg_privacy.filter_l3_facts(...)` applied to the
result at both sites (person_context, owner `person.get("priv")`;
person_enrichment, owner `row.get("priv")`).

WHY IT IS HERE AND NOT IN THE PATCH. `scripts/regenerate_divergence_patch.sh
cm041/assistant_api --write` was RUN, not assumed, and twice:

  against the CM041 checkout as found (HEAD 82f4537)
      REFUSED -- the source has advanced past the pin. Correct: regenerating
      there would fold upstream #137 into the patch and record it as a local
      edit to this repo.

  against a worktree detached at EXACTLY the pin 9be482d3, so no upstream
  commit could be folded in
      REFUSED -- the patch it would record carries PII-shaped content. Pattern
      name only, value deliberately not reproduced. The tool names the MINUS
      side as the likely location: upstream still carries a value the vendored
      tree has scrubbed, so recording the divergence would publish it back into
      this PUBLIC repo.

That second refusal is the tool working, not a bug, and it is the same refusal
already recorded on this tree. It is NOT clearable by re-syncing: a re-sync
deletes the vendored side, which is where the scrub lives. It clears by removing
the value from the SOURCE, re-pinning, and bringing the graft forward. CM041 #173
is the upstream half of that and is already cited on this tree's hold_ack.

CONSEQUENCE, STATED PLAINLY: `verify = "full"` on this tree cannot reconstruct
while this graft is unrecorded, and a `sync_vendor.sh` that accepts divergence
loss would DELETE this privacy fix silently. A sync refusal on this tree is
EXPECTED and correct. Do not pass SYNC_ACCEPT_DIVERGENCE_LOSS=1.

RE-APPLY AFTER ANY sync_vendor.sh OF THIS TREE.

## 2026-09-28: service senders withheld from reconnect and birthday suggestions

Location: `vendor/cm041/assistant_api/ical-server.py`, new `_is_service_sender`
(with `_SERVICE_SENDER_NAMES`, `_SERVICE_MAILBOX_LOCALPARTS`) directly above
`_is_nameless_name`, and one call at each of the two suggestion loops (after
`_is_not_a_person_to_suggest`). Shape: suggestion-only screen, nothing hidden or
deleted. Reason: a "You and Skype have gone quiet" card on the v1.0.105 console
walk. Guarded by `tests/test_service_senders_get_no_reconnect_card.py`. Must be
upstreamed to CM041 before the next `sync_vendor.sh` of this tree.
## Second graft: the Timeline window, types and titles (CM051 #2469, 2026-09-28)

Tree `cm041/assistant_api`, file `vendor/cm041/assistant_api/ical-server.py`,
functions `_timeline_from_graph`, `_timeline_conversations`, `api_timeline`,
the `/api/v1/timeline` handler, and new helpers `_safe_iso_day`,
`_conversation_title`, `_CHANNEL_LABELS`.

Why: on Andy's v1.0.105 walk the Timeline opened a year ahead and ended part
way through today (the graph query had no upper date bound and sorted
newest-first, so future all-day entries filled the 200-row cap), labelled every
row MEETING (the entries mapper collapsed every non-meeting kind to
`calendar`), and titled conversations with the bare channel. The graft adds an
opening window (up to today + `days`) and `before=`/`after=` paging
(validated YYYY-MM-DD before any SPARQL interpolation), real kinds, and
titles that name who.

Recorded here, not as a patch, for the same reason as the erasure graft above:
the tree's patch cannot be regenerated. Guarded by
`tests/test_the_timeline_opens_on_today.py`. Retire by landing it in CM041
`assistant_api/ical-server.py` and re-pinning.

## Third graft: role-address-only names are not listed as people (CM051 #2489, 2026-09-30)

Tree `cm041/assistant_api`, file `vendor/cm041/assistant_api/ical-server.py`,
new `_ROLE_ADDRESS_LOCAL_RE` and `_is_role_address_name` directly above
`_is_service_sender`, and one `continue` in `people_list` right after the
empty-name skip. Shape: the People LIST only; nothing is deleted, and search
and the assistant still find the record. Reason: on the v1.0.106 walk the
People list showed records whose only name was a support or promotions
mailbox. Judged by the local part, never the domain. Guarded by
`tests/test_role_addresses_are_not_listed_as_people.py`. Recorded here, not as
a patch, for the same reason as the grafts above. Retire by landing it in
CM041 and re-pinning.

## Fourth graft: the Hub's own people count applies the locked nameless filter (CM051 #2568, 2026-10-01)

Tree `cm041/assistant_api`, file `vendor/cm041/assistant_api/ical-server.py`,
one `continue` in `people_list`, replacing `if not name: continue` with
`if _is_nameless_name(name): continue` (the role-address check above still
runs right after it, unchanged). Shape: the People LIST only; nothing is
deleted. Reason: `if not name` only caught an EMPTY display name -- case 1
of `_is_nameless_name`'s three. A WhatsApp-JID-shaped or bare-phone-shaped
"name" (cases 2 and 3) passed straight through, so the Hub's own count
included rows the wiki (`compiler/nameless.py`) and iOS (`PersonNameFilter`)
both hide -- the Hub/wiki count gap. `_is_nameless_name` itself is untouched
(no new predicate, reused the LOCKED one, Ref #664). Guarded by
`tests/test_nameless_filter_applies_to_the_hub_people_count.py`. Recorded
here, not as a patch, for the same reason as the grafts above. Retire by
landing it in CM041 and re-pinning.
