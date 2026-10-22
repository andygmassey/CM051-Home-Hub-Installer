#!/usr/bin/env bash
# gateway_never_serves_a_stored_secret, RED/GREEN end to end through the real
# probe script (box_run on this machine, OSTLER_BOX_HOST unset) and the real
# hub contract's gateway route list, against a fake gateway:
#   1. the lib's own --self-test (13 arms) passes, and the probe's --self-test
#      returns FAIL (1), as the walk runner's phase 1 demands
#   2. a fake gateway that leaks the paired token on GET /api/config: the
#      probe FAILs (1) and names GET /api/config
#   3. a clean fake gateway: PASS (0), with every gateway route requested
#   4. a positive control that sees 0: CANNOT-RUN (78), never PASS
#   5. no route answering: CANNOT-RUN (78)
#   6. in every arm, no secret value appears anywhere in the probe's output
#   7. mutation: a blinded counter turns arm 2 into CANNOT-RUN, not PASS
#   8. the fixture enables [email_assistant]: the mailbox app password is a
#      swept secret, POST /api/assistant-mailbox/self-test is in the contract
#      and requested with the bearer. Its Keychain read goes to the security
#      stand-in (tests/e2e/fakebin/security), first on PATH: no test touches a
#      real keychain.
#   9. no outward mail: with a REAL provider host in [email_assistant] the
#      probe prints CANNOT for the self-test route with the reason, sweeps a
#      read-only GET instead, and still PASSes a clean gateway; with loopback
#      hosts (the fixture default, the mailsim case) it POSTs it.
#  10. a PASS with the self-test skipped NAMES it on the verdict line
#      (`VERDICT: PASS (mailbox self-test CANNOT-RUN: host not loopback)`); a
#      loopback PASS carries no qualifier; a mutant that drops the qualifier
#      is caught.
#   8. a fake gateway that echoes the device fingerprint on POST
#      /api/v1/invites/mint (the Hub's invites proxy, ostler-assistant #573):
#      FAIL naming that route, which the probe sweeps even though the vendored
#      contract may not list it yet
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
secret = getattr(s, spec[2]) if len(spec) > 2 else s.SYN_TOKEN
srv = s._fake_server(None if spec == ["none"] else (spec[0], spec[1], secret))
open(sys.argv[2], "w").write(str(srv.server_address[1]))
time.sleep(600)
PY
    pids+=("$!")
    for _ in $(seq 1 50); do [ -s "$portfile" ] && break; sleep 0.1; done
    FAKE_PORT="$(cat "$portfile")"
}

mkdir -p "$work/ostler/assistant-config"
export PATH="$PWD/tests/e2e/fakebin:$PATH"
export FAKE_SECURITY_STORE="$work/fake-keychain.json" FAKE_SECURITY_LOG="$work/fake-security.log"
# box_run is a LOGIN shell, which resets PATH, so the stand-in is also named
# by absolute path; the real security tool must never run here.
export OSTLER_SECRET_SWEEP_SECURITY="$PWD/tests/e2e/fakebin/security"
: > "$FAKE_SECURITY_LOG"
python3 - "$LIBDIR" "$FAKE_SECURITY_STORE" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import stored_secret_sweep as s
json.dump({"default": {s.MAILBOX_SERVICE + "\n" + s.SYN_MAILBOX_ADDR: s.SYN_MAILBOX}}, open(sys.argv[2], "w"))
PY
[ "$(command -v security)" = "$PWD/tests/e2e/fakebin/security" ] && ok "Keychain reads go to the security stand-in" || bad "security stand-in not first on PATH"
python3 - "$LIBDIR" "$work" <<'PY'
import os, shutil, sys
sys.path.insert(0, sys.argv[1])
import stored_secret_sweep as s
cfg, _, blind = s.write_fixture(sys.argv[2])
shutil.move(cfg, os.path.join(sys.argv[2], "ostler/assistant-config/config.toml"))
for sub, name in (("license", "license.json"), ("state", "fingerprint.txt")):
    os.makedirs(os.path.join(sys.argv[2], "ostler", sub), exist_ok=True)
    shutil.move(os.path.join(sys.argv[2], name), os.path.join(sys.argv[2], "ostler", sub, name))
PY
[ "$(stat -c %a "$work/ostler/assistant-config/config.toml" 2>/dev/null || stat -f %Lp "$work/ostler/assistant-config/config.toml")" = 600 ] \
    && ok "the fixture config.toml is 0600" || bad "the fixture config.toml is not 0600"
SECRETS="$(python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import stored_secret_sweep as s; print(s.SYN_TOKEN); print(s.SYN_TOKEN2); print(s.SYN_VANE); print(s.SYN_MAILBOX); print(s.SYN_LICENCE); print(s.SYN_FPRINT)" "$LIBDIR")"
python3 -c "import json,sys; sys.exit(0 if any(r['listener']=='gateway' and r['method']=='POST' and r['path']=='/api/assistant-mailbox/self-test' and 'device_bearer' in r['auth'] for r in json.load(open('vendor/cm041/assistant_api/hub_contract.yaml'))['routes']) else 1)" \
    && ok "the contract carries POST /api/assistant-mailbox/self-test as device_bearer" || bad "the mailbox self-test route is not in the contract as device_bearer"
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

# RED: a gateway whose mailbox self-test echoes the app password.
start_fake mbleak 'POST /api/assistant-mailbox/self-test SYN_MAILBOX'; pm="$FAKE_PORT"
rc="$(run_arm "http://127.0.0.1:$pm")"
[ "$rc" -eq 1 ] && /usr/bin/grep -q 'FAIL   POST /api/assistant-mailbox/self-test on http://127.0.0.1.*assistant_mailbox_password' "$work/out" \
    && ok "the mailbox app password echoed by the self-test route: FAIL naming the route and the secret" || { bad "mailbox-leak arm rc=$rc"; tail -5 "$work/out"; }
no_values "mailbox-leak arm"

start_fake fp 'POST /api/v1/invites/mint SYN_FPRINT'; pf="$FAKE_PORT"
rc="$(run_arm "http://127.0.0.1:$pf")"
[ "$rc" -eq 1 ] && /usr/bin/grep -q 'FAIL   POST /api/v1/invites/mint on http://127.0.0.1.*device_fingerprint' "$work/out" \
    && ok "the fingerprint echoed on POST /api/v1/invites/mint: FAIL naming the route and the secret label" || { bad "invite fingerprint arm rc=$rc"; tail -5 "$work/out"; }
no_values "invite fingerprint arm"

start_fake clean none; pc="$FAKE_PORT"
rc="$(run_arm "http://127.0.0.1:$pc")"
[ "$rc" -eq 0 ] && ok "a clean fake gateway: PASS" || { bad "clean arm rc=$rc"; tail -5 "$work/out"; }
/usr/bin/grep -qE "^  ok     [0-9]+ requests" "$work/out" && req="$(/usr/bin/grep -oE '^  ok     [0-9]+' "$work/out" | tail -1 | tr -dc 0-9)" || req=0
[ "$req" -gt "$ngw" ] && ok "the clean arm made $req requests over $ngw contract gateway routes" || bad "the clean arm made $req requests for $ngw routes"
no_values "clean arm"
/usr/bin/grep -q 'assistant mailbox: enabled, its password is swept' "$work/out" \
    && ok "the clean arm swept the mailbox app password" || bad "the mailbox app password was not swept"
/usr/bin/grep -q 'find-generic-password' "$FAKE_SECURITY_LOG" && ! /usr/bin/grep -q UNSUPPORTED "$FAKE_SECURITY_LOG" \
    && ok "the Keychain read went to the stand-in" || bad "no stand-in Keychain read recorded"

# No outward mail: point the fixture's mailbox at a real provider host.
cp "$work/ostler/assistant-config/config.toml" "$work/cfg.loopback"
sed 's/^imap_host = .*/imap_host = "imap.mail.me.com"/; s/^smtp_host = .*/smtp_host = "smtp.mail.me.com"/' "$work/cfg.loopback" > "$work/ostler/assistant-config/config.toml"
chmod 600 "$work/ostler/assistant-config/config.toml"
rc="$(run_arm "http://127.0.0.1:$pc")"
[ "$rc" -eq 0 ] && /usr/bin/grep -q 'CANNOT POST /api/assistant-mailbox/self-test on .*mailbox host is not loopback; self-test would send real mail' "$work/out" \
    && ok "a real mailbox host: the self-test is not POSTed, CANNOT names why, the rest still PASSes" || { bad "real-host arm rc=$rc"; tail -5 "$work/out"; }
no_values "real-host arm"
QUAL='^VERDICT: PASS \(mailbox self-test CANNOT-RUN: host not loopback\) -- '
/usr/bin/grep -qE "$QUAL" "$work/out" && [ "$(/usr/bin/grep -c '^VERDICT: ' "$work/out")" -eq 1 ] \
    && ok "a real mailbox host: the verdict line names the skipped self-test" || { bad "verdict not qualified: $(/usr/bin/grep '^VERDICT' "$work/out")"; }
# Mutant: drop the qualifier; the same arm must be caught.
qm="$work/qmut"; mkdir -p "$qm/scripts/box_walk_probes/lib" "$qm/scripts/box_walk_probes/probes" "$qm/vendor/cm041/assistant_api"
cp scripts/box_walk_probes/lib/probe.sh scripts/box_walk_probes/lib/stored_secret_sweep.py "$qm/scripts/box_walk_probes/lib/"
cp vendor/cm041/assistant_api/hub_contract.yaml "$qm/vendor/cm041/assistant_api/"
sed 's/^            if grep -q .*CANNOT POST \/api\/assistant-mailbox\/self-test.*then$/            if false; then/' "$PROBE" > "$qm/scripts/box_walk_probes/probes/gateway_never_serves_a_stored_secret.sh"
if cmp -s "$PROBE" "$qm/scripts/box_walk_probes/probes/gateway_never_serves_a_stored_secret.sh"; then
    bad "qualifier mutant did not apply"
else
    OSTLER_DIR="$work/ostler" OSTLER_SECRET_SWEEP_BASES="http://127.0.0.1:$pc" bash "$qm/scripts/box_walk_probes/probes/gateway_never_serves_a_stored_secret.sh" > "$work/qout" 2>&1
    ! /usr/bin/grep -qE "$QUAL" "$work/qout" && /usr/bin/grep -q '^VERDICT: PASS -- ' "$work/qout" \
        && ok "mutant (qualifier dropped) prints a bare PASS, which the check above rejects" || bad "qualifier mutant not distinguishable"
fi
cp "$work/cfg.loopback" "$work/ostler/assistant-config/config.toml"
! /usr/bin/grep -q 'mailbox host is not loopback' <(OSTLER_DIR="$work/ostler" OSTLER_SECRET_SWEEP_BASES="http://127.0.0.1:$pc" bash "$PROBE" 2>&1) \
    && ok "loopback mailbox hosts: no CANNOT for the self-test (it is POSTed)" || bad "loopback hosts still skipped the self-test"
OSTLER_DIR="$work/ostler" OSTLER_SECRET_SWEEP_BASES="http://127.0.0.1:$pc" bash "$PROBE" > "$work/out" 2>&1
/usr/bin/grep -q '^VERDICT: PASS -- ' "$work/out" && ! /usr/bin/grep -q '^VERDICT: PASS (' "$work/out" \
    && ok "loopback mailbox hosts: a plain PASS, no qualifier" || bad "loopback verdict: $(/usr/bin/grep '^VERDICT' "$work/out")"

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
