#!/usr/bin/env bash
# THE DOCTOR SAYS WHY A DOWNLOADS EXPORT DID NOT IMPORT (#30).
#
# MEASURED on a synthetic walk box (studio29, v1.0.107 candidate): loose
# exports sat in ~/Downloads, the watcher imported none of them, and the
# Doctor's "Where your data came from" table had no row for the watcher at
# all. "Found nothing", "could not look" and "found three, imported none" all
# rendered as the same nothing.
#
# This is the CONSUMER half. The record is not hand-written: the SHIPPED
# watcher (extracted from install.sh) is run against a fake HOME so that it
# writes state/source_activity/downloads_exports.tsv itself, and then the
# SHIPPED read_source_status + render_source_status (AST-extracted from
# vendor/doctor/agent/web_ui.py) read it. So a writer/reader vocabulary drift
# between the two fails here, not on a customer's Mac.
#
# Synthetic fixtures only (example.com, invented names).
# THREE OUTCOMES. 0 pass, 1 fail, 2 CANNOT-RUN (which is not a pass).
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="${REPO}/install.sh"
LIB="${REPO}/lib/ostler-detect-exports.sh"
MOD="${REPO}/vendor/doctor/agent/web_ui.py"
for f in "$INSTALL" "$LIB" "$MOD"; do
    [ -f "$f" ] || { echo "CANNOT-RUN: missing ${f}" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3" >&2; exit 2; }

SB="$(mktemp -d "${TMPDIR:-/tmp}/doctor-dl.XXXXXX")" || { echo "CANNOT-RUN: no scratch dir" >&2; exit 2; }
trap 'rm -rf "$SB"' EXIT

SCAN="$SB/ostler-scan-exports"
awk '/^cat > "\$\{OSTLER_DIR\}\/bin\/ostler-scan-exports" <<'"'"'SCANEOF'"'"'$/{f=1;next} /^SCANEOF$/{f=0} f' \
    "$INSTALL" > "$SCAN"
[ -s "$SCAN" ] || { echo "CANNOT-RUN: could not extract ostler-scan-exports" >&2; exit 2; }
mkdir -p "$SB/shim"
printf '#!/bin/bash\nexit 0\n' > "$SB/shim/osascript"; chmod +x "$SB/shim/osascript"

_box() {  # $1 name, $2 importer exit code
    local h="$SB/$1"
    mkdir -p "$h/.ostler/lib" "$h/.ostler/bin" "$h/Downloads"
    cp "$LIB" "$h/.ostler/lib/ostler-detect-exports.sh"
    printf '#!/bin/bash\nexit %s\n' "$2" > "$h/.ostler/bin/ostler-import"
    chmod +x "$h/.ostler/bin/ostler-import"
    printf '%s\n' "$h"
}
_run() { HOME="$1" PATH="$SB/shim:$PATH" OSTLER_CATCHUP_BUDGET_SECONDS=0 /bin/bash "$SCAN" >/dev/null 2>&1; }

# Box A: only a loose contact card, which no importer reads -> not_imported.
A="$(_box vcf 0)"
printf 'BEGIN:VCARD\nVERSION:3.0\nFN:Jane Doe\nEMAIL:pat@example.com\nEND:VCARD\n' > "$A/Downloads/contacts.vcf"
touch -t 202601010000 "$A/Downloads/contacts.vcf"
_run "$A"
# Box B: a mailbox whose import fails -> error, with the exit code.
B="$(_box failing 3)"
printf 'From pat@example.com Thu, 01 Jan 2026 00:00:00 +0000\nFrom: Jane Doe <pat@example.com>\n\nhello\n' > "$B/Downloads/emails.mbox"
touch -t 202601010000 "$B/Downloads/emails.mbox"
_run "$B"
# Box C: the watcher has never run (no record at all).
C="$(_box never 0)"

python3 - "$MOD" "$A" "$B" "$C" <<'PY'
import ast, html, json, os, pathlib, re, sys, types

MOD, A, B, C = sys.argv[1:5]
PASS = FAIL = 0
def ok(m):
    global PASS; PASS += 1; print("  [PASS] " + m)
def bad(m):
    global FAIL; FAIL += 1; print("  [FAIL] " + m)

fake = types.ModuleType("routine_status")
fake.read_routine_status = lambda: []
sys.modules["routine_status"] = fake

tree = ast.parse(pathlib.Path(MOD).read_text(encoding="utf-8"))
wanted = {"_source_activity_dir", "_read_source_activity", "_source_hydrate_dir",
          "_parse_source_sentinel", "read_source_status", "render_source_status",
          "_routine_evidence", "_routine_run_count", "_best_routine_count",
          "_settling_progress_total",
          "_catchup_state_dir", "_read_catchup_by_row", "_catchup_phrase",
          "_ostler_state_root", "_positive_int", "_settling_done",
          "_extract_summary_count", "_distinct_pages", "_canonical_total",
          "_mail_available_total", "_source_count_label"}
ns = {"Path": pathlib.Path, "os": os, "json": json, "html": html}
for node in tree.body:
    if isinstance(node, (ast.Assign, ast.AnnAssign)):
        try:
            exec(compile(ast.Module([node], []), "<const>", "exec"), ns)
        except Exception:
            pass
for node in tree.body:
    if isinstance(node, ast.FunctionDef) and node.name in wanted:
        exec(compile(ast.Module([node], []), "<fn>", "exec"), ns)
core = {"read_source_status", "render_source_status", "_source_activity_dir"}
if core - set(ns):
    print("CANNOT-RUN: web_ui.py has no " + ", ".join(sorted(core - set(ns))), file=sys.stderr)
    raise SystemExit(2)

def view(home):
    root = pathlib.Path(home) / ".ostler"
    for k in ("OSTLER_DIR", "OSTLER_HOME"):
        os.environ[k] = str(root)
    rows = {r.get("source"): r for r in ns["read_source_status"]()}
    page = ns["render_source_status"]()
    cells = None
    for tr in re.findall(r"<tr>(.*?)</tr>", page, re.S):
        tds = [re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", c)).strip()
               for c in re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)]
        if tds and tds[0] == "Downloads folder":
            cells = tds
    return rows.get("downloads_exports"), cells, page

print("=== THE DOCTOR SAYS WHY A DOWNLOADS EXPORT DID NOT IMPORT ===")

rec_a = pathlib.Path(A) / ".ostler/state/source_activity/downloads_exports.tsv"
if not rec_a.is_file():
    print("CANNOT-RUN: the shipped watcher wrote no record, so the Doctor half has nothing to read", file=sys.stderr)
    raise SystemExit(2)

print("-- A. a loose contact card: found 1, imported 0, and why --")
row, cells, page = view(A)
if row is None or cells is None:
    bad("the Doctor has no Downloads row: the watcher's record is written and never read")
else:
    ok("the Doctor table has a Downloads folder row")
    if row.get("status") == "not_imported" and "found, not imported" in cells[1]:
        ok("status cell: %r" % cells[1].split(" Ostler")[0])
    else:
        bad("status: api=%r cell=%r" % (row.get("status"), cells[1]))
    if "contact card" in cells[1].lower():
        ok("the reason is shown under the status, in the customer's words")
    else:
        bad("no reason in the row: %r" % cells[1])
    if cells[2] == "1 found, 0 imported":
        ok("items cell: %r" % cells[2])
    else:
        bad("items cell %r, wanted '1 found, 0 imported'" % cells[2])
    if row.get("reason") and row.get("found") == 1 and row.get("imported") == 0:
        ok("the /api/v1/sources row carries found, imported and reason")
    else:
        bad("API row: %r" % row)

print("-- B. an import that failed: error, with the exit code --")
row, cells, page = view(B)
if row is None or cells is None:
    bad("no Downloads row for a failed import")
else:
    if row.get("status") == "error" and "exit code 3" in cells[1]:
        ok("failed import: %r" % cells[1])
    else:
        bad("failed import not said: api=%r cell=%r" % (row.get("status"), cells[1]))

print("-- C. CONTROL: never ran is said, not omitted and not invented --")
row, cells, page = view(C)
if row is not None and row.get("status") == "not_run" and cells and "not run yet" in cells[1]:
    ok("no record: %r" % cells[1])
else:
    bad("a watcher that never ran: api=%r cells=%r" % (row, cells))
if row is not None and row.get("count_label") is None and cells and cells[2] in ("\u2014", "&mdash;", ""):
    ok("CONTROL: no record, no invented count")
else:
    bad("an absent record produced a count: %r" % (cells,))

print("\n== %d pass / %d fail / %d total ==" % (PASS, FAIL, PASS + FAIL))
raise SystemExit(1 if FAIL else 0)
PY
