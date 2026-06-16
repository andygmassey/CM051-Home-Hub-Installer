"""Tests for the release-manifest reader + Doctor version surface.

WORKSTREAM C / C2. Closes the writer/reader contract between CM051
install.sh (which writes ~/.ostler/ostler-release.json via
lib/release_manifest.sh) and the Doctor version surface that reads it.

Covers the happy path plus every backwards-tolerant edge case the
convention (launch/BACKWARDS_TOLERANT_READERS.md) demands: absent file,
malformed JSON, a non-object payload, nested vs flat shapes, an unknown
schema version, and missing/null component pins. A version surface that
500s the dashboard on a malformed manifest is a regression even when the
happy-path test passes -- the rendered-HTML assertions guard that axis.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
from unittest import mock


V1_MANIFEST = {
    "manifest_schema_version": "1",
    "ostler_version": "v1.0.1",
    "installer_version": "v1.0.1",
    "channel": "stable",
    "daemon": {"version": "0.4.12", "tag": "hub-v0.4.12"},
    "wiki": {
        "site_image_sha": "sha256:b7cf8ba6cc8365482206283110bc3f1b337c0c243b556b0fb0ccd9952f34f7ea",
        "compiler_image_sha": None,
    },
    "source_repos": {"cm051": "abc123def456", "hr015": "0123456789ab"},
    "built_at": "2026-06-16T09:00:00Z",
    "installed_at": "2026-06-16T11:42:13Z",
}


def _write(tmp_path: Path, payload) -> Path:
    home = tmp_path / ".ostler"
    home.mkdir(parents=True, exist_ok=True)
    f = home / "ostler-release.json"
    if isinstance(payload, str):
        f.write_text(payload, encoding="utf-8")
    else:
        f.write_text(json.dumps(payload), encoding="utf-8")
    return home


# ── Reader: happy path ───────────────────────────────────────────────


def test_read_v1_manifest(tmp_path):
    import release_manifest as rm

    home = _write(tmp_path, V1_MANIFEST)
    with mock.patch.dict(os.environ, {"OSTLER_HOME": str(home)}):
        m = rm.read_release_manifest()

    assert m is not None
    assert m["ostler_version"] == "v1.0.1"
    assert m["daemon_version"] == "0.4.12"
    assert m["daemon_tag"] == "hub-v0.4.12"
    assert m["wiki_site_image_sha"].startswith("sha256:")
    assert m["wiki_compiler_image_sha"] is None  # null distinguished from absent
    assert m["source_repos"]["cm051"] == "abc123def456"
    assert m["schema_known"] is True


# ── Reader: backwards-tolerant edge cases ────────────────────────────


def test_absent_manifest_returns_none(tmp_path):
    import release_manifest as rm

    home = tmp_path / ".ostler"
    home.mkdir()
    with mock.patch.dict(os.environ, {"OSTLER_HOME": str(home)}):
        assert rm.read_release_manifest() is None


def test_malformed_json_returns_none(tmp_path):
    import release_manifest as rm

    home = _write(tmp_path, "not json {")
    with mock.patch.dict(os.environ, {"OSTLER_HOME": str(home)}):
        assert rm.read_release_manifest() is None


def test_non_object_payload_returns_none(tmp_path):
    import release_manifest as rm

    home = _write(tmp_path, "[1, 2, 3]")
    with mock.patch.dict(os.environ, {"OSTLER_HOME": str(home)}):
        assert rm.read_release_manifest() is None


def test_unknown_schema_is_read_but_flagged(tmp_path):
    import release_manifest as rm

    home = _write(
        tmp_path,
        {"manifest_schema_version": "99", "ostler_version": "v2.0.0", "future": "x"},
    )
    with mock.patch.dict(os.environ, {"OSTLER_HOME": str(home)}):
        m = rm.read_release_manifest()
    assert m is not None
    assert m["ostler_version"] == "v2.0.0"
    assert m["schema_known"] is False
    # absent nested objects default cleanly, never raise
    assert m["daemon_version"] is None
    assert m["source_repos"] == {}


def test_flat_daemon_shape_tolerated(tmp_path):
    """A build that wrote daemon fields flat (not nested) still reads."""
    import release_manifest as rm

    home = _write(
        tmp_path,
        {
            "manifest_schema_version": "1",
            "ostler_version": "v1.0.0",
            "daemon_version": "0.4.11",
            "daemon_tag": "hub-v0.4.11",
        },
    )
    with mock.patch.dict(os.environ, {"OSTLER_HOME": str(home)}):
        m = rm.read_release_manifest()
    assert m["daemon_version"] == "0.4.11"
    assert m["daemon_tag"] == "hub-v0.4.11"


# ── status_collector.collect_pwg_version ─────────────────────────────


def test_collect_pwg_version(tmp_path):
    import status_collector as sc

    home = _write(tmp_path, V1_MANIFEST)
    with mock.patch.dict(os.environ, {"OSTLER_HOME": str(home)}):
        assert sc.collect_pwg_version() == "v1.0.1"


def test_collect_pwg_version_absent(tmp_path):
    import status_collector as sc

    home = tmp_path / ".ostler"
    home.mkdir()
    with mock.patch.dict(os.environ, {"OSTLER_HOME": str(home)}):
        assert sc.collect_pwg_version() is None


# ── Render: version surface tile ─────────────────────────────────────


def test_render_version_surface_happy(tmp_path):
    import dashboard_components as dc

    home = _write(tmp_path, V1_MANIFEST)
    with mock.patch.dict(os.environ, {"OSTLER_HOME": str(home)}):
        html = dc.render_version_surface()

    assert "Ostler v1.0.1" in html
    assert "hub-v0.4.12" in html
    assert "Deployed version" in html
    # null compiler pin renders as a muted "not pinned", not a crash
    assert "not pinned" in html
    # source-repo pins surfaced in the click-through
    assert "cm051" in html


def test_render_version_surface_absent(tmp_path):
    import dashboard_components as dc

    home = tmp_path / ".ostler"
    home.mkdir()
    with mock.patch.dict(os.environ, {"OSTLER_HOME": str(home)}):
        html = dc.render_version_surface()

    # an absent manifest shows a visible "unknown" card + re-run pointer,
    # never a hidden section (operator should SEE the gap)
    assert "Version unknown" in html
    assert "ostler-release.json" in html


def test_render_version_surface_malformed_does_not_raise(tmp_path):
    import dashboard_components as dc

    home = _write(tmp_path, "not json {")
    with mock.patch.dict(os.environ, {"OSTLER_HOME": str(home)}):
        html = dc.render_version_surface()
    assert "Version unknown" in html


def test_render_version_surface_newer_schema_hint(tmp_path):
    import dashboard_components as dc

    home = _write(
        tmp_path,
        {"manifest_schema_version": "99", "ostler_version": "v2.0.0"},
    )
    with mock.patch.dict(os.environ, {"OSTLER_HOME": str(home)}):
        html = dc.render_version_surface()
    assert "Ostler v2.0.0" in html
    assert "newer Ostler" in html
