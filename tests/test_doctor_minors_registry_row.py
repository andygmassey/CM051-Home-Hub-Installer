"""The Doctor says so when the owner's under-18 list cannot be read.

The owner 2026-10-19 (project_minors_flag). The ingest reads the owner's under-18
list (``~/.ostler/minors.json``, env ``OSTLER_MINORS_FILE``) on every import and
FAILS CLOSED: a file that is present but unreadable stops imports, because
"unknown" must not be read as "nobody is a child". Imports stopping with no word
anywhere is a silent outage, so ``check_minors_registry`` raises a row.

The shapes below mirror PWG ``MinorsRegistry.load`` at e98630a3 (``json.loads``
then ``data["minors"]`` then must be a list; anything raising is "unreadable").
The cross-repo agreement is shown in the PR body (both loaders run over every
shape here); this file pins the Doctor side.

PRIVACY: the file holds children's names. Nothing from it may reach a finding,
the support bundle (raw or redacted), the mailto, or a log line. Synthetic names
only.

Runs under pytest (HR015 doctor/agent suite) or bare in CM051 (``python3 <file>``).
"""
from __future__ import annotations

import ast
import json
import logging
import sys
from pathlib import Path

import pytest

_HERE = Path(__file__).resolve().parent
AGENT = _HERE if (_HERE / "diagnostic_rules.py").exists() else _HERE.parent / "vendor" / "doctor" / "agent"
sys.path.insert(0, str(AGENT))

import diagnostic_rules as D  # noqa: E402
import diagnostic_copy as C  # noqa: E402

TITLE = "Your under-18 list can't be read, so imports are paused until it's fixed"
NAMES = ["Sam Jones", "Jane Smith", "sam.jones@example.test", "+447700900123", "@sam_jones_kid"]

VALID_ENTRY = {"slug": "sam-jones", "names": [NAMES[0]], "identifiers": NAMES[2:]}
VALID = {
    "empty_list": '{"version": 1, "minors": []}',
    "one_minor": json.dumps({"version": 1, "minors": [VALID_ENTRY]}),
    "no_version": json.dumps({"minors": [VALID_ENTRY]}),
    "entry_without_names": '{"minors": [{"slug": "sam-jones"}]}',
}
CORRUPT = {
    "empty_file": "",
    "not_json": "{",
    "truncated_with_names": '{"version": 1, "minors": [{"slug": "sam-jones", "names": ["Sam Jones", "Jane Smith"',
    "json_list": "[]",
    "json_string": '"minors"',
    "json_null": "null",
    "json_number": "3",
    "no_minors_key": '{"version": 1}',
    "minors_null": '{"minors": null}',
    "minors_object": '{"minors": {"names": ["Sam Jones"]}}',
    "minors_string": '{"minors": "Sam Jones"}',
    "minors_empty_object": '{"minors": {}}',
    "minors_empty_string": '{"minors": ""}',
    "entry_is_a_string": '{"minors": ["Sam Jones"]}',
    "entry_is_a_list": '{"minors": [["Sam Jones"]]}',
    "names_is_a_number": '{"minors": [{"slug": "sam-jones", "names": 7}]}',
    "identifiers_is_null": '{"minors": [{"slug": "sam-jones", "identifiers": null}]}',
}


@pytest.fixture
def reg(tmp_path, monkeypatch):
    p = tmp_path / "minors.json"
    monkeypatch.setenv("OSTLER_MINORS_FILE", str(p))
    return p


def _rows(findings):
    return [f for f in findings if f.get("title") == TITLE]


def test_title_is_exact():
    assert C.MINORS_UNREADABLE_TITLE == TITLE


def test_rule_is_registered():
    assert D.check_minors_registry in D.ALL_RULES


def test_absent_file_is_no_row(reg):
    assert not reg.exists()
    assert D.check_minors_registry(None) == []
    assert _rows(D.run_all_rules(_snap())) == []


@pytest.mark.parametrize("name", sorted(VALID))
def test_valid_file_is_no_row(reg, name):
    reg.write_text(VALID[name])
    assert D.check_minors_registry(None) == []
    assert _rows(D.run_all_rules(_snap())) == []


@pytest.mark.parametrize("name", sorted(CORRUPT))
def test_corrupt_file_raises_a_critical_row_through_the_real_engine(reg, name):
    reg.write_text(CORRUPT[name])
    rows = _rows(D.run_all_rules(_snap()))
    assert len(rows) == 1, name
    row = rows[0]
    assert row["severity"] == "critical"
    assert row["category"] == "privacy"
    assert row["fix"] and row["fix_command"].startswith("mv -- ")
    assert str(reg) in row["fix_command"]


def test_non_utf8_and_directory_are_corrupt(reg):
    reg.write_bytes(b"\xff\xfe\x00{")
    assert len(_rows(D.run_all_rules(_snap()))) == 1
    reg.unlink()
    reg.mkdir()
    assert len(_rows(D.run_all_rules(_snap()))) == 1


def test_fix_command_survives_a_path_with_a_space(tmp_path, monkeypatch):
    p = tmp_path / "my dir" / "minors.json"
    p.parent.mkdir()
    p.write_text("{")
    monkeypatch.setenv("OSTLER_MINORS_FILE", str(p))
    cmd = D.check_minors_registry(None)[0]["fix_command"]
    import shlex
    parts = shlex.split(cmd.replace("$(date +%Y%m%d-%H%M%S)", "STAMP"))
    assert parts[:2] == ["mv", "--"] and parts[2] == str(p) and parts[3] == str(p) + ".unreadable-STAMP"


def test_default_path_is_home_dot_ostler(tmp_path, monkeypatch):
    monkeypatch.delenv("OSTLER_MINORS_FILE", raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))
    assert D._minors_registry_path() == tmp_path / ".ostler" / "minors.json"


# ── privacy ──────────────────────────────────────────────────────────


def _snap():
    from status_collector import SystemSnapshot
    return SystemSnapshot()


def _bundle(monkeypatch):
    import web_ui
    monkeypatch.setattr(web_ui, "collect_full_snapshot", lambda *a, **k: _snap())
    return web_ui._run_diagnostics()


@pytest.mark.parametrize("name", sorted(VALID) + sorted(CORRUPT))
def test_support_bundle_never_contains_the_files_names(reg, monkeypatch, name, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    content = {**VALID, **CORRUPT}[name]
    reg.write_text(content)
    bundle = _bundle(monkeypatch)
    blob = json.dumps(bundle, default=str)
    for n in NAMES:
        assert n not in blob, (name, n)
    if name in CORRUPT:
        assert TITLE in blob
        assert TITLE in bundle["report"]
        assert TITLE in bundle["report_redacted"]
    else:
        assert TITLE not in blob


def test_names_in_a_corrupt_file_never_reach_the_logs(reg, caplog):
    reg.write_text(CORRUPT["truncated_with_names"])
    with caplog.at_level(logging.DEBUG):
        D.check_minors_registry(None)
        D.run_all_rules(_snap())
    text = "\n".join(
        r.getMessage() + " " + (str(r.exc_info[1]) if r.exc_info else "") + repr(r.args)
        for r in caplog.records
    )
    assert "under-18 list unreadable" in text  # the control: we did capture the line
    for n in NAMES:
        assert n not in text


def test_no_logging_call_in_the_rule_can_carry_file_content():
    src = (AGENT / "diagnostic_rules.py").read_text()
    tree = ast.parse(src)
    fns = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)
           and n.name in ("check_minors_registry", "_minors_registry_path")]
    assert len(fns) == 2
    calls = 0
    for fn in fns:
        for node in ast.walk(fn):
            if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                    and isinstance(node.func.value, ast.Name) and node.func.value.id == "log"):
                calls += 1
                assert not node.keywords or all(k.arg != "exc_info" for k in node.keywords), "exc_info prints the message"
                for arg in node.args[1:]:
                    for sub in ast.walk(arg):
                        if isinstance(sub, ast.Name) and sub.id in ("data", "exc", "path", "text"):
                            # only legal as type(exc).__name__
                            assert isinstance(arg, ast.Attribute) and isinstance(arg.value, ast.Call) \
                                and getattr(arg.value.func, "id", "") == "type", ast.unparse(node)
    assert calls >= 1, "control: the walker found no log call, so it checked nothing"


if __name__ == "__main__":
    raise SystemExit(pytest.main(["-q", "--no-header", "-p", "no:cacheprovider", __file__]))
