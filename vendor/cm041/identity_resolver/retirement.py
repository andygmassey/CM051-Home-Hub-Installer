"""How a merged person node is RETIRED, defined once.

Retirement used to be written four different times in this package, as the
same DELETE of the ``a pwg:Person`` triple, and it was wrong in all four
places for one reason:

    A RETIRED NODE MUST STILL ASSERT SOMETHING. ABSENCE IS NOT A SIGNAL
    ANY PRODUCER CAN READ.

THE DEFECT THIS MODULE EXISTS TO CLOSE. Every ingest writer decides whether
to create a person by asking whether the URI it minted already exists. The
question it actually asks (``ostler_fda/pwg_ingest.py::_person_exists``) is::

    SELECT ?t WHERE { <uri> a ?t } LIMIT 1

ANY type, not ``pwg:Person``. Removing a retired node's only type triple
therefore made it indistinguishable from a node that had NEVER BEEN CREATED,
and the writer re-created it: re-asserted ``a pwg:Person``, and appended
another ``createdAt``. Because those writers mint their URI as a
deterministic ``uuid5`` of the identifier, every run re-mints the SAME node,
so the resurrection is not a race -- it is guaranteed on the next ingest.

MEASURED on the live 16GB box. A repair removed the type from 32 merge
subjects at 2026-09-17T18:39Z. THE PRODUCT'S OWN COUNTER RECORDS WHAT
HAPPENED NEXT, in ~/.ostler/logs/fda-rerun.log::

    [ingest] {"imessage": {"status": "ok", "people_created":  0, ...}}
    [ingest] {"imessage": {"status": "ok", "people_created": 32, ...}}
    [ingest] {"imessage": {"status": "ok", "people_created": 32, ...}}
    [ingest] {"imessage": {"status": "ok", "people_created":  0, ...}}

Two consecutive ticks created EXACTLY 32 people; no other tick in that log
creates any. Corroborated in the graph: 32 phantoms carry a ``createdAt``
dated after 18:39Z (control: 32 also carry one from before it -- three each,
being the original creation plus two re-creations, which matches the two
ticks), and all 32 carry ``source imessage_fda``. Later ticks report 0
because by then the nodes exist and are typed.

    STRIPPING THE TYPE IS WHAT ARMED THE RESURRECTION.

RULED OUT, WITH ITS CONTROL, so nobody re-excludes it:
``repair_overmerged_contact_cards.py`` also re-types untyped tombstones and
writes no ``createdAt``, which matches part of the signature. Its population
is Person nodes holding 2+ distinct ``icloud_contact_uid`` values. The number
of these 32 holding ANY such identifier is 0, against a control of 2,221 in
the graph. It was never in a position to touch them.

ALSO MEASURED, and it corrects the record: these merges were not made by this
repository. The graph holds ZERO ``pwg:mergedAt`` values while ``resolver.py``
and ``batch_resolver.py`` both ALWAYS write one; ``ostler_fda/dedupe_merge.py``
writes ``mergedInto`` and never ``mergedAt``.

HOW THIS WAS NEARLY MISDIAGNOSED, recorded because the trap is cheap to fall
into twice. Both this box and the machine reading it run HKT (+0800). The
"18:39Z" above was first written down as its LOCAL time, 02:39, and then
compared against a UTC date: "how many phantoms have a createdAt dated today,
2026-09-18?" answered 0, which was TRUE AND IRRELEVANT, because the event at
2026-09-17T19:04Z is 25 minutes AFTER the repair and not the day before. A
UTC instant was compared against a local date and the arithmetic was allowed
to kill a correct mechanism. Separately, ``people_created: 0`` was read from
the TAIL of that log -- hours later, when there was nothing left to create --
rather than from the window in question. STAMP THE ZONE ON EVERY TIMESTAMP,
AND READ THE TICK THAT COVERS YOUR WINDOW, NOT THE LAST ONE.

WHY REPLACEMENT RATHER THAN TEACHING THE WRITERS. ``pwg_ingest.py`` contains
ZERO occurrences of ``mergedInto`` and asserts ``a pwg:Person`` at five
sites; sixteen files in the running corpus write that type. A list of writers
is an exclusion list, and an exclusion list is only as good as the forms its
author imagined -- its failures are false PASSES.

SUFFICIENT FOR THE PATH THAT WAS MEASURED, AND THE BOUNDARY IS STILL EXACT.
Under ``pwg:RetiredPerson`` the writer's own query returns a row, it takes its
already-exists branch, and ``people_created`` stays 0. That closes EVERY
writer whose existence check asks for ANY type, which is the one the counter
caught.

It does NOT close a writer that asks for ``pwg:Person`` specifically, because
``RetiredPerson`` answers that with 0 as an absent type did.
``repair_overmerged_contact_cards.py:470`` is exactly that shape, and although
it is ruled out for THESE 32 it would revive a node whose identifiers put it
in its population. For writers like that, what this change provides is the
DISCRIMINATOR that did not exist before: a revive path can now ask "is this a
RetiredPerson?" and leave it alone. Using it is a one-line guard in
``ostler_fda``, a different repository and a vendored tree.

The measured resurrection is closed by this change. A second, unmeasured one
is not, and is tracked rather than assumed away.

"""

PWG = "https://schema.ostler.ai/ontology#"

#: The type a live person carries.
PERSON_TYPE = f"{PWG}Person"

#: The type a merged-away person carries INSTEAD. Not a subclass of Person.
RETIRED_TYPE = f"{PWG}RetiredPerson"

#: Some legacy nodes were typed with the FOAF Person class as well. A node
#: that keeps it would still be counted by any reader that unions the two,
#: and would still answer an ``a ?t`` existence check, so it is removed with
#: the pwg type rather than left behind.
FOAF_PERSON_TYPE = "http://xmlns.com/foaf/0.1/Person"


def retire_update(uri: str) -> str:
    """Return ONE SPARQL update that retires ``uri``.

    Single statement, three operations, semicolon-separated so a store that
    applies updates atomically cannot leave the node untyped -- which is the
    exact state that resurrects it. If these were three round trips, a crash
    between them would arm the resurrection this module exists to prevent.

    Idempotent: ``DELETE DATA`` of an absent triple and ``INSERT DATA`` of a
    present one are both no-ops, so re-running is safe and re-running is how
    the existing untyped nodes get upgraded.
    """
    return (
        f"DELETE DATA {{ <{uri}> a <{PERSON_TYPE}> }} ; "
        f"DELETE DATA {{ <{uri}> a <{FOAF_PERSON_TYPE}> }} ; "
        f"INSERT DATA {{ <{uri}> a <{RETIRED_TYPE}> }}"
    )


def untyped_merge_subjects_query() -> str:
    """Subjects that carry ``mergedInto`` but assert NO type at all.

    These are the nodes the old removal-based retirement left behind, and
    they are the ones a producer reads as never-created. The repair step
    upgrades them; this is how they are found.

    ``FILTER NOT EXISTS { ?s a ?any }`` is the whole point: it is the
    producer's own question, negated. A node matching this query WILL be
    re-created by the next ingest.
    """
    return (
        f"SELECT DISTINCT ?s WHERE {{ "
        f"  ?s <{PWG}mergedInto> ?t . "
        f"  FILTER NOT EXISTS {{ ?s a ?any }} "
        f"}}"
    )


def person_exists_query(uri: str) -> str:
    """The producer's existence check, VERBATIM, for use as a test oracle.

    Copied deliberately from ``ostler_fda/pwg_ingest.py::_person_exists``
    rather than paraphrased. A test that asserts our own idea of the
    question proves nothing about the writer that actually asks it; the
    point of this fix is that THIS query must return a row for a retired
    node. If the vendored writer's query ever changes shape, the test that
    drives this string is the thing that should go red.
    """
    return f"SELECT ?t WHERE {{ <{uri}> a ?t }} LIMIT 1"
