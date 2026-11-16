"""NEW-119: a source that READ messages is not "no_data", for iMessage and Email.

MEASURED, ORM diag118 rerun A, Mini 16, macOS 27.2, 2026-10-29:
  imessage.done  status=no_data  detail=ran_ok_no_new_or_enriched_people
                 while the extract read 54 conversations / 84,826 messages
  email.done     status=no_data  with 99,394 Apple Mail messages extracted
install.sh said why, in its own comment at the iMessage recorder: status came
from people_created + people_enriched only, the message counts never reached
the sentinel, and the repair "belongs in the vendored ingest".

WHAT THIS RUNS, end to end, all synthetic:
  1. the REAL vendored ``ostler_fda.pwg_ingest.ingest_imessage`` against a
     pyoxigraph-backed fake Oxigraph, twice over the same conversations, so
     the second run reads messages and meets nobody new (the walk-box shape);
  2. its JSON through the REAL install.sh iMessage block (parse + recorder);
  3. the REAL vendored cm021 ``cmd_mbox`` (dry run) over a synthetic mbox of
     automated senders only (messages read, nobody new), through the REAL
     install.sh email count chain and recorder;
  4. the REAL Doctor reader (``read_source_status``) over the sentinels.
Controls: zero conversations / zero messages must still record no_data.
Mutants: the vendored counts removed, and the install.sh email limb removed,
must each turn the verdict back to no_data.

THREE STATES: 0 pass, 1 fail, 2 cannot-run.
"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import types
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INSTALL_SH = REPO / "install.sh"
WORK = Path(tempfile.mkdtemp(prefix="new119-"))
os.environ["OSTLER_HOME"] = str(WORK / "home")
os.environ["OSTLER_DIR"] = str(WORK / "home")
os.environ["OSTLER_MAIL_DIR"] = str(WORK / "nomail")
os.environ["OSTLER_FORGET_TOMBSTONE_FILE"] = str(WORK / "forgotten.json")
os.environ["OSTLER_IDENTIFIER_QUALITY_STATE"] = str(WORK / "iq.json")
os.environ["OSTLER_PERSON_DELETION_LOG"] = str(WORK / "deletions.jsonl")


def cannot(msg):
    print("CANNOT-RUN: " + msg, file=sys.stderr)
    shutil.rmtree(WORK, ignore_errors=True)
    sys.exit(2)


try:
    import pyoxigraph  # noqa: F401
    import httpx  # noqa: F401
    import phonenumbers  # noqa: F401
except ImportError as exc:
    cannot("missing test dependency: %s" % exc)

sys.path.insert(0, str(REPO / "tests"))
from _fake_oxigraph import FakeOxigraph  # noqa: E402

PASS = FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print("  [PASS] " + m)


def bad(m):
    global FAIL
    FAIL += 1
    print("  [FAIL] " + m)


SRC = INSTALL_SH.read_text(encoding="utf-8").split("\n")


def fn(name):
    start = next((i for i, l in enumerate(SRC) if re.match(r"^%s\(\)\s*\{" % re.escape(name), l)), None)
    if start is None:
        cannot("function %s not found in install.sh" % name)
    end = next(i for i in range(start, len(SRC)) if SRC[i] == "}")
    return "\n".join(SRC[start:end + 1])


def segment(first, last_exclusive=None, through=None):
    s = [i for i, l in enumerate(SRC) if l == first]
    if len(s) != 1:
        cannot("landmark %r found %d times" % (first, len(s)))
    s = s[0]
    if last_exclusive is not None:
        e = next((i for i in range(s, len(SRC)) if SRC[i] == last_exclusive), None)
    else:
        e = next((i + 1 for i in range(s + 1, len(SRC)) if SRC[i] == through), None)
    if e is None:
        cannot("end landmark for %r not found" % first)
    return "\n".join(SRC[s:e])


RECORDERS = "\n".join(fn(n) for n in (
    "_hydrate_payload_is_all_zero", "_hydrate_payload_count", "_hydrate_compute_change",
    "_hydrate_sentinel_record", "_hydrate_sentinel_record_no_data",
    "_hydrate_sentinel_record_error"))
IMSG_SEG = segment('    if [[ "$_HYDRATE_IMESSAGE_TIMED_OUT" == "true" ]]; then',
                   last_exclusive="    unset _HYDRATE_IMESSAGE_TIMED_OUT _HYDRATE_IMESSAGE_JSON_OUT")
EMAIL_COUNT_SEG = segment('        _HYDRATE_EMAIL_COUNTS="$(',
                          last_exclusive='        rm -f "$_HYDRATE_EMAIL_MBOX"')
EMAIL_REC_SEG = segment('    if [[ "${_HYDRATE_EMAIL_RC:-0}" -ne 0 ]]; then', through="    fi")
print("     EXAMINED: install.sh recorder fns + iMessage block (%d lines) + email chain (%d) + email recorder (%d)"
      % (IMSG_SEG.count("\n") + 1, EMAIL_COUNT_SEG.count("\n") + 1, EMAIL_REC_SEG.count("\n") + 1))

PRELUDE = r'''set -uo pipefail
ok() { :; }; info() { :; }; warn() { :; }
settling_report() { :; }; settling_report_measured() { :; }; gui_step_record_rc() { :; }
MSG_HYDRATE_IMESSAGE_DONE="%s"; MSG_HYDRATE_IMESSAGE_SKIPPED_NO_DATA=x
MSG_HYDRATE_IMESSAGE_BACKGROUND_CONTINUES=x
MSG_HYDRATE_EMAIL_DONE="%s"; MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT=x
_HY_ITEM_COUNT=0; _HY_LAST_UPDATE_AT=""
'''


def sentinel_fields(path):
    out = {}
    if path.is_file():
        for line in path.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                out[k] = v
    return out


def drive(sentinel_dir, body, env):
    sentinel_dir.mkdir(parents=True, exist_ok=True)
    script = PRELUDE + "_HYDRATE_SENTINEL_DIR=%s\n" % sentinel_dir + RECORDERS + "\n" + body + "\n"
    e = dict(os.environ, **env)
    r = subprocess.run(["bash", "-c", script], env=e, capture_output=True, text=True)
    if r.returncode != 0:
        print("     bash rc=%d stderr: %s" % (r.returncode, r.stderr.strip()[-300:]))
    return r.returncode


def record_imessage(sentinel_dir, json_out, seg=IMSG_SEG):
    body = 'rc=0\n_HYDRATE_IMESSAGE_TIMED_OUT=false\n_HYDRATE_IMESSAGE_JSON_OUT="$JSON_OUT"\n' + seg
    drive(sentinel_dir, body, {"JSON_OUT": json_out})
    return sentinel_fields(sentinel_dir / "imessage.done")


def record_email(sentinel_dir, json_out, rec_seg=EMAIL_REC_SEG):
    body = ('_HYDRATE_EMAIL_RC=0\n_HYDRATE_EMAIL_OUTCOME=""\n_HYDRATE_EMAIL_MBOX=/nonexistent\n'
            '_HYDRATE_EMAIL_JSON="$JSON_OUT"\n' + EMAIL_COUNT_SEG + "\n" + rec_seg)
    drive(sentinel_dir, body, {"JSON_OUT": json_out})
    return sentinel_fields(sentinel_dir / "email.done")


# ── 1. the REAL vendored iMessage ingest, against a fake Oxigraph ─────────────
def imessage_run(vendor_root, conversations):
    """Run ingest_imessage twice over the same conversations in a FRESH
    interpreter (so a mutant copy is really what is imported). Returns the
    second run's dict."""
    fda = WORK / ("fda-" + str(abs(hash((str(vendor_root), len(conversations))))))
    fda.mkdir(parents=True, exist_ok=True)
    (fda / "imessage_conversations.json").write_text(json.dumps(conversations))
    code = r'''
import json, sys
sys.path.insert(0, sys.argv[1]); sys.path.insert(0, sys.argv[2])
from _fake_oxigraph import FakeOxigraph
from pathlib import Path
store = FakeOxigraph()
from ostler_fda import pwg_ingest
pwg_ingest.OXIGRAPH_URL = store.url
fda = Path(sys.argv[3])
first = pwg_ingest.ingest_imessage(fda)
second = pwg_ingest.ingest_imessage(fda)
store.close()
print(json.dumps({"first": first, "second": second}))
'''
    r = subprocess.run([sys.executable, "-c", code, str(vendor_root), str(REPO / "tests"), str(fda)],
                       capture_output=True, text=True, env=dict(os.environ))
    if r.returncode != 0:
        cannot("ingest_imessage did not run: %s" % r.stderr.strip()[-400:])
    return json.loads(r.stdout.strip().splitlines()[-1])


# Reserved UK drama numbers (Ofcom 07700 900xxx), cast names only.
CONVS = [
    {"participants": ["+447700900461"], "display_name": "Jane Doe",
     "message_count": 40, "last_message": "2026-10-01T10:00:00Z"},
    {"participants": ["+447700900462", "+447700900463"], "display_name": "Book club",
     "message_count": 25, "last_message": "2026-10-02T10:00:00Z"},
]

print("1. iMessage: messages read, nobody new")
res = imessage_run(REPO / "vendor", CONVS)
second = res["second"]
landed = second.get("people_created", 0) + second.get("people_enriched", 0)
if res["first"].get("people_created", 0) > 0 and landed == 0:
    ok("premise: run 1 created people, run 2 created/enriched none (the walk-box shape)")
else:
    cannot("premise failed, run1=%r run2=%r" % (res["first"], second))
if second.get("messages_read") == 65 and second.get("conversations_read") == 2:
    ok("vendored ingest reports what it read: conversations_read=2 messages_read=65")
else:
    bad("vendored ingest does not report its read volume: %r" % second)
if "people_created" in second and "people_enriched" in second:
    ok("people_created / people_enriched are still fields")
else:
    bad("people fields dropped: %r" % second)

s = record_imessage(WORK / "s_imsg", json.dumps(second))
if s.get("status") == "ok" and "messages=65" in s.get("payload", "") and "conversations=2" in s.get("payload", ""):
    ok("imessage.done: status=ok with the counts (payload=%s)" % s.get("payload"))
else:
    bad("imessage.done: status=%s detail=%s payload=%s -- a run that read 65 messages reads as no data"
        % (s.get("status"), s.get("detail"), s.get("payload")))

print("2. iMessage CONTROL: zero conversations read")
empty = imessage_run(REPO / "vendor", [])["second"]
s0 = record_imessage(WORK / "s_imsg0", json.dumps(empty))
if s0.get("status") == "no_data":
    ok("zero read -> status=no_data (detail=%s)" % s0.get("detail"))
else:
    bad("zero read recorded status=%s; no_data must survive for a run that read nothing" % s0.get("status"))

print("3. iMessage MUTANT: vendored read counts removed")
mut_root = WORK / "mut_vendor"
shutil.copytree(REPO / "vendor" / "ostler_fda", mut_root / "ostler_fda",
                ignore=shutil.ignore_patterns("__pycache__"))
pi = mut_root / "ostler_fda" / "pwg_ingest.py"
txt = pi.read_text(encoding="utf-8")
mtxt = re.sub(r'\n\s*"(conversations_read|messages_read)": (conversations_read|messages_read),', "", txt)
if mtxt == txt:
    if s.get("status") == "ok":
        bad("MUTANT: no read-count fields to remove, yet the subject passed -- something else sets status")
    else:
        print("  [ -- ] MUTANT: skipped, the fields are absent -- which IS the failure above")
else:
    pi.write_text(mtxt, encoding="utf-8")
    msec = imessage_run(mut_root, CONVS)["second"]
    sm = record_imessage(WORK / "s_imsg_mut", json.dumps(msec))
    if sm.get("status") == "no_data":
        ok("MUTANT caught: without the vendored counts imessage.done is no_data again")
    else:
        bad("MUTANT survived: status=%s with the counts removed; the verdict above is void" % sm.get("status"))

# ── 2. Email: the REAL vendored cm021 CLI, dry run ────────────────────────────
print("4. Email: messages read, nobody new (automated senders only)")
sys.path.insert(0, str(REPO / "vendor" / "cm021"))
try:
    from src import cli  # noqa: E402
except Exception as exc:  # noqa: BLE001
    cannot("could not import vendor/cm021/src/cli.py: %s" % exc)


def mbox_json(text):
    p = WORK / ("m%d.mbox" % len(text))
    p.write_text(text)
    a = argparse.Namespace(path=str(p), backfill_days=None, graph_endpoint="http://127.0.0.1:9",
                           json=True, dry_run=True)
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        cli.cmd_mbox(a)
    return out.getvalue().strip().splitlines()[-1]


MBOX = (
    "From a@x 2026-10-01\n"
    "From: shopdeals <hello@shop.example>\nTo: me@example.net\n"
    "List-Unsubscribe: <mailto:u@shop.example>\n"
    "Subject: sale\nDate: Thu, 1 Oct 2026 11:00:00 +0000\nMessage-ID: <1@x>\n\nbuy\n\n"
    "From b@x 2026-10-01\n"
    "From: cardissuer <no_reply@card.example>\nTo: me@example.net\n"
    "Subject: statement\nDate: Thu, 1 Oct 2026 12:00:00 +0000\nMessage-ID: <2@x>\n\nstatement\n\n"
    "From c@x 2026-10-01\n"
    "From: alerts <noreply@alerts.example>\nTo: me@example.net\n"
    "Subject: alert\nDate: Thu, 1 Oct 2026 13:00:00 +0000\nMessage-ID: <3@x>\n\nalert\n\n"
)
ej = mbox_json(MBOX)
ed = json.loads(ej)
if ed.get("messages_read") == 3 and ed.get("people_extracted") == 0:
    ok("premise: cm021 read 3 messages and extracted 0 people")
else:
    cannot("email premise failed: %r" % ed)
se = record_email(WORK / "s_mail", ej)
if se.get("status") == "ok" and "messages=3" in se.get("payload", ""):
    ok("email.done: status=ok with the counts (payload=%s)" % se.get("payload"))
else:
    bad("email.done: status=%s detail=%s payload=%s -- mail that was read reads as no data"
        % (se.get("status"), se.get("detail"), se.get("payload")))

print("5. Email CONTROL: zero messages read")
se0 = record_email(WORK / "s_mail0", json.dumps({"messages_read": 0, "people_extracted": 0}))
if se0.get("status") == "no_data":
    ok("zero read -> status=no_data (detail=%s)" % se0.get("detail"))
else:
    bad("zero read recorded status=%s; no_data must survive" % se0.get("status"))
se1 = record_email(WORK / "s_mail1", json.dumps({"messages_read": 300, "people_extracted": 12}))
if se1.get("status") == "ok" and "people=12" in se1.get("payload", ""):
    ok("CONTROL imported: people=12 still records status=ok")
else:
    bad("CONTROL imported broke: %r" % se1)

print("6. Email MUTANT: the messages-read limb removed")
mseg = re.sub(r' \\\n\s*\|\| \[\[ "\$\{_HYDRATE_EMAIL_MSGS:-0\}" =~ .*?; then', "; then", EMAIL_REC_SEG, flags=re.S)
if mseg == EMAIL_REC_SEG:
    if se.get("status") == "ok":
        bad("MUTANT: no messages-read limb found, yet the subject passed")
    else:
        print("  [ -- ] MUTANT: skipped, the limb is absent -- which IS the failure above")
else:
    sem = record_email(WORK / "s_mail_mut", ej, rec_seg=mseg)
    if sem.get("status") == "no_data":
        ok("MUTANT caught: without the limb email.done is no_data again")
    else:
        bad("MUTANT survived: status=%s; the verdict above is void" % sem.get("status"))

# ── 3. the Doctor reads it ────────────────────────────────────────────────────
print("7. Doctor /api/v1/sources reader")
hyd = WORK / "doctor_hydrate"
hyd.mkdir()
shutil.copy(WORK / "s_imsg" / "imessage.done", hyd / "imessage.done")
shutil.copy(WORK / "s_mail" / "email.done", hyd / "email.done")
webui = (REPO / "vendor" / "doctor" / "agent" / "web_ui.py").read_text(encoding="utf-8")
try:
    reader = webui[webui.index("_SOURCE_KINDS = {"):webui.index('@app.get("/api/v1/sources"')]
except ValueError:
    cannot("could not locate the sources reader in web_ui.py")
fake = types.ModuleType("routine_status")
fake.read_routine_status = lambda: []
sys.modules["routine_status"] = fake
ns = {}
try:
    exec("from pathlib import Path\nimport os, json\n" + reader, ns)
    rows = {r["source"]: r for r in ns["read_source_status"](hydrate_dir=hyd,
                                                              activity_dir=WORK / "act",
                                                              catchup_dir=WORK / "cu")}
except Exception as exc:  # noqa: BLE001
    cannot("the shipped reader did not run: %s: %s" % (type(exc).__name__, exc))
for name, want in (("imessage", "messages=65"), ("email", "messages=3")):
    r = rows.get(name, {})
    if r.get("status") == "ok" and want in str(r.get("detail")):
        ok("Doctor row %s: status=ok detail=%s" % (name, r.get("detail")))
    else:
        bad("Doctor row %s: status=%s detail=%s" % (name, r.get("status"), r.get("detail")))

shutil.rmtree(WORK, ignore_errors=True)
print("\n== %d pass / %d fail / %d total ==" % (PASS, FAIL, PASS + FAIL))
sys.exit(1 if FAIL else 0)
