#!/usr/bin/env python3
"""A forget that found nobody must not report that it erased them.

PROVED-RED-BY: this file, mutation 1 and mutation 2.

THE DEFECT, MEASURED ON THE WALK BOX 2026-09-18.

A person present in the graph with five triples was asked to be forgotten
through the shipped endpoint. It answered HTTP 200 with

    {"forgotten": false, "already_forgotten": true, "stores_purged": []}

and all five triples were still there afterwards. The customer is told the
erasure happened. It did not.

CM051 #960 was the SPARQL half of this: a bare DELETE WHERE that could not
reach a named graph. That half is fixed and the fix is in the installed
server. This is the REPORTING half, and it survived the fix.

WHY IT WAS WRITTEN THAT WAY, because the reasoning was not careless. The
handler's own docstring states the intent: idempotency, so a second forget
is benign for the iOS client. That is correct. What the implementation
could not do is tell the two cases apart, because both produce the same
observation, "no matching person":

    a SECOND call, after we really did erase them          benign
    a FIRST call whose lookup could not resolve them       NOT benign

The second is a customer exercising a right the product advertises, on a
person whose name the lookup cannot resolve, and being told it is done.

THE DISCRIMINATOR ALREADY EXISTED AND NOTHING READ IT. Every forget appends
one line to forget_audit.log. A slug forgotten before HAS a line; one never
forgotten does not. The branch needed exactly that fact and never asked for
it.

WHAT THIS ASSERTS: _forget_audit_has returns THREE states, and the third is
the one that matters. An unreadable log is None, not False and not True,
because a reader that cannot see the evidence must not rule in the
reassuring direction. Two states would collapse "I cannot tell" into "they
were never forgotten" or into "they were", and both are claims.

British English throughout; " -- " not em-dashes.
"""
import os
import pathlib
import shutil
import stat
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SERVER = ROOT / "vendor" / "cm041" / "assistant_api" / "ical-server.py"

PASS = FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  ok    {msg}")


def bad(msg, detail=""):
    global FAIL
    FAIL += 1
    print(f"  FAIL  {msg}")
    if detail:
        for line in str(detail).splitlines():
            print(f"        | {line}")


def load_audit_reader(source_text, queue_dir):
    """Exec just the reader, against a queue dir of our choosing.

    The whole server imports a live environment; lifting the one function
    keeps this a unit test of the decision rather than a slow integration
    test of everything around it.
    """
    i = source_text.find("def _forget_audit_has(slug):")
    j = source_text.find("def api_people_forget(slug):")
    if i < 0 or j < 0 or j <= i:
        return None
    ns = {"Path": pathlib.Path, "_RECOMPILE_QUEUE_DIR": pathlib.Path(queue_dir)}
    exec(compile(source_text[i:j], "forget_audit", "exec"), ns)
    return ns.get("_forget_audit_has")


def three_states(fn, d):
    """Returns the four readings, or a string naming what went wrong."""
    log = pathlib.Path(d) / "forget_audit.log"
    if log.exists():
        log.unlink()
    absent = fn("someone-never-seen")
    log.write_text("2026-09-18T00:00:00Z forget jane-doe\n", encoding="utf-8")
    other = fn("someone-never-seen")
    hit = fn("jane-doe")
    prefix = fn("jane")
    os.chmod(log, 0)
    try:
        unreadable = fn("jane-doe")
    finally:
        os.chmod(log, stat.S_IRUSR | stat.S_IWUSR)
    return absent, other, hit, prefix, unreadable


def main():
    global FAIL
    print("test_forget_does_not_claim_an_erasure_it_did_not_do")
    if not SERVER.is_file():
        print(f"CANNOT-RUN: no server at {SERVER}", file=sys.stderr)
        return 2
    src = SERVER.read_text(encoding="utf-8")

    # ── 0. CONTROL: the branch this file is about must still exist, and the
    #       control has to be able to FAIL, so a second pattern that is
    #       certainly absent is checked in the same breath.
    if "already_forgotten" in src and "definitely-not-in-this-file-xyzzy" not in src:
        ok("(0) CONTROL: the forget branch is present in the source and a "
           "fabricated pattern is not, so the reads below discriminate")
    else:
        bad("(0) CONTROL FAILED: the source could not be read discriminatingly; "
            "every assertion below would be vacuous")
        return 1

    d = tempfile.mkdtemp(prefix="forgetaudit_")
    try:
        fn = load_audit_reader(src, d)
        if fn is None:
            bad("(1) _forget_audit_has is not defined ahead of api_people_forget; "
                "the handler has no way to tell a second forget from a first miss")
            return 1
        ok("(1) the handler has an audit reader to consult at all")

        absent, other, hit, prefix, unreadable = three_states(fn, d)

        if absent is False:
            ok("(2) an ABSENT log reads False: a Mac that has forgotten nobody is "
               "a readable no, not an error")
        else:
            bad(f"(2) an absent log read {absent!r}, expected False")

        if other is False and hit is True:
            ok("(3) a log that names another slug reads False, and the slug it "
               "does name reads True")
        else:
            bad(f"(3) other={other!r} hit={hit!r}, expected False and True")

        if prefix is False:
            ok("(4) 'jane' does not match the line for 'jane-doe': a prefix is "
               "not a slug, and a loose match would report a stranger's erasure")
        else:
            bad(f"(4) a prefix matched: {prefix!r}. Two customers whose slugs "
                "share a prefix would be told about each other's erasure")

        if unreadable is None:
            ok("(5) THE ONE THAT MATTERS: an UNREADABLE log reads None, not "
               "False and not True, so 'I cannot tell' never becomes a claim")
        else:
            bad(f"(5) an unreadable log read {unreadable!r}, expected None. "
                "A reader that cannot see the evidence has ruled anyway")

        # ── MUTATION. Both collapses of the third state must go RED. ──
        print()
        print("  -- mutation --")

        m1 = src.replace("    except OSError:\n        return None",
                         "    except OSError:\n        return False", 1)
        if m1 == src:
            bad("(M1) the mutant could not be built, so nothing was mutation-tested",
                "re-point this test at the except arm of _forget_audit_has")
        else:
            d1 = tempfile.mkdtemp(prefix="forgetaudit_m1_")
            try:
                f1 = load_audit_reader(m1, d1)
                r1 = three_states(f1, d1)[4] if f1 else "no reader"
                if r1 is False:
                    ok("(M1) RED ON THE COLLAPSE: an unreadable log reporting False "
                       "is caught by assertion (5), so (5) is load-bearing")
                else:
                    bad(f"(M1) MUTANT SURVIVED: collapsing None to False still read "
                        f"{r1!r}, so assertion (5) proves nothing")
            finally:
                shutil.rmtree(d1, ignore_errors=True)

        # A substring test instead of an anchored end-of-line test. This is
        # the realistic loose-match slip, and note that the FIRST mutant
        # written here was not: replacing the needle with a bare slug still
        # fails endswith on "...forget jane-doe", so it changed nothing and
        # would have reported assertion (4) as proving nothing when the
        # mutant was the thing at fault.
        m2 = src.replace('                if line.rstrip("\\n").endswith(needle):',
                         '                if needle in line:', 1)
        if m2 == src:
            bad("(M2) the mutant could not be built, so the loose-match direction "
                "was not tested", "re-point this test at the needle in _forget_audit_has")
        else:
            d2 = tempfile.mkdtemp(prefix="forgetaudit_m2_")
            try:
                f2 = load_audit_reader(m2, d2)
                r2 = three_states(f2, d2)[3] if f2 else "no reader"
                # index 3 is the 'jane' reading against a log naming 'jane-doe' 
                if r2 is True:
                    ok("(M2) RED ON A LOOSE MATCH: a substring test makes 'jane' "
                       "match the line for 'jane-doe', which assertion (4) catches")
                else:
                    bad(f"(M2) MUTANT SURVIVED: a loose needle still read {r2!r} for "
                        "a prefix, so assertion (4) proves nothing")
            finally:
                shutil.rmtree(d2, ignore_errors=True)

        # ── 6. AND THE HANDLER MUST ACTUALLY USE IT. A reader nothing calls
        #       is the failure mode this whole repo keeps paying for.
        handler = src[src.find("def api_people_forget(slug):"):]
        if "_forget_audit_has(slug)" in handler:
            ok("(6) the handler CALLS the reader, so this is wired rather than "
               "merely written")
        else:
            bad("(6) _forget_audit_has is defined and the handler never calls it")

        if '"not_found": True' in handler:
            ok("(7) and the not-found case is reported as not_found rather than "
               "as an erasure that already happened")
        else:
            bad("(7) the handler still has no not_found answer, so a lookup miss "
                "is still reported as a completed erasure")
    finally:
        shutil.rmtree(d, ignore_errors=True)

    print()
    print(f"=== {PASS} passed / {FAIL} failed ===")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
