#!/usr/bin/env python3
"""vendor/VENDOR_MANIFEST.toml SHIPS. Hold it to the cut's own operator-PII rules.

WHY THIS EXISTS, MEASURED RATHER THAN IMAGINED
----------------------------------------------
The v1.0.83 cut run 34396580800 was refused at "Build, sign, notarise, staple",
by make check-manifest, on ONE red row:

    FAIL  no-operator-hostname   shipped DMG must not contain Andy's personal
          box hostname anywhere
          hits=1 in .../Ostler.app/Contents/Resources/ostler-payload/vendor-manifest.toml

That path reads like hub-app content and is not. gui/Makefile:1215 sets
VENDOR_MANIFEST_SRC to $SRC_ROOT/vendor/VENDOR_MANIFEST.toml and :1249 copies it
into the payload as vendor-manifest.toml, so THIS repo's file is shipped
verbatim inside the .app. The hub pin did not move; we moved the file.

The string arrived in CM051 #1881 (merge e54e5a3e), the cm048 re-vendor, inside
a clause describing a brand-neutralisation graft. It was 0 at tag v1.0.82 and 1
at tag v1.0.83.

AND THE PR-TIME SCANNER COULD NOT HAVE CAUGHT IT. .github/scripts/
operator-pii-scan.sh composes its master pattern from phone digits, email
domains, /Users/<u>/ and /home/<u>/ paths, brands, family names, activities and
<username>@. There is NO hostname alternative in it. The estate does hold that
pattern, in cut-manifests/permanent.yaml, and that gate runs at CUT time. So the
only instrument carrying it could not fire until a tag had been spent. This test
closes that window for the one file that is copied into the payload verbatim.

IT DECLARES NO PATTERN OF ITS OWN. It reads the no-operator-* rows out of
cut-manifests/permanent.yaml, which is where the cut gate reads them, so this
check cannot drift from the gate it anticipates and no second copy of an
operator identifier enters the tree to make it work.

Exit 0 pass, 1 fail, 2 could not run. CANNOT-RUN is not a pass.
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PERMANENT = os.path.join(HERE, "cut-manifests", "permanent.yaml")
SHIPPED = os.path.join(HERE, "vendor", "VENDOR_MANIFEST.toml")

# The file is copied into the payload here. If either line moves, the premise of
# this test has moved with it and the test says so rather than passing quietly.
MAKEFILE = os.path.join(HERE, "gui", "Makefile")
COPY_LINE = 'cp "$$VENDOR_MANIFEST_SRC" "$$PAYLOAD/vendor-manifest.toml"'
SRC_LINE = 'VENDOR_MANIFEST_SRC="$$SRC_ROOT/vendor/VENDOR_MANIFEST.toml"'


def cannot(msg):
    print("[CANNOT-RUN] %s" % msg)
    print("A check that could not run has not passed.")
    sys.exit(2)


def load_rules():
    try:
        import yaml
    except ImportError:
        cannot("PyYAML is not importable, so the rules cannot be read")
    try:
        doc = yaml.safe_load(io.open(PERMANENT, encoding="utf-8").read())
    except Exception as exc:
        cannot("cut-manifests/permanent.yaml did not parse: %s" % exc)
    rules = []
    for entry in (doc.get("entries") or []):
        proof = entry.get("proof") or {}
        if not str(entry.get("id", "")).startswith("no-operator-"):
            continue
        if proof.get("kind") != "grep_in_dmg_tree":
            continue
        if proof.get("must_match") is not False:
            continue
        pat = proof.get("pattern")
        if not pat:
            continue
        rules.append((entry["id"], pat))
    return rules


def main():
    for path in (PERMANENT, SHIPPED, MAKEFILE):
        if not os.path.isfile(path):
            cannot("missing input: %s" % path)

    mk = io.open(MAKEFILE, encoding="utf-8").read()
    for needle, what in ((SRC_LINE, "the source assignment"),
                         (COPY_LINE, "the copy into the payload")):
        if needle not in mk:
            cannot("gui/Makefile no longer contains %s. This test asserts a rule "
                   "about a file BECAUSE the cut ships it; if it has stopped "
                   "shipping it, the premise is gone and that is a decision for a "
                   "human, not a silent pass." % what)

    rules = load_rules()
    if not rules:
        cannot("no no-operator-* grep_in_dmg_tree rules with must_match:false were "
               "found in permanent.yaml. An empty rule set makes this a vacuous "
               "pass, which is the shape it exists to refuse.")

    body = io.open(SHIPPED, encoding="utf-8", errors="replace").read()
    if not body.strip():
        cannot("vendor/VENDOR_MANIFEST.toml read as empty")

    failures = []
    for rid, pat in rules:
        try:
            rx = re.compile(pat)
        except re.error as exc:
            cannot("rule %s has an unusable pattern: %s" % (rid, exc))
        hits = [i + 1 for i, line in enumerate(body.splitlines()) if rx.search(line)]
        if hits:
            failures.append((rid, hits))
        # MUTATION ARM, per rule. A predicate that has never said NO has a YES
        # worth nothing. The mutant is built in memory from the rule's own
        # pattern, so no operator identifier is written to disk or into this
        # file. Where a pattern is not a plain literal the constructed sample
        # may not match it; that is reported as CANNOT-RUN for the arm rather
        # than counted as a pass.
        sample = pat if not re.search(r"[\\\[\]().*+?{}|^$]", pat) else None
        if sample is None:
            print("  [arm skipped] %-24s pattern is not a plain literal, so no "
                  "mutant can be built from it here" % rid)
            continue
        if not rx.search("prefix %s suffix" % sample):
            cannot("rule %s did not match a line built from its own pattern, so "
                   "this test cannot demonstrate a NO for it" % rid)
        print("  [arm passed]  %-24s the predicate demonstrably fires on a "
              "planted line" % rid)

    print("")
    print("  rules read from cut-manifests/permanent.yaml: %d" % len(rules))
    print("  lines examined in vendor/VENDOR_MANIFEST.toml: %d"
          % len(body.splitlines()))

    if failures:
        print("")
        print("[FAIL] vendor/VENDOR_MANIFEST.toml is COPIED INTO THE SHIPPED .app "
              "by gui/Makefile:1249 and it violates the cut's own rules:")
        for rid, hits in failures:
            print("       %s at line(s) %s" % (rid, ", ".join(str(h) for h in hits)))
        print("")
        print("       Fix the file. Do not widen the rule: the rule is the one "
              "the cut enforces, and a tag is spent every time this is left to it.")
        return 1

    print("")
    print("[PASS] the shipped vendor manifest satisfies every no-operator-* rule "
          "the cut enforces")
    return 0


sys.exit(main())
