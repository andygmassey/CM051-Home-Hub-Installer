#!/usr/bin/env bash
#
# tests/test_safari_extension_paired_bearer_write.sh
#
# CM020 fix, v1.0.107: the Safari extension's APIService.swift hard-gates
# every send on Constants.pairedBearer() (SharedConsts.swift) being
# non-empty, read from the App Group UserDefaults suite
# group.com.creativemachines.SafariHistoryExt. A repo-wide search found no
# writer of that key anywhere outside the extension's own repo -- the Hub
# never paired it, so every install shipped browsing capture permanently
# off (CAPTURE_AUDIT_2026-10-07.md, CM020 Send row).
#
# install.sh's extension-token generator (EXTENSION_TOKEN_FILE /
# OSTLER_EXTENSION_TOKEN) was already real; this test proves the NEW block
# this PR adds -- SAFARI_EXTENSION_PAIR_BEGIN..END -- actually writes that
# same token into the extension's App Group plist as `pairedBearer`, which
# is the artefact the extension reads, not merely that install.sh runs
# without error.
#
# EXTRACTED from install.sh, not reimplemented: a test that re-describes
# the write in its own words could stay green after the real block is
# deleted. Same pattern as test_v1010_ical_doctor_service_auth.sh.
#
# macOS only (needs plutil + PlistBuddy, real plist writers). On a
# non-macOS runner this is CANNOT-RUN (exit 2), never a silent pass.
#
# Uses PlistBuddy, not `defaults write`: MEASURED that `defaults write
# <path>` against a plist outside the real logged-in user's actual $HOME
# exits 0 and writes NOTHING -- cfprefsd resolves the domain against the
# session's real identity, not the literal path argument. A test (or an
# installer) that faked $HOME and trusted `defaults write`'s exit code
# would report success while pairing nothing. install.sh uses PlistBuddy
# for exactly this reason.
#
# Three arms:
#   1. The real block, run with a canary token -> the plist must carry it.
#   2. Permissions: the plist must be 600, not world/group readable.
#   3. MUTATION: blank OSTLER_EXTENSION_TOKEN (the exact pre-fix shape, and
#      the exact failure mode this gate must not go green on) -> the block
#      must warn and must NOT write an empty bearer over a real one.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

pass=0
fail=0
ok()  { printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }

[[ -f "$INSTALL_SCRIPT" ]] || { echo "CANNOT-RUN: install.sh not found" >&2; exit 2; }
command -v /usr/bin/plutil >/dev/null 2>&1 || { echo "CANNOT-RUN: /usr/bin/plutil not present (not macOS)" >&2; exit 2; }
command -v /usr/libexec/PlistBuddy >/dev/null 2>&1 || { echo "CANNOT-RUN: /usr/libexec/PlistBuddy not present (not macOS)" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

GROUP_ID="group.com.creativemachines.SafariHistoryExt"

# ── Extract the real block ──────────────────────────────────────────────
BS="$(/usr/bin/grep -n '# ── SAFARI_EXTENSION_PAIR_BEGIN' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)"
BE="$(/usr/bin/grep -n '# ── SAFARI_EXTENSION_PAIR_END' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1)"
if [[ -z "$BS" || -z "$BE" || "$BE" -le "$BS" ]]; then
    echo "CANNOT-RUN: could not find the SAFARI_EXTENSION_PAIR_BEGIN..END block in install.sh" >&2
    exit 2
fi
sed -n "${BS},${BE}p" "$INSTALL_SCRIPT" > "${WORK}/block.sh"
BLOCK_LINES="$(wc -l < "${WORK}/block.sh" | tr -d ' ')"
if [[ "$BLOCK_LINES" -lt 10 ]]; then
    echo "CANNOT-RUN: extracted block is suspiciously small ($BLOCK_LINES lines) -- anti-vacuity floor" >&2
    exit 2
fi

run_block() {
    # $1 = fake HOME, $2 = OSTLER_EXTENSION_TOKEN value (may be empty), $3 = stdout capture file
    local fake_home="$1" token="$2" capture="$3"
    (
        HOME="$fake_home"
        export HOME
        OSTLER_EXTENSION_TOKEN="$token"
        ok() { printf 'OK:%s\n' "$1"; }
        warn() { printf 'WARN:%s\n' "$1"; }
        MSG_OK_SAFARI_EXTENSION_PAIRED="paired"
        MSG_WARN_SAFARI_EXTENSION_PAIR_FAILED="pair-failed"
        MSG_WARN_SAFARI_EXTENSION_NO_TOKEN_TO_PAIR="no-token"
        set +u
        source "${WORK}/block.sh"
    ) > "$capture" 2>&1
}

PLIST_PATH_FOR() {
    printf '%s/Library/Group Containers/%s/Library/Preferences/%s.plist' "$1" "$GROUP_ID" "$GROUP_ID"
}

read_key() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

# ── Arm 1: real token lands as pairedBearer ─────────────────────────────
CANARY="CANARY0000EXTENSION0000BEARER0000feedface"
HOME1="${WORK}/home1"
mkdir -p "$HOME1"
run_block "$HOME1" "$CANARY" "${WORK}/out1.log"
PLIST1="$(PLIST_PATH_FOR "$HOME1")"

if [[ ! -f "$PLIST1" ]]; then
    bad "no plist was written at all -- the extension would stay unpaired exactly as before this fix"
else
    READ="$(read_key "$PLIST1" pairedBearer)"
    if [[ "$READ" == "$CANARY" ]]; then
        ok "pairedBearer in the App Group plist equals the installer's OSTLER_EXTENSION_TOKEN"
    else
        bad "pairedBearer read back as '${READ}', expected the canary token"
    fi
fi

if grep -q "^OK:" "${WORK}/out1.log"; then
    ok "the block reports success via ok(), not warn()"
else
    bad "the block did not report success: $(cat "${WORK}/out1.log")"
fi

if grep -qi "$CANARY" "${WORK}/out1.log"; then
    bad "the token value appeared in the block's own log output -- it must never be echoed"
else
    ok "the token value never appears in stdout/stderr"
fi

# ── Arm 2: permissions ───────────────────────────────────────────────────
if [[ -f "$PLIST1" ]]; then
    PERM="$(/usr/bin/stat -f '%Lp' "$PLIST1" 2>/dev/null || echo '??')"
    if [[ "$PERM" == "600" ]]; then
        ok "plist permissions are 600"
    else
        bad "plist permissions are ${PERM}, expected 600"
    fi
fi

# ── Arm 3: MUTATION -- blank token must not overwrite a real pairing ────
HOME2="${WORK}/home2"
mkdir -p "$HOME2"
run_block "$HOME2" "$CANARY" "${WORK}/out2a.log"
PLIST2="$(PLIST_PATH_FOR "$HOME2")"
run_block "$HOME2" "" "${WORK}/out2b.log"

if grep -q "^WARN:" "${WORK}/out2b.log"; then
    ok "an empty OSTLER_EXTENSION_TOKEN (the pre-fix shape) is reported via warn(), not silently accepted"
else
    bad "an empty token produced no warning -- a regenerated-empty token would pair the extension with nothing and nobody would be told"
fi

READ2="$(read_key "$PLIST2" pairedBearer)"
if [[ "$READ2" == "$CANARY" ]]; then
    ok "an empty token does not clobber an already-paired bearer"
else
    bad "an empty token run left pairedBearer as '${READ2}' -- the prior real pairing was destroyed"
fi

echo
echo "pass=$pass fail=$fail"
[[ "$fail" -eq 0 ]]
