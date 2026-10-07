#!/usr/bin/env python3
"""Does iPhone/Watch conversation capture work end to end on a real Hub? (v1.0.107 #10)

Andy, on conversation capture: CORE to the product. The four-artefact spec
(CLAUDE.md, 2026-05-09) says every human conversation produces summary.md,
transcript.md, todos.md and frontmatter metadata under
~/Documents/Ostler/Conversations/<date>/<slug>-<id>/. Nothing on a box walk
had ever exercised the path a paired iPhone or Watch actually uses: POST
through the TLS companion gateway (:8443, device bearer) to
/api/v1/conversation/process, poll /api/v1/conversation/status/{id}, read the
artefacts back, confirm the conversation is still findable afterwards, and
confirm a second same-day conversation does not clobber the first.

scripts/box_walk_probes/lib/conversation_seed.sh already puts a conversation
through the SAME pipeline, but deliberately bypasses the HTTP API entirely
(invokes `pwg-convo process` as a CLI subprocess in a mktemp dir -- see that
file's own "WHY THE DIRECT CLI" section) because the transcripts-feed and the
device-facing API had problems unrelated to what that seed needed to prove.
That means the device-facing API path -- the one an iPhone or Watch actually
calls -- had NEVER been exercised by any walk instrument. This probe is that
instrument, not a duplicate of the existing seed.

Two halves, kept apart so the judge can be mutation-tested without a box:

  box  -- runs ON the box. Confirmed from source (vendor/cm041/assistant_api/
          ical-server.py and vendor/cm048_pipeline/src/conversation_writer.py,
          both read line-by-line for this probe):
            - POST /api/v1/conversation/process returns 202 with
              {"job_id", "state_url"} on acceptance, or 402 when
              conversation_transcription is subscription-paused
              (_subscription_paused, ical-server.py:7585).
            - GET /api/v1/conversation/status/{id} returns state.json
              verbatim; current_step == "completed" is done,
              failed_step != null is failed (api_conversation_status,
              ical-server.py:3077).
            - The four-artefact folder is
              <Conversations root>/<started_at[:10]>/<slug>-<sha1(id)[:8]>/
              holding summary.md, transcript.md, todos.md, each opening with
              YAML frontmatter carrying conversation_id and privacy_level
              (conversation_writer.py _resolve_folder / _render_frontmatter).
            - GET /api/v1/conversation/{id}/speakers answers 200 or 202 for
              an id the Hub holds, 404 for one it does not
              (api_conversation_speakers, ical-server.py:3106). There is no
              free-text conversation search/list route in this codebase
              (checked: grep for "api/v1/conversation" turns up only
              process, status/{id} and {id}/speakers) -- speakers is the
              best available "is this conversation still known to the Hub"
              instrument, not a claim that a search feature exists.
          NOT CONFIRMED FROM SOURCE (the companion gateway at :8443 is a
          compiled ZeroClaw binary, not vendored into this repo): the exact
          JSON field and header an already-paired device presents on calls
          AFTER /pair. This probe mints a pairing code the same way
          probes/pairing_recovers_without_a_repair_storm.sh does (admin
          token at :8000 -> POST :8443/pair with X-Pairing-Code) and then
          tries each plausible bearer field/header combination, recording
          exactly which one (if any) worked, rather than assuming one
          silently. See lib/conversation_capture_seed.sh for the writer.
  judge(facts) -> rows    pure.

Usage:
  conversation_capture_e2e.py --self-test
  conversation_capture_e2e.py judge FACTS.json
  conversation_capture_e2e.py box ARGS...   (on the box; see box_main)
"""
import hashlib
import json
import os
import re
import sys
import tempfile

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
NA = "N/A"

ARTEFACTS = ("summary", "transcript", "todos")
ARTEFACT_FILES = {"summary": "summary.md", "transcript": "transcript.md", "todos": "todos.md"}

DECLARED = [
    "process: POST /api/v1/conversation/process is accepted through the paired gateway (device bearer, :8443)",
    "status: GET /api/v1/conversation/status/{id} reaches 'completed' through the gateway within budget",
    "artefacts: summary.md, transcript.md and todos.md exist, are non-empty, and carry frontmatter naming this conversation_id",
    "findable: GET /api/v1/conversation/{id}/speakers answers for the conversation after processing (not 404)",
    "isolation: a second same-day conversation gets its own folder, and the first conversation's three artefacts are unchanged",
]
SENTINEL = "conversation-capture: every declared assertion produced a row"


# ---------------------------------------------------------------------------
# Frontmatter + artefact-folder reading. Pure: no network, exercised directly
# against real fixture directories by self_test(), and against the real
# Conversations folder on the box by box_main().
# ---------------------------------------------------------------------------

def _unquote(value):
    v = value.strip()
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        return v[1:-1].replace('\\"', '"').replace('\\\\', '\\')
    return v


def read_frontmatter(text):
    """{key: value} for the leading '---' ... '---' YAML block, scalar lines
    only (nested lists like 'participants:' keep an empty value for that
    key, which is fine: this probe only ever reads conversation_id and
    privacy_level, both single-line scalars in the shipped renderer).
    Returns None if the text does not open with a frontmatter block.
    """
    lines = (text or "").splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    out = {}
    for line in lines[1:]:
        if line.strip() == "---":
            break
        if ":" in line and not line.startswith(" "):
            k, _, v = line.partition(":")
            out[k.strip()] = _unquote(v)
    return out


def check_artefact_folder(folder, expected_id):
    """Read the three artefacts in `folder` and report counts/booleans only.

    `folder` is a pathlib.Path (may not exist). Never returns file content;
    the caller (box_main) must never print it either -- it is the owner's
    conversation, synthetic or not.
    """
    import pathlib
    folder = pathlib.Path(folder)
    out = {"folder_found": folder.is_dir()}
    privacy_present = False
    for key, fname in ARTEFACT_FILES.items():
        p = folder / fname
        exists = p.is_file()
        nonempty = False
        fm_ok = False
        if exists:
            try:
                text = p.read_text(encoding="utf-8")
            except OSError:
                text = ""
            nonempty = len(text.strip()) > 0
            fm = read_frontmatter(text)
            if fm and fm.get("conversation_id") == expected_id:
                fm_ok = True
            if key == "summary" and fm and fm.get("privacy_level"):
                privacy_present = True
        out["{}_exists".format(key)] = exists
        out["{}_nonempty".format(key)] = nonempty
        out["{}_frontmatter_id_ok".format(key)] = fm_ok
    out["privacy_level_present"] = privacy_present
    return out


def find_folder_by_conversation_id(root, conversation_id, date_hint=None):
    """Search `root` (the Conversations dir) for a folder whose summary.md
    frontmatter carries this exact conversation_id. Tries `date_hint` first
    (the fast path -- the real layout is <root>/<date>/<slug>-<hash>/) then
    falls back to every date directory, so a clock-skew or an adapter that
    resolves a different date than the one this probe guessed still gets
    found rather than silently reported missing.
    """
    import pathlib
    root = pathlib.Path(root)
    if not root.is_dir():
        return None
    search_dirs = []
    if date_hint:
        d = root / date_hint
        if d.is_dir():
            search_dirs.append(d)
    for d in sorted(root.iterdir()) if root.is_dir() else []:
        if d.is_dir() and d not in search_dirs:
            search_dirs.append(d)
    for date_dir in search_dirs:
        try:
            children = sorted(date_dir.iterdir())
        except OSError:
            continue
        for folder in children:
            summary = folder / "summary.md"
            if not summary.is_file():
                continue
            try:
                fm = read_frontmatter(summary.read_text(encoding="utf-8"))
            except OSError:
                continue
            if fm and fm.get("conversation_id") == conversation_id:
                return folder
    return None


# ---------------------------------------------------------------------------
# judge: pure
# ---------------------------------------------------------------------------

def judge(f):
    out = []

    def add(name, ok, detail=""):
        out.append((name, ok if ok is None or ok == NA else bool(ok), detail))

    seed_state = f.get("seed_state", "unrun")
    if seed_state != "seeded":
        reason = "NOT MEASURED: the walk did not seed two conversations through the paired gateway (seed state {})".format(seed_state)
        for d in DECLARED:
            add(d, None, reason)
        return out

    c1 = f.get("conv1") or {}
    p1 = c1.get("process") or {}
    accepted1 = p1.get("accepted") is True and bool(p1.get("job_id"))
    if p1.get("paused"):
        add(DECLARED[0], None, "NOT MEASURED: conversation_transcription is paused on this Hub (subscription gate) -- a licence state, not this probe's subject")
    elif accepted1:
        add(DECLARED[0], True, "conversation 1 accepted, job_id issued (http {})".format(p1.get("http_code")))
    else:
        add(DECLARED[0], False, "conversation 1 was not accepted (http {}, error {})".format(p1.get("http_code"), p1.get("error") or "none"))

    if not accepted1:
        for d in DECLARED[1:4]:
            add(d, None, "NOT MEASURED: conversation 1 was never accepted, so nothing downstream of it could be measured")
    else:
        s1 = c1.get("status") or {}
        complete1 = s1.get("reached_complete") is True
        if complete1:
            add(DECLARED[1], True, "reached 'completed' in {}s".format(s1.get("waited_s")))
        else:
            add(DECLARED[1], False, "{} after {}s, last status seen: {}".format(
                "timed out" if s1.get("timed_out") else "did not reach completed",
                s1.get("waited_s"), s1.get("last_status") or "none"))

        if not complete1:
            for d in DECLARED[2:4]:
                add(d, None, "NOT MEASURED: conversation 1 never reached 'completed'")
        else:
            a1 = c1.get("artefacts") or {}
            if not a1.get("folder_found"):
                add(DECLARED[2], False, "no artefact folder was found under Conversations for this conversation_id")
            else:
                miss = []
                for key in ARTEFACTS:
                    fname = ARTEFACT_FILES[key]
                    if not a1.get("{}_exists".format(key)):
                        miss.append("{} missing".format(fname))
                    elif not a1.get("{}_nonempty".format(key)):
                        miss.append("{} present but empty".format(fname))
                    elif not a1.get("{}_frontmatter_id_ok".format(key)):
                        miss.append("{} frontmatter does not carry this conversation_id".format(fname))
                if not a1.get("privacy_level_present"):
                    miss.append("frontmatter carries no privacy_level")
                add(DECLARED[2], not miss, "; ".join(miss) if miss else "summary.md, transcript.md and todos.md all present, non-empty, frontmatter-tagged with this conversation_id")

            find1 = c1.get("findable") or {}
            if not find1.get("attempted"):
                add(DECLARED[3], None, "NOT MEASURED: the findability check was never attempted")
            else:
                add(DECLARED[3], find1.get("found") is True, "GET .../speakers returned http {}".format(find1.get("http_code")))

    c2 = f.get("conv2") or {}
    p2 = c2.get("process") or {}
    s2 = c2.get("status") or {}
    accepted2 = p2.get("accepted") is True and bool(p2.get("job_id"))
    if p2.get("paused"):
        add(DECLARED[4], None, "NOT MEASURED: conversation_transcription is paused on this Hub (subscription gate)")
    elif not accepted2:
        add(DECLARED[4], None, "NOT MEASURED: the second conversation was never accepted")
    elif s2.get("reached_complete") is not True:
        add(DECLARED[4], None, "NOT MEASURED: the second conversation never reached 'completed'")
    else:
        iso = f.get("isolation") or {}
        a2 = c2.get("artefacts") or {}
        miss2 = []
        if iso.get("folders_distinct") is not True:
            miss2.append("the two conversations resolved to the same folder")
        if not a2.get("folder_found"):
            miss2.append("the second conversation's own folder was not found")
        if iso.get("conv1_still_intact") is not True:
            miss2.append("conversation 1's artefacts changed or vanished after the second conversation completed")
        add(DECLARED[4], not miss2, "; ".join(miss2) if miss2 else "both conversations have distinct folders, and conversation 1's three artefacts are unchanged")

    names = [n for n, _, _ in out]
    missing = [x for x in DECLARED if x not in names]
    add(SENTINEL, not missing, ", ".join(missing))
    return out


# ---------------------------------------------------------------------------
# box half: runs on the box
# ---------------------------------------------------------------------------

def _http(method, url, data=None, headers=None, timeout=30, insecure=False):
    import ssl
    import urllib.request
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    ctx = None
    if insecure and url.lower().startswith("https://"):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=timeout, context=ctx) if ctx is not None else opener.open(req, timeout=timeout) as r:
            code = r.getcode()
            body = r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        code = exc.code
        body = exc.read().decode("utf-8", "replace") if exc.fp else ""
    return code, body


def _mint_device_bearer(gateway_https_base, admin_token_path, pairing_code_url, insecure=True):
    """Mint a pairing code (admin, :8000) and spend it at :8443/pair (same
    mechanism as probes/pairing_recovers_without_a_repair_storm.sh). Returns
    (token_or_None, detail_str). The field/header a PAIRED device then
    presents is not confirmed from any source in this repo (the companion
    gateway is a compiled ZeroClaw binary); every plausible field name is
    tried and the one that answered is recorded, never assumed silently.
    """
    try:
        admin = open(os.path.expanduser(admin_token_path)).read().strip()
    except OSError:
        return None, "no readable admin token at {}".format(admin_token_path)
    if not admin:
        return None, "admin token file was empty"
    try:
        code_rc, code_body = _http("POST", pairing_code_url, data=b"",
                                    headers={"Authorization": "Bearer {}".format(admin)}, timeout=10)
    except Exception as exc:
        return None, "could not reach {} ({})".format(pairing_code_url, str(exc)[:80])
    try:
        pairing_code = json.loads(code_body).get("pairing_code")
    except Exception:
        pairing_code = None
    if not pairing_code:
        return None, "gateway did not issue a pairing code (http {}, body {} bytes)".format(code_rc, len(code_body))
    try:
        pair_rc, pair_body = _http("POST", gateway_https_base + "/pair", data=b"",
                                    headers={"X-Pairing-Code": pairing_code}, timeout=10, insecure=insecure)
    except Exception as exc:
        return None, "no answer from {}/pair ({})".format(gateway_https_base, str(exc)[:80])
    if '"paired":true' not in pair_body and '"paired": true' not in pair_body:
        return None, "pair rejected the fresh code (http {}): {}".format(pair_rc, pair_body[:120])
    try:
        parsed = json.loads(pair_body)
    except Exception:
        parsed = {}
    for field in ("token", "device_token", "bearer_token", "access_token", "paired_token"):
        if parsed.get(field):
            return str(parsed[field]), "field '{}' from /pair response".format(field)
    return None, "pair accepted (paired:true) but no recognised token field in the response; tried token/device_token/bearer_token/access_token/paired_token"


def _submit_conversation(gateway_https_base, device_token, transcript, metadata, insecure=True):
    body = json.dumps({"transcript": transcript, "metadata": metadata}).encode("utf-8")
    headers = {"Authorization": "Bearer {}".format(device_token), "Content-Type": "application/json"}
    try:
        rc, resp = _http("POST", gateway_https_base + "/api/v1/conversation/process", data=body, headers=headers, timeout=20, insecure=insecure)
    except Exception as exc:
        return {"accepted": False, "http_code": None, "job_id": None, "paused": False, "error": str(exc)[:120]}
    if rc == 402:
        return {"accepted": False, "http_code": rc, "job_id": None, "paused": True, "error": None}
    try:
        parsed = json.loads(resp)
    except Exception:
        parsed = {}
    job_id = parsed.get("job_id")
    accepted = rc in (200, 202) and bool(job_id)
    return {"accepted": accepted, "http_code": rc, "job_id": job_id, "paused": False,
            "error": None if accepted else (parsed.get("error") or resp[:120])}


def _poll_status(gateway_https_base, device_token, job_id, budget_s=180, poll_s=5, insecure=True):
    import time
    headers = {"Authorization": "Bearer {}".format(device_token)}
    waited = 0
    last_status = "none"
    while waited <= budget_s:
        try:
            rc, resp = _http("GET", gateway_https_base + "/api/v1/conversation/status/" + job_id, headers=headers, timeout=15, insecure=insecure)
            parsed = json.loads(resp) if resp else {}
        except Exception as exc:
            rc, parsed = None, {}
            last_status = "unreadable ({})".format(str(exc)[:60])
        if rc == 200:
            step = parsed.get("current_step")
            failed = parsed.get("failed_step")
            last_status = "current_step={} failed_step={}".format(step, failed)
            if step == "completed":
                return {"reached_complete": True, "timed_out": False, "last_status": last_status, "waited_s": waited}
            if failed:
                return {"reached_complete": False, "timed_out": False, "last_status": last_status, "waited_s": waited}
        time.sleep(poll_s)
        waited += poll_s
    return {"reached_complete": False, "timed_out": True, "last_status": last_status, "waited_s": waited}


def _check_findable(gateway_https_base, device_token, job_id, insecure=True):
    headers = {"Authorization": "Bearer {}".format(device_token)}
    try:
        rc, _ = _http("GET", gateway_https_base + "/api/v1/conversation/" + job_id + "/speakers", headers=headers, timeout=15, insecure=insecure)
    except Exception:
        return {"attempted": True, "http_code": None, "found": False}
    return {"attempted": True, "http_code": rc, "found": rc in (200, 202)}


def _conv_measure(gateway_https_base, device_token, job_id, conversations_root, date_hint, status_budget_s, insecure=True):
    status = _poll_status(gateway_https_base, device_token, job_id, budget_s=status_budget_s, insecure=insecure)
    artefacts = {"folder_found": False}
    findable = {"attempted": False, "http_code": None, "found": False}
    folder = None
    if status.get("reached_complete"):
        folder = find_folder_by_conversation_id(conversations_root, job_id, date_hint=date_hint)
        artefacts = check_artefact_folder(folder, job_id) if folder else {"folder_found": False}
        findable = _check_findable(gateway_https_base, device_token, job_id, insecure=insecure)
    return status, artefacts, findable, folder


def box_main(argv):
    """box --gateway URL --job-id-1 ID --job-id-2 ID
            --device-token-file PATH --conversations-root PATH --date DATE
            --seed-state STATE [--status-budget-s N]

    Reads the device bearer from --device-token-file ITSELF, on the box,
    rather than accepting it as an argument: lib/conversation_capture_seed.sh
    writes that file 0600 at mint time and hands this half only the path, so
    the secret never has to travel through an orchestrator process or a
    remote command line (CLAUDE.md security rule 2). --device-token is kept
    as a fallback for a caller that already holds the value in-process (e.g.
    a test harness), but the file path is preferred when both are given.

    Prints ONE JSON line of facts (counts/booleans only -- never transcript
    text, folder contents or reply prose, matching owner_digest.py's
    discipline for the same reason: this file is the owner's conversation).
    """
    a = dict(zip(argv[0::2], argv[1::2]))
    gateway = a.get("--gateway", "https://127.0.0.1:8443")
    device_token = a.get("--device-token", "")
    token_file = a.get("--device-token-file", "")
    if token_file:
        try:
            device_token = open(os.path.expanduser(token_file)).read().strip()
        except OSError:
            device_token = ""
    root = a.get("--conversations-root", os.path.expanduser("~/Documents/Ostler/Conversations"))
    date_hint = a.get("--date", "")
    budget = int(a.get("--status-budget-s", "180"))
    facts = {"seed_state": a.get("--seed-state", "unrun")}

    job1 = a.get("--job-id-1", "")
    job2 = a.get("--job-id-2", "")

    facts["conv1"] = {"process": {"accepted": bool(job1), "http_code": None, "job_id": job1 or None, "paused": False, "error": None if job1 else "no job id supplied to the box half"}}
    facts["conv2"] = {"process": {"accepted": bool(job2), "http_code": None, "job_id": job2 or None, "paused": False, "error": None if job2 else "no job id supplied to the box half"}}

    if facts["seed_state"] == "seeded" and job1 and device_token:
        status1, artefacts1, findable1, folder1 = _conv_measure(gateway, device_token, job1, root, date_hint, budget)
        facts["conv1"]["status"] = status1
        facts["conv1"]["artefacts"] = artefacts1
        facts["conv1"]["findable"] = findable1

        isolation = {"folders_distinct": None, "conv1_still_intact": None}
        if job2:
            status2, artefacts2, _findable2, folder2 = _conv_measure(gateway, device_token, job2, root, date_hint, budget)
            facts["conv2"]["status"] = status2
            facts["conv2"]["artefacts"] = artefacts2
            if folder1 and folder2:
                isolation["folders_distinct"] = (str(folder1) != str(folder2))
            if folder1:
                recheck1 = check_artefact_folder(folder1, job1)
                isolation["conv1_still_intact"] = all(
                    recheck1.get(k) == artefacts1.get(k) and recheck1.get(k) is True
                    for k in ("summary_exists", "summary_nonempty", "summary_frontmatter_id_ok",
                              "transcript_exists", "transcript_nonempty", "transcript_frontmatter_id_ok",
                              "todos_exists", "todos_nonempty", "todos_frontmatter_id_ok"))
        facts["isolation"] = isolation

    print(json.dumps(facts))
    return 0


# ---------------------------------------------------------------------------
# self-test
# ---------------------------------------------------------------------------

_FIX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fixtures", "conversation_capture_e2e")
CONV1_ID = "2026-10-07_alice_example_bob_example_conversation"
CONV2_ID = "2026-10-07_alice_example_bob_example_meeting"


def _good_artefacts(sub, conv_id):
    import pathlib
    folder = pathlib.Path(_FIX) / sub / "2026-10-07"
    children = [p for p in folder.iterdir()] if folder.is_dir() else []
    if not children:
        return None, None
    return children[0], check_artefact_folder(children[0], conv_id)


def _good():
    folder1, a1 = _good_artefacts("good_conv1", CONV1_ID)
    folder2, a2 = _good_artefacts("good_conv2", CONV2_ID)
    return {
        "seed_state": "seeded",
        "conv1": {
            "process": {"accepted": True, "http_code": 202, "job_id": CONV1_ID, "paused": False, "error": None},
            "status": {"reached_complete": True, "timed_out": False, "last_status": "current_step=completed failed_step=None", "waited_s": 120},
            "artefacts": a1,
            "findable": {"attempted": True, "http_code": 200, "found": True},
        },
        "conv2": {
            "process": {"accepted": True, "http_code": 202, "job_id": CONV2_ID, "paused": False, "error": None},
            "status": {"reached_complete": True, "timed_out": False, "last_status": "current_step=completed failed_step=None", "waited_s": 130},
            "artefacts": a2,
        },
        "isolation": {"folders_distinct": True, "conv1_still_intact": True},
    }, folder1, folder2


def self_test():
    import copy
    fails = []

    def row(f, i):
        return [ok for n, ok, _ in judge(f) if n == DECLARED[i]]

    g, folder1, folder2 = _good()
    if folder1 is None or folder2 is None:
        print("SELF-TEST CANNOT-RUN: the good fixtures are missing from " + _FIX)
        return EX_CANNOT
    if any(ok is not True for n, ok, _ in judge(g) if n != SENTINEL) or judge(g)[-1][1] is not True:
        print("SELF-TEST BROKEN: the good fixture fails: {}".format([(n, d) for n, ok, d in judge(g) if ok is not True]))
        return EX_FAIL
    print("  ok    good fixture (both real conversation folders): every assertion passes")

    # THE MANDATED MUTANT: a real fixture folder with todos.md deliberately
    # missing must FAIL (a), not CANNOT-RUN and not a silent pass.
    missing_path, missing_artefacts = _good_artefacts("missing_todos", CONV1_ID)
    if missing_path is None:
        print("SELF-TEST CANNOT-RUN: the missing_todos fixture is missing from " + _FIX)
        return EX_CANNOT
    bad = copy.deepcopy(g)
    bad["conv1"]["artefacts"] = missing_artefacts
    if row(bad, 2) != [False]:
        fails.append("conversation with todos.md missing: (artefacts) {} (want [False])".format(row(bad, 2)))
    else:
        print("  ok    MANDATED MUTANT: todos.md missing from a real fixture folder FAILS the artefacts assertion")
    if missing_artefacts.get("todos_exists") is not False:
        fails.append("check_artefact_folder did not itself notice todos.md is missing: {}".format(missing_artefacts))
    else:
        print("  ok    check_artefact_folder's own read reports todos_exists=False for the mutant folder")

    # Frontmatter without conversation_id: synthesised in a tmp dir (not a
    # tracked fixture -- it is a string mutation of the good one, same
    # pattern as owner_digest.py's WORK_LINE.sub).
    with tempfile.TemporaryDirectory() as tmp:
        import pathlib
        tmp = pathlib.Path(tmp)
        for name in ("summary.md", "transcript.md", "todos.md"):
            text = (folder1 / name).read_text(encoding="utf-8")
            text = text.replace('conversation_id: "{}"'.format(CONV1_ID), 'conversation_id: "wrong-id"')
            (tmp / name).write_text(text, encoding="utf-8")
        wrong_id_artefacts = check_artefact_folder(tmp, CONV1_ID)
        bad2 = copy.deepcopy(g)
        bad2["conv1"]["artefacts"] = wrong_id_artefacts
        if row(bad2, 2) != [False]:
            fails.append("frontmatter with the wrong conversation_id: (artefacts) {} (want [False])".format(row(bad2, 2)))
        else:
            print("  ok    mutant caught: frontmatter carries a different conversation_id")

    mutants = [
        ("process rejected (not accepted)", 0, lambda f: f["conv1"]["process"].update(accepted=False, job_id=None, http_code=500, error="internal error")),
        ("status never reaches completed (timeout)", 1, lambda f: f["conv1"]["status"].update(reached_complete=False, timed_out=True, last_status="current_step=02_classify")),
        ("findable check gets a 404", 3, lambda f: f["conv1"]["findable"].update(found=False, http_code=404)),
        ("the two conversations share one folder", 4, lambda f: f["isolation"].update(folders_distinct=False)),
        ("conversation 1 changed after conversation 2 landed", 4, lambda f: f["isolation"].update(conv1_still_intact=False)),
    ]
    for name, i, mutate in mutants:
        f = copy.deepcopy(g)
        mutate(f)
        if row(f, i) != [False]:
            fails.append("{} not caught by its own assertion ({})".format(name, row(f, i)))
        else:
            print("  ok    mutant caught: {}".format(name))

    # Honest gaps: paused, unseeded, unaccepted and never-completed are
    # CANNOT-RUN, never a pass and never a fail.
    paused = copy.deepcopy(g); paused["conv1"]["process"].update(paused=True, accepted=False, job_id=None)
    unseeded = copy.deepcopy(g); unseeded["seed_state"] = "skipped-read-only"
    never_accepted2 = copy.deepcopy(g); never_accepted2["conv2"]["process"].update(accepted=False, job_id=None)
    checks = [
        (row(paused, 0), [None], "conversation_transcription paused is CANNOT-RUN, not a FAIL"),
        (row(unseeded, 0), [None], "an unseeded walk is CANNOT-RUN for every assertion"),
        (row(never_accepted2, 4), [None], "a second conversation that was never accepted is CANNOT-RUN for isolation, not a FAIL"),
    ]
    for got, want, label in checks:
        if got != want:
            fails.append("{}: got {}".format(label, got))
        else:
            print("  ok    " + label)

    if [ok for n, ok, _ in judge({}) if ok is True]:
        fails.append("an empty collection reads as a pass")

    if fails:
        print("SELF-TEST FAIL: " + "; ".join(fails))
        return EX_FAIL
    print("SELF-TEST PASS: good fixture passes, the mandated missing-artefact mutant FAILs, {} further mutants each caught by their own assertion".format(len(mutants) + 1))
    return EX_PASS


def report(rows):
    for name, ok, detail in rows:
        tag = "  N/A   " if ok == NA else ("  ok    " if ok is True else ("  CANNOT " if ok is None else "  FAIL  "))
        print(tag + name + ("" if ok is True or not detail else "  -- " + detail))
    fails = [n for n, ok, _ in rows if ok is False]
    cannot = [n for n, ok, _ in rows if ok is None]
    print("EXAMINED: {} conversation-capture assertions ({} failed, {} not measured)".format(len(rows), len(fails), len(cannot)))
    return EX_FAIL if fails else (EX_CANNOT if cannot else EX_PASS)


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    if argv[:1] == ["judge"]:
        return report(judge(json.load(open(argv[1]))))
    if argv[:1] == ["box"]:
        return box_main(argv[1:])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
