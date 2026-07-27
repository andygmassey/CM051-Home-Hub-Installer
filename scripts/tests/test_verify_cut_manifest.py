#!/usr/bin/env python3
# scripts/tests/test_verify_cut_manifest.py
# ============================================================================
# Smoke tests for scripts/verify_cut_manifest.py. Each primitive gets a
# positive + negative case against a synthetic artefact tree so a schema
# regression is caught before the real cut fails.
#
# Run: python3 -m pytest scripts/tests/test_verify_cut_manifest.py -v
#      (or `pytest` from repo root)
# ============================================================================

import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "verify_cut_manifest.py"
assert SCRIPT.is_file(), f"verifier not found at {SCRIPT}"


# ---------------------------------------------------------------------------
# Fixtures — build a fake artefact tree that mirrors the real .app layout.
# ---------------------------------------------------------------------------

@pytest.fixture
def fake_cm051(tmp_path):
    """Fake CM051 repo root with install.sh + cut-manifests/ dir."""
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    (cm051 / "install.sh").write_text(
        "#!/bin/bash\n# Fake installer for tests\n"
        "open 'x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension'\n"
        "# No secret patterns in this fake\n"
    )
    (cm051 / "cut-manifests").mkdir()
    # Vendored plist under lib/
    (cm051 / "vendor" / "plists").mkdir(parents=True)
    (cm051 / "vendor" / "plists" / "sample.plist").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0"><dict>\n'
        '  <key>RunAtLoad</key><false/>\n'
        '  <key>Label</key><string>com.example.sample</string>\n'
        '</dict></plist>\n'
    )
    return cm051


@pytest.fixture
def fake_app(tmp_path):
    """Fake OstlerInstaller.app tree with the paths the resolver expects."""
    app = tmp_path / "OstlerInstaller.app"
    resources = app / "Contents" / "Resources"
    resources.mkdir(parents=True)
    ostler_app_bin_dir = resources / "Ostler.app" / "Contents" / "MacOS"
    ostler_app_bin_dir.mkdir(parents=True)
    (ostler_app_bin_dir / "zeroclaw-desktop").write_bytes(
        b"BEGIN\nfake binary strings with iMessage and WhatsApp inside\nEND\n"
    )
    # Vendored context-refresh
    ctx = resources / "context-refresh" / "bin"
    ctx.mkdir(parents=True)
    (ctx / "generate_pwg_context.py").write_text(
        '#!/usr/bin/env python3\n'
        'import urllib.request\n'
        'req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})\n'
    )
    return app


def _run(cm051: Path, app: Path, *extra) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT),
         "--cm051-dir", str(cm051),
         "--app-path", str(app),
         "--json",
         *extra],
        capture_output=True, check=False, text=True,
    )


def _write_manifest(cm051: Path, filename: str, entries: list[dict]) -> None:
    import yaml
    (cm051 / "cut-manifests" / filename).write_text(
        yaml.safe_dump({"version": filename.replace(".yaml", ""), "entries": entries})
    )


# ---------------------------------------------------------------------------
# grep_in_installer
# ---------------------------------------------------------------------------

def test_grep_in_installer_present_ok(fake_cm051, fake_app):
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "modern-fda-scheme",
        "title": "modern FDA URL present",
        "proof": {
            "kind": "grep_in_installer",
            "pattern": r"com\.apple\.settings\.PrivacySecurity\.extension",
            "must_match": True,
        },
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout + r.stderr
    assert '"pass": 1' in r.stdout or '"pass": 1,' in r.stdout


def test_grep_in_installer_absent_fails(fake_cm051, fake_app):
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "no-legacy-fda",
        "title": "no legacy FDA URL",
        "proof": {
            "kind": "grep_in_installer",
            "pattern": r"com\.apple\.preference\.security",
            "must_match": False,
        },
    }])
    # No legacy pattern in our fake installer, so absence proof passes.
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0

    # Now inject legacy pattern and re-check — absence proof fails.
    (fake_cm051 / "install.sh").write_text(
        (fake_cm051 / "install.sh").read_text()
        + "\nopen 'x-apple.systempreferences:com.apple.preference.security'\n"
    )
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1


# ---------------------------------------------------------------------------
# grep_in_artefact
# ---------------------------------------------------------------------------

def test_grep_in_artefact_context_refresh(fake_cm051, fake_app):
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "context-twin-auth",
        "title": "vendored context script sends auth",
        "proof": {
            "kind": "grep_in_artefact",
            "target": "vendored-context-refresh",
            "path": "bin/generate_pwg_context.py",
            "pattern": "Authorization",
            "must_match": True,
        },
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout


def test_grep_in_artefact_daemon_binary(fake_cm051, fake_app):
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "imessage-label",
        "title": "daemon binary contains iMessage label",
        "proof": {
            "kind": "grep_in_artefact",
            "target": "daemon-binary",
            "pattern": "iMessage",
            "must_match": True,
        },
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout


# ---------------------------------------------------------------------------
# file_exists_in_artefact
# ---------------------------------------------------------------------------

def test_file_exists_present_ok(fake_cm051, fake_app):
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "context-script-exists",
        "title": "vendored context script is present",
        "proof": {
            "kind": "file_exists_in_artefact",
            "target": "vendored-context-refresh",
            "path": "bin/generate_pwg_context.py",
        },
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout


def test_file_exists_missing_fails(fake_cm051, fake_app):
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "phantom-file",
        "title": "manifest claims a file that does not exist",
        "proof": {
            "kind": "file_exists_in_artefact",
            "target": "vendored-context-refresh",
            "path": "bin/does_not_exist.py",
        },
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1


# ---------------------------------------------------------------------------
# plist_key_equals
# ---------------------------------------------------------------------------

def test_plist_key_equals_ok(fake_cm051, fake_app):
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "runatload-false",
        "title": "sample plist RunAtLoad is false",
        "proof": {
            "kind": "plist_key_equals",
            "target": "installer-tree",
            "path": "vendor/plists/sample.plist",
            "key": "RunAtLoad",
            "value": "false",
        },
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout


def test_plist_key_equals_mismatch_fails(fake_cm051, fake_app):
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "runatload-true-expected",
        "title": "expect true, actual is false",
        "proof": {
            "kind": "plist_key_equals",
            "target": "installer-tree",
            "path": "vendor/plists/sample.plist",
            "key": "RunAtLoad",
            "value": "true",
        },
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1


def test_plist_regex_fallback_on_template(fake_cm051, fake_app):
    """Templated plists (unresolved {{ USER }}) fail plistlib but must still
    be regex-parseable so the gate can prove key values."""
    (fake_cm051 / "vendor" / "plists" / "templated.plist").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<plist version="1.0"><dict>\n'
        '  <key>Label</key><string>com.example.{{ USER }}</string>\n'
        '  <key>RunAtLoad</key><false/>\n'
        '</dict></plist>\n'
    )
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "templated-runatload",
        "title": "regex fallback on unresolved template",
        "proof": {
            "kind": "plist_key_equals",
            "target": "installer-tree",
            "path": "vendor/plists/templated.plist",
            "key": "RunAtLoad",
            "value": "false",
        },
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout


# ---------------------------------------------------------------------------
# grep_in_dmg_tree — whole-DMG operator-PII backstop
# ---------------------------------------------------------------------------

_PII_ABSENCE_ENTRY = {
    "id": "no-operator-hostname",
    "title": "shipped DMG must not contain operator hostname anywhere",
    "proof": {
        "kind": "grep_in_dmg_tree",
        "pattern": "gamingrig",
        "must_match": False,
    },
}


def test_grep_in_dmg_tree_clean_passes(fake_cm051, fake_app):
    """No operator-PII anywhere in the app tree or install.sh -> absence proof passes."""
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [_PII_ABSENCE_ENTRY])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout


def test_grep_in_dmg_tree_catches_vendored_pii(fake_cm051, fake_app):
    """The v1.0.11 hole: PII in a vendored .py (never in install.sh) must FAIL.

    grep_in_installer passed 17/17 while this shipped; grep_in_dmg_tree must
    catch it.
    """
    vendored = fake_app / "Contents" / "Resources" / "imessage_source"
    vendored.mkdir(parents=True)
    (vendored / "__init__.py").write_text(
        "# publisher.py which is the legacy gamingrig personal instance\n"
    )
    # install.sh itself is clean — proving the scan reaches beyond install.sh.
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [_PII_ABSENCE_ENTRY])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1, r.stdout
    assert "__init__.py" in r.stdout  # detail names the offending file


def test_grep_in_dmg_tree_excludes_gate_definition_files(fake_cm051, fake_app):
    """A cut-manifests/ file inside the tree that DEFINES the banned pattern must
    NOT self-flag the gate; only real leaks count."""
    stray_manifest_dir = fake_app / "Contents" / "Resources" / "cut-manifests"
    stray_manifest_dir.mkdir(parents=True)
    (stray_manifest_dir / "permanent.yaml").write_text(
        'proof:\n  pattern: "gamingrig"\n  must_match: false\n'
    )
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [_PII_ABSENCE_ENTRY])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout  # excluded -> clean -> passes


def test_grep_in_dmg_tree_strings_pass_on_binary(fake_cm051, fake_app):
    """A verbatim literal baked into a large (>=500KB) extensionless binary is
    caught via strings(1)."""
    macos = fake_app / "Contents" / "MacOS"
    macos.mkdir(parents=True)
    payload = b"\x00" * 600_000 + b"hardcoded=192.168.1.37\x00"
    (macos / "OstlerInstaller").write_bytes(payload)
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "no-operator-ip",
        "title": "shipped DMG must not contain operator LAN IP anywhere",
        "proof": {
            "kind": "grep_in_dmg_tree",
            "pattern": r"192\.168\.1\.37",
            "must_match": False,
        },
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1, r.stdout


def test_grep_in_dmg_tree_scans_source_install_sh_without_build(fake_cm051, tmp_path):
    """Even with no built app, absence is proven against the source install.sh."""
    (fake_cm051 / "install.sh").write_text(
        "#!/bin/bash\n# leaked: connect to gamingrig\n"
    )
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [_PII_ABSENCE_ENTRY])
    missing_app = tmp_path / "does-not-exist.app"
    r = _run(fake_cm051, missing_app, "--skip-source-at-sha")
    assert r.returncode == 1, r.stdout


# ---------------------------------------------------------------------------
# Unknown primitive
# ---------------------------------------------------------------------------

def test_unknown_kind_fails(fake_cm051, fake_app):
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "bad-kind",
        "title": "unknown primitive should fail loudly",
        "proof": {"kind": "grep_in_the_stars", "pattern": "x"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1
    assert "unknown proof.kind" in r.stdout or "unknown proof.kind" in r.stderr
