#!/usr/bin/env python3
"""Real-provider round trip for the assistant's own email address.

Same real components as assistant_mailbox_e2e.py (install.sh step, Doctor
module, daemon binary, temporary keychain), but against a REAL iCloud or Gmail
account for the assistant, with a human sending the owner's mail. The model is
a local stub: this proves the MAIL path, not the model's answers.

Input is the environment only; nothing secret is printed, written to the repo,
or passed on a command line:
  OSTLER_REAL_ADDRESS    the assistant's NEW account address
  OSTLER_REAL_PASSWORD   its app password
  OSTLER_REAL_PROVIDER   icloud | gmail
  OSTLER_REAL_OWNER      the owner's address (the one that will send the mails)
  OSTLER_E2E_DAEMON      the daemon binary
  OSTLER_E2E_KEYCHAIN    set by assistant_mailbox_real.sh
Exit 0 all ok, 1 a check failed, 2 CANNOT-RUN.
"""
from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(REPO / "vendor" / "doctor" / "agent"))
import assistant_mailbox_e2e as e2e  # noqa: E402  (Llm, check, wait, free_port, results)

check, wait = e2e.check, e2e.wait


def need(name: str) -> str:
    v = os.environ.get(name, "")
    if not v:
        e2e.cannot_run(f"{name} is not set")
    return v


def main() -> int:
    address = need("OSTLER_REAL_ADDRESS").strip().lower()
    password = need("OSTLER_REAL_PASSWORD")
    provider = need("OSTLER_REAL_PROVIDER").strip().lower()
    owner = need("OSTLER_REAL_OWNER").strip().lower()
    binary = need("OSTLER_E2E_DAEMON")
    need("OSTLER_E2E_KEYCHAIN")
    if provider not in ("icloud", "gmail"):
        e2e.cannot_run("OSTLER_REAL_PROVIDER must be icloud or gmail")
    if not os.access(binary, os.X_OK):
        e2e.cannot_run(f"daemon binary not executable: {binary}")
    if address == owner:
        e2e.cannot_run("the assistant's account must be a NEW account, not the owner's address")

    root = Path(tempfile.mkdtemp(prefix="ostler-am-real-"))
    home = root / "home"; ostler = home / ".ostler"; cfgdir = root / "cfg"
    (ostler / "secrets").mkdir(parents=True); (cfgdir / "workspace").mkdir(parents=True)
    llm_port, gw_port = e2e.free_port(), e2e.free_port()
    httpd = ThreadingHTTPServer(("127.0.0.1", llm_port), e2e.Llm)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    env = dict(os.environ)
    env.pop("OSTLER_REAL_PASSWORD", None)
    env.update({
        "OSTLER_E2E_LOOPBACK": "1",  # only enables the temporary-keychain path here
        "HOME": str(home), "OSTLER_HOME": str(ostler), "OSTLER_DIR": str(ostler),
        "ZEROCLAW_CONFIG_DIR": str(cfgdir), "ZEROCLAW_WORKSPACE": str(cfgdir / "workspace"),
        "OSTLER_ASSISTANT_CONFIG": str(cfgdir / "config.toml"),
        "OSTLER_CHAT_GATEWAY_PORT": str(gw_port),
        "OSTLER_CHAT_ADMIN_TOKEN_FILE": str(ostler / "secrets" / "zeroclaw_admin_token"),
        "RUST_LOG": "warn,zeroclaw_channels=info",
    })
    os.environ.update({k: v for k, v in env.items() if k.startswith(("OSTLER_", "HOME"))})
    (ostler / "secrets" / "zeroclaw_admin_token").write_text("ab" * 32)
    os.chmod(ostler / "secrets" / "zeroclaw_admin_token", 0o600)
    base = cfgdir / "base.toml"
    base.write_text(f'''schema_version = 2

[providers]
fallback = "ollama"

[providers.models.ollama]
base_url = "http://127.0.0.1:{llm_port}"
model = "stub"
timeout_secs = 30

[channels.email]
enabled = false
imap_host = "127.0.0.1"
imap_port = 1
imap_tls = false
smtp_host = "127.0.0.1"
smtp_port = 1
smtp_tls = false
username = "unused"
password = "unused"
from_address = "unused@example.test"
allowed_senders = ["{owner}"]
''')
    answers = root / "answers.txt"
    answers.write_text(f"am_choose={provider}\nam_address={address}\nam_password={password}\n")
    os.chmod(answers, 0o600)
    config = cfgdir / "config.toml"
    state = ostler / "state" / "email_assistant_status.json"
    log = root / "daemon.log"
    proc = {"p": None}

    def status() -> dict:
        try:
            return json.loads(state.read_text())
        except (OSError, ValueError):
            return {}

    def cfg_verified() -> bool:
        m = re.search(r"owner_addresses_verified = \[(.*)\]", config.read_text())
        return bool(m) and owner in m.group(1)

    try:
        import assistant_mailbox as am
        step_env = dict(env)
        step_env.update({"E2E_REPO": str(REPO), "E2E_ANSWERS": str(answers), "E2E_BASE_CONFIG": str(base),
                        "E2E_OUT_CONFIG": str(config), "E2E_OWNER": owner})
        print("Running the installer step against the real provider (about a minute)...", flush=True)
        r = subprocess.run(["/bin/bash", str(HERE / "drive_installer_step.sh")], env=step_env,
                           capture_output=True, text=True, timeout=300)
        out = r.stdout
        print(out.replace(password, "[password]"), flush=True)
        answers.unlink()
        if r.returncode == 2 and "CANNOT-RUN" in out:
            e2e.cannot_run(out.strip())
        check("installer step enabled the mailbox (login, SMTP AUTH, self-test, hello)",
              "ENABLED=true" in out and "SELFTEST=ok" in out and "HELLO_ID=<" in out)
        check("the password is not in the config or the installer output",
              (not config.exists() or password not in config.read_text()) and password not in out)
        if "ENABLED=true" not in out:
            return e2e.finish(1)

        log_f = open(log, "ab")
        proc["p"] = subprocess.Popen([binary, "daemon", "--host", "127.0.0.1", "--port", str(gw_port)],
                                     env=env, stdout=log_f, stderr=log_f, stdin=subprocess.DEVNULL,
                                     start_new_session=True)
        time.sleep(8)
        res = am.test_now()
        check("Doctor 'Test now' -> daemon -> self-test round trip through the real provider",
              res == {"result": "ok"}, str(res))
        check("the Doctor card shows it from the daemon's status file",
              am.read_row(config, ostler / "state").get("selftest_result") == "ok")

        print(f"\nSTEP 1. From {owner}, REPLY to the email titled 'Hello from ...' that the assistant "
              f"just sent you. Waiting up to 5 minutes...", flush=True)
        check("owner's reply to the hello mail verifies the address (needs the real Message-ID round trip)",
              wait(cfg_verified, 300, 3))
        if not cfg_verified():
            print("The hello Message-ID may have been rewritten by the provider; compare "
                  "hello_message_id in the config with the Message-ID header of the hello you received.")
            return e2e.finish(1)

        replies0 = status().get("last_reply_at")
        print(f"\nSTEP 2. From {owner}, send a NEW short email to {address} (any question). "
              f"Waiting up to 5 minutes for the assistant's reply...", flush=True)
        check("the assistant replied to the owner's mail",
              wait(lambda: status().get("last_reply_at") not in (None, replies0), 300, 3))
        ans = input("Did the reply arrive in the owner's inbox FROM the assistant's address, in the "
                    "same thread? [y/N] ").strip().lower() if sys.stdin.isatty() else "n"
        check("owner confirms: from the assistant address, threaded", ans.startswith("y"))

        print(f"\nSTEP 3. From a DIFFERENT address you own (not {owner}), send any email to {address}. "
              f"Waiting up to 5 minutes... (skip with Ctrl-C)", flush=True)
        try:
            check("a mail from an unlisted address is counted under not_listed and gets no reply",
                  wait(lambda: (status().get("drops_24h") or {}).get("not_listed", 0) >= 1, 300, 3))
        except KeyboardInterrupt:
            print("step 3 skipped by the operator (NOT a pass)")
        html = am.render_html(am.read_row(config, ostler / "state"))
        check("the Doctor card shows the address, self-test, confirmation and drops, and no secret",
              address in html and "Passed" in html and "Yes" in html and password not in html
              and "keychain:" not in html)
    finally:
        p = proc["p"]
        if p is not None:
            try:
                os.killpg(p.pid, signal.SIGTERM); p.wait(timeout=10)
            except Exception:
                pass
        httpd.shutdown()
        subprocess.run(["rm", "-rf", str(root)])
    return e2e.finish(0)


if __name__ == "__main__":
    sys.exit(main())
