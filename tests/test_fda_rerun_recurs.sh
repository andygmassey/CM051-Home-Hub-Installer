#!/usr/bin/env bash
# ============================================================================
# test_fda_rerun_recurs.sh -- com.ostler.fda-rerun must RECUR, and the fix must
# reach boxes that already carry the one-shot plist.
#
# THE DEFECT (#714, measured 2026-08-16)
#
# install.sh wrote the fda-rerun LaunchAgent with a StartCalendarInterval whose
# Year, Month, Day, Hour AND Minute were all pinned to install+12h. A fully
# specified StartCalendarInterval is a ONE-SHOT: launchd fires it at that
# instant (or at the next wake) and never again, because the date is then in
# the past forever.
#
# That silently falsified a decision made elsewhere in install.sh. At the
# OSTLER_HYDRATE_CALENDAR_DAYS site, CX-106 narrowed the install-time calendar
# window to 90 days on the stated premise that "the hourly fda-rerun
# LaunchAgent walks the ... window in the background". The agent was never
# hourly.
#
# TWO LIMBS, AND THIS FILE GUARDS BOTH
#
#   limb 1  the plist must carry StartInterval, not a pinned calendar date
#   limb 2  a box that ALREADY has the one-shot plist must be MIGRATED
#
# Limb 2 is the #768/#769 lesson made a control. #768 fixed a sentinel bug for
# fresh installs only, because its guard was a bare `[[ ! -f ]]`: every box that
# already had the defect kept it, and #769 had to correct that within the hour.
# The same `[[ ! -f ]]` shape was sitting right here. A control that only ever
# exercises the state the change PRODUCES cannot see the state it INHERITS.
#
# WHY THE PREDICATES READ install.sh RATHER THAN RE-IMPLEMENT IT
#
# Every control below extracts the REAL text out of the shipping install.sh
# with awk and asserts against that. A self-test that compares install.sh to a
# local re-implementation of the same logic is a duplicated predicate: it goes
# green while the shipping path carries the defect. If extraction fails, this
# script exits 2 CANNOT-RUN rather than 0, because "found nothing to check" and
# "checked and it was fine" must never print the same verdict.
#
# EXIT CODES   0 all controls pass   1 a control failed   2 CANNOT-RUN
#
# --self-test  reinstates the defect in a COPY of install.sh and proves the
#              controls go RED. Wired as its OWN CI job, never as a sibling
#              step, because a failing step masks everything after it.
# ============================================================================
set -uo pipefail

REPO_ROOT=""
SELF_TEST=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --self-test) SELF_TEST=1; shift ;;
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
INSTALL_SH="${REPO_ROOT}/install.sh"
STRINGS_SH="${REPO_ROOT}/install.sh.strings.en-GB.sh"

PASS=0
FAIL=0

cannot_run() {
    echo "CANNOT-RUN: $*" >&2
    exit 2
}

check() {
    local name="$1"; shift
    if "$@"; then
        printf '  [pass] %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  [FAIL] %s\n' "$name"
        FAIL=$((FAIL + 1))
    fi
}

[[ -f "$INSTALL_SH" ]] || cannot_run "install.sh not found at $INSTALL_SH"
[[ -f "$STRINGS_SH" ]] || cannot_run "strings file not found at $STRINGS_SH"

# ---------------------------------------------------------------------------
# EXTRACTION. Both regions come out of the shipping file, or we exit 2.
# ---------------------------------------------------------------------------

# The plist heredoc, exactly as install.sh emits it.
PLIST_BODY="$(awk '
    /cat > "\$FDA_RERUN_PLIST" <<FDARPEOF/ { grab = 1; next }
    grab && /^FDARPEOF$/                   { exit }
    grab                                   { print }
' "$INSTALL_SH")"

[[ -n "$PLIST_BODY" ]] || cannot_run \
    "could not extract the fda-rerun plist heredoc from install.sh; the marker moved"

# The write-decision guard, so controls 4-6 exercise the REAL predicate.
GUARD_BODY="$(awk '
    /^    FDA_RERUN_NEEDS_WRITE=0$/                       { grab = 1 }
    grab                                                  { print }
    grab && /^    if \[\[ "\$FDA_RERUN_NEEDS_WRITE" == "1" \]\]; then$/ { exit }
' "$INSTALL_SH")"

[[ -n "$GUARD_BODY" ]] || cannot_run \
    "could not extract the fda-rerun write guard from install.sh; the marker moved"

# Strip the trailing `if ...; then` so the block is evaluable on its own.
GUARD_EVAL="$(printf '%s\n' "$GUARD_BODY" | sed '$d')"

# The launchctl stanza that follows the heredoc, for the bootout control.
#
# 🔴 THE STANZA AND ITS SUCCESS MESSAGE ARE NO LONGER ADJACENT, AND THAT IS
# DELIBERATE (v1063-D010). This used to run from FDARPEOF to the first
# MSG_OK_FDA_RE_RUN, on the assumption that the bootout, the load and the
# success message all sat together. The LOAD is now deferred by ~3,300 lines,
# until after ~/.ostler/bin/ostler-fda is written, because launchd starts a
# StartInterval job IMMEDIATELY on load and the old ordering fired a tick
# against a binary that did not exist yet -- measured on the Mini 16, the
# error log written 38 seconds BEFORE the binary.
#
# So the stanza now ends at the write-guard's closing `fi` rather than at a
# message that has moved. Ordering is asserted separately and by LINE NUMBER
# in c9, which is a stronger claim than "these two strings are near each
# other" and cannot be satisfied by proximity.
LAUNCHCTL_BODY="$(awk '
    /^FDARPEOF$/                                  { grab = 1; next }
    grab && /_OSTLER_FDA_RERUN_LOAD_PENDING=1/    { print; exit }
    grab                                          { print }
' "$INSTALL_SH")"

[[ -n "$LAUNCHCTL_BODY" ]] || cannot_run \
    "could not extract the fda-rerun launchctl stanza from install.sh"

# ---------------------------------------------------------------------------
# The guard, exercised against a real file on disk.
# `mktemp -t` on BSD ignores TMPDIR, so build the dir explicitly.
# ---------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fdarerun.XXXXXX")" || cannot_run "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# Runs the EXTRACTED guard against a given plist state and echoes
# "<needs_write> <was_legacy>".
run_guard() {
    local state="$1"   # absent | legacy | modern | pathless
    local plist="${WORK}/com.ostler.fda-rerun.plist"
    rm -f "$plist"
    case "$state" in
        legacy) printf '<key>StartCalendarInterval</key>\n<dict><key>Year</key><integer>2026</integer></dict>\n' > "$plist" ;;
        # `modern` means CORRECT, and what counts as correct widened on
        # 2026-08-20: this job runs the tick's python toolchain, which resolves
        # through PATH, and launchd gives it /usr/bin:/bin:/usr/sbin:/sbin. A
        # plist with StartInterval and no Homebrew prefix is now a box that
        # MUST be rewritten, so it moved to the `pathless` state below. Leaving
        # it here would have been a fixture encoding the shape the old code
        # handled, which is how control (7) reads a correct rewrite as churn.
        modern) printf '<key>StartInterval</key>\n<integer>3600</integer>\n<key>EnvironmentVariables</key>\n<dict><key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string></dict>\n' > "$plist" ;;
        pathless) printf '<key>StartInterval</key>\n<integer>3600</integer>\n' > "$plist" ;;
        absent) : ;;
        *) return 1 ;;
    esac
    FDA_RERUN_PLIST="$plist" bash -c "
        set -u
        FDA_RERUN_PLIST='$plist'
        $GUARD_EVAL
        printf '%s %s\n' \"\$FDA_RERUN_NEEDS_WRITE\" \"\$FDA_RERUN_WAS_LEGACY\"
    "
}

# ---------------------------------------------------------------------------
# CONTROLS
# ---------------------------------------------------------------------------

# (1) THE DEFECT ITSELF. The shipped plist must schedule by interval.
c1() { printf '%s\n' "$PLIST_BODY" | grep -q '<key>StartInterval</key>'; }

# (2) And must NOT reintroduce a pinned calendar date. Checked separately from
#     (1) because a plist can legitimately carry BOTH keys, and a partially
#     restored StartCalendarInterval would slip past (1) alone.
c2() { ! printf '%s\n' "$PLIST_BODY" | grep -q 'StartCalendarInterval'; }

# (3) No pinned Year/Month/Day survives anywhere in the heredoc. This is the
#     axis that made the old plist one-shot -- a StartCalendarInterval with
#     only Minute set recurs hourly and is harmless; it is the DATE that kills
#     it. Assert the mechanism, not the key name.
c3() { ! printf '%s\n' "$PLIST_BODY" | grep -qE '<key>(Year|Month|Day)</key>'; }

# (4) The interval is substituted from the tunable, not hardcoded in the plist,
#     so a test or an operator can vary it without editing the heredoc.
c4() { printf '%s\n' "$PLIST_BODY" | grep -q '<integer>\${OSTLER_FDA_RERUN_INTERVAL_S}</integer>'; }

# (5) The tunable has a positive-integer default. A default of 0 or empty would
#     make launchd reject the job, and the install would still print success.
c5() {
    local d
    d="$(grep -oE ': "\$\{OSTLER_FDA_RERUN_INTERVAL_S:=[0-9]+\}"' "$INSTALL_SH" \
         | grep -oE '[0-9]+' | head -1)"
    [[ -n "$d" ]] && [[ "$d" -gt 0 ]]
}

# (6) UPGRADE LIMB. A box that already carries the one-shot plist must be
#     rewritten AND flagged legacy. This is the control #768 did not have.
c6() { [[ "$(run_guard legacy)" == "1 1" ]]; }

# (7) A box that already carries the fixed plist must NOT be rewritten. Without
#     this, (6) could be satisfied by a guard that rewrites unconditionally,
#     which would bootout and rebootstrap the agent on every re-run.
c7() { [[ "$(run_guard modern)" == "0 0" ]]; }

# (8) A fresh install still writes, and is not mislabelled as a migration.
c8() { [[ "$(run_guard absent)" == "1 0" ]]; }

# (9) The migration must BOOTOUT the old job before bootstrapping. Rewriting the
#     file on disk changes nothing on a box where the old label is still loaded:
#     bootstrap is a no-op against an already-loaded label, so the customer
#     keeps running the exact plist we just replaced.
# Two claims, both by LINE NUMBER, because install.sh executes top to bottom
# so "earlier in the file" IS "earlier in time" for statements at the same
# reachability:
#   (a) the migration boots out the old label, and
#   (b) it does so BEFORE the bootstrap.
# A proximity grep could be satisfied by a bootout that runs after the load,
# which is the failure this control exists to prevent.
c9() {
    local bootout_at load_at
    printf '%s\n' "$LAUNCHCTL_BODY" | grep -q 'launchctl bootout' || return 1
    bootout_at="$(grep -n -F 'launchctl bootout "gui/$(id -u)/com.ostler.fda-rerun"' "$INSTALL_SH" | head -1 | cut -d: -f1)"
    load_at="$(grep -n -F '_ostler_launchagent_load_verified "$FDA_RERUN_PLIST"' "$INSTALL_SH" | head -1 | cut -d: -f1)"
    [ -n "$bootout_at" ] && [ -n "$load_at" ] || return 1
    [ "$bootout_at" -lt "$load_at" ]
}

# (10) The success message install.sh prints must exist in the catalogue. A
#      missing key expands to empty under `ok ""`, so the step reports success
#      with a blank line and nobody notices.
# Read from install.sh rather than from LAUNCHCTL_BODY (v1063-D010). The
# success message now lives with the DEFERRED load, ~3,300 lines below the
# stanza, so scoping this to the stanza would report "no key" and fail for a
# reason that has nothing to do with the catalogue.
#
# THE PROPERTY IS LOCATION-INDEPENDENT: whatever key the code emits must exist
# in the strings file. Widening the search does not weaken it -- the key is
# still taken from the CODE and still checked against the CATALOGUE, and a
# missing entry still fails. It is the same question asked of the whole file
# instead of a window that has stopped containing the answer.
c10() {
    local key
    key="$(grep -oE 'MSG_OK_FDA_RE_RUN[A-Z_]*' "$INSTALL_SH" | head -1)"
    [[ -n "$key" ]] && grep -q "^${key}=" "$STRINGS_SH"
}

# (11) The date arithmetic that computed the one-shot moment must be GONE, not
#      merely unused. A leftover `date -v+12H` assignment is a live invitation
#      to wire the old schedule back in, and it is the thing a reader greps for.
c11() { ! grep -qE 'FDA_RERUN_(YEAR|MONTH|DAY|HOUR|MIN)=' "$INSTALL_SH"; }

# (12) THE SECOND UPGRADE LIMB, 2026-08-20. A box carrying a plist that is
#      modern in SCHEDULE but has no Homebrew prefix on PATH must be rewritten.
#      Every fda-rerun plist written before that date is exactly this shape, so
#      without the limb the fix reaches fresh installs only and every existing
#      box keeps a job that cannot resolve its own python toolchain. Same
#      #768/#769 shape as (6), one key over.
#
#      Note this is NOT redundant with (7): (7) now uses a plist that carries
#      the PATH, so the pair discriminates "correct, leave alone" from
#      "modern schedule but unusable, rewrite". Before today they were the
#      same fixture and only one answer was possible.
c12() { [[ "$(run_guard pathless)" == "1 0" ]]; }

run_controls() {
    PASS=0
    FAIL=0
    echo "fda-rerun recurrence controls (install.sh: $INSTALL_SH)"
    check "(1)  plist schedules with StartInterval"                  c1
    check "(2)  plist carries no StartCalendarInterval"              c2
    check "(3)  plist pins no Year/Month/Day"                        c3
    check "(4)  interval is substituted from the tunable"            c4
    check "(5)  tunable defaults to a positive integer"              c5
    check "(6)  legacy plist on disk  -> rewrite, flagged legacy"    c6
    check "(7)  fixed plist on disk   -> no rewrite, no churn"       c7
    check "(8)  no plist on disk      -> write, not a migration"     c8
    check "(9)  migration boots out the old label BEFORE bootstrap"  c9
    check "(10) success message key exists in the catalogue"         c10
    check "(11) one-shot date arithmetic is deleted"                 c11
    check "(12) PATH-less plist on disk -> rewrite, not flagged legacy" c12
}

# ---------------------------------------------------------------------------
# --self-test: PROVE RED. Reinstate each half of the defect in a copy and
# require the matching control to fail. A control that has never been observed
# failing is not evidence that it can.
# ---------------------------------------------------------------------------
if [[ "$SELF_TEST" == "1" ]]; then
    echo "SELF-TEST: reinstating the defect and requiring RED"
    SELF_FAIL=0

    probe() {
        local label="$1" sedscript="$2" expect_fail="$3"
        local dir="${WORK}/self-${label}"
        mkdir -p "$dir"
        sed "$sedscript" "$INSTALL_SH" > "${dir}/install.sh"
        cp "$STRINGS_SH" "${dir}/install.sh.strings.en-GB.sh"
        mkdir -p "${dir}/tests"
        cp "${BASH_SOURCE[0]}" "${dir}/tests/$(basename "${BASH_SOURCE[0]}")"
        local out rc
        out="$(bash "${dir}/tests/$(basename "${BASH_SOURCE[0]}")" --repo-root "$dir" 2>&1)"
        rc=$?
        if [[ "$rc" == "2" ]]; then
            printf '  [INCONCLUSIVE] %s -- controls could not run against the mutated copy\n' "$label"
            printf '%s\n' "$out" | sed 's/^/      /'
            SELF_FAIL=$((SELF_FAIL + 1))
            return
        fi
        if printf '%s\n' "$out" | grep -q "\[FAIL\] ${expect_fail}"; then
            printf '  [pass] %s -> %s went RED as required\n' "$label" "$expect_fail"
        else
            printf '  [FAIL] %s -> %s stayed GREEN with the defect present\n' "$label" "$expect_fail"
            printf '%s\n' "$out" | sed 's/^/      /'
            SELF_FAIL=$((SELF_FAIL + 1))
        fi
    }

    # Defect A: the original one-shot schedule, restored verbatim.
    probe "one-shot-schedule" \
        's|<key>StartInterval</key>|<key>StartCalendarInterval</key><dict><key>Year</key><integer>2026</integer></dict><key>Unused</key>|' \
        "(2)"

    # Defect B: the bare [[ ! -f ]] guard -- the #768 shape. Boxes that already
    # carry the one-shot plist are never migrated.
    probe "fresh-installs-only-guard" \
        's|^    elif grep -q .StartCalendarInterval. "\$FDA_RERUN_PLIST" 2>/dev/null; then$|    elif false; then|' \
        "(6)"

    # Defect C: file rewritten but the loaded label never booted out, so the box
    # keeps running the plist we just replaced.
    probe "no-bootout" \
        's|launchctl bootout|launchctl no_such_subcommand|' \
        "(9)"

    echo
    if [[ "$SELF_FAIL" -gt 0 ]]; then
        echo "SELF-TEST FAILED: $SELF_FAIL probe(s) did not go red"
        exit 1
    fi
    echo "SELF-TEST PASSED: every probe went red on the axis it targets"
    exit 0
fi

run_controls
echo
if [[ "$FAIL" -gt 0 ]]; then
    echo "FAILED: ${FAIL} of $((PASS + FAIL)) controls"
    exit 1
fi
echo "PASSED: ${PASS} of ${PASS} controls"
exit 0
