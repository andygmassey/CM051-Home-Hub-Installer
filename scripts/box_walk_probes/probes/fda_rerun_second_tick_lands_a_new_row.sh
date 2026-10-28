#!/usr/bin/env bash
# fda_rerun_second_tick_lands_a_new_row -- does the hourly FDA re-run refresh
# AFTER install? (NEW-119, diag118 Mini16 on macOS 27.2, 2026-10-29)
#
# A second refresh after install was NOT INSTRUMENTED: on diag118 rerun_A
# com.ostler.fda-rerun was never loaded after an abort and re-run (plist on
# disk, `launchctl print` rc=113), so no hourly tick existed and nothing said
# so. This probe makes the tick happen and checks that it carries new data:
#
#   1. seed ONE synthetic visit into the walk's own synthetic Safari
#      History.db (only when ~/.walk-safari-seed-run says planted(...) AND the
#      file carries walk_synthetic_marker; a real history is never touched)
#   2. kickstart com.ostler.fda-rerun until launchctl print says runs >= 2 and
#      at least one run completed after the seed (kickstart from launchd keeps
#      the real attribution chain: launchd -> ostler-assistant run-source)
#   3. ask Qdrant safari_history for that URL
#
#   PASS        runs >= 2, a run after the seed, last exit 0, and the row landed
#   FAIL        not loaded, < 2 runs, no run after the seed, a non-zero exit,
#               or the row never landed (ADVISORY while scoped advisory)
#   CANNOT-RUN  read-only walk, no synthetic Safari plant, the seed write was
#               refused (TCC), launchd or the store could not be read
#
# ADVISORY now; BLOCKING once the fda-rerun registration fix merges
# (scripts/walk_promote_scope.tsv says the same; Archie flips it).
#
# WALK_WRITES: inserts one synthetic example.com visit into the walk's synthetic Safari History.db (removed afterwards; the store point stays), and kickstarts com.ostler.fda-rerun until it has run twice
set -u
. "$(dirname "$0")/../lib/probe.sh"

PROBE_NAME="fda_rerun_second_tick_lands_a_new_row"
PROBE_QUESTION="kickstarted until it has run twice, does com.ostler.fda-rerun land a synthetic Safari visit seeded AFTER install in the store?"

_HERE="$(cd "$(dirname "$0")/.." && pwd)"
JUDGE="${_HERE}/lib/fda_refresh_tcc.py"
LABEL="com.ostler.fda-rerun"
LAUNCHCTL="${OSTLER_PROBE_LAUNCHCTL:-/bin/launchctl}"
SQLITE="${OSTLER_PROBE_SQLITE:-/usr/bin/sqlite3}"
CURL="${OSTLER_PROBE_CURL:-curl}"
QDRANT_URL="${OSTLER_QDRANT_URL:-http://127.0.0.1:6333}"
STORE_CURL_CONF="${OSTLER_PROBE_STORE_CURL_CONF:-\$HOME/.ostler/secrets/store-curl.conf}"
WAIT_S="${OSTLER_PROBE_FDA_TICK_WAIT_S:-2400}"
POLL_S="${OSTLER_PROBE_FDA_TICK_POLL_S:-15}"
MAX_KICKS="${OSTLER_PROBE_FDA_TICK_MAX_KICKS:-4}"
MAC_EPOCH=978307200

self_test() {
    if python3 "$JUDGE" --self-test >/dev/null; then
        probe_examined 20 "TCC and second-tick judge fixtures"
        probe_fail "negative control behaved: not loaded, one run, no run after the seed, a non-zero exit and a row that never landed are each FAIL; no seed, unreadable launchd and an unreadable store are CANNOT-RUN"
    fi
    probe_examined 20 "TCC and second-tick judge fixtures"
    probe_pass "SELF-TEST BROKEN: the judge let a known-bad fixture through (run lib/fda_refresh_tcc.py --self-test)"
}

# launchctl print for the label. Prints "NOTLOADED", "UNREADABLE ..." or the
# raw print text.
_print_job() {
    box_run "U=\$(id -u); o=\$(\"${LAUNCHCTL}\" print gui/\$U/${LABEL} 2>&1); rc=\$?
if [ \$rc -eq 113 ] || printf '%s' \"\$o\" | /usr/bin/grep -q 'Could not find service'; then echo NOTLOADED
elif [ \$rc -ne 0 ] || [ -z \"\$o\" ]; then echo \"UNREADABLE rc=\$rc\"
else printf '%s\n' \"\$o\"; fi"
}

_field() {  # $1 print text, $2 runs|last_exit|state
    local f; f="$(mktemp)"; printf '%s\n' "$1" > "$f"
    python3 "$JUDGE" print "$f" | python3 -c 'import json,sys; v=json.load(sys.stdin)[sys.argv[1]]; print("" if v is None else v)' "$2"
    rm -f "$f"
}

_store_count() {  # $1 url -> integer, or empty when the store could not be read
    local khdr="" body out code
    [ -n "${STORE_CONF_PATH:-}" ] && khdr="-K '${STORE_CONF_PATH}'"
    body="{\"exact\":true,\"filter\":{\"must\":[{\"key\":\"url\",\"match\":{\"value\":\"$1\"}}]}}"
    out="$(box_run "\"${CURL}\" -sS --noproxy '*' -m 15 ${khdr} -H 'Content-Type: application/json' -X POST '${QDRANT_URL}/collections/safari_history/points/count' -d '${body}' -w '\n%{http_code}'")"
    code="$(printf '%s\n' "$out" | tail -n1)"
    case "$code" in 404) printf '0'; return ;; 200) ;; *) return ;; esac
    printf '%s' "$out" | sed '$d' | python3 -c 'import json,sys
try:
    d=json.loads(sys.stdin.read()); print(int(d["result"]["count"]))
except Exception:
    pass'
}

run_probe() {
    box_reachable || probe_cannot_run "cannot reach the box; nothing about the second refresh was measured"
    if [ "${OSTLER_WALK_READ_ONLY:-0}" = "1" ]; then
        probe_cannot_run "read-only walk: this probe seeds a row and kickstarts fda-rerun, so it did not run"
    fi

    local marker db nonce url now mac seed_out pr runs0 loaded runs last state kicks waited after facts out rc reason landed
    marker="$(box_run 'f="$HOME/.walk-safari-seed-run"; [ -r "$f" ] && head -c 200 "$f"' | tr -d '\r\n')"
    case "$marker" in
        planted\(*) ;;
        *) probe_cannot_run "the walk's synthetic Safari History.db is not planted (~/.walk-safari-seed-run: '${marker:-absent}'), so there is no safe source to seed after install" ;;
    esac

    STORE_CONF_PATH="$(box_run "p=\"${STORE_CURL_CONF}\"; [ -r \"\$p\" ] && printf '%s' \"\$p\"" | tr -d '\r\n')"

    nonce="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    url="https://www.example.com/walk-second-tick/${nonce}"
    now="$(date +%s)"; mac=$((now - MAC_EPOCH))
    db='$HOME/Library/Safari/History.db'
    seed_out="$(box_run "D=\"${db}\"
m=\$(\"${SQLITE}\" \"file:\$D?mode=ro\" 'select count(*) from walk_synthetic_marker' 2>&1) || { echo \"NOMARKER \$m\"; exit 0; }
[ \"\$m\" -ge 1 ] 2>/dev/null || { echo \"NOMARKER \$m\"; exit 0; }
e=\$(\"${SQLITE}\" \"\$D\" \"insert into history_items (url, visit_count, daily_visit_counts, should_recompute_derived_visit_counts, visit_count_score) values ('${url}', 1, x'', 0, 0); insert into history_visits (history_item, visit_time, title) values ((select id from history_items where url='${url}'), ${mac}, 'Walk fixture second tick');\" 2>&1) || { echo \"REFUSED \$e\"; exit 0; }
echo SEEDED")"
    case "$seed_out" in
        SEEDED) probe_note "seeded 1 synthetic visit after install: ${url}" ;;
        NOMARKER*) probe_cannot_run "~/Library/Safari/History.db carries no walk_synthetic_marker (${seed_out#NOMARKER }); never writing to a history that may be real" ;;
        *) probe_cannot_run "the seed write was refused (${seed_out:-no answer}); over ssh that is TCC, not a refresh verdict" ;;
    esac

    pr="$(_print_job)"
    loaded=true
    case "$pr" in
        NOTLOADED) loaded=false ;;
        UNREADABLE*|'') loaded=null ;;
    esac
    runs0=""; [ "$loaded" = true ] && runs0="$(_field "$pr" runs)"
    probe_note "${LABEL}: loaded=${loaded} runs before=${runs0:-?}"

    kicks=0; waited=0; after=0; runs="$runs0"; last=""
    if [ "$loaded" = true ] && [ -n "$runs0" ]; then
        while [ "$kicks" -lt "$MAX_KICKS" ]; do
            if [ "$runs" -ge 2 ] && [ "$after" -ge 1 ]; then break; fi
            box_run "\"${LAUNCHCTL}\" kickstart gui/\$(id -u)/${LABEL}" >/dev/null
            kicks=$((kicks + 1))
            local before="$runs"
            while :; do
                pr="$(_print_job)"
                state="$(_field "$pr" state)"; runs="$(_field "$pr" runs)"; last="$(_field "$pr" last_exit)"
                [ -n "$runs" ] || runs="$before"
                if [ "$state" != "running" ] && [ "$runs" -gt "$before" ]; then
                    after=$((after + runs - before)); break
                fi
                [ "$waited" -ge "$WAIT_S" ] && break 2
                [ "${OSTLER_UNDER_TEST:-0}" = "1" ] || sleep "$POLL_S"
                waited=$((waited + POLL_S))
            done
        done
        probe_note "${LABEL}: ${kicks} kickstart(s), runs now ${runs}, ${after} completed after the seed, last exit ${last:-?}, waited ${waited}s"
    fi

    landed="$(_store_count "$url")"
    probe_note "store: safari_history points with the seeded url: ${landed:-UNREADABLE}"

    # Put the fixture back as planted. The store point stays: it is synthetic.
    box_run "\"${SQLITE}\" \"${db}\" \"delete from history_visits where history_item in (select id from history_items where url='${url}'); delete from history_items where url='${url}';\"" >/dev/null

    facts="$(mktemp)"
    printf '{"seeded": true, "loaded": %s, "runs": %s, "runs_after_seed": %s, "last_exit": %s, "landed": %s}\n' \
        "$loaded" "${runs:-null}" "$after" "$( [ -n "$last" ] && printf '"%s"' "$last" || printf null)" "${landed:-null}" > "$facts"
    out="$(python3 "$JUDGE" tick "$facts")"; rc=$?
    rm -f "$facts"
    reason="$(printf '%s\n' "$out" | sed -n 's/^REASON=//p')"
    probe_examined "${runs:-0}" "fda-rerun run(s) and 1 seeded row"
    case "$rc" in
        0)  probe_pass "$reason" ;;
        78) probe_cannot_run "$reason" ;;
        1)  probe_fail_or_advisory "$reason" ;;
        *)  probe_cannot_run "the second-tick judge crashed (rc=${rc}); nothing adjudicated" ;;
    esac
}

probe_main "$@"
