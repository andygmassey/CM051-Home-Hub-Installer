#!/bin/bash
#
# ostler-vault.sh -- Phase 1 of the Ostler vault: ONE encrypted APFS
# sparsebundle (AES-256), random 256-bit key in the login Keychain, attached
# at login, with a FAIL-CLOSED mountpoint.
#
# OFF BY DEFAULT. Every subcommand refuses (rc 3) unless OSTLER_VAULT=1.
# Nothing in install.sh sources or calls this file in Phase 1, so it cannot
# affect a shipped build.
#
# Design : walkdriver/VAULT_MVP_2026-11-11.md
# Spike  : walkdriver/VAULT_SPIKE_2026-11-11.md
#
# CLAIM THIS MAKES TRUE: bundle bands are AES-256 under a key held in the login
# Keychain. At rest only. Any same-user process can read the key while mounted.
#
# ----------------------------------------------------------------------------
# MEASURED 2026-11-11 (macOS 26.4.1, this Mac, throwaway bundles) -- the three
# things the spike did not catch:
#
#  1. `security find-generic-password -w` prints the secret + "\n", and
#     `hdiutil attach -stdinpass` treats the newline as part of the passphrase:
#        raw pipe          -> "hdiutil: attach failed - Authentication error"
#        newline stripped  -> mounted
#     So the key is always passed through printf %s "$(...)".
#  2. Attach OVER a `chflags uchg` empty directory WORKS (the spike left this
#     untested). The mounted volume is writable; after detach the directory is
#     uchg again and empty. So the design's primary mitigation holds and the
#     "alternative" (a root-owned /Volumes mountpoint) is NOT needed.
#  3. A failed attach followed by `touch <mp>/.mounted` on a NON-uchg dir
#     SUCCEEDS and plants a plaintext sentinel on the plain disk. Hence: the
#     sentinel is only ever written after `mount` confirms the mountpoint, and
#     the guard demands BOTH mount and sentinel.
#  `security create-keychain` leaves the user's keychain search list and
#  default keychain unchanged (measured before/after).
#
# NOT INSTRUMENTED (no command exists in Phase 1 that would show it):
#  - behaviour when the login keychain is LOCKED: `security find-generic-
#    password` can raise an unlock dialog. Phase 1 never calls unlock, always
#    passes the explicit keychain and `-T /usr/bin/security` on add so the
#    item does not prompt for the tool; a LaunchAgent at a fresh login is
#    unmeasured.
#  - Colima/Docker on the bundle at scale beyond the spike; reboot.
#
# bash 3.2 compatible (macOS /bin/bash). Source it, or run it:
#   OSTLER_VAULT=1 ostler-vault.sh create|attach|detach|status|guard|env|exec
#
# Env (all overridable; tests override every one):
#   OSTLER_VAULT_KEYCHAIN  default ~/Library/Keychains/login.keychain-db
#   OSTLER_VAULT_BUNDLE    default ~/Library/Application Support/Ostler/vault.sparsebundle
#   OSTLER_VAULT_MOUNT     default ~/.ovault   (must be < 60 chars: Lima socket limit 104)
#   OSTLER_VAULT_SERVICE   default com.ostler.vault   (Keychain service)
#   OSTLER_VAULT_ACCOUNT   default $USER
#   OSTLER_VAULT_SIZE      default 200g (a ceiling; bands grow on use)
#   OSTLER_VAULT_VOLNAME   default Ostler

OSTLER_VAULT_SENTINEL_NAME=".mounted"
OSTLER_VAULT_MAX_MOUNT_LEN=60

_v_log() { printf 'ostler-vault: %s\n' "$*" >&2; }

_v_cfg() {
    : "${OSTLER_VAULT_KEYCHAIN:=${HOME}/Library/Keychains/login.keychain-db}"
    : "${OSTLER_VAULT_BUNDLE:=${HOME}/Library/Application Support/Ostler/vault.sparsebundle}"
    : "${OSTLER_VAULT_MOUNT:=${HOME}/.ovault}"
    : "${OSTLER_VAULT_SERVICE:=com.ostler.vault}"
    : "${OSTLER_VAULT_ACCOUNT:=${USER:-$(id -un)}}"
    : "${OSTLER_VAULT_SIZE:=200g}"
    : "${OSTLER_VAULT_VOLNAME:=Ostler}"
}

# Off by default. rc 3 = disabled (not an error in the cut sense).
_v_enabled() {
    if [ "${OSTLER_VAULT:-}" != "1" ]; then
        _v_log "disabled (set OSTLER_VAULT=1 to enable)"
        return 3
    fi
    return 0
}

# THE ONLY WAY THIS FILE TALKS TO THE KEYCHAIN. The keychain path is always the
# LAST argument, so a call can never fall through to the default/search-list
# keychain, which is what can raise a Keychain GUI dialog. No unlock-keychain,
# no -p, no add-internet-password, no list-keychains/default-keychain.
# Usage: _v_sec <subcommand> [args...]
_v_sec() {
    local sub="$1"
    shift
    case "$sub" in
        add-generic-password | find-generic-password | delete-generic-password) ;;
        *)
            _v_log "BUG: refusing security subcommand '$sub'"
            return 99
            ;;
    esac
    [ -n "${OSTLER_VAULT_KEYCHAIN}" ] || { _v_log "BUG: empty keychain path"; return 99; }
    security "$sub" "$@" "${OSTLER_VAULT_KEYCHAIN}"
}

_v_key_present() {
    _v_sec find-generic-password -a "${OSTLER_VAULT_ACCOUNT}" -s "${OSTLER_VAULT_SERVICE}" >/dev/null 2>&1
}

# Resolve a directory to its physical path (mount(8) reports /private/tmp, not
# /tmp). Prints nothing and returns 1 if it does not exist.
_v_realdir() { ( cd -P -- "$1" 2>/dev/null && pwd -P ); }

# Is a filesystem mounted exactly at the mountpoint? Reads mount(8), not the
# directory: a plain dir and a mounted volume look the same to `ls`.
_v_is_mounted() {
    local mp
    mp="$(_v_realdir "${OSTLER_VAULT_MOUNT}")" || return 1
    /sbin/mount | /usr/bin/grep -F -q -- " on ${mp} ("
}

_v_sentinel() { printf '%s/%s' "${OSTLER_VAULT_MOUNT}" "${OSTLER_VAULT_SENTINEL_NAME}"; }

_v_check_mount_len() {
    if [ "${#OSTLER_VAULT_MOUNT}" -ge "${OSTLER_VAULT_MAX_MOUNT_LEN}" ]; then
        _v_log "mountpoint '${OSTLER_VAULT_MOUNT}' is ${#OSTLER_VAULT_MOUNT} chars; must be < ${OSTLER_VAULT_MAX_MOUNT_LEN} (Lima socket path limit 104)"
        return 1
    fi
}

# Make the mountpoint an EMPTY, immutable directory while detached. Refuses (and
# changes nothing) if it holds anything while NOT mounted: that is plaintext on
# the plain disk, and attaching over it would hide it rather than remove it.
_v_prepare_mountpoint() {
    _v_check_mount_len || return 1
    if _v_is_mounted; then return 0; fi
    mkdir -p -- "${OSTLER_VAULT_MOUNT}" || { _v_log "cannot create mountpoint"; return 1; }
    if [ -n "$(ls -A -- "${OSTLER_VAULT_MOUNT}" 2>/dev/null)" ]; then
        _v_log "REFUSING: ${OSTLER_VAULT_MOUNT} is not mounted and is not empty (plaintext on the plain disk). Not touching it."
        return 1
    fi
    chflags uchg "${OSTLER_VAULT_MOUNT}" || { _v_log "chflags uchg failed on mountpoint"; return 1; }
}

# Write the sentinel. ONLY after mount confirmed (measured hazard #3).
_v_write_sentinel() {
    _v_is_mounted || { _v_log "BUG: sentinel write while not mounted"; return 1; }
    [ -f "$(_v_sentinel)" ] && return 0
    printf 'ostler-vault 1\n' >"$(_v_sentinel)"
}

# ---------------------------------------------------------------------------
vault_create() {
    _v_enabled || return $?
    _v_cfg
    _v_check_mount_len || return 1
    if [ -e "${OSTLER_VAULT_BUNDLE}" ]; then
        _v_log "REFUSING: bundle already exists at ${OSTLER_VAULT_BUNDLE} (never create over an existing bundle)"
        return 1
    fi
    if _v_key_present; then
        _v_log "REFUSING: a key for ${OSTLER_VAULT_SERVICE} already exists in ${OSTLER_VAULT_KEYCHAIN} (never overwrite)"
        return 1
    fi
    [ -f "${OSTLER_VAULT_KEYCHAIN}" ] || { _v_log "keychain file not found: ${OSTLER_VAULT_KEYCHAIN}"; return 1; }
    mkdir -p -- "$(dirname -- "${OSTLER_VAULT_BUNDLE}")" || return 1

    local key
    key="$(openssl rand -hex 32)" || return 1
    [ "${#key}" -eq 64 ] || { _v_log "key generation failed"; return 1; }

    # Key into Keychain FIRST (no -U: never overwrite). The key is passed to
    # `security` as -w argv (visible to `ps` for milliseconds); there is no
    # stdin form for add-generic-password that avoids the interactive prompt.
    if ! _v_sec add-generic-password -a "${OSTLER_VAULT_ACCOUNT}" -s "${OSTLER_VAULT_SERVICE}" \
        -T /usr/bin/security -w "${key}" >/dev/null 2>&1; then
        _v_log "could not store the key in ${OSTLER_VAULT_KEYCHAIN}"
        return 1
    fi
    if ! printf %s "${key}" | hdiutil create -size "${OSTLER_VAULT_SIZE}" -type SPARSEBUNDLE \
        -fs APFS -encryption AES-256 -stdinpass -volname "${OSTLER_VAULT_VOLNAME}" -nospotlight \
        "${OSTLER_VAULT_BUNDLE}" >/dev/null 2>&1; then
        _v_log "hdiutil create failed; removing the key it would have used"
        _v_sec delete-generic-password -a "${OSTLER_VAULT_ACCOUNT}" -s "${OSTLER_VAULT_SERVICE}" >/dev/null 2>&1
        rm -rf -- "${OSTLER_VAULT_BUNDLE}"
        key=""
        return 1
    fi
    key=""
    # First attach: lay out the volume and plant the sentinel, then detach.
    vault_attach || return 1
    mkdir -p -- "${OSTLER_VAULT_MOUNT}/colima" "${OSTLER_VAULT_MOUNT}/lima" "${OSTLER_VAULT_MOUNT}/docker" || return 1
    tmutil addexclusion "${OSTLER_VAULT_MOUNT}" >/dev/null 2>&1 || true
    vault_detach
}

vault_attach() {
    _v_enabled || return $?
    _v_cfg
    [ -d "${OSTLER_VAULT_BUNDLE}" ] || { _v_log "no bundle at ${OSTLER_VAULT_BUNDLE} (never auto-creating one here)"; return 1; }
    if _v_is_mounted; then
        _v_write_sentinel
        return $?
    fi
    _v_prepare_mountpoint || return 1
    if ! _v_key_present; then
        _v_log "key ${OSTLER_VAULT_SERVICE} missing from ${OSTLER_VAULT_KEYCHAIN}; not creating a new one"
        return 1
    fi
    # printf %s "$(...)" strips the trailing newline -w adds (measured hazard #1).
    # The key never touches argv or disk on this path.
    local key
    key="$(_v_sec find-generic-password -a "${OSTLER_VAULT_ACCOUNT}" -s "${OSTLER_VAULT_SERVICE}" -w 2>/dev/null)" || {
        _v_log "could not read the key"
        return 1
    }
    if ! printf %s "${key}" | hdiutil attach -stdinpass -nobrowse -noverify \
        -mountpoint "${OSTLER_VAULT_MOUNT}" "${OSTLER_VAULT_BUNDLE}" >/dev/null 2>&1; then
        key=""
        _v_log "vault.mount.failed (attach refused: wrong key or damaged bundle); services must stay stopped"
        return 1
    fi
    key=""
    _v_is_mounted || { _v_log "vault.mount.failed (attach returned 0 but nothing is mounted at ${OSTLER_VAULT_MOUNT})"; return 1; }
    _v_write_sentinel
}

vault_detach() {
    _v_enabled || return $?
    _v_cfg
    if ! _v_is_mounted; then
        return 0
    fi
    local i=0
    while [ "$i" -lt 3 ]; do
        if hdiutil detach "${OSTLER_VAULT_MOUNT}" >/dev/null 2>&1; then
            return 0
        fi
        i=$((i + 1))
        sleep 2
    done
    _v_log "detach failed (busy). Holders:"
    /usr/sbin/lsof +D "${OSTLER_VAULT_MOUNT}" 2>/dev/null | head -10 >&2
    return 1
}

# Machine-readable. Exit: 0 ready | 10 detached | 11 no-vault | 12 key-missing | 13 degraded
vault_status() {
    _v_enabled || return $?
    _v_cfg
    local bundle=no key=no mounted=no sentinel=no state rc
    [ -d "${OSTLER_VAULT_BUNDLE}" ] && bundle=yes
    _v_key_present && key=yes
    _v_is_mounted && mounted=yes
    [ "${mounted}" = yes ] && [ -f "$(_v_sentinel)" ] && sentinel=yes
    if [ "${bundle}" = no ]; then state=no-vault rc=11
    elif [ "${mounted}" = yes ] && [ "${sentinel}" = yes ]; then state=ready rc=0
    elif [ "${mounted}" = yes ]; then state=degraded rc=13
    elif [ "${key}" = no ]; then state=key-missing rc=12
    else state=detached rc=10
    fi
    printf 'state=%s\nbundle=%s\nkey=%s\nmounted=%s\nsentinel=%s\nmountpoint=%s\n' \
        "${state}" "${bundle}" "${key}" "${mounted}" "${sentinel}" "${OSTLER_VAULT_MOUNT}"
    return "${rc}"
}

# The check every service/launcher runs BEFORE touching a store. 0 only if the
# bundle is mounted at the mountpoint AND the sentinel is inside it.
vault_guard() {
    _v_enabled || return $?
    _v_cfg
    if _v_is_mounted && [ -f "$(_v_sentinel)" ]; then
        return 0
    fi
    _v_log "vault not mounted: refusing to start (no directories created)"
    return 1
}

# Exports for the container stack, all INSIDE the vault. Prints nothing and
# fails unless the guard passes. DOCKER_CONFIG matters: without it
# `colima start` rewrites the user's shared ~/.docker current context.
vault_env() {
    vault_guard || return 1
    printf 'export COLIMA_HOME=%q\n' "${OSTLER_VAULT_MOUNT}/colima"
    printf 'export LIMA_HOME=%q\n' "${OSTLER_VAULT_MOUNT}/lima"
    printf 'export DOCKER_CONFIG=%q\n' "${OSTLER_VAULT_MOUNT}/docker"
}

# vault_exec <cmd...>: guard, then run cmd with the vault env. The only
# sanctioned way to start Colima.
vault_exec() {
    vault_guard || return 1
    COLIMA_HOME="${OSTLER_VAULT_MOUNT}/colima" \
        LIMA_HOME="${OSTLER_VAULT_MOUNT}/lima" \
        DOCKER_CONFIG="${OSTLER_VAULT_MOUNT}/docker" \
        "$@"
}

# Run directly (not sourced)?
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cmd="${1:-}"
    [ $# -gt 0 ] && shift
    case "$cmd" in
        create) vault_create ;;
        attach) vault_attach ;;
        detach) vault_detach ;;
        status) vault_status ;;
        guard) vault_guard ;;
        env) vault_env ;;
        exec)
            [ "${1:-}" = "--" ] && shift
            vault_exec "$@"
            ;;
        *)
            echo "usage: OSTLER_VAULT=1 $0 create|attach|detach|status|guard|env|exec -- cmd..." >&2
            exit 2
            ;;
    esac
    exit $?
fi
