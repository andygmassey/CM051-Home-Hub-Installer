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
  kern.boottime) echo "{ sec = 1762400000, usec = 0 }" ;;
esac
EOF
    printf '#!/bin/bash\necho "launchctl $*" >> "%s/pf/calls"\nexit 0\n' "$d" > "$d/bin/launchctl"
    printf '#!/bin/bash\nexit 0\n' > "$d/bin/chown"
    # id -u -- <name>: a fixed directory of accounts (names are synthetic).
    cat > "$d/bin/id" <<'EOF'
#!/bin/bash
case "${@: -1}" in
  asst-one) echo 502 ;; owner-one) echo 501 ;; sys-one) echo 70 ;; rooty) echo 0 ;; nobody) echo 4294967294 ;;
  *) echo "id: ${@: -1}: no such user" >&2; exit 1 ;;
esac
EOF
    chmod +x "$d/bin/"*
}

run() {   # $1 stub dir, $2 lib path, rest: shell to eval after sourcing
    local d="$1" lib="$2"; shift 2
    OSTLER_LG_DIR="$d/guard" OSTLER_LG_PLIST="$d/guard.plist" OSTLER_LG_PFCTL="$d/bin/pfctl" \
    OSTLER_LG_SYSCTL="$d/bin/sysctl" OSTLER_LG_LAUNCHCTL="$d/bin/launchctl" OSTLER_LG_SUDO="$d/bin/sudo" \
    OSTLER_LG_CHOWN="$d/bin/chown" OSTLER_LG_ID="$d/bin/id" OSTLER_LG_EUID=0 \
    OSTLER_LG_OWNER_HOME="${LG_TEST_OWNER_HOME:-$d/nohome}" \
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
mutant owner_not_passed 's/^    users="\${owner}, 0"$/    users="0"/' owner_blocked_on_11434
mutant everyone_passed 's/ user { \${users} } no state/ no state/g' other_account_reaches_11434
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

# 7. THE ASSISTANT ACCOUNT (Andy, 2026-11-06): its separate iMessage/WhatsApp
#    identity runs in its own macOS account and must NOT be cut off. Its uid is
#    allowed explicitly; a third uid (nobody) is still refused.
D="$T/asst"; mkstubs "$D"
run "$D" "$LIB" "ostler_lg_install_root $OWNER '$LIB' asst-one" >/dev/null; rc=$?
[ $rc = 0 ] && [ "$(cat "$D/guard/assistant_uid")" = 502 ] && [ "$(st "$D" assistant_uid)" = 502 ] \
  && [ "$(grep -c 'user { 501, 502, 0 } no state' "$D/pf/anchor")" = 2 ] \
  && ok "assistant: install-root resolves asst-one to 502, both pass rules allow { owner, assistant, root }" || bad "assistant install rc=$rc anchor=$(cat "$D/pf/anchor") status=$(cat "$D/guard/status")"
[ "$(st "$D" verdict)" = ok ] && [ "$(st "$D" probe_assistant_11434)" = refused ] && [ "$(st "$D" probe_assistant_runner_65531)" = refused ] \
  && [ "$(st "$D" probe_other_11434)" = timeout ] && [ "$(st "$D" probe_other_runner_65531)" = timeout ] \
  && ok "assistant: assistant uid REACHES 11434 and the runner range, nobody is DROPPED on both, verdict ok" || bad "assistant selftest: $(cat "$D/guard/status")"
# CONTROL: the same install with no assistant configured -> the assistant uid is dropped like any other
D="$T/asst0"; mkstubs "$D"
run "$D" "$LIB" "ostler_lg_install_root $OWNER '$LIB'" >/dev/null
[ ! -e "$D/guard/assistant_uid" ] && [ "$(st "$D" assistant_uid)" = none ] && [ "$(run "$D" "$LIB" "ostler_lg_probe '#502' 11434")" = timeout ] \
  && ok "assistant CONTROL: not configured -> uid 502 is dropped on 11434 (the allow is what lets it through)" || bad "assistant control: $(cat "$D/guard/status")"
# MUTANT: the rule text forgets the assistant -> the self-test goes red
sed 's/users="${owner}, ${asst}, 0"/users="${owner}, 0"/' "$LIB" > "$T/mut_asst.sh"
if cmp -s "$T/mut_asst.sh" "$LIB"; then bad "mutant assistant_dropped DID NOT APPLY"; else
  D="$T/asstm"; mkstubs "$D"; run "$D" "$T/mut_asst.sh" "ostler_lg_install_root $OWNER '$T/mut_asst.sh' asst-one" >/dev/null
  case "$(st "$D" reason)" in assistant_blocked_on_11434*) ok "mutant assistant_dropped caught ($(st "$D" reason))" ;; *) bad "mutant assistant_dropped survived: $(cat "$D/guard/status")" ;; esac
fi
# MUTANT: the self-test never probes the assistant -> the rule mutant above would pass silently
sed -e 's/users="${owner}, ${asst}, 0"/users="${owner}, 0"/' -e 's/selftest "$owner" "$asst")/selftest "$owner")/' "$LIB" > "$T/mut_asst2.sh"
D="$T/asstm2"; mkstubs "$D"; run "$D" "$T/mut_asst2.sh" "ostler_lg_install_root $OWNER '$T/mut_asst2.sh' asst-one" >/dev/null
[ "$(st "$D" verdict)" = ok ] && [ -z "$(st "$D" probe_assistant_11434)" ] \
  && ok "mutant selftest_skips_assistant is visible: verdict ok with no assistant probe (the probe-field check above would go red)" || bad "mutant selftest_skips_assistant: $(cat "$D/guard/status")"
# resolution refuses accounts we must not allow, and the install stops (rc 2)
for bad_name in nobody sys-one rooty owner-one ghost-acct '-u' 'a b'; do
  D="$T/asstbad"; rm -rf "$D"; mkstubs "$D"
  run "$D" "$LIB" "ostler_lg_install_root $OWNER '$LIB' '$bad_name'" >/dev/null 2>&1; rc=$?
  [ $rc = 2 ] && [ ! -e "$D/guard/status" ] || bad "assistant name '$bad_name' accepted (rc=$rc)"
done; ok "assistant: nobody, a system uid, root, the owner, an unknown name and bad names are refused before pf is touched"
# configured in the owner's ~/.ostler/.env (the GUI admin shell passes no name)
D="$T/asstenv"; mkstubs "$D"; mkdir -p "$D/oh/.ostler"; printf 'ASSISTANT_NAME=Sam\nOSTLER_ASSISTANT_MAC_USER=asst-one\n' > "$D/oh/.ostler/.env"
LG_TEST_OWNER_HOME="$D/oh" run "$D" "$LIB" "ostler_lg_install_root $OWNER '$LIB'" >/dev/null
[ "$(st "$D" assistant_uid)" = 502 ] && ok "assistant: read from the owner's ~/.ostler/.env when no name is passed (GUI path)" || bad "assistant .env: $(cat "$D/guard/status" 2>&1)"
# owner-side check: a configured assistant the guard does not allow is NOT ok
D="$T/asstchk"; mkstubs "$D"; echo "$(id -u)" > "$D/guard/owner_uid"; run "$D" "$LIB" ostler_lg_apply >/dev/null; touch "$D/guard.plist"
r="$(OSTLER_ASSISTANT_MAC_USER=asst-one run "$D" "$LIB" ostler_lg_check)"
[ "$r" = "assistant_not_in_guard(asst-one)" ] && ok "check: assistant configured but not in the guard -> not ok ($r)" || bad "check assistant missing: $r"
echo 502 > "$D/guard/assistant_uid"; run "$D" "$LIB" ostler_lg_apply >/dev/null
r="$(OSTLER_ASSISTANT_MAC_USER=asst-one run "$D" "$LIB" ostler_lg_check)"; [ "$r" = ok ] && ok "check: assistant configured and allowed -> ok" || bad "check assistant allowed: $r"
r="$(run "$D" "$LIB" ostler_lg_check)"; [ "$r" = "assistant_not_in_guard(none)" ] && ok "check: guard allows an assistant nobody configured -> not ok ($r)" || bad "check stray assistant: $r"

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
mkdir -p "$T/hm/.ollama"; chmod 0755 "$T/hm/.ollama"
run "$T/happy" "$LIB" "ostler_lg_tighten_ollama_dir '$T/hm/.ollama'"
[ "$(stat -f %Lp "$T/hm/.ollama")" = 700 ] && ok "the .ollama dir tightened to 0700" || bad "ollama dir mode $(stat -f %Lp "$T/hm/.ollama")"

# 12. rules refuse bad input
for a in "0 49152 65535" "501 80 65535" "501 60000 50000" "x 1 2"; do
  /bin/bash "$LIB" rules $a >/dev/null 2>&1; [ $? = 2 ] || bad "rules accepted '$a'"
done; ok "rules refuse root owner, low range, inverted range, non-numeric"

# 13. install.sh step FAILS CLOSED (GUI mode, no guard), and passes on a fresh ok
D="$T/step"; mkstubs "$D"; mkdir -p "$D/ostler" "$D/hm"
step_env() { cat <<EOS
fail_with_code() { echo "FAIL_WITH_CODE \$1 :: \$2"; exit 9; }
ok() { echo "OK \$*"; }; warn() { echo "WARN \$*"; }
MSG_FAIL_LOOPBACK_GUARD_NOT_ACTIVE="guard not active (%s). Details: %s"
OSTLER_DIR='$D/ostler'; INSTALL_LOG='$D/install.log'; OSTLER_GUI=1; HOME='$D/hm'
set -Eeuo pipefail; trap 'echo ERR_TRAP_FIRED' ERR
EOS
}
out="$(run "$D" "$LIB" "$(step_env); ostler_lg_install_step '$LIB'; echo AFTER")"; rc=$?
[ $rc = 9 ] && grep -q 'FAIL_WITH_CODE ERR-08-LOOPBACK-GUARD-NOT-ACTIVE :: guard not active (daemon_not_installed)' \
  <<<"$out" && ! grep -q -e AFTER -e ERR_TRAP_FIRED \
  <<<"$out" && ok "install step: no guard under OSTLER_GUI=1 -> ERR-08-LOOPBACK-GUARD-NOT-ACTIVE, install stops" || bad "install step fail-closed: rc=$rc out=$out"
cmp -s "$LIB" "$D/ostler/lib/ostler-loopback-guard.sh" && ok "install step: lib staged into ~/.ostler/lib (install.sh's fallback copy)" || bad "install step lib copy"
echo "$(id -u)" > "$D/guard/owner_uid"; run "$D" "$LIB" ostler_lg_apply >/dev/null; touch "$D/guard.plist"
out="$(run "$D" "$LIB" "$(step_env); ostler_lg_install_step '$LIB'; echo AFTER")"; rc=$?
[ $rc = 0 ] && grep -q '^OK Local AI engine is private' <<<"$out" && grep -q AFTER <<<"$out" && ! grep -q ERR_TRAP_FIRED \
  <<<"$out" && grep -q '^loopback_guard=ok' "$D/install.log" && ok "install step: fresh ok -> continues, ERR trap restored and silent, logged" || bad "install step ok: rc=$rc out=$out"

# 13b. MUTANT: the step warns instead of failing closed -> 13 must go red
sed 's/^    fail_with_code "ERR-08-LOOPBACK-GUARD-NOT-ACTIVE"/    warn "ERR-08-LOOPBACK-GUARD-NOT-ACTIVE"/' "$LIB" > "$T/mut_step.sh"
if cmp -s "$T/mut_step.sh" "$LIB"; then bad "mutant warn_not_fail DID NOT APPLY"; else
  D="$T/stepm"; mkstubs "$D"; mkdir -p "$D/ostler" "$D/hm"
  out="$(run "$D" "$T/mut_step.sh" "$(step_env | sed "s|$T/step|$D|g"); ostler_lg_install_step '$T/mut_step.sh'; echo AFTER")"
  grep -q AFTER <<<"$out" && ok "mutant warn_not_fail is visible: install continued (the fail-closed check above would go red)" || bad "mutant warn_not_fail: $out"
fi

# 14. WIRING (static): every consumer of the guard is present where it must run.
I="${HERE}/install.sh"
pin="$(grep -n 'fail_with_code "ERR-07-OLLAMA-AGENT-NOT-PINNED"' "$I" | head -1 | cut -d: -f1)"
stp="$(grep -n 'ostler_lg_install_step "\$_lg_lib"' "$I" | head -1 | cut -d: -f1)"
rot="$(grep -n '^# ── 3.3b Ollama log rotation' "$I" | head -1 | cut -d: -f1)"
[ -n "$pin" ] && [ -n "$stp" ] && [ -n "$rot" ] && [ "$pin" -lt "$stp" ] && [ "$stp" -lt "$rot" ] \
  && ok "install.sh runs the guard step after Ollama is pinned and before log rotation (:$stp)" || bad "install step placement pin=$pin step=$stp rot=$rot"
ue="$(awk '/<<.UNINSTALLEOF.$/{a=NR} /^UNINSTALLEOF$/{if(a&&!b)b=NR} END{print a, b}' "$I")"
ur="$(grep -n 'sudo /bin/bash "\$_lg_root" remove' "$I" | head -1 | cut -d: -f1)"
[ -n "$ur" ] && [ "$ur" -gt "${ue% *}" ] && [ "$ur" -lt "${ue#* }" ] && ok "the uninstaller (inside its heredoc) removes the guard" || bad "uninstall wiring ur=$ur heredoc=$ue"
# NO UPDATE-TIME PROMPT (Andy, 2026-11-06): the update path must not touch the guard at all.
upg_a="$(grep -n 'OSTLER_UPGRADE_MODE:-0}" == "1"' "$I" | head -1 | cut -d: -f1)"
upg_b="$(grep -n '# (7) Write VERSION last' "$I" | head -1 | cut -d: -f1)"
[ -n "$upg_a" ] && [ -n "$upg_b" ] && [ "$upg_a" -lt "$upg_b" ] && ! sed -n "${upg_a},${upg_b}p" "$I" | grep -q -i -e loopback -e ostler_lg_ \
  && ! grep -q -e 'ostler_lg_upgrade_check' -e 'needs_admin' "$LIB" \
  && ok "the update path (install.sh:${upg_a}-${upg_b}) never touches the guard; no needs-admin marker exists" || bad "update path references the guard (lines ${upg_a}-${upg_b})"
grep -q 'install-root "$(id -u)" "$lib" "$(ostler_lg_configured_assistant "$(id -u)")"' "$LIB" && ok "the CLI install passes the configured assistant account to install-root" || bad "CLI assistant wiring"
AH="${HERE}/gui/OstlerInstaller/Auth/AuthorizationHelper.swift"
grep -q '/lib/ostler-loopback-guard.sh' "$AH" && grep -q '" install-root $(/usr/bin/id -u $ORIG_USER) "' "$AH" && grep -q 'let innerShell = buildAdminInnerShell(resourcePath: Bundle.main.resourcePath)' "$AH" && ok "the GUI admin shell installs the guard" || bad "GUI wiring"
grep -q 'lib/ostler-loopback-guard.sh"  "${DEST}/lib/ostler-loopback-guard.sh"' "${HERE}/gui/project.yml" && ok "the lib is bundled into the .app" || bad "bundling"
n="$(grep -l '^MSG_FAIL_LOOPBACK_GUARD_NOT_ACTIVE=' "${HERE}"/install.sh.strings.*.sh | wc -l | tr -d ' ')"; t="$(ls "${HERE}"/install.sh.strings.*.sh | wc -l | tr -d ' ')"
[ "$n" = "$t" ] && [ "$t" -gt 0 ] && ok "fail message present in all ${t} catalogues" || bad "fail message in ${n}/${t} catalogues"

echo "loopback-guard: ${PASS} pass, ${FAIL} fail"
[ "$FAIL" = 0 ]
