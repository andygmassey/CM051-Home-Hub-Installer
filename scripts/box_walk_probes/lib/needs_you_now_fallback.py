"""Judge for needs_you_now_birthdays_survive_fallback (Python 3.9, no box access).

  judge EXPECTED_JSON LISTED_JSON    -> prints lines, exit 0 PASS / 1 FAIL / 78 CANNOT-RUN
  --self-test                        -> canned inputs; exit 0 only when every mutant went red

EXPECTED: names with a birthday inside the fallback's 14-day window, nearest
first (box side reads them from the Wiki's birthdays.md "In N days" rows).
LISTED: names on the "Needs you now" band of the Front Page, recompiled with
the Hub's editor feed forced absent, so the SPARQL fallback is the only source.

FAIL when the band lists NO expected birthday, or omits the nearest one. A
birthday that is in the window but not on the band is printed as a note, not a
FAIL: the band is capped, and that cap is not what this probe asserts.
"""
import json
import re
import sys

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78

# "Alice Example's birthday is in three days" -> "Alice Example"
BDAY_TITLE = re.compile(r"^(.+?)['’]s birthday\b", re.I)


def names_on_band(index_md):
    """The band is between the 'Needs you now' title and the next pw-band-title."""
    i = index_md.find("Needs you now")
    if i < 0:
        return None
    rest = index_md[i + 1:]
    j = rest.find("pw-band-title")
    band = rest[: j if j >= 0 else len(rest)]
    out = []
    for m in re.finditer(r'<p class="pw-fcard-title">([^<\n]+)', band):
        b = BDAY_TITLE.match(m.group(1).strip())
        if b:
            out.append(b.group(1).strip())
    return out


def judge(expected, listed):
    lines = ["  note   forced the SPARQL fallback; %d birthday(s) inside 14 days: %s"
             % (len(expected), ", ".join(expected) or "none")]
    if not expected:
        return lines + ["  CANNOT no contact has a birthday inside 14 days, so nothing could be listed"], EX_CANNOT
    if listed is None:
        return lines + ["  FAIL   the Front Page has no 'Needs you now' band at all"], EX_FAIL
    lines.append("  note   band lists %d birthday card(s): %s" % (len(listed), ", ".join(listed) or "none"))
    hit = [n for n in expected if n in listed]
    if not hit:
        return lines + ["  FAIL   none of the %d in-window birthdays is on the band" % len(expected)], EX_FAIL
    if expected[0] not in listed:
        return lines + ["  FAIL   the nearest birthday (%s) is missing from the band" % expected[0]], EX_FAIL
    missing = [n for n in expected if n not in listed]
    lines.append("  ok     %d of %d in-window birthdays listed, nearest (%s) included%s"
                 % (len(hit), len(expected), expected[0], "; not listed: " + ", ".join(missing) if missing else ""))
    return lines, EX_PASS


def self_test():
    band = ('<span class="pw-band-title">Needs you now<span class="pw-band-count">2</span></span>\n'
            '<p class="pw-fcard-title">Ada Test’s birthday is in three days\n'
            '<p class="pw-fcard-title">Bo Test\'s birthday is in four days\n'
            '<span class="pw-band-title">For you</span>\n<p class="pw-fcard-title">Cy Test\'s birthday is in nine days\n')
    got = names_on_band(band)
    want = [("band parsed, stops at next band", got, ["Ada Test", "Bo Test"]),
            ("listed -> PASS", judge(["Ada Test", "Bo Test"], got)[1], EX_PASS),
            ("empty band -> FAIL", judge(["Ada Test"], [])[1], EX_FAIL),
            ("nearest missing -> FAIL", judge(["Zed Test", "Ada Test"], got)[1], EX_FAIL),
            ("no band -> FAIL", judge(["Ada Test"], names_on_band("<p>front page</p>"))[1], EX_FAIL),
            ("no birthdays seeded -> CANNOT-RUN", judge([], got)[1], EX_CANNOT)]
    ok = True
    for name, g, w in want:
        print("  %s  %s" % ("ok    " if g == w else "FAIL  ", name))
        ok &= g == w
    print("every mutant went red" if ok else "SELF-TEST BROKEN")
    return 0 if ok else 1


def main(argv):
    if len(argv) > 1 and argv[1] == "--self-test":
        return self_test()
    if len(argv) > 3 and argv[1] == "judge":
        lines, rc = judge(json.load(open(argv[2])), json.load(open(argv[3])))
        print("\n".join(lines))
        return rc
    sys.stderr.write(__doc__)
    return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
