#!/usr/bin/env bash
#
# verify_cut_pin_is_current.sh -- the CM051 pin in cuts/<tag>/cut.env must name
# a tree whose install.sh is the one being shipped. Compared BY BLOB, failing
# closed. Non-zero = BLOCK THE CUT.
#
# PROVED-RED-BY: scripts/verify_cut_pin_is_current.sh
#
# Registered by hand because the axis-two predicate in
# verify_declared_gates_reachable.sh cannot infer this one, and the reason is
# worth stating rather than working around.
#
# That predicate looks for a fixture that re-invokes the gate AS A SUBPROCESS
# (`bash "$SELF" ...`) and then asserts a non-zero status. This gate's
# `--self-test` instead calls `run_gate` DIRECTLY, in-process, because the gate
# proper was deliberately factored into a function so the self-test drives THE
# SAME CODE rather than a re-implementation of it (see the note at the top of
# run_gate). That is the better construction and it is invisible to a
# subprocess-shaped search: PROVED-RED-NONE here meant "not recognised", never
# "not proven".
#
# What is actually proven, from `--self-test`, 9 passed / 0 failed:
#   (1) RED   a pin whose install.sh predates the fix exits 1
#   (4) RED   fires even though the pin IS an ancestor of the ref, which is the
#             exact excuse that would otherwise wave the red away
#   (5) GREEN re-pointing the pin exits 0, so it can say yes as well as no
#   (7)(8)(9) CANNOT-RUN limbs each exit 2, never 0
#
# Control (1) reproduces the v1.0.31 shape described below on a real git
# fixture, so this is a known-failing fixture in the full sense: the gate is
# shown to detect the specific defect it was written for.
#
# ============================================================================
# WHY THIS EXISTS, AND IT IS NOT HYPOTHETICAL
# ============================================================================
#
# 2026-08-16. v1.0.31 existed for one reason: v1.0.31's predecessor shipped a
# DMG whose Hub could not start. `ostler-assistant daemon` crash-looped on the
# LaunchAgent KeepAlive every ten seconds with `missing field backend`, because
# install.sh wrote a [memory] table that was PRESENT AND PARTIAL, and a partial
# table silently disarms the serde default that had been covering it.
#
# Three commits fixed it and merged: #745, #748, #751.
#
# And cuts/v1.0.31/cut.env still pinned CM051=f219eb0, whose install.sh predates
# all three. Cutting v1.0.31 from its own declared pin would have shipped the
# exact defect v1.0.31 was created to fix.
#
# ANCESTRY WOULD HAVE CALLED THAT FINE. f219eb0 IS an ancestor of main. Ancestry
# proves ordering and says nothing about content, which is why the predicate
# here is blob identity and why the cut record specifies blobs too.
#
# ============================================================================
# THE SAFEGUARD THAT EXISTED WAS A SENTENCE
# ============================================================================
#
# cut.env already documented all of this. Its own words:
#
#     "the pin must name a tree whose install.sh is the one in the DMG"
#     "VERIFIED BY BLOB IDENTITY rather than by ancestry, because ancestry
#      proves ordering and says nothing about content"
#     "RE-VERIFY IMMEDIATELY BEFORE PUSHING THE TAG: compare the two blob shas
#      above and re-point if they diverge."
#
# It even records that the v1.0.27 key had to be re-pointed TWICE for this same
# reason, and warns that "a pin chosen early and trusted is a pin that goes
# stale while you are not looking."
#
# It was right about everything except the mechanism. An instruction addressed
# to a human at tag time cannot fail closed, and this one did not: the note was
# accurate when written at 00:50 and false by morning, and nothing said so.
#
# This script is that paragraph, moved out of prose and into an exit code.
#
# ============================================================================
# WHAT IT COMPARES, AND WHY ONLY THIS
# ============================================================================
#
# The CM051 pin exists so a gate can fetch install.sh AT THAT REF. So the only
# question that matters is whether that ref's install.sh is byte-identical to
# the one in the tree being cut. Not whether the pin is recent, not whether it
# is an ancestor, not whether the commit subjects look relevant. One blob
# against one blob.
#
# DAEMON_COMMIT is deliberately NOT checked here. It names a commit in a
# different repository, which this gate cannot resolve offline, and a gate that
# silently skips half its declared job is worse than one that scopes itself
# honestly. It is reported as NOT CHECKED, every run, so the coverage gap is
# visible rather than assumed closed.
#
# British English throughout; " -- " not em-dashes.

set -uo pipefail

SELF_TEST=0
REPO_ARG=""
CUT_ARG=""
REF_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --self-test) SELF_TEST=1; shift ;;
        --repo)      REPO_ARG="${2:-}"; shift 2 ;;
        --cut)       CUT_ARG="${2:-}";  shift 2 ;;
        --ref)       REF_ARG="${2:-}";  shift 2 ;;
        -h|--help)
            echo "usage: $0 [--repo <path>] [--cut <tag>] [--ref <git-ref>] [--self-test]"
            echo "  --cut  tag whose cuts/<tag>/cut.env to read (default: newest cuts/v*)"
            echo "  --ref  the ref actually being cut          (default: HEAD)"
            exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# The gate proper, as a function, so the self-test drives THE SAME CODE.
#
# The previous gate I wrote this week carried an inline copy of its own
# algorithm in its self-test, which proved a copy correct and said nothing
# about what shipped. Not repeating that.
#
# EXIT: 0 green, 1 pin is stale (BLOCK), 2 CANNOT-RUN (never a pass).
# ---------------------------------------------------------------------------
run_gate() {
    local repo="$1" cut="$2" ref="$3"

    cd "$repo" 2>/dev/null || { echo "CANNOT-RUN: cannot enter '$repo'" >&2; return 2; }
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "CANNOT-RUN: not a git repository" >&2; return 2; }

    # Which cut? An explicit tag wins; otherwise the newest cuts/v* by version
    # sort. NEVER lexical: "1.0.18" sorts before "1.0.8" lexically, which is
    # the mistake that once reported an old DMG as the newest one.
    if [ -z "$cut" ]; then
        cut="$(ls -1 cuts 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)"
    fi
    [ -n "$cut" ] || { echo "CANNOT-RUN: no cuts/v* directory found" >&2; return 2; }

    local env_file="cuts/${cut}/cut.env"
    [ -f "$env_file" ] || { echo "CANNOT-RUN: no ${env_file}" >&2; return 2; }

    # Read the key without sourcing. cut.env is written for a permissive shell
    # and may legitimately set variables this gate has no business inheriting.
    local pin
    pin="$(grep -E '^[[:space:]]*CM051=' "$env_file" | tail -1 | sed -E 's/^[[:space:]]*CM051=//; s/[[:space:]]*(#.*)?$//')"
    [ -n "$pin" ] || { echo "CANNOT-RUN: ${env_file} declares no CM051= pin" >&2; return 2; }

    # A pin that does not resolve is a broken probe, not a clean cut.
    local pin_sha
    pin_sha="$(git rev-parse --verify --quiet "${pin}^{commit}")" || {
        echo "CANNOT-RUN: CM051 pin '${pin}' does not resolve in this checkout" >&2
        echo "  A pin nobody can resolve cannot be compared, and an unresolvable" >&2
        echo "  pin must never read as agreement." >&2
        return 2; }

    local ref_sha
    ref_sha="$(git rev-parse --verify --quiet "${ref}^{commit}")" || {
        echo "CANNOT-RUN: ref '${ref}' does not resolve in this checkout" >&2; return 2; }

    # THE COMPARISON. Blob against blob.
    local pin_blob ref_blob
    pin_blob="$(git rev-parse --verify --quiet "${pin_sha}:install.sh")" || {
        echo "CANNOT-RUN: no install.sh at the pin ${pin}" >&2; return 2; }
    ref_blob="$(git rev-parse --verify --quiet "${ref_sha}:install.sh")" || {
        echo "CANNOT-RUN: no install.sh at ref ${ref}" >&2; return 2; }

    echo "cut-pin: ${cut}"
    echo "  pinned CM051   ${pin_sha}"
    echo "  ref being cut  ${ref_sha}  (${ref})"
    echo "  install.sh @pin ${pin_blob}"
    echo "  install.sh @ref ${ref_blob}"
    echo "  DAEMON_COMMIT   NOT CHECKED HERE (lives in another repository; this"
    echo "                  run says nothing about it either way)"

    if [ "$pin_blob" = "$ref_blob" ]; then
        echo "  PIN IS CURRENT -- the pinned tree's install.sh IS the one being cut."
        return 0
    fi

    # DIVERGED. Say WHAT changed, because "they differ" is not actionable and a
    # red nobody can act on gets bypassed.
    echo
    echo "  🔴 STALE PIN -- the pin does NOT name the install.sh being shipped." >&2
    echo >&2
    echo "  Commits touching install.sh between the pin and the ref:" >&2
    git log --oneline "${pin_sha}..${ref_sha}" -- install.sh 2>/dev/null | sed 's/^/      /' >&2
    echo >&2

    # THE ANCESTRY CONTROL, PRINTED EVERY TIME IT MATTERS. The single most
    # likely way this red gets waved away is "but the pin is on main". It can
    # be, and be wrong, and that is the whole reason the predicate is blobs.
    if git merge-base --is-ancestor "$pin_sha" "$ref_sha" 2>/dev/null; then
        echo "  NOTE: the pin IS an ancestor of the ref. That is not a defence." >&2
        echo "  Ancestry proves ordering and says nothing about content -- which is" >&2
        echo "  exactly why cut.env specifies blob identity and this gate obeys it." >&2
        echo >&2
    fi
    echo "  FIX: re-point CM051= in ${env_file} to the ref being cut, then re-run" >&2
    echo "  this AFTER the last merge rather than before it. A pin chosen early" >&2
    echo "  and trusted is a pin that goes stale while you are not looking." >&2
    return 1
}

# ===========================================================================
# SELF-TEST -- builds real git fixtures and runs run_gate over them.
#
# Expected value in the field is GREEN, and a gate that only ever reports
# green is indistinguishable from a gate that looks at nothing. So the RED
# limb is proven on a fixture that reproduces the v1.0.31 shape exactly:
# a pin that is a genuine ANCESTOR of the ref, with a different install.sh.
# ===========================================================================
if [ "$SELF_TEST" -eq 1 ]; then
    p=0; f=0
    ok() { printf '  PASS  %s\n' "$1"; p=$((p+1)); }
    no() { printf '  FAIL  %s\n' "$1"; f=$((f+1)); }
    d="$(mktemp -d -t cutpin-XXXXXX)"; trap 'rm -rf "$d"' EXIT
    HOME_REPO="$d/repo"
    mkdir -p "$HOME_REPO/cuts/v1.0.31"
    (
      cd "$HOME_REPO"
      git init -q .
      git config user.email t@t; git config user.name t
      printf 'echo "[memory]"\necho "embedding_model = x"\n' > install.sh
      git add -A && git commit -qm "old install.sh (no backend)"
      OLD="$(git rev-parse HEAD)"
      printf 'CM051=%s\n' "$OLD" > cuts/v1.0.31/cut.env
      git add -A && git commit -qm "cut record pinning the old tree"
      # The fix lands AFTER the pin, exactly as #745/#748/#751 did.
      printf 'echo "[memory]"\necho "backend = sqlite"\necho "embedding_model = x"\n' > install.sh
      git add -A && git commit -qm "fix(install): write memory.backend"
    ) >/dev/null 2>&1

    out="$d/red.out"
    ( run_gate "$HOME_REPO" "v1.0.31" "HEAD" ) > "$out" 2>&1; rc=$?

    [ "$rc" -eq 1 ] && ok "(1) RED: a pin whose install.sh predates the fix BLOCKS (exit 1)" \
                    || no "(1) stale pin did NOT block (exit ${rc}) -- the gate is blind"
    grep -q 'STALE PIN' "$out" && ok "(2) the message names the defect, not just a mismatch" \
                               || no "(2) no STALE PIN message"
    grep -q 'memory.backend' "$out" && ok "(3) it lists the install.sh commits that were left behind" \
                                    || no "(3) did not enumerate the missed commits"
    # -i, and matching a SUBSTRING rather than a whole rendering. The first
    # version of this line was `grep -q 'is an ancestor of the ref'` against a
    # message that says "IS an ancestor", and it reported the note missing when
    # the note was there. A case-sensitive grep is the same mistake that once
    # cleared a PII scrub on this estate; it cost nothing here only because it
    # failed loudly instead of quietly.
    grep -qi 'ancestor of the ref' "$out" \
        && ok "(4) ANCESTRY CONTROL fires -- the pin IS an ancestor and it is still wrong" \
        || no "(4) ancestry note missing; the red is one 'but it is on main' away from being waved off"

    # GREEN LIMB: re-point the pin at HEAD, exactly as the fix instruction says.
    (
      cd "$HOME_REPO"
      printf 'CM051=%s\n' "$(git rev-parse HEAD)" > cuts/v1.0.31/cut.env
      git add -A && git -c user.email=t@t -c user.name=t commit -qm "re-point the pin"
    ) >/dev/null 2>&1
    ( run_gate "$HOME_REPO" "v1.0.31" "HEAD" ) > "$d/green.out" 2>&1; rcg=$?
    [ "$rcg" -eq 0 ] && ok "(5) GREEN CONTROL: re-pointing the pin passes (exit 0)" \
                     || no "(5) GREEN CONTROL FAILED (exit ${rcg}) -- this gate can only say no"

    # A re-point commit changes cut.env but NOT install.sh, so the blobs agree
    # while the commits differ. Proves the predicate reads content, not shas.
    grep -q 'PIN IS CURRENT' "$d/green.out" \
        && ok "(6) blob equality passes even though pin and ref are different COMMITS" \
        || no "(6) the predicate is comparing commits, not install.sh content"

    # CANNOT-RUN limbs. Each must be 2, never 0.
    ( run_gate "$HOME_REPO" "v9.9.9" "HEAD" ) >/dev/null 2>&1
    [ $? -eq 2 ] && ok "(7) CANNOT-RUN on a missing cut record (exit 2, not a pass)" \
                 || no "(7) a missing cut record did not produce CANNOT-RUN"
    ( cd "$HOME_REPO" && printf 'CM051=deadbeefdeadbeef\n' > cuts/v1.0.31/cut.env )
    ( run_gate "$HOME_REPO" "v1.0.31" "HEAD" ) >/dev/null 2>&1
    [ $? -eq 2 ] && ok "(8) CANNOT-RUN on an unresolvable pin (exit 2, not a pass)" \
                 || no "(8) an unresolvable pin did not produce CANNOT-RUN"
    ( cd "$HOME_REPO" && : > cuts/v1.0.31/cut.env )
    ( run_gate "$HOME_REPO" "v1.0.31" "HEAD" ) >/dev/null 2>&1
    [ $? -eq 2 ] && ok "(9) CANNOT-RUN when cut.env declares no CM051 pin" \
                 || no "(9) a pin-less cut.env did not produce CANNOT-RUN"

    echo
    echo "=== $p passed / $f failed ==="
    [ "$f" -eq 0 ]; exit $?
fi

# ===========================================================================
# REAL RUN
# ===========================================================================
REPO="${REPO_ARG:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REF="${REF_ARG:-${OSTLER_CUT_REF:-HEAD}}"
CUT="${CUT_ARG:-${OSTLER_CUT_VERSION:-${GITHUB_REF_NAME:-}}}"
# A branch name is not a cut tag. Only take GITHUB_REF_NAME when it looks like one.
case "$CUT" in
    v[0-9]*) : ;;
    *) CUT="" ;;
esac

run_gate "$REPO" "$CUT" "$REF"
exit $?
