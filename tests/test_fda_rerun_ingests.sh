#!/usr/bin/env bash
# ============================================================================
# test_fda_rerun_ingests.sh -- the recurring fda-rerun tick must run the INGEST
# half, not just the EXTRACT half.
#
# THE DEFECT (#784, measured 2026-08-19)
#
#   com.ostler.fda-rerun -> ostler-assistant run-source fda-rerun
#     -> the sealed tick.sh -> ~/.ostler/bin/ostler-fda   (written HERE)
#       -> ostler_fda.extract_all.run_all(...)   AND NOTHING ELSE
#
#   run_all     EXTRACTS the FDA sources -> imports/fda/*.json   every tick
#   ingest_all  LOADS that JSON into Qdrant/Oxigraph            install ONLY
#
# So Safari history was re-harvested on schedule, overwrote safari_history.json,
# and stopped. Collected on schedule, dropped on the floor.
#
# WHY IT SURVIVED SO LONG: this is a WRITER WITH NO READER, not a stalled
# indexer. Every check anyone would think to run -- is the agent scheduled, is
# the extractor running, is the JSON fresh -- reads GREEN. Only the destination
# is stale, and nothing was looking at the destination.
#
# It is also not novel. pwg_ingest.py already calls _INGEST_DISPATCH "the
# install-path dispatch table" and, in the same comment, names three prior
# burns of this exact shape: imessage-only people, BROWSING, the people-sweep.
# Two of those three are this ticket and #785.
#
# ============================================================================
# WHY THIS GATE IS BEHAVIOURAL AND NOT A grep
# ============================================================================
#
# The obvious predicate is "install.sh mentions ingest_all". That is the #688
# defect verbatim: a name in a comment scores as wired, and documenting a dark
# call marks it live. Controls (3)-(7) below therefore EXECUTE the wrapper that
# install.sh emits, against a stand-in ostler_fda that records which entry
# points were actually called, and assert on the record.
#
# Control (8) is the negative control that makes the rest mean anything: it
# feeds the harness a wrapper that provably does NOT ingest and requires the
# harness to say so. Without it, a harness broken toward "called" would report
# every arm green while measuring nothing -- which is how a dead test looks
# exactly like a passing one.
#
# EXIT CODES   0 all controls pass   1 a control failed   2 CANNOT-RUN
#
# --self-test  reinstates the defect in a COPY of install.sh and proves the
#              controls go RED. Wired as its OWN CI job, never as a sibling
#              step, because a failing step masks everything after it.
# ============================================================================
set -uo pipefail

REPO_ROOT=""
SELF_TEST=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --self-test) SELF_TEST=1; shift ;;
        --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
INSTALL_SH="${REPO_ROOT}/install.sh"
STRIPPER="${REPO_ROOT}/scripts/lib/strip_comments.sh"

PASS=0
FAIL=0

cannot_run() {
    echo "CANNOT-RUN: $*" >&2
    exit 2
}

check() {
    local name="$1"; shift
    if "$@"; then
        printf '  [pass] %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  [FAIL] %s\n' "$name"
        FAIL=$((FAIL + 1))
    fi
}

[[ -f "$INSTALL_SH" ]] || cannot_run "install.sh not found at $INSTALL_SH"

# The shared quote-aware stripper (#860). Sourced rather than reimplemented so
# that a fix to what counts as a comment reaches every gate from one edit --
# which is exactly what #862 then did.
[[ -f "$STRIPPER" ]] || cannot_run \
    "shared comment stripper missing at $STRIPPER; a gate that cannot strip comments cannot tell a call from a mention"
# shellcheck source=/dev/null
. "$STRIPPER"

PY="$(command -v python3 || true)"
[[ -n "$PY" ]] || cannot_run \
    "no python3 on PATH; the behavioural controls run the real wrapper and cannot be faked"

# ---------------------------------------------------------------------------
# EXTRACTION. The wrapper comes out of the shipping install.sh verbatim, or we
# exit 2. The heredoc is QUOTED (<<'FDAEOF'), so what install.sh writes to disk
# is byte-for-byte what we extract -- ${OSTLER_DIR} and ${FDA_DIR} expand in
# the WRAPPER's shell at run time, not at install time, which is what makes
# running the extracted text a faithful test rather than an approximation.
# ---------------------------------------------------------------------------
WRAPPER_BODY="$(awk '
    index($0, "bin/ostler-fda\" <<") { grab = 1; next }
    grab && $0 == "FDAEOF"           { exit }
    grab                             { print }
' "$INSTALL_SH")"

[[ -n "$WRAPPER_BODY" ]] || cannot_run \
    "could not extract the ostler-fda wrapper heredoc from install.sh; the marker moved"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fdaingest.XXXXXX")" || cannot_run "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
[[ -d "$WORK" ]] || cannot_run "work dir was not created; NOTHING was checked, which is not a pass"

# Comment-stripped wrapper, for the two static controls.
printf '%s\n' "$WRAPPER_BODY" > "${WORK}/wrapper.raw"
strip_comments_file "${WORK}/wrapper.raw" > "${WORK}/wrapper.stripped" \
    || cannot_run "strip_comments_file failed on the extracted wrapper"

# ---------------------------------------------------------------------------
# THE HARNESS. Builds a fake ~/.ostler containing a stand-in ostler_fda package
# and the wrapper under test, runs it with HOME redirected, and returns the
# call log. Nothing here touches the real machine.
# ---------------------------------------------------------------------------

# build_root <root-dir> <wrapper-file> <ingest-mode: ok|raise>
build_root() {
    local root="$1" wrapper="$2" mode="$3"
    local pkg="${root}/.ostler/fda-module/ostler_fda"
    mkdir -p "$pkg" "${root}/.ostler/bin" "${root}/.ostler/imports/fda"
    : > "${pkg}/__init__.py"

    cat > "${pkg}/extract_all.py" <<'PYEOF'
import os
import pathlib


def _log(line):
    with open(os.environ["OSTLER_FDA_PROBE_LOG"], "a") as fh:
        fh.write(line + "\n")


def run_all(output_dir=None, enabled_sources=None):
    # Stand-in for the real extractor. Writes the artefact the real one writes
    # so control (7) can prove the harvest survives a failing ingest.
    out = pathlib.Path(str(output_dir))
    out.mkdir(parents=True, exist_ok=True)
    (out / "safari_history.json").write_text("[]")
    _log("run_all " + str(output_dir))
    return {"sources": {}}
PYEOF

    # `fda_dir` deliberately defaults to a SENTINEL rather than being required.
    # A required arg would turn "called with no directory" into a TypeError and
    # a wrapper crash, which reads as "ingest never ran" -- the wrong diagnosis
    # for the wrong defect. With the sentinel, control (3) still sees the call
    # and control (5) is the one that fails, naming the actual problem.
    cat > "${pkg}/pwg_ingest.py" <<PYEOF
import os

_MISSING = object()
_MODE = "${mode}"


def _log(line):
    with open(os.environ["OSTLER_FDA_PROBE_LOG"], "a") as fh:
        fh.write(line + "\n")


def ingest_all(fda_dir=_MISSING):
    _log("ingest_all " + ("<no-explicit-dir>" if fda_dir is _MISSING else str(fda_dir)))
    if _MODE == "raise":
        # Structural failure: an import error or a bug in the loop itself.
        raise RuntimeError("ingest exploded")
    if _MODE == "error_dict":
        # THE REALISTIC FAILURE, and the one the first version of this test
        # could not see (Archie, #864). The real ingest_all catches Exception
        # per source and RECORDS {"status": "error"}; it does not raise. A stub
        # that only ever raises tests a code path the shipping module cannot
        # take, so the arm passed while the wrapper exited 0 on seven dead
        # sources.
        return {"browser_history": {"status": "error", "error": "qdrant refused"},
                "bookmarks": {"status": "ok", "sent": 3}}
    if _MODE == "error_flat":
        # The whole-directory failure shape: FLAT, not per-source. Iterating it
        # as if it were per-source finds no dict values and reports all clear.
        return {"status": "error", "reason": "directory not found: /nope"}
    return {"browser_history": {"status": "ok", "sent": 1}}
PYEOF

    cp "$wrapper" "${root}/.ostler/bin/ostler-fda"
    chmod +x "${root}/.ostler/bin/ostler-fda"
}

# run_wrapper <label> <wrapper-file> <ingest-mode>
# Echoes the wrapper's exit status; leaves the call log at $WORK/<label>.log and
# the fake home at $WORK/<label>/.
run_wrapper() {
    local label="$1" wrapper="$2" mode="$3"
    local root="${WORK}/${label}"
    local log="${WORK}/${label}.log"
    rm -rf "$root"; rm -f "$log"
    mkdir -p "$root"
    build_root "$root" "$wrapper" "$mode"
    # OSTLER_PYTHON is passed EMPTY, not unset: the wrapper uses ${VAR:-default}
    # so empty takes the default, and the real venv-then-system resolution path
    # is what gets exercised.
    HOME="$root" \
    OSTLER_PYTHON= \
    OSTLER_FDA_PROBE_LOG="$log" \
        bash "${root}/.ostler/bin/ostler-fda" >"${WORK}/${label}.out" 2>&1
    echo $?
}

# The wrapper exactly as install.sh ships it.
printf '%s\n' "$WRAPPER_BODY" > "${WORK}/ostler-fda.shipped"

# A synthetic EXTRACT-ONLY wrapper, for the negative control: the pre-#784
# shape, everything through the extract and nothing after it.
#
# BUILT BY TRUNCATION, NOT BY DELETING LINES THAT MENTION ingest_all. The
# line-deletion version worked until #864 added an error-inspection block, at
# which point removing every ingest_all line left an `if:` whose body was a
# comment -- a Python IndentationError, so the fixture crashed BEFORE run_all
# and the negative control failed for a reason that had nothing to do with the
# property it guards. A fixture built by subtraction breaks whenever the
# original grows; truncation at a named anchor does not.
awk '
    !stop { print }
    !stop && $0 == "run_all(fda_dir)" { stop = 1; next }
    stop && $0 == "\"" { print; stop = 2; next }
    stop == 2 { print }
' "${WORK}/ostler-fda.shipped" > "${WORK}/ostler-fda.extractonly"

# The anchor must have been found. If it moves, this fixture silently becomes
# "the whole shipped wrapper", the negative control then sees ingest_all called
# and fails -- which is at least loud -- but it could equally become an empty
# file that fails for the wrong reason. Refuse instead of guessing.
grep -q '^run_all(fda_dir)$' "${WORK}/ostler-fda.extractonly" || cannot_run \
    "could not build the extract-only fixture: the run_all(fda_dir) anchor moved"
# The fixture must not CALL ingest_all. Checked on the comment-stripped text
# with call syntax, not on the raw text: the wrapper's own comments discuss
# ingest_all at length, and a bare substring guard fails on the prose while the
# code is correct -- a false CANNOT-RUN, which is the same class of error as a
# false green, just noisier. This is control (2)'s predicate, reused.
strip_comments_file "${WORK}/ostler-fda.extractonly" > "${WORK}/extractonly.stripped" \
    || cannot_run "strip_comments_file failed on the extract-only fixture"
! grep -q 'ingest_all(' "${WORK}/extractonly.stripped" || cannot_run \
    "the extract-only fixture still CALLS ingest_all; truncation did not take"

RC_OK=""; LOG_OK=""
RC_RAISE=""; LOG_RAISE=""
RC_EDICT=""; RC_EFLAT=""
RC_NEG=""; LOG_NEG=""

measure() {
    RC_OK="$(run_wrapper shipped-ok "${WORK}/ostler-fda.shipped" ok)"
    LOG_OK="$(cat "${WORK}/shipped-ok.log" 2>/dev/null || true)"

    RC_RAISE="$(run_wrapper shipped-raise "${WORK}/ostler-fda.shipped" raise)"
    LOG_RAISE="$(cat "${WORK}/shipped-raise.log" 2>/dev/null || true)"

    RC_EDICT="$(run_wrapper shipped-edict "${WORK}/ostler-fda.shipped" error_dict)"
    RC_EFLAT="$(run_wrapper shipped-eflat "${WORK}/ostler-fda.shipped" error_flat)"

    RC_NEG="$(run_wrapper extract-only "${WORK}/ostler-fda.extractonly" ok)"
    LOG_NEG="$(cat "${WORK}/extract-only.log" 2>/dev/null || true)"

    # The apparatus itself must have worked. If the shipped wrapper produced no
    # call log at all then the harness measured nothing, and "no evidence of a
    # missing ingest" must not print the same as "the ingest happened".
    if [[ -z "$LOG_OK" ]]; then
        echo "CANNOT-RUN: the shipped wrapper produced an EMPTY call log." >&2
        echo "            Not even run_all was recorded, so the harness -- not the" >&2
        echo "            wrapper -- is what failed. Wrapper output follows:" >&2
        sed 's/^/            /' "${WORK}/shipped-ok.out" >&2 2>/dev/null || true
        exit 2
    fi
}

# ---------------------------------------------------------------------------
# CONTROLS
# ---------------------------------------------------------------------------

# (1) The wrapper IMPORTS the ingest half from the module that owns it. Cheap,
#     and it localises a rename: if pwg_ingest moves, this fails with a clear
#     reason before the behavioural arms fail with a stack trace.
c1() { grep -q 'from ostler_fda.pwg_ingest import ingest_all' "${WORK}/wrapper.stripped"; }

# (2) And CALLS it. Asserted on the comment-STRIPPED text with call syntax, so
#     that a commented-out call, or the import alone, cannot satisfy it. This is
#     the #688 lesson: count invocations, refuse to count mentions.
c2() { grep -q 'ingest_all(' "${WORK}/wrapper.stripped"; }

# (3) THE DEFECT ITSELF, measured by running the thing. Both halves must have
#     been called. Before #784 the log held run_all and nothing else.
c3() {
    printf '%s\n' "$LOG_OK" | grep -q '^run_all ' && \
    printf '%s\n' "$LOG_OK" | grep -q '^ingest_all '
}

# (4) ORDER. Extract must precede ingest, or the tick loads the PREVIOUS tick's
#     JSON and the freshest harvest waits an hour for a reader.
c4() {
    local first
    first="$(printf '%s\n' "$LOG_OK" | grep -E '^(run_all|ingest_all) ' | head -1 | awk '{print $1}')"
    [[ "$first" == "run_all" ]]
}

# (5) Both halves are handed the SAME directory, explicitly. ingest_all defaults
#     to ~/.ostler/imports/fda, which happens to be right today -- but the
#     extract half writes to ${OSTLER_DIR}/imports/fda, and OSTLER_DIR is
#     resolved in the wrapper. Letting the ingest half default is a silent
#     dependency on those two never diverging.
c5() {
    local extracted ingested
    extracted="$(printf '%s\n' "$LOG_OK" | grep '^run_all '    | head -1 | cut -d' ' -f2-)"
    ingested="$( printf '%s\n' "$LOG_OK" | grep '^ingest_all ' | head -1 | cut -d' ' -f2-)"
    [[ -n "$extracted" ]] && [[ "$extracted" == "$ingested" ]]
}

# (6) A RAISING INGEST IS LOUD. Structural failure -- import error, a bug in
#     the dispatch loop. `set -euo pipefail` covers this one on its own.
c6() { [[ "$RC_RAISE" != "0" ]]; }

# (11) A RECORDED-ERROR INGEST IS ALSO LOUD, and this is the arm that matters.
#      The real ingest_all NEVER RAISES: its per-source loop catches Exception
#      and records {"status": "error"}. So `set -e` sees nothing, and before
#      this control all seven sources could fail with the tick reporting
#      success. Found by Archie on #864 -- the header asserted loudness the
#      code did not have.
#
#      My own fixture was the reason the gap survived: the stub only ever
#      RAISED, which is a path the shipping module cannot take. A stand-in that
#      cannot fail the way the real thing fails is an instrument pointed at the
#      wrong surface, inside a gate written to catch exactly that.
c11() { [[ "$RC_EDICT" != "0" ]]; }

# (12) ...including the FLAT whole-directory error shape. Checked separately
#      because it is a different structure: iterating {"status": "error"} as if
#      it were per-source finds no dict values and concludes all is well. One
#      predicate over both shapes would pass here while blind to it.
c12() { [[ "$RC_EFLAT" != "0" ]]; }

# (7) ...and the harvest still survives it. The extract writes its JSON before
#     the ingest is attempted, so a broken ingest costs a load, never a
#     collection. This is the regression the fix must not cause.
c7() { [[ -f "${WORK}/shipped-raise/.ostler/imports/fda/safari_history.json" ]]; }

# (8) NEGATIVE CONTROL, and the arms above are worthless without it. Fed a
#     wrapper that provably does not ingest, the harness must report exactly
#     that. A harness biased toward "called" -- a stale log file, a marker
#     written by the fixture itself -- would otherwise pass (3) while measuring
#     nothing at all.
c8() {
    printf '%s\n' "$LOG_NEG" | grep -q '^run_all ' && \
    ! printf '%s\n' "$LOG_NEG" | grep -q '^ingest_all '
}

# (9) UPGRADE LIMB. The wrapper must be rewritten on every install, not only
#     when absent. #768 fixed a defect for fresh installs only, because its
#     guard was a bare `[[ ! -f ]]`, and #769 had to correct that within the
#     hour. Every box in the field already carries an extract-only ostler-fda;
#     a fix that skips them is half a fix.
# 🔴 SCOPED TO THE WRITE, 2026-09-04 (v1063-D010). This used to forbid ANY
# -f/-e/-x test against that path ANYWHERE in install.sh. The defect it guards
# is specifically a WRITE guarded on absence -- "create only if missing" --
# which skips every box already carrying an extract-only wrapper.
#
# The deferred fda-rerun LOAD now tests `-x` on the same path, deliberately: it
# refuses to register a LaunchAgent whose program is missing rather than
# registering one that fails hourly forever. That is the opposite of the #768
# defect and it tripped this control, which could not tell a write guard from a
# load guard because it never looked at WHERE the test appeared.
#
# So it now examines only the region IMMEDIATELY BEFORE the wrapper heredoc --
# the only place a write guard can live. A test after the write cannot make the
# write conditional, by construction.
#
# NOT WEAKENED, AND MUTATION-PROVEN: reinstating the #768 shape (an `if [[ ! -f
# ... ]]` around the heredoc) still fails this control. Evading it by hiding the
# path in a variable was the tempting fix and was refused -- that would leave
# the control unable to see a real write guard written the same way.
c9() {
    local write_at start body
    write_at="$(grep -n -F 'cat > "${OSTLER_DIR}/bin/ostler-fda" <<' "$INSTALL_SH" | head -1 | cut -d: -f1)"
    [ -n "$write_at" ] || return 1          # cannot find the write: not a pass
    start=$(( write_at > 40 ? write_at - 40 : 1 ))
    body="$(sed -n "${start},${write_at}p" "$INSTALL_SH")"
    ! printf '%s\n' "$body" | grep -qE '\[\[[^]]*-[fex][[:space:]]+"?\$\{?OSTLER_DIR\}?/bin/ostler-fda'
}

# (10) The wrapper is a SHIPPED TICK and must parse on the customer's shell.
#      ingest-slot.yml proves this for every tick that is a FILE in the repo;
#      this one is a heredoc, so it was outside that list and nothing checked
#      it. Refuses on a 5.x /bin/bash rather than passing: a 3.2-incompatible
#      construct parses fine on 5.x, so a green there would measure nothing.
#      The gate declares macos-14, where /bin/bash is 3.2.
c10() {
    local ver
    ver="$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || true)"
    if [[ "$ver" != "3" ]]; then
        echo "         REFUSING: /bin/bash here is ${ver:-unknown}.x, not 3.x." >&2
        echo "         This control exists to prove 3.2 compatibility; a pass on a" >&2
        echo "         5.x shell would be a green that measures nothing." >&2
        return 1
    fi
    /bin/bash -n "${WORK}/ostler-fda.shipped"
}

run_controls() {
    PASS=0
    FAIL=0
    measure
    echo "fda-rerun ingest-half controls (install.sh: $INSTALL_SH)"
    check "(1) wrapper imports ingest_all from ostler_fda.pwg_ingest"  c1
    check "(2) wrapper CALLS ingest_all (stripped text, call syntax)"  c2
    check "(3) running the wrapper calls BOTH extract and ingest"      c3
    check "(4) extract runs before ingest"                             c4
    check "(5) ingest is handed the extract's directory, explicitly"   c5
    check "(6) a RAISING ingest exits non-zero"                        c6
    check "(7) a failing ingest still leaves the harvest on disk"      c7
    check "(8) NEGATIVE CONTROL: harness detects an extract-only tick" c8
    check "(9) the wrapper is rewritten on upgrade, not only created"  c9
    check "(10) the shipped wrapper parses under bash 3.2"             c10
    check "(11) a RECORDED-error ingest exits non-zero"                c11
    check "(12) ...and the FLAT whole-directory error shape too"       c12
}

# ---------------------------------------------------------------------------
# --self-test: PROVE RED.
# ---------------------------------------------------------------------------
if [[ "$SELF_TEST" == "1" ]]; then
    echo "SELF-TEST: reinstating the defect and requiring RED"
    SELF_FAIL=0

    probe() {
        local label="$1" sedscript="$2" expect_fail="$3"
        local dir="${WORK}/self-${label}"
        mkdir -p "${dir}/tests" "${dir}/scripts/lib"
        sed "$sedscript" "$INSTALL_SH" > "${dir}/install.sh"
        cp "$STRIPPER" "${dir}/scripts/lib/strip_comments.sh"
        cp "${BASH_SOURCE[0]}" "${dir}/tests/$(basename "${BASH_SOURCE[0]}")"
        local out rc
        out="$(bash "${dir}/tests/$(basename "${BASH_SOURCE[0]}")" --repo-root "$dir" 2>&1)"
        rc=$?
        if [[ "$rc" == "2" ]]; then
            printf '  [INCONCLUSIVE] %s -- controls could not run against the mutated copy\n' "$label"
            printf '%s\n' "$out" | sed 's/^/      /'
            SELF_FAIL=$((SELF_FAIL + 1))
            return
        fi
        if printf '%s\n' "$out" | grep -q "\[FAIL\] ${expect_fail}"; then
            printf '  [pass] %s -> %s went RED as required\n' "$label" "$expect_fail"
        else
            printf '  [FAIL] %s -> %s stayed GREEN with the defect present\n' "$label" "$expect_fail"
            printf '%s\n' "$out" | sed 's/^/      /'
            SELF_FAIL=$((SELF_FAIL + 1))
        fi
    }

    # Defect A: origin/main restored. The ingest call is gone; everything else,
    # including the import, is untouched -- so this also proves (3) is not
    # quietly resting on (1).
    # NOTE the `.*` anchors. These used to match the call line exactly; #864
    # appended ` or {}` to it and three probes silently stopped mutating
    # anything, so the self-test reported "did not go red" for a fixture that
    # was never modified. A probe pinned to an exact line is a probe that
    # expires the next time the line is edited -- assert the CALL, not its
    # current spelling.
    probe "extract-only" \
        's|^results = ingest_all.*|results = {}|' \
        "(3)"

    # Defect B: both halves called, wrong order. The tick would ingest the
    # PREVIOUS harvest, so the destination is always one tick stale and looks
    # almost right, which is worse than looking wrong.
    # Defect B: both halves called, WRONG ORDER -- the tick would ingest the
    # PREVIOUS harvest, so the destination is always one tick stale and looks
    # almost right, which is worse than looking wrong.
    #
    # Achieved by REBINDING run_all to a no-op and calling the real one after
    # the ingest, rather than by deleting the `run_all(fda_dir)` line. The
    # deleting version removed the very anchor the extract-only fixture is
    # built from, so the run came back CANNOT-RUN and the probe proved nothing.
    # A probe must not destroy the apparatus it is measured by.
    probe "ingest-before-extract" \
        's|^from ostler_fda.extract_all import run_all$|from ostler_fda.extract_all import run_all as _rr; run_all = lambda *a, **k: None|; s|^results = ingest_all.*|results = ingest_all(fda_dir) or {}; _rr(fda_dir)|' \
        "(4)"

    # Defect C: the ingest half defaults its directory instead of being handed
    # the one the extract just wrote.
    probe "ingest-defaults-its-dir" \
        's|^results = ingest_all.*|results = ingest_all() or {}|' \
        "(5)"

    # Defect E (#864, Archie): the wrapper inspects the result and then does
    # nothing with it. This is the state main shipped in -- ingest ran, every
    # source could fail, and the tick still exited 0 because ingest_all records
    # errors rather than raising them.
    probe "swallow-recorded-errors" \
        's|^    sys.exit(1)$|    pass|' \
        "(11)"

    # Defect D: a `|| true` bolted on to quieten a failing tick. Anchored by
    # line number because the closing quote of the `-c` string is a lone `"`
    # and is not unique in install.sh.
    CLOSE_LINE="$(awk '
        index($0, "bin/ostler-fda\" <<") { grab = 1 }
        grab && $0 == "FDAEOF"           { print NR - 1; exit }
    ' "$INSTALL_SH")"
    if [[ -z "$CLOSE_LINE" ]]; then
        echo "  [INCONCLUSIVE] silence-the-failure -- could not locate the closing quote" >&2
        SELF_FAIL=$((SELF_FAIL + 1))
    else
        # `@` as the sed delimiter, not `|`: the replacement text IS `|| true`,
        # and a `|` inside a `|`-delimited s/// is a syntax error, not a match
        # failure -- BSD sed says "bad flag in substitute command" and writes
        # nothing, which the probe then reports as INCONCLUSIVE rather than as
        # a pass. Correct behaviour, wrong test.
        probe "silence-the-failure" \
            "${CLOSE_LINE}s@^\"\$@\" || true@" \
            "(6)"
    fi

    echo
    if [[ "$SELF_FAIL" -gt 0 ]]; then
        echo "SELF-TEST FAILED: $SELF_FAIL probe(s) did not go red"
        exit 1
    fi
    echo "SELF-TEST PASSED: every probe went red on the axis it targets"
    exit 0
fi

run_controls
echo
if [[ "$FAIL" -gt 0 ]]; then
    echo "FAILED: ${FAIL} of $((PASS + FAIL)) controls"
    exit 1
fi
echo "PASSED: ${PASS} of ${PASS} controls"
exit 0
