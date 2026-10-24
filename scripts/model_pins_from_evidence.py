#!/usr/bin/env python3
"""Check install.sh's model weight pins against the committed clean-pull manifests.

install.sh OSTLER_MODEL_PINS rows are "<tag> <n> sha256:<fingerprint>": n is how
many manifest layers have a mediaType in OSTLER_MODEL_WEIGHT_MEDIATYPES, and the
fingerprint is the sha256 of those layers' digests, SORTED, one per line, each
line ending "\\n". Every row must have clean-pull evidence; there is no
"not pinned" escape.

  --check <evidence_dir> <install.sh>
      evidence_dir holds the on-disk manifests the pinned Ollama wrote and a
      PROVENANCE.tsv (tag, file, sha256 of the file, source). For every row:
      the file must hash to its recorded sha256 (the bytes are the ones that
      were pulled), and the row install.sh carries must be the one computed
      from that manifest with install.sh's OWN weight mediaType list. Every
      pinned row in install.sh must have evidence, and every evidence row must
      be pinned. Exit 0 all match, 1 any mismatch, 2 cannot run.
  --rows <evidence_dir> <install.sh>
      Print the rows computed from the evidence (to paste into install.sh).

British English; no em dashes.
"""
import hashlib
import json
import os
import re
import sys

DIG = re.compile(r"sha256:[0-9a-f]{64}")


def cannot(msg):
    print("CANNOT-RUN: " + msg)
    sys.exit(2)


def install_tables(path):
    try:
        s = open(path, encoding="utf-8").read()
    except OSError as e:
        cannot("cannot read %s: %s" % (path, e))

    def array(name):
        m = re.search(r"^%s=\(\n(.*?)^\)$" % name, s, re.M | re.S)
        if not m:
            cannot("no %s=( ... ) in %s" % (name, path))
        return [re.match(r'\s*"([^"]*)"', l).group(1) for l in m.group(1).split("\n") if re.match(r'\s*"', l)]

    rows = {}
    for r in array("OSTLER_MODEL_PINS"):
        parts = r.split()
        if len(parts) != 3:
            cannot("malformed OSTLER_MODEL_PINS row: %r" % r)
        rows[parts[0]] = (parts[1], parts[2])
    return rows, set(array("OSTLER_MODEL_WEIGHT_MEDIATYPES"))


def evidence(ev_dir, types):
    prov = os.path.join(ev_dir, "PROVENANCE.tsv")
    try:
        lines = [l.rstrip("\n") for l in open(prov, encoding="utf-8")]
    except OSError as e:
        cannot("cannot read %s: %s" % (prov, e))
    out = {}
    for l in lines:
        if not l or l.startswith("#"):
            continue
        tag, fname, want_sha, _source = l.split("\t", 3)
        try:
            data = open(os.path.join(ev_dir, fname), "rb").read()
        except OSError as e:
            cannot("evidence file %s: %s" % (fname, e))
        got_sha = hashlib.sha256(data).hexdigest()
        m = json.loads(data)
        ds = sorted(x["digest"] for x in m["layers"] if x.get("mediaType") in types)
        fp = "sha256:" + hashlib.sha256("".join(d + "\n" for d in ds).encode()).hexdigest()
        out[tag] = {"file_ok": got_sha == want_sha, "got_sha": got_sha, "want_sha": want_sha,
                    "row": (str(len(ds)), fp), "n": len(ds)}
    if not out:
        cannot("%s lists no evidence" % prov)
    return out


def main(argv):
    if len(argv) != 3 or argv[0] not in ("--check", "--rows"):
        sys.exit("usage: model_pins_from_evidence.py --check|--rows <evidence_dir> <install.sh>")
    mode, ev_dir, inst = argv
    rows, types = install_tables(inst)
    ev = evidence(ev_dir, types)
    if mode == "--rows":
        for tag, e in sorted(ev.items()):
            print('    "%-23s %s %s"' % (tag, e["row"][0], e["row"][1]))
        return 0
    bad = 0
    for tag, e in sorted(ev.items()):
        if not e["file_ok"]:
            print("FAIL  %s: evidence file hashes to %s, PROVENANCE says %s" % (tag, e["got_sha"][:12], e["want_sha"][:12])); bad += 1
            continue
        if e["n"] == 0:
            print("FAIL  %s: no layer of the evidence manifest has a weight mediaType" % tag); bad += 1
            continue
        got = rows.get(tag)
        if got is None:
            print("FAIL  %s: has clean-pull evidence but no row in install.sh" % tag); bad += 1
        elif got != e["row"]:
            print("FAIL  %s: install.sh has '%s %s', the evidence gives '%s %s'" % (tag, got[0], got[1], e["row"][0], e["row"][1])); bad += 1
        else:
            print("ok    %s: %s weight layer(s), %s... matches the clean-pull manifest" % (tag, got[0], got[1][:19]))
    for tag in sorted(set(rows) - set(ev)):
        print("FAIL  %s: pinned in install.sh with no clean-pull evidence behind it" % tag); bad += 1
    print("examined %d evidence manifest(s) against %d install.sh row(s): %s"
          % (len(ev), len(rows), "PASS" if not bad else "%d FAIL" % bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
