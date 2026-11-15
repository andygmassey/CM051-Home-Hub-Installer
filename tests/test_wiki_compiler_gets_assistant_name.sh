#!/usr/bin/env bash
# S16b: the customer's assistant name must reach the wiki-compiler container.
# install.sh records ASSISTANT_NAME in config/.env, but docker compose
# interpolates ${ASSISTANT_NAME:-} in the wiki-compiler env from the COMPOSE
# .env. This test runs the real install.sh writer block against a temp compose
# .env, then resolves the real wiki-compiler env block from the compose heredoc
# against that .env, and asserts what the container would receive.
# Pure shell + awk. No docker. Runs under /bin/bash 3.2.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/install.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. The writer block, exactly as shipped.
sed -n '/^# >>> assistant-name-compose-env/,/^# <<< assistant-name-compose-env/p' "$INSTALL" > "$T/writer.sh"
[[ -s "$T/writer.sh" ]] || fail "assistant-name-compose-env block missing from install.sh"

run_writer() { # $1 = env file, $2 = assistant name ("" = unset)
    ( OSTLER_ENV_FILE="$1"
      if [[ -n "$2" ]]; then ASSISTANT_NAME="$2"; else unset ASSISTANT_NAME; fi
      # shellcheck source=/dev/null
      . "$T/writer.sh" )
}

# 2. The wiki-compiler service env block from the compose heredoc.
awk '
    /<<'\''DCEOF'\''/ { capture = 1; next }
    /^DCEOF$/         { capture = 0 }
    capture           { print }
' "$INSTALL" > "$T/compose.yml"
[[ -s "$T/compose.yml" ]] || fail "compose heredoc not found"
awk '
    /^  wiki-compiler:$/        { inside = 1; next }
    inside && /^  [a-z][a-z0-9_-]*:$/ { inside = 0 }
    inside && /^      - [A-Z_]+=/ { sub(/^      - /, ""); print }
' "$T/compose.yml" > "$T/svc_env"
[[ -s "$T/svc_env" ]] || fail "wiki-compiler env block not found"

# Resolve one wiki-compiler env entry the way compose does for ${VAR:-}.
resolve() { # $1 = env file, $2 = container var
    local line rhs var
    line="$(awk -F= -v k="$2" '$1 == k { print; exit }' "$T/svc_env")"
    [[ -n "$line" ]] || { echo "__ABSENT__"; return; }
    rhs="${line#*=}"
    case "$rhs" in
        '${'*':-}') var="${rhs#\$\{}"; var="${var%:-\}}" ;;
        *) echo "__UNEXPECTED_SHAPE__"; return ;;
    esac
    awk -v k="$var" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$1"
}

# 3. Configured name reaches the container; other lines survive; idempotent.
ENVF="$T/compose.env"
printf 'USER_FIRST_NAME=Jane\nASSISTANT_NAME=Stale\nAI_MODEL=qwen3.5:9b\n' > "$ENVF"
run_writer "$ENVF" "Robbie"
run_writer "$ENVF" "Robbie"
n="$(awk 'index($0, "ASSISTANT_NAME=") == 1' "$ENVF" | wc -l | tr -d ' ')"
[[ "$n" == "1" ]] || fail "expected exactly one ASSISTANT_NAME line in the compose .env, got $n"
grep -qx 'USER_FIRST_NAME=Jane' "$ENVF" || fail "writer dropped an unrelated line"
grep -qx 'AI_MODEL=qwen3.5:9b' "$ENVF" || fail "writer dropped an unrelated line"
got="$(resolve "$ENVF" ASSISTANT_NAME)"
[[ "$got" == "Robbie" ]] || fail "wiki-compiler would receive ASSISTANT_NAME='$got', expected 'Robbie'"
echo "PASS: configured assistant name reaches the wiki-compiler env"

# 4. A name with a space survives.
run_writer "$ENVF" "Robbie Two"
got="$(resolve "$ENVF" ASSISTANT_NAME)"
[[ "$got" == "Robbie Two" ]] || fail "multi-word name arrived as '$got'"
echo "PASS: multi-word name survives"

# 5. No name: the container gets empty, so CM044 uses the neutral "assistant".
EMPTYF="$T/empty.env"; : > "$EMPTYF"
run_writer "$EMPTYF" ""
got="$(resolve "$EMPTYF" ASSISTANT_NAME)"
[[ -z "$got" ]] || fail "unset name must give empty, got '$got'"
echo "PASS: unset name gives empty (CM044 neutral default)"

# 6. Control: the resolver sees a var that is NOT passed as absent.
[[ "$(resolve "$ENVF" NOT_A_PASSED_VAR)" == "__ABSENT__" ]] || fail "resolver control: absent var not reported absent"
echo "PASS: test_wiki_compiler_gets_assistant_name"
