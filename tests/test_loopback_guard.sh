#!/bin/bash
# tests/test_loopback_guard.sh -- lib/ostler-loopback-guard.sh with pf STUBBED.
#
# Nothing here touches pf, launchd, sudo or a real account. pfctl, sudo,
# sysctl, launchctl and chown are stubs on explicit paths. The sudo stub is a
# small MODEL of the kernel: it reads the rules the guard actually loaded into
# the fake anchor and decides, per uid and port, whether a connect would be
# dropped (timeout) or reach a closed port (refused). So a mutant in the RULE
# TEXT changes the self-test verdict, which is what proves the self-test reads
# the rules rather than the flags around them.
#
# What this does NOT prove, said plainly: that the real pf honours these rules.
# That was measured on the Studio on 2026-11-06 (user keyword on lo0, owner and
# root pass, two other uids blocked, a control with no rules and a flush both
# reachable) and is re-proven only by the live cold-install run, which waits on
# Andy's yes. The `no state` keyword is NOT yet measured live.
#
# Runs under /bin/bash 3.2.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LIB="${HERE}/lib/ostler-loopback-guard.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

mkstubs() {   # $1 dir
    local d="$1"; mkdir -p "$d/bin" "$d/pf" "$d/guard"
    : > "$d/pf/calls"
    cat > "$d/bin/pfctl" <<'EOF'
#!/bin/bash
D="$(cd "$(dirname "$0")/../pf" && pwd)"
echo "pfctl $*" >> "$D/calls"
[ -f "$D/fail_E" ] && [ "$1" = -E ] && { echo "pfctl: DIOCSTARTREF: Operation not permitted" >&2; exit 1; }
case "$1" in
  -E) touch "$D/enabled"; echo "pf enabled"; echo "Token : 4242"; exit 0 ;;
  -X) rm -f "$D/enabled"; echo "pf disabled"; exit 0 ;;
  -s) [ "$2" = info ] && { [ -f "$D/enabled" ] && echo "Status: Enabled for 0 days" || echo "Status: Disabled for 0 days"; }; exit 0 ;;
  -a) A="$2"; shift 2
      case "$1" in
        -f) [ -f "$D/fail_load" ] && { echo "syntax error" >&2; exit 1; }
            [ -f "$D/ignore_load" ] && exit 0
            grep -v -e '^#' -e '^$' "$2" > "$D/anchor"; exit 0 ;;
        -s) cat "$D/anchor" 2>/dev/null; exit 0 ;;
        -F) [ -f "$D/ignore_flush" ] || : > "$D/anchor"; exit 0 ;;
      esac ;;
esac
exit 0
EOF
    # sudo -n -u <spec> perl ... <host> <port> <timeout>: answer from the loaded rules.
    cat > "$d/bin/sudo" <<'EOF'
#!/bin/bash
D="$(cd "$(dirname "$0")/../pf" && pwd)"
spec="$3"; port="${@: -2:1}"
case "$spec" in nobody) uid=4294967294 ;; \#*) uid="${spec#\#}" ;; *) uid=999 ;; esac
[ -f "$D/control_times_out" ] && [ "$port" = 9 ] && { echo timeout; exit 0; }
[ -f "$D/enabled" ] || { echo refused; exit 0; }
verdict=refused
# first matching quick rule wins (all guard rules are quick)
while read -r act rest; do
  [ "$act" = pass ] || [ "$act" = block ] || continue
  ports="$(printf '%s' "$rest" | sed -n 's/.* port \([0-9:]*\) .*/\1/p')"
  [ -n "$ports" ] || continue
  case "$ports" in *:*) lo_p="${ports%:*}"; hi_p="${ports#*:}" ;; *) lo_p="$ports"; hi_p="$ports" ;; esac
  [ "$port" -ge "$lo_p" ] && [ "$port" -le "$hi_p" ] || continue
  if [ "$act" = pass ]; then
    users="$(printf '%s' "$rest" | sed -n 's/.*user { \([0-9, ]*\) }.*/\1/p' | tr -d ' ')"
    case "$rest" in *"user "*) ;; *) verdict=refused; break ;; esac   # a pass with no user clause passes everyone
    case ",${users}," in *",${uid},"*) verdict=refused; break ;; esac
    continue
  fi
  verdict=timeout; break
done < "$D/anchor"
echo "$verdict"
EOF
    cat > "$d/bin/sysctl" <<'EOF'
#!/bin/bash
case "$2" in
  net.inet.ip.portrange.first) echo 49152 ;; net.inet.ip.portrange.last) echo 65535 ;;
  kern.boottime) echo "{ sec = 1762400000, usec = 0 } Thu Nov  6 00:00:00 2026" ;;
esac
EOF
    printf '#!/bin/bash\necho "launchctl $*" >> "%s/pf/calls"\nexit 0\n' "$d" > "$d/bin/launchctl"
    printf '#!/bin/bash\nexit 0\n' > "$d/bin/chown"
    chmod +x "$d/bin/"*
}

run() {   # $1 stub dir, $2 lib path, rest: shell to eval after sourcing
    local d="$1" lib="$2"; shift 2
    OSTLER_LG_DIR="$d/guard" OSTLER_LG_PLIST="$d/guard.plist" OSTLER_LG_PFCTL="$d/bin/pfctl" \
    OSTLER_LG_SYSCTL="$d/bin/sysctl" OSTLER_LG_LAUNCHCTL="$d/bin/launchctl" OSTLER_LG_SUDO="$d/bin/sudo" \
    OSTLER_LG_CHOWN="$d/bin/chown" OSTLER_LG_EUID=0 \
    /bin/bash -c "source '$lib'; $*"
}
OWNER=501
st() { sed -n "s/^$2=//p" "$1/guard/status" | tail -1; }

# 1. happy path
D="$T/happy"; mkstubs "$D"; echo $OWNER > "$D/guard/owner_uid"
out="$(run "$D" "$LIB" ostler_lg_apply)"; rc=$?
[ $rc = 0 ] && [ "$(st "$D" verdict)" = ok ] && [ "$(st "$D" rules_loaded)" = 4 ] && [ "$(st "$D" pf_enabled)" = yes ] \
  && ok "apply: verdict ok, 4 rules, pf enabled" || bad "apply happy path rc=$rc out=$out status=$(cat "$D/guard/status")"
[ "$(st "$D" probe_other_11434)" = timeout ] && [ "$(st "$D" probe_owner_11434)" = refused ] \
  && [ "$(st "$D" probe_other_runner_65531)" = timeout ] && [ "$(st "$D" probe_owner_runner_65531)" = refused ] \
  && [ "$(st "$D" probe_other_control_9)" = refused ] \
  && ok "selftest: other account dropped on 11434 and runner range, owner reaches both, control refused" || bad "selftest fields: $(cat "$D/guard/status")"
grep -q 'token=4242' "$D/guard/pf.token" && ok "pf reference token recorded with boot time" || bad "token file: $(cat "$D/guard/pf.token" 2>&1)"
# second apply in the same boot must NOT take another pf reference
run "$D" "$LIB" ostler_lg_apply >/dev/null
[ "$(grep -c 'pfctl -E' "$D/pf/calls")" = 1 ] && ok "re-apply in the same boot takes no second pf reference" || bad "pfctl -E called $(grep -c 'pfctl -E' "$D/pf/calls") times"

# 2. RED CONTROL: no guard at all (anchor never loaded) -> other account reaches 11434
D="$T/nogate"; mkstubs "$D"; echo $OWNER > "$D/guard/owner_uid"; touch "$D/pf/ignore_load"
run "$D" "$LIB" ostler_lg_apply >/dev/null; rc=$?
[ $rc != 0 ] && [ "$(st "$D" verdict)" = fail ] && case "$(st "$D" reason)" in anchor_rules_mismatch*) true ;; *) false ;; esac \
  && ok "RED control: anchor not loaded -> verdict fail (anchor_rules_mismatch)" || bad "no-guard control: rc=$rc $(cat "$D/guard/status")"
# the same control with the count check bypassed must still be caught by the self-test
D="$T/nogate2"; mkstubs "$D"; echo $OWNER > "$D/guard/owner_uid"
sed 's/^LG_RULE_COUNT=4$/LG_RULE_COUNT=0/' "$LIB" > "$T/lib_count0.sh"; touch "$D/pf/ignore_load"
run "$D" "$T/lib_count0.sh" ostler_lg_apply >/dev/null
case "$(st "$D" reason)" in other_account_reaches_11434*) ok "RED control: with the count check blinded, the self-test still fails (other account reaches 11434)" ;; *) bad "self-test did not catch an empty anchor: $(cat "$D/guard/status")" ;; esac

# 3. pf cannot be enabled / anchor load fails -> fail closed
D="$T/noE"; mkstubs "$D"; echo $OWNER > "$D/guard/owner_uid"; touch "$D/pf/fail_E"
run "$D" "$LIB" ostler_lg_apply >/dev/null
[ "$(st "$D" reason)" = pf_enable_failed ] && ok "pf enable failure -> verdict fail (pf_enable_failed)" || bad "pf -E failure: $(cat "$D/guard/status")"
D="$T/noload"; mkstubs "$D"; echo $OWNER > "$D/guard/owner_uid"; touch "$D/pf/fail_load"
run "$D" "$LIB" ostler_lg_apply >/dev/null
[ "$(st "$D" reason)" = anchor_load_failed ] && ok "anchor load failure -> verdict fail" || bad "load failure: $(cat "$D/guard/status")"
D="$T/noowner"; mkstubs "$D"
run "$D" "$LIB" ostler_lg_apply >/dev/null
[ "$(st "$D" reason)" = owner_uid_missing_or_invalid ] && ok "missing owner uid -> verdict fail" || bad "no owner: $(cat "$D/guard/status")"

# 4. the self-test refuses to grade when its control cannot be refused
D="$T/ctl"; mkstubs "$D"; echo $OWNER > "$D/guard/owner_uid"; touch "$D/pf/control_times_out"
run "$D" "$LIB" ostler_lg_apply >/dev/null
case "$(st "$D" reason)" in selftest_control_not_refused*) ok "control port timing out -> CANNOT grade, verdict fail" ;; *) bad "control: $(cat "$D/guard/status")" ;; esac

# 5. MUTANTS of the rule text. Each must turn the verdict red.
mutant() {   # $1 name, $2 sed expression, $3 expected reason prefix
    local m="$T/mut_$1.sh" d="$T/mutd_$1"
    sed "$2" "$LIB" > "$m"
    if cmp -s "$m" "$LIB"; then bad "mutant $1 DID NOT APPLY (sed matched nothing)"; return; fi
    mkstubs "$d"; echo $OWNER > "$d/guard/owner_uid"
    run "$d" "$m" ostler_lg_apply >/dev/null
    case "$(st "$d" reason)" in "$3"*) ok "mutant $1 caught ($(st "$d" reason))" ;; *) bad "mutant $1 survived: $(cat "$d/guard/status")" ;; esac
}
mutant drop_range_block '/^block drop out quick on lo0 proto tcp from any to any port \${first}:\${last}/s/^block drop/pass/' other_account_reaches_runner_range
mutant drop_fixed_block '/^block drop out quick on lo0 proto tcp from any to any port \${LG_FIXED_PORT}/s/^block drop/pass/' other_account_reaches_11434
mutant owner_not_passed 's/user { \${owner}, 0 }/user { 0 }/g' owner_blocked_on_11434
mutant everyone_passed 's/user { \${owner}, 0 } no state/no state/g' other_account_reaches_11434
mutant wrong_range 's/port \${first}:\${last}/port 1024:2048/g' other_account_reaches_runner_range

# 6. owner-side check
D="$T/chk"; mkstubs "$D"; echo "$(id -u)" > "$D/guard/owner_uid"; run "$D" "$LIB" ostler_lg_apply >/dev/null; touch "$D/guard.plist"
r="$(run "$D" "$LIB" ostler_lg_check)"; [ "$r" = ok ] && ok "check: fresh ok verdict for this account -> ok" || bad "check fresh: $r"
sed -i.bak 's/^checked_at=.*/checked_at=1000/' "$D/guard/status"
r="$(run "$D" "$LIB" ostler_lg_check)"; case "$r" in status_stale*) ok "check: stale status -> not ok ($r)" ;; *) bad "check stale: $r" ;; esac
run "$D" "$LIB" ostler_lg_apply >/dev/null; rm -f "$D/guard.plist"
r="$(run "$D" "$LIB" ostler_lg_check)"; [ "$r" = daemon_not_installed ] && ok "check: no daemon plist -> not ok" || bad "check no plist: $r"
D="$T/chk2"; mkstubs "$D"; echo 777 > "$D/guard/owner_uid"; run "$D" "$LIB" ostler_lg_apply >/dev/null; touch "$D/guard.plist"
r="$(run "$D" "$LIB" ostler_lg_check)"; [ "$r" = guard_owner_is_another_account ] && ok "check: guard owned by another uid -> not ok" || bad "check other owner: $r"

# 7. upgrade path: never prompts, records needs-admin, clears it when ok
D="$T/upg"; mkstubs "$D"; mkdir -p "$D/ostler"
r="$(run "$D" "$LIB" "ostler_lg_upgrade_check '$D/ostler' '$LIB'")"; rc=$?
[ $rc != 0 ] && grep -q '^reason=daemon_not_installed' "$D/ostler/state/loopback_guard_needs_admin" && grep -q '^fix=/bin/bash .*install-root' "$D/ostler/state/loopback_guard_needs_admin" \
  && ok "upgrade: guard missing -> needs-admin marker with the fix command" || bad "upgrade missing: rc=$rc $r"
cmp -s "$LIB" "$D/ostler/lib/ostler-loopback-guard.sh" && ok "upgrade: payload lib copied to ~/.ostler/lib for the Hub's fix" || bad "upgrade lib copy"
echo "$(id -u)" > "$D/guard/owner_uid"; cp "$LIB" "$D/guard/ostler-loopback-guard.sh"; run "$D" "$LIB" ostler_lg_apply >/dev/null; touch "$D/guard.plist"
run "$D" "$LIB" "ostler_lg_upgrade_check '$D/ostler' '$LIB'" >/dev/null && [ ! -e "$D/ostler/state/loopback_guard_needs_admin" ] \
  && ok "upgrade: active guard -> marker cleared" || bad "upgrade ok path"
echo "# changed" >> "$D/guard/ostler-loopback-guard.sh"
run "$D" "$LIB" "ostler_lg_upgrade_check '$D/ostler' '$LIB'" >/dev/null; grep -q '^reason=guard_outdated' "$D/ostler/state/loopback_guard_needs_admin" \
  && ok "upgrade: root copy differs from payload -> guard_outdated" || bad "upgrade outdated: $(cat "$D/ostler/state/loopback_guard_needs_admin" 2>&1)"

# 8. remove: flush, release, delete; a rule left behind is an error, not a pass
D="$T/rm"; mkstubs "$D"; echo $OWNER > "$D/guard/owner_uid"; run "$D" "$LIB" ostler_lg_apply >/dev/null; touch "$D/guard.plist"
run "$D" "$LIB" ostler_lg_remove >/dev/null; rc=$?
[ $rc = 0 ] && [ ! -s "$D/pf/anchor" ] && grep -q 'pfctl -X 4242' "$D/pf/calls" && [ ! -e "$D/guard" ] && [ ! -e "$D/guard.plist" ] \
  && grep -q 'launchctl bootout system/com.ostler.loopback-guard' "$D/pf/calls" \
  && ok "remove: daemon booted out, anchor flushed, pf reference released, files gone" || bad "remove rc=$rc calls=$(cat "$D/pf/calls")"
D="$T/rm2"; mkstubs "$D"; echo $OWNER > "$D/guard/owner_uid"; run "$D" "$LIB" ostler_lg_apply >/dev/null; touch "$D/pf/ignore_flush"
run "$D" "$LIB" ostler_lg_remove >/dev/null 2>&1; [ $? = 1 ] && ok "remove: anchor that will not flush -> rc 1 (loud)" || bad "remove ignore_flush"

# 9. install-root: refuses non-root and root owner; writes plist + bootstraps
D="$T/inst"; mkstubs "$D"
OSTLER_LG_EUID=501 OSTLER_LG_DIR="$D/guard" /bin/bash "$LIB" install-root 501 "$LIB" >/dev/null 2>&1; [ $? = 2 ] && ok "install-root refuses a non-root caller" || bad "install-root non-root"
run "$D" "$LIB" "ostler_lg_install_root 0 '$LIB'" >/dev/null 2>&1; [ $? = 2 ] && ok "install-root refuses owner uid 0" || bad "install-root uid 0"
run "$D" "$LIB" "ostler_lg_install_root $OWNER '$LIB'" >/dev/null; rc=$?
[ $rc = 0 ] && /usr/bin/plutil -lint "$D/guard.plist" >/dev/null && grep -q 'launchctl bootstrap system' "$D/pf/calls" \
  && cmp -s "$LIB" "$D/guard/ostler-loopback-guard.sh" && [ "$(st "$D" verdict)" = ok ] \
  && ok "install-root: root copy, valid plist, daemon bootstrapped, verdict ok" || bad "install-root rc=$rc"

# 10. owner notification on ok -> fail only, not on every failing tick
D="$T/note"; mkstubs "$D"; echo $OWNER > "$D/guard/owner_uid"; run "$D" "$LIB" ostler_lg_apply >/dev/null
touch "$D/pf/fail_load"; run "$D" "$LIB" ostler_lg_apply >/dev/null; run "$D" "$LIB" ostler_lg_apply >/dev/null
[ "$(grep -c 'launchctl asuser 501 /usr/bin/osascript' "$D/pf/calls")" = 1 ] && ok "owner notified once on ok->fail" || bad "notify count $(grep -c asuser "$D/pf/calls")"

# 11. ~/.ollama tightened
mkdir -p "$T/home/.ollama"; chmod 0755 "$T/home/.ollama"
run "$T/happy" "$LIB" "ostler_lg_tighten_ollama_dir '$T/home/.ollama'"
[ "$(stat -f %Lp "$T/home/.ollama")" = 700 ] && ok "~/.ollama tightened to 0700" || bad "ollama dir mode $(stat -f %Lp "$T/home/.ollama")"

# 12. rules refuse bad input
for a in "0 49152 65535" "501 80 65535" "501 60000 50000" "x 1 2"; do
  /bin/bash "$LIB" rules $a >/dev/null 2>&1; [ $? = 2 ] || bad "rules accepted '$a'"
done; ok "rules refuse root owner, low range, inverted range, non-numeric"

echo "loopback-guard: ${PASS} pass, ${FAIL} fail"
[ "$FAIL" = 0 ]
