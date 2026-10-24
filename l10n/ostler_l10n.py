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
    python3 l10n/ostler_l10n.py legal-pack LANG [--out FILE]  # OFFLINE: legal review pack for one language

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

SPEC = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaA%]|\$\{[a-zA-Z_][a-zA-Z0-9_]*\}|\{[a-zA-Z_][a-zA-Z0-9_]*\}")
TAG = re.compile(r"</?[a-zA-Z][^<>]*>")


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
                if set(b) - set(a):  # fewer is fine: the loaders overlay English per key
                    errs.append(f"{os.path.relpath(p, REPO)} {path}: keys not in the English source")
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
            # Plural/device variations are hand-authored per language and have no single
            # source string: skip them, or a run would overwrite them with one stringUnit.
            if "variations" in v.get("localizations", {}).get(self.src_lang, {}):
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
            # never pop a language: a key-based entry would then render as its raw key
            e = d["strings"].get(k)
            if e:
                en = e.get("localizations", {}).get(self.src_lang, {}).get("stringUnit", {}).get("value", k)
                e.setdefault("localizations", {})[lang] = {"stringUnit": {"state": "new", "value": en}}
        self._dump(d, raw)

    def missing_fallbacks(self, languages):
        """Key-based entries (key != English) with no unit for a language.
        Apple does NOT fall back per key: once <lang>.lproj exists, a key it
        lacks renders as the RAW KEY (measured 2026-10-18, de simulator:
        'avatar.assistant.label O'). So every such entry needs a value in
        every shipped language, English if nothing better (state "new")."""
        out = []
        for k, v in self._load()["strings"].items():
            locs = v.get("localizations", {})
            en = locs.get(self.src_lang, {}).get("stringUnit", {}).get("value")
            # Literal-keyed (the key IS the English; Xcode may store it with
            # positional %1$@ forms): a missing value falls back to the key,
            # which is the English. Only a real key ("brand.name") is at risk.
            if en is None or en == k or re.sub(r"%\d+\$", "%", en) == k:
                continue
            out += [(k, l) for l in languages if "stringUnit" not in locs.get(l, {}) and "variations" not in locs.get(l, {})]
        return out

    def fill_fallbacks(self, languages):
        miss = self.missing_fallbacks(languages)
        if not miss:
            return 0
        raw = open(self.path(), encoding="utf-8").read()
        d = json.loads(raw)
        for k, l in miss:
            e = d["strings"][k]
            en = e["localizations"][self.src_lang]["stringUnit"]["value"]
            e["localizations"][l] = {"stringUnit": {"state": "new", "value": en}}
            e["localizations"] = dict(sorted(e["localizations"].items()))
        self._dump(d, raw)
        return len(miss)

    def _dump(self, d, raw):
        s = json.dumps(d, indent=2, separators=(",", " : "), ensure_ascii=False)
        s = re.sub(r'^(\s*)("(?:[^"\\]|\\.)*" : )\{\}(,?)$', lambda m: f"{m.group(1)}{m.group(2)}{{\n\n{m.group(1)}}}{m.group(3)}", s, flags=re.M)
        open(self.path(), "w", encoding="utf-8").write(s + ("\n" if raw.endswith("\n") else ""))

    def validate_file(self, lang):
        try:
            self._load()
        except Exception as e:
            return [f"{self.spec['source']}: invalid JSON: {e}"]
        return [f"{self.spec['source']} {lang} {k!r}: no {lang} value, so the app shows the RAW KEY; "
                "run `python3 l10n/ostler_l10n.py stale` (offline) to give it the English"
                for k, l in self.missing_fallbacks([lang])]


def _js_string(text, i):
    """Parse a JS string literal ('..', "..") at text[i]; return (value, end)."""
    q = text[i]
    j, out = i + 1, []
    esc = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", "'": "'", '"': '"', "`": "`", "$": "$", "0": "\0"}
    while text[j] != q:
        if text[j] == "\\":
            c = text[j + 1]
            if c == "u":
                out.append(chr(int(text[j + 2:j + 6], 16)))
                j += 6
                continue
            out.append(esc.get(c, c))
            j += 2
            continue
        out.append(text[j])
        j += 1
    return "".join(out), j + 1


class TsObjectCatalogue:
    """English lives in a TS object literal ({ 'key': 'value', ... } with
    // comments); each language is a flat <target>.json the app merges over
    English per key. Read-only on the TS side: the source is never rewritten."""

    def __init__(self, spec):
        self.id, self.spec = spec["id"], spec

    def path(self, lang=None):
        return os.path.join(REPO, self.spec["source"] if lang is None else self.spec["target"].format(lang=lang))

    def _entries(self):
        text = open(self.path(), encoding="utf-8").read()
        start = text.index(self.spec["start_marker"]) + len(self.spec["start_marker"])
        i, depth, comment = start, 1, []
        key_re = re.compile(r"\s*(?:'([^']+)'|\"([^\"]+)\"|([A-Za-z_][\w]*))\s*:\s*")
        while i < len(text):
            if text.startswith("//", i):
                e = text.index("\n", i)
                comment.append(text[i + 2:e].strip())
                i = e + 1
                continue
            c = text[i]
            if c in " \t\n,":
                if c == "\n" and text[i + 1:i + 2] == "\n":
                    comment = []
                i += 1
                continue
            if c == "}":
                return
            m = key_re.match(text, i)
            if not m:
                raise ValueError(f"{self.spec['source']}: cannot parse near {text[i:i + 60]!r}")
            key = m.group(1) or m.group(2) or m.group(3)
            j = m.end()
            while text[j] in " \t\n":
                j += 1
            parts = []
            while True:
                v, j = _js_string(text, j)
                parts.append(v)
                k = j
                while text[k] in " \t\n":
                    k += 1
                if text[k] == "+":
                    j = k + 1
                    while text[j] in " \t\n":
                        j += 1
                    continue
                break
            yield key, "".join(parts), " ".join(comment)[-300:]
            comment = []
            i = j

    def units(self):
        for k, v, c in self._entries():
            if has_letters(v) and k not in self.spec.get("do_not_translate_keys", []):
                yield Unit(self.id, k, v, c, "web")

    def read(self, lang):
        p = self.path(lang)
        return json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {}

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
        order = [k for k, _, _ in self._entries()]
        d = {k: values[k] for k in order if k in values}
        os.makedirs(os.path.dirname(self.path(lang)), exist_ok=True)
        with open(self.path(lang), "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, indent=2)
            f.write("\n")
        _write_flag_rows(lang, self.spec["source"], flags)

    def validate_file(self, lang):
        p = self.path(lang)
        if not os.path.exists(p):
            return []
        try:
            d = json.load(open(p, encoding="utf-8"))
        except Exception as e:
            return [f"{os.path.relpath(p, REPO)}: invalid JSON: {e}"]
        keys = {k for k, _, _ in self._entries()}
        extra = sorted(set(d) - keys)
        return [f"{os.path.relpath(p, REPO)}: {len(extra)} key(s) not in the English source, e.g. {extra[:3]}"] if extra else []


class YamlTreeCatalogue(JsonTreeCatalogue):
    """A YAML tree (needs PyYAML). Each language is written as JSON, which
    every YAML loader reads, so the writer never has to emit YAML. Keys in
    `skip_keys` (dotted paths) are copied from English untouched; `fixed`
    gives per-language values a translator must not invent."""

    def _load_src(self):
        import yaml
        return yaml.safe_load(open(self.path(), encoding="utf-8"))

    def _walk(self, x, p, meta, all_text=False):
        skip = set(self.spec.get("skip_keys", []))
        if p and ".".join(map(str, p)) in skip:
            return
        if any(".".join(map(str, p)).startswith(s + ".") for s in skip):
            return
        yield from JsonTreeCatalogue._walk(self, x, p, meta, all_text)

    def units(self):
        for k, v, meta in self._walk(self._load_src(), [], ""):
            yield Unit(self.id, k, v, meta[:300], "yaml")

    def write(self, lang, values, flags):
        fixed = self.spec.get("fixed", {})

        def walk(x, p):
            k = "/".join(map(str, p))
            dotted = ".".join(map(str, p))
            if dotted in fixed and isinstance(fixed[dotted], dict) and lang in fixed[dotted]:
                return fixed[dotted][lang]
            if isinstance(x, str):
                return values.get(k, x)
            if isinstance(x, dict):
                return {kk: walk(vv, p + [kk]) for kk, vv in x.items()}
            if isinstance(x, list):
                return [walk(v, p + [i]) for i, v in enumerate(x)]
            return x
        d = walk(self._load_src(), [])
        with open(self.path(lang), "w", encoding="utf-8") as f:
            f.write(f"# {self.spec['source']} translated to {lang} by l10n/ostler_l10n.py. Generated: edit the\n"
                    "# English source, never this file. JSON is valid YAML, so the loader reads it as-is.\n")
            json.dump(d, f, ensure_ascii=False, indent=1)
            f.write("\n")
        _write_flag_rows(lang, self.spec["source"], flags)

    def validate_file(self, lang):
        p = self.path(lang)
        if not os.path.exists(p):
            return []
        try:
            import yaml
            tr = yaml.safe_load(open(p, encoding="utf-8"))
        except Exception as e:
            return [f"{os.path.relpath(p, REPO)}: unreadable: {e}"]
        base = self._load_src()

        def keys(x, p=""):
            if isinstance(x, dict):
                out = set()
                for k, v in x.items():
                    out |= {f"{p}{k}"} | keys(v, f"{p}{k}.")
                return out
            return set()
        extra = keys(tr) - keys(base)  # fewer is fine: the loader overlays it on English
        return [f"{os.path.relpath(p, REPO)}: {len(extra)} key(s) not in English, e.g. {sorted(extra)[:3]}"] if extra else []

    def read(self, lang):
        p = self.path(lang)
        if not os.path.exists(p):
            return {}
        import yaml
        return {k: v for k, v, _ in self._walk(yaml.safe_load(open(p, encoding="utf-8")), [], "", True)}


ADAPTERS = {"shell": ShellCatalogue, "json-tree": JsonTreeCatalogue, "xcstrings": XcstringsCatalogue,
            "ts-object": TsObjectCatalogue, "yaml-tree": YamlTreeCatalogue}


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
# Legal / consent keys: a translation SHIPS only once a native reviewer
# (recorded by ROLE, never by name) has passed it (l10n/legal_reviews.tsv:
# lang, catalogue, key, source hash, reviewed_by, date, verdict). Until then
# the catalogue carries ENGLISH and the machine translation waits in
# l10n/legal_pending/<lang>.json for the reviewer.
#
# Owner ruling 2026-10-24: "yes, localisation with English prevails." So a reviewed
# legal translation ships only when the "English version prevails" line
# (config `legal_prevails_keys`) is ALSO reviewed for that language; without
# it every legal key of that language stays English. The switch is per key:
# a key with no current row, or whose English changed after review (hash
# mismatch), ships English. LegalGate is the one place this is decided.
# --------------------------------------------------------------------------

def _reviews_path():
    return os.path.join(HERE, "legal_reviews.tsv")


def _pending_dir():
    return os.path.join(HERE, "legal_pending")


def is_legal(u, cfg):
    pats = [re.compile(p, re.I) for p in cfg.get("legal_patterns", [])]
    tpats = [re.compile(p, re.I) for p in cfg.get("legal_text_patterns", [])]
    return (u.key in set(cfg.get("legal_keys", []))
            or any(p.search(u.key + " " + u.ctx) for p in pats)
            or any(p.search(u.src) for p in tpats))


def load_reviews(cfg=None):
    out = {}
    # Owner ruling (2026-10-22): legal and consent strings stay ENGLISH in every
    # locale, so no review row can make a translation of one shippable.
    if cfg and cfg.get("legal_english_only"):
        return out
    if os.path.exists(_reviews_path()):
        for line in open(_reviews_path(), encoding="utf-8").read().splitlines():
            f = line.split("\t")
            if len(f) >= 6 and not line.startswith("#") and f[0] != "lang":
                verdict = f[6].strip() if len(f) >= 7 else ""
                if re.search(r"reject|pending|awaiting", verdict, re.I):
                    continue  # a row that records a NO, or no answer yet, approves nothing
                out[(f[0], f"{f[1]}::{f[2]}")] = {"hash": f[3], "by": f[4], "date": f[5], "verdict": verdict}
    return out


def reviewed(reviews, lang, u):
    r = reviews.get((lang, u.uid))
    return bool(r and r["hash"] == h(u.src) and r["by"].strip() and re.fullmatch(r"\d{4}-\d{2}-\d{2}", r["date"]))


def review_id(lang, u):
    """The id of the legal_reviews.tsv row that lets this translation ship:
    language, catalogue::key and the hash of the English it was reviewed
    against. The consent log records it (lib/ostler_consent_display.py
    computes the same string), so we can later show which wording was seen."""
    return f"{lang}/{u.uid}@{h(u.src)}"


class LegalGate:
    """Does the translation of legal unit `u` in `lang` ship? Only if BOTH
    its own legal_reviews.tsv row is current AND every `legal_prevails_keys`
    unit ("English version prevails") is reviewed for that language. A
    catalogue with no prevails key configured keeps all legal keys English
    (fail closed). `legal_english_only: true` still forces English everywhere."""

    def __init__(self, cfg, reviews=None, units=None):
        self.cfg = cfg
        self.reviews = load_reviews(cfg) if reviews is None else reviews
        if units is None:
            units = {u.uid: u for c in catalogues(cfg) for u in c.units()}
        self.units = units
        self.prevails = [str(x) for x in (cfg.get("legal_prevails_keys") or [])]

    def prevails_ok(self, lang):
        if not self.prevails:
            return False
        return all(uid in self.units and reviewed(self.reviews, lang, self.units[uid]) for uid in self.prevails)

    def ships(self, lang, u):
        if self.cfg.get("legal_english_only"):
            return False
        return reviewed(self.reviews, lang, u) and self.prevails_ok(lang)

    def missing_prevails(self):
        """Configured prevails uids that name no unit: a typo would silently
        keep every legal key English forever, so `check` reports it."""
        return [uid for uid in self.prevails if uid not in self.units]


def load_legal_pending(lang):
    p = os.path.join(_pending_dir(), f"{lang}.json")
    return json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {}


def save_legal_pending(lang, d):
    os.makedirs(_pending_dir(), exist_ok=True)
    p = os.path.join(_pending_dir(), f"{lang}.json")
    if not d:
        if os.path.exists(p):
            os.remove(p)
        return
    with open(p, "w", encoding="utf-8") as f:
        json.dump(dict(sorted(d.items())), f, ensure_ascii=False, indent=1)
        f.write("\n")

# --------------------------------------------------------------------------
# Mechanical checks (the BLOCKING part of the gate)
# --------------------------------------------------------------------------

YN = re.compile(r"\(y/n\)|\(Y/n\)|\(y/N\)|Y / N|Y/N|\[y/N\]|\[Y/n\]")
YN_LABELLED = re.compile(r"\b[Yy] = [^/\n]{1,20} / [Nn] = ")
LIT = re.compile(r"https?://\S+|[\w.+-]+@[\w-]+\.[\w.]+|~/\S+|\b(?:127\.0\.0\.1|localhost):\d+")


MARKER = re.compile(r"\{([^{}]+)\}")


def mech(u, out, cfg):
    src, errs = u.src, []
    if u.key in set(cfg.get("emphasis_marker_keys", [])):
        # {braces} in these keys mark the emphasised word (the app renders it
        # italic), so they wrap a word of the TARGET language and are not
        # placeholders. Exactly one marker, and never the English word.
        ms, mo = MARKER.findall(src), MARKER.findall(out)
        if len(mo) != len(ms):
            errs.append(f"emphasis markers {ms} -> {mo} (need {len(ms)})")
        elif out != src and any(x.strip().casefold() == y.strip().casefold() for x, y in zip(ms, mo)):
            errs.append(f"emphasis marker still wraps the English word {mo}")
        src, out = MARKER.sub("", src), MARKER.sub("", out)
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
        # The cue stays, or is spelled out in the language: "(Y = oui / N = non)",
        # "[y = ja / N = nein]" (the installer still accepts Y/N; legal reviewer, 2026-10-19).
        if m not in out and not YN_LABELLED.search(out):
            errs.append(f"y/n cue {m!r} lost")
    for m in LIT.findall(src):
        m = m.rstrip(".,;:)")
        if m not in out:
            errs.append(f"literal {m!r} lost")
    if collections.Counter(TAG.findall(src)) != collections.Counter(TAG.findall(out)):
        errs.append("HTML tags differ (tags and their attributes must be kept verbatim)")
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
    cats = catalogues(cfg)
    all_units = {c.id: {u.key: u for u in c.units()} for c in cats}
    gate = LegalGate(cfg, units={u.uid: u for us in all_units.values() for u in us.values()})
    for uid in gate.missing_prevails():
        errs.append(f"legal_prevails_keys names {uid}, which is no unit in any catalogue")
    legal_shipped = collections.defaultdict(list)
    shown = collections.defaultdict(set)  # lang -> uids whose translation is in the catalogue
    for c in cats:
        units = all_units[c.id]
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
                shown[lang].add(u.uid)
                if is_legal(u, cfg) and not gate.ships(lang, u):
                    why = ("no current legal_reviews.tsv row for this English" if not reviewed(gate.reviews, lang, u)
                           else "the English-prevails line is not reviewed for this language")
                    errs.append(f"{c.id} {lang} {k}: UNREVIEWED legal/consent translation would ship ({why}); "
                                "run `stale` (moves it to l10n/legal_pending, English ships) or "
                                "`legal-approve` once a native reviewer has passed it")
                    n["legal_unreviewed"] += 1
                    continue
                if is_legal(u, cfg):
                    legal_shipped[lang].append(u.uid)
                for e in mech(u, v, cfg):
                    errs.append(f"{c.id} {lang} {k}: {e}")
                if made.get(u.uid) != h(u.src):
                    stale.append((c, lang, k))
                    n["stale"] += 1
                else:
                    n["translated"] += 1
            # A shell key missing from a translation is NOT an error: install.sh
            # sources en-GB first and the language file on top, so it prints
            # English. Coverage (above) counts it as an English fallback.
    # A localised legal surface must SHOW its English-prevails line: a legal
    # translation in the catalogue while the prevails translation is not
    # there would render without it.
    for lang, uids in legal_shipped.items():
        for p in gate.prevails:
            if p not in shown[lang]:
                errs.append(f"{lang}: {len(uids)} legal translation(s) ship (e.g. {uids[0]}) but the English-prevails "
                            f"line {p} is still English; run `stale` to promote it")
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
    # unreviewed legal/consent translations: park them for the reviewer;
    # reviewed ones waiting in legal_pending: promote them into the catalogue
    gate = LegalGate(cfg)
    parked = promoted = 0
    promote = collections.defaultdict(dict)
    for c in catalogues(cfg):
        units = {u.key: u for u in c.units()}
        for lang in cfg["languages"]:
            tr = c.read(lang)
            pend = load_legal_pending(lang)
            for k, u in units.items():
                v = tr.get(k)
                if v is not None and v != u.src and is_legal(u, cfg) and not gate.ships(lang, u):
                    # Park only a real translation (provenance knows it). A value with
                    # no provenance is an OLD ENGLISH fallback left behind when the
                    # English changed; parking it would offer English to a reviewer
                    # as a "translation" (62 such entries were found 2026-10-24).
                    if st["made_from"].get(lang, {}).get(u.uid):
                        pend[u.uid] = {"text": v, "src_hash": h(u.src), "src": u.src}
                        parked += 1
                    by[(c.id, lang)].add(k)
                    continue
                e = pend.get(u.uid)
                if (e and is_legal(u, cfg) and gate.ships(lang, u) and e.get("src_hash") == h(u.src)
                        and (v is None or v == u.src) and e.get("text") and e["text"] != u.src):
                    bad = mech(u, e["text"], cfg)
                    if bad:
                        print(f"stale: NOT promoting {lang} {u.uid}: {bad}")
                        continue
                    promote[(c.id, lang)][k] = e["text"]
                    st["made_from"].setdefault(lang, {})[u.uid] = h(u.src)
                    pend.pop(u.uid)
                    promoted += 1
            save_legal_pending(lang, pend)
    n = 0
    for c in catalogues(cfg):
        for lang in cfg["languages"]:
            ks = by.get((c.id, lang), set())
            tr, fl = c.read(lang), c.flags(lang)
            units = {u.key: u for u in c.units()}
            # a shell file missing keys is rewritten too: the writer emits the
            # full en-GB key set, English wherever there is no translation
            short = c.spec["type"] == "shell" and os.path.exists(c.path(lang)) and set(units) - set(tr)
            prom = promote.get((c.id, lang), {})
            if not ks and not short and not prom:
                continue
            keep = {k: v for k, v in tr.items() if k in units and k not in ks and v != units[k].src}
            keep.update(prom)
            if c.spec["type"] == "xcstrings":
                c.write(lang, prom, {}, drop=ks)
            else:
                c.write(lang, keep, {k: v for k, v in fl.items() if k in keep and k not in prom})
            for k in ks:
                st["made_from"].get(lang, {}).pop(f"{c.id}::{k}", None)
            n += len(ks)
    filled = sum(c.fill_fallbacks(cfg["languages"]) for c in catalogues(cfg) if c.spec["type"] == "xcstrings")
    save_state(st)
    print(f"stale: {n} translation(s) fell back to English ({parked} unreviewed legal/consent parked in "
          f"l10n/legal_pending); {promoted} reviewed legal/consent translation(s) promoted; "
          f"{filled} missing key-based value(s) given the English")
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
    only = [x for x in os.environ.get("OSTLER_L10N_ONLY", "").split(",") if x]  # e.g. "zh-Hant" for a second pass
    skip = [x for x in os.environ.get("OSTLER_L10N_SKIP", "").split(",") if x]
    out = []
    for c in catalogues(cfg):
        units = list(c.units())
        for lang in cfg["languages"]:
            if (only and lang not in only) or lang in skip:
                continue
            tr = c.read(lang)
            made = st["made_from"].get(lang, {})
            parked = load_legal_pending(lang)
            for u in units:
                if u.key in keep:
                    continue
                if parked.get(u.uid, {}).get("src_hash") == h(u.src):
                    continue  # a translation already waits for its legal reviewer
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
    # Crash-recovery record + raw results, OUTSIDE the repo: model output must
    # never sit in a tree that the PII guards scan or that git could pick up.
    runs = os.environ.get("OSTLER_L10N_RUNS_DIR") or os.path.join(
        os.path.expanduser("~/.cache/ostler-l10n"), os.path.basename(REPO))
    os.makedirs(runs, exist_ok=True)
    resume = os.environ.get(f"OSTLER_L10N_RESUME_{phase.upper()}")
    if resume:
        b = cl.messages.batches.retrieve(resume)  # never pay twice: reuse a batch that already ran
        print(f"{phase}: RESUMING batch {b.id}", flush=True)
    else:
        b = cl.messages.batches.create(requests=reqs)
        with open(os.path.join(runs, "inflight.tsv"), "a") as f:
            f.write(f"{datetime.datetime.utcnow():%Y-%m-%dT%H:%M:%SZ}\t{phase}\t{b.id}\t{len(reqs)}\n")
        print(f"{phase}: batch {b.id}, {len(reqs)} requests (recorded in {runs}/inflight.tsv)", flush=True)
    while True:
        r = cl.messages.batches.retrieve(b.id)
        rc = r.request_counts
        print(f"{datetime.datetime.utcnow():%H:%M:%S} {phase} {r.processing_status} processing={rc.processing} ok={rc.succeeded} err={rc.errored}", flush=True)
        if r.processing_status == "ended":
            break
        time.sleep(60)
    out, acc = {}, collections.Counter()
    raw = open(os.path.join(runs, f"{b.id}.jsonl"), "w", encoding="utf-8")  # streamed to disk as it arrives
    for res in cl.messages.batches.results(b.id):
        if res.result.type != "succeeded":
            continue
        m = res.result.message
        raw.write(json.dumps({"custom_id": res.custom_id, "text": next((x.text for x in m.content if x.type == "text"), "")}, ensure_ascii=False) + "\n")
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
    raw.close()
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

    # derive_from: {zh-Hant: zh-HK} -- a cheap adaptation pass from a reviewed
    # sibling translation instead of translating from scratch.
    derive = cfg.get("derive_from") or {}
    st0 = load_state()
    cats = {c.id: c for c in catalogues(cfg)}
    base_cache = {}

    def base_for(lang, u):
        src_lang = derive.get(lang)
        if not src_lang:
            return None
        if (u.cat, src_lang) not in base_cache:
            base_cache[(u.cat, src_lang)] = cats[u.cat].read(src_lang)
        v = base_cache[(u.cat, src_lang)].get(u.key)
        if v is None or st0["made_from"].get(src_lang, {}).get(u.uid) != h(u.src):
            return None  # the sibling is missing or stale: translate from scratch
        return v

    def item(sid):
        lang, u = ids[sid]
        d = {"id": sid, "src": u.src, "ctx": u.ctx[:400], "specs": SPEC.findall(u.src), "kind": u.kind}
        b = base_for(lang, u)
        if b is not None:
            d["base_translation"] = b
        return d

    reqs = []
    for lang in groups:
        for n, ch in enumerate(chunks(lang)):
            reqs.append({"custom_id": f"t_{lang}_{n}", "params": {
                "model": cfg["models"]["translate"], "max_tokens": 32000, "system": _system(gl, False),
                "thinking": {"type": "adaptive"}, "output_config": {"effort": "medium", "format": {"type": "json_schema", "schema": T_SCHEMA}},
                "messages": [{"role": "user", "content": f"Target language: {gl['language_names'][lang]} (locale {lang}). Translate every item."
                              + (f" Items with base_translation already have a reviewed {gl['language_names'][derive[lang]]} ({derive[lang]}) translation: "
                                 "ADAPT it to the target locale's usage and vocabulary, changing only what a native reader of the target locale would say differently, "
                                 "and keep everything else identical." if lang in derive else "") + "\n\n"
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
                    "messages": [{"role": "user", "content": f"Target language: {gl['language_names'][lang]} (locale {lang}). Review every item."
                                  + (f" Many were adapted from the {derive[lang]} translation: check specifically that the vocabulary is {lang} usage, not {derive[lang]}." if lang in derive else "") + "\n\n"
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
        if any(p.search(u.key + " " + u.ctx) for p in legal):
            why = why or "legal/consent wording: needs a qualified human check"
        if u.key in human:
            why = why or "source asks for human translation of this key"
        out[sid] = (chosen, why)
    out["__ids__"] = ids
    return out


def apply_results(cfg, results):
    ids = results.pop("__ids__")
    st = load_state()
    gate = LegalGate(cfg)
    per = collections.defaultdict(lambda: ({}, {}))
    parked = collections.defaultdict(dict)
    for sid, res in results.items():
        if not res:
            continue
        lang, u = ids[sid]
        if is_legal(u, cfg) and not gate.ships(lang, u):
            # legal/consent: never straight into a shipping catalogue
            parked[lang][u.uid] = {"text": res[0], "src_hash": h(u.src), "src": u.src}
            continue
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
    for lang, d in parked.items():
        pend = load_legal_pending(lang)
        pend.update(d)
        save_legal_pending(lang, pend)
    for c in catalogues(cfg):
        if c.spec["type"] == "xcstrings":
            c.fill_fallbacks(cfg["languages"])
    save_state(st)


def cmd_legal_list(cfg):
    """What is waiting for a legal/consent reviewer, per language."""
    total = 0
    for lang in cfg["languages"]:
        pend = load_legal_pending(lang)
        if pend:
            print(f"{lang}: {len(pend)} waiting")
            for uid, v in sorted(pend.items())[:200]:
                print(f"  {uid}\n    EN: {v['src'][:160]}\n    {lang}: {v['text'][:160]}")
        total += len(pend)
    print(f"legal-list: {total} translation(s) waiting for review; English ships until approved")
    return 0


def cmd_legal_approve(cfg, args):
    """legal-approve LANG CATALOGUE::KEY --by ROLE [--date YYYY-MM-DD] [--text "edited translation"]
    Records the review (reviewer by ROLE, never a name: public repo). The
    translation ships only if LegalGate then allows it (its English-prevails
    line is reviewed for LANG too); otherwise it waits in legal_pending."""
    import argparse
    ap = argparse.ArgumentParser(prog="legal-approve")
    ap.add_argument("lang"); ap.add_argument("uid")
    ap.add_argument("--by", required=True); ap.add_argument("--date", default=datetime.date.today().isoformat())
    ap.add_argument("--text")
    a = ap.parse_args(args)
    if cfg.get("legal_english_only"):
        raise SystemExit("legal-approve: refused, legal_english_only is set (legal and consent strings stay English in every locale)")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", a.date) or not a.by.strip():
        raise SystemExit("legal-approve: --by ROLE and --date YYYY-MM-DD are required")
    cat_id, key = a.uid.split("::", 1)
    c = next(x for x in catalogues(cfg) if x.id == cat_id)
    u = next(x for x in c.units() if x.key == key)
    pend = load_legal_pending(a.lang)
    entry = pend.get(a.uid)
    text = a.text if a.text is not None else (entry or {}).get("text")
    if text is None:
        raise SystemExit(f"legal-approve: nothing pending for {a.lang} {a.uid}; pass --text")
    if entry and entry.get("src_hash") != h(u.src):
        raise SystemExit("legal-approve: the English changed since this translation was made; retranslate first")
    errs = mech(u, text, cfg)
    if errs:
        raise SystemExit(f"legal-approve: refused, {errs}")
    new = not os.path.exists(_reviews_path())
    with open(_reviews_path(), "a", encoding="utf-8") as f:
        if new:
            f.write("lang\tcatalogue\tkey\tsource_hash\treviewed_by\tdate\tverdict\n")
        f.write(f"{a.lang}\t{cat_id}\t{key}\t{h(u.src)}\t{a.by.strip()}\t{a.date}\treviewed\n")
    gate = LegalGate(cfg)
    if not gate.ships(a.lang, u):
        pend[a.uid] = {"text": text, "src_hash": h(u.src), "src": u.src}
        save_legal_pending(a.lang, pend)
        print(f"legal-approve: {a.lang} {a.uid} reviewed by {a.by.strip()} on {a.date}; ENGLISH still ships "
              f"until the English-prevails line ({', '.join(gate.prevails) or 'none configured'}) is reviewed for {a.lang}")
        return 0
    existing = c.read(a.lang)
    units = {x.key: x for x in c.units()}
    if c.spec["type"] == "xcstrings":
        c.write(a.lang, {key: text}, {})
    else:
        merged = {k: v for k, v in existing.items() if k in units and v != units[k].src}
        merged[key] = text
        fl = {k: v for k, v in c.flags(a.lang).items() if k in merged and k != key}
        c.write(a.lang, merged, fl)
    st = load_state()
    st["made_from"].setdefault(a.lang, {})[a.uid] = h(u.src)
    save_state(st)
    pend.pop(a.uid, None)
    save_legal_pending(a.lang, pend)
    print(f"legal-approve: {a.lang} {a.uid} reviewed by {a.by.strip()} on {a.date}; translation ships")
    # the prevails line itself may have been the last missing review: promote the rest
    _quiet(cmd_stale, cfg)
    return 0


def legal_pack_items(cfg, lang):
    """Legal units of THIS repo that a reviewer of `lang` should see next:
    every English-prevails unit not yet reviewed for `lang`, then every key
    whose review (in ANY language) is stale because its English changed
    after review, and that is not yet reviewed for `lang` at today's English.
    Each item: (uid, English, current translation or None, why)."""
    reviews = load_reviews(dict(cfg, legal_english_only=False))
    gate = LegalGate(dict(cfg, legal_english_only=False), reviews=reviews)
    pend = load_legal_pending(lang)
    tr = {c.id: c.read(lang) for c in catalogues(cfg)}
    stale_uids = {uid for (lg, uid), r in reviews.items() if uid in gate.units and r["hash"] != h(gate.units[uid].src)}
    out = []
    for uid in gate.prevails + sorted(stale_uids - set(gate.prevails)):
        u = gate.units.get(uid)
        if not u or reviewed(reviews, lang, u):
            continue
        e = pend.get(uid)
        cur = e["text"] if e and e.get("src_hash") == h(u.src) else None
        if cur is None:
            v = tr[u.cat].get(u.key)
            cur = v if v is not None and v != u.src else None
        why = "english-prevails line" if uid in gate.prevails else "English changed after an earlier review"
        out.append((uid, u.src, cur, why))
    return out


def cmd_legal_pack(cfg, args):
    """legal-pack LANG [--out FILE]: write the review items as TSV (uid,
    english, translation, why). Offline; sends nothing anywhere."""
    import argparse
    ap = argparse.ArgumentParser(prog="legal-pack")
    ap.add_argument("lang"); ap.add_argument("--out")
    a = ap.parse_args(args)
    rows = legal_pack_items(cfg, a.lang)
    esc = lambda s: (s or "").replace("\t", " ").replace("\n", " ")
    body = "uid\tenglish\ttranslation\twhy\n" + "".join(f"{esc(u)}\t{esc(e)}\t{esc(t)}\t{esc(w)}\n" for u, e, t, w in rows)
    if a.out:
        open(a.out, "w", encoding="utf-8").write(body)
    else:
        sys.stdout.write(body)
    print(f"legal-pack: {a.lang}: {len(rows)} item(s)", file=sys.stderr)
    return 0

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
        open(os.path.join(tmp, "s.en-GB.sh"), "w").write('MSG_A="Saved to %s"\nMSG_B="Type INSTALL to go on"\n'
                                                       'MSG_LEGAL_PREVAILS="If this differs from the English, the English prevails."\n')
        open(os.path.join(tmp, "s.de.sh"), "w").write('MSG_A="Gespeichert unter %s"\nMSG_B="Gib INSTALL ein, um fortzufahren"\n')
        open(os.path.join(tmp, "l10n", "config.yaml"), "w").write(
            "languages: [de]\nbudget_usd: 1\nverbatim_tokens: [INSTALL]\nlegal_patterns: [consent]\nlegal_keys: [MSG_LEGAL_PREVAILS]\n"
            "legal_prevails_keys: [sh::MSG_LEGAL_PREVAILS]\nmodels:\n  translate: claude-sonnet-5-5\n  review: claude-opus-5-5\n"
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
        import types
        _u = types.SimpleNamespace(src="Go on? [y/N]", key="K", ctx="", uid="x::K", kind="other")
        results["y/n cue spelled out passes"] = not any("y/n cue" in e for e in mech(_u, "Weiter? [y = ja / N = nein]", c2))
        results["y/n cue dropped fails"] = any("y/n cue" in e for e in mech(_u, "Weiter?", c2))
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
        results["check passes after stale"] = quiet(cmd_check, c2) == 0
        results["stale keeps a value (no raw key)"] = after["strings"]["home.title"]["localizations"].get("de", {}).get("stringUnit", {}).get("value") == "Your day"
        # mutant 4: a key-based entry with no translation at all -> raw key on screen
        d = json.load(open(os.path.join(tmp, "L.xcstrings")))
        d["strings"]["brand.name"] = {"localizations": {"en": {"stringUnit": {"state": "translated", "value": "Ostler"}}}}
        json.dump(d, open(os.path.join(tmp, "L.xcstrings"), "w"))
        results["missing key-based value fails"] = quiet(cmd_check, c2) == 1
        quiet(cmd_stale, c2)
        results["stale gives it the English"] = json.load(open(os.path.join(tmp, "L.xcstrings")))["strings"]["brand.name"]["localizations"]["de"]["stringUnit"]["value"] == "Ostler"
        results["check passes after fill"] = quiet(cmd_check, c2) == 0
        # plural variations: never a unit, never pending, never overwritten by a run
        d = json.load(open(os.path.join(tmp, "L.xcstrings")))
        pl = lambda one, other: {"variations": {"plural": {"one": {"stringUnit": {"state": "translated", "value": one}},
                                                           "other": {"stringUnit": {"state": "translated", "value": other}}}}}
        d["strings"]["people.count"] = {"localizations": {"en": pl("%lld person", "%lld people"), "de": pl("%lld Person", "%lld Personen")}}
        json.dump(d, open(os.path.join(tmp, "L.xcstrings"), "w"))
        results["plural key is not a unit"] = all(u.key != "people.count" for u in XcstringsCatalogue(c2["catalogues"][0]).units())
        todo = pending(c2)
        fake = {f"s{i}": ("ÜBERSCHRIEBEN", "") for i in range(len(todo))}
        fake["__ids__"] = {f"s{i}": t for i, t in enumerate(todo)}
        quiet(apply_results, c2, fake)
        de_pl = json.load(open(os.path.join(tmp, "L.xcstrings")))["strings"]["people.count"]["localizations"]["de"]
        results["a run leaves plural variations intact"] = "stringUnit" not in de_pl and de_pl["variations"]["plural"]["other"]["stringUnit"]["value"] == "%lld Personen"
        results["check passes with a plural key"] = quiet(cmd_check, c2) == 0
        # yaml subset round-trip of the real config
        results["real config parses"] = bool(_REAL_CFG.get("catalogues"))
        # legal/consent: an unreviewed translation must never ship
        en_sh = os.path.join(tmp, "s.en-GB.sh"); de_sh = os.path.join(tmp, "s.de.sh")
        open(en_sh, "a").write('MSG_CONSENT_X="I agree to %s"\n')
        open(de_sh, "a").write('MSG_CONSENT_X="Ich stimme %s zu"\n')
        _st = load_state()
        _st["made_from"].setdefault("de", {})["sh::MSG_CONSENT_X"] = h("I agree to %s")  # a machine translation
        save_state(_st)
        sh_de = lambda k: ShellCatalogue(c2["catalogues"][1]).read("de").get(k)
        results["unreviewed consent translation fails"] = quiet(cmd_check, c2) == 1
        quiet(cmd_stale, c2)
        results["stale ships English for it"] = sh_de("MSG_CONSENT_X") == "I agree to %s"
        results["and parks the translation for review"] = load_legal_pending("de").get("sh::MSG_CONSENT_X", {}).get("text") == "Ich stimme %s zu"
        results["check passes with English"] = quiet(cmd_check, c2) == 0
        quiet(cmd_legal_approve, c2, ["de", "sh::MSG_CONSENT_X", "--by", "legal reviewer (de)", "--date", "2026-10-19"])
        # owner ruling 2026-10-24, English prevails: a reviewed key alone does not switch the surface on
        results["reviewed key stays English while the prevails line is unreviewed"] = sh_de("MSG_CONSENT_X") == "I agree to %s"
        results["and its reviewed translation waits in legal_pending"] = load_legal_pending("de").get("sh::MSG_CONSENT_X", {}).get("text") == "Ich stimme %s zu"
        results["check passes (nothing legal localised yet)"] = quiet(cmd_check, c2) == 0
        quiet(cmd_legal_approve, c2, ["de", "sh::MSG_LEGAL_PREVAILS", "--by", "legal reviewer (de)", "--date", "2026-10-24",
                                       "--text", "Weicht dies vom Englischen ab, gilt das Englische."])
        results["prevails line reviewed: it ships"] = sh_de("MSG_LEGAL_PREVAILS") == "Weicht dies vom Englischen ab, gilt das Englische."
        results["prevails line reviewed: the reviewed key ships"] = sh_de("MSG_CONSENT_X") == "Ich stimme %s zu"
        results["check passes once reviewed"] = quiet(cmd_check, c2) == 0
        # mutant (per key): delete the key's review row -> red, then `stale` -> English -> green
        rv_path = os.path.join(HERE, "legal_reviews.tsv")
        rv_all = open(rv_path, encoding="utf-8").read()
        open(rv_path, "w", encoding="utf-8").write("".join(l for l in rv_all.splitlines(True) if "\tMSG_CONSENT_X\t" not in l))
        results["mutant: review row deleted -> check fails"] = quiet(cmd_check, c2) == 1
        quiet(cmd_stale, c2)
        results["mutant: review row deleted -> that key renders English"] = sh_de("MSG_CONSENT_X") == "I agree to %s"
        results["mutant: ... and only that key"] = sh_de("MSG_LEGAL_PREVAILS") == "Weicht dies vom Englischen ab, gilt das Englische."
        results["mutant: check passes again"] = quiet(cmd_check, c2) == 0
        open(rv_path, "w", encoding="utf-8").write(rv_all)
        quiet(cmd_stale, c2)
        results["row restored: the key ships again"] = sh_de("MSG_CONSENT_X") == "Ich stimme %s zu"
        # mutant (surface): delete the prevails row -> every legal key of the language goes English
        open(rv_path, "w", encoding="utf-8").write("".join(l for l in rv_all.splitlines(True) if "\tMSG_LEGAL_PREVAILS\t" not in l))
        results["prevails row deleted -> check fails"] = quiet(cmd_check, c2) == 1
        quiet(cmd_stale, c2)
        results["prevails row deleted -> the whole surface is English"] = (sh_de("MSG_CONSENT_X"), sh_de("MSG_LEGAL_PREVAILS")) == (
            "I agree to %s", "If this differs from the English, the English prevails.")
        open(rv_path, "w", encoding="utf-8").write(rv_all.replace("\treviewed\n", "\trejected\n", 1))
        results["a rejected row does not count"] = ("de", "sh::MSG_CONSENT_X") not in load_reviews(c2)
        open(rv_path, "w", encoding="utf-8").write(rv_all)
        quiet(cmd_stale, c2)
        # an OLD ENGLISH fallback (no provenance) of a legal key: reset, never parked
        open(en_sh, "a").write('MSG_CONSENT_Y="Keep it on"\n')
        quiet(cmd_stale, c2)
        open(de_sh, "a").write('MSG_CONSENT_Y="Leave it on"\n')
        quiet(cmd_stale, c2)
        results["old English fallback is reset to the current English"] = sh_de("MSG_CONSENT_Y") == "Keep it on"
        results["old English fallback is NOT parked as a translation"] = "sh::MSG_CONSENT_Y" not in load_legal_pending("de")
        results["legal-pack lists nothing once all is reviewed"] = legal_pack_items(c2, "de") == []
        open(rv_path, "w", encoding="utf-8").write("".join(l for l in rv_all.splitlines(True) if "\tMSG_LEGAL_PREVAILS\t" not in l))
        results["legal-pack lists the unreviewed prevails line"] = [x[0] for x in legal_pack_items(c2, "de")] == ["sh::MSG_LEGAL_PREVAILS"]
        open(rv_path, "w", encoding="utf-8").write(rv_all)
        quiet(cmd_stale, c2)
        t = open(en_sh).read().replace('MSG_CONSENT_X="I agree to %s"', 'MSG_CONSENT_X="I fully agree to %s"')
        open(en_sh, "w").write(t)
        results["a review of OLD English does not cover new English"] = quiet(cmd_check, c2) == 1
        # legal_english_only (ruling 2026-10-22): the reviewed translation above no
        # longer ships; check fails until `stale` puts the English back.
        open(en_sh, "w").write(t.replace("I fully agree", "I agree"))
        c3 = dict(c2, legal_english_only=True)
        results["legal_english_only: a REVIEWED legal translation fails"] = quiet(cmd_check, c3) == 1
        quiet(cmd_stale, c3)
        results["legal_english_only: stale ships the English"] = ShellCatalogue(c3["catalogues"][1]).read("de").get("MSG_CONSENT_X") == "I agree to %s"
        results["legal_english_only: check passes with English"] = quiet(cmd_check, c3) == 0
        results["legal_english_only: legal-approve refuses"] = _refused(cmd_legal_approve, c3, ["de", "sh::MSG_CONSENT_X", "--by", "R00", "--date", "2026-10-23"])
        # emphasis markers: {braces} wrap a target-language word, not a placeholder
        c4 = dict(c2, emphasis_marker_keys=["tag"])
        _t = types.SimpleNamespace(src="The world {does} revolve around you.", key="tag", ctx="", uid="x::tag", kind="other")
        results["marker: local emphasis word passes"] = mech(_t, "Jane Doe sagt, die Welt dreht sich {DOCH} um dich.", c4) == []
        results["marker: multi-word / non-Latin emphasis passes"] = mech(_t, "世界は、{やっぱり}あなたを中心に回っている。", c4) == []
        results["marker: English word left in fails"] = any("English word" in e for e in mech(_t, "Jane Doe sagt, die Welt dreht sich {does} um dich.", c4))
        results["marker: dropped marker fails"] = any("emphasis markers" in e for e in mech(_t, "Jane Doe sagt, die Welt dreht sich doch um dich.", c4))
        results["marker: without the exemption {DOCH} is a placeholder defect"] = any("placeholders" in e for e in mech(_t, "Jane Doe sagt, die Welt dreht sich {DOCH} um dich.", c2))
        _p = types.SimpleNamespace(src="Hi {name}, the world {does} turn.", key="tag", ctx="", uid="x::tag", kind="other")
        results["marker: a real {placeholder} beside it is still checked"] = any("placeholders" in e or "emphasis markers" in e for e in mech(_p, "Hallo, die Welt dreht sich {DOCH}.", c4))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for k, v in results.items():
        print(f"  {'ok  ' if v else 'FAIL'} {k}")
    ok = all(results.values())
    print(f"SELF-TEST {'PASS' if ok else 'FAIL'} ({sum(results.values())}/{len(results)})")
    return 0 if ok else 1


def _refused(f, *a):
    try:
        _quiet(f, *a)
    except SystemExit as e:
        return bool(e.code) and e.code != 0
    return False


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
              "adopt": lambda: cmd_adopt(cfg),
              "legal-list": lambda: cmd_legal_list(cfg), "legal-approve": lambda: cmd_legal_approve(cfg, sys.argv[2:]),
              "legal-pack": lambda: cmd_legal_pack(cfg, sys.argv[2:]), "run": lambda: cmd_run(cfg, gl, dry="--dry-run" in sys.argv),
              "self-test": lambda: cmd_self_test(cfg)}[cmd]())
