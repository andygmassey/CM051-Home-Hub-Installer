#!/usr/bin/env bash
#
# tests/test_mail_content_probe.sh
#
# Locks the install.sh #259 mail-content probe block. Extracts the
# block between known markers, stubs the shell helpers it depends on,
# and runs it against synthetic ~/Library/Mail fixtures.
#
# Why this test exists:
#   - The probe's output (pipeline_signals.json) is the contract that
#     HR015 #109 reads to decide whether to fire the empty-Mail banner.
#     A regression here silently breaks the Doctor empty-Mail
#     diagnostic without any obvious symptom on the install side.
#
# Verified scenarios:
#   1. No ~/Library/Mail dir at all -> mail_has_fetched=false, count=0
#   2. Mail dir present, Accounts.plist has 2 AccountName entries,
#      InboxCache.plist is empty -> count=2, has_fetched=false
#   3. Mail dir present, InboxCache.plist >0 bytes -> has_fetched=true
#   4. install.sh structural sanity (probe block + writer call present)
#
# Synthetic Apple Mail fixtures only -- alice@example.com style.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
WRITER="${REPO_ROOT}/lib/write_pipeline_signals.py"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi
if [[ ! -f "$WRITER" ]]; then
    echo "FAIL: write_pipeline_signals.py not found at $WRITER" >&2
    exit 1
fi

if ! bash -n "$INSTALL_SCRIPT"; then
    echo "FAIL: install.sh fails bash -n parse check" >&2
    exit 1
fi
echo "PASS: install.sh parses"

# ── Structural sanity: probe block + writer call present ─────────
if ! grep -q '3.14a-probe Mail content probe + sidecar' "$INSTALL_SCRIPT"; then
    echo "FAIL [struct]: probe section header not found in install.sh" >&2
    exit 1
fi
echo "PASS: probe section header present in install.sh"

if ! grep -q 'write_pipeline_signals.py' "$INSTALL_SCRIPT"; then
    echo "FAIL [struct]: install.sh does not invoke write_pipeline_signals.py" >&2
    exit 1
fi
echo "PASS: install.sh invokes write_pipeline_signals.py"

if ! grep -qE 'gui_emit MAIL_ACCOUNTS_FOUND' "$INSTALL_SCRIPT"; then
    echo "FAIL [struct]: install.sh does not emit MAIL_ACCOUNTS_FOUND marker" >&2
    exit 1
fi
echo "PASS: install.sh emits MAIL_ACCOUNTS_FOUND marker"

# ── Extract the probe block between known markers ────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PROBE="${WORK}/probe.sh"
awk '
    /^# ── 3\.14a-probe Mail content probe \+ sidecar/ { capture = 1 }
    capture                                            { print }
    capture && /^unset .*_pipeline_writer$/            { exit }
' "$INSTALL_SCRIPT" > "$PROBE"

if [[ ! -s "$PROBE" ]]; then
    echo "FAIL [extract]: could not extract probe block from install.sh" >&2
    exit 1
fi
echo "PASS: probe block extracted ($(wc -l < "$PROBE") lines)"

# ── Driver: source the extracted block with stubs ────────────────
# The driver wraps the probe in a function so each test scenario gets
# a fresh execution against its own fake $HOME.
DRIVER="${WORK}/driver.sh"
cat > "$DRIVER" <<'DRIVER_EOF'
#!/usr/bin/env bash
set -euo pipefail

# Helpers the probe references. No-op stubs that capture state for
# assertions.
info()     { echo "[info] $*"; }
warn()     { echo "[warn] $*" >&2; }
gui_emit() { echo "[emit] $*"; }

# These are defined elsewhere in install.sh; the probe assumes them.
SCRIPT_DIR="$1"
OSTLER_DIR="$2"
shift 2

# Source the extracted block. It uses ${HOME}, ${OSTLER_DIR},
# ${SCRIPT_DIR}, the *info/warn/gui_emit* helpers above, and writes
# to ${OSTLER_DIR}/state/pipeline_signals.json.
source "$1"
DRIVER_EOF
chmod +x "$DRIVER"

# ── Scenario 1: no ~/Library/Mail at all ─────────────────────────
S1_HOME="${WORK}/s1_home"
mkdir -p "$S1_HOME"
S1_OSTLER="${WORK}/s1_ostler"
HOME="$S1_HOME" bash "$DRIVER" "$REPO_ROOT" "$S1_OSTLER" "$PROBE" >/dev/null 2>&1
S1_OUT="${S1_OSTLER}/state/pipeline_signals.json"
if [[ ! -f "$S1_OUT" ]]; then
    echo "FAIL [s1]: probe did not write sidecar in the no-Mail case" >&2
    exit 1
fi
python3 - "$S1_OUT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["mail_accounts_found"] == 0, data
assert data["mail_has_fetched"] is False, data
assert isinstance(data["install_completed_ts"], int), data
PY
echo "PASS [s1]: no Mail dir -> count=0, has_fetched=false"

# ── Scenario 2: Accounts.plist with 2 accounts, empty InboxCache ─
S2_HOME="${WORK}/s2_home"
mkdir -p "$S2_HOME/Library/Mail/V10/MailData"
cat > "$S2_HOME/Library/Mail/V10/MailData/Accounts.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>MailAccounts</key>
  <array>
    <dict>
      <key>AccountName</key>
      <string>alice@example.com</string>
    </dict>
    <dict>
      <key>AccountName</key>
      <string>bob@example.com</string>
    </dict>
  </array>
</dict>
</plist>
PLIST
# Empty (0-byte) InboxCache.plist so has_fetched stays false.
mkdir -p "$S2_HOME/Library/Mail/V10/SomeMailbox.mbox"
: > "$S2_HOME/Library/Mail/V10/SomeMailbox.mbox/InboxCache.plist"

S2_OSTLER="${WORK}/s2_ostler"
HOME="$S2_HOME" bash "$DRIVER" "$REPO_ROOT" "$S2_OSTLER" "$PROBE" >/dev/null 2>&1
S2_OUT="${S2_OSTLER}/state/pipeline_signals.json"
python3 - "$S2_OUT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["mail_accounts_found"] == 2, data
assert data["mail_has_fetched"] is False, data
PY
echo "PASS [s2]: 2 accounts, empty InboxCache -> count=2, has_fetched=false"

# ── Scenario 3: non-empty InboxCache.plist -> has_fetched=true ───
S3_HOME="${WORK}/s3_home"
mkdir -p "$S3_HOME/Library/Mail/V10/MailData"
cat > "$S3_HOME/Library/Mail/V10/MailData/Accounts.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>MailAccounts</key>
  <array>
    <dict>
      <key>AccountName</key>
      <string>alice@example.com</string>
    </dict>
  </array>
</dict>
</plist>
PLIST
mkdir -p "$S3_HOME/Library/Mail/V10/Inbox.mbox"
printf 'cached-marker' > "$S3_HOME/Library/Mail/V10/Inbox.mbox/InboxCache.plist"

S3_OSTLER="${WORK}/s3_ostler"
HOME="$S3_HOME" bash "$DRIVER" "$REPO_ROOT" "$S3_OSTLER" "$PROBE" >/dev/null 2>&1
S3_OUT="${S3_OSTLER}/state/pipeline_signals.json"
python3 - "$S3_OUT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["mail_accounts_found"] == 1, data
assert data["mail_has_fetched"] is True, data
PY
echo "PASS [s3]: non-empty InboxCache.plist -> has_fetched=true"

echo ""
echo "ALL MAIL CONTENT PROBE TESTS PASSED"
