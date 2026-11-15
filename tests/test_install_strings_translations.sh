#!/bin/bash
# test_install_strings_translations.sh
#
# The translated installer catalogues must be drop-in replacements for the
# en-GB ones, because install.sh sources whichever OSTLER_LANG names and
# printf's the values with positional arguments:
#
#   1. every install.sh.strings.<lang>.sh parses under /bin/bash (3.2 on macOS)
#      and defines no MSG_* key en-GB lacks (fewer is fine: English fills them)
#   2. every value carries the same printf placeholders, in the same order
#      (a dropped %s shifts every later argument; an extra one prints garbage)
#   3. no em dash (U+2014) anywhere
#   4. install.sh's own loader, run for real, selects the translated file for
#      OSTLER_LANG=<lang> and falls back to en-GB for an unknown value
#   5. ViewCopy.<lang>.json / HintCopy.<lang>.json have the base file's exact
#      shape (same keys, same non-string values, same {placeholder} slots);
#      HintCopy must still decode as [String: StepMeta] with id == key
#   6. the .app build phase (gui/project.yml) and the tarball (release.sh)
#      both ship every translated catalogue
#
# Self-test: TEST_INSTALL_STRINGS_MUTATE=1 drops a %s from one German value in
# a scratch copy and the test must go red.
set -u
cd "$(dirname "$0")/.." || exit 2
LANGS="en-US de fr es it nl pt-BR pt-PT ja ko zh-Hans zh-Hant zh-HK ar"
fail=0
bad() { printf 'FAIL: %s\n' "$*"; fail=1; }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
for f in install.sh.strings.*.sh; do cp "$f" "$scratch/"; done
if [ "${TEST_INSTALL_STRINGS_MUTATE:-0}" = "1" ]; then
    /usr/bin/python3 -I - "$scratch/install.sh.strings.de.sh" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
m=re.search(r'^(MSG_[A-Z0-9_]+="[^"\n]*?)%s', s, re.M)
s=s[:m.end()-2]+s[m.end():]
open(p,'w').write(s)
PY
fi

dump() {  # NUL-separated name, value pairs, from a clean bash
    env -i /bin/bash -c 'source "$1" || exit 3; for v in $(compgen -v MSG_); do printf "%s\0%s\0" "$v" "${!v}"; done' _ "$1"
}

dump "$scratch/install.sh.strings.en-GB.sh" > "$scratch/en.bin" || bad "en-GB catalogue does not source"
checked=0
for l in $LANGS; do
    f="$scratch/install.sh.strings.$l.sh"
    if [ ! -f "$f" ]; then bad "missing install.sh.strings.$l.sh"; continue; fi
    /bin/bash -n "$f" || { bad "$l: bash -n syntax error"; continue; }
    dump "$f" > "$scratch/$l.bin" || { bad "$l: does not source"; continue; }
    out="$(/usr/bin/python3 -I - "$scratch/en.bin" "$scratch/$l.bin" "$l" <<'PY'
import sys,re
def load(p):
    b=open(p,encoding='utf-8').read().split('\0')[:-1]
    return dict(zip(b[::2],b[1::2]))
en,tr,lang=load(sys.argv[1]),load(sys.argv[2]),sys.argv[3]
SPEC=re.compile(r'%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?[a-zA-Z%]')
errs=[]
# A key the translation lacks is fine (install.sh loads en-GB first, so it
# prints English; the weekly l10n run fills it). A key English does NOT have
# is a stale or misspelt key and fails.
if set(tr)-set(en):
    errs.append(f"keys not in en-GB: {sorted(set(tr)-set(en))[:5]}")
for k in en:
    if k in tr:
        if SPEC.findall(en[k])!=SPEC.findall(tr[k]):
            errs.append(f"{k}: placeholders {SPEC.findall(en[k])} -> {SPEC.findall(tr[k])}")
        if '—' in tr[k]:
            errs.append(f"{k}: em dash")
same=sum(1 for k in en if tr.get(k)==en[k])
print(f"{lang}: {len(tr)} keys, {len(en)-same} differ from English")
for e in errs[:20]: print("ERR "+e)
PY
)"
    printf '%s\n' "$out" | sed -n 1p
    if printf '%s\n' "$out" | /usr/bin/grep -q '^ERR '; then
        printf '%s\n' "$out" | /usr/bin/grep '^ERR ' | sed "s/^ERR /FAIL: $l: /"
        fail=1
    fi
    checked=$((checked + 1))
done
[ "$checked" -eq 14 ] || bad "checked $checked of 14 shell catalogues"

# 4. install.sh's own loader, extracted verbatim and run.
loader="$scratch/loader.sh"
awk '/^OSTLER_LANG="\$\{OSTLER_LANG:-en-GB\}"/{on=1} on{print} /^unset _STRINGS_FILE/{exit}' install.sh > "$loader"
[ -s "$loader" ] || bad "could not extract the strings loader from install.sh"
probe() {  # $1 = OSTLER_LANG value -> prints MSG_STEP_CHECKING_PREREQUISITES
    env -i OSTLER_LANG="$1" SCRIPT_DIR="$scratch" /bin/bash -c 'source "$1"; printf "%s" "$MSG_STEP_CHECKING_PREREQUISITES"' _ "$loader"
}
# Expected value per file, read straight from that file (not "differs from
# English": a key whose English changed falls back to English legitimately).
want() { env -i /bin/bash -c 'source "$1"; printf "%s" "$MSG_STEP_CHECKING_PREREQUISITES"' _ "$scratch/install.sh.strings.$1.sh"; }
# A marker only the selected file carries proves WHICH file the loader sourced.
for l in en-GB $LANGS; do printf '\nMSG_L10N_PROBE_MARK="%s"\n' "$l" >> "$scratch/install.sh.strings.$l.sh"; done
mark() { env -i OSTLER_LANG="$1" SCRIPT_DIR="$scratch" /bin/bash -c 'source "$1"; printf "%s" "$MSG_L10N_PROBE_MARK"' _ "$loader"; }
[ "$(mark en-GB)" = "en-GB" ] || bad "loader control: en-GB sourced '$(mark en-GB)'"
for l in $LANGS; do
    [ "$(mark "$l")" = "$l" ] || bad "loader: OSTLER_LANG=$l sourced '$(mark "$l")'"
    [ "$(probe "$l")" = "$(want "$l")" ] || bad "loader: OSTLER_LANG=$l value differs from its file"
done
[ "$(mark xx)" = "en-GB" ] || bad "loader: unknown OSTLER_LANG did not fall back to en-GB"
# A key the translation lacks (added to en-GB after the last run) prints
# English, not an empty string: drop one key from the German scratch copy.
/usr/bin/sed -i.bak '/^MSG_STEP_CHECKING_PREREQUISITES=/d' "$scratch/install.sh.strings.de.sh" && rm -f "$scratch/install.sh.strings.de.sh.bak"
[ "$(probe de)" = "$(want en-GB)" ] || bad "loader: a key missing from de printed '$(probe de)', not the English"

# 5. GUI JSON catalogues.
/usr/bin/python3 -I - $LANGS <<'PY' || fail=1
import json,re,sys
R='gui/OstlerInstaller/Resources/'
PH=re.compile(r'\{[a-zA-Z_][a-zA-Z0-9_]*\}')
bad=0
def cmp(a,b,path,lang,stem):
    global bad
    if type(a)!=type(b):
        print(f"FAIL: {stem}.{lang}.json {path}: type {type(a).__name__} -> {type(b).__name__}"); bad=1; return
    if isinstance(a,dict):
        if set(b)-set(a):  # fewer is fine (English overlay fills them); extra is stale
            print(f"FAIL: {stem}.{lang}.json {path}: keys not in English {sorted(set(b)-set(a))[:5]}"); bad=1
        for k in a:
            if k in b: cmp(a[k],b[k],path+'/'+k,lang,stem)
    elif isinstance(a,list):
        if len(a)!=len(b): print(f"FAIL: {stem}.{lang}.json {path}: list length"); bad=1
        for i,(x,y) in enumerate(zip(a,b)): cmp(x,y,f"{path}[{i}]",lang,stem)
    elif isinstance(a,str):
        if sorted(PH.findall(a))!=sorted(PH.findall(b)):
            print(f"FAIL: {stem}.{lang}.json {path}: placeholders {PH.findall(a)} -> {PH.findall(b)}"); bad=1
        if '—' in b: print(f"FAIL: {stem}.{lang}.json {path}: em dash"); bad=1
    elif a!=b:
        print(f"FAIL: {stem}.{lang}.json {path}: non-string value changed {a!r} -> {b!r}"); bad=1
for lang in sys.argv[1:]:
    for stem in ('ViewCopy','HintCopy'):
        base=json.load(open(R+stem+'.json'))
        try: tr=json.load(open(R+f'{stem}.{lang}.json'))
        except Exception as e: print(f"FAIL: {stem}.{lang}.json: {e}"); bad=1; continue
        cmp(base,tr,'',lang,stem)
        if stem=='HintCopy':
            for k,v in tr.items():
                if not (isinstance(v,dict) and v.get('id')==k and isinstance(v.get('title'),str)):
                    print(f"FAIL: HintCopy.{lang}.json {k}: would not decode as StepMeta"); bad=1
print(f"json: {2*len(sys.argv[1:])} catalogues compared")
sys.exit(bad)
PY

# 6. shipped by both delivery paths.
for l in $LANGS; do
    /usr/bin/grep -qF "\$(SRCROOT)/../install.sh.strings.$l.sh" gui/project.yml || bad "project.yml inputFiles lack $l"
    /usr/bin/grep -qF "cp \"\${SRCROOT}/../install.sh.strings.$l.sh\"" gui/project.yml || bad "project.yml build phase does not copy $l"
    /usr/bin/grep -q "\"install.sh.strings.$l.sh\"" release.sh || bad "release.sh tarball does not include $l"
    /usr/bin/grep -qF "install.sh.strings.$l.sh" gui/OstlerInstaller.xcodeproj/project.pbxproj || bad "pbxproj not regenerated for $l"
done

if [ "$fail" -ne 0 ]; then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS (14 shell catalogues, 28 JSON catalogues, loader, bundling)"
