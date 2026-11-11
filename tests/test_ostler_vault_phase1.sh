#!/bin/bash
#
# test_ostler_vault_phase1.sh -- lib/ostler-vault.sh (OSTLER_VAULT=1, Phase 1).
#
# THROWAWAY ONLY. Every keychain is created with `security create-keychain` in
# a temp dir (measured 2026-11-11: that leaves the user's search list and
# default keychain unchanged; this test re-asserts it). Every bundle is 200 MB.
# The user's login keychain is never named, opened or listed for items. No
# Colima VM: a fake `colima` stands in and only mkdirs.
#
# exit 0 all arms pass | 1 any arm failed | 97 CANNOT-RUN (not macOS, no hdiutil)
#
# Bands are grepped with /usr/bin/grep -a: the grep on PATH may be ugrep, which
# returned a false zero on BOTH encrypted and unencrypted bundles in the spike.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="${HERE}/../lib/ostler-vault.sh"
GREP=/usr/bin/grep

if [ "$(uname -s)" != Darwin ] || ! command -v hdiutil >/dev/null 2>&1 || ! command -v security >/dev/null 2>&1; then
    echo "CANNOT-RUN: needs macOS hdiutil + security"
    exit 97
fi

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }
# expect <desc> <expected-rc> <actual-rc>
expect() { if [ "$2" = "$3" ]; then ok "$1 (rc=$3)"; else bad "$1 (wanted rc=$2, got rc=$3)"; fi; }
yes_if() { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
no_if()  { if "${@:2}"; then bad "$1"; else ok "$1"; fi; }

T="$(mktemp -d /tmp/ovt.XXXXXX)" || exit 97
T="$(cd -P "$T" && pwd -P)"
KC="${T}/t.keychain-db"
BUNDLE="${T}/vault.sparsebundle"
MP="${T}/m"
LOGIN_KC="${HOME}/Library/Keychains/login.keychain-db"
SHIMLOG="${T}/security.argv"
BEFORE_LIST="$(security list-keychains -d user 2>&1)"
BEFORE_DEF="$(security default-keychain 2>&1)"

cleanup() {
    for m in "$MP" "${T}/m2"; do
        hdiutil detach "$m" >/dev/null 2>&1 || hdiutil detach -force "$m" >/dev/null 2>&1
        chflags nouchg "$m" 2>/dev/null
    done
    [ -f "$KC" ] && security delete-keychain "$KC" >/dev/null 2>&1
    case "$T" in /tmp/ovt.*|/private/tmp/ovt.*) rm -rf -- "$T" ;; esac
}
trap cleanup EXIT

# Safety rails: refuse to run if the throwaway paths could be the real thing.
case "$KC" in "$LOGIN_KC"|*/login.keychain*) echo "FATAL: test keychain resolves to a real keychain"; exit 1 ;; esac

# `security` shim: logs argv one call per line (NUL-free, tab-separated), then execs the real one.
mkdir -p "${T}/shim"
cat >"${T}/shim/security" <<EOF
#!/bin/bash
{ printf '%s' "\$1"; for a in "\${@:2}"; do printf '\t%s' "\$a"; done; printf '\n'; } >>"${SHIMLOG}"
exec /usr/bin/security "\$@"
EOF
chmod +x "${T}/shim/security"

v() { OSTLER_VAULT=1 OSTLER_VAULT_KEYCHAIN="$KC" OSTLER_VAULT_BUNDLE="$BUNDLE" OSTLER_VAULT_MOUNT="$MP" \
        OSTLER_VAULT_ACCOUNT=ovt OSTLER_VAULT_SERVICE=com.ostler.vault.test OSTLER_VAULT_SIZE=200m \
        PATH="${T}/shim:${PATH}" /bin/bash "$LIB" "$@"; }
mounted() { /sbin/mount | $GREP -F -q -- " on ${1} ("; }
empty_dir() { [ -d "$1" ] && [ -z "$(ls -A -- "$1")" ]; }

security create-keychain -p pw "$KC" && security unlock-keychain -p pw "$KC" || { echo "CANNOT-RUN: temp keychain"; exit 97; }

echo "== 0. off by default"
env -u OSTLER_VAULT /bin/bash "$LIB" create >/dev/null 2>&1; expect "create without OSTLER_VAULT=1 refuses" 3 $?
env OSTLER_VAULT=0 /bin/bash "$LIB" attach >/dev/null 2>&1; expect "attach with OSTLER_VAULT=0 refuses" 3 $?
no_if "disabled create made no bundle" test -e "$BUNDLE"

echo "== 1. create / attach / detach round trip"
v create >/dev/null 2>&1; expect "create" 0 $?
yes_if "bundle exists" test -d "$BUNDLE"
v status >/dev/null 2>&1; expect "status after create = detached" 10 $?
no_if "not mounted after create" mounted "$MP"
yes_if "mountpoint is empty while detached" empty_dir "$MP"
yes_if "mountpoint is uchg while detached (fail-closed)" test -n "$(ls -ldO "$MP" | $GREP -w uchg)"
v attach >/dev/null 2>&1; expect "attach over the uchg dir" 0 $?
yes_if "mounted at mountpoint" mounted "$MP"
yes_if "sentinel present" test -f "$MP/.mounted"
v status >/dev/null 2>&1; expect "status attached = ready" 0 $?
v guard >/dev/null 2>&1; expect "guard passes when attached" 0 $?
echo persisted >"$MP/probe.txt"
yes_if "env exports COLIMA_HOME/LIMA_HOME/DOCKER_CONFIG inside the vault" \
    test "$(v env | $GREP -c -E "^export (COLIMA_HOME|LIMA_HOME|DOCKER_CONFIG)=${MP}/")" -eq 3
v attach >/dev/null 2>&1; expect "second attach is idempotent" 0 $?
v detach >/dev/null 2>&1; expect "detach" 0 $?
no_if "unmounted after detach" mounted "$MP"
yes_if "mountpoint empty again after detach" empty_dir "$MP"
v attach >/dev/null 2>&1
yes_if "data survives re-attach" test "$(cat "$MP/probe.txt" 2>/dev/null)" = persisted
v detach >/dev/null 2>&1

echo "== 2. canary absent from bands when detached (with control)"
v attach >/dev/null 2>&1
CAN="OVT-CANARY-$(openssl rand -hex 12)"
yes "$CAN" 2>/dev/null | head -c 2097152 >"$MP/canary.txt"
yes_if "canary readable while attached" test "$($GREP -c -- "$CAN" "$MP/canary.txt")" -gt 0
v detach >/dev/null 2>&1
HITS="$($GREP -a -r -l -- "$CAN" "$BUNDLE" 2>/dev/null | wc -l | tr -d ' ')"
expect "encrypted bundle: bands containing canary" 0 "$HITS"
# Control: the SAME predicate on an unencrypted bundle must find it.
mkdir "${T}/m2"
hdiutil create -size 200m -type SPARSEBUNDLE -fs APFS -volname C -nospotlight "${T}/plain.sparsebundle" >/dev/null 2>&1
hdiutil attach -nobrowse -noverify -mountpoint "${T}/m2" "${T}/plain.sparsebundle" >/dev/null 2>&1
yes "$CAN" 2>/dev/null | head -c 2097152 >"${T}/m2/canary.txt"
hdiutil detach "${T}/m2" >/dev/null 2>&1
CHITS="$($GREP -a -r -l -- "$CAN" "${T}/plain.sparsebundle" 2>/dev/null | wc -l | tr -d ' ')"
yes_if "CONTROL: unencrypted bundle bands DO contain canary (hits=${CHITS})" test "$CHITS" -ge 1

echo "== 3. detached + start attempt refuses, creates no plaintext"
mkdir -p "${T}/bin"
cat >"${T}/bin/colima" <<EOF
#!/bin/bash
# fake colima: records that it ran, then does what the real one did in the spike.
: >"${T}/colima.ran"
mkdir -p "\${COLIMA_HOME}/_lima"
EOF
chmod +x "${T}/bin/colima"
rm -f "${T}/colima.ran"
v status >/dev/null 2>&1; expect "precondition: detached" 10 $?
v exec -- "${T}/bin/colima" start >/dev/null 2>&1; rc=$?
no_if "launcher refuses (rc=${rc})" test "$rc" -eq 0
no_if "fake colima never ran" test -e "${T}/colima.ran"
yes_if "mountpoint still empty (no plaintext dir)" empty_dir "$MP"
test -z "$(v env 2>/dev/null)"; expect "env prints nothing when detached" 0 $?
v guard >/dev/null 2>&1; rc=$?; no_if "guard refuses when detached (rc=${rc})" test "$rc" -eq 0
# Bypass the launcher: colima run directly at the detached mountpoint (the spike's fail-open).
COLIMA_HOME="$MP/colima" "${T}/bin/colima" start >/dev/null 2>&1; rc=$?
no_if "direct run against detached uchg mountpoint fails (rc=${rc})" test "$rc" -eq 0
yes_if "...and the mountpoint is still empty" empty_dir "$MP"
# CONTROL: the same direct run against a NON-uchg dir succeeds and plants plaintext,
# so the two assertions above are not vacuous.
mkdir "${T}/plainmp"
COLIMA_HOME="${T}/plainmp/colima" "${T}/bin/colima" start >/dev/null 2>&1
yes_if "CONTROL: without uchg the fake colima DOES create plaintext" test -d "${T}/plainmp/colima/_lima"
# Plaintext already sitting in an unmounted mountpoint is never hidden by an attach.
chflags nouchg "$MP"; echo leftover >"$MP/stray.txt"
v attach >/dev/null 2>&1; rc=$?
no_if "attach refuses over a non-empty unmounted mountpoint (rc=${rc})" test "$rc" -eq 0
yes_if "...and the stray file is untouched" test -f "$MP/stray.txt"
no_if "...and nothing got mounted" mounted "$MP"
rm -f "$MP/stray.txt"; chflags uchg "$MP"

echo "== 4. wrong / missing key refuses"
SVC=com.ostler.vault.test
GOOD="$(security find-generic-password -a ovt -s $SVC -w "$KC")"
security delete-generic-password -a ovt -s $SVC "$KC" >/dev/null 2>&1
security add-generic-password -a ovt -s $SVC -w "$(openssl rand -hex 32)" "$KC" >/dev/null 2>&1
v attach >/dev/null 2>&1; rc=$?
no_if "wrong key: attach refuses (rc=${rc})" test "$rc" -eq 0
no_if "wrong key: nothing mounted" mounted "$MP"
yes_if "wrong key: mountpoint empty" empty_dir "$MP"
v guard >/dev/null 2>&1; rc=$?; no_if "wrong key: guard refuses (rc=${rc})" test "$rc" -eq 0
security delete-generic-password -a ovt -s $SVC "$KC" >/dev/null 2>&1
v attach >/dev/null 2>&1; rc=$?
no_if "missing key: attach refuses (rc=${rc})" test "$rc" -eq 0
no_if "missing key: no replacement key was created" security find-generic-password -a ovt -s $SVC "$KC" >/dev/null 2>&1
v status >/dev/null 2>&1; expect "missing key: status = key-missing" 12 $?
v create >/dev/null 2>&1; rc=$?
no_if "create refuses over an existing bundle (rc=${rc})" test "$rc" -eq 0
security add-generic-password -a ovt -s $SVC -w "$GOOD" "$KC" >/dev/null 2>&1
v create >/dev/null 2>&1; rc=$?
no_if "create refuses when a key already exists (rc=${rc})" test "$rc" -eq 0
v attach >/dev/null 2>&1; expect "restored key attaches again" 0 $?
v detach >/dev/null 2>&1

echo "== 5. misc refusals"
OSTLER_VAULT=1 OSTLER_VAULT_KEYCHAIN="$KC" OSTLER_VAULT_BUNDLE="${T}/other.sparsebundle" \
    OSTLER_VAULT_MOUNT="${T}/$(printf 'x%.0s' $(seq 1 70))" /bin/bash "$LIB" create >/dev/null 2>&1; rc=$?
no_if "mountpoint >= 60 chars refused (rc=${rc})" test "$rc" -eq 0
no_if "...and no bundle was made for it" test -e "${T}/other.sparsebundle"

echo "== 6. every security call carries the explicit keychain"
NCALLS="$(wc -l <"$SHIMLOG" | tr -d ' ')"
yes_if "shim saw security calls (n=${NCALLS})" test "$NCALLS" -gt 5
# check_log <file>: every line's last field is $KC and its subcommand is allowed.
check_log() {
    awk -F'\t' -v kc="$KC" '
        { sub(/^[^\t]*/, "&"); }
        $1 !~ /^(add-generic-password|find-generic-password|delete-generic-password)$/ { print "BAD SUBCOMMAND: " $0; bad=1 }
        $NF != kc { print "NO EXPLICIT KEYCHAIN: " $0; bad=1 }
        END { exit bad }' "$1"
}
yes_if "all logged calls: allowed subcommand + keychain is the last arg" check_log "$SHIMLOG"
# CONTROL: the checker must reject a call without the keychain, and a forbidden subcommand.
printf 'find-generic-password\t-a\tovt\t-w\n' >"${T}/neg1.log"
no_if "CONTROL: checker rejects a call with no keychain arg" check_log "${T}/neg1.log"
printf 'unlock-keychain\t-p\tpw\t%s\n' "$KC" >"${T}/neg2.log"
no_if "CONTROL: checker rejects unlock-keychain" check_log "${T}/neg2.log"
yes_if "static: lib calls \`security\` from exactly one place (_v_sec)" \
    test "$($GREP -E '^[^#]*[[:space:]]security[[:space:]]+"' "$LIB" | wc -l | tr -d ' ')" -eq 1
code_lines() { $GREP -v -E '^[[:space:]]*#' "$LIB"; }
yes_if "static: lib names the login keychain exactly once (the default)" \
    test "$(code_lines | $GREP -c 'login.keychain')" -eq 1
yes_if "static: no unlock/list-keychains/default-keychain calls in the lib" \
    test "$(code_lines | $GREP -c -E 'unlock-keychain|list-keychains|default-keychain|set-keychain')" -eq 0

echo "== 7. user keychain search list untouched"
AFTER_LIST="$(security list-keychains -d user 2>&1)"
AFTER_DEF="$(security default-keychain 2>&1)"
yes_if "list-keychains unchanged" test "$BEFORE_LIST" = "$AFTER_LIST"
yes_if "default-keychain unchanged" test "$BEFORE_DEF" = "$AFTER_DEF"

echo "== 8. plist template"
PL="${HERE}/../lib/launchd/com.creativemachines.ostler.vault.plist.template"
yes_if "plutil -lint" plutil -lint "$PL"
yes_if "RunAtLoad true, no KeepAlive" test "$(plutil -extract RunAtLoad raw "$PL")" = true
no_if "no KeepAlive (no crash loop on a bad key)" plutil -extract KeepAlive raw "$PL" >/dev/null 2>&1

echo
echo "RESULT: ${PASS} pass, ${FAIL} fail"
[ "$FAIL" -eq 0 ]
