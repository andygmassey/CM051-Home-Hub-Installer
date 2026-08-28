#!/usr/bin/env bash
#
# test_qdrant_guard_fires.sh
#
# #550 -- THE MUTATION ARM FOR test_qdrant_publishes_no_host_port.sh.
#
# That guard passing proves nothing on its own. It would pass identically if
# its predicate were broken, if the qdrant block were renamed out from under
# it, or if someone replaced its body with `exit 0`. A gate that has never
# been seen to REJECT anything is a gate that compiles, not a gate that fires.
#
# This test re-introduces the exact defect #550 was raised for -- the
# published gRPC port --
#
#     ports:
#       - "127.0.0.1:6334:6334"
#
# -- and requires the guard to return non-zero. Then it restores the tree and
# requires the guard to return zero again, so a failure here can never leave a
# mutated install.sh behind for a later step to read.
#
# It lives as a TEST rather than as inline workflow YAML deliberately: logic
# embedded in a `run:` block cannot be executed locally, so it rots unseen and
# is only ever exercised by the CI it is supposed to validate.
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
GUARD="$REPO_ROOT/tests/test_qdrant_publishes_no_host_port.sh"
BACKUP="$(mktemp -t ostler-550-install.XXXXXX)"

cleanup() {
    if [ -f "$BACKUP" ]; then
        cp "$BACKUP" "$INSTALL_SH"
        rm -f "$BACKUP"
    fi
}
trap cleanup EXIT INT TERM

[ -f "$INSTALL_SH" ] || { echo "FAIL: install.sh not found -- CANNOT-RUN" >&2; exit 1; }
[ -f "$GUARD" ]      || { echo "FAIL: the guard under test is missing -- CANNOT-RUN" >&2; exit 1; }

cp "$INSTALL_SH" "$BACKUP"

# ── ARM 1: the tree as committed. The guard must PASS. ───────────────
if ! bash "$GUARD" >/dev/null 2>&1; then
    echo "FAIL: the guard is RED on the committed tree." >&2
    echo "      Either qdrant publishes a port (the defect is live) or the" >&2
    echo "      guard is broken. Run it directly for the detail." >&2
    exit 1
fi
echo "ok: arm 1 -- guard PASSES on the committed tree"

# ── ARM 2: reintroduce the defect. The guard must FAIL. ──────────────
python3 - "$INSTALL_SH" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()

anchor = '      QDRANT__SERVICE__API_KEY: "${QDRANT_API_KEY:-}"\n    volumes:'
defect = (
    '      QDRANT__SERVICE__API_KEY: "${QDRANT_API_KEY:-}"\n'
    '    ports:\n'
    '      - "127.0.0.1:6334:6334"\n'
    '    volumes:'
)

n = src.count(anchor)
if n != 1:
    raise SystemExit(
        f"CANNOT-RUN: the mutation anchor matched {n} times, expected 1.\n"
        "The qdrant block has been restructured. FIX THIS ARM rather than\n"
        "deleting it -- without it the guard has no proof of life."
    )

open(path, "w").write(src.replace(anchor, defect, 1))
PY
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "FAIL: could not apply the mutation (rc=$rc) -- CANNOT-RUN, not a pass" >&2
    exit 1
fi

if bash "$GUARD" >/dev/null 2>&1; then
    echo "FAIL: THE GUARD PASSED WITH THE DEFECT PRESENT." >&2
    echo "      It cannot detect a published 6334, so every green verdict it" >&2
    echo "      has ever given is meaningless. This is a broken gate, not a" >&2
    echo "      safe tree." >&2
    exit 1
fi
echo "ok: arm 2 -- guard REJECTS the reintroduced 6334 publish"

# ── ARM 3: restore, and prove the restore worked. ────────────────────
cp "$BACKUP" "$INSTALL_SH"
if ! bash "$GUARD" >/dev/null 2>&1; then
    echo "FAIL: the guard is still RED after restore -- the tree was left" >&2
    echo "      mutated. Any later step reading install.sh would be reading" >&2
    echo "      the wrong artefact." >&2
    exit 1
fi
echo "ok: arm 3 -- tree restored, guard green again"

echo ""
echo "qdrant guard mutation proof: PASS (3 arms)"
