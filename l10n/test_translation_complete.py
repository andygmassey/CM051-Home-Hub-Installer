#!/usr/bin/env python3
"""Completeness gate: every customer-visible string ships translated in every
shipped language, except legal wording (English by rule until reviewed).

`ostler_l10n.py check` only PRINTS coverage; a key that was never translated
renders English and passes it. This gate fails instead. A key FAILS in a
language when
  - it is absent from that language's catalogue (renders English), or
  - its value is identical to the English and the English is prose (three or
    more Latin words).
`english_by_design.tsv` (lang or *, catalogue, key, REASON) exempts a key that
is English on purpose (a name, a token), absent or not.
A key is EXEMPT when it is legal (`legal_patterns` / `legal_text_patterns` in
config.yaml, via the tool's own `is_legal`) or listed in `keep_english`.

Run:  python3 l10n/test_translation_complete.py         (exit 1 on any gap)
      python3 -m pytest l10n/test_translation_complete.py
Every run prints what it EXAMINED, so a zero denominator cannot read as PASS.
"""
import csv
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ostler_l10n as L  # noqa: E402

ALLOW = os.path.join(HERE, "english_by_design.tsv")
# placeholders, tags and entities are not words
_STRIP = re.compile(r"\$\{[^}]*\}|\{[^}]*\}|%[0-9$]*[@sdf]|<[^>]+>|&[a-z#0-9]+;|https?://\S+|\S+@\S+")
_WORD = re.compile(r"[A-Za-z]{2,}")
SPELLING_ONLY = {"en-US"}  # an en-US value equal to en-GB is correct


_CODE = re.compile(r"[/=*&|\\`]|--|^\s*(git|cd|bash|curl|tar|cp|mkdir|docker|python3?|pwg-|ostler-)\b")


def prose(s):
    """Three or more words of text, and not a command line or a path."""
    s = s or ""
    if _CODE.search(s):
        return False
    return len(_WORD.findall(_STRIP.sub(" ", s))) >= 3


def load_allow():
    out = {}
    if not os.path.exists(ALLOW):
        return out
    with open(ALLOW, encoding="utf-8") as f:
        for row in csv.reader(f, delimiter="\t"):
            if not row or row[0].startswith("#") or row[0] == "lang":
                continue
            if len(row) < 4 or not row[3].strip():
                raise SystemExit(f"english_by_design.tsv: row needs lang, catalogue, key and a REASON: {row}")
            out[(row[0], row[1], row[2])] = row[3]
    return out


def gaps(cfg, allow=None):
    """Return (failures, examined, exempt_legal)."""
    allow = load_allow() if allow is None else allow
    keep = set(cfg.get("keep_english", []))
    fails, examined, legal = [], 0, set()
    for c in L.catalogues(cfg):
        units = list(c.units())
        for lang in cfg["languages"]:
            if lang in SPELLING_ONLY:
                continue
            tr = c.read(lang)
            for u in units:
                if u.key in keep:
                    continue
                if L.is_legal(u, cfg):
                    legal.add(u.uid)
                    continue
                if (lang, c.id, u.key) in allow or ("*", c.id, u.key) in allow:
                    continue
                examined += 1
                v = tr.get(u.key)
                if v is None:
                    fails.append(f"{lang} {u.uid}: ABSENT, renders English: {u.src[:70]!r}")
                elif v == u.src and prose(u.src):
                    fails.append(f"{lang} {u.uid}: SAME AS ENGLISH (prose): {u.src[:70]!r}")
    return fails, examined, legal


def test_every_shipped_language_is_complete():
    cfg, _ = L.load_config()
    fails, examined, _ = gaps(cfg)
    assert examined > 0, "examined 0 keys: the gate cannot see the catalogues"
    assert not fails, f"{len(fails)} untranslated:\n" + "\n".join(fails[:60])


def test_gate_goes_red_on_a_dropped_key():
    """Negative control: drop one translated key from one language; the gate must name it."""
    cfg, _ = L.load_config()
    c = L.catalogues(cfg)[0]
    lang = [x for x in cfg["languages"] if x not in SPELLING_ONLY][0]
    tr = c.read(lang)
    victim = next(u for u in c.units() if u.key in tr and not L.is_legal(u, cfg) and u.key not in cfg.get("keep_english", []))
    orig = c.read
    c.read = lambda lg: {k: v for k, v in orig(lg).items() if not (lg == lang and k == victim.key)}
    try:
        cats = [c] + L.catalogues(cfg)[1:]
        real = L.catalogues
        L.catalogues = lambda _cfg: cats
        try:
            fails, _, _ = gaps(cfg, allow={})
        finally:
            L.catalogues = real
    finally:
        c.read = orig
    assert any(f.startswith(f"{lang} {victim.uid}: ABSENT") for f in fails), fails[:5]


def test_gate_goes_red_on_english_prose_left_in_place():
    """Negative control: an English sentence copied into a translation is a gap."""
    cfg, _ = L.load_config()
    c = L.catalogues(cfg)[0]
    lang = [x for x in cfg["languages"] if x not in SPELLING_ONLY][0]
    victim = next(u for u in c.units() if prose(u.src) and not L.is_legal(u, cfg) and u.key not in cfg.get("keep_english", []))
    orig = c.read
    c.read = lambda lg: {**orig(lg), **({victim.key: victim.src} if lg == lang else {})}
    real = L.catalogues
    L.catalogues = lambda _cfg: [c] + real(cfg)[1:]
    try:
        fails, _, _ = gaps(cfg, allow={})
    finally:
        L.catalogues = real
        c.read = orig
    assert any(f.startswith(f"{lang} {victim.uid}: SAME AS ENGLISH") for f in fails), fails[:5]


if __name__ == "__main__":
    # The gate proves it can fire before it is believed: both negative controls
    # run first, every time, and a control that stays green is a FAIL.
    for control in (test_gate_goes_red_on_a_dropped_key, test_gate_goes_red_on_english_prose_left_in_place):
        try:
            control()
        except AssertionError as e:
            print(f"FAIL: negative control {control.__name__} did not go red: {e}")
            sys.exit(1)
        print(f"control ok: {control.__name__}")
    cfg, _ = L.load_config()
    fails, examined, legal = gaps(cfg)
    langs = [x for x in cfg["languages"] if x not in SPELLING_ONLY]
    for f in fails[:200]:
        print("FAIL: " + f)
    if len(fails) > 200:
        print(f"FAIL: ... and {len(fails) - 200} more")
    print(f"examined {examined} key-language pairs across {len(langs)} languages; "
          f"{len(legal)} legal key(s) held English by rule; {len(fails)} gap(s)")
    print(f"RESULT: {'FAIL' if fails or not examined else 'PASS'}")
    sys.exit(1 if fails or not examined else 0)
