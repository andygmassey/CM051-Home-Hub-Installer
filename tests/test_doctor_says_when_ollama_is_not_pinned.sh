#!/usr/bin/env bash
# THE DOCTOR SAYS WHEN OLLAMA IS NOT ON OSTLER'S PINNED VERSION (#2977).
#
# Archie's condition (1) for the existing-install deferral: a deferred pin
# must be VISIBLE, not only a line in install.log. This is the consumer half,
# end to end through the real components:
#
#   writer  the SHIPPED _ostler_ollama_pin_apply (cut from install.sh between
#           the OSTLER-OLLAMA-PIN-FN markers) runs against a fake HOME with an
#           existing working install and a failing download, so IT writes
#           ~/.ostler/state/ollama-pin. Nothing here hand-writes the record.
#   reader  the SHIPPED Doctor (vendor/doctor/agent): run_all_rules() over a
#           degraded snapshot, then render_dashboard(), the page the customer
#           opens. The test asserts the title AND the reason reach the HTML.
#
#   A  deferred (download failed)   -> the page shows "Ollama is not on
#                                      Ostler's pinned version" + the reason
#   B  the next run installs the pin -> the record says installed and the row
#                                      is GONE (the retry clears it)
#   C  no record at all (an install older than the record) -> no row
#
# Synthetic fixtures only. Stubs `curl` on PATH; no network, no real Ollama.
# THREE OUTCOMES: 0 pass, 1 fail, 2 CANNOT-RUN (which is not a pass).
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="${REPO}/install.sh"
AGENT="${REPO}/vendor/doctor/agent"
cannot() { echo "CANNOT-RUN: $*" >&2; exit 2; }
[ -f "$INSTALL" ] && [ -d "$AGENT" ] || cannot "missing install.sh or vendor/doctor/agent"
PY="${PYTHON:-python3}"
"$PY" -c 'import fastapi, httpx' 2>/dev/null || cannot "the Doctor's deps are not installed (pip install -r vendor/doctor/agent/requirements.txt)"

W="$(mktemp -d "${TMPDIR:-/tmp}/doctor-pin.XXXXXX")" || cannot "no scratch dir"
trap 'rm -rf "$W"' EXIT
fails=0
pass() { echo "PASS: $*"; }
bad()  { echo "FAIL: $*"; fails=$((fails + 1)); }

FN="$W/pin_fn.sh"
sed -n '/^# OSTLER-OLLAMA-PIN-FN-BEGIN$/,/^# OSTLER-OLLAMA-PIN-FN-END$/p' "$INSTALL" > "$FN"
grep -q '^_ostler_ollama_pin_apply()' "$FN" || cannot "no _ostler_ollama_pin_apply between the pin markers"

# fixture engine archive + its sha
mkdir -p "$W/src" "$W/bin"
printf '#!/bin/sh\necho fixture\n' > "$W/src/ollama"; printf '#!/bin/sh\nexit 0\n' > "$W/src/llama-server"
chmod +x "$W/src/ollama" "$W/src/llama-server"
tar -czf "$W/good.tgz" -C "$W/src" .
SHA="$(shasum -a 256 "$W/good.tgz" 2>/dev/null || sha256sum "$W/good.tgz")"; SHA="${SHA%% *}"
# stub curl: the :11434 probe answers (an existing working Ollama); a download
# copies good.tgz, or fails when STUB_FAIL=1
cat > "$W/bin/curl" <<'STUB'
#!/bin/sh
all="$*"; out=""
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
case "$all" in *11434*) exit 0 ;; esac
[ "${STUB_FAIL:-0}" = 1 ] && exit 22
cp "${STUB_SRC:?}" "$out"
STUB
chmod +x "$W/bin/curl"

H="$W/home"
OLD="$H/.ostler/runtime/ollama-0.0.1/ollama"
mkdir -p "$(dirname "$OLD")" "$H/Library/LaunchAgents"
printf '#!/bin/sh\necho old\n' > "$OLD"; chmod +x "$OLD"
cat > "$H/Library/LaunchAgents/com.ostler.ollama.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
    <key>Label</key><string>com.ostler.ollama</string>
    <key>ProgramArguments</key>
    <array>
        <string>${OLD}</string>
        <string>serve</string>
    </array>
</dict></plist>
PL

apply() {  # apply <STUB_FAIL> ; runs the shipped writer
    HOME="$H" PATH="$W/bin:$PATH" STUB_SRC="$W/good.tgz" STUB_FAIL="$1" \
    OLLAMA_PIN_VERSION=9.9.9 OLLAMA_PIN_URL="https://example.invalid/ollama-darwin.tgz" OLLAMA_PIN_SHA256="$SHA" \
    bash -c '. "$1"; r=0; _ostler_ollama_pin_apply "$2" "$3" || r=$?; echo "rc=$r outcome=${OLLAMA_PIN_OUTCOME:-}"' \
        _ "$FN" "$H/.ostler/runtime/ollama-9.9.9" "$H/Library/LaunchAgents/com.ostler.ollama.plist" 2>/dev/null
}

render() {  # render -> the customer-facing dashboard HTML, via the shipped Doctor
    HOME="$H" OSTLER_DIR="$H/.ostler" "$PY" - "$AGENT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import web_ui
from diagnostic_rules import run_all_rules
snap = web_ui._degraded_snapshot()
findings = run_all_rules(snap)
print(web_ui.render_dashboard(snap, findings))
PY
}
TITLE="Ollama is not on Ostler&#x27;s pinned version"
TITLE_RAW="Ollama is not on Ostler's pinned version"
REASON="the download did not complete"
has_title() { grep -qF "$TITLE" <<<"$1" || grep -qF "$TITLE_RAW" <<<"$1"; }

# C first, before any record exists
html="$(render)" || cannot "the Doctor dashboard did not render"
[ -n "$html" ] || cannot "the Doctor dashboard rendered nothing"
if has_title "$html"; then bad "C: no record yet, but the page claims Ollama is unpinned"; else pass "C: no record -> no row (an older install is not called unpinned)"; fi

# A: deferred
out="$(apply 1)"
grep -qx 'ollama_pin=deferred' "$H/.ostler/state/ollama-pin" 2>/dev/null || bad "A: the shipped writer did not record ollama_pin=deferred ($out)"
html="$(render)"
if has_title "$html" && grep -qF "$REASON" <<<"$html"; then
    pass "A: deferred pin ($out) -> the Doctor page shows \"$TITLE_RAW\" and \"$REASON\""
else bad "A: the Doctor page does not show the unpinned row with its reason ($out)"; fi

# B: the next run installs the pin -> the row is gone
out="$(apply 0)"
html="$(render)"
if grep -qx 'ollama_pin=installed' "$H/.ostler/state/ollama-pin" && ! has_title "$html"; then
    pass "B: the next run installs the pin ($out) -> record says installed, the row is gone"
else bad "B: after a successful retry ($out) the record is '$(head -1 "$H/.ostler/state/ollama-pin" 2>/dev/null)' and the row is $(has_title "$html" && echo STILL SHOWN || echo gone)"; fi

echo "VERDICT: $([ "$fails" = 0 ] && echo PASS || echo "FAIL ($fails)")"
[ "$fails" = 0 ]
