#!/usr/bin/env bash
# v1.0.112 walk: harness faults graded as product FAIL. Each is now CANNOT-RUN,
# and each keeps FAIL where the product is really broken.
#   pair_endpoints_refuse_off_window  judge crash / curl "000" status -> CANNOT
#   todos_reach_reminders             unmeasured Ostler list, no Reminders grant -> CANNOT
#   reply_debt_is_answered            imessage_not_connected, no consent -> CANNOT
#   db_key_reaches_every_service      absent coach db, ssh-harness refusal -> CANNOT
# Negative controls (FAIL stays FAIL) live in each judge's --self-test; section 3
# MUTATES each fix and demands that self-test go red.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
L=scripts/box_walk_probes/lib
fails=0
ok() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fails=$((fails + 1)); }

# 1. every judge self-test passes (its negative controls included)
for m in pair_offwindow todo_reminders_probe wow_moments db_key_probe; do
    python3 "$L/$m.py" --self-test >/dev/null 2>&1 && ok "$m --self-test passes" || bad "$m --self-test"
done

# 2. real behaviour through the real entry points
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '{"source": "lan", "endpoints": [{"path": "/pair", "status": 000, "body": ""}]}' > "$tmp/bad.json"
python3 "$L/pair_offwindow.py" judge "$tmp/bad.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 78 ] && ok "pair judge: an unparseable capture is CANNOT-RUN (78)" || bad "pair judge: unparseable capture exit $rc, want 78"
printf '{"source": "lan", "log_readable": true, "log_hits": [], "endpoints": [{"path": "/pair", "status": 200, "body": "{}"}]}' > "$tmp/real.json"
python3 "$L/pair_offwindow.py" judge "$tmp/real.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "pair judge control: a real 200 off-window is still FAIL (1)" || bad "pair judge control: exit $rc, want 1"
# the probe's status normalisation: raw curl "000" breaks JSON, normalised does not
python3 -c 'import json; json.loads("{\"s\": 000}")' 2>/dev/null && bad "control: 000 should not parse" || ok "control: a raw 000 status is invalid JSON (the v1.0.112 crash)"
st="000"; st="$(printf '%s' "$st" | tr -dc '0-9')"; st=$((10#${st:-0}))
python3 -c "import json; json.loads('{\"s\": $st}')" 2>/dev/null && ok "normalised 000 parses" || bad "normalised 000 does not parse"
grep -q '10#\${st:-0}' scripts/box_walk_probes/probes/pair_endpoints_refuse_off_window.sh && ok "the probe applies the normalisation" || bad "the probe does not normalise the status"

# db_key install facts, read from a fake box home
ifacts() { OSTLER_DIR="$1" python3 -c "
import sys, json; sys.path.insert(0, '$L'); import db_key_probe as d; print(json.dumps(d.install_facts()))"; }
mk() {  # mk <dir> <refusal 0|1> <marker-start-offset-secs|none> ; header time is fixed at now
    mkdir -p "$1/logs"
    hdr="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    { echo "=== install.sh run $hdr (x) ==="; [ "$2" = 1 ] && echo "CANNOT-RUN no database key resolved; refusing"; } > "$1/logs/install.log"
    [ "$3" = none ] || printf 'ttywalk %s\n' "$(( $(date +%s) - $3 ))" > "$1/.install-harness"
}
mk "$tmp/h1" 1 60;     ifacts "$tmp/h1" | grep -q '"key_refusal": true, "via": "ssh-harness"' && ok "refusal + fresh harness marker -> ssh-harness" || bad "h1: $(ifacts "$tmp/h1")"
mk "$tmp/h2" 1 none;   ifacts "$tmp/h2" | grep -q '"via": "console-or-unknown"' && ok "control: refusal, no marker -> console-or-unknown" || bad "h2: $(ifacts "$tmp/h2")"
mk "$tmp/h3" 1 40000;  ifacts "$tmp/h3" | grep -q '"via": "console-or-unknown"' && ok "control: marker 11h older than the install -> console-or-unknown" || bad "h3: $(ifacts "$tmp/h3")"
mk "$tmp/h4" 0 60;     ifacts "$tmp/h4" | grep -q '"key_refusal": false' && ok "control: no refusal text -> key_refusal false" || bad "h4: $(ifacts "$tmp/h4")"
mkdir -p "$tmp/h5";    ifacts "$tmp/h5" | grep -q '"key_refusal": null' && ok "control: no install.log -> key_refusal null (not false)" || bad "h5: $(ifacts "$tmp/h5")"
grep -q 'install-harness' scripts/ttywalk.sh && ok "ttywalk.sh writes the harness marker the probe reads" || bad "ttywalk.sh does not write the marker"

# 3. mutants: break each fix, its self-test must go red
mutant() {  # mutant <lib> <sed-expr> <label>
    cp -R "$L" "$tmp/lib.$1"; sed -i.bak "$2" "$tmp/lib.$1/$1.py"
    if cmp -s "$tmp/lib.$1/$1.py" "$L/$1.py"; then bad "mutant did not apply: $3"; return; fi
    python3 "$tmp/lib.$1/$1.py" --self-test >/dev/null 2>&1 && bad "mutant SURVIVED: $3" || ok "mutant caught: $3"
}
mutant pair_offwindow 's/except Exception as exc:/except ZeroDivisionError as exc:/' "judge crash no longer caught"
mutant todo_reminders_probe 's/in ("absent", "unreadable"):$/in ():/' "no-grant Ostler list no longer CANNOT-RUN"
mutant wow_moments 's/if g.get("consent") in ("absent", "unreadable"):/if True:/' "consent accepted but not connected graded CANNOT"
mutant db_key_probe 's/if refused and via == "ssh-harness":/if refused:/' "console refusal graded CANNOT"
mutant db_key_probe 's/if refused and via == "ssh-harness":/if False:/' "ssh-harness refusal no longer CANNOT"

[ "$fails" -eq 0 ] && echo "PASS" || { echo "$fails FAILED"; exit 1; }
