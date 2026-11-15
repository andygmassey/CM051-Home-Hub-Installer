"""The forget scrub and the bundle writer must resolve the SAME conversations root.

THE DEFECT. The derive plist exported OSTLER_CONVERSATIONS_DIR=<transcript mirror>. CM048's
settings honoured that name, so the bundle writer and the forget scrub (both read
settings.output_conversations_dir) were pointed at the mirror. A forget then scrubbed a
folder the writer never used, and the customer bundle kept the forgotten text.

ARMS (synthetic paths under a temp HOME; no real ~/Ostler or ~/.ostler):
  A. with the derive mirror env set, the writer root is still ~/Ostler/Conversations;
  B. the writer root equals the scrub root (the same field the scrub reads);
  C. the writer root is not the mirror.
RED: on a vendored settings.py that still honours OSTLER_CONVERSATIONS_DIR, arm A and C fail.
Run with the vendored tree on sys.path (CANNOT-RUN if the vendored module will not import).
"""
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
VENDOR = Path(os.environ.get("CM048_VENDOR_SRC", HERE.parent / "vendor" / "cm048_pipeline" / "src"))
TMP = Path(tempfile.mkdtemp(prefix="writer-scrub-dir-"))
os.environ["HOME"] = str(TMP)
MIRROR = TMP / ".ostler" / "state" / "conversations_mirror"
os.environ["OSTLER_CONVERSATIONS_DIR"] = str(MIRROR)  # the name the old derive plist exported
os.environ["OSTLER_USER_ID"] = "synthowner"

sys.path.insert(0, str(VENDOR.parent))
try:
    from src import ostler_paths  # noqa: E402
    from src.settings import Settings, settings_from_env_override  # noqa: E402
except Exception as exc:  # pragma: no cover
    print("CANNOT-RUN: vendored cm048 settings did not import: %s" % exc)
    sys.exit(2)

WRITER_ROOT = Path(settings_from_env_override(Settings(user_id="synthowner")).output_conversations_dir)
EXPECTED = ostler_paths.conversations_dir()


def test_A_mirror_env_does_not_move_the_writer_root():
    assert WRITER_ROOT == EXPECTED, "writer root %s, expected %s" % (WRITER_ROOT, EXPECTED)


def test_B_writer_root_is_the_scrub_root():
    # forget_sweep.scrub_conversation_files reads settings.output_conversations_dir as well
    scrub_root = Path(settings_from_env_override(Settings(user_id="synthowner")).output_conversations_dir)
    assert scrub_root == WRITER_ROOT


def test_C_writer_root_is_not_the_mirror():
    assert WRITER_ROOT != MIRROR and MIRROR not in WRITER_ROOT.parents


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print("PASS", name)
