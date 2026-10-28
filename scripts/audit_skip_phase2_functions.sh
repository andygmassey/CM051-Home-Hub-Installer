#!/bin/bash
# Lists functions defined inside the `if [[ "$SKIP_PHASE2" == false ]]` question
# block of install.sh and any call site outside that block. Exit 1 if a function
# defined only inside the block is called outside it.
# Usage: audit_skip_phase2_functions.sh [install.sh]
set -u
f="${1:-$(dirname "$0")/../install.sh}"
start="$(awk '/^if \[\[ "\$SKIP_PHASE2" == false \]\]; then/ {print NR; exit}' "$f")"
end="$(awk -v s="$start" 'NR>s && /^fi  # end of SKIP_PHASE2 check/ {print NR; exit}' "$f")"
if [[ -z "$start" || -z "$end" ]]; then echo "CANNOT-RUN: block bounds not found" >&2; exit 2; fi
echo "block: ${start}-${end}"
defre='^[[:space:]]*(function[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(\)[[:space:]]*\{?'
bad=0; n=0
while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    n=$((n+1))
    # defined outside the block too? then not a hazard
    outdef="$(awk -v s="$start" -v e="$end" -v n="$name" '(NR<s||NR>e) && $0 ~ "^[[:space:]]*(function[[:space:]]+)?" n "[[:space:]]*\\(\\)" {c++} END{print c+0}' "$f")"
    calls="$(awk -v s="$start" -v e="$end" -v n="$name" '(NR<s||NR>e) && $0 !~ /^[[:space:]]*#/ && $0 !~ "^[[:space:]]*(function[[:space:]]+)?" n "[[:space:]]*\\(\\)" && $0 ~ "(^|[^A-Za-z0-9_-])" n "([^A-Za-z0-9_-]|$)" {printf "%s ", NR}' "$f")"
    if [[ -n "$calls" ]]; then
        if [[ "$outdef" -eq 0 ]]; then echo "HAZARD $name: defined only inside, called outside at lines: $calls"; bad=$((bad+1))
        else echo "ok     $name: also defined outside ($outdef), calls: $calls"; fi
    fi
done < <(awk -v s="$start" -v e="$end" -v re="$defre" 'NR>=s && NR<=e && match($0, /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/) {x=substr($0,RSTART,RLENGTH); sub(/^[[:space:]]*(function[[:space:]]+)?/,"",x); sub(/[[:space:]]*\(\)$/,"",x); print x}' "$f" | sort -u)
echo "functions defined inside block: ${n}; hazards: ${bad}"
[[ "$bad" -eq 0 ]]
