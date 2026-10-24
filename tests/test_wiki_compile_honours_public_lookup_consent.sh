#!/usr/bin/env bash
# test_wiki_compile_honours_public_lookup_consent.sh -- Ostler #30.
#
# THE DEFECT. The wiki compiler (CM044) looked every venue with coordinates up
# on OpenStreetMap (Nominatim, Overpass), and artists and organisations on
# MusicBrainz and Wikipedia, on every compile. It defaulted ON, and nothing on
# a customer Mac ever told it the customer's recorded answer, so a customer
# whose ~/.ostler/config/.env says OSTLER_CONSENT_ENRICHMENT_DECISION="declined"
# still had their places looked up publicly. Same class as #2912.
#
# THE FIX, this side. CM044 now looks nothing up unless the container sees
# OSTLER_PUBLIC_LOOKUPS=agreed. Every compile on the Mac is launched by
# install.sh (first run + background summary compile) or by
# wiki-recompile-tick.sh (daily, and the catch-up agent), and each now derives
# that value from the FILE, at the moment that compile starts.
#
# WHAT THIS PROVES:
#   A. the reader: declined -> off, accepted -> agreed, and every degraded
#      input (missing, unreadable, no key, empty) -> off; a later change of
#      mind is seen on the next call; a caller's leftover env is not an answer.
#   B. the two copies of the reader (install.sh, tick) are byte-identical.
#   C. EVERY compile launch site in both files sets OSTLER_PUBLIC_LOOKUPS, and
#      the compose service defaults it to off. Self-tested against a mutant.
#   D. end to end: the REAL tick, with docker stubbed as a bash function so no
#      real daemon is reachable, hands the compile "off" for a declined .env
#      even when the caller's environment says agreed, and "agreed" for an
#      accepted one, for both the baseline and the detached full compile.
#
# Synthetic only: no real names, no real data.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-$ROOT/install.sh}"
TICK_SH="${TICK_SH:-$ROOT/wiki-recompile/bin/wiki-recompile-tick.sh}"
WORK="$(mktemp -d)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

pass=0; fail=0; cannot=0
ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$*"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$*"; }
cant() { cannot=$((cannot + 1)); printf '  CANNOT-RUN  %s\n' "$*"; }
expect() { # name want got
    if [ "$2" = "$3" ]; then ok "$1 -> $3"; else bad "$1: want '$2', got '$3'"; fi
}

extract_fn() { awk '/^ostler_public_lookups_flag\(\) \{/,/^\}/' "$1"; }

# ---------------------------------------------------------------------------
echo "B. one reader, two copies, byte-identical"
fn_install="$(extract_fn "$INSTALL_SH")"
fn_tick="$(extract_fn "$TICK_SH")"
if [ -z "$fn_install" ] || [ -z "$fn_tick" ]; then
    bad "reader missing (install.sh: ${#fn_install} bytes, tick: ${#fn_tick} bytes)"
elif [ "$fn_install" = "$fn_tick" ]; then
    ok "install.sh and wiki-recompile-tick.sh carry the same reader (${#fn_tick} bytes)"
else
    bad "the two readers differ"; diff <(printf '%s\n' "$fn_install") <(printf '%s\n' "$fn_tick")
fi

# ---------------------------------------------------------------------------
echo "A. the reader"
eval "$fn_tick"
H="$WORK/a"; mkdir -p "$H/config"; E="$H/config/.env"
put() { printf '%s\n' "USER_ID=\"jane\"" "$@" > "$E"; }

put 'OSTLER_CONSENT_ENRICHMENT_DECISION="declined"'; expect "declined (quoted)" off "$(ostler_public_lookups_flag "$H")"
put 'OSTLER_CONSENT_ENRICHMENT_DECISION=declined';   expect "declined (bare)" off "$(ostler_public_lookups_flag "$H")"
put 'OSTLER_CONSENT_ENRICHMENT_DECISION="accepted"'; expect "accepted (quoted)" agreed "$(ostler_public_lookups_flag "$H")"
put 'OSTLER_CONSENT_ENRICHMENT_DECISION=accepted';   expect "accepted (bare)" agreed "$(ostler_public_lookups_flag "$H")"
put 'OSTLER_CONSENT_ENRICHMENT_DECISION=""';         expect "empty answer" off "$(ostler_public_lookups_flag "$H")"
put 'OSTLER_CONSENT_ARTICLE_9_DECISION="accepted"';  expect "key absent (another consent says yes)" off "$(ostler_public_lookups_flag "$H")"
put 'OSTLER_CONSENT_ENRICHMENT_DECISION="accepted"' 'OSTLER_CONSENT_ENRICHMENT_DECISION="declined"'
expect "two lines, the last one wins" off "$(ostler_public_lookups_flag "$H")"
put 'OSTLER_CONSENT_ENRICHMENT_DECISION="declined"'
expect "caller env says accepted, file says declined" off "$(OSTLER_CONSENT_ENRICHMENT_DECISION=accepted OSTLER_PUBLIC_LOOKUPS=agreed ostler_public_lookups_flag "$H")"
put 'OSTLER_CONSENT_ENRICHMENT_DECISION="accepted"'; first="$(ostler_public_lookups_flag "$H")"
put 'OSTLER_CONSENT_ENRICHMENT_DECISION="declined"'; second="$(ostler_public_lookups_flag "$H")"
expect "change of mind, accepted then declined" "agreed off" "$first $second"
rm -f "$E"; expect "no .env at all" off "$(ostler_public_lookups_flag "$H")"
put 'OSTLER_CONSENT_ENRICHMENT_DECISION="accepted"'; chmod 000 "$E"
if [ -r "$E" ]; then
    cant "unreadable .env: running as uid $(id -u), which can read a mode-000 file"
else
    expect "unreadable .env (says accepted)" off "$(ostler_public_lookups_flag "$H")"
fi
chmod 600 "$E"

# ---------------------------------------------------------------------------
echo "C. every compile launch site sets OSTLER_PUBLIC_LOOKUPS"
# A site passes if the run line itself sets it, or if `export
# OSTLER_PUBLIC_LOOKUPS` appears earlier inside the same `bash -c '` block.
check_sites() { # file -> prints "sites ungated" and one line per ungated site
    awk '
        /bash -c '\''[[:space:]]*$/ { inblk = 1; exported = 0 }
        inblk && /^[[:space:]]*'\'' _ / { inblk = 0; exported = 0 }
        inblk && /export OSTLER_PUBLIC_LOOKUPS/ { exported = 1 }
        /^[[:space:]]*#/ { next }
        /(log|printf|echo) / { next }
        /docker compose --profile compile run/ {
            sites++
            if ($0 ~ /OSTLER_PUBLIC_LOOKUPS=/ || (inblk && exported)) next
            ungated++; printf "    ungated %s:%d: %s\n", FILENAME, NR, $0 > "/dev/stderr"
        }
        END { printf "%d %d\n", sites + 0, ungated + 0 }
    ' "$1"
}
for f in "$INSTALL_SH" "$TICK_SH"; do
    read -r sites ungated < <(check_sites "$f")
    if [ "$sites" -eq 0 ]; then
        bad "$(basename "$f"): found 0 compile sites, the scan is blind"
    elif [ "$ungated" -eq 0 ]; then
        ok "$(basename "$f"): $sites of $sites compile sites set OSTLER_PUBLIC_LOOKUPS"
    else
        bad "$(basename "$f"): $ungated of $sites compile sites do not set OSTLER_PUBLIC_LOOKUPS"
    fi
done
# Self-test: strip the setting from a copy and the scan must see it.
sed -e 's/OSTLER_PUBLIC_LOOKUPS="\$_public_lookups" docker/docker/' \
    -e '/export OSTLER_PUBLIC_LOOKUPS/d' "$TICK_SH" > "$WORK/mutant-tick.sh"
if cmp -s "$TICK_SH" "$WORK/mutant-tick.sh"; then
    bad "self-test: the mutation did not apply, so it proves nothing"
else
    read -r msites mungated < <(check_sites "$WORK/mutant-tick.sh" 2>/dev/null)
    if [ "$mungated" -eq "$msites" ] && [ "$msites" -gt 0 ]; then
        ok "self-test: with the setting stripped, the scan flags $mungated of $msites sites"
    else
        bad "self-test: stripped mutant flagged $mungated of $msites sites"
    fi
fi
svc="$(awk '/^  wiki-compiler:/{f=1} f&&/^  [a-z][a-z-]*:$/&&!/wiki-compiler/{exit} f' "$INSTALL_SH")"
if grep -qF -- '- OSTLER_PUBLIC_LOOKUPS=${OSTLER_PUBLIC_LOOKUPS:-off}' <<< "$svc"; then
    ok "compose wiki-compiler service maps OSTLER_PUBLIC_LOOKUPS, default off"
else
    bad "compose wiki-compiler service does not map OSTLER_PUBLIC_LOOKUPS with a default of off ($(printf '%s\n' "$svc" | wc -l | tr -d ' ') lines read)"
fi

# ---------------------------------------------------------------------------
echo "D. the real tick, docker stubbed"
run_tick() { # decision caller_env -> prints the recorded "lookups|args" lines for compile runs
    local d="$WORK/d-$1-$2" ; rm -rf "$d"; mkdir -p "$d/fakehome/.ostler/config" "$d/fakehome/.ostler/logs"
    local od="$d/fakehome/.ostler"
    printf 'services: {}\n' > "$od/docker-compose.yml"
    [ "$1" = none ] || printf 'OSTLER_CONSENT_ENRICHMENT_DECISION="%s"\n' "$1" > "$od/config/.env"
    : > "$d/docker.log"
    # A bash FUNCTION, exported: it wins over any docker on PATH (the tick
    # prepends /usr/local/bin, where a dev Mac keeps the real one) and is
    # inherited by the detached `nohup bash -c` full compile.
    DOCKER_LOG="$d/docker.log" HOME="$d/fakehome" OSTLER_DIR="$od" OSTLER_INGEST_SLOT=0 \
    OSTLER_RESOURCE_GOVERNOR=0 OSTLER_PUBLIC_LOOKUPS="$2" \
    bash -c '
        docker() { printf "%s|%s\n" "${OSTLER_PUBLIC_LOOKUPS-UNSET}" "$*" >> "$DOCKER_LOG"; return 0; }
        export -f docker
        bash "$1"
    ' _ "$TICK_SH" > "$d/tick.out" 2>&1
    local rc=$?
    # The full compile is detached: wait for it, bounded.
    local i=0
    while [ $i -lt 100 ] && [ "$(grep -c 'compose --profile compile run' "$d/docker.log")" -lt 2 ]; do
        sleep 0.1; i=$((i + 1))
    done
    printf 'rc=%s\n' "$rc"
    grep 'compose --profile compile run' "$d/docker.log"
}
for case in "declined agreed" "none agreed" "accepted UNSETX"; do
    set -- $case
    decision="$1"; caller="$2"; [ "$caller" = UNSETX ] && caller=""
    want=off; [ "$decision" = accepted ] && want=agreed
    out="$(run_tick "$decision" "$caller")"
    runs="$(printf '%s\n' "$out" | grep -c 'compose --profile compile run')"
    base="$(printf '%s\n' "$out" | grep 'OSTLER_WIKI_SKIP_LLM=1' | head -1 | cut -d'|' -f1)"
    full="$(printf '%s\n' "$out" | grep 'compose --profile compile run' | grep -v 'OSTLER_WIKI_SKIP_LLM' | head -1 | cut -d'|' -f1)"
    if [ "$runs" -lt 2 ]; then
        bad "tick, recorded=$decision caller=${caller:-unset}: only $runs compile run(s) recorded, want 2 ($(printf '%s' "$out" | head -1))"
        continue
    fi
    expect "tick baseline compile, recorded=$decision caller=${caller:-unset}" "$want" "$base"
    expect "tick detached full compile, recorded=$decision caller=${caller:-unset}" "$want" "$full"
done

echo
echo "=== $pass passed / $fail failed / $cannot cannot-run ==="
[ "$fail" -eq 0 ]
