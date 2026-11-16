#!/usr/bin/env python3
"""lib/ostler_consent_display.py extends the consent log without breaking it.

The consent log is <OSTLER_HOME>/posture/consent.json, written by the vendored
ostler_security.consent (via consent_cli, from install.sh _consent_cli_record).
The helper adds display_language / display_review_ids / display_recorded_at /
display_schema to the record just written. These checks use the REAL vendored
writer and readers:

  - a record written by consent.record_consent, then extended, is still read
    by consent.read_consent and is still is_current against its wording hash
    (the gates key on the ENGLISH hash: English prevails);
  - a pre-existing record WITHOUT display fields stays readable (old records);
  - every tickbox consent_cli can record has a surface in the helper, and the
    helper knows no tickbox consent_cli does not (contract, both sides);
  - en-GB shows no translated line: display_review_ids == [];
  - failures exit non-zero (unknown tickbox 2, no record 1), never a silent 0;
  - the file stays mode 0600.
"""
import importlib.util
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
HELPER = ROOT / "lib" / "ostler_consent_display.py"
FAILS = []


def check(name, cond, detail=""):
    print(f"  {'ok  ' if cond else 'FAIL'} {name}" + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        FAILS.append(name)


def run(*args):
    r = subprocess.run([sys.executable, "-I", str(HELPER), *args], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def main():
    home = pathlib.Path(tempfile.mkdtemp(prefix="consent-display-"))
    os.environ["OSTLER_HOME"] = str(home)
    sys.path.insert(0, str(ROOT / "vendor"))
    from ostler_security import consent, consent_cli  # the vendored writer + registry
    spec = importlib.util.spec_from_file_location("ocd", HELPER)
    ocd = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ocd)

    check("contract: helper surfaces == consent_cli TICKBOX_REGISTRY",
          set(ocd.SURFACES) == set(consent_cli.TICKBOX_REGISTRY),
          f"{sorted(set(consent_cli.TICKBOX_REGISTRY) ^ set(ocd.SURFACES))}")

    cs = consent_cli.TICKBOX_REGISTRY["personal_use_only"]
    consent.record_consent(tickbox_id=cs.tickbox_id, wording_text=cs.text, wording_version=cs.version,
                           decision="accepted", region="uk", wording_hash=cs.sha256(), user_id="u-test", scope=cs.scope)
    # an OLD record (no display fields) for another tickbox, as written before this change
    cs2 = consent_cli.TICKBOX_REGISTRY["third_party_data_personal_records"]
    consent.record_consent(tickbox_id=cs2.tickbox_id, wording_text=cs2.text, wording_version=cs2.version,
                           decision="accepted", region="uk", wording_hash=cs2.sha256(), user_id="u-test", scope=cs2.scope)
    posture = home / "posture"

    rc, out = run("--posture", str(posture), "--tickbox", "personal_use_only", "--lang", "en-GB", "--resources", str(ROOT))
    check("helper exits 0 on the real repo resources", rc == 0, out)
    rec = consent.read_consent("personal_use_only")
    check("extended record still read by the vendored reader", isinstance(rec, dict) and rec.get("decision") == "accepted")
    check("extended record still is_current on its English hash", consent.is_current("personal_use_only", cs.sha256()))
    check("display_language recorded", rec.get("display_language") == "en-GB")
    check("en-GB: no translated line, display_review_ids == []", rec.get("display_review_ids") == [])
    check("display_schema 1", rec.get("display_schema") == 1)
    old = consent.read_consent("third_party_data_personal_records")
    check("an old record without display fields stays readable and current",
          old and "display_language" not in old and consent.is_current(cs2.tickbox_id, cs2.sha256()))
    mode = stat.S_IMODE(os.stat(posture / "consent.json").st_mode)
    check("consent.json stays 0600", mode == 0o600, oct(mode))

    rc, out = run("--posture", str(posture), "--tickbox", "no_such_tickbox", "--lang", "de", "--resources", str(ROOT))
    check("unknown tickbox exits 2", rc == 2, out)
    rc, out = run("--posture", str(posture), "--tickbox", "voice_speaker_id_eu", "--lang", "de", "--resources", str(ROOT))
    check("no record for the tickbox exits 1 (never a silent 0)", rc == 1, out)
    rc, out = run("--posture", str(posture), "--tickbox", "personal_use_only", "--lang", "de", "--resources", str(home))
    check("resources without the strings catalogue exits 1", rc == 1, out)

    # a translated line is named; an English one is not (synthetic resources)
    res = home / "res"
    res.mkdir()
    (res / "install.sh.strings.en-GB.sh").write_text('MSG_TERMS_PERSONAL_USE_LEGAL="Licensed for personal use."\n'
                                                      'MSG_TERMS_PERSONAL_USE_INTRO="Read this."\n', encoding="utf-8")
    (res / "install.sh.strings.de.sh").write_text('MSG_TERMS_PERSONAL_USE_LEGAL="Lizenziert f\\u00fcr den pers\\u00f6nlichen Gebrauch."\n'
                                                   'MSG_TERMS_PERSONAL_USE_INTRO="Read this."\n', encoding="utf-8")
    rc, out = run("--posture", str(posture), "--tickbox", "personal_use_only", "--lang", "de", "--resources", str(res))
    ids = consent.read_consent("personal_use_only").get("display_review_ids")
    check("translated line named by its review row id",
          ids == [f"de/install_sh::MSG_TERMS_PERSONAL_USE_LEGAL@{ocd.h('Licensed for personal use.')}"], str(ids))
    # a zh-Hans screen is recorded as zh-Hans, with the zh-Hans row id (not en-GB, not another language)
    (res / "install.sh.strings.zh-Hans.sh").write_text('MSG_TERMS_PERSONAL_USE_LEGAL="仅授权个人使用。"\n'
                                                        'MSG_TERMS_PERSONAL_USE_INTRO="Read this."\n', encoding="utf-8")
    rc, out = run("--posture", str(posture), "--tickbox", "personal_use_only", "--lang", "zh-Hans", "--resources", str(res))
    rec = consent.read_consent("personal_use_only")
    check("zh-Hans run exits 0", rc == 0, out)
    check("zh-Hans run records display_language zh-Hans", rec.get("display_language") == "zh-Hans", str(rec.get("display_language")))
    check("zh-Hans run names the zh-Hans review row",
          rec.get("display_review_ids") == [f"zh-Hans/install_sh::MSG_TERMS_PERSONAL_USE_LEGAL@{ocd.h('Licensed for personal use.')}"],
          str(rec.get("display_review_ids")))
    print("PASS" if not FAILS else f"FAIL ({len(FAILS)})")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
