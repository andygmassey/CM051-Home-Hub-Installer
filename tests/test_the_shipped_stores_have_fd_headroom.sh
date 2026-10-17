#!/bin/bash
# F5 / walk #16 (#17 blocker): ostler-qdrant ran with `ulimit -n` = 1024 and
# hit "Too many open files (os error 24)" on RocksDB put_cf. Every later write
# failed ("Not recovered from previous error"): initial_hydrate went red,
# Places wrote 0 and failed 979 with HTTP 500 on PUT /collections/preferences/points.
#
# This reads the SHIPPED compose heredoc in install.sh (never a dev compose) and
# asserts qdrant and oxigraph (both RocksDB) carry nofile soft AND hard >= 65535.
#
# ARM 1 qdrant meets it.   ARM 2 oxigraph meets it.
# ARM 3 CONTROL: with the ulimits lines deleted from the qdrant block the
#       predicate must go RED (has it ever failed: yes, every run).
# ARM 4 CONTROL: soft = 1024 must be RED.
# ARM 5 INDEPENDENCE: ulimits only on oxigraph must leave qdrant RED.
# ARM 6 LIVE (opt-in, OSTLER_LIVE_DOCKER=1): `ulimit -n` inside the pinned
#       Qdrant image under the shipped compose is >= 65535. Otherwise it prints
#       CANNOT-RUN, which is not a pass.
# Runs under /bin/bash 3.2; python3 (stdlib only) does the block parse.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${ROOT}/install.sh"
[ -r "$INSTALL" ] || { echo "CANNOT-RUN: ${INSTALL} unreadable"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
COMPOSE="${WORK}/compose.yml"
START="$(grep -n '^cat > "${OSTLER_DIR}/docker-compose.yml" <<.DCEOF.$' "$INSTALL" | head -1 | cut -d: -f1)"
[ -n "${START:-}" ] || { echo "CANNOT-RUN: compose heredoc opener not found"; exit 2; }
END="$(awk -v s="$START" 'NR>s && /^DCEOF$/ { print NR; exit }' "$INSTALL")"
[ -n "${END:-}" ] || { echo "CANNOT-RUN: DCEOF terminator not found"; exit 2; }
awk -v s="$START" -v e="$END" 'NR>s && NR<e' "$INSTALL" > "$COMPOSE"
LINES="$(grep -c . "$COMPOSE" || true)"
echo "EXAMINED: install.sh:${START}..${END}, ${LINES} lines of the SHIPPED compose"
SVC="$(grep -cE '^  [a-z][a-z0-9-]*:$' "$COMPOSE" || true)"
if [ "${LINES:-0}" -lt 50 ] || [ "${SVC:-0}" -lt 3 ] || ! grep -q '^  qdrant:$' "$COMPOSE" || ! grep -q '^  oxigraph:$' "$COMPOSE"; then
    echo "CANNOT-RUN: span implausible (${LINES} lines, ${SVC} services)"; exit 2
fi
echo "          RANGE CONTROL: ${SVC} services, qdrant and oxigraph both present"

# nofile "<soft> <hard>" of service $2 in file $1, or "none".
nofile_of() {
    python3 - "$1" "$2" <<'PY'
import re, sys
text = open(sys.argv[1]).read().splitlines()
svc = sys.argv[2]
blk, on = [], False
for ln in text:
    if re.match(r"^  [a-z][a-z0-9-]*:\s*$", ln):
        on = (ln.strip() == svc + ":")
        continue
    if on:
        blk.append(ln)
b = "\n".join(blk)
m = re.search(r"^    ulimits:\s*\n\s+nofile:\s*(?:\n((?:\s{8,}.*\n?)+)|(\{[^}\n]*\})|(\d+))", b, re.M)
if not m:
    print("none"); sys.exit(0)
body = m.group(1) or m.group(2) or ""
if m.group(3):
    print(m.group(3), m.group(3)); sys.exit(0)
s = re.search(r"soft:\s*(\d+)", body); h = re.search(r"hard:\s*(\d+)", body)
print((s.group(1) if s else "none"), (h.group(1) if h else "none"))
PY
}
FAIL=0
meets() { # file svc -> 0 if soft and hard >= 65535
    local got soft hard; got="$(nofile_of "$1" "$2")"; soft="${got% *}"; hard="${got#* }"
    echo "          ${2}: nofile soft=${soft} hard=${hard}" >&2
    case "$soft$hard" in *none*) return 1;; esac
    [ "$soft" -ge 65535 ] && [ "$hard" -ge 65535 ]
}
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

meets "$COMPOSE" qdrant   && ok "ARM 1 qdrant nofile >= 65535" || bad "ARM 1 qdrant nofile < 65535 or absent"
meets "$COMPOSE" oxigraph && ok "ARM 2 oxigraph nofile >= 65535" || bad "ARM 2 oxigraph nofile < 65535 or absent"

# ARM 3: strip every ulimits block (3 lines) -> must be RED for qdrant.
awk '/^    ulimits:$/ {skip=4} skip>0 {skip--; next} {print}' "$COMPOSE" > "${WORK}/m3.yml"
if [ "$(grep -c 'ulimits:' "${WORK}/m3.yml" || true)" != "0" ] || [ "$(grep -c 'ulimits:' "$COMPOSE")" -lt 2 ]; then
    bad "ARM 3 mutant did not apply"
elif meets "${WORK}/m3.yml" qdrant 2>/dev/null; then bad "ARM 3 predicate stayed GREEN on the pre-fix compose"; else ok "ARM 3 control: pre-fix compose is RED"; fi

# ARM 4: soft 1024.
sed 's/soft: 65535/soft: 1024/' "$COMPOSE" > "${WORK}/m4.yml"
if cmp -s "$COMPOSE" "${WORK}/m4.yml"; then bad "ARM 4 mutant did not apply"
elif meets "${WORK}/m4.yml" qdrant 2>/dev/null; then bad "ARM 4 soft=1024 stayed GREEN"; else ok "ARM 4 control: soft=1024 is RED"; fi

# ARM 5: remove qdrant's ulimits only (first ulimits block); oxigraph keeps its.
awk '/^    ulimits:$/ && !done {skip=4; done=1} skip>0 {skip--; next} {print}' "$COMPOSE" > "${WORK}/m5.yml"
if [ "$(grep -c 'ulimits:' "${WORK}/m5.yml")" != "$(( $(grep -c 'ulimits:' "$COMPOSE") - 1 ))" ]; then bad "ARM 5 mutant did not apply"
elif meets "${WORK}/m5.yml" qdrant 2>/dev/null; then bad "ARM 5 qdrant GREEN with only oxigraph covered"
elif meets "${WORK}/m5.yml" oxigraph 2>/dev/null; then ok "ARM 5 independence: oxigraph alone leaves qdrant RED"; else bad "ARM 5 oxigraph lost its own"; fi

# ARM 6: live, opt-in.
if [ "${OSTLER_LIVE_DOCKER:-0}" = "1" ]; then
    if docker info >/dev/null 2>&1; then
        got="$(cd "$WORK" && cp "$COMPOSE" docker-compose.yml && QDRANT_API_KEY= docker compose run --rm --no-deps --entrypoint sh qdrant -c 'ulimit -n' 2>/dev/null | tail -1)"
        if [ -n "$got" ] && [ "$got" -ge 65535 ] 2>/dev/null; then ok "ARM 6 live: ulimit -n = ${got} inside the pinned qdrant"; else bad "ARM 6 live: ulimit -n = '${got}'"; fi
    else echo "CANNOT-RUN ARM 6: docker daemon not reachable (not a pass)"; fi
else
    echo "CANNOT-RUN ARM 6: set OSTLER_LIVE_DOCKER=1 with a running daemon (not a pass)"
fi
if [ "$FAIL" -ne 0 ]; then echo "RESULT: ${FAIL} FAIL"; exit 1; fi
echo "RESULT: static arms 1-5 PASS"; exit 0
