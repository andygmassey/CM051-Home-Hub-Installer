#!/usr/bin/env bash
#
# tests/test_owner_name_id_never_empty.sh
#
# THE DEFECT (measured on a v1.0.121 trial box). With Contacts denied, the name
# prompt (user_name) and the id prompt (user_id) both took an EMPTY answer.
# DEFAULT_ID derives from the empty name, so USER_ID stayed empty, and the
# install died five steps later at encrypt_db:
#     USER_ID: USER_ID must be set before consent recording
# from the ${USER_ID:?} inside _consent_cli_record (ERR-99-INSTALL-ABORT).
#
# THE CONTRACT this pins, by RUNNING the real prompt block out of install.sh
# (from "# -- 1. Confirm name" to "# -- 2. Confirm country code") with the real
# gui_read (lib/progress_emitter.sh), the real warn/fail/fail_with_code, the
# real English catalogue, and then the real _consent_cli_record:
#   1. empty name + empty id, Contacts empty, no TTY: REFUSES at the prompt
#      with ERR-03-OWNER-NAME-EMPTY and NEVER reaches _consent_cli_record
#      (RED on main: it reaches it and dies on the ${USER_ID:?}).
#   2. a whitespace-only name is empty too; an empty id with no TTY refuses
#      with ERR-03-OWNER-ID-EMPTY.
#   3. GUI path: an empty name and a whitespace id are each RE-ASKED (the same
#      prompt id re-emitted with an error= banner), then valid answers are
#      accepted and consent records with that id.
#   4. terminal path on a real pty: an empty name, and an empty id over a
#      blank me-card first name, are each warned and re-asked, then accepted.
#   5. a closed GUI pipe (every read is EOF) refuses after five empty answers
#      instead of spinning forever.
#   6. CONTROLS: an unattended run WITH a Contacts me-card, and an unattended
#      run with a typed name, both still reach consent with a derived id (the
#      harness can reach consent at all, so case 1's absence is meaningful).
#   7. MUTATION: with the emptiness check removed from a copy of install.sh,
#      case 1 goes RED (and the mutant is proven to have applied).
#
# Synthetic data only. Bash 3.2 safe. No `| grep -q` under pipefail.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${OWNER_TEST_INSTALL_SH:-${REPO_ROOT}/install.sh}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fails=0
pass() { printf 'ok   %s\n' "$*"; }
bad()  { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
has()  { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# Build a runnable harness from a given install.sh.
build_harness() {
    local src="$1" out="$2"
    local block consent helpers
    block="$(awk '/^# ── 1\. Confirm name/{on=1} /^# ── 2\. Confirm country code/{on=0} on' "$src")"
    consent="$(awk '/^    _consent_cli_record\(\) \{/{on=1} on{print} on && /^    \}$/{exit}' "$src")"
    helpers="$(awk '/^warn\(\)  \{/{print} /^fail_with_code\(\) \{/{on=1} /^fail\(\)  \{/{on=1} on{print} on && /^\}$/{on=0}' "$src")"
    if [[ -z "$block" || -z "$consent" || -z "$helpers" ]]; then
        echo "CANNOT-RUN: could not extract the prompt block, _consent_cli_record or the helpers from $src" >&2
        exit 2
    fi
    {
        printf '%s\n' 'set -Eeuo pipefail'
        printf 'SCRIPT_DIR=%q\n' "$REPO_ROOT"
        printf '%s\n' 'source "$SCRIPT_DIR/install.sh.strings.en-GB.sh"'
        printf '%s\n' 'source "$SCRIPT_DIR/lib/progress_emitter.sh"'
        printf '%s\n' 'BOLD=""; NC=""; RED=""; YELLOW=""'
        printf '%s\n' "$helpers"
        printf '%s\n' "$block"
        printf '%s\n' 'echo "CONSENT_CALLED user_id=[$USER_ID] user_name=[$USER_NAME]"'
        printf '%s\n' "$consent"
        printf '%s\n' '_consent_cli_record blocking test_tickbox accept "could not record" >/dev/null'
        printf '%s\n' 'echo "CONSENT_RECORDED"'
    } > "$out"
}

# Stub python: records the consent call, never touches anything real.
mkdir -p "$T/ostler/posture"
cat > "$T/py" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${OWNER_TEST_PY_LOG}"
exit 0
EOF
chmod +x "$T/py"

# run <harness> <stdin-file> [env...]: no TTY, no GUI unless env says so.
run() {
    local h="$1" in="$2"; shift 2
    env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T" \
        OSTLER_DIR="$T/ostler" OSTLER_PYTHON="$T/py" OSTLER_REGION=gb \
        OWNER_TEST_PY_LOG="$T/py.log" \
        DETECTED_NAME="" DETECTED_FIRST="" DETECTED_PHONE="" DETECTED_EMAIL="" \
        "$@" /bin/bash "$h" < "$in" 2>&1
}

case_empty_refuses() {   # $1 harness; prints verdict lines, returns 0 when GREEN
    local h="$1" out rc ok=0
    printf '\n\n' > "$T/in.empty"
    out="$(run "$h" "$T/in.empty")"; rc=$?
    has "$out" "CONSENT_CALLED" && ok=1
    has "$out" "USER_ID must be set before consent recording" && ok=1
    [[ $rc -ne 0 ]] || ok=1
    has "$out" "ERR-03-OWNER-NAME-EMPTY" || ok=1
    has "$out" "$(. "$REPO_ROOT/install.sh.strings.en-GB.sh" 2>/dev/null; printf '%s' "${MSG_FAIL_OWNER_NAME_EMPTY:-<missing>}")" || ok=1
    LAST_OUT="$out"; LAST_RC=$rc
    return $ok
}

H="$T/harness.sh"
build_harness "$INSTALL_SH" "$H"
/bin/bash -n "$H" || { echo "CANNOT-RUN: harness does not parse" >&2; exit 2; }

# ── 1. empty name + empty id, Contacts empty, no TTY ─────────────────
if case_empty_refuses "$H"; then
    pass "1 empty name+id with no TTY refuses at the prompt (rc=$LAST_RC, ERR-03-OWNER-NAME-EMPTY), _consent_cli_record never reached"
else
    bad "1 empty name+id was not refused at the prompt (rc=$LAST_RC):"; printf '%s\n' "$LAST_OUT" | sed 's/^/     | /'
fi

# ── 2. whitespace-only name is empty ─────────────────────────────────
printf '   \n\n' > "$T/in.ws"
out="$(run "$H" "$T/in.ws")"; rc=$?
if [[ $rc -ne 0 ]] && has "$out" "ERR-03-OWNER-NAME-EMPTY" && ! has "$out" "CONSENT_CALLED"; then
    pass "2 whitespace-only name refuses (rc=$rc)"
else
    bad "2 whitespace-only name accepted (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/     | /'
fi

# ── 2b. an empty id with no TTY refuses with the ID code ─────────────
# A blank me-card first name gives a blank id default; no one can re-ask.
printf 'Sam Jones\n\n' > "$T/in.id"
out="$(run "$H" "$T/in.id" DETECTED_FIRST=" ")"; rc=$?
if [[ $rc -ne 0 ]] && has "$out" "ERR-03-OWNER-ID-EMPTY" && has "$out" "$(. "$REPO_ROOT/install.sh.strings.en-GB.sh" 2>/dev/null; printf '%s' "${MSG_FAIL_OWNER_ID_EMPTY:-<missing>}")" && ! has "$out" "CONSENT_CALLED"; then
    pass "2b empty id with no TTY refuses at the prompt (rc=$rc, ERR-03-OWNER-ID-EMPTY)"
else
    bad "2b empty id with no TTY was not refused by name (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/     | /'
fi

# ── 3. GUI path re-asks, then accepts ───────────────────────────────
# Answers in order: name "" (re-ask), name "Sam Jones", id "   " (re-ask), id "Samuel".
printf '\nSam Jones\n   \nSamuel\n' > "$T/gui.answers"
: > "$T/markers"; : > "$T/py.log"
out="$(run "$H" /dev/null OSTLER_GUI=1 OSTLER_GUI_FD=3 OSTLER_MARKER_FD=4 3<"$T/gui.answers" 4>"$T/markers")"; rc=$?
n_name="$(/usr/bin/grep -c 'id=user_name' "$T/markers" || true)"
n_id="$(/usr/bin/grep -c 'id=user_id' "$T/markers" || true)"
n_err="$(/usr/bin/grep -c 'error=' "$T/markers" || true)"
if [[ $rc -eq 0 && "$n_name" == 2 && "$n_id" == 2 && "$n_err" == 2 ]] \
   && has "$out" "CONSENT_CALLED user_id=[Samuel] user_name=[Sam Jones]" \
   && has "$out" "CONSENT_RECORDED" && has "$(cat "$T/py.log")" "--user-id Samuel"; then
    pass "3 GUI: empty name and whitespace id each re-asked with an error banner (user_name x$n_name, user_id x$n_id), then accepted; consent recorded --user-id Samuel"
else
    bad "3 GUI re-ask (rc=$rc name=$n_name id=$n_id err=$n_err)"; printf '%s\n' "$out" | sed 's/^/     | /'; sed 's/^/     m /' "$T/markers"
fi

# ── 4. terminal path on a real pty re-asks, then accepts ─────────────
# pty_run <DETECTED_FIRST> <typed bytes>: the harness on a real terminal.
pty_run() {
    env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T" \
        OSTLER_DIR="$T/ostler" OSTLER_PYTHON="$T/py" OSTLER_REGION=gb \
        OWNER_TEST_PY_LOG="$T/py.log" \
        DETECTED_NAME="" DETECTED_FIRST="$1" DETECTED_PHONE="" DETECTED_EMAIL="" \
        /usr/bin/python3 -I -c '
import os, pty, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execv("/bin/bash", ["/bin/bash", sys.argv[1]])
os.write(fd, sys.argv[2].encode())
buf = b""
deadline = time.time() + 60
while time.time() < deadline:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
_, status = os.waitpid(pid, 0)
sys.stdout.write(buf.decode("utf-8", "replace").replace("\r", ""))
sys.stdout.write("\nPTY_RC=%d\n" % (os.WEXITSTATUS(status) if os.WIFEXITED(status) else 255))
' "$H" "$2"
}
. "$REPO_ROOT/install.sh.strings.en-GB.sh"
# 4a: empty name is warned and re-asked; the id prompt then offers "sam".
: > "$T/py.log"
out="$(pty_run "" $'\nSam Jones\n\n')"
if has "$out" "PTY_RC=0" && has "$out" "$MSG_WARN_OWNER_NAME_EMPTY" \
   && has "$out" "CONSENT_CALLED user_id=[sam] user_name=[Sam Jones]" \
   && has "$(cat "$T/py.log")" "--user-id sam"; then
    pass "4a terminal (pty): empty name warned and re-asked, then accepted; consent recorded --user-id sam"
else
    bad "4a terminal name re-ask"; printf '%s\n' "$out" | sed 's/^/     | /'
fi
# 4b: a blank me-card first name gives a blank id default; an empty id is
# warned and re-asked rather than taking the blank.
: > "$T/py.log"
out="$(pty_run " " $'Sam Jones\n\nSamuel\n')"
if has "$out" "PTY_RC=0" && has "$out" "$MSG_WARN_OWNER_ID_EMPTY" \
   && has "$out" "CONSENT_CALLED user_id=[Samuel] user_name=[Sam Jones]" \
   && has "$(cat "$T/py.log")" "--user-id Samuel"; then
    pass "4b terminal (pty): blank id warned and re-asked, then accepted; consent recorded --user-id Samuel"
else
    bad "4b terminal id re-ask"; printf '%s\n' "$out" | sed 's/^/     | /'
fi

# ── 5. closed GUI pipe refuses after five empties, no spin ───────────
: > "$T/markers"
out="$(run "$H" /dev/null OSTLER_GUI=1 OSTLER_GUI_FD=3 OSTLER_MARKER_FD=4 3</dev/null 4>"$T/markers")"; rc=$?
n_name="$(/usr/bin/grep -c 'id=user_name' "$T/markers" || true)"
if [[ $rc -ne 0 && "$n_name" == 5 ]] && ! has "$out" "CONSENT_CALLED"; then
    pass "5 closed GUI pipe: asked $n_name times, then refused (rc=$rc), consent never reached"
else
    bad "5 closed GUI pipe (rc=$rc asked=$n_name)"; printf '%s\n' "$out" | sed 's/^/     | /'
fi

# ── 6. controls: the harness CAN reach consent ───────────────────────
: > "$T/py.log"
out="$(run "$H" /dev/null DETECTED_NAME="Sam Jones" DETECTED_FIRST="Sam")"; rc=$?
if [[ $rc -eq 0 ]] && has "$out" "CONSENT_CALLED user_id=[sam] user_name=[Sam Jones]" && has "$out" "CONSENT_RECORDED"; then
    pass "6a control: unattended WITH a me-card still reaches consent, user_id=sam derived from Contacts"
else
    bad "6a control unattended with Contacts (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/     | /'
fi
printf 'Sam Jones\n\n' > "$T/in.typed"
out="$(run "$H" "$T/in.typed")"; rc=$?
if [[ $rc -eq 0 ]] && has "$out" "CONSENT_CALLED user_id=[sam] user_name=[Sam Jones]"; then
    pass "6b control: typed name + empty id (default offered) reaches consent, user_id=sam"
else
    bad "6b control typed name (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/     | /'
fi

# ── 7. mutation: remove the emptiness check, case 1 must go RED ─────
if [[ -z "${OWNER_TEST_INSTALL_SH:-}" ]]; then
    M="$T/install.mutant.sh"
    sed 's/^    \[\[ -n "\$_OWNER_ANSWER" \]\] && return 0$/    return 0/' "$INSTALL_SH" > "$M"
    if cmp -s "$INSTALL_SH" "$M"; then
        bad "7 mutation did not apply (the check line was not found); the mutant would prove nothing"
    else
        build_harness "$M" "$T/harness.mutant.sh"
        if case_empty_refuses "$T/harness.mutant.sh"; then
            bad "7 mutant with the emptiness check removed still passed case 1"
        else
            pass "7 mutant (emptiness check removed) goes RED on case 1"
        fi
    fi
fi

echo
if [[ $fails -ne 0 ]]; then
    echo "test_owner_name_id_never_empty: $fails FAIL"
    exit 1
fi
echo "test_owner_name_id_never_empty: all checks passed"
