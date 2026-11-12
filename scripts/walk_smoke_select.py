#!/usr/bin/env python3
"""Pick the probes a `ttywalk.sh --tier smoke` walk runs.  scripts/box_walk_probes/smoke_scope.tsv is the policy.

  walk_smoke_select.py --repo-root DIR [--walk-store DIR] [--os003-dir DIR] [--list-probes-dir DIR]

stdout: one line  `probe<TAB>class<TAB>why`  per selected probe; stderr: the narration. Exit 0 selected,
78 CANNOT-RUN (policy unreadable or names an unknown probe). It never reads a probe's output and never touches a box.

"Changed since the last FULL walk": the newest record in the walk store whose `tier` row is `full` (a record with
no tier row predates tiers and every such walk was a full one, so it counts as full). Every cut BOM after that
record's version contributes the component of each row's capability (OS003 capability_manifest.tsv `repo`
column). Anything that cannot be mapped widens to every component.
"""
import argparse, os, re, subprocess, sys

def vkey(v):
    return tuple(int(x) for x in re.findall(r"\d+", v))

def read_tsv(text):
    return [l.split("\t") for l in text.splitlines() if l.strip() and not l.startswith("#")]

def git_show(os003, ref_path):
    if not os003 or not os.path.isdir(os003):
        return None
    r = subprocess.run(["git", "-C", os003, "show", "origin/main:" + ref_path], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None

def last_full(store):
    best = None
    if not store or not os.path.isdir(store):
        return None
    for f in os.listdir(store):
        m = re.match(r"^(v[\d.]+)-(\d{8}T\d{6}Z)\.tsv$", f)
        if not m:
            continue
        rows = {}
        with open(os.path.join(store, f), encoding="utf-8") as fh:
            for ln in fh:
                p = ln.rstrip("\n").split("\t")
                if len(p) >= 2 and p[0] in ("tier", "version"):
                    rows.setdefault(p[0], p[1])
        if rows.get("tier", "full") != "full":
            continue
        k = (m.group(2), vkey(m.group(1)))
        if best is None or k > best[0]:
            best = (k, m.group(1))
    return best[1] if best else None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", required=True)
    ap.add_argument("--walk-store", default=os.environ.get("OSTLER_WALK_STORE", os.path.expanduser("~/.ostler/walks")))
    ap.add_argument("--os003-dir", default=os.environ.get("OSTLER_OS003_DIR", ""))
    ap.add_argument("--target-version", default="")
    a = ap.parse_args()
    say = lambda s: print(s, file=sys.stderr)
    root = a.repo_root
    try:
        scope = read_tsv(open(os.path.join(root, "scripts/box_walk_probes/smoke_scope.tsv"), encoding="utf-8").read())
    except OSError as e:
        say(f"CANNOT-RUN: smoke_scope.tsv unreadable: {e}"); return 78
    on_disk = {f[:-3] for f in os.listdir(os.path.join(root, "scripts/box_walk_probes/probes")) if f.endswith(".sh")}
    comps, fixed = {}, []
    for r in scope:
        if len(r) < 3:
            say(f"CANNOT-RUN: malformed smoke_scope row: {r}"); return 78
        names = [n for n in r[2].split(",") if n]
        unknown = [n for n in names if n not in on_disk]
        if unknown:
            say(f"CANNOT-RUN: smoke_scope.tsv names probes that do not exist: {unknown}"); return 78
        if r[0] == "component":
            comps[r[1]] = names
        else:
            fixed += [(n, r[0], r[1]) for n in names]
    chosen = {n: (c, f"always ({k})") for n, c, k in fixed}

    full = last_full(a.walk_store)
    changed, widen_reason = set(), None
    os003 = a.os003_dir
    # Say which OS003 commit was read. A stale clone widens (safe) but must be visible.
    if os003 and os.path.isdir(os003):
        r = subprocess.run(["git", "-C", os003, "log", "-1", "--format=%h %cI", "origin/main"], capture_output=True, text=True)
        say("OS003 origin/main read: " + (r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else f"UNREADABLE ({r.stderr.strip()[:120]})"))
    else:
        say("OS003 origin/main read: NO OS003 clone given (BOMs fall back to the vendored cuts/ copies)")
    if full is None:
        widen_reason = "no FULL walk record in the walk store"
    elif not a.target_version:
        widen_reason = "no target version given, so no delta can be computed"
    else:
        # BOMs are CUMULATIVE (each cut lists everything shipped so far, ~50 capability_id=none rows and all three
        # components), so the question is the DELTA: target-BOM rows that the last-FULL-walk BOM does not have,
        # keyed on (what, repo, ref). Only a NEW row that is none or unmapped widens.
        def bom(v):
            txt = git_show(os003, f"cuts/{v}/MUST_CONTAIN.tsv")
            if txt is None:
                p = os.path.join(root, "cuts", v, "MUST_CONTAIN.tsv")
                txt = open(p, encoding="utf-8").read() if os.path.isfile(p) else None
            if txt is None:
                return None
            rows = read_tsv(txt)
            if not rows or "capability_id" not in rows[0]:
                return None
            h = rows[0]
            return h, rows[1:]
        tb, fb = bom(a.target_version), bom(full)
        cap = git_show(os003, "manifest/capability_manifest.tsv")
        capmap = {}
        if cap:
            for r in read_tsv(cap):
                if len(r) > 2 and r[0] != "id":
                    capmap[r[0]] = r[2]
        if tb is None:
            widen_reason = f"BOM for {a.target_version} unreadable"
        elif fb is None:
            widen_reason = f"BOM for the last FULL walk {full} unreadable, so no delta"
        elif not capmap:
            widen_reason = "OS003 capability_manifest.tsv unreadable"
        else:
            th, trows = tb; fh, frows = fb
            key = lambda h, r: tuple(r[h.index(c)] if len(r) > h.index(c) else "" for c in ("what", "repo", "ref"))
            old = {key(fh, r) for r in frows}
            now = {key(th, r) for r in trows}
            new = [r for r in trows if key(th, r) not in old]
            # A row that is in the last-FULL BOM and gone from the target is a change too (something was removed or
            # replaced), counted against its own capability.
            gone = [("REMOVED", full, fh, r) for r in frows if key(fh, r) not in now]
            ci = th.index("capability_id")
            say(f"smoke delta: {len(trows)} rows in {a.target_version}, {len(frows)} in {full}, {len(new)} new, {len(gone)} removed")
            for tag, ver, h, r in [("NEW", a.target_version, th, x) for x in new] + gone:
                ci = h.index("capability_id")
                c = r[ci] if len(r) > ci else ""
                comp = capmap.get(c)
                if comp not in comps:
                    widen_reason = f"a {tag} {ver} BOM row has capability {c or '(empty)'!r}, which maps to no component"
                    break
                changed.add(comp)
    if widen_reason:
        say(f"smoke scope: ALL components (fail wide): {widen_reason}")
        changed = set(comps)
    else:
        say(f"smoke scope: last FULL record {full}; components changed since: {sorted(changed) or 'none'}")
    for comp in sorted(changed):
        for n in comps[comp]:
            chosen.setdefault(n, ("component", f"component {comp} changed since the last FULL walk"))
    # run_box_walk.sh --only matches by SUBSTRING. The list is exact names, so prove that no OTHER probe on disk
    # is pulled in (or dropped) by that rule; otherwise the printed scope and the executed scope would differ.
    picked = {p for p in on_disk if any(n in p for n in chosen)}
    if picked != set(chosen):
        say(f"CANNOT-RUN: --only substring matching would run {sorted(picked ^ set(chosen))} beyond/short of the scope")
        return 78
    for n in sorted(chosen):
        print(f"{n}\t{chosen[n][0]}\t{chosen[n][1]}")
    say(f"smoke scope: {len(chosen)} of {len(on_disk)} probes")
    return 0

sys.exit(main())
