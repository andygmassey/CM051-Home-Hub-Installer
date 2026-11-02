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

DIGEST = "## About you\n- Name: Pat Doe\n- Family and close people: Pat Doe asked about cooking twice a week.\n\n## Next\n"


def _run(about):
    od._identity = lambda: {"user_id": "pat", "name": "Pat Doe", "emails": []}

    def sparql(q):
        if "urn:ostler:Fact" in q:
            return [{"about": about}]
        return []
    od._sparql = sparql
    return od.about_check(DIGEST)


def test_owner_fact_in_urn_user_form_is_the_owner():
    r = _run("urn:ostler:user/pat")
    assert r["items"] == 1 and r["not_owner"] == 0


def test_a_neighbours_fact_is_still_not_the_owner():
    assert _run("urn:ostler:person/sam-neighbour")["not_owner"] == 1
