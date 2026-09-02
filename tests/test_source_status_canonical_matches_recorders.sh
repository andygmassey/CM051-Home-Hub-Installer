#!/usr/bin/env bash
#
# tests/test_source_status_canonical_matches_recorders.sh
#
# G3 discrimination (Archie's review point (a), the #1347 class): the set of
# sources /api/v1/sources SERVES must be EXACTLY the set install.sh writes a
# hydrate recorder for. Those are two files in two repos that cannot share a
# constant, so they drift silently unless something compares them:
#
#   SERVED    _SOURCE_KINDS in the vendored web_ui.py
#   WRITTEN   the first arg to _hydrate_sentinel_record* in install.sh
#
# A source SERVED but never WRITTEN is a phantom row -- `not_run` forever, which
# reads as "a source you have that never landed" when in truth nothing was ever
# going to write it. A source WRITTEN but never SERVED vanishes from the panel.
# Either way the artefact stops being the ONE record all three consumers read.
# This is also what makes the reader's `not_run` HONEST: it means "this recorder
# exists and has not fired", not "no such recorder", because the served set IS
# the recorder set.
#
# Exit 0 they match / 1 they drifted / 2 could not run.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${REPO_ROOT}/install.sh"
WEBUI="${REPO_ROOT}/vendor/doctor/agent/web_ui.py"
[[ -f "$INSTALL" ]] || { echo "CANNOT-RUN: install.sh not found (exit 2)" >&2; exit 2; }
[[ -f "$WEBUI"   ]] || { echo "CANNOT-RUN: vendored web_ui.py not found (exit 2)" >&2; exit 2; }

# WRITTEN: the source arg of every recorder CALL (non-comment lines only, so a
# comment showing an example call cannot inflate the set).
written="$(grep -vE '^[[:space:]]*#' "$INSTALL" \
    | grep -oE '_hydrate_sentinel_record(_error|_no_data|_cannot_run)?[[:space:]]+"?[a-z_]+"?' \
    | sed -E 's/.*record(_error|_no_data|_cannot_run)?[[:space:]]+"?//; s/"$//' \
    | sort -u)"

# SERVED: the keys of _SOURCE_KINDS in the vendored reader.
served="$(python3 - "$WEBUI" <<'PY'
import sys, re
src = open(sys.argv[1]).read()
try:
    i = src.index("_SOURCE_KINDS = {")
    blk = src[i:src.index("}", i)]
except ValueError:
    sys.exit(2)
for name in sorted(re.findall(r'"([a-z_]+)"\s*:', blk)):
    print(name)
PY
)"
rc=$?
[[ "$rc" -eq 2 ]] && { echo "CANNOT-RUN: could not locate _SOURCE_KINDS in web_ui.py (exit 2)" >&2; exit 2; }

if [[ -z "$written" ]]; then
    echo "CANNOT-RUN: found 0 recorder call-sites in install.sh -- suspect the predicate (exit 2)" >&2
    exit 2
fi
if [[ -z "$served" ]]; then
    echo "CANNOT-RUN: _SOURCE_KINDS parsed to 0 sources (exit 2)" >&2
    exit 2
fi

only_written="$(comm -23 <(printf '%s\n' "$written") <(printf '%s\n' "$served"))"
only_served="$(comm -13 <(printf '%s\n' "$written") <(printf '%s\n' "$served"))"

echo "written (recorders): $(printf '%s ' $written)"
echo "served  (_SOURCE_KINDS): $(printf '%s ' $served)"

fail=0
if [[ -n "$only_written" ]]; then
    echo "  [FAIL] WRITTEN but not SERVED (missing rows -- the panel never shows these): $(printf '%s ' $only_written)" >&2
    fail=1
fi
if [[ -n "$only_served" ]]; then
    echo "  [FAIL] SERVED but not WRITTEN (phantom rows -- not_run forever): $(printf '%s ' $only_served)" >&2
    fail=1
fi

if [[ "$fail" -eq 0 ]]; then
    echo "  [pass] the served set is EXACTLY the recorder set ($(printf '%s\n' $served | wc -l | tr -d ' ') sources); no phantom, no missing."
fi
exit "$fail"
