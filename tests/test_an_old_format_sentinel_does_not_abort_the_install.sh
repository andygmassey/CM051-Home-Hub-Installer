#!/usr/bin/env bash
# A sentinel written by an older Ostler must not abort the upgrade
# ================================================================
#
# THE INPUT THIS TEST REPLAYS
#
# `_hydrate_compute_change` reads the previous sentinel before overwriting it:
#
#     prev_count="$(grep -m1 '^item_count=' "$sentinel" 2>/dev/null | cut -d= -f2-)"
#
# `grep` exits 1 on NO MATCH. Under `set -Eeuo pipefail` that makes the whole
# substitution non-zero, there is no `||`, `set -e` aborts, and `2>/dev/null`
# has already discarded the reason. The customer gets a generic
# ERR-99-INSTALL-ABORT with nothing to read.
#
# WHY A NO-MATCH IS A REAL STATE, NOT A HYPOTHETICAL
#
# `item_count=` was introduced by #1346 (b38af35d). Measured: 6 of 242 tags
# contain it -- v1.0.60 and later. Every build up to v1.0.59 wrote sentinels
# with no `item_count=` and no `last_update_at=`. The fixture below is not
# invented: it is the shape `git show v1.0.59:install.sh` actually writes.
#
# The helper is called from EVERY hydrate block and its own header says it
# "MUST be called before the `> \"$sentinel\"` write", so the abort lands early
# in hydrate on a customer whose only distinguishing feature is not having
# upgraded for a few versions.
#
# WHAT IS TRACED AND NOT EXECUTED, SO NOBODY INHERITS IT AS FACT
#
# Whether an upgrading box still HOLDS an old sentinel when this runs depends
# on the path: promote replaces whole top-level entries, and on the reuse path
# it runs BEFORE `state/` exists in the staging tree, so `~/.ostler/state`
# survives. That ordering is traced from the source, not executed. Andy's Hub
# was checked read-only and carries 11 sentinels, all NEW format, so it cannot
# demonstrate it either. This test pins the HELPER's behaviour, which is
# executed, and makes no claim about how often the input arises.
#
# WHAT THIS TEST ASSERTS
#
#   A  ORIGINAL FAILING INPUT. The real helper, given a v1.0.59-format
#      sentinel, must RETURN rather than abort.
#   B  POSITIVE CONTROL. A NEW-format sentinel still computes the same
#      change fields, so the fix cannot be "ignore the file".
#   C  NEGATIVE CONTROL, MUST ABORT. The pre-fix form of the same statement
#      aborts under the same options. Without it, arm A could pass because the
#      harness cannot see an abort at all.
#   D  NO SENTINEL AT ALL is unaffected -- the first-install path.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
fatal(){ printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }
ok(){ PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
[ -f "$SUBJECT" ] || fatal "no install.sh at ${SUBJECT}"
_t="${TMPDIR:-/tmp}"; WORK="$(mktemp -d "${_t%/}/oldsent-XXXXXX")" || fatal "no work dir"
trap 'rm -rf "$WORK"' EXIT

awk '/^_hydrate_compute_change\(\)/{f=1} f{print} f&&/^\}/{exit}' "$SUBJECT" > "${WORK}/fn.sh"
[ -s "${WORK}/fn.sh" ] || fatal "could not extract _hydrate_compute_change; this test would measure nothing"
grep -q 'item_count=' "${WORK}/fn.sh" || fatal "the extracted helper does not read item_count -- extraction hit the wrong function"
bash -n "${WORK}/fn.sh" || fatal "the extracted helper does not parse"

_run() { # $1 = sentinel body ("" = no file). Echoes "<rc>|<item_count>"
    local body="$1" d="${WORK}/r"; rm -rf "$d"; mkdir -p "$d"
    local s="${d}/imessage.done"
    [ -n "$body" ] && printf '%s' "$body" > "$s"
    {
        printf '%s\n' 'set -Eeuo pipefail'
        cat "${WORK}/fn.sh"
        printf '_hydrate_compute_change %q 5 "2026-09-04T18:00:00Z"\n' "$s"
        printf '%s\n' 'printf "%s" "${_HY_ITEM_COUNT:-}"'
    } > "${d}/run.sh"
    local out rc
    out="$(bash "${d}/run.sh" 2>/dev/null)"; rc=$?
    printf '%s|%s' "$rc" "$out"
}

OLD=$'recorded_at=2026-08-01T00:00:00Z\nsource=imessage\nstatus=ok\npayload=people=3\n'
NEW=$'recorded_at=2026-08-01T00:00:00Z\nsource=imessage\nstatus=ok\nitem_count=5\nlast_update_at=2026-08-01T00:00:00Z\npayload=people=3\n'

# --- C first: prove the harness can SEE an abort ----------------------------
cat > "${WORK}/neg.sh" <<'EOS'
set -Eeuo pipefail
s="$1"
prev="$(grep -m1 '^item_count=' "$s" 2>/dev/null | cut -d= -f2-)"
printf 'reached'
EOS
printf '%s' "$OLD" > "${WORK}/neg.done"
bash "${WORK}/neg.sh" "${WORK}/neg.done" >/dev/null 2>&1
NEG=$?
if [ "$NEG" -ne 0 ]; then
    ok "C  negative control: the PRE-FIX statement aborts on an old sentinel (rc=${NEG})"
else
    fatal "the pre-fix statement did NOT abort. This harness cannot see the defect, so every arm below would be a false green."
fi

IFS='|' read -r RC_A CNT_A <<< "$(_run "$OLD")"
if [ "$RC_A" = "0" ]; then
    ok "A  a v1.0.59-format sentinel does not abort (item_count=${CNT_A})"
else
    bad "A  a v1.0.59-format sentinel ABORTS the install (rc=${RC_A}). Every box upgrading from <= v1.0.59 hits this."
fi

IFS='|' read -r RC_B CNT_B <<< "$(_run "$NEW")"
if [ "$RC_B" = "0" ] && [ "$CNT_B" = "5" ]; then
    ok "B  positive control: a NEW-format sentinel still computes its fields (item_count=${CNT_B})"
else
    bad "B  a new-format sentinel now returns rc=${RC_B} item_count=${CNT_B}; the fix has broken the normal path"
fi

IFS='|' read -r RC_D CNT_D <<< "$(_run "")"
if [ "$RC_D" = "0" ]; then
    ok "D  no sentinel at all is unaffected (first install)"
else
    bad "D  the first-install path now aborts (rc=${RC_D})"
fi

printf '\nCONCLUSION HISTOGRAM\n  PASS : %d\n  FAIL : %d\n  TOTAL: %d\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
