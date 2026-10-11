"""The People rules must load in the layout install.sh lays down, not only
in a repo checkout.

Walk #20 (launch blocker): every push was skipped with
non_human_predicate_unavailable, "People predicates could not be imported on
this box". The import worked in the repo and failed installed because:

  * install.sh `pip install`s cm048 (NOT editable) into
    <ostler>/services/cm048/.venv, so reminders_push runs from
    .venv/lib/python3.X/site-packages/src/ and `Path(__file__).parents[2]`
    is .../lib/python3.X, not <ostler>/services;
  * ical-server.py sits at <ostler>/services/ical-server/ and cannot be
    imported whole from cm048's venv anyway (ostler_security, pwg_privacy,
    identity_resolver and rapidfuzz are not there).

This builds that layout in a temp HOME the way install.sh does, and runs the
shipped code under it in a fresh interpreter with ONLY the cm048
site-packages on the path. Synthetic data only.
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


@pytest.fixture()
def installed(tmp_path):
    """<home>/.ostler/services/{ical-server, pwg_privacy.py, cm048/.venv/...}
    laid out as install.sh does (cp -R assistant_api/. -> ical-server/;
    pwg_privacy.py beside it; cm048's `src` pip-installed into
    site-packages)."""
    home = tmp_path / "home"
    services = home / ".ostler" / "services"
    ical = services / "ical-server"
    shutil.copytree(ASSISTANT_API, ical, ignore=shutil.ignore_patterns("tests", "__pycache__"))
    shutil.copy(ROOT / "vendor" / "cm041" / "pwg_privacy.py", services / "pwg_privacy.py")
    site = services / "cm048" / ".venv" / "lib" / "python3.11" / "site-packages"
    shutil.copytree(CM048 / "src", site / "src", ignore=shutil.ignore_patterns("__pycache__"))
    return home, ical / "ical-server.py", site


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
        return {"eligible": d.eligible, "skip": d.skip_reason, "title": d.push_title}

    out = {
        "file": rp.__file__,
        "person": decide("Jane Doe"),
        "org": decide("example bank support team"),
        "tried": list(getattr(rp, "_ICAL_TRY_LOG", [])),
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


def _run(code, args, home, site):
    env = {
        "HOME": str(home),
        "PYTHONPATH": str(site),
        "PATH": os.environ.get("PATH", ""),
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    return subprocess.run(
        [sys.executable, "-c", code, *args],
        env=env, cwd=str(home), capture_output=True, text=True, timeout=60,
    )


def test_the_layout_is_the_one_that_broke_walk_20(installed):
    """CONTROL: in this layout the old __file__-relative guess finds nothing,
    and the whole of ical-server.py cannot be imported from cm048's venv.
    If either stopped being true this test would no longer prove the fix."""
    home, ical_py, site = installed
    r = _run(SCRIPT, [], home, site)
    assert r.returncode == 0, r.stderr[-800:]
    out = json.loads(r.stdout.strip().splitlines()[-1])
    rp_file = Path(out["file"])
    assert "site-packages" in str(rp_file), rp_file
    old_guess = rp_file.resolve().parents[2] / "ical-server" / "ical-server.py"
    assert not old_guess.exists(), "the pre-fix path guess would have worked; layout is wrong"
    whole = _run(WHOLE_IMPORT, [str(ical_py)], home, site)
    assert whole.stdout.strip().startswith("FAILED"), whole.stdout + whole.stderr[-400:]


def test_people_rules_load_installed_and_decide_correctly(installed):
    home, ical_py, site = installed
    r = _run(SCRIPT, [], home, site)
    assert r.returncode == 0, r.stderr[-800:]
    out = json.loads(r.stdout.strip().splitlines()[-1])
    assert out["person"]["skip"] != "non_human_predicate_unavailable", out["tried"]
    assert out["org"]["skip"] != "non_human_predicate_unavailable", out["tried"]
    assert out["person"]["eligible"] is True
    assert out["person"]["title"] == "Jane Doe: send the synthetic draft"
    # the rules actually RAN: an organisation is refused for the right reason
    assert out["org"]["eligible"] is False and out["org"]["skip"] == "non_human_sender"
    assert out["tried"] == []


def test_a_missing_ical_server_still_fails_closed_and_names_the_paths(installed):
    home, ical_py, site = installed
    ical_py.unlink()
    r = _run(SCRIPT, [], home, site)
    assert r.returncode == 0, r.stderr[-800:]
    out = json.loads(r.stdout.strip().splitlines()[-1])
    assert out["person"]["eligible"] is False
    assert out["person"]["skip"] == "non_human_predicate_unavailable"
    assert any("ical-server.py: no such file" in t and str(home) in t for t in out["tried"]), out["tried"]
