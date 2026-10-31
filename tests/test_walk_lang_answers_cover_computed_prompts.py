#!/usr/bin/env python3
"""tests/test_walk_lang_answers_cover_computed_prompts.py

A localised walk leg (ttywalk --lang) answers prompts from a generated
~/.walk-answers.tsv. The English driver answers some prompts with a COMPUTED
value (@owner_name, @owner_allowed, @passphrase, and the country code and
timezone read from the box). v1.0.121 batch 2: the JA leg aborted because the
generator mapped only the FIRST catalogue key that carries "Full name"
(MSG_PROMPT_USER_NAME_DETECTED_TITLE) and the installer showed the other one
(MSG_PROMPT_USER_NAME_FALLBACK_TITLE), which got Enter and was re-asked for ever.

This test fails if ANY prompt the English driver answers with a computed value
has no matching answer in the file generated for ANY shipped locale. The
oracle is independent of the generator: catalogues are read by sourcing them
with /bin/bash (the way install.sh reads them), and the answer is found the way
the driver finds it, by first-matching row.

Controls (each must turn the check red):
  - the generator with the all-keys mapping switched off (the pre-fix behaviour)
  - a generated file with the fallback-name row deleted
  - a generated file whose fallback-name row carries the wrong answer

GEN=<path> points the check at another generator (used to show RED on main).
0 pass, 1 fail, 2 cannot-run.
"""
import glob
import importlib.util
import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = os.environ.get("GEN") or os.path.join(REPO, "scripts/box_walk_probes/lib/gen_walk_answers_lang.py")
DRV = os.path.join(REPO, "scripts/walk_drive.py")
BASE = "en-GB"

TMP = tempfile.mkdtemp(prefix="walk-lang-computed.")
# The driver reads HOME at import; never let it touch the real one.
os.environ["HOME"] = TMP


def cannot_run(msg):
    print("CANNOT-RUN: " + msg)
    sys.exit(2)


for f in (GEN, DRV):
    if not os.path.isfile(f):
        cannot_run("missing " + f)

spec = importlib.util.spec_from_file_location("walk_drive_under_test", DRV)
drv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(drv)
loc = drv._locale_defaults()
COMPUTED_PLAIN = {loc["country_code"], loc["timezone"]}
table = drv.build_table()
computed = [(s, a) for s, a in table if a.startswith("@") or a in COMPUTED_PLAIN]
if len(computed) < 7:
    cannot_run("only %d computed driver answers found; the table shape changed" % len(computed))
print("driver computed answers (%d): %s" % (len(computed), ", ".join("%s=%s" % (s, a) for s, a in computed)))


def catalogue(path):
    script = 'set -u; . "$1"; for v in ${!MSG_*}; do printf "%s\\0%s\\0" "$v" "${!v}"; done'
    r = subprocess.run(["/bin/bash", "-c", script, "x", path], capture_output=True)
    if r.returncode != 0:
        cannot_run("cannot source %s: %s" % (path, r.stderr.decode("utf-8", "replace")[:200]))
    parts = r.stdout.decode("utf-8").split("\0")
    return dict(zip(parts[0::2], parts[1::2]))


def generate(gen, lang, out):
    r = subprocess.run([sys.executable, gen, DRV,
                        os.path.join(REPO, "install.sh.strings.%s.sh" % BASE),
                        os.path.join(REPO, "install.sh.strings.%s.sh" % lang), out],
                       capture_output=True, env=dict(os.environ))
    if r.returncode != 0 or not os.path.isfile(out):
        cannot_run("generator failed for %s: %s" % (lang, r.stderr.decode("utf-8", "replace")[:200]))


def rows_of(path):
    rows = []
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if "\t" in line:
            rows.append(tuple(line.split("\t", 1)))
    return rows


def check(lang, en, xx, rows):
    """Return (examined, failures) for one locale."""
    examined, fails = 0, []
    for sub, ans in computed:
        for k, v in sorted(en.items()):
            if sub not in v:
                continue
            shown = xx.get(k, "")
            if not shown:
                continue  # the locale has no value for this key: not a prompt it can show
            examined += 1
            hit = next(((rs, ra) for rs, ra in rows if rs in shown), None)
            if hit is None:
                if sub in shown:
                    continue  # untranslated: the driver's built-in row still matches
                fails.append("%s: %s (%r -> %r) has NO answer row" % (lang, k, sub, ans))
            elif hit[1] != ans:
                fails.append("%s: %s answered %r, driver answers %r" % (lang, k, hit[1], ans))
    return examined, fails


langs = sorted(os.path.basename(p)[len("install.sh.strings."):-3]
               for p in glob.glob(os.path.join(REPO, "install.sh.strings.*.sh")))
langs = [l for l in langs if l != BASE]
if len(langs) < 10:
    cannot_run("only %d locales found: %s" % (len(langs), langs))
en = catalogue(os.path.join(REPO, "install.sh.strings.%s.sh" % BASE))

PASS = FAIL = 0


def arm(name, ok):
    global PASS, FAIL
    print("  [%s] %s" % ("PASS" if ok else "FAIL", name))
    if ok:
        PASS += 1
    else:
        FAIL += 1


_cache = {}


def catalog_cache_get(lang):
    if lang not in _cache:
        _cache[lang] = catalogue(os.path.join(REPO, "install.sh.strings.%s.sh" % lang))
    return _cache[lang]


def run_all(gen, tag):
    total, allfails, files = 0, [], {}
    for lang in langs:
        out = os.path.join(TMP, "%s.%s.tsv" % (tag, lang))
        generate(gen, lang, out)
        files[lang] = out
        n, fails = check(lang, en, catalog_cache_get(lang), rows_of(out))
        total += n
        allfails += fails
    return total, allfails, files


print("== real generator: %s" % GEN)
total, fails, files = run_all(GEN, "real")
print("  examined %d (computed prompt x catalogue key) pairs over %d locales" % (total, len(langs)))
for f in fails:
    print("    MISSING " + f)
arm("every computed driver answer has a matching row in every locale (%d pairs, %d locales)" % (total, len(langs)), not fails and total > 0)
arm("denominator is not trivial (>= 7 computed prompts x %d locales)" % len(langs), total >= 7 * len(langs))

if "ja" in files:
    rows = rows_of(files["ja"])
    fb = catalog_cache_get("ja")["MSG_PROMPT_USER_NAME_FALLBACK_TITLE"]
    arm("ja: the typed-name fallback prompt is answered @owner_name", any(r[0] in fb and r[1] == "@owner_name" for r in rows))

if os.environ.get("GEN"):
    print("== GEN override in use: controls skipped")
else:
    print("== controls (each must turn the check red)")
    src = open(GEN, encoding="utf-8").read()
    if "all_keys = is_computed" not in src:
        cannot_run("mutant anchor 'all_keys = is_computed' not found in the generator")
    mut = os.path.join(TMP, "gen_mutant_first_key_only.py")
    open(mut, "w", encoding="utf-8").write(src.replace("all_keys = is_computed", "all_keys = False"))
    mt, mf, _ = run_all(mut, "mut")
    arm("MUST-FAIL generator maps only the first key (pre-fix behaviour): %d missing" % len(mf), len(mf) > 0)
    if "ja" in files:
        fb = catalog_cache_get("ja")["MSG_PROMPT_USER_NAME_FALLBACK_TITLE"]
        base_rows = rows_of(files["ja"])
        dropped = [r for r in base_rows if not (r[0] in fb and r[1] == "@owner_name")]
        if len(dropped) == len(base_rows):
            cannot_run("control did not apply: no fallback-name row to delete")
        _, f2 = check("ja", en, catalog_cache_get("ja"), dropped)
        arm("MUST-FAIL a ja file with the fallback-name row deleted: %d missing" % len(f2), len(f2) > 0)
        wrong = [(r[0], "") if (r[0] in fb and r[1] == "@owner_name") else r for r in base_rows]
        _, f3 = check("ja", en, catalog_cache_get("ja"), wrong)
        arm("MUST-FAIL a ja file answering the fallback-name prompt with Enter: %d wrong" % len(f3), len(f3) > 0)

print("%d pass, %d fail" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
