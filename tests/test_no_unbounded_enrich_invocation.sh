#!/usr/bin/env bash
# Every enrichment invocation in the shipped product carries an allowance.
#
# THE DEFECT, measured on main 8b281fd9.
#
# `bin/ostler-import` ran `enrich --all` with no --budget-seconds. The option
# default reads OSTLER_ENRICH_BUDGET_SECONDS and falls back to 600. Nothing
# sets that variable there: the recurring agent sets it in its own plist, and
# ostler-import is not the agent. So a customer with a GDPR export in
# ~/Downloads got a TEN MINUTE foreground stall during the install, watching a
# progress bar.
#
# THIS CORRECTS THE BOX-WALK DIAGNOSIS, which said "needs a timeout". Every
# client already has one: base.py:99 `timeout: float = 30.0`, and
# settings.request_timeout for the rest. The nine minutes observed in SYN_SENT
# was retries with backoff against an unreachable host. The wall-clock budget
# that bounds it landed AFTER the v1.0.33 tag (budget 7cc2a6f 19:07 +0800,
# tag a1cb850 13:30 +0800), which is why the walk saw no ceiling at all. A
# socket timeout would have changed nothing; the ceiling is the budget.
#
# WHAT THIS PINS
#   1. Every `enrich` invocation in install.sh carries --budget-seconds.
#      Not "the import one" -- ALL of them, because a second entry point
#      with no allowance is exactly how this recurred once already
#      (enrich_parallel, CM051 998f7a4).
#   2. DENOMINATOR PRINTED. A predicate that finds zero invocations passes
#      vacuously, and "0 of 0 bounded" reads identically to "all bounded".
#   3. POSITIVE CONTROL: the recurring agent's own tick must still be found,
#      so a scan that reaches nothing cannot report clean.
#   4. PROVED RED: the flag is stripped from a scratch copy and limb 1 must
#      fail. A check that cannot fail is not a check.
#
# The scan runs on the GENERATED script as well as install.sh itself, because
# the import path lives inside a quoted heredoc and a flag can be present in
# the generator while absent from what the customer actually runs.
#
# Exit: 0 pass, 1 real failure, 2 cannot-run.

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$REPO/install.sh"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; RST=$'\033[0m'
PASS=0; FAIL=0
ok()  { printf '  %sPASS%s  %s\n' "$GRN" "$RST" "$1"; PASS=$((PASS+1)); }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$RST" "$1"; FAIL=$((FAIL+1)); }

[ -f "$INSTALL_SH" ] || { echo "CANNOT RUN: no install.sh at $INSTALL_SH" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Render the generated importer exactly as the customer receives it. The
# heredoc is quoted, so nothing expands at generation time and the flag must
# be present verbatim in the OUTPUT, not only in the generator.
python3 - "$INSTALL_SH" "$TMP/ostler-import.sh" <<'PY' || { echo "CANNOT RUN: could not extract the generated importer" >&2; exit 2; }
import io, sys
lines = io.open(sys.argv[1], encoding="utf-8").read().split("\n")
start = next((i for i, l in enumerate(lines) if "IMPORTEOF" in l and "cat >" in l), None)
if start is None:
    sys.exit(1)
end = next((i for i, l in enumerate(lines) if i > start and l.strip() == "IMPORTEOF"), None)
if end is None:
    sys.exit(1)
io.open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines[start + 1:end]))
PY

# ── the predicate, applied to a file, so the red proof can reuse it ────────
# An invocation is a line running `services.enrich.src.cli enrich`. Comments
# are stripped first: this file and install.sh both DISCUSS the flag in prose,
# and a scan that counts its own documentation is the trap that bit the
# disclosure guard on #807.
count_invocations() {
    grep -v '^[[:space:]]*#' "$1" 2>/dev/null \
        | grep -c 'services\.enrich\.src\.cli[[:space:]]*enrich' || true
}
count_bounded() {
    grep -v '^[[:space:]]*#' "$1" 2>/dev/null \
        | grep 'services\.enrich\.src\.cli[[:space:]]*enrich' \
        | grep -c -- '--budget-seconds' || true
}

# The invocation and its flag may sit on different physical lines (the import
# call is a backslash continuation). Join continuations before counting, or
# every multi-line call reads as unbounded and the gate cries wolf.
join_continuations() {
    python3 - "$1" "$2" <<'PY'
import io, sys
src = io.open(sys.argv[1], encoding="utf-8").read()
io.open(sys.argv[2], "w", encoding="utf-8").write(src.replace("\\\n", " "))
PY
}

TOTAL=0; BOUNDED=0
for f in "$INSTALL_SH" "$TMP/ostler-import.sh"; do
    j="$TMP/$(basename "$f").joined"
    join_continuations "$f" "$j" || { echo "CANNOT RUN: join failed for $f" >&2; exit 2; }
    n="$(count_invocations "$j")"; b="$(count_bounded "$j")"
    TOTAL=$((TOTAL + n)); BOUNDED=$((BOUNDED + b))
    printf '  scanned %-28s invocations=%s bounded=%s\n' "$(basename "$f")" "$n" "$b"
done

# ── 2. DENOMINATOR, before any verdict ────────────────────────────────────
printf '  DENOMINATOR: %s enrich invocation(s) examined, %s carry an allowance\n' \
    "$TOTAL" "$BOUNDED"
if [ "$TOTAL" -eq 0 ]; then
    bad "found ZERO enrich invocations, so this gate examined nothing and its verdict is meaningless"
else
    ok "the scan reaches the enrichment call sites ($TOTAL found)"
fi

# ── 1. every invocation is bounded ────────────────────────────────────────
if [ "$TOTAL" -gt 0 ] && [ "$BOUNDED" -eq "$TOTAL" ]; then
    ok "every enrich invocation carries --budget-seconds ($BOUNDED of $TOTAL)"
else
    bad "$((TOTAL - BOUNDED)) of $TOTAL enrich invocation(s) run with no allowance, so the install can stall on the 600s default"
fi

# ── 3. POSITIVE CONTROL: the recurring tick is still present ──────────────
if grep -q 'com\.ostler\.enrich' "$INSTALL_SH"; then
    ok "POSITIVE CONTROL: the recurring enrichment agent is still installed"
else
    bad "POSITIVE CONTROL BROKEN: com.ostler.enrich is gone, so a short install-time allowance now loses the remainder"
fi

# ── 4. PROVED RED ─────────────────────────────────────────────────────────
sed 's/--budget-seconds/--REMOVED-FOR-RED-PROOF/g' \
    "$TMP/ostler-import.sh.joined" > "$TMP/red.sh"
r_total="$(count_invocations "$TMP/red.sh")"
r_bound="$(count_bounded "$TMP/red.sh")"
if [ "$r_total" -gt 0 ] && [ "$r_bound" -lt "$r_total" ]; then
    ok "PROVED RED: stripping the flag makes the predicate report $r_bound of $r_total"
else
    bad "PROVED RED FAILED: stripping the flag changed nothing ($r_bound of $r_total), so this gate cannot see the defect it exists to find"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
