"""Per-merge backup, journal and undo for the batch resolver (v1.0.107 #30).

Before ANY merge, ``record_merge`` writes a structured snapshot of both nodes
(every triple with the node as subject or object, with literal datatype and
language kept) and appends one journal line. ``undo_merge`` puts both nodes
back to that snapshot and pins the pair as ``distinct`` in duplicates.yaml, so
the next converge pass does not simply merge them again.

UNDO IS COMPLETE ACROSS BOTH STORES. Before the merge, ``record_merge`` also
snapshots the pair's Qdrant ``people`` points (id, vector, payload): the two
uuid5(person_uri) points plus any point whose payload ``person_uri`` is either
node. ``undo_merge`` upserts those points back and deletes any point for the
pair that was not in the snapshot, THEN restores the graph. Qdrant goes first
because upsert is idempotent; if it fails nothing in the graph has changed and
the undo can simply be run again. The one honest limit: if Qdrant was
unreachable, ``record_merge`` raises SnapshotUnavailable and the pair is NOT
merged (journalled as a ``skip`` with reason ``qdrant_unavailable``; the next
converge retries it). So every merge written by this code has a vector
snapshot. ``qdrant_restored: False`` can now only come from a journal written
by older code, and ``undo_merge`` says so rather than claiming otherwise.
Cosine collections re-normalise stored vectors, so a restored vector can differ
from the snapshot in the last float bit; ids and payloads are exact.

Files are written 0600 inside a 0700 directory: a snapshot holds the same
identifiers the graph does.

The journal records identifier KINDS, never identifier values. An exact-
identifier override (exact_identifier.py) additionally records each matched
key as ``{"kind", "hash"}``: a keyed hash, see ``journal_identifier_keys``.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Set, Tuple

import httpx

logger = logging.getLogger(__name__)

PWG = "https://schema.ostler.ai/ontology#"
JOURNAL_NAME = "merge_journal.jsonl"
SNAP_DIR = "merge_snapshots"

#: Predicates the merge copies or rewrites on the survivor (step 5 / 5b / 8).
TOUCHED_PREDICATES = frozenset(
    PWG + p for p in (
        "displayName", "givenName", "familyName", "organization", "jobTitle",
        "relationship", "howWeMet", "notes", "birthday", "contactType",
        "lastContact",
    )
)

Term = Tuple[str, str, str]          # (kind, value, datatype-or-lang)
SubjTriple = Tuple[str, Term]        # (predicate, object)
ObjTriple = Tuple[str, str]          # (subject, predicate)


class UndoError(Exception):
    """The undo was refused; nothing was written."""


class SnapshotUnavailable(Exception):
    """The pre-merge Qdrant snapshot could not be taken. No snapshot, no
    merge: the caller skips the pair (reason ``qdrant_unavailable``) and the
    next converge retries it. Not a refusal, not a pin."""
    reason = "qdrant_unavailable"


# -- SPARQL plumbing ---------------------------------------------------------

def _query(url: str, client: httpx.Client, sparql: str) -> List[Dict[str, Any]]:
    resp = client.post(
        f"{url}/query", content=sparql,
        headers={"Content-Type": "application/sparql-query",
                 "Accept": "application/sparql-results+json"},
    )
    resp.raise_for_status()
    return resp.json().get("results", {}).get("bindings", [])


def _update(url: str, client: httpx.Client, sparql: str) -> None:
    resp = client.post(
        f"{url}/update", content=sparql,
        headers={"Content-Type": "application/sparql-update"},
    )
    resp.raise_for_status()


def _term(b: Dict[str, Any]) -> Term:
    if b["type"] == "uri":
        return ("uri", b["value"], "")
    extra = b.get("datatype") or b.get("xml:lang") or ""
    return ("lit", b["value"], extra)


def _esc(v: str) -> str:
    return (v.replace("\\", "\\\\").replace('"', '\\"')
             .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t"))


def _sparql_term(t: Term) -> str:
    kind, v, extra = t
    if kind == "uri":
        return f"<{v}>"
    if not extra:
        return f'"{_esc(v)}"'
    if extra.startswith("http"):
        return f'"{_esc(v)}"^^<{extra}>'
    return f'"{_esc(v)}"@{extra}'


def snapshot_qdrant(qdrant_url: str, collection: str, uris: List[str]) -> Dict[str, Any]:
    """Every people point belonging to ``uris`` (id, vector, payload).

    Never raises: a store that cannot be read is recorded as ``unavailable``
    with the exception class, so the journal says what it could not capture.
    """
    try:
        from qdrant_client import QdrantClient, models
        client = QdrantClient(url=qdrant_url, timeout=30)
        ids = [str(uuid.uuid5(uuid.NAMESPACE_URL, u)) for u in uris]
        if not client.collection_exists(collection):
            # Reachable, but no people collection yet: there are no vectors
            # to lose, so an empty snapshot is a true one.
            return {"status": "ok", "collection": collection, "pair_ids": ids,
                    "points": []}
        found: Dict[str, Any] = {}
        for r in client.retrieve(collection_name=collection, ids=ids,
                                 with_payload=True, with_vectors=True):
            found[str(r.id)] = r
        pts, _ = client.scroll(
            collection_name=collection,
            scroll_filter=models.Filter(must=[models.FieldCondition(
                key="person_uri", match=models.MatchAny(any=list(uris)))]),
            with_payload=True, with_vectors=True, limit=1000)
        for r in pts:
            found[str(r.id)] = r
        return {"status": "ok", "collection": collection,
                "pair_ids": ids,
                "points": [{"id": i, "vector": r.vector, "payload": r.payload or {}}
                           for i, r in sorted(found.items())]}
    except Exception as exc:  # noqa: BLE001
        return {"status": "unavailable", "collection": collection,
                "reason": type(exc).__name__, "points": []}


def _restore_qdrant(qdrant_url: str, snap: Dict[str, Any]) -> int:
    """Put the pair's points back exactly; returns the number restored. Raises
    on any failure so the caller can stop before touching the graph."""
    from qdrant_client import QdrantClient, models
    client = QdrantClient(url=qdrant_url, timeout=30)
    coll = snap["collection"]
    want = {p["id"] for p in snap["points"]}
    if snap["points"]:
        client.upsert(collection_name=coll, wait=True, points=[
            models.PointStruct(id=p["id"], vector=p["vector"], payload=p["payload"])
            for p in snap["points"]])
    # Anything the merge (or the reconcile sweep) left for this pair that was
    # not there before is removed.
    pair_uris = {p["payload"].get("person_uri") for p in snap["points"]} - {None}
    now, _ = client.scroll(
        collection_name=coll, with_payload=False, with_vectors=False, limit=1000,
        scroll_filter=models.Filter(must=[models.FieldCondition(
            key="person_uri", match=models.MatchAny(any=sorted(pair_uris)))]),
    ) if pair_uris else ([], None)
    extra = [str(r.id) for r in now if str(r.id) not in want]
    if extra:
        client.delete(collection_name=coll, wait=True, points_selector=extra)
    # Prove it: read the snapshot ids back.
    got = {str(r.id) for r in client.retrieve(collection_name=coll, ids=sorted(want))}
    if got != want:
        raise RuntimeError("restored points not all present after upsert")
    return len(want)


def delete_person_points(qdrant_url: str, collection: str, uri: str) -> int:
    """Delete every ``people`` point that belongs to ``uri``: the
    uuid5(person_uri) point and any other point whose payload ``person_uri``
    is ``uri`` (a writer that keyed its point some other way). Returns the
    number of points that existed before the delete. Raises on any failure:
    the caller decides whether a vector-side failure stops it.

    This is the vector half of a merge. Without it a merged-away person keeps
    a searchable point, so a people search for their name returns a URI the
    graph has retired (v1.0.120 box: 86 such points, every one a
    ``mergedInto`` source, every one from the ingest-time merge path).
    ``record_merge`` snapshots these points first, so ``undo_merge`` puts
    them back.
    """
    from qdrant_client import QdrantClient, models
    client = QdrantClient(url=qdrant_url, timeout=30)
    if not client.collection_exists(collection):
        return 0
    ids = {str(uuid.uuid5(uuid.NAMESPACE_URL, uri))}
    ids &= {str(r.id) for r in client.retrieve(collection_name=collection,
                                               ids=sorted(ids))}
    pts, _ = client.scroll(
        collection_name=collection, with_payload=False, with_vectors=False,
        limit=1000,
        scroll_filter=models.Filter(must=[models.FieldCondition(
            key="person_uri", match=models.MatchValue(value=uri))]))
    ids |= {str(r.id) for r in pts}
    if ids:
        client.delete(collection_name=collection, wait=True,
                      points_selector=sorted(ids))
    return len(ids)


def default_journal_dir() -> Optional[str]:
    """Where a merge made outside the batch converge journals itself.

    The SAME directory the converge pass uses (it runs from the pipeline dir
    with ``--backup-dir ./backups``) and that ``--undo-merge`` and the Hub's
    Split read, so every merge, whichever path made it, is listed and undone
    in one place. ``OSTLER_MERGE_JOURNAL_DIR`` overrides it (empty disables
    it). None when there is no pipeline directory, i.e. not an installed Hub.
    """
    env = os.environ.get("OSTLER_MERGE_JOURNAL_DIR")
    if env is not None:
        return env or None
    pipeline = os.environ.get("OSTLER_PIPELINE_DIR") or os.path.join(
        os.path.expanduser("~"), ".ostler", "import-pipeline")
    if not os.path.isdir(pipeline):
        return None
    return os.path.join(pipeline, "backups", "merge_journal")


def read_node(url: str, client: httpx.Client, uri: str
              ) -> Tuple[Set[SubjTriple], Set[ObjTriple]]:
    subj = {(b["p"]["value"], _term(b["o"])) for b in _query(
        url, client, f"SELECT ?p ?o WHERE {{ <{uri}> ?p ?o }}")}
    obj = {(b["s"]["value"], b["p"]["value"]) for b in _query(
        url, client, f"SELECT ?s ?p WHERE {{ ?s ?p <{uri}> }}")}
    return subj, obj


# -- matched identifier keys (NEW-119) ---------------------------------------
#
# WHY. The walk probe no_person_holds_two_contact_cards may accept a Person
# holding 2+ Contacts cards ONLY when this journal proves an exact-identifier
# override. "The override said so" is not proof; the journal has to name what
# matched. It must not name the VALUE, because this file reaches support
# bundles. So each matched key is written as {kind, hash}, where the hash is
# keyed by a per-install secret: the same identifier hashes the same on one box
# (rows can be compared), cannot be recomputed off the box from a guessed
# phone number, and differs between boxes.
#
# THE SECRET. ~/.ostler/secrets/service_token, created once by install.sh
# (openssl rand -hex 32, 0600 in a 0700 dir, reused on every re-install) and
# readable by the user the resolver runs as. It is NEVER used as the hash key
# directly: a subkey is derived as HMAC-SHA256(secret, SUBKEY_LABEL), so a hash
# in the journal can never be used to test a guess against the service token
# itself, and the derivation is versioned by its label.
#
# MISSING SECRET. The merge still happens (dedupe is never blocked by the
# journal's privacy layer); the row keeps the kinds with ``hash: null`` and
# ``matched_keys_reason: "journal_secret_unavailable"``.

#: Domain-separation label for the journal subkey. Changing it changes every
#: hash, so it is versioned rather than edited.
SUBKEY_LABEL = b"ostler.merge-journal.v1"
#: Hex characters kept from the keyed hash (64 bits).
HASH_HEX_LEN = 16
SECRET_UNAVAILABLE = "journal_secret_unavailable"


def install_secret_path() -> str:
    """Where install.sh keeps the per-install secret the subkey is derived from.
    Same root resolution as repair_lid_as_phone: OSTLER_HOME, OSTLER_DIR, else
    ~/.ostler."""
    root = (os.environ.get("OSTLER_HOME") or os.environ.get("OSTLER_DIR")
            or os.path.join(os.path.expanduser("~"), ".ostler"))
    return os.path.join(root, "secrets", "service_token")


def journal_subkey(secret_path: Optional[str] = None) -> Optional[bytes]:
    """HMAC-SHA256(per-install secret, SUBKEY_LABEL), or None when the secret
    cannot be read or is empty. Never raises, never logs the secret."""
    path = secret_path or install_secret_path()
    try:
        with open(path, "rb") as fh:
            secret = fh.read().strip()
    except OSError as exc:
        logger.warning("merge journal: per-install secret unreadable (%s); "
                       "matched keys journalled without hashes",
                       type(exc).__name__)
        return None
    if not secret:
        logger.warning("merge journal: per-install secret is empty; matched "
                       "keys journalled without hashes")
        return None
    return hmac.new(secret, SUBKEY_LABEL, hashlib.sha256).digest()


def normalise_key_value(kind: str, value: str, *, normalise_linkedin,
                        default_country_code: Optional[int] = None) -> str:
    """The resolver's own normalisers, so two spellings of one identifier hash
    the same: phone -> normalise.normalise_phone (E.164), email ->
    normalise.normalise_email (trimmed, lower-cased), linkedin ->
    batch_resolver._normalise_linkedin_url (passed in; importing it here would
    be circular)."""
    from .normalise import normalise_email, normalise_phone
    if kind == "phone":
        return normalise_phone(value, default_country_code)
    if kind == "email":
        return normalise_email(value)
    if kind == "linkedin":
        return normalise_linkedin(value)
    return value.strip()


def key_hash(subkey: bytes, kind: str, normalised: str) -> str:
    """HMAC-SHA256(subkey, "<kind>:<normalised value>"), first 16 hex chars."""
    msg = f"{kind}:{normalised}".encode("utf-8")
    return hmac.new(subkey, msg, hashlib.sha256).hexdigest()[:HASH_HEX_LEN]


def journal_identifier_keys(
    keys, *, normalise_linkedin, default_country_code: Optional[int] = None,
    secret_path: Optional[str] = None,
) -> Tuple[List[Dict[str, Optional[str]]], str]:
    """(rows, reason) for the journal. ``keys`` is the matched (kind, value)
    list from exact_identifier.card_uid_override_keys. Each row is
    ``{"kind": k, "hash": h}``; the raw value never leaves this function.
    reason is "" when every row is hashed, SECRET_UNAVAILABLE when the secret
    could not be read (rows then carry ``hash: None``). No keys -> ([], "")
    and the secret is not read at all."""
    keys = list(keys or [])
    if not keys:
        return [], ""
    subkey = journal_subkey(secret_path)
    rows: List[Dict[str, Optional[str]]] = []
    for kind, value in keys:
        if subkey is None:
            rows.append({"kind": kind, "hash": None})
            continue
        norm = normalise_key_value(kind, value, normalise_linkedin=normalise_linkedin,
                                   default_country_code=default_country_code)
        rows.append({"kind": kind, "hash": key_hash(subkey, kind, norm)})
    rows.sort(key=lambda r: (r["kind"], r["hash"] or ""))
    return rows, ("" if subkey is not None else SECRET_UNAVAILABLE)


# -- snapshot + journal ------------------------------------------------------

def _private_dir(path: str) -> None:
    os.makedirs(path, mode=0o700, exist_ok=True)
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass


def _write_private(path: str, text: str, append: bool = False) -> None:
    flags = os.O_WRONLY | os.O_CREAT | (os.O_APPEND if append else os.O_TRUNC)
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "a" if append else "w", encoding="utf-8") as fh:
        fh.write(text)


def record_merge(
    url: str, client: httpx.Client, journal_dir: str, keep_uri: str,
    discard_uri: str, *, strategy: str, confidence: float, details: str,
    override: str = "",
    matched_keys: Optional[List[Dict[str, Optional[str]]]] = None,
    matched_keys_reason: str = "",
    qdrant_url: str = "", qdrant_collection: str = "people",
) -> str:
    """Snapshot both nodes and journal the merge. MUST be called BEFORE the
    merge writes anything. Raises on failure: a merge with no backup does not
    proceed (the caller treats the exception as a refusal).

    ``matched_keys`` is the output of ``journal_identifier_keys``: already
    hashed, never raw. ``shared_kinds`` is derived from it and from nothing
    else."""
    _private_dir(journal_dir)
    _private_dir(os.path.join(journal_dir, SNAP_DIR))
    qsnap = None
    if qdrant_url:
        # Take the vector snapshot FIRST: if it cannot be taken nothing has
        # been written, not even a snapshot file.
        qsnap = snapshot_qdrant(qdrant_url, qdrant_collection, [keep_uri, discard_uri])
        if qsnap["status"] != "ok":
            raise SnapshotUnavailable(qsnap.get("reason", ""))
    merge_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8]
    snap: Dict[str, Any] = {"keep": keep_uri, "discard": discard_uri, "nodes": {}}
    if qsnap is not None:
        snap["qdrant"] = qsnap
    for uri in (keep_uri, discard_uri):
        subj, obj = read_node(url, client, uri)
        snap["nodes"][uri] = {
            "subj": sorted([p, list(o)] for p, o in subj),
            "obj": sorted([list(x) for x in obj]),
        }
    snap_rel = os.path.join(SNAP_DIR, f"{merge_id}.json")
    _write_private(os.path.join(journal_dir, snap_rel), json.dumps(snap))
    entry = {
        "kind": "merge", "id": merge_id,
        "ts": datetime.now(timezone.utc).isoformat(),
        "keep": keep_uri, "discard": discard_uri, "strategy": strategy,
        "confidence": confidence, "details": details, "override": override,
        "shared_kinds": sorted({k["kind"] for k in (matched_keys or [])}),
        "matched_keys": list(matched_keys or []),
        "matched_keys_reason": matched_keys_reason,
        "snapshot": snap_rel,
        "qdrant_status": snap.get("qdrant", {}).get("status", "not_requested"),
        "qdrant_points": len(snap.get("qdrant", {}).get("points", [])),
    }
    _write_private(os.path.join(journal_dir, JOURNAL_NAME),
                   json.dumps(entry) + "\n", append=True)
    return merge_id


def record_skip(journal_dir: str, keep_uri: str, discard_uri: str, reason: str,
                detail: str = "") -> None:
    """Journal a pair that was NOT merged and why. Carries no identifier values."""
    _private_dir(journal_dir)
    _write_private(os.path.join(journal_dir, JOURNAL_NAME), json.dumps({
        "kind": "skip", "reason": reason, "detail": detail,
        "ts": datetime.now(timezone.utc).isoformat(),
        "keep": keep_uri, "discard": discard_uri}) + "\n", append=True)


def read_journal(journal_dir: str) -> List[Dict[str, Any]]:
    path = os.path.join(journal_dir, JOURNAL_NAME)
    if not os.path.exists(path):
        return []
    out = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


# -- undo --------------------------------------------------------------------

def _pin_distinct(corrections_dir: str, keep: str, discard: str) -> bool:
    """Record keep/discard as DISTINCT so converge never re-merges them."""
    if not corrections_dir:
        return False
    try:
        import yaml
        from .decisions import short_id
        os.makedirs(corrections_dir, exist_ok=True)
        path = os.path.join(corrections_dir, "duplicates.yaml")
        data: Dict[str, Any] = {}
        if os.path.exists(path):
            with open(path, encoding="utf-8") as fh:
                data = yaml.safe_load(fh) or {}
        data.setdefault("decisions", []).append(
            {"distinct": [short_id(keep), short_id(discard)]})
        with open(path, "w", encoding="utf-8") as fh:
            yaml.safe_dump(data, fh, sort_keys=False)
        return True
    except Exception as exc:  # pragma: no cover - defensive
        logger.warning("could not pin pair as distinct: %s", type(exc).__name__)
        return False


def undo_merge(
    url: str, client: httpx.Client, journal_dir: str, merge_id: str,
    *, corrections_dir: str = "", qdrant_url: str = "",
) -> Dict[str, Any]:
    """Restore both nodes to their pre-merge snapshot. Raises UndoError and
    writes nothing when the merge is unknown, already undone, or the discard
    is no longer merged into the keep."""
    entries = read_journal(journal_dir)
    merge = next((e for e in entries
                  if e.get("kind") == "merge" and e.get("id") == merge_id), None)
    if merge is None:
        raise UndoError(f"unknown merge id {merge_id}")
    if any(e.get("kind") == "undo" and e.get("merge_id") == merge_id for e in entries):
        raise UndoError(f"merge {merge_id} was already undone")
    keep, discard = merge["keep"], merge["discard"]
    with open(os.path.join(journal_dir, merge["snapshot"]), encoding="utf-8") as fh:
        snap = json.load(fh)

    def _load(uri):
        n = snap["nodes"][uri]
        return ({(p, tuple(o)) for p, o in n["subj"]},
                {tuple(x) for x in n["obj"]})

    pre_keep_s, pre_keep_o = _load(keep)
    pre_disc_s, pre_disc_o = _load(discard)

    merged_into = _query(
        url, client,
        f"SELECT ?k WHERE {{ <{discard}> <{PWG}mergedInto> ?k }}")
    if not any(b["k"]["value"] == keep for b in merged_into):
        raise UndoError("the discarded node is not currently merged into the survivor")

    cur_keep_s, cur_keep_o = read_node(url, client, keep)
    cur_disc_s, cur_disc_o = read_node(url, client, discard)

    ops: List[str] = []

    def _del(s, p, o):
        ops.append(f"DELETE DATA {{ <{s}> <{p}> {o} }}")

    def _ins(s, p, o):
        ops.append(f"INSERT DATA {{ <{s}> <{p}> {o} }}")

    # Survivor: drop what the merge copied in, restore what it rewrote.
    for p, o in cur_keep_s:
        if (p, o) in pre_keep_s:
            continue
        if (p, o) in pre_disc_s or p in TOUCHED_PREDICATES:
            _del(keep, p, _sparql_term(o))
    for p, o in pre_keep_s - cur_keep_s:
        _ins(keep, p, _sparql_term(o))
    for s, p in cur_keep_o:
        if (s, p) in pre_disc_o and (s, p) not in pre_keep_o:
            _del(s, p, f"<{keep}>")
    for s, p in pre_keep_o - cur_keep_o:
        _ins(s, p, f"<{keep}>")

    # Discarded node: remove the tombstone and retired type, restore all.
    for p, o in cur_disc_s:
        if (p, o) not in pre_disc_s:
            _del(discard, p, _sparql_term(o))
    for p, o in pre_disc_s - cur_disc_s:
        _ins(discard, p, _sparql_term(o))
    for s, p in cur_disc_o:
        if (s, p) not in pre_disc_o:
            _del(s, p, f"<{discard}>")
    for s, p in pre_disc_o - cur_disc_o:
        _ins(s, p, f"<{discard}>")

    # Vectors first (idempotent upsert; a failure leaves the graph untouched).
    qd = snap.get("qdrant") or {}
    qdrant_restored = False
    qdrant_note = qd.get("status", "not_snapshotted")
    if qd.get("status") == "ok":
        if not qdrant_url:
            raise UndoError("this merge has a Qdrant snapshot but no Qdrant URL was given")
        try:
            _restore_qdrant(qdrant_url, qd)
        except Exception as exc:  # noqa: BLE001
            raise UndoError(
                f"Qdrant restore failed ({type(exc).__name__}); nothing was "
                "changed in the graph, run the undo again once Qdrant is up")
        qdrant_restored = True
        qdrant_note = "restored"

    # One request: the store applies it atomically, so a crash cannot leave
    # a half-restored pair.
    _update(url, client, " ; ".join(ops))
    pinned = _pin_distinct(corrections_dir, keep, discard)
    _write_private(
        os.path.join(journal_dir, JOURNAL_NAME),
        json.dumps({"kind": "undo", "merge_id": merge_id,
                    "ts": datetime.now(timezone.utc).isoformat(),
                    "pinned_distinct": pinned}) + "\n",
        append=True)
    return {"merge_id": merge_id, "keep": keep, "discard": discard,
            "operations": len(ops), "pinned_distinct": pinned,
            "qdrant_restored": qdrant_restored, "qdrant": qdrant_note}
