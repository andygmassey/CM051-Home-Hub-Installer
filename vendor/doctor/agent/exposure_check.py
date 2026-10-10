"""If this Mac were taken: a local, metadata-only exposure check (Lane 30).

QUESTION: "If someone stole this Mac right now, what could they take over in
ten minutes?"

THE ABSOLUTE RULE. This module COUNTS and LOCATES. It never returns, prints,
logs, stores or transmits a secret VALUE: no key material, no token text, no
cookie values, no passwords. How that is held structurally, not by promise:

  * Every probe returns a verdict, a count and a list of {path, type} pairs.
    No probe has a code path that returns file content.
  * Secret-shape detection (``_shape_labels``) reads a file into a local
    variable, asks "does a provider-shaped string occur", and returns ONLY
    the label of the shape. It never calls ``.group()`` and never keeps a
    match object, so there is nothing to leak even by accident.
  * Commands whose output could carry a value (``nvram``, ``defaults read
    autoLoginUser``) are run with ``exit_only=True``: stdout goes to
    /dev/null and only the exit status is seen.
  * Browser databases are opened read-only and ONLY ``SELECT COUNT(*)`` is
    ever issued. No value column is named anywhere in this file.
  * SSH key classification reads the first 512 bytes (header and, for the
    OpenSSH format, the cipher and key-type fields, which are public
    metadata) and returns a three-way label. Key material starts after that.

NO NETWORK. The imports below are stdlib and local-only. The test suite
asserts no network module is imported and that a socket connect would raise.

NO TELEMETRY. Results are kept at ``~/.ostler/exposure-check/last.json``
(mode 0600) so the Doctor page can show the last run. Logging emits only a
check id and a verdict.

Sibling of ``ostler_security/filevault.py`` (``check_filevault_status``),
which this does not import: that helper keeps ``fdesetup`` raw output in its
result, this one keeps nothing but the verdict.

Feature flag: ``features.exposure_check`` in ``features.yaml``. OFF unless
explicitly ``true``. See ``is_feature_enabled``.
"""
from __future__ import annotations

import base64
import json
import logging
import os
import platform
import plistlib
import re
import sqlite3
import struct
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional
from urllib.parse import quote as _urlquote

from exposure_check_copy import CHECKS as C, SUMMARY_FAIR, SUMMARY_STRONG, SUMMARY_WEAK

logger = logging.getLogger("exposure_check")

OK = "OK"
RISK = "risk"
CANNOT = "CANNOT-CHECK"

SCHEMA = 1
FEATURE_KEY = "exposure_check"

# Search caps. A thief question must answer in seconds, not hang a Doctor
# worker on a huge home folder.
MAX_FILES_VISITED = 30000
MAX_DEPTH = 5
MAX_SECONDS = 8.0
MAX_CONTENT_BYTES = 65536
MAX_SCAN_FILE_SIZE = 1024 * 1024
MAX_LOCATIONS = 20
MAX_SSH_ENTRIES = 200

DEV_FOLDERS = (
    "Developer", "Projects", "Code", "code", "src", "dev", "repos", "work",
    "git", "GitHub", "workspace", "Sites",
)
SKIP_DIRS = frozenset({
    "Library", "node_modules", ".git", ".cache", "Caches", "caches", ".venv",
    "venv", "__pycache__", ".Trash", "Pods", "DerivedData", "build", "dist",
    "target", "site-packages", ".tox", ".gradle", ".npm", ".cargo",
})
# Well-known single files in the home folder, checked by name only.
KNOWN_HOME_FILES = (
    (".env", "env file"),
    (".aws/credentials", "AWS credentials file"),
    (".netrc", "netrc file"),
    (".npmrc", "npm config"),
    (".pypirc", "PyPI config"),
    (".git-credentials", "git credentials file"),
)
CODE_EXTS = frozenset({
    ".py", ".js", ".ts", ".tsx", ".jsx", ".swift", ".go", ".rs", ".java", ".kt",
    ".c", ".h", ".cpp", ".rb", ".php", ".md", ".html", ".css", ".sh", ".cs",
    ".m", ".mm", ".lock", ".pyc", ".map", ".log", ".rst", ".svg",
})
ENV_TEMPLATE_SUFFIXES = (".example", ".sample", ".template", ".dist", ".tmpl", ".defaults")

# Provider-prefix SHAPES. Matching is "does this occur", never "what is it".
_SHAPES = (
    ("AWS access key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("GitHub token", re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}")),
    ("GitHub fine-grained token", re.compile(r"github_pat_[A-Za-z0-9_]{30,}")),
    ("Stripe live key", re.compile(r"[sr]k_live_[A-Za-z0-9]{16,}")),
    ("Slack token", re.compile(r"xox[abprs]-[A-Za-z0-9-]{10,}")),
    ("Anthropic key", re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}")),
    ("OpenAI key", re.compile(r"sk-(?:proj-)?[A-Za-z0-9_-]{32,}")),
    ("Google API key", re.compile(r"AIza[0-9A-Za-z_-]{35}")),
    ("private key block", re.compile(r"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----")),
    ("JSON web token", re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")),
    ("AWS secret assignment", re.compile(r"aws_secret_access_key\s*[=:]\s*\S{20,}", re.I)),
    ("netrc password entry", re.compile(r"\bpassword\s+\S{4,}")),
    ("npm auth token", re.compile(r"_authToken\s*=\s*\S{8,}")),
    ("URL with embedded password", re.compile(r"https?://[^/\s:@]+:[^/\s@]{3,}@")),
)


# ── environment seam ───────────────────────────────────────────────────────

class Env:
    """Everything the checks touch, in one place, so tests inject a fixture.

    ``run`` returns ``(returncode, text)``; ``returncode`` is None when the
    command is missing or timed out. With ``exit_only`` stdout and stderr go
    to /dev/null and ``text`` is always empty.
    """

    def __init__(self, home: Optional[Path] = None, system: Optional[str] = None,
                 arch: Optional[str] = None, root: Optional[Path] = None,
                 denied: tuple = ()):
        self.home = Path(home) if home else Path.home()
        self.system = system or platform.system()
        self.arch = arch or platform.machine()
        self.root = Path(root) if root else Path("/")
        # Test hook for Full Disk Access: paths under these raise PermissionError.
        self.denied = tuple(Path(d) for d in denied)

    def guard(self, path: Path) -> None:
        for d in self.denied:
            if path == d or d in path.parents:
                raise PermissionError(str(path))

    @property
    def is_mac(self) -> bool:
        return self.system == "Darwin"

    def etc(self, rel: str) -> Path:
        return self.root / rel.lstrip("/")

    def run(self, argv, exit_only: bool = False, timeout: float = 8.0):
        try:
            res = subprocess.run(
                list(argv),
                stdout=subprocess.DEVNULL if exit_only else subprocess.PIPE,
                stderr=subprocess.DEVNULL if exit_only else subprocess.STDOUT,
                timeout=timeout,
                env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return None, ""
        if exit_only:
            return res.returncode, ""
        return res.returncode, (res.stdout or b"").decode("utf-8", "replace")[:8192]


def _tilde(env: Env, p: Path) -> str:
    try:
        return "~/" + p.relative_to(env.home).as_posix()
    except ValueError:
        return p.as_posix()


def _result(cid: str, verdict: str, weight: int, found: str, *, count: int = 0,
            locations=None, note: str = "") -> dict:
    cp = C[cid]
    out = {
        "id": cid,
        "title": cp["title"],
        "verdict": verdict,
        "weight": weight,
        "found": found,
        "count": count,
        "locations": list(locations or [])[:MAX_LOCATIONS],
        "thief": cp["thief"] if verdict == RISK else "",
        "fix": cp["fix"] if verdict == RISK else "",
        "note": note,
    }
    logger.info("exposure_check %s %s", cid, verdict)
    return out


def _needs_mac(env: Env, cid: str, weight: int):
    if env.is_mac:
        return None
    return _result(cid, CANNOT, weight, C[cid]["cannot"] + " It needs a Mac.")


# ── system settings ────────────────────────────────────────────────────────

def check_filevault(env: Env) -> dict:
    w = 10
    if (r := _needs_mac(env, "filevault", w)):
        return r
    rc, text = env.run(["fdesetup", "status"])
    if rc is not None and "FileVault is On" in text:
        return _result("filevault", OK, w, C["filevault"]["ok"])
    if rc is not None and "FileVault is Off" in text:
        return _result("filevault", RISK, w, C["filevault"]["risk"])
    return _result("filevault", CANNOT, w, C["filevault"]["cannot"])


_SCREENLOCK_DELAY = re.compile(r"screenLock delay is (\w+)(?: seconds)?", re.I)
_SCREENLOCK_OFF = re.compile(r"screenLock is off", re.I)


def check_screen_lock(env: Env) -> dict:
    w = 8
    cp = C["screen_lock"]
    if (r := _needs_mac(env, "screen_lock", w)):
        return r
    rc, text = env.run(["sysadminctl", "-screenLock", "status"])
    if rc is not None:
        if _SCREENLOCK_OFF.search(text):
            return _result("screen_lock", RISK, w, cp["risk_off"])
        m = _SCREENLOCK_DELAY.search(text)
        if m:
            token = m.group(1).lower()
            if token == "immediate":
                return _result("screen_lock", OK, w, cp["ok"])
            if token.isdigit():
                n = int(token)
                if n <= 5:
                    return _result("screen_lock", OK, w, cp["ok"])
                return _result("screen_lock", RISK, w, cp["risk_delay"].format(n=n))
    # Older macOS: the screensaver preference pair.
    rc1, ask = env.run(["defaults", "read", "com.apple.screensaver", "askForPassword"])
    rc2, delay = env.run(["defaults", "read", "com.apple.screensaver", "askForPasswordDelay"])
    if rc1 == 0 and ask.strip() in ("0", "1"):
        if ask.strip() == "0":
            return _result("screen_lock", RISK, w, cp["risk_off"])
        d = delay.strip() if rc2 == 0 else "0"
        if d.isdigit():
            if int(d) <= 5:
                return _result("screen_lock", OK, w, cp["ok"])
            return _result("screen_lock", RISK, w, cp["risk_delay"].format(n=int(d)))
    return _result("screen_lock", CANNOT, w, cp["cannot"])


def check_auto_login(env: Env) -> dict:
    w = 8
    cp = C["auto_login"]
    if (r := _needs_mac(env, "auto_login", w)):
        return r
    # exit_only: the user name is never read.
    rc, _ = env.run(["defaults", "read", "/Library/Preferences/com.apple.loginwindow",
                     "autoLoginUser"], exit_only=True)
    kc = env.etc("/etc/kcpassword")
    try:
        kc_present = kc.exists()  # existence only; the file is never opened
    except OSError:
        kc_present = False
    if rc == 0:
        return _result("auto_login", RISK, w, cp["risk"])
    if kc_present:
        return _result("auto_login", RISK, w, cp["risk_file"], locations=[{"path": "/etc/kcpassword", "type": "login password file"}])
    if rc is None:
        return _result("auto_login", CANNOT, w, cp["cannot"])
    return _result("auto_login", OK, w, cp["ok"])


def check_find_my(env: Env) -> dict:
    w = 4
    cp = C["find_my"]
    if (r := _needs_mac(env, "find_my", w)):
        return r
    rc_sp, sp = env.run(["system_profiler", "SPHardwareDataType"], timeout=20.0)
    al = None
    if rc_sp is not None:
        m = re.search(r"Activation Lock Status:\s*(Enabled|Disabled)", sp)
        al = m.group(1) if m else None
    # exit_only: the Find My token value is never read, only whether it exists.
    rc_nv, _ = env.run(["nvram", "fmm-mobileme-token-FMM"], exit_only=True)
    if al == "Enabled" or rc_nv == 0:
        return _result("find_my", OK, w, cp["ok"])
    if al == "Disabled" and rc_nv is not None:
        return _result("find_my", RISK, w, cp["risk"])
    return _result("find_my", CANNOT, w, cp["cannot"])


def check_firmware(env: Env) -> dict:
    w = 2
    cp = C["firmware"]
    if (r := _needs_mac(env, "firmware", w)):
        return r
    if env.arch.lower() in ("arm64", "aarch64"):
        return _result("firmware", OK, w, cp["ok_na"])
    rc, text = env.run(["firmwarepasswd", "-check"])
    if rc is not None:
        if re.search(r"Password Enabled:\s*Yes", text):
            return _result("firmware", OK, w, cp["ok"])
        if re.search(r"Password Enabled:\s*No", text):
            return _result("firmware", RISK, w, cp["risk"])
    return _result("firmware", CANNOT, w, cp["cannot"])


# ── SSH ────────────────────────────────────────────────────────────────────

def _lp(buf: bytes, off: int):
    """Read an SSH length-prefixed string. Returns (bytes, next_off) or None."""
    if off + 4 > len(buf):
        return None
    (n,) = struct.unpack(">I", buf[off:off + 4])
    if off + 4 + n > len(buf):
        return None
    return buf[off + 4:off + 4 + n], off + 4 + n


def _classify_private_key(head: bytes) -> Optional[str]:
    """Classify from the first bytes only. Returns None (not a private key),
    "open", "locked" or "hardware". Never returns any of ``head``."""
    text = head.decode("latin-1")
    first = text.split("\n", 1)[0].strip()
    if not first.startswith("-----BEGIN ") or "PRIVATE KEY" not in first:
        return None
    if "OPENSSH PRIVATE KEY" in first:
        body = "".join(text.split("\n")[1:]).replace("\r", "")
        body = re.sub(r"[^A-Za-z0-9+/]", "", body.split("-----")[0])
        body = body[: len(body) // 4 * 4]
        try:
            raw = base64.b64decode(body)
        except Exception:  # noqa: BLE001
            return None
        magic = b"openssh-key-v1\x00"
        if not raw.startswith(magic):
            return None
        off = len(magic)
        cipher = _lp(raw, off)
        if cipher is None:
            return None
        if cipher[0] != b"none":
            return "locked"
        # kdfname, kdfoptions, nkeys, then the public blob (keytype first).
        kdf = _lp(raw, cipher[1])
        opts = _lp(raw, kdf[1]) if kdf else None
        if not opts or opts[1] + 4 > len(raw):
            return "open"
        pub = _lp(raw, opts[1] + 4)
        keytype = _lp(pub[0], 0) if pub else None
        if keytype and keytype[0].startswith(b"sk-"):
            return "hardware"
        return "open"
    if "ENCRYPTED PRIVATE KEY" in first:
        return "locked"
    # Legacy PEM: an encrypted key carries a "Proc-Type: 4,ENCRYPTED" header.
    if "Proc-Type: 4,ENCRYPTED" in text:
        return "locked"
    return "open"


def check_ssh_keys(env: Env) -> dict:
    w = 9
    cp = C["ssh_keys"]
    ssh = env.home / ".ssh"
    try:
        env.guard(ssh)
        if not ssh.is_dir():
            return _result("ssh_keys", OK, w, cp["ok_none"])
        entries = sorted(ssh.iterdir())[:MAX_SSH_ENTRIES]
    except OSError:
        return _result("ssh_keys", CANNOT, w, cp["cannot"])
    locs, bad, total = [], 0, 0
    for p in entries:
        if p.suffix == ".pub" or p.is_symlink() or not p.is_file():
            continue
        try:
            if p.stat().st_size > 65536:
                continue
            with open(p, "rb") as fh:
                head = fh.read(512)
        except OSError:
            continue
        kind = _classify_private_key(head)
        del head
        if kind is None:
            continue
        total += 1
        label = {"open": cp["type_open"], "locked": cp["type_locked"], "hardware": cp["type_hw"]}[kind]
        if kind == "open":
            bad += 1
        locs.append({"path": _tilde(env, p), "type": label})
    if total == 0:
        return _result("ssh_keys", OK, w, cp["ok_none"])
    if bad:
        locs.sort(key=lambda l: l["type"] != cp["type_open"])
        return _result("ssh_keys", RISK, w, cp["risk"].format(bad=bad, n=total), count=bad, locations=locs)
    return _result("ssh_keys", OK, w, cp["ok"].format(n=total), count=total, locations=locs)


def check_ssh_agent_forwarding(env: Env) -> dict:
    w = 3
    cp = C["ssh_agent_forwarding"]
    cfg = env.home / ".ssh" / "config"
    try:
        env.guard(cfg)
        if not cfg.is_file():
            return _result("ssh_agent_forwarding", OK, w, cp["ok"])
        lines = cfg.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return _result("ssh_agent_forwarding", CANNOT, w, cp["cannot"])
    scope_all = True  # directives before any Host line apply to every host
    hit = False
    for raw in lines:
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        key, _, rest = line.partition(" ")
        key = key.lower().rstrip("=")
        if key == "host":
            pats = rest.replace("=", " ").split()
            scope_all = "*" in pats
        elif key == "match":
            scope_all = "all" in rest.lower().split()
        elif key == "forwardagent" and scope_all:
            val = rest.replace("=", " ").split()
            if val and val[0].lower() == "yes":
                hit = True
    if hit:
        return _result("ssh_agent_forwarding", RISK, w, cp["risk"], count=1,
                       locations=[{"path": _tilde(env, cfg), "type": cp["type_all"]}])
    return _result("ssh_agent_forwarding", OK, w, cp["ok"])


# ── plain-text credentials ─────────────────────────────────────────────────

def _shape_labels(path: Path) -> list:
    """Return the LABELS of the secret shapes found in a file. Never a match."""
    try:
        if path.stat().st_size > MAX_SCAN_FILE_SIZE:
            return []
        with open(path, "rb") as fh:
            blob = fh.read(MAX_CONTENT_BYTES).decode("latin-1")
    except OSError:
        return []
    labels = [label for label, rx in _SHAPES if rx.search(blob)]
    del blob
    return labels


def _name_kind(name: str) -> Optional[str]:
    low = name.lower()
    ext = os.path.splitext(low)[1]
    if low == ".env" or (low.startswith(".env.") and not low.endswith(ENV_TEMPLATE_SUFFIXES)):
        return "env file"
    if ext == ".pem":
        return "PEM file"
    if ext in CODE_EXTS:
        return None
    if "credentials" in low:
        return "credentials file"
    if "token" in low:
        return "token file"
    return None


def check_plaintext_credentials(env: Env) -> dict:
    w = 8
    cp = C["plaintext_credentials"]
    home = env.home
    started = time.monotonic()
    visited, truncated = 0, False
    found = []  # (path, kind, shapes)

    def consider(p: Path, kind: str):
        found.append((p, kind, _shape_labels(p)))

    for rel, kind in KNOWN_HOME_FILES:
        p = home / rel
        try:
            env.guard(p)
            if p.is_file():
                consider(p, kind)
        except OSError:
            continue

    for folder in DEV_FOLDERS:
        base = home / folder
        try:
            env.guard(base)
            if not base.is_dir():
                continue
        except OSError:
            continue
        base_depth = len(base.parts)
        for dirpath, dirnames, filenames in os.walk(base, followlinks=False):
            if len(Path(dirpath).parts) - base_depth >= MAX_DEPTH:
                dirnames[:] = []
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for fn in filenames:
                visited += 1
                if visited > MAX_FILES_VISITED or time.monotonic() - started > MAX_SECONDS:
                    truncated = True
                    break
                kind = _name_kind(fn)
                if kind:
                    p = Path(dirpath) / fn
                    if not p.is_symlink():
                        consider(p, kind)
            if truncated:
                break
        if truncated:
            break

    flagged = [(p, k, s) for p, k, s in found if s]
    # A bare PEM that is only a certificate has no private-key shape: counted, not flagged.
    locs = [{"path": _tilde(env, p), "type": f"{k}, looks like {s[0]}"} for p, k, s in flagged]
    note = cp["note_truncated"] if truncated else ""
    if flagged:
        return _result("plaintext_credentials", RISK, w,
                       cp["risk"].format(bad=len(flagged), n=len(found)),
                       count=len(flagged), locations=locs, note=note)
    if found:
        plain = [{"path": _tilde(env, p), "type": k} for p, k, _ in found]
        return _result("plaintext_credentials", OK, w, cp["ok"].format(n=len(found)),
                       count=len(found), locations=plain, note=note)
    return _result("plaintext_credentials", OK, w, cp["ok_none"], note=note)


# ── browsers ───────────────────────────────────────────────────────────────

_CHROMIUM = (
    ("Chrome", "Library/Application Support/Google/Chrome"),
    ("Brave", "Library/Application Support/BraveSoftware/Brave-Browser"),
    ("Edge", "Library/Application Support/Microsoft Edge"),
    ("Arc", "Library/Application Support/Arc/User Data"),
    ("Vivaldi", "Library/Application Support/Vivaldi"),
)
_SAFARI_COOKIES = "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"


def _count_rows(db: Path, table: str) -> Optional[int]:
    """Row COUNT of a fixed table. This is the ONLY query ever issued against
    a browser database; no value column is named anywhere in this module."""
    if table not in ("logins", "cookies"):
        raise ValueError("unsupported table")
    uri = "file:" + _urlquote(str(db)) + "?mode=ro&immutable=1"
    try:
        con = sqlite3.connect(uri, uri=True, timeout=1.0)
        try:
            row = con.execute("SELECT COUNT(*) FROM " + table).fetchone()
        finally:
            con.close()
        return int(row[0])
    except (sqlite3.Error, OSError, ValueError, TypeError):
        return None


def check_browsers(env: Env, lock_ok: bool = True) -> dict:
    w = 5
    cp = C["browsers"]
    locs, any_data, firefox_logins, safari_denied = [], False, 0, False
    for name, rel in _CHROMIUM:
        root = env.home / rel
        try:
            env.guard(root)
            if not root.is_dir():
                continue
            profiles = [d for d in sorted(root.iterdir())
                        if d.is_dir() and (d.name == "Default" or d.name.startswith("Profile "))]
        except OSError:
            continue
        for prof in profiles:
            logins = _count_rows(prof / "Login Data", "logins") if (prof / "Login Data").is_file() else None
            cookie_db = prof / "Network" / "Cookies"
            if not cookie_db.is_file():
                cookie_db = prof / "Cookies"
            cookies = _count_rows(cookie_db, "cookies") if cookie_db.is_file() else None
            parts = []
            if logins:
                parts.append(cp["type_logins"].format(n=logins))
            if cookies:
                parts.append(cp["type_sessions"].format(n=cookies))
            if parts:
                any_data = True
                locs.append({"path": _tilde(env, prof), "type": f"{name}: " + ", ".join(parts) + f", {cp['type_no_primary']}"})
    ff_root = env.home / "Library/Application Support/Firefox/Profiles"
    try:
        env.guard(ff_root)
        if ff_root.is_dir():
            for prof in sorted(ff_root.iterdir()):
                lj = prof / "logins.json"
                if lj.is_file():
                    try:
                        n = len(json.loads(lj.read_text(encoding="utf-8")).get("logins", []))
                    except (OSError, ValueError, AttributeError):
                        n = 0
                    if n:
                        firefox_logins += n
                        any_data = True
                        locs.append({"path": _tilde(env, prof), "type": f"Firefox: {cp['type_logins'].format(n=n)}"})
    except OSError:
        pass
    sc = env.home / _SAFARI_COOKIES
    try:
        env.guard(sc)
        if sc.is_file() and sc.stat().st_size > 0:
            any_data = True
            locs.append({"path": _tilde(env, sc), "type": "Safari: session data present"})
    except PermissionError:
        safari_denied = True
    except OSError:
        pass
    if any_data and not lock_ok:
        return _result("browsers", RISK, w, cp["risk"], count=len(locs), locations=locs)
    if firefox_logins:
        return _result("browsers", CANNOT, w, cp["cannot_firefox"], count=len(locs), locations=locs)
    if any_data:
        return _result("browsers", OK, w, cp["ok"], count=len(locs), locations=locs)
    if safari_denied:
        return _result("browsers", CANNOT, w, cp["cannot_safari"])
    return _result("browsers", OK, w, cp["ok_none"])


# ── Keychain ───────────────────────────────────────────────────────────────

def check_keychain(env: Env) -> dict:
    w = 6
    cp = C["keychain"]
    if (r := _needs_mac(env, "keychain", w)):
        return r
    kc = env.home / "Library/Keychains/login.keychain-db"
    rc, text = env.run(["security", "show-keychain-info", str(kc)])
    if rc is None or rc != 0:
        return _result("keychain", CANNOT, w, cp["cannot"])
    lock_on_sleep = "lock-on-sleep" in text
    m = re.search(r"timeout=(\d+)s", text)
    timeout = int(m.group(1)) if m else None
    del text
    if lock_on_sleep or (timeout is not None and timeout <= 3600):
        return _result("keychain", OK, w, cp["ok"])
    return _result("keychain", RISK, w, cp["risk"])


# ── Messages, Mail, banking apps ───────────────────────────────────────────

def _finance_apps(env: Env) -> list:
    out = []
    for base in (env.root / "Applications", env.home / "Applications"):
        try:
            apps = sorted(base.glob("*.app"))[:400]
        except OSError:
            continue
        for app in apps:
            try:
                with open(app / "Contents" / "Info.plist", "rb") as fh:
                    cat = plistlib.load(fh).get("LSApplicationCategoryType")
            except Exception:  # noqa: BLE001 - an unreadable plist is simply not counted
                continue
            if cat == "public.app-category.finance":
                out.append(app)
    return out


def check_messages_mail_apps(env: Env, lock_ok: bool = True) -> dict:
    w = 4
    cp = C["messages_mail_apps"]
    locs, denied, present = [], 0, 0
    for path, label in ((env.home / "Library/Messages/chat.db", cp["type_messages"]),
                        (env.home / "Library/Mail", cp["type_mail"])):
        try:
            env.guard(path)
            if path.exists():  # existence and size only; never opened
                present += 1
                locs.append({"path": _tilde(env, path), "type": label})
        except PermissionError:
            denied += 1
        except OSError:
            pass
    for app in _finance_apps(env):
        present += 1
        locs.append({"path": _tilde(env, app) if env.home in app.parents else app.as_posix(),
                     "type": cp["type_finance"]})
    note = cp["note_inapp"]
    if present and not lock_ok:
        return _result("messages_mail_apps", RISK, w, cp["risk"], count=present, locations=locs, note=note)
    if denied and not present:
        return _result("messages_mail_apps", CANNOT, w, cp["cannot"], note=note)
    return _result("messages_mail_apps", OK, w, cp["ok"], count=present, locations=locs, note=note)


def _active_lines(path: Path) -> Optional[list]:
    try:
        return [l.split("#", 1)[0].strip() for l in path.read_text(encoding="utf-8", errors="replace").splitlines()
                if l.split("#", 1)[0].strip()]
    except OSError:
        return None


def check_touch_id_sudo(env: Env) -> dict:
    w = 3
    cp = C["touch_id_sudo"]
    pam = [_active_lines(env.etc("/etc/pam.d/sudo_local")), _active_lines(env.etc("/etc/pam.d/sudo"))]
    if all(x is None for x in pam):
        return _result("touch_id_sudo", CANNOT, w, cp["cannot"])
    lines = [l for x in pam if x for l in x]
    # NOPASSWD in sudoers.d, where the account can read it (usually it cannot).
    nopass = False
    try:
        for f in sorted(env.etc("/etc/sudoers.d").glob("*")):
            ls = _active_lines(f) or []
            nopass = nopass or any("NOPASSWD" in l for l in ls)
    except OSError:
        pass
    passwordless = nopass or any(l.startswith("auth") and "pam_permit.so" in l and "sufficient" in l for l in lines)
    if passwordless:
        return _result("touch_id_sudo", RISK, w, cp["risk"])
    if any("pam_tid.so" in l for l in lines):
        return _result("touch_id_sudo", OK, w, cp["ok_tid"])
    return _result("touch_id_sudo", OK, w, cp["ok"])


# ── assembly ───────────────────────────────────────────────────────────────

def _score(checks: list) -> tuple:
    measured = [c for c in checks if c["verdict"] != CANNOT]
    possible = sum(c["weight"] for c in measured)
    if not measured or len(measured) < 3 or possible == 0:
        return None, len(measured)
    earned = sum(c["weight"] for c in measured if c["verdict"] == OK)
    return round(100 * earned / possible), len(measured)


def run_all(env: Optional[Env] = None) -> dict:
    env = env or Env()
    sl = check_screen_lock(env)
    fv = check_filevault(env)
    al = check_auto_login(env)
    # Browsers and the app check turn into a risk only when the Mac does not
    # lock promptly, so they read the verdicts above.
    lock_ok = sl["verdict"] == OK and al["verdict"] != RISK and fv["verdict"] != RISK
    checks = [
        fv, sl, al,
        check_find_my(env), check_firmware(env),
        check_ssh_keys(env), check_ssh_agent_forwarding(env),
        check_plaintext_credentials(env),
        check_browsers(env, lock_ok=lock_ok),
        check_keychain(env),
        check_messages_mail_apps(env, lock_ok=lock_ok),
        check_touch_id_sudo(env),
    ]
    score, measured = _score(checks)
    risks = sorted((c for c in checks if c["verdict"] == RISK), key=lambda c: -c["weight"])
    top = [{"id": c["id"], "title": c["title"], "fix": c["fix"]} for c in risks[:3]]
    if score is None:
        summary = ""
    elif score >= 90:
        summary = SUMMARY_STRONG
    elif score >= 60:
        summary = SUMMARY_FAIR
    else:
        summary = SUMMARY_WEAK
    return {
        "schema": SCHEMA,
        "ran_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "platform": env.system,
        "score": score,
        "measured": measured,
        "total": len(checks),
        "summary": summary,
        "top_fixes": top,
        "checks": checks,
    }


# ── state and feature flag ─────────────────────────────────────────────────

def _state_dir() -> Path:
    root = Path(os.environ.get("OSTLER_DIR", str(Path.home() / ".ostler")))
    return root / "exposure-check"


def save_last(result: dict, state_dir: Optional[Path] = None) -> None:
    d = state_dir or _state_dir()
    d.mkdir(parents=True, exist_ok=True)
    tmp = d / "last.json.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2)
    os.replace(tmp, d / "last.json")


def load_last(state_dir: Optional[Path] = None) -> Optional[dict]:
    try:
        return json.loads(((state_dir or _state_dir()) / "last.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def _features_file() -> Path:
    raw = os.environ.get("OSTLER_FEATURES_FILE")
    return Path(raw) if raw else Path.home() / ".ostler" / "config" / "features.yaml"


def is_feature_enabled(*, _path: Optional[Path] = None) -> bool:
    """True only when ``features.exposure_check: true``. Missing file, bad
    YAML, missing key or any other value is OFF."""
    path = _path or _features_file()
    try:
        import yaml
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001 - every failure is OFF
        return False
    features = data.get("features") if isinstance(data, dict) else None
    return isinstance(features, dict) and features.get(FEATURE_KEY) is True
