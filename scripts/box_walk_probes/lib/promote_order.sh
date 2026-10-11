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
