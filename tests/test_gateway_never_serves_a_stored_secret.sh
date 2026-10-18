#!/usr/bin/env bash
# gateway_never_serves_a_stored_secret, RED/GREEN end to end through the real
# probe script (box_run on this machine, OSTLER_BOX_HOST unset) and the real
# hub contract's gateway route list, against a fake gateway:
#   1. the lib's own --self-test (8 arms) passes, and the probe's --self-test
#      returns FAIL (1), as the walk runner's phase 1 demands
#   2. a fake gateway that leaks the paired token on GET /api/config: the
#      probe FAILs (1) and names GET /api/config
#   3. a clean fake gateway: PASS (0), with every gateway route requested
#   4. a positive control that sees 0: CANNOT-RUN (78), never PASS
#   5. no route answering: CANNOT-RUN (78)
#   6. in every arm, no secret value appears anywhere in the probe's output
#   7. mutation: a blinded counter turns arm 2 into CANNOT-RUN, not PASS
# Synthetic values only (the lib's SYN_* constants).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
fails=0; total=0
ok() { total=$((total + 1)); echo "  ok    $1"; }
bad() { total=$((total + 1)); fails=$((fails + 1)); echo "  FAIL  $1"; }
LIBDIR=scripts/box_walk_probes/lib
PROBE=scripts/box_walk_probes/probes/gateway_never_serves_a_stored_secret.sh
work="$(mktemp -d)"; pids=()
cleanup() { for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$work"; }
trap cleanup EXIT

python3 "$LIBDIR/stored_secret_sweep.py" --self-test >/dev/null 2>&1 \
    && ok "stored_secret_sweep --self-test: leaks red, blind control and dead bases CANNOT-RUN, clean green" || bad "stored_secret_sweep --self-test"
bash "$PROBE" --self-test >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "probe --self-test returns FAIL (1)" || bad "probe --self-test returned $rc"

# A fake gateway in its own process. $1 = leak spec "METHOD PATH" or "none".
start_fake() {
    local portfile="$work/port.$1.$$"
    rm -f "$portfile"
    python3 - "$LIBDIR" "$portfile" "$2" >/dev/null 2>&1 <<'PY' &
import sys, time
sys.path.insert(0, sys.argv[1])
import stored_secret_sweep as s
spec = sys.argv[3].split()
srv = s._fake_server(None if spec == ["none"] else (spec[0], spec[1], s.SYN_TOKEN))
open(sys.argv[2], "w").write(str(srv.server_address[1]))
time.sleep(600)
PY
    pids+=("$!")
    for _ in $(seq 1 50); do [ -s "$portfile" ] && break; sleep 0.1; done
    FAKE_PORT="$(cat "$portfile")"
}

mkdir -p "$work/ostler/assistant-config"
python3 - "$LIBDIR" "$work" <<'PY'
import os, shutil, sys
sys.path.insert(0, sys.argv[1])
import stored_secret_sweep as s
cfg, _, blind = s.write_fixture(sys.argv[2])
shutil.move(cfg, os.path.join(sys.argv[2], "ostler/assistant-config/config.toml"))
PY
[ "$(stat -c %a "$work/ostler/assistant-config/config.toml" 2>/dev/null || stat -f %Lp "$work/ostler/assistant-config/config.toml")" = 600 ] \
    && ok "the fixture config.toml is 0600" || bad "the fixture config.toml is not 0600"
SECRETS="$(python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import stored_secret_sweep as s; print(s.SYN_TOKEN); print(s.SYN_TOKEN2); print(s.SYN_VANE)" "$LIBDIR")"
ngw="$(python3 -c "import json; print(len([r for r in json.load(open('vendor/cm041/assistant_api/hub_contract.yaml'))['routes'] if r['listener']=='gateway']))")"

run_arm() {  # $1 port(s), extra env in caller
    OSTLER_DIR="$work/ostler" OSTLER_SECRET_SWEEP_BASES="$1" bash "$PROBE" > "$work/out" 2>&1
    echo $?
}
no_values() {
    local leaked=0 v
    while IFS= read -r v; do /usr/bin/grep -qF -- "$v" "$work/out" && leaked=1; done <<< "$SECRETS"
    [ "$leaked" -eq 0 ] && ok "$1: no secret value in the probe output" || bad "$1: a secret value reached the probe output"
}

start_fake leak 'GET /api/config'; pl="$FAKE_PORT"
rc="$(run_arm "http://127.0.0.1:$pl")"
[ "$rc" -eq 1 ] && /usr/bin/grep -q 'FAIL   GET /api/config on http://127.0.0.1' "$work/out" \
    && ok "a token leaked on GET /api/config: FAIL naming the route" || { bad "leak arm rc=$rc"; tail -5 "$work/out"; }
nf="$(/usr/bin/grep -cE '^  FAIL   [A-Z]+ /' "$work/out")"
[ "$nf" -eq 1 ] && ok "exactly one route named (the leaking one)" || bad "leak arm named $nf routes"
no_values "leak arm"

start_fake clean none; pc="$FAKE_PORT"
rc="$(run_arm "http://127.0.0.1:$pc")"
[ "$rc" -eq 0 ] && ok "a clean fake gateway: PASS" || { bad "clean arm rc=$rc"; tail -5 "$work/out"; }
/usr/bin/grep -qE "^  ok     [0-9]+ requests" "$work/out" && req="$(/usr/bin/grep -oE '^  ok     [0-9]+' "$work/out" | tail -1 | tr -dc 0-9)" || req=0
[ "$req" -gt "$ngw" ] && ok "the clean arm made $req requests over $ngw contract gateway routes" || bad "the clean arm made $req requests for $ngw routes"
no_values "clean arm"

# Control sees 0: drive the lib directly with a control file lacking the secret
# (the probe has no flag for it on purpose); then a dead base through the probe.
python3 - "$LIBDIR" "$work" "$pc" <<'PY' > "$work/out"; rc=$?
import json, os, sys
sys.path.insert(0, sys.argv[1])
import stored_secret_sweep as s
w = sys.argv[2]
res = s.sweep(os.path.join(w, "ostler/assistant-config/config.toml"), "vendor/cm041/assistant_api/hub_contract.yaml",
              ["http://127.0.0.1:" + sys.argv[3]], control_file=os.path.join(w, "control_without_secret.txt"), timeout=3)
lines, rc = s.judge(res)
print("\n".join(lines))
sys.exit(rc)
PY
[ "$rc" -eq 78 ] && /usr/bin/grep -q 'positive control saw 0' "$work/out" \
    && ok "control sees 0: CANNOT-RUN" || bad "control-zero arm rc=$rc"
no_values "control-zero arm"
rc="$(run_arm "http://127.0.0.1:9")"
[ "$rc" -eq 78 ] && ok "no route answering: CANNOT-RUN" || bad "dead-base arm rc=$rc"
mv "$work/ostler/assistant-config/config.toml" "$work/cfg.away"
rc="$(run_arm "http://127.0.0.1:$pc")"
[ "$rc" -eq 78 ] && ok "config.toml absent: CANNOT-RUN" || bad "absent-config arm rc=$rc"
mv "$work/cfg.away" "$work/ostler/assistant-config/config.toml"

# Mutation: blind the counter; the leak arm must become CANNOT-RUN, never PASS.
mut="$work/mut"; mkdir -p "$mut/scripts/box_walk_probes/lib" "$mut/scripts/box_walk_probes/probes" "$mut/vendor/cm041/assistant_api"
cp scripts/box_walk_probes/lib/probe.sh "$mut/scripts/box_walk_probes/lib/"
cp "$PROBE" "$mut/scripts/box_walk_probes/probes/"
cp vendor/cm041/assistant_api/hub_contract.yaml "$mut/vendor/cm041/assistant_api/"
sed 's/return sum(blob.count(f) for f in forms(value, extra))/return 0/' "$LIBDIR/stored_secret_sweep.py" > "$mut/scripts/box_walk_probes/lib/stored_secret_sweep.py"
if cmp -s "$LIBDIR/stored_secret_sweep.py" "$mut/scripts/box_walk_probes/lib/stored_secret_sweep.py"; then
    bad "mutant did not apply"
else
    OSTLER_DIR="$work/ostler" OSTLER_SECRET_SWEEP_BASES="http://127.0.0.1:$pl" bash "$mut/scripts/box_walk_probes/probes/gateway_never_serves_a_stored_secret.sh" > "$work/out" 2>&1; rc=$?
    [ "$rc" -eq 78 ] && ok "mutant (blind counter) on the leaking gateway: CANNOT-RUN, not PASS" || bad "mutant returned $rc"
fi

grep -q "^gateway_never_serves_a_stored_secret	blocking	" scripts/walk_promote_scope.tsv \
    && ok "declared BLOCKING in walk_promote_scope.tsv" || bad "not declared blocking"
grep -q 'probe: "gateway_never_serves_a_stored_secret"' cut-manifests/permanent.yaml \
    && ok "declared in cut-manifests/permanent.yaml" || bad "no permanent.yaml row"
echo "== $((total - fails)) pass / $fails fail / $total total =="
[ "$fails" -eq 0 ]
