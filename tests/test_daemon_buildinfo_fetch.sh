#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Tests scripts/fetch_daemon_buildinfo.sh.
#
# A gate that has never failed has never been tested. Every case below asserts
# an EXIT CODE, and the codes are distinct on purpose:
#   0 = provenance carried (or explicitly waived)
#   1 = refused (cut must not proceed)
#   2 = could not run (tool/credential fault, NEVER a verdict)
#
# The local-cache acquisition path is used as the fixture so none of this
# touches the network. That is also the path a cut takes on a pre-staged box,
# so it is not a synthetic-only route.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$REPO_ROOT/scripts/fetch_daemon_buildinfo.sh"

PASSED=0
FAILED=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; PASSED=$((PASSED+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*" >&2; FAILED=$((FAILED+1)); }

[[ -x "$GATE" ]] || { echo "gate not executable: $GATE" >&2; exit 2; }

WORK="$(mktemp -d)" || exit 2
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT INT TERM

CACHE="$WORK/cache"; mkdir -p "$CACHE"
DEST="$WORK/out/build-info.json"
TAG="hub-v0.4.55"
REPO="ostler-ai/ostler-releases"

# Run with the network paths disabled so the local cache is the only route.
# PATH is stripped of gh and GH_TOKEN is cleared, which also lets CONTROL 5
# assert the cannot-run arm.
run_gate() {
    local waiver="${1:-$WORK/empty-waiver.tsv}"
    ( export DAEMON_LOCAL_CACHE_DIR="$CACHE" \
             DAEMON_BUILDINFO_WAIVER_FILE="$waiver" \
             GH_TOKEN="fake-token-so-cannot-run-does-not-fire"
      "$GATE" "$TAG" "$REPO" "$DEST" >/dev/null 2>&1 )
    echo $?
}

: > "$WORK/empty-waiver.tsv"

echo "test_daemon_buildinfo_fetch"

# --- GREEN: a real record with a commit -----------------------------------
printf '{"commit_sha":"e0234e71c66d","tag":"hub-v0.4.55"}\n' > "$CACHE/${TAG}-build-info.json"
rc="$(run_gate)"
if [[ "$rc" == 0 ]]; then ok "valid build-info with commit_sha -> rc=0"
else bad "expected rc=0 on a valid record, got rc=$rc"; fi
if [[ -f "$DEST" ]] && grep -q 'e0234e71c66d' "$DEST" 2>/dev/null; then
    ok "the commit actually reached DEST (not just a green exit)"
else
    bad "rc said OK but DEST does not carry the commit -- exit code lied"
fi

# --- RED 1: record present but carrying NO commit -------------------------
rm -f "$DEST"
printf '{"tag":"hub-v0.4.55","built_at":"2026-08-10"}\n' > "$CACHE/${TAG}-build-info.json"
rc="$(run_gate)"
if [[ "$rc" == 1 ]]; then ok "RED: build-info without a commit field -> rc=1"
else bad "RED FAILED: commit-less record returned rc=$rc, expected 1"; fi
if [[ ! -f "$DEST" ]]; then ok "refusal wrote nothing to DEST"
else bad "refused but still wrote DEST -- a bad record would ship"; fi

# --- RED 2: no asset anywhere, no waiver ----------------------------------
rm -f "$CACHE/${TAG}-build-info.json" "$DEST"
rc="$(run_gate)"
if [[ "$rc" == 1 ]]; then ok "RED: absent asset with no waiver -> rc=1 (fails closed)"
else bad "RED FAILED: absent asset returned rc=$rc, expected 1"; fi

# --- RED 3: waiver row present but reason EMPTY ---------------------------
printf '%s\t\n' "$TAG" > "$WORK/empty-reason.tsv"
rc="$(run_gate "$WORK/empty-reason.tsv")"
if [[ "$rc" == 1 ]]; then ok "RED: waiver with an empty reason -> rc=1"
else bad "RED FAILED: reasonless waiver returned rc=$rc, expected 1"; fi

# --- GREEN: waiver row with a real reason ---------------------------------
printf '%s\tpredates build-info.json; provenance accepted absent for this tag\n' "$TAG" > "$WORK/good-waiver.tsv"
rc="$(run_gate "$WORK/good-waiver.tsv")"
if [[ "$rc" == 0 ]]; then ok "waiver with a stated reason -> rc=0"
else bad "expected rc=0 on a reasoned waiver, got rc=$rc"; fi

# --- CONTROL: a waiver for a DIFFERENT tag must not apply -----------------
printf 'hub-v0.0.1\tsome other tag entirely\n' > "$WORK/other-waiver.tsv"
rc="$(run_gate "$WORK/other-waiver.tsv")"
if [[ "$rc" == 1 ]]; then ok "CONTROL: a waiver for another tag does NOT waive this one"
else bad "CONTROL FAILED: foreign-tag waiver returned rc=$rc, expected 1"; fi

# --- CONTROL: no acquisition method at all is CANNOT-RUN, never a verdict --
rc="$( ( export DAEMON_LOCAL_CACHE_DIR="$WORK/definitely-empty" \
                DAEMON_BUILDINFO_WAIVER_FILE="$WORK/empty-waiver.tsv"
         unset GH_TOKEN
         PATH=/usr/bin:/bin "$GATE" "$TAG" "$REPO" "$DEST" >/dev/null 2>&1 ); echo $? )"
if [[ "$rc" == 2 ]]; then ok "CONTROL: no gh + no GH_TOKEN -> rc=2 CANNOT-RUN, not rc=1"
else bad "CONTROL FAILED: unreachable release returned rc=$rc, expected 2. A cannot-run reported as a verdict would license a waiver for a release that HAS the file."; fi

# --- CONTROL: bad args are a cannot-run -----------------------------------
rc="$( ( "$GATE" >/dev/null 2>&1 ); echo $? )"
if [[ "$rc" == 2 ]]; then ok "CONTROL: missing args -> rc=2"
else bad "CONTROL FAILED: missing args returned rc=$rc, expected 2"; fi

echo
if (( FAILED == 0 )); then
    printf '\033[32m%s passed, 0 failed\033[0m\n' "$PASSED"; exit 0
else
    printf '\033[31m%s passed, %s FAILED\033[0m\n' "$PASSED" "$FAILED" >&2; exit 1
fi
