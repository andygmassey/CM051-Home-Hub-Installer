"""The People rules must load in the layout install.sh lays down, not only
in a repo checkout.

Walk #20 (launch blocker): every push was held back with
non_human_predicate_unavailable. The rules loaded in the repo and not on a
box because:

  * install.sh `pip install`s cm048 (NOT editable) into
    <ostler>/services/cm048/.venv, so reminders_push runs from
    .venv/lib/python3.X/site-packages/src/ and `Path(__file__).parents[2]`
    is .../lib/python3.X, not <ostler>/services;
  * the rules lived inside ical-server.py, which cannot be imported from
    cm048's venv (ostler_security, pwg_privacy, identity_resolver,
    rapidfuzz are not there).

Now they live in stdlib-only people_rules.py, which install.sh (3.10a) lays
into <ostler>/services/shared/. This builds that layout in a temp dir the
way install.sh does and runs the shipped code in a fresh interpreter with
ONLY the cm048 site-packages on the path. Synthetic data only.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
CM048 = ROOT / "vendor" / "cm048_pipeline"
ASSISTANT_API = ROOT / "vendor" / "cm041" / "assistant_api"


def _lay_out(base: Path, shared: bool = True):
    """<base>/services/{shared/people_rules.py, ical-server/, pwg_privacy.py,
    cm048/.venv/lib/python3.11/site-packages/src}: install.sh 3.10a copies
    people_rules.py to shared/, the ical-server block copies assistant_api/.
    minus people_rules.py, and cm048's `src` is pip-installed into
    site-packages."""
    services = base / "services"
    ical = services / "ical-server"
    shutil.copytree(ASSISTANT_API, ical, ignore=shutil.ignore_patterns("tests", "__pycache__"))
    (ical / "people_rules.py").unlink()  # install.sh removes the bundled duplicate
    if shared:
        (services / "shared").mkdir(parents=True)
        shutil.copy(ASSISTANT_API / "people_rules.py", services / "shared" / "people_rules.py")
    shutil.copy(ROOT / "vendor" / "cm041" / "pwg_privacy.py", services / "pwg_privacy.py")
    site = services / "cm048" / ".venv" / "lib" / "python3.11" / "site-packages"
    shutil.copytree(CM048 / "src", site / "src", ignore=shutil.ignore_patterns("__pycache__"))
    return ical / "ical-server.py", site


@pytest.fixture()
def installed(tmp_path):
    home = tmp_path / "home"
    ical_py, site = _lay_out(home / ".ostler")
    return home, ical_py, site


SCRIPT = textwrap.dedent(
    """
    import json, sys
    from pathlib import Path
    from src import reminders_push as rp
    from src.conversation_writer import ConversationBundle, ConversationSummary, Todo

    def decide(label):
        b = ConversationBundle(
            conversation_id="c", source_kind="channel", source_subtype="imessage",
            source_session_id="s", channel="im", participants=("user", label),
            started_at="2026-10-01T09:00:00Z", ended_at="2026-10-01T09:30:00Z",
            summary=ConversationSummary(overall="x", topics=()), transcript="x",
            privacy_level="L2")
        t = Todo(id="t", text="send the synthetic draft", owner="user", deadline=None)
        d = rp.decide_push(t, b, demo_mode=False, user_id="user", summary_path=Path("/tmp/s.md"))
        return {"eligible": d.eligible, "skip": d.skip_reason, "title": d.push_title,
                "flag": getattr(d, "flag", "")}

    out = {
        "file": rp.__file__,
        "person": decide("Jane Doe"),
        "org": decide("example bank support team"),
        "tried": list(getattr(rp, "_PEOPLE_TRY_LOG", [])),
    }
    print(json.dumps(out))
    """
)

WHOLE_IMPORT = textwrap.dedent(
    """
    import importlib.util, sys
    spec = importlib.util.spec_from_file_location("whole", sys.argv[1])
    m = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(__import__("pathlib").Path(sys.argv[1]).parent))
    try:
        spec.loader.exec_module(m)
        print("IMPORTED")
    except BaseException as e:
        print("FAILED " + type(e).__name__)
    """
)


def _run(code, args, home, site, ostler_dir=None):
    env = {
        "HOME": str(home),
        "PYTHONPATH": str(site),
        "PATH": os.environ.get("PATH", ""),
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    if ostler_dir is not None:
        env["OSTLER_DIR"] = str(ostler_dir)
    return subprocess.run(
        [sys.executable, "-c", code, *args],
        env=env, cwd=str(home), capture_output=True, text=True, timeout=60,
    )


def _out(r):
    assert r.returncode == 0, r.stderr[-800:]
    return json.loads(r.stdout.strip().splitlines()[-1])


def test_the_layout_is_the_one_that_broke_walk_20(installed):
    """CONTROL: the pre-fix path guess finds nothing in this layout, and the
    whole of ical-server.py cannot be imported from cm048's venv. If either
    stopped being true this test would no longer prove the fix."""
    home, ical_py, site = installed
    out = _out(_run(SCRIPT, [], home, site))
    rp_file = Path(out["file"])
    assert "site-packages" in str(rp_file), rp_file
    old_guess = rp_file.resolve().parents[2] / "ical-server" / "ical-server.py"
    assert not old_guess.exists(), "the pre-fix path guess would have worked; layout is wrong"
    whole = _run(WHOLE_IMPORT, [str(ical_py)], home, site)
    assert whole.stdout.strip().startswith("FAILED"), whole.stdout + whole.stderr[-400:]


def test_people_rules_load_installed_and_decide_correctly(installed):
    home, ical_py, site = installed
    out = _out(_run(SCRIPT, [], home, site))
    assert out["tried"] == [], out["tried"]
    assert out["person"]["flag"] == "" and out["org"]["flag"] == ""
    assert out["person"]["eligible"] is True
    assert out["person"]["title"] == "Jane Doe: send the synthetic draft"
    # the rules actually RAN: an organisation is refused for the right reason
    assert out["org"]["eligible"] is False and out["org"]["skip"] == "non_human_sender"


def test_an_overridden_ostler_dir_is_honoured_like_install_sh_does(tmp_path):
    """install.sh:20814 resolves OSTLER_DIR="${OSTLER_DIR:-${HOME}/.ostler}".
    A tree under a custom dir is found via OSTLER_DIR, and HOME's own
    ~/.ostler (empty here) is NOT consulted."""
    home = tmp_path / "home"
    home.mkdir()
    custom = tmp_path / "elsewhere" / "ostler"
    ical_py, site = _lay_out(custom)
    out = _out(_run(SCRIPT, [], home, site, ostler_dir=custom))
    assert out["tried"] == [] and out["person"]["flag"] == ""
    assert out["org"]["skip"] == "non_human_sender"
    # without the override the same HOME has no shared dir: fail open, flagged
    off = _out(_run(SCRIPT, [], home, site))
    assert off["person"]["flag"] == "org_filter_unavailable"


def test_missing_rules_fail_open_flag_the_row_and_name_the_paths(installed):
    """The org filter is quality, not privacy: with no rules the todo is
    STILL pushed (eligible), flagged, and the ERROR names every path tried."""
    home, ical_py, site = installed
    shutil.rmtree(home / ".ostler" / "services" / "shared")
    out = _out(_run(SCRIPT, [], home, site))
    assert out["person"]["eligible"] is True
    assert out["person"]["flag"] == "org_filter_unavailable"
    assert out["person"]["title"] == "Jane Doe: send the synthetic draft"
    assert any("people_rules.py: no such file" in t and str(home) in t for t in out["tried"]), out["tried"]


def test_ical_server_resolves_the_same_shared_dir_install_sh_creates(installed):
    """ical-server.py must look in <services>/shared, which is where
    install.sh 3.10a puts people_rules.py (its own bundled copy is removed)."""
    import ast

    home, ical_py, site = installed
    tree = ast.parse(ical_py.read_text())
    node = next(
        n for n in tree.body
        if isinstance(n, ast.Assign) and any(getattr(t, "id", "") == "_PEOPLE_RULES_SHARED" for t in n.targets)
    )
    code = compile(ast.Expression(node.value), "x", "eval")
    got = eval(code, {"os": os, "__file__": str(ical_py)})  # noqa: S307
    assert Path(got) == home / ".ostler" / "services" / "shared"
    assert (Path(got) / "people_rules.py").is_file()
    assert not (ical_py.parent / "people_rules.py").exists()


APPLY_SCRIPT = textwrap.dedent(
    """
    import sys
    from pathlib import Path
    from src import reminders_push as rp
    from src.conversation_writer import ConversationBundle, ConversationSummary, Todo

    def todo(i):
        return Todo(id=i, text="send the synthetic draft", owner="user", deadline=None)

    b = ConversationBundle(
        conversation_id="c", source_kind="channel", source_subtype="imessage",
        source_session_id="s", channel="im", participants=("user", "Jane Doe"),
        started_at="2026-10-01T09:00:00Z", ended_at="2026-10-01T09:30:00Z",
        summary=ConversationSummary(overall="x", topics=()), transcript="x",
        privacy_level="L2")
    rp.apply_push_status_to_todos((todo("t1"), todo("t2")), b, summary_path=Path("/tmp/s.md"),
                                  user_id="user", db_path=Path(sys.argv[1]))
    """
)


def test_the_fail_open_error_lands_in_the_known_log_file(installed):
    """The pipeline has no LaunchAgent of its own (ical-server captures the
    CLI's stderr), so the loud line must be written to a known file:
    <ostler>/logs/cm048-reminders.err, with the flagged-row count."""
    home, ical_py, site = installed
    shutil.rmtree(home / ".ostler" / "services" / "shared")
    r = _run(APPLY_SCRIPT, [str(home / "m.db")], home, site)
    assert r.returncode == 0, r.stderr[-800:]
    log_file = home / ".ostler" / "logs" / "cm048-reminders.err"
    text = log_file.read_text()
    assert text.count("WITHOUT the organisation filter") == 1, text  # one per run, not per row
    assert "org_filter_unavailable" in text and "1 todo(s)" in text
    assert "people_rules.py: no such file" in text


def test_no_log_line_when_the_rules_load(installed):
    home, ical_py, site = installed
    r = _run(APPLY_SCRIPT, [str(home / "m.db")], home, site)
    assert r.returncode == 0, r.stderr[-800:]
    assert not (home / ".ostler" / "logs" / "cm048-reminders.err").exists()


def test_the_log_follows_an_overridden_ostler_dir(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    custom = tmp_path / "elsewhere"
    ical_py, site = _lay_out(custom, shared=False)
    r = _run(APPLY_SCRIPT, [str(home / "m.db")], home, site, ostler_dir=custom)
    assert r.returncode == 0, r.stderr[-800:]
    assert (custom / "logs" / "cm048-reminders.err").is_file()
    assert not (home / ".ostler").exists()
