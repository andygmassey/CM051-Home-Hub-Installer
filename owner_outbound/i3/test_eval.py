"""I3 eval controls. RED for the detector: owner_outbound.i3.detector does not exist yet."""
from owner_outbound.i3.eval import load_corpus, expected_labels, score, run
from owner_outbound.i3.detector import detect_promises


def test_oracle_scores_perfect():
    corpus = load_corpus()
    oracle = expected_labels(corpus)
    s = score(oracle, corpus)
    assert s["precision"] == 1.0 and s["recall"] == 1.0


def test_empty_detector_recall_is_zero_not_pass():
    corpus = load_corpus()
    s = score({}, corpus)
    assert s["recall"] == 0.0


def test_corpus_is_synthetic_and_has_each_class():
    labels = set(expected_labels(load_corpus()).values())
    assert {"kept", "broken", "open"} <= labels


def test_real_detector_precision_and_recall():
    s = run(detect_promises)
    assert s["precision"] >= 0.9
    assert s["recall"] >= 0.9
