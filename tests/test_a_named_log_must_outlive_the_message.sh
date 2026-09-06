#!/usr/bin/env bash
#
# A message that tells the customer to go and look at a log must name a path
# that will still be there when they look.
#
# install.sh keeps its logs in `mktemp -d "${TMPDIR:-/tmp}/ostler-diag-XXXXXX"`,
# which macOS purges. `_ostler_persist_diagnostics` copies them under
# ~/.ostler/diagnostics/<timestamp> and records that in $OSTLER_DIAG_KEPT.
# install.sh's own comment on that function says the warning it exists for
# "named a file they could not find the next day".
#
# THE FIX HAD LANDED ON 1 OF 7 SITES. Six user-facing messages still cited the
# purgeable path. One of them was the `*)` arm of the namespace-migration case,
# sitting directly beneath the `124|137` arm that HAD been fixed -- and it is
# the arm that fires on rc=1, which that block's own rc contract defines as
# "a rule ran and left residue", i.e. the store was written to.
#
# The repo had already been bitten by this exact shape. install.sh's places
# guard carries the comment: "Both arms named a file that nothing writes, so
# fixing only the guard arm would have left the unexpected-error arm lying."
#
# So this gate asserts the PROPERTY over the whole file rather than the six
# lines that were wrong, because the next one will be somewhere else.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${REPO_ROOT}/install.sh"

pass=0; fail=0
ok()  { printf '[PASS] %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '[FAIL] %s\n' "$1"; fail=$((fail + 1)); }

[ -f "$INSTALL" ] || { echo "[CANNOT-RUN] no ${INSTALL}"; exit 78; }

# Comments are stripped BEFORE anything else. Writing this as
# `grep -n PAT file | grep -v '^ *#'` filters nothing, because grep -n has
# already put a line number in front of the '#'.
naming_sites() {   # every non-comment user-facing message naming the diag dir
    awk '{ l=$0; sub(/^[ \t]+/, "", l)
           if (l !~ /^#/ && $0 ~ /OSTLER_DIAG_DIR/ && $0 ~ /(warn|err|info|ok|die|echo)[ "]/)
               print NR }' "$INSTALL"
}
durable_sites() {  # ...of those, the ones naming the DURABLE copy
    awk '{ l=$0; sub(/^[ \t]+/, "", l)
           if (l !~ /^#/ && $0 ~ /OSTLER_DIAG_DIR/ && $0 ~ /(warn|err|info|ok|die|echo)[ "]/ \
               && $0 ~ /OSTLER_DIAG_KEPT/)
               print NR }' "$INSTALL"
}

echo "=== 1. THE DENOMINATOR IS REAL ==="
# A must-match with no denominator check passes on an empty file. If the
# predicate stops matching because someone renamed the variable, this arm
# fails rather than silently reporting a clean estate.
n_total="$(naming_sites | wc -l | tr -d ' ')"
if [ "$n_total" -ge 5 ]; then
    ok "the predicate finds ${n_total} message(s) naming the diagnostics dir"
else
    bad "only ${n_total} site(s) found; the predicate is broken, not the estate clean"
fi

echo
echo "=== 2. EVERY ONE OF THEM NAMES THE DURABLE COPY ==="
n_durable="$(durable_sites | wc -l | tr -d ' ')"
n_bad=$((n_total - n_durable))
if [ "$n_bad" -eq 0 ]; then
    ok "all ${n_total} name \${OSTLER_DIAG_KEPT:-\$OSTLER_DIAG_DIR}, not the purgeable path"
else
    bad "${n_bad} of ${n_total} still name the purgeable path only:"
    comm -23 <(naming_sites | sort) <(durable_sites | sort) | while read -r l; do
        printf '         install.sh:%s  %s\n' "$l" "$(awk -v n="$l" 'NR==n' "$INSTALL" | cut -c1-96)"
    done
fi

echo
echo "=== 3. EACH ONE PERSISTS BEFORE IT NAMES ==="
# Naming the durable copy is not enough on its own: at warn time
# $OSTLER_DIAG_KEPT is empty unless something has already persisted, and the
# fallback then quietly yields the purgeable path again.
missing=0
while read -r l; do
    [ -n "$l" ] || continue
    lo=$((l - 6)); [ "$lo" -lt 1 ] && lo=1
    if [ "$(awk -v lo="$lo" -v hi="$l" 'NR>=lo && NR<hi && /_ostler_persist_diagnostics/' "$INSTALL" | wc -l | tr -d ' ')" -eq 0 ]; then
        printf '         install.sh:%s names a log with no persist above it\n' "$l"
        missing=$((missing + 1))
    fi
done < <(naming_sites)
if [ "$missing" -eq 0 ]; then
    ok "all ${n_total} sites call _ostler_persist_diagnostics first"
else
    bad "${missing} site(s) name a log without persisting it first"
fi

echo
echo "=== 4. THE STRAY-QUOTE DEFECT ==="
# Two of these lines ended `See "${OSTLER_DIAG_DIR}/x.log""`, with the path
# expansion OUTSIDE the quotes. Driven: a TMPDIR containing a space splits it
# into three arguments and truncates the message at the first space.
n_stray="$(/usr/bin/grep -c 'See "${OSTLER_DIAG' "$INSTALL" || true)"
if [ "$n_stray" -eq 0 ]; then
    ok "no message leaves the diagnostics path outside its quotes"
else
    bad "${n_stray} message(s) expand the path outside the quotes; a TMPDIR with a space truncates them"
fi

echo
echo "=== 5. PERSIST IS IDEMPOTENT, DRIVEN NOT READ ==="
# Calling it at every warn site is only safe if repeat calls TOP UP one
# directory. Otherwise a four-warning install leaves four timestamped
# directories and the complete one is indistinguishable from the partials.
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
awk '/^_ostler_persist_diagnostics\(\) \{/,/^\}/' "$INSTALL" > "$SB/fn.sh"
if [ "$(wc -l <"$SB/fn.sh" | tr -d ' ')" -lt 8 ] || ! bash -n "$SB/fn.sh" 2>/dev/null; then
    echo "[CANNOT-RUN] could not extract a parseable _ostler_persist_diagnostics"
    fail=$((fail + 1))
else
    # 🔴 DO NOT test this by calling it twice and counting directories. The
    # destination is stamped `%Y%m%dT%H%M%SZ`, so two calls inside the same
    # second land on the same name whether the function is idempotent or not.
    # A mutant that replaced the reuse branch with `if false` SURVIVED that
    # version of this arm: the arm was measuring clock resolution, not code.
    #
    # So drive the branch directly -- hand it a destination that already
    # exists and require it to write THERE -- and only then do the two-call
    # check, with a second between them so the names would genuinely differ.
    (
        set +u
        source "$SB/fn.sh"
        OSTLER_DIR="$SB/dot-ostler"
        OSTLER_DIAG_DIR="$SB/diag"; mkdir -p "$OSTLER_DIAG_DIR"
        echo one > "$OSTLER_DIAG_DIR/a.log"

        # (a) a destination is already recorded: it must be reused, not replaced
        PRESET="$SB/dot-ostler/diagnostics/PRESET"; mkdir -p "$PRESET"
        OSTLER_DIAG_KEPT="$PRESET"
        _ostler_persist_diagnostics
        [ "$OSTLER_DIAG_KEPT" = "$PRESET" ] || { echo "    reuse: went to $OSTLER_DIAG_KEPT not $PRESET" >&2; exit 1; }
        [ -f "$PRESET/a.log" ] || { echo "    reuse: nothing copied into the preset dir" >&2; exit 1; }

        # (b) two calls a second apart still top up one directory
        rm -rf "$SB/dot-ostler/diagnostics"; unset OSTLER_DIAG_KEPT
        _ostler_persist_diagnostics; K1="$OSTLER_DIAG_KEPT"
        sleep 1
        echo two > "$OSTLER_DIAG_DIR/b.log"
        _ostler_persist_diagnostics; K2="$OSTLER_DIAG_KEPT"
        n_dirs="$(/bin/ls "$SB/dot-ostler/diagnostics" 2>/dev/null | wc -l | tr -d ' ')"
        n_files="$(/bin/ls "$K2" 2>/dev/null | wc -l | tr -d ' ')"
        [ "$K1" = "$K2" ] && [ "$n_dirs" = "1" ] && [ "$n_files" = "2" ]
        exit $?
    )
    if [ $? -eq 0 ]; then
        ok "two calls top up ONE directory and it holds both logs"
    else
        bad "repeat calls do not top up a single directory; every warn site would spawn its own"
    fi
fi

echo
echo "=== 6. THE FAILED RUN IS THE ONE THAT NEEDS THE TRAIL ==="
# The persister was called at the END of the file, so a run that COMPLETED
# left durable logs and a run that DIED did not -- which is the run anyone
# actually wants. composite_cleanup, the EXIT trap, had zero persist calls.
#
# It cannot persist to $OSTLER_DIR from there: on a run that never promoted,
# OSTLER_DIR is the /tmp staging tree the trap has just deleted. So the
# persister takes an explicit root, and that is driven below rather than read,
# because a parameter that is accepted and ignored looks identical to one
# that works.
trap_body() { awk '/^composite_cleanup\(\) \{/,/^\}/' "$INSTALL"; }

if [ "$(trap_body | /usr/bin/grep -c '_ostler_persist_diagnostics')" -ge 1 ]; then
    ok "the EXIT trap persists diagnostics, so a failed run leaves a trail"
else
    bad "composite_cleanup has no persist call; only a SUCCESSFUL install leaves durable logs"
fi

# The decline arms rm -rf the install to "leave no ~/.ostler/ residue", which
# is an Article 9 commitment rather than tidiness. A trap that wrote a
# diagnostics directory there on the way out would break that promise.
if [ "$(trap_body | /usr/bin/grep -c 'declined')" -ge 1 ]; then
    ok "the trap's persist is suppressed when a consent was declined"
else
    bad "the trap persists unconditionally; a declined install would be left with residue"
fi

if bash -c '
    set +u
    awk "/^_ostler_persist_diagnostics\(\) \{/,/^\}/" "$1" > "$2/fn2.sh"
    source "$2/fn2.sh"
    OSTLER_DIR="$2/WRONG-ROOT"
    OSTLER_DIAG_DIR="$2/diag2"; mkdir -p "$OSTLER_DIAG_DIR"; echo x > "$OSTLER_DIAG_DIR/t.log"
    _ostler_persist_diagnostics "$2/EXPLICIT-ROOT"
    case "$OSTLER_DIAG_KEPT" in
        "$2"/EXPLICIT-ROOT/diagnostics/*) [ -f "$OSTLER_DIAG_KEPT/t.log" ] ;;
        *) exit 1 ;;
    esac
' _ "$INSTALL" "$SB"; then
    ok "an explicit root wins over \$OSTLER_DIR, so the trap avoids the doomed staging tree"
else
    bad "the explicit root argument is ignored; the trap would persist into the tree it just deleted"
fi

echo
echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
