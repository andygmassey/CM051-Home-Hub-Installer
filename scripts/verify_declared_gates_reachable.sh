#!/usr/bin/env bash
#
# verify_declared_gates_reachable.sh -- a file that says it blocks the cut must
# be reachable FROM the cut, and its CALLER must be reachable too.
#
#   REPORTS RATIOS, NEVER A BARE PASS.
#
# "6 of 7 declared blockers are reachable" is a fact a reader can act on. "PASS"
# is not, and neither is "1 finding" -- both hide the denominator, and a
# denominator nobody states is a denominator nobody checks.
#
# ============================================================================
# WHY THIS EXISTS
# ============================================================================
#
# 2026-08-15. Three files across three repos were found in one night, each
# declaring itself a cut blocker in its own header, each invoked by nothing:
#
#   * CM051 tests/verify_hub_chat.sh   "Exit 0 = chat works. Non-zero = BLOCK
#                                       THE CUT." Zero callers, zero mentions.
#                                       DISPOSITIONED 2026-08-16: deleted. The
#                                       live equivalent is OS003
#                                       gates/behavioural_chat_probe.py, and it
#                                       IS reached --
#                                       pipeline/release.yml:169 runs
#                                       gates/verify_behavioural_acceptance.sh
#                                       --seed, which invokes the probe. Two
#                                       copies of one gate where only one is
#                                       reachable is worse than one copy: the
#                                       dark one absorbs the attention the live
#                                       one needs.
#   * HR015 bin/ci-pii-shape-scan.sh   declared blocking, reachable only via a
#                                       workflow nothing required.
#   * D011 repair pass                  same shape.
#
# None was caught by the test-wiring register, because that register enumerates
# `test_*` and these are named otherwise: they were not scored UNWIRED, they
# were UNENUMERABLE, which prints as nothing at all.
#
# A gate declaring itself blocking and being invoked by nothing is the purest
# form of that night's defect: an instrument whose verdict cannot reach the
# decision it claims to govern. It is worse than no gate, because the
# declaration is read as coverage.
#
# ============================================================================
# REACHABILITY IS TRANSITIVE. VERSION ONE OF THIS GATE FORGOT THAT.
# ============================================================================
#
# 2026-08-16, measured against CM051 origin/main ee457e5. The one-hop question
# "does anything call X" is not the question. The real one is "can the CUT get
# to X", and those differ the moment a caller is itself dark:
#
#   scripts/run_all_cut_gates.sh  -- "every pre-cut gate, one command, fails
#   closed" -- is invoked by NOTHING. Its only appearance inside an executable
#   file is an `@echo` in gui/Makefile that PRINTS its name as advice.
#
#   And tests/TEST_WIRING.tsv scores THREE tests WIRED naming that runner as
#   the evidence. The runner really does invoke all three. So the register's
#   claim is true about the runner and false about the product, because the
#   runner is dark. One of those three is the arm64 check that two wiki
#   hold_ack rows lean on with the words "so this ack does not carry that
#   guarantee on trust". It carries it on a test that never runs.
#
# So this gate computes a FIXPOINT from declared cut entry points, not a
# one-hop grep. A gate reached only by a gate nobody reaches is still dark.
#
# ============================================================================
# A MENTION IS NOT AN INVOCATION, AND A PRINT IS NOT AN INVOCATION EITHER
# ============================================================================
#
# Two ways a name appears without the file ever running, and this gate rejects
# both because each has already fooled a real instrument in this estate:
#
#   COMMENTS. verify_test_wiring.sh scores a test WIRED if its name appears in
#   a comment, so documenting a dark test marks it live. Comments are stripped
#   here before anything is matched.
#
#   OUTPUT STATEMENTS. `@echo "... run_all_cut_gates.sh"` is code, not a
#   comment, and it still invokes nothing. Lines whose whole job is to print
#   are dropped.
#
# ============================================================================
# WHAT COUNTS AS A CALL SITE, AND WHY IT IS NOT A LIST OF SPELLINGS
# ============================================================================
#
# Version one matched `bash X`, `sh X`, `./X`, `source X`, `run: X`. That is a
# predicate pinned to the RENDERING of an invocation, and it produced a false
# orphan on the first real tree it met:
#
#   gui/Makefile:1375   ORPHANS_SH ?= $(CURDIR)/../scripts/verify_no_orphaned_fixes.sh
#   gui/Makefile:1378   @rc=0; bash "$(ORPHANS_SH)" || rc=$$?; \
#
# Genuinely wired, through a variable, and reported as an orphan. Assert the
# defect, not its formatting. So the predicate is now the other way round: ANY
# reference on a line of real code counts, EXCEPT a line that only prints. That
# admits variables, `for f in X`, `include X`, `run:`, dispatch tables and
# whatever spelling arrives next, and it needs no maintenance when one does.
#
# THE ERROR DIRECTION IS DELIBERATE. An over-tight predicate reports an extra
# orphan, which is noise a human resolves in a minute. An over-loose one
# blesses a dark gate, which is invisible forever. Where this is unsure it
# reports the orphan.
#
# ============================================================================
# TWO POPULATIONS, TWO DENOMINATORS, NEVER ONE RATIO
# ============================================================================
#
# A doc or a data file can declare a blocking rule too, and CLAUDE.md and its
# kin are the highest-privilege prose in the estate. But a doc is reached by
# being READ, not by being called, so running an executable-call-site predicate
# over it can only ever return "orphan" -- a permanent false red, which is how
# people learn that red means nothing.
#
# Version one folded both into one 7-of-14 ratio, and 3 of those 7 "orphans"
# were a .yaml, a .md and a .manifest. They are reported here, separately,
# labelled as NOT MEASURED ON THIS AXIS, with their own count. Stating the
# exclusion is the point: an instrument that goes quiet about what it cannot
# see gets read as having seen everything.
#
# British English throughout; " -- " not em-dashes.

set -uo pipefail

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
SELF_TEST=0
TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --self-test) SELF_TEST=1; shift ;;
        --repo)      TARGET="${2:-}"; shift 2 ;;
        -h|--help)
            echo "usage: $0 [--repo <path>] [--self-test]"
            echo "  --repo   repository to examine (default: \$PWD's repo root)"
            exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# TWO DIFFERENT QUESTIONS, TWO DIFFERENT PREDICATES. Conflating them is what
# put a cut-manifest yaml in the orphan list on the first real run.
#
#   is_caller_file  -- "could this file INVOKE something?"  Loose on yaml,
#                      because admitting a data file as a possible caller only
#                      ever costs a missed orphan report, never a false green.
#
#   is_executable_declarer -- "is it fair to judge THIS file on whether it gets
#                      CALLED?"  Strict. A cut-manifest yaml declares blocking
#                      rules and is consumed by being READ. Judging it on an
#                      invocation axis can only ever return "orphan", which is
#                      a permanent false red, which is how people learn that
#                      red means nothing.
is_caller_file() {
    case "$1" in
        *.sh|*.bash|*.py|*.zsh) return 0 ;;
        *.yml|*.yaml) return 0 ;;
        Makefile|makefile|GNUmakefile|*/Makefile|*/makefile|*.mk) return 0 ;;
        *) return 1 ;;
    esac
}

is_executable_declarer() {
    case "$1" in
        *.sh|*.bash|*.py|*.zsh) return 0 ;;
        .github/workflows/*) return 0 ;;
        Makefile|makefile|GNUmakefile|*/Makefile|*/makefile|*.mk) return 0 ;;
    esac
    # Anything else earns the executable axis only by carrying a shebang or the
    # executable bit -- a property of the file, not of its name.
    [ -x "$1" ] && return 0
    head -c 2 "$1" 2>/dev/null | grep -q '#!' && return 0
    return 1
}

# ENTRY POINTS: reachable by definition, because something outside the repo
# runs them. Everything else must be reached FROM one of these.
#
#   .github/workflows/*  GitHub runs them on its own schedule/triggers
#   Makefile / *.mk      the operator and the ORM run `make ...` by hand
#
# Extend with OSTLER_CUT_ENTRYPOINTS (colon-separated, repo-relative). Adding
# one is how you declare "a human or a robot starts here".
is_entry_point() {
    case "$1" in
        .github/workflows/*) return 0 ;;
        Makefile|makefile|GNUmakefile|*/Makefile|*/makefile|*.mk) return 0 ;;
    esac
    local extra
    IFS=':' read -r -a extra <<< "${OSTLER_CUT_ENTRYPOINTS:-}"
    local e
    for e in "${extra[@]:-}"; do
        [ -n "$e" ] && [ "$e" = "$1" ] && return 0
    done
    return 1
}

DECLARE_RE='BLOCK THE CUT|BLOCKS THE CUT|CUT BLOCKER|blocks? the release|MUST NOT SHIP|DO NOT ASSEMBLE'

# ---------------------------------------------------------------------------
# code_lines: emit only the lines of a file that are REAL, EXECUTED code.
#
#   1. drop comment tails   (`#` at start of line or preceded by whitespace)
#   2. drop pure-output lines (echo / printf / say / warn / note / log / print)
#
# Step 2 is what separates "the cut can reach this" from "someone typed its
# name". Both filters err towards dropping, i.e. towards reporting an orphan.
# ---------------------------------------------------------------------------
code_lines() {
    sed -E 's/(^|[[:space:]])#.*$/\1/' "$1" 2>/dev/null \
      | grep -vE '^[[:space:]]*[-@]?[[:space:]]*(echo|printf|say|print|puts|warn|note|info|log|cat[[:space:]]+<<)[[:space:](]'
}

# ===========================================================================
# SELF-TEST
#
# A classifier never shown an orphan cannot be relied on to report one, and a
# classifier never shown the case that BROKE IT cannot be said to be fixed.
# Control (4) is the gui/Makefile variable-indirection call that version one
# called an orphan; control (5) is the @echo that version one would have called
# reachable once comments alone were stripped. The fix is proven by the two
# failures that caused it.
# ===========================================================================
if [ "$SELF_TEST" -eq 1 ]; then
    p=0; f=0
    ok() { printf '  PASS  %s\n' "$1"; p=$((p+1)); }
    no() { printf '  FAIL  %s\n' "$1"; f=$((f+1)); }

    # THE SELF-TEST DRIVES THE REAL SCRIPT, VIA --repo, AND ASSERTS ON ITS
    # OUTPUT. It does NOT re-implement the walk.
    #
    # The first version of this block carried its own inline copy of the
    # fixpoint, so it proved a COPY of the algorithm correct and said nothing
    # about the one that ships. That is the duplicated-predicate trap, and it
    # is a member of the same family this gate exists to catch: evidence
    # ADJACENT to the claim rather than about it. Everything below runs
    # "$SELF" over a real git fixture.
    SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    d="$(mktemp -d -t declgate-XXXXXX)"; trap 'rm -rf "$d"' EXIT

    build_fixture() {   # $1 = dir, $2 = "with-orphans" | "clean"
        local r="$1" mode="$2"
        mkdir -p "$r/scripts" "$r/docs" "$r/gui" "$r/cut-manifests"
        for g in called_gate var_called_gate; do
            printf '#!/bin/sh\n# Non-zero = BLOCK THE CUT.\nexit 0\n' > "$r/scripts/$g.sh"
        done
        cat > "$r/gui/Makefile" <<'MK'
GATE_SH ?= $(CURDIR)/../scripts/var_called_gate.sh
check:
	bash scripts/called_gate.sh
	@rc=0; bash "$(GATE_SH)" || rc=$$?; exit $$rc
	@echo "Pre-cut gates all at once:  scripts/echoed_gate.sh"
MK
        if [ "$mode" = "with-orphans" ]; then
            for g in orphan_gate echoed_gate second_hop_gate dark_runner; do
                printf '#!/bin/sh\n# Non-zero = BLOCK THE CUT.\nexit 0\n' > "$r/scripts/$g.sh"
            done
            # A dark runner that really does invoke second_hop_gate.
            printf '#!/bin/sh\n# Non-zero = BLOCK THE CUT.\nbash scripts/second_hop_gate.sh\n' \
                > "$r/scripts/dark_runner.sh"
            # Prose mention. Must not rescue orphan_gate.
            printf 'The orphan_gate.sh check is important and must be kept.\n' > "$r/docs/notes.md"
            # A DATA yaml that declares a blocking rule. Belongs in the second
            # population, never in the orphan list.
            printf 'version: v1.0.11\nnote: this manifest MUST NOT SHIP unverified\n' \
                > "$r/cut-manifests/v1.0.11.yaml"
        fi
        ( cd "$r" && git init -q . && git add -A \
          && git -c user.email=t@t -c user.name=t commit -qm fixture ) >/dev/null 2>&1
    }

    build_fixture "$d/red" with-orphans
    build_fixture "$d/green" clean

    OUT="$d/red.out"
    bash "$SELF" --repo "$d/red" > "$OUT" 2>&1; rc_red=$?
    orphan_block() { sed -n '/^  ORPHANED/,$p' "$OUT"; }
    listed_orphan() { orphan_block | grep -qF "scripts/$1.sh"; }

    listed_orphan called_gate     && no "(1) direct 'bash X' call site was called an orphan" \
                                  || ok "(1) a direct 'bash X' call site IS a call site"
    listed_orphan orphan_gate     && ok "(2) unreachable declarer reported as an orphan" \
                                  || no "(2) MISSED an unreachable declarer -- the gate is blind"
    grep -q 'orphan_gate' "$d/red/docs/notes.md" \
                                  && ok "(3) a prose mention exists and (2) still called it an orphan" \
                                  || no "(3) fixture broken: the mention is not there"
    listed_orphan var_called_gate && no "(4) REGRESSION: variable-indirection call called an orphan" \
                                  || ok "(4) VARIABLE INDIRECTION is a call site (the v1 false positive)"
    listed_orphan echoed_gate     && ok "(5) a print-only reference does NOT rescue a gate" \
                                  || no "(5) an @echo naming a gate wrongly marked it reachable"
    listed_orphan dark_runner     && ok "(6) the dark runner is itself reported as an orphan" \
                                  || no "(6) dark runner wrongly reported reachable"
    listed_orphan second_hop_gate && ok "(7) TRANSITIVE: a gate reached only VIA a dark runner is still dark" \
                                  || no "(7) one-hop reasoning let a second-hop gate pass"
    if orphan_block | grep -qF 'cut-manifests/v1.0.11.yaml'; then
        no "(8) a DATA yaml was judged on the invocation axis (permanent false red)"
    elif grep -qF 'cut-manifests/v1.0.11.yaml' "$OUT"; then
        ok "(8) a DATA yaml declarer is reported under NOT MEASURED, not as an orphan"
    else
        no "(8) the data-yaml declarer vanished entirely -- it must still be COUNTED"
    fi
    [ "$rc_red" -eq 1 ] && ok "(9) exits 1 when orphans exist" \
                        || no "(9) orphans present but exit code was ${rc_red}"

    # THE GREEN CONTROL. A gate that has only ever been observed failing is not
    # known to be able to pass, and a red-only instrument gets bypassed.
    bash "$SELF" --repo "$d/green" > "$d/green.out" 2>&1; rc_green=$?
    if [ "$rc_green" -eq 0 ] && grep -q 'no orphans' "$d/green.out"; then
        ok "(10) GREEN CONTROL: a tree with no orphans passes, exit 0"
    else
        no "(10) GREEN CONTROL FAILED (exit ${rc_green}) -- this gate can only ever say no"
    fi

    echo
    echo "=== $p passed / $f failed ==="
    [ "$f" -eq 0 ]; exit $?
fi

# ===========================================================================
# THE REAL RUN
# ===========================================================================
if [ -n "$TARGET" ]; then
    cd "$TARGET" || { echo "cannot enter --repo '$TARGET'" >&2; exit 2; }
fi
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "verify-declared-gates: CANNOT-RUN -- not inside a git repository" >&2; exit 2; }
cd "$REPO_ROOT" || exit 2

TMP="$(mktemp -d -t declgate-real-XXXXXX)"; trap 'rm -rf "$TMP"' EXIT

# --- enumerate DECLARERS across the whole tracked tree ---------------------
# Not scoped to tests/ or scripts/. A scoped zero is not a tree zero, and
# instruction files live at the root.
git grep -lniE "$DECLARE_RE" -- . 2>/dev/null | sort > "$TMP/declarers"

if [ ! -s "$TMP/declarers" ]; then
    echo "verify-declared-gates: CANNOT-RUN -- 0 declaring files found." >&2
    echo "  Every repo in this estate has always had some. A zero here means the" >&2
    echo "  pattern stopped matching, not that the problem was solved. Refusing" >&2
    echo "  to report a pass." >&2
    exit 2
fi

# --- split the two populations --------------------------------------------
: > "$TMP/decl_exec"; : > "$TMP/decl_other"
while IFS= read -r f; do
    if is_executable_declarer "$f"; then
        echo "$f" >> "$TMP/decl_exec"
    else
        echo "$f" >> "$TMP/decl_other"
    fi
done < "$TMP/declarers"

# --- candidate graph nodes = every tracked file that can invoke ------------
git ls-files > "$TMP/all"
: > "$TMP/nodes"
while IFS= read -r f; do
    is_caller_file "$f" && echo "$f" >> "$TMP/nodes"
done < "$TMP/all"

# Declarers that are not caller-files still need a reachability verdict, so
# they join the node set as leaves.
cat "$TMP/decl_exec" >> "$TMP/nodes"
sort -u "$TMP/nodes" -o "$TMP/nodes"

# --- seed the reachable set with entry points ------------------------------
: > "$TMP/reach"
while IFS= read -r f; do
    is_entry_point "$f" && echo "$f" >> "$TMP/reach"
done < "$TMP/nodes"

if [ ! -s "$TMP/reach" ]; then
    echo "verify-declared-gates: CANNOT-RUN -- no cut entry points found." >&2
    echo "  Nothing is reachable from nothing, so every file would report as an" >&2
    echo "  orphan and the run would look like a catastrophe rather than like a" >&2
    echo "  broken probe. Declare one with OSTLER_CUT_ENTRYPOINTS." >&2
    exit 2
fi
entries="$(wc -l < "$TMP/reach" | tr -d ' ')"

# --- pre-compute the code text of every node, and a basename index ---------
#
# THE SHAPE OF THIS LOOP IS LOAD-BEARING, not a micro-optimisation. Written the
# obvious way -- for each candidate, scan every reachable file -- the fixpoint
# is quadratic and did not finish inside two minutes on CM051. A gate nobody
# will wait for is a gate that gets commented out of the pipeline, which lands
# it right back in the population it exists to find.
#
# So the graph is walked ONCE per node: each file that becomes reachable is
# scanned a single time with one `grep -oFf` against the whole basename list,
# and every name it mentions is resolved through the index below.
mkdir -p "$TMP/code" "$TMP/id" "$TMP/bn"

esc() { printf '%s' "$1" | tr '/' '%'; }

i=0
while IFS= read -r f; do
    i=$((i + 1))
    code_lines "$f" > "$TMP/code/$i.txt" 2>/dev/null
    printf '%s' "$i" > "$TMP/id/$(esc "$f")"
    b="$(basename "$f")"
    printf '%s\n' "$f" >> "$TMP/bn/$b"
    printf '%s\n' "$b" >> "$TMP/basenames.all"
done < "$TMP/nodes"
sort -u "$TMP/basenames.all" > "$TMP/basenames"

# --- fixpoint: breadth-first from the entry points -------------------------
cp "$TMP/reach" "$TMP/frontier"
rounds=0
while [ -s "$TMP/frontier" ]; do
    rounds=$((rounds + 1))
    : > "$TMP/next"
    while IFS= read -r r; do
        n="$(cat "$TMP/id/$(esc "$r")" 2>/dev/null)"
        [ -n "$n" ] || continue
        # Every declared basename this file mentions, in one pass.
        grep -oFf "$TMP/basenames" "$TMP/code/$n.txt" 2>/dev/null | sort -u \
        | while IFS= read -r b; do
            [ -f "$TMP/bn/$b" ] || continue
            cat "$TMP/bn/$b"
          done \
        | sort -u \
        | while IFS= read -r cand; do
            [ "$cand" = "$r" ] && continue
            grep -qxF "$cand" "$TMP/reach" && continue
            echo "$cand" >> "$TMP/next"
          done
    done < "$TMP/frontier"
    if [ -s "$TMP/next" ]; then
        sort -u "$TMP/next" -o "$TMP/next"
        # Re-filter: a name can be discovered twice in one round.
        : > "$TMP/next2"
        while IFS= read -r c; do
            grep -qxF "$c" "$TMP/reach" || { echo "$c" >> "$TMP/reach"; echo "$c" >> "$TMP/next2"; }
        done < "$TMP/next"
        mv "$TMP/next2" "$TMP/frontier"
    else
        : > "$TMP/frontier"
    fi
done

# --- verdict ---------------------------------------------------------------
exec_total=$(wc -l < "$TMP/decl_exec" | tr -d ' ')
other_total=$(wc -l < "$TMP/decl_other" | tr -d ' ')
exec_reach=0
: > "$TMP/orphans"
while IFS= read -r f; do
    if grep -qxF "$f" "$TMP/reach"; then
        exec_reach=$((exec_reach + 1))
    else
        echo "$f" >> "$TMP/orphans"
    fi
done < "$TMP/decl_exec"

echo "verify-declared-gates: ${exec_reach} of ${exec_total} EXECUTABLE files declaring themselves"
echo "  cut-blocking are reachable from the cut (${entries} entry point(s), fixpoint in ${rounds} round(s))."

if [ "$other_total" -gt 0 ]; then
    echo
    echo "  NOT MEASURED ON THIS AXIS: ${other_total} non-executable file(s) also declare a"
    echo "  blocking rule (docs, data yaml, manifests). They are reached by being READ,"
    echo "  not called, so this gate says NOTHING about them either way:"
    while IFS= read -r f; do echo "    ${f}"; done < "$TMP/decl_other"
fi

if [ -s "$TMP/orphans" ]; then
    echo
    echo "  ORPHANED -- declares it blocks the cut, and the cut cannot reach it:" >&2
    while IFS= read -r o; do echo "    $o" >&2; done < "$TMP/orphans"
    echo >&2
    echo "  Each is either (a) a real gate that must be wired to a runner the cut" >&2
    echo "  reaches, or (b) superseded, in which case DELETE it naming the survivor" >&2
    echo "  so the next reader lands on the live one. Triage before wiring: wiring a" >&2
    echo "  rotted predicate manufactures a permanent false red, and permanent false" >&2
    echo "  reds teach people that red means nothing." >&2
    echo >&2
    echo "  If one of these is named as WIRING EVIDENCE anywhere -- a test register," >&2
    echo "  a hold_ack, a manifest row -- that evidence is void, because a runner the" >&2
    echo "  cut cannot reach cannot run anything." >&2
    exit 1
fi

echo "  no orphans."
exit 0
