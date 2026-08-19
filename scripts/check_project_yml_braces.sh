#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# check_project_yml_braces.sh -- refuse a gui/project.yml that lets XcodeGen
# capture a variable at GENERATION time which was meant for the shell at BUILD
# time.
#
# THE HAZARD
# ----------
# XcodeGen expands a plain ${VAR} while it generates the .xcodeproj. Anything
# it can resolve then gets FROZEN into the tracked pbxproj. Proven with a probe
# variable on 2026-08-08: substituted 1, left literal 0.
#
# Two ways a variable becomes resolvable at generation time, and they need
# different defences:
#
#   (a) ENVIRONMENT-SOURCED -- the var is exported into xcodegen's environment.
#       gui/Makefile does `export OSTLER_APP_PATH`, so under make it exists
#       (empty) and got substituted; in a bare shell it did not exist and
#       survived. Same spec, two different pbxproj files.
#
#   (b) PROCESS-IDENTITY -- XcodeGen resolves it from the process itself, NOT
#       from the environment. ${USER} is the known case: `env -i` still yielded
#       `ostler-installer-build-andy`. Environment scrubbing CANNOT close this
#       class, which is why the primary defence is the source-text form, not
#       the invocation.
#
# WHAT WENT WRONG WHEN THIS WASN'T CHECKED
# ----------------------------------------
#   * the pbxproj carried the operator's username -- a hard `exit 1` build
#     failure for every other builder (their tarball lands in their own
#     /tmp/ostler-installer-build-$USER; the frozen path points at someone
#     else's) plus operator PII in git history
#   * generation stopped being reproducible: the committed project encoded
#     whichever shell last ran `make regen`
#
# THE RULE
# --------
# Inside a shellScript block, write ${VAR:-} not ${VAR} for anything the SHELL
# should expand at build time. XcodeGen passes the `:-` form through literally.
# Xcode's own build settings (SRCROOT, TARGET_BUILD_DIR, ...) are allowlisted:
# they are never present at generation time and Xcode needs the bare form.
#
# EXIT CODES
#   0  no plain ${VAR} that could be captured
#   1  at least one could be captured  -- fix before committing a regen
#   2  could not run (no project.yml). NOT a pass.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SPEC="${1:-$REPO_ROOT/gui/project.yml}"
MAKEFILE="$REPO_ROOT/gui/Makefile"

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

[[ -f "$SPEC" ]] || { red "UNAVAILABLE: spec not found: $SPEC"; red "  A gate that cannot run is NOT a pass."; exit 2; }

# Xcode build settings: resolved by xcodebuild at BUILD time, never present in
# a generation-time environment, and Xcode requires the bare ${...} form.
XCODE_SETTINGS='SRCROOT|TARGET_BUILD_DIR|UNLOCALIZED_RESOURCES_FOLDER_PATH|BUILD_DIR|DERIVED_FILE_DIR|WRAPPER_NAME|ARCHS|CONFIGURATION|PROJECT_DIR|EXECUTABLE_NAME|CONTENTS_FOLDER_PATH|FULL_PRODUCT_NAME'

# Process-identity vars: XcodeGen resolves these regardless of the environment.
# Always a defect in bare form -- env scrubbing does not save you.
IDENTITY_VARS='USER|LOGNAME|HOME'

python3 - "$SPEC" "$MAKEFILE" "$XCODE_SETTINGS" "$IDENTITY_VARS" <<'PY'
import re, sys, os

spec_path, makefile_path, xcode_re, identity_re = sys.argv[1:5]
spec = open(spec_path).read().splitlines()

xcode = set(xcode_re.split('|'))
identity = set(identity_re.split('|'))

# Vars the Makefile exports into xcodegen's environment.
exported = set()
if os.path.exists(makefile_path):
    for line in open(makefile_path):
        m = re.match(r'\s*export\s+([A-Za-z_][A-Za-z0-9_]*)', line)
        if m:
            exported.add(m.group(1))

# A shell var assigned inside the script itself is fine -- it never reaches
# xcodegen's environment. Collect NAME= assignments appearing in the spec.
assigned = set(re.findall(r'^\s*([A-Za-z_][A-Za-z0-9_]*)=', "\n".join(spec), re.M))
assigned |= set(re.findall(r'\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b', "\n".join(spec)))

findings = []
advisory = []
for i, line in enumerate(spec, 1):
    # plain ${VAR}, i.e. NOT ${VAR:-...}
    for m in re.finditer(r'(?<!\$)\$\{([A-Za-z_][A-Za-z0-9_]*)\}', line):
        var = m.group(1)
        if var in xcode:
            continue
        if var in identity:
            findings.append((i, var, "process-identity: XcodeGen resolves it even with a scrubbed environment"))
        elif var in exported:
            findings.append((i, var, f"exported by gui/Makefile, so it exists at generation time"))
        elif var in os.environ:
            findings.append((i, var, "present in the ambient environment right now"))
        elif var not in assigned:
            # ADVISORY ONLY, never a failure. A var that is not exported, not in
            # the environment and not process-identity CANNOT be captured today.
            # Flagging it would fire ~30 times on ${SCRIPT_DIR}/${OSTLER_DIR},
            # and a linter that opens with a wall of false positives is a linter
            # people switch off -- which is how a gate stops gating.
            advisory.append((i, var))

if not findings:
    print("PASS  no capturable plain ${VAR} in " + os.path.basename(spec_path))
    if advisory:
        names = sorted({v for _, v in advisory})
        print(f"      ({len(advisory)} advisory bare refs, not capturable today: {', '.join(names)})")
        print("      They become defects only if something starts exporting them.")
    sys.exit(0)

print("FAIL: gui/project.yml has ${VAR} references XcodeGen can freeze into the pbxproj.", file=sys.stderr)
print("", file=sys.stderr)
for ln, var, why in findings:
    print(f"  line {ln}: ${{{var}}}  -- {why}", file=sys.stderr)
    print(f"      write  ${{{var}:-}}  so the SHELL expands it at build time", file=sys.stderr)
print("", file=sys.stderr)
print("  Why this matters: a captured value is frozen into the tracked project.", file=sys.stderr)
print("  ${USER} froze one operator's username in and made the build fail for", file=sys.stderr)
print("  everyone else. DO NOT COMMIT A REGEN UNTIL THIS IS CLEAN.", file=sys.stderr)
sys.exit(1)
PY
