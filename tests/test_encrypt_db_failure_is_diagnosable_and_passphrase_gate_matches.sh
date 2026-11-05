#!/bin/bash
# encrypt_db must not abort mute, and Phase 2 must not accept a passphrase
# that Phase 3.6 will refuse.
#
# WHY. An F&F tester's install (v1.0.118, macOS 27, 29 Oct 2026) aborted at
# encrypt_db with ERR-99-INSTALL-ABORT-L18321. The python error text was never
# in the log or the support email, for two reasons this test pins:
#
#   1. `SETUP_OUTPUT=$(... python -c ... 2>&1)` ran with the ERR trap armed
#      under `set -E`. A non-zero exit fired the trap in the child and then in
#      the parent, which aborted BEFORE `SETUP_EXIT=$?`. The branch that
#      prints SETUP_OUTPUT (and raises the curated ERR-09-PASSKEY-SETUP) was
#      unreachable.
#   2. Phase 2 accepted any passphrase of 12+ characters, and the customer
#      copy said "At least 12 characters". setup_passphrase() runs
#      validate_passphrase_strength, which needs 16+ characters (or 4+ words
#      of 4+). 12 to 15 characters was accepted at the question and refused
#      40 minutes later, after every question had been answered. Reproduced
#      with the verbatim v1.0.118 python block and a 13-character synthetic
#      passphrase: rc=1 "Passphrase must be at least 16 characters".
#
# Every arm runs the REAL lines of install.sh, cut out by content, under the
# shell the installer ships under (/bin/bash 3.2). Only gui_read, warn, ok,
# fail_with_code, the ERR handler body and (arm A) the python are stubbed.
#
#   A  setup python FAILS: its error text reaches stdout (the log the support
#      email carries), ERR-09-PASSKEY-SETUP is raised, no ERR-99 abort.
#   A0 control, setup python SUCCEEDS: no ERR-09, no abort, and the ERR trap
#      is re-armed byte-identical afterwards.
#   B  Phase 2 gate with the REAL validator: a 13-char passphrase is refused
#      at the question, and the passphrase finally captured passes the same
#      validate_passphrase_strength that setup_passphrase() runs.
#   C  a 16-char "too simple" passphrase is refused at the question too.
#   D  validator cannot run (python is /usr/bin/false): its 16-char floor
#      still applies, so 13 chars is refused, 17 accepted.
#   E  re-run / upgrade with keychain.json on disk: no prompt, no validator
#      call, the skip is taken, so an existing passphrase is never re-judged.
#   F  unlock() with an existing 13-char passphrase (config minted with the
#      validator bypassed; synthetic) still returns the key.
#      OSTLER_TEST_VENDOR points F at another vendor tree (mutation runs).
#
# RED: `bash $0 <path-to-old-install.sh>` runs every arm against another copy.
# On origin/main before this change, A and B fail (and C, D).
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${REPO}/install.sh}"
STRINGS="${REPO}/install.sh.strings.en-GB.sh"
PY="${OSTLER_TEST_PYTHON:-python3}"
[ -f "$SRC" ] || { echo "CANNOT-RUN: no install.sh at $SRC"; exit 2; }
[ -f "$STRINGS" ] || { echo "CANNOT-RUN: no strings at $STRINGS"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/encdb-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS+1)); }
echo "shell: $BASH_VERSION  subject: $SRC"

# The real validator, imported from the vendored package the DMG ships.
cat > "$WORK/real_python" <<EOF
#!/bin/bash
PYTHONPATH="${REPO}/vendor" exec "${PY}" "\$@"
EOF
chmod +x "$WORK/real_python"
if ! "$WORK/real_python" -c 'from ostler_security.passphrase import validate_passphrase_strength' 2>"$WORK/import.err"; then
    echo "CANNOT-RUN: vendored validator does not import with ${PY}:"; cat "$WORK/import.err"; exit 2
fi
validator_accepts() {  # $1 passphrase -> rc 0 when the real validator accepts
    RP_CHECK="$1" "$WORK/real_python" -c 'import os,sys; from ostler_security.passphrase import validate_passphrase_strength as v; sys.exit(0 if v(os.environ["RP_CHECK"])[0] else 1)'
}
validator_accepts 'Tulip-river9x' && { echo "CANNOT-RUN: the validator accepts a 13-char passphrase; this test's premise moved"; exit 2; }
validator_accepts 'Lantern-orchid-47' || { echo "CANNOT-RUN: the validator refuses the 17-char control"; exit 2; }

# ── cut the real Phase 3.6 capture + failure branch ──────────────────────
s=$(/usr/bin/grep -n -F 'SETUP_OUTPUT=$(RECOVERY_PASSPHRASE_FOR_SETUP=' "$SRC" | head -1 | cut -d: -f1)
e=$(/usr/bin/grep -n -F 'fail_with_code "ERR-09-PASSKEY-SETUP"' "$SRC" | head -1 | cut -d: -f1)
TRAP_LINE="$(/usr/bin/grep -m1 -E "^trap '_ostler_on_err " "$SRC" || true)"
if [ -z "$s" ] || [ -z "$e" ] || [ "$e" -le "$s" ] || [ -z "$TRAP_LINE" ]; then
    echo "CANNOT-RUN: capture (${s:-?}), ERR-09 (${e:-?}) or the ERR trap line not found"; exit 2
fi
{ /usr/bin/sed -n "${s},${e}p" "$SRC"; echo "fi"; echo "fi"; } > "$WORK/setup.sh"
echo "setup block: lines ${s}-${e}"

run_setup() {  # $1 = stub python body; prints the run's stdout
    local d="$WORK/setup-$2"; mkdir -p "$d"
    printf '#!/bin/bash\n%s\n' "$1" > "$d/python"; chmod +x "$d/python"
    cat > "$d/run.sh" <<EOF
set -Eeuo pipefail
_ostler_on_err() { if [ "\${BASH_SUBSHELL:-0}" -gt 0 ]; then echo "SUBSHELL_TRAP"; return; fi; echo "ABORTED_ERR99"; exit 99; }
${TRAP_LINE}
warn() { echo "[warn] \$*"; }
fail_with_code() { echo "FAIL_WITH_CODE \$1"; exit 9; }
MSG_WARN_SECURITY_SETUP_FAILED_OUTPUT="setup failed, output:"
MSG_FAIL_PASSKEY_SETUP_FAILED_RE_RUN_WITH="re-run"
ALLOW_PLAINTEXT=0; SECURITY_CONFIG_DIR="$d/sec"
RECOVERY_PASSPHRASE='Lantern-orchid-47'
OSTLER_PYTHON="$d/python"
_before="\$(trap -p ERR)"
. "$WORK/setup.sh"
if [ "\$(trap -p ERR)" = "\$_before" ]; then echo "TRAP_REARMED"; else echo "TRAP_CHANGED"; fi
echo "END_REACHED"
EOF
    /bin/bash "$d/run.sh" 2>&1; echo "rc=$?"
}

# A: failure path
out="$(run_setup 'echo "ERROR=SYNTHETIC-SETUP-ERROR passphrase refused" >&2; exit 1' fail)"
echo "$out" | sed 's/^/    A| /'
if /usr/bin/grep -q -F 'SYNTHETIC-SETUP-ERROR' <<<"$out"; then pass "A: setup error text reaches stdout"; else fail "A: setup error text never printed"; fi
if /usr/bin/grep -q -F 'FAIL_WITH_CODE ERR-09-PASSKEY-SETUP' <<<"$out"; then pass "A: curated ERR-09-PASSKEY-SETUP raised"; else fail "A: ERR-09-PASSKEY-SETUP not raised"; fi
if /usr/bin/grep -q -F 'ABORTED_ERR99' <<<"$out"; then fail "A: ERR trap aborted the install (ERR-99) before SETUP_EXIT"; else pass "A: no ERR-99 abort"; fi

# A0: control, success path
out="$(run_setup 'echo "RECOVERY_PHRASE=SYNT-HETI-CKEY-0000-TEST-ONLY"; echo "DB_KEY_FILE=/nonexistent"; exit 0' ok)"
echo "$out" | sed 's/^/    A0| /'
if /usr/bin/grep -q -F 'END_REACHED' <<<"$out" && ! /usr/bin/grep -q -E 'FAIL_WITH_CODE|ABORTED_ERR99' <<<"$out"; then pass "A0: success path runs through"; else fail "A0: success path did not run through"; fi
if /usr/bin/grep -q -F 'TRAP_REARMED' <<<"$out"; then pass "A0: ERR trap re-armed unchanged"; else fail "A0: ERR trap not re-armed as before"; fi

# ── cut the real Phase 2 passphrase loop body ────────────────────────────
s=$(/usr/bin/grep -n -F 'RECOVERY_PASSPHRASE="$(gui_read "$MSG_PROMPT_RECOVERY_PASSPHRASE_TITLE"' "$SRC" | head -1 | cut -d: -f1)
e=$(/usr/bin/grep -n -F 'ok "$MSG_OK_RECOVERY_PASSPHRASE_CAPTURED_FOR_PHASE_3"' "$SRC" | head -1 | cut -d: -f1)
if [ -z "$s" ] || [ -z "$e" ] || [ "$e" -le "$s" ]; then echo "CANNOT-RUN: Phase 2 passphrase loop not found"; exit 2; fi
{ echo 'while true; do'; echo '    rp_help=""'; /usr/bin/sed -n "${s},${e}p" "$SRC"; echo '    break'; echo 'done'; } > "$WORK/gate.sh"
echo "gate block: lines ${s}-${e}"

run_gate() {  # $1 = python for OSTLER_PYTHON, $2.. = answers in order; prints CAPTURED=<value>
    local py="$1"; shift
    local d; d="$(mktemp -d "$WORK/gate.XXXX")"
    printf '%s\n' "$@" > "$d/answers"
    cat > "$d/run.sh" <<EOF
set -Eeuo pipefail
_ostler_on_err() { echo "ABORTED_ERR99"; exit 99; }
${TRAP_LINE}
. "$STRINGS"
warn() { echo "[warn] \$*"; }
ok() { :; }
# gui_read runs inside \$(...), so its counter lives in a file; running out
# of answers kills the WHOLE run (a refused-forever loop must not hang CI).
echo 0 > "$d/n"
gui_read() { local n; n=\$(( \$(cat "$d/n") + 1 )); echo "\$n" > "$d/n"; if [ "\$n" -gt $# ]; then echo "OUT_OF_ANSWERS" >&2; kill -TERM \$\$; fi; /usr/bin/sed -n "\${n}p" "$d/answers"; }
OSTLER_PYTHON="$py"; OSTLER_DIAG_DIR="$d"
RP_PASS_ERROR=""; RP_CONFIRM_ERROR=""
. "$WORK/gate.sh"
echo "CAPTURED=\${RECOVERY_PASSPHRASE}"
EOF
    /bin/bash "$d/run.sh" 2>&1
}
captured() { /usr/bin/sed -n 's/^CAPTURED=//p' <<<"$1" | tail -1; }

# B: 13 chars twice, then a valid one
out="$(run_gate "$WORK/real_python" 'Tulip-river9x' 'Tulip-river9x' 'Lantern-orchid-47' 'Lantern-orchid-47')"
c="$(captured "$out")"
if [ -n "$c" ] && validator_accepts "$c"; then pass "B: captured passphrase passes setup_passphrase's validator (${#c} chars)"; else fail "B: Phase 2 captured a ${#c}-char passphrase that setup_passphrase() refuses"; fi
TOO_SHORT_MSG="$( . "$STRINGS" >/dev/null 2>&1; printf '%s' "${MSG_WARN_RECOVERY_PASSPHRASE_TOO_SHORT:-}")"
if [ -n "$TOO_SHORT_MSG" ] && /usr/bin/grep -q -F "[warn] ${TOO_SHORT_MSG}" <<<"$out"; then pass "B: the customer is told why at the question"; else fail "B: no too-short warning at the question"; fi

# C: 16 chars but too simple
out="$(run_gate "$WORK/real_python" 'abababababababab' 'abababababababab' 'Lantern-orchid-47' 'Lantern-orchid-47')"
c="$(captured "$out")"
if [ "$c" = 'Lantern-orchid-47' ]; then pass "C: a 16-char too-simple passphrase is refused at the question"; else fail "C: captured '${c}'"; fi

# D: validator cannot run, 16-char floor still applies
out="$(run_gate /usr/bin/false 'Tulip-river9x' 'Lantern-orchid-47' 'Lantern-orchid-47')"
c="$(captured "$out")"
if [ "$c" = 'Lantern-orchid-47' ]; then pass "D: validator unavailable, 13 chars still refused, 17 accepted"; else fail "D: captured '${c}'"; fi

# ── E: an EXISTING install is never re-validated on a re-run / upgrade ────
# Cut the real Phase 2 security chain, from the "already configured" test to
# its closing fi, and run it with a keychain.json on disk. A recording python
# and a recording gui_read prove nothing is asked and nothing is validated.
s=$(/usr/bin/grep -n -F 'if [[ -f "${SECURITY_CONFIG_DIR}/passkey.json" || -f "${SECURITY_CONFIG_DIR}/keychain.json" ]]; then' "$SRC" | head -1 | cut -d: -f1)
[ -n "$s" ] || { echo "CANNOT-RUN: Phase 2 re-run check not found"; exit 2; }
e=$(/usr/bin/awk -v s="$s" 'NR>s && /^fi$/ {print NR; exit}' "$SRC")
/usr/bin/sed -n "${s},${e}p" "$SRC" > "$WORK/chain.sh"
echo "chain block: lines ${s}-${e}"
d="$WORK/rerun"; mkdir -p "$d/sec"
echo '{"version": 2}' > "$d/sec/keychain.json"    # synthetic: an earlier install's config
printf '#!/bin/bash\necho "PYTHON_CALLED" >> "%s/calls"\necho "Passphrase must be at least 16 characters"\n' "$d" > "$d/python"; chmod +x "$d/python"
cat > "$d/run.sh" <<RUNEOF
set -Eeuo pipefail
_ostler_on_err() { echo "ABORTED_ERR99"; exit 99; }
${TRAP_LINE}
. "$STRINGS"
warn() { echo "[warn] \$*"; }; ok() { :; }; info() { :; }
fail_with_code() { echo "FAIL_WITH_CODE \$1"; exit 9; }
gui_read() { echo "GUI_READ_CALLED" >> "$d/calls"; kill -TERM \$\$; }
gui_emit() { :; }; gui_log() { :; }
SECURITY_CONFIG_DIR="$d/sec"; HAS_SECURITY_MODULE=true; PASSKEY_PRIMED=false; SECURITY_PREEXISTED=false
OSTLER_PYTHON="$d/python"; OSTLER_DIAG_DIR="$d"; ALLOW_PLAINTEXT=0; SCRIPT_DIR="$d"
RP_PASS_ERROR=""; RP_CONFIRM_ERROR=""
. "$WORK/chain.sh"
echo "PASSKEY_PRIMED=\$PASSKEY_PRIMED SECURITY_PREEXISTED=\$SECURITY_PREEXISTED HAS_SECURITY_MODULE=\$HAS_SECURITY_MODULE"
RUNEOF
out="$(/bin/bash "$d/run.sh" 2>&1)"
calls="$(cat "$d/calls" 2>/dev/null || true)"
if [ -z "$calls" ]; then pass "E: re-run with keychain.json: no prompt, no validator call"; else fail "E: re-run touched the passphrase: $(echo "$calls" | tr '\n' ' ')"; fi
if /usr/bin/grep -q -F 'PASSKEY_PRIMED=false SECURITY_PREEXISTED=true HAS_SECURITY_MODULE=false' <<<"$out"; then pass "E: re-run takes the skip, so Phase 3.6 setup_passphrase never runs"; else fail "E: re-run did not take the skip: $(tail -1 <<<"$out")"; fi

# ── F: unlock() never re-validates an existing passphrase ────────────────
# A config minted under a 13-char passphrase (validator bypassed via the
# locked writer; synthetic) must still unlock with it. ostler-unlock, the
# services and the Hub start go through unlock(); only setup_passphrase()
# and change_passphrase()'s NEW passphrase validate (passphrase.py:298, :705).
cat > "$WORK/f.py" <<'PYEOF'
import sys
from pathlib import Path
from ostler_security import passphrase as p
d = Path(sys.argv[1]); d.mkdir(parents=True, exist_ok=True); d.chmod(0o700)
short = "Tulip-river9x"
p._setup_passphrase_locked(short, d)
try:
    k = p.unlock(short, config_dir=d)
    print("UNLOCK_OK", len(k))
except Exception as e:
    print("UNLOCK_REFUSED", type(e).__name__, e)
PYEOF
FOUT="$(PYTHONPATH="${OSTLER_TEST_VENDOR:-${REPO}/vendor}" "${PY}" "$WORK/f.py" "$WORK/fsec" 2>&1)"
if /usr/bin/grep -q '^UNLOCK_OK 32$' <<<"$FOUT"; then pass "F: an existing 13-char passphrase still unlocks"; else fail "F: unlock refused an existing short passphrase: $FOUT"; fi

echo "----"
if [ "$FAILS" -eq 0 ]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL (${FAILS})"; exit 1
