#!/usr/bin/env bash
#
# tests/test_skills_lockdown_config.sh
#
# Locks the v1.0 Skills surface lockdown (task #559) in install.sh.
#
# Why this test exists:
#
#   The bundled ostler-assistant runtime exposes a Skills system
#   (zeroclaw skills install <source> + script execution gated by
#   skills.allow_scripts). Shipping an open "install any skill +
#   run its scripts" surface to customers at v1.0 is a remote-code-
#   execution / supply-chain risk on a privacy product.
#
#   v1.0 locks it down at the config layer (resign-free; the daemon
#   binary is unchanged): install.sh writes an explicit [skills]
#   block into the customer's assistant config.toml so the posture
#   never depends on an upstream default that could drift.
#
#     1. skills.allow_scripts = false    (blocks script execution)
#     2. skills.registry_url  = ""       (suppresses the bundled
#        third-party registry default + disables bare-name installs)
#
# ── WHY THIS TEST WAS REWRITTEN, 2026-09-23 ─────────────────────────
#
# It used to assert three `grep -q 'echo "allow_scripts = false"'`
# lines against install.sh. That is a presence-grep on the EMITTER,
# not on the config the emitter produces, and it was blind in two
# directions that both leave the RCE surface open.
#
# MEASURED, both against this repo's install.sh:
#
#   MUTATION A -- append one line to the same brace block:
#         echo "registry_url = \"\""
#       + echo "allow_scripts = true"
#     The old test printed 5 PASS and "ALL SKILLS LOCKDOWN CONFIG
#     TESTS PASSED", rc=0.
#
#   MUTATION E -- wrap the three echoes in a conditional, WITHOUT
#     re-indenting them:
#       + if [ "${CHANNEL_EMAIL_CONFIGURED:-}" = "yes" ]; then
#             echo "[skills]"
#             ...
#       + fi
#     The old test printed 5 PASS, rc=0 -- INCLUDING its own
#     "emitted unconditionally" indent check, because the echoes were
#     still at four spaces. Mutation E is precisely the failure the old
#     header warned about in as many words ("a future edit that wraps
#     the block in an `if` ... would silently disable the lockdown").
#     The test carried the warning and could not detect the thing.
#
# WHAT IT DOES NOW: runs the emitter and reads the ARTEFACT. It slices
# the `{ ... } > "$ASSISTANT_CONFIG"` block out of install.sh by its
# anchors, executes it with every variable empty, and parses the
# config.toml that falls out with a real TOML parser. The assertion is
# on the VALUE tomllib returns, so prose cannot satisfy it:
#
#   mutation A  -> TOML parse error (duplicate key)  -> FAIL
#   mutation B  -> allow_scripts is True             -> FAIL
#   mutation C  -> block commented out, no [skills]  -> FAIL
#   mutation E  -> conditional never fires, no [skills] -> FAIL
#
# 🔴 THE BOUNDS ARE FOUND, NEVER HARDCODED, AND THE OUTPUT IS FRESH.
# The first draft of this harness sliced fixed line numbers and reused
# one output path. Mutation A adds a line, which pushed the closing
# brace out of the slice; the block then failed to parse, wrote
# nothing, and the harness read the PREVIOUS run's config.toml and
# reported it clean. A stale artefact reads exactly like a fresh pass.
# So: anchors, a fresh mktemp per render, and an empty render is
# CANNOT-RUN rather than anything else.
#
# Sister test, same render-and-parse shape:
#   - test_assistant_config_required_fields.sh
#
# The full surface-off (hiding the install/test subcommands) is a
# binary change and ships in v1.0.1 with the Curator gallery (#546);
# this test pins only the resign-free config-layer half.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"

pass=0
fail=0
ok()  { printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }

[[ -f "$INSTALL_SCRIPT" ]] || { echo "CANNOT-RUN: install.sh not found at $INSTALL_SCRIPT" >&2; exit 2; }

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3 for TOML parsing" >&2; exit 2; }
"$PY" -c 'import tomllib' 2>/dev/null || { echo "CANNOT-RUN: python3 lacks tomllib (needs 3.11+)" >&2; exit 2; }

if bash -n "$INSTALL_SCRIPT" 2>/dev/null; then
    ok "install.sh parses (bash -n)"
else
    bad "install.sh fails bash -n parse check"
fi

# ── Render: execute the emitter, keep the artefact ──────────────────
#
# Every variable is left unset and `set +u` makes each expand empty, so
# optional blocks take their false branch and only the UNCONDITIONAL
# statements emit. That is what makes mutation E detectable: a [skills]
# block behind any condition simply does not appear.
render_emitted_config() {   # $1 = install.sh to render; prints the config path
    local src="$1" work end start
    work="$(mktemp -d)"
    end="$(/usr/bin/grep -n '^} > "\$ASSISTANT_CONFIG"$' "$src" | head -1 | cut -d: -f1)"
    [ -n "$end" ] || return 1
    start="$(awk -v e="$end" 'NR < e && /^\{[[:space:]]*$/ { n = NR } END { print n }' "$src")"
    [ -n "$start" ] && [ "$start" -gt 0 ] || return 1
    sed -n "${start},${end}p" "$src" > "${work}/emit.sh"
    # Sandbox every path-shaped variable the block touches, and stub the
    # one helper it calls, so rendering cannot reach outside ${work}.
    {
        echo 'set +u'
        echo "OSTLER_DIR=\"${work}/ostler\""
        echo "mkdir -p \"\${OSTLER_DIR}\""
        echo '_esc() { printf "%s" "$1"; }'
        echo "ASSISTANT_CONFIG=\"${work}/config.toml\""
        echo ". \"${work}/emit.sh\""
    } > "${work}/run.sh"
    bash "${work}/run.sh" >/dev/null 2>"${work}/err"
    printf '%s' "${work}/config.toml"
}

CONFIG="$(render_emitted_config "$INSTALL_SCRIPT")"
if [ -z "${CONFIG:-}" ] || [ ! -s "$CONFIG" ]; then
    echo "CANNOT-RUN: rendered no config.toml from install.sh -- the emitter anchors moved." >&2
    echo "            An empty render is not a clean config." >&2
    exit 2
fi
ok "emitter rendered a config.toml ($(/usr/bin/grep -c . "$CONFIG") non-blank line(s))"

# ── The checker: asserts on the parsed VALUE, never on the text ─────
CHECKER="$(mktemp -t skillscheck.XXXXXX.py)"
trap 'rm -f "$CHECKER"' EXIT
cat > "$CHECKER" <<'PYEOF'
import sys, tomllib

raw = open(sys.argv[1], "rb").read()
if not raw.strip():
    print("checker received an EMPTY document; refusing to call that clean", file=sys.stderr)
    sys.exit(3)
try:
    data = tomllib.loads(raw.decode("utf-8"))
except Exception as exc:                                    # noqa: BLE001
    print(f"emitted config is not valid TOML: {exc}", file=sys.stderr)
    sys.exit(1)

skills = data.get("skills")
if skills is None:
    print("no [skills] table in the emitted config -- the lockdown did not ship", file=sys.stderr)
    sys.exit(1)

problems = []
# `is False`, not a truthiness test and not a string compare: TOML `false`
# must arrive as a real boolean. The string "false" is truthy in Python and
# would sail through a naive check while the daemon read it as a parse error.
if skills.get("allow_scripts") is not False:
    problems.append(f"skills.allow_scripts is {skills.get('allow_scripts')!r}, expected boolean False")
if skills.get("registry_url") != "":
    problems.append(f"skills.registry_url is {skills.get('registry_url')!r}, expected the empty string")

if problems:
    for p in problems:
        print(p, file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PYEOF

check() { "$PY" "$CHECKER" "$1"; }

# ── THE ASSERTION ───────────────────────────────────────────────────
ERRF="$(mktemp)"
if check "$CONFIG" 2>"$ERRF"; then
    ok "emitted config.toml has skills.allow_scripts = false and registry_url = \"\""
else
    rc=$?
    if [ "$rc" = "3" ]; then
        bad "checker got an empty document: $(cat "$ERRF")"
    else
        bad "$(cat "$ERRF")"
    fi
fi

# ── CONTROLS. A green that a dead checker could also produce is not a
# ── measurement, so each mutation below MUST make the checker go red.
control_red() {   # $1 = label, $2 = TOML body
    local f; f="$(mktemp)"
    printf '%s\n' "$2" > "$f"
    if check "$f" 2>/dev/null; then
        bad "CONTROL DID NOT FIRE: checker passed $1"
    else
        ok "control: checker goes red on $1"
    fi
    rm -f "$f"
}

control_red "allow_scripts = true"           '[skills]
allow_scripts = true
registry_url = ""'
control_red "a third-party registry_url"     '[skills]
allow_scripts = false
registry_url = "https://skills.example.invalid"'
control_red "no [skills] table at all"       'schema_version = 2
[memory]
backend = "sqlite"'
control_red "allow_scripts as the STRING \"false\"" '[skills]
allow_scripts = "false"
registry_url = ""'
control_red "a duplicated allow_scripts key" '[skills]
allow_scripts = false
registry_url = ""
allow_scripts = true'

# The other direction: the checker must accept a correct document, else
# every red above is a red the checker would have produced regardless.
GOODF="$(mktemp)"
printf '[skills]\nallow_scripts = false\nregistry_url = ""\n' > "$GOODF"
if check "$GOODF" 2>/dev/null; then
    ok "control: checker accepts a correctly locked-down [skills] table"
else
    bad "FALSE POSITIVE: checker rejected a correct [skills] table"
fi
rm -f "$GOODF" "$ERRF"

echo
echo "== skills lockdown: ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
