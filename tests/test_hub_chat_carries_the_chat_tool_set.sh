#!/usr/bin/env bash
#
# tests/test_hub_chat_carries_the_chat_tool_set.sh
#
# Pins #2385's tool-set half: the config.toml install.sh emits must exclude
# the developer and admin tools from non-CLI chat, and must NOT exclude the
# tools a customer drives from chat.
#
# Why: every chat turn sends the full definition of every tool it may call.
# On a 16 GB walk box the full set was 14,204 prompt tokens per turn (simple
# replies 27-50s); excluding the tools below took it to 5,848 (16-21s).
#
# Same render-and-parse shape as test_skills_lockdown_config.sh: slice the
# `{ ... } > "$ASSISTANT_CONFIG"` block out of install.sh by its anchors,
# run it with every variable empty, parse the result with tomllib, and
# assert on the parsed VALUE. A comment or a conditional cannot satisfy it.
#
# Two sets, both asserted:
#   MUST_EXCLUDE  heavy tools that must be absent from chat
#   MUST_KEEP     tools chat needs: reminders (cron_add/list/remove,
#                 schedule), every pwg_* reader, memory. Excluding any of
#                 these silently removes a customer feature, e.g.
#                 "remind me every morning" stops working if cron_add goes.
#
# Exit: 0 all pass, 1 any FAIL, 2 CANNOT-RUN.

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

render_emitted_config() {   # $1 = install.sh to render; prints the config path
    local src="$1" work end start
    work="$(mktemp -d)"
    end="$(/usr/bin/grep -n '^} > "\$ASSISTANT_CONFIG"$' "$src" | head -1 | cut -d: -f1)"
    [ -n "$end" ] || return 1
    start="$(awk -v e="$end" 'NR < e && /^\{[[:space:]]*$/ { n = NR } END { print n }' "$src")"
    [ -n "$start" ] && [ "$start" -gt 0 ] || return 1
    sed -n "${start},${end}p" "$src" > "${work}/emit.sh"
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
    echo "CANNOT-RUN: rendered no config.toml from install.sh; the emitter anchors moved." >&2
    exit 2
fi
ok "emitter rendered a config.toml ($(/usr/bin/grep -c . "$CONFIG") non-blank line(s))"

CHECKER="$(mktemp -t chattools.XXXXXX)"
trap 'rm -f "$CHECKER"' EXIT
cat > "$CHECKER" <<'PYEOF'
import sys, tomllib

MUST_EXCLUDE = {
    "shell", "file_write", "file_edit", "git_operations", "browser",
    "browser_open", "model_routing_config", "proxy_config", "backup",
    "sessions_send", "memory_purge",
}
MUST_KEEP = {
    "cron_add", "cron_list", "cron_remove", "schedule",
    "pwg_people", "pwg_preferences", "pwg_overview", "pwg_commitments",
    "pwg_topics", "pwg_person_timeline", "pwg_knowledge_search",
    "memory_recall", "remember_fact", "web_search_tool",
}

raw = open(sys.argv[1], "rb").read()
if not raw.strip():
    print("checker received an EMPTY document", file=sys.stderr); sys.exit(3)
try:
    data = tomllib.loads(raw.decode("utf-8"))
except Exception as exc:  # noqa: BLE001
    print(f"emitted config is not valid TOML: {exc}", file=sys.stderr); sys.exit(1)

auto = data.get("autonomy")
if auto is None:
    print("no [autonomy] table: Hub chat carries all tools", file=sys.stderr); sys.exit(1)
excl = auto.get("non_cli_excluded_tools")
if not isinstance(excl, list) or not all(isinstance(x, str) for x in excl):
    print(f"non_cli_excluded_tools is {excl!r}, expected a list of strings", file=sys.stderr); sys.exit(1)
excl = set(excl)
problems = []
missing = sorted(MUST_EXCLUDE - excl)
if missing:
    problems.append("heavy tools still offered to chat: " + ", ".join(missing))
dropped = sorted(MUST_KEEP & excl)
if dropped:
    problems.append("chat tools wrongly excluded (customer feature lost): " + ", ".join(dropped))
extra = sorted(k for k in auto if k != "non_cli_excluded_tools")
if extra:
    problems.append("[autonomy] sets more than the exclusion list, overriding daemon defaults: " + ", ".join(extra))
for p in problems:
    print(p, file=sys.stderr)
sys.exit(1 if problems else 0)
PYEOF

check() { "$PY" "$CHECKER" "$1"; }

ERRF="$(mktemp)"
if check "$CONFIG" 2>"$ERRF"; then
    ok "emitted [autonomy].non_cli_excluded_tools drops the heavy tools and keeps the chat tools"
else
    bad "$(cat "$ERRF")"
fi

# Controls: each must make the checker go red, or the green above means nothing.
control_red() {   # $1 = label, $2 = TOML body
    local f; f="$(mktemp)"
    printf '%s\n' "$2" > "$f"
    if check "$f" 2>/dev/null; then bad "CONTROL DID NOT FIRE: $1"; else ok "control: red on $1"; fi
    rm -f "$f"
}
GOOD='"shell", "file_write", "file_edit", "git_operations", "browser", "browser_open", "model_routing_config", "proxy_config", "backup", "sessions_send", "memory_purge"'
control_red "no [autonomy] table"            '[skills]
allow_scripts = false'
control_red "empty exclusion list"           '[autonomy]
non_cli_excluded_tools = []'
control_red "cron_add excluded"              "[autonomy]
non_cli_excluded_tools = [${GOOD}, \"cron_add\"]"
control_red "a pwg reader excluded"          "[autonomy]
non_cli_excluded_tools = [${GOOD}, \"pwg_people\"]"
control_red "shell left in chat"             '[autonomy]
non_cli_excluded_tools = ["file_write", "file_edit", "git_operations", "browser", "browser_open", "model_routing_config", "proxy_config", "backup", "sessions_send", "memory_purge"]'
control_red "autonomy level overridden"      "[autonomy]
level = \"full\"
non_cli_excluded_tools = [${GOOD}]"
# Positive control: the minimal good list must pass, or the checker is simply always red.
f="$(mktemp)"; printf '[autonomy]\nnon_cli_excluded_tools = [%s]\n' "$GOOD" > "$f"
if check "$f" 2>/dev/null; then ok "positive control: minimal good list passes"; else bad "positive control failed: checker is always red"; fi
rm -f "$f"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
