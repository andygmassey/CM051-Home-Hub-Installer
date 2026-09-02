#!/usr/bin/env bash
# probes/ingest_coverage.sh
# ============================================================================
# QUESTION: of the NINE ingest sources this product installs, how many have
#           actually landed data, and is any store still EMPTY?
#
# WHY THIS PROBE EXISTS, and it is the plainest gap in the suite
# --------------------------------------------------------------
# On 2026-08-19 Andy asked a simple question -- "so does everything work?" --
# and neither agent could answer it. Not because the box was broken, but
# because nothing measures the thing the question is about.
#
# The eight probes that existed answered "did the mechanism run" or "is it
# self-consistent":
#
#   daemon_is_listening        installed_bundle_seal_intact
#   freshness_panel_has_dates  launchd_no_ephemeral_paths
#   install_error_honesty      no_unexpected_egress
#   pair_state_agreement       people_count_agreement
#
# Not one counts sources. Not one asserts data arrived. people_count_agreement
# is the sharpest illustration: it checks the count AGREES across three
# surfaces, so THREE SURFACES AGREEING ON ZERO PASSES IT. Consistency is not
# liveness, and the suite had only consistency.
#
# THE DENOMINATOR, which nobody had written down
# ----------------------------------------------
# Measured from install.sh: every source the installer hydrates.
#
#   ai_conversations  apple_notes  browsing  email_preferences  imessage
#   people            places       privacy_backfill             whatsapp
#                                                             = NINE
#
# They land in four stores. Without that denominator, "four channels are
# ingesting" is unreadable -- four out of what? It was four out of nine, and
# the difference between those two sentences is the whole product claim.
#
# EMPTY IS THE FAILURE. FLAT IS NOT.
# ----------------------------------
# The tempting assertion is "every store must have grown since last run". That
# is wrong and it would fire constantly: a customer who sent no messages
# overnight has a legitimately flat conversations store, and a probe that calls
# that a fault is a false accusation that teaches operators to ignore it.
#
# So the FAIL condition is EMPTY, not FLAT:
#
#   count == 0   nothing has EVER arrived here.        -> FAIL
#   count > 0, unchanged since baseline                -> PASS, reported FLAT
#   count > 0, grown since baseline                    -> PASS, reported MOVED
#   store unreachable                                  -> CANNOT-RUN
#
# FLAT is reported loudly but does not fail, because this probe cannot tell
# "quiet" from "dead" and MUST NOT PRETEND IT CAN. That discrimination needs a
# per-source reachability signal the stores do not carry. Saying so is the
# honest outcome; guessing would put a false verdict in a suite whose whole
# value is that its verdicts are trustworthy.
#
# WHY A BASELINE FILE
# -------------------
# A count alone is a snapshot and snapshots get restated as present tense --
# which is exactly how the "WhatsApp is our only working source" claim survived
# a day past its evidence. Recording the count with its timestamp means the
# NEXT run reports a delta and an age, so a reader can see how old the number
# is without trusting anybody's memory.
#
# macOS bash 3.2.57 + BSD userland. British English; " -- " not em-dashes.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="ingest_coverage"
PROBE_QUESTION="of the nine ingest sources, how many have landed data, and is any store EMPTY?"

QDRANT_URL="${OSTLER_QDRANT_URL:-http://127.0.0.1:6333}"
BASELINE_FILE="${OSTLER_INGEST_BASELINE:-${HOME}/.ostler/state/ingest_coverage_baseline.tsv}"

# ---------------------------------------------------------------------------
# THE DISCRIMINATOR THIS PROBE SAID IT DID NOT HAVE (#851).
#
# The header above is right that a point count cannot tell a QUIET source from
# a DEAD one, and it was right to refuse to fail on FLAT alone. But the fact
# that settles it is one launchctl read away, and it is not in this file yet.
#
# com.ostler.fda-rerun is the recurring top-up for EVERYTHING that is not
# email: contacts, calendar, iMessage, WhatsApp, browsing, notes. If it is
# dying on every fire then FLAT is not quiet, it is dead, and the customer is
# looking at a graph frozen at install time while the installer copy tells
# them work continues in the background.
#
# MEASURED on .228 2026-08-21, 11 samples one minute apart: conversation
# columns MOVED, graph columns FLAT TO THE DIGIT (triples 246725 both ends),
# with com.ostler.fda-rerun at "last exit code = 1", 3 runs of 3. The moving
# column is the control: the instrument worked and the graph really was frozen.
# This probe was in the suite that night and would have said PASS.
#
# ⚠️ ASK launchctl print, NEVER launchctl list or load: `launchctl load` exits
# 0 on failure, and only `print` carries "last exit code".
TOPUP_AGENT="${OSTLER_TOPUP_AGENT:-com.ostler.fda-rerun}"
TOPUP_INTERVAL_S="${OSTLER_TOPUP_INTERVAL_S:-3600}"
OLLAMA_URL="${OSTLER_OLLAMA_URL:-http://127.0.0.1:11434/api/tags}"

# Prints REACHABLE | UNREACHABLE | UNKNOWN:<code>.
#
# The top-up agent embeds as it ingests, so the embedder being down makes it
# exit non-zero WITHOUT the pipeline being dead. Without this the FAIL arm
# above cannot tell those apart and will convict a healthy box (@A2, 2026-09-02).
ollama_reachable() {
    local code
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then
        printf '%s' "${FAKE_ollama:-REACHABLE}"
        return 0
    fi
    code="$(box_run "curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 5 '${OLLAMA_URL}'" \
             | tr -d "\r\n ")"
    case "$code" in
        200) printf 'REACHABLE' ;;
        000|"") printf 'UNREACHABLE' ;;
        *)   printf 'UNKNOWN:HTTP_%s' "$code" ;;
    esac
}

# Prints HEALTHY | DEAD:<code> | UNKNOWN:<reason-code>.
#
# UNKNOWN is a first-class outcome, not a soft pass. A reason CODE rather than
# a reason STRING because walks/*.tsv already withholds not_measured_reasons on
# the ground that this repo is public -- so a string cannot survive into the
# record, and a record that says a probe went quiet WITHOUT saying why is what
# let #851 sit unexamined for eleven days. A code carries no operator data.
topup_agent_health() {
    local uid out code
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then
        printf '%s' "${FAKE_topup_health:-UNKNOWN:SELFTEST}"
        return 0
    fi
    uid="$(box_run 'id -u' | tr -d "\r\n ")"
    if [ -z "$uid" ]; then printf 'UNKNOWN:NO_UID'; return 0; fi
    out="$(box_run "launchctl print gui/${uid}/${TOPUP_AGENT}")"
    if [ -z "$out" ]; then printf 'UNKNOWN:AGENT_UNREADABLE'; return 0; fi
    code="$(printf '%s' "$out" | awk -F'=' '/last exit code/{print $2}' \
              | awk '{print $1}' | tr -d "\r\n ")"
    case "$code" in
        "")   printf 'UNKNOWN:NO_EXIT_CODE_FIELD' ;;
        0)    printf 'HEALTHY' ;;
        *)    printf 'DEAD:%s' "$code" ;;
    esac
}

# STORE CREDENTIAL. Qdrant answers 401 to a keyless request on every enforce-ON
# install (#550/#1222). count_store used to query BARE and read that 401 as
# UNAVAILABLE -> "not one of the stores answered", which cannot tell "the probe
# brought no key" from "the store is down". So it now presents the install's own
# -K config, exactly as people_seed_and_retrieval does (#1268/#1284/#1285).
# STORE_CONF_PATH, never the literal STORE_CURL_CONF: the literal single-quoted
# at a -K site carries an unexpanded $HOME, curl exits 26, no request, and the
# caller reads 000 (#1284). STORE_CONF_PATH is $HOME expanded on the box.
STORE_CURL_CONF="${OSTLER_PROBE_STORE_CURL_CONF:-\$HOME/.ostler/secrets/store-curl.conf}"
STORE_CONF_PATH=""   # STORE_CURL_CONF with $HOME expanded on the box
STORE_AUTH=""        # "conf" once the box is proven to carry a usable config
STORE_AUTH_REASON="" # when STORE_AUTH!="conf": WHY (absent / unreadable / empty config)

# Resolve the store curl config ON THE BOX ($HOME expands there) and decide
# whether a usable credential exists. Called once at the top of run_probe.
_store_resolve() {
    STORE_CONF_PATH="$(box_run "printf '%s' \"${STORE_CURL_CONF}\"" | tr -d '\r\n')"
    # Classify the config ON THE BOX so the walk record can name WHY a read is
    # keyless instead of collapsing three causes into one message. The config is
    # written 0600 owner-only (#549/#550), so a probe running as another account
    # gets permission-denied on a file that may be full of headers -- printing
    # that as "carried no header lines" tells a tired human the opposite of true.
    local _state
    _state="$(box_run "if [ ! -e '${STORE_CONF_PATH}' ]; then printf ABSENT; elif [ ! -r '${STORE_CONF_PATH}' ]; then printf UNREADABLE; elif [ \"\$(/usr/bin/grep -c '^header = ' '${STORE_CONF_PATH}' 2>/dev/null)\" -gt 0 ]; then printf HEADERS; else printf EMPTY; fi" | tr -d '\r\n ')"
    case "$_state" in
        HEADERS)    STORE_AUTH="conf"; STORE_AUTH_REASON="" ;;
        ABSENT)     STORE_AUTH="";     STORE_AUTH_REASON="the store curl config ${STORE_CONF_PATH:-<unresolved>} does not exist on the box" ;;
        UNREADABLE) STORE_AUTH="";     STORE_AUTH_REASON="the store curl config ${STORE_CONF_PATH} exists but is not readable by this probe's account -- it is written 0600 owner-only, so a probe running as a different user cannot read a config that may be full of headers; this is NOT evidence the credential is absent" ;;
        *)          STORE_AUTH="";     STORE_AUTH_REASON="the store curl config ${STORE_CONF_PATH} is readable but carries no 'header = ' lines" ;;
    esac
}

# The four stores, and which of the nine sources feed each. The mapping is the
# reason this probe can talk about SOURCES rather than only collections.
STORES="conversations people safari_history preferences"

sources_for() {
    case "$1" in
        conversations)  printf 'imessage whatsapp ai_conversations' ;;
        people)         printf 'people' ;;
        safari_history) printf 'browsing' ;;
        preferences)    printf 'email_preferences apple_notes places privacy_backfill' ;;
        *)              printf '' ;;
    esac
}

# Point count for one Qdrant collection. Prints an integer, or UNAVAILABLE.
# UNAVAILABLE and 0 are DIFFERENT and must never collapse: the first means the
# probe could not look, the second means it looked and found nothing.
count_store() {
    local name="$1"
    if [ "${SELF_TEST_LOCAL:-0}" -eq 1 ]; then
        local var="FAKE_${name}"
        eval "printf '%s' \"\${$var:-UNAVAILABLE}\""
        return
    fi
    local out code khdr=""
    [ "$STORE_AUTH" = "conf" ] && khdr="-K '${STORE_CONF_PATH}'"
    # Present the store credential (STORE_CONF_PATH, already $HOME-expanded) and
    # capture the HTTP code. A 401/403 and a 000 are NOT "UNAVAILABLE": they are
    # an auth or transport fact the caller must adjudicate with the right reason,
    # never collapse into "the store did not answer".
    out="$(box_run "curl -sS --noproxy '*' -m 10 ${khdr} '${QDRANT_URL}/collections/${name}' -w '\n%{http_code}'")"
    code="$(printf '%s\n' "$out" | tail -n1)"
    out="$(printf '%s' "$out" | sed '$d')"
    case "$code" in
        401|403) printf 'AUTH'; return ;;
        000|'') printf 'TRANSPORT'; return ;;
    esac
    printf '%s' "$out" | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw:
    print("UNAVAILABLE"); sys.exit(0)
try:
    d=json.loads(raw)
    if d.get("status")!="ok":
        print("UNAVAILABLE"); sys.exit(0)
    n=d["result"].get("points_count")
    print("UNAVAILABLE" if n is None else int(n))
except Exception:
    print("UNAVAILABLE")
'
}

read_baseline() {
    # <store>\t<count>\t<iso8601>
    [ -f "$BASELINE_FILE" ] || return 1
    grep -E "^$1	" "$BASELINE_FILE" 2>/dev/null | head -1
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "box ${OSTLER_BOX_HOST:-<local>} is not reachable over ssh. Nothing was measured; this is not a pass."
    fi

    _store_resolve

    local total_stores=0 reachable=0 empty=0 moved=0 flat=0
    local auth_seen=0 transport_seen=0
    local unavailable_list="" empty_list="" flat_list="" moved_list=""
    local sources_evidenced=0
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local newline
    newline="$(printf '\n')"
    local fresh_baseline=""

    printf 'STORE            COUNT      BASELINE   AGE          STATE\n'

    local s count base_line base_count base_when age_note state
    for s in $STORES; do
        total_stores=$((total_stores + 1))
        count="$(count_store "$s")"
        # An auth or transport fact is recorded so the aggregate verdict below
        # names the RIGHT reason; the store still counts as not-measured here.
        case "$count" in
            AUTH)      auth_seen=1;      count="UNAVAILABLE" ;;
            TRANSPORT) transport_seen=1; count="UNAVAILABLE" ;;
        esac

        if [ "$count" = "UNAVAILABLE" ]; then
            unavailable_list="${unavailable_list} ${s}"
            printf '%-16s %-10s %-10s %-12s %s\n' "$s" "UNAVAIL" "-" "-" "NOT MEASURED"
            continue
        fi
        reachable=$((reachable + 1))

        base_count="-"; base_when="-"; age_note="-"
        if base_line="$(read_baseline "$s")"; then
            base_count="$(printf '%s' "$base_line" | cut -f2)"
            base_when="$(printf '%s' "$base_line" | cut -f3)"
            age_note="$base_when"
        fi

        if [ "$count" -eq 0 ]; then
            empty=$((empty + 1))
            empty_list="${empty_list} ${s}"
            state="EMPTY"
        elif [ "$base_count" = "-" ]; then
            state="POPULATED (no baseline yet)"
            sources_evidenced=$((sources_evidenced + $(sources_for "$s" | wc -w)))
        elif [ "$count" -gt "$base_count" ]; then
            moved=$((moved + 1))
            moved_list="${moved_list} ${s}"
            state="MOVED +$((count - base_count))"
            sources_evidenced=$((sources_evidenced + $(sources_for "$s" | wc -w)))
        else
            flat=$((flat + 1))
            flat_list="${flat_list} ${s}"
            state="FLAT"
            sources_evidenced=$((sources_evidenced + $(sources_for "$s" | wc -w)))
        fi

        printf '%-16s %-10s %-10s %-12s %s\n' "$s" "$count" "$base_count" "$age_note" "$state"
        fresh_baseline="${fresh_baseline}${s}	${count}	${now}${newline}"
    done

    printf '\n'
    probe_examined "$reachable of $total_stores" "stores read (9 sources map onto these 4 stores)"
    probe_note "sources with data evidenced : ${sources_evidenced} of 9"
    probe_note "stores EMPTY                : ${empty}${empty_list:+ --${empty_list}}"
    probe_note "stores MOVED since baseline : ${moved}${moved_list:+ --${moved_list}}"
    probe_note "stores FLAT since baseline  : ${flat}${flat_list:+ --${flat_list}}"

    # Persist the new baseline ONLY when every store was readable. A partial
    # write would silently reset the deltas for the stores that did answer and
    # destroy the comparison this probe exists to make.
    if [ -n "$fresh_baseline" ] && [ "$reachable" -eq "$total_stores" ] && [ "${SELF_TEST_LOCAL:-0}" -ne 1 ]; then
        mkdir -p "$(dirname "$BASELINE_FILE")" 2>/dev/null
        printf '%s' "$fresh_baseline" > "$BASELINE_FILE" 2>/dev/null \
            && probe_note "baseline rewritten: $BASELINE_FILE" \
            || probe_note "baseline NOT written (unwritable): $BASELINE_FILE"
    elif [ "$reachable" -ne "$total_stores" ]; then
        probe_note "baseline NOT rewritten: only ${reachable} of ${total_stores} stores answered, and a partial baseline destroys the next run's deltas."
    fi

    # Transport and auth are adjudicated BEFORE the reachability verdicts below,
    # so a keyless 401 reads as "store auth is enforced and this run brought no
    # key" and a 000 as a transport failure -- not as "the store did not answer",
    # which is the pre-#550 reason that conflated a missing credential with a
    # down store.
    if [ "$transport_seen" -eq 1 ]; then
        probe_cannot_run "at least one store gave no HTTP response at ${QDRANT_URL} -- a transport failure (refused, timed out, proxied, or a bad curl argument), not a result. Coverage was not measured; nothing here is evidence about ingest."
    fi
    if [ "$auth_seen" -eq 1 ]; then
        if [ "$STORE_AUTH" = "conf" ]; then
            probe_fail "Qdrant returned HTTP 401/403 WITH the install's store credential presented (-K, ${STORE_CONF_PATH}) at ${QDRANT_URL}. A key the store refuses is a real fault, not a missing probe credential."
        else
            probe_cannot_run "Qdrant returned HTTP 401/403 and this run presented NO store credential -- ${STORE_AUTH_REASON:-no usable store credential was resolved}. Store auth is ENFORCED since #550/#1222, so a keyless probe cannot read the collections whether or not data exists -- ingest coverage was not measured."
        fi
    fi

    # A zero denominator is the thing most likely to be misread as clean.
    if [ "$reachable" -eq 0 ]; then
        probe_cannot_run "not one of the ${total_stores} stores answered at ${QDRANT_URL}. Zero stores measured is not zero problems."
    fi

    if [ "$empty" -gt 0 ]; then
        probe_fail "${empty} of ${total_stores} stores are EMPTY (${empty_list# }). Nothing has ever landed there, so the sources feeding them have delivered nothing."
    fi

    if [ "$reachable" -lt "$total_stores" ]; then
        probe_cannot_run "only ${reachable} of ${total_stores} stores answered (missing:${unavailable_list}). A verdict on a subset would understate coverage."
    fi

    # FLAT is where #851 lived. The header's reasoning is preserved EXACTLY --
    # FLAT alone still never fails -- but the probe no longer stops at "I cannot
    # tell". It asks the one fact that discriminates and then says which of the
    # three answers it got. Three outcomes, three branches.
    if [ "$flat" -gt 0 ]; then
        health="$(topup_agent_health)"
        probe_note "top-up agent ${TOPUP_AGENT} : ${health}"
        case "$health" in
            DEAD:*)
                # ⚠️ A NON-ZERO EXIT IS NOT YET A VERDICT, and this guard is why.
                # @A2 refuted the first draft of this arm on 2026-09-02: a
                # genuinely dead pipeline and a TRANSIENT OLLAMA BLIP both exit 1,
                # and launchd's "last exit code" is up to StartInterval (3600s)
                # STALE -- so one blip in the past hour would convict a box that
                # had already recovered. ingest_coverage never probes Ollama, so
                # that dependency was invisible to this file.
                #
                # Qdrant-down is already adjudicated upstream as TRANSPORT ->
                # CANNOT-RUN. Ollama-down was the hole. So: accuse only when the
                # embedder the agent depends on is REACHABLE and it still died.
                #
                # ⛔ THIS IS A NARROWING, NOT THE COMPLETE FIX. The complete fix is
                # a DISTINCT non-zero from the wrapper (e.g. 3 = stores/embedder
                # unreachable, 1 = real death); without that no arm logic here can
                # fully separate the two. Filed separately; not silently assumed.
                _oll="$(ollama_reachable)"
                if [ "$_oll" != "REACHABLE" ]; then
                    probe_cannot_run "${flat} of ${total_stores} stores are FLAT and ${TOPUP_AGENT} last exited ${health#DEAD:}, but its embedder is ${_oll} -- and a transient embedder outage exits with the SAME code as a genuinely dead pipeline. launchd's last-exit is up to ${TOPUP_INTERVAL_S}s stale, so this cannot distinguish a dead top-up from a box that already recovered. Refusing to convict on an ambiguous code."
                fi
                probe_fail "${flat} of ${total_stores} stores are FLAT since baseline (${flat_list# }) AND the top-up agent ${TOPUP_AGENT} is dying on every fire (last exit code ${health#DEAD:}) WITH its embedder REACHABLE, so this is not a transient dependency outage. FLAT is not quiet here, it is DEAD: that agent is the recurring top-up for every source except email, so contacts, calendar, iMessage, WhatsApp, browsing and notes have no live path into the graph. The install is frozen at install-time contents while the installer copy says work continues in the background (#851)."
                ;;
            UNKNOWN:*)
                probe_cannot_run "${flat} of ${total_stores} stores are FLAT since baseline (${flat_list# }) and this run could NOT read the health of ${TOPUP_AGENT} (${health#UNKNOWN:}). FLAT with unknown top-up health is exactly the state this probe cannot adjudicate -- quiet and dead are indistinguishable from a count alone, and passing here would be a guess with a customer's whole graph behind it."
                ;;
            *)
                probe_pass "all ${total_stores} stores hold data. ${flat} FLAT since baseline (${flat_list# }) and the top-up agent ${TOPUP_AGENT} is HEALTHY (last exit 0), so FLAT here means quiet, not dead."
                ;;
        esac
    fi

    probe_pass "all ${total_stores} stores hold data and ${moved} moved since baseline. ${sources_evidenced} of 9 sources evidenced."
}

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL. A probe that only ever passes is decoration.
# Three arms, because this probe has three ways to be wrong.
# ---------------------------------------------------------------------------
self_test() {
    local rc out fails=0

    # ARM 1: a store is EMPTY -> must FAIL, and must name the store.
    out="$(SELF_TEST_LOCAL=1 FAKE_conversations=1024 FAKE_people=0 \
           FAKE_safari_history=8788 FAKE_preferences=9025 \
           bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
    if [ "$rc" -ne 1 ] || ! printf '%s' "$out" | grep -q 'EMPTY'; then
        printf 'SELF-TEST ARM 1 BROKEN: empty store did not FAIL (rc=%s)\n' "$rc"; fails=$((fails+1))
    else
        printf 'arm 1 OK: an EMPTY store returns FAIL naming it\n'
    fi

    # ARM 2: nothing readable -> must CANNOT-RUN (78), never PASS.
    out="$(SELF_TEST_LOCAL=1 bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
    if [ "$rc" -ne 78 ]; then
        printf 'SELF-TEST ARM 2 BROKEN: unreadable stores returned rc=%s, expected 78\n' "$rc"; fails=$((fails+1))
    else
        printf 'arm 2 OK: zero readable stores is CANNOT-RUN, not a pass\n'
    fi

    # ⚠️ THE ARMS BELOW PIN OSTLER_INGEST_BASELINE. Without it the self-test
    # reads the REAL baseline out of the operator's ~/.ostler and its verdict
    # depends on whose machine ran it -- which is the same family of defect
    # this probe exists to catch, one layer up. Found by this arm failing on a
    # developer Mac that had a populated baseline; a runner with an empty home
    # would have passed and told us nothing.
    local _bl_none="${TMPDIR:-/tmp}/ingest_cov_selftest_absent.$$"
    local _bl_flat="${TMPDIR:-/tmp}/ingest_cov_selftest_flat.$$"
    rm -f "$_bl_none"
    printf 'conversations\t1024\t2026-01-01T00:00:00Z\n'   >  "$_bl_flat"
    printf 'people\t6889\t2026-01-01T00:00:00Z\n'          >> "$_bl_flat"
    printf 'safari_history\t8788\t2026-01-01T00:00:00Z\n'  >> "$_bl_flat"
    printf 'preferences\t9025\t2026-01-01T00:00:00Z\n'     >> "$_bl_flat"

    # ARM 3: all populated, NO baseline -> must PASS. Without this the probe
    # could satisfy arms 1 and 2 by failing unconditionally.
    out="$(SELF_TEST_LOCAL=1 OSTLER_INGEST_BASELINE="$_bl_none" \
           FAKE_conversations=1024 FAKE_people=6889 \
           FAKE_safari_history=8788 FAKE_preferences=9025 \
           bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'SELF-TEST ARM 3 BROKEN: fully populated returned rc=%s, expected 0\n' "$rc"; fails=$((fails+1))
    else
        printf 'arm 3 OK: all stores populated returns PASS\n'
    fi

    # ARM 4 (#851): counts FLAT against the baseline AND the top-up agent dying
    # -> must FAIL. This is the arm that did not exist, and its absence is why
    # a graph frozen to the digit scored PASS on every walk it was part of.
    out="$(SELF_TEST_LOCAL=1 OSTLER_INGEST_BASELINE="$_bl_flat" \
           FAKE_topup_health="DEAD:1" FAKE_ollama="REACHABLE" \
           FAKE_conversations=1024 FAKE_people=6889 \
           FAKE_safari_history=8788 FAKE_preferences=9025 \
           bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
    if [ "$rc" -ne 1 ] || ! printf '%s' "$out" | grep -q 'FLAT is not quiet here, it is DEAD'; then
        printf 'SELF-TEST ARM 4 BROKEN: FLAT + dead top-up returned rc=%s, expected 1 naming it DEAD\n' "$rc"; fails=$((fails+1))
    else
        printf 'arm 4 OK: FLAT + a dying top-up agent WITH a reachable embedder is a FAIL\n'
    fi

    # ARM 7 (@A2's refutation, 2026-09-02): the SAME dead-looking agent must NOT
    # be convicted when its embedder is down. A transient Ollama outage exits
    # with the same code as a real death, and launchd's last-exit is up to an
    # hour stale -- so without this arm the probe false-accuses a box that has
    # already recovered. This arm IS the difference between an instrument and
    # an accusation.
    out="$(SELF_TEST_LOCAL=1 OSTLER_INGEST_BASELINE="$_bl_flat" \
           FAKE_topup_health="DEAD:1" FAKE_ollama="UNREACHABLE" \
           FAKE_conversations=1024 FAKE_people=6889 \
           FAKE_safari_history=8788 FAKE_preferences=9025 \
           bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
    if [ "$rc" -ne 78 ] || ! printf '%s' "$out" | grep -q 'Refusing to convict on an ambiguous code'; then
        printf 'SELF-TEST ARM 7 BROKEN: FLAT + dead top-up + DOWN embedder returned rc=%s, expected 78 (CANNOT-RUN, not an accusation)\n' "$rc"; fails=$((fails+1))
    else
        printf 'arm 7 OK: FLAT + dead-looking agent + DOWN embedder is CANNOT-RUN, not a false accusation\n'
    fi

    # ARM 5 (#851): FLAT with the agent's health UNREADABLE -> must CANNOT-RUN,
    # never PASS. Quiet and dead are indistinguishable from a count alone, so a
    # pass here would be a guess with a customer's whole graph behind it.
    out="$(SELF_TEST_LOCAL=1 OSTLER_INGEST_BASELINE="$_bl_flat" \
           FAKE_topup_health="UNKNOWN:AGENT_UNREADABLE" \
           FAKE_conversations=1024 FAKE_people=6889 \
           FAKE_safari_history=8788 FAKE_preferences=9025 \
           bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
    if [ "$rc" -ne 78 ] || ! printf '%s' "$out" | grep -q 'AGENT_UNREADABLE'; then
        printf 'SELF-TEST ARM 5 BROKEN: FLAT + unknown top-up returned rc=%s, expected 78 carrying the reason CODE\n' "$rc"; fails=$((fails+1))
    else
        printf 'arm 5 OK: FLAT + unreadable top-up health is CANNOT-RUN carrying a reason code\n'
    fi

    # ARM 6: the HEALTHY branch must still PASS, or arms 4 and 5 could be
    # satisfied by a probe that simply never passes once a baseline exists.
    out="$(SELF_TEST_LOCAL=1 OSTLER_INGEST_BASELINE="$_bl_flat" \
           FAKE_topup_health="HEALTHY" \
           FAKE_conversations=1024 FAKE_people=6889 \
           FAKE_safari_history=8788 FAKE_preferences=9025 \
           bash "${BASH_SOURCE[0]}" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'SELF-TEST ARM 6 BROKEN: FLAT + healthy top-up returned rc=%s, expected 0\n' "$rc"; fails=$((fails+1))
    else
        printf 'arm 6 OK: FLAT + a HEALTHY top-up agent still means quiet, and passes\n'
    fi
    rm -f "$_bl_none" "$_bl_flat"

    # THE CONVENTION IS INVERTED HERE, and it cost this probe every box walk
    # it has ever been part of.
    #
    # `--self-test` must come back FAIL (rc 1) when the negative control
    # behaved CORRECTLY -- that is what proves the probe can go red. Every
    # other probe in this directory ends its self_test with probe_fail. This
    # one exited 0 on success, so run_box_walk marked it BROKEN and DISCARDED
    # its real measurement on every run.
    #
    # So ingest coverage -- the one probe that would notice sources reporting
    # ok with a zero payload -- has never been counted. Measured 2026-08-20 by
    # running phase 1 across all probes; it was already being caught, nobody
    # had looked at the output.
    if [ "$fails" -gt 0 ]; then
        probe_examined "$fails" "self-test arm(s) that did NOT behave as required"
        probe_pass "SELF-TEST BROKEN: ${fails} arm(s) failed. This probe cannot demonstrate a FAIL, so its real result must not be trusted."
    fi
    probe_examined 7 "synthetic store readings (negative control)"
    probe_fail "negative control behaved correctly on all 7 arms (an empty store FAILs and is named; zero readable stores is CANNOT-RUN, not a pass; fully populated PASSes; FLAT + a DYING top-up agent FAILs; FLAT + UNREADABLE agent health is CANNOT-RUN carrying a reason code; FLAT + a HEALTHY agent still PASSes; and a dead-looking agent with a DOWN embedder is CANNOT-RUN rather than a false accusation)"
}

probe_main "$@"
