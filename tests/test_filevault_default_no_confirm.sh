#!/usr/bin/env bash
# FileVault-off install gate: a bare Enter must NEVER continue unencrypted.
#
# Before this change, install.sh asked one yes/no question with default "y"
# when FileVault was off, so pressing Enter continued with the disk
# unencrypted at rest. Now a second, default-NO confirmation
# ("Are you sure? This is a security risk.") is the real gate: the install
# proceeds only on an explicit yes to that second question.
#
# The gate block is extracted from install.sh BY MARKER (not grepped), run
# under bash with a stubbed gui_read that mirrors the TTY branch's default
# substitution, and its outcome is read from the side effect that only a
# passed gate produces: the filevault_ack.txt marker.
#
# Each "must not proceed" case has a positive control in the same run: the
# explicit "\ny\n" case MUST proceed, or the probe cannot detect proceeding
# and the absence assertions would pass against nothing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
INSTALL_SH="${REPO_ROOT}/install.sh"
STRINGS_DIR="${REPO_ROOT}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILED=$((FAILED + 1)); }

[[ -f "$INSTALL_SH" ]] || { printf 'FAIL: missing %s\n' "$INSTALL_SH" >&2; exit 1; }
bash -n "$INSTALL_SH"
pass "install.sh parses (bash -n)"

# ── 0. Every catalogue carries the new title (parity across languages) ──
CATALOGUES=0
MISSING_KEY=0
for cat in "${STRINGS_DIR}"/install.sh.strings.*.sh; do
    CATALOGUES=$((CATALOGUES + 1))
    if ! grep -qF 'MSG_PROMPT_FILEVAULT_CONFIRM_TITLE=' "$cat"; then
        MISSING_KEY=$((MISSING_KEY + 1))
        fail "$(basename "$cat") has no MSG_PROMPT_FILEVAULT_CONFIRM_TITLE"
    fi
done
if [[ "$CATALOGUES" -lt 10 ]]; then
    fail "found only ${CATALOGUES} catalogues -- the glob is broken, so the parity check checks nothing"
elif [[ "$MISSING_KEY" -eq 0 ]]; then
    pass "all ${CATALOGUES} string catalogues define MSG_PROMPT_FILEVAULT_CONFIRM_TITLE"
fi

# ── 1. Extract the FileVault-off gate block from install.sh by marker ──
GATE_START_MARK='FV_CONTINUE="$(gui_read "$MSG_PROMPT_FILEVAULT_SKIP_TITLE"'
GATE_END_MARK='filevault_ack.txt'
BLOCK="${TMP_ROOT}/gate_block.sh"
awk -v s="$GATE_START_MARK" -v e="$GATE_END_MARK" '
    index($0, s) && !started { started = 1 }
    started { print }
    started && index($0, e) { exit }
' "$INSTALL_SH" > "$BLOCK"

BLOCK_LINES="$(wc -l < "$BLOCK" | tr -d ' ')"
if [[ "$BLOCK_LINES" -lt 8 ]]; then
    fail "extracted only ${BLOCK_LINES} lines of gate block -- extractor broken, every case below would be vacuous"
    printf 'RESULT: %d failed\n' "$FAILED" >&2
    exit 1
fi
pass "extracted ${BLOCK_LINES} lines of FileVault gate (denominator is non-zero)"

# ── 2. Drive the block with a given stdin; report proceed / stop ──────
# gui_read stub: the TTY branch of install.sh's gui_read, minus the prompt
# printing. Same default substitution on an empty or EOF answer.
run_gate() {
    local input="$1" cfg="${TMP_ROOT}/cfg.$RANDOM$RANDOM"
    mkdir -p "$cfg"
    local driver="${TMP_ROOT}/driver.$RANDOM.sh"
    {
        printf 'gui_read() { local kind="${2:-text}" default_value="${3:-}" answer=""; read -r answer || true; [[ -z "$answer" && -n "$default_value" ]] && answer="$default_value"; printf "%%s" "$answer"; }\n'
        printf 'warn() { :; }\n'
        printf 'FV_STATUS="FileVault is Off"\n'
        printf 'SECURITY_CONFIG_DIR="%s"\n' "$cfg"
        printf 'MSG_PROMPT_FILEVAULT_SKIP_TITLE="x"; MSG_PROMPT_FILEVAULT_SKIP_HELP="x"\n'
        printf 'MSG_PROMPT_FILEVAULT_CONFIRM_TITLE="Are you sure? This is a security risk."\n'
        cat "$BLOCK"
    } > "$driver"
    local rc=0
    printf "$input" | bash "$driver" >/dev/null 2>&1 || rc=$?
    if [[ -f "${cfg}/filevault_ack.txt" ]]; then
        echo "PROCEEDED"
    else
        echo "STOPPED rc=${rc}"
    fi
}

# ── 3. Cases ─────────────────────────────────────────────────────────
# want=NOT_PROCEED: anything but a passed gate. want=PROCEED: the control.
check() {
    local label="$1" input="$2" want="$3" got
    got="$(run_gate "$input")"
    case "$want" in
        PROCEED)     [[ "$got" == "PROCEEDED" ]] && pass "${label} -> ${got}" || fail "${label} -> ${got} (want PROCEEDED)" ;;
        NOT_PROCEED) [[ "$got" != "PROCEEDED" ]] && pass "${label} -> ${got}" || fail "${label} -> ${got} (want it NOT to proceed)" ;;
    esac
}

# Bare Enter, one or two, must not proceed.
check "bare Enter, one ENTER"                      '\n'      NOT_PROCEED
check "bare Enter, two ENTERs"                     '\n\n'    NOT_PROCEED
# A single "y" must not proceed: the second question needs its own yes.
check "single y (second question left to default)" 'y\n'     NOT_PROCEED
check "explicit n at the first question"           'n\n'     NOT_PROCEED
check "Enter then n at the second question"        '\nn\n'   NOT_PROCEED
# CONTROL: the explicit double yes MUST proceed, or the probe cannot see a
# proceed and every NOT_PROCEED above is a pass over nothing.
check "CONTROL: Enter then explicit y"             '\ny\n'   PROCEED

if [[ "$FAILED" -eq 0 ]]; then
    echo "RESULT: 0 failed"
    exit 0
fi
printf 'RESULT: %d failed\n' "$FAILED" >&2
exit 1
