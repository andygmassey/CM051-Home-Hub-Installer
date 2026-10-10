"""Lane 30, "If this Mac were taken": red and green for every check, the
canary proof, the no-network proof and the flag/route behaviour.

Synthetic only. No real person, account, key or token appears here: every
secret-shaped string is assembled at run time from fragments so this file
never contains one, and the "keys" are random filler behind a real header.

THE CANARY TEST (test_canary_*): plants a canary secret in every place the
check looks (a dev-folder .env, ~/.aws/credentials, an SSH key body, a Chrome
Login Data row and Cookies row, a Firefox logins.json) and asserts the canary
appears in NONE of: the returned result, the saved state file, the log
records, stdout/stderr, or anything under the state directory. A positive
control proves the canary really is in the fixture and that the check really
did flag the files, so the test cannot pass by finding nothing.

Run: python3 -m pytest tests/test_exposure_check.py -q
(needs fastapi, httpx, pyyaml, qrcode for the route tests).
"""
import ast
import base64
import json
import logging
import os
import socket
import sqlite3
import struct
import sys
from pathlib import Path

import pytest

AGENT = Path(__file__).resolve().parent.parent / "vendor" / "doctor" / "agent"
sys.path.insert(0, str(AGENT))

import exposure_check as ec  # noqa: E402

CANARY = "sk_" + "live_" + "CANARY" + "Q" * 24            # matches the Stripe-live shape
CANARY_B64 = base64.b64encode(CANARY.encode()).decode()
CANARY_HEX = CANARY.encode().hex()


# ── fixtures ───────────────────────────────────────────────────────────────

class FakeEnv(ec.Env):
    """Scripted commands. Records every call so tests can assert on how a
    command was run (notably exit_only for value-bearing ones)."""

    def __init__(self, script=None, **kw):
        super().__init__(**kw)
        self.script = script or {}
        self.calls = []

    def run(self, argv, exit_only=False, timeout=8.0):
        self.calls.append((tuple(argv), exit_only))
        rc, text = self.script.get(tuple(argv), (None, ""))
        return rc, ("" if exit_only else text)


GREEN_MAC = {
    ("fdesetup", "status"): (0, "FileVault is On.\n"),
    ("sysadminctl", "-screenLock", "status"): (0, "screenLock delay is immediate\n"),
    ("defaults", "read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser"): (1, ""),
    ("system_profiler", "SPHardwareDataType"): (0, "      Activation Lock Status: Enabled\n"),
    ("nvram", "fmm-mobileme-token-FMM"): (0, ""),
    ("security", "show-keychain-info", "{kc}"): (0, 'Keychain "x" lock-on-sleep timeout=300s\n'),
}


def mac_env(tmp_path, script_over=None, arch="arm64", **kw):
    home = tmp_path / "home"
    home.mkdir(parents=True, exist_ok=True)
    root = tmp_path / "root"
    (root / "etc/pam.d").mkdir(parents=True, exist_ok=True)
    script = {}
    for k, v in GREEN_MAC.items():
        k = tuple(str(home / "Library/Keychains/login.keychain-db") if p == "{kc}" else p for p in k)
        script[k] = v
    script.update(script_over or {})
    return FakeEnv(script, home=home, system="Darwin", arch=arch, root=root, **kw)


def by_id(result):
    return {c["id"]: c for c in result["checks"]}


def key_openssh(cipher=b"none", keytype=b"ssh-ed25519"):
    def s(b):
        return struct.pack(">I", len(b)) + b
    pub = s(keytype) + s(os.urandom(32))
    raw = b"openssh-key-v1\x00" + s(cipher) + s(b"none" if cipher == b"none" else b"bcrypt") + s(b"") \
        + struct.pack(">I", 1) + s(pub) + s(os.urandom(200))
    b64 = base64.b64encode(raw).decode()
    wrapped = "\n".join(b64[i:i + 70] for i in range(0, len(b64), 70))
    return ("-----BEGIN OPENSSH PRIVATE KEY-----\n" + wrapped + "\n-----END OPENSSH PRIVATE KEY-----\n").encode()


def key_pem(encrypted):
    body = base64.b64encode(os.urandom(300)).decode()
    hdr = "Proc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,00112233445566778899AABBCCDDEEFF\n\n" if encrypted else ""
    return f"-----BEGIN RSA PRIVATE KEY-----\n{hdr}{body}\n-----END RSA PRIVATE KEY-----\n".encode()


# ── system settings: red / green / cannot ──────────────────────────────────

@pytest.mark.parametrize("out,rc,expect", [
    ("FileVault is On.\n", 0, ec.OK),
    ("FileVault is Off.\n", 0, ec.RISK),
    ("garbled\n", 0, ec.CANNOT),
    ("", None, ec.CANNOT),
])
def test_filevault(tmp_path, out, rc, expect):
    env = mac_env(tmp_path, {("fdesetup", "status"): (rc, out)})
    assert ec.check_filevault(env)["verdict"] == expect


@pytest.mark.parametrize("out,expect", [
    ("screenLock delay is immediate\n", ec.OK),
    ("screenLock delay is 5 seconds\n", ec.OK),
    ("screenLock delay is 300 seconds\n", ec.RISK),
    ("screenLock is off\n", ec.RISK),
])
def test_screen_lock(tmp_path, out, expect):
    env = mac_env(tmp_path, {("sysadminctl", "-screenLock", "status"): (0, out)})
    assert ec.check_screen_lock(env)["verdict"] == expect


def test_screen_lock_falls_back_to_defaults_then_cannot(tmp_path):
    over = {("sysadminctl", "-screenLock", "status"): (None, ""),
            ("defaults", "read", "com.apple.screensaver", "askForPassword"): (0, "1\n"),
            ("defaults", "read", "com.apple.screensaver", "askForPasswordDelay"): (0, "0\n")}
    assert ec.check_screen_lock(mac_env(tmp_path, over))["verdict"] == ec.OK
    over[("defaults", "read", "com.apple.screensaver", "askForPassword")] = (0, "0\n")
    assert ec.check_screen_lock(mac_env(tmp_path, over))["verdict"] == ec.RISK
    assert ec.check_screen_lock(mac_env(tmp_path, {("sysadminctl", "-screenLock", "status"): (None, "")}))["verdict"] == ec.CANNOT


def test_auto_login_red_green_and_never_reads_the_user_name(tmp_path):
    key = ("defaults", "read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser")
    green = mac_env(tmp_path, {key: (1, "")})
    assert ec.check_auto_login(green)["verdict"] == ec.OK
    red = mac_env(tmp_path, {key: (0, "")})
    assert ec.check_auto_login(red)["verdict"] == ec.RISK
    assert (key, True) in red.calls, "autoLoginUser must be run exit_only"
    kc = tmp_path / "root/etc/kcpassword"
    kc.write_bytes(b"\x00" * 4)
    assert ec.check_auto_login(mac_env(tmp_path, {key: (1, "")}))["verdict"] == ec.RISK
    assert ec.check_auto_login(mac_env(tmp_path, {key: (None, "")}))["verdict"] in (ec.RISK, ec.CANNOT)


def test_find_my(tmp_path):
    nv = ("nvram", "fmm-mobileme-token-FMM")
    sp = ("system_profiler", "SPHardwareDataType")
    assert ec.check_find_my(mac_env(tmp_path, {sp: (0, "Activation Lock Status: Enabled"), nv: (1, "")}))["verdict"] == ec.OK
    assert ec.check_find_my(mac_env(tmp_path, {sp: (0, "Activation Lock Status: Disabled"), nv: (0, "")}))["verdict"] == ec.OK
    assert ec.check_find_my(mac_env(tmp_path, {sp: (0, "Activation Lock Status: Disabled"), nv: (1, "")}))["verdict"] == ec.RISK
    assert ec.check_find_my(mac_env(tmp_path, {sp: (None, ""), nv: (1, "")}))["verdict"] == ec.CANNOT
    env = mac_env(tmp_path, {sp: (0, ""), nv: (0, "")})
    ec.check_find_my(env)
    assert (nv, True) in env.calls, "the Find My token must be probed exit_only"


def test_firmware_password(tmp_path):
    fp = ("firmwarepasswd", "-check")
    assert ec.check_firmware(mac_env(tmp_path, arch="arm64"))["verdict"] == ec.OK
    assert ec.check_firmware(mac_env(tmp_path, {fp: (0, "Password Enabled: Yes")}, arch="x86_64"))["verdict"] == ec.OK
    assert ec.check_firmware(mac_env(tmp_path, {fp: (0, "Password Enabled: No")}, arch="x86_64"))["verdict"] == ec.RISK
    assert ec.check_firmware(mac_env(tmp_path, {fp: (1, "Must be root")}, arch="x86_64"))["verdict"] == ec.CANNOT


@pytest.mark.parametrize("out,expect", [
    ('Keychain "x" lock-on-sleep timeout=300s\n', ec.OK),
    ('Keychain "x" timeout=900s\n', ec.OK),
    ('Keychain "x" no-timeout\n', ec.RISK),
    ('Keychain "x" timeout=86400s\n', ec.RISK),
])
def test_keychain(tmp_path, out, expect):
    home = tmp_path / "home"
    key = ("security", "show-keychain-info", str(home / "Library/Keychains/login.keychain-db"))
    assert ec.check_keychain(mac_env(tmp_path, {key: (0, out)}))["verdict"] == expect
    assert ec.check_keychain(mac_env(tmp_path, {key: (36, "")}))["verdict"] == ec.CANNOT


def test_sudo(tmp_path):
    env = mac_env(tmp_path)
    pam = tmp_path / "root/etc/pam.d"
    assert ec.check_touch_id_sudo(env)["verdict"] == ec.CANNOT
    (pam / "sudo").write_text("auth required pam_opendirectory.so\n")
    assert ec.check_touch_id_sudo(env)["verdict"] == ec.OK
    (pam / "sudo_local").write_text("# comment\nauth sufficient pam_tid.so\n")
    r = ec.check_touch_id_sudo(env)
    assert r["verdict"] == ec.OK and "Touch ID" in r["found"]
    (pam / "sudo_local").write_text("auth sufficient pam_permit.so\n")
    assert ec.check_touch_id_sudo(env)["verdict"] == ec.RISK
    (pam / "sudo_local").write_text("# auth sufficient pam_permit.so\n")
    assert ec.check_touch_id_sudo(env)["verdict"] == ec.OK


# ── SSH ────────────────────────────────────────────────────────────────────

def test_ssh_keys_red_green_cannot(tmp_path):
    env = mac_env(tmp_path)
    assert ec.check_ssh_keys(env)["verdict"] == ec.OK          # no ~/.ssh
    ssh = env.home / ".ssh"
    ssh.mkdir()
    (ssh / "known_hosts").write_text("example.invalid ssh-ed25519 AAAA\n")
    (ssh / "id_locked").write_bytes(key_openssh(cipher=b"aes256-ctr"))
    (ssh / "id_pem_locked").write_bytes(key_pem(True))
    (ssh / "id_hw").write_bytes(key_openssh(keytype=b"sk-ssh-ed25519@openssh.com"))
    (ssh / "id_locked.pub").write_text("ssh-ed25519 AAAA\n")
    r = ec.check_ssh_keys(env)
    assert r["verdict"] == ec.OK and r["count"] == 3
    (ssh / "id_open").write_bytes(key_openssh())
    (ssh / "id_pem_open").write_bytes(key_pem(False))
    r = ec.check_ssh_keys(env)
    assert r["verdict"] == ec.RISK and r["count"] == 2
    kinds = {l["path"]: l["type"] for l in r["locations"]}
    assert kinds["~/.ssh/id_open"] == "no passphrase"
    assert kinds["~/.ssh/id_pem_open"] == "no passphrase"
    assert kinds["~/.ssh/id_locked"] == "passphrase set"
    assert kinds["~/.ssh/id_hw"] == "hardware key"
    denied = mac_env(tmp_path, denied=(ssh,))
    assert ec.check_ssh_keys(denied)["verdict"] == ec.CANNOT


def test_ssh_agent_forwarding(tmp_path):
    env = mac_env(tmp_path)
    assert ec.check_ssh_agent_forwarding(env)["verdict"] == ec.OK
    cfg = env.home / ".ssh"
    cfg.mkdir()
    (cfg / "config").write_text("Host build\n  ForwardAgent yes\nHost other\n  User x\n")
    assert ec.check_ssh_agent_forwarding(env)["verdict"] == ec.OK         # one trusted host only
    (cfg / "config").write_text("Host *\n  ForwardAgent yes\n")
    assert ec.check_ssh_agent_forwarding(env)["verdict"] == ec.RISK
    (cfg / "config").write_text("ForwardAgent yes\nHost a\n")
    assert ec.check_ssh_agent_forwarding(env)["verdict"] == ec.RISK
    (cfg / "config").write_text("Host *\n  # ForwardAgent yes\n  ForwardAgent no\n")
    assert ec.check_ssh_agent_forwarding(env)["verdict"] == ec.OK


# ── plain-text credentials ─────────────────────────────────────────────────

def test_plaintext_credentials_red_green(tmp_path):
    env = mac_env(tmp_path)
    assert ec.check_plaintext_credentials(env)["verdict"] == ec.OK
    proj = env.home / "Developer/app"
    proj.mkdir(parents=True)
    (proj / ".env.example").write_text("API_KEY=changeme\n")           # template: ignored
    (proj / "token.py").write_text("def token(): pass\n")              # code: ignored
    (proj / "cert.pem").write_text("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n")
    (proj / ".env").write_text("DEBUG=1\nNAME=demo\n")                 # named, but nothing key-shaped
    r = ec.check_plaintext_credentials(env)
    assert r["verdict"] == ec.OK and r["count"] == 2
    (proj / "service_token.json").write_text('{"k": "' + CANARY + '"}')
    (proj / "node_modules").mkdir()
    (proj / "node_modules" / ".env").write_text("K=" + "AKIA" + "ABCDEFGHIJKLMNOP\n")   # skipped dir
    r = ec.check_plaintext_credentials(env)
    assert r["verdict"] == ec.RISK and r["count"] == 1
    assert r["locations"][0]["path"] == "~/Developer/app/service_token.json"
    assert "Stripe live key" in r["locations"][0]["type"]


def test_plaintext_credentials_known_home_files_and_cap(tmp_path, monkeypatch):
    env = mac_env(tmp_path)
    (env.home / ".aws").mkdir()
    (env.home / ".aws/credentials").write_text("[default]\naws_access_key_id = " + "AKIA" + "ABCDEFGHIJKLMNOP\n")
    r = ec.check_plaintext_credentials(env)
    assert r["verdict"] == ec.RISK and r["locations"][0]["path"] == "~/.aws/credentials"
    monkeypatch.setattr(ec, "MAX_FILES_VISITED", 3)
    d = env.home / "Code"
    d.mkdir()
    for i in range(10):
        (d / f"f{i}.txt").write_text("x")
    r = ec.check_plaintext_credentials(env)
    assert r["note"], "hitting the cap must be said out loud"


# ── browsers ───────────────────────────────────────────────────────────────

def make_chrome(home, logins=2, cookies=3, canary=None):
    prof = home / "Library/Application Support/Google/Chrome/Default"
    (prof / "Network").mkdir(parents=True)
    con = sqlite3.connect(prof / "Login Data")
    con.execute("CREATE TABLE logins (origin_url TEXT, username_value TEXT, password_value BLOB)")
    for i in range(logins):
        con.execute("INSERT INTO logins VALUES (?,?,?)", (f"https://site{i}.invalid", "demo", (canary or "x").encode()))
    con.commit(); con.close()
    con = sqlite3.connect(prof / "Network" / "Cookies")
    con.execute("CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB)")
    for i in range(cookies):
        con.execute("INSERT INTO cookies VALUES (?,?,?,?)", ("a.invalid", f"n{i}", canary or "v", (canary or "v").encode()))
    con.commit(); con.close()
    return prof


def test_browsers_red_green_cannot(tmp_path):
    env = mac_env(tmp_path)
    assert ec.check_browsers(env)["verdict"] == ec.OK and "No saved" in ec.check_browsers(env)["found"]
    make_chrome(env.home)
    ok = ec.check_browsers(env, lock_ok=True)
    assert ok["verdict"] == ec.OK and "2 saved login" in ok["locations"][0]["type"]
    assert "3 session cookie" in ok["locations"][0]["type"]
    assert ec.check_browsers(env, lock_ok=False)["verdict"] == ec.RISK
    ff = env.home / "Library/Application Support/Firefox/Profiles/abc.default"
    ff.mkdir(parents=True)
    (ff / "logins.json").write_text(json.dumps({"logins": [{"encryptedPassword": "x"}] * 4}))
    assert ec.check_browsers(env, lock_ok=True)["verdict"] == ec.CANNOT   # primary password unreadable
    safari = mac_env(tmp_path / "s", denied=(tmp_path / "s/home/Library/Containers",))
    assert ec.check_browsers(safari)["verdict"] == ec.CANNOT


def test_browser_queries_are_counts_only():
    src = (AGENT / "exposure_check.py").read_text()
    tree = ast.parse(src)
    doc = ast.get_docstring(tree, clean=False)
    sqls = [n.value for n in ast.walk(tree) if isinstance(n, ast.Constant)
            and isinstance(n.value, str) and n.value != doc and "SELECT" in n.value.upper()]
    assert sqls == ["SELECT COUNT(*) FROM "], sqls
    for col in ("password_value", "encrypted_value", "value FROM"):
        assert col not in src.replace("NO value column", "")


# ── Messages, Mail, banking apps ───────────────────────────────────────────

def test_messages_mail_apps(tmp_path):
    env = mac_env(tmp_path)
    assert ec.check_messages_mail_apps(env)["verdict"] == ec.OK
    (env.home / "Library/Messages").mkdir(parents=True)
    (env.home / "Library/Messages/chat.db").write_bytes(b"")
    app = tmp_path / "root/Applications/Demo Bank.app/Contents"
    app.mkdir(parents=True)
    import plistlib
    (app / "Info.plist").write_bytes(plistlib.dumps({"LSApplicationCategoryType": "public.app-category.finance"}))
    ok = ec.check_messages_mail_apps(env, lock_ok=True)
    assert ok["verdict"] == ec.OK and ok["count"] == 2 and ok["note"]
    assert ec.check_messages_mail_apps(env, lock_ok=False)["verdict"] == ec.RISK
    denied = mac_env(tmp_path / "d", denied=(tmp_path / "d/home/Library/Messages", tmp_path / "d/home/Library/Mail"))
    assert ec.check_messages_mail_apps(denied)["verdict"] == ec.CANNOT


# ── assembly, score, top three ─────────────────────────────────────────────

def test_green_mac_scores_high_and_has_no_fixes(tmp_path):
    r = ec.run_all(mac_env(tmp_path, {("defaults", "read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser"): (1, "")}))
    assert r["score"] == 100 and r["top_fixes"] == []
    assert r["summary"] and r["measured"] == r["total"] - 1       # sudo unreadable in the fake root


def test_red_mac_top_three_are_the_heaviest(tmp_path):
    over = {("fdesetup", "status"): (0, "FileVault is Off."),
            ("sysadminctl", "-screenLock", "status"): (0, "screenLock is off"),
            ("system_profiler", "SPHardwareDataType"): (0, "Activation Lock Status: Disabled"),
            ("nvram", "fmm-mobileme-token-FMM"): (1, "")}
    env = mac_env(tmp_path, over)
    (env.home / ".ssh").mkdir()
    (env.home / ".ssh/id_open").write_bytes(key_openssh())
    r = ec.run_all(env)
    assert [f["id"] for f in r["top_fixes"]] == ["filevault", "ssh_keys", "screen_lock"]
    assert r["score"] < 60 and r["summary"]
    assert all(f["fix"] for f in r["top_fixes"])
    assert by_id(r)["filevault"]["thief"]


def test_score_ignores_unmeasured_and_refuses_when_too_little_is_measured(tmp_path):
    r = ec.run_all(ec.Env(home=tmp_path / "h", system="Linux"))          # a non-Mac: Mac checks CANNOT-CHECK
    assert by_id(r)["filevault"]["verdict"] == ec.CANNOT
    assert r["measured"] < r["total"]
    assert ec._score([{"verdict": ec.CANNOT, "weight": 5}] * 5) == (None, 0)


def test_copy_rules():
    from exposure_check_copy import CHECKS
    import exposure_check_copy as copy
    text = json.dumps([CHECKS, copy.PAGE_LEAD, copy.SUMMARY_WEAK, copy.NO_FIXES])
    assert chr(0x2014) not in text and "recording" not in text.lower()


# ── THE CANARY ─────────────────────────────────────────────────────────────

def plant_everything(env):
    home = env.home
    d = home / "Developer/app"
    d.mkdir(parents=True)
    (d / ".env").write_text(f"STRIPE={CANARY}\n")
    (home / ".aws").mkdir()
    (home / ".aws/credentials").write_text(f"[default]\naws_secret_access_key = {CANARY}\n")
    (home / ".ssh").mkdir()
    # The canary sits in the key body, where real key material would be.
    body = base64.b64encode(b"\x00" * 64 + CANARY.encode() + b"\x00" * 64).decode()
    (home / ".ssh/id_open").write_bytes(
        key_openssh()[:-len(b"-----END OPENSSH PRIVATE KEY-----\n")] + (body + "\n-----END OPENSSH PRIVATE KEY-----\n").encode())
    make_chrome(home, canary=CANARY)
    ff = home / "Library/Application Support/Firefox/Profiles/p.default"
    ff.mkdir(parents=True)
    (ff / "logins.json").write_text(json.dumps({"logins": [{"encryptedPassword": CANARY}]}))
    return [d / ".env", home / ".aws/credentials", home / ".ssh/id_open",
            home / "Library/Application Support/Google/Chrome/Default/Login Data"]


def test_canary_appears_nowhere(tmp_path, caplog, capsys, monkeypatch):
    env = mac_env(tmp_path, {("defaults", "read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser"): (1, "")})
    planted = plant_everything(env)
    # POSITIVE CONTROL 1: the canary really is in the fixture.
    assert any(CANARY.encode() in p.read_bytes() for p in planted)

    state = tmp_path / "state"
    caplog.set_level(logging.DEBUG)
    result = ec.run_all(env)
    ec.save_last(result, state)
    assert ec.load_last(state) == json.loads(json.dumps(result))
    assert oct((state / "last.json").stat().st_mode & 0o777) == "0o600"

    # POSITIVE CONTROL 2: the check really looked and really flagged.
    ids = by_id(result)
    assert ids["plaintext_credentials"]["verdict"] == ec.RISK and ids["plaintext_credentials"]["count"] >= 2
    assert ids["ssh_keys"]["verdict"] == ec.RISK
    assert ids["browsers"]["locations"], "browser profile metadata should be present"

    out = capsys.readouterr()
    haystacks = {
        "result": json.dumps(result),
        "state files": "".join(p.read_text(errors="replace") for p in state.rglob("*") if p.is_file()),
        "log": "\n".join(r.getMessage() + str(r.args) for r in caplog.records),
        "stdout": out.out, "stderr": out.err,
    }
    for name, blob in haystacks.items():
        for needle in (CANARY, CANARY_B64, CANARY_HEX, "CANARYQQQQ"):
            assert needle not in blob, f"canary leaked into {name}"
    assert any(r.name == "exposure_check" for r in caplog.records)   # it did log, just not values


def test_value_bearing_commands_are_exit_only(tmp_path):
    env = mac_env(tmp_path)
    ec.run_all(env)
    exit_only = {argv for argv, eo in env.calls if eo}
    assert ("nvram", "fmm-mobileme-token-FMM") in exit_only
    assert ("defaults", "read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser") in exit_only


def test_shape_detector_returns_labels_never_matches():
    src = (AGENT / "exposure_check.py").read_text()
    tree = ast.parse(src)
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute) and node.attr in ("group", "groups", "groupdict", "findall", "finditer"):
            # .group() is used only on the screenLock / timeout / Activation parsers (non-secret settings).
            assert node.lineno not in range(*_func_span(tree, "_shape_labels"))


def _func_span(tree, name):
    for n in ast.walk(tree):
        if isinstance(n, ast.FunctionDef) and n.name == name:
            return n.lineno, n.end_lineno + 1
    raise AssertionError(name)


def test_real_env_exit_only_returns_no_output():
    env = ec.Env()
    assert env.run(["true"], exit_only=True) == (0, "")
    assert env.run(["false"], exit_only=True) == (1, "")
    assert env.run(["/nonexistent-binary-xyz"]) == (None, "")


# ── no network ─────────────────────────────────────────────────────────────

def test_no_network_module_is_imported():
    banned = {"socket", "urllib", "http", "httpx", "requests", "ssl", "ftplib", "smtplib", "aiohttp", "asyncio"}
    for fname in ("exposure_check.py", "exposure_check_copy.py"):
        tree = ast.parse((AGENT / fname).read_text())
        for n in ast.walk(tree):
            mods = []
            if isinstance(n, ast.Import):
                mods = [a.name for a in n.names]
            elif isinstance(n, ast.ImportFrom):
                mods = [n.module or ""]
            for m in mods:
                root = m.split(".")[0]
                # urllib.parse.quote is string quoting, not a network call.
                if m == "urllib.parse":
                    continue
                assert root not in banned, f"{fname} imports {m}"


def test_a_full_run_survives_a_dead_network(tmp_path, monkeypatch):
    def boom(*a, **k):
        raise AssertionError("network used")
    monkeypatch.setattr(socket.socket, "connect", boom)
    monkeypatch.setattr(socket, "create_connection", boom)
    monkeypatch.setattr(socket, "getaddrinfo", boom)
    env = mac_env(tmp_path)
    plant_everything(env)
    assert ec.run_all(env)["checks"]


# ── flag and routes ────────────────────────────────────────────────────────

def test_flag_is_off_unless_explicitly_true(tmp_path, monkeypatch):
    f = tmp_path / "features.yaml"
    assert not ec.is_feature_enabled(_path=f)
    for body in ("", "features: {}\n", "features:\n  exposure_check: false\n",
                 "features:\n  exposure_check: 'true'\n", ": : bad", "features: 3\n"):
        f.write_text(body)
        assert not ec.is_feature_enabled(_path=f), body
    f.write_text("features:\n  exposure_check: true\n")
    assert ec.is_feature_enabled(_path=f)


@pytest.fixture
def client(tmp_path, monkeypatch):
    pytest.importorskip("fastapi")
    pytest.importorskip("httpx")
    pytest.importorskip("yaml")
    from fastapi.testclient import TestClient
    try:
        import web_ui
    except Exception as exc:  # pragma: no cover
        pytest.skip(f"web_ui not importable here: {exc}")
    monkeypatch.setenv("OSTLER_DIR", str(tmp_path / "ostler"))
    monkeypatch.setenv("OSTLER_FEATURES_FILE", str(tmp_path / "features.yaml"))
    env = mac_env(tmp_path)
    real = ec.run_all
    monkeypatch.setattr(ec, "run_all", lambda e=None: real(env))
    return TestClient(web_ui.app), tmp_path


HUB = {"host": "127.0.0.1:8089"}


def test_routes_are_404_while_the_flag_is_off(client):
    c, _ = client
    assert c.get("/doctor/exposure", headers=HUB).status_code == 404
    assert c.get("/api/v1/exposure-check", headers=HUB).status_code == 404
    assert c.post("/api/v1/exposure-check/run", headers=HUB).status_code == 404


def test_routes_run_on_demand_when_the_flag_is_on(client):
    c, tmp = client
    (tmp / "features.yaml").write_text("features:\n  exposure_check: true\n")
    page = c.get("/doctor/exposure", headers=HUB)
    assert page.status_code == 200 and "If this Mac were taken" in page.text
    assert "recording" not in page.text.lower() and chr(0x2014) not in page.text
    assert c.get("/api/v1/exposure-check", headers=HUB).json() is None          # never run yet
    run = c.post("/api/v1/exposure-check/run", headers=HUB)
    assert run.status_code == 200 and run.json()["score"] == 100
    assert c.get("/api/v1/exposure-check", headers=HUB).json()["score"] == 100  # now saved
    assert (tmp / "ostler/exposure-check/last.json").is_file()


def test_run_refuses_cross_site_and_non_loopback(client):
    c, tmp = client
    (tmp / "features.yaml").write_text("features:\n  exposure_check: true\n")
    assert c.post("/api/v1/exposure-check/run", headers={**HUB, "sec-fetch-site": "cross-site"}).status_code == 403
    assert c.post("/api/v1/exposure-check/run", headers={**HUB, "origin": "https://evil.invalid"}).status_code == 403
    assert c.post("/api/v1/exposure-check/run", headers={"host": "hub.example.invalid"}).status_code == 403
    assert c.get("/doctor/exposure", headers={"host": "hub.example.invalid"}).status_code == 403
