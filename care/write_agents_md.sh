#!/bin/bash
# write_agents_md.sh -- write the care rules into the daemon workspace.
#
# usage: write_agents_md.sh <care_dir> <region_iso> <workspace_dir>
#
# Renders <care_dir>/AGENTS_CARE.md.tmpl into <workspace_dir>/AGENTS.md with
# the customer's local helpline, chosen OFFLINE by region from
# <care_dir>/helplines.tsv. Called by the fresh install and by the upgrade
# path, always before the daemon is started. The file is product-owned and
# always overwritten.
#
# Only rows whose flag is exactly CONFIRMED ship. Any other region, or an
# unknown one, gets the ZZ row, which names no number. An emergency number
# that the table marks with a trailing * (not seen on a source page) is
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
tmp_out="$(mktemp "${ws_dir}/.AGENTS.md.XXXXXX")" || exit 3
if ! printf '%s\n' "$body" > "$tmp_out" || ! mv -f "$tmp_out" "${ws_dir}/AGENTS.md"; then
    rm -f "$tmp_out"
    echo "write_agents_md: could not write ${ws_dir}/AGENTS.md" >&2
    exit 3
fi
chmod 644 "${ws_dir}/AGENTS.md" 2>/dev/null || true
echo "write_agents_md: wrote ${ws_dir}/AGENTS.md (region ${region}, helpline row $([[ "$helpline" == "$zz_helpline" ]] && echo ZZ || echo "$region"))"
exit 0
