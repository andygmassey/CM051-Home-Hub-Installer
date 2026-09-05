#!/usr/bin/env bash
# #1560: the shipped uninstaller had no way to be told yes, and no way to say
# "I could not ask".
#
# MEASURED on origin/main 2fb58d1e, on the heredoc extracted from install.sh:
#
#   the uninstaller                            450 lines
#   line 104                                   a bare `read -p ... CONFIRM`
#   grep ASSUME_YES|NONINTERACTIVE|FORCE|
#        --yes|CONFIRM                         2 hits, BOTH that prompt and
#                                              the test on its result
#
# So there was no override of any kind. A GUI button or a scripted caller
# blocked forever on a prompt it could not see, which is why #1562 (a GUI
# uninstall, asked for by Andy directly) could not be built on top of it.
#
# 🔴 THE HALF THAT MATTERS IS THE REFUSAL. A run that cannot obtain consent must
# exit having removed NOTHING. A half-uninstalled box is worse than an untouched
# one, and it is a state no probe in the suite describes.
#
# 🔴 AND CONSENT IS NEVER INFERRED FROM THE TERMINAL. A stray pipe, a cron job or
# a GUI that forgot the flag must not be read as authorisation to destroy a
# customer's library. The absence of a terminal can only make the script REFUSE.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run. British English throughout.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
SRC="${REPO}/install.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  [PASS] $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $*"; }
cant() { echo "CANNOT-RUN: $*" >&2; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }

[ -r "$SRC" ] || cant "install.sh is not readable at ${SRC}"
WORK="$(mktemp -d)" || cant "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
U="${WORK}/uninstaller"

# The uninstaller is a QUOTED heredoc, so its body is literal shell.
/usr/bin/awk "/^cat > \"\\\${OSTLER_DIR}\\/bin\\/ostler-uninstall\" <<'UNINSTALLEOF'\$/{f=1;next} /^UNINSTALLEOF\$/{f=0} f" \
    "$SRC" > "$U"
[ -s "$U" ] || cant "could not extract the ostler-uninstall heredoc; the anchors moved and nothing below was examined"
/bin/bash -n "$U" || cant "the extracted uninstaller is not syntactically valid; extraction is wrong"

# ── ARM 0: the destructive gate must PRECEDE every destructive line ──────────
# This is how "removed nothing" is proved without running anything destructive:
# structurally, not by observation. If the gate's refusal exits before the first
# rm/docker-volume-rm/bootout in the file, no refusal can remove anything.
# EXECUTABLE LINES ONLY. My first version grepped for `exit 3` anywhere and
# matched the COMMENT that documents the three outcomes, 108 lines above the
# statement it describes. The arm still passed, because the comment also
# precedes the destruction -- but it would have kept passing with the real
# refusal moved AFTER an `rm -rf`, which is the entire thing this arm exists to
# forbid. A predicate that can be satisfied by prose is not measuring the code.
gate_exit="$(/usr/bin/grep -nE '^[[:space:]]*exit 3([[:space:]]|$)' "$U" | head -1 | cut -d: -f1)"
first_destroy="$(/usr/bin/grep -nE '^[[:space:]]*(sudo )?(rm -rf|rm -f)|docker volume rm|launchctl bootout' "$U" | head -1 | cut -d: -f1)"
if [ -z "$gate_exit" ]; then
    bad "no 'exit 3' in the uninstaller: the could-not-ask refusal does not exist"
elif [ -z "$first_destroy" ]; then
    cant "found no destructive command in the uninstaller at all. Either the file changed shape or this predicate is broken, and 'the gate precedes destruction' would be vacuously true."
elif [ "$gate_exit" -lt "$first_destroy" ]; then
    ok "the could-not-ask refusal (line ${gate_exit}) precedes the first destructive command (line ${first_destroy}), so a refusal cannot have removed anything"
else
    bad "the refusal is at line ${gate_exit} but destruction starts at ${first_destroy}: a refusal would fire AFTER something was already gone"
fi

# CONTROL ON THAT PREDICATE: it must NOT be satisfied by a comment. The file
# contains one that mentions the same token, and if the predicate matched it the
# arm above would be measuring prose.
n_any="$(/usr/bin/grep -c 'exit 3' "$U" || true)"
n_code="$(/usr/bin/grep -cE '^[[:space:]]*exit 3([[:space:]]|$)' "$U" || true)"
if [ "${n_any:-0}" -gt "${n_code:-0}" ]; then
    ok "CONTROL: ${n_any} mention(s) of the token, ${n_code} of them executable -- the predicate rejects the comment"
else
    bad "CONTROL: ${n_any} mentions and ${n_code} executable. The predicate cannot tell a comment from a statement, so the arm above proves nothing."
fi

# ── ARM 1: consent is never inferred from the terminal ──────────────────────
n_tty="$(/usr/bin/grep -cE '\-t 0|\-t 1|tty -s|\[ -t ' "$U" || true)"
[ "${n_tty:-0}" -eq 0 ] \
    && ok "no terminal-detection test anywhere in the uninstaller (${n_tty})" \
    || bad "${n_tty} terminal-detection test(s) present; a pipe could authorise destruction"
n_ctl="$(/usr/bin/grep -cE '\-t 0|\-t 1|tty -s|\[ -t ' "$SRC" || true)"
[ "${n_ctl:-0}" -gt 0 ] \
    && ok "CONTROL: the same predicate finds ${n_ctl} in install.sh, so a zero above is a measurement" \
    || bad "CONTROL: the predicate finds none in install.sh either; it cannot detect what it is looking for"

# ── Drive the real gate, with everything after it replaced by a sentinel ─────
# Everything from the shebang through the gate is kept verbatim. The remainder
# is discarded, so nothing destructive exists in what runs.
gate_end="$(/usr/bin/grep -n '^# ── User-facing content' "$U" | head -1 | cut -d: -f1)"
[ -n "$gate_end" ] || cant "could not find the end-of-gate marker; refusing to guess where to truncate a destructive script"
head -n "$((gate_end - 1))" "$U" > "${WORK}/gate.sh"
printf 'echo "SENTINEL_REACHED"\n' >> "${WORK}/gate.sh"
/bin/bash -n "${WORK}/gate.sh" || cant "the truncated gate is not valid shell"
# The banner reads a few paths; give it somewhere harmless to look.
export OSTLER_DIR="${WORK}/fake-ostler" USER_FACING_ROOT="${WORK}/fake-docs"
mkdir -p "$OSTLER_DIR" "$USER_FACING_ROOT"

drive() { local stdin="$1"; shift; printf '%s' "$stdin" | /bin/bash "${WORK}/gate.sh" "$@" 2>&1; }
rc_of()  { local stdin="$1"; shift; printf '%s' "$stdin" | /bin/bash "${WORK}/gate.sh" "$@" >/dev/null 2>&1; echo $?; }

# ARM 2: --yes proceeds
out="$(drive "" --yes)"; rc="$(rc_of "" --yes)"
case "$out" in *SENTINEL_REACHED*) ok "--yes proceeds past the gate (rc=${rc})" ;;
               *) bad "--yes did not reach the sentinel (rc=${rc}); unattended consent does not work" ;; esac

# ARM 3: the env var proceeds
out="$(OSTLER_UNINSTALL_ASSUME_YES=1 drive "")"; 
rc="$(OSTLER_UNINSTALL_ASSUME_YES=1 rc_of "")"
case "$out" in *SENTINEL_REACHED*) ok "OSTLER_UNINSTALL_ASSUME_YES=1 proceeds past the gate (rc=${rc})" ;;
               *) bad "the env var did not reach the sentinel (rc=${rc})" ;; esac

# ARM 4: THE ONE THAT MATTERS. No flag, no answer -> refuse, remove nothing.
out="$(drive "")"; rc="$(rc_of "")"
if [ "$rc" = "3" ]; then
    ok "no flag and no answer on stdin -> exit 3, the could-not-ask refusal"
else
    bad "no flag and no answer gave rc=${rc}, expected 3. A caller cannot tell 'declined' from 'could not ask'."
fi
case "$out" in *NOTHING\ HAS\ BEEN\ REMOVED*) ok "and it says so in terms: NOTHING HAS BEEN REMOVED" ;;
               *) bad "the refusal does not state that nothing was removed" ;; esac
case "$out" in *SENTINEL_REACHED*) bad "the refusal FELL THROUGH to the sentinel: it would have gone on to destroy" ;;
               *) ok "and it never reached the code past the gate" ;; esac

# ARM 5: a human declining is exit 0, NOT 3. The two must stay distinct.
rc="$(rc_of "no
")"
[ "$rc" = "0" ] && ok "a human typing something other than YES exits 0, distinct from the refusal's 3" \
                || bad "declining gave rc=${rc}; declined and could-not-ask have collapsed onto one code"

# ARM 6: typing YES proceeds
out="$(drive "YES
")"
case "$out" in *SENTINEL_REACHED*) ok "typing YES still proceeds, so the interactive path is unbroken" ;;
               *) bad "typing YES no longer proceeds; the change broke the ordinary route" ;; esac

# ── ARM 7: NON-EMPTY IS NOT TRUTHY ──────────────────────────────────────────
# ARM 3 is a must-match: it proves =1 proceeds. On its own it is satisfied by
# a gate that lets EVERYTHING proceed, which is exactly what `-n` did. This is
# the must-miss it was always owed. Every value here means no, or means
# nothing; none of them may reach the code past the gate.
for v in 0 no NO false FALSE banana 2 00; do
    out="$(OSTLER_UNINSTALL_ASSUME_YES="$v" drive "")"
    rc="$(OSTLER_UNINSTALL_ASSUME_YES="$v" rc_of "")"
    case "$out" in
        *SENTINEL_REACHED*)
            bad "OSTLER_UNINSTALL_ASSUME_YES=${v} PROCEEDED past the gate (rc=${rc}): a value that is not consent authorised a destructive uninstall" ;;
        *)
            if [ "$rc" = "3" ]; then
                ok "OSTLER_UNINSTALL_ASSUME_YES=${v} refuses with the could-not-ask exit 3"
            else
                bad "OSTLER_UNINSTALL_ASSUME_YES=${v} did not reach the sentinel but gave rc=${rc}, expected 3"
            fi ;;
    esac
done

# And the caller is told WHY, or they read "stdin gave no answer" and never
# learn that the variable they set is the reason.
out="$(OSTLER_UNINSTALL_ASSUME_YES=0 drive "")"
case "$out" in *not\ consent*) ok "a non-consent value says so, rather than reporting only an EOF" ;;
               *) bad "a non-consent value is silently ignored; the caller cannot tell why it refused" ;; esac

# ARM 8: the accepted spellings still work, so the allow-list is not so tight
# that ordinary consent stops being consent.
for v in 1 y Y yes YES true TRUE; do
    out="$(OSTLER_UNINSTALL_ASSUME_YES="$v" drive "")"
    case "$out" in *SENTINEL_REACHED*) ok "OSTLER_UNINSTALL_ASSUME_YES=${v} is accepted as consent" ;;
                   *) bad "OSTLER_UNINSTALL_ASSUME_YES=${v} was refused; a documented spelling of yes no longer works" ;; esac
done

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
