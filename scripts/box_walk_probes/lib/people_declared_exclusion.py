# lib/people_declared_exclusion.py
# ============================================================================
# THE PROBES' INDEPENDENT RE-CHECK OF THE PRODUCT'S DECLARED PEOPLE EXCLUSION.
#
# The shipped people indexer leaves notification and organisation senders OUT
# of the people index on purpose (service_sender_reason in ostler_fda/
# pwg_ingest.py). It now DECLARES what it left out: state/people-index.json
# carries excluded, by_reason and excluded_uris, written each pass.
#
# A declaration is not evidence. Each probe RE-APPLIES the shipped rule to every
# declared URI against the graph and FAILS on any URI the rule does not confirm.
# The rule is read from the installed pwg_ingest.py by AST (only the _SVC_*
# constants and the two functions), so it is never copied into the probe and
# never imported for side effects. A change to the rule is seen by the probes.
#
# Verdicts (CANNOT-RUN is not FAIL and is not PASS):
#   fail        a declared URI the rule does not confirm, or the per-reason
#               counts the rule gives disagree with the declared by_reason
#   cannot_run  the state file, a declared field, or a declared URI's graph
#               row is absent, so nothing was confirmed
#   ok          every checked declared URI is confirmed by the rule
#
# Sampling: above sample_cap the first sample_cap URIs (sorted) are checked and
# the per-reason equality is NOT asserted (the sample cannot prove it). Declared
# URIs outside the sample are not verified and stay residual in the caller.
#
# NOTHING HERE PRINTS A URI. Mismatches are reported as 12-hex fingerprints.
#
# CLI (self-test and the test script only):
#   python3 people_declared_exclusion.py cli <state.json> <rule_pwg_ingest.py> <rows.json> [sample_cap]
#   rows.json: {uri: {"name": str, "phones": [str], "emails": [str]}}
# ============================================================================
import ast
import hashlib
import json
import os
import re
import sys
from collections import Counter


def fp(u):
    return hashlib.sha256(u.encode("utf-8")).hexdigest()[:12]


def state_path():
    explicit = os.environ.get("OSTLER_PEOPLE_INDEX_STATE")
    if explicit:
        return explicit
    base = os.environ.get("OSTLER_DIR") or os.path.join(os.path.expanduser("~"), ".ostler")
    return os.path.join(base, "state", "people-index.json")


def rule_path():
    explicit = os.environ.get("OSTLER_FDA_PWG_INGEST")
    if explicit:
        return explicit
    return os.path.join(os.path.expanduser("~"), ".ostler", "fda-module", "ostler_fda", "pwg_ingest.py")


def load_rule(path):
    """The SHIPPED service_sender_reason, extracted by AST and nothing else."""
    with open(path, encoding="utf-8") as fh:
        tree = ast.parse(fh.read(), path)
    keep = []
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id.startswith("_SVC_") for t in node.targets):
            keep.append(node)
        elif isinstance(node, ast.FunctionDef) and node.name in ("_service_mailbox", "service_sender_reason"):
            keep.append(node)
    ns = {"re": re}
    exec(compile(ast.Module(body=keep, type_ignores=[]), path, "exec"), ns)
    if "service_sender_reason" not in ns:
        raise RuntimeError("service_sender_reason not found in the shipped rule")
    return ns["service_sender_reason"]


def read_declaration(path):
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
    except FileNotFoundError:
        return None, "people-index state file absent"
    except Exception as exc:
        return None, "people-index state file unreadable (%s)" % type(exc).__name__
    if not isinstance(d, dict):
        return None, "people-index state file is not a JSON object"
    missing = [k for k in ("excluded", "by_reason", "excluded_uris") if k not in d]
    if missing:
        return None, "declaration fields absent from people-index state: " + ",".join(missing)
    return d, ""


def verify(decl, lookup, rule, sample_cap=1000, named_total=None):
    out = {"status": "cannot_run", "detail": "", "verified": set(), "checked": 0,
           "excluded": 0, "mismatches": [], "share": None, "sampled": False}
    uris = decl.get("excluded_uris")
    n = decl.get("excluded")
    by = decl.get("by_reason")
    if (not isinstance(uris, list) or not isinstance(by, dict)
            or not isinstance(n, int) or isinstance(n, bool)):
        out["detail"] = "declaration malformed"
        return out
    if len(uris) != n:
        out["status"] = "fail"
        out["detail"] = "declaration disagrees with itself: excluded=%d but %d URIs declared" % (n, len(uris))
        return out
    out["excluded"] = n
    if named_total:
        out["share"] = round(100.0 * n / named_total, 2)
    sample = sorted(set(uris))
    if len(sample) > sample_cap:
        sample = sample[:sample_cap]
        out["sampled"] = True
    computed = Counter()
    unresolved = 0
    for u in sample:
        row = lookup(u)
        if row is None:
            unresolved += 1
            continue
        reason = rule(row.get("name") or "", row.get("phones") or None, row.get("emails") or None)
        out["checked"] += 1
        if reason is None:
            out["mismatches"].append(fp(u))
        else:
            computed[reason] += 1
            out["verified"].add(u)
    if out["mismatches"]:
        out["status"] = "fail"
        out["detail"] = ("%d declared URI(s) the shipped rule does NOT confirm (fingerprints %s)"
                         % (len(out["mismatches"]), ",".join(out["mismatches"][:10])))
        return out
    if unresolved:
        out["detail"] = "%d declared URI(s) have no graph row to re-check, so nothing was confirmed" % unresolved
        return out
    if not out["sampled"] and dict(computed) != dict(by):
        out["status"] = "fail"
        out["detail"] = ("the shipped rule gives per-reason counts %s but the declaration says %s"
                         % (dict(sorted(computed.items())), dict(sorted(by.items()))))
        return out
    out["status"] = "ok"
    out["detail"] = ("rule re-applied to %d of %d declared, all confirmed%s"
                     % (out["checked"], n, "; sampled, per-reason equality not asserted" if out["sampled"] else ""))
    return out


def _cli(argv):
    st, rule_src, rows_p = argv[0], argv[1], argv[2]
    cap = int(argv[3]) if len(argv) > 3 else 1000
    decl, why = read_declaration(st)
    if decl is None:
        print(json.dumps({"status": "cannot_run", "detail": why}))
        return 0
    with open(rows_p, encoding="utf-8") as fh:
        rows = json.load(fh)
    res = verify(decl, lambda u: rows.get(u), load_rule(rule_src), cap)
    res["verified"] = len(res["verified"])
    print(json.dumps(res, sort_keys=True))
    return 0


if __name__ == "__main__" and len(sys.argv) > 4 and sys.argv[1] == "cli":
    sys.exit(_cli(sys.argv[2:]))
