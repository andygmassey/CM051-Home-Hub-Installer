#!/usr/bin/env python3
"""A legal or consent translation ships ONLY when it is reviewed, English prevailing.

Andy, 2026-10-24: "yes, localisation with English prevails." (This replaces the
2026-10-22 ruling that every legal string stays English.) Conditions:

  1. Per key: a legal unit's translation is in a shipped catalogue only with a
     CURRENT l10n/legal_reviews.tsv row (same English hash) for that language.
  2. Per surface: and only when the "English version prevails" line
     (config legal_prevails_keys) is reviewed for that language too; until
     then every legal key of that language is English.
  3. A localised legal surface shows the prevails line (install.sh prints it
     before every legal prompt when it is translated).
  4. The consent record names the language and the review row ids shown.

Part A reads the REAL shipped catalogues: every legal unit that differs from
its English must pass l10n/ostler_l10n.LegalGate. Mutants prove it can fail.

Part B is end to end on a COPY of the real catalogues and the real tool:
review the prevails line for zh-Hans (a synthetic test row), run `stale`, and
the real install.sh strings loader then renders the real reviewed Chinese for
MSG_TERMS_PERSONAL_USE_LEGAL and prints the prevails line; the consent display
helper records the matching review row id. Then DELETE that key's review row:
`check` goes red, `stale` puts the English back, the loader renders English and
the record no longer names the row (red, then green).
"""
import importlib.util
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("ostler_l10n", ROOT / "l10n" / "ostler_l10n.py")
L = importlib.util.module_from_spec(spec)
spec.loader.exec_module(L)

FAILS = []


def check(name, cond, detail=""):
    print(f"  {'ok  ' if cond else 'FAIL'} {name}" + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        FAILS.append(name)


# ------------------------------------------------------------------- Part A

def violations(cfg, read=None, gate=None):
    gate = gate or L.LegalGate(cfg)
    bad, legal_seen = [], 0
    for c in L.catalogues(cfg):
        units = {u.key: u for u in c.units()}
        for lang in cfg["languages"]:
            tr = (read or (lambda cat, lg: cat.read(lg)))(c, lang)
            for k, u in units.items():
                if not L.is_legal(u, cfg):
                    continue
                legal_seen += 1
                v = tr.get(k)
                if v is not None and v != u.src and not gate.ships(lang, u):
                    bad.append(f"{c.id} {lang} {k}")
    return bad, legal_seen


def part_a():
    print("Part A: the real shipped catalogues")
    cfg, _ = L.load_config()
    gate = L.LegalGate(cfg)
    bad, seen = violations(cfg, gate=gate)
    print(f"  legal-class unit checks: {seen} across {len(cfg['languages'])} languages; unreviewed translations: {len(bad)}")
    check("some legal units examined (predicate matches)", seen > 0)
    check("no unreviewed legal translation ships", not bad, "; ".join(bad[:5]))
    check("legal_english_only is off (2026-10-24 ruling)", not cfg.get("legal_english_only"))
    check("every legal_prevails_keys entry is a real legal unit",
          gate.prevails and not gate.missing_prevails() and all(L.is_legal(gate.units[p], cfg) for p in gate.prevails),
          str(gate.missing_prevails()))
    names = [l.split("\t")[4] for l in (ROOT / "l10n" / "legal_reviews.tsv").read_text(encoding="utf-8").splitlines()[1:] if l.count("\t") >= 4]
    check("reviewers recorded by role, never a personal name",
          all(re.fullmatch(r"R\d\d|legal reviewer( \([A-Za-z-]+\))?|legal reviewer \(test\)", n.strip()) for n in names),
          str(sorted({n for n in names if not re.fullmatch(r"R\d\d|legal reviewer( \([A-Za-z-]+\))?", n.strip())})[:3]))

    c0 = next(c for c in L.catalogues(cfg) if c.id == "install_sh")
    legal_k = next(u.key for u in c0.units() if L.is_legal(u, cfg))
    plain_k = next(u.key for u in c0.units() if not L.is_legal(u, cfg))
    lang0 = cfg["languages"][0]

    def mutate(key):
        def read(cat, lg):
            tr = dict(cat.read(lg))
            if cat.id == c0.id and lg == lang0:
                tr[key] = "MUTANT"
            return tr
        return read
    check("mutant: an unreviewed legal translation is caught", len(violations(cfg, mutate(legal_k), gate)[0]) == len(bad) + 1)
    check("mutant: a translated non-legal string is not flagged", violations(cfg, mutate(plain_k), gate)[0] == bad)


# ------------------------------------------------------------------- Part B

KEY = "MSG_TERMS_PERSONAL_USE_LEGAL"
LANG = "zh-Hans"
PREVAILS_ZH = "本文为译文。如与英文版本有任何不一致，以英文版本为准。"


def loader(tmp):
    """Run install.sh's REAL strings-catalogue block (Rule 0.9 header to the
    progress-emitter header) under /bin/bash with SCRIPT_DIR = the copy."""
    src = (ROOT / "install.sh").read_text(encoding="utf-8")
    a = src.index("# ── Strings catalogue (Rule 0.9)")
    b = src.index("# ── GUI progress emitter (sourced)")
    script = (f'SCRIPT_DIR="{tmp}"\nOSTLER_LANG="{LANG}"\n' + src[a:b] +
              f'\nprintf "VALUE=%s\\n" "${KEY}"\nprintf "LOCALISED=%s\\n" "$OSTLER_LEGAL_LOCALISED"\n'
              'printf "NOTE<<\\n"; legal_prevails_note; printf ">>\\n"\n')
    bash = "/bin/bash" if os.path.exists("/bin/bash") else shutil.which("bash")
    r = subprocess.run([bash, "-c", script], capture_output=True, text=True)
    out = r.stdout
    val = re.search(r"^VALUE=(.*)$", out, re.M)
    loc = re.search(r"^LOCALISED=(.*)$", out, re.M)
    note = re.search(r"NOTE<<\n(.*?)>>", out, re.S)
    return (val.group(1) if val else None, loc.group(1) if loc else None,
            note.group(1).strip() if note else None, r.returncode, r.stderr[-300:])


def tool(tmp, *args):
    r = subprocess.run([sys.executable, "-I", str(tmp / "l10n" / "ostler_l10n.py"), *args], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def display(tmp, posture):
    reg = {"schema_version": 1, "records": {"personal_use_only": {
        "tickbox_id": "personal_use_only", "wording_hash": "0" * 64, "wording_text": "English wording",
        "wording_version": "v1", "decision": "accepted", "timestamp": "2026-10-24T00:00:00Z"}}}
    posture.mkdir(exist_ok=True)
    (posture / "consent.json").write_text(json.dumps(reg), encoding="utf-8")
    r = subprocess.run([sys.executable, "-I", str(ROOT / "lib" / "ostler_consent_display.py"), "--posture", str(posture),
                        "--tickbox", "personal_use_only", "--lang", LANG, "--resources", str(tmp / "res")],
                       capture_output=True, text=True)
    rec = json.loads((posture / "consent.json").read_text(encoding="utf-8"))["records"]["personal_use_only"]
    return r.returncode, rec


def part_b():
    print("Part B: end to end on a copy (real tool, real catalogues, real install.sh loader)")
    cfg, _ = L.load_config()
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="legal-e2e-"))
    try:
        shutil.copytree(ROOT / "l10n", tmp / "l10n")
        for c in cfg["catalogues"]:
            for p in [c["source"]] + [c["target"].format(lang=lg) for lg in cfg["languages"]]:
                if (ROOT / p).exists():
                    (tmp / p).parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(ROOT / p, tmp / p)
        u = {x.uid: x for c in L.catalogues(cfg) for x in c.units()}
        key_u = u[f"install_sh::{KEY}"]
        reviews = L.load_reviews(cfg)
        check(f"precondition: {LANG} {KEY} has a current real review row", L.reviewed(reviews, LANG, key_u))
        pend = json.loads((tmp / "l10n" / "legal_pending" / f"{LANG}.json").read_text(encoding="utf-8"))
        zh_text = pend.get(key_u.uid, {}).get("text")
        check(f"precondition: its reviewed Chinese waits in legal_pending", bool(zh_text) and zh_text != key_u.src)

        v, loc, note, rc, err = loader(tmp)
        check("before: the loader renders English (prevails line unreviewed)", v == key_u.src and loc == "0" and note == "", err)

        # review the English-prevails line for zh-Hans (synthetic test row, both catalogues)
        rows, pend_add = [], {}
        for uid in L.LegalGate(cfg).prevails:
            pu = u[uid]
            cat, k = uid.split("::", 1)
            rows.append(f"{LANG}\t{cat}\t{k}\t{L.h(pu.src)}\tlegal reviewer (test)\t2026-10-24\treviewed\n")
            pend_add[uid] = {"text": PREVAILS_ZH, "src_hash": L.h(pu.src), "src": pu.src}
        rv = tmp / "l10n" / "legal_reviews.tsv"
        rv.write_text(rv.read_text(encoding="utf-8") + "".join(rows), encoding="utf-8")
        pend.update(pend_add)
        (tmp / "l10n" / "legal_pending" / f"{LANG}.json").write_text(json.dumps(pend, ensure_ascii=False), encoding="utf-8")
        rc, out = tool(tmp, "stale")
        check("stale promotes the reviewed translations", rc == 0 and re.search(r"[1-9]\d* reviewed legal/consent translation\(s\) promoted", out), out[-300:])
        rc, out = tool(tmp, "check")
        check("check passes with reviewed legal translations shipping", rc == 0, out[-400:])

        v, loc, note, rc, err = loader(tmp)
        check("after review: the loader renders the reviewed Chinese", v == zh_text, f"{v!r} {err}")
        check("after review: the surface is marked localised", loc == "1")
        check("after review: the prevails line is printed before legal prompts", note == PREVAILS_ZH, repr(note))

        # consent record: language + the review row id, same string as the tool's review_id()
        res = tmp / "res"
        res.mkdir()
        for f in tmp.glob("install.sh.strings.*.sh"):
            shutil.copy2(f, res / f.name)
        for f in (tmp / "gui/OstlerInstaller/Resources").glob("ViewCopy*.json"):
            shutil.copy2(f, res / f.name)
        want = L.review_id(LANG, key_u)
        rc, rec = display(tmp, tmp / "posture")
        check("consent record: helper exits 0", rc == 0)
        check("consent record: display_language", rec.get("display_language") == LANG)
        check("consent record: names the review row of the translated line", want in rec.get("display_review_ids", []),
              f"{want} not in {rec.get('display_review_ids')}")
        check("consent record: names the prevails line's row too",
              L.review_id(LANG, u["install_sh::MSG_LEGAL_ENGLISH_PREVAILS"]) in rec.get("display_review_ids", []))
        row_ids = {f"{f[0]}/{f[1]}::{f[2]}@{f[3]}" for f in (l.split("\t") for l in rv.read_text(encoding="utf-8").splitlines()[1:]) if len(f) >= 6}
        check("consent record: every id it names is a row in legal_reviews.tsv",
              rec.get("display_review_ids") and set(rec["display_review_ids"]) <= row_ids,
              str(set(rec.get("display_review_ids", [])) - row_ids))
        check("consent record: binding wording untouched (English prevails)", rec.get("wording_text") == "English wording")

        # MUTANT: delete this key's review row -> red, then stale -> English -> green
        rv.write_text("".join(l for l in rv.read_text(encoding="utf-8").splitlines(True)
                              if not (l.startswith(f"{LANG}\t") and f"\t{KEY}\t" in l)), encoding="utf-8")
        rc, out = tool(tmp, "check")
        check("MUTANT row deleted: check goes RED", rc == 1 and KEY in out, out[-300:])
        rc, out = tool(tmp, "stale")
        rc2, out2 = tool(tmp, "check")
        check("MUTANT row deleted: after stale, check is GREEN", rc == 0 and rc2 == 0, out2[-300:])
        v, loc, note, rc, err = loader(tmp)
        check("MUTANT row deleted: that key renders ENGLISH", v == key_u.src, repr(v))
        check("MUTANT row deleted: the rest of the surface stays localised", loc == "1" and note == PREVAILS_ZH)
        for f in tmp.glob("install.sh.strings.*.sh"):
            shutil.copy2(f, res / f.name)
        rc, rec = display(tmp, tmp / "posture2")
        check("MUTANT row deleted: the consent record no longer names that row", want not in rec.get("display_review_ids", ["x"]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    part_a()
    part_b()
    print("PASS" if not FAILS else f"FAIL ({len(FAILS)})")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
