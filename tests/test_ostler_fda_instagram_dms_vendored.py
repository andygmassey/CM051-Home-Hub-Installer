# VENDORED copy of HR015 ostler_fda/tests/test_instagram_dms.py at fd10f28 (#1164); runs against vendor/ostler_fda.
"""Tests for the Instagram DM importer (Download Your Information export).

Fixtures are synthetic and built from Meta's documented DYI JSON shape; no
real export was opened (see the UNVERIFIED list in instagram_dms.py). Every
person is a placeholder from the approved cast. Every string is written the
way Meta writes it: UTF-8 bytes escaped as latin-1 code points, so the
mojibake repair is exercised against the real failure mode.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1] / "vendor"
sys.path.insert(0, str(REPO_ROOT))

from ostler_fda import instagram_dms as igd  # noqa: E402
from ostler_fda import universal_import as ui  # noqa: E402

OPERATOR = "Jane Doe"


def _meta(s: str) -> str:
    """Encode a string the way Meta's DYI export does (mojibake)."""
    return s.encode("utf-8").decode("latin-1")


def _thread(inbox: Path, slug: str, participants, messages, title=None):
    d = inbox / slug
    d.mkdir(parents=True, exist_ok=True)
    data = {
        "participants": [{"name": _meta(p)} for p in participants],
        "messages": [
            {**m, "sender_name": _meta(m["sender_name"]),
             **({"content": _meta(m["content"])} if "content" in m else {})}
            for m in messages
        ],
        "title": _meta(title if title is not None else participants[0]),
        "is_still_participant": True,
        "thread_path": f"inbox/{slug}",
        "magic_words": [],
    }
    # ensure_ascii=True reproduces Meta's Ã© escapes on disk.
    (d / "message_1.json").write_text(json.dumps(data), encoding="utf-8")
    return d


def _profile(root: Path, name: str = OPERATOR, username: str = "operator.person", nested=True):
    rel = ("personal_information/personal_information/personal_information.json"
           if nested else "personal_information/personal_information.json")
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps({"profile_user": [{"string_map_data": {
        "Name": {"href": "", "value": _meta(name), "timestamp": 0},
        "Username": {"href": "", "value": username, "timestamp": 0},
    }}]}))


def _export(root: Path, *, layout="current", with_profile=True) -> Path:
    base = root / "your_instagram_activity" / "messages" if layout == "current" else root / "messages"
    inbox = base / "inbox"
    _thread(inbox, "jane.smith_1234567890", [ "Jane Smith", OPERATOR], [
        {"sender_name": "Jane Smith", "timestamp_ms": 1700000300000, "content": "Café at 6? \U0001F600"},
        {"sender_name": OPERATOR, "timestamp_ms": 1700000100000, "content": "Are we still on for tonight"},
        {"sender_name": OPERATOR, "timestamp_ms": 1700000400000, "content": "Liked a message"},
        {"sender_name": "Jane Smith", "timestamp_ms": 1700000500000, "content": "Reacted ❤ to your message"},
        {"sender_name": "Jane Smith", "timestamp_ms": 1700000600000, "photos": [{"uri": "x.jpg", "creation_timestamp": 1}]},
    ])
    _thread(inbox, "weekendcrew_9876543210", ["Bob Jones", "Mary Patel", OPERATOR], [
        {"sender_name": "Bob Jones", "timestamp_ms": 1700001000000, "content": "Who is driving"},
        {"sender_name": OPERATOR, "timestamp_ms": 1700001100000, "content": "I can"},
    ], title="Weekend Crew")
    # A request thread: must be skipped by default.
    _thread(base / "message_requests", "stranger.account_5555555555", ["Raj Brown", OPERATOR], [
        {"sender_name": "Raj Brown", "timestamp_ms": 1700002000000, "content": "hey"},
    ])
    if with_profile:
        _profile(root)
    return root


# ── parser ────────────────────────────────────────────────────────────


def test_parses_current_layout_and_repairs_mojibake(tmp_path, monkeypatch):
    monkeypatch.delenv("OSTLER_USER_DISPLAY_NAME", raising=False)
    monkeypatch.delenv("WIKI_OPERATOR_NAME", raising=False)
    threads = igd.parse_export(_export(tmp_path))
    assert len(threads) == 2
    dm = next(t for t in threads if not t.is_group)
    transcript = igd.render_transcript(dm)
    assert "Café at 6? \U0001F600" in transcript
    assert "Ã" not in transcript  # no residual mojibake


def test_operator_comes_from_export_profile_not_env(tmp_path, monkeypatch):
    # The installer name differs from the Instagram display name: the
    # export's own profile must win, or every thread is skipped.
    monkeypatch.setenv("OSTLER_USER_DISPLAY_NAME", "Some Person")
    root = _export(tmp_path)
    assert igd.resolve_operator_name(root) == OPERATOR
    assert len(igd.parse_export(root)) == 2


def test_env_fallback_when_no_profile(tmp_path, monkeypatch):
    monkeypatch.setenv("OSTLER_USER_DISPLAY_NAME", OPERATOR)
    root = _export(tmp_path, with_profile=False)
    assert igd.resolve_operator_name(root) == OPERATOR
    assert len(igd.parse_export(root)) == 2


def test_no_operator_anywhere_skips_every_thread(tmp_path, monkeypatch):
    monkeypatch.delenv("OSTLER_USER_DISPLAY_NAME", raising=False)
    monkeypatch.delenv("WIKI_OPERATOR_NAME", raising=False)
    root = _export(tmp_path, with_profile=False)
    assert igd.parse_export(root) == []
    assert igd.main(["--export-path", str(root), "--dry-run"]) == 0


def test_likes_and_reactions_are_dropped_media_is_kept(tmp_path):
    dm = next(t for t in igd.parse_export(_export(tmp_path)) if not t.is_group)
    texts = [m.text for m in dm.messages]
    assert "Liked a message" not in texts
    assert not any(t.startswith("Reacted ") for t in texts)
    assert "[photo]" in texts
    assert len(dm.messages) == 3


def test_message_requests_skipped_by_default_and_counted(tmp_path):
    root = _export(tmp_path)
    slugs = {t.thread_slug for t in igd.parse_export(root)}
    assert "stranger.account_5555555555" not in slugs
    assert igd.count_message_requests(root) == 1
    with_req = {t.thread_slug for t in igd.parse_export(root, include_requests=True)}
    assert "stranger.account_5555555555" in with_req


def test_legacy_flat_layout(tmp_path):
    root = _export(tmp_path, layout="legacy")
    assert len(igd.parse_export(root)) == 2


def test_chronological_order(tmp_path):
    dm = next(t for t in igd.parse_export(_export(tmp_path)) if not t.is_group)
    ts = [m.timestamp_ms for m in dm.messages]
    assert ts == sorted(ts)


# ── payloads ──────────────────────────────────────────────────────────


def test_payload_shape_privacy_and_handle(tmp_path):
    threads = igd.parse_export(_export(tmp_path))
    payloads = igd.ingestible_payloads(threads)
    assert len(payloads) == 2
    for p in payloads:
        md = p["metadata"]
        assert md["channel"] == "instagram"
        assert md["privacy_level"] == "L2"
        assert p["conversation_id"].startswith("igd_")
        assert md["participants"][0] == {"id": OPERATOR, "display": OPERATOR, "role": "user"}
    dm = next(p for p in payloads if not p["metadata"]["is_group_chat"])
    other = dm["metadata"]["participants"][1]
    assert other["display"] == "Jane Smith"
    assert other["instagram"] == "jane.smith"
    grp = next(p for p in payloads if p["metadata"]["is_group_chat"])
    assert all("instagram" not in e for e in grp["metadata"]["participants"])
    assert grp["metadata"]["group_subject"] == "Weekend Crew"


def test_ids_stable_across_reimport_and_distinct_from_messenger(tmp_path):
    a = {p["conversation_id"] for p in igd.ingestible_payloads(igd.parse_export(_export(tmp_path / "a")))}
    b = {p["conversation_id"] for p in igd.ingestible_payloads(igd.parse_export(_export(tmp_path / "b")))}
    assert a == b and len(a) == 2
    from ostler_fda import facebook_messenger as fbm
    t = igd.parse_export(_export(tmp_path / "c"))[0]
    assert igd.thread_conversation_id(t) != fbm.thread_conversation_id(t)


def test_cli_json_is_counts_only(tmp_path, capsys):
    root = _export(tmp_path)
    out = tmp_path / "out"
    assert igd.main(["--export-path", str(root), "--output-dir", str(out), "--json"]) == 0
    line = capsys.readouterr().out.strip().splitlines()[-1]
    data = json.loads(line)
    assert data["status"] == "ok"
    assert data["ingestible_threads"] == 2
    assert data["message_requests_skipped"] == 1
    for banned in ("Jane", "Smith", "jane.smith", "Caf", OPERATOR):
        assert banned not in line
    staged = json.loads((out / igd.OUTPUT_FILENAME).read_text())
    assert len(staged) == 2


def test_cli_missing_export_is_graceful(tmp_path, capsys):
    assert igd.main(["--export-path", str(tmp_path / "nope"), "--json"]) == 0
    assert json.loads(capsys.readouterr().out.strip())["status"] == "not_found"


# ── universal_import detection + dispatch, end to end ────────────────


def _fake_pwg_convo(tmp_path: Path):
    log = tmp_path / "calls.log"
    meta_log = tmp_path / "meta.log"
    b = tmp_path / "pwg-convo"
    b.write_text(
        "#!/usr/bin/env bash\n"
        'if [[ "${1:-}" == "process" ]]; then\n'
        f'  python3 -c "import json,sys;m=json.load(open(sys.argv[1]));print(m[\'conversation_id\'], m[\'channel\'], m[\'privacy_level\'])" "$3" >> "{log}"\n'
        "fi\n"
        "exit 0\n"
    )
    b.chmod(0o755)
    return b, log


def test_detects_current_layout_as_instagram(tmp_path):
    det = ui.detect_format(_export(tmp_path))
    assert det.format == "instagram_dms"
    assert det.confidence == 1.0


def test_detects_legacy_flat_layout_as_instagram_not_facebook(tmp_path):
    # The flat messages/inbox shape is identical to an old Facebook export;
    # only the Instagram profile marker tells them apart.
    det = ui.detect_format(_export(tmp_path, layout="legacy"))
    assert det.format == "instagram_dms"


def test_flat_inbox_without_instagram_marker_is_still_facebook(tmp_path):
    # Negative control: the new detector must not steal Facebook exports.
    root = _export(tmp_path, layout="legacy", with_profile=False)
    assert ui.detect_format(root).format == "facebook_messenger"


def test_universal_import_persists_end_to_end_and_reimport_is_same_ids(tmp_path, monkeypatch):
    root = _export(tmp_path / "ig")
    bin_path, log = _fake_pwg_convo(tmp_path)
    monkeypatch.setenv("OSTLER_PWG_CONVO_CMD", str(bin_path))

    first = ui.import_path(root, output_dir=tmp_path / "out")["result"]
    assert first["format"] == "instagram_dms"
    assert first["status"] == "ok"
    assert first["persist_status"] == "ok"
    assert first["persisted"] == 2
    assert first["summary"]["message_requests_skipped"] == 1
    rows1 = [l.split() for l in log.read_text().splitlines() if l]
    assert len(rows1) == 2
    assert all(ch == "instagram" and lvl == "L2" for _, ch, lvl in rows1)

    # Re-import: CM048's writer keys on conversation_id, so identical ids
    # mean zero new bundles.
    ui.import_path(root, output_dir=tmp_path / "out")
    rows = [l.split()[0] for l in log.read_text().splitlines() if l]
    assert len(rows) == 4
    assert sorted(rows[:2]) == sorted(rows[2:])


def test_universal_import_cli_exit_zero(tmp_path, monkeypatch, capsys):
    root = _export(tmp_path / "ig")
    bin_path, _ = _fake_pwg_convo(tmp_path)
    monkeypatch.setenv("OSTLER_PWG_CONVO_CMD", str(bin_path))
    assert ui.main([str(root), "--output-dir", str(tmp_path / "out"), "--json"]) == 0
    out = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert out["result"]["dispatched"] == "instagram_dms"


def test_facebook_export_with_lookalike_dirs_stays_on_messenger_path(tmp_path):
    # Archie #1164: a real Facebook DYI export has its own connections/ and
    # personal_information/ trees. Bare directory names, and a
    # personal_information.json without Instagram's profile_user/Username
    # content, must NOT pull a Messenger export onto the Instagram path.
    root = _export(tmp_path, layout="legacy", with_profile=False)
    for d in ("connections/followers_and_following", "followers_and_following",
              "personal_information/personal_information", "personal_information/profile_information"):
        (root / d).mkdir(parents=True, exist_ok=True)
    (root / "personal_information/personal_information.json").write_text(
        json.dumps({"profile_v2": {"name": {"full_name": "Jane Doe"}}}))
    (root / "personal_information/profile_information/profile_information.json").write_text(
        json.dumps({"profile_v2": {"name": {"full_name": "Jane Doe"}}}))
    (root / "connections/followers_and_following/followers.json").write_text(
        json.dumps({"followers_v2": []}))
    (root / "connections/followers_and_following/following.json").write_text(
        json.dumps({"following_v3": []}))
    assert ui.detect_format(root).format == "facebook_messenger"


def test_following_file_marker_identifies_legacy_instagram(tmp_path):
    root = _export(tmp_path, layout="legacy", with_profile=False)
    f = root / "connections/followers_and_following/following.json"
    f.parent.mkdir(parents=True)
    f.write_text(json.dumps({"relationships_following": []}))
    det = ui.detect_format(root)
    assert det.format == "instagram_dms"
    assert "following.json" in det.signal
