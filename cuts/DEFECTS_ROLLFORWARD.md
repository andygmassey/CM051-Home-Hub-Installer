# Cross-Cut Defects Rollforward

**Purpose**: single register of every defect observed in ANY cut, and the mechanical gate that proves it's fixed in the next one. This is the file the pre-cut gate reads. Cuts that don't pass every applicable gate here don't ship.

**Not this file's job**: describing defects in detail (see per-cut `cuts/<version>/DEFECTS_LEDGER.md`). This file is the index + gate registry.

**Discipline**: after ANY cut ships, walk this file and mark every defect either `fixed_in_<cut>` (with gate transcribed) or `still_open` (rolls forward to MUST-FIX-NEXT). No cut ships without this file audited.

**CITATION CONVENTION, and it is not cosmetic.** A reference of the form
`task #N` in this file is a **local agent task-list id**. It is NOT a GitHub
issue or PR and MUST NOT be resolved as one. GitHub references are written
`owner/repo#n`, or `<REPO> #n` using a repo shorthand (`OS003`, `CM051`, `CM044`,
`CM041`, `HR015`, `oa`).

The two id spaces overlap, and the collision confirms rather than fails. Measured
2026-08-10:

```
task #191   local: "a cut-time freshness gate ALREADY exists; #191 was a duplicate"
HR015 #191  real, CLOSED, MERGED: "fix(fda): stamp FDA people-index with real
            pwg:createdAt so they show in time views"                 -- unrelated
```

Row `v1018-D025` says *"task #191 landed as part of the mechanical release
pipeline"*. Anyone resolving that against HR015 gets a **merged** PR and concludes
it landed. **13 distinct `task #N` ids are cited in this file** and HR015's PR
numbering covers all of them, so every one of those citations resolves to
something real and wrong if read as a GitHub reference. Same family as the
`HR015 #314` / `task #314` collision: it is not that the lookup fails, it is that
it succeeds against the wrong artefact and is often in a matching state.

---

## MUST-FIX-NEXT (blockers for the next cut — v1.0.19 or v1.0.1)

Every entry here has a gate. The cut pipeline (`pipeline/release.yml`) MUST run each gate as a pre-ship check. FAIL any = NO SHIP.

**v1.0.19 planning (Archie 2026-08-09):** every MUST-FIX-NEXT entry below now carries its corresponding PR from the consolidated `v1.0.18/V1019_PLAN.md`. Target state = the state the entry moves to when the PR lands + the cut pipeline enforces its gate. Any entry marked `deferred` requires an explicit Andy sign-off in `V1019_PLAN.md § deferred` before v1.0.19 can be tagged.

### From v1.0.18

| ID | Summary | Ledger entry | Gate | V1019 PR | Target state |
|---|---|---|---|---|---|
| v1018-D001 **RESCOPED** | Funnel warning is a FALSE POSITIVE on the happy path (`funnel status` and `serve status` are the same upstream fn; a tailnet-private serve prints `https://... (tailnet only)` and the grep matched it). NOT a missing prompt. | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d001--corrected--the-funnel-warning-is-a-false-positive-on-the-happy-path-not-a-missing-prompt) | `tests/test_wiki_tailnet_gate.sh` passes (extracts the shipped detection block, runs it against on/off fixtures) AND shipped install.sh greps `funnel status --json` and never pipes `funnel status` into `grep` | PR #545 (`archie/d001-funnel-false-positive`, CM051) — **plan PR #16 CANCELLED** | fixed_in_v1.0.19 |
| v1018-D002 | Wiki tab conceded to the error state on the FIRST failed probe. The retry loop was gated on `prev === 'probing'` inside a `setProbeState` updater, and the first failure had already set `'error'`, so the loop went silent. The "Building your wiki..." copy existed in all 31 locales and was unreachable. | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d002--wiki-tab-shows-wiki-not-available-error-on-first-run-instead-of-initializing-state) | `web/src/pages/Wiki.test.tsx` passes (drives the real component against a controllable fetch; asserts probe COUNT across the warm-up window, not merely the absence of an error) | PR #291 (`archie/d002-wiki-warmup`, ostler-assistant) — **plan PR #22 CANCELLED** | fixed_in_v1.0.19 **CITATION IS CORRECT, BUT THE FIX IS NOT ON THE BOX (2026-08-10, Archie).** oa #291 is the right PR and merged 2026-08-09T12:34Z. The Mini's daemon reports build commit `782a6195`, authored **2026-08-06T17:02Z**; `git compare` puts #291's merge `2c974f27` **ahead_by=4, behind_by=0** of it (control: self-compare identical). So the running daemon predates the fix. **This is the THIRD delivery path found stale today** -- after the digest-pinned wiki image (D010/D014a/D016) and alongside vendored code, which DID travel (D014b/c). **Bounded generalisation:** 5 oa PRs merged after the box's build and are absent from it -- #291 (this fix), #289, #285 (a Snyk `react-router-dom` security upgrade), #189, #175 -- against a control of 92 merged before it. Note this is ANDY'S box, not the customer path; it matters because the box is what launch readiness is judged on. **RE-CONFIRMED 2026-08-10 21:5x HKT (Archie), by an independent measurement that needs no build sentinel.** The running daemon is `~/.ostler/OstlerAssistant.app/Contents/MacOS/ostler-assistant`, binary mtime **Aug 8 19:29 HKT (Aug 8 11:29 UTC)**. oa `#291` merged **Aug 9 12:34 UTC**. The binary is **25 hours older than the fix**, so it cannot contain it. mtime is sound in this direction specifically: copying a file would make it look NEWER, never older, so an old mtime cannot be manufactured. **Two days on, the daemon still has not been rebuilt.** Note the contrast with D014a, whose wiki image DID deliver today at 19:06 -- the wiki lane moved and the daemon lane did not. Source side is GREEN: the D002 gate (runs-on=repo) passes on oa main `cd01cca8`, and its test is not vacuous, running 6 real assertions. Gate measures SOURCE; delivery is the gap. |
| v1018-D003 | OS003 gate stale vs current daemon (all 3 v1.0.18 fails were gate-staleness) | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d003--os003-behavioural-gate-is-stale-vs-current-daemon-contracts) | gate runs GREEN against known-good post-install box (meta-gate) | **OS003 #5** (merged) `fix(gate): rewrite behavioural acceptance gate against current daemon contracts -- v1018-D003`. Repointed 2026-08-10: the row cited OS003 #1, which is closed and NOT merged. MUST land BEFORE tag-push. | fixed_in_v1.0.19 |
| **v1018-D004 🔴🔴🔴** | Base32 ghost person: write-side data corruption ships to customer wiki (customer-visible on first wiki visit) | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d004--base32-ghost-person-write-side-data-corruption-ships-to-customer-wiki) | grep wiki People pages for blob-like display_name (0 hits = PASS) | **CM044 #172** (merged) `fix(wiki): catch opaque calendar handles per-token, not whole-string [v1018-D004]`. Repointed 2026-08-10: the row cited CM041 #5, CM044 #5 and CM051 #19, all merged but none naming this defect. | fixed_in_v1.0.19 (write-side reject + read-side regex + one-time backfill LaunchAgent) |
| **v1018-D005 🔴🔴🔴** | Dedupe fragmentation 16% of wiki People (915/5713) — flagship "Recently active" fragments customer's world | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d005--dedupe-fragmentation-systemic-16-of-wiki-people-are-duplicates) | **T+0 ONLY** -- hex6-suffixed ratio in `~/Documents/Ostler/Wiki/People/` measured on the FIRST compile after a fresh install, not whenever someone looks. See the time-varying note in the D005 entry: the ratio converges, so a late measurement passes while the customer's first impression fails | **CITATION WITHDRAWN 2026-08-11.** `CM041-People-Graph#4` is an OPEN ISSUE titled "iCloud photo source for People Graph" -- **not a pull request**. GitHub shares one number sequence between issues and PRs, so it resolves, sits in the right repo, and reads exactly like a fix citation until you check the type. `CM051#17` is genuinely merged but is "CM046 LaunchAgent piece 3", a different defect. Controls run before believing the 404: `CM041-People-Graph#116` resolves, and #1 #2 #3 #5 #6 all exist, so neither the token nor the repo is the explanation. **No PR fixes this row.** | open -- status corrected from `fixed_in_v1.0.19` 2026-08-11. The old status contradicted itself: it conceded "resolver-rework real fix deferred to v1.0.1" while claiming fixed, and this file's own D034 note already states "D005 is genuinely OPEN". The table row was the only place still asserting otherwise. The real fix rides on CM041 `fix/one-person-one-name`, which is ABSENT from that remote across 57 enumerated branches (branch count kept as the control). A row cannot be fixed on a branch that does not exist. The v1.0.19 budget and chunking work is real and stays described in the ledger entry, but it is mitigation, not the fix this row's acceptance measures. |
| v1018-D006 | Nia/Niaj Wexcombe same-person split (subclass of D005, named because Andy flagged) | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md) | not both of the two slugs exist | **CITATION WITHDRAWN 2026-08-11, inherited from D005.** This row rode on the same two citations and neither is a fix: `CM041-People-Graph#4` is an OPEN ISSUE about iCloud photo sourcing, not a pull request, and `CM051#17` is merged but is "CM046 LaunchAgent piece 3". Nothing to repoint to. | open -- status corrected from `fixed_in_v1.0.19` 2026-08-11. The old status was "as a consequence of D005 fix", and D005 is now correctly recorded as open with no fix located, so the consequence cannot hold. A row whose entire claim is derived from another row's fix must move when that row moves. Acceptance is unchanged and is a good one -- both hex-suffixed page variants must not coexist -- so this row needs no rework, only an honest status. |
| v1018-D007 | Hydration surface claim un-backed by verifiable endpoint (task #208 trust class) | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d007--hydration-surface-claim-un-backed-by-verifiable-endpoint-task-208-class) | `/api/v1/hydration/status` returns `overall_state` plus a non-empty `phases` list, and every phase carries enough numeric substance for the state it claims (state=done needs `count`; state=running needs `done` + `total`; state=pending needs neither) | **CITATION DOES NOT RESOLVE (2026-08-10).** ostler-assistant #13 is "ci: fix Quality Gate trigger (master -> main)", merged 2026-05-03 from `agent/ci-trigger-main-2026-05-03` -- a CI trigger fix against a hydration-endpoint defect. The cited branch `tnm/d007-hydration-endpoint` does not exist in ostler-assistant or HR015. Controls: oa #292 and oa `main` both resolve with the same token, so this is not an auth artefact. | open -- status corrected from `fixed_in_v1.0.19` 2026-08-10, and the ACCEPTANCE corrected with it. **The old acceptance could not fire:** it named `/doctor/api/hydration`, which returns **404** on the shipped v1.0.18 box. Positive controls that prove the probe was sound: `/doctor/api/health` 200, `/api/v1/box-status` 200, `/api/v1/wiki/duplicates/decision` 405. A hydration endpoint **does** exist at `/api/v1/hydration/status` (200, unauthenticated) but its shape is nothing like the one this row asserted: it returns `{generated_at, overall_state, phases}` and **none** of `percent`, `eta_seconds`, `sources` appear at top level. `eta_seconds` does exist, but per-phase on a running phase, and a percentage is derivable from that phase's `done`/`total` rather than served. So the row was written against a flat API shape that was never built. The trust question it exists to ask (task #208 class) is now gated against the real contract below. |
| **v1018-D008 🔴🔴🔴** | Chat hangs while wiki-compile holds Ollama-slot lock (task #181 recurrence) — 16 GB first-hour fatal | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d008--chat-hangs-indefinitely-while-wiki-compile-holds-ollama-slot-lock-task-181-recurrence) | chat responds within 60s while wiki-compile in flight (real-box behavioural gate) | **CITATION WITHDRAWN 2026-08-11.** The row named the right BRANCH and the wrong NUMBER, which is why it read as sound: the parenthetical says `archie/d008-mount-ollama-user-active-lease`, unmistakably a D008 fix branch, while `CM051#18` is "Wiki container piece 1: bundle wiki-site + wiki-compiler in compose", merged 2026-05-01, +51 -2, touching install.sh only. Only the integer is machine-checked; a human reads the branch name, recognises it, and stops. Chased for the real number and there is none: server-side head filter on that branch returns NO PR (control: the same query returns #557 for its own branch), the branch itself 404s in CM051, and no merged PR anywhere in the org names this mechanism. **Nothing to repoint to.** | open -- status corrected from `fixed_in_v1.0.19` 2026-08-11. I expected this one to be a repoint and it is not; the evidence went the other way and the claim has to move instead. The described fix (bind-mount plus env in the wiki-compiler compose heredoc) has no PR and no surviving branch, so there is nothing to verify it against. This row is a 🔴🔴🔴 and its acceptance is a real-box behavioural probe (chat responds within 60s while wiki-compile is in flight) -- that acceptance is good and unchanged, and it has never been run against a located fix. Related and NOT closed by this edit: the shared Ollama slot lock still has no timeout and no heartbeat, which is the mechanism behind this defect and stalled three separate scripts on 2026-08-10. |
| **v1018-D009 ~~🔴🔴🔴~~ NOT-A-DEFECT** | Combine/Different-people dedupe buttons return 404 (route not wired) — human escape hatch for D005/D006 is dead | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d009--combine--different-people-dedupe-review-buttons-return-404-route-not-wired--the-human-escape-hatch-for-d005d006-is-dead) | POST /doctor/api/duplicate-decision returns 200/201/202 | PR #14 (`archie/d009-dup-decision-contract-test`, HR015) + ledger correction | **RESOLVED 2026-08-09 -- NOT A DEFECT. Verified end-to-end on the shipped v1.0.18 box (192.168.1.210), not inferred.** `/People/duplicates/` -> HTTP 200 carrying **146** `dup-decide` buttons with `dup_decision.js` linked; the served JS uses the literal `http://127.0.0.1:8089/api/v1/wiki/duplicates/decision`; a valid POST returns **200 `{"status":"recorded"}`** and writes `~/.ostler/corrections/duplicates.yaml`. Probe entry removed and the file restored to its pre-probe absent state. Both earlier root causes were WRONG: 'route not wired' (retracted 2026-08-09 overnight) and 'JS posts a relative path -> :8044 -> 501' (retracted now -- `git log -S` proves a relative-path version **never existed** in this file's history). No fix required; no PR. |
| v1018-D010 | Wiki CSS regression: pink bar behind h2 subheadings | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d010--wiki-css-regression-pink-bar-background-behind-h2-subheadings) | no CSS rule sets background on .pw-h2 or h2 | **CM044 #171** (merged) `fix(wiki): namespace heatmap buckets pw-hN to pw-heat-N [v1018-D010]`. Repointed 2026-08-10: the row cited CM044 #6, which is merged but is an incremental-fingerprint change, and was shared as a single wrong pointer by D010/D015/D016. | fixed_in_v1.0.19 (compound `.pw-hc.pw-h2` selector scope + regression test) |
| **v1018-D011 🔴🔴🔴** | "Mum Fairweather" is Robin — display_name derived wrongly + SOURCE of "Mum" is UNKNOWN (Andy did NOT save her as Mum in Contacts) | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md--mystery-about-source-of-mum) | no wiki People page has a display_name that is not a name -- kinship word, bare phone number, email address, placeholder, or empty. **This cell used to read `display_name != given_name + " " + family_name`, which is the predicate the gate block below documents as wrong in both directions and which was replaced there; the cell was left behind, so the table advertised the broken contract while the gate ran the corrected one.** Requires an examined-count control: the People directory must exist and at least one page must be read, or CANNOT RUN. | **CITATION DOES NOT RESOLVE (2026-08-10).** CM041 PR #4 returns 404 and the cited branch 404s (control: `main` resolves). Third row of this cut with an unresolvable citation, after D017 and D018. | open — status corrected from `fixed_in_v1.0.19` 2026-08-10 after the citation failed to resolve. NOTE: the kinship half of this defect IS now fixed and live on the FDA path (CM051 #550 + #552, merged, `_upsert_display_name` has 5 production callers on CM051 main). The canonical-name half is unverified. |
| **v1018-D012** | RETRACTED — Archie probe error (wrong ontology). Oxigraph HAS 6,325 people. See D012b for the legitimate underlying question. | [v1.0.18 retraction](v1.0.18/DEFECTS_LEDGER.md#v1018-d012--retracted-archie-probe-error-not-a-product-defect) | (n/a — retracted) | (n/a) | RETRACTED — not counted against v1.0.19 |
| v1018-D012b | Verify chat's graph-grounding tool queries correct ontology + named graph (pwg.dev/#Person in urn:pwg:user/Andy, not schema:Person default) | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d012b--verify-chats-graph-grounding-tool-queries-the-correct-ontology--named-graph) | chat returns >0 results for known person when Oxigraph populated | **CITATION WITHDRAWN 2026-08-11.** It was never a fix citation: it read "Verified as part of PR #10 D018 bisect scope ... no separate PR unless bisect finds a distinct defect". That cites a SCOPE, not a change -- and it says outright that no PR exists. **The bisect it rides on was cancelled:** D018 turned out not to be a regression at all, because cross-channel recall was never implemented, so there was nothing to bisect between. A verification that was scoped and then cancelled cannot support a fixed claim. | open -- status corrected from a CONDITIONAL 2026-08-11. The old value was "fixed_in_v1.0.19 (verified as a smoke check) OR filed as v1019-D001 if the bisect surfaces a real gap". That is not a state, it is a branch: the row asserted fixed and not-fixed at once and left the resolution to an event that never happened. **A register row must hold a state, not a plan** -- a conditional cannot be gated, and read by a machine the leading token wins, so this counted as fixed. The verification itself was never performed. |
| v1018-D013 | Wiki quality low: 9,759 orphans / 5,933 thin / 50 topic gaps / 200 missing cross-links | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d013--wiki-quality-low-9759-orphan-pages--5933-thin-pages--50-topic-gaps--200-missing-cross-links) | orphan pages < 2000 | **CITATION WITHDRAWN 2026-08-11, inherited from D005.** It read "Rides on PR #4 + PR #17 (D005 dedupe fix reduces orphan count materially)" -- the same two non-fixes already withdrawn on D005 and D006. `CM041-People-Graph#4` is an OPEN ISSUE about iCloud photo sourcing, not a pull request; `CM051#17` is merged but is "CM046 LaunchAgent piece 3". Third row riding the same pair, which is why one bad citation is never one bad row. | open -- status corrected from `measured_in_v1.0.19` 2026-08-11. Two separate reasons, either sufficient. First, the citations it rode on are withdrawn and D005 itself is now open, so the premise "the D005 dedupe fix reduces orphan count materially" has no fix behind it. Second, the acceptance is a MEASUREMENT and the measurement is not in evidence here: a box measurement of 11,982 orphans against an acceptance of under 2000 was recorded on the unmerged branch for OS003 #26 and has NOT been reproduced on main, so it is carried here as a claim to re-run, not as a result. Re-measure on the box before this row moves again in either direction. |
| **v1018-D014 🔴🔴🔴** | Wiki content-quality bugs: (a) 249 pages with numeric-only summaries, (b) raw prompt scaffolding written instead of output, (c) unfilled {user_email} placeholders | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d014--wiki-content-quality-bugs-a-llm-returns-just-a-number-b-raw-prompt-scaffolding-rendered-instead-of-output-c-unfilled-template-placeholders) | zero numeric-only summaries + zero {placeholder} + zero raw-prompt patterns | PR #7 (CM044 `fix/wiki-d014-content-quality-cluster` — manual port of PR #154) + PR #8 (CM048 `fix/cm048-d014-prompt-scaffolding-echo`) | **UNEVIDENCED** -- source fixes are in (CM044 #7, CM048 #8, CM051 #546/#547), but no box has demonstrated them. Two of this row's three sub-predicates could not fire (OS003 #20), and the founder box today reports 249 / 6 / 29 against code that predates all of them. Re-run the gate on a rebuilt box before this says fixed. Pre-existing damage is NOT repaired by any of those PRs: the 29 summaries and 6 placeholder files on disk stay broken until re-enrichment. **MEASURED ON THE BOX 2026-08-10 (Archie). D014 SPLITS, and the split confirms the delivery-path theory.** (a) **numeric-only summaries: STILL RED.** 249 People pages carry a `pw-summary` block and **all 249 contain a bare integer** -- exactly the 249 originally reported. Verified by masking content (`<div class="pw-summary"><p>999`, line lengths min 28 / median 30 / max 30); an earlier `grep -A2` returned 0 only because the text sits on the SAME line as the div. (b) **raw scaffolding + literal `{user_email}`: GREEN.** Zero template placeholders of `{[a-z_]{3,30}}` shape and zero `user_email` anywhere, against a positive control of **11,722 pages containing a brace**. **Why the split:** D014b/c were fixed in CM051 (#547, #546) -- vendored code that reaches the box on install -- while D014a was fixed in CM044 #174, which ships INSIDE the digest-pinned wiki-compiler image that has not been rebuilt since 2026-08-08. Same cause as D010 + D016; remedy is the `v0.1.8` tag push. Counts only left the box. **RE-MEASURED ON THE BOX 2026-08-10 21:20 HKT (Archie): THE WHOLE GATE IS GREEN, exit 0, a=0 b=0 c=0.** D014a has flipped: 327 People pages now carry a `pw-summary` and **zero** are numeric-only, against 249-of-249 numeric-only when this row was written. Prose length min 52 / median 167 / max 278 characters versus the RED-era min 28 / median 30 / max 30. **Both controls run before believing the green,** because an absence is the reading most often manufactured by a dead predicate: POSITIVE, the predicate has a real population to search (4,918 People pages, 11,838 wiki pages total); NEGATIVE, a planted `<div class="pw-summary"><p>249` file in a temp tree still matches, so the `[0-9]+$` anchor is intact and the line format has not drifted away from it. **The delivery-path blocker this row names is RESOLVED.** The wiki recompiled inside the Docker wiki-compiler image (`ostler-wiki-compiler-run-c231cb3633a8`) from 18:29 to 19:06 HKT, and all 4,918 People pages carry an 19:06:21 mtime, so the image did deliver rather than the fix being applied by hand. The `v0.1.8` remedy is done. Legacy flat-layout debris remains and is reported, not failed: 61 conversations without a narrative and 11 with an unfilled placeholder, all in the pre-migration layout the current writer cannot emit. NOT changing the status cell to fixed in this PR: the gate is green on ANDY'S box, and CM044 #179 (the D014a prompt fix) is still open, so whether this green survives a fresh install with a different data shape is untested. Evidence recorded; the claim stays where it is until TNM rules on #179. |
| **v1018-D015 🔴🔴🔴** | Wiki theme uses admonition-style AI-tell callout treatment — BANNED per feedback_no_glowing_callout_admonition_style_anywhere (D010 is a sub-symptom) | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d015--wiki-theme-uses-admonition-style-ai-tell-callout-treatment-banned-per-andys-brand-rules) | shipped wiki CSS has zero admonition-style callout rules + Andy signs off multi-page consistency sweep | **CITATION WITHDRAWN 2026-08-11 -- same shape as D008, right branch, wrong number.** The parenthetical names `fix/wiki-d010-d015-d016-theme-cluster`, which contains this defect's own id and is unmistakably the theme-cluster branch. `CM044#6` is "R3-12: incremental fingerprint catches in-place edits via MAX(created_at)", merged 2026-04-24, touching compiler/incremental.py and its test. **It changes zero CSS.** This row is about wiki theme callout treatment; an incremental-compile fingerprint cannot address it. Checked by FILES, not by title, because the title is what makes these plausible. | open -- status corrected from `fixed_in_v1.0.19` 2026-08-11. The described scope (de-admonize `.pw-summary` and `.pw-doc blockquote`) may well have been written, but the cited PR is not where it landed, so there is nothing here to verify it against. Its acceptance is unchanged and is strong: shipped wiki CSS carries zero admonition-style callout rules, plus Andy's multi-page consistency sign-off. That acceptance has never been run against a located fix. Andy's sign-off is a REQUIRED half of this row and cannot be satisfied by any PR. |
| **v1018-D016 🔴🔴🔴** | Wiki body text + everything sitewide MASSIVE — type-scale blown out (same class as task #224) | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d016--wiki-body-text--everything-renders-massive--sitewide-type-scale-blown-out) | body font-size ≤ 18px + no raw px text > 24px + Andy signs off multi-viewport sweep | PR #6 (CM044 `fix/wiki-d010-d015-d016-theme-cluster`) | **DELIVERED + VERIFIED ON THE BOX 2026-08-10.** Gate re-run by Archie, extracted verbatim from this file and executed on the founder Mini against the v0.1.8 image (`ostler-wiki-site` `3f8e01f8952d`, `build-20260810-035744`): exit 0. `extra.css:2245` carries an unscoped `html { font-size: 100% !important; }`. **The previous gate body was a FALSE RED** -- it required selector and declaration on one line, and the shipped CSS is ordinary multi-line, so it could never have passed; it would have blocked a cut on a fixed defect. Corrected gate parses the block and additionally holds the unscoped requirement. Controls: unmodified PASS, block-deleted FAIL, re-scoped-to-`.ostler-embed` FAIL. Andy's 13.1 px vs 14 px body-target preference is a separate open question, not a defect. |
| **v1018-D017 🔴🔴🔴** | **SCOPE NARROWED 2026-08-11 to the channel-scrub WIRING, which is what its gate actually asserts. The customer-visible defect this row was filed for is `v1018-D038` and remains OPEN.** Original report: assistant iMessage rendering leak, raw tool-call syntax reached the customer. Two corrections are kept here so they travel with the claim. **(1) The HTML-entity half is REFUTED** -- `escape_html` exists at exactly two private sites (`telegram.rs:1743`, correct there because that API takes `parse_mode=HTML`, and `report_templates.rs:32`), neither has a cross-channel caller, and `link_enricher.rs:148` only ever UNescapes. No shipped plain-text send path has an escape step that could fail to unescape. What produced `< " >` is unknown and probably unknowable, because the daemon logs no outbound message bodies. **(2) `🤖 ` is the configured message prefix** (`schema.rs:1963`, `imessage.rs:408`), not a renderer, so the leaked text is the model's own reply. | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d017--assistant-imessage-rendering-leak-raw-tool-call-syntax--html-entity-mis-escaping-to-customer) | **The predicate this cell used to name -- "zero raw tool-call or HTML entities in outbound iMessage log" -- is UNMEASURABLE: there is no outbound iMessage log.** The gate below asserts the send path instead: every shipped channel must call the scrub. See its scope note before reading a green as a fixed D017; the real defect is `v1018-D038`. | **`ostler-ai/ostler-assistant#292` MERGED** (`archie/d017-imessage-tool-call-scrub`). This cell read "OPEN, UNSTABLE" until 2026-08-10; it merged, and so did `#296` for the other five send paths. Neither closes `v1018-D038`. | **fixed_in_v1.0.19 -- NARROWED SCOPE ONLY. Read the next sentence before citing this row as closed.** What is closed: every shipped channel's send path now calls `strip_tool_call_tags`. What is NOT closed: a bare `tool_name(args)` reply still reaches the customer on every channel, and that is **`v1018-D038`, OPEN**. **GATE RE-RUN BY ARCHIE 2026-08-11 WITH A DEMONSTRATED RED, which it had never had:** at oa `#292`'s base `52b1ffba` the gate goes RED naming **0 of 6** shipped send paths scrubbing (apple_mail, email_channel, gmail_push, imessage, whatsapp, whatsapp_web); on current oa `main` it is GREEN at **6 of 6**. Same script, two refs, opposite verdicts, so it discriminates. **Two preconditions for anyone re-running it.** (a) Only the `ostler-ai` gh account can read both `ostler-ai/*` and `andygmassey/*`; under the other two every oa read returns empty and the gate exits `FAIL: examined 0 channel send paths`, which is correct fail-closed behaviour, not a flake. (b) To find a pre-fix ref do **not** use `merge_commit_sha`'s parent: oa is rebase-merge, so there is no merge commit and `parents[0]` walks backwards INSIDE the same PR. Doing that returned a RED that was real but mislabelled. Use `.base.sha`, and sanity-check the commit's subject line before quoting it as a before-state. **Prior history of this cell, kept because it is the point:** it read `fixed_in_v1.0.19` citing PR #9 and a branch that 404s; #9 is an unrelated cron-delivery repair merged 2026-05-02. Anyone spot-checking "#9 -- merged? yes" would have confirmed a fix that never landed, which is exactly `v1018-D029`. |
| **v1018-D018 🔴🔴🔴** | Assistant memory doesn't cross channels — macOS Chat memory not reaching iMessage (persistence works within-channel, retrieval fails cross-channel) | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d018--assistant-memory-does-not-cross-channels-macos-chat-memory-not-reaching-imessage) | after chat asserts "X is Y", subsequent iMessage query for "Y" resolves to X (real-box gate) | **CITATION DOES NOT RESOLVE (2026-08-10).** oa #10 is "cron-delivery: piece E", merged 2026-05-02, unrelated; the cited branch 404s (control: `main` resolves). No fix has been located. | open — status corrected from `fixed_in_v1.0.19` 2026-08-10 after the citation failed to resolve. Ungated by design: there is nothing yet to gate. Acceptance stays a real-box two-channel probe. |
| **v1018-D019 🔴🔴🔴** | whatsapp-bundle exits 78 (EX_CONFIG) with 0-byte .err+.log — ships dark, MUST-D class in different job | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d019--whatsapp-bundle-launchd-job-exits-78-ex_config-with-zero-byte-err-and-log--ships-dark) | whatsapp-bundle either exits 0 OR writes non-empty log on failure | **CITATION IS THE WRONG SUBSYSTEM (2026-08-10).** CM051 #20 is "Wiki container piece 3: daily wiki-recompile LaunchAgent". Called by DIFF, not title: it touches 5 files, all under `wiki-recompile/`, with ZERO occurrences of "whatsapp" in the whole patch. D019's acceptance is entirely about whatsapp-bundle. | open — status corrected from `fixed_in_v1.0.19` 2026-08-10. Both share the word "launchd", which is why this one needed the diff rather than the title. No whatsapp-bundle logging fix located. |
| **v1018-D020 🔴🔴🔴** | email-bundle SIGKILLed (-9) mid-run — probably memory pressure but UNPROVEN | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d020--email-bundle-sigkilled--9-mid-run) | email-bundle either exits 0 OR SIGKILL cause is logged | **CM051 #539** (merged) `fix(ingest): bound every pwg-convo dispatch [v1018-D020]`. Repointed 2026-08-10: the row cited CM051 #20, which is merged but is the daily wiki-recompile LaunchAgent, and was shared with D019. | fixed_in_v1.0.19 (kill-cause tracing at launchd + install.sh watchdog level; root-cause investigation may spill to v1.0.20 if memory pressure is confirmed) |
| **v1018-D021 🔴🔴🔴** | Email settling throughput broken: 28 conv/hour = 148 days for 100k email install | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d021--email-settling-throughput-broken-28-conversationshour-box-doesnt-settle-in-days) | 6h post-install ≥50% of email conversations have wiki representation | **CM051 #541** (merged) `feat(ingest): every dispatch reports its own duration [v1018-D021]`. Repointed 2026-08-10: the row cited CM046 #21 (does not resolve), CM044 #21 and CM051 #21, none naming this defect. **Re-measured 2026-08-11: #541 is INSTRUMENTATION, not the fix.** Its title is "every dispatch reports its own duration"; it adds a timing workflow, a timing test, and +19/-1 in each of four pipelines. It makes throughput measurable and does not change it. #541 is also the ONLY CM051 PR that has ever referenced D021 (control: the same search finds 6 for D024), and no fast-first-pass or fanout code exists in the source pipelines. The two occurrences of "background enrichment" there belong to the v1.0.3 interactive-chat priority yield, which pauses background work while the user is chatting. | open -- deferred to v1.0.20. The claimed two-tier fanout was never built (measured 2026-08-11, see evidence cell). Acceptance stays the 6h real-box observation, and the throughput floor still needs calibration on a real mailbox (TNM). |
| **v1018-D022 🔴🔴🔴** | Chat unusably slow (30-55s/turn) + one full turn failure — not just D008 hang, actual slow | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d022--assistant-chat-unusably-slow-30-55s-per-turn--one-full-turn-failure-all-providersmodels-failed) | 90p chat turn ≤ 15s + zero all-providers-failed in 1h probe | **CITATION IS FROM ANOTHER RELEASE (2026-08-10).** oa #11 is "A7+A8 ostler-consent-gate crate (read-side gate for Rust daemons)", merged 2026-05-03 from `agent/a7-consent-gate-2026-05-03` -- a consent crate against a chat-latency defect, three months before this cut existed. The cited branch `tnm/d022-provider-retry-and-latency-warn` does not exist and has never been the head of any PR (controls: `main`, oa #230 and oa #288 all resolve). Searched the newest 100 PRs, #191-292, which spans the whole v1.0.18/v1.0.19 window: one title match, #216 "model-name-independent retry-on-empty + preload model on config reload" -- an Ollama fix, not the claimed provider retry + backoff + observability. | open -- status corrected from `fixed_in_v1.0.19` 2026-08-10 after the citation resolved to another release. The surviving half of the old status is a DOCS change, not a fix: recording 16 GB as "usable but slow" and 24 GB as recommended does not satisfy this row's acceptance (90p turn <= 15s), it REDEFINES it. Descoping on a hardware floor may well be the right call, but it is a descope and needs recording as one with Andy's sign-off -- never as `fixed`. Acceptance stays as written until he moves it. |
| v1018-D023 | Doctor `/` returns 404 (front door) + box-status busy-loop polled ~1/sec | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d023--doctor-front-door--returns-404-only-apiv1box-status-responds--busy-loop-polling-1sec) | GET / returns 200 or redirect | **CITATION IS FROM ANOTHER RELEASE (2026-08-10).** oa #12 is "consent-gate: wording-drift CI guard + format-string fix", merged 2026-05-03 from `agent/wording-drift-guard-2026-05-03`, 2 files -- a CI wording guard against a Doctor front-door 404. The cited branch `tnm/d023-doctor-front-door-and-polling-backoff` does not exist and has never been the head of any PR (controls resolve). Nothing in #191-292 matches a front-door or polling-backoff fix. | open -- status corrected from `fixed_in_v1.0.19` 2026-08-10. Sixth and seventh rows of this cut carrying a citation that does not resolve. Acceptance here is a one-line probe (`GET /` returns 200 or redirect) and stays exactly as written. |
| **v1018-D024 🔴🔴🔴** | Doctor payload hand-grafted → every later Doctor fix silently misses the cut (the trilemma; MECHANISM behind D009) | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d024--doctor-payload-is-hand-grafted-so-every-later-doctor-fix-silently-misses-the-cut-the-trilemma) | shipped doctor/ == HR015 doctor/ at pinned SHA (no drift) | **BOTH CITATIONS ARE DOCUMENTATION PRs (2026-08-10).** HR015 #15 is "Tech-debt audit doc (2026-04-24)"; the status's second citation, HR015 #2, is "Docs overnight: tech-debt sweep + brand checklist". Neither is a code fix. Cited branch 404s (control: `main` resolves). | open — status corrected from `fixed_in_v1.0.19` 2026-08-10. This row is 🔴🔴🔴 and is the stated MECHANISM behind D009, so a false `fixed` here hides a cause, not just a symptom. No code fix located for either half (auto-vendor, or the cut-time drift assertion). |
| v1018-D025 | Daemon pin 4 merges behind oa/main; `pinned_artefact_freshness` gate (task #191) still doesn't exist | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d025--daemon-pin-is-4-merges-behind-ostler-assistant-main-pinned_artefact_freshness-gate-task-191-still-doesnt-exist) | every pinned artefact at source-main-HEAD or carries justification | **CITATION CORRECTED 2026-08-11, and the ROW WAS ALSO WRONG.** Measured on `a690a75` with a control. The named primitive is genuinely absent: `pinned_artefact_freshness` appears in 5 `.md` and **0 `.sh`** (control: `pipefail` appears in 15 `.sh`, so the probe is sound). BUT the row concluded about a BEHAVIOUR from a NAME, and the behaviour partly exists: `gates/verify_wiki_image_fresh.sh:53` extracts a pinned `ghcr.io/...@sha256:` digest from install.sh and checks it against a CM044 source fingerprint, and `bin/cut.sh:177` runs CM051 `verify_cut_freshness.sh` as a cut gate. So "never a pinned container digest" is refuted. OS003 #2 was never a fix for this. | open -- corrected 2026-08-11. **The real gap is narrower than the row claimed:** artefact-digest freshness EXISTS for the wiki images; what does not exist is any check that the pinned DAEMON artefact matches its source. That is tracked as HR015 task #227 / D039 (the box cannot honestly say which daemon it runs), not here. Independent corroboration: HR015 task #191 already reads "a cut-time freshness gate ALREADY exists and is wired". |
| **v1018-D035 🔴🔴🔴** | **The locked merge bar is unfalsifiable and rewards the defect it exists to prevent.** The ruleset's bar is *shared exact ID always merges; bar = 0 collisions*. Zero collisions is ALSO what you get from over-merging: two people collapsed onto one node cannot register as a duplicate pair. Limit case: merge all 6,584 people onto one node and the bar reports a flawless graph. Found by TNM 2026-08-09 while disbelieving his own correctly-measured zero. | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md) | Both sides reported together, always: unmerged-pair count AND nodes-carrying-2+-distinct-human-names. Neither number alone is a bar. | Archie (bar shape, RULED) + Andy (thresholds) + task #659 (the over-merge guard itself) | open |
| **v1018-D036 🔴🔴** | **CM044 has 1712 test functions and no CI that runs them, so a render-path change is `CI-green` without a single page having been rendered.** Four workflows exist -- `assistant-name-check`, `operator-pii-scan`, `release-images`, `rule-09-strings-check` -- and not one invokes pytest. `release-images` is tag-only, so a PR gets three checks, none of which executes the compiler. Found 2026-08-10 while reviewing dependabot PRs #151/#152/#153, which are `mergeable=true` with every check green and land squarely on the render path: `compiler/html_sanitise.py` imports `nh3` + `BeautifulSoup` and prefers `lxml`. `lxml` goes `<6.0` -> `>=6.1.1` (MAJOR). And `_ALLOWED_TAGS = set(nh3.ALLOWED_TAGS) \| {...}` reads a module constant from nh3 -- if `0.3.x` changed that set, the post-build sanitiser's allowlist changes silently and markup is stripped from every wiki page. **MEASURED 2026-08-10 (Archie).** Count is **1712 test functions**, not "160+". The nh3 `ALLOWED_TAGS` worry above was **tested and did NOT materialise**: the set is byte-identical between 0.2.18 and 0.3.6 (75 tags, none added, none removed). The row's point stands regardless, because nothing in CI would have reported it either way -- the 5 checks a dependabot PR gets are three string/PII scanners plus one SKIPPED and one never-completed Snyk. Resolution: hand-ran `compiler/tests/test_html_sanitise.py` against origin/main in an isolated venv (16 passed under lxml 5.4.0, identical under 6.1.1, with `_PARSER` asserted `== "lxml"` so the bump was genuinely exercised), then merged **#153** (lxml, CVE-2025-7424 / CVE-2025-11731) and **#152** (nh3); **#151** is rebasing. CM044 **#176** adds the parser-independence tests that were missing, both demonstrated RED. | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md) -- filed 2026-08-10 | CM044 CI runs the compiler suite on every PR AND the check is REQUIRED on main. Must be demonstrated RED first: land it on a branch with a deliberately broken renderer and show the check failing, per the rule that a gate with no demonstrated RED is not a gate. | TNM -- this needs a workflow built, not a review | open |
| **v1018-D037 🔴🔴** | **D017 is not an iMessage defect -- it is per-channel wiring, and three SHIPPED channels still leak tool-call payloads to the customer.** `strip_tool_call_tags` is defined once (`zeroclaw-channels/src/util.rs`) and wired per channel. Call sites on main: telegram 33, discord 2, **imessage 0** (oa #292 fixes it), **whatsapp 0**, **email_channel 0**, **apple_mail 0**. There is no upstream scrub: `zeroclaw-api/src/lib.rs` has zero references and `agent/dispatcher.rs` mentions `tool_call` **37 times while scrubbing none** (that 37 is the positive control). So a model emitting `<tool_call>{...}` as prose reaches the customer verbatim on WhatsApp and both email paths, exactly as it did on iMessage. **Not claimed:** a runtime observation on those channels -- only that no scrub exists on their send paths nor upstream, which is the same evidence that established D017. | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md) -- filed 2026-08-10 | A source-level guard, `every_shipped_channel_scrubs_tool_calls`, asserting every shipped channel's send path calls the scrub. Must be demonstrated RED by running it against current main, where it must name whatsapp + email_channel + apple_mail. **oa #292's comment already claims this guard exists; it does not** -- the name appears once, in that comment, with zero definitions. | TNM (oa) -- the guard, then the three wirings | open |
| **v1018-D038 🔴🔴🔴** | **This is the REAL v1018-D017, split out so it cannot go green behind D037.** A bare `tool_name(args)` reply reaches the customer and nothing catches it, on every channel including the three where the XML scrub has been wired all along. **Demonstrated, not inferred** (probe run against oa main `cd01cca8`, 2026-08-10, `crates/zeroclaw-tool-call-parser`): the observed string yields `calls: 0`, text returned **unchanged**, `detect_tool_call_parse_issue -> None`. Positive control in the same run: a malformed `<tool_call>` payload yields `Some("response resembled a tool-call payload...")`, and a well-formed one yields `calls: 1`, so the probe reaches live code. Negative control: `I checked your calendar (nothing today).` yields 0 candidates. **Second, larger finding:** the detector's own result is DISCARDED. `loop_.rs:1217` binds it as `_parse_issue_detected` and nothing ever reads it, so even when the guard fires the malformed payload is still delivered. Born underscored in upstream commit `4fa47646` (2026-03-05) and never read since. The detector is observability-only by construction. | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md) -- filed 2026-08-10, split from D017 | Source invariants on `ostler-ai/ostler-assistant` main, all three required: (1) `_parse_issue_detected` must not appear in `loop_.rs`; (2) a registry-filtered bare-call recogniser `parse_bare_function_call_syntax` must exist in the parser crate; (3) the observed string must appear in a test. Necessary, NOT sufficient -- sufficiency is the named cargo test in oa's own CI, which now runs on push as well as PR. Gate below. | TNM (oa) -- limb B (contain) first, then limb A (recognise) | open |

**v1.0.19 consolidated plan:** [`v1.0.18/V1019_PLAN.md`](v1.0.18/V1019_PLAN.md) — 22 PRs total (1 cherry-pick bundle + 1 manual port + 20 fresh), sequenced across Wave 0 (structural) → Wave 1 (parallel code fixes) → Wave 2 (installer + backfill) → Wave 3 (vendor bump + tag). Target cut day: **2026-08-22 to 2026-08-23** (13–14 days from 2026-08-09).

---

## VERIFIED-STILL-IN (gates that PASS as of the most recent cut — regression-catchers)

Every fix that landed in a prior cut and MUST STAY IN. If any of these gates fails in a later cut, we shipped a regression. These are the "don't lose ground" gates.

### As of v1.0.18

| Prior-cut defect | Gate — must PASS on every cut | Last verified |
|---|---|---|
| task #259 — wiki-compile qwen fallback | `grep -q 'AI_MODEL=' ~/.ostler/.env && grep -q 'OLLAMA_MODEL=\${AI_MODEL:-' ~/.ostler/docker-compose.yml` | v1.0.18 (Archie 2026-08-09) |
| task #187 — Doctor `is_native_deployment` | OS003 gate check 3 (`grep -l 'is_native_deployment' <doctor_dir>/agent/diagnostic_rules.py`) | v1.0.18 (built-in OS003 gate) |
| task #263 — Tauri binary named `Ostler` not `zeroclaw-desktop` | `test "$(basename /Applications/Ostler.app/Contents/MacOS/*)" = "Ostler" -o "$(basename /Applications/Ostler.app/Contents/MacOS/*)" = "ostler"` | needs post-install verification, add on next walk |
| task #225 — Ostler.app frontend == daemon web-dist commit | `test "$(cat ~/.ostler/OSTLER_HUB_BUILD_COMMIT)" = "$(<pull frontend commit from Ostler.app Info.plist>)"` | needs post-install verification, add on next walk |
| task #219 — wiki compiler uses `localhost:7878` not `oxigraph:7878` | `grep -c 'oxigraph:7878' <wiki compiler .py files> = 0` (pending regression check per task #260) | task #260 says regression — VERIFY THIS CUT before promoting to VERIFIED |
| task #221 — Ostler.app notarisation ticket stapled | `xcrun stapler validate /Applications/Ostler.app` returns 0 | needs post-install verification |

---

## DEFERRED (Andy signed off — do not block cuts)

Defects real, explicitly deferred. Gate not required but tracked so we don't lose them.

*(empty as of 2026-08-09 — no v1.0.18 defects deferred yet)*

---

## Cut-status table

Machine-readable summary. Each cut lists new defects introduced + prior defects verified fixed + prior defects verified still-in + prior defects regressed.

| Cut | New defects | Fixes landed | Verified still-in | Regressed |
|---|---|---|---|---|
| v1.0.18 | **NO-SHIP RECOMMENDED**: D001 (Funnel), D002 (wiki-not-avail UX), **D004 🔴 ghost-person**, **D005 🔴 16% dedupe frag = task #257 shipping again**, D006 (Nia/Niaj), D007 (hydration observability), **D008 🔴 chat hangs on 16 GB behind wiki-compile lock**, **D009 🔴 dedupe review buttons 404 — escape hatch dead**, D003 (gate-stale — Archie's own fault) | task #259 verified in-place | task #187 (at moved path), task #225 (partial), task #263 (partial) | (walk in progress) |

---

## Pipeline wire-up (how this file becomes gates)

For each row under `MUST-FIX-NEXT`, `pipeline/release.yml` should:

1. Extract the gate command from the row (or the linked ledger entry)
2. Run it against the built DMG BEFORE the notarise step
3. FAIL the pipeline on any RED gate

For each row under `VERIFIED-STILL-IN`, the same but against the installed box during the behavioural gate stage.

**Author note (Archie 2026-08-09):** the mechanical extraction script `pipeline/extract_gates_from_rollforward.py` doesn't exist yet — needs writing. That's task-of-the-cut for whoever wires v1.0.19's cut pipeline. Until then, the pipeline maintainer reads this file by hand at cut time, and I'll write the extractor as a separate PR.

---

# MACHINE-READABLE GATE REGISTRY

**This section is the pipeline's input.** The tables above are the human index; the fenced blocks below are what `pipeline/release.yml` executes. Authored by Archie, parsed by TNM's extractor (see channel 2026-08-09 03:38 for the agreed contract).

## Parser contract

Each gate is a fenced block whose info-string carries four fields:

```
gate id=<ledger-id> expect=<int> runs-on=<box|artefact|repo>
```

- **`id`** must match a ledger entry exactly. An id with no ledger entry is a **parse error, not a skip** — that closes the "orphan gate silently always passes" hole.
- **`expect`** is the required exit code. Normally `0`.
- **`runs-on`** — `box` = SSH to the installed target; `artefact` = against the mounted DMG; `repo` = against a checkout.
- **Body** is plain `sh` (macOS `/bin/sh`), read-only, idempotent.
- **One gate per ledger entry.** Multiple assertions join with `&&` so a row is binary green/red.
- A MUST-FIX-NEXT entry with **no** gate block is a **parse error**.
- **NEGATIVE CONTROL IS MANDATORY — a gate with no demonstrated RED is not a gate.** TNM's proposal, adopted 2026-08-09. Before a gate is accepted into the registry its author must have watched it FAIL against the pre-fix state and PASS against the fixed state, and must record both in the PR. This closes the reversed-conclusion hole structurally rather than by care.
  - The case that motivated it: D009's original gate probed `/doctor/api/duplicate-decision`, a URL that never existed. It would have returned RED forever regardless of product state — indistinguishable from a real defect, and it cost hours. Authored by me.
  - TNM demonstrated the standard on D010: pre-fix file → RED, fixed file → GREEN, both shown in CM044 PR #171.
  - **THE CONTROL MUST BE DEMONSTRATED IN THE ENVIRONMENT THE GATE RUNS IN, not the one its author is sitting in.** Added 2026-08-10, and D010 is the case that earned it. That control was sound: the author watched it go red on the pre-fix file and green on the fixed one, in a shell with `docker` on `PATH`. A `runs-on=box` gate executes over `ssh … 'sh -s'`, which does **not** source the login profile and therefore has **no Homebrew PATH**. So on the box `docker` was "command not found", D010's `… && { FAIL }` never fired, control fell through to `exit 0`, and the gate reported **GREEN while being structurally unable to report its defect at all**. Its sibling D009 used `||` and reported RED for the same non-reason. A negative control proved in the wrong environment is not a weaker control — it is an *untested* one, and it is indistinguishable from a good one in the PR. When the demonstration cannot be run where the gate runs, say so in the PR rather than letting a local pass stand in for it.
  - One gate in this registry is **negative-control-by-construction** (it asserts a failure, so it cannot silently always-pass): `v1018-D009`'s JS-origin check.
  - **`v1018-D027` was listed here too and no longer qualifies (2026-08-10).** That claim described a body which ran `env -u CI make ship` and asserted it failed. Two things were wrong with it. First, an edit left an orphaned `&& { ... }` after the block, so the body was a **bash syntax error**: it exited 2 without executing one assertion, and scored RED on every run for a reason unrelated to D027. Second, and worse if it had parsed: proving the guard by *invoking the thing it guards* means that when the guard IS broken — the one case the gate exists to catch — the check **cuts a signed DMG** as its side effect. The property is static, so it is now asserted statically and nothing is executed. Its discrimination is therefore demonstrated by mutation, not by construction, and both halves are recorded in the PR.
  - The general lesson, which is the same one D027 is *about*: **"cannot always-pass by construction" is itself a claim that decays.** It was true of a body that no longer exists. Whenever a gate body is rewritten, the justification for trusting it has to be re-earned, not inherited.
- **`runs-on=repo` gates MUST assert checkout freshness first** (see `v1018-D028`). A tree can be 78 commits behind origin while `git status` reports clean, and an agent grepping it will conclude a whole subsystem does not exist:
  ```sh
  git -C "$REPO" fetch -q origin && [ "$(git -C "$REPO" rev-list --count HEAD..origin/main)" -eq 0 ] || exit 1
  ```

## Gates — v1.0.18 launch-blockers

### v1018-D001 — Funnel warning fired on the happy path

Its row has always stated its own acceptance — `tests/test_wiki_tailnet_gate.sh`
passes — and nothing enforced that, because the row had no gate block. Added
2026-08-10. The test is a good one: it carries its own negative control
(`old predicate matches a Funnel-OFF box (demonstrated RED); shipped code no
longer uses it`), so a green here is not merely an absence of error.

```gate id=v1018-D001 expect=0 runs-on=repo
# THIS TEST MOUNTS A FILE INTO A CONTAINER. The runtime here is a VM
# (Colima) and only some host paths are shared into it. A checkout under
# /tmp is NOT shared: docker then materialises a DIRECTORY at the source
# path, the bind fails "not a directory", and the test reports "pinned
# nginx rejected the generated config" -- a PRODUCT message for a TOOLING
# cause. That cost me a wrong reading on 2026-08-10, so the failure branch
# distinguishes the two instead of leaving the next reader to guess.
T="${CM051_DIR:?CM051_DIR unset}/tests/test_wiki_tailnet_gate.sh"
[ -f "$T" ] || { echo "FAIL: $T missing -- D001's stated acceptance test is gone"; exit 1; }
out="$(cd "${CM051_DIR}" && bash tests/test_wiki_tailnet_gate.sh 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && exit 0
probe="$(mktemp "${CM051_DIR}/.d001probe.XXXXXX")" && printf 'x\n' > "$probe"
if ! docker run --rm -v "$probe:/etc/probe.x" alpine:latest test -f /etc/probe.x >/dev/null 2>&1; then
  rm -f "$probe"
  echo "FAIL: cannot bind-mount a file from \$CM051_DIR into a container."
  echo "      TOOLING, not D001: this checkout is on a path the container runtime"
  echo "      does not share. A /tmp worktree does exactly this. Re-point"
  echo "      CM051_DIR under \$HOME and re-run."
  exit 1
fi
rm -f "$probe"
echo "FAIL: D001's acceptance test failed AND the container can mount from"
echo "      \$CM051_DIR, so this is the defect, not the environment:"
printf '%s\n' "$out" | grep '^FAIL' | head -5
exit 1
```

### v1018-D002 — the Wiki tab conceded on the first failed probe

Its row has always stated its own acceptance — `web/src/pages/Wiki.test.tsx`
passes — and nothing enforced that, because the row had no gate block. One of
the 14 gateless `fixed` rows v1018-D026's coverage check now blocks the cut on.
Added 2026-08-10. The fix is oa #291, merged 2026-08-09 (verified `gh api`,
`merged=true`, not asserted from the row).

**This is the first gate to read a fourth repo**, so `OA_DIR` joins the
freshness loop in `bin/rollforward_gate.sh`. Unset is skipped exactly like the
others, so adding it cannot break a run that does not need it.

**The test is worth gating on rather than merely running.** It drives the real
component against a controllable fetch and asserts the probe COUNT across the
warm-up window — not the absence of an error message, which is what a weaker
test would have checked and which the pre-fix code would also have satisfied on
the first tick.

**NEGATIVE CONTROL, run on this Mac against `origin/main`:**

| state | result |
|---|---|
| `origin/main` as shipped | **6 passed**, 1.5s |
| pre-fix defect reintroduced — the retry gated on `prev === 'probing'` inside a `setProbeState` updater | **3 failed / 3 passed** |

The three that fail are `keeps probing across the warm-up window`, `mounts the
wiki when it comes up late in the window`, and `Retry restarts the window`. The
three that still pass are the first-failure case, the concede-after-the-window
case and unmount. **That split is the evidence the test discriminates rather
than being globally brittle** — a mutation of the retry loop breaks exactly the
retry assertions and leaves the others alone.

```gate id=v1018-D002 expect=0 runs-on=repo
# TOOLING vs DEFECT, in the shape D001's gate uses, because that
# distinction cost two wrong readings on 2026-08-10.
#
# This gate needs node and an installed web/node_modules. Neither is a
# product fact, and neither failing means D002 has regressed -- so the
# failure branch says which it was instead of leaving the next reader to
# infer a product defect from a missing toolchain.
# NO APOSTROPHE in the :? message. The `word` in ${VAR:?word} is tokenised
# on its own, so an apostrophe there opens a quote even inside the double
# quotes -- and the whole body becomes a bash SYNTAX ERROR that exits 2
# before running one assertion. That is exactly what D027 was. Caught by
# running this body, not by reading it.
R="${OA_DIR:?OA_DIR unset -- D002 acceptance test lives in ostler-assistant}"
T="$R/web/src/pages/Wiki.test.tsx"
[ -f "$T" ] || { echo "FAIL: $T missing -- D002's stated acceptance test is gone"; exit 1; }

# The test must still assert the probe COUNT. A test edited down to "no
# error message appears" would pass against the pre-fix code on the first
# tick, which is precisely the defect. Gating on the file's existence
# alone would not notice that.
grep -q 'calls.n' "$T" || {
  echo "FAIL: $T no longer counts probes."
  echo "      D002 is a defect about a loop going SILENT. A test that only"
  echo "      checks for the absence of an error passes against the pre-fix"
  echo "      code, so this gate would be decorative."
  exit 1; }

V="$R/web/node_modules/.bin/vitest"
if [ ! -x "$V" ]; then
  echo "FAIL: no vitest at $V."
  echo "      TOOLING, not D002: \$OA_DIR has no installed web/node_modules."
  echo "      Run 'npm ci' in \$OA_DIR/web and re-run. Nothing here says"
  echo "      anything about the product."
  exit 1
fi
out="$(cd "$R/web" && "$V" run src/pages/Wiki.test.tsx 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && exit 0
if printf '%s' "$out" | grep -qE 'Cannot find module|ERR_MODULE_NOT_FOUND|Failed to resolve import'; then
  echo "FAIL: the test could not load. TOOLING, not D002 -- an incomplete or"
  echo "      stale node_modules in \$OA_DIR/web. Re-run 'npm ci' there."
  printf '%s\n' "$out" | grep -E 'Cannot find module|ERR_MODULE_NOT_FOUND|Failed to resolve import' | head -3
  exit 1
fi
echo "FAIL: D002's acceptance test failed AND it loaded cleanly, so this is"
echo "      the defect, not the environment:"
printf '%s\n' "$out" | grep -E '^\s+×|Tests ' | head -6
exit 1
```

### v1018-D004 — base32 blob as person display_name

```gate id=v1018-D004 expect=0 runs-on=box
# EXAMINED-COUNT CONTROL. This gate had none, and its sibling D011 carries one
# with a comment explaining exactly why -- same file, same author, and D004 was
# left behind when D011 was fixed.
#
# DEMONSTRATED 2026-08-11, pointing the old body at a directory that does not
# exist: find matches nothing, xargs runs grep over an empty list, count=0, and
# `[ 0 -eq 0 ]` reports PASS. A machine with NO WIKI AT ALL passed this gate.
# Zero violations over zero pages is not a pass; it is a gate that did not run.
DIR="$HOME/Documents/Ostler/Wiki/People"
[ -d "$DIR" ] || { echo "CANNOT-RUN: $DIR does not exist -- nothing was examined."; exit 97; }
examined=$(find "$DIR" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
[ "${examined:-0}" -gt 0 ] || { echo "CANNOT-RUN: 0 People pages in $DIR -- nothing was examined."; exit 97; }

count=$(find "$DIR" -maxdepth 1 -name '*.md' 2>/dev/null \
  | xargs grep -l 'display_name: "[0-9]* [A-Za-z0-9]\{40,\}"' 2>/dev/null | wc -l | tr -d ' ')
echo "examined $examined People page(s) in $DIR"
[ "${count:-0}" -eq 0 ] || { echo "FAIL: $count of $examined wiki pages carry a blob-like display_name"; exit 1; }
echo "GREEN: no blob-like display_name in $examined page(s)"
```

### v1018-D005 — dedupe fragmentation ratio

```gate id=v1018-D005 expect=0 runs-on=box
# THIS GATE MUST REFUSE UNLESS IT IS MEASURING AT T+0.
#
# The row's own Gate column says so: "T+0 ONLY -- hex6-suffixed ratio measured
# on the FIRST compile after a fresh install, not whenever someone looks ... the
# ratio converges, so a late measurement passes while the customer's first
# impression fails."
#
# That condition lived ONLY in the table prose. The body measured whenever it
# was run, so on any settled box it returned GREEN -- the precise reading the
# row warns is meaningless.
#
# MEASURED 2026-08-11 on the operator box:
#
#     ~/.ostler/.installer-tree-created        Aug  9 00:40   (install)
#     ~/Documents/Ostler/Wiki/.compile-complete Aug 10 18:23  (~42h later)
#     fragment ratio 1.83% (90 of 4918)  ->  gate said GREEN
#
# 1.83% against a 5% threshold looks like a comfortable pass. It is a converged
# corpus on a box that has been recompiling for days, and it says nothing about
# what a customer sees on their first compile. Reporting that as GREEN would
# have retired a launch-blocker row on the one measurement its own acceptance
# criteria excludes.
#
# WHY AN OPT-IN AND NOT A TIME WINDOW: "within N hours of install" would be an
# invented environmental fact -- a fresh-install walk may compile promptly or
# slowly, and I have no basis for N. So the gate refuses to self-certify and
# requires the fresh-install walk to say so. rc=97 is CANNOT-RUN: it blocks the
# cut like any other unmet gate, but it is NOT recorded as a product defect.
if [ "${GATE_D005_T0:-0}" != "1" ]; then
    echo "CANNOT-RUN: this row accepts a T+0 measurement only (first compile after a fresh install)."
    echo "            A settled box converges and passes regardless of the defect."
    _inst=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$HOME/.ostler/.installer-tree-created" 2>/dev/null)
    _comp=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$HOME/Documents/Ostler/Wiki/.compile-complete" 2>/dev/null)
    echo "            install=${_inst:-unknown}  last compile=${_comp:-unknown}"
    echo "            Set GATE_D005_T0=1 in the fresh-install walk to assert T+0."
    exit 97
fi
total=$(ls "$HOME/Documents/Ostler/Wiki/People"/*.md 2>/dev/null | wc -l | tr -d ' ')
[ "${total:-0}" -gt 0 ] || { echo "FAIL: no People pages found — cannot measure"; exit 1; }
frags=$(ls "$HOME/Documents/Ostler/Wiki/People"/*.md 2>/dev/null | grep -cE -- '-[a-f0-9]{6}\.md$')
pct=$(awk "BEGIN{printf \"%.1f\", ($frags/$total)*100}")
awk "BEGIN{exit !($pct > 5.0)}" && { echo "FAIL: fragment ratio ${pct}% > 5% ($frags/$total)"; exit 1; }
echo "OK: fragment ratio ${pct}% ($frags/$total)"
```

### v1018-D006 — Nia/Niaj Wexcombe split (rides on D005 fix)

```gate id=v1018-D006 expect=0 runs-on=box
# The two slugs are a real person's name, so they live on the box, not in
# this register. The gate must refuse when the fixture is absent -- a gate that
# cannot read its subject must not report a pass. That instinct was right; the
# MECHANISM was wrong.
#
# It used to be:
#
#     : "${GATE_D006_SLUG_A:?set GATE_D006_SLUG_A in the box gate-fixture file}"
#
# `:?` exits non-zero with a shell diagnostic, and the runner reads any non-zero
# body exit as a MEASURED FAILURE. So the refusal was reported as "this defect
# is present" when it meant "I could not look" -- and D006 sat in the walk as a
# product defect on every run where the fixture was unset. Measured 2026-08-11:
# it was one of nine gates doing this, which is what prompted the rc=97
# sentinel (OS003 #64).
#
# 97 is the runner's CANNOT-RUN vocabulary: it still BLOCKS the cut, it is just
# not counted as a finding about the product.
if [ -z "${GATE_D006_SLUG_A:-}" ] || [ -z "${GATE_D006_SLUG_B:-}" ]; then
    echo "CANNOT-RUN: set GATE_D006_SLUG_A and GATE_D006_SLUG_B in the box gate-fixture file."
    echo "            The two slugs are a real person's name and deliberately do not live in this register."
    exit 97
fi
a=0; b=0
[ -f "$HOME/Documents/Ostler/Wiki/People/${GATE_D006_SLUG_A}.md" ] && a=1
[ -f "$HOME/Documents/Ostler/Wiki/People/${GATE_D006_SLUG_B}.md" ] && b=1
[ $((a + b)) -lt 2 ] || { echo "FAIL: both ${GATE_D006_SLUG_A}.md and ${GATE_D006_SLUG_B}.md exist -- not merged"; exit 1; }
```

### v1018-D009 — dedupe decision endpoint reachable from the wiki origin

**Note:** the pre-correction gate probed `/doctor/api/duplicate-decision`, a URL that never existed, so it would have failed forever regardless of product state. Corrected to the real route plus the actual defect (the wiki JS posting same-origin).

```gate id=v1018-D009 expect=0 runs-on=box
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d '{"action":"distinct","ids":["gate_probe_a","gate_probe_b"]}' \
  'http://127.0.0.1:8089/api/v1/wiki/duplicates/decision')
[ "$code" = "200" ] || { echo "FAIL: real dup-decision route returned $code"; exit 1; }
docker exec ostler-wiki-site sh -c 'grep -qE "8089|DOCTOR_BASE|doctorBase" /site/build-*/javascripts/dup_decision.js' \
  || { echo "FAIL: dup_decision.js still posts same-origin (:8044) and will 501"; exit 1; }
```

### v1018-D011 -- a display_name must be a name

**Note:** the pre-correction gate asserted `display_name == given_name + " " +
family_name` exactly. Measured on the box 2026-08-10, it was wrong in **both**
directions:

- **False negatives, the serious half.** Of the 9 pages carrying the actual
  defect (a kinship word in a name field) it flagged **2 and passed 7**. When the
  kinship word is stored as `given_name` -- 6 pages confirmed -- the derived
  `display_name` equals `"Mum <Family>"`, which is precisely what the gate
  asserted. **The gate's condition was satisfied BY the defect it was named for.**
- **False positives.** 36 of the 81 it did flag were legitimate middle names or
  suffixes (`"Jane Q. Doe"` with `given=Jane family=Doe`). Satisfying the old
  gate literally meant stripping real middle names to turn a row green.
- It also required `given_name` AND `family_name` to be non-empty before testing
  anything, so a page with neither and an empty `display_name` was **invisible**
  to it.

Corrected to assert the defect rather than string equality. Controls run on the
box: `"Jane Q. Doe"` passes; `"Mum Fairweather"`, `"Uncle Bob"`, a bare phone number,
an email address and `"unknown"` all fail. Flags 12 where the old gate flagged
81, and the 12 include the 3 it was structurally blind to.

Root cause is upstream in `v1018-D659` (a kinship word must never become a name),
not in display-name derivation. This gate detects; it does not locate.

**SECOND CORRECTION, 2026-08-10. The corrected gate had a vacuous green in it.**
Run verbatim on a machine with no wiki (the MBP, where
`~/Documents/Ostler/Wiki/People` does not exist), it exited **0**:

```
$ bash d011.sh ; echo "GATE EXIT=$?"
GATE EXIT=0
```

`find` matched nothing, the loop never ran, `wc -l` gave 0, and "no violations"
was reported as a pass. **Zero violations over zero pages.** The gate written to
fix a predicate that was satisfied by its own defect shipped with the failure
mode this register opens with, and neither the row nor the controls caught it,
because every control was run on the box where the directory happens to exist.

Two repairs, both demonstrated below rather than asserted:

1. **Examined-count control**, the same one TNM put in the D035 gate. The
   directory must exist and at least one page must be read, or the gate says
   CANNOT RUN and exits 1. It also prints the examined count on success, so a
   green is legible instead of merely quiet.
2. **The extraction only matched a double-quoted scalar.** For a bare
   `display_name:` with nothing after it, `sed` did not match, so `dn` became the
   literal text `display_name:` -- non-empty, therefore silently passing the very
   emptiness check it was there for. Now accepts quoted, single-quoted and bare
   scalars.

Controls, all four run 2026-08-10 against fixtures:

```
clean tree (3 pages)    GREEN  examined 3, and all three are names the OLD
                               exact-equality gate would have flagged:
                               "Jane Q. Doe", bare Ada Lovelace, 'Kwok Wing Chan'
dirty tree (8 pages)    FAIL   7 of 8, labelled by class:
                               KINSHIP PHONE EMAIL PLACEHOLDER EMPTY x3
                               ("Jane Q. Doe" in the same tree is NOT flagged)
empty directory         CANNOT RUN   <- the old body exited 0 here
absent directory        CANNOT RUN
```

Of the three EMPTY hits, one is `display_name:` with no value -- the case the
previous extraction passed.

`OSTLER_WIKI_PEOPLE` overrides the path so the controls can run against a
fixture. It defaults to the box path, so the gate is unchanged in normal use.
Bodies are executed with `sh`, not `bash` (`bin/rollforward_gate.sh` line 365
runs `sh -s` over ssh), so this is POSIX: no process substitution, and the counts
come back through markers rather than shell variables that a pipeline subshell
would discard.

```gate id=v1018-D011 expect=0 runs-on=box
KIN='\b(mum|mummy|mother|dad|daddy|father|wife|husband|gran|granny|grandma|grandad|grandpa|nan|nana|auntie|aunt|uncle|bro|sis|sister|brother|son|daughter|cousin|in-law)\b'
DIR="${OSTLER_WIKI_PEOPLE:-$HOME/Documents/Ostler/Wiki/People}"

# EXAMINED-COUNT CONTROL. The previous body exited 0 on a machine with no wiki:
# find matched nothing, the loop never ran, and "no violations" was reported as a
# pass. Zero violations over zero pages is the vacuous green this file is about.
[ -d "$DIR" ] || { echo "CANNOT RUN: $DIR does not exist. This is not a pass."; exit 1; }

# SCOPE: PERSON PAGES ONLY (v1018-D011 narrowing, 2026-08-11).
#
# The old body scanned every People/*.md. Three of them are not people --
# index.md (type: index), timeline.md (type: timeline), duplicates.md
# (type: report). They carry no display_name BY DESIGN, so all three were
# reported as "BAD EMPTY", i.e. three permanent false positives out of twelve.
#
# `type: person` is the discriminator the compiler already writes, and it
# accounts for the corpus exactly: 4915 person + 3 structural = 4918 files.
# That is why this is a scoping fix and not a convenient exclusion list.
out=$(grep -lE '^type:[[:space:]]*person' "$DIR"/*.md 2>/dev/null | while IFS= read -r f; do
  echo "EXAMINED"
  # Accept quoted, single-quoted OR bare scalars. The old extraction matched only
  # a double-quoted value, so a bare `display_name:` yielded the literal text
  # "display_name:" -- non-empty, and so silently passed the emptiness check.
  dn=$(sed -n 's/^display_name:[[:space:]]*//p' "$f" | head -1)
  dn=$(printf '%s' "$dn" | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'\$/\1/")
  [ -n "$dn" ] || { echo "BAD EMPTY $f"; continue; }
  # KINSHIP ONLY IN TITLE POSITION (leading token).
  #
  # The old test matched the kinship word ANYWHERE, so a kinship word used as a
  # SURNAME was a defect. Measured 2026-08-11: of 9 kinship hits, 2 were
  # surnames in final position -- a French surname and a Korean surname, both
  # entirely legitimate names of real people. The remaining 7 have the kinship
  # word FIRST, which is the actual defect this row names: a relationship label
  # standing in for a given name ("<kinship> <surname>").
  #
  # Deliberately still RED on the ambiguous ones. `nan` and `nana` are real
  # given names in several cultures AND English grandmother words; leading
  # position cannot separate those two, and guessing which of a real person's
  # names is a nickname is not the gate's job. It flags them; a human decides.
  dn_first=$(printf '%s' "$dn" | awk '{print $1}')
  printf '%s' "$dn_first" | grep -qiE "^${KIN#\\b}" && { echo "BAD KINSHIP $f"; continue; }
  printf '%s' "$dn" | grep -qE '^[+(]?[0-9][0-9 ()+-]{6,}$' && { echo "BAD PHONE $f"; continue; }
  printf '%s' "$dn" | grep -q '@'                           && { echo "BAD EMAIL $f"; continue; }
  printf '%s' "$dn" | grep -qiE '^(unknown|unnamed|n/?a|null|none|tbd)$' && { echo "BAD PLACEHOLDER $f"; continue; }
done)

examined=$(printf '%s\n' "$out" | grep -c '^EXAMINED' || true)
bad=$(printf '%s\n' "$out" | grep -c '^BAD ' || true)
echo "examined $examined People page(s) in $DIR"
[ "${examined:-0}" -gt 0 ] || { echo "CANNOT RUN: 0 People pages examined. Zero violations over zero pages is not a pass."; exit 1; }

printf '%s\n' "$out" | grep '^BAD ' | sed 's/^BAD /  /' | head -20
[ "${bad:-0}" -eq 0 ] || { echo "FAIL: $bad of $examined pages have a display_name that is not a name (kinship word, phone, email, placeholder or empty)"; exit 1; }
echo "GREEN: all $examined display_name values are names"
```

### v1018-D017 -- every SHIPPED channel must scrub tool-call payloads

**This row had no gate. Its stated predicate could not have one.** The row asks
for "zero raw tool-call or HTML entities in the outbound iMessage log". Measured
on the founder box 2026-08-10: **there is no outbound iMessage log.** The daemon
records "channel listening", "sent one warm hello" and "dropping inbound that
matches a recently-sent" -- never a message body, and no sent-body store exists
among `~/.ostler/**/*.db`. A gate written to that predicate would grep a surface
with no bodies in it, find zero, and pass forever. Same class as D009 (probed a
URL that never existed) and D014's `c` (grepped a string present in no file).

The leak is on the wire, delivered into the customer's Messages app. It is not
observable after the fact, so the gate has to assert the SEND PATH instead.

**And the defect is far wider than the row says.** Measured across all 33 channel
source files with a `send` fn on `ostler-assistant` main:

```
scrub present:  telegram (33 calls), discord (2), discord_history (1)
scrub ABSENT:   the other 30 -- INCLUDING ALL FOUR THE PRODUCT SHIPS
```

`install.sh` writes `enabled = true` for exactly `imessage`, `email`,
`apple_mail`, `whatsapp`. **The scrub is wired into two channels the product does
not ship and none of the four it does.** D017 is not "iMessage was forgotten";
it is a whole-surface leak of which iMessage is the one instance someone saw.

This is also the guard an earlier comment in `imessage.rs` claimed already
existed (`every_shipped_channel_scrubs_tool_calls`). It did not. Now it does.

The shipped set is DERIVED from `install.sh`, never hardcoded: a baked-in list
goes stale the first time a channel is added or dropped, and would then pass by
omission. The gate refuses to run on an empty or implausibly short derivation.

**SCOPE NOTE -- CORRECTED 2026-08-10. Read this before treating a green gate as
a fixed D017.** This gate asserts one thing only: that every shipped channel
CALLS `strip_tool_call_tags`. That is a real and currently-violated invariant,
and it is worth holding. **It is not D017.**

`strip_tool_call_tags`
(`crates/zeroclaw-channels/src/orchestrator/mod.rs:538` -- the canonical impl;
`util.rs:123` and `telegram.rs:247` both delegate to it) matches **exactly seven
literal open tags**: `<function_calls>`, `<function_call>`, `<tool_call>`,
`<toolcall>`, `<tool-call>`, `<tool>`, `<invoke>`. Its loop is
`while let Some((start, open_tag)) = find_first_tag(...)`; when no tag is found
the body never executes, `remaining` stays the whole message, and it is returned
`.trim()`ed -- unchanged.

The string this row was filed for was
`🤖 pwg_people(name:< " >Robin Fairweather< " >)`. It contains none of the seven
tags. **The scrub passes it through untouched, on every channel, including the
three where the scrub has been wired all along.** So neither `#292` nor the
widening to the other three shipped channels closes D017; they close a separate,
genuine XML-tag hole.

The HTML-entity half is **not** "untouched" as this note previously claimed --
its stated mechanism is refuted. The ledger says the angle brackets are "almost
certainly" `&lt;`/`&gt;` left by a path that "HTML-escaped the string (for a web
surface) then failed to un-escape when downshifting to plain-text iMessage."
No such path exists: `escape_html` is defined only at `telegram.rs:1743`
(private, telegram-only, correct -- that API takes `parse_mode=HTML`) and
`zeroclaw-tools/src/report_templates.rs:32`, with zero cross-channel callers;
`link_enricher.rs:148` only ever UNescapes. There is nothing on a shipped
plain-text send path that could fail to unescape. What produced `< " >` is
unknown, and is likely unknowable from logs given there is no outbound body log.

Also note `🤖 ` is the configured assistant message prefix
(`zeroclaw-config/src/schema.rs:1963`, `imessage.rs:408`), not a tool-call
renderer -- so the leaked text is the model's own reply, prefixed and sent.

**The real D017 -- a bare `tool_name(args)` string reaching a customer -- is now
filed as its own row, `v1018-D038`, with a gate that fires.** Do not mark this
row fixed on the strength of the gate below: D038 is the one that tracks the
defect this row was filed for. This row tracks the channel-scrub wiring only.

Status of the two PRs this row cites, checked 2026-08-10:
`ostler-ai/ostler-assistant#292` **MERGED**, `#296` **MERGED**. The row's citation
cell said `#292` was "OPEN, UNSTABLE" until today. Neither closes D038.

```gate id=v1018-D017 expect=0 runs-on=repo
GH="${GH_BIN:-gh}"
# Resolve the token for the repo's OWNER before every read.
#
# This gate spans TWO GitHub accounts -- andygmassey owns CM051, ostler-ai owns
# the daemon -- and `gh auth switch` is GLOBAL. Whichever is active, the other
# org answers 404 "Not Found", indistinguishable from a deleted file.
# Measured 2026-08-11 on the first completed box-walk:
#
#   andygmassey -> repos/ostler-ai/ostler-assistant/contents/...  Not Found
#   ostler-ai   -> same path                                      returns content
#   control: andygmassey -> its OWN CM051 repo                    returns content
#
# The token was not broken, it was the wrong one. The empty body then fed
# `base64 -d`, which printed `stdin: (null): error decoding base64 input
# stream`, `checked` stayed 0, and the gate said "examined 0 channel send
# paths -- the gate is measuring nothing". That message was HONEST and is the
# only reason this was findable; a gate counting zero as a pass ships a green.
#
# Same root cause as the orphan gate's gh_as, fixed the same day.
gh_owner() {   # $1 = owner/repo ; remaining args go to gh
  _o="${1%%/*}"; shift
  _t="$($GH auth token -u "$_o" 2>/dev/null || true)"
  if [ -n "$_t" ]; then GH_TOKEN="$_t" $GH "$@"; else $GH "$@"; fi
}
OA_REPO="${OA_REPO:-ostler-ai/ostler-assistant}"
CM051_REPO="${CM051_REPO:-andygmassey/CM051-Home-Hub-Installer}"

# THE SUBJECT IS THE PIN, NEVER `main`. Both refs, and both matter here: this
# gate derives the shipped channel SET from CM051's install.sh and then checks
# the daemon's send paths, so a main-vs-pin mismatch on either half asks the
# question about a product that is not being cut. At the v1.0.19 pins this gate
# reports 0 of 6 send paths scrubbing; at main it is 6 of 6. Same script.
OA_REF="${OA_REF:-${OSTLER_PIN_OA:-}}"
CM051_REF="${CM051_REF:-${OSTLER_PIN_CM051:-}}"
if [ -z "$OA_REF" ] || [ -z "$CM051_REF" ]; then
	echo "CANNOT RUN: missing pin(s) -- OA_REF='${OA_REF:-}' CM051_REF='${CM051_REF:-}'."
	echo "            Run with --cut <version> so DAEMON_COMMIT and CM051 from that"
	echo "            cut.env bind them, or set both explicitly to measure on"
	echo "            purpose. Falling back to main would ask about the wrong tree."
	exit 97
fi
echo "subject: $OA_REPO@$OA_REF + $CM051_REPO@$CM051_REF"

inst=$(gh_owner "$CM051_REPO" api "repos/$CM051_REPO/contents/install.sh?ref=$CM051_REF" --jq '.content' 2>/dev/null | base64 -d)
[ -n "$inst" ] || { echo "FAIL: could not read install.sh -- cannot derive the shipped channel set"; exit 1; }

shipped=$(printf '%s\n' "$inst" \
  | grep -A1 'echo "\[channels\.' \
  | grep -B1 'echo "enabled = true"' \
  | grep -oE '\[channels\.[a-z_]+\]' \
  | sed 's/\[channels\.//; s/\]//' | sort -u)

[ -n "$shipped" ] || { echo "FAIL: derived an EMPTY shipped-channel set -- a gate over nothing passes"; exit 1; }
n_shipped=$(printf '%s\n' "$shipped" | wc -l | tr -d ' ')
[ "$n_shipped" -ge 3 ] || { echo "FAIL: only $n_shipped shipped channels derived; the installer enables at least 4. Derivation is broken."; exit 1; }

src_files_for() {
  case "$1" in
    email)    echo "email_channel gmail_push" ;;
    whatsapp) echo "whatsapp whatsapp_web" ;;
    *)        echo "$1" ;;
  esac
}

missing=""
unread=""
checked=0
for ch in $shipped; do
  for f in $(src_files_for "$ch"); do
    body=$(gh_owner "$OA_REPO" api "repos/$OA_REPO/contents/crates/zeroclaw-channels/src/${f}.rs?ref=$OA_REF" --jq '.content' 2>/dev/null | base64 -d)
    # UNREADABLE is not ABSENT. A file that exists but could not be fetched
    # must not be silently skipped into a zero count.
    [ -n "$body" ] || { unread="$unread $ch/$f"; continue; }
    printf '%s\n' "$body" | grep -q "async fn send" || continue
    checked=$((checked + 1))
    printf '%s\n' "$body" | grep -q "strip_tool_call_tags" || missing="$missing $ch/$f"
  done
done

[ "$checked" -gt 0 ] || {
  echo "FAIL: examined 0 channel send paths -- the gate is measuring nothing"
  [ -n "$unread" ] && echo "      COULD NOT READ:$unread -- credential/path fault, NOT a finding about the code"
  exit 1; }
[ -z "$missing" ] || { echo "FAIL: shipped channels whose send path does NOT scrub tool-call payloads:$missing"; echo "      (examined $checked send paths across $n_shipped shipped channels)"; exit 1; }
echo "OK: all $checked shipped send paths scrub tool-call payloads"
```

### v1018-D003 -- the blocking gate must authenticate, not read 401 as absent data

The pre-rewrite gate probed `:8090/api/v1/people/search` unauthenticated, got 401, and
reported it as "graph lacks this person". All three v1.0.18 behavioural failures were that,
not product defects. Confirmed read-only on the founder box 2026-08-10:

```
:8090/api/v1/people/search  unauthenticated    401
:8090/api/v1/people/search  with service token 200
```

This gate asserts the CONTRACT, not the content: unauthenticated must be refused, and the
same request with the token must be accepted. Both halves matter -- a 200 without a token
would mean the store-auth hardening had regressed, which is a security finding, not a pass.

Check 1 of `verify_behavioural_acceptance.sh` (drive `/ws/chat` and assert the reply
contains a seeded fact) is NOT represented here. It writes a conversation, so it cannot run
against a live instance without polluting it. It belongs `runs-on=box` on a FRESH install
with the synthetic seed loaded, which is the ritual, and it stays out of the registry until
that box exists rather than being approximated here.

```gate id=v1018-D003 expect=0 runs-on=box
TP="${OSTLER_SERVICE_TOKEN_PATH:-$HOME/.ostler/secrets/service_token}"
[ -r "$TP" ] || { echo "FAIL: service token unreadable at $TP -- cannot test the contract"; exit 1; }
un=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://localhost:8090/api/v1/people/search?q=test" 2>/dev/null)
au=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Authorization: Bearer $(cat "$TP")" "http://localhost:8090/api/v1/people/search?q=test" 2>/dev/null)
[ "$un" = "401" ] || { echo "FAIL: unauthenticated people/search returned $un, expected 401 -- store-auth has regressed"; exit 1; }
[ "$au" = "200" ] || { echo "FAIL: authenticated people/search returned $au, expected 200 -- the gate would read this as absent data (the D003 defect)"; exit 1; }
```

### v1018-D014 — no LLM slop, prompt scaffolding, or unfilled placeholders in the wiki

Two of this gate's three sub-predicates could not fire. Measured on the founder box
2026-08-10, the old form reported `a=249 b=0 c=0` while the same box carried 6 files with
unfilled placeholders and 29 metadata-only summaries:

- **`b` scanned the wrong tree.** Placeholders reach `~/Documents/Ostler/Conversations/`,
  a customer surface in its own right; the gate looked only under `Wiki/`. Its pattern also
  drifted from the shipped `strip_placeholder_tokens`, which allows digits after the first
  letter.
- **`c` grepped a string that appears in no file.** `^--- Summary Participants` is the
  run-together form from a screenshot, not the on-disk form. Same defect as v1018-D001.
- **Neither could distinguish a fixed product from a broken one**, so the roll-forward row
  claiming D014 `fixed_in_v1.0.19` was never evidenced by two thirds of its own gate.

`c` now asserts the defect as measured: a conversation summary that renders its `### Thread`
metadata and no `### Narrative` prose. See CM051 #547 for why that is the real symptom.

```gate id=v1018-D014 expect=0 runs-on=box
W="$HOME/Documents/Ostler/Wiki"
C="$HOME/Documents/Ostler/Conversations"
[ -d "$W" ] || { echo "FAIL: $W absent -- a gate that passes because the data is missing is not a gate"; exit 1; }
[ -d "$C" ] || { echo "FAIL: $C absent -- conversation artefacts are a customer surface too"; exit 1; }
a=$(grep -rlE '<div class="pw-summary"><p>[0-9]+$' "$W/People/" 2>/dev/null | wc -l | tr -d ' ')
# Split on the same axis as `c` below, and for the same reason: a
# placeholder in a flat legacy artefact is a remnant, one in the Wiki or in
# a <date>/<slug>/ artefact is current output. Counting them together would
# leave this gate failing on migration debris while its message said
# "current layout", which is the mislabelling the split exists to stop.
b=$(grep -rlE '\{[a-z][a-z0-9_]*\}' "$W/" 2>/dev/null | wc -l | tr -d ' ')
b=$((b + $(find "$C" -mindepth 2 -name '*.md' -exec grep -lE '\{[a-z][a-z0-9_]*\}' {} + 2>/dev/null | wc -l | tr -d ' ')))
b_legacy=$(find "$C" -maxdepth 1 -name '*.md' -exec grep -lE '\{[a-z][a-z0-9_]*\}' {} + 2>/dev/null | wc -l | tr -d ' ')
# The conversation check used to be `for f in "$C"/*.md` -- ONE directory
# level, no descent. It therefore counted only the flat top-level files and
# never saw the artefacts the shipping writer actually produces, which live
# at <date>/<slug>-<short-id>/. On the founder box that is 131 flat files
# examined and 393 nested files ignored.
#
# The two populations are NOT the same thing, established at source:
# cm048_pipeline/src/conversation_writer.py::_resolve_folder returns
# `base / date_part / folder_name` unconditionally, with date_part falling
# back to "unknown" when started_at is empty. There is no flat branch. The
# shipping writer CANNOT emit a top-level .md, so every flat file predates
# it and is a migration remnant, not current output.
#
# Counting them together let a remnant be reported as a shipping defect --
# and hid the fact that the 393 files the current writer DID produce have
# zero of either symptom. Counted separately now: `c` is the shipping
# verdict and fails the gate; `legacy` is reported for cleanup and does not.
c=0
legacy=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  grep -q '^### Thread' "$f" || continue
  grep -q '^### Narrative' "$f" && continue
  case "$f" in
    "$C"/*/*) c=$((c + 1)) ;;
    *)        legacy=$((legacy + 1)) ;;
  esac
done <<EOF
$(find "$C" -name '*.md' 2>/dev/null)
EOF
if [ "${legacy:-0}" -eq 0 ] && [ "${b_legacy:-0}" -eq 0 ]; then
  echo "note: no legacy flat-layout conversation debris remains"
else
  echo "note: legacy flat-layout debris -- $legacy without a narrative, $b_legacy with an unfilled placeholder."
  echo "note: migration cleanup, NOT a shipping defect: the current writer cannot emit this layout."
fi
[ "${a:-0}" -eq 0 ] && [ "${b:-0}" -eq 0 ] && [ "${c:-0}" -eq 0 ] \
  || { echo "FAIL: numeric-only summaries=$a, unfilled placeholders=$b, metadata-only summaries=$c (current layout)"; exit 1; }
```

### v1018-D019 — whatsapp-bundle must not fail silently

```gate id=v1018-D019 expect=0 runs-on=box
L=com.creativemachines.ostler.whatsapp-bundle
ec=$(launchctl print "gui/$(id -u)/$L" 2>/dev/null | grep -oE 'last exit code = [0-9]+' | grep -oE '[0-9]+$')
[ "${ec:-0}" = "0" ] && exit 0
se=$(stat -f %z "$HOME/.ostler/logs/whatsapp-bundle.err" 2>/dev/null || echo 0)
sl=$(stat -f %z "$HOME/.ostler/logs/whatsapp-bundle.log" 2>/dev/null || echo 0)
[ "$se" -gt 0 ] || [ "$sl" -gt 0 ] \
  || { echo "FAIL: whatsapp-bundle exited $ec with zero-byte .err AND .log — ships dark"; exit 1; }
```

### v1018-D020 — email-bundle must not be silently SIGKILLed

```gate id=v1018-D020 expect=0 runs-on=box
L=com.creativemachines.ostler.email-bundle
ec=$(launchctl print "gui/$(id -u)/$L" 2>/dev/null | grep -oE 'last exit code = [-0-9]+' | grep -oE '[-0-9]+$')
case "${ec:-0}" in
  -9|137)
    grep -qE 'email-bundle.*(killed|SIGKILL|terminated)' "$HOME/.ostler/logs/"*.log 2>/dev/null \
      || { echo "FAIL: email-bundle SIGKILLed with no logged reason"; exit 1; } ;;
esac
```

### v1018-D023 — Doctor front door must not 404

```gate id=v1018-D023 expect=0 runs-on=box
code=$(curl -sS -o /dev/null -w '%{http_code}' 'http://127.0.0.1:8089/')
case "$code" in 200|301|302) ;; *) echo "FAIL: Doctor / returned $code"; exit 1 ;; esac
```

### v1018-D007 — the hydration surface is backed by an endpoint that substantiates it

The old acceptance named `/doctor/api/hydration`, a path that returns 404. It could never
fire, so it was never demonstrated green -- the same class as D016's false RED, and the same
class as D017 naming a surface that does not exist.

The real endpoint is `/api/v1/hydration/status`, and its phase objects are **state-dependent**,
which is why a flat key check is the wrong shape:

```
contacts       state=done      keys = count, key, state
graph          state=done      keys = count, key, state
ai_summaries   state=running   keys = done, eta_seconds, eta_utc, key, state, total
conversations  state=pending   keys = completed, dispatched, failed, key, running, state
```

This gate asserts the trust property rather than a literal payload: a phase must carry enough
numeric substance for the state it claims. A `running` phase without `done`/`total` means the
headline figure the customer sees is derived from nothing, which is exactly the task #208 class
this row was filed under. `pending` carries no numeric requirement because nothing has happened
yet -- demanding one there would make the gate stricter than the defect.

Controls, all run on the shipped v1.0.18 box 2026-08-10:

```
A  live box, unmodified                     PASS (exit 0, "4 phases, overall_state=running")
B  the path this row named until today      FAIL (404)
C  running phase with `total` removed       FAIL ("state=running but has no total")
D  phases = []                              FAIL ("any headline figure derived from it is unbacked")
```

C and D were driven through the same checker as A, so the predicate is demonstrated to fire and
to pass, not merely to compile.

```gate id=v1018-D007 expect=0 runs-on=box
H="${OSTLER_DOCTOR_URL:-http://127.0.0.1:8089}/api/v1/hydration/status"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$H" 2>/dev/null)
[ "$code" = "200" ] || { echo "FAIL: $H returned $code, expected 200 -- the hydration surface has no endpoint behind it"; exit 1; }
curl -s --max-time 8 "$H" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not isinstance(d, dict):
    sys.exit("FAIL: hydration payload is not a JSON object")
for k in ("overall_state", "phases"):
    if k not in d:
        sys.exit("FAIL: hydration payload missing %s -- the displayed state is not backed by the endpoint" % k)
p = d["phases"]
if not isinstance(p, list) or not p:
    sys.exit("FAIL: phases is empty or not a list -- any headline figure derived from it is unbacked")
REQUIRED = {"done": ("count",), "running": ("done", "total")}
for i, ph in enumerate(p):
    if not isinstance(ph, dict):
        sys.exit("FAIL: phases[%d] is not an object" % i)
    for k in ("key", "state"):
        if k not in ph:
            sys.exit("FAIL: phases[%d] missing %s" % (i, k))
    for k in REQUIRED.get(ph["state"], ()):
        if k not in ph:
            sys.exit("FAIL: phases[%d] (%s) is state=%s but has no %s -- progress shown for it would be unbacked" % (i, ph["key"], ph["state"], k))
        if not isinstance(ph[k], int):
            sys.exit("FAIL: phases[%d] (%s).%s is %s, not an integer" % (i, ph["key"], k, type(ph[k]).__name__))
print("OK: %d phases, overall_state=%s, each substantiated for its state" % (len(p), d["overall_state"]))
'
```


### v1018-D010 — no background painted on wiki h2 headings

```gate id=v1018-D010 expect=0 runs-on=box
docker exec ostler-wiki-site sh -c \
  'grep -nE "^\.pw-doc \.pw-h2\{background" /site/build-*/stylesheets/extra.css' >/dev/null 2>&1 \
  && { echo "FAIL: bare .pw-doc .pw-h2 background rule still collides with the section-heading class"; exit 1; }
exit 0
```

### v1018-D016 — wiki type scale not inflated in a standalone browser

**GATE CORRECTED 2026-08-10, and the old one was a FALSE RED.** The previous
body required the selector and the declaration on a **single line**:

```
grep -qE "^html\{font-size:100%|^html \{ *font-size: *100%"
```

The shipped CSS is ordinary multi-line CSS:

```css
html {
  font-size: 100% !important;
}
```

`extra.css` is 3157 lines and **not** minified, so that rule was never going to
be on one line. The old gate therefore returned FAIL on a build that **contains
the fix**. It cannot ever have passed, which means it was never demonstrated
GREEN -- only assumed. Left alone it would have blocked a cut on an
already-fixed defect, or sent someone to re-fix working code.

The corrected gate parses the `html` block instead of pattern-matching a
formatting accident, and it additionally holds the **unscoped** requirement that
`extra.css`'s own comment calls out ("Keep this selector unscoped.
`tests/test_type_scale.py` fails if the `.ostler-embed` qualifier comes back").

**CONTROLS, run on the founder box 2026-08-10 against the v0.1.8 image
(`ostler-wiki-site` `3f8e01f8952d`, build dir `build-20260810-035744`):**

| control | result |
|---|---|
| A -- unmodified box CSS | **PASS** |
| B -- `html` block deleted | **FAIL** |
| C -- re-scoped to `.ostler-embed html {` | **FAIL** |

B and C are the two ways this defect can come back, and the gate catches both.
A green here is therefore load-bearing, which the old one's green never was.

```gate id=v1018-D016 expect=0 runs-on=box
CSS=$(docker exec ostler-wiki-site sh -c 'ls -d /site/build-*/stylesheets/extra.css 2>/dev/null | tail -1')
[ -n "$CSS" ] || { echo "FAIL(tooling): no extra.css in ostler-wiki-site -- toolchain, not defect"; exit 1; }
docker exec ostler-wiki-site sh -c "awk '
  /^html[[:space:]]*\{/ { inblk=1; next }
  inblk && /font-size:[[:space:]]*100%/ { found=1 }
  inblk && /\}/ { inblk=0 }
  END { exit !found }
' $CSS" \
  || { echo "FAIL: no UNSCOPED html{ ... font-size:100% ... } -- browser view still inherits Material 125%"; exit 1; }
```

### v1018-D026 — Part 2: cuts must be tag-triggered and gate-enforced

```gate id=v1018-D026 expect=0 runs-on=repo
wf=".github/workflows/release.yml"
[ -f "$wf" ] || { echo "FAIL: no release workflow"; exit 1; }
grep -qE 'tags:|v1\.0\.\*' "$wf" || { echo "FAIL: release workflow is not tag-triggered"; exit 1; }
grep -q 'workflow_dispatch' "$wf" && { echo "FAIL: workflow_dispatch present — a hand-cut in a costume"; exit 1; }
grep -q 'rollforward' "$wf" || { echo "FAIL: pipeline never runs the rollforward gate"; exit 1; }
```

### v1018-D027 — Part 3: `make ship` must refuse to sign outside CI

**Negative-control by construction** — this gate asserts a failure, so it cannot silently always-pass.

```gate id=v1018-D027 expect=0 runs-on=repo
# This gate did not run AT ALL between 2026-08-09 and 2026-08-10. An edit
# left an orphaned `&& { ... }` line after the block below, so bash exited
# 2 on a syntax error before reaching a single assertion. It scored RED
# throughout -- for a reason that had nothing to do with D027 -- which is
# the same class of failure D027 itself is about: a check that reports a
# verdict it did not earn.
#
# It also USED to run `env -u CI make ship` to prove the guard refuses
# outside CI. That is not a safe way to test this: if the guard is broken
# -- exactly the case the gate exists to catch -- then the check CUTS A
# SIGNED DMG as its side effect. The property is static, so it is now
# asserted statically and nothing is executed.
#
# `make ship` is the FRONT door. Asserting only on it stayed green while
# `make sign-python-bundle && make staple-apps && make package` still produced a
# signed, stapled artefact locally (found reviewing #536, 2026-08-09). Assert the
# whole signing surface: every target whose recipe actually invokes codesign
# --sign / --force --sign / stapler staple / notarytool submit must name
# guard-local-cut. DERIVED from the Makefile, not an allow-list, so a signing
# target added later is caught too.
mk="${CM051_DIR:?CM051_DIR unset}/gui/Makefile"
[ -f "$mk" ] || { echo "FAIL: no gui/Makefile at $mk"; exit 1; }
holes=0
for t in $(grep -oE '^[a-z][a-z0-9-]*:' "$mk" | tr -d ':' | sort -u); do
  body=$(awk -v tgt="^$t:" 'BEGIN{p=0} $0~tgt{p=1;next} p&&/^[a-zA-Z][a-zA-Z0-9_-]*:/{exit} p&&!/^[[:space:]]*#/' "$mk")
  printf '%s' "$body" | grep -qE 'codesign --force --sign|codesign --sign|xcrun stapler staple|xcrun notarytool submit' || continue
  grep -qE "^$t:.*guard-local-cut" "$mk" || { echo "FAIL: signing target '$t' has no guard-local-cut"; holes=$((holes+1)); }
done
[ "$holes" -eq 0 ] || { echo "FAIL: $holes signing target(s) sign without the guard (v1018-D027)"; exit 1; }
# The front door itself, asserted without opening it: `ship` must name
# guard-local-cut among its prerequisites.
grep -qE '^ship:[^#]*[[:space:]]guard-local-cut([[:space:]]|$)' "$mk" \
  || { echo "FAIL: the ship target does not require guard-local-cut — the bypass is open at the front door"; exit 1; }
exit 0
```

### v1018-D028 — no fix spec may verify against a checkout without a freshness assertion

```gate id=v1018-D028 expect=0 runs-on=repo
hits=$(grep -rLE 'rev-list --count HEAD\.\.origin|gh api repos/' cuts/*/FIX_SPEC_*.md 2>/dev/null | wc -l | tr -d ' ')
[ "${hits:-0}" -eq 0 ] || { echo "FAIL: $hits fix specs verify against a checkout with no freshness assertion"; exit 1; }
```

### v1018-D029 -- the freshness gate must be mockable, timed, and self-tested green

The cut-freshness self-test was RED on `main` on EVERY run from 2026-08-01T15:47Z to
2026-08-09 -- eight days spanning the v1.0.16, v1.0.17 and v1.0.18 cuts. Root cause was
in the GATE, not the test: `29c20b1` wrote the daemon provenance chain with bare `gh`
calls instead of the script's own `api <account>` helper, bypassing `$GH_BIN` (so it
could not be mocked and its cases could never pass, no matter what the mock did),
`run_to $GH_API_TIMEOUT` (an unbounded call in a gate that bounds every other one), and
the `rc=2` UNREACHABLE signal (so a network blip printed a confident RED -- a false RED
in the fail-closed direction, which is how a gate trains people to ignore it).

Separately the test's case (c) asserted `daemon ... RED STALE:+12`, a contract the same
commit deleted, so it could never pass again; the five RED branches that replaced it had
zero coverage. Fixed in CM051 #538 with (c1)-(c7).

Demonstrated RED against `origin/main`: bare `gh api` count **5** before, **0** after;
self-test **12/18** with the new cases against the old gate, **18/18** after.

```gate id=v1018-D029 expect=0 runs-on=repo
cd "${CM051_DIR:?CM051_DIR unset}" || exit 1
# Every API call must go through $GH_BIN. `gh auth token` inside token_for is exempt --
# it is short-circuited under FRESHNESS_GH_BIN. Bare `gh api` must be zero.
bare=$(grep -cE '(^|[^_A-Za-z"$/])gh api' scripts/verify_cut_freshness.sh)
[ "${bare:-1}" -eq 0 ] || { echo "FAIL: $bare bare 'gh api' call(s) in the freshness gate -- unmockable and untimed (v1018-D029)"; exit 1; }
out=$(bash tests/test_cut_freshness_gate.sh 2>&1) || { echo "FAIL: cut-freshness self-test exited non-zero"; printf '%s\n' "$out" | tail -6; exit 1; }
printf '%s' "$out" | grep -qE '/ 0 failed' || { echo "FAIL: cut-freshness self-test not fully green"; printf '%s\n' "$out" | grep -E '^  FAIL'; exit 1; }
exit 0
```

### v1018-D030 -- a guard cited in a comment must actually exist

`_render_meeting_heatmap`'s docstring cited `tests/test_single_heatmap_renderer.py` from
2026-08-08 as "fails the build if a second emitter reappears". That file had never
existed -- not on any branch, not in history -- so grepping for the promise returned a
false green and the invariant it claimed to protect was unguarded. Written for real in
CM044 #171 (merged 2026-08-09).

**If you cite a guard in a comment, write the guard in the same commit.** A comment
asserting a mechanism that does not exist is worse than silence: the next reader, human
or agent, stops looking.

```gate id=v1018-D030 expect=0 runs-on=repo
cd "${CM044_DIR:?CM044_DIR unset}" || exit 1
missing=0
for f in $(grep -rhoE 'tests/test_[a-z0-9_]+\.py' --include='*.py' compiler/ 2>/dev/null | sort -u); do
  [ -e "$f" ] || [ -e "compiler/$f" ] || { echo "FAIL: source comment cites a guard that does not exist: $f"; missing=$((missing+1)); }
done
[ "$missing" -eq 0 ] || { echo "FAIL: $missing cited guard(s) do not exist (v1018-D030)"; exit 1; }
exit 0
```

### v1018-D031 -- a classified document must COMPLETE, not merely fail within a ceiling
> **NUMBER RETRACTED 2026-08-09 21:0x, AND THE DEFECT REFRAMED. Read this before the text
> below, which still contains the superseded 13-hour figure.**
>
> `ps etime` is wall-clock and **includes system sleep**. `pmset -g log` on .210 shows the
> Mac in Deep Idle from the 03:47 start until a 09:36 wake, so **~5h49m of the "13-hour
> hang" was a sleeping machine, not a wedged process.** Awake wall-clock is ~7h11m.
>
> Second and more useful measurement: a live pwg-convo shows `etime 27:11` against
> `cputime 0:19.90` -- **27 minutes of wall-clock for 20 seconds of CPU.** These processes
> are ~99% blocked on Ollama. **Elapsed time was never a proxy for work.**
>
> With that correction the accounted worst case (3-4 chunks x 900s + merge + validation
> retry, x MAX_RETRIES=3 plus backoff) is **~3h47m to ~4h30m against ~7h11m awake** -- a
> factor of 1.6 on an estimate with unknown chunk count, **not the order of magnitude that
> demanded a different mechanism.** TNM withdraws that claim; so do I, having repeated it.
>
> **THE REAL DEFECT IS WORSE THAN A HANG.** Nothing is stuck. The step's bounded worst case
> is **four and a half hours BY DESIGN** for a single email -- five LLM calls at 900s each,
> times three retries. **A per-call timeout can never fix this, because every call is
> individually within its limit.** D020's ceiling bounds the blast radius and cannot bound
> this.
>
> **Fix is therefore a STEP-LEVEL BUDGET, not another per-call bound:** `_step_enrich` gets
> a total wall-clock allowance across chunks, merge and validation, and abandons the
> document with a recorded reason on exceeding it. That is also what makes the
> assert-completion gate tractable -- a budgeted step either completes or says why, in
> minutes rather than hours.
>
> **Durable lesson, TNM's words: three of his figures today were wrong because he kept
> quoting elapsed time as though it were effort.** On a box where the model is the
> bottleneck and the machine sleeps, `etime` measures neither. Any future timing claim in
> this register must state whether it is wall-clock, awake wall-clock, or CPU.


Split out of D020 on 2026-08-09. **D020 is fixed; this is not.** TNM's CM051 #539 bounds
every pwg-convo dispatch, so a document that wedged for 13 hours now wedges for the
ceiling and returns 75. Correct, shippable, and still a document that never completes.

Folding this into D020 and marking D020 done would hide the real failure behind a green
tick -- bounding a symptom and calling the cause closed, which is the disease this whole
cut exists to break.

**What is established, and what is NOT.** Four feeds were dead for 13 hours while
`launchctl list` reported every label healthy -- fact. pwg-convo reached the classify step
and completed an Ollama call in 9.6s -- fact. The process then never exited -- fact.

**That it hung AFTER the classify branch is NOT established, and this entry previously
said it was.** My error: I wrote "localised to after the classify branch" into this
ledger on the strength of a stderr excerpt. TNM then checked the shape of his own
evidence -- the swallow line is `proc.stderr.strip()[:500]`, and the captured block is
exactly 500 characters, cut mid-word. Those four lines are the FIRST 500 characters of
that process's stderr, not the last. What it logged over the following 13 hours is
unknown. A truncation was read as an ending, by him first and then by me, and I hardened
it into a ledger entry without checking.

So we have the START of the diagnosis, not the middle. The fix must be found, not
inferred from where the visible log happens to stop.

Not D019: different feed, different mechanism, and D019's exit 78 happens before any
dispatch runs at all.

The gate must assert COMPLETION. A gate that accepts rc=75 would go green on exactly the
state this entry exists to describe.

```gate id=v1018-D031 expect=0 runs-on=box
# A bulk/marketing document must finish, not time out. rc=75 is the D020 ceiling
# firing, which means this defect is still live -- treat it as RED, not as a pass.
log="$HOME/.ostler/logs/email-bundle.log"
[ -f "$log" ] || { echo "FAIL: no email-bundle.log to judge"; exit 1; }
tail -2000 "$log" | grep -qE 'dispatch (complete|ok).*bulk|classified.*bulk.*-> (stored|done)' \
  || { echo "FAIL: no completed bulk/marketing dispatch in the last 2000 lines"; exit 1; }
if tail -2000 "$log" | grep -qE 'rc=75|EX_TEMPFAIL|TimeoutExpired'; then
  echo "FAIL: dispatch ceiling fired -- document still never completes (v1018-D031)"; exit 1
fi
exit 0
```

### v1018-D032 -- captured stderr keeps the head, when a hang needs the tail

`proc.stderr.strip()[:500]` in the conversation-feed dispatch keeps the FIRST 500
characters of a failed child's stderr. For a hang that is precisely the least useful
window: the tail is where the last thing the process did before wedging lives. The head
is the startup chatter.

Found by TNM while retracting his own over-claim on D031 -- the 500-char block was cut
mid-word at `sender:noreply`, which is what exposed it as a truncation rather than an
ending. It is the reason D031's diagnosis stops where it does.

Own row rather than folded into D031, on the same principle that split D031 from D020: a
one-line fix may ship inside another PR, but a defect must not lose its identity, because
when the parent closes the child becomes invisible. This one outlives D031 -- it degrades
every dispatch failure on every feed, not just the bulk/marketing document.

Fix is `[-500:]` plus an explicit truncation marker so the next reader knows the window
was clipped and from which end. Landing in TNM's D031 branch.

```gate id=v1018-D032 expect=0 runs-on=repo
# The dispatch stderr capture must keep the TAIL, and must say it truncated.
cd "${CM051_DIR:?CM051_DIR unset}" || exit 1
bad=0
for f in vendor/email_source/pipeline.py vendor/whatsapp_source/pipeline.py \
         vendor/imessage_source/pipeline.py vendor/spoken_source/pipeline.py; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; bad=$((bad+1)); continue; }
  if grep -qE 'stderr[^\n]*\[:[0-9]+\]' "$f"; then
    echo "FAIL: $f keeps the HEAD of stderr -- a hang needs the tail (v1018-D032)"; bad=$((bad+1))
  fi
  grep -qE 'stderr[^\n]*\[-[0-9]+:\]' "$f" \
    || { echo "FAIL: $f does not keep a stderr tail at all"; bad=$((bad+1)); }
done
[ "$bad" -eq 0 ] || exit 1
exit 0
```

### v1018-D033 -- the canonical cut doc points at a pin the register does not hold

`CUT_MECHANISM_CANONICAL.md:112` instructs: for cm048_pipeline, "use a FRESH clone at the
pinned SHA". `release.toml` is the register that should hold that SHA. It holds `sha = ""`.

Found by TNM while resolving D031 placement; verified by me at source, and it is WIDER than
either of us reported. He named one repo. I then said four, having eyeballed the section he
quoted instead of enumerating. **Running the gate enumerated SIX:**

```
[repos.cm044] sha = ""      <- the wiki, consumed directly by the cut
[repos.cm051] sha = ""      <- the installer itself
[repos.cm041] sha = ""
[repos.cm048] sha = ""
[repos.cm019] sha = ""
[repos.cm021] sha = ""
```

`cm044` and `cm051` are the two the cut consumes most directly, which makes this not a
cm048 quirk: **the register is essentially unpopulated** while a canonical doc sends people
to it for pins. My own four-not-six error is the point of the gate -- reading finds what you
already suspect, enumerating finds the rest.

The only place the cm048 pin actually exists is CM051's `vendor/VENDOR_MANIFEST.toml`
(`pinned_sha = 2133786a...`, `verify = "skip"`) -- the CONSUMER, not the register.

**This is v1018-D030 in a different costume.** D030 was a docstring citing a test file that
did not exist. This is a canonical procedure citing a pin the mechanism does not hold. Both
read as authority; both send the next person to an empty box. The class is: *a document
asserting a mechanism nobody checked was there.*

**RULING: do not hand-fill the register.** TNM proposed the line and declined to write it
himself, which was right. Writing a SHA that cannot be verified against a healthy clone is
manufacturing provenance, and manufactured provenance is worse than an admitted gap -- it
converts "we do not know" into "we asserted, wrongly", which is unfalsifiable later.

Correct shape, in order:
1. The doc names where the pin ACTUALLY lives (the CM051 vendor manifest) rather than
   implying the register holds it.
2. The register's empty entries carry an explicit reason, not bare `sha = ""`.
3. A gate asserts register and consumer never DISAGREE when both are populated -- that is
   the invariant that matters, and it is checkable without inventing a value.

**Demonstrated RED before trusting it** (late -- I filed this gate a tick before proving it,
breaking the rule I have enforced twice today): against current `origin/main` it reports
**RED, 7 findings** (six empty shas + the doc citation). Against a fixture where each empty
entry carries a stated reason and the doc names the vendor manifest as the pin's home:
**GREEN**. So it discriminates rather than always-failing.

```gate id=v1018-D033 expect=0 runs-on=repo
# A doc must not cite a pin the register does not hold, and where both hold one they
# must agree. Empty is permitted ONLY with a stated reason on the same or prior line.
rel="${OS003_DIR:?OS003_DIR unset}/release.toml"
doc="${OS003_DIR}/CUT_MECHANISM_CANONICAL.md"
[ -f "$rel" ] && [ -f "$doc" ] || { echo "FAIL: register or canonical doc missing"; exit 1; }
bad=0
# The name class was [a-z0-9]+ until 2026-08-10, which SILENTLY SKIPPED
# [repos.ostler_assistant] and [repos.ostler_fda] -- the daemon source pin
# and the FDA vendored tree. The gate reported six failures, looked
# thorough, and never examined the two pins that matter most. Underscores
# were the whole reason.
#
# Widening the class fixes today's miss. The completeness check below is
# what stops the next one: whatever shape a section name takes, the number
# examined must equal the number present.
present="$(grep -cE '^\[repos\.' "$rel")"
seen=0
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  seen=$((seen+1))
  line="$(grep -A1 "^\[repos\.${repo}\]" "$rel" | grep '^sha' || true)"
  case "$line" in
    *'sha = ""'*)
      # The reason must be ON THE sha LINE and must be about the PIN.
      # It used to be satisfied by any '#' anywhere on the SECTION line,
      # which let [repos.ostler_fda] through on a comment that says where
      # the tree lives -- nothing at all about why it is unpinned. A
      # comment is not a reason unless it answers the question asked.
      printf '%s' "$line" | grep -qiE '#.*(intentional|unpinned|not pinned|n/a|out of band|see )' \
        || { echo "FAIL: [repos.$repo] sha is empty with no stated reason (v1018-D033)"; bad=$((bad+1)); } ;;
  esac
done <<EOF
$(grep -oE '^\[repos\.[A-Za-z0-9_.-]+\]' "$rel" | sed 's/\[repos\.//; s/\]//')
EOF
[ "$seen" -eq "$present" ] || {
  echo "FAIL: examined $seen of $present [repos.*] sections -- a section name shape is escaping the scan (v1018-D033)"
  bad=$((bad+1)); }
grep -q 'pinned SHA' "$doc" && ! grep -qiE 'VENDOR_MANIFEST|vendor manifest' "$doc" \
  && { echo "FAIL: canonical doc says 'pinned SHA' without naming where it lives"; bad=$((bad+1)); }
[ "$bad" -eq 0 ] || exit 1
exit 0
```

### ~~v1018-D034~~ RETRACTED 2026-08-09 -- both dedupe fixes DID ship in v1.0.18

**RETRACTED. The headline claim below is false and the original text is kept underneath so
the reasoning error stays visible rather than being quietly overwritten.**

Caught by TNM while executing the re-pin, **against his own exoneration** -- D034 had been
recorded as clearing him of "TNM said it was fixed and it shipped broken". Verified
independently here before retracting.

```
cm041/identity_resolver  pinned_sha = 1cf3e163  <- IS `fix(dedupe): gate shareable-ID
                                                    merges on surname agreement`
cm041/assistant_api      pinned_sha = 8377b5f6  <- ONE AHEAD of `fix(memory): stop minting
                                                    a duplicate person on every assert`

$ git log -1 -S'1cf3e163...' -- vendor/VENDOR_MANIFEST.toml
066b5bc  2026-08-07 03:25:47 +0800  fix(vendor): re-vendor the trees carrying every
                                    headline v1.0.16 fix
$ v1.0.18 freshness-ledger commit
d71d84d  2026-08-08 19:20:43 +0800
```

Both pins were set **two days before the cut**. **Both named dedupe fixes shipped in
v1.0.18.**

**Where the reasoning slipped.** The table below reads `identity_resolver | 2026-08-06 |
main ahead by 8`. I generalised staleness from the lag. But 2026-08-06 is the date **of**
the dedupe commit, so being pinned there means **having** the fix. Lag-from-main was used as
a proxy for missing-the-thing-being-looked-for, and it is not one.

**Claim (b) is retracted too.** "identity_resolver (06 Aug) runs against contact_syncer (19
Jul) ... that pairing has never existed on any main branch." Structurally true, materially
irrelevant: the pairing is **deliberate**, recorded in `hold_ack_reason` on
`cm041/contact_syncer`, and the sole delta is a settling-progress wire the manifest chose
not to take because it would give the `contacts` channel a second producer. A recorded
decision was dressed up as an incoherence.

**What survives, on its own evidence:** the cut-freshness gate really was RED on main for
eight days across three cuts (v1018-D029, fixed in CM051 #538). Untouched by this
retraction.

**The consequence matters more than the retraction. D005 is genuinely OPEN.** The 16% was
measured **with** both fixes present. So one of: the fixes do not do what we think; the
fragmentation has a different cause; or the relevant merge decision lives in the frozen
`contact_syncer` tree (`DedupDetector` is there, which makes it worth checking first).
**No re-pin of any CM041 tree until that is established** -- a re-pin with no stated benefit
is churn on a launch cut surface.

**And the gate below was wrong in the same family as D001's and D002's.** It required every
tree sharing a source repo to pin an identical SHA. The manifest **deliberately** violates
that, with a written reason. A gate that fails a correct, documented configuration trains
people to ignore it. Replaced: drift is allowed, **unacknowledged** drift is not.

---

<details>
<summary><strong>ORIGINAL D034 TEXT (2026-08-09 afternoon) -- WRONG, kept for the record</strong></summary>

### v1018-D034 -- the shipped CM041 trees are stale AND incoherent, and D005 was measured blind

**This reframes v1018-D005 and v1018-D011. Do not write more dedupe logic until it is settled.**

The v1.0.18 DMG pins six CM041 trees at **four different dates**, all behind source:

| tree | pinned | main ahead by | verify |
|---|---|---|---|
| cm041/contact_syncer | 2026-07-19 | **13** | full |
| cm041/meeting_syncer | 2026-07-15 | **14** | full |
| cm041/ostler_hygiene | 2026-07-15 | **14** | full |
| cm041/pwg_privacy | 2026-07-15 | **14** | full |
| cm041/identity_resolver | 2026-08-06 | 8 | full |
| cm041/assistant_api | 2026-08-06 | 2 | full |

**Two distinct problems.**

**(a) The dedupe fixes never shipped.** CM041 main gained these on 2026-08-06, eighteen days
after the contact_syncer pin:
```
fix(dedupe): gate shareable-ID merges on surname agreement, not string similarity
fix(memory): stop minting a duplicate person on every assert
Merge PR #107: gate shareable-ID merges on surname agreement
```
So Andy's "16% of wiki People are duplicates" was measured on a box running dedupe code from
19 July, with two fixes for that exact defect merged and undelivered. **D005 has never been
tested against its own fixes.** TNM may well have been right that he fixed it; the cut never
picked it up.

**(b) The pinned set is not a coherent snapshot.** `identity_resolver` (06 Aug) runs against
`contact_syncer` (19 Jul). Those two collaborate on dedupe. That pairing has never existed on
any main branch and was never tested together. Staleness is one bug; **assembled-from-parts is
a second, and it can produce fragmentation neither fix addresses.**

All six are `verify = "full"`, so the cut-freshness gate was meant to catch precisely this. It
was RED and unread for eight days (v1018-D029). **This is the concrete cost of that gate being
dark: six trees drifted up to 14 commits while the alarm was disabled.**

**Correct next action is re-pin and re-measure, NOT a new fix.** Bump the CM041 trees to one
coherent SHA, rebuild, re-run the fragmentation count. Drops -> D005 was a delivery failure.
Does not drop -> we finally have a clean measurement to design against. Either answer beats
another fix written against July code.

**Related, and the reason 12 trees could not be checked at all:** `source_repo` values like
`"$CM041"` and `"$HR015/doctor"` expand from the OPERATOR'S SHELL to LOCAL FILESYSTEM PATHS
(`scripts/_vendor_lib.sh:183` -- `eval printf`). They are not repo URLs. So for 12 of 19 trees
the provenance resolves only on the machine that cut the DMG, and cannot be verified from CI,
from another operator, or by this gate. Same family as D033: a record that reads as
authoritative and cannot be checked.

</details>

```gate id=v1018-D034 expect=0 runs-on=repo
# REPLACED 2026-08-09 alongside the retraction above.
#
# The original required every tree sharing a source_repo to pin an IDENTICAL sha. The
# manifest deliberately violates that -- cm041/contact_syncer is held at f83d5aee with a
# written hold_ack_reason -- so the gate failed a correct, documented configuration. Third
# gate in one day that encoded a wrong conclusion (see D001, D002).
#
# The real invariant is not uniformity. It is that drift must be ACKNOWLEDGED: any
# verify=full tree pinned behind its source main must carry a hold_ack_shas entry. Drift
# nobody has looked at is the failure; drift somebody wrote a reason for is a decision.
cd "${CM051_DIR:?CM051_DIR unset}" || exit 1
man="vendor/VENDOR_MANIFEST.toml"
[ -f "$man" ] || { echo "FAIL: no vendor manifest"; exit 1; }
python3 - "$man" <<'PYGATE'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
bad = 0
for block in src.split("[[tree]]")[1:]:
    def field(name):
        m = re.search(r'^\s*%s\s*=\s*"([^"]*)"' % name, block, re.M)
        return m.group(1) if m else None
    name = field("name")
    if field("verify") != "full" or not name:
        continue
    if field("pinned_sha") is None:
        print("FAIL: %s is verify=full with no pinned_sha" % name); bad += 1; continue
    # Behind-ness is established by the freshness gate; here we only assert that a tree
    # DECLARED behind carries an acknowledgement.
    if re.search(r'^\s*behind_main\s*=\s*true', block, re.M) and not field("hold_ack_shas"):
        print("FAIL: %s pins behind source main with no hold_ack_shas" % name); bad += 1
sys.exit(1 if bad else 0)
PYGATE
```

### v1018-D035 -- a raw participants roster with live email addresses renders on wiki People pages

**PROPOSED BY TNM -- this is Archie's file. Merge, amend or reject; I have not
touched main.** Raising it as a section rather than a comment because the defect
is live and, as of this writing, no gate in this ledger covers it.

D014's old `c` limb was the only thing that ever pointed at prompt scaffolding,
and the note above is right that `^--- Summary Participants` matches nothing on
disk. `c` has since been re-pointed at metadata-only summaries -- a different,
real defect. The consequence is that the scaffolding defect now has **no gate at
all**, and it turns out to be a PII leak rather than a cosmetic one.

Two things the old limb missed, both measured on the founder box 2026-08-10
against `$HOME/Documents/Ostler/Wiki`:

- **The `^` anchor.** On a rendered page the roster sits mid-line inside a
  bullet, after the icon span and the date:
  `- <span class="pw-ic pw-ic-mail"...></span> **10 August 2026** * Email - --- Summary  Participants - ...`
- **The spacing.** The on-disk form is `Summary  Participants` with TWO spaces.
  So the string is not merely "the run-together form from a screenshot" -- a
  form very close to it IS on disk, on three files, and neither the old limb nor
  the new one can see it.

`b` caught exactly one of those three files, and only incidentally: that file
happened to contain `{user_email}`, which `b` matches for unrelated reasons. The
other two carry live third-party addresses and were invisible to every limb.

Root cause is fixed in CM044 (#177, #178) -- two independent ways to switch the
roster scrub off: an unfilled `{user_email}` in the first entry (the scrub
required an address in EVERY entry, so a malformed first entry vetoed the whole
run), and a leading `---` (the anchor was `^\s*`, which does not match `-`).
Both have demonstrated-RED unit guards. Neither is in an image yet, so this gate
is expected to be RED until the wiki-compiler image is rebuilt and re-pinned.

Producer half is a shipped CM048 prompt template that emits its `{token}`
output-format slots verbatim; filed in HR015 BACKLOG (#315), not fixed.

**Measured, with controls, before proposing:**

```
People/*.md examined                 4918     <- 0 here would mean nothing looked at
proposed predicate                      3     <- mum-fairweather.md, robin-fairweather.md, timeline.md
negative control (prose w/ parens)      0
```

```gate id=v1018-D035 expect=0 runs-on=box
W="$HOME/Documents/Ostler/Wiki"
[ -d "$W" ] || { echo "FAIL: $W absent -- a gate that passes because the data is missing is not a gate"; exit 1; }
# Examined-count control. A roster count of 0 is only meaningful if pages were
# actually read; "nothing found" and "nothing looked at" print identically.
n=$(find "$W/People" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
[ "${n:-0}" -gt 0 ] || { echo "FAIL: no People/*.md examined -- nothing looked at, not nothing found"; exit 1; }
# Shape, not formatting: roster label + separator + at least one `name (...)`
# entry whose parenthetical carries an address. Unanchored on purpose -- the
# scaffolding renders mid-line inside a bullet. The address requirement keeps
# this to the PII-bearing form; a roster with no address leaks nothing.
c=$(grep -rlE '(Summary[[:space:]]+)?(Participants|Attendees)[[:space:]]*[-:][[:space:]]*[^,()]+\([^)]*@[^)]*\)' "$W/People/" 2>/dev/null | wc -l | tr -d ' ')
# PROVENANCE. This gate reads RENDERED PAGES, so what it measures is whatever
# compiler last wrote them -- which is NOT necessarily the one the cut ships.
#
# Measured 2026-08-11: this gate went RED on 3 of 4918 pages and the CM044 code
# was correct the whole time. The box's compose pinned
# ostler-wiki-compiler@sha256:099975d3..., whose _PARTICIPANT_ENTRY still
# required an address inside every entry's parens -- the pre-fix form that
# 9163ade replaced on 2026-07-23. install.sh pins 14b5b452..., which strips the
# same input correctly. So a fresh install was never affected; this box was an
# older install whose compose was never re-pinned.
#
# Without this line the RED reads as "the product leaks addresses". With it,
# the operator can tell a stale box from a real defect in one look. Printing
# the digest is not a fix for the attribution problem -- the real fix is to
# assert the STRIPPER'S BEHAVIOUR against the shipped image, which is
# deterministic and attributable. Recorded as the follow-up, not done here.
compose="$HOME/.ostler/docker-compose.yml"
pin="$(grep -oE 'ostler-wiki-compiler@sha256:[a-f0-9]{64}' "$compose" 2>/dev/null | head -1)"
[ -n "$pin" ] || pin="UNKNOWN (no wiki-compiler pin found in $compose)"
[ "${c:-0}" -eq 0 ] \
  || { echo "FAIL: $c of $n wiki People page(s) render a raw participants roster carrying email addresses"; \
       echo "      pages were written by: $pin"; \
       echo "      if that digest is not the one install.sh pins, this is a STALE BOX, not a product defect"; \
       exit 1; }
```


### v1018-D038 -- a reply that looked like a tool call must never be sent as prose

**This is the real D017.** D037 and `ostler-ai/ostler-assistant#292` /
`ostler-ai/ostler-assistant#296` close a genuine, separate
hole: XML-tagged payloads on the shipped channels. They do not touch this one,
and the D017 scope note says so. This row exists so that a green D037 can never
be mistaken for a fixed D017.

**Demonstrated on oa main `cd01cca8`, 2026-08-10.** A probe against the real
`zeroclaw-tool-call-parser`, with both controls in the same run:

```
OBSERVED bare call            calls: 0   text: UNCHANGED   issue: None
  input:  pwg_people(name:"Robin Fairweather")
bare call inside prose        calls: 0   text: UNCHANGED   issue: None
POSITIVE CONTROL malformed    calls: 0                     issue: Some("response resembled
  input:  <tool_call>{"name": "pwg_people", "argum          a tool-call payload but no valid
                                                            tool call could be parsed")
POSITIVE CONTROL well-formed  calls: 1                      issue: None
NEGATIVE CONTROL prose        calls: 0                      issue: None
  input:  I checked your calendar (nothing today).
```

The two positive controls are the point. Without them, `calls: 0, issue: None`
on the observed string is indistinguishable from a probe that never reached the
code -- which is this session's recurring failure and the reason
`feedback_validate_the_probe_before_believing_its_answer` exists. The malformed
control proves the detector runs; the well-formed control proves the parser runs.

**Mechanism, limb 1 -- the detector cannot see this shape.**
`detect_tool_call_parse_issue`
(`crates/zeroclaw-tool-call-parser/src/lib.rs:1433`) fires only on a fixed list
of literal substrings: `<tool_call`, `<toolcall`, `<tool-call`, three
` ```tool ` fence variants, `"tool_calls"`, `TOOL_CALL`, `[TOOL_CALL]`,
`<FunctionCall>`. A bare `name(args)` contains none of them, so it returns
`None`. Same shape of defect as `strip_tool_call_tags`: a literal-tag predicate
answering a question about a tag-free string.

**Mechanism, limb 2 -- and this is the worse half. The detector's answer is
thrown away.** `crates/zeroclaw-runtime/src/agent/loop_.rs:1217` destructures the
tuple returned from the provider call as:

```rust
let (
    response_text,
    parsed_text,
    tool_calls,
    assistant_history_content,
    native_tool_calls,
    _parse_issue_detected,      // <- computed at :1268, never read
    response_streamed_live,
) = match chat_result {
```

The leading underscore is not a style choice, it is the defect. It was born
underscored in upstream commit `4fa47646` (2026-03-05, external contributor) and
has never been read in any commit since. So even a payload the detector DOES
flag is still returned as `response_text` and delivered. `runtime_trace` records
an event and the customer gets the payload. **A guard whose result is discarded
is a log line, not a guard.**

**What the shipped model actually emits matters here.** The 16 GB tier runs
`gemma4:e2b` prompt-guided, not native tool calling, so the emitted call shape is
whatever the model produces. `pwg_people(name:"...")` is ordinary
function-call syntax and there is no strategy for it among the parser's eight
(JSON, XML, MiniMax invoke, XML-attribute, Perl/hash-ref, GLM, GLM-shortened,
FunctionCall).

**The fix has two limbs and they are not the same size. Land B first.**

- **Limb B, contain (small).** Stop discarding the signal. Read it, retry the
  turn ONCE with a corrective instruction, and if the retry is still suspect send
  a fixed fallback sentence -- never the payload. This alone closes the
  customer-visible leak.
- **Limb A, recognise (larger).** Add `parse_bare_function_call_syntax` to the
  parser crate returning CANDIDATES, and filter them in `run_tool_call_loop`
  against `tools_registry` (in scope at that point, signature line 825). A
  candidate is promoted to a real call only when its name EXACTLY matches a
  registered tool and it spans the whole trimmed reply. That registry filter is
  what makes this safe where a bare `\w+\(.*\)` regex would not be: it is why
  `I checked your calendar (nothing today).` cannot match.

**Known limit, stated rather than hidden:** an unregistered name (a model typo
such as `pwg_peple(...)`) is filtered out and will still ship. Suppressing every
parenthesised identifier instead would mean the assistant could never discuss
code. This is the deliberate trade, not an oversight.

**Scrubbing alone is the wrong answer** and must not be the fix. It turns a wrong
answer into a blank one: the customer asked about a person, the assistant tried
to look them up, and scrubbing would leave them with silence. Recognition makes
the product work; containment is the floor under it.

**What this gate can and cannot prove.** It reads source on `oa` main and asserts
the three invariants below. That is NECESSARY and NOT SUFFICIENT -- source
presence is not behaviour. Sufficiency is the named cargo test, which oa CI now
runs on push as well as PR since `ostler-ai/ostler-assistant#293`. Two systems,
each asserting only what it
can actually reach. The test path and the symbol name below are **load-bearing**:
they are mandated in the spec handed to TNM, so the gate and the spec agree by
construction rather than by luck.

```gate id=v1018-D038 expect=0 runs-on=repo
GH="${GH_BIN:-gh}"
OA_REPO="${OA_REPO:-ostler-ai/ostler-assistant}"

# THE SUBJECT IS THE PIN, NEVER `main`.
#
# This read `OA_REF="${OA_REF:-main}"` until 2026-08-11 and was GREEN on that
# basis while the daemon the cut actually pins was RED on all three limbs below.
# `main` is the one value that must not be a fallback here: it is always
# readable, always the most-fixed tree, and therefore always the flattering
# answer. Precedence is explicit-override, then pin, then REFUSE.
OA_REF="${OA_REF:-${OSTLER_PIN_OA:-}}"
[ -n "$OA_REF" ] || {
	echo "CANNOT RUN: no daemon pin. Run with --cut <version> so DAEMON_COMMIT"
	echo "            from that cut.env binds OA_REF, or set OA_REF= explicitly"
	echo "            to measure a ref on purpose. This is not a pass."
	exit 97
}
echo "subject: $OA_REPO@$OA_REF"

# ostler-ai/* is readable only by the ostler-ai gh account. A wrong-account read
# comes back 404, which is indistinguishable from "the invariant holds" -- so
# resolve the account token first and fail LOUDLY, never silently, on a bad read.
OA_TOKEN="$(gh auth token --user ostler-ai 2>/dev/null || true)"
[ -n "$OA_TOKEN" ] || OA_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[ -n "$OA_TOKEN" ] || { echo "CANNOT RUN: no gh token for ostler-ai. This is not a pass."; exit 1; }

read_oa() {
  GH_TOKEN="$OA_TOKEN" $GH api "repos/$OA_REPO/contents/$1?ref=$OA_REF" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null
}

LOOP="crates/zeroclaw-runtime/src/agent/loop_.rs"
PARSER="crates/zeroclaw-tool-call-parser/src/lib.rs"
TESTF="crates/zeroclaw-tool-call-parser/tests/bare_tool_call_never_reaches_customer.rs"

loop_src="$(read_oa "$LOOP")"
parser_src="$(read_oa "$PARSER")"

# Examined-count control. "Zero violations" means nothing if zero bytes were read.
loop_n=$(printf '%s' "$loop_src" | wc -c | tr -d ' ')
parser_n=$(printf '%s' "$parser_src" | wc -c | tr -d ' ')
echo "read $LOOP: ${loop_n} bytes"
echo "read $PARSER: ${parser_n} bytes"
[ "${loop_n:-0}" -gt 100000 ] || { echo "CANNOT RUN: $LOOP read as ${loop_n} bytes; it is ~280k. Read failed. This is not a pass."; exit 1; }
[ "${parser_n:-0}" -gt 20000 ] || { echo "CANNOT RUN: $PARSER read as ${parser_n} bytes. Read failed. This is not a pass."; exit 1; }

fail=0

# (1) The parse-issue signal must not be discarded.
#
# COMMENTS ARE STRIPPED FIRST, AND THAT IS THE POINT. This predicate matches an
# IDENTIFIER, so it cannot tell code from prose ABOUT code. TNM's explanatory
# comment on oa #299 originally contained the literal `_parse_issue_detected`
# while describing the very binding it had just removed -- which would have held
# this gate RED for a purely cosmetic reason, against a correct fix.
#
# That is the D025 finding wearing the opposite costume: there a name-based
# predicate under-reported (the name was absent, the BEHAVIOUR present); here it
# would over-report (the name present in prose, the behaviour already fixed).
# Same root error both times -- asserting on a rendering rather than on the thing.
#
# Stripping `//` to end-of-line covers `//`, `///` and `//!`. It cannot cause a
# FALSE GREEN for this predicate: a real binding (`let _parse_issue_detected =`)
# sits BEFORE any trailing comment on its line and survives the strip.
loop_code="$(printf '%s' "$loop_src" | sed 's://.*::')"
# Control: a strip that ate the file would make every following check vacuous.
code_n=$(printf '%s' "$loop_code" | wc -c | tr -d ' ')
[ "${code_n:-0}" -gt 50000 ] || { echo "CANNOT RUN: comment-strip left ${code_n} bytes of $LOOP; it should stay ~200k+. This is not a pass."; exit 1; }
echo "stripped $LOOP to ${code_n} bytes of code (comments removed)"
if printf '%s' "$loop_code" | grep -q '_parse_issue_detected'; then
  echo "FAIL(1): loop_.rs still binds the parse-issue result to _parse_issue_detected -- computed and never read"
  fail=1
else
  echo "ok(1): parse-issue result is no longer bound to a discarded name (checked against code, not comments)"
fi

# (2) A registry-filterable bare-call recogniser must exist.
if printf '%s' "$parser_src" | grep -q 'fn parse_bare_function_call_syntax'; then
  echo "ok(2): parse_bare_function_call_syntax present"
else
  echo "FAIL(2): no parse_bare_function_call_syntax in the parser crate -- a bare name(args) reply is still unrecognisable"
  fail=1
fi

# (3) The regression test must exist AND must use the string actually observed,
#     not a toy. A test over an invented input proves nothing about this defect.
test_src="$(read_oa "$TESTF")"
if [ -z "$test_src" ]; then
  echo "FAIL(3): $TESTF absent -- no regression test pins this defect"
  fail=1
elif printf '%s' "$test_src" | grep -q 'pwg_people(name:'; then
  echo "ok(3): regression test present and uses the observed string"
else
  echo "FAIL(3): $TESTF exists but does not contain the observed string 'pwg_people(name:'"
  fail=1
fi

[ "$fail" -eq 0 ] || { echo "GATE RED: the real D017 is still open"; exit 1; }
echo "GATE GREEN (source invariants only -- behaviour is proved by oa CI running $TESTF)"
```

### v1018-D018 -- the bisect target is dead, and that is not the same as the recollection being wrong

**This row is ungated by design and stays that way. What changes is the SHAPE of
the work the plan has budgeted for.**

`v1.0.18/DEFECTS_LEDGER.md:823` records the basis for a bisect:

> **REGRESSION not gap (Andy 2026-08-09 ~02:10 HKT):** Andy confirms cross-channel
> recollection was definitely working a couple of weeks ago ... Bisect problem,
> not architecture problem.

`V1019_PLAN.md:31` then budgets *"buffer for D018 memory-regression bisect
(unknown-width window -- could be 1 day, could be 3)"*.

**Measured at source. The session-scoping filter has no regression to find.**

```
crates/zeroclaw-memory/src/sqlite.rs -- FOUR commits in its entire history,
last touched 2026-04-10 (four months ago)

occurrences of  session_id.as_deref() != Some(
  470ff7ab  crate extraction   5
  14799a7d  last touch         5
  main today                   5
```

Identical at three points in history. A bisect over the last twenty days of
`oa/main` cannot find a change in a file that has not changed since April.

**What that does and does not establish, stated precisely because the difference
is the whole point.** It establishes that **this** mechanism did not regress. It
does **not** establish that cross-channel recall never worked. If it did work,
it worked by some other path, and that path has to be NAMED before a bisect can
be scoped -- otherwise the window is unbounded and the budget is a guess.

So the correction is not "Andy misremembered". It is:

- **The bisect as scoped is dead.** Session scoping is original, deliberate,
  tested behaviour, asserted by `sqlite_purge_session_preserves_other_sessions`
  (line 2168). There is no commit to find.
- **The open question is what mechanism the recollection refers to.** That is one
  question for Andy, not one to three days of bisecting.
- **Four production sites, not one.** `recall()` at 751 and 825, `list()` at 913
  and 927. A fix relaxing only `recall()` leaves `list()` scoped and the defect
  half-alive.
- **The obvious fix is wrong.** Do not delete the filter. Purge-scoping is a
  deliberate tested property; recall-scoping is the defect. They share a
  predicate and must be separated before either moves.

**Knock-on, and it is the reason this is written here rather than left in a task.**
`v1018-D012b`'s V1019 cell reads *"Verified as part of PR #10 D018 bisect scope
(same tool-binding surface); no separate PR unless bisect finds a distinct
defect."* That row's verification is parented on a bisect that will not happen and
a PR that does not exist -- `oa #10` is *"cron-delivery: piece E"*, merged
2026-05-02, unrelated. **D012b is therefore unverified by a route nobody will
walk**, and it currently claims `fixed_in_v1.0.19`. It needs its own acceptance or
its own owner.

Acceptance for D018 is unchanged and already right: a real-box two-channel probe,
assert on chat, query on iMessage. It is not gated here because there is still
nothing to gate.

**MECHANISM NAMED, 2026-08-10 (Archie).** The paragraphs above ask for the path to
be NAMED before a bisect can be scoped. It is now named, at source, and it is
architecture rather than a regression -- which settles the bisect question without
one being run.

**The session key is a FILE PATH, and the same value is used for both write and
read.** `loop_.rs:2479`:

```rust
let memory_session_id = session_state_file.as_deref().and_then(|path| {
    let raw = path.to_string_lossy().trim().to_string();
```

That one value is passed to **`store()` at 2540** and to **`build_context()` at
2550**, which reaches `recall()` through `memory_loader.rs:47`, which passes it
straight into the four scoping sites. `agent.rs` does the same at all four of its
`load_context` sites via `self.memory_session_id`, whose default is `None`
(`agent.rs:118`).

So a memory is written under the session-state-file path of the channel that
created it, and read back under the session-state-file path of the channel
asking. **Two channels never share a session state file, so neither can ever see
the other's memories.** Cross-channel recall was not lost. It was never reachable
under this design.

**The filter's exact semantics, which decide the fix shape:**

```
session_ref = None       -> the `if let` never binds, NOTHING is filtered
session_ref = Some(sid)  -> keep only exact matches, and a NULL-session row
                            is SKIPPED, because None != Some(sid)
```

**Measured on the founder box, 2026-08-10.** 19 memories total, of which **15
carry a NULL session_id**; the remainder are scoped to per-conversation keys of
the shape `imessage_<handle>_<handle>` plus one UUID. Handle values are withheld
here deliberately: they are operator PII and this file is tracked.

That 15 is the sharper finding. **A NULL-session memory is invisible to every
scoped read**, visible only to an unscoped one. So most of what is stored on that
box cannot be retrieved by any caller that sets a session id.

**What this does to the plan.** `V1019_PLAN.md:31` budgets one to three days of
bisect. That budget can be released: there is no commit to find, and the question
it was meant to answer is answered. What replaces it is a scoping decision --
whether memory should be keyed on the session-state-file path at all, and whether
`recall()` should read across sessions while `list()` and purge stay scoped. That
is design work, and much smaller than three days.

**Still not a status change, and the acceptance below stands.** Nothing here
demonstrates the customer-visible behaviour, only the mechanism that produces it.
I did not run the two-channel probe, because it would send real iMessages from
Andy's account.

## Gates deferred pending fix design

These MUST-FIX-NEXT entries have no runnable gate yet because the fix shape is still open. **They are listed deliberately so the parser sees them and the pipeline refuses to treat their absence as a pass.** Each needs a gate before v1.0.19 tags.

| ID | Why no gate yet | Owner |
|---|---|---|
| v1018-D008 | Needs a cross-component contract check (lease writer ↔ wiki-compiler reader) rather than a static probe — see `FIX_SPEC_D008.md` §5 | TNM |
| v1018-D018 | Cross-channel memory assertion needs a two-channel behavioural probe (assert on chat, query on iMessage) | Archie |
| v1018-D021 | Throughput floor requires empirical calibration on a real mailbox before a number can be defended | TNM |
| v1018-D022 | p50/p90 latency measurement belongs in the behavioural gate harness, not a standalone script | TNM (behind D003 contract) |
| v1018-D024 | Doctor vendor-parity check depends on the `VENDOR_ONLY.tsv` design landing first | TNM |
| v1018-D015 | Design-judgment defect — needs Andy's multi-viewport sign-off, not a mechanical assertion | Andy |
