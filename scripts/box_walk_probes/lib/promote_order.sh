# scripts/box_walk_probes/lib/promote_order.sh
# promote_order "<names, one per line or space separated>"
#   Reads $PROBES (space-separated probe paths, already C-sorted) and prints the
#   same paths, space-separated, with the named READ-ONLY probes that exist moved
#   to the front. Nothing is added or dropped.
#
# A PROBE THAT WRITES IS NEVER MOVED. Moving one changes what every probe after
# it reads, so a verdict would change through ordering alone (people_stores_
# reconcile kickstarts the people writers; the pairing probe pairs a device).
# A writer is declared, not guessed: it carries a marker line
#
#     # WALK_WRITES: <what it changes>
#
# and the decision reads ONLY that marker. tests/test_a_writing_probe_declares_
# it_and_is_never_promoted.sh lints the probes so an unmarked writer cannot hide.
# DO NOT "FIX" THE CROSSING (Archie, kept on purpose). A read-only probe that is
# promoted ahead of a probe-writer reads the post-seed state with none of the
# probes' own side effects, and that is the customer's box. Reading AFTER a
# probe's own write (a lockout bump, a forced sync, a reminder left behind) is
# the walk's artefact, not the product's. So promotion may move a reader across
# a writer, and a stricter "only before the first writer" rule is wrong.
# Non-promoted probes (writers included) keep their relative C-sorted order.
#
# BASH 3.2. No associative arrays.
probe_writes() {   # path -> 0 when it declares # WALK_WRITES:
    [ "$(grep -c '^# WALK_WRITES:' "$1")" -gt 0 ]
}

# promote_writers_named "<names>" -> the named probes that exist and write
promote_writers_named() {
    local names p b out=""
    names=" $(printf '%s' "$1" | tr '\n' ' ') "
    for p in $PROBES; do
        b="$(basename "$p" .sh)"
        case "$names" in *" $b "*) probe_writes "$p" && out="$out $b" ;; esac
    done
    printf '%s\n' "${out# }"
}

promote_order() {
    local names p b front="" rest=""
    names=" $(printf '%s' "$1" | tr '\n' ' ') "
    for p in $PROBES; do
        b="$(basename "$p" .sh)"
        case "$names" in
            *" $b "*) if probe_writes "$p"; then rest="$rest $p"; else front="$front $p"; fi ;;
            *) rest="$rest $p" ;;
        esac
    done
    printf '%s\n' "${front# }${rest}" | sed 's/  */ /g; s/^ //; s/ $//'
}

# pin_last "<name>" -> reads $PROBES (space-separated probe paths) and prints the
# same paths with the named probe moved to the END, if it is present. Nothing is
# added or dropped. Used for owner_knowledge_score: it seeds a synthetic persona
# into the people graph and conversation store, so every probe that counts or
# reads people must have run BEFORE it, whatever the previous walk's FAILs
# promoted. A writer is never promoted (probe_writes), so this only ever has to
# undo the C-sort, where "o" would put it ahead of the p..z probes.
pin_last() {
    local want="$1" p b rest="" last=""
    for p in $PROBES; do
        b="$(basename "$p" .sh)"
        if [ "$b" = "$want" ]; then last="$p"; else rest="$rest $p"; fi
    done
    printf '%s\n' "${rest# }${last:+ $last}" | sed 's/  */ /g; s/^ //; s/ $//'
}

# WALK_PIN_AFTER: "<probe>:<anchor>" pairs. The walk runs <probe> AFTER <anchor>.
# gateway_never_serves_a_stored_secret pairs (and revokes) a synthetic companion,
# so it declares WALK_WRITES and counts as a pairing mutator; it sorts ahead of
# pair_state_agreement ("g" < "p"), which reads pairing state, so it is pinned
# behind that reader. Shared by run_box_walk.sh and the order test so both
# measure the same order.
WALK_PIN_AFTER="gateway_never_serves_a_stored_secret:pair_state_agreement"

# pin_after "<name>" "<anchor>" -> reads $PROBES (space-separated probe paths) and
# prints the same paths with <name> moved to sit directly after <anchor>. Nothing
# is added or dropped. If either is absent (a filtered --only run) the order is
# left alone.
pin_after() {
    local want="$1" anchor="$2" p b rest="" moved="" have_anchor=0 out=""
    for p in $PROBES; do
        b="$(basename "$p" .sh)"
        [ "$b" = "$want" ] && moved="$p"
        [ "$b" = "$anchor" ] && have_anchor=1
    done
    if [ -z "$moved" ] || [ "$have_anchor" -eq 0 ]; then
        printf '%s\n' "$PROBES" | sed 's/  */ /g; s/^ //; s/ $//'; return
    fi
    for p in $PROBES; do
        b="$(basename "$p" .sh)"
        [ "$b" = "$want" ] && continue
        out="$out $p"
        [ "$b" = "$anchor" ] && out="$out $moved"
    done
    printf '%s\n' "$out" | sed 's/  */ /g; s/^ //; s/ $//'
}

# apply_pins -> $PROBES with every WALK_PIN_AFTER pair applied.
apply_pins() {
    local pair P="$PROBES"
    for pair in $WALK_PIN_AFTER; do
        P="$(PROBES="$P" pin_after "${pair%%:*}" "${pair#*:}")"
    done
    printf '%s\n' "$P"
}
