"""Adding the Instagram route (HR015 #1164) must not move ANY Facebook export.

Archie 118 condition: a wrongly-claimed Facebook export breaks a working import.
Every Facebook-shaped fixture the repo's existing tests use is rebuilt here and
pushed through universal_import's dispatcher (import_path -> detect_format ->
_dispatch, with the two handlers replaced by recorders). Each must reach the
Facebook handler and never the Instagram one.

FIXTURE SOURCES (all rebuilt from the other tests' own constants where they
exist, so a new layout added there is picked up here):
  * HR015 test_universal_import: flat messages/inbox, your_facebook_activity,
    your_activity_across_facebook, a root that is itself `inbox`
  * tests/test_parser_claims_do_not_cross_services.py FACEBOOK_MEMBERS (the full
    11-member DYI tree) and its zip form
  * tests/test_whatsapp_parser_does_not_claim_meta_messages.py META_MESSAGE_FILES
    (Facebook entry, dropped as "01 - Facebook")
  * tests/test_ostler_fda_instagram_dms_vendored.py lookalike dirs (FB
    personal_information / connections trees beside a flat inbox)

MIXED-ROOT RULE (explicit): Facebook wins on conflict. Instagram is claimed only
on a positive Instagram signal (a your_instagram_activity root, or a flat
messages/inbox beside an Instagram-only marker) AND no Facebook-named activity
root with a valid inbox in the same root.

MUTANT CONTROL: the Instagram marker is made non-exclusive (always "present");
the flat Facebook fixtures must then flip to Instagram, proving the fixtures can
see the difference. Run by hand against the shipped file as well (see PR body).
"""
import json
import sys
import zipfile
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "vendor"))
sys.path.insert(0, str(HERE))

from ostler_fda import universal_import as ui  # noqa: E402
import test_parser_claims_do_not_cross_services as cross  # noqa: E402
import test_whatsapp_parser_does_not_claim_meta_messages as meta  # noqa: E402

THREAD = {
    "participants": [{"name": "Jane Doe"}, {"name": "John Doe"}],
    "messages": [{"sender_name": "Jane Doe", "timestamp_ms": 1609459200000, "content": "hello"}],
    "title": "Jane Doe", "thread_path": "inbox/t1",
}


def _w(root, rel, data=None):
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(THREAD if data is None else data))
    return p


def _fb_flat(root):
    _w(root, "messages/inbox/someone_abc123/message_1.json")


def _fb_current(root):
    _w(root, "your_facebook_activity/messages/inbox/someone_abc123/message_1.json")


def _fb_legacy(root):
    _w(root, "your_activity_across_facebook/messages/inbox/someone_abc123/message_1.json")


def _fb_inbox_root(root):
    inbox = root / "inbox"
    _w(inbox, "someone_abc123/message_1.json")
    return inbox


def _fb_full_tree(root):
    for rel in cross.FACEBOOK_MEMBERS:
        _w(root, rel, THREAD if rel.endswith("message_1.json") else {})


def _fb_meta_drop(root):
    for rel in meta.META_MESSAGE_FILES:
        if "Facebook" in rel:
            _w(root, rel.split("/", 1)[1], THREAD)


def _fb_lookalikes(root):
    _fb_flat(root)
    _w(root, "personal_information/personal_information.json", {"profile_v2": {"name": {"full_name": "Jane Doe"}}})
    _w(root, "personal_information/profile_information/profile_information.json", {"profile_v2": {"name": {"full_name": "Jane Doe"}}})
    _w(root, "connections/followers_and_following/following.json", {"following_v3": []})
    _w(root, "connections/followers_and_following/followers.json", {"followers_v2": []})


def _fb_full_plus_following_key(root):
    # FB tree whose following.json is the FACEBOOK key (not relationships_following)
    _fb_full_tree(root)
    _w(root, "connections/followers_and_following/following.json", {"following_v3": []})


FB_BUILDERS = {
    "flat messages/inbox": _fb_flat,
    "your_facebook_activity": _fb_current,
    "your_activity_across_facebook": _fb_legacy,
    "root is inbox": _fb_inbox_root,
    "full DYI tree (cross-service FACEBOOK_MEMBERS)": _fb_full_tree,
    "dropped as '01 - Facebook' (meta fixture)": _fb_meta_drop,
    "flat inbox + FB lookalike dirs": _fb_lookalikes,
    "full tree + FB following key": _fb_full_plus_following_key,
}


@pytest.fixture()
def routed(monkeypatch):
    calls = []

    def rec(name):
        def h(detection, *, output_dir):
            calls.append(name)
            return {"status": "ok", "dispatched": name}
        return h

    monkeypatch.setitem(ui._DISPATCH, "facebook_messenger", rec("facebook_messenger"))
    monkeypatch.setitem(ui._DISPATCH, "instagram_dms", rec("instagram_dms"))
    return calls


def _route(root, calls, tmp_path):
    out = ui.import_path(root, output_dir=tmp_path / "out")
    return out["result"]["format"], list(calls)


@pytest.mark.parametrize("name", sorted(FB_BUILDERS))
def test_every_facebook_fixture_still_routes_to_facebook(name, tmp_path, routed):
    root = tmp_path / "export"
    root.mkdir()
    r = FB_BUILDERS[name](root) or root
    fmt, calls = _route(r, routed, tmp_path)
    assert fmt == "facebook_messenger", (name, fmt)
    assert calls == ["facebook_messenger"], (name, calls)


def test_facebook_zip_still_routes_to_facebook(tmp_path, routed):
    src = tmp_path / "src"
    src.mkdir()
    _fb_full_tree(src)
    z = tmp_path / "facebook-synthetic-user-2026-01-01.zip"
    with zipfile.ZipFile(z, "w") as zf:
        for f in src.rglob("*"):
            if f.is_file():
                zf.write(f, f.relative_to(src).as_posix())
    fmt, calls = _route(z, routed, tmp_path)
    assert (fmt, calls) == ("facebook_messenger", ["facebook_messenger"])


def _ig_current(root):
    _w(root, "your_instagram_activity/messages/inbox/t/message_1.json")


def _ig_flat_with_marker(root):
    _w(root, "messages/inbox/t/message_1.json")
    _w(root, "connections/followers_and_following/following.json", {"relationships_following": []})


@pytest.mark.parametrize("build", [_ig_current, _ig_flat_with_marker])
def test_instagram_only_fixture_routes_to_instagram(build, tmp_path, routed):
    root = tmp_path / "ig"
    root.mkdir()
    build(root)
    fmt, calls = _route(root, routed, tmp_path)
    assert (fmt, calls) == ("instagram_dms", ["instagram_dms"])


def test_mixed_root_is_decided_by_the_named_rule_facebook_wins(tmp_path, routed):
    root = tmp_path / "both"
    root.mkdir()
    _fb_current(root)
    _ig_current(root)
    _ig_flat_with_marker(root)
    fmt, calls = _route(root, routed, tmp_path)
    assert (fmt, calls) == ("facebook_messenger", ["facebook_messenger"])


def test_mutant_non_exclusive_instagram_marker_flips_flat_facebook(tmp_path, routed, monkeypatch):
    """CONTROL: with the Instagram-exclusive marker dropped, a flat Facebook
    export is claimed by Instagram. If this does not flip, the tests above
    could not have seen the defect."""
    monkeypatch.setattr(ui, "_has_instagram_marker", lambda root: "mutant-marker")
    root = tmp_path / "fb"
    root.mkdir()
    _fb_flat(root)
    fmt, calls = _route(root, routed, tmp_path)
    assert (fmt, calls) == ("instagram_dms", ["instagram_dms"])
