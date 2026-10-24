#!/usr/bin/env bash
# ============================================================================
# test_contacts_and_reminders_are_reread.sh -- Contacts and Reminders must be
# RE-READ after install, and every outcome recorded honestly (G2 + G3, TCC
# background sweep 2026-10-15).
#
# THE DEFECTS, read from source on origin/main f0f2ac2f:
#
#   G3  Contacts were read once, at install. ostler-contact-resync ran only
#       when that read failed, and removed its own agent on first success. Yet
#       the Doctor mapped Contacts to fda-rerun (which never reads contacts)
#       and showed "Up to date" with the install time.
#   G2  Reminders were re-extracted every hour, but the only reader of
#       reminders.json was the install-time hydrate leg. Nothing re-embedded
#       them, and nothing recorded whether they were read.
#
# WHAT THIS RUNS: the two programs exactly as install.sh ships them, in a fake
# HOME, against synthetic fixtures (an AddressBook sqlite store holding only
# ids, a reminders.json holding only placeholder titles) and stand-ins for the
# syncer, the extractor and ostler-knowledge that log every call. launchctl is
# stubbed so nothing touches this machine's launchd.
#
# EXIT CODES   0 every arm passed   1 an arm failed   2 CANNOT-RUN
#
# --repo-root <dir>  run against another tree (used to show RED on main).
# ============================================================================
set -uo pipefail

# shellcheck source=lib/fda_run_all.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/fda_run_all.sh"
fda_run_all_contract_check "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || {
    rc=$?; echo "$(basename "$0"): the run_all call/signature moved (rc ${rc}); see tests/lib/fda_run_all.sh" >&2; exit 2; }


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

cannot_run() { echo "CANNOT-RUN: $*" >&2; exit 2; }
[[ -f "$INSTALL_SH" ]] || cannot_run "install.sh not found at ${INSTALL_SH}"
PY="$(command -v python3 || true)"
[[ -n "$PY" ]] || cannot_run "no python3 on PATH"
[[ "$(id -u)" != "0" ]] || cannot_run "running as root: file permissions cannot simulate a refused read"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/reread.XXXXXX")" || cannot_run "mktemp failed"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

awk 'index($0, "bin/ostler-contact-resync\" <<") {g=1; next} g && $0 == "CRSEOF" {exit} g' \
    "$INSTALL_SH" > "${WORK}/ostler-contact-resync"
awk 'index($0, "bin/ostler-fda\" <<") {g=1; next} g && $0 == "FDAEOF" {exit} g' \
    "$INSTALL_SH" > "${WORK}/ostler-fda"
[[ -s "${WORK}/ostler-contact-resync" ]] || cannot_run "could not extract ostler-contact-resync from install.sh"
[[ -s "${WORK}/ostler-fda" ]] || cannot_run "could not extract ostler-fda from install.sh"

mkdir -p "${WORK}/stubbin"
printf '#!/bin/sh\necho "launchctl $*" >> "%s/launchctl.log"\nexit 0\n' "$WORK" > "${WORK}/stubbin/launchctl"
chmod +x "${WORK}/stubbin/launchctl"

PASS=0
FAIL=0
ok()  { printf '  [pass] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
field() { sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -1; }
calls() { grep -c "$2" "$1" 2>/dev/null || true; }

# ── CONTACTS ────────────────────────────────────────────────────────────────
C="${WORK}/contacts"
AB="${C}/Library/Application Support/AddressBook/Sources/SRC-0001"
mkdir -p "$AB" "${C}/.ostler/import-pipeline/.venv/bin" "${C}/.ostler/import-pipeline/contact_syncer"
ln -s "$PY" "${C}/.ostler/import-pipeline/.venv/bin/python"
: > "${C}/.ostler/import-pipeline/contact_syncer/__init__.py"
cat > "${C}/.ostler/import-pipeline/contact_syncer/syncer.py" <<'PYEOF'
import json, os
with open(os.environ["CRS_CALLS"], "a") as fh:
    fh.write("sync\n")
print(json.dumps({"imported": int(os.environ.get("CRS_IMPORTED", "0")), "skipped": 0, "errors": [], "deleted": 0}))
PYEOF
"$PY" - "${AB}/AddressBook-v22.abcddb" <<'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE ZABCDRECORD (Z_PK INTEGER PRIMARY KEY, Z_OPT INTEGER, ZUNIQUEID TEXT)")
con.executemany("INSERT INTO ZABCDRECORD VALUES (?, 1, ?)", [(1, "uid-a"), (2, "uid-b")])
con.commit(); con.close()
PYEOF
CREC="${C}/.ostler/state/source_activity/contacts.tsv"
crs() {
    HOME="$C" PATH="${WORK}/stubbin:${PATH}" CRS_CALLS="${C}/calls.log" CRS_IMPORTED="$1" \
        bash "${WORK}/ostler-contact-resync" >/dev/null 2>&1
    echo $?
}

echo "== C1. a readable address book is synced and recorded fresh =="
rc="$(crs 2)"
[[ "$(field "$CREC" last_status)" == "ok" ]] && ok "contacts last_status=ok" \
    || bad "contacts last_status='$(field "$CREC" last_status)' after a good read"
FIRST_SUCCESS="$(field "$CREC" last_success_at)"
[[ -n "$FIRST_SUCCESS" ]] && ok "contacts last_success_at=${FIRST_SUCCESS}" || bad "no last_success_at after a good read"
[[ "$(calls "${C}/calls.log" sync)" == "1" ]] && ok "the syncer ran once" || bad "syncer calls=$(calls "${C}/calls.log" sync)"
[[ "$rc" == "0" ]] && ok "exit 0" || bad "exit ${rc} on a good read"
! grep -qE 'bootout|unload' "${WORK}/launchctl.log" 2>/dev/null \
    && ok "the reader did not remove its own agent" \
    || bad "the reader removed its own agent: $(cat "${WORK}/launchctl.log")"

echo "== C2. an unchanged address book is not re-synced, but is still a fresh read =="
sleep 1
rc="$(crs 2)"
[[ "$(calls "${C}/calls.log" sync)" == "1" ]] && ok "no second sync for an unchanged store" \
    || bad "syncer calls=$(calls "${C}/calls.log" sync), want 1"
[[ "$(field "$CREC" last_status)" == "ok" && "$(field "$CREC" last_success_at)" != "$FIRST_SUCCESS" ]] \
    && ok "recorded ok with a new last_success_at ($(field "$CREC" last_success_at))" \
    || bad "unchanged read recorded as '$(field "$CREC" last_status)' / '$(field "$CREC" last_success_at)'"

echo "== C3. a changed address book is re-synced =="
"$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("INSERT INTO ZABCDRECORD VALUES (3, 1, \"uid-c\")"); c.commit()' "${AB}/AddressBook-v22.abcddb"
rc="$(crs 3)"
[[ "$(calls "${C}/calls.log" sync)" == "2" ]] && ok "a new contact triggered a sync" \
    || bad "syncer calls=$(calls "${C}/calls.log" sync), want 2"
GOOD_SUCCESS="$(field "$CREC" last_success_at)"

echo "== C4. a refused read is cannot_run, keeps last_success_at, exits 75 =="
chmod 000 "${C}/Library/Application Support/AddressBook/Sources"
sleep 1
rc="$(crs 3)"
chmod 755 "${C}/Library/Application Support/AddressBook/Sources"
[[ "$(field "$CREC" last_status)" == "cannot_run" ]] && ok "contacts last_status=cannot_run" \
    || bad "contacts last_status='$(field "$CREC" last_status)' on a refused read"
[[ "$(field "$CREC" last_success_at)" == "$GOOD_SUCCESS" ]] && ok "last_success_at unchanged" \
    || bad "last_success_at moved from ${GOOD_SUCCESS} to $(field "$CREC" last_success_at) on a refused read"
[[ "$(calls "${C}/calls.log" sync)" == "2" ]] && ok "the syncer was not run" || bad "the syncer ran on a refused read"
[[ "$rc" == "75" ]] && ok "exit 75" || bad "exit ${rc} on a refused read, want 75"

echo "== C5. a store with rows that syncs 0 is an error, never a quiet success =="
"$PY" -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("INSERT INTO ZABCDRECORD VALUES (4, 1, \"uid-d\")"); c.commit()' "${AB}/AddressBook-v22.abcddb"
rc="$(crs 0)"
[[ "$(field "$CREC" last_status)" == "error" ]] && ok "contacts last_status=error" \
    || bad "contacts last_status='$(field "$CREC" last_status)' when the sync read 0 of 4"
[[ "$rc" == "1" ]] && ok "exit 1" || bad "exit ${rc}, want 1"

# ── REMINDERS ───────────────────────────────────────────────────────────────
R="${WORK}/reminders"
PKG="${R}/.ostler/fda-module/ostler_fda"
mkdir -p "$PKG" "${R}/.ostler/imports/fda" "${R}/bin"
: > "${PKG}/__init__.py"
{ printf 'import json, os, pathlib\n\n%s\n' "$FDA_RUN_ALL_STUB_DEF"; cat <<'PYEOF'
    out = pathlib.Path(str(output_dir))
    status = os.environ["REM_STATUS"]
    if status == "ok":
        n = int(os.environ["REM_COUNT"])
        (out / "reminders.json").write_text(json.dumps(
            [{"title": "Placeholder task %d" % i} for i in range(n)]))
    summary = {"sources": {"reminders": {"status": status}}}
    (out / "extraction_summary.json").write_text(json.dumps(summary))
    return summary
PYEOF
} > "${PKG}/extract_all.py"
cat > "${PKG}/pwg_ingest.py" <<'PYEOF'
_INGEST_DISPATCH = ()

def ingest_all(fda_dir=None):
    return {}
PYEOF
cat > "${R}/bin/ostler-knowledge" <<EOF
#!/bin/sh
echo "\$1" >> "${R}/knowledge.log"
[ "\$1" = embed ] && [ "\${REM_EMBED_FAIL:-0}" = 1 ] && exit 3
exit 0
EOF
chmod +x "${R}/bin/ostler-knowledge"
cp "${WORK}/ostler-fda" "${R}/.ostler/bin-ostler-fda"
RREC="${R}/.ostler/state/source_activity/reminders.tsv"
tick() {
    HOME="$R" PATH="${WORK}/stubbin:${PATH}" OSTLER_PYTHON= OSTLER_NOTES_REFRESH=0 OSTLER_APP_WARMUP=0 \
    OSTLER_FDA_SOURCES=reminders OSTLER_KNOWLEDGE_BIN="${R}/bin/ostler-knowledge" \
    REM_STATUS="$1" REM_COUNT="${2:-0}" REM_EMBED_FAIL="${3:-0}" \
        bash "${R}/.ostler/bin-ostler-fda" >>"${R}/out.log" 2>&1
    echo $?
}

echo "== R1. reminders read this tick are embedded and recorded fresh =="
rc="$(tick ok 2)"
[[ "$(field "$RREC" last_status)" == "ok" ]] && ok "reminders last_status=ok" \
    || bad "reminders last_status='$(field "$RREC" last_status)' after a good read"
R_SUCCESS="$(field "$RREC" last_success_at)"
[[ -n "$R_SUCCESS" ]] && ok "reminders last_success_at=${R_SUCCESS}" || bad "no last_success_at"
[[ "$(calls "${R}/knowledge.log" embed)" == "1" ]] && ok "convert + embed ran once" \
    || bad "embed calls=$(calls "${R}/knowledge.log" embed)"
[[ "$(field "${R}/.ostler/state/hydrate/reminders_knowledge.done" item_count)" == "2" ]] \
    && ok "reminders_knowledge sentinel says 2" || bad "reminders_knowledge sentinel not written"
[[ "$rc" == "0" ]] && ok "exit 0" || bad "exit ${rc} on a good read"

echo "== R2. unchanged reminders are not re-embedded =="
rc="$(tick ok 2)"
[[ "$(calls "${R}/knowledge.log" embed)" == "1" ]] && ok "no second embed" \
    || bad "embed calls=$(calls "${R}/knowledge.log" embed), want 1"
[[ "$(field "$RREC" last_status)" == "ok" ]] && ok "still recorded ok" || bad "recorded '$(field "$RREC" last_status)'"

echo "== R3. a refused Reminders read is cannot_run and keeps last_success_at =="
sleep 1
R_SUCCESS="$(field "$RREC" last_success_at)"
rc="$(tick no_fda)"
[[ "$(field "$RREC" last_status)" == "cannot_run" ]] && ok "reminders last_status=cannot_run" \
    || bad "reminders last_status='$(field "$RREC" last_status)' on a refused read"
[[ "$(field "$RREC" last_success_at)" == "$R_SUCCESS" ]] && ok "last_success_at unchanged" \
    || bad "last_success_at moved on a refused read"
[[ "$(calls "${R}/knowledge.log" embed)" == "1" ]] && ok "nothing embedded" || bad "embedded on a refused read"

echo "== R4. a failed embed is an error and the tick goes non-zero =="
rc="$(tick ok 3 1)"
[[ "$(field "$RREC" last_status)" == "error" ]] && ok "reminders last_status=error" \
    || bad "reminders last_status='$(field "$RREC" last_status)' after a failed embed"
[[ "$rc" != "0" ]] && ok "exit ${rc}" || bad "exit 0 after a failed embed"

# ── DOCTOR ──────────────────────────────────────────────────────────────────
echo "== D1. the Doctor reads Contacts and Reminders from their own readers =="
D="${WORK}/doctor"; mkdir -p "${D}/state/hydrate" "${D}/state/source_activity"
printf 'source=contacts\nstatus=cannot_run\nrecorded_at=2026-01-01T00:00:00Z\ndetail=fda_not_granted\n' > "${D}/state/hydrate/contacts.done"
printf 'source=reminders\nstatus=ok\nitem_count=2\nrecorded_at=2026-01-01T00:00:00Z\n' > "${D}/state/hydrate/reminders.done"
printf 'source=contacts\nlast_run_at=2026-10-15T01:00:00Z\nlast_status=ok\nlast_success_at=2026-10-15T01:00:00Z\nlast_detail=imported=3\nwriter=ostler-contact-resync\n' \
    > "${D}/state/source_activity/contacts.tsv"
[[ -f "$RREC" ]] && cp "$RREC" "${D}/state/source_activity/reminders.tsv"
doc="$(OSTLER_DIR="$D" AGENT_DIR="$AGENT_DIR" "$PY" - <<'PYEOF' 2>&1
import ast, json, os, pathlib, sys
src = pathlib.Path(os.environ["AGENT_DIR"], "web_ui.py").read_text(encoding="utf-8")
ns = {"Path": pathlib.Path, "os": os, "json": json}
for node in ast.parse(src).body:
    if isinstance(node, (ast.Assign, ast.AnnAssign, ast.FunctionDef)):
        try:
            exec(compile(ast.Module([node], []), "<n>", "exec"), ns)
        except Exception:
            pass
rows = {r["source"]: r for r in ns["read_source_status"]()}
sys.path.insert(0, os.environ["AGENT_DIR"])
import routine_status
labels = [r[0] for r in routine_status._ROUTINES]
print(json.dumps({"contacts": rows["contacts"].get("ongoing"),
                  "contacts_success": rows["contacts"].get("last_success_at"),
                  "reminders": rows.get("reminders", {}).get("ongoing"),
                  "contact_routine": "com.ostler.contact-resync" in labels}))
PYEOF
)"
dj() { "$PY" -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$doc" "$1" 2>/dev/null; }
[[ "$(dj contacts)" == "active" && "$(dj contacts_success)" == "2026-10-15T01:00:00Z" ]] \
    && ok "Contacts row is fed by the contact reader's record" || bad "Contacts row: ${doc:0:300}"
[[ "$(dj reminders)" == "failing" ]] && ok "Reminders row reflects its last tick (error after R4)" \
    || bad "Reminders row ongoing='$(dj reminders)'"
[[ "$(dj contact_routine)" == "True" ]] && ok "routine_status measures com.ostler.contact-resync" \
    || bad "routine_status does not list com.ostler.contact-resync"

echo
echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ "$PASS" -gt 0 ]] || cannot_run "no arm passed, so nothing was measured"
[[ "$FAIL" -eq 0 ]]
