#!/usr/bin/env bash
# THE SENTINEL VOCABULARY MUST BE DECLARED, AND THE DECLARATION MUST BE TRUE.
#
# WHY THIS EXISTS. The same drift was found TWICE, in two fields, both times by
# a human reading BOTH SIDES of a cross-repo contract:
#
#     sources    CM051 writes 13    CM044 recognised  9
#     statuses   CM051 writes  5    CM044 recognised  3
#
# `cannot_run` and `timeout` fell through to "Could not tell" on the customer's
# freshness panel. `timeout` is the expensive one: rc 124/137 means a source was
# killed by its cap and moved no data, so it needs a re-run, and "Could not
# tell" invites no action.
#
# ⚠️ THE WRITER COULD NOT BE ENUMERATED, WHICH IS THE ACTUAL DEFECT. A literal
# `grep 'status='` over install.sh returns ok / no_data / cannot_run and MISSES
# error and timeout, because _hydrate_sentinel_record_error builds its status at
# runtime from an rc. So the writer had no vocabulary, only BEHAVIOUR, and the
# only way for a reader to stay in sync was for somebody to re-derive that
# behaviour by hand. That is what failed, twice.
#
# SO THIS TEST DOES NOT GREP. It EXECUTES every recorder, with the rc values
# that select the runtime branch, and reads the status each one actually WROTE
# into its sentinel file. A declaration that merely exists is worth nothing --
# a list that can drift from its own writer is WORSE than none, because it looks
# authoritative. This asserts the declaration and the behaviour agree.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SUBJECT="${REPO}/install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$SUBJECT" ] || { echo "CANNOT-RUN: no install.sh at ${SUBJECT}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

DECLARED="$(grep -m1 '^OSTLER_SENTINEL_STATUSES=' "$SUBJECT" | sed 's/^[^=]*=//; s/^"//; s/"$//')"
[ -n "$DECLARED" ] || { echo "CANNOT-RUN: OSTLER_SENTINEL_STATUSES is not declared in install.sh." >&2
                        echo "  This test exists to prove the declaration matches the writer;" >&2
                        echo "  with no declaration there is nothing to compare and a PASS" >&2
                        echo "  would assert something unmeasured." >&2; exit 2; }
echo "  declared statuses: ${DECLARED}"

# Extract the four recorders verbatim, plus stubs for what they call.
python3 - "$SUBJECT" "${WORK}/recorders.sh" <<'PY'
import sys
src, out = sys.argv[1], sys.argv[2]
lines = open(src, encoding='utf-8').read().split('\n')
names = ['_hydrate_sentinel_record', '_hydrate_sentinel_record_no_data',
         '_hydrate_sentinel_record_error', '_hydrate_sentinel_record_cannot_run']
body = []
for n in names:
    s = next(i for i, l in enumerate(lines) if l.startswith(n + '()'))
    e = next(i for i in range(s + 1, len(lines)) if lines[i] == '}')
    body.append('\n'.join(lines[s:e + 1]))
open(out, 'w', encoding='utf-8').write('\n\n'.join(body) + '\n')
PY
[ -s "${WORK}/recorders.sh" ] || { echo "CANNOT-RUN: could not extract the recorders." >&2; exit 2; }

# Echoes the status the recorder actually WROTE, or nothing.
_emit() {
    local call="$1" src_name="$2" d="${WORK}/sent"; rm -rf "$d"; mkdir -p "$d"
    {
        printf '%s\n' 'set -uo pipefail'
        printf '_HYDRATE_SENTINEL_DIR=%q\n' "$d"
        printf '%s\n' '_HY_ITEM_COUNT=0'
        printf '%s\n' '_HY_LAST_UPDATE_AT=-'
        printf '%s\n' 'gui_step_record_rc() { :; }'
        printf '%s\n' '_hydrate_compute_change() { _HY_ITEM_COUNT="${2:-0}"; _HY_LAST_UPDATE_AT="${3:--}"; }'
        printf '%s\n' '_hydrate_payload_count() { printf 0; }'
        printf '%s\n' '_hydrate_payload_is_all_zero() { return 1; }'
        cat "${WORK}/recorders.sh"
        printf '%s\n' "$call"
    } > "${WORK}/run.sh"
    bash "${WORK}/run.sh" >/dev/null 2>&1
    sed -n 's/^status=//p' "${d}/${src_name}.done" 2>/dev/null | head -1
}

echo "── every recorder EXECUTED, and what it actually wrote ──"

declare_ok() {   # name, observed, expected
    if [ "$2" = "$3" ]; then ok "$1 wrote status=$2"
    else bad "$1 wrote status='${2:-<nothing>}', expected '$3'"; fi
}

OBSERVED=""
for spec in \
  "_hydrate_sentinel_record|_hydrate_sentinel_record contacts 'people=1'|contacts|ok" \
  "_hydrate_sentinel_record_no_data|_hydrate_sentinel_record_no_data calendar no_calendar_accounts|calendar|no_data" \
  "_hydrate_sentinel_record_cannot_run|_hydrate_sentinel_record_cannot_run email venv_missing|email|cannot_run" \
  "_hydrate_sentinel_record_error rc=1|_hydrate_sentinel_record_error imessage 1 'x=1'|imessage|error" \
  "_hydrate_sentinel_record_error rc=124|_hydrate_sentinel_record_error whatsapp 124 'x=1'|whatsapp|timeout" \
  "_hydrate_sentinel_record_error rc=137|_hydrate_sentinel_record_error people 137 'x=1'|people|timeout" ; do
    IFS='|' read -r label call sname want <<< "$spec"
    got="$(_emit "$call" "$sname")"
    OBSERVED="${OBSERVED} ${got}"
    declare_ok "$label" "$got" "$want"
done

echo "── the declaration must COVER everything observed ──"
missing=""
for st in $OBSERVED; do
    case " ${DECLARED} " in *" ${st} "*) : ;; *) missing="${missing} ${st}" ;; esac
done
if [ -z "$missing" ]; then
    ok "every status the recorders actually emit is in OSTLER_SENTINEL_STATUSES"
else
    bad "emitted but NOT declared:${missing}. The declaration is a lie about its own writer."
fi

echo "── and it must not declare words nothing emits ──"
# Not fatal on its own -- a status may be emitted by a path this test does not
# drive -- so it REPORTS rather than fails, and names them.
unseen=""
for st in $DECLARED; do
    case " ${OBSERVED} " in *" ${st} "*) : ;; *) unseen="${unseen} ${st}" ;; esac
done
[ -z "$unseen" ] && ok "every declared status was observed from a real recorder" \
                 || ok "declared but not exercised here:${unseen} (reported, not failed -- another path may emit them)"

echo "── THE SOURCES HALF, which was declared and unchecked ──"
# 🔴 TNM's review finding, and it turned this PR's own argument on itself.
# OSTLER_SENTINEL_SOURCES was declared and NOTHING compared it to anything --
# which is precisely the failure mode this file exists to end: a hand-typed
# list that no gate checks is a writer with "no vocabulary, only behaviour",
# wearing a badge. Add a 14th source and the list stays at 13, the reader stays
# at 13, and the panel loses a row.
#
# Static extraction is sound HERE and it was checked, not assumed:
#     51 recorder call sites · 51 with a QUOTED literal source · 0 with a
#     variable · 13 distinct names
# and the control below proves the extractor would SEE a variable form if one
# were ever added, so this cannot go quietly blind.
DECLARED_SRC="$(grep -m1 '^OSTLER_SENTINEL_SOURCES=' "$SUBJECT" | sed 's/^[^=]*=//; s/^"//; s/"$//')"
if [ -z "$DECLARED_SRC" ]; then
    echo "CANNOT-RUN: OSTLER_SENTINEL_SOURCES is not declared in install.sh." >&2; exit 2
fi

CALLSITES="$(sed 's/[[:space:]]*#.*$//' "$SUBJECT"     | grep -oE '_hydrate_sentinel_record(_no_data|_error|_cannot_run)?[[:space:]]+[^[:space:]]+')"
# QUOTES ARE OPTIONAL, and assuming they were not cost a real miss. The first
# version extracted with a pattern requiring quotes, so an UNQUOTED literal was
# readable but NEVER EXTRACTED: Direction 1 then compared a SUBSET and the
# suite reported agreement while a 14th source sat in the file. Readable and
# extracted are different properties and both are needed.
SITE_SRCS="$(printf '%s\n' "$CALLSITES" \
    | sed -E 's/.*_hydrate_sentinel_record(_no_data|_error|_cannot_run)?[[:space:]]+//' \
    | sed -E 's/^"([a-z_]+)"$/\1/' \
    | grep -E '^[a-z_]+$' | sort -u)"
N_SITES="$(printf '%s
' "$CALLSITES" | grep -c . || true)"
N_SRCS="$(printf '%s
' "$SITE_SRCS" | grep -c . || true)"
echo "  ${N_SITES} recorder call site(s), ${N_SRCS} distinct source name(s)"

# ── DIRECTION 0: NO CALL SITE MAY BE UNREADABLE ─────────────────────────
#
# 🔴 TNM mutation-tested the two directions below and one slipped through:
#
#     _hydrate_sentinel_record "brand_new_source" "x=1"   -> FAIL, named it
#     _hydrate_sentinel_record  brand_new_source  "x=1"   -> PASS  🔴
#
# and MY OWN DIAGNOSTIC LINE was the evidence: sites went 51 -> 52 while
# sources stayed 13. The extractor SAW the call site, could not read its source
# token, DROPPED it, and reported agreement over the subset that remained.
# That is a silent under-count, and agreement over a subset means nothing.
#
# THE FIX IS NOT A WIDER REGEX. Chasing spellings loses -- unquoted, ${VAR},
# single quotes, a line continuation -- and each miss looks like a pass. The
# invariant is that every call site is READABLE, which covers every spelling at
# once and turns the two numbers printed above into an assertion rather than a
# diagnostic nobody reads.
UNPARSED="$(printf '%s\n' "$CALLSITES" \
    | sed -E 's/.*_hydrate_sentinel_record(_no_data|_error|_cannot_run)?[[:space:]]+//' \
    | grep -cvE '^"?[a-z_]+"?$' || true)"
[ "${UNPARSED:-0}" -eq 0 ] \
    && ok "every one of the ${N_SITES} call sites is readable, so the comparison below is over the WHOLE population" \
    || bad "${UNPARSED} call site(s) UNREADABLE. The comparison below is over a SUBSET and its agreement means nothing."

# DIRECTION 1: a source used at a call site but never declared is a new source
# nobody told the reader about.
undeclared=""
for sname in $SITE_SRCS; do
    case " ${DECLARED_SRC} " in *" ${sname} "*) : ;; *) undeclared="${undeclared} ${sname}" ;; esac
done
[ -z "$undeclared" ]     && ok "every source written at a call site is declared"     || bad "written but NOT declared:${undeclared}. A reader pinned to the declaration will carry no row for it."

# DIRECTION 2: a declared source with no call site is rot -- it makes the
# reader carry a row that can never fill.
orphaned=""
for sname in $DECLARED_SRC; do
    case " $(printf '%s ' $SITE_SRCS) " in *" ${sname} "*) : ;; *) orphaned="${orphaned} ${sname}" ;; esac
done
[ -z "$orphaned" ]     && ok "every declared source is actually written by a call site"     || bad "declared but NEVER written:${orphaned}. The reader would carry a row that can never fill."

# CONTROL: the extractor must SEE a variable-form call site. If a future edit
# passes "$SRC" instead of a literal, static extraction silently under-counts,
# and a zero from a blind extractor would read as agreement.
_varform="$(printf '_hydrate_sentinel_record "$SRC" x
'     | grep -oE '_hydrate_sentinel_record(_no_data|_error|_cannot_run)?[[:space:]]+[^[:space:]]+'     | grep -c '\$' || true)"
[ "${_varform:-0}" -ge 1 ]     && ok "CONTROL: a variable-form call site IS visible to the extractor, so it cannot go blind unnoticed"     || bad "CONTROL BROKEN: the extractor cannot see a variable-form call site, so both arms above may be reading a truncated population."

echo "── CONTROL: an undeclared status MUST be caught ──"
# Prove the coverage arm can fail. If this passes, the arm above is decoration.
FAKE="definitely_not_a_declared_status"
case " ${DECLARED} " in
    *" ${FAKE} "*) bad "CONTROL BROKEN: the fake status is somehow declared" ;;
    *) ok "CONTROL: a status outside the declaration is detectably absent, so the coverage arm can fail" ;;
esac

echo "── DIRECTION 3: A DENOMINATOR THAT CAN CONTAIN THE SUBJECT (#1587) ──"
# 🔴 THE FINDING THIS ARM EXISTS FOR, and it is about THIS FILE.
#
# Both directions above enumerate HYDRATE RECORDER CALL SITES on one side and
# the declaration on the other. Photos and Reminders had NEITHER, so neither
# direction could reach them: this gate was wired, ran on main, passed, and was
# structurally incapable of noticing that two shipped extractors could never
# appear on the surface built to report what ran. A gate whose denominator
# excludes its subject proves only that the set it CAN see agrees with itself.
#
# So this arm's denominator is the EXTRACTOR'S OWN source vocabulary, read from
# vendor/ostler_fda/extract_all.py, which is the list of things a customer can
# turn on. Every one of them must say where its result surfaces, and "nowhere"
# is allowed only with a reason somebody wrote down.
EXTRACTOR="${REPO}/vendor/ostler_fda/extract_all.py"
if [ ! -r "$EXTRACTOR" ]; then
    echo "CANNOT-RUN: no extractor at ${EXTRACTOR}; Direction 3 would compare against nothing." >&2
    exit 2
fi
EXTRACTOR_SRCS="$(grep -oE 'summary\["sources"\]\["[a-z_]+"\]' "$EXTRACTOR" \
    | sed -E 's/.*\["([a-z_]+)"\]$/\1/' | sort -u)"
N_EXTRACTOR="$(printf '%s\n' "$EXTRACTOR_SRCS" | grep -c . || true)"
echo "  ${N_EXTRACTOR} source(s) the extractor can report on, read from $(basename "$EXTRACTOR")"

# CONTROL ON THE DENOMINATOR ITSELF. If this list could not contain photos and
# reminders, the arm below would pass over a set that excludes its own subject,
# which is the precise defect being repaired. A floor alone is not enough: a
# pattern that matched twelve other names and missed these two would clear it.
_d3_missing_subject=""
for want in photos reminders; do
    printf '%s\n' "$EXTRACTOR_SRCS" | grep -qx "$want" || _d3_missing_subject="${_d3_missing_subject} ${want}"
done
if [ -n "$_d3_missing_subject" ]; then
    echo "CANNOT-RUN: the extractor-source scan did not find:${_d3_missing_subject}." >&2
    echo "  This arm exists because those two were outside every denominator." >&2
    echo "  A denominator that cannot contain them measures nothing here." >&2
    exit 2
fi
if [ "${N_EXTRACTOR:-0}" -lt 8 ]; then
    echo "CANNOT-RUN: only ${N_EXTRACTOR} extractor source(s) found; suspect the pattern." >&2
    exit 2
fi
ok "CONTROL: the denominator CONTAINS photos and reminders (${N_EXTRACTOR} sources examined), so this arm can see the case that defeated the two above"

SURFACING="$(sed -n '/^OSTLER_FDA_SOURCE_SURFACING="/,/"$/p' "$SUBJECT" \
    | sed -e 's/^OSTLER_FDA_SOURCE_SURFACING="//' -e 's/\\$//' -e 's/"$//' \
    | tr ' ' '\n' | grep -E '^[a-z_]+:' | sort -u)"
N_SURFACING="$(printf '%s\n' "$SURFACING" | grep -c . || true)"
echo "  ${N_SURFACING} surfacing declaration(s) read from OSTLER_FDA_SOURCE_SURFACING"
# 🔴 A MISSING REGISTER IS A FAIL, NOT A CANNOT-RUN, and the difference was
# measured. Reverting install.sh to its pre-fix state makes this parse to 0,
# and an exit 2 there would report "could not look" about the exact state this
# arm exists to catch. install.sh being unreadable is a cannot-run and is
# handled at the top of the file; a readable install.sh carrying no register is
# a measurement, and the answer is that every extractor source is unmapped.
if [ "${N_SURFACING:-0}" -eq 0 ]; then
    bad "OSTLER_FDA_SOURCE_SURFACING is absent or empty. Nothing says where any extractor source surfaces, so no source can be shown to reach the customer."
fi

unmapped=""
bad_target=""
no_reason=""
for esrc in $EXTRACTOR_SRCS; do
    entry="$(printf '%s\n' "$SURFACING" | grep -m1 "^${esrc}:" || true)"
    if [ -z "$entry" ]; then
        unmapped="${unmapped} ${esrc}"
        continue
    fi
    target="$(printf '%s' "$entry" | cut -d: -f2)"
    reason="$(printf '%s' "$entry" | cut -d: -f3)"
    if [ "$target" = "none" ]; then
        [ -n "$reason" ] || no_reason="${no_reason} ${esrc}"
        continue
    fi
    case " ${DECLARED_SRC} " in
        *" ${target} "*) : ;;
        *) bad_target="${bad_target} ${esrc}->${target}" ;;
    esac
    case " $(printf '%s ' $SITE_SRCS) " in
        *" ${target} "*) : ;;
        *) bad_target="${bad_target} ${esrc}->${target}(no_call_site)" ;;
    esac
done

[ -z "$unmapped" ] \
    && ok "every one of the ${N_EXTRACTOR} extractor sources says where it surfaces" \
    || bad "extractor source(s) with NO surfacing declaration:${unmapped}. A customer can turn these on and has no way to learn whether they ran."
[ -z "$bad_target" ] \
    && ok "every surfacing target is a declared source with a real recorder call site" \
    || bad "surfacing declaration(s) naming a target that is not a written, declared source:${bad_target}"
[ -z "$no_reason" ] \
    && ok "every deliberately unsurfaced source carries a written reason" \
    || bad "source(s) declared 'none' with no reason:${no_reason}. An omission is not a decision."

# CONTROL: the lookup must be able to MISS. Without this, an arm that matched
# everything loosely would pass whatever the register said.
if printf '%s\n' "$SURFACING" | grep -q "^zzq_not_a_real_extractor_source:"; then
    bad "CONTROL BROKEN: a fabricated extractor name is somehow declared"
else
    ok "CONTROL: a fabricated extractor name is detectably unmapped, so the arms above can fail"
fi

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
