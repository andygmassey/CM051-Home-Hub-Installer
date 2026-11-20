"""CB136-HUB-DOCTOR-HYDRATION-502: the Doctor's hydration passthrough must not
time out on the composite the walk box actually serves.

The 135 walk saw GET /api/v1/hydration/status answer 502 "ReadTimeout" from the
Doctor (customer_read: "every GET a screen makes returns 2xx"). The upstream
composite took 4.3 s idle and more under walk load; the Doctor's own budget
was _HYDRATION_UPSTREAM_TIMEOUT_SECONDS = 5.0 (web_ui.py), so the panel poll
failed whenever the box was busy.

This test reads the budget from the source with ast (web_ui.py imports
fastapi and a dozen agent modules, which a walk CI job should not need) and
asserts that (a) the passthrough sends that budget to its httpx call and
(b) the budget is at least the measured floor. Mutant: restore 5.0 and it
goes red.
"""

from __future__ import annotations

import ast
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
WEB_UI = REPO / "vendor" / "doctor" / "agent" / "web_ui.py"
CONST = "_HYDRATION_UPSTREAM_TIMEOUT_SECONDS"
# Measured 2026-11-20 on the 135 walk box: 4.3 s idle, under a 5.0 s budget
# that already failed under load. A budget below 2x the idle measurement
# reproduces the 502.
MEASURED_IDLE_SECONDS = 4.3
FLOOR_SECONDS = 2 * MEASURED_IDLE_SECONDS


def _tree() -> ast.Module:
    return ast.parse(WEB_UI.read_text(encoding="utf-8"), filename=str(WEB_UI))


def _budget(tree: ast.Module) -> float:
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
            isinstance(t, ast.Name) and t.id == CONST for t in node.targets
        ):
            assert isinstance(node.value, ast.Constant), "budget must be a literal"
            return float(node.value.value)
    raise AssertionError(f"{CONST} is not defined in web_ui.py")


def _fetch_uses_budget(tree: ast.Module) -> bool:
    for node in ast.walk(tree):
        if isinstance(node, ast.AsyncFunctionDef) and node.name == "_fetch_hydration_status":
            return any(isinstance(n, ast.Name) and n.id == CONST for n in ast.walk(node))
    raise AssertionError("_fetch_hydration_status is not defined in web_ui.py")


def test_hydration_passthrough_sends_the_budget_it_declares():
    tree = _tree()
    assert _fetch_uses_budget(tree), "_fetch_hydration_status must pass the budget to httpx"


def test_hydration_budget_covers_the_measured_upstream_latency():
    budget = _budget(_tree())
    assert budget >= FLOOR_SECONDS, (
        f"{CONST}={budget}s is below the {FLOOR_SECONDS}s floor (2x the measured "
        f"{MEASURED_IDLE_SECONDS}s idle composite); a loaded box returns 502 ReadTimeout"
    )
