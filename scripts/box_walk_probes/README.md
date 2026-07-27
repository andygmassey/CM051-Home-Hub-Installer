# box-walk probe registry

Each `.sh` file in this directory is a named runtime probe invoked by the
`box_walk_probe` primitive in `scripts/verify_cut_manifest.py`. A cut-manifest
entry names one via `proof.probe: <name>`; the verifier looks up the matching
`<name>.sh`, invokes it, and PASSes on exit 0.

## Contract

- Each probe is a self-contained bash script (`/bin/bash`).
- Exit `0` on success. Any non-zero exit is FAIL; the verifier captures the
  last stdout / stderr line in its Result detail.
- Timeout: 180 seconds (see `BOX_WALK_PROBE_TIMEOUT_SECONDS` in the verifier).
- Probes may read `OSTLER_BOX_HOST` and any related env vars for target
  addressing. The verifier itself SKIPs when `OSTLER_BOX_HOST` is not set, so
  probes never run in CI or offline dev.

## Naming

`<name>.sh` where `<name>` matches the value of `proof.probe` in the cut
manifest entry. Names are lowercase, underscore-separated, and short: they
identify the runtime shape being probed, not the fix.

## Adding a probe

1. Land the probe body first, matching this contract.
2. Add a cut-manifest entry under `cut-manifests/v<version>.yaml` with
   `kind: box_walk_probe` and `probe: <name>`.
3. Bring the probe live in the Studio matrix runbook (which sets
   `OSTLER_BOX_HOST` on the operator's shell).

## Registered probes (v1.0.12)

- `people_seed_and_retrieval` - stub only in this PR. Full probe body ships with
  the Studio matrix runbook. See the stub script for the intended behaviour.
