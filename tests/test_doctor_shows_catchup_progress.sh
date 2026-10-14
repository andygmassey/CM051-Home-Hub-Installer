#!/usr/bin/env bash
# Doctor shows how far back each source has been read (v1.0.108 catch-up).
#
# The background catch-up (lib/ostler_catchup.py) writes one watermark per
# source under state/catchup/. The customer reads progress in exactly one
# place, the Doctor's "Where your data came from" table, so that table must
# say, per row: still catching up and how far back, waiting for a quiet
# moment, or finished. A row catch-up has never touched says nothing at all
# (no invented state).
#
# Drives the SHIPPED read_source_status + render_source_status (AST-extracted
# from vendor/doctor/agent/web_ui.py) against synthetic watermark files.
#
# THREE OUTCOMES. CANNOT-RUN (exit 2) is not a pass.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MOD="${REPO}/vendor/doctor/agent/web_ui.py"
[ -f "$MOD" ] || { echo "CANNOT-RUN: no web_ui.py at ${MOD}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3" >&2; exit 2; }

python3 - "$MOD" <<'PY'
import ast, html, json, os, pathlib, re, sys, tempfile, types

MOD = sys.argv[1]
PASS = FAIL = 0
def ok(m):
    global PASS; PASS += 1; print("  [PASS] " + m)
def bad(m):
    global FAIL; FAIL += 1; print("  [FAIL] " + m)

fake = types.ModuleType("routine_status")
fake.read_routine_status = lambda: []
sys.modules["routine_status"] = fake

src = pathlib.Path(MOD).read_text(encoding="utf-8")
tree = ast.parse(src)
wanted = {"_source_activity_dir", "_read_source_activity", "_source_hydrate_dir",
          "_parse_source_sentinel", "read_source_status", "render_source_status",
          "_routine_evidence", "_routine_run_count", "_best_routine_count",
          "_settling_progress_total",
          "_catchup_state_dir", "_read_catchup_by_row", "_catchup_phrase"}
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
missing = sorted(n for n in wanted if n not in ns)
if missing:
    # On a tree without the catch-up reader this is the RED: the Doctor has
    # no way to show catch-up progress at all.
    print("  [FAIL] the Doctor has no catch-up reader: absent " + ", ".join(missing))
    print("\n== 0 pass / 1 fail / 1 total ==")
    raise SystemExit(1)

root = pathlib.Path(tempfile.mkdtemp())
(root / "state" / "hydrate").mkdir(parents=True)
(root / "state" / "source_activity").mkdir(parents=True)
cu = root / "state" / "catchup"
cu.mkdir(parents=True)
os.environ["OSTLER_DIR"] = str(root)
os.environ["OSTLER_HOME"] = str(root)

def wm(source, row, complete, oldest, reason="budget"):
    (cu / (source + ".json")).write_text(json.dumps({
        "schema": 1, "source": source, "doctor_row": row, "complete": complete,
        "oldest_at": oldest, "items_done": 10, "last_tick": {"reason": reason}}))

wm("imessage", "imessage", False, "2021-03-04T10:00:00Z")
wm("whatsapp", "whatsapp", True, "2014-01-01T00:00:00Z", "complete")
wm("safari", "browsing", True, "2012-06-01T00:00:00Z", "complete")
wm("chrome", "browsing", False, "2019-05-20T00:00:00Z")
wm("mail_contacts", "email", False, "2020-01-01T00:00:00Z", "busy:load")
wm("ai_chats", "ai_conversations", False, None)
# CONTROL: a file that is not a schema-1 watermark must not invent a row state.
(cu / "calendar.json").write_text(json.dumps({"schema": 99, "source": "calendar",
                                              "doctor_row": "calendar", "complete": True}))
(cu / "ledger.sqlite").write_bytes(b"not json")

rows = {r["source"]: r for r in ns["read_source_status"]()}
page = ns["render_source_status"]()

def history(page, source):
    for tr in re.findall(r"<tr>(.*?)</tr>", page, re.S):
        tds = [re.sub(r"<[^>]+>", "", c).strip() for c in re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)]
        if tds and tds[0] == source.replace("_", " "):
            return tds[4] if len(tds) > 4 else None
    return None

cases = [
    ("imessage", "Catching up, back to March 2021"),
    ("whatsapp", "All of your history is read"),
    ("browsing", "Catching up, back to May 2019"),   # least advanced of two
    ("email", "Catching up, waiting for a quiet moment"),
    ("ai_conversations", "Catching up, starting"),
    ("calendar", ""),                                  # never touched: blank
    ("contacts", ""),
]
for source, want in cases:
    got = history(page, source)
    if got == want:
        ok("%s: %r" % (source, want))
    else:
        bad("%s: History cell %r, wanted %r" % (source, got, want))

if "<th align=\"left\">History</th>" in page:
    ok("the table has a History column")
else:
    bad("no History column header")

r = rows.get("browsing", {}).get("catchup")
if r and r.get("state") == "catching_up" and r.get("back_to", "").startswith("2019-05") and r.get("sources") == 2:
    ok("the API row carries catchup={state, back_to, sources}: %s" % r)
else:
    bad("browsing API catchup field: %r" % r)
if rows.get("calendar", {}).get("catchup") is None:
    ok("CONTROL: a non-schema file did not invent catch-up state for calendar")
else:
    bad("CONTROL: calendar got %r from a schema-99 file" % rows["calendar"]["catchup"])

found = [w for w in ("—", "recording") if w in page]
if found:
    bad("customer copy contains %r" % found)
else:
    ok("customer copy has no em dash and does not say recording")

print("\n== %d pass / %d fail / %d total ==" % (PASS, FAIL, PASS + FAIL))
raise SystemExit(0 if FAIL == 0 else 1)
PY
