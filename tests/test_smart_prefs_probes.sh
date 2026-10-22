#!/usr/bin/env bash
# tests/test_smart_prefs_probes.sh
# ============================================================================
# The five BLOCKING Smart Preferences walk probes (v1.0.118), driven END TO END:
# the real probe scripts, the real staging, the real box-side reader and the
# real judge, against fake Qdrant / Oxigraph / Hub / gateway servers and a
# stubbed `launchctl`, in a scratch HOME. OSTLER_BOX_HOST is unset (this
# machine, the suite contract) and the real run_box_walk.sh is only ever run
# with --read-only here, so nothing touches a real store or LaunchAgent.
#
# ENGINE STUBS, because a probe is believed only when it has gone red:
#   v116       what v1.0.116 does: films only, no stated reader, no pyyaml. All
#              five probes must go RED (FAIL, not CANNOT-RUN).
#   intended   the spec: ten broad categories, a stated dislike is negative, the
#              owner's own like derives, another person's like does not, the
#              brief uses likes and leaves the dislike out. All five PASS.
#   leak       intended with ONE defect (another person's like leaked to the
#              owner); brief_bad: a brief that names the disliked thing. Only
#              that probe may go red: proof the passes are not unconditional.
#
# WHAT THE STUB CANNOT PROVE, said once: the engine here is a stand-in. That the
# REAL derive engine produces these outputs from the same fixture is
# `lib/smart_prefs.py engine-check <tree>` (run against main, CM051 #3116 and
# #3117 in the PR body); that the box has pyyaml is the probe, on the box.
#
# Exit 0 pass, 1 fail, 2 cannot-run. Bash 3.2.
# ============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBES="$REPO/scripts/box_walk_probes/probes"
LIB="$REPO/scripts/box_walk_probes/lib"
RUNNER="$REPO/scripts/box_walk_probes/run_box_walk.sh"
PY="$(command -v python3 || true)"
[ -n "$PY" ] && [ -f "$RUNNER" ] || { echo "CANNOT-RUN: python3 or the runner is missing"; exit 2; }
NAMES="derived_preferences_runs derived_preferences_breadth derived_preferences_dislike derived_preferences_not_others dislike_respected_in_brief"
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
echo "test_smart_prefs_probes"

WORK="$(mktemp -d)"; SRVPID=""
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "CANNOT-RUN: mktemp"; exit 2; }
trap '[ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null; rm -rf "$WORK"' EXIT

# ---- the fake stores + Hub + gateway, one process ---------------------------
cat > "$WORK/fake.py" <<'PYEOF'
import http.server, json, os, re, sys, time, urllib.parse
MODE = sys.argv[2]; HOME = sys.argv[3]
S = {"tags": set(), "jobs": {}, "posted_delivery": [], "deleted": [], "points": {}, "facts": [], "derived": [{"dimension": "media.film.genre", "label": "science fiction", "strength": 0.7, "confidence": 0.8}], "n": 0}
CATS = {"tv_show": "media.tv.series", "music": "media.music.artist", "podcast": "media.podcast.show", "bookmark": "web.site",
        "place": "place.city", "product": "commerce.brand", "food": "food.restaurant", "fitness": "health.activity", "professional": "work.skill",
        "movie": "media.film.genre", "book": "media.book.genre", "interest": "interests.topic"}
def derive():
    items = [S["derived"][0]]
    if MODE != "v116":
        seen = set()
        for p in S["points"].values():
            pl = p["payload"]; dim = CATS.get(pl["category"])
            ex = pl.get("extra") or {}
            v = next(iter(ex.values())) if ex else pl["subject"]
            if dim and (dim, v) not in seen:
                seen.add((dim, v)); items.append({"dimension": dim, "label": v, "strength": 0.7, "confidence": 0.7})
        items.append({"dimension": "news.source", "label": "bbc.com", "strength": 0.6, "confidence": 0.6})
        for f in S["facts"]:
            owner = f["about"].startswith("urn:ostler:user/")
            if not owner and MODE != "leak":
                continue
            t = f["text"].lower()
            for word, dim, label in (("coriander", "food.ingredient", "Coriander"), ("sichuan", "food.cuisine", "Sichuan"), ("jazz", "media.music.genre", "Jazz")):
                if word in t and not any(i["label"] == label for i in items):
                    items.append({"dimension": dim, "label": label, "strength": -0.74 if "can't stand" in t else 0.74, "confidence": 0.7})
    S["derived"] = items
    S["n"] += 1
    st = os.path.join(HOME, ".ostler", "state"); os.makedirs(st, exist_ok=True)
    json.dump({"schema": 1, "last_run_at": "2026-10-22T00:00:%02dZ" % S["n"], "outcome": "written", "graph_node_count": len(items), "reason": ""},
              open(os.path.join(st, "derived-preferences.json"), "w"))
    lg = os.path.join(HOME, ".ostler", "logs"); os.makedirs(lg, exist_ok=True)
    open(os.path.join(lg, "derive-preferences.log"), "a").write("[x] tick finished: written (see state/derived-preferences.json)\n")
BROAD3 = ("media.tv", "media.music", "web")
def cat_ok(dim): return dim.startswith(BROAD3)
def derived_for(q):
    tier = (urllib.parse.parse_qs(q).get("tier") or [""])[0]
    items = S["derived"]
    if MODE not in ("tiered", "tiered_few", "fallback"):
        return {"items": items, "degraded": False}          # a route that predates tiers ignores ?tier=
    if tier == "broad":
        if MODE == "fallback":
            return {"items": items, "degraded": False, "tier": "all", "tier_fallback": True}
        keep = items if MODE == "tiered" else [i for i in items if cat_ok(i["dimension"])]
        return {"items": keep, "degraded": False, "tier": "broad"}
    return {"items": items, "degraded": False, "tier": "all"}
def brief():
    base = "Today: meetings and one open promise. "
    if MODE == "brief_bad": return base + "For dinner, try the coriander salad."
    if MODE == "v116": return base + "Nothing else to report."
    return base + "You might enjoy some Sichuan food tonight."
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj=None):
        b = json.dumps(obj).encode() if obj is not None else b""
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def body(self):
        n = int(self.headers.get("Content-Length") or 0); return self.rfile.read(n) if n else b""
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/collections/preferences": return self.send(200, {"result": {"config": {"params": {"vectors": {"size": 4}}}}})
        if u.path == "/api/v1/preferences/derived":
            if self.headers.get("Authorization") != "Bearer tok": return self.send(401, {})
            return self.send(200, derived_for(u.query))
        if u.path == "/query":
            q = urllib.parse.parse_qs(u.query)["query"][0]
            n = len(S["tags"]) if "smartprefs/tag" in q else len(S["facts"])
            return self.send(200, {"results": {"bindings": [{"n": {"value": str(n)}}]}})
        if u.path == "/__jobs": return self.send(200, {"live": list(S["jobs"]), "posted_delivery": S["posted_delivery"], "deleted": S["deleted"]})
        m = re.match(r"/api/cron/(\w+)$", u.path)
        if m: return self.send(200, {"job": S["jobs"][m.group(1)]}) if m.group(1) in S["jobs"] else self.send(404, {})
        if re.match(r"/api/cron/\w+/runs", u.path): return self.send(200, {"runs": [{"status": "ok", "output": brief()}]})
        if u.path == "/__derive": derive(); return self.send(200, {})
        self.send(404, {})
    def do_PUT(self):
        for p in json.loads(self.body())["points"]: S["points"][p["id"]] = p
        self.send(200, {"result": {"status": "ok"}})
    def do_POST(self):
        u = urllib.parse.urlparse(self.path); raw = self.body()
        if u.path.endswith("/points/count"): return self.send(200, {"result": {"count": sum(1 for p in S["points"].values() if p["payload"].get("walk_fixture"))}})
        if u.path.endswith("/points/delete"): S["points"].clear(); return self.send(200, {})
        if u.path == "/update":
            q = raw.decode()
            if q.startswith("INSERT DATA") and "GRAPH <" not in q:
                S["tags"] |= set(re.findall(r"<(urn:ostler-walk-fixture:smartprefs/tag/[^>]+)> <http://www.w3.org/2000/01/rdf-schema#label>", q))
            elif q.startswith("INSERT DATA"):
                for m in re.finditer(r"<urn:ostler:about> <([^>]+)>.*?<urn:ostler:text> \"((?:[^\"\\]|\\.)*)\"", q):
                    S["facts"].append({"about": m.group(1), "text": m.group(2)})
            if q.startswith("DROP"): S["facts"].clear()
            if q.startswith("DELETE"): S["tags"].clear()
            return self.send(204)
        if u.path == "/api/cron":
            b = json.loads(raw); S["jn"] = S.get("jn", 0) + 1; jid = "j%d" % S["jn"]
            S["posted_delivery"].append(b.get("delivery"))
            # delivery_ignored: a gateway that drops the field and defaults to announcing
            b["delivery"] = {"mode": "announce"} if MODE == "delivery_ignored" else b.get("delivery")
            b["id"] = jid; S["jobs"][jid] = b
            return self.send(200, {"job": {"id": jid}})
        self.send(404, {})
    def do_DELETE(self):
        m = re.match(r"/api/cron/(\w+)$", self.path)
        if m: S["jobs"].pop(m.group(1), None); S["deleted"].append(m.group(1))
        self.send(200, {})
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF

# stub launchctl: kickstart runs the fake engine's derive pass; anything else is refused loudly
printf '#!/bin/sh\n[ "$1" = kickstart ] || { echo "stub launchctl: unexpected $*" >&2; exit 64; }\nexec "%s" -c "import urllib.request,os;urllib.request.build_opener(urllib.request.ProxyHandler({})).open(\x27http://127.0.0.1:\x27+os.environ[\x27FAKE_PORT\x27]+\x27/__derive\x27,timeout=10).read()"\n' "$PY" > "$WORK/launchctl"
chmod +x "$WORK/launchctl"

start() { # $1 = mode; fresh scratch HOME and servers; exports the environment the probes read
    [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null
    H="$WORK/home-$1-$RANDOM"; PORT=$((20000 + RANDOM % 20000))
    mkdir -p "$H/.ostler/secrets" "$H/.ostler/assistant-config" "$H/Library/LaunchAgents" "$H/.ostler/services/cm019/.venv/bin" "$H/.ostler/state"
    printf tok > "$H/.ostler/secrets/service_token"; printf adm > "$H/.ostler/secrets/zeroclaw_admin_token"
    : > "$H/Library/LaunchAgents/com.ostler.derive-preferences.plist"
    printf '[[cron.jobs]]\nid = "morning-brief"\nprompt = "Give me today and my promises."\n' > "$H/.ostler/assistant-config/config.toml"
    # The venv interpreter. The IMPORT lines are emulated at this boundary (v116:
    # the box has no pyyaml and no derive tree); everything else is real python.
    local vpy="$H/.ostler/services/cm019/.venv/bin/python3" imp='*"import yaml"*|*services.enrich.src.derive*|*"import pyshacl"*'
    if [ "$1" = v116 ]; then
        printf '#!/bin/sh\ncase "$*" in %s) echo "ModuleNotFoundError: No module named yaml" >&2; exit 1;; esac\nexec "%s" "$@"\n' "$imp" "$PY" > "$vpy"
    else
        printf '#!/bin/sh\ncase "$*" in %s) exit 0;; esac\nexec "%s" "$@"\n' "$imp" "$PY" > "$vpy"
    fi
    chmod +x "$vpy"
    "$PY" "$WORK/fake.py" "$PORT" "$1" "$H" & SRVPID=$!
    sleep 1
    export HOME="$H" FAKE_PORT="$PORT" OSTLER_BOX_HOST= OSTLER_HUB_URL="http://127.0.0.1:$PORT" OSTLER_QDRANT_URL="http://127.0.0.1:$PORT" \
        OSTLER_OXIGRAPH_URL="http://127.0.0.1:$PORT" OSTLER_PROBE_GATEWAY="http://127.0.0.1:$PORT" OSTLER_SMARTPREFS_LAUNCHCTL="$WORK/launchctl" \
        OSTLER_SMARTPREFS_POLL_S=0.2 OSTLER_SMARTPREFS_DERIVE_BUDGET_S=20 OSTLER_SMARTPREFS_BRIEF_POLL_S=0.2 OSTLER_SMARTPREFS_BRIEF_WAIT_S=20
}
verdicts() { # runs the five probes; V_<name> = PASS|FAIL|CANNOT-RUN ; OUT_<name> = the probe's output
    local n out v
    for n in $NAMES; do
        out="$(bash "$PROBES/$n.sh" 2>&1)"
        v="$(printf '%s\n' "$out" | sed -n 's/^VERDICT: \([A-Z-]*\) .*/\1/p' | tail -1)"
        eval "V_$n=\"\$v\""
        eval "OUT_$n=\$out"
    done
}
seed() { # sources the real lib and applies it, as the runner does
    # shellcheck source=/dev/null
    . "$LIB/smart_prefs_seed.sh"
    SEED_OUT="$(smart_prefs_seed_apply 2>&1)"
    # the function ran in a subshell: read its marker the way a probe would, and set the env as the runner does
    if printf '%s' "$SEED_OUT" | /usr/bin/grep -q '^  SEEDED '; then SEED_STATE=seeded; else SEED_STATE="failed"; fi
    export OSTLER_SMARTPREFS_SEED_STATE="$SEED_STATE"
}
want() { # $1 name, $2 expected verdict
    local got; eval "got=\$V_$1"
    if [ "$got" = "$2" ]; then ok "$1 -> $2"
        # the reason, so a red is seen to be red for the RIGHT reason
        [ "$2" = PASS ] || eval "printf '%s\n' \"\$OUT_$1\"" | /usr/bin/grep -E '^  (FAIL|CANNOT) ' | cut -c1-210 | sed 's/^/         /'
    else bad "$1 expected $2, got '${got}'"; eval "printf '%s\n' \"\$OUT_$1\"" | tail -6 | sed 's/^/         /'; fi
}

# ---- S1: v1.0.116 -----------------------------------------------------------
start v116; seed
[ "$SEED_STATE" = seeded ] && ok "S1 seed lib: fixture written, read back, derive kicked" || bad "S1 seed did not complete: $SEED_OUT"
verdicts
echo "  -- S1: v1.0.116 behaviour (films only, no pyyaml, no stated reader): all five must be FAIL, none CANNOT-RUN"
for n in $NAMES; do want "$n" FAIL; done

# ---- S2: intended -----------------------------------------------------------
start intended; seed
[ "$SEED_STATE" = seeded ] && ok "S2 seed lib completed" || bad "S2 seed did not complete: $SEED_OUT"
verdicts
echo "  -- S2: intended behaviour: all five must PASS"
for n in $NAMES; do want "$n" PASS; done

# ---- S3: one defect each ----------------------------------------------------
start leak; seed; verdicts
echo "  -- S3a: another person's like leaks to the owner: only derived_preferences_not_others goes red"
for n in derived_preferences_runs derived_preferences_breadth derived_preferences_dislike dislike_respected_in_brief; do want "$n" PASS; done
want derived_preferences_not_others FAIL
start brief_bad; seed; verdicts
echo "  -- S3b: the brief names the disliked thing: only dislike_respected_in_brief goes red"
for n in derived_preferences_runs derived_preferences_breadth derived_preferences_dislike derived_preferences_not_others; do want "$n" PASS; done
want dislike_respected_in_brief FAIL

# ---- S2b: the brief job was created undelivered and left nothing behind -----------
start intended; seed; verdicts
JOBS="$(curl -s --noproxy '*' "http://127.0.0.1:$PORT/__jobs")"
printf '%s' "$JOBS" | /usr/bin/grep -q '"posted_delivery": \[{"mode": "none"}\]' && ok "S2b the probe POSTed delivery {mode: none} explicitly" || bad "S2b delivery not sent as none: $JOBS"
printf '%s' "$JOBS" | /usr/bin/grep -q '"live": \[\]' && ok "S2b the job is deleted after the run" || bad "S2b a cron job was left behind: $JOBS"

# ---- S8: tiers. Breadth uses the served tier; the fallback is labelled -----------
start tiered; seed; verdicts
echo "  -- S8a: route serves tier=broad with 10 categories: breadth PASS, via the served tier"
want derived_preferences_breadth PASS
printf '%s\n' "$OUT_derived_preferences_breadth" | /usr/bin/grep -q "the route served tier=broad" && ok "S8a output labels the tier source" || bad "S8a tier source not labelled"
want derived_preferences_dislike PASS
start tiered_few; seed; verdicts
echo "  -- S8b: tier=broad holds only 3 categories although 10 exist overall: breadth FAIL (a category count would have passed)"
want derived_preferences_breadth FAIL
start fallback; seed; verdicts
echo "  -- S8c: tier_fallback (graph predates tiers) is NOT broad: breadth FAIL naming it"
want derived_preferences_breadth FAIL
printf '%s\n' "$OUT_derived_preferences_breadth" | /usr/bin/grep -q "tier_fallback" && ok "S8c names tier_fallback" || bad "S8c tier_fallback not named"
start intended; seed; verdicts
printf '%s\n' "$OUT_derived_preferences_breadth" | /usr/bin/grep -q "NO TIER in the payload" && ok "S8d an older route falls back to the category count and SAYS so" || bad "S8d fallback not labelled"

# ---- S9: a gateway that ignores the delivery field: the probe refuses ---------------
start delivery_ignored; seed; verdicts
echo "  -- S9: gateway stores delivery=announce: dislike_respected_in_brief is CANNOT-RUN (REFUSED) and the job is deleted"
want dislike_respected_in_brief CANNOT-RUN
printf '%s\n' "$OUT_dislike_respected_in_brief" | /usr/bin/grep -q "REFUSED" && ok "S9 the refusal is named" || bad "S9 no REFUSED in output"
JOBS="$(curl -s --noproxy '*' "http://127.0.0.1:$PORT/__jobs")"
printf '%s' "$JOBS" | /usr/bin/grep -q '"live": \[\]' && ok "S9 the job was deleted before it could fire" || bad "S9 job left live: $JOBS"

# ---- S10: a walk killed mid-wait leaves no job: the seed cleanup deletes it by id --------
start intended; seed
JID="$(curl -s --noproxy '*' -X POST -d '{"delivery":{"mode":"none"}}' "http://127.0.0.1:$PORT/api/cron" | sed -n 's/.*"id": "\([a-z0-9]*\)".*/\1/p')"
[ -n "$JID" ] && ok "S10 a job exists to be orphaned ($JID)" || bad "S10 could not create the job"
printf '{"job": "%s"}' "$JID" > "$HOME/.ostler/state/smartprefs-brief-job.json"
SMARTPREFS_SEED_STATE=seeded
( smart_prefs_seed_forget >/dev/null 2>&1 )
JOBS="$(curl -s --noproxy '*' "http://127.0.0.1:$PORT/__jobs")"
printf '%s' "$JOBS" | /usr/bin/grep -q '"live": \[\]' && [ ! -e "$HOME/.ostler/state/smartprefs-brief-job.json" ] \
    && ok "S10 forget deleted the recorded brief job by id and removed its marker" || bad "S10 job or marker survived forget: $JOBS"
# and the abort trap really calls the same forget (already pinned in S7: both cleanup lists)

# ---- S4: no seed => CANNOT-RUN naming it, never a pass or a silent fail ------
start intended
unset OSTLER_SMARTPREFS_SEED_STATE
verdicts
echo "  -- S4: the fixture was never seeded: the four fixture probes are CANNOT-RUN"
for n in derived_preferences_breadth derived_preferences_dislike derived_preferences_not_others dislike_respected_in_brief; do want "$n" CANNOT-RUN; done
printf '%s\n' "$OUT_derived_preferences_breadth" | /usr/bin/grep -q "seed fixture is on the box" && ok "S4 the CANNOT-RUN names the missing fixture" || bad "S4 reason not named"

# ---- S5: forget removes it --------------------------------------------------
start intended; seed
SMARTPREFS_SEED_STATE=seeded
smart_prefs_seed_forget >/dev/null 2>&1
verdicts
echo "  -- S5: after the forget the fixture is gone (CANNOT-RUN, not a stale pass)"
want derived_preferences_breadth CANNOT-RUN

# ---- S6: the real runner collects and invokes all five ------------------------
start v116; unset OSTLER_SMARTPREFS_SEED_STATE
LISTED="$(bash "$RUNNER" --list 2>&1)"
n=0; for p in $NAMES; do printf '%s\n' "$LISTED" | /usr/bin/grep -q "$p" && n=$((n+1)); done
[ "$n" -eq 5 ] && ok "S6 run_box_walk.sh --list names all five probes (the probes/ glob collects them)" || bad "S6 runner lists $n of 5"
RUNOUT="$(bash "$RUNNER" --only derived_preferences_breadth,derived_preferences_dislike,derived_preferences_not_others,derived_preferences_runs,dislike_respected --read-only 2>&1)"
inv=0; for p in $NAMES; do printf '%s\n' "$RUNOUT" | /usr/bin/grep -q "$p" && inv=$((inv+1)); done
[ "$inv" -eq 5 ] && ok "S6 the real runner (--read-only) invoked all five and reported each by name" || bad "S6 runner reported $inv of 5: $(printf '%s' "$RUNOUT" | tail -5)"
printf '%s\n' "$RUNOUT" | /usr/bin/grep -qE '^  PASS +[1-9]' && bad "S6 a probe PASSED with no seed under --read-only" || ok "S6 nothing passed without the seed (read-only run)"
printf '%s\n' "$RUNOUT" | /usr/bin/grep -q "SKIPPED (read-only): smart-preferences seed not applied" && ok "S6 read-only skips the seed and says so" || bad "S6 read-only seed skip not announced"

# ---- S7: wiring in the runner ----------------------------------------------
L_SRC=$(/usr/bin/grep -n '^\. "\$HERE/lib/smart_prefs_seed.sh"' "$RUNNER" | head -1 | cut -d: -f1)
L_APPLY=$(/usr/bin/grep -n '^smart_prefs_seed_apply' "$RUNNER" | head -1 | cut -d: -f1)
L_LOOP=$(/usr/bin/grep -n -e '--- PHASE 2: measurements ---' "$RUNNER" | head -1 | cut -d: -f1)
if [ -n "$L_SRC" ] && [ -n "$L_APPLY" ] && [ -n "$L_LOOP" ] && [ "$L_SRC" -lt "$L_APPLY" ] && [ "$L_APPLY" -lt "$L_LOOP" ]; then
    ok "S7 the runner sources the lib ($L_SRC) and applies it ($L_APPLY) above the phase-2 loop ($L_LOOP)"
else
    bad "S7 wiring order: src=$L_SRC apply=$L_APPLY loop=$L_LOOP"
fi
[ "$(/usr/bin/grep -c 'smart_prefs_seed_forget' "$RUNNER")" -ge 2 ] && ok "S7 forget is in both the abort trap and the normal path" || bad "S7 forget is not in both cleanup lists"

echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
