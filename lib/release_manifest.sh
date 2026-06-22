#!/usr/bin/env bash
# CM051 -- Ostler release manifest emitter (WORKSTREAM C / C1).
#
# Writes ~/.ostler/ostler-release.json: the single runtime-queryable
# record of "what version is actually deployed". The lack of this is
# what bit the .152 walk -- nobody could tell from the box which
# daemon / wiki-image / installer build was live.
#
# Two emit paths, one schema:
#
#   1. CUT (release.sh) writes a BUILD STAMP -- ostler-release.build.json
#      -- into the staged install/ tree. It carries the values only the
#      cut knows: ostler_version (the --version tag), the git SHAs of the
#      source repos at cut time, the installer_version. The DMG ships it.
#
#   2. install.sh, at the end of a successful install, calls
#      emit_release_manifest. That function reads the build stamp (when
#      present), augments it with the values install.sh itself pins
#      (daemon version, wiki image SHAs scraped from the generated
#      docker-compose.yml, the channel), and writes the final runtime
#      manifest to ~/.ostler/ostler-release.json.
#
# When no build stamp is present (dev run / curl|bash bootstrap / a
# hand-run install.sh), emit_release_manifest still produces a valid
# manifest from the values install.sh knows -- ostler_version falls back
# to "dev" and the source-repo SHAs are omitted. A manifest is ALWAYS
# emitted so the Doctor version surface always has something real to read.
#
# Schema is versioned (manifest_schema_version). Readers MUST be
# backwards-tolerant: read old and new shapes, never hard-fail on an
# unknown or missing field. See
# docs/RELEASE_MANIFEST.md + launch/BACKWARDS_TOLERANT_READERS.md.
#
# No user-facing strings live here -- this file emits machine-readable
# JSON only. Operator-facing copy lives in install.sh's catalogue and in
# the Doctor surface (HR015 web_ui_copy.py). i18n-exempt by construction.

# The schema version. BUMP this only when the SHAPE changes in a way a
# reader must know about. Adding an OPTIONAL field does not need a bump
# (backwards-tolerant readers tolerate it). Removing/renaming a field, or
# changing a field's meaning, DOES need a bump + a reader migration.
OSTLER_MANIFEST_SCHEMA_VERSION="1"

# Build-stamp filename emitted by release.sh into the staged tree and
# read back here at install time. Lives next to install.sh in the DMG.
OSTLER_BUILD_STAMP_NAME="ostler-release.build.json"

# Runtime manifest filename written under ~/.ostler.
OSTLER_RELEASE_MANIFEST_NAME="ostler-release.json"

# _json_escape <string> -- minimal JSON string escaper for the handful
# of values we embed. Escapes backslash, double-quote and control chars
# we are likely to see (newline, tab, CR). The inputs are version
# strings, SHAs and short channel names -- not arbitrary user text -- so
# this stays deliberately small rather than shelling out to python/jq
# (which may not be on PATH this early on a fresh box).
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# _scrape_image_sha <compose_file> <image_repo_substr>
# Pulls the @sha256:... digest for a given image out of the generated
# docker-compose.yml. Echoes the bare sha256:... digest, or empty string
# if not found. Tolerates the line being absent (older / different
# compose layouts) -- the manifest field just comes out null.
_scrape_image_sha() {
    local compose_file="$1" needle="$2"
    [[ -f "$compose_file" ]] || { printf ''; return 0; }
    # Match e.g.  image: ghcr.io/ostler-ai/ostler-wiki-site@sha256:abc...
    grep -m1 -E "image:[[:space:]]*[^[:space:]]*${needle}[^[:space:]]*@sha256:[0-9a-f]+" "$compose_file" 2>/dev/null \
        | grep -oE 'sha256:[0-9a-f]+' \
        | head -n1
}

# emit_release_manifest -- the public entry point. Writes the runtime
# manifest to ${OSTLER_DIR}/ostler-release.json (atomic: temp + mv).
#
# Reads (all best-effort; every one has a fallback):
#   OSTLER_DIR                       -- target ~/.ostler (required)
#   SCRIPT_DIR                       -- where the build stamp lives
#   OSTLER_ASSISTANT_VERSION         -- daemon version pin
#   ${OSTLER_DIR}/docker-compose.yml -- wiki image SHAs
#
# Never aborts the install: any failure is a warn, not a fail. A missing
# manifest degrades the Doctor surface to "unknown", which is strictly
# better than a blank that looks legitimate.
emit_release_manifest() {
    local ostler_dir="${OSTLER_DIR:-${HOME}/.ostler}"
    local script_dir="${SCRIPT_DIR:-}"
    local stamp=""
    local out="${ostler_dir}/${OSTLER_RELEASE_MANIFEST_NAME}"

    if [[ -z "$ostler_dir" ]]; then
        return 0
    fi
    mkdir -p "$ostler_dir" 2>/dev/null || return 0

    # ---- values from the build stamp (cut-time facts) ----------------
    local ostler_version="dev"
    local installer_version="dev"
    local built_at=""
    local daemon_tag=""
    local source_shas_json=""   # raw JSON object body (may be empty)

    if [[ -n "$script_dir" && -f "${script_dir}/${OSTLER_BUILD_STAMP_NAME}" ]]; then
        stamp="${script_dir}/${OSTLER_BUILD_STAMP_NAME}"
    elif [[ -f "${ostler_dir}/${OSTLER_BUILD_STAMP_NAME}" ]]; then
        # post-install re-run: the stamp may have been promoted into ~/.ostler
        stamp="${ostler_dir}/${OSTLER_BUILD_STAMP_NAME}"
    fi

    if [[ -n "$stamp" ]]; then
        # The build stamp is small, well-formed JSON written by us. Pull
        # the scalar fields with a tolerant grep rather than requiring jq
        # on a fresh box. Each match is optional.
        local v
        v="$(grep -oE '"ostler_version"[[:space:]]*:[[:space:]]*"[^"]*"' "$stamp" 2>/dev/null | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | head -n1)"
        [[ -n "$v" ]] && ostler_version="$v"
        v="$(grep -oE '"installer_version"[[:space:]]*:[[:space:]]*"[^"]*"' "$stamp" 2>/dev/null | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | head -n1)"
        [[ -n "$v" ]] && installer_version="$v"
        v="$(grep -oE '"built_at"[[:space:]]*:[[:space:]]*"[^"]*"' "$stamp" 2>/dev/null | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | head -n1)"
        [[ -n "$v" ]] && built_at="$v"
        v="$(grep -oE '"daemon_tag"[[:space:]]*:[[:space:]]*"[^"]*"' "$stamp" 2>/dev/null | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | head -n1)"
        [[ -n "$v" ]] && daemon_tag="$v"
        # source_repos: rebuild the object from its "repo": "sha" pairs
        # rather than copying the block verbatim (verbatim is brittle --
        # a single-line vs multi-line stamp object collapses the brace
        # range). Pull every  "key": "value"  pair that sits inside the
        # source_repos block. The stamp is small + machine-written by us,
        # so a flat pair-scan is reliable; anything unexpected just yields
        # an empty object.
        local repos_block
        repos_block="$(awk '/"source_repos"[[:space:]]*:/{f=1} f{print} f&&/}/{exit}' "$stamp" 2>/dev/null)"
        # Drop the source_repos key line itself, then collect inner pairs.
        source_shas_json="$(printf '%s\n' "$repos_block" \
            | grep -oE '"[A-Za-z0-9_.-]+"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | grep -vE '^"source_repos"' \
            | paste -sd ',' - 2>/dev/null)"
    fi

    # ---- values install.sh itself knows (runtime facts) --------------
    local daemon_version="${OSTLER_ASSISTANT_VERSION:-unknown}"
    [[ -z "$daemon_tag" ]] && daemon_tag="hub-v${daemon_version}"

    local compose_file="${ostler_dir}/docker-compose.yml"
    local wiki_site_sha wiki_compiler_sha
    wiki_site_sha="$(_scrape_image_sha "$compose_file" "ostler-wiki-site")"
    wiki_compiler_sha="$(_scrape_image_sha "$compose_file" "ostler-wiki-compiler")"

    local emitted_at
    emitted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')"

    local channel="${OSTLER_RELEASE_CHANNEL:-stable}"

    # ---- compose the JSON --------------------------------------------
    # Hand-rolled rather than jq-dependent: this runs on a freshly-wiped
    # Mac where jq is not guaranteed. Null where a value is genuinely
    # unknown -- the reader distinguishes "absent" from "empty".
    local tmp
    tmp="$(mktemp "${ostler_dir}/.ostler-release.XXXXXX.json" 2>/dev/null)" || tmp="${out}.tmp.$$"

    {
        printf '{\n'
        printf '  "manifest_schema_version": "%s",\n' "$(_json_escape "$OSTLER_MANIFEST_SCHEMA_VERSION")"
        printf '  "ostler_version": "%s",\n' "$(_json_escape "$ostler_version")"
        printf '  "installer_version": "%s",\n' "$(_json_escape "$installer_version")"
        printf '  "channel": "%s",\n' "$(_json_escape "$channel")"
        printf '  "daemon": {\n'
        printf '    "version": "%s",\n' "$(_json_escape "$daemon_version")"
        printf '    "tag": "%s"\n' "$(_json_escape "$daemon_tag")"
        printf '  },\n'
        printf '  "wiki": {\n'
        if [[ -n "$wiki_site_sha" ]]; then
            printf '    "site_image_sha": "%s",\n' "$(_json_escape "$wiki_site_sha")"
        else
            printf '    "site_image_sha": null,\n'
        fi
        if [[ -n "$wiki_compiler_sha" ]]; then
            printf '    "compiler_image_sha": "%s"\n' "$(_json_escape "$wiki_compiler_sha")"
        else
            printf '    "compiler_image_sha": null\n'
        fi
        printf '  },\n'
        if [[ -n "$source_shas_json" ]]; then
            # source_shas_json is a comma-joined list of  "repo": "sha"
            # pairs rebuilt from the stamp -- wrap it in a fresh object.
            printf '  "source_repos": {%s},\n' "$source_shas_json"
        else
            printf '  "source_repos": {},\n'
        fi
        if [[ -n "$built_at" ]]; then
            printf '  "built_at": "%s",\n' "$(_json_escape "$built_at")"
        else
            printf '  "built_at": null,\n'
        fi
        printf '  "installed_at": "%s"\n' "$(_json_escape "$emitted_at")"
        printf '}\n'
    } > "$tmp" 2>/dev/null

    if [[ -s "$tmp" ]]; then
        chmod 0644 "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$out" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
    else
        rm -f "$tmp" 2>/dev/null
        return 0
    fi

    return 0
}
