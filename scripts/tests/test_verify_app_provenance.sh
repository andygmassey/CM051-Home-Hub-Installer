#!/usr/bin/env bash
#
# test_verify_app_provenance.sh -- prove the pre-seal provenance gate FIRES,
# and prove it fires on the RIGHT AXIS.
#
# A gate that only ever runs against a good tree has no evidence it can detect
# a bad one. Worse, a gate pinned to the wrong axis is BOTH blind and noisy: it
# passes real defects and fails correct artefacts, and the second one is what
# gets it switched off.
#
# So control 6 is the load-bearing one. It changes the commit SHA and NOTHING
# else. A SHA-equality gate flips to red there; this gate must not, because the
# frontend content is identical. That single control is the difference between
# the gate we built and the one that was specified.
set -uo pipefail

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/verify_app_provenance.sh"
[[ -x "$GATE" ]] || { echo "FAIL: gate not executable: $GATE"; exit 99; }

PASS=0; FAIL=0
TMP="$(mktemp -d -t app_provenance_XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

ZEROS="$(printf '0%.0s' $(seq 1 40))"

# --- fixture repo: two commits, IDENTICAL web/, plus one that changes web/ ---
REPO="$TMP/repo"; mkdir -p "$REPO/web"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" config user.email t@t.invalid; git -C "$REPO" config user.name t
printf 'frontend v1\n' > "$REPO/web/app.js"
git -C "$REPO" add -A; git -C "$REPO" commit -qm c1
C1="$(git -C "$REPO" rev-parse HEAD)"
# c2 touches a NON-frontend file only -- the real-world shape (embeddings.rs etc)
mkdir -p "$REPO/crates"; printf 'rust\n' > "$REPO/crates/lib.rs"
git -C "$REPO" add -A; git -C "$REPO" commit -qm c2
C2="$(git -C "$REPO" rev-parse HEAD)"
# c3 genuinely changes the frontend
printf 'frontend v2 CHANGED\n' > "$REPO/web/app.js"
git -C "$REPO" add -A; git -C "$REPO" commit -qm c3
C3="$(git -C "$REPO" rev-parse HEAD)"

# make_bundle <name> <marker-or-empty>
make_bundle() {
    local d="$TMP/$1.app"
    mkdir -p "$d/Contents/MacOS"
    cat > "$d/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ostler-hub</string>
</dict></plist>
PLIST
    if [[ -n "${2:-}" ]]; then
        printf 'padding\nWRAPPER_FRONTEND_COMMIT=%s\npadding\n' "$2" > "$d/Contents/MacOS/ostler-hub"
    else
        printf 'a binary with no marker at all\n' > "$d/Contents/MacOS/ostler-hub"
    fi
    echo "$d"
}

check() { # check <label> <expected-rc> <bundle> <daemon-commit>
    local label="$1" want="$2" bundle="$3" dcommit="$4" out rc
    out="$(OSTLER_DAEMON_COMMIT="$dcommit" bash "$GATE" "$bundle" "$REPO" 2>&1)"; rc=$?
    if [[ "$rc" == "$want" ]]; then
        printf '  PASS  %-52s rc=%s\n' "$label" "$rc"; PASS=$((PASS+1))
    else
        printf '  FAIL  %-52s rc=%s want=%s\n' "$label" "$rc" "$want"
        printf '%s\n' "$out" | sed 's/^/        | /'; FAIL=$((FAIL+1))
    fi
}

echo "test_verify_app_provenance"
echo

# 1. identical commit -> pass
check "identical commit, identical frontend" 0 "$(make_bundle good "$C1")" "$C1"

# 2. NO marker at all -> the unattestable bundle. MUST fail before the seal.
check "no WRAPPER_FRONTEND_COMMIT marker" 1 "$(make_bundle nomark "")" "$C1"

# 3. all-zero marker -> well-formed but means "I do not know".
#    verify_commit_parity.sh accepts this; two zero-marked binaries compare
#    EQUAL there and it reports "commit-parity verified: 000...0". Not here.
check "all-zero unattestable marker" 1 "$(make_bundle zeros "$ZEROS")" "$C1"

# 4. marker names a commit that does not exist in the reference checkout
check "marker names a nonexistent commit" 1 \
    "$(make_bundle ghost "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")" "$C1"

# 5. frontend CONTENT genuinely differs -> the HR015 #225 class. MUST fail.
check "frontend content genuinely differs (c1 vs c3)" 1 "$(make_bundle stale "$C1")" "$C3"

# ---------------------------------------------------------------------------
# 6. THE LOAD-BEARING CONTROL.
#    Wrapper at c1, daemon at c2. The commits DIFFER. The frontend is BYTE
#    IDENTICAL (c2 touched crates/lib.rs only). This is exactly the live
#    situation measured 2026-08-14: e0234e71 vs acf991bf, three commits apart,
#    empty frontend diff.
#
#    A SHA-equality gate returns 1 here and fails a CORRECT bundle. This gate
#    must return 0. If this control ever goes red, the gate has been rewritten
#    onto the wrong axis and will be switched off by the next person it blocks.
# ---------------------------------------------------------------------------
check "commits differ, frontend identical -> STILL PASSES" 0 "$(make_bundle behind "$C1")" "$C2"

# 7. cannot-run cases are rc=2 and are NOT passes
out="$(bash "$GATE" 2>&1)"; rc=$?
if [[ "$rc" == 2 ]]; then printf '  PASS  %-52s rc=2\n' "bare usage -> CANNOT (2), not a pass"; PASS=$((PASS+1))
else printf '  FAIL  %-52s rc=%s want=2\n' "bare usage -> CANNOT" "$rc"; FAIL=$((FAIL+1)); fi

out="$(bash "$GATE" "$TMP/does-not-exist.app" "$REPO" 2>&1)"; rc=$?
if [[ "$rc" == 2 ]]; then printf '  PASS  %-52s rc=2\n' "missing bundle -> CANNOT (2)"; PASS=$((PASS+1))
else printf '  FAIL  %-52s rc=%s want=2\n' "missing bundle -> CANNOT" "$rc"; FAIL=$((FAIL+1)); fi

# 8. THE v1.0.30 BURN, LOCKED IN.
#
# A non-git directory as the reference checkout must be CANNOT-RUN, never a
# pass. This is the exact shape that burnt v1.0.30: download-hub-app extracts
# the Hub app tarball to .../ostler-assistant on the runner, so the SIBLING
# path the script falls back to EXISTS but is not a repo. The directory
# existing is why no earlier check caught it.
#
# The caller (gui/Makefile) now passes OSTLER_ASSISTANT_DIR explicitly. This
# case exists so that fix cannot later be "simplified" back out: if anyone
# drops the second argument, or points it at an extraction directory again,
# the gate must still refuse rather than wave the bundle through.
mkdir -p "$TMP/not-a-repo"
out="$(bash "$GATE" "$(make_bundle good "$C1")" "$TMP/not-a-repo" 2>&1)"; rc=$?
if [[ "$rc" == 2 ]]; then printf '  PASS  %-52s rc=2\n' "non-git reference checkout -> CANNOT (2)"; PASS=$((PASS+1))
else printf '  FAIL  %-52s rc=%s want=2\n' "non-git reference checkout -> CANNOT" "$rc"; FAIL=$((FAIL+1)); fi
# and it must say WHY, not just fail: a bare non-zero would send the next
# reader hunting a stale bundle instead of a mis-wired path.
if grep -q 'reference checkout is not a git repo' <<<"$out"; then
  printf '  PASS  %-52s\n' "and it NAMES the cause (not a git repo)"; PASS=$((PASS+1))
else printf '  FAIL  %-52s\n' "did not name the cause"; FAIL=$((FAIL+1)); fi

echo
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]] || exit 1
echo "ALL PRE-SEAL PROVENANCE GATE TESTS PASSED"
