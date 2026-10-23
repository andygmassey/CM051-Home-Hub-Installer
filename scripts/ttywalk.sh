#!/usr/bin/env bash
#
# scripts/ttywalk.sh -- ONE COMMAND, ONE UNATTENDED INSTALL, ONE VERDICT.
#
# WHY THIS EXISTS. The v1.0.x loop has been: cut a DMG (~30 min) -> a human
# installs it (~1 h) -> it dies at step N -> fix ONE defect -> repeat. One walk,
# one defect. The bottleneck was never the fixing, it was the DISCOVERY RATE,
# and discovery was gated on a human being awake and at a keyboard.
#
# THE UNLOCK, measured not assumed:
#
#   lib/progress_emitter.sh gui_read() takes the GUI branch only when
#       OSTLER_GUI == 1  AND  OSTLER_GUI_FD is non-empty
#   and gui_emit() takes its early return only when
#       OSTLER_GUI != 1
#
# So OSTLER_GUI=1 with OSTLER_GUI_FD UNSET is a configuration the product does
# not ship but which is exactly what a harness wants:
#
#   - gui_emit is LIVE, so the terminal `#OSTLER DONE status=...` marker is
#     emitted (to stderr, since OSTLER_MARKER_FD is also unset) and lands in
#     the pty log. Without it the run is unadjudicable -- scripts/walk_drive.py
#     says so in its own FIX 2, and would correctly report CANNOT-RUN.
#   - gui_read still falls through to a plain `read` off the controlling
#     terminal, so walk_drive.py's reactive answer table can drive the whole
#     question phase.
#
# ⚠️ STATE THE LIMIT, EVERY TIME. THIS IS NOT A GUI WALK AND NEVER WILL BE.
# It exercises install.sh: ordering, branch logic, hangs, exit codes, missing
# files, error text. It is BLIND to GUI prompt rendering, the failure banner,
# TCC/FDA dialogs, Gatekeeper and stapling, and everything about the .app.
# Those still need one human walk. The point is to make that walk a
# CONFIRMATION rather than the place defects are discovered.
#
# 🔴 AN IP IS NOT AN IDENTITY. DHCP moved the walk box three times in five days.
# Every destructive step below is gated on a NAME + MODEL check, and the host
# is re-confirmed after staging, because staging takes minutes and a lease can
# move under you. Refusing is the correct outcome of an ambiguous identity.
#
# USAGE
#   scripts/ttywalk.sh --host andy@192.168.1.238 --expect-name "Andrew's Mac mini"
#
#   🚨 THE APOSTROPHE ABOVE IS A STRAIGHT ONE (U+0027). A real macOS
#   ComputerName usually contains a CURLY one (U+2019, bytes e2 80 99), so
#   copying this line verbatim can refuse with an IDENTITY MISMATCH whose two
#   quoted strings look identical. Deliberately NOT "fixed" by swapping in a
#   curly character here: that edit is invisible in review and just as easy to
#   retype wrongly. Read the name off the host once and paste THAT:
#       ssh <host> scutil --get ComputerName
#   If it still refuses, the die now prints both strings BYTE BY BYTE.
#
#   --expect-user <login> asserts WHICH ACCOUNT the walk runs as. The identity
#   round trip has always read `id -un`; until 2026-09-13 it only printed it,
#   so a walk pointed at the wrong account ran to completion. The probes read
#   the Hub user's 0600 files under ~/.ostler/secrets, and as another account
#   they degrade to CANNOT-RUN rather than FAIL, which is the quietest way for
#   a blocking probe to stop asserting anything.
#
#   scripts/ttywalk.sh --host ... --expect-name ... --reset      # cold box first
#
#   --reset IS A WIPE (v1.0.117 W4, approved by Archie: the launch directive
#   requires a cold box). It runs the shipped uninstaller, boots out every
#   Ostler job, deletes the colima VM WITH its data disk, and refuses the walk
#   (CANNOT-RUN) unless the box is then clean. --wipe-stores is retired; it is
#   accepted as an alias of --reset so old command lines keep working.
#   scripts/ttywalk.sh --host ... --expect-name ... --report-only # read last run
#
#   THE WALK RECORDS ITSELF. When the install reaches an adjudication this runs
#   scripts/record_walk.sh, which runs the probe suite and writes
#   walks/<version>.tsv -- the launch directive's deliverable, and the file
#   scripts/verify_walk_record.sh reads. Until 2026-09-23 nothing did, and two
#   walks on real hardware left no evidence any gate could read.
#
#   --no-record          skip it. ANNOUNCED, never silent. The probe suite
#                        writes to the live store, so a box mid-demo is a real
#                        reason to decline.
#   --no-early-pass      skip the EARLY PASS (read-only re-check of the previous
#                        walk's FAILED probes, run right after the install; see
#                        scripts/early_repeat_fail_pass.sh). ANNOUNCED. It never
#                        enters WALK_VERDICT or walks/.
#   --console "<who was at the console, when, what they granted>"
#                        record this as a CONSOLE walk. Without it the record
#                        says walk_kind=thin and does NOT authorise repointing
#                        the customer download. Reads OSTLER_CONSOLE_WALK too.
#
# EXIT CODES, and they are three not two:
#   0  PASS        install.sh reached its end and said so on the marker wire
#   1  FAIL        it did not, and we watched that happen
#   2  CANNOT-RUN  we were not in a position to find out
#
#   A PASS that could not be RECORDED becomes 2, not 0: nothing downstream can
#   read it, and a pass nobody can verify is absence of evidence. A FAIL is
#   never rewritten this way -- that would convert a found defect into a
#   missing measurement.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib_identity_lookalike.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_identity_lookalike.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib_walk_cm019_bundle.sh"
REMOTE_DIR="ostler-ttywalk"

PASS=0; FAIL=1; CANNOT_RUN=2

HOST=""
EXPECT_NAME=""
EXPECT_MODEL=""
# The third fact the identity round trip already collects. It was read and
# PRINTED and never asserted, so `--host someoneelse@box` ran happily. See
# identity_check() for why that matters more than it looks.
EXPECT_USER=""
DO_RESET=0
WIPE_STORES=0
REPORT_ONLY=0
STAGE_ONLY=0
# RECORDING IS THE DEFAULT, AND THAT IS THE FIX. The walk record is the launch
# directive's deliverable, scripts/post_walk_qa.sh has written it correctly
# since 2026-08-21, and until 2026-09-23 NOTHING CALLED IT: measured on
# origin/main, 0 executable invocations outside tests/, against a control of 8
# inside it. Two walks ran on real hardware on 2026-09-23 and recorded nothing.
# An opt-in would have reproduced that, because the thing being forgotten was
# the second command.
#
# --no-record exists because the probe suite WRITES (it seeds a synthetic
# person into the LIVE store, #829), so a box mid-demo is a real reason to
# decline. Declining is ANNOUNCED, never silent.
NO_RECORD=0
# The early repeat-failure pass (scripts/early_repeat_fail_pass.sh) runs by
# default, right after the install finishes. It is read-only, labelled, and
# never reaches WALK_VERDICT or walks/. --no-early-pass declines it, announced.
NO_EARLY_PASS=0
CONSOLE_WALK="${OSTLER_CONSOLE_WALK:-}"

die() { printf 'CANNOT-RUN: %s\n' "$*" >&2; exit "$CANNOT_RUN"; }
say() { printf '%s\n' "$*"; }
rule() { printf -- '---- %s ----\n' "$*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)         HOST="${2:-}"; shift 2 ;;
        --expect-name)  EXPECT_NAME="${2:-}"; shift 2 ;;
        --expect-model) EXPECT_MODEL="${2:-}"; shift 2 ;;
        --expect-user)  EXPECT_USER="${2:-}"; shift 2 ;;
        --reset)        DO_RESET=1; shift ;;
        --wipe-stores)  WIPE_STORES=1; DO_RESET=1; shift ;;
        --report-only)  REPORT_ONLY=1; shift ;;
        --stage-only)   STAGE_ONLY=1; shift ;;
        --no-record)    NO_RECORD=1; shift ;;
        --no-early-pass) NO_EARLY_PASS=1; shift ;;
        --console)      CONSOLE_WALK="${2:-}"; shift 2 ;;
        --from-dmg)     FROM_DMG="${2:-}"; shift 2 ;;
        -h|--help)      sed -n '2,90p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)              die "unknown argument: $1" ;;
    esac
done

[[ -n "$HOST" ]] || die "--host is required (user@host)"

# ARGUMENT-TIME, NOT SSH-TIME. Placed here deliberately: the first draft sat
# beside the wipe block, so `--wipe-stores` without `--reset` died on the ssh
# reachability probe instead, reporting "cannot reach <host>" for a usage error
# that has nothing to do with the network. A CANNOT-RUN with the wrong REASON
# is barely better than a wrong verdict: it sends the next person to the wrong
# problem.
if [[ "$WIPE_STORES" -eq 1 ]]; then
    say "--wipe-stores is retired: --reset now deletes the VM with its data disk, which removes every store. Treating it as --reset."
fi

SSH=(ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST")

# ── Identity, by NAME, before anything else ──────────────────────────
#
# Read all three facts in ONE round trip so they cannot describe different
# machines, which is the failure a second ssh call would invite.
identity_check() {
    local when="$1" ident name model user
    ident="$("${SSH[@]}" 'printf "%s\n%s\n%s\n" "$(scutil --get ComputerName)" "$(sysctl -n hw.model)" "$(id -un)"' 2>&1)" \
        || die "cannot reach ${HOST} (${when}): ${ident}"

    name="$(printf '%s' "$ident"  | sed -n 1p)"
    model="$(printf '%s' "$ident" | sed -n 2p)"
    user="$(printf '%s' "$ident"  | sed -n 3p)"

    [[ -n "$name" ]] || die "the host answered with an EMPTY ComputerName (${when}).
       An empty string matches nothing and must never be read as a match."

    if [[ -n "$EXPECT_NAME" && "$name" != "$EXPECT_NAME" ]]; then
        die "IDENTITY MISMATCH (${when}). Expected ComputerName '${EXPECT_NAME}',
       the host at ${HOST} answers '${name}'. DHCP moves this address.
       Refusing rather than acting on the wrong machine.
$(identity_mismatch_hint "$EXPECT_NAME" "$name")"
    fi
    if [[ -n "$EXPECT_MODEL" && "$model" != "$EXPECT_MODEL" ]]; then
        die "IDENTITY MISMATCH (${when}). Expected hw.model '${EXPECT_MODEL}',
       got '${model}'.
$(identity_mismatch_hint "$EXPECT_MODEL" "$model")"
    fi
    # THE THIRD FACT WAS COLLECTED, PRINTED, AND ASSERTED ON BY NOBODY.
    #
    # The round trip has always read `id -un`, and the say() below has always
    # printed it, but nothing compared it to anything. So
    # `--host someoneelse@box` ran the whole walk as the wrong account and the
    # only trace was one line in a log.
    #
    # That is not a hypothetical on this harness. people_count_agreement
    # already reads ~/.ostler/secrets/store-curl.conf on every walk and passes,
    # which is the behavioural proof that the walk runs as an account that can
    # read the Hub user's 0600 secrets. Run it as a DIFFERENT account and that
    # path does not resolve: the probe degrades to CANNOT-RUN rather than
    # failing, and a blocking probe that cannot run is invisible in exactly the
    # way a passing one is quiet.
    #
    # Same shape as the two arms above, including the empty-answer guard: an
    # empty string matches nothing and must never be read as a match.
    if [[ -n "$EXPECT_USER" ]]; then
        [[ -n "$user" ]] || die "the host answered with an EMPTY login name (${when}).
       An empty string matches nothing and must never be read as a match."
        if [[ "$user" != "$EXPECT_USER" ]]; then
            die "IDENTITY MISMATCH (${when}). Expected to be running as '${EXPECT_USER}',
       the host at ${HOST} answers '${user}'. The probes read the Hub user's
       0600 files under ~/.ostler/secrets; as another account they degrade to
       CANNOT-RUN, which is not a FAIL and is not a PASS.
$(identity_mismatch_hint "$EXPECT_USER" "$user")"
        fi
    fi

    say "identity ${when}: ${name} / ${model} (as ${user})"
}

# ── The report. Read the LOG, adjudicate on the MARKER ───────────────
#
# Everything printed here is quoted from the run's own output. Nothing is
# inferred. A section that finds nothing prints its zero WITH the denominator
# it searched, because "found nothing" and "could not look" print identically
# and only one of them is evidence.
report() {
    local log="$1"
    rule "REPORT"

    local bytes
    bytes="$("${SSH[@]}" "wc -c < '$log' 2>/dev/null || echo 0" | tr -d ' ')"
    if [[ "${bytes:-0}" -eq 0 ]]; then
        say "the pty log ${log} is EMPTY or absent (${bytes:-0} bytes)."
        say "That is CANNOT-RUN: there is nothing to adjudicate."
        return "$CANNOT_RUN"
    fi
    say "pty log: ${log} (${bytes} bytes)"

    # A single remote pass over the log. Each limb prints its own count so a
    # zero is always accompanied by the denominator that produced it.
    "${SSH[@]}" "LOG='$log'; python3 - \"\$LOG\" <<'PY'
import re, sys
raw = open(sys.argv[1], 'rb').read()
txt = re.sub(rb'\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07', b'', raw)
lines = txt.decode('utf-8', 'replace').splitlines()
print('lines examined: %d' % len(lines))

def show(label, pat, cap=12):
    rx = re.compile(pat)
    hits = [l.strip() for l in lines if rx.search(l)]
    print('')
    print('%s: %d' % (label, len(hits)))
    for h in hits[:cap]:
        print('    ' + h[:200])
    if len(hits) > cap:
        print('    ... and %d more' % (len(hits) - cap))

# Furthest progress reached, read off the marker wire itself.
steps = [l for l in lines if 'STEP_BEGIN' in l]
print('')
print('STEP_BEGIN markers: %d' % len(steps))
if steps:
    print('    first: ' + steps[0].strip()[:200])
    print('    LAST:  ' + steps[-1].strip()[:200])
else:
    print('    none. Either the marker channel was off, or install.sh never')
    print('    reached its first step. Those are different findings.')

# 🔴 THIS COUNTED ONLY status=error AND SO REPORTED A TIMED-OUT STEP AS ZERO
# FAILURES. MEASURED on walk 13: the run ended DONE status=ok failed_steps=1,
# this line printed 'status=error steps: 0', and the step that actually failed
# was STEP_END id=health_check status=timeout rc=124.
# 'status=error steps: 0' is TRUE and it reads as "nothing failed". The
#
# NO BACKTICKS IN THIS BLOCK. It sits inside a DOUBLE-QUOTED ssh argument, so
# the LOCAL shell command-substitutes anything between backticks before the
# payload is ever sent. The first version of this comment used them for the
# marker names and walk 15 printed:
#     ttywalk.sh: line 133: DONE: command not found
#     ttywalk.sh: line 133: steps:: command not found
#     ttywalk.sh: line 133: STEP_END: command not found
# Those are MY COMMENT TEXT being executed. It was harmless only because the
# words happened not to be commands.
# installer's own vocabulary has more than one way to fail a step, so the
# predicate has to be "not ok" rather than a list of the failure words I
# happened to think of.
show('STEP_END not status=ok',    r'STEP_END(?!.*status=ok)')
show('  of which status=error',   r'STEP_END.*status=error')
show('  of which status=timeout', r'STEP_END.*status=timeout')
# #2318: without this row the 'of which' lines stop summing to the headline,
# because the unmeasured state is not-ok and is neither failure word.
# A breakdown that does not add up sends the reader hunting for a failure
# that is not there. An unmeasured step is NOT a failure: it is the count of
# steps that recorded no outcome, and it is the instrumentation debt, not a
# defect on the box.
# NO BACKTICKS IN THIS BLOCK. It sits inside a double-quoted ssh payload, so
# the LOCAL shell would execute whatever sat between them before the payload
# was ever sent. The repo gate that enforces this caught exactly that here.
show('  of which status=unmeasured (no outcome recorded; NOT a failure)',
                                  r'STEP_END.*status=unmeasured')
show('ERR-NN codes',              r'ERR-\d+-')
show('Python tracebacks',         r'Traceback \(most recent call last\)')
show('TERMINAL DONE markers',     r'#OSTLER\s+DONE\s')
show('abort / fatal lines',       r'(?i)\b(fatal|aborting|aborted)\b', 8)
PY" 2>&1

    # 🔴 THIS SECTION PRINTED THE RAW EXIT CODE UNDER THE WORD "VERDICT" AND SO
    # REPORTED A FAILED WALK AS 0. MEASURED on walk 11: install.sh reached its
    # end and exited 0, so .walk-rc held 0 and this heading published it as the
    # adjudication, while walk_drive.py had already concluded FAIL over three
    # failed steps. The driver's own comment says .walk-rc is "EVIDENCE ... not
    # the verdict"; the harness printing it was the part that disagreed.
    #
    # Both numbers are printed now, because they answer different questions and
    # a disagreement between them is itself a finding.
    rule "EXIT CODE install.sh RETURNED (evidence, not a verdict)"
    "${SSH[@]}" "cd '${REMOTE_DIR}' 2>/dev/null && python3 scripts/walk_drive.py --read-result 2>&1 || echo 'no exit code recorded'"
    rule "VERDICT (walk_drive.py's own adjudication)"
    WALK_VERDICT="$("${SSH[@]}" "cd '${REMOTE_DIR}' 2>/dev/null && python3 scripts/walk_drive.py --read-verdict 2>/dev/null" | tr -d '[:space:]')"
    case "$WALK_VERDICT" in
        0) say "0  PASS" ;;
        1) say "1  FAIL" ;;
        2) say "2  CANNOT-RUN" ;;
        *) say "UNREADABLE verdict [${WALK_VERDICT}] -- treating as CANNOT-RUN."
           say "A verdict that cannot be read has not passed."
           WALK_VERDICT="$CANNOT_RUN" ;;
    esac
    return 0
}

if [[ "$REPORT_ONLY" -eq 1 ]]; then
    identity_check "at report"
    LOG="$("${SSH[@]}" 'cat ~/.walk-log 2>/dev/null')"
    [[ -n "$LOG" ]] || die "~/.walk-log is absent on the host: no previous run to report on."
    report "$LOG"
    exit $?
fi

identity_check "before staging"

# ── LICENCE PREFLIGHT ────────────────────────────────────────────────
#
# 🔴 THIS COST A RUN, AND IT WOULD HAVE COST A RESET. MEASURED 2026-09-04 on
# the first walk of a brand-new macOS account: the harness identity-checked,
# rsynced the whole tree, flattened 15 payload directories, wrote its config,
# started the install, and 32 seconds later got
#
#     [fail]  [ERR-02-LICENCE-REQUIRED] Licence check failed: No licence file found.
#
# The product was RIGHT and the harness was late. install.sh reads exactly one
# path, ${HOME}/.ostler/license/license.json (install.sh:1874), and a fresh
# account has no such file -- which is the normal state of the cold accounts
# this harness exists to walk. Nothing told the operator that before the run.
#
# WHY IT SITS ABOVE --reset AND NOT BELOW IT. --reset runs the shipped
# uninstaller on the target account. Discovering an unstartable walk AFTER
# tearing a box down means the reset was spent for nothing, and on a box
# somebody cared about that is worse than a wasted half hour.
#
# THE CHECK IS ON THE TARGET ACCOUNT, NOT THIS ONE. The whole class of defect
# behind this harness is permission-scoped state read from the wrong account:
# `lsof` cannot see another user's sockets, and this operator account cannot
# see another user's home. Asking the box, as the user being walked, is the
# only question worth asking.
#
# A MISSING LICENCE IS CANNOT-RUN, NOT FAIL. The build under test has not been
# shown to be bad; the harness was not given what it needs. Conflating the two
# is how a setup gap gets filed as a product defect.
# ── BUNDLED-PYTHON PREFLIGHT ─────────────────────────────────────────
#
# 🔴 A MISSING BUILD PRODUCT DOES NOT JUST REMOVE FILES, IT CHANGES WHICH
# CODE PATH THE INSTALL TAKES, AND THAT IS FAR WORSE.
#
# MEASURED 2026-09-04, on the second walk of a cold account. The run died at
#
#     [ERR-05-HOMEBREW-PYTHON-INSTALL] Could not install Python 3.11 via Homebrew
#
# and it looked exactly like a product defect. It is not one. install.sh:7035
# reads ${SCRIPT_DIR}/python/bin/python3.11 and takes the bundled interpreter
# when it is executable; the `brew install python@3.11` arm below it is, in
# the file's own words, a "Dev mode fallback ... hit only when install.sh runs
# from a developer's HR015 sibling-clone, not from the customer-facing signed
# .app (which always has ${SCRIPT_DIR}/python/bin/python3.11 bundled)".
#
# THE CONTROL THAT SETTLED IT:
#
#     DMG   Contents/Resources/python/bin/python3.11   present, 3.11.15, 17.6 MB
#     repo  python/bin/python3.11                      DOES NOT EXIST
#
# So the harness walked a branch no customer ever runs and produced a red that
# said nothing about the build. That is not a wasted run, it is a MISLEADING
# one, and this file already carries the same warning for hub-power,
# email-ingest and imessage-bridge -- but those only change which FILES exist.
# This one changes the interpreter the whole install is built on.
#
# REFUSING IS THE RIGHT OUTCOME, not warning. The purpose of this harness is
# to produce a verdict about the product, and a verdict from the dev-mode
# branch is not one. CANNOT-RUN, never FAIL: nothing about the build has been
# shown to be wrong.
STAGE_SRC="$REPO_ROOT"
STAGE_KIND="repo"
DMG_MNT=""
if [[ -n "${FROM_DMG:-}" ]]; then
    [[ -f "$FROM_DMG" ]] || die "--from-dmg: no file at ${FROM_DMG}"
    DMG_MNT="$(mktemp -d "${TMPDIR:-/tmp}/ostler-dmg.XXXXXX")" \
        || die "--from-dmg: could not make a mountpoint"
    hdiutil attach -nobrowse -readonly -mountpoint "$DMG_MNT" "$FROM_DMG" >/dev/null 2>&1 \
        || die "--from-dmg: hdiutil attach failed for ${FROM_DMG}"
    # Detach on the way out however we leave, so a later run does not meet
    # "Resource busy" -- the v1.0.51 failure, one artefact over.
    trap 'hdiutil detach "$DMG_MNT" -quiet 2>/dev/null || hdiutil detach "$DMG_MNT" -force -quiet 2>/dev/null || true' EXIT
    _res="$(/usr/bin/find "$DMG_MNT" -maxdepth 3 -type d -name Resources -path '*.app/Contents/*' 2>/dev/null | head -1)"
    [[ -n "$_res" ]] || die "--from-dmg: no <app>/Contents/Resources inside ${FROM_DMG}"
    [[ -f "${_res}/install.sh" ]] \
        || die "--from-dmg: ${_res} has no install.sh. That is not the payload root."
    STAGE_SRC="$_res"
    STAGE_KIND="artefact"
    # Every probe on this run (the preference seed runs on the DRIVER) finds
    # the artefact's cm019 bundle through this, not by guessing a path.
    walk_export_cm019_bundle "$_res" || true
    # THE VERSION OF THE INSTALLER THAT IS ABOUT TO RUN, read from the bundle
    # this walk actually mounts.
    #
    # 🔴 WHY THIS EXISTS. post_walk_qa.sh records `version` from
    # /Applications/OstlerInstaller.app, and its own comment says the field
    # means "which installer RAN". On an ARTEFACT walk nothing is ever dragged
    # to /Applications -- the install.sh inside the DMG is run in place -- so
    # that path holds whatever some EARLIER run left behind.
    #
    # MEASURED 2026-09-04 after the v1.0.66 artefact walk went green: the box
    # held /Applications/OstlerInstaller.app at 1.0.63 from a run 13 hours
    # earlier, so the gate refused to write a walk record for a version it
    # said the box "says". The DMG's own app was correctly stamped 1.0.66/6600.
    # The stale app was not wrong about itself; it was answering a question
    # nobody asked.
    #
    # Left unfixed this is permanent: NO artefact walk could ever produce a
    # walk record, and the walk record is what gates promoting a release.
    # 🔴 TWO BUGS LIVED IN THIS ONE LINE AND THEY HID EACH OTHER. Measured
    # 2026-09-05 against the real v1.0.67 DMG:
    #
    #   1. ONE dirname TOO MANY. $_res is <app>/Contents/Resources, so two
    #      dirnames give <app>/Info.plist -- which does not exist. Info.plist
    #      is at <app>/Contents/Info.plist. One dirname.
    #
    #   2. PlistBuddy WRITES ITS ERROR TO STDOUT, NOT STDERR. So `2>/dev/null`
    #      suppressed nothing: its "file does not exist, will create"
    #      diagnostic landed in the variable, and `[[ -n ]]` PASSED on a
    #      failure. The walk then announced
    #      `version: FileDoesn'tExist,WillCreate:/private/var/...` as though it
    #      had succeeded, and wrote that into ~/.walk-artefact-version.
    #
    # Bug 2 is why bug 1 survived: a non-empty check cannot see a failure that
    # answers on stdout. post_walk_qa caught it downstream and REFUSED to write
    # the record -- correctly -- which is the only reason it was found at all.
    #
    # The guard below therefore tests the SHAPE, not merely emptiness. A
    # version is digits and dots; anything else is a diagnostic wearing a
    # value's clothes.
    # NOT `local`: this block is TOP-LEVEL script, not a function body. `local`
    # parses fine and dies at RUNTIME with "can only be used in a function",
    # and under `set -u` the unset name then trips unbound-variable. Caught by
    # RUNNING it -- `bash -n` is a parse, not an execution, and it passed.
    _ARTEFACT_PLIST="$(dirname "$_res")/Info.plist"
    ARTEFACT_VERSION=""
    if [[ -f "$_ARTEFACT_PLIST" ]]; then
        ARTEFACT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            "$_ARTEFACT_PLIST" 2>/dev/null | tr -d '[:space:]')"
        [[ "$ARTEFACT_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || ARTEFACT_VERSION=""
    fi
    if [[ -n "$ARTEFACT_VERSION" ]]; then
        say "   version: ${ARTEFACT_VERSION}  (read from the mounted bundle)"
    else
        say "   ⚠️  could not read CFBundleShortVersionString from the mounted bundle."
        say "      The walk still runs; the record will fall back to /Applications,"
        say "      which on an artefact walk is whatever an earlier run left."
    fi
    say "ARTEFACT WALK. Staging the DMG's payload, not this checkout."
    say "   dmg:     ${FROM_DMG}"
    say "   payload: ${_res}"
    say "   ⚠️  the .app is NOT launched. This runs the install.sh INSIDE it,"
    say "      so it still says nothing about first-RUN behaviour of the bundle."
fi

rule "BUNDLED-PYTHON PREFLIGHT (the customer path, not the dev fallback)"
# READ FROM THE STAGED SOURCE, not the checkout. In --from-dmg mode the
# interpreter lives inside the artefact, and checking $REPO_ROOT there made
# the first artefact walk refuse CANNOT-RUN against a DMG that HAS one.
# ${STAGE_SRC:-$REPO_ROOT}, not ${STAGE_SRC}: tests/test_ttywalk_licence_preflight_is_cannot_run.sh
# EXTRACTS this block and drives it in isolation, where STAGE_SRC does not exist.
# A bare ${STAGE_SRC} under `set -u` made all three of its interpreter arms exit
# 1, so a change that only added an artefact mode blinded a guard that was
# already working. The default keeps the extracted block self-sufficient and
# changes nothing at runtime, where STAGE_SRC is always set above.
BUNDLED_PY_LOCAL="${STAGE_SRC:-$REPO_ROOT}/python/bin/python3.11"
if [[ -x "$BUNDLED_PY_LOCAL" ]]; then
    say "bundled interpreter present: $("$BUNDLED_PY_LOCAL" --version 2>&1 | head -1)"
else
    printf '%s\n' "CANNOT-RUN: no bundled interpreter at ${BUNDLED_PY_LOCAL}" >&2
    printf '%s\n' "" >&2
    printf '%s\n' "  install.sh takes the BUNDLED python when that file is executable and" >&2
    printf '%s\n' "  falls back to 'brew install python@3.11' when it is not. The signed" >&2
    printf '%s\n' "  .app always ships it, so the fallback is a DEV-ONLY branch that no" >&2
    printf '%s\n' "  customer reaches. Walking without it does not merely skip a file, it" >&2
    printf '%s\n' "  runs the whole install on a DIFFERENT interpreter path, and any red it" >&2
    printf '%s\n' "  produces says nothing about the build." >&2
    printf '%s\n' "" >&2
    printf '%s\n' "  It is a build product, so it is absent from the repo by design. Take it" >&2
    printf '%s\n' "  from the cut you are walking:" >&2
    printf '%s\n' "" >&2
    printf '%s\n' "      hdiutil attach -nobrowse -readonly <the>.dmg" >&2
    printf '%s\n' "      cp -R \"/Volumes/Install Ostler/OstlerInstaller.app/Contents/Resources/python\" \\" >&2
    printf '%s\n' "            \"${REPO_ROOT}/python\"" >&2
    printf '%s\n' "      hdiutil detach \"/Volumes/Install Ostler\"" >&2
    printf '%s\n' "" >&2
    printf '%s\n' "  Take it from the DMG you intend to ship, not from any other build: the" >&2
    printf '%s\n' "  interpreter is part of the artefact." >&2
    exit 2
fi

# ── SUDO PREFLIGHT ───────────────────────────────────────────────────
#
# 🔴 THIS COST 25 MINUTES AND 14 OF 41 STEPS. MEASURED 2026-09-04, walk 4 of
# v1.0.65 on a cold account:
#
#     sudo: 3 incorrect password attempts
#     Install aborted unexpectedly at line 17980 (step cm048_setup):
#         sudo ln -sf "$CM048_BIN" "$CM048_SYMLINK"
#     #OSTLER DONE status=fail code=ERR-99-INSTALL-ABORT-L17980
#
# install.sh has a sudo pre-flight that refuses cleanly with
# ERR-04-SUDO-DENIED, but it is SKIPPED under OSTLER_GUI=1 -- "parent .app has
# pre-handled root operations" -- and OSTLER_GUI=1 is exactly the mode this
# harness runs in. There is no .app here to answer the password prompt, so the
# first `sudo` that is not already authorised kills the run at whatever line it
# happens to be on.
#
# ⚠️ AND THE PRODUCT IS NOT WRONG TO SKIP IT. I nearly "fixed" install.sh to
# demand `sudo -n true` before trusting GUI mode. THE CONTROL REFUTED IT:
#
#     Andy's real v1.0.63 GUI install   cm048_setup  status=ok elapsed_s=8
#     the same skip line in his log     line 59
#     `sudo -n true` as him, today      FAILS, a password is required
#
# So `sudo -n` fails on a real box whose install SUCCEEDS, because the .app
# answers the prompt interactively. Demanding `sudo -n` would have emitted a
# false ERR-04 on every real GUI install. The gap is the harness's, and the
# harness is where it gets reported.
#
# WARN, DO NOT REFUSE. Unlike the licence and the interpreter, a walk without
# sudo still produces 14 steps of real evidence, and that is worth having. What
# is not acceptable is discovering the limit at minute 25 with a red that names
# a symlink.
rule "SUDO PREFLIGHT (the harness has no .app to answer a password prompt)"
if "${SSH[@]}" 'sudo -n true' >/dev/null 2>&1; then
    say "passwordless sudo available on ${HOST%%@*}: the install can complete"
else
    say ""
    say "⚠️  NO PASSWORDLESS SUDO on ${HOST%%@*}."
    say ""
    say "    install.sh skips its own sudo gate under OSTLER_GUI=1, which is the"
    say "    mode this harness runs in, so the FIRST unauthorised sudo will abort"
    say "    the run at whatever line it lands on. Measured: v1.0.65 died at"
    say "    line 17980 (cm048_setup) after 14 of 41 steps."
    say ""
    say "    This walk WILL still produce evidence up to that point. It will NOT"
    say "    reach the end, and its red will name a symlink rather than the cause."
    say ""
    say "    To let it complete, grant the WALK ACCOUNT ONLY passwordless sudo:"
    say "        echo '<walk-user> ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/ostler-walk"
    say "        sudo chmod 440 /etc/sudoers.d/ostler-walk && sudo visudo -c"
    say ""
fi

rule "LICENCE PREFLIGHT (on the target account, before anything is staged)"
lic_state="$("${SSH[@]}" 'if [[ -s "${HOME}/.ostler/license/license.json" ]]; then
                              echo "present $(stat -f %z "${HOME}/.ostler/license/license.json") bytes"
                          elif [[ -e "${HOME}/.ostler/license/license.json" ]]; then
                              echo "empty"
                          else
                              echo "absent"
                          fi' 2>/dev/null)" || lic_state="unreadable"
case "$lic_state" in
    present*)
        say "licence present on ${HOST%%@*}: ${lic_state#present }"
        ;;
    empty)
        printf '%s\n' "CANNOT-RUN: the licence file exists on ${HOST} but is EMPTY." >&2
        printf '%s\n' "  install.sh will refuse with ERR-02-LICENCE-REQUIRED. A zero-byte" >&2
        printf '%s\n' "  licence is not a licence; replace it before walking." >&2
        exit 2
        ;;
    absent)
        printf '%s\n' "CANNOT-RUN: no licence on ${HOST} at ~/.ostler/license/license.json" >&2
        printf '%s\n' "" >&2
        printf '%s\n' "  install.sh reads exactly that path and refuses without it, so this" >&2
        printf '%s\n' "  walk would stage the whole tree and then die in about 30 seconds." >&2
        printf '%s\n' "  That is a SETUP gap, not a verdict on the build." >&2
        printf '%s\n' "" >&2
        printf '%s\n' "  A brand-new account never has one. Put the licence in place as the" >&2
        printf '%s\n' "  account being walked, then re-run:" >&2
        printf '%s\n' "" >&2
        printf '%s\n' "      mkdir -p ~/.ostler/license" >&2
        printf '%s\n' "      cp <licence json> ~/.ostler/license/license.json" >&2
        printf '%s\n' "      chmod 600 ~/.ostler/license/license.json" >&2
        exit 2
        ;;
    *)
        printf '%s\n' "CANNOT-RUN: could not read the licence state on ${HOST} (got '${lic_state}')." >&2
        printf '%s\n' "  Not knowing is not the same as knowing it is absent, and neither is" >&2
        printf '%s\n' "  a reason to spend a walk." >&2
        exit 2
        ;;
esac

# ── Reset ────────────────────────────────────────────────────────────
#
# A TTY reset is NOT a wipe. It runs the SHIPPED uninstaller, which is itself
# part of what we are testing, and then reports what is still holding a port.
# Anything that genuinely needs a virgin box is CANNOT-RUN here and must be
# said so out loud rather than approximated.
# ── The old --wipe-stores block is retired (v1.0.117 W4) ─────────────────
# It dumped the graph, ran the uninstaller and counted docker volumes. The reset
# below now deletes the colima VM WITH its data disk (colima delete --data) and
# asserts the disk is gone, which removes every store whatever the uninstaller
# did, so a separate opt-in wipe only duplicated it. On the cold box the launch
# directive walks there is no graph to dump. The flag remains an alias.


if [[ "$DO_RESET" -eq 1 ]]; then
    rule "RESET (uninstall + bootout + VM and data disk delete + port check)"
    if ! "${SSH[@]}" 'set -u
        # v1.0.117 W4 (Archie review): EVERY check below that finds the box not
        # clean adds a reason here, and the block ends CANNOT-RUN if any is set.
        # The reset still runs every step first, so the box gets as clean as it
        # can before the refusal.
        _reset_fail=""
        _df_kb() { df -k "$HOME" 2>/dev/null | awk "NR==2{print \$4}"; }
        _df_before="$(_df_kb)"
        echo "free space before the reset: ${_df_before:-unknown} KB available on the home volume"
        _ran_uninstaller=""
        _u_rc=""
        for u in ~/.ostler/bin/ostler-uninstall \
                 ~/Applications/Ostler.app/Contents/Resources/uninstall.sh \
                 /Applications/Ostler.app/Contents/Resources/uninstall.sh \
                 ~/.ostler/uninstall.sh; do
            if [[ -x "$u" ]]; then
                echo "running shipped uninstaller: $u"
                # CAPTURE, THEN PRINT, so the rc is the uninstaller and not tail.
                _u_out="$(OSTLER_UNINSTALL_ASSUME_YES=1 bash "$u" 2>&1)" && _u_rc=0 || _u_rc=$?
                echo "$_u_out" | tail -25
                echo "uninstaller rc=${_u_rc}"
                _ran_uninstaller="$u"
                if [[ "$_u_rc" != "0" ]]; then
                    _reset_fail="${_reset_fail} uninstaller-rc-${_u_rc}"
                fi
                break
            fi
        done
        # A LOOP THAT MATCHES NOTHING MUST SAY SO. It used to fall through in
        # silence, and the run then read as "reset done" when no uninstall had
        # happened. Measured 2026-09-05 against CM051 origin/main: install.sh
        # writes exactly ONE uninstaller, ~/.ostler/bin/ostler-uninstall
        # (install.sh:19984, chmod at :20395), and a repo-wide find for
        # uninstall*.sh returns NOTHING -- so all three paths above name a file
        # this repo never produces, on a box installed from this DMG.
        #
        # NOTE: NO APOSTROPHES ANYWHERE IN THIS BLOCK. The whole body is passed
        # to ssh inside a SINGLE-QUOTED shell string, so one typed apostrophe
        # closes it and bash -n dies at EOF. Measured: it happened writing this.
        #
        # v1.0.117 THIN WALK, W4: bin/ostler-uninstall IS NOW FIRST IN THE LIST.
        # This block used to leave it out on purpose, because that uninstaller
        # runs docker compose down -v and a 2026-09 investigation needed the
        # stores kept. That left the installed assistant (KeepAlive) loaded: it
        # restarted colima 22s after the VM delete, held all six store ports,
        # and walk attempt 1 was CANNOT-RUN. The shipped uninstaller is the one
        # thing that knows every job it installed, writes the deliberate-stop
        # marker first, and keeps the licence (install.sh, its find excludes
        # license/). CONSEQUENCE, stated: a plain --reset on a box whose VM is
        # up now removes the store volumes, and the provenance line below says
        # wiped-by-shipped-uninstaller. On the cold box the launch directive
        # walks, the VM is already gone and there is nothing to remove.
        if [[ -z "$_ran_uninstaller" ]]; then
            echo "NO SHIPPED UNINSTALLER FOUND. This reset did NOT uninstall."
            echo "  searched: ~/.ostler/bin/ostler-uninstall"
            echo "            ~/Applications/Ostler.app/Contents/Resources/uninstall.sh"
            echo "            /Applications/Ostler.app/Contents/Resources/uninstall.sh"
            echo "            ~/.ostler/uninstall.sh"
            echo "  The store volumes are still removed below, by colima delete --data (the VM"
            echo "  and its data disk). Nothing is carried over; the provenance line says so."
        fi
        # #1828 config-only teardown. With no shipped uninstaller present the box
        # keeps its previous ~/.ostler config, so the next install skips its
        # interactive setup (the reuse gate at install.sh:5214 keys on
        # ~/.ostler/config/.env holding USER_ID) and every probe measures
        # carried-over state. Remove ONLY the host config that gates setup:
        # config (the previous-answers .env), security (the keychain.json FILE,
        # not the macOS Keychain), assistant-config (memory/brain.db, the poisoned
        # count rows that made grounded measure history), and imports
        # (icloud-contacts.vcf, the prior-export marker read below the reuse gate).
        # Leave the container store
        # volumes untouched -- whether to wipe those stays the operators
        # --wipe-stores decision, exactly as the announcement above preserves.
        if [[ -z "$_ran_uninstaller" ]]; then
            echo "config-only teardown (#1828): clearing host config so the next install is a fresh setup"
            for _cfg in ~/.ostler/config ~/.ostler/security ~/.ostler/assistant-config ~/.ostler/imports ~/.ostler/active_workspace.toml; do
                if [[ -e "$_cfg" ]]; then
                    echo "  removing $_cfg"
                    rm -rf "$_cfg"
                fi
            done
            echo "  store volumes (qdrant/oxigraph/redis/wiki/vane): removed below with the colima data disk"
        fi
        # RECORDED BELOW THE ANNOUNCEMENT, NOT ABOVE IT. The honesty gate for
        # this block extracts it with an awk RANGE that ends at the first
        # "        fi", so an `if` placed earlier truncates the extraction and
        # the gate reports the announcement missing. Measured: two assertions
        # went red on a block that had been cut in half.
        # RECORD IT WHERE THE RECORD CAN READ IT. This block already SAYS the
        # stores are carried over; nothing downstream repeated it, so a probe
        # reading the graph could fail on history and the walk record would
        # present that as evidence about the DMG. Written to a run file that the
        # config step below consumes, so a value can never be stale.
        # NO APOSTROPHES IN THIS BLOCK: the whole body is a single-quoted ssh
        # string and one typed apostrophe closes it.
        # DO NOT OVERWRITE A WIPE. The --wipe-stores block runs earlier, in its
        # own ssh session, and records the stronger fact with a measured volume
        # count behind it. This arm only speaks when nothing has spoken already.
        # Stop the container VM. A previous install leaves colima running, and
        # colima publishes the container ports through an ssh multiplexer of its
        # own -- so ALL SIX preflight ports read HELD by a process called `ssh`
        # owned by the user. That looks like an operator tunnel and is not one.
        #
        # 🔴 ABSOLUTE PATH, DELIBERATELY. /opt/homebrew/bin is NOT on the login
        # PATH on a real walk box (measured 2026-09-04: the login PATH has no
        # Homebrew entry at all, though install.sh had put colima, docker and
        # limactl there hours earlier). A bare `colima` here is
        # command-not-found, and under `|| true` that reads as a clean reset
        # that never happened. That is task #542 and it bites the harness too.
        # 🔴 STOP THE SUPERVISOR BEFORE THE THING IT SUPERVISES.
        # Run 6 measured this: colima stop returned rc=0, the survey showed
        # all six ports FREE, and by the time the driver ran its own preflight
        # ~90s later 6333 was held again and colima was running. Nothing had
        # gone wrong -- com.ostler.engine-supervisor had done its job and
        # restarted the container VM, which is CORRECT on a customer box.
        # A reset that stops colima without stopping its supervisor is racing
        # a component designed to win that race.
        # Booting it out is not destructive: the install re-loads it.
        # v1.0.117 W4: NOT ONLY THE SUPERVISOR. com.creativemachines.ostler.assistant
        # is KeepAlive and restarts colima too; it did, 22s after the VM delete.
        # Boot out EVERY Ostler job still loaded (the uninstaller should have
        # left none; when it is absent or failed, this is the backstop). The two
        # known restarters are named explicitly as well, in case launchctl list
        # itself fails. An unquoted command substitution, not a variable,
        # because the remote login shell is zsh and zsh does not word-split
        # a plain variable expansion.
        echo "booting out every Ostler launchd job so nothing can restart colima under us"
        _uid="$(id -u)"
        for _l in com.ostler.engine-supervisor com.creativemachines.ostler.assistant \
                  $(launchctl list 2>/dev/null | awk "{print \$3}" | grep -Ei "(^|[.-])ostler([.-]|$)" | sort -u); do
            if launchctl bootout "gui/${_uid}/${_l}" >/dev/null 2>&1; then
                echo "  booted out ${_l}"
            fi
        done
        # The label match is ostler between separators, so it also catches
        # com.creativemachines.ostler-remotecapture, which the old prefix
        # match (ostler followed by a dot) missed.
        _left_jobs="$(launchctl list 2>/dev/null | awk "{print \$3}" | grep -Ei "(^|[.-])ostler([.-]|$)" | tr "\n" " ")"
        if [[ -n "$_left_jobs" ]]; then
            echo "STILL LOADED after bootout: ${_left_jobs}"
            _reset_fail="${_reset_fail} job-still-loaded"
        else
            echo "no Ostler launchd job is loaded"
        fi
        COLIMA=""
        for c in /opt/homebrew/bin/colima /usr/local/bin/colima; do
            [[ -x "$c" ]] && { COLIMA="$c"; break; }
        done
        if [[ -n "$COLIMA" ]]; then
            echo "stopping container VM: $COLIMA"
            # 🔴 AND THE ABSOLUTE PATH ALONE IS NOT ENOUGH, measured on run 4:
            #     level=fatal msg="dependency check failed for VM: lima not
            #     found, run brew install lima to install"
            # colima SHELLS OUT to limactl, so resolving colima by path just
            # moves the command-not-found one process deeper -- and the whole
            # reset then silently did nothing, all six ports stayed held, and
            # the run refused. Give the child the directory colima came from.
            # (limactl IS installed; nothing needed installing.)
            # CAPTURE, THEN PRINT. Not `| tail`: piping makes $? the exit of
            # TAIL, which is 0 whatever colima did, and that is how a failed
            # stop reads as a clean one.
            #
            # ⚠️ AND NOT ${PIPESTATUS[0]} EITHER. This block is interpreted by
            # the REMOTE LOGIN SHELL, which on the walk box is zsh 5.9 (asked,
            # not assumed) -- zsh spells it $pipestatus and leaves PIPESTATUS
            # UNSET, so under the `set -u` at the top of this heredoc the
            # "safety" line would itself abort the reset. Measured before it
            # cost a run.
            _colima_bin_dir="${COLIMA%/*}"
            _stop_out="$(PATH="${_colima_bin_dir}:${PATH}" "$COLIMA" stop 2>&1)" \
                && _stop_rc=0 || _stop_rc=$?
            # echo, NOT printf with a quoted format. THIS WHOLE BLOCK IS A
            # SINGLE-QUOTED ARGUMENT TO ssh, so any inner single quote closes
            # it and the shell re-splits everything after. Run 6 printed
            #     msg=donencolima stop rc=0
            # -- two separate lines welded together with a stray literal n,
            # which is what a quote breakout looks like when it does not
            # error. It corrupted the OUTPUT ONLY, so nothing failed and
            # nothing said so.
            #
            # NOTE TO THE NEXT EDITOR, AND I TRIPPED ON IT WRITING THIS VERY
            # COMMENT: no apostrophes in here either. bash -n does NOT catch
            # it, because the quotes rebalance at the end of the block and the
            # result is valid shell that means something else. The control
            # that catches it is a grep for a quote inside the block.
            echo "$_stop_out" | tail -3
            echo "colima stop rc=${_stop_rc}"
            # v1.0.117 W4: DELETE THE VM AND ITS DATA DISK. A plain
            # `colima delete -f` (colima 0.10.3) KEEPS the data disk at
            # ~/.colima/_lima/_disks/colima, so the images and store volumes of
            # earlier walks survived every "cold" walk. --data removes it. The
            # assertion below reads the DISK path, not ~/.colima/_lima/colima
            # (the instance directory), which is gone even when the disk is not.
            _del_out="$(PATH="${_colima_bin_dir}:${PATH}" "$COLIMA" delete --data -f 2>&1)" \
                && _del_rc=0 || _del_rc=$?
            echo "$_del_out" | tail -3
            echo "colima delete --data -f rc=${_del_rc}"
        else
            echo "no colima binary found at either Homebrew prefix."
            echo "If the ports below are HELD, THAT is why -- not a clean box."
        fi
        # THE DISK, ASSERTED. With or without a colima binary: a disk left by
        # an earlier walk is carried-over store data whatever deleted the VM.
        _colima_disk="${HOME}/.colima/_lima/_disks/colima"
        if [[ -e "$_colima_disk" ]]; then
            echo "RESET FAILED: the colima data disk is still present at ${_colima_disk}"
            du -sh "$_colima_disk" 2>/dev/null | tail -1
            echo "  Images and store volumes from earlier walks would be carried into this one,"
            echo "  so it would not be a cold walk."
            _reset_fail="${_reset_fail} colima-data-disk-present"
        else
            echo "colima data disk absent: ${_colima_disk}"
        fi
        # THE APP. The shipped uninstaller removes /Applications/Ostler.app and
        # the /Applications/Ostler folder; either surviving means the box still
        # carries a previous install.
        for _app in /Applications/Ostler.app /Applications/Ostler ~/Applications/Ostler.app; do
            if [[ -e "$_app" ]]; then
                echo "STILL PRESENT after the reset: ${_app}"
                _reset_fail="${_reset_fail} app-present"
            fi
        done
        # LEFTOVER PROCESSES. Anything still running from an Ostler install. The
        # patterns are written so they cannot match their own text (a bracket
        # or a class in each), and the shell running this block, and its own
        # forked subshells, are dropped by comparing command lines.
        _self_cmd="$(ps -o command= -p $$ 2>/dev/null)"
        _left_procs="$(ps -axo pid=,command= 2>/dev/null | awk -v self="$_self_cmd" "{pid=\$1; c=\$0; sub(/^ *[0-9]+ /, \"\", c); if (c == self) next; if (c ~ /Ostler[.]app\/Contents\/MacOS\/|\/[.]ostler\/|ostler[-]assistant|ostler[-]engine/) print pid \" \" c}")"
        if [[ -n "$_left_procs" ]]; then
            echo "LEFTOVER Ostler processes after the reset:"
            echo "$_left_procs" | head -10 | sed "s/^/  /"
            _reset_fail="${_reset_fail} leftover-processes"
        else
            echo "no Ostler process is running"
        fi
        # v1.0.117 W4: VERIFY, DO NOT SURVEY. This used to print HELD and carry
        # on, so the walk started, the installer preflight found all six ports
        # held, and the attempt was CANNOT-RUN after staging. Now the reset
        # waits for the ports to clear (colima stop is not instant) and FAILS
        # LOUDLY if they do not. A port is held if lsof sees a listener OR a
        # TCP connect succeeds: lsof is permission-scoped and cannot see a
        # listener owned by another account, a connect can.
        echo "--- preflight ports (must all be free) ---"
        _try=0
        while :; do
            _held=""
            for p in 3000 6333 6379 7878 8044 8144; do
                if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1 || nc -z -G 1 127.0.0.1 $p >/dev/null 2>&1; then
                    _held="${_held} ${p}"
                fi
            done
            [[ -z "$_held" ]] && break
            _try=$((_try + 1))
            [[ "$_try" -ge 10 ]] && break
            sleep 3
        done
        if [[ -n "$_held" ]]; then
            echo "RESET FAILED: port(s)${_held} still held after the uninstall, the bootout and 30s."
            for p in $(echo "$_held"); do
                lsof -nP -iTCP:$p -sTCP:LISTEN 2>/dev/null | tail -n +2 | head -3
            done
            echo "  Something is still serving the stores. Walking now would be CANNOT-RUN at"
            echo "  the installer preflight, after staging."
            _reset_fail="${_reset_fail} ports-held"
        else
            echo "  all six ports free: 3000 6333 6379 7878 8044 8144"
        fi
        _df_after="$(_df_kb)"
        echo "free space after the reset: ${_df_after:-unknown} KB available (before: ${_df_before:-unknown} KB)"
        # PROVENANCE, WRITTEN FROM WHAT HAPPENED. colima delete --data removes
        # the store volumes whether or not an uninstaller ran, so the old
        # carried-over-from-previous-install value (written when no uninstaller
        # was found) was false the moment the disk went. Written only once the
        # disk is asserted gone; a failed reset writes no provenance at all.
        if [[ -z "$_reset_fail" ]]; then
            if [[ -n "$_ran_uninstaller" ]]; then
                printf "wiped-by-shipped-uninstaller(%s; colima delete --data, data disk absent)\n" "$_ran_uninstaller" > ~/.walk-stores-provenance-run
            else
                printf "wiped-by-explicit-store-wipe(colima delete --data, data disk absent; no uninstaller on the box)\n" > ~/.walk-stores-provenance-run
            fi
            echo "stores provenance: $(cat ~/.walk-stores-provenance-run)"
            exit 0
        fi
        rm -f ~/.walk-stores-provenance-run
        echo "RESET FAILED:${_reset_fail}"
        exit 5
    ' 2>&1; then
        die "--reset did not leave the box clean (see RESET FAILED above, or the ssh session failed); refusing to stage or walk"
    fi
fi

# ── Stage: the REPO by default, or the ARTEFACT with --from-dmg ──────
#
# 🔴 EVERY WALK THIS HARNESS HAS EVER RUN MEASURED THE REPO, NOT THE DMG, and
# that gap has been carried in prose on every green it produced. A source-truth
# walk proves install.sh runs clean. It does NOT prove the thing a customer
# downloads runs clean, because the DMG's Contents/Resources is assembled by
# the cut pipeline from places the repo does not hold: on v1.0.65, 23 of its 48
# payload entries were absent from a full repo checkout and I had to copy 22 of
# them in by hand to get past step 21.
#
# --from-dmg stages that directory instead. It is the same SHAPE the repo
# presents after flattening -- install.sh at the top with the payload dirs
# beside it -- so nothing downstream changes.
#
# WHAT IT STILL DOES NOT COVER, said here so a green does not overstate itself:
# the .app is never launched. A customer double-clicks an installer app; this
# runs the install.sh inside it. Those differ in exactly the way v1.0.45 was
# bricked by -- a bundle that writes into itself on first RUN, which nothing
# inspecting it at rest can see.
rule "STAGE"
if [[ "$STAGE_KIND" == "repo" ]]; then
    HEAD_SHA="$(cd "$REPO_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    DIRTY="$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    say "staging ${REPO_ROOT} @ ${HEAD_SHA} (${DIRTY} uncommitted paths) -> ${HOST}:~/${REMOTE_DIR}"
    say "⚠️  THIS IS A SOURCE-TRUTH WALK. It measures install.sh, not the DMG."
else
    say "staging ${STAGE_SRC} -> ${HOST}:~/${REMOTE_DIR}"
fi

# 🔴 THE REPO EXCLUDES DESTROY A SIGNED BUNDLE. MEASURED on the first artefact
# walk that got as far as running: install.sh refused at step 9 with
#
#     Refusing to install ostler-assistant: not a Developer-ID-signed,
#     notarised bundle
#     codesign: a sealed resource is missing or invalid
#
# and the artefact was innocent. Inside the DMG that bundle passes BOTH checks
# install.sh demands (codesign --verify --deep --strict rc=0, spctl accepted,
# source=Notarized Developer ID). What broke it was this rsync:
#
#     in the DMG   54 files
#     staged       52 files
#     missing      Contents/Resources/ingest/email-ingest/__pycache__
#                  .../__pycache__/mark_first_ingest.cpython-311.pyc
#
# A .pyc inside a signed .app is a SEALED RESOURCE. `--exclude '*.pyc'` is
# correct hygiene for a CHECKOUT and is destructive to an ARTEFACT, and the
# same flag means opposite things depending on which one you are staging.
#
# So the artefact is copied VERBATIM. The whole premise of this mode is that
# the box receives what the customer receives; an exclude list contradicts it.
if [[ "$STAGE_KIND" == "artefact" ]]; then
    rsync -a --delete "${STAGE_SRC}/" "${HOST}:${REMOTE_DIR}/" \
        || die "rsync failed; nothing was run on the host."
else
    rsync -a --delete \
          --exclude '.git/' --exclude 'walks/' --exclude '__pycache__/' \
          --exclude '*.pyc' --exclude '.venv/' \
          "${STAGE_SRC}/" "${HOST}:${REMOTE_DIR}/" \
        || die "rsync failed; nothing was run on the host."
fi

# Re-confirm AFTER staging. Staging takes minutes; a DHCP lease can move in
# that window, and every step from here is on the box.
identity_check "after staging"

# ── Reproduce the .app payload LAYOUT, not just the file set ─────────
#
# 🔴 THIS IS WHY RUN 2 DIED. install.sh:7095 tests
#     [[ -d "${SCRIPT_DIR}/ostler_fda" ]]
# and on a real install SCRIPT_DIR is Contents/Resources/, where the payload
# dirs sit FLAT beside install.sh. In the repo the same code lives at
# vendor/ostler_fda. A flat rsync of the repo therefore puts every payload dir
# one level too deep, install.sh finds none of them, and the run dies at
# ERR-10-FDA-MODULE-MISSING having tested nothing.
#
# That failure is the HARNESS's, not the product's. Reporting it as a product
# defect would have been a fabricated bug, and `--allow-plaintext` (which the
# installer's own error text offers) would have "fixed" it by walking a
# DIFFERENT code path from the one customers run. Neither is acceptable.
#
# THE NAME LIST IS READ FROM THE BUNDLER, NEVER COPIED. gui/Makefile's payload
# check is the definition of what a DMG contains; a second hand-maintained copy
# here would drift and the harness would go on testing the old set while
# reporting success. Same artefact, one consumer.
# 🔴 THE ARTEFACT IS ALREADY IN THIS SHAPE. Flattening exists to turn a REPO
# checkout into what the DMG's Contents/Resources already is, so running it in
# --from-dmg mode looks for repo-relative sources that do not exist inside the
# artefact and dies. The first artefact walk got as far as here and refused:
#
#     cp: gui/ostler-mecard: No such file or directory
#     CANNOT-RUN: could not flatten gui/ostler-mecard on the host.
#
# Skipped, with a POSITIVE CONTROL rather than a bare skip: the whole point of
# this step is that ostler_fda ends up beside install.sh, and that is asserted
# below for both modes. A skip that checked nothing would hand the next walk
# the run-2 failure back.
if [[ "$STAGE_KIND" == "artefact" ]]; then
    rule "LAYOUT (skipped: the artefact ships already flattened)"
    say "the DMG's Contents/Resources IS the target shape; nothing to flatten."
    say "the control below still runs, so this skip is not a free pass."
else
rule "LAYOUT (flatten payload dirs to the Contents/Resources shape)"
PAYLOAD_NAMES="$(sed -n 's/.*for p in \(Ostler\.app install\.sh .*\); do.*/\1/p' \
                    "${REPO_ROOT}/gui/Makefile" | head -1)"
PAYLOAD_N="$(printf '%s\n' $PAYLOAD_NAMES | grep -c . || true)"

# ANTI-VACUITY FLOOR. An empty or truncated list would flatten nothing, the
# run would die exactly as run 2 did, and the cause would look like a product
# defect all over again. A zero here is a broken predicate, never a clean tree.
if [[ "${PAYLOAD_N:-0}" -lt 20 ]]; then
    die "could not read the payload name list from gui/Makefile
       (got ${PAYLOAD_N:-0} names, expected >= 20). The bundler's
       'for p in ...' line moved. Refusing to stage a layout I cannot verify."
fi
say "payload names read from gui/Makefile: ${PAYLOAD_N}"

# The payload dirs are NOT all one shape in the repo. Measured 2026-09-04:
#   2 already at the root            (contact_syncer, assistant-agent)
#  11 under vendor/                  (ostler_fda, ostler_security, doctor, ...)
#   1 under gui/                     (ostler-mecard)
#   3 under vendor/cm041/            (assistant_api, meeting_syncer, identity_resolver)
#   3 in NONE of those               (hub-power, email-ingest, imessage-bridge)
#
# My first cut of this loop looked only at the root and vendor/, found 13 of
# 22, and reported the other 9 as "absent" -- which would have been a false
# accusation against the repo for 6 of them and would have quietly under-staged
# every run. Search the real candidate roots, and keep the genuinely-absent
# three as a NAMED list rather than a count, so nobody has to guess which.
LINKED=0; ALREADY=0; ABSENT=""
for p in $PAYLOAD_NAMES; do
    [[ "$p" == "install.sh" || "$p" == "Ostler.app" ]] && continue
    if [[ -e "${REPO_ROOT}/${p}" ]]; then
        ALREADY=$(( ALREADY + 1 ))
        continue
    fi
    src=""
    for cand in "vendor/${p}" "gui/${p}" "vendor/cm041/${p}"; do
        [[ -d "${REPO_ROOT}/${cand}" ]] && { src="$cand"; break; }
    done
    if [[ -n "$src" ]]; then
        "${SSH[@]}" "cd '${REMOTE_DIR}' && rm -rf './${p}' && cp -R '${src}' './${p}'" \
            || die "could not flatten ${src} on the host."
        LINKED=$(( LINKED + 1 ))
    else
        ABSENT="${ABSENT} ${p}"
    fi
done
say "flattened: ${LINKED}   already at root: ${ALREADY}   of $(( PAYLOAD_N - 2 )) payload dirs"
if [[ -n "$ABSENT" ]]; then
    say "🔴 NOT IN THE REPO AT ALL:${ABSENT}"
    say "   These reach a real DMG from somewhere else in the cut pipeline."
    say "   The run below therefore exercises their ABSENCE, not their content."
    say "   Any failure naming one of them is the HARNESS, not the product."
fi

fi

# ── OVERLAY THE INSTRUMENT, WITHOUT TOUCHING THE SUBJECT ─────────────
#
# The artefact has no scripts/ directory -- it is a payload, not a checkout --
# so the driver that answers install.sh's prompts is simply not there. The
# third artefact walk died on exactly that, with an empty pty log:
#
#     python3: can't open file '.../ostler-ttywalk/scripts/walk_drive.py'
#
# walk_drive.py is the INSTRUMENT and install.sh is the SUBJECT. The instrument
# has to be beside the subject to drive its pty, but it must not change it.
# So: copy ONLY the driver in, then ASSERT the artefact's own install.sh is
# byte-identical to the one inside the DMG. A harness that quietly edited the
# thing it was measuring would make every verdict it produced meaningless, and
# "I only added a file" is exactly the assumption worth checking rather than
# stating.
if [[ "$STAGE_KIND" == "artefact" ]]; then
    rule "OVERLAY (the driver only; the payload must not change)"
    _sub_before="$(shasum -a 256 "${STAGE_SRC}/install.sh" | awk '{print $1}')"
    "${SSH[@]}" "mkdir -p '${REMOTE_DIR}/scripts'" \
        || die "could not create scripts/ on the host for the driver."
    scp -q "${REPO_ROOT}/scripts/walk_drive.py" "${HOST}:${REMOTE_DIR}/scripts/walk_drive.py" \
        || die "could not copy walk_drive.py to the host."
    _sub_after="$("${SSH[@]}" "shasum -a 256 '${REMOTE_DIR}/install.sh'" | awk '{print $1}')"
    if [[ "$_sub_before" != "$_sub_after" ]]; then
        die "the staged install.sh does NOT match the DMG's.
       dmg   ${_sub_before}
       host  ${_sub_after}
       The instrument has changed the subject, or staging is lossy. Either
       way this walk would measure something that is not the artefact."
    fi
    say "driver overlaid; install.sh on the host is byte-identical to the DMG's"
    say "   sha256 ${_sub_before}"

    # 🔴 A HASH ON ONE FILE IS NOT A CHECK ON 49 ENTRIES. install.sh matched
    # while a bundle two directories away had lost two sealed resources, and
    # the walk went on to blame the product for it. The seal is the thing that
    # actually proves the payload arrived intact, so assert it directly, on the
    # box, before spending a walk.
    _agent="${REMOTE_DIR}/assistant-agent/OstlerAssistant.app"
    if "${SSH[@]}" "[[ -d '${_agent}' ]]"; then
        if "${SSH[@]}" "codesign --verify --deep --strict '${_agent}' 2>&1"; then
            say "staged daemon bundle still verifies: codesign --deep --strict OK"
        else
            die "the staged OstlerAssistant.app NO LONGER VERIFIES on the host.
       The payload was damaged in transit, so install.sh will refuse it and
       the walk would record that refusal as a product defect. Compare the
       file COUNT inside the bundle on both sides: an rsync exclude that is
       correct for a checkout can strip a sealed resource from a signed app."
        fi
    fi
fi

# POSITIVE CONTROL: the specific directory whose absence killed run 2 must now
# resolve at the exact path install.sh tests. Checking the general case above
# and not this one would leave the original failure free to recur silently.
"${SSH[@]}" "[[ -d '${REMOTE_DIR}/ostler_fda' ]]" \
    || die "ostler_fda is STILL not beside install.sh after flattening.
       install.sh:7095 will fail ERR-10 again and the run would measure my
       staging rather than the product. CANNOT-RUN."
say "control: ostler_fda resolves beside install.sh (the run-2 killer is closed)"

"${SSH[@]}" "set -u
    printf '%s\n' \"\$HOME/${REMOTE_DIR}/ttywalk.log\" > ~/.walk-log
    printf '%s\n' \"\$HOME/${REMOTE_DIR}/install.sh\"  > ~/.walk-installsh
    printf '%s\n' \"${ARTEFACT_VERSION:-}\" > ~/.walk-artefact-version
    # STORE PROVENANCE. The reset step writes the run file; consuming it here
    # (rather than reading it in place) means a walk with no --reset cannot
    # inherit the previous walk answer and present it as this one.
    if [ -f ~/.walk-stores-provenance-run ]; then
        mv ~/.walk-stores-provenance-run ~/.walk-stores-provenance
    else
        printf 'unknown-no-reset-step\n' > ~/.walk-stores-provenance
    fi
    # THE HUB PASSPHRASE PROMPT HAS NO WAY PAST, so the walk must be able
    # to answer it or the install re-prompts for ever (install.sh:8032-8051
    # loops while true on empty or under-12-character input). walk_drive.py
    # answers it with @passphrase, which resolves from this file at answer
    # time, so the value is never an argument and never in the process table.
    #
    # GENERATED ON THE BOX, not passed in: it must not cross the wire, appear
    # in an operator's shell history, or reach a transcript. It is a throwaway
    # for a disposable walk account and is regenerated whenever it is absent.
    if [ ! -s ~/.walk-passphrase ]; then
        ( umask 077
          LC_ALL=C tr -dc 'a-z' < /dev/urandom | head -c 24 > ~/.walk-passphrase )
        chmod 600 ~/.walk-passphrase
    fi
    : > \"\$HOME/${REMOTE_DIR}/ttywalk.log\"
    chmod +x \"\$HOME/${REMOTE_DIR}/install.sh\" 2>/dev/null || true
    echo 'walk config written:'
    echo \"  log:        \$(cat ~/.walk-log)\"
    echo \"  install.sh: \$(cat ~/.walk-installsh)\"
    echo \"  artefact:   \$(cat ~/.walk-artefact-version 2>/dev/null | sed 's/^\$/(repo walk -- none)/')\"
    echo \"  stores:     \$(cat ~/.walk-stores-provenance 2>/dev/null)\"
" || die "could not write the walk config on the host."

# THE WALK'S OWNER. WHOSE identity the installer is given is DECIDED, never
# inferred from a file being present on the driver (walk #31, 2026-10-18: a
# non-owner test account was installed with the operator's real identity
# because the only predicate was "the owner file exists"). The owner file is
# staged ONLY when this target's (IOPlatformUUID, account) pair is declared in
# the operator-local allowlist; every other walk installs the synthetic cast
# owner. If the predicate cannot be evaluated, the walk REFUSES. Values are
# streamed over ssh stdin into a 0600 file, never an argument, never printed.
# See scripts/lib_walk_owner.sh.
# shellcheck source=scripts/lib_walk_owner.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_walk_owner.sh"
OWNER_FILE_LOCAL="${OSTLER_WALK_OWNER_FILE:-$HOME/walkdriver/owner_identity.env}"
OWNER_TARGETS_LOCAL="$(walk_owner_default_targets)"
# ONE round trip, so the UUID and the account cannot describe different hosts.
# ioreg's own failure is kept: an empty UUID is a refusal below, never a match.
OWNER_IDENT="$("${SSH[@]}" 'u=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F"\"" "/IOPlatformUUID/{print \$4}"); printf "%s\n%s\n" "$u" "$(id -un)"')" \
    || die "could not read the target's IOPlatformUUID and account to decide whose identity to install."
OWNER_DECISION="$(walk_owner_decide "$OWNER_FILE_LOCAL" "$OWNER_TARGETS_LOCAL" \
    "$(printf '%s\n' "$OWNER_IDENT" | sed -n 1p)" "$(printf '%s\n' "$OWNER_IDENT" | sed -n 2p)")" \
    || die "owner identity: REFUSING to start the walk -- the owner-target predicate could not be evaluated (see above). Fix ${OWNER_TARGETS_LOCAL} or the target; the owner file is never staged on a guess."
if [[ "$OWNER_DECISION" == owner ]]; then
    "${SSH[@]}" "umask 077; cat > ~/.walk-owner.env && chmod 600 ~/.walk-owner.env" < "$OWNER_FILE_LOCAL" \
        || die "could not stage the owner identity on the host."
    say "owner identity: OWNER target (declared in ${OWNER_TARGETS_LOCAL}); staged from ${OWNER_FILE_LOCAL} (values not printed)"
else
    # A stale file from an earlier walk would be answered by walk_drive.py, so
    # its removal is VERIFIED, not hoped for.
    "${SSH[@]}" "rm -f ~/.walk-owner.env && test ! -e ~/.walk-owner.env" \
        || die "could not remove a stale ~/.walk-owner.env on the host; refusing rather than risk installing it."
    say "owner identity: SYNTHETIC cast owner (${OWNER_DECISION#synthetic: }); the owner-in-People probe will read CANNOT-RUN"
fi

if [[ "$STAGE_ONLY" -eq 1 ]]; then
    say "staged only, as asked. Not running."
    exit "$PASS"
fi

# ── SAFARI SEED: a SYNTHETIC History.db, planted BEFORE install ──────
# A walk account that never opened Safari has no ~/Library/Safari, so the
# reader says not_found and ingest_coverage can only grade the source absent
# (CANNOT-RUN). Planting a synthetic History.db gives the walk real coverage of
# the Safari path. Never overwrites a real History.db; records what happened in
# ~/.walk-safari-seed-run on the box, which ingest_coverage reads. TCC can
# refuse the plant or, later, the read: both are CANNOT-RUN (FDA), recorded,
# never a pass. See scripts/lib_walk_safari_seed.sh.
# shellcheck source=scripts/lib_walk_safari_seed.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_walk_safari_seed.sh"
if [[ "$(walk_safari_throwaway_decide "$EXPECT_USER")" != "plant" ]]; then
    # Not a declared throwaway (--expect-user walk[0-9]+ or OSTLER_WALK_THROWAWAY=1):
    # never plant synthetic browsing on a box that may be a real person's.
    { declare -f walk_safari_seed_skip; printf 'walk_safari_seed_skip\n'; } \
        | "${SSH[@]}" 'bash -s' | sed 's/^/  /' | while IFS= read -r _l; do say "$_l"; done
else
    _SAFARI_FX_LOCAL="$(mktemp -t walk-safari-fx)" || die "could not create a local scratch file for the Safari fixture."
    if python3 -I "${REPO_ROOT}/scripts/box_walk_probes/lib/safari_history_fixture.py" "$_SAFARI_FX_LOCAL" >/dev/null; then
        _SAFARI_FX_REMOTE="$("${SSH[@]}" 'f=$(mktemp -t walk-safari-fx) && cat > "$f" && printf "%s" "$f"' < "$_SAFARI_FX_LOCAL")" || _SAFARI_FX_REMOTE=""
        if [[ -n "$_SAFARI_FX_REMOTE" ]]; then
            { declare -f walk_safari_seed_apply; printf 'walk_safari_seed_apply %q\nrm -f %q\n' "$_SAFARI_FX_REMOTE" "$_SAFARI_FX_REMOTE"; } \
                | "${SSH[@]}" 'bash -s' | sed 's/^/  /' | while IFS= read -r _l; do say "$_l"; done
        else
            say "safari seed: could not ship the fixture to the host; Safari will be graded SOURCE-ABSENT if the box has none"
        fi
    else
        say "safari seed: could not build the fixture locally; Safari will be graded SOURCE-ABSENT if the box has none"
    fi
    rm -f "$_SAFARI_FX_LOCAL"
fi

# ── Run ──────────────────────────────────────────────────────────────
rule "RUN (unattended; OSTLER_GUI=1 with OSTLER_GUI_FD UNSET)"
say "started $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ARCHIVE THE PREVIOUS RUN'S EVIDENCE BEFORE THIS ONE STARTS, so the report at
# the end can only be describing this run. Archived, not deleted: the previous
# answers are how we saw run 4 reporting run 3's. See the QA PAIRS note below.
"${SSH[@]}" 'for f in ~/.walk-qa.tsv; do
    [[ -f "$f" ]] && mv -f "$f" "${f%.tsv}.prev.tsv"
done; :' >/dev/null 2>&1

# nohup + setsid-equivalent so the run survives this ssh channel closing.
# OSTLER_GUI_FD and OSTLER_MARKER_FD are explicitly UNSET rather than merely
# unmentioned: an inherited value from a previous shell would silently send
# the markers somewhere we are not reading, and the run would then look
# marker-less for a reason that has nothing to do with the product.
# ── THE ONE THING AN UNATTENDED WALK CANNOT DO, DECLARED RATHER THAN DISCOVERED
#
# MEASURED on walk 13. The run reached the last step and then:
#
#     STEP_END id=health_check status=timeout elapsed_s=110 rc=124
#     WARN No answer to the Messages permission prompt, so we moved on.
#
# install.sh probes iMessage Automation with `osascript ... tell application
# "Messages"`, deadlined at OSTLER_IMESSAGE_PROBE_TIMEOUT_S (90s by default).
# The grant is a macOS TCC decision that requires a GUI user to click Allow in
# a dialog. **An ssh session cannot click it, ever.** So the probe
# blocks for the full 90s, returns 124, and the step is recorded `timeout`.
#
# install.sh handles that 124 correctly and deliberately -- its own comment
# says "A probe nobody answered is NOT a denial" and records `check-failed`,
# which the daemon later re-probes. The PRODUCT is not at fault. The harness is,
# for spending 90 seconds every run to rediscover a permission it can never be
# granted, and then reporting the result as a failed step.
#
# install.sh already ships the hook for exactly this: PWG_IMESSAGE_PROBE_OUTCOME
# is documented in its source as "lets test harnesses inject an outcome without
# invoking osascript. Real macOS installs leave this unset."
#
# 🔴 THE VALUE MATTERS AND IT IS NOT A FREE CHOICE.
#
#     granted-and-working   would MANUFACTURE a permission this box has not got.
#                           That is a fabricated pass and must never be used.
#     check-failed          is the honest state: we could not determine it.
#                           It is the same value install.sh itself records on a
#                           real 124, so the walk follows the same path a real
#                           unattended install follows.
#
# WHAT THIS COSTS, STATED PLAINLY: the walk does NOT exercise the real osascript
# probe. That coverage was never obtainable over ssh, so nothing is lost that
# was ever there -- but a walk that passes says nothing about TCC, and a human
# walk on a real console is the only thing that can.
IMESSAGE_SHIM="check-failed"
say "iMessage Automation probe: SHIMMED to '${IMESSAGE_SHIM}' for this run."
say "   macOS TCC needs a GUI click that ssh cannot make, so the real probe"
say "   would block 90s and report a timed-out step every single walk."
say "   ⚠️  THIS WALK THEREFORE DOES NOT TEST THE REAL AUTOMATION PROBE."
say "   Only a console walk by a human can. Never shim it to granted-and-working."

# MARK THE INSTALL AS HARNESS-DRIVEN, ON THE BOX. box_walk_probes/lib/db_key_probe.py
# reads this (with install.log's run header) to tell an ssh-harness install, which
# has no GUI app to make the DB key file, from a console install, where the same
# "no database key resolved" refusal is the launch blocker. Written by the box's
# own clock; absent on any install this script did not start.
"${SSH[@]}" 'mkdir -p ~/.ostler && printf "ttywalk %s\n" "$(date +%s)" > ~/.ostler/.install-harness' >/dev/null 2>&1 \
    || say "WARNING: could not write ~/.ostler/.install-harness; db_key_reaches_every_service will treat this install as a console install"

"${SSH[@]}" "cd '${REMOTE_DIR}' && \
    unset OSTLER_GUI_FD OSTLER_MARKER_FD && \
    PWG_IMESSAGE_PROBE_OUTCOME='${IMESSAGE_SHIM}' \
    OSTLER_WALK_OWNER_FILE=\"\$HOME/.walk-owner.env\" \
    OSTLER_GUI=1 nohup python3 scripts/walk_drive.py > ttywalk.driver.out 2>&1 &
    echo started" >/dev/null 2>&1

# Poll. A poll loop with no delay is not a wait.
# IS THE BOX DOING WORK? Echoes "<free-kb> <live-worker-count>", or nothing
# at all when it could not measure -- and the caller treats "could not
# measure" as CANNOT-RUN rather than as zero.
#
# CPU IS THE WRONG INSTRUMENT HERE AND I MEASURED THAT BEFORE SHIPPING IT.
# Two ways it lies on this box:
#   unscoped .... colima's VM daemons burn ~1 CPU-second every 25s whether or
#                 not anything is progressing, i.e. ~48s of pure noise per
#                 20-minute window. Everything looks busy.
#   descendant .. a docker pull's work happens INSIDE the colima VM, which is
#                 not a descendant of walk_drive.py. Everything looks idle.
# Free disk has neither problem: a 3.5 GB image pull consumes it monotonically.
_box_work_signal() {
    "${SSH[@]}" 'FREE=$(df -k / | tail -1 | awk "{print \$4}");
        W=$(/usr/bin/pgrep -f "[d]ocker (pull|compose)|[b]rew (install|upgrade)|[c]url .*-o" | wc -l | tr -d " ");
        [ -n "$FREE" ] && printf "%s %s" "$FREE" "${W:-0}"' 2>/dev/null
}

# 4h. vane_install alone is documented as up to an hour, and there are 39
# other steps. 2h could not cover a healthy walk, so it was a second
# fixed number standing in for a measurement.
# THE DECISION, AS A PURE FUNCTION so it can be tested without a box.
#   _stall_verdict "<signal>" "<free_prev_kb>"
# where <signal> is "<free_kb> <workers>" or empty.
# Echoes exactly one of: WORKING  STALLED  CANNOT-RUN
#
# CANNOT-RUN is a THIRD STATE and it is not a pass and not a failure. An
# unreadable signal means the harness could not look, which must never be
# spelled the same way as "it looked and saw nothing".
_stall_verdict() {
    local sig="$1" prev="$2" free workers delta
    if [[ -z "$sig" ]]; then printf 'CANNOT-RUN'; return; fi
    free="${sig%% *}"; workers="${sig##* }"
    case "$free" in ''|*[!0-9]*) printf 'CANNOT-RUN'; return ;; esac
    case "$workers" in ''|*[!0-9]*) printf 'CANNOT-RUN'; return ;; esac
    if [[ "$workers" -ge 1 ]]; then printf 'WORKING'; return; fi
    if [[ -z "$prev" ]]; then printf 'WORKING'; return; fi   # first sample: no delta yet
    case "$prev" in ''|*[!0-9]*) printf 'CANNOT-RUN'; return ;; esac
    delta=$(( prev - free )); [[ "$delta" -lt 0 ]] && delta=$(( -delta ))
    if [[ "$delta" -ge 51200 ]]; then printf 'WORKING'; else printf 'STALLED'; fi
}

DEADLINE=$(( $(date +%s) + 14400 ))
LAST_SIZE=-1
STALL_TICKS=0
STALL_EXTENSIONS=0
# 6 x 20 min = up to 2h of quiet-but-working, which the 2h DEADLINE bounds
# anyway. The cap exists so a process that spins without progressing cannot
# hold the walk open forever.
STALL_EXTENSION_CAP=6
_free_prev=""   # seeded on the first stall check, not before
while :; do
    sleep 30
    ALIVE="$("${SSH[@]}" 'pgrep -f walk_drive.py >/dev/null 2>&1 && echo yes || echo no')"
    SIZE="$("${SSH[@]}" "wc -c < ~/${REMOTE_DIR}/ttywalk.log 2>/dev/null || echo 0" | tr -d ' ')"
    STEP="$("${SSH[@]}" "grep -a 'STEP_BEGIN' ~/${REMOTE_DIR}/ttywalk.log 2>/dev/null | tail -1 | tr -d '\r' | cut -c1-120")"
    printf '%s  alive=%s  log=%sB  %s\n' "$(date -u '+%H:%M:%SZ')" "$ALIVE" "${SIZE:-0}" "${STEP:-<no step marker yet>}"

    [[ "$ALIVE" == "no" ]] && break

    if [[ "$SIZE" == "$LAST_SIZE" ]]; then
        STALL_TICKS=$(( STALL_TICKS + 1 ))
    else
        STALL_TICKS=0
    fi
    LAST_SIZE="$SIZE"

    # 40 ticks x 30s = 20 minutes of a LIVE process producing NO output.
    #
    # 🔴 MEASURED 2026-09-04, ARTEFACT WALK 6. This fired at vane_install and
    # threw away 27 minutes for nothing. The step was PERFECTLY HEALTHY: Vane
    # is a 3.5 GB image pull, and install.sh itself logs
    #
    #     "There is no progress bar for it, so a long silence here is expected
    #      and does not mean the install has stalled."
    #
    # A docker pull writes NOTHING to the marker wire for as long as it takes.
    # So a fixed log-silence cap does not measure wedged-ness, it measures
    # step identity, and it will kill EVERY artefact walk at step 11 of 40.
    #
    # The comment this replaces had it exactly right -- "a wedged install and a
    # slow one look identical from here and the difference matters" -- and then
    # resolved the ambiguity by guessing. The fix is to STOP THEM LOOKING
    # IDENTICAL, not to raise the number and guess later.
    #
    # ELAPSED TIME IS NOT WORK. CUMULATIVE CPU IS. A wedged process burns no
    # CPU; a pull, an unpack and a build all do. So silence now TRIGGERS a
    # second, independent measurement instead of ending the run.
    if [[ "$STALL_TICKS" -ge 40 ]]; then
        _sig_now="$(_box_work_signal)"
        if [[ -z "$_sig_now" ]]; then
            say ""
            say "STALL CHECK CANNOT-RUN: could not read the work signal from the box."
            say "Refusing to call this either way. Absent is not zero."
            break
        fi
        _free_now="${_sig_now%% *}"; _workers="${_sig_now##* }"
        _free_delta=$(( ${_free_prev:-$_free_now} - _free_now ))
        [[ "$_free_delta" -lt 0 ]] && _free_delta=$(( -_free_delta ))
        if [[ "$(_stall_verdict "$_sig_now" "${_free_prev:-}")" == "WORKING" ]]; then
            STALL_EXTENSIONS=$(( STALL_EXTENSIONS + 1 ))
            say "  quiet but WORKING: disk moved $(( _free_delta / 1024 ))MB, ${_workers} long-running worker(s) alive"
            say "  (extension ${STALL_EXTENSIONS} of ${STALL_EXTENSION_CAP}; the deadline below still applies)"
            _free_prev="$_free_now"
            STALL_TICKS=0
            if [[ "$STALL_EXTENSIONS" -ge "$STALL_EXTENSION_CAP" ]]; then
                say ""
                say "STALLED: ${STALL_EXTENSION_CAP} extensions used and still no marker output."
                say "Reporting on what exists. This is not a completed run."
                break
            fi
        else
            say ""
            say "STALLED: no marker output for 20 minutes, disk moved only"
            say "$(( _free_delta / 1024 ))MB and no long-running worker is alive. Alive and doing"
            say "nothing is the discriminator between wedged and merely slow."
            say "Reporting on what exists. This is not a completed run."
            break
        fi
    fi
    if [[ "$(date +%s)" -ge "$DEADLINE" ]]; then
        say ""
        say "DEADLINE: 4 hours elapsed and the driver is still running."
        say "Reporting on what exists. This is not a completed run."
        break
    fi
done

say "finished $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ── EARLY PASS: the previous walk's FAILED probes, read-only, NOW ────────────
# So a repeat failure shows within minutes of the install and not at the end of
# the walk. It is informational: its exit status is discarded on purpose and it
# touches neither WALK_VERDICT nor the walk record. The full probe run in
# record_walk.sh below is unchanged and alone decides the verdict.
if [[ "$NO_EARLY_PASS" -eq 1 ]]; then
    say ""
    say "early-pass: DECLINED -- --no-early-pass was passed."
elif [[ ! -f "${REPO_ROOT}/scripts/early_repeat_fail_pass.sh" ]]; then
    say ""
    say "early-pass: CANNOT-RUN -- ${REPO_ROOT}/scripts/early_repeat_fail_pass.sh is absent."
else
    bash "${REPO_ROOT}/scripts/early_repeat_fail_pass.sh" --host "$HOST" || \
        say "early-pass: CANNOT-RUN -- the pass itself exited non-zero; the full walk is unaffected."
fi

LOG="$("${SSH[@]}" 'cat ~/.walk-log 2>/dev/null')"
report "$LOG"

rule "DRIVER STDERR (last 30 lines)"
"${SSH[@]}" "tail -30 ~/${REMOTE_DIR}/ttywalk.driver.out 2>/dev/null || echo '(none)'"

rule "QA PAIRS ANSWERED"
# 🔴 THIS SECTION PRINTED ANOTHER RUN'S ANSWERS AS THIS ONE'S. Run 4 refused
# at the port preflight, answered nothing, and still reported four Q/A rows --
# run 3's, timestamped 40 minutes before run 4 started. ~/.walk-qa.tsv is
# append-only and nothing rotated it. Same class as walk_drive's FIX 1 (a
# stale result file read as this run's verdict), one artefact over: the driver
# guards its RESULT and nobody guarded its EVIDENCE.
#
# The archive at the top of the run makes the rows here unambiguous. The count
# excludes the header, because "rows: 5" over four answers is a small lie of
# exactly the kind this harness exists to catch.
"${SSH[@]}" "awk 'NR>1' ~/.walk-qa.tsv 2>/dev/null | wc -l | tr -d ' ' | sed 's/^/answers this run: /'; tail -50 ~/.walk-qa.tsv 2>/dev/null || echo '(none)'"

# ── RECORD THE WALK ──────────────────────────────────────────────────────
#
# 🔴 THIS SCRIPT RAN TWO FULL WALKS ON REAL HARDWARE ON 2026-09-23 AND LEFT NO
# EVIDENCE ANY GATE COULD READ. The launch directive makes walks/v1.0.NN.tsv
# THE deliverable; scripts/verify_walk_record.sh reads it; scripts/post_walk_qa.sh
# writes it and has since 2026-08-21. The only missing piece was a call, and
# this file -- the command the directive mandates -- named post_walk_qa.sh
# exactly twice, both times in a comment.
#
# WHY IT SITS HERE, AFTER report() AND BEFORE THE EXIT. report() is what sets
# WALK_VERDICT, so this is the first point at which the install's adjudication
# is known; and the exit below is final, so anything after it would be dead.
#
# WHY IT DOES NOT TOUCH WALK_VERDICT ON A FAIL. A record is written for FAILED
# walks too -- walks/v1.0.100.tsv says `verdict FAILED` and is one of the most
# useful files in this repo. Folding the recorder's exit into the walk's would
# turn "the probes found defects" into "the walk was not recorded", the exact
# inversion verify_walk_record.sh warns about at _require_console_walk.
#
# WHAT IT DOES ESCALATE, and only this: a walk that PASSED but could not be
# recorded is not a green anyone may act on, because nothing downstream can
# see it. That is CANNOT-RUN -- absence of evidence -- and it is applied only
# to a verdict that would otherwise read as clean. A FAIL keeps saying FAIL.
# Same doctrine, and the same placement rule, as _require_console_walk.
if [[ "$NO_RECORD" -eq 1 ]]; then
    say ""
    say "walk-record: DECLINED -- --no-record was passed. No walks/<version>.tsv"
    say "             was written, so no gate downstream can see this walk."
elif [[ ! -x "${REPO_ROOT}/scripts/record_walk.sh" && ! -f "${REPO_ROOT}/scripts/record_walk.sh" ]]; then
    say ""
    say "walk-record: CANNOT-RUN -- ${REPO_ROOT}/scripts/record_walk.sh is absent."
    say "             This walk is unrecorded and nothing downstream can read it."
    [[ "${WALK_VERDICT:-}" == "$PASS" ]] && WALK_VERDICT="$CANNOT_RUN"
else
    RECORD_ARGS=(--host "$HOST" --walk-verdict "${WALK_VERDICT:-2}")
    [[ -n "$CONSOLE_WALK" ]] && RECORD_ARGS+=(--console "$CONSOLE_WALK")
    # NOT in an && chain and NOT read through a pipe: 3 (DECLINED) and 2
    # (CANNOT-RUN) are both ordinary and must be told apart.
    RECORD_RC=0
    bash "${REPO_ROOT}/scripts/record_walk.sh" "${RECORD_ARGS[@]}" || RECORD_RC=$?
    if [[ "$RECORD_RC" -eq 2 && "${WALK_VERDICT:-}" == "$PASS" ]]; then
        say ""
        say "The walk passed and COULD NOT BE RECORDED, so there is nothing for any"
        say "gate to read. A pass nobody can verify is not a pass: CANNOT-RUN."
        WALK_VERDICT="$CANNOT_RUN"
    fi
fi

# ── EXIT WITH THE VERDICT ────────────────────────────────────────────────
# This script used to end on its last `ssh`, so it exited 0 no matter what the
# walk found. Every failed walk of the night reported "exit code 0" to whatever
# ran it, and a caller branching on that would have called walk 11 green while
# three steps were failing. A gate that exits zero after dying is not a gate.
if [[ -z "${WALK_VERDICT:-}" ]]; then
    say ""
    say "NO VERDICT WAS RECORDED. That is CANNOT-RUN, not a pass."
    exit "$CANNOT_RUN"
fi
say ""
say "ttywalk exiting ${WALK_VERDICT}"
exit "$WALK_VERDICT"
