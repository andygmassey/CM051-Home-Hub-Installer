#!/usr/bin/env bash
#
# tests/test_user_facing_tree.sh
#
# Verifies the user-facing tree creation block in install.sh:
#   - First run with no sentinel creates all 5 subdirs and writes
#     the sentinel file.
#   - Second run with sentinel present is a no-op (we delete a
#     subdir between runs and confirm it stays deleted).
#   - mkdir -p semantics: pre-existing subdirs are not damaged.
#
# Runs the production snippet inside an isolated $HOME under
# mktemp so the developer's real ~/.ostler / ~/Documents/Ostler
# is never touched.
#
# Pure shell. No deps beyond bash + find + mkdir.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${REPO_ROOT}/install.sh"

if [[ ! -f "$SCRIPT_PATH" ]]; then
    echo "FAIL: install.sh not found at $SCRIPT_PATH" >&2
    exit 1
fi

# ── Sandbox setup ────────────────────────────────────────────
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX"

OSTLER_DIR="${HOME}/.ostler"
USER_FACING_ROOT="${HOME}/Documents/Ostler"
USER_TREE_SENTINEL="${OSTLER_DIR}/.installer-tree-created"
USER_TREE_SUBDIRS=("Wiki" "Transcripts" "Daily-Briefs" "Captures" "Exports")

# Stub the install.sh logging helpers used inside the snippet.
info() { :; }
ok()   { :; }

mkdir -p "$OSTLER_DIR"

run_user_tree_snippet() {
    # Mirrors the install.sh production block. Kept in sync by
    # tests/README.md (a divergence here would be the test
    # missing real behaviour, not the other way round).
    if [[ ! -f "$USER_TREE_SENTINEL" ]]; then
        info "Creating user-facing content tree at ${USER_FACING_ROOT}/"
        mkdir -p "$USER_FACING_ROOT"
        for sub in "${USER_TREE_SUBDIRS[@]}"; do
            mkdir -p "${USER_FACING_ROOT}/${sub}"
        done
        {
            echo "Ostler user-facing tree created on $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
            echo "Subdirs: ${USER_TREE_SUBDIRS[*]}"
        } > "$USER_TREE_SENTINEL"
        ok "User-facing tree ready"
    else
        info "User-facing tree already announced (sentinel present); skipping"
    fi
}

assert_subdirs_exist() {
    local label="$1"
    for sub in "${USER_TREE_SUBDIRS[@]}"; do
        if [[ ! -d "${USER_FACING_ROOT}/${sub}" ]]; then
            echo "FAIL [$label]: missing ${USER_FACING_ROOT}/${sub}" >&2
            exit 1
        fi
    done
}

assert_subdirs_absent() {
    local label="$1"
    local sub="$2"
    if [[ -d "${USER_FACING_ROOT}/${sub}" ]]; then
        echo "FAIL [$label]: ${USER_FACING_ROOT}/${sub} unexpectedly present" >&2
        exit 1
    fi
}

# ── Test 1: fresh install creates all 5 subdirs + sentinel ──
run_user_tree_snippet
assert_subdirs_exist "fresh-install"
if [[ ! -f "$USER_TREE_SENTINEL" ]]; then
    echo "FAIL: sentinel not written on first run" >&2
    exit 1
fi
echo "PASS: fresh install creates all 5 subdirs and writes the sentinel"

# ── Test 2: sentinel-gated re-run is a no-op ────────────────
# Delete a subdir to simulate the customer's deliberate removal.
# The sentinel is in place, so the re-run must NOT re-create it.
rm -rf "${USER_FACING_ROOT}/Captures"
run_user_tree_snippet
assert_subdirs_absent "re-run-after-delete" "Captures"
echo "PASS: sentinel short-circuits re-run; deleted subdir stays deleted"

# ── Test 3: mkdir -p does not damage pre-existing content ──
# Reset the sandbox, pre-seed the destination with content, and
# run the snippet. The pre-seeded file must survive.
rm -rf "$OSTLER_DIR" "${HOME}/Documents"
mkdir -p "$OSTLER_DIR" "${USER_FACING_ROOT}/Wiki"
SEED_FILE="${USER_FACING_ROOT}/Wiki/seeded-page.md"
echo "do-not-clobber" > "$SEED_FILE"
run_user_tree_snippet
if [[ "$(cat "$SEED_FILE")" != "do-not-clobber" ]]; then
    echo "FAIL: pre-existing content was clobbered" >&2
    exit 1
fi
assert_subdirs_exist "pre-seeded"
echo "PASS: mkdir -p preserves pre-existing content; tree still created"

# ── Test 4: snippet is in sync with install.sh ──────────────
# Cheap smoke that the production block contains the expected
# sentinel name and subdir list. Catches a future refactor that
# renames either of these without updating the test fixture.
if ! grep -q "USER_TREE_SENTINEL=" "$SCRIPT_PATH"; then
    echo "FAIL: install.sh does not declare USER_TREE_SENTINEL" >&2
    exit 1
fi
if ! grep -q "USER_TREE_SUBDIRS=" "$SCRIPT_PATH"; then
    echo "FAIL: install.sh does not declare USER_TREE_SUBDIRS" >&2
    exit 1
fi
for sub in "${USER_TREE_SUBDIRS[@]}"; do
    if ! grep -q "\"$sub\"" "$SCRIPT_PATH"; then
        echo "FAIL: install.sh does not list subdir \"$sub\"" >&2
        exit 1
    fi
done
echo "PASS: install.sh declares matching constants and subdir list"

echo ""
echo "All user-facing tree tests passed."
