#!/usr/bin/env bash
# The wiki compiler must get OSTLER_TZ (owner's IANA zone) from the Mac at each
# compile tick and at install; a missing/unreadable zone must be SAID and
# yield empty (the wiki then labels UTC), never a silent guess.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TICK="$ROOT/wiki-recompile/bin/wiki-recompile-tick.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

sed -n '/^# >>> owner-tz/,/^# <<< owner-tz/p' "$TICK" > "$T/fn.sh"
[[ -s "$T/fn.sh" ]] || fail "owner-tz block missing from the tick script"
# shellcheck source=/dev/null
. "$T/fn.sh"

ln -s /usr/share/zoneinfo/Asia/Hong_Kong "$T/lt"
got="$(ostler_owner_tz "$T/lt" 2>"$T/err")"
[[ "$got" == "Asia/Hong_Kong" ]] || fail "expected Asia/Hong_Kong, got '$got'"
[[ ! -s "$T/err" ]] || fail "unexpected stderr on the good path"

# missing -> empty AND loud
got="$(ostler_owner_tz "$T/nope" 2>"$T/err")"
[[ -z "$got" ]] || fail "missing link must give empty, got '$got'"
grep -q "labelled UTC" "$T/err" || fail "missing link was silent"

# regular file (not a symlink) -> empty AND loud
: > "$T/plain"
got="$(ostler_owner_tz "$T/plain" 2>"$T/err")"
[[ -z "$got" ]] || fail "non-symlink must give empty"
grep -q "labelled UTC" "$T/err" || fail "non-symlink was silent"

# odd target -> empty AND loud
ln -s "/tmp/not a zone" "$T/odd"
got="$(ostler_owner_tz "$T/odd" 2>"$T/err")"
[[ -z "$got" ]] || fail "odd target must give empty"
grep -q "labelled UTC" "$T/err" || fail "odd target was silent"

# wiring: tick exports it; compose passes it; install-time compile derives it
grep -q '^export OSTLER_TZ' "$TICK" || fail "tick does not export OSTLER_TZ"
grep -q -- '- OSTLER_TZ=${OSTLER_TZ:-}' "$ROOT/install.sh" || fail "compose does not pass OSTLER_TZ"
grep -q 'OSTLER_TZ="${_tzl#\*zoneinfo/}"' "$ROOT/install.sh" || fail "install-time compile does not derive OSTLER_TZ"
echo "PASS: test_wiki_compile_gets_owner_tz"
