#!/usr/bin/env bash
# ============================================================================
# THE LICENCE POSITIVE CONTROL WAS SELF-REFERENTIAL. THIS PINS IT TO THE SIGNER.
#
# Four implementations canonicalise a licence body before Ed25519 touches it:
#
#   SIGNER    CM050 appcast-server/src/license.ts  canonicaliseLicenseBody
#             (hand-rolled TS, Cloudflare Worker -- signs every real licence)
#   signer    CM050 license-generator/.../canonical.py  (json.dumps, admin CLI)
#   verifier  CM051 install.sh:1271                canonical_body  (json.dumps)
#   verifier  CM051 LicenseVerifier.swift:203      canonicalJSON   (hand-rolled)
#
# Each carries a comment asserting byte-identity with the others. Until this
# fixture, NOTHING pinned any pair.
#
# tests/test_licence_gate.sh:193 defines its OWN minting canonicaliser with the
# same json.dumps rule the gate verifies with, so its Case 4 "valid licence
# (positive control)" passes BY CONSTRUCTION -- and would keep passing if the
# signer drifted. It proves the gate is self-consistent, not that it agrees
# with CM050.
#
# THIS TEST IS THE OTHER HALF. The expected bytes in the fixture were produced
# by RUNNING the signer, not by re-deriving the rule here. A value the test
# must FIND, not a value it generated.
#
# WHY THAT MATTERS CONCRETELY: generating the fixture found a real divergence.
# Measured over all 32 codepoints 0x00-0x1F, by running all three reachable
# implementations, the signer disagrees with both verifiers on 5 of them
# (0x08 0x09 0x0a 0x0c 0x0d): the signer emits \u00XX for every control char,
# json.dumps and the Swift verifier emit JSON's short forms. Different bytes ->
# different Ed25519 payload -> rc=13 "signature did not verify", which reads to
# a customer as a bad licence rather than as our bug. Control 5 below is a
# RATCHET on those five: it fails if the divergence widens AND if it silently
# disappears, so whoever fixes CM050 is forced to regenerate this fixture.
#
# Exit: 0 all examined and agreed | 1 a real disagreement | 2 CANNOT-RUN
# ============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
SWIFT_SRC="${REPO_ROOT}/gui/OstlerInstaller/Auth/LicenseVerifier.swift"
FIXTURE="${REPO_ROOT}/tests/fixtures/licence_canonical_golden_vectors.json"

# TRI-STATE, set by the caller, because "swiftc is missing" means three
# different things depending on WHERE you are and only the caller knows which:
#
#   require  the macOS job. Chosen BECAUSE it has swiftc, so an absent swiftc
#            is a FAILURE -- otherwise the arm reports green having compiled
#            nothing, which is the exact vacuous-green this file exists to kill.
#   skip     the ubuntu job. swiftc was never going to be here; the Swift arm
#            is PROVEN on the macOS job, so its absence is expected and is not
#            counted. Declared at the call site, not inferred from the runner.
#   auto     a developer laptop (default). Absent swiftc is CANNOT-RUN: honest,
#            and never mistaken for a pass.
#
# Each CI job states its own expectation. A job that inspected the test's
# internals to decide what its exit code meant would be a gate reading a
# rendering instead of a decision.
SWIFT_MODE="${OSTLER_GOLDEN_SWIFT:-auto}"

pass=0; fail=0; cannot=0
ok()     { printf '  [ok]     %s\n' "$*"; pass=$(( pass + 1 )); }
bad()    { printf '  [FAIL]   %s\n' "$*"; fail=$(( fail + 1 )); }
cannot() { printf '  [CANNOT] %s\n' "$*"; cannot=$(( cannot + 1 )); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "== licence canonical JSON: the verifiers must reproduce the SIGNER's bytes =="
echo ""

command -v python3 >/dev/null 2>&1 || {
    echo "  [CANNOT] python3 absent -- this gate cannot run" >&2; exit 2; }

# --- extract the REAL verifier from the REAL install.sh -----------------------
# Same two markers tests/test_licence_gate.sh:277 uses: the heredoc opener, and
# the documented "=== entrypoint ===" split that lets the definitions be loaded
# without invoking main(). Reading install.sh itself is the point -- a copy of
# canonical_body in this test would reproduce the self-reference it exists to
# remove.
sed -n "/^[[:space:]]*_lic_detail=.*<<'OSTLER_LICENCE_VERIFY_PY'\$/,/^OSTLER_LICENCE_VERIFY_PY\$/p" \
    "${INSTALL_SH}" \
  | sed '1d;$d' \
  | sed -n '1,/^# === entrypoint ===/p' > "${WORK}/verifier_defs.py"

# --- 0. ANTI-VACUITY: everything below is attributable ------------------------
# An empty extraction, a renamed function or a truncated fixture must all read
# as CANNOT-RUN. A gate that examined nothing must never print a pass.
#
# Name the RIGHT cause. An earlier version reported "markers moved?" for a run
# where install.sh was simply not at the path -- REPO_ROOT had collapsed to /
# because dirname was missing from a stripped PATH. The extraction was fine;
# the file was absent. A diagnostic that names the wrong object sends the next
# reader to the wrong file, so check existence separately and say which it is.
if [ ! -f "${INSTALL_SH}" ]; then
    cannot "0. install.sh not found at ${INSTALL_SH} -- nothing was extracted or examined"
    echo ""; echo "== ${pass} passed, ${fail} failed, ${cannot} cannot-run =="; exit 2
fi
defs_lines=$(wc -l < "${WORK}/verifier_defs.py" | tr -d ' ')
if [ "${defs_lines}" -lt 100 ]; then
    cannot "0. install.sh IS present but yielded only ${defs_lines} lines (expected >=100) -- the heredoc or '=== entrypoint ===' marker moved"
    echo ""; echo "== ${pass} passed, ${fail} failed, ${cannot} cannot-run =="; exit 2
fi
if [ ! -f "${FIXTURE}" ]; then
    cannot "0. fixture missing: ${FIXTURE}"
    echo ""; echo "== ${pass} passed, ${fail} failed, ${cannot} cannot-run =="; exit 2
fi
ok "0. extracted ${defs_lines} lines of the REAL install.sh verifier; fixture present"

# --- 1-2, 4-5, 6: the python arm ---------------------------------------------
python3 - "${WORK}/verifier_defs.py" "${FIXTURE}" > "${WORK}/py.out" 2>&1 <<'PYEOF'
import json, sys

defs_path, fixture_path = sys.argv[1], sys.argv[2]

ns = {}
try:
    exec(compile(open(defs_path).read(), defs_path, "exec"), ns)
except Exception as exc:                       # noqa: BLE001
    print("CANNOT|1|could not load install.sh verifier definitions: %s" % exc)
    raise SystemExit(0)

canonical_body = ns.get("canonical_body")
if not callable(canonical_body):
    print("CANNOT|1|install.sh no longer defines canonical_body -- extraction is stale")
    raise SystemExit(0)

doc = json.load(open(fixture_path))
vectors = doc["vectors"]
prov = doc.get("provenance", {})

FLOOR = 14
if len(vectors) < FLOOR:
    print("CANNOT|1|fixture carries %d vectors, floor is %d" % (len(vectors), FLOOR))
    raise SystemExit(0)

agree_expected = [v for v in vectors if not v.get("known_divergent")]
divergent      = [v for v in vectors if v.get("known_divergent")]

# --- 1. every non-divergent vector: our verifier == the signer, byte for byte
mismatched = []
for v in agree_expected:
    got = canonical_body(v["body"])
    if got is None or got.hex() != v["signer_canonical_hex"]:
        mismatched.append((v["name"],
                           "None" if got is None else got.hex(),
                           v["signer_canonical_hex"]))
if mismatched:
    print("FAIL|1|%d of %d agreed vectors DISAGREE with the signer" % (len(mismatched), len(agree_expected)))
    for name, got, want in mismatched:
        print("INFO|0|  %s" % name)
        print("INFO|0|    ours  : %s" % got)
        print("INFO|0|    signer: %s" % want)
else:
    print("OK|1|1. install.sh canonical_body reproduces the SIGNER's bytes on all %d agreed vectors" % len(agree_expected))

# --- 2. sorting is real, not an accident of insertion order
a = next((v for v in vectors if v["name"] == "realistic-full-body"), None)
b = next((v for v in vectors if v["name"] == "insertion-order-reversed"), None)
if a and b and canonical_body(a["body"]) == canonical_body(b["body"]) \
         and a["signer_canonical_hex"] == b["signer_canonical_hex"]:
    print("OK|1|2. reversed insertion order yields identical bytes -- key sorting is exercised")
else:
    print("FAIL|1|2. insertion order changes the bytes -- sorting is broken or the vectors drifted")

# --- 4. DEMONSTRATED RED: the comparison must be capable of failing
# Not "the right answer passes" -- a deliberately wrong canonicaliser must be
# CAUGHT. ensure_ascii=True is the classic near-miss: identical for pure-ASCII
# bodies, different the moment a non-ASCII byte appears. If this control ever
# passes silently, control 1 proves nothing.
def wrong_canonicaliser(body):
    return json.dumps(body, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=True).encode("utf-8")

caught = [v["name"] for v in agree_expected
          if wrong_canonicaliser(v["body"]).hex() != v["signer_canonical_hex"]]
if caught:
    print("OK|1|4. DEMONSTRATED RED: a wrong canonicaliser (ensure_ascii=True) is caught on %s" % ", ".join(caught))
else:
    print("FAIL|1|4. a KNOWN-WRONG canonicaliser passed every vector -- this test has no teeth")

# --- 5. RATCHET on the measured divergence, in BOTH directions
# Fails if a divergence disappears (CM050 fixed -> regenerate the fixture) and
# if a new one appears. Recording a defect without a trigger to revisit it is
# how a known bug becomes a permanent one.
still, healed = [], []
for v in divergent:
    got = canonical_body(v["body"])
    (still if (got is not None and got.hex() != v["signer_canonical_hex"]) else healed).append(v["name"])
if healed:
    print("FAIL|1|5. %d known divergence(s) NO LONGER diverge: %s" % (len(healed), ", ".join(healed)))
    print("INFO|0|    CM050 was probably fixed. Regenerate the fixture (tests/fixtures/REGENERATE.md)")
    print("INFO|0|    and drop the known_divergent flag -- do not leave a stale record standing.")
elif len(still) == len(divergent) and divergent:
    print("OK|1|5. RATCHET: all %d recorded divergences still hold, none added" % len(still))
else:
    print("FAIL|1|5. divergence set changed unexpectedly")

# --- 6. provenance is present -- an unattributable fixture is a magic constant
need = ("signer_commit", "signer_file", "signer_file_sha256", "signer_function")
missing = [k for k in need if not prov.get(k)]
if missing:
    print("FAIL|1|6. fixture provenance incomplete, missing: %s" % ", ".join(missing))
else:
    print("OK|1|6. provenance names the signer commit %s and %s" % (prov["signer_commit"][:12], prov["signer_file"]))

print("INFO|0|EXAMINED: %d vectors (%d agreed, %d known-divergent)" % (len(vectors), len(agree_expected), len(divergent)))
PYEOF

while IFS='|' read -r verdict counts message; do
    case "${verdict}" in
        OK)     [ "${counts}" = "1" ] && ok "${message}" ;;
        FAIL)   [ "${counts}" = "1" ] && bad "${message}" ;;
        CANNOT) [ "${counts}" = "1" ] && cannot "${message}" ;;
        INFO)   printf '           %s\n' "${message}" ;;
        *)      printf '           %s\n' "${verdict}${counts:+|${counts}}${message:+|${message}}" ;;
    esac
done < "${WORK}/py.out"

# --- 3. the Swift verifier, COMPILED AND RUN, over the same vectors ----------
# Reading jsonEncodeString and reasoning about it is how the false "byte-
# identical" comment survived in three files. Compile it and ask it.
echo ""
if ! command -v swiftc >/dev/null 2>&1; then
    case "${SWIFT_MODE}" in
        require) bad "3. swiftc absent on a runner chosen BECAUSE it has swiftc -- the Swift arm examined nothing" ;;
        skip)    printf '  [skip]   3. Swift arm not attempted here by declaration (OSTLER_GOLDEN_SWIFT=skip); it is PROVEN on the macOS job\n' ;;
        *)       cannot "3. swiftc unavailable here -- Swift arm NOT RUN (the macOS job is where this is proven)" ;;
    esac
else
    cat > "${WORK}/main.swift" <<'SWEOF'
import Foundation
let fixture = CommandLine.arguments[1]
let raw = try! Data(contentsOf: URL(fileURLWithPath: fixture))
let doc = try! JSONSerialization.jsonObject(with: raw) as! [String: Any]
let vectors = doc["vectors"] as! [[String: Any]]
var out: [[String: Any]] = []
for v in vectors {
    let body = v["body"] as! [String: Any]
    let hex = LicenseVerifier.canonicalJSON(body)?
        .map { String(format: "%02x", $0) }.joined()
    out.append(["name": v["name"] as! String, "hex": hex ?? NSNull()])
}
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: out))
SWEOF
    if ! swiftc -O "${SWIFT_SRC}" "${WORK}/main.swift" -o "${WORK}/swift_probe" 2>"${WORK}/swiftc.err"; then
        bad "3. LicenseVerifier.swift did not compile -- see below"
        sed -n '1,15p' "${WORK}/swiftc.err"
    elif ! "${WORK}/swift_probe" "${FIXTURE}" > "${WORK}/swift.json" 2>/dev/null; then
        bad "3. the Swift probe crashed"
    else
        python3 - "${FIXTURE}" "${WORK}/swift.json" > "${WORK}/swift.verdict" 2>&1 <<'PYEOF'
import json, sys
doc = json.load(open(sys.argv[1]))
got = {r["name"]: r["hex"] for r in json.load(open(sys.argv[2]))}
agreed    = [v for v in doc["vectors"] if not v.get("known_divergent")]
divergent = [v for v in doc["vectors"] if v.get("known_divergent")]

missing = [v["name"] for v in doc["vectors"] if v["name"] not in got]
wrong   = [v["name"] for v in agreed if got.get(v["name"]) != v["signer_canonical_hex"]]
# The Swift verifier must diverge from the signer on exactly the recorded set --
# same ratchet as control 5, applied to the other implementation.
healed  = [v["name"] for v in divergent if got.get(v["name"]) == v["signer_canonical_hex"]]

if missing:
    print("CANNOT|the Swift probe returned no bytes for %d vector(s): %s"
          % (len(missing), ", ".join(missing)))
elif wrong:
    print("FAIL|LicenseVerifier.canonicalJSON disagrees with the signer on %d of %d agreed vectors: %s"
          % (len(wrong), len(agreed), ", ".join(wrong)))
elif healed:
    print("FAIL|Swift no longer diverges on %s -- CM050 was fixed; regenerate the fixture"
          % ", ".join(healed))
else:
    print("OK|3. LicenseVerifier.swift COMPILED AND RUN: reproduces the signer's bytes on all %d agreed vectors (and still diverges on the %d recorded)"
          % (len(agreed), len(divergent)))
PYEOF
        # Two plain assignments, not ${$(...)%%|*}: that form is zsh-only and
        # /bin/bash 3.2 -- the cut host's shell -- rejects it outright.
        sv_line="$(head -1 "${WORK}/swift.verdict")"
        sv_verdict="${sv_line%%|*}"
        sv_message="${sv_line#*|}"
        case "${sv_verdict}" in
            OK)     ok     "${sv_message}" ;;
            FAIL)   bad    "${sv_message}" ;;
            *)      cannot "3. ${sv_message}" ;;
        esac
    fi
fi
echo ""
echo "== ${pass} passed, ${fail} failed, ${cannot} cannot-run =="
if [ "${fail}" -gt 0 ]; then exit 1; fi
if [ "${cannot}" -gt 0 ]; then exit 2; fi
exit 0
