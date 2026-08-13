#!/usr/bin/env bash
# verify_doctor_governor_revendor.sh
#
# Guard for the doctor governor re-vendor (HR015 #282). Run AFTER a
# `sync_vendor.sh doctor` re-pin that adopts #282. Fails LOUD if the
# CM051 vendor-only Mac pause bridge was dropped by a blind --regen-patch,
# or if the native #282 pieces did not land.
#
# Recipe + rationale: vendor/divergences/GOVERNOR_REVENDOR_282.md
#
# SCOPE, read this before reading a FAIL (2026-08-14, v1018-D024). This script
# asserts a FULL #282 re-vendor, and that re-vendor HAS NOT HAPPENED. The pin
# is still b0b3831. What did happen is a narrow graft of #282's customer-facing
# half -- pause_control.py plus the four governor route handlers -- because the
# Hub Governor page's Pause button was 404ing on every install. So check 4's
# pause_control.py line now passes by GRAFT, not by re-pin, and check 4's
# build_env_map line still FAILS because the config_panel.py half of #282 was
# deliberately not adopted (task #633, the open v1.0 governor scope decision).
# That single FAIL is the honest state of the tree, not a regression: this
# script reported THREE before the graft and reports ONE after. Do not silence
# it to get a green; when the pin finally moves, the recipe closes it properly.
# The graft itself is gated by tests/test_doctor_governor_routes_vendored.sh.
#
# The failure it prevents: without daemon_cron.py the Doctor Settings Pause
# toggle raises ModuleNotFoundError -> HTTP 500 while governor.env is already
# written "paused" -- ticks look paused but the 09:00 brief / 18:00 wrap still
# fire (a ships-dark pause). daemon_cron.py is vendor-only and is stripped by
# `sync_vendor.sh doctor --regen-patch`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT="$ROOT/vendor/doctor/agent"
PATCH="$ROOT/vendor/divergences/doctor.patch"
fail=0

say()  { printf '%s\n' "$*"; }
ok()   { say "  ok   $*"; }
bad()  { say "  FAIL $*"; fail=1; }

say "== doctor governor re-vendor guard (HR015 #282) =="

# 1. vendor-only Mac pause bridge must survive the re-vendor
if [ -s "$AGENT/daemon_cron.py" ]; then ok "daemon_cron.py present (vendor-only Mac pause bridge)"
else bad "daemon_cron.py MISSING or empty -- blind --regen-patch stripped it; re-add the /dev/null new-file hunk to doctor.patch"; fi

grep -q 'def apply_pause_to_cron' "$AGENT/daemon_cron.py" 2>/dev/null \
  && ok "daemon_cron.apply_pause_to_cron present" \
  || bad "daemon_cron.apply_pause_to_cron MISSING (launchctl pause bridge gutted)"

grep -q 'launchctl' "$AGENT/daemon_cron.py" 2>/dev/null \
  && ok "daemon_cron launchctl kickstart present" \
  || bad "daemon_cron launchctl idiom MISSING"

# 2. config_panel.py must still import the bridge (else Pause toggle 500s)
grep -Eq 'from daemon_cron import .*apply_pause_to_cron' "$AGENT/config_panel.py" 2>/dev/null \
  && ok "config_panel imports daemon_cron.apply_pause_to_cron" \
  || bad "config_panel LOST the daemon_cron import -> Pause toggle would 500"

# 3. config_panel.py governor.env writer must survive
for sym in render_governor_env _write_governor_env; do
  grep -q "def $sym" "$AGENT/config_panel.py" 2>/dev/null \
    && ok "config_panel.$sym present" \
    || bad "config_panel.$sym MISSING (governor.env writer gutted)"
done

# 4. #282 native pieces must have landed
[ -s "$AGENT/pause_control.py" ] \
  && ok "pause_control.py present (grafted ahead of pin from #282, v1018-D024; native once the pin moves)" \
  || bad "pause_control.py MISSING -- the pause backend is gone, so the Governor Pause button 404s (v1018-D024)"

grep -q 'def build_env_map' "$AGENT/config_panel.py" 2>/dev/null \
  && ok "config-env-bridge (build_env_map) present (from #282)" \
  || bad "config-env-bridge MISSING -- #282 config_panel not adopted"

# 5. doctor.patch must still carry the vendor-only new-file hunk
grep -q 'daemon_cron.py' "$PATCH" 2>/dev/null \
  && ok "doctor.patch still references daemon_cron.py new-file hunk" \
  || bad "doctor.patch no longer carries daemon_cron.py -- it will vanish on next full sync"

say ""
if [ "$fail" -ne 0 ]; then
  say "RESULT: FAIL -- do NOT ship a #282 RE-VENDOR in this state."
  say "        If the pin is still b0b3831 no re-vendor has been attempted, and the"
  say "        expected residue is exactly ONE fail (config-env-bridge / build_env_map),"
  say "        which is the deliberately un-adopted half. See the SCOPE note at the top"
  say "        and vendor/divergences/GOVERNOR_REVENDOR_282.md."
  exit 1
fi
say "RESULT: PASS -- governor re-vendor preserved the vendor-only bridge and adopted #282 native pieces."
