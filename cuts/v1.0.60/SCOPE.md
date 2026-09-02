# v1.0.60 SCOPE MANIFEST

Opened 2026-09-02T13:35:40Z by Archie, on Andy's instruction:
*"You had better be making a manifest of all these things going in the next cut,
because I will be SUPER PISSED off if ANYTHING falls through."*

## THE RULE THIS FILE EXISTS TO ENFORCE

Every row below is either **DONE with a stated proof** or **NOT DONE**. There is
no third state. A row may not be carried to v1.0.61 by an agent writing
"deferred, next cut" — that is the exact mechanism that hid Apple Notes for six
weeks (see ROW A1). **Descoping is Andy's call, in writing, recorded here.**

Every row names:
- **PROOF** — the measurement that closes it. Not "merged". Not "the code exists".
  A command, an artefact, or a box observation.
- **STATE** — TODO / IN PROGRESS / DONE (+proof) / DESCOPED BY ANDY (+date).

---

## A. THE APPLE NOTES CHAIN (the row that started today)

| # | Item | State | Proof required |
|---|---|---|---|
| A1 | Re-vendor `cm024_knowledge` across the `src/` → `ostler_knowledge/` rename, to `1fabd75` | **DONE (on disk, uncommitted)** | 27 files parse; 8 invariants asserted; apple_notes.py + evernote_guid present; 0 rename artefacts. Re-run `revendor_cm024.py`. |
| A2 | Manifest row rewritten: correct `source_path`, new pin, drop the stale `unverifiable_ack` | **DONE at source** (Archie, 2026-09-02) | Read from the PARSED manifest, not grepped: `source_path = '.'`, `pinned_sha = 1fabd75d8aef239eaf0c59ad7c2270a0b24e150f`, and NO `unverifiable_ack` key present. The row's own `note` records that the rename is resolved and the ack retired. Shipped-artefact proof still owed on the walk. |
| A3 | Restore `apple_notes` to `OSTLER_FDA_SOURCES` (install.sh ~11613) | **DONE at source** (Archie, 2026-09-02) | `install.sh:11639` lists `apple_notes`. Not merely grepped: `tests/test_hydrate_apple_notes_wired.sh` now FAILS if it is absent while the CM024 converter is vendored, and that arm was mutation-proved RED. Original proof (grep the SHIPPED install.sh in the DMG) still owed on the walk. |
| A4 | Delete the "deliberately ABSENT" comment — it was an agent's scope call, never Andy's | **DONE at source** (Archie, 2026-09-02) | `install.sh:11622` now reads "It used to read ...", i.e. the directive is gone and only a historical note remains. Deliberately NOT deleted outright: the note records that an agent, not Andy, made that scope call. Absence from the SHIPPED install.sh still owed on the walk. |
| A5 | `progress "Reading your Apple Notes"` (install.sh:25560) fires only when work happens | TODO | box walk: line absent when no notes, present when notes ingest |
| A6 | **Apple Notes actually land on a box** | TODO | count > 0 in the knowledge store after a real install |

## B. ANDY'S FOUR MISSING SURFACES (2026-09-02)

TNM's ingest table had 15 rows. Andy named four omissions. Table is **19 rows**.

| # | Item | State | Proof required |
|---|---|---|---|
| B1 | RemoteConversations (CM042) — app + LaunchAgent + `spoken_source` reader all present | **VERIFIED AT SOURCE, NOT ON A BOX** | transcript recorded → appears in graph |
| B2 | Voice feed silently skips if `~/Documents/Ostler/Transcripts` is ever deleted (sentinel-guarded creation, presence-gated reader) | TODO | delete dir, re-run install, assert a REFUSAL not a silent skip |
| B3 | **Safari extension must ingest WITHOUT an iPhone pair** — Andy 2026-09-02: *"it's a fucking BUG… needs fixing PROPERLY"* | **SPLIT INTO THREE LIMBS — 3 of 3 BUILT, 2 of 3 IN THE SHIPPING TREE.** See B3a/B3b/B3c | Hub-only install, no phone EVER paired, browse → page in `safari_history` |
| B3a | the auth predicate: Doctor accepts an extension credential on `/api/safari/ingest` POST loopback only | **DONE** | HR015 PR #734 (`c383b5f`) at source; CM051 `a0a79465` in the vendored tree. RED 30 / GREEN 30 measured **on the vendored file itself**, sha256-matched. Gate: `OK doctor -- vendor == source@b0b38310 (+patch)` |
| B3b | install.sh MINTS `OSTLER_EXTENSION_TOKEN` and puts it in the Doctor plist | **DONE** | CM051 `c7bab9a8`: mints to `${SECRETS_DIR}/extension_token` (umask 0077, chmod 600), reuses an existing one, and passes it to the Doctor LaunchAgent. Landed with a defect of its own: it referenced two catalogue strings that did not exist, which under `set -uo pipefail` is a DEAD INSTALL at that step. Fixed in `d1dd60dd`, which also builds the gate that had been missing for all 940 MSG_ references |
| B3c | the EXTENSION learns the token | **DONE AT SOURCE, NOT YET VENDORED** | HR015 #734 MERGED `bb3b90a9`: `extension_token.py`, `/extension-setup`, `/api/v1/extension/token`, 12 tests, mutation-proved. **The environment is the authority, not the file**, because `proxy.py` authenticates against `os.environ` and Doctor is the same process; where the two disagree the panel shows NOTHING and names the restart. ⚠️ **The vendor carry into `vendor/doctor` is BLOCKED** on the doctor divergence patch: 3 of its 7 `/dev/null` new-file hunks name files that already exist in source at the pin (measured, both controls firing). @A2 is measuring whether the patch applies at all; I will not run the graft-deleting re-vendor on an unmeasured patch |

> ### 🔴 B3c — I ALMOST SHIPPED THIS AS "FIXED". IT WOULD HAVE BEEN A THIRD HALF.
>
> B3a makes the Doctor **willing** to accept an extension credential. It does not
> make the extension **send** one. Measured, not assumed:
>
> - `install.sh:27204` installs the extension from a **pre-built signed zip**,
>   `${SCRIPT_DIR}/extensions/OstlerSafariExtension.app.zip`, produced by CM020's
>   `bin/build-safari-extension.sh`. install.sh **never configures it** — there is
>   no token write, no endpoint write, no config write of any kind.
> - `extensions/` **does not exist in this checkout at all**, so the whole install
>   step at 27204-27240 is a no-op here. That is the same absence already filed as
>   **#268** ("extension bundle absent from shipped Ostler.app — reconciler no-op
>   guaranteed"), reaching a second surface.
>
> ⇒ **B3a alone changes NOTHING a customer can see.** Landing it and ticking B3
> would have been precisely the "fixed = half wired" pattern Andy named today.
> It is recorded here as one-third, and the row does not go green until a page
> from a real browser lands in `safari_history` on a box that never paired a phone.
>
> **B3c NOW HAS A DESIGN — measured in CM020, not guessed.** I read the extension
> source (`~/Developer/cleanse-safari-history-extension`, origin
> `andygmassey/safari-history-extension`) instead of inventing an App Group scheme:
>
> ```
> background.js:32   DEFAULT_ENDPOINT = 'http://localhost:8089/api/safari/ingest'   ← already the Doctor
> background.js:36   DEFAULT_API_KEY  = ''                                          ← empty by design
> background.js:44   getConfig() reads apiKey from browser.storage.sync
> background.js:77   if (!config.apiKey) → "Skipping send - extension not paired
>                    with Hub. Open the popup to pair."   ← refuses to send, silently
> background.js:102  'Authorization': `Bearer ${config.apiKey}`
> ```
>
> **The extension already sends a bearer and already points at the right endpoint.**
> Nothing in CM020 needs to change. The entire defect is that the only value a
> customer could ever put in that box was a **paired-phone bearer**, so a Hub-only
> customer had nothing to paste and the extension sat in its silent-skip branch
> forever. That is the bug, whole, end to end.
>
> ⇒ **B3c = show the customer the extension token so they can paste it into the
> popup.** Precedent already exists in this codebase: `whatsapp_pair.py` +
> `/whatsapp-pair` is exactly this shape (a per-install secret rendered on a Doctor
> page for a human to copy). No signed-bundle change, no CM020 release, no App
> Group. B3a already makes the Doctor accept that token.
>
> **The three limbs now compose into a working feature**, which is the test this
> row has to pass before it goes green: mint (B3b) → display (B3c) → accept (B3a,
> done) → page lands in `safari_history` on a box that never paired a phone.
| B4 | ~~iOS Safari extension must exist~~ **IT EXISTS AND IS WIRED** | **DONE at source** (A2, 2026-09-02) | `SafariCaptureRelay.swift:103` POSTs `/api/safari/ingest`, fed by a Safari Web Extension App-Group queue, drained on app foreground (`CM031App:300` scenePhase→active). **My row was mis-scoped** — I wrote "must exist" without measuring. Box proof still owed. |
| B5 | **Chrome extension is NOT SHIPPED.** install.sh opens `chrome.google.com/webstore/category/extensions` — the generic category page, not our listing | TODO | either a real listing URL, or the step does not run at all |

### B3 MECHANISM — measured 2026-09-02 in `vendor/doctor/agent/proxy.py`

It is **the wrong credential**, not a missing policy.

> "when a service token is configured it VALIDATES the incoming client bearer
> **against the ZeroClaw gateway's paired-token store** and only THEN
> substitutes the service token on the forwarded request."

The paired-token store is populated **by pairing a phone**. So the macOS
Safari extension — running on the customer's own Mac, capturing the
customer's own browsing, never leaving the machine — is authenticated
against a credential that exists only if they own an iPhone and paired it.

The proxy's design note explains why it validates rather than passes through,
and that reasoning is CORRECT and must not be undone: substituting the
service token without validating the client would let any loopback process
that reaches `:8089` inherit ical-server access. **The fix is a second
accepted credential, not a hole.**

**Fix shape (needs review before build):**

1. install.sh mints a per-install **extension token**, same class as
   `PWG_SERVICE_TOKEN`, stored 0600 under the user's own home.
2. The extension obtains it once, on an explicit customer action
   ("Connect to Ostler"), never silently.
3. The Doctor accepts **either** a valid paired-phone bearer **or** the
   extension token, **for `/api/safari/ingest` only** — not for the other
   29 proxied paths, which read personal data rather than write browsing.
4. iOS Safari extension rides the paired channel it already has.

⚠️ **The asymmetry is the point.** Ingest is a WRITE of the customer's own
browsing. The other proxied paths are READS of their whole life. Widening
the credential across all 30 paths would be a real security regression and
is not what this row asks for.
| B6 | iOS-generated transcripts reach the Hub (`/api/v1/conversation/process`) | **WIRED — measured by A2 at `origin/main` b2ec7c10** | `APIClient.swift:92` (`syncTranscript`), triggered by `HomeViewModel:351` (iPhone-direct) and `WatchAudioReceiver:689` (Watch audio) → TranscriptUploader → SyncManager. Box proof still owed. |
| B7 | Everything else CM031 generates (`/api/v1/ingest/ios`) | **WIRED — same measurement** | `PWGUploadService.swift:367` (`upload`), triggered by Quick Note save (`QuickNoteView:150`) and health sync (`HealthService:150`). Box proof still owed. |
| B8 | GET `/api/v1/recording/active` is **DARK** — `RecordingStateService` is never instantiated (2 refs on main, both its own class definition; the "In LiveActivityCoordinator.start()" line is an aspirational comment) | **NOT a v1.0.60 item** | Live Activities dependency, v1.0.1 scope. Recorded so it is not rediscovered as new. |

| B9 | **Quick Note has an UNMEASURED RUNTIME PRECONDITION** (TNM, second eyes). `QuickNoteView.swift:147` guards the POST on `let hubURL = URL(string: pwgAPIBaseURL)`, a `UserDefaults` string. Absent or empty ⇒ `URL(string:)` is nil ⇒ block skipped ⇒ **no POST, and nothing throws**, so the `catch` never fires and the customer sees a clean local save. | **WALK ITEM — not a source defect and not a build item** | on the box: read `pwgAPIBaseURL`, save a Quick Note, assert it reaches the Hub. If the key is empty on a Hub-only install, it becomes a v1.0.61 build item. |

⚠️ **B9 is the silent-no-op-on-falsy-config shape and it is why "WIRED" is not "WORKING".** TNM explicitly did NOT measure what that key holds and said so — nobody may read the flag as evidence it is empty. 24 `DemoMode.isEnabled` sites exist in production Swift, so the demo half of the guard is a deliberate estate-wide pattern, not an accident here. **Whether this is a defect is a BOX question, not a source question** — the same boundary that stops a row being ticked off a receiver's existence.

**A2's controls, recorded because a count without them is not evidence:**
positive control PASSED — `subscription/receipt` found at
`SubscriptionReceiptSync.swift:181` by the same method, so the DARK verdict is a
real absence and not a broken predicate. Denominator **306** Swift files at
b2ec7c10, reconciled against TNM's 304 as a sha difference (main advanced by 2
files), both correct at their own sha. Filter bound established: **0** `.m/.mm/.h`
files, so `*.swift` is the whole network-code population rather than a partial one.
Measured on `origin/main`, NOT the checkout HEAD, which sits on a branch diverging
1↔6 — TNM handed that trap over without a verdict so the measurement stayed
independent.

## C. TNM'S 15 ROWS — the broken ones

### ✅ VERIFIED BY A2, 2026-09-02. **ZERO CODE-BUILD ITEMS.** 4 REFUTED, 3 BOX LIMBS.

Measured at CM051 `origin/main` 8d2818e3, with **0 differing files across all 7
producer trees vs the cut branch 82825671** — so the verdicts hold for the tree
being cut, not merely for main. Every row had a passing positive control.

| # | Claim | VERDICT | Evidence |
|---|---|---|---|
| C1 | Topics extracted then dropped (#858) | **REFUTED** | written `topic_writer.py:397-406` (SPARQL insert `pwg:ConversationTopic`), readable `ical-server.py:3996` → `GET /api/v1/topics`. Namespace, graph and predicates match on both sides. "Dropped on the floor" is documented as the OLD state. |
| C2 | Preferences read under wrong field name (#855) | **REFUTED** | writer and reader BOTH key `interests` (`emit_artefact.py:107` ↔ `ical-server.py:6637`). |
| C3 | Calendar lands raw rows not meetings (#859) | **REFUTED** | `pwg:Meeting` created at `pwg_ingest.py:1153`. The in-code comment says this was the fixed regression. |
| C4 | Calendar-people have no identifiers so cannot merge (#680) | **REFUTED — premise TRUE, conclusion FALSE** | there really is no `pwg:hasIdentifier` (real absence, `pwg_ingest.py:1090-1132`) **but they merge anyway** by exact display name at 0.9 against an auto threshold of 0.8. |
| C5 | People graph stops growing (#851) | fix **PRESENT** / grows-on-box **CANNOT-RUN** | fix at `install.sh ~2848` + probe `63867dad`. Historical sample was FLAT 246725↔246725 on .228 and **no walk since records growth** — "never watched working" is corroborated, not dismissed. |
| C6 | Email drains ~30 days (#789) | **REFUTED (mixed)** | backfill default is **1825d = 5 years** (`email-ingest-tick.sh:53`). The "30" is the per-tick CHUNK STRIDE, not a cap. A second `email_source` path is 30d-rolling, so the blanket claim is false but not baseless. |
| C7 | 128 over-merged people (#659) | mechanism **REFUTED** / count **CANNOT-RUN** | merge is conservative: auto 0.8, **surname agreement required**, fuzzy danger-zone gated, hard-conflict veto. The named over-merge is a documented FIX. The 128 is an unmeasured store count. |

**⇒ SECTION C CONTRIBUTES NO BUILD WORK TO v1.0.60.** C1-C4 all describe
PRE-FIX state already closed in the vendored trees. **Verify-before-fix
prevented four no-op "fixes" on healthy code** — the exact waste the dispatch
was written to avoid, and the reason the rule is measure-then-fix.

**C5, C6, C7 carry a genuine open BOX limb and are WALK items, not build items.**
The code is present and sound; whether it works at runtime was never measured.
Each has a named measurement that folds into the same clean-box walk already
gating this cut — no new instrument needed, they need the box:

- **C5** two-tick `ingest_coverage` + `fda-rerun` exit 0 → `walks/v1.0.60.tsv`
- **C6** which path is actually wired, and the real drained window
- **C7** `batch_resolver --dry-run` `auto_merge_count` against the live store

⚠️ **CROSS-ROW, C4 + C7, and it is the one to watch.** Exact-display-name
auto-merge at 0.9 with no identifier required is ONE mechanism that both makes
identifier-less calendar people mergeable (C4, good) and is the plausible
over-merge vector if two DISTINCT people share a name and carry no conflicting
identifier (C7, dangerous). The C7 dry-run is where that gets settled. There is
already a live instance of this class on the founder instance — a family member
fragmented across records and sometimes conflated with a different relative
(task #298, names deliberately not repeated here: this repo is PUBLIC).

**No row was left TBD or deferred.** 4 refuted, 3 CANNOT-RUN with the exact
measurement named. CANNOT-RUN is a first-class answer and never a pass.
| C8 | **"Keeps updating" for all 19 rows** — Andy wants green in every cell | TODO | **a T+1h probe per surface.** A surface that lands once and stops is indistinguishable from a working one at T+0 |

## D. THE SELF-RENEWING DEFERRAL CLASS (swept 2026-09-02)

Measured: **13 of 24 vendored trees** (CORRECTED 2026-09-02: my "15" was wrong. @A2 re-measured with `tomllib` rather than line-grep and got 13 carrying any relaxation: 7 with verification genuinely off, 6 hold_ack where full verify still runs. The likeliest source of my error is that `spoken_source` and its siblings carry `verify = "full"` AND `verify_exempt = true` on the SAME row, so a reader consulting `verify` alone sees "full". A2's parse is authoritative.) Also measured, and worse than the count: **ZERO of the 24 deferrals carries an expiry**, and the 4 exempt source trees name no owner at all while each shipping a launchd job to the customer. A deferral with no end date is indistinguishable from a decision are held in a deferred/unverifiable state.
**None has an expiry. None has a human owner** — every owner is a role.
The cut-deferral register is *fine* (707 of 709 rows expire); the vendor
manifest is the one that rots.

| # | Item | State | Proof required |
|---|---|---|---|
| D1 | `unverifiable_ack` / `hold_ack` require a MANDATORY expiry + a HUMAN owner | TODO | gate proved RED on a row with neither |
| D2 | A cut REFUSES when any ack is past its date | TODO | demonstrated refusal |
| D3 | Open each of the other 14 rows: does it withhold something the customer is told they have? | TODO | 14 verdicts, one per row |

## E. ANDY'S #599 — probes at the end of a customer install

Confirmed by measurement 2026-09-02: install.sh mentions "box-walk" 20 times,
**every one a comment**. Zero invocations. The 22-probe harness is operator-run.
This was logged as Andy's idea today and was **not built**.

| # | Item | State | Proof required |
|---|---|---|---|
| E1 | Wire the T+0 probe subset into the end of install.sh | TODO | probe output in the install log on a real install |
| E2 | Result lands where the Doctor can read it | TODO | Doctor surfaces it |
| E3 | Add probes for the 19 ingest surfaces (T+0 **and** T+1h) | TODO | 19 × 2 probes exist and run |
| E4 | Probes cluster where measuring is easy and are absent where it is hard (#533) | TODO | coverage stated with a denominator |

## G. ONE TABLE, THREE CONSUMERS — the Doctor panel (Andy, 2026-09-02)

Andy: *"These data surfaces should be tracked and monitored as working in the
user's Doctor panel, shouldn't they?"* Yes, and it collapses three half-built
things into one.

**The 19-row ingest table becomes a machine-readable artefact.** Three
consumers read the SAME artefact, so they cannot disagree:

1. the **Doctor panel** the customer looks at,
2. the **end-of-install probe** (Andy's #599, section E),
3. the **box walk**.

Today the Doctor is already trying to be this panel and structurally cannot,
because nothing publishes per-surface state. All four symptoms are already
filed and are the SAME missing piece:

| existing task | symptom | what it really is |
|---|---|---|
| #269 | `/api/v1/sources` returns 404 | no JSON endpoint was ever built |
| #213 | "CONNECTED SOURCES: 2" under-counts by 6 | the count is inferred from `.done` markers, not published |
| #514 | no per-source date surface anywhere; 8 of 12 components 32h stale | there is no per-source freshness record to render |
| #349 | freshness panel prints "unknown", not a date | consequence of the above |

### ✅ G6 ALREADY EXISTS — CORRECTED BY TNM, 2026-09-02, AND I WAS WRONG

I wrote in the dispatch: *"G6 IS NOT A NICETY AND I WILL BLOCK THE PR WITHOUT
IT."* **It is already in the shipping installer**, and it is already a genuinely
distinct fourth state rather than a two-state predicate:

```
_hydrate_sentinel_record            install.sh:23323   status=ok         21 literals
_hydrate_sentinel_record_error      install.sh:23387   status=error       7
_hydrate_sentinel_record_no_data    install.sh:23452   status=no_data     8
_hydrate_sentinel_record_cannot_run install.sh:23514   status=cannot_run  1   <- G6
```

Fields already written: `recorded_at` · `source` · `status` · `detail` ·
`payload`. **Four of my five G1 fields exist under other names** (`detail` is my
`reason_if_not`). Had TNM followed my instruction they would have built a second
record mechanism beside a working one — the duplicate-machinery scar. They
refused and said so rather than quietly complying. Correct call.

**SECOND CORRECTION, MINE:** I reported install.sh mentions "box-walk" **20**
times. Measured at origin/main 8d2818e3 it is **29**, with 0 non-comment. My
count was low by nine; the conclusion — zero invocations, E stands — is unchanged.

### 🔴 THE REAL G1 GAP IS THREE FIELDS, NOT A NEW MECHANISM

| # | Item | State | Proof required |
|---|---|---|---|
| G1a | `last_update_at`, DISTINCT from `recorded_at` | TODO | **one timestamp cannot answer both "Lands at install?" and "Keeps updating?"** — this single field is what makes Andy's second column possible, and it is why E3 is the hard half |
| G1b | typed `item_count` (today `payload` is a free string, `sent=0`) | TODO | a panel can render a count without parsing prose |
| G1c | **Nothing publishes the record** — no `/api/v1/sources`, so panel, probe and walk each infer state independently | TODO | the three-implementations-that-can-disagree problem, measured: 0 occurrences in ical-server, control `/api/v1/timeline` = 5 so the zero is real |
| G2 | Map all 19 surfaces to recorder call sites | TODO | **stated as UNMAPPED rather than assumed.** Recorder call sites: ok 14 · error 13 · no_data 9 · **cannot_run 5** |
| G3 | `/api/v1/sources` serves the record | TODO | 200 with 19 rows |
| G4 | Panel renders landed + last-updated, and says WHY when dark | TODO | on a box |
| G5 | Probe (E1) and walk READ this artefact rather than re-implementing | TODO | one artefact, three readers |

⚠️ **cannot_run at 5 call sites against 14 for the ok-recorder is the number most
likely to be a real gap.** A surface that can say OK but cannot say "could not
look" is precisely the false-green shape — the Doctor computing a CRITICAL memory
card, swallowing it in a bare `except`, and rendering "Everything looks healthy"
at 91% RAM (#419). TNM will not publish a 19-row table until every row is a
measured surface rather than an assumed one.

## F. CUT MECHANICS

| # | Item | State | Proof required |
|---|---|---|---|
| F1 | Green dry run BEFORE the tag | TODO | run id, preflight + dry-run both 0 failures |
| F2 | Ledger row filed SAME TURN as the tag | TODO | row on main, re-fetched and parsed |
| F3 | OS003 rollforward row filed | TODO | row on main |
| F4 | **Box walk on .98** | TODO | walk record, `box_walked: true` |

---

## CARRIED-FORWARD REGISTER

Nothing may be added here without Andy's written agreement. Empty is correct.

*(empty)*
