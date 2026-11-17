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

PINNED_SHA256 = "d209fce91d109e12cddad6c27aafa3c33e8a5d66cb4a57c93f67cd8e8244d124"


def test_vendored_table_digest_is_pinned():
    assert hashlib.sha256(sd._TSV.read_bytes()).hexdigest() == PINNED_SHA256


def test_ai_conversations_row_is_l2_and_transcript_stays_l3():
    # The owner, 11-16 ("Keep 11-16"): AI conversations default L2; floor + classifier raise sensitive items.
    assert sd.default_level("ai_conversations") == "L2"
    assert wire._ARTEFACT_DEFAULT_ENV["transcript"][1] == "L3"
