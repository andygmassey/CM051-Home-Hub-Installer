#!/bin/bash
# lib/ostler-loopback-guard.sh -- keep the local AI engine private to its owner.
#
# THE EXPOSURE (measured on ollama 0.34.0, v1.0.124 red team): Ollama has no
# authentication. Any OTHER account on the Hub Mac, with no credential, could
# use 127.0.0.1:11434 (version, tags, ps, embed, generate, and unload or load a
# model through keep_alive) and the llama-server runner ports Ollama opens on
# EPHEMERAL 127.0.0.1 ports (/health, /props, /slots, /v1/models, /embedding).
# OLLAMA_HOST takes only http(s), so a unix socket is not available.
#
# THE GUARD: a pf anchor that refuses NEW loopback TCP connections to :11434
# and to the ephemeral port range from every uid except the owner, root and,
# when one is configured, the assistant's own macOS account (its separate
# iMessage/WhatsApp identity is ours, so it is allowed explicitly).
# Measured on the Studio, 2026-11-06 (macOS 15.6.1): pf's `user` keyword on
# lo0 in the OUT direction matches the uid that OPENED the connection; owner
# and root got 200, two other uids were blocked, the same probe with no rule
# got 200 for all, and after a flush 200 for all again. pf tags do NOT survive
# lo0 out -> in, so pf cannot pair a client uid with a listener uid; that is
# why the runner ports are covered by the ephemeral RANGE, not by listener.
#
# SIDE EFFECT, STATED (and on the privacy page): other accounts on this Mac
# cannot open loopback TCP connections to ANY ephemeral-range port (their own
# local dev servers included). The owner, the assistant account and root are
# unaffected.
#
# Two halves, one file:
#   ROOT half   install-root | apply | remove | selftest   (run as root)
#   OWNER half  sourced by install.sh: ostler_lg_check, ostler_lg_tighten_ollama_dir,
#               ostler_lg_install_step, ostler_lg_status_field
#
# NO UPDATE EVER PROMPTS (Andy, 2026-11-06). The root half runs ONLY inside the
# INITIAL install's existing elevation (the GUI's one macOS administrator
# dialog, or the CLI's sudo). An update (OSTLER_UPGRADE_MODE) never touches the
# guard and never asks for a password; a box installed before the guard gets
# it by reinstalling. Because the daemon is already root, a future privileged
# change should ride on it rather than add a prompt; today it does NOTHING
# beyond loading this anchor and self-testing it.
# The root copy lives in /Library (root:wheel 0755), never in ~/.ostler, so the
# owner cannot edit a script that runs as root.
#
# Every external tool is overridable (OSTLER_LG_*) so tests run with pfctl,
# sudo, launchctl and sysctl STUBBED. Nothing in the test suite touches pf.
#
# Bash 3.2 (macOS /bin/bash). No associative arrays, no ${var,,}.

LG_DIR="${OSTLER_LG_DIR:-/Library/Application Support/Ostler/loopback-guard}"
LG_ANCHOR="${OSTLER_LG_ANCHOR:-com.apple/ostler-loopback-guard}"
LG_LABEL="${OSTLER_LG_LABEL:-com.ostler.loopback-guard}"
LG_PLIST="${OSTLER_LG_PLIST:-/Library/LaunchDaemons/com.ostler.loopback-guard.plist}"
LG_PFCTL="${OSTLER_LG_PFCTL:-/sbin/pfctl}"
LG_SYSCTL="${OSTLER_LG_SYSCTL:-/usr/sbin/sysctl}"
LG_LAUNCHCTL="${OSTLER_LG_LAUNCHCTL:-/bin/launchctl}"
LG_SUDO="${OSTLER_LG_SUDO:-/usr/bin/sudo}"
LG_PERL="${OSTLER_LG_PERL:-/usr/bin/perl}"
LG_CHOWN="${OSTLER_LG_CHOWN:-/usr/sbin/chown}"
LG_ID="${OSTLER_LG_ID:-/usr/bin/id}"
LG_PROBE_HOST="${OSTLER_LG_PROBE_HOST:-127.0.0.1}"
LG_PROBE_TIMEOUT="${OSTLER_LG_PROBE_TIMEOUT:-3}"
LG_OTHER_USER="${OSTLER_LG_OTHER_USER:-nobody}"
LG_FIXED_PORT=11434
# A port inside the ephemeral range: stands in for a runner port. A blocked
# connect TIMES OUT (pf drops the SYN); an unblocked one to a closed port is
# REFUSED at once. That difference is the whole self-test, and it needs no
# running Ollama.
LG_SENTINEL_PORT="${OSTLER_LG_SENTINEL_PORT:-65531}"
# A port OUTSIDE the guard (discard, 9): the other uid must get REFUSED here.
# If it times out too, the probe cannot tell blocked from broken.
LG_CONTROL_PORT="${OSTLER_LG_CONTROL_PORT:-9}"
LG_RULE_COUNT=4
LG_MIN_HUMAN_UID=501   # macOS gives people uids from 501; below that are system accounts
LG_STATUS_MAX_AGE="${OSTLER_LG_STATUS_MAX_AGE:-900}"   # daemon re-checks every 300 s

_lg_now() { date +%s; }
_lg_euid() { echo "${OSTLER_LG_EUID:-$(id -u)}"; }
_lg_is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# ── rules ─────────────────────────────────────────────────────────────────
# `no state`: the pass rules must not create pf state, or a busy owner (69
# ingest sockets were measured on one walk) could fill the state table and
# have its OWN connections dropped. flags S/SA: only a NEW connection's SYN is
# judged; replies and established traffic never match.
ostler_lg_rules() {   # $1 owner uid, $2 first ephemeral port, $3 last, $4 assistant uid (optional)
    local owner="$1" first="$2" last="$3" asst="${4:-}" users
    _lg_is_uint "$owner" && _lg_is_uint "$first" && _lg_is_uint "$last" || { echo "ostler_lg_rules: non-numeric input" >&2; return 2; }
    [ "$owner" -gt 0 ] || { echo "ostler_lg_rules: owner uid must not be root" >&2; return 2; }
    users="${owner}, 0"
    if [ -n "$asst" ]; then
        _lg_is_uint "$asst" && [ "$asst" -gt 0 ] && [ "$asst" != "$owner" ] || { echo "ostler_lg_rules: bad assistant uid '${asst}'" >&2; return 2; }
        users="${owner}, ${asst}, 0"
    fi
    [ "$first" -ge 1024 ] && [ "$first" -le "$last" ] && [ "$last" -le 65535 ] || { echo "ostler_lg_rules: bad range ${first}:${last}" >&2; return 2; }
    [ "$LG_FIXED_PORT" -lt "$first" ] || { echo "ostler_lg_rules: fixed port inside the range" >&2; return 2; }
    cat <<RULES
# Ostler loopback guard (lib/ostler-loopback-guard.sh). Owner uid ${owner}, assistant uid ${asst:-none}.
pass out quick on lo0 proto tcp from any to any port ${LG_FIXED_PORT} flags S/SA user { ${users} } no state
block drop out quick on lo0 proto tcp from any to any port ${LG_FIXED_PORT} flags S/SA
pass out quick on lo0 proto tcp from any to any port ${first}:${last} flags S/SA user { ${users} } no state
block drop out quick on lo0 proto tcp from any to any port ${first}:${last} flags S/SA
RULES
}

ostler_lg_ephemeral_range() {   # prints "first last"
    local f l
    f="$("$LG_SYSCTL" -n net.inet.ip.portrange.first)" || return 1
    l="$("$LG_SYSCTL" -n net.inet.ip.portrange.last)" || return 1
    _lg_is_uint "$f" && _lg_is_uint "$l" || return 1
    echo "$f $l"
}

# ── the assistant's own macOS account ─────────────────────────────────────
# The assistant's separate iMessage/WhatsApp identity runs in its OWN macOS
# account (the founder bridge: vendor/imessage_bridge/bin/bridge.py, run as
# that account, writing /Users/Shared/imessage-bridge/inbox.jsonl). It is
# ours, so its uid is allowed explicitly. Configured by name, in
# OSTLER_ASSISTANT_MAC_USER (environment, or that line in the owner's
# ~/.ostler/.env), and resolved to a uid ONLY at install, inside the install's
# own elevation. The daemon reads only the root-owned assistant_uid file.
_lg_owner_home() {   # $1 owner uid
    [ -n "${OSTLER_LG_OWNER_HOME:-}" ] && { echo "$OSTLER_LG_OWNER_HOME"; return 0; }
    "$LG_PERL" -e 'my @p = getpwuid($ARGV[0]); print $p[7] if @p' "$1" 2>/dev/null
}

# Prints the configured assistant account NAME, or nothing.
ostler_lg_configured_assistant() {   # $1 owner uid
    local h
    if [ -n "${OSTLER_ASSISTANT_MAC_USER:-}" ]; then echo "$OSTLER_ASSISTANT_MAC_USER"; return 0; fi
    h="$(_lg_owner_home "$1")"
    [ -n "$h" ] && [ -r "${h}/.ostler/.env" ] || return 0
    sed -n 's/^OSTLER_ASSISTANT_MAC_USER=//p' "${h}/.ostler/.env" | tail -1 | tr -d "\"' "
}

# Prints the assistant uid for a name; rc 2 with a reason on stderr when the
# account is not one we can safely allow. An empty name prints nothing, rc 0.
ostler_lg_resolve_assistant() {   # $1 name, $2 owner uid
    local name="$1" owner="$2" uid
    [ -n "$name" ] || return 0
    case "$name" in -*|*[!A-Za-z0-9_.-]*) echo "assistant_user_invalid_name" >&2; return 2 ;; esac
    [ "$name" != "$LG_OTHER_USER" ] || { echo "assistant_user_is_the_selftest_account(${name})" >&2; return 2; }
    uid="$("$LG_ID" -u -- "$name" 2>/dev/null)" || { echo "assistant_user_not_found(${name})" >&2; return 2; }
    _lg_is_uint "$uid" || { echo "assistant_user_uid_unreadable(${name})" >&2; return 2; }
    [ "$uid" -ge "$LG_MIN_HUMAN_UID" ] || { echo "assistant_user_is_a_system_account(${name}=${uid})" >&2; return 2; }
    [ "$uid" != "$owner" ] || { echo "assistant_user_is_the_owner(${name})" >&2; return 2; }
    echo "$uid"
}

# ── probe ─────────────────────────────────────────────────────────────────
# One TCP connect, as a given account. Prints connected | refused | timeout |
# error:<reason>. Run by root (sudo -u needs no password for root).
ostler_lg_probe() {   # $1 sudo user spec (name or #uid), $2 port
    "$LG_SUDO" -n -u "$1" "$LG_PERL" -MIO::Socket::INET -e '
        my ($h, $p, $t) = @ARGV;
        my $s = IO::Socket::INET->new(PeerAddr => $h, PeerPort => $p, Proto => "tcp", Timeout => $t);
        if ($s) { print "connected\n"; exit 0 }
        my $e = "$! $@";
        if ($e =~ /refused/i) { print "refused\n" }
        elsif ($e =~ /timed? ?out/i) { print "timeout\n" }
        else { $e =~ s/\s+/_/g; print "error:$e\n" }' "$LG_PROBE_HOST" "$2" "$LG_PROBE_TIMEOUT" 2>/dev/null \
        || echo "error:probe_could_not_run"
}

# Prints key=value lines; rc 0 only when every check holds.
ostler_lg_selftest() {   # $1 owner uid, $2 assistant uid (optional)
    local owner="$1" asst="${2:-}" c o_fixed o_sent x_fixed x_sent a_fixed="" a_sent="" fail=""
    c="$(ostler_lg_probe "$LG_OTHER_USER" "$LG_CONTROL_PORT")"
    x_fixed="$(ostler_lg_probe "$LG_OTHER_USER" "$LG_FIXED_PORT")"
    x_sent="$(ostler_lg_probe "$LG_OTHER_USER" "$LG_SENTINEL_PORT")"
    o_fixed="$(ostler_lg_probe "#${owner}" "$LG_FIXED_PORT")"
    o_sent="$(ostler_lg_probe "#${owner}" "$LG_SENTINEL_PORT")"
    if [ -n "$asst" ]; then
        a_fixed="$(ostler_lg_probe "#${asst}" "$LG_FIXED_PORT")"
        a_sent="$(ostler_lg_probe "#${asst}" "$LG_SENTINEL_PORT")"
    fi
    echo "probe_other_control_${LG_CONTROL_PORT}=${c}"
    echo "probe_other_${LG_FIXED_PORT}=${x_fixed}"
    echo "probe_other_runner_${LG_SENTINEL_PORT}=${x_sent}"
    echo "probe_owner_${LG_FIXED_PORT}=${o_fixed}"
    echo "probe_owner_runner_${LG_SENTINEL_PORT}=${o_sent}"
    if [ -n "$asst" ]; then
        echo "probe_assistant_${LG_FIXED_PORT}=${a_fixed}"
        echo "probe_assistant_runner_${LG_SENTINEL_PORT}=${a_sent}"
    fi
    # The control first: if the other account cannot even be REFUSED on an
    # unguarded port, a timeout below proves nothing (CANNOT-RUN, failed closed).
    case "$c" in refused|connected) ;; *) fail="selftest_control_not_refused(${c})" ;; esac
    [ -n "$fail" ] || [ "$x_fixed" = timeout ] || fail="other_account_reaches_${LG_FIXED_PORT}(${x_fixed})"
    [ -n "$fail" ] || [ "$x_sent" = timeout ] || fail="other_account_reaches_runner_range(${x_sent})"
    [ -n "$fail" ] || case "$o_fixed" in connected|refused) ;; *) fail="owner_blocked_on_${LG_FIXED_PORT}(${o_fixed})" ;; esac
    [ -n "$fail" ] || case "$o_sent" in connected|refused) ;; *) fail="owner_blocked_on_runner_range(${o_sent})" ;; esac
    if [ -n "$asst" ]; then
        [ -n "$fail" ] || case "$a_fixed" in connected|refused) ;; *) fail="assistant_blocked_on_${LG_FIXED_PORT}(${a_fixed})" ;; esac
        [ -n "$fail" ] || case "$a_sent" in connected|refused) ;; *) fail="assistant_blocked_on_runner_range(${a_sent})" ;; esac
    fi
    if [ -n "$fail" ]; then echo "selftest=fail"; echo "selftest_reason=${fail}"; return 1; fi
    echo "selftest=ok"; return 0
}

# ── status (root writes, anyone reads) ────────────────────────────────────
ostler_lg_status_field() {   # $1 key, $2 status file (default LG_DIR/status)
    local f="${2:-${LG_DIR}/status}"
    [ -r "$f" ] || return 1
    sed -n "s/^${1}=//p" "$f" | tail -1
}

_lg_write_status() {   # stdin = body
    local tmp="${LG_DIR}/status.tmp.$$"
    cat > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "${LG_DIR}/status"
}

_lg_notify_owner() {   # $1 owner uid, $2 text. Best effort, never fatal.
    "$LG_LAUNCHCTL" asuser "$1" /usr/bin/osascript -e "display notification \"$2\" with title \"Ostler\"" >/dev/null 2>&1 || true
}

# ── apply (root; the daemon's entry point) ────────────────────────────────
ostler_lg_apply() {
    local owner asst range first last rules_n info tok boot prev st reason="" pf_on=no selftest_out
    # Bound the daemon's own log (one line per 300 s tick): keep the newest half.
    if [ -f "${LG_DIR}/guard.log" ] && [ "$(wc -c < "${LG_DIR}/guard.log")" -gt 262144 ]; then
        tail -c 131072 "${LG_DIR}/guard.log" > "${LG_DIR}/guard.log.tmp" && cat "${LG_DIR}/guard.log.tmp" > "${LG_DIR}/guard.log"; rm -f "${LG_DIR}/guard.log.tmp"
    fi
    owner="$(cat "${LG_DIR}/owner_uid" 2>/dev/null)"
    asst="$(cat "${LG_DIR}/assistant_uid" 2>/dev/null)"
    prev="$(ostler_lg_status_field verdict 2>/dev/null)"
    boot="$("$LG_SYSCTL" -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9]*\).*/\1/p')"
    if ! _lg_is_uint "$owner" || [ "$owner" -eq 0 ]; then reason="owner_uid_missing_or_invalid"
    elif [ -n "$asst" ] && { ! _lg_is_uint "$asst" || [ "$asst" -eq 0 ] || [ "$asst" = "$owner" ]; }; then reason="assistant_uid_invalid"
    elif ! range="$(ostler_lg_ephemeral_range)"; then reason="ephemeral_range_unreadable"
    else
        first="${range% *}"; last="${range#* }"
        if ! ostler_lg_rules "$owner" "$first" "$last" "$asst" > "${LG_DIR}/rules.conf" 2>"${LG_DIR}/rules.err"; then
            reason="rules_render_failed($(tr '\n' ' ' < "${LG_DIR}/rules.err"))"
        fi
    fi
    if [ -z "$reason" ]; then
        # Take OUR OWN reference on pf (pfctl -E returns a token), once per boot.
        # A reference survives other tools' `pfctl -d`/-X of theirs.
        info="$("$LG_PFCTL" -s info 2>/dev/null)"
        tok="$(sed -n "s/^boot=${boot:-none} token=//p" "${LG_DIR}/pf.token" 2>/dev/null)"
        if [ -z "$tok" ] || ! grep -q 'Status: Enabled' <<<"$info"; then
            tok="$("$LG_PFCTL" -E 2>&1 | sed -n 's/.*[Tt]oken *: *\([0-9][0-9]*\).*/\1/p' | tail -1)"
            if [ -n "$tok" ]; then printf 'boot=%s token=%s\n' "${boot:-none}" "$tok" > "${LG_DIR}/pf.token"; else reason="pf_enable_failed"; fi
        fi
    fi
    if [ -z "$reason" ]; then
        "$LG_PFCTL" -a "$LG_ANCHOR" -f "${LG_DIR}/rules.conf" > "${LG_DIR}/pfctl.out" 2>&1 || reason="anchor_load_failed"
    fi
    if [ -z "$reason" ]; then
        rules_n="$("$LG_PFCTL" -a "$LG_ANCHOR" -s rules 2>/dev/null | grep -c -E '^(pass|block) ')"
        [ "$rules_n" = "$LG_RULE_COUNT" ] || reason="anchor_rules_mismatch(${rules_n:-0}/${LG_RULE_COUNT})"
    fi
    info="$("$LG_PFCTL" -s info 2>/dev/null)"; grep -q 'Status: Enabled' <<<"$info" && pf_on=yes
    [ -n "$reason" ] || [ "$pf_on" = yes ] || reason="pf_not_enabled"
    selftest_out=""
    if [ -z "$reason" ]; then
        selftest_out="$(ostler_lg_selftest "$owner" "$asst")" || reason="$(printf '%s\n' "$selftest_out" | sed -n 's/^selftest_reason=//p')"
    fi
    if [ -z "$reason" ]; then st=ok; else st=fail; fi
    {
        echo "verdict=${st}"
        echo "reason=${reason:-none}"
        echo "owner_uid=${owner:-unknown}"
        echo "assistant_uid=${asst:-none}"
        echo "anchor=${LG_ANCHOR}"
        echo "ephemeral=${first:-?}:${last:-?}"
        echo "rules_loaded=${rules_n:-0}"
        echo "pf_enabled=${pf_on}"
        printf '%s\n' "$selftest_out" | grep -v '^$'
        echo "checked_at=$(_lg_now)"
    } | _lg_write_status
    if [ "$st" = fail ] && [ "$prev" != fail ] && _lg_is_uint "$owner"; then
        _lg_notify_owner "$owner" "Ostler privacy guard is not active: other accounts on this Mac could reach the local AI engine. Open Ostler Doctor to fix it."  # i18n-exempt (root context has no locale; Doctor carries the localised text)
    fi
    echo "loopback-guard: verdict=${st} reason=${reason:-none}"
    [ "$st" = ok ]
}

# ── install / remove (root) ───────────────────────────────────────────────
_lg_plist_body() {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LG_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${LG_DIR}/ostler-loopback-guard.sh</string>
        <string>apply</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>StandardOutPath</key>
    <string>${LG_DIR}/guard.log</string>
    <key>StandardErrorPath</key>
    <string>${LG_DIR}/guard.log</string>
</dict>
</plist>
PLIST
}

ostler_lg_install_root() {   # $1 owner uid, $2 source copy of this file, $3 assistant account name (optional)
    local owner="$1" src="$2" aname="${3:-}" auid
    [ "$(_lg_euid)" = 0 ] || { echo "install-root must run as root" >&2; return 2; }
    _lg_is_uint "$owner" && [ "$owner" -gt 0 ] || { echo "install-root: bad owner uid '${owner}'" >&2; return 2; }
    [ -r "$src" ] || { echo "install-root: cannot read ${src}" >&2; return 2; }
    # The assistant account: the name passed in, else the owner's configured one.
    # A configured account we cannot resolve STOPS the install (rc 2): allowing
    # nobody would silently cut the assistant off; guessing would allow a stranger.
    [ -n "$aname" ] || aname="$(ostler_lg_configured_assistant "$owner")"
    auid="$(ostler_lg_resolve_assistant "$aname" "$owner")" || { echo "install-root: assistant account '${aname}' refused" >&2; return 2; }
    mkdir -p "$LG_DIR" || return 1
    "$LG_CHOWN" root:wheel "$LG_DIR" && chmod 0755 "$LG_DIR" || return 1
    if [ "$src" != "${LG_DIR}/ostler-loopback-guard.sh" ]; then
        cp -f "$src" "${LG_DIR}/ostler-loopback-guard.sh.new" && mv -f "${LG_DIR}/ostler-loopback-guard.sh.new" "${LG_DIR}/ostler-loopback-guard.sh" || return 1
    fi
    "$LG_CHOWN" root:wheel "${LG_DIR}/ostler-loopback-guard.sh" && chmod 0755 "${LG_DIR}/ostler-loopback-guard.sh" || return 1
    printf '%s\n' "$owner" > "${LG_DIR}/owner_uid" && chmod 0644 "${LG_DIR}/owner_uid" || return 1
    if [ -n "$auid" ]; then
        printf '%s\n' "$auid" > "${LG_DIR}/assistant_uid" && chmod 0644 "${LG_DIR}/assistant_uid" || return 1
    else
        rm -f "${LG_DIR}/assistant_uid"
    fi
    _lg_plist_body > "${LG_PLIST}.new" && "$LG_CHOWN" root:wheel "${LG_PLIST}.new" && chmod 0644 "${LG_PLIST}.new" && mv -f "${LG_PLIST}.new" "$LG_PLIST" || return 1
    # Synchronous first apply, so the caller reads a fresh verdict now; the
    # daemon then keeps it true at every boot and every 300 s.
    ostler_lg_apply; local rc=$?
    "$LG_LAUNCHCTL" bootout "system/${LG_LABEL}" >/dev/null 2>&1 || true
    if ! "$LG_LAUNCHCTL" bootstrap system "$LG_PLIST"; then
        echo "install-root: launchctl bootstrap of ${LG_LABEL} failed" >&2
        printf 'reason=daemon_bootstrap_failed\nverdict=fail\n' >> "${LG_DIR}/status"
        return 1
    fi
    return $rc
}

ostler_lg_remove() {   # root. Prints each step; rc 1 if any rule is left behind.
    local tok left
    [ "$(_lg_euid)" = 0 ] || { echo "remove must run as root" >&2; return 2; }
    "$LG_LAUNCHCTL" bootout "system/${LG_LABEL}" >/dev/null 2>&1 || true
    rm -f "$LG_PLIST"
    "$LG_PFCTL" -a "$LG_ANCHOR" -F all >/dev/null 2>&1
    tok="$(sed -n 's/^boot=[^ ]* token=//p' "${LG_DIR}/pf.token" 2>/dev/null)"
    [ -z "$tok" ] || "$LG_PFCTL" -X "$tok" >/dev/null 2>&1 || true
    left="$("$LG_PFCTL" -a "$LG_ANCHOR" -s rules 2>/dev/null | grep -c -E '^(pass|block) ')"
    rm -rf "$LG_DIR"
    if [ "${left:-0}" != 0 ]; then echo "loopback-guard: ${left} rule(s) still loaded in ${LG_ANCHOR}" >&2; return 1; fi
    echo "loopback-guard: removed (daemon, anchor, pf reference, files)"
}

# ── owner half (sourced by install.sh; no root) ───────────────────────────
# rc 0 only for a FRESH ok verdict with the daemon plist installed.
ostler_lg_check() {   # $1 max status age in seconds (default LG_STATUS_MAX_AGE)
    local v at now max="${1:-$LG_STATUS_MAX_AGE}" aname want
    [ -f "$LG_PLIST" ] || { echo "daemon_not_installed"; return 1; }
    v="$(ostler_lg_status_field verdict)" || { echo "no_status"; return 1; }
    at="$(ostler_lg_status_field checked_at)"; now="$(_lg_now)"
    _lg_is_uint "$at" || { echo "status_unreadable"; return 1; }
    [ $((now - at)) -le "$max" ] || { echo "status_stale($((now - at))s)"; return 1; }
    [ "$v" = ok ] || { echo "$(ostler_lg_status_field reason)"; return 1; }
    [ "$(ostler_lg_status_field owner_uid)" = "$(id -u)" ] || { echo "guard_owner_is_another_account"; return 1; }
    # The configured assistant account must be the one the guard allows.
    aname="$(ostler_lg_configured_assistant "$(id -u)")"
    want="$(ostler_lg_resolve_assistant "$aname" "$(id -u)" 2>&1)" || { echo "$want"; return 1; }
    [ "$(ostler_lg_status_field assistant_uid)" = "${want:-none}" ] || { echo "assistant_not_in_guard(${aname:-none})"; return 1; }
    echo ok
}

# ~/.ollama held models and keys world-readable (0755). Owner-only.
ostler_lg_tighten_ollama_dir() {
    local d="${1:-${HOME}/.ollama}"
    [ -d "$d" ] || return 0
    chmod 0700 "$d"
}

# install.sh step (owner context; uses install.sh's fail_with_code/ok/warn).
# FAILS CLOSED: the install stops unless a FRESH ok verdict exists. Under
# OSTLER_GUI=1 the root half already ran inside the installer's one admin
# shell (AuthorizationHelper.swift); on the CLI path install.sh holds sudo.
ostler_lg_install_step() {   # $1 path of this lib
    local lib="$1" why saved_trap had_e=0
    saved_trap="$(trap -p ERR)"; trap - ERR; case $- in *e*) had_e=1 ;; esac; set +e
    ostler_lg_tighten_ollama_dir || warn "could not make ~/.ollama owner-only (chmod 0700)"  # i18n-exempt
    mkdir -p "${OSTLER_DIR}/lib" && cp -f "$lib" "${OSTLER_DIR}/lib/ostler-loopback-guard.sh"
    why="$(ostler_lg_check)"
    if [ "$why" != ok ] && [ "${OSTLER_GUI:-0}" != 1 ] && "$LG_SUDO" -n /usr/bin/true 2>/dev/null; then
        "$LG_SUDO" -n /bin/bash "$lib" install-root "$(id -u)" "$lib" "$(ostler_lg_configured_assistant "$(id -u)")" >> "${INSTALL_LOG:-/dev/null}" 2>&1
        why="$(ostler_lg_check)"
    fi
    { echo "loopback_guard=${why}"; cat "${LG_DIR}/status" 2>/dev/null | sed 's/^/loopback_guard_status: /'; } >> "${INSTALL_LOG:-/dev/null}" 2>/dev/null
    [ "$had_e" = 1 ] && set -e; eval "${saved_trap:-:}"
    if [ "$why" = ok ]; then
        ok "Local AI engine is private to this account: other accounts on this Mac are refused"  # i18n-exempt
        return 0
    fi
    fail_with_code "ERR-08-LOOPBACK-GUARD-NOT-ACTIVE" "$(printf "$MSG_FAIL_LOOPBACK_GUARD_NOT_ACTIVE" "$why" "${INSTALL_LOG:-}")"
}

# ── CLI ───────────────────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        apply)        ostler_lg_apply ;;
        install-root) ostler_lg_install_root "${2:-}" "${3:-$0}" "${4:-}" ;;
        remove)       ostler_lg_remove ;;
        selftest)     ostler_lg_selftest "${2:-$(cat "${LG_DIR}/owner_uid" 2>/dev/null)}" "${3:-$(cat "${LG_DIR}/assistant_uid" 2>/dev/null)}" ;;
        rules)        ostler_lg_rules "${2:-}" "${3:-49152}" "${4:-65535}" "${5:-}" ;;
        check)        ostler_lg_check ;;
        *) echo "usage: $0 apply|install-root <owner_uid> [src] [assistant_user]|remove|selftest [uid] [assistant_uid]|rules <uid> [first last] [assistant_uid]|check" >&2; exit 64 ;;
    esac
fi
