#!/usr/bin/env python3
"""Sweep every vendored tree for person-shaped tokens, and refuse a verdict
unless the sweep can first prove it finds the shapes that have defeated us.

WHY THIS EXISTS
---------------
2026-08-11. Two agents each swept `vendor/cm041` for real people's names, each
using a computed predicate, and each returned a confident number. Five, then
eight. Both were wrong, and each instrument was blind exactly where the other
could see:

  * a bigram regex could not match a name written ``"<emoji>First<emoji>
    Last"`` -- the emoji breaks the word boundary, so the name was invisible;
  * a comments-and-docstrings predicate never opened
    ``contact_syncer/requirements.txt``, so a name in a comment in a
    requirements file was invisible;
  * both were scoped to ONE tree, and there are twenty-five.

Neither could find the other's miss, and neither carried a control proving it
could find anything. The count is still not known. That is the finding this
file encodes: **an instrument that cannot demonstrate its reach has not earned
a verdict.**

TWO RULES THIS FILE OBEYS
-------------------------
1. **The canaries are synthetic.** Proving reach by searching for the real
   names would put those names in a tracked file in the shipping repo -- the
   test becomes the leak. Every canary below is invented, written into a
   scratch tree at run time, and deleted. No real name appears in this file.
   (Credit where due: this is Archie's design. My first version failed this
   rule.)

2. **A missed canary is a refusal, not a warning.** If any shape is not found,
   the vendor result is suppressed entirely and the exit status is 2. A green
   sweep over a surface the sweep cannot read is worse than no sweep, because
   it is reported as a clean bill.

WHAT IT DOES NOT DO
-------------------
It does not decide whether a token is a person. It cannot: a real forename and
surname, and "Application Support", are the same shape. It reports candidates and defers
classification to ``vendor/PERSON_NAMES_REVIEWED.tsv``, the same
declare-it-or-it-is-a-finding pattern ``vendor/VENDOR_ONLY.tsv`` already uses in
this repo. Until that file is seeded the sweep is a MEASUREMENT (``--report``),
not a gate.

THE HEADLINE NUMBER GOES **UP** WHEN YOU FIX THINGS
---------------------------------------------------
Read this before concluding a scrub made things worse. Measured across one
scrub on 2026-08-15: distinct candidates fell 877 -> 875, while the
kinship-shaped set ROSE from 3 names at 9 sites to 4 at 10.

Nothing regressed. Replacing a real-looking name with a synthetic one removes
one token and mints another, and the new one is a candidate too, because this
sweep reports SHAPE and a synthetic name is the same shape as a real one. A
scrub can therefore raise every number here while strictly improving the tree.

So the count is a DENOMINATOR, not a finding count, in both directions: it
cannot go to zero (the trees are full of legitimate two-capitalised-word
tokens), and it does not fall monotonically as you fix things. The number that
means something is the count of UNDECLARED candidates once
``PERSON_NAMES_REVIEWED.tsv`` is seeded. Anyone quoting the raw total as a leak
count will panic at 877, and anyone watching it after a scrub will conclude the
scrub failed.

WHICH SIDE OF A DIVERGENCE PATCH A NAME SITS ON DETERMINES THE FIX ROUTE,
AND THE WRONG ROUTE FAILS SILENTLY IN BOTH DIRECTIONS
-------------------------------------------------------------------------
Both halves of this were hit for real on 2026-08-15, by two people, in the same
file, on opposite sides. Neither half is safe to know alone.

  MINUS line -- the content is SOURCE, and the graft REMOVES it. The commonest
  graft is a scrub, so a name being scrubbed sits here. Scrubbing the VENDORED
  copy pushes the name onto this side, where the diff reads as "fixed", and the
  name is still published from source.

  PLUS line -- the content is VENDORED, added by the graft, and it may not
  exist in source at all. Fixing SOURCE and re-vendoring does not touch it. The
  graft reinstates it on the next vendor, and you are left with a convincing
  "already fixed" commit in the history and the name still shipping.

Measured instance of the plus-side trap: a kinship-shaped example in
``vendor/cm041/identity_resolver/resolver.py`` and its divergence patch, with
the enclosing comment block VERIFIED ABSENT from cm041 source (source 782
lines, vendored 986). A source-side fix would have been a no-op that looked
like a fix.

Neither failure is visible in the diff you would naturally look at. So:
determine the SIDE first, then pick the route, and re-run this sweep AFTER the
re-vendor rather than before -- that ordering is the only thing that catches a
silent reinstatement.

A NOTE ON REPORTING WHAT THIS FINDS
-----------------------------------
Report categories, paths, counts and sides. Never the token. A report about
removing names must not carry the names, for the same reason this file's
canaries are synthetic: a gate must not carry the thing it hunts, and a report
is read, quoted and logged in more places than the gate is.

Corollary, learned the same day: a SHAPE gate can only ever say
"name-shaped". What converts a candidate into an identification is joining two
independently-written files -- e.g. a fixture and a repo instruction file that
names the same person alongside an employer or a venue. That join is a
legitimate and cheap audit technique, and it is also the thing an outsider can
do. When assessing a file's exposure, measure the ADJACENCY (does a
name-shaped token share a line with an employer/venue/role cue?), not just the
name count.
"""
from __future__ import annotations

import argparse
import collections
import pathlib
import re
import sys
import tempfile
import unicodedata

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
VENDOR = REPO_ROOT / "vendor"
REVIEWED = VENDOR / "PERSON_NAMES_REVIEWED.tsv"

SKIP_SUFFIX = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".icns", ".pdf",
    ".zip", ".gz", ".tar", ".whl", ".dylib", ".so", ".o", ".a", ".bin",
    ".woff", ".woff2", ".ttf", ".otf", ".mp3", ".mp4", ".wav",
}
SKIP_PART = {"__pycache__", ".git", "node_modules", ".venv"}

KINSHIP = (
    "Granny|Grandma|Grandmother|Grandad|Grandpa|Grandfather|Nana|Nanny|Nan|"
    "Auntie|Aunty|Aunt|Uncle|Mum|Mummy|Mam|Mom|Mommy|Dad|Daddy|Papa|Nonna|Oma|Opa"
)
KINSHIP_RE = re.compile(rf"\b(?:{KINSHIP})\s+([A-Z][a-z]{{2,}})\b")
BIGRAM_RE = re.compile(r"\b([A-Z][a-z]{2,})\s+([A-Z][a-z]{2,})\b")

# Vocabulary that is demonstrably not a person in this codebase. Kept short and
# auditable on purpose: a long list here is how a real name gets filtered out
# by accident. Anything not covered lands in the report and gets a TSV row.
TECHNICAL = {
    w.strip() for w in """
    Access Address Api Application Args Assistant Attributes Authentication Base Batch Book
    British American English Buffer Build Cache Calendar Career Chrome Class Client Cloud Code
    Company Compute Config Configuration Connections Contact Contacts Content Context Convert
    Creation Custom Data Database Date Default Dependencies Description Development Directory
    Disk Docker Documentation Dry Run Each Endorsement Entry Environment Error Event Example
    Examples Expected Extension False Field File First Firefox Format Front Full Function Given
    Google Graph Home Hub Identity Import Importer Index Info Information Input Install Installer
    Instance Integration Interface Internal Job Json Key Last Level Library License Line Link
    Linkedin List Live Load Local Location Mac Mail Main Manager Matches Maximum Meeting Memory
    Message Messages Method Microsoft Migration Minimum Mini Mode Model Module Name Network New
    Next None Not Note Notes Notion Number Object Obsidian Offset Ollama Only Open Option
    Options Order Output Outlook Package Page Parameter Parse Parser Path Pattern Person Phase
    Ping Pipeline Positions Previous Privacy Private Product Profile Project Property Public
    Python Qdrant Query Queue Quick Raises Range Read Real Recording Reject Request Response
    Result Return Returns Review Rule Rules Running Runtime Safari Sample Schema Script Search
    Section Server Service Session Setting Settings Setup Signal Since Size Skill Slack Snapshot
    Some Source Sources Spotify Stage Start State Status Step Storage String Structure Style
    Subject Support Sync Syncer System Table Tailscale Target Task Team Teams Template Test
    Tests The Then There This Threshold Time Title Token Tool Tools Total Trace True Type Unified
    Unknown Update Updates Usage Use User Utility Valid Value Variables Vector Vendor Verify
    Version View Walk Warning When Where Which While With Without Worker Write Your Zoom
    Ostler Marvin Samantha Evernote Whatsapp Facebook Instagram Twitter Substack Acme Foo Bar Baz
    """.split()
}

# ---------------------------------------------------------------------------
# Canaries. Every string here is invented. If you are tempted to paste a real
# name in to "make the control realistic", that is precisely the mistake this
# comment exists to stop: the file is tracked, and the file ships.
# ---------------------------------------------------------------------------
CANARIES = [
    ("plain bigram in a .py comment", "syn_plain.py",
     '# owner heuristic, e.g. "Quilty Fenwake" from the header\n',
     "Quilty Fenwake"),
    # DISTINCT token on purpose. The first version reused "Quilty Fenwake"
    # here, so this canary passed off the PLAIN file's hit and could never
    # fail on its own -- a control compared against a different control.
    # Caught by sabotaging the normaliser and seeing no refusal.
    ("emoji-decorated bigram", "syn_emoji.py",
     '# strips decoration, e.g. a "\N{HIBISCUS}Marbeck\N{HIBISCUS} Thrale" display name\n',
     "Marbeck Thrale"),
    ("non-.py file", "syn_reqs.txt",
     '# CAVEAT: parses "Zorbin Halewick via LinkedIn" to last="LinkedIn"\nsomepkg>=1.0\n',
     "Zorbin Halewick"),
    ("inside a .patch", "syn.patch",
     '+    # conservative: name VARIANTS ("Auntie Plumbrey" / "Wendolen Plumbrey")\n',
     "Auntie Plumbrey"),
]
# Must NOT fire: a technical bigram, and a lone capitalised word.
NEGATIVE_CANARY = ("syn_negative.py", "# see Application Support and Batch Resolver notes\nX = 1\n")


def normalise(text: str) -> str:
    """Replace symbol/other-category characters with spaces.

    This is the whole reason the emoji canary passes: ``"\N{HIBISCUS}Quilty"``
    has no word boundary before ``Quilty`` until the symbol becomes a space.
    """
    return "".join(
        " " if unicodedata.category(ch) in ("So", "Sk", "Cn", "Co") else ch
        for ch in text
    )


def scan_text(text: str) -> set[str]:
    """Return the person-shaped tokens in one file's text."""
    found: set[str] = set()
    body = normalise(text)
    for m in KINSHIP_RE.finditer(body):
        found.add(m.group(0))
    for a, b in BIGRAM_RE.findall(body):
        if a in TECHNICAL or b in TECHNICAL:
            continue
        found.add(f"{a} {b}")
    return found


def scan_tree(root: pathlib.Path) -> dict[str, list[str]]:
    """Map token -> list of "path:line" sites under root."""
    sites: dict[str, list[str]] = collections.defaultdict(list)
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        if path.suffix.lower() in SKIP_SUFFIX or SKIP_PART & set(path.parts):
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for lineno, line in enumerate(text.splitlines(), 1):
            for token in scan_text(line):
                sites[token].append(f"{path}:{lineno}")
    return sites


def run_controls() -> tuple[bool, list[str]]:
    """Write the synthetic canaries to a scratch tree and require every hit.

    Returns (all_passed, log_lines). A False here must suppress the vendor
    verdict entirely -- see the module docstring.
    """
    log: list[str] = []
    passed = True
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        for _, filename, body, _ in CANARIES:
            (root / filename).write_text(body, encoding="utf-8")
        (root / NEGATIVE_CANARY[0]).write_text(NEGATIVE_CANARY[1], encoding="utf-8")

        # Per FILE, not per tree: a combined scan lets one canary's hit
        # satisfy another canary's expectation. See the note on the emoji
        # canary above.
        found = scan_tree(root)
        for label, filename, _, expect in CANARIES:
            hit = expect in scan_text((root / filename).read_text(encoding="utf-8"))
            passed &= hit
            log.append(f"  {'FOUND ' if hit else 'MISSED'}  canary: {label}")

        # The negative canary must contribute nothing. If it does, the
        # technical filter has stopped working and every count below is noise.
        leaked = sorted(
            t for t, sites in found.items()
            if any(NEGATIVE_CANARY[0] in s for s in sites)
        )
        neg_ok = not leaked
        passed &= neg_ok
        log.append(
            f"  {'CLEAN ' if neg_ok else 'LEAKED'}  negative control: technical bigrams stay out"
            + ("" if neg_ok else f" -- leaked {leaked}")
        )

    # SELF-SCAN. Rule 1 is a promise in a docstring, and prose has no exit
    # status. Both agents wrote "no real name appears in this file" and both
    # were wrong when they wrote it -- mine carried two in the WHY section.
    # So point the sweep at its own source: anything person-shaped in here must
    # be a declared canary. This catches the next paste without needing a list
    # of real names to compare against, which would reintroduce the problem.
    allowed = {expect for _, _, _, expect in CANARIES}
    allowed |= {"Wendolen Plumbrey"}  # the second half of the .patch canary
    self_tokens = scan_text(pathlib.Path(__file__).read_text(encoding="utf-8"))
    stray = sorted(self_tokens - allowed)
    self_ok = not stray
    passed &= self_ok
    log.append(
        f"  {'CLEAN ' if self_ok else 'STRAY '}  self-scan: only declared canaries appear in this file"
        + ("" if self_ok else f" -- undeclared: {stray}")
    )
    return passed, log


def load_reviewed() -> dict[str, str]:
    """token -> classification, from the declaration file (may not exist yet)."""
    out: dict[str, str] = {}
    if not REVIEWED.is_file():
        return out
    for line in REVIEWED.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 2:
            out[parts[0].strip()] = parts[1].strip()
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--report", action="store_true",
                    help="print the candidate surface instead of gating on it")
    ap.add_argument("--top", type=int, default=0,
                    help="with --report, list at most N tokens (0 = all)")
    args = ap.parse_args()

    print("== controls (synthetic; no real name appears in this file) ==")
    ok, log = run_controls()
    for line in log:
        print(line)
    if not ok:
        print("\nREFUSING TO REPORT: the sweep cannot demonstrate it finds the shapes")
        print("it exists to find, so any vendor result would be a clean bill it has")
        print("not earned. Fix the predicate, do not relax the canary.")
        return 2
    print("  -> reach demonstrated on all four shapes plus the negative control\n")

    if not VENDOR.is_dir():
        print(f"CANNOT RUN: {VENDOR} does not exist. This is not a pass.")
        return 2

    sites = scan_tree(VENDOR)
    reviewed = load_reviewed()
    undeclared = {t: s for t, s in sites.items() if t not in reviewed}

    per_tree: collections.Counter[str] = collections.Counter()
    for token, locs in undeclared.items():
        for loc in locs:
            rel = pathlib.Path(loc.split(":")[0]).relative_to(REPO_ROOT)
            per_tree[rel.parts[1] if len(rel.parts) > 1 else rel.name] += 1

    print(f"== surface: {len(sites)} candidate token(s), "
          f"{len(reviewed)} declared, {len(undeclared)} undeclared ==")
    for tree, n in per_tree.most_common():
        print(f"    {tree:<28} {n}")

    kin = sorted(t for t in undeclared if KINSHIP_RE.fullmatch(t))
    if kin:
        # Label the STOCK and the RATE separately. "(3)" beside six printed
        # lines reads as a miscount; it is 3 distinct names at 6 sites.
        n_sites = sum(len(undeclared[t]) for t in kin)
        print(f"\n== kinship-shaped: {len(kin)} distinct name(s) at {n_sites} site(s), review first ==")
        for token in kin:
            for loc in undeclared[token]:
                print(f"    {pathlib.Path(loc).relative_to(REPO_ROOT)}  {token}")

    if args.report:
        print(f"\n== undeclared tokens ==")
        listing = sorted(undeclared.items())
        if args.top:
            listing = listing[: args.top]
        for token, locs in listing:
            print(f"    {token:<28} x{len(locs):<3} "
                  f"{pathlib.Path(locs[0]).relative_to(REPO_ROOT)}")
        return 0

    if undeclared:
        print(f"\nRED: {len(undeclared)} undeclared candidate(s). Each needs a row in")
        print(f"     {REVIEWED.relative_to(REPO_ROOT)} classifying it as")
        print("     technical / synthetic / real-and-scrubbed, with the reason.")
        print("     Run with --report to list them. Do NOT widen TECHNICAL to")
        print("     silence a row -- that is how a real name gets filtered out.")
        return 1

    print("\nGREEN: every candidate on the vendored surface is declared.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
