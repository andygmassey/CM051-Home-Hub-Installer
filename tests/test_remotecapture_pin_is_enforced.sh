#!/usr/bin/env bash
# RemoteCapture tarball is verified against a PIN baked into install.sh
# ==========================================================================
# THE DEFECT. The tarball was checked only against a .sha256 sidecar fetched
# from the SAME release URL, so a replaced release asset (tarball + sidecar)
# passed. The daemon path pins DEFAULT_ASSISTANT_TARBALL_SHA256 in install.sh;
# RemoteCapture now does the same, via _ostler_remotecapture_pinned_sha.
#
# BEHAVIOURAL: extracts the real functions from install.sh and CALLS them.
# Sidecar policy mirrors the daemon (install.sh: the sidecar curl is chained
# with && to the tarball curl, so a missing sidecar means no install): a
# missing sidecar REFUSES even with a matching pin. Asserted below.
#
# ASSERTED
#   1 genuine bytes + pin + matching sidecar            -> accepted
#   2 TAMPERED bytes + MATCHING sidecar + pin           -> REFUSED (the defect)
#   3 genuine bytes, pin ok, sidecar missing            -> REFUSED (daemon parity)
#   4 genuine bytes, pin ok, sidecar disagrees          -> REFUSED
#   5 version with no table row, no override            -> REFUSED (fail closed)
#   6 the DEFAULT version has a row, and tampered bytes fail the REAL table
#   7 version and pin move together: the row for the default version equals
#     the sha256 of the PUBLISHED asset (network; CANNOT-RUN, not PASS, if
#     unreachable)
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
PASS=0; FAIL=0; CANNOT=0
ok()  { printf '  ok   %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$*" >&2; FAIL=$((FAIL+1)); }
printf 'test_remotecapture_pin_is_enforced\n'

FN1="$(awk '/^_ostler_remotecapture_pinned_sha\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$INSTALL_SH")"
FN2="$(awk '/^_ostler_remotecapture_verify\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$INSTALL_SH")"
if [ -z "$FN1" ] || [ -z "$FN2" ]; then
    bad "premise: install.sh has no _ostler_remotecapture_pinned_sha / _ostler_remotecapture_verify (no pin is enforced)"
    printf '%d ok, %d FAIL\n' "$PASS" "$FAIL"; exit 1
fi
ok "extracted both real functions"

VER="$(sed -nE 's/^OSTLER_REMOTECAPTURE_VERSION="\$\{OSTLER_REMOTECAPTURE_VERSION:-([^}"]+)\}".*/\1/p' "$INSTALL_SH" | head -1)"
REPO="$(sed -nE 's/^OSTLER_REMOTECAPTURE_REPO="\$\{OSTLER_REMOTECAPTURE_REPO:-([^}"]+)\}".*/\1/p' "$INSTALL_SH" | head -1)"
[ -n "$VER" ] && [ -n "$REPO" ] || { bad "premise: could not parse default version/repo"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf 'genuine-bytes' >"$T/good.tgz"; printf 'attacker-bytes' >"$T/evil.tgz"
GOOD="$(shasum -a 256 "$T/good.tgz" | awk '{print $1}')"
EVIL="$(shasum -a 256 "$T/evil.tgz" | awk '{print $1}')"
echo "$GOOD  good.tgz" >"$T/good.sha"; echo "$EVIL  evil.tgz" >"$T/evil.sha"
[ "$GOOD" != "$EVIL" ] || { bad "premise: fixtures identical"; exit 1; }

# run <override-pin|-> <tarball> <sidecar> <version> -> echoes rc
run() { ( unset OSTLER_REMOTECAPTURE_SHA256
          [ "$1" != "-" ] && export OSTLER_REMOTECAPTURE_SHA256="$1"
          eval "$FN1"; eval "$FN2"
          _ostler_remotecapture_verify "$2" "$3" "$4" >/dev/null 2>&1; echo $? ); }

[ "$(run "$GOOD" "$T/good.tgz" "$T/good.sha" 9.9.9)" = 0 ] && ok "1 genuine + pin + sidecar accepted" || bad "1 genuine rejected"
[ "$(run "$GOOD" "$T/evil.tgz" "$T/evil.sha" 9.9.9)" = 1 ] && ok "2 tampered bytes with MATCHING sidecar refused by the pin" || bad "2 tampered tarball with matching sidecar was NOT refused"
[ "$(run "$GOOD" "$T/good.tgz" "$T/none.sha" 9.9.9)" = 2 ] && ok "3 missing sidecar refused (daemon parity)" || bad "3 missing sidecar not refused"
[ "$(run "$GOOD" "$T/good.tgz" "$T/evil.sha" 9.9.9)" = 2 ] && ok "4 disagreeing sidecar refused" || bad "4 disagreeing sidecar not refused"
[ "$(run - "$T/good.tgz" "$T/good.sha" 9.9.9)" = 3 ] && ok "5 unpinned version refused (fail closed)" || bad "5 unpinned version accepted"

ROW="$( ( eval "$FN1"; _ostler_remotecapture_pinned_sha "$VER" ) )"
if printf '%s' "$ROW" | grep -Eq '^[0-9a-f]{64}$'; then ok "6a default version ${VER} has a 64-hex row"; else bad "6a default version ${VER} has NO pin row (version moved without its sha)"; fi
[ "$(run - "$T/evil.tgz" "$T/evil.sha" "$VER")" = 1 ] && ok "6b tampered bytes + matching sidecar fail the REAL table for ${VER}" || bad "6b real table did not refuse tampered bytes"

if grep -Fq -- '-o "${REMOTECAPTURE_TMPDIR}/${REMOTECAPTURE_ARCHIVE_NAME}.sha256"' "$INSTALL_SH"; then ok "install.sh still requires the sidecar download (chained with the tarball curl)"; else bad "sidecar download no longer present"; fi

URL="https://github.com/${REPO}/releases/download/remote-capture-v${VER}/RemoteCapture-${VER}-arm64.tar.gz"
if curl -fsSL --noproxy '*' --retry 2 -o "$T/pub.tgz" "$URL" 2>/dev/null || curl -fsSL --retry 2 -o "$T/pub.tgz" "$URL" 2>/dev/null; then
    PUB="$(shasum -a 256 "$T/pub.tgz" | awk '{print $1}')"
    [ "$PUB" = "$ROW" ] && ok "7 pinned sha equals the published asset (${PUB})" || bad "7 pinned ${ROW} != published ${PUB}"
else
    printf '  CANNOT-RUN 7 could not download %s\n' "$URL"; CANNOT=$((CANNOT+1))
fi
printf '%d ok, %d FAIL, %d CANNOT-RUN\n' "$PASS" "$FAIL" "$CANNOT"
[ "$FAIL" -eq 0 ]
