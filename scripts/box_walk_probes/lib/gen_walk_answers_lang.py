#!/usr/bin/env python3
"""gen_walk_answers_lang.py <walk_drive.py> <strings.en-GB.sh> <strings.LANG.sh> <out.tsv>

Builds a ~/.walk-answers.tsv for a non-English walk. walk_drive.py answers
prompts by ENGLISH substring (its built-in table); under OSTLER_LANG=<lang> the
prompts are translated and those substrings no longer appear. For every
built-in (substring, answer) pair this finds the en-GB MSG_ key(s) whose value
contains the substring, takes the SAME key's value from the <lang> file, and
emits the longest literal run of it (split at printf placeholders and
newlines) as the override substring, with the same answer.

Prints, per built-in pair: MAPPED (key, translated substring), ENGLISH (the
<lang> value still carries the English substring, so the built-in still
matches), or UNMAPPED (no MSG_ key holds the substring: the prompt is not
catalogued, so it stays English and the built-in matches; reported, never
guessed). Exit 0 always; the report is the product.
"""
import ast, importlib.util, os, re, sys, warnings

# The en-GB catalogue carries "\$" and "\`"; decoding them is deliberate.
warnings.simplefilter("ignore", DeprecationWarning)

drv, en_f, xx_f, out = sys.argv[1:5]


def computed_answers(drv_path):
    """The two computed answers, taken from the driver itself.

    Imports walk_drive.py (import has no side effects: its entry point is
    behind __main__) and calls the SAME function build_table() calls, so the
    country code and timezone are read from the box's ~/.walk-locale.tsv with
    the driver's own defaults. Nothing is hard-coded here. If the driver
    cannot be imported the computed pairs are reported SKIP, never guessed.
    """
    try:
        spec = importlib.util.spec_from_file_location("walk_drive_for_gen", drv_path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        loc = mod._locale_defaults()
        return {"cc": loc["country_code"], "tz": loc["timezone"]}
    except Exception as exc:  # report, do not guess
        sys.stderr.write("computed answers unavailable: %s\n" % exc)
        return {}


def load(path):
    d = {}
    for line in open(path, encoding="utf-8"):
        m = re.match(r'^(MSG_[A-Z0-9_]+)=(.*)$', line.rstrip("\n"))
        if not m:
            continue
        v = m.group(2).strip()
        try:
            if v[:1] in "\"'":
                v = ast.literal_eval(v) if v[:1] == "'" else bytes(v[1:-1], "utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8")
        except Exception:
            v = v.strip("\"'")
        d[m.group(1)] = v
    return d


en, xx = load(en_f), load(xx_f)
src = open(drv, encoding="utf-8").read()
pairs = re.findall(r'^\s*\("([^"]+)",\s*("?[^)]*?"?|[a-z_]+)\),', src, re.M)
computed = computed_answers(drv)
rows, report = [], []
for sub, ans in pairs:
    ans = ans.strip().strip('"')
    if ans in ("cc", "tz") and ans in computed:
        ans = computed[ans]
    elif not ans or ans in ("cc", "tz"):
        report.append(("SKIP", sub, "answer is computed (%s) and unavailable; keep built-in" % ans))
        continue
    keys = [k for k, v in en.items() if sub in v]
    if not keys:
        report.append(("UNMAPPED", sub, "no MSG_ key holds it; prompt stays English"))
        continue
    done = False
    for k in keys:
        t = xx.get(k, "")
        if sub in t:
            report.append(("ENGLISH", sub, k + " untranslated; built-in still matches"))
            done = True
            break
        runs = [r.strip() for r in re.split(r"%[sd]|\\n|\n", t) if r.strip()]
        if runs:
            best = max(runs, key=len)
            rows.append((best, ans))
            report.append(("MAPPED", sub, k + " -> " + best[:60]))
            done = True
            break
    if not done:
        report.append(("UNMAPPED", sub, "keys %s have no %s value" % (",".join(keys), "translated")))
with open(out, "w", encoding="utf-8") as fh:
    for s, a in rows:
        fh.write(s + "\t" + a + "\n")
for r in report:
    print("\t".join(r))
print("rows written: %d of %d built-in pairs" % (len(rows), len(pairs)))
