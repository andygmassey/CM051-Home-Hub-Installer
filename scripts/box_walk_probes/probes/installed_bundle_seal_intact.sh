#!/usr/bin/env bash
# installed_bundle_seal_intact.sh -- every installed .app must still satisfy its
# own code signature AFTER a real install, not merely when it was signed.
#
# ============================================================================
# WHY THIS EXISTS, AND WHY 32 CUTS PASSED WITHOUT IT
# ============================================================================
#
# MEASURED on the v1.0.32 box, 2026-08-16, after a genuine install:
#
#     spctl -a -vv /Applications/OstlerInstaller.app
#       -> "a sealed resource is missing or invalid"        rc=1
#     codesign --verify --deep --strict
#       -> 346 UNSEALED files
#     263 of those written DURING the install window
#     PKG-INFO mtime 20:25:29  vs  signature Timestamp 17:09:52
#
# Cause: install.sh ran `pip install "${SCRIPT_DIR}/<pkg>"` at FIVE call sites,
# and when the installer runs from the signed app SCRIPT_DIR is
# Contents/Resources. `pip install <dir>` builds IN PLACE, writing *.egg-info
# and build/lib/ into the bundle. A pip build executing inside a notarised
# bundle voids its notarisation.
#
# EVERY SIGNING CHECK WE OWN RUNS PRE-INSTALL, on the freshly signed bundle.
# That is precisely why this survived 32 cuts: the gate and the defect were on
# different surfaces. The signature was valid at the moment it was measured and
# invalid at the moment it mattered. This probe measures the SECOND moment.
#
# The bundle still LAUNCHED on that box only because com.apple.quarantine
# happened to be absent. A customer downloading the DMG carries the quarantine
# bit, and Gatekeeper then refuses. So "it worked on the test Mac" is not
# evidence and must not be accepted as any.
#
# ============================================================================
# v1.0.46 BOM ROW 6 -- THE READER WAS MEASURING THE WRONG COMPUTER
# ============================================================================
#
# The row, verbatim:
#
#     UNRESOLVED CONTRADICTION, blocks a CLAIM not the cut:
#     installed_bundle_seal_intact reports all three Ostler bundles MISSING
#     from /Applications while a direct SSH read finds /Applications/Ostler.app
#     present (short=0.7.1, mtime 22 Aug 17:34). One of the two readers is
#     lying and neither may be cited until it is known which.
#
# ADJUDICATED. This probe was the wrong one, and NOT because it was denied a
# read. Every other probe in this suite reaches the box through box_run. This
# one contained no ssh, no box_run and no mention of OSTLER_BOX_HOST at all:
#
#     grep -n "box_run\|ssh\|OSTLER_BOX_HOST" installed_bundle_seal_intact.sh
#     -> rc=1, zero matches
#
# so `[[ -d /Applications/Ostler.app ]]` was always a question about the
# operator's own laptop. Watched failing 2026-08-25 on the pre-fix file:
#
#     OSTLER_BOX_HOST=operator@definitely-not-a-real-box.invalid \
#         bash probes/installed_bundle_seal_intact.sh
#     ->  MISSING   /Applications/OstlerInstaller.app
#         MISSING   /Applications/Ostler.app
#         MISSING   /Applications/Ostler RemoteCapture.app
#         rc=2
#
# A host that cannot even be resolved, and a full three-line verdict about it.
# The bundles really were absent -- but on the DEVELOPMENT LAPTOP the command
# was typed on, whose /Applications enumerated 110 entries with no Ostler among
# them. Correct answer, wrong machine. A CONTROL CAN BE IN THE WRONG
# COMPARTMENT ENTIRELY, and so can a subject.
#
# TWO FIXES, and the second is the one that generalises:
#
#   1. Every filesystem read now goes through box_run_v, so the probe inspects
#      THE BOX UNDER TEST.
#
#   2. The reader SHOWS ITS WORKING. lib/bundle_inspect.py prints the hostname,
#      uid/euid, transport, SIP and TCC state, the RESOLVED path after symlink
#      and variable expansion, the raw errno and strerror of any failing
#      syscall, and -- for an absence -- the ancestor directory it enumerated
#      and how many entries were in it. A verdict with no record of what was
#      inspected cannot be adjudicated, which is how this contradiction sat
#      open in the first place.
#
# ============================================================================
# THREE OUTCOMES, THREE APPEARANCES
# ============================================================================
#
#     PRESENT      lstat succeeded
#     ABSENT       the ancestor was LISTED and the component was not in it
#     CANNOT-LOOK  the read was refused (EACCES/EPERM/...), or no ancestor
#                  could be enumerated, so absence was never established
#
# CANNOT-LOOK NEVER RENDERS AS ABSENT. It exits 78 (the contract's CANNOT_RUN),
# because a box walk that could not read /Applications has verified nothing and
# reporting that as "not installed" is a false absence with a version number
# attached to it.
#
# The old file exited 2 for its cannot-run case. 2 is not in this contract --
# run_box_walk.sh maps 78 to CANNOT-RUN and counts everything else non-zero as
# FAIL -- and the old file also had no --self-test, so phase 1 ran its real body,
# got 2, and marked it BROKEN. It has therefore never returned a measurement in
# phase 2 on any box walk. Both are fixed here.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSPECTOR="$SUITE_DIR/lib/bundle_inspect.py"

PROBE_NAME="installed_bundle_seal_intact"
PROBE_QUESTION="does the installed bundle's signature still verify on the box, and can this reader prove what it looked at?"

APP_1="/Applications/OstlerInstaller.app"
APP_2="/Applications/Ostler.app"
APP_3="/Applications/Ostler RemoteCapture.app"

# ---------------------------------------------------------------------------
# Transport. Kept separate from box_reachable() because that one routes through
# box_run, which discards stderr -- and "ssh: Could not resolve hostname" is
# the single most useful line available when a box walk cannot reach its box.
# ---------------------------------------------------------------------------
TRANSPORT_ERR=""
transport_ok() {
    [ -z "${OSTLER_BOX_HOST:-}" ] && return 0
    local out
    out="$(box_run_v 'echo ok' 2>&1)"
    case "$out" in
        *ok*) TRANSPORT_ERR=""; return 0 ;;
    esac
    TRANSPORT_ERR="$out"
    return 1
}

# ---------------------------------------------------------------------------
# Ship the inspector to whichever machine holds the bundles and run it there.
#
# It is wrapped in single quotes for the remote shell, so the source may not
# contain one. Checked, not assumed: an unchecked assumption here fails as a
# remote syntax error, i.e. a reader that produces no reading, which is the
# family of defect this probe exists to remove.
# ---------------------------------------------------------------------------
inspect_paths() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then
        python3 "$INSPECTOR" "$@" 2>&1
        return $?
    fi

    local src args p
    src="$(cat "$INSPECTOR")"
    args=""
    for p in "$@"; do
        args="$args \"$p\""
    done
    box_run_v "python3 -c '$src' $args" 2>&1
}

# field <record-line> <key>  -> the value, or empty
field() {
    printf '%s\n' "$1" | tr '\t' '\n' | sed -n "s/^$2=//p" | head -1
}

# ---------------------------------------------------------------------------
# The seal itself. Two separate questions, reported separately: a bundle can
# verify and still be refused by Gatekeeper, and collapsing them hides which
# one the customer will hit.
# ---------------------------------------------------------------------------
codesign_report() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then
        codesign --verify --deep --strict "$1" 2>&1
        printf 'RC=%s\n' "$?"
        return 0
    fi
    box_run_v "codesign --verify --deep --strict \"$1\" 2>&1; echo RC=\$?" 2>&1
}

spctl_report() {
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then
        spctl -a -vv "$1" 2>&1
        printf 'RC=%s\n' "$?"
        return 0
    fi
    box_run_v "spctl -a -vv \"$1\" 2>&1; echo RC=\$?" 2>&1
}

rc_of() {
    printf '%s\n' "$1" | sed -n 's/^RC=//p' | tail -1
}

run_probe() {
    if [ ! -f "$INSPECTOR" ]; then
        probe_cannot_run "the reader itself is missing at $INSPECTOR, so nothing was inspected and no verdict below would mean anything"
    fi
    if grep -q "'" "$INSPECTOR"; then
        probe_cannot_run "$INSPECTOR contains a single-quote character, which would break the quoting that ships it to the box. Refusing to send a command that cannot parse rather than reporting the resulting silence as a reading."
    fi

    if ! transport_ok; then
        probe_cannot_run "cannot reach box ${OSTLER_BOX_HOST} over ssh, so NOTHING on it was inspected. Transport said: $(printf '%s' "$TRANSPORT_ERR" | tr '\n' ' ')"
    fi

    # ---------------------------------------------------------------------
    # POSITIVE CONTROL FIRST, on the box, not here. If codesign cannot
    # validate a bundle Apple ships, the tool or the environment is broken and
    # every subsequent verdict is worthless.
    # ---------------------------------------------------------------------
    local control control_rc
    control="$(codesign_report /System/Applications/Calculator.app)"
    control_rc="$(rc_of "$control")"
    if [ "${control_rc:-1}" != "0" ]; then
        probe_cannot_run "the control bundle (Calculator.app) did not verify on ${OSTLER_BOX_HOST:-this machine}, so codesign is not usable there and no seal verdict would mean anything. codesign said: $(printf '%s' "$control" | tr '\n' ' ' | cut -c1-300)"
    fi
    probe_note "control PASSED: codesign verifies Calculator.app on ${OSTLER_BOX_HOST:-this machine}, so the tool works"

    # ---------------------------------------------------------------------
    # THE READING. Printed in full, before any verdict, because the record of
    # what was inspected is the point.
    # ---------------------------------------------------------------------
    local report
    report="$(inspect_paths "$APP_1" "$APP_2" "$APP_3")"

    local total_line
    total_line="$(printf '%s\n' "$report" | grep '^TOTAL' | head -1)"
    if [ -z "$total_line" ]; then
        probe_cannot_run "the reader produced no TOTAL record, so nothing was inspected on ${OSTLER_BOX_HOST:-this machine}. Raw output: $(printf '%s' "$report" | tr '\n' ' ' | cut -c1-400)"
    fi

    printf '%s\n' "$report" | grep -E '^(HOST|CONTEXT)' | sed 's/^/  what this reader looked at: /'

    local present absent blind
    present="$(field "$total_line" present)"
    absent="$(field "$total_line" absent)"
    blind="$(field "$total_line" cannot_look)"

    local line state
    while IFS= read -r line; do
        case "$line" in PATH*) ;; *) continue ;; esac
        state="$(field "$line" state)"
        printf '  %-12s %s\n' "$state" "$(field "$line" resolved)"
        case "$state" in
            PRESENT)
                probe_note "    short=$(field "$line" short)  mtime=$(field "$line" mtime)  mode=$(field "$line" mode)  kind=$(field "$line" kind)"
                ;;
            ABSENT)
                probe_note "    errno=$(field "$line" errno) ($(field "$line" strerror)); proved by listing $(field "$line" listed) -- $(field "$line" entries) entries, component not among them"
                ;;
            *)
                probe_note "    errno=$(field "$line" errno) ($(field "$line" strerror)) at $(field "$line" denied_at); $(field "$line" proved_by)"
                ;;
        esac
    done <<< "$report"

    probe_examined 3 "declared bundle paths on ${OSTLER_BOX_HOST:-this machine} (${present} present, ${absent} absent, ${blind} could-not-look)"

    # ---------------------------------------------------------------------
    # A REFUSED READ IS NOT AN ABSENCE. This branch exists before the
    # zero-present branch on purpose: if any path could not be read, the
    # denominator is unknown and "nothing is installed" is not a finding this
    # probe is entitled to report.
    # ---------------------------------------------------------------------
    if [ "${blind:-0}" -gt 0 ]; then
        probe_cannot_run "${blind} of 3 bundle paths could not be READ on ${OSTLER_BOX_HOST:-this machine} (errno shown above). That is a refused read, not an absence, and this probe will not render it as one."
    fi

    if [ "${present:-0}" -eq 0 ]; then
        probe_cannot_run "no Ostler bundle exists on ${OSTLER_BOX_HOST:-this machine} -- absence PROVED by enumerating the parent, not inferred from a failed stat. This is NOT a pass: a box with nothing installed cannot demonstrate a good seal. If a bundle was expected here, the host named in the HOST record above is the thing to check first."
    fi

    # ---------------------------------------------------------------------
    # Only now, over the bundles that demonstrably exist.
    # ---------------------------------------------------------------------
    local failures=0 checked=0 app out rc seal gate
    while IFS= read -r line; do
        case "$line" in PATH*) ;; *) continue ;; esac
        [ "$(field "$line" state)" = "PRESENT" ] || continue
        app="$(field "$line" expanded)"
        checked=$((checked + 1))

        # --deep --strict is the one that notices resources added after
        # signing. A plain `codesign -dv` reads the signature and would still
        # say "signed".
        out="$(codesign_report "$app")"
        rc="$(rc_of "$out")"
        if [ "${rc:-1}" = "0" ]; then
            seal="intact"
        else
            seal="BROKEN"
            failures=$((failures + 1))
            probe_note "    codesign rc=${rc:-?}: $(printf '%s' "$out" | grep -v '^RC=' | head -3 | tr '\n' ' ')"
        fi

        out="$(spctl_report "$app")"
        rc="$(rc_of "$out")"
        if [ "${rc:-1}" = "0" ]; then
            gate="accepted"
        else
            gate="REJECTED"
            failures=$((failures + 1))
            probe_note "    spctl rc=${rc:-?}: $(printf '%s' "$out" | grep -v '^RC=' | head -3 | tr '\n' ' ')"
        fi

        printf '  seal=%-7s gatekeeper=%-9s %s\n' "$seal" "$gate" "$app"
    done <<< "$report"

    if [ "$failures" -gt 0 ]; then
        probe_fail "${failures} seal/Gatekeeper failure(s) across ${checked} installed bundle(s) on ${OSTLER_BOX_HOST:-this machine}. A bundle written into after signing is not notarised any more, whatever the pre-install checks said (#375 / CM051 #767)."
    fi

    probe_pass "${checked} installed bundle(s) on ${OSTLER_BOX_HOST:-this machine} still verify --deep --strict and are accepted by Gatekeeper"
}

# ===========================================================================
# NEGATIVE CONTROL
#
# Drives the REAL reader -- lib/bundle_inspect.py, the same file the live run
# ships to the box -- over a fixture holding one of each of the three outcomes.
# The control is not "does it return FAIL"; it is "does it keep the three
# outcomes apart", because the whole defect was two of them printing the same.
#
# Per this suite's inversion: probe_pass here means THE CONTROL DID NOT FIRE,
# which run_box_walk.sh reads as BROKEN and discards the probe's real result.
# probe_fail means the control behaved.
# ===========================================================================
self_test() {
    local fixture
    fixture="$(mktemp -d "${TMPDIR:-/tmp}/sealprobe.XXXXXX")"
    trap 'chmod 700 "$fixture/blocked" 2>/dev/null; rm -rf "$fixture"' EXIT
    SELF_TEST_LOCAL=1

    mkdir -p "$fixture/Present.app/Contents"
    cat > "$fixture/Present.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>0.0.0-fixture</string>
</dict></plist>
PLIST
    mkdir -p "$fixture/blocked/Blocked.app"

    # A directory with no permissions at all. root can traverse it anyway, so
    # as root this arm cannot be demonstrated -- and a control that cannot be
    # demonstrated is CANNOT-RUN, never a quiet pass.
    chmod 000 "$fixture/blocked"

    local report
    report="$(inspect_paths \
        "$fixture/Present.app" \
        "$fixture/Absent.app" \
        "$fixture/blocked/Blocked.app")"

    probe_examined 3 "fixture paths (negative control): one present, one absent, one unreadable"
    printf '%s\n' "$report" | grep -E '^(PATH|TOTAL)' | sed 's/^/    /'

    state_of() {
        printf '%s\n' "$report" | grep "^PATH.*requested=$1	" | head -1 \
            | tr '\t' '\n' | sed -n 's/^state=//p' | head -1
    }

    local s_present s_absent s_blind
    s_present="$(state_of "$fixture/Present.app")"
    s_absent="$(state_of "$fixture/Absent.app")"
    s_blind="$(state_of "$fixture/blocked/Blocked.app")"

    # POSITIVE ARM FIRST. Without it, a reader that answered CANNOT-LOOK to
    # everything would satisfy the negative arm and look correct.
    if [ "$s_present" != "PRESENT" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a bundle that is really there was read as '${s_present:-<no record>}'. This reader cannot see a present bundle, so none of its verdicts mean anything."
    fi

    if [ "$s_absent" != "ABSENT" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a genuinely missing bundle was read as '${s_absent:-<no record>}' instead of ABSENT."
    fi

    if [ "$(id -u)" = "0" ]; then
        probe_cannot_run "running as uid 0, which traverses a 000 directory regardless of its mode, so the could-not-look arm CANNOT be demonstrated here. The present/absent arms behaved, but this probe has not shown it can tell a refused read from an absence and must not be trusted on this box."
    fi

    # THE ARM THAT IS THE WHOLE POINT. A refused read must not come back as
    # absence -- that is v1.0.46 BOM row 6 in one assertion.
    if [ "$s_blind" != "CANNOT-LOOK" ]; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: a path behind a 000 directory came back as '${s_blind:-<no record>}'. A read this reader was REFUSED is being rendered as a fact about the filesystem. That is the defect in v1.0.46 BOM row 6 and it is live again."
    fi

    probe_fail "negative control behaved: PRESENT / ABSENT / CANNOT-LOOK stayed three distinct verdicts, the absence was proved by enumerating its parent, and the refused read reported EACCES instead of being called missing."
}

probe_main "$@"
