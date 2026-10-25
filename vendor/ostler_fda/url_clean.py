"""Strip known tracking parameters from a URL before it is stored.

Privacy rule: a browsing-history URL is stored without the advertising and
campaign identifiers that ride on it (utm_*, fbclid, gclid and so on).

DENYLIST ONLY. A parameter is removed only if it is on the list below.
Functional parameters (YouTube v/list/t, search q, page, id, ...) are never
touched, because the streaming-recognition work needs them. Unknown
parameters stay.

Contract:
  * pure function, stdlib only, no I/O;
  * the input is returned BYTE-IDENTICAL when nothing is stripped (no
    re-encoding, no normalisation, no reordering);
  * surviving parameters keep their original order and original bytes;
  * non-http(s) and non-string input is returned unchanged.

This file is shipped as byte-identical copies in several trees (HR015
ostler_fda, CM051 vendor/ostler_fda, CM051 vendor/cm041/assistant_api, the
Safari extension's server-side peer). tests/test_url_clean_parity compares
them. Edit one, edit them all.
"""
from __future__ import annotations

from urllib.parse import unquote

# Removed on every host. Compared lowercase.
_GLOBAL_PARAMS = frozenset({
    "fbclid", "gclid", "gbraid", "wbraid", "dclid", "msclkid",
    "mc_cid", "mc_eid", "igshid", "_hsenc", "_hsmi", "mkt_tok",
    "yclid", "twclid", "ttclid", "li_fat_id", "oly_anon_id",
    "oly_enc_id", "vero_id", "_ga", "_gl", "ref_src",
})

# Removed only on these hosts (or their subdomains): the same name is a
# real parameter elsewhere.
_HOST_PARAMS = {
    "si": ("open.spotify.com", "youtu.be"),
    "spm": (
        "aliexpress.com", "aliexpress.us", "alibaba.com", "1688.com",
        "taobao.com", "tmall.com", "alipay.com", "lazada.com",
        "lazada.sg", "lazada.co.th", "lazada.com.my", "lazada.vn",
        "lazada.co.id", "lazada.com.ph",
    ),
}

_TEXT_FRAGMENT = ":~:"


def _host(url: str) -> str:
    rest = url.split("://", 1)[1]
    for sep in ("/", "?", "#"):
        rest = rest.split(sep, 1)[0]
    rest = rest.rsplit("@", 1)[-1]
    if rest.startswith("["):
        return rest.lower()
    return rest.split(":", 1)[0].lower()


def _on_host(host: str, domains) -> bool:
    return any(host == d or host.endswith("." + d) for d in domains)


def _is_tracking(key: str, host: str) -> bool:
    k = unquote(key).lower()
    if k.startswith("utm_") or k in _GLOBAL_PARAMS:
        return True
    domains = _HOST_PARAMS.get(k)
    return bool(domains) and _on_host(host, domains)


def strip_tracking(url):
    """Return ``url`` without tracking parameters / text fragments."""
    if not isinstance(url, str):
        return url
    low = url[:8].lower()
    if not (low.startswith("http://") or low.startswith("https://")):
        return url
    base, hash_, frag = url.partition("#")
    path, q_, query = base.partition("?")
    host = _host(url)
    changed = False

    if q_ and query:
        kept = []
        for part in query.split("&"):
            if part and _is_tracking(part.split("=", 1)[0], host):
                changed = True
                continue
            kept.append(part)
        if changed:
            query = "&".join(kept)
            if not query:
                q_ = ""

    if hash_:
        cut = frag.find(_TEXT_FRAGMENT)
        if cut != -1 and frag[cut + 3:].startswith("text="):
            changed = True
            frag = frag[:cut]
            if not frag:
                hash_ = ""

    if not changed:
        return url
    return path + (q_ + query if q_ else "") + (hash_ + frag if hash_ else "")
