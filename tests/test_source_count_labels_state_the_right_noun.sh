#!/usr/bin/env bash
# Ostler #30 walk: Doctor Data sources rows named the wrong thing.
#   Mail: "28 emails (most recent check)" shown as if it were the total
#   WhatsApp: DM-chat count labelled "messages"
#   Safari: visits labelled "web pages"; Photos: events labelled "photos"
#   Notes: 913 here vs 971 in the wiki
# Pins _source_count_label / _payload_counts / _read_source_totals. All values
# are FABRICATED fixtures. Outcomes: PASS / FAIL / CANNOT-RUN (exit 2).
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MOD="${REPO}/vendor/doctor/agent/web_ui.py"
[ -f "$MOD" ] || { echo "CANNOT-RUN: no web_ui.py at ${MOD}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3" >&2; exit 2; }
python3 - "$MOD" <<'PY'
import sys, ast, json, tempfile, pathlib, os
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
need = ["def _source_count_label(", "def _payload_counts(", "def _read_source_totals("]
miss = [n for n in need if n not in src]
PASS = FAIL = 0
def chk(cond, msg):
    global PASS, FAIL
    if cond: PASS += 1; print("  [PASS] " + msg)
    else: FAIL += 1; print("  [FAIL] " + msg)
if miss:
    # The tree that SHIPS the defect has no helper at all: that is a FAIL on
    # the contract, not a CANNOT-RUN.
    print("  [FAIL] helpers absent: " + ", ".join(miss)); print("PASS=0 FAIL=1"); raise SystemExit(1)
ns = {"Path": pathlib.Path, "os": os, "json": json}
for node in ast.parse(src).body:
    if isinstance(node, ast.FunctionDef) and node.name in ("_payload_counts", "_read_source_totals", "_source_count_label"):
        exec(compile(ast.Module([node], []), "<f>", "exec"), ns)
L = ns["_source_count_label"]
def row(**k):
    d = {"source": "x", "status": "ok", "item_count": None, "last_run_count": None, "payload_counts": {}}
    d.update(k); return d

# Mail: a delta is never presented as the total.
lbl, kind = L(row(source="email", item_count=353842))
chk((lbl, kind) == ("353,842 emails", "total"), "mail total reads as emails, total: %r" % (lbl,))
lbl, kind = L(row(source="email", item_count=0, last_run_count=28))
chk(kind == "last_check" and "last check" in lbl, "mail delta is labelled last check, not total: %r" % (lbl,))
# WhatsApp: chats are chats, messages are messages.
lbl, _ = L(row(source="whatsapp", item_count=46, payload_counts={"people_added": 46}, last_run_count=12345))
chk(lbl == "46 chats, 12,345 messages", "whatsapp chats + messages: %r" % (lbl,))
lbl, _ = L(row(source="whatsapp", item_count=46, payload_counts={"people_added": 46}))
chk(lbl == "46 chats", "whatsapp with no message total says chats only: %r" % (lbl,))
# iMessage: people= is not messages.
lbl, _ = L(row(source="imessage", item_count=167))
chk(lbl is None, "imessage people count is not printed as messages")
# Safari: visits and pages saved.
lbl, _ = L(row(source="browsing", item_count=8714, payload_counts={"sent": 8714, "skipped": 3, "collection_points": 4583}))
chk(lbl == "8,714 visits, 4,583 pages saved", "browsing visits/pages: %r" % (lbl,))
# Photos: events.
lbl, _ = L(row(source="photos", item_count=1323))
chk(lbl == "1,323 photo events", "photos say events: %r" % (lbl,))
# Notes: the wiki-recorded total wins over the install-time count.
lbl, _ = L(row(source="apple_notes", item_count=913), {"notes_apple_notes": 971})
chk(lbl == "971 notes", "notes read the shared total: %r" % (lbl,))
lbl, _ = L(row(source="apple_notes", item_count=913))
chk(lbl == "913 notes", "notes fall back to install count: %r" % (lbl,))
# A fabricated zero is never printed for a state that took no measurement.
chk(L(row(source="photos", status="cannot_run", item_count=0)) == (None, None), "cannot_run prints no count")
# Payload parsing + totals file.
chk(ns["_payload_counts"]("sent=5,skipped=2,collection_points=unknown") == {"sent": 5, "skipped": 2}, "payload parse keeps integers only")
with tempfile.TemporaryDirectory() as d:
    root = pathlib.Path(d); (root / "state").mkdir()
    chk(ns["_read_source_totals"](root) == {}, "absent totals file reads as empty, not zero")
    (root / "state" / "source_totals.json").write_text(json.dumps({"notes": 971, "bad": "x"}))
    chk(ns["_read_source_totals"](root) == {"notes": 971}, "totals file read, non-ints dropped")
print("PASS=%d FAIL=%d" % (PASS, FAIL))
raise SystemExit(1 if FAIL else 0)
PY
