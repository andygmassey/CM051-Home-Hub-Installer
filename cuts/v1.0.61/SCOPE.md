# v1.0.61 SCOPE MANIFEST

Opened 2026-09-03 by TNM, on Archie's dispatch ("BUILD THE v1.0.61 CUT SET"),
under Andy's standing instruction recorded in the v1.0.60 manifest:
*"You had better be making a manifest of all these things going in the next cut,
because I will be SUPER PISSED off if ANYTHING falls through."*

## THE RULE THIS FILE EXISTS TO ENFORCE

Every row below is either **DONE with a stated proof** or **NOT DONE**. There is
no third state. A row may not be carried to v1.0.62 by an agent writing
"deferred, next cut" — that is the exact mechanism that hid Apple Notes for six
weeks. **Descoping is Andy's call, in writing, recorded here.**

Every row names a **Proof** — the measurement that closes it. Not "merged". Not
"the code exists". A command, an artefact, or a box observation.

---

## 🔴 WHY SECTION B EXISTS, AND IT IS THE MOST IMPORTANT THING IN THIS FILE

**v1.0.60 was walked, it FAILED, and Andy called it: v1.0.60 does not ship.**
Its SCOPE manifest carries **15 open rows**, and its own carried-forward register
reads *"(empty)"*.

Measured, not assumed — table rows classified by their State column, not by a word
count of the prose:

```
cuts/v1.0.60/SCOPE.md   open rows (TODO / IN PROGRESS / NOT DONE)  15
                        CONTROL: rows in a DONE state             14
                        carried-forward register                  (empty)
```

Those 15 rows describe work scoped for a version that is not shipping. **Had this
file been written as "the nine merges", all 15 would have fallen through** — the
precise failure the rule above exists to prevent, on the very next cut after it
was written down.

⛔ **I have descoped NONE of them.** Section B reproduces all eleven product rows
verbatim, with their original IDs and their original Proof text. Whether any of
them is descoped is Andy's call in writing, and this file is where that would be
recorded. The four v1.0.60 `F`-rows are per-cut mechanics and are re-scoped to
this cut as Section C rather than carried, because "green dry run before the tag"
is a statement about a specific tag.

---

## A. WHAT v1.0.61 CARRIES — the nine merges since v1.0.60

All nine are CM051 `install.sh` or its tests. Every one was mutation-verified
against the real pre-fix tree before merging. **Merged to main is NOT shipped**;
the Proof column says what would actually close each row.

| # | Item | State | Proof required |
|---|---|---|---|
| A1 | #1369 `16b3d219` — the closing verdict consults `__OSTLER_FAILED_STEPS`, so an install cannot claim a clean finish over a failed step | **DONE at source** | 🔴 THE HEADLINE FIX. This is v1060-D001 caught on the v1.0.60 artefact (`DONE status=ok failed_steps=2 errors=0`), not reasoned about. Gate `step-end-status-honesty.yml#step-end-honesty`. **BOM row + capability `closing_verdict_consults_failed_steps`.** Shipped-artefact proof owed on the walk. |
| A2 | #1370 `39e896b6` — declined remote access is never followed by a sign-in promise | **DONE at source** | Copy no longer promises a thing the customer declined. Not BOM-guarded: no pattern found that discriminates against the pre-fix tree. |
| A3 | #1371 `318d513d` — ERR-06 leads with the measurement, not the word LEAK (#612) | **DONE at source** | Diagnostic states what was measured. Not BOM-guarded, same reason. |
| A4 | #1372 `da360b9b` — the class gate: declared-vs-present, both directions, NAMED | **DONE at source** | The gate IS the proof; it runs in CI. |
| A5 | #1374 `4ef8c0ec` — `qdrant_collection` as a 5th class-gate type (A2) | **DONE at source** | Extends A4's gate. |
| A6 | #1373 `cefae599` — contacts bound; a killed wrapper is not an empty address book | **DONE at source** | Distinguishes "wrapper died" from "no contacts". Not BOM-guarded. |
| A7 | #1375 `dc9d85d3` — the six hardcoded hydrate caps named, raised to 1800, gated | **DONE at source** | Caps are named and gated rather than silent. |
| A8 | #1376 `e08869ab` — #616: name WHICH collections are missing, not how many | **DONE at source** | A count told a customer nothing actionable. |
| A9 | #1377 `477608ab` — #619: a reuse-settings re-run keeps the customer's daily briefs | **DONE at source** | 🔴 CUSTOMER-VISIBLE SILENT LOSS. Gate `assistant-config-required-fields.yml#assistant-config-required-fields`; the test is INVOKED (2 hits, control 2). **BOM row + capability `reuse_run_preserves_daily_brief_channels`.** Mutation-proved: the real pre-fix install.sh still fails arm A with *"wrote 0 [[cron.jobs]], expected 2 — the customer lost their briefs"*. Shipped-artefact proof owed on the walk. |

### ⚠️ WHY ONLY TWO OF THE NINE ARE BOM ROWS

`cuts/v1.0.61/MUST_CONTAIN.tsv` carries **2 rows, not 9**. A BOM row needs a
`capability_id` that RESOLVES in `manifest/capability_manifest.tsv` **and** a
pattern that DISCRIMINATES — present on the shipped tree, ABSENT on the pre-fix
one. Both were mutation-tested against v1.0.60's CM051 pin `355a503e` before
being written:

```
_ostler_restore_channels_from_existing_config   post=6   pre=0    ✅ A9
MSG_WARN_INSTALL_FINISHED_WITH_FAILED_STEPS     post=3   pre=0    ✅ A1
failed_steps                                    post=2   pre=1    ❌ REJECTED
CONTROL OSTLER_EXTENSION_TOKEN                  post=13  pre=13   (scan is live)
```

`failed_steps` is the obvious string for A1 and it is **present on the pre-fix
tree**. A row built on it would have been accepted, reported GREEN for ever, and
guarded nothing. Per #959, a row that guards nothing is worse than no row.

---

## B. CARRIED FORWARD FROM v1.0.60 — ELEVEN OPEN PRODUCT ROWS

⛔ **Reproduced verbatim. NOT descoped by me. Descoping is Andy's call, in writing.**
IDs are v1.0.60's originals so the two manifests can be diffed against each other.

| v1.0.60 # | Item | State | Proof required |
|---|---|---|---|
| A6 | **Apple Notes actually land on a box** | TODO (carried) | count > 0 in the knowledge store after a real install |
| B2 | Voice feed silently skips if `~/Documents/Ostler/Transcripts` is ever deleted (sentinel-guarded creation, presence-gated reader) | TODO (carried) | delete dir, re-run install, assert a REFUSAL not a silent skip |
| B5 | **Chrome extension is NOT SHIPPED.** install.sh opens `chrome.google.com/webstore/category/extensions` — the generic category page, not our listing | TODO (carried) | either a real listing URL, or the step does not run at all |
| C8 | **"Keeps updating" for all 19 rows** — Andy wants green in every cell | TODO (carried) | **a T+1h probe per surface.** A surface that lands once and stops is indistinguishable from a working one at T+0 |
| D1 | `unverifiable_ack` / `hold_ack` require a MANDATORY expiry + a HUMAN owner | TODO (carried) | gate proved RED on a row with neither |
| D2 | A cut REFUSES when any ack is past its date | TODO (carried) | demonstrated refusal |
| D3 | Open each of the other 14 rows: does it withhold something the customer is told they have? | TODO (carried) | 14 verdicts, one per row |
| E2 | Result lands where the Doctor can read it | TODO (carried) | Doctor surfaces it |
| E3 | Add probes for the 19 ingest surfaces (T+0 **and** T+1h) | TODO (carried) | 19 × 2 probes exist and run |
| E4 | Probes cluster where measuring is easy and are absent where it is hard (#533) | TODO (carried) | coverage stated with a denominator |
| G4 | Panel renders landed + last-updated, and says WHY when dark | TODO (carried) | on a box |

📌 **Note on D1/D2 specifically:** CM051 #965 records that 32 of 709 deferrals
carry no `until_cut` at all, so the ratchet cannot see them — which is the same
defect D1 names, measured independently. Carried, not merged into one row.

---

## C. CUT MECHANICS — v1.0.61

Re-scoped to this cut rather than carried, because each is a statement about a
specific tag.

| # | Item | State | Proof required |
|---|---|---|---|
| F1 | Green gates-only dry run BEFORE the tag | TODO | run id; preflight + dry-run both 0 failures |
| F2 | Ledger row filed SAME TURN as the tag | TODO | row on main, re-fetched and parsed |
| F3 | OS003 rollforward row filed | TODO | row on main |
| F4 | Box walk | TODO | walk record with `box_walked: true`. ⚠️ Subject NOT YET NAMED — Archie's call, deliberately blank rather than inherited |

### 🔴 F1 IS NOT OPTIONAL AND THE REGISTER SAYS WHY IN ARCHIE'S OWN WORDS

The v1.0.59 row records that a gates-only `workflow_dispatch` **caught six
refusals at zero version cost**, and that v1.0.57 and v1.0.58 both skipped it and
paid. `cut:` is guarded `if: github.event_name == 'push'`, so a dispatch runs the
checks and cannot make an artefact. **NEVER TAG WITHOUT A GREEN DRY RUN.**

---

## CARRIED-FORWARD REGISTER

Nothing may be added here without Andy's written agreement.

*(empty — and note that "empty" here means no row has been PARKED. It does not
mean nothing is outstanding: Section B is eleven outstanding rows, carried in
full and visible, which is the opposite of parking them.)*
