#!/usr/bin/env bash
# EVERY KNOWLEDGE COLLECTION THIS INSTALL WRITES MUST HAVE A RECORDED READER
# VERDICT, AND THE VERDICT MUST NOT BE STALE.
#
# ============================================================================
# THE DEFECT, AND THE REASON A GATE ON THE OTHER SIDE CANNOT CLOSE IT
# ============================================================================
#
# install.sh embeds Apple Notes into `apple_notes_knowledge`. The assistant's
# `pwg_knowledge_search` read `evernote_knowledge` and nothing else. Qdrant
# answers 404 for an unknown collection and the tool maps 404 to an empty
# result, so the customer's notes were absent from every knowledge search and
# nothing anywhere reported a fault. The miss arrives wearing the costume of
# "you have no matching notes".
#
# The READ side is fixed. MEASURED at the tag this installer pins, hub-v0.4.80,
# crates/zeroclaw-tools/src/pwg_knowledge_search.rs:56:
#
#     pub const KNOWLEDGE_COLLECTIONS: &[&str] =
#         &["evernote_knowledge", "apple_notes_knowledge"];
#
# iterated at :209, rank-merged at :215. Both are searched.
#
# 🔴 AND THE TEST GUARDING THAT IS A TAUTOLOGY. pwg_knowledge_search.rs:685-693
# asserts `KNOWLEDGE_COLLECTIONS.contains("apple_notes_knowledge")` against a
# hard-coded literal, beside a COMMENT citing an install.sh line number. It
# compares a constant to itself. It cannot open install.sh; CM051's CI cannot
# open the assistant repo. Measured: ZERO CM051 files name
# KNOWLEDGE_COLLECTIONS, against a positive control of 32 naming
# apple_notes_knowledge. A NINTH hydrate collection added here would go dark
# with every test on both sides green, which is exactly how the eighth did.
#
# ============================================================================
# WHAT THIS GATE ASSERTS, AND WHAT IT HONESTLY CANNOT
# ============================================================================
#
# It CANNOT read the assistant. Nothing in this repo can, and pretending
# otherwise by re-asserting a literal is the tautology above. What it does
# instead:
#
#   1. Every collection install.sh actually embeds into has a row in
#      OSTLER_KNOWLEDGE_COLLECTIONS, and every row is a collection install.sh
#      actually embeds into. Both directions. A new hydrate target with no
#      recorded verdict is a RED, which is the property the other side lacks.
#   2. Every verdict is one of exactly two words. "Nobody checked" is not a
#      verdict; it is a missing row.
#   3. Every `searched` collection is declared in scripts/install_manifest.tsv,
#      so the box walk enumerates it on a real box. Until #1598,
#      apple_notes_knowledge was in NO register on this side, so no walk ever
#      asked whether the collection a customer's notes went into exists.
#   4. THE ANTI-ROT ARM, and the only non-tautological one:
#      OSTLER_KNOWLEDGE_READER_VERSION must equal the assistant version this
#      installer pins. The verdicts were read at a tag; the moment the pin
#      moves they are a statement about a binary the customer no longer runs.
#      A pin bump is exactly when a reader can quietly lose a collection, so
#      the bump forces a re-verification or it stays red.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run. A CANNOT-RUN is not a pass: a
# register that could not be parsed has not agreed with anything.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
MANIFEST="${REPO}/scripts/install_manifest.tsv"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cannot() { printf 'CANNOT-RUN: %s\n' "$1" >&2; exit 2; }

[ -f "$SUBJECT" ]  || cannot "no install.sh at ${SUBJECT}"
[ -f "$MANIFEST" ] || cannot "no install_manifest.tsv at ${MANIFEST}"
command -v python3 >/dev/null 2>&1 || cannot "no python3"

python3 - "$SUBJECT" "$MANIFEST" "${REPO}/vendor/doctor/agent" <<'PY'
import os, re, sys

subject, manifest, agentdir = sys.argv[1], sys.argv[2], sys.argv[3]
PASS = FAIL = 0
def ok(m):
    global PASS; PASS += 1; print("  [PASS] " + m)
def bad(m):
    global FAIL; FAIL += 1; print("  [FAIL] " + m)
def cannot(m):
    print("CANNOT-RUN: " + m, file=sys.stderr); raise SystemExit(2)

sh = open(subject, encoding="utf-8", errors="replace").read()
lines = sh.split("\n")

# ── WHAT THE INSTALL ACTUALLY EMBEDS INTO ─────────────────────────────────
#
# Read from the EMBED CALL SITES, not from the register, because the register
# is the thing under test. A gate that derives both sides from one source
# cannot disagree with itself, which is the tautology this file exists to
# avoid repeating.
#
# Two shapes reach the embedder: a literal `--collection <name>` on the
# command line, and a `--collection "$VAR"` whose variable is assigned a
# knowledge collection name elsewhere in the file. Both are resolved; a
# `--collection` whose target cannot be resolved at all is reported rather
# than dropped, because a dropped call site is a silent under-count and this
# gate's whole value is the completeness of this set.
written = set()
unresolved = []
assigned = {}
for line in lines:
    m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)="([a-z_]+_knowledge)"\s*$', line)
    if m:
        assigned[m.group(1)] = m.group(2)
    m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)="\$\{[A-Za-z_][A-Za-z0-9_]*'
                 r':-([a-z_]+_knowledge)\}"\s*$', line)
    if m:
        assigned.setdefault(m.group(1), m.group(2))

for line in lines:
    if "--collection" not in line:
        continue
    if re.match(r'\s*#', line):
        continue            # a comment showing an example call is not a call
    m = re.search(r'--collection\s+"?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"?', line)
    if m:
        name = assigned.get(m.group(1))
        if name:
            written.add(name)
        else:
            unresolved.append(line.strip()[:110])
        continue
    m = re.search(r'--collection\s+"?([a-z_]+_knowledge)"?', line)
    if m:
        written.add(m.group(1))
        continue
    unresolved.append(line.strip()[:110])

# ── AND THE THREE WRITERS THAT ARE NOT IN install.sh ──────────────────────
#
# Measured while writing this gate, by running it: install.sh drives exactly
# ONE embed call site. The other three knowledge writers are the vendored
# Doctor importers, which shell out to the same embedder with their own
# resolved collection. Scanning install.sh alone reported evernote_knowledge
# as a dead register row, which would have sent the next reader to delete the
# row for the collection three of the four writers use.
#
# Two shapes, both present in the shipped tree: a module constant
# KNOWLEDGE_COLLECTION (notion, obsidian, after the #1974 unification) and an
# f-string `f"{source}_knowledge"` resolved against DEFAULT_SOURCE (evernote,
# the original shape). Both are read; a module with neither is REPORTED, not
# skipped, because a silently-skipped writer is how a collection goes dark.
importers = ("import_evernote.py", "import_notion.py", "import_obsidian.py")
seen_importers = 0
for fname in importers:
    path = os.path.join(agentdir, fname)
    if not os.path.isfile(path):
        unresolved.append("%s: absent from the vendored tree" % fname)
        continue
    text = open(path, encoding="utf-8", errors="replace").read()
    m = re.search(r'^KNOWLEDGE_COLLECTION\s*=\s*"([a-z_]+)"', text, re.M)
    if m:
        written.add(m.group(1)); seen_importers += 1; continue
    src = re.search(r'^DEFAULT_SOURCE\s*=\s*"([a-z_]+)"', text, re.M)
    tmpl = re.search(r'return f"\{source\}_knowledge"', text)
    if src and tmpl:
        written.add(src.group(1) + "_knowledge"); seen_importers += 1; continue
    unresolved.append("%s: no resolvable knowledge collection" % fname)

# CONTROL on that half: all three importers must have resolved. One silently
# unresolved importer would shrink the written set and could turn a live
# register row into a reported-dead one.
if seen_importers != len(importers):
    cannot("only %d of %d Doctor knowledge importers resolved to a "
           "collection; the writer set is incomplete and every 'dead row' "
           "verdict below would be suspect. Unresolved: %s"
           % (seen_importers, len(importers), unresolved))

# POSITIVE CONTROL ON THE SCANNER. apple_notes_knowledge is the collection
# this row is about and it is reachable by the variable route. If the scanner
# cannot see it, every "not written" verdict below is a false one and the
# control is what to investigate, not the subject.
if "apple_notes_knowledge" not in written:
    cannot("the embed-call-site scanner found no apple_notes_knowledge. "
           "install.sh drives `embed --collection \"$_HYDRATE_APPLENOTES_"
           "COLLECTION\"`, so the scanner is blind and its other answers "
           "cannot be trusted. Resolved targets: %s. Unresolved call sites: %s"
           % (sorted(written) or "none", unresolved or "none"))
if unresolved:
    bad("%d `--collection` call site(s) could not be resolved to a name, so "
        "the comparison below is over a SUBSET and its agreement means "
        "nothing: %s" % (len(unresolved), unresolved))
else:
    ok("every knowledge writer resolves to a collection: install.sh's embed "
       "call site(s) plus %d Doctor importer(s), %d collection(s) written "
       "in total (%s)" % (seen_importers, len(written), " ".join(sorted(written))))

# ── THE REGISTER ──────────────────────────────────────────────────────────
decl = [l for l in lines if l.startswith("OSTLER_KNOWLEDGE_COLLECTIONS=")]
if not decl:
    bad("OSTLER_KNOWLEDGE_COLLECTIONS is not declared in install.sh, so no "
        "collection this install writes has a recorded reader verdict and a "
        "new one cannot be noticed")
    register = {}
else:
    raw = decl[0].split("=", 1)[1].strip().strip('"')
    register = {}
    for pair in raw.split():
        if ":" not in pair:
            bad("OSTLER_KNOWLEDGE_COLLECTIONS entry %r is not <collection>:"
                "<verdict>" % pair)
            continue
        k, v = pair.split(":", 1)
        register[k] = v
    ok("OSTLER_KNOWLEDGE_COLLECTIONS records a verdict for %d collection(s)"
       % len(register))

# A ZERO DENOMINATOR READS AS SUCCESS. Every subset check below would pass
# over an empty register, so refuse to grade rather than print green.
if not register:
    bad("there is no register to check, so the four arms below have no "
        "subject and are NOT being graded")
    print("  %d pass, %d fail" % (PASS, FAIL))
    raise SystemExit(1)

# 1. both directions
missing = sorted(written - set(register))
if missing:
    bad("install.sh embeds into %s with no recorded reader verdict. A "
        "collection nothing has decided about is a collection that goes dark "
        "silently: Qdrant 404s an unknown name and the reader maps 404 to an "
        "empty result." % ", ".join(missing))
else:
    ok("every collection install.sh embeds into has a recorded reader verdict")

stale = sorted(set(register) - written)
if stale:
    bad("the register records a verdict for %s, which install.sh no longer "
        "embeds into. A register carrying a dead row stops being a "
        "description of the product." % ", ".join(stale))
else:
    ok("the register carries no collection the install does not write")

# 2. the verdict vocabulary
VERDICTS = ("searched", "excluded")
wrong = sorted("%s:%s" % (k, v) for k, v in register.items()
               if v not in VERDICTS)
if wrong:
    bad("verdict(s) %s are outside the vocabulary %s. There is no third "
        "state: \"nobody checked\" is a missing row, not a word."
        % (", ".join(wrong), "/".join(VERDICTS)))
else:
    ok("every verdict is one of %s" % "/".join(VERDICTS))

# 3. the walk can see them
man = open(manifest, encoding="utf-8", errors="replace").read().split("\n")
declared_cols = set()
for line in man:
    if line.startswith("#") or not line.strip():
        continue
    cols = line.split("\t")
    if len(cols) >= 4 and cols[0] == "qdrant_collection":
        declared_cols.add(cols[1])
# CONTROL: the manifest parse must have found the long-standing rows, or an
# empty set would make the membership test below pass for everything.
if "evernote_knowledge" not in declared_cols:
    cannot("the install_manifest.tsv parse found no evernote_knowledge row; "
           "it has been declared there since #615, so the parse is broken "
           "and its answers cannot be trusted. Parsed: %s"
           % (sorted(declared_cols) or "none"))
searched = sorted(k for k, v in register.items() if v == "searched")
undeclared = [c for c in searched if c not in declared_cols]
if undeclared:
    bad("%s is searched by the assistant and has no qdrant_collection row in "
        "scripts/install_manifest.tsv, so no box walk ever asks whether the "
        "collection the customer's content went into exists"
        % ", ".join(undeclared))
else:
    ok("all %d searched collection(s) are declared in install_manifest.tsv, "
       "so the walk enumerates them" % len(searched))

# 4. the anti-rot arm
ver_decl = [l for l in lines if l.startswith("OSTLER_KNOWLEDGE_READER_VERSION=")]
pin_decl = [l for l in lines if "OSTLER_ASSISTANT_VERSION=" in l
            and ":-" in l and not l.lstrip().startswith("#")]
if not ver_decl:
    bad("OSTLER_KNOWLEDGE_READER_VERSION is not declared, so the verdicts "
        "above name no binary and cannot be known to be stale")
elif not pin_decl:
    cannot("could not find the OSTLER_ASSISTANT_VERSION default in install.sh; "
           "without the pin there is nothing to compare the register's "
           "evidence against")
else:
    read_at = ver_decl[0].split("=", 1)[1].strip().strip('"')
    m = re.search(r'OSTLER_ASSISTANT_VERSION="\$\{OSTLER_ASSISTANT_VERSION'
                  r':-([^}]*)\}"', pin_decl[0])
    if not m:
        cannot("the OSTLER_ASSISTANT_VERSION line did not parse: %r"
               % pin_decl[0].strip()[:120])
    pinned = m.group(1)
    if not read_at or not pinned:
        cannot("one of the two versions parsed empty (read_at=%r pinned=%r); "
               "an empty-to-empty comparison would pass for anything"
               % (read_at, pinned))
    if read_at == pinned:
        ok("the reader verdicts were read at the assistant version this "
           "installer pins (%s), so they describe the binary the customer "
           "actually runs" % pinned)
    else:
        bad("the reader verdicts were read at assistant %s and this installer "
            "now pins %s. They are a statement about a binary the customer no "
            "longer runs. Re-read KNOWLEDGE_COLLECTIONS at the new tag and "
            "move both, or record the change. A pin bump is exactly when a "
            "reader can quietly lose a collection." % (read_at, pinned))

print("  %d pass, %d fail" % (PASS, FAIL))
raise SystemExit(1 if FAIL else 0)
PY
_rc=$?
[ "$_rc" -eq 2 ] && exit 2
if [ "$_rc" -ne 0 ]; then FAIL=$((FAIL+1)); else PASS=$((PASS+1)); fi

# ── The hydrate leg must take its collection FROM the register ────────────
# A register nothing reads is a comment. If the embed call site carries its
# own literal, the register can say one thing while the install does another
# and every arm above still passes.
if grep -qE '^\s*_HYDRATE_APPLENOTES_COLLECTION="apple_notes_knowledge"\s*$' "$SUBJECT"; then
    bad "the Apple Notes hydrate leg assigns its collection as a bare literal rather than reading OSTLER_KNOWLEDGE_COLLECTIONS; the register and the writer can then disagree in silence"
else
    ok "the Apple Notes hydrate leg resolves its collection through the register"
fi

# ── bash 3.2, because the cut host has bash 3.2 ──────────────────────────
# MEASURED while writing this: the first draft of that lookup was a
# `$( for ... case ... done )`, `bash -n install.sh` PASSED it because -n does
# not descend into command substitutions, and bash 3.2 then failed at runtime
# with "syntax error near unexpected token 'newline'" and assigned the
# collection the literal text of the loop. Parse it the way the cut host will.
if command -v /bin/bash >/dev/null 2>&1; then
    if /bin/bash -n "$SUBJECT" 2>/dev/null; then
        ok "install.sh parses under $(/bin/bash --version | head -1 | sed 's/.*version //; s/ .*//')"
    else
        bad "install.sh does not parse under the system bash"
    fi
else
    printf '  [note] no /bin/bash; the 3.2 parse arm did not run\n'
fi

printf '\n  %d pass, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
_TOTAL=$((PASS + FAIL))
if [ "$_TOTAL" -lt 3 ]; then
    echo "CANNOT-RUN: only ${_TOTAL} assertions were reached; expected 3 or more" >&2
    exit 2
fi
echo "PASS: every knowledge collection this install writes has a live reader verdict"
exit 0
