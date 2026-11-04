#!/usr/bin/env bash
# tests/test_telemetry_egress_off.sh
# v1.0.124 egress audit D1 + D3. RED on the pre-fix install.sh, GREEN after, with mutants.
#   D1: every Qdrant launch path in install.sh sets QDRANT__TELEMETRY_DISABLED "true" (compose has ONE qdrant service)
#   D1: the stripping sed for the API key line must not remove the telemetry line
#   D3: install.sh exports HOMEBREW_NO_ANALYTICS=1 BEFORE the first brew invocation
#   probe: third_party_telemetry_off self-test behaves and its judge mutants go RED
# Bash 3.2. Exit 0 pass, 1 fail.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${INSTALL_SH:-$REPO/install.sh}"
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
echo "test_telemetry_egress_off"

check_qdrant() { # $1 = install.sh path ; prints nothing, rc 0 when every qdrant service block disables telemetry
    python3 -I - "$1" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
blocks = re.findall(r"^  qdrant:\n(.*?)(?=^  [a-z0-9_-]+:\n)", t, re.S | re.M)
n = 0
for b in blocks:
    if "ghcr.io/creativemachines-ai/qdrant@" not in b:
        continue
    n += 1
    if not re.search(r'^\s+QDRANT__TELEMETRY_DISABLED: "true"', b, re.M):
        sys.exit(1)
sys.exit(0 if n >= 1 else 2)
PY
}
check_brew() { # rc 0 when the export precedes the first real brew call
    python3 -I - "$1" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
exp = next((i for i, l in enumerate(lines) if re.match(r"^[^#]*\bexport HOMEBREW_NO_ANALYTICS=1", l)), None)
first = next((i for i, l in enumerate(lines) if re.match(r"^\s*(if ! )?brew (install|upgrade|update|tap)\b", l)), None)
sys.exit(0 if exp is not None and first is not None and exp < first else 1)
PY
}
check_strip() { # the API-key strip sed must target only the API_KEY line
    /usr/bin/grep -F "sed -i.bak '/QDRANT__SERVICE__API_KEY:/d'" "$1" >/dev/null
}

check_qdrant "$INSTALL"; rc=$?
[ "$rc" -eq 0 ] && ok "D1 the qdrant service sets QDRANT__TELEMETRY_DISABLED \"true\"" || bad "D1 qdrant service lacks telemetry-off (rc=$rc; 2 means no qdrant block found)"
check_strip "$INSTALL" && ok "D1 the API-key strip sed is key-specific (cannot drop the telemetry line)" || bad "D1 API-key strip sed changed shape"
check_brew "$INSTALL" && ok "D3 HOMEBREW_NO_ANALYTICS=1 is exported before the first brew call" || bad "D3 no HOMEBREW_NO_ANALYTICS=1 export before the first brew call"

# executed, not just read: apply the strip to the real compose block and confirm telemetry survives
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
python3 -I - "$INSTALL" "$W/c.yml" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r"^  qdrant:\n.*?(?=^  [a-z0-9_-]+:\n)", t, re.S | re.M)
open(sys.argv[2], "w").write("services:\n" + m.group(0))
PY
sed -i.bak '/QDRANT__SERVICE__API_KEY:/d' "$W/c.yml"
/usr/bin/grep -q 'QDRANT__TELEMETRY_DISABLED: "true"' "$W/c.yml" && ! /usr/bin/grep -q 'SERVICE__API_KEY:' "$W/c.yml" && ok "D1 after the opt-out strip, telemetry stays off and the key line is gone" || bad "D1 strip result wrong"

# mutants
mut() { # label, sed expr, checker
    cp "$INSTALL" "$W/m.sh"; sed -E "$2" "$INSTALL" > "$W/m.sh"
    if cmp -s "$INSTALL" "$W/m.sh"; then bad "mutant $1 did not change the source"; return; fi
    if "$3" "$W/m.sh"; then bad "mutant $1 SURVIVED"; else ok "mutant $1 turns the check RED"; fi
}
mut qdrant-telemetry-removed '/QDRANT__TELEMETRY_DISABLED: "true"/d' check_qdrant
mut qdrant-telemetry-false 's/QDRANT__TELEMETRY_DISABLED: "true"/QDRANT__TELEMETRY_DISABLED: "false"/' check_qdrant
mut brew-export-removed 's/; export HOMEBREW_NO_ANALYTICS=1//' check_brew
mut brew-export-wrong-value 's/export HOMEBREW_NO_ANALYTICS=1/export HOMEBREW_NO_ANALYTICS=0/' check_brew

# the Homebrew host is the one brew 7.0.9 source names, and the probe watches it
/usr/bin/grep -q '"analytics.brew.sh"' "$REPO/scripts/box_walk_probes/lib/telemetry_off.py" && ok "probe watches analytics.brew.sh" || bad "probe does not watch analytics.brew.sh"

# probe
P="$REPO/scripts/box_walk_probes"
bash "$P/probes/third_party_telemetry_off.sh" --self-test >"$W/st" 2>&1; rc=$?
[ "$rc" -eq 1 ] && /usr/bin/grep -q '^VERDICT: FAIL -- negative control behaved' "$W/st" && ok "probe self-test behaves" || bad "probe self-test rc=$rc"
python3 -I "$P/lib/telemetry_off.py" --self-test >"$W/py" 2>&1 && /usr/bin/grep -q ', 0 wrong' "$W/py" && ok "judge self-test clean" || bad "judge self-test not clean"
for e in 's/"QDRANT__TELEMETRY_DISABLED=true" in cap\["qdrant_env"\]/True/' 's/if ip in set\(cap.get\("remotes"\) or \[\]\)/if False/' 's/elif not cap.get\("control_seen"\):/elif False:/; s/if not cap.get\("control_seen"\):/if False:/'; do
    sed -E "$e" "$P/lib/telemetry_off.py" > "$W/t.py"
    if cmp -s "$P/lib/telemetry_off.py" "$W/t.py"; then bad "probe mutant did not apply: $e"; continue; fi
    python3 -I "$W/t.py" --self-test >/dev/null 2>&1 && bad "probe mutant SURVIVED: $e" || ok "probe mutant turns the judge self-test RED"
done
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
