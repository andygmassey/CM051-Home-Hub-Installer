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
# ROOTS: ~/.ostler, ~/Documents/Ostler (legacy), ~/Ostler (the current user root), ~/Library/Application Support/Ostler*
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

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/walk-cold.XXXXXX")" || { echo "walk_cold_wipe_state: no temp dir" >&2; exit 2; }
trap 'rm -rf "$TMPD"' EXIT
PROBE_NAME=".walk-cold-probe.$$"

# A look that could not be made is NOT cold and is NOT zero. It writes the
# NOT_COLD marker and exits 2 with the root and find's OWN stderr line.
cannot_look() {  # cannot_look <what> <root> <errfile>
    echo "CANNOT LOOK: $1 under $2: $(head -1 "$3" 2>/dev/null)" >&2
    echo "  (find's own exit status was non-zero; a count read through a pipe would have said 0)" >&2
    printf 'NOT_COLD(could not look: %s)\n' "$1" > "$OUT"
    exit 2
}

# is_absent <path> : true only when the PARENT can be listed and the name is not
# in it. An unreadable parent (TCC, permissions) is "could not look", never absent.
is_absent() {
    local path="$1" parent name
    parent="$(dirname "$path")"; name="$(basename "$path")"
    if [ "$parent" = "$HOME_DIR" ] || [ -e "$parent" ]; then
        ls -A "$parent" > "$TMPD/ls.out" 2> "$TMPD/ls.err" || cannot_look "cannot list the parent of an absent-looking root" "$path" "$TMPD/ls.err"
        grep -Fxq -- "$name" "$TMPD/ls.out" && return 1
        return 0
    fi
    is_absent "$parent"
}

LIB="${HOME_DIR}/Library/Application Support"
ls -A "$LIB" > "$TMPD/lib.out" 2> "$TMPD/lib.err" || cannot_look "cannot list Library/Application Support (the Ostler* glob root)" "$LIB" "$TMPD/lib.err"
ROOTS=()
ROOTS+=("${HOME_DIR}/.ostler" "${HOME_DIR}/Documents/Ostler" "${HOME_DIR}/Ostler")
while IFS= read -r _n; do
    case "$_n" in Ostler*) ROOTS+=("${LIB}/${_n}") ;; esac
done < "$TMPD/lib.out"

# find_to <outfile> <root> [find args...] : find's OWN exit status, stderr kept.
find_to() {
    local out="$1" root="$2"; shift 2
    find "$root" "$@" > "$out" 2> "$TMPD/find.err"
    return $?
}

# count_root <root> : files and symlinks outside the allowlist; exits 2 on any
# find error. Each existing root first gets a POSITIVE CONTROL: a planted probe
# file must be seen by the same find, then it is removed, before a count of 0 is believed.
count_root() {
    local root="$1" n
    if [ ! -e "$root" ]; then
        if is_absent "$root"; then echo 0; return 0; fi
        cannot_look "root exists but cannot be stat-ed" "$root" /dev/null
    fi
    if ! : > "${root}/${PROBE_NAME}" 2> "$TMPD/plant.err"; then
        cannot_look "cannot plant the positive-control file" "$root" "$TMPD/plant.err"
    fi
    find_to "$TMPD/ctl.out" "$root" \( -type f -o -type l \) -print || { rm -f "${root}/${PROBE_NAME}"; cannot_look "positive-control find failed" "$root" "$TMPD/find.err"; }
    if ! grep -Fxq -- "${root}/${PROBE_NAME}" "$TMPD/ctl.out"; then
        rm -f "${root}/${PROBE_NAME}"
        cannot_look "positive control NOT seen (the count cannot see a planted file)" "$root" /dev/null
    fi
    rm -f "${root}/${PROBE_NAME}" 2> "$TMPD/rm.err" || cannot_look "cannot remove the positive-control file" "$root" "$TMPD/rm.err"
    find_to "$TMPD/cnt.out" "$root" \( -type f -o -type l \) ${ALLOW_ARGS[@]+"${ALLOW_ARGS[@]}"} -print || cannot_look "find failed while counting" "$root" "$TMPD/find.err"
    n="$(wc -l < "$TMPD/cnt.out" | tr -d ' ')"
    echo "$n"
}
count_all() {
    local root="$1"
    [ -e "$root" ] || { echo 0; return 0; }
    find_to "$TMPD/all.out" "$root" \( -type f -o -type l \) -print || cannot_look "find failed while counting allowlisted files" "$root" "$TMPD/find.err"
    wc -l < "$TMPD/all.out" | tr -d ' '
}

if [ "$MODE" = before ]; then
    : > "$STATE"
    for r in "${ROOTS[@]}"; do
        n="$(count_root "$r")" || exit $?
        echo "cold count BEFORE teardown: ${n} files under ${r}"
        printf '%s\t%s\n' "$r" "$n" >> "$STATE"
    done
    exit 0
fi

# wipe. Any non-zero find (or rm run by find) is recorded and makes the box NOT cold.
wipe_err=0
for r in "${ROOTS[@]}"; do
    [ -e "$r" ] || continue
    if ! find_to "$TMPD/w1.out" "$r" \( -type f -o -type l \) ${ALLOW_ARGS[@]+"${ALLOW_ARGS[@]}"} -exec rm -f {} +; then
        echo "WIPE ERROR under ${r}: $(head -1 "$TMPD/find.err")"; wipe_err=1
    fi
    # Empty directories go too; non-empty ones (allowlisted content) stay.
    if ! find_to "$TMPD/w2.out" "$r" -depth -type d -empty -delete; then
        echo "WIPE ERROR (empty dirs) under ${r}: $(head -1 "$TMPD/find.err")"; wipe_err=1
    fi
done

bad="$wipe_err"
SUMMARY=""
for r in "${ROOTS[@]}"; do
    before="$(awk -F'\t' -v r="$r" '$1==r{print $2; exit}' "$STATE" 2>/dev/null)"
    [ -n "$before" ] || before="not-counted"
    after="$(count_root "$r")" || exit $?
    kept=$(( $(count_all "$r") - after ))
    echo "cold count: ${r}: before=${before} after=${after} (allowlisted files kept: ${kept})"
    SUMMARY="${SUMMARY}${r##*/}:${before}->${after} "
    [ "$after" -ne 0 ] && bad=1
done
echo "allowlist rows:"
for p in ${ALLOW_PATHS[@]+"${ALLOW_PATHS[@]}"}; do echo "  ${p}"; done

if [ "$bad" -ne 0 ]; then
    echo "NOT COLD: files survived the wipe outside the allowlist, or the wipe reported errors (first 20 paths):"
    for r in "${ROOTS[@]}"; do
        [ -e "$r" ] || continue
        find_to "$TMPD/left.out" "$r" \( -type f -o -type l \) ${ALLOW_ARGS[@]+"${ALLOW_ARGS[@]}"} -print || cannot_look "find failed while listing survivors" "$r" "$TMPD/find.err"
        cat "$TMPD/left.out"
    done | head -20 | sed 's/^/  /'
    printf 'NOT_COLD(files survive outside the allowlist or the wipe errored: %s)\n' "$SUMMARY" > "$OUT"
    exit 2
fi
printf 'PROVEN(files outside the allowlist, before->after per root: %s)\n' "$SUMMARY" > "$OUT"
echo "cold: PROVEN, 0 files outside the allowlist under every root"
exit 0
