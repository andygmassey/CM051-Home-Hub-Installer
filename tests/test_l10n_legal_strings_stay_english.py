#!/usr/bin/env python3
"""Legal and consent strings are IDENTICAL to the en-GB source in every locale.

Andy's ruling, 2026-10-22: legal and consent strings stay ENGLISH in every
locale. This reads every shipped catalogue for every configured language and
fails on any legal-class unit whose value differs from the English source.
A missing value is fine (the runtime falls back to English).

The predicate is l10n/ostler_l10n.is_legal over the real catalogues, so a new
legal key is covered the day it appears. The mutant cases prove the check can
fail: one translated legal unit must be reported, and a translated NON-legal
unit must not be.
"""
import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("ostler_l10n", ROOT / "l10n" / "ostler_l10n.py")
L = importlib.util.module_from_spec(spec)
spec.loader.exec_module(L)


def violations(cfg, read=None):
    bad, legal_seen = [], 0
    for c in L.catalogues(cfg):
        units = {u.key: u for u in c.units()}
        for lang in cfg["languages"]:
            tr = (read or (lambda cat, lg: cat.read(lg)))(c, lang)
            for k, u in units.items():
                if not L.is_legal(u, cfg):
                    continue
                legal_seen += 1
                v = tr.get(k)
                if v is not None and v != u.src:
                    bad.append(f"{c.id} {lang} {k}")
    return bad, legal_seen


def main():
    cfg, _gl = L.load_config()
    fails = []
    bad, seen = violations(cfg)
    print(f"legal-class unit checks: {seen} across {len(cfg['languages'])} languages; translated: {len(bad)}")
    if seen == 0:
        fails.append("CANNOT-RUN: no legal-class unit examined (predicate matched nothing)")
    for b in bad[:20]:
        fails.append(f"legal string differs from English: {b}")

    # mutant: translate one legal unit in one locale, the check must catch it
    c0 = next(c for c in L.catalogues(cfg) if c.id == "install_sh")
    legal_k = next(u.key for u in c0.units() if L.is_legal(u, cfg))
    plain_k = next(u.key for u in c0.units() if not L.is_legal(u, cfg))
    lang0 = cfg["languages"][0]

    def mutate(key):
        def read(cat, lg):
            tr = dict(cat.read(lg))
            if cat.id == c0.id and lg == lang0:
                tr[key] = "MUTANT"
            return tr
        return read
    if len(violations(cfg, mutate(legal_k))[0]) != len(bad) + 1:
        fails.append("MUTANT NOT CAUGHT: a translated legal string passed")
    if violations(cfg, mutate(plain_k))[0] != bad:
        fails.append("false positive: a translated non-legal string was flagged")
    for f in fails:
        print("FAIL:", f)
    print("PASS" if not fails else "FAIL")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
