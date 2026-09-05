#!/usr/bin/env bash
# Every terminal DONE marker must be the LAST thing a run emits.
#
# MEASURED on origin/main 2fb58d1e:
#
#   gui_done call sites in install.sh           4   (1796, 10481, 10655, 30695)
#   OSTLER_DONE_EMITTED written inside gui_done  2   (progress_emitter.sh 738, 759)
#   OSTLER_DONE_EMITTED read inside gui_done     0   <- the point of this file
#   read by the two trap handlers                2   (install.sh 10466, 10601)
#
# 🔴 gui_done IS NOT IDEMPOTENT. The sentinel is written inside it and never
# read by it, so calling it twice emits two terminal markers. Today that cannot
# happen, and each site is safe for a DIFFERENT reason:
#
#   1796   inside fail(), immediately followed by `exit 1`
#   10481  inside the EXIT backstop, guarded by `-z OSTLER_DONE_EMITTED`
#   10655  inside the ERR trap, which returns early when one already went out
#   30695  gui_done ok, the unconditional success path
#
# The invariant is therefore held BY CONSTRUCTION and by nothing else. A fifth
# call site added anywhere after a failure would emit DONE twice, the GUI would
# key on the last one, and a failed install could report ok. Nothing in the
# repository would notice.
#
# The standing queue called this "the TWO terminal DONE markers". There are now
# FOUR. That drift is the reason to write the check rather than trust the count.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run. British English throughout.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
SRC="${REPO}/install.sh"
EMIT="${REPO}/lib/progress_emitter.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  [PASS] $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
cant() { echo "CANNOT-RUN: $*" >&2; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }

[ -r "$SRC" ]  || cant "install.sh is not readable at ${SRC}"
[ -r "$EMIT" ] || cant "lib/progress_emitter.sh is not readable at ${EMIT}"

# ── the population, and a refusal if it is empty ─────────────────────────────
# bash 3.2-safe: macOS ships 3.2 and it has no `mapfile`. The repo already
# records this in post_walk_qa.sh ("no mapfile on a stock Mac shell"), and the
# first draft of this file used it anyway.
SITES=()
while IFS= read -r _l; do
    [ -n "$_l" ] && SITES+=("$_l")
done < <(/usr/bin/grep -nE '^[[:space:]]*gui_done (ok|fail)([[:space:]]|$)' "$SRC" | cut -d: -f1)
n="${#SITES[@]}"
[ "$n" -gt 0 ] || cant "found no gui_done call sites in install.sh. install.sh has emitted terminal markers for dozens of versions, so this is a dead pattern rather than a clean tree, and every verdict below would be vacuous."
ok "CONTROL: ${n} gui_done call site(s) found, so the checks below have a population"

# ── the property that makes the guard necessary ──────────────────────────────
set_in="$(/usr/bin/grep -cE '^[[:space:]]*OSTLER_DONE_EMITTED=1' "$EMIT" || true)"
read_in="$(/usr/bin/awk '/^gui_done\(\)/{f=1} f && /OSTLER_DONE_EMITTED/ && /\$\{?OSTLER_DONE_EMITTED/{c++} f && /^}/{f=0} END{print c+0}' "$EMIT")"
[ "${set_in:-0}" -gt 0 ] \
    && ok "the sentinel is written ${set_in} time(s) in the emitter, so it exists" \
    || bad "OSTLER_DONE_EMITTED is never written; the trap guards read something nothing sets"
[ "${read_in:-0}" -eq 0 ] \
    && ok "and gui_done does NOT read it, which is why each call site must carry its own protection" \
    || ok "gui_done now reads the sentinel itself (${read_in}); it has become idempotent and this file's premise is weaker, which is an improvement"

# ── every call site must exit, or sit under a sentinel guard ────────────────
unprotected=""
for L in "${SITES[@]}"; do
    txt="$(/usr/bin/sed -n "${L}p" "$SRC")"
    case "$txt" in *"gui_done ok"*) continue ;; esac      # the success path is terminal by definition
    # exit within the next 3 lines?
    nxt="$(/usr/bin/sed -n "$((L+1)),$((L+3))p" "$SRC")"
    if printf '%s' "$nxt" | /usr/bin/grep -qE '^[[:space:]]*exit '; then
        ok "line ${L}: followed by an explicit exit"
        continue
    fi
    # or a sentinel guard within the 40 lines above?
    prv="$(/usr/bin/sed -n "$((L>40 ? L-40 : 1)),${L}p" "$SRC")"
    if printf '%s' "$prv" | /usr/bin/grep -q 'OSTLER_DONE_EMITTED'; then
        ok "line ${L}: sits under an OSTLER_DONE_EMITTED guard"
        continue
    fi
    bad "line ${L}: a terminal DONE-fail with NO exit after it and NO sentinel guard above it. A later success path could emit DONE ok on top of it and the GUI would key on the ok."
    unprotected="${unprotected} ${L}"
done

# ── exactly one unconditional success marker ────────────────────────────────
n_ok="$(/usr/bin/grep -cE '^[[:space:]]*gui_done ok([[:space:]]|$)' "$SRC" || true)"
[ "${n_ok:-0}" -eq 1 ] \
    && ok "exactly one 'gui_done ok' exists, so there is a single success terminal" \
    || bad "${n_ok} 'gui_done ok' call sites; more than one success terminal means two runs could both claim to have finished"

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
