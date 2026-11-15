#!/bin/bash
# write_agents_md.sh -- write the care rules into the daemon workspace.
#
# usage: write_agents_md.sh <care_dir> <region_iso> <workspace_dir>
#
# Renders <care_dir>/AGENTS_CARE.md.tmpl into <workspace_dir>/AGENTS.md with
# the customer's local helpline, chosen OFFLINE by region from
# <care_dir>/helplines.tsv. Called by the fresh install and by the upgrade
# path, always before the daemon is started. The care block is product-owned
# and always rewritten, at the top of the file; any other content already in
# AGENTS.md is preserved below it (idempotent: see the BEGIN/END markers).
#
# Only rows whose flag is exactly CONFIRMED ship. Any other region, or an
# unknown one, gets the ZZ row, which names no number. An emergency number
# that the table marks with a trailing * (not seen on an official page) is
# never shipped either: that row's emergency text falls back to the ZZ one.
#
# Exit: 0 written, 2 inputs missing or unreadable (nothing written, any
# existing AGENTS.md left as it was), 3 render or write failed.
# Runs under /bin/bash 3.2.
set -u

care_dir="${1:-}"; region="${2:-}"; ws_dir="${3:-}"
tmpl="${care_dir}/AGENTS_CARE.md.tmpl"
tsv="${care_dir}/helplines.tsv"

if [[ -z "$care_dir" || -z "$ws_dir" || ! -r "$tmpl" || ! -r "$tsv" ]]; then
    echo "write_agents_md: template or helplines.tsv missing under '${care_dir}'" >&2
    exit 2
fi

region="$(printf '%s' "$region" | tr '[:lower:]' '[:upper:]')"
[[ "$region" =~ ^[A-Z][A-Z]$ ]] || region="ZZ"

# Columns: iso2, helpline_line, graded_number, emergency_line, source, checked, flag.
# awk, not read: graded_number is empty on the ZZ row and `read` with a tab IFS
# collapses empty tab-separated fields, shifting every later column.
pick() {  # $1 = iso, $2 = column; flag must be exactly CONFIRMED unless iso is ZZ
    awk -F'\t' -v iso="$1" -v col="$2" \
        '$1 == iso && ($1 == "ZZ" || $7 == "CONFIRMED") { print $col; exit }' "$tsv"
}
helpline="$(pick "$region" 2)"; emergency="$(pick "$region" 4)"
zz_helpline="$(pick ZZ 2)"; zz_emergency="$(pick ZZ 4)"

if [[ -z "$zz_helpline" || -z "$zz_emergency" ]]; then
    echo "write_agents_md: helplines.tsv has no ZZ fallback row" >&2
    exit 2
fi
if [[ -z "$helpline" ]]; then helpline="$zz_helpline"; emergency="$zz_emergency"; fi
case "$emergency" in *'*') emergency="$zz_emergency" ;; esac
# The template says "call 999." style: the table text already reads "call X".
emergency="${emergency%.}."

body="$(cat "$tmpl")" || exit 3
body="${body//\{\{HELPLINE_LINE\}\}/$helpline}"
body="${body//\{\{EMERGENCY_LINE\}\}/$emergency}"
case "$body" in *'{{'*) echo "write_agents_md: unresolved placeholder after render" >&2; exit 3 ;; esac

mkdir -p "$ws_dir" || exit 3
target="${ws_dir}/AGENTS.md"
BEGIN_MARK="<!-- OSTLER-CARE-BEGIN -->"; END_MARK="<!-- OSTLER-CARE-END -->"

# Anything already in AGENTS.md that is not our care block is the customer's
# (or the oa wizard's stock file) and is kept, below the care block. Our block
# is the BEGIN..END marker pair, dropped wherever it sits, so a rerun replaces
# it instead of stacking a second copy. A BEGIN with no END (damaged file)
# loses only the BEGIN line: nothing foreign is ever dropped.
foreign=""
if [[ -f "$target" ]]; then
    if grep -qF -- "$END_MARK" "$target"; then
        foreign="$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" 'index($0,b){skip=1; next} index($0,e){skip=0; next} !skip{print}' "$target")" || exit 3
    else
        foreign="$(awk -v b="$BEGIN_MARK" '!index($0,b){print}' "$target")" || exit 3
    fi
    # trim leading and trailing blank lines so reruns are byte-stable
    foreign="$(printf '%s\n' "$foreign" | awk 'NF{f=1} f{buf[++n]=$0} END{while(n>0 && buf[n] ~ /^[ \t]*$/) n--; for(i=1;i<=n;i++) print buf[i]}')" || exit 3
fi

tmp_out="$(mktemp "${ws_dir}/.AGENTS.md.XXXXXX")" || exit 3
if [[ -n "$foreign" ]]; then
    out_text="${BEGIN_MARK}"$'\n'"${body}"$'\n'"${END_MARK}"$'\n\n'"${foreign}"
else
    out_text="${BEGIN_MARK}"$'\n'"${body}"$'\n'"${END_MARK}"
fi
if ! printf '%s\n' "$out_text" > "$tmp_out" || ! mv -f "$tmp_out" "$target"; then
    rm -f "$tmp_out"
    echo "write_agents_md: could not write ${target}" >&2
    exit 3
fi
chmod 644 "$target" 2>/dev/null || true
echo "write_agents_md: wrote ${target} (region ${region}, helpline row $([[ "$helpline" == "$zz_helpline" ]] && echo ZZ || echo "$region"), foreign content $([[ -n "$foreign" ]] && echo kept || echo none))"
exit 0
