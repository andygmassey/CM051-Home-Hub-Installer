#!/usr/bin/env bash
# An optional source that was never given its input must not fail the install.
#
# WHY THIS EXISTS. MEASURED on Andy's Mini during the v1.0.63 walk,
# 2026-09-04. Every probe inside the final step logged healthy -- Qdrant,
# Oxigraph, Redis, Ollama, pairing, Doctor, assistant API, wiki, Vane -- and
# the step still closed as:
#
#     STEP_END id=health_check status=error elapsed_s=28 rc=2
#     DONE status=ok failed_steps=1 errors=0
#
# The 2 came from the AI-conversations producer. USER_EMAIL is read from the
# macOS me-card via osascript; on a Mac where Contacts has never been opened
# that call returns "Application isn't running. (-600)", so the address is
# empty and cm052.cli refuses. Re-measured against the installed binary on
# that same box:
#
#     CM052_USER_EMAIL="" pwg-ai-convo --source all --json   -> exit 2
#     CONTROL, same binary:  pwg-ai-convo --help             -> exit 0
#
# so the 2 is specific to the missing address and not a broken venv. The
# drain ran anyway, and its rc was folded into the shared step recorder.
#
# v1.0.64 fixed the OTHER half: it stopped registering an hourly agent that
# could only fail. But that guard sits BELOW the fold, so the drain still ran
# and health_check still reddened. This test exists because half a fix reads
# exactly like a whole one from the commit message.
#
# WHY IT IS A RUNTIME TEST AND NOT A GREP. The defect is an ORDERING between
# a guard and a fold, and both were present in the tree that shipped it. No
# pattern over the source distinguishes "guarded above the fold" from
# "guarded below it"; only executing the block does. So this extracts the
# real block from install.sh and runs it against a stub producer that exits 2.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run. A check that could not run has
# not passed.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }

WORK="$(mktemp -d)" || { echo "CANNOT-RUN: could not create a working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# ── Extract the real drain block from a tree ──────────────────────────────
# From the heartbeat that opens the drain through the fold that closes it.
# Both markers were confirmed to appear exactly once in every tree this test
# reads. Returns 2 (cannot-run) if the block is not found, so a renamed
# marker reports as unmeasured rather than as a pass.
_extract_block() {
    local file="$1"
    awk '
        index($0, "_hydrate_heartbeat_start \"$MSG_HYDRATE_AICONV_HEARTBEAT\"") { f=1 }
        f { print }
        index($0, "gui_step_record_rc \"$_aiconv_rc\"") { if (f) exit }
    ' "$file"
}

# The owner-email predicate, if the tree has one. Trees that predate it have
# the condition written inline instead, and the extracted block carries it.
_extract_helper() {
    local file="$1"
    awk '/^_aiconv_owner_email_known\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$file"
}

# ── Run the extracted block with a stub producer ──────────────────────────
# Prints "<recorded_rc> <ran|notrun>", or nothing on a harness failure.
#
# USER_EMAIL is set to a NON-EMAIL token on the populated arm on purpose.
# The property under test is "non-empty", which is all the guard inspects,
# and a literal address in a committed fixture is a rule-zero violation for
# no gain.
_run_block() {
    local file="$1" owner_email="$2" run="${WORK}/run"
    rm -rf "$run"; mkdir -p "$run" || return 2

    local block; block="$(_extract_block "$file")" || return 2
    [ -n "$block" ] || return 2
    printf '%s' "$block" | grep -qF 'gui_step_record_rc "$_aiconv_rc"' || return 2

    cat > "${run}/stub-producer" <<'STUB'
#!/usr/bin/env bash
# Stands in for pwg-ai-convo. Records that it was invoked, then refuses with
# the code the real binary was measured to return on an empty owner email.
: > "${STUB_RAN_MARKER}"
echo "stub: refusing, no owner address" >&2
exit 2
STUB
    chmod +x "${run}/stub-producer" || return 2

    {
        printf '%s\n' 'set -Eeuo pipefail'
        printf 'USER_EMAIL=%s\n' "$(printf '%q' "$owner_email")"
        printf 'HOME=%s\n' "$(printf '%q' "$run")"
        printf 'STUB_RAN_MARKER=%s\n' "$(printf '%q' "${run}/producer_ran")"
        printf 'export STUB_RAN_MARKER\n'
        printf '_AICONV_OUT=%s\n' "$(printf '%q' "${run}/out.json")"
        printf '_AICONV_LOG=%s\n' "$(printf '%q' "${run}/aiconv.log")"
        printf '_AICONV_BIN=%s\n' "$(printf '%q' "${run}/stub-producer")"
        printf '%s\n' '_AICONV_TIMEOUT_WRAP=""'
        printf '%s\n' '_AICONV_TIMED_OUT=false'
        printf '%s\n' 'MSG_HYDRATE_AICONV_HEARTBEAT="heartbeat"'
        printf '%s\n' '_hydrate_heartbeat_start() { :; }'
        printf '%s\n' '_hydrate_heartbeat_stop() { :; }'
        printf '%s\n' 'warn() { :; }'
        printf '%s\n' 'info() { :; }'
        printf 'gui_step_record_rc() { printf %s "$1" > %s; }\n' \
            "'%s\n'" "$(printf '%q' "${run}/recorded_rc")"
        _extract_helper "$file"
        printf '%s\n' "$block"
    } > "${run}/harness.sh"

    bash "${run}/harness.sh" >/dev/null 2>&1
    [ -f "${run}/recorded_rc" ] || return 2

    local rc ran
    rc="$(cat "${run}/recorded_rc")"
    if [ -f "${run}/producer_ran" ]; then ran=ran; else ran=notrun; fi
    printf '%s %s\n' "$rc" "$ran"
}

# ── Subject: this tree ────────────────────────────────────────────────────
echo "── subject: this tree ──"

_r="$(_run_block "$SUBJECT" "")" || {
    echo "CANNOT-RUN: the drain block could not be extracted or executed from ${SUBJECT}." >&2
    echo "  A harness that did not run must not read as a passing test." >&2
    exit 2
}
case "$_r" in
    "0 notrun") ok "empty owner email: the producer is not invoked and rc 0 is folded, so health_check stays green" ;;
    "0 ran")    bad "empty owner email: rc 0 was folded, but the producer RAN. It cannot succeed without an address; skip it." ;;
    "2 "*)      bad "empty owner email: rc 2 folded into the step recorder. This is the v1.0.63 defect -- the install ends failed_steps=1 with every probe healthy." ;;
    *)          bad "empty owner email: unexpected harness result '${_r}'" ;;
esac

# ── NEGATIVE CONTROL ON MY OWN FIX ────────────────────────────────────────
# The fold must SURVIVE for a producer that was genuinely given its input and
# genuinely failed. Deleting the fold would make the limb above pass and would
# hide every real AI-conversations failure, so this limb is what stops that
# being the cheap way to green.
_r="$(_run_block "$SUBJECT" "owner-address-present")" || {
    echo "CANNOT-RUN: the populated-owner arm could not be executed." >&2
    exit 2
}
case "$_r" in
    "2 ran") ok "owner email present: the producer runs and its rc 2 is still folded, so a real failure is still reported" ;;
    "0 "*)   bad "owner email present: rc 0 folded. The fold has been neutered -- a genuine producer failure would now be silent." ;;
    *"notrun") bad "owner email present: the producer was NOT invoked. The guard is too wide; it is skipping the drain on a Mac that has an address." ;;
    *)       bad "owner email present: unexpected harness result '${_r}'" ;;
esac

# ── ONE VALUE, TWO CONSUMERS ──────────────────────────────────────────────
# The drain guard and the LaunchAgent guard must consult the SAME predicate.
# v1.0.63 shipped a neighbouring block where the step counter read the raw
# variable while the guard read the resolver (#1427); this is that class.
if grep -qF '_aiconv_owner_email_known() {' "$SUBJECT"; then
    _uses="$(grep -cF '_aiconv_owner_email_known;' "$SUBJECT")"
    if [ "$_uses" -ge 2 ]; then
        ok "both the drain and the LaunchAgent registration read one predicate (${_uses} call sites)"
    else
        bad "only ${_uses} call site reads _aiconv_owner_email_known -- the two guards can drift apart again"
    fi
else
    bad "no _aiconv_owner_email_known predicate: the owner-email condition is written out more than once"
fi

# ── NEGATIVE CONTROLS, pinned to trees that CARRY the defect ──────────────
# Pinned to fixed shas, never a moving branch: a control that reads
# origin/main inverts the moment this fix merges and then passes forever.
#   45126e9a  the v1.0.63 cut -- the blob that shipped to the Mini and
#             produced the measured `status=error rc=2`.
#   deecd9fc  this fix's own parent -- proves the defect SURVIVED v1.0.64,
#             whose guard addressed only the LaunchAgent half.
for _CONTROL_SHA in 45126e9a deecd9fc; do
    echo "── negative control: ${_CONTROL_SHA} ──"
    _ctl="${WORK}/control-${_CONTROL_SHA}.sh"
    if ! git -C "$REPO" cat-file -e "${_CONTROL_SHA}:install.sh" 2>/dev/null; then
        git -C "$REPO" fetch --depth=1 origin "$_CONTROL_SHA" >/dev/null 2>&1 || true
    fi
    if ! git -C "$REPO" show "${_CONTROL_SHA}:install.sh" > "$_ctl" 2>/dev/null; then
        echo "CANNOT-RUN: control blob ${_CONTROL_SHA}:install.sh is unreadable." >&2
        echo "  A shallow clone cannot see it. Scanning nothing must not read" >&2
        echo "  as a passing control." >&2
        exit 2
    fi
    _r="$(_run_block "$_ctl" "")" || {
        echo "CANNOT-RUN: the drain block could not be executed from control ${_CONTROL_SHA}." >&2
        exit 2
    }
    case "$_r" in
        "2 ran") ok "control ${_CONTROL_SHA}: correctly reproduces rc 2 folded from a producer that could not succeed" ;;
        "0 "*)   bad "control ${_CONTROL_SHA}: reports rc 0. That tree DID redden health_check on a real install, so the harness is measuring something other than the defect." ;;
        *)       bad "control ${_CONTROL_SHA}: unexpected harness result '${_r}'" ;;
    esac
done

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
