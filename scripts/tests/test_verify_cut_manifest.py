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

import hashlib
import json
import os
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
    ostler_app = resources / "Ostler.app"
    ostler_app_bin_dir = ostler_app / "Contents" / "MacOS"
    ostler_app_bin_dir.mkdir(parents=True)
    # Declare the executable the way a real bundle does. The resolver reads
    # CFBundleExecutable rather than assuming a name, so the fixture has to
    # carry an Info.plist -- that IS the contract under test.
    import plistlib as _plistlib
    with (ostler_app / "Contents" / "Info.plist").open("wb") as _fh:
        _plistlib.dump({"CFBundleExecutable": "ostler-hub"}, _fh)
    (ostler_app_bin_dir / "ostler-hub").write_bytes(
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


def _run(cm051: Path, app: Path, *extra, env: dict | None = None) -> subprocess.CompletedProcess:
    # Strip any ambient DAEMON_VERSION so the payload-version gate's pin
    # resolution is driven only by what a test explicitly provides (env kwarg
    # or a gui/Makefile pin), never by the developer's/CI's shell environment.
    run_env = {k: v for k, v in os.environ.items() if k != "DAEMON_VERSION"}
    if env:
        run_env.update(env)
    return subprocess.run(
        [sys.executable, str(SCRIPT),
         "--cm051-dir", str(cm051),
         "--app-path", str(app),
         "--json",
         *extra],
        capture_output=True, check=False, text=True, env=run_env,
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


# ---------------------------------------------------------------------------
# grep_in_dmg_tree — exempt_paths filter
# ---------------------------------------------------------------------------

_MARVIN_ABSENCE_ENTRY_NO_EXEMPT = {
    "id": "no-marvin",
    "title": "shipped DMG must not contain Marvin",
    "proof": {
        "kind": "grep_in_dmg_tree",
        "pattern": "Marvin",
        "must_match": False,
    },
}

_MARVIN_ABSENCE_ENTRY_WITH_EXEMPT = {
    "id": "no-marvin-except-pool",
    "title": "shipped DMG must not contain Marvin except in the F6.1 pool",
    "proof": {
        "kind": "grep_in_dmg_tree",
        "pattern": "Marvin",
        "must_match": False,
        "exempt_paths": [
            "**/ViewCopy.json",
            "**/install.sh.strings.en-GB.sh",
        ],
    },
}


def _write_marvin_hit_in_pool_file(fake_app: Path) -> None:
    """Legit F6.1 name-pool file with a Marvin reference the exempt list allows."""
    view_copy = fake_app / "Contents" / "Resources" / "ViewCopy.json"
    view_copy.write_text('{"pool": ["Friday", "Marvin", "Sage"]}\n')


def _write_marvin_hit_in_stray_file(fake_app: Path) -> None:
    """A stray Marvin leak the exempt list should NOT catch — a real regression."""
    stray = fake_app / "Contents" / "Resources" / "assistant" / "banner.py"
    stray.parent.mkdir(parents=True, exist_ok=True)
    stray.write_text("# leftover Marvin literal in the assistant banner\n")


def test_grep_in_dmg_tree_exempt_paths_allow_pool_hit(fake_cm051, fake_app):
    """Marvin lives only in the F6.1 pool file; exempt_paths keeps the gate green."""
    _write_marvin_hit_in_pool_file(fake_app)
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [_MARVIN_ABSENCE_ENTRY_WITH_EXEMPT])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout


def test_grep_in_dmg_tree_no_exempt_paths_flags_pool_hit(fake_cm051, fake_app):
    """Same Marvin-in-pool hit WITHOUT exempt_paths fails — proves exempt is doing the work."""
    _write_marvin_hit_in_pool_file(fake_app)
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [_MARVIN_ABSENCE_ENTRY_NO_EXEMPT])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1, r.stdout
    assert "ViewCopy.json" in r.stdout


def test_grep_in_dmg_tree_exempt_paths_still_catches_stray_leak(fake_cm051, fake_app):
    """Stray Marvin in a non-exempt file still fails the gate — exempt list is scoped."""
    _write_marvin_hit_in_pool_file(fake_app)      # allowed
    _write_marvin_hit_in_stray_file(fake_app)     # NOT allowed
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [_MARVIN_ABSENCE_ENTRY_WITH_EXEMPT])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1, r.stdout
    assert "banner.py" in r.stdout
    # Exempted files should NOT appear in the offending-files list.
    assert "ViewCopy.json" not in r.stdout


def test_grep_in_dmg_tree_exempt_paths_reports_exempted_count(fake_cm051, fake_app):
    """Detail line reports (M exempted) when exempt_paths made the difference."""
    _write_marvin_hit_in_pool_file(fake_app)
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [_MARVIN_ABSENCE_ENTRY_WITH_EXEMPT])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout
    assert "exempted" in r.stdout


# ---------------------------------------------------------------------------
# plist_env_key_present
# ---------------------------------------------------------------------------


def _write_env_plist(cm051: Path, name: str, env_dict: dict[str, str] | None) -> Path:
    """Write a launchd-shaped plist with an optional EnvironmentVariables block."""
    plist_dir = cm051 / "vendor" / "plists"
    plist_dir.mkdir(parents=True, exist_ok=True)
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        '<dict>',
        '  <key>Label</key><string>com.example.sample</string>',
    ]
    if env_dict is not None:
        lines.append('  <key>EnvironmentVariables</key>')
        lines.append('  <dict>')
        for k, v in env_dict.items():
            lines.append(f'    <key>{k}</key><string>{v}</string>')
        lines.append('  </dict>')
    lines.append('</dict>')
    lines.append('</plist>')
    p = plist_dir / name
    p.write_text("\n".join(lines) + "\n")
    return p


def test_plist_env_key_present_true(fake_cm051, fake_app):
    """PWG_SERVICE_TOKEN is in EnvironmentVariables: must_be_present:true -> PASS."""
    _write_env_plist(fake_cm051, "assistant.plist",
                     {"PWG_SERVICE_TOKEN": "s3cret", "OTHER": "x"})
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "assistant-plist-token-declared",
        "title": "assistant plist declares PWG_SERVICE_TOKEN",
        "proof": {
            "kind": "plist_env_key_present",
            "target": "installer-tree",
            "path": "vendor/plists/assistant.plist",
            "key": "PWG_SERVICE_TOKEN",
            "must_be_present": True,
        },
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout


def test_plist_env_key_present_absence_ok(fake_cm051, fake_app):
    """must_be_present:false + key genuinely absent -> PASS."""
    _write_env_plist(fake_cm051, "assistant.plist", {"OTHER": "x"})
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "assistant-plist-no-legacy-var",
        "title": "assistant plist does not declare a legacy env var",
        "proof": {
            "kind": "plist_env_key_present",
            "target": "installer-tree",
            "path": "vendor/plists/assistant.plist",
            "key": "LEGACY_TOKEN",
            "must_be_present": False,
        },
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout


def test_plist_env_key_present_key_missing_fails(fake_cm051, fake_app):
    """Expected key not in EnvironmentVariables -> FAIL."""
    _write_env_plist(fake_cm051, "assistant.plist", {"OTHER": "x"})
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "assistant-plist-missing-token",
        "title": "assistant plist is missing the token env key",
        "proof": {
            "kind": "plist_env_key_present",
            "target": "installer-tree",
            "path": "vendor/plists/assistant.plist",
            "key": "PWG_SERVICE_TOKEN",
            "must_be_present": True,
        },
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1, r.stdout


def test_plist_env_key_present_no_env_block_fails(fake_cm051, fake_app):
    """Plist has no EnvironmentVariables dict at all -> FAIL (not SKIP)."""
    _write_env_plist(fake_cm051, "no_env.plist", None)
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "plist-no-env-block",
        "title": "plist has no EnvironmentVariables dict",
        "proof": {
            "kind": "plist_env_key_present",
            "target": "installer-tree",
            "path": "vendor/plists/no_env.plist",
            "key": "PWG_SERVICE_TOKEN",
            "must_be_present": True,
        },
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1, r.stdout


def test_plist_env_key_present_missing_file_skips(fake_cm051, fake_app):
    """Plist file doesn't exist -> SKIP (not FAIL)."""
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "plist-missing",
        "title": "plist file missing",
        "proof": {
            "kind": "plist_env_key_present",
            "target": "installer-tree",
            "path": "vendor/plists/does_not_exist.plist",
            "key": "PWG_SERVICE_TOKEN",
            "must_be_present": True,
        },
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    # SKIP results do not turn overall exit non-zero — only FAILs do.
    assert r.returncode == 0, r.stdout
    assert '"skip": 1' in r.stdout


def test_plist_env_key_present_regex_fallback_on_template(fake_cm051, fake_app):
    """Templated plist (unresolved {{ USER }}) fails plistlib but the regex
    fallback still finds the env key."""
    plist_dir = fake_cm051 / "vendor" / "plists"
    plist_dir.mkdir(parents=True, exist_ok=True)
    (plist_dir / "templated.plist").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<plist version="1.0">\n'
        '<dict>\n'
        '  <key>Label</key><string>com.example.{{ USER }}</string>\n'
        '  <key>EnvironmentVariables</key>\n'
        '  <dict>\n'
        '    <key>PWG_SERVICE_TOKEN</key><string>{{ TOKEN }}</string>\n'
        '  </dict>\n'
        '</dict>\n'
        '</plist>\n'
    )
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "templated-token-declared",
        "title": "regex fallback finds token in templated plist",
        "proof": {
            "kind": "plist_env_key_present",
            "target": "installer-tree",
            "path": "vendor/plists/templated.plist",
            "key": "PWG_SERVICE_TOKEN",
            "must_be_present": True,
        },
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout


# ---------------------------------------------------------------------------
# box_walk_probe
# ---------------------------------------------------------------------------


def _write_probe(cm051: Path, name: str, body: str, subdir: str = "") -> Path:
    """Register a probe script under scripts/box_walk_probes[/<subdir>]/.

    `subdir` defaults to "" for the flat layout these tests have always used.
    That default is itself part of what #778 fixed: every fixture here wrote
    flat, the verifier only read flat, and the two agreed perfectly with each
    other while disagreeing with the real repo, where seven of the eight probes
    live one directory down. A fixture that encodes the shape the code handles
    cannot fail on the shape the repo has.
    """
    probes = cm051 / "scripts" / "box_walk_probes"
    if subdir:
        probes = probes / subdir
    probes.mkdir(parents=True, exist_ok=True)
    p = probes / f"{name}.sh"
    p.write_text("#!/usr/bin/env bash\n" + body + "\n")
    p.chmod(0o755)
    return p


def test_box_walk_probe_skips_without_box_host(fake_cm051, fake_app, monkeypatch):
    """OSTLER_BOX_HOST not set -> SKIP (runtime probe can't run without a box)."""
    monkeypatch.delenv("OSTLER_BOX_HOST", raising=False)
    _write_probe(fake_cm051, "smoke", "exit 0")
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "box-walk-smoke",
        "title": "runtime probe smoke check",
        "proof": {"kind": "box_walk_probe", "probe": "smoke"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout
    assert '"skip": 1' in r.stdout


def test_box_walk_probe_pass_on_exit_0(fake_cm051, fake_app, monkeypatch):
    """Box available and probe exits 0 -> PASS."""
    monkeypatch.setenv("OSTLER_BOX_HOST", "1.2.3.4")
    _write_probe(fake_cm051, "green", "echo 'seeded + retrieved'\nexit 0")
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "box-walk-green",
        "title": "runtime probe passes",
        "proof": {"kind": "box_walk_probe", "probe": "green"},
    }])
    # The subprocess we spawn inherits our env; make sure OSTLER_BOX_HOST
    # propagates via the current environment.
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout


def test_box_walk_probe_fail_on_nonzero(fake_cm051, fake_app, monkeypatch):
    """Box available and probe exits non-zero -> FAIL, exit code in detail."""
    monkeypatch.setenv("OSTLER_BOX_HOST", "1.2.3.4")
    _write_probe(fake_cm051, "red", "echo 'confabulated'\nexit 7")
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "box-walk-red",
        "title": "runtime probe fails",
        "proof": {"kind": "box_walk_probe", "probe": "red"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1, r.stdout
    assert "exit=7" in r.stdout or "exit\\\": 7" in r.stdout


def test_box_walk_probe_exit_78_is_cannot_run_not_fail(fake_cm051, fake_app, monkeypatch):
    """Exit 78 is CANNOT-RUN, never FAIL. A probe that could not MEASURE is not
    evidence of a defect in the ARTEFACT.

    THE DEFECT THIS PINS. _check_box_walk_probe was:
        ok = (exit_code == 0)
        status = "PASS" if ok else "FAIL"
    -- a two-state predicate over a three-state protocol.
    scripts/box_walk_probes/run_box_walk.sh:44 declares `EX_CANNOT_RUN=78` and 13
    of the 17 registered probes honour it. This function had never heard of it.

    MEASURED on the 2026-08-26T14:17:14Z walk of the v1.0.47 box:
        pair_state_agreement exit=78
        "VERDICT: CANNOT-RUN -- only 1 of 3 pairing signals were readable --
         one signal cannot contradict itself, so this would pass forever."
    and the row was recorded FAIL. It went onto the cut-blocker list as a real
    pairing defect. It was not one. A false accusation sends whoever reads the
    report hunting a bug that was never detected, while the actual fault -- a
    signal nobody could read -- goes unsaid.
    """
    monkeypatch.setenv("OSTLER_BOX_HOST", "1.2.3.4")
    _write_probe(fake_cm051, "unreadable",
                 "echo 'VERDICT: CANNOT-RUN -- only 1 of 3 signals were readable'\nexit 78")
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "box-walk-unreadable",
        "title": "runtime probe cannot run",
        "proof": {"kind": "box_walk_probe", "probe": "unreadable"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    summary = json.loads(r.stdout)["summary"]
    # Counted as CANNOT-RUN, and -- the load-bearing half -- NOT blamed on the
    # artefact. Assert the FAIL count is zero, not merely that the words differ.
    assert summary["cannot_run"] == 1, r.stdout
    assert summary["fail"] == 0, r.stdout


def test_box_walk_probe_cannot_run_still_blocks_the_cut(fake_cm051, fake_app, monkeypatch):
    """CANNOT-RUN is relabelled, NOT downgraded. It must still exit non-zero.

    THE TRAP THIS EXISTS TO SHUT. The obvious fix for the test above is to map 78
    to the pre-existing SKIP status. That would be WORSE than the defect: main()
    ends `return 0 if fails == 0 ...`, so SKIP does not block, and a cut would
    sail through on unmeasured pairing, egress and signing.

    The original author chose FAIL because it was the only blocking option
    available -- the right instinct with the wrong label. This pins both halves:
    the label is CANNOT-RUN (test above) AND the exit code is still 1 (here).
    Delete either assertion and the other one alone is satisfiable by a
    regression.
    """
    monkeypatch.setenv("OSTLER_BOX_HOST", "1.2.3.4")
    _write_probe(fake_cm051, "unreadable2", "echo 'CANNOT-RUN'\nexit 78")
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "box-walk-unreadable2",
        "title": "runtime probe cannot run",
        "proof": {"kind": "box_walk_probe", "probe": "unreadable2"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1, (
        "a probe that could not measure let the cut through -- "
        "coverage lost is not coverage passed\n" + r.stdout)


def test_box_walk_probe_78_does_not_swallow_real_failures(fake_cm051, fake_app, monkeypatch):
    """THE CONTROL. A predicate that called everything CANNOT-RUN would satisfy
    both tests above while blinding the gate to real defects. Exit 1 must still
    be FAIL, and must still be counted as one."""
    monkeypatch.setenv("OSTLER_BOX_HOST", "1.2.3.4")
    _write_probe(fake_cm051, "genuinely_broken",
                 "echo 'VERDICT: FAIL -- 35 paired tokens persisted'\nexit 1")
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "box-walk-genuinely-broken",
        "title": "runtime probe genuinely fails",
        "proof": {"kind": "box_walk_probe", "probe": "genuinely_broken"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1, r.stdout
    summary = json.loads(r.stdout)["summary"]
    assert summary["fail"] == 1, r.stdout
    assert summary["cannot_run"] == 0, r.stdout


def test_box_walk_probe_missing_probe_fails(fake_cm051, fake_app, monkeypatch):
    """Box available but probe script missing -> FAIL (registry gap)."""
    monkeypatch.setenv("OSTLER_BOX_HOST", "1.2.3.4")
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "box-walk-missing",
        "title": "missing probe",
        "proof": {"kind": "box_walk_probe", "probe": "never_registered"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1, r.stdout
    assert "not registered" in r.stdout


# ---------------------------------------------------------------------------
# #778 -- the gate and the runner had ZERO probes in common.
#
# This gate resolved `scripts/box_walk_probes/<name>.sh`, flat. The runner,
# scripts/box_walk_probes/run_box_walk.sh, globs `$HERE/probes/*.sh`. The repo
# holds seven probes in `probes/` and one flat, so the two instruments looked at
# disjoint sets: the gate could see only the probe the runner never runs, and
# the seven the runner does run could not be named by any manifest.
#
# Nothing failed, because a manifest cannot declare a probe the gate cannot
# resolve, so nobody ever wrote the rows. Silence, not an error.
#
# Every fixture above writes flat, which is why the existing suite was green
# throughout: it agreed with the verifier about a layout the repo does not use.
# ---------------------------------------------------------------------------


def test_box_walk_probe_resolves_in_probes_subdir(fake_cm051, fake_app, monkeypatch):
    """The seven real probes live in probes/. Before #778 this FAILED."""
    monkeypatch.setenv("OSTLER_BOX_HOST", "1.2.3.4")
    _write_probe(fake_cm051, "nested", "exit 0", subdir="probes")
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "box-walk-nested",
        "title": "probe registered in the probes/ subdirectory",
        "proof": {"kind": "box_walk_probe", "probe": "nested"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout


def test_box_walk_probe_still_resolves_flat(fake_cm051, fake_app, monkeypatch):
    """A probe registered flat must keep resolving.

    Nothing ships flat any more -- people_seed_and_retrieval gained a
    --self-test and moved into probes/, because sitting one level up meant
    run_box_walk.sh never globbed it and it had never executed in a box walk.
    The flat arm of the resolver stays anyway: a gate that stops finding a
    probe the moment somebody puts one back in the directory it used to live in
    fails by not-registered, which reads as "the probe is missing" rather than
    "the probe is in the wrong place".
    """
    monkeypatch.setenv("OSTLER_BOX_HOST", "1.2.3.4")
    _write_probe(fake_cm051, "flatprobe", "exit 0")
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "box-walk-flat",
        "title": "probe registered flat",
        "proof": {"kind": "box_walk_probe", "probe": "flatprobe"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout


def test_box_walk_missing_probe_names_every_path_searched(
    fake_cm051, fake_app, monkeypatch
):
    """A registry FAIL must say where it looked, in both directories.

    'not registered' alone sent a reader to the wrong directory for as long as
    this defect existed. The message is the only thing standing between the
    reader and the same wrong assumption.
    """
    monkeypatch.setenv("OSTLER_BOX_HOST", "1.2.3.4")
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "box-walk-absent",
        "title": "probe in neither directory",
        "proof": {"kind": "box_walk_probe", "probe": "absent_everywhere"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1, r.stdout
    assert "box_walk_probes/probes/absent_everywhere.sh" in r.stdout, r.stdout
    assert "box_walk_probes/absent_everywhere.sh" in r.stdout, r.stdout


# ---------------------------------------------------------------------------
# The coverage ratchet. This is the assertion that makes the defect
# unrepeatable, and it runs against the REAL repo, not a fixture.
#
# Resolvability was only half the problem. A probe the gate CAN resolve is
# still dark if no manifest names it, and seven of eight were in exactly that
# state. permanent.yaml is the manifest that runs on every cut; a probe
# declared only in a version manifest goes dark the moment that version ships,
# which is precisely how the people probe was lost after v1.0.12.
# ---------------------------------------------------------------------------

_REPO = Path(__file__).resolve().parents[2]


def _real_probe_names() -> set:
    """Every probe file in the real registry, both directories, no lib/."""
    root = _REPO / "scripts" / "box_walk_probes"
    names = set()
    for d in (root, root / "probes"):
        if not d.is_dir():
            continue
        for f in d.glob("*.sh"):
            if f.name == "run_box_walk.sh":
                continue
            names.add(f.stem)
    return names


def _permanent_probe_names() -> set:
    import yaml
    doc = yaml.safe_load((_REPO / "cut-manifests" / "permanent.yaml").read_text())
    out = set()
    for e in doc.get("entries") or []:
        proof = e.get("proof") or {}
        if proof.get("kind") == "box_walk_probe" and proof.get("probe"):
            out.add(proof["probe"])
    return out


def test_real_registry_is_not_empty():
    """POSITIVE CONTROL.

    Both assertions below are set comparisons, and an empty left-hand side
    satisfies every one of them. If a rename or a moved directory made the glob
    return nothing, the coverage test would pass while measuring nothing, which
    is the exact failure shape it exists to catch.
    """
    names = _real_probe_names()
    assert len(names) >= 8, f"expected at least 8 probes on disk, found {sorted(names)}"
    assert "people_seed_and_retrieval" in names
    assert "install_error_honesty" in names


def test_every_probe_on_disk_is_declared_in_permanent_manifest():
    """A probe nothing declares is a probe the cut never runs."""
    undeclared = _real_probe_names() - _permanent_probe_names()
    assert not undeclared, (
        "these probes exist on disk but no permanent.yaml row names them, so no "
        f"cut will ever invoke them: {sorted(undeclared)}. Add a box_walk_probe "
        "row to cut-manifests/permanent.yaml, or delete the probe."
    )


def test_every_declared_probe_resolves_to_a_real_file():
    """The other direction: a manifest row naming a probe that is not there."""
    sys.path.insert(0, str(SCRIPT.parent))
    import verify_cut_manifest as V  # noqa: E402
    missing = [
        p for p in sorted(_permanent_probe_names())
        if V._resolve_box_walk_probe(_REPO, p) is None
    ]
    assert not missing, (
        f"permanent.yaml declares probes with no script: {missing}"
    )


# ---------------------------------------------------------------------------
# #713 -- a declared RUNTIME proof that could not run must not read as green.
#
# Measured on main before this change: OSTLER_BOX_HOST is set NOWHERE. Zero
# hits across OS003 (the canonical cut mechanism); in CM051 only inside
# scripts/tests/. Two manifests declare box_walk_probe rows, so those rows have
# returned SKIP on every cut that has ever run, main() exits 0 because
# `fails == 0`, and the summary printed a skip COUNT with no names.
#
# The four tests above pin the DEFAULT behaviour and must keep passing: SKIP is
# right in CI and on a dev box, where there is no machine to probe. These tests
# pin the cut behaviour, which is the opposite.
# ---------------------------------------------------------------------------


def test_runtime_proof_skip_is_a_failure_under_require_flag(fake_cm051, fake_app, monkeypatch):
    """The row this whole primitive exists for cannot silently prove nothing."""
    monkeypatch.delenv("OSTLER_BOX_HOST", raising=False)
    _write_probe(fake_cm051, "smoke", "exit 0")
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "box-walk-smoke",
        "title": "runtime probe smoke check",
        "proof": {"kind": "box_walk_probe", "probe": "smoke"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha", "--require-runtime-proofs")
    assert r.returncode == 1, r.stdout
    assert "no runtime proof happened" in r.stdout


def test_require_flag_does_not_break_a_probe_that_can_run(fake_cm051, fake_app, monkeypatch):
    """The flag must not turn a genuinely-runnable proof red.

    Without this, the test above could be satisfied by a flag that fails
    unconditionally -- which would be a gate that cannot pass, the mirror image
    of a gate that cannot fail.
    """
    monkeypatch.setenv("OSTLER_BOX_HOST", "1.2.3.4")
    _write_probe(fake_cm051, "green", "echo 'seeded + retrieved'\nexit 0")
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "box-walk-green",
        "title": "runtime probe passes",
        "proof": {"kind": "box_walk_probe", "probe": "green"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha", "--require-runtime-proofs")
    assert r.returncode == 0, r.stdout


def test_skipped_rows_are_named_not_just_counted(fake_cm051, fake_app, monkeypatch):
    """A skip COUNT is a silent cap. The HUMAN summary must name which proof did not happen.

    🔴 THIS TEST WAS BLIND TWICE, IN DIFFERENT WAYS, AND BOTH WERE CAUGHT BY
    PROVING RED RATHER THAN BY READING IT.

    v1 asserted only that the row id appeared somewhere in stdout. Every check
    already prints its own id via emit(), so it passed with the summary block
    deleted -- satisfied by output the change does not touch.

    v2 anchored to the summary header, and then failed against the FIX, because
    the shared _run() helper always passes --json and the human summary branch
    never executes under it. The JSON path was never the blind one: it emits
    every result object including skips, with id and kind. The HUMAN path was,
    and the human path is what a person reads during a cut.

    So this runs WITHOUT --json deliberately. It is the only test in this file
    that does, and that is the point.
    """
    monkeypatch.delenv("OSTLER_BOX_HOST", raising=False)
    _write_probe(fake_cm051, "smoke", "exit 0")
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "box-walk-named",
        "title": "runtime probe smoke check",
        "proof": {"kind": "box_walk_probe", "probe": "smoke"},
    }])
    run_env = {k: v for k, v in os.environ.items() if k != "DAEMON_VERSION"}
    run_env.pop("OSTLER_BOX_HOST", None)
    r = subprocess.run(
        [sys.executable, str(SCRIPT),
         "--cm051-dir", str(fake_cm051),
         "--app-path", str(fake_app),
         "--skip-source-at-sha"],
        capture_output=True, check=False, text=True, env=run_env,
    )
    assert r.returncode == 0, r.stdout
    header = "Rows that did NOT prove anything (SKIP):"
    assert header in r.stdout, "the human summary does not list skipped rows at all"
    tail = r.stdout.split(header, 1)[1]
    assert "box-walk-named" in tail, "the skipped row was not named in the summary block"
    assert "box_walk_probe" in tail, "the summary block does not name the proof KIND"


# ---------------------------------------------------------------------------
# payload_version_matches_daemon_version
# ---------------------------------------------------------------------------


def _make_payload(fake_app: Path, version_text: str) -> None:
    """Build the (B-lite) payload layout inside the fake app.

    - Contents/Resources/ostler-payload/VERSION carries `version_text` verbatim.
    - A stub daemon binary is placed at
      Contents/Resources/ostler-payload/assistant-agent/OstlerAssistant.app/
      Contents/MacOS/ostler-assistant -- THE SHAPE gui/Makefile:1142-1148
      ACTUALLY BUILDS. The gate no longer invokes `--version` (the daemon binary
      reports the FROZEN Cargo workspace version by design -- see
      reference_ostler_assistant_version_field_frozen); it compares VERSION
      against the DAEMON_VERSION release pin. So the binary's contents are
      irrelevant here -- only its presence, at the right path, matters.

    Until 2026-08-21 this helper built the LEGACY bare-binary shape
    (assistant-agent/bin/ostler-assistant). #890 moved the payload to the .app
    bundle and made the bare shape a build-time hard failure, but neither the
    production predicate nor this fixture followed. Six tests stayed green
    against a payload `make ship` refuses to produce, so the suite could not have
    caught the inversion that red-ed v1.0.38. A fixture that models a shape the
    build rejects is not a test -- keep this in lockstep with gui/Makefile:1148.
    """
    payload = fake_app / "Contents" / "Resources" / "ostler-payload"
    macos_dir = payload / "assistant-agent" / "OstlerAssistant.app" / "Contents" / "MacOS"
    macos_dir.mkdir(parents=True, exist_ok=True)
    (payload / "VERSION").write_text(version_text)
    daemon = macos_dir / "ostler-assistant"
    daemon.write_text("#!/usr/bin/env bash\nexit 0\n")
    daemon.chmod(0o755)


def _make_payload_legacy_shape(fake_app: Path, version_text: str) -> None:
    """Build the payload with ONLY the pre-#890 bare-binary daemon.

    This is the shape gui/Makefile:1154 now refuses to build and install.sh
    upgrade-mode refuses to install (exit 20). It exists here solely so the
    predicate can be proved to REJECT it and to say why.
    """
    payload = fake_app / "Contents" / "Resources" / "ostler-payload"
    bin_dir = payload / "assistant-agent" / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    (payload / "VERSION").write_text(version_text)
    daemon = bin_dir / "ostler-assistant"
    daemon.write_text("#!/usr/bin/env bash\nexit 0\n")
    daemon.chmod(0o755)


def _make_payload_no_daemon(fake_app: Path, version_text: str) -> None:
    """Build a payload with a valid VERSION and NO daemon in either shape.

    The anti-vacuity control. Correcting a wrong path is only worth anything if
    the corrected predicate still detects genuine absence -- otherwise a wrong
    assertion has been swapped for one that cannot fail.
    """
    payload = fake_app / "Contents" / "Resources" / "ostler-payload"
    (payload / "assistant-agent").mkdir(parents=True, exist_ok=True)
    (payload / "VERSION").write_text(version_text)


def _write_daemon_pin(fake_cm051: Path, version: str) -> None:
    """Write a gui/Makefile carrying `DAEMON_VERSION ?= <version>` so the
    payload-version gate can resolve the release pin via its Makefile fallback.
    Mirrors the real cut, where `make ship` exports DAEMON_VERSION into env AND
    the gui/Makefile carries the same pin as the fallback."""
    gui = fake_cm051 / "gui"
    gui.mkdir(parents=True, exist_ok=True)
    (gui / "Makefile").write_text(f"DAEMON_VERSION ?= {version}\n")


def test_payload_version_matches_via_makefile_pin(fake_cm051, fake_app):
    """`hub-vX.Y.Z` payload VERSION vs a matching gui/Makefile DAEMON_VERSION
    pin (the env-unset fallback path) normalise equal -> PASS."""
    _make_payload(fake_app, "hub-v0.4.42")
    _write_daemon_pin(fake_cm051, "0.4.42")
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "payload-versions-match",
        "title": "payload VERSION matches DAEMON_VERSION Makefile pin",
        "proof": {"kind": "payload_version_matches_daemon_version"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout


# --- the three cases that pin the payload daemon SHAPE (#843) ----------------
#
# GREEN first, and it is load-bearing: the defect this closes was a predicate
# INCAPABLE OF PASSING, so a red-only set of controls would have reported
# healthy against both the broken and the fixed version.


def test_payload_daemon_app_bundle_shape_passes(fake_cm051, fake_app):
    """GREEN: the .app-bundle payload that gui/Makefile:1142-1148 actually
    builds satisfies the presence check.

    Before this fix the predicate looked for assistant-agent/bin/ostler-assistant
    -- the one shape gui/Makefile:1154 hard-fails on -- so a correctly assembled
    payload FAILED. That is what red-ed the v1.0.38 cut.
    """
    _make_payload(fake_app, "hub-v0.4.60")
    _write_daemon_pin(fake_cm051, "0.4.60")
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "payload-daemon-app-shape",
        "title": "payload carries the daemon as an .app bundle",
        "proof": {"kind": "payload_version_matches_daemon_version"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout


def test_payload_daemon_legacy_bare_shape_fails_and_names_the_drift(fake_cm051, fake_app):
    """RED: a payload carrying ONLY the pre-#890 bare binary must FAIL, and the
    detail must say the shape drifted rather than that the daemon is missing.

    install.sh upgrade-mode resolves _UPG_PAYLOAD_APP first and refuses a bare
    binary with exit 20, so this payload would brick every upgrade. The two
    failure modes -- absent daemon vs wrong-shaped daemon -- need opposite fixes,
    so an undifferentiated 'missing' message is a defect in its own right.
    """
    _make_payload_legacy_shape(fake_app, "hub-v0.4.60")
    _write_daemon_pin(fake_cm051, "0.4.60")
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "payload-daemon-legacy-shape",
        "title": "payload carries the legacy bare-binary daemon",
        "proof": {"kind": "payload_version_matches_daemon_version"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1, r.stdout
    assert "LEGACY" in r.stdout, "the detail does not name the shape drift"
    assert "exit 20" in r.stdout, "the detail does not name the consequence"


def test_payload_daemon_absent_entirely_still_fails(fake_cm051, fake_app):
    """RED (anti-vacuity): with the path corrected, a payload carrying NO daemon
    in either shape must still FAIL.

    Without this control the fix is unfalsifiable -- a predicate pointed at a
    path that always exists reports the same green as one that is genuinely
    satisfied. This is the control that makes the corrected path worth trusting.
    """
    _make_payload_no_daemon(fake_app, "hub-v0.4.60")
    _write_daemon_pin(fake_cm051, "0.4.60")
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "payload-daemon-absent",
        "title": "payload carries no daemon at all",
        "proof": {"kind": "payload_version_matches_daemon_version"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1, r.stdout
    assert "missing" in r.stdout
    # Genuine absence must NOT be reported as shape drift.
    assert "LEGACY" not in r.stdout, "absent daemon misreported as a legacy-shape payload"


def test_payload_version_matches_via_env_pin(fake_cm051, fake_app):
    """Bare `X.Y.Z` payload VERSION vs a matching DAEMON_VERSION env var (the
    primary path, exported by `make ship`) -> PASS. Env wins over any Makefile."""
    _make_payload(fake_app, "0.4.42")
    _write_daemon_pin(fake_cm051, "9.9.9")  # deliberately wrong; env must win
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "payload-versions-match-env",
        "title": "payload VERSION matches DAEMON_VERSION env pin",
        "proof": {"kind": "payload_version_matches_daemon_version"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha", env={"DAEMON_VERSION": "0.4.42"})
    assert r.returncode == 0, r.stdout


def test_payload_version_mismatch_fails(fake_cm051, fake_app):
    """Payload VERSION differs from the DAEMON_VERSION pin -> FAIL, with both
    normalised values in the detail so a human can see the drift."""
    _make_payload(fake_app, "hub-v0.4.42")
    _write_daemon_pin(fake_cm051, "0.4.41")
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "payload-versions-drift",
        "title": "payload VERSION drifted from DAEMON_VERSION pin",
        "proof": {"kind": "payload_version_matches_daemon_version"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1, r.stdout
    # Detail must include both normalised values so a human can see the drift.
    assert "0.4.42" in r.stdout and "0.4.41" in r.stdout


def test_payload_version_no_pin_resolvable_fails(fake_cm051, fake_app):
    """Valid payload + daemon present but NO DAEMON_VERSION (env or Makefile)
    -> FAIL: the gate refuses to pass without an authoritative release pin."""
    _make_payload(fake_app, "hub-v0.4.42")
    # No _write_daemon_pin and no env DAEMON_VERSION (stripped by _run).
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "payload-versions-no-pin",
        "title": "no DAEMON_VERSION pin resolvable",
        "proof": {"kind": "payload_version_matches_daemon_version"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1, r.stdout
    assert "could not resolve DAEMON_VERSION" in r.stdout


def test_payload_version_unparseable_fails(fake_cm051, fake_app):
    """Non-semver payload VERSION text -> FAIL (parse error), even with a valid
    pin present (the payload is what's broken, not the pin)."""
    _make_payload(fake_app, "not-a-version")
    _write_daemon_pin(fake_cm051, "0.4.42")
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "payload-versions-unparseable",
        "title": "payload VERSION is unparseable",
        "proof": {"kind": "payload_version_matches_daemon_version"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1, r.stdout
    assert "unparseable" in r.stdout


def test_payload_version_missing_files_fail(fake_cm051, fake_app):
    """App exists but payload missing entirely -> FAIL (not SKIP; the app IS
    built, but the assembly step was skipped)."""
    # fake_app fixture creates a bare Contents/Resources but no ostler-payload
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "payload-versions-missing",
        "title": "payload missing entirely",
        "proof": {"kind": "payload_version_matches_daemon_version"},
    }])
    r = _run(fake_cm051, fake_app, "--skip-source-at-sha")
    assert r.returncode == 1, r.stdout


def test_payload_version_skips_when_app_absent(fake_cm051, tmp_path):
    """No built app at all -> SKIP (local dev / pre-build CI)."""
    _write_manifest(fake_cm051, "permanent.yaml", [])
    _write_manifest(fake_cm051, "v1.0.0.yaml", [{
        "id": "payload-versions-app-absent",
        "title": "no built app yet",
        "proof": {"kind": "payload_version_matches_daemon_version"},
    }])
    missing_app = tmp_path / "does-not-exist.app"
    r = _run(fake_cm051, missing_app, "--skip-source-at-sha")
    assert r.returncode == 0, r.stdout
    assert '"skip": 1' in r.stdout


# ---------------------------------------------------------------------------
# Version normalisation — unit-level coverage of the three accepted shapes.
# ---------------------------------------------------------------------------


def test_normalise_version_all_three_shapes():
    """The parser accepts hub-vX.Y.Z, zeroclaw X.Y.Z, and bare X.Y.Z."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("vcm", str(SCRIPT))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    assert mod._normalise_version("hub-v1.2.3") == "1.2.3"
    assert mod._normalise_version("zeroclaw 4.5.6") == "4.5.6"
    assert mod._normalise_version("7.8.9") == "7.8.9"
    # Trailing content past the semver core is tolerated (matches the daemon's
    # own `X.Y.Z@sha` tag format).
    assert mod._normalise_version("hub-v1.2.3@abcdef") == "1.2.3"
    with pytest.raises(ValueError):
        mod._normalise_version("not-a-version")
    with pytest.raises(ValueError):
        mod._normalise_version("")


# ---------------------------------------------------------------------------
# pinned_artefact_freshness -- v1.0.13 near-miss recovery
#
# Covers the primitive that stops CM051 from cutting a DMG whose pinned
# pre-built artefact (daemon tarball, RemoteCapture) is behind its source
# repo on the compile sub-tree. Uses monkey-patched gh-API + version-source
# reads so the tests are hermetic (no network, no gh auth).
# ---------------------------------------------------------------------------

def _load_module():
    import importlib.util
    spec = importlib.util.spec_from_file_location("vcm", str(SCRIPT))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _write_daemon_pin_makefile(fake_cm051: Path, version: str) -> None:
    (fake_cm051 / "gui").mkdir(parents=True, exist_ok=True)
    (fake_cm051 / "gui" / "Makefile").write_text(
        f"# fake\nDAEMON_VERSION       ?= {version}\n"
    )


def _daemon_entry():
    return {
        "id": "daemon-freshness",
        "title": "daemon pin is fresh vs oa/main crates/",
        "proof": {
            "kind": "pinned_artefact_freshness",
            "artefact": "daemon (ostler-assistant)",
            "pinned_version_source": {
                "file": "gui/Makefile",
                "pattern": r"DAEMON_VERSION\s*[?:]?=\s*(\d+\.\d+\.\d+)",
            },
            "tag_format": "hub-v{version}",
            "source_repo": "ostler-ai/ostler-assistant",
            "source_paths": ["crates/**"],
            "ignore_commits_matching": [r"^chore\(fmt\)", r"^docs:"],
        },
    }


class _FakeGh:
    """Route (path -> json | error) for _gh_api_json and stub _gh_token_for.

    Applied to the LIVE module (not a subprocess) so the test calls the
    checker directly and does not need to spawn a subprocess or set up gh
    auth. That keeps the tests hermetic + fast.
    """

    def __init__(self, tag_sha: str, head_sha: str, default_branch: str = "main",
                 compare_status: str = "ahead", commits: list[dict] | None = None,
                 per_commit_files: dict[str, list[dict]] | None = None,
                 tag_object_type: str = "commit",
                 tag_target_sha: str | None = None,
                 token: str | None = "fake-token",
                 tag_error: str = "",
                 repo_error: str = "",
                 source_repo: str = "ostler-ai/ostler-assistant",
                 tag: str = "hub-v0.4.39"):
        self.tag_sha = tag_sha
        self.head_sha = head_sha
        self.default_branch = default_branch
        self.compare_status = compare_status
        self.commits = commits or []
        self.per_commit_files = per_commit_files or {}
        self.tag_object_type = tag_object_type
        self.tag_target_sha = tag_target_sha or tag_sha
        self.token = token
        self.tag_error = tag_error
        self.repo_error = repo_error
        self.source_repo = source_repo
        self.tag = tag
        self.calls: list[str] = []

    def gh_token_for(self, owner):
        return self.token

    def gh_api_json(self, path, token):
        self.calls.append(path)
        if path == f"repos/{self.source_repo}/git/refs/tags/{self.tag}":
            if self.tag_error:
                return None, self.tag_error
            return {"object": {"sha": self.tag_sha, "type": self.tag_object_type}}, ""
        if path == f"repos/{self.source_repo}/git/tags/{self.tag_sha}":
            return {"object": {"sha": self.tag_target_sha, "type": "commit"}}, ""
        if path == f"repos/{self.source_repo}":
            if self.repo_error:
                return None, self.repo_error
            return {"default_branch": self.default_branch}, ""
        if path == f"repos/{self.source_repo}/branches/{self.default_branch}":
            return {"commit": {"sha": self.head_sha}}, ""
        if path == f"repos/{self.source_repo}/compare/{self.tag_target_sha}...{self.head_sha}":
            return {"status": self.compare_status, "commits": self.commits}, ""
        # Per-commit files fetch
        prefix = f"repos/{self.source_repo}/commits/"
        if path.startswith(prefix):
            sha = path[len(prefix):]
            return {"files": self.per_commit_files.get(sha, [])}, ""
        return None, f"unrouted path: {path}"

    def install(self, mod):
        mod._gh_token_for = self.gh_token_for
        mod._gh_api_json = self.gh_api_json


def _run_check(cm051: Path, entry: dict):
    """Run the freshness checker against a fake_cm051 dir via the loaded module."""
    mod = _load_module()
    return mod, entry, cm051


def test_freshness_pass_when_pin_equals_head(tmp_path):
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_daemon_pin_makefile(cm051, "0.4.39")
    mod = _load_module()
    fake = _FakeGh(tag_sha="abc12300" + "0" * 32, head_sha="abc12300" + "0" * 32)
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(_daemon_entry(),
                                                 {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "PASS", result.detail
    assert "==" in result.detail


def test_freshness_pass_when_head_moved_but_nothing_touches_source_paths(tmp_path):
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_daemon_pin_makefile(cm051, "0.4.39")
    mod = _load_module()
    commits = [
        {"sha": "c1" * 20, "commit": {"message": "feat(website): landing page tweak"}},
        {"sha": "c2" * 20, "commit": {"message": "chore(ci): retry flaky action"}},
    ]
    per_commit = {
        "c1" * 20: [{"filename": "website/index.html"}],
        "c2" * 20: [{"filename": ".github/workflows/ci.yml"}],
    }
    fake = _FakeGh(tag_sha="a" * 40, head_sha="b" * 40,
                   commits=commits, per_commit_files=per_commit)
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(_daemon_entry(),
                                                 {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "PASS", result.detail
    assert "all 2 intervening commits are ignored or off-tree" in result.detail


def test_freshness_pass_when_all_diverging_commits_are_ignored(tmp_path):
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_daemon_pin_makefile(cm051, "0.4.39")
    mod = _load_module()
    commits = [
        {"sha": "c1" * 20, "commit": {"message": "chore(fmt): rustfmt sweep"}},
        {"sha": "c2" * 20, "commit": {"message": "docs: README typos"}},
    ]
    per_commit = {
        "c1" * 20: [{"filename": "crates/subscription/src/lib.rs"}],
        "c2" * 20: [{"filename": "crates/hub/src/lib.rs"}],
    }
    fake = _FakeGh(tag_sha="a" * 40, head_sha="b" * 40,
                   commits=commits, per_commit_files=per_commit)
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(_daemon_entry(),
                                                 {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "PASS", result.detail


def test_freshness_fail_when_source_paths_diverge(tmp_path):
    """The v1.0.13 near-miss shape: pin behind main, real commit touches crates/*.

    9528520a "feat(subscription): has_ever_paid sticky bit" MUST fail this gate.
    """
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_daemon_pin_makefile(cm051, "0.4.39")
    mod = _load_module()
    commits = [
        {"sha": "9528520a" + "0" * 32,
         "commit": {"message": "feat(subscription): has_ever_paid sticky bit"}},
        {"sha": "a2d2d23f" + "0" * 32,
         "commit": {"message": "build(release): hub-vX.Y.Z tag push wiring"}},
        {"sha": "cccc" * 10,
         "commit": {"message": "chore(fmt): rustfmt sweep"}},
    ]
    per_commit = {
        "9528520a" + "0" * 32: [{"filename": "crates/subscription/src/lib.rs"}],
        "a2d2d23f" + "0" * 32: [{"filename": "crates/release/src/tag.rs"}],
        "cccc" * 10: [{"filename": "crates/hub/src/lib.rs"}],  # ignored (chore(fmt))
    }
    fake = _FakeGh(tag_sha="a" * 40, head_sha="b" * 40,
                   commits=commits, per_commit_files=per_commit)
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(_daemon_entry(),
                                                 {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "FAIL", result.detail
    # Both non-ignored, tree-touching commits should be enumerated.
    assert "has_ever_paid" in result.detail
    assert "hub-vX.Y.Z" in result.detail
    # The chore(fmt) commit must NOT be enumerated.
    assert "rustfmt" not in result.detail
    # Recovery guidance is present.
    assert "Recovery" in result.detail


def test_freshness_hold_ack_passes_when_all_diverging_acked(tmp_path):
    """#238: a hotfix graft-forward may pin BEHIND HEAD when every diverging
    commit is acknowledged by SHA with a written reason -> PASS (HELD)."""
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_daemon_pin_makefile(cm051, "0.4.39")
    mod = _load_module()
    commits = [
        {"sha": "9528520a" + "0" * 32,
         "commit": {"message": "feat(subscription): has_ever_paid sticky bit"}},
        {"sha": "a2d2d23f" + "0" * 32,
         "commit": {"message": "build(release): hub-vX.Y.Z tag push wiring"}},
    ]
    per_commit = {
        "9528520a" + "0" * 32: [{"filename": "crates/subscription/src/lib.rs"}],
        "a2d2d23f" + "0" * 32: [{"filename": "crates/release/src/tag.rs"}],
    }
    fake = _FakeGh(tag_sha="a" * 40, head_sha="b" * 40,
                   commits=commits, per_commit_files=per_commit)
    fake.install(mod)
    entry = _daemon_entry()
    entry["proof"]["hold_ack"] = {
        # Full 40-char SHAs; the checker prefix-matches against 8-char diverging shas.
        "shas": ["9528520a" + "0" * 32, "a2d2d23f" + "0" * 32],
        "reason": "v1.0.13.1 hotfix pins graft-forward daemon; these oa/main commits are intentionally held",
    }
    result = mod.check_pinned_artefact_freshness(
        entry, {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "PASS", result.detail
    assert "hold_ack'd" in result.detail
    assert "intentionally held" in result.detail


def test_freshness_hold_ack_fails_when_reason_missing(tmp_path):
    """#238: hold_ack.shas without a written reason FAILs closed -- an intentional
    hold must be justified, not just silently waved through."""
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_daemon_pin_makefile(cm051, "0.4.39")
    mod = _load_module()
    commits = [{"sha": "9528520a" + "0" * 32,
                "commit": {"message": "feat(subscription): has_ever_paid sticky bit"}}]
    per_commit = {"9528520a" + "0" * 32: [{"filename": "crates/subscription/src/lib.rs"}]}
    fake = _FakeGh(tag_sha="a" * 40, head_sha="b" * 40,
                   commits=commits, per_commit_files=per_commit)
    fake.install(mod)
    entry = _daemon_entry()
    entry["proof"]["hold_ack"] = {"shas": ["9528520a" + "0" * 32], "reason": "   "}
    result = mod.check_pinned_artefact_freshness(
        entry, {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "FAIL", result.detail
    assert "reason" in result.detail.lower()


def test_freshness_hold_ack_partial_fails_naming_only_unacked(tmp_path):
    """#238: a hold_ack that does NOT cover the full delta narrows the failure to
    the un-acknowledged commit(s) -- it never passes on a partial ack."""
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_daemon_pin_makefile(cm051, "0.4.39")
    mod = _load_module()
    commits = [
        {"sha": "9528520a" + "0" * 32,
         "commit": {"message": "feat(subscription): has_ever_paid sticky bit"}},
        {"sha": "deadbeef" + "0" * 32,
         "commit": {"message": "feat(hub): sneaky unreviewed change"}},
    ]
    per_commit = {
        "9528520a" + "0" * 32: [{"filename": "crates/subscription/src/lib.rs"}],
        "deadbeef" + "0" * 32: [{"filename": "crates/hub/src/lib.rs"}],
    }
    fake = _FakeGh(tag_sha="a" * 40, head_sha="b" * 40,
                   commits=commits, per_commit_files=per_commit)
    fake.install(mod)
    entry = _daemon_entry()
    entry["proof"]["hold_ack"] = {
        "shas": ["9528520a" + "0" * 32],  # only the first commit is acknowledged
        "reason": "acknowledging only the subscription commit; the hub one is not vouched for",
    }
    result = mod.check_pinned_artefact_freshness(
        entry, {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "FAIL", result.detail
    assert "sneaky" in result.detail            # the un-acknowledged commit IS named
    assert "has_ever_paid" not in result.detail  # the acknowledged commit is filtered out


def test_freshness_fail_when_tag_does_not_exist(tmp_path):
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_daemon_pin_makefile(cm051, "0.4.39")
    mod = _load_module()
    fake = _FakeGh(tag_sha="", head_sha="",
                   tag_error="gh api repos/ostler-ai/ostler-assistant/git/refs/tags/hub-v0.4.39 exit=1: HTTP 404: Not Found")
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(_daemon_entry(),
                                                 {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "FAIL"
    assert "resolving tag 'hub-v0.4.39'" in result.detail
    assert "404" in result.detail


def test_freshness_fail_when_source_repo_unreachable_is_not_silent_pass(tmp_path):
    """Transient error MUST fail the gate, not sneak through as a pass."""
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_daemon_pin_makefile(cm051, "0.4.39")
    mod = _load_module()
    # Successfully resolve tag, then fail on the repo-metadata fetch.
    class _NetDown(_FakeGh):
        def gh_api_json(self, path, token):
            if path.endswith("/git/refs/tags/hub-v0.4.39"):
                return {"object": {"sha": "a" * 40, "type": "commit"}}, ""
            return None, "gh api repos/ostler-ai/ostler-assistant exit=1: connection reset"
    fake = _NetDown(tag_sha="a" * 40, head_sha="b" * 40)
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(_daemon_entry(),
                                                 {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "FAIL"
    assert "connection reset" in result.detail


def test_freshness_SKIPS_when_missing_token(tmp_path, monkeypatch):
    """No credential is CANNOT-RUN, not a stale artefact.

    This test previously asserted FAIL, and that assertion was the defect
    rather than the guard. Measured on the v1.0.26 cut: with no ostler-ai
    token on the runner, the row rendered as

        FAIL  permanent-daemon-freshness
              pinned daemon tarball must contain all merged crates/* changes
              could not resolve gh token for owner 'ostler-ai'

    -- a headline asserting the daemon is stale, sitting above a detail saying
    the checker could not log in. Only one of those was true, and the false one
    is the one a reader acts on. Every CI cut that reached this row hit it.

    The token env vars are cleared explicitly: the fallback added alongside
    this change reads OSTLER_RELEASES_TOKEN, so a developer with it exported
    would otherwise see this test pass for the wrong reason.
    """
    monkeypatch.delenv("OSTLER_RELEASES_TOKEN", raising=False)
    monkeypatch.delenv("OSTLER_GH_TOKEN_OSTLER_AI", raising=False)
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_daemon_pin_makefile(cm051, "0.4.39")
    mod = _load_module()
    fake = _FakeGh(tag_sha="a" * 40, head_sha="b" * 40, token=None)
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(_daemon_entry(),
                                                 {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "SKIP", (
        "a missing credential must not be reported as a stale artefact")
    assert "NOT CHECKED" in result.detail
    assert "not evaluated either way" in result.detail
    # Both remedies named: CI and operator. A cannot-run that does not say how
    # to make it runnable is only half an honest answer.
    assert "OSTLER_RELEASES_TOKEN" in result.detail
    assert "gh auth login --user ostler-ai" in result.detail


def test_freshness_SKIPS_when_the_repo_itself_cannot_be_READ(tmp_path):
    """A 404 on a private repo is CANNOT-RUN, not a stale artefact.

    Measured on the v1.0.26 cut: permanent-remotecapture-freshness rendered

        FAIL  permanent-remotecapture-freshness
              resolving tag 'remote-capture-v0.1.3' ... HTTP 404

    -- a headline asserting the pinned RemoteCapture is STALE. Controlled with
    the ostler-ai account, the repo resolves (PRIVATE) and that same tag
    resolves to 5f9ddf32. Nothing was stale; the token could not see the repo.
    GitHub answers 404 for "not found" and for "not yours" identically, so the
    checker was reading a permissions signal as an artefact verdict.

    Sibling of test_freshness_SKIPS_when_missing_token one level in: there the
    credential was absent, here it is present but lacks scope.
    """
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_daemon_pin_makefile(cm051, "0.4.39")
    mod = _load_module()
    fake = _FakeGh(tag_sha="a" * 40, head_sha="b" * 40,
                   repo_error="gh api repos/... exit=1: HTTP 404: Not Found")
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(
        _daemon_entry(), {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "SKIP", (
        "an unreadable repo must not be reported as a stale artefact")
    assert "NOT CHECKED" in result.detail
    assert "cannot read" in result.detail
    assert "not evaluated either way" in result.detail

    # The REPO is probed BEFORE the tag. If the order ever flips, the tag 404
    # lands first and the row goes back to asserting staleness from a
    # permissions signal -- which is the entire defect.
    assert f"repos/{fake.source_repo}" in fake.calls
    assert f"repos/{fake.source_repo}/git/refs/tags/{fake.tag}" not in fake.calls, (
        "the tag must not be queried once the repo has proved unreadable")


def test_freshness_FAILS_when_repo_readable_but_tag_genuinely_absent(tmp_path):
    """The other half, and the reason this is not just 'map 404 to SKIP'.

    Mapping every 404 to SKIP would swallow a real missing tag: a genuine
    staleness defect silently reclassified as not-checked. Both verdicts have
    to stay reachable, distinguished by evidence -- so with the repo READABLE
    and only the tag missing, this must still be a hard FAIL.
    """
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_daemon_pin_makefile(cm051, "0.4.39")
    mod = _load_module()
    fake = _FakeGh(tag_sha="a" * 40, head_sha="b" * 40,
                   tag_error="gh api ... exit=1: HTTP 404: Not Found")
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(
        _daemon_entry(), {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "FAIL", (
        "a readable repo with a missing tag is a REAL defect and must not be "
        "downgraded to SKIP by the private-repo fix")
    assert "genuinely absent" in result.detail
    # And it did prove readability first, rather than guessing.
    assert f"repos/{fake.source_repo}" in fake.calls


def test_freshness_RUNS_when_token_comes_from_the_environment(tmp_path, monkeypatch):
    """The env fallback is why this gate can work in CI at all.

    Without it _gh_token_for resolves only via `gh auth token --user`, which
    needs a human-logged account and therefore never resolves on a runner.
    """
    monkeypatch.setenv("OSTLER_RELEASES_TOKEN", "test-token-not-a-real-secret")
    mod = _load_module()
    assert mod._gh_token_for("ostler-ai") == "test-token-not-a-real-secret"
    # CONTROL: the fallback is scoped to the owner it was issued for, so an
    # unrelated owner must NOT silently borrow it.
    monkeypatch.delenv("OSTLER_GH_TOKEN_SOME_OTHER_OWNER", raising=False)
    assert mod._gh_token_for("some-other-owner") != "test-token-not-a-real-secret"


def test_freshness_fail_when_pin_source_missing(tmp_path):
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    # deliberately do not write gui/Makefile
    mod = _load_module()
    fake = _FakeGh(tag_sha="a" * 40, head_sha="b" * 40)
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(_daemon_entry(),
                                                 {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "FAIL"
    assert "pin source file not found" in result.detail


def test_freshness_annotated_tag_takes_extra_hop(tmp_path):
    """Annotated tags (object.type == 'tag') require one extra `git/tags/{sha}` hop."""
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_daemon_pin_makefile(cm051, "0.4.39")
    mod = _load_module()
    fake = _FakeGh(
        tag_sha="a" * 40,             # annotated-tag object SHA
        tag_target_sha="c" * 40,      # the underlying commit
        head_sha="c" * 40,            # HEAD equals the target commit -> PASS
        tag_object_type="tag",
    )
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(_daemon_entry(),
                                                 {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "PASS", result.detail
    # Extra hop happened.
    assert any("git/tags/" in c for c in fake.calls)


def test_freshness_source_paths_glob_matches_deep_paths(tmp_path):
    """`crates/**` must match `crates/subscription/src/lib.rs` (deep), not just
    top-level files. Regression: naive fnmatch fails on `**` across separators.
    """
    mod = _load_module()
    assert mod._matches_source_path("crates/subscription/src/lib.rs", ["crates/**"]) == "crates/**"
    assert mod._matches_source_path("crates/lib.rs", ["crates/**"]) == "crates/**"
    assert mod._matches_source_path("website/index.html", ["crates/**"]) is None
    # Sources/** for RemoteCapture
    assert mod._matches_source_path("Sources/RemoteCapture/App.swift",
                                    ["Sources/**"]) == "Sources/**"
    # Multi-glob with a plain file
    assert mod._matches_source_path("Package.swift",
                                    ["Sources/**", "Package.swift"]) == "Package.swift"


def test_freshness_remotecapture_pin_extraction(tmp_path):
    """RemoteCapture pin sits inside a `${VAR:-default}` fragment in install.sh.
    The permanent.yaml entry's pattern must extract the default correctly.
    """
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    (cm051 / "install.sh").write_text(
        '#!/bin/bash\n'
        'OSTLER_REMOTECAPTURE_VERSION="${OSTLER_REMOTECAPTURE_VERSION:-0.1.3}"\n'
    )
    mod = _load_module()
    v, err = mod._extract_pinned_version(cm051, {
        "file": "install.sh",
        "pattern": r'OSTLER_REMOTECAPTURE_VERSION="\$\{OSTLER_REMOTECAPTURE_VERSION:-(\d+\.\d+\.\d+)\}"',
    })
    assert err == "", err
    assert v == "0.1.3"


# ---------------------------------------------------------------------------
# verify_build_info_sidecar_present + sidecar-aware pinned_artefact_freshness
# (v1.0.14, pairs with oa #259 Stream 1)
#
# Hermetic: monkey-patched _gh_api_json / _gh_token_for / _fetch_asset_content
# so no network + no gh auth needed. Local-file fallback is exercised against
# tmp_path directories that mirror the Stream 3 backfill layout.
# ---------------------------------------------------------------------------

_TAG = "hub-v0.4.43"
_TAG_SHA = "2ae9ca8574dd69dee27cf1fa6a05d2adfbaaaf7c"
_HEAD_SHA = _TAG_SHA  # same-as-HEAD keeps freshness happy; tests focus on sidecar
_TARBALL_SHA = "8ef223f79bd61c8c00b4db3f54f8973131ce401e569404dc957d568b9d3ba17a"
_SIDECAR_NAME = "ostler-assistant-aarch64-apple-darwin-v0.4.43.build-info.json"
_TARBALL_NAME = "ostler-assistant-aarch64-apple-darwin-v0.4.43.tar.gz"


def _write_daemon_pin_makefile_043(fake_cm051: Path) -> None:
    (fake_cm051 / "gui").mkdir(parents=True, exist_ok=True)
    (fake_cm051 / "gui" / "Makefile").write_text(
        "# fake\nDAEMON_VERSION       ?= 0.4.43\n"
    )


def _sidecar_entry(*, allow_reconstructed: bool = False,
                   local_sidecar_dir: str | None = None) -> dict:
    proof = {
        "kind": "verify_build_info_sidecar_present",
        "pinned_version_source": {
            "file": "gui/Makefile",
            "pattern": r"DAEMON_VERSION\s*[?:]?=\s*(\d+\.\d+\.\d+)",
        },
        "tag_format": "hub-v{version}",
        "source_repo": "ostler-ai/ostler-assistant",
        "allow_reconstructed": allow_reconstructed,
    }
    if local_sidecar_dir is not None:
        proof["local_sidecar_dir"] = local_sidecar_dir
    return {"id": "sidecar-present", "title": "build-info sidecar for pinned daemon",
            "proof": proof}


def _freshness_entry_with_sidecar(*, allow_reconstructed: bool = False,
                                  local_sidecar_dir: str | None = None,
                                  verify_tarball_sha: bool = False) -> dict:
    entry = _daemon_entry()
    entry["proof"]["consume_build_info_sidecar"] = True
    entry["proof"]["allow_reconstructed"] = allow_reconstructed
    entry["proof"]["verify_tarball_sha"] = verify_tarball_sha
    if local_sidecar_dir is not None:
        entry["proof"]["local_sidecar_dir"] = local_sidecar_dir
    return entry


def _real_sidecar_json(*, commit_sha: str = _TAG_SHA,
                       dirty_worktree: bool = False,
                       reconstructed: bool = False,
                       tarball_sha256: str = _TARBALL_SHA,
                       tag_name: str = _TAG) -> dict:
    return {
        "schema_version": 1,
        "artefact": "ostler-assistant",
        "version": "0.4.43",
        "commit_sha": commit_sha,
        "commit_date": "2026-07-31T04:20:11Z",
        "tag_name": tag_name,
        "build_timestamp": "2026-07-31T05:10:00Z",
        "build_machine": "andy-mbp-14",
        "build_tool_versions": {"cargo": "1.93.0", "rustc": "1.93.0"},
        "dirty_worktree": dirty_worktree,
        "crate_versions": {"zeroclaw": "0.4.43"},
        "signed_by": {
            "tarball_filename": _TARBALL_NAME,
            "tarball_sha256": tarball_sha256,
        },
        "reconstructed": reconstructed,
    }


def _backfill_sidecar_json(*, tarball_sha256: str = _TARBALL_SHA) -> dict:
    """Shape of a Stream 3 backfill sidecar (reconstructed:true, some UNKNOWNs)."""
    return {
        "schema_version": 1,
        "artefact": "ostler-assistant",
        "version": "0.4.43",
        "commit_sha": _TAG_SHA,
        "commit_date": "2026-07-31T04:20:11Z",
        "tag_name": _TAG,
        "tag_pushed": True,
        "build_timestamp": "<UNKNOWN - not captured at build time>",
        "build_machine": "andy-mbp-14",
        "build_tool_versions": "<UNKNOWN - not captured at build time>",
        "dirty_worktree": False,
        "crate_versions": "<UNKNOWN - not captured at build time>",
        "signed_by": {
            "tarball_filename": _TARBALL_NAME,
            "tarball_sha256": tarball_sha256,
        },
        "reconstructed": True,
        "reconstruction_notes": {
            "authored_by": "test-fixture",
            "sources": ["synthetic"],
        },
    }


class _SidecarGh(_FakeGh):
    """_FakeGh extended with release+asset routing for sidecar fetches.

    Routes:
      - repos/{repo}/releases/tags/{tag} -> {assets: [...]}
      - repos/{repo}/releases/assets/{id} (via _fetch_asset_content) -> bytes
    """

    def __init__(self, *, sidecar_content: bytes | None = None,
                 sidecar_asset_name: str = _SIDECAR_NAME,
                 tarball_content: bytes = b"pretend-tarball-bytes",
                 include_sidecar_asset: bool = True,
                 include_tarball_asset: bool = True,
                 sidecar_asset_id: int = 5551,
                 tarball_asset_id: int = 5552,
                 release_error: str = "",
                 **kwargs):
        super().__init__(tag_sha=_TAG_SHA, head_sha=_HEAD_SHA, tag=_TAG, **kwargs)
        self.sidecar_content = sidecar_content
        self.sidecar_asset_name = sidecar_asset_name
        self.tarball_content = tarball_content
        self.include_sidecar_asset = include_sidecar_asset
        self.include_tarball_asset = include_tarball_asset
        self.sidecar_asset_id = sidecar_asset_id
        self.tarball_asset_id = tarball_asset_id
        self.release_error = release_error
        self.asset_fetches: list[int] = []

    def gh_api_json(self, path, token):
        # Delegate everything the base class knows about first.
        if path == f"repos/{self.source_repo}/releases/tags/{self.tag}":
            if self.release_error:
                return None, self.release_error
            assets = []
            if self.include_sidecar_asset:
                assets.append({"id": self.sidecar_asset_id,
                               "name": self.sidecar_asset_name})
            if self.include_tarball_asset:
                assets.append({"id": self.tarball_asset_id,
                               "name": _TARBALL_NAME})
            return {"assets": assets}, ""
        return super().gh_api_json(path, token)

    def fetch_asset_content(self, source_repo, asset_id, token, timeout=None):
        self.asset_fetches.append(asset_id)
        if asset_id == self.sidecar_asset_id:
            if self.sidecar_content is None:
                return b"", f"asset {asset_id} not routed"
            return self.sidecar_content, ""
        if asset_id == self.tarball_asset_id:
            return self.tarball_content, ""
        return b"", f"unrouted asset id: {asset_id}"

    def install(self, mod):
        super().install(mod)
        mod._fetch_asset_content = self.fetch_asset_content


def _ctx(cm051, tmp_path):
    return {"cm051_dir": cm051, "app_path": tmp_path / "no-app"}


# --- verify_build_info_sidecar_present ---


def test_sidecar_present_green_real_emit(tmp_path):
    """Real (non-reconstructed) sidecar present -> PASS "fully-verified"."""
    cm051 = tmp_path / "cm051"; cm051.mkdir()
    _write_daemon_pin_makefile_043(cm051)
    mod = _load_module()
    fake = _SidecarGh(sidecar_content=json.dumps(_real_sidecar_json()).encode())
    fake.install(mod)
    r = mod.check_verify_build_info_sidecar_present(_sidecar_entry(), _ctx(cm051, tmp_path))
    assert r.status == "PASS", r.detail
    assert "fully-verified" in r.detail
    assert _TAG in r.detail


def test_sidecar_present_green_with_caveat_reconstructed(tmp_path):
    """Reconstructed sidecar + allow_reconstructed:true -> PASS with caveat."""
    cm051 = tmp_path / "cm051"; cm051.mkdir()
    _write_daemon_pin_makefile_043(cm051)
    mod = _load_module()
    fake = _SidecarGh(sidecar_content=json.dumps(_backfill_sidecar_json()).encode())
    fake.install(mod)
    r = mod.check_verify_build_info_sidecar_present(
        _sidecar_entry(allow_reconstructed=True), _ctx(cm051, tmp_path))
    assert r.status == "PASS", r.detail
    assert "verified-with-caveat" in r.detail
    assert "reconstructed" in r.detail


def test_sidecar_present_fails_when_reconstructed_but_not_allowed(tmp_path):
    """Reconstructed sidecar without allow_reconstructed -> FAIL."""
    cm051 = tmp_path / "cm051"; cm051.mkdir()
    _write_daemon_pin_makefile_043(cm051)
    mod = _load_module()
    fake = _SidecarGh(sidecar_content=json.dumps(_backfill_sidecar_json()).encode())
    fake.install(mod)
    r = mod.check_verify_build_info_sidecar_present(
        _sidecar_entry(allow_reconstructed=False), _ctx(cm051, tmp_path))
    assert r.status == "FAIL", r.detail
    assert "reconstructed:true" in r.detail
    assert "allow_reconstructed" in r.detail


def test_sidecar_present_fails_when_asset_missing_entirely(tmp_path):
    """No .build-info.json asset in the release -> FAIL closed."""
    cm051 = tmp_path / "cm051"; cm051.mkdir()
    _write_daemon_pin_makefile_043(cm051)
    mod = _load_module()
    fake = _SidecarGh(sidecar_content=None, include_sidecar_asset=False)
    fake.install(mod)
    r = mod.check_verify_build_info_sidecar_present(_sidecar_entry(), _ctx(cm051, tmp_path))
    assert r.status == "FAIL", r.detail
    assert "no .build-info.json asset" in r.detail


def test_sidecar_present_uses_local_dir_first(tmp_path):
    """local_sidecar_dir hit skips GH; validates the Stream 3 backfill flow."""
    cm051 = tmp_path / "cm051"; cm051.mkdir()
    _write_daemon_pin_makefile_043(cm051)
    backfill_dir = tmp_path / "backfill"
    backfill_dir.mkdir()
    (backfill_dir / f"{_TAG}.build-info.json").write_text(
        json.dumps(_backfill_sidecar_json()))
    mod = _load_module()
    # Deliberately break the GH release fetch to prove local won.
    fake = _SidecarGh(sidecar_content=None, include_sidecar_asset=False,
                      release_error="should not be called")
    fake.install(mod)
    r = mod.check_verify_build_info_sidecar_present(
        _sidecar_entry(allow_reconstructed=True,
                       local_sidecar_dir=str(backfill_dir)),
        _ctx(cm051, tmp_path))
    assert r.status == "PASS", r.detail
    assert "local:" in r.detail
    assert fake.asset_fetches == []  # never went to GH


def test_sidecar_present_local_env_var_expansion(tmp_path, monkeypatch):
    """`${VAR}` in local_sidecar_dir is expanded before resolution."""
    cm051 = tmp_path / "cm051"; cm051.mkdir()
    _write_daemon_pin_makefile_043(cm051)
    backfill_dir = tmp_path / "hr015" / "launch" / "backfill-sidecars"
    backfill_dir.mkdir(parents=True)
    (backfill_dir / f"{_TAG}.build-info.json").write_text(
        json.dumps(_backfill_sidecar_json()))
    monkeypatch.setenv("HR015_DIR", str(tmp_path / "hr015"))
    mod = _load_module()
    fake = _SidecarGh(sidecar_content=None, include_sidecar_asset=False)
    fake.install(mod)
    r = mod.check_verify_build_info_sidecar_present(
        _sidecar_entry(allow_reconstructed=True,
                       local_sidecar_dir="${HR015_DIR}/launch/backfill-sidecars"),
        _ctx(cm051, tmp_path))
    assert r.status == "PASS", r.detail


def test_sidecar_present_tag_mismatch_fails(tmp_path):
    """Sidecar carries a different tag_name than the pin -> FAIL (misfile guard)."""
    cm051 = tmp_path / "cm051"; cm051.mkdir()
    _write_daemon_pin_makefile_043(cm051)
    mod = _load_module()
    fake = _SidecarGh(sidecar_content=json.dumps(
        _real_sidecar_json(tag_name="hub-v0.4.99")).encode())
    fake.install(mod)
    r = mod.check_verify_build_info_sidecar_present(_sidecar_entry(), _ctx(cm051, tmp_path))
    assert r.status == "FAIL", r.detail
    assert "hub-v0.4.99" in r.detail and _TAG in r.detail


# --- sidecar-aware pinned_artefact_freshness (opt-in via consume_build_info_sidecar) ---


def test_freshness_backward_compat_when_sidecar_field_omitted(tmp_path):
    """Existing pinned_artefact_freshness entries (no sidecar fields) still PASS
    with no change in behaviour. Backward-compat guard."""
    cm051 = tmp_path / "cm051"; cm051.mkdir()
    _write_daemon_pin_makefile_043(cm051)
    mod = _load_module()
    fake = _SidecarGh()  # no sidecar_content set — never fetched
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(_daemon_entry(), _ctx(cm051, tmp_path))
    assert result.status == "PASS", result.detail
    assert fake.asset_fetches == []  # sidecar path never touched


def test_freshness_with_sidecar_green(tmp_path):
    """consume_build_info_sidecar:true + real sidecar matching pin -> PASS with note."""
    cm051 = tmp_path / "cm051"; cm051.mkdir()
    _write_daemon_pin_makefile_043(cm051)
    mod = _load_module()
    fake = _SidecarGh(sidecar_content=json.dumps(_real_sidecar_json()).encode())
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(
        _freshness_entry_with_sidecar(), _ctx(cm051, tmp_path))
    assert result.status == "PASS", result.detail
    assert "sidecar verified" in result.detail


def test_freshness_with_reconstructed_sidecar_passes_when_allowed(tmp_path):
    """Reconstructed backfill sidecar + allow_reconstructed:true -> PASS with caveat."""
    cm051 = tmp_path / "cm051"; cm051.mkdir()
    _write_daemon_pin_makefile_043(cm051)
    mod = _load_module()
    fake = _SidecarGh(sidecar_content=json.dumps(_backfill_sidecar_json()).encode())
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(
        _freshness_entry_with_sidecar(allow_reconstructed=True), _ctx(cm051, tmp_path))
    assert result.status == "PASS", result.detail
    assert "verified-with-caveat" in result.detail


def test_freshness_sidecar_commit_sha_mismatch_fails(tmp_path):
    """Sidecar declares a different commit_sha than tag resolves to -> FAIL."""
    cm051 = tmp_path / "cm051"; cm051.mkdir()
    _write_daemon_pin_makefile_043(cm051)
    mod = _load_module()
    wrong = _real_sidecar_json(commit_sha="deadbeef" + "0" * 32)
    fake = _SidecarGh(sidecar_content=json.dumps(wrong).encode())
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(
        _freshness_entry_with_sidecar(), _ctx(cm051, tmp_path))
    assert result.status == "FAIL", result.detail
    assert "commit_sha" in result.detail
    assert _TAG_SHA[:12] in result.detail
    assert "deadbeef" in result.detail


def test_freshness_sidecar_dirty_worktree_fails(tmp_path):
    """Sidecar declares dirty_worktree:true -> FAIL (releases must be clean)."""
    cm051 = tmp_path / "cm051"; cm051.mkdir()
    _write_daemon_pin_makefile_043(cm051)
    mod = _load_module()
    dirty = _real_sidecar_json(dirty_worktree=True)
    fake = _SidecarGh(sidecar_content=json.dumps(dirty).encode())
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(
        _freshness_entry_with_sidecar(), _ctx(cm051, tmp_path))
    assert result.status == "FAIL", result.detail
    assert "dirty_worktree:true" in result.detail


def test_freshness_sidecar_tarball_sha_mismatch_is_tamper(tmp_path):
    """verify_tarball_sha:true + downloaded tarball SHA-256 mismatches sidecar -> FAIL."""
    cm051 = tmp_path / "cm051"; cm051.mkdir()
    _write_daemon_pin_makefile_043(cm051)
    mod = _load_module()
    # Sidecar declares one SHA; the tarball we serve hashes to a DIFFERENT one.
    sidecar = _real_sidecar_json(tarball_sha256="a" * 64)
    fake = _SidecarGh(sidecar_content=json.dumps(sidecar).encode(),
                      tarball_content=b"whatever-does-not-match")
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(
        _freshness_entry_with_sidecar(verify_tarball_sha=True), _ctx(cm051, tmp_path))
    assert result.status == "FAIL", result.detail
    assert "TAMPER" in result.detail


def test_freshness_sidecar_tarball_sha_matches_passes(tmp_path):
    """Tarball SHA-256 matches what the sidecar declares -> PASS."""
    cm051 = tmp_path / "cm051"; cm051.mkdir()
    _write_daemon_pin_makefile_043(cm051)
    mod = _load_module()
    tarball_bytes = b"the-real-tarball-bytes"
    expected_sha = hashlib.sha256(tarball_bytes).hexdigest()
    sidecar = _real_sidecar_json(tarball_sha256=expected_sha)
    fake = _SidecarGh(sidecar_content=json.dumps(sidecar).encode(),
                      tarball_content=tarball_bytes)
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(
        _freshness_entry_with_sidecar(verify_tarball_sha=True), _ctx(cm051, tmp_path))
    assert result.status == "PASS", result.detail


def test_freshness_sidecar_missing_fails_closed(tmp_path):
    """consume_build_info_sidecar:true + release has no sidecar -> FAIL."""
    cm051 = tmp_path / "cm051"; cm051.mkdir()
    _write_daemon_pin_makefile_043(cm051)
    mod = _load_module()
    fake = _SidecarGh(sidecar_content=None, include_sidecar_asset=False)
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(
        _freshness_entry_with_sidecar(), _ctx(cm051, tmp_path))
    assert result.status == "FAIL", result.detail
    assert "no .build-info.json asset" in result.detail


def test_freshness_backfill_tarball_sha_unknown_is_skipped(tmp_path):
    """A reconstructed backfill whose tarball_sha256 is `<UNKNOWN...>` still
    passes verify_tarball_sha (skipped, not failed) so older backfills grade
    green when allow_reconstructed:true."""
    cm051 = tmp_path / "cm051"; cm051.mkdir()
    _write_daemon_pin_makefile_043(cm051)
    mod = _load_module()
    unknown_sidecar = _backfill_sidecar_json(
        tarball_sha256="<UNKNOWN - not captured at build time>")
    fake = _SidecarGh(sidecar_content=json.dumps(unknown_sidecar).encode())
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(
        _freshness_entry_with_sidecar(allow_reconstructed=True,
                                      verify_tarball_sha=True),
        _ctx(cm051, tmp_path))
    assert result.status == "PASS", result.detail
    # We never had to fetch the tarball because the expected SHA was unknown.
    assert 5552 not in fake.asset_fetches  # tarball asset id


# ---------------------------------------------------------------------------
# pr_branch_not_stale_vs_main -- catches PR #484 near-miss shape
#
# Encodes `feedback_mergeable_api_state_isnt_semantic_safety`: mergeable ==
# MERGEABLE does NOT prove semantic safety when the branch predates a critical
# recent commit. Turns update-the-branch-before-merge into a mechanical gate
# (by MERGE, never rebase: a rebase rewrites shas, after which
# `git merge-base --is-ancestor` can no longer prove the work landed).
# ---------------------------------------------------------------------------

def _stale_branch_entry(max_behind: int = 10, ignore=None):
    proof = {
        "kind": "pr_branch_not_stale_vs_main",
        "max_commits_behind": max_behind,
    }
    if ignore is not None:
        proof["ignore_commits_matching"] = ignore
    return {
        "id": "pr-branch-stale",
        "title": "PR branch not stale vs main",
        "proof": proof,
    }


class _FakePR:
    """Stub _gh_token_for + _gh_api_json for pr_branch_not_stale_vs_main."""

    def __init__(self, base_sha, head_sha, base_ref="main", pr_number="123",
                 repo="andygmassey/CM051-Home-Hub-Installer",
                 compare_status="ahead", ahead_by=0, commits=None,
                 token="fake-token",
                 branches_error="", compare_error="", pr_error="",
                 state="open", merged_at=None):
        self.base_sha = base_sha
        self.head_sha = head_sha
        self.base_ref = base_ref
        self.pr_number = pr_number
        self.repo = repo
        self.compare_status = compare_status
        self.ahead_by = ahead_by
        self.commits = commits or []
        self.token = token
        self.branches_error = branches_error
        self.compare_error = compare_error
        self.pr_error = pr_error
        self.state = state
        self.merged_at = merged_at
        self.calls: list[str] = []

    def install(self, mod):
        mod._gh_token_for = lambda owner: self.token
        def _api(path, token):
            self.calls.append(path)
            if path == f"repos/{self.repo}/pulls/{self.pr_number}":
                if self.pr_error:
                    return None, self.pr_error
                return {"base": {"sha": self.base_sha, "ref": self.base_ref},
                        "state": self.state, "merged_at": self.merged_at}, ""
            if path == f"repos/{self.repo}/branches/{self.base_ref}":
                if self.branches_error:
                    return None, self.branches_error
                return {"commit": {"sha": self.head_sha}}, ""
            if path == f"repos/{self.repo}/compare/{self.base_sha}...{self.head_sha}":
                if self.compare_error:
                    return None, self.compare_error
                return {"status": self.compare_status, "ahead_by": self.ahead_by,
                        "commits": self.commits}, ""
            return None, f"unrouted path: {path}"
        mod._gh_api_json = _api


def test_stale_branch_skip_when_env_missing(tmp_path, monkeypatch):
    """Local dev / non-PR context: SKIP so the manifest gate can still be run."""
    monkeypatch.delenv("PR_NUMBER", raising=False)
    monkeypatch.delenv("GITHUB_REPOSITORY", raising=False)
    mod = _load_module()
    result = mod.check_pr_branch_not_stale_vs_main(
        _stale_branch_entry(), {"cm051_dir": tmp_path, "app_path": tmp_path})
    assert result.status == "SKIP"
    assert "PR_NUMBER" in result.detail


def test_stale_branch_pass_when_up_to_date(tmp_path, monkeypatch):
    monkeypatch.setenv("PR_NUMBER", "484")
    monkeypatch.setenv("GITHUB_REPOSITORY", "andygmassey/CM051-Home-Hub-Installer")
    mod = _load_module()
    _FakePR(base_sha="a" * 40, head_sha="a" * 40, pr_number="484").install(mod)
    result = mod.check_pr_branch_not_stale_vs_main(
        _stale_branch_entry(), {"cm051_dir": tmp_path, "app_path": tmp_path})
    assert result.status == "PASS", result.detail
    assert "up to date" in result.detail


def test_stale_branch_pass_when_behind_below_threshold(tmp_path, monkeypatch):
    """5 commits behind, threshold=10 -- PASS."""
    monkeypatch.setenv("PR_NUMBER", "484")
    monkeypatch.setenv("GITHUB_REPOSITORY", "andygmassey/CM051-Home-Hub-Installer")
    mod = _load_module()
    commits = [{"sha": f"c{i:03d}" * 8,
                "commit": {"message": f"feat: real work {i}"}} for i in range(5)]
    _FakePR(base_sha="a" * 40, head_sha="b" * 40, pr_number="484",
            ahead_by=5, commits=commits).install(mod)
    result = mod.check_pr_branch_not_stale_vs_main(
        _stale_branch_entry(max_behind=10),
        {"cm051_dir": tmp_path, "app_path": tmp_path})
    assert result.status == "PASS", result.detail
    assert "5 non-ignored" in result.detail or "5 commits behind" in result.detail


def test_stale_branch_fail_when_behind_exceeds_threshold(tmp_path, monkeypatch):
    """PR #484 near-miss shape: branch predates a critical recent daemon-pin bump.

    Simulates the actual 2026-07-31 scenario: mergeable=MERGEABLE but branch is
    stale relative to a critical recent merge; recommending merge would revert.
    """
    monkeypatch.setenv("PR_NUMBER", "484")
    monkeypatch.setenv("GITHUB_REPOSITORY", "andygmassey/CM051-Home-Hub-Installer")
    mod = _load_module()
    commits = [
        {"sha": "d1" * 20, "commit": {"message": "fix(cut): pin daemon to hub-v0.4.43 (0.4.41->0.4.43) (#492)"}},
        {"sha": "d2" * 20, "commit": {"message": "chore(vendor): re-sync apple_mail_mbox.py #197 (#489)"}},
        {"sha": "d3" * 20, "commit": {"message": "chore(daemon): bump hub 0.4.40 -> 0.4.41 (#488)"}},
    ] + [{"sha": f"e{i:03d}" * 8, "commit": {"message": f"chore: unrelated {i}"}}
         for i in range(9)]  # 12 total > 10
    _FakePR(base_sha="a" * 40, head_sha="b" * 40, pr_number="484",
            ahead_by=len(commits), commits=commits).install(mod)
    result = mod.check_pr_branch_not_stale_vs_main(
        _stale_branch_entry(max_behind=10),
        {"cm051_dir": tmp_path, "app_path": tmp_path})
    assert result.status == "FAIL", result.detail
    assert "0.4.43" in result.detail  # the critical merge that would be reverted
    assert "Recovery" in result.detail
    # The recovery instruction says MERGE, not rebase. House rule: branches are
    # updated by merge, never rebase, because a rebase rewrites shas and
    # `git merge-base --is-ancestor` can then never prove the work landed.
    assert "merge main into the branch" in result.detail, result.detail
    assert "rebase" not in result.detail, result.detail


def test_stale_branch_ignore_patterns_reduce_count(tmp_path, monkeypatch):
    """docs:/chore(fmt) commits filtered from the behind-by count."""
    monkeypatch.setenv("PR_NUMBER", "484")
    monkeypatch.setenv("GITHUB_REPOSITORY", "andygmassey/CM051-Home-Hub-Installer")
    mod = _load_module()
    commits = [{"sha": f"c{i:03d}" * 8,
                "commit": {"message": f"chore(fmt): rustfmt sweep {i}"}} for i in range(15)]
    _FakePR(base_sha="a" * 40, head_sha="b" * 40, pr_number="484",
            ahead_by=15, commits=commits).install(mod)
    result = mod.check_pr_branch_not_stale_vs_main(
        _stale_branch_entry(max_behind=10, ignore=[r"^chore\(fmt\)"]),
        {"cm051_dir": tmp_path, "app_path": tmp_path})
    # All 15 ignored -> 0 non-ignored, well within threshold.
    assert result.status == "PASS", result.detail


def test_stale_branch_fail_on_api_error(tmp_path, monkeypatch):
    """Fail-closed: transient API error MUST fail, not silently pass."""
    monkeypatch.setenv("PR_NUMBER", "484")
    monkeypatch.setenv("GITHUB_REPOSITORY", "andygmassey/CM051-Home-Hub-Installer")
    mod = _load_module()
    _FakePR(base_sha="a" * 40, head_sha="b" * 40, pr_number="484",
            pr_error="gh api pulls/484 exit=1: HTTP 502").install(mod)
    result = mod.check_pr_branch_not_stale_vs_main(
        _stale_branch_entry(), {"cm051_dir": tmp_path, "app_path": tmp_path})
    assert result.status == "FAIL"
    assert "502" in result.detail


def test_stale_branch_fail_on_missing_token(tmp_path, monkeypatch):
    monkeypatch.setenv("PR_NUMBER", "484")
    monkeypatch.setenv("GITHUB_REPOSITORY", "andygmassey/CM051-Home-Hub-Installer")
    monkeypatch.delenv("GH_TOKEN", raising=False)
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    mod = _load_module()
    _FakePR(base_sha="a" * 40, head_sha="b" * 40, token=None).install(mod)
    result = mod.check_pr_branch_not_stale_vs_main(
        _stale_branch_entry(), {"cm051_dir": tmp_path, "app_path": tmp_path})
    assert result.status == "FAIL"
    assert "gh token" in result.detail


def test_stale_branch_pass_via_ignore_and_below_threshold(tmp_path, monkeypatch):
    """Mix of ignored + real commits; real commits under threshold -> PASS."""
    monkeypatch.setenv("PR_NUMBER", "484")
    monkeypatch.setenv("GITHUB_REPOSITORY", "andygmassey/CM051-Home-Hub-Installer")
    mod = _load_module()
    commits = (
        [{"sha": f"i{i:03d}" * 8, "commit": {"message": "docs: readme"}} for i in range(20)]
        + [{"sha": f"r{i:03d}" * 8, "commit": {"message": "feat: real"}} for i in range(3)]
    )
    _FakePR(base_sha="a" * 40, head_sha="b" * 40, pr_number="484",
            ahead_by=23, commits=commits).install(mod)
    result = mod.check_pr_branch_not_stale_vs_main(
        _stale_branch_entry(max_behind=10, ignore=[r"^docs:"]),
        {"cm051_dir": tmp_path, "app_path": tmp_path})
    assert result.status == "PASS", result.detail


# ---------------------------------------------------------------------------
# THE ROW THAT COULD NOT FAIL.
#
# permanent-pr-branch-not-stale-vs-main was written 2026-07-31 and never ran
# once. It reads PR_NUMBER; `grep -rn PR_NUMBER .github/workflows/` returned
# nothing (control: the same grep for `pull_request` matched 12 files), so every
# invocation returned SKIP, and SKIP and PASS both leave the exit code at 0.
#
# The eight cases above all stub the API and call the primitive DIRECTLY, so
# every one of them passed while the row was unreachable in production. They
# tested the check. Nothing tested that the check RUNS. These do.
# ---------------------------------------------------------------------------

def _run_verifier(args, env=None, cwd=None):
    """Invoke verify_cut_manifest.py as a subprocess; return (rc, stdout+stderr)."""
    proc_env = dict(os.environ)
    proc_env.pop("PR_NUMBER", None)
    proc_env.pop("GITHUB_REPOSITORY", None)
    proc_env.update(env or {})
    r = subprocess.run([sys.executable, str(SCRIPT)] + args,
                       capture_output=True, env=proc_env,
                       cwd=str(cwd) if cwd else None, timeout=120)
    return r.returncode, (r.stdout + r.stderr).decode("utf-8", "replace")


@pytest.fixture
def staleness_manifest_dir(tmp_path):
    """A manifest dir holding ONLY the staleness row, plus an empty per-cut file."""
    d = tmp_path / "cut-manifests"
    d.mkdir()
    (d / "permanent.yaml").write_text(
        "version: permanent\n"
        "entries:\n"
        "  - id: permanent-pr-branch-not-stale-vs-main\n"
        "    title: current PR branch must not be more than N commits behind its target branch\n"
        "    proof:\n"
        "      kind: pr_branch_not_stale_vs_main\n"
        "      max_commits_behind: 10\n"
    )
    (d / "v9.9.9.yaml").write_text("version: v9.9.9\nentries: []\n")
    return d


def test_require_kind_turns_the_silent_skip_into_cannot_run(staleness_manifest_dir):
    """RED-to-GREEN for the defect itself.

    With PR_NUMBER unset the row SKIPs. Without --require-kind that is exit 0,
    which is the bug: identical to a row that ran and passed. With
    --require-kind it must be exit 3.
    """
    args = ["--manifest-dir", str(staleness_manifest_dir),
            "--only-kind", "pr_branch_not_stale_vs_main"]

    rc_without, out_without = _run_verifier(args)
    assert rc_without == 0, out_without
    assert "SKIP" in out_without
    # The defect, stated as an assertion: a skipped row and a passing row are
    # the same exit code without the lever.
    assert "0 PASS  0 FAIL  1 SKIP" in out_without, out_without

    rc_with, out_with = _run_verifier(
        args + ["--require-kind", "pr_branch_not_stale_vs_main"])
    assert rc_with == 3, out_with
    assert "CANNOT-RUN" in out_with
    assert "0 RAN" in out_with, out_with


def test_require_kind_names_the_denominator_when_the_kind_is_absent(tmp_path):
    """A manifest with no entry of the required kind is CANNOT-RUN, not a pass.

    Deleting the row is the other way to make the gate unreachable, and it must
    not read as green either.
    """
    d = tmp_path / "cut-manifests"
    d.mkdir()
    (d / "permanent.yaml").write_text("version: permanent\nentries: []\n")
    (d / "v9.9.9.yaml").write_text("version: v9.9.9\nentries: []\n")
    rc, out = _run_verifier(["--manifest-dir", str(d),
                             "--require-kind", "pr_branch_not_stale_vs_main"])
    assert rc == 3, out
    assert "0 entries of that kind exist" in out, out


def test_require_kind_is_satisfied_when_the_row_actually_runs(staleness_manifest_dir,
                                                              monkeypatch, tmp_path):
    """Positive control: the lever must not fail a run in which the row DID run.

    A gate that always exits 3 proves as little as one that always exits 0.
    """
    fake_gh = tmp_path / "bin"
    fake_gh.mkdir()
    script = fake_gh / "gh"
    script.write_text(
        "#!/bin/sh\n"
        'case "$*" in\n'
        '  "auth token --user"*) exit 1 ;;\n'
        '  *"/pulls/"*) echo \'{"base":{"sha":"aaaaaaaa","ref":"main"}}\' ;;\n'
        '  *"/branches/main") echo \'{"commit":{"sha":"aaaaaaaa"}}\' ;;\n'
        "  *) exit 1 ;;\n"
        "esac\n"
    )
    script.chmod(0o755)
    rc, out = _run_verifier(
        ["--manifest-dir", str(staleness_manifest_dir),
         "--only-kind", "pr_branch_not_stale_vs_main",
         "--require-kind", "pr_branch_not_stale_vs_main"],
        env={"PR_NUMBER": "123",
             "GITHUB_REPOSITORY": "andygmassey/CM051-Home-Hub-Installer",
             "GH_TOKEN": "fake-token",
             "PATH": f"{fake_gh}:{os.environ.get('PATH', '')}"},
    )
    assert rc == 0, out
    assert "1 RAN, 0 did not" in out, out
    assert "PASS" in out


def test_workflow_wiring_sets_pr_number(tmp_path):
    """The wiring itself is the thing that rotted; assert it exists.

    The primitive was correct all along. What was missing was a caller that set
    PR_NUMBER. Nothing guarded that, so nothing noticed for the row's entire
    lifetime.
    """
    repo_root = SCRIPT.resolve().parent.parent
    wf = repo_root / ".github" / "workflows" / "pr-branch-staleness.yml"
    assert wf.is_file(), f"the PR-context runner is missing: {wf}"
    text = wf.read_text(encoding="utf-8")
    assert "PR_NUMBER:" in text, "the runner does not set PR_NUMBER"
    assert "github.event.pull_request.number" in text
    assert "--require-kind" in text, (
        "without --require-kind the runner can go green by not running")
    # Positive control for the greps above: a string that MUST be present.
    assert "verify_cut_manifest.py" in text
    # No `paths:` filter -- staleness is a property of the branch, not of the
    # files it touches, so a filter would skip exactly the PRs it must catch.
    assert "\n    paths:" not in text and "\n      paths:" not in text, (
        "pr-branch-staleness.yml must not carry a paths: filter")


def test_compare_commit_cap_counts_uninspected_commits_as_non_ignored():
    """GitHub caps compare .commits at 250 while .ahead_by reports the truth.

    Measured against PR #509 on 2026-08-19: ahead_by=393, len(commits)=250. If
    the ignore filter is applied only to the returned page, a branch 393 behind
    whose first 250 commits all match an ignore pattern counts as 0 behind and
    PASSES. An un-inspected commit is not an ignorable one.
    """
    mod = _load_module()
    import os as _os
    _os.environ["PR_NUMBER"] = "509"
    _os.environ["GITHUB_REPOSITORY"] = "andygmassey/CM051-Home-Hub-Installer"
    try:
        commits = [{"sha": f"d{i:03d}" * 8, "commit": {"message": "docs: churn"}}
                   for i in range(250)]
        _FakePR(base_sha="a" * 40, head_sha="b" * 40, pr_number="509",
                ahead_by=393, commits=commits).install(mod)
        result = mod.check_pr_branch_not_stale_vs_main(
            _stale_branch_entry(max_behind=10, ignore=[r"^docs:"]),
            {"cm051_dir": Path("."), "app_path": Path(".")})
        assert result.status == "FAIL", result.detail
        assert "143 NOT inspected" in result.detail, result.detail
        assert "143 non-ignored" in result.detail, result.detail
    finally:
        _os.environ.pop("PR_NUMBER", None)
        _os.environ.pop("GITHUB_REPOSITORY", None)


# ---------------------------------------------------------------------------
# A CLOSED PR HAS NO ANSWER TO THIS QUESTION.
#
# I ran this primitive by hand against #1124 and #1118 on 2026-08-27 and it said
# "22 commits behind, over the threshold of 10". I published that. Both had
# MERGED 85 minutes earlier, and both merge commits were already ancestors of
# the main I was comparing against. `pulls/{n}.base.sha` freezes when a PR
# leaves the open state, so the arithmetic was right and the question was void.
#
# CI cannot reach this -- `on: pull_request` fires only for open PRs -- which is
# exactly why nothing would ever have caught it. The primitive is what a human
# invokes directly.
# ---------------------------------------------------------------------------

def test_a_merged_pr_is_not_measured_it_is_skipped(tmp_path, monkeypatch):
    monkeypatch.setenv("PR_NUMBER", "1124")
    monkeypatch.setenv("GITHUB_REPOSITORY", "andygmassey/CM051-Home-Hub-Installer")
    mod = _load_module()
    commits = [{"sha": f"c{i:03d}" * 8, "commit": {"message": f"feat: real work {i}"}}
               for i in range(22)]
    _FakePR(base_sha="a" * 40, head_sha="b" * 40, pr_number="1124",
            ahead_by=22, commits=commits,
            state="closed", merged_at="2026-08-27T03:34:24Z").install(mod)
    result = mod.check_pr_branch_not_stale_vs_main(
        _stale_branch_entry(max_behind=10),
        {"cm051_dir": tmp_path, "app_path": tmp_path})
    assert result.status == "SKIP", result.detail
    assert "closed" in result.detail
    assert "2026-08-27T03:34:24Z" in result.detail
    # And it must NOT report the void number as though it meant something.
    assert "22 non-ignored" not in result.detail, result.detail


def test_an_open_pr_with_the_same_shape_still_fails(tmp_path, monkeypatch):
    """CONTROL for the case above, and it is the load-bearing half.

    Identical inputs except `state`. If this also skipped, the guard would have
    silenced the gate rather than narrowed it -- which is the mistake the guard
    exists to avoid, one level down.
    """
    monkeypatch.setenv("PR_NUMBER", "1124")
    monkeypatch.setenv("GITHUB_REPOSITORY", "andygmassey/CM051-Home-Hub-Installer")
    mod = _load_module()
    commits = [{"sha": f"c{i:03d}" * 8, "commit": {"message": f"feat: real work {i}"}}
               for i in range(22)]
    _FakePR(base_sha="a" * 40, head_sha="b" * 40, pr_number="1124",
            ahead_by=22, commits=commits, state="open").install(mod)
    result = mod.check_pr_branch_not_stale_vs_main(
        _stale_branch_entry(max_behind=10),
        {"cm051_dir": tmp_path, "app_path": tmp_path})
    assert result.status == "FAIL", result.detail
    assert "22 non-ignored" in result.detail


def test_a_response_with_no_state_field_is_still_measured(tmp_path, monkeypatch):
    """Absence of `state` must not be read as 'closed'.

    A stubbed or partial API response omits it. Treating a missing field as a
    reason to skip would turn every harness that does not model `state` into a
    silent pass -- absence and failure, indistinguishable at the call site.
    """
    monkeypatch.setenv("PR_NUMBER", "484")
    monkeypatch.setenv("GITHUB_REPOSITORY", "andygmassey/CM051-Home-Hub-Installer")
    mod = _load_module()
    _FakePR(base_sha="a" * 40, head_sha="a" * 40, pr_number="484",
            state=None).install(mod)
    result = mod.check_pr_branch_not_stale_vs_main(
        _stale_branch_entry(), {"cm051_dir": tmp_path, "app_path": tmp_path})
    assert result.status == "PASS", result.detail
    assert "up to date" in result.detail

