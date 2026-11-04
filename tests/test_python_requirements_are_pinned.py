#!/usr/bin/env python3
"""Every requirements file the installer or upgrader uses is == pinned (S4).

Red-team S4, v1.0.124: CM051 installed Python packages from 9 requirements
files with 0 `==` pins, at install AND at every upgrade. A compromised release
inside a `>=` range ran as the owner on every install after its publication.

Checks, each with a mutant in --self-test (a check that cannot go red is not a
check):
  1. DISCOVERY is by `git ls-files` (any requirements*.txt anywhere), not a
     list, so a NEW unpinned file goes red instead of being invisible.
  2. every requirement line is `name==version` (extras and env markers
     allowed). Ranges, bare names, -e, -r, URLs, VCS lines all fail.
  3. a package pinned in two files carries the SAME version (they install into
     one shared venv; a split makes pip reinstall on every run).
  4. every pip site in install.sh is pinned: no `--upgrade` of anything, no
     `pip install` of a name with a range, and the `_install_conversation_feed`
     dependency lists are == pinned.
Hashes (--require-hashes) are the v1.0.125 step and are NOT checked here.
"""
import re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PIN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.\-]*(\[[A-Za-z0-9_,.\- ]+\])?==[A-Za-z0-9_.!+*]+(\s*;[^#]*)?$")
norm = lambda n: re.sub(r"[-_.]+", "-", n).lower()


def req_lines(text):
    for i, ln in enumerate(text.splitlines(), 1):
        s = ln.split("#", 1)[0].strip()
        if s:
            yield i, s


def check_requirements(files):
    """files: {path: text} -> list of problems"""
    bad, seen = [], {}
    if not files:
        return ["no requirements file discovered (a zero is not a pass)"]
    for path, text in files.items():
        n = 0
        for i, s in req_lines(text):
            n += 1
            if not PIN.match(s):
                bad.append("%s:%d not an == pin: %s" % (path, i, s))
                continue
            name, ver = re.split(r"==", re.sub(r"\[.*?\]", "", s.split(";")[0]).strip())
            if seen.setdefault(norm(name), (ver, path))[0] != ver:
                bad.append("%s:%d %s==%s but %s pins %s" % (path, i, name, ver, seen[norm(name)][1], seen[norm(name)][0]))
        if n == 0:
            bad.append("%s has no requirement lines" % path)
    return bad


def check_install_sh(text):
    bad = []
    for i, ln in enumerate(text.splitlines(), 1):
        code = ln.strip()
        if code.startswith("#"):
            continue
        if re.search(r"\bpip\"?\s+install\b.*--upgrade\b", code) or re.search(r"\bpip\"?\s+install\b.*\s-U\b", code):
            bad.append("install.sh:%d pip install --upgrade (floating): %s" % (i, code[:100]))
        m = re.search(r"\bpip\"?\s+install\b(.*)", code)
        if m:
            for spec in re.findall(r"\"([A-Za-z0-9_.\-]+[<>~!][^\"]*)\"", m.group(1)):
                bad.append("install.sh:%d ranged pip spec %r" % (i, spec))
        m = re.match(r"_install_conversation_feed\s+\S+\s+\S+\s+\"([^\"]*)\"", code)
        if m:
            for dep in m.group(1).split():
                if dep != "ostler_fda" and "==" not in dep:
                    bad.append("install.sh:%d feed dep not == pinned: %s" % (i, dep))
    return bad


def real_inputs():
    names = subprocess.run(["git", "ls-files", "--", "*requirements*.txt"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    files = {n: (ROOT / n).read_text() for n in names if not n.startswith("tests/")}
    return files, (ROOT / "install.sh").read_text()


def self_test(files, sh):
    assert not check_requirements(files) and not check_install_sh(sh), "control: the real tree must be green"
    k = sorted(files)[0]
    first = next(s for _, s in req_lines(files[k]))
    name = first.split("==")[0]
    muts = {
        "one unpinned line": ({**files, k: files[k] + "\nrequests\n"}, sh, check_requirements),
        "one ranged line": ({**files, k: files[k].replace(first, name + ">=1.0", 1)}, sh, check_requirements),
        "new unpinned file": ({**files, "x/requirements.txt": "httpx>=0.28\n"}, sh, check_requirements),
        "-r include": ({**files, k: files[k] + "\n-r other.txt\n"}, sh, check_requirements),
        "version split": ({**files, "x/requirements.txt": name + "==0.0.1\n"}, sh, check_requirements),
        "empty file": ({**files, "x/requirements.txt": "# nothing\n"}, sh, check_requirements),
    }
    for label, (f, s, fn) in muts.items():
        assert fn(f if fn is check_requirements else files) , "mutant NOT caught: " + label
    shm = {
        "upgrade pip": sh + '\n"$v/bin/pip" install --quiet --upgrade pip\n',
        "ranged spec": sh + '\n"$v/bin/pip" install --quiet "sqlcipher3>=0.6.0,<0.7.0"\n',
        "feed dep": sh + '\n_install_conversation_feed spoken spoken_source "pyyaml"\n',
    }
    for label, s in shm.items():
        assert check_install_sh(s), "install.sh mutant NOT caught: " + label
    print("self-test ok: control green, %d requirements mutants + %d install.sh mutants caught" % (len(muts), len(shm)))


def main():
    files, sh = real_inputs()
    if "--self-test" in sys.argv:
        self_test(files, sh)
        return 0
    bad = check_requirements(files) + check_install_sh(sh)
    for b in bad:
        print("FAIL", b)
    if bad:
        return 1
    n = sum(1 for t in files.values() for _ in req_lines(t))
    print("ok: %d requirements files, %d pinned lines, 0 unpinned; install.sh pip sites pinned" % (len(files), n))
    self_test(files, sh)
    return 0


if __name__ == "__main__":
    sys.exit(main())
