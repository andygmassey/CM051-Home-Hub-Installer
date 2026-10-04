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

Matches CM041 PR #193 (upstream, open at time of writing -- supersedes the
now-closed #192, see the correction above). Recorded here, not as a patch,
for the same reason as the grafts above. Retire by landing CM041 PR #193 and
re-pinning.
