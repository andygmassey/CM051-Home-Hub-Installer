#!/usr/bin/env bash
#
# tests/test_an_import_reaches_the_digest_straight_away.sh
#
# smart-prefs P1. Preferences reached the digest and the assistant's
# pwg_preferences tool only at the next hourly editor-frontpage tick, because
# nothing told the interest-profile compile that an import had finished.
#
# Writer : editor-frontpage-tick.sh compiles ~/.ostler/preferences/
#          interest_profile.json, then kickstarts context-refresh when the
#          interest count changes.
# Reader : ical-server api_preferences (pwg_preferences) and
#          generate_pwg_context._preferences_section (the digest).
# Trigger: the REAL generated ostler-import (the IMPORTEOF heredoc extracted
#          from install.sh) must kickstart the compile when it finishes.
#
# Launchd is faked: the stub launchctl runs the REAL tick (rendered, with a
# synthetic compile stub) when its label is kickstarted, and records every
# kickstart. Nothing here touches the real session. Synthetic data only.
#
#   arm A  RED on main: after ostler-import returns, with no hourly tick, the
#          profile holds interests, the digest has Preferences lines and the
#          assistant tool serves them
#   arm B  the derive agent is kicked as well
#   arm C  control: the same harness with a manual tick (the hourly path)
#          does fill the profile, so arm A can only be red for the trigger
#   arm D  mutant: ostler-import's compile kick removed -> arm A goes red
#
# Runs under bash 3.2.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"
TICK="${REPO}/vendor/cm059_editor/bin/editor-frontpage-tick.sh"
FRONTPAGE_LABEL="com.creativemachines.ostler.editor-frontpage"
DIGEST_LABEL="com.creativemachines.ostler.context-refresh"
DERIVE_LABEL="com.ostler.derive-preferences"
PY="$(command -v python3 || true)"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
cannot() { echo "CANNOT-RUN: $*" >&2; exit 2; }

echo "test_an_import_reaches_the_digest_straight_away"
[ -n "$PY" ] && [ -f "$TICK" ] && [ -f "$INSTALL_SH" ] || cannot "python3, the tick or install.sh is missing"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

awk '/cat > "\$IMPORT_SCRIPT" <<.IMPORTEOF./{f=1;next} f&&/^IMPORTEOF$/{exit} f{print}' "$INSTALL_SH" > "$WORK/ostler-import.orig"
/usr/bin/grep -q 'services.enrich.src.cli enrich' "$WORK/ostler-import.orig" || cannot "could not extract ostler-import from install.sh"

# One scratch box per arm: $1 = ostler-import variant file.
build_box() {
    BOX="$WORK/box.$1"; H="$BOX/home"; OD="$H/.ostler"
    SRC="$BOX/cm059"; STUB="$BOX/stub"; CALLS="$BOX/launchctl.log"
    PROFILE="$OD/preferences/interest_profile.json"
    mkdir -p "$OD/preferences" "$OD/state" "$OD/config" "$OD/bin" "$OD/services/cm019/.venv/bin" \
             "$SRC/compiler" "$STUB" "$BOX/exports/synthetic"
    : > "$BOX/exports/synthetic/placeholder.json"
    : > "$CALLS"
    : > "$SRC/compiler/__init__.py"
    printf 'import sys\nsys.exit(0)\n' > "$SRC/compiler/emit_frontpage.py"
    cat > "$SRC/compiler/emit_artefact.py" <<'PYEOF'
import json, os, time
subjects = ["Sea kayaking", "Sourdough baking", "Jazz piano", "Fell running", "Board games"]
items = [{"id": "i%d" % i, "subject": subjects[i % 5] + (" %d" % i if i >= 5 else ""),
          "domain": "hobbies", "polarity": "like", "privacy": "L2" if i % 2 else "L1",
          "score": float(12 - i), "confidence": 0.8, "sources": ["synthetic"]} for i in range(12)]
with open(os.environ["OSTLER_INTEREST_PROFILE"], "w") as fh:
    json.dump({"schema_version": 1, "generated_at": str(time.time()), "interests": items}, fh)
PYEOF
    # The CM019 venv python: every leg exits 0.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$OD/services/cm019/.venv/bin/python"
    chmod +x "$OD/services/cm019/.venv/bin/python"
    printf 'OSTLER_CONSENT_ENRICHMENT_DECISION="declined"\n' > "$OD/config/.env"
    sed -e "s#__OSTLER_PYTHON__#${PY}#" -e "s#__OSTLER_SOURCE_DIR__#${SRC}#" "$TICK" > "$BOX/tick.sh"
    chmod +x "$BOX/tick.sh"
    # Fake launchd. `print` says every label is loaded. `kickstart` records the
    # label and runs the REAL tick for the front-page label (detached, like
    # launchd would) and the extracted derive wrapper for the derive label.
    cat > "$STUB/launchctl" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALLS"
case "\$1" in
    print) exit 0 ;;
    kickstart)
        case "\$*" in
            *${FRONTPAGE_LABEL}*)
                ( OSTLER_DIR="$OD" OSTLER_RESOURCE_GOVERNOR=0 OSTLER_INTEREST_PROFILE="$PROFILE" \
                  PYTHONPYCACHEPREFIX="$BOX/pycache" PATH="$STUB:\$PATH" "$BOX/tick.sh" >>"$BOX/tick.log" 2>&1 ) & ;;
        esac
        exit 0 ;;
esac
exit 0
STUBEOF
    chmod +x "$STUB/launchctl"
}

run_import() {  # $1 = ostler-import file
    cp "$1" "$BOX/ostler-import"; chmod +x "$BOX/ostler-import"
    HOME="$H" PATH="$STUB:$PATH" "$BOX/ostler-import" "$BOX/exports" --user-name "Jane Doe" --user-id jane >"$BOX/import.log" 2>&1
}

wait_for() {  # $1 = file to have >0 interests, up to 20s
    local i=0
    while [ "$i" -lt 40 ]; do
        if [ -f "$1" ] && [ "$("$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("interests") or []))' "$1" 2>/dev/null || echo 0)" -gt 0 ]; then return 0; fi
        sleep 0.5; i=$((i+1))
    done
    return 1
}

reader_lines() {  # digest Preferences lines via the real hub reader + real digest section
    OSTLER_INTEREST_PROFILE="$PROFILE" PYTHONPYCACHEPREFIX="$BOX/pycache" "$PY" - "$REPO" <<'PYEOF' 2>"$BOX/reader.err"
import importlib.util, sys
root = sys.argv[1]
sys.path.insert(0, root + "/vendor/cm041/assistant_api/tests")
import test_failed_conversation_auto_retry  # noqa: F401  installs the ostler_security stub
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod); return mod
hub = load("ical_server_for_p1", root + "/vendor/cm041/assistant_api/ical-server.py")
gen = load("generate_pwg_context_for_p1", root + "/context-refresh/bin/generate_pwg_context.py")
served = hub.api_preferences(limit=50)
def get_json(path):
    return hub.api_preferences(limit=int(path.split("limit=")[1])) if path.startswith("/api/v1/preferences") else None
gen._get_json = get_json
print(len(gen._preferences_section()), len((served or {}).get("interests") or []))
PYEOF
}

# ---- arm A: the import itself reaches the digest -----------------------------
build_box A
run_import "$WORK/ostler-import.orig"
if wait_for "$PROFILE"; then
    set -- $(reader_lines); dl="${1:-0}"; tl="${2:-0}"
    if [ "$dl" -gt 0 ] && [ "$tl" -gt 0 ]; then
        ok "A: right after ostler-import, no hourly tick: digest has ${dl} Preferences line(s), pwg_preferences serves ${tl}"
    else
        bad "A: profile written but digest lines='${dl}' tool interests='${tl}' ($(tail -2 "$BOX/reader.err" | tr '\n' ' '))"
    fi
else
    bad "A: ostler-import returned and the interest profile is still absent/empty after 20s: preferences wait for the hourly tick"
fi
if /usr/bin/grep -q "kickstart .*${DIGEST_LABEL}" "$CALLS"; then
    ok "A: the digest (${DIGEST_LABEL}) was kickstarted by the compile's own count-change rule"
else
    bad "A: the digest was never kickstarted after the import"
fi

# ---- arm B: the derive agent is kicked too ---------------------------------
if /usr/bin/grep -q "kickstart .*${DERIVE_LABEL}" "$CALLS"; then
    ok "B: ostler-import kickstarts ${DERIVE_LABEL} (the \"What you like\" graph refreshes after an import)"
else
    bad "B: ostler-import never kickstarts ${DERIVE_LABEL}"
fi

# ---- arm C: control, the hourly path fills the same profile ------------------
build_box C
( OSTLER_DIR="$OD" OSTLER_RESOURCE_GOVERNOR=0 OSTLER_INTEREST_PROFILE="$PROFILE" PYTHONPYCACHEPREFIX="$BOX/pycache" PATH="$STUB:$PATH" "$BOX/tick.sh" >>"$BOX/tick.log" 2>&1 )
if wait_for "$PROFILE"; then ok "C: control: a manual tick fills the profile, so arm A can only be red for the missing trigger"; else bad "C: control failed: even a manual tick left the profile empty ($(tail -2 "$BOX/tick.log" | tr '\n' ' '))"; fi

# ---- arm D: mutant, remove the compile kick from ostler-import ---------------
sed -e "/${FRONTPAGE_LABEL}/d" "$WORK/ostler-import.orig" > "$WORK/ostler-import.mut"
if cmp -s "$WORK/ostler-import.orig" "$WORK/ostler-import.mut"; then
    bad "D: mutant did not apply (no front-page label in ostler-import)"
else
    build_box D
    run_import "$WORK/ostler-import.mut"
    if wait_for "$PROFILE"; then bad "D: mutant (compile kick removed) still filled the profile: arm A proves nothing"; else ok "D: mutant: with the compile kick removed the profile stays empty (arm A can go red)"; fi
fi

echo "  $pass passed, $fail failed (4 scratch boxes, real tick, real ostler-import, real hub reader and digest section)"
[ "$fail" -eq 0 ]
