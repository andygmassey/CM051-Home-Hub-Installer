#!/usr/bin/env bash
#
# tests/test_launchagent_refusal_reason_is_recorded.sh
#
# _ostler_launchagent_load_verified is the function that stopped the installer
# lying about LaunchAgents (#876: "Ostler Doctor running at localhost:8089"
# printed while the label was not loaded and the port answered 000). It works.
# It returns 1 and the caller warns.
#
# WHAT IT COULD NOT DO WAS SAY WHY. Both load attempts ran under `2>/dev/null`,
# so launchd's refusal -- the only artefact that knows the answer -- went to
# the bit bucket. Measured on the Mini 16, 2026-09-04: com.ostler.doctor was
# absent from launchctl and :8089 answered 000; bootstrapping the SAME
# unmodified plist by hand 21 minutes later gave `state = running` and a 200.
# Plist fine, payload fine, and the diagnosis cost a second full install.
#
# So the contract this test enforces is narrow and behavioural:
#
#   a REFUSED load must leave launchd's own words in the logs directory,
#   and a SUCCESSFUL load must leave nothing at all.
#
# HOW IT RUNS ANYWHERE. It does not need launchd. The two functions are
# EXTRACTED FROM install.sh (never restated -- a hand-copied body would be a
# second artefact with one consumer, and would keep passing after the real one
# changed) and driven against a `launchctl` stub on PATH. The stub reproduces
# the two behaviours this file has measured on macOS and records in its own
# comments: `load` EXITS 0 ON FAILURE, and `print` exits non-zero when the
# label is not registered.
#
# ⚠️ STATED LIMIT: this proves the plumbing carries the reason, not that any
# particular launchd refusal is correctly worded. Only a real box can say that.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${REPO_ROOT}/install.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
rc=0

[[ -f "$INSTALLER" ]] || fail "install.sh not found at ${INSTALLER}"

# BSD-only `mktemp -d -t NAME` (no X's) is refused by GNU coreutils, which
# leaves the variable EMPTY and sends every write to /. Two tests in this
# directory shipped with exactly that bug.
WORK="$(mktemp -d 2>/dev/null || mktemp -d -t ostler-launchagent)"
[[ -n "$WORK" && -d "$WORK" ]] || fail "mktemp produced no directory. CANNOT-RUN."
trap 'rm -rf "$WORK"' EXIT

# ── Extract the real functions ────────────────────────────────────
#
# From the helper's definition through the SECOND column-0 `}`, which closes
# _ostler_launchagent_load_verified. Every `}` inside either body is indented,
# so the anchor cannot land early.
SRC="${WORK}/extracted.sh"
#
# Stop at the brace that closes load_verified SPECIFICALLY, not at "the Nth
# brace": a helper added between them silently truncated this extraction the
# first time, and a truncated body defines fewer functions while still looking
# like a successful extract.
awk '
    /^_ostler_launchagent_note_refusal\(\) \{/   { f = 1 }
    f                                            { print }
    f && /^_ostler_launchagent_load_verified\(\) \{/ { inlv = 1 }
    inlv && /^\}$/                               { exit }
' "$INSTALLER" > "$SRC"

# PREMISE GUARD. If the extraction missed, every arm below would exercise
# nothing and report success. That is CANNOT-RUN, not a pass.
for _need in '_ostler_launchagent_note_refusal()' \
             '_ostler_launchagent_keeps_alive()' \
             '_ostler_launchagent_load_verified()' \
             'launchctl bootstrap' \
             'launchctl print'; do
    grep -qF -- "$_need" "$SRC" || fail "extraction did not capture '${_need}'.
      The functions moved or were renamed in install.sh. CANNOT-RUN."
done

# ── The launchctl stub ────────────────────────────────────────────
#
# REFUSAL_TOKEN is a POSITIVE control: a value the test must FIND. It is
# fixture text, never a real launchd string, so a hit cannot be a coincidence.
REFUSAL_TOKEN="STUB-LAUNCHD-REFUSED-THIS-BOOTSTRAP"
STUBDIR="${WORK}/bin"
mkdir -p "$STUBDIR"
cat > "${STUBDIR}/launchctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    bootout) exit 0 ;;                       # no-op on an unloaded label
    bootstrap)
        [[ "${STUB_LOAD_OK:-0}" == "1" ]] && exit 0
        echo "Bootstrap failed: 5: ${STUB_REFUSAL_TOKEN}" >&2
        exit 5
        ;;
    load)
        # Faithful to the measured macOS behaviour this installer documents:
        # `launchctl load` prints its failure to stderr and EXITS 0. If this
        # stub exited non-zero the test would be easier and wrong.
        [[ "${STUB_LOAD_OK:-0}" == "1" ]] && exit 0
        echo "Load failed: 5: ${STUB_REFUSAL_TOKEN}" >&2
        exit 0
        ;;
    print)
        case "${STUB_PRINT_MODE:-absent}" in
            running)
                printf '\tstate = running\n\tlast exit code = (never exited)\n'
                exit 0 ;;
            parked)
                printf '\tstate = spawn scheduled\n\tlast exit code = 78: EX_CONFIG\n'
                exit 0 ;;
            notrunning)
                # Registered, not parked on 78, and NOT RUNNING. This is the
                # state the Doctor was actually in on the walk box.
                printf '\tstate = not running\n\tlast exit code = 0\n'
                exit 0 ;;
            *)  echo "Could not find service in domain" >&2
                exit 113 ;;
        esac
        ;;
esac
exit 0
STUB
chmod +x "${STUBDIR}/launchctl"

export STUB_REFUSAL_TOKEN="$REFUSAL_TOKEN"
PATH="${STUBDIR}:${PATH}"

# A plist that exists, so the absent-file arm does not fire by accident.
PLIST="${WORK}/com.ostler.stubagent.plist"
printf '<?xml version="1.0"?>\n<plist version="1.0"><dict/></plist>\n' > "$PLIST"

LOGS_DIR="${WORK}/logs"
DIAG="${LOGS_DIR}/launchagent-load.log"
export LOGS_DIR

# shellcheck disable=SC1090
source "$SRC"

diag_lines() { [[ -f "$DIAG" ]] && wc -l < "$DIAG" | tr -d ' ' || echo 0; }

# ── Arm 1: a refusal must carry launchd's own words ───────────────
STUB_LOAD_OK=0 STUB_PRINT_MODE=absent
export STUB_LOAD_OK STUB_PRINT_MODE
_ostler_launchagent_load_verified "$PLIST" && arm1_rc=0 || arm1_rc=$?

if [[ "$arm1_rc" -eq 0 ]]; then
    echo "FAIL arm 1: the label is not registered and the function returned 0."
    echo "     That is the #876 defect itself, not a reporting gap."
    rc=1
elif ! grep -qF -- "$REFUSAL_TOKEN" "$DIAG" 2>/dev/null; then
    echo "FAIL arm 1: refusal recorded no reason. ${DIAG} does not contain the"
    echo "     stub's stderr. launchd's refusal is being discarded again --"
    echo "     check for a \`2>/dev/null\` on the bootstrap/load attempt."
    rc=1
else
    echo "ok   arm 1: a refused load records launchd's own stderr in ${DIAG##*/}"
fi

# ── Arm 2: EX_CONFIG parking is named as such ─────────────────────
: > "$DIAG"
STUB_LOAD_OK=1 STUB_PRINT_MODE=parked
export STUB_LOAD_OK STUB_PRINT_MODE
_ostler_launchagent_load_verified "$PLIST" && arm2_rc=0 || arm2_rc=$?

if [[ "$arm2_rc" -eq 0 ]]; then
    echo "FAIL arm 2: a job parked on EX_CONFIG was reported as loaded."
    rc=1
elif ! grep -qF -- "78" "$DIAG" 2>/dev/null; then
    echo "FAIL arm 2: parked on EX_CONFIG, but the record does not say so."
    rc=1
else
    echo "ok   arm 2: EX_CONFIG parking is refused AND named in the record"
fi

# ── Arm 3: THE CONTROL. Success must write nothing ────────────────
#
# Without this, a helper that logged unconditionally would pass arms 1 and 2
# while filling a healthy customer's logs with refusals that never happened.
: > "$DIAG"
STUB_LOAD_OK=1 STUB_PRINT_MODE=running
export STUB_LOAD_OK STUB_PRINT_MODE
_ostler_launchagent_load_verified "$PLIST" && arm3_rc=0 || arm3_rc=$?

if [[ "$arm3_rc" -ne 0 ]]; then
    echo "FAIL arm 3 control: a running, never-exited job was reported as failed"
    echo "     (rc=${arm3_rc}). The predicate refuses a healthy agent."
    rc=1
elif [[ "$(diag_lines)" -ne 0 ]]; then
    echo "FAIL arm 3 control: a SUCCESSFUL load wrote $(diag_lines) line(s) to"
    echo "     ${DIAG}. The record must only carry real refusals."
    rc=1
else
    echo "ok   arm 3 control: a successful load returns 0 and records nothing"
fi

# ── Arm 4: an absent plist is refused and said out loud ───────────
: > "$DIAG"
_ostler_launchagent_load_verified "${WORK}/nope.plist" && arm4_rc=0 || arm4_rc=$?
if [[ "$arm4_rc" -eq 0 ]]; then
    echo "FAIL arm 4: a plist that does not exist was reported as loaded."
    rc=1
elif ! grep -q 'plist absent' "$DIAG" 2>/dev/null; then
    echo "FAIL arm 4: absent plist refused, but the record does not name it."
    rc=1
else
    echo "ok   arm 4: an absent plist is refused and the reason is recorded"
fi

# ── Arm 5: KeepAlive + registered + NOT RUNNING must be refused ───
#
# THE #876 RECURRENCE, measured on the Mini 16 during ttywalk run 5. The
# installer printed "Ostler Doctor running at http://localhost:8089/doctor"
# and 254 lines later its own health check said "Doctor not responding".
# launchd had REGISTERED the label and never spawned the job -- doctor.err,
# which launchd creates on spawn, was never created at all. The old predicate
# refused only EX_CONFIG, so registered-and-idle sailed through.
KEEPALIVE_PLIST="${WORK}/com.ostler.keepalive.plist"
cat > "$KEEPALIVE_PLIST" <<'PL'
<?xml version="1.0"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.ostler.keepalive</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
PL

: > "$DIAG"
STUB_LOAD_OK=1 STUB_PRINT_MODE=notrunning
export STUB_LOAD_OK STUB_PRINT_MODE
_ostler_launchagent_load_verified "$KEEPALIVE_PLIST" && arm5_rc=0 || arm5_rc=$?

if [[ "$arm5_rc" -eq 0 ]]; then
    echo "FAIL arm 5: a KeepAlive agent that is registered but NOT RUNNING was"
    echo "     reported as loaded. That is #876 verbatim: the installer says"
    echo "     the Doctor is running while :8089 answers nothing."
    rc=1
elif ! grep -q 'KeepAlive' "$DIAG" 2>/dev/null; then
    echo "FAIL arm 5: refused, but the record does not say it was the"
    echo "     KeepAlive/never-ran rule. A refusal that cannot be attributed"
    echo "     costs another install to diagnose."
    rc=1
else
    echo "ok   arm 5: KeepAlive + registered + not running is REFUSED and named"
fi

# ── Arm 6: THE CONTROL FOR ARM 5 ──────────────────────────────────
#
# The same KeepAlive plist, actually running, must still pass and record
# nothing. Without this, arm 5 is satisfied by a predicate that refuses every
# KeepAlive agent -- which would take the whole install down instead.
: > "$DIAG"
STUB_LOAD_OK=1 STUB_PRINT_MODE=running
export STUB_LOAD_OK STUB_PRINT_MODE
_ostler_launchagent_load_verified "$KEEPALIVE_PLIST" && arm6_rc=0 || arm6_rc=$?

if [[ "$arm6_rc" -ne 0 ]]; then
    echo "FAIL arm 6 control: a KeepAlive agent in 'state = running' was refused"
    echo "     (rc=${arm6_rc}). The new rule refuses healthy agents."
    rc=1
elif [[ "$(diag_lines)" -ne 0 ]]; then
    echo "FAIL arm 6 control: a running KeepAlive agent wrote $(diag_lines) line(s)."
    rc=1
else
    echo "ok   arm 6 control: a RUNNING KeepAlive agent passes and records nothing"
fi

[[ "$rc" -eq 0 ]] && echo "PASS: tests/test_launchagent_refusal_reason_is_recorded.sh"
exit "$rc"
