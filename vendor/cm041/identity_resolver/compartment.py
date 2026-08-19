"""Per-user compartment model for the PWG graph layer (multiuser groundwork).

Implements the (a)+(b) groundwork of CM061 ``MULTIUSER_B2B_GROUNDWORK_SPEC.md``:
a namespace model where each user of the SAME Hub Mac has an isolated PWG
compartment, defaulting to a single PRIMARY user whose compartment maps to
EXACTLY today's storage layout. Nothing about single-user behaviour changes:

    ============================  =========================  ==========================
    Surface                       PRIMARY (default, today)    Secondary user (e.g. priya)
    ============================  =========================  ==========================
    Oxigraph graph                default graph (no GRAPH)   named graph
                                                             ``https://pwg.dev/graph/user/priya``
    SPARQL read endpoint          ``{base}/query``           ``{base}/query?default-graph-uri=...``
    SPARQL INSERT DATA payload    unchanged                  wrapped in ``GRAPH <iri> { ... }``
    Qdrant collection             base name unchanged        ``user__priya__<base>``
    Visible zone                  ``~/Documents/Ostler``     ``~/Documents/Ostler/Users/priya``
    Engine zone                   ``~/.ostler``              ``~/.ostler/users/priya``
    ============================  =========================  ==========================

Isolation is fail-closed at the query boundary:

* a secondary compartment's reads are pinned to its named graph via the
  SPARQL-protocol ``default-graph-uri`` dataset parameter, so the store's
  default graph (the primary user's data) is never on its read path;
* a secondary compartment's writes are only accepted in the one shape this
  module knows how to scope (``INSERT DATA { ... }`` -> wrapped in the
  compartment's ``GRAPH`` block). Any other update shape raises
  :class:`CompartmentIsolationError` instead of silently writing into the
  default (primary) graph;
* cross-user and cross-tenant reads are rejected by :func:`guard_read`.

Load-bearing store dependency -- ``--union-default-graph`` must be OFF
-----------------------------------------------------------------------
The whole primary-side wall above additionally depends on ONE property of
the store itself (CM061 ``PRO_ENGINES_AUDIT_4_multiuser.md`` HIGH-1): the
Oxigraph server must NOT run with ``--union-default-graph``. With union
mode ON, an unqualified query's default graph becomes the UNION of every
named graph, so the primary user's plain ``/query`` reads -- and every
derived surface behind them -- would silently include every secondary
user's triples. All three launch paths in the estate run plain ``serve``
today (union OFF), but that fact lives in OTHER repos' compose/plist
files, so this module asserts it at runtime: before a SECONDARY
compartment is trusted to read or write, :func:`assert_default_graph_isolated`
proves (once per store per process, cached) that a sentinel written into a
named graph is invisible to an unqualified default-graph query. If the
store turns out to be in union mode, secondary-compartment operation is
REFUSED (fail-closed) rather than quietly creating named-graph data that
the operator's unqualified reads would leak. The primary (single-user)
path never probes and is byte-identical to today.

``tenant_id`` is the spec's no-op outer field: it defaults to
``"personal"`` and does nothing in the personal product; it exists only so
a hypothetical future fork can add an outer federation level without
reshaping schemas. Cross-tenant access is structurally rejected NOW (see
:func:`guard_read`) so the rejection is testable with one tenant.

Naming note -- "compartment" vs the dead Scheme B
-------------------------------------------------
CM019 historically wrote a NUMERIC privacy "compartment" scheme
(``pwg:belongsToCompartment`` / ``pwg:compartmentLevel``), documented as
structurally dead in ``contact_syncer/privacy_model.py``. That scheme was
about per-fact *sensitivity*. This module's :class:`UserCompartment` is
about per-user *ownership isolation* -- a different axis entirely. The two
never interact: sensitivity (``pwg:privacyLevel`` ``"L0".."L3"``) applies
WITHIN a user's compartment; this module walls compartments off from each
other.

Dependency note
---------------
Intentionally self-contained (stdlib only, no imports from the rest of
CM041) so it can be mirrored verbatim into sibling packages/repos as a
documented no-shared-dep twin -- the same pattern as
``contact_syncer/privacy_model.py``. If you change it, mirror the change
in any copies. See ``MULTIUSER_GROUNDWORK.md`` at the repo root for the
rollout pattern and the per-PR discipline checklist.
"""
from __future__ import annotations

import os
import re
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional
from urllib.parse import quote

__all__ = [
    "PERSONAL_TENANT",
    "PRIMARY_USER_FALLBACK",
    "MULTIUSER_ENABLED_ENV",
    "UNION_PROBE_GRAPH_IRI",
    "CompartmentError",
    "CompartmentIsolationError",
    "TenantIsolationError",
    "UserCompartment",
    "resolve_compartment",
    "guard_read",
    "validate_user_id",
    "normalise_user_id",
    "multiuser_enabled",
    "assert_default_graph_isolated",
]

PWG_NS = "https://pwg.dev/ontology#"
USER_GRAPH_BASE = "https://pwg.dev/graph/user/"

#: Env var that gates the DEFERRED multiuser paths. The groundwork ships
#: OFF: unless this is exactly ``"1"``, resolving any SECONDARY (named)
#: compartment fails closed, so no stray ``resolve_compartment("priya")``
#: call anywhere in the estate can silently flip multiuser on before the
#: outstanding AUDIT_4 items are closed. The PRIMARY (single-user) path is
#: never gated -- it is today's product and must always boot.
MULTIUSER_ENABLED_ENV = "OSTLER_MULTIUSER_ENABLED"

#: The no-op outer tenant. The personal product only ever has this value.
PERSONAL_TENANT = "personal"

#: user_id recorded for the primary compartment when no ``USER_ID`` env
#: var is set. The primary compartment's storage derivations NEVER depend
#: on its user_id (they are byte-identical to today's layout by
#: construction), so this fallback is a label, not a namespace input.
PRIMARY_USER_FALLBACK = "primary"

# Secondary user ids feed filesystem paths, IRIs and collection names, so
# they are strictly validated: lowercase alphanumeric plus ``_``/``-``,
# starting alphanumeric, max 64 chars. No dots (path traversal), no
# slashes, no whitespace, no IRI metacharacters. Fail-closed.
_USER_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
_TENANT_ID_RE = _USER_ID_RE

# The one update shape this groundwork knows how to scope into a named
# graph. Everything else is rejected for secondary compartments.
_INSERT_DATA_RE = re.compile(r"^\s*INSERT\s+DATA\s*\{(.*)\}\s*$", re.DOTALL | re.IGNORECASE)


class CompartmentError(ValueError):
    """Invalid compartment construction (bad user_id / tenant_id)."""


class CompartmentIsolationError(PermissionError):
    """A read or write attempted to cross a user-compartment wall."""


class TenantIsolationError(PermissionError):
    """A read attempted to cross the (no-op, but enforced) tenant wall."""


@dataclass(frozen=True)
class UserCompartment:
    """An isolated per-user PWG namespace on the one Hub Mac.

    Do not construct directly -- use :func:`resolve_compartment` (or
    :meth:`UserCompartment.primary`), which owns default-user resolution
    and validation.
    """

    user_id: str
    tenant_id: str = PERSONAL_TENANT
    is_primary: bool = field(default=False)

    # -- Graph (Oxigraph) ---------------------------------------------------

    @property
    def graph_iri(self) -> Optional[str]:
        """Named-graph IRI for this compartment; ``None`` for primary.

        Primary maps to the store's default graph -- exactly where all
        existing single-user data lives today. No migration, no GRAPH
        clause, no behaviour change.
        """
        if self.is_primary:
            return None
        return f"{USER_GRAPH_BASE}{self.user_id}"

    def query_endpoint(self, oxigraph_url: str) -> str:
        """SPARQL read endpoint with the compartment's dataset pinned.

        Primary: the plain ``/query`` endpoint, byte-identical to today.
        Secondary: ``default-graph-uri`` pins the query's default graph to
        the compartment's named graph, so the store default graph (the
        primary user's data) and every other user's graph are simply not
        on the read path. Isolation is enforced at the HTTP boundary, not
        by trusting the query text.
        """
        base = f"{oxigraph_url.rstrip('/')}/query"
        if self.is_primary:
            return base
        return f"{base}?default-graph-uri={quote(self.graph_iri, safe='')}"

    def update_endpoint(self, oxigraph_url: str) -> str:
        """SPARQL update endpoint (same for all compartments; write
        scoping happens in the payload via :meth:`scope_update`)."""
        return f"{oxigraph_url.rstrip('/')}/update"

    def scope_update(self, sparql: str) -> str:
        """Scope a SPARQL update payload to this compartment. Fail-closed.

        Primary: returns ``sparql`` unchanged (the identical object), so
        the single-user wire payload is byte-identical to today.

        Secondary: only ``INSERT DATA { ... }`` is accepted, and is
        rewritten to ``INSERT DATA { GRAPH <iri> { ... } }``. Any other
        shape (DELETE/WHERE forms, multiple operations, an embedded GRAPH
        block) raises :class:`CompartmentIsolationError` -- an unscoped
        write from a secondary compartment must never silently land in the
        default (primary) graph.
        """
        if self.is_primary:
            return sparql
        match = _INSERT_DATA_RE.match(sparql)
        if match is None:
            raise CompartmentIsolationError(
                "compartment %r: update shape is not compartment-scopable; "
                "only plain INSERT DATA { ... } is supported for secondary "
                "compartments in the groundwork (fail-closed)" % self.user_id
            )
        inner = match.group(1)
        # The inner body must be a FLAT triple list (this codebase's
        # writers emit exactly that): any brace inside it could close the
        # GRAPH block early and smuggle a second, unscoped operation
        # (e.g. "INSERT DATA { x } ; DELETE WHERE { ... }"), and any
        # embedded GRAPH keyword could target another compartment. Both
        # fail closed. A quoted literal containing a brace also lands
        # here -- rejected rather than risk-analysed.
        if "{" in inner or "}" in inner or re.search(r"\bGRAPH\b", inner, re.IGNORECASE):
            raise CompartmentIsolationError(
                "compartment %r: INSERT DATA body must be a flat triple "
                "list (no nested braces, no GRAPH block); rejected "
                "fail-closed" % self.user_id
            )
        return f"INSERT DATA {{ GRAPH <{self.graph_iri}> {{{inner}}} }}"

    # -- Vectors (Qdrant) ----------------------------------------------------

    def qdrant_collection(self, base: str) -> str:
        """Collection name for this compartment.

        Primary: ``base`` unchanged (today's collections keep their exact
        names). Secondary: ``user__<user_id>__<base>``.
        """
        if not base:
            raise CompartmentError("qdrant collection base name must be non-empty")
        if self.is_primary:
            return base
        return f"user__{self.user_id}__{base}"

    # -- Filesystem zones ------------------------------------------------------

    def visible_zone(self, home: Optional[Path] = None) -> Path:
        """User-facing zone. Primary: ``~/Documents/Ostler`` (unchanged).

        Secondary derivation is a provisional seam: if single-Mac
        multi-user ships for real, compartments are expected to bind to
        macOS accounts / per-user encrypted volumes (the T16 lane), and
        this function is the one place that policy lands.
        """
        home = home or Path.home()
        base = home / "Documents" / "Ostler"
        if self.is_primary:
            return base
        return base / "Users" / self.user_id

    def engine_zone(self, home: Optional[Path] = None) -> Path:
        """Engine zone. Primary: ``~/.ostler`` (unchanged)."""
        home = home or Path.home()
        base = home / ".ostler"
        if self.is_primary:
            return base
        return base / "users" / self.user_id

    # -- Identity / audit -------------------------------------------------------

    @property
    def owner_node_iri(self) -> Optional[str]:
        """IRI of this user's owner/me-card node (``pwg:user_<id>``).

        Same derivation as ``contact_syncer.owner_node.owner_uri`` and the
        ``USER_URI`` in ``assistant_api``. For a primary compartment where
        no ``USER_ID`` env var was set, returns ``None`` (mirrors the
        existing read-side gate that refuses to answer without a
        configured owner) rather than minting an IRI from the fallback
        label.
        """
        if self.is_primary and self.user_id == PRIMARY_USER_FALLBACK:
            return None
        return f"{PWG_NS}user_{self.user_id}"

    def log_context(self) -> dict:
        """Structured-logging fields (groundwork discipline 5)."""
        return {"user_id": self.user_id, "tenant_id": self.tenant_id}

    # -- Construction -----------------------------------------------------------

    @classmethod
    def primary(cls, tenant_id: str = PERSONAL_TENANT) -> "UserCompartment":
        """The default compartment: today's single-user layout, exactly.

        ``user_id`` is taken from the existing ``USER_ID`` env var (the
        install's one operator identity) or the ``PRIMARY_USER_FALLBACK``
        label when unset. Neither value affects any storage derivation:
        primary is special-cased by flag, never by string comparison of
        ids, so single-user behaviour cannot drift with configuration.

        A configured ``USER_ID`` is **normalised, NOT strictly validated**.
        CM051 ``install.sh`` writes into the launchd env whatever the
        operator answered to "What should your assistant call you?" -- real
        values are ``Jane`` (uppercase), ``jane.doe``, ``jane@home``,
        ``Mrs Smith``. NONE of those match the strict secondary-compartment
        grammar, yet the single-user Hub MUST boot on every one of them.
        The operator/PRIMARY compartment is therefore never subject to the
        strict grammar -- only genuinely secondary/named compartments are.
        :func:`normalise_user_id` folds any real value into a slug that
        satisfies :data:`_USER_ID_RE` by construction, so the value that
        feeds :attr:`owner_node_iri` (interpolated into SPARQL by sibling
        modules) is still injection-proof -- it just can never crash the
        boot.
        """
        raw = os.environ.get("USER_ID", "").strip()
        if raw:
            user_id = normalise_user_id(raw)
        else:
            user_id = PRIMARY_USER_FALLBACK
        return cls(user_id=user_id, tenant_id=_check_tenant(tenant_id), is_primary=True)


def _check_tenant(tenant_id: str) -> str:
    if not tenant_id or not _TENANT_ID_RE.match(tenant_id):
        raise CompartmentError(f"invalid tenant_id: {tenant_id!r}")
    return tenant_id


def validate_user_id(user_id: str) -> str:
    """Validate an explicit user id against the strict id grammar.

    The one validator for every id that feeds an IRI, a Qdrant collection
    name or a filesystem path: secondary compartment ids, a configured
    primary ``USER_ID``, and ownership stamps (``pwg:belongsToUser``) in
    writer modules. Fail-closed: raises :class:`CompartmentError`.
    """
    user_id = str(user_id or "").strip()
    if not _USER_ID_RE.match(user_id):
        raise CompartmentError(
            f"invalid user_id: {user_id!r} (must match {_USER_ID_RE.pattern})"
        )
    return user_id


def normalise_user_id(raw: object) -> str:
    """Fold an arbitrary operator-supplied identity into a safe id slug.

    The one place we accept an id that did NOT come from our own
    provisioning: the PRIMARY operator's ``USER_ID``. CM051 ``install.sh``
    captures it from the free-text "What should your assistant call you?"
    prompt, so real values are ``Jane`` (uppercase), ``jane.doe``,
    ``jane@home``, ``Mrs Smith`` -- none of which match the strict
    secondary grammar, yet all of which must boot the single-user Hub.

    Rather than reject (which crashes the Hub) this maps ANY string to a
    value that satisfies :data:`_USER_ID_RE` by construction:

    * lower-cased (APFS is case-preserving; ``$USER`` can arrive uppercase);
    * every run of characters outside ``[a-z0-9_-]`` collapsed to one ``-``
      (kills whitespace, dots -> no path traversal, ``@``/``<``/``>`` -> no
      IRI break-out);
    * forced to start alphanumeric and clamped to 64 chars.

    The result can never break out of an IRI or a filesystem path, so it is
    injection-proof in exactly the way the strict validator is -- it simply
    never raises. Empty / all-punctuation input folds to
    :data:`PRIMARY_USER_FALLBACK` (the label the primary compartment
    already wears when ``USER_ID`` is unset).
    """
    s = str(raw or "").strip().lower()
    s = re.sub(r"[^a-z0-9_-]+", "-", s)  # any disallowed run -> single '-'
    s = re.sub(r"^[^a-z0-9]+", "", s)    # must start alphanumeric
    s = s[:64]
    s = s.rstrip("-_")                    # tidy any trailing separator
    return s or PRIMARY_USER_FALLBACK


def multiuser_enabled() -> bool:
    """Whether the DEFERRED multiuser paths are explicitly enabled.

    Fail-closed tamper-evident gate: only the exact string ``"1"`` enables
    multiuser. Unset, empty, ``"0"`` and any garbage value all read as OFF,
    so the groundwork ships dark unless an operator opts in deliberately via
    :data:`MULTIUSER_ENABLED_ENV`.
    """
    return os.environ.get(MULTIUSER_ENABLED_ENV, "").strip() == "1"


def resolve_compartment(
    user_id: Optional[str] = None, tenant_id: str = PERSONAL_TENANT
) -> UserCompartment:
    """Resolve a user_id to its compartment. The ONE front door.

    * ``None`` / ``""`` -> the primary compartment (today's behaviour --
      the entire existing call surface has no user_id, and it must keep
      resolving to exactly today's layout).
    * the primary user's own **configured** id (``USER_ID`` env) -> the
      primary compartment (same person, same storage).
    * the literal ``PRIMARY_USER_FALLBACK`` label (``"primary"``) ->
      REJECTED (audit P2). It is the label the primary compartment wears
      when ``USER_ID`` is unset -- the default single-user install -- so
      a *secondary* user provisioned with that id would resolve into the
      operator's default graph and unprefixed Qdrant collections by
      string coincidence. Reserved, fail-closed. (The one exception: an
      operator who has explicitly configured ``USER_ID=primary`` is
      addressing themselves, which is the configured-id rule above.)
    * any other id -> a secondary compartment, strictly validated.
    """
    if user_id is None or not str(user_id).strip():
        return UserCompartment.primary(tenant_id=tenant_id)
    user_id = str(user_id).strip()
    configured_primary_id = os.environ.get("USER_ID", "").strip()
    # Self-address compares on the NORMALISED form so an operator whose
    # USER_ID is e.g. "Andy" self-resolves to primary whether they are
    # addressed as "Andy" or "andy" -- both fold to the same slug the
    # primary compartment carries.
    if configured_primary_id and normalise_user_id(user_id) == normalise_user_id(
        configured_primary_id
    ):
        return UserCompartment.primary(tenant_id=tenant_id)
    if user_id == PRIMARY_USER_FALLBACK:
        raise CompartmentError(
            f"user_id {PRIMARY_USER_FALLBACK!r} is reserved: it is the "
            "fallback label the PRIMARY compartment wears when USER_ID is "
            "unset, so a secondary user with this id would collide into "
            "the operator's default graph and unprefixed collections "
            "(fail-closed)"
        )
    # Genuinely secondary/named compartment: the strict grammar DOES apply
    # here (these ids come from our own provisioning, not free-text), and
    # the DEFERRED multiuser paths are gated OFF unless explicitly enabled.
    user_id = validate_user_id(user_id)
    if not multiuser_enabled():
        raise CompartmentError(
            f"secondary compartment {user_id!r} requested but multiuser is "
            f"DISABLED. The groundwork ships OFF: set {MULTIUSER_ENABLED_ENV}=1 "
            "to enable secondary/named compartments (fail-closed)."
        )
    return UserCompartment(
        user_id=user_id, tenant_id=_check_tenant(tenant_id), is_primary=False
    )


def guard_read(requesting: UserCompartment, resource_owner: UserCompartment) -> None:
    """Fail-closed read guard for any data-access path that can see more
    than one compartment. Tenant wall first, then user wall.

    Raises :class:`TenantIsolationError` or
    :class:`CompartmentIsolationError`; returns ``None`` when the read is
    within the requesting user's own compartment.
    """
    if requesting.tenant_id != resource_owner.tenant_id:
        raise TenantIsolationError(
            f"cross-tenant read rejected: {requesting.tenant_id!r} -> "
            f"{resource_owner.tenant_id!r}"
        )
    if requesting.user_id != resource_owner.user_id or (
        requesting.is_primary != resource_owner.is_primary
    ):
        raise CompartmentIsolationError(
            f"cross-compartment read rejected: user {requesting.user_id!r} "
            f"may not read user {resource_owner.user_id!r}"
        )


#: Named graph the union-mode probe writes its throwaway sentinel into.
#: Deliberately NOT under ``USER_GRAPH_BASE`` so no real user compartment
#: can ever collide with probe traffic.
UNION_PROBE_GRAPH_IRI = "https://pwg.dev/graph/compartment-union-probe"


def assert_default_graph_isolated(
    run_update: Callable[[str], None],
    run_default_graph_query: Callable[[str], dict],
) -> None:
    """Prove the store's default graph does NOT include named graphs.

    AUDIT_4 HIGH-1 guard: compartment isolation silently depends on the
    Oxigraph server NOT running ``--union-default-graph``. In union mode
    an unqualified (no ``GRAPH``, no dataset param) query reads the union
    of every named graph, so the operator's plain ``/query`` traffic would
    leak every secondary user's triples with no code change and no error.
    This function establishes the store's ACTUAL semantics, not its
    configuration flags (which the store does not expose over HTTP):

    1. write a throwaway sentinel triple (fresh UUID subject) into the
       probe named graph :data:`UNION_PROBE_GRAPH_IRI`;
    2. run an UNQUALIFIED query for that sentinel via the caller-supplied
       bare default-graph endpoint;
    3. delete the sentinel again (always -- ``finally``);
    4. if the unqualified query SAW the sentinel, the default graph is the
       union of named graphs -> raise :class:`CompartmentIsolationError`.

    Dependency-injected (``run_update`` posts a raw SPARQL update;
    ``run_default_graph_query`` posts a SPARQL query to the BARE default
    endpoint and returns parsed SPARQL-results JSON) so this module stays
    stdlib-only and the semantics are testable against a real RDF dataset
    without HTTP. Fail-closed: any transport/store error from either
    callable propagates, denying secondary-compartment operation, rather
    than assuming the store is safe. The residual fail-open risk is a
    store that accepts the probe write, then returns a well-formed EMPTY
    result for a query it did not actually evaluate -- indistinguishable
    from a correct non-union answer at this seam.

    Callers should invoke this once per store per process and cache the
    success (see ``IdentityResolver._ensure_compartment_isolation``); the
    probe costs two updates and one query.
    """
    nonce = uuid.uuid4().hex
    sentinel = f"urn:pwg:union-probe:{nonce}"
    triple = f'<{sentinel}> <urn:pwg:union-probe> "{nonce}"'
    run_update(
        f"INSERT DATA {{ GRAPH <{UNION_PROBE_GRAPH_IRI}> {{ {triple} }} }}"
    )
    try:
        results = run_default_graph_query(
            f"SELECT ?leak WHERE {{ <{sentinel}> <urn:pwg:union-probe> ?leak }}"
        )
        bindings = results.get("results", {}).get("bindings", [])
    finally:
        # Always remove the sentinel, even when about to raise: the probe
        # must not litter the store in either mode.
        run_update(
            f"DELETE DATA {{ GRAPH <{UNION_PROBE_GRAPH_IRI}> {{ {triple} }} }}"
        )
    if bindings:
        raise CompartmentIsolationError(
            "store default graph includes named graphs (Oxigraph appears "
            "to be running with --union-default-graph): compartment "
            "isolation CANNOT hold -- an unqualified primary read would "
            "return every secondary user's triples. Refusing secondary-"
            "compartment operation (fail-closed). Restart the store "
            "without --union-default-graph. "
            "See CM061 PRO_ENGINES_AUDIT_4_multiuser.md HIGH-1."
        )
