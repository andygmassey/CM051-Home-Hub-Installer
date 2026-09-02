#!/usr/bin/env bash
#
# tests/test_source_status_contract.sh
#
# THE CONTRACT between the two halves of the source-status feature, which live
# in DIFFERENT repos and cannot share a type:
#
#   WRITER  CM051 install.sh   _hydrate_sentinel_record* -> key=value .done file
#   READER  vendored doctor    web_ui.py read_source_status() parses it
#
# The record is an on-disk contract, not a shared class (#532: two artefacts,
# one consumer). If the writer emits a key the reader does not read, or the
# reader expects a key the writer never writes, the panel blanks silently on a
# real box and nothing fails in CI -- unless this test does. Both halves are
# EXTRACTED and RUN for real, so neither can pass against a copy of the logic.
#
# Exit 0 pass / 1 the contract drifted / 2 could not run.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${REPO_ROOT}/install.sh"
WEBUI="${REPO_ROOT}/vendor/doctor/agent/web_ui.py"
[[ -f "$INSTALL" ]] || { echo "CANNOT-RUN: install.sh not found (exit 2)" >&2; exit 2; }
[[ -f "$WEBUI"   ]] || { echo "CANNOT-RUN: vendored web_ui.py not found (exit 2)" >&2; exit 2; }
grep -q 'def read_source_status' "$WEBUI" || {
    echo "CANNOT-RUN: read_source_status() absent from web_ui.py -- the reader half is gone (exit 2)" >&2
    exit 2
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/contract-XXXXXX")" || { echo "CANNOT-RUN: mktemp (exit 2)" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
HYDRATE="$TMP/hydrate"; mkdir -p "$HYDRATE"

# ---- WRITE side: the REAL install.sh recorders ----
extract() {
    local body; body="$(sed -n "/^$1() {/,/^}/p" "$INSTALL")"
    [[ -n "$body" ]] || { echo "CANNOT-RUN: $1() not found in install.sh (exit 2)" >&2; exit 2; }
    printf '%s\n' "$body"
}
{
    printf '_HYDRATE_SENTINEL_DIR=%q\n' "$HYDRATE"
    printf 'gui_step_record_rc() { :; }\n'
    extract _hydrate_payload_count
    extract _hydrate_compute_change
    extract _hydrate_payload_is_all_zero
    extract _hydrate_sentinel_record
    extract _hydrate_sentinel_record_no_data
} > "$TMP/writer.sh"
# shellcheck source=/dev/null
source "$TMP/writer.sh"

_hydrate_sentinel_record people "people=42"      # a source that landed data
_hydrate_sentinel_record_no_data browsing "no_export_found"   # ran, found nothing

# ---- READ side: the REAL vendored reader ----
python3 - "$WEBUI" "$HYDRATE" <<'PY'
import sys
from pathlib import Path

src = open(sys.argv[1]).read()
try:
    start = src.index("_SOURCE_KINDS = {")
    end = src.index('@app.get("/api/v1/sources"')
except ValueError:
    print("CANNOT-RUN: could not locate the reader block in web_ui.py (exit 2)", file=sys.stderr)
    sys.exit(2)
block = "from pathlib import Path\nimport os\n" + src[start:end]
ns = {}
exec(block, ns)  # noqa: S102 -- executing the SHIPPED reader is the point

rows = {r["source"]: r for r in ns["read_source_status"](Path(sys.argv[2]))}
fails = 0
def chk(c, label):
    global fails
    print(f"  [{'pass' if c else 'FAIL'}] {label}"); fails += 0 if c else 1

p = rows["people"]
# The writer wrote people=42 with the G1a/G1b fields; the reader must read each,
# and item_count must arrive TYPED (a string 42 would fail == 42 and read as
# broken to a panel that renders a number).
chk(p["status"] == "ok", "reader reads the writer's status=ok")
chk(p["item_count"] == 42 and isinstance(p["item_count"], int),
    f"reader reads the writer's item_count as typed int 42 (got {p['item_count']!r})")
chk(p["recorded_at"] is not None, "reader reads recorded_at the writer wrote")
chk(p["last_update_at"] is not None, "reader reads last_update_at the writer wrote (G1a)")

b = rows["browsing"]
chk(b["status"] == "no_data", "reader reads the writer's no_data status")
chk(b["item_count"] == 0, f"no_data round-trips item_count 0 (got {b['item_count']!r})")

# The contract's other direction: nothing the writer emitted is left unread. The
# reader's own row keys must cover the meaningful writer keys.
writer_keys = set()
for line in (Path(sys.argv[2]) / "people.done").read_text().splitlines():
    k = line.split("=", 1)[0].strip()
    if k:
        writer_keys.add(k)
reader_covers = {"recorded_at", "source", "status", "item_count", "last_update_at"}
missing = (writer_keys & reader_covers) - set()  # sanity: those keys exist writer-side
chk(reader_covers.issubset(writer_keys | {"detail"}),
    f"every field the reader keys on is one the writer emits (writer wrote: {sorted(writer_keys)})")

sys.exit(1 if fails else 0)
PY
rc=$?
echo
if [[ "$rc" -eq 0 ]]; then
    echo "source-status writer<->reader contract: OK"
elif [[ "$rc" -eq 2 ]]; then
    echo "source-status contract: CANNOT-RUN"
else
    echo "source-status contract: DRIFTED (a field does not round-trip)"
fi
exit "$rc"
