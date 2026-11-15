#!/usr/bin/env python3
"""The consent record's legal/plain split must match the translation tool's.

Owner ruling 2026-11-04: plain-language consent copy is translated; only the
legal wording needs a legal review. lib/ostler_consent_display.py and
l10n/config.yaml each encode that rule; if they drift, a consent record could
call a legal line "plain" (no review row named) or the reverse."""
import hashlib
import importlib.util
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("cd", ROOT / "lib" / "ostler_consent_display.py")
cd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cd)
cfg = (ROOT / "l10n" / "config.yaml").read_text()
pats = [re.compile(p, re.I) for p in re.findall(r"'([^']+)'", re.search(r"^legal_patterns: \[(.*)\]$", cfg, re.M).group(1))]
keys = set(re.search(r"^legal_keys: \[(.*)\]$", cfg, re.M).group(1).replace(" ", "").split(","))

src = (ROOT / "install.sh.strings.en-GB.sh").read_text()
names = re.findall(r"^(MSG_[A-Z0-9_]+)=", src, re.M)
names += ["consent_spoken_capture/legal_core", "consent_third_party/legal_note", "legal/english_prevails",
          "consent_spoken_capture/bullet_1", "consent_article_9/intro_body"]
bad = [k for k in names if cd.is_legal_key(k) != (k in keys or any(p.search(k) for p in pats))]
ok = not bad and keys == cd.LEGAL_KEYS
print(("ok   " if ok else "FAIL ") + f"consent record legal rule matches l10n/config.yaml ({len(names)} keys){' ' + str(bad[:5]) if bad else ''}")
legal = [k for k in names if cd.is_legal_key(k)]
print(("ok   " if "MSG_CONSENT_SPOKEN_CAPTURE_ASK_1" not in legal and "MSG_TERMS_PERSONAL_USE_LEGAL" in legal else "FAIL ")
      + "a plain consent bullet is plain; the licence line is legal")
ok &= "MSG_TERMS_PERSONAL_USE_LEGAL" in legal and "MSG_CONSENT_SPOKEN_CAPTURE_ASK_1" not in legal

# The record names the LOCALE shown and the exact English version (@src_hash)
# of every translated line, plain and legal (Archie 2026-11-04). A fake
# resources dir with one translated plain line and one translated legal line.
import json, tempfile
with tempfile.TemporaryDirectory() as d:
    res, post = Path(d) / "res", Path(d) / "post"
    res.mkdir(); post.mkdir()
    en_sh = 'MSG_PROMPT_CONSENT_ARTICLE_9_TITLE="Your decision (Y / N)"\nMSG_PROMPT_CONSENT_ARTICLE_9_HELP="Plain help"\nMSG_LEGAL_ENGLISH_PREVAILS="English prevails"\n'
    (res / "install.sh.strings.en-GB.sh").write_text(en_sh)
    (res / "install.sh.strings.fr.sh").write_text(en_sh.replace('"Plain help"', '"Aide"'))
    (res / "ViewCopy.json").write_text(json.dumps({"consent_article_9": {"intro_body": "Hello", "legal_note": "Legal note: x"},
                                                   "legal": {"english_prevails": "EP"}}))
    (res / "ViewCopy.fr.json").write_text(json.dumps({"consent_article_9": {"intro_body": "Bonjour", "legal_note": "Note juridique : x"},
                                                      "legal": {"english_prevails": "EP"}}))
    (post / "consent.json").write_text(json.dumps({"records": {"article_9_special_category_consent": {"granted": True}}}))
    rec = cd.record(post, "article_9_special_category_consent", "fr", res)
    hx = lambda s: hashlib.sha256(s.encode()).hexdigest()[:12]
    want_plain = sorted([f"fr/install_sh::MSG_PROMPT_CONSENT_ARTICLE_9_HELP@{hx('Plain help')}",
                         f"fr/viewcopy::consent_article_9/intro_body@{hx('Hello')}"])
    want_legal = [f"fr/viewcopy::consent_article_9/legal_note@{hx('Legal note: x')}"]
    good = (rec.get("display_language") == "fr" and rec.get("display_plain_translated_ids") == want_plain
            and rec.get("display_review_ids") == want_legal)
    print(("ok   " if good else "FAIL ") + "consent record: locale, and every translated line plain and legal with its @src_hash"
          + ("" if good else f" {rec}"))
    ok &= good
sys.exit(0 if ok else 1)
