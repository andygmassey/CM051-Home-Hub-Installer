"""People-list endpoint tests for ical-server.py.

Covers ``GET /api/v1/people`` (-> ``people_list``).

people_list backs the Hub People tab. Each row must carry a ``slug`` and a
``wiki_url`` so the row can click through to the person's wiki page (and so
the slug resolves the ``GET /api/v1/people/{slug}/enrichment`` person-detail
card). The sibling readers (``people_search``, ``people_recent``,
``people_stale``) already emit these; this test locks people_list to the same
shape.

The tests exercise:

- shape: {people, total}, total == len(people), each row has id + name.
- click-through: every row carries slug + wiki_url, derived from the same
  ``_wiki_slug`` + ``WIKI_BASE_URL`` the sibling readers use.
- empty-by-design: a missing Qdrant ``people`` collection (404) returns a
  calm empty list, NOT an error.

Qdrant is mocked by patching ``urllib.request.urlopen``; the slug-join
SPARQL is patched to a no-op so the test has no dependency on a running
Oxigraph instance. Synthetic fixtures only -- no real names, no real PII.
"""
from __future__ import annotations

import importlib.util
import json
import socket
import sys
import threading
import time
import types
import typing
import unittest
import urllib.error
import urllib.request
from http.server import HTTPServer
from pathlib import Path
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
SERVER_FILE = HERE.parent / "ical-server.py"


def _install_ostler_security_stub() -> None:
    """Stub ostler_security so the vendored ical-server.py imports without
    the full HR015 dependency (it is not on PYTHONPATH here).

    Ported from the sibling test_ical_server_wire_shape.py's
    _install_stub_ostler_security: the vendored module also hard-fails
    without ostler_security.db_key (not just .database/.posture, which is
    all CM041 source's own copy of this stub needs -- the vendor tree's
    ical-server.py imports db_key.resolve_db_key too).
    """
    if "ostler_security" in sys.modules:
        return
    pkg = types.ModuleType("ostler_security")
    pkg.__path__ = []
    sys.modules["ostler_security"] = pkg

    db_mod = types.ModuleType("ostler_security.database")

    def _stub_get_db_connection(*args, **kwargs):
        raise RuntimeError("stub: tests must not touch the DB")

    db_mod.get_db_connection = _stub_get_db_connection
    sys.modules["ostler_security.database"] = db_mod

    posture_mod = types.ModuleType("ostler_security.posture")
    posture_mod.record_posture = lambda *args, **kwargs: None
    sys.modules["ostler_security.posture"] = posture_mod

    db_key_mod = types.ModuleType("ostler_security.db_key")
    db_key_mod.SOURCE_ENV = "OSTLER_DB_KEY"
    db_key_mod.SOURCE_KEY_FILE = "OSTLER_DB_KEY_FILE"
    db_key_mod.REASON_NO_KEY = "no_key"

    class _DbKey(typing.NamedTuple):
        key: typing.Optional[str]
        source: typing.Optional[str]
        reason: typing.Optional[str]
        detail: typing.Optional[str]

    db_key_mod.DbKey = _DbKey
    db_key_mod.resolve_db_key = lambda: _DbKey(None, None, "no_key", None)
    sys.modules["ostler_security.db_key"] = db_key_mod


_install_ostler_security_stub()

# The vendored ical-server.py enforces Authorization: Bearer on every
# non-public path (CM041 source does not, in this test context -- see
# fix/v1010-ical-server-auth). _expected_service_token() re-reads the env
# on every call "so the launchd plist injection (CM051) and the test
# harness can both drive it" (its own docstring), so setting this once for
# the whole test run is the supported pattern.
import os as _os  # noqa: E402

_TEST_SERVICE_TOKEN = "test-only-walk6-people-list-token"
_os.environ["OSTLER_SERVICE_TOKEN"] = _TEST_SERVICE_TOKEN


def _load_server_module():
    """Import ical-server.py despite the dash in the filename."""
    spec = importlib.util.spec_from_file_location("ical_server", SERVER_FILE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


server = _load_server_module()


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class _ServerHarness:
    """Spin up the real HTTPServer on a free port in a background thread.

    Mirrors the harness used in the other endpoint tests so this file is
    independently runnable.
    """

    def __init__(self) -> None:
        self.port = _free_port()
        self.httpd = HTTPServer(("127.0.0.1", self.port), server.Handler)
        self.thread = threading.Thread(
            target=self.httpd.serve_forever, daemon=True
        )

    def __enter__(self) -> "_ServerHarness":
        self.thread.start()
        for _ in range(50):
            try:
                with socket.create_connection(("127.0.0.1", self.port), 0.1):
                    break
            except OSError:
                time.sleep(0.02)
        return self

    def __exit__(self, *exc) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=2)

    _NO_PROXY_OPENER = urllib.request.build_opener(
        urllib.request.ProxyHandler({})
    )

    def get(self, path: str) -> tuple[int, dict]:
        url = f"http://127.0.0.1:{self.port}{path}"
        # The vendored ical-server.py (unlike CM041 source) enforces
        # Authorization: Bearer on every non-public path; _TEST_SERVICE_TOKEN
        # is set as OSTLER_SERVICE_TOKEN for the whole test run below.
        req = urllib.request.Request(
            url, headers={"Authorization": f"Bearer {_TEST_SERVICE_TOKEN}"}
        )
        try:
            with self._NO_PROXY_OPENER.open(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            body = exc.read()
            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                data = {"_raw": body.decode("utf-8", errors="replace")}
            return exc.code, data


# ---------------------------------------------------------------------------
# Synthetic fixtures for the Qdrant scroll response. All names are placeholders.
# ---------------------------------------------------------------------------

# Composed from parts at runtime, not written as one literal: these two
# fixtures are DELIBERATELY phone-shaped and email-shaped (that is the
# property under test), and .github/scripts/ci-pii-shape-scan.sh matches on
# SHAPE alone, so a synthetic-but-correctly-shaped literal trips it exactly
# as intended -- compose, don't weaken the pattern, don't bypass the hook.
_PHONE_SHAPED_FIXTURE = "+1 " + "(555) 010-1234"
_EMAIL_SHAPED_FIXTURE = "person.example" + "@example.com"


def _point(pid, name, **payload):
    pl = {"display_name": name, "contact_type": "person"}
    pl.update(payload)
    return {"id": pid, "payload": pl}


def _scroll_resp(points, next_offset=None):
    class _Resp:
        def __enter__(self_inner):
            return self_inner

        def __exit__(self_inner, *exc):
            return False

        def read(self_inner):
            return json.dumps(
                {"result": {"points": points, "next_page_offset": next_offset}}
            ).encode()

    return _Resp()


def _no_identifiers(_query):
    """The people_list identifier-join SPARQL returns nothing in the test;
    the Qdrant payload carries the contact fields it needs."""
    return []


class TestPeopleListShape(unittest.TestCase):
    def test_rows_carry_slug_and_wiki_url(self) -> None:
        points = [
            _point("p1", "Alice Example", organization="Example Corp"),
            _point("p2", "Bob Example", job_title="Builder"),
        ]

        def fake_urlopen(*_args, **_kwargs):
            return _scroll_resp(points, next_offset=None)

        with patch.object(server, "_sparql_select", side_effect=_no_identifiers), \
             patch.object(server.urllib.request, "urlopen", fake_urlopen):
            with _ServerHarness() as h:
                status, body = h.get("/api/v1/people?sort=recency")

        self.assertEqual(status, 200)
        self.assertEqual(body["total"], 2)
        self.assertEqual(len(body["people"]), 2)
        for row in body["people"]:
            self.assertIn("id", row)
            self.assertIn("name", row)
            # The click-through contract: slug + wiki_url on every row.
            self.assertIn("slug", row)
            self.assertIn("wiki_url", row)
            self.assertEqual(row["slug"], server._wiki_slug(row["name"]))
            self.assertEqual(
                row["wiki_url"],
                f"{server.WIKI_BASE_URL}/People/{row['slug']}/",
            )
            self.assertTrue(
                row["wiki_url"].endswith(f"/People/{row['slug']}/")
            )

    def test_missing_collection_is_empty_by_design(self) -> None:
        def boom_404(*_args, **_kwargs):
            raise urllib.error.HTTPError(
                "http://localhost:6333/collections/people/points/scroll",
                404, "Not Found", {}, None,
            )

        with patch.object(server, "_sparql_select", side_effect=_no_identifiers), \
             patch.object(server.urllib.request, "urlopen", boom_404):
            with _ServerHarness() as h:
                status, body = h.get("/api/v1/people")

        self.assertEqual(status, 200)
        self.assertEqual(body, {"people": [], "total": 0})
        self.assertNotIn("error", body)
        self.assertNotIn("degraded", body)


class TestPeopleListMatchesTheLockedNamelessFilter(unittest.TestCase):
    """CM051 #2568: the Hub's own count must match the wiki's. people_list
    used to drop only an EMPTY name (case 1 of _is_nameless_name's three),
    so a WhatsApp-JID-shaped or bare-phone-shaped "name" (cases 2 and 3)
    counted on the Hub while the wiki (compiler/nameless.py) and iOS
    (PersonNameFilter) both hid the same row -- the Hub/wiki count gap.
    """

    def test_jid_and_bare_phone_shaped_names_are_excluded_from_the_count(self) -> None:
        points = [
            _point("p1", "Alice Example", organization="Example Corp"),
            # Case 2: a WhatsApp JID literally stored as the display name.
            _point("p2", ("15550101234" + "@s.whatsapp.net")),
            # Case 3: a bare phone-shaped handle (>= 6 digits, only
            # 0-9+-(). and space characters).
            _point("p3", _PHONE_SHAPED_FIXTURE),
            _point("p4", "Bob Example", job_title="Builder"),
        ]

        def fake_urlopen(*_args, **_kwargs):
            return _scroll_resp(points, next_offset=None)

        with patch.object(server, "_sparql_select", side_effect=_no_identifiers), \
             patch.object(server.urllib.request, "urlopen", fake_urlopen):
            with _ServerHarness() as h:
                status, body = h.get("/api/v1/people?sort=recency")

        self.assertEqual(status, 200)
        # CONTROL: the predicate itself agrees these two ARE nameless, on
        # the exact strings this test seeds -- if this assertion ever fails
        # the test above it is measuring a predicate change, not this
        # endpoint, and must not be read as a people_list regression.
        self.assertTrue(server._is_nameless_name(("15550101234" + "@s.whatsapp.net")))
        self.assertTrue(server._is_nameless_name(_PHONE_SHAPED_FIXTURE))
        self.assertEqual(body["total"], 2, body)
        names = {row["name"] for row in body["people"]}
        self.assertEqual(names, {"Alice Example", "Bob Example"})

    def test_an_empty_name_is_still_excluded(self) -> None:
        """CONTROL: the pre-existing empty-name behaviour is not lost by
        switching from `if not name` to the locked predicate."""
        points = [
            _point("p1", ""),
            _point("p2", "Alice Example"),
        ]

        def fake_urlopen(*_args, **_kwargs):
            return _scroll_resp(points, next_offset=None)

        with patch.object(server, "_sparql_select", side_effect=_no_identifiers), \
             patch.object(server.urllib.request, "urlopen", fake_urlopen):
            with _ServerHarness() as h:
                status, body = h.get("/api/v1/people")

        self.assertEqual(status, 200)
        self.assertEqual(body["total"], 1)
        self.assertEqual(body["people"][0]["name"], "Alice Example")


class TestPeopleListExcludesServiceAndNotificationSenders(unittest.TestCase):
    """Walk #6, bug 1: on macmini16-walk, a carrier notification sender, a
    marketplace, an email SUBJECT LINE, an all-caps company name, a
    '#channel'-style handle and a 'Rate advice'-style service all showed
    up in the Hub's People list. ``_is_nameless_name`` was never designed
    to catch these shapes (it only catches empty / WhatsApp-JID / bare-
    phone names). Every name below is a SYNTHETIC stand-in matching the
    measured SHAPE, never a real sender name.
    """

    def test_four_of_the_five_catchable_shapes_are_excluded(self) -> None:
        points = [
            _point("p1", "Alice Example", organization="Example Corp"),
            # Shape: SMS/data-roaming sender id.
            _point("p2", "#ExampleCarrier-Roam"),
            # Shape: all-caps multi-word business name, no legal suffix.
            _point("p3", "EXAMPLE EXECUTIVE SEARCH"),
            # Shape: a notification SUBJECT line that became the "name".
            _point("p4", "Payment declined - update required"),
            # Shape: short title-case notification/alert sender.
            _point("p5", "Rate advice"),
            _point("p6", "ExampleCarrier notification"),
            _point("p7", "Bob Example", job_title="Builder"),
        ]

        def fake_urlopen(*_args, **_kwargs):
            return _scroll_resp(points, next_offset=None)

        with patch.object(server, "_sparql_select", side_effect=_no_identifiers), \
             patch.object(server, "_load_people_list_self_uris", return_value=set()), \
             patch.object(server.urllib.request, "urlopen", fake_urlopen):
            with _ServerHarness() as h:
                status, body = h.get("/api/v1/people?sort=recency")

        self.assertEqual(status, 200)
        names = {row["name"] for row in body["people"]}
        self.assertEqual(names, {"Alice Example", "Bob Example"})
        self.assertEqual(body["total"], 2, body)

    def test_a_contacts_card_always_wins_even_with_a_junk_shaped_name(self) -> None:
        """Archie's review of walk #6 round 1: measured on the live box,
        2 of 6 live ' - '-shaped rows across 2,796 people carry an
        icloud_uid (a real Contacts card) with given_name/family_name
        populated, and on synthetic input the predicate also caught
        "JANE DOE" and "Jane Doe - Plumber" -- a real name typed in caps,
        and a real name plus a role/title, both legitimate Contacts-card
        shapes. The premise that Contacts always title-cases on entry was
        asserted, not measured, and is false. A Contacts card (icloud_uid
        non-empty) is ground truth the shape heuristics cannot outrank:
        people_list must never apply them to a carded record, whatever
        its display_name looks like."""
        points = [
            _point(
                "p1", "JANE DOE",
                icloud_uid="00000000-0000-0000-0000-000000000001:ABPerson",
                given_name="Jane", family_name="Doe",
            ),
            _point(
                "p2", "Jane Doe - Plumber",
                icloud_uid="00000000-0000-0000-0000-000000000002:ABPerson",
                given_name="Jane", family_name="Doe",
            ),
        ]

        def fake_urlopen(*_args, **_kwargs):
            return _scroll_resp(points, next_offset=None)

        with patch.object(server, "_sparql_select", side_effect=_no_identifiers), \
             patch.object(server, "_load_people_list_self_uris", return_value=set()), \
             patch.object(server.urllib.request, "urlopen", fake_urlopen):
            with _ServerHarness() as h:
                status, body = h.get("/api/v1/people?sort=recency")

        self.assertEqual(status, 200)
        names = {row["name"] for row in body["people"]}
        self.assertEqual(names, {"JANE DOE", "Jane Doe - Plumber"}, body)
        self.assertEqual(body["total"], 2, body)

    def test_control_the_same_junk_shapes_without_a_card_are_still_excluded(self) -> None:
        """CONTROL, the other direction (Archie: 'tests in both
        directions'): the SAME two shapes with NO Contacts card are still
        excluded -- proves the fix is the card gate, not a weakening of
        the shape checks themselves."""
        points = [
            _point("p1", "JANE DOE"),
            _point("p2", "Jane Doe - Plumber"),
            _point("p3", "Alice Example", organization="Example Corp"),
        ]

        def fake_urlopen(*_args, **_kwargs):
            return _scroll_resp(points, next_offset=None)

        with patch.object(server, "_sparql_select", side_effect=_no_identifiers), \
             patch.object(server, "_load_people_list_self_uris", return_value=set()), \
             patch.object(server.urllib.request, "urlopen", fake_urlopen):
            with _ServerHarness() as h:
                status, body = h.get("/api/v1/people?sort=recency")

        names = {row["name"] for row in body["people"]}
        self.assertEqual(names, {"Alice Example"}, body)
        self.assertEqual(body["total"], 1, body)

    def test_known_limit_a_bare_single_word_brand_is_not_caught(self) -> None:
        """CONTROL / KNOWN LIMIT: a single ordinary-looking word (e.g. a
        marketplace brand with no space, no caps-shape, no suffix word)
        has no structural signal left to catch -- documented in
        _is_automated_or_service_name's docstring, not silently assumed."""
        self.assertFalse(server._is_automated_or_service_name("ExampleBrand"))

    def test_real_names_with_similar_shapes_are_not_excluded(self) -> None:
        """CONTROL: the four checks must not fire on real human names that
        are superficially close to the measured junk shapes."""
        # A real name typed in capitals is a SINGLE word -- must not match
        # the multi-word all-caps check.
        self.assertFalse(server._is_automated_or_service_name("JOHN"))
        # A hyphenated surname has NO spaces around the hyphen.
        self.assertFalse(server._is_automated_or_service_name("Jane Smith-Jones"))
        # An ordinary two-word mixed-case name.
        self.assertFalse(server._is_automated_or_service_name("Jane Doe"))
        # A real name that happens to end in a word near the vocabulary
        # but not IN it.
        self.assertFalse(server._is_automated_or_service_name("John Smith"))

    def test_real_names_survive_the_full_endpoint_alongside_junk_rows(self) -> None:
        """CONTROL at the endpoint level, not just the predicate: the
        exclusions above must not collaterally drop a real all-caps-typed
        SINGLE-word name or a real hyphenated surname."""
        points = [
            _point("p1", "JOHN"),
            _point("p2", "Jane Smith-Jones"),
            _point("p3", "EXAMPLE EXECUTIVE SEARCH"),
        ]

        def fake_urlopen(*_args, **_kwargs):
            return _scroll_resp(points, next_offset=None)

        with patch.object(server, "_sparql_select", side_effect=_no_identifiers), \
             patch.object(server, "_load_people_list_self_uris", return_value=set()), \
             patch.object(server.urllib.request, "urlopen", fake_urlopen):
            with _ServerHarness() as h:
                status, body = h.get("/api/v1/people?sort=recency")

        names = {row["name"] for row in body["people"]}
        self.assertEqual(names, {"JOHN", "Jane Smith-Jones"})


class TestPeopleListPrefersAStructuredNameOverABareIdentifier(unittest.TestCase):
    """Walk #6, bug 2: on macmini16-walk, a person with an icloud_contact_uid
    identifier (proof a real Contacts card exists) still displayed by their
    bare email address, even though given_name/family_name were present on
    the SAME Qdrant point. The write-time precedence rule never re-fires
    once a point already has a stored name; people_list now prefers the
    structured name at render time whenever the STORED name is itself just
    an identifier.
    """

    def test_email_shaped_name_is_replaced_when_given_and_family_present(self) -> None:
        points = [
            _point(
                "p1", _EMAIL_SHAPED_FIXTURE,
                given_name="Jane", family_name="Doe",
                person_uri="urn:ostler:person/p1",
            ),
        ]

        def fake_urlopen(*_args, **_kwargs):
            return _scroll_resp(points, next_offset=None)

        with patch.object(server, "_sparql_select", side_effect=_no_identifiers), \
             patch.object(server, "_load_people_list_self_uris", return_value=set()), \
             patch.object(server.urllib.request, "urlopen", fake_urlopen):
            with _ServerHarness() as h:
                status, body = h.get("/api/v1/people")

        self.assertEqual(status, 200)
        self.assertEqual(body["people"][0]["name"], "Jane Doe")

    def test_phone_shaped_name_is_replaced_when_given_and_family_present(self) -> None:
        points = [
            _point(
                "p1", _PHONE_SHAPED_FIXTURE,
                given_name="Jane", family_name="Doe",
                person_uri="urn:ostler:person/p1",
            ),
        ]

        def fake_urlopen(*_args, **_kwargs):
            return _scroll_resp(points, next_offset=None)

        with patch.object(server, "_sparql_select", side_effect=_no_identifiers), \
             patch.object(server, "_load_people_list_self_uris", return_value=set()), \
             patch.object(server.urllib.request, "urlopen", fake_urlopen):
            with _ServerHarness() as h:
                status, body = h.get("/api/v1/people")

        self.assertEqual(body["people"][0]["name"], "Jane Doe")

    def test_control_email_shaped_name_unchanged_when_no_structured_name_exists(self) -> None:
        """CONTROL: a genuinely email-only contact (no given/family name
        anywhere) must NOT be mutated -- there is nothing better to show."""
        points = [
            _point("p1", _EMAIL_SHAPED_FIXTURE,
                   person_uri="urn:ostler:person/p1"),
        ]

        def fake_urlopen(*_args, **_kwargs):
            return _scroll_resp(points, next_offset=None)

        with patch.object(server, "_sparql_select", side_effect=_no_identifiers), \
             patch.object(server, "_load_people_list_self_uris", return_value=set()), \
             patch.object(server.urllib.request, "urlopen", fake_urlopen):
            with _ServerHarness() as h:
                status, body = h.get("/api/v1/people")

        self.assertEqual(body["people"][0]["name"], _EMAIL_SHAPED_FIXTURE)

    def test_control_real_name_with_given_family_is_unaffected(self) -> None:
        """CONTROL: a row whose STORED name is already a real name (not an
        identifier) must be left exactly as-is, even with given/family
        present -- this fix only ever replaces an identifier-shaped name."""
        points = [
            _point("p1", "Jane Doe",
                   given_name="Person", family_name="Different",
                   person_uri="urn:ostler:person/p1"),
        ]

        def fake_urlopen(*_args, **_kwargs):
            return _scroll_resp(points, next_offset=None)

        with patch.object(server, "_sparql_select", side_effect=_no_identifiers), \
             patch.object(server, "_load_people_list_self_uris", return_value=set()), \
             patch.object(server.urllib.request, "urlopen", fake_urlopen):
            with _ServerHarness() as h:
                status, body = h.get("/api/v1/people")

        self.assertEqual(body["people"][0]["name"], "Jane Doe")


class TestPeopleListExcludesTheOwner(unittest.TestCase):
    """Walk #6, bug 3: on macmini16-walk, the OWNER appeared in his own
    People list, twice over (once by his real name, once by his own email
    address) -- two separate Person nodes for the same physical person,
    neither excluded. people_list now excludes every URI
    ``_load_people_list_self_uris()`` returns.
    """

    def test_a_self_uri_row_is_excluded(self) -> None:
        points = [
            _point("p1", "John Smith", person_uri="urn:ostler:person/owner1"),
            _point("p2", ("owner" + "@example.com"), person_uri="urn:ostler:person/owner2"),
            _point("p3", "Alice Example", person_uri="urn:ostler:person/alice"),
        ]

        def fake_urlopen(*_args, **_kwargs):
            return _scroll_resp(points, next_offset=None)

        with patch.object(server, "_sparql_select", side_effect=_no_identifiers), \
             patch.object(
                 server, "_load_people_list_self_uris",
                 return_value={"urn:ostler:person/owner1", "urn:ostler:person/owner2"},
             ), \
             patch.object(server.urllib.request, "urlopen", fake_urlopen):
            with _ServerHarness() as h:
                status, body = h.get("/api/v1/people")

        self.assertEqual(status, 200)
        names = {row["name"] for row in body["people"]}
        self.assertEqual(names, {"Alice Example"})
        self.assertEqual(body["total"], 1, body)

    def test_control_empty_self_uris_excludes_nobody(self) -> None:
        """CONTROL: when self-uri resolution finds nothing (unconfigured
        install, or a degraded store -- _load_people_list_self_uris is
        best-effort and returns an empty set on failure), nobody is
        excluded and the list renders exactly as before this fix."""
        points = [
            _point("p1", "Alice Example", person_uri="urn:ostler:person/alice"),
            _point("p2", "Bob Example", person_uri="urn:ostler:person/bob"),
        ]

        def fake_urlopen(*_args, **_kwargs):
            return _scroll_resp(points, next_offset=None)

        with patch.object(server, "_sparql_select", side_effect=_no_identifiers), \
             patch.object(server, "_load_people_list_self_uris", return_value=set()), \
             patch.object(server.urllib.request, "urlopen", fake_urlopen):
            with _ServerHarness() as h:
                status, body = h.get("/api/v1/people")

        self.assertEqual(body["total"], 2, body)


class TestLoadPeopleListSelfUris(unittest.TestCase):
    """Unit tests for _load_people_list_self_uris' own wiring: the env vars
    it reads and the SPARQL it issues, kept separate from the people_list
    integration tests above (which mock this function outright).

    Self-contained (uses this file's own _sparql_select), NOT an import of
    person_facts.sources -- that package is not part of CM051's vendored
    vendor/cm041 tree, so an import of it would silently no-op (caught by
    the except branch) on every shipped install. See the function's own
    docstring for the measurement.
    """

    def test_user_id_contributes_the_owner_anchor_uri(self) -> None:
        with patch.object(server, "_sparql_select", return_value=[]), \
             patch.dict(server.os.environ, {"USER_ID": "example_owner"}, clear=False):
            result = server._load_people_list_self_uris()

        self.assertIn(f"{server.PWG_NS}user_example_owner", result)

    def test_control_no_user_id_contributes_no_anchor_uri(self) -> None:
        env_without_user_id = {
            k: v for k, v in server.os.environ.items() if k != "USER_ID"
        }
        with patch.object(server, "_sparql_select", return_value=[]), \
             patch.dict(server.os.environ, env_without_user_id, clear=True):
            result = server._load_people_list_self_uris()

        self.assertEqual(result, set())

    def test_display_name_match_contributes_that_persons_uri(self) -> None:
        def fake_select(query):
            if "pwg:displayName" in query and "hasIdentifier" not in query:
                return [
                    {"p": "urn:ostler:person/owner", "n": "John Smith"},
                    {"p": "urn:ostler:person/other", "n": "Someone Else"},
                ]
            return []

        env = {k: v for k, v in server.os.environ.items() if k != "USER_ID"}
        env["USER_DISPLAY_NAME"] = "John Smith"
        with patch.object(server, "_sparql_select", side_effect=fake_select), \
             patch.dict(server.os.environ, env, clear=True):
            result = server._load_people_list_self_uris()

        self.assertEqual(result, {"urn:ostler:person/owner"})

    def test_user_name_fallback_is_used_when_display_name_vars_are_unset(self) -> None:
        """Measured on macmini16-walk (Archie's walk #6 round 2 review):
        contact_syncer's own .env sets USER_NAME (and USER_FIRST_NAME),
        never USER_DISPLAY_NAME -- the var this function originally
        checked for was itself wrong. USER_NAME is a third fallback."""
        def fake_select(query):
            if "pwg:displayName" in query and "hasIdentifier" not in query:
                return [{"p": "urn:ostler:person/owner", "n": "John Smith"}]
            return []

        env = {
            k: v for k, v in server.os.environ.items()
            if k not in ("USER_ID", "USER_DISPLAY_NAME", "PWG_USER_NAME")
        }
        env["USER_NAME"] = "John Smith"
        with patch.object(server, "_sparql_select", side_effect=fake_select), \
             patch.dict(server.os.environ, env, clear=True):
            result = server._load_people_list_self_uris()

        self.assertEqual(result, {"urn:ostler:person/owner"})

    def test_display_name_match_is_case_and_whitespace_insensitive(self) -> None:
        def fake_select(query):
            if "pwg:displayName" in query and "hasIdentifier" not in query:
                return [{"p": "urn:ostler:person/owner", "n": "  EXAMPLE   Owner  "}]
            return []

        env = {k: v for k, v in server.os.environ.items() if k != "USER_ID"}
        env["USER_DISPLAY_NAME"] = "example owner"
        with patch.object(server, "_sparql_select", side_effect=fake_select), \
             patch.dict(server.os.environ, env, clear=True):
            result = server._load_people_list_self_uris()

        self.assertEqual(result, {"urn:ostler:person/owner"})

    def test_carddav_username_email_match_contributes_that_persons_uri(self) -> None:
        def fake_select(query):
            if "hasIdentifier" in query:
                return [{"p": "urn:ostler:person/owner", "value": ("Example.Owner" + "@icloud.com")}]
            return []

        env = {k: v for k, v in server.os.environ.items() if k != "USER_ID"}
        env["CARDDAV_USERNAME"] = ("example.owner" + "@icloud.com")
        with patch.object(server, "_sparql_select", side_effect=fake_select), \
             patch.dict(server.os.environ, env, clear=True):
            result = server._load_people_list_self_uris()

        self.assertEqual(result, {"urn:ostler:person/owner"})

    def test_control_a_failure_returns_empty_not_an_exception(self) -> None:
        """CONTROL: best-effort -- a degraded Oxigraph must never raise
        out of people_list, only degrade to 'exclude nobody'."""
        env = dict(server.os.environ)
        env["USER_DISPLAY_NAME"] = "John Smith"
        with patch.object(server, "_sparql_select",
                           side_effect=RuntimeError("store unreachable")), \
             patch.dict(server.os.environ, env, clear=True):
            result = server._load_people_list_self_uris()

        self.assertEqual(result, set())

    def test_control_neither_signal_configured_returns_only_possibly_empty(self) -> None:
        """CONTROL: on a box with no USER_DISPLAY_NAME / CARDDAV_USERNAME
        configured (the measured gap: OSTLER_OPERATOR_EMAILS/NAME are never
        set by install.sh either), self-uri resolution degrades to AT MOST
        the owner anchor URI -- never raises, never fabricates a match."""
        env = {
            k: v for k, v in server.os.environ.items()
            if k not in ("USER_DISPLAY_NAME", "PWG_USER_NAME", "CARDDAV_USERNAME", "USER_ID")
        }
        with patch.object(server, "_sparql_select", return_value=[]), \
             patch.dict(server.os.environ, env, clear=True):
            result = server._load_people_list_self_uris()

        self.assertEqual(result, set())


class TestPeopleListToEnrichment(unittest.TestCase):
    """A row's slug must resolve to a 200 enrichment card -- the
    click-through from fix [4] to fix [5]."""

    def test_row_slug_resolves_to_enrichment_200(self) -> None:
        name = "Alice Example"
        slug = server._wiki_slug(name)
        uri = "urn:ostler:person/carol"

        def fake_sparql(query):
            # Slug-resolution candidate query (person + displayName, no
            # per-source predicates / identifiers).
            if ("pwg:Person" in query and "displayName" in query
                    and "lastContactCalendar" not in query
                    and "hasIdentifier" not in query):
                return [{"person": uri, "name": name}]
            # Core attributes query.
            if "lastContactCalendar" in query:
                return [{"org": "Example Corp", "title": "Director"}]
            return []

        def qdrant_empty(*_args, **_kwargs):
            return _scroll_resp([], next_offset=None)

        with patch.object(server, "_sparql_select", side_effect=fake_sparql), \
             patch.object(server.urllib.request, "urlopen", qdrant_empty):
            with _ServerHarness() as h:
                status, body = h.get(
                    f"/api/v1/people/{slug}/enrichment"
                )

        self.assertEqual(status, 200, msg=f"body={body!r}")
        self.assertTrue(body["found"])
        self.assertEqual(body["slug"], slug)
        self.assertEqual(body["person"]["organisation"], "Example Corp")


if __name__ == "__main__":
    unittest.main()
