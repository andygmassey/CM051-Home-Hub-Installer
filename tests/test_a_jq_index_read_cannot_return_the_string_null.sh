#!/usr/bin/env bash
# `jq -r '.[0].field'` on an EMPTY array prints the literal string `null`.
# It is 4 bytes, so `[ -z "$x" ]` does NOT fire, and the value flows onward as
# though it were real. Every consequence is downstream of that one fact.
#
# It bit twice in one hour on 2026-09-07:
#   HR015 CLAUDE.md   a branch sweep called three NEVER-MERGED branches
#                     "spent, safe to delete", because "<date>" > "null" is
#                     false. FAILED TOWARD DELETION.
#   CM051 this repo   test_appcast_debt_is_collected.sh asked for
#                     releases/tags/null and then blamed the LOOKUP for not
#                     finding "a tag the LIST just returned".
#
# The second ends in CANNOT-RUN so nothing passes that should not. The damage is
# the sentence: a refusal that names the wrong cause costs the next person a
# session.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

echo "test_a_jq_index_read_cannot_return_the_string_null"
command -v jq >/dev/null || { echo "  CANNOT-RUN: jq absent. NOT a pass."; exit 3; }

# 1. The trap itself, demonstrated rather than asserted from memory.
v="$(printf '[]' | jq -r '.[0].tag_name' 2>/dev/null)"
n=$(printf '%s' "$v" | wc -c | tr -d ' ')
if [[ "$n" == "4" && -n "$v" ]]; then
  ok "1 bare .[0].field on an empty list yields 4 bytes and survives -z (this is the trap)"
else
  no "1 expected 4 bytes that survive -z, got ${n} bytes: '${v}'"
fi

# 2. The fix empties it, so the caller's own guard fires.
w="$(printf '[]' | jq -r '.[0].tag_name // empty' 2>/dev/null)"
[[ -z "$w" ]] && ok "2 '// empty' yields 0 bytes, so -z fires" \
              || no "2 '// empty' did not empty it: '${w}'"

# 3. CONTROL, and it is the one that stops the fix being a lobotomy: a NON-empty
#    list must still yield its real value through the same expression. Without
#    this arm, '// empty' returning nothing for everything would pass arms 1-2.
x="$(printf '[{"tag_name":"hub-v0.4.73"}]' | jq -r '.[0].tag_name // empty' 2>/dev/null)"
[[ "$x" == "hub-v0.4.73" ]] && ok "3 control: a non-empty list still yields its real value" \
                            || no "3 control: '// empty' broke the happy path, got '${x}'"

# 4. The call site this test was written for carries the fix.
F="${ROOT}/tests/test_appcast_debt_is_collected.sh"
if [[ ! -r "$F" ]]; then
  printf '  SKIP 4 %s not readable. NOT a pass.\n' "$F"
else
  # Only EXECUTABLE lines: a comment explaining the trap must not satisfy the check.
  bad=$(grep -vE '^[[:space:]]*#' "$F" | grep -cE "jq '\.\[0\]\.[A-Za-z_]+'" || true)
  [[ "$bad" -eq 0 ]] && ok "4 no unguarded .[0].field read remains in that file" \
                     || no "4 ${bad} unguarded .[0].field read(s) still in that file"
fi

# 5. CONTROL on arm 4's predicate: it must be able to SEE an unguarded read.
tmp="$(mktemp)"; printf 'x="$(gh api foo --jq %s.[0].tag_name%s)"\n' "'" "'" > "$tmp"
seen=$(grep -vE '^[[:space:]]*#' "$tmp" | grep -cE "jq '\.\[0\]\.[A-Za-z_]+'" || true)
rm -f "$tmp"
[[ "$seen" -eq 1 ]] && ok "5 control: the arm-4 predicate does detect an unguarded read" \
                    || no "5 control: arm 4 cannot see an unguarded read, so its 0 means nothing"

echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
