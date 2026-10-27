#!/usr/bin/env python3
"""Every docs URL the installer shows a customer must resolve (HTTP 200).

Why: the installer help text linked docs.ostler.ai/data-exports, which
redirects to https://ostler.ai/docs/data-exports/ and 404s (the real page is
/docs/getting-started/data-exports/). A tester hit it; no test fetched it.

Scope: https://ostler.ai/docs/..., ostler.ai/docs/... and docs.ostler.ai/...
(with or without scheme) in the installer strings, install.sh and the GUI
sources and JSON copy. Not scanned: the GUI tests (linkify examples), Swift
comment lines and "_meta" JSON keys (developer notes, not customer copy).

Three parts:
  1. Offline: the extractor finds the known links (denominator is non-zero).
  2. Offline control: the checker flags a 404 and follows a 301 to a 200,
     proven against a local server.
  3. Network (skipped offline): fetch every extracted URL, follow redirects,
     the final status must be 200. CI sets OSTLER_REQUIRE_NETWORK=1 so an
     unreachable site FAILS there instead of skipping.
"""
from __future__ import annotations

import http.server
import os
import re
import socket
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(os.environ.get("DOC_LINKS_ROOT", Path(__file__).resolve().parent.parent))
SOURCES = ["install.sh.strings.en-GB.sh", "install.sh"]
GUI_DIR = "gui/OstlerInstaller"
URL_RE = re.compile(
    r"(?:https?://)?(?:ostler\.ai/docs|docs\.ostler\.ai)(?:/[^\s\"'<>)\]\\`|]*)?"
)
CANARY = "https://ostler.ai/docs/getting-started/data-exports/"
REQUIRE_NETWORK = os.environ.get("OSTLER_REQUIRE_NETWORK") == "1"


def normalise(raw: str) -> str:
    url = raw.rstrip(".,;:!?")
    return url if url.startswith("http") else "https://" + url


def is_developer_note(f: Path, line: str) -> bool:
    t = line.lstrip()
    if f.suffix == ".swift":
        return t.startswith("//")
    if f.suffix == ".json":
        return t.startswith('"_')
    return False


def source_files(root: Path = ROOT) -> list[Path]:
    files = [root / s for s in SOURCES]
    files += sorted((root / GUI_DIR).rglob("*.swift"))
    files += sorted((root / GUI_DIR / "Resources").glob("*.json"))
    return [f for f in files if f.is_file()]


def extract_urls(root: Path = ROOT) -> dict[str, list[str]]:
    """normalised URL -> [file:line, ...]"""
    found: dict[str, list[str]] = {}
    for f in source_files(root):
        for n, line in enumerate(f.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if is_developer_note(f, line):
                continue
            for m in URL_RE.finditer(line):
                found.setdefault(normalise(m.group(0)), []).append(f"{f.relative_to(root)}:{n}")
    return found


def final_status(url: str, timeout: float = 20.0) -> tuple[int, str]:
    """GET url following redirects. Returns (status, final_url). No proxy."""
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    req = urllib.request.Request(url, headers={"User-Agent": "ostler-installer-link-check"})
    try:
        with opener.open(req, timeout=timeout) as r:
            return r.status, r.geturl()
    except urllib.error.HTTPError as e:
        return e.code, e.geturl()


def site_reachable() -> bool:
    try:
        socket.create_connection(("ostler.ai", 443), timeout=5).close()
        return True
    except OSError:
        return False


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/ok":
            self.send_response(200)
        elif self.path == "/moved":
            self.send_response(301)
            self.send_header("Location", "/ok")
        else:
            self.send_response(404)
        self.end_headers()

    def log_message(self, *a):
        pass


class ExtractorTests(unittest.TestCase):
    def test_finds_the_known_links(self):
        urls = extract_urls()
        self.assertIn(CANARY, urls, "EXPORTS_ACK link missing: extractor or string changed")
        self.assertIn("https://docs.ostler.ai/privacy/third-party-data", urls)

    def test_old_exports_url_is_gone_from_product_copy(self):
        self.assertNotIn("https://docs.ostler.ai/data-exports", extract_urls())
        self.assertNotIn("https://ostler.ai/docs/data-exports/", extract_urls())

    def test_developer_notes_are_not_scanned(self):
        self.assertTrue(is_developer_note(Path("a.swift"), "    /// see docs.ostler.ai/x"))
        self.assertTrue(is_developer_note(Path("a.json"), '    "_meta": "docs.ostler.ai/..."'))
        self.assertFalse(is_developer_note(Path("a.json"), '    "help": "docs.ostler.ai/x"'))
        self.assertFalse(is_developer_note(Path("a.swift"), '    let s = "docs.ostler.ai/x" // c'))

    def test_extractor_normalises_bare_and_strips_punctuation(self):
        for raw, want in [
            ("docs.ostler.ai/privacy/third-party-data.", "https://docs.ostler.ai/privacy/third-party-data"),
            ("see https://ostler.ai/docs/faq/, then", "https://ostler.ai/docs/faq/"),
            ("ostler.ai/docs/faq)", "https://ostler.ai/docs/faq"),
        ]:
            m = URL_RE.search(raw)
            self.assertIsNotNone(m, raw)
            self.assertEqual(normalise(m.group(0)), want)


class CheckerControlTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        cls.base = f"http://127.0.0.1:{cls.srv.server_address[1]}"
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def test_404_is_reported(self):
        self.assertEqual(final_status(self.base + "/nope")[0], 404)

    def test_redirect_to_200_is_followed(self):
        status, final = final_status(self.base + "/moved")
        self.assertEqual((status, final), (200, self.base + "/ok"))


class LiveLinkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.reachable = site_reachable()
        if not cls.reachable:
            if REQUIRE_NETWORK:
                raise AssertionError("ostler.ai unreachable and OSTLER_REQUIRE_NETWORK=1 (CANNOT-RUN is not PASS)")
            raise unittest.SkipTest("offline: ostler.ai unreachable")

    def test_checker_flags_a_real_404(self):
        status, _ = final_status("https://ostler.ai/docs/__no_such_page_link_check__/")
        self.assertEqual(status, 404, "control: the live site must 404 an unknown docs page")

    def test_every_installer_docs_url_returns_200(self):
        urls = extract_urls()
        self.assertTrue(urls, "no docs URLs extracted: broken extractor, not a pass")
        bad = []
        for url, where in sorted(urls.items()):
            status, final = final_status(url)
            if status != 200:
                bad.append(f"{status} {url} -> {final}  ({', '.join(where)})")
        self.assertEqual(bad, [], "installer links that do not resolve:\n" + "\n".join(bad))


if __name__ == "__main__":
    unittest.main(verbosity=2)
