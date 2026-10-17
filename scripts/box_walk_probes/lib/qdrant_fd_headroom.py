"""qdrant_has_fd_headroom_and_writes_land: judge + box-side collector.

v1.0.107 cut #16 console walk: ostler-qdrant ran with nofile=1024 (compose
set no ulimits), 751 RocksDB .sst files were open, and the Places step then
wrote 0 of 979 while printing status=ok. Three assertions, all BLOCKING:

  1. the qdrant PROCESS's soft nofile limit is >= 65535 (read from
     /proc/<pid>/limits inside the container, not from compose text);
  2. its open fds are under 50% of that limit;
  3. every hydrate step that had input wrote ALL of it: written == input and
     no errors, read from the STEP'S OWN COUNT LINES in its log, never from a
     status word or exit code ("status=ok" over 0 written is the #16 shape; the
     real-path RED exited 0 having inserted 9,266 of 18,000 chunks).

Count lines read (the producers, file:line in this repo):
  places      "Done: N places (W written, E errors)"
              vendor/cm041/contact_syncer/places_ingest.py:539
  CM024 embed "Chunks created: N" / "Vectors inserted: W"
              vendor/cm024_knowledge/ostler_knowledge/cli.py:732-733
              (reminders, apple notes, and every other knowledge step)

`box` mode prints one JSON line (counts only, no content). `judge FILE`
prints ok/FAIL/CANNOT lines and exits 0 pass / 1 fail / 78 cannot-run.
`--self-test` drives the judge over a good capture and the #16 shapes.
"""
import glob
import json
import os
import re
import subprocess
import sys

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
MIN_NOFILE = 65535
MAX_FD_FRACTION = 0.5
CONTAINER = os.environ.get("OSTLER_QDRANT_CONTAINER", "ostler-qdrant")

PLACES = re.compile(r"Done: ([\d,]+) places \(([\d,]+) written, ([\d,]+) errors\)(?:.*status=(\w+))?")
CHUNKS = re.compile(r"Chunks created:\s*([\d,]+)")
VECTORS = re.compile(r"Vectors inserted:\s*([\d,]+)")
EMBED_ERRORS = re.compile(r"^Errors \(([\d,]+)\):", re.M)
UPSERT_FAILED = re.compile(r"Failed to upsert chunk")


def _n(s):
    return int(s.replace(",", ""))


def parse_log(name, text):
    """-> list of {step, input, written, status_word} from count lines only.
    The LAST occurrence of each count line wins (a log can hold a retry)."""
    steps = []
    p = PLACES.findall(text)
    if p:
        n, w, e, st = p[-1]
        steps.append({"step": name + ": places", "input": _n(n), "written": _n(w), "errors": _n(e),
                      "status_word": st or None})
    c, v = CHUNKS.findall(text), VECTORS.findall(text)
    if c and v:
        # CM024 prints "Errors (N):" only for embed failures; a failed Qdrant
        # upsert is logged per chunk ("Failed to upsert chunk"), so count both.
        e = EMBED_ERRORS.findall(text)
        errs = max(_n(e[-1]) if e else 0, len(UPSERT_FAILED.findall(text)))
        steps.append({"step": name + ": embed", "input": _n(c[-1]), "written": _n(v[-1]),
                      "errors": errs, "status_word": None})
    return steps


def collect(named_texts):
    """[(log name, text)] -> (steps, unmeasured log names). A log that yields
    no count line is NOT MEASURED and is reported by name, never skipped."""
    steps, unmeasured = [], []
    for name, text in named_texts:
        got = parse_log(name, text)
        if got:
            steps += got
        else:
            unmeasured.append(name)
    return steps, unmeasured


def _docker():
    for d in ("/opt/homebrew/bin/docker", "/usr/local/bin/docker", "docker"):
        if d == "docker" or os.path.exists(d):
            return d
    return "docker"


def box():
    out = {"container": CONTAINER}
    cmd = ('for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = qdrant ] || continue; '
           'awk "/Max open files/ {print \\$4}" $p/limits; ls $p/fd | wc -l; '
           'find /qdrant/storage -name "*.sst" | wc -l; break; done')
    try:
        r = subprocess.run([_docker(), "exec", CONTAINER, "sh", "-c", cmd],
                           capture_output=True, text=True, timeout=60)
        vals = r.stdout.split()
        if r.returncode != 0 or len(vals) < 3:
            out["container_cannot"] = "could not read the qdrant process in %s (rc %d): %s" % (
                CONTAINER, r.returncode, (r.stderr or "").strip()[:160])
        else:
            out["limit"] = int(vals[0]) if vals[0].isdigit() else vals[0]
            out["fds"], out["sst"] = int(vals[1]), int(vals[2])
    except Exception as e:  # docker missing or hung
        out["container_cannot"] = "docker exec failed: %s" % type(e).__name__
    root = os.path.expanduser(os.environ.get("OSTLER_DIAG_ROOT", "~/.ostler/diagnostics"))
    dirs = sorted(d for d in glob.glob(os.path.join(root, "*")) if os.path.isdir(d))
    install = [d for d in dirs if not d.endswith("-scale-fixture")]
    scale = [d for d in dirs if d.endswith("-scale-fixture")]
    chosen = install[-1:] + scale[-1:]
    out["diag_dirs"] = [os.path.basename(d) for d in chosen]
    named = []
    for d in chosen:
        for log in sorted(glob.glob(os.path.join(d, "*.log"))):
            name = "%s/%s" % (os.path.basename(d), os.path.basename(log))
            try:
                text = open(log, encoding="utf-8", errors="replace").read()
            except OSError:
                text = ""
            named.append((name, text))
    out["logs_examined"] = len(named)
    out["steps"], out["unmeasured_logs"] = collect(named)
    return out


def judge(c):
    lines, fail = [], False

    def check(label, ok):
        nonlocal fail
        lines.append(("  ok     " if ok else "  FAIL   ") + label)
        fail |= not ok

    if c.get("container_cannot"):
        lines.append("  CANNOT " + c["container_cannot"])
        return lines, EX_CANNOT
    lim = c.get("limit")
    if not isinstance(lim, int):
        # "unlimited" is a pass on the limit; anything else unreadable is not measured.
        if str(lim).lower() == "unlimited":
            check("qdrant nofile limit is unlimited (>= %d)" % MIN_NOFILE, True)
            lim = None
        else:
            lines.append("  CANNOT the qdrant nofile limit could not be read (%r)" % lim)
            return lines, EX_CANNOT
    else:
        check("qdrant nofile limit %d >= %d" % (lim, MIN_NOFILE), lim >= MIN_NOFILE)
    if lim:
        check("qdrant open fds %d < 50%% of the limit (%d); %s RocksDB .sst files"
              % (c.get("fds", -1), int(lim * MAX_FD_FRACTION), c.get("sst", "?")),
              c.get("fds", 1 << 30) < lim * MAX_FD_FRACTION)
    for name in c.get("unmeasured_logs") or []:
        lines.append("NOT MEASURED %s" % name)
    steps = c.get("steps") or []
    with_input = [s for s in steps if s.get("input", 0) > 0]
    if not with_input:
        lines.append("  CANNOT no hydrate step with input > 0 was found in %d log(s) under %s; "
                     "the writes-land arm was NOT measured" % (c.get("logs_examined", 0), c.get("diag_dirs")))
        return lines, EX_FAIL if fail else EX_CANNOT
    for s in with_input:
        word = " (it printed status=%s)" % s["status_word"] if s.get("status_word") else ""
        errs = s.get("errors") or 0
        check("%s wrote %d of %d, %d error(s)%s" % (s["step"], s["written"], s["input"], errs, word),
              s["written"] >= s["input"] and errs == 0)
    lines.append("  note   %d step(s) with input examined, from %d log(s)" % (len(with_input), c.get("logs_examined", 0)))
    return lines, EX_FAIL if fail else EX_PASS


def self_test():
    ok = True
    good = {"limit": 65535, "fds": 412, "sst": 320, "logs_examined": 3, "diag_dirs": ["x"],
            "steps": [{"step": "places-ingest.log: places", "input": 979, "written": 979, "status_word": "ok"},
                      {"step": "hydrate-reminders.log: embed", "input": 9000, "written": 9000, "status_word": None}]}
    # The parser reads the producers' real line shapes.
    places_line = "\nDone: 979 places (0 written, 979 errors) from 400 meeting locations + 579 photo places. status=ok\n"
    parsed = parse_log("places-ingest.log", places_line)
    embed_text = "  Notes processed: 6,000\n  Chunks created: 18,000\n  Vectors inserted: 0\n"
    parsed_e = parse_log("hydrate-apple-notes.log", embed_text)
    if parsed != [{"step": "places-ingest.log: places", "input": 979, "written": 0, "errors": 979, "status_word": "ok"}] \
            or parsed_e != [{"step": "hydrate-apple-notes.log: embed", "input": 18000, "written": 0, "errors": 0, "status_word": None}]:
        print("  FAIL   the parser misreads the producers' count lines: %r %r" % (parsed, parsed_e))
        ok = False
    else:
        print("  ok     the parser reads 'Done: N places (W written, E errors)' and the CM024 chunk/vector lines")
    mutants = {
        "#16: nofile 1024": dict(good, limit=1024, fds=200),
        "#16: fds at the limit (1024 of 1024)": dict(good, limit=1024, fds=1024),
        "fds over half a raised limit": dict(good, fds=40000),
        "#16: Places 0 written of 979 with status=ok": dict(good, steps=parsed + good["steps"][1:]),
        "an embed step with chunks and no vectors": dict(good, steps=good["steps"][:1] + parsed_e),
        "the real-path RED: 9,266 of 18,000 written, 8,734 errors, exit 0": dict(good, steps=good["steps"][:1] + parse_log(
            "hydrate-apple-notes.log", "  Chunks created: 18,000\n  Vectors inserted: 9,266\n"
            + "ERROR - Failed to upsert chunk: HTTP 500\n" * 8734)),
        "every chunk written but errors reported": dict(good, steps=[dict(good["steps"][1], errors=3)]),
    }
    # A log with no count line is reported by name, never silently skipped.
    st, um = collect([("d/hydrate-reminders.log", "  Chunks created: 9,000\n  Vectors inserted: 9,000\n"),
                      ("d/hydrate-email.log", "Started.\nnothing countable here\n")])
    nl, _ = judge(dict(good, steps=st, unmeasured_logs=um))
    hit = [l for l in nl if l.startswith("NOT MEASURED ")]
    print("  %s  a log with no count line prints exactly 'NOT MEASURED d/hydrate-email.log'" %
          ("ok    " if hit == ["NOT MEASURED d/hydrate-email.log"] else "FAIL  "))
    ok &= hit == ["NOT MEASURED d/hydrate-email.log"]
    full = parse_log("hydrate-apple-notes.log", "  Chunks created: 18,000\n  Vectors inserted: 18,000\n")
    _, rcf = judge(dict(good, steps=full))
    print("  %s  a full write (18,000 of 18,000, 0 errors) passes" % ("ok    " if rcf == EX_PASS else "FAIL  "))
    ok &= rcf == EX_PASS
    _, rc = judge(good)
    print("  %s  the good capture passes" % ("ok    " if rc == EX_PASS else "FAIL  "))
    ok &= rc == EX_PASS
    for name, m in mutants.items():
        _, rc = judge(m)
        print("  %s  mutant rejected: %s" % ("ok    " if rc == EX_FAIL else "FAIL  ", name))
        ok &= rc == EX_FAIL
    for name, m in (("docker unreachable", {"container_cannot": "no docker"}),
                    ("no step with input found", dict(good, steps=[]))):
        _, rc = judge(m)
        print("  %s  %s is CANNOT-RUN, not a pass" % ("ok    " if rc == EX_CANNOT else "FAIL  ", name))
        ok &= rc == EX_CANNOT
    print("every mutant went red" if ok else "SELF-TEST BROKEN")
    return 0 if ok else 1


def main(argv):
    if len(argv) > 1 and argv[1] == "--self-test":
        return self_test()
    if len(argv) > 1 and argv[1] == "box":
        print(json.dumps(box()))
        return 0
    if len(argv) > 2 and argv[1] == "judge":
        lines, rc = judge(json.load(open(argv[2])))
        print("\n".join(lines))
        return rc
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
