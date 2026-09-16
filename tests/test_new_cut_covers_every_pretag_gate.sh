#!/usr/bin/env bash
# test_new_cut_covers_every_pretag_gate.sh
#
# scripts/new_cut.sh HAND-MIRRORS A LIST THAT LIVES IN cut.yml, so it drifts,
# and every drift has been discovered by SPENDING A TAG:
#
#   v1.0.76 tag 1  cut-manifests/<v>.yaml missing, and the installer still
#                  stamped 1.0.75/7500. Both absent from new_cut.sh. Added by
#                  #1825 -- BY HAND.
#   v1.0.77 tag 1  verify_bom_rows_are_in_the_pin.sh, present in cut.yml,
#                  absent here. Discovered the same way, WITHIN THE DAY of the
#                  fix that was supposed to close this class.
#
# So the remedy is not a more careful list. Two careful lists failed. This test
# DERIVES cut.yml's pre-tag gates and requires new_cut.sh to invoke each one,
# so the next drift fails CI instead of a tag.
#
# WHY A SKIP LIST EXISTS AND IS NAMED. Some cut.yml gates cannot run before the
# tag because they need the built artefact. Those are listed explicitly with
# the reason, so "not covered" always means either COVERED or DELIBERATELY
# EXEMPT -- never silently forgotten.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
NC="scripts/new_cut.sh"; CY=".github/workflows/cut.yml"
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
for f in "$NC" "$CY"; do [ -r "$f" ] || { printf 'CANNOT-RUN: %s unreadable\n' "$f" >&2; exit 3; }; done

# POST-BUILD ONLY: these need an artefact that does not exist until after the
# tag fires the build, so new_cut.sh cannot run them. Named, with the reason.
needs_artefact="stage_and_verify_dmg.sh walk_dmg.sh verify_dmg_delivers_fixes.sh publish_release.sh test_artefact_content_matches_the_tag.sh verify_cut_provenance.sh provenance_gate.sh dry_run_cut_checks.sh"

GATELIST="$(grep -oE 'bash (scripts|tests|bin)/[a-z_0-9]+\.sh' "$CY" | awk '{print $2}' | sed 's#.*/##' | sort -u)"
n="$(printf '%s\n' "$GATELIST" | grep -c '.')"
if [ "$n" -lt 5 ]; then
    printf 'CANNOT-RUN: parsed %s gate(s) from %s, expected >=5. The parse is wrong, so a pass is meaningless.\n' "$n" "$CY" >&2
    exit 3
fi
ok "denominator: ${n} gate invocation(s) parsed from cut.yml"

missing=0
while IFS= read -r g; do
    [ -n "$g" ] || continue
    case " $needs_artefact " in *" $g "*) continue ;; esac
    if [ "$(grep -cF "$g" "$NC")" -gt 0 ]; then
        ok "new_cut.sh invokes ${g}"
    else
        bad "cut.yml runs ${g} at preflight and new_cut.sh does NOT -- new_cut.sh can print ALL GREEN on a cut that preflight will refuse. That is how the v1.0.76 and v1.0.77 tags were spent."
        missing=$((missing+1))
    fi
done <<GATES
$GATELIST
GATES
[ "$missing" -eq 0 ] && ok "no pre-tag gate in cut.yml is missing from new_cut.sh"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
