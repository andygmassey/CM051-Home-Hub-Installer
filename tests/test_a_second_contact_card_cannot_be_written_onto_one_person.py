#!/usr/bin/env python3
"""RULE 2 is enforced on the MATCH DECISION and not on the WRITE that follows.

MEASURED on two independent graphs, 2026-09-05:

    archie   (months of history)              54 Person nodes with 2+ icloud_contact_uid
    archie2  (VIRGIN, built minutes earlier)  53, 113 cards collapsed, worst node 5 -> 1

Both appeared, so an ordinary install on fresh data produces it. RULE 2 of the
ratified dedupe ruleset says:

    MUST NOT MERGE: different canonical keys, even if identical display name.

`icloud_contact_uid` is canonical and unique-by-construction: one macOS Contacts
card, for ever. Two distinct values on one Person node is the ruleset's own
stated violation.

The resolver implements RULE 2 twice and both are called -- but on the DECISION
(`_canonical_key_conflict`, the match path) and on a MERGE of two existing
nodes. Neither governs what `_resolve_and_write_person` does with the match it
was handed: it passes the matched node straight to `_update_person_oxigraph`,
whose only test before attaching the incoming uid is `_identifier_exists`, which
is VALUE-scoped. It asks "is THIS uid already here", which suppresses a repeat
of the same card. It cannot see a DIFFERENT uid already on the node.

TWO SUBJECTS, AND THE ONE THAT SHIPS IS NOT THE ONE IN vendor/.
`install.sh:18069-18072` copies `${SCRIPT_DIR}/contact_syncer` -- the REPO ROOT
copy -- into the import pipeline. `vendor/cm041/contact_syncer` is the upstream
vendored twin and the two have drifted. Both are driven below, and each run
proves by `__file__` that it loaded the copy it names, because a test that
silently measures the wrong twin reports a true fact about a file no customer
runs.

THREE STATES. 0 pass, 1 fail, 2 cannot-run.

British English throughout.
"""
import importlib.machinery
import io
import os
import re
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
VENDOR = os.path.join(REPO, "vendor", "cm041")

U1 = "AAAAAAAA-1111-4111-8111-111111111111"   # the card already on the node
U2 = "BBBBBBBB-2222-4222-8222-222222222222"   # a DIFFERENT card, incoming
PERSON = "https://schema.ostler.ai/ontology#person_deadbeefcafe"

# (label, path to the syncer, sys.path order that must resolve it)
SUBJECTS = [
    ("shipped  (install.sh copies this one)",
     os.path.join(REPO, "contact_syncer", "syncer.py"), [REPO, VENDOR]),
    ("vendored (vendor/cm041, the upstream twin)",
     os.path.join(VENDOR, "contact_syncer", "syncer.py"), [VENDOR, REPO]),
]

PASS = 0
FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print("  [PASS] %s" % m)


def bad(m):
    global FAIL
    FAIL += 1
    print("  [FAIL] %s" % m)


CANNOTS = []
STARTED = False


class _Unmeasured(Exception):
    """One scenario could not be measured. The others still can."""


def cannot(m):
    """Record a refusal.

    BEFORE the scenarios start there is nothing to salvage, so this exits 2.
    ONCE they are running it unwinds a single scenario and the file carries on,
    because the exit code has a precedence: a MEASURED defect outranks an
    unmeasured arm. Without that, deleting the guard made scenario A fail and
    scenario D refuse -- and the refusal won, so the file reported "could not
    measure" over a defect it had just measured.
    """
    print("CANNOT-RUN: %s" % m, file=sys.stderr)
    CANNOTS.append(m)
    if not STARTED:
        raise SystemExit(2)
    raise _Unmeasured(m)


for _label, _path, _ in SUBJECTS:
    if not os.path.isfile(_path):
        cannot("no syncer at %s (%s)" % (_path, _label))
    if "_update_person_oxigraph" not in io.open(_path, encoding="utf-8").read():
        cannot("%s no longer defines _update_person_oxigraph; re-point this test" % _path)


# ---------------------------------------------------------------------------
# A stub graph. It records every UPDATE and answers ASK truthfully about what it
# holds, so `_identifier_exists` behaves exactly as it does against Oxigraph.
# ---------------------------------------------------------------------------
class StubGraph(object):
    def __init__(self, node_uid=U1, fail_conflict_ask=False):
        self.identifiers = {(PERSON, "icloud_contact_uid", node_uid)}
        self.fail_conflict_ask = fail_conflict_ask
        self.updates = []
        self.asks = 0
        self.conflict_asks = 0

    def post(self, url, content=None, headers=None, timeout=None, **kw):
        body = content if isinstance(content, str) else (content or b"").decode()
        if url.endswith("/update"):
            self.updates.append(body)
            return _Resp({}, text="")
        # ASK ON A LINE BOUNDARY, NOT " ASK ". The real query is
        # "PREFIX pwg: <...>\nASK {", so a space-delimited match never fires and
        # every ASK falls through to the SELECT arm, which carries no `boolean`
        # key -- `_identifier_exists` then reads False for a reason that has
        # nothing to do with what the graph holds. The control below caught
        # exactly that, in this file, before it could report a defect.
        if re.search(r"(?m)^\s*ASK\b", body):
            self.asks += 1
            # THE GUARD'S OWN QUESTION. It asks for any icloud_contact_uid on the
            # node OTHER than the incoming one, via a FILTER rather than a value
            # literal, so the value-literal arm below would answer it wrongly
            # (no `identifierValue "..."` to match, hence "not present", hence
            # "no conflict"). The stub has to answer the question Oxigraph would.
            m_f = re.search(r'FILTER\(str\(\?v\) != "([^"]+)"\)', body)
            if m_f:
                self.conflict_asks += 1
                if self.fail_conflict_ask:
                    raise RuntimeError("stub graph refused the RULE 2 read")
                others = {v for (pp, tt, vv) in self.identifiers
                          for v in [vv]
                          if pp == PERSON and tt == "icloud_contact_uid"
                          and vv != m_f.group(1)}
                return _Resp({"boolean": bool(others)})
            m_t = re.search(r'identifierType "([^"]+)"', body)
            m_v = re.search(r'identifierValue "([^"]+)"', body)
            present = (PERSON, m_t.group(1) if m_t else "",
                       m_v.group(1) if m_v else "") in self.identifiers
            return _Resp({"boolean": present})
        return _Resp({"results": {"bindings": []}})


class _Resp(object):
    def __init__(self, payload, text=""):
        self._p = payload
        self.text = text
        self.status_code = 200

    def json(self):
        return self._p

    def raise_for_status(self):
        return None


class _PermissiveModule(types.ModuleType):
    """Anything not named explicitly resolves to an inert class.

    Something on the syncer's transitive import graph does
    `from httpx import AsyncClient`, and the next dependency will want a
    different symbol again. Enumerating them makes this file CANNOT-RUN every
    time an unrelated library moves, which is a false absence dressed as a
    refusal. The write path under test touches none of it, and the per-scenario
    control proves the stub graph was actually asked.
    """

    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        return type(str(name), (object,), {"__init__": lambda self, *a, **k: None})


# ---------------------------------------------------------------------------
# THE THIRD-PARTY CLOSURE, DERIVED STATICALLY AND CHECKED AT RUN TIME.
#
# This file passed on a workstation and returned CANNOT-RUN on CI: `vobject` is
# installed here and absent on a bare runner. Six of the seven names below are
# in that position, so discovering them by pushing and reading the next red job
# is a four-minute round trip per name.
#
# So the two hosts are made equal instead: every one of these is stubbed on
# EVERY host, before the subject is imported, and the write path under test
# touches none of them. `_derive_third_party` re-reads the source tree on each
# run and refuses by name if a new non-stdlib import appears that this list does
# not carry -- the failure arrives as "here is the module you added", not as a
# red job somewhere else.
# ---------------------------------------------------------------------------
THIRD_PARTY = ("phonenumbers", "qdrant_client", "rapidfuzz", "vobject", "yaml")

# httpx is deliberately NOT in that tuple: it is stubbed per scenario with the
# stub graph's own post(), which is how the graph is observed at all.
SUBJECT_ROOTS = (
    os.path.join(REPO, "contact_syncer"),
    os.path.join(VENDOR, "contact_syncer"),
    os.path.join(VENDOR, "identity_resolver"),
)


def _derive_third_party():
    """Every non-stdlib, non-local top-level import across the subject packages."""
    import ast
    tops = set()
    scanned = 0
    for root in SUBJECT_ROOTS:
        for dirpath, _dirs, names in os.walk(root):
            if "__pycache__" in dirpath:
                continue
            for n in names:
                if not n.endswith(".py"):
                    continue
                scanned += 1
                try:
                    tree = ast.parse(io.open(os.path.join(dirpath, n),
                                             encoding="utf-8").read())
                except SyntaxError:
                    continue
                for node in ast.walk(tree):
                    if isinstance(node, ast.Import):
                        for a in node.names:
                            tops.add(a.name.split(".")[0])
                    elif isinstance(node, ast.ImportFrom):
                        if node.level == 0 and node.module:
                            tops.add(node.module.split(".")[0])
    local = {"contact_syncer", "identity_resolver", "ostler_fda", "tests"}
    known_test_only = {"pytest", "httpx"}
    return scanned, {t for t in tops
                     if t not in sys.stdlib_module_names
                     and t not in local
                     and t not in known_test_only}


class _PermissiveLoader(object):
    def create_module(self, spec):
        return _PermissiveModule(spec.name)

    def exec_module(self, module):
        # A package, so `from x.y import z` resolves through the same loader.
        module.__path__ = []


class _StubFinder(object):
    """Fabricates a permissive module for any name under a stubbed root."""

    def __init__(self, roots):
        self.roots = tuple(roots)

    def find_spec(self, fullname, path=None, target=None):
        # importlib.machinery is imported at module scope, NOT here: importing
        # anything inside find_spec re-enters the import lock through this same
        # finder and dies on RecursionError.
        if fullname.split(".")[0] in self.roots:
            return importlib.machinery.ModuleSpec(
                fullname, _PermissiveLoader(), is_package=True)
        return None


def _install_third_party_stubs():
    scanned, derived = _derive_third_party()
    if scanned == 0:
        cannot("scanned no .py files under the subject packages, so the "
               "dependency closure below was derived from nothing")
    unknown = sorted(derived - set(THIRD_PARTY))
    if unknown:
        cannot("the subject packages import %s, which THIRD_PARTY does not "
               "carry. Add them there rather than discovering them one red CI "
               "job at a time. (%d .py files scanned)"
               % (", ".join(unknown), scanned))
    # rapidfuzz first and explicitly: it is the one library whose functions have
    # a meaningful return TYPE if anything ever calls them at import time.
    # sys.modules beats sys.meta_path, so this wins for rapidfuzz and the finder
    # covers everything else.
    if "rapidfuzz" not in sys.modules:
        rf = types.ModuleType("rapidfuzz")
        fuzz = types.ModuleType("rapidfuzz.fuzz")
        for _n in ("ratio", "partial_ratio", "token_sort_ratio",
                   "token_set_ratio", "WRatio"):
            setattr(fuzz, _n, lambda *a, **k: 0)
        proc = types.ModuleType("rapidfuzz.process")
        proc.extractOne = lambda *a, **k: None
        proc.extract = lambda *a, **k: []
        dist = types.ModuleType("rapidfuzz.distance")
        jw = types.ModuleType("rapidfuzz.distance.JaroWinkler")
        jw.similarity = lambda *a, **k: 0.0
        jw.normalized_similarity = lambda *a, **k: 0.0
        dist.JaroWinkler = jw
        rf.fuzz, rf.process, rf.distance = fuzz, proc, dist
        for k, v in (("rapidfuzz", rf), ("rapidfuzz.fuzz", fuzz),
                     ("rapidfuzz.process", proc), ("rapidfuzz.distance", dist),
                     ("rapidfuzz.distance.JaroWinkler", jw)):
            sys.modules[k] = v
    # Drop any REAL copy already imported, so a host that happens to have the
    # wheel measures the same thing as a host that does not.
    for name in list(sys.modules):
        if name.split(".")[0] in THIRD_PARTY and name.split(".")[0] != "rapidfuzz":
            del sys.modules[name]
    sys.meta_path.insert(0, _StubFinder(THIRD_PARTY))


_install_third_party_stubs()


def load_syncer_module(stub, syncer_path, path_order):
    """Import the REAL syncer named by *syncer_path*. Nothing is paraphrased."""
    for name in [n for n in sys.modules
                 if n == "contact_syncer" or n.startswith("contact_syncer.")
                 or n == "identity_resolver" or n.startswith("identity_resolver.")]:
        del sys.modules[name]
    for entry in (REPO, VENDOR):
        while entry in sys.path:
            sys.path.remove(entry)
    for entry in reversed(path_order):
        sys.path.insert(0, entry)

    fake_httpx = _PermissiveModule("httpx")
    fake_httpx.post = stub.post

    class _HTTPError(Exception):
        pass

    fake_httpx.HTTPError = _HTTPError
    fake_httpx.HTTPStatusError = _HTTPError
    fake_httpx.RequestError = _HTTPError
    fake_httpx.Client = object
    fake_httpx.Timeout = lambda *a, **k: None
    saved = sys.modules.get("httpx")
    sys.modules["httpx"] = fake_httpx
    try:
        import importlib
        mod = importlib.import_module("contact_syncer.syncer")
    finally:
        if saved is None:
            sys.modules.pop("httpx", None)
        else:
            sys.modules["httpx"] = saved

    # PROVE THE SUBJECT IS THE SUBJECT. Two packages named contact_syncer sit in
    # this repo. Without this the file can report a true fact about the twin
    # nobody ships.
    got = os.path.realpath(getattr(mod, "__file__", "") or "")
    want = os.path.realpath(syncer_path)
    if got != want:
        cannot("asked for %s but imported %s -- the wrong twin was on sys.path"
               % (want, got))
    return mod


class _Cfg(object):
    OXIGRAPH_URL = "http://stub"
    QDRANT_URL = "http://stub"
    USER_ID = ""
    DEFAULT_COUNTRY_CODE = "GB"
    DEFAULT_PRIVACY_LEVEL = "L2"


class _Match(object):
    def __init__(self, uri):
        self.person_uri = uri
        self.confidence = 1.0
        self.method = "stub"


class _Resolver(object):
    """Returns the conflicting node, exactly as the real resolver did on archie2."""

    default_country_code = "GB"

    def __init__(self, uri=PERSON):
        self._uri = uri
        self.registered = []

    def resolve(self, identity, use_fuzzy=False, **kw):
        return _Match(self._uri) if self._uri else None

    def register_person(self, *a, **kw):
        self.registered.append(a)


def drive(syncer_path, path_order, node_uid, card_uid, label,
          fail_conflict_ask=False):
    """Drive the REAL _resolve_and_write_person, the decision point itself."""
    stub = StubGraph(node_uid, fail_conflict_ask=fail_conflict_ask)
    try:
        mod = load_syncer_module(stub, syncer_path, path_order)
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        import traceback
        _tb = traceback.format_exc().strip().splitlines()
        cannot("could not import %s: %s: %s | %s"
               % (syncer_path, type(exc).__name__, exc, " <- ".join(_tb[-4:])))
    if not hasattr(mod, "ContactSyncer"):
        cannot("%s exposes no ContactSyncer class" % syncer_path)
    syncer = mod.ContactSyncer.__new__(mod.ContactSyncer)
    syncer.cfg = _Cfg()
    syncer.resolver = _Resolver()
    card = {"fn": "A Person", "org": "", "title": "",
            "given_name": "A", "family_name": "Person",
            "phones": [], "emails": []}
    if card_uid:
        card["uid"] = card_uid
    try:
        syncer._resolve_and_write_person(card, "person")
    except Exception as exc:  # noqa: BLE001
        import traceback
        _tb = traceback.format_exc().strip().splitlines()
        cannot("driving the real _resolve_and_write_person (%s) raised %s: %s | %s"
               % (label, type(exc).__name__, exc, " <- ".join(_tb[-3:])))
    # CONTROL PER SCENARIO. If nothing was written the assertions below are
    # about a method that never reached the graph.
    if not stub.updates:
        cannot("%s: the real method wrote nothing at all, so nothing was measured"
               % label)
    return stub


def minted_other_person(stub):
    """Person URIs written that are NOT the matched node."""
    text = "\n".join(stub.updates)
    return set(re.findall(r"ontology#(person_[0-9a-f]+)", text)) - {"person_deadbeefcafe"}


STARTED = True

for label, syncer_path, path_order in SUBJECTS:
    print("\n=== %s ===" % label)

    # ----- SCENARIO A: the subject. The matched node already holds card U1 and
    try:
        # the incoming card is U2. RULE 2 says these must not merge.
        a = drive(syncer_path, path_order, U1, U2, "%s / A conflicting card" % label)
        written_a = "\n".join(a.updates)
        ok("CONTROL A: reached the graph (%d ASK, %d UPDATE)" % (a.asks, len(a.updates)))

        if U2 in written_a and "person_deadbeefcafe" in written_a and not minted_other_person(a):
            bad("A: a SECOND icloud_contact_uid was written onto a node that already "
                "holds a different one, and no separate person was minted. RULE 2 "
                "says different canonical keys must not merge.")
        elif a.conflict_asks == 0:
            # NOT A PASS. If the matched node was never asked whether it already
            # holds a different canonical key, then whatever kept U2 off it was not
            # this guard, and the next refactor can remove the guard without this
            # file noticing.
            cannot("A (%s): the conflicting card did not land, but the node was never "
                   "asked whether it holds a different canonical key (%d such ASKs), "
                   "so the guard is not what prevented it"
                   % (label, a.conflict_asks))
        elif minted_other_person(a):
            ok("A: the node was asked (%d conflict ASK) and the conflicting card was "
               "given its own person node" % a.conflict_asks)
        else:
            ok("A: the node was asked (%d conflict ASK) and no second canonical key "
               "landed on it" % a.conflict_asks)
    except _Unmeasured:
        pass

    # ----- SCENARIO B: MUST-MISS. Same node, the SAME card re-synced. This is
    try:
        # the case `_identifier_exists` exists for and the match must be ACCEPTED.
        # Without B the file cannot tell "the write is unguarded" from "this harness
        # reports a conflict no matter what it is handed".
        b = drive(syncer_path, path_order, U1, U1, "%s / B same card again" % label)
        ok("CONTROL B: reached the graph (%d ASK, %d UPDATE)" % (b.asks, len(b.updates)))
        if minted_other_person(b):
            bad("B MUST-MISS BREACHED: re-syncing the SAME card minted a second "
                "person node, so the guard is rejecting matches it must accept")
        else:
            ok("B MUST-MISS: re-syncing the same card kept the match")
    except _Unmeasured:
        pass

    # ----- SCENARIO D: the graph cannot be read. "Could not look" and "no
    try:
        # conflict" must not come out the same. Declining the match mints a
        # duplicate, which a later merge can repair; accepting it welds two people
        # into one node, which it cannot. This arm exists because the cheapest way
        # to write this guard -- one try/except returning False -- passes A, B and C
        # and reinstates the whole defect the moment Oxigraph hiccups.
        d = drive(syncer_path, path_order, U1, U2, "%s / D unreadable graph" % label,
                  fail_conflict_ask=True)
        ok("CONTROL D: reached the graph (%d ASK, %d conflict ASK, %d UPDATE)"
           % (d.asks, d.conflict_asks, len(d.updates)))
        if d.conflict_asks == 0:
            cannot("D (%s): the guard never asked, so the unreadable-graph path was "
                   "not exercised" % label)
        if U2 in "\n".join(d.updates) and not minted_other_person(d):
            bad("D: the RULE 2 read failed and the card was merged onto the matched "
                "node anyway; a read failure is being treated as 'no conflict'")
        else:
            ok("D: an unreadable RULE 2 check declined the match rather than "
               "assuming there was no conflict")
    except _Unmeasured:
        pass

    # ----- SCENARIO C: MUST-MISS. A card with no uid carries no canonical key,
    try:
        # so there is nothing for RULE 2 to conflict with and the match must stand.
        c = drive(syncer_path, path_order, U1, "", "%s / C card with no uid" % label)
        ok("CONTROL C: reached the graph (%d ASK, %d UPDATE)" % (c.asks, len(c.updates)))
        if minted_other_person(c):
            bad("C MUST-MISS BREACHED: a card carrying NO icloud_contact_uid was "
                "diverted to a new person; a card with no canonical key cannot "
                "conflict with one")
        else:
            ok("C MUST-MISS: a card with no uid kept the match")
    except _Unmeasured:
        pass

print("\n== %d pass / %d fail / %d unmeasured / %d total =="
      % (PASS, FAIL, len(CANNOTS), PASS + FAIL))

# PRECEDENCE, STATED. A measured defect outranks an unmeasured arm; an
# unmeasured arm outranks a pass. Never collapse the two non-zero states.
if FAIL:
    if CANNOTS:
        print("  (%d arm(s) also could not be measured; the defect above is the "
              "verdict)" % len(CANNOTS), file=sys.stderr)
    sys.exit(1)
if CANNOTS:
    print("  %d arm(s) could not be measured and none failed. That is not a pass."
          % len(CANNOTS), file=sys.stderr)
    sys.exit(2)
sys.exit(0)
