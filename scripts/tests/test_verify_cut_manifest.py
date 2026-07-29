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


def _write_probe(cm051: Path, name: str, body: str) -> Path:
    """Register a probe script under scripts/box_walk_probes/."""
    probes = cm051 / "scripts" / "box_walk_probes"
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
# payload_version_matches_daemon_version
# ---------------------------------------------------------------------------


def _make_payload(fake_app: Path, version_text: str) -> None:
    """Build the (B-lite) payload layout inside the fake app.

    - Contents/Resources/ostler-payload/VERSION carries `version_text` verbatim.
    - A stub daemon binary is placed at
      Contents/Resources/ostler-payload/assistant-agent/bin/ostler-assistant so
      the gate's presence check passes. The gate no longer invokes `--version`
      (the daemon binary reports the FROZEN Cargo workspace version by design --
      see reference_ostler_assistant_version_field_frozen); it compares VERSION
      against the DAEMON_VERSION release pin. So the binary's contents are
      irrelevant here -- only its presence matters.
    """
    payload = fake_app / "Contents" / "Resources" / "ostler-payload"
    bin_dir = payload / "assistant-agent" / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    (payload / "VERSION").write_text(version_text)
    daemon = bin_dir / "ostler-assistant"
    daemon.write_text("#!/usr/bin/env bash\nexit 0\n")
    daemon.chmod(0o755)


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
