#!/usr/bin/env python3
"""CM051 #1619 behavioural check, driven by
tests/test_only_the_users_own_address_book_is_read.sh.

THE DEFECT, AND IT TOOK FOUR WRONG DIAGNOSES TO FIND. Person pages on the
walk box carried display names derived from kinship terms. They were not
manufactured and they were not orphans: macOS `AddressBookSourceSync` pulls
ANOTHER DEVICE'S local address book up into the owning iCloud account, the
Hub ingested that book too, and a household member's contact naming became
the customer's data. The customer appeared in their own People list under a
relationship word.

THE FIX IS `_source_is_the_users_own` IN THE SHIPPED SYNCER. It classifies
every AddressBook source by its owning bundle in
`~/Library/Accounts/Accounts4.sqlite` and drops the ones that are not the
customer's own contacts.

WHY THIS FILE EXISTS. Measured on CM051 `origin/main` `d0c207fd`:

    test files naming _source_is_the_users_own    1, and it is the DMG
                                                  DELIVERY fixture, which
                                                  asserts the STRING is in
                                                  the artefact
    test files naming _read_abcddb_as_vcards      0
    CONTROL, test files naming contact_syncer    26
    workflows naming either                       0
    CONTROL, workflows naming contact_syncer      6

So the only guard on the fix was that its FUNCTION NAME appears in the DMG. A
refactor that keeps the name and drops the bundle test, or inverts the
fail-open arm, passes every one of those and reproduces #1619 on the next
customer with a family iCloud.

THE FAIL-OPEN ARM IS ASSERTED, NOT JUST TOLERATED. If the oracle cannot be
read the shipped code INCLUDES every source, because excluding on an
unreadable oracle silently empties a customer's contacts, which is a worse
failure than the one being fixed. That is a judgement call somebody made
deliberately and it is the kind that gets "tightened" by a later reader who
does not know why. Arms 4 and 5 pin it.

Rule 0: every identifier below is synthetic. Source uuids are described by
ROLE, never taken from a real machine.

Emits one `PASS: ` / `FAIL: ` line per assertion. Never a raw traceback.
"""

from __future__ import annotations

import logging
import pathlib
import re
import sqlite3
import sys
import tempfile
import textwrap

RESULTS: list[str] = []


def ok(msg: str) -> None:
    RESULTS.append("PASS: " + msg)


def bad(msg: str) -> None:
    RESULTS.append("FAIL: " + msg)


def die(msg: str) -> None:
    print("FAIL: " + msg)
    sys.exit(1)


# Synthetic source identifiers. Real ones are per-machine UUIDs and a person's
# machine is not something to write into a public repo, so these are shaped
# like UUIDs and are not any.
# THE FIRST EIGHT CHARACTERS MUST DIFFER. The shipped allowlist matches by
# PREFIX (`source_uuid.startswith(w)`), and a first draft of this file gave all
# three the same leading block, so arm 7's "unnamed source" matched the named
# one's prefix and the negative half could never fail. A fixture that cannot
# express the distinction it is testing is the fixture encoding the flag rather
# than the property.
SRC_OWN = "0a11d000-0000-4000-8000-00000000aaaa"      # the customer's own iCloud book
SRC_DEVICE = "0b22d000-0000-4000-8000-00000000bbbb"   # another device's local book
SRC_UNKNOWN = "0c33d000-0000-4000-8000-00000000cccc"  # registered nowhere

BUNDLE_OWN = "com.apple.accountsd"
BUNDLE_DEVICE = "com.apple.AddressBookSourceSync"


def lift(module_src: str) -> callable:
    """Exec `_source_is_the_users_own` out of the SHIPPED vendored source.

    Bounded by the function's own end, so a runaway regex cannot swallow the
    rest of the module and quietly change what is under test (the v1018-D032
    lesson). Lifting rather than importing is deliberate: importing
    contact_syncer.syncer drags in httpx, qdrant_client and phonenumbers, and
    a guard that only runs where those are installed is a guard that does not
    run.
    """
    m = re.search(
        r"^    def _source_is_the_users_own\(.*?(?=^    def |\Z)",
        module_src,
        re.S | re.M,
    )
    if not m:
        die(
            "_source_is_the_users_own is GONE from the shipped syncer. That is "
            "either the fix being reverted or the method being renamed; either "
            "way this check is measuring nothing, which is not a pass."
        )
    body = textwrap.dedent(m.group(0))

    # The lifted body must still be the real classifier. A method that no
    # longer mentions the discriminating bundle cannot do the job its name
    # claims, and the DMG delivery row (which greps the NAME) would not notice.
    if BUNDLE_DEVICE not in body:
        die(
            "the lifted _source_is_the_users_own no longer mentions %s, so it "
            "cannot discriminate the source that caused #1619. The function "
            "name survived and the behaviour did not." % BUNDLE_DEVICE
        )

    ns: dict = {"logger": logging.getLogger("lifted"), "List": list, "Dict": dict}
    try:
        exec(compile(body, "<lifted _source_is_the_users_own>", "exec"), ns)
    except Exception as exc:
        die("the lifted method does not compile in isolation: %r" % exc)
    fn = ns.get("_source_is_the_users_own")
    if not callable(fn):
        die("the lift produced no callable")
    return fn


def write_accounts_db(path: pathlib.Path, rows: list[tuple[str, str]]) -> None:
    """A minimal Accounts4.sqlite with only the columns the shipped code reads."""
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path))
    conn.execute("CREATE TABLE ZACCOUNT (ZIDENTIFIER TEXT, ZOWNINGBUNDLEID TEXT)")
    conn.executemany("INSERT INTO ZACCOUNT VALUES (?, ?)", rows)
    conn.commit()
    conn.close()


class _Self:
    """The method uses `self` for nothing; it is effectively static."""


def main(repo: pathlib.Path) -> int:
    src_path = repo / "vendor" / "cm041" / "contact_syncer" / "syncer.py"
    if not src_path.is_file():
        die("the shipped syncer is missing at %s" % src_path)
    fn = lift(src_path.read_text(encoding="utf-8"))
    ok("the classifier was lifted out of the SHIPPED vendored syncer and it "
       "still names the discriminating bundle")

    import os

    tmp = pathlib.Path(tempfile.mkdtemp(prefix="abguard-"))
    home = tmp / "home"
    accounts = home / "Library" / "Accounts" / "Accounts4.sqlite"
    write_accounts_db(
        accounts,
        [(SRC_OWN, BUNDLE_OWN), (SRC_DEVICE, BUNDLE_DEVICE)],
    )

    saved_home = os.environ.get("HOME")
    saved_override = os.environ.get("OSTLER_CONTACT_SOURCES")

    def call(uuid: str) -> bool:
        return bool(fn(_Self(), uuid))

    try:
        os.environ["HOME"] = str(home)
        os.environ.pop("OSTLER_CONTACT_SOURCES", None)

        # -- ANTI-VACUITY. The fixture must be readable, or every verdict below
        # -- is the fail-open arm wearing an answer.
        try:
            conn = sqlite3.connect("file:%s?mode=ro" % accounts, uri=True)
            n = conn.execute("SELECT COUNT(*) FROM ZACCOUNT").fetchone()[0]
            conn.close()
        except Exception as exc:
            die("the synthetic Accounts4.sqlite is unreadable (%r), so arms 1 to "
                "3 would all return True for the WRONG reason" % exc)
        if n != 2:
            die("the synthetic oracle holds %d row(s), expected 2" % n)
        ok("the synthetic oracle is readable and holds both registered sources "
           "(so an INCLUDED below is a decision, not a fail-open)")

        # -- arm 1: the customer's own book is INCLUDED -------------------
        if call(SRC_OWN) is True:
            ok("a source owned by the ordinary contacts bundle is INCLUDED")
        else:
            bad("the customer's OWN address book was SKIPPED -- this empties "
                "their contacts, which is worse than the defect being fixed")

        # -- arm 2: another DEVICE's book is SKIPPED. This is #1619. -------
        if call(SRC_DEVICE) is False:
            ok("a source owned by %s is SKIPPED -- another device's local book "
               "is not the customer's contacts (#1619)" % BUNDLE_DEVICE)
        else:
            bad("a source owned by %s was INCLUDED. This is #1619 exactly: a "
                "household member's contact naming becomes the customer's data, "
                "and the customer appears in their own People list under a "
                "relationship word." % BUNDLE_DEVICE)

        # -- arm 3: a source registered nowhere is SKIPPED -----------------
        if call(SRC_UNKNOWN) is False:
            ok("a source registered as no account at all is SKIPPED (unknown "
               "provenance)")
        else:
            bad("a source with no account registration was INCLUDED")

        # -- arm 4: NO oracle -> fail OPEN ---------------------------------
        # Deliberate, and the reason is written into the shipped comment:
        # dropping a source on an unreadable oracle silently empties contacts.
        os.environ["HOME"] = str(tmp / "no-such-home")
        if call(SRC_DEVICE) is True:
            ok("with NO Accounts4.sqlite every source is INCLUDED -- fails OPEN, "
               "because cannot-read is not cannot-trust")
        else:
            bad("with no Accounts4.sqlite a source was SKIPPED. Excluding on an "
                "unreadable oracle empties a customer's address book.")

        # -- arm 5: a CORRUPT oracle -> fail OPEN --------------------------
        broken_home = tmp / "broken"
        broken = broken_home / "Library" / "Accounts" / "Accounts4.sqlite"
        broken.parent.mkdir(parents=True, exist_ok=True)
        broken.write_bytes(b"this is not a database")
        os.environ["HOME"] = str(broken_home)
        if call(SRC_DEVICE) is True:
            ok("with a CORRUPT Accounts4.sqlite every source is INCLUDED -- the "
               "fail-open arm covers an unreadable file, not just a missing one")
        else:
            bad("a corrupt Accounts4.sqlite caused a source to be SKIPPED")

        # -- arm 6: the documented rollback lever --------------------------
        # OSTLER_CONTACT_SOURCES=all is the no-deploy rollback the shipped
        # comment promises. An untested rollback is not a rollback.
        os.environ["HOME"] = str(home)
        os.environ["OSTLER_CONTACT_SOURCES"] = "all"
        if call(SRC_DEVICE) is True:
            ok("OSTLER_CONTACT_SOURCES=all restores the union-everything "
               "behaviour (the documented no-deploy rollback)")
        else:
            bad("OSTLER_CONTACT_SOURCES=all did NOT re-include a skipped source, "
                "so the documented rollback does not work")

        # -- arm 7: the explicit allowlist, and its NEGATIVE half -----------
        os.environ["OSTLER_CONTACT_SOURCES"] = SRC_DEVICE[:8]
        keeps = call(SRC_DEVICE)
        drops = call(SRC_OWN)
        if keeps is True and drops is False:
            ok("an explicit OSTLER_CONTACT_SOURCES allowlist keeps what it names "
               "by prefix and drops what it does not")
        else:
            bad("the allowlist arm is wrong: named source kept=%r, unnamed "
                "source kept=%r (expected True/False)" % (keeps, drops))

        # -- arm 8: MUTATION CONTROL, in-file ------------------------------
        # Blind the classifier the way a refactor would: hand it a bundle map
        # in which the device book is registered as an ordinary account. If
        # arm 2 cannot flip here, arm 2's green above is vacuous.
        blind_home = tmp / "blind"
        write_accounts_db(
            blind_home / "Library" / "Accounts" / "Accounts4.sqlite",
            [(SRC_OWN, BUNDLE_OWN), (SRC_DEVICE, BUNDLE_OWN)],
        )
        os.environ["HOME"] = str(blind_home)
        os.environ.pop("OSTLER_CONTACT_SOURCES", None)
        if call(SRC_DEVICE) is True:
            ok("MUTATION CONTROL: the same uuid registered under an ORDINARY "
               "bundle is INCLUDED, so arm 2 discriminates on the bundle and "
               "not on the identifier")
        else:
            bad("MUTATION CONTROL DID NOT FIRE: the classifier skipped a source "
                "registered under an ordinary bundle, so arm 2 is deciding on "
                "something other than the owning bundle and its green means "
                "nothing")
    finally:
        if saved_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = saved_home
        if saved_override is None:
            os.environ.pop("OSTLER_CONTACT_SOURCES", None)
        else:
            os.environ["OSTLER_CONTACT_SOURCES"] = saved_override

    for line in RESULTS:
        print(line)
    return 1 if any(r.startswith("FAIL") for r in RESULTS) else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        die("usage: check_address_book_source_guard.py <repo-root>")
    raise SystemExit(main(pathlib.Path(sys.argv[1]).resolve()))
