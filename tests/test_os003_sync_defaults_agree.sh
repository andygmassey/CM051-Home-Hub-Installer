#!/usr/bin/env bash
# Every script that defaults to an OS003 checkout must default to the SAME one.
#
# CM051 #1485. scripts/sync_rollforward_registry.sh and scripts/sync_cut_bom.sh
# defaulted to different checkouts of the same repo, so during the v1.0.67
# assembly the register sync succeeded against a file the BOM sync then
# reported missing, seconds apart:
#
#     CANNOT-RUN  OS003 has no BOM for v1.0.67 -- write it there first
#
# That sentence reads as "nobody wrote the BOM" and meant "I looked somewhere
# else". A CANNOT-RUN that names the wrong cause is worse than a silent one,
# because it sends the reader to fix a file that is already correct.
#
# AND THE TWO PATHS WERE NOT EQUIVALENT. Measured 2026-09-05:
#
#     ~/Developer/OS003-Ostler-Release           0 dataless    HEAD 3d51fef
#     ~/Documents/Projects/OS003 - Ostler ...    1593 dataless (1591 in .git)
#                                                HEAD eca2b18  -- STALE
#
# iCloud had evicted the second one. A git read against an evicted pack does
# not fail loudly, it returns a false answer, and a recursive grep over that
# tree hangs rather than erroring. So the disagreement was not cosmetic: one
# default pointed at a tree whose absences cannot be trusted.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

# A DENOMINATOR FLOOR. If the extractor stops matching -- a rename, a quoting
# change -- it finds zero defaults, they trivially "agree", and this gate goes
# green over a question it never asked. Two scripts carry one today.
MIN_DEFAULTS=2

# Extract the default from `${OS003_DIR:-<default>}`. Echoes one line per site:
#   <file>\t<default>
# SCOPE IS scripts/ AND bin/ ONLY, AND THAT IS THE POINT.
# The property is about executable sync scripts that RESOLVE a checkout at run
# time. tests/ carries fixture text, help strings and this file's own control
# seeds, all of which contain the literal `OS003_DIR:-` without being a runtime
# default. Scanning them made this gate report ITSELF as a disagreement on its
# first run -- six "distinct checkouts", four of which were its own regex and
# fixtures. A gate that cannot tell its own seeds from its subject is measuring
# the wrong thing.
# THE NAME MUST BE ANCHORED. The old pattern was the bare substring
# `OS003_DIR:-`, which also matches the TAIL of any longer variable ending in
# those characters. scripts/new_cut.sh reads a differently-named operator
# override, and the greedy `.*` took that tail, so the gate reported a phantom
# site with an empty default and then called the empty string a rival checkout.
# The `${` prefix is what makes the name a whole name.
#
# AND A DEFAULT CAN BE ANOTHER EXPANSION, not a path. `${OS003_DIR:-${X}}`
# defers to a second resolver; the old character class stopped at the INNER
# closing brace and emitted a truncated token, which then read as a third
# distinct checkout. Those are classified INDIRECT and checked by resolving
# them, not by string-comparing them against a path.
_os003_sites() {
    local root="$1" d
    for d in scripts bin; do
        [ -d "${root}/${d}" ] || continue
        grep -rnE '\$\{OS003_DIR:-' "${root}/${d}" --include='*.sh' 2>/dev/null
    done \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
}

# <file>\t(LITERAL|INDIRECT)\t<value>
_os003_classified() {
    _os003_sites "$1" | awk '
    {
        i = index($0, ":");             rest = substr($0, i + 1)
        j = index(rest, ":");           file = substr($0, 1, i - 1)
        code = substr(rest, j + 1)
        anchor = "${OS003_DIR:-"
        k = index(code, anchor)
        if (k == 0) next
        d = substr(code, k + length(anchor))
        if (substr(d, 1, 2) == "${") {
            e = index(d, "}")
            printf "%s\tINDIRECT\t%s\n", file, (e > 2 ? substr(d, 3, e - 3) : "")
        } else {
            out = ""
            n = length(d)
            for (p = 1; p <= n; p++) {
                c = substr(d, p, 1)
                if (c == "}" || c == "\"") break
                out = out c
            }
            printf "%s\tLITERAL\t%s\n", file, out
        }
    }' | sort -u
}

_os003_defaults()     { _os003_classified "$1" | awk -F'\t' '$2 == "LITERAL"  { print $1 "\t" $3 }'; }
_os003_indirections() { _os003_classified "$1" | awk -F'\t' '$2 == "INDIRECT" { print $1 "\t" $3 }'; }

# EVERY line of CODE that names an OS003 checkout, not only the `:-` defaults.
# A checkout is also chosen by a DISCOVERY LIST -- a for-loop of candidate
# directories, the first that exists winning -- and a `:-` extractor is blind to
# every entry in it. That is the shape the eviction arm below could not see.
_os003_path_literals() {
    local root="$1" d
    for d in scripts bin; do
        [ -d "${root}/${d}" ] || continue
        grep -rnE 'OS003[-_[:space:]]+Ostler[-_[:space:]]+Release' "${root}/${d}" --include='*.sh' 2>/dev/null
    done \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
}

# Expand a leading ~ or $HOME so two spellings of one tree compare equal.
_os003_norm() {
    local v="$1"
    case "$v" in
        "~/"*)     v="${HOME}/${v#\~/}" ;;
        '$HOME/'*) v="${HOME}/${v#\$HOME/}" ;;
        '${HOME}/'*) v="${HOME}/${v#\$\{HOME\}/}" ;;
    esac
    printf '%s' "$v"
}

# The declared pointer an INDIRECT default resolves through. Echoes the path, or
# nothing if the declaration is absent or duplicated (both of which make the
# indirection resolve to something no reader can predict).
_os003_declared() {
    local rule="$1" hits
    [ -f "$rule" ] || return 0
    hits="$(grep -cE '^[[:space:]]*OS003_CHECKOUT[[:space:]]*=' "$rule")"
    [ "${hits:-0}" -eq 1 ] || return 0
    grep -E '^[[:space:]]*OS003_CHECKOUT[[:space:]]*=' "$rule" \
        | head -1 \
        | sed -E -e 's/^[[:space:]]*OS003_CHECKOUT[[:space:]]*=[[:space:]]*//' \
                 -e 's/[[:space:]]*$//' -e 's/^`//' -e 's/`$//'
}

cd "$REPO" || cant "cannot enter ${REPO}"

echo "── controls: the extractor must SEE a default and must ABSTAIN ──"
CTL="$(mktemp -d)" || cant "mktemp failed"
trap 'rm -rf "$CTL"' EXIT

mkdir -p "$CTL/scripts"
printf '%s\n' '#!/usr/bin/env bash' 'SRC="${OS003_DIR:-$HOME/Developer/OS003-Ostler-Release}"' > "$CTL/scripts/a.sh"
printf '%s\n' '#!/usr/bin/env bash' 'SRC="${OS003_DIR:-$HOME/Documents/Projects/OS003 - Ostler Release}"' > "$CTL/scripts/b.sh"
printf '%s\n' '#!/usr/bin/env bash' '# OS003_DIR:-$HOME/somewhere/else   a comment, not code' > "$CTL/scripts/c.sh"

CTL_N="$(_os003_defaults "$CTL" | grep -c . || true)"
CTL_DISTINCT="$(_os003_defaults "$CTL" | cut -f2 | sort -u | grep -c . || true)"

if [ "${CTL_N:-0}" -eq 2 ]; then
    ok "CONTROL: the extractor finds both seeded defaults and skips the commented one"
else
    bad "CONTROL: expected 2 seeded defaults, found ${CTL_N}. The extractor is broken, so the verdict below is meaningless."
fi
if [ "${CTL_DISTINCT:-0}" -eq 2 ]; then
    ok "CONTROL: a seeded DISAGREEMENT is detectable (2 distinct defaults)"
else
    bad "CONTROL: a seeded disagreement collapsed to ${CTL_DISTINCT} distinct value(s). This gate cannot fail, so its pass means nothing."
fi

# MUST-MISS: two sites that agree must read as one distinct value.
printf '%s\n' '#!/usr/bin/env bash' 'SRC="${OS003_DIR:-$HOME/Developer/OS003-Ostler-Release}"' > "$CTL/scripts/b.sh"
if [ "$(_os003_defaults "$CTL" | cut -f2 | sort -u | grep -c . || true)" -eq 1 ]; then
    ok "MUST-MISS: two agreeing sites are not reported as a disagreement"
else
    bad "MUST-MISS: two identical defaults were counted as different. The gate is loud rather than right."
fi

# MUST-MISS: a LONGER variable whose name ends in the target name is a
# different variable. This is the false positive that reddened the gate on
# main: the phantom site carried an empty default, and an empty string then
# counted as a rival checkout.
printf '%s\n' '#!/usr/bin/env bash' 'V="${OSTLER_OS003_DIR:-}"' > "$CTL/scripts/d.sh"
if [ "$(_os003_classified "$CTL" | grep -c 'd\.sh' || true)" -eq 0 ]; then
    ok "MUST-MISS: a longer variable ending in the same characters is not counted"
else
    bad "MUST-MISS: an unrelated variable was counted as an OS003 default. Its value is not a checkout, so the comparison below is against noise."
fi

# A default that is itself an expansion defers to a second resolver. It must be
# classified as such, never string-compared against a path: the old extractor
# truncated it at the inner brace and reported the fragment as a third checkout.
printf '%s\n' '#!/usr/bin/env bash' 'T="${OS003_DIR:-${DECLARED}}"' > "$CTL/scripts/e.sh"
if [ "$(_os003_indirections "$CTL" | grep -c 'e\.sh	DECLARED' || true)" -eq 1 ] \
   && [ "$(_os003_defaults "$CTL" | grep -c 'e\.sh' || true)" -eq 0 ]; then
    ok "CONTROL: a nested default is read as an indirection naming DECLARED, not as a path"
else
    bad "CONTROL: a nested default was not classified. A truncated expansion reads as a rival checkout and reddens this gate over nothing."
fi
rm -f "$CTL/scripts/d.sh" "$CTL/scripts/e.sh"

# The discovery-list scan, both directions. A candidate list is how a checkout
# gets chosen without any `:-` default existing at all.
mkdir -p "$CTL/disc/scripts"
printf '%s\n' '#!/usr/bin/env bash' \
    'for _c in "$HOME/Developer/OS003-Ostler-Release"; do :; done' > "$CTL/disc/scripts/ok.sh"
if [ "$(_os003_path_literals "$CTL/disc" | grep -c 'Documents/Projects' || true)" -eq 0 ]; then
    ok "MUST-MISS: a discovery list holding only a ~/Developer candidate does not fire"
else
    bad "MUST-MISS: the discovery scan fired on a clean candidate list. It is loud rather than right."
fi
printf '%s\n' '#!/usr/bin/env bash' \
    'for _c in "$HOME/Documents/Projects/OS003 - Ostler Release"; do :; done' >> "$CTL/disc/scripts/ok.sh"
if [ "$(_os003_path_literals "$CTL/disc" | grep -c 'Documents/Projects' || true)" -eq 1 ]; then
    ok "CONTROL: a seeded evicted-tree CANDIDATE is found, so the scan below can fail"
else
    bad "CONTROL: a seeded evicted-tree candidate was invisible to the discovery scan. Its pass below would mean nothing."
fi

# The declared-pointer reader, and the comparison that uses it.
printf '%s\n' 'OS003_CHECKOUT = ~/Developer/OS003-Ostler-Release' > "$CTL/rule_ok.md"
printf '%s\n' 'OS003_CHECKOUT = ~/Developer/OS003-Ostler-Release' \
              'OS003_CHECKOUT = ~/Developer/somewhere-else' > "$CTL/rule_two.md"
if [ "$(_os003_norm "$(_os003_declared "$CTL/rule_ok.md")")" = "${HOME}/Developer/OS003-Ostler-Release" ]; then
    ok "CONTROL: the declared pointer is read and its ~ is expanded"
else
    bad "CONTROL: the declared pointer could not be read, so the indirection arm below is measuring nothing."
fi
if [ -z "$(_os003_declared "$CTL/rule_two.md")" ] && [ -z "$(_os003_declared "$CTL/rule_absent.md")" ]; then
    ok "CONTROL: a duplicated or absent declaration yields no pointer rather than a guess"
else
    bad "CONTROL: an ambiguous declaration produced a confident answer. The indirection would resolve to something no reader can predict."
fi

echo "── subject: this repo ──"
FOUND="$(_os003_defaults .)"
N="$(printf '%s\n' "$FOUND" | grep -c . || true)"
[ "${N:-0}" -ge "$MIN_DEFAULTS" ] || cant "found ${N} OS003 default(s), below the floor of ${MIN_DEFAULTS}. \
The extractor has gone blind or a script was renamed; zero defaults agree trivially and that is not a pass."

printf '%s\n' "$FOUND" | sed 's/^/    /'
DISTINCT="$(printf '%s\n' "$FOUND" | cut -f2 | sort -u)"
N_DISTINCT="$(printf '%s\n' "$DISTINCT" | grep -c . || true)"

if [ "${N_DISTINCT:-0}" -eq 1 ]; then
    ok "all ${N} OS003 default(s) name the same checkout"
else
    bad "the ${N} OS003 default(s) name ${N_DISTINCT} DIFFERENT checkouts:
$(printf '%s\n' "$DISTINCT" | sed 's/^/          /')
        One script will report a file missing that another just read, and the
        CANNOT-RUN it prints will name the wrong cause."
fi

# The chosen default must not be the iCloud tree. That path is subject to
# eviction, and an evicted git read returns a false answer rather than an error.
# `grep -c`, not `| grep -q`: this repo bans the piped short-circuit form and
# its ratchet caught this very line. grep -c must read to EOF, so it cannot
# SIGPIPE the producer.
if [ "$(printf '%s\n' "$DISTINCT" | grep -c 'Documents/Projects')" -gt 0 ]; then
    bad "an OS003 default points into ~/Documents/Projects, which iCloud evicts. \
A read there can return a false absence instead of failing. Use a ~/Developer checkout."
else
    ok "no OS003 default points into the iCloud-evicted ~/Documents/Projects tree"
fi

# ---------------------------------------------------------------------------
# THE INDIRECTIONS. A default that defers to a declared pointer is not exempt
# from the property; it just cannot be checked by comparing strings. Resolve it
# and compare the RESULT, or the original incident recurs one level down and
# this gate reports agreement because it never looked.
# ---------------------------------------------------------------------------
N_IND="$(_os003_indirections . | grep -c . || true)"
DECLARED_PATH="$(_os003_norm "$(_os003_declared "${REPO}/CLAUDE.md")")"

if [ "${N_IND:-0}" -eq 0 ]; then
    ok "no default defers to another resolver, so there is nothing to resolve"
elif [ -z "${DECLARED_PATH}" ]; then
    bad "${N_IND} default(s) defer to the pointer declared in CLAUDE.md, and that \
file does not state it exactly once. The indirection resolves to a value no \
reader can predict, which is the same wrong-cause CANNOT-RUN in a new costume."
else
    IND_BAD=0
    while IFS="$(printf '\t')" read -r _f _v; do
        [ -n "${_f:-}" ] || continue
        [ "$(_os003_norm "$_v")" = "${DECLARED_PATH}" ] || IND_BAD=$((IND_BAD+1))
    done <<EOF
$(printf '%s\n' "$FOUND")
EOF
    if [ "$IND_BAD" -eq 0 ]; then
        ok "the declared pointer (${DECLARED_PATH}) resolves to the same checkout as all ${N} literal default(s)"
    else
        bad "${IND_BAD} literal default(s) name a different checkout from the \
pointer CLAUDE.md declares (${DECLARED_PATH}). ${N_IND} script(s) resolve \
through that pointer, so they read a different tree from the ones that do not."
    fi
fi

# ---------------------------------------------------------------------------
# THE DISCOVERY LISTS. A `:-` default is only one way a checkout gets chosen.
# The other is a list of candidate directories walked until one exists, and
# every arm above is blind to it: no default is written, so nothing is
# extracted, and the gate passes over the choice entirely.
# ---------------------------------------------------------------------------
EVICTED_CANDIDATES="$(_os003_path_literals . | grep 'Documents/Projects' || true)"
if [ -n "${EVICTED_CANDIDATES}" ]; then
    bad "a script chooses an OS003 checkout from a path under ~/Documents/Projects, \
which iCloud evicts. An evicted read returns a false absence rather than an error, \
so the cut would be gated against a tree whose silences cannot be trusted:
$(printf '%s\n' "${EVICTED_CANDIDATES}" | sed 's/^/          /')"
else
    ok "no script names an OS003 checkout under the iCloud-evicted tree, in a default OR a candidate list"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
