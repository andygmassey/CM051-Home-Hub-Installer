#!/usr/bin/env bash
#
# tests/test_a_box_precondition_is_not_a_build_verdict.sh
#
# A WALK OF AN UNDER-PROVISIONED BOX MUST NOT RECORD A BUILD DEFECT.
#
# install.sh refuses before installing anything when the machine cannot host
# the product: ERR-02-PREREQ-DISK-LOW below 15 GB free (install.sh:4880),
# ERR-02-PREREQ-RAM-LOW (:4865, :8494), ERR-02-PREREQ-XCODE-CLI (:11182).
# None of those is a statement about the artefact.
#
# MEASURED 2026-09-07, before the fix: walk_drive.py contained ZERO references
# to any install error code, so `#OSTLER DONE status=fail` from a disk refusal
# and the same marker from a real product abort were indistinguishable, and
# both returned FAIL. That verdict is written into walks/<v>.tsv, which is
# BOUND TO AN ARTEFACT -- so the box's disk became the build's record.
#
# TWO ARMS, AND THE SECOND IS THE ONE THAT MATTERS. Making the disk case
# CANNOT-RUN is easy; the risk is a pattern loose enough to swallow real
# failures, because CANNOT-RUN is not a pass but it is also not a finding, and
# a defect that reads as "we could not tell" is a defect nobody chases.
#
#   1  a PREREQ refusal          -> CANNOT-RUN (2)
#   2  a real product abort      -> still FAIL (1)   <- the control
#
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DRIVER="${REPO}/scripts/walk_drive.py"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$DRIVER" ] || { echo "CANNOT-RUN: no walk_drive.py at ${DRIVER}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# Drives the REAL adjudicate(), not a copy of its logic.
_adjudicate() {
    local body="$1" h="${WORK}/h"; rm -rf "$h"; mkdir -p "$h"
    printf '%s\n' "$body" > "${h}/pty.log"
    printf 'utc\tprompt\tanswer\n' > "${h}/.walk-qa.tsv"
    HOME="$h" python3 - "$DRIVER" "${h}/pty.log" <<'PY' 2>/dev/null
import sys, importlib.util
spec = importlib.util.spec_from_file_location("wd", sys.argv[1])
wd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wd)
code, headline, _detail = wd.adjudicate(sys.argv[2], 1, True)
print("%d|%s" % (code, headline))
PY
}

printf 'test_a_box_precondition_is_not_a_build_verdict\n'
echo "-- arm 1: a PREREQ refusal is CANNOT-RUN --"
for code in ERR-02-PREREQ-DISK-LOW ERR-02-PREREQ-RAM-LOW ERR-02-PREREQ-XCODE-CLI; do
    r="$(_adjudicate "[fail]  [${code}] not enough disk space
#OSTLER	DONE	status=fail")"
    case "$r" in
        2\|*) ok "${code} -> CANNOT-RUN" ;;
        *)    bad "${code} -> ${r%%|*} (wanted 2). ${r#*|}" ;;
    esac
done

echo "-- arm 2, THE CONTROL: a real product abort must still be FAIL --"
for code in ERR-14-STORE-WIKI-CREDENTIAL ERR-13-MODEL-PULL-NOMIC ERR-10-FDA-MODULE-MISSING; do
    r="$(_adjudicate "[fail]  [${code}] the store never came up
#OSTLER	DONE	status=fail")"
    case "$r" in
        1\|*) ok "${code} -> FAIL, as it must" ;;
        *)    bad "${code} -> ${r%%|*} (wanted 1). A loose pattern that swallows this is worse than no fix. ${r#*|}" ;;
    esac
done

echo "-- arm 3: an abort with NO code at all is still FAIL --"
r="$(_adjudicate "[fail]  something went wrong
#OSTLER	DONE	status=fail")"
case "$r" in
    1\|*) ok "uncoded abort -> FAIL" ;;
    *)    bad "uncoded abort -> ${r%%|*} (wanted 1)" ;;
esac

echo "-- arm 4: PREREQ text WITHOUT the bracket form must not trigger it --"
r="$(_adjudicate "we recommend ERR-02-PREREQ-DISK-LOW is avoided
#OSTLER	DONE	status=fail")"
case "$r" in
    1\|*) ok "unbracketed mention -> FAIL, so prose cannot flip a verdict" ;;
    *)    bad "unbracketed mention -> ${r%%|*} (wanted 1): the pattern is too loose" ;;
esac

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
