"""Z2 P0-1 regression: pwg-email-ingest Person IRI shape + RDF namespace.

The CLI used to emit Person IRIs under ``urn:pwg:person/<email>`` and
declare ``PREFIX pwg: <urn:pwg:>``. The canonical PWG People graph
(written by ``vendor/ostler_fda/pwg_ingest.py`` from iMessage,
WhatsApp, and Mail) uses ``https://pwg.dev/ontology#`` as its
namespace and ``https://pwg.dev/ontology#person_<uuid5>`` as its
Person IRI shape, where the uuid5 is derived from
``https://pwg.dev/person/<clean>`` under ``uuid.NAMESPACE_URL``.

Both axes were wrong before, so emails ingested by this CLI never
joined the Person graph the FDA path was building -- the wiki Email
column came up blank for every customer.

This test pins the canonical shape so a future refactor that drifts
back to ``urn:pwg:`` is caught before it ships.

Synthetic fixtures only -- never a real email address.
"""
from __future__ import annotations

import importlib.util
import sys
import unittest
import uuid
from pathlib import Path


_VENDOR_ROOT = Path(__file__).resolve().parent.parent
_CLI_PATH = _VENDOR_ROOT / "src" / "cli.py"


def _load_cli_module():
    """Load src.cli without importing the full src package.

    The package's ``src.__init__`` chain pulls in the parsers
    sub-package, which requires beautifulsoup4 at import time. Those
    runtime deps are not installed in the bare test environment, so
    we side-load cli.py directly and stub the two relative imports
    it needs (``src.filters`` + ``src.parsers.fast_mbox_parser``).
    The Person-IRI / namespace helpers under test don't touch either
    of those stubs.
    """
    import types

    # Stub src package + the two modules cli.py imports at module
    # load time. The helpers under test never call into the stubs.
    src_pkg = types.ModuleType("src")
    src_pkg.__path__ = [str(_VENDOR_ROOT / "src")]
    sys.modules.setdefault("src", src_pkg)

    filters_stub = types.ModuleType("src.filters")
    filters_stub.EmailFilter = object  # placeholder -- never instantiated here
    sys.modules.setdefault("src.filters", filters_stub)

    parsers_pkg = types.ModuleType("src.parsers")
    parsers_pkg.__path__ = [str(_VENDOR_ROOT / "src" / "parsers")]
    sys.modules.setdefault("src.parsers", parsers_pkg)

    fast_parser_stub = types.ModuleType("src.parsers.fast_mbox_parser")
    fast_parser_stub.FastEmail = object
    fast_parser_stub.FastMboxParser = object
    sys.modules.setdefault("src.parsers.fast_mbox_parser", fast_parser_stub)

    spec = importlib.util.spec_from_file_location("src.cli", _CLI_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["src.cli"] = module
    spec.loader.exec_module(module)
    return module


class TestPWGNamespace(unittest.TestCase):
    """Pin the canonical PWG namespace + Person IRI shape."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.cli = _load_cli_module()

    def test_pwg_ns_constant_is_canonical(self) -> None:
        self.assertEqual(self.cli.PWG_NS, "https://pwg.dev/ontology#")

    def test_person_iri_uses_canonical_namespace(self) -> None:
        iri = self.cli._safe_person_iri("alice@example.com")
        self.assertTrue(
            iri.startswith("https://pwg.dev/ontology#person_"),
            f"IRI does not use canonical PWG namespace: {iri!r}",
        )

    def test_person_iri_is_uuid5_derived(self) -> None:
        iri = self.cli._safe_person_iri("alice@example.com")
        suffix = iri.removeprefix("https://pwg.dev/ontology#person_")
        parsed = uuid.UUID(suffix)
        self.assertEqual(parsed.version, 5, "Person IRI must be uuid5-derived")

        # Independently recompute the expected uuid5 using the canonical
        # writer's recipe (mirrors pwg_ingest._person_id_from_identifier).
        expected = str(
            uuid.uuid5(uuid.NAMESPACE_URL, "https://pwg.dev/person/alice@example.com")
        )
        self.assertEqual(suffix, expected)

    def test_person_iri_is_deterministic(self) -> None:
        a = self.cli._safe_person_iri("alice@example.com")
        b = self.cli._safe_person_iri("alice@example.com")
        self.assertEqual(a, b)

    def test_person_iri_is_case_insensitive(self) -> None:
        lower = self.cli._safe_person_iri("alice@example.com")
        upper = self.cli._safe_person_iri("ALICE@EXAMPLE.COM")
        self.assertEqual(
            lower,
            upper,
            "Email casing must not produce different Person IRIs",
        )

    def test_person_iri_strips_whitespace(self) -> None:
        bare = self.cli._safe_person_iri("alice@example.com")
        padded = self.cli._safe_person_iri("  alice@example.com  ")
        self.assertEqual(bare, padded)

    def test_distinct_emails_produce_distinct_iris(self) -> None:
        a = self.cli._safe_person_iri("alice@example.com")
        b = self.cli._safe_person_iri("bob@example.com")
        self.assertNotEqual(a, b)

    def test_sparql_upsert_declares_canonical_prefix(self) -> None:
        """The PREFIX line in the SPARQL UPDATE must match PWG_NS.

        A drift between the IRI shape and the PREFIX would re-create
        the original bug at the query level -- predicates like
        ``pwg:lastContactEmail`` would expand under the wrong base
        and never match what the rest of the graph expects.
        """
        iri = self.cli._safe_person_iri("alice@example.com")
        query = self.cli._build_upsert(
            person_iri=iri,
            email="alice@example.com",
            name="Alice Example",
            last_contact_iso="2026-01-01T12:00:00+00:00",
        )
        self.assertIn("PREFIX pwg: <https://pwg.dev/ontology#>", query)
        self.assertNotIn("urn:pwg:", query)

    def test_clean_email_helper_matches_canonical_recipe(self) -> None:
        """Mirror of pwg_ingest._person_id_from_identifier semantics."""
        self.assertEqual(
            self.cli._clean_email_for_iri("  ALICE@example.com  "),
            "alice@example.com",
        )


if __name__ == "__main__":
    unittest.main()
