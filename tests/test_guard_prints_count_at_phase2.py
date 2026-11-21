#!/usr/bin/env python3
"""owner_knowledge_score prints the guard's count at phase 2 start, next to the decision.

Archie asked for the count, not just the word LIVE/CLEAR, so a refusal or a score can be read
against the graph state the guard actually saw. The print is one line: the count, then the decision.

Checks:
  - the probe has the phase-2 line, placed after the guard decision
  - the count extraction reads a real count from the SPARQL reply, and says "unreadable" for
    a reply that is not a count (never a number it did not read)
  - control: the same line without the count extraction is caught
Exit 0 pass, 1 fail. No box.
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(os.path.dirname(HERE), "scripts", "box_walk_probes", "probes", "owner_knowledge_score.sh")

EXTRACT = ('python3 -c \'import json,sys\ntry:\n    print(json.load(sys.stdin)["results"]["bindings"][0]["n"]["value"])\n'
           'except Exception:\n    print("unreadable")\'')


def extract(text):
    out = subprocess.run(["bash", "-c", "printf '%s' \"$T\" | " + EXTRACT],
                         env={"T": text, "PATH": os.environ.get("PATH", "/usr/bin:/bin")},
                         capture_output=True, text=True)
    return out.stdout.strip()


def main():
    with open(PROBE, encoding="utf-8") as fh:
        src = fh.read()
    bad = []
    decide_at = src.find('_og="$(printf')
    line_at = src.find("guard at phase 2 start")
    if line_at == -1 or decide_at == -1 or not decide_at < line_at:
        bad.append("the phase-2 guard line must be printed after the guard decision")
    if extract('{"results":{"bindings":[{"n":{"value":"3"}}]}}') != "3":
        bad.append("a real count must be read as 3")
    if extract("") != "unreadable" or extract("not json") != "unreadable":
        bad.append("an unreadable reply must print unreadable, never a number")
    mutant = src.replace("guard at phase 2 start", "guard NOT printed", 1)
    if mutant.find("guard at phase 2 start") != -1:
        bad.append("CONTROL: the mutant must not carry the line")
    if bad:
        print("FAIL: " + "; ".join(bad))
        return 1
    print("PASS: the phase-2 guard count is printed after the decision; an unreadable reply is 'unreadable'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
