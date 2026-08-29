#!/usr/bin/env python3
"""pii_name_guard.py -- the PERSON-NAME guard, and it REFUSES.

WHY THIS EXISTS, and why the guards that came before it did not work
====================================================================
Every PII guard in HR015 and CM051 matches on SHAPE: mailbox patterns, phone
patterns, digit runs, /Users/<name>/ home paths. Those are the right shape for
an identifier and the WRONG shape for a name, because

    A HUMAN NAME HAS NO SHAPE.

So a real person's name is structurally invisible to every guard these repos
had, and five months of scrubs reported clean over real names. On 2026-08-14 a
scrub of one module reported "12 hits to 10" and left the names untouched --
its detector was mailbox-shaped, so the names were never candidates.

CM041 solved this in tests/test_no_unknown_person_names.py and neither of these
repos had the equivalent. This is that inversion, hardened into a blocking gate.

THE INVERSION
=============
Not a denylist. A denylist can only catch a value somebody already wrote down;
it can never catch the first leak of a name nobody has enumerated, and "the
names I know about" is exactly the green that kept being wrong.

This is a PERMIT-LIST. It lists who is ALLOWED -- the approved synthetic cast
plus explicit technical vocabulary -- and anything else that looks like a
person's name is a FINDING. A name nobody has thought about is suspicious by
default instead of exempt by default.

FAIL CLOSED, in four specific ways
==================================
1. CANNOT-RUN IS NOT A PASS. Missing permit-list, unreadable registry,
   unparseable row, no files resolved -- every one of them exits 2. Callers
   must treat any non-zero as BLOCK. There is no code path that reports clean
   without having actually examined something.

2. THE POSITIVE CONTROL FIRES ON EVERY RUN. A synthetic known-bad name is
   composed from fragments at runtime and fed to the real predicate. If it is
   not flagged, the detector is broken and the run REFUSES TO REPORT -- it does
   not fall through to "no findings". A detector that cannot demonstrate it
   still detects is not evidence of absence. The negative half runs too: an
   approved cast name must NOT be flagged, so a predicate that flags everything
   is caught as well.

3. THE DENOMINATOR IS ALWAYS PRINTED. Files read, candidates examined,
   cleared-by-reason, excluded. A zero over zero reads identical to a zero over
   ten thousand, so zero examined is a FAILURE, not a pass.

4. NO PATH IS EXCLUDED SILENTLY. Test directories were excluded by design, and
   that exclusion is precisely why real data survived in them. Anything skipped
   needs a row with a reason in .pii-name-registry.tsv, and the skipped count is
   printed separately so it can never be mistaken for zero.

TWO TIERS, and the difference is stated rather than hidden
==========================================================
STRICT paths (the identity modules, their tests and fixtures, the vendored
copies of both) get all three arms: capitalised name PAIRS, bare capitalised
TOKENS, and identifier SHAPE. Nothing outside the cast survives there.

The bare-TOKEN arm matters and is not decoration: CM041's own adjudicated
identifier_quality.py still carried an operator surname fragment and two given
names as LONE tokens while its pair guard was green. Pairs alone are not enough.

BASELINE paths (the rest of the repo -- docs, markdown, prose) get the pair arm
against a recorded BASELINE. Every pair already present is recorded, and the
guard BLOCKS on any pair that is not. That is regression-proof rather than
clean, it is labelled UNREVIEWED where it is unreviewed, and the count is
printed. It is not an exclusion: a new name in a doc still REDs.

THE BASELINE IS HASHED, and that is not decoration. A registry that listed the
pairs verbatim would be a file, in the repo, containing every name the sweep
found -- the guard would publish the leak it exists to stop. This is the same
trap as a vendor divergence patch, whose minus lines are the SOURCE side, so
scrubbing only the copy writes the original into the patch. Baseline rows are
sha256 prefixes of the lowercased pair. They can confirm "this exact pair was
already here" and they cannot be read back into a name.

Exit codes
  0  clean            -- control fired, N files examined, no findings
  1  findings         -- BLOCK
  2  CANNOT-RUN       -- BLOCK. Never, under any circumstances, a pass.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

REGISTRY_NAME = ".pii-name-registry.tsv"

# ---------------------------------------------------------------------------
# Reading the repo. Binary and oversize files are skipped by TYPE, counted, and
# reported -- not silently dropped.
# ---------------------------------------------------------------------------
SKIP_DIRS = {
    ".git", "node_modules", "__pycache__", ".venv", "venv", ".mypy_cache",
    ".pytest_cache", ".ruff_cache", ".tox", "site-packages", "Pods",
    ".build", "DerivedData",
}
BINARY_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".icns", ".ico", ".pdf",
    ".zip", ".gz", ".tgz", ".bz2", ".xz", ".dmg", ".mp3", ".mp4", ".mov",
    ".wav", ".ttf", ".otf", ".woff", ".woff2", ".eot", ".so", ".dylib",
    ".pyc", ".pkl", ".db", ".sqlite", ".sqlite3", ".realm", ".car",
    ".xcuserstate", ".pack", ".idx", ".jar", ".class", ".bin", ".o", ".a",
}
MAX_BYTES = 4 * 1024 * 1024


# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------
def _digest(pair: str) -> str:
    """Stable 16-hex prefix of the lowercased pair.

    The baseline stores this, never the pair. A one-way digest can answer "was
    this exact pair already here" without the registry itself becoming a list
    of everybody's names.
    """
    return hashlib.sha256(pair.lower().encode("utf-8")).hexdigest()[:16]


_PAIR = re.compile(r"\b([A-Z][a-z]{1,})[ \t]+([A-Z][a-z]{1,})\b")
# Names carrying a lowercase nobiliary particle. The pair regex above is
# STRUCTURALLY blind to these: a lowercase word sits BETWEEN the two
# capitalised ones, so `[A-Z][a-z]+\s+[A-Z][a-z]+` never matches and the name
# reads as clean. Found 2026-08-15 in role_addresses.py, in a PUBLIC repo,
# while a ported permit-list guard reported that file green.
#
# A guard blind to every Dutch, German, French, Spanish, Portuguese and Arabic
# surname is not a guard for a product that ships worldwide.
#
# Ported from HR015 #371 (ostler_fda/tests/test_no_unknown_person_names.py) so
# the whole-tree layer and the scoped layer cannot disagree about what a name
# looks like. CM041 still carries the version without it.
_PARTICLES = r"(?:van|von|de|del|della|di|da|der|den|dos|das|le|la|bin|ibn|al|ter|op)"
_PARTICLE_PAIR = re.compile(
    r"\b([A-Z][a-z]+)\s+((?:%s)(?:\s+%s)?)\s+([A-Z][a-z]+)\b" % (_PARTICLES, _PARTICLES)
)

_TOKEN = re.compile(r"\b([A-Z][a-z]{2,})\b")
_MAILBOX = re.compile(r"\b([A-Za-z][A-Za-z0-9._%+-]{1,63})@([A-Za-z0-9.-]+\.[A-Za-z]{2,})")
_LOCAL_SPLIT = re.compile(r"[._\-]+")
_PHONE = re.compile(r"\+?\d[\d\s().-]{7,}\d")

# RFC 2606 / 6761 reserved for documentation. Anything else that parses as an
# address is treated as somebody's real address.
_SYNTHETIC_EMAIL_DOMAINS = {"example.com", "example.org", "example.net"}
_SYNTHETIC_EMAIL_SUFFIXES = (".example", ".invalid", ".test", ".localhost")
# Ofcom drama ranges: 07700 900xxx, 020 7946 0xxx, 01632 960xxx.
_RESERVED_PHONE_MARKERS = ("7700900", "79460", "1632960")
_REPEATED_DIGIT = re.compile(r"(\d)\1{5,}")

# A hyphenated ROLE local part (`no-reply`, `mailer-daemon`, `inmail-hit-reply`)
# splits into two word-ish parts and reads as first.last to a naive splitter.
# It is a service address, and flagging it trains the reader to ignore the arm.
# Mirrors ostler_fda/role_addresses.py::_ROLE_LOCALS -- the same rule, so the
# guard and the module cannot drift into disagreeing about what a role is.
_ROLE_LOCAL_WORDS = {
    "no", "noreply", "reply", "donotreply", "not", "do", "mailer", "daemon",
    "inmail", "hit", "messages", "message", "notifications", "notification",
    "notify", "alerts", "alert", "invitations", "invitation", "invite",
    "invites", "news", "newsletter", "newsletters", "digest", "updates",
    "update", "info", "hello", "contact", "support", "help", "helpdesk",
    "admin", "billing", "accounts", "account", "sales", "marketing", "team",
    "mail", "bounce", "bounces", "postmaster", "webmaster", "automated",
    "auto", "system", "robot", "bot", "members", "member", "community",
    "social", "security", "service", "email", "bulletin", "kontakt",
    "nyhetsbrev", "rundbrief",
}


class Registry:
    """The permit-list, the tier map and the baseline, in one TSV.

    Fail closed on every failure mode a registry has: absent, unreadable,
    empty, or carrying a row this parser does not understand. A guard that
    shrugs at a malformed registry is a guard that can be disabled with a typo.
    """

    KINDS = {"cast", "phrase", "strict", "selfcheck", "baseline", "skip"}

    def __init__(self, path: Path):
        self.path = path
        self.cast: set[str] = set()
        self.phrases: set[str] = set()
        self.strict: list[str] = []
        self.selfcheck: list[str] = []
        self.baseline: set[str] = set()
        self.baseline_unreviewed = 0
        self.skips: list[tuple[str, str]] = []
        self.rows = 0

    def load(self) -> None:
        if not self.path.is_file():
            raise CannotRun(
                f"no permit-list registry at {self.path}. It is the whole "
                "guard: without it every name would be unknown and every file "
                "would RED, which is indistinguishable from the guard being "
                "deleted. Refusing to run."
            )
        try:
            text = self.path.read_text(encoding="utf-8")
        except OSError as exc:
            raise CannotRun(f"cannot read {self.path}: {exc}")

        for lineno, raw in enumerate(text.splitlines(), 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                raise CannotRun(
                    f"{self.path}:{lineno}: expected 'kind<TAB>value<TAB>reason', "
                    f"got {len(parts)} field(s). A row nobody can parse is a row "
                    "nobody reviewed."
                )
            kind, value, reason = parts[0].strip(), parts[1].strip(), "\t".join(parts[2:]).strip()
            if kind not in self.KINDS:
                raise CannotRun(
                    f"{self.path}:{lineno}: unknown kind {kind!r}. "
                    f"Known kinds: {sorted(self.KINDS)}."
                )
            if not value or not reason:
                raise CannotRun(
                    f"{self.path}:{lineno}: empty value or reason. "
                    "If you cannot write why it is permitted, it is not permitted."
                )
            self.rows += 1
            if kind == "cast":
                self.cast.add(value.lower())
            elif kind == "phrase":
                self.phrases.add(value.lower())
            elif kind == "strict":
                self.strict.append(value)
            elif kind == "selfcheck":
                # PAIR arm only. A guard's own controls deliberately carry a
                # mailbox shape and fragments of a synthetic name, so running
                # the TOKEN and SHAPE arms over them turns the proof-of-
                # detection into a finding. The PAIR arm still runs, with NO
                # baseline, because prose is exactly where a real name got into
                # a guard file: #371's own comment carried one, and that file
                # excluded itself from its own scope entirely.
                self.selfcheck.append(value)
            elif kind == "baseline":
                if not re.fullmatch(r"[0-9a-f]{16}", value):
                    raise CannotRun(
                        f"{self.path}:{lineno}: baseline rows must be a 16-hex "
                        "sha256 prefix, never a name. A registry that lists the "
                        "pairs verbatim publishes the leak it exists to stop."
                    )
                self.baseline.add(value)
                if reason.startswith("UNREVIEWED"):
                    self.baseline_unreviewed += 1
            elif kind == "skip":
                self.skips.append((value, reason))

        if not self.cast:
            raise CannotRun(
                f"{self.path} loaded {self.rows} row(s) but zero 'cast' entries. "
                "An empty permit-list makes every name a finding, which is the "
                "same failure as the denylist that loaded zero patterns."
            )
        if not self.strict:
            raise CannotRun(
                f"{self.path} declares no 'strict' paths. With no strict tier "
                "the guard only defends a baseline, and the identity modules -- "
                "the whole reason this exists -- would go unexamined."
            )


class CannotRun(Exception):
    """Exit 2. Never a pass."""


# Grammatical and sentence-leading words. A capitalised pair headed by one of
# these is a sentence, not a person; flagging prose trains the reader to ignore
# the guard, which is worse than the misses it would catch.
SENTENCE_WORDS = set("""
a an the this that these those it its is was are were be been being not no nor
if so in on at to for and or but as by of from with without into onto over
under one two three four five six seven eight nine ten all any each every both
some none most when where which what who whom whose why how there here then
than same other another first last only just also still even never always note
see read use used using given real true false word words name names named left
right before after next do does did done can could will would shall should may
might must have has had get gets got make makes made take takes taken run runs
ran add added set sets new old now yes we you they he she i me my our your
their his her them us because while until unless though although however
therefore instead rather already again once twice very much many more less
least best worst good bad well better worse fix fixed fixes per via vs let lets
keep keeps stop stops start starts open opens close closes write writes wrote
check checks prove proves found find finds call calls called said says say know
knows known think thinks want wants need needs look looks give gives put puts
come comes came go goes went leave leaves hold holds held turn turns cut cuts
ship ships shipped build builds built test tests tested pass passes passed fail
fails failed either neither such own about above below between against during
through across along around behind beyond within upon toward towards off out up
down back away yet far near long short big small high low full empty different
""".split())


_LOWER_WORD = re.compile(r"(?<![A-Za-z0-9_])([a-z]{3,})(?![A-Za-z0-9_])")


LEXICON_MIN_FILES = 8


def build_lexicon(chunks) -> set:
    """Ordinary lowercase vocabulary: words present in >= LEXICON_MIN_FILES files.

    Built from the same bytes the guard examines, so it cannot drift from the
    tree and needs no dictionary on the runner -- a guard that depends on
    /usr/share/dict/words is a guard that CANNOT-RUNs on a clean CI image.

    THE FREQUENCY FLOOR IS THE WHOLE POINT, and a version without it shipped
    for about an hour on 2026-08-15 before being caught. Without it THE LEAK
    POISONS ITS OWN DETECTOR: a surname that appears lowercase even once --
    inside a mail local part, a slug, a filename -- enters the lexicon and
    then clears its own capitalised form everywhere else. Two real surnames
    were cleared exactly that way, one of them present in a single file.

    An ordinary English word appears in dozens of files in a repo this size;
    a leaked surname appears in one or two. A rare technical word that falls
    below the floor is not waved through, it is FLAGGED, and clearing it costs
    an explicit `phrase` row with a written reason. That is the fail-closed
    direction: unfamiliar means suspicious, never exempt.
    """
    seen: dict[str, set] = {}
    for rel, text in chunks:
        for m in _LOWER_WORD.finditer(text):
            seen.setdefault(m.group(1), set()).add(rel)
    return {w for w, files in seen.items() if len(files) >= LEXICON_MIN_FILES}


def iter_files(root: Path, skips: list[tuple[str, str]]):
    """Yield (path, relpath). Returns counters for everything NOT yielded."""
    stats = {"binary": 0, "oversize": 0, "unreadable": 0, "skipped_registry": 0}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in sorted(filenames):
            p = Path(dirpath) / fn
            try:
                rel = str(p.relative_to(root))
            except ValueError:
                continue
            if any(fnmatch.fnmatch(rel, pat) for pat, _ in skips):
                stats["skipped_registry"] += 1
                continue
            if p.suffix.lower() in BINARY_SUFFIXES:
                stats["binary"] += 1
                continue
            try:
                if p.is_symlink() or not p.is_file():
                    continue
                if p.stat().st_size > MAX_BYTES:
                    stats["oversize"] += 1
                    continue
                raw = p.read_bytes()
            except OSError:
                stats["unreadable"] += 1
                continue
            if b"\x00" in raw[:8192]:
                stats["binary"] += 1
                continue
            yield p, rel, raw.decode("utf-8", errors="replace")
    yield None, None, stats


def pair_offenders(text: str, reg: Registry, baseline_ok: bool):
    """Capitalised two-word phrases that are not on the permit-list."""
    out = []
    examined = 0
    for lineno, line in enumerate(text.splitlines(), 1):
        found = [(m.group(0), m.group(1).lower(), m.group(2).lower())
                 for m in _PAIR.finditer(line)]
        # The particle limb: the particle itself is never the deciding token,
        # the given name and the surname either side both have to be cast.
        found += [(m.group(0), m.group(1).lower(), m.group(3).lower())
                  for m in _PARTICLE_PAIR.finditer(line)]
        for pair, a, b in found:
            examined += 1
            if pair.lower() in reg.phrases:
                continue
            if a in SENTENCE_WORDS or b in SENTENCE_WORDS:
                continue
            if a in reg.cast and b in reg.cast:
                continue
            if baseline_ok and _digest(pair) in reg.baseline:
                continue
            out.append((lineno, "PAIR", pair))
    return out, examined


def token_offenders(text: str, reg: Registry, lexicon: set):
    """Bare capitalised tokens outside the cast. STRICT tier only.

    This is the arm that sees what a pair detector cannot. It is deliberately
    not run repo-wide: on prose it would flag every product noun, and a guard
    that cries wolf is a guard somebody deletes.

    THE NOISE FLOOR IS THE REPO'S OWN LOWERCASE VOCABULARY, not a word list
    and not a path exclusion. "Canonical", "Deliberately", "Splitting" are
    sentence-initial ordinary words, and every one of them also occurs in this
    repo in lowercase. A surname does not: nobody writes "whittet" in running
    text. So a capitalised token is cleared when the same token appears
    somewhere in the corpus as a standalone lowercase word.

    Deliberate residual: a given name that is also an English word (Mark,
    Grace, Bill) clears here. The PAIR arm still catches it the moment it has
    a surname beside it, which is when it becomes identifying.
    """
    out = []
    examined = 0
    for lineno, line in enumerate(text.splitlines(), 1):
        for m in _TOKEN.finditer(line):
            examined += 1
            t = m.group(1)
            lc = t.lower()
            if lc in reg.cast or lc in SENTENCE_WORDS or lc in reg.phrases:
                continue
            if lc in lexicon:
                continue
            out.append((lineno, "TOKEN", t))
    return out, examined


def identifier_offenders(text: str):
    """Email/phone-shaped tokens that are not demonstrably synthetic.

    Returns (findings, mailboxes_examined, phones_examined). The two counts are
    kept APART: a mailbox detector is blind to phone shape and a phone detector
    is blind to mailboxes, so one combined number would let a zero in either
    hide behind a healthy total in the other.
    """
    out = []
    n_mail = 0
    n_phone = 0
    for lineno, line in enumerate(text.splitlines(), 1):
        for m in _MAILBOX.finditer(line):
            n_mail += 1
            domain = m.group(2).lower()
            if domain in _SYNTHETIC_EMAIL_DOMAINS:
                continue
            if domain.endswith(_SYNTHETIC_EMAIL_SUFFIXES):
                continue
            local = m.group(1)
            parts = [x for x in _LOCAL_SPLIT.split(local) if len(x) > 1]
            # A role/bulk local part on a real domain is a service, not a
            # person. Only a person-shaped local part is a finding here.
            if len(parts) < 2:
                continue
            if any(x.lower() in _ROLE_LOCAL_WORDS for x in parts):
                continue
            out.append((lineno, "MAILBOX", f"{parts[0][:1]}*.{parts[1][:1]}*@{domain}"))
        for m in _PHONE.finditer(line):
            n_phone += 1
            digits = re.sub(r"\D", "", m.group(0))
            if len(digits) < 9:
                continue
            if any(k in digits for k in _RESERVED_PHONE_MARKERS):
                continue
            if _REPEATED_DIGIT.search(digits):
                continue
            out.append((lineno, "PHONE", f"{len(digits)}-digit run"))
    return out, n_mail, n_phone


# ---------------------------------------------------------------------------
# The positive control. Composed from fragments so this file never carries the
# thing it hunts: a gate whose control is itself a finding is a gate that has
# to exclude itself, and self-exclusion is how blind spots start.
# ---------------------------------------------------------------------------
def run_control(reg: Registry) -> tuple[bool, str]:
    a, b = "Wil" + "helmina", "Fitz" + "gerald"
    probe = f'# {a} {b} merged with Bob Doe\n'
    found, _ = pair_offenders(probe, reg, baseline_ok=False)
    if not any(v == f"{a} {b}" for _, _, v in found):
        return False, "a synthetic unknown name was NOT flagged by the PAIR arm"

    # The particle limb gets its OWN control. Its bug was that it did not fire
    # at all, which a shared control would have hidden behind the plain pair.
    pa = "Nie" + "ks"
    pb = "Uij" + "link"
    pprobe = f"# {pa} van {pb} signed off\n"
    pfound, _ = pair_offenders(pprobe, reg, baseline_ok=False)
    if not any(v == f"{pa} van {pb}" for _, _, v in pfound):
        return False, "a name with a lowercase particle was NOT flagged"
    pclean, _ = pair_offenders("# Jane van Doe is one person\n", reg,
                               baseline_ok=False)
    if pclean:
        return False, "an approved-cast name with a particle WAS flagged"

    tfound, _ = token_offenders(probe, reg, lexicon=set())
    if not any(v == a for _, _, v in tfound):
        return False, "a synthetic unknown token was NOT flagged by the TOKEN arm"

    ifound, _m, _p = identifier_offenders('x = "someone.else@consumer-mail.co"\n')
    if not any(k == "MAILBOX" for _, k, _ in ifound):
        return False, "a non-reserved mailbox was NOT flagged by the SHAPE arm"

    # Negative half: a predicate that flags everything passes the above.
    clean, _ = pair_offenders('# "Jane Doe" and "Bob Doe" are one person\n',
                              reg, baseline_ok=False)
    if clean:
        return False, f"an approved cast name WAS flagged: {[v for _, _, v in clean]}"
    return True, "PAIR + PARTICLE + TOKEN + SHAPE arms all fired; cast not flagged"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--registry", default=None)
    ap.add_argument("--print-baseline", action="store_true",
                    help="emit registry rows for every current finding (bootstrap only)")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    reg_path = Path(args.registry) if args.registry else root / REGISTRY_NAME
    reg = Registry(reg_path)

    try:
        reg.load()
    except CannotRun as exc:
        print(f"pii-name-guard: CANNOT-RUN -- {exc}", file=sys.stderr)
        return 2

    ok, why = run_control(reg)
    print(f"pii-name-guard: CONTROL -- {why}")
    if not ok:
        print("pii-name-guard: CANNOT-RUN -- the positive control did not fire.",
              file=sys.stderr)
        print("  The detector cannot demonstrate that it still detects, so a",
              file=sys.stderr)
        print("  clean result from it would be meaningless. REFUSING to report.",
              file=sys.stderr)
        return 2

    files = 0
    strict_files = 0
    self_files = 0
    candidates = 0
    # PER-CLASS denominators. A clean NAME scan says nothing about mailboxes
    # and a clean mailbox scan says nothing about phone shape -- the detector
    # for each is blind to the other two, and a single combined number hides
    # which of the three actually examined anything.
    seen = {"PAIR": 0, "TOKEN": 0, "MAILBOX": 0, "PHONE": 0}
    hit = {"PAIR": 0, "TOKEN": 0, "MAILBOX": 0, "PHONE": 0}
    findings: dict[str, list] = defaultdict(list)
    stats = {}
    corpus: list[tuple[str, str]] = []

    for p, rel, payload in iter_files(root, reg.skips):
        if p is None:
            stats = payload
            break
        files += 1
        corpus.append((rel, payload))

    # The lexicon is built from the WHOLE corpus, then the strict tier is
    # scanned against it. Two passes on purpose: a noise floor derived from
    # only the strict files would be tiny, and every ordinary word in them
    # would read as a name.
    lexicon = build_lexicon(corpus)

    for rel, payload in corpus:
        is_strict = any(fnmatch.fnmatch(rel, pat) for pat in reg.strict)
        is_self = any(fnmatch.fnmatch(rel, pat) for pat in reg.selfcheck)
        bad, n = pair_offenders(payload, reg,
                                baseline_ok=not (is_strict or is_self))
        candidates += n
        seen["PAIR"] += n
        if is_self:
            self_files += 1
        # `and not is_self` is LOAD-BEARING and it is a FIX, not a widening.
        # The selfcheck comment above says "PAIR arm only ... running the TOKEN
        # and SHAPE arms over them turns the proof-of-detection into a finding".
        # The code did not do that: TOKEN ran whenever a file was strict, and
        # selfcheck was consulted ONLY for the PAIR baseline. MEASURED 2026-08-29,
        # and one of the two pre-existing selfcheck rows was already half-dead:
        #   bin/pii_name_guard.py                       selfcheck, NOT strict -> TOKEN skipped, comment held
        #   vendor/ostler_fda/tests/test_no_unknown...  selfcheck AND strict  -> TOKEN ran, comment did NOT hold
        # strict-membership is the discriminator, which is why one worked and
        # one did not. The PAIR arm still runs over selfcheck files with NO
        # baseline (see baseline_ok above), so a genuinely new name in a control
        # corpus is still caught -- that is the protection that matters here.
        if is_strict:
            # Counted on MEMBERSHIP, not on whether the TOKEN arm ran. Moving
            # this inside the guard below would have made the DENOMINATOR print
            # "STRICT tier 11" for a registry that matches 12 files -- a gate
            # under-reporting its own scope is the failure this file exists to
            # prevent, and I introduced it in this very commit.
            strict_files += 1
        if is_strict and not is_self:
            tbad, tn = token_offenders(payload, reg, lexicon)
            ibad, imail, iphone = identifier_offenders(payload)
            seen["TOKEN"] += tn
            seen["MAILBOX"] += imail
            seen["PHONE"] += iphone
            candidates += tn + imail + iphone
            bad = bad + tbad + ibad
        for _ln, kind, _v in bad:
            hit[kind] = hit.get(kind, 0) + 1
        if bad:
            findings[rel].extend(bad)

    print("pii-name-guard: DENOMINATOR")
    print(f"  registry rows                {reg.rows}  ({reg_path.name})")
    print(f"    cast tokens                {len(reg.cast)}")
    print(f"    strict path patterns       {len(reg.strict)}")
    print(f"    baseline pairs             {len(reg.baseline)}  "
          f"(UNREVIEWED: {reg.baseline_unreviewed})")
    print(f"    registry skips             {len(reg.skips)}")
    print(f"  files examined               {files}")
    print(f"    of which STRICT tier       {strict_files}")
    print(f"    of which SELFCHECK (pair)  {self_files}")
    print(f"  candidate tokens examined    {candidates}")
    print("  PER CLASS (examined / findings) -- each detector is blind to the others")
    for k in ("PAIR", "TOKEN", "MAILBOX", "PHONE"):
        scope = "whole tree" if k == "PAIR" else "STRICT tier"
        print(f"    {k:<8} {seen[k]:>7} / {hit[k]:<5}  ({scope})")
    print(f"  corpus lexicon (>= {LEXICON_MIN_FILES} files)  {len(lexicon)}")
    print(f"  not examined (binary)        {stats.get('binary', 0)}")
    print(f"  not examined (oversize)      {stats.get('oversize', 0)}")
    print(f"  not examined (unreadable)    {stats.get('unreadable', 0)}")
    print(f"  not examined (registry skip) {stats.get('skipped_registry', 0)}")

    if files == 0 or candidates == 0:
        print("pii-name-guard: CANNOT-RUN -- examined 0 files or 0 candidates.",
              file=sys.stderr)
        print("  Zero findings over zero input reads exactly like zero findings",
              file=sys.stderr)
        print("  over ten thousand. That is not a pass.", file=sys.stderr)
        return 2

    dead = [k for k in ("TOKEN", "MAILBOX", "PHONE") if seen[k] == 0]
    if dead and strict_files:
        print(f"pii-name-guard: CANNOT-RUN -- class(es) {dead} examined ZERO "
              "candidates.", file=sys.stderr)
        print("  A class that looked at nothing reports clean exactly like a",
              file=sys.stderr)
        print("  class that looked at everything. The STRICT tier must contain",
              file=sys.stderr)
        print("  at least one instance of each shape, or the arm is untested.",
              file=sys.stderr)
        return 2

    if reg.selfcheck and self_files == 0:
        print("pii-name-guard: CANNOT-RUN -- selfcheck paths matched no files.",
              file=sys.stderr)
        print("  A guard file that moved out from under its own PAIR check is",
              file=sys.stderr)
        print("  unwatched. Fix the paths in the registry.", file=sys.stderr)
        return 2

    if strict_files == 0:
        print("pii-name-guard: CANNOT-RUN -- the STRICT tier matched no files.",
              file=sys.stderr)
        print("  A renamed or moved module silently leaves the strict tier and",
              file=sys.stderr)
        print("  the guard keeps passing. Fix the paths in the registry.",
              file=sys.stderr)
        return 2

    if args.print_baseline:
        seen = set()
        for rel, hits in sorted(findings.items()):
            for _ln, kind, val in hits:
                if kind != "PAIR":
                    continue
                d = _digest(val)
                if d in seen:
                    continue
                seen.add(d)
                print(f"baseline\t{d}\tUNREVIEWED-legacy: present before the "
                      f"2026-08-15 name sweep; first seen in {rel}")
        return 0

    if findings:
        total = sum(len(v) for v in findings.values())
        print(f"pii-name-guard: BLOCK -- {total} finding(s) in "
              f"{len(findings)} file(s)", file=sys.stderr)
        print("", file=sys.stderr)
        print("  Locations only. The VALUES are deliberately not printed: a",
              file=sys.stderr)
        print("  guard that echoes what it found copies PII into every CI log.",
              file=sys.stderr)
        print("", file=sys.stderr)
        for rel, hits in sorted(findings.items()):
            kinds = sorted({k for _l, k, _v in hits})
            lines = sorted({l for l, _k, _v in hits})[:12]
            print(f"  {rel}", file=sys.stderr)
            print(f"      {len(hits)} finding(s)  kinds={','.join(kinds)}  "
                  f"lines={lines}", file=sys.stderr)
        print("", file=sys.stderr)
        print("  FIX by renaming to the approved synthetic cast. Do NOT widen",
              file=sys.stderr)
        print("  the cast to admit a real person -- the cast is the cast, not a",
              file=sys.stderr)
        print("  record of what happens to be in the tree. Reserved values:",
              file=sys.stderr)
        print("  example.com / *.example for addresses, Ofcom drama ranges",
              file=sys.stderr)
        print("  (07700 900xxx, 020 7946 0xxx) for numbers.", file=sys.stderr)
        return 1

    print(f"pii-name-guard: CLEAN -- {candidates} candidate(s) across {files} "
          f"file(s), {strict_files} at STRICT")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CannotRun as exc:          # belt and braces: never fall through to 0
        print(f"pii-name-guard: CANNOT-RUN -- {exc}", file=sys.stderr)
        raise SystemExit(2)
