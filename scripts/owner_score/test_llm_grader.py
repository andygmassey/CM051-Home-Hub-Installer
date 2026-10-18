#!/usr/bin/env python3
"""Offline tests for llm_grader.py. No network, no SDK, no key: make_client is stubbed.
Run: python3 -I scripts/owner_score/test_llm_grader.py"""
import io, json, os, sys, tempfile, contextlib, types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import llm_grader as G  # noqa: E402

FAIL = []


def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        FAIL.append(name)


class Stub:
    """Records batch creates; serves canned results."""
    def __init__(self, results=None):
        self.created = []
        self.results_data = results or []
        outer = self

        class B:
            def create(self, requests):
                outer.created.append(requests)
                return types.SimpleNamespace(id="msgbatch_stub")

            def retrieve(self, bid):
                return types.SimpleNamespace(processing_status="ended", request_counts=types.SimpleNamespace(processing=0, succeeded=len(outer.results_data), errored=0, expired=0))

            def results(self, bid):
                return iter(outer.results_data)
        self.messages = types.SimpleNamespace(batches=B())


def ok_result(cid, grade, usage=(100, 50, 1000, 200)):
    msg = types.SimpleNamespace(model="claude-sonnet-5-5", stop_reason="end_turn",
                                usage=types.SimpleNamespace(input_tokens=usage[0], cache_creation_input_tokens=usage[1], cache_read_input_tokens=usage[2], output_tokens=usage[3]),
                                content=[types.SimpleNamespace(type="text", text=json.dumps(grade))])
    return types.SimpleNamespace(custom_id=cid, result=types.SimpleNamespace(type="succeeded", message=msg))


def grade(verdict, made_up=False, non=False):
    return {"needed_lookup": True, "verdict": verdict, "made_up_facts": made_up, "non_answer": non, "persona_leakage": False,
            "misattributed_context": False, "evidence": "", "rationale": "r"}


def item(i, h, reply="I could not find that."):
    return {"item_id": f"S|m|q{i}", "source": "S", "setting": "empty_tools", "model": "m", "run": "m", "qid": f"q{i}",
            "question": "When?", "gold": "12 November", "tools_called": ["pwg_people"], "reply": reply, "heuristic": h}


def run(argv):
    sys.argv = ["llm_grader.py"] + argv
    buf = io.StringIO()
    code = 0
    with contextlib.redirect_stdout(buf):
        try:
            G.main()
        except SystemExit as e:
            code = e.code if isinstance(e.code, int) else 1
            if not isinstance(e.code, int) and e.code:
                print(e.code)
    return code, buf.getvalue()


def main():
    t = tempfile.mkdtemp()
    os.environ["GRADER_SPEND_LOG"] = os.path.join(t, "spend.tsv")
    os.environ["GRADER_JOB"] = "test-job"
    os.environ.pop("GRADER_DENY_REGEX", None)
    items = [item(0, {"non_answer": False, "made_up": False, "correct": False}),
             item(1, {"non_answer": False, "made_up": True, "correct": False}, "It was 3 March."),
             item(2, {"non_answer": True, "made_up": False, "correct": False}, ""),
             item(3, {"non_answer": False, "made_up": None, "correct": True}, "12 November.")]
    ip = os.path.join(t, "items.jsonl")
    open(ip, "w").write("".join(json.dumps(x) + "\n" for x in items))
    ctx = os.path.join(t, "ctx.txt")
    open(ctx, "w").write("CONTEXT-SENTINEL owner is Test Person")
    out = os.path.join(t, "out")

    # request shape: rubric + context cached in system, structured output, no forced tool choice
    r = G.build_request(items[1], "CONTEXT-SENTINEL", G.GRADE_MODEL, "medium")
    check("context sits in the cached system block", "CONTEXT-SENTINEL" in r["system"][-1]["text"] and r["system"][-1].get("cache_control") == {"type": "ephemeral"})
    check("question and reply sit in the user turn, not the cached prefix", "It was 3 March." in r["messages"][0]["content"] and "It was 3 March." not in r["system"][-1]["text"])
    check("structured JSON output requested", r["output_config"]["format"]["type"] == "json_schema")
    check("no forced tool_choice (400 on this model)", "tool_choice" not in r)

    # submit happy path
    stub = Stub()
    G.make_client = lambda: stub
    code, o = run(["submit", ip, "--context", ctx, "--phase", "P1", "--out", out])
    check("submit creates one batch with every item", code == 0 and len(stub.created) == 1 and len(stub.created[0]) == 4)
    # refuse to resubmit (batch id on disk)
    code, o = run(["submit", ip, "--context", ctx, "--phase", "P1", "--out", out])
    check("submit refuses a phase whose batch id is on disk", code != 0 and len(stub.created) == 1 and "REFUSED" in o)
    # refuse a phase already in the spend log (no file on disk)
    with open(os.environ["GRADER_SPEND_LOG"], "w") as f:
        f.write(G.SPEND_COLS + "2026-01-01T00:00:00Z\ttest-job\tP9\tclaude-sonnet-5-5\tmsgbatch_x\t4\t1\t1\t1\t1\t0.0100\n")
    code, o = run(["submit", ip, "--context", ctx, "--phase", "P9", "--out", out])
    check("submit refuses a phase listed in the spend log", code != 0 and len(stub.created) == 1)
    # control: a different job's identical phase name does not block
    os.environ["GRADER_JOB"] = "other-job"
    code, o = run(["submit", ip, "--context", ctx, "--phase", "P9", "--out", os.path.join(t, "out2")])
    check("control: the same phase under another job is not blocked", code == 0 and len(stub.created) == 2)
    os.environ["GRADER_JOB"] = "test-job"
    # budget
    os.environ["GRADER_BUDGET_USD"] = "0.0001"
    code, o = run(["submit", ip, "--context", ctx, "--phase", "P2", "--out", out])
    check("submit refuses over budget", code != 0 and len(stub.created) == 2 and "budget" in o)
    os.environ.pop("GRADER_BUDGET_USD")
    # deny-list
    os.environ["GRADER_DENY_REGEX"] = "3 march"
    code, o = run(["submit", ip, "--context", ctx, "--phase", "P3", "--out", out])
    check("submit refuses items matching the deny-list", code != 0 and len(stub.created) == 2)
    os.environ.pop("GRADER_DENY_REGEX")

    # poll: results streamed, spend logged once with batch pricing, key never written
    os.environ["ANTHROPIC_API_KEY"] = "sk-KEY-SENTINEL"
    idmap = json.load(open(os.path.join(out, "P1.idmap.json")))
    cids = sorted(idmap)
    stub.results_data = [ok_result(cids[0], grade("honest_no_data")), ok_result(cids[1], grade("honest_no_data")),
                         ok_result(cids[2], grade("non_answer", non=True)), ok_result(cids[3], grade("correct"))]
    code, o = run(["poll", "--phase", "P1", "--out", out])
    rows = [l for l in open(os.environ["GRADER_SPEND_LOG"]) if "\tP1\t" in l]
    exp = 0.5 * 4 * (100 * 2.0 + 50 * 2.0 * 1.25 + 1000 * 2.0 * 0.1 + 200 * 10.0) / 1e6
    check("poll logs spend once at batch price", len(rows) == 1 and abs(float(rows[0].split("\t")[10]) - exp) < 1e-4)
    code, o = run(["poll", "--phase", "P1", "--out", out])
    rows = [l for l in open(os.environ["GRADER_SPEND_LOG"]) if "\tP1\t" in l]
    check("a second poll does not log the batch twice", len(rows) == 1)
    leaked = any("sk-KEY-SENTINEL" in open(os.path.join(dp, f), errors="ignore").read() for dp, _, fs in os.walk(t) for f in fs)
    check("the API key is never written to disk", not leaked)

    # report: item 1 is a planted disagreement on made_up (heuristic yes, grader no)
    code, o = run(["report", ip, "--phase", "P1", "--out", out])
    rep = open(os.path.join(out, "report_A.md")).read()
    check("report counts the planted made_up disagreement", "| S | made_up | 2/3 (67%)" in rep)
    check("report lists the disagreeing item", "S|m|q1" in rep and "S|m|q0" not in rep.split("## Disagreements")[1])
    check("report denominators exclude items with no existing label", "| S | correct | 4/4 (100%)" in rep and "| S | non_answer | 4/4 (100%)" in rep)
    # mutation: flip the grader on item 3 to non-correct; agreement on correct must drop
    stub.results_data[3] = ok_result(cids[3], grade("honest_no_data"))
    os.remove(os.path.join(out, "P1.results.jsonl"))
    run(["poll", "--phase", "P1", "--out", out])
    run(["report", ip, "--phase", "P1", "--out", out])
    rep2 = open(os.path.join(out, "report_A.md")).read()
    check("mutation: a flipped grade moves the agreement rate", "| S | correct | 3/4 (75%)" in rep2)

    # adjudicate: only disagreeing items go; --blind hides both labels and the rationale
    n0 = len(stub.created)
    run(["adjudicate", ip, "--context", ctx, "--from", "P1", "--phase", "ADJ", "--out", out])
    adj_reqs = stub.created[n0] if len(stub.created) > n0 else []
    u0 = adj_reqs[0]["params"]["messages"][0]["content"] if adj_reqs else ""
    check("adjudicate sends only the disagreeing items, with both labels", len(adj_reqs) == 2 and "HEURISTIC LABELS" in u0)
    run(["adjudicate", ip, "--context", ctx, "--from", "P1", "--phase", "ADJB", "--blind", "--out", out])
    b_reqs = stub.created[-1] if len(stub.created) > n0 + 1 else []
    ub = " ".join(r["params"]["messages"][0]["content"] for r in b_reqs)
    check("blind adjudication shows no labels and no rationale", len(b_reqs) == 2 and "HEURISTIC LABELS" not in ub and "RATIONALE" not in ub and "BLIND" in ub)

    print(f"{len(FAIL)} failed")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
