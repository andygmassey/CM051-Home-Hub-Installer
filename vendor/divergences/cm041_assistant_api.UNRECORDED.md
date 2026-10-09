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

## Fifth graft: ai_summaries trusts its own numbers, and wiki_ready ignores conversations (board #2562-G, v1.0.107 candidate #5, 2026-10-03)

Tree `cm041/assistant_api`, file `vendor/cm041/assistant_api/ical-server.py`,
function `api_hydration_status`. Regeneration tool re-run today: CANNOT-RUN
(no `$CM041` source checkout available in this environment to verify
against), not a refusal -- recorded here by location and shape rather than
left unrecorded while the tool cannot be exercised.

Two changes, both inside `api_hydration_status`:

- The `ai_summaries` phase's `else` branch (compiler status present, `complete`
  not set) gained one new arm: when `done >= total` (and `total > 0`, the
  existing zero-total branch above still owns "no work yet"), the phase now
  reads "done" the same way the explicit `complete` flag already does two
  branches up. MEASURED on a walk box: stage_done=200, stage_total=200,
  `complete` unset, phase stuck at "running" forever -- the branch trusted
  the upstream flag exclusively and never compared the numbers it already
  had. Mirrors v1018-D007 above in this same function (there the flag said
  done and the numbers were ignored; here the numbers say done and the flag
  is ignored).
- A new top-level `wiki_ready` boolean in the returned dict: `all(s == "done"
  for s in gating)`, reusing the `gating` list (contacts/graph/ai_summaries)
  the function already computes for `overall_state`. Andy's decision: one
  failed phase must never hide the whole wiki. `overall_state` reads
  "needs_attention" the instant conversations has any failure (MEASURED on
  the same walk box: 10 of 17 dispatched), with the wiki itself fully built
  underneath. `wiki_ready` answers the narrower question a wiki-frame gate
  actually needs, independent of conversations, which is still surfaced via
  `overall_state` and the `conversations` phase's own counts, never hidden.

Shape: additive. No existing field, key or branch removed; `overall_state`'s
own semantics are untouched. Guarded by
`tests/test_wiki_ready_ignores_conversations_and_ai_summaries_trusts_its_own_numbers.py`.
Recorded here, not as a patch, for the same reason as the grafts above.
Retire by landing it in CM041 and re-pinning.

## Fifth graft: a processor crash's failure_reason keeps the tail, not the head (CM051 walk #5, v1.0.107)

Tree `cm041/assistant_api`, file `vendor/cm041/assistant_api/ical-server.py`,
`_conversation_process_background`: one line, `result.stderr[:500]` ->
`result.stderr[-500:]`, on the branch that records a `failed_step=
"processor"` reason when the `pwg-convo` CLI subprocess exits non-zero.
Shape: diagnostic text only, nothing is deleted and no decision changes.
Reason: a crashing subprocess writes its INFO-level progress logging FIRST
and any traceback/exception message LAST, so the first 500 characters of a
long stderr stream is guaranteed to be ordinary logging with the real error
cut off before it ever printed. Measured on a cold v1.0.107 install: every
"processor"-failed conversation's `failure_reason` ended abruptly mid
log-line, e.g. `"...src.processor: Enriching 2026-10-03_0e"` -- not a
reason at all. The sibling `str(exc)[:500]` branch a few lines below (a
single exception's own message, not a multi-line subprocess log) is
untouched on purpose -- that shape puts the useful part first. Matches
CM041 PR #190 (upstream, not yet merged at time of writing). Guarded by
`tests/test_vendored_conversation_process_failure_reason.py`. Recorded
here, not as a patch, for the same reason as the grafts above. Retire by
landing CM041 PR #190 and re-pinning.

## Sixth graft: a transient processor crash is retried once before the conversation job is marked failed (CM051 walk #5, v1.0.107)

Tree `cm041/assistant_api`, file `vendor/cm041/assistant_api/ical-server.py`,
`_conversation_process_background`: the single `_invoke_pwg_convo(...)` call
is now a bounded loop (max 2 attempts, 15s backoff) that retries ONLY on a
non-zero exit or a timeout; `FileNotFoundError` (pwg-convo missing from
PATH) and any other setup/config exception break the loop immediately and
are not retried, since those are deterministic. Shape: control flow only --
every existing failure-reason string and the step name are unchanged;
`state["retry_count"]` now reflects attempts actually made instead of
always being left at its initial 0. Reason: 4 of 18 cold-install
conversation jobs failed_step=processor, all created in the same second (a
backfill burst, identical metadata shape), all crashing during the first or
second Ollama call. Re-running the exact saved input for all 4 in
isolation, and again concurrently in the original 4-at-once shape, on the
same box, succeeded cleanly every time (exit 0, full pipeline) -- the input
is provably processable, so this is a transient cold-start contention
window (Ollama/model still loading while install.sh is also still running
its own setup steps), not legitimately unprocessable input. CM052's
cli.py (~446-481) watermarks a conversation on a successful POST
regardless of this downstream failure, so nothing else ever retries it;
this is the smallest fix that does not require touching CM052. Matches
CM041 PR #190 (upstream, not yet merged at time of writing). Guarded by
`tests/test_vendored_conversation_process_failure_reason.py`
(`TestConversationProcessBackgroundRetry`-equivalent cases). Recorded
here, not as a patch, for the same reason as the grafts above. Retire by
landing CM041 PR #190 and re-pinning.

## Seventh graft: the Hub's People list excludes service/notification senders, prefers a known real name over a bare identifier, and excludes the owner (CM051 walk #6, v1.0.107)

Tree `cm041/assistant_api`, file `vendor/cm041/assistant_api/ical-server.py`,
three additions in and around `people_list`, plus three new module-level
helpers (`_looks_like_bare_email_or_phone`, `_SERVICE_NAME_SUFFIX_WORDS` +
`_is_automated_or_service_name`, `_load_people_list_self_uris`). Shape:
exclusion/relabelling only, nothing deleted.

Andy's screen read of the People page on macmini16-walk found the top 10
"recent" rows mostly wrong, in three ways (synthetic shapes standing in
for the real rows, never quoted): (1) 6 of 10 were non-people -- a carrier
notification sender, a marketplace, an email SUBJECT LINE, an all-caps
company name, a `#`-prefixed handle, a "Rate advice"-style service --
shapes `_is_nameless_name` (empty / WhatsApp-JID / bare-phone only) and
this vendor's own `_is_role_address_name` (role mailboxes) were never
designed to catch; (2) 1 of 10 showed a known contact (proven by an
`icloud_contact_uid` identifier) by their bare email although
given_name/family_name were present on the SAME record -- the write-time
precedence rule never re-fires once a point already has a stored name, and
the read layer trusted the stored value as-is; (3) 2 of 10 were the OWNER
himself, once by name and once by his own email -- two separate Person
nodes for the same physical person, neither excluded.

`_load_people_list_self_uris` is a LOCAL reimplementation of the concept in
CM041 source's `person_facts.sources.load_self_uris`, not an import of it:
`person_facts` is a sibling package in the CM041 source repo but is NOT
part of this vendored `vendor/cm041` tree (measured: assistant_api,
contact_syncer, identity_resolver, meeting_syncer, ostler_hygiene only).
An import would have worked in CM041's own test suite and silently no-op'd
on every shipped install -- the exact "ships dark" shape this fix exists to
avoid elsewhere in this tree.

Matches CM041 PR #191 -- CORRECTED 2026-10-04: this previously cited PR #192,
which does not carry this content. #191 squash-merged to CM041 main as
`51aba0f` and its 4-commit log (readable via `gh pr view 191 --json commits`)
confirms rounds 1 AND 2 of this walk landed there, not round 1 alone as an
earlier draft of this entry assumed. #192 was opened on the mistaken belief
that rounds 2-3 were still unmerged, found CONFLICTING against CM041 main for
exactly this reason (its branch replayed round-1/2 content already present at
`51aba0f`), and was closed in favour of #193, which carries ONLY round 3 (see
the Eighth graft below) -- adapted here to run alongside this vendor's own
`_is_role_address_name` check, which CM041 source does not yet have. Guarded
by `vendor/cm041/assistant_api/tests/test_people_list_endpoint.py` (ported
from CM041 source's own file of the same name, with this vendor's
Authorization-token enforcement wired into the test harness -- CM041
source's copy of `ical-server.py` does not enforce it in this test
context). RED confirmed against the unmodified vendored `ical-server.py`
via `git stash`, GREEN after. Recorded here, not as a patch, for the same
reason as the grafts above. Retire by re-pinning to CM041 main, which
already contains this via #191 (`51aba0f`) -- no further PR to land for
rounds 1-2.

## Eighth graft: owner-exclusion by email/phone, plus the plist delivery that feeds it (CM051 walk #6 round 3, v1.0.107, #2629)

Tree `cm041/assistant_api`, same file, same function
(`_load_people_list_self_uris`). The Seventh graft's owner-exclusion arm
could only match by NAME (`USER_NAME`, confirmed delivered to this process's
LaunchAgent plist) or by `USER_ID`-derived anchor. Archie's round-3 review
found that insufficient: the box's own screen read showed the owner also
duplicated by his own EMAIL, which no arm there could reach.

Two coupled changes, one PR (#2629), both needed together:

1. `install.sh`'s `com.ostler.ical-server` LaunchAgent plist heredoc now also
   writes `USER_EMAIL` and `USER_PHONE` into `EnvironmentVariables`, same
   `<key>X</key><string>${X}</string>` pattern as the pre-existing `USER_NAME`
   key. Verified `plutil -lint`: OK; `tests/test_v1010_ical_doctor_service_auth.sh`:
   7/7 pass; no `--` inside any XML comment (checked explicitly, CM051's own
   XML-comment gate catches that class).
2. `_load_people_list_self_uris`'s email arm now reads `USER_EMAIL` (falling
   back to the historically-named but unwired `CARDDAV_USERNAME`); a new
   phone arm reads `USER_PHONE`, matching on a shared 7+ digit SUFFIX rather
   than full equality, to tolerate a stored number carrying a country-code
   prefix the configured value omits (or vice versa) -- KNOWN LIMIT: not a
   full E.164 normaliser.

MEASURED REGENERATE REFUSAL (Archie's requirement for this entry, run
2026-10-04 with `VENDOR_SRC_CM041_ASSISTANT_API` pointed at a CM041 source
checkout): `scripts/regenerate_divergence_patch.sh cm041/assistant_api`
refuses with

    The SOURCE has advanced past the pin. Unshipped commits touching this tree:
        72bf3a3 fix: reword the phone-suffix comment to avoid a literal PII-shaped example
        81daa9e fix: owner-email/phone self-exclusion arms read USER_EMAIL/USER_PHONE; correct a wrong CM044 claim (walk #6 round 3)
        51aba0f fix(assistant_api,identity_resolver): People list excludes service senders, ... (#191)
        6307197 fix(assistant_api): a processor crash's failure_reason must keep the tail, not the head (walk #5) (#190)
        4940790 fix(people): the Hub's own count now applies the locked nameless filter (#183)

    REFUSED: this is a RE-PIN, not a graft to record.

Exactly the tool's documented behaviour for a tree whose pin trails its
source by several commits (exit 1, not a crash) -- regenerating now would
fold four unrelated, already-upstream commits into the divergence patch as
if they were local edits to this repo. This is NOT a new defect: the pin has
trailed CM041 main since before this walk; it is recorded here because
Archie asked for the measurement, not because this graft caused it.

Guarded by `vendor/cm041/assistant_api/tests/test_people_list_endpoint.py`,
class `TestLoadPeopleListSelfUris`:
`test_user_email_match_contributes_that_persons_uri`,
`test_user_email_takes_precedence_over_carddav_username`,
`test_user_phone_match_contributes_that_persons_uri`,
`test_user_phone_match_tolerates_a_country_code_prefix_mismatch`, and the
negative control `test_control_a_short_shared_phone_suffix_does_not_false_match`
(a short shared tail must NOT false-match). RED confirmed against the
unmodified vendored `ical-server.py` via `git stash`, GREEN after.

Matches CM041 PR #193 -- UPDATED 2026-10-04: merged to CM041 main as
`c6230ac` shortly after this entry was first written (supersedes the
now-closed #192, see the correction above). Recorded here, not as a patch,
for the same reason as the grafts above. Retire by re-pinning to CM041
main, which now contains this via #193.

## Ninth graft: widened service/notification coverage + email-name duplicate precedence (CM051 walk #6 round 4, v1.0.107)

Tree `cm041/assistant_api`, same file, `_is_automated_or_service_name`
(widened), two new helpers (`_is_service_mailbox_name`,
`_SERVICE_NAME_PHRASE_RE`/`_MARKETPLACE_BRAND_RE`/`_SERVICE_MAILBOX_LOCAL_RE`),
and `people_list`'s main loop (a new `human_named_emails` precomputation
plus a new skip branch). Shape: widening + one new exclusion branch,
nothing deleted.

Archie's SECOND screen-read of macmini16-walk's People page (2,584 rows,
post-round-3) found two more defect classes: (1) 12 rows that are
services/notifications/subject lines round 1-3's checks could not reach --
7 where the vocabulary word (rewards/gift/update/delivery) is not the LAST
word (round 1 checked last-word-only), 1 marketplace-brand row, and 4
"service mailbox" rows whose NAME IS an email address (3 brand-bearing, 1
`ebill`-prefixed); (2) 3 rows named by a bare email address while a
separate, human-named row shares that same address -- two Person records
for one real contact. Still uncarded-only throughout, per Archie's
explicit instruction.

Widened vocabulary and the new marketplace-brand/service-local regexes are
independently-written copies of the SAME shapes CM051's own box-walk audit
tooling already uses (`scripts/box_walk_probes/lib/customer_read.py`:
`SERVICE_PHRASE`, `MARKETPLACES`, `SERVICE_LOCAL`) -- not an import, for
the same reason `_load_people_list_self_uris` reimplements rather than
imports `person_facts`: this file ships to a vendor tree that does not
carry CM051's `scripts/` directory. Two independent implementations
agreeing is a stronger signal than one shared one.

MEASURED on macmini16-walk, read-only, same box as the Eighth graft's
regenerate-refusal measurement: 2,584 -> 2,567 (delta 17). Breakdown:
self-exclusion 4 (already proven round 3), nameless 194 (pre-existing),
automated-or-service 38 (pre-existing round 1-2 catches plus this round's
widened vocabulary -- the 3 brand-bearing service-mailbox rows are caught
here too, since an email address containing a marketplace brand token now
also trips this check), service_mailbox 1 (the `ebill` row specifically),
email_collision_dup 3 (matches Archie's reported count exactly). The box
was still background-hydrating during measurement (created_at timestamps
spanning the same session), so a repeat measurement will not reproduce
bit-for-bit -- the SHAPE of each number was validated against Archie's
facts file, not an exact repeat count.

Guarded by `vendor/cm041/assistant_api/tests/test_people_list_endpoint.py`,
classes `TestServiceShapesRound4`, `TestServiceMailboxNames`,
`TestEmailNamePrecedenceRound4` -- including controls for word-boundary
(no substring false-positive), carded-always-wins (using an `ebill`-shaped
local part specifically, since this vendor's own PRE-EXISTING
`_is_role_address_name` check already catches `no-reply@`-shaped names
UNCONDITIONALLY and would have confounded a card-gating test built on that
vocabulary), lone-email-unaffected, and the given/family-on-itself case
that round 1's existing upgrade handles, not this one's. RED confirmed
against the unmodified vendored `ical-server.py` via `git stash`, GREEN
after.

Matches CM041 PR #194 -- UPDATED 2026-10-07: merged to CM041 main as
`a5cbb52` since this entry was first written. Recorded here, not as a
patch, for the same reason as the grafts above. Retire by re-pinning to
CM041 main, which now contains this via #194.

## Tenth graft: suggestion producers never applied the People-list filters (CM051 walk #6 candidate #10)

Tree `cm041/assistant_api`, same file: `people_stale`, `people_recent`,
`people_birthdays`, plus a new reusable helper, `_load_carded_uris(uris)`.
Matches CM041 PR #195 (upstream, open at time of writing).

Archie: the phone's People tab reads `/api/v1/suggestions`
(`api_suggestions`, a composite of these three producers), which never
applied the filters `people_list()` already uses -- an organisation, an
unresolved service record, or the owner's own entry could all surface as
a suggestion.

**This vendor tree was ALREADY AHEAD of CM041 source on part of this**,
which changes the shape of the graft from a straight port. `people_stale`
and `people_birthdays` already call this vendor's OWN
`_is_not_a_person_to_suggest` (exact `USER_NAME` string match, plus
`#`-shortcode and bare-address shapes) and `_is_service_sender` (a fixed
brand denylist, e.g. `paypal`/`skype`, plus an all-role-mailbox address
check) -- both measured and walked on real boxes (v1.0.100, v1.0.105) per
their own docstrings. `people_recent` had NEITHER mechanism at all, the
exact same gap as CM041 source.

Decision: ADD CM041's new checks (`_load_people_list_self_uris`,
`_is_automated_or_service_name`, `_is_service_mailbox_name`, uncarded-only)
as a SECOND, complementary layer in `people_stale`/`people_birthdays`,
not a replacement -- grafting upstream over a vendor-side improvement, or
deleting one to make room, is the exact failure this manifest's own
history already warns about. The two layers catch different things: this
vendor's own checks reach a brand denylist and an exact-name match; the
new checks reach an owner identified by email/phone (not just an exact
`USER_NAME` string) and shape patterns (notification phrasing, marketplace
brands, `ebill`-style mailboxes) no fixed denylist enumerates. Neither of
this vendor's own two checks is card-gated -- a PRE-EXISTING property of
its own mechanism, unchanged here, not something this graft fixes or
widens. `people_recent` gets BOTH mechanisms, brought up to the same
(now doubly-protected) standard as the other two.

MEASURED, not assumed: `_is_service_mailbox_name` is fully subsumed by
this vendor's own `_is_not_a_person_to_suggest` for every email-shaped
case (its "contains @, no space" rule is unconditional and strictly
broader), confirmed by this PR's own test suite -- two of the twelve new
tests pass on UNMODIFIED code too and are labelled as controls, not
isolating proof, rather than claiming coverage the measurement does not
show.

Guarded by
`vendor/cm041/assistant_api/tests/test_suggestions_apply_people_list_filters.py`,
12 tests (ported from CM041 PR #195, adapted: the owner-dropped tests use
`USER_EMAIL` + `_load_people_list_self_uris`'s dynamic email-match arm
rather than `USER_NAME`, since this vendor's `_is_not_a_person_to_suggest`
reads `USER_NAME` as a MODULE-LEVEL global frozen at import time, which a
test-time env patch cannot reach). RED confirmed against the unmodified
vendored `ical-server.py` via `git stash` (7 of 12 fail -- the 2
subsumed-shape controls above pass on both sides, by design, alongside
the 3 carded-human-stays controls), GREEN after.

Retire by landing CM041 PR #195 and re-pinning.

## Eleventh graft: conversation_id ignored metadata.meeting_id, causing silent data loss (CM051 v1.0.107 candidate #10)

Tree `cm041/assistant_api`, same file: `api_conversation_process`, plus two
new helpers, `_is_safe_meeting_id` and `_resolve_fallback_conversation_id`.
Matches CM041 PR #196 (upstream, open at time of writing).

`conversation_id` was built as `date_firstTwoSpeakerLabels_type` and
ignored `metadata.meeting_id`, the per-session UUID the iOS/Watch app
sends with every recording. Every Watch conversation on the same day
collided as `<date>_s1_wearable`: the second POST overwrote the first
conversation's raw transcript, CM048 then skipped the overwritten one as
already-complete, and the Hub still returned 202 so the app deleted its
(now only) copy. The conversation was gone. Affects any capture path
whose speaker labels repeat on the same day, including the Mac's.

This vendor tree's `api_conversation_process` has its own divergence from
CM041 source (the Rule 0.8 subscription-pause gate, and a pre-flight probe
of the `pwg-convo` CLI via `_invoke_pwg_convo` in place of CM041's direct
`OSTLER_VENV_PYTHON` subprocess call) -- both untouched by this graft. The
id-generation block the graft touches is byte-identical between the two
trees before this change, so the port is a straight copy of the new
block, not an adaptation.

`conversation_id` now prefers `metadata.meeting_id` when it validates as a
UUID or a path-safe slug (`_is_safe_meeting_id`: no `/`, `.`, or
whitespace). Falls back to the old date+label scheme otherwise, guarded
by `_resolve_fallback_conversation_id`: if the target already holds a
DIFFERENT raw transcript, suffix instead of overwriting; a resend of
identical content reuses the same id.

Guarded by
`vendor/cm041/assistant_api/tests/test_conversation_process_meeting_id.py`,
7 tests (ported from CM041 PR #196, adapted for this tree's own
divergence: `_invoke_pwg_convo` is stubbed so the pre-flight probe and the
background processor's own call both succeed without a real `pwg-convo`
binary on PATH, and `_subscription_paused` is stubbed directly because
`assistant_api/subscription_gate.py` sits on `sys.path` in this test
environment -- same mechanism the gate's own docstring describes for
production -- and reports the default unlicensed state as paused rather
than failing open). RED confirmed against the unmodified vendored
`ical-server.py` via `git checkout origin/main --
vendor/cm041/assistant_api/ical-server.py` (4 of 7 fail, including the
exact overwrite scenario), GREEN after.

Wired into CI by `.github/workflows/walk-meeting-id-collision-guard.yml`
in the same diff (new-tests-must-be-wired gate).

Retire by landing CM041 PR #196 and re-pinning.

## Eleventh graft: the conversation-status endpoint reads the path CM048 actually writes (H2b, v1.0.107)

Tree `cm041/assistant_api`, file `vendor/cm041/assistant_api/ical-server.py`,
module-level `PROCESSING_DIR`. Matches CM041 PR #197.

`GET /api/v1/conversation/status/{id}` (`api_conversation_status`) read
`PROCESSING_DIR` derived from `PWG_HOME`, which defaults to `~/.pwg`.
CM048's real processor (`andygmassey/CM048-PWG-Conversation-Processing`,
installed on this Hub at `${OSTLER_DIR}/services/cm048`, invoked here via
`pwg-convo`) writes each conversation's `state.json` under the two-zone
engine room, `~/.ostler/processing`, by default -- confirmed at
`src/ostler_paths.py:42-44` (`processing_dir()`), `src/settings.py:93-94`
(`Settings.processing_state_dir` default) and the shipped production
config `settings.yaml.production:143`
(`processing_state_dir: ~/.ostler/processing`); the real write is
`src/processor.py:88` (and 480, 590). CM048's own two-zone migration
(`ostler_paths.py:124-128`, `_ENGINE_ROOM_MAPPING`) moves `.pwg/processing`
to `.ostler/processing` and removes the legacy root on first launch, so
past first launch `~/.pwg/processing` does not exist at all, and this
endpoint was reading a directory CM048 could never write to -- a phone
polling status never saw "completed".

`PROCESSING_DIR` now resolves independently of `PWG_HOME`, honouring the
same override chain CM048's own `settings.py:270-276` uses
(`OSTLER_PROCESSING_DIR` > `OSTLER_STATE_DIR` > `PWG_PROCESSING_DIR`),
defaulting to `~/.ostler/processing`. `COACH_DB` and `CONVERSATIONS_DIR`
still derive from `PWG_HOME` and share the same stale-default shape; that
is a separate, pre-existing divergence, flagged not fixed here, to keep
this graft to the one reported defect.

The brief that opened this ticket named `andygmassey/CM052` ("PWG AI
Conversation Ingest") as the writer. That repo contains no code that
writes a processing marker anywhere; the real writer is the separate,
still-independently-existing `andygmassey/CM048-PWG-Conversation-Processing`
repo, confirmed by reading it rather than assumed from the brief.

Guarded by
`vendor/cm041/assistant_api/tests/test_conversation_status_processing_path.py`
(ported from CM041 PR #197), 3 tests. RED confirmed against the unmodified
vendored `ical-server.py` via `git checkout origin/main --
vendor/cm041/assistant_api/ical-server.py` (no stash): 2 of 3 fail (default
resolves to `.pwg/processing`, env-override chain unhonoured). GREEN
after. Full vendor `assistant_api` suite: 130 passed, 5 failed, both before
and after this graft, same 5 test names each time (the pre-existing,
unrelated `test_ical_server_wire_shape.py` gap already named in the Tenth
graft's own sibling PR #2658 -- iOS-ingest subscription-gate shape plus an
organisation-key test with a real, unmocked network dependency) -- confirmed
unchanged by running the full suite against the pre-fix file via the same
`git checkout origin/main --` swap, not `git stash`.

Retire by landing CM041 PR #197 and re-pinning.

## Eleventh graft: browsing page summaries, Save to Knowledge, browsing search (CM051 Lane 6)

Tree `cm041/assistant_api`. Files: `ical-server.py` (`api_safari_ingest`
extended; new `api_safari_save`, `api_browsing_search`, `_enrich_*` wiring,
routes `POST /api/safari/save` and `GET /api/v1/browsing/search`, worker
resume on startup), new sibling module `browsing_enrich.py` (copied
byte-identical from CM041), `TOOLS.md` is NOT changed here (it differs from
upstream already and the BROWSING routing line is owed in the same re-pin).
Matches CM041 branch `claude/lane6-page-summaries` (open at time of writing,
not yet on CM041 main, so no sha exists to ack; the manifest ack is OWED
after that merge, same shape as #2642 and #2658).

What the measurement found first. The shipped `api_safari_ingest` stored
only url, title, domain, timestamp (plus `html_len`); it never summarised
anything, although the extension README claimed it did. There was no browsing
read endpoint at all: nothing in this tree reads `safari_history` except the
wiki, so "the assistant's existing history search" does not exist and
`/api/v1/browsing/search` is new.

Behaviour added. Optional `text` (clamped to 20480 chars) and `dwell_ms` on
ingest. Text goes to a spool-backed, bounded, rate limited worker that yields
to the chat lease (`~/.ostler/run/ollama-user-active`, same contract as
CM024 and CM048), calls the loopback Ollama, writes summary, tags and
entities onto the stored visit, and DELETES the raw text. Skip-listed pages
(explicit default list plus the customer's own
`~/.ostler/config/browsing_text_skiplist.txt`) keep the visit and capture no
text. History.db and Chrome history rows have no field and read as
`unsummarised`. Save to Knowledge writes a `web_clip` item to the
`evernote_knowledge` collection at `compartment_level` 2 in the importers'
shape, linked to the visit.

THE ONE CM051-ONLY LINE. `api_safari_save` calls
`_subscription_paused("safari_capture")` first (Rule 0.8, browser capture
pauses without Ostler Pro). CM041 source has no subscription gate, so this
is a divergence by construction, pinned by
`TestD_VendoredSubscriptionGate` in the vendored test. The startup hunk
also differs in context only (`ThreadingHTTPServer` here).

Doctor: `vendor/doctor/agent/proxy.py` widens the extension credential from
one path to exactly two POST paths (`/api/safari/ingest`,
`/api/safari/save`), pinned by
`tests/test_extension_credential_covers_the_save_route.py`, which also pins
that every other path, GET, a remote caller and a wrong token stay refused.
`install.sh` DOCTOR_PROXY_PATHS gains `/api/safari/save` and
`/api/v1/browsing/search`. The proxy.py change has no upstream (HR015) twin
yet: OWED, and it is a security-boundary change that wants a human read.

Guarded by `vendor/cm041/assistant_api/tests/test_browsing_enrich.py`
(20 tests). Retire by landing the CM041 branch and re-pinning.

## Twelfth graft: the hydration conversations counter follows CM048 completions (v1.0.107 #11)

Tree `cm041/assistant_api`, file `vendor/cm041/assistant_api/ical-server.py`,
functions `_wiki_conversations_progress`, `_conversation_state_is_complete`,
`_conversation_state_is_stalled`. Matches CM041 PR #201.

`GET /api/v1/hydration/status` counted a conversation completed only when
`state.json` had `current_step == "completed"`. CM048 never writes that for a
real run: it leaves `current_step` on the last step entered (or back on
`00_raw` after a re-entry) and records finished work in `completed_steps`, with
`09_bundle` as the terminal step (CM048 `src/seed.py` `already_enriched`).
Measured read-only on a walk box: 84 of 90 "running" had `09_bundle` done, so
the counter sat flat while pwg-convo logged completions. Completed is now
`09_bundle` in `completed_steps`; `stalled` (subset of running, no update for
30 minutes) is added and never promoted to a failure.

Test `vendor/cm041/assistant_api/tests/test_hydration_conversations_counter.py`
(5 tests), wired in `.github/workflows/walk-meeting-id-collision-guard.yml`.

Upstream landed as CM041 #201, squash sha `1e18c6b0`, acked in `hold_ack_shas`
in `vendor/VENDOR_MANIFEST.toml`. Retire by re-pinning.

## Thirteenth graft: the coach reader read a path the writer never wrote (CM051 v1.0.107 #11)

Mirrors CM041 PR #202. `vendor/cm041/assistant_api/ical-server.py`:
`COACH_DB`, `coach_recent`, and the `/api/v1/coach/recent` handler.

CM048 writes coach observations to `~/.ostler/coach/observations.db`
(`vendor/cm048_pipeline/src/ostler_paths.py:52`, `ingest.py` `_write_coach`),
SQLCipher-encrypted. The reader defaulted to `PWG_HOME/coach/...`
(`~/.pwg`), opened an empty file and returned an empty list, silently.

Now: `COACH_DB` is `~/.ostler/coach/observations.db` (`OSTLER_COACH_DB`
overrides, `PWG_HOME` no longer does). An ABSENT db is a fresh box (the writer creates it on the first
observation; the context-refresh generator polls and counts non-200 as failure):
200 with `observations: []` and `db_state: "absent"`. An existing db with no
key, a wrong key or a missing table raises `CoachDbError`, logs to stderr and
answers HTTP 500 with an `error` and no `observations` key. The key is the one
already resolved at import by `resolve_db_key()` (CM051 #1956 precedent, which
CM041 source does not carry; that is why this file differs from upstream there).

The walk probe `db_key_reaches_every_service` had the same hard-coded
`~/.pwg` path (and created the 0-byte decoy by connecting to it); it now
resolves the writer's path and never creates the file.

Guarded by `vendor/cm041/assistant_api/tests/test_coach_reader_matches_writer.py`
(7 tests; one loads the vendored CM048 `coach_db_path()` itself). Retire by
landing CM041 #202 and re-pinning. ACKED: CM041 #202 merged as 9f2b883c859d53d65e65fcac1e461c1afe8edea1 and that sha is in the VENDOR_MANIFEST hold_ack for this tree. The pin is still held.

## Fourteenth graft: failed conversations retry automatically on a backoff and are never lost (CM051 v1.0.107 #11)

Tree `cm041/assistant_api`, same file. Matches CM041 #203, squash sha
`e1de0cfdb696d21475ff0e89f161ddcf7d08d442`, acked in `hold_ack_shas`.

2 of 129 conversations failed at the processor step on the walk box
(macmini16-walk). The one in-process retry above was spent
(`retry_count=1`) and the only thing that resumes a failed conversation is
the manual `pwg-convo retry-all`, which nothing schedules and a customer
cannot run. They sat failed forever and the hydration panel showed
`needs_attention` with no way out.

Added to this tree's `ical-server.py`: `CONVERSATION_RETRY_*` constants,
`_conversation_process_tracked`, `_preserve_cm048_progress`,
`_retry_one_conversation`, `_conversation_retry_sweep`,
`_conversation_retry_rearm`, `_start_conversation_retry_thread`,
`api_conversation_retry_failed` (`POST /api/v1/conversation/retry-failed`),
the sidecar helpers, and edits to `_conversation_process_background` (one
call before its final state write), `api_conversation_process` (thread
target), `_wiki_conversations_progress` (`retrying`, `gave_up`),
`api_hydration_status` (retrying is `running`, spent cap is
`needs_attention` with a `message`), the POST router, and `__main__` (thread
start). Bookkeeping is a sidecar `auto_retry.json`, NOT a new state.json key,
because `PipelineState.from_dict` was `cls(**data)` and rejects an unknown
key. The retry re-runs `_invoke_pwg_convo(["process", ...])`, this tree's own
CM048 invocation (CM041 source uses `OSTLER_VENV_PYTHON -m src.cli`), the
one adaptation against the source graft.

The `09_bundle` completion predicate and `stalled` (CM041 #201, the Twelfth graft above) are now in this tree, so `retrying` / `gave_up` sit beside `stalled`.

### What a future sync must preserve

All of the above. Guarded by
`vendor/cm041/assistant_api/tests/test_failed_conversation_auto_retry.py`
(12 tests, 12 fail against main's ical-server) and by
`tests/test_vendored_conversation_process_failure_reason.py`, whose fixture
now loads the real `_preserve_cm048_progress` helpers. Wired into
`.github/workflows/failed-conversations-auto-retry-guard.yml`.

## Fifteenth graft: a 14+ digit internal id is never shown as a phone (CM051 v1.0.107 #12)

Tree `cm041/assistant_api`, same file. Matches CM041 #204, squash sha
`c05b35edd6441976fe2b068c90bd4d13e88fa004`, acked in `hold_ack_shas`. The
four ical-server.py hunks applied unchanged (offsets only), so the changed
lines are identical to upstream.

Walk #11 measured 1 of 2,571 Hub People rows showing a 17-digit internal id
(a WhatsApp linked-device id or another app's id written before the writer
fixes) as its phone. `people_list` and `person_enrichment` took `phones[0]`
with no check. Added `_displayable_phone`: under 14 digits shown as stored,
over 15 never, 14 or 15 only when `identity_resolver.normalise.is_valid_phone`
says valid (hidden if that check cannot run). Read-side only; the graph is
untouched. Edits: `person_enrichment` (identifier loop and Qdrant payload
phones) and `people_list` (payload phones and identifier phones).

### What a future sync must preserve

`_displayable_phone` and its four call sites. Guarded by
`vendor/cm041/assistant_api/tests/test_people_list_endpoint.py` class
`TestPeopleListNeverShowsAnInternalIdAsAPhone` (6 tests: 5 fail against main's
ical-server, the ordinary-number control passes on both), wired in
`.github/workflows/walk6-people-list-correctness-guard.yml`. Retire by
re-pinning.

## Sixteenth graft: an encrypted connection gets its own Row class (CM051 v1.0.107 walk #12)

Tree `cm041/assistant_api`, same file. Matches CM041 #205 (open at graft
time; ack its squash sha in `hold_ack_shas` when it merges). The helper and
both call-site lines are identical to upstream.

Walk #12 FAIL `db_key_reaches_every_service`: the box's ical-server.err read
`Row() argument 1 must be sqlite3.Cursor, not sqlcipher3.dbapi2.Cursor` and
every coach read returned 500. Added `_row_factory_for(conn)`, which returns
the Row class of the module that made the connection. Edits:
`conn.row_factory` in `coach_recent` and in `_memory_corrections_connect`.

### What a future sync must preserve

`_row_factory_for` and its two call sites. Guarded by
`vendor/cm041/assistant_api/tests/test_row_factory_on_sqlcipher_connection.py`
(unfixed: 3 failed, control passed; fixed: 4 passed), run on a real sqlcipher3
connection by `.github/workflows/db-key-delivery-and-recovery.yml`. Retire by
re-pinning.

## Seventeenth graft: People list hides business-shaped names (CM051 cut #15, walk #14)

Tree `cm041/assistant_api`, same file. Matches CM041 #206, pre-merge head
`f9458b91e18f38040ccb10305ee75732dd68fb4a` (acked in `hold_ack_shas`; swap for
the squash sha on merge). The ical-server.py hunks applied unchanged.

Walk #14 measured 33 of 7,815 Hub People rows that were businesses or
automated senders ("<brand> official", "<x> swimming gear store",
"<x> hk official"). Added `_is_business_shaped_name` and one call from
`_is_automated_or_service_name`: corporate last word (official, ltd, limited,
inc, ...) after at least one word; retail last word (store, shop, ...) only
with three or more words; support/customer-service team endings; noreply.
Uncarded records only (existing Contacts-card gate). "HK" alone is never a
signal. Round 2 (walk probe hub_screens.py _org_like requires zero): a STRONG tier of institutional words (official, ltd, solutions, group, university...) hides a row even when it HAS a Contacts card; a WEAK tier (club, news, bank, team, store...) stays uncarded-only and needs 3+ words. Read-side only.

### What a future sync must preserve

`_BUSINESS_*` constants, `_is_business_shaped_name`, and its call in
`_is_automated_or_service_name`. Guarded by
`vendor/cm041/assistant_api/tests/test_people_list_endpoint.py` class
`BusinessShapedNameFilterTests`. Retire by re-pinning past the CM041 merge.

## cm041/assistant_api: memory/assert answers inside a budget (CM051 walk #15, CM041 #208)

Tree `cm041/assistant_api`, file `ical-server.py`. Graft of CM041 #208 ahead of
a re-pin; the identical edit (one script applied to both copies) is on the
CM041 branch `fix/memory-assert-search-budget`.

Location and shape. `_embed_text` gains a `timeout` parameter (default 30, as
before). `people_search` gains `timeout` as ONE budget for embed + Qdrant
together and raises TimeoutError when it is spent. Beside
`_ASSERT_DISAMBIGUATION_MARGIN`: `_ASSERT_SEARCH_BUDGET_S` (env
`OSTLER_ASSERT_SEARCH_BUDGET_S`, default 8) and `_is_timeout`. In
`api_memory_assert`, step 2 calls people_search with that budget, logs the
duration (no PII), and on timeout continues with no search hits. After the
exact-displayName Oxigraph lookup, if no person resolved and the search had
timed out, the handler returns 503 `identity_resolution_timeout` with
`retry_after_seconds` and writes nothing.

### What a future sync must preserve

All of the above until the pin passes the CM041 #208 merge. Guarded by
`tests/test_memory_assert_answers_inside_the_probe_timeout.py` (workflow
`memory-assert-answers-under-load.yml`): 3 of 4 fail on the pre-graft server,
4 of 4 pass with it. Retire by re-pinning past the CM041 merge.

## cm041/assistant_api: memory/assert spools on budget exhaustion (CM051 walk #15 follow-up, CM041 spool PR)

Tree `cm041/assistant_api`, file `ical-server.py`. Graft of the CM041 branch
`fix/memory-assert-spool` (one script applied to both copies), stacked on the
#208 budget graft above.

Location and shape. `api_memory_assert` keeps validation and hands steps 2-5
to a new `_assert_resolve_and_write(..., budget, spool_on_timeout, fact_id,
person_id, privacy_level)`. On budget exhaustion with no exact-name match the
request path calls `_spool_assertion` and answers 202 `accepted_pending`
(spool_id, fact_id, status_url) instead of 503. New beside the budget
constants: `_ASSERT_PRIVACY_LEVEL`, `ASSERT_SPOOL_DB` (SQLCipher via
`_secure_connect` and the installed key, as `_memory_corrections_connect`),
`_assert_spool_connect`, `_spool_assertion`, `_assert_fact_person`,
`_assert_spool_sweep` (single-flight; ASK the fact URI first so a re-run is a
no-op; writes the spooled ids, timestamp and level), `_assert_spool_loop`,
`_start_assert_spool_thread` (started in main beside the Lane 6 worker), and
`api_memory_assert_pending` behind GET `/api/v1/memory/assert/pending/<id>`.
The PersonFact level is written from the parameter (default "L1", unchanged).

### What a future sync must preserve

All of the above until the pin passes the CM041 spool merge. Guarded by
`tests/test_memory_assert_answers_inside_the_probe_timeout.py`: 3 of 6 fail on
the budget-only server, 6 of 6 pass with it; mutants (resolver drops the
spooled fact_id; level hardcoded) each go red.
