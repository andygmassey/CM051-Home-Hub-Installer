# seeded_people.sh -- sourced by the walk's seeds that write Person nodes.
#
# WHY. data_conservation reads people IN (the owner), STORED, GRAPH and SHOWN.
# The walk's own seeds then add people to the box (contact cards, the neighbour,
# the grounding person), so STORED reads in + seeded and the row read INFLATED
# on 116c (11/11/10 vs in=1) although nothing was duplicated. Each seed therefore
# records what ITS OWN WRITE RESULT says it wrote, on the box, in
#
#     ~/.walk-seeded-people       one line per seed:  <seed> <count>
#
# and removes its line when it forgets. A forget leaves the file EMPTY, never
# absent: an empty file is a readable 0, an absent one is "no seed ran" and the
# collector only believes that when the runner says so.
#
# These functions PRINT box-side shell, because the seeds reach the box as ssh
# command strings. POSIX sh: runs under macOS /bin/bash 3.2 and /bin/sh.
# The name is [A-Za-z0-9_] only (checked), so it is safe inside grep and printf.

_swp_check_name() {
    case "$1" in ''|*[!A-Za-z0-9_]*) echo "seeded_people: bad seed name '$1'" >&2; return 1 ;; esac
}

# $1 seed name; $2 a box-side shell expression for the count, e.g. '$n' or 8.
# Replaces any earlier line for the same seed, then appends.
seeded_people_record_cmd() {
    _swp_check_name "$1" || return 1
    printf '%s\n' "_swp=\$HOME/.walk-seeded-people; { grep -v '^$1 ' \"\$_swp\" 2>/dev/null; printf '%s %s\\n' '$1' \"$2\"; } > \"\$_swp.tmp.\$\$\" && mv \"\$_swp.tmp.\$\$\" \"\$_swp\""
}

# $1 seed name. Removes the seed's line.
seeded_people_forget_cmd() {
    _swp_check_name "$1" || return 1
    printf '%s\n' "_swp=\$HOME/.walk-seeded-people; if [ -f \"\$_swp\" ]; then grep -v '^$1 ' \"\$_swp\" > \"\$_swp.tmp.\$\$\"; mv \"\$_swp.tmp.\$\$\" \"\$_swp\"; fi"
}
