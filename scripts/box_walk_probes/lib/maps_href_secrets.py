"""wiki_maps_links_carry_no_join_secret: judge for the compiled-wiki grep (#2528).

CM044 #289 (compiler/pw_kit.py maps_href) refuses a URL-shaped location and any
pwd=/passcode= parameter, so a meeting join passcode is never sent to a maps
provider on one click. This is the walk grep that closes it: every URL in the
compiled wiki that mentions "maps" is extracted by extract_sh (find + grep,
run inside ostler-wiki-site on the box and on a fixture dir for the control),
and the judge counts those that carry pwd= or passcode= (also %3D encoded).

  extract DIR            print the maps-looking URL tokens under DIR
  extract-sh DIR | pages-sh DIR   the sh lines the probe runs on the box
  judge FILE FILES_SEEN  FILE = tokens, one per line; exit 0 PASS, 1 FAIL, 78 CANNOT-RUN
  --self-test            seeded positive control, clean control, blind control

Python 3.9 compatible, stdlib only.
"""
import re
import subprocess
import sys

EX_PASS, EX_FAIL, EX_CANNOT = 0, 1, 78

# One URL-ish token that mentions "maps". Ends at whitespace, ) " ' < >.
TOKEN_RX = "[^[:space:]()\"'<>]*[Mm][Aa][Pp][Ss][^[:space:]()\"'<>]*"
SECRET = re.compile(r"(?i)(?:pwd|passcode)(?:=|%3d)")


def extract_sh(root):
    """The ONE extractor, as a POSIX sh line. find+grep -Eoih only, so the same
    text runs under BSD grep (fixture control) and the wiki container's busybox
    or GNU grep (the box). The pattern is passed base64 so no quote survives."""
    import base64
    b = base64.b64encode(TOKEN_RX.encode()).decode()
    return ("P=$(printf %%s %s | base64 -d); find %s -type f \\( -name '*.md' -o -name '*.html' \\) "
            "-exec grep -Eoih \"$P\" {} +" % (b, root))


def pages_sh(root):
    return "find %s -type f \\( -name '*.md' -o -name '*.html' \\) | wc -l" % root


def judge(tokens, files_seen):
    """Return (rc, lines). files_seen is the denominator: pages scanned."""
    out = []
    if files_seen <= 0:
        return EX_CANNOT, ["CANNOT files_seen=0: the extractor looked at no page, so 0 hits means nothing"]
    bad = [t for t in tokens if SECRET.search(t)]
    out.append("pages_scanned=%d maps_urls=%d maps_urls_with_pwd_or_passcode=%d"
               % (files_seen, len(tokens), len(bad)))
    for t in bad[:5]:
        out.append("FAIL a maps link carries a join secret: %s" % SECRET.sub(lambda m: m.group(0) + "<redacted>", t.split("?")[0])[:120])
    return (EX_FAIL if bad else EX_PASS), out


def _extract(root):
    p = subprocess.run(["sh", "-c", extract_sh(root)], capture_output=True, text=True)
    if p.returncode not in (0, 1):
        raise SystemExit("extractor error rc=%d: %s" % (p.returncode, p.stderr.strip()))
    return [l for l in p.stdout.splitlines() if l.strip()]


def self_test(fixture_dir):
    fails = []
    rc, lines = judge(_extract(fixture_dir + "/bad"), 1)
    if rc != EX_FAIL or sum(1 for l in lines if l.startswith("FAIL")) != 2:
        fails.append("seeded positive control not caught: rc=%s %s" % (rc, lines))
    rc, _ = judge(_extract(fixture_dir + "/good"), 1)
    if rc != EX_PASS:
        fails.append("clean fixture raised a false FAIL: rc=%s" % rc)
    rc, _ = judge([], 0)
    if rc != EX_CANNOT:
        fails.append("blind extractor (0 pages) was not CANNOT-RUN: rc=%s" % rc)
    for f in fails:
        print("SELF-TEST " + f)
    return EX_PASS if not fails else EX_FAIL


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["extract-sh"]:
        print(extract_sh(a[1]))
    elif a[:1] == ["pages-sh"]:
        print(pages_sh(a[1]))
    elif a[:1] == ["extract"]:
        print("\n".join(_extract(a[1])))
    elif a[:1] == ["judge"]:
        toks = [l for l in open(a[1]).read().splitlines() if l.strip()]
        rc, lines = judge(toks, int(a[2]))
        print("\n".join(lines))
        sys.exit(rc)
    elif a[:1] == ["--self-test"]:
        sys.exit(self_test(a[1]))
    else:
        sys.exit("usage: extract DIR | judge FILE FILES_SEEN | --self-test FIXTURE_DIR")
