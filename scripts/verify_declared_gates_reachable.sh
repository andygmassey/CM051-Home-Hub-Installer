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
#                                       DISPOSITIONED 2026-08-16 by deletion,
#                                       naming a survivor. RIGHT CALL, WRONG
#                                       EVIDENCE. Corrected 2026-08-23; see
#                                       "THE DISPOSITION THAT CITED A DARK
#                                       CALLER" below.
#   * HR015 bin/ci-pii-shape-scan.sh   declared blocking, reachable only via a
#                                       workflow nothing required.
#   * D011 repair pass                  same shape.
#
# ============================================================================
# THE DISPOSITION THAT CITED A DARK CALLER
# ============================================================================
#
# This header used to record that verify_hub_chat.sh was safe to delete because
# "the live equivalent is OS003 gates/behavioural_chat_probe.py, and it IS
# reached -- pipeline/release.yml:169 runs gates/verify_behavioural_acceptance.sh
# --seed, which invokes the probe."
#
# MEASURED 2026-08-23 against OS003 main 35753583df45. Every clause of that is
# wrong except the conclusion:
#
#   * the line is 204, not 169
#   * pipeline/release.yml is NOT under .github/workflows/, and OS003 has
#     exactly one workflow (gates.yml, self-tests). GitHub never reads it.
#   * so NOTHING invokes it, and OS003's own registers already said so:
#     cuts/DEFECTS_ROLLFORWARD.md:39 -- "no file in the repo invokes
#     pipeline/release.yml" -- and bin/cut.sh:358-363, which refuses to
#     register a gate there because it would be "a gate that looks required
#     and runs never".
#   * bin/cut.sh, the operator road, does not mention behavioural at all.
#     Control: verify_must_contain appears in it at line 368.
#
# So a gate was retired against evidence that was itself the defect this gate
# exists to catch. It is worth saying plainly, because the failure is not
# carelessness -- the search was reasonable and the conclusion was correct:
#
#   A FILENAME SEARCH CANNOT FIND A GLOB-DRIVEN RUNNER'S CALLEES.
#
# The real survivor was in CM051 the whole time, and no search for "hub_chat"
# or "chat_probe" could have surfaced it -- NOR CAN THIS GATE, see control (19):
#
#   scripts/post_walk_qa.sh:112
#     -> scripts/box_walk_probes/run_box_walk.sh
#     -> for f in "$PROBE_DIR"/*.sh                (run_box_walk.sh:83)
#     -> probes/assistant_answers_grounded.sh
#
# and #978's walk-record gate makes that walk a precondition of promoting a
# build to customers. The chat behaviour IS proven before a customer sees it.
# Through the human box walk, not through CI.
#
# Two copies of one gate where only one is reachable is still worse than one
# copy: the dark one absorbs the attention the live one needs. That part stood.
#
# ============================================================================
# THIS GATE TAKES --repo, AND HAD ONLY EVER BEEN POINTED AT CM051
# ============================================================================
#
# 2026-08-23. One command, no runner, no network:
#
#   OSTLER_CUT_ENTRYPOINTS='bin/cut.sh' \
#     bash scripts/verify_declared_gates_reachable.sh --repo <OS003>
#   -> 3 of 8 reachable, rc=1
#
# Without the entry-point declaration it reports 2 of 8 and scores bin/cut.sh
# itself an orphan -- a FALSE orphan, because a human starts it by hand and
# this gate's built-in entry points are .github/workflows/* and Makefile.
# Declaring the operator road is what OSTLER_CUT_ENTRYPOINTS is for.
#
# The five real orphans share one root cause -- reachable only from
# pipeline/release.yml -- and one of them matters more than the rest:
#
#   gates/reconcile_gates.sh reads release.toml [gates].required, THE DECLARED
#   LIST OF GATES THAT BLOCK A RELEASE, and reconciles it against computed
#   verdicts. Its only call site is pipeline/release.yml:238.
#
# Not every OS003 orphan is a hole. vendor/verify_vendor_fresh.sh is dark THERE
# and live HERE (.github/workflows/vendor-integrity.yml:150, every PR). Two
# copies, one reachable: check which one before wiring anything.
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

# Does this workflow fire on the event that MAKES A CUT -- a push of a v1.0.*
# tag? `is_entry_point` above says yes to every workflow, which is right for
# "can the cut reach this file at all" and wrong for "does this run when the
# cut runs". Both questions are worth asking; AXIS THREE asks the second.
#
# THE THREE `push:` SHAPES, and getting this wrong is easy:
#   push:                    -> bare. Fires on branches AND tags.        YES
#   push: {tags: [...]}      -> tags.                                     YES
#   push: {branches: [...]}  -> branches ONLY. A tag push does NOT fire.  NO
# The third is the one that looks like coverage and is not. Measured on this
# repo: 94 workflows are entry points on the any-trigger axis; ONE fires on a
# cut tag.
# The operator and the ORM run `make` by hand at cut time, so a Makefile is an
# entry point on BOTH axes. Split out of is_entry_point so axis three can take
# the Makefile half without the every-workflow half.
is_makefile_entry() {
    case "$1" in
        Makefile|makefile|GNUmakefile|*/Makefile|*/makefile|*.mk) return 0 ;;
    esac
    return 1
}

fires_on_cut_tag() {
    case "$1" in .github/workflows/*) ;; *) return 1 ;; esac
    python3 - "$1" <<'CUTTAGPY'
import sys, yaml
try:
    d = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    sys.exit(1)                      # unparseable is NOT "fires"; it is unknown
on = d.get(True, d.get("on"))
# `on:` has THREE legal shapes and only one is a mapping. YAML gives back a
# STRING for `on: push` and a LIST for `on: [push, pull_request]`, so a bare
# isinstance(on, dict) test silently scores both as "does not fire on a tag"
# -- the exact opposite of this file's own finding that an unfiltered push
# fires on branches AND tags. Measured on this repo: 0 of 95 workflows use the
# scalar or list form, so the estate number is unaffected; the TEST FIXTURE
# uses `on: push` and was mis-scored, which is how this was found.
if isinstance(on, str):
    sys.exit(0 if on == "push" else 1)
if isinstance(on, list):
    sys.exit(0 if "push" in on else 1)
if not isinstance(on, dict) or "push" not in on:
    sys.exit(1)
push = on["push"]
if push is None:                     sys.exit(0)   # bare push: branches AND tags
if not isinstance(push, dict):       sys.exit(1)
if "tags" in push:                   sys.exit(0)
if "branches" in push:               sys.exit(1)   # branches only -> no tags
sys.exit(0)
CUTTAGPY
}

DECLARE_RE='BLOCK THE CUT|BLOCKS THE CUT|CUT BLOCKER|blocks? the release|MUST NOT SHIP|DO NOT ASSEMBLE'

# ===========================================================================
# AXIS TWO: REACHABLE IS NOT THE SAME AS ABLE TO SAY NO
# ===========================================================================
#
# Axis one asks "can the cut GET to this gate". A gate can pass that and still
# be useless, because a gate that runs, passes, and is blind to the defect it
# names is worse than one that does not run: the green is read as coverage.
# Measured examples from this estate, all of them gates that were REACHABLE:
#
#   #666  the cut-freshness self-test carried two DEAD controls -- (a) and (c)
#         could not fail -- so the gate had no proof it detects a stale daemon.
#   #662  a bundle-phase gate read project.yml and never the pbxproj it claimed
#         to gate. Green on a tree where the guarded artefact was wrong.
#   #713  every box_walk_probe row had ALWAYS returned SKIP, and SKIP does not
#         fail the cut. A gate that has only ever abstained.
#
# So the second axis is: has this gate ever been SHOWN to fail? A known-failing
# fixture is the only evidence that separates "found nothing" from "cannot see".
#
# WHAT COUNTS AS PROOF, AND WHY IT IS NOT "HAS A SELF-TEST"
#
# The obvious predicate -- does the file contain --self-test -- was measured
# first and is wrong in both directions on this very tree. It reports 3 of 12,
# and two of the misses (verify_cut_freshness.sh, verify_no_orphaned_fixes.sh)
# have thorough known-failing suites living in a SEPARATE file. Scoring those
# unguarded is the same error as pinning a predicate to a rendering: it asserts
# the FORMATTING of a proof rather than its existence.
#
# The next predicate tried -- any file naming the gate and comparing a status
# to non-zero -- is wrong the other way, and worse. On this tree it blessed
# bin/rollforward_gate.sh on the strength of a MARKDOWN file, and blessed
# run_all_cut_gates.sh (a known orphan) on an @echo in a Makefile plus a
# mention in a comment. False green, which is the direction this file exists to
# refuse.
#
# The discriminator that actually separates them is what a proof DOES with the
# non-zero: a proof treats it as a PASS. A consumer treats it as a failure.
#
#   proof     [ "$rc_red" -eq 1 ] && ok "(9) exits 1 when orphans exist"
#   proof     if [ "$rc" -ne 0 ]; then pass "unreachable repo fails closed"
#   consumer  if [ "$rc" -ne 0 ]; then echo "gate failed"; exit 1; fi
#
# Measured over the 9 relevant files here, that predicate returns exactly the
# 4 known proofs and exactly 0 of the 5 known non-proofs. Stated as a
# denominator rather than a vibe: 4/4 detected, 0/5 false.
#
# A proof must also be REACHABLE, by the same fixpoint as axis one. A
# known-failing fixture nobody runs is a description of a proof, not a proof.
#
# ESCAPE HATCH, deliberately explicit rather than clever. A gate whose proof
# does not match the shape above declares it:
#
#     # PROVED-RED-BY: tests/test_my_gate.sh
#
# and the named file is then checked the same way (exists, reachable, names
# this gate, contains the red-as-pass shape). Registering a proof is cheap;
# being credited for one that cannot fail is what this axis exists to stop.
#
# ADVISORY, WITH A RATCHET. This axis reports a ratio and does NOT fail the
# run on the existing backlog, because turning it blocking today would red-line
# a main branch that has carried these gaps for months, and a permanent red
# teaches people that red means nothing -- the exact failure this file's header
# already warns about. It is not decorative either: OSTLER_PROVED_RED_FLOOR
# fails the run if the proven count DROPS. Set OSTLER_REQUIRE_PROVED_RED=1 to
# make any unproven gate blocking once the backlog is cleared.
# ===========================================================================

# A status-ish variable compared against a NON-ZERO expectation.
RED_CMP_RE='(-ne[[:space:]]+0|-eq[[:space:]]+[1-9]|-gt[[:space:]]+0|!=[[:space:]]*0)'
# The taken branch registers a PASS. This is the whole discriminator.
PASS_MARK_RE='(^|[^[:alnum:]_])(ok|pass|PASS|good)([[:space:]]|\()'
# How many lines after the comparison the pass marker may sit. Two covers the
# `if ...; then` / `ok ...` split without swallowing an unrelated later block.
RED_PROOF_WINDOW=2

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

# ---------------------------------------------------------------------------
# is_red_proof_for <proof_file> <gate_basename>
#
# True when <proof_file> both NAMES the gate on a line of real code and treats
# a non-zero exit from something as a PASS. See the AXIS TWO block above for
# why the pass marker, and not the comparison, is the load-bearing half.
#
# Both halves are taken from code_lines, so a proof that has been commented
# out cannot count. `ok` and `pass` survive that filter deliberately: they are
# assertion helpers, not members of the echo/printf output family it drops.
# If a future rename makes a pass helper look like an output statement, this
# reports the gate as UNPROVEN, which is the safe direction.
# ---------------------------------------------------------------------------
# NEVER `grep -q` HERE, AND THIS IS NOT STYLE. This file runs under
# `set -o pipefail`. `grep -q` exits the moment it matches, closing the pipe;
# the upstream greps then die of SIGPIPE, and pipefail promotes that to a
# non-zero pipeline status -- so a SUCCESSFUL match reports as no match.
#
# It is worse than a plain bug because it is SIZE-DEPENDENT. Small proof files
# finish writing before the -q exits and look fine; the 783-line freshness
# suite does not, and was silently scored unproven while three smaller ones
# passed. A predicate whose answer depends on how fast a pipe drains is the
# same family of defect this gate exists to find, so it is spelled out rather
# than quietly fixed. Count with -c, compare the count.
esc() { printf '%s' "$1" | tr '/' '%'; }

# The code text of a file, from the fixpoint's cache when it is a graph node,
# built once and cached otherwise. Re-running code_lines per candidate made
# this axis quadratic and it stopped finishing -- the same trap the fixpoint
# comment above already records, met a second time by the same author.
code_file_for() {
    local f="$1" n k
    n="$(cat "$TMP/id/$(esc "$f")" 2>/dev/null)"
    if [ -n "$n" ] && [ -f "$TMP/code/$n.txt" ]; then printf '%s' "$TMP/code/$n.txt"; return 0; fi
    k="$TMP/code/ext_$(esc "$f").txt"
    [ -f "$k" ] || code_lines "$f" > "$k" 2>/dev/null
    printf '%s' "$k"
}

has_red_shape() {   # $1 = a code-text file
    local reds
    reds="$(grep -E "$RED_CMP_RE" -A "$RED_PROOF_WINDOW" "$1" 2>/dev/null \
            | grep -cE "$PASS_MARK_RE")"
    [ "${reds:-0}" -gt 0 ]
}

is_red_proof_for() {
    local proof="$1" gate_bn="$2" cf named
    [ -f "$proof" ] || return 1
    is_caller_file "$proof" || return 1
    cf="$(code_file_for "$proof")"
    named="$(grep -cF "$gate_bn" "$cf" 2>/dev/null)"
    [ "${named:-0}" -gt 0 ] || return 1
    has_red_shape "$cf"
}

# A file proving ITSELF red cannot be found by name: every self-test in this
# estate re-invokes itself through "$SELF" or ${BASH_SOURCE}, never by typing
# its own filename. Requiring the name here scored both real self-testing gates
# as unproven.
#
# The self-invocation is also what keeps this HONEST. A companion suite like
# tests/test_cut_freshness_gate.sh is full of red-as-pass assertions, but they
# are about $GATE -- another file. Crediting it for proving ITSELF would let a
# suite that can never fail vouch for its own reliability, which is #666
# exactly. So the self case demands the file run ITSELF, not merely contain
# assertions.
SELF_INVOKE_RE='(bash|sh|python3?|exec)[[:space:]]+"?\$\{?(SELF|BASH_SOURCE|0)'
proves_itself_red() {
    local g="$1" cf
    grep -qE 'SELF_TEST|--self-test' "$g" 2>/dev/null || return 1
    cf="$(code_file_for "$g")"
    grep -qE "$SELF_INVOKE_RE" "$cf" 2>/dev/null || return 1
    has_red_shape "$cf"
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
        mkdir -p "$r/scripts" "$r/docs" "$r/gui" "$r/cut-manifests" "$r/tests"
        for g in called_gate var_called_gate; do
            printf '#!/bin/sh\n# Non-zero = BLOCK THE CUT.\nexit 0\n' > "$r/scripts/$g.sh"
        done
        cat > "$r/gui/Makefile" <<'MK'
GATE_SH ?= $(CURDIR)/../scripts/var_called_gate.sh
check:
	bash scripts/called_gate.sh
	bash scripts/proven_gate.sh
	bash tests/test_proven_gate.sh
	bash scripts/consumed_gate.sh
	bash scripts/consumer.sh
	bash scripts/prose_gate.sh
	bash scripts/glob_runner.sh
	bash scripts/darkly_proven_gate.sh
	bash scripts/falsely_registered_gate.sh
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

            # A GLOB-DRIVEN RUNNER and the probe it really does execute. The
            # runner is reachable; the probe is named literally NOWHERE.
            mkdir -p "$r/scripts/probes"
            {
              printf '#!/bin/sh\n'
              printf '# Non-zero = BLOCK THE CUT.\n'
              printf 'for f in "$(dirname "$0")"/probes/*.sh; do bash "$f"; done\n'
            } > "$r/scripts/glob_runner.sh"
            printf '#!/bin/sh\n# Non-zero = BLOCK THE CUT.\nexit 0\n' \
                > "$r/scripts/probes/glob_probe_gate.sh"
            # A DATA yaml that declares a blocking rule. Belongs in the second
            # population, never in the orphan list.
            printf 'version: v1.0.11\nnote: this manifest MUST NOT SHIP unverified\n' \
                > "$r/cut-manifests/v1.0.11.yaml"

            # ---- AXIS TWO fixture. Each case below is a mistake this axis
            # ---- actually made in development, kept as the control that
            # ---- caught it.

            # (A) A gate with a REAL proof: a companion that runs it on a
            #     broken fixture and treats non-zero as a PASS.
            printf '#!/bin/sh\n# Non-zero = BLOCK THE CUT.\nexit 0\n' > "$r/scripts/proven_gate.sh"
            {
              printf '#!/bin/sh\n'
              printf 'bash scripts/proven_gate.sh --broken; rc=$?\n'
              printf '[ "$rc" -ne 0 ] && ok "RED: it blocks a broken tree"\n'
              # PADDING, and it is load-bearing. The first version of the
              # predicate used `grep -q`, which closes the pipe on match; under
              # pipefail the upstream grep dies of SIGPIPE and a SUCCESSFUL
              # match reports as failure. That is SIZE-DEPENDENT: it passed on
              # short files and silently scored the 783-line freshness suite
              # unproven. A small fixture cannot see it, so this one is not
              # small.
              i=0; while [ "$i" -lt 3000 ]; do printf 'true  # filler line %s\n' "$i"; i=$((i+1)); done
            } > "$r/tests/test_proven_gate.sh"

            # (B) A gate whose only companion CONSUMES it -- runs it and
            #     treats non-zero as a failure. Not a proof. The loose version
            #     of this predicate credited exactly this shape.
            printf '#!/bin/sh\n# Non-zero = BLOCK THE CUT.\nexit 0\n' > "$r/scripts/consumed_gate.sh"
            printf '#!/bin/sh\nbash scripts/consumed_gate.sh; rc=$?\nif [ "$rc" -ne 0 ]; then exit 1; fi\n' \
                > "$r/scripts/consumer.sh"

            # (C) A gate "proved" only by PROSE. A markdown file with a red
            #     comparison in it credited bin/rollforward_gate.sh on the
            #     first real run.
            printf '#!/bin/sh\n# Non-zero = BLOCK THE CUT.\nexit 0\n' > "$r/scripts/prose_gate.sh"
            printf 'When prose_gate.sh runs, if [ "$rc" -ne 0 ] then ok, it blocked.\n' \
                > "$r/docs/prose_gate_notes.md"

            # (D) A gate whose proof is real but UNREACHABLE. A fixture nobody
            #     runs proves nothing, and axis one already knows the file is
            #     dark -- the two axes must agree.
            printf '#!/bin/sh\n# Non-zero = BLOCK THE CUT.\nexit 0\n' > "$r/scripts/darkly_proven_gate.sh"
            printf '#!/bin/sh\nbash scripts/darkly_proven_gate.sh; rc=$?\n[ "$rc" -ne 0 ] && ok "RED"\n' \
                > "$r/scripts/unreachable_proof.sh"

            # (E) A registration that does not check out. Must be reported as
            #     WORSE than no registration, never silently ignored.
            {
              printf '#!/bin/sh\n'
              printf '# PROVED-RED-BY: tests/does_not_exist.sh\n'
              printf '# Non-zero = BLOCK THE CUT.\nexit 0\n'
            } > "$r/scripts/falsely_registered_gate.sh"
        fi
        ( cd "$r" && git init -q . && git add -A \
          && git -c user.email=t@t -c user.name=t commit -qm fixture ) >/dev/null 2>&1
    }

    build_fixture "$d/red" with-orphans
    build_fixture "$d/green" clean

    OUT="$d/red.out"
    bash "$SELF" --repo "$d/red" > "$OUT" 2>&1; rc_red=$?
    orphan_block() { sed -n '/^  ORPHANED/,$p' "$OUT"; }
    # Count, do not -q. See the block at the top of this file: `grep -q`
    # exits on first match, the upstream sed dies of SIGPIPE, and pipefail
    # turns a SUCCESSFUL match into a non-zero status. Measured: this exact
    # shape inverts once the orphan block passes about 1000 lines / 24KB.
    listed_orphan() { [ "$(orphan_block | grep -cF "scripts/$1.sh")" -gt 0 ]; }

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
    if [ "$(orphan_block | grep -cF 'cut-manifests/v1.0.11.yaml')" -gt 0 ]; then
        no "(8) a DATA yaml was judged on the invocation axis (permanent false red)"
    elif grep -qF 'cut-manifests/v1.0.11.yaml' "$OUT"; then
        ok "(8) a DATA yaml declarer is reported under NOT MEASURED, not as an orphan"
    else
        no "(8) the data-yaml declarer vanished entirely -- it must still be COUNTED"
    fi
    # (19) A GLOB CALL SITE IS NOT RESOLVED, AND THAT IS THE DELIBERATE ANSWER.
    #
    # scripts/glob_runner.sh IS reachable and genuinely executes
    # scripts/probes/glob_probe_gate.sh, whose name appears nowhere. The gate
    # reports the probe as an ORPHAN.
    #
    # PINNED, NOT FIXED, and the reason is this file's own error-direction
    # rule: "an over-tight predicate reports an extra orphan, which is noise a
    # human resolves in a minute. An over-loose one blesses a dark gate, which
    # is invisible forever." Expanding globs to decide reachability is the
    # over-loose direction, so the miss is the safe one.
    #
    # 🔴 IT IS NOT FREE, and axis one is BLOCKING now. The day a box-walk probe
    # writes "BLOCK THE CUT" in its header, this gate reports a FALSE ORPHAN and
    # stops main. Measured 2026-08-23: 0 of the box_walk probes declare
    # themselves blocking, against 23 declarers tree-wide, so the risk is latent
    # rather than live. If it goes live, add the runner's directory to an
    # explicit allowance -- do NOT widen the predicate to expand globs.
    #
    # This control exists so the limit is a DECISION with a fixture, not an
    # accident somebody later "fixes" into a false green.
    [ "$(orphan_block | grep -cF 'scripts/probes/glob_probe_gate.sh')" -gt 0 ] \
        && ok "(19) LIMIT PINNED: a glob-reached gate reads as an orphan (safe direction)" \
        || no "(19) a glob call site is now resolved -- CHECK IT CANNOT BLESS A DARK GATE"

    listed_orphan glob_runner \
        && no "(20) the glob RUNNER was called an orphan -- (19) proves nothing then" \
        || ok "(20) CONTROL: the glob runner itself IS reachable, so (19) is about the glob"

    [ "$rc_red" -eq 1 ] && ok "(9) exits 1 when orphans exist" \
                        || no "(9) orphans present but exit code was ${rc_red}"

    # ---- AXIS TWO --------------------------------------------------------
    # MATCH AN EXPLICIT TOKEN, NEVER A REGION OF THE LAYOUT. The first
    # version of these two helpers sliced the report by headings, and the
    # PROVED-RED slice ran on past its own list into the UNPROVEN one -- so
    # (11) reported PASS with its fixture file deleted, and (14) could not
    # fail either. Three of four new controls were blind, in the self-test of
    # the axis whose whole subject is instruments that cannot say no. Caught
    # only by mutating the fixture and watching what refused to go red.
    proved_ok()   { grep -qE "PROVED-RED-OK +$1( |\$)" "$OUT"; }
    proved_none() { grep -qE "PROVED-RED-NONE +$1( |\$)" "$OUT"; }

    proved_ok "scripts/proven_gate.sh" \
        && ok "(11) a companion that treats non-zero as a PASS counts as proof" \
        || no "(11) MISSED a real known-failing fixture -- axis two is blind"

    grep -c . "$d/red/tests/test_proven_gate.sh" | grep -qE '^[0-9]{4,}' \
        && ok "(12) that proof file is >=1000 lines, so (11) also covers the SIGPIPE race" \
        || no "(12) fixture shrank: a short proof cannot exercise the pipefail race"

    proved_none "scripts/consumed_gate.sh" \
        && ok "(13) a CONSUMER of the gate is not a proof of it" \
        || no "(13) a consumer was credited as a known-failing fixture"

    # (14) WAS "PROSE naming a gate is not a proof", and it was DELETED as a
    # dead control. A .md is not a caller file, so it never enters the node
    # set, never enters the reachable set, and can never be a proof candidate
    # -- the control could not fail under any mutation of the fixture. It read
    # as coverage of the doc-vs-code rule while proving nothing, which is #666
    # in the self-test of the axis that exists to find #666. The rule it aimed
    # at is enforced upstream by is_caller_file and is genuinely exercised by
    # control (8). Caught by mutating the fixture and noticing which controls
    # refused to go red; three of the four new ones were blind on first write.

    proved_none "scripts/darkly_proven_gate.sh" \
        && ok "(15) a proof the cut cannot reach does not count" \
        || no "(15) an unreachable fixture was credited"

    grep -q "PROVED-RED-NONE .*DECLARED PROOF DOES NOT CHECK OUT" "$OUT" \
        && ok "(16) a PROVED-RED-BY pointing at nothing is reported, not ignored" \
        || no "(16) a broken registration was silently treated as absent"

    # THE RATCHET, proved in both directions. A floor that cannot fire is the
    # same defect as a gate that cannot fail.
    OSTLER_PROVED_RED_FLOOR=99 bash "$SELF" --repo "$d/green" >/dev/null 2>&1; rc_floor=$?
    [ "$rc_floor" -eq 1 ] && ok "(17) RATCHET: an unreachable floor fails the run" \
                          || no "(17) the proved-red floor cannot fail (exit ${rc_floor})"
    OSTLER_PROVED_RED_FLOOR=0 bash "$SELF" --repo "$d/green" >/dev/null 2>&1; rc_floor0=$?
    [ "$rc_floor0" -eq 0 ] && ok "(18) RATCHET CONTROL: a satisfied floor still passes" \
                           || no "(18) the floor fails even when met (exit ${rc_floor0}) -- unusable"

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

# --- AXIS TWO: has each gate ever been shown to FAIL? ----------------------
# Reuses the reachable set computed above. That reuse is the reason this lives
# inside this file rather than beside it: a sibling scanner would need its own
# copy of the fixpoint, and two enumerations of one population drift. They have
# already drifted once here -- a scanner of mine found 3 declaring files where
# this gate finds ${exec_total}.
# PASS ONE: which reachable files carry the red-as-pass shape at all. One scan
# each, off the fixpoint's cached code text.
: > "$TMP/proofcap"
while IFS= read -r p; do
    is_caller_file "$p" || continue
    pcf="$(code_file_for "$p")"
    has_red_shape "$pcf" && echo "$p" >> "$TMP/proofcap"
done < "$TMP/reach"
proofcap_n=$(wc -l < "$TMP/proofcap" | tr -d ' ')

proved=0
: > "$TMP/unproved"
: > "$TMP/proofmap"
while IFS= read -r g; do
    gb="$(basename "$g")"
    proof=""

    # An explicit registration wins, and is checked, not taken on trust.
    declared_proof="$(grep -m1 -E '^[[:space:]]*#[[:space:]]*PROVED-RED-BY:' "$g" 2>/dev/null \
                      | sed -E 's/.*PROVED-RED-BY:[[:space:]]*//' | tr -d '[:space:]')"
    if [ -n "$declared_proof" ]; then
        # A gate may register ITSELF, for a self-test this predicate cannot
        # infer -- verify_cut_pin_is_current.sh drives its red control through
        # an internal helper rather than re-executing itself, so no textual
        # rule short of over-fitting will find it. Self-registration still has
        # to carry the red-as-pass shape; only the name check is dropped,
        # because a file does not type its own filename.
        if [ "$declared_proof" = "$g" ]; then
            if has_red_shape "$(code_file_for "$g")"; then
                proof="$g (declared self-test)"
            else
                echo "${g}|DECLARED SELF-PROOF HAS NO RED ASSERTION" >> "$TMP/unproved"
                continue
            fi
        elif grep -qxF "$declared_proof" "$TMP/reach" && is_red_proof_for "$declared_proof" "$gb"; then
            proof="$declared_proof (declared)"
        else
            # A registration that does not check out is worse than none: it
            # reads as coverage. Say so rather than falling back silently.
            echo "${g}|DECLARED PROOF DOES NOT CHECK OUT: ${declared_proof}" >> "$TMP/unproved"
            continue
        fi
    fi

    if [ -z "$proof" ]; then
        # Itself, then any reachable caller-file. Unreachable proofs are
        # skipped on purpose: a fixture nobody runs proves nothing.
        if proves_itself_red "$g"; then
            proof="$g (own self-test)"
        else
            # Only files already known to carry the red-as-pass shape are
            # candidates, so this scans a handful rather than the whole
            # reachable set once per gate.
            while IFS= read -r p; do
                [ "$p" = "$g" ] && continue
                if is_red_proof_for "$p" "$gb"; then proof="$p"; break; fi
            done < "$TMP/proofcap"
        fi
    fi

    if [ -n "$proof" ]; then
        proved=$((proved + 1))
        echo "    PROVED-RED-OK    ${g}  <-  ${proof}" >> "$TMP/proofmap"
    else
        echo "${g}|no known-failing fixture" >> "$TMP/unproved"
    fi
done < "$TMP/decl_exec"

unproved_n=$(wc -l < "$TMP/unproved" | tr -d ' ')
echo
echo "  PROVED RED: ${proved} of ${exec_total} have a known-failing fixture -- a run in which"
echo "  the gate was SHOWN to fail. The rest may be correct; nothing has demonstrated"
echo "  they can say no, and a gate that cannot say no is read as coverage."
if [ -s "$TMP/proofmap" ]; then
    echo
    echo "  proven, and by what:"
    cat "$TMP/proofmap"
fi
if [ "$unproved_n" -gt 0 ]; then
    echo
    echo "  NO KNOWN-FAILING FIXTURE:"
    while IFS='|' read -r f why; do echo "    PROVED-RED-NONE  ${f}  (${why})"; done < "$TMP/unproved"
    echo
    echo "  Fix by adding a fixture that BREAKS the thing the gate names, asserting the"
    echo "  gate exits non-zero on it, and a green control proving it can still pass. A"
    echo "  red-only instrument gets bypassed; a green-only one gets believed."
    echo "  Register an unusual proof with a '# PROVED-RED-BY: <path>' header."
fi

# The ratchet. Advisory on the standing backlog, blocking on a REGRESSION, so
# this axis is not decorative while the backlog is worked off.
floor="${OSTLER_PROVED_RED_FLOOR:-}"
axis_two_fail=0
if [ -n "$floor" ] && [ "$proved" -lt "$floor" ]; then
    echo >&2
    echo "  PROVED-RED REGRESSION: ${proved} proven, floor is ${floor}." >&2
    echo "  A gate that had a known-failing fixture no longer does. Restore it, or" >&2
    echo "  lower OSTLER_PROVED_RED_FLOOR in the same commit that removes the proof" >&2
    echo "  and say why -- so the loss is a decision in the log, not an erosion." >&2
    axis_two_fail=1
fi
if [ "${OSTLER_REQUIRE_PROVED_RED:-0}" = "1" ] && [ "$unproved_n" -gt 0 ]; then
    echo >&2
    echo "  OSTLER_REQUIRE_PROVED_RED=1 and ${unproved_n} gate(s) have no known-failing" >&2
    echo "  fixture. Blocking." >&2
    axis_two_fail=1
fi

# --- AXIS THREE: reachable is not the same as RUNS ON THE CUT --------------
#
# Axis one seeds the fixpoint with EVERY workflow, so "reachable from the cut"
# means "reachable from something that runs sometime". A gate invoked only by a
# workflow that never fires on a tag push is reachable and does not run on the
# cut. #1167 measured two of those executing ZERO times at the commit v1.0.48
# was cut from, while axis one reported full coverage.
#
# THIS IS A RATCHET, NOT A FLIP. Re-seeding the existing verdict would turn
# seven declarers orphan at once and block every cut, which is how a gate gets
# commented out. So the current state is RECORDED in a baseline and only
# GROWTH fails. Shrinking the baseline is always allowed.
axis_three_fail=0
A3_BASELINE="${OSTLER_CUT_TRIGGER_BASELINE:-$REPO_ROOT/scripts/cut_trigger_reachability_baseline.tsv}"

: > "$TMP/reach3"
while IFS= read -r f; do
    if fires_on_cut_tag "$f" || is_makefile_entry "$f"; then echo "$f" >> "$TMP/reach3"; fi
done < "$TMP/nodes"
IFS=':' read -r -a _a3_extra <<< "${OSTLER_CUT_ENTRYPOINTS:-}"
for _e in "${_a3_extra[@]:-}"; do
    [ -n "$_e" ] && grep -qxF "$_e" "$TMP/nodes" && echo "$_e" >> "$TMP/reach3"
done
sort -u "$TMP/reach3" -o "$TMP/reach3"
a3_seeds="$(wc -l < "$TMP/reach3" | tr -d ' ')"   # SEEDS, counted before the BFS grows the set

if [ ! -s "$TMP/reach3" ]; then
    # Nothing fires on a tag. That is not "everything is fine"; it is a broken
    # probe, and it must not print a clean axis.
    echo >&2
    echo "  AXIS THREE CANNOT RUN: no workflow fires on a cut tag, so the" >&2
    echo "  cut-trigger reachable set is empty and every gate would look" >&2
    echo "  unreachable. Not reporting this axis, and FAILING rather than" >&2
    echo "  passing: a probe that cannot see is not a clean result." >&2
    echo "  (If you are looking at a minimal fixture, check fires_on_cut_tag" >&2
    echo "   handles its \`on:\` shape before assuming the repo is at fault.)" >&2
    axis_three_fail=1
else
    cp "$TMP/reach3" "$TMP/frontier3"
    while [ -s "$TMP/frontier3" ]; do
        : > "$TMP/next3"
        while IFS= read -r r; do
            n="$(cat "$TMP/id/$(esc "$r")" 2>/dev/null)"
            [ -n "$n" ] || continue
            grep -oFf "$TMP/basenames" "$TMP/code/$n.txt" 2>/dev/null | sort -u \
            | while IFS= read -r b; do [ -f "$TMP/bn/$b" ] && cat "$TMP/bn/$b"; done \
            | sort -u \
            | while IFS= read -r cand; do
                [ "$cand" = "$r" ] && continue
                grep -qxF "$cand" "$TMP/reach3" && continue
                echo "$cand" >> "$TMP/next3"
              done
        done < "$TMP/frontier3"
        if [ -s "$TMP/next3" ]; then
            sort -u "$TMP/next3" -o "$TMP/next3"
            : > "$TMP/next3b"
            while IFS= read -r c; do
                grep -qxF "$c" "$TMP/reach3" || { echo "$c" >> "$TMP/reach3"; echo "$c" >> "$TMP/next3b"; }
            done < "$TMP/next3"
            mv "$TMP/next3b" "$TMP/frontier3"
        else
            : > "$TMP/frontier3"
        fi
    done

    : > "$TMP/a3_dark"
    a3_reach=0
    while IFS= read -r f; do
        if grep -qxF "$f" "$TMP/reach3"; then
            a3_reach=$((a3_reach + 1))
        elif grep -qxF "$f" "$TMP/reach"; then
            # reachable on axis one, NOT under the cut trigger -- the gap
            echo "$f" >> "$TMP/a3_dark"
        fi
    done < "$TMP/decl_exec"

    a3_dark_n="$(wc -l < "$TMP/a3_dark" | tr -d ' ')"
    echo
    echo "  AXIS THREE -- runs on the cut, not merely reachable:"
    echo "    ${a3_reach} of ${exec_total} declarers are reachable from a CUT-TAG entry point"
    echo "    (${a3_seeds} such entry point(s); axis one seeded ${entries})."

    : > "$TMP/a3_new"
    if [ -r "$A3_BASELINE" ]; then
        while IFS= read -r d; do
            grep -qxF "$d" <(grep -vE '^#|^$' "$A3_BASELINE" | cut -f1) || echo "$d" >> "$TMP/a3_new"
        done < "$TMP/a3_dark"
    else
        cp "$TMP/a3_dark" "$TMP/a3_new"
        [ -s "$TMP/a3_new" ] && echo "    (no baseline at ${A3_BASELINE}; every gap below is NEW)"
    fi

    if [ "$a3_dark_n" -gt 0 ]; then
        echo "    ${a3_dark_n} declare cut-blocking, are reachable, and do NOT run on a tag push:"
        while IFS= read -r d; do echo "      ${d}"; done < "$TMP/a3_dark"
    fi
    if [ -s "$TMP/a3_new" ]; then
        echo >&2
        echo "  NEW on axis three -- not in ${A3_BASELINE##*/}:" >&2
        while IFS= read -r d; do echo "    ${d}" >&2; done < "$TMP/a3_new"
        echo >&2
        echo "  Either wire it to a runner that fires on a v1.0.* tag, or add a row" >&2
        echo "  to the baseline WITH A REASON. The baseline may shrink freely; it" >&2
        echo "  may only grow by someone writing down why." >&2
        axis_three_fail=1
    fi
fi

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

echo
echo "  no orphans."
[ "$axis_two_fail" -eq 1 ] && exit 1
[ "${axis_three_fail:-0}" -eq 1 ] && exit 1
exit 0
