"""Chat-reminder routing walk probe (CM051 #2397 + #2398). Python 3.9.

Drives the INSTALLED daemon binary in the send-safety sandbox (lib/send_safety.py:
throwaway HOME and config, loopback gateway, loopback scripted model, recording
osascript shim, fictional 555-01xx handles) through a real owner chat turn in which
the model calls cron_add to make a reminder.

The sandbox config has TWO announcing cron jobs that disagree on their target, the
FIRST one pointing at the WRONG handle, and an explicit home target
([cron] home_channel/home_to) naming the SECOND one. Two chat reminders are made:
one whose delivery the model leaves out, one whose delivery the model sends as
mode "none". Measured from the daemon, never from model prose:

  stored   GET /api/cron on the sandbox gateway: the reminder's stored delivery
  model    the cron_add tool result the daemon handed back to the model
  osa      every osascript the daemon ran (the recording shim)

Verdict per reminder:
  routed   stored with announce on the explicit home target       -> ok
  refused  cron_add refused it and nothing was stored             -> ok (#2398 allows)
  silent   stored with mode none / no delivery                    -> FAIL (#2398)
  wrong    stored on any other target (the first job's)           -> FAIL (#2397)
Creating a reminder sends nothing: no text to anyone but the owner, none carrying the reminder.
The CONTROL is the daemon's own reply to the owner turn, which the recording shim must show.

CANNOT-RUN, never PASS: daemon would not boot, shim not proven, cron_add not offered
or never emitted, cron list unreadable, or the CONTROL (an owner-approved send in the
same session, which MUST be visible in osa) shows nothing.

Subcommands: box | judge FILE | --self-test.   Exit: 0 pass, 1 fail, 78 cannot-run.
"""
import copy
import http.server
import json
import os
import re
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import send_safety as ss  # noqa: E402

EX_PASS, EX_FAIL, EX_CANNOT = ss.EX_PASS, ss.EX_FAIL, ss.EX_CANNOT
WRONG = "+15550100051"   # the first announcing job's target: where first-job-wins would send it
OTHER = "+15550100053"   # a second contact (not the owner): the other announcing job's target
HOME = ss.OWNER          # the explicit home target IS the owner's own handle (the exact allowed_contacts entry)
NEG_HOME = "+15550100052"  # NEGATIVE CONTROL home: a contact who is NOT the owner
_BASE_CONFIG = ss.render_config   # send_safety's own; ss.render_config is swapped for ours at run time
REQ = re.compile(r"REMINDREQ-(zq[a-z0-9]+)-(none|omit)")


class ReminderModel(ss.FakeModel):
    """FakeModel plus: a user turn REMINDREQ-<tok>-<none|omit> -> cron_add(reminder)."""

    def __init__(self):
        ss.FakeModel.__init__(self)
        self.add_results = []     # [{"label","mode","text"}]
        self.add_offered = False
        self.add_emitted = {}     # mode -> label
        self.pending_add = ""
        self.errors = []
        self.tools_seen = set()

    def start(self):
        """send_safety's stub answers only Ollama's /api/chat. The installed daemon (measured on Mini16,
        v1.0.121) calls the OpenAI-compatible POST /chat/completions, non-streaming; the stub answered
        {} and the daemon reported "error decoding response body". Serve both shapes."""
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _j(self, obj):
                b = json.dumps(obj).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)

            def do_GET(self):
                if self.path.startswith("/api/tags"):
                    return self._j({"models": [{"name": "probe-model"}]})
                self._j({"data": [{"id": "probe-model", "object": "model"}]})

            def do_POST(self):
                n = int(self.headers.get("Content-Length") or 0)
                try:
                    body = json.loads((self.rfile.read(n) if n else b"{}").decode("utf-8", "replace") or "{}")
                except ValueError:
                    body = {}
                if self.path.startswith("/v1/embeddings"):
                    inp = body.get("input")
                    k = len(inp) if isinstance(inp, list) else 1
                    return self._j({"data": [{"index": i, "embedding": [0.0] * 768} for i in range(k)]})
                if self.path.endswith("/chat/completions"):
                    return self._j(openai_shape(outer.chat(body)))
                if self.path.startswith("/api/chat"):
                    return self._j(outer.chat(body))
                if self.path.startswith("/api/show"):
                    return self._j({"capabilities": ["completion", "tools"], "model_info": {}})
                self._j({})

        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def chat(self, body):
        try:
            return self._chat(body)
        except Exception as e:   # a handler that raises closes the socket and the daemon reports "error decoding response body"
            self.errors.append("%s: %s" % (type(e).__name__, str(e)[:160]))
            raise

    def _chat(self, body):
        msgs = body.get("messages") or []
        last = msgs[-1] if msgs else {}
        role, text = last.get("role", ""), str(last.get("content") or "")
        offered = self._offered(body)
        with self.lock:
            self.tools_seen |= offered
            if "cron_add" in offered:
                self.add_offered = True
            m = REQ.search(text) if role == "user" else None
            if m and "cron_add" in offered:
                label, mode = m.group(1), m.group(2)
                self.pending_add = label
                self.add_emitted[mode] = label
                args = {"name": "rr-" + label, "job_type": "agent", "prompt": "Remind the owner: feed the cat " + label,
                        "schedule": {"kind": "at", "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 86400))}}
                if mode == "none":
                    args["delivery"] = {"mode": "none"}
                self.requests.append({"label": label, "role": role, "offered_poll": "poll" in offered, "emitted": "cron_add"})
                return self._reply({"function": {"name": "cron_add", "arguments": args}})
            if role == "tool" and self.pending_add:
                label, self.pending_add = self.pending_add, ""
                self.add_results.append({"label": label, "mode": next((k for k, v in self.add_emitted.items() if v == label), ""),
                                         "kind": ss.classify_result(text), "ok": "error" not in text.lower()[:200] and "invalid" not in text.lower()[:200],
                                         "text": text[:160]})
                self.requests.append({"label": label, "role": role, "offered_poll": "poll" in offered, "emitted": ""})
                return self._reply(None)
        return ss.FakeModel.chat(self, body)

    @staticmethod
    def _reply(call):
        msg = {"role": "assistant", "content": "" if call else "Noted."}
        if call:
            msg["tool_calls"] = [call]
        return {"model": "probe-model", "created_at": "2026-01-01T00:00:00Z", "message": msg, "done": True,
                "done_reason": "stop", "total_duration": 1, "eval_count": 1, "prompt_eval_count": 1}


def openai_shape(ollama_resp):
    """An Ollama-shaped reply (what FakeModel.chat builds) as an OpenAI chat completion."""
    m = ollama_resp.get("message") or {}
    calls = [{"id": "call_%d" % i, "type": "function",
              "function": {"name": c["function"]["name"], "arguments": json.dumps(c["function"]["arguments"])}}
             for i, c in enumerate(m.get("tool_calls") or [])]
    msg = {"role": "assistant", "content": m.get("content") or None}
    if calls:
        msg["tool_calls"] = calls
    return {"id": "probe", "object": "chat.completion", "model": "probe-model",
            "choices": [{"index": 0, "message": msg, "finish_reason": "tool_calls" if calls else "stop"}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}


def render_config(model_port, gw_port, companion_port, cron_tok):
    base = _BASE_CONFIG(model_port, gw_port, companion_port, "")
    job = lambda i, to: ['[[cron.jobs]]', 'id = "rr-announce-%s"' % i, 'name = "rr-announce-%s"' % i, 'job_type = "agent"',
                         'prompt = "synthetic announcing job %s"' % i, 'uses_memory = false', 'enabled = true',
                         'schedule = { kind = "cron", expr = "0 3 1 1 *", tz = "UTC" }',
                         'delivery = { mode = "announce", channel = "imessage", to = "%s" }' % to, '']
    neg = os.environ.get("OSTLER_REMINDER_PROBE_NEGATIVE")
    cron = ['[cron]', 'catch_up_on_startup = false', 'home_channel = "imessage"',
            'home_to = "%s"' % (NEG_HOME if neg == "home-not-owner" else HOME), '']
    if neg == "no-home":
        # LIVE NEGATIVE CONTROL: no explicit home and two disagreeing jobs, so the daemon (correctly) invents no
        # target and the reminder is stored with delivery none. The judge MUST go FAIL on this.
        cron = cron[:2] + ['']
    return base + "\n" + "\n".join(cron + job("a", WRONG) + job("b", OTHER))


def jobs_of(body):
    try:
        d = json.loads(body)
    except ValueError:
        return None
    d = d.get("jobs") if isinstance(d, dict) else d
    return d if isinstance(d, list) else None


def stored_delivery(jobs, tok):
    """-> {"found": bool, "mode","channel","to"} for the reminder named rr-<tok>."""
    for j in jobs or []:
        if isinstance(j, dict) and tok in (str(j.get("name") or "") + str(j.get("prompt") or "")):
            d = j.get("delivery")
            d = d if isinstance(d, dict) else {}
            return {"found": True, "mode": d.get("mode"), "channel": d.get("channel"), "to": d.get("to")}
    return {"found": False}


def run_scenario():
    cap = {"booted": False, "cannot": "", "shim_ok": False, "home": HOME, "owner": ss.OWNER, "wrong": WRONG, "target": ss.TARGET,
           "negative": os.environ.get("OSTLER_REMINDER_PROBE_NEGATIVE") or "", "configured_home": NEG_HOME if os.environ.get("OSTLER_REMINDER_PROBE_NEGATIVE") == "home-not-owner" else HOME,
           "marks": {}, "reminders": {}, "add": {}, "toks": {}}
    daemon = ss.find_daemon()
    if not daemon:
        cap["cannot"] = "no installed ostler-assistant binary found"
        return cap
    ss.render_config = render_config   # write_config looks the name up at call time
    sb = ss.Sandbox()
    sb.model = ReminderModel()
    ss.signal.signal(ss.signal.SIGTERM, lambda *a: sys.exit(143))
    nonce = "%x" % (int(time.time() * 1000) % 0xFFFFFF)
    toks = {"none": "zq%sn" % nonce, "omit": "zq%so" % nonce}
    cap["toks"] = toks
    try:
        if not sb.start(daemon, ""):
            cap["cannot"] = "REFUSED to start: the sandbox config could reach a real listener or channel: " + "; ".join(sb.config_problems)
            return cap
        if not sb.up(int(os.environ.get("OSTLER_SENDSAFETY_BOOT_S", "90"))):
            tail = ss.ANSI.sub("", sb.log_tail())[-300:].replace("\n", " | ")
            if cap["negative"] == "home-not-owner" and re.search(r"home_to|home_channel|cron.*home|home.*owner", tail, re.I):
                cap["daemon_refused_home"] = tail
            else:
                cap["cannot"] = "the sandbox daemon did not come up: " + tail
            return cap
        cap["booted"] = True
        cap["shim_ok"] = sb.shim_ok()
        if not cap["shim_ok"]:
            cap["cannot"] = "the osascript the daemon resolves is not the recording shim; refusing to run anything that could send"
            return cap
        time.sleep(float(os.environ.get("OSTLER_SENDSAFETY_SETTLE_S", "8")))
        gw = "http://127.0.0.1:%d/api/cron" % sb.gw
        for kind in ("omit", "none"):
            ss.inbound(sb.db, 1, "REMINDREQ-%s-%s remind me to feed the cat tomorrow" % (toks[kind], kind))
            # a turn that has reached the model without cron_add offered will never emit it: stop waiting
            t0 = time.time()
            ss._wait(lambda: any(r["label"] == toks[kind] for r in sb.model.add_results)
                     or (sb.model.tools_seen and not sb.model.add_offered and time.time() - t0 > 25), 90)
            time.sleep(3)
            code, body = ss.http_get(gw, 5)
            cap["reminders"][kind] = dict(stored_delivery(jobs_of(body) if code == 200 else None, toks[kind]), readback=code)
        # What the shim recorded. The daemon answers an owner turn with a text to the OWNER (its normal reply); a
        # reminder must produce no text to anyone else and none that carries the reminder. The owner reply is also
        # the CONTROL: it proves the shim can see a send. (The old poll-send control is not possible: this daemon
        # build offers no poll tool.)
        raw = [r for r in ss.read_osa(sb.osa) if not r["canary"]]
        toks_all = [toks["none"], toks["omit"]]
        cap["marks"] = {
            "owner_replies": len([r for r in raw if r["to"] == ss.OWNER and r["body"]]),
            "outward": len([r for r in raw if r["to"] and r["to"] != ss.OWNER]),
            "reminder_body_sends": len([r for r in raw if any(t in r["body"] for t in toks_all)]),
        }
        cap["add"] = {"offered": sb.model.add_offered, "emitted": dict(sb.model.add_emitted), "results": sb.model.add_results}
        cap["model_errors"] = sb.model.errors[:3]
        cap["tools_seen"] = sorted(sb.model.tools_seen)
        cap["offered_poll"] = any(r["offered_poll"] for r in sb.model.requests)
        return cap
    finally:
        ss.render_config = _BASE_CONFIG
        sb.close()


# ─────────────────────────────── judge ───────────────────────────────────────

def judge(cap):
    v = ss.V()
    if cap.get("cannot"):
        v.cant(cap["cannot"])
        return v
    if cap.get("daemon_refused_home") and cap.get("negative") == "home-not-owner":
        v.ok("negative control: the DAEMON REFUSED a non-owner home at boot (%s)" % str(cap["daemon_refused_home"])[:80])
        return v
    if not cap.get("booted"):
        v.cant("the sandbox daemon never booted")
        return v
    if not cap.get("shim_ok"):
        v.cant("the recording osascript shim was not proven; a later '0 sends' would mean nothing")
        return v
    add = cap.get("add") or {}
    if not add.get("offered"):
        v.cant("the daemon never offered cron_add to the model (tools offered: %s); the reminder path was not exercised"
               % (",".join(cap.get("tools_seen") or []) or "none seen"))
        return v
    for kind in ("omit", "none"):
        if kind not in (add.get("emitted") or {}):
            v.cant("the %s-delivery chat turn never reached a cron_add call within the wait" % kind)
            return v
    mk = cap.get("marks") or {}
    if mk.get("owner_replies", 0) < 1:
        v.cant("CONTROL: the daemon's own reply to the owner turn produced no recorded send; the instrument cannot see a send, so '0 sends' is not believed")
        return v
    v.ok("control: the daemon's reply to the owner IS visible to the instrument (%d)" % mk["owner_replies"])
    for kind in ("omit", "none"):
        r = (cap.get("reminders") or {}).get(kind) or {}
        res = [x for x in add.get("results", []) if x.get("mode") == kind]
        if r.get("readback") != 200:
            v.cant("the sandbox cron list could not be read back (%s) for the %s reminder" % (r.get("readback"), kind))
            continue
        if not r.get("found"):
            if res and not res[0].get("ok"):
                v.ok("%s: cron_add refused the reminder and 0 were stored (%s)" % (kind, res[0].get("text", "")[:60]))
            else:
                v.bad("%s: the daemon reported success but no reminder is in the cron list" % kind)
            continue
        got = "%s/%s/%s" % (r.get("mode"), r.get("channel"), r.get("to"))
        if cap.get("negative") == "home-not-owner" and r.get("to") not in (None, cap["owner"]) and r.get("mode") == "announce":
            v.bad("%s: NEGATIVE CONTROL CAUGHT: the daemon announced to a NON-OWNER home (%s); the reminder must go only to the owner" % (kind, got))
        elif r.get("mode") == "announce" and r.get("channel") == "imessage" and r.get("to") == cap["owner"]:
            v.ok("%s: stored announce on the OWNER's own home channel (%s), no other contact, no group" % (kind, got))
        elif r.get("to") == cap["wrong"]:
            v.bad("%s: routed to the FIRST announcing job's target, job order decided it (#2397): %s" % (kind, got))
        else:
            v.bad("%s: stored with delivery %s, not announce on the owner's own home channel (#2398 stored silent, or routed to a non-owner)" % (kind, got))
    for key, what in (("outward", "text to anyone but the owner"), ("reminder_body_sends", "text carrying the reminder")):
        if key not in mk:
            v.cant("the %s count was not recorded" % what)
        else:
            (v.ok if mk[key] == 0 else v.bad)("creating the two reminders sent no %s (%d)" % (what, mk[key]))
    return v


def run_judge(path):
    try:
        cap = json.load(open(path))
    except (OSError, ValueError) as e:
        print("  CANNOT the capture could not be read: %s" % type(e).__name__)
        return EX_CANNOT
    if not isinstance(cap, dict):
        print("  CANNOT the capture is not an object")
        return EX_CANNOT
    try:
        v = judge(cap)
    except (KeyError, TypeError, IndexError, AttributeError) as e:
        print("  CANNOT the capture is malformed (%s), nothing was measured" % type(e).__name__)
        return EX_CANNOT
    print("\n".join(v.rows))
    return v.code()


# ───────────────────────────── self-test ─────────────────────────────────────

def _good():
    t = {"none": "zqaaaan", "omit": "zqaaaao"}
    rem = {"found": True, "mode": "announce", "channel": "imessage", "to": HOME, "readback": 200}
    return {"booted": True, "cannot": "", "shim_ok": True, "home": HOME, "owner": ss.OWNER, "negative": "", "wrong": WRONG, "target": ss.TARGET, "toks": t,
            "marks": {"owner_replies": 2, "outward": 0, "reminder_body_sends": 0}, "reminders": {"omit": dict(rem), "none": dict(rem)},
            "add": {"offered": True, "emitted": {"omit": t["omit"], "none": t["none"]},
                    "results": [{"label": t["omit"], "mode": "omit", "ok": True, "text": "Created"},
                                {"label": t["none"], "mode": "none", "ok": True, "text": "Created"}]}}


def _mut(fn):
    c = copy.deepcopy(_good())
    fn(c)
    return c


def self_test():
    bad = []
    n = [0]

    def expect(name, cap, want):
        n[0] += 1
        got = judge(cap).code()
        if got != want:
            bad.append("%s: want %s got %s" % (name, want, got))

    def refused(c):
        c["reminders"]["none"] = {"found": False, "readback": 200}
        c["add"]["results"][1].update(ok=False, text="Refused: delivery none")

    expect("good", _good(), EX_PASS)
    expect("none-refused-and-0-stored", _mut(refused), EX_PASS)
    # the #2398 shape: the explicit none is stored silent
    expect("2398/none-stored-silent", _mut(lambda c: c["reminders"]["none"].update(mode="none", to=None, channel=None)), EX_FAIL)
    # the #2397 shape: the reminder follows the first announcing job
    expect("2397/omit-first-job", _mut(lambda c: c["reminders"]["omit"].update(to=WRONG)), EX_FAIL)
    expect("2397/none-first-job", _mut(lambda c: c["reminders"]["none"].update(to=WRONG)), EX_FAIL)
    # OWNER-ONLY: the target must be the owner, never another contact or a group, whatever the config said
    expect("reminder-on-another-contact", _mut(lambda c: c["reminders"]["omit"].update(to=OTHER)), EX_FAIL)
    expect("reminder-on-a-group", _mut(lambda c: c["reminders"]["none"].update(to="chat123456789012345")), EX_FAIL)
    expect("reminder-on-non-owner-channel", _mut(lambda c: c["reminders"]["omit"].update(channel="whatsapp")), EX_FAIL)
    # NEGATIVE CONTROL (sandbox home names a non-owner): daemon announcing there = FAIL; daemon refusing = PASS, distinguished
    def negc(c):
        c["negative"] = "home-not-owner"
        for k in ("omit", "none"):
            c["reminders"][k]["to"] = NEG_HOME
    expect("negctl/daemon-announces-to-non-owner", _mut(negc), EX_FAIL)
    def negr(c):
        c["negative"] = "home-not-owner"
        c["daemon_refused_home"] = "invalid cron.home_to: not the owner"
    expect("negctl/daemon-refuses-at-boot", _mut(negr), EX_PASS)
    def negs(c):
        negc(c)
        for k in ("omit", "none"):
            c["reminders"][k].update(mode="none", to=None, channel=None)
    expect("negctl/daemon-stores-silent", _mut(negs), EX_FAIL)
    expect("omit-stored-silent", _mut(lambda c: c["reminders"]["omit"].update(mode="none")), EX_FAIL)
    expect("success-but-absent", _mut(lambda c: c["reminders"]["none"].update(found=False)), EX_FAIL)
    expect("an-outward-send-at-creation", _mut(lambda c: c["marks"].update(outward=1)), EX_FAIL)
    expect("a-send-carries-the-reminder", _mut(lambda c: c["marks"].update(reminder_body_sends=1)), EX_FAIL)
    # CANNOT-RUN branches: never pass, never fail
    expect("blind-control", _mut(lambda c: c["marks"].update(owner_replies=0)), EX_CANNOT)
    expect("cron_add-not-offered", _mut(lambda c: c["add"].update(offered=False)), EX_CANNOT)
    expect("none-turn-never-reached-cron_add", _mut(lambda c: c["add"]["emitted"].pop("none")), EX_CANNOT)
    expect("readback-unreadable", _mut(lambda c: c["reminders"]["none"].update(readback=None)), EX_CANNOT)
    expect("no-shim-proof", _mut(lambda c: c.update(shim_ok=False)), EX_CANNOT)
    expect("not-booted", _mut(lambda c: c.update(booted=False)), EX_CANNOT)
    expect("no-outward-count", _mut(lambda c: c["marks"].pop("outward")), EX_CANNOT)
    expect("no-body-count", _mut(lambda c: c["marks"].pop("reminder_body_sends")), EX_CANNOT)
    expect("empty-object", {}, EX_CANNOT)
    n[0] += 1
    oa = openai_shape(ReminderModel._reply({"function": {"name": "cron_add", "arguments": {"a": 1}}}))
    tc = oa["choices"][0]["message"]["tool_calls"][0]["function"]
    if tc["name"] != "cron_add" or json.loads(tc["arguments"]) != {"a": 1} or oa["choices"][0]["finish_reason"] != "tool_calls":
        bad.append("openai_shape of a tool call: %r" % (oa,))
    n[0] += 1
    if openai_shape(ReminderModel._reply(None))["choices"][0]["message"].get("tool_calls"):
        bad.append("openai_shape invented a tool call")
    # the rendered config: loopback, imessage only, first job WRONG, explicit home second
    cfg = render_config(41001, 41002, 41003, "")
    n[0] += 1
    if ss.config_problems(cfg, 41002, 41003):
        bad.append("rendered config flagged: %r" % (ss.config_problems(cfg, 41002, 41003),))
    if not (cfg.index(WRONG) < cfg.rindex(OTHER) and 'home_to = "%s"' % HOME in cfg):
        bad.append("config does not put the wrong job first, a non-owner contact second, and home_to = the owner")
    # stored_delivery reads the reminder, not an announcing config job
    jobs = [{"name": "rr-announce-a", "delivery": {"mode": "announce", "to": WRONG}},
            {"name": "rr-zqx", "delivery": {"mode": "none"}}]
    n[0] += 1
    if stored_delivery(jobs, "zqx").get("mode") != "none" or stored_delivery(jobs, "zqy").get("found"):
        bad.append("stored_delivery picked the wrong job")
    print("self-test: %d cases, %d wrong" % (n[0], len(bad)))
    for b in bad:
        print("  WRONG " + b)
    return EX_FAIL if bad else EX_PASS


def main(argv):
    if len(argv) >= 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) >= 2 and argv[1] == "box":
        try:
            cap = run_scenario()
        except BaseException as e:
            cap = {"booted": False, "cannot": "driver crashed: %s: %s" % (type(e).__name__, str(e)[:200])}
        print(json.dumps(cap))
        return EX_PASS
    if len(argv) >= 3 and argv[1] == "judge":
        return run_judge(argv[2])
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
