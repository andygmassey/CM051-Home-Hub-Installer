#!/usr/bin/env bash
# The promote-scope ratchet compares a HOTFIX cut against its HOTFIX_BASE_TAG,
# and every other branch against origin/main (Archie, 2026-10-26, v1.0.118).
#
# Subject: tests/test_promote_scope_only_ever_grows.sh, run inside a fixture
# repo so the base tag, origin/main and the cut's cut.env are all controlled.
#
# Arms:
#   1. hotfix carrying its base tag's blocking set, main has MORE   -> PASS
#   2. hotfix that drops one of its base tag's blocking probes      -> FAIL
#   3. NOT a hotfix, main has more blocking probes than the branch  -> FAIL
#      (a normal branch is still ratcheted against main)
#   4. hotfix with no HOTFIX_BASE_TAG                               -> FAIL
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$REPO_ROOT/tests/test_promote_scope_only_ever_grows.sh"
[ -r "$SUBJECT" ] || { echo "CANNOT-RUN: no $SUBJECT" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

FIX="$WORK/repo"
mkdir -p "$FIX/tests" "$FIX/scripts" "$FIX/gui/OstlerInstaller" "$FIX/cuts/v9.9.9"
cp "$SUBJECT" "$FIX/tests/"
git -C "$FIX" init -q .
git -C "$FIX" config user.email t@example.com
git -C "$FIX" config user.name Test

scope() { # blocking probe names...
    printf 'probe\tscope\treason\towner\n'
    for p in "$@"; do printf '%s\tblocking\tfixture\tarchie\n' "$p"; done
}
plist() { printf '<plist><dict>\n<key>CFBundleShortVersionString</key>\n<string>%s</string>\n</dict></plist>\n' "$1" > "$FIX/gui/OstlerInstaller/Info.plist"; }

# Base tag: two blocking probes.
scope probe_a probe_b > "$FIX/scripts/walk_promote_scope.tsv"
plist 9.9.8
git -C "$FIX" add -A && git -C "$FIX" commit -qm base && git -C "$FIX" tag v9.9.8
BASE="$(git -C "$FIX" rev-parse HEAD)"
# main moves on and adds a third blocking probe.
scope probe_a probe_b probe_main_only > "$FIX/scripts/walk_promote_scope.tsv"
git -C "$FIX" commit -qam "main adds a blocking probe"
git -C "$FIX" update-ref refs/remotes/origin/main HEAD
# The hotfix branch starts from the base tag.
git -C "$FIX" checkout -q -b hotfix "$BASE"
plist 9.9.9

run() { ( cd "$FIX" && env -u BASE_REF bash tests/test_promote_scope_only_ever_grows.sh >"$WORK/out" 2>&1; echo $? ); }
squash() { tr '\n' ' ' < "$WORK/out" | cut -c1-160; }

echo "-- 1. hotfix carrying its base tag's set --"
printf 'CUT_VERSION=9.9.9\nCUT_KIND=hotfix\nHOTFIX_BASE_TAG=v9.9.8\n' > "$FIX/cuts/v9.9.9/cut.env"
rc="$(run)"
[ "$rc" = "0" ] && grep -q 'ratcheting against its base tag v9.9.8' "$WORK/out" \
    && ok "a hotfix carrying its base's blocking set passes although main has more" \
    || bad "hotfix with the base set gave rc=${rc}: $(squash)"

echo "-- 2. hotfix dropping one of its base tag's probes --"
scope probe_a > "$FIX/scripts/walk_promote_scope.tsv"
rc="$(run)"
[ "$rc" = "1" ] && grep -q 'probe_b' "$WORK/out" \
    && ok "a hotfix that drops a base-tag blocking probe is RED and names it" \
    || bad "hotfix dropping probe_b gave rc=${rc}: $(squash)"
scope probe_a probe_b > "$FIX/scripts/walk_promote_scope.tsv"

echo "-- 3. NOT a hotfix: still ratcheted against main --"
printf 'CUT_VERSION=9.9.9\n' > "$FIX/cuts/v9.9.9/cut.env"
rc="$(run)"
[ "$rc" = "1" ] && grep -q 'probe_main_only' "$WORK/out" \
    && ok "a normal branch missing main's probe is RED against origin/main" \
    || bad "a normal branch gave rc=${rc}: $(squash)"

echo "-- 4. hotfix with no HOTFIX_BASE_TAG --"
printf 'CUT_VERSION=9.9.9\nCUT_KIND=hotfix\n' > "$FIX/cuts/v9.9.9/cut.env"
rc="$(run)"
[ "$rc" = "1" ] && grep -q 'names no HOTFIX_BASE_TAG' "$WORK/out" \
    && ok "CUT_KIND=hotfix without a base tag is RED" \
    || bad "a baseless hotfix gave rc=${rc}: $(squash)"

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
