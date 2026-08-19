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


def test_freshness_fail_when_missing_token(tmp_path):
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_daemon_pin_makefile(cm051, "0.4.39")
    mod = _load_module()
    fake = _FakeGh(tag_sha="a" * 40, head_sha="b" * 40, token=None)
    fake.install(mod)
    result = mod.check_pinned_artefact_freshness(_daemon_entry(),
                                                 {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "FAIL"
    assert "gh auth login --user ostler-ai" in result.detail


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
# pin_matches_latest_release_tag -- cross-repo tag consistency gate
#
# Sibling of pinned_artefact_freshness; distinct failure mode:
# "did a NEW release tag land that the pin does not yet reflect?"
# ---------------------------------------------------------------------------

def _write_makefile_pin(cm051: Path, version: str) -> None:
    (cm051 / "gui").mkdir(parents=True, exist_ok=True)
    (cm051 / "gui" / "Makefile").write_text(
        f"# fake\nDAEMON_VERSION       ?= {version}\n"
    )


def _tag_consistency_entry():
    return {
        "id": "tag-consistency",
        "title": "daemon pin matches latest hub-v* release",
        "proof": {
            "kind": "pin_matches_latest_release_tag",
            "release_repo": "ostler-ai/ostler-releases",
            "pin_file": "gui/Makefile",
            "pin_var_pattern": r"DAEMON_VERSION\s*[?:]?=\s*(\d+\.\d+\.\d+)",
            "tag_prefix": "hub-v",
        },
    }


class _FakeReleaseListing:
    """Stub for _list_releases_paginated + _gh_token_for on the loaded module."""

    def __init__(self, releases: list[dict] | None, error: str = "",
                 token: str | None = "fake-token"):
        self.releases = releases
        self.error = error
        self.token = token
        self.calls: list[str] = []

    def install(self, mod):
        mod._gh_token_for = lambda owner: self.token
        def _fake(source_repo, token, max_pages=5):
            self.calls.append(source_repo)
            if self.error:
                return None, self.error
            return self.releases, ""
        mod._list_releases_paginated = _fake


def test_tag_consistency_pass_when_pin_matches_latest(tmp_path):
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_makefile_pin(cm051, "0.4.43")
    mod = _load_module()
    releases = [
        {"tag_name": "hub-v0.4.43", "published_at": "2026-07-31T04:40:23Z",
         "draft": False, "prerelease": False},
        {"tag_name": "hub-v0.4.42", "published_at": "2026-07-30T00:00:00Z",
         "draft": False, "prerelease": False},
        {"tag_name": "remote-capture-v0.1.3", "published_at": "2026-07-25T00:00:00Z",
         "draft": False, "prerelease": False},
    ]
    _FakeReleaseListing(releases).install(mod)
    result = mod.check_pin_matches_latest_release_tag(
        _tag_consistency_entry(),
        {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "PASS", result.detail
    assert "hub-v0.4.43" in result.detail


def test_tag_consistency_fail_when_new_release_landed(tmp_path):
    """Pin lags behind a newer release -- exact hardening scenario."""
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_makefile_pin(cm051, "0.4.41")
    mod = _load_module()
    releases = [
        {"tag_name": "hub-v0.4.43", "published_at": "2026-07-31T04:40:23Z",
         "draft": False, "prerelease": False},
        {"tag_name": "hub-v0.4.42", "published_at": "2026-07-30T00:00:00Z",
         "draft": False, "prerelease": False},
        {"tag_name": "hub-v0.4.41", "published_at": "2026-07-29T00:00:00Z",
         "draft": False, "prerelease": False},
    ]
    _FakeReleaseListing(releases).install(mod)
    result = mod.check_pin_matches_latest_release_tag(
        _tag_consistency_entry(),
        {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "FAIL", result.detail
    assert "DRIFT" in result.detail
    assert "0.4.41" in result.detail  # the stale pin
    assert "0.4.43" in result.detail  # the latest release
    assert "Recovery" in result.detail


def test_tag_consistency_filters_by_tag_prefix(tmp_path):
    """When the release repo hosts multiple product tags (hub-v* + remote-capture-v*),
    the check MUST filter by the configured tag_prefix and not confuse them.
    """
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_makefile_pin(cm051, "0.4.43")
    mod = _load_module()
    releases = [
        # A remote-capture release published LATER than the latest hub-v --
        # the wrong filter would pick this and falsely fail.
        {"tag_name": "remote-capture-v0.1.5", "published_at": "2026-08-15T00:00:00Z",
         "draft": False, "prerelease": False},
        {"tag_name": "hub-v0.4.43", "published_at": "2026-07-31T04:40:23Z",
         "draft": False, "prerelease": False},
    ]
    _FakeReleaseListing(releases).install(mod)
    result = mod.check_pin_matches_latest_release_tag(
        _tag_consistency_entry(),
        {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "PASS", result.detail
    assert "hub-v0.4.43" in result.detail


def test_tag_consistency_ignores_drafts_and_prereleases(tmp_path):
    """A draft or prerelease with a HIGHER tag must not count as `latest`."""
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_makefile_pin(cm051, "0.4.43")
    mod = _load_module()
    releases = [
        {"tag_name": "hub-v0.4.44", "published_at": "2026-08-01T00:00:00Z",
         "draft": True, "prerelease": False},
        {"tag_name": "hub-v0.4.44-rc1", "published_at": "2026-08-01T00:00:00Z",
         "draft": False, "prerelease": True},
        {"tag_name": "hub-v0.4.43", "published_at": "2026-07-31T04:40:23Z",
         "draft": False, "prerelease": False},
    ]
    _FakeReleaseListing(releases).install(mod)
    result = mod.check_pin_matches_latest_release_tag(
        _tag_consistency_entry(),
        {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "PASS", result.detail


def test_tag_consistency_fail_when_no_matching_releases(tmp_path):
    """Empty release listing for the tag_prefix -- fail-closed."""
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_makefile_pin(cm051, "0.4.43")
    mod = _load_module()
    _FakeReleaseListing([
        {"tag_name": "some-other-v1.0.0", "published_at": "2026-08-01T00:00:00Z",
         "draft": False, "prerelease": False},
    ]).install(mod)
    result = mod.check_pin_matches_latest_release_tag(
        _tag_consistency_entry(),
        {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "FAIL"
    assert "no releases matching prefix" in result.detail


def test_tag_consistency_fail_when_missing_token(tmp_path):
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_makefile_pin(cm051, "0.4.43")
    mod = _load_module()
    _FakeReleaseListing([], token=None).install(mod)
    result = mod.check_pin_matches_latest_release_tag(
        _tag_consistency_entry(),
        {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "FAIL"
    assert "gh auth login --user ostler-ai" in result.detail


def test_tag_consistency_fail_on_transient_api_error(tmp_path):
    """Network flake MUST fail the gate, not silently pass."""
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_makefile_pin(cm051, "0.4.43")
    mod = _load_module()
    _FakeReleaseListing(None, error="gh api releases exit=1: connection reset").install(mod)
    result = mod.check_pin_matches_latest_release_tag(
        _tag_consistency_entry(),
        {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "FAIL"
    assert "connection reset" in result.detail


def test_tag_consistency_fail_on_missing_pin_source(tmp_path):
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    # deliberately no gui/Makefile
    mod = _load_module()
    _FakeReleaseListing([]).install(mod)
    result = mod.check_pin_matches_latest_release_tag(
        _tag_consistency_entry(),
        {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "FAIL"
    assert "pin source file not found" in result.detail


def test_tag_consistency_fail_on_malformed_release_repo(tmp_path):
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_makefile_pin(cm051, "0.4.43")
    mod = _load_module()
    bad_entry = _tag_consistency_entry()
    bad_entry["proof"]["release_repo"] = "not-a-slug"
    result = mod.check_pin_matches_latest_release_tag(
        bad_entry, {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "FAIL"
    assert "release_repo missing or malformed" in result.detail


def test_tag_consistency_picks_newest_by_published_at(tmp_path):
    """Two matching releases with different published_at times -- must pick the newest."""
    cm051 = tmp_path / "cm051"
    cm051.mkdir()
    _write_makefile_pin(cm051, "0.4.50")
    mod = _load_module()
    # Deliberately mis-ordered input.
    releases = [
        {"tag_name": "hub-v0.4.43", "published_at": "2026-07-31T04:40:23Z",
         "draft": False, "prerelease": False},
        {"tag_name": "hub-v0.4.50", "published_at": "2026-08-05T00:00:00Z",
         "draft": False, "prerelease": False},
        {"tag_name": "hub-v0.4.49", "published_at": "2026-08-04T00:00:00Z",
         "draft": False, "prerelease": False},
    ]
    _FakeReleaseListing(releases).install(mod)
    result = mod.check_pin_matches_latest_release_tag(
        _tag_consistency_entry(),
        {"cm051_dir": cm051, "app_path": tmp_path / "no-app"})
    assert result.status == "PASS", result.detail
    assert "hub-v0.4.50" in result.detail


# ---------------------------------------------------------------------------
# pr_branch_not_stale_vs_main -- catches PR #484 near-miss shape
#
# Encodes `feedback_mergeable_api_state_isnt_semantic_safety`: mergeable ==
# MERGEABLE does NOT prove semantic safety when the branch predates a critical
# recent commit. Turns rebase-before-merge into a mechanical gate.
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
                 branches_error="", compare_error="", pr_error=""):
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
        self.calls: list[str] = []

    def install(self, mod):
        mod._gh_token_for = lambda owner: self.token
        def _api(path, token):
            self.calls.append(path)
            if path == f"repos/{self.repo}/pulls/{self.pr_number}":
                if self.pr_error:
                    return None, self.pr_error
                return {"base": {"sha": self.base_sha, "ref": self.base_ref}}, ""
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
