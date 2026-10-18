#!/usr/bin/env bash
#
# tests/test_assistant_sandbox_is_pinned_to_seatbelt.sh
#
# The assistant config install.sh emits must pin the command sandbox to macOS
# Seatbelt explicitly: [security.sandbox] enabled = true, backend =
# "sandbox-exec". (v1.0.103 security pass, from the Muse comparison.)
#
# MEASURED 2026-09-26 on a Mac with a working install: the daemon default
# "auto" picked Seatbelt (assistant log: "macOS sandbox-exec (Seatbelt)
# enabled"). The pin is so the customer's isolation does not rest on an
# upstream auto-detect order (Bubblewrap, then Seatbelt, then Docker) that a
# runtime bump can reorder.
#
# Same render-and-parse shape as test_hub_chat_carries_the_chat_tool_set.sh:
# slice the `{ ... } > "$ASSISTANT_CONFIG"` block out of install.sh, run it
# with every variable empty, parse with tomllib, assert on the parsed VALUE,
# and check the value against the daemon's own enum spelling.
#
# Exit: 0 all pass, 1 any FAIL, 2 CANNOT-RUN.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${INSTALL_SH:-${REPO_ROOT}/install.sh}"

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
ok "emitter rendered a config.toml"

# The spellings the daemon accepts for SandboxBackend::SandboxExec
# (zeroclaw-config schema.rs: rename_all = "lowercase", alias "sandbox-exec").
out="$("$PY" - "$CONFIG" <<'PYEOF'
import sys, tomllib
c = tomllib.load(open(sys.argv[1], "rb"))
sb = c.get("security", {}).get("sandbox")
if sb is None:
    print("MISSING"); sys.exit(0)
print(f"{sb.get('enabled')!r}|{sb.get('backend')!r}")
PYEOF
)"
case "$out" in
    MISSING) bad "the emitted config has no [security.sandbox] table: the backend is left to auto-detect" ;;
    "True|'sandbox-exec'"|"True|'sandboxexec'") ok "[security.sandbox] enabled = true, backend = Seatbelt (${out#*|})" ;;
    *) bad "[security.sandbox] is enabled|backend = ${out}; want True|'sandbox-exec'" ;;
esac

# CONTROL: the parser must see a wrong backend as wrong, or the pass above is blind.
ctl="$(mktemp -t sbctl.XXXXXX)"; trap 'rm -f "$ctl"' EXIT
printf '[security.sandbox]\nenabled = true\nbackend = "auto"\n' > "$ctl"
cout="$("$PY" -c 'import sys,tomllib;s=tomllib.load(open(sys.argv[1],"rb"))["security"]["sandbox"];print(repr(s.get("enabled"))+"|"+repr(s.get("backend")))' "$ctl")"
[ "$cout" = "True|'auto'" ] && ok "CONTROL: a backend of auto parses as auto, which the case above rejects" \
    || bad "CONTROL: the parser read a known auto backend as ${cout}"

echo "RESULT: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
