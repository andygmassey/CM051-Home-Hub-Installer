#!/usr/bin/env bash
# The walk driver answers the three WhatsApp channel prompts, so the install
# writes [channels.whatsapp] and assistant_sends_over_whatsapp_and_email can
# MEASURE instead of reading "did not enable the WhatsApp channel" (CANNOT-RUN
# on v1.0.115). Prompt titles are read from the shipped strings file, so a
# renamed prompt turns this red instead of silently falling back to Enter.
# rc=2 means the harness could not set itself up.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRIVER_DIR="${OSTLER_WALK_DRIVER_DIR:-${REPO_ROOT}/scripts}"
STRINGS="${OSTLER_STRINGS_FILE:-${REPO_ROOT}/install.sh.strings.en-GB.sh}"
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3" >&2; exit 2; }
[ -f "${STRINGS}" ] || { echo "CANNOT-RUN: ${STRINGS} missing" >&2; exit 2; }

python3 -I - "${DRIVER_DIR}" "${STRINGS}" <<'PY'
import re, sys
drv, strings = sys.argv[1], sys.argv[2]
sys.path.insert(0, drv)
import walk_drive as w

def title(name):
    m = re.search(r'^%s="([^"]*)"' % name, open(strings).read(), re.M)
    if not m:
        print("CANNOT-RUN: %s not in strings file" % name); sys.exit(2)
    return m.group(1)

table = w.build_table()
want = [
    ("MSG_PROMPT_CHANNEL_CHOICE_TITLE", "5"),
    ("MSG_PROMPT_WHATSAPP_CONSENT_TITLE", "Y"),
    ("MSG_PROMPT_WHATSAPP_RECIPIENT_TITLE", "+447700900000"),
]
bad = 0
for name, expect in want:
    ans, matched = w.answer_for(title(name), table)
    if matched and ans == expect:
        print("PASS: %s -> %r" % (name, ans))
    else:
        print("FAIL: %s -> matched=%s answer=%r, want %r" % (name, matched, ans, expect)); bad = 1
sys.exit(bad)
PY
