#!/usr/bin/env bash
#
# tests/test_store_callers_authenticate.sh
#
# #550: every shell call that dials a data store must carry a credential,
# or be a MEASURED exemption.
#
# The Python shim (lib/ostler_store_auth.py) is a Python mechanism, so every
# `curl` in install.sh is outside it BY CONSTRUCTION. This is that half.
#
# ── WHY THIS FILE EXISTS AND NOT A GREP ───────────────────────────────
#
# Four predicates were tried on this population in one afternoon and every one
# was short. The history is the specification:
#
#   single-line grep                    3   URL had to share a line with curl
#   +3-line window                      6   a window is what you reach for
#                                           when you have not enumerated
#   quote-aware, port literals only     8   blind to composed URLs
#   + derived aliases, per COMMAND     18   but scored a two-arm command as
#                                           authenticated when only ONE arm was
#   + per CALL                         19 calls, and the arm defect appeared
#
# @A2 and @TNM reached 18 independently with different mechanisms. Three
# instruments agreeing is the strongest evidence available here, and it is
# still not a construction proof -- see UNMEASURED at the bottom.
#
# ── THE TWO RULES THAT MAKE IT WORK ───────────────────────────────────
#
# 1. DERIVE THE ALIASES, NEVER LIST THEM. install.sh names the stores through
#    eleven different variables -- `_qdrant_url` lowercase, `_HYDRATE_OXIGRAPH`,
#    `_INITIAL_HYDRATE_QDRANT`, one per source and per phase. No hand-written
#    list was ever going to contain those. Pass 1 finds every variable whose
#    ASSIGNMENT is a store URL.
#
# 2. CLASSIFY PER CALL, NOT PER COMMAND. `curl A || curl B` is one command and
#    two calls with different needs. Scoring the command marked it AUTH because
#    one arm held the credential -- while the OTHER arm, the one that 401s, was
#    bare. Measured, not hypothetical: that shipped in a8e62fa8 and @A2 caught it.
#
# Exemptions are MEASURED, not read from vendor docs. @A2 ran the pinned Qdrant
# image with an API key set: / /healthz /readyz /livez answer 200 with no key;
# /collections /telemetry /metrics 401. Oxigraph has NO exempt path at all --
# install.sh:14713 is a blanket nginx `if` on `location /`.

set -uo pipefail

INSTALL="install.sh"
MODE=""
case "${1:-}" in --self-test|--ci) MODE="$1"; shift ;; esac
[ $# -gt 0 ] && INSTALL="$1"
rc_pass=0; rc_fail=1; rc_cannot=2

# ⚠️ PINNED, same contract as every other floor in this repo: measured on
# CM051 main, 2026-08-28, and independently corroborated at 18 by @A2 (alias
# fixed-point closure) and @TNM (a third instrument). If a caller is
# legitimately DELETED, lower these in the same PR and name it. Never raise one
# to silence a failure.
# 🔴 FLOOR 19 -> 16 ON 2026-08-29, AND THIS IS A RATCHET-DOWN, NOT A WIDENING.
#
# The gate's own refusal message is right: "a shortfall means the predicate
# broke, not that callers left". So the burden is on the change to prove the
# population genuinely shrank. It did, by exactly three, all deliberate, all
# in the #566 readiness fix:
#
#   -2  the ERR-06 double-probe (two credentialed /collections curls) was
#       DELETED. Reaching it meant a credentialed GET had returned 200 a
#       second earlier; it could only add a flake, and its answer to a flake
#       was exit 1 on a customer's machine.
#   -1  the readiness loop went from TWO curls (bare /readyz || credentialed
#       /collections) to ONE credentialed /collections. The bare arm was dead
#       code: `A || B` never evaluated B because /readyz answers 200 keyless.
#
# ⚠️ THE PREDICATE IS PROVED INTACT, WHICH IS WHAT MAKES THIS SAFE TO LOWER.
# On the failing run the gate reported `calls 16  AUTH 15  EXEMPT 1  BARE 0`:
# it still FOUND and CLASSIFIED every remaining call, and found ZERO bare
# ones. A broken predicate loses calls silently; this one accounted for all
# 16. The floor was measuring a population that legitimately got smaller.
#
# 🔴 IF THIS NUMBER EVER DROPS AGAIN, DO NOT EDIT IT WITHOUT THE SAME PROOF:
# enumerate which calls went and why, and show BARE is still 0. A floor
# lowered without that enumeration is exactly the "edit a gate to pass"
# failure this repo keeps finding in other people's work.
OSTLER_STORE_CALL_FLOOR="${OSTLER_STORE_CALL_FLOOR:-16}"
# 🔴 EXEMPT 2 -> 1 ON 2026-08-29, AND AN EXEMPTION IS A MEASURED HOLE.
# The gate is right that changing this count changes what is unprotected, so
# the change has to name the hole that closed. It is the BARE /readyz arm of
# the Qdrant readiness loop: exempt precisely because /readyz answers 200
# with no credential. The #566 fix DELETED that arm -- it was dead code, the
# `||` meant it always won and the credentialed arm beside it never ran.
# So this is one FEWER uncredentialed store call on the customer path, not a
# hole being widened. The surviving exemption is unchanged.
OSTLER_STORE_EXEMPT_EXPECT="${OSTLER_STORE_EXEMPT_EXPECT:-1}"

analyse() {
    python3 - "$1" <<'PY'
import re, sys
path = sys.argv[1]
try:
    lines = open(path, encoding='utf-8').read().split('\n')
except OSError:
    print("CANNOT_RUN: cannot read", path); sys.exit(2)
if not lines or not any(l.strip() for l in lines):
    print("CANNOT_RUN: empty file"); sys.exit(2)

URLPORT = re.compile(r'https?://[^"\'\s]*(localhost|127\.0\.0\.1):(6333|6334|7878|6379)')
# RULE 1: derive the aliases. An assignment whose RHS is a store URL names a
# store. `curl` in the RHS is excluded: that is a variable holding curl OUTPUT,
# not a URL -- my first resolver pulled in `count` and `raw` that way and the
# extra rows looked exactly like real findings.
aliases = set()
for l in lines:
    m = re.match(r'\s*(?:local\s+|export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)', l)
    if m and URLPORT.search(m.group(2)) and 'curl' not in m.group(2):
        aliases.add(m.group(1))
ALIAS = re.compile(r'\$\{?(' + '|'.join(map(re.escape, sorted(aliases))) + r')\b') if aliases else None

AUTH   = re.compile(r'_OSTLER_STORE_CURL_ARGS|api-key|Authorization|--header|-K ')
# MEASURED exemptions only. Oxigraph deliberately absent: it has no exempt path.
EXEMPT = re.compile(r'/(healthz|readyz|livez)(\b|["\'/?])')

def balanced(s):
    return s.count('"') % 2 == 0 and s.count("'") % 2 == 0

calls, i = [], 0
while i < len(lines):
    l = lines[i]
    if re.search(r'(^|[;&|(`]|\s)curl\b', l) and not l.strip().startswith('#'):
        start, buf, j = i, l, i
        # A multi-line quoted SPARQL body continues with NO trailing backslash.
        # Extend until quotes balance, not until a backslash stops.
        while j + 1 < len(lines) and (not balanced(buf) or buf.rstrip().endswith('\\')):
            j += 1; buf += '\n' + lines[j]
            if j - start > 40: break
        # RULE 2: split into CALLS.
        for k, part in enumerate(re.split(r'(?:\|\||&&|;)\s*(?=curl\b)', buf)):
            if 'curl' not in part: continue
            if URLPORT.search(part) or (ALIAS and ALIAS.search(part)):
                if AUTH.search(part):     verdict = 'AUTH'
                elif EXEMPT.search(part): verdict = 'EXEMPT'
                else:                     verdict = 'BARE'
                calls.append((start + 1, k + 1, verdict))
        i = j + 1
    else:
        i += 1

n = len(calls)
bare   = [(a, b) for a, b, v in calls if v == 'BARE']
exempt = [(a, b) for a, b, v in calls if v == 'EXEMPT']
print(f"aliases derived: {len(aliases)}")
print(f"calls {n}  AUTH {n - len(bare) - len(exempt)}  EXEMPT {len(exempt)}  BARE {len(bare)}")
for a, b in bare:   print(f"  BARE   line {a} arm {b}")
for a, b in exempt: print(f"  exempt line {a} arm {b}")
sys.exit(0 if not bare else 1)
PY
}

verify() {
    local f="$1" out rc
    [ -f "$f" ] || { printf 'CANNOT_RUN: no such file: %s\n' "$f"; return $rc_cannot; }
    out="$(analyse "$f")"; rc=$?
    printf '%s\n' "$out"
    [ "$rc" -eq 2 ] && return $rc_cannot

    local n_calls n_exempt
    n_calls="$(printf '%s\n' "$out" | sed -n 's/^calls \([0-9]*\) .*/\1/p')"
    n_exempt="$(printf '%s\n' "$out" | sed -n 's/.*EXEMPT \([0-9]*\) .*/\1/p')"

    # ANTI-VACUITY. A predicate that quietly stops matching prints a small
    # number, and a small number reads as an answer. Four predicates were short
    # on this exact population today; the floor is what catches the fifth.
    if [ "${n_calls:-0}" -lt "$OSTLER_STORE_CALL_FLOOR" ]; then
        printf 'CANNOT_RUN: found %s store calls, floor is %s\n' \
            "${n_calls:-0}" "$OSTLER_STORE_CALL_FLOOR"
        printf '  Three independent instruments agreed on this population. A\n'
        printf '  shortfall means the predicate broke, not that callers left.\n'
        return $rc_cannot
    fi
    # An exemption is a HOLE. If the count moves, someone widened or narrowed
    # what counts as exempt, and that must be deliberate and visible.
    #
    # ⚠️ -1 means OFF, and it needs a sentinel because this is an EQUALITY, not
    # a floor. The self-test preamble first tried to disable it by setting it to
    # 0, which silently became "expect exactly zero exemptions" and false-failed
    # every fixture that holds one. A floor switches off at 0. An equality does
    # not, and it fails LOUD in the direction that looks like a real finding.
    if [ "$OSTLER_STORE_EXEMPT_EXPECT" -ge 0 ] \
       && [ "${n_exempt:-0}" -ne "$OSTLER_STORE_EXEMPT_EXPECT" ]; then
        printf 'CANNOT_RUN: %s exempt calls, expected exactly %s\n' \
            "${n_exempt:-0}" "$OSTLER_STORE_EXEMPT_EXPECT"
        printf '  Exemptions are measured holes. Changing the count changes\n'
        printf '  what is unprotected. Do it in a PR that says so.\n'
        return $rc_cannot
    fi
    [ "$rc" -eq 0 ] || { printf 'FAIL: a store call carries no credential\n'; return $rc_fail; }
    printf 'PASS: every store call is credentialled or a measured exemption\n'
    return $rc_pass
}

self_test() {
    local d rc fails=0; d="$(mktemp -d)"
    local F="$OSTLER_STORE_CALL_FLOOR" E="$OSTLER_STORE_EXEMPT_EXPECT"
    OSTLER_STORE_CALL_FLOOR=0; OSTLER_STORE_EXEMPT_EXPECT=-1

    printf 'Q="http://localhost:6333"\ncurl -sf "$Q/collections"\n' > "$d/bare_alias"
    printf 'Q="http://localhost:6333"\ncurl -K /c "$Q/collections"\n' > "$d/auth_alias"
    printf 'curl -sf "http://localhost:6333/healthz"\n' > "$d/exempt_only"
    # THE ARM DEFECT, as shipped in a8e62fa8 and caught by @A2.
    printf 'Q="http://localhost:6333"\ncurl -K /c "$Q/readyz" || curl -sf "$Q/collections"\n' \
        > "$d/arm_defect"
    printf 'Q="http://localhost:6333"\ncurl -sf "$Q/readyz" || curl -K /c "$Q/collections"\n' \
        > "$d/arm_correct"
    # Multi-line quoted body, no trailing backslash. A window misses this.
    printf 'OX="http://localhost:7878"\ncurl -sf \\\n  --data-binary "PREFIX p: <x>\nSELECT * {}" \\\n  "$OX/query"\n' \
        > "$d/multiline_body"
    # Oxigraph has NO exempt path: a bare / probe must FAIL, not be excused.
    printf 'OX="http://localhost:7878"\ncurl -sf "$OX/"\n' > "$d/oxigraph_root_not_exempt"
    printf 'curl -sf https://example.com/x\n' > "$d/not_a_store"

    ck() { verify "$3" >/dev/null 2>&1; rc=$?
        if [ "$rc" -eq "$2" ]; then printf '  ok   %-40s rc=%s\n' "$1" "$rc"
        else printf '  FAIL %-40s rc=%s want=%s\n' "$1" "$rc" "$2"; fails=$((fails+1)); fi; }

    ck "bare call via a DERIVED alias"        $rc_fail   "$d/bare_alias"
    ck "credentialled call via alias"         $rc_pass   "$d/auth_alias"
    ck "measured exemption alone"             $rc_pass   "$d/exempt_only"
    ck "ARM DEFECT: cred on exempt arm"       $rc_fail   "$d/arm_defect"
    ck "arms the right way round"             $rc_pass   "$d/arm_correct"
    ck "multi-line body, no backslash"        $rc_fail   "$d/multiline_body"
    ck "Oxigraph / is NOT exempt"             $rc_fail   "$d/oxigraph_root_not_exempt"
    ck "non-store host ignored"               $rc_pass   "$d/not_a_store"
    ck "absent file"                          $rc_cannot "$d/nope"

    OSTLER_STORE_CALL_FLOOR="$F"; OSTLER_STORE_EXEMPT_EXPECT="$E"
    ck "FLOOR catches a shrunken population"  $rc_cannot "$d/auth_alias"

    # MUTATION ARM for the fix above. Disabling the equality with a sentinel
    # could just as easily disable it ALWAYS, and the suite would go green
    # either way -- the failure I was fixing and the failure of the fix look
    # identical from the outside. This pins that -1 is the ONLY off switch.
    OSTLER_STORE_CALL_FLOOR=0; OSTLER_STORE_EXEMPT_EXPECT=0
    ck "exempt EQUALITY still fires at 0"    $rc_cannot "$d/exempt_only"
    OSTLER_STORE_EXEMPT_EXPECT=1
    ck "exempt equality passes on a match"   $rc_pass   "$d/exempt_only"
    OSTLER_STORE_CALL_FLOOR=0; OSTLER_STORE_EXEMPT_EXPECT=-1

    printf '  self-test failures: %s\n' "$fails"
    rm -rf "$d"
    OSTLER_STORE_CALL_FLOOR="$F"; OSTLER_STORE_EXEMPT_EXPECT="$E"
    return $((fails > 0))
}

# ── UNMEASURED, AND NAMED RATHER THAN CLEARED ─────────────────────────
#
# 🔴 THE BIGGEST GAP IS THAT THIS GATE IS CURL-SHAPED (widened 2026-08-28).
#
# A STORE CLIENT THAT IS NOT CURL AT ALL. This predicate keys on the token
# `curl`, so a caller that reaches a store by any other means is outside the
# denominator entirely -- not missed, INVISIBLE.
#
# Not hypothetical. @A2 found `install.sh:24972`:
#     docker exec ostler-redis redis-cli ping
# a real store client, in the shipped installer, feeding the customer's
# completion screen via a log-string contract. This gate scored 19 calls with
# three independent instruments agreeing, and all three agreed WITHIN THE SAME
# BLIND SPOT, because all three were looking for curl.
#
# 📌 My original list below enumerated three ways the predicate could miss a
# caller -- and every one of them is still a curl. I was careful about the
# spelling and never questioned the noun. That is the same error as pinning a
# denominator: precision inside a boundary you did not check.
#
# @A2's sweep for the other shapes (`docker exec` into a store container, `nc`,
# `python -c`) found :24972 and nothing else, so that inventory is closed AS OF
# 2026-08-28 -- by their measurement, not by this gate, which still cannot see
# any of them.
#
# The narrower curl-shaped gaps, still true:
#   * curl invoked through a variable        ("$CURL_BIN" ...)
#   * curl inside a heredoc that writes a helper script -- a real caller in the
#     GENERATED script, invisible as install.sh's own execution
#   * curl behind a wrapper function
#
# Three instruments agreeing bounds the RISK; it does not prove COVERAGE. And
# agreeing instruments that share a shape do not even bound it.

case "$MODE" in
    --self-test) self_test; exit $? ;;
    --ci) printf '== self-test ==\n'
          self_test || { printf 'CANNOT_RUN: gate fails its own suite\n' >&2; exit 2; }
          printf '\n== %s ==\n' "$INSTALL"; verify "$INSTALL"; exit $? ;;
esac
verify "$INSTALL"; exit $?
