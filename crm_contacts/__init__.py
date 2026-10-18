"""Dex and Mesh (formerly Clay) contact exports -> one vCard 3.0 file the
owner opens once into Apple Contacts, which Ostler already reads.

Why this route: no Ostler importer reads a contact CSV (contact_syncer's
import_all reads LinkedIn's Connections.csv and platform JSON only), and
Ostler's people graph is fed from Apple Contacts. Apple Contacts can import a
CSV itself (File > Import) but asks the owner to label every column by hand;
a vCard needs no mapping. No network, no Contacts write from here: the owner
double-clicks the .vcf (Contacts' own import, its own confirmation sheet).

Formats:
- Dex: Settings > Export. Contacts columns per Dex's guide
  (guide.getdex.com/integrations/exporting-from-dex): Id, Name (or First /
  Last / Full Name), Title, Company, Description, Birthday, Email, Phone,
  Last interaction, Keep-in-touch frequency, Twitter, LinkedIn, Facebook,
  Groups. Column names CONFIRMED by Dex's docs (via search summary);
  multi-value separators (comma, semicolon, ":::") ASSUMED.
- Mesh: Settings > General > Export my Data; CSV emailed from notify@me.sh,
  "backward compatible with" Google's contacts format
  (library.me.sh/hc/en-us/articles/6821989456027). Column names are NOT
  documented: Google's contacts CSV headers (both the legacy "given name /
  E-mail 1 - Value" and the newer "First Name / E-mail 1 - Value") ASSUMED.
"""
from __future__ import annotations

import csv
import io
import re
from dataclasses import dataclass, field
from pathlib import Path

__all__ = ["Person", "convert", "detect_csv", "read_csv", "to_vcard"]

_SPLIT = re.compile(r"\s*(?::::|;|,|\n)\s*")


@dataclass
class Person:
    full_name: str = ""
    given: str = ""
    family: str = ""
    org: str = ""
    title: str = ""
    birthday: str = ""
    note: str = ""
    emails: list = field(default_factory=list)
    phones: list = field(default_factory=list)
    urls: list = field(default_factory=list)
    groups: list = field(default_factory=list)


def _norm(h: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", h.lower()).strip()


def _header(path: Path) -> tuple[list[str], str]:
    text = Path(path).read_text(encoding="utf-8-sig")
    hdr = next(csv.reader(io.StringIO(text)), [])
    return [_norm(h) for h in hdr], text


def _kind(hdr: list[str]) -> str | None:
    s = set(hdr)
    if {"keep in touch frequency", "last interaction"} & s and ("email" in s or "emails" in s):
        return "dex"
    if any(h.startswith("e mail 1") for h in hdr) and ({"given name", "first name", "name"} & s):
        return "mesh"
    return None


def detect_csv(path: Path) -> str | None:
    try:
        return _kind(_header(path)[0])
    except (OSError, ValueError, UnicodeDecodeError):
        return None


def _vals(v: str) -> list[str]:
    return [x for x in (p.strip() for p in _SPLIT.split(v or "")) if x]


def _uniq(xs):
    out = []
    for x in xs:
        if x and x not in out:
            out.append(x)
    return out


def _row_dex(r: dict) -> Person:
    g = lambda *ks: next((r[k].strip() for k in ks if (r.get(k) or "").strip()), "")  # noqa: E731
    given, family = g("first name"), g("last name")
    full = g("full name", "name") or " ".join(x for x in (given, family) if x)
    return Person(full_name=full, given=given, family=family, org=g("company"), title=g("title"),
                  birthday=g("birthday"), note=g("description"),
                  emails=_uniq(e for e in _vals(g("email", "emails")) if "@" in e),
                  phones=_uniq(p for p in re.split(r"\s*(?::::|;|\n)\s*", g("phone", "phones")) if p.strip()),
                  urls=_uniq(u for k in ("linkedin", "twitter", "facebook") for u in _vals(r.get(k) or "")),
                  groups=_uniq(_vals(g("groups", "group"))))


def _row_mesh(r: dict) -> Person:
    g = lambda *ks: next((r[k].strip() for k in ks if (r.get(k) or "").strip()), "")  # noqa: E731
    given, family = g("given name", "first name"), g("family name", "last name")
    full = g("name") or " ".join(x for x in (given, g("additional name", "middle name"), family) if x)
    multi = lambda pfx: _uniq(r[k].strip() for k in r if k and k.startswith(pfx) and k.endswith("value")  # noqa: E731
                              and (r[k] or "").strip())
    emails = [e for v in multi("e mail ") for e in re.split(r"\s*:::\s*", v) if "@" in e]
    phones = [p for v in multi("phone ") for p in re.split(r"\s*:::\s*", v) if p]
    groups = [x for x in re.split(r"\s*:::\s*", g("group membership", "labels")) if x and not x.startswith("*")]
    return Person(full_name=full, given=given, family=family,
                  org=g("organization 1 name", "organization name"),
                  title=g("organization 1 title", "organization title"), birthday=g("birthday"),
                  note=g("notes"), emails=_uniq(emails), phones=_uniq(phones),
                  urls=multi("website "), groups=_uniq(groups))


def read_csv(path: Path) -> tuple[str, list[Person]]:
    hdr, text = _header(path)
    kind = _kind(hdr)
    if kind is None:
        raise ValueError("not a Dex or Mesh contacts export")
    rows = csv.reader(io.StringIO(text))
    next(rows, None)
    fn = _row_dex if kind == "dex" else _row_mesh
    people = []
    for raw in rows:
        p = fn(dict(zip(hdr, raw)))
        if p.full_name or p.emails or p.phones:
            people.append(p)
    return kind, people


def _esc(v: str) -> str:
    return (v.replace("\\", "\\\\").replace("\r\n", "\n").replace("\n", "\\n")
            .replace(",", "\\,").replace(";", "\;"))


def _fold(line: str) -> str:
    b = line.encode()
    if len(b) <= 75:
        return line
    out, cur = [], b""
    for ch in line:
        e = ch.encode()
        if len(cur) + len(e) > (75 if not out else 74):
            out.append(cur.decode())
            cur = b""
        cur += e
    out.append(cur.decode())
    return "\r\n ".join(out)


def to_vcard(p: Person, source_label: str) -> str:
    fn = p.full_name or (p.emails[0] if p.emails else p.phones[0])
    lines = ["BEGIN:VCARD", "VERSION:3.0", f"FN:{_esc(fn)}",
             f"N:{_esc(p.family)};{_esc(p.given)};;;"]
    if p.org:
        lines.append(f"ORG:{_esc(p.org)}")
    if p.title:
        lines.append(f"TITLE:{_esc(p.title)}")
    lines += [f"EMAIL;TYPE=INTERNET:{_esc(e)}" for e in p.emails]
    lines += [f"TEL:{_esc(t)}" for t in p.phones]
    lines += [f"URL:{_esc(u)}" for u in p.urls]
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", p.birthday or ""):
        lines.append(f"BDAY:{p.birthday}")
    if p.note:
        lines.append(f"NOTE:{_esc(p.note)}")
    if p.groups:
        lines.append("CATEGORIES:" + ",".join(_esc(g) for g in p.groups))
    lines += [f"X-OSTLER-SOURCE:{source_label}", "END:VCARD"]
    return "\r\n".join(_fold(l) for l in lines) + "\r\n"


LABELS = {"dex": "Dex", "mesh": "Mesh"}


def convert(src: Path, dst: Path) -> int:
    kind, people = read_csv(src)
    tmp = Path(dst).with_suffix(".vcf.tmp")
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        for p in people:
            f.write(to_vcard(p, LABELS[kind]))
    tmp.replace(dst)
    return len(people)
