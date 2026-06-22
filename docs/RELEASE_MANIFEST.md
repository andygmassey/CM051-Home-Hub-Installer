# Ostler release manifest

`~/.ostler/ostler-release.json` is the single runtime-queryable record of
**what version is actually deployed** on this machine. Its absence is what
cost a whole night on the .152 walk: the daemon, the wiki images and the
installer all had their own (often drifting) version notions and nothing
on the box could answer "which build is this?".

This document is the schema contract. Keep it in lockstep with:

- `lib/release_manifest.sh` -- the emitter (`emit_release_manifest`)
- `release.sh` -- emits the build stamp for the curl|bash tarball path
- `gui/project.yml` -- emits the build stamp for the DMG / .app path
- HR015 `doctor/agent/release_manifest.py` -- the Doctor-side reader
- The WS-B CI pipeline -- which will emit the same stamp from a clean room

## Two files, one schema

| File | Written by | When | Carries |
|---|---|---|---|
| `ostler-release.build.json` | `release.sh` / `gui/project.yml` | at cut | cut-time facts: `ostler_version`, `installer_version`, `daemon_tag`, `source_repos`, `built_at` |
| `ostler-release.json` | `install.sh` (`emit_release_manifest`) | at install | the above PLUS runtime facts: scraped wiki image SHAs, daemon version, `installed_at` |

The build stamp ships inside the DMG / tarball next to `install.sh`.
`install.sh` reads it at install time, augments it with the values only
the running install knows, and writes the final runtime manifest into
`~/.ostler/`. When no build stamp is present (a dev run or a hand-run
`install.sh`), a valid manifest is still emitted with `ostler_version`
defaulting to `"dev"` and `source_repos` omitted -- so the Doctor surface
always has something real to read.

## Runtime manifest schema (v1)

```json
{
  "manifest_schema_version": "1",
  "ostler_version": "v1.0.1",
  "installer_version": "v1.0.1",
  "channel": "stable",
  "daemon": {
    "version": "0.4.12",
    "tag": "hub-v0.4.12"
  },
  "wiki": {
    "site_image_sha": "sha256:b7cf8ba6...",
    "compiler_image_sha": "sha256:cb8498e0..."
  },
  "source_repos": {
    "cm051": "abcdef123456",
    "hr015": "0123456789ab",
    "cm021": "fedcba654321"
  },
  "built_at": "2026-06-16T09:00:00Z",
  "installed_at": "2026-06-16T11:42:13Z"
}
```

### Fields

| Field | Type | Meaning | Absent / unknown |
|---|---|---|---|
| `manifest_schema_version` | string | Schema version of THIS file. Bump only on a breaking shape change. | required |
| `ostler_version` | string | The product release tag (`vX.Y.Z`). `"dev"` for an unstamped build. | `"dev"` |
| `installer_version` | string | Installer / DMG version. Usually equal to `ostler_version`. | `"dev"` |
| `channel` | string | Release channel (`stable`, `beta`, ...). | `"stable"` |
| `daemon.version` | string | `OSTLER_ASSISTANT_VERSION` install.sh pinned. | `"unknown"` |
| `daemon.tag` | string | Daemon release tag (`hub-vX.Y.Z`). | derived from version |
| `wiki.site_image_sha` | string \| null | `@sha256:` digest of `ostler-wiki-site` scraped from the generated `docker-compose.yml`. | `null` |
| `wiki.compiler_image_sha` | string \| null | Same for `ostler-wiki-compiler`. | `null` |
| `source_repos` | object | Map of source repo -> short git SHA at cut time. | `{}` |
| `built_at` | string \| null | UTC ISO-8601 of the cut. | `null` |
| `installed_at` | string | UTC ISO-8601 of this install / re-run. | set every emit |

`null` means "genuinely unknown" (e.g. the docker-compose line was absent).
An ABSENT field means "this build predates the field". Readers MUST treat
both gracefully -- see `HR015/artefacts/2026-06-16/BACKWARDS_TOLERANT_READERS.md`.

## Why this matters for updates

Single-machine Ostler updates are **pull-based** (Homebrew / Sparkle
style, not SaaS). The manifest is the anchor of that model:

- **Phase 1 (now):** re-run `install.sh` to update. Each emit overwrites
  the manifest atomically, so the deployed-version record is always
  current.
- **Phase 2 (post-launch):** Hub "Check for updates" fetches the latest
  published manifest, diffs it against `~/.ostler/ostler-release.json`,
  and swaps only the components whose pins changed -- never touching the
  user's data under `~/.ostler/`. See
  `HR015/artefacts/2026-06-16/CUSTOMER_UPDATE_PHASE2_DESIGN.md`.

The structural guarantee that makes this safe: durable DATA (the markdown
vault + Oxigraph + Qdrant) is cleanly separated from replaceable CODE. An
update is a code swap; the manifest records what code is in place. No
update may require rebuilding or migrating the user's graph to function.
