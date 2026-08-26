#!/bin/bash
set -uo pipefail
c_grn=""; c_red=""; c_off=""; GREEN=0; RED=0; RESULTS=()
S=$(grep -n '^_interpreter_died()' scripts/run_all_cut_gates.sh | cut -d: -f1)
E=$(awk -v s="$S" 'NR>s && /^}$/{c++; if(c==2){print NR; exit}}' scripts/run_all_cut_gates.sh)
eval "$(sed -n "${S},${E}p" scripts/run_all_cut_gates.sh)"
F=0; ok(){ printf '  ok    %s\n' "$1"; }; bad(){ printf '  FAIL  %s\n' "$1"; F=1; }

# SPECIMEN: the REAL pre-fix gate, run under the REAL 3.2, on the REAL BOM.
git show origin/main:scripts/verify_must_contain.sh > /tmp/spec.sh
run "MUST_CONTAIN BOM" "every promised capability landed" /bin/bash /tmp/spec.sh cuts/v1.0.47/MUST_CONTAIN.tsv
[ "$RED" -eq 1 ] && ok "SPECIMEN: the real pre-fix gate (exits 0 after dying) is now RED" \
                 || bad "SPECIMEN NOT CAUGHT -- red=$RED green=$GREEN. This is the actual defect."

# POSITIVE CONTROL: a healthy gate must still be GREEN, or this just reds everything.
GREEN=0; RED=0
run "healthy" "a clean gate" /bin/bash -c 'echo "all good"; exit 0'
[ "$GREEN" -eq 1 ] && ok "CONTROL: a clean gate is still GREEN" || bad "CONTROL FAILED: clean gate went RED"

# FALSE-POSITIVE CONTROL: a gate legitimately printing "not found" must stay GREEN.
GREEN=0; RED=0
run "findingy" "reports a finding" /bin/bash -c 'echo "image not found in registry"; echo "error: none"; exit 0'
[ "$GREEN" -eq 1 ] && ok "CONTROL: 'not found'/'error' in a gate's OWN output does not trip it" \
                   || bad "FALSE POSITIVE: flagged a gate's legitimate output"

# A gate that dies AND exits non-zero was already RED; must not double-count.
GREEN=0; RED=0
run "loud" "dies loudly" /bin/bash -c 'echo "x: line 4: boom"; exit 3'
[ "$RED" -eq 1 ] && ok "a gate that dies AND exits non-zero is RED exactly once" || bad "miscounted: red=$RED"
echo; [ "$F" -eq 0 ] && echo "PASS -- a gate that exits 0 after an interpreter error is now RED." || echo "FAIL"
exit $F
