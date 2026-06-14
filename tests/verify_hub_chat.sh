#!/usr/bin/env bash
# verify_hub_chat.sh -- CUT GATE: the assistant must return a real, full-
# sentence reply over the EXACT WebSocket path the Hub app uses (/ws/chat).
#
# Why this path specifically: every prior "chat fix" hardened the model /
# think-mode layer, which provably already works on the box (the daemon's
# non-streaming /webhook returns full sentences). The regression that keeps
# shipping is a stale/divergent daemon whose *streaming* path truncates the
# reply to a single token ("Hello", "I"). A source unit test cannot catch a
# stale binary, and probing /webhook would PASS while the app stays broken.
# So this gate drives the real /ws/chat WebSocket on the running daemon and
# asserts the rendered reply is a full sentence.
#
# Exit 0 = chat works. Non-zero = BLOCK THE CUT.
set -u
DAEMON_HOST="${OSTLER_DAEMON_HOST:-localhost}"
DAEMON_PORT="${OSTLER_DAEMON_PORT:-8000}"
MIN_WORDS="${OSTLER_CHAT_MIN_WORDS:-4}"
fail() { echo "CHAT GATE FAIL: $*" >&2; exit 1; }

LS=$(/usr/bin/find "$HOME/Library/WebKit/ai.creativemachines.ostler-hub" \
      -name localstorage.sqlite3 2>/dev/null | head -1)
[ -n "$LS" ] || fail "no Hub localStorage (app never launched/paired?)"
TOKEN=$(sqlite3 "$LS" "SELECT quote(value) FROM ItemTable WHERE key='zeroclaw_token';" 2>/dev/null \
  | python3 -c 'import sys
h=sys.stdin.read().strip(); h=h[2:-1] if h.startswith("X"+chr(39)) else h
print(bytes.fromhex(h).decode("utf-16-le")) if h else print("")')
[ -n "$TOKEN" ] || fail "no zeroclaw_token in Hub localStorage"

# Minimal stdlib WebSocket client: connect /ws/chat, send one message,
# accumulate chunks + take the authoritative done.full_response, print it.
TEXT=$(OSTLER_HOST="$DAEMON_HOST" OSTLER_PORT="$DAEMON_PORT" OSTLER_TOK="$TOKEN" python3 - <<'PY'
import os,socket,base64,struct,json,hashlib
host=os.environ["OSTLER_HOST"]; port=int(os.environ["OSTLER_PORT"]); tok=os.environ["OSTLER_TOK"]
s=socket.create_connection((host,port),timeout=120)
key=base64.b64encode(os.urandom(16)).decode()
req=(f"GET /ws/chat HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
     f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
     f"Authorization: Bearer {tok}\r\n\r\n")
s.sendall(req.encode())
buf=b""
while b"\r\n\r\n" not in buf: buf+=s.recv(4096)
if b" 101 " not in buf.split(b"\r\n")[0]:
    print(""); raise SystemExit
def send_text(t):
    p=t.encode(); h=bytearray([0x81]); n=len(p); m=os.urandom(4)
    if n<126: h.append(0x80|n)
    elif n<65536: h.append(0x80|126); h+=struct.pack(">H",n)
    else: h.append(0x80|127); h+=struct.pack(">Q",n)
    h+=m; s.sendall(bytes(h)+bytes(b^m[i%4] for i,b in enumerate(p)))
def frames():
    data=buf.split(b"\r\n\r\n",1)[1]
    while True:
        while len(data)<2: data+=s.recv(4096)
        b0,b1=data[0],data[1]; ln=b1&0x7f; off=2
        if ln==126:
            while len(data)<4: data+=s.recv(4096)
            ln=struct.unpack(">H",data[2:4])[0]; off=4
        elif ln==127:
            while len(data)<10: data+=s.recv(4096)
            ln=struct.unpack(">Q",data[2:10])[0]; off=10
        while len(data)<off+ln: data+=s.recv(4096)
        payload=data[off:off+ln]; data=data[off+ln:]
        op=b0&0x0f
        if op==8: return
        if op in (1,2): yield payload.decode("utf-8","replace")
send_text(json.dumps({"type":"message","content":"In one short sentence, introduce yourself."}))
acc=""; final=None
for raw in frames():
    try: m=json.loads(raw)
    except: continue
    t=m.get("type")
    if t=="chunk": acc+=m.get("content","")
    elif t in ("done","message"):
        final=m.get("full_response") or m.get("content") or acc; break
    elif t=="error": final=""; break
print((final if final is not None else acc).strip())
PY
)
[ -n "$TEXT" ] || fail "empty reply over /ws/chat"
WORDS=$(printf '%s' "$TEXT" | wc -w | tr -d ' ')
[ "$WORDS" -ge "$MIN_WORDS" ] || fail "WS reply truncated to $WORDS word(s) -- the one-token regression. Reply: '$TEXT'"
echo "CHAT GATE PASS: full /ws/chat reply ($WORDS words): $TEXT"
exit 0
