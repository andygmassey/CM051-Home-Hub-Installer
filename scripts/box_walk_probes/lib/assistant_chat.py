"""Two chat probes for the scale walk (box side + judges, Python 3.9).

1. assistant_self_description_is_clean (BLOCKING). Asks the installed
   assistant "What can you do?" and "Who are you?" over /ws/chat and FAILS if
   a reply leaks internal tool vocabulary (pwg_..., memory_store,
   memory_recall, memory_forget, cron_..., web_fetch, "HTTP request"; case
   insensitive), or ADDRESSES the user by the assistant's own configured name
   (a vocative: "<Name>, I can..." or "..., <Name>?"). Stating its own name
   ("I'm <Name>") is correct and PASSES. Names are read from the box's
   ~/.ostler/assistant-config/config.toml (user_assistant_name,
   user_first_name), never hard-coded.

2. chat_latency_baseline (ADVISORY). Andy: chat replies "took a while", and
   Hub-side LLM latency was NOT INSTRUMENTED. Five fixed questions; per turn,
   time to first content token and total time, printed with the configured
   model and the box's RAM tier. Numbers only; never a pass/fail on speed.

The box side grades on the box and prints one JSON line of verdicts, token
names and timings. The reply prose never leaves the box.

  selfdesc-box | latency-box          (on the box)
  judge-selfdesc FILE | judge-latency FILE
  --self-test                         (canned replies, see self_test)
"""
import base64
import json
import os
import re
import socket
import struct
import sys
import time

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
HOME = os.path.expanduser("~")
GATEWAY = os.environ.get("OSTLER_PROBE_GATEWAY", "http://127.0.0.1:8000").rstrip("/")
TOKEN_PATH = os.environ.get("OSTLER_PROBE_TOKEN_PATH", os.path.join(HOME, ".ostler", "secrets", "zeroclaw_admin_token"))
CONFIG = os.path.join(HOME, ".ostler", "assistant-config", "config.toml")

LEAKS = [
    ("pwg_", re.compile(r"pwg_", re.I)),
    ("memory_store/recall/forget", re.compile(r"memory_(store|recall|forget)", re.I)),
    ("cron_", re.compile(r"cron_", re.I)),
    ("web_fetch", re.compile(r"web_fetch", re.I)),
    ("HTTP request", re.compile(r"http request", re.I)),
]
SELFDESC_QUESTIONS = ("What can you do?", "Who are you?")
LATENCY_QUESTIONS = (
    "What can you help me with today?",
    "Who have I been in contact with recently?",
    "What do I have on this week?",
    "What are my interests?",
    "Summarise what you know about me in two sentences.",
)


def config_values(text):
    def get(key):
        m = re.search(r'(?m)^\s*%s\s*=\s*"((?:[^"\\]|\\.)*)"' % re.escape(key), text)
        return json.loads('"%s"' % m.group(1)) if m else ""
    return {"assistant": get("user_assistant_name"), "owner": get("user_first_name"), "model": get("model")}


def leaks_in(text):
    return [name for name, rx in LEAKS if rx.search(text or "")]


def vocative(text, name):
    """True when the reply ADDRESSES someone as `name`: the name opening a
    sentence and followed by a comma ("Ada, I can..."), or a trailing ", Ada"
    before ? ! . or the end. "I'm Ada", "I am Ada" and "my name is Ada" are
    the assistant stating its own name and are not vocatives."""
    if not name or not text:
        return False
    n = re.escape(name.strip())
    opening = re.compile(r"(?:^|[.!?\n]\s*)%s\s*,\s" % n, re.I)
    closing = re.compile(r",\s*%s\s*(?:[?!.]|$)" % n, re.I | re.M)
    return bool(opening.search(text) or closing.search(text))


def ws_chat(question, deadline_s=420):
    """-> dict(text, ttft_s, total_s, error). Same handshake as the grounded probe."""
    try:
        token = open(TOKEN_PATH).read().strip()
    except OSError as e:
        return {"error": "no admin token (%s)" % type(e).__name__}
    port = int(GATEWAY.rsplit(":", 1)[1])
    t_start = time.time()
    deadline = t_start + deadline_s
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=20)
    except OSError as e:
        return {"error": "no_connect %s" % type(e).__name__}
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(("GET /ws/chat HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: zeroclaw.v1\r\n"
               "Authorization: Bearer %s\r\n\r\n" % (port, key, token)).encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        c = s.recv(4096)
        if not c:
            return {"error": "handshake_eof"}
        buf += c
    head, rest = buf.split(b"\r\n\r\n", 1)
    if b" 101" not in head.split(b"\r\n")[0]:
        return {"error": "handshake %s" % head.split(b"\r\n")[0].decode(errors="replace")[:60]}
    st = {"rest": rest}

    def rd(n):
        o = b""
        while len(o) < n:
            if st["rest"]:
                t = st["rest"][: n - len(o)]
                o += t
                st["rest"] = st["rest"][len(t):]
            else:
                s.settimeout(max(1, deadline - time.time()))
                c = s.recv(65536)
                if not c:
                    raise EOFError
                st["rest"] = c
        return o

    def frame():
        b0, b1 = rd(2)
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack("!H", rd(2))[0]
        elif n == 127:
            n = struct.unpack("!Q", rd(8))[0]
        return b0 & 0x0F, rd(n)

    d = json.dumps({"type": "message", "content": question}).encode()
    m = os.urandom(4)
    mk = bytes(b ^ m[i % 4] for i, b in enumerate(d))
    hdr = struct.pack("!BB", 0x81, 0x80 | len(d)) if len(d) < 126 else struct.pack("!BBH", 0x81, 0x80 | 126, len(d))
    t_sent = time.time()
    s.sendall(hdr + m + mk)
    text, final, t_first, err = "", None, None, None
    while time.time() < deadline:
        try:
            op, pay = frame()
        except Exception:
            err = "timeout"
            break
        if op == 8:
            break
        if op != 1:
            continue
        try:
            ev = json.loads(pay)
        except ValueError:
            continue
        t = ev.get("type")
        if t == "chunk" and ev.get("content"):
            t_first = t_first or time.time()
            text += ev["content"]
        elif t == "chunk_reset":
            text = ""
        elif t == "done":
            final = ev.get("full_response") if "full_response" in ev else text
            break
        elif t == "error":
            err = "error frame"
            break
    s.close()
    t_end = time.time()
    return {"text": final if final is not None else text,
            "ttft_s": round(t_first - t_sent, 2) if t_first else None,
            "total_s": round(t_end - t_sent, 2), "error": err}


def _config():
    try:
        return config_values(open(CONFIG, encoding="utf-8").read())
    except OSError:
        return None


def box_selfdesc():
    cfg = _config()
    if cfg is None or not cfg["assistant"]:
        return {"cannot": "no user_assistant_name in %s" % CONFIG}
    turns = []
    for q in SELFDESC_QUESTIONS:
        r = ws_chat(q)
        if r.get("error") and not (r.get("text") or "").strip():
            return {"cannot": "the assistant could not be asked %r: %s" % (q, r["error"])}
        text = r.get("text") or ""
        turns.append({"question": q, "answered": bool(text.strip()), "leaks": leaks_in(text),
                      "vocative_assistant": vocative(text, cfg["assistant"]),
                      "states_own_name": bool(re.search(r"\b%s\b" % re.escape(cfg["assistant"]), text, re.I))})
    return {"turns": turns, "assistant_name_len": len(cfg["assistant"]), "owner_name_set": bool(cfg["owner"])}


def judge_selfdesc(c):
    lines, fail = [], False

    def check(label, ok):
        nonlocal fail
        lines.append(("  ok     " if ok else "  FAIL   ") + label)
        fail |= not ok

    if c.get("cannot"):
        return ["  CANNOT " + c["cannot"]], EX_CANNOT
    for t in c.get("turns") or []:
        q = t["question"]
        check("%r was answered" % q, t.get("answered", False))
        check("%r leaks no internal tool name%s" % (q, (": " + ", ".join(t["leaks"])) if t.get("leaks") else ""),
              not t.get("leaks"))
        check("%r does not address the user by the assistant's own name" % q, not t.get("vocative_assistant"))
    if not c.get("turns"):
        return lines + ["  CANNOT no turn was graded"], EX_CANNOT
    return lines, EX_FAIL if fail else EX_PASS


def box_latency():
    cfg = _config() or {}
    try:
        import subprocess
        mem = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout.strip())
        ram_gb = mem // (1 << 30)
    except Exception:
        ram_gb = None
    tier = None if ram_gb is None else ("16" if ram_gb < 24 else ("24-47" if ram_gb < 48 else "48+"))
    turns = []
    for q in LATENCY_QUESTIONS:
        r = ws_chat(q)
        turns.append({"question": q, "ttft_s": r.get("ttft_s"), "total_s": r.get("total_s"),
                      "error": r.get("error"), "answered": bool((r.get("text") or "").strip())})
    return {"model": cfg.get("model") or "unknown", "ram_gb": ram_gb, "ram_tier": tier, "turns": turns}


def judge_latency(c):
    lines = ["  note   model %s, RAM %s GB (tier %s)" % (c.get("model"), c.get("ram_gb"), c.get("ram_tier"))]
    measured = [t for t in c.get("turns") or [] if t.get("total_s") is not None and t.get("answered")]
    for t in c.get("turns") or []:
        lines.append("  ok     %-55s ttft %s s, total %s s%s" % (
            repr(t["question"]), t.get("ttft_s") if t.get("ttft_s") is not None else "NOT-MEASURED",
            t.get("total_s"), "" if t.get("answered") else " (no answer: %s)" % t.get("error")))
    if not measured:
        return lines + ["  CANNOT no turn completed, so there is no baseline"], EX_CANNOT
    tt = sorted(t["ttft_s"] for t in measured if t.get("ttft_s") is not None)
    tot = sorted(t["total_s"] for t in measured)
    lines.append("  note   %d of %d turns answered; median ttft %s s, median total %s s"
                 % (len(measured), len(c.get("turns") or []), tt[len(tt) // 2] if tt else "NOT-MEASURED", tot[len(tot) // 2]))
    return lines, EX_PASS


def self_test():
    ok = True
    cfg = config_values('user_first_name = "Sam"\nuser_assistant_name = "Ada"\n[providers.ollama]\nmodel = "qwen3.5:9b"\n')
    if cfg != {"assistant": "Ada", "owner": "Sam", "model": "qwen3.5:9b"}:
        print("  FAIL   config read: %r" % cfg)
        ok = False
    else:
        print("  ok     the assistant name, owner name and model are read from config.toml")

    def turn(text):
        return {"question": "What can you do?", "answered": True, "leaks": leaks_in(text),
                "vocative_assistant": vocative(text, "Ada"), "states_own_name": "ada" in text.lower()}

    canned = [
        ("clean reply", "I can look up the people you know, remind you of what you owe and summarise your week.", EX_PASS),
        ("states its own name", "I'm Ada, your personal assistant. I can help you keep track of people and plans.", EX_PASS),
        ("my name is", "My name is Ada. I keep your notes, people and promises in one place.", EX_PASS),
        ("leaks pwg_ tool names", "I can call pwg_people and pwg_commitments to answer that.", EX_FAIL),
        ("leaks memory_store", "I use memory_store to remember facts.", EX_FAIL),
        ("leaks cron_add", "I can schedule reminders with cron_add.", EX_FAIL),
        ("leaks web_fetch", "I can use web_fetch to read pages.", EX_FAIL),
        ("says HTTP request", "I can make an HTTP Request to your Hub.", EX_FAIL),
        ("vocative opening", "Ada, I can help you with your calendar and people.", EX_FAIL),
        ("vocative closing", "What would you like to do next, Ada?", EX_FAIL),
    ]
    for name, text, want in canned:
        _, rc = judge_selfdesc({"turns": [turn(text)]})
        print("  %s  self-description %s -> %s" % ("ok    " if rc == want else "FAIL  ", name,
                                                     {EX_PASS: "PASS", EX_FAIL: "FAIL"}.get(rc, rc)))
        ok &= rc == want
    _, rc = judge_selfdesc({"cannot": "no box"})
    print("  %s  self-description: a missing prerequisite is CANNOT-RUN" % ("ok    " if rc == EX_CANNOT else "FAIL  "))
    ok &= rc == EX_CANNOT
    lat = {"model": "qwen3.5:9b", "ram_gb": 24, "ram_tier": "24-47",
           "turns": [{"question": q, "ttft_s": 1.5, "total_s": 6.0, "answered": True, "error": None} for q in LATENCY_QUESTIONS]}
    _, rc = judge_latency(lat)
    _, rc2 = judge_latency(dict(lat, turns=[dict(t, answered=False, total_s=None) for t in lat["turns"]]))
    print("  %s  latency: measured turns PASS (advisory); no completed turn is CANNOT-RUN" %
          ("ok    " if (rc, rc2) == (EX_PASS, EX_CANNOT) else "FAIL  "))
    ok &= (rc, rc2) == (EX_PASS, EX_CANNOT)
    print("every mutant went red" if ok else "SELF-TEST BROKEN")
    return 0 if ok else 1


def main(argv):
    if len(argv) > 1 and argv[1] == "--self-test":
        return self_test()
    if len(argv) > 1 and argv[1] in ("selfdesc-box", "latency-box"):
        print(json.dumps(box_selfdesc() if argv[1] == "selfdesc-box" else box_latency()))
        return 0
    if len(argv) > 2 and argv[1] in ("judge-selfdesc", "judge-latency"):
        lines, rc = (judge_selfdesc if argv[1] == "judge-selfdesc" else judge_latency)(json.load(open(argv[2])))
        print("\n".join(lines))
        return rc
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
