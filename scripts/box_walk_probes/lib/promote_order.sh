# scripts/box_walk_probes/lib/promote_order.sh
# promote_order "<names, one per line or space separated>"
#   Reads $PROBES (space-separated probe paths, already C-sorted) and prints the
#   same paths, space-separated, with the named probes that exist moved to the
#   front. Nothing is added or dropped.
#
# THE PAIRING RULE. One probe MUTATES pairing state (a real pair against :8443)
# and others READ it, and the reader must run first
# (tests/test_a_pairing_reader_runs_before_the_pairing_mutator.sh). So if the
# mutator is promoted, every pairing reader is promoted WITH it, and inside the
# promoted group the mutator goes last. The mutator is never ahead of a reader.
# The discovery patterns are the ones that test uses.
#
# BASH 3.2. No associative arrays.
promote_order() {
    local names p b m="" mutators="" readers="" want="" front="" rest="" mut_in=0
    names="$(printf '%s' "$1" | tr '\n' ' ')"
    for p in $PROBES; do
        b="$(basename "$p" .sh)"
        if [ "$(grep -cE "companion_pair_box_snippet|curl[^|]*-X POST[^|]*8443/pair" "$p")" -gt 0 ]; then
            mutators="$mutators $b"
        fi
    done
    for p in $PROBES; do
        b="$(basename "$p" .sh)"
        case " $mutators " in *" $b "*) continue ;; esac
        if [ "$(grep -cE 'devices\.db|paired_devices|pairing_required|require_pairing|"paired"' "$p")" -gt 0 ]; then
            readers="$readers $b"
        fi
    done
    want=" $names "
    for m in $mutators; do
        case "$want" in *" $m "*) mut_in=1 ;; esac
    done
    if [ "$mut_in" -eq 1 ]; then want="$want $readers "; fi
    # front: wanted non-mutators in their existing order, then wanted mutators.
    # rest: everything else in its existing order (an unpromoted mutator stays
    # exactly where it was relative to the rest).
    for p in $PROBES; do
        b="$(basename "$p" .sh)"
        case " $mutators " in *" $b "*) continue ;; esac
        case "$want" in *" $b "*) front="$front $p" ;; esac
    done
    for p in $PROBES; do
        b="$(basename "$p" .sh)"
        case " $mutators " in *" $b "*) case "$want" in *" $b "*) front="$front $p" ;; esac ;; esac
    done
    for p in $PROBES; do
        case " $front " in *" $p "*) ;; *) rest="$rest $p" ;; esac
    done
    printf '%s\n' "${front# }${rest}" | sed 's/  */ /g; s/^ //; s/ $//'
}
