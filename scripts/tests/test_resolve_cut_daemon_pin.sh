#!/usr/bin/env bash
#
# test_resolve_cut_daemon_pin.sh -- prove the hotfix fallback WARN actually FIRES.
#
# #794 shipped the fallback with no control driving it. Archie merged it anyway,
# correctly, because the change is strictly additive -- but flagged that the WARN
# is the entire safety mechanism and an unfired warn is a two-state predicate
# reading a warning as a pass. This is that control.
#
# Controls 2 and 3 are the load-bearing pair. 2 proves a four-part version WARNS
# and still returns the parent's pin. 3 proves a three-part version does NOT warn
# -- because a fallback that fires on every cut is noise, and noise gets muted,
# and a muted warning is the same as no warning.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/resolve_cut_daemon_pin.sh"
[[ -r "$SCRIPT" ]] || { echo "FAIL: not readable: $SCRIPT"; exit 99; }

PASS=0; FAIL=0
TMP="$(mktemp -d -t cutpin_resolve_XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Fixture: a repo with a three-part cut record only, which is the real shape --
# no four-part cuts/ directory has ever existed.
mkdir -p "$TMP/repo/cuts/v1.0.13" "$TMP/repo/cuts/v1.0.33"
printf 'CM051=abc\nDAEMON_COMMIT=1111111111aa\n' > "$TMP/repo/cuts/v1.0.13/cut.env"
printf 'CM051=def\nDAEMON_COMMIT=2222222222bb\n' > "$TMP/repo/cuts/v1.0.33/cut.env"
# A record that exists but declares no daemon pin at all.
mkdir -p "$TMP/repo/cuts/v1.0.40"
printf 'CM051=ghi\n' > "$TMP/repo/cuts/v1.0.40/cut.env"

run() { # run <version> -> sets OUT (stdout) and ERR (stderr)
    OUT="$(bash "$SCRIPT" "$TMP/repo" "$1" 2>"$TMP/err")"; RC=$?
    ERR="$(cat "$TMP/err")"
}

ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
no()   { printf '  FAIL  %s\n' "$1"; printf '%s\n' "${2:-}" | sed 's/^/        | /'; FAIL=$((FAIL+1)); }

echo "test_resolve_cut_daemon_pin"
echo

# 1. Exact three-part match returns its own pin.
run 1.0.33
[[ "$OUT" == "2222222222bb" ]] && ok "exact v1.0.33 -> its own pin" \
                               || no "exact v1.0.33 pin wrong: '$OUT'" "$ERR"

# ---------------------------------------------------------------------------
# 2. THE CONTROL #794 DID NOT HAVE.
#    A four-part version with no record of its own must WARN, name BOTH paths,
#    and state the consequence -- then still return the parent's pin so the cut
#    is not blocked on a convention that has never existed.
# ---------------------------------------------------------------------------
run 1.0.13.1
if [[ "$OUT" != "1111111111aa" ]]; then
    no "four-part falls back to the parent's pin: got '$OUT'" "$ERR"
else ok "four-part v1.0.13.1 -> parent's pin"; fi

grep -q 'no cut record for v1.0.13.1' <<<"$ERR" \
    && ok "and it WARNS, naming the missing version" \
    || no "the fallback WARN did not fire -- this is the whole point" "$ERR"

grep -q 'wanted:.*cuts/v1.0.13.1/cut.env' <<<"$ERR" \
    && ok "and names the path it WANTED" \
    || no "did not name the wanted path" "$ERR"

grep -q 'using:.*cuts/v1.0.13/cut.env' <<<"$ERR" \
    && ok "and names the path it USED" \
    || no "did not name the used path" "$ERR"

grep -q 'NOT the one being read' <<<"$ERR" \
    && ok "and states the CONSEQUENCE, not just the substitution" \
    || no "did not state the consequence" "$ERR"

# ---------------------------------------------------------------------------
# 3. THE OTHER HALF, AND IT IS NOT DECORATIVE.
#    A three-part version must NOT warn. A warning that fires on every cut is
#    noise; noise gets muted; a muted warning is no warning. If this control
#    ever goes red the WARN has become worthless without anyone editing it.
# ---------------------------------------------------------------------------
run 1.0.33
grep -q 'WARN' <<<"$ERR" \
    && no "a normal three-part cut WARNED -- the signal is now noise" "$ERR" \
    || ok "a normal three-part cut does NOT warn"

# 4. A record that exists but declares no DAEMON_COMMIT returns empty, so the
#    caller's fail-closed path (verify_app_provenance.sh -> CANNOT-RUN) engages.
run 1.0.40
[[ -z "$OUT" ]] && ok "record without DAEMON_COMMIT -> empty, caller blocks" \
                || no "expected empty, got '$OUT'" "$ERR"

# 5. No record anywhere: empty, and no misleading fallback warning either.
run 9.9.9
if [[ -n "$OUT" ]]; then no "expected empty for an unknown version, got '$OUT'" "$ERR"
elif grep -q 'falling back' <<<"$ERR"; then no "warned about a fallback that did not happen" "$ERR"
else ok "unknown version -> empty, and no false fallback warning"; fi

# 6. Usage errors are rc=2 and never a silent empty success.
bash "$SCRIPT" >/dev/null 2>&1; [[ $? == 2 ]] && ok "bare usage -> rc=2" || no "bare usage did not exit 2"
bash "$SCRIPT" "$TMP/nope" 1.0.33 >/dev/null 2>&1; [[ $? == 2 ]] && ok "missing repo -> rc=2" || no "missing repo did not exit 2"

echo
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]] || exit 1
echo "ALL CUT-PIN RESOLVER TESTS PASSED"
