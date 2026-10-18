#!/usr/bin/env python3
"""ostler-telegram-setup -- connect a Telegram bot to the Ostler assistant.

The customer path, about two minutes:

  1. In Telegram, message @BotFather, send /newbot, pick a name. It replies
     with a token. Paste it here (it is not shown as you type).
  2. We ask Telegram whether the token is real (getMe).
  3. "Now send any message to @<your bot> from your own Telegram account."
     We wait for that one message, show who sent it, and ask "Is this you?"
  4. We store the token in ~/.ostler/secrets/telegram_bot_token (0600, never
     in config.toml), switch [channels.telegram] on with ONLY that numeric
     Telegram user id allowed, and restart the assistant.
  5. We read the assistant's own status file and say "connected" only if the
     assistant itself says so.

Only the owner can talk to the assistant. Anyone else who finds the bot is
ignored without a reply and counted; the Doctor shows the count.

`--off` switches Telegram off again (the token file is removed).

Exit codes: 0 connected / switched off, 1 refused or failed (with a reason),
2 usage error, 78 could not check (network, or the assistant did not report).

Python 3.11 stdlib only. The token is never printed, logged, or put on a
command line.
"""
from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import subprocess
import sys
import time
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.telegram.org"
LABEL = "com.creativemachines.ostler.assistant"
TOKEN_RE = re.compile(r"^[0-9]{1,20}:[A-Za-z0-9_-]{30,64}$")
EXIT_OK, EXIT_FAIL, EXIT_USAGE, EXIT_CANNOT = 0, 1, 2, 78


class CannotCheck(Exception):
    """Network or service problem: we could not find out, which is not a no."""


class Refused(Exception):
    """A definite no, with a sentence the customer can act on."""


def say(msg: str = "") -> None:
    print(msg, flush=True)


# ------------------------------------------------------------ Bot API
def loopback_api_base(value: str | None) -> str | None:
    """Test hook. Same rule as the daemon: loopback only, so it can never
    send the token anywhere but this Mac."""
    if not value:
        return None
    m = re.match(r"^https?://(\[::1\]|127\.0\.0\.1|localhost)(:[0-9]+)?(/.*)?$", value.strip())
    if not m:
        raise Refused(f"OSTLER_TELEGRAM_API_BASE must be a loopback URL, got {value!r}")
    return value.strip().rstrip("/")


class Bot:
    def __init__(self, token: str, base: str) -> None:
        self._token = token
        self._base = base

    def call(self, method: str, body: dict | None = None, timeout: float = 15) -> object:
        url = f"{self._base}/bot{self._token}/{method}"
        data = json.dumps(body or {}).encode()
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                payload = json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            try:
                payload = json.loads(e.read() or b"{}")
            except ValueError:
                raise CannotCheck(f"Telegram answered HTTP {e.code} to {method}") from None
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            # Never include the URL: it carries the token.
            raise CannotCheck(f"could not reach Telegram ({type(e).__name__})") from None
        except ValueError:
            raise CannotCheck(f"Telegram sent an unreadable answer to {method}") from None
        if payload.get("ok"):
            return payload.get("result")
        code = payload.get("error_code")
        desc = str(payload.get("description", "unknown error"))
        if code in (401, 404) and method == "getMe":
            raise Refused("Telegram did not accept that token. Copy it again from @BotFather "
                          "(the whole line, digits, colon and letters) and re-run.")
        if code == 409:
            raise Refused("Another program is already reading this bot's messages (Telegram says: "
                          f"{desc}). If Ostler is already connected, run `ostler-telegram-setup --off` first.")
        raise CannotCheck(f"Telegram refused {method}: {code} {desc}")


def wait_for_owner(bot: Bot, wait_secs: float) -> dict:
    """First PRIVATE-chat message from a human, sent after we started."""
    # Skip anything already queued so an old message cannot claim the bot.
    offset = 0
    queued = bot.call("getUpdates", {"timeout": 0, "allowed_updates": ["message"]}) or []
    for u in queued:
        offset = max(offset, int(u.get("update_id", 0)) + 1)
    end = time.monotonic() + wait_secs
    while time.monotonic() < end:
        poll = max(1, min(20, int(end - time.monotonic())))
        updates = bot.call("getUpdates", {"offset": offset, "timeout": poll,
                                          "allowed_updates": ["message"]}, timeout=poll + 10) or []
        for u in updates:
            offset = max(offset, int(u.get("update_id", 0)) + 1)
            m = u.get("message") or {}
            frm, chat = m.get("from") or {}, m.get("chat") or {}
            if chat.get("type") == "private" and not frm.get("is_bot") and isinstance(frm.get("id"), int):
                bot.call("getUpdates", {"offset": offset, "timeout": 0})  # acknowledge
                return frm
    raise Refused(f"No message arrived within {int(wait_secs)} seconds. Open Telegram, find your bot, "
                  "press Start or send it any message, then run this again.")


# ------------------------------------------------------------ files
def write_secret(path: Path, token: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(token + "\n")
    os.replace(tmp, path)
    os.chmod(path, 0o600)


_HEADER = re.compile(r"^\s*\[\[?\s*([^\]]+?)\s*\]\]?\s*(#.*)?$")


def _strip_section(lines: list[str], name: str) -> list[str]:
    """Remove `[name]` and any `[name.sub]` tables, up to the next other header."""
    out, skipping = [], False
    for line in lines:
        m = _HEADER.match(line)
        if m:
            t = m.group(1)
            skipping = t == name or t.startswith(name + ".")
        if not skipping:
            out.append(line)
    return out


def set_telegram_section(cfg: Path, owner_id: int | None) -> None:
    """Rewrite [channels.telegram]; owner_id None switches it off.
    Re-parsed with tomllib before it replaces the original; on any doubt the
    original stays and we refuse."""
    original = cfg.read_text() if cfg.exists() else ""
    try:
        before = tomllib.loads(original)
    except tomllib.TOMLDecodeError as e:
        raise Refused(f"{cfg} is not valid TOML ({e}); not touching it.") from None
    tg_before = (before.get("channels") or {}).get("telegram")
    if tg_before is not None and not isinstance(tg_before, dict):
        raise Refused(f"{cfg} defines channels.telegram in an unexpected form; not touching it.")
    lines = _strip_section(original.splitlines(), "channels.telegram")
    while lines and not lines[-1].strip():
        lines.pop()
    block = ["", "[channels.telegram]"]
    if owner_id is None:
        block += ["enabled = false", 'bot_token = ""', "allowed_users = []"]
    else:
        block += [
            "# Set by ostler-telegram-setup. The token lives in ~/.ostler/secrets/telegram_bot_token.",
            "# Only this numeric Telegram user id may talk to the assistant.",
            "enabled = true",
            'bot_token = ""',
            f'allowed_users = ["{owner_id}"]',
        ]
    text = "\n".join(lines + block) + "\n"
    try:
        after = tomllib.loads(text)
    except tomllib.TOMLDecodeError:
        # e.g. an inline `telegram = {...}` under [channels]: we will not guess.
        raise Refused(f"{cfg} sets Telegram in a form this tool does not edit; original left unchanged.") from None
    tg = after["channels"]["telegram"]
    want_on = owner_id is not None
    if tg.get("enabled") is not want_on or (want_on and tg.get("allowed_users") != [str(owner_id)]):
        raise Refused(f"internal check failed rewriting {cfg}; original left unchanged.")
    # Everything outside channels.telegram must parse to the same thing.
    b2, a2 = dict(before), dict(after)
    for d in (b2, a2):
        ch = dict(d.get("channels") or {})
        ch.pop("telegram", None)
        if ch or "channels" in d:
            d["channels"] = ch
    if b2 != a2:
        raise Refused(f"rewriting {cfg} would have changed other settings; original left unchanged.")
    cfg.parent.mkdir(parents=True, exist_ok=True)
    tmp = cfg.with_name(cfg.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, cfg)
    os.chmod(cfg, 0o600)


def restart_assistant(launchctl: str) -> str | None:
    """Returns None on success, else the reason."""
    target = f"gui/{os.getuid()}/{LABEL}"
    r = subprocess.run([launchctl, "kickstart", "-k", target], capture_output=True, text=True)
    if r.returncode != 0:
        return f"launchctl kickstart {target} exited {r.returncode}: {(r.stderr or r.stdout).strip()}"
    return None


def read_status(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def wait_for_daemon(status_path: Path, since: float, wait_secs: float) -> dict | None:
    end = time.monotonic() + wait_secs
    while time.monotonic() < end:
        st = read_status(status_path)
        if st and status_path.stat().st_mtime >= since and st.get("status") in (
                "connected", "config_error", "api_error"):
            return st
        time.sleep(0.5)
    return None


# ------------------------------------------------------------ main
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Connect a Telegram bot to your Ostler assistant.")
    ap.add_argument("--off", action="store_true", help="switch Telegram off and delete the stored token")
    ap.add_argument("--token-stdin", action="store_true", help="read the token from stdin (no prompt)")
    ap.add_argument("--yes", action="store_true", help="accept the first sender without asking")
    ap.add_argument("--wait-secs", type=float, default=180)
    ap.add_argument("--daemon-wait-secs", type=float, default=45)
    ap.add_argument("--no-restart", action="store_true")
    ap.add_argument("--ostler-dir", default=os.environ.get("OSTLER_HOME") or str(Path.home() / ".ostler"))
    ap.add_argument("--launchctl", default="/bin/launchctl")
    a = ap.parse_args(argv)

    home = Path(a.ostler_dir)
    secret = home / "secrets" / "telegram_bot_token"
    cfg = home / "assistant-config" / "config.toml"
    status_path = home / "state" / "telegram_channel.json"

    try:
        if a.off:
            set_telegram_section(cfg, None)
            if secret.exists():
                secret.unlink()
            if not a.no_restart and (why := restart_assistant(a.launchctl)):
                say(f"Telegram is switched off in the settings, but the assistant did not restart: {why}")
                return EXIT_CANNOT
            say("Telegram is switched off and the stored token is deleted.")
            return EXIT_OK

        base = loopback_api_base(os.environ.get("OSTLER_TELEGRAM_API_BASE")) or API
        say("Connect Telegram to your assistant")
        say("")
        say("1. In Telegram, open a chat with @BotFather and send /newbot.")
        say("   Pick a name and a username ending in 'bot'. BotFather replies with a token.")
        if a.token_stdin:
            token = sys.stdin.readline().strip()
        else:
            token = getpass.getpass("2. Paste the token here (it will not show as you type): ").strip()
        if not TOKEN_RE.match(token):
            raise Refused("That does not look like a BotFather token (digits, a colon, then about 35 "
                          "letters and numbers). Copy the whole token and try again.")
        bot = Bot(token, base)
        me = bot.call("getMe") or {}
        uname = me.get("username") or "your bot"
        say(f"   Telegram knows this bot: @{uname}")
        # A bot that was used elsewhere may have a webhook, which blocks
        # getUpdates. Removing it does not delete any messages.
        bot.call("deleteWebhook", {"drop_pending_updates": False})
        say("")
        say(f"3. Now open Telegram on your phone, find @{uname}, and send it any message")
        say(f"   (press Start, or type hello). Waiting up to {int(a.wait_secs)} seconds...")
        frm = wait_for_owner(bot, a.wait_secs)
        who = " ".join(x for x in (frm.get("first_name"), frm.get("last_name")) if x) or "someone"
        handle = f" (@{frm['username']})" if frm.get("username") else ""
        say(f"   Message received from {who}{handle}, Telegram user id {frm['id']}.")
        if not a.yes:
            ans = input("   Is this you? Only this account will be able to talk to your assistant. [y/N] ")
            if ans.strip().lower() not in ("y", "yes"):
                raise Refused("Not saved. Run this again and send the message from your own account.")

        write_secret(secret, token)
        set_telegram_section(cfg, int(frm["id"]))
        say("")
        say(f"4. Saved. Token stored in {secret} (only you can read it).")
        try:
            bot.call("sendMessage", {"chat_id": frm["id"],
                                     "text": "Connected to your Ostler assistant. Message me here any time."})
        except (CannotCheck, Refused):
            pass  # the daemon's own status below is the real verdict

        if a.no_restart:
            say("   The assistant was not restarted (--no-restart). It picks this up on its next start.")
            return EXIT_OK
        since = time.time() - 1
        if why := restart_assistant(a.launchctl):
            say(f"   Could not restart the assistant: {why}")
            return EXIT_CANNOT
        st = wait_for_daemon(status_path, since, a.daemon_wait_secs)
        if st is None:
            say("   The assistant restarted but has not reported on Telegram yet. "
                "Check the Doctor page in a minute: it shows Telegram connected or the reason it is not.")
            return EXIT_CANNOT
        if st.get("status") == "connected":
            say(f"5. Connected. Message @{uname} to talk to your assistant.")
            return EXIT_OK
        say(f"   The assistant could not start Telegram: {st.get('last_error') or st.get('status')}")
        return EXIT_FAIL
    except Refused as e:
        say(f"Not connected: {e}")
        return EXIT_FAIL
    except CannotCheck as e:
        say(f"Couldn't check: {e}. Nothing was saved. Try again when your Mac is online.")
        return EXIT_CANNOT
    except (KeyboardInterrupt, EOFError):
        say("\nCancelled. Nothing was saved.")
        return EXIT_FAIL


if __name__ == "__main__":
    sys.exit(main())
