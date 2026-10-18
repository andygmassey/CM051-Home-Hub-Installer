#!/usr/bin/env python3
"""ostler-telegram-setup against a fake Telegram Bot API on 127.0.0.1.

No real Telegram account and no real token. `launchctl` is a stub on a temp
path that records its arguments and, like the real daemon would, writes the
status file the helper waits for. Every case runs the REAL helper as a
subprocess, the way a customer runs it.

Exit 0 when every case passes, 1 on any failure.
"""
from __future__ import annotations

import http.server
import json
import os
import stat
import subprocess
import sys
import tempfile
import threading
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
HELPER = HERE / "lib" / "ostler-telegram-setup.py"
TOKEN = "123456789:test_token_synthetic_0000000000000000"  # synthetic
OWNER, STRANGER = 4242, 777

FAILS: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else f"  -- {detail}"))
    if not cond:
        FAILS.append(name)


def upd(uid: int, frm: int, chat: int, ctype: str, text: str, is_bot: bool = False) -> dict:
    return {"update_id": uid, "message": {"message_id": uid, "text": text,
            "from": {"id": frm, "is_bot": is_bot, "first_name": "Synthetic", "username": "synthetic_owner"},
            "chat": {"id": chat, "type": ctype}}}


class Fake:
    def __init__(self, queued: list, later: list, getme_code: int | None = None) -> None:
        self.queued, self.later, self.getme_code = queued, later, getme_code
        self.calls: list[tuple[str, dict]] = []
        self.released = False


def serve(fake: Fake) -> tuple[http.server.ThreadingHTTPServer, str]:
    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):  # silent
            pass

        def do_POST(self):
            n = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(n) or b"{}")
            _, bot, method = self.path.split("/", 2)
            fake.calls.append((method, body))
            if bot != f"bot{TOKEN}":
                return self._j({"ok": False, "error_code": 401, "description": "Unauthorized"}, 401)
            if method == "getMe":
                if fake.getme_code:
                    return self._j({"ok": False, "error_code": fake.getme_code, "description": "Unauthorized"}, fake.getme_code)
                return self._j({"ok": True, "result": {"id": 1, "is_bot": True, "username": "synthetic_test_bot"}})
            if method == "getUpdates":
                off = int(body.get("offset", 0))
                pool = fake.queued + (fake.later if fake.released else [])
                if body.get("timeout", 0) > 0:
                    fake.released = True  # "the owner sends the message now"
                    pool = fake.queued + fake.later
                return self._j({"ok": True, "result": [u for u in pool if u["update_id"] >= off]})
            return self._j({"ok": True, "result": True})

        def _j(self, obj, code=200):
            b = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_address[1]}"


def stub_launchctl(d: Path, status: str, error: str | None = None) -> Path:
    p = d / "launchctl"
    st = json.dumps({"status": status, "last_error": error, "non_owner_dropped": 0,
                     "bot_username": "synthetic_test_bot", "updated_at": "2026-10-18T00:00:00Z"})
    p.write_text(f"""#!/bin/sh
printf '%s\\n' "$*" >> "{d}/launchctl.args"
mkdir -p "{d}/ostler/state"
# Like the daemon: report only when [channels.telegram] is enabled.
if {sys.executable} -c "import tomllib,sys; c=tomllib.load(open(sys.argv[1],'rb')); sys.exit(0 if c.get('channels',{{}}).get('telegram',{{}}).get('enabled') else 1)" "{d}/ostler/assistant-config/config.toml"; then
  printf '%s' '{st}' > "{d}/ostler/state/telegram_channel.json"
fi
""")
    p.chmod(0o755)
    return p


EXISTING = """schema_version = 2

[providers]
fallback = "ollama"

[channels.imessage]
enabled = true

[channels.telegram]
enabled = false
bot_token = ""
allowed_users = []

[channels.email]
enabled = true
allowed_senders = ["owner@example.test"]
"""


def run(d: Path, base: str | None, stdin: str, *extra: str, status="connected", error=None):
    lc = stub_launchctl(d, status, error)
    env = {k: v for k, v in os.environ.items() if not k.lower().endswith("_proxy")}
    env["OSTLER_TELEGRAM_API_BASE"] = base or ""
    env["NO_PROXY"] = "127.0.0.1"
    r = subprocess.run([sys.executable, str(HELPER), "--token-stdin", "--yes", "--wait-secs", "3",
                        "--daemon-wait-secs", "3", "--ostler-dir", str(d / "ostler"),
                        "--launchctl", str(lc), *extra],
                       input=stdin, capture_output=True, text=True, env=env, timeout=60)
    return r


def fresh() -> Path:
    d = Path(tempfile.mkdtemp(prefix="tg-setup-"))
    cfg = d / "ostler" / "assistant-config" / "config.toml"
    cfg.parent.mkdir(parents=True)
    cfg.write_text(EXISTING)
    cfg.chmod(0o600)
    return d


def cfg_of(d: Path) -> dict:
    return tomllib.loads((d / "ostler" / "assistant-config" / "config.toml").read_text())


def main() -> int:
    secret_rel = Path("ostler/secrets/telegram_bot_token")

    # 1. happy path; an OLD queued message from a stranger must not claim the bot,
    #    a group message must not either, the owner's private message does.
    d = fresh()
    fake = Fake(queued=[upd(10, STRANGER, STRANGER, "private", "old")],
                later=[upd(11, STRANGER, -100200300, "group", "stranger in a group"),
                       upd(12, OWNER, OWNER, "private", "hello")])
    srv, base = serve(fake)
    r = run(d, base, TOKEN + "\n")
    out = r.stdout + r.stderr
    check("happy: exit 0", r.returncode == 0, out)
    check("happy: says Connected from the daemon's status", "Connected." in out, out)
    c = cfg_of(d)
    check("happy: owner id is the ONLY allowed user", c["channels"]["telegram"].get("allowed_users") == [str(OWNER)], str(c["channels"]["telegram"]))
    check("happy: telegram enabled", c["channels"]["telegram"].get("enabled") is True)
    check("happy: token NOT in config.toml", "test_token_synthetic" not in (d / "ostler/assistant-config/config.toml").read_text())
    check("happy: other settings untouched", c["channels"]["email"]["allowed_senders"] == ["owner@example.test"] and c["channels"]["imessage"]["enabled"] is True and c["providers"]["fallback"] == "ollama")
    sp = d / secret_rel
    check("happy: secret file holds the token", sp.exists() and sp.read_text().strip() == TOKEN)
    check("happy: secret file is 0600", sp.exists() and stat.S_IMODE(sp.stat().st_mode) == 0o600, oct(stat.S_IMODE(sp.stat().st_mode)) if sp.exists() else "missing")
    check("happy: config stays 0600", stat.S_IMODE((d / "ostler/assistant-config/config.toml").stat().st_mode) == 0o600)
    check("happy: token never printed", "test_token_synthetic" not in out)
    args = (d / "launchctl.args").read_text() if (d / "launchctl.args").exists() else ""
    check("happy: assistant restarted via kickstart -k", f"kickstart -k gui/{os.getuid()}/com.creativemachines.ostler.assistant" in args, args)
    sends = [b for m, b in fake.calls if m == "sendMessage"]
    check("happy: confirmation sent only to the owner", len(sends) == 1 and sends[0]["chat_id"] == OWNER, str(sends))
    check("happy: stranger never contacted", all(b.get("chat_id") != STRANGER for _, b in fake.calls))
    srv.shutdown()

    # 2. malformed token: refused before any network call, nothing written
    d = fresh()
    fake = Fake([], [])
    srv, base = serve(fake)
    r = run(d, base, "not-a-token\n")
    check("bad shape: exit 1", r.returncode == 1, r.stdout)
    check("bad shape: clear message", "does not look like a BotFather token" in r.stdout, r.stdout)
    check("bad shape: no network call", fake.calls == [], str(fake.calls))
    check("bad shape: nothing saved", not (d / secret_rel).exists() and cfg_of(d)["channels"]["telegram"]["enabled"] is False)
    srv.shutdown()

    # 3. right shape, Telegram says 401
    d = fresh()
    fake = Fake([], [], getme_code=401)
    srv, base = serve(fake)
    r = run(d, base, TOKEN + "\n")
    check("401: exit 1", r.returncode == 1, r.stdout)
    check("401: says Telegram did not accept it", "did not accept that token" in r.stdout, r.stdout)
    check("401: nothing saved", not (d / secret_rel).exists())
    srv.shutdown()

    # 4. Telegram unreachable: CANNOT (78), not a refusal, nothing saved
    d = fresh()
    r = run(d, "http://127.0.0.1:9", TOKEN + "\n")
    check("unreachable: exit 78", r.returncode == 78, r.stdout)
    check("unreachable: says couldn't check", "Couldn't check" in r.stdout, r.stdout)
    check("unreachable: nothing saved", not (d / secret_rel).exists())

    # 5. owner never messages: refused with what to do, nothing saved
    d = fresh()
    fake = Fake([], [upd(5, OWNER, -1, "group", "group only")])
    srv, base = serve(fake)
    r = run(d, base, TOKEN + "\n")
    check("no message: exit 1", r.returncode == 1, r.stdout)
    check("no message: tells them to press Start", "press Start" in r.stdout, r.stdout)
    check("no message: nothing saved", not (d / secret_rel).exists())
    srv.shutdown()

    # 6. daemon reports a config error: helper does NOT say connected
    d = fresh()
    fake = Fake([], [upd(3, OWNER, OWNER, "private", "hi")])
    srv, base = serve(fake)
    r = run(d, base, TOKEN + "\n", status="config_error", error="synthetic reason from the daemon")
    check("daemon error: exit 1", r.returncode == 1, r.stdout)
    check("daemon error: relays the daemon's reason", "synthetic reason from the daemon" in r.stdout, r.stdout)
    check("daemon error: never says Connected.", "Connected." not in r.stdout, r.stdout)
    srv.shutdown()

    # 7. a non-loopback API override is refused (cannot ship the token off the Mac)
    d = fresh()
    r = run(d, "https://example.com", TOKEN + "\n")
    check("override: non-loopback refused", r.returncode == 1 and "loopback" in r.stdout, r.stdout)

    # 8. --off switches it off and deletes the token
    d = fresh()
    fake = Fake([], [upd(3, OWNER, OWNER, "private", "hi")])
    srv, base = serve(fake)
    run(d, base, TOKEN + "\n")
    r = run(d, base, "", "--off")
    c = cfg_of(d)
    check("off: exit 0", r.returncode == 0, r.stdout)
    check("off: disabled, no owner", c["channels"]["telegram"]["enabled"] is False and c["channels"]["telegram"]["allowed_users"] == [])
    check("off: token deleted", not (d / secret_rel).exists())
    check("off: other settings untouched", c["channels"]["email"]["allowed_senders"] == ["owner@example.test"])
    st = json.loads((d / "ostler/state/telegram_channel.json").read_text())
    check("off: the Doctor status file says off (no stale Connected)", st.get("status") == "off", str(st))
    # and with --no-restart (no daemon involved at all) it still says off
    run(d, base, TOKEN + "\n")
    run(d, base, "", "--off", "--no-restart")
    st = json.loads((d / "ostler/state/telegram_channel.json").read_text())
    check("off --no-restart: status file says off", st.get("status") == "off", str(st))
    srv.shutdown()

    # 9. a config with no telegram section at all gains one, and stays valid
    d = fresh()
    (d / "ostler/assistant-config/config.toml").write_text('schema_version = 2\n\n[channels.imessage]\nenabled = true\n')
    fake = Fake([], [upd(3, OWNER, OWNER, "private", "hi")])
    srv, base = serve(fake)
    r = run(d, base, TOKEN + "\n")
    c = cfg_of(d)
    check("no section: exit 0 and section added", r.returncode == 0 and c["channels"]["telegram"]["allowed_users"] == [str(OWNER)], r.stdout)
    check("no section: imessage kept", c["channels"]["imessage"]["enabled"] is True)
    srv.shutdown()

    print(f"\n{len(FAILS)} failed")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
