#!/usr/bin/env python3
"""A dropped WhatsApp per-chat export is parsed and persisted, not skipped.

Owner direction, 2026-11-08 (Andy): WhatsApp chat exports auto-process. Before
this, lib/ostler-detect-exports.sh answered every "WhatsApp chat*.txt" with
skip, and universal_import had no dispatcher for whatsapp_export. Both are
now wired: the watcher answers import (only if WhatsApp was accepted at setup),
and the dispatcher parses the chat and drives the same pwg-convo sink the
Messenger leg uses.

Every fixture is SYNTHETIC. Names are placeholders. No real chat is read.

Each test below is RED on origin/main and GREEN on this branch. The
reference that proves it is the test output, pasted in the PR body.

Exit: 0 all pass, 1 a real failure, 2 cannot-run (never a silent pass).
Run:  python3 tests/test_whatsapp_export_autoprocess.py
"""
from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
import traceback
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "vendor"))

from ostler_fda import universal_import as ui  # noqa: E402

try:
    from ostler_fda import whatsapp_export as wae  # noqa: E402
except ImportError:
    # origin/main has no whatsapp_export module. The parser tests then fail
    # on wae.<attr> (a FAIL, not a silent pass); the watcher test still runs.
    wae = None

LIB = REPO / "lib" / "ostler-detect-exports.sh"
IOS = "\n".join([
    "[01/02/2026, 09:00:00] Alex Smith: Morning, are we still on for Friday?",
    "[01/02/2026, 09:01:12] Sam Jones: Yes. Bring the plans.",
    "[01/02/2026, 09:02:30] Alex Smith: <attached: 00001-PHOTO-2026-02-01.jpg>",
    "[01/02/2026, 09:03:00] Sam Jones: This is a long one",
    "and it continues on a second line",
    "[01/02/2026, 09:04:00] Messages and calls are end-to-end encrypted.",
    "[01/02/2026, 09:05:00] Alex Smith: <Media omitted>",
]) + "\n"
ANDROID = "\n".join([
    "15/03/2026, 18:10 - Alex Smith: See you at six",
    "15/03/2026, 18:11 - Sam Jones: Great",
    "15/03/2026, 18:12 - Sam Jones: <attached: 00002-AUDIO.opus>",
    "15/03/2026, 18:20 - Alex Smith joined using this group's invite link",
    "15/03/2026, 18:21 - Alex Smith: Multi-line",
    "second line here",
]) + "\n"


def _fake_pwg_convo(d: Path) -> tuple[Path, Path]:
    log = d / "calls.log"
    b = d / "pwg-convo"
    b.write_text(
        "#!/usr/bin/env bash\n"
        'if [[ "${1:-}" == "process" ]]; then\n'
        f'  python3 -c "import json,sys;m=json.load(open(sys.argv[1]));'
        f"print(m['conversation_id'], m['channel'], m['privacy_level'], m['message_count'])\" \"$3\" >> \"{log}\"\n"
        "fi\n"
        "exit 0\n"
    )
    b.chmod(b.stat().st_mode | stat.S_IEXEC)
    return b, log


def _write(d: Path, name: str, text: str) -> Path:
    p = d / name
    p.write_text(text, encoding="utf-8")
    return p


def test_ios_and_android_lines_parse():
    ios = wae.parse_chat_text(IOS, "synthetic group")
    assert [m.sender for m in ios.messages] == [
        "Alex Smith", "Sam Jones", "Alex Smith", "Sam Jones", "Alex Smith"
    ], ios.messages
    assert ios.messages[0].timestamp.isoformat() == "2026-02-01T09:00:00"
    and_ = wae.parse_chat_text(ANDROID, "synthetic group")
    assert [m.sender for m in and_.messages] == [
        "Alex Smith", "Sam Jones", "Sam Jones", "Alex Smith"
    ], and_.messages
    # Day-first: 15/03/2026 is 15 March, not a month-15 error.
    assert and_.messages[0].timestamp.isoformat() == "2026-03-15T18:10:00"


def test_multiline_message_is_joined_not_dropped():
    ios = wae.parse_chat_text(IOS, "synthetic group")
    assert ios.messages[3].text == "This is a long one\nand it continues on a second line", repr(ios.messages[3].text)
    and_ = wae.parse_chat_text(ANDROID, "synthetic group")
    assert and_.messages[3].text == "Multi-line\nsecond line here", repr(and_.messages[3].text)


def test_media_placeholders_and_system_lines():
    ios = wae.parse_chat_text(IOS, "synthetic group")
    texts = [m.text for m in ios.messages]
    assert texts[2] == "[attachment]" and texts[4] == "[attachment]", texts
    # The end-to-end system line is not attached to the message above it.
    assert "end-to-end" not in texts[3], texts[3]
    and_ = wae.parse_chat_text(ANDROID, "synthetic group")
    # Android "joined using" has no "Name: " part, so it is a system line.
    assert all("invite link" not in m.text for m in and_.messages)
    assert and_.messages[2].text == "[attachment]", and_.messages[2].text


def test_payload_is_cm048_shape_and_l2():
    chat = wae.parse_chat_text(ANDROID, "synthetic group")
    p = wae.chat_to_payload(chat)
    assert set(p) == {"conversation_id", "transcript", "metadata"}, p.keys()
    assert p["metadata"]["privacy_level"] == "L2"
    assert p["metadata"]["channel"] == "whatsapp"
    assert p["metadata"]["message_count"] == 4
    assert p["conversation_id"] == wae.chat_to_payload(chat)["conversation_id"], "id must be stable"
    assert p["transcript"].splitlines()[0] == "[2026-03-15 18:10] Alex Smith: See you at six"


def test_loose_whatsapp_txt_is_detected_and_persisted_via_pwg_convo():
    d = Path(tempfile.mkdtemp(prefix="wae-persist-"))
    f = _write(d, "WhatsApp Chat with synthetic group.txt", IOS)
    det = ui.detect_format(f)
    assert det.format == "whatsapp_export", det.format
    bin_path, log = _fake_pwg_convo(d)
    old = os.environ.get("OSTLER_PWG_CONVO_CMD")
    os.environ["OSTLER_PWG_CONVO_CMD"] = str(bin_path)
    try:
        res = ui._dispatch(det, dry_run=False, output_dir=d / "out")
    finally:
        if old is None:
            os.environ.pop("OSTLER_PWG_CONVO_CMD", None)
        else:
            os.environ["OSTLER_PWG_CONVO_CMD"] = old
    assert res["status"] == "ok", res
    assert res["persist_status"] == "ok", res
    assert res["persisted"] == 1, res
    rows = [l.split() for l in log.read_text().splitlines() if l]
    assert len(rows) == 1, rows
    cid, channel, level, count = rows[0]
    assert channel == "whatsapp" and level == "L2" and count == "5", rows[0]


def test_watcher_answers_import_for_a_dropped_chat_and_zip():
    d = Path(tempfile.mkdtemp(prefix="wae-watch-"))
    _write(d, "WhatsApp Chat with synthetic group.txt", IOS)
    zdir = d / "zipped"
    zdir.mkdir()
    with zipfile.ZipFile(zdir / "WhatsApp Chat - Synthetic.zip", "w") as z:
        z.writestr("_chat.txt", IOS)
    # The customer accepted WhatsApp at setup (the consent registry the watcher
    # reads); without it the watcher answers skip, which is tested in
    # tests/test_no_whatsapp_chat_export_instruction.sh section 3.
    home = d / "ostler"
    (home / "posture").mkdir(parents=True)
    (home / "posture" / "consent.json").write_text(
        '{\n  "schema_version": 1,\n  "records": {\n    "whatsapp_unofficial_risk": {\n'
        '      "tickbox_id": "whatsapp_unofficial_risk",\n      "decision": "accepted"\n    }\n  }\n}\n')
    env = {"PATH": os.environ.get("PATH", ""), "HOME": str(d), "LC_ALL": "C", "OSTLER_HOME": str(home)}
    subprocess.run(["bash", str(LIB), str(d), "--unzip"], capture_output=True, env=env, check=False)
    out = subprocess.run(["bash", str(LIB), str(d), "--loose"], capture_output=True, text=True, env=env, check=False).stdout
    rows = [l.split("\t") for l in out.splitlines() if "WhatsApp" in l]
    verdicts = {Path(r[1]).name: r[2] for r in rows}
    assert verdicts.get("WhatsApp Chat with synthetic group.txt") == "import", out
    assert verdicts.get("_chat.txt") == "import", out


TESTS = [
    test_ios_and_android_lines_parse,
    test_multiline_message_is_joined_not_dropped,
    test_media_placeholders_and_system_lines,
    test_payload_is_cm048_shape_and_l2,
    test_loose_whatsapp_txt_is_detected_and_persisted_via_pwg_convo,
    test_watcher_answers_import_for_a_dropped_chat_and_zip,
]


def main() -> int:
    failed = 0
    for t in TESTS:
        try:
            t()
            print(f"  ok   {t.__name__}")
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print(f"  FAIL {t.__name__}: {exc!r}")
            if os.environ.get("WAE_TRACE"):
                traceback.print_exc()
    print("PASS" if failed == 0 else f"FAIL ({failed} of {len(TESTS)})")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
