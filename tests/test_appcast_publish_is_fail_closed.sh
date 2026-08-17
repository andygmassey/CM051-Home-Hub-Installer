#!/usr/bin/env bash
# The appcast publish must FAIL a cut when it cannot publish, not warn and pass.
#
# MEASURED 2026-08-17. `PUBLISH_APPCAST ?= auto` plus an unset
# OSTLER_SPARKLE_SIGNING_KEY made publish-appcast print a warning and exit 0.
# Every cut reported success while publishing nothing, so the live appcast
# serves a valid Sparkle feed with ZERO items and no installed Hub can ever
# upgrade. The key is in no secret store: CM051 has 7 secrets and none is the
# Sparkle key, CM050 has none at all. So this was never one forgotten export;
# it could not have published on any cut, ever.
#
# A warning nobody is forced to read is not a control.
set -uo pipefail
MK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gui/Makefile"
PASS=0; FAIL=0
ok(){ printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

[[ -f "$MK" ]] || { echo "CANNOT RUN: no gui/Makefile at $MK"; exit 2; }

# 1. The default must be hard-require. This is the whole fix.
def="$(grep -E '^PUBLISH_APPCAST[[:space:]]*\?=' "$MK" | head -1 | sed -E 's/.*\?=[[:space:]]*//')"
[[ -n "$def" ]] || { echo "CANNOT RUN: no PUBLISH_APPCAST default found"; exit 2; }
case "$def" in
    1|yes) ok "default is hard-require ($def)" ;;
    auto)  no "default is 'auto' -- a missing key warns and exits 0, which is the defect" ;;
    *)     no "default is '$def' -- not a hard-require value" ;;
esac

# 2. The hard arm must still exist and must exit non-zero.
grep -q 'hard-require) but OSTLER_SPARKLE_SIGNING_KEY is unset' "$MK" \
    && ok "the hard arm still names the missing key in its failure text" \
    || no "the hard arm's failure text no longer names OSTLER_SPARKLE_SIGNING_KEY"

# 3. The warn-and-pass arm must survive ONLY behind an explicit opt-in, so a
#    future edit cannot quietly restore it as the default.
grep -q 'PUBLISH_APPCAST=1' "$MK" \
    && ok "an explicit opt-in path is documented" \
    || no "no explicit opt-in documented"

# 4. Positive control: this test must be able to SEE a bad default. If the
#    grep silently matched nothing we would pass on an empty string.
probe="$(mktemp)"; trap 'rm -f "$probe"' EXIT
sed -E 's/^PUBLISH_APPCAST([[:space:]]*)\?=.*/PUBLISH_APPCAST\1?= auto/' "$MK" > "$probe"
bad="$(grep -E '^PUBLISH_APPCAST[[:space:]]*\?=' "$probe" | head -1 | sed -E 's/.*\?=[[:space:]]*//')"
[[ "$bad" == "auto" ]] \
    && ok "positive control: the predicate DOES detect a reverted default" \
    || no "positive control failed -- this test cannot see the defect it guards"

echo; echo "  $PASS passed, $FAIL failed"; [[ $FAIL == 0 ]] || exit 1
echo "APPCAST PUBLISH IS FAIL-CLOSED"
