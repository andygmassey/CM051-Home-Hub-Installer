#!/usr/bin/env bash
# _vendor_lib.sh -- shared helpers for the vendor-freshness toolchain.
#
# Sourced by verify_vendor_fresh.sh and sync_vendor.sh. Network-light
# (only local git), dependency-free beyond coreutils + git + a minimal
# TOML reader implemented here (the manifest is intentionally a flat,
# table-array TOML so we need no python/toml dependency in CI).
#
# Productisation: source repo locations are NOT hard-coded. Each manifest
# entry names a source_repo PATH, but that path may be overridden per
# operator/CI via an env var derived from the tree name -- see
# resolve_source_repo().
#
# British English throughout; " -- " not em-dashes.

set -euo pipefail

# Resolve the CM051 repo root regardless of CWD.
vlib_repo_root() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    printf '%s\n' "$here"
}

VLIB_REPO_ROOT="$(vlib_repo_root)"
VLIB_MANIFEST="${VENDOR_MANIFEST:-$VLIB_REPO_ROOT/vendor/VENDOR_MANIFEST.toml}"

# Per-operation timeout (seconds) for source-repo reads. A sick/locked source
# repo (corrupt pack, stale rebase state, an LFS filter blocking on the
# network) must degrade to "could not verify" -- never hang the whole gate.
VLIB_OP_TIMEOUT="${VENDOR_OP_TIMEOUT:-60}"

# Portable timeout: prefer coreutils `timeout`/`gtimeout`; otherwise a pure
# bash watchdog (macOS ships no `timeout`). Returns 124 on timeout, else the
# command's own exit status.
vlib_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
        return $?
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
        return $?
    fi
    # Bash fallback watchdog.
    "$@" &
    local cmd_pid=$!
    (
        sleep "$secs"
        kill -0 "$cmd_pid" 2>/dev/null && kill -TERM "$cmd_pid" 2>/dev/null
        sleep 2
        kill -0 "$cmd_pid" 2>/dev/null && kill -KILL "$cmd_pid" 2>/dev/null
    ) &
    local wd_pid=$!
    local rc=0
    wait "$cmd_pid" 2>/dev/null || rc=$?
    kill -TERM "$wd_pid" 2>/dev/null || true
    wait "$wd_pid" 2>/dev/null || true
    # 143 = 128+SIGTERM (our watchdog killed it) -> normalise to 124.
    [ "$rc" = "143" ] && rc=124
    return "$rc"
}

# ---------------------------------------------------------------------------
# Minimal TOML table-array reader.
#
# The manifest is an array of [[tree]] tables, each a flat set of
# key = "value" string assignments (plus optional `exclude = ["a","b"]`
# arrays). We do not support nested tables, multi-line strings, or
# numbers -- by design, to keep the reader tiny and auditable.
#
# vlib_tree_names            -> prints each tree `name` on its own line
# vlib_field <name> <field>  -> prints the scalar field value (empty if unset)
# vlib_excludes <name>       -> prints each exclude glob on its own line
# ---------------------------------------------------------------------------

vlib_tree_names() {
    awk '
        /^[[:space:]]*\[\[tree\]\]/ { intree=1; next }
        intree && /^[[:space:]]*name[[:space:]]*=/ {
            line=$0
            sub(/^[^=]*=[[:space:]]*"/, "", line)
            sub(/".*$/, "", line)
            print line
            intree=0
        }
    ' "$VLIB_MANIFEST"
}

# Print a scalar field for a given tree name.
vlib_field() {
    local want="$1" field="$2"
    awk -v want="$want" -v field="$field" '
        /^[[:space:]]*\[\[tree\]\]/ { intree=1; name=""; delete seen; next }
        intree && /^[[:space:]]*name[[:space:]]*=/ {
            line=$0
            sub(/^[^=]*=[[:space:]]*"/, "", line)
            sub(/".*$/, "", line)
            name=line
        }
        intree && name==want {
            # match  field = "value"   (quoted string)   OR
            #        field = true      (bare scalar: bool / number / bareword)
            if ($0 ~ "^[[:space:]]*"field"[[:space:]]*=") {
                line=$0
                sub(/^[^=]*=[[:space:]]*/, "", line)   # strip up to and incl "field = "
                if (line ~ /^"/) {                      # quoted string value
                    sub(/^"/, "", line)
                    sub(/".*$/, "", line)
                } else {                                # bare scalar (true/false/number)
                    sub(/[[:space:]]*#.*$/, "", line)   # drop trailing comment
                    sub(/[[:space:]]+$/, "", line)      # drop trailing whitespace
                }
                print line
                exit
            }
        }
    ' "$VLIB_MANIFEST"
}

# Print each exclude glob (one per line) for a tree. Supports a single-line
# array: exclude = ["tests/", "scripts/"]
vlib_excludes() {
    local want="$1"
    awk -v want="$want" '
        /^[[:space:]]*\[\[tree\]\]/ { intree=1; name=""; next }
        intree && /^[[:space:]]*name[[:space:]]*=/ {
            line=$0
            sub(/^[^=]*=[[:space:]]*"/, "", line)
            sub(/".*$/, "", line)
            name=line
        }
        intree && name==want && /^[[:space:]]*exclude[[:space:]]*=/ {
            line=$0
            sub(/^[^=]*=[[:space:]]*\[/, "", line)
            sub(/\].*$/, "", line)
            n=split(line, parts, ",")
            for (i=1;i<=n;i++) {
                v=parts[i]
                gsub(/^[[:space:]]*"?/, "", v)
                gsub(/"?[[:space:]]*$/, "", v)
                if (v != "") print v
            }
            exit
        }
    ' "$VLIB_MANIFEST"
}

# ---------------------------------------------------------------------------
# Source-repo resolution (productised override).
#
# A manifest source_repo of "$HR015/ostler_fda" (or a literal path) can be
# overridden. Two override layers, most-specific wins:
#   1. Per-tree:  VENDOR_SRC_<NAME>      (NAME upper-cased, non-alnum -> _)
#   2. Per-base:  VENDOR_SRC_HR015 / VENDOR_SRC_CM041 / ... when the manifest
#      path begins with a "$VARNAME/" placeholder, VARNAME is expanded from
#      the environment if set.
# Returns the resolved absolute repo path, or empty if it cannot be found.
# ---------------------------------------------------------------------------

vlib_env_key() {
    # tree-name -> VENDOR_SRC_<UPPER_SNAKE>
    printf 'VENDOR_SRC_%s\n' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_' | sed 's/_*$//')"
}

resolve_source_repo() {
    local tree="$1"
    local raw
    raw="$(vlib_field "$tree" source_repo)"

    # 1. Per-tree explicit override.
    local key val
    key="$(vlib_env_key "$tree")"
    val="$(eval "printf '%s' \"\${$key:-}\"")"
    if [ -n "$val" ]; then
        printf '%s\n' "$val"
        return 0
    fi

    # 2. Placeholder expansion: a manifest value like "${HR015}/ostler_fda"
    #    or "$HR015/ostler_fda" expands HR015 from the env if present.
    if printf '%s' "$raw" | grep -q '\$'; then
        # Let the shell expand any ${VAR} / $VAR present in the value.
        #
        # `set +u` INSIDE THE COMMAND SUBSTITUTION, and it is load-bearing.
        # Callers run `set -euo pipefail`, so expanding "$CM052" with CM052
        # unset raised "CM052: unbound variable" and killed the whole gate at
        # the FIRST unset placeholder. An unset placeholder is not an error
        # here: it means that source repo is simply not checked out on this
        # host, which must expand to empty, fall through to "source repo not
        # found ()", and be COUNTED as unverifiable so the denominator tells
        # the truth. Hard-erroring loses every tree after the first.
        #
        # The `set +u` is scoped to the subshell that $( ) already creates, so
        # the caller's `set -u` is untouched. Verified: after this call, $-
        # still contains u.
        #
        # Note the sibling override lookup above already does the equivalent
        # via ${VAR:-}; that form cannot be used here because $raw is an
        # arbitrary string like "$HR015/doctor", not a bare variable name.
        local expanded
        expanded="$(set +u; eval "printf '%s' \"$raw\"")"
        printf '%s\n' "$expanded"
        return 0
    fi

    printf '%s\n' "$raw"
}

# ---------------------------------------------------------------------------
# Materialise a source subtree at a given SHA into <dest>, restricted to the
# vendored file-set (i.e. with the tree's exclude globs removed). For a
# non-git source (CM019), fall back to copying the working tree and WARN.
#
# vlib_materialise <tree> <dest_dir>  -> 0 on success; 2 = source missing;
#                                        3 = sha not present in source.
# Emits diagnostics on stderr.
# ---------------------------------------------------------------------------

vlib_materialise() {
    local tree="$1" dest="$2"
    local repo subpath sha
    repo="$(resolve_source_repo "$tree")"
    subpath="$(vlib_field "$tree" source_path)"
    sha="$(vlib_field "$tree" pinned_sha)"

    if [ -z "$repo" ] || [ ! -d "$repo" ]; then
        echo "  could not verify $tree: source repo not found ($repo)" >&2
        return 2
    fi

    mkdir -p "$dest"

    # Non-git source (e.g. CM019 is not a git repo): copy the working tree.
    if [ "$sha" = "WORKING_TREE" ] || ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        echo "  note: $tree source is not pinned to a git SHA (WORKING_TREE) -- comparing against the live source working tree" >&2
        if [ -n "$subpath" ] && [ "$subpath" != "." ]; then
            if [ ! -d "$repo/$subpath" ]; then
                echo "  could not verify $tree: source path $repo/$subpath not found" >&2
                return 2
            fi
            ( cd "$repo/$subpath" && tar -cf - . ) | ( cd "$dest" && tar -xf - )
        else
            ( cd "$repo" && tar -cf - . ) | ( cd "$dest" && tar -xf - )
        fi
    else
        if ! git -C "$repo" cat-file -e "${sha}^{commit}" 2>/dev/null; then
            echo "  could not verify $tree: pinned_sha $sha not present in $repo (run: git -C '$repo' fetch)" >&2
            return 3
        fi
        # archive the subpath at the pinned sha, to a tarball (so the whole
        # read is a single timeout-wrappable command -- a sick source repo
        # must not hang the gate).
        local arch arc=0
        arch="$(mktemp)"
        if [ -n "$subpath" ] && [ "$subpath" != "." ]; then
            vlib_timeout "$VLIB_OP_TIMEOUT" git -C "$repo" archive -o "$arch" "$sha" "$subpath" || arc=$?
        else
            vlib_timeout "$VLIB_OP_TIMEOUT" git -C "$repo" archive -o "$arch" "$sha" || arc=$?
        fi
        if [ "$arc" = "124" ]; then
            echo "  could not verify $tree: 'git archive' on $repo timed out after ${VLIB_OP_TIMEOUT}s (sick source repo? stale rebase/lock/LFS filter). Heal the repo or raise VENDOR_OP_TIMEOUT." >&2
            rm -f "$arch"
            return 2
        elif [ "$arc" != "0" ]; then
            echo "  could not verify $tree: 'git archive' on $repo failed (rc=$arc)" >&2
            rm -f "$arch"
            return 2
        fi
        tar -x -C "$dest" -f "$arch"
        rm -f "$arch"
        # flatten: dest/<subpath>/... -> dest/...
        if [ -n "$subpath" ] && [ "$subpath" != "." ] && [ -d "$dest/$subpath" ]; then
            ( cd "$dest/$subpath" && tar -cf - . ) | ( cd "$dest" && tar -xf - )
            rm -rf "${dest:?}/${subpath%%/*}"
        fi
    fi

    # Strip excluded paths (tests/, scripts/, etc.) so the materialised tree
    # matches the vendored file-set. Two glob shapes are supported:
    #   - a literal path (e.g. "tests/", "CLAUDE.md")  -> rm -rf at any depth
    #   - a wildcard name (e.g. "*.egg-info/")         -> find -name match
    local glob bare
    while IFS= read -r glob; do
        [ -z "$glob" ] && continue
        bare="${glob%/}"
        if printf '%s' "$bare" | grep -q '[*?]'; then
            # Wildcard: match by basename anywhere in the tree, remove matches.
            find "$dest" -depth -name "$bare" -exec rm -rf {} + 2>/dev/null || true
        else
            # Literal: remove the top-level entry, plus any nested occurrence
            # (e.g. a tests/ dir inside a package sub-dir).
            rm -rf "${dest:?}/$bare"
            find "$dest" -depth -name "$bare" -exec rm -rf {} + 2>/dev/null || true
        fi
    done < <(vlib_excludes "$tree")

    return 0
}

# ---------------------------------------------------------------------------
# Shared-file diff.
#
# The vendored tree is deliberately a SUBSET of the source (tests/, dev docs,
# half of src/ are not vendored) AND a SUPERSET in places (vendor-only grafts
# like subscription_gate.py). "Stale" means: a file present in BOTH source and
# vendor has DRIFTED. Source-only and vendor-only files are out of scope.
#
# vlib_vendor_diff <tree> <srcdir> <vendordir> <outfile>
#   writes a unified diff to <outfile> covering BOTH files that differ and
#   files present only in the vendored tree (emitted as new-file hunks, unless
#   an exclude glob says the tree deliberately does not carry them);
#   exit 0 = identical, 1 = drift. The diff is rooted so `git apply` (run from
#   the source tree) reproduces the vendor's version of each shared file.
# ---------------------------------------------------------------------------

vlib_vendor_diff() {
    local tree="$1" src="$2" ven="$3" out="$4"
    : > "$out"
    local drift=0 rel

    # Exclude globs for this tree, read once. A file the tree deliberately does
    # not vendor must NOT get a new-file hunk: that would resurrect excluded
    # content on every materialise and quietly fight the exclude.
    local _ex
    _ex="$(vlib_excludes "$tree" 2>/dev/null || true)"
    # MUST agree with how vlib_materialise strips excludes, because the two
    # are the halves of one decision. The materialiser uses `find -name
    # "<glob>"`, which matches a BASENAME at ANY depth. This predicate has to
    # answer the same question or the pair disagrees.
    #
    # It used to disagree, for exactly one class of glob. The old patterns
    # quoted the glob inside the any-depth alternative:
    #
    #     case "$_p" in $_g|*"/$_g") return 0 ;; esac
    #                       ^^^^^^ quoted, so * and ? are LITERAL here
    #
    # In a `case` pattern a quoted expansion matches literally, so `*"/$_g"`
    # with _g="test_*.py" is the pattern `*/test_*.py` where that inner `*` is
    # an asterisk CHARACTER. No real path ever matches it. The bare `$_g`
    # alternative is unquoted and does glob, but only against the whole
    # relative path, so it only ever matched at the tree root.
    #
    # Net effect, and it is a nasty one because it is silent: a LITERAL exclude
    # (README.md, tests/) worked at any depth, while a WILDCARD exclude
    # (test_*.py, *.egg-info/) worked only at the top level. The materialiser
    # stripped agent/test_*.py from the source tree; this predicate did not
    # recognise them as excluded; so they looked VENDOR-ONLY and were emitted as
    # /dev/null new-file hunks for files that exist perfectly well at the pin.
    # `git apply` then aborts the WHOLE patch with "already exists in working
    # directory" and the tree reconstructs nothing at all.
    #
    # That is the mirror of the bug the new-file support fixed: that one dropped
    # creations, this one manufactured them out of modifications. Both end with
    # a divergence patch that cannot rebuild the tree it describes.
    _vd_excluded() {
        local _p="$1" _g _base
        _base="${_p##*/}"
        while IFS= read -r _g; do
            [ -n "$_g" ] || continue
            case "$_g" in
                */)
                    # Directory glob: at the tree root, or nested at any depth.
                    # Unquoted so a wildcard dir glob (*.egg-info/) still globs.
                    _g="${_g%/}"
                    case "$_p" in $_g/*|*/$_g/*) return 0 ;; esac
                    ;;
                *)
                    # File glob: the whole relative path, or the basename at any
                    # depth. The basename arm is the one that mirrors `find
                    # -name` and the one that was missing.
                    case "$_p" in $_g) return 0 ;; esac
                    case "$_base" in $_g) return 0 ;; esac
                    ;;
            esac
        done <<< "$_ex"
        return 1
    }

    while IFS= read -r rel; do
        rel="${rel#./}"
        [ -f "$ven/$rel" ] || continue
        if [ -f "$src/$rel" ]; then
            # Present in BOTH: ordinary modification hunk.
            if ! diff -q "$src/$rel" "$ven/$rel" >/dev/null 2>&1; then
                drift=1
                # Emit a git-applyable hunk: a/<rel> (source) -> b/<rel> (vendor).
                diff -u --label "a/$rel" --label "b/$rel" "$src/$rel" "$ven/$rel" >> "$out" 2>/dev/null || true
            fi
            continue
        fi

        # VENDOR-ONLY: present here, absent from source@pinned_sha.
        #
        # THIS IS THE CASE THAT USED TO BE SILENTLY DROPPED, and dropping it is
        # what made a grafted new file undeliverable. The old function iterated
        # the same list and simply skipped anything the source lacked, so a
        # hand-authored new-file hunk was stripped by the next --regen-patch and
        # the file had no durable home in the patch at all. That is why the old
        # daemon_cron.py hunks are gone.
        #
        # A file absent BY INSTRUCTION (exclude glob) is a different thing from
        # one absent because the pin predates it, so the excludes are honoured.
        _vd_excluded "$rel" && continue

        drift=1
        # git's new-file shape: /dev/null -> b/<rel>. `git apply` creates it.
        diff -u --label /dev/null --label "b/$rel" /dev/null "$ven/$rel" >> "$out" 2>/dev/null || true
    done < <(cd "$ven" && find . -type f -not -path '*/__pycache__/*' | sort)

    unset -f _vd_excluded
    return "$drift"
}

# vlib_patch_new_files <tree>
#   Print each path the tree's declared divergence patch CREATES (its new-file
#   hunks), one per line. Empty when there is no patch.
#
#   Used by sync_vendor.sh to tell a vendor-only file that already has a
#   durable home in the patch from one that would be lost by the swap.
vlib_patch_new_files() {
    local tree="$1" patch abs
    patch="$(vlib_field "$tree" divergence_patch)"
    [ -z "$patch" ] && return 0
    abs="$VLIB_REPO_ROOT/$patch"
    [ -f "$abs" ] || return 0
    # A new-file hunk is `--- /dev/null` immediately followed by `+++ b/<path>`.
    # Matching the +++ line alone would name every file in the patch.
    awk '
        /^--- \/dev\/null$/ { pending = 1; next }
        /^\+\+\+ b\// {
            if (pending) { sub(/^\+\+\+ b\//, ""); print }
            pending = 0; next
        }
        { pending = 0 }
    ' "$abs"
}

# Apply a divergence patch (source -> vendor transform) inside <dest>.
# Returns 0 on success or if no patch declared; 4 if the patch fails to apply.
vlib_apply_patch() {
    local tree="$1" dest="$2"
    local patch
    patch="$(vlib_field "$tree" divergence_patch)"
    [ -z "$patch" ] && return 0
    local abs="$VLIB_REPO_ROOT/$patch"
    if [ ! -f "$abs" ]; then
        echo "  WARN: $tree declares divergence_patch $patch but it does not exist" >&2
        return 0
    fi
    if ! ( cd "$dest" && git apply --whitespace=nowarn "$abs" 2>/dev/null ); then
        echo "  FAIL: $tree divergence patch did not apply onto source@pinned_sha -- the source has likely moved under the patch (re-graft needed: scripts/sync_vendor.sh $tree)" >&2
        return 4
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Manifest mutators (used by sync_vendor.sh). These edit the [[tree]] table
# whose name matches, in place. They operate on the scalar string fields
# only; they preserve everything else byte-for-byte.
# ---------------------------------------------------------------------------

# Set (or, if absent, insert) a scalar field within the named tree's table.
set_manifest_field() {
    local want="$1" field="$2" value="$3"
    local tmp
    tmp="$(mktemp)"
    awk -v want="$want" -v field="$field" -v value="$value" '
        function flush_insert() {
            if (intree && name==want && !done && field_seen==0) {
                # not reached normally; field inserted at table end below
            }
        }
        /^[[:space:]]*\[\[tree\]\]/ {
            # leaving a table: if we were in the target table and never saw
            # the field, insert it before the new table header.
            if (intree && name==want && !replaced) {
                print "  " field " = \"" value "\""
                replaced=1
            }
            intree=1; name=""; print; next
        }
        {
            if (intree && $0 ~ /^[[:space:]]*name[[:space:]]*=/) {
                line=$0
                sub(/^[^=]*=[[:space:]]*"/, "", line)
                sub(/".*$/, "", line)
                name=line
            }
            if (intree && name==want && $0 ~ "^[[:space:]]*"field"[[:space:]]*=" && !replaced) {
                print "  " field " = \"" value "\""
                replaced=1
                next
            }
            print
        }
        END {
            if (intree && name==want && !replaced) {
                print "  " field " = \"" value "\""
            }
        }
    ' "$VLIB_MANIFEST" > "$tmp"
    mv "$tmp" "$VLIB_MANIFEST"
}

ensure_manifest_patch_ref() {
    set_manifest_field "$1" divergence_patch "$2"
}

clear_manifest_patch_ref() {
    # Set the field to empty string (keeps the schema uniform).
    set_manifest_field "$1" divergence_patch ""
}
