#!/usr/bin/env bash
#
# test_sensitive_artefacts_guard_fires.sh
#
# PROOF OF LIFE for tests/test_sensitive_artefacts_not_world_readable.sh.
#
# That guard passing proves nothing on its own. It is a pile of "X does
# not appear" assertions, and every one of them passes for free if its
# predicate is broken. This file reintroduces the ACTUAL #912 defects,
# one at a time, and requires the guard to REJECT each one -- then puts
# the tree back and requires green again.
#
# ── WHY THE RESTORE IS A `cp`, NOT A `git checkout` ──────────────────
# On CM051 #1211 I shipped a first commit WITHOUT ITS OWN FIX because my
# mutation harness restored with `git checkout -- install.sh`, which
# restores from the INDEX, not from what I meant. The feature was
# deleted and `git show --stat` showed the file absent. A byte copy taken
# before the first mutation cannot do that.
#
# The rule that came out of it, and the reason this file exists at all:
# COMMIT FIRST, THEN MUTATE. If the mutation harness is the thing that
# eats your work, the commit is the only place it cannot reach.
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
GUARD="$REPO_ROOT/tests/test_sensitive_artefacts_not_world_readable.sh"

[ -f "$INSTALL_SH" ] || { echo "FAIL: install.sh missing -- CANNOT-RUN" >&2; exit 1; }
[ -f "$GUARD" ]      || { echo "FAIL: the guard is missing -- CANNOT-RUN" >&2; exit 1; }

BACKUP="$(mktemp -t ostler-912-install.XXXXXX)"
cleanup() {
    if [ -f "$BACKUP" ]; then
        cp "$BACKUP" "$INSTALL_SH" 2>/dev/null || true
        rm -f "$BACKUP" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM
cp "$INSTALL_SH" "$BACKUP"

# ── ARM 1: THE TREE AS COMMITTED. THE GUARD MUST PASS. ───────────────
if ! /bin/bash "$GUARD" >/dev/null 2>&1; then
    echo "FAIL: the guard is RED on the committed tree." >&2
    echo "      Either the #912 defect is live or the guard is broken." >&2
    echo "      Run it directly for the detail." >&2
    exit 1
fi
echo "ok: arm 1 -- guard PASSES on the committed tree"

# ── ARMS 2..N ────────────────────────────────────────────────────────
# Each entry: <label>|<python mutation applied to install.sh>
#
# Every mutation is a REINTRODUCTION of something that was genuinely in
# install.sh on origin/main d967950e, not an invented corruption. A
# mutation that breaks the file in some other way would make the guard
# go red for the wrong reason, and would prove nothing about #912.
arm=1
run_arm() {
    local label="$1" old="$2" new="$3"
    arm=$((arm + 1))
    cp "$BACKUP" "$INSTALL_SH"

    # The anchors go in as ARGV, never interpolated into the program
    # text. An earlier draft built the source with printf '%r' -- which
    # is Python's repr, not printf's -- and every arm died with a
    # SyntaxError. It reported CANNOT-RUN and stopped, which is the
    # behaviour I want, but a quoting bug should not be able to reach
    # the mutator in the first place.
    if ! python3 -c '
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if old not in s:
    sys.exit("anchor not found: " + repr(old[:70]))
if s.count(old) != 1:
    sys.exit("anchor is ambiguous (%d matches): %s" % (s.count(old), repr(old[:70])))
open(path, "w").write(s.replace(old, new, 1))
' "$INSTALL_SH" "$old" "$new"; then
        echo "FAIL: arm ${arm} (${label}) -- the mutation did not apply." >&2
        echo "      CANNOT-RUN, not a pass. FIX THIS ARM rather than" >&2
        echo "      deleting it: without it the guard has no proof of life" >&2
        echo "      for this defect." >&2
        exit 1
    fi

    if /bin/bash "$GUARD" >/dev/null 2>&1; then
        echo "FAIL: arm ${arm} -- THE GUARD PASSED WITH THE DEFECT PRESENT:" >&2
        echo "      ${label}" >&2
        echo "      It cannot detect this, so every green verdict it has" >&2
        echo "      ever given for it is meaningless. A broken gate, not a" >&2
        echo "      safe tree." >&2
        exit 1
    fi
    echo "ok: arm ${arm} -- guard REJECTS: ${label}"
}

# 1. The dedupe report, at the ordinary-shell site.
run_arm "the dedupe report back on a fixed /tmp path" \
    '--output "$_DEDUPE_REPORT" \' '--output /tmp/ostler-dedupe-report.yaml \'

# 2. The dedupe report, INSIDE the quoted heredoc (the LaunchAgent copy).
run_arm "the catch-up wrapper writing the report to /tmp" \
    '--output "$DEDUPE_REPORT" \' '--output /tmp/ostler-dedupe-report.yaml \'

# 3. The AI-conversations FAIL-OPEN fallback, restored verbatim.
run_arm "the mktemp fallback failing open onto a fixed /tmp path" \
    '|| _AICONV_OUT=""' '|| _AICONV_OUT=/tmp/ostler-aiconv-summary.json'

# 4. The wrapper loses its own 0700 enforcement. This is the arm that
#    matters most for the heredoc limb: the path stops being /tmp but
#    the directory is no longer proven private, which is the same
#    exposure wearing a different filename.
run_arm "the wrapper's own chmod 700 deleted" \
    'chmod 700 "$PRIVATE_DIR"' ':  # chmod 700 "$PRIVATE_DIR"'

# 5. THE INERT FIX. Someone "removes the duplication" by calling the
#    helper from inside the quoted heredoc, where it does not exist.
#    Byte-identical to a working fix, and does nothing. #1207 blocker-1.
run_arm "the wrapper calling the helper from inside the quoted heredoc (INERT)" \
    'DEDUPE_REPORT="${PRIVATE_DIR}/dedupe-report.yaml"' 'DEDUPE_REPORT="$(_ostler_private_artefact dedupe-report.yaml)"'

# 6. The helper grows a fallback. Every fallback is a world-readable one.
#
# ⚠️ THERE ARE NOW TWO COPIES OF THIS HELPER (#568: the main body needed
# its own, because the heredoc copy resolves only in the generated
# script's shell). A single-line anchor on the mkdir matches BOTH, and
# the mutator correctly refused it as ambiguous rather than picking one.
#
# 🔴 DO NOT "fix" that by replacing all occurrences at once. Mutating
# both copies together only proves the guard catches AT LEAST ONE of
# them -- a guard blind to either copy would still go red and look
# healthy. One arm per copy, disambiguated by the line above the mkdir,
# is the version that can tell those two worlds apart.
run_arm "a /tmp fallback added to the helper (MAIN-BODY copy)" \
    '    _d="${OSTLER_PRIVATE_ARTEFACTS_DIR:-${OSTLER_DIR:-${HOME}/.ostler}/state/private}"
    mkdir -p "${_d}" 2>/dev/null || return 1' \
    '    _d="${OSTLER_PRIVATE_ARTEFACTS_DIR:-${OSTLER_DIR:-${HOME}/.ostler}/state/private}"
    mkdir -p "${_d}" 2>/dev/null || { printf "/tmp/%s" "${_name}"; return 0; }'

run_arm "a /tmp fallback added to the helper (QUOTED-HEREDOC copy)" \
    '    local _name="$1" _d="${OSTLER_PRIVATE_ARTEFACTS_DIR}" _mode
    mkdir -p "${_d}" 2>/dev/null || return 1' \
    '    local _name="$1" _d="${OSTLER_PRIVATE_ARTEFACTS_DIR}" _mode
    mkdir -p "${_d}" 2>/dev/null || { printf "/tmp/%s" "${_name}"; return 0; }'

# ── FINAL ARM: RESTORE, AND PROVE THE RESTORE WORKED ─────────────────
cp "$BACKUP" "$INSTALL_SH"
if ! /bin/bash "$GUARD" >/dev/null 2>&1; then
    echo "FAIL: the guard is still RED after restore -- the tree was left" >&2
    echo "      mutated. Anything downstream is reading the wrong file." >&2
    exit 1
fi
arm=$((arm + 1))
echo "ok: arm ${arm} -- tree restored, guard green again"

echo ""
echo "sensitive-artefact guard proof-of-life: ${arm} arms, all passed"
