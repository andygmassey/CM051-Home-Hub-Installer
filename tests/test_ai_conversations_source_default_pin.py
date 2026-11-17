"""134: CM052 vendored [source_default] table. Digest pinned; re-pin = bytes + digest in one PR.

The table's ai_conversations row must equal the locked transcript default (L3).
A default may never be below a locked default (Archie ruling 2026-11-17).
"""
import hashlib
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "vendor" / "cm052_ai_conversations" / "src"))

from cm052 import source_defaults as sd  # noqa: E402
from cm052 import wire  # noqa: E402

PINNED_SHA256 = "3f17bcebba9ea788e77c1c63789f324fb1fc44d83bfdf0b1f869c74bdacb2196"


def test_vendored_table_digest_is_pinned():
    assert hashlib.sha256(sd._TSV.read_bytes()).hexdigest() == PINNED_SHA256


def test_ai_conversations_row_is_locked_l3_and_matches_transcript_default():
    assert sd.default_level("ai_conversations") == "L3"
    assert wire._ARTEFACT_DEFAULT_ENV["transcript"][1] == "L3"
