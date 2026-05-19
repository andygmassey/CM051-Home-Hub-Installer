#!/usr/bin/env python3
"""Negative-path tests for the install-sh <-> Swift GUI contract.

Sister test to tests/test_install_gui_contract.py.  Constructs
synthetic install.sh / Swift fixtures that DELIBERATELY violate the
contract and asserts the contract test reports the failure -- so the
positive-path test is not silently green when the underlying
extractors break.

Two negative scenarios match the brief's acceptance criteria,
remapped per the architectural recon (no per-prompt-id router exists
in the Swift coordinator, so the brief's literal `PU99` case becomes
the closest semantic equivalent):

  (a) Synthetic install.sh adds a `gui_read NEW_TEST_PROMPT` callsite
      with a brand-new kind value `kind=invented_kind` that is NOT a
      member of Swift's PromptKind enum.  Contract test must FAIL
      with a PROTOCOL DRIFT message naming the bogus kind.

  (b) Synthetic StepCatalog.swift adds an entry `pu99_dead_handler`
      to canonicalOrder without any matching `progress`/`step` call
      in install.sh, AND a synthetic install.sh emits
      `progress "..." "pu99_uncovered"` for an id NOT in
      canonicalOrder.  Contract test must FAIL on the uncovered
      emission AND (separately) emit a DEAD HANDLER warn for the
      orphan canonicalOrder entry.

The fixtures live under a tempdir; the extractor scripts are pointed
at it with --repo-root and run as subprocesses.  This keeps the real
extractor code under test (no mocking) and exercises the JSON
manifest contract end-to-end.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
EXTRACT_INSTALL = REPO_ROOT / "scripts" / "extract_install_protocol.py"
EXTRACT_GUI = REPO_ROOT / "gui" / "scripts" / "extract_gui_renderers.py"

# Synthetic install.sh prelude: enough shape that the extractor's
# heredoc / function-body skipping logic exercises along the way.
_SYNTHETIC_INSTALL_PRELUDE = textwrap.dedent("""\
    #!/usr/bin/env bash
    # Synthetic install.sh for contract test negatives.

    gui_emit()        { :; }
    gui_step_begin()  { :; }
    gui_step_end()    { :; }
    gui_phase()       { :; }
    gui_done()        { :; }
    gui_read()        { :; }
    gui_needs_sudo()  { :; }
    gui_needs_fda()   { :; }

    step()  {
        local title="$1"
        local id="${2:-}"
        gui_phase "$id" "$title"
    }

    progress() {
        local title="$1"
        local id="${2:-}"
        gui_step_begin "$id" "$title" 3 1 1
    }

""")

# Synthetic lib/progress_emitter.sh: a minimal scaffold so the extractor
# does not error when scanning.  Real wire format is documented; only
# the function shells need to exist.
_SYNTHETIC_PROGRESS_EMITTER = textwrap.dedent("""\
    #!/usr/bin/env bash
    # Synthetic lib/progress_emitter.sh for the contract negative tests.
    gui_emit() { :; }
    gui_step_begin() { :; }
    gui_step_end() { :; }
    gui_phase() { :; }
    gui_done() { :; }
    gui_read() { :; }
    gui_needs_sudo() { :; }
    gui_needs_fda() { :; }
    gui_log() { :; }
    gui_warn() { :; }
""")

# Synthetic Swift files: a minimal ProgressDecoder + StepCatalog.
# Just enough shape that the extractor scripts can parse them.
_SYNTHETIC_PROGRESS_PROTOCOL = textwrap.dedent("""\
    // Synthetic ProgressProtocol.swift for contract negative tests.
    import Foundation

    enum PromptKind: String, Equatable {
        case text, secret, yesno, choice
    }

    struct ProgressDecoder {
        static func decode(line raw: String) -> Int {
            switch event {
            case "STEP_BEGIN":
                return 1
            case "PCT":
                return 1
            case "LOG":
                return 1
            case "PROMPT":
                return 1
            case "STEP_END":
                return 1
            case "PHASE":
                return 1
            case "DONE":
                return 1
            default:
                return 0
            }
        }
    }
""")

_SYNTHETIC_STEP_CATALOG_BASELINE = textwrap.dedent("""\
    // Synthetic StepCatalog.swift for contract negative tests.
    import Foundation
    final class StepCatalog {
        static let canonicalOrder: [String] = [
            "real_step_one",
            "real_step_two",
        ]
    }
""")


def _build_fixture(root: Path, install_body: str, catalog: str) -> None:
    """Write the synthetic repo skeleton under `root`."""
    (root / "scripts").mkdir(parents=True, exist_ok=True)
    (root / "lib").mkdir(parents=True, exist_ok=True)
    (root / "gui" / "OstlerInstaller" / "Steps").mkdir(parents=True, exist_ok=True)
    (root / "gui" / "scripts").mkdir(parents=True, exist_ok=True)
    (root / "tests").mkdir(parents=True, exist_ok=True)

    (root / "install.sh").write_text(_SYNTHETIC_INSTALL_PRELUDE + install_body)
    (root / "lib" / "progress_emitter.sh").write_text(_SYNTHETIC_PROGRESS_EMITTER)
    (root / "gui" / "OstlerInstaller" / "ProgressProtocol.swift").write_text(
        _SYNTHETIC_PROGRESS_PROTOCOL
    )
    (root / "gui" / "OstlerInstaller" / "Steps" / "StepCatalog.swift").write_text(catalog)

    # Copy the real extractors and contract test into the fixture so
    # they import / run with the synthetic repo as their REPO_ROOT.
    shutil.copy2(EXTRACT_INSTALL, root / "scripts" / "extract_install_protocol.py")
    shutil.copy2(EXTRACT_GUI, root / "gui" / "scripts" / "extract_gui_renderers.py")
    shutil.copy2(
        REPO_ROOT / "tests" / "test_install_gui_contract.py",
        root / "tests" / "test_install_gui_contract.py",
    )


def _run_contract_test(root: Path) -> subprocess.CompletedProcess:
    """Run the contract test against the synthetic repo and capture."""
    env = os.environ.copy()
    # Force the contract test to see the synthetic root.
    return subprocess.run(
        [sys.executable, "-m", "unittest", "tests.test_install_gui_contract", "-v"],
        cwd=str(root),
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )


class NegativePathTests(unittest.TestCase):
    """Synthetic-fixture negatives proving the contract test bites."""

    maxDiff = None

    def test_unknown_prompt_kind_fails_contract(self) -> None:
        """Scenario (a): a gui_read with an unknown kind value.

        The synthetic install.sh emits a PROMPT with
        `kind=invented_kind`, which is not a PromptKind case.  The
        contract test's PROMPT-kind assertion must fail.
        """
        install_body = textwrap.dedent("""\
            # New prompt with a kind value not in PromptKind.
            ANSWER="$(gui_read "Synthetic question" invented_kind "" "" "" "new_test_prompt")"
        """)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _build_fixture(root, install_body, _SYNTHETIC_STEP_CATALOG_BASELINE)
            result = _run_contract_test(root)
        self.assertNotEqual(
            result.returncode, 0,
            f"Expected contract test to fail.\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        combined = result.stdout + result.stderr
        self.assertIn("PROTOCOL DRIFT", combined,
                      f"Expected DRIFT marker.  stderr:\n{result.stderr}")
        self.assertIn("invented_kind", combined,
                      f"Expected the bogus kind value to surface.  stderr:\n{result.stderr}")
        self.assertIn("new_test_prompt", combined,
                      f"Expected the prompt id to surface.  stderr:\n{result.stderr}")

    def test_uncovered_step_id_fails_contract(self) -> None:
        """Scenario (b1): a STEP_BEGIN id with no canonicalOrder entry.

        Synthetic install.sh emits `progress "..." "pu99_uncovered"`
        for an id NOT in canonicalOrder.  Contract test must fail
        with a PROTOCOL DRIFT message naming the offending id.
        """
        install_body = textwrap.dedent("""\
            # STEP_BEGIN id absent from canonicalOrder -- should fail.
            progress "Synthetic uncovered step" "pu99_uncovered"
        """)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _build_fixture(root, install_body, _SYNTHETIC_STEP_CATALOG_BASELINE)
            result = _run_contract_test(root)
        self.assertNotEqual(
            result.returncode, 0,
            f"Expected contract test to fail.\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        combined = result.stdout + result.stderr
        self.assertIn("PROTOCOL DRIFT", combined,
                      f"Expected DRIFT marker.  stderr:\n{result.stderr}")
        self.assertIn("pu99_uncovered", combined,
                      f"Expected the offending step id to surface.  stderr:\n{result.stderr}")

    def test_dead_canonical_order_entry_warns(self) -> None:
        """Scenario (b2): a canonicalOrder entry with no emitter.

        Synthetic StepCatalog adds `pu99_dead_handler` to
        canonicalOrder but no install.sh callsite matches.  Per the
        contract test design, this is a WARN (printed to stderr), not
        a fail -- canonicalOrder entries can be PHASE-driven or
        future-reserved.  We assert the warn is emitted AND the test
        as a whole still passes (no other drift in this fixture).
        """
        catalog = textwrap.dedent("""\
            import Foundation
            final class StepCatalog {
                static let canonicalOrder: [String] = [
                    "real_step_one",
                    "pu99_dead_handler",
                ]
            }
        """)
        install_body = textwrap.dedent("""\
            # Only emit the one canonicalOrder id that has a callsite.
            progress "Real step one" "real_step_one"
        """)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _build_fixture(root, install_body, catalog)
            result = _run_contract_test(root)
        combined = result.stdout + result.stderr
        self.assertEqual(
            result.returncode, 0,
            f"Expected contract test to pass with only a DEAD HANDLER warn."
            f"\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        self.assertIn("DEAD HANDLER", combined,
                      f"Expected DEAD HANDLER warn marker.  stderr:\n{result.stderr}")
        self.assertIn("pu99_dead_handler", combined,
                      f"Expected orphan id to surface in the warn.  stderr:\n{result.stderr}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
