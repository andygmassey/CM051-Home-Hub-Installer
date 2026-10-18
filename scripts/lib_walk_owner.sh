#!/usr/bin/env bash
# lib_walk_owner.sh -- WHOSE identity a walk installs, and proof that it did
# not leak into the walk record. Sourced by scripts/ttywalk.sh and
# scripts/post_walk_qa.sh. Must run under /bin/bash 3.2.
#
# THE DEFECT THIS EXISTS FOR (walk #31, 2026-10-18). ttywalk.sh staged the
# operator-local owner file onto EVERY walked account whenever the file merely
# existed on the driver, and walk_drive.py answered install.sh's "Full name:"
# prompt from it. So a walk on a disposable test account installed the
# operator's REAL name, email and phone into a test box. The synthetic owner
# applied only when the file was absent, i.e. the predicate was "the file is
# present", which is a fact about the DRIVER, never about the TARGET.
#
# THE PREDICATE NOW, declared, never inferred. The owner file is staged ONLY
# when the target's (IOPlatformUUID, login account) pair is listed in an
# operator-local allowlist:
#
#     ${OSTLER_WALK_OWNER_TARGETS:-$HOME/walkdriver/owner_targets.conf}
#
# one pair per line, `<IOPlatformUUID> <account>`, `#` comments allowed. It
# lives outside this PUBLIC repo for the same reason the owner file does.
#
#   owner file absent or empty            -> synthetic (nothing to stage)
#   allowlist absent                      -> synthetic (no owner target declared)
#   pair listed                           -> owner
#   pair not listed                       -> synthetic
#   allowlist unreadable or malformed,
#   target UUID or account empty/garbled  -> REFUSE (exit 2): the predicate
#                                            cannot be evaluated
#
# NEVER PRINTS AN OWNER VALUE. Counts and reasons only.

WALK_OWNER_UUID_RE='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
WALK_OWNER_ACCT_RE='^[A-Za-z_][A-Za-z0-9_.-]*$'

walk_owner_default_file()    { printf '%s\n' "${OSTLER_WALK_OWNER_FILE:-$HOME/walkdriver/owner_identity.env}"; }
walk_owner_default_targets() { printf '%s\n' "${OSTLER_WALK_OWNER_TARGETS:-$HOME/walkdriver/owner_targets.conf}"; }

# walk_owner_decide OWNER_FILE TARGETS_FILE TARGET_UUID TARGET_ACCOUNT
# stdout: `owner` or `synthetic: <reason>`; exit 0.
# stderr + exit 2: the predicate could not be evaluated. Callers REFUSE.
walk_owner_decide() {
    local owner_file="$1" targets="$2" uuid="$3" acct="$4"
    local line u a n=0 lineno=0 hit=0

    if [[ ! -s "$owner_file" ]]; then
        printf 'synthetic: no owner file on the driver\n'; return 0
    fi
    # From here an owner file exists, so a wrong answer could leak it. Every
    # input the predicate needs must be present and well formed, or refuse.
    if [[ -z "$uuid" || ! "$uuid" =~ $WALK_OWNER_UUID_RE ]]; then
        printf 'the target IOPlatformUUID is empty or not a UUID; cannot decide whose identity to install\n' >&2
        return 2
    fi
    if [[ -z "$acct" || ! "$acct" =~ $WALK_OWNER_ACCT_RE ]]; then
        printf 'the target login account is empty or malformed; cannot decide whose identity to install\n' >&2
        return 2
    fi
    if [[ ! -e "$targets" ]]; then
        printf 'synthetic: no owner targets declared (%s absent)\n' "$targets"; return 0
    fi
    if [[ ! -r "$targets" || ! -f "$targets" ]]; then
        printf 'the owner-targets allowlist %s exists but is not a readable file\n' "$targets" >&2
        return 2
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%%#*}"
        # trim
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        u="${line%%[[:space:]]*}"; a="${line#"$u"}"; a="${a#"${a%%[![:space:]]*}"}"
        if [[ ! "$u" =~ $WALK_OWNER_UUID_RE || ! "$a" =~ $WALK_OWNER_ACCT_RE ]]; then
            printf 'the owner-targets allowlist %s line %d is not `<IOPlatformUUID> <account>`\n' "$targets" "$lineno" >&2
            return 2
        fi
        n=$((n + 1))
        # UUIDs compare case-insensitively; account names exactly.
        if [[ "$(printf '%s' "$u" | tr 'a-f' 'A-F')" == "$(printf '%s' "$uuid" | tr 'a-f' 'A-F')" && "$a" == "$acct" ]]; then
            hit=1
        fi
    done < "$targets"
    if [[ "$hit" -eq 1 ]]; then
        printf 'owner\n'
    else
        printf 'synthetic: target not among the %d declared owner target(s)\n' "$n"
    fi
    return 0
}

# _walk_owner_values OWNER_FILE -> one hunted value per line (never printed by
# callers; written only to 0600 temp files). Full values, plus the phone's
# digits-only form so a reformatted number is still caught.
_walk_owner_values() {
    local line k v d
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
        k="${line%%=*}"; v="${line#*=}"
        k="${k//[[:space:]]/}"
        v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
        v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
        case "$k" in OWNER_NAME|OWNER_EMAIL|OWNER_PHONE) ;; *) continue ;; esac
        [[ ${#v} -ge 3 ]] || continue
        printf '%s\n' "$v"
        if [[ "$k" == OWNER_PHONE ]]; then
            d="$(printf '%s' "$v" | tr -cd '0-9')"
            [[ ${#d} -ge 7 && "$d" != "$v" ]] && printf '%s\n' "$d"
        fi
    done < "$1"
}

# walk_owner_scan_record RECORD OWNER_FILE
# Counts, WITHOUT PRINTING, lines of RECORD that contain any owner value.
# Runs a positive control first: a scratch record built from the same values
# must match, or the scan is BROKEN and reports CANNOT-RUN.
# exit 0 clean (or no owner file on this driver, said so), 1 matches, 2 CANNOT-RUN.
walk_owner_scan_record() {
    local record="$1" owner_file="$2" tmp n_vals hits ctl rc
    if [[ ! -e "$owner_file" ]]; then
        printf 'owner-scan: no owner file on this driver (%s); 0 values to hunt\n' "$owner_file"
        return 0
    fi
    if [[ ! -r "$owner_file" ]]; then
        printf 'owner-scan: CANNOT-RUN -- owner file %s exists but is unreadable\n' "$owner_file"
        return 2
    fi
    if [[ ! -r "$record" ]]; then
        printf 'owner-scan: CANNOT-RUN -- record %s is unreadable\n' "$record"
        return 2
    fi
    tmp="$(mktemp -d)" || { printf 'owner-scan: CANNOT-RUN -- mktemp failed\n'; return 2; }
    chmod 700 "$tmp"
    ( umask 077; _walk_owner_values "$owner_file" > "$tmp/v" )
    n_vals="$(grep -c . "$tmp/v")"
    if [[ "$n_vals" -eq 0 ]]; then
        rm -rf "$tmp"
        printf 'owner-scan: CANNOT-RUN -- owner file present but yields 0 values to hunt\n'
        return 2
    fi
    # POSITIVE CONTROL: the predicate must find a value that is there.
    ( umask 077; { printf 'control\tbefore\n'; sed -n 1p "$tmp/v" | sed 's/^/control\t/'; } > "$tmp/ctl" )
    ctl="$(grep -c -i -F -f "$tmp/v" "$tmp/ctl")"; rc=$?
    if [[ "$rc" -ne 0 || "$ctl" -ne 1 ]]; then
        rm -rf "$tmp"
        printf 'owner-scan: BROKEN -- positive control matched %s of 1 (rc %s); CANNOT-RUN\n' "$ctl" "$rc"
        return 2
    fi
    hits="$(grep -c -i -F -f "$tmp/v" "$record")"; rc=$?
    rm -rf "$tmp"
    if [[ "$rc" -gt 1 ]]; then
        printf 'owner-scan: CANNOT-RUN -- grep failed on the record (rc %s)\n' "$rc"
        return 2
    fi
    printf 'owner-scan: hunted %d owner value(s) over %d record line(s); control 1/1; matching lines %d\n' \
        "$n_vals" "$(grep -c '' "$record")" "$hits"
    [[ "$hits" -eq 0 ]] && return 0
    return 1
}
