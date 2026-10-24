#!/usr/bin/env python3
"""Record WHICH WORDING a person saw when they answered a consent screen.

Andy, 2026-10-24: "yes, localisation with English prevails." A legal or
consent line may now be shown translated, but only once a native reviewer has
passed that translation (l10n/legal_reviews.tsv in CM051). The consent record
must therefore say which language the screen was in and which reviewed
translations were on it, so we can later show exactly what was agreed to.

install.sh calls this right after `ostler_security.consent_cli record` has
written the record for a tickbox. It adds, to that same record in
<posture>/consent.json:

    "display_language":    the installer language (OSTLER_LANG), e.g. "zh-Hans"
    "display_review_ids":  sorted legal_reviews.tsv row ids of every line on the
                           screen that was shown TRANSLATED; [] means every line
                           was shown in English
    "display_recorded_at": UTC timestamp
    "display_schema":      1

The binding wording stays what it always was: `wording_text` / `wording_hash`
are the ENGLISH text from the legal package, because the English prevails.
Records written before this existed have no display_* fields and stay
readable: absence means the screen was English (the only thing shown then).

A review row id is "<lang>/<catalogue>::<key>@<hash>", where <hash> is the
first 12 hex of SHA-256 of the English line the reviewer read. It names exactly
one legal_reviews.tsv row (lang, catalogue, key, source_hash), and is the same
string l10n/ostler_l10n.py's review_id() produces; tests check both agree.

A translated line is detected by comparing the shipped catalogue for the
language against the English one: l10n/ostler_l10n.py only lets a legal
translation into a shipped catalogue with a current review row, so a line that
differs from English IS a reviewed one.

Stdlib only; runs under the bundled Python 3.11. Exit 0 on success, 2 on a
usage error, 1 if the record could not be updated (install.sh logs it).
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path

DISPLAY_SCHEMA = 1

# The lines each consent screen shows, per catalogue: key prefixes. Every
# screen also carries the English-prevails line (when it is translated).
PREVAILS = {"install_sh": ["MSG_LEGAL_ENGLISH_PREVAILS"], "viewcopy": ["legal/english_prevails"]}
SURFACES = {
    "article_9_special_category_consent": {
        "install_sh": ["MSG_PROMPT_CONSENT_ARTICLE_9_"],
        "viewcopy": ["consent_article_9/"],
    },
    "whatsapp_unofficial_risk": {
        "install_sh": ["MSG_PROMPT_WHATSAPP_CONSENT_"],
        "viewcopy": [],
    },
    "voice_speaker_id_eu": {
        "install_sh": ["MSG_PROMPT_CONSENT_VOICE_EU_"],
        "viewcopy": [],
    },
    "third_party_data_personal_records": {
        "install_sh": ["MSG_PROMPT_CONSENT_THIRD_PARTY_"],
        "viewcopy": ["consent_third_party/"],
    },
    "personal_use_only": {
        "install_sh": ["MSG_TERMS_PERSONAL_USE_", "MSG_PROMPT_TERMS_PERSONAL_USE_", "MSG_TERMS_LANGUAGE"],
        "viewcopy": [],
    },
    "spoken_capture_recording_consent": {
        "install_sh": ["MSG_CONSENT_SPOKEN_CAPTURE_", "MSG_PROMPT_CONSENT_SPOKEN_CAPTURE_"],
        "viewcopy": ["consent_spoken_capture/"],
    },
}


def h(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()[:12]


# --- install.sh.strings.<lang>.sh: MSG_KEY="value" (same reader as l10n) ----

_ASSIGN = re.compile(r'(MSG_[A-Z0-9_]+)="')


def read_shell(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    text = path.read_text(encoding="utf-8")
    out, pos, n = {}, 0, len(text)
    while pos < n:
        eol = text.find("\n", pos)
        eol = n if eol == -1 else eol
        m = _ASSIGN.match(text, pos)
        if m and not text.startswith("#", pos):
            j = m.end()
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            lit = text[m.end():j]
            out[m.group(1)] = re.sub(r'\\([\\"$`\n])', lambda x: "" if x.group(1) == "\n" else x.group(1), lit)
            e2 = text.find("\n", j)
            pos = n if e2 == -1 else e2 + 1
            continue
        pos = eol + 1
    return out


# --- ViewCopy(.<lang>).json: nested tree, keys joined with "/" -------------

def read_tree(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    out: dict[str, str] = {}

    def walk(x, p):
        if isinstance(x, str):
            out["/".join(p)] = x
        elif isinstance(x, dict):
            for k, v in x.items():
                if not k.startswith("_"):
                    walk(v, p + [k])
        elif isinstance(x, list):
            for i, v in enumerate(x):
                walk(v, p + [str(i)])

    walk(json.loads(path.read_text(encoding="utf-8")), [])
    return out


def catalogues(resources: Path, lang: str) -> dict[str, tuple[dict, dict]]:
    """{catalogue id: (english, shown)} as install.sh and the GUI load them:
    English first, the language overlaid per key."""
    en_sh = read_shell(resources / "install.sh.strings.en-GB.sh")
    en_vc = read_tree(resources / "ViewCopy.json")
    if lang in ("", "en-GB"):
        return {"install_sh": (en_sh, en_sh), "viewcopy": (en_vc, en_vc)}
    sh = dict(en_sh)
    sh.update(read_shell(resources / f"install.sh.strings.{lang}.sh"))
    vc = dict(en_vc)
    vc.update(read_tree(resources / f"ViewCopy.{lang}.json"))
    return {"install_sh": (en_sh, sh), "viewcopy": (en_vc, vc)}


def review_ids(tickbox: str, lang: str, resources: Path) -> list[str]:
    surface = SURFACES[tickbox]
    ids = []
    for cat, (en, shown) in catalogues(resources, lang).items():
        prefixes = surface.get(cat, []) + PREVAILS.get(cat, [])
        for key, src in en.items():
            if not any(key.startswith(p) for p in prefixes):
                continue
            v = shown.get(key)
            if v is not None and v != src:
                ids.append(f"{lang}/{cat}::{key}@{h(src)}")
    return sorted(ids)


def _atomic_write(path: Path, payload: dict) -> None:
    fd, tmp = tempfile.mkstemp(prefix=".consent.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2, sort_keys=True)
            f.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def record(posture: Path, tickbox: str, lang: str, resources: Path) -> dict:
    path = posture / "consent.json"
    reg = json.loads(path.read_text(encoding="utf-8"))
    rec = reg.get("records", {}).get(tickbox)
    if not isinstance(rec, dict):
        raise LookupError(f"no consent record for {tickbox!r} in {path}; consent_cli record must run first")
    rec["display_language"] = lang or "en-GB"
    rec["display_review_ids"] = review_ids(tickbox, lang, resources)
    rec["display_recorded_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    rec["display_schema"] = DISPLAY_SCHEMA
    _atomic_write(path, reg)
    return rec


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--posture", required=True, type=Path)
    ap.add_argument("--tickbox", required=True)
    ap.add_argument("--lang", required=True)
    ap.add_argument("--resources", required=True, type=Path,
                    help="directory holding install.sh.strings.*.sh and ViewCopy*.json")
    a = ap.parse_args(argv)
    if a.tickbox not in SURFACES:
        print(f"ostler_consent_display: unknown tickbox {a.tickbox!r}; known: {sorted(SURFACES)}", file=sys.stderr)
        return 2
    if not (a.resources / "install.sh.strings.en-GB.sh").is_file():
        print(f"ostler_consent_display: no install.sh.strings.en-GB.sh in {a.resources}", file=sys.stderr)
        return 1
    try:
        rec = record(a.posture, a.tickbox, a.lang, a.resources)
    except (OSError, ValueError, LookupError) as e:
        print(f"ostler_consent_display: {e}", file=sys.stderr)
        return 1
    print(f"ostler_consent_display: {a.tickbox} shown in {rec['display_language']}, "
          f"{len(rec['display_review_ids'])} reviewed translated line(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
