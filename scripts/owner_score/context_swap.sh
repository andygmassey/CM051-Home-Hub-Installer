#!/usr/bin/env bash
# owner_score/context_swap.sh -- put the SYNTHETIC persona at CONTEXT.md for an
# owner-score run, and put the original back. Runs ON THE BOX. bash 3.2.
#
#   context_swap.sh recover <workspace>
#   context_swap.sh swap    <workspace> <persona-file> [known-person]
#   context_swap.sh restore <workspace>
#
# THE RULES, each of which a test in test_context_swap.py pins:
#  1. NEVER TOUCH A REAL OWNER. `swap` proceeds only on positive evidence that
#     the existing CONTEXT.md is the synthetic seed: it already holds the persona
#     marker, or it names the walk's synthetic known person (argument 4), or the
#     operator declared the box synthetic with $OSTLER_STATE_DIR/synthetic-box
#     (default ~/.ostler/state/synthetic-box). Anything else, including no
#     CONTEXT.md at all, exits 10 and changes nothing.
#  2. ATOMIC. The backup is copied to a temp name and renamed into place, and the
#     persona is installed the same way, so a reader never sees a partial file
#     and the original is always whole in one of the two places.
#  3. NEVER CLOBBER A BACKUP. If a backup already exists `swap` exits 11: it may
#     be the only copy of the original, left by a crashed run.
#  4. RECOVER FIRST. `recover` puts back a leftover backup (a run that was
#     SIGKILLed cannot clean up after itself). The caller runs it before anything.
# Exit: 0 ok, 10 refused (not the synthetic seed), 11 backup in the way, 12 error.
set -u
cmd="${1:-}"; W="${2:-}"
[ -n "$cmd" ] && [ -n "$W" ] && [ -d "$W" ] || { echo "context_swap: usage / missing workspace" >&2; exit 12; }
C="$W/CONTEXT.md"; B="$W/CONTEXT.md.owner-score-backup"; F="$W/.owner-score-swapped"
MARKER="Synthetic owner: Jane Smith"
STATE="${OSTLER_STATE_DIR:-$HOME/.ostler/state}"

recover() {
    rm -f "$W"/*.owner-score-tmp.* 2>/dev/null
    if [ -f "$B" ]; then
        mv -f "$B" "$C" || exit 12
        rm -f "$F"
        echo "RECOVERED the original CONTEXT.md from a leftover backup"
    elif [ -f "$F" ]; then
        # swapped over a box that had no original: remove only OUR file
        if [ -f "$C" ] && grep -qF "$MARKER" "$C"; then rm -f "$C"; fi
        rm -f "$F"
        echo "RECOVERED: removed a leftover persona CONTEXT.md (there was no original)"
    fi
}

case "$cmd" in
    recover|restore) recover; exit 0 ;;
    swap)
        P="${3:-}"; KP="${4:-}"
        [ -f "$P" ] || { echo "context_swap: no persona file" >&2; exit 12; }
        [ ! -e "$B" ] || { echo "REFUSED: a backup already exists at $B (run recover first)"; exit 11; }
        ok=0
        if [ -f "$C" ]; then
            grep -qF "$MARKER" "$C" && ok=1
            [ -n "$KP" ] && grep -qF -- "$KP" "$C" && ok=1
        fi
        [ -f "$STATE/synthetic-box" ] && ok=1
        if [ "$ok" -ne 1 ]; then
            echo "REFUSED: the existing CONTEXT.md is not the synthetic seed (no persona marker, no synthetic known person, and no $STATE/synthetic-box). Nothing was changed."
            exit 10
        fi
        if [ -f "$C" ] && ! grep -qF "$MARKER" "$C"; then
            cp -p "$C" "$W/CONTEXT.md.owner-score-tmp.$$" || exit 12
            mv -f "$W/CONTEXT.md.owner-score-tmp.$$" "$B" || exit 12
        fi
        : > "$F"
        cp "$P" "$W/CONTEXT.persona.owner-score-tmp.$$" || exit 12
        mv -f "$W/CONTEXT.persona.owner-score-tmp.$$" "$C" || exit 12
        echo "SWAPPED"
        exit 0 ;;
    *) echo "context_swap: unknown command $cmd" >&2; exit 12 ;;
esac
