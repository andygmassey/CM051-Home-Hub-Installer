#!/usr/bin/env bash
# ostler-conversations-mirror.sh -- the signed fda-rerun tick copies the owner's
# conversations into ~/.ostler/state/conversations_mirror so the derive-preferences
# agent (bare launchd python) never opens ~/Documents (TCC charged python3.11 on
# the v1.0.121 walk: no_python_is_tcc_responsible FAIL).
#
# Sourced by ~/.ostler/bin/ostler-fda (written by install.sh), which runs
# _ostler_conversations_mirror on every tick. Status lines go to STDERR
# (fda-rerun.err), never stdout: the wrapper's stdout is read by callers and
# tests. Nothing is swallowed.
#
# WHAT IS COPIED: only files whose frontmatter privacy_level is L0, L1 or L2.
# L3 and a file with NO level stay out, matching derive stated.py
# BLOCKED_PRIVACY={"L3"} and its fail-closed no-level skip. A plain `rsync -a`
# would put the L3 files in a second place on disk. Blocked files are passed to
# rsync as --exclude with --delete-excluded, so a file deleted from the source, or
# re-levelled to L3, leaves the mirror on the next tick (one tick behind at most).
# --prune-empty-dirs keeps a withheld conversation's directory name out as well.
# Mirror dirs are 700 and files 600.

_ostler_conv_level() { # <file> -> privacy_level per derive fm_value, or empty
    awk '
        NR == 1 { if ($0 !~ /^---/) exit; next }
        /^---/ { exit }
        /^[ \t]*privacy_level:/ {
            v = $0; sub(/^[ \t]*privacy_level:[ \t]*/, "", v)
            gsub(/^[ \t"\047]+|[ \t"\047\r]+$/, "", v); print v; exit
        }' "$1"
}

_ostler_conversations_mirror() {
    local src="${HOME}/Documents/Ostler/Conversations"
    local dst="${OSTLER_DIR}/state/conversations_mirror"
    [[ -d "$src" ]] || return 0
    if ! command -v rsync >/dev/null 2>&1; then
        echo "[mirror] CANNOT-RUN: rsync not found, conversations_mirror not updated" >&2
        return 0
    fi
    local old_umask; old_umask="$(umask)"; umask 077
    local rc=0 excl f rel lvl blocked=0 kept=0
    if ! mkdir -p "$dst"; then
        echo "[mirror] FAIL: cannot create ${dst}" >&2; umask "$old_umask"; return 0
    fi
    chmod 700 "$dst" || echo "[mirror] FAIL: chmod 700 ${dst}" >&2
    excl="$(mktemp "${dst}.excl.XXXXXX")" || { echo "[mirror] FAIL: mktemp" >&2; umask "$old_umask"; return 0; }
    while IFS= read -r -d '' f; do
        rel="${f#"${src}"/}"
        lvl="$(_ostler_conv_level "$f")" || lvl=""
        case "$lvl" in
            L0|L1|L2) kept=$((kept + 1)) ;;
            *)  blocked=$((blocked + 1))
                # rsync patterns: anchor at the transfer root, escape glob chars
                printf '/%s\n' "$rel" | sed -e 's/[][*?\\]/\\&/g' >> "$excl" ;;
        esac
    done < <(find "$src" -type f -print0)
    rsync -a --delete --delete-excluded --prune-empty-dirs --exclude-from="$excl" "${src}/" "${dst}/" || rc=$?
    rm -f "$excl"
    if [[ $rc -ne 0 ]]; then
        echo "[mirror] FAIL: rsync exit ${rc}, conversations_mirror may be stale" >&2
    else
        echo "[mirror] ok: ${kept} file(s) mirrored, ${blocked} withheld (L3 or no privacy_level)" >&2
    fi
    find "$dst" -type d -exec chmod 700 {} + || echo "[mirror] FAIL: chmod dirs" >&2
    find "$dst" -type f -exec chmod 600 {} + || echo "[mirror] FAIL: chmod files" >&2
    umask "$old_umask"
    return 0
}
