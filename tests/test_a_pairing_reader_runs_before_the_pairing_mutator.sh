#!/usr/bin/env bash
# THE SUITE'S EXECUTION ORDER IS LOAD-BEARING AND NOTHING STATES IT.
#
# run_box_walk.sh:83 collects probes with a plain glob:
#
#     for f in "$PROBE_DIR"/*.sh
#
# One probe MUTATES pairing state -- pairing_recovers_without_a_repair_storm
# performs a real POST to :8443/pair and, on success, persists a bearer token in
# config.toml that nothing in the tree revokes. Other probes READ pairing state.
# Whether a reader sees the box as installed or as this suite left it therefore
# depends entirely on where its FILENAME sorts.
#
# Today pair_state_agreement sorts before the mutator, so it reads the pristine
# box. That is correct and it is an ACCIDENT: the two names differ first at
# "_" versus "i", and renaming either file would silently invert it. An accident
# that is currently right is still an accident, and nothing anywhere in the suite
# says the order matters.
#
# A glob also sorts by LC_COLLATE. Locales that ignore punctuation at the primary
# level compare "pairstate" against "pairingrecovers" -- where "i" precedes "s"
# and the order FLIPS. This test therefore checks the order under BOTH the
# ambient locale and the C locale and reports if they disagree, so the runner CI
# measures the question on its own collation rather than trusting this machine's.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${REPO}/scripts/box_walk_probes/probes"
[ -d "$DIR" ] || { printf 'CANNOT-RUN: no probe directory at %s\n' "$DIR" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

# --- REVIEWED EXCEPTIONS ----------------------------------------------------
# A reader listed here sorts AFTER the mutator and has been looked at. The
# reason is recorded because an allowlist whose grounds nobody wrote down cannot
# be audited, only obeyed.
#
#   running_config_matches_disk
#       It compares require_pairing ON DISK against the value the RUNNING
#       process holds. The mutator adds a paired token; the daemon writes that
#       token to disk itself, so both sides of this probe's comparison move
#       together and the comparison is unaffected. It does not read the token
#       count and it does not read device-layer state.
ALLOWED="running_config_matches_disk"

# --- discover the mutator ---------------------------------------------------
MUTATORS=""
for f in "$DIR"/*.sh; do
    if [ "$(grep -cE "curl[^|]*-X POST[^|]*8443/pair" "$f")" -gt 0 ]; then
        MUTATORS="${MUTATORS} $(basename "$f" .sh)"
    fi
done
set -- $MUTATORS
if [ "$#" -ne 1 ]; then
    printf 'CANNOT-RUN: expected exactly ONE probe that pairs against :8443, found %s (%s).\n' "$#" "${MUTATORS# }" >&2
    printf '  The predicate no longer matches how the mutation is written, so the\n' >&2
    printf '  ordering below would be asserted about the wrong subject.\n' >&2
    exit 2
fi
MUTATOR="$1"
ok "the pairing mutator is ${MUTATOR} (exactly one probe posts to :8443/pair)"

# --- discover the readers ---------------------------------------------------
# Device-layer and policy pairing state. Deliberately NOT the word "pair" alone:
# that matches the mutator's own prose and every comment about it.
READERS=""
for f in "$DIR"/*.sh; do
    b="$(basename "$f" .sh)"
    [ "$b" = "$MUTATOR" ] && continue
    if [ "$(grep -cE 'devices\.db|paired_devices|pairing_required|require_pairing|"paired"' "$f")" -gt 0 ]; then
        READERS="${READERS} ${b}"
    fi
done
set -- $READERS
if [ "$#" -lt 2 ]; then
    printf 'CANNOT-RUN: found %s pairing-state reader(s). Fewer than two means the\n' "$#" >&2
    printf '  search no longer matches how these reads are written, and a clean\n' >&2
    printf '  ordering report would be about nothing.\n' >&2
    exit 2
fi
ok "pairing-state readers found: $# (${READERS# })"

# --- the two orders ---------------------------------------------------------
order_under() {
    # order_under <locale>  -> probe basenames, one per line, as a glob would sort
    ( cd "$DIR" && LC_ALL="$1" ls -1 ./*.sh 2>/dev/null | sed 's|^\./||; s|\.sh$||' | LC_ALL="$1" sort )
}
AMBIENT="${LC_ALL:-${LANG:-C}}"
ORDER_C="$(order_under C)"
ORDER_A="$(order_under "$AMBIENT")"

if [ "$ORDER_C" = "$ORDER_A" ]; then
    ok "the C collation and this runner's (${AMBIENT}) agree on probe order"
else
    bad "probe order DIFFERS between the C collation and ${AMBIENT}. The suite's execution order depends on the operator's locale, and one probe mutates state the others read. First divergence: $(diff <(printf '%s' "$ORDER_C") <(printf '%s' "$ORDER_A") | head -4 | tr '\n' ' ')"
fi

pos_in() { printf '%s\n' "$1" | grep -nx -- "$2" | cut -d: -f1; }

for locale_name in C "$AMBIENT"; do
    ORD="$(order_under "$locale_name")"
    mpos="$(pos_in "$ORD" "$MUTATOR")"
    if [ -z "$mpos" ]; then
        printf 'CANNOT-RUN: %s does not appear in the %s ordering.\n' "$MUTATOR" "$locale_name" >&2
        exit 2
    fi
    for r in $READERS; do
        rpos="$(pos_in "$ORD" "$r")"
        [ -z "$rpos" ] && continue
        case " $ALLOWED " in *" $r "*) continue ;; esac
        if [ "$rpos" -lt "$mpos" ]; then
            ok "[${locale_name}] ${r} (#${rpos}) reads pairing state BEFORE ${MUTATOR} (#${mpos}) changes it"
        else
            bad "[${locale_name}] ${r} (#${rpos}) runs AFTER ${MUTATOR} (#${mpos}), so it reads pairing state THIS SUITE created. Either rename it to sort earlier, or add it to ALLOWED in this file WITH the reason it is unaffected."
        fi
    done
done

# --- the allowlist must not rot ---------------------------------------------
for a in $ALLOWED; do
    if [ ! -f "${DIR}/${a}.sh" ]; then
        bad "ALLOWED names ${a}, which is not a probe. An exception for a file that does not exist hides the next reader that takes its place."
    else
        ok "reviewed exception ${a} still exists and its reason is recorded above"
    fi
done

printf '\n== %s pass / %s fail / %s total ==\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
