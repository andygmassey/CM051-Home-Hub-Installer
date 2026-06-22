# CX-123 / #643 — set -u landmine audit + structural guard report

**Repo:** CM051 install.sh (origin/main d9c518c, 13,657 lines).
**Symptom:** clean-box install on .134 ran fully (all services up, data hydrated, Pro activated) then false-failed on `install.sh: line 13455: CONTACT_COUNT: unbound variable`. A `set -u` abort in the display-only success recap exits the script before `gui_done ok`, so no DONE marker is emitted and the GUI infers a failure on a fully-successful install.

## Why this is whack-a-mole, and the structural fix

The final-summary recap is a dense run of bare `$VAR` references inside `[[ ... ]]` tests and `echo`s. Each install PATH (fresh vs reuse, channel combos, battery/FDA/wiki/vane state) leaves a *different* optional var unset, so under `set -u` a different bare reference aborts on each cut. Patching one line just moves the abort one line along. The fix has to neutralise the whole block at once.

**Primary fix (structural):** the entire recap, from the `# ── Summary ──` arithmetic through `gui_done ok`, is wrapped in `set +u` ... `set -u` (nounset disabled for the block only, state saved/restored). `errexit (-e)` and the ERR trap stay ACTIVE inside the block, so a genuine command failure still aborts correctly; only the unbound-variable abort is suppressed. One change neutralises every landmine in the block, including any bare echo var.

**Belt-and-braces (structural):** the 5 summary optionals that had no unconditional early initialisation are now defaulted at the top of the declaration cluster, so they are set on EVERY path (their real conditional assignments still override on their own path), and the printed recap is sensible rather than blank.

## Landmines + fix + test coverage

### A. The recap / success block (install.sh ~13443 -> `gui_done ok` ~13639) — the launch blocker

Every bare reference below was a live landmine: on some path the variable is unset and `set -u` aborts before the DONE marker. ALL are neutralised by the `set +u`/`set -u` wrap.

| var(s) | example line | unset on which path |
|---|---|---|
| `CONTACT_COUNT` | `[[ -n "$CONTACT_COUNT" && "$CONTACT_COUNT" -gt 0 ]]` | fresh install (only assigned inside the reuse-settings `if`) — THIS is the .134 abort |
| `EXPORTS_DIR` (x2: `-n` and `-z`) | `[[ -n "$EXPORTS_DIR" ]]`, `[[ -z "$EXPORTS_DIR" ]]` | fresh install (assigned only inside the reuse `if`) |
| `FV_ENABLED` | `[[ "$FV_ENABLED" == true ]]` | (already had a col0 default; covered anyway) |
| `WIKI_FIRST_COMPILE_OK` | `if [[ "$WIKI_FIRST_COMPILE_OK" == true ]]` | any path where the wiki first-compile branch did not run |
| `CHANNEL_IMESSAGE_ENABLED` / `CHANNEL_EMAIL_ENABLED` / `CHANNEL_WHATSAPP_ENABLED` | `[[ "$CHANNEL_IMESSAGE_ENABLED" == true || ... ]]` | (already had col0 defaults; covered anyway) |
| `CHANNEL_IMESSAGE_ALLOWED` / `CHANNEL_EMAIL_USERNAME` | `echo "... ${CHANNEL_IMESSAGE_ALLOWED}"` | channel selected but value never captured |
| `IMESSAGE_TCC_STATUS` | `[[ "${IMESSAGE_TCC_STATUS}" != "granted-and-working" ]]` | no-iMessage path (probe block never ran) |
| `VANE_OK` | `if [[ "$VANE_OK" == true ]]` | any path where the Vane health branch did not run |
| `HAS_BATTERY` | `if [[ "$HAS_BATTERY" == true ]]` | (already had a col0 default; covered anyway) |
| bare echo vars: `USER_NAME`, `USER_ID`, `ASSISTANT_NAME`, `USER_TZ`, `COUNTRY_CODE`, `AI_MODEL`, `INSTALL_MINS`, `INSTALL_SECS`, `OSTLER_DIR`, `CONFIG_DIR`, `DATA_DIR`, `LOGS_DIR` | `echo "User: ${USER_NAME} (${USER_ID})"` | core vars, set on normal paths; the wrap removes any residual risk and the EXIT-trap region |

**Fix:** `set +u`/`set -u` wrap (primary) + unconditional early defaults for `CONTACT_COUNT=0`, `EXPORTS_DIR=""`, `WIKI_FIRST_COMPILE_OK=false`, `IMESSAGE_TCC_STATUS=""`, `VANE_OK=false` (belt-and-braces).
**Test:** `tests/test_final_summary_nounset_safe.sh` extracts the REAL wrapped block and runs it under `set -Eeuo pipefail` across 7 scenarios with the optionals unset (all-unset worst case, reuse-typical, channels-all-off, imessage+tcc-denied, no-battery+vane-down+wiki-not-compiled, fda-zero+contacts/exports-unset, partial-health) and asserts each reaches `gui_done ok`. A RED control runs the same recap WITHOUT the wrap and asserts it aborts before `gui_done ok` (proving the wrap is load-bearing).

### B. Other late-region references swept (outside the recap) — confirmed safe or defaulted

The whole script was scanned for bare `$VAR` inside test/arith/echo constructs where the var is a known-optional (used as `${VAR:-}` somewhere) with no early default. After filtering same-line short-circuit guards and loop/function locals, the late-region (>L12700) candidates outside the wrap were:

| line | var | verdict |
|---|---|---|
| ~13065 | `IMESSAGE_TCC_STATUS` | inside its own probe/write block (set at block start); ALSO now early-defaulted -> safe |
| ~12710 | `count` | loop/function-local, defaulted on the preceding line (`count="${count:-0}"`) -> safe |
| ~12943 / ~12961 | `SCRIPT_DIR` / `LOGS_DIR` | core infra vars, unconditionally set early (`LOGS_DIR` at L7794/9908) -> safe |
| ~13196 | `ASSISTANT_BINARY` | inside the `[[ -x "${ASSISTANT_BINARY:-}" ]]` doctor-probe guard -> safe |
| post-`gui_done ok` tail (icon cache-bust, Dock restart, browser open) | `$app`, `${OSTLER_GUI:-}` | loop-local / guarded, AND runs after the DONE marker (a failure there cannot false-fail) -> safe |

No additional structural change required outside the recap; the one genuine latent risk (`IMESSAGE_TCC_STATUS`) is covered by the early default.

### Scan note (no silent cap)

A whole-script precise "unconditional vs conditional assignment" classifier is unreliable on 13.6k lines of bash (control-flow depth accumulates across heredocs / `case` / multi-line constructs), so this audit uses the structural wrap as the guarantee for the recap and a targeted high-signal scan (bare var in a test/echo, known-optional, no early default) for the rest, each item then verified by hand. The path-matrix test is the real guarantee that the recap cannot abort regardless of which optionals are unset.

## Acceptance

- `bash -n install.sh` clean.
- No new user-facing strings (rule 0.9 N/A); British English; no em-dashes.
- New `tests/test_final_summary_nounset_safe.sh` green (7 matrix scenarios + RED control).
- Pre-existing reds NOT caused by this change, flagged not bundled: `test_no_internal_codenames_in_customer_strings` (CM### catalogue leak) and `test_install_daily_briefs` (both red on pristine origin/main).

## Addendum — whole-file second pass (2026-06-08, post-merge)

The original audit deliberately skipped a whole-file classifier as "unreliable on 13.6k lines" and guaranteed the recap structurally. This addendum records a whole-file second pass run against `origin/main` (now 13,721 lines, HEAD `fe46a17`) so the `set -u` question is documented closed end-to-end, not just for the recap. Result: **no genuine cross-path landmine exists outside the wrapped recap.** No code change accompanies this addendum; it is the record of a negative finding (no silent cap).

Two independent, complementary heuristics were run over the pre-recap region (L1 to L13440), each candidate then verified by hand:

1. **Guarded-optional class** — bare `$VAR`/`${VAR}` (not `${VAR:-}`) in a `[[ ]]` / `(( ))` / `echo` context, where VAR is treated as optional somewhere (`${VAR:-}` appears in the file) and has no col-0 default. 110 candidates; all false positives or already-safe. Representative verdicts:
   - `AI_MODEL` (L3547-3556) — `if/elif/else`, the `else` sets it on every path before the L3558 reference.
   - `FDA_GRANTED` (L6264-6274) — set on both branches of the `if/else` immediately before the L6275 reference.
   - `TAKEOUT_MBOX_PATH` / `TAKEOUT_ZIP_PATH` — bare refs at L3741/3744 sit inside the enclosing `if [[ -n "${VAR:-}" ]]` guard (L3738/3740); the bare ref only executes when the var is confirmed set.
   - `OSTLER_PROGRESS_EMITTER` — bare ref at L1048 is the then-branch of `if [[ -n "${OSTLER_PROGRESS_EMITTER:-}" && -f ... ]]` (L1047).
   - `SCRIPT_DIR` (49 refs) — set unconditionally in both branches of the bootstrap `if` at L859/862.

2. **Never-guarded conditional-only class** — the complementary blind spot of scan 1: a var bare-referenced in a `[[ ]]`/`(( ))` context whose only assignments are indented (never col-0) and which is never `${VAR:-}` guarded anywhere (so scan 1 could not see it — this is the exact `CONTACT_COUNT`-minus-the-guard shape). 127 candidates; every one is a straight-line local whose assignment is on the line(s) immediately above the reference (e.g. `ACK_PASSKEY` 3420->3421, `ACTUAL_SHA` 10308->10309), or a `local VAR=` / `for`/`while read` loop init the `^VAR=` regex does not capture (verified directly: `next_heartbeat` is `local next_heartbeat=30` at L1437, before its L1445 loop reference). None has the cross-conditional-boundary separation that a genuine landmine requires.

The launch-blocking shape (assigned only in a far conditional branch, referenced in an unrelated later block) appears exactly once in the file: the recap, which is structurally wrapped. The path-matrix test remains the guarantee.

**Re-verified green on `origin/main` HEAD `fe46a17` (2026-06-08):** `tests/test_final_summary_nounset_safe.sh` passes all 7 matrix scenarios (each reaches `gui_done ok`) and the RED control still aborts before `gui_done ok`, proving the wrap is load-bearing on the currently-shipping tree. `bash -n install.sh` clean.
