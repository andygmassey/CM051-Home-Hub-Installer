"""Pulled-image-digest walk probe (CM051 #2404). Python 3.9.

install.sh pins qdrant, nginx and valkey by digest on ghcr.io (mirrored byte for
byte from Docker Hub). Are the images the box actually pulled the pinned ones?

  box   collect, ON THE BOX: the pin from the installed docker-compose.yml, the
        digests docker holds for that ref (RepoDigests), the image ref each
        container runs, and the install log's pull lines and pull errors
  judge FILE   per image: pinned == a held RepoDigest, == the running ref's digest,
        == every digest the install log pulled for that repo, and no pull error

INDEPENDENCE. The compose pin and the log's "Image <ref> Pulling" line come from
the same install, so they agree by construction; the instruments that did not
read the pin are docker's RepoDigests and the running container's image ref. An
image the install log never mentions is CANNOT-RUN for the log arm, never PASS.

Subcommands: box | judge FILE | --self-test.   Exit: 0 pass, 1 fail, 78 cannot-run.
"""
import copy
import json
import os
import re
import subprocess
import sys

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78
IMAGES = ("qdrant", "nginx", "valkey")
DIG = r"sha256:[0-9a-f]{64}"
PULL_ERR = re.compile(r"toomanyrequests|manifest unknown|failed to (?:pull|resolve)|pull access denied|error pulling|Error response from daemon", re.I)


def pins_of(compose_text):
    """-> {name: digest} from `image: <registry>/<name>@sha256:...` lines."""
    out = {}
    for m in re.finditer(r"(?m)^\s*image:\s*(\S+/(%s))@(%s)" % ("|".join(IMAGES), DIG), compose_text):
        out.setdefault(m.group(2), m.group(3))
    return out


def log_pulls(log_text, name):
    """-> (digests the install log pulled for <name>, pull-error lines naming it)."""
    ds, errs = [], []
    for ln in log_text.splitlines():
        if re.search(r"/%s@" % name, ln) or ("/%s" % name in ln and PULL_ERR.search(ln)):
            ds += re.findall(DIG, ln)
            if PULL_ERR.search(ln):
                errs.append(ln.strip()[:160])
    return ds, errs


def _sh(args):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=60)
        return r.returncode, r.stdout, r.stderr.strip()[:160]
    except (OSError, subprocess.SubprocessError) as e:
        return 127, "", "%s: %s" % (type(e).__name__, str(e)[:120])


def collect():
    base = os.environ.get("OSTLER_DIR") or os.path.join(os.path.expanduser("~"), ".ostler")
    env_path = "/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "")
    os.environ["PATH"] = env_path
    cap = {"compose": os.path.join(base, "docker-compose.yml"), "images": {}, "cannot": ""}
    try:
        ctext = open(cap["compose"]).read()
    except OSError as e:
        cap["cannot"] = "cannot read the installed compose file %s: %s" % (cap["compose"], type(e).__name__)
        return cap
    try:
        ltext = open(os.path.join(base, "logs", "install.log"), errors="replace").read()
    except OSError:
        ltext = None
    pins = pins_of(ctext)
    rc, ids, err = _sh(["docker", "ps", "-aq"])
    ps = ""
    if rc == 0 and ids.split():   # `docker ps` prints the short image ID; Config.Image is the ref the container was created from
        rc, ps, err = _sh(["docker", "inspect", "--format", "{{.Name}}\t{{.Config.Image}}"] + ids.split())
    cap["docker_rc"], cap["docker_err"] = rc, err
    cap["log_readable"] = ltext is not None
    for name in IMAGES:
        e = {"pinned": pins.get(name), "held": None, "running": [], "log": [], "log_errors": [], "log_mentions": 0}
        if e["pinned"]:
            ref = re.search(r"(?m)^\s*image:\s*(\S+/%s@%s)" % (name, DIG), ctext).group(1)
            rc2, out, _ = _sh(["docker", "image", "inspect", ref, "--format", "{{json .RepoDigests}}"])
            if rc2 == 0:
                try:
                    e["held"] = [d for r in json.loads(out.strip()) for d in re.findall(DIG, r)]
                except ValueError:
                    pass
        for ln in ps.splitlines():
            if "/%s@" % name in ln or ("/%s:" % name in ln):
                e["running"] += re.findall(DIG, ln) or ["unpinned:" + ln.split("\t")[-1][:80]]
        if ltext is not None:
            e["log"], e["log_errors"] = log_pulls(ltext, name)
            e["log_mentions"] = len(re.findall(r"/%s@" % name, ltext))
        cap["images"][name] = e
    return cap


def judge(cap):
    from send_safety import V
    v = V()
    if cap.get("cannot"):
        v.cant(cap["cannot"])
        return v
    if cap.get("docker_rc") != 0:
        v.cant("docker could not be read on the box (rc=%s: %s); no pulled digest was measured" % (cap.get("docker_rc"), cap.get("docker_err")))
        return v
    if not cap.get("log_readable"):
        v.cant("the install log could not be read; what the install pulled was not measured")
        return v
    imgs = cap.get("images") or {}
    for name in IMAGES:
        e = imgs.get(name) or {}
        pin = e.get("pinned")
        if not pin:
            v.cant("%s: no digest pin found in the installed compose file" % name)
            continue
        if e.get("log_errors"):
            v.bad("%s: the install log carries a pull error: %s" % (name, e["log_errors"][0]))
        held = e.get("held")
        if held is None:
            v.bad("%s: docker holds no image for the pinned ref (pull never landed)" % name)
        elif pin in held:
            v.ok("%s: docker holds the pinned digest %s" % (name, pin[:19]))
        else:
            v.bad("%s: docker holds %s, not the pin %s" % (name, ",".join(d[:19] for d in held) or "no digest", pin[:19]))
        run = e.get("running") or []
        if not run:
            v.cant("%s: no container runs this image, so the running ref was not compared" % name)
        elif all(r == pin for r in run):
            v.ok("%s: the running container's image is the pin" % name)
        else:
            v.bad("%s: a running container uses %s, not the pin" % (name, [r[:19] for r in run if r != pin][0]))
        lg = e.get("log") or []
        if not e.get("log_mentions"):
            v.cant("%s: the install log has no pull line for it, so what the install pulled was not read" % name)
        elif all(d == pin for d in lg) and lg:
            v.ok("%s: every digest the install log pulled (%d) is the pin" % (name, len(lg)))
        else:
            v.bad("%s: the install log pulled %s, not the pin" % (name, [d[:19] for d in lg if d != pin][:1] or "no digest"))
    return v


def run_judge(path):
    try:
        cap = json.load(open(path))
    except (OSError, ValueError) as e:
        print("  CANNOT the capture could not be read: %s" % type(e).__name__)
        return EX_CANNOT
    if not isinstance(cap, dict):
        print("  CANNOT the capture is not an object")
        return EX_CANNOT
    try:
        v = judge(cap)
    except (KeyError, TypeError, IndexError, AttributeError) as e:
        print("  CANNOT the capture is malformed (%s), nothing was measured" % type(e).__name__)
        return EX_CANNOT
    print("\n".join(v.rows))
    return v.code()


def _good():
    d = {"qdrant": "sha256:" + "a" * 64, "nginx": "sha256:" + "b" * 64, "valkey": "sha256:" + "c" * 64}
    return {"compose": "x", "cannot": "", "docker_rc": 0, "docker_err": "", "log_readable": True,
            "images": {n: {"pinned": h, "held": [h], "running": [h], "log": [h], "log_errors": [], "log_mentions": 1} for n, h in d.items()}}


def _mut(fn):
    c = copy.deepcopy(_good())
    fn(c)
    return c


def self_test():
    bad, n = [], [0]
    other = "sha256:" + "f" * 64

    def expect(name, cap, want):
        n[0] += 1
        got = judge(cap).code()
        if got != want:
            bad.append("%s: want %s got %s" % (name, want, got))

    expect("good", _good(), EX_PASS)
    for nm in IMAGES:
        expect(nm + "/held-other-digest", _mut(lambda c: c["images"][nm].update(held=[other])), EX_FAIL)
        expect(nm + "/never-pulled", _mut(lambda c: c["images"][nm].update(held=None)), EX_FAIL)
        expect(nm + "/running-other", _mut(lambda c: c["images"][nm].update(running=[other])), EX_FAIL)
        expect(nm + "/log-pulled-other", _mut(lambda c: c["images"][nm].update(log=[other])), EX_FAIL)
        expect(nm + "/pull-error-in-log", _mut(lambda c: c["images"][nm].update(log_errors=["toomanyrequests"])), EX_FAIL)
        expect(nm + "/no-pin", _mut(lambda c: c["images"][nm].update(pinned=None)), EX_CANNOT)
        expect(nm + "/not-in-log", _mut(lambda c: c["images"][nm].update(log=[], log_mentions=0)), EX_CANNOT)
        expect(nm + "/not-running", _mut(lambda c: c["images"][nm].update(running=[])), EX_CANNOT)
    expect("docker-unreadable", _mut(lambda c: c.update(docker_rc=127)), EX_CANNOT)
    expect("log-unreadable", _mut(lambda c: c.update(log_readable=False)), EX_CANNOT)
    expect("compose-unreadable", _mut(lambda c: c.update(cannot="no compose")), EX_CANNOT)
    expect("empty-object", {}, EX_CANNOT)
    # the parsers against the real wording
    comp = "services:\n  q:\n    image: ghcr.io/creativemachines-ai/qdrant@sha256:%s  # v1\n  n:\n    image: ghcr.io/creativemachines-ai/nginx@sha256:%s\n  o:\n    image: ghcr.io/oxigraph/oxigraph@sha256:%s\n" % ("a" * 64, "b" * 64, "d" * 64)
    n[0] += 1
    if pins_of(comp) != {"qdrant": "sha256:" + "a" * 64, "nginx": "sha256:" + "b" * 64}:
        bad.append("pins_of: %r" % (pins_of(comp),))
    lg = " Image ghcr.io/creativemachines-ai/valkey@sha256:%s Pulling \n Image ghcr.io/creativemachines-ai/qdrant@sha256:%s Pulling \n Error response from daemon: ghcr.io/creativemachines-ai/nginx toomanyrequests\n" % ("c" * 64, "a" * 64)
    n[0] += 1
    if log_pulls(lg, "valkey") != (["sha256:" + "c" * 64], []) or not log_pulls(lg, "nginx")[1]:
        bad.append("log_pulls: %r %r" % (log_pulls(lg, "valkey"), log_pulls(lg, "nginx")))
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
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    sys.exit(main(sys.argv))
