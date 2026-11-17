"""Join a conversation participant to the People graph by ANY identifier.

WHY (red-team X3, 2026-10-19). ``ingest._participant_identity_triples`` used
to link a participant to a Person only through ``jid`` / ``handle``, by
reconstructing the URI ostler_fda.pwg_ingest mints for that handle. Telegram
(``identifiers.telegram_id``), Instagram (``identifiers.instagram``), GitHub
(``github_login``) and Linear (``email``) participants carry neither, so
they linked to nobody: no person edge, no last-contact bump, no timeline.
And an email handle that resolved to the owner's Contacts card linked to a
phantom URI beside it.

WHAT THIS DOES. For each non-user participant it collects every identifier
it carries, namespaced by platform exactly as CM041 identity_resolver.handles
stores them, and looks them up in the People graph (default graph) in ONE
query per conversation:

  * a live Person holds one  -> the edge goes to THAT Person (rungs a-c of
    the CM041 people-join ladder: email/phone, the Contacts card's social
    profile, or an alias a connector already recorded);
  * the Person is the OWNER  -> no edge at all: the owner never becomes a
    participant contact, even on a second account (work Slack email);
  * nothing holds one        -> for a jid/handle participant, the old
    deterministic URI (unchanged behaviour); for an alias-only participant,
    a ``pwg:UnlinkedHandle`` record in the default graph, byte-for-byte the
    shape CM041 ``handle_link._write_unlinked`` writes (shared contract
    fixture ``tests/fixtures/unlinked_handle_contract.json``). CM041's
    ``sweep_unlinked`` (run on every contact sync) later joins it or turns a
    name match into an owner-confirmed suggestion. NEVER a new Person.

A name is never a join key (no name-only merge). A store that cannot be
queried degrades LOUDLY to the old jid/handle behaviour and writes no
unlinked records (an outage must not create records keyed on nothing).
"""
from __future__ import annotations

import hashlib
import logging
import re
from typing import Dict, List, Optional, Tuple

from . import handle_resolver

logger = logging.getLogger(__name__)

PWG = "https://schema.ostler.ai/ontology#"

_IG_RE = re.compile(r"^[a-z0-9._]{1,30}$")
_TG_USER_RE = re.compile(r"^[a-z][a-z0-9_]{3,31}$")
_GH_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,38})$")
_SLACK_RE = re.compile(r"^[A-Z0-9]{6,20}:[A-Z0-9]{6,20}$")
_ATL_RE = re.compile(r"^[A-Za-z0-9:\-]{6,128}$")
_LINEAR_RE = re.compile(r"^[a-f0-9\-]{8,64}$")
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

# participant field -> CM041 identifier type. Same names as CM041
# identity_resolver/handles.py ALIAS_ID_TYPES.
_FIELD_TYPES = {
    "telegram_id": "telegram_user_id",
    "telegram_user_id": "telegram_user_id",
    "telegram_username": "telegram_username",
    "instagram": "instagram_username",
    "instagram_username": "instagram_username",
    "github_login": "github_login",
    "linear_user_id": "linear_user_id",
    "atlassian_account_id": "atlassian_account_id",
    "account_id": "atlassian_account_id",
    "slack_user": "slack_user",
    "email": "email",
}


def _strip(v: str) -> str:
    v = v.strip()
    return v[1:] if v.startswith("@") else v


def normalise(id_type: str, value) -> Optional[str]:
    """Same normal form as CM041 identity_resolver.handles.normalise_alias
    (and normalise_email for email). Unusable values return None: in
    particular a Telegram key that is not ``user<digits>`` (the exporter
    falls back to the display NAME when from_id is missing) is refused, so a
    name can never become a cross-chat join key."""
    if not isinstance(value, str) or not value.strip():
        return None
    if id_type == "telegram_user_id":
        v = value.strip()
        if v.lower().startswith("user"):
            v = v[4:]
        return v if v.isdigit() else None
    if id_type == "instagram_username":
        v = _strip(value).lower()
        return v if _IG_RE.match(v) else None
    if id_type == "telegram_username":
        v = _strip(value).lower()
        return v if _TG_USER_RE.match(v) else None
    if id_type == "github_login":
        v = _strip(value).lower()
        return v if _GH_RE.match(v) else None
    if id_type == "slack_user":
        v = value.strip().upper()
        return v if _SLACK_RE.match(v) else None
    if id_type == "atlassian_account_id":
        v = value.strip()
        return v if _ATL_RE.match(v) else None
    if id_type == "linear_user_id":
        v = value.strip().lower()
        return v if _LINEAR_RE.match(v) else None
    if id_type == "email":
        v = value.strip().lower()
        return v if _EMAIL_RE.match(v) else None
    return None


def participant_keys(entry: dict) -> List[Tuple[str, str]]:
    """Every usable (id_type, value) the participant carries, de-duplicated."""
    if not isinstance(entry, dict):
        return []
    raw: List[Tuple[str, str]] = []
    ids = entry.get("identifiers")
    if isinstance(ids, dict):
        for k, v in ids.items():
            t = _FIELD_TYPES.get(str(k))
            if t:
                raw.append((t, v))
    for k, t in _FIELD_TYPES.items():
        if k in entry:
            raw.append((t, entry.get(k)))
    h = entry.get("handle")
    if isinstance(h, str) and "@" in h:
        raw.append(("email", h))
    out: List[Tuple[str, str]] = []
    for t, v in raw:
        n = normalise(t, v)
        if n and (t, n) not in out:
            out.append((t, n))
    return out


def unlinked_uri_for(keys: List[str]) -> str:
    """MUST equal CM041 identity_resolver.handle_link.unlinked_uri_for."""
    first = sorted(keys)[0]
    return f"{PWG}unlinked_{hashlib.sha1(first.encode()).hexdigest()[:16]}"


def _lit(v: str) -> str:
    return (v.replace("\\", "\\\\").replace('"', '\\"')
             .replace("\n", "\\n").replace("\r", "\\r"))


def lookup(pairs: List[Tuple[str, str]], oxigraph_url: str) -> Dict[Tuple[str, str], Tuple[str, bool]]:
    """{(type, value): (live person uri, is_owner)} for every pair a Person
    holds. Follows mergedInto one hop to the survivor. Raises
    handle_resolver.StoreQueryError when the store cannot be queried."""
    if not pairs:
        return {}
    values = " ".join(f'("{_lit(t)}" "{_lit(v)}")' for t, v in sorted(set(pairs)))
    rows = handle_resolver._select(
        f"PREFIX pwg: <{PWG}> "
        "SELECT ?t ?v ?p ?live ?own WHERE { "
        f"VALUES (?t ?v) {{ {values} }} "
        "?p pwg:hasIdentifier ?i . ?i pwg:identifierType ?t ; pwg:identifierValue ?v . "
        "OPTIONAL { ?p pwg:mergedInto ?m } "
        "BIND(COALESCE(?m, ?p) AS ?live) "
        "?live a pwg:Person . "
        "OPTIONAL { ?live pwg:isOwner ?own } }",
        oxigraph_url,
    )
    out: Dict[Tuple[str, str], Tuple[str, bool]] = {}
    for r in rows:
        key = ((r.get("t") or {}).get("value", ""), (r.get("v") or {}).get("value", ""))
        live = (r.get("live") or {}).get("value", "")
        own = (r.get("own") or {}).get("value", "").lower() in ("true", "1")
        if live and key not in out:
            out[key] = (live, own)
    return out


def unlinked_turtle(uri: str, platform: str, source: str, keys: List[str],
                    display_name: str, conversation_ref: str) -> str:
    """The CM041 UnlinkedHandle shape (see handle_link._write_unlinked)."""
    lines = [f"<{uri}> a <{PWG}UnlinkedHandle> ;",
             f'  <{PWG}handlePlatform> "{_lit(platform)}" ;',
             f'  <{PWG}handleSource> "{_lit(source)}" ;']
    for k in sorted(keys):
        lines.append(f'  <{PWG}handleKey> "{_lit(k)}" ;')
    if display_name:
        lines.append(f'  <{PWG}handleDisplayName> "{_lit(display_name)}" ;')
    lines.append(f'  <{PWG}seenInConversation> "{_lit(conversation_ref)}" .')
    return "\n".join(lines)
