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
#   scripts/ttywalk.sh --host ... --expect-name ... --reset      # uninstall first
#   scripts/ttywalk.sh --host ... --expect-name ... --report-only # read last run
#
# EXIT CODES, and they are three not two:
#   0  PASS        install.sh reached its end and said so on the marker wire
#   1  FAIL        it did not, and we watched that happen
#   2  CANNOT-RUN  we were not in a position to find out

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_DIR="ostler-ttywalk"

PASS=0; FAIL=1; CANNOT_RUN=2

HOST=""
EXPECT_NAME=""
EXPECT_MODEL=""
DO_RESET=0
REPORT_ONLY=0
STAGE_ONLY=0

die() { printf 'CANNOT-RUN: %s\n' "$*" >&2; exit "$CANNOT_RUN"; }
say() { printf '%s\n' "$*"; }
rule() { printf -- '---- %s ----\n' "$*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)         HOST="${2:-}"; shift 2 ;;
        --expect-name)  EXPECT_NAME="${2:-}"; shift 2 ;;
        --expect-model) EXPECT_MODEL="${2:-}"; shift 2 ;;
        --reset)        DO_RESET=1; shift ;;
        --report-only)  REPORT_ONLY=1; shift ;;
        --stage-only)   STAGE_ONLY=1; shift ;;
        -h|--help)      sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)              die "unknown argument: $1" ;;
    esac
done

[[ -n "$HOST" ]] || die "--host is required (user@host)"

SSH=(ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST")

# ── Identity, by NAME, before anything else ──────────────────────────
#
# Read all three facts in ONE round trip so they cannot describe different
# machines, which is the failure a second ssh call would invite.
identity_check() {
    local when="$1" ident name model
    ident="$("${SSH[@]}" 'printf "%s\n%s\n%s\n" "$(scutil --get ComputerName)" "$(sysctl -n hw.model)" "$(id -un)"' 2>&1)" \
        || die "cannot reach ${HOST} (${when}): ${ident}"

    name="$(printf '%s' "$ident"  | sed -n 1p)"
    model="$(printf '%s' "$ident" | sed -n 2p)"

    [[ -n "$name" ]] || die "the host answered with an EMPTY ComputerName (${when}).
       An empty string matches nothing and must never be read as a match."

    if [[ -n "$EXPECT_NAME" && "$name" != "$EXPECT_NAME" ]]; then
        die "IDENTITY MISMATCH (${when}). Expected ComputerName '${EXPECT_NAME}',
       the host at ${HOST} answers '${name}'. DHCP moves this address.
       Refusing rather than acting on the wrong machine."
    fi
    if [[ -n "$EXPECT_MODEL" && "$model" != "$EXPECT_MODEL" ]]; then
        die "IDENTITY MISMATCH (${when}). Expected hw.model '${EXPECT_MODEL}',
       got '${model}'."
    fi
    say "identity ${when}: ${name} / ${model} (as $(printf '%s' "$ident" | sed -n 3p))"
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
rule "BUNDLED-PYTHON PREFLIGHT (the customer path, not the dev fallback)"
BUNDLED_PY_LOCAL="${REPO_ROOT}/python/bin/python3.11"
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
if [[ "$DO_RESET" -eq 1 ]]; then
    rule "RESET (uninstall + port survey; this is NOT a wipe)"
    "${SSH[@]}" 'set -u
        for u in ~/Applications/Ostler.app/Contents/Resources/uninstall.sh \
                 /Applications/Ostler.app/Contents/Resources/uninstall.sh \
                 ~/.ostler/uninstall.sh; do
            if [[ -x "$u" ]]; then
                echo "running shipped uninstaller: $u"
                OSTLER_ASSUME_YES=1 bash "$u" 2>&1 | tail -25
                break
            fi
        done
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
        echo "booting out the engine supervisor so it cannot restart colima under us"
        launchctl bootout "gui/$(id -u)/com.ostler.engine-supervisor" 2>&1 | head -2 || true
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
        else
            echo "no colima binary found at either Homebrew prefix."
            echo "If the ports below are HELD, THAT is why -- not a clean box."
        fi
        echo "--- install.sh processes still up ---"
        pgrep -fl "install.sh" || echo "none"
        echo "--- preflight ports still held ---"
        for p in 3000 6333 6379 7878 8044 8144; do
            if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; then
                echo "  $p HELD"
            else
                echo "  $p free"
            fi
        done
        echo "NOTE: lsof is PERMISSION-SCOPED. A port held by ANOTHER account is"
        echo "invisible here. This survey is evidence about THIS account only."
    ' 2>&1
fi

# ── Stage the CURRENT tree ───────────────────────────────────────────
rule "STAGE"
HEAD_SHA="$(cd "$REPO_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY="$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
say "staging ${REPO_ROOT} @ ${HEAD_SHA} (${DIRTY} uncommitted paths) -> ${HOST}:~/${REMOTE_DIR}"

rsync -a --delete \
      --exclude '.git/' --exclude 'walks/' --exclude '__pycache__/' \
      --exclude '*.pyc' --exclude '.venv/' \
      "${REPO_ROOT}/" "${HOST}:${REMOTE_DIR}/" \
    || die "rsync failed; nothing was run on the host."

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
    : > \"\$HOME/${REMOTE_DIR}/ttywalk.log\"
    chmod +x \"\$HOME/${REMOTE_DIR}/install.sh\" 2>/dev/null || true
    echo 'walk config written:'
    echo \"  log:        \$(cat ~/.walk-log)\"
    echo \"  install.sh: \$(cat ~/.walk-installsh)\"
" || die "could not write the walk config on the host."

if [[ "$STAGE_ONLY" -eq 1 ]]; then
    say "staged only, as asked. Not running."
    exit "$PASS"
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

"${SSH[@]}" "cd '${REMOTE_DIR}' && \
    unset OSTLER_GUI_FD OSTLER_MARKER_FD && \
    PWG_IMESSAGE_PROBE_OUTCOME='${IMESSAGE_SHIM}' \
    OSTLER_GUI=1 nohup python3 scripts/walk_drive.py > ttywalk.driver.out 2>&1 &
    echo started" >/dev/null 2>&1

# Poll. A poll loop with no delay is not a wait.
DEADLINE=$(( $(date +%s) + 7200 ))
LAST_SIZE=-1
STALL_TICKS=0
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
    # That is reported, never silently tolerated: a wedged install and a slow
    # one look identical from here and the difference matters.
    if [[ "$STALL_TICKS" -ge 40 ]]; then
        say ""
        say "STALLED: the driver is alive but the log has not grown in 20 minutes."
        say "Reporting on what exists. This is not a completed run."
        break
    fi
    if [[ "$(date +%s)" -ge "$DEADLINE" ]]; then
        say ""
        say "DEADLINE: 2 hours elapsed and the driver is still running."
        say "Reporting on what exists. This is not a completed run."
        break
    fi
done

say "finished $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

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
