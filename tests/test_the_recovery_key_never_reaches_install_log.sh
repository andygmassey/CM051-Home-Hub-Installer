#!/bin/bash
# The recovery key must never be written to install.log, and the key in
# logs left by older installers must be redacted on upgrade.
#
# v1.0.109 BLOCKER. install.sh tees all stdout into ~/.ostler/logs/install.log,
# and the reveal echoed ${RECOVERY_KEY} to stdout, so every install.log, every
# support upload and every Time Machine copy of one held the key that unwraps
# the DEK. The keychain fallback also put the key on argv
# (`security add-generic-password -w <key>`), readable by ps.
#
# Every arm runs the REAL lines of install.sh, cut out by content, under the
# shell the installer ships under (/bin/bash 3.2). Nothing is re-typed here.
#
#   A  GUI=0: key reaches the terminal (fd 8) once, the log 0 times, and the
#      log carries "recovery key shown (24 chars)".
#   B  GUI=1: key reaches the marker fd (9) once, fd 8 0 times, the log 0.
#   C  upgrade scrub: a planted old install.log and a rotated install.log.1,
#      each holding a synthetic key: 1 -> 0 occurrences each; a control line
#      survives byte-identical; a second run redacts nothing more.
#   D  keychain save with swift FAILING (the path that reached the CLI
#      fallback): stub `security` and stub `swift` record "$@"; the key is in
#      no recorded argv.
#   E  keychain save with swift succeeding: the key reaches swift via env,
#      never argv.
#   F  ERR-09 setup-failure dump of SETUP_OUTPUT: RECOVERY_PHRASE= redacted,
#      the error line kept.
#
# RED: `bash $0 <path-to-old-install.sh>` runs every arm against another copy.
# On origin/main before this fix A, B, C, D and F fail (A: log holds the key once).
#
# Usage: tests/test_the_recovery_key_never_reaches_install_log.sh [install.sh]
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${REPO}/install.sh}"
[ -f "$SRC" ] || { echo "CANNOT-RUN: no install.sh at $SRC"; exit 2; }

KEY='SYNT-HETI-CKEY-0000-TEST-ONLY'   # synthetic, 29 chars; never a real key
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rk-log-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS+1)); }
count() { /usr/bin/grep -c -F -- "$1" "$2" 2>/dev/null || true; }

echo "shell: $BASH_VERSION  subject: $SRC"

# ── cut the real reveal block ────────────────────────────────────────────
start=$(/usr/bin/grep -n -F 'gui_emit RECOVERY_KEY "value=$RECOVERY_KEY"' "$SRC" | head -1 | cut -d: -f1)
[ -n "$start" ] || { echo "CANNOT-RUN: reveal (gui_emit RECOVERY_KEY) not found in $SRC"; exit 2; }
end=$(/usr/bin/awk -v s="$start" 'NR>s && /RECOVERY_KEY_DELIVERED=true/ {print NR; exit}' "$SRC")
[ -n "$end" ] || { echo "CANNOT-RUN: RECOVERY_KEY_DELIVERED=true not found after line $start"; exit 2; }
/usr/bin/sed -n "${start},$((end-1))p" "$SRC" > "$WORK/reveal.sh"
echo "reveal block: lines ${start}-$((end-1)) ($(/usr/bin/wc -l < "$WORK/reveal.sh" | tr -d ' ') lines)"

# The fd-8 dup, if the subject has one, taken from the file, not re-typed.
FD8_LINE="$(/usr/bin/grep -m1 -E '^exec 8>&1$' "$SRC" || true)"

run_reveal() {  # $1 = OSTLER_GUI
    local gui="$1" d="$WORK/reveal-gui$1"
    mkdir -p "$d"
    cat > "$d/run.sh" <<EOF
BOLD=''; NC=''; YELLOW=''; RED=''
RECOVERY_KEY='${KEY}'
OSTLER_GUI='${gui}'
gui_emit() { [ "\${OSTLER_GUI:-0}" = "1" ] || return 0; local k="\$1"; shift; printf '[gui-marker] %s %s\n' "\$k" "\$*" >&9; }
exec 9>>"$d/fd9"
exec 1>>"$d/terminal"
${FD8_LINE}
OSTLER_TTY_FD=8
exec > >(/usr/bin/tee -a "$d/install.log" >/dev/null) 2>&1
. "$WORK/reveal.sh"
exec 1>&- 2>&-
EOF
    /bin/bash "$d/run.sh"
    sleep 1   # let the tee drain
}

# ── A: GUI=0 ─────────────────────────────────────────────────────────────
run_reveal 0
d="$WORK/reveal-gui0"
n_log=$(count "$KEY" "$d/install.log"); n_tty=$(count "$KEY" "$d/terminal")
n_shown=$(count 'recovery key shown (29 chars)' "$d/install.log")
echo "A: key in install.log=${n_log} terminal(fd8)=${n_tty}; 'shown' record in log=${n_shown}"
[ "$n_log" = 0 ] && pass "A: key absent from install.log" || fail "A: key written to install.log ${n_log} time(s)"
[ "$n_tty" = 1 ] && pass "A: key reached the terminal once" || fail "A: key reached the terminal ${n_tty} time(s), want 1"
[ "$n_shown" = 1 ] && pass "A: log records the reveal by length" || fail "A: no 'recovery key shown (29 chars)' line in the log"

# ── B: GUI=1 ─────────────────────────────────────────────────────────────
run_reveal 1
d="$WORK/reveal-gui1"
n_log=$(count "$KEY" "$d/install.log"); n_9=$(count "RECOVERY_KEY value=${KEY}" "$d/fd9")
n_8=$(/usr/bin/grep -c -F -- "$KEY" "$d/terminal" 2>/dev/null || true)
echo "B: key in install.log=${n_log} marker(fd9)=${n_9} stdout-pipe(fd8)=${n_8}"
[ "$n_log" = 0 ] && pass "B: key absent from install.log" || fail "B: key written to install.log ${n_log} time(s)"
[ "$n_9" = 1 ] && pass "B: GUI marker still carries the key on fd 9" || fail "B: GUI marker on fd 9 count ${n_9}, want 1"
[ "$n_8" = 0 ] && pass "B: key kept off the GUI stdout pipe (Log drawer)" || fail "B: key on the GUI stdout pipe ${n_8} time(s)"

# ── C: upgrade scrub ─────────────────────────────────────────────────────
fstart=$(/usr/bin/grep -n -F '_ostler_scrub_recovery_key_from_logs() {' "$SRC" | head -1 | cut -d: -f1)
if [ -z "$fstart" ]; then
    fail "C: no _ostler_scrub_recovery_key_from_logs in $SRC: old logs keep the key"
else
    fend=$(/usr/bin/awk -v s="$fstart" 'NR>s && /^}/ {print NR; exit}' "$SRC")
    /usr/bin/sed -n "${fstart},${fend}p" "$SRC" > "$WORK/scrub.sh"
    L="$WORK/logs"; mkdir -p "$L"
    CONTROL='control line: Doctor ok SYNT-HETI-CKEY-NOT-AFTER-LABEL'
    for f in install.log install.log.1; do
        printf '%s\n' 'old run' "$CONTROL" '' \
            $'  \033[1mYour recovery key:\033[0m' '' \
            $'    \033[1;33m\033[1m'"${KEY}"$'\033[0m' '' 'tail line' \
            "RECOVERY_PHRASE=${KEY}" > "$L/$f"
    done
    b0=$(count "$KEY" "$L/install.log"); b1=$(count "$KEY" "$L/install.log.1")
    ctl_before=$(/usr/bin/grep -c -x -F -- "$CONTROL" "$L/install.log")
    out1="$(/bin/bash -c ". '$WORK/scrub.sh'; _ostler_scrub_recovery_key_from_logs '$L'/install.log*" 2>&1)"
    a0=$(count "$KEY" "$L/install.log"); a1=$(count "$KEY" "$L/install.log.1")
    ctl_after=$(/usr/bin/grep -c -x -F -- "$CONTROL" "$L/install.log")
    out2="$(/bin/bash -c ". '$WORK/scrub.sh'; _ostler_scrub_recovery_key_from_logs '$L'/install.log*" 2>&1)"
    echo "C: key lines before install.log=${b0} install.log.1=${b1}; after=${a0}/${a1}; control ${ctl_before}->${ctl_after}"
    echo "C: run1: $(echo "$out1" | tr '\n' ' ')"
    echo "C: run2: $(echo "$out2" | tr '\n' ' ')"
    [ "$b0" -ge 1 ] && [ "$b1" -ge 1 ] || fail "C: plant did not take (before ${b0}/${b1})"
    [ "$a0" = 0 ] && [ "$a1" = 0 ] && pass "C: key redacted from install.log and install.log.1" || fail "C: key survives scrub (${a0}/${a1})"
    [ "$ctl_after" = 1 ] && pass "C: control line survives byte-identical" || fail "C: control line damaged"
    case "$out2" in *"redacted"*) /usr/bin/grep -q -E ': [1-9][0-9]* line' <<<"$out2" && fail "C: second run redacted more (not idempotent)" || pass "C: second run redacted nothing more" ;;
        *) pass "C: second run redacted nothing more" ;; esac
    /usr/bin/grep -q 'tail line' "$L/install.log" && pass "C: lines after the key untouched" || fail "C: lines after the key lost"
fi

# ── D/E: keychain save, argv ─────────────────────────────────────────────
kstart=$(/usr/bin/grep -n -F 'SAVE_KEYCHAIN="$(gui_read' "$SRC" | head -1 | cut -d: -f1)
kend=$(/usr/bin/awk -v s="$kstart" 'NR>s && /^    if \[\[ "\$SAVED_TO_KEYCHAIN" == false \]\]; then$/ {print NR; exit}' "$SRC")
if [ -z "$kstart" ] || [ -z "$kend" ]; then
    echo "CANNOT-RUN: keychain block not found in $SRC"; FAILS=$((FAILS+1))
else
    /usr/bin/sed -n "${kstart},$((kend-1))p" "$SRC" > "$WORK/kc.sh"
    run_kc() {  # $1 = swift exit code
        local rc="$1" d="$WORK/kc-swift$1"
        mkdir -p "$d/bin"
        printf '#!/bin/bash\nprintf "%%s\\n" "$@" >> "%s/security.argv"\nexit 0\n' "$d" > "$d/bin/security"
        printf '#!/bin/bash\nprintf "%%s\\n" "$@" >> "%s/swift.argv"\nprintf "%%s\\n" "${KC_PASSWORD:-}" > "%s/swift.env"\nexit %s\n' "$d" "$d" "$rc" > "$d/bin/swift"
        chmod +x "$d/bin/security" "$d/bin/swift"
        : > "$d/security.argv"; : > "$d/swift.argv"
        PATH="$d/bin:/usr/bin:/bin" /bin/bash -c "
            RECOVERY_KEY='${KEY}'; USER_ID=synthetic-user; SAVED_TO_KEYCHAIN=false
            gui_read() { echo Y; }; ok() { echo \"ok: \$*\"; }; warn() { echo \"warn: \$*\"; }
            . '${REPO}/install.sh.strings.en-GB.sh'
            . '$WORK/kc.sh'
            echo \"SAVED_TO_KEYCHAIN=\$SAVED_TO_KEYCHAIN\"
        " > "$d/out" 2>&1
    }
    run_kc 1
    d="$WORK/kc-swift1"
    ns=$(count "$KEY" "$d/security.argv"); nw=$(count "$KEY" "$d/swift.argv")
    echo "D: swift fails: security calls=$(/usr/bin/wc -l < "$d/security.argv" | tr -d ' ') argv lines; key in security argv=${ns} swift argv=${nw}; $(tail -1 "$d/out")"
    [ "$ns" = 0 ] && [ "$nw" = 0 ] && pass "D: key on no argv when swift fails" || fail "D: key on argv (security=${ns} swift=${nw})"
    /usr/bin/grep -q '^SAVED_TO_KEYCHAIN=false$' "$d/out" && pass "D: failure reported as not saved" || fail "D: claimed saved when swift failed"
    # The copy the customer sees on that path: says the key is NOT in Keychain
    # and to write it down, and does not read as an installer failure.
    /usr/bin/grep -qxF 'warn: Your recovery key was not saved to Keychain. Write it down and keep it somewhere safe, away from this Mac.' "$d/out" \
        && ! /usr/bin/grep -qiF 'could not save' "$d/out" \
        && pass "D: the not-saved warning says not saved and write it down, not a failure" \
        || fail "D: not-saved warning copy wrong: $(/usr/bin/grep '^warn:' "$d/out" | head -1)"
    run_kc 0
    d="$WORK/kc-swift0"
    nw=$(count "$KEY" "$d/swift.argv"); ne=$(count "$KEY" "$d/swift.env")
    echo "E: swift ok: key in swift argv=${nw} swift env=${ne}; $(tail -1 "$d/out")"
    [ "$nw" = 0 ] && pass "E: key not on swift argv" || fail "E: key on swift argv"
    [ "$ne" = 1 ] && pass "E: key reached swift via env (control: the stub can see it)" || fail "E: swift never received the key (env count ${ne})"
    /usr/bin/grep -q '^SAVED_TO_KEYCHAIN=true$' "$d/out" && pass "E: saved" || fail "E: not saved when swift succeeded"
    /usr/bin/grep -qF 'not saved to Keychain' "$d/out" && fail "E: not-saved warning shown although the key WAS saved" || pass "E: no not-saved warning when saved (control)"
fi

# ── F: setup-failure dump ────────────────────────────────────────────────
# On ERR-09 install.sh echoes SETUP_OUTPUT (to stdout, i.e. the tee). That
# output carries RECOVERY_PHRASE=<key> when setup fails after minting.
fline="$(/usr/bin/grep -m1 -E '^ *echo "\$SETUP_OUTPUT" \| sed ' "$SRC" || true)"
if [ -z "$fline" ]; then
    echo "CANNOT-RUN: F: setup-failure dump line not found"; FAILS=$((FAILS+1))
else
    fout="$(SETUP_OUTPUT="$(printf 'RECOVERY_PHRASE=%s\nERROR=synthetic failure\n' "$KEY")" /bin/bash -c "$fline")"
    nf=$(/usr/bin/grep -c -F -- "$KEY" <<<"$fout" || true)
    ne=$(/usr/bin/grep -c -F -- 'ERROR=synthetic failure' <<<"$fout" || true)
    echo "F: setup-failure dump: key=${nf} error line=${ne}"
    [ "$nf" = 0 ] && pass "F: key redacted from the setup-failure dump" || fail "F: setup-failure dump writes the key ${nf} time(s)"
    [ "$ne" = 1 ] && pass "F: the error line still reaches the log (control)" || fail "F: error line lost"
fi

echo "VERDICT: $([ "$FAILS" = 0 ] && echo PASS || echo "FAIL (${FAILS})")"
[ "$FAILS" = 0 ]
