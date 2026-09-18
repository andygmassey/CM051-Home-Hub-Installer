#!/usr/bin/env python3
"""scripts/verify_vendor_divergence_described.py

AN UNDESCRIBED VENDOR DIVERGENCE IS RED ON THE PULL REQUEST THAT INTRODUCES IT.
CM051 #1961.

WHAT #1961 ACTUALLY SAYS, AND WHAT IT DOES NOT
----------------------------------------------
It does NOT say verify_vendor_fresh.sh is broken. That gate is fail-closed by
default (VENDOR_FRESH_STRICT defaults to 1 since 2026-08-15) and CI opts out at
exactly one call site with fourteen lines of reasoning above it. Verified here
rather than inherited: one `VENDOR_FRESH_STRICT: "0"` in the whole tree, in
.github/workflows/vendor-integrity.yml, and that step prints GATE: DEGRADED and
never GREEN.

What #1961 says is narrower and worse: BECAUSE of that opt-out, an undescribed
divergence cannot be caught ON CI AT ALL. The runner has no CM041, CM048 or
HR015 checkout, so every cross-repo tree degrades to unverifiable and the
content limb never runs. The issue's proposed fix is to make the source repos
resolvable on the runner. That is a credentials-and-checkout project against
private repositories from a PUBLIC repo's runners, and it does not close the
window on the PR that introduces the divergence.

THE FIX BUILT HERE, AND THE ALTERNATIVE IT WAS CHOSEN OVER
----------------------------------------------------------
This gate asks a question that needs NO source repo, so it runs on any runner,
on the PR itself:

    a vendored tree's CONTENT changed in this diff.
    Was that change DESCRIBED anywhere?

A vendored tree is, by this repo's own definition, `source@pinned_sha` plus a
recorded divergence patch. So there are exactly three ways to describe a change
to one, and every one of them is a diff a reviewer can see:

    (a) the tree's divergence patch changed           -> reconstructible
    (b) the tree's pinned_sha changed                 -> a re-vendor; the new
                                                         content IS the source
    (c) the tree's `unrecorded_divergence` declaration changed, and the file it
        names exists and names this tree
                                                      -> honest and NOT
                                                         reconstructible, which
                                                         is the state #977
                                                         governs
    (d) the changed file carries a row in vendor/VENDOR_ONLY.tsv
                                                      -> declared as having no
                                                         upstream at all

Route (d) is not a loophole, it is a correctness requirement, and leaving it out
was the first version's bug. A vendor-only file CANNOT be captured by a
divergence patch: gen_patch captures only files present in BOTH trees, so
--regen-patch strips vendor-only new-file hunks, which is precisely why
VENDOR_ONLY.tsv exists and why sync_vendor.sh restores every path listed there.
Demanding a patch change for such a file would demand something the tooling
refuses to produce, and a gate that asks for the impossible gets routed around.

Anything else is UNDESCRIBED, and undescribed is RED.

THE ALTERNATIVE, STATED PLAINLY BECAUSE IT WAS A REAL CHOICE: accept any change
to the tree's manifest block as a description. That was rejected. Measured on
the real specimen below, it would have passed the one tree that matters, and it
turns a prose edit anywhere in a 900-line manifest into a wave-through. A
description has to be a DECLARATION, in a named field, or the gate is a spell
check.

THE SPECIMEN, MEASURED ON REAL HISTORY
--------------------------------------
#1961 cites CM051 #1956 and says it hand-edits nine files "with 0 divergence
patches and 0 manifest change". RE-MEASURED at its merge commit f2fe7eea, that
is not what landed, and the correction matters:

    tree                  content files changed   patch changed   pin changed
    ostler_security       7                       yes             yes
    cm041/assistant_api   3                       yes             no
    cm048_pipeline        1                       NO              NO

Two of three were described. The third was not, and the manifest says so in its
own words, in a free-text field added by that very commit: "UNDESCRIBED DELTA
LIVES HERE, AND IT IS THE DB-KEY CONSUMER ... This row is verify = 'skip', so
NOTHING WILL GO RED about it."

This gate is what makes that last sentence false. Run against f2fe7eea it names
cm048_pipeline and exits 1, and it does so on a runner with no CM048 checkout.

WHAT THIS GATE IS NOT
---------------------
It is not a replacement for verify_vendor_fresh.sh. It cannot tell you whether
the vendored bytes match the source, because it never sees the source. It tells
you whether a human wrote down what they did. The two gates fail in different
directions and the estate needs both: the freshness gate catches a tree that
drifted from a source it CAN read, and this one catches a tree that was edited
where no source is readable at all.

THREE STATES
------------
    0  every changed tree's change is described (or no vendored content changed)
    1  at least one tree changed with no description: RED
    2  CANNOT-RUN: no manifest at a ref, unparseable manifest, no merge base,
       a shallow clone, zero declared trees. An unexaminable diff must never be
       reported as a clean one.

British English throughout. No em dashes.
"""

import argparse
import os
import subprocess
import sys
import tomllib

CONTENT_EXCLUDE_PREFIXES = (
    "vendor/divergences/",
)
CONTENT_EXCLUDE_EXACT = (
    "vendor/VENDOR_MANIFEST.toml",
    "vendor/VENDOR_ONLY.tsv",
)


def cannot_run(msg: str) -> "None":
    print("GATE: CANNOT-RUN -- " + msg, file=sys.stderr)
    print(
        "      Nothing was established about this diff. That is NOT a pass:\n"
        "      'no undescribed divergence' and 'I could not look' print\n"
        "      identically otherwise, and only one of them is safe.",
        file=sys.stderr,
    )
    sys.exit(2)


def git(repo, *args, allow_fail=False):
    proc = subprocess.run(
        ["git", "-C", repo, *args],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 and not allow_fail:
        return None
    return proc.stdout


def load_manifest(repo, ref):
    """Read vendor/VENDOR_MANIFEST.toml at a ref. Returns {name: block} or None."""
    blob = git(repo, "show", "%s:vendor/VENDOR_MANIFEST.toml" % ref)
    if blob is None:
        return None
    try:
        parsed = tomllib.loads(blob)
    except Exception as exc:  # noqa: BLE001, the reason is printed rather than swallowed
        cannot_run(
            "vendor/VENDOR_MANIFEST.toml at %s does not parse as TOML: %s" % (ref, exc)
        )
    trees = parsed.get("tree") or []
    out = {}
    for t in trees:
        name = t.get("name")
        if not name:
            continue
        # A DUPLICATE NAME IS NOT A DETAIL. verify_vendor_fresh.sh resolves a
        # name to the FIRST matching block, so a second block of the same name
        # is examined zero times by every reader in this repo, including this
        # one. Refusing is the only sound answer; no count comparison can see it.
        if name in out:
            cannot_run(
                "the manifest at %s declares the tree name %r twice. Every reader "
                "in this repo resolves a name to the first block, so the second "
                "would be adjudicated zero times while still looking examined."
                % (ref, name)
            )
        out[name] = t
    return out


def vendor_only_paths(repo, ref):
    """Rows of vendor/VENDOR_ONLY.tsv at a ref, as 'vendor/<path>' strings.

    Returns None when the register is absent, which the caller treats as an
    empty set AFTER saying so. Silently reading an absent register as "no
    vendor-only files" would make route (d) unreachable and every vendor-only
    edit a false RED.
    """
    blob = git(repo, "show", "%s:vendor/VENDOR_ONLY.tsv" % ref)
    if blob is None:
        return None
    out = set()
    for line in blob.splitlines():
        s = line.strip()
        if not s:
            continue
        if s[0] == "#":
            continue
        first = line.split("\t")[0].strip()
        if first:
            out.add("vendor/" + first.lstrip("/"))
    return out


def tree_of(path, manifest):
    """Which declared tree owns this path? Longest vendor_path wins."""
    best = None
    best_len = -1
    for name, block in manifest.items():
        vp = (block.get("vendor_path") or "").rstrip("/")
        if not vp:
            continue
        if path == vp or path.startswith(vp + "/"):
            if len(vp) > best_len:
                best, best_len = name, len(vp)
    return best


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base", required=True, help="base ref (the branch this PR targets)")
    ap.add_argument("--head", required=True, help="head ref (this PR's tip)")
    ap.add_argument("--repo", default=".", help="repository root")
    args = ap.parse_args()

    repo = os.path.abspath(args.repo)
    if git(repo, "rev-parse", "--git-dir") is None:
        cannot_run("not a git repository: %s" % repo)

    for ref in (args.base, args.head):
        if git(repo, "rev-parse", "--verify", "--quiet", ref + "^{commit}") is None:
            cannot_run(
                "ref not present in this checkout: %s. On a runner that means "
                "fetch-depth must be 0; a shallow clone cannot answer this "
                "question and must not pretend to." % ref
            )

    mb = git(repo, "merge-base", args.base, args.head)
    if not mb or not mb.strip():
        cannot_run(
            "no merge base between %s and %s. Histories are unrelated or the "
            "fetch was shallow." % (args.base, args.head)
        )
    mb = mb.strip()

    # FROM THE MERGE BASE, and two-dot on a resolved sha rather than three-dot
    # notation. "How do these two trees differ" and "what did this branch
    # change" are different questions, and a branch that is merely behind main
    # would otherwise be blamed for every vendored file main touched. This repo
    # has already paid for that once, in scripts/enforce_ledger_write.sh.
    changed_raw = git(repo, "diff", "--name-only", "--diff-filter=ACMRD", mb, args.head)
    if changed_raw is None:
        cannot_run("git diff failed between %s and %s" % (mb, args.head))
    changed = [c for c in changed_raw.splitlines() if c.strip()]

    man_head = load_manifest(repo, args.head)
    if man_head is None:
        cannot_run("no vendor/VENDOR_MANIFEST.toml at %s" % args.head)
    man_base = load_manifest(repo, mb)
    if man_base is None:
        # A base with no manifest at all is a legitimate CANNOT-RUN rather than
        # a licence to treat every tree as new.
        cannot_run("no vendor/VENDOR_MANIFEST.toml at the merge base %s" % mb)

    # ANTI-VACUITY FLOOR. Every verdict below is computed from sets that start
    # empty. A manifest that yields no trees would sail through with a GREEN
    # having examined nothing, on the gate that decides whether unrecorded
    # vendored edits ship.
    if not man_head:
        cannot_run(
            "the manifest at %s declares 0 trees. A gate with an empty "
            "denominator is green in exactly the same way as one that checked "
            "everything." % args.head
        )

    print("vendor-divergence-described: is every vendored edit written down?")
    print("  base ref      : %s" % args.base)
    print("  head ref      : %s" % args.head)
    print("  merge base    : %s" % mb)
    print("  declared trees: %d" % len(man_head))
    print("  files in diff : %d" % len(changed))

    vendor_changed = [c for c in changed if c.startswith("vendor/")]
    content_changed = [
        c
        for c in vendor_changed
        if c not in CONTENT_EXCLUDE_EXACT
        and not any(c.startswith(p) for p in CONTENT_EXCLUDE_PREFIXES)
    ]

    vonly = vendor_only_paths(repo, args.head)
    if vonly is None:
        print(
            "  NOTE: no vendor/VENDOR_ONLY.tsv at head. Route (d) is unreachable "
            "on this tree, so a vendor-only edit would be reported as "
            "undescribed. Said out loud rather than read as an empty register."
        )
        vonly = set()
    print("  vendor-only rows: %d" % len(vonly))

    by_tree = {}
    orphans = []
    vendor_only_hits = []
    for path in content_changed:
        if path in vonly:
            vendor_only_hits.append(path)
            continue
        name = tree_of(path, man_head) or tree_of(path, man_base)
        if name is None:
            orphans.append(path)
        else:
            by_tree.setdefault(name, []).append(path)

    print(
        "EXAMINED: %d vendored file(s) changed, %d of them content (%d in "
        "divergences/ or the registers), %d declared vendor-only, touching %d "
        "declared tree(s)"
        % (len(vendor_changed), len(content_changed),
           len(vendor_changed) - len(content_changed),
           len(vendor_only_hits), len(by_tree))
    )
    for p in vendor_only_hits:
        print("  OK    %s -- declared in VENDOR_ONLY.tsv; a divergence patch "
              "cannot carry a vendor-only file" % p)

    if orphans:
        # NAMED, COUNTED, AND EXPLICITLY NOT CLEARED. These files are invisible
        # to verify_vendor_fresh.sh as well, because it walks declared trees.
        # That is a real gap and a different one from this row, so it is
        # reported in full rather than folded into a verdict it does not belong
        # in. Saying "not adjudicated" out loud is the point: a silent skip here
        # would be the warn bucket this repo keeps removing.
        print(
            "  NOTE: %d changed file(s) under vendor/ belong to NO declared tree, "
            "so THIS gate did not adjudicate them. They are equally invisible to "
            "the freshness gate, which also walks declared trees only:"
            % len(orphans)
        )
        for p in orphans:
            print("        %s" % p)

    if not by_tree:
        print(
            "GATE: GREEN -- no declared vendored tree's content changed in this "
            "diff, so there is nothing to describe."
        )
        return 0

    undescribed = []
    for name in sorted(by_tree):
        head_block = man_head.get(name)
        base_block = man_base.get(name)
        files = by_tree[name]

        if head_block is None:
            # The tree's content changed and its manifest block is GONE at head.
            # That is a removal without a record and the freshness gate will
            # never look at those bytes again.
            undescribed.append(
                (name, files, "the tree's manifest block is absent at head")
            )
            continue

        if base_block is None:
            print(
                "  OK    %s -- newly declared in this diff (%d file(s)); the "
                "manifest gained the block, which is the description"
                % (name, len(files))
            )
            continue

        patch = (head_block.get("divergence_patch") or "").strip()
        patch_changed = bool(patch) and patch in changed
        pin_changed = (head_block.get("pinned_sha") != base_block.get("pinned_sha"))
        decl_head = (head_block.get("unrecorded_divergence") or "").strip()
        decl_base = (base_block.get("unrecorded_divergence") or "").strip()
        # 🔴 A RECORD EXTENDED IN PLACE IS STILL A RECORD WRITTEN IN THIS DIFF.
        # This used to accept only a changed POINTER VALUE. The shared record's
        # own header instructs the opposite -- "extended in place by later PRs
        # that hit the same refusals" -- so anyone following the documented
        # practice left decl_head == decl_base, the gate refused, and the
        # message named none of that. The gate rejected its own instructions.
        #
        # The intent is "prove you wrote something new in THIS diff", not "prove
        # you made a new file", and `changed` already answers the former: it is
        # the same test the divergence-patch limb above uses. The existing
        # checks still apply to whichever file is named, so a pointer at a
        # missing file, or at one that never mentions this tree, still fails.
        decl_changed = bool(decl_head) and (decl_head != decl_base or decl_head in changed)

        decl_ok = False
        decl_problem = ""
        if decl_changed:
            blob = git(repo, "show", "%s:%s" % (args.head, decl_head))
            if blob is None:
                decl_problem = (
                    "unrecorded_divergence names %r, which does not exist at head"
                    % decl_head
                )
            elif name not in blob:
                decl_problem = (
                    "unrecorded_divergence names %r, and that file never mentions "
                    "the tree %r, so it records somebody else's divergence"
                    % (decl_head, name)
                )
            else:
                decl_ok = True

        if patch_changed:
            print("  OK    %s -- %d file(s); divergence patch %s changed in the same diff"
                  % (name, len(files), patch))
        elif pin_changed:
            print("  OK    %s -- %d file(s); pinned_sha moved %s -> %s, so this is a re-vendor"
                  % (name, len(files),
                     str(base_block.get("pinned_sha"))[:8],
                     str(head_block.get("pinned_sha"))[:8]))
        elif decl_ok:
            print("  OK    %s -- %d file(s); an unrecorded_divergence record was written "
                  "in the same diff: %s" % (name, len(files), decl_head))
        else:
            reason = decl_problem or (
                "no divergence patch change, no pin change, and no "
                "unrecorded_divergence record written in this diff"
            )
            undescribed.append((name, files, reason))

    if undescribed:
        print("")
        print("GATE: RED -- %d vendored tree(s) changed with the change described "
              "NOWHERE." % len(undescribed), file=sys.stderr)
        for name, files, reason in undescribed:
            print("  FAIL  %s" % name, file=sys.stderr)
            print("        %s" % reason, file=sys.stderr)
            for p in files:
                print("          %s" % p, file=sys.stderr)
        print(
            "\n        WHY THIS IS NOT A FORMALITY. sync_vendor.sh replaces a\n"
            "        vendored tree wholesale from upstream. A hand edit that\n"
            "        nothing records is deleted by the next sync, silently, and\n"
            "        the person meeting the refusal reaches for\n"
            "        SYNC_ACCEPT_DIVERGENCE_LOSS=1 to make it go away. That is\n"
            "        how a shipped fix is un-shipped by a tidy-up.\n"
            "\n"
            "        Do ONE of these, in this PR:\n"
            "          * regenerate the tree's divergence patch\n"
            "            (scripts/regenerate_divergence_patch.sh <tree> --write)\n"
            "          * move pinned_sha, if the edit belongs upstream and landed\n"
            "          * if regeneration REFUSES, record it: set\n"
            "            unrecorded_divergence on the tree's manifest block to a\n"
            "            file that names the tree, the measured refusal, and the\n"
            "            location and shape of every edit.\n",
            file=sys.stderr,
        )
        return 1

    print("")
    print("GATE: GREEN -- all %d changed tree(s) carry a description written in "
          "this same diff." % len(by_tree))
    return 0


if __name__ == "__main__":
    sys.exit(main())
