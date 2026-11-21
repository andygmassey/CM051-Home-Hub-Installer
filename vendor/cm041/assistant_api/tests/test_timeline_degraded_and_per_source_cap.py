"""CB136: a timeline source that fails is a named degraded state, and one large
source cannot starve the others out of the 200-row page.

Measured on the 135 walk box: the meeting query timed out, its error sentinel
carried no date, sorted last, and was cut by the newest-first slice, so the
page was empty. Photo days (one row per day, for years) filled the whole cap, so
meetings and conversations could never appear even when they worked.

ical-server.py is not importable (see test_timeline_sources.py), so the cap
function is extracted with ast and run. The wiring is checked on source.
Mutant: the plain newest-first slice. It must go red.
"""
from __future__ import annotations

import ast
import pathlib

SERVER_PY = pathlib.Path(__file__).resolve().parents[1] / "ical-server.py"


def _cap_fn(source: str):
    tree = ast.parse(source)
    fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "_cap_interleaved")
    ns: dict = {}
    exec(compile(ast.Module(body=[fn], type_ignores=[]), "cap", "exec"), ns)
    return ns["_cap_interleaved"]


def _rows():
    rows = [{"kind": "photos", "date": f"2026-11-{d:02d}", "summary": "p"} for d in range(1, 29)]
    rows += [{"kind": "photos", "date": f"2025-{m:02d}-01", "summary": "p"} for m in range(1, 13)]
    rows += [{"kind": "photos", "date": f"2024-{m:02d}-01", "summary": "p"} for m in range(1, 13)]
    # 200 photo days, then older meetings and conversations.
    rows += [{"kind": "photos", "date": f"2023-{m:02d}-{d:02d}", "summary": "p"}
             for m in range(1, 13) for d in range(1, 15)]
    rows += [{"kind": "meeting", "date": "2022-05-01", "summary": "Standup"},
             {"kind": "meeting", "date": "2022-04-01", "summary": "Review"},
             {"kind": "conversation", "date": "2022-03-01", "summary": "Chat"}]
    return rows


def test_meetings_and_conversations_survive_a_large_photo_source():
    cap = _cap_fn(SERVER_PY.read_text(encoding="utf-8"))
    out = cap(_rows(), 200)
    kinds = [r["kind"] for r in out]
    assert len(out) == 200
    assert "meeting" in kinds, "photo days must not starve the meetings"
    assert "conversation" in kinds, "photo days must not starve the conversations"


def test_each_source_keeps_its_own_newest_first_order():
    cap = _cap_fn(SERVER_PY.read_text(encoding="utf-8"))
    out = cap(_rows(), 200)
    meetings = [r["date"] for r in out if r["kind"] == "meeting"]
    assert meetings == sorted(meetings, reverse=True)


def test_the_output_is_newest_first_overall():
    cap = _cap_fn(SERVER_PY.read_text(encoding="utf-8"))
    out = cap(_rows(), 200)
    dates = [r["date"] for r in out]
    assert dates == sorted(dates, reverse=True)


def test_no_limit_returns_everything_newest_first():
    cap = _cap_fn(SERVER_PY.read_text(encoding="utf-8"))
    rows = _rows()
    assert len(cap(rows, 0)) == len(rows)


def test_wiring_degraded_state_is_named_not_dropped():
    src = SERVER_PY.read_text(encoding="utf-8")
    assert "_cap_interleaved(kept, limit, newest_first=not forward)" in src, "the cap must be the per-source one"
    assert "items = items[:limit]" not in src, "the plain newest-first slice must be gone"
    assert '"degraded": degraded_notices' in src, "a degraded source must be a named state on the response"
    assert '"type": "notice"' not in src, "a notice is not a timeline entry (entries carry a source)"


def test_mutant_plain_slice_is_caught():
    rows = _rows()
    plain = sorted(rows, key=lambda i: i.get("date") or "", reverse=True)[:200]
    assert not any(r["kind"] == "meeting" for r in plain), "the plain slice starves meetings"
    cap = _cap_fn(SERVER_PY.read_text(encoding="utf-8"))
    assert any(r["kind"] == "meeting" for r in cap(rows, 200))
