#!/usr/bin/env bash
#
# test_launchd_plist_no_tmp.sh
#
# Regression gate for #177 (v1.0.13 launch-blocker, live-confirmed on the
# Mini). The Ollama + ollama-logrotate LaunchAgents shipped with dead
# /tmp/ostler-prelaunch-<pid>/... paths baked into ProgramArguments /
# StandardOutPath / StandardErrorPath.
#
# ROOT CAUSE: the ollama section of install.sh runs PRE-FDA, when
# _ostler_set_paths still has LOGS_DIR and OSTLER_DIR bound to the
# /tmp/ostler-prelaunch-<pid> staging tree (they are not rebound to
# ~/.ostler until the post-FDA promotion). Those tainted values were
# interpolated into the two plists, and /tmp is wiped on reboot + macOS
# periodic cleanup -- so both agents failed after every reboot.
#
# THE GATE: rather than merely grep the source, this RENDERS the two
# ollama plist heredocs (running install.sh's own log-dir derivation
# first) with LOGS_DIR and OSTLER_DIR deliberately POISONED to a
# /tmp/ostler-prelaunch path -- the exact pre-FDA condition -- and
# asserts the rendered plists contain no /tmp. Any future re-introduction
# of a prelaunch-tainted var into a shipped LaunchAgent plist path fails
# here, at CI, not at a customer reboot.
#
# Per locked memory feedback_silent_bail_regression_test_shape +
# feedback_ships_dark_wire_and_gate: the gate exercises the ACTUAL shipped
# artefact (rendered plist) rather than a lookalike, and carries a
# positive control so a silently-empty extraction can never false-PASS.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"
FAILED=0

failure() { echo "FAIL: $*" >&2; FAILED=1; }

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "test_launchd_plist_no_tmp: FAILED (install.sh missing)" >&2
    exit 1
fi

# Extract the shell body of a `cat > "$X" <<DELIM ... DELIM` heredoc block
# (the lines strictly between the opening `<<DELIM` and the closing DELIM).
extract_heredoc_body() {
    local delim="$1"
    awk -v d="$delim" '
        $0 ~ ("<<" d "[[:space:]]*$") { grab=1; next }
        grab && $0 == d { grab=0 }
        grab { print }
    ' "$INSTALL_SH"
}

# Render a plist heredoc body under a POISONED prelaunch environment, after
# first running install.sh's real derivation of the log-dir var (that
# derivation is exactly what the #177 fix changed). Refuses to eval-render a
# body that contains command substitution, so this can never execute an
# embedded $(...) / backtick.
assert_plist_clean() {
    local name="$1" delim="$2" logvar="$3"
    local body assign rendered rc

    body="$(extract_heredoc_body "$delim")"
    if [[ -z "$body" ]]; then
        failure "$name: heredoc body <<$delim not found in install.sh (extraction broke)"
        return
    fi
    if printf '%s' "$body" | grep -qE '\$\(|`'; then
        failure "$name: heredoc body contains command substitution -- refusing to eval-render (update this test)"
        return
    fi
    assign="$(grep -E "^[[:space:]]*${logvar}=" "$INSTALL_SH" | head -1 | sed -E 's/^[[:space:]]+//')"
    if [[ -z "$assign" ]]; then
        failure "$name: could not find the ${logvar}= assignment in install.sh"
        return
    fi

    set +e
    rendered="$(
        set -u
        export HOME='/Users/regressiontest'
        # The two vars that were tainted pre-FDA on the real Mini.
        LOGS_DIR='/tmp/ostler-prelaunch-9999'
        OSTLER_DIR='/tmp/ostler-prelaunch-9999'
        # Non-path vars the bodies reference; values are irrelevant to the
        # /tmp assertion but must be set under `set -u`.
        OLLAMA_APP_BIN='/Applications/Ollama.app/Contents/Resources/ollama'
        OSTLER_NUM_PARALLEL=2
        # Run the REAL log-dir derivation from install.sh, then expand body.
        eval "$assign"
        eval "cat <<RENDER_EOF
$body
RENDER_EOF"
    )"
    rc=$?
    set -e

    if [[ $rc -ne 0 || -z "$rendered" ]]; then
        failure "$name: render failed (rc=$rc) -- an interpolated var was unset or the body changed shape"
        return
    fi
    if grep -q '/tmp' <<<"$rendered"; then
        failure "$name plist STILL contains /tmp under a poisoned prelaunch env:"
        grep -n '/tmp' <<<"$rendered" | sed 's/^/    /' >&2
        return
    fi
    if grep -q 'ostler-prelaunch' <<<"$rendered"; then
        failure "$name plist references the /tmp prelaunch staging tree:"
        grep -n 'ostler-prelaunch' <<<"$rendered" | sed 's/^/    /' >&2
        return
    fi
    if ! grep -q '/.ostler/' <<<"$rendered"; then
        failure "$name plist does not reference ~/.ostler/ after render -- extraction likely broke"
        return
    fi
    echo "  ok: $name renders clean (~/.ostler/, no /tmp) under poisoned LOGS_DIR/OSTLER_DIR"
}

# Positive control: prove the render harness actually detects taint, so a
# silently-empty extraction can never yield a false PASS.
control="$(
    HOME='/Users/regressiontest'
    LOGS_DIR='/tmp/ostler-prelaunch-9999'
    eval "cat <<RENDER_EOF
    <string>\${LOGS_DIR}/ollama.log</string>
RENDER_EOF"
)"
if ! grep -q '/tmp' <<<"$control"; then
    failure "positive control did not render /tmp -- the render harness is broken, results are untrustworthy"
fi

# The two LaunchAgent plists written PRE-FDA (the only ones tainted by #177).
assert_plist_clean "com.ostler.ollama"           OLLAMAPLIST    OLLAMA_LOG_DIR
assert_plist_clean "com.ostler.ollama-logrotate" OLLAMAROTPLIST _ollama_rot_logs

# ===========================================================================
# #573: THE TWO RENDERS ABOVE ARE A HAND-PICKED DENOMINATOR
# ===========================================================================
#
# The line above used to end this file, and its comment called those two "the
# only ones tainted by #177". That was true OF THAT INCIDENT and was never true
# OF THE CLASS -- but the final PASS message claims the general property, "no
# shipped com.*ostler*.plist path resolves under /tmp". A check of two made a
# claim about all of them.
#
# com.ostler.engine-supervisor was written above the promote boundary,
# interpolated ${OSTLER_DIR} and ${LOGS_DIR}, baked
# /tmp/ostler-prelaunch-<pid> into a durable LaunchAgent, and died at the
# customer's first reboot. This gate was green throughout. It never looked.
#
# So the list is now DISCOVERED, not typed. Adding a fifteenth plist cannot
# quietly escape the rule, and if discovery ever returns nothing the gate
# exits 2 CANNOT-RUN rather than printing a green zero.
#
# WHY A SOURCE RULE HERE AND NOT A RENDER: rendering needs each plist's own
# local variable derivations, so a generic renderer would fail for reasons
# that have nothing to do with taint -- and a gate that errors for the wrong
# reason gets weakened. The property IS decidable from source: above the
# boundary, do not name a staging-bound variable. The two renders above stay
# as the stronger evidence they are for the plists they cover.

echo ""
echo "  -- #573 whole-class sweep: every plist above the promote boundary --"

python3 - "$INSTALL_SH" <<'PYEOF'
import re, sys

path = sys.argv[1]
lines = open(path, encoding="utf-8").read().split("\n")

# The boundary is an explicit marker in install.sh, not a line number and not
# an inference from indentation. If it is missing or duplicated the contract
# has moved and this gate REFUSES rather than guessing: a wrong boundary would
# silently check the wrong set.
marker = [i for i, l in enumerate(lines, 1) if "OSTLER-PROMOTE-BOUNDARY" in l and l.lstrip().startswith("#")]
if len(marker) != 1:
    print(f"CANNOT-RUN: expected exactly 1 OSTLER-PROMOTE-BOUNDARY marker in install.sh, found {len(marker)}", file=sys.stderr)
    print("            install.sh's promote contract moved; this gate will not guess which plists are at risk.", file=sys.stderr)
    sys.exit(2)
boundary = marker[0]

# Discover every LaunchAgent plist heredoc: VAR="...LaunchAgents/x.plist"
# followed later by `cat > "$VAR" <<TAG`.
plistvars = {}
for i, l in enumerate(lines, 1):
    m = re.match(r'\s*([A-Z_][A-Z0-9_]*)="\$\{HOME\}/Library/LaunchAgents/([^"]+)"', l)
    if m:
        plistvars.setdefault(m.group(1), m.group(2))

found = []
for i, l in enumerate(lines, 1):
    m = re.search(r'cat\s*>\s*"\$(?:\{)?([A-Z_][A-Z0-9_]*)(?:\})?"', l)
    if not m or m.group(1) not in plistvars:
        continue
    h = re.search(r"<<-?('?)([A-Za-z_][A-Za-z0-9_]*)\1", l)
    if not h:
        continue
    tag = h.group(2)
    quoted = ("<<'" in l) or ('<<"' in l)
    body = []
    for j in range(i, len(lines)):
        if lines[j].strip() == tag:
            break
        body.append((j + 1, lines[j]))
    found.append((i, plistvars[m.group(1)], quoted, body))

# ANTI-VACUITY. A discovery bug and a clean tree print identically; only a
# floor tells them apart. 14 plists exist today, so 10 leaves room for
# deliberate removals while still refusing a collapsed match.
FLOOR = 10
if len(found) < FLOOR:
    print(f"CANNOT-RUN: discovered only {len(found)} LaunchAgent plist heredocs (floor {FLOOR}).", file=sys.stderr)
    print("            The discovery pattern broke; a green result here would mean nothing.", file=sys.stderr)
    sys.exit(2)

pre = [f for f in found if f[0] < boundary]
if not pre:
    print(f"CANNOT-RUN: no plist found above the boundary at line {boundary} -- discovery or boundary is wrong.", file=sys.stderr)
    sys.exit(2)

STAGING = re.compile(r'\$\{?(OSTLER_DIR|LOGS_DIR)\b')
failures = 0
for line_no, name, quoted, body in pre:
    if quoted:
        print(f"  ok: {name} (line {line_no}) heredoc is quoted -- no expansion, safe by construction")
        continue
    hits = [(n, t.strip()) for n, t in body if STAGING.search(t)]
    if hits:
        failures += 1
        print(f"FAIL: {name} (line {line_no}) is ABOVE the promote boundary (line {boundary}) and names a staging-bound variable.", file=sys.stderr)
        print(f"      On a fresh install OSTLER_DIR/LOGS_DIR are still /tmp/ostler-prelaunch-<pid> here.", file=sys.stderr)
        print(f"      A plist is durable and /tmp is wiped at reboot, so this agent dies on first restart.", file=sys.stderr)
        print(f"      Use OSTLER_FINAL_DIR instead. Offending lines:", file=sys.stderr)
        for n, t in hits:
            print(f"        {n}: {t}", file=sys.stderr)
    else:
        print(f"  ok: {name} (line {line_no}) above boundary, no staging-bound variable")

print(f"  EXAMINED: {len(found)} plist heredocs discovered, {len(pre)} above the boundary at line {boundary}, {len(pre)} checked, {failures} tainted")
sys.exit(1 if failures else 0)
PYEOF
_sweep_rc=$?
if [[ "$_sweep_rc" -eq 2 ]]; then
    echo "test_launchd_plist_no_tmp: CANNOT-RUN (whole-class sweep could not establish its own scope)" >&2
    exit 2
elif [[ "$_sweep_rc" -ne 0 ]]; then
    FAILED=1
fi

# CONTROL for the sweep itself. The rule above must FIRE on a plist that names
# a staging-bound variable above the boundary -- otherwise "0 tainted" and
# "the predicate is blind" print identically, and only one of them is a gate.
_ctrl="$(python3 - <<'PYEOF'
import re
STAGING = re.compile(r'\$\{?(OSTLER_DIR|LOGS_DIR)\b')
specimen = '    <string>${LOGS_DIR}/engine-supervisor.log</string>'
clean    = '    <string>${OSTLER_FINAL_DIR}/logs/engine-supervisor.log</string>'
print("FIRES" if STAGING.search(specimen) and not STAGING.search(clean) else "BLIND")
PYEOF
)"
if [[ "$_ctrl" != "FIRES" ]]; then
    failure "sweep control: the staging-bound predicate does not discriminate (got '${_ctrl}') -- the sweep's zero proves nothing"
else
    echo "  ok: sweep control -- the predicate fires on a staging-bound path and ignores the canonical one"
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo "test_launchd_plist_no_tmp: FAILED" >&2
    exit 1
fi
echo "test_launchd_plist_no_tmp: PASS -- no shipped com.*ostler*.plist path resolves under /tmp"
