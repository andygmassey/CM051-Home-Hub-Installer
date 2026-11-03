"""Customer status API date-sentinel probe (CM051 #966). Python 3.9.

A status endpoint once served a year-2318 sentinel as a date. Does ANY date field
the customer's status API serves parse past now + 10 years?

  judge NAME=FILE [NAME=FILE ...]   each FILE is `<json body>\\n<http status>`
  --self-test

A date field is (a) any string value that is an ISO date or datetime, or (b) a
number under a key ending _at / _ts / timestamp / epoch / expires / until /
deadline, read as epoch seconds (milliseconds when >= 1e11). Walked recursively.

CANNOT-RUN, never PASS: an endpoint that is not 200 JSON, or one that served no
date field at all (a zero from a probe that could not see dates reads the same as
a clean answer; the denominator must be > 0). FAIL: any date past the horizon.
Exit: 0 pass, 1 fail, 78 cannot-run.
"""
import datetime
import json
import re
import sys
import time

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
HORIZON_DAYS = 3653
ISO = re.compile(r"^(\d{4})-(\d{2})-(\d{2})(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?$")
NUMKEY = re.compile(r"(_at|_ts|timestamp|epoch|expires|until|deadline)$", re.I)


EPOCH = datetime.datetime(1970, 1, 1)


def ymd_of_epoch(secs):
    try:
        d = EPOCH + datetime.timedelta(seconds=secs)
        return (d.year, d.month, d.day)
    except (OverflowError, ValueError):
        return (99999, 1, 1)   # unrepresentable: further out than any horizon


def year_of_number(v):
    return ymd_of_epoch(v / 1000.0 if v >= 1e11 else float(v))


def date_fields(node, path=""):
    """-> [(path, shown, year)] for every date field under node."""
    out = []
    if isinstance(node, dict):
        for k, v in node.items():
            p = "%s.%s" % (path, k) if path else str(k)
            if isinstance(v, (int, float)) and not isinstance(v, bool) and NUMKEY.search(str(k)):
                out.append((p, v, year_of_number(v)))
            else:
                out += date_fields(v, p)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            out += date_fields(v, "%s[%d]" % (path, i))
    elif isinstance(node, str):
        m = ISO.match(node.strip())
        if m:
            out.append((path, node, (int(m.group(1)), int(m.group(2)), int(m.group(3)))))
    return out


def horizon_ymd(now=None):
    return ymd_of_epoch((now or time.time()) + HORIZON_DAYS * 86400)


def judge(bodies, now=None):
    """bodies: {name: (http_status, text)} -> (rows, code)"""
    from send_safety import V
    v = V()
    cut = horizon_ymd(now)
    for name, (code, text) in sorted(bodies.items()):
        try:
            doc = json.loads(text)
        except ValueError:
            doc = None
        if code != "200" or not isinstance(doc, (dict, list)):
            v.cant("%s: not a 200 JSON body (http %s); the status API was not read" % (name, code))
            continue
        fs = date_fields(doc)
        if not fs:
            v.cant("%s: served no date field at all, so a clean reading would be a blind one" % name)
            continue
        late = [f for f in fs if f[2] > cut]
        if late:
            v.bad("%s: %d of %d date fields are past now+10y (after %04d-%02d-%02d): %s = %s" % ((name, len(late), len(fs)) + cut + (late[0][0], late[0][1])))
        else:
            v.ok("%s: %d date fields, the furthest is %04d-%02d-%02d (horizon %04d-%02d-%02d)" % ((name, len(fs)) + max(f[2] for f in fs) + cut))
    return v


def _split(raw):
    body, _, code = raw.rstrip("\n").rpartition("\n")
    return code.strip(), body


def self_test():
    bad, n = [], [0]
    ok_doc = {"sources": [{"recorded_at": "2026-11-02T08:03:27Z", "last_run_at": None, "n": 3}], "snapshot": {"timestamp": "2026-11-02T12:01:50.6+00:00"}}
    now = 1793600000  # 2026-11-02

    def expect(name, bodies, want):
        n[0] += 1
        got = judge(bodies, now).code()
        if got != want:
            bad.append("%s: want %s got %s" % (name, want, got))

    J = lambda d, c="200": (c, json.dumps(d))
    expect("good", {"a": J(ok_doc)}, EX_PASS)
    expect("2318-iso-string", {"a": J({"x": [{"last_update_at": "2318-01-01T00:00:00Z"}], "t": "2026-01-01"})}, EX_FAIL)
    expect("2318-date-only", {"a": J({"until": "2318-06-30", "t": "2026-01-01"})}, EX_FAIL)
    expect("2318-epoch-seconds", {"a": J({"expires_at": 10990000000, "t": "2026-01-01"})}, EX_FAIL)
    expect("2318-epoch-millis", {"a": J({"expires_at": 10990000000000, "t": "2026-01-01"})}, EX_FAIL)
    expect("nested-in-list", {"a": J({"l": [{"m": {"n": "2400-01-01T00:00:00+00:00"}}], "t": "2026-01-01"})}, EX_FAIL)
    expect("one-bad-endpoint-fails-all", {"a": J(ok_doc), "b": J({"x": "2318-01-01"})}, EX_FAIL)
    expect("inside-horizon-passes", {"a": J({"next": "2030-01-01T00:00:00Z"})}, EX_PASS)
    expect("a-month-past-horizon", {"a": J({"next": "2036-12-01T00:00:00Z"})}, EX_FAIL)
    expect("a-month-inside-horizon", {"a": J({"next": "2036-10-01T00:00:00Z"})}, EX_PASS)
    expect("non-date-number-ignored", {"a": J({"count": 10990000000, "t": "2026-01-01"})}, EX_PASS)
    expect("404", {"a": ("404", '{"detail":"Not Found"}')}, EX_CANNOT)
    expect("not-json", {"a": ("200", "<html>")}, EX_CANNOT)
    expect("no-date-fields", {"a": J({"sources": [{"n": 1}]})}, EX_CANNOT)
    expect("empty-object", {"a": J({})}, EX_CANNOT)
    expect("blind-endpoint-with-good-one", {"a": J(ok_doc), "b": ("404", "")}, EX_CANNOT)
    n[0] += 1
    if _split('{"a":1}\n200\n') != ("200", '{"a":1}'):
        bad.append("_split")
    print("self-test: %d cases, %d wrong" % (n[0], len(bad)))
    for b in bad:
        print("  WRONG " + b)
    return EX_FAIL if bad else EX_PASS


def main(argv):
    import os
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    if len(argv) >= 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) >= 3 and argv[1] == "judge":
        bodies = {}
        for a in argv[2:]:
            name, _, path = a.partition("=")
            try:
                bodies[name] = _split(open(path, errors="replace").read())
            except OSError as e:
                bodies[name] = ("0", "")
        v = judge(bodies)
        print("\n".join(v.rows))
        return v.code()
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
