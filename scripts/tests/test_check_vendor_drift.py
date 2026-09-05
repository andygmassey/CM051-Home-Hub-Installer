#!/usr/bin/env python3
# scripts/tests/test_check_vendor_drift.py
# ============================================================================
# Hermetic tests for scripts/check_vendor_drift.py. Uses monkey-patched
# gh-API + synthetic .vendor-manifests/ + VENDOR_MANIFEST.toml so nothing
# touches the network.
#
# Run: python3 -m pytest scripts/tests/test_check_vendor_drift.py -v
# ============================================================================

import importlib.util
import json
import os
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "check_vendor_drift.py"
assert SCRIPT.is_file(), f"drift checker not found at {SCRIPT}"


def _load_module():
    spec = importlib.util.spec_from_file_location("cvd", str(SCRIPT))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ---------------------------------------------------------------------------
# Fixtures + helpers
# ---------------------------------------------------------------------------

def _write_yaml(path: Path, doc: dict) -> None:
    import yaml
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(doc), encoding="utf-8")


def _write_toml(path: Path, trees: list[dict]) -> None:
    """Write a minimal VENDOR_MANIFEST.toml with the fields the drift checker reads."""
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# fake VENDOR_MANIFEST.toml for tests\n"]
    for t in trees:
        lines.append("[[tree]]\n")
        for k, v in t.items():
            if isinstance(v, bool):
                lines.append(f'{k} = {"true" if v else "false"}\n')
            elif isinstance(v, (int, float)):
                lines.append(f'{k} = {v}\n')
            else:
                lines.append(f'{k} = "{v}"\n')
        lines.append("\n")
    path.write_text("".join(lines), encoding="utf-8")


@pytest.fixture
def fake_repo(tmp_path, monkeypatch):
    """Sets up a fake repo root that mimics CM051's layout for the drift checker."""
    root = tmp_path / "cm051"
    root.mkdir()
    (root / ".vendor-manifests").mkdir()
    (root / "vendor").mkdir()
    # Redirect the module's constants to this fake root.
    return root


def _install_module_with_paths(repo_root: Path):
    mod = _load_module()
    mod.REPO_ROOT = repo_root
    mod.VENDOR_MANIFESTS_DIR = repo_root / ".vendor-manifests"
    mod.VENDOR_TOML = repo_root / "vendor" / "VENDOR_MANIFEST.toml"
    return mod


class _FakeGh:
    """Stub _gh_token_for + _gh_api_json on the drift-checker module."""

    def __init__(self, routes: dict, token: str | None = "fake-token"):
        # routes: dict[path -> (json, error)]
        self.routes = routes
        self.token = token
        self.calls: list[str] = []

    def install(self, mod):
        mod._gh_token_for = lambda owner: self.token
        def _api(path, token):
            self.calls.append(path)
            if path in self.routes:
                return self.routes[path]
            # Wildcard: match by prefix for commits/{sha} endpoints.
            for pattern, response in self.routes.items():
                if pattern.endswith("*") and path.startswith(pattern[:-1]):
                    return response
            return None, f"unrouted path: {path}"
        mod._gh_api_json = _api


# ---------------------------------------------------------------------------
# Positive path -- fresh
# ---------------------------------------------------------------------------

def test_drift_fresh_when_pin_equals_head(fake_repo):
    _write_yaml(fake_repo / ".vendor-manifests" / "doctor.yaml", {
        "name": "doctor",
        "github": {"owner": "andygmassey", "repo": "HR015-Gaming-PC",
                   "branch": "main", "path": "doctor"},
    })
    _write_toml(fake_repo / "vendor" / "VENDOR_MANIFEST.toml", [{
        "name": "doctor", "pinned_sha": "abcd" * 10,
    }])
    mod = _install_module_with_paths(fake_repo)
    _FakeGh({
        "repos/andygmassey/HR015-Gaming-PC/commits?sha=main&path=doctor&per_page=1": (
            [{"sha": "abcd" * 10}], ""),
    }).install(mod)
    reports = []
    for m in mod._load_vendor_manifests_dir(fake_repo / ".vendor-manifests"):
        toml_tree = mod._lookup_toml_tree(
            mod._load_vendor_toml(fake_repo / "vendor" / "VENDOR_MANIFEST.toml"),
            m["name"])
        reports.append(mod._check_tree(m, toml_tree, []))
    assert len(reports) == 1
    assert reports[0].status == "fresh", reports[0].detail


# ---------------------------------------------------------------------------
# Drift detected -- head moved, path touched
# ---------------------------------------------------------------------------

def test_drift_detected_when_head_moved_on_scoped_path(fake_repo):
    _write_yaml(fake_repo / ".vendor-manifests" / "doctor.yaml", {
        "name": "doctor",
        "github": {"owner": "andygmassey", "repo": "HR015-Gaming-PC",
                   "branch": "main", "path": "doctor"},
    })
    _write_toml(fake_repo / "vendor" / "VENDOR_MANIFEST.toml", [{
        "name": "doctor", "pinned_sha": "a" * 40,
    }])
    mod = _install_module_with_paths(fake_repo)
    _FakeGh({
        "repos/andygmassey/HR015-Gaming-PC/commits?sha=main&path=doctor&per_page=1": (
            [{"sha": "b" * 40}], ""),
        f"repos/andygmassey/HR015-Gaming-PC/compare/{'a'*40}...{'b'*40}": (
            {"status": "ahead", "ahead_by": 2,
             "commits": [
                 {"sha": "b1" * 20, "commit": {"message": "feat(doctor): SPA writer"}},
                 {"sha": "b2" * 20, "commit": {"message": "fix(doctor): unauth hydration"}},
             ]},
            ""),
        # per-commit files: both touch doctor/
        "repos/andygmassey/HR015-Gaming-PC/commits/*": (
            {"files": [{"filename": "doctor/agent/web_ui.py"}]}, ""),
    }).install(mod)
    reports = []
    for m in mod._load_vendor_manifests_dir(fake_repo / ".vendor-manifests"):
        toml_tree = mod._lookup_toml_tree(
            mod._load_vendor_toml(fake_repo / "vendor" / "VENDOR_MANIFEST.toml"),
            m["name"])
        reports.append(mod._check_tree(m, toml_tree, [r"^chore\(fmt\)"]))
    assert len(reports) == 1
    r = reports[0]
    assert r.status == "drift", r.detail
    assert len(r.diverging_commits) == 2
    assert "SPA writer" in r.diverging_commits[0]["message"]


def test_drift_fresh_when_head_moved_but_no_commits_touch_path(fake_repo):
    """The HEAD SHA moved but no non-ignored commit touched the vendored path.
    Result: fresh (no drift on the vendored slice).
    """
    _write_yaml(fake_repo / ".vendor-manifests" / "doctor.yaml", {
        "name": "doctor",
        "github": {"owner": "andygmassey", "repo": "HR015-Gaming-PC",
                   "branch": "main", "path": "doctor"},
    })
    _write_toml(fake_repo / "vendor" / "VENDOR_MANIFEST.toml", [{
        "name": "doctor", "pinned_sha": "a" * 40,
    }])
    mod = _install_module_with_paths(fake_repo)
    _FakeGh({
        # path-scoped commits query -- returns the PIN because nothing has
        # touched doctor/ since (the path filter excludes off-tree commits).
        "repos/andygmassey/HR015-Gaming-PC/commits?sha=main&path=doctor&per_page=1": (
            [{"sha": "a" * 40}], ""),
    }).install(mod)
    reports = []
    for m in mod._load_vendor_manifests_dir(fake_repo / ".vendor-manifests"):
        toml_tree = mod._lookup_toml_tree(
            mod._load_vendor_toml(fake_repo / "vendor" / "VENDOR_MANIFEST.toml"),
            m["name"])
        reports.append(mod._check_tree(m, toml_tree, []))
    assert reports[0].status == "fresh"


# ---------------------------------------------------------------------------
# Skip: UNKNOWN lineage
# ---------------------------------------------------------------------------

def test_drift_skip_when_owner_unknown(fake_repo):
    _write_yaml(fake_repo / ".vendor-manifests" / "cm041_contact_syncer.yaml", {
        "name": "cm041/contact_syncer",
        "github": {"owner": "<UNKNOWN -- retrofit needed>",
                   "repo": "<UNKNOWN -- retrofit needed>",
                   "branch": "main", "path": "contact_syncer"},
    })
    _write_toml(fake_repo / "vendor" / "VENDOR_MANIFEST.toml", [{
        "name": "cm041/contact_syncer", "pinned_sha": "a" * 40,
    }])
    mod = _install_module_with_paths(fake_repo)
    # No API stub needed -- must SKIP before touching the network.
    _FakeGh({}).install(mod)
    reports = []
    for m in mod._load_vendor_manifests_dir(fake_repo / ".vendor-manifests"):
        toml_tree = mod._lookup_toml_tree(
            mod._load_vendor_toml(fake_repo / "vendor" / "VENDOR_MANIFEST.toml"),
            m["name"])
        reports.append(mod._check_tree(m, toml_tree, []))
    assert reports[0].status == "skip-unknown"
    assert "retrofit" in reports[0].detail


# ---------------------------------------------------------------------------
# Skip: verify_exempt in TOML
# ---------------------------------------------------------------------------

def test_drift_skip_when_verify_exempt(fake_repo):
    _write_yaml(fake_repo / ".vendor-manifests" / "cm024_knowledge.yaml", {
        "name": "cm024_knowledge",
        "github": {"owner": "andygmassey", "repo": "evernote-knowledge",
                   "branch": "main", "path": "src"},
    })
    _write_toml(fake_repo / "vendor" / "VENDOR_MANIFEST.toml", [{
        "name": "cm024_knowledge", "pinned_sha": "a" * 40,
        "verify_exempt": True,
        "exempt_reason": "Rename debt -- source path renamed.",
    }])
    mod = _install_module_with_paths(fake_repo)
    _FakeGh({}).install(mod)
    reports = []
    for m in mod._load_vendor_manifests_dir(fake_repo / ".vendor-manifests"):
        toml_tree = mod._lookup_toml_tree(
            mod._load_vendor_toml(fake_repo / "vendor" / "VENDOR_MANIFEST.toml"),
            m["name"])
        reports.append(mod._check_tree(m, toml_tree, []))
    assert reports[0].status == "skip-exempt"
    assert "Rename debt" in reports[0].exempt_reason


# ---------------------------------------------------------------------------
# Error: TOML entry missing
# ---------------------------------------------------------------------------

def test_drift_error_when_toml_entry_missing(fake_repo):
    _write_yaml(fake_repo / ".vendor-manifests" / "orphan.yaml", {
        "name": "orphan",
        "github": {"owner": "andygmassey", "repo": "HR015-Gaming-PC",
                   "branch": "main", "path": "orphan"},
    })
    # Empty TOML -- no matching tree.
    _write_toml(fake_repo / "vendor" / "VENDOR_MANIFEST.toml", [])
    mod = _install_module_with_paths(fake_repo)
    _FakeGh({}).install(mod)
    reports = []
    for m in mod._load_vendor_manifests_dir(fake_repo / ".vendor-manifests"):
        toml_tree = mod._lookup_toml_tree(
            mod._load_vendor_toml(fake_repo / "vendor" / "VENDOR_MANIFEST.toml"),
            m["name"])
        reports.append(mod._check_tree(m, toml_tree, []))
    assert reports[0].status == "error"
    assert "no matching [[tree]]" in reports[0].detail


# ---------------------------------------------------------------------------
# Error: missing token
# ---------------------------------------------------------------------------

def test_drift_error_when_missing_token(fake_repo, monkeypatch):
    _write_yaml(fake_repo / ".vendor-manifests" / "doctor.yaml", {
        "name": "doctor",
        "github": {"owner": "andygmassey", "repo": "HR015-Gaming-PC",
                   "branch": "main", "path": "doctor"},
    })
    _write_toml(fake_repo / "vendor" / "VENDOR_MANIFEST.toml", [{
        "name": "doctor", "pinned_sha": "a" * 40,
    }])
    monkeypatch.delenv("GH_TOKEN", raising=False)
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    mod = _install_module_with_paths(fake_repo)
    _FakeGh({}, token=None).install(mod)
    reports = []
    for m in mod._load_vendor_manifests_dir(fake_repo / ".vendor-manifests"):
        toml_tree = mod._lookup_toml_tree(
            mod._load_vendor_toml(fake_repo / "vendor" / "VENDOR_MANIFEST.toml"),
            m["name"])
        reports.append(mod._check_tree(m, toml_tree, []))
    assert reports[0].status == "error"
    assert "gh token" in reports[0].detail


# ---------------------------------------------------------------------------
# Error: transient API failure
# ---------------------------------------------------------------------------

def test_drift_error_on_transient_api_failure(fake_repo):
    """API flake MUST surface as an error, never silently pass."""
    _write_yaml(fake_repo / ".vendor-manifests" / "doctor.yaml", {
        "name": "doctor",
        "github": {"owner": "andygmassey", "repo": "HR015-Gaming-PC",
                   "branch": "main", "path": "doctor"},
    })
    _write_toml(fake_repo / "vendor" / "VENDOR_MANIFEST.toml", [{
        "name": "doctor", "pinned_sha": "a" * 40,
    }])
    mod = _install_module_with_paths(fake_repo)
    _FakeGh({
        "repos/andygmassey/HR015-Gaming-PC/commits?sha=main&path=doctor&per_page=1": (
            None, "gh api exit=1: connection reset"),
    }).install(mod)
    reports = []
    for m in mod._load_vendor_manifests_dir(fake_repo / ".vendor-manifests"):
        toml_tree = mod._lookup_toml_tree(
            mod._load_vendor_toml(fake_repo / "vendor" / "VENDOR_MANIFEST.toml"),
            m["name"])
        reports.append(mod._check_tree(m, toml_tree, []))
    assert reports[0].status == "error"
    assert "connection reset" in reports[0].detail


# ---------------------------------------------------------------------------
# TOML loader parses the real manifest without exploding
# ---------------------------------------------------------------------------

def test_toml_loader_parses_real_vendor_manifest():
    """Sanity: the real VENDOR_MANIFEST.toml in the repo must parse cleanly.

    Guards against a schema drift where the checker's parser stops recognising
    a shape actually used in production.
    """
    real = SCRIPT.parent.parent / "vendor" / "VENDOR_MANIFEST.toml"
    if not real.is_file():
        pytest.skip(f"real VENDOR_MANIFEST.toml not at {real} (running outside repo)")
    mod = _load_module()
    trees = mod._load_vendor_toml(real)
    assert len(trees) > 5, f"expected multiple trees, got {len(trees)}"
    # Every tree should carry a name.
    for t in trees:
        assert "name" in t, f"tree missing name: {t}"


# ---------------------------------------------------------------------------
# Markdown renderer produces useful output
# ---------------------------------------------------------------------------

def test_markdown_renderer_drift_section_has_source_and_recovery(fake_repo):
    _write_yaml(fake_repo / ".vendor-manifests" / "doctor.yaml", {
        "name": "doctor",
        "github": {"owner": "andygmassey", "repo": "HR015-Gaming-PC",
                   "branch": "main", "path": "doctor"},
    })
    _write_toml(fake_repo / "vendor" / "VENDOR_MANIFEST.toml", [{
        "name": "doctor", "pinned_sha": "a" * 40,
    }])
    mod = _install_module_with_paths(fake_repo)
    _FakeGh({
        "repos/andygmassey/HR015-Gaming-PC/commits?sha=main&path=doctor&per_page=1": (
            [{"sha": "b" * 40}], ""),
        f"repos/andygmassey/HR015-Gaming-PC/compare/{'a'*40}...{'b'*40}": (
            {"status": "ahead", "ahead_by": 1,
             "commits": [{"sha": "b1" * 20,
                          "commit": {"message": "feat(doctor): critical fix"}}]},
            ""),
        "repos/andygmassey/HR015-Gaming-PC/commits/*": (
            {"files": [{"filename": "doctor/agent/x.py"}]}, ""),
    }).install(mod)
    reports = []
    for m in mod._load_vendor_manifests_dir(fake_repo / ".vendor-manifests"):
        toml_tree = mod._lookup_toml_tree(
            mod._load_vendor_toml(fake_repo / "vendor" / "VENDOR_MANIFEST.toml"),
            m["name"])
        reports.append(mod._check_tree(m, toml_tree, []))
    md = mod._render_markdown(reports)
    assert "Drift detected" in md
    assert "andygmassey/HR015-Gaming-PC" in md
    assert "sync_vendor.sh doctor" in md
    assert "critical fix" in md
