# requirements.txt files: every line is an == pin (S4, v1.0.124)

Hand edit, recorded here because the per-tree patches are generated and the
upstream checkouts were not touched in this change.

## What changed

Eight vendored requirements files plus `contact_syncer/requirements.txt`
(not vendored) were rewritten from `>=` ranges to `==` pins, direct and
transitive (a full `pip freeze` of a clean venv per file, on Python 3.11,
resolved with one union constraint set so a package shared between files has
one version):

- vendor/cm019_preferences, vendor/cm024_knowledge, vendor/ostler_security
- vendor/cm041/{contact_syncer,identity_resolver,meeting_syncer}
- vendor/cm059_editor/compiler, vendor/doctor/agent

Each direct line keeps its old range as a trailing `# was:` comment. Regenerate
with `scripts/pin_python_requirements.py`.

## Why

Red-team S4: 0 of 43 requirement lines were pinned; install and upgrade pulled
whatever PyPI served. Proof: `tests/test_python_requirements_are_pinned.py`
(61 findings on the pre-pin tree, 0 after; mutants in its --self-test) and the
box-walk probe `installed_venvs_match_pinned_requirements`.

## Owed upstream

Re-vendoring any of these trees from source will overwrite the pins with the
upstream ranges and turn the gate red. Pin upstream, or re-run
`scripts/pin_python_requirements.py` after each sync. Hashes are v1.0.125.

## Not covered (named, not hidden)

- `pip install <bundled dir>` sites (ostler_security, legal, ostler_fda, cm021,
  cm024_knowledge, cm048_pipeline, cm052_ai_conversations) resolve their own
  pyproject.toml ranges; their transitive deps are not pinned by this change.
- Pins were checked against `pip freeze` of the four Ostler venvs on Mini16
  after the v1.0.123 walk (read-only). typing-inspection (0.4.4) and soupsieve
  (4.0) take the box versions. filelock 4.2.8 (ostler_security file) has no box
  venv to compare with, and was uploaded after the 123 tag; the 123 version is
  unknown.
