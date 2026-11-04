"""Third-party telemetry walk probe (v1.0.124 egress audit D1+D3+D2). Python 3.9.

Three vendors report home by default: Qdrant (telemetry.qdrant.io, hourly), Homebrew
(analytics host) and the Hub web UI (fonts.googleapis.com / fonts.gstatic.com). The fixes
are config, so a config check alone proves nothing about traffic. This probe checks both:

  box   collect, ON THE BOX: the RUNNING qdrant container's environment
        (docker inspect, not the compose file), the resolved addresses of the forbidden
        hosts, N samples of ESTABLISHED tcp remotes (lsof), and a CONTROL: a loopback
        connection planted by the collector and read by the SAME lsof reader.
  judge FILE   FAIL if telemetry is not disabled in the running container, or any
        established remote equals an address a forbidden host resolved to. CANNOT-RUN if
        the control was not seen (the sampler is blind), docker is unreadable, no qdrant
        container runs, or no forbidden host resolved.

LIMITS, stated: a sample, not a capture (a connection that opens and closes between
samples, UDP and DNS are invisible); a CDN address can be shared, so a match is
"consistent with". Qdrant reports hourly, so the sampler runs for the whole walk window
and the container-env arm is the durable evidence.

Subcommands: box | judge FILE | --self-test.   Exit: 0 pass, 1 fail, 78 cannot-run.
"""
import copy
import json
import os
import socket
import subprocess
import sys
import time

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
FORBIDDEN = (
    "telemetry.qdrant.io",
    "eu.i.posthog.com", "us.i.posthog.com", "app.posthog.com",
    "www.google-analytics.com", "eu-central-1-1.aws.cloud2.influxdata.com",
    "fonts.googleapis.com", "fonts.gstatic.com",
)
LSOF = "lsof -nP -iTCP -sTCP:ESTABLISHED"


def _sh(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=60)
        return r.returncode, r.stdout, r.stderr.strip()[:160]
    except (OSError, subprocess.SubprocessError) as e:
        return 127, "", "%s: %s" % (type(e).__name__, str(e)[:120])


def remotes(lsof_out):
    out = set()
    for line in lsof_out.splitlines()[1:]:
        for f in line.split():
            i = f.find("->")
            if i > 0:
                out.add(f[i + 2:].rsplit(":", 1)[0].strip("[]"))
    return out


def collect(samples=3, gap=2):
    os.environ["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "")
    cap = {"cannot": "", "docker_rc": 0, "qdrant_env": None, "qdrant_containers": 0,
           "forbidden": {}, "remotes": [], "control_seen": False, "samples": samples}
    rc, out, err = _sh("docker ps -q --filter name=qdrant")
    cap["docker_rc"] = rc
    ids = out.split()
    cap["qdrant_containers"] = len(ids)
    if rc == 0 and ids:
        rc2, env, _ = _sh("docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' %s" % ids[0])
        cap["qdrant_env"] = env.splitlines() if rc2 == 0 else None
    for h in FORBIDDEN:
        try:
            cap["forbidden"][h] = sorted({i[4][0] for i in socket.getaddrinfo(h, None, socket.AF_INET)})
        except OSError:
            cap["forbidden"][h] = []
    # CONTROL: a real loopback connection, read by the same lsof the samples use.
    srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(1)
    cli = socket.create_connection(srv.getsockname()); conn, _ = srv.accept()
    _, lo, _ = _sh(LSOF)
    cap["control_seen"] = "127.0.0.1" in remotes(lo)
    cli.close(); conn.close(); srv.close()
    seen = set()
    for i in range(samples):
        _, lo, _ = _sh(LSOF)
        seen |= remotes(lo)
        if i < samples - 1:
            time.sleep(gap)
    cap["remotes"] = sorted(seen)
    return cap


def judge(cap):
    rows, code = [], [EX_PASS]

    def row(kind, msg, c):
        rows.append("  %s %s" % (kind, msg))
        if c == EX_FAIL or (c == EX_CANNOT and code[0] == EX_PASS):
            code[0] = c
    if cap.get("cannot"):
        row("CANNOT", cap["cannot"], EX_CANNOT)
    if cap.get("docker_rc", 1) != 0:
        row("CANNOT", "docker unreadable (rc %s)" % cap.get("docker_rc"), EX_CANNOT)
    elif not cap.get("qdrant_containers"):
        row("CANNOT", "no running qdrant container to inspect", EX_CANNOT)
    elif cap.get("qdrant_env") is None:
        row("CANNOT", "docker inspect of the qdrant container failed", EX_CANNOT)
    elif "QDRANT__TELEMETRY_DISABLED=true" in cap["qdrant_env"]:
        row("ok", "qdrant container runs with QDRANT__TELEMETRY_DISABLED=true", EX_PASS)
    else:
        row("FAIL", "qdrant container env lacks QDRANT__TELEMETRY_DISABLED=true: it reports to telemetry.qdrant.io hourly", EX_FAIL)
    fb = cap.get("forbidden") or {}
    n_res = sum(1 for v in fb.values() if v)
    if not cap.get("control_seen"):
        row("CANNOT", "CONTROL not seen: lsof did not show the planted loopback connection, so the sampler is blind", EX_CANNOT)
    elif n_res == 0:
        row("CANNOT", "no forbidden host resolved on the box, nothing to compare against", EX_CANNOT)
    else:
        bad = [(h, ip) for h, ips in fb.items() for ip in ips if ip in set(cap.get("remotes") or [])]
        if bad:
            for h, ip in bad:
                row("FAIL", "established connection to %s (%s)" % (h, ip), EX_FAIL)
        else:
            row("ok", "0 of %d sampled remotes match %d forbidden hosts (%d resolved); control seen" % (len(cap.get("remotes") or []), len(fb), n_res), EX_PASS)
    return rows, code[0]


def run_judge(path):
    try:
        cap = json.load(open(path))
        assert isinstance(cap, dict)
        rows, code = judge(cap)
    except (OSError, ValueError, AssertionError, KeyError, TypeError, AttributeError) as e:
        print("  CANNOT capture unreadable or malformed (%s)" % type(e).__name__)
        return EX_CANNOT
    print("\n".join(rows))
    return code


def _good():
    return {"cannot": "", "docker_rc": 0, "qdrant_containers": 1, "qdrant_env": ["QDRANT__TELEMETRY_DISABLED=true", "X=1"],
            "forbidden": {"telemetry.qdrant.io": ["203.0.113.7"], "fonts.googleapis.com": ["203.0.113.8"]},
            "remotes": ["127.0.0.1", "198.51.100.9"], "control_seen": True}


def self_test():
    bad, n = [], [0]

    def expect(name, mut, want):
        n[0] += 1
        c = copy.deepcopy(_good()); mut(c)
        got = judge(c)[1]
        if got != want:
            bad.append("%s: want %s got %s" % (name, want, got))
    expect("good", lambda c: None, EX_PASS)
    expect("telemetry-not-disabled", lambda c: c.update(qdrant_env=["X=1"]), EX_FAIL)
    expect("telemetry-false", lambda c: c.update(qdrant_env=["QDRANT__TELEMETRY_DISABLED=false"]), EX_FAIL)
    expect("qdrant-connection", lambda c: c["remotes"].append("203.0.113.7"), EX_FAIL)
    expect("fonts-connection", lambda c: c["remotes"].append("203.0.113.8"), EX_FAIL)
    expect("control-blind", lambda c: c.update(control_seen=False), EX_CANNOT)
    expect("control-blind-with-hit", lambda c: (c.update(control_seen=False), c["remotes"].append("203.0.113.7")), EX_CANNOT)
    expect("no-qdrant", lambda c: c.update(qdrant_containers=0), EX_CANNOT)
    expect("docker-down", lambda c: c.update(docker_rc=127), EX_CANNOT)
    expect("env-unreadable", lambda c: c.update(qdrant_env=None), EX_CANNOT)
    expect("nothing-resolved", lambda c: c.update(forbidden={"telemetry.qdrant.io": []}), EX_CANNOT)
    n[0] += 1
    if remotes("COMMAND PID\nx 1 u 3u IPv4 0 0t0 TCP 10.0.0.1:5->203.0.113.7:443 (ESTABLISHED)\n") != {"203.0.113.7"}:
        bad.append("remotes() parser")
    print("self-test: %d cases, %d wrong" % (n[0], len(bad)))
    for b in bad:
        print("  WRONG " + b)
    return EX_FAIL if bad else EX_PASS


def main(argv):
    if len(argv) >= 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) >= 2 and argv[1] == "box":
        try:
            cap = collect()
        except BaseException as e:
            cap = {"cannot": "collector crashed: %s: %s" % (type(e).__name__, str(e)[:200])}
        print(json.dumps(cap))
        return EX_PASS
    if len(argv) >= 3 and argv[1] == "judge":
        return run_judge(argv[2])
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
