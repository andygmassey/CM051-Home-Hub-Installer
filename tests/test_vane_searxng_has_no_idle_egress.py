#!/usr/bin/env python3
"""ostler-vane (Vane + bundled SearXNG) must make NO network call that the owner
did not ask for, and its search-engine set must be small, named and declared.

Before this gate the container ran the image's own settings: `use_default_settings:
true` (every engine SearXNG ships, several dozen, including wikidata and the
Wikipedia family), `autocomplete: google`, and wolframalpha switched on. A walk
box showed ostler-vane holding a CLOSE-WAIT socket to a Wikimedia address with
nothing asked of it. That is the cost of inheriting a default list nobody read.

What is pinned here, all read from the SHIPPED install.sh and not from a copy:
  1. install.sh writes a SearXNG settings file and the `vane` compose service
     mounts it read-only at /etc/searxng/settings.yml, so the container does
     not fall back to the image's defaults.
  2. The file keeps ONLY the allow-listed engines (keep_only), and every engine
     host is a row in scripts/box_walk_probes/egress_hosts.tsv.
  3. Every idle-network feature is off: autocomplete, favicon resolver, image
     proxy, metrics, the tor-exit-list plugin, the DOI rewriter.

Run with no arguments to gate the real tree; --self-test proves each arm can go
red by breaking a copy of the shipped settings one property at a time.
Exit 0 pass, 1 fail, 2 CANNOT-RUN.
"""
import copy
import pathlib
import re
import sys

try:
    import yaml
except ImportError:  # CANNOT-RUN is not PASS
    print("CANNOT-RUN: PyYAML is not importable")
    sys.exit(2)

ROOT = pathlib.Path(__file__).resolve().parent.parent
INSTALL = ROOT / "install.sh"
LEDGER = ROOT / "scripts/box_walk_probes/egress_hosts.tsv"
SETTINGS_MARK = "VSEOF"
MOUNT = "/etc/searxng/settings.yml"

# The whole allow-list. Adding an engine is a public privacy claim: it needs a
# ledger row (arm 2) and an edit here, in the same PR.
ENGINES = {
    "duckduckgo": ["html.duckduckgo.com"],
    "brave": ["search.brave.com"],
    "wikipedia": ["en.wikipedia.org"],
}
# SearXNG plugins that can open a socket on their own account.
NETWORK_PLUGINS = [
    "searx.plugins.tor_check.SXNGPlugin",
    "searx.plugins.oa_doi_rewrite.SXNGPlugin",
]


class CannotRun(Exception):
    pass


def shipped_settings(text):
    m = re.search(
        r"<<'%s'\n(?P<body>.*?)\n%s\n" % (SETTINGS_MARK, SETTINGS_MARK), text, re.S
    )
    if not m:
        return None
    return yaml.safe_load(m.group("body"))


def check_settings(s):
    """Return a list of violations for a parsed settings mapping."""
    bad = []
    if not isinstance(s, dict):
        return ["settings did not parse to a mapping"]
    uds = s.get("use_default_settings")
    keep = (uds or {}).get("engines", {}).get("keep_only") if isinstance(uds, dict) else None
    if keep is None:
        bad.append("use_default_settings has no engines.keep_only: every default engine is live")
    elif sorted(keep) != sorted(ENGINES):
        bad.append(f"engine set {sorted(keep)} != allow-list {sorted(ENGINES)}")
    # An `engines:` block can re-enable an engine that keep_only dropped.
    for e in s.get("engines", []) or []:
        if e.get("name") not in ENGINES or e.get("disabled") is False and e.get("name") not in ENGINES:
            bad.append(f"engines: block names {e.get('name')!r}, not in the allow-list")
    search = s.get("search") or {}
    if search.get("autocomplete", "<unset>") != "":
        bad.append(f"search.autocomplete={search.get('autocomplete', '<unset: image default>')!r}, want ''")
    if search.get("favicon_resolver", "<unset>") != "":
        bad.append(f"search.favicon_resolver={search.get('favicon_resolver', '<unset>')!r}, want ''")
    server = s.get("server") or {}
    if server.get("image_proxy") is not False:
        bad.append(f"server.image_proxy={server.get('image_proxy', '<unset>')!r}, want false")
    if server.get("limiter") is not False:
        bad.append(f"server.limiter={server.get('limiter', '<unset>')!r}, want false")
    if (s.get("general") or {}).get("enable_metrics") is not False:
        bad.append("general.enable_metrics is not false")
    plugins = s.get("plugins") or {}
    for p in NETWORK_PLUGINS:
        if (plugins.get(p) or {}).get("active") is not False:
            bad.append(f"plugin {p} is not explicitly active: false")
    return bad


def check_tree(root_install, ledger_text):
    bad = []
    text = root_install
    s = shipped_settings(text)
    if s is None:
        return ["install.sh has no <<'%s' settings heredoc for the vane SearXNG" % SETTINGS_MARK]
    bad += check_settings(s)
    if MOUNT + ":ro" not in text:
        bad.append(f"no compose mount of a file at {MOUNT}:ro: the image defaults would load")
    elif not re.search(r"\$\{HOME\}/\.ostler/vane-searxng-settings\.yml:" + re.escape(MOUNT) + ":ro", text):
        bad.append("the settings mount does not come from ~/.ostler/vane-searxng-settings.yml")
    # The file must exist before compose creates the container, or Docker
    # materialises a DIRECTORY at the bind path and SearXNG dies.
    w = text.find("<<'%s'" % SETTINGS_MARK)
    up = text.find("docker compose up -d vane")
    if w < 0 or up < 0 or w > up:
        bad.append("the settings file is not written before `docker compose up -d vane`")
    hosts = {l.split("\t", 1)[0].strip() for l in ledger_text.splitlines()
             if l.strip() and not l.lstrip().startswith("#")}
    for eng, hs in ENGINES.items():
        for h in hs:
            if h not in hosts:
                bad.append(f"engine {eng}: host {h} is not declared in egress_hosts.tsv")
    return bad


def self_test(install_text, ledger_text):
    s = shipped_settings(install_text)
    if s is None or check_settings(s):
        print("  [FAIL] control: the shipped settings must be clean before mutating")
        return 1
    muts = {
        "drop keep_only": lambda c: c["use_default_settings"].pop("engines"),
        "add an engine": lambda c: c["use_default_settings"]["engines"]["keep_only"].append("wikidata"),
        "autocomplete on": lambda c: c["search"].__setitem__("autocomplete", "google"),
        "favicon resolver on": lambda c: c["search"].__setitem__("favicon_resolver", "google"),
        "image proxy on": lambda c: c["server"].__setitem__("image_proxy", True),
        "metrics on": lambda c: c["general"].__setitem__("enable_metrics", True),
        "tor_check on": lambda c: c["plugins"]["searx.plugins.tor_check.SXNGPlugin"].__setitem__("active", True),
        "autocomplete unset": lambda c: c["search"].pop("autocomplete"),
    }
    rc = 0
    for name, fn in muts.items():
        c = copy.deepcopy(s)
        fn(c)
        if check_settings(c):
            print(f"  [PASS] mutant goes red: {name}")
        else:
            print(f"  [FAIL] mutant stayed green: {name}")
            rc = 1
    gutted = check_tree(install_text.replace("<<'%s'" % SETTINGS_MARK, "<<'XXEOF'"), ledger_text)
    print(f"  [{'PASS' if gutted else 'FAIL'}] tree without the settings heredoc goes red")
    nomount = check_tree(install_text.replace(MOUNT + ":ro", "/x:ro"), ledger_text)
    print(f"  [{'PASS' if nomount else 'FAIL'}] tree without the compose mount goes red")
    noledger = check_tree(install_text, ledger_text.replace("search.brave.com", "x.invalid"))
    print(f"  [{'PASS' if noledger else 'FAIL'}] tree with an undeclared engine host goes red")
    return rc or (0 if gutted and nomount and noledger else 1)


def main():
    for p in (INSTALL, LEDGER):
        if not p.is_file():
            print(f"CANNOT-RUN: {p} is absent")
            return 2
    install_text = INSTALL.read_text(encoding="utf-8")
    ledger_text = LEDGER.read_text(encoding="utf-8")
    if "--self-test" in sys.argv:
        return self_test(install_text, ledger_text)
    bad = check_tree(install_text, ledger_text)
    for b in bad:
        print(f"  [FAIL] {b}")
    if not bad:
        print(f"  [PASS] vane/SearXNG: {len(ENGINES)} engines, every idle-network feature off, hosts declared")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
