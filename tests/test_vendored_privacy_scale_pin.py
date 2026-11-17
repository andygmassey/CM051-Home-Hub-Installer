"""Every vendored copy of the shared privacy scale table and loader is the shared bytes.

The pair is byte-identical in CM019, CM041, CM044, CM048 and CM052 (each pins
the same sha256). CM051 vendors it three times: vendor/cm041 (repo root),
vendor/cm048_pipeline (repo root) and vendor/cm052_ai_conversations/src/cm052.
A copy that drifts, or a vendored tree that loses its copy, fails here.
"""
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PINNED_SHA256 = {
    "privacy_scale_canonical.tsv": "77a99d94e81b5d1e70bc422aba6ba505bb9df71a8f78ebbcfddeea9637ee50cc",
    "privacy_scale.py": "3106baf3e9ca7edd55f9ff650653a4261dd5628d8669456c8229596f7ebda57e",
}
EXPECTED_DIRS = ("vendor/cm041", "vendor/cm048_pipeline", "vendor/cm052_ai_conversations/src/cm052")


def _sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def test_every_expected_tree_carries_the_pair():
    for d in EXPECTED_DIRS:
        for name in PINNED_SHA256:
            assert (ROOT / d / name).exists(), f"{d}/{name} missing"


def test_every_vendored_copy_is_the_shared_bytes():
    seen = 0
    for name, want in PINNED_SHA256.items():
        for p in (ROOT / "vendor").rglob(name):
            seen += 1
            assert _sha(p) == want, f"{p.relative_to(ROOT)}: {_sha(p)} != pinned {want}"
    assert seen == 2 * len(EXPECTED_DIRS), seen
