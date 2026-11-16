"""I3 kept-promises eval. Scores detect_promises() against corpus.json.

Positive class = "broken" (the thing the brief surfaces). Precision and recall
over promise ids. Controls: an oracle scores 1.0/1.0; an empty detector scores
recall 0.0, so a silent detector cannot read as passing.
"""
import json
import pathlib

CORPUS = pathlib.Path(__file__).with_name("corpus.json")


def load_corpus(path=CORPUS):
    return json.loads(pathlib.Path(path).read_text())


def expected_labels(corpus):
    out = {}
    for t in corpus["threads"]:
        for p in t["promises"]:
            out[p["promise_id"]] = p["expected"]
    return out


def score(detected, corpus):
    """detected: {promise_id: status} with status in kept|broken|open."""
    expected = expected_labels(corpus)
    tp = fp = fn = 0
    for pid, exp in expected.items():
        got = detected.get(pid)
        if exp == "broken" and got == "broken":
            tp += 1
        elif exp != "broken" and got == "broken":
            fp += 1
        elif exp == "broken" and got != "broken":
            fn += 1
    precision = tp / (tp + fp) if (tp + fp) else 0.0
    recall = tp / (tp + fn) if (tp + fn) else 0.0
    return {"tp": tp, "fp": fp, "fn": fn, "precision": precision, "recall": recall}


def run(detect_promises):
    corpus = load_corpus()
    return score(detect_promises(corpus), corpus)
