#!/usr/bin/env bash
# Photos events are read by default; photo faces never are (#2364).
#
# The installer asks for Photos access up front "so the Hub can read photo
# metadata", then did not read it on a default install: on the v1.0.102 walk
# a Recommended install ingested 0 of 1,298 photo events. This reads the
# preset lines install.sh actually assigns and the customise default.
# EXIT CODES   0 all pass   1 a check failed   2 CANNOT-RUN
set -uo pipefail
SRC="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install.sh}"
[ -r "$SRC" ] || { echo "CANNOT-RUN: no install.sh at $SRC" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
has() { case ",$1," in *",$2,"*) return 0 ;; esac; return 1; }
REC="$(grep -m1 -E '^RECOMMENDED="' "$SRC" | sed -E 's/^RECOMMENDED="([^"]*)".*/\1/')"
[ -n "$REC" ] || { echo "CANNOT-RUN: no RECOMMENDED= line in $SRC" >&2; exit 2; }
has "$REC" safari_history && ok "control: the parsed preset holds safari_history" \
    || { echo "CANNOT-RUN: parsed RECOMMENDED does not look like the preset: $REC" >&2; exit 2; }
has "$REC" photos_metadata && ok "Recommended reads Photos events" || bad "Recommended does not read Photos events: $REC"
has "$REC" photos_faces && bad "Recommended enables photo FACES without a tick" || ok "Recommended never enables photo faces"
grep -qE '_ask_source "photos_metadata" +"[^"]*" Y$' "$SRC" \
    && ok "Customise defaults Photos events to on" || bad "Customise defaults Photos events to off"
echo; echo "== ${PASS} pass / ${FAIL} fail =="
[ "$FAIL" -eq 0 ]
