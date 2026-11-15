"""walk 121: owner_digest_knows_the_owner FAILed '1 of 1 About-you entries come
from a fact about someone else' for "<Owner> asked about cooking twice a week",
a fact whose urn:ostler:about is urn:ostler:user/<id>, the owner. The probe's
owner set lacked that form. An owner fact passes; a neighbour's still fails.
Synthetic only."""
import importlib.util
import os

_p = os.path.join(os.path.dirname(__file__), "..", "scripts", "box_walk_probes", "lib", "owner_digest.py")
_s = importlib.util.spec_from_file_location("owner_digest_under_test", _p)
od = importlib.util.module_from_spec(_s)
_s.loader.exec_module(od)

DIGEST = "## About you\n- Name: Jane Doe\n- Family and close people: Jane Doe asked about cooking twice a week.\n\n## Next\n"


def _run(about):
    od._identity = lambda: {"user_id": "jane", "name": "Jane Doe", "emails": []}

    def sparql(q):
        if "urn:ostler:Fact" in q:
            return [{"about": about}]
        return []
    od._sparql = sparql
    return od.about_check(DIGEST)


def test_owner_fact_in_urn_user_form_is_the_owner():
    r = _run("urn:ostler:user/jane")
    assert r["items"] == 1 and r["not_owner"] == 0


def test_a_neighbours_fact_is_still_not_the_owner():
    assert _run("urn:ostler:person/john-neighbour")["not_owner"] == 1


def test_another_users_fact_is_not_the_owner():
    """owner_about_forms matches the owner's exact id, never any user/ URN."""
    assert _run("urn:ostler:user/john")["not_owner"] == 1
    assert _run("urn:ostler:user/jane2")["not_owner"] == 1
    assert _run("urn:ostler:user/")["not_owner"] == 1


def test_owner_forms_are_exact():
    assert od.owner_about_forms("jane") == ["urn:ostler:user/jane", "https://schema.ostler.ai/ontology#user_jane"]
