#!/usr/bin/env python3
"""One command: score the brief and owner-knowledge harness. stdlib only.

  python3 -I scripts/intelligence_eval/run.py --mode synthetic            controls + gap + noise, no model
  python3 -I scripts/intelligence_eval/run.py --mode synthetic --model qwen3.5:4b --ollama http://127.0.0.1:11500
  python3 -I scripts/intelligence_eval/run.py --self-test                 the harness tests itself
  python3 -I scripts/intelligence_eval/run.py --mode owner --host andy@HOST  preflight, then CANNOT-RUN with the reason

Exit: 0 ran and self-test green; 1 a self-test or control assertion failed;
78 could not run (no model, no box, walk running).
Output carries aggregates and the denominator only. Synthetic names appear
only in synthetic mode, and owner mode prints no question or answer text.
"""
import argparse
import hashlib
import json
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import brief_eval as B  # noqa: E402
import knowledge_eval as K  # noqa: E402
import world as W  # noqa: E402

FIXTURE = os.path.join(HERE, "fixtures", "owner_synthetic_v1.json")
OWNER_UUID = "E9589EC6-AA1E-5425-9D76-3AF64A0A05BD"
RUNS = 3


def load_fixture():
    with open(FIXTURE, encoding="utf-8") as f:
        return json.load(f)


def world_digest(world):
    return hashlib.sha256(json.dumps(world, sort_keys=True).encode()).hexdigest()[:16]


def half_width(p1, n1, p2, n2):
    """95% half-width on the difference of two proportions. The smallest gap this sample can resolve."""
    if not (n1 and n2) or p1 is None or p2 is None:
        return None
    return 1.96 * math.sqrt(p1 * (1 - p1) / n1 + p2 * (1 - p2) / n2)


def spread(values):
    vals = [v for v in values if v is not None]
    return (max(vals) - min(vals)) if len(vals) > 1 else 0.0


def fmt(r):
    if r is None or r.get("value") is None:
        return "n/a (den 0)"
    return "%5.1f%%  (%d/%d)" % (100 * r["value"], r["num"], r["den"])


def run_brief_suite(world, days, which, builder, runs):
    out = []
    for _ in range(runs):
        rates, _ = B.run_brief(world, which, days, builder=builder)
        out.append(rates)
    return out


def run_knowledge_suite(fixture, answerer, runs):
    return [K.run(fixture, answerer) for _ in range(runs)]


def controls_and_gap(world, fixture, days):
    good = run_brief_suite(world, days, "good", None, RUNS)
    bad = run_brief_suite(world, days, "bad", None, RUNS)
    g, b = good[0], bad[0]
    gap = {}
    for m in B.METRICS:
        gv, bv = g[m]["value"], b[m]["value"]
        hw = half_width(gv, g[m]["den"], bv, b[m]["den"]) if g[m]["den"] and b[m]["den"] else None
        nspread = max(spread([r[m]["value"] for r in good]), spread([r[m]["value"] for r in bad]))
        gap[m] = {"good": g[m], "bad": b[m],
                  "delta": (gv - bv) if (gv is not None and bv is not None) else None,
                  "ci95_halfwidth": hw, "run_spread": nspread}
    return gap, good, bad


def print_brief(title, gap, good, bad):
    print("\n== %s ==" % title)
    print("%-17s %-22s %-22s %-8s %-8s %-8s" % ("metric", "good (hand policy)", "bad (fixed sections)",
                                              "delta", "ci95", "spread"))
    for m in B.METRICS:
        row = gap[m]
        d = "%+.1f" % (100 * row["delta"]) if row["delta"] is not None else "n/a"
        hw = "%.1f" % (100 * row["ci95_halfwidth"]) if row["ci95_halfwidth"] is not None else "n/a"
        print("%-17s %-22s %-22s %-8s %-8s %-8.1f" % (m, fmt(row["good"]), fmt(row["bad"]), d, hw,
                                                      100 * row["run_spread"]))
    print("picks per day: good %.2f, bad %.2f (cap %d)" % (
        good[0]["picks_per_day"]["value"], bad[0]["picks_per_day"]["value"], B.PICK_CAP))


def knowledge_report(title, runs, fixture):
    print("\n== %s (%d runs) ==" % (title, len(runs)))
    n = runs[0]["n"]
    print("questions per run: %d (answerable %d, absent %d)" % (
        n, sum(runs[0]["by_kind"]["answerable"].values()), sum(runs[0]["by_kind"]["absent"].values())))
    for k in K.OUTCOMES:
        vals = [r["rates"][k]["value"] for r in runs]
        print("  %-10s %5.1f%%  run spread %.1f pts  (%s)" % (
            k, 100 * vals[0], 100 * spread(vals), " / ".join("%d" % r["counts"][k] for r in runs)))


def cmd_synthetic(args):
    fixture = load_fixture()
    world = W.build_world(fixture)
    days = args.days
    print("SYNTHETIC mode. fixture %s, replay days %d, world digest %s, items %d" % (
        os.path.basename(FIXTURE), days, world_digest(world), len(world["items"])))
    gap, good, bad = controls_and_gap(world, fixture, days)
    print_brief("BRIEF CONTROLS, %d runs each (deterministic policies)" % RUNS, gap, good, bad)
    ph, _ = B.run_brief(world, "phantom", days)
    print("phantom control (good policy + 1 invented id a day): phantom %s, acted_precision %s" % (
        fmt(ph["phantom"]), fmt(ph["acted_precision"])))

    failed = []
    if not (gap["acted_precision"]["delta"] and gap["acted_precision"]["delta"] > 0):
        failed.append("good does not beat bad on acted_precision")
    if gap["handled_shown"]["bad"]["value"] == 0:
        failed.append("bad control did not show handled items (control broken)")
    if gap["stale_fact"]["bad"]["value"] == 0:
        failed.append("bad control did not show stale facts (control broken)")
    if gap["guess_as_fact"]["bad"]["value"] in (0, None):
        failed.append("bad control did not state a guess as fact (control broken)")
    if gap["handled_shown"]["good"]["value"] != 0:
        failed.append("good control shows handled items")
    if not ph["phantom"]["num"] or gap["phantom"]["good"]["num"] != 0:
        failed.append("phantom control did not register phantoms, or good shows them (control broken)")
    if gap["duplicate"]["bad"]["num"] == 0:
        failed.append("bad control did not show a duplicate (control broken)")

    ans_k = K.build_questions(fixture)
    n_answerable = sum(1 for q in ans_k if q["kind"] == "answerable")
    kn = {
        "oracle": run_knowledge_suite(fixture, K.answer_oracle, 1)[0],
        "fabricator": run_knowledge_suite(fixture, K.answer_fabricator, 1)[0],
        "abstainer": run_knowledge_suite(fixture, K.answer_abstainer, 1)[0],
    }
    print("\n== KNOWLEDGE CONTROLS (deterministic) ==")
    for name, r in kn.items():
        print("%-11s right %5.1f%%  wrong %5.1f%%  fabricated %5.1f%%  abstained %5.1f%%  (n=%d)" % (
            name, 100 * r["rates"]["RIGHT"]["value"], 100 * r["rates"]["WRONG"]["value"],
            100 * r["rates"]["FABRICATED"]["value"], 100 * r["rates"]["ABSTAINED"]["value"], r["n"]))
    if kn["oracle"]["counts"]["RIGHT"] != n_answerable or kn["oracle"]["counts"]["FABRICATED"] != 0:
        failed.append("oracle control not all RIGHT on answerable, or fabricated")
    if kn["fabricator"]["counts"]["FABRICATED"] != kn["fabricator"]["by_kind"]["absent"]["FABRICATED"]:
        failed.append("fabricator control not fabricating every absent question")
    if kn["abstainer"]["counts"]["RIGHT"] != 0 or kn["abstainer"]["counts"]["FABRICATED"] != 0:
        failed.append("abstainer control scored RIGHT or FABRICATED")

    model_runs = None
    if args.model:
        model_runs = []
        for _ in range(RUNS):
            ans = B.build_model(args.ollama, args.model)
            try:
                rates, _ = B.run_brief(world, None, days, builder=ans)
            except (OSError, RuntimeError, ValueError) as e:
                # An endpoint that is down or errors is ERROR, not a zero score and not a crash.
                failed.append("brief model endpoint ERROR: %s" % type(e).__name__)
                print("ERROR brief model endpoint: %s" % e)
                break
            model_runs.append(rates)
        print("\n== MODEL %s brief, %d runs (synthetic world) ==" % (args.model, RUNS))
        for m in (B.METRICS if model_runs else []):
            vals = [r[m]["value"] for r in model_runs]
            print("%-17s run values %s  spread %.1f pts  den %s" % (
                m, ", ".join("n/a" if v is None else "%.1f%%" % (100 * v) for v in vals),
                100 * spread(vals), model_runs[0][m]["den"]))
        k_runs = run_knowledge_suite(fixture, K.make_model_answerer(args.ollama, args.model, fixture), RUNS)
        model_runs = model_runs if model_runs else None
        knowledge_report("MODEL %s owner knowledge" % args.model, k_runs, fixture)
        for i, kr in enumerate(k_runs):
            if kr["counts"]["ERROR"]:
                failed.append("model run %d: %d ERROR replies (missing, empty or error body). "
                              "Not a result: an error is not an abstention" % (i + 1, kr["counts"]["ERROR"]))

    print("\nSMALLEST GAP RESOLVED (95%%, this sample size, good vs bad): %s" % ", ".join(
        "%s %.1f pts" % (m, 100 * max(gap[m]["ci95_halfwidth"] or 0, gap[m]["run_spread"]))
        for m in ("acted_precision", "acted_recall", "handled_shown", "stale_fact")))
    print("CONTROL ASSERTIONS: %s" % ("ALL HOLD" if not failed else "FAILED: " + "; ".join(failed)))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump({"world_digest": world_digest(world), "days": days, "gap": gap,
                       "knowledge_controls": {k: v["rates"] for k, v in kn.items()},
                       "model_runs": model_runs}, f, indent=2, default=str)
    return 1 if failed else 0


def owner_preflight(host):
    """Refuse unless Mini16 is the expected box, and no walk is running here or there."""
    checks = {}
    try:
        uuid = subprocess.run(
            ["ssh", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", host,
             "ioreg -rd1 -c IOPlatformExpertDevice | awk -F'\"' '/IOPlatformUUID/{print $4}'"],
            capture_output=True, text=True, check=False).stdout.strip()
        checks["box_uuid_matches"] = uuid == OWNER_UUID
        walk = subprocess.run(
            ["ssh", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", host,
             "pgrep -f '[w]alk' | wc -l"],
            capture_output=True, text=True, check=False).stdout.strip()
        checks["walk_processes_on_box"] = int(walk or 0)
    except OSError as e:
        checks["ssh_error"] = type(e).__name__
    local = subprocess.run(["pgrep", "-f", "[t]tywalk"], capture_output=True, text=True, check=False)
    checks["ttywalk_processes_here"] = len(local.stdout.split())
    return checks


def cmd_owner(args):
    """Owner knowledge on the box. Only the counts JSON comes back. Nothing owner-side is copied."""
    if not args.host:
        print("owner mode needs --host (Mini16 user@address). Refusing.")
        return 78
    checks = owner_preflight(args.host)
    print("OWNER mode preflight: %s" % json.dumps(checks, sort_keys=True))
    if checks.get("walk_processes_on_box") or checks.get("ttywalk_processes_here"):
        print("WAIT: a walk-matching process is running. Not touching the box.")
        return 75
    if not checks.get("box_uuid_matches"):
        print("REFUSE: the box does not answer as Mini16. Nothing run.")
        return 78
    remote_dir = "walkdriver/intel-eval-run/owner"
    here = os.path.join(HERE, "owner_mode.py")
    script = (
        "set -u; mkdir -p ~/%(d)s; "
        "OLLAMA_HOST=127.0.0.1:11500 OLLAMA_KEEP_ALIVE=2m nohup ~/.ostler/runtime/ollama-0.34.0/ollama serve "
        ">~/%(d)s/ollama.log 2>&1 & OP=$!; "
        "for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -m 2 http://127.0.0.1:11500/api/version >/dev/null && break; sleep 2; done; "
        "python3 -I ~/%(d)s/owner_mode.py; RC=$?; "
        "kill $OP 2>/dev/null; exit $RC" % {"d": remote_dir})
    subprocess.run(["ssh", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", args.host,
                    "mkdir -p ~/%s" % remote_dir], check=False)
    subprocess.run(["scp", "-q", "-o", "BatchMode=yes", here,
                    "%s:%s/owner_mode.py" % (args.host, remote_dir)], check=False)
    proc = subprocess.run(["ssh", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", args.host, script],
                          capture_output=True, text=True, check=False)
    line = next((l for l in reversed(proc.stdout.splitlines()) if l.startswith("{")), None)
    if line is None:
        print("CANNOT-RUN: no counts returned (rc=%d). No text is printed for a failure." % proc.returncode)
        return 78
    result = json.loads(line)
    print("OWNER knowledge baseline (counts only): %s" % json.dumps(result, sort_keys=True))
    return 1 if result.get("error") else 0


def self_test():
    """Each check is an assertion the harness must satisfy, plus mutants it must fail."""
    fixture = load_fixture()
    results = []

    def check(name, ok):
        results.append((name, bool(ok)))
        print("  %s  %s" % ("PASS" if ok else "FAIL", name))

    w1 = W.build_world(fixture)
    w2 = W.build_world(fixture)
    check("world is deterministic (same seed, same digest)", world_digest(w1) == world_digest(w2))
    check("world has items of every kind",
          {i["kind"] for i in w1["items"]} >= {"reply_owed", "promise", "meeting", "birthday", "inference"})
    check("world holds a superseded meeting (stale-fact control has something to catch)",
          any(i["superseded_day"] is not None for i in w1["items"]))

    good, _ = B.run_brief(w1, "good", 30)
    bad, _ = B.run_brief(w1, "bad", 30)
    check("good brief never shows a handled item", good["handled_shown"]["num"] == 0)
    check("good brief never states a guess as fact", good["guess_as_fact"]["num"] == 0)
    check("good beats bad on acted precision", good["acted_precision"]["value"] > bad["acted_precision"]["value"])
    check("bad brief shows handled items (control has teeth)", bad["handled_shown"]["num"] > 0)
    check("bad brief shows stale facts (control has teeth)", bad["stale_fact"]["num"] > 0)
    check("bad brief states a guess as fact (control has teeth)", bad["guess_as_fact"]["num"] > 0)
    check("bad brief repeats a person in one morning (duplicate control has teeth)", bad["duplicate"]["num"] > 0)
    ph_rates, _ = B.run_brief(w1, "phantom", 30)
    check("phantom control registers invented ids; good policy has none",
          ph_rates["phantom"]["num"] == 30 and good["phantom"]["num"] == 0)

    phantom_picks, n_ph = B.parse_picks('{"picks":[{"id":"it-999","guess":false}]}', {"it-001"})
    check("a builder that invents an item id is counted as phantom", n_ph == 1 and phantom_picks[0]["version"] == -1)
    check("unparseable model reply yields no picks, not a crash", B.parse_picks("no json here", {"x"}) == ([], 0))

    mut = B.run_brief(w1, "good", 30, builder=None)[0]
    m_rates = B.rates(*_mutant_tot(w1, "good"))
    check("MUTANT scorer that never counts acted picks reads precision 0 (metric reads the outcome)",
          m_rates["acted_precision"]["value"] == 0 and mut["acted_precision"]["value"] > 0)

    orc = K.run(fixture, K.answer_oracle)
    fab = K.run(fixture, K.answer_fabricator)
    abst = K.run(fixture, K.answer_abstainer)
    n_ans = sum(1 for q in K.build_questions(fixture) if q["kind"] == "answerable")
    check("knowledge oracle: every answerable RIGHT, nothing fabricated",
          orc["counts"]["RIGHT"] == n_ans and orc["counts"]["FABRICATED"] == 0)
    check("knowledge fabricator: every absent question FABRICATED",
          fab["by_kind"]["absent"]["FABRICATED"] == sum(1 for q in K.build_questions(fixture) if q["kind"] == "absent"))
    check("knowledge abstainer: never RIGHT, never FABRICATED", abst["counts"]["RIGHT"] == 0 and abst["counts"]["FABRICATED"] == 0)
    check("grader: a plain refusal on an absent question is ABSTAINED",
          K.grade({"kind": "absent", "groups": [], "wrong": []}, "I do not know.")[0] == "ABSTAINED")
    check("grader: a committed answer on an absent question is FABRICATED",
          K.grade({"kind": "absent", "groups": [], "wrong": []}, "It is O positive.")[0] == "FABRICATED")
    for form in K.DECLINE_FORMS:
        check("grader: decline form is ABSTAINED, not FABRICATED: %r" % form,
              K.grade({"kind": "absent", "groups": [], "wrong": []}, form)[0] == "ABSTAINED")
    # POSITIVE CONTROL: a planted invented value must grade FABRICATED. Without this, a grader that
    # learned only declines could drift to scoring every absent answer ABSTAINED and pass the arms above.
    for planted in ("Mary Doe's blood type is O positive.", "The seed round closes on 2027-06-30.",
                    "Sam Ross sent 412 messages.", "Tom Coe is in Operators."):
        check("positive control: planted invented value is FABRICATED: %r" % planted,
              K.grade({"kind": "absent", "groups": [], "wrong": []}, planted)[0] == "FABRICATED")
    check("grader: an empty reply is ERROR, never ABSTAINED",
          K.grade({"kind": "absent", "groups": [], "wrong": []}, "")[0] == "ERROR")
    check("grader: a missing reply (None) is ERROR, never ABSTAINED",
          K.grade({"kind": "answerable", "groups": [["40"]], "wrong": []}, None)[0] == "ERROR")
    check("grader: a whitespace-only reply is ERROR",
          K.grade({"kind": "absent", "groups": [], "wrong": []}, "   \n ")[0] == "ERROR")
    blank = K.run(fixture, lambda q, f: None)
    check("MUTANT-GUARD: a run whose every reply is missing lands in ERROR, not ABSTAINED",
          blank["counts"]["ERROR"] == blank["n"] and blank["counts"]["ABSTAINED"] == 0)
    dead = K.make_model_answerer("http://127.0.0.1:9", "no-such-model", fixture)
    check("an unreachable model is ERROR on every question (connection refused, not a declined answer)",
          K.run(fixture, lambda q, f: dead(q, f))["counts"]["ERROR"] == blank["n"])
    check("grader: '400' does not satisfy a '40' expectation (word boundary)",
          K.grade({"kind": "answerable", "groups": [["40"]], "wrong": []}, "400 messages")[0] == "WRONG")

    failed = [n for n, ok in results if not ok]
    print("SELF-TEST: %d checks, %d passed, %d failed" % (len(results), len(results) - len(failed), len(failed)))
    return 1 if failed else 0


def _mutant_tot(world, which):
    build = B.BUILDERS[which]
    tot, per_day = B.aggregate(world, build, 30)
    tot["acted"] = 0
    tot["acted_visible_picked"] = 0
    return tot, per_day


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mode", choices=("synthetic", "owner"), default="synthetic")
    ap.add_argument("--days", type=int, default=W.REPLAY_DAYS)
    ap.add_argument("--model", help="tier model, e.g. qwen3.5:4b at 16 GB")
    ap.add_argument("--ollama", default="http://127.0.0.1:11434", help="Ollama base URL")
    ap.add_argument("--host", help="owner mode: user@address of the box")
    ap.add_argument("--json", help="write the aggregate result here (no names in owner mode)")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)
    if args.self_test:
        return self_test()
    if args.mode == "owner":
        return cmd_owner(args)
    return cmd_synthetic(args)


if __name__ == "__main__":
    sys.exit(main())
