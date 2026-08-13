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

- The verifier surfaces only the **last stdout line**, so a probe's last line
  must always be a one-line verdict. Anything else and a failure reads as an
  arbitrary log line in the cut report.
- Probes run under `/bin/bash`, which is **3.2** on macOS. Two 3.2 traps have
  already been paid for here: a command **prefix assignment** is not visible to
  expansions in its own command, and `local a=.. b=${a}..` expands every word
  before any assignment takes effect. Under `set -u` both kill the probe
  mid-run with no verdict line.

## Adding a probe

1. Land the probe body first, matching this contract.
2. **Land a test that proves it fires.** A probe is a gate, and a gate with no
   demonstrated RED is indistinguishable from `exit 0`. Drive it against a
   controllable fake and assert non-zero on each way the thing under test can
   be wrong. See `scripts/tests/test_people_seed_and_retrieval_probe.sh`.
3. Add the entry to `cut-manifests/permanent.yaml`, not to a single
   `v<version>.yaml`. A per-cut manifest protects exactly one cut: the people
   probe was registered in `v1.0.12.yaml` alone and was therefore absent from
   every manifest from v1.0.13 to v1.0.26.
4. Bring the probe live in the Studio matrix runbook (which sets
   `OSTLER_BOX_HOST` on the operator's shell).

## Registered probes

- `people_seed_and_retrieval` - seeds two synthetic people and retrieves them
  by the routes the assistant really uses. Leg A is the primary path
  (`POST /api/v1/memory/assert` then `GET /api/v1/people/context`, Oxigraph),
  leg B is the fallback (`GET /api/v1/people/search`, Qdrant + Ollama, seeded
  directly because `memory/assert` does not write Qdrant). Runs its HTTP calls
  **on the box**, because the Assistant API binds loopback and rejects
  non-loopback `Host` headers by design. Treats `"degraded": true` (which
  arrives as HTTP 200) as inconclusive and never as absence, and masks every
  retrieved name that is not one of its own synthetic fixtures before printing.
  Registered in `cut-manifests/permanent.yaml`.
