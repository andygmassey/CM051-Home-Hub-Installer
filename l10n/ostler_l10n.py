#!/usr/bin/env python3
"""ostler_l10n -- one tool for every Ostler string catalogue.

English is the source of truth. Translations are derived, reviewed, and may be
missing: every catalogue type here falls back to English at run time, so a
missing translation never blocks a PR or a cut.

    python3 l10n/ostler_l10n.py check          # OFFLINE gate (PR CI). exit 1 = blocking defect
    python3 l10n/ostler_l10n.py stale          # OFFLINE: revert translations whose English changed
    python3 l10n/ostler_l10n.py diff           # OFFLINE: what a run would send, and its estimated cost
    python3 l10n/ostler_l10n.py run            # ONLINE: diff -> translate -> review -> validate -> write
    python3 l10n/ostler_l10n.py adopt          # record current translations as made from current English
    python3 l10n/ostler_l10n.py self-test      # prove the gates fail on a mutant

Only `run` touches the network, and only for NEW or CHANGED English strings
(keyed by a hash of the source text). The API key is read from
$ANTHROPIC_API_KEY or the file named by $OSTLER_L10N_KEY_FILE, never printed.

Canonical copy: CM051-Home-Hub-Installer/l10n/ostler_l10n.py. Other repos vendor
it byte-for-byte (see l10n/VENDORED_FROM there). Stdlib only, except `run`,
which needs the `anthropic` package.
"""
import collections, copy, datetime, hashlib, json, os, re, shutil, subprocess, sys, tempfile, time, unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# --------------------------------------------------------------------------
# A deliberately small YAML subset (stdlib has no YAML): maps, lists of
# scalars or maps, `|` block scalars, quoted or bare scalars, `#` comments.
# --------------------------------------------------------------------------

def _scalar(v):
    v = v.strip()
    if not v:
        return ""
    if v[0] in "\"'" and v[-1] == v[0]:
        return v[1:-1]
    if v in ("true", "false"):
        return v == "true"
    if re.fullmatch(r"-?\d+(\.\d+)?", v):
        return float(v) if "." in v else int(v)
    if v.startswith("[") and v.endswith("]"):
        return [_scalar(x) for x in v[1:-1].split(",") if x.strip()]
    return v


def _strip_comment(line):
    out, q = [], None
    for i, c in enumerate(line):
        if q:
            if c == q:
                q = None
        elif c in "\"'":
            q = c
        elif c == "#" and (i == 0 or line[i - 1] in " \t"):
            break
        out.append(c)
    return "".join(out).rstrip()


def load_yaml(text):
    lines = text.split("\n")
    pos = [0]

    def indent(l):
        return len(l) - len(l.lstrip(" "))

    def skip():
        while pos[0] < len(lines) and not _strip_comment(lines[pos[0]]).strip():
            pos[0] += 1

    def block(ind):
        buf = []
        while pos[0] < len(lines):
            l = lines[pos[0]]
            if l.strip() and indent(l) < ind:
                break
            buf.append(l[ind:] if l.strip() else "")
            pos[0] += 1
        while buf and not buf[-1]:
            buf.pop()
        return "\n".join(buf) + "\n"

    def node(ind):
        skip()
        if pos[0] >= len(lines):
            return None
        first = _strip_comment(lines[pos[0]])
        if first.lstrip().startswith("- "):
            return seq(indent(first))
        return mapping(indent(first))

    def value_after(rest, ind):
        rest = rest.strip()
        if rest == "|":
            skip_blank = pos[0]
            nxt = pos[0]
            while nxt < len(lines) and not lines[nxt].strip():
                nxt += 1
            return block(indent(lines[nxt]) if nxt < len(lines) else ind + 2)
        if rest == "":
            skip()
            if pos[0] < len(lines) and indent(lines[pos[0]]) > ind:
                return node(indent(lines[pos[0]]))
            if pos[0] < len(lines) and indent(lines[pos[0]]) == ind and _strip_comment(lines[pos[0]]).lstrip().startswith("- "):
                return seq(ind)
            return None
        return _scalar(rest)

    def mapping(ind):
        out = {}
        while True:
            skip()
            if pos[0] >= len(lines):
                return out
            l = _strip_comment(lines[pos[0]])
            if indent(l) != ind or l.lstrip().startswith("- "):
                return out
            m = re.match(r"\s*([^:]+?):(\s.*|)$", l)
            if not m:
                raise ValueError(f"yaml line {pos[0] + 1}: {l!r}")
            pos[0] += 1
            out[_scalar(m.group(1))] = value_after(m.group(2), ind)

    def seq(ind):
        out = []
        while True:
            skip()
            if pos[0] >= len(lines):
                return out
            l = _strip_comment(lines[pos[0]])
            if indent(l) != ind or not l.lstrip().startswith("- "):
                return out
            body = l.lstrip()[2:]
            if re.match(r"[^:\"']+:(\s|$)", body):
                lines[pos[0]] = " " * (ind + 2) + body
                out.append(mapping(ind + 2))
            else:
                pos[0] += 1
                out.append(_scalar(body))
    return node(0) or {}


def load_config():
    cfg = load_yaml(open(os.path.join(HERE, "config.yaml"), encoding="utf-8").read())
    gl = load_yaml(open(os.path.join(HERE, "glossary.yaml"), encoding="utf-8").read())
    return cfg, gl

# --------------------------------------------------------------------------
# Units and catalogue adapters
# --------------------------------------------------------------------------

SPEC = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaA%]|\{[a-zA-Z_][a-zA-Z0-9_]*\}")


def h(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()[:12]


def has_letters(s):
    return bool(re.search(r"[A-Za-z]{2,}", s))


class Unit:
    __slots__ = ("cat", "key", "src", "ctx", "kind")

    def __init__(self, cat, key, src, ctx, kind):
        self.cat, self.key, self.src, self.ctx, self.kind = cat, key, src, ctx, kind

    @property
    def uid(self):
        return f"{self.cat}::{self.key}"


def _sh_parse(text):
    out, comment, pos, n = [], [], 0, len(text)
    while pos < n:
        eol = text.find("\n", pos)
        eol = n if eol == -1 else eol
        line = text[pos:eol]
        m = re.match(r"(MSG_[A-Z0-9_]+)=\"", line)
        if line.startswith("#"):
            comment.append(line.lstrip("# "))
            pos = eol + 1
            continue
        if m:
            start = pos + len(m.group(1)) + 1
            j = start + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    break
                j += 1
            out.append((m.group(1), start, j + 1, " ".join(comment)[-400:]))
            comment = []
            e2 = text.find("\n", j)
            pos = n if e2 == -1 else e2 + 1
            continue
        if not line.strip():
            comment = []
        pos = eol + 1
    return out


def _sh_unquote(lit):
    return re.sub(r'\\([\\"$`\n])', lambda m: "" if m.group(1) == "\n" else m.group(1), lit[1:-1])


def _sh_quote(v):
    return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`") + '"'


class ShellCatalogue:
    """install.sh.strings.<lang>.sh: MSG_KEY="value" assignments sourced by bash.
    Fallback: a key missing from the language file is never missing at run
    time, because the writer always emits the full key set, English where
    there is no current translation; a missing FILE falls back to en-GB in
    install.sh's loader."""

    def __init__(self, spec):
        self.id, self.spec = spec["id"], spec

    def path(self, lang=None):
        return os.path.join(REPO, self.spec["source"] if lang is None else self.spec["target"].format(lang=lang))

    def units(self):
        text = open(self.path(), encoding="utf-8").read()
        for key, s, e, c in _sh_parse(text):
            v = _sh_unquote(text[s:e])
            if has_letters(v):
                yield Unit(self.id, key, v, c, "shell")

    def read(self, lang):
        p = self.path(lang)
        if not os.path.exists(p):
            return {}
        text = open(p, encoding="utf-8").read()
        return {k: _sh_unquote(text[s:e]) for k, s, e, _ in _sh_parse(text)}

    def flags(self, lang):
        p = self.path(lang)
        if not os.path.exists(p):
            return {}
        out, pend = {}, None
        for line in open(p, encoding="utf-8"):
            if line.startswith("# NEEDS REVIEW:"):
                pend = line[len("# NEEDS REVIEW:"):].strip()
                continue
            m = re.match(r"(MSG_[A-Z0-9_]+)=", line)
            if m and pend is not None:
                out[m.group(1)] = pend
            if m:
                pend = None
        return out

    def write(self, lang, values, flags):
        text = open(self.path(), encoding="utf-8").read()
        out, pos = [], 0
        for key, s, e, _ in _sh_parse(text):
            chunk = text[pos:s]
            if key in flags:
                ls = chunk.rfind("\n") + 1
                chunk = chunk[:ls] + f"# NEEDS REVIEW: {flags[key][:160]}\n" + chunk[ls:]
            out.append(chunk)
            out.append(_sh_quote(values[key]) if key in values else text[s:e])
            pos = e
        out.append(text[pos:])
        body = "".join(out)
        if body.startswith("#!"):
            body = body[body.index("\n") + 1:]
        hdr = (f"#!/usr/bin/env bash\n# {self.spec['source']} translated to {lang} by l10n/ostler_l10n.py.\n"
               "# Generated: edit the en-GB source, never this file. '# NEEDS REVIEW' marks a key\n"
               "# awaiting a native speaker; a key with no current translation carries English.\n")
        open(self.path(lang), "w", encoding="utf-8").write(hdr + body)

    def validate_file(self, lang):
        p = self.path(lang)
        if not os.path.exists(p):
            return []
        r = subprocess.run(["/bin/bash", "-n", p], capture_output=True, text=True)
        return [f"{os.path.relpath(p, REPO)}: bash -n: {r.stderr.strip()[:200]}"] if r.returncode else []


class JsonTreeCatalogue:
    """ViewCopy.json / HintCopy.json: a nested tree; translation is a parallel
    <stem>.<lang>.json with the identical shape. Fallback: the GUI loaders read
    the English file and overlay the translation per key (ViewCopy) or per step
    (HintCopy), so anything missing renders English."""

    def __init__(self, spec):
        self.id, self.spec = spec["id"], spec
        self.skip = set(spec.get("skip_fields", []))

    def path(self, lang=None):
        return os.path.join(REPO, self.spec["source"] if lang is None else self.spec["target"].format(lang=lang))

    def _walk(self, x, p, meta, all_text=False):
        if isinstance(x, str):
            if p and p[-1] not in self.skip and (all_text or has_letters(x)):
                yield "/".join(map(str, p)), x, meta
        elif isinstance(x, dict):
            m2 = x["_meta"] if isinstance(x.get("_meta"), str) else meta
            for k, v in x.items():
                if not k.startswith("_"):
                    yield from self._walk(v, p + [k], m2, all_text)
        elif isinstance(x, list):
            for i, v in enumerate(x):
                yield from self._walk(v, p + [i], meta, all_text)

    def units(self):
        for k, v, meta in self._walk(json.load(open(self.path(), encoding="utf-8")), [], ""):
            yield Unit(self.id, k, v, meta[:300], "json")

    def read(self, lang):
        p = self.path(lang)
        if not os.path.exists(p):
            return {}
        return {k: v for k, v, _ in self._walk(json.load(open(p, encoding="utf-8")), [], "", True)}

    def flags(self, lang):
        p = os.path.join(HERE, f"REVIEW_FLAGS.{lang}.tsv")
        out = {}
        if os.path.exists(p):
            for line in open(p, encoding="utf-8").read().splitlines()[1:]:
                f = line.split("\t")
                if len(f) >= 4 and f[0] == self.spec["source"] and f[2] == "needs_review":
                    out[f[1]] = f[3]
        return out

    def write(self, lang, values, flags):
        def walk(x, p):
            if isinstance(x, str):
                k = "/".join(map(str, p))
                return values.get(k, x)
            if isinstance(x, dict):
                return {kk: (vv if kk.startswith("_") else walk(vv, p + [kk])) for kk, vv in x.items()}
            if isinstance(x, list):
                return [walk(v, p + [i]) for i, v in enumerate(x)]
            return x
        d = walk(json.load(open(self.path(), encoding="utf-8")), [])
        with open(self.path(lang), "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, indent=2)
            f.write("\n")
        _write_flag_rows(lang, self.spec["source"], flags)

    def validate_file(self, lang):
        p = self.path(lang)
        if not os.path.exists(p):
            return []
        try:
            tr = json.load(open(p, encoding="utf-8"))
        except Exception as e:
            return [f"{os.path.relpath(p, REPO)}: invalid JSON: {e}"]
        base = json.load(open(self.path(), encoding="utf-8"))
        errs = []

        def cmp(a, b, path):
            if type(a) != type(b):
                errs.append(f"{os.path.relpath(p, REPO)} {path}: type changed")
            elif isinstance(a, dict):
                if set(a) != set(b):
                    errs.append(f"{os.path.relpath(p, REPO)} {path}: keys differ from English")
                for k in a:
                    if k in b:
                        cmp(a[k], b[k], f"{path}/{k}")
            elif isinstance(a, list):
                if len(a) != len(b):
                    errs.append(f"{os.path.relpath(p, REPO)} {path}: list length differs")
                for i, (x, y) in enumerate(zip(a, b)):
                    cmp(x, y, f"{path}[{i}]")
            elif not isinstance(a, str) and a != b:
                errs.append(f"{os.path.relpath(p, REPO)} {path}: non-text value changed")
        cmp(base, tr, "")
        return errs


def _write_flag_rows(lang, source, flags):
    p = os.path.join(HERE, f"REVIEW_FLAGS.{lang}.tsv")
    rows = []
    if os.path.exists(p):
        rows = [l for l in open(p, encoding="utf-8").read().splitlines()[1:] if not l.startswith(source + "\t")]
    rows += [f"{source}\t{k}\tneeds_review\t{v.replace(chr(9), ' ').replace(chr(10), ' ')}" for k, v in sorted(flags.items())]
    open(p, "w", encoding="utf-8").write("file\tkey\tstate\treason\n" + "\n".join(rows) + ("\n" if rows else ""))


class XcstringsCatalogue:
    """Apple string catalogue (.xcstrings). Fallback is native: a language with no
    localisation for a key shows the development-language value."""

    def __init__(self, spec):
        self.id, self.spec = spec["id"], spec
        self.src_lang = spec.get("source_language", "en")

    def path(self, lang=None):
        return os.path.join(REPO, self.spec["source"])

    def _load(self):
        return json.load(open(self.path(), encoding="utf-8"))

    def _referenced(self):
        roots = self.spec.get("swift_roots")
        if not roots:
            return None
        buf = []
        for r in roots:
            for dp, _, fs in os.walk(os.path.join(REPO, r)):
                buf += [open(os.path.join(dp, f), encoding="utf-8", errors="replace").read() for f in fs if f.endswith(".swift")]
        return "\n".join(buf)

    def units(self):
        d, src = self._load(), self._referenced()
        for k, v in d["strings"].items():
            if v.get("shouldTranslate") is False:
                continue
            en = v.get("localizations", {}).get(self.src_lang, {}).get("stringUnit", {}).get("value", k)
            if not has_letters(en) or en in self.spec.get("do_not_translate", []):
                continue
            if src is not None and v.get("extractionState") == "stale":
                esc = k.replace("\\", "\\\\").replace('"', '\\"')
                if '"' + esc not in src:
                    continue
            yield Unit(self.id, k, en, v.get("comment", "")[:300], "ios")

    def read(self, lang):
        out = {}
        for k, v in self._load()["strings"].items():
            su = v.get("localizations", {}).get(lang, {}).get("stringUnit")
            if su and "value" in su:
                out[k] = su["value"]
        return out

    def flags(self, lang):
        return {k: "needs_review" for k, v in self._load()["strings"].items()
                if v.get("localizations", {}).get(lang, {}).get("stringUnit", {}).get("state") == "needs_review"}

    def write(self, lang, values, flags, drop=()):
        raw = open(self.path(), encoding="utf-8").read()
        d = json.loads(raw)
        for k, v in values.items():
            e = d["strings"].setdefault(k, {"extractionState": "manual", "localizations": {
                self.src_lang: {"stringUnit": {"state": "translated", "value": k}}}})
            locs = e.setdefault("localizations", {})
            locs[lang] = {"stringUnit": {"state": "needs_review" if k in flags else "translated", "value": v}}
            e["localizations"] = dict(sorted(locs.items()))
        for k in drop:
            if k in d["strings"]:
                d["strings"][k].get("localizations", {}).pop(lang, None)
        s = json.dumps(d, indent=2, separators=(",", " : "), ensure_ascii=False)
        s = re.sub(r'^(\s*)("(?:[^"\\]|\\.)*" : )\{\}(,?)$', lambda m: f"{m.group(1)}{m.group(2)}{{\n\n{m.group(1)}}}{m.group(3)}", s, flags=re.M)
        open(self.path(), "w", encoding="utf-8").write(s + ("\n" if raw.endswith("\n") else ""))

    def validate_file(self, lang):
        try:
            self._load()
        except Exception as e:
            return [f"{self.spec['source']}: invalid JSON: {e}"]
        return []


ADAPTERS = {"shell": ShellCatalogue, "json-tree": JsonTreeCatalogue, "xcstrings": XcstringsCatalogue}


def catalogues(cfg):
    return [ADAPTERS[c["type"]](c) for c in cfg["catalogues"]]

# --------------------------------------------------------------------------
# Provenance: which English text each translation was made from
# --------------------------------------------------------------------------

STATE = os.path.join(HERE, "provenance.json")  # not state.json: the repo .gitignore swallows that name


def load_state():
    return json.load(open(STATE, encoding="utf-8")) if os.path.exists(STATE) else {"version": 1, "made_from": {}}


def save_state(st):
    for lang in st["made_from"]:
        st["made_from"][lang] = dict(sorted(st["made_from"][lang].items()))
    with open(STATE, "w", encoding="utf-8") as f:
        json.dump(st, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write("\n")

# --------------------------------------------------------------------------
# Mechanical checks (the BLOCKING part of the gate)
# --------------------------------------------------------------------------

YN = re.compile(r"\(y/n\)|\(Y/n\)|\(y/N\)|Y / N|Y/N|\[y/N\]|\[Y/n\]")
LIT = re.compile(r"https?://\S+|[\w.+-]+@[\w-]+\.[\w.]+|~/\S+|\b(?:127\.0\.0\.1|localhost):\d+")


def mech(u, out, cfg):
    src, errs = u.src, []
    a, b = SPEC.findall(src), SPEC.findall(out)
    if collections.Counter(a) != collections.Counter(b):
        errs.append(f"placeholders {a} -> {b}")
    elif [x for x in a if x[0] == "%" and "$" not in x] != [x for x in b if x[0] == "%" and "$" not in x]:
        errs.append("non-positional placeholder order changed")
    if u.kind == "shell" and any("$" in x for x in b if x.startswith("%")):
        errs.append("positional printf specifier in a bash string (bash printf has none)")
    if "—" in out:
        errs.append("em dash")
    if src.count("\n") != out.count("\n"):
        errs.append("line-break count")
    if src[: len(src) - len(src.lstrip())] != out[: len(out) - len(out.lstrip())] or src[len(src.rstrip()):] != out[len(out.rstrip()):]:
        errs.append("leading/trailing whitespace")
    for tok in cfg.get("verbatim_tokens", []):
        bounded = re.compile(r"(?<![A-Za-z])" + re.escape(tok) + r"(?![A-Za-z])")
        if bounded.search(src) and not bounded.search(out):
            errs.append(f"verbatim token {tok!r} lost")
    for m in YN.findall(src):
        if m not in out:
            errs.append(f"y/n cue {m!r} lost")
    for m in LIT.findall(src):
        m = m.rstrip(".,;:)")
        if m not in out:
            errs.append(f"literal {m!r} lost")
    if not out.strip():
        errs.append("empty")
    return errs


def width(s):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def survey(cfg):
    """Return (blocking errors, stale list, coverage table)."""
    st = load_state()
    errs, stale, cov = [], [], {}
    keep = set(cfg.get("keep_english", []))
    for c in catalogues(cfg):
        units = {u.key: u for u in c.units()}
        for lang in cfg["languages"]:
            errs += c.validate_file(lang)
            tr = c.read(lang)
            made = st["made_from"].get(lang, {})
            n = cov.setdefault(lang, collections.Counter())
            n["source"] += len(units)
            for k, u in units.items():
                v = tr.get(k)
                current = made.get(u.uid) == h(u.src)
                if v is None or (v == u.src and not current):
                    n["english"] += 1
                    continue
                if v == u.src:
                    n["translated"] += 1  # reviewed, and the right answer is the English (a brand, "OK")
                    continue
                if k in keep:
                    errs.append(f"{c.id} {lang} {k}: must stay English (keep_english)")
                    continue
                for e in mech(u, v, cfg):
                    errs.append(f"{c.id} {lang} {k}: {e}")
                if made.get(u.uid) != h(u.src):
                    stale.append((c, lang, k))
                    n["stale"] += 1
                else:
                    n["translated"] += 1
            if c.spec["type"] == "shell" and os.path.exists(c.path(lang)):
                missing = set(units) - set(tr)
                if missing:
                    errs.append(f"{c.id} {lang}: {len(missing)} keys missing from the file (run `stale` to rewrite it)")
    return errs, stale, cov


def print_coverage(cov):
    print("coverage (non-blocking): lang  translated  english-fallback  stale  of")
    for lang, n in cov.items():
        pct = 100.0 * n["translated"] / n["source"] if n["source"] else 0
        print(f"  {lang:8} {n['translated']:6} ({pct:5.1f}%) {n['english']:6} {n['stale']:6} {n['source']:6}")


def cmd_check(cfg):
    errs, stale, cov = survey(cfg)
    print_coverage(cov)
    for c, lang, k in stale[:30]:
        errs.append(f"{c.id} {lang} {k}: English changed since this translation was made; "
                    "run `python3 l10n/ostler_l10n.py stale` (offline) to fall it back to English")
    for e in errs[:80]:
        print("FAIL: " + e)
    if len(errs) > 80:
        print(f"FAIL: ... and {len(errs) - 80} more")
    print(f"RESULT: {'FAIL' if errs else 'PASS'} ({len(errs)} blocking defects, {len(stale)} stale)")
    return 1 if errs else 0


def cmd_stale(cfg):
    """Fall stale translations back to English and rewrite shell files with the
    full key set. Offline, idempotent."""
    _, stale, _ = survey(cfg)
    st = load_state()
    by = collections.defaultdict(set)
    for c, lang, k in stale:
        by[(c.id, lang)].add(k)
    n = 0
    for c in catalogues(cfg):
        for lang in cfg["languages"]:
            ks = by.get((c.id, lang), set())
            tr, fl = c.read(lang), c.flags(lang)
            units = {u.key: u for u in c.units()}
            # a shell file missing keys is rewritten too: the writer emits the
            # full en-GB key set, English wherever there is no translation
            short = c.spec["type"] == "shell" and os.path.exists(c.path(lang)) and set(units) - set(tr)
            if not ks and not short:
                continue
            keep = {k: v for k, v in tr.items() if k in units and k not in ks and v != units[k].src}
            if c.spec["type"] == "xcstrings":
                c.write(lang, {}, {}, drop=ks)
            else:
                c.write(lang, keep, {k: v for k, v in fl.items() if k in keep})
            for k in ks:
                st["made_from"].get(lang, {}).pop(f"{c.id}::{k}", None)
            n += len(ks)
    save_state(st)
    print(f"stale: {n} translation(s) fell back to English")
    return 0


def cmd_adopt(cfg):
    st = load_state()
    n = 0
    for c in catalogues(cfg):
        for lang in cfg["languages"]:
            tr = c.read(lang)
            for u in c.units():
                if u.key in tr and tr[u.key] != u.src:
                    st["made_from"].setdefault(lang, {})[u.uid] = h(u.src)
                    n += 1
    save_state(st)
    print(f"adopt: recorded {n} translations as made from the current English")
    return 0

# --------------------------------------------------------------------------
# diff + run (the only network path)
# --------------------------------------------------------------------------

def pending(cfg):
    """(lang, Unit) pairs with no current translation."""
    _, stale, _ = survey(cfg)
    stale_set = {(c.id, lang, k) for c, lang, k in stale}
    st = load_state()
    keep = set(cfg.get("keep_english", []))
    out = []
    for c in catalogues(cfg):
        units = list(c.units())
        for lang in cfg["languages"]:
            tr = c.read(lang)
            made = st["made_from"].get(lang, {})
            for u in units:
                if u.key in keep:
                    continue
                if (c.id, lang, u.key) in stale_set or made.get(u.uid) != h(u.src):
                    out.append((lang, u))
    return out


PRICE = {"claude-sonnet-5-5": (2.0, 10.0, 0.1), "claude-opus-5-5": (4.0, 20.0, 0.05)}


def estimate(cfg, todo):
    chars = sum(len(u.src) + min(len(u.ctx), 400) + 80 for _, u in todo)
    tin, tout = chars / 3.2, chars / 2.0 * 2
    t, r = cfg["models"]["translate"], cfg["models"]["review"]
    cost = 0.5 * (tin * PRICE[t][0] + tout * PRICE[t][1]) / 1e6 + 0.5 * (tin * 1.6 * PRICE[r][0] + tout * 0.8 * PRICE[r][1]) / 1e6
    return cost


def cmd_diff(cfg):
    todo = pending(cfg)
    c = collections.Counter(l for l, _ in todo)
    print("pending translations per language:", dict(c) or "none")
    print(f"estimated cost of a run (batch, translate+review): ${estimate(cfg, todo):.2f}  (cap ${cfg['budget_usd']})")
    return 0


def _system(gl, review):
    text = gl["rules"] + "\n# Register per language\n" + "".join(f"- {k}: {v}\n" for k, v in gl["register"].items())
    if review:
        text += "\n" + gl["review_rules"]
    return [{"type": "text", "text": text, "cache_control": {"type": "ephemeral"}}]


T_SCHEMA = {"type": "object", "additionalProperties": False, "required": ["items"], "properties": {"items": {"type": "array", "items": {
    "type": "object", "additionalProperties": False, "required": ["id", "text", "note"],
    "properties": {"id": {"type": "string"}, "text": {"type": "string"}, "note": {"type": "string"}}}}}}
R_SCHEMA = {"type": "object", "additionalProperties": False, "required": ["items"], "properties": {"items": {"type": "array", "items": {
    "type": "object", "additionalProperties": False, "required": ["id", "verdict", "text", "reason"],
    "properties": {"id": {"type": "string"}, "verdict": {"type": "string", "enum": ["ok", "fix", "flag"]},
                   "text": {"type": "string"}, "reason": {"type": "string"}}}}}}


def _client():
    import anthropic
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key and os.environ.get("OSTLER_L10N_KEY_FILE"):
        key = open(os.environ["OSTLER_L10N_KEY_FILE"]).read().strip()
    if not key:
        raise SystemExit("CANNOT-RUN: no API key (ANTHROPIC_API_KEY or OSTLER_L10N_KEY_FILE)")
    return anthropic.Anthropic(api_key=key, max_retries=4)


def _batch(cl, cfg, reqs, phase, log):
    model = cfg["models"][phase]
    b = cl.messages.batches.create(requests=reqs)
    print(f"{phase}: batch {b.id}, {len(reqs)} requests", flush=True)
    while True:
        r = cl.messages.batches.retrieve(b.id)
        rc = r.request_counts
        print(f"{datetime.datetime.utcnow():%H:%M:%S} {phase} {r.processing_status} processing={rc.processing} ok={rc.succeeded} err={rc.errored}", flush=True)
        if r.processing_status == "ended":
            break
        time.sleep(60)
    out, acc = {}, collections.Counter()
    for res in cl.messages.batches.results(b.id):
        if res.result.type != "succeeded":
            continue
        m = res.result.message
        u = m.usage
        acc["in"] += u.input_tokens or 0
        acc["cw"] += getattr(u, "cache_creation_input_tokens", 0) or 0
        acc["cr"] += getattr(u, "cache_read_input_tokens", 0) or 0
        acc["out"] += u.output_tokens or 0
        if m.stop_reason != "end_turn":
            continue
        try:
            items = json.loads(next(x.text for x in m.content if x.type == "text"))["items"]
        except Exception:
            continue
        lang = res.custom_id.split("_")[1]  # custom_id must match ^[a-zA-Z0-9_-]{1,64}$
        for it in items:
            out[(lang, it["id"])] = it
    pin, pout, crm = PRICE[model]
    cost = 0.5 * (acc["in"] * pin + acc["cw"] * pin * 1.25 + acc["cr"] * pin * crm + acc["out"] * pout) / 1e6
    log(phase, model, b.id, len(reqs), acc, cost)
    return out, cost


def cmd_run(cfg, gl, dry=False):
    todo = pending(cfg)
    if not todo:
        print("run: nothing new or changed; no API call made")
        return 0
    est = estimate(cfg, todo)
    print(f"run: {len(todo)} pending translations, estimated ${est:.2f}, cap ${cfg['budget_usd']}")
    if est > cfg["budget_usd"]:
        print("REFUSED: estimate exceeds budget_usd in l10n/config.yaml")
        return 2
    if dry:
        return 0
    spend_log = os.environ.get("OSTLER_L10N_SPEND_LOG", os.path.expanduser("~/walkdriver/API_SPEND_LOG.tsv"))
    job = os.environ.get("OSTLER_L10N_JOB", f"l10n-{os.path.basename(REPO)}")

    def log(phase, model, bid, n, acc, cost):
        new = not os.path.exists(spend_log)
        if not os.path.isdir(os.path.dirname(spend_log) or "."):
            return
        with open(spend_log, "a") as f:
            if new:
                f.write("ts\tjob\tphase\tmodel\tbatch_id\trequests\tinput_tokens\tcache_write_tokens\tcache_read_tokens\toutput_tokens\tcost_usd\n")
            f.write(f"{datetime.datetime.utcnow():%Y-%m-%dT%H:%M:%SZ}\t{job}\t{phase}\t{model}\t{bid}\t{n}\t{acc['in']}\t{acc['cw']}\t{acc['cr']}\t{acc['out']}\t{cost:.4f}\n")

    cl = _client()
    ids = {f"s{i}": (lang, u) for i, (lang, u) in enumerate(todo)}
    groups = collections.defaultdict(list)
    for sid, (lang, u) in ids.items():
        groups[lang].append(sid)

    def chunks(lang):
        cur, size = [], 0
        for sid in groups[lang]:
            u = ids[sid][1]
            c = len(u.src) + min(len(u.ctx), 400)
            if cur and (len(cur) >= 40 or size + c > 7000):
                yield cur
                cur, size = [], 0
            cur.append(sid)
            size += c
        if cur:
            yield cur

    def item(sid):
        u = ids[sid][1]
        return {"id": sid, "src": u.src, "ctx": u.ctx[:400], "specs": SPEC.findall(u.src), "kind": u.kind}

    reqs = []
    for lang in groups:
        for n, ch in enumerate(chunks(lang)):
            reqs.append({"custom_id": f"t_{lang}_{n}", "params": {
                "model": cfg["models"]["translate"], "max_tokens": 32000, "system": _system(gl, False),
                "thinking": {"type": "adaptive"}, "output_config": {"effort": "medium", "format": {"type": "json_schema", "schema": T_SCHEMA}},
                "messages": [{"role": "user", "content": f"Target language: {gl['language_names'][lang]} (locale {lang}). Translate every item.\n\n"
                              + json.dumps([item(s) for s in ch], ensure_ascii=False)}]}})
    tr, c1 = _batch(cl, cfg, reqs, "translate", log)
    reqs = []
    for lang in groups:
        for n, ch in enumerate(chunks(lang)):
            items = []
            for s in ch:
                t = tr.get((lang, s))
                if not t:
                    continue
                d = item(s)
                d["translation"], d["translator_note"] = t["text"], t["note"]
                e = mech(ids[s][1], t["text"], cfg)
                if e:
                    d["automatic_check_failed"] = e
                items.append(d)
            if items:
                reqs.append({"custom_id": f"r_{lang}_{n}", "params": {
                    "model": cfg["models"]["review"], "max_tokens": 32000, "system": _system(gl, True),
                    "thinking": {"type": "adaptive"}, "output_config": {"effort": "medium", "format": {"type": "json_schema", "schema": R_SCHEMA}},
                    "messages": [{"role": "user", "content": f"Target language: {gl['language_names'][lang]} (locale {lang}). Review every item.\n\n"
                                  + json.dumps(items, ensure_ascii=False)}]}})
    rv, c2 = _batch(cl, cfg, reqs, "review", log) if reqs else ({}, 0.0)
    results = decide(cfg, ids, tr, rv)
    apply_results(cfg, results)
    print(f"run: cost ${c1 + c2:.2f}; written {sum(1 for r in results.values() if r)} of {len(ids)}")
    return cmd_check(cfg)


def decide(cfg, ids, tr, rv):
    legal = [re.compile(p, re.I) for p in cfg.get("legal_patterns", [])]
    human = set(cfg.get("human_review_keys", []))
    out = {}
    for sid, (lang, u) in ids.items():
        t, r = tr.get((lang, sid)), rv.get((lang, sid))
        if not t or not r:
            out[sid] = None  # never ship unreviewed: stays English
            continue
        cands = ([r["text"]] if r["verdict"] in ("fix", "flag") else []) + [t["text"]]
        chosen = next((c for c in cands if not mech(u, c, cfg)), None)
        if chosen is None:
            out[sid] = None
            continue
        why = r["reason"] if r["verdict"] == "flag" else ""
        if any(p.search(u.key + " " + u.ctx) for p in legal) and u.kind == "shell":
            why = why or "legal/consent wording: needs a qualified human check"
        if u.key in human:
            why = why or "source asks for human translation of this key"
        out[sid] = (chosen, why)
    out["__ids__"] = ids
    return out


def apply_results(cfg, results):
    ids = results.pop("__ids__")
    st = load_state()
    per = collections.defaultdict(lambda: ({}, {}))
    for sid, res in results.items():
        if not res:
            continue
        lang, u = ids[sid]
        vals, fl = per[(u.cat, lang)]
        vals[u.key] = res[0]
        if res[1]:
            fl[u.key] = res[1]
        st["made_from"].setdefault(lang, {})[u.uid] = h(u.src)
    for c in catalogues(cfg):
        for lang in cfg["languages"]:
            vals, fl = per.get((c.id, lang), ({}, {}))
            if not vals and not (c.spec["type"] == "shell"):
                continue
            existing = {k: v for k, v in c.read(lang).items()}
            units = {u.key: u for u in c.units()}
            old_flags = c.flags(lang)
            merged = {k: v for k, v in existing.items() if k in units and v != units[k].src}
            merged.update(vals)
            flags = {k: v for k, v in old_flags.items() if k in merged and k not in vals}
            flags.update(fl)
            if c.spec["type"] == "xcstrings":
                c.write(lang, vals, fl)
            else:
                c.write(lang, merged, flags)
    save_state(st)

# --------------------------------------------------------------------------
# self-test: the gate must fail on the defects it exists for
# --------------------------------------------------------------------------

def cmd_self_test(cfg):
    global REPO, HERE, STATE
    tmp = tempfile.mkdtemp(prefix="l10n-selftest-")
    try:
        os.makedirs(os.path.join(tmp, "l10n"))
        cat_x = {"sourceLanguage": "en", "version": "1.0", "strings": {
            "Hello %@, %lld new": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Hello %@, %lld new"}},
                                                   "de": {"stringUnit": {"state": "translated", "value": "Hallo %@, %lld neu"}}}},
            "home.title": {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Today"}},
                                             "de": {"stringUnit": {"state": "translated", "value": "Heute"}}}}}}
        json.dump(cat_x, open(os.path.join(tmp, "L.xcstrings"), "w"))
        open(os.path.join(tmp, "s.en-GB.sh"), "w").write('MSG_A="Saved to %s"\nMSG_B="Type INSTALL to go on"\n')
        open(os.path.join(tmp, "s.de.sh"), "w").write('MSG_A="Gespeichert unter %s"\nMSG_B="Gib INSTALL ein, um fortzufahren"\n')
        open(os.path.join(tmp, "l10n", "config.yaml"), "w").write(
            "languages: [de]\nbudget_usd: 1\nverbatim_tokens: [INSTALL]\nmodels:\n  translate: claude-sonnet-5-5\n  review: claude-opus-5-5\n"
            "catalogues:\n  - id: x\n    type: xcstrings\n    source: L.xcstrings\n  - id: sh\n    type: shell\n    source: s.en-GB.sh\n    target: s.{lang}.sh\n")
        REPO, HERE, STATE = tmp, os.path.join(tmp, "l10n"), os.path.join(tmp, "l10n", "provenance.json")
        c2 = load_yaml(open(os.path.join(HERE, "config.yaml")).read())
        quiet = lambda f, *a: _quiet(f, *a)
        cmd_adopt_q = quiet(cmd_adopt, c2)
        results = {}
        results["clean passes"] = quiet(cmd_check, c2) == 0
        # mutant 1: a dropped %@
        d = copy.deepcopy(cat_x)
        d["strings"]["Hello %@, %lld new"]["localizations"]["de"]["stringUnit"]["value"] = "Hallo, %lld neu"
        json.dump(d, open(os.path.join(tmp, "L.xcstrings"), "w"))
        results["dropped %@ fails"] = quiet(cmd_check, c2) == 1
        json.dump(cat_x, open(os.path.join(tmp, "L.xcstrings"), "w"))
        # mutant 2: a lost verbatim token in the shell catalogue
        open(os.path.join(tmp, "s.de.sh"), "w").write('MSG_A="Gespeichert unter %s"\nMSG_B="Gib INSTALLIEREN ein"\n')
        results["lost INSTALL fails"] = quiet(cmd_check, c2) == 1
        open(os.path.join(tmp, "s.de.sh"), "w").write('MSG_A="Gespeichert unter %s"\nMSG_B="Gib INSTALL ein, um fortzufahren"\n')
        # mutant 3: English changes under an existing translation
        d = copy.deepcopy(cat_x)
        d["strings"]["home.title"]["localizations"]["en"]["stringUnit"]["value"] = "Your day"
        json.dump(d, open(os.path.join(tmp, "L.xcstrings"), "w"))
        _, stale, _ = survey(c2)
        results["changed English is stale"] = [(c.id, l, k) for c, l, k in stale] == [("x", "de", "home.title")]
        results["stale blocks check"] = quiet(cmd_check, c2) == 1
        quiet(cmd_stale, c2)
        after = json.load(open(os.path.join(tmp, "L.xcstrings")))
        results["stale falls back to English"] = "de" not in after["strings"]["home.title"]["localizations"]
        results["check passes after stale"] = quiet(cmd_check, c2) == 0
        # yaml subset round-trip of the real config
        results["real config parses"] = bool(_REAL_CFG.get("catalogues"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for k, v in results.items():
        print(f"  {'ok  ' if v else 'FAIL'} {k}")
    ok = all(results.values())
    print(f"SELF-TEST {'PASS' if ok else 'FAIL'} ({sum(results.values())}/{len(results)})")
    return 0 if ok else 1


def _quiet(f, *a):
    import io, contextlib
    with contextlib.redirect_stdout(io.StringIO()):
        return f(*a)


_REAL_CFG = {}

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    cfg, gl = load_config()
    _REAL_CFG = cfg
    sys.exit({"check": lambda: cmd_check(cfg), "stale": lambda: cmd_stale(cfg), "diff": lambda: cmd_diff(cfg),
              "adopt": lambda: cmd_adopt(cfg), "run": lambda: cmd_run(cfg, gl, dry="--dry-run" in sys.argv),
              "self-test": lambda: cmd_self_test(cfg)}[cmd]())
