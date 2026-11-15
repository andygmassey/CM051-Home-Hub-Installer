#!/usr/bin/env python3
"""Owner ruling 2026-11-04: the legal wording is what we show SMALLER AND
LIGHTER on the consent screens; that wording stays English, the rest is
translated. So "drawn in the legal style" and "classed as legal" must be the
same set. In install.sh the legal style is ${DIM}; in the GUI it is the
small/italic/secondary legal_* fields of ViewCopy. Every key drawn that way
must be is_legal_key(). Mutant: dropping a DIM key from the legal class goes RED."""
import importlib.util
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("cd", ROOT / "lib" / "ostler_consent_display.py")
cd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cd)

sh = (ROOT / "install.sh").read_text(encoding="utf-8")
dim = set(re.findall(r"\$\{DIM\}[^\"\n]*?\$\{?(MSG_[A-Z0-9_]+)", sh))
swift = "\n".join(p.read_text(encoding="utf-8") for p in (ROOT / "gui" / "OstlerInstaller").rglob("*.swift"))
gui = set(re.findall(r'"((?:consent_[a-z_0-9]+[./])?legal_[a-z_0-9]+)"', swift))
gui |= {m.replace(".", "/") for m in re.findall(r'"(consent_[a-z_0-9]+\.legal_[a-z_0-9]+)"', swift)}


def check(legal_fn):
    return sorted(k for k in dim | gui if not legal_fn(k.split("/")[-1] if "/" in k else k) and not legal_fn(k))


ok = True
print(("ok   " if dim else "FAIL ") + f"legal-style lines found: {len(dim)} in install.sh (DIM), {len(gui)} GUI legal_* fields")
ok &= bool(dim)
bad = check(cd.is_legal_key)
print(("ok   " if not bad else "FAIL ") + f"every legal-style line is classed legal {bad if bad else ''}")
ok &= not bad
mut = check(lambda k: cd.is_legal_key(k) and k != "MSG_TERMS_LANGUAGE")
print(("ok   " if mut else "FAIL ") + "mutant: a DIM line dropped from the legal class is caught")
ok &= bool(mut)
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
