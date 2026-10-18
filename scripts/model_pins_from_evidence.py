#!/usr/bin/env python3
"""Model weight pins <-> clean-pull evidence.

install.sh OSTLER_MODEL_PINS rows are "<tag> <n> sha256:<fingerprint>", where
the fingerprint is the sha256 of the model's weight-layer digests, SORTED, one
per line, each line ending "\\n" (see the comment above the table).

  --extract <pins_0405_*.md>       Read the internal evidence write-up (table +
                                   "## <tag>: sorted weight-layer digests (N)"
                                   blocks) and print the repo extract format.
  --check <extract> <install.sh>   Recompute every row from the extract and
                                   compare with install.sh. Exit 0 all match,
                                   1 any mismatch/missing/extra, 2 cannot run.

Extract format (docs/model-pins/ollama-0.40.5-weight-layers.txt):
    # comment lines
    ## <tag> <weight mediaType> <n>
    sha256:<digest>      (n lines, sorted, unique)

British English; no em dashes.
"""
import hashlib
import re
import sys

DIG = re.compile(r"sha256:[0-9a-f]{64}")


def fingerprint(digests):
    return "sha256:" + hashlib.sha256("".join(d + "\n" for d in digests).encode()).hexdigest()


def extract(md_path):
    s = open(md_path, encoding="utf-8").read()
    table = {}
    for m in re.finditer(r"^\| (\S+) \| `[0-9a-f]{64}` \| `sha256:[0-9a-f]{64}` \| `([^`]+)` \| (\d+) \|", s, re.M):
        table[m.group(1)] = (m.group(2), int(m.group(3)))
    out = ["# Weight-layer digests of each model as the pinned Ollama 0.40.5 wrote it to",
           "# disk on a clean pull into an empty store (2026-10-18). Derived from the",
           "# internal evidence write-up pins_0405_2026-10-18.md, which carries the pull",
           "# logs. Regenerate with: scripts/model_pins_from_evidence.py --extract <md>"]
    blocks = list(re.finditer(r"^## (\S+): sorted weight-layer digests \((\d+)\)\n\n```\n(.*?)```", s, re.M | re.S))
    if not blocks:
        sys.exit("CANNOT-RUN: no '## <tag>: sorted weight-layer digests' blocks in %s" % md_path)
    for m in blocks:
        tag, n = m.group(1), int(m.group(2))
        ds = [l for l in m.group(3).split("\n") if l]
        if tag not in table:
            sys.exit("CANNOT-RUN: %s has digests but no table row" % tag)
        mt, tn = table[tag]
        if not (len(ds) == n == tn and ds == sorted(ds) and len(set(ds)) == n and all(DIG.fullmatch(d) for d in ds)):
            sys.exit("CANNOT-RUN: %s list is not %d sorted unique digests agreeing with the table (%d)" % (tag, n, tn))
        out.append("## %s %s %d" % (tag, mt, n))
        out.extend(ds)
    print("\n".join(out))


def read_extract(path):
    models, cur = {}, None
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line or (line.startswith("#") and not line.startswith("## ")):
            continue
        if line.startswith("## "):
            tag, mt, n = line[3:].split()
            cur = models[tag] = {"mt": set(mt.split(",")), "n": int(n), "d": []}
        elif cur is not None and DIG.fullmatch(line):
            cur["d"].append(line)
        else:
            sys.exit("CANNOT-RUN: unparseable extract line: %r" % line)
    if not models:
        sys.exit("CANNOT-RUN: extract %s holds no models" % path)
    return models


def read_install(path):
    s = open(path, encoding="utf-8").read()
    def array(name):
        m = re.search(r"^%s=\(\n(.*?)^\)$" % name, s, re.M | re.S)
        if not m:
            sys.exit("CANNOT-RUN: no %s=( ... ) in %s" % (name, path))
        return [re.match(r'\s*"([^"]*)"', l).group(1) for l in m.group(1).split("\n") if re.match(r'\s*"', l)]
    rows = {}
    for r in array("OSTLER_MODEL_PINS"):
        tag, n, fp = r.split()
        rows[tag] = (n, fp)
    return rows, set(array("OSTLER_MODEL_WEIGHT_MEDIATYPES"))


def check(extract_path, install_path):
    models = read_extract(extract_path)
    rows, types = read_install(install_path)
    bad = 0
    for tag, m in sorted(models.items()):
        ds = m["d"]
        if len(ds) != m["n"] or ds != sorted(ds) or len(set(ds)) != len(ds):
            print("FAIL  %s: extract lists %d digests, header says %d (or unsorted/duplicate)" % (tag, len(ds), m["n"]))
            bad += 1
            continue
        want = (str(len(ds)), fingerprint(ds))
        got = rows.get(tag)
        if got is None:
            print("FAIL  %s: in the evidence, no row in install.sh OSTLER_MODEL_PINS" % tag); bad += 1
        elif got != want:
            print("FAIL  %s: install.sh has %s %s, evidence gives %s %s" % (tag, got[0], got[1], want[0], want[1])); bad += 1
        else:
            print("ok    %s: %s weight layers, %s matches the evidence" % (tag, want[0], want[1][:19]))
        if not m["mt"] <= types:
            print("FAIL  %s: weight mediaType %s is not in OSTLER_MODEL_WEIGHT_MEDIATYPES" % (tag, ",".join(sorted(m["mt"] - types)))); bad += 1
    for tag in sorted(set(rows) - set(models)):
        print("FAIL  %s: pinned in install.sh but absent from the evidence" % tag); bad += 1
    print("checked %d evidence models against %d install.sh rows: %s" % (len(models), len(rows), "PASS" if not bad else "%d FAIL" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "--extract":
        extract(a[1])
    elif len(a) == 3 and a[0] == "--check":
        sys.exit(check(a[1], a[2]))
    else:
        sys.exit("usage: model_pins_from_evidence.py --extract <md> | --check <extract> <install.sh>")
