#!/usr/bin/env bash
# Regression guard (2026-10-22, job installer_copy_sweep): installer copy that
# states a size, a duration or a count must agree with what the walk measured,
# and the house wording rule holds on the step copy.
#
# Measured on the v1.0.116 walk (Mini16, ~650 KB/s link) and the v1.0.111 walk:
#   - the vane image is 3.43 GB compressed (ghcr manifest, arm64): "about 3.5 GB",
#     and at 650 KB/s that is ~88 minutes, so "up to an hour" was wrong.
#   - docker_install 22 s / 427 s, ollama_install 304 s, graph_db_start 262 s,
#     all past their long_running_threshold_s with NO long_running_copy, so the
#     customer saw a silent step.
#   - "Docker running (took 0s)" sat inside a step that STEP_END timed at 22 s.
#   - fda_extract 20 s / 75 s, titled "the instant bit".
#   - import_data copy said 10-20 minutes while the install log line says 15 to 45.
#   - GDPR scan copy promised "5-10 seconds" for a step with three macOS prompts
#     the customer must click.
#   - House rule: step copy says capture/transcribe, not record.
#
# Control: the stale detector is first run on synthetic stale lines and must fire.
# Bash 3.2 safe. No pipes into grep -q: here-strings only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STRINGS="${REPO_ROOT}/install.sh.strings.en-GB.sh"
HINTS="${REPO_ROOT}/gui/OstlerInstaller/Resources/HintCopy.json"
INSTALL="${REPO_ROOT}/install.sh"

fails=0
red() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

STALE_RE='up to an hour|~3\.6 GB|10-20 minutes|5-10 seconds|took %ss|instant (bit|onboarding)|[Rr]ecord (a|your)|recorded meetings|Recording is always|can record and'
for sample in \
    'can take up to an hour.' \
    'First-time pull is ~3.6 GB' \
    'Years of iMessage data can take 10-20 minutes.' \
    'It takes about 5-10 seconds in total.' \
    'Docker running (took %ss)' \
    'The instant onboarding bit' \
    'Record a call with Ostler' \
    'Recording is always your choice'; do
    if ! [[ "$sample" =~ $STALE_RE ]]; then
        red "stale detector did not fire on control: ${sample}"
    fi
done

field() { # $1 key in strings file -> value
    /usr/bin/grep -E "^$1=" "$STRINGS" | head -1
}

for key in MSG_INFO_VANE_LARGE_DOWNLOAD_NO_PROGRESS MSG_INFO_GDPR_SCAN_PROMPTS_INCOMING \
           MSG_OK_DOCKER_RUNNING_TOOK_S MSG_INFO_FEED_SPOKEN_SKIPPED_HOW; do
    line="$(field "$key")"
    [[ -n "$line" ]] || { red "${key} missing from strings file"; continue; }
    if [[ "$line" =~ $STALE_RE ]]; then red "${key} still carries a stale claim: ${line}"; fi
done

line="$(field MSG_INFO_VANE_LARGE_DOWNLOAD_NO_PROGRESS)"
[[ "$line" == *"an hour or more"* ]] || red "vane copy must say the pull can take an hour or more on a slow link"

if /usr/bin/grep -q 'Extracting data from your Mac (the instant bit)' "$INSTALL"; then
    red "install.sh fda_extract title still says 'the instant bit' (measured 20 s to 75 s)"
fi

/usr/bin/python3 -I - "$HINTS" <<'PY' || fails=$((fails + 1))
import json, re, sys
d = json.load(open(sys.argv[1]))
bad = []
stale = re.compile(r"up to an hour|~3\.6 GB|10-20 minutes|instant (bit|onboarding)|recorded meetings|own recordings|can record|records nothing|Recording is", re.I)
for k, v in d.items():
    if not isinstance(v, dict):
        continue
    for f in ("title", "subtitle", "why", "long_running_copy"):
        s = v.get(f)
        if isinstance(s, str) and stale.search(s):
            bad.append("%s.%s: %s" % (k, f, s[:90]))
for k in ("docker_install", "ollama_install", "graph_db_start"):
    c = d[k].get("long_running_copy")
    if not (isinstance(c, str) and c.strip()):
        bad.append("%s: past its long_running_threshold_s on every measured walk but has no long_running_copy" % k)
v = d["vane_install"].get("long_running_copy", "")
if "3.5 GB" not in v or "hour" not in v:
    bad.append("vane_install.long_running_copy must say about 3.5 GB and an hour or more: %s" % v)
i = d["import_data"].get("long_running_copy", "")
if "15 to 45 minutes" not in i:
    bad.append("import_data.long_running_copy must agree with install.sh (15 to 45 minutes): %s" % i)
if bad:
    for b in bad:
        print("FAIL: " + b, file=sys.stderr)
    sys.exit(1)
PY

if [[ "$fails" -ne 0 ]]; then
    printf '%d installer copy claim(s) disagree with the measured walk\n' "$fails" >&2
    exit 1
fi
echo "PASS: installer copy claims match the measured walk"
