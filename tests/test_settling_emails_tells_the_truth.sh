#!/usr/bin/env bash
# test_settling_emails_tells_the_truth.sh
#
# Walk #16 console (Andy): the settling panel said "Mail: nothing found" while
# the hourly mail agent had read 12,339 emails. Measured on the box: the
# install-time 90-day pass read 31 messages (all automated senders), named
# nobody, and wrote emails.json done=0 needs_source=true OVER the real count;
# the hourly agent never wrote emails.json at all.
#
# Arms:
#   1  the shell writer keeps done monotonic: 12339 then a later 0 -> 12339
#   2  a channel that has counted work is never "needs a source"
#   3  install.sh's email leg: 31 read, 0 people -> reports 31, not needs_source
#   4  the hourly tick reports CUMULATIVE progress: 3 then 3 more -> done 6
#   5  control: a genuinely empty first report still says needs_source
# Red on main: arms 1, 2, 3 and 4.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

read_field() {  # file field
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d.get(sys.argv[2])))' "$1" "$2" 2>/dev/null
}

# ---- arms 1, 2, 5: the shell writer ----------------------------------------
(
    export HOME="$WORK/h1"; mkdir -p "$HOME"
    export OSTLER_STATE_DIR="$HOME/.ostler/state"
    # shellcheck source=/dev/null
    . "$ROOT/lib/settling_progress.sh"
    settling_report emails 0 0 true
) >/dev/null 2>&1
f5="$(find "$WORK/h1" -name emails.json | head -1)"
if [ -n "$f5" ] && [ "$(read_field "$f5" needs_source)" = "true" ]; then
    pass "control: a first, empty report still invites a source"
else
    fail "control: a first, empty report should say needs_source (file=${f5:-none})"
fi

(
    export HOME="$WORK/h2"; mkdir -p "$HOME"
    # shellcheck source=/dev/null
    . "$ROOT/lib/settling_progress.sh"
    settling_report emails 12339 20000 false
    settling_report emails 0 0 true
) >/dev/null 2>&1
f1="$(find "$WORK/h2" -name emails.json | head -1)"
if [ -z "$f1" ]; then
    fail "writer wrote no emails.json at all"
else
    d="$(read_field "$f1" done)"; n="$(read_field "$f1" needs_source)"
    [ "$d" = "12339" ] && pass "done stays 12339 after a later 0" || fail "done walked back to $d (want 12339)"
    [ "$n" = "false" ] && pass "counted work is never 'needs a source'" || fail "needs_source=$n after 12339 done (want false)"
fi

# ---- arm 3: install.sh's own email-leg branch ------------------------------
BLOCK="$(awk '
    /_HYDRATE_EMAIL_COUNT="\$\{_HYDRATE_EMAIL_COUNTS%% \*\}"/ { s=1 }
    s { print }
    s && /_HYDRATE_EMAIL_OUTCOME="no_correspondents_in_window"/ { z=1 }
    z && /^        fi$/ { exit }
' "$ROOT/install.sh")"
case "$BLOCK" in
    *no_correspondents_in_window*) : ;;
    *) fail "could not extract install.sh's email-leg branch"; BLOCK="" ;;
esac
if [ -n "$BLOCK" ]; then
    got="$(
        _HYDRATE_EMAIL_COUNTS="0 31"; MSG_HYDRATE_EMAIL_SKIPPED_NO_MAIL_CONTENT=x; MSG_HYDRATE_EMAIL_DONE=x
        info() { :; }; ok() { :; }
        _hydrate_sentinel_record_no_data() { :; }
        settling_report_measured() { printf 'measured:%s:%s' "$2" "$3"; }
        settling_report() { printf 'report:%s:%s:%s' "$2" "$3" "$4"; }
        eval "$BLOCK"
    )"
    [ "$got" = "measured:31:false" ] \
        && pass "install leg: 31 read, 0 people -> reports 31 read" \
        || fail "install leg: 31 read, 0 people -> '$got' (want measured:31:false)"
fi

# ---- arm 4: the hourly tick, run for real with its two externals stubbed ---
H="$WORK/h4"; mkdir -p "$H/Library/Mail/V10/acct" "$H/py/ostler_fda" "$H/.ostler"
for i in 1 2 3 4 5; do : > "$H/Library/Mail/V10/acct/$i.emlx"; done
cp "$ROOT/vendor/ostler_fda/settling_progress.py" "$H/py/ostler_fda/"
: > "$H/py/ostler_fda/__init__.py"
cat > "$H/py/ostler_fda/apple_mail_mbox.py" <<'PY'
import sys
out = sys.argv[sys.argv.index("--emit-mbox") + 1]
with open(out, "w") as fh:
    for i in range(3):
        fh.write("From sender@example.com Thu Oct  9 10:00:00 2026\nSubject: t%d\n\nbody\n\n" % i)
PY
for tick in 1 2; do
    HOME="$H" OSTLER_DIR="$H/.ostler" PYTHONPATH="$H/py" PWG_EMAIL_INGEST=/usr/bin/true \
        OSTLER_MARK_FIRST_INGEST=/nonexistent \
        bash "$ROOT/vendor/email_ingest/bin/email-ingest-tick.sh" >"$WORK/tick$tick.log" 2>&1 \
        || fail "tick $tick exited non-zero: $(tail -2 "$WORK/tick$tick.log")"
    rm -f "$H/.ostler/imports/email/"*.mbox.txt
    sleep 1
done
f4="$H/.ostler/state/settling_progress.d/emails.json"
if [ -f "$f4" ]; then
    d="$(read_field "$f4" done)"; n="$(read_field "$f4" needs_source)"
    [ "$d" = "6" ] && pass "two hourly ticks of 3 -> done 6" || fail "two hourly ticks of 3 -> done $d (want 6)"
    [ "$n" = "false" ] && pass "the hourly tick never says needs_source" || fail "hourly tick needs_source=$n"
else
    fail "the hourly tick wrote no emails.json (the walk #16 defect)"
fi

echo "denominator: 5 arms (writer x3, install.sh branch, real tick x2)"
[ "$fails" -eq 0 ] || exit 1
exit 0
