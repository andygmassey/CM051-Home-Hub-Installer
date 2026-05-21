"""CardDAV client for reading contacts from an iCloud (or compatible) server."""
from __future__ import annotations

from typing import Dict, List, Optional, Tuple
from xml.etree import ElementTree as ET

import httpx

# XML namespace map
NS_DAV = "DAV:"
NS_CARD = "urn:ietf:params:xml:ns:carddav"
NS_CS = "http://calendarserver.org/ns/"


class CardDAVClient:
    """Read-only CardDAV client using httpx."""

    def __init__(self, url: str, username: str, password: str) -> None:
        self.url = url.rstrip("/") + "/"
        self.username = username
        self.password = password
        self._auth = httpx.BasicAuth(username, password)

    # -- helpers --------------------------------------------------------------

    def _request(
        self,
        method: str,
        url: Optional[str] = None,
        *,
        headers: Optional[Dict[str, str]] = None,
        content: Optional[str] = None,
        timeout: float = 60.0,
    ) -> httpx.Response:
        target = url or self.url
        resp = httpx.request(
            method,
            target,
            auth=self._auth,
            headers=headers or {},
            content=content,
            timeout=timeout,
        )
        resp.raise_for_status()
        return resp

    @staticmethod
    def _find_text(element: ET.Element, path: str) -> Optional[str]:
        """Find text at *path* (using Clark notation already in *path*)."""
        node = element.find(path)
        if node is not None and node.text:
            return node.text.strip()
        return None

    # -- public API -----------------------------------------------------------

    def get_ctag(self) -> str:
        """Return the collection CTag (calendarserver extension)."""
        body = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/">'
            "  <d:prop>"
            "    <cs:getctag/>"
            "  </d:prop>"
            "</d:propfind>"
        )
        resp = self._request(
            "PROPFIND",
            headers={"Depth": "0", "Content-Type": "application/xml; charset=utf-8"},
            content=body,
        )
        root = ET.fromstring(resp.text)
        ctag = root.find(f".//{{{NS_CS}}}getctag")
        if ctag is not None and ctag.text:
            return ctag.text.strip()
        raise ValueError("CTag not found in PROPFIND response")

    def get_etags(self) -> Dict[str, str]:
        """Return ``{href: etag}`` for every vCard in the collection.

        *href* is the relative path component (typically ``<uid>.vcf``).
        """
        body = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<d:propfind xmlns:d="DAV:">'
            "  <d:prop>"
            "    <d:getetag/>"
            "  </d:prop>"
            "</d:propfind>"
        )
        resp = self._request(
            "PROPFIND",
            headers={"Depth": "1", "Content-Type": "application/xml; charset=utf-8"},
            content=body,
        )
        root = ET.fromstring(resp.text)
        etags: Dict[str, str] = {}
        for response_el in root.findall(f"{{{NS_DAV}}}response"):
            href_el = response_el.find(f"{{{NS_DAV}}}href")
            etag_el = response_el.find(f".//{{{NS_DAV}}}getetag")
            if href_el is not None and href_el.text and etag_el is not None and etag_el.text:
                href = href_el.text.strip()
                # Skip the collection URL itself (no .vcf extension)
                if not href.endswith(".vcf"):
                    continue
                etags[href] = etag_el.text.strip()
        return etags

    def get_vcard(self, href: str) -> str:
        """Fetch a single vCard by its href path and return raw vCard text."""
        # Build absolute URL from href
        if href.startswith("http"):
            url = href
        else:
            # href is an absolute path -- derive base from self.url
            from urllib.parse import urlparse

            parsed = urlparse(self.url)
            url = f"{parsed.scheme}://{parsed.netloc}{href}"
        resp = self._request("GET", url=url, headers={"Accept": "text/vcard"})
        return resp.text

    def put_vcard(self, href: str, vcard_text: str, etag: str) -> None:
        """Update an existing vCard via PUT with ETag concurrency check.

        Args:
            href: the resource path (from get_etags)
            vcard_text: the full modified vCard text
            etag: the current ETag (from get_etags) for If-Match safety
        """
        if href.startswith("http"):
            url = href
        else:
            from urllib.parse import urlparse
            parsed = urlparse(self.url)
            url = f"{parsed.scheme}://{parsed.netloc}{href}"
        self._request(
            "PUT",
            url=url,
            headers={
                "Content-Type": "text/vcard; charset=utf-8",
                "If-Match": etag,
            },
            content=vcard_text,
        )

    def get_all_vcards(self) -> List[str]:
        """Fetch all vCards via REPORT addressbook-query.

        Falls back to PROPFIND + individual GET if the server does not
        support ``addressbook-query``.
        """
        body = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<card:addressbook-query xmlns:d="DAV:" '
            'xmlns:card="urn:ietf:params:xml:ns:carddav">'
            "  <d:prop>"
            "    <d:getetag/>"
            "    <card:address-data/>"
            "  </d:prop>"
            "</card:addressbook-query>"
        )
        try:
            resp = self._request(
                "REPORT",
                headers={
                    "Depth": "1",
                    "Content-Type": "application/xml; charset=utf-8",
                },
                content=body,
                timeout=120.0,
            )
        except httpx.HTTPStatusError:
            # Fallback: fetch ETags then GET each vCard individually
            return self._fetch_all_individually()

        root = ET.fromstring(resp.text)
        vcards: List[str] = []
        for response_el in root.findall(f"{{{NS_DAV}}}response"):
            data_el = response_el.find(f".//{{{NS_CARD}}}address-data")
            if data_el is not None and data_el.text:
                vcards.append(data_el.text)
        return vcards

    def _fetch_all_individually(self) -> List[str]:
        """Fetch all vCards one-by-one via GET (fallback)."""
        etags = self.get_etags()
        vcards: List[str] = []
        for href in etags:
            try:
                vcards.append(self.get_vcard(href))
            except httpx.HTTPStatusError:
                continue
        return vcards

    def get_changed_vcards(
        self, old_etags: Dict[str, str]
    ) -> Tuple[List[str], List[str]]:
        """Compare current ETags against *old_etags*.

        Returns ``(changed_vcard_texts, deleted_hrefs)`` where
        *changed_vcard_texts* contains the raw vCard text for new or
        modified contacts, and *deleted_hrefs* lists hrefs that are no
        longer present on the server.
        """
        current_etags = self.get_etags()

        # Determine which contacts changed or are new
        changed_hrefs: List[str] = []
        for href, etag in current_etags.items():
            if href not in old_etags or old_etags[href] != etag:
                changed_hrefs.append(href)

        # Determine deleted contacts
        deleted_hrefs = [h for h in old_etags if h not in current_etags]

        # Fetch full vCard for each changed/new contact
        changed_vcards: List[str] = []
        for href in changed_hrefs:
            try:
                changed_vcards.append(self.get_vcard(href))
            except httpx.HTTPStatusError:
                continue

        return changed_vcards, deleted_hrefs
