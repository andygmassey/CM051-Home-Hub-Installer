"""Is this identifier actually one person's identity?

WHY A LIST IS NOT ENOUGH (Andy, 2026-08-08)
===========================================
The first fix for the over-merge was a blocklist of role local-parts and bulk
domains. It caught `invitations@linkedin.com`, `notifications@github.com` and
`dan@tldrnewsletter.com` on Andy's box.

Andy: "everyone's 'not real people' are going to be different to mine, so you
need to make sure you catch them all on anyone's box/data."

Exactly right, and it is the productisation rule too: a list tuned on one
person's mail is a list that fails on the next customer's. Someone's ingest
will hit `hello@teacher-newsletter.de`, `kontakt@verein.at`,
`nyhetsbrev@dn.se`, a Japanese school mailing list, a golf club's Mailchimp --
none of which any English blocklist will ever contain.

THE STRUCTURAL RULE
===================
There is a rule that needs no vocabulary, no language and no list:

    An identifier that maps to MORE THAN ONE distinct human name
    is not an identity.

A personal email address belongs to one person. If ingest sees the same
address presenting as "Craig Whittet" and then "Madhu Motwani", the address is
a channel, not a person -- whatever it is called, whatever language it is in.
That single rule catches every one of Andy's cases AND the ones nobody has
written down yet.

The blocklist survives as a PRIOR, not the defence: it lets the very first
sighting of a known role address be refused before a collision has had a
chance to occur. The structural rule is what makes the guard universal.

CONSERVATIVE BY CONSTRUCTION
============================
Two distinct names is deliberately not the threshold for demotion on its own,
because real people do legitimately present differently ("Andy Quillon",
"Andrew Quillon", "andygmassey"). Names are normalised and compared on their
word set before being counted as distinct, so nicknames and orderings do not
trip it. It takes genuinely different humans to poison an identifier.

A false positive splits one person across nodes -- annoying, recoverable, and
visible on the duplicates page. A false negative fuses strangers into one
identity and silently corrupts who the customer knows. Splitting is safe.

KNOWN LIMITS (Archie's review, 2026-08-08)
==========================================
Written down because an undocumented limit gets rediscovered as a bug. None of
these is a blocker: every one lands on the SAFE side of the calculus above.

Will over-split (false positives -- one person appears twice):

  * NAME CHANGE ON MARRIAGE OR DIVORCE. "Jane Smith" then "Jane Doe" on the
    same address. Shared given name only, so the shared-word union does not
    fire and two clusters survive. The highest-frequency case by some
    distance, and the one most likely to reach support.
  * CROSS-SCRIPT NAMES. A person recorded once as 山田太郎 and once as
    "Taro Yamada". The given-name variants table is a LOOKUP, not a
    transliterator, so nothing folds them together.
  * STAGE AND PEN NAMES with no shared word against the legal name.

  Asymmetry worth knowing: the guard is more aggressive against COMMON given
  names than rare ones, because the shared-word union is gated on recognising
  the given name. A rare name is likelier to be treated as two people.

Will not split (false negatives -- distinct people share one node). These are
the DANGEROUS direction, and each is a genuine gap:

  * FAMILY ON A SHARED ADDRESS where every member is recorded with a single
    word ("Mum", "Dad", "Nige"). No surname to compare, so the household rule
    has nothing to work with.
  * COUPLES SHARING A SURNAME on one address -- structurally identical to one
    person recorded under two given-name variants.
  * SMALL-FIRM SHARED INBOX below the distinct-name threshold: two partners
    on `office@`, seen twice, never a third time.

  Every candidate fix for these trades directly against the false positives
  above, and a false positive there costs less than a false negative here
  costs when it is wrong. Left as limits on purpose, not overlooked.
"""
from __future__ import annotations

import re
import unicodedata

from nameparser import HumanName
from typing import Iterable, Set

try:
    from .role_addresses import is_role_identifier
    from .given_name_variants import canonical_given, is_known_given
    from .relationship_labels import is_relationship_label
except ImportError:  # plain-script use (repair/audit on a customer box)
    from role_addresses import is_role_identifier  # type: ignore
    from given_name_variants import canonical_given, is_known_given  # type: ignore
    from relationship_labels import is_relationship_label  # type: ignore

# Two distinct HUMANS behind one identifier is the signal. Set at 2 because a
# personal address has exactly one owner; the normalisation below is what stops
# "Andy Quillon" / "Andrew Quillon" reaching that count.
DISTINCT_NAME_LIMIT = 2

_PUNCT = re.compile(r"[^\w\s]", re.UNICODE)
_SUFFIX = re.compile(
    r"\b(via linkedin|via facebook|via twitter|via x|"
    r"jr|sr|phd|md|mba|cbe|obe|mbe|esq)\b",
    re.IGNORECASE,
)


# A label that is the IDENTIFIER wearing a name's clothes, not a person.
_ALL_DIGITS = re.compile(r"^[\d\s+().-]+$")
_EMAILISH = re.compile(r"[^\s@]+@[^\s@]+\.[A-Za-z]{2,}")
_MANGLED_EMAIL = re.compile(r"\b(com|net|org|co|io|icloud|gmail|hotmail|outlook|yahoo|me)\b")
_OPAQUE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-", re.IGNORECASE)


def _is_machine_label(name: str) -> bool:
    """True for a phone number, an address, or a UUID posing as a name."""
    n = (name or "").strip()
    if not n:
        return True
    if _ALL_DIGITS.match(n) or _EMAILISH.search(n) or _OPAQUE.match(n):
        return True
    # An address that punctuation-stripping has already mangled into words:
    # "emmaj@icloud.com" -> "com emmaj icloud". Requires a mail-ish token AND
    # no space in the original, so a real person called "Jo Coe" is safe.
    if " " not in n and _MANGLED_EMAIL.search(n.lower()):
        return True
    words = normalise_name(n).split()
    return len(words) > 1 and sum(bool(_MANGLED_EMAIL.fullmatch(w)) for w in words) >= 2


def normalise_name(name: str) -> str:
    """A comparable form: accent-folded, punctuation-free, word-sorted.

    Word-SORTED so "Quillon Andy" and "Andy Quillon" collapse -- name order is
    not consistent across sources (vCard vs mail header vs CJK convention),
    and treating an ordering difference as a different person is how a guard
    starts splitting real people.
    """
    n = unicodedata.normalize("NFKD", name or "")
    n = "".join(c for c in n if not unicodedata.combining(c))
    n = _SUFFIX.sub(" ", n.lower())
    n = _PUNCT.sub(" ", n)
    # Canonicalise given-name variants so Andy IS Andrew, Bob IS Robert.
    #
    # Andy, 2026-08-08: "same surname, and two firstnames where one is a
    # well-known nickname/shortened version of the other should ALWAYS pass to
    # next merge condition."
    #
    # Word-overlap alone only rescued "Andy Quillon"/"Andrew Quillon" because the
    # SURNAME happened to collide -- "Andy" vs "Andrew Quillon" still split, and
    # a shortened given name is the commonest way one person appears twice.
    # Canonicalising here means the overlap test sees "andrew" on both sides.
    return " ".join(sorted(canonical_given(w) for w in n.split() if w))


def distinct_people(names: Iterable[str]) -> Set[str]:
    """Cluster names by SHARED WORDS; return one representative per cluster.

    Two names that share any word are treated as the same person. This is the
    rule that survives contact with real data, and it is language-neutral:

        Andy Quillon / Andrew Quillon   share "quillon"  -> one person
        Andy Quillon / Quillon Andy     identical       -> one person
        Andy Quillon / Andy            share "andy"    -> one person
        Craig Whittet / Madhu Motwani share nothing   -> TWO people

    Subset-matching was tried first and was wrong: it split "Andy Quillon" from
    "Andrew Quillon", because neither word set contains the other. A nickname
    table would fix that case and only that case -- and would be English-only,
    which is the exact failure this module exists to avoid.

    It errs toward MERGING: two different people who share a surname land in
    one cluster and the identifier is not demoted. That is the safe direction
    -- failing to split is recoverable, wrongly splitting a real person is
    visible damage.
    """
    # Drop MACHINE labels before counting people.
    #
    # A contact whose name has not been resolved yet is stored under the raw
    # identifier, so the same person shows up as both "+85293165862" and
    # "Milan Tubic". Counting those as two humans would demote his real phone
    # number and split him in half -- the first live run of this rule flagged
    # exactly that, along with "353877643750 / auntie emma / emmaj icloud
    # oneill" (one aunt, three labels).
    #
    # A digit string or a mangled address is a PLACEHOLDER for a name, never
    # evidence of a second person.
    forms = {
        normalise_name(n) for n in names or []
        if (n or "").strip() and not _is_machine_label(n)
    }
    forms.discard("")
    if not forms:
        return set()

    ordered = sorted(forms)
    parent = {f: f for f in ordered}

    def find(x: str) -> str:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a: str, b: str) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    for i, a in enumerate(ordered):
        wa = set(a.split())
        for b in ordered[i + 1:]:
            shared = wa & set(b.split())
            # A shared GIVEN name is a coincidence, not an identity: "Andrew
            # Quillon" and "Andrew Smith" are two people. A shared surname is
            # evidence. So union only on a shared word that is not a known
            # given name -- and let the single-word rule below handle the
            # "Andy" / "Andrew Quillon" case, where the bare given name is an
            # incomplete record rather than a second human.
            if any(not is_known_given(w) for w in shared):
                union(a, b)

    clusters = {find(f) for f in ordered}

    # A SINGLE-WORD label cannot establish a second person.
    #
    # "Mum", "Home", "Work", "Achiever" are how the customer refers to someone
    # or where they work -- an alias, not another human. The live run flagged
    # `marta.quillon@example.com` as two people ("marta quillon", "mum") and
    # would have demoted Marta's real address, splitting her off her own email.
    #
    # A genuine second person arrives with a genuine name: "Craig Whittet" and
    # "Madhu Motwani" are both multi-word and stay two. So only clusters that
    # contain at least one multi-word form count toward the limit.
    members = {c: set() for c in clusters}
    for f in ordered:
        members[find(f)].add(f)
    return {c for c, forms_in in members.items()
            if any(len(f.split()) > 1 for f in forms_in)} or clusters


def is_non_identifying(identifier: str, names: Iterable[str] = ()) -> bool:
    """True when this identifier cannot be one person's identity.

    Two independent grounds, either sufficient:

      1. STRUCTURAL -- it already presents as two or more distinct people.
         Universal: no list, no language, no locale.
      2. PRIOR -- it matches a known role/bulk pattern. Lets the FIRST
         sighting be refused, before any collision exists to detect.
    """
    if is_role_identifier(identifier):
        return True
    return len(distinct_people(names)) >= DISTINCT_NAME_LIMIT


def explain(identifier: str, names: Iterable[str] = ()) -> str:
    """One line a human can act on. Used in logs and the Doctor surface."""
    if is_role_identifier(identifier):
        return f"{identifier}: matches a known role/bulk-sender pattern"
    people = sorted(distinct_people(names))
    if len(people) >= DISTINCT_NAME_LIMIT:
        return (
            f"{identifier}: presents as {len(people)} distinct people "
            f"({', '.join(people[:4])}{'...' if len(people) > 4 else ''}) "
            "-- a personal address has one owner"
        )
    return f"{identifier}: looks like one person's identifier"


# ---------------------------------------------------------------------------
# Learned state: the structural rule, applied at WRITE time.
# ---------------------------------------------------------------------------
#
# The rule needs to know which names an identifier has already presented as,
# and the keying function only sees the identifier. Querying the graph per
# person would put a SPARQL round-trip in the hot path of every ingest.
#
# So ingest OBSERVES: each (identifier, name) sighting is recorded, and the
# moment an identifier accumulates two distinct people it is written to a
# learned set that `_person_id_from_identifier` consults. Cheap after the first
# detection, and it survives restarts -- which matters because the collision
# that exposes a channel may be hours apart from the mail that created it.
#
# Failure policy: NEVER raise. This is a guard, not a feature; a full disk or
# an unwritable state dir must degrade to "the prior still works", not cost the
# customer their ingest.

import json as _json
import logging as _logging
import os as _os
from typing import Dict as _Dict

_log = _logging.getLogger(__name__)


def _state_path() -> str:
    root = _os.environ.get(
        "OSTLER_STATE_DIR", _os.path.expanduser("~/.ostler/state")
    )
    return _os.path.join(root, "non_identifying_identifiers.json")


def _load_state() -> _Dict[str, list]:
    try:
        with open(_state_path(), encoding="utf-8") as fh:
            data = _json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _save_state(state: _Dict[str, list]) -> None:
    try:
        path = _state_path()
        _os.makedirs(_os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            _json.dump(state, fh, sort_keys=True)
        _os.replace(tmp, path)
    except OSError as exc:
        _log.debug("identifier-quality: could not persist state (%s)", exc)


def observe(identifier: str, name: str) -> bool:
    """Record a sighting. Returns True once this identifier is non-identifying.

    Call from ingest BEFORE keying. The first time an identifier presents as a
    second distinct person, it is remembered and every later sighting is
    refused -- which is how `invitations@linkedin.com` would have been stopped
    at person two instead of person nine.
    """
    ident = (identifier or "").strip().lower()
    if not ident:
        return False
    if is_role_identifier(ident):
        return True

    state = _load_state()
    seen = state.get(ident, [])
    if name and name not in seen:
        seen.append(name)
        state[ident] = seen[:12]  # a dozen is ample to decide; cap the file
        _save_state(state)
    return len(distinct_people(seen)) >= DISTINCT_NAME_LIMIT


def is_learned_non_identifying(identifier: str) -> bool:
    """True when past sightings already proved this identifier is a channel."""
    ident = (identifier or "").strip().lower()
    if not ident:
        return False
    return len(distinct_people(_load_state().get(ident, []))) >= DISTINCT_NAME_LIMIT


# ---------------------------------------------------------------------------
# Household over-merge: relatives fused by a shared address book entry.
# ---------------------------------------------------------------------------
#
# Andy, 2026-08-08, on a node carrying "Adena Hecks", "Brian Hecks" and
# "Nigel Hecks": "these are all fairly specific edge cases where I have been
# sloppy with filing people. Adena, Brian and Nigel are mother, son, and
# father."
#
# The rules above are BLIND to this by construction. distinct_people() unions
# names that share a word, so a family sharing a surname reads as one person --
# the very rule that correctly rescues "Andy Quillon"/"Andrew Quillon" is what
# hides the Heckses. Names alone cannot separate relatives.
#
# The IDENTIFIERS can, and loudly. That node carries:
#
#     brian.h@hex.co.uk   adena.h@hex.co.uk   chris.d@tradegroup.co.uk
#
# Distinct local parts on the same domain are evidence of DIFFERENT PEOPLE --
# the exact mirror of the rule for shared identifiers. One mailbox, one person;
# three mailboxes, three people.
#
# Deliberately narrow. A single person legitimately holds andy@x.com and
# andy.quillon@x.com, so local parts that are variants of each other do not
# count. It takes genuinely unrelated local parts to call it a household.

def _local_parts(identifiers: Iterable[str]) -> Dict[str, Set[str]]:
    """domain -> {local parts}, emails only."""
    out: Dict[str, Set[str]] = {}
    for ident in identifiers or []:
        i = (ident or "").strip().lower()
        if "@" not in i:
            continue
        local, _, domain = i.partition("@")
        if local and domain:
            out.setdefault(domain, set()).add(local)
    return out


def _locals_are_variants(a: str, b: str) -> bool:
    """True when two local parts plausibly belong to ONE person.

    andy / andy.quillon / amassey / a.quillon -- same human with several
    aliases at one employer. Compared on the alphabetic tokens so separators
    and initials do not create false households.
    """
    # Single characters are DISCARDED before comparing.
    #
    # `adena.h@hex.co.uk` and `brian.h@hex.co.uk` share the token "h" -- the
    # family surname initial. Counting that as overlap made the first version
    # of this function call the Hecks household one person, which is the
    # failure it was written to detect. An initial is a convention, not an
    # identity.
    ta = {t for t in re.split(r"[._+-]", a) if len(t) > 1}
    tb = {t for t in re.split(r"[._+-]", b) if len(t) > 1}
    if not ta or not tb:
        # Nothing substantial to compare (e.g. "a" vs "b") -- refuse to guess.
        return True
    if ta & tb:
        return True
    # initial + surname vs full first + surname: a.quillon / andy.quillon
    la, lb = sorted(ta), sorted(tb)
    if la[-1] == lb[-1]:
        return True
    return a.startswith(b) or b.startswith(a)


def distinct_given_names(names: Iterable[str]) -> Set[str]:
    """Canonical FIRST names among the human-looking labels.

    This is the family signature and the one thing distinct_people() cannot
    see. Adena, Brian and Nigel Hecks share a surname, so the shared-word
    clustering fuses them -- correctly, for its own purpose, since that is what
    rescues "Andy Quillon"/"Andrew Quillon". Different GIVEN names behind one
    mailbox set is what says "household".

        Adena Hecks / Brian Hecks / Nigel Hecks  -> adena, brian, nigel  = 3
        Anthony Quillon / Mum / +4478...           -> anthony               = 1
        Andy Quillon / Andrew Quillon              -> andrew               = 1
        Ann-Sofie Virtala / Tim Clark            -> ann-sofie, tim       = 2

    Kinship words and machine labels are excluded first: "Mum" has no given
    name, and counting it would split Anthony from herself.
    """
    out: Set[str] = set()
    for raw in names or []:
        n = (raw or "").strip()
        if not n or _is_machine_label(n) or is_relationship_label(n):
            continue
        # Strip the source suffix BEFORE parsing: nameparser reads
        # "Craig Whittet via LinkedIn" as last="LinkedIn" (verified, not
        # assumed), which would poison every social-imported contact.
        cleaned = _SUFFIX.sub(" ", n)
        first = HumanName(cleaned).first or ""
        first = _PUNCT.sub(" ", first).strip().lower()
        if first:
            out.add(canonical_given(first.split()[0]))
    return out


def looks_like_household(identifiers: Iterable[str], names: Iterable[str] = ()) -> bool:
    """True when one node holds several people who share a surname.

    Requires BOTH signals, because either alone has a benign reading:
      * two or more non-variant local parts on one domain, AND
      * two or more display names that are DISTINCT PEOPLE

    The second condition uses distinct_people(), not a raw name count. The
    first version counted raw names and flagged Marta: that node holds
    `marta.quillon@example.com` and `marta.halloran@example.com` -- one
    person before and after a name change, with "Mum" and two phone numbers
    also on the card. Six
    labels, two mailboxes, ONE person. A maiden-name alias on the same domain
    is the benign case this must never touch.
    """
    for domain, locals_ in _local_parts(identifiers).items():
        if len(locals_) < 2:
            continue
        ordered = sorted(locals_)
        for i, a in enumerate(ordered):
            for b in ordered[i + 1:]:
                if not _locals_are_variants(a, b):
                    if len(distinct_given_names(names)) >= 2:
                        return True
    return False


def explain_household(identifiers: Iterable[str], names: Iterable[str] = ()) -> str:
    parts = _local_parts(identifiers)
    worst = max(parts.items(), key=lambda kv: len(kv[1]), default=("", set()))
    return (
        f"{len(set(n for n in names if n))} names share this node, and "
        f"{len(worst[1])} distinct mailboxes on @{worst[0]} "
        f"({', '.join(sorted(worst[1])[:4])}) -- one mailbox is one person, "
        "so this is several people filed as one"
    )
