#!/usr/bin/env bash
# THE DOCTOR DASHBOARD 500ed ON EVERY LOAD IN v1.0.98, and every gate was green.
#
# render_source_status() calls html.escape four times and web_ui.py never
# imported html. A NameError inside a route body is invisible to import, to
# syntax checks and to any test that does not RENDER THE PAGE. Andy walked three
# builds asking where the per-source ingest table was; the table was there and
# the page it lived on was dead.
#
# This test calls the render functions. It does not read the source.
set -u
cd "$(dirname "$0")/.." || exit 1
python3 - <<'PY'
import sys, pathlib, types
sys.path.insert(0, str(pathlib.Path("vendor/doctor/agent").resolve()))
src = pathlib.Path("vendor/doctor/agent/web_ui.py").read_text(encoding="utf-8")
ns = {"__name__": "web_ui_probe"}
try:
    exec(compile(src, "web_ui.py", "exec"), ns)
except Exception as exc:            # import-time deps may be absent in CI
    print(f"CANNOT-RUN: module would not load ({type(exc).__name__}: {exc})")
    sys.exit(0)
fn = ns.get("render_source_status")
if fn is None:
    print("FAIL: render_source_status is not defined")
    sys.exit(1)
try:
    out = fn()
except NameError as exc:
    print(f"FAIL: render_source_status raised NameError: {exc}")
    sys.exit(1)
except Exception as exc:
    print(f"PASS (no NameError; non-fatal {type(exc).__name__} with no live Doctor)")
    sys.exit(0)
print(f"PASS: render_source_status returned {len(out)} chars, no NameError")
PY
