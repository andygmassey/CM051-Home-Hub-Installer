#!/usr/bin/env bash
#
# CM051 walk #27, item 2: the context digest's "Preferences and things to
# keep in mind" was EMPTY while the preferences store held 40,315 points.
#
# Writer: editor-frontpage-tick.sh emits ~/.ostler/preferences/
#         interest_profile.json (hourly, plus a catch-up agent).
# Reader: context-refresh/bin/generate_pwg_context.py _preferences_section,
#         through ical-server's /api/v1/preferences (api_preferences), which
#         serves that file.
# Measured on macmini16-walk (read-only): the digest ran at 05:14 local, the
# first non-empty profile landed at 05:25, the next digest was 06:48, and the
# walk read the digest in between. Nothing told the reader the writer had
# produced.
#
# Limbs:
#   A  the tick kickstarts context-refresh when the profile's interest count
#      changes (0 -> N), and NOT when it is unchanged (real tick, stub launchctl)
#   B  the reader contract: the profile the writer leaves is read by the REAL
#      api_preferences and the REAL _preferences_section into non-empty lines
#   C  negative control: a tick with the change-check forced false never
#      kickstarts, so limb A can fail
#
# Runs under bash 3.2.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TICK="${REPO_ROOT}/vendor/cm059_editor/bin/editor-frontpage-tick.sh"
LABEL="com.creativemachines.ostler.context-refresh"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

echo "test_digest_refreshes_when_the_interest_profile_lands"
PY_BIN="$(command -v python3 || true)"
if [ -z "$PY_BIN" ] || [ ! -f "$TICK" ]; then
    echo "  CANNOT-RUN: python3 or the tick script is missing"; exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
OSTLER_DIR="${WORK}/ostler"; SOURCE_DIR="${WORK}/cm059-editor"; STUB_BIN="${WORK}/stubbin"
PROFILE="${WORK}/preferences/interest_profile.json"
mkdir -p "${OSTLER_DIR}/editor" "${SOURCE_DIR}/compiler" "$STUB_BIN" "${WORK}/preferences"
: > "${SOURCE_DIR}/compiler/__init__.py"
printf 'import sys\nsys.exit(0)\n' > "${SOURCE_DIR}/compiler/emit_frontpage.py"
# The stub writer emits ARTEFACT_N synthetic interests in the shape the Hub
# serves (keys measured on the walk box), with a fresh generated_at each tick.
cat > "${SOURCE_DIR}/compiler/emit_artefact.py" <<'EOF'
import json, os, time
n = int(os.environ.get("ARTEFACT_N", "0"))
subjects = ["Sea kayaking", "Sourdough baking", "Jazz piano", "Fell running", "Board games"]
items = [{"id": "i%d" % i, "subject": subjects[i % len(subjects)] + (" %d" % i if i >= len(subjects) else ""),
          "domain": "hobbies", "polarity": "like", "privacy": "L2" if i % 2 else "L1",
          "score": float(n - i), "confidence": 0.8, "sources": ["synthetic"]} for i in range(n)]
with open(os.environ["OSTLER_INTEREST_PROFILE"], "w") as fh:
    json.dump({"schema_version": 1, "generated_at": str(time.time()), "interests": items}, fh)
EOF
CALLS="${WORK}/launchctl_calls.log"; : > "$CALLS"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$CALLS" > "${STUB_BIN}/launchctl"
chmod +x "${STUB_BIN}/launchctl"

run_tick() {  # $1 = tick script, $2 = interests to emit
    sed -e "s#__OSTLER_PYTHON__#${PY_BIN}#" -e "s#__OSTLER_SOURCE_DIR__#${SOURCE_DIR}#" "$1" > "${WORK}/rendered.sh"
    chmod +x "${WORK}/rendered.sh"
    OSTLER_DIR="$OSTLER_DIR" OSTLER_RESOURCE_GOVERNOR=0 ARTEFACT_N="$2" \
        OSTLER_INTEREST_PROFILE="$PROFILE" PYTHONPYCACHEPREFIX="${WORK}/pycache" \
        PATH="${STUB_BIN}:${PATH}" "${WORK}/rendered.sh" >> "${WORK}/tick.log" 2>&1
}
kicks() { grep -c "kickstart .*${LABEL}" "$CALLS" 2>/dev/null || true; }

# A. hydration still landing: 0 interests, then the profile fills, then steady.
run_tick "$TICK" 0; k0="$(kicks)"
run_tick "$TICK" 0; k1="$(kicks)"
run_tick "$TICK" 12; k2="$(kicks)"
run_tick "$TICK" 12; k3="$(kicks)"
if [ "$k1" = "$k0" ]; then ok "an unchanged empty profile does not re-run the digest"; else bad "unchanged 0 re-ran the digest (${k0} -> ${k1})"; fi
if [ "$k2" = "$((k1 + 1))" ]; then ok "the profile filling (0 -> 12) kickstarts ${LABEL} within the same tick"; else bad "0 -> 12 did not kickstart ${LABEL} (${k1} -> ${k2}); log: $(tail -3 "${WORK}/tick.log")"; fi
if [ "$k3" = "$k2" ]; then ok "an unchanged count does not re-run the digest (generated_at alone changed)"; else bad "unchanged 12 re-ran the digest"; fi

# B. reader contract: the written profile -> real api_preferences -> real
#    _preferences_section -> non-empty Preferences lines.
lines="$(OSTLER_INTEREST_PROFILE="$PROFILE" PYTHONPYCACHEPREFIX="${WORK}/pycache" "$PY_BIN" - "$REPO_ROOT" <<'EOF' 2>"${WORK}/reader.err"
import importlib.util, sys
root = sys.argv[1]
sys.path.insert(0, root + "/vendor/cm041/assistant_api/tests")
import test_failed_conversation_auto_retry  # noqa: F401  installs the ostler_security stub
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod); return mod
hub = load("ical_server_for_digest", root + "/vendor/cm041/assistant_api/ical-server.py")
gen = load("generate_pwg_context_for_digest", root + "/context-refresh/bin/generate_pwg_context.py")
def get_json(path):
    if path.startswith("/api/v1/preferences"):
        return hub.api_preferences(limit=int(path.split("limit=")[1]))
    return None
gen._get_json = get_json
print(len(gen._preferences_section()))
EOF
)"
if [ "${lines:-0}" -gt 0 ] 2>/dev/null; then
    ok "the reader turns the written profile into ${lines} Preferences line(s)"
else
    bad "the reader produced '${lines}' Preferences lines from a 12-interest profile; stderr: $(tail -3 "${WORK}/reader.err")"
fi

# C. negative control: force the change-check false, the same 0 -> N must not kick.
MUT="${WORK}/mutant.sh"
sed 's/\[ "\$_new_n" != "\$_old_n" \]/[ 1 -eq 0 ]/' "$TICK" > "$MUT"
if grep -q '\[ 1 -eq 0 \]' "$MUT"; then
    : > "$CALLS"; rm -f "${OSTLER_DIR}/state/context-refresh-last-interest-count"
    run_tick "$MUT" 0; run_tick "$MUT" 7
    if [ "$(kicks)" = "0" ]; then ok "negative control: with the change-check forced false nothing kicks"; else bad "negative control kicked $(kicks) time(s): limb A proves nothing"; fi
else
    bad "negative control mutation did not apply"
fi

echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
