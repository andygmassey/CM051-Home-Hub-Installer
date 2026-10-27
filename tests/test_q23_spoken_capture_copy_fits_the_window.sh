#!/usr/bin/env bash
# Q23 ("Turn spoken conversations into text?") must keep its toggle on screen.
# The GUI body (ViewCopy.json consent_spoken_capture) sits in a ScrollView above
# the toggle; the long intro and bullets pushed the toggle below the fold at the
# default 880x620 window (117 blocker, 2026-10-22). Pins the shortened visible
# copy exactly, the legal note byte for byte (sha256), and that no em dash
# appears. Copy only: no layout is asserted or touched here.
#
# Since 2026-10-24 the legal note is composed per REGION from legal_* keys
# (LegalRegion.spokenCaptureLegalNote). The sha now covers every legal_* key,
# and the LONGEST composed note (DE: core + local + EU + DE + responsibility)
# must stay within LEGAL_MAX characters. The single region-blind note it
# replaced was 829; LEGAL_MAX allows under one extra caption line.
#
# Self-test first: the predicate must reject the pre-fix copy.
set -euo pipefail
cd "$(dirname "$0")/.."
VC=gui/OstlerInstaller/Resources/ViewCopy.json
LEGAL_SHA=75f4d9c5ed653bbdc492edd18c65902378d7df981ae7519841dd3a2104194bb0
LEGAL_MAX=900

check() { # $1 file
    python3 -I - "$1" "$LEGAL_SHA" "$LEGAL_MAX" <<'PY'
import hashlib, json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))["consent_spoken_capture"]
want = {
    "intro_body": "Ostler can turn calls and meetings you capture into searchable text, here on your Mac.",
    "ask_heading": "What we ask of you:",
    "bullet_1": "Get any consent your local law requires before you capture a conversation.",
    "bullet_2": "Tell people audio is being captured, or keep a visible indicator on.",
    "bullet_3": "If in doubt, leave this off. You can turn it on later in Settings.",
}
bad = [k for k, v in want.items() if d.get(k) != v]
if bad:
    print("FAIL copy differs for: " + ", ".join(bad)); sys.exit(1)
lk = sorted(k for k in d if k.startswith("legal_"))
if hashlib.sha256("\n".join(k + "=" + d[k] for k in lk).encode()).hexdigest() != sys.argv[2]:
    print("FAIL legal_* copy changed"); sys.exit(1)
base = [d["legal_prefix"], d["legal_core"], d["legal_local"]]
longest = max(
    len(" ".join(base + [d["legal_region_" + r] for r in regs] + [d["legal_responsibility"]]))
    for regs in ([], ["gb"], ["eu"], ["eu", "de"], ["eu", "fr"], ["hk"], ["us"])
)
if longest > int(sys.argv[3]):
    print(f"FAIL longest composed legal note is {longest} chars, over {sys.argv[3]}"); sys.exit(1)
if any("—" in v for v in d.values()):
    print("FAIL em dash in copy"); sys.exit(1)
print("PASS")
PY
}

old="$(mktemp -d)/old.json"
python3 -I - "$VC" "$old" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["consent_spoken_capture"]["intro_body"] = "Ostler can turn spoken audio you capture \u2013 calls and meetings \u2013 into searchable text. Typing and messaging are unaffected. Getting any consent the law requires is your responsibility, not ours."
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"))
PY
if check "$old" >/dev/null; then
    echo "FAIL self-test: predicate accepted the pre-fix copy"; exit 1
fi
echo "PASS self-test: pre-fix copy rejected"
long="$(mktemp -d)/long.json"
python3 -I - "$VC" "$long" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["consent_spoken_capture"]["legal_region_de"] += " " + "x" * 200
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"))
PY
if check "$long" >/dev/null; then
    echo "FAIL self-test: predicate accepted an over-long legal note"; exit 1
fi
echo "PASS self-test: over-long legal note rejected"
check "$VC"
