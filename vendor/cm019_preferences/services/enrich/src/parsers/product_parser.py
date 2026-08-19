"""
Product Attribute Parser

Extracts structured attributes from product names/descriptions:
- Manufacturing brand (not retailer)
- Size (clothing, shoes, generic)
- Color
- Product category
- Model numbers

Also handles gift detection based on shipping address and recipient.
"""

import re
from dataclasses import dataclass, field
from typing import Optional, List, Dict, Tuple, Set
from enum import Enum
from collections import Counter


def _normalize_letter_size(size_str: str) -> Tuple[str, None]:
    """Normalize letter sizes to standard format."""
    size_map = {
        'extra small': 'XS', 'extrasmall': 'XS', 'x-small': 'XS',
        'small': 'S',
        'medium': 'M', 'med': 'M',
        'large': 'L',
        'extra large': 'XL', 'extralarge': 'XL', 'x-large': 'XL',
    }
    normalized = size_map.get(size_str.lower().strip(), size_str.upper().strip())
    return (normalized, None)


class ProductCategory(Enum):
    """Product categories for preference analysis."""
    MOTORCYCLE_GEAR = "motorcycle_gear"
    ELECTRONICS_HOBBY = "electronics_hobby"
    CABLES_ACCESSORIES = "cables_accessories"
    PHOTOGRAPHY = "photography"
    DEVICE_ACCESSORIES = "device_accessories"
    AUDIO = "audio"
    CLOTHING = "clothing"
    FOOTWEAR = "footwear"
    BOOK = "book"
    GAMING = "gaming"
    KITCHEN = "kitchen"
    OUTDOOR = "outdoor"
    HOME = "home"
    HEALTH = "health"
    TOYS = "toys"
    SPORTS = "sports"
    FASHION = "fashion"
    MUSIC = "music"
    VIDEO = "video"
    SOFTWARE = "software"
    UNKNOWN = "unknown"


@dataclass
class SizeInfo:
    """Parsed size information."""
    raw: str  # Original text matched
    normalized: str  # Normalized size (e.g., "M", "US 9.5", "32W")
    size_type: str  # "clothing", "shoes", "numeric", "dimensions", "helmet", "gloves", "waist", "kids"
    region: Optional[str] = None  # "US", "UK", "EU" for regional sizes


@dataclass
class UserSizeProfile:
    """
    User's known sizes for detecting personal vs gift purchases.

    All fields are optional - only specify what you know.
    Sizes can include ranges (e.g., shoe_size_uk=["8.5", "9"]).
    """
    # Shoe sizes
    shoe_size_uk: List[str] = field(default_factory=list)  # e.g., ["8.5", "9"]
    shoe_size_us: List[str] = field(default_factory=list)  # e.g., ["9", "9.5"]
    shoe_size_eu: List[str] = field(default_factory=list)  # e.g., ["42", "42.5"]

    # Clothing sizes
    tops_size: List[str] = field(default_factory=list)  # e.g., ["M", "L"]
    bottoms_size: List[str] = field(default_factory=list)  # e.g., ["M", "L"]
    waist_inches: List[str] = field(default_factory=list)  # e.g., ["32"]
    inseam_inches: List[str] = field(default_factory=list)  # e.g., ["30", "32"]

    # Accessories
    helmet_size: List[str] = field(default_factory=list)  # e.g., ["M"]
    gloves_size: List[str] = field(default_factory=list)  # e.g., ["M"]

    def matches_size(self, size_info: 'SizeInfo') -> Optional[bool]:
        """
        Check if a size matches the user's profile.

        Returns:
            True: Size matches user's known sizes
            False: Size doesn't match (likely a gift)
            None: Can't determine (size type not in profile)
        """
        if not size_info:
            return None

        size = size_info.normalized.upper()
        size_type = size_info.size_type
        region = size_info.region

        # Shoe sizes
        if size_type == 'shoes':
            if region == 'UK' and self.shoe_size_uk:
                return any(s in size for s in self.shoe_size_uk)
            elif region == 'US' and self.shoe_size_us:
                return any(s in size for s in self.shoe_size_us)
            elif region == 'EU' and self.shoe_size_eu:
                return any(s in size for s in self.shoe_size_eu)
            # Try to match any shoe size
            all_sizes = self.shoe_size_uk + self.shoe_size_us + self.shoe_size_eu
            if all_sizes:
                return any(s in size for s in all_sizes)

        # Clothing sizes
        if size_type == 'clothing':
            all_clothing = self.tops_size + self.bottoms_size
            if all_clothing:
                return size in [s.upper() for s in all_clothing]

        # Waist
        if size_type in ['waist', 'waist_inseam']:
            if self.waist_inches:
                # Extract numeric part
                waist_match = re.search(r'(\d{2})', size)
                if waist_match:
                    return waist_match.group(1) in self.waist_inches

        # Helmet
        if size_type == 'helmet' and self.helmet_size:
            return size in [s.upper() for s in self.helmet_size]

        # Gloves
        if size_type == 'gloves' and self.gloves_size:
            return size in [s.upper() for s in self.gloves_size]

        # Kids sizes never match adult user
        if size_type == 'kids':
            return False

        return None

    @classmethod
    def infer_from_sizes(cls, sizes: List['SizeInfo']) -> 'UserSizeProfile':
        """
        Infer a user's size profile from a list of extracted sizes.
        Uses mode (most common) for each category, filtering outliers.
        """
        profile = cls()

        # Group by type
        by_type: Dict[str, Counter] = {
            'shoes_uk': Counter(),
            'shoes_us': Counter(),
            'shoes_eu': Counter(),
            'clothing': Counter(),
            'waist': Counter(),
            'helmet': Counter(),
            'gloves': Counter(),
        }

        for size in sizes:
            if size.size_type == 'shoes':
                if size.region == 'UK':
                    by_type['shoes_uk'][size.normalized] += 1
                elif size.region == 'US':
                    by_type['shoes_us'][size.normalized] += 1
                elif size.region == 'EU':
                    by_type['shoes_eu'][size.normalized] += 1
            elif size.size_type == 'clothing':
                by_type['clothing'][size.normalized] += 1
            elif size.size_type in ['waist', 'waist_inseam']:
                by_type['waist'][size.normalized] += 1
            elif size.size_type == 'helmet':
                by_type['helmet'][size.normalized] += 1
            elif size.size_type == 'gloves':
                by_type['gloves'][size.normalized] += 1

        # Take top 2 most common for each (allows for slight variation)
        def top_sizes(counter: Counter, n: int = 2) -> List[str]:
            return [size for size, _ in counter.most_common(n) if counter[size] >= 1]

        if by_type['shoes_uk']:
            profile.shoe_size_uk = top_sizes(by_type['shoes_uk'])
        if by_type['shoes_us']:
            profile.shoe_size_us = top_sizes(by_type['shoes_us'])
        if by_type['shoes_eu']:
            profile.shoe_size_eu = top_sizes(by_type['shoes_eu'])
        if by_type['clothing']:
            profile.tops_size = top_sizes(by_type['clothing'])
        if by_type['waist']:
            profile.waist_inches = top_sizes(by_type['waist'])
        if by_type['helmet']:
            profile.helmet_size = top_sizes(by_type['helmet'])
        if by_type['gloves']:
            profile.gloves_size = top_sizes(by_type['gloves'])

        return profile


@dataclass
class ProductAttributes:
    """Extracted product attributes."""
    original_text: str

    # Manufacturing brand (the maker, not retailer)
    brand: Optional[str] = None
    brand_confidence: float = 0.0

    # Size information
    size: Optional[SizeInfo] = None

    # Color
    color: Optional[str] = None

    # Product category
    category: Optional[ProductCategory] = None
    category_confidence: float = 0.0

    # Model/SKU
    model_number: Optional[str] = None

    # Quantity indicators
    quantity: int = 1
    is_multipack: bool = False

    # Dimensions/measurements
    dimensions: Optional[str] = None

    # Gift detection
    is_likely_gift: bool = False
    gift_indicators: List[str] = field(default_factory=list)

    # Cleaned product name (without size/color/brand prefixes)
    clean_name: Optional[str] = None

    def to_dict(self) -> Dict:
        """Convert to dictionary for storage in extra field."""
        return {
            'brand': self.brand,
            'brand_confidence': self.brand_confidence,
            'size': self.size.normalized if self.size else None,
            'size_type': self.size.size_type if self.size else None,
            'size_region': self.size.region if self.size else None,
            'color': self.color,
            'category': self.category.value if self.category else None,
            'category_confidence': self.category_confidence,
            'model_number': self.model_number,
            'quantity': self.quantity,
            'is_multipack': self.is_multipack,
            'dimensions': self.dimensions,
            'is_likely_gift': self.is_likely_gift,
            'gift_indicators': self.gift_indicators,
            'clean_name': self.clean_name,
        }


class ProductParser:
    """
    Parse product names to extract structured attributes.

    Usage:
        parser = ProductParser()
        attrs = parser.parse("New Balance Mens 574 Sport Black Sneaker - 9.5")
        print(attrs.brand)  # "New Balance"
        print(attrs.size.normalized)  # "US 9.5"
        print(attrs.color)  # "black"
        print(attrs.category)  # ProductCategory.FOOTWEAR
    """

    def __init__(self, user_config: Optional['UserConfig'] = None):
        """
        Initialize parser.

        Args:
            user_config: Optional user configuration for gift detection
        """
        self.user_config = user_config
        self._compile_patterns()
        self._build_brand_database()
        self._build_category_patterns()

    def _compile_patterns(self):
        """Compile regex patterns for extraction."""

        # Exclusion patterns - products that should NOT have sizes extracted
        # Vinyl records often have "UK 12" or "7"" which are NOT shoe sizes
        self.size_exclusion_patterns = [
            re.compile(r'\bvinyl\b', re.I),
            re.compile(r'\b(?:12|7|10)["\u2033\u201d\'](?:\s|$)', re.I),  # 12", 7", 10" records
            re.compile(r'\brecord\b.*\b(?:UK|US)\s*\d', re.I),  # "record" near regional sizes
            re.compile(r'\bLP\b', re.I),  # LP records
            re.compile(r'\bsingle\s+(?:45|rpm)\b', re.I),  # 45 rpm singles
        ]

        # Size patterns - ordered by specificity
        # IMPORTANT: These are designed to minimize false positives by requiring context
        self.size_patterns = [
            # Regional shoe sizes - REQUIRE footwear context to avoid vinyl false positives
            # "UK 8.5" or "US 9" - only match near footwear keywords
            (re.compile(r'\b(?:shoe|boot|trainer|sneaker|footwear|rift|sandal|slipper|loafer).*?\b(US|UK|EU)\s*(\d{1,2}(?:\.\d{1,2})?)\b', re.I), 'shoes', lambda m: (f"{m.group(1).upper()} {m.group(2)}", m.group(1).upper())),
            (re.compile(r'\b(US|UK|EU)\s*(\d{1,2}(?:\.\d{1,2})?)\b.*?\b(?:shoe|boot|trainer|sneaker|footwear|rift|sandal|slipper|loafer)', re.I), 'shoes', lambda m: (f"{m.group(1).upper()} {m.group(2)}", m.group(1).upper())),
            # "Size X UK/US/EU" pattern with footwear context
            (re.compile(r'\b(?:shoe|boot|trainer|sneaker).*?\bSize\s*(\d{1,2}(?:\.\d)?)\s*(UK|US|EU)?\b', re.I), 'shoes', lambda m: (f"{m.group(2).upper() + ' ' if m.group(2) else ''}{m.group(1)}", m.group(2).upper() if m.group(2) else None)),
            # Shoe size at end with comma: ", 8.5 UK" or ", 10.5" - only with footwear context
            (re.compile(r'\b(?:shoe|boot|trainer|sneaker|footwear).*,\s*(\d{1,2}(?:\.\d)?)\s*(UK|US|EU)?\s*$', re.I), 'shoes', lambda m: (f"{m.group(2).upper() + ' ' if m.group(2) else ''}{m.group(1)}", m.group(2).upper() if m.group(2) else None)),

            # Waist/inseam - REQUIRE clothing context to avoid matching display dimensions
            # Pattern: "32W x 30L" or "32W" - but only near clothing keywords
            (re.compile(r'\b(?:jeans|pants|trousers|chinos|shorts|denim).*?(\d{2})\s*[Ww](?:\s*x\s*(\d{2})[Ll]?)?\b', re.I), 'waist', lambda m: (f"{m.group(1)}W" + (f"x{m.group(2)}L" if m.group(2) else ""), None)),
            (re.compile(r'\b(\d{2})\s*[Ww]\s*x\s*(\d{2})\s*[Ll]?\b.*?(?:jeans|pants|trousers|chinos|shorts|denim)', re.I), 'waist', lambda m: (f"{m.group(1)}Wx{m.group(2)}L", None)),
            # Explicit waist/inseam keywords
            (re.compile(r'\b(?:waist|inseam)[:\s]+(\d{2})(?:["\']|\s*(?:inch|in))?\b', re.I), 'waist', lambda m: (f"{m.group(1)}\"", None)),
            (re.compile(r'\b(\d{2})["\']?\s*(?:waist|inseam)\b', re.I), 'waist', lambda m: (f"{m.group(1)}\"", None)),
            # Jeans size format at end: ", 32x30" or ", 32/30"
            (re.compile(r'(?:jeans|pants|trousers|denim).*,\s*(\d{2})\s*[x/]\s*(\d{2})\s*$', re.I), 'waist', lambda m: (f"{m.group(1)}x{m.group(2)}", None)),
            # Standalone waist x inseam format: "32x30" or "32 x 30" (with denim context earlier in title)
            (re.compile(r'\b(\d{2})\s*x\s*(\d{2})\b', re.I), 'waist', lambda m: (f"{m.group(1)}x{m.group(2)}", None)),

            # === CONTEXT-SPECIFIC SIZES (must come BEFORE generic clothing) ===

            # Helmet sizes - requires "helmet" keyword
            (re.compile(r'\bhelmet[^)]*\(([XS]{1,3}|M|[XL]{1,3}|2XL|3XL|Medium|Small|Large)\)', re.I), 'helmet', lambda m: _normalize_letter_size(m.group(1))),
            (re.compile(r'\(([XS]{1,3}|M|[XL]{1,3}|2XL|3XL)\)\s*.*\bhelmet', re.I), 'helmet', lambda m: (m.group(1).upper(), None)),
            (re.compile(r'\bhelmet\b.*[,\s-]+\s*(XXS|XS|S|M|L|XL|XXL)\s*$', re.I), 'helmet', lambda m: (m.group(1).upper(), None)),
            (re.compile(r'\bhelmet\b.*\b(medium|small|large|x-?large|x-?small)\b', re.I), 'helmet', lambda m: _normalize_letter_size(m.group(1))),

            # Glove sizes - requires "glove(s)" keyword (STRICT to avoid "Strand" -> "S")
            (re.compile(r'\bgloves?\s+Size\s+(XXS|XS|S|M|L|XL|XXL)\b', re.I), 'gloves', lambda m: (m.group(1).upper(), None)),
            (re.compile(r'\bgloves?[,\s-]+\s*(XXS|XS|S|M|L|XL|XXL)\s*$', re.I), 'gloves', lambda m: (m.group(1).upper(), None)),
            (re.compile(r'\bgloves?\s*\(([XS]{1,3}|M|[XL]{1,3}|2XL|3XL)\)', re.I), 'gloves', lambda m: (m.group(1).upper(), None)),
            (re.compile(r'\b(XXS|XS|S|M|L|XL|XXL)\s+gloves?\b', re.I), 'gloves', lambda m: (m.group(1).upper(), None)),
            (re.compile(r'\bgloves?\b.*\bSize\s+(medium|small|large)\b', re.I), 'gloves', lambda m: _normalize_letter_size(m.group(1))),

            # === GENERIC LETTER SIZES (must come AFTER context-specific patterns) ===

            # Parenthetical sizes: "(M)", "(Large)", "(XL)" - very reliable but generic
            (re.compile(r'\(([XS]{1,3}|M|[XL]{1,3}|2XL|3XL|4XL)\)', re.I), 'clothing', lambda m: (m.group(1).upper(), None)),
            # Size after comma at end: ", Medium", ", L", ", XL"
            (re.compile(r',\s*(X{0,2}S|M|X{0,2}L|XXL|2XL|3XL|Medium|Small|Large)\s*(?:Regular|Long|Short)?\s*$', re.I), 'clothing', lambda m: _normalize_letter_size(m.group(1))),
            # Size after hyphen: "- M", "- Large"
            (re.compile(r'\s-\s*(X{0,2}S|M|X{0,2}L|XXL|2XL|3XL|Medium|Small|Large)\s*(?:[,\s]|$)', re.I), 'clothing', lambda m: _normalize_letter_size(m.group(1))),
            # "Size: M" or "Size M" patterns
            (re.compile(r'\bsize[:\s]+(X{0,2}S|M|X{0,2}L|XXL|2XL|3XL|Medium|Small|Large)\b', re.I), 'clothing', lambda m: _normalize_letter_size(m.group(1))),
            # Written sizes with word boundaries and context
            (re.compile(r'\b(extra\s*small|small|medium|large|extra\s*large)\s+(?:regular|long|short|fit|size)\b', re.I), 'clothing', lambda m: _normalize_letter_size(m.group(1))),

            # Age-based kids sizes: "7/9yrs", "Age 5-6" - these indicate gifts
            (re.compile(r'\b(\d{1,2})\s*/\s*(\d{1,2})\s*(?:yrs?|years?)\b', re.I), 'kids', lambda m: (f"Age {m.group(1)}-{m.group(2)}", None)),
            (re.compile(r'\bage\s*(\d{1,2})(?:\s*-\s*(\d{1,2}))?\b', re.I), 'kids', lambda m: (f"Age {m.group(1)}" + (f"-{m.group(2)}" if m.group(2) else ""), None)),

            # Trailing numeric size ONLY after "Size" keyword: "Size 42"
            (re.compile(r'\bsize\s+(\d{1,2}(?:\.\d)?)\b', re.I), 'numeric', lambda m: (m.group(1), None)),
        ]

        # Color patterns
        self.colors = [
            'black', 'white', 'blue', 'red', 'green', 'grey', 'gray', 'navy',
            'beige', 'brown', 'pink', 'purple', 'orange', 'yellow', 'silver',
            'gold', 'khaki', 'olive', 'burgundy', 'maroon', 'cream', 'tan',
            'charcoal', 'coral', 'teal', 'turquoise', 'violet', 'indigo',
            'matte black', 'flat black', 'gloss black', 'carbon', 'chrome',
            'rose gold', 'space gray', 'midnight', 'graphite', 'titanium',
            'anthracite', 'fuchsia', 'magenta', 'cyan', 'amber',
        ]
        self.color_pattern = re.compile(
            r'\b(' + '|'.join(re.escape(c) for c in self.colors) + r')\b',
            re.I
        )

        # Model number patterns
        self.model_patterns = [
            re.compile(r'\b([A-Z]{2,4}[-]?\d{3,}[A-Z]?)\b'),  # AB-1234, ABC123
            re.compile(r'\b([A-Z]\d{2,}[A-Z]{1,2})\b'),  # A123BC
            re.compile(r'\bmodel\s*#?\s*([A-Z0-9-]+)\b', re.I),  # Model: XYZ123
            re.compile(r'\b(B[0-9A-Z]{9})\b'),  # ASIN format
        ]

        # Quantity patterns
        self.qty_patterns = [
            (re.compile(r'\b(\d+)\s*(?:x|×)\s*', re.I), lambda m: int(m.group(1))),
            (re.compile(r'\bpack\s*(?:of\s*)?(\d+)\b', re.I), lambda m: int(m.group(1))),
            (re.compile(r'\b(\d+)\s*(?:pack|piece|pcs?|count|ct)\b', re.I), lambda m: int(m.group(1))),
            (re.compile(r'\bset\s*(?:of\s*)?(\d+)\b', re.I), lambda m: int(m.group(1))),
        ]

        # Dimension patterns
        self.dimension_patterns = [
            re.compile(r'\b(\d+(?:\.\d+)?)\s*(ml|oz|fl\.?\s*oz|g|kg|lb|lbs?|mm|cm|m|inch|in|"|\'|ft)\b', re.I),
            re.compile(r'\b(\d+(?:\.\d+)?)\s*x\s*(\d+(?:\.\d+)?)\s*(mm|cm|m|inch|in|")\b', re.I),
        ]

        # Gift indicator patterns
        self.gift_patterns = [
            re.compile(r'\bgift\b', re.I),
            re.compile(r'\bfor\s+(kids?|children|baby|toddler|boy|girl|him|her|dad|mom|mum)\b', re.I),
            re.compile(r'\b(kids?|children\'?s?|baby|toddler)\b', re.I),
            re.compile(r'\b(birthday|christmas|xmas|easter|valentine)\b', re.I),
        ]

    def _build_brand_database(self):
        """Build brand recognition database with categories."""

        # Format: (pattern, brand_name, typical_categories)
        self.brands = [
            # Sportswear/Athletic
            (re.compile(r'\bNike\b', re.I), 'Nike', [ProductCategory.FOOTWEAR, ProductCategory.CLOTHING, ProductCategory.SPORTS]),
            (re.compile(r'\bAdidas\b', re.I), 'Adidas', [ProductCategory.FOOTWEAR, ProductCategory.CLOTHING, ProductCategory.SPORTS]),
            (re.compile(r'\bNew Balance\b', re.I), 'New Balance', [ProductCategory.FOOTWEAR, ProductCategory.CLOTHING]),
            (re.compile(r'\bPuma\b', re.I), 'Puma', [ProductCategory.FOOTWEAR, ProductCategory.CLOTHING]),
            (re.compile(r'\bReebok\b', re.I), 'Reebok', [ProductCategory.FOOTWEAR, ProductCategory.CLOTHING]),
            (re.compile(r'\bUnder Armour\b', re.I), 'Under Armour', [ProductCategory.CLOTHING, ProductCategory.SPORTS]),
            (re.compile(r'\bLululemon\b', re.I), 'Lululemon', [ProductCategory.CLOTHING]),
            (re.compile(r'\bCanterbury\b', re.I), 'Canterbury', [ProductCategory.SPORTS, ProductCategory.CLOTHING]),

            # Outdoor/Technical
            (re.compile(r'\bNorth Face\b', re.I), 'The North Face', [ProductCategory.CLOTHING, ProductCategory.OUTDOOR]),
            (re.compile(r'\bPatagonia\b', re.I), 'Patagonia', [ProductCategory.CLOTHING, ProductCategory.OUTDOOR]),
            (re.compile(r'\bColumbia\b', re.I), 'Columbia', [ProductCategory.CLOTHING, ProductCategory.OUTDOOR]),
            (re.compile(r"\bArc'?teryx\b", re.I), "Arc'teryx", [ProductCategory.CLOTHING, ProductCategory.OUTDOOR]),
            (re.compile(r'\bVollebak\b', re.I), 'Vollebak', [ProductCategory.CLOTHING]),
            (re.compile(r'\b686\b'), '686', [ProductCategory.CLOTHING, ProductCategory.OUTDOOR]),

            # Fashion/Streetwear
            (re.compile(r'\bG-Star\b', re.I), 'G-Star RAW', [ProductCategory.CLOTHING]),
            (re.compile(r'\bOff-White\b', re.I), 'Off-White', [ProductCategory.CLOTHING, ProductCategory.FASHION]),
            (re.compile(r"\bLevi'?s\b", re.I), "Levi's", [ProductCategory.CLOTHING]),
            (re.compile(r'\bGap\b'), 'Gap', [ProductCategory.CLOTHING]),
            (re.compile(r'\bH&M\b', re.I), 'H&M', [ProductCategory.CLOTHING]),
            (re.compile(r'\bZara\b', re.I), 'Zara', [ProductCategory.CLOTHING]),
            (re.compile(r'\bUniqlo\b', re.I), 'Uniqlo', [ProductCategory.CLOTHING]),
            (re.compile(r'\bTru-Spec\b', re.I), 'Tru-Spec', [ProductCategory.CLOTHING]),

            # Motorcycle Gear
            (re.compile(r'\bNEXX\b'), 'NEXX', [ProductCategory.MOTORCYCLE_GEAR]),
            (re.compile(r'\bSena\b', re.I), 'Sena', [ProductCategory.MOTORCYCLE_GEAR, ProductCategory.AUDIO]),
            (re.compile(r'\bAlpinestars\b', re.I), 'Alpinestars', [ProductCategory.MOTORCYCLE_GEAR]),
            (re.compile(r'\bDainese\b', re.I), 'Dainese', [ProductCategory.MOTORCYCLE_GEAR]),
            (re.compile(r"\bREV'?IT\b", re.I), "REV'IT", [ProductCategory.MOTORCYCLE_GEAR]),
            (re.compile(r'\bBiltwell\b', re.I), 'Biltwell', [ProductCategory.MOTORCYCLE_GEAR]),
            (re.compile(r'\bShoei\b', re.I), 'Shoei', [ProductCategory.MOTORCYCLE_GEAR]),
            (re.compile(r'\bArai\b', re.I), 'Arai', [ProductCategory.MOTORCYCLE_GEAR]),
            (re.compile(r'\bBell\b(?!\s+(?:pepper|curve))', re.I), 'Bell', [ProductCategory.MOTORCYCLE_GEAR]),
            (re.compile(r'\bForcefield\b', re.I), 'Forcefield', [ProductCategory.MOTORCYCLE_GEAR]),
            (re.compile(r'\bKnox\b', re.I), 'Knox', [ProductCategory.MOTORCYCLE_GEAR]),

            # Electronics - Consumer
            (re.compile(r'\bApple\b(?!\s+(?:juice|cider|pie|tree|watch))', re.I), 'Apple', [ProductCategory.ELECTRONICS_HOBBY, ProductCategory.AUDIO]),
            (re.compile(r'\bSamsung\b', re.I), 'Samsung', [ProductCategory.ELECTRONICS_HOBBY]),
            (re.compile(r'\bSony\b', re.I), 'Sony', [ProductCategory.ELECTRONICS_HOBBY, ProductCategory.AUDIO, ProductCategory.PHOTOGRAPHY]),
            (re.compile(r'\bLG\b(?=\s+[A-Z0-9])'), 'LG', [ProductCategory.ELECTRONICS_HOBBY]),  # Must be followed by model number
            (re.compile(r'\bPhilips\b', re.I), 'Philips', [ProductCategory.ELECTRONICS_HOBBY, ProductCategory.HOME]),
            (re.compile(r'\bPanasonic\b', re.I), 'Panasonic', [ProductCategory.ELECTRONICS_HOBBY]),

            # Electronics - Hobby/Maker
            (re.compile(r'\bRaspberry Pi\b', re.I), 'Raspberry Pi', [ProductCategory.ELECTRONICS_HOBBY]),
            (re.compile(r'\bArduino\b', re.I), 'Arduino', [ProductCategory.ELECTRONICS_HOBBY]),
            (re.compile(r'\bAdafruit\b', re.I), 'Adafruit', [ProductCategory.ELECTRONICS_HOBBY]),
            (re.compile(r'\bSparkFun\b', re.I), 'SparkFun', [ProductCategory.ELECTRONICS_HOBBY]),
            (re.compile(r'\bSeeed\b', re.I), 'Seeed Studio', [ProductCategory.ELECTRONICS_HOBBY]),
            (re.compile(r'\bBlackmagic\b', re.I), 'Blackmagic Design', [ProductCategory.PHOTOGRAPHY, ProductCategory.VIDEO]),

            # Audio
            (re.compile(r'\bBose\b', re.I), 'Bose', [ProductCategory.AUDIO]),
            (re.compile(r'\bJBL\b'), 'JBL', [ProductCategory.AUDIO]),
            (re.compile(r'\bSennheiser\b', re.I), 'Sennheiser', [ProductCategory.AUDIO]),
            (re.compile(r'\bAudio-Technica\b', re.I), 'Audio-Technica', [ProductCategory.AUDIO]),
            (re.compile(r'\bBeats\b', re.I), 'Beats', [ProductCategory.AUDIO]),
            (re.compile(r'\bBang & Olufsen\b', re.I), 'Bang & Olufsen', [ProductCategory.AUDIO]),
            (re.compile(r'\bB&O\b'), 'Bang & Olufsen', [ProductCategory.AUDIO]),

            # Photography
            (re.compile(r'\bCanon\b', re.I), 'Canon', [ProductCategory.PHOTOGRAPHY]),
            (re.compile(r'\bNikon\b', re.I), 'Nikon', [ProductCategory.PHOTOGRAPHY]),
            (re.compile(r'\bGoPro\b', re.I), 'GoPro', [ProductCategory.PHOTOGRAPHY, ProductCategory.VIDEO]),
            (re.compile(r'\bDJI\b'), 'DJI', [ProductCategory.PHOTOGRAPHY, ProductCategory.ELECTRONICS_HOBBY]),
            (re.compile(r'\bFujifilm\b', re.I), 'Fujifilm', [ProductCategory.PHOTOGRAPHY]),
            (re.compile(r'\bLeica\b', re.I), 'Leica', [ProductCategory.PHOTOGRAPHY]),

            # Computer/Peripherals
            (re.compile(r'\bLogitech\b', re.I), 'Logitech', [ProductCategory.ELECTRONICS_HOBBY]),
            (re.compile(r'\bMicrosoft\b', re.I), 'Microsoft', [ProductCategory.ELECTRONICS_HOBBY, ProductCategory.SOFTWARE]),
            (re.compile(r'\bDell\b', re.I), 'Dell', [ProductCategory.ELECTRONICS_HOBBY]),
            (re.compile(r'\bHP\b(?=\s+[A-Z])'), 'HP', [ProductCategory.ELECTRONICS_HOBBY]),  # Must be followed by model
            (re.compile(r'\bLenovo\b', re.I), 'Lenovo', [ProductCategory.ELECTRONICS_HOBBY]),
            (re.compile(r'\bASUS\b'), 'ASUS', [ProductCategory.ELECTRONICS_HOBBY]),
            (re.compile(r'\bAnker\b', re.I), 'Anker', [ProductCategory.CABLES_ACCESSORIES]),
            (re.compile(r'\bBelkin\b', re.I), 'Belkin', [ProductCategory.CABLES_ACCESSORIES]),

            # Home/Kitchen
            (re.compile(r'\bIKEA\b', re.I), 'IKEA', [ProductCategory.HOME]),
            (re.compile(r'\bDyson\b', re.I), 'Dyson', [ProductCategory.HOME]),
            (re.compile(r'\bNespresso\b', re.I), 'Nespresso', [ProductCategory.KITCHEN]),
            (re.compile(r'\bSodaStream\b', re.I), 'SodaStream', [ProductCategory.KITCHEN]),
            (re.compile(r'\bKitchenAid\b', re.I), 'KitchenAid', [ProductCategory.KITCHEN]),
            (re.compile(r'\bBreville\b', re.I), 'Breville', [ProductCategory.KITCHEN]),
            (re.compile(r'\bInstant Pot\b', re.I), 'Instant Pot', [ProductCategory.KITCHEN]),
            (re.compile(r'\bWeber\b', re.I), 'Weber', [ProductCategory.OUTDOOR, ProductCategory.KITCHEN]),

            # Bags/Accessories
            (re.compile(r'\bBellroy\b', re.I), 'Bellroy', [ProductCategory.FASHION]),
            (re.compile(r'\bTumi\b', re.I), 'Tumi', [ProductCategory.FASHION]),
            (re.compile(r'\bPeak Design\b', re.I), 'Peak Design', [ProductCategory.PHOTOGRAPHY, ProductCategory.FASHION]),
        ]

    def _build_category_patterns(self):
        """Build product category detection patterns."""

        self.category_patterns = [
            # Motorcycle gear - high confidence
            (re.compile(r'\b(motorcycle|motorbike|moto|biker)\b', re.I), ProductCategory.MOTORCYCLE_GEAR, 0.9),
            (re.compile(r'\b(helmet|visor|armor|armour)\b', re.I), ProductCategory.MOTORCYCLE_GEAR, 0.8),
            (re.compile(r'\b(riding\s+)?(jacket|pants|gloves|boots)\b', re.I), ProductCategory.MOTORCYCLE_GEAR, 0.6),

            # Electronics hobby
            (re.compile(r'\b(raspberry|arduino|sensor|GPIO|breadboard|PCB|microcontroller)\b', re.I), ProductCategory.ELECTRONICS_HOBBY, 0.9),
            (re.compile(r'\b(LED|capacitor|resistor|transistor|diode|relay)\b', re.I), ProductCategory.ELECTRONICS_HOBBY, 0.8),
            (re.compile(r'\b(soldering|multimeter|oscilloscope)\b', re.I), ProductCategory.ELECTRONICS_HOBBY, 0.85),

            # Cables/accessories
            (re.compile(r'\b(USB|HDMI|DisplayPort|Thunderbolt)\s*(cable|adapter|hub|dock)\b', re.I), ProductCategory.CABLES_ACCESSORIES, 0.9),
            (re.compile(r'\b(charger|charging\s+cable|power\s+adapter)\b', re.I), ProductCategory.CABLES_ACCESSORIES, 0.85),

            # Photography
            (re.compile(r'\b(camera|DSLR|mirrorless|lens|tripod|flash|strobe)\b', re.I), ProductCategory.PHOTOGRAPHY, 0.85),
            (re.compile(r'\b(photography|photographer|photo\s+editing)\b', re.I), ProductCategory.PHOTOGRAPHY, 0.7),

            # Audio
            (re.compile(r'\b(headphone|earphone|earbud|speaker|amplifier|DAC)\b', re.I), ProductCategory.AUDIO, 0.85),
            (re.compile(r'\b(audio|sound|hi-fi|hifi|stereo)\b', re.I), ProductCategory.AUDIO, 0.6),

            # Footwear
            (re.compile(r'\b(shoe|sneaker|trainer|boot|sandal|slipper|loafer)\b', re.I), ProductCategory.FOOTWEAR, 0.9),

            # Clothing
            (re.compile(r'\b(shirt|t-shirt|tee|polo|jacket|coat|pants|jeans|shorts|hoodie|sweater|cardigan|dress)\b', re.I), ProductCategory.CLOTHING, 0.85),
            (re.compile(r'\b(men\'?s|women\'?s|unisex)\s+(clothing|apparel|wear)\b', re.I), ProductCategory.CLOTHING, 0.8),

            # Device accessories
            (re.compile(r'\b(case|cover|screen\s+protector|sleeve|skin)\b', re.I), ProductCategory.DEVICE_ACCESSORIES, 0.75),
            (re.compile(r'\bfor\s+(iPhone|iPad|MacBook|Galaxy|Pixel)\b', re.I), ProductCategory.DEVICE_ACCESSORIES, 0.8),

            # Kitchen
            (re.compile(r'\b(kitchen|cooking|baking|pan|pot|knife|blender|mixer)\b', re.I), ProductCategory.KITCHEN, 0.8),
            (re.compile(r'\b(coffee|espresso|tea|kettle)\b', re.I), ProductCategory.KITCHEN, 0.7),

            # Outdoor
            (re.compile(r'\b(outdoor|camping|hiking|tent|sleeping\s+bag|backpack)\b', re.I), ProductCategory.OUTDOOR, 0.85),
            (re.compile(r'\b(BBQ|grill|barbecue)\b', re.I), ProductCategory.OUTDOOR, 0.8),

            # Books
            (re.compile(r'\b(book|paperback|hardcover|hardback|ebook)\b', re.I), ProductCategory.BOOK, 0.9),
            (re.compile(r'\b(novel|biography|memoir|cookbook)\b', re.I), ProductCategory.BOOK, 0.85),

            # Gaming
            (re.compile(r'\b(game|gaming|controller|gamepad|joystick|console)\b', re.I), ProductCategory.GAMING, 0.85),
            (re.compile(r'\b(PlayStation|Xbox|Nintendo|Steam)\b', re.I), ProductCategory.GAMING, 0.9),

            # Home
            (re.compile(r'\b(furniture|lamp|shelf|desk|chair|bed|mattress|pillow)\b', re.I), ProductCategory.HOME, 0.85),
            (re.compile(r'\b(home|house|room|decor|decoration)\b', re.I), ProductCategory.HOME, 0.5),

            # Health
            (re.compile(r'\b(health|medical|vitamin|supplement|fitness|wellness)\b', re.I), ProductCategory.HEALTH, 0.7),
            (re.compile(r'\b(toothbrush|shampoo|skincare|sunscreen)\b', re.I), ProductCategory.HEALTH, 0.75),

            # Toys
            (re.compile(r'\b(toy|toys|lego|playset|action\s+figure|doll)\b', re.I), ProductCategory.TOYS, 0.9),
            (re.compile(r'\b(kids?|children\'?s?|child)\b', re.I), ProductCategory.TOYS, 0.5),

            # Sports
            (re.compile(r'\b(sport|sports|athletic|fitness|gym|workout)\b', re.I), ProductCategory.SPORTS, 0.7),
            (re.compile(r'\b(rugby|football|soccer|basketball|tennis|golf|cycling)\b', re.I), ProductCategory.SPORTS, 0.85),
        ]

    def parse(self, text: str) -> ProductAttributes:
        """
        Parse product name/description to extract attributes.

        Args:
            text: Product name or description

        Returns:
            ProductAttributes with extracted information
        """
        attrs = ProductAttributes(original_text=text)

        # Extract brand
        brand_result = self._extract_brand(text)
        if brand_result:
            attrs.brand, attrs.brand_confidence, brand_categories = brand_result
            # Use brand's typical categories as hints
            if brand_categories and not attrs.category:
                attrs.category = brand_categories[0]
                attrs.category_confidence = 0.6  # Lower confidence for brand-inferred category

        # Extract category (may override brand-inferred)
        cat_result = self._extract_category(text)
        if cat_result:
            cat, conf = cat_result
            if conf > attrs.category_confidence:
                attrs.category = cat
                attrs.category_confidence = conf

        # Extract size
        attrs.size = self._extract_size(text)

        # Extract color
        attrs.color = self._extract_color(text)

        # Extract model number
        attrs.model_number = self._extract_model(text)

        # Extract quantity
        qty_result = self._extract_quantity(text)
        if qty_result:
            attrs.quantity, attrs.is_multipack = qty_result

        # Extract dimensions
        attrs.dimensions = self._extract_dimensions(text)

        # Check gift indicators
        attrs.is_likely_gift, attrs.gift_indicators = self._check_gift_indicators(text)

        # Generate clean name
        attrs.clean_name = self._clean_product_name(text, attrs)

        return attrs

    def _extract_brand(self, text: str) -> Optional[Tuple[str, float, List[ProductCategory]]]:
        """Extract manufacturing brand from text."""
        for pattern, brand_name, categories in self.brands:
            if pattern.search(text):
                return (brand_name, 0.95, categories)
        return None

    def _extract_category(self, text: str) -> Optional[Tuple[ProductCategory, float]]:
        """Extract product category from text."""
        best_match = None
        best_confidence = 0.0

        for pattern, category, confidence in self.category_patterns:
            if pattern.search(text):
                if confidence > best_confidence:
                    best_match = category
                    best_confidence = confidence

        return (best_match, best_confidence) if best_match else None

    def _extract_size(self, text: str) -> Optional[SizeInfo]:
        """Extract size information from text.

        Includes exclusion patterns to avoid false positives like:
        - Vinyl records with "UK 12" being matched as shoe sizes
        - "Strand/Short" being matched as glove size "S"
        """
        # Check exclusion patterns first - skip size extraction entirely for these
        for exclusion_pattern in self.size_exclusion_patterns:
            if exclusion_pattern.search(text):
                return None

        for pattern, size_type, extractor in self.size_patterns:
            match = pattern.search(text)
            if match:
                normalized, region = extractor(match)
                return SizeInfo(
                    raw=match.group(0),
                    normalized=normalized,
                    size_type=size_type,
                    region=region
                )
        return None

    def _extract_color(self, text: str) -> Optional[str]:
        """Extract color from text."""
        match = self.color_pattern.search(text)
        if match:
            color = match.group(1).lower()
            # Normalize some colors
            color = color.replace('grey', 'gray')
            return color
        return None

    def _extract_model(self, text: str) -> Optional[str]:
        """Extract model number from text."""
        for pattern in self.model_patterns:
            match = pattern.search(text)
            if match:
                return match.group(1)
        return None

    def _extract_quantity(self, text: str) -> Optional[Tuple[int, bool]]:
        """Extract quantity from text."""
        for pattern, extractor in self.qty_patterns:
            match = pattern.search(text)
            if match:
                qty = extractor(match)
                return (qty, qty > 1)
        return None

    def _extract_dimensions(self, text: str) -> Optional[str]:
        """Extract dimensions from text."""
        for pattern in self.dimension_patterns:
            match = pattern.search(text)
            if match:
                return match.group(0)
        return None

    def _check_gift_indicators(self, text: str) -> Tuple[bool, List[str]]:
        """Check for gift indicators in text."""
        indicators = []
        for pattern in self.gift_patterns:
            match = pattern.search(text)
            if match:
                indicators.append(match.group(0))
        return (len(indicators) > 0, indicators)

    def _clean_product_name(self, text: str, attrs: ProductAttributes) -> str:
        """Generate a clean product name without redundant info."""
        clean = text

        # Remove brand if at start
        if attrs.brand:
            clean = re.sub(rf'^\s*{re.escape(attrs.brand)}\s*', '', clean, flags=re.I)

        # Remove size
        if attrs.size:
            clean = clean.replace(attrs.size.raw, '')

        # Remove trailing model numbers
        if attrs.model_number:
            clean = clean.replace(attrs.model_number, '')

        # Remove common prefixes
        clean = re.sub(r'^(Purchased|Ordered|Bought)\s*:?\s*', '', clean, flags=re.I)

        # Clean up
        clean = re.sub(r'\s+', ' ', clean).strip(' -,|/')

        return clean if clean else text


@dataclass
class UserConfig:
    """
    User configuration for personalized parsing (e.g., gift detection).
    """
    # User's name variations
    user_names: List[str] = field(default_factory=list)

    # Known home addresses (partial matches OK)
    home_addresses: List[str] = field(default_factory=list)

    # Known work addresses
    work_addresses: List[str] = field(default_factory=list)

    # Known team members (orders for them are likely work-related)
    team_members: List[str] = field(default_factory=list)

    def is_user_address(self, address: str, recipient: Optional[str] = None) -> Tuple[bool, bool]:
        """
        Check if address/recipient matches user's known addresses.

        Returns:
            (is_user_address, is_work_address)
        """
        if not address and not recipient:
            return (True, False)  # Assume personal if no address info

        address_lower = (address or '').lower()
        recipient_lower = (recipient or '').lower()

        # Check if recipient is user
        for name in self.user_names:
            if name.lower() in recipient_lower:
                # Check if work address
                for work_addr in self.work_addresses:
                    if work_addr.lower() in address_lower:
                        return (True, True)
                return (True, False)

        # Check if recipient is team member (work order)
        for member in self.team_members:
            if member.lower() in recipient_lower:
                return (True, True)  # User's address but for team = work

        # Check addresses
        for home_addr in self.home_addresses:
            if home_addr.lower() in address_lower:
                return (True, False)

        for work_addr in self.work_addresses:
            if work_addr.lower() in address_lower:
                return (True, True)

        # Unknown address - might be a gift
        return (False, False)


# Example user config - customize for your use
# To use: Create a UserConfig with your own names/addresses
# Example:
#   my_config = UserConfig(
#       user_names=['Your Name', 'Y Name'],
#       home_addresses=['123 Main St'],
#       work_addresses=['456 Office Blvd'],
#       team_members=['Colleague1', 'Colleague2'],
#   )
#   parser = ProductParser(user_config=my_config)
