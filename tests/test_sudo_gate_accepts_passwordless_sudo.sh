#!/bin/bash
# The sudo pre-flight must ACCEPT a Mac where sudo already works without a
# password, and must still REFUSE a Mac where it does not work at all.
#
# THE DEFECT THIS CLOSES, measured on the 2026-08-29 box walk (sudo 1.9.17p2).
# The gate was a bare `sudo -v`. On an admin account carrying BOTH the admin
# group's `(ALL) ALL` and an operator NOPASSWD grant:
#
#     sudo -n true       rc=0     every privileged call in Phase 3 is fine
#     sudo -n pmset -g   rc=0     the exact call the gate exists to protect
#     sudo -n -v         rc=1     "sudo: a password is required"
#
# `sudo -v` asks "would this user EVER have to authenticate", which is a
# broader question than the install needs. With both entries present the answer
# is yes, so it prompted, three attempts failed, and the install died on
# ERR-04-SUDO-DENIED without ever attempting the thing it wanted to do. The
# gate refused an environment strictly MORE permissive than the one it accepts.
#
# THIS TEST IS BEHAVIOURAL, NOT A GREP. Asserting "the file contains
# `sudo -n true`" would pass on a line inside a comment, or on a call whose
# result is discarded. Instead the gate block is lifted out of install.sh and
# RUN against a fake `sudo` that reproduces each environment exactly.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"

PASS=0; FAIL=0; CANT=0
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
# Three outcomes, three branches (#1239): a check that could not run has not
# passed, but it is not the product failing either.
cant() { printf '  [CANNOT-RUN] %s\n' "$*"; CANT=$((CANT+1)); }

[ -r "${INSTALL_SH}" ] || { cant "install.sh unreadable at ${INSTALL_SH}"
    echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }

# ── lift the gate ────────────────────────────────────────────────────
# EXACTLY the `if sudo -n true ... fi` block and nothing else. Comments are
# stripped so a `sudo -v` mentioned in prose cannot satisfy or break an arm.
#
# The first version of this used a sed range ending in `$`, which lifted 7996
# lines -- the whole remainder of install.sh. Three arms then "passed" while
# executing eight thousand lines of installer in a subshell, which is not the
# subject and proves nothing about it. A lift that is not bounded is not a
# lift, so the size is asserted below and the arm refuses if it is implausible.
# THE LIFT MUST ALSO FIND THE OLD SHAPE, or this test can only confirm that
# the fix is present and can never accuse the defect. Anchoring solely on
# `if sudo -n true` made a revert report CANNOT-RUN: honest, still non-zero,
# but it is not a finding. So: take the if/fi block when it exists, otherwise
# take the bare `sudo -v || fail_with_code` line that preceded it. Either way
# arm 1 runs the REAL gate against a passwordless environment, and the old
# shape fails it, which is the accusation this file exists to make.
GATE="$(awk '
    /^    if sudo -n true/ { inblk = 1 }
    inblk                  { print }
    inblk && /^    fi$/    { exit }
' "${INSTALL_SH}" | /usr/bin/sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d')"

if [ -z "${GATE}" ]; then
    GATE="$(/usr/bin/grep -E '^[[:space:]]*sudo -v \|\| fail_with_code "ERR-04-SUDO-DENIED"' "${INSTALL_SH}" \
            | /usr/bin/sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d')"
fi

GATE_LINES=$(printf '%s\n' "${GATE}" | /usr/bin/grep -c . || true)
if [ -z "${GATE}" ]; then
    cant "arm 0: could not lift the sudo gate out of install.sh"
    echo "== ${PASS} pass / ${FAIL} fail / 1 cannot-run =="
    exit 2
elif [ "${GATE_LINES}" -gt 20 ]; then
    # A correct lift is ~6 lines. Anything large means the range ran away and
    # every downstream arm would be measuring the wrong thing.
    cant "arm 0: lift ran away -- ${GATE_LINES} lines, expected under 20. Refusing to test the wrong subject."
    echo "== ${PASS} pass / ${FAIL} fail / 1 cannot-run =="
    exit 2
fi
ok "arm 0: lifted the sudo gate, ${GATE_LINES} lines (bounded, comments stripped)"

# ── the harness ──────────────────────────────────────────────────────
# Runs the lifted gate with a fake `sudo` first on PATH. Never touches the
# real sudo: the shim lives in a private mktemp dir and PATH is restored by
# the subshell exiting.
run_gate_with_sudo() {
    local behaviour="$1"
    local dir; dir="$(mktemp -d "${TMPDIR:-/tmp}/sudogate-XXXXXX")"
    cat > "${dir}/sudo" <<SHIM
#!/bin/bash
# Fake sudo. behaviour=${behaviour}
case "\$*" in
  "-n true")  [ "${behaviour}" = "none" ] && exit 1 || exit 0 ;;
  "-v")       [ "${behaviour}" = "interactive" ] && exit 0 || exit 1 ;;
  *)          exit 0 ;;
esac
SHIM
    chmod 755 "${dir}/sudo"
    (
        PATH="${dir}:${PATH}"
        info() { :; }
        fail_with_code() { printf 'FAILED:%s\n' "$1"; exit 4; }
        # The gate's failure arm expands an installer string that does not
        # exist out here. Under `set -u` that aborted the subshell BEFORE
        # fail_with_code could print, so the NEGATIVE control returned empty
        # and read as "the gate did not refuse" -- when in fact the harness
        # died first. Arms 1 and 2 never reach this branch, so only the
        # control saw it, which is exactly the arm you cannot afford to have
        # lying. Bind it to a placeholder: we assert control flow, not copy.
        MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL="<message under test is irrelevant>"
        eval "${GATE}"
        printf 'PASSED\n'
    ) 2>/dev/null
    local rc=$?
    rm -rf "${dir}"
    return $rc
}

# ── arm 1: THE DEFECT. passwordless sudo, `sudo -v` refuses. Must PASS. ──
OUT="$(run_gate_with_sudo passwordless)"
if [ "${OUT}" = "PASSED" ]; then
    ok "arm 1: passwordless sudo is ACCEPTED (sudo -n true rc=0, sudo -v rc=1)"
else
    bad "arm 1: passwordless sudo was REFUSED -- this is the walk-killer, output: ${OUT:-<empty>}"
fi

# ── arm 2: an ordinary customer. -n fails, the prompt succeeds. Must PASS. ──
OUT="$(run_gate_with_sudo interactive)"
if [ "${OUT}" = "PASSED" ]; then
    ok "arm 2: ordinary customer still accepted (sudo -n true rc=1, sudo -v rc=0)"
else
    bad "arm 2: an ordinary password-prompt customer is now refused, output: ${OUT:-<empty>}"
fi

# ── arm 3: NEGATIVE CONTROL. no sudo at all. Must FAIL with the code. ──
# Without this the gate could be made to pass by simply never refusing.
OUT="$(run_gate_with_sudo none)"
case "${OUT}" in
    FAILED:ERR-04-SUDO-DENIED)
        ok "arm 3: NEGATIVE control -- no sudo at all still fails ERR-04-SUDO-DENIED" ;;
    PASSED)
        bad "arm 3: the gate PASSED with no sudo available -- it refuses nothing" ;;
    *)
        bad "arm 3: expected ERR-04-SUDO-DENIED, got: ${OUT:-<empty>}" ;;
esac

# ── arm 4: the fallback is still REACHABLE, not dead code. ──
# arm 2 passing via `sudo -v` already proves the else-branch runs, but assert
# the ordering explicitly: -n must be tried FIRST, or a customer who would have
# been prompted once gets prompted anyway and nothing was gained.
FIRST="$(printf '%s' "${GATE}" | /usr/bin/grep -oE 'sudo -n true|sudo -v' | head -1)"
if [ "${FIRST}" = "sudo -n true" ]; then
    ok "arm 4: the non-interactive probe is tried FIRST"
else
    bad "arm 4: first sudo call in the gate is '${FIRST}', expected 'sudo -n true'"
fi

printf '\n== %d pass / %d fail / %d cannot-run ==\n' "${PASS}" "${FAIL}" "${CANT}"
[ "${CANT}" -eq 0 ] || printf '   NOTE: %d arm(s) COULD NOT RUN. Not a product failure, not a pass.\n' "${CANT}"
[ "${FAIL}" -eq 0 ] || exit 1
[ "${CANT}" -eq 0 ] || exit 2
