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
| A2 | Manifest row rewritten: correct `source_path`, new pin, drop the stale `unverifiable_ack` | TODO | `measure_vendor_overlap.py` shows cm024 overlap > 0 |
| A3 | Restore `apple_notes` to `OSTLER_FDA_SOURCES` (install.sh ~11613) | TODO | grep the SHIPPED install.sh in the DMG |
| A4 | Delete the "deliberately ABSENT" comment — it was an agent's scope call, never Andy's | TODO | absent from shipped install.sh |
| A5 | `progress "Reading your Apple Notes"` (install.sh:25560) fires only when work happens | TODO | box walk: line absent when no notes, present when notes ingest |
| A6 | **Apple Notes actually land on a box** | TODO | count > 0 in the knowledge store after a real install |

## B. ANDY'S FOUR MISSING SURFACES (2026-09-02)

TNM's ingest table had 15 rows. Andy named four omissions. Table is **19 rows**.

| # | Item | State | Proof required |
|---|---|---|---|
| B1 | RemoteConversations (CM042) — app + LaunchAgent + `spoken_source` reader all present | **VERIFIED AT SOURCE, NOT ON A BOX** | transcript recorded → appears in graph |
| B2 | Voice feed silently skips if `~/Documents/Ostler/Transcripts` is ever deleted (sentinel-guarded creation, presence-gated reader) | TODO | delete dir, re-run install, assert a REFUSAL not a silent skip |
| B3 | **Safari extension must ingest WITHOUT an iPhone pair** — Andy 2026-09-02: *"it's a fucking BUG… needs fixing PROPERLY"* | TODO — **mechanism measured, see below** | Hub-only install, no phone EVER paired, browse → page in `safari_history` |
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

| # | Item | State | Proof required |
|---|---|---|---|
| C1 | Topics extracted then dropped (#858) | TODO — **verify at source first** | a topic readable on a surface |
| C2 | Preferences read under wrong field name (#855) | TODO — verify first | assistant answers a preference question |
| C3 | Calendar lands raw rows not meetings (#859) | TODO — verify first | a meeting entity in the graph |
| C4 | Calendar-people have no identifiers, cannot merge (#680) | TODO — verify first | a calendar person merges |
| C5 | People graph stops growing (#851) — fix merged, never watched working | TODO | count rises across two ticks on a box |
| C6 | Email drains ~30 days (#789) | TODO | measured window on a box |
| C7 | 128 over-merged people (#659) | TODO | count after dedupe |
| C8 | **"Keeps updating" for all 19 rows** — Andy wants green in every cell | TODO | **a T+1h probe per surface.** A surface that lands once and stops is indistinguishable from a working one at T+0 |

## D. THE SELF-RENEWING DEFERRAL CLASS (swept 2026-09-02)

Measured: **15 of 24 vendored trees** are held in a deferred/unverifiable state.
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

| # | Item | State | Proof required |
|---|---|---|---|
| G1 | Define the per-surface record: `landed_at`, `last_update_at`, `item_count`, `status`, `reason_if_not` | TODO | schema checked in |
| G2 | Every one of the 19 surfaces WRITES its record (a surface that cannot write one is not shipped) | TODO | 19 of 19 records present on a box |
| G3 | `/api/v1/sources` serves it | TODO | 200 with 19 rows |
| G4 | Doctor panel renders per-surface landed + last-updated, and says WHY when a surface is dark | TODO | screenshot on a box |
| G5 | The install-time probe (E1) and the box walk read this artefact, not their own logic | TODO | one artefact, three readers, no second source of truth |
| G6 | **`status` must have a CANNOT-CHECK state**, distinct from OK and FAILED | TODO | a surface whose store is unreachable reads CANNOT-CHECK, never OK |

⚠️ **G6 is not a nicety.** Every false-green in this product's history came from
a two-state predicate reading "could not look" as "nothing wrong". The Doctor
already does this: it computed a CRITICAL memory card, swallowed it in a bare
`except`, and rendered "Everything looks healthy" at 91% RAM (#419).

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
