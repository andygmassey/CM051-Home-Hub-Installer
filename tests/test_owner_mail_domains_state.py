"""Owner mail-account domains in pipeline_signals.json (synthetic data only).

The installer's Accounts4 probe (tests/test_owner_mail_domains_probe.sh) emits
domains, never addresses. The writer refuses addresses, drops consumer webmail
as a second line of defence, and keeps the prior value when the probe could
not read the store (unknown is not "no accounts").
"""
from __future__ import annotations

import pathlib
import re
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))

import write_pipeline_signals as wps  # noqa: E402

INSTALL_SH = ROOT / "install.sh"
# An address, built at runtime so no fixture carries a literal one.
ADDRESS = "owner" + chr(64) + "workco.example"


def test_domains_are_written_as_a_list():
    assert wps.normalise_owner_mail_domains("workco.example") == ["workco.example"]


def test_address_is_refused_not_stored():
    with pytest.raises(ValueError):
        wps.normalise_owner_mail_domains(ADDRESS)


def test_webmail_domains_are_dropped_by_the_writer():
    got = wps.normalise_owner_mail_domains("gmail.com,workco.example,icloud.com")
    assert got == ["workco.example"]


def test_duplicates_and_case_collapse():
    got = wps.normalise_owner_mail_domains("WorkCo.Example, workco.example")
    assert got == ["workco.example"]


def test_empty_string_is_no_domains_not_unknown():
    assert wps.normalise_owner_mail_domains("") == []


def test_invalid_domain_is_refused():
    with pytest.raises(ValueError):
        wps.normalise_owner_mail_domains("not a domain")


def test_unknown_sentinel_preserves_the_prior_value():
    payload = wps.build_payload(None, None, 1, {"owner_mail_domains": ["workco.example"]},
                                owner_mail_domains=None)
    assert payload["owner_mail_domains"] == ["workco.example"]


def test_known_empty_overwrites_the_prior_value():
    payload = wps.build_payload(None, None, 1, {"owner_mail_domains": ["workco.example"]},
                                owner_mail_domains=[])
    assert payload["owner_mail_domains"] == []


def test_no_prior_and_unknown_writes_no_key():
    payload = wps.build_payload(None, None, 1, {}, owner_mail_domains=None)
    assert "owner_mail_domains" not in payload


def test_main_refuses_an_address_with_exit_2(tmp_path):
    rc = wps.main(["--output", str(tmp_path / "p.json"),
                   "--owner-mail-domains", ADDRESS])
    assert rc == 2
    assert not (tmp_path / "p.json").exists()


def test_main_unknown_sentinel_keeps_prior_on_disk(tmp_path):
    out = tmp_path / "p.json"
    out.write_text('{"owner_mail_domains": ["workco.example"]}')
    rc = wps.main(["--output", str(out), "--owner-mail-domains", "__unknown__"])
    assert rc == 0
    assert '"workco.example"' in out.read_text()


def test_shell_and_python_webmail_lists_do_not_drift():
    text = INSTALL_SH.read_text(encoding="utf-8")
    m = re.search(r'^_OWNER_WEBMAIL_DOMAINS="([^"]+)"', text, re.MULTILINE)
    assert m, "install.sh must define _OWNER_WEBMAIL_DOMAINS"
    assert set(m.group(1).split()) == set(wps.WEBMAIL_DOMAINS)
