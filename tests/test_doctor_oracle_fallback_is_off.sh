#!/usr/bin/env bash
# The Doctor's tokenless loopback-read fallback must be OFF on every install.
#
# Why: install.sh tailscale-serves the Doctor's :8089 as raw TCP, so every
# device on the owner's tailnet arrives as 127.0.0.1.
# vendor/doctor/agent/proxy.py _local_fallback_allowed lets a loopback caller
# with NO token do GET/HEAD whenever the gateway's bearer oracle looks absent
# (a 404/405 on POST /internal/validate-bearer). A gateway regression on that
# one route would therefore hand owner-data reads to every tailnet device.
# install.sh sets OSTLER_DOCTOR_ORACLE_FALLBACK=0 in the Doctor plist, and
# proxy.py honours it.
#
# Arms:
#   1. the Doctor plist block in install.sh carries the key with value 0
#   2. with the oracle ABSENT, a tokenless loopback GET is REFUSED when the
#      variable is 0 (the shipped setting)
#   3. CONTROL: the same request is ALLOWED when the variable is unset, so
#      arm 2 measures the variable and not something else
#   4. with the variable at 0, a POST without the admin token is refused
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

# Arm 1: inside the Doctor plist heredoc only.
# From the DOCTOR_PLIST assignment to the FIRST </plist> after it: the
# Doctor's own plist and nothing later, so a key in another plist can't pass.
block=$(awk '/DOCTOR_PLIST="\$\{HOME\}\/Library\/LaunchAgents\/com.ostler.doctor.plist"/{on=1} on{print} on&&/<\/plist>/{exit}' install.sh)
if [ -z "$block" ]; then
    bad "arm 1: could not find the Doctor plist block in install.sh (CANNOT-RUN is not a pass)"
elif printf '%s\n' "$block" | /usr/bin/grep -A1 '<key>OSTLER_DOCTOR_ORACLE_FALLBACK</key>' | /usr/bin/grep -q '<string>0</string>'; then
    ok "arm 1: Doctor plist sets OSTLER_DOCTOR_ORACLE_FALLBACK=0"
else
    bad "arm 1: Doctor plist does not set OSTLER_DOCTOR_ORACLE_FALLBACK=0"
fi

# Arms 2-4: drive the real function with stubbed web modules.
python3 - <<'PY' || fail=1
import importlib.util, os, sys, types
fa = types.ModuleType("fastapi")
class _Any:
    def __init__(self, *a, **k): pass
fa.FastAPI = fa.Request = fa.Response = _Any
sys.modules["fastapi"] = fa
sys.modules.setdefault("httpx", types.ModuleType("httpx"))
sys.modules["httpx"].AsyncClient = _Any
spec = importlib.util.spec_from_file_location("proxy", "vendor/doctor/agent/proxy.py")
proxy = importlib.util.module_from_spec(spec); spec.loader.exec_module(proxy)

class Req:
    def __init__(self, method):
        self.method = method
        self.client = types.SimpleNamespace(host="127.0.0.1")

proxy._ORACLE_STATE["absent"] = True
rc = 0
def check(label, got, want):
    global rc
    print(("ok   " if got == want else "FAIL ") + f"{label}: got {got}, want {want}")
    if got != want: rc = 1

os.environ["OSTLER_DOCTOR_ORACLE_FALLBACK"] = "0"
check("arm 2: oracle absent, var=0, tokenless loopback GET", proxy._local_fallback_allowed(Req("GET"), ""), False)
os.environ.pop("OSTLER_DOCTOR_ORACLE_FALLBACK")
check("arm 3 (control): oracle absent, var unset, tokenless loopback GET", proxy._local_fallback_allowed(Req("GET"), ""), True)
os.environ["OSTLER_DOCTOR_ORACLE_FALLBACK"] = "0"
check("arm 4: var=0 still refuses a POST without the admin token", proxy._local_fallback_allowed(Req("POST"), ""), False)
sys.exit(rc)
PY

[ "$fail" -eq 0 ] && echo "ALL ARMS PASSED" || echo "FAILED"
exit "$fail"
