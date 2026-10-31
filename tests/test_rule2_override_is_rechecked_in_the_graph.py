"""RULE 2 exception (Andy, 2026-10-30): a journalled override is RE-CHECKED in the graph.

The ratified exception: two Contacts cards with the same full name that share an
email, a validated mobile or a LinkedIn URL are one person and merge. Generational
suffixes are part of the name. A key held by 3+ distinct names is never a key.

no_person_holds_two_contact_cards (BLOCKING) excuses a 2+ card node only when the
merge journal records the exact-identifier override for it. The journal is written
by the code under test, so its reason alone must never turn a FAIL into a PASS:
the probe re-checks, in the GRAPH, (1) the same full name after normalisation with
suffixes kept, (2) both cards really share the claimed key kind, (3) the 3+ names
guard. This file drives that end to end:

  * the REAL BatchResolver.converge writes the graph, the merge journal, its
    snapshots and keyed hashes (secret under a temp OSTLER_HOME);
  * the REAL probe script reads it, over loopback HTTP from an rdflib graph,
    with HOME a temp dir and the install venv interpreter a wrapper onto this
    Python (so `phonenumbers` is present exactly as on a box).

RED on origin/main 2275dd8e (the #3202 probe): the key-mismatch and 3+ names cases
PASS there, because it trusts a journal row with identical names. GREEN here.
Set RULE2_PROBE_FILE to another copy of the probe to measure it (that is how the
RED was taken).

Synthetic data only: example.com addresses, a valid-mobile shape split so no full
number literal sits in the source, and cast names already used by
tests/test_exact_identifier_merge.py.
"""
from __future__ import annotations

import http.server
import json
import os
import stat
import subprocess
import sys
import threading
import urllib.parse
from pathlib import Path

import pytest

rdflib = pytest.importorskip("rdflib")
qdrant_client = pytest.importorskip("qdrant_client")
for _m in ("httpx", "phonenumbers"):
    pytest.importorskip(_m)

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "vendor" / "cm041"))
from identity_resolver import batch_resolver as br  # noqa: E402
from identity_resolver import exact_identifier as ei  # noqa: E402

PWG = br.PWG
PROBE = Path(os.environ.get("RULE2_PROBE_FILE") or
             ROOT / "scripts" / "box_walk_probes" / "probes" / "no_person_holds_two_contact_cards.sh")
MOBILE = "+44" + "7400123456"        # validates as MOBILE (phonenumbers)
VOIP = "+44" + "5612345678"          # VOIP
PERSONAL = "+44" + "7012345678"      # PERSONAL_NUMBER
AMBIGUOUS = "+1" + "2015550123"      # FIXED_LINE_OR_MOBILE (NANP 555-01xx fictional)
LANDLINE = "+44" + "2079460123"      # Ofcom drama range, FIXED_LINE
TOLL_FREE = "+44" + "8001234567"     # TOLL_FREE
UNVALIDATED = "+44" + "7700900123"   # Ofcom drama mobile range: phonenumbers says not valid
EMAIL = "pat.sample@example.com"


class Graph:
    """rdflib behind a single-threaded loopback HTTP server: /query (GET+POST), /update."""

    def __init__(self):
        self.g = rdflib.Graph()
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, body=b""):
                self.send_response(code)
                self.send_header("Content-Type", "application/sparql-results+json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("query", [""])[0]
                self._send(200, outer.g.query(q).serialize(format="json"))

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
                if self.path.startswith("/update"):
                    outer.g.update(body)
                    return self._send(204)
                if (self.headers.get("Content-Type") or "").startswith("application/x-www-form-urlencoded"):
                    body = urllib.parse.parse_qs(body).get("query", [""])[0]
                self._send(200, outer.g.query(body).serialize(format="json"))

        self.srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = "http://127.0.0.1:%d" % self.srv.server_address[1]

    def person(self, slug, name, *, phones=(), emails=(), linkedin=(), uids=()):
        uri = f"{PWG}person_{slug}"
        t = [f"<{uri}> a <{PWG}Person>", f'<{uri}> <{PWG}displayName> "{name}"']
        ids = ([("phone", v) for v in phones] + [("email", v) for v in emails]
               + [("linkedin_url", v) for v in linkedin] + [("icloud_contact_uid", v) for v in uids])
        for n, (typ, val) in enumerate(ids):
            iu = f"{PWG}id_{slug}_{n}"
            t += [f"<{uri}> <{PWG}hasIdentifier> <{iu}>", f"<{iu}> a <{PWG}PersonIdentifier>",
                  f'<{iu}> <{PWG}identifierType> "{typ}"', f'<{iu}> <{PWG}identifierValue> "{val}"']
        self.g.update("INSERT DATA { " + " . ".join(t) + " . }")
        return uri

    def set_value(self, iu, value):
        self.g.update(f"DELETE {{ <{iu}> <{PWG}identifierValue> ?v }} INSERT {{ <{iu}> <{PWG}identifierValue> \"{value}\" }} "
                      f"WHERE {{ <{iu}> <{PWG}identifierValue> ?v }}")

    def set_name(self, uri, name):
        self.g.update(f"DELETE {{ <{uri}> <{PWG}displayName> ?v }} INSERT {{ <{uri}> <{PWG}displayName> \"{name}\" }} "
                      f"WHERE {{ <{uri}> <{PWG}displayName> ?v }}")

    def live(self):
        return {str(r[0]) for r in self.g.query(
            f"SELECT ?p WHERE {{ ?p a <{PWG}Person> . FILTER NOT EXISTS {{ ?p <{PWG}mergedInto> ?m }} }}")}

    def close(self):
        self.srv.shutdown()


@pytest.fixture(autouse=True)
def _qdrant(monkeypatch):
    from qdrant_client import QdrantClient, models
    mem = QdrantClient(":memory:")
    mem.create_collection("people", vectors_config=models.VectorParams(size=4, distance=models.Distance.COSINE))
    monkeypatch.setattr(qdrant_client, "QdrantClient", lambda *a, **k: mem)
    monkeypatch.setattr(br, "_merge_qdrant", lambda *a, **k: True)
    monkeypatch.setattr(br, "_set_qdrant_display_name", lambda *a, **k: None)
    monkeypatch.setattr(br, "record_person_removal", lambda *a, **k: None)


@pytest.fixture
def box(tmp_path, monkeypatch):
    """A temp HOME laid out like a box: ~/.ostler/secrets/service_token, the
    store curl config, the venv interpreter (a wrapper onto this Python)."""
    home = tmp_path / "home"
    ostler = home / ".ostler"
    (ostler / "secrets").mkdir(parents=True)
    (ostler / "secrets" / "service_token").write_text("synthetic-test-secret-0123456789abcdef\n")
    (ostler / "secrets" / "store-curl.conf").write_text('header = "Authorization: Bearer synthetic"\n')
    vbin = ostler / ".venv" / "bin"
    vbin.mkdir(parents=True)
    wrapper = vbin / "python3"
    wrapper.write_text('#!/bin/sh\nexec "%s" "$@"\n' % sys.executable)
    wrapper.chmod(wrapper.stat().st_mode | stat.S_IXUSR)
    monkeypatch.setenv("OSTLER_HOME", str(ostler))
    g = Graph()
    yield {"home": home, "ostler": ostler, "g": g,
           "journal": ostler / "import-pipeline" / "backups" / "merge_journal" / "merge_journal.jsonl"}
    g.close()


def converge(box):
    r = br.BatchResolver(oxigraph_url=box["g"].url,
                         config={"default_country_code": None,
                                 "corrections_dir": str(box["ostler"] / "corr")})
    r.reconcile_qdrant = lambda **k: None
    r.converge(backup_dir=str(box["ostler"] / "import-pipeline" / "backups"))
    return r


def journal_rows(box):
    p = box["journal"]
    return [json.loads(l) for l in p.read_text().splitlines() if l.strip()] if p.exists() else []


def write_rows(box, rows):
    box["journal"].write_text("".join(json.dumps(r) + "\n" for r in rows))


def probe(box, no_phonenumbers=False):
    env = {k: v for k, v in os.environ.items() if k.lower() not in ("http_proxy", "https_proxy", "all_proxy")}
    env.update({"HOME": str(box["home"]), "OSTLER_BOX_HOST": "", "NO_PROXY": "127.0.0.1,localhost",
                "no_proxy": "127.0.0.1,localhost", "OSTLER_OXIGRAPH_URL": box["g"].url + "/query"})
    env.pop("OSTLER_HOME", None)
    if no_phonenumbers:
        # The venv is absent and the fallback interpreter cannot import phonenumbers.
        w = box["ostler"] / ".venv" / "bin" / "python3"
        w.write_text('#!/bin/sh\nshift\nexec "%s" -c "import sys; sys.modules[\'phonenumbers\'] = None; '
                     'exec(compile(sys.stdin.read(), \'<probe>\', \'exec\'))" "$@"\n' % sys.executable)
    r = subprocess.run(["/bin/bash", str(PROBE)], env=env, capture_output=True, text=True, timeout=300,
                       stdin=subprocess.DEVNULL)
    text = r.stdout + r.stderr
    v = next((ln.split("VERDICT:")[1].strip().split(" ")[0] for ln in text.splitlines() if "VERDICT:" in ln), "NONE")
    print("probe verdict: %s" % v)
    return v, text


def override_pair(box, *, emails=(EMAIL,), phones=(), name="John Smith"):
    g = box["g"]
    a = g.person("x1", name, emails=emails, phones=phones, uids=["UID-CARD-ONE"])
    b = g.person("x2", name, emails=emails, phones=phones, uids=["UID-CARD-TWO"])
    converge(box)
    assert len(g.live() & {a, b}) == 1, "the exact-identifier override did not merge the pair"
    rows = journal_rows(box)
    assert len(rows) == 1 and str(rows[0]["override"]).startswith("exact_identifier:"), rows
    return a, b, rows[0]


def discard_id(row, kind_index=0):
    slug = row["discard"].rsplit("person_", 1)[1]
    return f"{PWG}id_{slug}_{kind_index}"


def allowed_line(text):
    return next((l for l in text.splitlines() if "allowed by the exact-identifier override" in l), "")


# ---------------------------------------------------------------- (a) PASS
def test_a_genuine_email_override_is_allowed(box):
    override_pair(box)
    v, out = probe(box)
    assert v == "PASS", out[-1500:]
    assert "1 of 1; violations: 0" in allowed_line(out), out[-1500:]
    assert EMAIL not in out and "John Smith" not in out


def test_a_genuine_mobile_override_is_allowed(box):
    override_pair(box, emails=(), phones=(MOBILE,))
    v, out = probe(box)
    assert v == "PASS", out[-1500:]
    assert MOBILE[-6:] not in out


@pytest.mark.parametrize("phone", [VOIP, PERSONAL, AMBIGUOUS], ids=["voip", "personal", "fixed_line_or_mobile"])
def test_a_person_specific_phone_override_is_allowed_as_the_resolver_allows_it(box, phone):
    """The resolver (exact_identifier.is_usable_phone_key) merges on these, so
    the probe must accept them: VOIP, PERSONAL_NUMBER, and the ambiguous
    FIXED_LINE_OR_MOBILE, which the resolver counts as a mobile."""
    import phonenumbers as pn
    t = pn.number_type(pn.parse(phone, None))
    assert t in ei._PERSONAL_TYPES, t
    override_pair(box, emails=(), phones=(phone,))
    v, out = probe(box)
    assert v == "PASS", out[-1500:]


def test_names_differing_only_by_case_are_the_resolvers_same_name_and_pass(box):
    """The resolver's name_key folds case and whitespace, so the probe must too,
    or a merge the ruleset allows reads as a violation (the #3202 probe compared
    with .strip() only)."""
    _, _, row = override_pair(box)
    box["g"].set_name(row["discard"], "john  SMITH")
    v, out = probe(box)
    assert v == "PASS", out[-1500:]


# ---------------------------------------------------------------- (b) FAIL, no reason
def test_b_a_two_card_merge_with_no_reason_fails_as_reason_unrecorded(box):
    _, _, row = override_pair(box)
    row = dict(row, override="", matched_keys=[], shared_kinds=[], matched_keys_reason="")
    write_rows(box, [row])
    v, out = probe(box)
    assert v == "FAIL", out[-1500:]
    assert "violations: 1 (reason unrecorded: 1;" in allowed_line(out), out[-1500:]


def test_b_mixed_one_override_allowed_one_forced_two_card_node_fails(box):
    """The brief's GREEN statement: in ONE graph, the override merge is allowed
    while a non-override 2-uid node still FAILs, and both counts print."""
    override_pair(box)
    box["g"].person("y1", "Jane Doe", emails=["jane.doe@example.com"], uids=["UID-CARD-THREE", "UID-CARD-FOUR"])
    v, out = probe(box)
    assert v == "FAIL", out[-1500:]
    line = allowed_line(out)
    assert "1 of 2; violations: 1 (reason unrecorded: 1; reason recorded but the graph re-check failed: 0)" in line, line


def test_b_no_journal_at_all_fails(box):
    override_pair(box)
    box["journal"].unlink()
    v, out = probe(box)
    assert v == "FAIL", out[-1500:]


# ---------------------------------------------------------------- (c) FAIL, reason recorded, graph disagrees
def test_c_reason_recorded_but_the_cards_do_not_share_the_key_fails(box):
    """RED on the #3202 probe: identical names plus a keyed row was enough."""
    _, _, row = override_pair(box)
    box["g"].set_value(discard_id(row), "someone.else@example.com")
    v, out = probe(box)
    assert v == "FAIL", out[-1500:]
    assert "key-not-shared-in-graph:email" in out
    assert "reason recorded but the graph re-check failed: 1" in allowed_line(out)


def test_c_reason_recorded_but_the_key_is_held_by_three_names_fails(box):
    """RED on the #3202 probe: it never looked at the guard."""
    override_pair(box)
    for slug, nm in (("z1", "Jane Doe"), ("z2", "Mary Jones"), ("z3", "Sam Li")):
        box["g"].person(slug, nm, emails=[EMAIL])
    v, out = probe(box)
    assert v == "FAIL", out[-1500:]
    assert "guarded:email" in out


@pytest.mark.parametrize("phone", [LANDLINE, TOLL_FREE, UNVALIDATED], ids=["landline", "toll_free", "unvalidated"])
def test_c_reason_recorded_but_the_shared_phone_is_not_person_specific_fails(box, phone):
    """The resolver never merges on these (it refuses, the pair goes to
    review), so a journalled merge whose graph shows one is a FAIL."""
    import phonenumbers as pn
    n = pn.parse(phone, None)
    assert not (pn.is_valid_number(n) and pn.number_type(n) in ei._PERSONAL_TYPES)
    assert not ei.is_usable_phone_key(phone)
    _, _, row = override_pair(box, emails=(), phones=(MOBILE,))
    slug_k = row["keep"].rsplit("person_", 1)[1]
    box["g"].set_value(discard_id(row), phone)
    box["g"].set_value(f"{PWG}id_{slug_k}_0", phone)
    v, out = probe(box)
    assert v == "FAIL", out[-1500:]
    assert "phone-not-person-specific" in out


# ---------------------------------------------------------------- phone-type parity
def _probe_phone_types(text):
    import re
    m = re.search(r'^PERSON_SPECIFIC_PHONE_TYPES = \(([^)]*)\)', text, re.M)
    assert m, "PERSON_SPECIFIC_PHONE_TYPES not found in the probe"
    return set(re.findall(r'"([A-Z_]+)"', m.group(1)))


def test_probe_phone_types_are_exactly_the_resolvers():
    """PARITY: the probe's person-specific phone set is the resolver's
    _PERSONAL_TYPES, by name, both ways. Drift on either side is RED."""
    probe_set = _probe_phone_types(PROBE.read_text())
    import phonenumbers as pn
    # PhoneNumberType members are plain ints; name them through the class.
    names = {n: getattr(pn.PhoneNumberType, n) for n in dir(pn.PhoneNumberType) if n.isupper()}
    resolver_set = {n for n, v in names.items() if v in ei._PERSONAL_TYPES}
    assert len(resolver_set) == len(ei._PERSONAL_TYPES), "a resolver type has no unique name"
    for n in probe_set:
        assert n in names, n
    assert probe_set == resolver_set, ("probe only", probe_set - resolver_set, "resolver only", resolver_set - probe_set)


@pytest.mark.parametrize("other", [
    "John Smith Jr", "John Smith Jr.", "John Smith, Jr", "John Smith, Jr.", "John Smith Sr",
    "John Smith, Sr.", "John Smith Jnr", "John Smith II", "John Smith, II", "John Smith III",
    "John Smith IV", "J. Smith", "J Smith", "John-Smith",
])
def test_c_reason_recorded_but_the_names_differ_fails(box, other):
    _, _, row = override_pair(box)
    box["g"].set_name(row["discard"], other)
    v, out = probe(box)
    assert v == "FAIL", (other, out[-1500:])
    assert "name-mismatch" in out


def test_c_a_missing_snapshot_fails_and_never_passes(box):
    _, _, row = override_pair(box)
    (box["journal"].parent / row["snapshot"]).unlink()
    v, out = probe(box)
    assert v == "FAIL", out[-1500:]
    assert "snapshot-absent" in out


def test_a_phone_key_without_phonenumbers_is_cannot_run_never_pass(box):
    override_pair(box, emails=(), phones=(MOBILE,))
    v, out = probe(box, no_phonenumbers=True)
    assert v == "CANNOT-RUN", out[-1500:]
    assert "phonenumbers=no" in out


# ---------------------------------------------------------------- suffixes in the resolver
@pytest.mark.parametrize("other", [
    "John Smith Jr", "John Smith, Jr.", "John Smith Sr", "John Smith Jnr",
    "John Smith II", "John Smith, III", "John Smith IV", "J. Smith",
])
def test_the_resolver_keeps_a_suffixed_name_apart_even_with_a_shared_email(box, other):
    g = box["g"]
    a = g.person("s1", "John Smith", emails=[EMAIL], uids=["UID-CARD-ONE"])
    b = g.person("s2", other, emails=[EMAIL], uids=["UID-CARD-TWO"])
    converge(box)
    assert {a, b} <= g.live(), other
    assert not [r for r in journal_rows(box) if r.get("kind") == "merge"], other


def test_name_key_keeps_suffixes_and_punctuation_and_folds_only_case_and_spaces():
    nk = ei.name_key
    assert nk("John  SMITH") == nk("john smith")
    for other in ("John Smith Jr", "John Smith, Jr", "John Smith Jnr", "John Smith Sr",
                  "John Smith II", "John Smith III", "J. Smith", "J Smith"):
        assert nk(other) != nk("John Smith"), other
    assert nk("John Smith Jr") != nk("John Smith, Jr")


# ---------------------------------------------------------------- the ruleset text
def test_the_probe_header_carries_the_amended_rule_2_and_andys_words():
    head = PROBE.read_text().split("set -uo pipefail", 1)[0]
    assert "THAT TEXT IS SUPERSEDED (Andy, 2026-10-30)" in head
    assert "Two people with SAME NAME and SAME EMAIL address clearly are te same" in head
    assert "ridiculously small edge case" in head
    assert "person-specific phone number" in head and "Generational suffixes" in head
    assert "MIRRORS exact_identifier's" in PROBE.read_text()


# ---------------------------------------------------------------- the candidate-pair query, at walk scale
def _probe_query(name):
    import re
    m = re.search(r'^%s="(.*?)"\n' % name, PROBE.read_text(), re.S | re.M)
    assert m, name
    return m.group(1).replace('\\"', '"').replace("${ONTO}", PWG)


def test_the_candidate_pair_query_returns_a_measured_number_on_a_walk_sized_graph():
    """v1.0.120 trial box: 59/59 excused, 0 violations, but "collision
    opportunities NOT MEASURED (query UNAVAILABLE)", so CANNOT-RUN. The old
    query joined Person x Person; on this Oxigraph store, shaped like that walk
    graph (11,800 Persons, 2,900 card uids, a 240-holder switchboard), it took
    about 50 s, past the probe's 20 s curl limit. The query must return the
    right number, inside the limit, on the SAME engine the box runs."""
    import random
    import time
    ox = pytest.importorskip("pyoxigraph")
    A = ox.NamedNode("http://www.w3.org/1999/02/22-rdf-syntax-ns#type")
    HAS, TYP, VAL = (ox.NamedNode(PWG + p) for p in ("hasIdentifier", "identifierType", "identifierValue"))
    rnd = random.Random(121)
    quads, holders = [], {}
    for i in range(11800):
        pu = ox.NamedNode(f"{PWG}person_{i}")
        quads += [ox.Quad(pu, A, ox.NamedNode(PWG + "Person"), ox.DefaultGraph()),
                  ox.Quad(pu, ox.NamedNode(PWG + "displayName"), ox.Literal(f"Cast Name {i % 3000}"), ox.DefaultGraph())]
        ids = []
        if i < 2900:
            ids.append(("icloud_contact_uid", f"UID-{i}"))
        if rnd.random() < 0.6:
            ids.append(("phone", "+4474%08d" % rnd.randint(0, 40000)))
        if rnd.random() < 0.5:
            ids.append(("email", f"p{rnd.randint(0, 30000)}@example.com"))
        if i % 50 == 0:
            ids.append(("phone", LANDLINE))
        for n, (k, v) in enumerate(ids):
            iu = ox.NamedNode(f"{PWG}id_{i}_{n}")
            quads += [ox.Quad(pu, HAS, iu, ox.DefaultGraph()), ox.Quad(iu, TYP, ox.Literal(k), ox.DefaultGraph()),
                      ox.Quad(iu, VAL, ox.Literal(v), ox.DefaultGraph())]
            if k in ("phone", "email"):
                holders.setdefault((k, v), set()).add(i)
    st = ox.Store()
    st.extend(quads)
    # The answer, computed without SPARQL: Persons holding a phone or email
    # that another Person also holds.
    want = len({p for hs in holders.values() if len(hs) > 1 for p in hs})
    assert want > 1000
    t0 = time.time()
    rows = list(st.query(_probe_query("_Q_OPPORTUNITY")))
    took = time.time() - t0
    got = int(rows[0]["n"].value)
    print("candidate-pair query: %d (want %d) in %.2fs" % (got, want, took))
    assert got == want
    assert took < 10, "%.1fs: the probe's curl gives the store 20 s" % took
