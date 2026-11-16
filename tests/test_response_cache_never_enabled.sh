#!/bin/bash
# ==========================================================================
# test_response_cache_never_enabled.sh
#
# The shipped Hub config must never turn on the assistant's response cache.
#
# The cache answers a repeated question from its last answer for the TTL. It
# is keyed on the question and the model, not on the store, so after a forget
# or a privacy relabel it can replay withheld content. The daemon now binds the
# key to a store generation (ostler-assistant, response_cache), but until that
# is shipped and proven on a walk, nothing the installer writes may enable it.
#
# This reads what ships: install.sh and every other tracked file outside tests/
# and docs. It fails if any of them sets response_cache_enabled to true.
#
# The instrument and the defect share a surface: the scanner below is run over
# the real tree (must be clean), over a fixture that must be caught (control),
# and over a mutant of install.sh that enables the cache (must go red).
# ==========================================================================
set -uo pipefail

REPO=${REPO:-$(cd "$(dirname "$0")/.." && pwd)}
PATTERN='response_cache_enabled[[:space:]]*=[[:space:]]*true'

# scan <file>: prints each hit; exit 0 if at least one hit, 1 if none, 2 if unreadable.
scan() {
  [ -r "$1" ] || return 2
  /usr/bin/grep -nE "$PATTERN" "$1"
}

fail=0
tmp=$(mktemp -d) || { echo "CANNOT-RUN: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

# 1. Real tree: every tracked, shipped file must be clean.
hits=""
while IFS= read -r f; do
  case "$f" in tests/*|*.md) continue ;; esac
  out=$(scan "$REPO/$f"); rc=$?
  if [ "$rc" -eq 2 ]; then echo "CANNOT-RUN: unreadable $f" >&2; exit 2; fi
  if [ "$rc" -eq 0 ]; then hits="$hits
$f: $out"; fi
done < <(cd "$REPO" && git ls-files)
if [ -n "$hits" ]; then
  echo "FAIL [shipped-config]: a shipped file enables the response cache:$hits"
  fail=1
else
  echo "PASS [shipped-config]: no shipped file sets response_cache_enabled = true"
fi

# 2. Control: the scanner catches the exact line the installer would write.
printf '%s\n' 'echo "response_cache_enabled = true"' > "$tmp/control.sh"
if scan "$tmp/control.sh" >/dev/null; then
  echo "PASS [control]: the scanner catches an enabled line"
else
  echo "FAIL [control]: the scanner missed a known enabled line; the check proves nothing"
  fail=1
fi

# 3. Mutant: install.sh with the cache switched on inside the [memory] block must go red.
if [ -r "$REPO/install.sh" ] && /usr/bin/grep -q 'embedding_dimensions = 768' "$REPO/install.sh"; then
  awk '{ print } /embedding_dimensions = 768/ { print "    echo \"response_cache_enabled = true\"" }' \
    "$REPO/install.sh" > "$tmp/install_mutant.sh"
  if scan "$tmp/install_mutant.sh" >/dev/null; then
    echo "PASS [mutant]: an install.sh that enables the cache is caught"
  else
    echo "FAIL [mutant]: an install.sh that enables the cache was NOT caught"
    fail=1
  fi
else
  echo "CANNOT-RUN [mutant]: the [memory] anchor is absent from install.sh" >&2
  exit 2
fi

exit $fail
