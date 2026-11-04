#!/usr/bin/env python3
"""The consent copy must not promise cloud routing, and the terms link is ostler.ai/terms.

v1.0.124. The Article 9 consent and the third-party-data notice listed, among
the Privacy Policy exceptions, "optional cloud routing for non-personal
questions". No such path exists: install.sh writes only an Ollama provider on
localhost (no model routes, no LLM api_key), and the assistant's query
classification is off by default. A consent screen must not describe a data
flow the product does not have, so the clause is gone in every place a
customer reads it:

  - install.sh (TTY third-party-data notice)
  - vendor/legal/consent_strings.py (the wording the consent record hashes)
  - gui/OstlerInstaller/Resources/ViewCopy*.json, consent_article_9/intro_body,
    in every shipped language

and the install terms line in install.sh points at the same ostler.ai/terms the
GUI and LICENSE already use, not the retired creativemachines.ai/ostler/terms.

Each surface also carries a POSITIVE control (the parenthetical is still there,
with its remaining items), so a renamed key or a deleted paragraph cannot pass
by reading nothing. A built-in negative control proves the detector fires on
the old wording before any verdict is printed.

Exit 0 = every check passed; 1 = any FAIL; 2 = CANNOT-RUN (a file is missing).
"""
import importlib.util
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "gui" / "OstlerInstaller" / "Resources"

# The removed clause, as each shipped translation rendered it. Every phrase is
# checked against EVERY file, so a clause pasted into the wrong locale is caught.
BANNED = [
    "cloud routing",
    "non-personal question",
    "Cloud-Routing",
    "nicht personenbezogene Fragen",
    "nube para preguntas",
    "vers le cloud pour",
    "instradamento cloud",
    "クラウド経由",
    "클라우드 라우팅",
    "cloudroutering",
    "nuvem para perguntas",
    "nuvem de perguntas",
    "云端路由",
    "雲端路由",
    "雲端轉送",
    "التوجيه السحابي",
]

# What must REMAIN in each locale's parenthetical: the update-check item.
KEEP = {
    "ViewCopy.json": "software update checks and a handful of public metadata services",
    "ViewCopy.en-US.json": "software update checks and a handful of public metadata services",
    "ViewCopy.de.json": "Prüfungen auf Software-Updates",
    "ViewCopy.es.json": "comprobaciones de actualizaciones de software",
    "ViewCopy.fr.json": "la vérification des mises à jour logicielles",
    "ViewCopy.it.json": "controllo degli aggiornamenti del software",
    "ViewCopy.ja.json": "ソフトウェアアップデートの確認",
    "ViewCopy.ko.json": "소프트웨어 업데이트 확인",
    "ViewCopy.nl.json": "controles op software-updates",
    "ViewCopy.pt-BR.json": "verificação de atualizações de software",
    "ViewCopy.pt-PT.json": "verificações de atualizações de software",
    "ViewCopy.zh-HK.json": "軟件更新檢查",
    "ViewCopy.zh-Hans.json": "软件更新检查",
    "ViewCopy.zh-Hant.json": "軟體更新檢查",
    "ViewCopy.ar.json": "التحقق من تحديثات البرنامج",
}

fails = 0


def report(ok, msg):
    global fails
    print(("ok   " if ok else "FAIL ") + msg)
    if not ok:
        fails += 1


def hits(text):
    low = text.lower()
    return [b for b in BANNED if b.lower() in low]


def flatten_echo(sh):
    """Join consecutive echo lines so a clause wrapped across lines is one run."""
    return re.sub(r'"\s*\n\s*echo\s+"\s*', " ", sh)


# Negative control: the detector must fire on the old wording, wrapped or not.
old_wrapped = ('echo "      Privacy Policy at ostler.ai/privacy (mainly: optional cloud"\n'
               'echo "      routing for non-personal questions, software update checks,"\n')
if not hits(flatten_echo(old_wrapped)) or not hits("(vor allem: optionales Cloud-Routing für nicht personenbezogene Fragen, ...)"):
    print("CANNOT-RUN detector does not fire on the old wording; no verdict")
    sys.exit(2)
report(True, "negative control: the detector flags the old wording (wrapped echo lines and a translation)")

needed = [ROOT / "install.sh", ROOT / "vendor" / "legal" / "consent_strings.py"] + [RES / f for f in KEEP]
missing = [str(p.relative_to(ROOT)) for p in needed if not p.is_file()]
if missing:
    print(f"CANNOT-RUN missing: {missing}")
    sys.exit(2)

# 1. install.sh
sh = (ROOT / "install.sh").read_text(encoding="utf-8")
flat = flatten_echo(sh)
h = hits(flat)
report(not h, f"install.sh promises no cloud routing {h if h else ''}")
report("ostler.ai/privacy (mainly: software update checks and public metadata enrichment)" in flat,
       "install.sh third-party notice still lists its remaining exceptions (positive control)")
report("creativemachines.ai/ostler/terms" not in sh, "install.sh no longer points at creativemachines.ai/ostler/terms")
report(re.search(r'^echo "    4\. You accept the terms at ostler\.ai/terms"$', sh, re.M) is not None,
       "install.sh terms line is ostler.ai/terms")

# 2. vendor/legal/consent_strings.py, the text the consent record hashes
spec = importlib.util.spec_from_file_location("cs", ROOT / "vendor" / "legal" / "consent_strings.py")
cs = importlib.util.module_from_spec(spec)
sys.modules["cs"] = cs  # dataclasses resolves annotations through sys.modules
spec.loader.exec_module(cs)
for name in ("ARTICLE_9_EU_CONSENT", "THIRD_PARTY_DATA_NOTICE"):
    text = getattr(cs, name).text
    h = hits(text)
    report(not h, f"consent_strings.{name} promises no cloud routing {h if h else ''}")
    report("ostler.ai/privacy (mainly: software update checks" in text,
           f"consent_strings.{name} still lists its remaining exceptions (positive control)")
h = hits((ROOT / "vendor" / "legal" / "consent_strings.py").read_text(encoding="utf-8"))
report(not h, f"consent_strings.py source carries no cloud-routing clause anywhere {h if h else ''}")

# 3. every ViewCopy locale
for fname, keep in KEEP.items():
    d = json.loads((RES / fname).read_text(encoding="utf-8"))
    body = d.get("consent_article_9", {}).get("intro_body", "")
    report("ostler.ai/privacy" in body and keep in body,
           f"{fname} consent_article_9/intro_body still lists the update-check exception (positive control)")
    h = hits(json.dumps(d, ensure_ascii=False))
    report(not h, f"{fname} promises no cloud routing {h if h else ''}")
    url = d.get("consent_install", {}).get("consent_install_terms_url") or \
        next((v.get("consent_install_terms_url") for v in d.values()
              if isinstance(v, dict) and "consent_install_terms_url" in v), None)
    report(url == "https://ostler.ai/terms", f"{fname} terms url is https://ostler.ai/terms (got {url!r})")

print(f"{'PASS' if not fails else 'FAIL'}: {fails} failure(s)")
sys.exit(1 if fails else 0)
