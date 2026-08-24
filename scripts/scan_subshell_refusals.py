#!/usr/bin/env python3
"""
SWEEP: a refusal that happens in a subshell cannot refuse.

THE CLASS, found 2026-08-24 in OS003 gates/capability_matrix.sh:

    die() { echo "..." >&2; exit 2; }
    probe() { ... [ -n "$dir" ] || die "unknown repo '$repo'"; ... }
    res="$(probe "$ref" ... )"        # <-- die exits THIS subshell, not the script

The gate printed its refusal SEVEN TIMES and exited 0. The file already
documented the same trap thirty lines above, for a different check that had
been hoisted into the main shell. The second limb was left behind.

This is the #876 family wearing different clothes: an error is emitted, the
process reports success, and the operator reads green.

PREDICATE
  1. Find every function whose body reaches a fatal primitive
     (die / fail / abort / bail / exit N / cannot_run).
  2. Find every call site of those functions that sits inside a command
     substitution $(...) or `...`, or is the left-hand side of a pipe.
  3. Report the intersection. Those refusals cannot refuse.

WHAT IT DELIBERATELY DOES NOT FLAG
  - a fatal function called as a plain statement (that one works);
  - `$( ... )` where the function is on the RIGHT of a && (still a subshell,
    but flagged, since the exit is still swallowed);
  - `exit 0` (not a refusal).

EXIT
  0 findings printed to stdout, one per line, plus a DENOMINATOR.
  The caller is responsible for the controls -- see --self-check.
"""
import re, sys, os

FATAL = re.compile(r'(^|[;&|(\s])(die|fail|abort|bail|cannot_run|fatal)\b|(^|[;&|(\s])exit\s+[1-9]')
FUNCDEF = re.compile(r'^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{')
SKIP = re.compile(r'^\s*#')


def functions_reaching_fatal(lines):
    """Return {name: (start_line, end_line)} for functions whose body has a fatal."""
    out = {}
    i = 0
    while i < len(lines):
        m = FUNCDEF.match(lines[i])
        if not m:
            i += 1
            continue
        name = m.group(1)
        depth = lines[i].count('{') - lines[i].count('}')
        j = i + 1
        body = []
        while j < len(lines) and depth > 0:
            body.append(lines[j])
            depth += lines[j].count('{') - lines[j].count('}')
            j += 1
        if any(FATAL.search(b) for b in body if not SKIP.match(b)):
            out[name] = (i + 1, j)
        i = j if j > i else i + 1
    return out


def swallowed_call_sites(lines, fatal_funcs, path):
    findings = []
    for n, line in enumerate(lines):
        if SKIP.match(line):
            continue
        for name, (fs, fe) in fatal_funcs.items():
            if fs <= n + 1 <= fe:      # the definition itself, not a call
                continue
            # inside $( ... ) or ` ... `
            for m in re.finditer(r'\$\(([^()]*)\)|`([^`]*)`', line):
                inner = m.group(1) or m.group(2) or ''
                if re.search(r'(^|[\s;&|])' + re.escape(name) + r'(\s|$)', inner):
                    findings.append((path, n + 1, name, line.strip()[:110], 'command-substitution'))
                    break
            else:
                # left-hand side of a pipe
                if '|' in line and not re.search(r'\|\||\bcase\b', line):
                    lhs = line.split('|')[0]
                    if re.search(r'(^|[\s;&(])' + re.escape(name) + r'(\s|$)', lhs):
                        findings.append((path, n + 1, name, line.strip()[:110], 'pipeline-lhs'))
    return findings


def scan(paths):
    findings, scanned, funcs_total = [], 0, 0
    for p in paths:
        try:
            lines = open(p, errors='replace').read().split('\n')
        except (IsADirectoryError, PermissionError):
            continue
        scanned += 1
        ff = functions_reaching_fatal(lines)
        funcs_total += len(ff)
        findings += swallowed_call_sites(lines, ff, p)
    return findings, scanned, funcs_total


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    files = []
    for root in args:
        if os.path.isfile(root):
            files.append(root)
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames
                           if d not in ('.git', 'node_modules', '.venv', 'worktrees', 'vendor')]
            for f in filenames:
                if f.endswith('.sh') or f == 'install.sh':
                    files.append(os.path.join(dirpath, f))
    findings, scanned, funcs_total = scan(files)
    for f in findings:
        print(f"SWALLOWED\t{f[0]}\t{f[1]}\t{f[2]}\t{f[4]}\t{f[3]}")
    print(f"DENOMINATOR\tfiles={scanned}\tfatal_functions={funcs_total}\tfindings={len(findings)}")
