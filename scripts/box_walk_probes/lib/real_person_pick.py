#!/usr/bin/env python3
"""real_person_pick.py -- choose the REAL person for hub_screens_render_for_a_customer.

Pure picker. Inputs are FILES (never argv, so a name cannot reach `ps`):
  --people F   the Hub people API body (JSON, {"people":[{"name":..}]})
  --pages  F   the compiled wiki People listing, one relative .md path per line
  --owner  F   the owner's first name (may be empty)
  --seed   F   names of the walk's seeded synthetic people, one per line (may be empty)

stdout, three lines, NEVER the name except on line 3:
  STATE  chosen | none
  EXAMINED people=<n> compiled_pages=<n> candidates=<n> rejected_org=<n> rejected_synthetic=<n> rejected_owner=<n> rejected_no_page=<n> rejected_shape=<n>
  NAME   <name>            (only when chosen; the caller must keep it out of every log)

PRIVACY: a real person's name. Nothing here prints it except that last line,
which the shell captures into a variable and never echoes. Logs carry
sha256(name)[:8] and the page path depth only (see `fingerprint`).
"""
import hashlib
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hub_screens import _org_like  # the same organisation predicate the screens judge uses
import scale_fixture  # the walk's synthetic cast (.pii-name-registry.tsv)


def slugify(name):
    # Identical to hub_screens.person_link_selector, so the page this finds is
    # the page the probe will look for.
    return re.sub(r"[^a-z0-9]+", "-", (name or "").casefold()).strip("-")


def compiled_sizes(listing):
    """slug -> bytes, from `wc -c` style lines ("<bytes> ./x.md"); 0 for a bare path."""
    out = {}
    for line in listing.splitlines():
        m = re.match(r"^\s*(\d+)\s+(.*\.md)\s*$", line)
        size, path = (int(m.group(1)), m.group(2)) if m else (0, line.strip())
        if not path.endswith(".md"):
            continue
        parts = path.lstrip("./")[:-3].split("/")
        if parts[-1] == "index":
            parts = parts[:-1]
        if parts:
            out[parts[-1].casefold()] = max(size, out.get(parts[-1].casefold(), 0))
    return out


def compiled_slugs(listing):
    """slug -> path depth, from relative .md paths under People/. `x.md` and
    `x/index.md` are the page for x; the section index itself is not a person."""
    out = {}
    for line in listing.splitlines():
        line = re.sub(r"^\s*\d+\s+(?=\S.*\.md\s*$)", "", line)
        p = line.strip().lstrip("./")
        if not p.endswith(".md"):
            continue
        parts = p[:-3].split("/")
        if parts[-1] == "index":
            parts = parts[:-1]
        if not parts:
            continue
        out[parts[-1].casefold()] = len(parts)
    return out


def is_synthetic(name, seed_names):
    toks = [t.casefold() for t in re.split(r"\s+", name.strip()) if t]
    if name.strip().casefold() in seed_names:
        return True
    if "walkfixture" in name.casefold():
        return True
    # scale_fixture names: approved cast first, optional middle initial, cast last.
    if len(toks) >= 2 and toks[0] in scale_fixture._FIRST and toks[-1] in scale_fixture._LAST:
        return True
    return False


_RICH_KEYS = ("role", "email", "phone", "linkedin")
_RICH_MIN = 2
_TOP_N = 10


def richness(row):
    """How many of role/email/phone/linkedin the people API row carries. The API
    has no numeric count field, so this is what 'the graph knows them' looks like."""
    if not isinstance(row, dict):
        return 0
    return sum(1 for k in _RICH_KEYS if str(row.get(k) or "").strip())


def pick(people_body, pages_listing, owner_first, seed_names):
    c = dict(people=0, compiled_pages=0, candidates=0, rejected_org=0,
             rejected_synthetic=0, rejected_owner=0, rejected_no_page=0, rejected_shape=0)
    try:
        doc = json.loads(people_body)
        rows = doc["people"] if isinstance(doc, dict) and isinstance(doc.get("people"), list) else []
    except Exception:
        rows = []
    pages = compiled_slugs(pages_listing)
    sizes = compiled_sizes(pages_listing)
    c["people"], c["compiled_pages"] = len(rows), len(pages)
    owner = (owner_first or "").strip().casefold()
    seeds = {s.strip().casefold() for s in seed_names if s.strip()}
    chosen = None
    best_size = -1
    cands = []
    for r in rows:
        name = ((r.get("name") if isinstance(r, dict) else "") or "").strip()
        if not name or "@" in name or len(name.split()) < 2 or "\n" in name:
            c["rejected_shape"] += 1; continue
        if _org_like(name):
            c["rejected_org"] += 1; continue
        if is_synthetic(name, seeds):
            c["rejected_synthetic"] += 1; continue
        if owner and name.split()[0].casefold() == owner:
            c["rejected_owner"] += 1; continue
        slug = slugify(name)
        if slug not in pages:
            c["rejected_no_page"] += 1; continue
        c["candidates"] += 1
        cands.append((name, pages[slug], richness(r), sizes.get(slug, 0)))
    # The API is already sorted by recency. Among the top-recency candidates take
    # those carrying >= _RICH_MIN of role/email/phone/linkedin; the largest
    # compiled page wins, ties keep recency. None rich: the first candidate, as before.
    rich = [x for x in cands[:_TOP_N] if x[2] >= _RICH_MIN]
    pool = rich or cands[:1]
    for x in pool:
        if chosen is None or x[3] > best_size:
            chosen, best_size = (x[0], x[1]), x[3]
    return chosen, c


def fingerprint(name, depth):
    return "id={} page_path_depth={}".format(hashlib.sha256(name.encode("utf-8")).hexdigest()[:8], depth)


def _read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return ""


def self_test():
    """Synthetic stand-ins only. Every arm must go the way stated; arm 0 is the
    positive control, so a picker that rejects everything cannot pass."""
    people = json.dumps({"people": [
        {"name": "Acme Corp Billing"},      # organisation
        {"name": "jane.d@example.com"},     # provisional email name
        {"name": "Sam Q Patel"},            # synthetic cast
        {"name": "Tommy Min"},              # owner's first name
        {"name": "Wei Zhang"},        # fine, but no page
        {"name": "Robbie Wang"},         # the one
        {"name": "Lizzie Li"},         # also fine, later
    ]})
    pages = "index.md\ntommy-min.md\nsam-q-patel.md\nacme-corp-billing.md\nrobbie-wang/index.md\nlizzie-li.md\n"
    ch, c = pick(people, pages, "Tommy", [])
    ok = True

    def chk(cond, msg):
        nonlocal ok
        if not cond:
            ok = False
            print("SELF-TEST FAIL: " + msg)

    chk(ch and ch[0] == "Robbie Wang" and ch[1] == 1, "positive control: did not choose the one valid person: {}".format(ch))
    chk(c["rejected_org"] == 1 and c["rejected_synthetic"] == 1 and c["rejected_owner"] == 1
        and c["rejected_no_page"] == 1 and c["rejected_shape"] == 1 and c["candidates"] == 2, "counts: {}".format(c))
    chk(pick(people, "", "Tommy", [])[0] is None, "no compiled pages must choose nobody")
    chk(pick("not json", pages, "", [])[0] is None, "an unreadable people body must choose nobody")
    ch2, _ = pick(people, pages, "Tommy", ["Robbie Wang"])
    chk(ch2 and ch2[0] == "Lizzie Li", "the seeded grounding person must be skipped")
    chk(fingerprint("Robbie Wang", 1).count("Robbie") == 0 and "Wang" not in fingerprint("Robbie Wang", 1),
        "the fingerprint leaks the name")
    return 0 if ok else 1


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    a = dict(zip(argv[::2], argv[1::2]))
    ch, c = pick(_read(a.get("--people", "")), _read(a.get("--pages", "")),
                 _read(a.get("--owner", "")).strip(), _read(a.get("--seed", "")).splitlines())
    print("STATE " + ("chosen" if ch else "none"))
    print("EXAMINED " + " ".join("{}={}".format(k, v) for k, v in c.items()))
    if ch:
        print("NAME " + ch[0])
        print("DEPTH {}".format(ch[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
