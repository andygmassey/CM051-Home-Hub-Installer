"""walk #24: at thousands of people a real slug can carry a disambiguation
suffix. The chooser passes the API slug; the probe matches on the href slug.
Synthetic names only."""
import json
import os
import sys

_L = os.path.join(os.path.dirname(__file__), "..", "scripts", "box_walk_probes", "lib")
sys.path.insert(0, _L)
import hub_screens as hs  # noqa: E402
import real_person_pick as rpp  # noqa: E402

ROW = {"id": "p1", "name": "Robbie Wang", "slug": "robbie-wang-2", "wiki_url": "/People/robbie-wang-2/",
       "recency": "2026-10-01"}
PAGES = "10 ./index.md\n300 ./robbie-wang-2.md\n"


def test_picker_uses_the_api_slug_when_it_carries_a_suffix():
    ch, _ = rpp.pick(json.dumps({"people": [ROW]}), PAGES, "", [])
    assert ch and ch[0] == "Robbie Wang" and ch[2] == "robbie-wang-2"


def test_picker_still_falls_back_to_the_name_slug():
    row = dict(ROW, slug="")
    ch, _ = rpp.pick(json.dumps({"people": [row]}), "300 ./robbie-wang.md\n", "", [])
    assert ch and ch[2] == "robbie-wang"


def test_slug_selector_matches_the_suffixed_href_and_not_the_name_slug_one():
    sel = hs.slug_link_selector("robbie-wang-2")
    assert '/People/robbie-wang-2/"' in sel
    # the name-derived selector cannot match the suffixed href: the defect
    assert '/People/robbie-wang/"' in hs.person_link_selector("Robbie Wang")
    assert '/People/robbie-wang/"' not in sel


def test_slug_selector_refuses_an_empty_slug():
    assert hs.slug_link_selector("") is None and hs.slug_link_selector(None) is None


def test_link_fingerprint_is_hash_only():
    fp = hs.link_fingerprint(["/People/robbie-wang-2/", "/People/lizzie-li/"])
    assert len(fp) == 8 and "robbie" not in fp and hs.link_fingerprint([]) == ""
    assert fp == hs.link_fingerprint(["/People/lizzie-li/", "/People/robbie-wang-2/"])


if __name__ == "__main__":
    n = 0
    for k, v in sorted(globals().items()):
        if k.startswith("test_") and callable(v):
            v()
            n += 1
    print(f"{n} passed")
