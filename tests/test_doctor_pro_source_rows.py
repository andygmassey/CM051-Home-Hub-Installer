"""Ostler Pro rows in the Doctor's "Where your data came from" table.

Spec: ~/walkdriver/PRO_DISCOVERABILITY_SPEC_2026-10-19.md. Pro sources are
listed with a Pro badge, but only once SHIPPED; entitlement comes from the G7
gate's --check exit code, and "could not ask" is never shown as locked.

Synthetic only: fake runners stand in for the gate subprocess; no real Hub,
no real home folder, no Keychain.

Run: ``python3 tests/test_doctor_pro_source_rows.py`` (bare, no deps) or pytest.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO / "vendor" / "doctor" / "agent"))

import pro_sources as ps  # noqa: E402

ALL = frozenset(cid for cid, _, _ in ps.PRO_CONNECTORS)


class _Done:
    def __init__(self, rc):
        self.returncode = rc


def _fresh():
    ps._cache["at"] = None
    ps._cache["value"] = None


def _gate_file(tmp):
    p = Path(tmp) / "subscription_gate.py"
    p.write_text("# stand-in; the runner is faked\n")
    return p


def test_nothing_ships_in_this_build():
    # No connector is wired yet, so none may be listed (no roadmap leaks).
    # A PR that adds one must update this test with its walk evidence.
    assert ps.SHIPPED_PRO_CONNECTORS == frozenset()
    for ent in (ps.ENT_ACTIVE, ps.ENT_PAUSED, ps.ENT_UNKNOWN):
        assert ps.pro_source_rows(ent) == []


def test_the_pro_set_is_andys_seven():
    names = [n for _, n, _ in ps.PRO_CONNECTORS]
    assert names == ["Jira", "Confluence", "Slack", "Google Chat", "Linear", "GitHub", "Notion"]


def test_no_pro_shows_what_it_does_and_where_to_upgrade():
    rows = ps.pro_source_rows(ps.ENT_PAUSED, shipped=frozenset({"jira"}))
    assert rows == [{
        "source": "jira", "name": "Jira", "state": "locked", "line": "Part of Ostler Pro",
        "detail": "Ask why a feature was parked: Ostler reads your Jira history. "
                  "Upgrade in the Ostler app on your iPhone.",
    }]


def test_pro_not_yet_connected():
    rows = ps.pro_source_rows(ps.ENT_ACTIVE, shipped=frozenset({"slack"}))
    assert [(r["state"], r["line"]) for r in rows] == [("not_connected", "Not connected yet")]


def test_unknown_is_never_locked_or_paused():
    rows = ps.pro_source_rows(ps.ENT_UNKNOWN, shipped=frozenset({"slack"}))
    assert [(r["state"], r["line"]) for r in rows] == [("unknown", "Could not check your Pro status")]
    rows = ps.pro_source_rows("something-new", shipped=frozenset({"slack"}))
    assert rows[0]["state"] == "unknown"


def test_a_connected_source_keeps_its_own_row():
    rows = ps.pro_source_rows(ps.ENT_ACTIVE, shipped=ALL, connected=frozenset({"slack"}))
    assert "slack" not in [r["source"] for r in rows]
    assert len(rows) == len(ALL) - 1


def test_rows_follow_table_order_and_only_shipped():
    rows = ps.pro_source_rows(ps.ENT_PAUSED, shipped=frozenset({"notion", "jira"}))
    assert [r["source"] for r in rows] == ["jira", "notion"]


def test_paused_row_keeps_data_readable():
    r = ps.paused_row("Slack")
    assert r["line"] == "Paused"
    assert r["detail"] == "What Ostler already read stays readable. Renew to keep syncing."


def test_gate_exit_codes_map_to_entitlement():
    with tempfile.TemporaryDirectory() as tmp:
        gate = _gate_file(tmp)
        for rc, want in ((0, ps.ENT_ACTIVE), (3, ps.ENT_PAUSED), (1, ps.ENT_UNKNOWN), (2, ps.ENT_UNKNOWN)):
            _fresh()
            seen = []
            got = ps.resolve_entitlement(gate, runner=lambda cmd, **kw: seen.append(cmd) or _Done(rc))
            assert got == want, (rc, got)
            assert seen and seen[0][-2:] == [str(gate), "--check"], seen


def test_a_gate_that_cannot_run_is_unknown():
    with tempfile.TemporaryDirectory() as tmp:
        gate = _gate_file(tmp)

        def boom(cmd, **kw):
            raise subprocess.TimeoutExpired(cmd, 10)

        _fresh()
        assert ps.resolve_entitlement(gate, runner=boom) == ps.ENT_UNKNOWN
        _fresh()
        called = []
        missing = Path(tmp) / "absent.py"
        assert ps.resolve_entitlement(missing, runner=lambda *a, **k: called.append(1)) == ps.ENT_UNKNOWN
        assert called == [], "a missing gate must not be executed"


def test_entitlement_is_cached_for_a_minute():
    with tempfile.TemporaryDirectory() as tmp:
        gate = _gate_file(tmp)
        calls = []
        t = [100.0]

        def run(cmd, **kw):
            calls.append(1)
            return _Done(0)

        _fresh()
        ps.resolve_entitlement(gate, runner=run, clock=lambda: t[0])
        t[0] += 30
        ps.resolve_entitlement(gate, runner=run, clock=lambda: t[0])
        assert len(calls) == 1
        t[0] += 31
        ps.resolve_entitlement(gate, runner=run, clock=lambda: t[0])
        assert len(calls) == 2


def test_html_row_has_badge_and_escapes():
    rows = ps.pro_source_rows(ps.ENT_PAUSED, shipped=frozenset({"jira"}))
    out = ps.render_pro_rows_html(rows)
    assert ">Pro</span>" in out and "Jira" in out and "Part of Ostler Pro" in out
    assert ps.render_pro_rows_html([{"name": "<b>", "line": "x", "detail": ""}]).count("&lt;b&gt;") == 1
    assert ps.render_pro_rows_html([]) == ""


def test_copy_rules():
    text = " ".join(e for _, _, e in ps.PRO_CONNECTORS) + ps.UPGRADE_LINE + ps.paused_row("x")["detail"]
    assert "—" not in text
    assert "recording" not in text.lower() and "companion" not in text.lower()


def test_web_ui_calls_pro_rows_only_when_shipped():
    # Source check, because web_ui needs fastapi to import: the table must
    # gate on the flag (no fork with an empty set) and must not swallow a
    # failure silently.
    src = (_REPO / "vendor" / "doctor" / "agent" / "web_ui.py").read_text()
    seg = src[src.index("def render_source_status"):]
    seg = seg[:seg.index("\ndef ")]
    assert "if pro_sources.SHIPPED_PRO_CONNECTORS:" in seg
    assert "Could not list the Ostler Pro" in seg


if __name__ == "__main__":
    n = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            n += 1
    print(f"ok: {n} tests")
