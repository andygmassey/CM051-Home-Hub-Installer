#!/bin/bash
# A function called outside install.sh's `if [[ "$SKIP_PHASE2" == false ]]`
# question block must not be defined only inside it. On a reuse-settings re-run
# (SKIP_PHASE2=true) the block is skipped, the function never exists, and
# `set -e` aborts with "command not found" (ERR-99-INSTALL-ABORT; CM051 #2673
# defined _ostler_existing_email_block inside the block, called it from reuse).
#
# 1. generic guard: scripts/audit_skip_phase2_functions.sh finds 0 hazards.
# 2. targeted: build the script a reuse run sees (install.sh with the block
#    deleted), source the email helpers from it, require type -t == function and
#    that the lifted block is the real one.
# 3. mutant: put the definition back inside the block, both must go RED.
# Runs under /bin/bash 3.2. No network, no HOME writes.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
audit="${here}/scripts/audit_skip_phase2_functions.sh"
INSTALL="${1:-${here}/install.sh}"
fails=0
ok()  { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails+1)); }

names="_ostler_existing_email_block _email_password_store _email_block_extract_password _email_allowlist_toml_items"

reuse_view() { # $1 = install.sh -> stdout: the file as a SKIP_PHASE2=true run sees it
    local s e
    s="$(awk '/^if \[\[ "\$SKIP_PHASE2" == false \]\]; then/ {print NR; exit}' "$1")"
    e="$(awk -v s="$s" 'NR>s && /^fi  # end of SKIP_PHASE2 check/ {print NR; exit}' "$1")"
    [ -n "$s" ] && [ -n "$e" ] || { echo "CANNOT-RUN: block bounds" >&2; return 2; }
    awk -v s="$s" -v e="$e" 'NR<s || NR>e' "$1"
}

check() { # $1 = install.sh, $2 = label ; returns number of failures
    local f="$1" label="$2" n=0 tmp view name t out
    if bash "$audit" "$f" >/dev/null 2>&1; then ok "${label}: generic guard, 0 hazards"
    else bad "${label}: generic guard found hazards: $(bash "$audit" "$f" 2>&1 | grep HAZARD | sed 's/:.*//' | tr '\n' ' ')"; fi
    tmp="$(mktemp -d)"; view="${tmp}/view.sh"
    reuse_view "$f" > "$view" || { bad "${label}: CANNOT-RUN reuse view"; rm -rf "$tmp"; return; }
    for name in $names; do
        # extract just the definition from the reuse view, source it, ask bash
        awk -v n="$name" '$0 ~ "^"n"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$view" > "${tmp}/${name}.sh"
        t="$(HOME="$tmp" bash -c ". '${tmp}/${name}.sh' 2>/dev/null; type -t ${name}" 2>/dev/null)"
        if [ "$t" = function ]; then ok "${label}: ${name} resolves on the reuse path"
        else bad "${label}: ${name} NOT defined on the reuse path (type -t='${t}')"; fi
    done
    # behaviour: the call the reuse branch makes returns the block, verbatim
    printf '%s\n' '[channels.other]' 'x = 1' '[channels.email]' 'host = "mail.example.com"' '[next]' 'y = 2' > "${tmp}/cfg.toml"
    out="$(HOME="$tmp" bash -c ". '${tmp}/_ostler_existing_email_block.sh' 2>/dev/null; _ostler_existing_email_block '${tmp}/cfg.toml'" 2>/dev/null)"
    if [ "$out" = "$(printf '[channels.email]\nhost = "mail.example.com"')" ]; then ok "${label}: reuse call lifts the email block"
    else bad "${label}: reuse call returned '${out}'"; fi
    rm -rf "$tmp"
}

check "$INSTALL" "install.sh"

# mutant: move the definition back inside the block (just after its opening if)
mut="$(mktemp -d)/install.sh"
awk '
  /^_ostler_existing_email_block\(\) \{/ {grab=1}
  grab {held = held $0 "\n"; if ($0 ~ /^}/) grab=0; next}
  {lines[++n]=$0}
  END {
    for (i=1;i<=n;i++) { print lines[i]; if (lines[i] ~ /^if \[\[ "\$SKIP_PHASE2" == false \]\]; then/ && !done) { printf "%s", held; done=1 } }
  }' "$INSTALL" > "$mut"
if cmp -s "$mut" "$INSTALL"; then bad "mutant: identical to install.sh, mutation did not apply"
else
    before=$fails
    check "$mut" "MUTANT" >/dev/null
    if [ "$fails" -gt "$before" ]; then fails=$before; ok "mutant (definition moved back in) is RED"
    else bad "mutant stayed green: the test cannot fail"; fi
fi
rm -rf "$(dirname "$mut")"

echo "fails=${fails}"
[ "$fails" -eq 0 ]
