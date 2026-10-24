"""Shared Qdrant collection bootstrap for the contact-syncer people writers.

On a fresh single-Mac install nothing pre-creates the `people` collection
before these writers run: install.sh brings Qdrant up empty and the contact
import is the first thing to write to it. Qdrant does not auto-create a
collection on `upsert`, so the first writer to reach a missing collection
404s ("Collection 'people' doesn't exist") and loses its whole batch.

`syncer.ContactSyncer._ensure_qdrant_collection` already self-creates for the
main syncer (#638). Its sibling social writers (facebook_friends,
instagram_social, linkedin_connections) write to the SAME collection but did
not, so they fail exactly this way whenever they run before the syncer or on
a store the syncer never reached (#629). This is that self-create, factored
out so all three call ONE helper rather than carrying three copies.

Stateless by design: it probes on every call rather than caching an "already
ensured" flag. The probe short-circuits cheaply once the collection exists,
and statelessness means a collection deleted mid-run is re-created on the
next write rather than skipped by a stale cache.
"""
from __future__ import annotations

from typing import Any, Optional, NamedTuple
import logging

# nomic-embed-text default; matches syncer._ensure_qdrant_collection and the
# install.sh people pre-create (768-dim, Cosine, unnamed vectors).
_DEFAULT_VECTOR_SIZE = 768


def ensure_qdrant_collection(
    client: Any, collection: str, vector_size: int = 0
) -> None:
    """Create `collection` if it does not already exist. Idempotent.

    Mirrors syncer._ensure_qdrant_collection: probe first, create on absence,
    tolerate a lost create race iff the collection is present afterwards, and
    re-raise a genuine Qdrant failure so it still surfaces to the caller.
    """
    try:
        if client.collection_exists(collection):
            return
    except Exception:
        # Probe failed (transient Qdrant hiccup): fall through and try to
        # create. A redundant create on an existing collection is tolerated
        # below, so this cannot make things worse.
        pass

    from qdrant_client.models import Distance, VectorParams

    size = vector_size if vector_size and vector_size > 0 else _DEFAULT_VECTOR_SIZE
    try:
        client.create_collection(
            collection_name=collection,
            vectors_config=VectorParams(size=size, distance=Distance.COSINE),
        )
    except Exception:
        # Lost a create race, or it already existed: tolerate only if the
        # collection is now present; otherwise re-raise so a genuine Qdrant
        # failure still surfaces.
        if client.collection_exists(collection):
            return
        raise


# ---------------------------------------------------------------------------
# Reading the existing point before an upsert overwrites it
# ---------------------------------------------------------------------------

class ExistingPoint(NamedTuple):
    """What we know about the point we are about to overwrite.

    THE THREE STATES ARE NOT TWO. `readable=False` is not the same as
    `payload=None`, and collapsing them is the defect this exists to remove:

        payload=<dict>, readable=True    a richer point exists; preserve from it
        payload=None,   readable=True    genuinely new; write freely
        payload=None,   readable=False   WE DO NOT KNOW. Writing is a gamble.

    The old shape was one `try` wrapping the retrieve AND every preservation,
    with `except Exception: pass`, followed by an UNCONDITIONAL upsert. A
    transient store failure therefore took the same path as "nothing to
    preserve", and the upsert then wrote a poorer payload over a richer one
    with no error anywhere. Measured on CM041 main: three such blocks,
    preserving 3, 3 and 6 payload keys, and ONE exception anywhere in a block
    abandons every preservation in it.

    For the six-key block that means a customer's real name, employer and job
    title are replaced by whatever Instagram knows, silently, on any blip.
    """

    payload: Optional[dict]
    readable: bool
    error: Optional[BaseException] = None


def _is_missing_collection(exc: BaseException) -> bool:
    """Is this exception "there is no such collection" rather than "the store
    is unreachable"?

    TWO SHAPES, DELIBERATELY, AND BOTH ARE CONTROLLED IN THE TESTS.

    The real client raises qdrant_client.http.exceptions.UnexpectedResponse,
    which carries `.status_code`. But this estate runs a client and server
    two minor versions apart (measured on the box: client 1.19.1 against
    server 1.12.1, which the client itself warns about), and the exception
    type has not been stable across that gap. So the status code is checked
    where it exists AND the 404 signature is matched in the message where it
    does not.

    Matching text alone would be fragile; matching the attribute alone missed
    a 404 raised as a plain RuntimeError. Requiring either is the only form
    that is right for both, and a version bump that changes one arm leaves
    the other standing.
    """
    if getattr(exc, "status_code", None) == 404:
        return True
    text = str(exc)
    return "404" in text and (
        "doesn't exist" in text or "does not exist" in text
        or "Not Found" in text
    )


def read_existing_payload(qdrant, collection: str, point_id) -> ExistingPoint:
    """Read the payload of the point we are about to overwrite.

    ONLY THE RETRIEVE IS GUARDED. Preservation logic stays OUTSIDE the
    handler in the caller, because a bug in preservation is a bug and should
    surface, not be absorbed by a handler meant for store failures. Mixing
    the two is what let a KeyError abort five unrelated preservations.

    Never raises. Returns the three-state answer above so the caller can
    decide, which is the decision the old code took implicitly and wrongly.
    """
    try:
        existing = qdrant.retrieve(
            collection_name=collection, ids=[point_id], with_payload=True,
        )
    except Exception as exc:  # noqa: BLE001 -- a store failure, not a bug
        # A MISSING COLLECTION IS NOT AN UNREADABLE STORE. It is a store that
        # DEFINITIVELY has no such point, and on a fresh box it is the normal
        # first-run state: nothing pre-creates the people collection before
        # the social writers run (#629), which is why each of them calls
        # ensure_qdrant_collection immediately after this read.
        #
        # Collapsing the two cost a real regression. Treating the 404 as
        # "cannot read, do not write" meant the FIRST EVER write on a new
        # install was skipped, so no social contact would ever be created --
        # worse than the silent-overwrite bug this function exists to fix.
        # Caught by test_falls_back_to_768_for_empty_vector, which existed
        # already and which I would not have thought to write.
        if _is_missing_collection(exc):
            return ExistingPoint(payload=None, readable=True)
        logging.getLogger(__name__).warning(
            "could not read the existing point %s in %s before upserting "
            "(%s). NOT overwriting it: a write now could replace richer data "
            "with poorer, and this syncer runs again.",
            point_id, collection, exc,
        )
        return ExistingPoint(payload=None, readable=False, error=exc)

    if existing and existing[0].payload:
        return ExistingPoint(payload=existing[0].payload, readable=True)
    return ExistingPoint(payload=None, readable=True)
