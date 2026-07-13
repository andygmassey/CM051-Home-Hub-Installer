#!/usr/bin/env python3
"""Vendor-BEHAVIOUR gate -- prove the load-bearing divergence GRAFTS still FUNCTION.

Why this exists (consolidation plan rec A3, 2026-07): the freshness gate
(scripts/verify_vendor_fresh.sh) proves each vendored tree matches
source@pinned_sha + divergence patch BYTE-wise. It cannot prove the grafts
still BEHAVE: a re-vendor whose patch "applies cleanly" onto moved source can
still neutralise a graft (hunk lands in dead code, a renamed function stops
being called, a guard clause inverts). The F&F cut proved the class: an
artefact that LOOKED right shipped broken, and the miss surfaced at box-walk
-- hours -- instead of at re-vendor time -- seconds.

This gate runs GOLDEN CASES against the vendored code itself, in-process,
with the SPARQL/HTTP seams stubbed (no Oxigraph/Ollama needed):

  A. cm041 resolver / contact_syncer dedupe grafts (the #657 family):
     - big-bang same-run dedupe: a person created mid-run is visible to later
       rows via register_person() (the x11 one-shot dupe -> 1);
     - org-conflict guard: two real people sharing a name stay separate
       (two real people sharing an exact name);
     - same-name + same-org still merges (same-name+same-org x4 -> 1);
     - shared-email guard (a2b0a25): a shareable identifier (email/phone) is
       NOT a merge signal when display names diverge (a mother and a spouse sharing
       a family email address stay two people) -- plus the merge control (same email + same name
       DOES merge) so a broken seam cannot pass vacuously;
     - unique identifiers (icloud_contact_uid) stay always-trusted;
     - LinkedIn hard blocker: two different linkedin_urls never fuzzy-merge;
     - BW-1 normalisation goldens (E.164 phones, lowercased emails);
     - register_person() is WIRED into every importer create-new branch
       (AST-level: a dropped call site = the exact #657 regression).

  B. cm048_pipeline grafts:
     - ollama_client qwen3.x JSON-mode skip (format:json degenerates qwen to
       "{}"): behavioural, via a stubbed httpx capturing the real payload;
     - num_ctx / num_predict pinned (the silent-truncation -> "{}" class);
     - provenance.py present and parseable (vendor manifest names it).

  C. ostler_fda / pwg_ingest grafts:
     - the graft FILES parse and their entry points exist (apple_mail,
       dedupe_merge, extract_all, universal_import, pwg_ingest);
     - dedupe_merge RULE 1 mechanics behaviourally: WhatsApp-JID phone
       canonicalisation and the union-find collision fold.

Dependencies: httpx + phonenumbers (the vendored resolver's own deps) --
scripts/verify_vendor_behaviour.sh bootstraps them if absent. Runs green
today against the current vendored trees; a re-vendor that drops any graft
turns a check RED and names it.

Exit 0 = all grafts behave. Exit 1 = at least one graft dropped/regressed.
"""

from __future__ import annotations

import ast
import importlib.util
import sys
import types
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
VENDOR = REPO / "vendor"

sys.path.insert(0, str(VENDOR / "cm041"))

RESULTS: list[tuple[bool, str]] = []


def check(name, fn) -> None:
    try:
        fn()
    except AssertionError as exc:
        RESULTS.append((False, name))
        print(f"  FAIL  {name}\n        {exc}", file=sys.stderr)
    except Exception as exc:  # noqa: BLE001 -- a crash is a failed check, not a crash of the gate
        RESULTS.append((False, name))
        print(
            f"  FAIL  {name}\n        unexpected {type(exc).__name__}: {exc}",
            file=sys.stderr,
        )
    else:
        RESULTS.append((True, name))
        print(f"  PASS  {name}")


# --------------------------------------------------------------------------
# Section A -- cm041 resolver / contact_syncer dedupe grafts
# --------------------------------------------------------------------------

def _resolver(candidates=None, ident_map=None, display_names=None):
    """Vendored IdentityResolver with ONLY the data-access seams stubbed.

    The behaviour under test (_resolve_tiers, _identifier_match_trustworthy,
    _fuzzy_match, register_person) is the REAL vendored code. We stub the two
    narrow SPARQL read seams and inject the in-memory fuzzy index directly.
    Expect-merge and expect-decline goldens are paired on the same seams, so
    a renamed/broken seam fails the merge control rather than passing the
    decline cases vacuously.
    """
    from identity_resolver.resolver import IdentityResolver

    for seam in (
        "find_by_identifier",
        "_person_display_name",
        "_fuzzy_match",
        "register_person",
    ):
        assert hasattr(IdentityResolver, seam), (
            f"resolver seam '{seam}' missing -- the re-vendor renamed the "
            "surface this gate stubs; re-point the gate at the new seam"
        )

    r = IdentityResolver("http://vendor-behaviour-gate.invalid:7878")
    r._fuzzy_candidates = list(candidates or [])
    imap = dict(ident_map or {})
    names = dict(display_names or {})
    r.find_by_identifier = lambda id_type, id_value: imap.get((id_type, id_value))
    r._person_display_name = lambda uri: names.get(uri)
    return r


def _identity(**kwargs):
    from identity_resolver.models import PersonIdentity

    return PersonIdentity(**kwargs)


def t_same_run_dedupe_via_register_person():
    """#657 golden: one LinkedIn contact imported twice in ONE big-bang run -> 1 node.

    The graft: after creating a new person the importer calls
    register_person(), so later rows in the SAME run fuzzy-match against it.
    Unwired, every LinkedIn-scale one-shot import re-creates the person
    (x11 duplicate nodes for one LinkedIn contact on the .140 walk).
    """
    r = _resolver(candidates=[])
    first = r.resolve(
        _identity(display_name="Taylor Quince", organization="Quince Analytics"),
        use_fuzzy=True,
    )
    assert first.match_type == "new", f"empty graph should yield new, got {first}"

    r.register_person("urn:gate:quince-1", "Taylor Quince", "Quince Analytics")

    second = r.resolve(
        _identity(display_name="Taylor Quince", organization="Quince Analytics"),
        use_fuzzy=True,
    )
    assert second.person_uri == "urn:gate:quince-1" and second.match_type == "fuzzy_name", (
        "same-run dedupe BROKEN (the #657 class): a person registered mid-run "
        f"was not matched by a later identical row -- got {second.match_type}/"
        f"{second.person_uri}"
    )


def t_org_conflict_guard_keeps_stuart_baileys_apart():
    """Golden: two REAL people who share an exact name at different employers
    must NOT merge (the wrongly-auto-merged same-name pair caught in the executed
    1,004)."""
    r = _resolver(
        candidates=[
            {"person": "urn:gate:rowan-1", "name": "Rowan Ferris",
             "org": "Acme Widgets", "linkedinUrl": None},
        ]
    )
    res = r.resolve(
        _identity(display_name="Rowan Ferris", organization="Zenith Bank"),
        use_fuzzy=True,
    )
    assert res.match_type == "new", (
        "org-conflict guard DROPPED: same-name candidates with CONFLICTING "
        f"orgs must stay separate people, got {res.match_type} -> {res.person_uri}"
    )


def t_same_name_same_org_still_merges():
    """Merge control for the org guard: the same name at the SAME org twice -> 1 node.
    If this fails alongside the same-name golden, the fuzzy tier is broken, not
    the guard."""
    r = _resolver(
        candidates=[
            {"person": "urn:gate:casey-1", "name": "Casey Wong",
             "org": "Coral Bank", "linkedinUrl": None},
        ]
    )
    res = r.resolve(
        _identity(display_name="Casey Wong", organization="Coral Bank"),
        use_fuzzy=True,
    )
    assert res.person_uri == "urn:gate:casey-1", (
        f"same-name+same-org must merge, got {res.match_type}/{res.person_uri}"
    )


def t_shared_email_is_not_a_merge_signal_when_names_diverge():
    """a2b0a25 golden: the operator's mother and spouse share a family
    email (the a2b0a25 deceased-spouse / reused-address class). A shareable identifier with DIVERGENT display names must decline
    the match (create a recoverable duplicate), never irreversibly merge."""
    shared = "family.shared@example.com"
    r = _resolver(
        ident_map={("email", shared): "urn:gate:spouse-1"},
        display_names={"urn:gate:spouse-1": "Eleanor Rowe"},
    )
    res = r.resolve(
        _identity(display_name="Margaret Rowe", emails=[shared]),
        use_fuzzy=False,
    )
    assert res.match_type == "new", (
        "shared-email guard DROPPED: divergent-name email match must NOT "
        f"merge (mother != spouse), got {res.match_type} -> {res.person_uri}"
    )


def t_shared_email_with_matching_name_does_merge():
    """Merge control for the email guard (same seams as the shared-email decline
    golden): same email AND same display name = Tier-1 exact merge. Proves
    the stubbed seams are live, so the decline golden cannot pass vacuously."""
    r = _resolver(
        ident_map={("email", "spouse.own@example.com"): "urn:gate:spouse-2"},
        display_names={"urn:gate:spouse-2": "Eleanor Rowe"},
    )
    res = r.resolve(
        _identity(display_name="Eleanor Rowe", emails=["spouse.own@example.com"]),
        use_fuzzy=False,
    )
    assert res.person_uri == "urn:gate:spouse-2" and res.match_type == "exact_identifier", (
        f"same-email+same-name must Tier-1 merge, got {res.match_type}/{res.person_uri}"
    )


def t_unique_identifier_always_trusted():
    """icloud_contact_uid is unique-by-construction: it merges even when the
    display names differ (a renamed contact is still the same person)."""
    r = _resolver(
        ident_map={("icloud_contact_uid", "ABC-UID-123"): "urn:gate:renamed-1"},
        display_names={"urn:gate:renamed-1": "Old Name"},
    )
    res = r.resolve(
        _identity(display_name="Completely New Name", icloud_uid="ABC-UID-123"),
        use_fuzzy=False,
    )
    assert res.person_uri == "urn:gate:renamed-1", (
        f"unique-identifier trust DROPPED: icloud UID match must merge, got {res.match_type}"
    )


def t_linkedin_url_hard_blocker():
    """Two different LinkedIn profiles = two different people, regardless of
    name similarity."""
    r = _resolver(
        candidates=[
            {"person": "urn:gate:sam-1", "name": "Sam Smith", "org": None,
             "linkedinUrl": "https://linkedin.com/in/samsmith-1"},
        ]
    )
    res = r.resolve(
        _identity(
            display_name="Sam Smith",
            linkedin_url="https://linkedin.com/in/samsmith-2",
        ),
        use_fuzzy=True,
    )
    assert res.match_type == "new", (
        "LinkedIn hard blocker DROPPED: differing linkedin_urls must never "
        f"fuzzy-merge, got {res.match_type} -> {res.person_uri}"
    )


def t_bw1_normalisation_goldens():
    """BW-1 graft: phones fold to one E.164 form (so Contacts '9123 4567' and
    WhatsApp '+85291234567' collide under RULE 1); emails lowercase+strip."""
    from identity_resolver.normalise import normalise_email, normalise_phone

    assert normalise_phone("9123 4567", 852) == "+85291234567", (
        f"local HK number must fold to E.164, got {normalise_phone('9123 4567', 852)!r}"
    )
    assert normalise_phone("+852 9123-4567", 852) == "+85291234567"
    assert normalise_email("  Foo@BAR.com ") == "foo@bar.com"


def t_register_person_wired_into_every_importer():
    """#657 wiring: every importer create-new branch must call
    register_person() -- the graft was DEFINED but had ZERO callers when the
    .140 walk produced x11 duplicates of a single contact. AST-level so a re-vendor that drops a
    call site (not just the definition) goes RED."""
    importer_files = [
        "syncer.py",
        "linkedin_connections.py",
        "facebook_friends.py",
        "linkedin_messages.py",
        "instagram_social.py",
    ]
    missing = []
    for fname in importer_files:
        path = VENDOR / "cm041" / "contact_syncer" / fname
        assert path.is_file(), f"vendored importer missing on disk: {path}"
        tree = ast.parse(path.read_text(encoding="utf-8"))
        called = any(
            isinstance(node, ast.Call)
            and (
                (isinstance(node.func, ast.Attribute) and node.func.attr == "register_person")
                or (isinstance(node.func, ast.Name) and node.func.id == "register_person")
            )
            for node in ast.walk(tree)
        )
        if not called:
            missing.append(fname)
    assert not missing, (
        "register_person call DROPPED from importer create-new branch(es): "
        f"{missing} -- one-shot imports will re-create duplicates (#657)"
    )


# --------------------------------------------------------------------------
# Section B -- cm048_pipeline grafts
# --------------------------------------------------------------------------

def _load_module(alias: str, path: Path):
    spec = importlib.util.spec_from_file_location(alias, path)
    assert spec and spec.loader, f"cannot load {path}"
    mod = importlib.util.module_from_spec(spec)
    # dataclasses resolves cls.__module__ via sys.modules at decoration time,
    # so the module must be registered BEFORE exec.
    sys.modules[alias] = mod
    spec.loader.exec_module(mod)
    return mod


class _CapturingHttpx(types.SimpleNamespace):
    """Minimal httpx stand-in capturing the JSON payload generate() posts."""

    def __init__(self):
        super().__init__()
        self.captured: list[dict] = []
        outer = self

        class _Resp:
            @staticmethod
            def raise_for_status():
                return None

            @staticmethod
            def json():
                return {"response": "ok"}

        class _Client:
            def __init__(self, **kwargs):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def post(self, url, json=None, **kwargs):
                outer.captured.append({"url": url, "payload": json})
                return _Resp()

        self.Client = _Client
        self.HTTPTransport = lambda **kwargs: None


def _ollama_client_and_captures():
    mod = _load_module(
        "cm051_gate_cm048_ollama_client",
        VENDOR / "cm048_pipeline" / "src" / "ollama_client.py",
    )
    fake = _CapturingHttpx()
    mod.httpx = fake
    client_cls = getattr(mod, "OllamaClient", None)
    if client_cls is None:  # renamed upstream -- find any class with generate()
        client_cls = next(
            (
                obj
                for obj in vars(mod).values()
                if isinstance(obj, type) and hasattr(obj, "generate")
            ),
            None,
        )
    assert client_cls is not None, "no client class with generate() in vendored ollama_client.py"
    return client_cls(), fake


def t_cm048_qwen_json_mode_skipped():
    """Graft: qwen3.x degenerates to empty/'{}' under native format:json, so
    the vendored client must NOT send it for qwen3* models (recut #2 marker,
    behaviourally)."""
    client, fake = _ollama_client_and_captures()
    client.generate("qwen3.5:9b", "extract facts", format_json=True)
    payload = fake.captured[-1]["payload"]
    assert "format" not in payload, (
        "qwen3.x JSON-mode skip DROPPED: payload carries format="
        f"{payload.get('format')!r} -- extraction degenerates to '{{}}'"
    )


def t_cm048_non_qwen_keeps_json_mode():
    """Control: non-qwen models DO get native JSON mode -- proves the skip is
    the qwen guard, not format:json support removed wholesale."""
    client, fake = _ollama_client_and_captures()
    client.generate("llama3:8b", "extract facts", format_json=True)
    payload = fake.captured[-1]["payload"]
    assert payload.get("format") == "json", (
        f"non-qwen format:json lost: payload format={payload.get('format')!r}"
    )


def t_cm048_context_window_pinned():
    """Graft: without num_ctx Ollama silently truncates long transcripts to
    its small default window (the one-token #118 class). num_predict=-1 =
    generate until done."""
    client, fake = _ollama_client_and_captures()
    client.generate("qwen3.5:9b", "long transcript " * 100)
    options = fake.captured[-1]["payload"].get("options", {})
    assert options.get("num_ctx", 0) >= 32768, (
        f"num_ctx pin DROPPED: options={options!r} -- long transcripts truncate to '{{}}'"
    )
    assert options.get("num_predict") == -1, f"num_predict=-1 lost: options={options!r}"


def t_cm048_provenance_module_present():
    """The vendor manifest names provenance.py as required by the pipeline;
    a fresh clone re-vendor without it crashes conversation processing."""
    path = VENDOR / "cm048_pipeline" / "src" / "provenance.py"
    assert path.is_file(), f"cm048 provenance.py missing: {path}"
    ast.parse(path.read_text(encoding="utf-8"))


# --------------------------------------------------------------------------
# Section C -- ostler_fda / pwg_ingest grafts
# --------------------------------------------------------------------------

def t_fda_graft_files_parse_and_export_entry_points():
    """The ostler_fda grafts (apple_mail backfill, dedupe_merge, extract_all,
    universal_import + the pwg_ingest ingest legs) must exist, parse, and
    export the entry points install.sh invokes."""
    expected = {
        "pwg_ingest.py": {
            "ingest_imessage",
            "ingest_whatsapp",
            "ingest_calendar",
            "ingest_mail_contacts",
            "ingest_browser_history",
        },
        "apple_mail.py": {"extract_messages"},
        "apple_mail_mbox.py": set(),
        "dedupe_merge.py": {"find_collisions", "run"},
        "extract_all.py": set(),
        "universal_import.py": set(),
    }
    problems = []
    for fname, symbols in expected.items():
        path = VENDOR / "ostler_fda" / fname
        if not path.is_file():
            problems.append(f"{fname}: file missing")
            continue
        tree = ast.parse(path.read_text(encoding="utf-8"))
        defined = {
            node.name
            for node in ast.walk(tree)
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))
        }
        lost = symbols - defined
        if lost:
            problems.append(f"{fname}: entry point(s) dropped: {sorted(lost)}")
    assert not problems, "; ".join(problems)


def _dedupe_merge_module():
    return _load_module(
        "cm051_gate_fda_dedupe_merge", VENDOR / "ostler_fda" / "dedupe_merge.py"
    )


def t_fda_dedupe_merge_rule1_keys():
    """RULE 1 (locked): shared exact email/phone ALWAYS merges; social handles
    are name-fuzzy signals only, never exact-merge keys."""
    mod = _dedupe_merge_module()
    keys = set(getattr(mod, "EXACT_KEY_TYPES", ()))
    assert keys == {"email", "phone"}, (
        f"RULE 1 exact-key slate drifted: {sorted(keys)} (expected email+phone only)"
    )


def t_fda_dedupe_merge_whatsapp_jid_canonicalisation():
    """Graft: a WhatsApp JID must collide with the same E.164 number written
    by Contacts/iMessage (the 'duplicate +number' rows)."""
    mod = _dedupe_merge_module()
    assert mod._canonical_phone("85291234567@s.whatsapp.net") == "+85291234567"
    assert mod._canonical_phone("+85291234567") == "+85291234567"
    # Opaque / non-phone values must pass through unchanged.
    assert mod._canonical_phone("not-a-number@lid") == "not-a-number@lid"


def t_fda_dedupe_merge_union_find_folds_transitively():
    """Graft: A~B on a phone and B~C on an email must fold A,B,C into ONE
    component with a deterministic (lexicographically-smallest) canonical."""
    mod = _dedupe_merge_module()
    collisions = {
        ("phone", "+85291234567"): ["urn:gate:p-a", "urn:gate:p-b"],
        ("email", "shared@example.com"): ["urn:gate:p-b", "urn:gate:p-c"],
    }
    comps = mod._components(collisions)
    assert len(comps) == 1, f"expected ONE folded component, got {len(comps)}: {comps}"
    canonical, members = next(iter(comps.items()))
    assert canonical == "urn:gate:p-a", f"canonical must be lexicographic min, got {canonical}"
    assert members == {"urn:gate:p-a", "urn:gate:p-b", "urn:gate:p-c"}, (
        f"transitive fold incomplete: {members}"
    )


# --------------------------------------------------------------------------

def main() -> int:
    print("=== Vendor-BEHAVIOUR gate (load-bearing grafts must FUNCTION) ===")
    print(f"vendor root: {VENDOR}")
    print()
    print("-- cm041 resolver / contact_syncer dedupe grafts --")
    check("same-run dedupe via register_person (one-shot dupe -> 1)", t_same_run_dedupe_via_register_person)
    check("org-conflict guard (same-name pair stays 2)", t_org_conflict_guard_keeps_stuart_baileys_apart)
    check("same-name+same-org merges (same-org pair -> 1)", t_same_name_same_org_still_merges)
    check("shared-email guard (mother != spouse)", t_shared_email_is_not_a_merge_signal_when_names_diverge)
    check("shared-email merge control (same name DOES merge)", t_shared_email_with_matching_name_does_merge)
    check("unique identifier (icloud UID) always trusted", t_unique_identifier_always_trusted)
    check("LinkedIn different-URL hard blocker", t_linkedin_url_hard_blocker)
    check("BW-1 phone/email normalisation goldens", t_bw1_normalisation_goldens)
    check("register_person wired in all importer create-new branches", t_register_person_wired_into_every_importer)
    print()
    print("-- cm048_pipeline grafts --")
    check("qwen3.x native JSON mode skipped", t_cm048_qwen_json_mode_skipped)
    check("non-qwen keeps native JSON mode (control)", t_cm048_non_qwen_keeps_json_mode)
    check("num_ctx/num_predict pinned (no silent truncation)", t_cm048_context_window_pinned)
    check("provenance.py present + parses", t_cm048_provenance_module_present)
    print()
    print("-- ostler_fda / pwg_ingest grafts --")
    check("graft files parse + entry points exported", t_fda_graft_files_parse_and_export_entry_points)
    check("RULE 1 exact-key slate (email+phone)", t_fda_dedupe_merge_rule1_keys)
    check("WhatsApp JID phone canonicalisation", t_fda_dedupe_merge_whatsapp_jid_canonicalisation)
    check("union-find transitive collision fold", t_fda_dedupe_merge_union_find_folds_transitively)

    passed = sum(1 for ok, _ in RESULTS if ok)
    failed = len(RESULTS) - passed
    print()
    print(f"=== Verdict: {passed} pass / {failed} fail ===")
    if failed:
        print(
            "BEHAVIOUR GATE RED -- a load-bearing graft was dropped or "
            "regressed by a re-vendor. Do NOT cut; re-graft (scripts/"
            "sync_vendor.sh <tree>) and re-run.",
            file=sys.stderr,
        )
        return 1
    print("BEHAVIOUR GATE GREEN -- every load-bearing graft still functions.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
