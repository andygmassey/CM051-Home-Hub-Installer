"""The walk's real-person chooser prefers a recent, well-described person with a
big compiled page. Rows are real-shaped (id, name, slug, wiki_url, recency, plus
role/email/phone/linkedin on some): NO count field. Synthetic names only."""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts", "box_walk_probes", "lib"))
import real_person_pick as rpp  # noqa: E402


def row(name, **kw):
    slug = name.lower().replace(" ", "-")
    d = {"id": "p-" + slug, "name": name, "slug": slug, "wiki_url": "/People/" + slug + "/", "recency": "2026-10-01"}
    d.update(kw)
    return d


def pick(rows, pages):
    return rpp.pick(json.dumps({"people": rows}), pages, "", [])[0]


PAGES = "10 ./index.md\n300 ./robbie-wang.md\n2500 ./lizzie-li.md\n900 ./wei-zhang.md\n"


def test_rich_recent_row_beats_a_sparse_more_recent_one():
    rows = [row("Robbie Wang"),                                   # most recent, sparse
            row("Lizzie Li", role="Founder", email="x@example.com")]
    assert pick(rows, PAGES)[0] == "Lizzie Li"


def test_largest_page_breaks_the_tie_among_rich_rows():
    rows = [row("Wei Zhang", role="CTO", phone="not-a-real-number"),
            row("Lizzie Li", role="Founder", linkedin="in/x")]
    assert pick(rows, PAGES)[0] == "Lizzie Li"   # 2500 bytes > 900


def test_one_attribute_is_not_rich_so_first_candidate_is_kept():
    rows = [row("Robbie Wang"), row("Lizzie Li", role="Founder")]
    assert pick(rows, PAGES)[0] == "Robbie Wang"


def test_rich_row_without_a_page_is_rejected():
    rows = [row("Nopage Person", role="a", email="b"), row("Robbie Wang")]
    assert pick(rows, PAGES)[0] == "Robbie Wang"


def test_bare_path_listing_still_parses():
    assert pick([row("Robbie Wang")], "index.md\nrobbie-wang.md\n")[0] == "Robbie Wang"
