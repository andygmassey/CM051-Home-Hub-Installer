"""Brand recognition client using Wikidata.

Standardizes brand names across platforms to canonical Wikidata Q-IDs.
Resolves parent company relationships for brand hierarchy analysis.

Key Wikidata Properties:
- P31 (instance of): Q431289 (brand), Q4830453 (business), Q891723 (public company)
- P127 (owned by): points to owner entity
- P749 (parent organization): points to parent company
- P452 (industry): what industry the brand is in
- P856 (official website)
- P159 (headquarters location)
- P17 (country)
"""

import logging
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from .base import BaseClient, InMemoryCache
from .validation import title_similarity

logger = logging.getLogger(__name__)


@dataclass
class BrandInfo:
    """Information about a brand from Wikidata."""
    qid: str  # Wikidata Q-ID (e.g., "Q312")
    name: str  # Canonical brand name
    description: Optional[str] = None
    aliases: List[str] = field(default_factory=list)

    # Classification
    brand_type: Optional[str] = None  # "brand", "company", "subsidiary", etc.
    industries: List[str] = field(default_factory=list)  # Industry categories

    # Parent company chain
    owned_by: Optional["BrandInfo"] = None  # Direct owner (P127)
    parent_org: Optional["BrandInfo"] = None  # Parent organization (P749)
    ultimate_parent: Optional["BrandInfo"] = None  # Top of ownership chain

    # Additional metadata
    country: Optional[str] = None  # Country of origin
    headquarters: Optional[str] = None
    website: Optional[str] = None
    founded: Optional[str] = None

    @property
    def url(self) -> str:
        """Get Wikidata URL for this brand."""
        return f"https://www.wikidata.org/wiki/{self.qid}"

    def get_parent_chain(self) -> List["BrandInfo"]:
        """Get the full ownership chain from this brand to ultimate parent."""
        chain = []
        current = self.owned_by or self.parent_org
        while current:
            chain.append(current)
            current = current.owned_by or current.parent_org
        return chain

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "qid": self.qid,
            "name": self.name,
            "description": self.description,
            "aliases": self.aliases,
            "brand_type": self.brand_type,
            "industries": self.industries,
            "country": self.country,
            "headquarters": self.headquarters,
            "website": self.website,
            "founded": self.founded,
            "owned_by": self.owned_by.qid if self.owned_by else None,
            "parent_org": self.parent_org.qid if self.parent_org else None,
            "ultimate_parent": self.ultimate_parent.qid if self.ultimate_parent else None,
        }


@dataclass
class BrandLookupResult:
    """Result of a brand lookup operation."""
    query: str  # Original search query
    brand: Optional[BrandInfo] = None  # Matched brand
    confidence: float = 0.0  # Match confidence (0-1)
    match_type: str = "none"  # "exact", "fuzzy", "alias", "none"
    alternatives: List[BrandInfo] = field(default_factory=list)  # Other matches

    def is_match(self) -> bool:
        """Check if lookup found a confident match."""
        return self.brand is not None and self.confidence >= 0.5


# Wikidata Q-IDs for filtering brand-related entities
BRAND_TYPE_QIDS = {
    "Q431289": "brand",
    "Q4830453": "business",
    "Q891723": "public_company",
    "Q6881511": "enterprise",
    "Q783794": "company",
    "Q43229": "organization",
    "Q167037": "corporation",
    "Q134161": "joint_stock_company",
    "Q163740": "nonprofit_organization",
}

# Industry Q-IDs to readable names
# Known brand mappings - hardcoded to avoid search errors
# These brands had incorrect Q-IDs due to name collisions with people, animals, places, etc.
KNOWN_BRAND_QIDS = {
    # Sportswear/Footwear
    "puma": "Q157064",           # German multinational (not Q270748 the mammal)
    "nike": "Q483915",           # Nike Inc.
    "adidas": "Q3895",           # Adidas AG
    "new balance": "Q742988",    # New Balance (not Q136790032 the 2025 song)
    "under armour": "Q2031498",
    "asics": "Q227653",
    "reebok": "Q466183",
    # Electronics
    "philips": "Q170416",        # Koninklijke Philips NV (not Q89438875 given name)
    "sony": "Q41187",            # Sony Group Corporation (not Q65177437 given name)
    "samsung": "Q20718",
    "apple": "Q312",             # Apple Inc. (not Q89 the fruit)
    "lg": "Q186449",
    "panasonic": "Q182154",
    # Grills/Outdoor
    "weber": "Q79208032",        # Weber Grill brand (not Q1409226 family name)
    # Fashion
    "g-star": "Q1484081",        # G-Star Raw (not Q25943 Korean game trade show)
    "levis": "Q127962",
    "tommy hilfiger": "Q634881",
    "calvin klein": "Q1050099",
    # Motorcycle gear (no Wikidata entries - return None)
    # "rokker": None,            # No Wikidata entry for Rokker motorcycle jeans
    # "forcefield": None,        # No Wikidata entry for Forcefield armor
    # "knox": None,              # No Wikidata entry for Knox armor
    # "canterbury": None,        # No Wikidata entry for Canterbury clothing
}


INDUSTRY_MAPPINGS = {
    "Q11451": "agriculture",
    "Q880739": "automotive_industry",
    "Q373469": "banking",
    "Q3972943": "beauty_industry",
    "Q131186": "chemical_industry",
    "Q628099": "clothing_industry",
    "Q175089": "computer_hardware",
    "Q638": "music",
    "Q1414055": "consumer_electronics",
    "Q1369832": "e_commerce",
    "Q52": "entertainment",
    "Q43015": "finance",
    "Q211503": "food_industry",
    "Q232161": "footwear_industry",
    "Q80157": "hospitality_industry",
    "Q131512": "insurance",
    "Q628858": "internet",
    "Q482": "media",
    "Q179448": "medical_device",
    "Q124922": "petroleum_industry",
    "Q184395": "pharmaceutical_industry",
    "Q182828": "publishing",
    "Q613142": "retail",
    "Q17144808": "social_media",
    "Q16920908": "software_industry",
    "Q238570": "sports_industry",
    "Q31855": "technology",
    "Q418": "telecommunications",
    "Q5747893": "textile_industry",
    "Q2656332": "video_game_industry",
}


class BrandClient(BaseClient[BrandInfo]):
    """
    Client for brand recognition using Wikidata.

    Normalizes brand names to Wikidata Q-IDs and resolves
    parent company relationships for brand hierarchy analysis.

    Features:
    - Search brands by name
    - Resolve parent company chains (P127, P749)
    - Get industry classifications
    - Cache results for performance

    Rate limit: 1 req/sec (polite to Wikidata)
    """

    BASE_URL = "https://www.wikidata.org/w/api.php"
    SPARQL_URL = "https://query.wikidata.org/sparql"
    CACHE_PREFIX = "brand"

    def __init__(
        self,
        cache: Optional[InMemoryCache] = None,
        max_parent_depth: int = 5,
    ):
        """
        Initialize the brand client.

        Args:
            cache: Optional cache instance
            max_parent_depth: Maximum depth for parent company resolution
        """
        super().__init__(
            rate_limit=1.0,  # 1 req/sec
            max_retries=3,
            timeout=30.0,
            cache=cache,
        )
        self.max_parent_depth = max_parent_depth
        self._parent_cache: Dict[str, BrandInfo] = {}

    def _get_headers(self) -> Dict[str, str]:
        return {
            "Accept": "application/json",
            "User-Agent": "PWG-Brand-Recognition/0.1.0 (Personal World Graph; brand normalization)",
        }

    async def lookup_brand(
        self,
        brand_name: str,
        resolve_parents: bool = True,
        language: str = "en",
    ) -> BrandLookupResult:
        """
        Look up a brand by name and optionally resolve parent companies.

        Args:
            brand_name: Brand name to search for
            resolve_parents: Whether to resolve ownership chain
            language: Language for labels

        Returns:
            BrandLookupResult with matched brand and confidence
        """
        if not brand_name or not brand_name.strip():
            return BrandLookupResult(query=brand_name, match_type="none")

        brand_name = brand_name.strip()

        # Check known brands first (avoids search errors for ambiguous names)
        known_qid = KNOWN_BRAND_QIDS.get(brand_name.lower())
        if known_qid:
            logger.debug(f"Using known brand mapping: {brand_name} -> {known_qid}")
            brand_info = await self._get_brand_details(known_qid, language)
            if brand_info and resolve_parents:
                await self._resolve_parent_chain(brand_info, language)
            return BrandLookupResult(
                query=brand_name,
                brand=brand_info,
                confidence=1.0,  # Known mapping = high confidence
                match_type="exact",
            )

        # Search Wikidata for the brand
        search_results = await self._search_brands(brand_name, language)

        if not search_results:
            logger.debug(f"No brand matches for: {brand_name}")
            return BrandLookupResult(query=brand_name, match_type="none")

        # Score and rank results
        scored_results = []
        for result in search_results:
            score = self._calculate_match_score(brand_name, result)
            scored_results.append((result, score))

        # Sort by score
        scored_results.sort(key=lambda x: x[1], reverse=True)

        best_match, best_score = scored_results[0]
        alternatives = [r for r, _ in scored_results[1:5]]

        # Determine match type
        if best_score >= 0.95:
            match_type = "exact"
        elif best_score >= 0.7:
            match_type = "fuzzy"
        elif best_score >= 0.5:
            match_type = "alias"
        else:
            match_type = "weak"

        # Get full brand info
        brand_info = await self._get_brand_details(best_match["qid"], language)

        if brand_info and resolve_parents:
            await self._resolve_parent_chain(brand_info, language)

        return BrandLookupResult(
            query=brand_name,
            brand=brand_info,
            confidence=best_score,
            match_type=match_type,
            alternatives=alternatives,
        )

    async def get_brand(
        self,
        qid: str,
        resolve_parents: bool = True,
        language: str = "en",
    ) -> Optional[BrandInfo]:
        """
        Get brand info by Wikidata Q-ID.

        Args:
            qid: Wikidata Q-ID (e.g., "Q312" for Apple Inc.)
            resolve_parents: Whether to resolve ownership chain
            language: Language for labels

        Returns:
            BrandInfo or None if not found
        """
        brand = await self._get_brand_details(qid, language)

        if brand and resolve_parents:
            await self._resolve_parent_chain(brand, language)

        return brand

    async def search(self, query: str) -> Optional[BrandInfo]:
        """
        Search for a brand by name.

        Implementation of abstract method from BaseClient.

        Args:
            query: Brand name to search for

        Returns:
            First matching BrandInfo or None
        """
        result = await self.lookup_brand(query, resolve_parents=False)
        return result.brand

    async def get_details(self, item_id: str) -> Optional[BrandInfo]:
        """
        Get brand details by Wikidata Q-ID.

        Implementation of abstract method from BaseClient.

        Args:
            item_id: Wikidata Q-ID (e.g., "Q312")

        Returns:
            BrandInfo or None if not found
        """
        return await self.get_brand(item_id, resolve_parents=True)

    async def batch_lookup(
        self,
        brand_names: List[str],
        resolve_parents: bool = True,
        language: str = "en",
    ) -> Dict[str, BrandLookupResult]:
        """
        Look up multiple brands.

        Args:
            brand_names: List of brand names
            resolve_parents: Whether to resolve ownership chains
            language: Language for labels

        Returns:
            Dict mapping brand name to lookup result
        """
        results = {}
        for name in brand_names:
            results[name] = await self.lookup_brand(name, resolve_parents, language)
        return results

    async def get_brands_by_parent(
        self,
        parent_qid: str,
        language: str = "en",
    ) -> List[BrandInfo]:
        """
        Get all brands owned by a parent company.

        Args:
            parent_qid: Wikidata Q-ID of parent company
            language: Language for labels

        Returns:
            List of brands owned by the parent
        """
        query = f"""
        SELECT DISTINCT ?brand ?brandLabel ?brandDescription WHERE {{
          ?brand (wdt:P127|wdt:P749) wd:{parent_qid} .
          SERVICE wikibase:label {{ bd:serviceParam wikibase:language "{language},en" . }}
        }}
        LIMIT 100
        """

        result = await self._sparql_query(query)

        brands = []
        if result and "results" in result:
            bindings = result["results"].get("bindings", [])
            for binding in bindings:
                brand_uri = binding.get("brand", {}).get("value", "")
                if "entity/" in brand_uri:
                    qid = brand_uri.split("/")[-1]
                    if qid.startswith("Q"):
                        brand = BrandInfo(
                            qid=qid,
                            name=binding.get("brandLabel", {}).get("value", ""),
                            description=binding.get("brandDescription", {}).get("value"),
                        )
                        brands.append(brand)

        return brands

    async def _search_brands(
        self,
        query: str,
        language: str = "en",
    ) -> List[Dict[str, Any]]:
        """Search Wikidata for brand-related entities.

        CRITICAL: Must validate P31 (instance of) to avoid false positives.
        Without validation, "Apple" matches the fruit (Q89), "Sony" matches
        a given name (Q65177437), etc.
        """
        params = {
            "action": "wbsearchentities",
            "search": query,
            "language": language,
            "type": "item",
            "limit": 10,
            "format": "json",
        }

        result = await self._get("", params=params)

        if not result or "search" not in result:
            return []

        # MUST validate P31 (instance of) for each result
        # Only accept entities that are companies/brands/organizations
        validated = []

        for item in result["search"]:
            qid = item["id"]

            # Fetch P31 (instance of) claims to validate entity type
            is_valid_brand = await self._validate_is_company_or_brand(qid)

            if is_valid_brand:
                validated.append({
                    "qid": qid,
                    "label": item.get("label", ""),
                    "description": item.get("description"),
                    "aliases": item.get("aliases", []),
                })
            else:
                # Log rejected entities for debugging
                logger.debug(
                    f"Rejected non-brand entity: {qid} '{item.get('label')}' "
                    f"({item.get('description', 'no description')})"
                )

        return validated

    async def _validate_is_company_or_brand(self, qid: str) -> bool:
        """Validate that an entity is a company, brand, or organization.

        Checks P31 (instance of) claims against known brand-related types.
        This prevents matching fruits, people, songs, etc.
        """
        cache_key = f"validate:{qid}"

        # Check cache first
        if hasattr(self, '_validation_cache'):
            if qid in self._validation_cache:
                return self._validation_cache[qid]
        else:
            self._validation_cache = {}

        params = {
            "action": "wbgetentities",
            "ids": qid,
            "props": "claims",
            "format": "json",
        }

        result = await self._get("", params=params, cache_key=cache_key)

        if not result or "entities" not in result:
            self._validation_cache[qid] = False
            return False

        entity = result["entities"].get(qid)
        if not entity or entity.get("missing"):
            self._validation_cache[qid] = False
            return False

        claims = entity.get("claims", {})
        instance_of = self._extract_qid_claims(claims.get("P31", []))

        # Valid brand/company types (from BRAND_TYPE_QIDS plus additional)
        valid_types = {
            # Core company types
            "Q431289",   # brand
            "Q4830453",  # business
            "Q891723",   # public company
            "Q6881511",  # enterprise
            "Q783794",   # company
            "Q43229",    # organization
            "Q167037",   # corporation
            "Q134161",   # joint-stock company
            "Q163740",   # nonprofit organization
            "Q4830453",  # business enterprise
            # Additional valid types
            "Q1589009",  # private company
            "Q7275",     # state-owned enterprise
            "Q746359",   # holding company
            "Q628125",   # brand name
            "Q22687",    # bank
            "Q178706",   # institution
            "Q18127",    # record label
            "Q6956195",  # consumer electronics brand
            "Q210167",   # video game developer
            "Q2695246",  # fashion house
            "Q5633421",  # group of companies
            "Q219577",   # conglomerate
            "Q3918",     # university (for brand context)
            "Q131734",   # broadcasting company
            "Q1762059",  # film production company
            "Q4139847",  # athletic footwear company
            "Q5",        # human (reject - people are not brands)
            "Q11424",    # film (reject)
            "Q7889",     # video game (reject)
            "Q482994",   # album (reject)
            "Q134556",   # single (reject)
            "Q7302866",  # music track (reject)
        }

        # Types that are explicitly NOT brands (reject these)
        reject_types = {
            # People/names
            "Q5",          # human
            "Q101352",     # family name
            "Q12308941",   # male given name
            "Q11879590",   # female given name
            "Q202444",     # given name
            "Q95074",      # fictional character
            # Media
            "Q11424",      # film
            "Q7889",       # video game
            "Q482994",     # album
            "Q134556",     # single
            "Q7302866",    # music track/recording
            "Q215380",     # band/musical group (edge case)
            "Q15416",      # television program
            "Q7725634",    # literary work
            "Q13442814",   # scholarly article
            "Q3331189",    # version, edition, or translation
            # Biological
            "Q16521",      # taxon (genus, species, etc.)
            "Q89",         # apple (fruit) - explicit reject
            "Q2996394",    # biological process
            # Geographic
            "Q515",        # city
            "Q6256",       # country
            "Q3624078",    # sovereign state
            "Q13100073",   # village in China
            "Q532",        # village
            "Q486972",     # human settlement
            "Q8502",       # mountain
            "Q165",        # sea
            # Wikimedia
            "Q4167410",    # Wikimedia disambiguation page
            "Q13406463",   # Wikimedia list article
        }

        # Check for reject types first
        for type_qid in instance_of:
            if type_qid in reject_types:
                logger.debug(f"Entity {qid} rejected: instance of {type_qid}")
                self._validation_cache[qid] = False
                return False

        # Check for valid company/brand types
        for type_qid in instance_of:
            if type_qid in valid_types:
                self._validation_cache[qid] = True
                return True

        # Fallback: check description for company indicators
        # This catches edge cases not in our type lists
        desc = entity.get("descriptions", {}).get("en", {}).get("value", "").lower()
        company_indicators = [
            "company", "corporation", "brand", "manufacturer",
            "retailer", "enterprise", "inc.", "ltd.", "plc",
            "subsidiary", "conglomerate", "holdings", "group"
        ]

        if any(ind in desc for ind in company_indicators):
            self._validation_cache[qid] = True
            return True

        self._validation_cache[qid] = False
        return False

    async def _get_brand_details(
        self,
        qid: str,
        language: str = "en",
    ) -> Optional[BrandInfo]:
        """Get detailed brand information from Wikidata."""
        # Check cache
        cache_key = f"brand:{qid}"
        if qid in self._parent_cache:
            return self._parent_cache[qid]

        params = {
            "action": "wbgetentities",
            "ids": qid,
            "props": "labels|descriptions|aliases|claims",
            "languages": language,
            "format": "json",
        }

        result = await self._get("", params=params, cache_key=cache_key)

        if not result or "entities" not in result:
            return None

        entity = result["entities"].get(qid)
        if not entity or entity.get("missing"):
            return None

        # Extract basic info
        labels = entity.get("labels", {})
        descriptions = entity.get("descriptions", {})
        aliases_data = entity.get("aliases", {})

        name = labels.get(language, {}).get("value", "")
        description = descriptions.get(language, {}).get("value")
        aliases = [a["value"] for a in aliases_data.get(language, [])]

        # Extract claims
        claims = entity.get("claims", {})

        # P31 - instance of (for brand type)
        instance_of = self._extract_qid_claims(claims.get("P31", []))
        brand_type = self._determine_brand_type(instance_of)

        # P452 - industry
        industry_qids = self._extract_qid_claims(claims.get("P452", []))
        industries = [INDUSTRY_MAPPINGS.get(q, q) for q in industry_qids]

        # P17 - country
        country_qids = self._extract_qid_claims(claims.get("P17", []))
        country = await self._get_label(country_qids[0]) if country_qids else None

        # P159 - headquarters location
        hq_qids = self._extract_qid_claims(claims.get("P159", []))
        headquarters = await self._get_label(hq_qids[0]) if hq_qids else None

        # P856 - official website
        website = self._extract_string_claim(claims.get("P856", []))

        # P571 - inception/founded
        founded = self._extract_time_claim(claims.get("P571", []))

        brand = BrandInfo(
            qid=qid,
            name=name,
            description=description,
            aliases=aliases,
            brand_type=brand_type,
            industries=industries,
            country=country,
            headquarters=headquarters,
            website=website,
            founded=founded,
        )

        # Cache for parent resolution
        self._parent_cache[qid] = brand

        return brand

    async def _resolve_parent_chain(
        self,
        brand: BrandInfo,
        language: str = "en",
        depth: int = 0,
    ) -> None:
        """Resolve the ownership chain for a brand."""
        if depth >= self.max_parent_depth:
            return

        # Get the entity claims for parent info
        params = {
            "action": "wbgetentities",
            "ids": brand.qid,
            "props": "claims",
            "format": "json",
        }

        result = await self._get("", params=params, cache_key=f"claims:{brand.qid}")

        if not result or "entities" not in result:
            return

        entity = result["entities"].get(brand.qid)
        if not entity:
            return

        claims = entity.get("claims", {})

        # P127 - owned by
        owned_by_qids = self._extract_qid_claims(claims.get("P127", []))
        if owned_by_qids:
            owner = await self._get_brand_details(owned_by_qids[0], language)
            if owner:
                brand.owned_by = owner
                await self._resolve_parent_chain(owner, language, depth + 1)

        # P749 - parent organization
        parent_org_qids = self._extract_qid_claims(claims.get("P749", []))
        if parent_org_qids and not brand.owned_by:
            parent = await self._get_brand_details(parent_org_qids[0], language)
            if parent:
                brand.parent_org = parent
                await self._resolve_parent_chain(parent, language, depth + 1)

        # Set ultimate parent
        chain = brand.get_parent_chain()
        if chain:
            brand.ultimate_parent = chain[-1]

    async def _get_label(self, qid: str, language: str = "en") -> Optional[str]:
        """Get the label for a Q-ID."""
        params = {
            "action": "wbgetentities",
            "ids": qid,
            "props": "labels",
            "languages": language,
            "format": "json",
        }

        result = await self._get("", params=params, cache_key=f"label:{qid}")

        if result and "entities" in result:
            entity = result["entities"].get(qid, {})
            labels = entity.get("labels", {})
            return labels.get(language, {}).get("value")

        return None

    async def _sparql_query(self, query: str) -> Optional[Dict[str, Any]]:
        """Execute a SPARQL query against Wikidata."""
        import aiohttp

        headers = {
            "Accept": "application/json",
            "User-Agent": self._get_headers()["User-Agent"],
        }

        async with self.rate_limiter:
            try:
                async with aiohttp.ClientSession() as session:
                    async with session.get(
                        self.SPARQL_URL,
                        params={"query": query},
                        headers=headers,
                        timeout=aiohttp.ClientTimeout(total=self.timeout),
                    ) as response:
                        if response.status == 200:
                            return await response.json()
                        else:
                            logger.warning(f"SPARQL query failed: {response.status}")
                            return None
            except Exception as e:
                logger.error(f"SPARQL query error: {e}")
                return None

    def _extract_qid_claims(self, claims: List[Dict]) -> List[str]:
        """Extract Q-IDs from claim values."""
        qids = []
        for claim in claims:
            mainsnak = claim.get("mainsnak", {})
            datavalue = mainsnak.get("datavalue", {})
            if datavalue.get("type") == "wikibase-entityid":
                value = datavalue.get("value", {})
                if "id" in value:
                    qids.append(value["id"])
        return qids

    def _extract_string_claim(self, claims: List[Dict]) -> Optional[str]:
        """Extract first string value from claims."""
        for claim in claims:
            mainsnak = claim.get("mainsnak", {})
            datavalue = mainsnak.get("datavalue", {})
            if datavalue.get("type") == "string":
                return datavalue.get("value")
        return None

    def _extract_time_claim(self, claims: List[Dict]) -> Optional[str]:
        """Extract time value from claims (year only)."""
        for claim in claims:
            mainsnak = claim.get("mainsnak", {})
            datavalue = mainsnak.get("datavalue", {})
            if datavalue.get("type") == "time":
                time_value = datavalue.get("value", {}).get("time", "")
                # Format: +1976-04-01T00:00:00Z -> 1976
                if time_value:
                    import re
                    match = re.search(r"(\d{4})", time_value)
                    if match:
                        return match.group(1)
        return None

    def _determine_brand_type(self, instance_of_qids: List[str]) -> Optional[str]:
        """Determine brand type from P31 (instance of) values."""
        for qid in instance_of_qids:
            if qid in BRAND_TYPE_QIDS:
                return BRAND_TYPE_QIDS[qid]
        return None

    def _calculate_match_score(
        self,
        query: str,
        result: Dict[str, Any],
    ) -> float:
        """Calculate match score for a search result."""
        label = result.get("label", "").lower()
        query_lower = query.lower()

        # Exact match
        if label == query_lower:
            return 1.0

        # Fuzzy match using title_similarity
        base_score = title_similarity(query, label)

        # Boost if description indicates company/brand
        if not result.get("_low_priority"):
            base_score = min(1.0, base_score + 0.1)

        # Check aliases
        for alias in result.get("aliases", []):
            if alias.lower() == query_lower:
                return max(base_score, 0.9)
            alias_score = title_similarity(query, alias)
            base_score = max(base_score, alias_score * 0.9)

        return base_score


# Convenience functions
async def lookup_brand(brand_name: str, **kwargs) -> BrandLookupResult:
    """Quick lookup for a brand name."""
    client = BrandClient()
    return await client.lookup_brand(brand_name, **kwargs)


async def get_parent_company(brand_name: str) -> Optional[BrandInfo]:
    """Get the ultimate parent company for a brand."""
    result = await lookup_brand(brand_name, resolve_parents=True)
    if result.brand and result.brand.ultimate_parent:
        return result.brand.ultimate_parent
    return result.brand
