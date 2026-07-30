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

if [[ "$FAILED" -ne 0 ]]; then
    echo "test_launchd_plist_no_tmp: FAILED" >&2
    exit 1
fi
echo "test_launchd_plist_no_tmp: PASS -- no shipped com.*ostler*.plist path resolves under /tmp"
