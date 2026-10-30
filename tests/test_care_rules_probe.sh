#!/usr/bin/env bash
# care_rules_present_in_workspace_agents_md: four outcomes against fixture
# homes (HOME=$(mktemp -d); the probe reads $HOME/.ostler/assistant-config/
# workspace/AGENTS.md through the local box_run path), plus a transport
# failure through a stub ssh, plus the mutant (probe forced to PASS) going red.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
PROBE="${CARE_PROBE_UNDER_TEST:-scripts/box_walk_probes/probes/care_rules_present_in_workspace_agents_md.sh}"
fails=0; total=0
ok()  { total=$((total + 1)); echo "  ok    $1"; }
bad() { total=$((total + 1)); fails=$((fails + 1)); echo "  FAIL  $1"; }
TMP="$(mktemp -d)"; trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

mkhome() { # $1 = name; prints the workspace dir
    local ws="$TMP/$1/.ostler/assistant-config/workspace"; mkdir -p "$ws"; echo "$ws"
}
GOOD_BODY='# Care rules

## 1. If the person might hurt themselves
- Always include this, with the number exactly as written: Samaritans, free, 24 hours: call 116 123. If they are in immediate danger: call 999 (or 112).'
ZZ_BODY='# Care rules
- Always include this, with the number exactly as written: If you can, contact a local crisis line or someone you trust. If they are in immediate danger: call your local emergency number.'

run() { # $1 = probe path, $2 = home; echoes verdict word, returns rc via global
    local out
    out="$(env -u OSTLER_BOX_HOST HOME="$2" bash "$1" 2>&1)"; RC=$?
    VERDICT="$(printf '%s\n' "$out" | sed -n 's/^VERDICT: \([A-Z-]*\).*/\1/p' | head -1)"
    OUT="$out"
}
expect() { # $1 label, $2 probe, $3 home, $4 verdict, $5 rc
    run "$2" "$3"
    if [ "$VERDICT" = "$4" ] && [ "$RC" -eq "$5" ]; then ok "$1 -> $4 (rc $RC)"
    else bad "$1: wanted $4/$5, got ${VERDICT:-none}/$RC"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi
}

ws="$(mkhome present)";   printf '%s\n' "$GOOD_BODY" > "$ws/AGENTS.md"
expect "present with a real helpline" "$PROBE" "$TMP/present" PASS 0
ws="$(mkhome generic)";   printf '%s\n' "$ZZ_BODY" > "$ws/AGENTS.md"
expect "present with the generic ZZ line" "$PROBE" "$TMP/generic" PASS 0
mkhome missing >/dev/null
expect "file missing" "$PROBE" "$TMP/missing" FAIL 1
ws="$(mkhome noheading)"; printf '%s\n' "$GOOD_BODY" | sed '1d' > "$ws/AGENTS.md"
expect "heading missing" "$PROBE" "$TMP/noheading" FAIL 1
ws="$(mkhome noline)";    printf '# Care rules\nnothing else\n' > "$ws/AGENTS.md"
expect "helpline sentence missing" "$PROBE" "$TMP/noline" FAIL 1
ws="$(mkhome placeholder)"; printf '# Care rules\n- Always include this, with the number exactly as written: {{HELPLINE_LINE}} If they are in immediate danger: x\n' > "$ws/AGENTS.md"
expect "unresolved placeholder" "$PROBE" "$TMP/placeholder" FAIL 1

ws="$(mkhome unreadable)"; printf '%s\n' "$GOOD_BODY" > "$ws/AGENTS.md"; chmod 000 "$ws/AGENTS.md"
if [ -r "$ws/AGENTS.md" ]; then
    echo "  CANNOT-RUN  unreadable fixture: this user can read a mode-000 file (root?)"; total=$((total + 1)); fails=$((fails + 1))
else
    expect "unreadable" "$PROBE" "$TMP/unreadable" CANNOT-RUN 78
fi

# Transport failure: stub ssh exits 255 and prints nothing.
mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 255\n' > "$TMP/bin/ssh"; chmod +x "$TMP/bin/ssh"
out="$(PATH="$TMP/bin:$PATH" OSTLER_BOX_HOST=box.invalid HOME="$TMP/present" bash "$PROBE" 2>&1)"; rc=$?
[ "$rc" -eq 78 ] && printf '%s' "$out" | grep -q 'VERDICT: CANNOT-RUN' \
    && ok "ssh failure -> CANNOT-RUN (rc 78)" || bad "ssh failure gave rc $rc"

bash "$PROBE" --self-test >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "--self-test returns FAIL (1), its negative control went red" || bad "--self-test returned $rc"

# Mutant: grade() always passes. Every FAIL and CANNOT-RUN case above must now be wrong.
MUT="$TMP/mutant.sh"
sed 's/^grade() {/grade() { echo mutant; return 0; }\n_grade_orig() {/' "$PROBE" \
    | sed "s#\$(dirname \"\$0\")/../lib/probe.sh#$PWD/scripts/box_walk_probes/lib/probe.sh#" > "$MUT"
cmp -s "$PROBE" "$MUT" && bad "mutant is identical to the probe (sed did not apply)"
run "$MUT" "$TMP/present"
[ "$VERDICT" = "PASS" ] && ok "control: mutant still passes a good file" || bad "mutant broken on the good file: $VERDICT"
for h in missing noheading noline placeholder unreadable; do
    run "$MUT" "$TMP/$h"
    [ "$VERDICT" = "PASS" ] && ok "mutant PASSES the $h fixture, so the real test above would be red" || bad "mutant did not pass $h (got $VERDICT)"
done
echo "== $((total - fails)) pass / $fails fail / $total total =="
[ "$fails" -eq 0 ]
