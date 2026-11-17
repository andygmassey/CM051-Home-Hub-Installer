"""Contract: the measured wiki exposure on a customer Hub (install.sh).

Pins what was MEASURED on the customer path (2026-11-17):
  (a) store-proxy publishes the wiki on 127.0.0.1 only, for 8044 and 8144;
      wiki-site publishes nothing; :8044 needs the wiki credential; :8144 is
      gated on the owner's tailnet login AND the same credential.
  (b) the shipped Hub never runs CM044's standalone compose
      (docker/docker-compose.yml). The Hub runs the compose it generates.

Each check is a pure function over the install.sh TEXT, so the mutant tests
below can show it going red without editing the real file.

Citations are install.sh line numbers at 2026-11-17; the pattern is what is
pinned, so a re-numbering is not a failure but a removed pattern is.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

INSTALL = Path(__file__).resolve().parents[1] / "install.sh"
# Snapshot at import, so the mutant tests are independent of the file under test.
PRISTINE = INSTALL.read_text(encoding="utf-8")

# install.sh:22196-22199  store-proxy publishes, loopback only
LOOPBACK_PUBLISHES = ('"127.0.0.1:8044:8044"', '"127.0.0.1:8144:8144"')
# install.sh:22069        the compose the Hub generates and runs
GENERATED_COMPOSE = '> "${OSTLER_DIR}/docker-compose.yml"'
# install.sh:22896-22906  8044 answers 403 with no Authorization header
NO_AUTH_403 = 'if ($http_authorization = "") { return 403'
# install.sh:22920-22921 (credential include, both listeners)
AUTH_INCLUDE = "include /etc/nginx/ostler-wiki-auth.conf;"
# install.sh:23281-23308  owner-login allowlist and the gate check
OWNER_MAP = "map $http_tailscale_user_login $ostler_wiki_user_ok {"
OWNER_DEFAULT_DENY = "    default 0;"
GATE_CHECK = "if ($ostler_wiki_user_ok = 0) { return 403; }"


def _uncommented(text: str) -> list[str]:
    return [ln for ln in text.splitlines() if not ln.lstrip().startswith("#")]


def _block(text: str, name: str) -> str:
    """The compose service block `  <name>:` up to the next service key."""
    lines = text.splitlines()
    start = next(i for i, ln in enumerate(lines) if ln == f"  {name}:")
    end = start + 1
    while end < len(lines) and not re.match(r"^  [A-Za-z0-9_-]+:\s*$", lines[end]) \
            and not re.match(r"^\S", lines[end]):
        end += 1
    return "\n".join(lines[start:end])


def exposure_violations(text: str) -> list[str]:
    out: list[str] = []
    sp = _block(text, "store-proxy")
    for needle in LOOPBACK_PUBLISHES:
        if needle not in sp:
            out.append(f"store-proxy no longer publishes {needle}")
    # Nothing publishes 8044 or 8144 off loopback, anywhere in the installer.
    for ln in _uncommented(text):
        if re.search(r'"(?!127\.0\.0\.1:)[^"]*:(8044|8144):(8044|8144)"', ln):
            out.append(f"a non-loopback publish of 8044/8144: {ln.strip()}")
    if re.search(r"^\s{4}ports:", _block(text, "wiki-site"), re.M):
        out.append("wiki-site publishes a host port (bypasses the credential)")
    if NO_AUTH_403 not in text:
        out.append(":8044 no longer answers 403 without an Authorization header")
    if text.count(AUTH_INCLUDE) < 2:
        out.append("the wiki credential is not required on both 8044 and 8144")
    if OWNER_MAP not in text or OWNER_DEFAULT_DENY not in text:
        out.append("the 8144 tailnet gate no longer defaults to deny")
    if GATE_CHECK not in text:
        out.append("8144 no longer checks the tailnet owner login")
    return out


def shipped_compose_violations(text: str) -> list[str]:
    out: list[str] = []
    for ln in _uncommented(text):
        # A PATH to CM044 or to its dev compose, not a prose mention of CM044.
        if re.search(r"CM044/|/CM044\b|docker/docker-compose\.yml", ln):
            out.append(f"installer reaches CM044's dev compose: {ln.strip()}")
        if re.search(r"docker compose\b.*\s-f\s", ln):
            out.append(f"installer runs an explicit compose file: {ln.strip()}")
    if GENERATED_COMPOSE not in text:
        out.append("the generated compose heredoc is no longer written")
    return out


@pytest.fixture(scope="module")
def install_text() -> str:
    return INSTALL.read_text(encoding="utf-8")


def test_wiki_exposure_is_the_measured_one(install_text):
    assert exposure_violations(install_text) == []


def test_shipped_hub_never_runs_cm044_standalone_compose(install_text):
    assert shipped_compose_violations(install_text) == []


# ---- mutants: each must turn its check red on an in-memory copy -------

def _mutate(text: str, old: str, new: str) -> str:
    assert text.count(old) >= 1, f"mutant did not apply: {old[:60]!r}"
    return text.replace(old, new, 1)


A_MUTANTS = {
    "store-proxy publishes 8044 on all interfaces":
        lambda t: _mutate(t, '"127.0.0.1:8044:8044"', '"0.0.0.0:8044:8044"'),
    "8144 published without loopback":
        lambda t: _mutate(t, '"127.0.0.1:8144:8144"', '"8144:8144"'),
    "8044 stops requiring a credential header":
        lambda t: _mutate(t, NO_AUTH_403, 'if ($http_authorization = "") { return 200'),
    "8144 gate loses the owner-login check":
        lambda t: _mutate(t, GATE_CHECK, "# owner check removed"),
    "wiki-site regains a host publish":
        lambda t: _mutate(t, "  wiki-site:\n", "  wiki-site:\n    ports:\n      - \"8044:8000\"\n"),
}

B_MUTANTS = {
    "installer runs CM044's dev compose":
        lambda t: t + '\ndocker compose -f "$HOME/CM044/docker/docker-compose.yml" up -d\n',
    "installer reads CM044's dev compose path":
        lambda t: t + '\ncp "$HOME/CM044/docker/docker-compose.yml" "${OSTLER_DIR}/"\n',
}


@pytest.mark.parametrize("name", sorted(A_MUTANTS))
def test_each_exposure_mutant_goes_red(install_text, name):
    mutated = A_MUTANTS[name](PRISTINE)
    assert exposure_violations(mutated), f"mutant not caught: {name}"


@pytest.mark.parametrize("name", sorted(B_MUTANTS))
def test_each_compose_mutant_goes_red(install_text, name):
    mutated = B_MUTANTS[name](PRISTINE)
    assert shipped_compose_violations(mutated), f"mutant not caught: {name}"
