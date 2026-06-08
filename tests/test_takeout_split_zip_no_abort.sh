#!/usr/bin/env bash
#
# tests/test_takeout_split_zip_no_abort.sh
#
# CX-127: the Gmail/Takeout mbox extraction must NEVER abort the whole
# install when the zip holds no .mbox member. A split multi-part Google
# Takeout (takeout-...-6-001.zip / -7-001.zip) has parts with no mailbox;
# the extraction helper `sys.exit(1)` on those. Under the script-wide
# `set -Eeuo pipefail`, a bare `VAR=$(... exit 1)` assignment aborts the
# entire install on the spot -- jumping over the graceful warn-and-continue
# branch and killing a fully-recoverable optional step with no error line
# and no DONE marker (the GUI then shows "failed"). This is the launch
# blocker hit on the clean Studio install on 2026-06-08.
#
# This test:
#   1. Asserts install.sh's real EXTRACTED_MBOX assignment is `||`-guarded.
#   2. Behaviourally reproduces the exact pattern: builds a synthetic zip
#      with NO .mbox (a split-part stand-in), runs the GUARDED form under
#      `set -Eeuo pipefail`, and asserts execution survives to a sentinel.
#   3. RED control: runs the UNGUARDED form and asserts it aborts BEFORE the
#      sentinel -- proving the guard is load-bearing.
#
# Synthetic only (a zip we build here, no .mbox, no real archive). Pure bash
# + stdlib python3 zipfile.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${SCRIPT_DIR}/../install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$INSTALL_SH" ]] || fail "install.sh not found"
bash -n "$INSTALL_SH" || fail "install.sh fails bash -n"
echo "PASS: install.sh parses"

# 1. Static guard: the real assignment must be `|| `-guarded so set -e
#    cannot abort on a non-zero extractor exit.
if ! grep -Eq 'EXTRACTED_MBOX=\$\(python3 -c' "$INSTALL_SH"; then
    fail "could not find the EXTRACTED_MBOX=\$(python3 -c ...) assignment in install.sh"
fi
# The closing line of that command substitution must carry a `|| ` fallback.
if ! grep -Eq '2>/dev/null\) \|\| EXTRACTED_MBOX=' "$INSTALL_SH"; then
    fail "EXTRACTED_MBOX command-substitution is NOT '|| '-guarded -- a no-mbox/split-Takeout exit will abort the install under set -e"
fi
echo "PASS: install.sh EXTRACTED_MBOX assignment is '|| '-guarded"

# 2 + 3. Behavioural reproduction with a synthetic no-mbox zip.
ZIP="$WORK/takeout-split-part-6-001.zip"
python3 - "$ZIP" <<'PY'
import sys, zipfile
# A split-Takeout part with NO .mbox member (mailbox lives in another part).
with zipfile.ZipFile(sys.argv[1], "w") as zf:
    zf.writestr("Takeout/archive_browser.html", "<html>not a mailbox</html>")
    zf.writestr("Takeout/Mail/README.txt", "the mbox is in another part")
PY
[[ -f "$ZIP" ]] || fail "could not build synthetic split-Takeout zip"

# The extraction helper, structurally identical to install.sh's (no .mbox
# member -> sys.exit(1)).
read -r -d '' EXTRACT_PY <<'PY' || true
import sys, zipfile
from pathlib import Path
zip_path = Path(sys.argv[1])
dest = Path(sys.argv[2])
try:
    with zipfile.ZipFile(zip_path, 'r') as zf:
        members = [m for m in zf.namelist() if m.lower().endswith('.mbox')]
        if not members:
            print('', file=sys.stderr)
            sys.exit(1)
        print(zf.extract(members[0], dest))
except Exception as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
PY

# GREEN: the guarded form must survive to the sentinel under set -Eeuo pipefail.
GREEN_RC=0
bash -c '
    set -Eeuo pipefail
    EXTRACTED_MBOX=$(python3 -c "$1" "$2" "$3" 2>/dev/null) || EXTRACTED_MBOX=""
    if [[ -n "$EXTRACTED_MBOX" && -f "$EXTRACTED_MBOX" ]]; then
        echo "EXTRACTED:$EXTRACTED_MBOX"
    else
        echo "WARN_CONTINUE: no mbox, carrying on"
    fi
    echo "SENTINEL_REACHED"
' _ "$EXTRACT_PY" "$ZIP" "$WORK" > "$WORK/green.out" 2>&1 || GREEN_RC=$?
grep -q "SENTINEL_REACHED" "$WORK/green.out" \
    || fail "GUARDED form did not reach the sentinel (rc=$GREEN_RC): $(cat "$WORK/green.out")"
grep -q "WARN_CONTINUE" "$WORK/green.out" \
    || fail "GUARDED form did not hit the warn-and-continue branch: $(cat "$WORK/green.out")"
echo "PASS: guarded extraction survives a no-mbox split-Takeout zip and continues"

# RED control: the UNGUARDED form must abort BEFORE the sentinel.
bash -c '
    set -Eeuo pipefail
    EXTRACTED_MBOX=$(python3 -c "$1" "$2" "$3" 2>/dev/null)
    echo "SENTINEL_REACHED"
' _ "$EXTRACT_PY" "$ZIP" "$WORK" > "$WORK/red.out" 2>&1 || true
if grep -q "SENTINEL_REACHED" "$WORK/red.out"; then
    fail "RED control: the UNGUARDED form reached the sentinel -- this host does not reproduce the set -e abort, so the test cannot prove the guard is load-bearing"
fi
echo "PASS: red-control -- the UNGUARDED form aborts before the sentinel (set -e abort reproduced)"

echo ""
echo "ALL TAKEOUT SPLIT-ZIP NO-ABORT TESTS PASSED"
