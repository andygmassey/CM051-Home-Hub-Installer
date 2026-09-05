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

## WALKS

**What this is.** The register of what happened to each cut after it shipped.
`bin/rollforward_gate.sh --require-walk-closure --cut <tag>` REFUSES a cut
unless every cut directory from `walk_horizon` up to that tag has a row here.
Wired in CM051 `.github/workflows/cut.yml` (the shipping path, via the vendored
copy) and in OS003 `bin/cut.sh preflight` (the operator path). HR015 task 867,
limb 3, OS003 #128.

**Why it exists.** Until 2026-08-23 this file carried no row for any cut after
v1.0.18, and the claim check reported `rc=0, 0 unproven fixed-claims across 28
gate(s)` while we were cutting v1.0.41. That green was not a statement that walk
closure held. It was a statement that there was nothing left to check. A ZERO
DENOMINATOR READS AS SUCCESS, and it read that way in the one register whose job
is stopping a defect riding forward.

**Statuses.** `closed` (walked, and every finding listed below has a `###`
section in this file), `deferred` (findings exist and are deliberately not
blocking), `not_walked` (nobody walked it). The last two REQUIRE a named
approver, the same rule `gates/reconcile_gates.sh` already applies to gate
waivers: an anonymous waiver is one nobody signed.

**And the status is DERIVED, not taken on trust.** CM051 #978 writes
`walks/<version>.tsv` after driving the box-walk probes against a real installed
box, which is the only RUNTIME evidence in the release pipeline: everything else
measures the artefact, and all of it passes on a DMG that installs to a broken
machine. Two registers of one fact is this estate's signature failure, so where
a record exists it decides which statuses are LEGAL:

| walk record | statuses this table may carry |
|---|---|
| verdict `CLEAN` | `closed` only. It was walked and it was clean; `not_walked` is a false statement contradicted by an artefact. |
| verdict `FAILED` or `PARTIAL` | `closed` or `deferred`. Not `not_walked`. |
| no record for that cut | `deferred` or `not_walked`. **`closed` is REFUSED** -- a walk claimed closed with nothing written by the walker is the silence this mechanism exists to refuse. |
| no `walks/` directory at all | any, and every row is labelled `UNAVAILABLE` on the verdict line. OS003 has no `walks/`; CM051, where the shipping cut runs this gate, does. A reader must be able to tell a DERIVED status from one taken on trust, so the output says which. |

The row still carries the approver and the findings, because a record cannot
know either. What it can no longer do is CLAIM a walk that left no trace, or
deny one that did.

**findings** is a space-separated list of the section ids for that walk, or the
literal `none`. The gate requires it to EQUAL the set of `### vNNNN-Dxxx`
sections in this file for that cut, so a finding the row forgot fails and a
finding with no section fails. That is what stops closure being a word someone
types. Retracted sections (`### ~~vNNNN-Dxxx~~`) are excluded: a retraction is a
finding withdrawn.

**walk_horizon** is the first cut this table accounts for. Below it, nothing is
claimed. From it upward, nothing may be silent. It is set to v1.0.41 because
that is the first cut for which a human statement exists; writing rows for
v1.0.24 through v1.0.40 would be fabricating history nobody measured, which is
worse than admitting the gap. **Raising the horizon to make the gate pass is
forbidden and the gate refuses a horizon that sits above every cut**, because
otherwise the way to green this register is to edit one line.

walk_horizon: v1.0.41

| cut | walked_on | status | approver | findings |
|---|---|---|---|---|
| v1.0.41 |  | not_walked | Andy | none |
| v1.0.42 |  | not_walked | Andy (relayed 2026-08-23, see below) | v1042-D001 v1042-D002 v1042-D003 v1042-D004 |
| v1.0.43 | 2026-08-24 | deferred | TNM (2026-08-24, under Andy's standing instruction to drive to the cut) | v1043-D001 v1043-D002 v1043-D003 |
| v1.0.44 | 2026-08-24 | closed | Andy (walked on hardware; run header 2026-08-24T10:10:59Z) | v1044-D001 v1044-D002 v1044-D003 v1044-D004 v1044-D005 v1044-D006 |
| v1.0.45 |  | not_walked | A2 (ARTEFACT MEASURED 2026-08-26, NEVER INSTALLED. Not walked because it CANNOT be: the DMG bricks on first run, v1045-D001. There is no walks/v1.0.45.tsv and there should not be one -- no walker got past Gatekeeper.) | v1045-D001 |
| v1.0.46 | 2026-08-26 | deferred | ORM walked the artefact 2026-08-26T03:08Z with scripts/walk_dmg.sh: PASS 5, FAIL 2, CANNOT-RUN 1, VERDICT NO_GO. Deferred (not closed) by A1 under Andy's standing instruction to drive to a cut: the root cause is FIXED on CM051 main c196c1e0 and rides v1.0.47, but it is in NO artefact, so closing would be true about the repo and false about the DMG. | v1046-D001 v1046-D002 v1046-D003 |
| v1.0.47 | 2026-08-26 | deferred | ORM walked the artefact 2026-08-26 with scripts/walk_dmg.sh; arm 8b (#1092) imports an UNSEEDED product module and takes .pyc 1448 -> 1449 with codesign rc=1, VERDICT NO_GO. Deferred (not closed) by A2 under Andy's standing instruction to drive to a cut: the root cause is FIXED on CM051 main 7857e00c (#1093) and rides v1.0.48, but it is in NO artefact, so closing would be true about the repo and false about the DMG. | v1047-D001 |
| v1.0.48 | 2026-08-27 | deferred | Archie walked the artefact on the walk box (box_fp 9b6a0022a46780ac), record at walks/v1.0.48.tsv, version_source measured(CFBundleShortVersionString) 1.0.48 / 4800 read via plutil ON THE BOX. VERDICT FAILED, qa_exit 1: phase 1 10 pass / 8 fail / 2 cannot-run of 20, phase 2 cut manifest 27 pass / 9 fail / 4 skip of 42. THE CUT'S OWN JOB PASSED: app_signature_survives_first_run is GREEN on the artefact, 1887 .pyc all unchecked-hash, corpus byte-identical 8644c1b53ca5, 353 product .py with 0 uncovered, live-trigger control fired (1 .pyc written OUTSIDE the bundle), 0 files added to a writable copy by importing its own product modules, codesign clean on BOTH verbs. That closes v1047-D001's ADD limb, measured on the artefact rather than in the source. DEFERRED (not closed) BECAUSE OF WHAT THE WALK COULD NOT SEE, NOT BECAUSE OF THE EIGHT FAILURES: the walk drag-copies the .app and never launches it, so install.sh did not run and the eight phase-1 failures describe an AUG 25 install of Ostler 0.7.1, not this DMG (see v1048-D001). Re-attribution independently confirmed by A2 via version strings and by mtimes with a control that moved. | v1048-D001 |
| v1.0.49 |  | not_walked | Archie (2026-08-28). TAGGED d38f3320 -> a612a480 and NEVER INSTALLED BY ANYONE. Not walked, and deliberately not walked. Andy's launch hold (#551) landed over the #550 multi-account store exposure before any walker reached it, and the public download is still v1.0.41 (unchanged since 2026-08-22), so no customer and no operator has run this artefact. MEASURED: zero of the seven #550 merges are ancestors of a612a480. Walking it would therefore measure a tree that PREDATES every fix it would be walked to demonstrate -- a real walk producing a true result about the wrong subject, which is worse than no walk because it would read as evidence. There is no walks/v1.0.49.tsv and there should not be one. SUPERSEDED BY v1.0.50, which carries the ERR-06 Qdrant credential fix (#1226), the wiki-compiler Qdrant key (#1228), and the CM044 v0.1.28 image re-pin (#1229). The walk that matters is v1.0.50's and it has not happened either. | none |
| v1.0.50 | 2026-08-29 | deferred | Archie 2026-08-30. Walk record walks/v1.0.50.tsv exists with verdict FAILED and qa_exit 1, so the rules table above admits closed or deferred and REFUSES not_walked. DEFERRED, not closed: four of the eight findings are fixed on CM051 main (d4ee9de2) and ride v1.0.51, but they are in NO artefact, so closing would be true about the repo and false about the DMG. The other four are open. THE HEADLINE COUNT OVER-STATES PRODUCT DEFECTS, measured not softened: fail 7 contains TWO probes with ONE cause (app_signature_survives_first_run and installed_bundle_seal_intact are both the cm052 pip build-in-place breaking the code seal) and ONE probe that was not measuring the product at all (people_seed_and_retrieval called Qdrant with no credential, got 401, and reported a collection missing that demonstrably exists). So seven recorded failures describe five distinct subjects, one of which is the instrument. Nothing here is measured closure: 7 recorded, 4 predicted to clear, 0 measured. A merge cannot clear a row in a frozen record, and walks/v1.0.50.tsv will read fail 7 permanently. The next walk is of a DIFFERENT artefact with a different sha256, which is #931 working as designed. THE ROW NOW LISTS NINE IDs WHILE THE PROSE ABOVE SAYS EIGHT, AND BOTH ARE CORRECT: v1050-D001 through D008 disposition the **fail** bucket, and v1050-D009 dispositions the **cannot_run** bucket, which nothing in this file had ever adjudicated. The row previously omitted D009 while the finding section existed, so the registry and the row disagreed by exactly one finding and walk closure went RED -- caught by the gates-only dry run 33299809685 rather than by spending a version on a tag. | v1050-D001 v1050-D002 v1050-D003 v1050-D004 v1050-D005 v1050-D006 v1050-D007 v1050-D008 v1050-D009 |
| v1.0.51 | 2026-08-29 | deferred | Archie 2026-08-30. Walk record walks/v1.0.51.tsv exists with verdict FAILED and qa_exit 1, so the rules table above admits closed or deferred and REFUSES not_walked. It is the FIRST record in this project's history whose artefact_sha256_source is measured(...) rather than asserted -- shasum of OstlerInstaller-1.0.51.dmg taken on the walked box -- so for the first time a walk record can bind a version to a build rather than to a claim. Andy installed this artefact on hardware (OstlerInstaller.app 1.0.51, ~/.ostler 1.1 GB) and 12 of 21 probes pass. DEFERRED, not closed, and the four failures are FOUR DIFFERENT KINDS OF THING, which is why none of them is being called a product regression without saying which: D001 is a real customer-visible defect whose fix cannot reach a customer without a wiki-image rebuild that TNM measured is NOT in the v1.0 path; D002 is an EXPECTED red that Andy explicitly decided to defer to v1.0.1; D003's recorded `broken` was my own packaging and is cleared on the box, while its customer-visible half survives with MY explanation of it refuted by its own decisive test; D004 I did not investigate at all and it is recorded as unexamined rather than dispositioned. ZERO of these four are measured closure. The next walk is of a DIFFERENT artefact with a different sha256, which is #931 working as designed. | v1051-D001 v1051-D002 v1051-D003 v1051-D004 |
| v1.0.52 | 2026-08-30 | deferred | Archie 2026-09-01 (UTC; the record's walked_at is 2026-08-30T15:22:57Z). Walk record walks/v1.0.52.tsv exists with verdict FAILED and qa_exit 1, so the rules table above admits closed or deferred and REFUSES not_walked. artefact_sha256_source reads measured(...), so this is the second record in this project's history that binds a version to a BUILD rather than to a claim. DEFERRED, not closed. THIS ROW CARRIES TWO POPULATIONS AND THEY MUST NOT BE CONFLATED: the 21-probe machine walk (12 pass / 7 fail / 2 cannot-run) and ANDY'S OWN HAND WALK of the same artefact, which found six customer-visible defects the probe suite does not measure at all. D001-D006 are Andy's six; D007-D010 are the recorded failed probes his six do not already disposition; D011 dispositions the cannot_run bucket, which nothing would otherwise adjudicate. FAIL WENT 4 -> 7 AND THAT IS NOT THREE NEW DEFECTS. Measured against walks/v1.0.51.tsv: two of the three (no_person_holds_two_contact_cards, people_stores_reconcile) were CANNOT-RUN on v1.0.51 and merely became measurable, while exactly ONE (no_unexpected_egress) moved pass -> fail and is a genuine new red. THE ARITHMETIC CLOSES AS A CONTROL: people_count_agreement moved cannot_run -> pass (+1) against no_unexpected_egress's pass -> fail (-1), which is why pass reads 12 on BOTH records -- had my reading of the delta been wrong, that number would not have reconciled. THREE OF ANDY'S SIX WERE MARKED COMPLETED IN THE TASK REGISTER WHILE BROKEN and he found them still broken on the box; closing this row would be the third statement of the same false claim, which is precisely why the status is deferred. ONE of the eleven (D002) has a fix verified inside a signed artefact, and even that is not walked. ZERO are measured closure. | v1052-D001 v1052-D002 v1052-D003 v1052-D004 v1052-D005 v1052-D006 v1052-D007 v1052-D008 v1052-D009 v1052-D010 v1052-D011 |
| v1.0.53 |  | not_walked | Archie 2026-09-02, filed RETROSPECTIVELY to close a gap in this register: v1.0.54 and v1.0.55 both had rows while v1.0.53, which died the same way, had none. Two of three refused tags recorded reads to a later reader as 'v1.0.53 never happened', and the version sequence 52 -> 54 invites exactly that inference. It did happen. TAGGED at 8f66b632 on 2026-08-30T18:10:50Z and REFUSED AT PREFLIGHT with four failures, every one a condition of the tree AT THAT COMMIT: cuts/v1.0.53/cut.env absent, cuts/v1.0.53/MUST_CONTAIN.tsv absent, walk closure missing a v1.0.52 rollforward row, and gui/project.yml still reading MARKETING_VERSION 1.0.52. 🔴 BORN DEAD, WHICH IS STRONGER THAN 'WENT STALE'. Fixing any of the four requires a NEW COMMIT, so main necessarily moves PAST the tag, and the tag keeps pointing at a tree that can never satisfy the gates. Re-running against it fails identically, forever. This is the origin of the invariant the two rows below cite: A CUT TAG MUST BE CREATED AFTER EVERY CONDITION IT WILL BE JUDGED ON. Task #905 had recorded a weaker version of it ('the tag goes stale on every prerequisite merge'), which reads as a race that can be lost; it is not a race. Tagging first makes the tag unsatisfiable WITH CERTAINTY, because the version bump preflight demands is itself a commit and no commit can precede the tag that needs it. PUBLISHED NOTHING -- no release object, no bytes, no artefact. THE REF IS NOT DELETED AND MUST NOT BE: it truthfully records a tree that was tagged and refused, and force-repointing it would have made ONE VERSION NAME TWO TREES, which is the two-artefacts-one-version class this project filed against itself the same night. Versions are cheap; a version that names two trees is not. ABANDONED, recorded, not reused. | none |
| v1.0.54 |  | not_walked | Archie 2026-09-01. TAGGED fbdbf00e -> 42464845 at 17:46:14Z and NEVER BUILT. There is no artefact, so there is no walks/v1.0.54.tsv and there should not be one. THIS IS A DIFFERENT DEATH FROM v1.0.53 AND THE DISTINCTION IS THE POINT. v1.0.53 was refused at PREFLIGHT on four conditions of the tree at its own commit, so it was born dead and no re-run could ever have saved it. v1.0.54's preflight PASSED -- the same gate that refused v1.0.53 four times went green -- and the cut job then failed inside the build at `make check-orphans`, which is NOT a preflight gate. Two OPEN CM051 PRs were neither merged nor deferred: #1305 (TNM's usage-journal producer for the shipping ostler_fda) and #1300 (my own walk-record harness_commit binding). Both are genuinely unready, MEASURED not asserted, on a latest-check-run-per-name conclusion histogram: #1305 2 failing of 66, #1300 4 failing of 36. NO RELEASE OBJECT, no bytes, nobody installed it. THE GATE OFFERED A GREEN THAT WAS REFUSED, and the reason is recorded here so nobody takes it later: check-orphans resolves its shipping ref as `origin/main` and reads LIVE PR state at BUILD time, so merging those two PRs to main would have turned it green while the DMG -- built from the TAG -- still did not contain them. That is the gate passing on a premise ('origin/main is what we ship') that is false for any tag which is not main's head, and taking it would have shipped an artefact the gate believed complete. Deferral was chosen instead because the deferral file is read from the TREE, which makes it unreachable for v1.0.54 for exactly the v1.0.53 reason and forces a new version rather than a quiet re-run. SUPERSEDED BY v1.0.55, which carries the IDENTICAL payload -- main was still AT 42464845 when this died, so v1.0.55's tree is v1.0.54 plus two written deferrals and its own cut records -- and disposes of both PRs through cut-deferrals.yaml, the mechanism this gate names itself. | none |
| v1.0.55 |  | not_walked | Archie 2026-09-02. TAGGED a44621837a5f at commit 29d3c326 and NEVER BUILT to an artefact. No walks/v1.0.55.tsv exists and none should. THIS IS A THIRD DISTINCT DEATH AND THE PROGRESSION IS THE FINDING, because each version died at a gate the previous one never reached. v1.0.53 was refused at PREFLIGHT, born dead on four tree conditions at its own commit. v1.0.54's preflight PASSED and it died IN-BUILD at check-orphans on two open PRs. v1.0.55's preflight passed TWICE and it died IN-BUILD at check-freshness, one target further along. THE GATES RUN IN SERIES INSIDE THE BUILD, AFTER SIGNING CREDENTIALS ARE IMPORTED, so there is no single pre-tag sweep that can answer 'will this cut survive' -- each version buys exactly one gate's worth of new information, which is why four versions have been spent to walk four gates. ATTEMPT 1 died at check-pr-age on PR AGE, not on PR content. ATTEMPT 2, after that was cleared, died at check-freshness on three stale pins: vendor:cm041/identity_resolver, wiki:wiki-compiler and wiki:wiki-site. 🔴 THE LIVE-READ VERSUS TREE-READ DISTINCTION IS WHAT DECIDED THE COST, and it is recorded because it is not obvious from the gate names. check-orphans and check-pr-age read LIVE GitHub state at build time, so CLOSING a PR clears them with no new version -- which is how attempt 2 was bought for free. check-freshness's remedy is a hold_ack or a re-pin, both of which live in the TREE, so main necessarily moves past the tag and the tag becomes permanently unsatisfiable. That is the v1.0.53 mechanism recurring at a later gate, and it is what forces v1.0.56. ⚠️ PARTLY SELF-INFLICTED, RECORDED AS SUCH: two of the three stale pins were advanced by our own merges earlier the same night (CM041 #135, CM044 #266). Merging upstream fixes INSIDE a cut window advances the live HEADs that the pins are measured against, so the cut's own inputs went stale under it. Merging upstream during a cut is not free. AND A STALE LOG WAS READ BEFORE THIS WAS UNDERSTOOD: a re-run mints a NEW job id, and the FIRST attempt's id had been hardcoded into both the monitor and the query, so attempt 1's failure was initially read as attempt 2's. The failing STEP list happened to be identical; the CAUSE was not. Corrected by asking for /jobs?filter=latest. v1.0.55 PUBLISHED NOTHING -- no release object, no bytes, no artefact, nobody installed it. The ref is NOT deleted, because it truthfully records a tree that was tagged and refused, and repointing a version name at a second tree is the one thing this project has filed against itself. ABANDONED, recorded, not reused. | none |
| v1.0.56 |  | not_walked | Archie 2026-09-02. TAGGED f04bf0a3 at commit c3b23919 and NEVER BUILT. No artefact, so no walks/v1.0.56.tsv and there should not be one. 🔴 THIS ONE IS A REGRESSION IN THE SEQUENCE, NOT PROGRESS, AND THAT IS THE HONEST READING. v1.0.53 was refused at PREFLIGHT; v1.0.54 got past preflight and died at check-orphans; v1.0.55 got past preflight TWICE and died at check-freshness. v1.0.56 went BACKWARDS: it died at PREFLIGHT, on two steps the three previous versions had all cleared. So the tidy story that each version buys one gate's worth of information is FALSE for this one. It bought none of that. It bought a lesson about where the gate reads from. BOTH FAILURES WERE MINE AND THEY ARE THE SAME ERROR IN TWO DIRECTIONS: (1) 'BOM_PIN records no hash for cuts/v1.0.56/MUST_CONTAIN.tsv -- an unpinned vendored copy is a fork nobody declared'. I authored that BOM directly in CM051, which is the VENDORED side, and never ran scripts/sync_cut_bom.sh; the canonical BOM lives in OS003 and the sync is what writes cuts/BOM_PIN. (2) 'v1.0.55 NO ROW'. I wrote the v1.0.55 row HERE in OS003, opened a PR for it, and never synced it into the VENDORED cuts/DEFECTS_ROLLFORWARD.md that CM051's gate actually reads. THE GATE READS THE TREE IT IS CUTTING. Canonical is not vendored; merged is not delivered. I have written that sentence about other people's work and then made both halves of it myself inside one hour. ⚠️ AND IT WAS FREE TO AVOID. cut.yml declares a gates-only workflow_dispatch: contents:read, no signing step, no notarisation, and scripts/dry_run_cut_checks.sh ends by ASSERTING no DMG and no exported artefact. It runs the same preflight gates. Running it would have surfaced both failures at zero cost and without spending a version. I did not run it. THE RULE THAT FOLLOWS IS NOT A PREFERENCE: NEVER TAG WITHOUT A GREEN DRY RUN. The v1.0.50 row already records a defect caught 'by the gates-only dry run rather than by spending a version on a tag', so the mechanism was not only available, it was documented in this very file as having worked before. PUBLISHED NOTHING -- no release object (verified 404 on the tag), no bytes, no artefact, nobody installed it. The ref is NOT deleted: it truthfully records a tree that was tagged and refused, and repointing a version name at a second tree is the one thing this project has filed against itself. ABANDONED, recorded, not reused. SUPERSEDED BY v1.0.57, which carries the IDENTICAL payload plus the registry sync and the BOM pin. | none |
| v1.0.57 | 2026-09-02 | deferred | Archie 2026-09-02. THIS IS THE FIRST ARTEFACT IN THIS SEQUENCE THAT WAS CUT, PUBLISHED, INSTALLED ON A FRESH macOS ACCOUNT AND WALKED. Four versions before it died at gates (v1.0.53 preflight, v1.0.54 check-orphans, v1.0.55 check-freshness, v1.0.56 preflight again) and produced no bytes anybody ran. v1.0.57 produced bytes and somebody ran them: OstlerInstaller-1.0.57.dmg, 70,895,668 bytes, sha256 f01f7ec1 matching the published SHA256SUMS AND the copy on the box, installed by Andy on the Studio under archie5 (uid 505) on a machine verified clean beforehand -- 0 of 12 contaminant ports with the :22 control firing, both /Applications bundles absent, no ~/.ostler. THE WALK PAID FOR ITS VERSION, which is the whole argument for cutting. 🔴 AND IT FOUND A1, WHICH NO GATE HAD EVER CAUGHT. Read verbatim off the installed box: sys.path.append("/tmp/ostler-prelaunch-2026/lib"). The store-auth .pth had the STAGING path frozen into it, so the import failed at EVERY python startup, for ever, on every install; python printed 'Remainder of file ignored', OSTLER_SECRETS_DIR was never defaulted, cm059-editor 401d hourly and the Front Page never populated. EVERY OBVIOUS CHECK PASSES ON THAT DEFECT -- the .pth was present, the module was present and correctly installed at <final>/lib, only the path INSIDE was wrong -- which is exactly why no source-presence gate had seen it through five cuts. DEFERRED, NOT CLOSED, and the reason is the standing one: D001 and D002 are FIXED on CM051 main (#1316 21a63078, #1315 0d104ebc) and ride v1.0.58, but they are in NO artefact, so closing would be true about the repo and false about the DMG. ⚠️ THERE IS NO walks/v1.0.57.tsv AND THAT IS ITSELF A FINDING, filed as D004 rather than quietly omitted. The artefact WAS walked -- install completed, the 6-probe post-install QA subset ran on the box at 5 PASS / 1 FAIL / 0 CANNOT-RUN -- but the 21-probe harness was never run and no record was written, so this row is [DERIVED(no record)] while describing a version that really was installed. That gap is what took walk closure RED on the v1.0.58 dry run: 'v1.0.57 NO ROW. A cut with no row is indistinguishable from a cut nobody looked at.' The gate was right, the omission was mine, and it was caught by the gates-only dispatch rather than by spending a version -- the mechanism v1.0.56 was spent learning. THE STAGING-FREEZE CLASS WAS THEN SWEPT WITH CONTROLS rather than patched at the instance, because D001 is its THIRD occurrence (#177, #578, this): at the fixed pin, 8 writes above the promote-boundary contract line carry a tainted value, 1 is real (D001) and the other 7 are token/IP VALUES read via $(cat file) or openssl rand, and a token cannot freeze a directory. Both controls fired -- the same taint engine convicts #177 on its real pre-fix tree, and the finding disappears on the fixed branch -- so that near-zero is a measurement, not a vacuum. The sweep also named WHY the class recurs, which is D003. ZERO of these four are measured closure. The next walk is of a DIFFERENT artefact with a different sha256, which is #931 working as designed. | v1057-D001 v1057-D002 v1057-D003 v1057-D004 |
| v1.0.58 |  | not_walked | Archie 2026-09-02. TAGGED cb787e69 at commit 323a0df9 and ACTUALLY CUT: run 33599019125 concluded success and published OstlerInstaller-1.0.58.dmg, 70,905,599 bytes, as a PRERELEASE on ostler-ai/ostler-installer. That makes it the SECOND artefact in this sequence to produce bytes anybody could install, after v1.0.57 and four gate deaths before that. NOBODY INSTALLED IT. There is no walks/v1.0.58.tsv and there should not be one, so this row is not_walked under the rules table above and closed is REFUSED. 🔴 THE ROW YOU ARE READING WAS FILED HOURS LATE, AND ONLY BECAUSE SOMETHING ELSE WENT LOOKING. That makes it the THIRD occurrence of the class already recorded as 'the shipping ledger can silently lose an entire cut'. The mandate is same-turn: append after any tag push. v1.0.58 was tagged at 06:23:15Z, its cut ran green at 06:28:50Z, it published a real 70,905,599-byte DMG, and the turn ended with no row in either register. NOTHING FAILED. Nothing was red. Every guard we own reads the file and the file parsed fine, so a MISSING row is invisible to all of them by construction -- a parser cannot miss what was never written. ⚠️ AND IT WAS NEARLY MISSED A SECOND TIME, BY THREE BROKEN PREDICATES IN ONE SITTING, each of which returned a confident zero that looked like a finding. (1) Reading the ledger via the contents API with a base64 decode gave an EMPTY file and the YAML loader returned None: that API goes empty above 1MB with no error and the file is 1,074,699 bytes. Fixed by asking for the raw media type. (2) With real bytes in hand, testing whether the version was present treated a LIST of dicts as a dict keyed by version, so it reported absent for SEVEN versions of which FIVE were present. (3) Listing workflow runs filtered by head branch found NO cut run for v1.0.58; the workflow-scoped query returned 33599019125 immediately, against 172 total cut runs as the denominator. 🗿 THE UNIFORM SHAPE WAS THE TELL ALL THREE TIMES, and this row is the proof of the rule rather than another anecdote about it: when a WORKING predicate was finally run against this file it answered v1.0.53 through v1.0.57 present and v1.0.58 alone missing. REAL ABSENCE IS RAGGED. A uniform zero is a broken instrument. An earlier attempt to count rows here returned zero for v1.0.56 and v1.0.57 as well, which are the CONTROL and must be non-zero -- that is what exposed the pattern rather than the file. 🔴 AND THE ARTEFACT CARRIES ONLY HALF OF A1, MEASURED ON THE TAG'S OWN TREE RATHER THAN INFERRED FROM MERGE ORDER. The v1.0.57 row records D001 and D002 as fixed on main and riding v1.0.58. D002 rides. D001 only half does: at commit 323a0df9 the PYTHON3_BIN call site still passes the STAGING root explicitly, above the promote-boundary contract line, so the .pth it writes still names a directory that does not survive the install. #1316 hardened the FUNCTION DEFAULT, and A DEFAULT CANNOT APPLY TO A CALLER THAT PASSES THE ARGUMENT EXPLICITLY -- 12 of the 16 call sites pass no root and were genuinely fixed, and this one was never in that population. CM051 #1321 changes that one identifier to the final dir and merged at 06:48:46Z, TWENTY-FIVE MINUTES AFTER THE TAG. So the published DMG has the staging freeze still live for every service without its own venv: cm059-editor, ical-server, ostler_hygiene. WALKING v1.0.58 WOULD HAVE RE-FOUND A1, which is the strongest argument available for why this row must not be quietly marked closed. PUBLISHED BYTES, NO WALK, HALF A FIX. SUPERSEDED BY v1.0.59, which carries the second half of A1, the hub-v0.4.70 daemon re-pin and its rebuilt wrapper. | none |
| v1.0.59 |  | not_walked | Archie 2026-09-02. TAGGED c017f35d at commit 1d92f9d4, CUT run 33619834748 concluded success, and PUBLISHED OstlerInstaller-1.0.59.dmg -- 70,765,483 bytes, sha256 b35bfdd5..., prerelease, on ostler-ai/ostler-installer. 🎯 THE FIRST TAG IN THIS SEQUENCE CREATED AFTER A GREEN DRY RUN, which is the rule the v1.0.56 row states in my own words and which was still not followed at v1.0.57 or v1.0.58. Run 33619461561: preflight 20 success 0 failure, dry-run job 10 success 0 failure, cut job SKIPPED because a workflow_dispatch cannot make an artefact. IT CAUGHT SIX REFUSALS AT ZERO VERSION COST, and every one was mine. Four at preflight: no cut-manifests/v1.0.59.yaml at all; BOM_PIN carrying no hash for the v1.0.59 BOM; walk closure failing because v1.0.58 had NO ROW; and the CM051 pin not RESOLVING on CI at all. Two in-build: check-freshness, the gate that killed v1.0.55, red because I merged an upstream daemon commit INSIDE the cut window; and check-orphans, the gate that killed v1.0.54, red on exactly one orphan. 🗿 THREE OF THE SIX ARE DOCUMENTED RECURRENCES OF LESSONS ALREADY WRITTEN IN THIS FILE IN MY OWN WORDS: authoring canonically on the VENDORED side rather than here (the v1.0.56 row), advancing the live HEADs a pin is measured against mid-window (the v1.0.55 row), and reading a gate's own remedy text without acting on it. A registry that records a lesson and does not prevent its repetition has documented a habit, not fixed one. ⚠️ THE ORPHAN RED ALSO EXPOSED A KEY-SHAPE ERROR I THEN STATED PUBLICLY AND HAD TO RETRACT. cut-deferrals.yaml holds TWO top-level lists with TWO different consumers and TWO different reference shapes: deferrals is read by check-orphans, pr_exemptions by check-pr-age. I wrote four rows into pr_exemptions and announced the open PRs were disposed of. check-orphans never reads that list. The claim was HALF TRUE by accident -- three of the four were already covered by pre-existing deferrals rows, so only one was genuinely undisposed. 🔴 AND IT CARRIES THE SECOND HALF OF A1, WHICH v1.0.58 DID NOT. The v1.0.58 row records that #1316 hardened the FUNCTION DEFAULT while install.sh's PYTHON3_BIN call site kept passing the staging root EXPLICITLY, so the .pth still named a directory that does not survive promote for every service without its own venv. #1321 changes that call site and it is in this cut, measured in the shipped file rather than inferred from merge order. PROVEN ON THE ARTEFACT, NOT THE BUILD LOG, because divergent lineage is precisely the case where every step runs green and the bundle is still wrong: codesign valid, spctl accepted, stapler validated so offline first-run survives; the three fix patterns 1 hit each with a negative control at 0 and a positive control at 3009; BOTH shipped install.sh hashed identically rather than one probed and the other assumed; the shipped daemon binary carrying the pinned commit 3 times and the superseded one 0 times; and the Ostler.app wrapper's compiled-in WRAPPER_FRONTEND_COMMIT equal to the daemon commit. CUSTOMER PATH PROVEN WITH CONTROLS: unauthenticated and unproxied, DMG 200, alias 200, SHA256SUMS 200, a 9.9.9 negative control 404, and the downloaded bytes hashing to the value the release itself claims. PUBLISHED BYTES, FULL FIX, STILL NO WALK. Nobody has installed this on a clean macOS account. status is not_walked and closed is REFUSED. The BOM carries 11 rows, 5 PROVEN and 6 DECLARED needs-walk with 0 unclassified -- against v1.0.58's nine rows and nine TBD -- so what is unproven reaches Andy ANNOUNCED rather than as a surprise during the walk. | none |
| v1.0.60 | 2026-09-03 | deferred | Archie 2026-09-03. **THE ARTEFACT WAS INSTALLED AND WALKED BY ANDY ON THE MINI 16 (.98), AND IT FAILED.** That is his recorded call, not an inference of mine. I did not observe the walk; I observed its artefact and its findings, and this row says which is which throughout. ARTEFACT EVIDENCE I MEASURED MYSELF, over ssh, read-only: ~/.ostler/logs/install.log final line `DONE status=ok failed_steps=2 errors=0`, mtime `Sep 3 11:39:48` box-local, i.e. the run COMPLETED and then MISREPORTED ITSELF -- which is v1060-D001 caught in the act on the shipped artefact rather than reasoned about. The same log carries `Source status (T+0): 13 sources reporting, 5 landed at install`, so A2's G3 publisher is live on a real install. SEVEN DEFECTS CAME OFF THIS WALK, every one filed the same day with a named author, and FIVE ARE ALREADY FIXED ON MAIN: v1060-D001 (#1369 16b3d219 + #1376 e08869ab), D002 (#1375 dc9d85d3), D003 (#1370 39e896b6), D004 (#1371 318d513d), D005 (#1377 477608ab). D006 and D007 are OPEN. **DEFERRED, NOT CLOSED, and the reason is the standing one**: those five fixes are on CM051 main and ride v1.0.61, but they are in NO ARTEFACT, so closing would be true about the repo and false about the DMG. The next walk is of a DIFFERENT artefact with a different sha256, which is #931 working as designed. 🔴 AND `closed` IS NOT MERELY UNWISE HERE, IT IS ILLEGAL: this file's own status table says that with no walk record for a cut, only `deferred` or `not_walked` are legal and `closed` is REFUSED. `not_walked` would be a false statement about a version somebody really did install, so `deferred` is the only honest cell. ⚠️ THERE IS NO walks/v1.0.60.tsv AND THAT IS ITSELF A FINDING, filed as v1060-D008 rather than quietly omitted -- the identical shape as v1057-D004, which means this is the SECOND consecutive hand-walked cut whose harness record was never written, and a recurrence is a mechanism rather than an oversight. 📌 PROVENANCE, STATED SO IT CAN BE AUDITED RATHER THAN TRUSTED: the seven defect sections below are transcribed from register rows filed on 2026-09-03 from Andy's live walk, plus my own install.log measurement. TNM built the v1.0.61 cut set, hit this gate RED, and REFUSED to write this row -- correctly, because they held none of the findings and a walk row is a record of something someone watched. I am writing it because I hold the findings and the artefact measurement; I am NOT writing walks/v1.0.60.tsv, because that file is generated by scripts/post_walk_qa.sh and I did not run the harness, and hand-forging a harness record is the one thing this whole mechanism exists to prevent. @ANDY: correct anything here you saw and I have not captured -- these are your findings and my transcription. | v1060-D001 v1060-D002 v1060-D003 v1060-D004 v1060-D005 v1060-D006 v1060-D007 v1060-D008 |
| v1.0.61 | 2026-09-03 | deferred | Archie 2026-09-03. **ANDY INSTALLED THIS ON A CLEAN ACCOUNT ON THE MINI 16 AND IT FAILED**, and for the first time since v1.0.52 THE HARNESS WROTE A RECORD OF IT. `walks/v1.0.61.tsv` exists: verdict FAILED, qa_exit 1, walked_at 2026-09-03T10:56:21Z, box_fp 165e8417bcff2a80, artefact_sha256 0da59320633a92c9... with artefact_sha256_source reading measured(shasum -a 256 on the walked box). Phase-1 counts are pass 11, fail 7, cannot_run 6, broken 0, and the file's own `measured` line reconciles them at 24 of 24, so the buckets partition the suite rather than leaving a silent remainder. 🎯 **THE EXISTENCE OF THAT FILE IS ITSELF THE CLOSURE OF v1057-D004 AND v1060-D008**, which are the same finding filed twice running: "the artefact was walked and no walk record was written". Both times the walk was done by hand, and the harness -- the only thing that writes the record -- was never run. This time it was. That makes this the first row in the v1.0.5x/6x sequence whose status is DERIVED FROM A RECORD rather than from my transcription of somebody else's account, and the difference is not cosmetic: every row above this one reading [DERIVED(no record)] is me writing down what I was told. 🔴 **SIX DEFECTS CAME OFF THE WALK AND THREE ARE ALREADY FIXED ON MAIN**: v1061-D003 (CM051 #1385, 4e1bd89a) and v1061-D004 + v1061-D006 (CM051 #1386, c7b2c3ac). D006 is the one that ended the walk -- a SPACE after a line-continuation backslash at install.sh:26690, which `bash -n` exits 0 on, so no parse-level check we own could ever have seen it. v1061-D001 (#622), v1061-D002 (#623) and v1061-D005 (#627) are OPEN. **DEFERRED, NOT CLOSED, and the reason is the standing one**: those three fixes are on CM051 main and ride v1.0.62, but they are in NO ARTEFACT, so closing would be true about the repo and false about the DMG. The next walk is of a different artefact with a different sha256, which is #931 working as designed. ⚠️ **AND A SEVENTH FINDING CAME OUT OF THE RECORD ITSELF RATHER THAN OFF THE BOX**, filed as v1061-D007: three probes have now failed on FOUR CONSECUTIVE walk records and not one of the four was investigated. That is NOT a v1.0.61 regression and this row does not claim it is -- it is a standing condition the harness has been reporting since v1.0.50, filed here because v1052-D007 already called it out at two consecutive and nothing changed. 📌 PROVENANCE, STATED SO IT CAN BE AUDITED RATHER THAN TRUSTED: the walk is Andy's, on his hardware, and the descriptions of D001, D002 and D005 are transcribed from register rows filed the same day from what he saw. The counts, the probe names and the four-walk recurrence in D007 are mine, measured directly from the walks/*.tsv files. I did NOT write walks/v1.0.61.tsv; the harness did, which is the entire point of this row. @ANDY: correct anything here you saw and I have not captured. | v1061-D001 v1061-D002 v1061-D003 v1061-D004 v1061-D005 v1061-D006 v1061-D007 |
| v1.0.62 | 2026-09-03 | deferred | Archie 2026-09-03. **THE ARTEFACT WAS CUT, INSTALLED ON THE MINI 16, AND WALKED. THE HARNESS DID NOT WRITE A RECORD.** There is no `walks/v1.0.62.tsv`: measured with `git ls-files walks/`, 7 files present (v1.0.44, 47, 50, 51, 52, 61 and the README), and a positive control confirms the predicate is sound because it finds `walks/v1.0.61.tsv`. The zero is real, not a broken search. 🔴 **THAT MAKES THIS THE THIRD OCCURRENCE OF THE CLASS v1057-D004 AND v1060-D008 BOTH NAMED**, and the v1.0.61 row directly above celebrated closing it: "the artefact was walked and no walk record was written". One cut ran the harness. The very next one did not. The closure was a single event, not a mechanism, which is exactly the distinction this register exists to force. Everything in this row is therefore **[DERIVED(no record)]** -- me writing down what I observed, the same provenance the v1.0.61 row was written to escape. 📌 **WHAT THE WALK ACTUALLY SHOWED.** The ttywalk ended 2026-09-03T20:42:08Z with `~/.ostler/logs/install.log` frozen at 4180s and no `install.sh` process alive. The log's terminal line reads `DONE status=ok failed_steps=1 errors=0` -- a success verdict carrying a failed step, which is **precisely** the defect CM051 #1401 (6e82afc5) fixes. #1401 merged 21:06:16Z and **v1.0.62 was tagged 13:24:04Z, 7h42m earlier**, so the fix is on main and in no artefact. 🔴🔴🔴 **AND THE WALK-KILLER IS WORSE.** e17dad02 (CM051 #1392, register #642) fixes a `pgrep` no-match that fabricates a TERMINAL failure verdict mid-install; it postdates the v1.0.62 tag by **3h14m**. The double-DONE mechanism was solved on a live run of this vintage: the ERR trap inherited into a command substitution's SUBSHELL, which is why three earlier harnesses all refuted it -- each kept an rc-capturing fallback on the fallible call, which suppressed ERR. 🚦 **SCOPE CALL, MINE, 2026-09-03T22:19Z: v1.0.62 MUST NOT BE WALKED AGAIN.** Walking it walks the deadlock. Six install-path commits are stranded off the tag -- e17dad02 (#1392), 6e82afc5 (#1401), 0c4f920a (#1398), 1adc5ef1 (#1396), f875f353 (#1400), 205aa100 (#1393) -- measured as 14 commits since the tag of which 6 touch `install.sh` or `gui/`, with a control confirming the gate-only PRs (#1404, #1405, #1406) are correctly ABSENT from that shipping set. **DEFERRED rather than closed, for the standing reason**: those fixes ride v1.0.63, which does not exist yet, so closing would be true about the repo and false about the DMG (#931). ✅ One thing this artefact did prove: the Tailscale pre-announce guard was verified IN the shipped v1.0.62 DMG (register #613), so declining no longer promises a later sign-in. ⚠️ **THE FINDINGS COLUMN OF THIS ROW IS DELIBERATELY EMPTY AND THAT IS NOT A CLAIM THAT NOTHING WAS FOUND.** The gate counts findings by `v1062-Dxxx` ids carrying a matching `###` section here, and this walk's findings are already filed as register rows #639, #640, #641, #642 and #613, cited in the prose above. Minting duplicate `v1062-D` sections would put TWO REGISTERS ON ONE FACT, which is this estate's signature failure (#532), so I have not done it. But the consequence must be stated rather than left for a reader to trip over: **this row passes walk closure on a ZERO DENOMINATOR**, exactly as v1.0.58 and v1.0.59 do, while v1.0.60 and v1.0.61 carry 8 and 7. A `deferred` row with no findings is the odd one out in that sequence and a reader is entitled to be suspicious of it. @ANDY: correct anything you saw here that I have not captured. | #639 #640 #641 #642 #613 |
| v1.0.63 | 2026-09-04 | deferred | Archie 2026-09-04. **ANDY INSTALLED THIS ON THE FRESHLY WIPED MINI 16 AND WALKED IT BY HAND, AND THE HARNESS WROTE A RECORD.** `walks/v1.0.63.tsv` exists: verdict FAILED, qa_exit 1, artefact_sha256 1c1bb8a941c1d24b... with artefact_sha256_source reading measured(...) on the walked box. 🔴 **BUT THE RECORD IN THE TREE IS NOT THE WALK'S OWN RESULT, AND THAT IS MY DOING.** The first harness run, at ~08:53Z on the untouched box, measured **pass 14 / fail 8 / cannot_run 2 / broken 0**. I then repaired the box by hand with Andy's explicit go-ahead -- set the aiconv owner email ~09:16Z, pinned the iMessage backfill window and re-extracted ~09:17Z, ran the over-merge repair ~10:07Z -- and re-ran the harness, which OVERWROTE the file with the 10:14:36Z result of **pass 15 / fail 7 / cannot_run 2**. The delta is `people_count_agreement`, which moved FAIL -> PASS because of my repair and not because of any build. **So this row's counts are 14/8/2/0 and the file's are 15/7/2/0, and the file is the weaker evidence.** That is #940 exactly -- a walk verdict is a function of the build AND the box state, and only the build is recorded -- caught on myself rather than reasoned about. The harness has no notion of a box that changed under it, and I gave it one. ⚠️ **THE MINI 16 IS THEREFORE NO LONGER A CLEAN SUBJECT** and no probe result taken from it after 09:16Z is a verdict on the v1.0.63 artefact. 🎯 **TEN FINDINGS CAME OFF THIS WALK AND SIX ARE ALREADY FIXED ON MAIN**, all in CM051 #1418 (98398996) except where noted: D001, D002, D003, D004, D005 and D009. D006, D007, D008 and D010 are OPEN. Three of the ten are not product defects at all but **GATES REPORTING ON THEMSELVES** -- D004, D005 and D006 -- which is the finding underneath the findings: `install_manifest_complete` had never once adjudicated since v1.0.50 because every walk is remote and it refused to run remotely; `pair_state_agreement` asked the Doctor for a key only the gateway carries; `usage_journal_producers` reads a workspace path the daemon does not use, and has FAILED ON ALL FIVE WALKS THAT MEASURED IT while the journal it reports missing exists with 684 records. **DEFERRED, NOT CLOSED, for the standing reason** (#931): the six fixes are on CM051 main and ride v1.0.64, which is being cut now, but they are in NO ARTEFACT. Closing would be true about the repo and false about the DMG. 📌 PROVENANCE: the walk is Andy's, on his hardware. The probe counts, root causes and code reads are mine, measured directly. **I asserted seven root causes across this session and three survived** -- the four withdrawn ones are named in D003 and D006 so the record shows the wrong turns, not just the destination. @ANDY: correct anything you saw that I have not captured. | v1063-D001 v1063-D002 v1063-D003 v1063-D004 v1063-D005 v1063-D006 v1063-D007 v1063-D008 v1063-D009 v1063-D010 |
| v1.0.64 |  | not_walked | Archie 2026-09-04. **TAGGED, CUT, PUBLISHED, VERIFIED TO THE PAYLOAD, AND NEVER WALKED.** The artefact is real and I measured it: OstlerInstaller-1.0.64.dmg, 70,927,801 bytes, sha256 7e6a0ebf..., stapled, codesigned, Gatekeeper-accepted, and the `install.sh` INSIDE the DMG hashes identically to the tagged blob 92d4286e71a95adab992816f, which is the check that compares the payload rather than the commit. It was copied to the Mini and its hash re-measured there. 🔴 **IT WAS NOT WALKED BECAUSE IT WOULD HAVE FAILED THE WALK IN THE SAME PLACE v1.0.63 DID, AND THAT IS MY DOING.** First it could not be walked at all: the only account on the Mini was Andy's, whose running v1.0.63 held all six store ports through colima's forwarder (measured: `ssh: ~/.colima/_lima/colima/ssh.sock [mux]`, pid 10934, holding 3000 6333 6379 7878 8044 8144), so `ttywalk.sh` returned CANNOT-RUN and was RIGHT to. Andy then created a second account, `archie` (uid 502), which is a genuinely cold subject. Before spending it I re-read the one defect v1.0.64 was cut to fix and found I had fixed HALF of it. `v1063-D001` has two symptoms from one empty string; CM051 #1418 guarded the LaunchAgent and left the `health_check` fold alone, because the guard it added sits BELOW the fold at install.sh:29055. So v1.0.64 still ends a cold-Mac install `failed_steps=1` with a red final step while every service inside it logs healthy. **A brand-new account has never opened Contacts, which is precisely the condition the defect needs**, so walking v1.0.64 on `archie` would have reproduced Andy's exact complaint on the only genuinely cold account available. ⚠️ **THE CUT MANIFEST FOR v1.0.64 STATES THIS DEFECT AS FIXED**, and so did a code comment I wrote the same morning. The reason it survived is worth more than the fix: the defect is an ORDERING between a guard and a fold, and after #1418 BOTH were present in the tree, so every structural check over the source answers YES on a tree that still ships the bug. Only executing the block discriminates. **SUPERSEDED BY v1.0.65**, which carries CM051 #1428 and a RUNTIME test whose two pinned controls, 45126e9a and deecd9fc, BOTH reproduce the failure. The second control is the one that proves v1.0.64 did not fix it. 📌 PROVENANCE: no human installed this artefact. Every claim in this row is a measurement of the artefact or of the source, not of a walk, and the row says `not_walked` for exactly that reason. | v1063-D001 |
| v1.0.65 | 2026-09-04 | deferred | Archie 2026-09-04. **WALKED NINE TIMES ON archie@192.168.1.240 (uid 502) AND CONDEMNED.** This is the first cut ever driven past step 21, and the reason it took nine attempts is worth more than the verdict: **FOUR of the nine stops were MY HARNESS, not the product.** walk 5 died at step 6 on a real defect (#1436, merged). walks 6-8 died at step 10 on three different false zeros I wrote into ttywalk's reset payload -- an apostrophe inside a single-quoted ssh argument, a `tr -d ' '` that closed it the same way, and a bare `docker` that is not on the non-interactive ssh PATH -- each of which PRINTED SUCCESS while five containers were running. walk 9 died at step 21 on a staging gap: the harness stages the REPO and 23 of 48 DMG `Contents/Resources` entries were absent, of which it warned about 3. **THE STAGING GAP IS WORKED AROUND, NOT FIXED**: I copied 22 of the 23 in BY HAND from the mounted DMG into a worktree under `/private/tmp`, which macOS clears on boot. 🔴 **THEN THE PRODUCT DEFECTS.** walk 10 found `v1065-D001`, a same-day regression of mine that kills every install at step 21 with rc=127. walks 11 and 12 found `v1065-D002`, which has silently disabled contact and Places import since v1.0.60, and `v1065-D003`, the abort that turned it into a dead step. walk 18 is GREEN: 39 steps, 0 not-ok, 0 ERR codes, 0 tracebacks, one terminal `DONE status=ok failed_steps=0 errors=0`, `ttywalk exiting 0`. ⚠️ **THE GREEN WALK SHIMS THE iMESSAGE TCC PROBE AND THEREFORE SAYS NOTHING ABOUT AUTOMATION PERMISSION.** macOS TCC needs a GUI click an ssh session cannot make. Only a console walk by a human can measure it, and the harness prints that disclaimer on every run. 🔴 **AND THE POST-WALK GATE IS 10 PASS / 10 FAIL / 4 CANNOT-RUN, AGAINST 15/8/1 ON THE v1.0.63 WALK THIS MORNING.** Three failures are new (`daemon_is_listening`, `people_count_agreement`, `people_seed_and_retrieval`) and one moved FAIL -> CANNOT-RUN (`ingest_coverage`), which is coverage lost and must not be read as a fix. `assistant_answers_grounded` DEGRADED rather than merely staying red: this morning the socket connected and answered, tonight all three questions die at `handshake HTTP/1.1 401 Unauthorized`. **The 401 is NOT a provisioning failure** -- `secrets/service_token` is present at mode 600 and the daemon plist carries a `PWG_SERVICE_TOKEN` of matching length, and four credential presentations all 401 against a `GET /` control that returns 200. **CONFOUND, STATED: tonight's box is a FRESH RESET and the v1.0.63 box had history**, so I have NOT established that any of the three new failures is caused by code. That needs a real v1.0.66 DMG on a cold account. 📌 PROVENANCE: every walk is mine, unattended, on Andy's Mini under the `archie` account. No human installed this artefact. **DEFERRED, NOT CLOSED**, for the standing reason (#931): D001, D002 and D003 are all fixed on CM051 main and ride v1.0.66, which has no artefact yet. Closing would be true about the repo and false about the DMG. @ANDY: correct anything you saw that I have not captured. | v1065-D001 v1065-D002 v1065-D003 |

**On the v1.0.42 row, and it corrects something this file said hours earlier.**
**v1.0.42 WAS NEVER INSTALLED ANYWHERE.** The upgrade walk that produced
`v1042-D001..D004` ran on **v1.0.38**. Measured three independent ways on
2026-08-23:

| | |
|---|---|
| DMG on the walk box | 57,818,336 bytes, dated 21 Aug 19:32 HKT |
| published v1.0.38 | **57,818,336 bytes**, published 2026-08-21T11:29:32Z |
| published v1.0.42 | 57,970,010 bytes, published 2026-08-23T10:55:39Z |
| `install.sh` run headers on that box, all time | exactly ONE, 2026-08-21T11:36:44Z |

The byte count matches v1.0.38 exactly, 19:32 HKT **is** 11:32Z -- three minutes
after v1.0.38 was published -- and v1.0.42 did not exist for another two days.
Three facts agreeing, none of them inferred from a version label.

So the row is `not_walked` and it always was going to be: **there was no
v1.0.42 install to walk.** The approver is recorded as relayed rather than
direct, because what was given was a directive and not a row sign-off: *"Andy's
directive is a NEW cut, v1.0.43, carrying everything surfaced since v1.0.38,
walkable when he wakes. Do not wait on a v1.0.42 walk."* That is an explicit
decision not to walk v1.0.42, and it is cited here so a reader can weigh the
provenance instead of taking a name on trust.

**A `not_walked` row that still lists findings is not a contradiction, and it is
the most accurate thing this table can say.** The status answers "did anyone
walk this cut", and nobody did. The findings column answers "what do we know
this cut carries", and the answer is four defects that shipped in v1.0.38 and
were never fixed, so **v1.0.39, .40, .41 and .42 all carry them**. Listing them
here asserts that v1.0.42 HAS these defects, which is true, and asserts nothing
about how they were discovered.

The sections keep their `v1042-` ids -- see the correction banner on the block
-- because the ids are already cited in `SHIPPING_LEDGER.yaml`, in
`launch/GROUNDING.md` and across five PRs. **Renaming a label that other
documents point at trades one wrong fact for a set of dangling references**, and
a wrong label that says it is wrong is the safer half of that trade.

**On the v1.0.44 row, and it is deliberately RED.** v1.0.44 was cut. Run
32706147520 succeeded at 2026-08-24T08:24Z, all thirteen cut steps green, and a
signed, notarised, stapled DMG was published to `ostler-ai/ostler-installer` as a
prerelease at 08:33Z, sha256 `d13da1d9b729f277d8ac3480723ddb88bd4ef77211f5a6c5418bf00507c4126a`.
The earlier run at 07:46Z failed on the expiry ratchet and the tag was moved to
`3ee69f16` before the successful one, so a reader who stops at the first run
concludes the opposite.

Nobody has walked it and nobody has waived it, so the approver column is EMPTY on
purpose. The gate reads `not_walked` with no named approver as RED, and that is
the correct verdict: this row exists to turn "no row at all", which is
indistinguishable from a cut nobody looked at, into a named decision that somebody
has to make. Filling that column requires a person, and inventing one to make the
gate green would be exactly the fabrication the horizon rule exists to prevent.

Two ways to close it. Walk v1.0.44 on a box and commit the record
`scripts/post_walk_qa.sh` writes, which also promotes it out of prerelease. Or
waive it by name, the way v1.0.41 and v1.0.42 were waived, and say why.

**On the v1.0.41 row.** Andy signed this off unwalked on 2026-08-23, asked
directly, because the alternative was inference. `SHIPPING_LEDGER.yaml` cannot
answer the question: its `dmg_cuts` section had no row for any of them (it now
holds v1.0.42, v1.0.43 and v1.0.44, filed 2026-08-24, but still none for the four
named here), and v1.0.38, .39,
.40 and .41 appear 28, 45, 31 and 24 times across that file without a single cut
row between them. The last cut recorded as `box_walked: true` is v1.0.36. So the
launch cut ships without a walk of its predecessor, and this row is that fact
written down rather than left to be discovered.

---

## MUST-FIX-NEXT (blockers for the next cut — v1.0.19 or v1.0.1)

Every entry here has a gate, and **nothing automatically runs them.** `pipeline/release.yml`
is NOT wired: it sits at `pipeline/`, not `.github/workflows/`, so GitHub Actions never
loads it. Measured 2026-08-21, OS003's only workflow is `.github/workflows/gates.yml`, and
no file in the repo invokes `pipeline/release.yml`. Its own header says so: only `preflight`
runs to completion, the macOS jobs use placeholder runners. The DMG is actually produced by
CM051 `.github/workflows/cut.yml`, whose shipping job is gated on
`if: github.event_name == 'push'` (cut.yml:386), and that workflow does not read this file.
So MUST-FIX-NEXT is enforced by a human reading it at cut time. Treat "FAIL any = NO SHIP"
as the intended discipline, not as a mechanism, until a gate reads this register.

**v1.0.19 planning (Archie 2026-08-09):** every MUST-FIX-NEXT entry below now carries its corresponding PR from the consolidated `v1.0.18/V1019_PLAN.md`. Target state = the state the entry moves to when the PR lands + the cut pipeline enforces its gate. Any entry marked `deferred` requires an explicit Andy sign-off in `V1019_PLAN.md § deferred` before v1.0.19 can be tagged.

### From v1.0.18

| ID | Summary | Ledger entry | Gate | V1019 PR | Target state |
|---|---|---|---|---|---|
| v1018-D001 **RESCOPED** | Funnel warning is a FALSE POSITIVE on the happy path (`funnel status` and `serve status` are the same upstream fn; a tailnet-private serve prints `https://... (tailnet only)` and the grep matched it). NOT a missing prompt. | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d001--corrected--the-funnel-warning-is-a-false-positive-on-the-happy-path-not-a-missing-prompt) | `tests/test_wiki_tailnet_gate.sh` passes (extracts the shipped detection block, runs it against on/off fixtures) AND shipped install.sh greps `funnel status --json` and never pipes `funnel status` into `grep` | PR #545 (`archie/d001-funnel-false-positive`, CM051) — **plan PR #16 CANCELLED** | fixed_in_v1.0.19 |
| v1018-D002 | Wiki tab conceded to the error state on the FIRST failed probe. The retry loop was gated on `prev === 'probing'` inside a `setProbeState` updater, and the first failure had already set `'error'`, so the loop went silent. The "Building your wiki..." copy existed in all 31 locales and was unreachable. | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d002--wiki-tab-shows-wiki-not-available-error-on-first-run-instead-of-initializing-state) | `web/src/pages/Wiki.test.tsx` passes (drives the real component against a controllable fetch; asserts probe COUNT across the warm-up window, not merely the absence of an error) | PR #291 (`archie/d002-wiki-warmup`, ostler-assistant) — **plan PR #22 CANCELLED** | fixed_in_v1.0.19 **CITATION IS CORRECT, BUT THE FIX IS NOT ON THE BOX (2026-08-10, Archie).** oa #291 is the right PR and merged 2026-08-09T12:34Z. The Mini's daemon reports build commit `782a6195`, authored **2026-08-06T17:02Z**; `git compare` puts #291's merge `2c974f27` **ahead_by=4, behind_by=0** of it (control: self-compare identical). So the running daemon predates the fix. **This is the THIRD delivery path found stale today** -- after the digest-pinned wiki image (D010/D014a/D016) and alongside vendored code, which DID travel (D014b/c). **Bounded generalisation:** 5 oa PRs merged after the box's build and are absent from it -- #291 (this fix), #289, #285 (a Snyk `react-router-dom` security upgrade), #189, #175 -- against a control of 92 merged before it. Note this is ANDY'S box, not the customer path; it matters because the box is what launch readiness is judged on. **RE-CONFIRMED 2026-08-10 21:5x HKT (Archie), by an independent measurement that needs no build sentinel.** The running daemon is `~/.ostler/OstlerAssistant.app/Contents/MacOS/ostler-assistant`, binary mtime **Aug 8 19:29 HKT (Aug 8 11:29 UTC)**. oa `#291` merged **Aug 9 12:34 UTC**. The binary is **25 hours older than the fix**, so it cannot contain it. mtime is sound in this direction specifically: copying a file would make it look NEWER, never older, so an old mtime cannot be manufactured. **Two days on, the daemon still has not been rebuilt.** Note the contrast with D014a, whose wiki image DID deliver today at 19:06 -- the wiki lane moved and the daemon lane did not. Source side is GREEN: the D002 gate (runs-on=repo) passes on oa main `cd01cca8`, and its test is not vacuous, running 6 real assertions. Gate measures SOURCE; delivery is the gap. |
| v1018-D003 | OS003 gate stale vs current daemon (all 3 v1.0.18 fails were gate-staleness) | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d003--os003-behavioural-gate-is-stale-vs-current-daemon-contracts) | gate runs GREEN against known-good post-install box (meta-gate) | **OS003 #5** (merged) `fix(gate): rewrite behavioural acceptance gate against current daemon contracts -- v1018-D003`. Repointed 2026-08-10: the row cited OS003 #1, which is closed and NOT merged. MUST land BEFORE tag-push. | fixed_in_v1.0.19 |
| **v1018-D004 🔴🔴🔴** | Base32 ghost person on the customer wiki. **NOT write-side corruption** (corrected 2026-08-12): the graph holds a legitimate machine ADDRESS and the wiki compiler MANUFACTURES the blob out of it | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d004--base32-ghost-person-write-side-data-corruption-ships-to-customer-wiki) | grep wiki People pages for blob-like display_name (0 hits = PASS) | **CM044 #185** (open) `fix(wiki): the rescue must not manufacture the machinery the drop just passed`. **MECHANISM PROVEN 2026-08-12 against the shipped artefact, not inferred.** #172's per-token guard is correct AND delivered: present in both compiler images on the box, both built after it, and the offending page was still written 2026-08-12 01:47Z. `_is_not_a_person` passes the raw address because it is ONE token carrying `@` `.` `_`, so no token matches `[0-9a-z]{32,}`; `_looks_non_human_name` is then True, so `_rescue_display_name` humanises the email local part, drops those separators, and MANUFACTURES the 76-character unbroken run the guard exists to catch. Nothing asks again. Replayed the real graph value through the real compiler image: the rescue output equals the page byte for byte. #172 is not wrong and stays; #185 re-asks the drop of the rescued name. Repointed 2026-08-10: the row cited CM041 #5, CM044 #5 and CM051 #19, all merged but none naming this defect. | fixed_in_v1.0.19. **A write-side reject would NOT have caught this** and that prescription is withdrawn: what CM041 writes is a valid address. Needs (a) CM044 #185 merged, (b) a compiler image built from it and re-pinned, (c) a recompile on the box, (d) the gate re-run by me. Stale pages persist until (c) |
| **v1018-D005 🔴🔴🔴** | Dedupe fragmentation 16% of wiki People (915/5713) — flagship "Recently active" fragments customer's world | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d005--dedupe-fragmentation-systemic-16-of-wiki-people-are-duplicates) | **T+0 ONLY** -- hex6-suffixed ratio in `~/Documents/Ostler/Wiki/People/` measured on the FIRST compile after a fresh install, not whenever someone looks. See the time-varying note in the D005 entry: the ratio converges, so a late measurement passes while the customer's first impression fails | **CITATION WITHDRAWN 2026-08-11.** `CM041-People-Graph#4` is an OPEN ISSUE titled "iCloud photo source for People Graph" -- **not a pull request**. GitHub shares one number sequence between issues and PRs, so it resolves, sits in the right repo, and reads exactly like a fix citation until you check the type. `CM051#17` is genuinely merged but is "CM046 LaunchAgent piece 3", a different defect. Controls run before believing the 404: `CM041-People-Graph#116` resolves, and #1 #2 #3 #5 #6 all exist, so neither the token nor the repo is the explanation. **CORRECTED 2026-08-13 (Archie): "No PR fixes this row" was FALSE when written.** CM041 #109 had merged the previous day and is exactly the change this row names as its real fix. The withdrawal of the `CM041-People-Graph#4` and `CM051#17` citations above remains CORRECT and stands -- those two were genuinely wrong, and the discipline that caught them was right. What was wrong was the conclusion drawn afterwards, that therefore nothing fixed the row. | open -- status corrected from `fixed_in_v1.0.19` 2026-08-11. The old status contradicted itself: it conceded "resolver-rework real fix deferred to v1.0.1" while claiming fixed, and this file's own D034 note already states "D005 is genuinely OPEN". The table row was the only place still asserting otherwise. **CORRECTED 2026-08-13 (Archie): this sentence was a FALSE ABSENCE and it is retracted.** It read: "The real fix rides on CM041 `fix/one-person-one-name`, which is ABSENT from that remote across 57 enumerated branches". The branch was absent because it had **MERGED AND BEEN AUTO-DELETED THE DAY BEFORE** this note was written. Verified at source: `andygmassey/CM041-People-Graph` PR **#109**, `head.ref = fix/one-person-one-name`, `merged = true at 2026-08-10T01:41:45Z`, base `main`, title "fix(identity): one canonical displayName; kinship labels dropped, never stored as alternateName". Control: 59 branches enumerate on that remote, so the listing works. Enumerating live branches can never distinguish "never existed" from "merged and tidied up"; querying PRs by `--head` can. **A SECOND TRAP SAT ON TOP OF IT:** the repo is `CM041-People-Graph`, NOT `CM041-PWG-People-Graph`. The wrong name 404s identically to a missing PR, and returns ZERO branches, which is the tell -- a real repo cannot have none. A row cannot be fixed on a branch that does not exist. The v1.0.19 budget and chunking work is real and stays described in the ledger entry, but it is mitigation, not the fix this row's acceptance measures. |
| v1018-D006 | Nia/Niaj Wexcombe same-person split (subclass of D005, named because Andy flagged) | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md) | not both of the two slugs exist | **CITATION WITHDRAWN 2026-08-11, inherited from D005.** This row rode on the same two citations and neither is a fix: `CM041-People-Graph#4` is an OPEN ISSUE about iCloud photo sourcing, not a pull request, and `CM051#17` is merged but is "CM046 LaunchAgent piece 3". Nothing to repoint to. | open -- status corrected from `fixed_in_v1.0.19` 2026-08-11. The old status was "as a consequence of D005 fix", and D005 is now correctly recorded as open with no fix located, so the consequence cannot hold. A row whose entire claim is derived from another row's fix must move when that row moves. Acceptance is unchanged and is a good one -- both hex-suffixed page variants must not coexist -- so this row needs no rework, only an honest status. **MEASURED 2026-08-12: this gate has never actually run.** It refuses with rc=97 on the box because no gate-fixture file sets `GATE_D006_SLUG_A` and `GATE_D006_SLUG_B`, and none exists anywhere under `~/.ostler`. The refusal is correct and the row is not green; it is unmeasured. **The name in this row is already a pseudonym** -- it was introduced by `dc1a58b`, the PII fix itself, and the real pair is the one the register guard's denylist names. Recorded because I read it as a live leak, checked the box, found 0 pages and 0 graph literals, and nearly opened a remediation PR against two repos before the history check settled it. Positive control on that probe: a real surname stem from the same directory returns 7. **Class-level measurement, since the single-pair gate cannot run:** 4,918 People pages carry 536 surname stems with 2 or more pages, of which 21 are prefix-of pairs within 2 characters, the shape this row names. Those 21 are CANDIDATES, not confirmed splits -- D011 found 36 of 81 hits were legitimate middle names, and the same caution applies here. |
| v1018-D007 | Hydration surface claim un-backed by verifiable endpoint (task #208 trust class) | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d007--hydration-surface-claim-un-backed-by-verifiable-endpoint-task-208-class) | `/api/v1/hydration/status` returns `overall_state` plus a non-empty `phases` list, and every phase carries enough numeric substance for the state it claims (state=done needs `count`; state=running needs `done` + `total`; state=pending needs neither) | **CITATION DOES NOT RESOLVE (2026-08-10).** ostler-assistant #13 is "ci: fix Quality Gate trigger (master -> main)", merged 2026-05-03 from `agent/ci-trigger-main-2026-05-03` -- a CI trigger fix against a hydration-endpoint defect. The cited branch `tnm/d007-hydration-endpoint` does not exist in ostler-assistant or HR015. Controls: oa #292 and oa `main` both resolve with the same token, so this is not an auth artefact. | open -- status corrected from `fixed_in_v1.0.19` 2026-08-10, and the ACCEPTANCE corrected with it. **The old acceptance could not fire:** it named `/doctor/api/hydration`, which returns **404** on the shipped v1.0.18 box. Positive controls that prove the probe was sound: `/doctor/api/health` 200, `/api/v1/box-status` 200, `/api/v1/wiki/duplicates/decision` 405. A hydration endpoint **does** exist at `/api/v1/hydration/status` (200, unauthenticated) but its shape is nothing like the one this row asserted: it returns `{generated_at, overall_state, phases}` and **none** of `percent`, `eta_seconds`, `sources` appear at top level. `eta_seconds` does exist, but per-phase on a running phase, and a percentage is derivable from that phase's `done`/`total` rather than served. So the row was written against a flat API shape that was never built. The trust question it exists to ask (task #208 class) is now gated against the real contract below. **GREEN 2026-08-12, gate re-run by me on the box:** rc=0, `4 phases, overall_state=running, each substantiated for its state`. **The gate was proven before the verdict was believed:** 8 negative controls all fired rc=1 with the right message (404, non-object payload, missing `overall_state`, missing `phases`, empty `phases`, a running phase with no `total`, a done phase with no `count`, a `count` that is a string), and a valid payload gave rc=0. **The path is the shipped surface, not a convenient one:** the daemon-served SPA asset and the Doctor's own `web_ui.py` and `box_status.py` all name `/api/v1/hydration/status` and nothing else. Discrimination control: on the Doctor at `:8089` the three wrong paths return 404 while this one returns 200. The daemon at `:8000` is excluded as an oracle because it returns 200 for every path (task #319). **The fix stays unattributed** -- no PR was located, and inventing a citation to close the row is exactly what the withdrawn one did. |
| **v1018-D008 🔴🔴🔴** | A live reply starves behind whichever background job holds the Ollama slot. **NOT wiki-compile specifically** (corrected 2026-08-12: the observed holder was a WhatsApp source tick and no wiki-compiler container existed at all), and **not the lock**, which behaves as designed. 16 GB FLOOR tier fatal | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d008--chat-hangs-indefinitely-while-wiki-compile-holds-ollama-slot-lock-task-181-recurrence) | chat responds within 60s while wiki-compile in flight (real-box behavioural gate) | **CITATION WITHDRAWN 2026-08-11.** The row named the right BRANCH and the wrong NUMBER, which is why it read as sound: the parenthetical says `archie/d008-mount-ollama-user-active-lease`, unmistakably a D008 fix branch, while `CM051#18` is "Wiki container piece 1: bundle wiki-site + wiki-compiler in compose", merged 2026-05-01, +51 -2, touching install.sh only. Only the integer is machine-checked; a human reads the branch name, recognises it, and stops. Chased for the real number and there is none: server-side head filter on that branch returns NO PR (control: the same query returns #557 for its own branch), the branch itself 404s in CM051, and no merged PR anywhere in the org names this mechanism. **Nothing to repoint to.** | open -- status corrected from `fixed_in_v1.0.19` 2026-08-11. I expected this one to be a repoint and it is not; the evidence went the other way and the claim has to move instead. The described fix (bind-mount plus env in the wiki-compiler compose heredoc) has no PR and no surviving branch, so there is nothing to verify it against. This row is a 🔴🔴🔴 and its acceptance is a real-box behavioural probe (chat responds within 60s while wiki-compile is in flight) -- that acceptance is good and unchanged, and it has never been run against a located fix. Related and NOT closed by this edit: the shared Ollama slot lock still has no timeout and no heartbeat, which is the mechanism behind this defect and stalled three separate scripts on 2026-08-10. **ROOT CAUSE FOUND 2026-08-12, and it is not the lock.** install.sh's own comment states the design premise: holding the lock for a whole run is safe BECAUSE "the 2nd parallel slot is always free for a live reply". That requires two slots. The same file's resource governor sets `OLLAMA_NUM_PARALLEL` to "2 on LOW/HIGH, 1 on the FLOOR tier". On the FLOOR tier there is one slot, the background job holds it, and the live reply has nowhere to go, so the mitigation is **false by construction on exactly the 16 GB hardware this row names**. Measured on the operator box: running server `OLLAMA_NUM_PARALLEL=1`, launchd plist `<string>1</string>`, holder was a WhatsApp tick that had held the slot 1,016 minutes **legitimately** (its child parked in `sock_recv` on an ESTABLISHED socket to `127.0.0.1:11434` while the Ollama access log showed generates completing at 16.9s / 24.2s / 20.6s). **The row's own acceptance FAILS**: a live generate took **77s against the 60s budget** while the slot was held. The timeout/heartbeat framing above is withdrawn: PID-liveness reclaim is correct and irrelevant, because the holder is alive and working. **Gate written and proved 2026-08-12** (this row had none, which is why a triple-red had never been measured): 4 negative controls on limb A and limb B each fire with their own message, the composition rule is verified 4 of 4 against a fast stub so box load cannot confound it, and the real box returns rc=1 on both limbs. **A near-miss worth recording:** the holder showed 17h elapsed against 2.76s CPU, the classic wedge signature, and it was not wedged. Low CPU is what a client looks like when the work is in another process. The socket and the server's access log were both needed to settle it. |
| **v1018-D009 ~~🔴🔴🔴~~ NOT-A-DEFECT** | Combine/Different-people dedupe buttons return 404 (route not wired) — human escape hatch for D005/D006 is dead | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d009--combine--different-people-dedupe-review-buttons-return-404-route-not-wired--the-human-escape-hatch-for-d005d006-is-dead) | POST /doctor/api/duplicate-decision returns 200/201/202 | PR #14 (`archie/d009-dup-decision-contract-test`, HR015) + ledger correction | **RESOLVED 2026-08-09 -- NOT A DEFECT. Verified end-to-end on the shipped v1.0.18 box (192.168.1.210), not inferred.** `/People/duplicates/` -> HTTP 200 carrying **146** `dup-decide` buttons with `dup_decision.js` linked; the served JS uses the literal `http://127.0.0.1:8089/api/v1/wiki/duplicates/decision`; a valid POST returns **200 `{"status":"recorded"}`** and writes `~/.ostler/corrections/duplicates.yaml`. Probe entry removed and the file restored to its pre-probe absent state. Both earlier root causes were WRONG: 'route not wired' (retracted 2026-08-09 overnight) and 'JS posts a relative path -> :8044 -> 501' (retracted now -- `git log -S` proves a relative-path version **never existed** in this file's history). No fix required; no PR. |
| v1018-D010 | Wiki CSS regression: pink bar behind h2 subheadings | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d010--wiki-css-regression-pink-bar-background-behind-h2-subheadings) | no CSS rule sets background on .pw-h2 or h2 | **CM044 #171** (merged) `fix(wiki): namespace heatmap buckets pw-hN to pw-heat-N [v1018-D010]`. Repointed 2026-08-10: the row cited CM044 #6, which is merged but is an incremental-fingerprint change, and was shared as a single wrong pointer by D010/D015/D016. | fixed_in_v1.0.19 (compound `.pw-hc.pw-h2` selector scope + regression test) |
| **v1018-D011 🔴🔴🔴** | "Mum Fairweather" is Robin — display_name derived wrongly + SOURCE of "Mum" is UNKNOWN (Andy did NOT save her as Mum in Contacts) | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md--mystery-about-source-of-mum) | no wiki People page has a display_name that is not a name -- kinship word, bare phone number, email address, placeholder, or empty. **This cell used to read `display_name != given_name + " " + family_name`, which is the predicate the gate block below documents as wrong in both directions and which was replaced there; the cell was left behind, so the table advertised the broken contract while the gate ran the corrected one.** Requires an examined-count control: the People directory must exist and at least one page must be read, or CANNOT RUN. | **CITATION DOES NOT RESOLVE (2026-08-10).** CM041 PR #4 returns 404 and the cited branch 404s (control: `main` resolves). Third row of this cut with an unresolvable citation, after D017 and D018. | open — status corrected from `fixed_in_v1.0.19` 2026-08-10 after the citation failed to resolve. NOTE: the kinship half of this defect IS now fixed and live on the FDA path (CM051 #550 + #552, merged, `_upsert_display_name` has 5 production callers on CM051 main). The canonical-name half is unverified. **THE GATE WAS MEASURING THE RENDER, NOT THE STORE (2026-08-14, TNM).** The page limb reads compiler output; the remedy writes Oxigraph. Joined on `pwg_uri` on the founder box: 14 graph nodes carry a kinship-form displayName, 10 have a person page and the page agrees on all 10, and **4 have no person page at all so the gate could never see them -- 3 of those 4 are the "exact" class where the whole name is a single kinship word, i.e. the gate was blind on its cleanest cases.** The render limb is CORRECT on its own population: 7 flagged of 4915 examined, all 7 confirmed kinship in the graph too, zero false positives. But it reaches 7 of the 12 leading-or-exact cases the store holds, and it examines only 4915 of 7372 subjects that carry a displayName. A store-side limb is now in the gate block, with its own examined-count control and two regex-engine controls; demonstrated RED on the box (render 7, store 12, exit 1) and GREEN by mutation (clean fixture, live store, kinship list swapped for an impossible word, exit 0). **Separately, the gate's own FAIL output printed the full path of every failing page, and a person page's filename IS the person's name -- gate output is pasted into this register. It now prints class plus a truncated hash by default; `OSTLER_GATE_SHOW_PATHS=1` restores paths for whoever is actually fixing them.** |
| **v1018-D012** | RETRACTED — Archie probe error (wrong ontology). Oxigraph HAS 6,325 people. See D012b for the legitimate underlying question. | [v1.0.18 retraction](v1.0.18/DEFECTS_LEDGER.md#v1018-d012--retracted-archie-probe-error-not-a-product-defect) | (n/a — retracted) | (n/a) | RETRACTED — not counted against v1.0.19 |
| v1018-D012b | Verify chat's graph-grounding tool queries correct ontology + named graph (schema.ostler.ai/ontology#Person in urn:ostler:user/Andy, not schema:Person default) | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d012b--verify-chats-graph-grounding-tool-queries-the-correct-ontology--named-graph) | chat returns >0 results for known person when Oxigraph populated | **CITATION WITHDRAWN 2026-08-11.** It was never a fix citation: it read "Verified as part of PR #10 D018 bisect scope ... no separate PR unless bisect finds a distinct defect". That cites a SCOPE, not a change -- and it says outright that no PR exists. **The bisect it rides on was cancelled:** D018 turned out not to be a regression at all, because cross-channel recall was never implemented, so there was nothing to bisect between. A verification that was scoped and then cancelled cannot support a fixed claim. | open -- status corrected from a CONDITIONAL 2026-08-11. The old value was "fixed_in_v1.0.19 (verified as a smoke check) OR filed as v1019-D001 if the bisect surfaces a real gap". That is not a state, it is a branch: the row asserted fixed and not-fixed at once and left the resolution to an event that never happened. **A register row must hold a state, not a plan** -- a conditional cannot be gated, and read by a machine the leading token wins, so this counted as fixed. The verification itself was never performed. |
| v1018-D013 | Wiki quality low: 9,759 orphans / 5,933 thin / 50 topic gaps / 200 missing cross-links | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d013--wiki-quality-low-9759-orphan-pages--5933-thin-pages--50-topic-gaps--200-missing-cross-links) | orphan pages < 2000 | **CITATION WITHDRAWN 2026-08-11, inherited from D005.** It read "Rides on PR #4 + PR #17 (D005 dedupe fix reduces orphan count materially)" -- the same two non-fixes already withdrawn on D005 and D006. `CM041-People-Graph#4` is an OPEN ISSUE about iCloud photo sourcing, not a pull request; `CM051#17` is merged but is "CM046 LaunchAgent piece 3". Third row riding the same pair, which is why one bad citation is never one bad row. | open -- status corrected from `measured_in_v1.0.19` 2026-08-11. Two separate reasons, either sufficient. First, the citations it rode on are withdrawn and D005 itself is now open, so the premise "the D005 dedupe fix reduces orphan count materially" has no fix behind it. Second, the acceptance is a MEASUREMENT and the measurement is not in evidence here: a box measurement of 11,982 orphans against an acceptance of under 2000 was recorded on the unmerged branch for OS003 #26 and has NOT been reproduced on main, so it is carried here as a claim to re-run, not as a result. Re-measure on the box before this row moves again in either direction. |
| **v1018-D014 🔴🔴🔴** | Wiki content-quality bugs: (a) 249 pages with numeric-only summaries, (b) raw prompt scaffolding written instead of output, (c) unfilled {user_email} placeholders | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d014--wiki-content-quality-bugs-a-llm-returns-just-a-number-b-raw-prompt-scaffolding-rendered-instead-of-output-c-unfilled-template-placeholders) | zero numeric-only summaries + zero {placeholder} + zero raw-prompt patterns | PR #7 (CM044 `fix/wiki-d014-content-quality-cluster` — manual port of PR #154) + PR #8 (CM048 `fix/cm048-d014-prompt-scaffolding-echo`) | **UNEVIDENCED** -- source fixes are in (CM044 #7, CM048 #8, CM051 #546/#547), but no box has demonstrated them. Two of this row's three sub-predicates could not fire (OS003 #20), and the founder box today reports 249 / 6 / 29 against code that predates all of them. Re-run the gate on a rebuilt box before this says fixed. Pre-existing damage is NOT repaired by any of those PRs: the 29 summaries and 6 placeholder files on disk stay broken until re-enrichment. **MEASURED ON THE BOX 2026-08-10 (Archie). D014 SPLITS, and the split confirms the delivery-path theory.** (a) **numeric-only summaries: STILL RED.** 249 People pages carry a `pw-summary` block and **all 249 contain a bare integer** -- exactly the 249 originally reported. Verified by masking content (`<div class="pw-summary"><p>999`, line lengths min 28 / median 30 / max 30); an earlier `grep -A2` returned 0 only because the text sits on the SAME line as the div. (b) **raw scaffolding + literal `{user_email}`: GREEN.** Zero template placeholders of `{[a-z_]{3,30}}` shape and zero `user_email` anywhere, against a positive control of **11,722 pages containing a brace**. **Why the split:** D014b/c were fixed in CM051 (#547, #546) -- vendored code that reaches the box on install -- while D014a was fixed in CM044 #174, which ships INSIDE the digest-pinned wiki-compiler image that has not been rebuilt since 2026-08-08. Same cause as D010 + D016; remedy is the `v0.1.8` tag push. Counts only left the box. **RE-MEASURED ON THE BOX 2026-08-10 21:20 HKT (Archie): THE WHOLE GATE IS GREEN, exit 0, a=0 b=0 c=0.** D014a has flipped: 327 People pages now carry a `pw-summary` and **zero** are numeric-only, against 249-of-249 numeric-only when this row was written. Prose length min 52 / median 167 / max 278 characters versus the RED-era min 28 / median 30 / max 30. **Both controls run before believing the green,** because an absence is the reading most often manufactured by a dead predicate: POSITIVE, the predicate has a real population to search (4,918 People pages, 11,838 wiki pages total); NEGATIVE, a planted `<div class="pw-summary"><p>249` file in a temp tree still matches, so the `[0-9]+$` anchor is intact and the line format has not drifted away from it. **The delivery-path blocker this row names is RESOLVED.** The wiki recompiled inside the Docker wiki-compiler image (`ostler-wiki-compiler-run-c231cb3633a8`) from 18:29 to 19:06 HKT, and all 4,918 People pages carry an 19:06:21 mtime, so the image did deliver rather than the fix being applied by hand. The `v0.1.8` remedy is done. Legacy flat-layout debris remains and is reported, not failed: 61 conversations without a narrative and 11 with an unfilled placeholder, all in the pre-migration layout the current writer cannot emit. NOT changing the status cell to fixed in this PR: the gate is green on ANDY'S box, and CM044 #179 (the D014a prompt fix) is still open, so whether this green survives a fresh install with a different data shape is untested. Evidence recorded; the claim stays where it is until TNM rules on #179. **THE NAMED BLOCKER IS DISCHARGED, AND IT WAS DISCHARGED THREE DAYS BEFORE THIS WAS READ (2026-08-14 Archie).** This row ended "the claim stays where it is until TNM rules on #179". **CM044 #179 was MERGED 2026-08-11T14:54:04Z as d423cb37.** So the row has been holding itself open on a ruling that had already happened, the same shape as the OS003 #7 and CM041 one-person-one-name premises found stale the same morning. **AND IT REACHES THE SHIPPING ARTEFACT, verified by CONTENT rather than by ancestry.** d423cb37 is an ancestor of the v1.0.26 wiki pin 562b2ad7 (compare: ahead=11, behind=0), and at that pin `compiler/llm.py` defines `build_person_summary_prompt`, `has_nothing_to_summarise` and `is_none_summary` (1 each), `compiler/pages/person_pages.py` references the shared builder 3 times, and **the drifted inline duplicate prompt is GONE (0 hits for its opening literal)** -- which is the invariant that matters, because #179's whole subject was that a second inlined copy of the prompt was the one that actually ran on a customer box, so the method could be fixed while shipped behaviour never moved. Controls on the same two files return 2 and 5, so the greps were live. **STATUS STILL NOT CHANGED TO FIXED,** and the reason is now precise rather than a pending ruling: the 2026-08-10 21:20 green (a=0 b=0 c=0, both controls run) was measured on the founder box against the founder data shape. Whether it survives a FRESH INSTALL with a different data shape is untested and is exactly what the v1.0.26 box-walk exists to answer. That is the only outstanding input on this row. |
| **v1018-D015 🔴🔴🔴** | Wiki theme uses admonition-style AI-tell callout treatment — BANNED per feedback_no_glowing_callout_admonition_style_anywhere (D010 is a sub-symptom) | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d015--wiki-theme-uses-admonition-style-ai-tell-callout-treatment-banned-per-andys-brand-rules) | shipped wiki CSS has zero admonition-style callout rules + Andy signs off multi-page consistency sweep | **CITATION WITHDRAWN 2026-08-11 -- same shape as D008, right branch, wrong number.** The parenthetical names `fix/wiki-d010-d015-d016-theme-cluster`, which contains this defect's own id and is unmistakably the theme-cluster branch. `CM044#6` is "R3-12: incremental fingerprint catches in-place edits via MAX(created_at)", merged 2026-04-24, touching compiler/incremental.py and its test. **It changes zero CSS.** This row is about wiki theme callout treatment; an incremental-compile fingerprint cannot address it. Checked by FILES, not by title, because the title is what makes these plausible. | open -- status corrected from `fixed_in_v1.0.19` 2026-08-11. The described scope (de-admonize `.pw-summary` and `.pw-doc blockquote`) may well have been written, but the cited PR is not where it landed, so there is nothing here to verify it against. Its acceptance is unchanged and is strong: shipped wiki CSS carries zero admonition-style callout rules, plus Andy's multi-page consistency sign-off. That acceptance has never been run against a located fix. Andy's sign-off is a REQUIRED half of this row and cannot be satisfied by any PR. |
| **v1018-D016 🔴🔴🔴** | Wiki body text + everything sitewide MASSIVE -- type-scale blown out (same class as task #224) | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d016--wiki-body-text--everything-renders-massive--sitewide-type-scale-blown-out) | body font-size ≤ 18px + no raw px text > 24px + Andy signs off multi-viewport sweep | PR #6 (CM044 `fix/wiki-d010-d015-d016-theme-cluster`) | **DELIVERED + VERIFIED ON THE BOX 2026-08-10.** Gate re-run by Archie, extracted verbatim from this file and executed on the founder Mini against the v0.1.8 image (`ostler-wiki-site` `3f8e01f8952d`, `build-20260810-035744`): exit 0. `extra.css:2245` carries an unscoped `html { font-size: 100% !important; }`. **The previous gate body was a FALSE RED** -- it required selector and declaration on one line, and the shipped CSS is ordinary multi-line, so it could never have passed; it would have blocked a cut on a fixed defect. Corrected gate parses the block and additionally holds the unscoped requirement. Controls: unmodified PASS, block-deleted FAIL, re-scoped-to-`.ostler-embed` FAIL. Andy's 13.1 px vs 14 px body-target preference is a separate open question, not a defect. **SCOPE CORRECTED + APP SURFACE NOW MEASURED 2026-08-11 (Archie).** The row says "+ everything sitewide" and cites task #224, which is the app SPA; the gate covered only the wiki and its own heading said so, so a PASS answered half the row and was read as answering all of it. A second limb now measures the surface the app actually renders. **Which surface that is was resolved from RUNTIME CONFIG, not from `strings`:** `apps/tauri/tauri.conf.json` sets `frontendDist = ../../web/dist`, so Tauri EMBEDS the frontend and serves it from `tauri://localhost`; `devUrl` is dev-only and is where the dead `42617` port (task #170) in the shipped binary comes from, harmless in a production build. **Measured on the box:** the shipped SPA stylesheet is 58,668 bytes with 71 `font-size` declarations; the scale is fully tokenised (`--fs-micro` 10 through `--fs-display` 28), `body{font-size:var(--fs-body)}` resolves to **14px**, and there are **zero** raw-px `font-size` declarations, so task #224's untokenised 10-24px scale is genuinely gone. **Six controls run before writing the limb:** shipped build PASS (71 examined); injected `font-size:42px` FAIL; `--fs-body` forced to 32px FAIL; `--fs-body` deleted FAIL; absent directory rc=97; empty stylesheet rc=97 rather than a vacuous green. **The limb was then proven live inside the runner**, not just as a standalone probe, by temporarily lowering the ceiling to 13px and watching the walk go RED after printing `LIMB A (wiki) PASS`. **NOT changing this row to fixed:** its own criterion requires Andy's multi-viewport sign-off, and that has not happened. Evidence recorded; the claim stays where it is. **A SEPARATE defect was found while measuring and is deliberately NOT folded in here:** the daemon at `:8000` serves its SPA index but cannot serve the SPA's assets -- measured on the box over loopback, `/`, `/assets/index-*.js` and `/assets/index-*.css` all return the same 508-byte index page although both files exist on disk. The app never loads from `:8000`, so this is not this row's cause, but it is a live trap for task #228, which wants Ostler.app to stop embedding and always load from the daemon. **THE WIKI LIMB'S PASS WAS TAKEN ON AN IMAGE THIS ROW'S CUT DOES NOT SHIP, AND IS NOW RE-MEASURED AT THE SHIPPING PIN (2026-08-14 Archie).** The 2026-08-10 verification ran against `ostler-wiki-site` `3f8e01f8952d` (CM044 301ee165). v1.0.26 ships `36de411b` (CM044 562b2ad7). Different image, so the earlier PASS does not transfer by inheritance and was not treated as if it did. Re-measured at the SHIPPING source pin 562b2ad7: `mkdocs/overrides/stylesheets/extra.css` is 151,357 bytes and carries the unscoped `html { font-size: 100% !important; }` at line 2245, which is exactly what the corrected gate body requires. So the fix does reach what a v1.0.26 customer installs. **STATUS DELIBERATELY UNCHANGED:** this is evidence, not a green. The row's own criterion is Andy's multi-viewport sign-off and that has still not happened, so nothing here discharges it. Recording it because the heartbeat queue kept re-presenting D016 as an undiagnosed defect ("wiki/app text far too large, Andy screenshotted it") when both limbs are measured and the only outstanding input is a human at a screen. **RELATED, MEASURED THE SAME TICK AND NOT FOLDED IN:** the wiki images this row depends on are now the subject of a fail-closed cut refusal. `verify_cut_freshness.sh` run from CM051 6986dc8 returns `wiki:wiki-compiler` and `wiki:wiki-site` both `RED STALE:+2` (562b2ad7 vs live CM044 HEAD e23611fb, no covering hold_ack row), verdict `GATE: RED ... DO NOT CUT`, with a healthy denominator of fresh=17 held=3 exempt=5. That blocks the NEXT cut, not this row. |
| **v1018-D017 🔴🔴🔴** | **SCOPE NARROWED 2026-08-11 to the channel-scrub WIRING, which is what its gate actually asserts. The customer-visible defect this row was filed for is `v1018-D038` and remains OPEN.** Original report: assistant iMessage rendering leak, raw tool-call syntax reached the customer. Two corrections are kept here so they travel with the claim. **(1) The HTML-entity half is REFUTED** -- `escape_html` exists at exactly two private sites (`telegram.rs:1743`, correct there because that API takes `parse_mode=HTML`, and `report_templates.rs:32`), neither has a cross-channel caller, and `link_enricher.rs:148` only ever UNescapes. No shipped plain-text send path has an escape step that could fail to unescape. What produced `< " >` is unknown and probably unknowable, because the daemon logs no outbound message bodies. **(2) `🤖 ` is the configured message prefix** (`schema.rs:1963`, `imessage.rs:408`), not a renderer, so the leaked text is the model's own reply. | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d017--assistant-imessage-rendering-leak-raw-tool-call-syntax--html-entity-mis-escaping-to-customer) | **The predicate this cell used to name -- "zero raw tool-call or HTML entities in outbound iMessage log" -- is UNMEASURABLE: there is no outbound iMessage log.** The gate below asserts the send path instead: every shipped channel must call the scrub. See its scope note before reading a green as a fixed D017; the real defect is `v1018-D038`. | **`ostler-ai/ostler-assistant#292` MERGED** (`archie/d017-imessage-tool-call-scrub`). This cell read "OPEN, UNSTABLE" until 2026-08-10; it merged, and so did `#296` for the other five send paths. Neither closes `v1018-D038`. | **fixed_in_v1.0.19 -- NARROWED SCOPE ONLY. Read the next sentence before citing this row as closed.** What is closed: every shipped channel's send path now calls `strip_tool_call_tags`. What is NOT closed: a bare `tool_name(args)` reply still reaches the customer on every channel, and that is **`v1018-D038`, OPEN**. **GATE RE-RUN BY ARCHIE 2026-08-11 WITH A DEMONSTRATED RED, which it had never had:** at oa `#292`'s base `52b1ffba` the gate goes RED naming **0 of 6** shipped send paths scrubbing (apple_mail, email_channel, gmail_push, imessage, whatsapp, whatsapp_web); on current oa `main` it is GREEN at **6 of 6**. Same script, two refs, opposite verdicts, so it discriminates. **Two preconditions for anyone re-running it.** (a) Only the `ostler-ai` gh account can read both `ostler-ai/*` and `andygmassey/*`; under the other two every oa read returns empty and the gate exits `FAIL: examined 0 channel send paths`, which is correct fail-closed behaviour, not a flake. (b) To find a pre-fix ref do **not** use `merge_commit_sha`'s parent: oa is rebase-merge, so there is no merge commit and `parents[0]` walks backwards INSIDE the same PR. Doing that returned a RED that was real but mislabelled. Use `.base.sha`, and sanity-check the commit's subject line before quoting it as a before-state. **Prior history of this cell, kept because it is the point:** it read `fixed_in_v1.0.19` citing PR #9 and a branch that 404s; #9 is an unrelated cron-delivery repair merged 2026-05-02. Anyone spot-checking "#9 -- merged? yes" would have confirmed a fix that never landed, which is exactly `v1018-D029`. |
| **v1018-D018 🔴🔴🔴** | Assistant memory doesn't cross channels — macOS Chat memory not reaching iMessage (persistence works within-channel, retrieval fails cross-channel) | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d018--assistant-memory-does-not-cross-channels-macos-chat-memory-not-reaching-imessage) | after chat asserts "X is Y", subsequent iMessage query for "Y" resolves to X (real-box gate) | **CITATION DOES NOT RESOLVE (2026-08-10).** oa #10 is "cron-delivery: piece E", merged 2026-05-02, unrelated; the cited branch 404s (control: `main` resolves). No fix has been located. | open — status corrected from `fixed_in_v1.0.19` 2026-08-10 after the citation failed to resolve. Ungated by design: there is nothing yet to gate. Acceptance stays a real-box two-channel probe. **THE FIX EXISTS, IS WIRED, AND IS IN THE SHIPPING DAEMON (2026-08-14 Archie). This row's "No fix has been located" is REFUTED, and its "Ungated by design: there is nothing yet to gate" is now false.** The row was corrected to `open` on 2026-08-10 when its citation failed to resolve; the fix landed 2026-08-12, so the row was right when written and is two days stale. `install.sh` defaults `OSTLER_ASSISTANT_VERSION` to 0.4.55; tag `hub-v0.4.55` dereferences to commit `e0234e71`, whose subject is `fix(memory): a scoped read hid the user's durable facts (v1018-D018)`, +135/-14 in `crates/zeroclaw-memory/src/sqlite.rs`. **The shipping daemon IS the fix commit.** **MECHANISM, from the commit's own measurement:** the read side was exact-match, `if row.session_id != Some(sid) { skip }`, which skipped every NULL-session row. Durable facts about the user are stored NULL-session BY DESIGN (core, daily), so on the founder box 19 memories included 15 NULL-session rows and **100% of the core category**. **That reframes this row: it was never a peer-to-peer sharing problem. The durable store was invisible to ANY reader that set a session id, and every channel sets one, because the session key is the session-state-file path and two channels never share one.** "Memory does not cross channels" understates it. **THE REMEDY IS A ROW-VISIBILITY PREDICATE, NOT A SQL CHANGE, which is why a grep for the old filter shape finds an absence and nothing else:** `fn session_row_visible(row_session, filter_sid)` returns true for `None` (durable, visible to every reader) and `s == filter_sid` otherwise. **Verified WIRED, not merely defined: four live call sites (sqlite.rs 779, 853, 941, 955) plus its own unit tests asserting own-session-plus-durable and never-another-session.** Presence proved by call site, per the rule that a defined function with no caller is not a fix. **RESIDUAL, FLAGGED NOT CLAIMED:** `vector_search` and `recall_by_time_only` still filter `AND session_id = ?` at SQL level and do not appear to route through the predicate. Whether that matters depends on whether those paths serve user-facing recall, which is NOT established here and is not being called a defect. **STATUS NOT CHANGED TO FIXED.** Rule 5: no gate has been re-run, and the third gate -- does it behave on a real box -- is untested. What changes is that this row now HAS something to gate. Its own acceptance criterion (assert on chat, query on iMessage, real box) is runnable on the v1.0.26 walk, because the fix is in the daemon the DMG installs. Added to the walk plan. |
| **v1018-D019 🔴🔴🔴** | whatsapp-bundle exits 78 (EX_CONFIG) with 0-byte .err+.log — ships dark, MUST-D class in different job | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d019--whatsapp-bundle-launchd-job-exits-78-ex_config-with-zero-byte-err-and-log--ships-dark) | whatsapp-bundle either exits 0 OR writes non-empty log on failure | **CITATION IS THE WRONG SUBSYSTEM (2026-08-10).** CM051 #20 is "Wiki container piece 3: daily wiki-recompile LaunchAgent". Called by DIFF, not title: it touches 5 files, all under `wiki-recompile/`, with ZERO occurrences of "whatsapp" in the whole patch. D019's acceptance is entirely about whatsapp-bundle. | open — status corrected from `fixed_in_v1.0.19` 2026-08-10. Both share the word "launchd", which is why this one needed the diff rather than the title. No whatsapp-bundle logging fix located. |
| **v1018-D020 🔴🔴🔴** | email-bundle SIGKILLed (-9) mid-run — probably memory pressure but UNPROVEN | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d020--email-bundle-sigkilled--9-mid-run) | email-bundle either exits 0 OR SIGKILL cause is logged | **CM051 #539** (merged) `fix(ingest): bound every pwg-convo dispatch [v1018-D020]`. Repointed 2026-08-10: the row cited CM051 #20, which is merged but is the daily wiki-recompile LaunchAgent, and was shared with D019. | fixed_in_v1.0.19 (kill-cause tracing at launchd + install.sh watchdog level; root-cause investigation may spill to v1.0.20 if memory pressure is confirmed) |
| **v1018-D021 🔴🔴🔴** | Email settling throughput broken: 28 conv/hour = 148 days for 100k email install | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d021--email-settling-throughput-broken-28-conversationshour-box-doesnt-settle-in-days) | 6h post-install ≥50% of email conversations have wiki representation | **CM051 #541** (merged) `feat(ingest): every dispatch reports its own duration [v1018-D021]`. Repointed 2026-08-10: the row cited CM046 #21 (does not resolve), CM044 #21 and CM051 #21, none naming this defect. **Re-measured 2026-08-11: #541 is INSTRUMENTATION, not the fix.** Its title is "every dispatch reports its own duration"; it adds a timing workflow, a timing test, and +19/-1 in each of four pipelines. It makes throughput measurable and does not change it. #541 is also the ONLY CM051 PR that has ever referenced D021 (control: the same search finds 6 for D024), and no fast-first-pass or fanout code exists in the source pipelines. The two occurrences of "background enrichment" there belong to the v1.0.3 interactive-chat priority yield, which pauses background work while the user is chatting. **MEASURED AND FIXED 2026-08-14 (Archie): CM051 #662 + CM048 #69.** Ran the real shipping chain (`vendor/email_source` -> `pwg-convo process` -> `vendor/cm048_pipeline`) against a recording Ollama stub on a synthetic .emlx corpus. The number is **6 model calls per email thread** -- 01_classify_email, 02_enrich_email_thread, 03_relationship_signal, 04_coaching, 05_fact_extraction, 09_bundle_extract -- ~27,200 prompt tokens/doc, strictly sequential, one document per `pwg-convo` invocation. 06_speaker_feedback costs 0 on this channel (an email transcript carries real names, so `_unresolved_speaker_labels` returns empty and it short-circuits before the model). **The bottleneck is not that enrichment is slow: it is that `09_bundle_extract`, the ONLY call that produces anything the customer can read, is the LAST of the six.** So time-to-first-readable-page equalled time-to-complete-graph. **D008 interaction settled, not assumed:** the stub records requests in flight and this chain never exceeds ONE, so `OLLAMA_NUM_PARALLEL` cannot move D021 -- a second decode slot is worth nothing to a caller that never asks for two decodes at once. #660 fixes D008 and protects live chat; it does not touch this row. **Found while measuring, needs its own row:** `OSTLER_ENRICH_CONCURRENCY` and `OSTLER_ENRICH_NUM_CTX` are computed and exported by the tier governor and read by NOTHING (zero consumers across CM048 + CM044), while `OllamaClient.generate` pins `num_ctx: 32768` on every call regardless of tier. | **PR open (CM051 #662, CM048 #69), not yet merged.** The fix is a zero-model-call SEED pass that writes the four artefacts before enrichment starts, so a thread is browseable on the tick it arrives and the model rewrites the same folder in place later. 8 tests demonstrated RED on 2deaf9b. Acceptance stays the 6h real-box observation -- a bench is not a box. **Still open after the merge:** the daytime `--since-days` clamp (30 -> 2 outside 01:00-06:00) in `bin/email-bundle-tick.sh` means a customer installing at 10:00 cannot have their historic mailbox READ until the small hours whatever the pipeline costs, so that clamp becomes the binding constraint on this row's acceptance. Scheduling decision, needs Andy. |
| **v1018-D022 🔴🔴🔴** | Chat unusably slow (30-55s/turn) + one full turn failure — not just D008 hang, actual slow | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d022--assistant-chat-unusably-slow-30-55s-per-turn--one-full-turn-failure-all-providersmodels-failed) | 90p chat turn ≤ 15s + zero all-providers-failed in 1h probe | **CITATION IS FROM ANOTHER RELEASE (2026-08-10).** oa #11 is "A7+A8 ostler-consent-gate crate (read-side gate for Rust daemons)", merged 2026-05-03 from `agent/a7-consent-gate-2026-05-03` -- a consent crate against a chat-latency defect, three months before this cut existed. The cited branch `tnm/d022-provider-retry-and-latency-warn` does not exist and has never been the head of any PR (controls: `main`, oa #230 and oa #288 all resolve). Searched the newest 100 PRs, #191-292, which spans the whole v1.0.18/v1.0.19 window: one title match, #216 "model-name-independent retry-on-empty + preload model on config reload" -- an Ollama fix, not the claimed provider retry + backoff + observability. | open -- status corrected from `fixed_in_v1.0.19` 2026-08-10 after the citation resolved to another release. The surviving half of the old status is a DOCS change, not a fix: recording 16 GB as "usable but slow" and 24 GB as recommended does not satisfy this row's acceptance (90p turn <= 15s), it REDEFINES it. Descoping on a hardware floor may well be the right call, but it is a descope and needs recording as one with Andy's sign-off -- never as `fixed`. Acceptance stays as written until he moves it. |
| v1018-D023 | Doctor `/` returns 404 (front door) + box-status busy-loop polled ~1/sec | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d023--doctor-front-door--returns-404-only-apiv1box-status-responds--busy-loop-polling-1sec) | GET / returns 200 or redirect | **CITATION IS FROM ANOTHER RELEASE (2026-08-10).** oa #12 is "consent-gate: wording-drift CI guard + format-string fix", merged 2026-05-03 from `agent/wording-drift-guard-2026-05-03`, 2 files -- a CI wording guard against a Doctor front-door 404. The cited branch `tnm/d023-doctor-front-door-and-polling-backoff` does not exist and has never been the head of any PR (controls resolve). Nothing in #191-292 matches a front-door or polling-backoff fix. | open -- status corrected from `fixed_in_v1.0.19` 2026-08-10. Sixth and seventh rows of this cut carrying a citation that does not resolve. Acceptance here is a one-line probe (`GET /` returns 200 or redirect) and stays exactly as written. |
| **v1018-D024 🔴🔴🔴** | Doctor payload hand-grafted → every later Doctor fix silently misses the cut (the trilemma; MECHANISM behind D009) | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d024--doctor-payload-is-hand-grafted-so-every-later-doctor-fix-silently-misses-the-cut-the-trilemma) | shipped doctor/ == HR015 doctor/ at pinned SHA (no drift) | **BOTH CITATIONS ARE DOCUMENTATION PRs (2026-08-10).** HR015 #15 is "Tech-debt audit doc (2026-04-24)"; the status's second citation, HR015 #2, is "Docs overnight: tech-debt sweep + brand checklist". Neither is a code fix. Cited branch 404s (control: `main` resolves). | open — status corrected from `fixed_in_v1.0.19` 2026-08-10. This row is 🔴🔴🔴 and is the stated MECHANISM behind D009, so a false `fixed` here hides a cause, not just a symptom. No code fix located for either half (auto-vendor, or the cut-time drift assertion). **A CUSTOMER-VISIBLE SYMPTOM OF THIS ROW WAS FIXED 2026-08-14, and the row STAYS OPEN.** Governor then Pause in the Ostler sidebar returned `API 404` on every install: the Hub calls `/api/v1/governor-status`, `/api/v1/pause` and `/api/v1/resume`, HR015 added all three at `6639c79` (#282), and the held doctor pin `b0b3831` predates that commit, so the shipped payload registered none of them. This is precisely the disease this row names, observed downstream. `pause_control.py` plus the four handlers are now grafted into `vendor/doctor/agent` and captured in `doctor.patch`; `box_status._pause()` no longer swallows the missing backend into a permanent `paused: false`; and `tests/test_doctor_governor_routes_vendored.sh` gates all of it, demonstrated RED first. **The graft is a symptom fix and must not be read as closing this row** -- the acceptance here is still `shipped doctor/ == HR015 doctor/ at pinned SHA`, and it is still false: the doctor-path delta is 16 commits, all acknowledged, none re-pinned. The re-pin was measured and declined with reasons rather than skipped, and the measurement is recorded in `vendor/divergences/GOVERNOR_REVENDOR_282.md`: `doctor.patch` applies at the pin with `rc=0` and fails on 9 of 11 files at `origin/main`, so a pin bump is a reconciliation project, and it would additionally pull `51957f4`, a v1.1 Pro-tier surface, into a v1.0 DMG. |
| v1018-D025 | Daemon pin 4 merges behind oa/main; `pinned_artefact_freshness` gate (task #191) still doesn't exist | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md#v1018-d025--daemon-pin-is-4-merges-behind-ostler-assistant-main-pinned_artefact_freshness-gate-task-191-still-doesnt-exist) | every pinned artefact at source-main-HEAD or carries justification | **CITATION CORRECTED 2026-08-11, and the ROW WAS ALSO WRONG.** Measured on `a690a75` with a control. The named primitive is genuinely absent: `pinned_artefact_freshness` appears in 5 `.md` and **0 `.sh`** (control: `pipefail` appears in 15 `.sh`, so the probe is sound). BUT the row concluded about a BEHAVIOUR from a NAME, and the behaviour partly exists: `gates/verify_wiki_image_fresh.sh:53` extracts a pinned `ghcr.io/...@sha256:` digest from install.sh and checks it against a CM044 source fingerprint, and `bin/cut.sh:177` runs CM051 `verify_cut_freshness.sh` as a cut gate. So "never a pinned container digest" is refuted. OS003 #2 was never a fix for this. | open -- corrected 2026-08-11. **The real gap is narrower than the row claimed:** artefact-digest freshness EXISTS for the wiki images; what does not exist is any check that the pinned DAEMON artefact matches its source. That is tracked as HR015 task #227 / D039 (the box cannot honestly say which daemon it runs), not here. Independent corroboration: HR015 task #191 already reads "a cut-time freshness gate ALREADY exists and is wired". |
| **v1018-D035 🔴🔴🔴** | **The locked merge bar is unfalsifiable and rewards the defect it exists to prevent.** The ruleset's bar is *shared exact ID always merges; bar = 0 collisions*. Zero collisions is ALSO what you get from over-merging: two people collapsed onto one node cannot register as a duplicate pair. Limit case: merge all 6,584 people onto one node and the bar reports a flawless graph. Found by TNM 2026-08-09 while disbelieving his own correctly-measured zero. | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md) | Both sides reported together, always: unmerged-pair count AND nodes-carrying-2+-distinct-human-names. Neither number alone is a bar. | Archie (bar shape, RULED) + Andy (thresholds) + task #659 (the over-merge guard itself) | open |
| **v1018-D036 🔴🔴** | **CM044 has 1712 test functions and no CI that runs them, so a render-path change is `CI-green` without a single page having been rendered.** Four workflows exist -- `assistant-name-check`, `operator-pii-scan`, `release-images`, `rule-09-strings-check` -- and not one invokes pytest. `release-images` is tag-only, so a PR gets three checks, none of which executes the compiler. Found 2026-08-10 while reviewing dependabot PRs #151/#152/#153, which are `mergeable=true` with every check green and land squarely on the render path: `compiler/html_sanitise.py` imports `nh3` + `BeautifulSoup` and prefers `lxml`. `lxml` goes `<6.0` -> `>=6.1.1` (MAJOR). And `_ALLOWED_TAGS = set(nh3.ALLOWED_TAGS) \| {...}` reads a module constant from nh3 -- if `0.3.x` changed that set, the post-build sanitiser's allowlist changes silently and markup is stripped from every wiki page. **MEASURED 2026-08-10 (Archie).** Count is **1712 test functions**, not "160+". The nh3 `ALLOWED_TAGS` worry above was **tested and did NOT materialise**: the set is byte-identical between 0.2.18 and 0.3.6 (75 tags, none added, none removed). The row's point stands regardless, because nothing in CI would have reported it either way -- the 5 checks a dependabot PR gets are three string/PII scanners plus one SKIPPED and one never-completed Snyk. Resolution: hand-ran `compiler/tests/test_html_sanitise.py` against origin/main in an isolated venv (16 passed under lxml 5.4.0, identical under 6.1.1, with `_PARSER` asserted `== "lxml"` so the bump was genuinely exercised), then merged **#153** (lxml, CVE-2025-7424 / CVE-2025-11731) and **#152** (nh3); **#151** is rebasing. CM044 **#176** adds the parser-independence tests that were missing, both demonstrated RED. | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md) -- filed 2026-08-10 | CM044 CI runs the compiler suite on every PR AND the check is REQUIRED on main. Must be demonstrated RED first: land it on a branch with a deliberately broken renderer and show the check failing, per the rule that a gate with no demonstrated RED is not a gate. | TNM -- this needs a workflow built, not a review | open |
| **v1018-D037 🔴🔴** | **D017 is not an iMessage defect -- it is per-channel wiring, and three SHIPPED channels still leak tool-call payloads to the customer.** `strip_tool_call_tags` is defined once (`zeroclaw-channels/src/util.rs`) and wired per channel. Call sites on main: telegram 33, discord 2, **imessage 0** (oa #292 fixes it), **whatsapp 0**, **email_channel 0**, **apple_mail 0**. There is no upstream scrub: `zeroclaw-api/src/lib.rs` has zero references and `agent/dispatcher.rs` mentions `tool_call` **37 times while scrubbing none** (that 37 is the positive control). So a model emitting `<tool_call>{...}` as prose reaches the customer verbatim on WhatsApp and both email paths, exactly as it did on iMessage. **Not claimed:** a runtime observation on those channels -- only that no scrub exists on their send paths nor upstream, which is the same evidence that established D017. | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md) -- filed 2026-08-10 | A source-level guard, `every_shipped_channel_scrubs_tool_calls`, asserting every shipped channel's send path calls the scrub. Must be demonstrated RED by running it against current main, where it must name whatsapp + email_channel + apple_mail. **oa #292's comment already claims this guard exists; it does not** -- the name appears once, in that comment, with zero definitions. | TNM (oa) -- the guard, then the three wirings | open |
| **v1018-D038 🔴🔴🔴** | **This is the REAL v1018-D017, split out so it cannot go green behind D037.** A bare `tool_name(args)` reply reaches the customer and nothing catches it, on every channel including the three where the XML scrub has been wired all along. **Demonstrated, not inferred** (probe run against oa main `cd01cca8`, 2026-08-10, `crates/zeroclaw-tool-call-parser`): the observed string yields `calls: 0`, text returned **unchanged**, `detect_tool_call_parse_issue -> None`. Positive control in the same run: a malformed `<tool_call>` payload yields `Some("response resembled a tool-call payload...")`, and a well-formed one yields `calls: 1`, so the probe reaches live code. Negative control: `I checked your calendar (nothing today).` yields 0 candidates. **Second, larger finding:** the detector's own result is DISCARDED. `loop_.rs:1217` binds it as `_parse_issue_detected` and nothing ever reads it, so even when the guard fires the malformed payload is still delivered. Born underscored in upstream commit `4fa47646` (2026-03-05) and never read since. The detector is observability-only by construction. | [v1.0.18](v1.0.18/DEFECTS_LEDGER.md) -- filed 2026-08-10, split from D017 | Source invariants on `ostler-ai/ostler-assistant` main, all three required: (1) `_parse_issue_detected` must not appear in `loop_.rs`; (2) a registry-filtered bare-call recogniser `parse_bare_function_call_syntax` must exist in the parser crate; (3) the observed string must appear in the regression test at `crates/zeroclaw-tool-call-parser/tests/bare_tool_call_never_reaches_customer.rs` -- note the crate-relative path: this cell used to name it repo-root-relative, and an exact-path lookup at the wrong path returns the same empty result as a missing file. Necessary, NOT sufficient -- sufficiency is the named cargo test in oa's own CI, which now runs on push as well as PR. Gate below. | TNM (oa) -- limb B (contain) first, then limb A (recognise)  | **FIXED ON oa main, NOT IN THE SHIPPING PIN -- open FOR THIS CUT.** `oa #299` MERGED 2026-08-10T17:49:37Z, fix commit `f78f56b5` (2026-08-10). All three acceptance invariants above PASS on oa `origin/main`: `_parse_issue_detected` 0 occurrences in `loop_.rs`; `parse_bare_function_call_syntax` present in `crates/zeroclaw-tool-call-parser/src/lib.rs`; the observed string is in `tests/bare_tool_call_never_reaches_customer.rs`. **RESOLVED BY THE 0.4.56 RE-PIN. Re-measured against the CURRENT pin 2026-08-15, not against either earlier claim.** `merge-base --is-ancestor f78f56b5 acf991bf` is TRUE, so the daemon this cut now pins carries the fix. All three acceptance invariants PASS on `acf991bf`: (1) `_parse_issue_detected` 0 occurrences in `loop_.rs`; (2) `parse_bare_function_call_syntax` present in the parser crate; (3) the regression test present at 131 lines. **History kept, because the row was wrong twice and in opposite directions.** It read `fixed_in_v1.0.19` while the shipping artefact did not carry the fix. It was then corrected to "fixed on main, NOT in the shipping pin, open FOR THIS CUT", which was true against pin `782a6195` (2026-08-07, three days older than the fix) and became false the moment the daemon was re-pinned. **Neither error was a wrong verdict about the CODE; both were a verdict about main mistaken for a verdict about the ARTEFACT.** That is the standing lesson: a rollforward row states what the CUT carries, so it must be re-measured against the pin every time the pin moves, and a row asserting `main` is not measuring the thing that ships. **One near-miss worth recording:** invariant (3) first returned zero because the acceptance cell named the test repo-root-relative when it lives under the parser crate. An exact-path lookup returns the same empty result for "wrong path" and "absent", and reporting that zero would have filed a false blocker on a cut that is actually clean. Verdict: fixed_in_v1.0.19, carried by pin `acf991bf`. Measured by TNM 2026-08-15. |

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

**This section is the pipeline's intended input.** The tables above are the human index; the fenced blocks below are what `pipeline/release.yml` WOULD execute if it were wired. It is not (see MUST-FIX-NEXT above), and the extractor that would parse them does not exist either, so today these blocks are run by hand. Authored by Archie, parsed by TNM's extractor (see channel 2026-08-09 03:38 for the agreed contract).

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
[ -n "${CM051_DIR:-}" ] || { echo "CANNOT-RUN: CM051_DIR unset"; exit 97; }
T="$CM051_DIR/tests/test_wiki_tailnet_gate.sh"
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
[ -n "${OA_DIR:-}" ] || { echo "CANNOT-RUN: OA_DIR unset"; exit 97; }
R="$OA_DIR"
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

### v1018-D008 — a live reply is not starved while a background job holds the Ollama slot

```gate id=v1018-D008 expect=0 runs-on=box
# THIS ROW HAD NO GATE AT ALL. It is a triple-red and its acceptance lived only
# as prose, so it has never been measured. Written 2026-08-12 after taking the
# measurement below on the operator box.
#
# WHAT THE ROW SAYS, AND WHERE IT IS WRONG
#
# The row blames "wiki-compile holds the Ollama-slot lock". Measured on the box:
# there was NO wiki-compiler container at all, running or exited. The holder was
# a WhatsApp source tick, and the lock is the shared one every tick wrapper
# uses. So the holder is whichever background job took the slot, not the wiki
# compile specifically, and naming one of them sends a reader to the wrong code.
#
# THE LOCK IS NOT THE DEFECT. It behaves as designed. install.sh's own comment
# states the design premise:
#
#   "Holding the lock for the whole compile keeps background Ollama concurrency
#    at 1, so the 2nd parallel slot is always free for a live reply."
#
# That premise REQUIRES two slots. The same file's resource governor sets
# "OLLAMA_NUM_PARALLEL (2 on LOW/HIGH, 1 on the FLOOR tier)". On the FLOOR tier
# there is one slot, the background job holds it, and the live reply has nowhere
# to go. The mitigation is false by construction on exactly the 16 GB hardware
# this row names.
#
# Measured on the operator box 2026-08-12:
#   running server   OLLAMA_NUM_PARALLEL=1
#   launchd plist    <key>OLLAMA_NUM_PARALLEL</key><string>1</string>
#   holder           whatsapp tick, lock held 1016 minutes, legitimately working
#   ollama access    POST /api/generate 200 in 16.9s / 24.2s / 20.6s
#   live probe       concurrent /api/generate returned 200 in 27s
#
# A NOTE ON THE MEASUREMENT THAT ALMOST WENT WRONG. The holder showed 17 hours
# elapsed against 2.76 seconds of CPU, which is the classic signature of a
# wedged process. It was not wedged. Its child was parked in `sock_recv` on an
# ESTABLISHED socket to 127.0.0.1:11434 and the Ollama access log showed
# generates completing throughout. Low CPU is what a client looks like when the
# work is happening in another process. Both controls were needed.
#
# TWO LIMBS, BECAUSE ONE OF THEM CAN ALMOST NEVER RUN.
# Limb B is the row's stated acceptance and needs a live contender, which is
# rare on demand. Limb A tests the premise the mitigation rests on and runs any
# time. Limb A does not REPLACE the acceptance; the acceptance is unchanged.
LOCK="${OSTLER_INGEST_LOCK:-$HOME/.ostler/workspace/ingest-ollama.lock.d}"
GEN="${OSTLER_D008_GEN_URL:-http://127.0.0.1:11434/api/generate}"
MODEL="${OSTLER_D008_MODEL:-gemma4:e2b}"
BUDGET="${OSTLER_D008_BUDGET_S:-60}"

limb_a() {
    # Read the RUNNING server, not the plist. The plist is intent; the process
    # environment is what is actually in force, and the two have disagreed on
    # this box before (task #177, a plist writing a /tmp path).
    if [ -n "${OSTLER_D008_PARALLEL:-}" ]; then
        np="$OSTLER_D008_PARALLEL"          # test seam for the controls
    else
        opid=$(pgrep -f 'ollama serve' 2>/dev/null | head -1)
        if [ -z "${opid:-}" ]; then
            echo "A: CANNOT RUN: no 'ollama serve' process, so the parallel-slot premise cannot be read from the running server. Not a pass."
            return 97
        fi
        np=$(ps -E -p "$opid" 2>/dev/null | tr ' ' '\n' | sed -n 's/^OLLAMA_NUM_PARALLEL=//p' | head -1)
        # Absent means the Ollama default applies, which has varied by release.
        # Refusing is right: this gate must not guess a number that decides a
        # verdict (v1018-D008).
        if [ -z "${np:-}" ]; then
            echo "A: CANNOT RUN: OLLAMA_NUM_PARALLEL is not set in the running server env, so the effective slot count is the build default and cannot be read here. Not a pass."
            return 97
        fi
    fi
    case "$np" in
        ''|*[!0-9]*)
            echo "A: CANNOT RUN: OLLAMA_NUM_PARALLEL is '$np', not an integer."
            return 97 ;;
    esac
    if [ "$np" -ge 2 ]; then
        echo "A: OK: OLLAMA_NUM_PARALLEL=$np, so a background holder still leaves a slot for a live reply"
        return 0
    fi
    echo "A: FAIL: OLLAMA_NUM_PARALLEL=$np. The whole-run lock is safe ONLY because install.sh promises the 2nd slot stays free for a live reply. With one slot that promise cannot hold, and a live reply queues behind a background generate. (v1018-D008)"
    return 1
}

limb_b() {
    # The row's own acceptance: chat responds within 60s while a background job
    # holds the slot. No contender means the condition the row describes is not
    # present, and a pass measured with nothing running would be meaningless --
    # the same shape as D005 measuring a converged corpus.
    holder=$(cat "$LOCK/pid" 2>/dev/null | tr -d ' \n')
    if [ -z "${holder:-}" ] || ! kill -0 "$holder" 2>/dev/null; then
        echo "B: CANNOT RUN: no live holder of $LOCK, so there is no contention to measure. A fast reply on an idle box says nothing about this row. Not a pass."
        return 97
    fi
    s=$(date +%s)
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$((BUDGET + 30))" \
        -X POST "$GEN" -H 'Content-Type: application/json' \
        -d "{\"model\":\"$MODEL\",\"prompt\":\"Reply with the single word: ok\",\"stream\":false}" 2>/dev/null)
    e=$(date +%s)
    took=$((e - s))
    if [ "$code" != "200" ]; then
        echo "B: FAIL: a live generate returned HTTP $code after ${took}s while pid $holder held the slot"
        return 1
    fi
    if [ "$took" -gt "$BUDGET" ]; then
        echo "B: FAIL: a live generate took ${took}s (budget ${BUDGET}s) while pid $holder held the slot"
        return 1
    fi
    echo "B: OK: a live generate returned 200 in ${took}s while pid $holder held the slot"
    return 0
}

limb_a; A=$?
limb_b; B=$?
if [ "$A" -eq 1 ] || [ "$B" -eq 1 ]; then exit 1; fi
if [ "$A" -eq 0 ] && [ "$B" -eq 0 ]; then exit 0; fi
echo "CANNOT-RUN overall: limb A rc=$A, limb B rc=$B. Neither limb found a defect and at least one could not look, so this is NOT a pass. (v1018-D008)"
exit 97
```

### v1018-D009 — dedupe decision endpoint reachable from the wiki origin

**Note:** the pre-correction gate probed `/doctor/api/duplicate-decision`, a URL that never existed, so it would have failed forever regardless of product state. Corrected to the real route plus the actual defect (the wiki JS posting same-origin).

```gate id=v1018-D009 expect=0 runs-on=box
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d '{"action":"distinct","ids":["gate_probe_a","gate_probe_b"]}' \
  'http://127.0.0.1:8089/api/v1/wiki/duplicates/decision')
case "${code:-}" in 000|"") echo "CANNOT-RUN: no HTTP response from the Doctor on :8089 -- the dup-decision route cannot be judged (v1018-D009)"; exit 97 ;; esac
[ "$code" = "200" ] || { echo "FAIL: real dup-decision route returned $code"; exit 1; }
# grep's code is the verdict; docker failing to run it is not. 0 match, 1 no
# match, anything else means we never read the file (no docker on a
# non-interactive ssh PATH, container down, build path gone).
docker exec ostler-wiki-site sh -c 'grep -qE "8089|DOCTOR_BASE|doctorBase" /site/build-*/javascripts/dup_decision.js'
drc=$?
case "$drc" in
  0) ;;
  1) echo "FAIL: dup_decision.js still posts same-origin (:8044) and will 501"; exit 1 ;;
  *) echo "CANNOT-RUN: could not read dup_decision.js in ostler-wiki-site (rc=$drc) (v1018-D009)"; exit 97 ;;
esac
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

**THIRD CORRECTION, 2026-08-14 (TNM). The gate asserted the RENDER while the
remedy writes the STORE.** Everything above reads
`~/Documents/Ostler/Wiki/People`, which is compiler output. The fix this row
names is an FDA-side repair that writes Oxigraph by SPARQL update. Those are not
the same population, so the gate could go green on a tree that had merely been
recompiled, and could stay green while the store it is standing in for was never
touched.

Measured on the founder box 2026-08-14, joined on `pwg_uri` rather than on the
display value, so a page carrying a DIFFERENT name for the same node could not
be miscounted as an absent page:

```
graph nodes with a kinship-form displayName            14
  of those, node has a person page                     10   page agrees on all 10
  of those, node has NO person page                     4   invisible to the gate
    of those 4, the "exact" class (the whole name
    is a single kinship word, the least ambiguous
    form of the defect)                                 3

person pages examined                                4915
pages the gate flags (leading or exact kinship)         7   all 7 confirmed kinship in the graph too
                                                            0 false positives, 0 wiki-stale artefacts
```

So the render limb is CORRECT on everything it can reach, and reaches 7 of the
12 leading-or-exact cases the store holds. It is blind on its own cleanest ones.
Scale of the blind region: 4915 of 7372 subjects carrying a `displayName` have a
person page, so the gate examines 67% of named subjects and is silent about the
rest.

Two independent instruments agree on the store number, which is why it is stated
as a fact rather than a reading: a Python pass that pulled every `displayName`
and classified it locally, and the SPARQL `REGEX` filter now in the gate. Both
return 12.

The store limb below is therefore ADDITIVE, not a replacement. The customer reads
the render and the repair writes the store; a row that claims to be fixed needs
both. It carries its own examined-count control and two regex-engine controls,
because SPARQL `REGEX` is XPath-flavoured and `\b` is not in the XPath spec -- it
works here only because Oxigraph is backed by the Rust regex crate, and if that
ever changed the kinship query would return 0 and read as clean.

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

# REPORT BY SHAPE, NOT BY VALUE (2026-08-14). The previous line printed the full
# path of every failing page, and a person page's filename IS the person's name.
# Gate output is pasted into this register and into gate-run records, so the gate
# was a route for family names into a repo. It now prints the CLASS and a
# truncated hash, which is enough to tell two failures apart and to confirm a
# later run cleared the same ones. Set OSTLER_GATE_SHOW_PATHS=1 when a human is
# sitting down to fix them and needs to know which file.
if [ "${OSTLER_GATE_SHOW_PATHS:-0}" = "1" ]; then
  printf '%s\n' "$out" | grep '^BAD ' | sed 's/^BAD /  /' | head -20
else
  printf '%s\n' "$out" | grep '^BAD ' | head -20 | while IFS= read -r line; do
    cls=$(printf '%s' "$line" | awk '{print $2}')
    pth=$(printf '%s' "$line" | cut -d' ' -f3-)
    # shasum is present on macOS and on the Linux images this runs against; if
    # it is not, say so rather than printing the path as a fallback.
    if command -v shasum >/dev/null 2>&1; then
      idh=$(printf '%s' "$pth" | shasum | cut -c1-8)
    else
      idh="nohash"
    fi
    echo "  $cls page:$idh"
  done
  [ "${bad:-0}" -eq 0 ] || echo "  (paths withheld: a person page's filename is a person's name. OSTLER_GATE_SHOW_PATHS=1 to see them.)"
fi

# ---------------------------------------------------------------- STORE LIMB
# The loop above reads compiler OUTPUT. The remedy this row names writes
# Oxigraph. Measured 2026-08-14: 4 of the 14 graph nodes carrying a kinship-form
# displayName have no person page at all, so the render limb can never see them,
# and 3 of those 4 are the "exact" class. The gate was blind on its cleanest
# cases. This limb reads the surface the repair actually writes.
OXI="${OSTLER_OXIGRAPH_URL:-${OXIGRAPH_URL:-http://127.0.0.1:7878}}"
ask() { curl -sS -m 60 -G --data-urlencode "query=$1" -H 'Accept: text/csv' "$OXI/query" 2>/dev/null | tr -d '\r' | tail -1; }

total=$(ask 'SELECT (COUNT(DISTINCT ?s) AS ?n) WHERE { ?s <https://schema.ostler.ai/ontology#displayName> ?v }')
alive=$(ask 'SELECT (COUNT(DISTINCT ?s) AS ?n) WHERE { ?s <https://schema.ostler.ai/ontology#displayName> ?v . FILTER(REGEX(STR(?v), "[a-z]", "i")) }')
never=$(ask 'SELECT (COUNT(DISTINCT ?s) AS ?n) WHERE { ?s <https://schema.ostler.ai/ontology#displayName> ?v . FILTER(REGEX(STR(?v), "^zzqqxxnotaword\\b", "i")) }')
store=$(ask 'SELECT (COUNT(DISTINCT ?s) AS ?n) WHERE { ?s <https://schema.ostler.ai/ontology#displayName> ?v . FILTER(REGEX(STR(?v), "^(mum|mummy|mother|dad|daddy|father|wife|husband|gran|granny|grandma|grandad|grandpa|nan|nana|auntie|aunt|uncle|bro|sis|sister|brother|son|daughter|cousin|in-law)\\b", "i")) }')

# A store that cannot be READ is not a store with no defects. Anything that is
# not a bare integer -- an empty body, a SPARQL error page, a connection refusal
# -- is CANNOT RUN, never a pass.
for v in "$total" "$alive" "$never" "$store"; do
  case "$v" in ''|*[!0-9]*)
    echo "CANNOT RUN: $OXI/query did not return a count (got '$v'). A store that cannot be read is not a store with no defects."
    exit 1;; esac
done

# EXAMINED-COUNT CONTROL, store side. The same one the page loop carries: zero
# kinship names over zero names reads identically to zero over seven thousand.
[ "$total" -gt 0 ] || { echo "CANNOT RUN: 0 displayName subjects in $OXI. Not a pass."; exit 1; }

# REGEX-ENGINE CONTROLS, both directions. Without these, an unsupported \b or a
# filter that silently matched nothing would return 0 and read as CLEAN. One
# must find nearly everything; the other must find nothing. The second is also
# the proof that the kinship query CAN return zero, since it is the same query
# shape with a word no name contains.
[ "$alive" -gt 0 ] || { echo "CANNOT RUN: the /[a-z]/ control matched 0 of $total. REGEX is not working, so the kinship count means nothing."; exit 1; }
[ "$never" -eq 0 ] || { echo "CANNOT RUN: the impossible-word control matched $never. The filter is not filtering."; exit 1; }
echo "store: $total displayName subject(s) in $OXI, controls alive=$alive never=$never"

rc=0
[ "${bad:-0}" -eq 0 ] || { echo "FAIL (render): $bad of $examined pages have a display_name that is not a name (kinship word, phone, email, placeholder or empty)"; rc=1; }
[ "${store:-0}" -eq 0 ] || { echo "FAIL (store): $store of $total graph subject(s) have a displayName beginning with a kinship word. These are what the repair must clear; the render limb cannot see the ones with no page."; rc=1; }
[ "$rc" -eq 0 ] || exit 1
echo "GREEN: $examined rendered display_name value(s) and $total stored displayName subject(s) are all names"
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

# 🔴 RAW, NOT contents+base64, AND CANNOT-RUN, NOT FAIL.
# The contents API returns an EMPTY .content for any blob over 1 MB and does
# NOT error. install.sh is 1,369,788 bytes, so this read returned empty on
# EVERY run, the 2>/dev/null hid anything stderr might have said, and the gate
# reported a FAIL -- a finding about the product -- for a measurement it never
# made. Eight lines above, this same gate exits 97 for exactly this situation.
# MEASURED 2026-08-29, with a positive control through the SAME api/ref/token:
#   contents .content length   install.sh (1,369,788 B) -> 1      (empty)
#                              cuts/BOM_PIN (623 B)     -> 847    (real)
#   raw accept header          install.sh               -> 1,369,788 bytes,
#                              carrying all 4 `echo "[channels.` markers.
# It does NOT trade a false FAIL for a false PASS: a path that does not exist
# still 404s loudly under the raw header (negative control run).
inst=$(gh_owner "$CM051_REPO" api "repos/$CM051_REPO/contents/install.sh?ref=$CM051_REF" -H "Accept: application/vnd.github.raw")
inst_n=$(printf '%s' "$inst" | wc -c | tr -d ' ')
echo "read install.sh: ${inst_n} bytes"
# Anti-vacuity FLOOR, not just a non-empty test. This is the control the two
# sibling reads in this registry already carry and this one did not: D017's
# channel loop has an `unread` bucket + a `checked > 0` floor, and D038 asserts
# loop_.rs reads > 100000 bytes. A TRUNCATED read passes `[ -n ]` and then
# reports absent-marker FAILs about a file it only half-saw. install.sh was
# 1,369,788 bytes at v1.0.50; 1000000 leaves room to shrink without a false red.
[ "${inst_n:-0}" -gt 1000000 ] || { echo "CANNOT-RUN: install.sh read as ${inst_n} bytes; it is ~1.37M. The read failed or truncated. Nothing was measured; this is NOT a finding about the product."; exit 97; }

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
echo "LIMB A OK: all $checked shipped send paths scrub tool-call payloads"

# ---------------------------------------------------------------------------

# LIMB B WAS REMOVED 2026-08-12, AND THE REASON MATTERS MORE THAN THE REMOVAL.
#
# Limb B asserted a scrubber named `strip_bare_tool_calls` in util.rs, called by
# every shipped send path, and carried the note "EXPECTED TO BE RED UNTIL THE FIX
# IS BUILT". The fix WAS built -- and deliberately not in that shape.
#
# v1018-D038 (`ostler-ai/ostler-assistant#299`, merged 2026-08-10) closes the
# bare `name(args)` defect by RECOGNISING the call rather than scrubbing it:
# `parse_bare_function_call_syntax` in the parser crate, whose candidates are
# filtered against `tools_registry` so a name only promotes to a real call when
# it matches a registered tool and spans the whole reply. D038's row states the
# product reason for rejecting the scrubber outright:
#
#     "Scrubbing alone is the wrong answer and must not be the fix. It turns a
#      wrong answer into a blank one: the customer asked about a person, the
#      assistant tried to look them up, and scrubbing would leave them with
#      silence."
#
# So limb B demanded an artefact that a correct fix must NOT produce. Measured
# 2026-08-12 on oa main: `strip_bare_tool_calls` 0 hits,
# `parse_bare_function_call_syntax` 3 hits, and the D038 gate GREEN on all three
# of its invariants. Limb B would have stayed RED forever against a working
# product, and the `D017_BARE_FN` override could not have rescued it: the SHAPE
# differs, not merely the name.
#
# Limb B's own closing note anticipated this exactly -- "If a different name is
# chosen, change it HERE in the same PR. A gate that cannot be satisfied by a
# correct fix is worse than no gate." This is that PR. The defect it was standing
# guard over is not dropped: v1018-D038 owns it and has a gate that fires.
#
# This row is now what its own SCOPE NOTE always said it was: the channel-scrub
# WIRING invariant, and nothing more.
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
# IT SAID SO ITSELF. The old line ended "-- cannot test the contract" and then
# exit 1, which the runner reads as "the defect is present". The English was
# right and the exit code contradicted it, exactly as D002 did before it.
[ -r "$TP" ] || { echo "CANNOT-RUN: service token unreadable at $TP -- cannot test the contract (v1018-D003)"; exit 97; }
un=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://localhost:8090/api/v1/people/search?q=test" 2>/dev/null)
au=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "Authorization: Bearer $(cat "$TP")" "http://localhost:8090/api/v1/people/search?q=test" 2>/dev/null)
# 000 is curl saying it never got an answer. A daemon that is not running has
# not "regressed store-auth"; it has not been asked.
case "${un:-}" in 000|"") echo "CANNOT-RUN: no HTTP response from the daemon on :8090 -- store-auth cannot be judged (v1018-D003)"; exit 97 ;; esac
[ "$un" = "401" ] || { echo "FAIL: unauthenticated people/search returned $un, expected 401 -- store-auth has regressed"; exit 1; }
case "${au:-}" in 000|"") echo "CANNOT-RUN: no HTTP response from the daemon on :8090 (authenticated probe) (v1018-D003)"; exit 97 ;; esac
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
# THE DIRECTORIES ARE RESOLVED, AND AN ABSENT ONE IS CANNOT-RUN, NOT A DEFECT.
#
# The previous body opened with
#
#     [ -d "$W" ] || { echo "FAIL: $W absent -- a gate that passes because the
#                      data is missing is not a gate"; exit 1; }
#
# The instinct is right and the exit code is wrong. "The wiki was never
# compiled" and "the wiki is full of LLM slop" are different claims, and this
# row is the second one. A Hub where the compiler has not run yet, or a fresh
# install, reported THIS row's defect. That is the same red-unearned shape
# already fixed on D023, D003, D009 and D016 limb A, and the mirror of D010's
# green-without-looking.
#
# exit 97 keeps the original intent intact: a cut still does not proceed, and
# the message says plainly that this is not a pass. What changes is that it no
# longer accuses the product of a defect it never measured.
W="${OSTLER_WIKI_DIR:-$HOME/Documents/Ostler/Wiki}"
C="${OSTLER_CONV_DIR:-$HOME/Documents/Ostler/Conversations}"

[ -d "$W" ] || { echo "CANNOT-RUN: no wiki at $W -- not compiled on this box, or a fresh install. Nothing was examined, so this is NOT a pass. (v1018-D014)"; exit 97; }
[ -d "$C" ] || { echo "CANNOT-RUN: no conversations at $C -- nothing was examined, so this is NOT a pass. (v1018-D014)"; exit 97; }

# EXAMINED-COUNT CONTROLS. THIS ROW'S OWN HISTORY IS THE ARGUMENT FOR THEM:
# the previous form reported `a=249 b=0 c=0` on a box that carried 6 files with
# unfilled placeholders and 29 metadata-only summaries, because two of the three
# sub-predicates were looking somewhere the defect was not. A zero from a
# predicate that examined nothing is indistinguishable from a clean bill of
# health -- see the "0 violations over 0 files" cases this file has hit twice.
# So each population is counted BEFORE it is judged, and an empty one refuses.
n_w=$(find "$W/People" -type f 2>/dev/null | wc -l | tr -d ' ')
[ "${n_w:-0}" -gt 0 ] || { echo "CANNOT-RUN: 0 files under $W/People -- the wiki carries no person pages, so predicate (a) would report a vacuous 0. This is NOT a pass. (v1018-D014)"; exit 97; }

# The CURRENT-layout population, which is the only one that can be a shipping
# defect: cm048_pipeline/src/conversation_writer.py::_resolve_folder returns
# `base / date_part / folder_name` unconditionally, so the shipping writer
# CANNOT emit a top-level .md. Flat files predate it and are migration debris.
n_c=$(find "$C" -mindepth 2 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
[ "${n_c:-0}" -gt 0 ] || { echo "CANNOT-RUN: 0 conversation artefacts in the current <date>/<slug>/ layout under $C -- predicates (b) and (c) would report a vacuous 0. This is NOT a pass. (v1018-D014)"; exit 97; }
echo "examined: $n_w wiki person file(s), $n_c current-layout conversation artefact(s)"

a=$(grep -rlE '<div class="pw-summary"><p>[0-9]+$' "$W/People/" 2>/dev/null | wc -l | tr -d ' ')
# Split on the same axis as `c` below, and for the same reason: a
# placeholder in a flat legacy artefact is a remnant, one in the Wiki or in
# a <date>/<slug>/ artefact is current output. Counting them together would
# leave this gate failing on migration debris while its message said
# "current layout", which is the mislabelling the split exists to stop.
b=$(grep -rlE '\{[a-z][a-z0-9_]*\}' "$W/" 2>/dev/null | wc -l | tr -d ' ')
b=$((b + $(find "$C" -mindepth 2 -name '*.md' -exec grep -lE '\{[a-z][a-z0-9_]*\}' {} + 2>/dev/null | wc -l | tr -d ' ')))
b_legacy=$(find "$C" -maxdepth 1 -name '*.md' -exec grep -lE '\{[a-z][a-z0-9_]*\}' {} + 2>/dev/null | wc -l | tr -d ' ')
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
# AN UNLOADED AGENT IS NOT A HEALTHY ONE. `launchctl print` fails when the
# label is not loaded, the greps then yield nothing, and `${ec:-0}` turned that
# empty string into "0" -- a clean exit code the service never reported. The
# gate went GREEN on a box where the WhatsApp bundle was not installed at all.
lp=$(launchctl print "gui/$(id -u)/$L" 2>/dev/null); lprc=$?
[ "$lprc" -eq 0 ] || { echo "CANNOT-RUN: $L is not loaded in this user's launchd domain (launchctl rc=$lprc) -- nothing to judge (v1018-D019)"; exit 97; }
ec=$(printf '%s\n' "$lp" | grep -oE 'last exit code = [0-9]+' | grep -oE '[0-9]+$')
[ -n "$ec" ] || { echo "CANNOT-RUN: $L is loaded but reports no last exit code yet (v1018-D019)"; exit 97; }
[ "$ec" = "0" ] && exit 0
se=$(stat -f %z "$HOME/.ostler/logs/whatsapp-bundle.err" 2>/dev/null || echo 0)
sl=$(stat -f %z "$HOME/.ostler/logs/whatsapp-bundle.log" 2>/dev/null || echo 0)
[ "$se" -gt 0 ] || [ "$sl" -gt 0 ] \
  || { echo "FAIL: whatsapp-bundle exited $ec with zero-byte .err AND .log — ships dark"; exit 1; }
```

### v1018-D020 — email-bundle must not be silently SIGKILLed

```gate id=v1018-D020 expect=0 runs-on=box
L=com.creativemachines.ostler.email-bundle
# Same as D019: an unloaded label produced an empty $ec, `${ec:-0}` read it as
# a clean 0, the case matched nothing and the body fell through to GREEN.
lp=$(launchctl print "gui/$(id -u)/$L" 2>/dev/null); lprc=$?
[ "$lprc" -eq 0 ] || { echo "CANNOT-RUN: $L is not loaded in this user's launchd domain (launchctl rc=$lprc) -- nothing to judge (v1018-D020)"; exit 97; }
ec=$(printf '%s\n' "$lp" | grep -oE 'last exit code = [-0-9]+' | grep -oE '[-0-9]+$')
[ -n "$ec" ] || { echo "CANNOT-RUN: $L is loaded but reports no last exit code yet (v1018-D020)"; exit 97; }
case "${ec:-0}" in
  -9|137)
    grep -qE 'email-bundle.*(killed|SIGKILL|terminated)' "$HOME/.ostler/logs/"*.log 2>/dev/null \
      || { echo "FAIL: email-bundle SIGKILLed with no logged reason"; exit 1; } ;;
esac
```

### v1018-D023 — Doctor front door must not 404

```gate id=v1018-D023 expect=0 runs-on=box
# "NO ANSWER" IS NOT "404". Measured 2026-08-12.
#
# The old body had one catch-all arm: anything that was not 200/301/302 became
# `FAIL: Doctor / returned $code`. But curl writes %{http_code} as 000 when it
# never got an HTTP response at all -- Doctor not running, port closed, daemon
# mid-restart, curl missing from a non-interactive ssh PATH. Measured: nothing
# listening gives code=000, curl rc=7, and the old case fell to the FAIL arm.
#
# So a Hub where the Doctor was simply DOWN reported this row's defect, which
# is "the Doctor front door 404s". Those are different claims, and this one is
# worse than a plain false positive: 459aee8c is the fix FOR this row, so a
# false RED here reads as "the front-door fix did not work".
#
# Same shape the runner already names on D016 -- "RED always, with a product
# message it had not earned" -- and the exact mirror of D010, which went GREEN
# when it could not look. 000 means we did not get to ask the question, so it
# is CANNOT-RUN (97), not a verdict.
code=$(curl -sS -o /dev/null -w '%{http_code}' 'http://127.0.0.1:8089/' 2>/dev/null)
rc=$?
case "$code" in
  200|301|302) exit 0 ;;
  000|"")      echo "CANNOT-RUN: no HTTP response from 127.0.0.1:8089 (curl rc=$rc) -- the Doctor is not answering, so its front door cannot be judged (v1018-D023)"; exit 97 ;;
  *)           echo "FAIL: Doctor / returned $code"; exit 1 ;;
esac
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
# THIS GATE USED TO RETURN GREEN WITHOUT LOOKING. Measured 2026-08-12.
#
# The old body was `docker exec ... >/dev/null 2>&1 && { echo FAIL; exit 1; }`.
# When `docker` is not on PATH -- which is exactly what happened to every box
# gate, because a non-interactive ssh shell does not source the login profile
# and docker is a Homebrew binary -- the command fails, the `&&` never fires,
# and the body falls through to `exit 0`. GREEN. It reported the defect FIXED
# having never opened the file, and `>/dev/null 2>&1` swallowed the reason.
#
# Proven, not argued: running the old body with docker off PATH gives rc=0 and
# empty output. The runner expects 0, so it printed GREEN.
#
# This matters more than one row: the registry cites D010 as its model negative
# control ("pre-fix -> RED, fixed -> GREEN, shown in CM044 #171"). That control
# was demonstrated in a shell that HAD docker. The control was real; the
# environment it was proved in was not the one it runs in.
#
# grep's exit code IS the verdict, so it must not be discarded:
#   0  -> the colliding rule is present  -> defect present, FAIL
#   1  -> no match                       -> defect absent, PASS
#   >1 -> grep errored, or docker could not run it (126/127, container down,
#         build path gone) -> WE DID NOT LOOK. rc=97 is the runner's declared
#         CANNOT-RUN vocabulary, and it is NOT a pass.
out=$(docker exec ostler-wiki-site sh -c \
  'grep -nE "^\.pw-doc \.pw-h2\{background" /site/build-*/stylesheets/extra.css' 2>&1)
rc=$?
case "$rc" in
  0) echo "FAIL: bare .pw-doc .pw-h2 background rule still collides with the section-heading class"
     printf '%s\n' "$out"; exit 1 ;;
  1) exit 0 ;;
  *) echo "CANNOT-RUN: could not evaluate the rule (rc=$rc)"; printf '%s\n' "$out"; exit 97 ;;
esac
```

### v1018-D016 -- type scale not inflated, and the gate was measuring the wrong bundle

**SCOPE CORRECTED 2026-08-11.** The row says "Wiki body text **+ everything
sitewide** MASSIVE" and cites task #224, which is about the **app SPA**, not the
wiki. The gate covered only the wiki, and its own heading said so. So a PASS was
answering half the row and being read as answering all of it. The wiki limb was
correct and is unchanged; a second limb now measures the app surface.

**PREMISE CORRECTED 2026-08-12, and this is the more serious of the two.** Limb
B pointed at

    ~/.ostler/OstlerAssistant.app/Contents/Resources/web/dist

and its comment claimed that was the Tauri app's embedded frontend, resolved
from `apps/tauri/tauri.conf.json` (`frontendDist = ../../web/dist`, served from
`tauri://localhost`). **That bundle is not the app. It is the DAEMON.** Measured
on the box:

    CFBundleIdentifier   ai.ostler.assistant
    LSUIElement          true            background agent, it has no window
    linked libraries     5, none of them WebKit
    strings              daemon config schema, gateway, provider list

The `tauri://localhost` inside it is the gateway's **Host-header allowlist for
DNS-rebind protection**, not evidence of a WebView. The row already recorded
that reading the executing surface out of `strings` was the earlier mistake
here; resolving it from a config file in the SOURCE repo, and then never
checking which BUNDLE on the box that config produced, reproduced the same error
one level up.

**The GUI is a different bundle:**

    /Applications/Ostler.app
    CFBundleIdentifier   ai.creativemachines.ostler-hub
    executable           ostler-hub, WebKit-linked
    assets               COMPILED IN, not files on disk
    OSTLER_HUB_BUILD_COMMIT  782a6195

**THE TWO FRONTENDS ALREADY DISAGREE.** Measured the same minute:

    GUI     index-BKje6gr0.js   +   index-C3vVbOBz.css
    daemon  index-BJGHlmN_.js   +   index-C3vVbOBz.css

**Same stylesheet, different script.** Vite content-hashes these filenames, so
an equal name means equal bytes: the daemon's on-disk copy is a faithful stand
in for the compiled-in stylesheet TODAY, which is why the old limb B's verdict
was nonetheless correct for the surface Andy actually looks at. It was right by
luck, not by construction. The JS shows the two payloads can and do drift, and
nothing stopped the CSS drifting the same way, at which point the old limb would
have reported a confident verdict about a file nothing renders.

So the limb now resolves the stylesheet NAME out of the GUI binary's embedded
asset registry and **refuses (97) unless the daemon copy carries that exact
content hash.** Divergence becomes a loud cannot-run instead of a wrong answer.

**BOTH LIMBS NOW ALWAYS RUN, WORST VERDICT WINS.** The old body ran limb A first
and exited on its result, so a CANNOT-RUN from limb A silently deleted the
app-surface measurement, which is the exact limb the scope correction added.
Measured 2026-08-12: limb A returned 97 (docker is not on a non-interactive ssh
PATH) on a box where the app surface was perfectly measurable. FAIL beats
CANNOT-RUN beats PASS, so neither limb can launder the other.

**MEASURED ON THE BOX 2026-08-12, re-run rather than inherited.** The shipped
stylesheet is 58,668 bytes with 71 `font-size` declarations, fully tokenised:

    --fs-micro 10   --fs-caption 11   --fs-caption-lg 12   --fs-body-sm 13
    --fs-body  14   --fs-body-lg 16   --fs-heading-sm  18  --fs-heading-md 20
    --fs-heading-lg 24                --fs-display     28

`body{font-size:var(--fs-body)}`, so body text is **14px**, and no literal in
the file renders above 16px. Task #224's untokenised 10-24px scale is genuinely
gone. Nothing here is "MASSIVE", on either surface the row names.

**WHY THE GATE DOES NOT USE THE ROW'S LITERAL "no raw px text > 24px".** Taken
literally that fails on `--fs-display:28px`, an ordinary display-heading size.
Fitting the threshold to make the current build pass would be encoding the
answer into the gate. The limb asserts the two things the defect was actually
about: body text at or below 18px, and nothing rendering above a 32px ceiling in
any unit.

**CONTROLS, all fifteen run on the box 2026-08-12 before this was written:**

| # | control | rc |
|---|---|---|
| 0 | shipped artefact, unmodified | **0 PASS** |
| 1 | inject `.leak{font-size:42px}` | 1 |
| 2 | `--fs-body` set to 32px | 1 |
| 3 | `--fs-body` token deleted | 1 |
| 4 | `4rem` = 64px (TNM's rem hole) | 1 |
| 5 | `3em` = 48px | 1 |
| 6 | `400%` = 64px | 1 |
| 7 | `--fs-display:5rem` = 80px | 1 |
| 8 | absent SPA dist | 97 |
| 9 | empty stylesheet | 97 |
| 10 | absent GUI bundle | 97 |
| 11 | GUI binary names no stylesheet | 97 |
| 12 | GUI binary names two stylesheets | 97 |
| 13 | GUI and daemon stylesheets diverged | 97 |
| 14 | limb A toolchain down | **97, and limb B still measured and reported** |

Controls 4 to 6 are the unit hole TNM demonstrated 2026-08-11: a stylesheet
where everything is `4rem` is literally "everything sitewide MASSIVE" and the
first version of this limb passed it with "raw px declarations: 0", because it
counted NOTATION instead of measuring SIZE. Same family as this row's original
false RED, which required a selector and its declaration on one line. Controls 8
to 13 are the ones that matter most: `find`-shaped gates in this file have twice
reported "0 violations" over 0 examined files, and 8 and 13 are deliberately
distinguished so that "there is no dist" never reports as "the frontends have
diverged".

**WHAT THIS LIMB NO LONGER CATCHES, stated rather than buried.** Moving from
"count raw px literals" to "nothing renders above 32px" is a real loosening: raw
px DRIFT alongside the tokens now passes. Every value in task #224's original
scale was 24px or less, comfortably inside the ceiling, so only the total
absence of tokens gives that defect away, and B1 catches that. Accepted
deliberately, because this row is about things being MASSIVE and a ceiling
measures massive. If #224 recurs, add a non-blocking raw-px count beside this so
drift is visible without failing a cut on a 20px literal.

**A SEPARATE DEFECT, deliberately NOT folded into D016, re-verified live
2026-08-12.** The daemon at `:8000` serves its SPA index but **cannot serve the
SPA's assets**. Measured on the box over loopback, not over the LAN:

    GET /                            200  text/html  508
    GET /assets/index-BJGHlmN_.js    200  text/html  508
    GET /assets/index-C3vVbOBz.css   200  text/html  508

All three return the same 508-byte index page, i.e. the catch-all, although both
asset files exist on disk. A browser pointed at `:8000` therefore gets no CSS
and no JS and renders unstyled at the UA default size, **which looks exactly
like this row's symptom**. It is not this row's cause, because the app renders
its own compiled-in copy. It IS a live trap for task #228, which wants Ostler.app
to stop embedding and "ALWAYS load from daemon :8000": executing #228 today would
migrate a working embedded frontend onto a broken served one. Tracked as task
#319, filed separately rather than smuggled into a green.

### v1018-D016 -- wiki limb: type scale not inflated in a standalone browser

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
# BOTH LIMBS ALWAYS RUN, AND THE WORST VERDICT WINS.
#
# The previous body ran limb A first and exited on its result, so a CANNOT-RUN
# from limb A (docker down, container gone) silently removed the APP-surface
# measurement -- the very limb the 2026-08-11 scope correction added because the
# row names the app and the gate only covered the wiki. A toolchain outage on
# the wiki side must not decide the app question. Measured 2026-08-12: limb A
# returned 97 on a box where the app surface was perfectly measurable.
#
# FAIL beats CANNOT-RUN beats PASS, so neither limb can launder the other.

# ---------------------------------------------------------------------------
# LIMB A -- the WIKI surface in a standalone browser.
# ---------------------------------------------------------------------------
limb_a() {
	CSS=$(docker exec ostler-wiki-site sh -c 'ls -d /site/build-*/stylesheets/extra.css 2>/dev/null | tail -1')
	[ -n "$CSS" ] || { echo "A: CANNOT-RUN: no extra.css in ostler-wiki-site -- toolchain, not defect. This is not a pass. (v1018-D016)"; return 97; }
	# awk's exit code is the verdict (0 found, 1 not found). Anything else means
	# docker never ran it -- no docker on a non-interactive ssh PATH, container
	# down, path gone.
	docker exec ostler-wiki-site sh -c "awk '
	  /^html[[:space:]]*\{/ { inblk=1; next }
	  inblk && /font-size:[[:space:]]*100%/ { found=1 }
	  inblk && /\}/ { inblk=0 }
	  END { exit !found }
	' $CSS"
	arc=$?
	case "$arc" in
		0) ;;
		1) echo "A: FAIL: no UNSCOPED html{ ... font-size:100% ... } -- browser view still inherits Material 125%"; return 1 ;;
		*) echo "A: CANNOT-RUN: could not evaluate $CSS in ostler-wiki-site (rc=$arc). This is not a pass. (v1018-D016)"; return 97 ;;
	esac
	echo "A: LIMB A (wiki) PASS"
	return 0
}

# ---------------------------------------------------------------------------
# LIMB B -- the APP surface.
#
# WHICH BUNDLE IS "THE APP", MEASURED 2026-08-12 rather than assumed.
# The previous body pointed at
#     ~/.ostler/OstlerAssistant.app/Contents/Resources/web/dist
# and its comment claimed that was the Tauri app's embedded frontend. IT IS NOT.
# That bundle is the DAEMON:
#     CFBundleIdentifier  ai.ostler.assistant
#     LSUIElement         true          (background agent, no window)
#     linked libraries    5, none of them WebKit
#     strings             daemon config schema, gateway, provider list
# The `tauri://localhost` inside it is the gateway's Host-header ALLOWLIST for
# DNS-rebind protection, not evidence of a WebView. Reading that string as
# "this is the Tauri app" is the same mistake the row already recorded once.
#
# The GUI is a DIFFERENT bundle:
#     /Applications/Ostler.app
#     CFBundleIdentifier  ai.creativemachines.ostler-hub
#     executable          ostler-hub, WebKit-linked
#     assets              COMPILED IN (index-*.js / index-*.css, brotli, not files)
#
# So the stylesheet that governs what Andy sees is the one compiled into
# /Applications/Ostler.app, and it CANNOT be read off disk. What can be read is
# the asset NAME in the embedded registry, and Vite content-hashes that name.
# Equal name therefore means equal bytes, which lets the on-disk daemon copy
# stand in for the compiled-in one -- but ONLY once that equality is checked.
#
# THIS IS NOT THEORETICAL. On the box today the two frontends already disagree:
#     GUI    index-BKje6gr0.js  +  index-C3vVbOBz.css
#     daemon index-BJGHlmN_.js  +  index-C3vVbOBz.css
# Same CSS, DIFFERENT JS. The old limb B measured the daemon's copy while
# claiming to measure the GUI's, and it was right today only by luck. When the
# CSS diverges the way the JS already has, this limb REFUSES instead of
# reporting a verdict about a file nothing renders.
# ---------------------------------------------------------------------------
limb_b() {
	GUI="${OSTLER_GUI_APP:-/Applications/Ostler.app}"
	SPA="${OSTLER_SPA_DIST:-$HOME/.ostler/OstlerAssistant.app/Contents/Resources/web/dist}"

	[ -d "$GUI" ] || { echo "B: CANNOT RUN: no GUI bundle at $GUI -- cannot resolve the surface the customer looks at. This is not a pass."; return 97; }
	gui_bin=$(ls "$GUI"/Contents/MacOS/* 2>/dev/null | head -1)
	[ -n "$gui_bin" ] || { echo "B: CANNOT RUN: no executable in $GUI/Contents/MacOS. This is not a pass."; return 97; }

	# The embedded asset registry stores KEYS uncompressed even though the asset
	# BODIES are brotli'd, so the name is readable. If a future toolchain stops
	# emitting readable keys this yields nothing, and nothing must mean REFUSE.
	gui_css=$(strings -a "$gui_bin" 2>/dev/null | grep -oE 'index-[A-Za-z0-9_-]+\.css' | sort -u)
	n_css=$(printf '%s' "$gui_css" | grep -c . || true)
	[ "${n_css:-0}" -eq 1 ] || { echo "B: CANNOT RUN: resolved ${n_css:-0} embedded stylesheet name(s) in $(basename "$gui_bin"), need exactly 1. This is not a pass."; printf '%s\n' "$gui_css" | sed 's/^/      /' | head -5; return 97; }
	echo "B: GUI embeds $gui_css"

	# ABSENT DIST AND DIVERGED DIST ARE DIFFERENT FAULTS AND MUST SAY SO.
	# Without this the next check reports "the two frontends have DIVERGED" when
	# the truth is there is no dist directory at all, sending the reader after a
	# frontend-parity bug that does not exist.
	[ -d "$SPA/assets" ] || { echo "B: CANNOT RUN: no SPA assets dir at $SPA/assets. This is not a pass."; return 97; }

	# THE PARITY CHECK. The daemon's on-disk copy may only stand in for the
	# compiled-in stylesheet when it IS the same content-hashed file.
	css="$SPA/assets/$gui_css"
	[ -f "$css" ] || { echo "B: CANNOT RUN: the GUI embeds $gui_css but the daemon dist at $SPA/assets does not carry it -- the two frontends have DIVERGED, and the GUI's stylesheet cannot be read off disk. This is not a pass. (task #228)"; return 97; }

	# EXAMINED-COUNT CONTROL. A stylesheet whose format has drifted would yield
	# zero matches and report a clean bill of health over nothing examined.
	decls=$(tr '}' '\n' < "$css" | grep -cE 'font-size:')
	echo "B: examined $decls font-size declaration(s) in $gui_css"
	[ "${decls:-0}" -ge 20 ] || { echo "B: CANNOT RUN: only ${decls:-0} font-size declarations -- format drifted, gate is blind. This is not a pass."; return 97; }

	# B1. Body text stays at or below 18px. This is the row's own criterion.
	fsbody=$(tr '{;' '\n\n' < "$css" | grep -oE '^[[:space:]]*--fs-body:[0-9]+px' | grep -oE '[0-9]+' | head -1)
	[ -n "$fsbody" ] || { echo "B: FAIL: no --fs-body px token defined -- the type scale has no body anchor"; return 1; }
	echo "B: --fs-body = ${fsbody}px"
	[ "$fsbody" -le 18 ] || { echo "B: FAIL: --fs-body is ${fsbody}px, above the 18px body ceiling (v1018-D016)"; return 1; }

	# B2. NOTHING RENDERS ABOVE A 32px CEILING, in ANY unit.
	#
	# MEASURE THE RENDERED SIZE, NOT THE NOTATION. The first version counted `px`
	# literals only; TNM demonstrated the hole 2026-08-11 with a stylesheet where
	# everything is `4rem` (64px at a 16px root, literally "everything sitewide
	# MASSIVE") that passed with "raw px declarations: 0". Same family as this
	# row's ORIGINAL false RED, which required a selector and its declaration on
	# one line: a predicate pinned to one RENDERING of the defect, not the defect.
	#
	#     Npx -> N        Nrem -> N*16        Nem -> N*16        N% -> N/100*16
	#
	# 32px because the shipped scale tops out at --fs-display 28px. NOT fitted to
	# make the current build pass: the build's largest literal is 16px, so the
	# ceiling could be 20 and still pass. It is set where a heading stops being a
	# heading. var(--*) is exempt BY DESIGN -- that is the tokenised path this row
	# wants, and the token DEFINITIONS are checked by B1 plus the loop below.
	#
	# WHAT THIS NO LONGER CATCHES, stated rather than buried: raw px DRIFT
	# alongside the tokens. Every value in task #224's original scale was 24px or
	# less, comfortably inside this ceiling, so only the total absence of tokens
	# gives that defect away -- and B1 catches that. Accepted deliberately: this
	# row is about things being MASSIVE, and a ceiling measures massive.
	ceiling=32
	over=$(tr '}' '\n' < "$css" \
	  | grep -oE 'font-size:[[:space:]]*[0-9.]+(px|rem|em|%)' \
	  | grep -oE '[0-9.]+(px|rem|em|%)' \
	  | awk -v c="$ceiling" '
	      { n=$0+0; u=$0; sub(/^[0-9.]+/,"",u)
	        if (u=="px") v=n; else if (u=="rem"||u=="em") v=n*16; else if (u=="%") v=n/100*16; else next
	        if (v > c) print $0" = "v"px" }')
	n_over=$(printf '%s' "$over" | grep -c . || true)
	echo "B: font-size literals over ${ceiling}px: ${n_over:-0}"
	[ "${n_over:-1}" -eq 0 ] || {
		echo "B: FAIL: ${n_over} font-size literal(s) render above ${ceiling}px -- this is the sitewide blow-out (v1018-D016)"
		printf '%s\n' "$over" | sed 's/^/      /' | head -8
		return 1; }

	# AND the token definitions themselves must not blow out, in any unit.
	tok_over=$(tr '{;' '\n\n' < "$css" \
	  | grep -oE '^[[:space:]]*--(fs|text)-[a-z0-9-]+:[[:space:]]*[0-9.]+(px|rem|em)' \
	  | grep -oE '[0-9.]+(px|rem|em)' \
	  | awk -v c="$ceiling" '{ n=$0+0; u=$0; sub(/^[0-9.]+/,"",u); v=(u=="px")?n:n*16; if (v>c) print $0" = "v"px" }')
	n_tok=$(printf '%s' "$tok_over" | grep -c . || true)
	echo "B: type-scale tokens over ${ceiling}px: ${n_tok:-0}"
	[ "${n_tok:-1}" -eq 0 ] || { echo "B: FAIL: ${n_tok} type-scale token(s) render above ${ceiling}px (v1018-D016)"; printf '%s\n' "$tok_over" | sed 's/^/      /' | head -8; return 1; }
	echo "B: LIMB B (app SPA) PASS"
	return 0
}

limb_a; A=$?
limb_b; B=$?
echo "verdicts: limbA=$A limbB=$B"
if [ "$A" -eq 1 ] || [ "$B" -eq 1 ]; then exit 1; fi
if [ "$A" -eq 0 ] && [ "$B" -eq 0 ]; then exit 0; fi
exit 97
```

### v1018-D026 — Part 2: cuts must be tag-triggered and gate-enforced

**THE PIPELINE EXISTS AND THE GATE COULD NOT SEE IT (corrected 2026-08-12).** The
property this row asserts has been satisfied since `cut.yml` was written -- that file's
own header opens "addresses v1018-D026 (Part 2)". The gate reported it missing for
**three independent reasons, none of them the defect**:

    1. WRONG FILENAME. It looked for `.github/workflows/release.yml`. The pipeline is
       `cut.yml`. No file named release.yml exists in CM051, and none exists under
       `.github/workflows/` in OS003 either. **OS003 does have `pipeline/release.yml`**,
       which is exactly why this is worth stating precisely: it exists, it is cited above
       as the thing that gates the cut, and being outside `.github/workflows/` it never
       runs. Checking only whether the name exists gives the wrong answer in both
       directions.

    2. NO `cd "${CM051_DIR}"`. Every other runs-on=repo gate cds into the repo it
       measures. This one did not, so it grepped the OS003 checkout, which holds
       exactly one workflow (gates.yml) and never held a cut pipeline at all.

    3. AND THE SHARPEST ONE: `grep -q workflow_dispatch` matched the COMMENT that
       documents its absence. cut.yml line 11 reads:

           # There is deliberately no `workflow_dispatch`. A manually-fired
           # pipeline is a hand-cut wearing a costume [...]

       So even pointed at the right file in the right repo, the gate would have failed
       it with "workflow_dispatch present -- a hand-cut in a costume". **It failed the
       file for stating its own compliance.** A substring search cannot tell a trigger
       key from prose about a trigger key.

That is the fifth notation-pinned false RED in this registry (D016 twice, D028, D032,
now this). **The corrected gate resolves the cut pipeline BY PROPERTY** -- the workflow
whose trigger is a `v1.0.*` tag push -- and strips comments before every assertion, so
prose can neither satisfy a requirement nor trip a prohibition.

Demonstrated discrimination, five inputs, five distinct verdicts:

    shipped state                        PASS, "examined 22 workflow(s)", names cut.yml
    workflow_dispatch as a REAL key      FAIL "accepts workflow_dispatch"
    rollforward step removed             FAIL "never runs the rollforward gate"
    tag trigger -> pull_request          FAIL "no workflow is triggered by a v1.0.* tag push"
    empty / absent workflows dir         CANNOT-RUN (97), not a vacuous pass

The comment on line 11 is still present in the shipped file and the gate now passes it,
which is the specific regression control for reason 3.

```gate id=v1018-D026 expect=0 runs-on=repo
# Cuts must be tag-triggered and gate-enforced. See the note above for why this
# body resolves the pipeline BY PROPERTY rather than by filename, and why every
# assertion runs against a comment-stripped copy.
[ -n "${CM051_DIR:-}" ] || { echo "CANNOT-RUN: CM051_DIR unset"; exit 97; }
cd "$CM051_DIR" || { echo "CANNOT-RUN: cannot cd to CM051_DIR=$CM051_DIR"; exit 97; }
wfdir=".github/workflows"
[ -d "$wfdir" ] || { echo "CANNOT-RUN: no $wfdir in $PWD (v1018-D026)"; exit 97; }
n_wf=$(ls "$wfdir"/*.yml "$wfdir"/*.yaml 2>/dev/null | wc -l | tr -d ' ')
[ "${n_wf:-0}" -gt 0 ] || { echo "CANNOT-RUN: $wfdir holds no workflows (v1018-D026)"; exit 97; }
echo "examined $n_wf workflow(s)"
cut_wf=""
for f in "$wfdir"/*.yml "$wfdir"/*.yaml; do
  [ -f "$f" ] || continue
  body=$(sed 's/#.*//' "$f")
  printf '%s\n' "$body" | grep -qE '^[[:space:]]*tags:[[:space:]]*$' || continue
  printf '%s\n' "$body" | grep -qE "^[[:space:]]*-[[:space:]]*'?v1\.0\.\*'?[[:space:]]*$" || continue
  cut_wf="$f"; break
done
[ -n "$cut_wf" ] || { echo "FAIL: no workflow is triggered by a v1.0.* tag push -- there is no gate-enforced cut pipeline (v1018-D026)"; exit 1; }
echo "cut pipeline: $cut_wf"
body=$(sed 's/#.*//' "$cut_wf")
# 🔴 THE TRIGGER LIST IS NOT THE SAFETY PROPERTY. THE JOB GUARD IS.
# This limb used to FAIL any cut workflow that merely DECLARED a
# workflow_dispatch. CM051's cut.yml declares one deliberately, for a DRY-RUN
# job that runs the checks and stops. What must never happen is a dispatch
# REACHING the cutting job, and that is decided by the job's `if:`.
#
# Reading the trigger list alone is wrong in BOTH directions: it calls a safe
# file unsafe, and it would call a file SAFE that declared no dispatch while
# leaving its cut job unguarded.
#
# NOT "every job must be guarded" either -- that is a third wrong predicate.
# cut.yml's `preflight` job legitimately carries no guard because running the
# checks on either trigger is correct and harmless. The dangerous shape is a
# file with two triggers and NO discrimination anywhere.
#
# MUTATION-TESTED 2026-08-29 on the real CM051 cut.yml, three arms:
#   real file                      -> PASS   (guard present)
#   guard line deleted             -> FAIL   (mutation verified applied, 1 -> 0)
#   workflow_dispatch line deleted -> PASS   (no dispatch, old behaviour kept)
#
# AND THE COMMENT-STRIP WAS VERIFIED, NOT ASSUMED. cut.yml's prose now
# discusses this guard, so the raw file matches the guard text 4 times. After
# `sed 's/#.*//'` exactly 1 survives, and it is the real `if:`. Prose about a
# guard therefore cannot manufacture a pass. That check matters because this
# gate's own post-mortem records comment-matching as a defect it already had.
if printf '%s\n' "$body" | grep -qE '^[[:space:]]*workflow_dispatch[[:space:]]*:'; then
  printf '%s\n' "$body" | grep -qE "^[[:space:]]*if:.*github\\.event_name[[:space:]]*==[[:space:]]*'push'" || {
    echo "FAIL: $cut_wf declares workflow_dispatch and NO job is gated on github.event_name == 'push' -- a manual run could reach the cutting job (v1018-D026)"; exit 1; }
  echo "workflow_dispatch is declared, and a push-only job guard discriminates it"
fi
printf '%s\n' "$body" | grep -q 'rollforward' || {
  echo "FAIL: $cut_wf never runs the rollforward gate (v1018-D026)"; exit 1; }
echo "tag-triggered, no manual dispatch, runs the rollforward gate"
exit 0
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
[ -n "${CM051_DIR:-}" ] || { echo "CANNOT-RUN: CM051_DIR unset"; exit 97; }
mk="$CM051_DIR/gui/Makefile"
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

**THE PREDICATE MEASURED ONE SPELLING, NOT THE PROPERTY (corrected 2026-08-11).**
The original body accepted only `gh api repos/`. It reported **5 of 6 specs failing,
and 3 of those 5 were FALSE REDS** -- they had queried the remote, in a spelling the
regex did not recognise:

    D005_D011        gh api /search/code?q=repo:...        2 queries
    D009             gh api .../contents/...?ref=main      route confirmed at line 2298
    D010_D015_D016   gh api repos/.../branches --paginate  the ONLY accepted form

That is the same family as this registry's other notation bugs: D016's original false
RED (selector and declaration required on one line) and its `px`-only ceiling that a
`4rem` blow-out walked straight through. **Notation is not the property.**

The three genuine failures were then verified at source rather than retro-certified,
and each spec now carries the queries and their answers. One correction came out of it,
recorded in `FIX_SPEC_D004_D017.md`: `contact_syncer/identifier_quality.py` DOES exist
on CM041 `main` and DOES carry an opaque-identifier predicate (`_OPAQUE`, UUID-shaped),
which the spec's prior-art table did not mention. Its conclusion survives -- that filter
is reachable only from `distinct_people` and `distinct_given_names`, both dedupe
helpers, and is **not** on the `pwg:displayName` write path -- but it survives on
evidence now instead of on assertion.

```gate id=v1018-D028 expect=0 runs-on=repo
# THE PROPERTY: a fix spec's "no prior fix exists" conclusion must rest on something
# a STALE CHECKOUT CANNOT FAKE. A tree can be 78 commits behind origin while
# `git status` reports clean. Two forms qualify:
#   (a) query the remote directly   -- gh api (any endpoint), git ls-remote
#   (b) assert the checkout is current -- rev-list --count HEAD..origin
#
# A bare `origin/<branch>` mention does NOT qualify. A remote-tracking ref is only as
# fresh as the last fetch, which is precisely what a stale checkout has.
#
# VACUITY CONTROL, which the previous body had none of: if the glob matched nothing,
# grep errored into 2>/dev/null, wc counted 0, and the gate reported PASS having
# examined nothing at all.
specs=$(ls cuts/*/FIX_SPEC_*.md 2>/dev/null | wc -l | tr -d ' ')
[ "${specs:-0}" -gt 0 ] || { echo "CANNOT-RUN: no fix specs found under cuts/*/ (v1018-D028)"; exit 97; }
echo "examined $specs fix spec(s)"
unverified=$(grep -rLE 'rev-list --count HEAD\.\.origin|gh api|git ls-remote' cuts/*/FIX_SPEC_*.md 2>/dev/null)
n=$(printf '%s' "$unverified" | grep -c .)
[ "${n:-0}" -eq 0 ] || { echo "FAIL: $n fix spec(s) reach a prior-art conclusion with no source-side query (v1018-D028):"; printf '%s\n' "$unverified" | sed 's/^/  /'; exit 1; }
exit 0
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
[ -n "${CM051_DIR:-}" ] || { echo "CANNOT-RUN: CM051_DIR unset"; exit 97; }
cd "$CM051_DIR" || { echo "CANNOT-RUN: cannot cd to CM051_DIR=$CM051_DIR"; exit 97; }
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
[ -n "${CM044_DIR:-}" ] || { echo "CANNOT-RUN: CM044_DIR unset"; exit 97; }
cd "$CM044_DIR" || { echo "CANNOT-RUN: cannot cd to CM044_DIR=$CM044_DIR"; exit 97; }
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

**DIAGNOSED ON THE BOX 2026-08-12 (Archie). THIS ROW IS REAL, AND ITS GATE WAS ALSO
MISWRITTEN -- both at once, which is why fixing the gate does NOT turn it green.**

Measured directly, `~/.ostler/logs/email-bundle.err`, last 615 lines:

    Dispatching            595
    pwg-convo completed      0
    pwg-convo failed         4
    TIMED OUT                0

**591 dispatches with no recorded outcome of any kind.** Every dispatch must leave
through exactly one of three logging branches -- `TIMED OUT` (D020 ceiling), `pwg-convo
failed ... rc=`, or `pwg-convo completed ... in Ns` (the D021 line, added precisely
because success timing was being discarded). 595 in, 4 accounted for. The other 591
produced no line at all, which means the parent is not reaching ANY branch: it is dying
mid-`subprocess.run` and being restarted, appending a fresh run of `Dispatching` lines
each time.

**No email dispatch has succeeded anywhere in the retained window.**

TWO INSTRUMENT FAULTS FOUND ALONGSIDE THE REAL ONE:

1. **The gate read the wrong file.** `email-bundle.log` is 3 KB and 16 hours stale and
   contains nothing but 34 identical "another LLM job (pid 82437) holds the model slot;
   yielding this tick" lines. The live output is in `email-bundle.err` (102 KB, written
   within the last minute). Same err-not-log shape as the pair-flow logs.

2. **The gate's completion pattern does not match the program's vocabulary.** It looks
   for `dispatch (complete|ok).*bulk` or `classified.*bulk.*-> (stored|done)`. The
   dispatcher emits `pwg-convo completed <id> in <N>s`. **A genuine success would not
   have turned this gate green.** Corrected below -- and the row stays RED, honestly,
   because there are no successes to find.

NOT ESTABLISHED, and deliberately not guessed: WHY the parent dies mid-dispatch. The
591 missing outcomes are the diagnosis target, not the conclusion. Candidates worth
separating before anyone builds: watchdog/launchd kill (cf. task #257's watchdog
killing dedupe mid-run), OOM under the 16 GB tier, or the parent exiting on its own
tick boundary while a child is still running. **D032's tail fix is now merged but not
yet installed; once it is, a killed dispatch will carry the last thing it did rather
than its startup chatter, which is the instrument this diagnosis needs next.**

A caution recorded because it nearly cost a wrong finding here: a frequency-sorted
`uniq -c | head -20` census of this log shows ZERO completion lines, because unique
per-document durations sort to count=1 and fall below the cut. The absence was real
but the census could not have proven it. Direct `grep -c` per branch is the control.

```gate id=v1018-D031 expect=0 runs-on=box
# A bulk/marketing document must finish, not time out, and every dispatch must leave
# through a logged branch. rc=75 is the D020 ceiling firing, which means this defect
# is still live -- treat it as RED, not as a pass.
#
# READS .err, NOT .log. The live dispatcher output goes to email-bundle.err;
# email-bundle.log holds only slot-yield ticks and went stale 2026-08-11 07:18.
# ASSERTS THE PROGRAM'S OWN VOCABULARY: the success line is "pwg-convo completed",
# not "dispatch complete". The previous pattern could not have matched a real success.
log="$HOME/.ostler/logs/email-bundle.err"
[ -f "$log" ] || { echo "CANNOT-RUN: no $log to judge (v1018-D031)"; exit 97; }
win=$(tail -2000 "$log")
n_disp=$(printf '%s\n' "$win" | grep -c 'Dispatching' || true)
[ "${n_disp:-0}" -gt 0 ] || { echo "CANNOT-RUN: no dispatch attempts in the window -- nothing to judge (v1018-D031)"; exit 97; }
n_done=$(printf '%s\n' "$win" | grep -c 'pwg-convo completed' || true)
n_fail=$(printf '%s\n' "$win" | grep -c 'pwg-convo failed' || true)
n_to=$(printf '%s\n' "$win" | grep -cE 'TIMED OUT|rc=75|EX_TEMPFAIL|TimeoutExpired' || true)
echo "dispatched=${n_disp} completed=${n_done} failed=${n_fail} timed_out=${n_to}"
[ "${n_done:-0}" -gt 0 ] || { echo "FAIL: ${n_disp} dispatch(es), ZERO completions -- no document finishes (v1018-D031)"; exit 1; }
[ "${n_to:-0}" -eq 0 ] || { echo "FAIL: dispatch ceiling fired ${n_to} time(s) -- document still never completes (v1018-D031)"; exit 1; }
unaccounted=$(( n_disp - n_done - n_fail - n_to ))
[ "$unaccounted" -le 0 ] || { echo "FAIL: ${unaccounted} dispatch(es) left through NO logged branch -- the parent is dying mid-dispatch (v1018-D031)"; exit 1; }
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

**DELIVERED, AND THE GATE WAS A FALSE RED (2026-08-11, Archie).** The fix is present in
all four pipelines and is BETTER than the shape specced above: a named
`_stderr_excerpt()` helper with a **2000**-char default (not 500), configurable at
runtime via `OSTLER_DISPATCH_STDERR_CHARS`, a dropped-count marker, and distinct
returns for absent vs empty stderr.

The old gate reported all four FAILING, for **two independent notation reasons**, and
neither was the defect:

    grep -qE 'stderr[^\n]*\[-[0-9]+:\]'
                        ^^^^^^^^^         the slice is text[-limit:] -- a VARIABLE,
                                          not a digit literal
            ^^^^^^                        and it lives in a helper, on a line that
                                          does not contain the word "stderr"

That is the third notation-pinned false RED in this registry, after D016's
selector-on-one-line and its `px`-only ceiling. **A grep for a slice cannot tell a
refactor from a regression.**

**The gate now EXECUTES the helper** rather than pattern-matching its source: it
AST-extracts `_stderr_excerpt` from each pipeline (a plain import fails -- these modules
use relative imports and have no parent package), runs it against a long synthetic
stream, and asserts the tail survives and the clip is announced. Presence is not
behaviour; this measures behaviour.

Four demonstrated controls, each with its own verdict:

    shipped state                        PASS, "examined 4 pipeline(s)"
    text[-limit:] -> text[:limit]        FAIL "discards the TAIL of stderr"
    truncation marker removed            FAIL "clips without saying it clipped"
    helper deleted                       FAIL "has no _stderr_excerpt helper"

```gate id=v1018-D032 expect=0 runs-on=repo
# The dispatch stderr capture must keep the TAIL, and must say it truncated.
#
# THIS RUNS THE FUNCTION. The previous body grepped for a slice literal and reported
# all four pipelines failing when the fix was present and correct -- the slice is
# text[-limit:] (a variable, not a digit) inside a helper (on a line with no "stderr").
# A grep for notation cannot tell a refactor from a regression.
#
# AST extraction rather than import: these modules use relative imports and have no
# parent package, so importlib raises ImportError on all four.
[ -n "${CM051_DIR:-}" ] || { echo "CANNOT-RUN: CM051_DIR unset"; exit 97; }
cd "$CM051_DIR" || { echo "CANNOT-RUN: cannot cd to CM051_DIR=$CM051_DIR"; exit 97; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: python3 not on PATH (v1018-D032)"; exit 97; }
python3 - <<'D032_PY'
import ast, os, sys
FILES = ["vendor/email_source/pipeline.py", "vendor/whatsapp_source/pipeline.py",
         "vendor/imessage_source/pipeline.py", "vendor/spoken_source/pipeline.py"]
HEAD, TAIL = "STARTUP-CHATTER-" * 400, "LAST-THING-BEFORE-WEDGE"
bad = 0
for f in FILES:
    if not os.path.isfile(f):
        print("FAIL: missing %s" % f); bad += 1; continue
    tree = ast.parse(open(f, encoding="utf-8").read())
    fn = next((n for n in tree.body
               if isinstance(n, ast.FunctionDef) and n.name == "_stderr_excerpt"), None)
    if fn is None:
        print("FAIL: %s has no _stderr_excerpt helper" % f); bad += 1; continue
    ns = {"os": os}
    for c in tree.body:
        if isinstance(c, ast.Assign) and any(
                getattr(t, "id", "") == "_STDERR_EXCERPT_DEFAULT_CHARS" for t in c.targets):
            exec(compile(ast.Module(body=[c], type_ignores=[]), f, "exec"), ns)
    exec(compile(ast.Module(body=[fn], type_ignores=[]), f, "exec"), ns)
    g = ns["_stderr_excerpt"]
    try:
        out = g(HEAD + TAIL)
    except Exception as e:
        print("FAIL: %s _stderr_excerpt raised %s" % (f, type(e).__name__)); bad += 1; continue
    if TAIL not in out:
        print("FAIL: %s discards the TAIL of stderr -- a hang needs the tail (v1018-D032)" % f); bad += 1
    elif "dropped" not in out:
        print("FAIL: %s clips without saying it clipped (v1018-D032)" % f); bad += 1
    elif g(None) != "<no stderr captured>" or g("") != "<stderr empty>":
        print("FAIL: %s does not distinguish absent from empty stderr" % f); bad += 1
    else:
        print("  ok  %s" % f)
print("examined %d pipeline(s)" % len(FILES))
sys.exit(1 if bad else 0)
D032_PY
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
[ -n "${OS003_DIR:-}" ] || { echo "CANNOT-RUN: OS003_DIR unset"; exit 97; }
rel="$OS003_DIR/release.toml"
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
[ -n "${CM051_DIR:-}" ] || { echo "CANNOT-RUN: CM051_DIR unset"; exit 97; }
cd "$CM051_DIR" || { echo "CANNOT-RUN: cannot cd to CM051_DIR=$CM051_DIR"; exit 97; }
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

**Knock-on, and it is the reason this was written here rather than left in a
task. RESOLVED 2026-08-11; this paragraph is kept as the trail, not as a live
finding.**

`v1018-D012b`'s V1019 cell read *"Verified as part of PR #10 D018 bisect scope
(same tool-binding surface); no separate PR unless bisect finds a distinct
defect."* That parented a verification on a bisect that will not happen and on a
PR that has nothing to do with it: `oa #10` is *"cron-delivery: piece E"*, and
re-checked at source 2026-08-12 it is **closed and never merged** -- this row
previously said "merged 2026-05-02", which was wrong in both halves.

**That was acted on and D012b no longer claims a fix.** Its citation now reads
CITATION WITHDRAWN 2026-08-11 and its status is `open`, corrected from a
CONDITIONAL that asserted fixed and not-fixed at once. Anyone arriving here from
the D012b row should stop: there is nothing left to chase.

**Left standing deliberately**, because the failure mode is worth keeping in
front of people: a row can be parented on a verification route that is later
cancelled, and nothing tells it. The bisect was cancelled by THIS row's finding,
and D012b went on claiming a fix for a day on the strength of it. A register row
must hold a state, not a plan.

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

**QUANTIFIED 2026-08-11 (Archie). The split is CATEGORICAL, and that is what
makes this severe rather than merely awkward.**

Re-measured at `~/.ostler/assistant-config/workspace/memory/brain.db`:

```
category      session      rows
core          NULL           2     durable facts about the user
daily         NULL          13
conversation  scoped         4     across 3 distinct keys
                            ---
                             19
```

**The WRITE side is correct.** Durable facts land unscoped; per-conversation
ephemera land scoped. That separation is sensible and nothing about it needs to
change.

**The READ filter inverts it.** `session_ref = Some(sid)` keeps only exact
matches and SKIPS every NULL-session row. So a channel that runs with a session
id sees its own handful of `conversation` rows and **none of `core`, none of
`daily`** -- 15 of 19 rows, and **100% of the `core` category**, which is
precisely where the user's own facts live.

That is the difference between "two channels cannot share" and what is actually
happening: **a scoped channel cannot see the user's durable memory at all.** Not
a sharing problem between peers -- the durable store is invisible to any reader
that identifies itself.

It explains the fresh-install ritual exactly. Seed "X is my wife" in chat, which
writes `core` with a NULL session. Ask on iMessage, which reads with
`imessage_<handle>_<handle>`. The row is skipped because `None != Some(sid)`.
Nothing errors at write time and nothing errors at read time.

**Consequence for the fix shape:** relaxing `recall()` to ignore the session is
NOT enough on its own, and deleting the filter is still wrong (purge-scoping is
a deliberate tested property). The minimal correct change is that a read must
match `session_id = sid OR session_id IS NULL`, applied at all four sites, so
durable rows are always visible and conversation rows stay scoped.

**A NOTE ON HOW THIS WAS FOUND, because the first probe lied.** A glob for
`~/.ostler/*memory*.db` returned nothing and would have supported "there is no
memory store". The DIRECTORY is `memory/`; the FILE is `brain.db`. Only the
control -- enumerate every `*.db`, ask each for a `memories` table -- found it.
A failed glob is a candidate false absence, never evidence.


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

### 🔴 v1042-D001..D004 ARE v1.0.38's DEFECTS. THE ID IS A LABEL, NOT A CLAIM.

Written 2026-08-23 as findings of a v1.0.42 upgrade walk. **They are not.**
v1.0.42 was never installed on any machine; the walk ran on v1.0.38. The
evidence is in the v1.0.42 row above.

Nothing about the four findings changes -- every measurement in them was taken
on a real box and stands. What changes is which cut produced the box, and
therefore which cut a reader should hold. **They were shipped by v1.0.38 and
have been in every cut since**, so v1.0.39, .40, .41 and .42 all carry them and
none was walked either.

The ids are kept because they are cited elsewhere. **A label that is wrong and
says so is safer than a rename that leaves five documents pointing at nothing.**

### v1042-D001 -- the runtime guard asked for a CLIENT and inferred an ENGINE

Found on the v1.0.42 upgrade walk, 2026-08-23. `install.sh` decided whether to
install a container runtime with `if ! command -v docker`. **On macOS `docker`
is a CLIENT.** Any box that had ever installed the Homebrew `docker` formula --
including one this installer had run on before -- skipped the Colima install and
walked on with no engine, while `ostler-wiki-site` and `ostler-wiki-compiler`
are pinned by digest as containers and have no native path.

CM051 #992 commit 1 replaces the client test with a loop over the runtimes that
can actually run a container (`colima orbstack podman`) plus the Docker Desktop
app bundle, behind an `ENGINE_PRESENT` variable the install decision reads.
CM051 #994 independently computes `HAS_CONTAINER_ENGINE` from `docker info` --
whether an engine ANSWERS, which is stronger -- and keeps `HAS_DOCKER_CLIENT`
deliberately, to make the diagnostic honest while deciding nothing.

**The two implementations collide and neither wins whole.** #994's Phase 0
detection is better; #994's Phase 3.2 guard is NARROWER than #992's (colima and
Docker.app only, 0 mentions of orbstack or podman in its guard block), so a box
running OrbStack gets `brew install colima` poured over a live engine.

**THE WALK EVIDENCE ORIGINALLY ATTACHED TO THIS FINDING IS WITHDRAWN, and the
withdrawal matters more than the finding.** The Mini was reported as having no
engine. It had one throughout: colima, docker, docker-compose and limactl were
all present and correctly symlinked, dated 21 Aug 19:43. The reading came from
a shell with no Homebrew on PATH. **A uniform zero across four different
runtimes is not four facts, it is one broken predicate**, and it was visible in
the same paste that reported `PATH homebrew count 0`. The error was then
repeated twice more over SSH before anyone caught it.

So the guard is a real defect and the mutants below prove the class, but **on
that box the fixed guard would have found colima, skipped the brew install, and
correctly changed nothing. It would not have restored the wiki.** The thing that
took the wiki down is v1042-D004.

**Three test defeats are recorded because they are the finding's real lesson.**
The first test asserted `grep -qE 'command -v docker'` over a 40-line window:
defeated by `-x /opt/homebrew/bin/docker` (no literal match) and by
`command -v "docker"` (two quote characters), both scoring 10/0. The window was
also 14 lines of code rather than 40, because `sed 's/#.*//'` BLANKS a comment
line and leaves it. The rebuilt test asserts a property of the ASSIGNMENTS and
was defeated twice more, both at 14/0: by `-x /opt/homebrew/bin/"docker"`,
because the client predicate was made quote-tolerant on its `command -v` limb
and left literal on its `bin/docker` limb; and by laundering the client check
through a variable set more than eight lines away, because **a window is a
distance and a distance can be padded with statements.**

### v1042-D002 -- the installer retained one byte per byte of carriage-return output

The Installer held **4.27 GB after a SUCCESSFUL install**. `stdoutBuffer` drained
only on `"\n"`; `docker pull` writes layer progress with `"\r"` and no newline,
so for the length of a multi-gigabyte pull the drain loop never executed once.
The trailing partial line was never drained at all, so the bytes survived the
install.

Driven, not read. The accumulator extracted from the shipped file and compiled:

    origin/main   fed 25,770,400   peak 25,770,400   final 25,770,400
    CM051 #993    fed 26,185,600   peak          0   lines emitted 534,400

**#993 does not merely bound it, it parses it**, because it treats `\r` as a
terminator rather than as something to discard. CM051 #992 commit 2 caps the
buffer at 64 KiB instead and emits nothing; #993 supersedes it and the two
conflict on the same function.

**A SECOND, OLDER PATH WAS FOUND WHILE PROBING.** Swift treats `"\r\n"` as ONE
Character -- a single grapheme cluster equal to neither `"\r"` nor `"\n"` -- so
`firstIndex(of: "\n")` is FALSE on it. Measured: 4,000 CRLF lines yielded **0
lines emitted and 42,890 bytes retained**, with plain LF as the control
returning TRUE. The `if line.hasSuffix("\r")` strip, whose comment says "a
handful of tool outputs put CRLF even into pipes", **could not be reached by the
input it names.** #993 fixes this explicitly; #992's cap bounds it without ever
parsing it.

**AND THE FIX STILL LOSES THE LINE THAT MATTERS.** Driven against #993: 1.3 MB
with no terminator followed by `"ERROR: no space left on device\n"` emits one
line of 65,669 bytes that does **not** contain the error text. Both notices
attached to it are honest -- bytes truncated, bytes dropped -- and the
diagnostic is gone anyway, because `finish()` keeps `prefix(maxLineBytes)` and
the error arrived at the end. **This is `v1018-D032` in a new file: captured
output keeps the head when a hang needs the tail.**

**A SOURCE-TEXT PREDICATE CANNOT HOLD THIS LINE.** The first test asserted that
a cap is declared, consulted, and that the buffer is reassigned. A decoy
satisfying all three -- guarded by `stdoutBuffer.isEmpty`, which cannot hold
above a cap -- scored **6 PASS / 0 FAIL while leaking 11,844,000 bytes and
climbing.** The property is "the number stops going up", and that is a fact
about execution.

### v1042-D003 -- install reported success with no container runtime

The install exits green having never established that a container can run. On
the walk box the two Docker-hosted ports were dark (`:8044` wiki, `:7878`
Oxigraph) while the two native launchd ports answered (`:8000` daemon,
`:8089` ical). **The zero was RAGGED and it fell on an architectural line**,
which is what made it trustworthy: the dead ports were exactly the containerised
services.

CM051 #994 adds the postcondition. It is additive -- nothing else in the walk
set covers it -- and it is the half of #994 that is not in dispute.

**It also collides with #995**, three files deep: `install.sh`,
`install.sh.strings.en-GB.sh` and `tests/TEST_WIRING.tsv`. That pair needs a
sequencing decision of its own and it is not the same decision as the #992
overlap.

### v1042-D004 -- an engine killed while the daemon stays up has no recovery road

**This is the finding that took the wiki down, and it is the one v1.0.43 holds
on.** Chain, measured on the box:

    the D002 buffer leak
      -> five JetsamEvent reports on 2026-08-23, 16:13:35 to 17:33:51
      -> jetsam killed the 4 GB Colima VM (install.sh --memory 4;
         pgrep 'limactl|qemu' returns 0)
      -> docker.sock gone; :8044 and :7878 dark, :8000 and :8089 alive
      -> ensure_colima_running() is called ONCE at daemon startup
         (ostler-assistant src/main.rs:1159, called at :1923)
      -> the daemon never exited, so recovery never fired
      -> no reboot: uptime 2d, last boot 21 Aug 17:31

Fixing D002 makes the TRIGGER rarer and gives the system no recovery road.
Jetsam is one way that VM dies; `colima stop`, a VM crash, a full disk and an OS
update are others, and every one of them lands in the same state: daemon up,
`ensure_colima_running()` already spent, wiki dark until a human notices.

**A one-shot at startup is not a recovery mechanism, it is an initialisation
step wearing one. Anything the daemon starts once at boot has this hole**, and
that is the finding -- Colima is the symptom.

`install.sh` deliberately creates no LaunchAgent here, and the reason rules out
the obvious fix: **a bare LaunchAgent has no Full Disk Access**, so a
LaunchAgent-spawned Colima cannot mount `~/Documents`, which `install.sh` binds
into `wiki-site` and `wiki-compiler`. That would bring the wiki up EMPTY instead
of DOWN, which is the harder failure to notice and therefore the worse one. The
smaller change is a periodic trigger on the daemon, which already holds FDA.

CM051 #995 is the candidate fix (`bin/ostler-engine-supervisor.sh`,
`lib/ostler-container-engine.sh`, plus a Doctor rule so a dead wiki announces
itself rather than rendering byte-identically to a healthy one).

**THE HOLD CLEARS** when #995 lands AND is demonstrated against the box in its
current failure state -- engine installed, engine stopped, `:8044`/`:7878` at
000, `:8000`/`:8089` alive. That fixture is perishable and repairing the box
destroys it.

**AND #995's OWN GATES ARE NOT WIRED TO FIRE.** `vendor-integrity.yml` gained
both run steps and none of the five path entries they need. Parsed, 27 entries,
with two must-be-present controls:

    tests/test_a_dead_wiki_announces_itself.py            NOT WATCHED
    wiki-recompile/bin/wiki-recompile-tick.sh             NOT WATCHED
    tests/test_container_engine_liveness_and_recovery.sh  NOT WATCHED
    bin/ostler-engine-supervisor.sh                       NOT WATCHED
    lib/ostler-container-engine.sh                        NOT WATCHED
    install.sh                                            install.sh   (control)
    vendor/doctor/agent/diagnostic_rules.py               vendor/**    (control)

That file states the rule in its own comment: "A path entry alone would only
make the workflow TRIGGER; the run step above is what makes it CHECK. Both are
needed." The dead-wiki gate is PARTIALLY covered, because `vendor/**` catches
the change it most needs to catch. **The engine-liveness gate is covered by
nothing**, and passes today only because its PR happens to touch `install.sh`.

### 🔴 v1.0.43 WAS WALKED, ON HARDWARE, AND IT COULD NOT INSTALL

Andy walked the published v1.0.43 DMG on the Mac mini on 2026-08-24. It aborted
at **19%**, step `fda_extract`, `ERR-99-INSTALL-ABORT-L2151 -> L1722`.
Deterministic: twice, same point, same error.

**The artefact was perfect and it did not matter.** 58,075,821 bytes; SHA256
`b753f152...39a0` matching the published SHA256SUMS; `spctl` Notarized Developer
ID (V95N2B8X7A); staple valid; `CFBundleShortVersionString 1.0.43` /
`CFBundleVersion 4300`. Every gate green, every signature good, dead installer.
Nothing between "gates green" and a human double-clicking would have caught it,
which is board #844 stated as an event rather than a risk.

**Why the status is `deferred` and not `closed`.** There is no
`walks/v1.0.43.tsv`: the install aborted long before `post_walk_qa.sh` could be
driven, so the walker left no artefact. This table's own rule refuses `closed`
with no record, and it is right to -- a walk claimed closed with nothing written
is the silence the mechanism exists to refuse. `not_walked` would be a plain
falsehood: it WAS walked, by a human, on hardware. `deferred` over a named
approver is the only honest status available, and D001/D002 below are deferred
because they are FIXED and ride v1.0.44, not because they were waved through.

**What the walk banked, and it is not nothing.** The stdout-buffer fix (#993)
was proven on hardware for the first time: peak installer RSS **0.14 GB**,
flat, against v1.0.38's 4.27 GB, with swap never moving off 2160 MB. That is
v1042-D002 demonstrated on a real box rather than in a driven harness.

### v1043-D001 -- a guarded ImportError fallback was counted as a hard dependency

`_ostler_verify_runtime_ready` derives the runtime's dependency set by walking
the AST of every file in the shipped `ostler_fda` package. Several files carry
the script-mode fallback pattern:

    try:
        from .role_addresses import is_role_identifier
    except ImportError:      # running as a plain script (repair on the box)
        from role_addresses import is_role_identifier   # type: ignore

`node.level` already skipped the relative arm. **Nothing skipped the fallback**,
and `ast.walk()` does not care about control flow, so a branch that never
executes when the relative import succeeds was collected as a hard requirement.
`importlib.util.find_spec("role_addresses")` returns None from the venv, because
a bare sibling only resolves with the package directory on `sys.path`. Four
optional-by-construction imports -> `missing=4` -> `return 1` -> abort at 19%.

Measured on the walk box before the fix:

    scanned=30 third_party=7 missing=4
    MISSING given_name_variants / pwg_ingest / relationship_labels / role_addresses

All four are files INSIDE the package, and `import ostler_fda.identifier_quality`
succeeded throughout. **Nothing was missing. The check was wrong.**

**This check is NEW since v1.0.38** -- `git grep -c` scores 0 at v1.0.38 and 4 at
v1.0.42/43. So **v1.0.42 would have failed identically**, and nobody found out
because v1.0.42 was never installed on any machine. The defect had two cuts to
be discovered in and was discovered in neither.

FIXED: CM051 #1013, squashed to main `d39bca0a`. Two layers -- skip imports
inside an `ImportError` handler (per-NODE, so a module guarded in one file and
hard-imported in another stays required), and subtract the package's own module
names. Proven on the specimen that failed, not on a fixture: same interpreter,
same package, on the walk box, the OLD guard returns rc=1 missing=4 and the NEW
one rc=0 missing=0, with `scanned=30` on BOTH arms -- so the fix narrowed the
classification, not the scan. The six dropped names were enumerated rather than
trusted; the only external one, `ostler_security`, soft-degrades by construction
and its hard gate lives at the CM046 LaunchAgent's boot. Masking risk measured
at zero: no derived own-name shadows an installed distribution.

Guarded by `tests/test_runtime_ready_does_not_require_optional_imports.sh`,
which carries a demonstrated red (pre-fix 5/2, reproducing `MISSING
role_addresses`; post-fix 7/0) and a discriminating arm that plants an absent
UNGUARDED dependency and requires rc=1 -- green in BOTH columns, so the fix did
not buy green by going blind.

### v1043-D002 -- the walk record recorded the version it was told

`scripts/post_walk_qa.sh` took `CUT_VERSION` from `argv` and wrote it verbatim
into `walks/<version>.tsv`. That file gates the customer download. The result is
already on disk and already wrong: `walks/v1.0.42.tsv` files four real,
correctly-measured defects against a version that has never been installed on
any machine.

Surfaced by this walk rather than caused by it, and it belongs to v1.0.43
because this is the walk that made it consequential: with the install dead,
the only thing that could have spoken about v1.0.43 was a record, and the record
could not have been trusted to name its own subject.

FIXED: CM051 #1014, squashed to main `cd666901`. The version is now MEASURED --
`CFBundleShortVersionString` read from `/Applications/OstlerInstaller.app` on
the box -- with four arms (no app -> `asserted-unverifiable`; no argument ->
derive; match; mismatch -> print both and `exit 3`) and a `version_source` field
recording how it knew.

**Near-miss worth recording, caught only by driving it at the live box:** the
first draft read `/Applications/Ostler.app`, which is the hub app at 0.7.1, and
would have REFUSED every legitimate walk record while looking rigorous. Three
version surfaces exist on a walked box -- `OstlerInstaller.app` (the cut),
`Ostler.app` (0.7.1, the hub app) and `~/.ostler/VERSION` (`hub-v0.4.61`, the
daemon, stale) -- and only the first is the thing being walked.

### v1043-D003 -- COVERAGE LOST: the abort meant most of the install was never exercised

CARRIED FORWARD, NOT FIXED. This one has no PR and must not be allowed to look
like it does.

Dying at 19% means everything after `fda_extract` went unmeasured on hardware:
the container-engine precondition, the wiki image pull, and -- the one that
matters for this register -- **#995's periodic engine liveness and recovery
path, which v1042-D004 exists to close**. `engine-supervisor.log` exists on the
box and is **0 bytes**.

So v1042-D004's demonstration limb is still open. ORM's adjudication on it
stands: "a one-shot at startup is not a recovery mechanism, it is an
initialisation step wearing one", and it clears only when #995 lands AND is
demonstrated on a live box. #995 has landed. It has still never run.

CLOSING CONDITION: a v1.0.44 walk that reaches past `fda_extract`, plus a
non-empty `engine-supervisor.log` and a demonstrated engine restart on the box.
Anything less leaves this row open, and a v1.0.44 walk that aborts for a
different reason does NOT close it.

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


### v1044-D001 -- the FDA dialog states something false and names the wrong entry

Board #874. The Full Disk Access dialog told the customer "System Settings is
open at Full Disk Access" when it was not open, and named the entry "Ostler"
when the row macOS actually shows is "OstlerAssistant". A customer following
the instruction looks for a name that is not on screen.

CARRIED into v1.0.45 and landed -- BOM row 1.

### v1044-D002 -- the installer re-asks the iPhone/Tailscale question on upgrade

Board #875. The prompt is unconditional. It never consults the tailscaled.state
that proves the step was already done, so an upgrading customer is asked to
redo setup they completed.

CARRIED into v1.0.45 and landed -- BOM row 2.

### v1044-D003 -- a run that aborted AT a step reports zero failed steps

Board #873, the #774 family. `DONE status=fail failed_steps=0` -- the run knows
it failed and cannot say where. Plus an unguarded `convert` call on the
customer path.

CARRIED into v1.0.45 and landed -- BOM row 3.

### v1044-D004 -- the installer said Doctor was running and it was not loaded

Board #876, and the headline of this walk. install.sh ran
`launchctl bootstrap ... || launchctl load ... || true` with both attempts
silenced, then printed the success line unconditionally. MEASURED on hardware:
com.ostler.doctor NOT LOADED, :8089 returned 000, no process and no log.

It cascades -- Preferences blank, Governor "Box status is not available yet",
Channels INACTIVE, People "No people yet", Timeline LOAD FAILED. All one bug.
The launch-blocking half is that the wiki in the same app showed 6,932 people:
the data was there, and every empty state told the customer a reassuring lie
instead of "I could not read this".

CARRIED into v1.0.45 and landed -- BOM row 6.

### v1044-D005 -- the settings migration is half done

Board #877. /preferences carries 10 flat keys; /config still owns 10 richer
sections including the daily brief schedule and the robot-emoji prefix, and
nothing links to /config. Andy asked for the pages to be combined; what shipped
was one nav entry, not one page.

CARRIED into v1.0.45 and landed -- BOM row 7.

### v1044-D006 -- the QA console and the walk record disagree, and it is UNRECONCILED

post_walk_qa.sh reported 22 PASS / 9 FAIL / 2 SKIP, verdict FAILED.
walks/v1.0.44.tsv records pass 5 / fail 5 / cannot_run 3, verdict FAILED,
qa_exit 1. Thirteen rows against thirty-three, and 5+3 does not equal 9.

BOTH agree the walk FAILED, so the gate that blocked promotion was reading a
true verdict and v1.0.44 was correctly never promoted -- ostler.ai/install.dmg
stayed on v1.0.41. That is the part that matters and it held.

WHAT IS NOT CLOSED: which denominator is right. Neither figure has been traced
to its producer. This is recorded as a finding in its own right rather than
folded into the five above, because a walk record whose arithmetic does not
reconcile cannot be used as evidence for anything else, and the next reader
must not quote either number as "the" result. Not carried into v1.0.45's BOM:
it is a defect of the RECORD, not of the shipped artefact.

### v1045-D001 -- the DMG bricks on first run: .pyc break the code seal

**This is why v1.0.45 has no install walk.** It could not be installed and then
assessed; the failure IS the install.

Measured on the SHIPPED artefact, not on the tree. OstlerInstaller-1.0.45.dmg,
58,099,134 bytes, sha256 70ebd926...989b57 -- byte count AND digest match BOM
row 16, so this is the DMG that was published. Dittoed to a WRITABLE directory,
which is the only place the defect exists and the reason v1.0.45's 14 of 14
read-only checks were worthless:

    env -u PYTHONPYCACHEPREFIX -u PYTHONDONTWRITEBYTECODE \
        .../python/bin/python3.11 -c 'import secrets,hmac,platform'

    .pyc inside the bundle   BEFORE 0  ->  AFTER 26
    codesign --verify --deep --strict   rc=1
        "a sealed resource is missing or invalid"
    spctl                                REFUSES

CPython writes `__pycache__/*.pyc` beside the source it imports. The interpreter
ships INSIDE the notarised app, so the first ordinary import rewrites the sealed
bundle and Gatekeeper refuses it. The customer sees "damaged and can't be
opened. You should move it to the Bin." on first run -- every customer, because
quarantine is attached by every browser download.

CONTROL, same binary, same import, guard set: .pyc in bundle 0 -> 0, 26
redirected to the cache dir, codesign rc=0. So the mechanism is the write
LOCATION, not the import.

🔴 AND THE OBVIOUS FIX WAS ALREADY SHIPPED AND STILL NOT ENOUGH. v1.0.45
ALREADY carried PYTHONPYCACHEPREFIX -- the string is present in the shipped
Mach-O (2 hits against a 20,685-string control) -- and it STILL bricked,
because the redirect is conditional on a fact about the CALLER and LaunchAgents
inherit no environment.

FIXED IN v1.0.46, and deliberately at more than one layer:
  #1052  seed the stdlib .pyc INSIDE the seal, so no caller can break it.
         --invalidation-mode unchecked-hash, anti-vacuity floor >=500, fails
         closed. Invoked from the real ship chain at gui/Makefile:2898, BEFORE
         notarise-app, so the seeded files land inside the seal.
  #1051  export the prefix from install.sh, not only from the GUI
  #1053  the CM059 front-page LaunchAgent
  #1054  the other three python LaunchAgents
  #1056  a CI GATE that refuses any LaunchAgent able to run python with no
         bytecode redirect -- the first gate aimed at the CLASS, not the case
  #1057  box-walk the DMG itself, before anyone installs it

NOT CLOSED BY THE ABOVE, and recorded so silence is not read as a pass:
#1055 relocates the interpreter OUT of the notarised app, which removes the
reason those four guards are needed at all. It is held for v1.0.47 because its
arms ran on a mounted artefact and a scratch HOME, never a real install, and
its author asks for a box walk -- which needs a DMG that does not brick.

✅ THAT PRECONDITION IS NOW MET. v1.0.47 is a DMG that does not brick, measured
on the published artefact (see v1046-D001): unguarded interpreter start and a
30-module no-env import both leave codesign at rc=0, with 0 added and 0
modified. The #1055 box walk is no longer blocked by the absence of a bootable
DMG. It remains blocked on Andy's ship-or-hold, which is a decision, not a
measurement.
### v1046-D001 -- v1.0.46 still breaks its own seal: 45 .pyc shipped in TIMESTAMP mode

**v1.0.46 existed to close v1045-D001 and it did not close it.** v1.0.45 shipped
ZERO .pyc so first use ADDED files to the seal. v1.0.46 closed that limb -- 1448
seeded, an unguarded first use adds ZERO -- and bricks anyway by the other limb.

Measured on the SHIPPED artefact, read-only mount. OstlerInstaller-1.0.46.dmg,
67,199,451 bytes, sha256 23134736...fa126f, matches SHA256SUMS:

    1448 .pyc      1403 unchecked-hash   ·   45 TIMESTAMP mode
    of those 45:    0 match their .py    ·   45 MISMATCH
    recorded mtime 1704067200 (2024-01-01) vs actual 1787713192 (build time),
    sizes IDENTICAL

All 45 are stale AS PUBLISHED, on the read-only volume, so `ditto` and the
customer's copy path are NOT implicated. Then, writable copy, no env:

    NEW .pyc  0   ·   REWRITTEN 19   ·   count 1448 -> 1448
    codesign --verify --deep --strict  rc=1
        "a sealed resource is missing or invalid"   IDENTICAL to v1.0.45

ORM reached the same defect independently via `env -i python3.11 -c 'pass'`.

ROOT CAUSE: `--invalidation-mode unchecked-hash` was ALREADY on the compileall
command line in v1.0.46 (counted 2 at d297cc59). It governs only what compileall
itself compiles; the ~45 stdlib modules the interpreter imports to BOOT are
written by the IMPORT SYSTEM in timestamp mode, and compileall then skips them
as up-to-date.

FIXED on CM051 main c196c1e0 (#1085): PYTHONDONTWRITEBYTECODE=1 + -f + an audit
that reads byte 4 bit 0 of every .pyc and REFUSES TO SIGN unless the
timestamp-mode count is 0. Gate: capability installer_refuses_timestamp_mode_pyc
(OS003 #157), counted 0 at d297cc59 and 1 on c196c1e0.

✅ AN ARTEFACT NOW CONTAINS IT. v1.0.47 cut + published 2026-08-26T04:32:56Z,
tag -> 10c24171 == CM051 origin/main. Downloaded and re-hashed rather than
trusted from the run: OstlerInstaller-1.0.47.dmg, 67,180,568 bytes, sha256
12fb6366f1ca5a02f8831958e6dfceb0e9f7e307bc30f7274638ae5bbb8a86ff, MATCHES
SHA256SUMS, and the byte count differs from v1.0.46's 67,199,451 so it is a
different artefact rather than a re-label.

    MODE CENSUS       1448 .pyc · timestamp 0 · unchecked-hash 1448
                      (v1.0.46: 45 timestamp-mode, 45 of 45 already stale)
                      denominator 1448 is non-zero, so this is a real zero
    WRITABLE COPY     .pyc BEFORE 1448  <- DENOMINATOR
      env -i python3.11 -c 'pass'        rc=0
      30 modules, no env                 rc=0, 30/30
      AFTER 1448 · NEW 0 · bytes CHANGED 0 (per-file sha256)
      codesign --verify --deep --strict  rc=0   <- v1.0.45 AND v1.0.46 were 1
      ^file added: 0   ·   ^file modified: 0    <- the verb that caught v1.0.46

BOM row v1.0.47 is landed=yes.

🔴 CLOSED BY MEASUREMENT, NOT BY A WALK. Nobody has installed v1.0.47. The
release is prerelease=true and ostler.ai/install.dmg is unmoved, so no customer
is on it. A2 verifies; A1 wrote the fix and is the wrong person to certify it.

### v1046-D002 -- walk arm 5 is CANNOT-RUN, and that is not a pass

Arm 5 could not run because CM051 #1055 is absent: the bundled interpreter is
still an import root, so the arm has no state in which to make its measurement.
CANNOT-RUN is neither FAIL nor PASS. Recorded here so the next reader does not
count 5 passes out of 8 arms and conclude the walk was mostly green.

#1055 is Andy's ship-or-hold and is NOT in v1.0.47. v1046-D001's fix closes the
BRICK without it -- ORM's own `env -i` reproducer returns 0 rewritten with the
fix applied -- but arm 5 stays CANNOT-RUN until #1055 lands.

DEFERRED to Andy's decision on #1055.

### v1046-D003 -- arm 7 fails by asserting the OLD contract, and arm 8's wording hides its own finding

Two instrument defects found by the same walk, neither of them product defects.

Arm 7 FAILED on "1448 .pyc seeded in the image". Seeding is now DELIBERATE --
it is v1045-D001's fix. The arm asserts a contract the product intentionally
left behind, so it will fail on every future cut until its predicate is
inverted.

Arm 8 prints "first use wrote 1448 .pyc into the bundle". It did not. NEW files
were ZERO; the number that matters is the REWRITE count, and the total is
reported in its place. ORM flagged this himself. A count-based message cannot
describe a defect that does not change the count.

✅ BOTH FIXED ON CM051 main, AFTER the walk that found them, and I verified it
rather than took the channel's word:
    3fd124df 2026-08-26T11:40:04+08:00  ARM 8 vetoes a SEEDED bundle (#1086)
    5cab70b2 2026-08-26T11:55:03+08:00  ARM 7 is ARM 8's sibling (#1088)
ORM's walk was 03:08Z = 11:08+08:00, so both landed within the hour after it.

Arm 7 now reads the PEP 552 flag word at offset 4 and requires 1
(unchecked-hash); 0 .pyc on the image is now the FAILING state, because zero
would mean the seeding never ran. Arm 8's invariant is AFTER = BEFORE plus an
independent codesign rc, which holds for a seeded and an unseeded bundle alike.
CONTROL: the old `1448 already in the artefact` predicate survives only inside a
comment at line 227 -- I checked, because a grep that scores comments as code is
its own defect (board #808).

✅ AND THE COUNT DISCREPANCY IS RESOLVED, NOT AVERAGED. It read as ORM 20 vs A1
4 on `env -i python3.11 -c 'pass'`. It is not a contradiction: THE NUMBER IS A
FUNCTION OF HOW MUCH YOU IMPORT, and 45 is the ceiling because that is how many
timestamp-mode .pyc shipped.
    bare `-c 'pass'`      4 rewritten   (boot set only)
    3 modules            19 rewritten
    broad import      up to 45          (the whole exposure)
ORM's own corrected comment in walk_dmg.sh:151 now says 45 for a bare-env
import, which sits at the top of that same curve. Every measurement any of us
took is a point on it.

CLOSED -- instrument fixes landed, discrepancy explained.


### v1047-D001 -- v1.0.47 seals only the stdlib: 440 product .py ship with NO .pyc

**v1.0.47 existed to close v1046-D001 and it closed only half of it.** The
stdlib limb IS closed -- 1448 seeded, all 1448 unchecked-hash, 0 timestamp-mode,
and a broad no-env import changes nothing. That half holds and should not be
re-litigated.

It fails by the OTHER limb, which is v1045-D001's, not v1.0.46's. Measured on
the SHIPPED artefact, OstlerInstaller-1.0.47.dmg, 67,180,568 bytes, sha256
12fb6366...a86ff, matches SHA256SUMS, plist 1.0.47 / 4700:

    .py in the bundle          1888
    .pyc                       1448
    .py with NO .pyc            440   <- ADDED by the customer's first import
      of the 440: outer bundle  353
      inside nested Ostler.app   87   (own signature -- see the residual below)

ORM's walk arm 8b found the smallest unseeded module and imported it:

    probing Contents/Resources/assistant_api/tests
    .pyc 1448 -> 1449    codesign rc=1    FAIL, VETO

That is an ADD, not a REWRITE. **Two defects wear the same colour and only one
of them touches a mode bit:**

    .py with NO .pyc        -> first import ADDS a file      (v1045-D001)
    .pyc in timestamp mode  -> first import REWRITES a file  (v1046-D001)

🔴 ROOT CAUSE, AND IT IS AN INSTRUMENT DEFECT, NOT A NEW PRODUCT DEFECT. The
audit added by #1085 reads `$PYTHON_DIR` -- the one directory that same commit
had just fixed. It asserted a property over a subset chosen so as to exclude the
defect, and it only ever asked about MODE, never about ABSENCE. Every count-based
and mode-based assertion was green while 440 files sat outside the root. Same
family as v1046-D001's flag-grep, one level up: see
`feedback_a_control_can_be_in_the_wrong_compartment`.

FIXED on CM051 main 7857e00c (#1093). Seeds the product tree with the same
compileall line, excluding `/python/` (already done) and `\.app/` (own
signature), and replaces the single-question audit with a whole-bundle one
asking BOTH questions, plus an anti-vacuity floor on the DENOMINATOR -- "0
uncovered" is also what an unstaged Resources tree prints.

VERIFIED ON THE REAL v1.0.47 BUNDLE BEFORE THE PATCH WAS WRITTEN, not after:

    compileall -q -f --invalidation-mode unchecked-hash -x '(/python/|\.app/)'
        rc=0    1448 -> 1801   exactly the 353 predicted, nothing failed to compile
        uncovered outer .py 0  ·  timestamp-mode 0
    re-ran arm 8b's own import:   1801 -> 1801    the add does not happen

41 test assertions (was 30). Both new predicates MUTATION-TESTED: neutering the
uncovered check fails 3 assertions, neutering the floor fails 2.

🟠 RESIDUAL, STATED NOT BURIED: the 87 .py inside Ostler.app are NOT fixed.
`ship:` runs `sparkle-embed` -- which seals Ostler.app with
`codesign --force --deep` -- two steps BEFORE `sign-python-bundle`, so excluding
them was mandatory, not cautious. Their fix belongs at `stage-payload`, before
that reseal. Hub lane owns it. If the Hub ever runs an unguarded product python
it breaks its own seal exactly as the installer did.

DEFERRED, NOT CLOSED: the fix is on CM051 main and in NO artefact. v1.0.47 is
published, prerelease, and installed by nobody; ostler.ai/install.dmg still
serves v1.0.41. Closing this would be true about the repo and false about the DMG.

### v1048-D001 -- v1.0.48's install path is UNMEASURED, because no walk has ever run install.sh

**This is a CANNOT-RUN, not a FAIL, and the distinction is the whole finding.**
v1.0.48 is not known to be broken. It is not known to work either, on the one
surface a customer actually touches.

**WHAT THE WALK ACTUALLY DID.** `walk_stage2_install_and_walk.sh` mounts the DMG
and drag-copies `OstlerInstaller.app` into `/Applications`. It never launches it.
Measured with a control that moved:

    /Applications/OstlerInstaller.app                     Aug 28 01:07  <- CONTROL
    ~/.ostler/logs/install.log                            Aug 25 16:23
    ~/.ostler/config.toml                                 Aug 25 16:23
    ~/Library/LaunchAgents/com.ostler.ical-server.plist   Aug 25 16:02
    ~/.ostler/.venv                                       Aug 24 12:42

The control moved; nothing `install.sh` writes moved. Corroborated by a second
instrument: `/tmp/ostler-pipeline-pip.log` is dated Aug 25, holds 3 lines, and
carries ZERO of the `== <req> ==` headers this version of install.sh writes, and
that block opens with `: > $LOG`, so a run would have truncated it. A2 confirmed
independently by version strings: `/Applications/Ostler.app` reads **0.7.1**, and
the install log mentions "1.0.4" zero times, so it predates the whole 1.0.4x line.

**CONSEQUENCE, AND IT IS THE REASON THIS ROW IS DEFERRED RATHER THAN CLOSED.**
The box runs an Aug 25 install of 0.7.1 with the v1.0.48 installer sitting beside
it unused. Every probe downstream of install.sh described 0.7.1. The eight phase-1
failures are therefore NOT this cut's:

    identity_layer_is_importable          the #1139 fix for this IS IN v1.0.48
                                          (d44bba7c, ancestor of the tag: TRUE) and
                                          has never executed. Proved sound in an
                                          isolated venv: rapidfuzz 3.14.5, all three
                                          identity_resolver modules import, consumer
                                          venv left untouched so the box still shows
                                          the defect.
    no_person_holds_two_contact_cards     damage dated 2026-08-21..24, ZERO merges
    people_count_agreement                since install, control 1128 mergedAt
    people_stores_reconcile               triples so the zero is real
    pairing_recovers_without_a_repair_storm  pre-existing per #505, measured BEFORE
                                          this cut
    usage_journal_producers               designed pipeline shipping dark (#482)
    no_unexpected_egress                  all three destinations Tailscale-owned and
                                          declared by wildcard; NOT a leak
    assistant_answers_grounded            1 of 3 questions did not reach the graph;
                                          n=3 is too small to size

**IT ALSO PRODUCED A FALSE PASS IN THE WALK'S OWN OUTPUT, and that is the part
worth keeping.** The walk printed `#520 PRECONDITION, RE-CHECKED AFTER INSTALL
(install regenerates config.toml) -> companion_enabled = true`. config.toml was
NOT regenerated; it is Aug 25's, and the value was already true. The probe passed
for a reason its subject cannot support. That is task #520's exact shape, and it
means a green from that probe carries no information about any install.

**WHY IT IS NOT SIMPLY FIXABLE, stated so the next reader does not re-derive it.**
install.sh REFUSES to run headless by design: line 771 requires a TTY unless
`--check`, `--help` or `--licenses`, or `OSTLER_GUI=1`. A real run calls `sudo -v`
(72 sudo sites), 44 `osascript` calls, and 22 `launchctl kickstart -k` (#509's
documented hang). An agent cannot supply a password and must not try. So this is a
CANNOT-RUN at the level of the harness, not a probe that happened to fail.

**THIS EXPLAINS A LONG-RUNNING PATTERN.** Andy's manual walks keep finding
installer defects our automated walks score green. It was never that we kept
missing them; the automated walk is structurally incapable of seeing them.

**RIDES FORWARD AS:** #531, which offers an honest floor that costs nothing
(rename the driver and record `install_path_exercised=false`) and a real fix that
does not (a GUI session or an `OSTLER_GUI=1` arm with the osascript and kickstart
hazards handled). Neither is in v1.0.49's scope, which is arm 8 and nothing else.

**DEFERRED, NOT CLOSED:** closing would assert that v1.0.48 was walked. It was
walked as an ARTEFACT and that half is genuinely green. The install half has not
been walked by anyone, and saying otherwise would be true about the DMG's bytes
and false about the DMG's behaviour.

### v1050-D001 -- the installer breaks its own code seal during the install, and TCC makes that permanent

**TWO PROBES, ONE CAUSE.** `app_signature_survives_first_run` and
`installed_bundle_seal_intact` both failed, and they are not two findings. Any
count that reads `fail 7` as seven product defects is over-stating by at least
one here.

`_AICONV_SRC` is `${SCRIPT_DIR}/cm052_ai_conversations`, and in the `.app`
layout `SCRIPT_DIR` is `Contents/Resources`. A bare `pip install` of a
bundle-rooted source directory therefore builds IN PLACE and writes into the
notarised bundle. Measured on the walk: `codesign` reported a sealed resource
missing or invalid and named exactly **22 added files**, 6 under
`cm052.egg-info/` and 16 under `build/lib/src/cm052/`, all inside
`Contents/Resources/cm052_ai_conversations`.

**WHY THIS IS WORSE THAN AN UNTIDY BUNDLE.** TCC pins identifier AND team, so a
permission the customer granted does not survive the bundle changing underneath
it. The customer grants Full Disk Access to a bundle that then stops being the
bundle they granted it to.

**FIXED ON MAIN, NOT IN AN ARTEFACT.** CM051 #1266 routes the call through
`_ostler_pip_install_pkg`, which stages outside the bundle. This was the LAST
unrouted bundle-rooted pip install: the helper's own docstring records the
v1.0.32 measurement of 346 unsealed files, so this is the remainder of that
fix, not a new regression. Guarded by capability
`install_cm052_pip_stage_outside_bundle` (present, mutation-tested fixed=1 /
unfixed=0).

### v1050-D002 -- a LaunchAgent baked a /tmp staging path and dies at the customer's first reboot

Probe `launchd_no_ephemeral_paths`. The `com.ostler.engine-supervisor` plist is
written ABOVE the promote boundary and interpolated `${OSTLER_DIR}` and
`${LOGS_DIR}`, which on a fresh install still hold
`/tmp/ostler-prelaunch-<pid>`. `/tmp` is wiped at reboot, so the supervisor dies
the first time the customer restarts.

**THE DEFECT WAS INVISIBLE TO EXACTLY THE PERSON TESTING IT.** Every promote
call earlier in the file is conditional, and the earliest fires only on the
`SKIP_PHASE2` RE-RUN path. On a re-run the promote HAD fired, so the plist came
out correct. Only a genuinely fresh install reaches that line with staging
values still bound -- which is why this survived two cuts.

**THE GUARD WAS THE SECOND FINDING.** #177 fixed this same class for the two
ollama agents, and its gate's PASS message claimed "no shipped
`com.*ostler*.plist` path resolves under /tmp" while its denominator was TWO
PLISTS, HAND-TYPED. True of that incident, never true of the class.

**SCOPE, MEASURED, AND SMALLER THAN MY OWN FILING IMPLIED:** 14 plist heredocs
discovered, 4 above the boundary, 2 already fixed by #177, 1 a quoted heredoc
that does not interpolate. `engine-supervisor` was the only live one. A class of
ONE remaining, not the sweep I first described.

**FIXED ON MAIN, NOT IN AN ARTEFACT.** CM051 #1269 roots at `OSTLER_FINAL_DIR`
(bound once at the top of the file, never rebound), creates the logs directory
because launchd resolves `StandardOutPath` at spawn so a missing directory is a
spawn failure, and emits a `dbg` line recording the path actually baked -- the
write used to emit nothing, and that silence is why a dead path survived. The
guard now DISCOVERS all 14 with an anti-vacuity floor and a CANNOT-RUN arm.
Guarded by `engine_supervisor_plist_roots_at_final_dir` (present, fixed=2 /
unfixed=0).

### v1050-D003 -- this failure was the INSTRUMENT, not the product

Probe `people_seed_and_retrieval`. It called Qdrant with no credential, received
**401**, and reported "collection missing or unreadable" about a collection that
demonstrably exists. Store auth has been mandatory since #550/#1222, so the
probe was accusing the product of the probe's own missing credential.

**A 401 IS NOT A 404 AND NEITHER IS A MEASUREMENT OF THE PRODUCT WHEN YOU
BROUGHT NO KEY.** The probe collapsed three states into two, which is the same
class as #558 and #574. It now presents the install's OWN curl config via
`-K`, so no secret is ever read, echoed or interpolated by the probe, and it
adjudicates three ways:

    401 + credential presented  -> FAIL        (a key the store refuses is real)
    401 + no credential         -> CANNOT-RUN  (nothing was measured; accuse nobody)
    404                         -> FAIL        (genuinely absent: real)

**THIS ROW DOES NOT CLEAR A PRODUCT DEFECT, BECAUSE THERE WAS NOT ONE.** It
corrects the record. CM051 #1268 fixed the probe, and deliberately has NO BOM
row for v1.0.51: it touches only `scripts/box_walk_probes/` and
`scripts/tests/`, which the DMG does not carry (`grep -c box_walk_probes
gui/Makefile` = 0 rc=1, control `install.sh` = 29 rc=0 on the same file). An
instrument fix that never reaches the artefact does not belong in a bill of
materials for the artefact.

The harness also gained EXACT-CODE expectations, because its `fail` meant "any
non-zero" and could not tell 1 from 78 -- the same two-state reading of a
three-state contract that caused the defect it was guarding.

### v1050-D004 -- the install told the customer Full Disk Access was already granted when it was not

Not attributable to a named failing probe: this was observed on the live
fresh-account walk narrative, and saying so matters because a reader
reconciling this section against `failed_probe` lines will otherwise look for
one that is not there.

The old code tested whether the FDA register-nudge had RUN and then assigned
listed-ness from that. It synthesised a fact it had not observed. **REFUTED ON
THE WALK:** the nudge ran, logged success, and OstlerAssistant was absent from
the Full Disk Access list.

**ONE INVENTED BOOLEAN DROVE THREE CUSTOMER-FACING BRANCHES, ALL THE WRONG
WAY.** It suppressed the `open -R` so the Finder drag-in route was never
offered; it printed "already listed, just switch it on" at a customer looking
at a list that did not contain it; and it dropped the drag instruction from the
modal. The one route that might have worked was withheld BECAUSE the code had
convinced itself the customer did not need it.

**AND VERIFYING INSTEAD IS STRUCTURALLY IMPOSSIBLE HERE.** The real probe reads
TCC.db via sudo, and `sudo -n` is unavailable on exactly the fresh install this
fires on. So the honest state is CANNOT-VERIFY, and the previous code answered
a CANNOT-VERIFY with a PASS.

**FIXED ON MAIN, NOT IN AN ARTEFACT.** CM051 #1267 deletes the synthesis, logs
the nudge as an attempt rather than a confirmation, and offers the route when we
do not know. **A DELIBERATE COST, STATED:** BW6 added the synthesis to stop a
redundant Finder window stacking with the Tailscale sign-in, and that annoyance
returns. A duplicate window is cosmetic; a customer who cannot grant Full Disk
Access at all is a broken install. Guarded by
`fda_listed_never_synthesised_from_nudge` (absent, fixed=0 / unfixed=1).

### v1050-D005 -- the store-port probe reported BROKEN, and its self-test adjudicated its own red as a pass

`broken_probe no_store_port_is_tcp_reachable`. BROKEN is a fourth state and it
is not a pass: the probe could not reach a verdict about its subject.

The probe's `--self-test` mode ended on `probe_pass`. A self-test whose purpose
is to DEMONSTRATE the negative control fires must not terminate green, because
then a genuinely broken adjudication and a working one print identically.
CM051 #1269 changes the terminal to `probe_fail` with an explicit BROKEN arm,
so the red it emits is labelled as the expected result of `--self-test` and
cannot be mistaken for a finding.

**Fixed on main, not in an artefact.** No capability row: the probe does not
ship in the DMG, same reasoning as v1050-D003.

### v1050-D006 -- assistant_answers_grounded: OPEN, unfixed, and not carried by v1.0.51

Probe `assistant_answers_grounded` failed and **nothing in v1.0.51 addresses
it.** Recording it as open rather than quietly omitting it, because a
rollforward row that lists only the findings that were fixed is a status report
dressed as a record.

Related open board rows: #339 (assistant refuses benign input on the default
16 GB model), #510 (the grounding measurement itself was taken at temp=0.0
while the daemon ships temp=0.7, so the earlier 7/9-vs-9/9 figure was measuring
the wrong configuration). The second is the reason this row does not yet carry
a defensible pass/fail threshold: the harness is a controlled dimension and it
was not controlled.

### v1050-D007 -- freshness_panel_has_dates: OPEN, unfixed, and not carried by v1.0.51

Probe `freshness_panel_has_dates` failed. Board #514 and #349: the panel has NO
per-source date surface anywhere, and the earlier wrong-clock symptom was
REPLACED rather than resolved -- Meetings and Contact now read "unknown" instead
of a wrong date, which is more honest and still not a date. Nothing in v1.0.51
touches it.

### v1050-D008 -- usage_journal_producers: OPEN, unfixed, and blocked on something outside CM051

Probe `usage_journal_producers` failed. Board #482 and #487: the ingestion
producer landed, the ENRICHMENT producer has not, and it has two blockers of its
own (the writer is absent from the wiki-compiler image, and a bind mount). Not
addressed by v1.0.51 and not addressable inside CM051 alone.

### v1050-D009 -- the cannot_run bucket was never adjudicated, and four of its six rows are the instrument

The eight findings above cover the **fail** bucket. `walks/v1.0.50.tsv` also records
**6 `not_measured_probe` rows**, and nothing in this document has ever dispositioned
them. That omission is why the fourth instance of v1050-D003 went unnoticed for a
day: D003 named one keyless probe, and this file never asked whether it had
siblings.

Measured at `v1.0.51^{commit}` by @A2 and @TNM, credential mechanism
(`STORE_CURL_CONF|curl -K|Bearer|api-key`), whole file, with the D003-fixed probe as
a must-hit control:

    probe                              cred  queries   verdict
    ingest_coverage                      0    6333     D003 class -- keyless
    no_person_holds_two_contact_cards    0    7878     D003 class -- keyless
    people_count_agreement               0    7878     D003 class -- keyless
    people_stores_reconcile              0    7878+6333  D003 class -- keyless
    launchagents_resolve_their_tools     0    none     correctly outside the class
    pair_state_agreement                 1    :8000    correctly outside -- admin Bearer, not a store
    ---- CONTROL ----
    people_seed_and_retrieval            9    6333     D003-FIXED, so cred=0 above is real absence

Store auth is enforce-ON and mandatory since #550/#1222. A keyless call to these
stores returns 401, so **all four cannot_run for an instrument reason on any
conforming box, whatever the product state.** `verify_walk_record` requires
`cannot_run==0` for CLEAN, so these four block a clean walk exactly as D005 did from
the broken column.

`ingest_coverage` is the worst of the four and deserves its own sentence: it carries
**no auth-aware branch at all** (auth-string count 0, against 50 in the fixed
probe), so a 401 does not land in an auth arm -- there isn't one. It lands in
*"not one of the stores answered"*, which names the store as unresponsive when the
store in fact answered *who are you*. It is also the probe closest to "did the
product ingest anything", so the instrument bug blinds the most load-bearing
question in the suite.

**DISPOSITION: instrument fix, not a product defect, and NOT a decision for the
cut owner.** The remedy is D003's: give each the store curl config. Queue is
2 changes / 6 files -- these 4 probes, plus the cannot_run reason capture in
`run_box_walk.sh` and `post_walk_qa.sh`. Both gated on a sole-tenant box, because
neither can be exercised end-to-end while another account holds the store ports.

⚠️ BOUND: the keyless query and the missing auth branch are MEASURED in source. That
they caused the v1.0.50 cannot_runs is a PREDICTION -- strong, because D003 is the
same pattern with the 401 already observed -- and it is unprovable after the fact
because the record discards the cannot_run reason. That gap is the second half of
the queue above.

### v1051-D001 -- the freshness panel reports INSTALL-TIME sentinels forever, and its source list disagrees with the sentinel directory

Measured on the walk box 2026-08-30, both artefacts side by side. The panel does NOT
read `settling_progress.d`; it reads `~/.ostler/state/hydrate/<source>.done`, written by
install.sh's recorder call sites.

    hydrate/imessage.done                      recorded_at 2026-08-30T04:52:43Z  status=no_data
    settling_progress.d/messages.imessage.json updated_at  2026-08-30T06:33:15Z

**100 minutes apart.** At 04:52 the installer asked iMessage and correctly got nothing.
iMessage then ingested. Nothing rewrites the sentinel, so the panel reports `no_data`
permanently for the largest corpus on the box. It is an install-completion panel wearing
a freshness label.

SECOND, INDEPENDENT DEFECT -- the list and the directory disagree:

    on disk (11)   apple_notes browsing calendar contacts dedupe email imessage
                   people places privacy_backfill whatsapp
    panel list (9) imessage whatsapp email_preferences browsing apple_notes
                   people places privacy_backfill ai_conversations

`calendar.done` (status=ok, events=72) and `contacts.done` (status=ok) are NOT in
`KNOWN_HYDRATE_SOURCES`, so those rows never render -- two healthy sources invisible on the
one panel built to show the customer things are working. `email.done` exists but the panel
looks up `email_preferences.done`, so it renders "never" with a real sentinel beside it.
The list's own comment anticipates drift in one direction only; the failure is the other
direction, where a sentinel with no list entry vanishes silently. Class (g), #532.

DISPOSITION: DEFERRED to v1.0.1, and this is a SCOPE CALL, not an oversight. The renderer is
CM044 `compiler/hydration.py`, which ships as a PINNED IMAGE, so no fix reaches a customer
without an image rebuild + re-pin + re-cut. @TNM measured the prerequisite and the answer is
**no wiki-image rebuild is in the v1.0 path**, so this is not a free ride on work already
happening. Archie's call: a wrong label on a diagnostic panel does not justify adding an
image-rebuild pipeline to the launch critical path. It is not data loss and not a security
defect. ANDY MAY OVERRIDE.

🔻 MY OWN FIRST FILING OF THIS WAS WRONG and the measurement corrected it. I filed it as a
key-vs-filename mismatch INSIDE `settling_progress.d` ("the bridge sits unused in the filename
messages.imessage.json"). The panel never reads that directory at all. I compared two artefacts
that were never connected, then found the real consumer by reading the code that emits the row.

### v1051-D002 -- no_store_port_is_tcp_reachable is an EXPECTED red for 8044/3000, deferred by Andy

Not a regression and not a new defect. Andy decided 2026-08-30, asked once and answered once:
ship v1.0 with 8044 open and close it properly in v1.0.1. His words, relayed verbatim: "I guess,
yes... But not happy about it." @TNM measured that NO cookie/session concept exists anywhere in
the daemon (6 mechanisms searched, 6 zeros, control `Authorization` = 122 files), so the close is
a BUILD, not a wiring job.

Measured blast radius, so the deferral is not a shrug: all three ports are already loopback-only
in install.sh (127.0.0.1:8044, :8144, :3000; control 127.0.0.1:6333 also present). Unauthenticated
from the owning account 8044 -> 200 and 3000 -> 200, while the demonstrably-closed stores 6333 and
7878 both -> 401 on the identical request.

⚠️ NOT MEASURED, DO NOT HARDEN: whether a SECOND account on the same Mac can read it -- the
#549/#550 threat model -- was CANNOT-RUN (no passwordless sudo on the walk box). It is INFERRED
FROM TOPOLOGY, NOT DEMONSTRATED. Any row or release note stating it as measured got that from
inference, not from a measurement anyone took.

### v1051-D003 -- usage_journal_producers, and a mechanism of MINE that the decisive test refuted

The recorded `broken 1` was MY PACKAGING (3 files missing, not 1) and is cleared on the box:
5 of 5 arms OK, verified rather than predicted.

The customer-visible half is the Bursar: the nav entry exists, `/api/cost` is registered (401
keyless; a nonsense sibling 404s), the writer is in the shipped binary, and
`~/.ostler/workspace/state/` never exists so the journal is never written.

🔻 MY EXPLANATION WAS "START ORDER" AND ITS OWN DECISIVE TEST KILLED IT. I claimed the daemon
booted before the installer enabled cost tracking, caching "disabled" in a once-only global.
Measured on the box:

    config.toml mtime   Aug 30 12:53:49   (enabled = true present)
    daemon started      Aug 30 12:54:51   (62 seconds LATER)

The daemon booted WITH `enabled = true` already on disk, and `state/` still does not exist. The
start-order mechanism is dead. The remaining candidate -- unverified, explicitly not a conclusion
-- is that the directory is created on the first recorded cost and nothing has recorded one.

⛔ DO NOT "FIX" THIS BY CREATING THE DIRECTORY. That converts a loud absence into a quiet zero,
which is the failure mode this register exists to prevent.

### v1051-D004 -- assistant_answers_grounded failed and I DID NOT INVESTIGATE IT

Recorded in `walks/v1.0.51.tsv` as one of four `failed_probe` rows. I investigated the other
three and did not reach this one before the cut.

This section exists so the count is honest. It is NOT a disposition, NOT a severity assessment,
and NOT a claim that the probe is the instrument rather than the product -- three things I have
wrongly assumed about a red today and been corrected on. Unexamined, and recorded as unexamined,
because a walk-closure row that quietly omitted it would read as coverage this cut does not have.

OWNER: unassigned. Next walker or next lane picks it up.
### v1052-D001 -- A1: the Front Page never populates, and the store-auth shim is why

Andy's hand walk of v1.0.52, 2026-08-31. Home shows the settling stub on a box that has ingested.

ROOT CAUSE, measured at source: the store-auth shim wires a credential into interpreters by
ENUMERATING `.venv` DIRECTORIES. `cm059-editor` has no venv, so its Front Page producer starts with
no credential, 401s against Oxigraph on every hourly run, and fail-closes to the settling stub. The
panel is not empty because there is nothing to say. It is empty because the producer cannot read the
store, and it will stay empty for ever on every install.

Fix merged as CM051 #1302. NOT WALKED -- it is in no artefact any human has installed.

This defect was marked COMPLETED in the task register while broken, and Andy found it still broken on
the box. That is why this row reads deferred: calling it closed here would restate the false claim.

### v1052-D002 -- A2: Settings still carries the "Advanced" section that was agreed removed

Andy's hand walk, 2026-08-31: "we agreed that there wouldn't be this 'Advanced' section".

This is the ONE finding of the six that v1.0.54 carries a fix for. oa #369 removes the Advanced
surface and remounts its two customer-facing controls -- the daily-brief schedule and the iMessage
message prefix -- on Preferences. Deleting the link alone would have re-created the earlier defect
where those two controls were orphaned with no route to them.

VERIFIED INSIDE THE SIGNED DAEMON, two-sided with a predicate control: two Advanced strings absent,
three control strings present, one never-present token absent. That verification is OF THE ARTEFACT.
It is not a walk, and it is not evidence that a customer sees the change.

Also marked COMPLETED in the task register while broken -- on a task whose own title recorded that it
had not been box-walked.

### v1052-D003 -- A3: the "Still getting to know you" panel is unstyled, not merely untidy

Andy's hand walk, 2026-08-31.

MEASURED IN CM044: the renderer emits four classes that have ZERO matching rules anywhere in the
stylesheet -- `pwg-settling-sources-h`, `pwg-source`, `pwg-source--*`, `pwg-settling-wiki-age` -- and
`.pwg-settling-sources`, whose only rule set is written for a `<ul>`, is applied to a `<table>`. This
is unstyled markup reaching a customer, not a layout tuning problem.

Andy chose the list idiom over a styled table, which makes the fix TWO REPOS rather than
self-contained CM044. Held by A2. Whatever lands still has to reach an artefact through a wiki-image
rebuild and re-pin, the same delivery constraint as D005 and D008.

Also marked COMPLETED in the task register while broken.

### v1052-D004 -- A4: the Bursar says "You're not on the meter", and two of five required producers do not exist

Andy's hand walk, 2026-08-31. This section also dispositions the machine probe
`usage_journal_producers`, so the probe is not counted twice.

THIS IS ANDY'S SCOPE CALL AND IT IS DELIBERATELY NOT BEING CODED AROUND. Five usage-journal producers
are required before the Bursar has a denominator.

🔻 MY FIRST FILING SAID "TWO OF FIVE" AND IT WAS WRONG IN BOTH THE COUNT AND THE KIND. @TNM
measured the roster row by row on 2026-09-01, before writing any producer, specifically to check they
were not doubling up -- and the check found a third:

    cm044_wiki_compiler          required   NOT MEASURED this pass, and recorded as not measured
    cm048_conversation_extract   required   UNWIRED, and the roster says so in its own provenance
    cm041_identity_resolution    required   UNWIRED, and the row names the wrong component
    cm051_ostler_fda_ingest      required   🔴 WIRED UPSTREAM, ABSENT FROM THE SHIPPING TREE
    oa_daemon_chat               required   the daemon's own tracker

🔴 THE THIRD IS WORSE THAN THE OTHER TWO AND IT IS THE ONLY ROW THE ROSTER CALLS "MEASURED".
Its provenance cites the ingesting producer in the HR015 source, and it is measured -- ON THE SOURCE,
WHICH IS NOT WHAT SHIPS. The same predicate scores 5 on the HR015 file and 0 on the vendored copy in
the shipping tree, with a live control of 57 on the same vendored file proving the blob was read; and
the module the import needs is not among the 34 files in that vendored package, against a VISIBLE
population, so the import has nowhere to resolve to even if it were present. The divergence is also
NOT DECLARED: the divergence patch scores 0 for this class against a control of 10 for the same file,
so the patch declares other divergences in that exact file and is silent on this one.

⇒ THE INGESTING PRODUCER HAS NEVER WRITTEN A RECORD ON ANY CUSTOMER INSTALL. Not "unwired like the
other two" -- wired, merged upstream, and LOST AT THE VENDOR BOUNDARY, while the roster records it as
the one that was verified. That is the MERGED IS NOT IN THE ARTEFACT class landing inside the very
gate built to detect silent pipeline failure, and it is the reason this section now exists in
corrected form rather than as a count.

🔻 AND THE cm041 ROW NAMES A COMPONENT THAT CALLS NO MODEL. The identity-resolver modules score
0 for model calls across the whole package, against a live control of 25 on a sibling package's
client. The contract's own wording is conditional -- identity resolution WHERE IT CALLS A MODEL -- and
the hedge turns out to be load-bearing, because it does not. CM041 does call models, in the contact
syncer and the calendar server, so the OBLIGATION is real and the producer_id is simply pointed at the
wrong file.

Two moves are legal: BUILD the two producers, or SHRINK the required roster deliberately and say so on
the page. Demoting the roster to obtain a green has been proposed twice and refused twice, because it
converts a true "we are not measuring this" into a false "everything is measured".

DO NOT clear the probe by creating the journal directory. v1051-D003 already recorded why: it turns a
loud absence into a quiet zero, which is the failure mode this register exists to prevent.

OWNER: Andy, one decision. Nothing else on this row waits on it.

### v1052-D005 -- A5: "Duplicate review is available on the Hub Mac only." rendered ON the Hub Mac

Andy's hand walk, 2026-08-31. He had reported this before and I had never filed it, which is why it
appears here as a new id rather than as a recurrence.

CM044 #262 is merged. It is in NO ARTEFACT: the renderer ships as a pinned image, so the fix reaches a
customer only through a wiki-image rebuild and a re-pin in CM051. That prerequisite is the same one
v1051-D001 was deferred on and it is still not in the v1.0 path.

Carried by v1.0.54: NO. Merged is not delivered.

### v1052-D006 -- A6: dedupe asks the customer to merge real people, and the deciding test has not been run

Andy's hand walk, 2026-08-31. This section also dispositions the machine probes
`no_person_holds_two_contact_cards` and `people_stores_reconcile`. BOTH WERE CANNOT-RUN ON v1.0.51 AND
BECAME MEASURABLE ON THIS WALK -- they are not new defects, they are newly visible ones, and the row
above says so with the arithmetic.

MEASURED: approximately 30 genuine over-merges, through the shareable-id path. NOT 136 -- A2 corrected
their own first figure, and TNM then refuted A2's replacement invariant against the ratified ruleset.
Two successive statements of this number were wrong before the third stood, so treat the ~30 as the
current best measurement rather than a settled one. Suspects are narrowed to the email-exact and
exact-name rules. `linkedin-exact` IS CORRECT BY DESIGN and must be excluded from any repair pass.

🟢 THE DECIDING TEST HAS NOW BEEN RUN, AND IT DECLINES. @A2, 2026-09-01, CM041 #135, test-only,
CI green. Three cases through the real decision surface (detect_email_matches then consolidate_matches)
under the DEFAULT config, not through raw confidence:

    same surname, different given    names_agree=unsure     conf 0.7  -> review
    different given AND surname      names_agree=disagree   conf 0.7  -> review
    identical name  (POSITIVE CONTROL)  names_agree=agree   conf 1.0  -> auto

0.7 is below the 0.8 auto floor, so both non-agreeing verdicts route to review and never to auto. THE
CONTROL IS WHAT MAKES THE TWO DECLINES MEAN ANYTHING: it proves the apparatus can reach auto, so this
is not a vacuous pass by an assertion that could never fire. Non-vacuity was also shown by count --
1144 collected on the base commit, 1147 with the three new cases, so all three demonstrably RAN rather
than being silently skipped.

⇒ THE DISPOSITION IS DECIDED: the historical over-merges are ARCHAEOLOGY. The current auto-merge path
does not reproduce them, so the work is a one-off repair and re-resolve pass over existing data, NOT a
resolver code change. Every future install is unaffected.

SCOPE, STATED SO IT IS NOT READ AS MORE THAN IT IS. The EMAIL vector was executed. The PHONE vector
shares the identical names_agree gate and was READ, not run, so it declines by the same mechanism as a
matter of code reading rather than measurement. Fuzzy-name cannot score high on different given names
-- a standalone check put the two specimen given names at 0.51 against a 0.75 boundary, so there is no
knife-edge here. A FORCED OPERATOR DECISION bypasses the gate entirely, and that path, along with any
pre-gate version of the resolver, are the plausible provenances of the damage that exists.

OWNER: unassigned, and what is owed is now a REPAIR PASS with a defined scope, not an investigation.

### v1052-D007 -- assistant_answers_grounded failed for the SECOND consecutive walk and was investigated on neither

Recorded in `walks/v1.0.52.tsv`, and in `walks/v1.0.51.tsv` before it, where v1051-D004 says in as
many words that I did not investigate it.

This section exists so the count stays honest across two cuts rather than one. It is NOT a
disposition, NOT a severity assessment, and NOT a claim that the probe is the instrument rather than
the product. What has changed since v1051-D004 is only that the omission is now a pattern: a probe
that fails on every walk and is examined on none is indistinguishable, inside this register, from a
probe nobody has ever run.

OWNER: unassigned, and it should stop being unassigned.

### v1052-D008 -- freshness_panel_has_dates: the same defect as v1051-D001, unchanged, for the reason v1051-D001 named

Recorded in `walks/v1.0.52.tsv`. v1051-D001 root-caused it on the box: the panel reads install-time
`hydrate/<source>.done` sentinels that nothing rewrites, so the largest corpus on the box reports
`no_data` permanently; and the panel's source list disagrees with the sentinel directory in both
directions, hiding two healthy sources behind a list that anticipated drift the other way.

Nothing has changed and nothing was expected to. The renderer ships as a pinned image and the
deferral was explicitly a scope call about not adding an image rebuild to the launch critical path.

⚠️ NOTE THE COUPLING, WHICH WAS NOT VISIBLE WHEN v1051-D001 WAS WRITTEN. D003, D005 and D008 now ALL
wait on the same wiki-image rebuild and re-pin. Three deferrals resting on one absent prerequisite is
a different economic argument from one deferral, and it deserves re-deciding as a group rather than
inheriting three separate "not worth it on its own" verdicts. Whoever re-decides it should price the
rebuild ONCE, against three findings, before concluding anything.

### v1052-D009 -- no_store_port_is_tcp_reachable, and TWO RECORDED DISPOSITIONS THAT CONTRADICT EACH OTHER

Recorded in `walks/v1.0.52.tsv`. The subject is the wiki port and the search port, both loopback-bound
and both answering unauthenticated from the owning account, while the demonstrably-closed stores
return 401 on the identical request.

⚠️ THE DISPOSITION IS UNRESOLVED AND THIS SECTION DOES NOT RESOLVE IT. Two records disagree:

    v1051-D001..D004 era, in THIS file   Andy DEFERRED the close to v1.0.1
    task register, later entry           Andy decided to CLOSE these ports, re-confirmed

I did not witness the second, and a disposition read back from a register I wrote myself is not the
same kind of evidence as one taken from Andy. ONE LINE TO HIM SETTLES IT. Until it is settled the
status here is DEFERRED WITH THE CONFLICT NAMED, which is the only statement true of both records.
Do not let a later reader collapse this into whichever of the two they find first.

⚠️ STILL NOT MEASURED, unchanged from v1051-D002: whether a SECOND account on the same Mac can reach
these ports was CANNOT-RUN. It is inferred from topology, not demonstrated. Any row or release note
stating it as closed took that from inference.

### v1052-D010 -- no_unexpected_egress is the ONLY genuine new red on this walk, and its cause is undetermined

Recorded in `walks/v1.0.52.tsv`. MEASURED against `walks/v1.0.51.tsv`: this probe PASSED on v1.0.51 and
FAILS on v1.0.52. Of the three probes that appear to be new failures, this is the only one for which
"regression" is the right word -- the other two merely left CANNOT-RUN.

I DID NOT DETERMINE THE CAUSE. Two candidates are already on file and NEITHER IS ADOPTED HERE:

  - an enrichment path that is gated off, but whose one-shot pass has previously been shown not to
    honour the consent answer;
  - the assistant's web-fetch tool, which is on by default and unbounded by host.

Neither has been tested against this probe. Writing either into a fix, a release note or a code
comment before a discriminator runs would harden a hedged cause into a fact.

⚠️ SEVERITY IS UNASSIGNED, DELIBERATELY. On a product whose central claim is that the data does not
leave the Mac, an egress red is either the most serious finding on this row or an artefact of the
probe, and nobody has looked. Those two possibilities are three orders of magnitude apart and a guess
between them helps no one.

OWNER: unassigned. On this product, an unexamined egress red outranks everything else unclaimed here.

### v1052-D011 -- the cannot_run bucket: two probes, and the record does not say why

Recorded in `walks/v1.0.52.tsv`: `ingest_coverage` and `pair_state_agreement` were NOT MEASURED.
CANNOT-RUN is neither PASS nor FAIL, and this section exists so that neither is quietly assumed of
them. Two of 21 unmeasured is the honest denominator for every other claim on this row.

⚠️ THE REASONS ARE NOT RECOVERABLE FROM THE RECORD. The file says the reasons are withheld because
this repo is public and that `run_box_walk.sh` prints them under "PREREQUISITES THAT WERE ABSENT" --
that is, the reason existed on a console at walk time and the DURABLE artefact kept only the probe
names. So a reader here cannot distinguish an absent prerequisite from a broken probe, which is the
same gap v1050-D009 named and it has not closed.

WITHHOLDING the reason is correct for a public repo. DISCARDING it is not, and the two are separable:
a redacted reason CODE in the record costs nothing and preserves the distinction. That is the
improvement this section asks for, and it is not a product defect.


### v1057-D001 -- A1: the store-auth .pth froze the /tmp STAGING path, so the auth wiring never ran on any install

Read verbatim off the freshly installed box, not inferred from source:

    import sys, os; sys.path.append("/tmp/ostler-prelaunch-2026/lib"); ...

`_ostler_wire_store_auth_pth` defaulted its root to `${OSTLER_DIR}`, which points at the
temporary staging tree until the promote at the OSTLER-PROMOTE-BOUNDARY line -- and four
of its sixteen call sites run ABOVE that boundary. The staging directory does not survive
the install, so `__import__("ostler_store_auth")` failed at every interpreter startup, for
ever. Python answers that with **"Remainder of file ignored"**, which also discards the
`OSTLER_SECRETS_DIR` default on the same line, so cm059-editor reached the stores with no
credential, 401d hourly, and the Front Page never populated.

🔴 **A FILE-PRESENCE CHECK CANNOT CATCH THIS.** The `.pth` was present. The module was
present and correctly installed at `<final>/lib`. Only the path inside was wrong. Any test
asserting "the .pth exists" or "the module exists" passes on the defect, which is why the
fix ships with a BEHAVIOURAL gate: it runs the real function with `OSTLER_DIR` deliberately
pointed at a staging tree and reads back what the `.pth` actually contains.

FIXED at CM051 `21a63078` (#1316), rides v1.0.58, **in no artefact yet**.

### v1057-D002 -- macOS asked the customer to let Ostler "control Finder" and reach "documents and data"

Observed by Andy during the live walk. The installer sent one Apple Event to Finder
(`osascript -e 'tell application "Finder" to close windows'`), and macOS words that prompt
in its own voice, mentioning documents and data -- a sentence a customer reasonably reads
as the installer asking to read their files. Nothing in an install wants Finder.

**FIXED BY DELETION, NOT BY WORDING, AND THE REASON MATTERS.** macOS permits exactly ONE
`NSAppleEventsUsageDescription` per app and stamps it on every Apple Events prompt
regardless of target. No copy could have made that dialog honest while the event still
fired; v1.0.57 shipped a pre-announcement which softened the surprise but left the cause.
`open -R` survives and must: it is LaunchServices, not an Apple Event, and raises no TCC
prompt. The gate asserts both directions, because a fix that also killed `open -R` would
read identically to a clean pass on a Finder-only check.

FIXED at CM051 `0d104ebc` (#1315), rides v1.0.58, **in no artefact yet**.

### v1057-D003 -- the staging-freeze gate covers ONE artefact family, so a .pth walked straight through it

Not a defect in the shipped product; a defect in what guards it, and it is the reason
D001 is the third occurrence of its class rather than the first.

`tests/test_launchd_plist_no_tmp.sh` is a good gate. It discovers its subjects rather than
typing them, it has a floor so a collapsed match cannot read as clean, and it locates the
promote boundary by a marker rather than a line number. But it discovers them by matching

    VAR="...LaunchAgents/<name>.plist"

which is **one artefact family**. A `.pth` is not a LaunchAgent plist, so it was never in
the population the gate examines. The gate did not fail; it was never pointed at this.

Measured at the fixed pin: 8 writes above the contract line carry a value tainted from
`OSTLER_DIR`, of which exactly 1 is real (D001) and 7 are token or IP VALUES obtained via
`$(cat file)` or `openssl rand` -- tainted by name-flow only, and a token cannot freeze a
directory. That near-zero is trustworthy because both controls fired: the same taint engine
convicts #177 on its genuine pre-fix tree (`OLLAMAROTPLIST` carries `${_ollama_rot_logs}` ->
`${LOGS_DIR}` -> `${OSTLER_DIR}/logs`), and the `.pth` finding disappears when pointed at the
fixed branch.

OPEN. Widening the gate from "LaunchAgent plists above the boundary" to "any durable write
above the boundary whose CONTENT carries a tainted variable" is tracked separately and is
deliberately NOT in v1.0.58 -- a gate change inside a cut window is the class of thing that
has cost this project versions before.

### v1057-D004 -- the artefact was walked and no walk record was written

Filed against myself, and filed rather than omitted because an omitted process gap is
indistinguishable from one nobody noticed.

v1.0.57 was installed on a fresh account and exercised: the questions phase completed, the
install completed, and the 6-probe post-install QA subset ran ON THE BOX at **5 PASS / 1
FAIL / 0 CANNOT-RUN** -- the FAIL being install.sh's clean-completion claim over real
recorded errors, a known open item and not a new one. That is a real walk and it produced
D001, the most valuable finding of the sequence.

But the 21-probe harness was never run and `walks/v1.0.57.tsv` was never written, so this
register reads `[DERIVED(no record)]` for a version that really was installed. **The
consequence was immediate and measurable**: walk closure took the v1.0.58 dry run RED with
"v1.0.57 NO ROW. A cut with no row is indistinguishable from a cut nobody looked at." The
gate is correct -- from the tree, a walked-but-unrecorded cut and an ignored cut are the
same object.

⚠️ **AND IT COST NOTHING TO FIND**, which is the only good part. The gates-only dispatch
surfaced it before any tag was created. That is the v1.0.56 lesson applying itself one
version later, in the direction it was meant to.

### v1060-D001 -- the install printed a clean finish over two failed steps and an empty search index

**FIXED on main** (#1369 `16b3d219` names the failure; #1376 `e08869ab` names WHICH collections are missing).

Measured on the walked artefact, not reasoned: the final line of `~/.ostler/logs/install.log` reads
`DONE status=ok failed_steps=2 errors=0`. The run completed, carried two failed steps, and reported
`status=ok` anyway. The customer-facing wrap-up said the install finished with no errors raised.

The second half is worse than the first. The install had also just promised to create four Qdrant
collections and then asked `count -gt 0` about them -- **a cardinality test cannot see a missing
member.** The live store held three collections, two of the four promised were absent, and one
present collection was never in the creation loop. Count correct, claim false, wiki compiling
against an index that did not have what it needed.

⚠️ REMAINDER, NOT CLOSED BY THE ABOVE: #1376 closes the qdrant half AT INSTALL TIME. The
declared-vs-present manifest for LaunchAgents, cron, artefact dirs and import wires still only runs
on a box walk. That is tracked separately and is Andy's #599 idea (run the T+0 probe subset at the
end of a customer install).

### v1060-D002 -- two hydrate steps timed out at 90s and the wiki compiled against an empty store

**FIXED on main** (#1375 `dc9d85d3`).

Two hydrate steps returned rc=124 -- killed by their own cap. Six hardcoded `90` caps were doing it;
they are now named constants at 1800 and env-tunable, gated. #456 predicted exactly this failure on
a real install and it arrived.

🔻 A CORRECTION THAT BELONGS IN THE RECORD: my first sizing said "six bare-literal-90 sites". TNM
measured 8 lines / 6 capped steps. And I attributed the hour-long promise to `initial_hydrate` when
`wiki_compile` owns it. My cap-floor rule was also refused as unenforceable and replaced with a
defensible measured floor. Three corrections on one finding, all TNM's, all taken.

### v1060-D003 -- the installer promised a Tailscale sign-in twice AFTER the customer declined it

**FIXED on main** (#1370 `39e896b6`). Found by Andy live, mid-walk.

He answered "skip" to remote access and was then told twice that a Tailscale sign-in was still
coming: once in the post-questions wrap-up, once at the Full Disk Access gate. The install then
printed "Tailscale skipped" in the same run, contradicting itself. **Neither line consulted the
answer.** Both are read at the moment a customer is deciding how long they must stay at the
keyboard, so the false promise costs them real time.

The fix keeps the ACCEPTED and late-ask arms, which are load-bearing: deleting the promise outright
would have satisfied the declined case and broken a true promise on the two paths where the sign-in
genuinely is still to come.

### v1060-D004 -- ERR-06 told the customer "STORE-AUTH-LEAK" for a measured readiness timeout

**FIXED on main** (#1371 `318d513d`).

The #566 residual, seen live on this walk. #566 had already established the mechanism -- status=000,
a readiness timeout, NOT a 401 -- and five candidate mechanisms had died explaining a status code
nobody had measured. The mechanism was fixed; the NAME was not. The customer still read the word
LEAK for a timeout. ERR-06 now leads with the measurement.

### v1060-D005 -- the daily briefs were absent, and not broken: there was no LaunchAgent at all

**FIXED on main** (#1377 `477608ab`).

Andy: "daily briefings haven't worked for 10-15 builds." Measured on the box: there was no
daily-brief LaunchAgent present, and `[[cron.jobs]]` count was 0.

Mechanism, and it is a reuse-path defect: the reuse-settings re-run restores five values from
`config/.env`, which carries **zero** CHANNEL_* keys (measured, with a must-hit control on the keys
it does carry). The channel questions never execute under SKIP_PHASE2, config.toml is regenerated
anyway with no SKIP_PHASE2 guard between the questions block and the truncating redirect, the
brief-delivery resolver therefore resolves NO channel, and the re-run writes ZERO cron jobs. The
customer silently loses the morning brief and the evening wrap they already had -- while the reuse
prompt's own help text promises their previous answers are being carried over.

🗿 The fix shipped WITH a test that fails on the ORIGINAL defect, per #398, and it was verified
against the real pre-fix install.sh rather than a synthetic mutant: arms A and E go RED with
"reuse re-run wrote 0 [[cron.jobs]], expected 2 -- the customer lost their briefs", arms B/C/D still
PASS (so it discriminates rather than failing wholesale), and arm F reports CANNOT-RUN rather than
passing when its anchors are absent.

### v1060-D006 -- a contact labelled "Mum" produced a "gone quiet" card

**OPEN.** Fix exists upstream (CM041 #136), lands the cut AFTER v1.0.61 unless Andy pulls it forward.

⚠️ REFRAMED BY ANDY AND THE REFRAME IS THE IMPORTANT PART: this is most likely **#298 regressing** --
his wife is labelled "Mum" -- and NOT a missing deceased-state feature. He parked deceased-state by
decision. Do not re-derive this as a bereavement-handling gap; it is a people-dedupe regression.

Not pulled into v1.0.61 because a re-vendor at T-minus imports an unmeasured delta, and because A2
measured that the box-walk probe runs `--exclude-type import_wire` deliberately, so the CI red
cannot be rediscovered by a walk. **Re-vendor only to a CM041 SHA that has #136 merged**: on bare
main, row 117 goes GREEN via three helper files while `syncer.py` -- the actual write path -- is
still unguarded, which is a split state that misrepresents the fix.

### v1060-D007 -- freshness times render as decimal hours, and "0.0h ago" means nothing to a reader

**OPEN, UNOWNED, AND THE PRODUCER IS NOT FOUND.** Filed honestly as unresolved rather than guessed at.

Andy saw "0.2h ago" and "0.0h ago" on the freshness panel. Four renderers measured, and **all four
floor correctly and cannot emit a decimal**: the HR015 Doctor (`dashboard_components.py:292`,
`seconds // 3600`), the daemon SPA (`SystemStatus.tsx:58-72`, `Math.floor` at every step), the daemon
Rust (`mod.rs:930-946`, integer `mins / 60`, and a prompt string rather than a panel), and the HR015
doctor tree generally.

🔻 **My "it is the daemon SPA" narrowing is REFUTED by my own measurement.** Unprobed surfaces: CM031
iOS Swift, and the CM044 wiki compiler. Advice for whoever takes it, learned by wasting the time:
**find the PANEL first, then read its renderer.** Going renderer-first found nothing.

### v1060-D008 -- the artefact was walked and no walk record was written (SECOND CONSECUTIVE TIME)

Filed against the process, and filed rather than omitted because an omitted process gap is
indistinguishable from one nobody noticed.

`walks/v1.0.60.tsv` does not exist. The newest walk record on main is still v1.0.52. v1.0.60 was
genuinely installed and exercised -- it produced seven distinct defects, five of which are already
fixed -- so this is a real walk with no artefact of itself.

**This is the identical shape as v1057-D004, one cut later, which makes it a MECHANISM rather than an
oversight.** Both times the walk was performed by hand rather than through
`scripts/post_walk_qa.sh`, and the harness is the only thing that writes the record. A process that
depends on someone remembering to run a second tool after the interesting part is over will keep
producing this row.

⚠️ WHAT I DELIBERATELY DID NOT DO: I did not hand-write `walks/v1.0.60.tsv`. That file is generated
by the harness and its whole value is that it was produced by something that watched. Forging one
would defeat the mechanism it belongs to far more thoroughly than leaving it absent and saying so.
TNM reached the same conclusion independently and refused to write the row at all; they were right
to refuse on the evidence they held, and I am writing it only for the parts I can source.

⇒ SUCCESSOR WORK, not a T-minus fix: either the walk driver writes a record for a hand walk too, or
the gate learns to accept a DERIVED row with named provenance as a distinct third state from both
"harness record" and "nothing". Related to #599.

### v1063-D001 -- an empty owner email shipped into a LaunchAgent, and it reddened health_check too

`USER_EMAIL` is read from exactly ONE place: the macOS me-card via `osascript`.
On a Mac where Contacts.app has never been launched that call returns
`Contacts got an error: Application isn't running. (-600)`. The installer
ALREADY recognised that failure and warned about it; what it had was no
fallback and no guard. So the agent shipped `CM052_USER_EMAIL=""` and
`cm052.cli` refused once an hour, forever.

One empty string, two symptoms, neither naming the cause: `ai_conversations`
read `not_run` permanently, AND the same rc=2 folded through
`gui_step_record_rc` into `health_check`, which is why every service reported
`healthy` and the step still exited 2.

A warm GUI app is the property LEAST likely to hold at install time -- the
installer runs on a machine somebody has just set up.

**FIXED on main**, CM051 #1418: a GUI-free second source
(`Accounts4.sqlite`, opened `immutable=1` so it takes no lock) plus a guard
that refuses to register an agent that cannot succeed and records
`owner_email_unknown_agent_not_registered`. The fallback PICKED THE WRONG
ADDRESS on the first box it met and the code says so: the account-identity
address is not the one the owner uses. It ships because a plausible-but-wrong
address is correctable in one field while an absent one leaves the source dead
until somebody notices. **The real fix is to ASK, pre-filled, and that is not
done.**

🔴 **CORRECTION, 2026-09-04T14:38:35Z. ONLY ONE OF THE TWO SYMPTOMS WAS FIXED, AND
I WROTE THE SENTENCE THAT SAID OTHERWISE.** The row above says this row's two
symptoms were fixed in #1418. The LaunchAgent half was. The `health_check`
half was NOT, and v1.0.64 shipped carrying it.

The guard #1418 added sits **BELOW** the fold it was supposed to prevent:

```
install.sh :29038   CM052_USER_EMAIL="${USER_EMAIL:-}"  ...  <- drain runs anyway
install.sh :29055   gui_step_record_rc "$_aiconv_rc"         <- rc 2 folded HERE
install.sh :29185   if [[ -z "${USER_EMAIL:-}" ]]            <- the #1418 guard
```

So on v1.0.64 the producer is still invoked with an empty address, still exits
2, and the install still ends `failed_steps=1` with a red final step while
every service inside it logs healthy. Re-measured against the installed binary
on the Mini, with a control:

```
CM052_USER_EMAIL="" pwg-ai-convo --source all --json   -> exit 2
CONTROL, same binary:  pwg-ai-convo --help             -> exit 0
```

**WHY IT SURVIVED A REVIEW, AND THIS IS THE TRANSFERABLE PART.** The defect is
an ORDERING between a guard and a fold, and after #1418 **both were present in
the tree**. Every structural check over the source -- "is there a guard", "is
the reason recorded", "is the plist protected" -- answers YES on a tree that
still ships the bug. No pattern distinguishes *guarded above the fold* from
*guarded below it*. Only executing the block does. The v1.0.64 cut manifest
states this defect as fixed on exactly that evidence, and so did I.

**ACTUALLY FIXED**, CM051 #1428, riding v1.0.65: one predicate
(`_aiconv_owner_email_known`) read by BOTH consumers, so the drain and the
LaunchAgent registration cannot disagree, and a RUNTIME test that extracts the
real block and runs it against a stub producer exiting 2. Two pinned controls,
`45126e9a` (the v1.0.63 cut) and `deecd9fc` (#1428's own parent), and **both
reproduce the failure** -- the second is what proves v1.0.64 did not fix it.
Plus a negative control on the fix itself: with an address present the rc MUST
still be folded, so deleting the fold is not the cheap way to green.

⚠️ **A COLD MAC IS THE NORMAL CUSTOMER MAC**, and the walk subject for v1.0.65
is a brand-new account that has never opened Contacts. Walking v1.0.64 on it
would have reproduced this exact red step on the one genuinely cold account
available.

### v1063-D002 -- the source-status surface only ever reported the install-time run

Measured on the box: all eleven hydrate sentinels stamped between 08:29:38Z and
08:45:04Z -- install time -- while `imports/fda/imessage_conversations.json` was
rewritten at 09:17:19Z with 167 conversations and 136 people created. The
extract moved and the record did not.

Nothing outside `install.sh` had ever written a sentinel, so ongoing ingestion
did real work and updated nothing. `/api/v1/sources` still answered
`imessage status=no_data item_count=0` for a source that had just delivered.
The route's own docstring promises it shows "whether a source landed AND
WHETHER IT KEEPS UPDATING" -- the second half was unanswerable by construction.

A source that failed at install showed failed forever after it recovered; one
that worked showed `ok` forever after it died. **Andy asked twice for a check
that each source ingested AND that ongoing ingestion works. The product could
not answer the second half at all.**

**FIXED on main**, CM051 #1418. Two records, never one repurposed:
`state/hydrate/<n>.done` keeps its install-time meaning, and a new
`state/source_activity/<n>.tsv` carries `last_run_at` + `last_success_at` from
the recurring tick. `last_success_at` is carried forward on a failing run so a
broken source still shows when it last worked. Three ongoing states, and the
third is the one that matters: `never` means no record at all and is NOT
reported as a failure -- inventing one is as bad as hiding one.

⚠️ The tick's key names are NOT the canonical ones -- it writes `apple_mail`,
`browser_history`, `bookmarks`, `people_index`. Only 3 of 9 records joined on
first contact with a real box. An explicit alias table now bridges them, with a
control asserting `apple_notes` is never joined to `apple_mail`'s record by a
loose match. **Caught on the box, not in the tests: the suite was green because
both sides of the join were written from the same wrong assumption.**

### v1063-D003 -- RULE 2 was enforced on ONE of the TWO merge paths, and the count grew for three cuts

Measured independently of the walk probe, with a matched control:

    over-merged Person nodes                   137
    Contacts cards swallowed                   286  (149 people with no node)
    CONTROL: icloud_contact_uid identifiers   2261
    CONTROL: correctly single-uid nodes       1975  (so the zero was reachable)

RULE 2 -- "MUST NOT MERGE: different canonical keys" -- was implemented in
`IdentityResolver`, and the register recorded that as "stops NEW ones". It
stops new ones ON THE RESOLVE PATH. `batch_resolver --execute --converge` is
the other path: `install.sh` runs it on EVERY install and the dedupe-catchup
agent re-runs it hourly. It reached the graph through raw SPARQL in
`_merge_oxigraph` and had never heard of the veto. There is exactly ONE caller
of `merge_persons()` and it IS guarded -- **this path never called it**, which
is why every audit that started from the guarded function came back clean.

That is why the number GREW while the fix was believed to be in place:
128 (v1.0.38) -> 130 (2026-08-26) -> **137** here, with the walk probe failing
on v1.0.52, v1.0.61 and v1.0.63.

**FIXED on main**, CM051 #1418. The veto is applied per pair before any write,
FAILS CLOSED if the store cannot be read, and prints its refusal count. Red-
first: 1 pass / 3 fail against 45126e9a, 4 / 0 after.

🔴 **I ASSERTED THREE WRONG CAUSES ON THIS DEFECT BEFORE READING THE CODE** --
the resolver's single-match path, then `_identifier_match_trustworthy`, then
the fuzzy tier. Each was plausible and each was refuted by the next read. What
found it was enumerating every CALLER of the merge primitive and noticing the
shipping path was not among them. **When a guard is present and the defect
persists, stop auditing the guard and enumerate the callers of what it guards.**

**GRAPH REPAIR APPLIED TO THE FOUNDER INSTANCE ONLY**, with Andy's explicit
go-ahead and a movelog: 137 -> 46 nodes, 286 -> 94 cards, identifier control
pinned at 2261 so nothing was destroyed, single-uid 1975 -> 2167 reconciling
exactly with the 192 cards freed. **The customer-install policy for that repair
is NOT decided.** 46 nodes remain: 51 cards whose origin node was erased at
merge time and 14 where no card is provably native. The tool refuses to guess.

### v1063-D004 -- install_manifest_complete had never adjudicated, on any walk, since v1.0.50

It returned CANNOT-RUN whenever `OSTLER_BOX_HOST` was set, on the correct
observation that the verifier reads the TARGET's filesystem. The conclusion
drawn from that was wrong: "I cannot run where I am" is a reason to run
somewhere else, not to give up. **Every walk is driven remotely**, so five cuts
shipped with this gate never once returning a verdict, filed under "not
measured" -- a column nobody read.

**FIXED on main**, CM051 #1418: the verifier is carried to the box over the
existing ssh transport and run against its own `$HOME`. Decoded with `python3`,
not `base64 -d`: macOS shipped `base64` with `-D` and without `-d` for years,
and the wrong flag writes an EMPTY file -- an empty verifier runs and finds
nothing, a false zero wearing the shape of a clean install.

⚠️ **ITS FIRST VERDICT WAS 3 FALSE POSITIVES AND 1 REAL GAP**, and I reported
all four as defects before checking. `com.ostler.enrich` is deliberately not
installed (`OSTLER_ENRICH_AGENT_ENABLED` defaults to 0 -- it is standing
outbound traffic the customer must opt into). The two brief cron jobs ARE
installed and enabled, as `[[cron.jobs]]` in the assistant TOML -- I checked
`crontab -l`, which is the wrong surface, and got a clean believable zero.
**Only `context-refresh` being undeclared is real.** The gate cannot adjudicate
a cut until its manifest matches these deliberate decisions. OPEN.

### v1063-D005 -- the pairing flag was asked of the wrong service, and the parse would have lied

`pair_state_agreement` returned CANNOT-RUN on every recorded walk: only one
device-layer signal was readable, and one signal cannot contradict itself.

The flag was never missing. `:8089/doctor/api/health` carries no `paired` key
-- the probe's own note says so, correctly -- while `:8000/health` returns
`{"companion_paired":false,"paired":false,"require_pairing":true,...}`.

🔴 **REPOINTING THE URL ALONE WOULD HAVE BEEN WORSE THAN THE BUG.** The parse
was `*'"paired"'*'true'*`, which matches `true` ANYWHERE AFTER the key. The
live body carries `"paired":false` followed by `"require_pairing":true`, so
that arm matches and the probe reports PAIRED on a box with no phone. It had
never fired only because the endpoint it was pointed at had no such key. **A
permanent CANNOT-RUN would have become a confident wrong answer.**

**FIXED on main**, CM051 #1418: parsed as JSON and read BY KEY, control
mutation-tested against the old glob, and reader and control share ONE function
-- the first draft inlined a second copy of the parser and would have gone
green with the real reader still broken. CANNOT-RUN -> PASS on the box.

### v1063-D006 -- usage_journal_producers has failed on ALL FIVE walks that measured it, and the journal exists

The Bursar is the paid tier's justification and the probe has reported it
broken on v1.0.50, .51, .52, .61 and .63. **It is a gate defect.**

    probe reads   ~/.ostler/workspace/state/costs.jsonl                 DOES NOT EXIST
    daemon writes ~/.ostler/assistant-config/workspace/state/costs.jsonl 175020 bytes, 684 records

The daemon gets `ZEROCLAW_WORKSPACE` from its LaunchAgent; an ssh probe session
does not, so it falls through to a directory `install.sh`'s own comment
describes as "a DIFFERENT directory nothing reads back". `active_workspace.toml`
-- the marker that would let any reader resolve correctly -- has **0 hits in
install.sh**.

⚠️ **I TOLD ANDY THE BURSAR HAD NEVER WORKED, ON THE STRENGTH OF THIS PROBE,
AND RETRACTED IT.** TNM held the evidence and had told me not to say it. Same
shape as the crontab in D004: a true reading of the wrong surface.

**OPEN.** Two jobs, not one: make the resolver find the workspace from a
CLEARED environment (`env -i`), and SEPARATELY reconcile the panel's arithmetic
-- 73 model calls / 23.5K tokens against a 684-record journal may or may not
agree, and assuming it does because the file exists is the same mistake in the
opposite direction.

### v1063-D007 -- the freshness panel omits three sources it holds current data for

The panel renders 9 of the 13 canonical sources. `calendar` (updated
10:27:34Z), `contacts` (08:29:38Z) and `email` (08:31:18Z) all have fresh data
in `/api/v1/sources` and **no row at all**. An absent row is not a neutral
omission: the customer is shown a currency report that silently excludes a
source they rely on.

The probe itself was also wrong and is **FIXED on main** (CM051 #1418): it
compared `settling_progress.d` keys against panel rows, and those two sets had
**ZERO overlap** -- not one key in common -- so all four ingested keys reported
missing and all four were wrong as stated. The filename carries the sub-source
(`messages.imessage.json`), so most of the map is derived; `contacts -> people`
was deliberately NOT aliased, because contacts is its own canonical source and
its absence is a real gap rather than a naming artefact.

    before   NO ROW for calendar contacts emails messages   (4, all spurious)
    after    NO ROW for calendar contacts email             (3, all real)

**The remaining gap is in the CM044 wiki compiler**, which owns the renderer.
OPEN.

### v1063-D008 -- nothing routes iMessage or WhatsApp into the conversations store

`ingest_coverage` reports the `conversations` collection EMPTY. Its declared
mapping is `conversations <- imessage, whatsapp, ai_conversations`.

The only writer in the tree is `vendor/cm048_pipeline/src/ingest.py`. The only
agent driving cm048 is `com.creativemachines.ostler.spoken-bundle`, which reads
`~/Documents/Ostler/Transcripts` -- RemoteCapture voice transcripts -- and
correctly found zero, because Andy has recorded no calls.
`pwg_ingest.ingest_imessage` writes the PEOPLE GRAPH, not conversation vectors.

**So on a customer install that store is fed by voice alone, while the coverage
probe declares three sources feed it. Two of the three have no route to it
anywhere in the tree.**

**OPEN, and the two possibilities need OPPOSITE fixes**: either the wiring is
missing, or the probe's mapping is aspirational and `conversations` is a
voice-only store. CM040, the conversation-memory extractor, is personal infra
per CLAUDE.md and may never have been in the product -- that is the first thing
to check. **Not guessed here.**

### v1063-D009 -- identity_resolver declared 1 of its 3 dependencies

`requirements.txt` exists specifically because PR #109 added a `rapidfuzz`
import without declaring it. The same omission was sitting in the same package,
twice: `phonenumbers` (normalise.py:6) and `httpx` (resolver.py,
batch_resolver.py) were both undeclared.

It stayed invisible because every environment that runs this package -- the
installed venv, a developer machine, the box -- already had all three from a
sibling requirements file. **A dependency list is only tested by an environment
that has nothing**, and building one clean venv found it in seconds.

Enumerated rather than added one traceback at a time: chasing them one failure
at a time is how a list ends up one short again.

**FIXED on main**, CM051 #1418. Control: a venv built ONLY from that file now
runs the converge test, 4 pass / 0 fail.

### v1063-D010 -- the fda-rerun agent is bootstrapped 38 seconds before its binary exists

    ~/.ostler/logs/fda-rerun.err   08:23:35Z  "ostler-fda not found/executable ... re-run the installer to repair"
    ~/.ostler/bin/ostler-fda       08:24:13Z  installed 38 SECONDS LATER

Every customer install writes "re-run the installer to repair" into its own
error log on the first tick. Harmless -- the agent retries hourly and the
second tick succeeds -- and alarming to anyone who reads it, which on a support
call is exactly who does.

**OPEN.** Bootstrap after the binary is installed, or make the first tick quiet
when it is not yet there.


### v1061-D001 -- five raw Python tracebacks reach the customer during the passphrase step, and the step still reports status=ok

OPEN (#622).

Andy's finding on the live walk. During the passphrase step the installer printed five raw Python
tracebacks to the customer, and the step then recorded `status=ok`.

**This is the third member of the honesty class named in #625**: `status=ok` is a claim about the
STEP, never about the DATA and never about what the customer was shown. A step can print a stack
trace, do none of its work, and still exit 0. v1060-D001 was this same shape at the whole-run level
(`DONE status=ok failed_steps=2`); this is it at the step level, one cut later.

A traceback is also the most alarming thing a non-technical customer can be shown, and it lands at
the passphrase step, which is precisely where they are being asked to trust the product with a
credential.

### v1061-D002 -- install.sh tells the customer the AI model is "~5 GB". It is 7.2 GB, measured on the box

OPEN (#623).

Measured on the walked box rather than read off a spec: the model the installer downloads is 7.2 GB.
The copy says "~5 GB". That is a 44% understatement of the largest single download in the install,
given to the customer at the moment they decide whether to continue on a metered or slow connection.

⚠️ RELATED, NOT THE SAME: #544 records a 52-minute silent step and a 3.43 GB vane image. Download
honesty is a CLASS here, not an instance. Fixing this one string without auditing the other
advertised sizes leaves the class alive and the next cut re-finds it.

### v1061-D003 -- the import attempted 3810 people, stored 0, and reported success

**FIXED on main** (CM051 #1385, `4e1bd89a`).

On a cold install Qdrant collections do not self-create
(`feedback_qdrant_collections_no_self_create_fresh_install`). A readiness miss at T+0 left them
absent, `import_data` embedded every person, 404'd on the missing collection, and discarded 3810 of
3810 people while the step reported `status=ok`.

The fix has two halves and the second is the one that matters. The import now REFUSES an unready
store rather than running into a void, AND an import that attempted people but stored none FAILS. A
refusal alone would have left the silent-loss path reachable by any other route to an empty store.

🔻 A CORRECTION INSIDE MY OWN FIX, RECORDED BECAUSE IT IS THE SAME CLASS AS THE DEFECT: the first cut
of the yield floor read its input with `grep -c ... 2>/dev/null || printf '0'`, which reports an
UNREADABLE log as "attempted 0" -- and attempted-0 is exactly the value that makes the floor decline
to fire. **I shipped a fail-open while fixing a fail-open.** The count is now read behind an `-r`
guard and reports CANNOT-RUN, which is a third state and not a pass. The log is also no longer
deleted one line before the failure that cites it as evidence.

### v1061-D004 -- a LOCKED store read as EMPTY, and bought a redundant re-ingest

**FIXED on main** (CM051 #1386, `c7b2c3ac`).

The store was locked, not empty. The predicate that asked could only answer two ways, so "I cannot
read this" and "there is nothing here" collapsed to the same value, and the install responded to the
wrong one by re-ingesting data that was already present.

Now tri-state. **CANNOT-RUN is not FAIL and is not PASS.** A two-state predicate that meets a third
condition will always answer with whichever of its two states is cheapest to reach, and it will do
so silently, which is what makes this class expensive rather than merely wrong.

### v1061-D005 -- the install step denominator shrank mid-run, 41 to 40, and nothing said so

OPEN (#627).

The customer-facing progress counter changed its denominator during the run and nothing announced it.

Low customer harm, high diagnostic harm. A denominator that moves silently makes every percentage
before and after it incomparable, which means our own progress telemetry cannot be used to compare
two runs -- and comparing runs is most of how a walk regression gets caught. Same reading hazard as
the zero-denominator in #533: the number wears the format of a measurement and is not one.

### v1061-D006 -- the walk-killer: a space after a line-continuation backslash at install.sh:26690

**FIXED on main** (CM051 #1386, `c7b2c3ac`).

This is what ended the walk at 97%. A backslash followed by a SPACE is not a line continuation. The
line ends there, and what should have been its continuation becomes a separate command.

🗿 **NO PARSE-LEVEL CHECK WE OWN COULD HAVE CAUGHT IT, AND THAT IS THE DURABLE LESSON.** `bash -n`
EXITS 0 on the real pre-fix file. The file is syntactically valid; it simply does something other
than what it reads as. A shape-reading gate now exists and it ships with a `--self-test`, because a
gate that cannot demonstrate its own RED is a gate nobody can trust.

⚠️ THE PROOF THIS CUT MUST CARRY: run `scripts/verify_no_broken_line_continuation.py` against the
**MOUNTED DMG's** install.sh, not the repo copy, and run `--self-test` first. REPO LAYOUT IS NOT
PAYLOAD LAYOUT, and the defect was in the shipped file.

### v1061-D007 -- three probes have now failed on FOUR CONSECUTIVE walk records, and not one was investigated

OPEN. Filed against the process, and measured directly from the records rather than recalled.

`assistant_answers_grounded`, `freshness_panel_has_dates` and `usage_journal_producers` appear in the
`failed_probe` list of every walk record we hold from v1.0.50 onward:

| record | verdict | the three probes |
|---|---|---|
| walks/v1.0.50.tsv | FAILED | all three present |
| walks/v1.0.51.tsv | FAILED | all three present |
| walks/v1.0.52.tsv | FAILED | all three present |
| walks/v1.0.61.tsv | FAILED | all three present |

**v1052-D007 ALREADY FILED THIS AT TWO CONSECUTIVE**, and its title says so in as many words:
"assistant_answers_grounded failed for the SECOND consecutive walk and was investigated on neither".
It is now four. A register that records a recurrence and does not change what happens next has
documented a habit rather than fixed one, which is the sentence the v1.0.59 row uses about me.

⚠️ WHAT THIS FINDING DOES NOT CLAIM: it is not a v1.0.61 regression. It is a standing condition that
predates the cut, and the walk record is simply the instrument that makes it countable. Each probe
has a live register row already -- #510 (assistant grounding), #514 (freshness panel), #482 (usage
journal producers) -- and #482 in particular records that 4 of 5 required producers have NO CHANNEL
to the journal at all, so that probe may be failing for a structural reason no fix to any cut can
address. If so, the honest move is to say that on the probe, not to keep reporting it as a red the
next cut might clear.

⇒ SUCCESSOR WORK, not a T-minus fix: either these three get an owner and a disposition before the
next walk, or the harness marks a probe that has failed N consecutive walks as a KNOWN-FAILING state
distinct from a fresh red -- so that a genuinely NEW failure is not lost among the standing ones,
which is the actual risk a persistent red creates.

### v1065-D001 -- the install aborts at step 21 because a function is called above its definition

MEASURED on walk 10, the first walk ever to reach step 21 of 40:

    #OSTLER STEP_END id=email_ingest status=error elapsed_s=5 rc=127
    Install aborted unexpectedly at line 21445 (step email_ingest):
        _OSTLER_CONSENT_TP_EMAIL="$(_ostler_consent_state ...)"

rc=127 is "command not found". install.sh is a LINEAR script whose step bodies
are top-level statements executed in file order. The assignment sat at 21445
and `_ostler_consent_state` was defined at 21494, 49 lines below it.

**THIS IS A SAME-DAY REGRESSION OF MINE, NOT A LATENT DEFECT**, and the first
version of this record said the opposite:

    v1.0.63   the function does not exist at all
    v1.0.64   the function does not exist at all
    v1.0.65   BROKEN, call 21321, definition 21370

`git log -S` puts BOTH halves in ONE commit, e7b835ba (#1423, 2026-09-04
20:45:16 +0800), and `git tag --contains` returns v1.0.65 alone. I wrote that
it "shipped unnoticed because no walk got deep enough"; Andy refuted it on
sight, because plenty of DMGs have installed to the end. Ageing a defect
backwards makes a repair look like a discovery and points the next reader at
the harness instead of at the change that caused it.

**FIXED on main, CM051 #1439.** A pure relocation, verified by the sorted line
multiset being byte-identical to the parent. TNM's review corrected the
account: the anchor deltas show the CALL moved, carrying a `TOTAL_STEPS`
decrement whose misplacement is v1061-D005, and he measured 0 of 26
`TOTAL_STEPS` references inside the moved window with progress-step counts of
41/41 either side. Safe by measurement, not by my argument.

⚠️ The regression test guards ONE function and is blind to the class. TNM
mutation-tested it: a different function with the same shape passes 7/7. The CI
step is named for the function it actually checks. **A generic class test is
OWED** and needs his unbound-name execution, because a sweep keyed on "line
begins with the name" cannot see the `$( )` shape that broke the install.

### v1065-D002 -- contacts and Places have never imported, since v1.0.60

MEASURED on the box from the installer's own diagnostic logs, walks 11 and 12:

    hydrate-contacts.log
      File ".../import-pipeline/contact_syncer/syncer.py", line 35
        from contact_syncer.photo_storage import remove_photo, write_photo
      ModuleNotFoundError: No module named 'contact_syncer.photo_storage'

    places-ingest.log
      No module named contact_syncer.places_ingest

`install.sh:17729` copies the ROOT `contact_syncer/` into
`~/.ostler/import-pipeline`. That copy had 19 modules; the complete vendored
copy at `vendor/cm041/contact_syncer/` has 24, and the two it lacks are two the
installer runs. The two `syncer.py` differ in size (65,023 vs 64,362 bytes), so
the root copy is a DIVERGED PARTIAL rather than a stale mirror.

**THE CUSTOMER-VISIBLE SHAPE IS WHY IT SURVIVED SIX CUTS.** hydrate dies at
`elapsed_s=0`, the customer is told "your contacts are on this Mac but Ostler
imported 0 of them", and the install then reaches its end and reports
`DONE status=ok`. Nothing about a completed install says the contacts never
arrived.

Present in v1.0.60, .61, .62, .63, .64 and .65, every tag checked directly with
`git cat-file -p`. **`git show <tag>:<path>` was discarded as an instrument**:
under zsh it returned EMPTY with rc=0 for a blob `cat-file` reads at 65,050
bytes, because `:c` is consumed as a zsh modifier.

**FIXED on main, CM051 #1442.** TNM reviewed it by attacking completeness,
expecting three further missing modules, and his own measurement refuted him:
five are absent but only two are reachable, one by intra-package import and one
as an install.sh `-m` entry point. The accompanying test resolves BY PATH rather
than `find_spec`, because `find_spec` imports the parent package and turned a
submodule question into `No module named cryptography` on ostler_security.

⚠️ **NOT reconciled: the root and vendored `syncer.py` still differ.** The fix
restores two absent modules; it does not close the divergence.

### v1065-D003 -- a hydrate counter aborts the install when its producer fails, then declares a cause nobody observed

Found by TNM after two of my own reductions failed and I posted "I do not know".
`install.sh:25424` is a command substitution containing a pipeline with **no
`|| { ... }` guard**, sitting immediately after a guarded producer. The
expensive call was defended and the arithmetic after it was not.

Class measured BY EXECUTION, not by parse:

    23 multi-line candidates, 4 skipped, 19 measured
    11 abort, 8 survive, 0 CANNOT-RUN
    parse said 20 unguarded; execution said 11
    10 of the 11 are the hydrate step family

**A parse-only report would have handed over nine sites that are not defects.**
Single-line substitutions remain an UNMEASURED population and the "30 pipelines
/ 330 substitutions" intersection is still open.

🔴 **AND THE FIX ALONE WOULD HAVE BEEN WORSE THAN THE DEFECT.** TNM found that
his own guard composed with two other correct things into a false statement:

    W012 (merged)       gave the zero a DECLARED reason
    the abort guard     made a failed counter yield ""
    a pre-existing :-0  turned "" into 0
    ------------------------------------------------------
    a run that FAILED and a run that FOUND NOBODY emitted BYTE-IDENTICAL sentinels

He reported it against himself rather than shipping it. **A declared cause is
safe only while the value it explains cannot be manufactured.** #1443 was
therefore HELD and landed together with #1450, never alone: a loud abort is
better than a quiet fabrication.

**FIXED on main, CM051 #1443 + #1450.** Nine per-source `*_UNMEASURED` flags
replace a shared global the file's own comment at 26196 warns against; 0
references to it remain. One site of the eleven was withdrawn on review: 26194
is already inside a `set +e` bracket and the guard there would have stolen the
`rc=$?` that drives the 124/137 WhatsApp timeout arm.

⚠️ **STILL OWED**: `_HYDRATE_EMAIL_COUNTS_UNMEASURED` and `_AICONV_UNMEASURED`
are set and never read. Neither site has been traced, so neither is claimed as
a defect. And the sentinel STATUS is still `no_data` in both cases -- only the
DETAIL was made honest, because a true status needs volume counts
`ingest_imessage` does not return.

### v1066-D001 -- the two UNMEASURED flags v1065-D003 left owed are traced, and both were dead

**This closes the "STILL OWED" note at the foot of v1065-D003.** Both sites are
now traced and both were real. Measured against the SHIPPED v1.0.66
`install.sh` (sha256 `e1cdd10c`, the blob inside the DMG):

    _HYDRATE_EMAIL_COUNTS_UNMEASURED   occurrences=1
    _AICONV_UNMEASURED                 occurrences=1

**One occurrence means ASSIGNED, then read by nothing in the entire file.** Both
sit on the failure arm of a command substitution, and in both cases the very
next lines MANUFACTURE the value whose absence was just recorded:

    )" || { _HYDRATE_EMAIL_COUNTS_UNMEASURED=true; _HYDRATE_EMAIL_COUNTS=""; }
      -> case ''|*[!0-9]*) _HYDRATE_EMAIL_COUNT=0
    )" || { _AICONV_UNMEASURED=true; _AICONV_COUNT=""; }
      -> _AICONV_COUNT="${_AICONV_COUNT:-0}"

So a counter that COULD NOT RUN was published as a MEASURED ZERO. Email then
landed on `no_correspondents_in_window` -- a cause nobody observed, shown to a
customer for a count nobody could take. **This is exactly the composition
v1065-D003 warned about, surviving in the two arms that never got the guard.**

Calendar and contacts already carried it. Seven flags in the family, five
consulted, two not, and nothing in the tree could tell you which.

**FIXED, CM051 #1457.** Email mirrors calendar including the reason string
`counter_failed_count_unmeasured`, so the two encode ONE state. Aiconv uses
`_hydrate_sentinel_record_cannot_run`, which already existed. Email ALSO gets a
`settling_report emails 0 0 true` that calendar does not need: email calls
settling on every other path (5 of 5) and `install.sh:26136` requires the
channel to appear, so omitting it would have made this the one email path whose
row vanishes from the panel.

**GATE**: `tests/test_an_unmeasured_flag_must_be_read.sh`, 6 limbs, 4 synthetic
controls (one MUST-FLAG, three MUST-MISS: a guard that is present, a `${BRACED}`
read, and a shorter flag name inside a longer one), plus a negative control
pinned to `a752275d` which must name both dead flags and does. Mutation:
removing the email guard alone gives rc=1 naming that flag.

Reporting honesty, not data loss. No install aborts. Scoped to v1.0.67.

### v1066-D002 -- a subshell emits a TERMINAL DONE, so a healthy install shows a failure banner

`set -E` propagates the ERR trap INTO a command substitution's subshell. The
child emits a terminal marker and sets `OSTLER_DONE_EMITTED=1` **inside itself**,
then dies with the flag. Measured by TNM on `/bin/bash` 3.2.57 by instrumenting
the real shipped test with `$$` and `$BASH_SUBSHELL` at every emit:

    pid=55691  subshell=1   DONE status=fail  code=ERR-99-INSTALL-ABORT-L9
    pid=55691  subshell=0   DONE status=ok    failed_steps=0 errors=0

Same process. `fail` then `ok`.

**THE EXPOSURE IS NOT THE `local` SUBSET.** Both TNM and Archie published
"9 `local X=$( )` sites" and both independently corrected it to **2** within
four minutes, because `$((` arithmetic matches any pattern anchored on `$(`.
The two are `date +%s` and `printf | tr`, both benign. The real mask is:

    X="$( ... )" || { ... }     19 sites, EVERY hydrate counter
    bare X="$( ... )"          410 sites, no mask -- parent aborts too
    if X="$( ... )"; then        3 sites, ERR suppressed, safe

and walk 11's abort at `install.sh:25448` names `tail -n 1`, a command inside
exactly that shape, after which the install ran 29 more steps. **Field evidence
that the subshell speaks while the parent survives.**

**CUSTOMER IMPACT, measured from the consumer side rather than assumed.**
`InstallerCoordinator.swift`: `finished` is overwritten by each DONE (1825),
`failureState` is COMPUTED not stored (227), and `process.terminate()` is
reached ONLY from user-initiated `cancel()` (1142). So a phantom renders the
failure banner carrying `ERR-99-INSTALL-ABORT-Lnnnn` during a HEALTHY install,
does NOT kill install.sh, and REVERTS when the parent's DONE arrives.

⇒ **Not a false success. Not a killed install.** A scary error code shown to a
customer whose install is fine. Residual risk is a customer who acts on that
banner. **High-priority v1.0.67 fix, NOT a launch blocker.**

**FIXED, CM051 #1459**: `[ "${BASH_SUBSHELL:-0}" -gt 0 ] && gui_log error ... &&
return` near the top of `_ostler_on_err`. The `gui_log` before the `return` is
load-bearing: the log stream survives the subshell, the flag does not, so the
failure is still recorded and only the TERMINAL marker is suppressed.

⚠️ **DO NOT hoist `OSTLER_DONE_EMITTED`.** `lib/progress_emitter.sh:717-725`
already measured that at **0 DONE markers**, and it mutes the EXIT backstop too.
The obvious fix is the wrong one and the measurement is on the record.

⚠️ **STILL OWED**: nothing anywhere covers the **fail-then-ok** transition.
`FailureStateMachineTests` asserts `status=fail -> .failed(step:)` and stops.
The revert works only because `failureState` is a computed property, so the
half of the severity argument above that says "it reverts" is unpinned.

### v1066-D003 -- the admin-token mirror is startup-only and two of its four outcomes are invisible

Filed at TNM's request so it is not rediscovered from scratch. **Not the cause
of anything observed** -- it was his hypothesis for the `/ws/chat` 401, and the
401 turned out to be a port collision (see v1066-D004) -- but the code reading
is correct and worth keeping.

The mirror has ONE production writer, it runs at startup only, and **two of its
four outcomes are below the shipped log level**. Consequence: **a daemon that
never trusted the admin token is indistinguishable from one that did.**

Not v1.0.67: `DAEMON_COMMIT` is pinned and that cut rebuilds no daemon. This is
an observability gap in `oa`, to be picked up when the daemon pin next moves.

### v1066-D004 -- the box-walk probe blamed the product for another account's service

**HARNESS, not product, and it cost hours of product investigation.** On the
v1.0.66 artefact walk `daemon_is_listening` reported:

    FAIL -- config loads cleanly but NOTHING is listening on :8000
            (launchd last_exit=0). The daemon is failing after config parse.

Every word of that diagnosis was wrong:

    curl --noproxy '*' http://127.0.0.1:8000/     ->  HTTP 200
    ps -Ao user=,pid=,lstart=  ->  andy   20075   running since the day before
                                   archie 91136   this walk's daemon
    archie's ostler-assistant.err  ->  27x "Address already in use (os error 48)"
                                       and ZERO successful binds

**Another account's Hub held the port.** `lsof` ran as the walked account and
cannot see a socket owned by a different user, so it returned 0, and the probe
read that PERMISSION BOUNDARY as ABSENCE.

**Two faults, and the second is what made it a FAIL rather than a CANNOT-RUN:**

1. `2>/dev/null` on the enumeration. Wrong on principle -- but MEASURED, it does
   not fire here: macOS `lsof` gives **rc=1, 0 stdout lines, 0 stderr BYTES**,
   and rc=1 is also what a genuinely empty port returns. **Neither stderr nor
   the exit code discriminates on this platform.**
2. `if [ "$signals" -eq 0 ]` required **BOTH** lsof AND launchctl to be silent.
   launchctl answered, so the CANNOT-RUN arm was skipped. **The honest verdict
   was one branch away and an AND closed it.**

Ten sibling probes failed downstream of the same fact, and it also explains the
`/ws/chat` **401** investigated for hours as a provisioning defect: the probe
reached the OTHER Hub and presented a token it never issued. The `GET /` control
returned 200 for the same reason -- **control and subject were talking to the
same wrong server.**

**FIXED, CM051 #1462.** A CONNECT test plus the daemon's own "Address already in
use" confession, returning CANNOT-RUN when the port answers while we see no
listener; and an unreadable enumeration is now disqualifying on its own.
Control grew 4 -> 6 reading sets, and set 6 is the important one: a genuinely
dead port must STILL be FAIL, so the occupancy check cannot disable the defect
the probe exists for.

### v1066-D005 -- FOUR post-walk FAILs that no outage explains, and I nearly filed all eleven as environmental

The v1.0.66 ARTEFACT walk was GREEN (39 steps, `DONE status=ok failed_steps=0`).
The 24-probe post-walk gate then returned **10 PASS / 11 FAIL / 3 CANNOT-RUN**.

🔴 **THE PROCESS FAILURE FIRST, because it is the reusable part.** Another
account's Hub held :8000, which genuinely explains the 401 and
`daemon_is_listening`. I found one mechanism that explained the two loudest
symptoms and **extended it over nine probes whose verdict text I had not read**,
publishing "essentially all of them are one environmental fact" twice. Reading
each FAIL's own text refuted it:

```
PORT COLLISION, the explanation holds ......................  3 of 11
REAL PRODUCT FINDINGS, no outage explains them .............  4 of 11
DATA / STORE, needing attribution rather than assumption ...  4 of 11
```

**A single cause that explains the two loudest symptoms is the most seductive
wrong answer available.** Compounding it, the LIST was also wrong: built with
`grep -aB 30 '^  VERDICT: FAIL'`, and a 30-line window SPANS PROBE BOUNDARIES,
so four probes were mis-attributed. `launchagents_resolve_their_tools`,
`launchd_no_ephemeral_paths` and `pairing_recovers_without_a_repair_storm` all
PASSED; `pair_state_agreement` was CANNOT-RUN. The COUNTS were right, which is
why it survived two retellings. **A correct total over a wrong composition
looks exactly like a measurement.**

TNM spent a work cycle chasing a `launchagents_resolve_their_tools` FAIL that
never happened, on that list. (It led him somewhere real anyway -- see
v1066-D006 -- but by luck, not by the route.)

**THE FOUR, each with its own text and NO shared cause:**

1. `install_manifest_complete` -- **2 required subjects MISSING**:
   `launch_agent com.ostler.enrich (baseline)` and
   `launch_agent com.ostler.ollama (baseline)`, plus 1 present-but-UNDECLARED.
2. `no_person_holds_two_contact_cards` -- **54 Person nodes each carry 2+
   distinct `icloud_contact_uid`, collapsing 117 Contacts cards.** RULE 2 of the
   ratified dedupe ruleset -- different canonical keys MUST NOT merge --
   violated in the LIVE graph (#659). Note v1064-ad already fixed RULE 2 on the
   converge path; this is the same rule red again on a v1.0.66 box.
3. `freshness_panel_has_dates` -- the panel has **NO ROW for calendar, contacts,
   email**, while the ingested keys ARE `[calendar,contacts,email,imessage]`.
   In the probe's own words, "the customer is shown a currency report that
   silently excludes a source they are relying on." Same family as the
   "the channel must still APPEAR" invariant at install.sh:26136.
4. `no_store_port_is_tcp_reachable` -- **6333 7878 6379 8044 3000 8144
   TCP-reachable on loopback**, "therefore readable by every account on this
   Mac". #550 was demonstrated against 7878 with ONE unauthenticated curl.
   **Look at this one first**: a security finding with a demonstrated exploit
   path, and the least likely of the four to be a fresh-box artefact.

**NOT CLAIMED**: that any of the four is v1.0.66-specific rather than
long-standing, or that the remaining four (`ingest_coverage`,
`people_count_agreement`, `people_stores_reconcile`, `usage_journal_producers`)
are environmental. Those need attribution and have not had it. **A cause I
cannot name is better recorded as unnamed than attached to the nearest
available story.**

⬆️ **UPDATE, same night: all FOUR are now attributed, and NONE of them is the
port collision I originally blamed them all on.**

```
no_store_port_is_tcp_reachable     MEASURED    the STORES enforce auth --
                                               Qdrant /collections 401 (bogus
                                               api-key also 401), Oxigraph 401.
                                               The 200s were health endpoints.
                                               The real exposure is the WIKI on
                                               8044: 49,002 bytes, 0 auth
                                               indicators, and
                                               /search/search_index.json 200.
                                               LOOPBACK ONLY (127.0.0.1), so
                                               not a network exposure -- any
                                               other LOCAL ACCOUNT can read the
                                               customer's wiki and its
                                               full-text index.
                                               Redis + 8144 = NOT MEASURED; an
                                               HTTP probe cannot read a RESP
                                               port, and that is not "safe".

no_person_holds_two_contact_cards  ATTRIBUTED  a v1.0.66 DEFECT. Both graph
                                               volumes were created 20:39:14Z,
                                               5m44s AFTER the walk began at
                                               20:33:30Z, so the graph was
                                               built end to end by v1.0.66's
                                               own ingest. RULE 2 is red on
                                               code that CARRIES v1064-ad's
                                               fix. Whether the guard misses
                                               hydrate's path or covers it and
                                               does not hold is NOT
                                               established.

freshness_panel_has_dates          DIAGNOSED   CM044, by TNM, from the consumer
                                               side. `compiler/pages/
                                               dashboard.py:2234-2239` is THREE
                                               HARDCODED ROWS and nothing reads
                                               the ingested set, so calendar,
                                               email and imessage can never
                                               appear by construction. Rows
                                               also carry a LOCALISED DISPLAY
                                               STRING and no key, so they
                                               cannot be attributed and change
                                               under a non-en-GB locale.
                                               Producer side (mine): install.sh
                                               reports only 2 channels --
                                               contacts (2 sites), emails (4);
                                               calendar/messages/notes/whatsapp
                                               have ZERO producers. Different
                                               pin, different cut: NOT v1.0.67.

install_manifest_complete          ATTRIBUTED  see v1066-D007 below.
```

### v1066-D006 -- the upgrade path silently reverts the 2026-08-20 Homebrew-PATH fix

`_upg_preserve_plist_env` (install.sh:530..550) walks every key in the OLD plist
and, where the key also exists in the new one, `Set`s the old value. **`Set`
replaces, and there is no PATH exclusion.** Called on the assistant at :657 and
the keepalive at :675.

Found by TNM, reproduced INDEPENDENTLY, using the real function extracted from
main and two plists differing only in PATH:

```
Set :EnvironmentVariables lines in the function : 1
PATH exclusions                                 : 0

BEFORE new.plist PATH   /usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin
AFTER  new.plist PATH   /usr/bin:/bin:/usr/sbin:/sbin          OVERWRITTEN
function rc             0
CONTROL OSTLER_HOME     preserved correctly
```

**The control is the point: the function is right for every other key.** This is
a MISSING EXCLUSION, not a broken function -- PATH is the one key whose old
value must lose. That makes the fix narrow.

**WHY IT IS SERIOUS.** `/usr/bin:/bin:/usr/sbin:/sbin` is exactly the PATH the
assistant plist's own comment records as producing, measured after a real power
cycle: *"colima FATA exec limactl: executable file not found in $PATH ...
Qdrant, Oxigraph, Redis, Vane, wiki-site and store-proxy were all gone until
someone started Colima by hand."* An upgrading pre-2026-08-20 customer gets the
fix reverted and **their container stack does not survive a reboot** -- and it
only reaches customers who ALREADY HAVE containers running.

**THE GATE IS GREEN BECAUSE IT TESTS THE TEMPLATE.**
`tests/test_launchagent_homebrew_path.sh` has **0** references to
upgrade / preserve / `_upg_`. It asserts the templates carry the PATH; nothing
asserts the value SURVIVES an upgrade. The fix shipped, the gate stayed green,
and it never reached an upgrading customer -- the "a merged PR is not a shipped
feature" class, with a gate that looks like it covers it.

⚠️ **THE FIRST EXTRACTION READ AS "TEMPLATE SURVIVED".** The function is
INDENTED at 530 and a column-0 awk anchor extracted **0 lines**, so it never
ran and the PATH was unchanged because nothing touched it. `rc=127` was the
only tell. **An unchanged value after a function that never ran is
indistinguishable from a function that ran and preserved it.**

Scoped to v1.0.67, where on severity it outranks both items already there.
The test must assert SURVIVAL and carry a MUST-PRESERVE control (a non-PATH
key), so a fix that simply stops preserving anything cannot pass.


### v1066-D007 -- an already-installed Ollama makes install.sh skip the LaunchAgent it is required to write

`install_manifest_complete` failed with **2 required subjects MISSING**:
`launch_agent com.ostler.enrich (baseline)` and `launch_agent com.ostler.ollama
(baseline)`. Both confirmed absent on the box by EXACT label match, after a
substring probe first reported `com.ostler.ollama` as loaded -- it was matching
`com.ostler.ollama-logrotate`.

**THE MECHANISM, for the ollama half.**

🔴 **THE FIRST VERSION OF THIS ROW NAMED THE WRONG CAUSE AND IT SHIPPED INTO
THE REGISTER.** I wrote that "the CASK branch skips the else at 11951 that
writes the plist". The cask branch is ONE LINE and closes before the plist is
ever mentioned:

```
11922  if [[ -x "$OLLAMA_APP_BIN" ]]; then
11923      ok "$MSG_OK_OLLAMA_INSTALLED"      <- the ENTIRE cask branch
11947  fi                                     <- and it CLOSES here
```

The `else` at 11951 belongs to a **different `if`**, and this is the real one:

```
11949  if curl -s http://localhost:11434/api/tags &>/dev/null; then
11950      ok "$MSG_OK_OLLAMA_RUNNING"        <- already serving: DO NOTHING
11951  else
11965      OLLAMA_PLIST=".../com.ostler.ollama.plist"   <- the ONLY creation site
```

⇒ **the LaunchAgent is written only when NOTHING answers on 11434, and that
probe is a bare loopback curl with no ownership check.**

I got the first answer by walking backwards for the nearest enclosing
`if`/`else` WITHOUT a depth counter, so it handed me the closest block rather
than the owning one, and I published it. The correct instrument is an
equal-indent backwards walk with a `fi` depth counter.

On the walked box:

```
/Applications/Ollama.app/Contents/Resources/ollama   EXECUTABLE  -> CASK branch
com.ostler.ollama.plist                              ABSENT
#OSTLER STEP_END id=ollama_install status=ok elapsed_s=0
```

⇒ **ANOTHER ACCOUNT ON THE SAME MAC WAS SERVING 11434.** install.sh asked "is
Ollama already running?", the other account's Ollama said yes, and the branch
that creates our LaunchAgent never ran. The step closed ok in ZERO SECONDS.

**The customer-facing shape is worse than a missing file.** That install ends
with NO LaunchAgent, so nothing starts Ollama at boot for it; it depends on a
process owned by a different user, which disappears when that user logs out;
and the step reports ok while saying none of it.

**This is the PORT CLASS, for the fourth time in one night** -- :8000, :11434,
:8044, and two `lsof` enumerations that read another user's socket as absence.
It is the worst of them because it changes what gets INSTALLED, not merely what
gets reported.

FIXED, CM051 #1471: the plist path is hoisted above the branch and the guard
becomes `curl ... && [[ -f "$OLLAMA_PLIST" ]]`, separating "is something
serving" (whether to START) from "do we own an agent" (whether the install is
COMPLETE). Blast radius is the defect case only: serving+plist still SKIPs,
not-serving still CREATEs either way.

11 of 39 steps closed at `elapsed_s=0` on that walk. Most are legitimately
fast. This one provably skipped required work while reporting ok.

⚠️ **`com.ostler.enrich` is UNFINISHED, not assumed to match.** `cm019_setup`
closed `ok elapsed_s=1` and its plist is likewise absent -- the same signature,
but the guard has not been read. Recorded as an open question, not a second
instance.

🔴 **AND A CORRECTION ON MY OWN EVIDENCE.** I cited "ollama serving: 200" as
support that the step had done its job. `lsof -nP -iTCP:11434` as the walk user
returns NOTHING -- another account owns that socket, exactly as with :8000.
**That 200 was almost certainly the other account's ollama answering.** Third
instance in one night of the same class: on a shared Mac, REACHABLE never means
OURS, and a successful CONNECT makes the instrument look healthy while only the
OWNER is wrong.
### v1066-D008 -- three health probes go GREEN on another account's service, and one of them already did

**D007's mirror image.** That one SKIPS an install step; these HIDE A FAILED
INSTALL, inside the step whose entire job is to notice.

```
install.sh:28407  curl -sf localhost:6333/healthz    -> ok  else HEALTHY=false
install.sh:28414  curl -sf localhost:7878/           -> ok  else HEALTHY=false
install.sh:28465  curl -sf localhost:11434/api/tags  -> ok  else HEALTHY=false
```

All three are bare loopback probes with no ownership instrument. Found by TNM's
sweep: **11 loopback probes in install.sh, 0 with an ownership instrument**
(`lsof`/`pgrep`/`docker inspect`/`docker compose ps`/`launchctl print`) within
+/-10 lines, with a must-miss control (a comment naming localhost) scoring 0 and
a must-match control on two lines that DO carry one returning 1 and 2.

🔴 **28465 ALREADY FIRED, IN A WALK THAT WAS PUBLISHED AS PASS.** v1.0.66
artefact walk, terminal step:

```
#OSTLER STEP_END id=health_check status=ok elapsed_s=23
#OSTLER LOG msg=Ollama healthy

walked account:  com.ostler.ollama.plist ABSENT · launchctl exact-label count 0
                 :11434 answers 200  <- another account's ollama
```

The health check reported a component healthy for an install that does not have
it. **The COMPLETION verdict is unaffected and stands** -- 39 steps, `DONE
status=ok failed_steps=0`, rc=0 -- but that arm was a CANNOT-RUN wearing a PASS,
and the walk record now carries the qualification rather than the bare green.

**28407 and 28414 are HONEST BY LUCK OF THE BIND, not unverified.** Measured:
6333 and 7878 were the walked account's OWN containers on that box, so the
mechanism is live and we know exactly why those two did not fire. On a box where
the other account's containers win the bind, all three go green on a dead
install.

**FIXED for 28465 only, CM051 #1471**, together with D007's create-side arm.

⚠️ **DO NOT FIX ANY OF THESE WITH `lsof`.** `_port_is_our_own_forward` already
records that "an unprivileged lsof returns no pid for a foreign-owned holder --
so on a genuine cross-account collision this branch is never reached" (#549,
open). An lsof-shaped ownership check returns EMPTY on precisely the collision it
would be written for.

⚠️ **AND DO NOT GATE ON `launchctl print`'s EXIT CODE.** The first version of the
fix did, and TNM caught it. Measured on two Macs, three labels:

```
absent label            rc=113   (no state line)
loaded but NOT running  rc=0     state = not running
loaded AND running      rc=0     state = running
```

rc=0 covers BOTH, so a parked agent would report healthy -- the same defect
wearing a different instrument, and the third appearance of the `launchctl load
exits 0 on failure` family in this file, which install.sh's own note already
documents: *"Registration is not runnability."* Parse `state = running`. It is a
fair demand for this agent because its plist sets `KeepAlive <true/>`, the exact
condition `_ostler_launchagent_keeps_alive()` exists to test; it would NOT be
fair of a one-shot.

🔒 **WHAT THE FIX CLOSES, AND WHAT IT DOES NOT.** It closes GREEN ON A DEAD
INSTALL: our agent must be up. It does NOT close GREEN ON SOMEONE ELSE'S LIVE
ONE -- `state = running` does not prove the reply on :11434 came from OUR pid,
and attributing a listener needs #549. The narrower claim is the true one and it
is stated in the source.

**28407 and 28414 remain OPEN.** They want the `install.sh:30097` pattern --
read the Doctor's `/api/v1/sources` artefact rather than infer from reachability
-- which TNM identifies as the shape the other ten probes want. Not changed
under time pressure before a cut.

### v1066-D009 -- the writer's vocabulary and the reader's are both declared, and nothing links them

**OPEN. Not a defect today; a structural gap that has already produced two
defects and will produce a third.**

The same writer/reader drift was found TWICE in one night, in two fields:

```
sources    CM051 install.sh writes 13    CM044 hydration.py recognised  9
statuses   CM051 install.sh writes  5    CM044 hydration.py recognised  3
```

`cannot_run` and `timeout` fell through to "Could not tell" on the customer's
freshness panel, for two statuses CM051 emits on purpose. `timeout` is the
expensive one: rc 124/137 means a source was killed by its cap and moved no
data, so it needs a re-run.

**BOTH SIDES ARE NOW SELF-CHECKING, AND THAT IS NOT THE SAME AS LINKED.**

```
CM051 #1472   OSTLER_SENTINEL_STATUSES (5) and OSTLER_SENTINEL_SOURCES (13)
              declared in install.sh, with a gate that EXECUTES all four
              recorders (rc 1/124/137) and asserts what they actually wrote,
              plus both directions on the sources: written-but-undeclared and
              declared-but-never-written.
CM044 #267    the reader's set pinned in a test, the row set derived from the
              ingested sources rather than three hardcoded appends, and every
              row given a machine-readable key.
```

⇒ **each copy is guarded against its own writer. Neither is guarded against the
other.** The only thing that caught the drift on 2026-09-04 was a human diffing
two repos member for member, as SETS not counts -- and equal counts would have
proved nothing, which is the "agreement on an outcome is not agreement on a
cause" trap.

**WHAT IS DELIBERATELY NOT PRESCRIBED HERE.** A link needs a PIN and a
DIRECTION: does CM044 vendor CM051's declaration, or transcribe it against a
pinned sha, and which repo is authoritative when they disagree? Different pins
and different cuts, and the panel work already established that a cross-repo
RUNTIME check is the wrong shape. Those are cut decisions and are not being
invented under time pressure.

**THE FAILURE MODE TO WATCH FOR**, because it is the one a fix could reintroduce:
a link that compares COUNTS rather than MEMBERS would have passed on the night
this was found, twice. 13 vs 13 and 5 vs 5 were only meaningful because someone
compared the names.

⚠️ AND THE VENDORING ORDER MATTERS, measured the same night: D007 was vendored
into CM051 (#1470) and THEN corrected upstream (#201), which left the vendored
copy asserting a cause the register had already refuted. Only
`scripts/sync_rollforward_registry.sh`'s AHEAD guard noticed. **Correct upstream
BEFORE vendoring, not after.**
