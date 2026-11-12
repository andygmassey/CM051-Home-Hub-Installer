#!/bin/bash
# walk_cold_wipe_state.sh -- the COLD PROOF for ttywalk.sh --reset.
# Runs ON THE WALK BOX, fed over ssh (bash -s < this file). Bash 3.2 safe.
#
# THE DEFECT (v1.0.129 walk, 2026-11-12). The reset printed "NO SHIPPED
# UNINSTALLER FOUND. This reset did NOT uninstall." and ran only the #1828
# config-only teardown (config, security, assistant-config, imports,
# active_workspace.toml) plus colima delete --data. ~/.ostler/state was never
# touched: 123,775 files under state/conversations_mirror (dated 2026-05-15 to
# 2026-11-11) predated the reset, so every conversation, people, dedupe and
# email count of that walk was measured on carried-over state.
#
# THIS SCRIPT, two modes (COLD_MODE):
#   before  count the files under every root, print the count per root, save it.
#   wipe    delete every file under the roots except the allowlist, count again,
#           print before and after per root, and exit 2 (CANNOT-RUN, the caller
#           refuses to stage) unless the after-count is 0 outside the allowlist.
#           Lists up to 20 offending paths.
# On success it writes ~/.walk-cold-run (consumed into ~/.walk-cold by ttywalk.sh
# and read by post_walk_qa.sh into the record's `cold` row).
#
# ROOTS: ~/.ostler, ~/Documents/Ostler, ~/Library/Application Support/Ostler*
# ALLOWLIST: COLD_ALLOWLIST_B64 (base64 of scripts/walk_cold_allowlist.tsv, set
# by the driver) or COLD_ALLOWLIST_FILE. Rows: path relative to HOME, TAB, reason.
# A trailing slash means that whole subtree. A row without a reason is refused.
# HARNESS ONLY. The installer must never do this: conversations_mirror is the
# customer's archive on a reinstall.
set -u
MODE="${COLD_MODE:-}"
HOME_DIR="${HOME:?}"
STATE="${HOME_DIR}/.walk-cold-before-run"
OUT="${HOME_DIR}/.walk-cold-run"

case "$MODE" in before|wipe) ;; *) echo "walk_cold_wipe_state: COLD_MODE must be before or wipe, got '${MODE}'" >&2; exit 2 ;; esac

# A stale verdict from an earlier run must never be readable as this one.
rm -f "$OUT"

ALLOW_TSV=""
if [ -n "${COLD_ALLOWLIST_FILE:-}" ]; then
    [ -r "$COLD_ALLOWLIST_FILE" ] || { echo "walk_cold_wipe_state: allowlist ${COLD_ALLOWLIST_FILE} unreadable" >&2; exit 2; }
    ALLOW_TSV="$(cat "$COLD_ALLOWLIST_FILE")"
elif [ -n "${COLD_ALLOWLIST_B64:-}" ]; then
    if [ "$(uname -s)" = Darwin ]; then _d="-D"; else _d="-d"; fi
    ALLOW_TSV="$(printf '%s' "$COLD_ALLOWLIST_B64" | base64 "$_d")" || { echo "walk_cold_wipe_state: allowlist did not decode" >&2; exit 2; }
else
    echo "walk_cold_wipe_state: no allowlist supplied (COLD_ALLOWLIST_B64 or COLD_ALLOWLIST_FILE); an unlisted wipe is refused" >&2
    exit 2
fi

# Parse the allowlist into find arguments.
ALLOW_PATHS=()
ALLOW_ARGS=()
while IFS="$(printf '\t')" read -r _p _why; do
    case "$_p" in ''|'#'*) continue ;; esac
    if [ -z "${_why:-}" ]; then echo "walk_cold_wipe_state: allowlist row '${_p}' has no reason; refused" >&2; exit 2; fi
    case "$_p" in /*|*..*) echo "walk_cold_wipe_state: allowlist row '${_p}' must be relative to HOME with no ..; refused" >&2; exit 2 ;; esac
    ALLOW_PATHS+=("$_p")
    case "$_p" in
        */) ALLOW_ARGS+=( ! -path "${HOME_DIR}/${_p}*" ) ;;
        *)  ALLOW_ARGS+=( ! -path "${HOME_DIR}/${_p}" ) ;;
    esac
done <<EOT
${ALLOW_TSV}
EOT

ROOTS=()
ROOTS+=("${HOME_DIR}/.ostler" "${HOME_DIR}/Documents/Ostler")
for _r in "${HOME_DIR}/Library/Application Support"/Ostler*; do
    [ -e "$_r" ] && ROOTS+=("$_r")
done

# count_root <root> : files and symlinks outside the allowlist.
count_root() {
    local root="$1"
    [ -e "$root" ] || { echo 0; return 0; }
    find "$root" \( -type f -o -type l \) ${ALLOW_ARGS[@]+"${ALLOW_ARGS[@]}"} -print | wc -l | tr -d ' '
}
count_all() {
    local root="$1"
    [ -e "$root" ] || { echo 0; return 0; }
    find "$root" \( -type f -o -type l \) -print | wc -l | tr -d ' '
}

if [ "$MODE" = before ]; then
    : > "$STATE"
    for r in "${ROOTS[@]}"; do
        n="$(count_root "$r")"
        echo "cold count BEFORE teardown: ${n} files under ${r}"
        printf '%s\t%s\n' "$r" "$n" >> "$STATE"
    done
    exit 0
fi

# wipe
for r in "${ROOTS[@]}"; do
    [ -e "$r" ] || continue
    find "$r" \( -type f -o -type l \) ${ALLOW_ARGS[@]+"${ALLOW_ARGS[@]}"} -exec rm -f {} +
    # Empty directories go too; non-empty ones (allowlisted content) stay.
    find "$r" -depth -type d -empty -delete
done

bad=0
SUMMARY=""
for r in "${ROOTS[@]}"; do
    before="$(awk -F'\t' -v r="$r" '$1==r{print $2; exit}' "$STATE" 2>/dev/null)"
    [ -n "$before" ] || before="not-counted"
    after="$(count_root "$r")"
    kept=$(( $(count_all "$r") - after ))
    echo "cold count: ${r}: before=${before} after=${after} (allowlisted files kept: ${kept})"
    SUMMARY="${SUMMARY}${r##*/}:${before}->${after} "
    [ "$after" -ne 0 ] && bad=1
done
echo "allowlist rows:"
for p in ${ALLOW_PATHS[@]+"${ALLOW_PATHS[@]}"}; do echo "  ${p}"; done

if [ "$bad" -ne 0 ]; then
    echo "NOT COLD: files survived the wipe outside the allowlist (first 20):"
    for r in "${ROOTS[@]}"; do
        [ -e "$r" ] && find "$r" \( -type f -o -type l \) ${ALLOW_ARGS[@]+"${ALLOW_ARGS[@]}"} -print
    done | head -20 | sed 's/^/  /'
    printf 'NOT_COLD(files survive outside the allowlist: %s)\n' "$SUMMARY" > "$OUT"
    exit 2
fi
printf 'PROVEN(files outside the allowlist, before->after per root: %s)\n' "$SUMMARY" > "$OUT"
echo "cold: PROVEN, 0 files outside the allowlist under every root"
exit 0
