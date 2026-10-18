#!/usr/bin/env python3
"""telegram_channel_round_trip -- loopback driver and judge.

WHAT THIS MEASURES. The assistant's Telegram channel, end to end, against a
fake Telegram Bot API and a stub model on loopback, with the REAL daemon
binary (`ostler-assistant channel start`):

  (a) a message already queued when the daemon starts gets NO reply;
  (b) the owner's private message gets exactly ONE reply, to the owner's chat,
      and the seen reaction is 👀 (never a random pick, never 👍);
  (c) a stranger's private message gets no reply and no reaction;
  (d) the owner writing inside a GROUP gets no reply (would leak to the group);
  (e) the daemon's status file says connected, last owner message set, and
      counts 2 ignored messages (stranger + group);
  (f) the token is read from ~/.ostler/secrets/telegram_bot_token: config.toml
      holds bot_token = "".

Everything is synthetic and loopback only. The daemon runs with HOME,
OSTLER_HOME and ZEROCLAW_CONFIG_DIR in a throwaway directory and is pointed at
the fake through OSTLER_TELEGRAM_API_BASE (the daemon refuses any non-loopback
value).

MODES
  run --daemon BIN [--facts FILE] [--keep-log FILE]   drive, print facts JSON
  judge FACTS.json                                    0 PASS / 1 FAIL / 78 CANNOT
  --self-test                                         judge must go red on every mutant

Exit codes follow the probe contract: 0 PASS, 1 FAIL, 78 CANNOT-RUN.
"""
from __future__ import annotations

import argparse
import copy
import http.server
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

TOKEN = "123456789:test_token_synthetic_0000000000000000"  # synthetic
OWNER, STRANGER, GROUP = 4242, 777, -100200300
SEEN = "\U0001F440"


class FakeBotApi:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.calls: list[dict] = []
        self.pending: list[dict] = []
        self.next_id = 1
        self.polls = 0

    def queue(self, frm: int, chat: int, ctype: str, text: str) -> int:
        with self.lock:
            uid = self.next_id
            self.next_id += 1
            self.pending.append({"update_id": uid, "message": {
                "message_id": 100 + uid, "date": int(time.time()), "text": text,
                "from": {"id": frm, "is_bot": False, "first_name": "Synthetic"},
                "chat": {"id": chat, "type": ctype}}})
            return uid

    def handler(self):
        api = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):  # noqa: N802
                n = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(n) or b"{}"
                try:
                    body = json.loads(raw)
                except ValueError:
                    body = {"_raw": raw[:200].decode("latin-1")}
                parts = self.path.split("/")
                method = parts[-1] if parts else ""
                with api.lock:
                    api.calls.append({"method": method, "body": body, "t": time.time()})
                if len(parts) < 3 or parts[1] != f"bot{TOKEN}":
                    return self._j({"ok": False, "error_code": 401, "description": "Unauthorized"})
                if method == "getMe":
                    return self._j({"ok": True, "result": {"id": 123456789, "is_bot": True, "username": "synthetic_test_bot"}})
                if method == "getUpdates":
                    off = int(body.get("offset", 0) or 0)
                    with api.lock:
                        api.polls += 1
                        api.pending = [u for u in api.pending if u["update_id"] >= off]
                        res = list(api.pending)
                    if not res and body.get("timeout", 0):
                        time.sleep(0.3)
                    return self._j({"ok": True, "result": res})
                if method == "sendMessage":
                    return self._j({"ok": True, "result": {"message_id": 9000, "chat": {"id": body.get("chat_id")}, "text": "ok"}})
                return self._j({"ok": True, "result": True})

            def _j(self, obj):
                b = json.dumps(obj).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)
        return H


class _Ollama(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):  # noqa: N802
        self._json({"models": [{"name": "stub", "model": "stub"}]})

    def do_POST(self):  # noqa: N802
        n = int(self.headers.get("Content-Length", "0"))
        req = json.loads(self.rfile.read(n) or b"{}")
        msg = {"role": "assistant", "content": "Synthetic reply from the loopback model."}
        base = {"model": req.get("model", "stub"), "created_at": "2026-10-18T00:00:00Z"}
        if req.get("stream", True) and self.path.endswith("/api/chat"):
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.end_headers()
            self.wfile.write((json.dumps({**base, "message": msg, "done": False}) + "\n").encode())
            self.wfile.write((json.dumps({**base, "message": {"role": "assistant", "content": ""}, "done": True,
                                          "done_reason": "stop", "total_duration": 1, "prompt_eval_count": 1,
                                          "eval_count": 1}) + "\n").encode())
            return
        self._json({**base, "message": msg, "done": True, "done_reason": "stop",
                    "prompt_eval_count": 1, "eval_count": 1})


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def write_config(cfg_dir: str, llm: int) -> str:
    os.makedirs(os.path.join(cfg_dir, "workspace"), exist_ok=True)
    text = f'''schema_version = 2

[providers]
fallback = "ollama"

[providers.models.ollama]
base_url = "http://127.0.0.1:{llm}"
model = "stub"
timeout_secs = 30

[channels]
ack_reactions = true

[channels.telegram]
enabled = true
bot_token = ""
allowed_users = ["{OWNER}"]
'''
    p = os.path.join(cfg_dir, "config.toml")
    with open(p, "w") as f:
        f.write(text)
    os.chmod(p, 0o600)
    return text


def _wait(pred, timeout: float, step: float = 0.25) -> bool:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(step)
    return pred()


def drive(binary: str, keep_log: str | None) -> dict:
    root = tempfile.mkdtemp(prefix="ostler-telegram-probe-")
    home = os.path.join(root, "home")
    ostler = os.path.join(home, ".ostler")
    os.makedirs(os.path.join(ostler, "secrets"), exist_ok=True)
    tok = os.path.join(ostler, "secrets", "telegram_bot_token")
    fd = os.open(tok, os.O_WRONLY | os.O_CREAT, 0o600)
    os.write(fd, (TOKEN + "\n").encode())
    os.close(fd)

    api = FakeBotApi()
    api_port, llm_port = _free_port(), _free_port()
    a_srv = http.server.ThreadingHTTPServer(("127.0.0.1", api_port), api.handler())
    l_srv = http.server.ThreadingHTTPServer(("127.0.0.1", llm_port), _Ollama)
    for s in (a_srv, l_srv):
        threading.Thread(target=s.serve_forever, daemon=True).start()
    cfg_text = write_config(os.path.join(root, "cfg"), llm_port)

    facts: dict = {"daemon_started": False, "config_bot_token_empty": 'bot_token = ""' in cfg_text}
    env = dict(os.environ)
    env.update({
        "HOME": home, "OSTLER_HOME": ostler,
        "ZEROCLAW_CONFIG_DIR": os.path.join(root, "cfg"),
        "ZEROCLAW_WORKSPACE": os.path.join(root, "cfg", "workspace"),
        "OSTLER_TELEGRAM_API_BASE": f"http://127.0.0.1:{api_port}",
        "RUST_LOG": "warn,zeroclaw_channels::telegram=info,zeroclaw_channels::orchestrator=info",
        "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost",
    })
    for k in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY", "all_proxy"):
        env.pop(k, None)
    log_path = os.path.join(root, "daemon.log")
    proc = None
    try:
        # (a) queued before start
        api.queue(OWNER, OWNER, "private", "queued before the assistant started")
        with open(log_path, "ab") as log:
            proc = subprocess.Popen(["nice", "-n", "19", binary, "channel", "start"], env=env,
                                    stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)
        facts["daemon_started"] = True
        state = os.path.join(ostler, "state", "telegram_channel.json")

        def status():
            try:
                with open(state) as f:
                    return json.load(f)
            except (OSError, ValueError):
                return None
        facts["connected"] = _wait(lambda: (status() or {}).get("status") == "connected", 90)
        time.sleep(1.5)
        facts["replies_before_live"] = sum(1 for c in api.calls if c["method"] == "sendMessage")

        # (c) stranger, (d) owner in a group, then (b) owner private
        api.queue(STRANGER, STRANGER, "private", "hello, who is this?")
        api.queue(OWNER, GROUP, "group", "owner talking in a group")
        owner_uid = api.queue(OWNER, OWNER, "private", "what is on today?")
        facts["owner_message_id"] = 100 + owner_uid
        _wait(lambda: any(c["method"] == "sendMessage" for c in api.calls), 90)
        time.sleep(4)
        facts["daemon_alive"] = proc.poll() is None
        facts["calls"] = [{"method": c["method"], "chat_id": c["body"].get("chat_id"),
                           "message_id": c["body"].get("message_id"),
                           "reaction": c["body"].get("reaction"),
                           "text": (c["body"].get("text") or "")[:120]}
                          for c in api.calls if c["method"] not in ("getUpdates",)]
        facts["polls"] = api.polls
        facts["status"] = status()
        facts["token_in_status_file"] = TOKEN.split(":")[1] in json.dumps(facts["status"] or {})
    finally:
        if proc and proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
                proc.wait(timeout=8)
            except Exception:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except Exception:
                    pass
        a_srv.shutdown()
        l_srv.shutdown()
        if keep_log and os.path.exists(log_path):
            shutil.copy(log_path, keep_log)
        shutil.rmtree(root, ignore_errors=True)
    return facts


def judge(f: dict) -> int:
    if not f.get("daemon_started"):
        print("CANNOT-RUN: daemon did not start")
        return 78
    if not f.get("connected"):
        print("CANNOT-RUN: the daemon never reported Telegram connected (see the daemon log)")
        return 78
    fails = []
    calls = f.get("calls") or []
    sends = [c for c in calls if c["method"] == "sendMessage"]
    reacts = [c for c in calls if c["method"] == "setMessageReaction"]

    def chat(c):
        return str(c.get("chat_id"))
    if f.get("replies_before_live"):
        fails.append(f"(a) {f['replies_before_live']} reply(ies) to a message queued before start")
    owner_sends = [c for c in sends if chat(c) == str(OWNER)]
    if len(owner_sends) != 1:
        fails.append(f"(b) owner got {len(owner_sends)} replies, want exactly 1")
    for c in calls:
        if chat(c) in (str(STRANGER), str(GROUP)):
            fails.append(f"(c/d) {c['method']} sent to non-owner chat {chat(c)}")
    adds = [c for c in reacts if c.get("reaction")]
    if not adds:
        fails.append("(b) no seen reaction on the owner's message")
    for c in adds:
        emojis = [r.get("emoji") for r in c["reaction"]]
        if c.get("message_id") == f.get("owner_message_id") and emojis and emojis[0] not in (SEEN,):
            # the first reaction on the owner message must be 👀
            if c is adds[0]:
                fails.append(f"(b) first reaction is {emojis[0]!r}, want 👀")
        if "\U0001F44D" in emojis:
            fails.append("(b) a 👍 reaction was sent")
    if adds and [r.get("emoji") for r in adds[0]["reaction"]] != [SEEN]:
        fails.append(f"(b) seen reaction is {adds[0]['reaction']}, want 👀")
    st = f.get("status") or {}
    if st.get("status") != "connected":
        fails.append(f"(e) status file says {st.get('status')!r}")
    if not st.get("last_owner_message_at"):
        fails.append("(e) last_owner_message_at not recorded")
    if st.get("non_owner_dropped") != 2:
        fails.append(f"(e) non_owner_dropped = {st.get('non_owner_dropped')}, want 2")
    if f.get("token_in_status_file"):
        fails.append("(f) the token appears in the status file")
    if not f.get("config_bot_token_empty"):
        fails.append("(f) config.toml carried a token")
    if not f.get("daemon_alive"):
        fails.append("daemon exited during the run")
    for x in fails:
        print("FAIL " + x)
    if not fails:
        print(f"PASS: owner answered once ({owner_sends[0]['text']!r}), 👀 seen reaction, "
              f"stranger + group ignored and counted ({st.get('non_owner_dropped')}), "
              f"queued-before-start not answered, token from the secrets file")
    return 1 if fails else 0


def _good_facts() -> dict:
    return {
        "daemon_started": True, "connected": True, "replies_before_live": 0, "daemon_alive": True,
        "config_bot_token_empty": True, "token_in_status_file": False, "owner_message_id": 104,
        "calls": [
            {"method": "getMe", "chat_id": None, "message_id": None, "reaction": None, "text": ""},
            {"method": "setMessageReaction", "chat_id": str(OWNER), "message_id": 104, "reaction": [{"type": "emoji", "emoji": SEEN}], "text": ""},
            {"method": "sendChatAction", "chat_id": str(OWNER), "message_id": None, "reaction": None, "text": ""},
            {"method": "sendMessage", "chat_id": str(OWNER), "message_id": None, "reaction": None, "text": "Synthetic reply"},
            {"method": "setMessageReaction", "chat_id": str(OWNER), "message_id": 104, "reaction": [], "text": ""},
        ],
        "status": {"status": "connected", "last_owner_message_at": "2026-10-18T06:00:00Z", "non_owner_dropped": 2},
    }


def self_test() -> int:
    good = _good_facts()
    if judge(copy.deepcopy(good)) != 0:
        print("SELF-TEST BROKEN: good facts did not pass")
        return 2
    mutants = {
        "queued answered": lambda f: f.update(replies_before_live=1),
        "no owner reply": lambda f: f.update(calls=[c for c in f["calls"] if c["method"] != "sendMessage"]),
        "two owner replies": lambda f: f["calls"].append(dict(f["calls"][3])),
        "reply to stranger": lambda f: f["calls"].append(dict(f["calls"][3], chat_id=str(STRANGER))),
        "reply into group": lambda f: f["calls"].append(dict(f["calls"][3], chat_id=str(GROUP))),
        "thumbs-up seen": lambda f: f["calls"][1].update(reaction=[{"type": "emoji", "emoji": "\U0001F44D"}]),
        "random seen": lambda f: f["calls"][1].update(reaction=[{"type": "emoji", "emoji": "\U0001F525"}]),
        "no seen reaction": lambda f: f.update(calls=[c for c in f["calls"] if c["method"] != "setMessageReaction"]),
        "drops not counted": lambda f: f["status"].update(non_owner_dropped=0),
        "status not connected": lambda f: f["status"].update(status="config_error"),
        "no owner timestamp": lambda f: f["status"].update(last_owner_message_at=None),
        "token leaked": lambda f: f.update(token_in_status_file=True),
        "token in config": lambda f: f.update(config_bot_token_empty=False),
        "daemon died": lambda f: f.update(daemon_alive=False),
    }
    survived = []
    for name, mut in mutants.items():
        f = copy.deepcopy(good)
        mut(f)
        print(f"--- mutant: {name}")
        if judge(f) != 1:
            survived.append(name)
    for name, f in {"not started": dict(good, daemon_started=False), "never connected": dict(good, connected=False)}.items():
        print(f"--- cannot-run: {name}")
        if judge(f) != 78:
            survived.append(name)
    if survived:
        print(f"SELF-TEST FAILED: judge missed {survived}")
        return 2
    print(f"negative control behaved: {len(mutants)} mutants red, 2 CANNOT-RUN, good facts PASS")
    return 1  # by contract: the self-test proves the judge CAN fail


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", nargs="?", choices=["run", "judge"])
    ap.add_argument("facts_file", nargs="?")
    ap.add_argument("--daemon")
    ap.add_argument("--facts")
    ap.add_argument("--keep-log")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if a.mode == "judge":
        with open(a.facts_file) as fh:
            return judge(json.load(fh))
    if a.mode == "run":
        if not a.daemon or not os.access(a.daemon, os.X_OK):
            print(f"CANNOT-RUN: daemon binary not executable: {a.daemon}")
            return 78
        facts = drive(a.daemon, a.keep_log)
        if a.facts:
            with open(a.facts, "w") as fh:
                json.dump(facts, fh, indent=2)
        print(json.dumps(facts, indent=2))
        return judge(facts)
    ap.print_usage()
    return 2


if __name__ == "__main__":
    sys.exit(main())
