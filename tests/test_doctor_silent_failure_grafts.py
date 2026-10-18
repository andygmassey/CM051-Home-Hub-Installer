#!/usr/bin/env python3
"""Four silent-failure grafts in the vendored Doctor must stay grafted.

WHY A GATE RATHER THAN A COMMENT

vendor/doctor is HELD at pin b0b38310 and will be for the life of v1.0
(vendor/divergences/doctor.patch applies at that pin with rc=0 and fails on
9-10 of 11 files at HR015 main, so a re-pin is a reconciliation project, not
a pin bump). Everything the vendored tree gains therefore arrives as a
hand-spliced graft, and a hand-spliced graft is exactly what the next full
``sync_vendor.sh doctor`` silently drops. Both fixes below are invisible
when lost: the panel keeps rendering, the tile keeps rendering, and the
output is wrong in the direction of "everything is fine".

=========================================================================
GRAFT A -- HR015 7feb3020: A HEALTH CHECK THAT CRASHED READ AS ONE THAT PASSED
=========================================================================

``run_all_rules`` wrapped each rule in ``except Exception: pass``. The
comment said individual rule failures should not crash diagnostics, which is
correct, and then it threw the failure away, which is not the same thing.

MEASURED on the vendored tree before the graft, by EXECUTING the shipped
rules rather than reading them -- 3 of 20 raised AttributeError on every
single run:

    check_memory_pressure   'SystemSnapshot' object has no attribute 'ram_total_gb'
    check_ollama_models     'SystemSnapshot' object has no attribute 'ram_total_gb'
    check_gdpr_export_age   'SystemSnapshot' object has no attribute 'last_import_date'

check_memory_pressure is the CRITICAL >90% rule. The Doctor panel has said
"Everything looks healthy" on every cut while never running it.

A FIXTURE BOUND, recorded because it nearly cost the finding: the first run
used an EMPTY snapshot and reported 2 of 20. check_ollama_models returns
early when there are no models, so it never reached ``ram_total_gb``.
Populating one model took it to 3. An empty fixture is not a neutral
fixture -- it silently under-counts anything guarded by a precondition, so
the snapshot below is POPULATED on purpose.

=========================================================================
GRAFT B -- HR015 ee511c2c: THE CONSENT TILE WENT SILENT
=========================================================================

``render_consent_status`` returned ``""`` for two different facts: "the
consent registry could not be read" and "you have not consented to anything
yet". Consent records are the Article 9 / EU legal surface, and a Hub whose
registry is unreadable looked exactly like a fresh pre-consent install.

That state is reachable on a real box: install.sh installs ostler_security
into the Hub venv with ``2>/dev/null || true``, so the install is tolerated
to fail silently, and the module's own comment at that site says as much.

EXIT CODES   0 all controls pass   1 a control failed   2 CANNOT-RUN
"""
import ast
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
AGENT = os.path.join(REPO, "vendor", "doctor", "agent")

PASS = FAIL = 0


def ok(msg):
    global PASS
    print(f"  PASS  {msg}")
    PASS += 1


def bad(msg):
    global FAIL
    print(f"  FAIL  {msg}")
    FAIL += 1


def cannot_run(msg):
    print(f"  CANNOT-RUN: {msg}")
    print("  A subject that cannot be loaded is not a subject that passed.")
    sys.exit(2)


print("doctor silent-failure grafts (vendored tree)")

if not os.path.isdir(AGENT):
    cannot_run(f"no vendored doctor agent dir at {AGENT}")

sys.path.insert(0, AGENT)

try:
    import status_collector as sc
    import diagnostic_rules as dr
    import dashboard_components as dc
except ModuleNotFoundError as exc:
    # httpx is a real runtime dependency of status_collector. Refusing is the
    # honest outcome: these controls are behavioural and a static stand-in
    # would measure the source text rather than what the module does.
    cannot_run(f"a dependency of the vendored modules is missing: {exc}. "
               "Install it (pip install httpx) and re-run.")
except Exception as exc:                     # noqa: BLE001 - report, never pass
    cannot_run(f"the vendored modules did not import: {type(exc).__name__}: {exc}")


# =========================================================================
# GRAFT A
# =========================================================================

# POPULATED, not empty. See the fixture-bound note in the docstring.
def _snapshot():
    model = sc.OllamaModelInfo(name="qwen3:8b", size_gb=5.2, quantisation="Q4")
    return sc.SystemSnapshot(
        timestamp="2026-01-01T00:00:00Z",
        hostname="box",
        os_version="15.4",
        ollama_models=[model],
        ollama_version="0.5.0",
        pwg_version="1.0.0",
        docker_version="27.0",
    )


RULE_FLOOR = 20     # measured on the shipped tree 2026-08-19

snap = _snapshot()
rules = list(dr.ALL_RULES)

if len(rules) >= RULE_FLOOR:
    ok(f"rule floor holds ({len(rules)} >= {RULE_FLOOR})")
else:
    bad(f"only {len(rules)} rules registered, floor is {RULE_FLOOR}. "
        "Deleting rules is not a way to stop them crashing.")

raised = []
for rule in rules:
    try:
        rule(snap)
    except Exception as exc:                 # noqa: BLE001 - that IS the finding
        raised.append((getattr(rule, "__name__", repr(rule)), type(exc).__name__, str(exc)))

if not raised:
    ok(f"all {len(rules)} rules RUN against a populated snapshot (0 raise)")
else:
    for name, kind, msg in raised:
        bad(f"rule {name} raises {kind}: {msg} -- it has never run on any install")

# The rules that were dead read these. Assert the fields exist AND that the
# collector populates them: a field nothing fills is the same dead rule with
# a different exception.
missing = [f for f in ("ram_total_gb", "ram_available_gb")
           if not hasattr(snap, f)]
if missing:
    bad(f"SystemSnapshot lacks {missing} -- the memory rules cannot run")
else:
    ok("SystemSnapshot carries ram_total_gb / ram_available_gb")

_src_sc = open(os.path.join(AGENT, "status_collector.py"), encoding="utf-8").read()
_tree_sc = ast.parse(_src_sc)
populated = False
for node in ast.walk(_tree_sc):
    if isinstance(node, ast.FunctionDef) and node.name == "collect_full_snapshot":
        populated = "ram_total_gb" in ast.dump(node)
        break
if populated:
    ok("collect_full_snapshot POPULATES the RAM fields (a field nothing fills is a dead rule with a new exception)")
else:
    bad("collect_full_snapshot never sets ram_total_gb -- the fields exist and stay None forever")

# POSITIVE CONTROL for the whole of Graft A. Feed run_all_rules a rule that
# provably raises and require the failure to reach the panel. Without this,
# "0 rules raise" would pass just as happily on the swallowing version.
def _always_raises(snapshot):
    raise RuntimeError("deliberate control failure")


_saved = list(dr.ALL_RULES)
try:
    dr.ALL_RULES.append(_always_raises)
    findings = dr.run_all_rules(snap)
finally:
    dr.ALL_RULES[:] = _saved

surfaced = [f for f in findings if "_always_raises" in str(f.get("title", "")) + str(f.get("detail", ""))]
if surfaced:
    ok("POSITIVE CONTROL: a rule that raises produces a VISIBLE finding, not silence")
else:
    bad("POSITIVE CONTROL FAILED: a rule that raises is swallowed. The panel reports "
        "'everything looks healthy' over a check that did not run.")

# Structural backstop: the bare `pass` must not come back. Behavioural
# controls can be defeated by a handler that logs and then swallows; this
# one names the exact shape that shipped.
swallows = False
_tree_dr = ast.parse(open(os.path.join(AGENT, "diagnostic_rules.py"), encoding="utf-8").read())
for node in ast.walk(_tree_dr):
    if not (isinstance(node, ast.FunctionDef) and node.name == "run_all_rules"):
        continue
    for handler in [n for n in ast.walk(node) if isinstance(n, ast.ExceptHandler)]:
        if all(isinstance(stmt, ast.Pass) for stmt in handler.body):
            swallows = True
    break
if swallows:
    bad("run_all_rules still has a bare `except: pass` -- a crashed rule is indistinguishable from a passing one")
else:
    ok("run_all_rules has no bare `except: pass`")

# HR015 967f6608's class, folded into this graft rather than imported with
# it: upstream wrote `log.warning` in collect_memory against a name nothing
# bound, so all four of its error paths raised NameError instead of warning.
_module_names = {t.id for n in ast.walk(_tree_sc) if isinstance(n, ast.Assign)
                 for t in n.targets if isinstance(t, ast.Name)}
_unbound = set()
for node in ast.walk(_tree_sc):
    if (isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name)
            and node.value.id in ("log", "logger")
            and node.value.id not in _module_names):
        _unbound.add(node.value.id)
if _unbound:
    bad(f"status_collector calls {sorted(_unbound)}.* but never binds it -- every error path "
        "raises NameError instead of warning (HR015 967f6608)")
else:
    ok("every logger the collectors call is bound at module scope")


# =========================================================================
# GRAFT B
# =========================================================================

if not hasattr(dc, "_resolve_consent_registry"):
    bad("_resolve_consent_registry absent -- the consent tile still decides readability once, "
        "at first import, and can never recover")
else:
    ok("_resolve_consent_registry present (readability is re-derived per call, not frozen at import)")

    # DEGRADED ARM. Force the real import to fail, which is the same event
    # production sees, rather than poking the _HAS_CONSENT flag -- a flag the
    # code is allowed to re-derive is not a fault-injection point.
    _saved_import = dc._import_consent_registry
    _saved_flag = dc._HAS_CONSENT
    try:
        def _boom():
            raise ImportError("no module named ostler_security (control)")
        dc._import_consent_registry = _boom
        dc._HAS_CONSENT = False
        degraded = dc.render_consent_status()
    finally:
        dc._import_consent_registry = _saved_import
        dc._HAS_CONSENT = _saved_flag

    from web_ui_copy import CONSENT_UNREADABLE_TITLE

    if degraded.strip() and CONSENT_UNREADABLE_TITLE in degraded:
        ok("an UNREADABLE consent registry renders a visible tile, not an empty string")
    else:
        bad("an unreadable consent registry renders as nothing at all, which is byte-identical "
            "to 'you have not consented to anything yet'. Two different facts, one output, on "
            "the Article 9 surface.")

    # NEGATIVE CONTROL. If the degraded arm rendered unconditionally the
    # control above would pass while telling us nothing. A readable registry
    # with no records must still render EMPTY.
    _saved_all = dc.all_consents
    _saved_flag = dc._HAS_CONSENT
    try:
        dc.all_consents = lambda: {}
        dc._HAS_CONSENT = True
        empty = dc.render_consent_status()
    finally:
        dc.all_consents = _saved_all
        dc._HAS_CONSENT = _saved_flag

    if empty.strip() == "":
        ok("NEGATIVE CONTROL: a READABLE but empty registry still renders nothing (the tile is not unconditional)")
    else:
        bad("NEGATIVE CONTROL FAILED: the tile renders even when the registry is readable and empty, "
            "so the degraded-arm control above proves nothing")



# =========================================================================
# GRAFT C -- HR015 7328c33e: AN UNREACHABLE ENGINE READ AS A HEALTHY STACK
# =========================================================================
#
# collect_docker_containers() returns (containers, error). The caller bound
# the error to `_docker_err` and dropped it, so SystemSnapshot carried no
# record that the query had failed at all. Every per-container arm of
# check_container_health loops snapshot.docker_containers, so an empty list
# runs zero bodies and contributes zero findings -- byte-identical to a
# healthy stack. Reachable after ANY reboot: Colima has no autostart.
#
# The two controls below are deliberately opposed. The first proves the rule
# FIRES on the defect. The second proves it does NOT fire when the engine is
# genuinely reachable and simply has nothing running, because a rule that
# fired unconditionally would pass the first control while meaning nothing.

def _snapshot_no_containers(docker_error):
    snap = _snapshot()
    snap.docker_containers = []
    snap.docker_error = docker_error
    return snap


if not hasattr(sc.SystemSnapshot(), "docker_error"):
    bad("SystemSnapshot has no docker_error field, so the collector's error is "
        "still being discarded by the caller. Graft C is not present.")
else:
    ok("SystemSnapshot carries docker_error (the collector's error survives the call)")

    engine_down = dr.check_container_health(_snapshot_no_containers(
        "Cannot connect to the Docker daemon at unix:///var/run/docker.sock"))
    if engine_down:
        ok(f"an unreachable engine with zero containers yields {len(engine_down)} finding(s), not silence")
    else:
        bad("`docker ps` failed and the container rule produced NOTHING. A box with every "
            "store gone renders exactly like a healthy one -- absence read as health.")

    # NEGATIVE CONTROL: reachable engine, nothing running. Must stay silent.
    engine_idle = dr.check_container_health(_snapshot_no_containers(None))
    if not engine_idle:
        ok("NEGATIVE CONTROL: a REACHABLE engine with zero containers stays silent "
           "(the arm keys on the error, not on the empty list)")
    else:
        bad("NEGATIVE CONTROL FAILED: the rule fires when the engine is reachable and merely "
            "idle, so the control above proves nothing about the unreachable case.")


# =========================================================================
# GRAFT D -- v1.0.107 walk #5 item 1: A BLOCKING BOX-STATUS CALL STARVED
# EVERY OTHER ROUTE ON THE DOCTOR'S ONE EVENT LOOP
# =========================================================================
#
# The Hub header pill read "Status unavailable" on every route except Home
# (Bursar, People, Personal wiki). Doctor's own access log showed 200 OK for
# every logged /api/v1/box-status call -- the server never errored, so the
# symptom is the CLIENT's 15s fetch timing out.
#
# api_box_status() is `async def` but called its aggregator directly:
# `return _box_status()`. box_status.py's own "FORK BUDGET" comment already
# documents that `top -l 2` "BLOCKS FOR ABOUT A SECOND" on a cache miss, and
# its other probes carry their own subprocess timeouts (3s/3s/4s/6s/5s).
# uvicorn runs ONE event loop for the whole Doctor process; a synchronous
# call inside an `async def` handler blocks THAT LOOP, not just its own
# request -- every other concurrent /api/v1/* request the Doctor is holding
# stalls with it, including a DIFFERENT TAB'S OWN box-status poll. Measured
# on macmini16-walk: a cache-miss box-status call took 1.43s against a
# ~0.03s cache hit; the chained probe timeouts reach past the Hub's 15s
# client fetch timeout in the worst case. People/Wiki/Bursar each add their
# own concurrent Doctor requests on top of the chip's poll, which is why the
# stall landed on those routes and not the lighter Home route.
#
# Fix: run the aggregator via `asyncio.to_thread` so a slow or cache-missed
# probe no longer blocks the loop every other concurrent request shares.

_wu_path = os.path.join(AGENT, "web_ui.py")
if not os.path.isfile(_wu_path):
    bad(f"no {_wu_path} -- Graft D cannot even be located")
else:
    _src_wu = open(_wu_path, encoding="utf-8").read()
    try:
        _tree_wu = ast.parse(_src_wu)
    except SyntaxError as exc:
        cannot_run(f"web_ui.py did not parse: {exc}")

    _api_box_status_node = None
    for node in ast.walk(_tree_wu):
        if isinstance(node, ast.AsyncFunctionDef) and node.name == "api_box_status":
            _api_box_status_node = node
            break

    if _api_box_status_node is None:
        bad("api_box_status not found in web_ui.py -- Graft D cannot even be located")
    else:
        _api_box_status_src = ast.get_source_segment(_src_wu, _api_box_status_node) or ""

        if "asyncio.to_thread" not in _api_box_status_src:
            bad("api_box_status calls its aggregator directly, not through "
                "asyncio.to_thread -- a slow box_status() call (subprocess cache "
                "miss) blocks EVERY concurrent /api/v1/* request on the Doctor's "
                "one event loop, which is how a page that merely adds its own "
                "concurrent requests (People, Wiki, Bursar) can starve a "
                "different tab's box-status poll into the client's 15s timeout")
        else:
            ok("api_box_status runs its aggregator via asyncio.to_thread "
               "(does not block the shared event loop)")

            # BEHAVIOURAL CONTROL: exec the REAL shipped function (decorator
            # stripped -- it references `app`/`JSONResponse`, neither of which
            # this control needs or stubs) and prove a slow aggregator no
            # longer starves a concurrent coroutine on the same loop. Stub
            # `box_status` in sys.modules so the function's own
            # `from box_status import box_status as _box_status` resolves to a
            # synchronous stand-in that blocks for a fixed, measured duration
            # -- the same shape as a real subprocess.run() cache miss --
            # without shelling out to anything.
            import asyncio
            import time
            import types

            BLOCK_SECONDS = 0.25

            def _slow_box_status():
                time.sleep(BLOCK_SECONDS)
                return {"state": "busy"}

            _stub_mod = types.ModuleType("box_status")
            _stub_mod.box_status = _slow_box_status
            _saved_mod = sys.modules.get("box_status")
            sys.modules["box_status"] = _stub_mod

            # Strip the FastAPI decorator (`@app.get(...)`) before exec: it
            # references `app`/`JSONResponse`, neither of which this control
            # needs or stubs, and the function body references neither.
            _api_box_status_node.decorator_list = []

            try:
                _ns = {"asyncio": asyncio}
                exec(compile(ast.Module(body=[_api_box_status_node], type_ignores=[]),
                             "<api_box_status>", "exec"), _ns)
                _api_box_status = _ns["api_box_status"]

                async def _heartbeat():
                    start = time.monotonic()
                    # A starved loop cannot resume this until the blocking
                    # aggregator call returns.
                    await asyncio.sleep(0)
                    return time.monotonic() - start

                async def _race():
                    return await asyncio.gather(_api_box_status(), _heartbeat())

                _result, _heartbeat_elapsed = asyncio.run(_race())
            finally:
                if _saved_mod is not None:
                    sys.modules["box_status"] = _saved_mod
                else:
                    del sys.modules["box_status"]

            STARVE_FLOOR = BLOCK_SECONDS * 0.5  # a starved loop delays it by ~BLOCK_SECONDS
            if _heartbeat_elapsed < STARVE_FLOOR:
                ok(f"BEHAVIOURAL: a concurrent coroutine resumed in "
                   f"{_heartbeat_elapsed * 1000:.0f}ms while the REAL, shipped "
                   f"api_box_status ran a {BLOCK_SECONDS * 1000:.0f}ms blocking "
                   "aggregator call -- the event loop was not starved")
            else:
                bad(f"BEHAVIOURAL FAILED: a concurrent coroutine took "
                    f"{_heartbeat_elapsed * 1000:.0f}ms to resume against a "
                    f"{BLOCK_SECONDS * 1000:.0f}ms blocking aggregator call -- "
                    "the shipped api_box_status is still starving the shared "
                    "event loop")

            # CONTROL: the stubbed aggregator itself must actually have taken
            # ~BLOCK_SECONDS -- otherwise the behavioural check above could
            # pass for the trivial reason that nothing slow ever ran.
            if _result is not None and isinstance(_result, dict) and _result.get("state") == "busy":
                ok("CONTROL: the stubbed slow aggregator did run (result reached "
                   "the caller), so the behavioural check above measured a real "
                   "race, not a no-op")
            else:
                bad(f"CONTROL FAILED: api_box_status returned {_result!r}, not the "
                    "stub's result -- the behavioural check above proves nothing")

print(f"\n=== {PASS} passed / {FAIL} failed ===")
sys.exit(1 if FAIL else 0)
