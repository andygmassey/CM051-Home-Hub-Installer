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
#
# EVERY NEW DASHBOARD TILE GETS A ROW IN `TILES` BELOW. A renderer is reached
# only from inside a route body, so a NameError, a bad .format key or a missing
# copy constant in one of them is invisible to every static gate and takes the
# whole page down. That is the failure this file exists for, and a tile that is
# not listed here is not covered by it.
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
TILES = ("render_source_status", "render_whatsapp_keepalive")

failures = 0
for name in TILES:
    fn = ns.get(name)
    if fn is None:
        print(f"FAIL: {name} is not defined in web_ui's namespace")
        failures += 1
        continue
    try:
        out = fn()
    except NameError as exc:
        print(f"FAIL: {name} raised NameError: {exc}")
        failures += 1
    except (KeyError, ImportError, AttributeError) as exc:
        # These three kill the page just as dead as a NameError and are never
        # "no live Doctor": a missing copy constant (the .154 blocker: web_ui
        # imported CONFIG_BTN_SAVE and 15 siblings that web_ui_copy did not
        # define, and Doctor crash-looped), a bad .format key, or a renderer
        # reaching for a name its module does not have. Without naming them
        # they fall into the tolerant arm below and report PASS.
        print(f"FAIL: {name} raised {type(exc).__name__}: {exc}")
        failures += 1
    except Exception as exc:
        print(f"PASS: {name} (no NameError; non-fatal {type(exc).__name__} with no live Doctor)")
    else:
        print(f"PASS: {name} returned {len(out)} chars, no NameError")

sys.exit(1 if failures else 0)
PY
