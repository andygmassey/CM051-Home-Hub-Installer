#!/usr/bin/env python3
"""The Doctor shows "Web search not ready yet" with a Retry while Vane downloads.

v1.0.118 (W5 + W8). Web search (the 3.4 GB Vane image) now downloads in the
background after the install. A customer must SEE that state, with a way to
retry, rather than meet a search tool that silently does not work.

End to end through the real pieces:

* The state file is produced by the REAL fetcher, extracted from install.sh
  (the bytes that ship), run against a fake docker that ALWAYS fails with the
  short read measured on the v1.0.117 console walk. Nothing hand-writes the
  JSON the tile reads, so a writer/reader drift fails here.
* The tile is rendered by the real vendor/doctor/agent/web_search_status.py and
  the real dashboard wiring in web_ui.py.
* The Retry route is the real handler in web_ui.py, driven over HTTP with a
  stubbed launchctl that records its argv (never the real launchctl).

Negative controls: a fetcher run that SUCCEEDS renders the green "ready" tile
with no Retry, and an absent state file (an install from before the fetcher)
renders nothing; an unknown state renders "could not be checked", never green.

Exit codes: 0 pass, 1 a case was wrong, 2 CANNOT-RUN (a dependency missing).
"""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
AGENT = REPO / "vendor" / "doctor" / "agent"
INSTALL = REPO / "install.sh"


def _cannot_run(msg: str) -> None:
    print(f"CANNOT-RUN: {msg}", file=sys.stderr)
    sys.exit(2)


def _extract_fetcher(dest: Path) -> Path:
    text = INSTALL.read_text(encoding="utf-8")
    start = text.find("<<'OSTLER_VANE_FETCH_EOF'\n")
    if start < 0:
        print("FAIL: install.sh carries no ostler-vane-fetch heredoc", file=sys.stderr)
        sys.exit(1)
    body_start = text.index("\n", start) + 1
    end = text.index("\nOSTLER_VANE_FETCH_EOF\n", body_start)
    path = dest / "ostler-vane-fetch"
    path.write_text(text[body_start:end + 1], encoding="utf-8")
    path.chmod(0o755)
    return path


FAKE_DOCKER = textwrap.dedent("""\
    #!/bin/bash
    F="${FAKE:?}"
    case "$1" in
        image) [ -f "${F}/image_present" ] && exit 0; exit 1 ;;
        inspect) [ -f "${F}/running" ] && { echo true; exit 0; }; exit 1 ;;
        compose)
            case " $* " in
                *" pull vane "*)
                    if [ -f "${F}/always_fail" ]; then
                        echo " 1a2b3c4d5e6f Pull complete"
                        echo "failed to copy: short read: expected 237669906 bytes but got 41943040: unexpected EOF" >&2
                        exit 1
                    fi
                    : > "${F}/image_present"; exit 0 ;;
                *" up -d vane "*) : > "${F}/running"; exit 0 ;;
            esac ;;
    esac
    exit 0
    """)
FAKE_CURL = textwrap.dedent("""\
    #!/bin/bash
    cfg="$(cat)"
    if [ -f "${FAKE:?}/running" ] && [ "$cfg" = 'user = "ostler:synthetic-pass-word"' ]; then printf 200; else printf 401; fi
    """)
FAKE_LAUNCHCTL = textwrap.dedent("""\
    #!/bin/bash
    printf '%s\\n' "$*" >> "${FAKE:?}/launchctl_calls"
    exit 0
    """)


class _Box:
    """A fake ~/.ostler driven by the shipped fetcher."""

    def __init__(self, always_fail: bool):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.fake = root / "fake"
        self.fake.mkdir()
        self.ostler = root / "home" / ".ostler"
        (self.ostler / "secrets").mkdir(parents=True)
        (self.ostler / "secrets" / "vane_password").write_text("synthetic-pass-word\n")
        (self.ostler / "docker-compose.yml").write_text(
            "services:\n  vane:\n    image: example.invalid/vane@sha256:2222\n")
        bindir = root / "bin"
        bindir.mkdir()
        for name, body in (("docker", FAKE_DOCKER), ("curl", FAKE_CURL),
                           ("launchctl", FAKE_LAUNCHCTL), ("fakesleep", "#!/bin/bash\nexit 0\n")):
            p = bindir / name
            p.write_text(body)
            p.chmod(0o755)
        self.bin = bindir
        if always_fail:
            (self.fake / "always_fail").write_text("")
        self.fetcher = _extract_fetcher(root)

    def env(self) -> dict:
        e = dict(os.environ)
        e.update({
            "FAKE": str(self.fake),
            "HOME": str(self.ostler.parent),
            "OSTLER_DIR": str(self.ostler),
            "OSTLER_VANE_DOCKER": str(self.bin / "docker"),
            "OSTLER_VANE_CURL": str(self.bin / "curl"),
            "OSTLER_VANE_FETCH_SLEEP": str(self.bin / "fakesleep"),
            "OSTLER_VANE_HEALTH_WAIT_S": "0",
            "OSTLER_VANE_INSTALL_MARKER": str(self.fake / "no-marker"),
            "OSTLER_LAUNCHCTL": str(self.bin / "launchctl"),
        })
        return e

    def run_fetcher(self) -> int:
        return subprocess.run(["/bin/bash", str(self.fetcher), "run"], env=self.env(),
                              capture_output=True, text=True, timeout=60).returncode

    def close(self):
        self.tmp.cleanup()


sys.path.insert(0, str(AGENT))
if not (AGENT / "web_search_status.py").is_file():
    print("FAIL: the Doctor has no web search readiness row "
          "(vendor/doctor/agent/web_search_status.py is absent)", file=sys.stderr)
    sys.exit(1)
try:
    import web_search_status as WSS  # noqa: E402
except Exception as exc:  # pragma: no cover
    _cannot_run(f"vendor/doctor/agent/web_search_status.py did not import: {exc!r}")


class TheTileReadsTheRealFetchersState(unittest.TestCase):
    def test_always_failing_download_shows_not_ready_with_retry(self):
        box = _Box(always_fail=True)
        try:
            rc = box.run_fetcher()
            self.assertEqual(rc, 75, "an always-failing download must exit 75 (try again later)")
            state = json.loads((box.ostler / "state" / "vane-fetch.json").read_text())
            self.assertEqual(state["state"], "waiting")
            html = WSS.render_web_search_status(box.ostler)
            self.assertIn("Web search not ready yet", html)
            self.assertIn("/api/v1/web-search/retry", html, "no Retry on a not-ready tile")
            self.assertIn("Press Retry", html)
            self.assertNotIn("Web search ready", html)
        finally:
            box.close()

    def test_negative_control_a_download_that_lands_is_green_without_retry(self):
        box = _Box(always_fail=False)
        try:
            self.assertEqual(box.run_fetcher(), 0)
            html = WSS.render_web_search_status(box.ostler)
            self.assertIn("Web search ready", html)
            self.assertNotIn("not ready yet", html)
            self.assertNotIn("/api/v1/web-search/retry", html)
        finally:
            box.close()

    def test_every_state_the_fetcher_writes_is_known_to_the_reader(self):
        # Writer/reader contract: every `_state <name>` the shipped fetcher can
        # write must classify as ready or not-ready, never check-failed.
        text = INSTALL.read_text(encoding="utf-8")
        body = text[text.index("<<'OSTLER_VANE_FETCH_EOF'"):text.index("\nOSTLER_VANE_FETCH_EOF\n")]
        import re
        written = set(re.findall(r"vf_state ([a-z]+) ", body))
        self.assertTrue(written >= {"ready", "pulling", "retrying", "waiting", "deferred"}, written)
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "state").mkdir()
            for s in sorted(written):
                (Path(d) / "state" / "vane-fetch.json").write_text(json.dumps({"state": s}))
                status = WSS.read_web_search_state(d)["status"]
                self.assertIn(status, (WSS.STATUS_READY, WSS.STATUS_NOT_READY), f"{s} -> {status}")

    def test_absent_state_renders_nothing_and_unknown_renders_could_not_check(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(WSS.render_web_search_status(d), "")
            (Path(d) / "state").mkdir()
            (Path(d) / "state" / "vane-fetch.json").write_text('{"state":"bogus"}')
            html = WSS.render_web_search_status(d)
            self.assertIn("could not be checked", html)
            self.assertNotIn("Web search ready", html)
            (Path(d) / "state" / "vane-fetch.json").write_text("not json")
            self.assertIn("could not be checked", WSS.render_web_search_status(d))


class TheRetryRouteKicksTheAgent(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            from fastapi.testclient import TestClient  # noqa: F401
        except Exception as exc:
            _cannot_run(f"fastapi/httpx not installed ({exc!r}); run python3 -m pip install fastapi httpx")
        spec = importlib.util.spec_from_file_location("ostler_web_ui_vane", AGENT / "web_ui.py")
        mod = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(mod)
        except Exception as exc:
            _cannot_run(f"web_ui.py did not import: {exc!r}")
        cls.web_ui = mod

    def _client(self):
        from fastapi.testclient import TestClient
        return TestClient(self.web_ui.app)

    def test_retry_kickstarts_the_fetch_agent_when_not_downloading(self):
        box = _Box(always_fail=True)
        old = dict(os.environ)
        try:
            box.run_fetcher()
            os.environ.update({"OSTLER_DIR": str(box.ostler), "FAKE": str(box.fake),
                               "OSTLER_LAUNCHCTL": str(box.bin / "launchctl")})
            r = self._client().post("/api/v1/web-search/retry",
                                    headers={"host": "127.0.0.1:8089"})
            self.assertEqual(r.status_code, 200, r.text)
            self.assertTrue(r.json()["ok"])
            calls = (box.fake / "launchctl_calls").read_text().split("\n")
            self.assertIn(f"kickstart -k gui/{os.getuid()}/com.ostler.vane-fetch", calls)
        finally:
            os.environ.clear(); os.environ.update(old)
            box.close()

    def test_retry_leaves_an_active_download_alone(self):
        box = _Box(always_fail=True)
        old = dict(os.environ)
        try:
            (box.ostler / "state").mkdir(parents=True, exist_ok=True)
            (box.ostler / "state" / "vane-fetch.json").write_text('{"state":"pulling","attempt":2}')
            os.environ.update({"OSTLER_DIR": str(box.ostler), "FAKE": str(box.fake),
                               "OSTLER_LAUNCHCTL": str(box.bin / "launchctl")})
            r = self._client().post("/api/v1/web-search/retry",
                                    headers={"host": "127.0.0.1:8089"})
            self.assertEqual(r.json()["detail"], "already downloading")
            self.assertFalse((box.fake / "launchctl_calls").exists(),
                             "restarted a download that was in flight")
        finally:
            os.environ.clear(); os.environ.update(old)
            box.close()

    def test_retry_refuses_a_request_not_dialled_to_the_hub(self):
        r = self._client().post("/api/v1/web-search/retry", headers={"host": "evil.example"})
        self.assertEqual(r.status_code, 403)

    def test_dashboard_carries_the_tile(self):
        src = (AGENT / "web_ui.py").read_text(encoding="utf-8")
        self.assertIn("web_search_section = render_web_search_status()", src)
        self.assertIn("{web_search_section}", src)


if __name__ == "__main__":
    unittest.main()
