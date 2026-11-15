#!/usr/bin/env python3
"""Every legal/consent prompt in install.sh is preceded by legal_prevails_note.

Owner ruling 2026-10-24: a localised legal surface carries the reviewed "English
version prevails" line. On the terminal path install.sh prints it via
legal_prevails_note (a no-op unless the line is translated, and in the GUI,
which draws it itself under the consent body: ViewCopy.isLegalPrompt). This
holds the two to the same rule: a gui_read whose prompt id (sixth argument)
is consent_*, *_consent or terms_* must have legal_prevails_note on the line
before it. A new consent prompt without the note fails here.

Mutant: the same scan over a copy with one note removed must report it.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LEGAL_ID = re.compile(r"^(consent_\w+|\w+_consent|terms_\w+)$")
CALL = re.compile(r'gui_read\s+.*"([a-z0-9_]+)"\)"?\s*$')


def scan(text):
    lines = text.splitlines()
    seen, missing = [], []
    for i, line in enumerate(lines):
        if line.lstrip().startswith("#") or "gui_read" not in line:
            continue
        m = CALL.search(line)
        if not m or not LEGAL_ID.match(m.group(1)):
            continue
        seen.append(m.group(1))
        j = i - 1
        while j >= 0 and not lines[j].strip():
            j -= 1
        if lines[j].strip() != "legal_prevails_note":
            missing.append(f"install.sh:{i + 1} {m.group(1)}")
    return seen, missing


def main():
    text = (ROOT / "install.sh").read_text(encoding="utf-8")
    fails = []
    seen, missing = scan(text)
    want = {"autologin_consent", "consent_article_9", "consent_enrichment", "consent_install", "consent_spoken_capture",
            "consent_third_party", "consent_voice_eu", "terms_personal_use", "whatsapp_consent"}
    print(f"legal prompts found: {len(seen)} ({', '.join(sorted(set(seen)))}); missing the note: {len(missing)}")
    if not want <= set(seen):
        fails.append(f"CANNOT-RUN: scan did not find every known legal prompt; missing {sorted(want - set(seen))}")
    fails += [f"no legal_prevails_note before {m}" for m in missing]
    if "legal_prevails_note() {" not in text:
        fails.append("legal_prevails_note is not defined in install.sh")
    # mutant: drop the first note, the scan must report exactly one
    mut = text.replace("legal_prevails_note\n", "", 1)
    if len(scan(mut)[1]) != len(missing) + 1:
        fails.append("MUTANT NOT CAUGHT: a legal prompt without the note passed")
    for f in fails:
        print("FAIL:", f)
    print("PASS" if not fails else "FAIL")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
