"""Read one email into the few things the extractor needs.

The body is held in memory only while a message is processed and is never
written out. Remote content (images, tracking pixels, links) is never loaded.
"""

from __future__ import annotations

import email
import hashlib
import json
import re
from dataclasses import dataclass, field
from datetime import datetime
from email import policy
from email.message import Message
from email.utils import parseaddr, parsedate_to_datetime
from typing import Any, Dict, List, Optional

from bs4 import BeautifulSoup

from .textutil import html_to_text, normalise_lines


@dataclass
class ParsedMessage:
    message_id: str
    from_address: str
    from_domain: str
    from_name: str
    subject: str
    date: Optional[datetime]
    text: str  # line text, tab separated columns
    html: str = ""
    jsonld: List[Dict[str, Any]] = field(default_factory=list)
    microdata: List[Dict[str, Any]] = field(default_factory=list)
    headers: Dict[str, str] = field(default_factory=dict)


def _part_text(part: Message) -> str:
    try:
        return part.get_content()
    except Exception:
        payload = part.get_payload(decode=True) or b""
        return payload.decode(part.get_content_charset() or "utf-8", errors="replace")


def _domain(addr: str) -> str:
    return addr.rsplit("@", 1)[-1].lower() if "@" in addr else ""


def _synthetic_id(from_addr: str, subject: str, date: str) -> str:
    h = hashlib.sha256(f"{from_addr}|{subject}|{date}".encode()).hexdigest()[:24]
    return f"<synthetic-{h}@local>"


def parse_message(msg: Message) -> ParsedMessage:
    name, addr = parseaddr(str(msg.get("From", "")))
    subject = str(msg.get("Subject", "") or "")
    raw_date = str(msg.get("Date", "") or "")
    try:
        date = parsedate_to_datetime(raw_date).replace(tzinfo=None) if raw_date else None
    except (TypeError, ValueError):
        date = None
    mid = str(msg.get("Message-ID", "") or "").strip() or _synthetic_id(addr, subject, raw_date)

    html, plain = "", ""
    for part in msg.walk():
        if part.is_multipart():
            continue
        ctype = part.get_content_type()
        disp = str(part.get("Content-Disposition", "") or "")
        if "attachment" in disp.lower():
            continue
        if ctype == "text/html" and not html:
            html = _part_text(part)
        elif ctype == "text/plain" and not plain:
            plain = _part_text(part)
    text = html_to_text(html) if html else normalise_lines(plain)
    jsonld, micro = ([], [])
    if html:
        jsonld = extract_jsonld(html)
        micro = extract_microdata(html)
    return ParsedMessage(
        message_id=mid, from_address=addr.lower(), from_domain=_domain(addr),
        from_name=name, subject=subject, date=date, text=text, html=html,
        jsonld=jsonld, microdata=micro,
        headers={k.lower(): str(v) for k, v in msg.items() if k.lower() in
                 ("list-unsubscribe", "precedence", "x-mailer", "auto-submitted")},
    )


def parse_bytes(raw: bytes) -> ParsedMessage:
    return parse_message(email.message_from_bytes(raw, policy=policy.default))


def extract_jsonld(html: str) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup.find_all("script", attrs={"type": re.compile(r"ld\+json", re.I)}):
        try:
            data = json.loads(tag.string or tag.get_text() or "")
        except (ValueError, TypeError):
            continue
        out.extend(_flatten_jsonld(data))
    return out


def _flatten_jsonld(data: Any) -> List[Dict[str, Any]]:
    if isinstance(data, list):
        return [d for item in data for d in _flatten_jsonld(item)]
    if isinstance(data, dict):
        if "@graph" in data:
            return _flatten_jsonld(data["@graph"])
        return [data]
    return []


def extract_microdata(html: str) -> List[Dict[str, Any]]:
    """Minimal schema.org microdata reader: top-level itemscope elements to dicts."""
    soup = BeautifulSoup(html, "html.parser")

    def read(scope) -> Dict[str, Any]:
        item: Dict[str, Any] = {}
        t = scope.get("itemtype")
        if t:
            item["@type"] = t.rstrip("/").rsplit("/", 1)[-1]

        def walk(node):
            for child in node.children:
                if not getattr(child, "attrs", None) and not hasattr(child, "children"):
                    continue
                if not hasattr(child, "get"):
                    continue
                prop = child.get("itemprop")
                if prop:
                    if child.has_attr("itemscope"):
                        value: Any = read(child)
                    elif child.name == "meta":
                        value = child.get("content")
                    elif child.name in ("time",) and child.get("datetime"):
                        value = child.get("datetime")
                    elif child.name in ("link", "a") and child.get("href"):
                        value = child.get("href")
                    else:
                        value = child.get_text(" ", strip=True)
                    if prop in item:
                        if not isinstance(item[prop], list):
                            item[prop] = [item[prop]]
                        item[prop].append(value)
                    else:
                        item[prop] = value
                    if child.has_attr("itemscope"):
                        continue
                if not child.has_attr("itemscope") or not prop:
                    walk(child)

        walk(scope)
        return item

    scopes = [s for s in soup.find_all(attrs={"itemscope": True})
              if not s.find_parent(attrs={"itemscope": True})]
    return [read(s) for s in scopes]
