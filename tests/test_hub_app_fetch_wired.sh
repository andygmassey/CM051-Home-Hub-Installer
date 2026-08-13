#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# `ship` must OBTAIN Ostler.app before it CHECKS for Ostler.app (task #332).
#
# WHAT BROKE. OSTLER_APP_PATH defaults to a sibling ostler-assistant checkout.
# That exists on the operator's Mac and cannot exist on a hosted runner, so
# every tagged cut from 2026-08-08 onward died at check-ostler-app -- eight
# runs across v1.0.23, v1.0.24 and v1.0.25, none of which produced a DMG:
#
#   ERROR: OSTLER_APP_PATH points at a path that does not exist:
#     /Users/runner/work/CM051-Home-Hub-Installer/ostler-assistant/...
#
# The gate was right and the pipeline was wrong. download-hub-app fetches the
# bundle; this pins that it is wired AHEAD of the gate that demands it. A fetch
# ordered after its own check is a fetch that never runs.
#
# ASKS MAKE, NOT THE TEXT. `make -pRrq` is make's own parsed database, so this
# cannot be fooled by a commented-out line, a line continuation, or a second
# `ship:` rule elsewhere in the file -- all of which a grep would misread.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/gui"

PASSED=0
FAILED=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; PASSED=$((PASSED+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*" >&2; FAILED=$((FAILED+1)); }

command -v make >/dev/null 2>&1 || { echo "CANNOT RUN: make not found" >&2; exit 2; }

echo "test_hub_app_fetch_wired"

# Returns the prerequisite list of $2 as parsed by make, from the makefile in $1.
prereqs_of() {
    ( cd "$1" && make -pRrq 2>/dev/null | grep -m1 "^$2:" | cut -d: -f2- )
}

SHIP_PREREQS="$(prereqs_of "$GUI_DIR" ship)"

if [[ -z "$SHIP_PREREQS" ]]; then
    bad "could not read ship's prerequisites from make's database.
       Not judging the order against an empty string -- a substring test
       against \"\" passes for the wrong reason."
    echo
    printf '\033[31m%s passed, %s failed\033[0m\n' "$PASSED" "$FAILED"
    exit 1
fi

# Position, not mere presence: the whole defect is one of ORDER.
pos_of() {
    local needle="$1" list="$2" i=0 word
    for word in $list; do
        i=$((i+1))
        [[ "$word" == "$needle" ]] && { echo "$i"; return 0; }
    done
    echo 0
}

FETCH_AT="$(pos_of download-hub-app "$SHIP_PREREQS")"
CHECK_AT="$(pos_of check-ostler-app "$SHIP_PREREQS")"

if (( FETCH_AT > 0 )); then
    ok "ship depends on download-hub-app (position $FETCH_AT)"
else
    bad "ship does NOT depend on download-hub-app. Nothing obtains Ostler.app,
       so any machine without a sibling ostler-assistant checkout -- which is
       every hosted runner -- fails at check-ostler-app.
       ship: $SHIP_PREREQS"
fi

if (( CHECK_AT > 0 )); then
    ok "ship still depends on check-ostler-app (position $CHECK_AT)"
else
    bad "check-ostler-app has been dropped from ship. That gate must STAY:
       a missing Hub app was once non-fatal and shipped a Hub-less DMG.
       Fetching the bundle is not a reason to stop checking for it.
       ship: $SHIP_PREREQS"
fi

if (( FETCH_AT > 0 && CHECK_AT > 0 )); then
    if (( FETCH_AT < CHECK_AT )); then
        ok "download-hub-app runs BEFORE check-ostler-app ($FETCH_AT < $CHECK_AT)"
    else
        bad "download-hub-app is ordered AFTER check-ostler-app ($FETCH_AT > $CHECK_AT).
       The check fires first and fails, so the fetch never runs. This is the
       exact eight-run failure the target was added to end.
       ship: $SHIP_PREREQS"
    fi
fi

# --- NEGATIVE CONTROL ------------------------------------------------------
# Everything above would also pass against a prereqs_of() that silently returns
# the same string regardless of input, or a pos_of() that reports 1 for
# anything. Build a makefile with the order DELIBERATELY WRONG and require the
# predicate to catch it. Without this the file is a guard-shaped no-op.
CTL_DIR="$(mktemp -d)"
cat > "$CTL_DIR/Makefile" <<'EOF'
ship: check-ostler-app download-hub-app
check-ostler-app:
	@true
download-hub-app:
	@true
EOF
CTL_PREREQS="$(prereqs_of "$CTL_DIR" ship)"
CTL_FETCH="$(pos_of download-hub-app "$CTL_PREREQS")"
CTL_CHECK="$(pos_of check-ostler-app "$CTL_PREREQS")"
rm -rf "$CTL_DIR"

if (( CTL_FETCH > 0 && CTL_CHECK > 0 && CTL_FETCH > CTL_CHECK )); then
    ok "CONTROL: a deliberately mis-ordered ship is detected as mis-ordered"
else
    bad "CONTROL FAILED: the probe did not see a KNOWN-BAD order
       (fetch=$CTL_FETCH check=$CTL_CHECK from: '$CTL_PREREQS').
       Either make's database format changed or pos_of/prereqs_of is broken.
       Either way the assertions above prove nothing about the real Makefile."
fi

echo
if (( FAILED == 0 )); then
    printf '\033[32m%s passed, 0 failed\033[0m\n' "$PASSED"
    exit 0
fi
printf '\033[31m%s passed, %s failed\033[0m\n' "$PASSED" "$FAILED"
exit 1
