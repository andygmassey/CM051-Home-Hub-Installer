#!/usr/bin/env python3
"""Fold single-purpose workflows into FAMILY workflows without dropping a gate.

WHY THIS EXISTS
---------------
Measured 2026-10-17 on this repository's own Actions history: 214 workflow
files, 266 jobs, 212 of them PR-triggered and 178 of those path-filtered. A
pull request touching install.sh fires 93 workflows. PR #2941 carried 178
check-runs whose work was mostly 5 to 30 seconds each, but whose wall clock was
9m16s because they QUEUE: across 795 check-runs on eight PRs, an Ubuntu job
waited a median 13s for a runner and a macOS job a median 318s (p90 2039s).
Two of those PRs hit the CI Required Gate's 45 minute idle cap waiting on
macOS. The cost is the number of jobs, not the work in them.

Folding jobs into fewer, larger jobs is the fix, and it is also the easiest way
in this repository to make a gate silently vanish. So the fold is mechanical
and the proof is separate from the generator:

  inventory   every job and step in every workflow, the scripts and tests each
              one executes, and the family it is proposed to fold into.
  generate    writes ONE family workflow from .github/ci-fold-families.tsv,
              copying every folded step's text verbatim (comments included),
              and removes the folded jobs from their source files.
  check       compares a base ref against the working tree and refuses unless
              every job is either byte-for-byte unchanged or folded exactly as
              the spec says, every folded step is preserved verbatim, every
              trigger is a superset, the executed-script set is a superset,
              and the runner and matrix are unchanged.

WHAT A FOLDED BLOCK PRESERVES, AND HOW
--------------------------------------
Each source job becomes a BLOCK of steps inside the family job. Separate jobs
had separate machines, so each block first restores what a fresh machine gave
it:

  * a pristine checkout   git reset --hard + git clean -ffdx
  * a fresh interpreter   a new venv from the hoisted setup-python, so a
                          block sees only the packages ITS steps install --
                          a "stdlib only" test cannot pass because an earlier
                          block installed something
  * a fresh HOME, TMPDIR  so files one block leaves behind cannot satisfy
                          another block's assertions

Step conditions are re-scoped to the block. A step with no `if:` ran only when
every earlier step in ITS job succeeded; here it runs when every earlier step
in its BLOCK succeeded (`!cancelled() && steps.<prior>.conclusion !=
'failure'...`), so one block's failure cannot skip another block's tests.
`success()` and `failure()` inside an existing condition are rewritten to the
block-scoped equivalents; `always()` and `cancelled()` are kept as written.
Every step keeps a per-step timeout equal to its old job's timeout, so a hang
is still bounded where it was.

WHAT IS NOT PRESERVED, stated so nobody over-trusts it:
  * Check-run NAMES change. Nothing in this repository requires a check by
    name except "CI Required Gate", which is untouched.
  * Wall-clock parallelism inside a family is gone; the blocks run in series.
  * A test that writes to a fixed absolute path outside the checkout, HOME and
    TMPDIR (for example a literal /tmp/foo) can still see an earlier block's
    leftovers. Nothing here can isolate that without a fresh machine.

EXIT CODES
  0  ok / proven
  1  the fold is NOT proven -- something was dropped, narrowed or changed
  2  could not run (no PyYAML, unreadable ref, unparseable workflow)

British English; " -- " not em-dashes.
"""
import argparse
import copy
import json
import glob
import os
import re
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:      # only `select` may run without it; see main()
    yaml = None

class CannotRun(Exception):
    """Nothing safe was established. Exit 2, never a pass and never a 1."""


REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
WF_REL = ".github/workflows"
SPEC_REL = ".github/ci-fold-families.tsv"
PATHS_REL = ".github/ci-fold-paths.tsv"
# A change to the selector or its data could make it skip a block wrongly, so
# a change to either runs EVERY block, as does a change to the family file.
SELECT_ALWAYS = ("scripts/ci_fold.py", PATHS_REL)
FAMILY_PREFIX = "fold-"

# Never folded. Each has a reason that is not about speed.
STANDALONE = {
    "ci-required-gate.yml": "the aggregate itself; branch protection names it",
    "cut.yml": "the release cut; tag and dispatch triggers, secrets, macos-26",
}

# Paths a step can execute. Anything under these trees with a script suffix.
SCRIPT_RE = re.compile(
    r"(?<![\w./-])((?:tests|scripts|gui|tools|bin|lib|launch|vendor|"
    r"context-refresh|contact_syncer|wiki-recompile|assistant-agent|"
    r"\.github)/[\w./@+-]*\.(?:sh|py|swift|bats|js|mjs|rb|pl|toml|tsv))"
    r"|(?<![\w./-])((?:install|release)\.sh)\b")
MAKE_RE = re.compile(r"\bmake\b((?:\s+-C\s+\S+|\s+-[a-zA-Z]+)*)\s+([\w-]+)")


# ---------------------------------------------------------------------------
# loading
# ---------------------------------------------------------------------------
def load_dir(wf_dir):
    out = {}
    for path in sorted(glob.glob(os.path.join(wf_dir, "*.yml")) +
                       glob.glob(os.path.join(wf_dir, "*.yaml"))):
        name = os.path.basename(path)
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        try:
            doc = yaml.safe_load(text)
        except yaml.YAMLError as e:
            raise CannotRun(f"ci_fold: CANNOT RUN -- {name} does not parse: {e}")
        out[name] = (text, doc)
    if not out:
        raise CannotRun(f"ci_fold: CANNOT RUN -- 0 workflows under {wf_dir}. "
                         f"An empty scan is not a clean one.")
    return out


def load_ref(ref):
    """Workflows as they are at a git ref, via git archive into a temp dir."""
    tmp = tempfile.mkdtemp(prefix="ci_fold_ref_")
    try:
        arch = subprocess.run(["git", "-C", REPO, "archive", ref, WF_REL],
                              check=True, capture_output=True).stdout
    except subprocess.CalledProcessError as e:
        raise CannotRun(f"ci_fold: CANNOT RUN -- git archive {ref} failed: "
                         f"{e.stderr.decode().strip()}")
    subprocess.run(["tar", "-x", "-C", tmp], input=arch, check=True)
    return load_dir(os.path.join(tmp, WF_REL))


def triggers(doc):
    on = doc.get(True, doc.get("on"))
    if isinstance(on, str):
        on = {on: None}
    if isinstance(on, list):
        on = {k: None for k in on}
    return on or {}


def event_paths(doc, event):
    """None = event absent; [] = present and unfiltered; else the paths list."""
    on = triggers(doc)
    if event not in on:
        return None
    ev = on[event] or {}
    if "paths-ignore" in ev:
        raise CannotRun("ci_fold: CANNOT RUN -- paths-ignore is not modelled "
                         "and would make a union of path lists wrong.")
    paths = list(ev.get("paths") or [])
    if any(str(p).startswith("!") for p in paths):
        raise CannotRun("ci_fold: CANNOT RUN -- a negated path is order-"
                         "dependent; a concatenated union would not be exact.")
    return paths


ASSIGN_RE = re.compile(r"^\s*(?:export\s+|local\s+)?([A-Za-z_]\w*)="
                       r"([\"']?)([\w./@+-]+)\2\s*(?:#.*)?$", re.M)
CD_RE = re.compile(r"(?:^|[;&|]\s*|\(\s*)cd\s+([\"']?)([\w./-]+)\1", re.M)
REL_RE = re.compile(r"(?<![\w./$-])([\w.-]+(?:/[\w.-]+)*\.(?:sh|py))\b")


def scripts_in(text):
    """Repo paths a run body executes or names. Best effort, and the SAME
    effort on both sides of a diff, so a superset still means something.

    Two indirections are followed because the estate uses them: a simple
    variable (`d=vendor/x/tests; pytest $d/test_a.py`) and a relative path
    after `cd DIR`. A path found after `cd` counts only if it exists under
    that directory, so a relative token cannot invent an entry."""
    found = set()
    text = "" if text is None else str(text)
    for m in ASSIGN_RE.finditer(text):
        name, val = m.group(1), m.group(3)
        text = re.sub(r"\$\{%s\}|\$%s\b" % (name, name), val, text)
    for m in CD_RE.finditer(text):
        d = m.group(2).rstrip("/")
        for r in REL_RE.finditer(text[m.end():]):
            cand = os.path.normpath(os.path.join(d, r.group(1)))
            if os.path.isfile(os.path.join(REPO, cand)):
                found.add(cand)
    for m in SCRIPT_RE.finditer(text):
        found.add(m.group(1) or m.group(2))
    for m in MAKE_RE.finditer(text):
        flags = m.group(1) or ""
        d = re.search(r"-C\s+(\S+)", flags)
        found.add(f"make:{d.group(1) if d else '.'}:{m.group(2)}")
    return found


def step_kind(step):
    if "uses" in step:
        return "uses:" + str(step["uses"])
    return "run"


# ---------------------------------------------------------------------------
# family proposal (inventory only; the SPEC is what generate/check obey)
# ---------------------------------------------------------------------------
def propose_family(fname, doc, jid, job):
    if fname in STANDALONE or fname.startswith(FAMILY_PREFIX):
        return "standalone" if fname in STANDALONE else fname[:-4]
    on = triggers(doc)
    if "pull_request" not in on:
        return "standalone"            # schedule / dispatch / release only
    if "uses" in job:
        return "standalone"            # reusable-workflow call
    if "needs" in job or any("needs" in j for j in doc["jobs"].values()):
        return "standalone"            # an expressed dependency stays a job
    ro = job.get("runs-on")
    if isinstance(ro, str) and ro.startswith("macos"):
        return "macos-" + ro.split("-", 1)[1]
    if (job.get("strategy") or {}).get("matrix", {}).get("python"):
        return "py-matrix"
    paths = event_paths(doc, "pull_request") or []
    if not paths:
        return "always"
    real = [p for p in paths if not p.startswith(WF_REL + "/")]
    if "install.sh" in real or "install.sh.strings.en-GB.sh" in real:
        return "installer"
    if any(p.startswith("vendor/") for p in real):
        return "vendor"
    if any(re.search(r"walk|cut|release|appcast|dmg|gui/", p) for p in real):
        return "release-walk"
    return "misc"


def cmd_inventory(args):
    wfs = load_ref(args.ref) if args.ref else load_dir(os.path.join(REPO, WF_REL))
    rows = []
    for fname, (_, doc) in wfs.items():
        on = triggers(doc)
        pr = event_paths(doc, "pull_request")
        trig = ",".join(sorted(str(k) for k in on))
        filt = ("-" if pr is None else ("unfiltered" if not pr
                                        else f"{len(pr)} paths"))
        for jid, job in (doc.get("jobs") or {}).items():
            fam = propose_family(fname, doc, jid, job)
            mat = (job.get("strategy") or {}).get("matrix")
            width = 1
            if isinstance(mat, dict):
                for v in mat.values():
                    if isinstance(v, list):
                        width *= len(v)
            for i, step in enumerate(job.get("steps") or []):
                rows.append((fname, jid, str(job.get("name", jid)),
                             str(job.get("runs-on")), str(width), trig, filt,
                             fam, str(i), step_kind(step),
                             " ".join(sorted(scripts_in(step.get("run", ""))))
                             or "-"))
            if "uses" in job:
                rows.append((fname, jid, jid, "reusable", "1", trig, filt, fam,
                             "0", "uses:" + job["uses"], "-"))
    out = sys.stdout if args.out == "-" else open(args.out, "w", encoding="utf-8")
    out.write("# generated by scripts/ci_fold.py inventory"
              + (f" --ref {args.ref}" if args.ref else "") + "\n")
    out.write("# columns: workflow\tjob\tcheck_name\truns_on\tmatrix_width\t"
              "triggers\tpr_filter\tproposed_family\tstep\tkind\texecutes\n")
    for r in rows:
        out.write("\t".join(x.replace("\t", " ").replace("\n", " ")
                            for x in r) + "\n")
    if out is not sys.stdout:
        out.close()
    jobs = {(r[0], r[1]) for r in rows}
    print(f"inventory: {len(wfs)} workflow file(s), {len(jobs)} job(s), "
          f"{len(rows)} step row(s)", file=sys.stderr)
    return 0


# ---------------------------------------------------------------------------
# spec
# ---------------------------------------------------------------------------
def load_spec(path=None):
    path = path or os.path.join(REPO, SPEC_REL)
    fams = {}
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            if not line.strip() or line.startswith("#"):
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) != 3:
                raise CannotRun(f"ci_fold: CANNOT RUN -- {path}:{n} needs "
                                 f"family<TAB>workflow<TAB>job")
            fam, wf, jid = parts
            fams.setdefault(fam, []).append((wf, jid))
    return fams


# ---------------------------------------------------------------------------
# textual surgery on a workflow file (so comments survive the move)
# ---------------------------------------------------------------------------
def header_comments(text):
    out = []
    for line in text.splitlines():
        if line.startswith("#") or not line.strip():
            out.append(line)
        else:
            break
    while out and not out[-1].strip():
        out.pop()
    return out


def job_span(lines, jid):
    """[start, end) line span of job `jid` under `jobs:`, comments included."""
    try:
        jobs_at = next(i for i, l in enumerate(lines) if l.rstrip() == "jobs:")
    except StopIteration:
        raise CannotRun("ci_fold: CANNOT RUN -- no top-level jobs: key")
    key = re.compile(r"^  ([A-Za-z0-9_-]+):\s*(#.*)?$")
    starts = [(i, key.match(l).group(1)) for i, l in enumerate(lines)
              if i > jobs_at and key.match(l)]
    for k, (i, name) in enumerate(starts):
        if name != jid:
            continue
        end = starts[k + 1][0] if k + 1 < len(starts) else len(lines)
        # leading comment lines belong to this job
        s = i
        while s - 1 > jobs_at and (lines[s - 1].startswith("  #")
                                   or not lines[s - 1].strip()):
            s -= 1
        while s < i and not lines[s].strip():
            s += 1
        # trailing comments/blank lines before the next job belong to IT
        e = end
        while e - 1 > i and (lines[e - 1].startswith("  #")
                             or not lines[e - 1].strip()):
            e -= 1
        return s, i, e
    raise CannotRun(f"ci_fold: CANNOT RUN -- job {jid} not found textually")


def step_items(lines, job_start, job_end):
    """Split the job's `steps:` list into items, each with leading comments."""
    try:
        st = next(i for i in range(job_start, job_end)
                  if re.match(r"^    steps:\s*$", lines[i]))
    except StopIteration:
        raise CannotRun("ci_fold: CANNOT RUN -- job has no steps: block")
    body = lines[st + 1:job_end]
    first = next(i for i, l in enumerate(body) if l.lstrip().startswith("- "))
    ind = len(body[first]) - len(body[first].lstrip())
    items, cur, pending = [], None, []
    for l in body:
        stripped = l.strip()
        lead = len(l) - len(l.lstrip())
        if l.startswith(" " * ind + "- "):
            if cur is not None:
                items.append(cur)
            cur = {"comments": pending, "lines": [l], "ind": ind}
            pending = []
        elif stripped.startswith("#") and lead <= ind:
            pending.append(l)
        elif cur is not None:
            cur["lines"].append(l)
        elif stripped:
            raise CannotRun("ci_fold: CANNOT RUN -- unexpected text before "
                             "the first step")
    if cur is not None:
        items.append(cur)
    for it in items:                 # trailing blank lines are not content
        while it["lines"] and not it["lines"][-1].strip():
            it["lines"].pop()
    return items


def reindent(lines, delta):
    if delta == 0:
        return list(lines)
    if delta > 0:
        return [(" " * delta + l) if l.strip() else l for l in lines]
    out = []
    for l in lines:
        if l.strip() and not l.startswith(" " * -delta):
            raise CannotRun("ci_fold: CANNOT RUN -- cannot dedent a line")
        out.append(l[-delta:] if l.strip() else l)
    return out


def rewrite_item(item, new_id, new_if, timeout, id_map):
    """Return item text with id/if/timeout replaced; everything else verbatim."""
    ind = item["ind"]
    key_ind = ind + 2
    lines = list(item["lines"])
    # make the first line's inline key a normal key line
    first = lines[0]
    lines[0] = " " * key_ind + first[ind + 2:]
    top = re.compile(r"^ {%d}([A-Za-z0-9_-]+):(.*)$" % key_ind)
    kept = []
    i = 0
    while i < len(lines):
        m = top.match(lines[i])
        if m and m.group(1) in ("id", "if", "timeout-minutes"):
            # single-line values only; a continuation would be deeper-indented
            if i + 1 < len(lines) and lines[i + 1].startswith(" " * (key_ind + 1)) \
                    and not top.match(lines[i + 1]):
                raise CannotRun(f"ci_fold: CANNOT RUN -- multi-line "
                                 f"{m.group(1)}: is not supported")
            i += 1
            continue
        kept.append(lines[i])
        i += 1
    text = "\n".join(kept)
    for old, new in id_map.items():
        text = re.sub(r"\bsteps\.%s\." % re.escape(old), f"steps.{new}.", text)
    head = [" " * ind + f"- id: {new_id}",
            " " * key_ind + f"if: {new_if}",
            " " * key_ind + f"timeout-minutes: {timeout}"]
    return item["comments"] + head + text.split("\n")


# ---------------------------------------------------------------------------
# condition scoping
# ---------------------------------------------------------------------------
STATUS_FN = re.compile(r"\b(always|success|failure|cancelled)\(\)")


def strip_expr(cond):
    c = str(cond).strip()
    if c.startswith("${{") and c.endswith("}}"):
        c = c[3:-2].strip()
    return c


def scoped_if(orig, prior_ids, id_map, gate=None):
    ok_terms = ["!cancelled()"] + [f"steps.{p}.conclusion != 'failure'"
                                   for p in prior_ids]
    ok = " && ".join(ok_terms)
    bad = " || ".join(f"steps.{p}.conclusion == 'failure'"
                      for p in prior_ids) or "false"
    pre = f"{gate} && " if gate else ""
    if orig is None:
        return "${{ " + pre + ok + " }}"
    c = strip_expr(orig)
    for old, new in id_map.items():
        c = re.sub(r"\bsteps\.%s\." % re.escape(old), f"steps.{new}.", c)
    if not STATUS_FN.search(c):
        return "${{ " + f"{pre}({ok}) && ({c})" + " }}"
    c = re.sub(r"\bsuccess\(\)", f"({ok})", c)
    c = re.sub(r"\bfailure\(\)", f"(!cancelled() && ({bad}))", c)
    return "${{ " + (f"{pre}({c})" if pre else c) + " }}"


# ---------------------------------------------------------------------------
# generate
# ---------------------------------------------------------------------------
HOIST_CHECKOUT = "actions/checkout@v4"
READ_ONLY = {"contents": "read"}
# pull-requests: read is for the selector's list of the PR's changed files.
FAMILY_PERMS = {"contents": "read", "pull-requests": "read"}
TOKEN_RE = re.compile(r"secrets\.|GITHUB_TOKEN|GH_TOKEN|\bgh |api\.github")
HOIST_PYTHON = "actions/setup-python@v5"


# A member's checkout may be shallow (the default) or full. The family's is
# full if any member's was: deeper history is a superset, and nothing in this
# estate asserts a shallow clone.
CHECKOUT_WITH_OK = (None, {"fetch-depth": 0})


def uses_token(job):
    """Does a job's EXECUTED text use the GitHub token? Comments do not count:
    a `# gh pr list fails when...` note is not a call. A member that declares
    `contents: read` is never narrowed by the family's token (contents: read,
    pull-requests: read), so this matters only on default permissions."""
    parts = []
    for st in job.get("steps") or []:
        run = str(st.get("run") or "")
        parts += [l for l in run.splitlines() if not l.strip().startswith("#")]
        parts.append(json.dumps(st.get("env") or {}))
        parts.append(json.dumps(st.get("with") or {}))
    parts.append(json.dumps(job.get("env") or {}))
    return bool(TOKEN_RE.search("\n".join(parts)))


def hoist_shape(job):
    """How a job's leading steps hoist into a family, or None if they do not.

    "matrix": checkout + setup-python on ${{ matrix.python }}. Each block's
              venv is built from that interpreter.
    "plain":  checkout, and NO other action anywhere in the job. Each block's
              venv is built from the runner's own python3, with its
              system site-packages, so a block starts from exactly the base
              interpreter and its installs land in its own venv -- including
              `pip install --break-system-packages`, which on a shared
              machine would otherwise leak into every later block.
    A job that uses any other action (setup-python on a fixed version,
    upload-artifact, a local action) is not foldable here: an action's
    side effects on PATH and the environment cannot be undone per block."""
    steps = job.get("steps") or []
    if not steps:
        return None
    c = steps[0]
    if c.get("uses") != HOIST_CHECKOUT or set(c) - {"uses", "name", "with"}:
        return None
    if c.get("with") not in CHECKOUT_WITH_OK:
        return None
    if len(steps) > 1 and steps[1].get("uses") == HOIST_PYTHON:
        pstep = steps[1]
        if set(pstep) - {"uses", "with", "name"} or \
                pstep.get("with") != {"python-version": "${{ matrix.python }}"}:
            return None
        shape, rest = "matrix", steps[2:]
    else:
        shape, rest = "plain", steps[1:]
    if any("uses" in st for st in rest):
        return None
    return shape


def hoist_len(shape):
    return 2 if shape == "matrix" else 1


def cmd_generate(args):
    spec = load_spec(args.spec)
    if args.family not in spec:
        raise CannotRun(f"ci_fold: no family {args.family!r} in the spec")
    members = spec[args.family]
    wf_dir = args.dir or os.path.join(REPO, WF_REL)
    wfs = load_dir(wf_dir)
    fam_file = f"{FAMILY_PREFIX}{args.family}.yml"

    runs_on = matrix = shape = None
    deep = False
    pr_paths, push_paths, push_branches = [], [], None
    push_unfiltered = False
    blocks, total_timeout = [], 0
    removals = {}
    for n, (wf, jid) in enumerate(members, 1):
        if wf not in wfs:
            raise CannotRun(f"ci_fold: {wf} does not exist")
        if wf in STANDALONE:
            raise CannotRun(f"ci_fold: {wf} is never folded: {STANDALONE[wf]}")
        text, doc = wfs[wf]
        job = doc["jobs"].get(jid)
        if job is None:
            raise CannotRun(f"ci_fold: {wf} has no job {jid}")
        on = triggers(doc)
        extra = set(on) - {"pull_request", "push"}
        if extra:
            raise CannotRun(f"ci_fold: {wf} has triggers {sorted(extra)}; "
                             f"only pull_request/push workflows are folded")
        pb = (on.get("push") or {}).get("branches")
        if (on.get("push") or {}).get("tags"):
            raise CannotRun(f"ci_fold: {wf} fires on tags; not folded")
        if push_branches is None:
            push_branches = pb
        elif pb != push_branches:
            raise CannotRun(f"ci_fold: {wf} push branches {pb} differ")
        for k in ("needs", "if", "services", "container", "env", "defaults",
                  "permissions", "outputs", "uses", "environment",
                  "continue-on-error"):
            if k in job:
                raise CannotRun(f"ci_fold: {wf}:{jid} has job-level {k}:; "
                                 f"not folded by this generator")
        for k in ("env", "defaults"):
            if k in doc:
                raise CannotRun(f"ci_fold: {wf} has workflow-level {k}:")
        # The family token is read-only. That is the same as or NARROWER than
        # every member's, which is only safe if no member uses the token.
        if doc.get("permissions") not in (None, READ_ONLY):
            raise CannotRun(f"ci_fold: {wf} permissions "
                             f"{doc.get('permissions')} are not foldable")
        if doc.get("permissions") is None and uses_token(job):
            raise CannotRun(f"ci_fold: {wf} uses the token on the repo's "
                            f"DEFAULT permissions; a read-only family token "
                            f"could break it")
        ro = job.get("runs-on")
        strat = job.get("strategy") or {}
        if runs_on is None:
            runs_on, matrix = ro, strat
        elif ro != runs_on or strat != matrix:
            raise CannotRun(f"ci_fold: {wf}:{jid} runner/matrix differs from "
                             f"the family's ({ro} {strat})")
        js = hoist_shape(job)
        if js is None:
            raise CannotRun(f"ci_fold: {wf}:{jid} does not start with a "
                            f"hoistable checkout (+ matrix setup-python), or "
                            f"uses another action")
        if shape is None:
            shape = js
        elif js != shape:
            raise CannotRun(f"ci_fold: {wf}:{jid} is a {js} job in a {shape} "
                            f"family")
        if js == "plain" and job.get("strategy"):
            raise CannotRun(f"ci_fold: {wf}:{jid} has a matrix but no "
                            f"matrix setup-python; not modelled")
        deep = deep or job["steps"][0].get("with") == {"fetch-depth": 0}
        self_watch = f"{WF_REL}/{wf}"
        own = [p for p in event_paths(doc, "pull_request") or []
               if p != self_watch]
        for p in own:
            if p not in pr_paths:
                pr_paths.append(p)
        if not event_paths(doc, "pull_request"):
            raise CannotRun(f"ci_fold: {wf} is unfiltered on pull_request; "
                             f"fold it into an unfiltered family instead")
        pp = event_paths(doc, "push")
        if pp is not None:
            if not pp:
                # A member that runs on EVERY push makes the family do so:
                # the union of "every push" and anything is every push. On a
                # push the selector runs every block anyway.
                push_unfiltered = True
            for p in pp:
                if p != self_watch and p not in push_paths:
                    push_paths.append(p)
        jt = int(job.get("timeout-minutes") or 0)
        if jt <= 0:
            raise CannotRun(f"ci_fold: {wf}:{jid} declares no timeout")
        total_timeout += jt

        lines = text.splitlines()
        s, k, e = job_span(lines, jid)
        items = step_items(lines, k, e)
        if len(items) != len(job["steps"]):
            raise CannotRun(f"ci_fold: {wf}:{jid} textual step count "
                             f"{len(items)} != parsed {len(job['steps'])}")
        tag = f"b{n:02d}"
        gate = f"steps.select.outputs.{tag} != 'false'"
        hl = hoist_len(js)
        rest = list(zip(items[hl:], job["steps"][hl:]))
        id_map = {st["id"]: f"{tag}_{st['id']}" for _, st in rest if "id" in st}
        pre_id = f"{tag}_isolate"
        out_steps, prior = [], [pre_id]
        for i, (it, st) in enumerate(rest, 1):
            new_id = id_map.get(st.get("id"), f"{tag}_s{i:02d}")
            stt = st.get("timeout-minutes")
            stt = min(int(stt), jt) if stt is not None else jt
            new_if = scoped_if(st.get("if"), prior, id_map, gate)
            out_steps += rewrite_item(it, new_id, new_if, stt, id_map)
            prior.append(new_id)
        delta = 6 - items[0]["ind"]
        blocks.append({"tag": tag, "wf": wf, "jid": jid, "pre_id": pre_id,
                       "header": header_comments(text),
                       "jobcomments": [l for l in lines[s:k] if l.strip()],
                       "steps": reindent(out_steps, delta),
                       "name": job.get("name", jid), "gate": gate,
                       "own": own})
        removals.setdefault(wf, []).append(jid)

    fam_self = f"{WF_REL}/{fam_file}"
    for p in SELECT_ALWAYS + (fam_self,):
        if p not in pr_paths:
            pr_paths.append(p)
    if push_branches is not None:
        push_paths.append(f"{WF_REL}/{fam_file}")
    job_timeout = min(total_timeout, 70)

    o = []
    o += [f"# {fam_file} -- GENERATED by scripts/ci_fold.py generate "
          f"{args.family}.",
          "#",
          "# The pull request that adds this family's rows to "
          f"{SPEC_REL} is proven by",
          "# scripts/ci_fold.py check against its base: every source step "
          "verbatim, every",
          "# trigger a superset, every executed script still executed. "
          "Once merged, this",
          "# file IS the source: edit a block here as you would any "
          "workflow, keeping its",
          "# isolate step first and its step conditions block-scoped.",
          "#",
          ("# One job per matrix leg instead of one per source job. Each block "
           "below was a" if shape == "matrix" else
           "# One job instead of one per source job. Each block below was a"),
          "# separate job; it gets back what a fresh machine gave it (pristine "
          "checkout,",
          "# fresh venv, fresh HOME and TMPDIR) and its step conditions are "
          "scoped to the",
          "# block, so one block failing cannot skip another block's tests. "
          "The source",
          "# workflows' own header comments are carried verbatim above each "
          "block.",
          "#",
          f"# Folded jobs ({len(blocks)}):"]
    for b in blocks:
        o.append(f"#   {b['tag']}  {b['wf']} :: {b['jid']}")
    o += [f"name: {FAMILY_PREFIX}{args.family}", "", "on:"]
    if push_branches is not None:
        o += ["  push:", f"    branches: {flow(push_branches)}"]
        if push_unfiltered:
            o += ["    # Unfiltered: at least one member ran on every push."]
        else:
            o += ["    paths:"]
            o += [f"      - {q(p)}" for p in push_paths]
    o += ["  pull_request:", "    paths:"]
    o += [f"      - {q(p)}" for p in pr_paths]
    o += ["",
          "concurrency:",
          "  group: ${{ github.workflow }}-${{ github.event.pull_request.number"
          " || github.ref }}",
          "  cancel-in-progress: ${{ github.ref != 'refs/heads/main' && "
          "!startsWith(github.ref, 'refs/tags/') }}",
          "",
          "# Read-only. No folded member uses the token (checked at generate);",
          "# the selector reads the PR's changed-file list with it.",
          "permissions:",
          "  contents: read",
          "  pull-requests: read",
          "",
          "jobs:",
          f"  {args.family}:",
          f"    runs-on: {runs_on}",
          f"    # Sum of the folded jobs' own timeouts ({total_timeout} min), "
          f"capped at 70 so the",
          "    # CI Required Gate (75 min hard cap) still sees a verdict. "
          "Every step below",
          "    # keeps its old job's timeout, so a hang is bounded where it "
          "always was.",
          f"    timeout-minutes: {job_timeout}"]
    if matrix:
        o.append("    strategy:")
        o += ["      " + l for l in
              yaml.safe_dump(matrix, default_flow_style=None,
                             sort_keys=False).rstrip().split("\n")]
    o += ["    steps:",
          "      - uses: actions/checkout@v4"]
    if deep:
        o += ["        with:",
              "          # A member checked out full history; the family "
              "does for all.",
              "          fetch-depth: 0"]
    if shape == "matrix":
        o += ["      - id: python",
              "        uses: actions/setup-python@v5",
              "        with:",
              "          python-version: ${{ matrix.python }}",
              "          # Speed only: a warm wheel cache. Each block still "
              "installs exactly",
              "          # what its own steps name, into its own fresh venv.",
              "          cache: pip",
              f"          cache-dependency-path: {WF_REL}/{fam_file}"]
    else:
        o += ["      # The runner's own python3, which each block's venv is "
              "built from (with",
              "      # its system site-packages), so every block starts from "
              "what a fresh",
              "      # machine gave it and installs into its own venv.",
              "      - id: python",
              "        name: The runner's python3, the base of every block's "
              "venv",
              "        run: echo \"python-path=$(command -v python3)\" >> "
              "\"$GITHUB_OUTPUT\""]
    o += [
          "      - name: Pin the pip cache to the real HOME before blocks "
          "move it",
          "        run: echo \"PIP_CACHE_DIR=$HOME/.cache/pip\" >> "
          "\"$GITHUB_ENV\"",
          "      # Each block runs only if the PR changes a file its OWN old "
          "workflow watched",
          f"      # ({PATHS_REL}), so the family does the work the old jobs "
          "did, no more.",
          "      # FAILS OPEN: a push, an API error, an empty or capped file "
          "list, or a glob",
          "      # form it cannot model exactly runs the block. Skipping is "
          "the only outcome",
          "      # that needs evidence.",
          "      - id: select",
          "        name: Which blocks this change can affect (fails open)",
          "        if: ${{ always() }}",
          "        env:",
          "          GH_TOKEN: ${{ github.token }}",
          "          EVENT_NAME: ${{ github.event_name }}",
          "          PR_NUMBER: ${{ github.event.pull_request.number }}",
          "          REPO: ${{ github.repository }}",
          f"        run: python3 scripts/ci_fold.py select {args.family}"]
    for b in blocks:
        o.append("")
        o.append("      # " + "=" * 72)
        o.append(f"      # {b['tag']}: {b['wf']} :: {b['jid']}")
        o.append("      # " + "=" * 72)
        for l in b["header"]:
            o.append(("      " + l) if l.strip() else "      #")
        for l in b["jobcomments"]:
            o.append("      " + l.strip())
        o += [f"      - id: {b['pre_id']}",
              f"        name: \"[{b['tag']}] {b['wf']} :: {b['jid']} -- "
              f"fresh tree, venv, HOME, TMPDIR\"",
              "        if: ${{ !cancelled() && " + b["gate"] + " }}",
              "        env:",
              "          PY: ${{ steps.python.outputs.python-path }}",
              f"          BLOCK: ${{{{ runner.temp }}}}/ci-fold/{b['tag']}",
              "        run: |",
              # No pipefail, and no pipe to need it. tests/test_pipefail_
              # shortcircuit_inversion.sh counts per FILE, so a pipefail here
              # would make every folded block's `x | grep -q` look new.
              "          set -eu",
              "          git -C \"$GITHUB_WORKSPACE\" reset --hard -q HEAD",
              "          git -C \"$GITHUB_WORKSPACE\" clean -ffdxq",
              "          rm -rf \"$BLOCK\"",
              "          mkdir -p \"$BLOCK/home\" \"$BLOCK/tmp\"",
              "          \"$PY\" -m venv " +
              ("" if shape == "matrix" else "--system-site-packages ") +
              "\"$BLOCK/venv\"",
              "          echo \"$BLOCK/venv/bin\" >> \"$GITHUB_PATH\"",
              "          {",
              "            echo \"HOME=$BLOCK/home\"",
              "            echo \"TMPDIR=$BLOCK/tmp\"",
              "            echo \"VIRTUAL_ENV=$BLOCK/venv\"",
              "          } >> \"$GITHUB_ENV\""]
        o += b["steps"]
    body = "\n".join(o) + "\n"
    yaml.safe_load(body)          # must parse, or nothing is written
    ptsv = os.path.join(os.path.dirname(wf_dir), os.path.basename(PATHS_REL))
    keep = []
    if os.path.exists(ptsv):
        keep = [l for l in open(ptsv, encoding="utf-8").read().splitlines()
                if l and not l.startswith("#")
                and l.split("\t")[0] != args.family]
    with open(ptsv, "w", encoding="utf-8") as fh:
        fh.write("# GENERATED by scripts/ci_fold.py generate. Read by "
                 "scripts/ci_fold.py select.\n"
                 "# A block runs on a PR that changes a file matching ANY of "
                 "its rows. The rows\n"
                 "# are its old workflow's own pull_request paths, plus the "
                 "selector, this file\n"
                 "# and the family workflow, so a change to the selection "
                 "itself runs everything.\n"
                 "# columns: family\tblock\tsource\tpattern\n")
        for l in keep:
            fh.write(l + "\n")
        for b in blocks:
            for p in b["own"] + list(SELECT_ALWAYS) + [fam_self]:
                fh.write(f"{args.family}\t{b['tag']}\t{b['wf']}::{b['jid']}"
                         f"\t{p}\n")
    with open(os.path.join(wf_dir, fam_file), "w", encoding="utf-8") as fh:
        fh.write(body)

    for wf, jids in removals.items():
        text, doc = wfs[wf]
        if set(jids) == set(doc["jobs"]):
            os.remove(os.path.join(wf_dir, wf))
            print(f"removed   {wf} (all {len(jids)} job(s) folded)")
            continue
        lines = text.splitlines()
        spans = sorted((job_span(lines, j) for j in jids), reverse=True)
        for s, _, e in spans:
            del lines[s:e]
        new = "\n".join(lines).rstrip("\n") + "\n"
        new = re.sub(r"\n{3,}", "\n\n", new)
        yaml.safe_load(new)
        with open(os.path.join(wf_dir, wf), "w", encoding="utf-8") as fh:
            fh.write(new)
        print(f"trimmed   {wf} (folded {', '.join(jids)}; kept the rest)")
    print(f"generated {WF_REL}/{fam_file}: {len(blocks)} block(s)")
    return 0


def q(p):
    return "'" + str(p).replace("'", "''") + "'"


def flow(v):
    return "[" + ", ".join(str(x) for x in v) + "]"


# ---------------------------------------------------------------------------
# check -- independent of generate: re-derives nothing, compares outcomes
# ---------------------------------------------------------------------------
IGNORED_STEP_KEYS = {"id", "if", "timeout-minutes"}


def norm_step(st, id_map):
    d = {k: v for k, v in st.items() if k not in IGNORED_STEP_KEYS}
    s = yaml.safe_dump(d, sort_keys=True)
    for old, new in id_map.items():
        s = re.sub(r"\bsteps\.%s\." % re.escape(new), f"steps.{old}.", s)
    return s


def all_scripts(wfs):
    found = {}
    for fname, (_, doc) in wfs.items():
        for jid, job in (doc.get("jobs") or {}).items():
            for st in job.get("steps") or []:
                for s in scripts_in(st.get("run", "")):
                    found.setdefault(s, set()).add(f"{fname}::{jid}")
    return found


def base_spec(args):
    """The spec as it was at the base. Rows already there were proven by the
    pull request that added them; only rows NEW in this change are folds to
    prove now."""
    if args.base_dir:
        return load_spec(args.base_spec) if args.base_spec else {}
    try:
        text = subprocess.run(["git", "-C", REPO, "show",
                               f"{args.base}:{SPEC_REL}"], check=True,
                              capture_output=True).stdout.decode()
    except subprocess.CalledProcessError:
        return {}
    fd, tmp = tempfile.mkstemp(prefix="ci_fold_spec_")
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
    return load_spec(tmp)


def cmd_check(args):
    before = (load_dir(args.base_dir) if args.base_dir
              else load_ref(args.base))
    after = load_dir(args.tree or os.path.join(REPO, WF_REL))
    full = load_spec(args.spec)
    old = base_spec(args)
    old_rows = {(f, w, j) for f, ms in old.items() for w, j in ms}
    spec = {}
    for fam, members in full.items():
        new = [(w, j) for w, j in members if (fam, w, j) not in old_rows]
        if not new:
            continue
        if len(new) != len(members):
            raise CannotRun(f"family {fam} gains members after it was "
                            f"folded; extending a family is not modelled -- "
                            f"fold the new jobs into a new family")
        spec[fam] = members
    for fam, members in old.items():
        if any((w, j) not in full.get(fam, []) for w, j in members):
            print(f"NOTE: spec rows removed for {fam}; an unfold is an "
                  f"ordinary workflow change and is not proven here",
                  file=sys.stderr)
    if not spec:
        print("no new fold in this change: nothing to prove (spec rows "
              "unchanged from the base)")
        return 0
    problems, mapping = [], []
    folded = {}
    for fam, members in spec.items():
        for wf, jid in members:
            folded[(wf, jid)] = fam

    # 1. every job not in the spec is byte-for-byte the same job, same file
    for wf, (_, bdoc) in before.items():
        for jid, bjob in (bdoc.get("jobs") or {}).items():
            if (wf, jid) in folded:
                continue
            if wf not in after:
                problems.append(f"{wf}::{jid} vanished and is not in the spec")
                continue
            adoc = after[wf][1]
            if (adoc.get("jobs") or {}).get(jid) != bjob:
                problems.append(f"{wf}::{jid} changed but is not in the spec")
            if triggers(adoc) != triggers(bdoc):
                problems.append(f"{wf}: triggers changed but no job of it "
                                f"is folded")
            mapping.append((wf, jid, "unchanged", wf, jid))

    # 2. every folded job: verbatim steps, same runner/matrix, superset triggers
    for fam, members in spec.items():
        fam_file = f"{FAMILY_PREFIX}{fam}.yml"
        if fam_file not in after:
            problems.append(f"{fam_file} is missing")
            continue
        adoc = after[fam_file][1]
        if len(adoc["jobs"]) != 1:
            problems.append(f"{fam_file}: expected exactly one job")
            continue
        fjid, fjob = next(iter(adoc["jobs"].items()))
        fsteps = fjob.get("steps") or []
        apr = event_paths(adoc, "pull_request")
        apush = event_paths(adoc, "push")
        self_watch = f"{WF_REL}/{fam_file}"
        if adoc.get("permissions") != FAMILY_PERMS:
            problems.append(f"{fam_file}: token is not read-only "
                            f"({adoc.get('permissions')})")
        sel = [st for st in fsteps if st.get("id") == "select"]
        if len(sel) != 1 or f"scripts/ci_fold.py select {fam}" not in \
                str(sel[0].get("run", "")) or \
                "always()" not in str(sel[0].get("if", "")):
            problems.append(f"{fam_file}: no always-run selector step for "
                            f"{fam}")
        tree_dir = args.tree or os.path.join(REPO, WF_REL)
        ptsv = os.path.join(os.path.dirname(tree_dir),
                            os.path.basename(PATHS_REL))
        rows = {}
        try:
            for l in open(ptsv, encoding="utf-8"):
                if l.startswith("#") or not l.strip():
                    continue
                f_, t_, src_, pat_ = l.rstrip("\n").split("\t")
                if f_ == fam:
                    rows.setdefault(t_, (src_, set()))[1].add(pat_)
        except (OSError, ValueError) as e:
            problems.append(f"{ptsv} unreadable: {e}")
        for t_, (_, pats) in rows.items():
            missing = sorted(pats - set(apr or []))
            if missing:
                problems.append(f"{fam_file}: block {t_} selects on "
                                f"{missing} but the family is not triggered "
                                f"by them")
        if not apr or self_watch not in apr:
            problems.append(f"{fam_file} does not watch itself")
        for n, (wf, jid) in enumerate(members, 1):
            tag = f"b{n:02d}"
            if wf not in before or jid not in before[wf][1]["jobs"]:
                problems.append(f"spec names {wf}::{jid}, absent at base")
                continue
            bdoc = before[wf][1]
            bjob = bdoc["jobs"][jid]
            if wf in after and jid in (after[wf][1].get("jobs") or {}):
                problems.append(f"{wf}::{jid} folded AND still present")
            if wf in after:
                rest = {k: v for k, v in bdoc["jobs"].items()
                        if (wf, k) not in folded}
                if (after[wf][1].get("jobs") or {}) != rest:
                    problems.append(f"{wf}: its unfolded jobs changed")
            if fjob.get("runs-on") != bjob.get("runs-on"):
                problems.append(f"{wf}::{jid} runs-on changed")
            if bdoc.get("permissions") is None and uses_token(bjob):
                problems.append(f"{wf}::{jid} calls the token on DEFAULT "
                                f"permissions; the family's read-only token "
                                f"could narrow it")
            if (fjob.get("strategy") or {}) != (bjob.get("strategy") or {}):
                problems.append(f"{wf}::{jid} strategy/matrix changed")
            # triggers
            old_self = f"{WF_REL}/{wf}"
            for ev, apaths in (("pull_request", apr), ("push", apush)):
                bp = event_paths(bdoc, ev)
                if bp is None:
                    continue
                if apaths is None:
                    problems.append(f"{wf}: {ev} trigger dropped")
                    continue
                if not bp:
                    if apaths:
                        problems.append(f"{wf}: {ev} was unfiltered, family "
                                        f"is filtered")
                    continue
                if apaths:
                    lost = [p for p in bp if p != old_self and p not in apaths]
                    if lost:
                        problems.append(f"{wf}: {ev} paths narrowed, lost "
                                        f"{lost}")
            bpb = (triggers(bdoc).get("push") or {}).get("branches")
            apb = (triggers(adoc).get("push") or {}).get("branches")
            if bpb != apb:
                problems.append(f"{wf}: push branches {bpb} -> {apb}")
            # the hoisted steps: the member's must be ones the family runs
            # once for all, and no deeper or different than the family's
            js = hoist_shape(bjob)
            if js is None:
                problems.append(f"{wf}::{jid} did not start with a hoistable "
                                f"checkout, or used another action")
                continue
            fco = fsteps[0] if fsteps else {}
            mwith = bjob["steps"][0].get("with") or {}
            if fco.get("uses") != HOIST_CHECKOUT or \
                    any((fco.get("with") or {}).get(k) != v
                        for k, v in mwith.items()):
                problems.append(f"{fam_file}: its checkout does not cover "
                                f"{wf}::{jid}'s ({mwith or 'default'})")
            if js == "matrix":
                if len(fsteps) < 2 or fsteps[1].get("uses") != HOIST_PYTHON or \
                        (fsteps[1].get("with") or {}).get("python-version") \
                        != "${{ matrix.python }}":
                    problems.append(f"{fam_file}: no hoisted matrix "
                                    f"setup-python for {wf}::{jid}")
            else:
                py = [st for st in fsteps if st.get("id") == "python"]
                if not py or "command -v python3" not in str(py[0].get("run")):
                    problems.append(f"{fam_file}: no runner-python step for "
                                    f"the plain block of {wf}::{jid}")
            # verbatim steps, in order, in this block
            block = [s for s in fsteps
                     if str(s.get("id", "")).startswith(tag + "_")]
            if not block or block[0].get("id") != f"{tag}_isolate":
                problems.append(f"{wf}::{jid}: block {tag} has no isolate "
                                f"step first")
                continue
            pre, body = block[0], block[1:]
            if "!cancelled()" not in str(pre.get("if", "")):
                problems.append(f"{tag}_isolate can be skipped by another "
                                f"block's failure")
            gate = f"steps.select.outputs.{tag} != 'false'"
            for st in block:
                if gate not in str(st.get("if", "")):
                    problems.append(f"{wf}::{jid}: step {st.get('id')} is "
                                    f"not gated on its own selection, so "
                                    f"the selector cannot be trusted to "
                                    f"mean anything")
            src_, pats = rows.get(tag, ("", set()))
            if src_ != f"{wf}::{jid}":
                problems.append(f"{PATHS_REL}: block {tag} is recorded as "
                                f"{src_!r}, not {wf}::{jid}")
            want = {p for p in (event_paths(bdoc, "pull_request") or [])
                    if p != f"{WF_REL}/{wf}"}
            want |= set(SELECT_ALWAYS) | {self_watch}
            lost = sorted(want - pats)
            if lost:
                problems.append(f"{wf}::{jid}: block {tag} no longer selects "
                                f"on {lost}")
            bsteps = bjob["steps"][hoist_len(js):]
            if len(body) != len(bsteps):
                problems.append(f"{wf}::{jid}: {len(bsteps)} step(s) at base, "
                                f"{len(body)} in block {tag}")
                continue
            id_map = {st["id"]: f"{tag}_{st['id']}"
                      for st in bsteps if "id" in st}
            jt = int(bjob.get("timeout-minutes") or 0)
            prior = [pre["id"]]
            for i, (bs, fs) in enumerate(zip(bsteps, body), 1):
                if norm_step(bs, {}) != norm_step(fs, id_map):
                    problems.append(f"{wf}::{jid} step {i + 2} is not "
                                    f"verbatim in block {tag}")
                cond = strip_expr(fs.get("if", ""))
                borig = bs.get("if")
                if borig is None:
                    need = ["!cancelled()"] + [
                        f"steps.{p}.conclusion != 'failure'" for p in prior]
                    if any(t not in cond for t in need):
                        problems.append(f"{wf}::{jid} step {i + 2}: implicit "
                                        f"success() not scoped to its block")
                else:
                    ob = strip_expr(borig)
                    for old, new in id_map.items():
                        ob = re.sub(r"\bsteps\.%s\." % re.escape(old),
                                    f"steps.{new}.", ob)
                    has_fn = STATUS_FN.search(ob)
                    if "always()" in ob and "always()" not in cond:
                        problems.append(f"{wf}::{jid} step {i + 2}: always() "
                                        f"lost")
                    if not has_fn and ob not in cond:
                        problems.append(f"{wf}::{jid} step {i + 2}: its own "
                                        f"condition was not carried")
                ft = fs.get("timeout-minutes")
                bt = bs.get("timeout-minutes")
                want = min(int(bt), jt) if bt is not None else jt
                if ft is None or int(ft) > want:
                    problems.append(f"{wf}::{jid} step {i + 2}: timeout "
                                    f"{ft} wider than its old bound {want}")
                prior.append(fs.get("id"))
            mapping.append((wf, jid, "folded", fam_file, fjid))

    # 3. nothing in the after tree that the spec does not explain
    for wf, (_, adoc) in after.items():
        if wf in before:
            continue
        if wf[len(FAMILY_PREFIX):-4] in spec and wf.startswith(FAMILY_PREFIX):
            continue
        problems.append(f"{wf} is new and is not a family folded here")

    # 4. the executed-script set is a superset
    bs, as_ = all_scripts(before), all_scripts(after)
    lost = sorted(set(bs) - set(as_))
    for s in lost:
        problems.append(f"script no longer executed by any workflow: {s}")

    njobs = sum(len(d.get("jobs") or {}) for _, d in before.values())
    ajobs = sum(len(d.get("jobs") or {}) for _, d in after.values())
    print(f"base {args.base_dir or args.base}: {len(before)} workflow(s), {njobs} job(s), "
          f"{len(bs)} executed script(s)")
    print(f"tree         : {len(after)} workflow(s), {ajobs} job(s), "
          f"{len(as_)} executed script(s)")
    print(f"folded       : {len(folded)} job(s) into {len(spec)} family(s); "
          f"{sum(1 for m in mapping if m[2] == 'unchanged')} job(s) unchanged")
    if args.mapping:
        with open(args.mapping, "w", encoding="utf-8") as fh:
            fh.write("# before_workflow\tbefore_job\tfate\tafter_workflow"
                     "\tafter_job\n")
            for m in sorted(mapping):
                fh.write("\t".join(m) + "\n")
    if args.scripts_diff:
        with open(args.scripts_diff, "w", encoding="utf-8") as fh:
            fh.write("# script\tbefore_runners\tafter_runners\n")
            for s in sorted(set(bs) | set(as_)):
                fh.write(f"{s}\t{','.join(sorted(bs.get(s, ())))}\t"
                         f"{','.join(sorted(as_.get(s, ())))}\n")
    if njobs == 0 or (len(mapping) != njobs):
        problems.append(f"accounted for {len(mapping)} of {njobs} base jobs")
    if problems:
        print(f"\nNOT PROVEN: {len(problems)} problem(s)", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1
    print("PROVEN: every base job is unchanged or folded verbatim; triggers "
          "and executed scripts are supersets.")
    return 0


# ---------------------------------------------------------------------------
# select -- which blocks a pull request can affect. FAILS OPEN.
# ---------------------------------------------------------------------------
# GitHub's own filter syntax, as used in this repository's workflows, is
# literal paths plus `*` (any run of characters except "/") and `**` (any run
# including "/"). Measured 2026-10-17 over every workflow: those are the ONLY
# special characters in use. A pattern carrying anything else (? [ ] { } + !)
# is not modelled and MATCHES EVERYTHING, so an unmodelled pattern can only
# make a block run that need not have, never skip one that should have.
GITHUB_FILES_CAP = 3000   # the pulls/files API stops listing here


def glob_to_re(pat):
    if re.search(r"[?\[\]{}+!]", pat):
        return None
    out, i = [], 0
    while i < len(pat):
        if pat.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pat.startswith("**", i):
            out.append(".*")
            i += 2
        elif pat[i] == "*":
            out.append("[^/]*")
            i += 1
        else:
            out.append(re.escape(pat[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def matches(pat, path):
    rx = glob_to_re(pat)
    return True if rx is None else bool(rx.match(path))


def pr_files():
    """(files, reason). files is None when the list cannot be trusted."""
    seam = os.environ.get("CI_FOLD_FILES")
    if seam:
        try:
            lines = open(seam, encoding="utf-8").read().splitlines()
        except OSError as e:
            return None, f"could not read {seam}: {e}"
    else:
        num, repo = os.environ.get("PR_NUMBER"), os.environ.get("REPO")
        if not num or not repo:
            return None, "no PR number or repository in the environment"
        try:
            p = subprocess.run(
                ["gh", "api", "--paginate",
                 f"repos/{repo}/pulls/{num}/files?per_page=100", "--jq",
                 ".[] | .filename, (.previous_filename // empty)"],
                capture_output=True, timeout=120)
        except (OSError, subprocess.TimeoutExpired) as e:
            return None, f"could not ask GitHub for the file list: {e}"
        if p.returncode != 0:
            return None, ("GitHub refused the file list: "
                          + p.stderr.decode(errors="replace").strip()[:200])
        lines = p.stdout.decode(errors="replace").splitlines()
    files = sorted({l.strip() for l in lines if l.strip()})
    if not files:
        return None, "the file list came back EMPTY; a PR changes something"
    if len(files) >= GITHUB_FILES_CAP:
        return None, f"{len(files)} files: at or over the API's listing cap"
    return files, f"{len(files)} changed file(s)"


def cmd_select(args):
    ptsv = args.paths or os.path.join(REPO, PATHS_REL)
    blocks = {}
    try:
        for l in open(ptsv, encoding="utf-8"):
            if l.startswith("#") or not l.strip():
                continue
            fam, tag, src, pat = l.rstrip("\n").split("\t")
            if fam == args.family:
                blocks.setdefault(tag, [src, []])[1].append(pat)
    except (OSError, ValueError) as e:
        # Without the block list there are no outputs at all, and an absent
        # output reads != 'false': every block runs. Fail open, loudly.
        print(f"select: cannot read {ptsv} ({e}); EVERY block runs",
              file=sys.stderr)
        return 0
    if not blocks:
        print(f"select: no rows for {args.family} in {ptsv}; EVERY block "
              f"runs", file=sys.stderr)
        return 0
    event = os.environ.get("EVENT_NAME", "")
    files, why = (None, f"event is {event or 'unknown'}, not a pull request")
    if event == "pull_request":
        files, why = pr_files()
    decision, lines = {}, []
    for tag, (src, pats) in sorted(blocks.items()):
        if files is None:
            decision[tag], reason = True, "fail open: " + why
        else:
            hit = next(((f, pt) for f in files for pt in pats
                        if matches(pt, f)), None)
            decision[tag] = hit is not None
            reason = (f"{hit[0]} matches {hit[1]}" if hit
                      else f"none of {len(files)} file(s) match its "
                           f"{len(pats)} pattern(s)")
        lines.append(f"{tag}\t{'RUN ' if decision[tag] else 'skip'}\t{src}"
                     f"\t{reason}")
    print(f"select {args.family}: {why}; "
          f"{sum(decision.values())} of {len(decision)} block(s) run")
    for l in lines:
        print("  " + l.replace("\t", "  "))
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            for tag, run in decision.items():
                fh.write(f"{tag}={'true' if run else 'false'}\n")
    summ = os.environ.get("GITHUB_STEP_SUMMARY")
    if summ:
        with open(summ, "a", encoding="utf-8") as fh:
            fh.write(f"### {args.family}: {sum(decision.values())} of "
                     f"{len(decision)} block(s) run\n\n{why}\n\n"
                     "| block | decision | source | why |\n|---|---|---|---|\n")
            for l in lines:
                fh.write("| " + " | ".join(l.split("\t")) + " |\n")
    return 0


# ---------------------------------------------------------------------------
# run-local -- execute a family job on this machine, GitHub step semantics
# ---------------------------------------------------------------------------
# Only what family jobs use is modelled: run: steps under bash, the hoisted
# checkout/setup-python (replaced by a disposable worktree and a named
# interpreter), $GITHUB_ENV/$GITHUB_PATH/$GITHUB_OUTPUT, and conditions built
# from always()/!cancelled()/success()/failure() and steps.<id>.conclusion|
# outcome|outputs. ANY other expression makes the step CANNOT-EMULATE, which
# fails the run: a local green that skipped a step it could not read would be
# exactly the vacuous pass this file exists to refuse.
EXPR = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")


class CannotEmulate(Exception):
    pass


def eval_expr(expr, ctx):
    e = expr
    def ref(m):
        sid, kind, rest = m.group(1), m.group(2), m.group(3)
        st = ctx["steps"].get(sid)
        if st is None:
            return repr("")
        if kind == "outputs":
            return repr(st["outputs"].get(rest, ""))
        return repr(st[kind])
    e = re.sub(r"steps\.([A-Za-z0-9_-]+)\.(conclusion|outcome|outputs)"
               r"(?:\.([A-Za-z0-9_-]+))?", ref, e)
    e = e.replace("matrix.python", repr(ctx["python_version"]))
    e = e.replace("github.event_name", repr("pull_request"))
    e = e.replace("always()", "True").replace("cancelled()", "False")
    e = e.replace("success()", repr(not ctx["failed"]))
    e = e.replace("failure()", repr(ctx["failed"]))
    e = e.replace("&&", " and ").replace("||", " or ")
    e = re.sub(r"!(?!=)", " not ", e)
    if re.search(r"[A-Za-z_][\w.]*\(|\b(github|env|runner|secrets|vars|inputs)"
                 r"\.", e):
        raise CannotEmulate(expr)
    try:
        return eval(e, {"__builtins__": {}}, {"True": True, "False": False})
    except Exception:
        raise CannotEmulate(expr)


def subst(text, ctx):
    def one(m):
        x = m.group(1)
        if x == "runner.temp":
            return ctx["runner_temp"]
        if x == "github.workspace":
            return ctx["workspace"]
        if x == "steps.python.outputs.python-path" and ctx["matrix_shape"]:
            return ctx["python"]
        if x == "matrix.python":
            return ctx["python_version"]
        # The selector's inputs. Locally there is no PR, so it fails open and
        # every block runs -- the local run is the superset, by construction.
        if x in ("github.event_name",):
            return "pull_request"
        if x in ("github.token", "github.repository",
                 "github.event.pull_request.number"):
            return ""
        m2 = re.fullmatch(r"steps\.([\w-]+)\.outputs\.([\w-]+)", x)
        if m2:
            return ctx["steps"].get(m2.group(1), {}).get("outputs", {}).get(
                m2.group(2), "")
        raise CannotEmulate(x)
    return EXPR.sub(one, str(text))


def read_kv(path):
    out = {}
    if not os.path.exists(path):
        return out
    lines = open(path, encoding="utf-8").read().splitlines()
    i = 0
    while i < len(lines):
        l = lines[i]
        m = re.match(r"^([^=<]+)<<(.+)$", l)
        if m:
            val, i = [], i + 1
            while i < len(lines) and lines[i] != m.group(2):
                val.append(lines[i])
                i += 1
            out[m.group(1)] = "\n".join(val)
        elif "=" in l:
            k, v = l.split("=", 1)
            out[k] = v
        i += 1
    return out


def cmd_run_local(args):
    import shutil
    import time
    path = args.workflow
    doc = yaml.safe_load(open(path, encoding="utf-8"))
    (jid, job), = doc["jobs"].items()
    steps = job["steps"]
    if not steps or steps[0].get("uses") != HOIST_CHECKOUT:
        print("run-local: only family jobs (hoisted checkout first) are "
              "modelled", file=sys.stderr)
        return 2
    matrix_shape = len(steps) > 1 and steps[1].get("uses") == HOIST_PYTHON
    first = 2 if matrix_shape else 1
    python = shutil.which(f"python{args.python}" if args.python else "python3")
    if not python:
        print(f"run-local: CANNOT RUN -- no python{args.python} on PATH",
              file=sys.stderr)
        return 2
    work = tempfile.mkdtemp(prefix="ci_fold_run_")
    ws = os.path.join(work, "ws")
    subprocess.run(["git", "-C", REPO, "worktree", "add", "-q", "--detach",
                    ws, args.ref], check=True)
    ctx = {"steps": {}, "failed": False, "python": python,
           "matrix_shape": matrix_shape,
           "python_version": args.python, "runner_temp": os.path.join(work, "t"),
           "workspace": ws}
    os.makedirs(ctx["runner_temp"])
    genv = dict(os.environ)
    genv.update({"GITHUB_WORKSPACE": ws, "RUNNER_TEMP": ctx["runner_temp"],
                 "GITHUB_ACTIONS": "true", "CI": "true",
                 "GITHUB_EVENT_NAME": "pull_request"})
    for k in ("VIRTUAL_ENV", "PYTHONPATH", "PYTHONHOME"):
        genv.pop(k, None)
    genv["PATH"] = os.path.dirname(python) + os.pathsep + genv["PATH"]
    genv["PIP_CACHE_DIR"] = os.path.expanduser("~/.cache/pip")
    extra_path = []
    rows = []
    only = set(args.block or [])
    t_job = time.time()
    try:
        for idx, st in enumerate(steps[first:], first + 1):
            sid = st.get("id", f"_{idx}")
            blk = sid.split("_")[0] if re.match(r"b\d\d_", sid) else ""
            if only and blk and blk not in only:
                continue
            if "run" not in st:
                ctx["steps"][sid] = {"conclusion": "success",
                                     "outcome": "success", "outputs": {}}
                continue
            cond = st.get("if")
            try:
                if cond is None:
                    go = not ctx["failed"]
                else:
                    c = strip_expr(cond)
                    go = bool(eval_expr(c, ctx))
                script = subst(st["run"], ctx)
                senv = {k: subst(v, ctx) for k, v in (st.get("env") or {}).items()}
                # GitHub's default for run: is `bash -e {0}`. Only an explicit
                # `shell: bash` adds --noprofile --norc -o pipefail. Emulating
                # the stricter one would grade a step by rules it never ran
                # under.
                if st.get("shell") == "bash":
                    argv = ["bash", "--noprofile", "--norc", "-eo", "pipefail"]
                elif st.get("shell") in (None, "bash -e {0}"):
                    argv = ["bash", "-e"]
                else:
                    raise CannotEmulate(f"shell: {st.get('shell')}")
            except CannotEmulate as e:
                rows.append((sid, "CANNOT-EMULATE", 0.0, str(e)))
                ctx["failed"] = True
                ctx["steps"][sid] = {"conclusion": "failure",
                                     "outcome": "failure", "outputs": {}}
                continue
            if not go:
                ctx["steps"][sid] = {"conclusion": "skipped",
                                     "outcome": "skipped", "outputs": {}}
                rows.append((sid, "skipped", 0.0, st.get("name", "")))
                continue
            files = {k: os.path.join(work, f"{k}.{idx}") for k in
                     ("GITHUB_ENV", "GITHUB_PATH", "GITHUB_OUTPUT")}
            for f in files.values():
                open(f, "w").close()
            env = dict(genv)
            env["PATH"] = os.pathsep.join(reversed(extra_path)) + \
                (os.pathsep if extra_path else "") + genv["PATH"]
            env.update(files)
            env.update(senv)
            sf = os.path.join(work, f"step{idx}.sh")
            with open(sf, "w") as fh:
                fh.write(script)
            tmo = int(st.get("timeout-minutes") or job.get("timeout-minutes"))
            t0 = time.time()
            try:
                p = subprocess.run(argv + [sf], cwd=os.path.join(
                                        ws, st.get("working-directory", "")),
                                   env=env, timeout=tmo * 60,
                                   stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT)
                rc, out = p.returncode, p.stdout.decode(errors="replace")
            except subprocess.TimeoutExpired:
                rc, out = 124, "TIMEOUT"
            dt = time.time() - t0
            genv.update(read_kv(files["GITHUB_ENV"]))
            extra_path += [l.strip() for l in
                           open(files["GITHUB_PATH"]).read().splitlines()
                           if l.strip()]
            res = "success" if rc == 0 else "failure"
            if rc != 0 and st.get("continue-on-error"):
                ctx["steps"][sid] = {"conclusion": "success",
                                     "outcome": "failure",
                                     "outputs": read_kv(files["GITHUB_OUTPUT"])}
            else:
                ctx["steps"][sid] = {"conclusion": res, "outcome": res,
                                     "outputs": read_kv(files["GITHUB_OUTPUT"])}
                if rc != 0:
                    ctx["failed"] = True
            rows.append((sid, res, dt, st.get("name", "")))
            if rc != 0 or args.verbose:
                print(f"--- {sid} ({res}, rc={rc}) {st.get('name', '')}\n"
                      f"{out[-4000:]}", file=sys.stderr)
    finally:
        subprocess.run(["git", "-C", REPO, "worktree", "remove", "--force", ws],
                       check=False)
        shutil.rmtree(work, ignore_errors=True)
    total = time.time() - t_job
    per_block = {}
    for sid, res, dt, _ in rows:
        b = sid.split("_")[0]
        pb = per_block.setdefault(b, [0.0, "success"])
        pb[0] += dt
        if res in ("failure", "CANNOT-EMULATE"):
            pb[1] = res
    out = sys.stdout if not args.timings else open(args.timings, "a")
    for b, (dt, res) in sorted(per_block.items()):
        out.write(f"{os.path.basename(path)}\t{args.python}\t{b}\t{res}\t"
                  f"{dt:.1f}\n")
    if out is not sys.stdout:
        out.close()
    bad = [r for r in rows if r[1] in ("failure", "CANNOT-EMULATE")]
    ran = sum(1 for r in rows if r[1] in ("success", "failure"))
    print(f"run-local {os.path.basename(path)} python{args.python}: "
          f"{ran} step(s) ran, {len(bad)} failed, "
          f"{sum(1 for r in rows if r[1] == 'skipped')} skipped, "
          f"{total:.0f}s wall", file=sys.stderr)
    if ran == 0:
        print("run-local: CANNOT RUN -- zero steps executed", file=sys.stderr)
        return 2
    return 1 if bad else 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("inventory")
    a.add_argument("--ref")
    a.add_argument("--out", default="-")
    g = sub.add_parser("generate")
    g.add_argument("family")
    g.add_argument("--spec")
    g.add_argument("--dir", help="workflows dir to fold in place (self-test "
                   "seam; default: this checkout's)")
    c = sub.add_parser("check")
    c.add_argument("--base", default="origin/main")
    c.add_argument("--spec")
    c.add_argument("--base-dir", help="a workflows dir instead of --base "
                   "(self-test seam)")
    c.add_argument("--base-spec", help="the spec at the base when using "
                   "--base-dir (self-test seam)")
    c.add_argument("--tree", help="the after workflows dir (default: this "
                   "checkout's)")
    c.add_argument("--mapping")
    c.add_argument("--scripts-diff")
    se = sub.add_parser("select")
    se.add_argument("family")
    se.add_argument("--paths", help="the paths TSV (default: this "
                    "checkout's)")
    r = sub.add_parser("run-local")
    r.add_argument("workflow")
    r.add_argument("--python", help="matrix families: the leg to run "
                   "(python3.N must be on PATH); plain families use python3")
    r.add_argument("--ref", default="HEAD",
                   help="committed tree to run in a disposable worktree")
    r.add_argument("--block", action="append")
    r.add_argument("--timings")
    r.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv[1:])
    if yaml is None and args.cmd != "select":
        print("ci_fold: CANNOT RUN -- PyYAML is not installed. Nothing was "
              "examined; this is not a pass.", file=sys.stderr)
        return 2
    try:
        return {"inventory": cmd_inventory, "generate": cmd_generate,
            "check": cmd_check, "run-local": cmd_run_local,
            "select": cmd_select}[args.cmd](args)
    except CannotRun as e:
        msg = str(e)
        if not msg.startswith("ci_fold"):
            msg = "ci_fold: " + msg
        print(msg, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
