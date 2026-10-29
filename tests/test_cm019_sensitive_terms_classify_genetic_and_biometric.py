#!/usr/bin/env python3
"""The vendored CM019 sensitive-term gate classifies genetic and biometric
data (board row 2471b, v1.0.119).

sensitive_terms.yaml carried six of the eight GDPR Art. 9(1) classes; genetic
and biometric data were missing, so a derived preference such as a DNA kit
or a fingerprint enrolment could be surfaced. This loads the SHIPPED
vendored derive/sensitive.py (and its yaml) and asserts:
  * every synthetic genetic example classifies as `genetic` and every
    biometric example as `biometric`, and none is surfaceable;
  * every term the Front Page list (sensitive_topics.py) names for those
    two classes is sensitive here too, so the two lists cannot drift apart;
  * ordinary controls stay unclassified.
Exit 0 pass, 1 fail, 2 CANNOT-RUN.
"""
import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SENS = os.path.join(ROOT, "vendor", "cm019_preferences", "services", "enrich", "src",
                    "derive", "sensitive.py")
TOPICS = os.path.join(ROOT, "vendor", "cm059_editor", "compiler", "sensitive_topics.py")
FAILS = []


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


try:
    sensitive = load("cm019_sensitive_under_test", SENS)
    sensitive.data()
    topics = load("cm059_sensitive_topics_under_test", TOPICS)
except Exception as exc:
    print("CANNOT-RUN: {}".format(exc))
    sys.exit(2)


def check(name, cond, detail=""):
    print(("  ok    " if cond else "  FAIL  ") + name + (("  -- " + detail) if detail and not cond else ""))
    if not cond:
        FAILS.append(name)


EXAMPLES = {
    "genetic": ["Genetic ancestry testing", "23andMe results", "DNA test kits",
                "genome sequencing", "BRCA screening"],
    "biometric": ["Fingerprint unlock enrolment", "Iris scan registration",
                  "Facial recognition", "Biometrics", "voiceprint login"],
}
FRONT_PAGE_CLASS = {"genetic": "genetic_data", "biometric": "biometric_data"}

for cat, examples in sorted(EXAMPLES.items()):
    for ex in examples:
        got = sensitive.sensitive_category(ex)
        check("{!r} classifies as {}".format(ex, cat), got == cat, repr(got))
        check("{!r} is not surfaceable".format(ex), not sensitive.surfaceable(ex))

for cat, cls in sorted(FRONT_PAGE_CLASS.items()):
    terms = [t for t in topics.ART9_CLASSES[cls] if not t.endswith("*")]
    # a stem is tested as the word it stands for when it is not one itself
    stem_word = {"gene therap": "gene therapy"}
    stems = [stem_word.get(t[:-1], t[:-1]) for t in topics.ART9_CLASSES[cls] if t.endswith("*")]
    for t in terms + stems:
        # sensitive here, in this class or an earlier one (gene THERAPY is
        # also health; either way it is never surfaced)
        got = sensitive.sensitive_category(t)
        check("Front Page {} term {!r} is sensitive here".format(cls, t),
              got is not None and not sensitive.surfaceable(t), repr(got))

for c in ["Trail running", "History podcasts", "Jazz piano", "Denim jackets"]:
    got = sensitive.sensitive_category(c)
    check("control {!r} is not classified".format(c), got is None, repr(got))

print("{} fail".format(len(FAILS)))
sys.exit(1 if FAILS else 0)
