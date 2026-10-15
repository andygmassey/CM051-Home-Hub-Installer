"""The assistant's OWN mailbox (v1.0.108): rules, probes and the Doctor row.

The customer gives their assistant a NEW email account (iCloud recommended,
Gmail supported) and pastes an app-specific password. This module is the one
place that knows:

  * which hosts are allowed for that mailbox (exactly two pairs; Outlook and
    every other host stays refused),
  * what a pasted app password looks like once spaces and dashes are removed,
  * how an IMAP/SMTP failure is explained to a person,
  * how to run the probes (login, SELECT INBOX, SMTP AUTH with no send, a
    self-send with a random token, a hello to the owner),
  * what the Doctor row shows and what its buttons do.

install.sh calls the CLI at the bottom of this file during setup, and the
Doctor imports it, so the install-time check and the "Test now" button can
never disagree. Standard library only, so it is importable and testable alone.

The password lives in the macOS Keychain (service ``SERVICE``, account = the
address). It is never written to config, never logged, never put on a command
line (``security -i`` takes the command on stdin) and never returned by any
function here that feeds the Doctor.
"""
from __future__ import annotations

import imaplib
import json
import os
import re
import secrets
import smtplib
import socket
import ssl
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from email.utils import parsedate_to_datetime
from pathlib import Path

SERVICE = "Ostler Assistant Mailbox"
SECTION = "email_assistant"

# Exactly two accepted hosts pairs. Anything else (Outlook included) is refused
# for the assistant's mailbox. The OWNER's mailbox keeps its own, stricter rule
# in install.sh: no cloud-provider password is ever asked for it.
PROVIDERS = {
    "icloud": {
        "label": "iCloud",
        "imap_host": "imap.mail.me.com", "imap_port": 993,
        "smtp_host": "smtp.mail.me.com", "smtp_port": 587,
        "domains": ("icloud.com", "me.com", "mac.com"),
    },
    "gmail": {
        "label": "Gmail",
        "imap_host": "imap.gmail.com", "imap_port": 993,
        "smtp_host": "smtp.gmail.com", "smtp_port": 465,
        "domains": ("gmail.com", "googlemail.com"),
    },
}

# A "new account" has a small, young inbox. Over either limit we say so and
# make the customer confirm a second time.
INBOX_MAX_MESSAGES = 200
INBOX_MAX_AGE_DAYS = 14

SELFTEST_SECONDS = 60
NETWORK_TIMEOUT = 20

_ADDR_RE = re.compile(r"^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)+$")


# ── Rules ────────────────────────────────────────────────────────────────

def host_pair_allowed(imap_host: str, imap_port, smtp_host: str, smtp_port) -> bool:
    """True only for the two accepted IMAP+SMTP pairs, host and port."""
    try:
        got = (str(imap_host).strip().lower(), int(imap_port),
               str(smtp_host).strip().lower(), int(smtp_port))
    except (TypeError, ValueError):
        return False
    for p in PROVIDERS.values():
        if got == (p["imap_host"], p["imap_port"], p["smtp_host"], p["smtp_port"]):
            return True
    return False


def provider_for_hosts(imap_host: str, smtp_host: str) -> str | None:
    for name, p in PROVIDERS.items():
        if (str(imap_host).lower(), str(smtp_host).lower()) == (p["imap_host"], p["smtp_host"]):
            return name
    return None


def normalise_address(raw: str) -> str:
    return (raw or "").strip().lower()


def address_ok(provider: str, address: str) -> bool:
    """Syntax plus 'is this the provider the customer chose'."""
    a = normalise_address(address)
    p = PROVIDERS.get(provider)
    if not p or not _ADDR_RE.match(a):
        return False
    return a.rsplit("@", 1)[1] in p["domains"]


def is_owner_address(address: str, owner_addresses) -> bool:
    """Refuse the customer's own address: this must be a NEW account."""
    a = normalise_address(address)
    return any(a == normalise_address(o) for o in (owner_addresses or []))


def gmail_identity_ok(username: str, from_address: str) -> bool:
    """Gmail logs in as the address it sends as. A different username means a
    send-as alias or a mistyped account, and replies would not be 'itself'."""
    return normalise_address(username) == normalise_address(from_address)


def clean_password(raw: str) -> str:
    """Strip spaces, dashes and other whitespace from a pasted app password."""
    return re.sub(r"[\s\-‐-―]+", "", raw or "").lower()


def password_format_ok(raw: str) -> bool:
    """Apple and Google app passwords are 16 lower-case letters once the
    spaces/dashes are gone. Used only to decide whether 'Paste from
    clipboard' is offered; the server is the real judge."""
    return re.fullmatch(r"[a-z]{16}", clean_password(raw)) is not None


def inbox_looks_real(message_count: int, oldest_age_days) -> bool:
    if message_count > INBOX_MAX_MESSAGES:
        return True
    return oldest_age_days is not None and oldest_age_days > INBOX_MAX_AGE_DAYS


# ── Plain-English failures ───────────────────────────────────────────────

# code -> (what happened, what to do). British English, no em dashes.
ERRORS = {
    "wrong_password": (
        "The password was not accepted.",
        "Use the app password you just made, not your Apple ID or Google password.",
    ),
    "two_step_off": (
        "This account does not have two-step verification switched on.",
        "App passwords only exist once it is on. Go back one step and switch it on.",
    ),
    "imap_disabled": (
        "Email access is switched off for this account.",
        "Turn on IMAP in the account's mail settings, then try again.",
    ),
    "locked": (
        "The provider has temporarily locked this account.",
        "Wait a few minutes, or sign in to the account in a browser to unlock it.",
    ),
    "network": (
        "Could not check.",
        "Ostler could not reach the provider. Check your internet connection and try again.",
    ),
    "unknown": (
        "Could not check.",
        "The provider gave an answer Ostler does not recognise. Try again in a moment.",
    ),
}


def classify_error(exc_or_text) -> str:
    """Map a provider failure to one of ERRORS' keys."""
    if isinstance(exc_or_text, (socket.timeout, socket.gaierror, ConnectionError,
                                TimeoutError, ssl.SSLError, OSError)) \
            and not isinstance(exc_or_text, (imaplib.IMAP4.error, smtplib.SMTPException)):
        return "network"
    t = (exc_or_text.decode("utf-8", "replace") if isinstance(exc_or_text, bytes)
         else str(exc_or_text)).lower()
    if any(k in t for k in ("two-step", "two step", "two-factor", "2-step", "2sv")):
        return "two_step_off"
    if any(k in t for k in ("imap access is disabled", "imap is disabled", "imap disabled",
                            "web login required", "enable imap", "access disabled",
                            "not enabled for imap")):
        return "imap_disabled"
    if any(k in t for k in ("locked", "too many", "temporarily", "unavailable",
                            "rate limit", "try again later")):
        return "locked"
    if any(k in t for k in ("authenticationfailed", "authentication failed",
                            "invalid credentials", "535", "534", "application-specific",
                            "app-specific", "login failed", "invalid password",
                            "authentication unsuccessful", "not accepted")):
        return "wrong_password"
    if any(k in t for k in ("timed out", "timeout", "name or service", "nodename",
                            "connection", "network", "unreachable", "eof", "ssl")):
        return "network"
    return "unknown"


def explain(code: str) -> str:
    what, todo = ERRORS.get(code, ERRORS["unknown"])
    return f"{what} {todo}"


# ── Probes ───────────────────────────────────────────────────────────────

def _imap(provider: str) -> imaplib.IMAP4_SSL:
    p = PROVIDERS[provider]
    return imaplib.IMAP4_SSL(p["imap_host"], p["imap_port"], timeout=NETWORK_TIMEOUT,
                             ssl_context=ssl.create_default_context())


def _smtp(provider: str) -> smtplib.SMTP:
    p = PROVIDERS[provider]
    ctx = ssl.create_default_context()
    if p["smtp_port"] == 465:
        s = smtplib.SMTP_SSL(p["smtp_host"], p["smtp_port"], timeout=NETWORK_TIMEOUT, context=ctx)
        s.ehlo()
    else:
        s = smtplib.SMTP(p["smtp_host"], p["smtp_port"], timeout=NETWORK_TIMEOUT)
        s.ehlo()
        s.starttls(context=ctx)
        s.ehlo()
    return s


def probe(provider: str, address: str, password: str) -> dict:
    """IMAP login + SELECT INBOX, then SMTP AUTH with nothing sent. Each its
    own result. ``imap``/``smtp`` are 'ok' or an ERRORS key. Also reports the
    inbox size and the age of the oldest message for the 'real inbox' guard."""
    out = {"imap": "skipped", "smtp": "skipped", "inbox_count": 0, "oldest_days": None}
    password = clean_password(password)
    try:
        m = _imap(provider)
        try:
            m.login(address, password)
            typ, data = m.select("INBOX", readonly=True)
            if typ != "OK":
                raise imaplib.IMAP4.error(f"select refused: {data!r}")
            out["inbox_count"] = int(data[0] or 0)
            if out["inbox_count"]:
                typ, d = m.fetch("1", "(INTERNALDATE)")
                if typ == "OK" and d and d[0]:
                    raw = d[0] if isinstance(d[0], bytes) else d[0][0]
                    mt = re.search(rb'INTERNALDATE "([^"]+)"', raw)
                    if mt:
                        when = parsedate_to_datetime(mt.group(1).decode())
                        out["oldest_days"] = max(0, (datetime.now(timezone.utc) - when).days)
            out["imap"] = "ok"
        finally:
            try:
                m.logout()
            except Exception:
                pass
    except Exception as exc:  # noqa: BLE001 - every failure is classified
        out["imap"] = classify_error(exc)
    try:
        s = _smtp(provider)
        try:
            s.login(address, password)
            out["smtp"] = "ok"
        finally:
            try:
                s.quit()
            except Exception:
                pass
    except Exception as exc:  # noqa: BLE001
        out["smtp"] = classify_error(exc)
    return out


def _send(provider, address, password, to, subject, body) -> None:
    msg = EmailMessage()
    msg["From"] = address
    msg["To"] = to
    msg["Subject"] = subject
    msg["Auto-Submitted"] = "auto-generated"
    msg.set_content(body)
    s = _smtp(provider)
    try:
        s.login(address, clean_password(password))
        s.send_message(msg)
    finally:
        try:
            s.quit()
        except Exception:
            pass


def selftest(provider: str, address: str, password: str, seconds: int = SELFTEST_SECONDS) -> dict:
    """Send a message to itself with a random token and wait for it to arrive
    in the INBOX. 'ok' only when the token is seen within ``seconds``."""
    token = secrets.token_hex(8)
    subject = f"Ostler self-test {token}"
    started = time.time()
    try:
        _send(provider, address, password, address, subject,
              "This is an automatic check. You can delete it.")
    except Exception as exc:  # noqa: BLE001
        return {"result": classify_error(exc), "token": token, "seconds": 0}
    deadline = started + seconds
    while time.time() < deadline:
        try:
            m = _imap(provider)
            try:
                m.login(address, clean_password(password))
                m.select("INBOX")
                typ, ids = m.search(None, "SUBJECT", f'"{subject}"')
                if typ == "OK" and ids and ids[0].split():
                    for i in ids[0].split():
                        m.store(i, "+FLAGS", "\\Deleted")
                    m.expunge()
                    return {"result": "ok", "token": token,
                            "seconds": int(time.time() - started)}
            finally:
                try:
                    m.logout()
                except Exception:
                    pass
        except Exception as exc:  # noqa: BLE001
            return {"result": classify_error(exc), "token": token, "seconds": int(time.time() - started)}
        time.sleep(3)
    return {"result": "timeout", "token": token, "seconds": seconds}


def hello_owner(provider: str, address: str, password: str, owner: str, name: str) -> dict:
    """The first message the assistant ever sends: to the owner, as itself."""
    try:
        _send(provider, address, password, owner, f"Hello from {name}",
              f"Hello, this is {name}. Reply with any word to finish setting up.")
        return {"result": "ok"}
    except Exception as exc:  # noqa: BLE001
        return {"result": classify_error(exc)}


# ── Keychain (the only place the password lives) ─────────────────────────

def keychain_store(address: str, password: str) -> bool:
    """Add or update the item. The command goes in on stdin (``security -i``)
    so the password never appears in a process listing."""
    pw = clean_password(password)
    if not re.fullmatch(r"[a-z0-9]{8,64}", pw) or "\n" in address or '"' in address:
        return False
    cmd = f'add-generic-password -U -a "{address}" -s "{SERVICE}" -w "{pw}"\n'
    try:
        r = subprocess.run(["security", "-i"], input=cmd, text=True,
                           capture_output=True, timeout=15)
        return r.returncode == 0
    except Exception:
        return False


def keychain_read(address: str) -> str | None:
    try:
        r = subprocess.run(["security", "find-generic-password", "-a", address,
                            "-s", SERVICE, "-w"], capture_output=True, text=True, timeout=15)
    except Exception:
        return None
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else None


def secret_ref(address: str) -> str:
    return f"keychain:{SERVICE}:{address}"


# ── Config (reads only the non-secret keys) ──────────────────────────────

def _root() -> Path:
    return Path(os.environ.get("OSTLER_DIR", str(Path.home() / ".ostler")))


def config_path() -> Path:
    return Path(os.environ.get("OSTLER_ASSISTANT_CONFIG",
                               str(_root() / "assistant-config" / "config.toml")))


def read_config(path: Path | None = None) -> dict:
    """The ``[email_assistant]`` keys, or {} when absent. Tiny parser: the
    section holds only scalars and one string list, all written by install.sh."""
    p = path or config_path()
    try:
        text = p.read_text(encoding="utf-8")
    except OSError:
        return {}
    cfg: dict = {}
    inside = False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("["):
            inside = s == f"[{SECTION}]"
            continue
        if not inside or not s or s.startswith("#") or "=" not in s:
            continue
        k, v = (x.strip() for x in s.split("=", 1))
        if v.startswith("["):
            cfg[k] = re.findall(r'"([^"]*)"', v)
        elif v.startswith('"'):
            cfg[k] = v.strip('"')
        elif v in ("true", "false"):
            cfg[k] = v == "true"
        else:
            try:
                cfg[k] = int(v)
            except ValueError:
                cfg[k] = v
    return cfg


def set_enabled(enabled: bool, path: Path | None = None) -> bool:
    """Flip ``email_assistant.enabled`` in place. False when there is no section."""
    p = path or config_path()
    try:
        lines = p.read_text(encoding="utf-8").splitlines(keepends=True)
    except OSError:
        return False
    inside, done, out = False, False, []
    for ln in lines:
        s = ln.strip()
        if s.startswith("["):
            inside = s == f"[{SECTION}]"
        if inside and re.match(r"enabled\s*=", s):
            ln = f"enabled = {'true' if enabled else 'false'}\n"
            done = True
        out.append(ln)
    if done:
        p.write_text("".join(out), encoding="utf-8")
    return done


# ── The Doctor row ───────────────────────────────────────────────────────

def _state_dir() -> Path:
    return Path(os.environ.get("OSTLER_STATE_DIR", str(_root() / "state")))


def _load(path: Path) -> dict:
    try:
        d = json.loads(path.read_text(encoding="utf-8"))
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def _age(iso) -> str | None:
    if not iso:
        return None
    try:
        when = datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
        if when.tzinfo is None:
            when = when.replace(tzinfo=timezone.utc)
    except ValueError:
        return None
    secs = int((datetime.now(timezone.utc) - when).total_seconds())
    if secs < 90:
        return "just now"
    if secs < 3600:
        return f"{secs // 60} min ago"
    if secs < 172800:
        return f"{secs // 3600} h ago"
    return f"{secs // 86400} days ago"


def read_row(config: Path | None = None, state_dir: Path | None = None) -> dict:
    """What the Doctor shows. Never contains the password, nor the secret
    reference's account part beyond the address already shown."""
    cfg = read_config(config)
    if not cfg or not cfg.get("address"):
        return {"configured": False}
    sd = state_dir or _state_dir()
    daemon = _load(sd / "email_assistant_status.json")
    test = _load(sd / "email_assistant_selftest.json")
    drops = daemon.get("drops_24h")
    drops = {str(k): int(v) for k, v in drops.items()} if isinstance(drops, dict) else {}
    return {
        "configured": True,
        "enabled": bool(cfg.get("enabled", True)),
        "address": cfg.get("address"),
        "provider": PROVIDERS.get(cfg.get("provider", ""), {}).get("label", cfg.get("provider", "")),
        "owner_verified": bool(cfg.get("owner_addresses_verified")),
        "last_inbound": _age(daemon.get("last_inbound_at")),
        "last_reply": _age(daemon.get("last_reply_at")),
        "selftest_result": test.get("result"),
        "selftest_age": _age(test.get("at")),
        "drops_24h": drops,
        "drops_24h_total": sum(drops.values()),
    }


def test_now(config: Path | None = None, state_dir: Path | None = None) -> dict:
    """Run the self-test with the Keychain password and record the result."""
    cfg = read_config(config)
    provider, address = cfg.get("provider", ""), cfg.get("address", "")
    if provider not in PROVIDERS or not address:
        return {"result": "unknown"}
    pw = keychain_read(address)
    if not pw:
        return {"result": "wrong_password"}
    res = selftest(provider, address, pw)
    res.pop("token", None)
    sd = state_dir or _state_dir()
    try:
        sd.mkdir(parents=True, exist_ok=True)
        (sd / "email_assistant_selftest.json").write_text(json.dumps(
            {"result": res["result"], "at": datetime.now(timezone.utc).isoformat()}))
    except OSError:
        pass
    return res


def replace_password(new_password: str, config: Path | None = None) -> dict:
    """Validate the new app password with a live probe, then replace the
    Keychain item. The old one is kept unless the new one is accepted."""
    cfg = read_config(config)
    provider, address = cfg.get("provider", ""), cfg.get("address", "")
    if provider not in PROVIDERS or not address:
        return {"ok": False, "error": "unknown"}
    if not password_format_ok(new_password):
        return {"ok": False, "error": "wrong_password"}
    r = probe(provider, address, new_password)
    for stage in ("imap", "smtp"):
        if r[stage] != "ok":
            return {"ok": False, "error": r[stage]}
    return {"ok": keychain_store(address, new_password)}


def _esc(s) -> str:
    return (str(s).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


_SELFTEST_WORDS = {
    "ok": "Passed",
    "timeout": "No reply within 60 seconds",
}


def render_html(row: dict | None = None) -> str:
    """The Doctor card. Server-side HTML, every value escaped. Empty string
    when the assistant has no mailbox, so a fresh install shows no empty
    header. There is no field for the password, and no route returns it."""
    row = read_row() if row is None else row
    if not row.get("configured"):
        return ""
    st = row.get("selftest_result")
    if st is None:
        test = "Not run yet"
    else:
        test = _SELFTEST_WORDS.get(st, explain(st))
        if row.get("selftest_age"):
            test += f" ({row['selftest_age']})"
    drops = row.get("drops_24h") or {}
    if drops:
        drop_txt = ", ".join(f"{k}: {int(v)}" for k, v in sorted(drops.items()))
    else:
        drop_txt = "none"
    on = row.get("enabled", True)
    verified = "Yes" if row.get("owner_verified") else "Not yet. Reply to its hello email"
    return f"""
        <div class="status-card" id="assistant-mailbox">
            <div class="status-name">Assistant's own email</div>
            <div class="status-detail">{_esc(row.get('address'))} &middot; {_esc(row.get('provider'))} &middot; {'on' if on else 'off'}</div>
            <div class="status-detail">Last email received: {_esc(row.get('last_inbound') or 'never')} &middot; last reply: {_esc(row.get('last_reply') or 'never')}</div>
            <div class="status-detail">Self-test: {_esc(test)}</div>
            <div class="status-detail">Your address confirmed: {_esc(verified)}</div>
            <div class="status-detail">Messages ignored in the last 24 hours: {_esc(drop_txt)}</div>
            <div class="status-detail">
                <button type="button" onclick="amPost('test-now')">Test now</button>
                <button type="button" onclick="amReplace()">Replace password</button>
                <button type="button" onclick="amPost('{'off' if on else 'on'}')">Turn {'off' if on else 'on'}</button>
                <span id="am-result" role="status"></span>
            </div>
            <script>
            function amPost(a, body) {{
              var r = document.getElementById('am-result'); r.textContent = 'Working...';
              fetch('/api/v1/assistant-mailbox/' + a, {{method: 'POST',
                headers: {{'Content-Type': 'application/json'}}, body: JSON.stringify(body || {{}})}})
                .then(function (x) {{ return x.json(); }})
                .then(function (j) {{ r.textContent = j.message || j.error || 'Done'; }})
                .catch(function () {{ r.textContent = 'Could not check. Try again.'; }});
            }}
            function amReplace() {{
              var v = window.prompt('Paste the new app password (it is kept in your Mac\u2019s Keychain)');
              if (v) amPost('replace-password', {{password: v}});
            }}
            </script>
        </div>"""


# ── CLI for install.sh ───────────────────────────────────────────────────
# Inputs come from the environment (AM_PROVIDER, AM_ADDRESS, AM_PASSWORD,
# AM_OWNER, AM_NAME), never argv, so the password is not in a process listing.
# Output is key=value lines on stdout. The password is never printed.

def _cli(argv) -> int:
    mode = argv[1] if len(argv) > 1 else ""
    prov = os.environ.get("AM_PROVIDER", "")
    addr = normalise_address(os.environ.get("AM_ADDRESS", ""))
    pw = os.environ.get("AM_PASSWORD", "")
    if prov not in PROVIDERS or not addr:
        print("error=unknown")
        return 2
    if mode == "probe":
        r = probe(prov, addr, pw)
        for k in ("imap", "smtp", "inbox_count"):
            print(f"{k}={r[k]}")
        print(f"oldest_days={'' if r['oldest_days'] is None else r['oldest_days']}")
        return 0
    if mode == "selftest":
        print(f"result={selftest(prov, addr, pw)['result']}")
        return 0
    if mode == "hello":
        print(f"result={hello_owner(prov, addr, pw, os.environ.get('AM_OWNER', ''), os.environ.get('AM_NAME', 'your assistant'))['result']}")
        return 0
    if mode == "store":
        print(f"result={'ok' if keychain_store(addr, pw) else 'failed'}")
        return 0
    if mode == "explain":
        print(explain(os.environ.get("AM_CODE", "unknown")))
        return 0
    print("error=mode")
    return 2


if __name__ == "__main__":  # pragma: no cover
    sys.exit(_cli(sys.argv))
