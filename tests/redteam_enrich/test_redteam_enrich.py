"""Red-team attacks on the vendored enrichment look-up gate (synthetic data, network mocked)."""
import pytest
from conftest import STAMP, pref, run_batch, run_one

L1 = {"privacy_level": "L1", **STAMP}
L0 = {"privacy_level": "L0", **STAMP}


def sent(sink, needle):
    return [s for s in sink.strings() if needle in s]


# ---- positive controls: enrichment must be alive ----
@pytest.mark.asyncio
async def test_P01_L1_subject_is_looked_up(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("p1", "control-band-alpha", "music", **L1)])
    assert sent(sink, "control-band-alpha"), f"L1 music subject not looked up; calls={sink.calls}"


@pytest.mark.asyncio
async def test_P02_stamped_L0_subject_is_looked_up(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("p2", "control-book-beta", "book", **L0)])
    assert sent(sink, "control-book-beta"), f"stamped L0 book not looked up; calls={sink.calls}"


# ---- mixed records and spellings of the level ----
@pytest.mark.asyncio
async def test_A01_canonical_L1_plus_legacy_1_is_refused(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a1", "mixed-subject A01", "music", **L1, compartment_level=1)])
    assert not sent(sink, "mixed-subject A01"), f"legacy 1 beside L1 looked up; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A02_legacy_1_as_padded_string_is_refused(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a2", "mixed-subject A02", "music", **L1, compartment_level=" 1 ")])
    assert not sent(sink, "mixed-subject A02"), f"padded legacy 1 looked up; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A03_zero_width_space_in_level_is_refused(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a3", "mixed-subject A03", "music",
                               privacy_level="​L1", **STAMP)])
    assert not sent(sink, "mixed-subject A03"), f"zero-width level looked up; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A04_fullwidth_digit_level_is_refused(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a4", "mixed-subject A04", "music",
                               privacy_level="L１", **STAMP)])
    assert not sent(sink, "mixed-subject A04"), f"fullwidth L1 looked up; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A05_lowercase_L1_stamped_is_looked_up_control(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a5", "case-control A05", "music", privacy_level="l1", **STAMP)])
    assert sent(sink, "case-control A05"), f"lowercase l1 refused (over-refusal); calls={sink.calls}"


@pytest.mark.asyncio
async def test_A06_bool_level_and_bool_legacy_refused(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [
        pref("a6a", "bool-subject A06a", "music", privacy_level=True, **STAMP),
        pref("a6b", "bool-subject A06b", "music", **L1, compartment_level=True),
        pref("a6c", "bool-subject A06c", "music", **L1, compartment_level=2.0),
    ])
    assert not sent(sink, "bool-subject A06"), f"bool/float level looked up; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A07_unstamped_L0_refused_and_wrong_stamp_refused(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [
        pref("a7a", "unstamped-subject A07a", "book", privacy_level="L0"),
        pref("a7b", "wrong-stamp-subject A07b", "book", privacy_level="L0",
             privacyScale="Canonical-2026-10"),
    ])
    assert not sent(sink, "unstamped-subject A07a") and not sent(sink, "wrong-stamp-subject A07b"), \
        f"unstamped/wrong-stamp L0 looked up; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A08_legacy_zero_beside_stamped_L0_refused(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a8", "legacy-zero-subject A08", "book", **L0, compartment_level=0)])
    assert not sent(sink, "legacy-zero-subject A08"), f"legacy 0 beside L0 looked up; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A09_unlevelled_with_stamp_only_refused(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a9", "unlevelled-subject A09", "book", **STAMP)])
    assert not sent(sink, "unlevelled-subject A09"), f"unlevelled looked up; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A10_level_as_list_refused(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a10", "list-level-subject A10", "music", privacy_level=["L1"], **STAMP)])
    assert not sent(sink, "list-level-subject A10"), f"list-valued level looked up; calls={sink.calls}"


# ---- category spoofing and content ----
@pytest.mark.asyncio
async def test_A11_health_subject_labelled_music_is_refused(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a11", "metformin-doe A11", "music", **L1)])
    assert not sent(sink, "metformin-doe A11"), \
        f"health topic under category music sent to a look-up; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A12_health_vocabulary_term_labelled_music_is_refused(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a12", "diabetes", "music", **L1)])
    assert not sent(sink, "diabetes"), f"vocabulary health term under music sent; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A13_person_name_as_interest_topic_is_refused(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a13", "Jane Smith", "interest", **L1)])
    assert not sent(sink, "Jane Smith"), f"person name as interest topic sent; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A14_person_name_as_artist_is_refused(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a14", "Jane Smith", "artist", **L1)])
    assert not sent(sink, "Jane Smith"), f"person name as artist sent; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A15_author_field_person_name_is_not_sent(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a15", "doe-book-title", "book", **L1, author="Jane Smith")])
    assert not sent(sink, "Jane Smith"), f"author person name sent to openlibrary; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A16_place_category_address_is_refused(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a16", "Flat 3, 14 doe-road", "place", **L1)])
    assert not sent(sink, "doe-road"), f"street address under place sent; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A17_restaurant_area_home_location_is_not_sent(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a17", "doe-bistro", "food", **L1,
                               extra={"restaurant": "doe-bistro", "area": "doe-road, Springfield"})])
    assert not sent(sink, "doe-road"), f"area (location) sent to osm_cuisine; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A18_bookmark_url_with_owner_query_is_not_sent(svc_and_sink):
    svc, sink = svc_and_sink
    await run_one(svc, pref("a18", "doe-article", "bookmark", **L1,
                            extra={"url": "https://example.org/profile?owner=Jane_Example"}))
    assert not sent(sink, "owner=Jane_Example"), f"owner URL sent to url_fetcher; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A19_url_field_top_level_is_not_sent(svc_and_sink):
    svc, sink = svc_and_sink
    await run_one(svc, pref("a19", "doe-article", "page", **L1,
                            url="https://example.org/notes?owner=Jane_Example"))
    assert not sent(sink, "owner=Jane_Example"), f"top-level owner URL sent; calls={sink.calls}"


# ---- minors ----
@pytest.mark.asyncio
async def test_A20_minor_flag_string_yes_refused_control(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a20", "minor-subject A20", "book", **L1, about_minor="yes")])
    assert not sent(sink, "minor-subject A20"), f"about_minor='yes' looked up; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A21_minor_flag_in_extra_string_true_refused(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a21", "minor-subject A21", "book", **L1,
                               extra={"about_minor": "true"})])
    assert not sent(sink, "minor-subject A21"), f"extra.about_minor='true' looked up; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A22_minor_flag_under_other_key_refused(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a22", "minor-subject A22", "book", **L1, child=True)])
    assert not sent(sink, "minor-subject A22"), f"child=True flag looked up; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A23_minor_flag_when_extra_is_json_string_refused(svc_and_sink):
    svc, sink = svc_and_sink
    # run_one: enrich_preference (the gate itself). Batch would refuse on provenance first.
    await run_one(svc, {"id": "a23", "subject": "minor-subject A23", "category": "book",
                        "extra": '{"about_minor": true}', **L1})
    assert not sent(sink, "minor-subject A23"), f"JSON-string extra hides about_minor; calls={sink.calls}"


# ---- category exclusions and unicode in categories ----
@pytest.mark.asyncio
async def test_A24_fullwidth_and_zero_width_category_gets_no_client(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [
        pref("a24a", "fullwidth-subject A24a", "ｍｕｓｉｃ", **L1),
        pref("a24b", "ZeroWidth Subject A24b", "music​", **L1),
    ])
    assert not sent(sink, "fullwidth-subject A24a") and not sent(sink, "ZeroWidth Subject A24b"), \
        f"unicode-spoofed category reached a client; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A25_uppercase_health_category_excluded(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a25", "health-subject A25", "Health", **L1)])
    assert not sent(sink, "health-subject A25"), f"uppercase health category sent; calls={sink.calls}"


@pytest.mark.asyncio
async def test_A26_dietary_category_excluded_control(svc_and_sink):
    svc, sink = svc_and_sink
    await run_batch(svc, [pref("a26", "diet-subject A26", "dietary", **L1)])
    assert not sent(sink, "diet-subject A26"), f"dietary sent; calls={sink.calls}"
