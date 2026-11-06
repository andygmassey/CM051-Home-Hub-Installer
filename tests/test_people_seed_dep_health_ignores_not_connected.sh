#!/bin/bash
# C4 of people_seed_and_retrieval: judge_dep_health must FAIL a dead store the
# legs use (oxigraph/qdrant/ollama) and must NOT fail on gws not_connected.
# Runs the REAL function, extracted from the probe. Has a mutant that ignores
# every ok:false; the test must go red on it.
set -u
cd "$(dirname "$0")/.." || exit 2
P=scripts/box_walk_probes/probes/people_seed_and_retrieval.sh
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
extract() { sed -n '/^judge_dep_health() {/,/^}/p' "$1"; }
extract "$P" > "$T/real.sh"
[ -s "$T/real.sh" ] || { echo "CANNOT-RUN: judge_dep_health not found"; exit 78; }
# Mutant: judge nothing (REQUIRED empty).
sed 's/^REQUIRED = .*/REQUIRED = ()/' "$T/real.sh" > "$T/mutant.sh"
cmp -s "$T/real.sh" "$T/mutant.sh" && { echo "CANNOT-RUN: mutant did not apply"; exit 78; }

OK='{"checks":{"oxigraph":{"ok":true},"qdrant":{"ok":true},"ollama":{"ok":true},"gws":{"ok":false,"not_connected":true}}}'
RED='{"checks":{"oxigraph":{"ok":false},"qdrant":{"ok":true},"ollama":{"ok":true},"gws":{"ok":false,"not_connected":true}}}'
MISSING='{"checks":{"qdrant":{"ok":true},"ollama":{"ok":true}}}'
printf '%s' "$OK" > "$T/ok.json"; printf '%s' "$RED" > "$T/red.json"; printf '%s' "$MISSING" > "$T/missing.json"
run() { ( . "$1"; judge_dep_health "$2" ); }
fails=0
chk() { if [ "$2" = "$3" ]; then echo "ok   $1: $2"; else echo "FAIL $1: got '$2' want '$3'"; fails=$((fails+1)); fi; }

chk "gws not_connected passes, named" "$(run "$T/real.sh" "$T/ok.json")" "ok:3;ignored:gws(not_connected)"
chk "oxigraph ok:false is down (red control)" "$(run "$T/real.sh" "$T/red.json")" "down:oxigraph"
chk "required store absent is down" "$(run "$T/real.sh" "$T/missing.json")" "down:oxigraph"
# Mutant must be caught: it must NOT report the red fixture as down.
m="$(run "$T/mutant.sh" "$T/red.json")"
case "$m" in down:*) echo "FAIL mutant still reports down: the red control cannot discriminate"; fails=$((fails+1));; *) echo "ok   mutant ignoring all ok:false goes red on the control ($m)";; esac
[ "$fails" -eq 0 ] || exit 1
echo "PASS"
