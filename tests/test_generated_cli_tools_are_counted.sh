#!/usr/bin/env bash
# ===========================================================================
# Every CLI tool install.sh writes into ~/.ostler/bin/ must be declared in
# scripts/generated_cli_tools.tsv, with an honest answer to "does a Sparkle
# upgrade refresh it?"
#
# WHY. install.sh's upgrade branch exits at :1005/:1030/:1042 and every
# `cat > "${OSTLER_DIR}/bin/..."` site is past line 19000, so an upgrade swaps
# the daemon and the app bundle and leaves every generated shell tool frozen at
# whatever version the customer first installed. install.sh:280 states the
# mechanism for one hoisted function; it was never generalised.
#
# This does NOT fix that. It makes the set countable, so the reach of a change
# to any of these tools is a row a reviewer can read instead of a property
# someone has to rediscover.
#
# A "yes" MUST BE EARNED. Claiming a tool is refreshed on upgrade requires an
# explicit `# UPGRADE-REFRESHES: <tool>` marker in install.sh. A registry that
# can assert a reach nobody implemented is worse than no registry.
# ===========================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/install.sh"
REG="${ROOT}/scripts/generated_cli_tools.tsv"
[ -r "$SRC" ] || { printf 'CANNOT-RUN: %s is not readable.\n' "$SRC" >&2; exit 2; }
[ -r "$REG" ] || { printf 'CANNOT-RUN: %s is not readable.\n' "$REG" >&2; exit 2; }

# Every generated tool, by name, from the write sites themselves.
enumerate() {
    awk 'match($0, /cat > "\$\{OSTLER_DIR\}\/bin\/[A-Za-z0-9._-]+"/) {
             s = substr($0, RSTART, RLENGTH)
             sub(/.*\/bin\//, "", s); sub(/"$/, "", s)
             print s
         }' "$1" | sort -u
}

ACTUAL="$(enumerate "$SRC")"
n_actual="$(printf '%s' "$ACTUAL" | grep -c . || true)"

# ANTI-VACUITY. An enumeration that finds nothing must refuse, not pass. A
# renamed variable or a changed quoting style would otherwise silently turn
# this gate into a no-op that reports success.
if [ "$n_actual" -lt 1 ]; then
    printf 'CANNOT-RUN: found 0 generated bin/ tools in install.sh; the enumeration predicate no longer matches the write sites.\n' >&2
    exit 2
fi

DECLARED="$(awk -F'\t' '!/^#/ && NF>=4 {print $1}' "$REG" | sort -u)"
n_declared="$(printf '%s' "$DECLARED" | grep -c . || true)"

fails=0
report() { if [ "$2" -eq 0 ]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); fi; }

printf 'generated CLI tools are counted\n'
printf '  examined %s write site(s) in install.sh against %s registry row(s)\n' "$n_actual" "$n_declared"

UNDECLARED="$(comm -23 <(printf '%s\n' "$ACTUAL") <(printf '%s\n' "$DECLARED") | grep -v '^$' || true)"
if [ -n "$UNDECLARED" ]; then
    printf '  FAIL  %s tool(s) written by install.sh and NOT in the registry:\n' "$(printf '%s' "$UNDECLARED" | grep -c .)"
    printf '%s\n' "$UNDECLARED" | sed 's/^/          + /'
    printf '        Add a row saying whether an upgrade refreshes it. If it does not,\n'
    printf '        say so: that is the reach of every future fix to that file.\n'
    fails=$((fails + 1))
else
    report "every generated tool is declared" 0
fi

STALE="$(comm -13 <(printf '%s\n' "$ACTUAL") <(printf '%s\n' "$DECLARED") | grep -v '^$' || true)"
if [ -n "$STALE" ]; then
    printf '  FAIL  %s registry row(s) naming a tool install.sh no longer writes:\n' "$(printf '%s' "$STALE" | grep -c .)"
    printf '%s\n' "$STALE" | sed 's/^/          - /'
    fails=$((fails + 1))
else
    report "every registry row names a tool that is still written" 0
fi

# A "yes" must be earned by an explicit marker in install.sh.
YES_ROWS="$(awk -F'\t' '!/^#/ && NF>=4 && $2=="yes" {print $1}' "$REG")"
n_yes="$(printf '%s' "$YES_ROWS" | grep -c . || true)"
unearned=0
for t in $YES_ROWS; do
    grep -qF "# UPGRADE-REFRESHES: ${t}" "$SRC" || {
        printf '  FAIL  registry claims %s is refreshed on upgrade, but install.sh carries no\n' "$t"
        printf '        "# UPGRADE-REFRESHES: %s" marker to back it.\n' "$t"
        unearned=$((unearned + 1))
    }
done
[ "$unearned" -eq 0 ] && report "every refreshed_on_upgrade=yes row is backed by a marker ($n_yes row(s))" 0 || fails=$((fails + 1))

n_no="$(awk -F'\t' '!/^#/ && NF>=4 && $2=="no"' "$REG" | wc -l | tr -d ' ')"
BAD_VALUE="$(awk -F'\t' '!/^#/ && NF>=4 && $2!="yes" && $2!="no" {print $1 " -> " $2}' "$REG")"
if [ -n "$BAD_VALUE" ]; then
    printf '  FAIL  refreshed_on_upgrade must be yes or no:\n'
    printf '%s\n' "$BAD_VALUE" | sed 's/^/          /'
    fails=$((fails + 1))
else
    report "refreshed_on_upgrade is yes or no on every row" 0
fi

printf '  REACH: %s of %s generated CLI tools are refreshed by a Sparkle upgrade.\n' "$n_yes" "$n_actual"
[ "$n_no" -gt 0 ] && printf '         %s are fresh-install only, so a fix to any of them does NOT reach an upgrading customer.\n' "$n_no"

[ "$fails" -eq 0 ] || { printf 'FAIL: %s check(s) failed.\n' "$fails" >&2; exit 1; }
printf 'PASS: %s generated tools, all declared, %s claimed refreshed and backed.\n' "$n_actual" "$n_yes"
