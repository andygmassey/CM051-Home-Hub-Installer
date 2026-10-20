#!/usr/bin/env bash
# A SHAZAM EXPORT DROPPED IN DOWNLOADS IS FOUND, AND A REFUSED ONE IS SAID.
#
# Shazam history is only reachable as an owner export (no on-device API gives
# the owner's library), and the CM019 ShazamParser accepts ONE documented CSV
# shape and refuses the rest. This pins the two customer-visible halves, using
# the SHIPPED watcher (extracted from install.sh) and the SHIPPED Doctor reader
# (AST-extracted from vendor/doctor/agent/web_ui.py), the same way
# test_doctor_shows_why_downloads_exports_did_not_import.sh does:
#
#   A. a real-shaped shazamlibrary.csv: the watcher finds it, runs the
#      importer, and the Doctor row says "1 found, 1 imported".
#   B. a Shazam-named CSV in a shape the parser would refuse: found, NOT
#      imported, and the Doctor row says why ("did not guess").
#   C. a header-only export (the forum-reported empty file): found, NOT
#      imported, and the Doctor row says there are no tagged songs.
#   D. CONTROL: an unrelated songs.csv is not claimed at all (found 0).
#   E. the lib table verdicts directly (import / skip / skip / nothing).
#
# Synthetic fixtures only (example artists, invented track keys, no location).
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

SB="$(mktemp -d "${TMPDIR:-/tmp}/shazam-dl.XXXXXX")" || { echo "CANNOT-RUN: no scratch dir" >&2; exit 2; }
trap 'rm -rf "$SB"' EXIT

SCAN="$SB/ostler-scan-exports"
awk '/^cat > "\$\{OSTLER_DIR\}\/bin\/ostler-scan-exports" <<'"'"'SCANEOF'"'"'$/{f=1;next} /^SCANEOF$/{f=0} f' \
    "$INSTALL" > "$SCAN"
[ -s "$SCAN" ] || { echo "CANNOT-RUN: could not extract ostler-scan-exports" >&2; exit 2; }
mkdir -p "$SB/shim"
printf '#!/bin/bash\nexit 0\n' > "$SB/shim/osascript"; chmod +x "$SB/shim/osascript"

GOOD=$'Shazam Library\nIndex,TagTime,Title,Artist,URL,TrackKey\n1,2024-06-13,Example Song One,Example Artist A,https://www.example.com/track/100001,100001\n2,2024-06-11,Example Song Two,Example Artist B,https://www.example.com/track/100002,100002\n'
WRONG=$'Song,When\nExample Song One,2024-06-13\n'
EMPTY=$'Shazam Library\nIndex,TagTime,Title,Artist,URL,TrackKey\n'

_box() {  # $1 name, $2 file name, $3 body
    local h="$SB/$1"
    mkdir -p "$h/.ostler/lib" "$h/.ostler/bin" "$h/Downloads"
    cp "$LIB" "$h/.ostler/lib/ostler-detect-exports.sh"
    printf '#!/bin/bash\nexit 0\n' > "$h/.ostler/bin/ostler-import"
    chmod +x "$h/.ostler/bin/ostler-import"
    printf '%s' "$3" > "$h/Downloads/$2"
    touch -t 202601010000 "$h/Downloads/$2"
    printf '%s\n' "$h"
}
_run() { HOME="$1" PATH="$SB/shim:$PATH" OSTLER_CATCHUP_BUDGET_SECONDS=0 /bin/bash "$SCAN" >/dev/null 2>&1; }

A="$(_box good shazamlibrary.csv "$GOOD")";   _run "$A"
W="$(_box wrong shazamlibrary.csv "$WRONG")"; _run "$W"
H="$(_box empty shazamlibrary.csv "$EMPTY")"; _run "$H"
D="$(_box control songs.csv "$GOOD")";        _run "$D"

python3 - "$MOD" "$LIB" "$A" "$W" "$H" "$D" <<'PY'
import ast, html, json, os, pathlib, re, subprocess, sys, types

MOD, LIB, A, W, H, D = sys.argv[1:7]
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
    return rows.get("downloads_exports"), cells

print("=== A SHAZAM EXPORT IS FOUND, AND A REFUSED ONE IS SAID ===")
for name, box in (("A", A), ("W", W), ("H", H), ("D", D)):
    if not (pathlib.Path(box) / ".ostler/state/source_activity/downloads_exports.tsv").is_file():
        print("CANNOT-RUN: the shipped watcher wrote no record for box %s" % name, file=sys.stderr)
        raise SystemExit(2)

print("-- A. a real-shaped shazamlibrary.csv --")
row, cells = view(A)
if row and row.get("status") == "ok" and row.get("found") == 1 and row.get("imported") == 1:
    ok("api row: ok, found 1, imported 1")
else:
    bad("A api row: %r" % (row,))
if cells and cells[2] == "1 found, 1 imported":
    ok("Doctor items cell: %r" % cells[2])
else:
    bad("A Doctor cells: %r" % (cells,))

print("-- B. a Shazam-named CSV in a shape the parser refuses --")
row, cells = view(W)
if row and row.get("status") == "not_imported" and row.get("found") == 1 and row.get("imported") == 0:
    ok("api row: not_imported, found 1, imported 0")
else:
    bad("W api row: %r" % (row,))
if cells and "Title, Artist and TagTime" in cells[1] and "did not guess" in cells[1]:
    ok("Doctor says why, in plain words")
else:
    bad("W Doctor cells: %r" % (cells,))

print("-- C. a header-only export --")
row, cells = view(H)
if row and row.get("status") == "not_imported" and row.get("imported") == 0:
    ok("api row: not_imported")
else:
    bad("H api row: %r" % (row,))
if cells and "no tagged songs" in cells[1]:
    ok("Doctor says there are no tagged songs")
else:
    bad("H Doctor cells: %r" % (cells,))

print("-- D. CONTROL: an unrelated songs.csv is not claimed --")
row, cells = view(D)
if row and row.get("found") in (0, None) and row.get("status") in ("no_data", "not_run"):
    ok("not claimed: status=%s found=%s" % (row.get("status"), row.get("found")))
else:
    bad("D api row: %r" % (row,))

print("-- E. the lib table, directly --")
import tempfile
def loose(d):
    r = subprocess.run(["bash", LIB, d, "--loose"], capture_output=True, text=True)
    return [l.split("\t") for l in r.stdout.splitlines()]
for label, box, verdict in (("good", A, "import"), ("wrong", W, "skip"), ("empty", H, "skip")):
    out = loose(str(pathlib.Path(box) / "Downloads"))
    if len(out) == 1 and out[0][0] == "Shazam library" and out[0][2] == verdict:
        ok("%s -> %s" % (label, verdict))
    else:
        bad("%s: wanted %s, got %r" % (label, verdict, out))
if loose(str(pathlib.Path(D) / "Downloads")) == []:
    ok("control songs.csv -> no line")
else:
    bad("control songs.csv was claimed")

print("\n== %d pass / %d fail / %d total ==" % (PASS, FAIL, PASS + FAIL))
raise SystemExit(1 if FAIL else 0)
PY
