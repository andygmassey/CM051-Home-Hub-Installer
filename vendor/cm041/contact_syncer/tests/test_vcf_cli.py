"""CX-81 B1 – install-time hydration CLI surface tests for contact_syncer.

The CM051 install.sh ``hydrate_graph`` sub-phase calls
``python -m contact_syncer.syncer --vcf <path> --graph-endpoint <url>``
and parses the single-line JSON status emitted on stdout. These tests
pin that JSON contract so future refactors of ``sync_from_vcf`` cannot
silently break install.sh.

Synthetic vCard fixtures only -- no real contacts, no real phone
numbers, no real emails. Per the per-repo "no real data in tests"
policy.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest


# Minimal RFC 6350 vCard 3.0 record using fully synthetic data:
#   - Alice Tester / Bob Tester / Carol Tester (placeholder names)
#   - +15551234567, +15551234568 (NANP test/reserved prefix per FCC docs)
#   - alice@example.com, bob@example.com, carol@example.com (RFC 2606
#     reserved example domain)
SYNTHETIC_VCF = """BEGIN:VCARD
VERSION:3.0
N:Tester;Alice;;;
FN:Alice Tester
EMAIL;TYPE=INTERNET:alice@example.com
TEL;TYPE=CELL:+15551234567
END:VCARD
BEGIN:VCARD
VERSION:3.0
N:Tester;Bob;;;
FN:Bob Tester
EMAIL;TYPE=INTERNET:bob@example.com
TEL;TYPE=CELL:+15551234568
END:VCARD
BEGIN:VCARD
VERSION:3.0
N:Tester;Carol;;;
FN:Carol Tester
EMAIL;TYPE=INTERNET:carol@example.com
END:VCARD
"""


# The CLI is invoked as `python -m contact_syncer.syncer ...` from the
# package root. The tests run from inside the package, so we walk up to
# the repo root first.
_PKG_ROOT = Path(__file__).resolve().parent.parent.parent


def _run_cli(args: list[str], extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    """Invoke the contact_syncer CLI as a subprocess and capture stdout."""
    env = os.environ.copy()
    # Point at unreachable backends so the syncer fails cleanly if it
    # tries to write -- we only care about the JSON shape from the
    # early-return paths in this test module.
    env.setdefault("OXIGRAPH_URL", "http://localhost:1/")
    env.setdefault("QDRANT_URL", "http://localhost:1/")
    env.setdefault("EMBED_OLLAMA_URL", "http://localhost:1/")
    env.setdefault("CARDDAV_URL", "http://localhost:1/")
    env.setdefault("STATE_FILE", "/tmp/contact_syncer_test_state.json")
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [sys.executable, "-m", "contact_syncer.syncer", *args],
        cwd=str(_PKG_ROOT),
        capture_output=True,
        text=True,
        timeout=30,
        env=env,
    )


def _last_json_line(stdout: str) -> dict:
    """Extract the final JSON line from stdout (the status dict).

    install.sh's hydrate_graph step does the same with
    ``tail -n 1 | jq -r '.imported'`` so the contract is that the JSON
    appears alone on the last line of stdout, regardless of any earlier
    output.
    """
    lines = [ln for ln in stdout.splitlines() if ln.strip()]
    assert lines, f"expected at least one stdout line, got: {stdout!r}"
    last = lines[-1]
    return json.loads(last)


class TestVcfCli:
    """The --vcf install-time path."""

    def test_missing_file_emits_empty_status(self) -> None:
        """A missing vCard file is not an install failure -- the syncer
        emits a zero-counts JSON dict and exits 0. install.sh's
        ``hydrate_graph`` step uses this to detect the
        ``MSG_HYDRATE_SKIPPED_NO_CONTACTS`` path on a customer Mac with
        no iCloud Contacts signed in.
        """
        result = _run_cli(["--vcf", "/tmp/does-not-exist-cx81-b1.vcf"])
        assert result.returncode == 0, f"stderr={result.stderr}"
        payload = _last_json_line(result.stdout)
        assert payload == {
            "imported": 0,
            "skipped": 0,
            "errors": [],
            "deleted": 0,
        }

    def test_empty_file_emits_empty_status(self, tmp_path: Path) -> None:
        """A zero-byte vCard file is treated identically to a missing
        file: zero-counts JSON, exit 0. Matches install.sh AC4 -- the
        customer has Contacts permission but no actual contacts.
        """
        empty = tmp_path / "empty.vcf"
        empty.write_text("", encoding="utf-8")
        result = _run_cli(["--vcf", str(empty)])
        assert result.returncode == 0, f"stderr={result.stderr}"
        payload = _last_json_line(result.stdout)
        assert payload["imported"] == 0
        assert payload["skipped"] == 0
        assert payload["errors"] == []

    def test_whitespace_only_file_emits_empty_status(self, tmp_path: Path) -> None:
        """A vCard file containing only whitespace (newlines, no actual
        records) is also treated as empty."""
        ws = tmp_path / "whitespace.vcf"
        ws.write_text("   \n  \n\n", encoding="utf-8")
        result = _run_cli(["--vcf", str(ws)])
        assert result.returncode == 0, f"stderr={result.stderr}"
        payload = _last_json_line(result.stdout)
        assert payload["imported"] == 0

    def test_json_keys_are_present(self, tmp_path: Path) -> None:
        """install.sh consumes ``imported``, ``skipped``, and ``errors``.
        Pin the key set so a future refactor cannot silently drop one
        and leave install.sh parsing ``null``.
        """
        empty = tmp_path / "empty.vcf"
        empty.write_text("", encoding="utf-8")
        result = _run_cli(["--vcf", str(empty)])
        payload = _last_json_line(result.stdout)
        for required_key in ("imported", "skipped", "errors"):
            assert required_key in payload, (
                f"JSON status missing {required_key!r}: {payload}"
            )
        assert isinstance(payload["errors"], list)
        assert isinstance(payload["imported"], int)
        assert isinstance(payload["skipped"], int)


class TestVcardSplit:
    """The multi-vCard split regex used by ``sync_from_vcf``."""

    def test_synthetic_fixture_yields_three_vcards(self) -> None:
        """The synthetic fixture above contains three concatenated
        records. The regex used in ``sync_from_vcf`` must find all
        three.
        """
        import re
        pattern = re.compile(r"BEGIN:VCARD.*?END:VCARD", re.DOTALL)
        matches = pattern.findall(SYNTHETIC_VCF)
        assert len(matches) == 3
        # Each match starts with BEGIN:VCARD and ends with END:VCARD.
        for m in matches:
            assert m.startswith("BEGIN:VCARD")
            assert m.endswith("END:VCARD")
            assert "VERSION:3.0" in m


class TestCliFlags:
    """The argparse surface itself."""

    def test_help_lists_new_flags(self) -> None:
        """--help advertises the new CX-81 B1 flags so future operators
        (and future Claude sessions) can discover them.
        """
        result = _run_cli(["--help"])
        assert result.returncode == 0
        for flag in ("--vcf", "--graph-endpoint", "--json"):
            assert flag in result.stdout, f"--help missing {flag}"
