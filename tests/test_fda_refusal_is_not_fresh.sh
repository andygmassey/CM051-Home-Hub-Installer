#!/usr/bin/env bash
# ============================================================================
# test_fda_refusal_is_not_fresh.sh -- a read macOS REFUSED must never be
# reported as a fresh success (G1, TCC background sweep 2026-10-15).
#
# THE DEFECT, read from source on origin/main f0f2ac2f:
#
#   ~/.ostler/bin/ostler-fda (written by install.sh) called run_all() and threw
#   its per-source result away. When macOS refused a read, extract_all recorded
#   status no_fda and LEFT THE OLD JSON ON DISK. ingest_all then re-loaded the
#   install-time file, called it ok, and the activity writer stamped
#   last_success_at = now. Exit 0. The Doctor row read "Up to date, just now"
#   for a source nothing had been able to read.
#
# WHAT THIS RUNS: the wrapper exactly as install.sh ships it, against stand-in
# ostler_fda modules that return a chosen extract summary and log which ingest
# keys were actually loaded. Then the Doctor's own read_source_status and
# check_scheduled_agents, driven with the records the wrapper wrote. Then a
# contract arm against the REAL vendored extract_all.py and pwg_ingest.py, so
# the stand-ins cannot drift from the names the shipping modules use.
#
# EXIT CODES   0 every arm passed   1 an arm failed   2 CANNOT-RUN
#
# --repo-root <dir>  run against another tree (used to show RED on main).
# ============================================================================
set -uo pipefail

REPO_ROOT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
INSTALL_SH="${REPO_ROOT}/install.sh"
AGENT_DIR="${REPO_ROOT}/vendor/doctor/agent"
FDA_VENDOR="${REPO_ROOT}/vendor/ostler_fda"

cannot_run() { echo "CANNOT-RUN: $*" >&2; exit 2; }

[[ -f "$INSTALL_SH" ]] || cannot_run "install.sh not found at ${INSTALL_SH}"
[[ -f "${AGENT_DIR}/web_ui.py" ]] || cannot_run "vendor/doctor/agent/web_ui.py not found"
[[ -f "${FDA_VENDOR}/extract_all.py" ]] || cannot_run "vendor/ostler_fda/extract_all.py not found"
PY="$(command -v python3 || true)"
[[ -n "$PY" ]] || cannot_run "no python3 on PATH"

WRAPPER_BODY="$(awk '
    index($0, "bin/ostler-fda\" <<") { grab = 1; next }
    grab && $0 == "FDAEOF"           { exit }
    grab                             { print }
' "$INSTALL_SH")"
[[ -n "$WRAPPER_BODY" ]] || cannot_run "could not extract the ostler-fda heredoc from install.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fdarefusal.XXXXXX")" || cannot_run "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
printf '%s\n' "$WRAPPER_BODY" > "${WORK}/ostler-fda"

PASS=0
FAIL=0
ok()  { printf '  [pass] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

OLD_SUCCESS="2026-01-01T00:00:00Z"

# build_root <root>: a fake ~/.ostler holding stand-in ostler_fda modules.
build_root() {
    local root="$1"
    local pkg="${root}/.ostler/fda-module/ostler_fda"
    mkdir -p "$pkg" "${root}/.ostler/bin" "${root}/.ostler/imports/fda" \
             "${root}/.ostler/state/source_activity"
    : > "${pkg}/__init__.py"
    cat > "${pkg}/extract_all.py" <<'PYEOF'
import json, os

def run_all(output_dir=None, enabled_sources=None):
    with open(os.environ["FDA_TEST_SUMMARY"]) as fh:
        return {"sources": json.load(fh)}
PYEOF
    cat > "${pkg}/pwg_ingest.py" <<'PYEOF'
import os, sys

# Same SHAPE as the real table: (results key, function name). The contract arm
# below checks the real module still has it.
_INGEST_DISPATCH = (
    ("imessage", "x"), ("social", "x"), ("calendar", "x"), ("photos", "x"),
    ("apple_mail", "x"), ("browser_history", "x"), ("bookmarks", "x"),
)

def ingest_all(fda_dir=None):
    out = {}
    this = sys.modules[__name__]
    for name, _fn in this._INGEST_DISPATCH:
        with open(os.environ["FDA_TEST_INGEST_LOG"], "a") as fh:
            fh.write(name + "\n")
        out[name] = {"status": "ok", "sent": 1}
    return out
PYEOF
    cp "${WORK}/ostler-fda" "${root}/.ostler/bin/ostler-fda"
}

# seed <root> <source>: a prior activity record that last succeeded long ago.
seed() {
    printf 'source=%s\nlast_run_at=%s\nlast_status=ok\nlast_success_at=%s\nlast_detail={}\nwriter=ostler-fda\n' \
        "$2" "$OLD_SUCCESS" "$OLD_SUCCESS" > "${1}/.ostler/state/source_activity/${2}.tsv"
}

# tick <root> <summary-json>: run the shipped wrapper once; echoes its rc.
tick() {
    local root="$1"
    printf '%s' "$2" > "${root}/summary.json"
    HOME="$root" OSTLER_PYTHON= OSTLER_NOTES_REFRESH=0 OSTLER_APP_WARMUP=0 \
    FDA_TEST_SUMMARY="${root}/summary.json" FDA_TEST_INGEST_LOG="${root}/ingested.log" \
        bash "${root}/.ostler/bin/ostler-fda" >>"${root}/out.log" 2>&1
    echo $?
}

field() { sed -n "s/^${2}=//p" "${1}" 2>/dev/null | head -1; }

echo "== 1. a refused Calendar read keeps last_success_at and says cannot_run =="
R="${WORK}/refused"; build_root "$R"; seed "$R" calendar
rc="$(tick "$R" '{"calendar":{"status":"no_fda"},"safari_history":{"status":"ok"},"chrome_history":{"status":"not_found"},"safari_bookmarks":{"status":"ok"},"imessage":{"status":"ok"},"photos":{"status":"ok"},"apple_mail":{"status":"ok"}}')"
F="${R}/.ostler/state/source_activity/calendar.tsv"
[[ "$(field "$F" last_status)" == "cannot_run" ]] \
    && ok "calendar last_status=cannot_run" \
    || bad "calendar last_status=$(field "$F" last_status), want cannot_run"
[[ "$(field "$F" last_success_at)" == "$OLD_SUCCESS" ]] \
    && ok "calendar last_success_at unchanged (${OLD_SUCCESS})" \
    || bad "calendar last_success_at moved to '$(field "$F" last_success_at)' on a refused read"
! grep -qx calendar "${R}/ingested.log" 2>/dev/null \
    && ok "the stale calendar JSON was NOT re-ingested" \
    || bad "calendar was re-ingested from the stale file"
grep -qx photos "${R}/ingested.log" 2>/dev/null \
    && ok "control: a readable source (photos) in the same tick was still ingested" \
    || bad "photos was not ingested; the harness or the skip is too broad"
[[ "$rc" != "0" ]] \
    && ok "the tick exits non-zero (rc=${rc})" \
    || bad "the tick exited 0 on a refused read"

echo "== 2. a good Calendar read still updates (the control) =="
G="${WORK}/good"; build_root "$G"; seed "$G" calendar
rc="$(tick "$G" '{"calendar":{"status":"ok"},"photos":{"status":"ok"}}')"
F="${G}/.ostler/state/source_activity/calendar.tsv"
[[ "$(field "$F" last_status)" == "ok" ]] && ok "calendar last_status=ok" \
    || bad "calendar last_status=$(field "$F" last_status) on a good read"
s="$(field "$F" last_success_at)"
[[ -n "$s" && "$s" != "$OLD_SUCCESS" ]] && ok "calendar last_success_at advanced to ${s}" \
    || bad "calendar last_success_at did not advance on a good read ('${s}')"
grep -qx calendar "${G}/ingested.log" 2>/dev/null && ok "calendar was ingested" \
    || bad "calendar was not ingested on a good read"
[[ "$rc" == "0" ]] && ok "the tick exits 0" || bad "the tick exited ${rc} on a good read"

echo "== 3. half a source is not fresh (Safari refused, Chrome readable) =="
M="${WORK}/mixed"; build_root "$M"; seed "$M" browser_history
rc="$(tick "$M" '{"safari_history":{"status":"no_fda"},"chrome_history":{"status":"ok"},"safari_bookmarks":{"status":"ok"}}')"
F="${M}/.ostler/state/source_activity/browser_history.tsv"
[[ "$(field "$F" last_status)" == "cannot_run" ]] && ok "browser_history last_status=cannot_run" \
    || bad "browser_history last_status=$(field "$F" last_status) with Safari refused"
[[ "$(field "$F" last_success_at)" == "$OLD_SUCCESS" ]] && ok "browser_history last_success_at unchanged" \
    || bad "browser_history last_success_at moved with Safari refused"
grep -qx browser_history "${M}/ingested.log" 2>/dev/null && ok "the readable Chrome half was still ingested" \
    || bad "browser_history was skipped although Chrome was readable"

echo "== 4. an extract-only source (Reminders) records the refusal, and a later good read clears it =="
E="${WORK}/extractonly"; build_root "$E"
rc="$(tick "$E" '{"reminders":{"status":"no_fda"},"calendar":{"status":"ok"}}')"
F="${E}/.ostler/state/source_activity/reminders.tsv"
[[ "$(field "$F" last_status)" == "cannot_run" ]] && ok "reminders last_status=cannot_run" \
    || bad "reminders refusal left no record (last_status='$(field "$F" last_status)')"
[[ -z "$(field "$F" last_success_at)" ]] && ok "reminders has no last_success_at" \
    || bad "reminders was given a success stamp on a refused read"
rc="$(tick "$E" '{"reminders":{"status":"ok"},"calendar":{"status":"ok"}}')"
[[ ! -f "$F" ]] && ok "a good read cleared the refusal without stamping it fresh" \
    || bad "reminders record still present after a good read: $(field "$F" last_status)"

echo "== 5. an extract ERROR is loud too, and is not called a permission problem =="
X="${WORK}/xerror"; build_root "$X"; seed "$X" calendar
rc="$(tick "$X" '{"calendar":{"status":"error","error":"boom"}}')"
F="${X}/.ostler/state/source_activity/calendar.tsv"
[[ "$(field "$F" last_status)" == "error" ]] && ok "calendar last_status=error" \
    || bad "calendar last_status=$(field "$F" last_status) on an extract error"
[[ "$(field "$F" last_success_at)" == "$OLD_SUCCESS" ]] && ok "calendar last_success_at unchanged" \
    || bad "calendar last_success_at moved on an extract error"
[[ "$rc" == "1" ]] && ok "the tick exits 1" || bad "the tick exited ${rc} on an extract error"

echo "== 5b. ONE source erroring does not make the others read failing =="
Y="${WORK}/oneerror"; build_root "$Y"; seed "$Y" calendar; seed "$Y" photos
rc="$(tick "$Y" '{"calendar":{"status":"error","error":"boom"},"photos":{"status":"ok"}}')"
FC="${Y}/.ostler/state/source_activity/calendar.tsv"; FP="${Y}/.ostler/state/source_activity/photos.tsv"
[[ "$(field "$FC" last_status)" == "error" ]] && ok "the erroring source (calendar) reads error" \
    || bad "calendar last_status=$(field "$FC" last_status), want error"
[[ "$(field "$FP" last_status)" == "ok" ]] && ok "the healthy source (photos) keeps its own status ok" \
    || bad "photos last_status=$(field "$FP" last_status) inherited the tick's failure"
s="$(field "$FP" last_success_at)"
[[ -n "$s" && "$s" != "$OLD_SUCCESS" ]] && ok "photos last_success_at advanced despite calendar erroring" \
    || bad "photos last_success_at did not advance ('${s}')"
D2="${WORK}/doctor2"; mkdir -p "${D2}/state/hydrate" "${D2}/state/source_activity"
for s in calendar photos; do
    printf 'source=%s\nstatus=ok\nitem_count=12\nrecorded_at=%s\n' "$s" "$OLD_SUCCESS" > "${D2}/state/hydrate/${s}.done"
    cp "${Y}/.ostler/state/source_activity/${s}.tsv" "${D2}/state/source_activity/${s}.tsv"
done
rows_out="$(OSTLER_DIR="$D2" AGENT_DIR="$AGENT_DIR" "$PY" - <<'PYEOF' 2>&1
import ast, json, os, pathlib
src = pathlib.Path(os.environ["AGENT_DIR"], "web_ui.py").read_text(encoding="utf-8")
tree = ast.parse(src)
ns = {"Path": pathlib.Path, "os": os, "json": json}
for kinds in ((ast.Assign, ast.AnnAssign), (ast.FunctionDef,)):
    for node in tree.body:
        if isinstance(node, kinds):
            try:
                exec(compile(ast.Module([node], []), "<n>", "exec"), ns)
            except Exception:
                pass
rows = {r["source"]: r for r in ns["read_source_status"]()}
print(json.dumps({k: {"ongoing": rows[k].get("ongoing")} for k in ("calendar", "photos") if k in rows}))
PYEOF
)"
rowf() { "$PY" -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]]["ongoing"])' "$rows_out" "$1" 2>/dev/null; }
[[ "$(rowf calendar)" == "failing" ]] && ok "Doctor: the erroring source reads failing" \
    || bad "Doctor: calendar ongoing=$(rowf calendar || echo "${rows_out:0:200}")"
[[ "$(rowf photos)" == "active" ]] && ok "Doctor: the healthy source does NOT read failing (rc=${rc} on the tick)" \
    || bad "Doctor: photos ongoing=$(rowf photos || echo "${rows_out:0:200}")"

echo "== 5c. only error and cannot_run read failing; skipped and no_data do not =="
D3="${WORK}/doctor3"; mkdir -p "${D3}/state/hydrate" "${D3}/state/source_activity"
for pair in "calendar:skipped" "photos:no_data" "apple_mail:skipped" "imessage:error" "whatsapp:cannot_run" "apple_notes:ok"; do
    s="${pair%%:*}"; st="${pair##*:}"
    printf 'source=%s\nstatus=ok\nitem_count=12\nrecorded_at=%s\n' "$s" "$OLD_SUCCESS" > "${D3}/state/hydrate/${s}.done"
    printf 'source=%s\nlast_run_at=2026-10-15T00:00:00Z\nlast_status=%s\nlast_success_at=%s\nlast_detail={}\nwriter=ostler-fda\n' \
        "$s" "$st" "$OLD_SUCCESS" > "${D3}/state/source_activity/${s}.tsv"
done
rows3="$(OSTLER_DIR="$D3" AGENT_DIR="$AGENT_DIR" "$PY" - <<'PYEOF' 2>&1
import ast, json, os, pathlib
src = pathlib.Path(os.environ["AGENT_DIR"], "web_ui.py").read_text(encoding="utf-8")
tree = ast.parse(src)
ns = {"Path": pathlib.Path, "os": os, "json": json}
for kinds in ((ast.Assign, ast.AnnAssign), (ast.FunctionDef,)):
    for node in tree.body:
        if isinstance(node, kinds):
            try:
                exec(compile(ast.Module([node], []), "<n>", "exec"), ns)
            except Exception:
                pass
rows = {r["source"]: r for r in ns["read_source_status"]()}
print(json.dumps({k: {"ongoing": rows[k].get("ongoing")} for k in rows}))
PYEOF
)"
r3() { "$PY" -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2],{}).get("ongoing"))' "$rows3" "$1" 2>/dev/null; }
[[ "$(r3 calendar)" == "active" ]] && ok "skipped does not read failing (calendar: $(r3 calendar))" || bad "skipped (calendar) reads $(r3 calendar)"
[[ "$(r3 email)" == "active" ]] && ok "skipped does not read failing (Mail/email: $(r3 email))" || bad "skipped (Mail) reads $(r3 email)"
[[ "$(r3 photos)" == "active" ]] && ok "no_data does not read failing (photos: $(r3 photos))" || bad "no_data (photos) reads $(r3 photos)"
[[ "$(r3 imessage)" == "failing" ]] && ok "control: error reads failing" || bad "control: error ongoing=$(r3 imessage || echo "${rows3:0:200}")"
[[ "$(r3 whatsapp)" == "failing" ]] && ok "control: cannot_run reads failing" || bad "control: cannot_run ongoing=$(r3 whatsapp)"
[[ "$(r3 apple_notes)" == "active" ]] && ok "control: ok reads active" || bad "control: ok ongoing=$(r3 apple_notes)"

echo "== 6. the Doctor reads a refusal as cannot_run, not Up to date =="
D="${WORK}/doctor"; mkdir -p "${D}/state/hydrate" "${D}/state/source_activity"
for s in calendar browsing; do
    printf 'source=%s\nstatus=ok\nitem_count=12\nrecorded_at=%s\n' "$s" "$OLD_SUCCESS" \
        > "${D}/state/hydrate/${s}.done"
done
cp "${R}/.ostler/state/source_activity/calendar.tsv" "${D}/state/source_activity/calendar.tsv"
cp "${M}/.ostler/state/source_activity/browser_history.tsv" "${D}/state/source_activity/browser_history.tsv"
printf 'source=bookmarks\nlast_run_at=2026-10-15T00:00:00Z\nlast_status=ok\nlast_success_at=2026-10-15T00:00:00Z\nlast_detail={}\nwriter=ostler-fda\n' \
    > "${D}/state/source_activity/bookmarks.tsv"
doc_out="$(OSTLER_DIR="$D" AGENT_DIR="$AGENT_DIR" "$PY" - <<'PYEOF' 2>&1
import ast, json, os, pathlib, sys
src = pathlib.Path(os.environ["AGENT_DIR"], "web_ui.py").read_text(encoding="utf-8")
tree = ast.parse(src)
ns = {"Path": pathlib.Path, "os": os, "json": json}
for node in tree.body:
    if isinstance(node, (ast.Assign, ast.AnnAssign)):
        try:
            exec(compile(ast.Module([node], []), "<c>", "exec"), ns)
        except Exception:
            pass
for node in tree.body:
    if isinstance(node, ast.FunctionDef):
        try:
            exec(compile(ast.Module([node], []), "<f>", "exec"), ns)
        except Exception:
            pass
rows = {r["source"]: r for r in ns["read_source_status"]()}
print(json.dumps({k: {f: rows[k].get(f) for f in ("status", "ongoing", "last_success_at", "detail")}
                  for k in ("calendar", "browsing")}))
PYEOF
)"
docj() { "$PY" -c 'import json,sys; d=json.loads(sys.argv[1]); print(d[sys.argv[2]][sys.argv[3]])' "$doc_out" "$1" "$2" 2>/dev/null; }
[[ "$(docj calendar status)" == "cannot_run" ]] && ok "calendar row status=cannot_run" \
    || bad "calendar row status=$(docj calendar status) (output: ${doc_out:0:300})"
docj calendar detail | grep -q "Full Disk Access" && ok "calendar row says Full Disk Access in plain words" \
    || bad "calendar row detail does not name the permission"
[[ "$(docj browsing status)" == "cannot_run" ]] && ok "browsing row (one half refused) status=cannot_run" \
    || bad "browsing row status=$(docj browsing status)"
[[ "$(docj browsing last_success_at)" == "$OLD_SUCCESS" ]] && ok "browsing last_success_at is its stalest half" \
    || bad "browsing last_success_at=$(docj browsing last_success_at), want ${OLD_SUCCESS}"
cp "${G}/.ostler/state/source_activity/calendar.tsv" "${D}/state/source_activity/calendar.tsv"
doc_out="$(OSTLER_DIR="$D" AGENT_DIR="$AGENT_DIR" "$PY" - <<'PYEOF' 2>&1
import ast, json, os, pathlib
src = pathlib.Path(os.environ["AGENT_DIR"], "web_ui.py").read_text(encoding="utf-8")
ns = {"Path": pathlib.Path, "os": os, "json": json}
for node in ast.parse(src).body:
    if isinstance(node, (ast.Assign, ast.AnnAssign, ast.FunctionDef)):
        try:
            exec(compile(ast.Module([node], []), "<n>", "exec"), ns)
        except Exception:
            pass
rows = {r["source"]: r for r in ns["read_source_status"]()}
print(json.dumps({"calendar": {"status": rows["calendar"]["status"]}}))
PYEOF
)"
[[ "$(docj calendar status)" == "ok" ]] && ok "control: a good read leaves the calendar row ok" \
    || bad "control: calendar row status=$(docj calendar status) after a good read"

echo "== 7. the Doctor card for a refused tick points at the permission, not a restart =="
card="$(AGENT_DIR="$AGENT_DIR" OSTLER_STATE_DIR="${WORK}/st" "$PY" - <<'PYEOF' 2>&1
import json, os, sys
sys.path.insert(0, os.environ["AGENT_DIR"])
# status_collector imports httpx at module scope and a CI runner has none. The
# card rules never call it, so a stand-in module is enough when it is absent.
try:
    import httpx  # noqa: F401
except ImportError:
    import types
    sys.modules["httpx"] = types.ModuleType("httpx")
import diagnostic_rules as d
real = d._scheduled_agent_observe
out = {}
for code in (75, 1):
    def fake(label, now=None, obs=None, code=code):
        o = {"state": "failing", "runs": 5, "last_exit": code} if label == "com.ostler.fda-rerun" \
            else {"state": "healthy", "runs": 1, "last_exit": 0}
        return real(label, now=now, obs=o)
    d._scheduled_agent_observe = fake
    f = [x for x in d.check_scheduled_agents(None) if x.get("agent_label") == "com.ostler.fda-rerun"]
    out[str(code)] = f[0]["agent_state"] + "|" + f[0]["fix"] if f else "none"
print(json.dumps(out))
PYEOF
)"
cardf() { "$PY" -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$card" "$1" 2>/dev/null; }
cardf 75 | grep -q '^needs_permission|.*Full Disk Access' && ok "exit 75 gives a needs-permission card" \
    || bad "exit 75 card: $(cardf 75 || echo "${card:0:300}")"
cardf 1 | grep -q '^failing|' && ok "control: exit 1 still gives the failing card" \
    || bad "exit 1 card: $(cardf 1 || echo "${card:0:300}")"

echo "== 8. contract: the wrapper's names exist in the REAL shipping modules =="
contract="$("$PY" - "$WORK/ostler-fda" "${FDA_VENDOR}" <<'PYEOF' 2>&1
import ast, re, sys, pathlib
wrapper = pathlib.Path(sys.argv[1]).read_text()
vendor = pathlib.Path(sys.argv[2])
m = re.search(r"^_FEEDS = (\{.*?^\})", wrapper, re.S | re.M)
e = re.search(r"^_EXTRACT_ONLY = (\(.*?\))", wrapper, re.M)
if not m or not e:
    print("MISSING: the wrapper has no _FEEDS / _EXTRACT_ONLY table")
    sys.exit(0)
feeds = ast.literal_eval(m.group(1)); extract_only = ast.literal_eval(e.group(1))
dispatch = None
for node in ast.parse((vendor / "pwg_ingest.py").read_text()).body:
    if isinstance(node, ast.Assign) and any(getattr(t, "id", "") == "_INGEST_DISPATCH" for t in node.targets):
        dispatch = [el.elts[0].value for el in node.value.elts]
extract_src = (vendor / "extract_all.py").read_text()
written = set(re.findall(r'summary\["sources"\]\["([a-z_]+)"\]', extract_src))
problems = []
if dispatch is None:
    problems.append("real pwg_ingest has no _INGEST_DISPATCH")
else:
    problems += ["ingest key %s not in the real _INGEST_DISPATCH" % k for k in feeds if k not in dispatch]
keys = {k for v in feeds.values() for k in v} | set(extract_only)
problems += ["extract key %s never written by the real extract_all" % k for k in sorted(keys) if k not in written]
print("; ".join(problems) if problems else "OK %d ingest keys, %d extract keys" % (len(feeds), len(keys)))
PYEOF
)"
[[ "$contract" == OK* ]] && ok "contract: ${contract}" || bad "contract: ${contract}"

echo
echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ "$PASS" -gt 0 ]] || cannot_run "no arm passed, so nothing was measured"
[[ "$FAIL" -eq 0 ]]
