#!/usr/bin/env bash
# Two walk-box safety rules, each with its own mutation arm.
#
#  1. A WALK NEVER ENABLES WHATSAPP. Answer 5 writes pair_phone/allowed_numbers,
#     after which the daemon opens wss://web.whatsapp.com and sends the number to
#     Meta on every reconnect, and install.sh installs the keepalive agent. So the
#     driver must NOT answer 5 / Y / a phone to the three WhatsApp prompts. The
#     WhatsApp writer is judged OFF-BOX instead (brief_channel_probe.py --self-test).
#  2. A WALK DECLARES ITS OWNER. Without OSTLER_WALK_OWNER_FILE walk_drive.py
#     would fall back to the fictional +44 7700 900000 recipient and the installed
#     09:00/18:00 brief would try an outward send. It must refuse (rc != 0), and
#     ttywalk.sh must always pass it. Declared-but-absent file = synthetic walk.
#
# Prompt titles are read from the shipped strings file, so a renamed prompt turns
# this red instead of silently falling back. rc=2: harness could not set itself up.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRIVER_DIR="${OSTLER_WALK_DRIVER_DIR:-${REPO_ROOT}/scripts}"
STRINGS="${OSTLER_STRINGS_FILE:-${REPO_ROOT}/install.sh.strings.en-GB.sh}"
TTYWALK="${OSTLER_TTYWALK:-${REPO_ROOT}/scripts/ttywalk.sh}"
PROBE="${OSTLER_BRIEF_PROBE:-${REPO_ROOT}/scripts/box_walk_probes/lib/brief_channel_probe.py}"
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3" >&2; exit 2; }
[ -f "${STRINGS}" ] || { echo "CANNOT-RUN: ${STRINGS} missing" >&2; exit 2; }
[ -f "${DRIVER_DIR}/walk_drive.py" ] || { echo "CANNOT-RUN: no walk_drive.py in ${DRIVER_DIR}" >&2; exit 2; }
T="$(mktemp -d)" || exit 2
trap 'rm -rf "${T}"' EXIT
FAIL=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }

# ---- 1. the table never enables WhatsApp --------------------------------
# $1 = driver dir. Prints "<name> <answer>" per prompt.
wa_answers() {
    python3 -I - "$1" "${STRINGS}" <<'PY'
import re, sys
drv, strings = sys.argv[1], sys.argv[2]
sys.path.insert(0, drv)
import walk_drive as w
text = open(strings).read()
def title(name):
    m = re.search(r'^%s="([^"]*)"' % name, text, re.M)
    if not m:
        print("CANNOT-RUN %s" % name); sys.exit(2)
    return m.group(1)
table = w.build_table()
for name in ("MSG_PROMPT_CHANNEL_CHOICE_TITLE", "MSG_PROMPT_WHATSAPP_CONSENT_TITLE", "MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE"):
    ans, matched = w.answer_for(title(name), table)
    print("%s %s" % (name, ans))
PY
}
check_table() {  # $1 = driver dir, $2 = label
    local out rc
    out="$(wa_answers "$1")"; rc=$?
    [ "${rc}" -eq 0 ] || { echo "CANNOT-RUN: could not read the answer table (${out})" >&2; exit 2; }
    if printf '%s\n' "${out}" | /usr/bin/grep -qE '^MSG_PROMPT_CHANNEL_CHOICE_TITLE 5$'; then
        echo "  $2: channel_choice answered 5 (WhatsApp)"; return 1
    fi
    if printf '%s\n' "${out}" | /usr/bin/grep -qE '^MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE \+?[0-9]{6,}'; then
        echo "  $2: a WhatsApp phone number is answered"; return 1
    fi
    return 0
}
if check_table "${DRIVER_DIR}" real; then ok "the walk driver does not answer channel_choice 5 or a WhatsApp number"; else bad "the walk driver enables WhatsApp"; fi

# mutation: a driver that answers 5 must turn the check red.
mkdir -p "${T}/mut_wa"; cp "${DRIVER_DIR}/walk_drive.py" "${T}/mut_wa/walk_drive.py"
python3 -I - "${T}/mut_wa/walk_drive.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
anchor = '        ("Ready to install?",'
assert anchor in s, "anchor missing"
s = s.replace(anchor, '        ("How will your assistant reach you?", "5"),\n' + anchor, 1)
open(p, 'w').write(s)
PY
if check_table "${T}/mut_wa" mutant >/dev/null; then bad "mutation-inert: a driver answering 5 was not caught"; else ok "mutant caught: a driver answering channel_choice 5 turns the check red"; fi

# ---- 2. no OSTLER_WALK_OWNER_FILE -> refuse -------------------------------
run_main() {  # $1 = driver, $2 = HOME, $3.. = extra env assignments
    local drv="$1" h="$2"; shift 2
    env -u OSTLER_WALK_OWNER_FILE HOME="${h}" OSTLER_GUI=1 "$@" python3 -I "${drv}" 2>&1
}
mkdir -p "${T}/h1"
OUT="$(run_main "${DRIVER_DIR}/walk_drive.py" "${T}/h1")"; RC=$?
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | /usr/bin/grep -q 'OSTLER_WALK_OWNER_FILE is not set'; then
    ok "no OSTLER_WALK_OWNER_FILE: the driver refuses (rc=${RC}) and names the variable"
else
    bad "no OSTLER_WALK_OWNER_FILE: rc=${RC}, output: $(printf '%s' "${OUT}" | head -c 200)"
fi
# control: with it declared (file absent = synthetic) the driver gets PAST the refusal
OUT2="$(run_main "${DRIVER_DIR}/walk_drive.py" "${T}/h1" "OSTLER_WALK_OWNER_FILE=${T}/h1/.walk-owner.env")"
if printf '%s' "${OUT2}" | /usr/bin/grep -q 'OSTLER_WALK_OWNER_FILE is not set'; then
    bad "control: a declared OSTLER_WALK_OWNER_FILE was still refused"
else
    ok "control: with OSTLER_WALK_OWNER_FILE declared the driver is past the refusal (stops later, on the missing walk config)"
fi
# mutation: remove the refusal -> arm must go red
mkdir -p "${T}/mut_own"
python3 -I - "${DRIVER_DIR}/walk_drive.py" "${T}/mut_own/walk_drive.py" <<'PY'
import sys
s = open(sys.argv[1]).read()
needle = 'if not os.environ.get("OSTLER_WALK_OWNER_FILE"):'
assert needle in s, 'refusal anchor missing'
s = s.replace(needle, 'if False:', 1)
open(sys.argv[2], 'w').write(s)
PY
OUT3="$(run_main "${T}/mut_own/walk_drive.py" "${T}/h1")"
if printf '%s' "${OUT3}" | /usr/bin/grep -q 'OSTLER_WALK_OWNER_FILE is not set'; then
    bad "mutation-inert: the refusal survived its own removal"
else
    ok "mutant caught: a driver without the refusal proceeds, so the arm above would be red"
fi

# ttywalk always passes it on the line that launches the driver.
if /usr/bin/grep -B3 'nohup python3 scripts/walk_drive.py' "${TTYWALK}" | /usr/bin/grep -q 'OSTLER_WALK_OWNER_FILE='; then
    ok "ttywalk.sh passes OSTLER_WALK_OWNER_FILE on the walk_drive.py launch"
else
    bad "ttywalk.sh launches walk_drive.py without OSTLER_WALK_OWNER_FILE"
fi
# nothing else launches the driver
OTHERS="$(/usr/bin/grep -rlE 'python3? +[^ ]*walk_drive\.py' "${REPO_ROOT}/scripts" "${REPO_ROOT}/.github" 2>/dev/null | /usr/bin/grep -v -e 'ttywalk.sh$' -e '/scripts/tests/' || true)"
[ -z "${OTHERS}" ] && ok "ttywalk.sh is the only launcher of walk_drive.py in scripts/ and .github/" || bad "other launchers of walk_drive.py: ${OTHERS}"

# ---- 3. the off-box WhatsApp writer self-test is part of this gate --------
if python3 -I "${PROBE}" --self-test >"${T}/st.out" 2>&1; then ok "brief_channel_probe --self-test: $(tail -1 "${T}/st.out")"; else bad "brief_channel_probe --self-test failed: $(tail -3 "${T}/st.out" | tr '\n' ' ')"; fi

[ "${FAIL}" -eq 0 ] && echo "PASS: the walk never enables WhatsApp and declares its owner" || { echo "FAIL"; exit 1; }
