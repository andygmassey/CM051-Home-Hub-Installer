#!/usr/bin/env python3
"""A consent prompt that asks the person to TYPE a word must show, in every
language, exactly the word the installer accepts.

2 Nov 2026 tester failure class: a translated prompt asking for a translated
word ("tapez INSTALLER") against a validator expecting INSTALL is a dead end.
For every `gui_read ... text_with_cancel ...` prompt in install.sh, the accept
and cancel tokens come from its choices argument; every locale's shell strings
for that prompt's title/help must carry those tokens verbatim wherever the
English does. Mutant: translate a token in one locale and this goes RED."""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sh = (ROOT / "install.sh").read_text(encoding="utf-8")
prompts = re.findall(r'gui_read "\$(MSG_[A-Z0-9_]+)" text_with_cancel "[^"]*" "\$(MSG_[A-Z0-9_]+)" "([^"]+)"', sh)


def strings(lang):
    p = ROOT / ("install.sh.strings.en-GB.sh" if lang == "en-GB" else f"install.sh.strings.{lang}.sh")
    out = {}
    for k, v in re.findall(r'^(MSG_[A-Z0-9_]+)=(.*)$', p.read_text(encoding="utf-8"), re.M):
        out[k] = v
    return out


def check(langs, mutate=None):
    bad = []
    en = strings("en-GB")
    for title, helpk, choices in prompts:
        tokens = [t for t in choices.split(",") if t]
        # the validator compares against choices[0] (accept) / choices[1] (cancel)
        for lang in langs:
            tr = strings(lang)
            if mutate and lang == mutate[0]:
                tr = {k: v.replace(mutate[1], mutate[2]) for k, v in tr.items()}
            for k in (title, helpk):
                for tok in tokens:
                    # a whole word: "INSTALLER" must not count as "INSTALL"
                    w = re.compile(r"(?<![A-Za-z])" + re.escape(tok) + r"(?![A-Za-z])")
                    if w.search(en.get(k, "")) and not w.search(tr.get(k, en.get(k, ""))):
                        bad.append(f"{lang}:{k} lost '{tok}'")
    return bad


langs = sorted(p.name[len("install.sh.strings."):-len(".sh")] for p in ROOT.glob("install.sh.strings.*.sh")
               if not p.name.endswith("en-GB.sh"))
ok = True
print(("ok   " if prompts else "FAIL ") + f"typed-token prompts found: {len(prompts)} ({', '.join(t for t, _, _ in prompts)})")
ok &= bool(prompts)
bad = check(langs)
print(("ok   " if not bad else "FAIL ") + f"every locale ({len(langs)}) shows the exact accept/cancel tokens {bad[:3] if bad else ''}")
ok &= not bad
mut = check(langs, mutate=("fr", "INSTALL", "INSTALLER"))
print(("ok   " if mut else "FAIL ") + "mutant: a translated token in fr is caught")
ok &= bool(mut)
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
