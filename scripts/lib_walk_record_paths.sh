#!/usr/bin/env bash
# scripts/lib_walk_record_paths.sh
#
# A WALK RECORD IS COMMITTED TO A PUBLIC REPO, SO NO FIELD MAY CARRY A HOME
# DIRECTORY. A home path names the account, and the account name is the owner.
#
# MEASURED 2026-11-04 (v1.0.123 walk, CM051 #3318): stores_provenance was
# written as wiped-by-shipped-uninstaller(<home>/.ostler/bin/ostler-uninstall;...)
# because ttywalk.sh's reset records the uninstaller path it actually ran, and
# post_walk_qa.sh copied the marker into the record verbatim. ci-pii-shape-scan
# blocked the record PR. Fixing that one field would leave every other field
# free to do the same thing tomorrow, so this runs over the WHOLE record.
#
# walk_record_tildeize FILE
#   Rewrites every macOS (/Users/<x>), Linux (/home/<x>) and root (/var/root)
#   home prefix in FILE to "~". A home path with nothing after it becomes "~".
#   Then it looks again. Any home-shaped path still present is a refusal (rc 1),
#   never a silent pass, because the caller is about to commit this file.
#   rc 0  rewritten (or nothing to rewrite) and re-checked clean
#   rc 1  a home path survived the rewrite
#   rc 2  could not read or write FILE
#
# BASH 3.2 and BSD sed: no \b, no -i without a suffix argument. So the rewrite
# goes through a temp file and mv, which also keeps the record whole if sed dies.

_WRP_HOME_ERE='(/Users/[^/[:space:];:,)"]+|/home/[^/[:space:];:,)"]+|/var/root)'

walk_record_tildeize() {
    local f="$1" tmp
    [ -f "$f" ] && [ -r "$f" ] && [ -w "$f" ] || { echo "walk_record_tildeize: cannot read/write ${f}" >&2; return 2; }
    tmp="${f}.tildeize.$$"
    if ! /usr/bin/sed -E "s#${_WRP_HOME_ERE}(/|([[:space:];:,)\"]|\$))#~\\2#g" "$f" > "$tmp"; then
        rm -f "$tmp"; echo "walk_record_tildeize: sed failed on ${f}" >&2; return 2
    fi
    mv "$tmp" "$f" || { rm -f "$tmp"; return 2; }
    if /usr/bin/grep -E -q "${_WRP_HOME_ERE}" "$f"; then
        echo "walk_record_tildeize: a home path survived in ${f} ($(/usr/bin/grep -E -c "${_WRP_HOME_ERE}" "$f") line(s)); refusing" >&2
        return 1
    fi
    return 0
}
