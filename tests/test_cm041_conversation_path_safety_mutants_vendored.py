"""Mutation check for test_conversation_path_safety.py.

Each mutant removes ONE guard from a temp copy of ical-server.py and the
path-safety suite is run against it (ICAL_SERVER_UNDER_TEST). Every mutant
must make that suite FAIL. A mutant whose source edit did not apply is
reported as an error, not as a kill.
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Ported from CM041 #225 (e2dffc09) for the v1.0.112 vendored graft.
SERVER = HERE.parent / "vendor" / "cm041" / "assistant_api" / "ical-server.py"
SUITE = HERE / "test_cm041_conversation_path_safety_vendored.py"

# Containment (relative_to) is defence in depth behind the charset regex and
# the symlink check: with both of those intact no single-segment id can
# resolve outside the root, so removing containment ALONE is an equivalent
# mutant. It is therefore mutated together with the symlink guard, the
# only other thing that stops a symlink pointing outside the root.
MUTANTS = {
    "no_charset_regex": (
        "    return bool(_SAFE_CONVERSATION_ID_RE.match(conversation_id))",
        "    return bool(conversation_id)",
    ),
    "no_dotdot_check": (
        '    if ".." in conversation_id:\n        return False\n',
        "",
    ),
    "no_symlink_dir_check": (
        "    if raw.is_symlink():\n        return None\n    candidate = raw.resolve()",
        "    candidate = raw.resolve()",
    ),
    "no_symlink_state_check": (
        "    if state_file.is_symlink() or not state_file.is_file():",
        "    if not state_file.is_file():",
    ),
    "no_containment_no_symlink_guard": (
        "    if raw.is_symlink():\n        return None\n    candidate = raw.resolve()\n    try:\n        candidate.relative_to(root)\n    except ValueError:\n        return None\n    if candidate == root:",
        "    candidate = raw.resolve()\n    if False:",
    ),
    "status_skips_guard": (
        'def api_conversation_status(conversation_id):\n    """Handle GET /api/v1/conversation/status/{id}."""\n    conv_dir = _safe_conversation_dir(conversation_id)\n    if conv_dir is None:\n        return {"error": "Invalid conversation_id"}, 400',
        'def api_conversation_status(conversation_id):\n    """Handle GET /api/v1/conversation/status/{id}."""\n    conv_dir = PROCESSING_DIR / conversation_id',
    ),
    "writer_skips_guard": (
        "    state_dir = _safe_conversation_dir(conversation_id)\n    if state_dir is None:\n        return\n    state_dir.mkdir",
        "    state_dir = PROCESSING_DIR / conversation_id\n    state_dir.mkdir",
    ),
    "no_id_token_sanitiser": (
        '    return re.sub(r"[^\\w-]", "_", str(value))[:64]',
        "    return str(value)",
    ),
}


def _run_suite(server_file: Path) -> int:
    env = dict(os.environ, ICAL_SERVER_UNDER_TEST=str(server_file))
    return subprocess.run(
        [sys.executable, "-m", "pytest", str(SUITE), "-q", "-x",
         "--import-mode=importlib", "-p", "no:cacheprovider"],
        env=env, cwd=str(HERE.parent), capture_output=True, timeout=300,
    ).returncode


class Mutants(unittest.TestCase):
    def test_every_mutant_is_killed(self):
        src = SERVER.read_text(encoding="utf-8")
        # Control: the unmutated copy must pass, or "red" proves nothing.
        for name, (old, new) in MUTANTS.items():
            with self.subTest(mutant=name):
                self.assertEqual(src.count(old), 1, f"{name}: edit does not apply")
                with tempfile.TemporaryDirectory() as td:
                    # Same directory as the real file so relative imports resolve.
                    mutated = SERVER.parent / f".mutant_{name}.py"
                    try:
                        mutated.write_text(src.replace(old, new), encoding="utf-8")
                        self.assertNotEqual(_run_suite(mutated), 0,
                                            f"{name}: suite stayed green (mutant survived)")
                    finally:
                        mutated.unlink(missing_ok=True)

    def test_control_unmutated_is_green(self):
        self.assertEqual(_run_suite(SERVER), 0)


if __name__ == "__main__":
    unittest.main()
