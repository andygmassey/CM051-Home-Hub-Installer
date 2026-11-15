#!/usr/bin/env bash
# followup_keys_match_chat_threads: the probe can say PASS, FAIL and
# CANNOT-RUN, each for its own reason, and it is read-only.
#
# Hermetic: the "box" is this runner, the daemon is a loopback fake serving
# GET /api/status with a synthetic `followup` block, and the token is a
# synthetic file. No chat.db, no real identifiers.
#
# Arms:
#   1. the judge's own self-test lands every case on its own verdict
#   2. the probe's --self-test exits 1 with "negative control behaved"
#   3. a mutant judge (FAIL turned into PASS) makes the probe's self-test BROKEN
#   4. end to end through run_probe: PASS, FAIL, CANNOT-RUN (no FDA), CANNOT-RUN
#      (daemon predates the block), CANNOT-RUN (denominator 0)
#   5. it declares WALK_READ_ONLY and carries no writing shape
#
# EXIT 0 pass, 1 fail, 2 cannot-run. BASH 3.2.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROBE="${ROOT}/scripts/box_walk_probes/probes/followup_keys_match_chat_threads.sh"
LIB="${ROOT}/scripts/box_walk_probes/lib/followup_keys_probe.py"
[ -f "$PROBE" ] && [ -f "$LIB" ] || { echo "CANNOT-RUN: probe or lib missing" >&2; exit 2; }
command -v python3 >/dev/null || { echo "CANNOT-RUN: no python3" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
W="$(mktemp -d)"; GW_PID=""
cleanup() { [ -n "$GW_PID" ] && { kill "$GW_PID" 2>/dev/null; wait "$GW_PID" 2>/dev/null; }; rm -rf "$W"; }
trap cleanup EXIT

echo "--- 1. judge self-test ---"
python3 "$LIB" --self-test >"$W/lib.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "judge self-test: every case on its own verdict ($(grep -c '^  ok' "$W/lib.out") cases)" \
    || { cat "$W/lib.out"; bad "judge self-test rc=$rc"; }

echo "--- 2. probe self-test goes red ---"
out="$(bash "$PROBE" --self-test 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'negative control behaved' <<< "$out"; then
    ok "probe --self-test exits 1 with 'negative control behaved'"
else printf '%s\n' "$out"; bad "probe --self-test rc=$rc"; fi

echo "--- 3. a mutant judge breaks the self-test ---"
M="$W/mut"; mkdir -p "$M/probes" "$M/lib"
cp "$PROBE" "$M/probes/"; cp "${ROOT}/scripts/box_walk_probes/lib/probe.sh" "$M/lib/"
python3 -c "import sys; s=sys.stdin.read(); a='rows match any chat.db thread'; i=s.index(a); j=s.index('return lines, EX_FAIL', i); sys.stdout.write(s[:j]+'return lines, EX_PASS'+s[j+len('return lines, EX_FAIL'):])" < "$LIB" > "$M/lib/followup_keys_probe.py"
if cmp -s "$LIB" "$M/lib/followup_keys_probe.py"; then bad "mutant did not apply"; else
    out="$(bash "$M/probes/followup_keys_match_chat_threads.sh" --self-test 2>&1)"; rc=$?
    if [ "$rc" -ne 1 ] || ! grep -q 'negative control behaved' <<< "$out"; then
        ok "with the display-name FAIL turned into PASS, the self-test no longer claims a behaved control (rc=$rc)"
    else bad "the self-test still reports a behaved control against a mutant judge"; fi
fi

echo "--- 4. end to end through run_probe against a loopback fake daemon ---"
mkdir -p "$W/secrets"; echo synthetic-token > "$W/secrets/zeroclaw_admin_token"
cat > "$W/gw.py" <<'PY'
import http.server, json, sys
state = {"body": {}}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/api/status" or self.headers.get("Authorization") != "Bearer synthetic-token":
            self.send_response(401); self.end_headers(); return
        b = open(sys.argv[2]).read().encode()
        self.send_response(200); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$W/gw.py" "$W/port" "$W/body.json" & GW_PID=$!
i=0; while [ ! -s "$W/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
[ -s "$W/port" ] || { echo "CANNOT-RUN: fake daemon did not start" >&2; exit 2; }
PORT="$(cat "$W/port")"
fu() { printf '{"followup": {"available": true, "measured": true, "enabled": true, "chat_db_readable": %s, "keyed_rows": %s, "keys_matching_one_to_one": %s, "keys_matching_group": %s, "completed_by_followup": 0, "reopened": 0}}\n' "$1" "$2" "$3" "$4"; }
# Synthetic reminders_map.db: argv[2] is a JSON list of [source_session_id, status, thread_key].
cat > "$W/mkdb.py" <<'PY'
import json, os, sqlite3, sys
db, rows = sys.argv[1], json.loads(sys.argv[2])
os.makedirs(os.path.dirname(db), exist_ok=True)
conn = sqlite3.connect(db)
conn.execute("DROP TABLE IF EXISTS reminders_map")
conn.execute("CREATE TABLE reminders_map (user_id TEXT NOT NULL, source_session_id TEXT NOT NULL, "
             "todo_id TEXT NOT NULL, status TEXT NOT NULL, thread_key TEXT, "
             "PRIMARY KEY (user_id, source_session_id, todo_id))")
for i, (sid, status, key) in enumerate(rows):
    conn.execute("INSERT INTO reminders_map VALUES ('u', ?, ?, ?, ?)", (sid, "t%d" % i, status, key))
conn.commit(); conn.close()
PY
python3 "$W/mkdb.py" "$W/.ostler/reminders_map.db" '[]'
keyed_rows_json() { # the map rows a census of body $1 implies
    python3 -c "import json,sys; b=json.loads(sys.argv[1]); fu=b.get('followup') if isinstance(b,dict) else None; n=fu.get('keyed_rows',0) if isinstance(fu,dict) and isinstance(fu.get('keyed_rows'),int) else 0; print(json.dumps([['imessage-chat-synth-%d' % i,'pushed','k_arm_%d' % i] for i in range(n)]))" "$1"
}
arm() { # arm <label> <want rc> <want verdict word> <body> [keep: use the map as already built]
    printf '%s\n' "$4" > "$W/body.json"
    # The map holds the census's own keyed rows (real, non-walk sids), so the arm is a
    # consistent read; the census-vs-map check is tested separately in section 6.
    if [ "${5:-}" != keep ]; then
        python3 "$W/mkdb.py" "$W/.ostler/reminders_map.db" "$(keyed_rows_json "$4")" || return 1
    fi
    out="$(unset OSTLER_BOX_HOST; OSTLER_PROBE_GATEWAY="http://127.0.0.1:${PORT}" OSTLER_SECRETS_DIR="$W/secrets" HOME="$W" bash "$PROBE" 2>&1)"; rc=$?
    if [ "$rc" -eq "$2" ] && grep -q "^VERDICT: $3 " <<< "$out"; then ok "$1 -> $3"
    else printf '%s\n' "$out"; bad "$1: rc=$rc, wanted $2 / $3"; fi
}
arm "1 of 4 rows matches a 1:1 chat" 0 PASS "$(fu true 4 1 0)"
arm "4 rows, none match (display-name keys)" 1 FAIL "$(fu true 4 0 0)"
arm "daemon cannot read chat.db" 78 CANNOT-RUN "$(fu false 4 0 0)"
arm "denominator 0" 78 CANNOT-RUN "$(fu true 0 0 0)"
arm "daemon predates the followup block" 78 CANNOT-RUN '{"reminders_list": {}}'
# The denominator is printed on a PASS.
printf '%s\n' "$(fu true 4 1 0)" > "$W/body.json"
python3 "$W/mkdb.py" "$W/.ostler/reminders_map.db" "$(keyed_rows_json "$(fu true 4 1 0)")"
out="$(unset OSTLER_BOX_HOST; OSTLER_PROBE_GATEWAY="http://127.0.0.1:${PORT}" OSTLER_SECRETS_DIR="$W/secrets" HOME="$W" bash "$PROBE" 2>&1)"
grep -q 'EXAMINED 4 keyed row(s) after excluding 0 walk-synthetic' <<< "$out" && ok "a PASS prints its denominator" || bad "no denominator on PASS"

echo "--- 5. read-only ---"
[ "$(grep -c '^# WALK_READ_ONLY:' "$PROBE")" -eq 1 ] && ok "declares WALK_READ_ONLY" || bad "no WALK_READ_ONLY marker"
# The sqlite3 CLI on a database stays forbidden. The python module is allowed only
# as a read-only URI (asserted below), because the walk-residue read needs it.
SHAPES='launchctl[[:space:]]+(kickstart|bootstrap|bootout|load|unload)|-X[[:space:]]+(POST|PUT|PATCH|DELETE)|INSERT[[:space:]]+(DATA|INTO)|DELETE[[:space:]]+(WHERE|DATA|FROM)|sqlite3[[:space:]]+[^#]*(\.db|chat)|osascript|imsg|send'
n="$(cat "$PROBE" "$LIB" | grep -v -E '^[[:space:]]*#' | grep -c -E "$SHAPES")"
[ "$n" -eq 0 ] && ok "no writing or sending shape in the probe or its reader" || bad "$n writing/sending shape(s) found"
# Control: the shape check sees a writer, and a CLI read of a database.
printf 'sqlite3 x "INSERT INTO t VALUES (1)"\n' | grep -c -E "$SHAPES" >/dev/null && ok "control: the shape check flags a writer" || bad "shape check is blind"
printf 'sqlite3 ~/.ostler/reminders_map.db "SELECT 1"\n' | grep -c -E "$SHAPES" >/dev/null && ok "control: the shape check flags a sqlite CLI read of a db" || bad "shape check is blind to a sqlite CLI read"
conn_n="$(grep -c 'sqlite3\.connect(' "$LIB")"; ro_n="$(grep 'sqlite3\.connect(' "$LIB" | grep -c 'mode=ro')"
[ "$conn_n" -ge 1 ] && [ "$conn_n" -eq "$ro_n" ] && ok "every sqlite3.connect in the reader is mode=ro ($ro_n of $conn_n)" || bad "a sqlite3.connect is not mode=ro ($ro_n of $conn_n)"

echo "--- 6. walk-synthetic residue is excluded, and only that ---"
# The census is an aggregate, so keyed_rows counts the walk's own residue too.
# The box reads reminders_map.db read-only and subtracts ONLY rows whose
# source_session_id matches ostler-walk-todo-*. Rows are [sid, status, thread_key].
# cap <rows-json> <daemon keyed_rows>: build the map, run the real box() path,
# and leave its JSON in $W/cap.json.
cap() {
    python3 "$W/mkdb.py" "$W/.ostler/reminders_map.db" "$1" || return 1
    printf '%s\n' "$(fu true "$2" 0 0)" > "$W/body.json"
    OSTLER_PROBE_GATEWAY="http://127.0.0.1:${PORT}" OSTLER_SECRETS_DIR="$W/secrets" HOME="$W" \
        python3 "$LIB" box > "$W/cap.json" 2>/dev/null
}
judge_cap() { out="$(python3 "$LIB" judge "$W/cap.json")"; rc=$?; }
# Mutant of the capture: the same capture with the walk exclusion switched off.
nofilter() {
    python3 -c "import json,sys; c=json.load(open(sys.argv[1])); c['walk_synthetic_keyed']=0; json.dump(c,open(sys.argv[1],'w'))" "$W/cap.json"
}

# (a) a planted walk-synthetic row. Two real rows and the two rows one walk leaves behind.
A='[["email-thread-synth-1","pushed","k_email_1"],["imessage-chat-synth-1","pushed","k_im_1"],["ostler-walk-todo-4242-1700000000","pushed","k_walk_1"],["ostler-walk-todo-4242-1700000000-1to1","pushed","k_walk_2"]]'
cap "$A" 4 && judge_cap
if [ "$rc" -eq 78 ] && grep -q 'EXAMINED 2 keyed row(s) after excluding 2 walk-synthetic' <<< "$out"; then
    ok "(a) with the walk exclusion: 2 real rows examined, 2 walk rows excluded, below the floor -> CANNOT-RUN"
else printf '%s\n' "$out"; bad "(a) with the filter: rc=$rc"; fi
nofilter && judge_cap
if [ "$rc" -eq 1 ] && grep -q '^  FAIL  0 of 4 keyed rows' <<< "$out"; then
    ok "(a) without the walk exclusion, the same capture is FAIL on its own residue (4 rows, 0 match)"
else printf '%s\n' "$out"; bad "(a) mutant without the filter: rc=$rc, expected FAIL"; fi
arm "(a) end to end, the walk rows present" 78 CANNOT-RUN "$(fu true 4 0 0)" keep

# (b) a planted REAL non-iMessage row, email-keyed, plus one whose name only
# contains the walk prefix mid-string. Neither may be excluded: 3 real rows, 0 match.
B='[["email-thread-synth-1","pushed","k_email_1"],["email-ostler-walk-todo-look-alike","pushed","k_email_2"],["whatsapp-thread-synth-3","pushed","k_wa_3"],["ostler-walk-todo-4242-1700000001","pushed","k_walk_3"],["ostler-walk-todo-4242-1700000001-1to1","pushed","k_walk_4"]]'
cap "$B" 5 && judge_cap
if [ "$rc" -eq 1 ] && grep -q 'EXAMINED 3 keyed row(s) after excluding 2 walk-synthetic' <<< "$out" && grep -q '^  FAIL  0 of 3 keyed rows' <<< "$out"; then
    ok "(b) real non-iMessage rows are still graded: 3 examined, 2 excluded, FAIL"
else printf '%s\n' "$out"; bad "(b) rc=$rc: a real row was excluded or the FAIL was lost"; fi
arm "(b) end to end, a real email row still FAILs" 1 FAIL "$(fu true 5 0 0)" keep

# (c) only walk-synthetic rows present: zero denominator after exclusion.
C='[["ostler-walk-todo-4242-1700000002","pushed","k_walk_5"],["ostler-walk-todo-4242-1700000002-1to1","pushed","k_walk_6"]]'
cap "$C" 2 && judge_cap
if [ "$rc" -eq 78 ] && grep -q 'EXAMINED 0 keyed row(s) after excluding 2' <<< "$out"; then
    ok "(c) only walk-synthetic rows: 0 examined after exclusion -> CANNOT-RUN, not PASS"
else printf '%s\n' "$out"; bad "(c) rc=$rc"; fi
arm "(c) end to end, only walk rows" 78 CANNOT-RUN "$(fu true 2 0 0)" keep

# (d) a walk key shared with a real row: the exclusion cannot be by key, so no verdict.
D='[["email-thread-synth-1","pushed","k_shared"],["whatsapp-thread-synth-3","pushed","k_wa_3"],["imessage-chat-synth-1","pushed","k_im_1"],["ostler-walk-todo-4242-1700000003","pushed","k_shared"]]'
cap "$D" 4 && judge_cap
[ "$rc" -eq 78 ] && grep -q 'shared with a real row' <<< "$out" && ok "(d) a walk key shared with a real row -> CANNOT-RUN" || { printf '%s\n' "$out"; bad "(d) rc=$rc"; }

# (e) the census and the map disagree (a write landed between the two reads).
E='[["email-thread-synth-1","pushed","k_e1"],["imessage-chat-synth-1","pushed","k_i1"],["ostler-walk-todo-4242-1700000004","pushed","k_w1"]]'
cap "$E" 5 && judge_cap
[ "$rc" -eq 78 ] && grep -q 'disagree: a write landed' <<< "$out" && ok "(e) census 5 vs map 3 keyed -> CANNOT-RUN" || { printf '%s\n' "$out"; bad "(e) rc=$rc"; }

# (f) no reminders_map.db: the residue cannot be separated, so CANNOT-RUN.
rm -f "$W/.ostler/reminders_map.db"
arm "(f) no reminders_map.db on the box" 78 CANNOT-RUN "$(fu true 4 0 0)" keep
python3 "$W/mkdb.py" "$W/.ostler/reminders_map.db" '[]'

echo "--- 7. the exclusion is the walk prefix and nothing wider ---"
# Mutant: the filter excludes every row. Arm (b) must go red: it has real rows that must be graded.
MUT="$W/mutlib"; mkdir -p "$MUT"
sed "s/^WALK_GLOB = .*/WALK_GLOB = '*'/" "$LIB" > "$MUT/followup_keys_probe.py"
if cmp -s "$LIB" "$MUT/followup_keys_probe.py"; then bad "over-exclusion mutant did not apply"; else
    python3 "$W/mkdb.py" "$W/.ostler/reminders_map.db" "$B"
    OSTLER_PROBE_GATEWAY="http://127.0.0.1:${PORT}" OSTLER_SECRETS_DIR="$W/secrets" HOME="$W" \
        python3 "$MUT/followup_keys_probe.py" box > "$W/mut_cap.json" 2>/dev/null
    out="$(python3 "$MUT/followup_keys_probe.py" judge "$W/mut_cap.json")"; rc=$?
    if [ "$rc" -eq 78 ]; then ok "over-exclusion mutant: arm (b) goes red (the real rows vanish, CANNOT-RUN)"
    else printf '%s\n' "$out"; bad "over-exclusion mutant survived arm (b): rc=$rc"; fi
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
