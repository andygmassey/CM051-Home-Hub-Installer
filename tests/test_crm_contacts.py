"""Lane 31: Dex and Mesh (formerly Clay) contact CSV -> vCard for Apple Contacts.
All data synthetic (example.test, +44 7700 900xxx)."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from crm_contacts import convert, detect_csv, read_csv  # noqa: E402

# Dex: Settings > Export; contacts columns as documented on
# guide.getdex.com/integrations/exporting-from-dex (search summary, 2026-10-18):
# Id, Name, Title, Company, Description, Birthday, Email, Phone, Last interaction,
# Keep-in-touch frequency, Twitter, LinkedIn, Facebook, Groups. Multi-value
# separators are ASSUMED.
DEX = ('Id,First Name,Last Name,Full Name,Title,Company,Description,Birthday,Email,Phone,'
       'Last interaction,Keep-in-touch frequency,Twitter,LinkedIn,Facebook,Groups\n'
       'dx1,Alex,Example,Alex Example,Head of Synthetic Ops,Example Co,"Met at a synthetic conference, likes sailing",'
       '1990-04-12,"alex@example.test, alex.work@example.test",+44 7700 900001,2026-02-01,Monthly,'
       'https://x.com/alexexample,https://www.linkedin.com/in/alex-example,,"Friends:::Work"\n'
       'dx2,,,Sam Sample,,,,,,+44 7700 900002,,,,,,\n'
       'dx3,,,,,,,,,,,,,,,\n')

# Mesh (formerly Clay): Settings > General > Export my Data, CSV emailed from
# notify@me.sh, "backward compatible with Google Contacts"
# (library.me.sh/hc/en-us/articles/6821989456027). Columns are NOT documented:
# Google Contacts CSV headers are ASSUMED.
MESH = ('Name,Given Name,Family Name,Birthday,Notes,Group Membership,E-mail 1 - Type,E-mail 1 - Value,'
        'E-mail 2 - Type,E-mail 2 - Value,Phone 1 - Type,Phone 1 - Value,Organization 1 - Name,'
        'Organization 1 - Title,Website 1 - Value\n'
        'Robin Sample,Robin,Sample,,"Synthetic note; line two",* myContacts ::: Investors,Home,'
        'robin@example.test,Work,robin.w@example.test,Mobile,+44 7700 900003,Sample Ltd,Partner,'
        'https://example.test/robin\n')


def test_detects_both_and_refuses_unknown(tmp_path):
    (tmp_path / "dex.csv").write_text(DEX)
    (tmp_path / "mesh.csv").write_text(MESH)
    (tmp_path / "budget.csv").write_text("Month,Amount\nJan,1\n")
    assert detect_csv(tmp_path / "dex.csv") == "dex"
    assert detect_csv(tmp_path / "mesh.csv") == "mesh"
    assert detect_csv(tmp_path / "budget.csv") is None
    with pytest.raises(ValueError):
        read_csv(tmp_path / "budget.csv")

def test_dex_fields(tmp_path):
    (tmp_path / "dex.csv").write_text(DEX)
    src, people = read_csv(tmp_path / "dex.csv")
    assert src == "dex" and [p.full_name for p in people] == ["Alex Example", "Sam Sample"]  # empty row dropped
    a = people[0]
    assert a.emails == ["alex@example.test", "alex.work@example.test"]
    assert a.org == "Example Co" and a.title == "Head of Synthetic Ops" and a.birthday == "1990-04-12"
    assert a.groups == ["Friends", "Work"] and "https://www.linkedin.com/in/alex-example" in a.urls

def test_mesh_google_style_fields(tmp_path):
    (tmp_path / "mesh.csv").write_text(MESH)
    src, people = read_csv(tmp_path / "mesh.csv")
    r = people[0]
    assert src == "mesh" and r.full_name == "Robin Sample" and r.given == "Robin"
    assert r.emails == ["robin@example.test", "robin.w@example.test"] and r.phones == ["+44 7700 900003"]
    assert r.groups == ["Investors"]          # Google's "* myContacts" system group is not a label

def test_vcard_round_trip_is_valid_and_escaped(tmp_path):
    (tmp_path / "dex.csv").write_text(DEX)
    out = tmp_path / "out.vcf"
    n = convert(tmp_path / "dex.csv", out)
    v = out.read_bytes().decode()
    assert n == 2 and v.count("BEGIN:VCARD") == 2 and v.count("END:VCARD") == 2
    assert "VERSION:3.0" in v and "FN:Alex Example" in v and "N:Example;Alex;;;" in v
    assert "EMAIL;TYPE=INTERNET:alex.work@example.test" in v and "TEL:+44 7700 900002" in v
    assert "NOTE:Met at a synthetic conference\\, likes sailing" in v      # RFC 2426 escaping
    assert "BDAY:1990-04-12" in v and "CATEGORIES:Friends,Work" in v and "X-OSTLER-SOURCE:Dex" in v
    assert all(len(l.encode()) <= 75 for l in v.split("\r\n"))            # folded lines
    assert "\r\n" in v

def test_cli_writes_a_vcf_next_to_the_export(tmp_path):
    (tmp_path / "mesh-export.csv").write_text(MESH)
    r = subprocess.run([sys.executable, "-m", "crm_contacts", str(tmp_path / "mesh-export.csv")],
                       capture_output=True, text=True, cwd=ROOT, env={"PYTHONPATH": str(ROOT), "PATH": "/usr/bin:/bin"})
    assert r.returncode == 0, r.stderr
    vcf = tmp_path / "mesh-export (for Contacts).vcf"
    assert vcf.exists() and "1 contact" in r.stdout and "Contacts" in r.stdout
    bad = subprocess.run([sys.executable, "-m", "crm_contacts", str(ROOT / "README.md")],
                         capture_output=True, text=True, cwd=ROOT, env={"PYTHONPATH": str(ROOT), "PATH": "/usr/bin:/bin"})
    assert bad.returncode == 1 and "not a Dex or Mesh" in bad.stderr


def test_ostlers_own_vcard_reader_reads_every_card(tmp_path):
    """Consumer side: contact_syncer.vcard_parser is the reader Ostler uses
    for vCards from Contacts (syncer.sync_from_vcf). It must read every card."""
    pytest.importorskip("vobject", reason="CANNOT-RUN: vobject (contact_syncer dependency) not installed")
    from contact_syncer.vcard_parser import parse_vcard
    (tmp_path / "dex.csv").write_text(DEX)
    (tmp_path / "mesh.csv").write_text(MESH)
    got = []
    for name in ("dex", "mesh"):
        out = tmp_path / f"{name}.vcf"
        convert(tmp_path / f"{name}.csv", out)
        cards = [c + "END:VCARD\r\n" for c in out.read_bytes().decode().split("END:VCARD\r\n") if c.strip()]
        got += [parse_vcard(c) for c in cards]
    assert [c["fn"] for c in got] == ["Alex Example", "Sam Sample", "Robin Sample"]
    alex = got[0]
    assert [e["value"] if isinstance(e, dict) else e for e in alex["emails"]] == [
        "alex@example.test", "alex.work@example.test"]
    assert alex["org"] == "Example Co" and alex["birthday"] == "1990-04-12"
    assert alex["notes"] == "Met at a synthetic conference, likes sailing"   # escaping undone by the reader
