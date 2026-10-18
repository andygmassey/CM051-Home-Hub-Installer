#!/usr/bin/env bash
#
# tests/test_assistant_mailbox_installer.sh  (v1.0.108)
#
# The assistant's OWN mailbox: host rules, guards, and "the secret never lands
# in config or logs". Behaviour is exercised on the helper block and the flow
# function extracted from install.sh, with a fake probe so nothing touches the
# network. Every structural assertion is also run on a mutant with the old or
# broken behaviour restored, and must FAIL there, so each check is known to be
# able to go red. All addresses are synthetic (example.test).
#
# Exit 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Provider domains the host rules key on, composed at runtime so no literal
# address at a real provider sits in this PUBLIC repo (ci-pii-shape-scan).
IC="icloud.com"; MC="me.com"; GM="gmail.com"
INSTALL_SH="${REPO_ROOT}/install.sh"
[ -f "$INSTALL_SH" ] || { echo "CANNOT-RUN: install.sh not found"; exit 2; }
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
pass() { echo "ok:   $*"; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

extract() { # <install.sh path> <out>
    sed -n '/^# BEGIN assistant-mailbox-helpers/,/^# END assistant-mailbox-helpers/p' "$1" > "$2"
    sed -n '/^_assistant_mailbox_flow() {/,/^}/p' "$1" >> "$2"
}
extract "$INSTALL_SH" "$tmp/real.sh"
n="$(wc -l < "$tmp/real.sh" | tr -d ' ')"
[ "$n" -gt 80 ] || { echo "FAIL: assistant-mailbox helpers not found in install.sh ($n lines)"; exit 1; }
echo "examined: helper block + flow, $n lines"

# ---- 1. host rules ----------------------------------------------------------
cat > "$tmp/rules.sh" <<'R'
IC="icloud.com"; MC="me.com"; GM="gmail.com"
chk() { local want="$1"; shift; "$@" && got=0 || got=1; [ "$got" = "$want" ] && echo ok || echo "BAD:$*"; }
chk 0 _am_host_pair_allowed imap.gmail.com 993 smtp.gmail.com 465
chk 0 _am_host_pair_allowed imap.mail.me.com 993 smtp.mail.me.com 587
chk 0 _am_host_pair_allowed IMAP.Gmail.com 993 smtp.gmail.com 465
chk 1 _am_host_pair_allowed imap-mail.outlook.com 993 smtp-mail.outlook.com 587
chk 1 _am_host_pair_allowed outlook.office365.com 993 smtp.office365.com 587
chk 1 _am_host_pair_allowed imap.example.test 993 smtp.example.test 587
chk 1 _am_host_pair_allowed imap.gmail.com 993 smtp.gmail.com 587
chk 1 _am_host_pair_allowed imap.mail.me.com 993 smtp.mail.me.com 465
chk 1 _am_host_pair_allowed imap.gmail.com 993 smtp.mail.me.com 587
chk 0 _am_address_ok icloud "new.assistant@${IC}"
chk 0 _am_address_ok icloud "new.assistant@${MC}"
chk 0 _am_address_ok gmail "new.assistant@GMAIL.${GM#gmail.}"
chk 1 _am_address_ok gmail "new.assistant@${IC}"
chk 1 _am_address_ok icloud "new.assistant@example.test"
chk 1 _am_address_ok icloud "not an address"
chk 0 _am_is_owner_address "OWNER@example.test" "x@example.test, owner@example.test"
chk 1 _am_is_owner_address "new@${IC}" "owner@example.test,"
chk 1 _am_is_owner_address "new@${IC}" ""
chk 0 _am_gmail_identity_ok "a@${GM}" "A@${GM}"
chk 1 _am_gmail_identity_ok "a@${GM}" "b@${GM}"
chk 0 _am_password_shape_ok "abcd-efgh-ijkl-mnop"
chk 0 _am_password_shape_ok "ABCD EFGH IJKL MNOP"
chk 1 _am_password_shape_ok "abcd-efgh-ijkl"
chk 1 _am_password_shape_ok "a-real-account-password-1!"
chk 1 _am_inbox_looks_real 200 14
chk 0 _am_inbox_looks_real 201 0
chk 0 _am_inbox_looks_real 3 15
chk 1 _am_inbox_looks_real 0 ""
chk 1 _am_inbox_looks_real 5 ""
[ "$(_am_clean_password 'Abcd-Efgh ijkl_mnop')" = "abcdefghijkl_mnop" ] && echo ok || echo "BAD:clean"
R
rules() { bash -c ". '$1'; . '$tmp/rules.sh'" 2>&1; }
out="$(rules "$tmp/real.sh")"
bad="$(grep -c '^BAD' <<< "$out" || true)"
okn="$(grep -c '^ok' <<< "$out" || true)"
badlist="$(grep '^BAD' <<< "$out" || true)"
[ "$bad" = 0 ] && [ -n "$out" ] && pass "host rules, address, owner, gmail, password and inbox guards ($okn checks)" \
    || fail "rules: $badlist"

# mutants: each broken rule must be caught
mut() { # <label> <sed expr>
    sed "$2" "$tmp/real.sh" > "$tmp/mut.sh"
    if cmp -s "$tmp/real.sh" "$tmp/mut.sh"; then fail "mutant '$1' did not change the file"; return; fi
    o="$(rules "$tmp/mut.sh")"
    if grep -q '^BAD' <<< "$o"; then pass "mutant caught: $1"; else fail "mutant NOT caught: $1"; fi
}
mut "outlook accepted"        's#imap.mail.me.com:993\\|smtp.mail.me.com:587) return 0 ;;#imap.mail.me.com:993\\|smtp.mail.me.com:587|imap-mail.outlook.com:993\\|smtp-mail.outlook.com:587) return 0 ;;#'
mut "owner address allowed"   's#if \[\[ -n "\$o" \&\& "\$o" == "\$a" \]\]; then IFS="\$_old_ifs"; return 0; fi#:#'
mut "inbox limit 200 -> 2000" 's#(( n > 200 ))#(( n > 2000 ))#'
mut "age limit 14 -> 140"     's#(( d > 14 ))#(( d > 140 ))#'
mut "gmail identity ignored"  's#^_am_gmail_identity_ok() .*#_am_gmail_identity_ok() { return 0; }#'

# ---- 2. the config block never holds a password ------------------------------
cat > "$tmp/emit.sh" <<'R'
IC="icloud.com"; MC="me.com"; GM="gmail.com"
_am_emit_config "Assistant.Test@iCloud.${IC#icloud.}" icloud
R
blk="$(bash -c ". '$tmp/real.sh'; . '$tmp/emit.sh'")"
for k in 'enabled = true' 'address = "assistant.test@'"$IC"'"' 'provider = "icloud"' \
         'imap_host = "imap.mail.me.com"' 'imap_port = 993' 'smtp_host = "smtp.mail.me.com"' \
         'smtp_port = 587' 'secret_ref = "keychain:Ostler Assistant Mailbox:assistant.test@'"$IC"'"' \
         'owner_addresses_verified = []'; do
    grep -qxF "$k" <<< "$blk" && pass "config has: $k" || fail "config missing: $k"
done
if grep -qiE 'password|passwd|app_pass' <<< "$blk"; then fail "config block mentions a password"; else pass "config block has no password key"; fi
blk_gm="$(bash -c ". '$tmp/real.sh'; _am_emit_config x@${GM} gmail")"
grep -qxF 'smtp_port = 465' <<< "$blk_gm" && pass "gmail smtp 465" || fail "gmail smtp port"

# ---- 3. the flow: fake probe, fake gui_read, secret never leaks -------------
SECRET="abcdefghijklmnop"
cat > "$tmp/probe.py" <<'P'
import os, sys
mode = sys.argv[1]
log = os.environ["FAKE_LOG"]
open(log, "a").write(f"{mode} pw_in_env={'yes' if os.environ.get('AM_PASSWORD') else 'no'} argv={sys.argv[1:]}\n")
st = os.environ.get("FAKE_STATE", "good")
if mode == "probe":
    if st == "bad":
        print("imap=wrong_password"); print("smtp=wrong_password"); print("inbox_count=0"); print("oldest_days=")
    elif st == "real":
        print("imap=ok"); print("smtp=ok"); print("inbox_count=500"); print("oldest_days=90")
    else:
        print("imap=ok"); print("smtp=ok"); print("inbox_count=0"); print("oldest_days=")
elif mode == "explain":
    print("The password was not accepted. Use the app password you just made, not your Apple ID or Google password.")
elif mode == "store":
    print("result=ok")
elif mode == "selftest":
    print("result=" + os.environ.get("FAKE_SELFTEST", "ok"))
elif mode == "hello":
    print("result=ok")
    print("message_id=<hello-test@example.test>")
P
cat > "$tmp/drive.sh" <<'D'
set -uo pipefail
ok() { echo "[ok] $*"; }; warn() { echo "[warn] $*"; }; info() { echo "[info] $*"; }
for f in $(sed -n 's/^\(MSG_[A-Z_0-9]*\)=.*/\1/p' "$STRINGS" | grep '_AM_'); do :; done
. "$STRINGS"
ASSISTANT_NAME="Tess"; USER_EMAIL="${OWNER:-owner@example.test}"; CHANNEL_EMAIL_ALLOWED_SENDERS="${OWNER:-owner@example.test}"
ASSISTANT_MAILBOX_ENABLED=false; ASSISTANT_MAILBOX_ADDRESS=""; ASSISTANT_MAILBOX_PROVIDER=""; ASSISTANT_MAILBOX_SELFTEST=""; ASSISTANT_MAILBOX_HELLO_ID=""
CHANNEL_EMAIL_USERNAME=""; SCRIPT_DIR="/nonexistent"
export OSTLER_AM_PROBE="$PROBE" OSTLER_AM_PYTHON="$PY" FAKE_LOG
ANS="$ANSWERS"
gui_read() { # title kind default help choices id [error]
    local id="$6" a
    a="$(printf '%s\n' "$ANS" | sed -n "s/^$id=//p" | head -n 1)"
    echo "PROMPT $id" >> "$FAKE_LOG"
    [[ -z "$a" && "$2" == yesno ]] && a="${3:-N}"
    [[ -z "$a" && "$2" == acknowledge ]] && a="OK"
    [[ -z "$a" && "$2" == choice ]] && a="$3"   # the step's own default, as gui_read gives it
    printf '%s' "$a"
}
. "$HELPERS"
_assistant_mailbox_flow
echo "ENABLED=$ASSISTANT_MAILBOX_ENABLED ADDRESS=$ASSISTANT_MAILBOX_ADDRESS PROVIDER=$ASSISTANT_MAILBOX_PROVIDER"
echo "HELLO_ID=$ASSISTANT_MAILBOX_HELLO_ID"
if [[ "$ASSISTANT_MAILBOX_ENABLED" == true ]]; then _am_emit_config "$ASSISTANT_MAILBOX_ADDRESS" "$ASSISTANT_MAILBOX_PROVIDER" "$ASSISTANT_MAILBOX_HELLO_ID"; fi
D
STRINGS="$REPO_ROOT/install.sh.strings.en-GB.sh"
PYBIN="$(command -v python3 || true)"; [ -n "$PYBIN" ] || { echo "CANNOT-RUN: python3"; exit 2; }
run_flow() { # <helpers file> <answers> <state> [selftest]
    : > "$tmp/fake.log"
    STRINGS="$STRINGS" PROBE="$tmp/probe.py" PY="$PYBIN" FAKE_LOG="$tmp/fake.log" HELPERS="$1" ANSWERS="$2" \
    FAKE_STATE="${3:-good}" FAKE_SELFTEST="${4:-ok}" OWNER="${OWNER:-owner@example.test}" bash "$tmp/drive.sh" 2>&1
}
A_OK="am_choose=icloud
am_address=tess.assistant@${IC}
am_password=abcd-efgh-ijkl-mnop"

o="$(run_flow "$tmp/real.sh" "$A_OK")"
grep -q "ENABLED=true ADDRESS=tess.assistant@${IC} PROVIDER=icloud" <<< "$o" && pass "happy path enables the mailbox" || fail "happy path: $o"
leaked=no
grep -q "$SECRET" <<< "$o" && leaked=yes
grep -q "$SECRET" "$tmp/fake.log" && leaked=yes
if [ "$leaked" = yes ]; then fail "the app password appeared in output or in a command line"; else pass "password not in output, log or argv"; fi
grep -q 'pw_in_env=yes' "$tmp/fake.log" && pass "password travels in the environment" || fail "password was not passed to the probe"
grep -q '^store ' "$tmp/fake.log" && pass "stored via the Keychain-backed store step" || fail "no store step"
grep -q '^hello ' "$tmp/fake.log" && pass "hello sent to the owner after a good self-test" || fail "no hello"
grep -q '^HELLO_ID=<hello-test@example.test>$' <<< "$o" && grep -qxF 'hello_message_id = "<hello-test@example.test>"' <<< "$o" \
    && pass "the hello Message-ID is captured and written to the config block" || fail "hello id not recorded: $o"

o="$(run_flow "$tmp/real.sh" "")"
grep -q 'ENABLED=false' <<< "$o" && ! grep -q '^probe' "$tmp/fake.log" && ! grep -q '^store' "$tmp/fake.log" \
    && ! grep -q '^PROMPT am_address' "$tmp/fake.log" \
    && pass "Default answer (nothing chosen) is Skip: the mailbox stays off, nothing probed or stored" || fail "default: $o"
o="$(run_flow "$tmp/real.sh" "am_choose=skip")"
grep -q 'ENABLED=false' <<< "$o" && ! grep -q '^probe' "$tmp/fake.log" && pass "Skip leaves the mailbox off and touches nothing" || fail "skip: $o"

_owner_msg="That is one of your own addresses"
o="$(OWNER=owner@${IC} run_flow "$tmp/real.sh" "am_choose=icloud
am_address=owner@${IC}")"
grep -q 'ENABLED=false' <<< "$o" && grep -q "$_owner_msg" <<< "$o" && ! grep -q '^probe' "$tmp/fake.log" \
    && pass "the owner's own address is refused before any login" || fail "owner address: $o"

o="$(run_flow "$tmp/real.sh" "$A_OK
am_retry=skip" bad)"
grep -q 'ENABLED=false' <<< "$o" && ! grep -q '^store' "$tmp/fake.log" && pass "wrong password then Skip: not stored, install not blocked" || fail "bad password: $o"
grep -q 'not your Apple ID or Google password' <<< "$o" && pass "wrong-password error names the Apple ID/Google mix-up" || fail "error text missing"

o="$(run_flow "$tmp/real.sh" "$A_OK" real)"
grep -q 'ENABLED=false' <<< "$o" && grep -q '^PROMPT am_real_inbox_confirm' "$tmp/fake.log" && ! grep -q '^store' "$tmp/fake.log" \
    && pass "a real-looking inbox needs a second confirm, default No refuses" || fail "real inbox: $o"
o="$(run_flow "$tmp/real.sh" "$A_OK
am_real_inbox_confirm=y" real)"
grep -q 'ENABLED=true' <<< "$o" && pass "a real-looking inbox proceeds once confirmed" || fail "real inbox confirmed: $o"

o="$(run_flow "$tmp/real.sh" "$A_OK
am_test_retry=skip" good timeout)"
grep -q 'ENABLED=true' <<< "$o" && ! grep -q '^hello' "$tmp/fake.log" && pass "failed self-test then Skip: still enabled, no hello, never blocks" || fail "selftest skip: $o"
grep -q '^HELLO_ID=$' <<< "$o" && ! grep -q 'hello_message_id' <<< "$o" && pass "no hello sent: no hello_message_id in config (nobody can be verified)" || fail "hello id without a hello: $o"

# mutant: password logged / put on argv must be caught by the flow check
sed 's#echo "error=unavailable"; return 3; }#echo "error=unavailable"; return 3; }; echo "pw=$AM_PASSWORD" >\&2#' "$tmp/real.sh" > "$tmp/leak.sh"
o="$(run_flow "$tmp/leak.sh" "$A_OK")"
grep -q "$SECRET" <<< "$o" && pass "mutant caught: password leaked to output" || fail "mutant NOT caught: password leak"

# ---- 3b. the golden contract fixture: the writer reproduces it exactly -------
FIXTURE="$REPO_ROOT/tests/fixtures/assistant_mailbox_contract.json"
FIXTURE_SHA256="b9a10daea75b476cdcee2fc7f81df44b5d72dc1042d739fabc8e11d93086c89f"
[ -f "$FIXTURE" ] || { echo "FAIL: contract fixture missing"; exit 1; }
got_sha="$(shasum -a 256 "$FIXTURE" | cut -d' ' -f1)"
[ "$got_sha" = "$FIXTURE_SHA256" ] && pass "contract fixture matches the pinned digest (same bytes as ostler-assistant)" \
    || fail "contract fixture drifted from the pinned copy ($got_sha); sync it with ostler-assistant"
fx() { "${PYBIN:-python3}" -I -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d
for k in sys.argv[2:]: v=v[k]
sys.stdout.write(v)' "$FIXTURE" "$@"; }
want_block="$(fx config_block)"
_fa="$(fx installer_inputs address)"; _fp="$(fx installer_inputs provider)"; _fh="$(fx installer_inputs hello_message_id)"
emit_fx() { bash -c ". '$1'; _am_emit_config '$_fa' '$_fp' '$_fh'" | sed '1{/^$/d;}'; }
[ "$(emit_fx "$tmp/real.sh")" = "$want_block" ] && pass "_am_emit_config output equals the fixture config block byte for byte" \
    || fail "installer writer does not match the contract fixture"
sed 's#echo "hello_message_id = \\"${h}\\""#:#' "$tmp/real.sh" > "$tmp/mut_hello.sh"
if cmp -s "$tmp/real.sh" "$tmp/mut_hello.sh"; then fail "mutant 'hello id not written' did not change the file"
elif [ "$(emit_fx "$tmp/mut_hello.sh")" = "$want_block" ]; then fail "mutant NOT caught: hello_message_id dropped"
else pass "mutant caught: hello_message_id dropped"; fi
bad_id="$(bash -c ". '$tmp/real.sh'; _am_emit_config a@${IC} icloud '<x\"y@example.test>'")"
! grep -q hello_message_id <<< "$bad_id" && pass "a Message-ID with a quote is refused, never written to TOML" || fail "unsafe Message-ID reached the config"

# ---- 4. install.sh structure -------------------------------------------------
check_struct() { # <file> <label-suffix> ; echoes number of failures
    local f="$1" bad=0
    # owner path keeps all four refusals
    grep -q 'imap.gmail.com|imap-mail.outlook.com|outlook.office365.com|imap.mail.me.com)' "$f" || { echo "owner host refusal list changed"; bad=1; }
    # the comment now says owner-only
    grep -q "for a cloud-provider password for the OWNER's mailbox" "$f" || { echo "comment not rewritten"; bad=1; }
    grep -q "assistant-only mailbox" "$f" || { echo "comment does not allow assistant-only app password"; bad=1; }
    # no password key in the assistant config writer, and it is wired
    grep -q '_am_emit_config "$ASSISTANT_MAILBOX_ADDRESS"' "$f" || { echo "config writer not wired"; bad=1; }
    _emit_body="$(awk '/^_am_emit_config\(\)/,/^}/' "$f")"
    grep -qi 'password' <<< "$_emit_body" && { echo "emit_config mentions password"; bad=1; }
    # Keychain store takes the command on stdin, not argv
    grep -q 'security -i' "$REPO_ROOT/vendor/doctor/agent/assistant_mailbox.py" || { echo "store not via security -i"; bad=1; }
    return $bad
}
if res="$(check_struct "$INSTALL_SH")"; then pass "install.sh structure: owner refusals kept, comment rewritten, writer wired"; else fail "install.sh structure: $res"; fi
sed "s#for a cloud-provider password for the OWNER's mailbox#for a cloud-provider password#" "$INSTALL_SH" > "$tmp/mut_install.sh"
if check_struct "$tmp/mut_install.sh" >/dev/null; then fail "mutant NOT caught: old comment"; else pass "mutant caught: old comment"; fi

# the whole install.sh must still parse, and the new strings exist
bash -n "$INSTALL_SH" && pass "install.sh parses" || fail "install.sh does not parse"
for k in MSG_PROMPT_AM_CHOOSE_HELP MSG_PROMPT_AM_DONE_HELP MSG_WARN_AM_ADDRESS_IS_OWNER; do
    grep -q "^$k=" "$STRINGS" && pass "string $k" || fail "string $k missing"
done
if grep -q "Give your assistant its own email address. Create a new account just for your assistant, not your own email. Your assistant can then email you and reply as itself, never as you. Messages go through the provider you choose (Apple or Google), who can read them, not through Ostler. We never see your assistant's mail. The password you paste is a special app password that only works for this account, and it is kept in your Mac's Keychain. You can turn this off or delete the account at any time." "$STRINGS"; then
    pass "consent copy is verbatim"; else fail "consent copy differs"; fi

echo; echo "failures: $fails"
[ "$fails" -eq 0 ] || exit 1
