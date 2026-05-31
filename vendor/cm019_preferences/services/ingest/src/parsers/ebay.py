"""eBay data parser - comprehensive extraction from GDPR HTML/CSV exports."""

import csv
import logging
import re
import zipfile
from pathlib import Path
from typing import AsyncIterator, Optional, Dict, Any, List, Tuple
from datetime import datetime
from bs4 import BeautifulSoup
import aiofiles

from .base import BaseParser, ParsedPreference

logger = logging.getLogger(__name__)

# Base strength values per signal type (0.0 to 1.0 scale)
# These are pre-decay values; the pipeline applies time decay.
SIGNAL_STRENGTHS = {
    "purchase": 1.0,        # Financial commitment - strongest signal
    "bid": 0.8,             # Strong intent to buy
    "saved_search": 0.75,   # Active pattern monitoring - high intent
    "watch": 0.6,           # Moderate interest - added to watchlist
    "browse": 0.35,         # Weak signal - just looked
    "sell": 0.12,           # Weak signal - owned but sold
}

# Electronics decay configuration
# Collectable electronics: standard decay (10-year half-life, 40% floor)
# Regular electronics: faster decay (5-year half-life, 20% floor)
COLLECTABLE_ELECTRONICS_PATTERNS = re.compile(
    r'\b(vintage|classic|anniversary|retro|collector|rare|'
    r'mac\s*classic|20th\s*anniversary|apple\s*newton|'
    r'apple\s*i+[^a-z]|macintosh\s*(128k?|512k?|plus|se|ii))\b',
    re.I
)

# Decay parameters by category type
DECAY_PARAMS = {
    "electronics_collectable": {"half_life_years": 10, "floor": 0.4},
    "electronics_regular": {"half_life_years": 5, "floor": 0.2},
    "default": {"half_life_years": 10, "floor": 0.4},
}

# Brand detection patterns - common brands to extract
# More comprehensive extraction happens in enrichment phase
BRAND_PATTERNS: List[Tuple[re.Pattern, str]] = [
    # Tech/Electronics
    (re.compile(r'\b(apple|iphone|ipad|macbook|imac)\b', re.I), 'Apple'),
    (re.compile(r'\b(samsung)\b', re.I), 'Samsung'),
    (re.compile(r'\b(sony)\b', re.I), 'Sony'),
    (re.compile(r'\b(nokia)\b', re.I), 'Nokia'),
    (re.compile(r'\b(panasonic)\b', re.I), 'Panasonic'),
    (re.compile(r'\b(canon)\b', re.I), 'Canon'),
    (re.compile(r'\b(nikon)\b', re.I), 'Nikon'),
    (re.compile(r'\b(gopro)\b', re.I), 'GoPro'),
    (re.compile(r'\b(dji|mavic)\b', re.I), 'DJI'),
    (re.compile(r'\b(bose)\b', re.I), 'Bose'),
    (re.compile(r'\b(dyson)\b', re.I), 'Dyson'),
    (re.compile(r'\b(raspberry\s*pi)\b', re.I), 'Raspberry Pi'),
    (re.compile(r'\b(arduino)\b', re.I), 'Arduino'),
    # Fashion
    (re.compile(r'\b(nike)\b', re.I), 'Nike'),
    (re.compile(r'\b(adidas)\b', re.I), 'Adidas'),
    (re.compile(r'\b(levis?|levi\'?s)\b', re.I), 'Levi\'s'),
    (re.compile(r'\b(g-star|gstar)\b', re.I), 'G-Star'),
    (re.compile(r'\b(vollebak)\b', re.I), 'Vollebak'),
    (re.compile(r'\b(rokker)\b', re.I), 'Rokker'),
    (re.compile(r'\b(belstaff)\b', re.I), 'Belstaff'),
    (re.compile(r'\b(alpinestars)\b', re.I), 'Alpinestars'),
    (re.compile(r'\b(dainese)\b', re.I), 'Dainese'),
    (re.compile(r'\b(new\s*balance)\b', re.I), 'New Balance'),
    (re.compile(r'\b(under\s*armou?r)\b', re.I), 'Under Armour'),
    (re.compile(r'\b(ray-?ban)\b', re.I), 'Ray-Ban'),
    (re.compile(r'\b(oakley)\b', re.I), 'Oakley'),
    # Watches
    (re.compile(r'\b(rolex)\b', re.I), 'Rolex'),
    (re.compile(r'\b(omega)\b', re.I), 'Omega'),
    (re.compile(r'\b(seiko)\b', re.I), 'Seiko'),
    (re.compile(r'\b(casio|g-shock)\b', re.I), 'Casio'),
    # Motorcycle
    (re.compile(r'\b(motogadget)\b', re.I), 'Motogadget'),
    (re.compile(r'\b(rizoma)\b', re.I), 'Rizoma'),
    (re.compile(r'\b(ohlins)\b', re.I), 'Öhlins'),
    (re.compile(r'\b(brembo)\b', re.I), 'Brembo'),
    (re.compile(r'\b(akrapovic)\b', re.I), 'Akrapovič'),
    (re.compile(r'\b(triumph)\b', re.I), 'Triumph'),
    (re.compile(r'\b(harley|harley-?davidson)\b', re.I), 'Harley-Davidson'),
    (re.compile(r'\b(ducati)\b', re.I), 'Ducati'),
    # Home/Garden
    (re.compile(r'\b(countax)\b', re.I), 'Countax'),
    (re.compile(r'\b(weber)\b', re.I), 'Weber'),
    (re.compile(r'\b(kitchenaid)\b', re.I), 'KitchenAid'),
]

# Category detection patterns
# Maps regex patterns to (category, optional_subcategory)
CATEGORY_PATTERNS: List[Tuple[re.Pattern, str, Optional[str]]] = [
    # Electronics
    (re.compile(r'\b(iphone|ipad|macbook|apple watch|airpods|mac mini|imac)\b', re.I), 'electronics', 'apple'),
    (re.compile(r'\b(samsung|galaxy|android|pixel|oneplus)\b', re.I), 'electronics', 'mobile'),
    (re.compile(r'\b(laptop|notebook|chromebook|computer|pc|desktop)\b', re.I), 'electronics', 'computer'),
    (re.compile(r'\b(headphones?|earbuds?|speakers?|soundbar|audio|amp|amplifier)\b', re.I), 'electronics', 'audio'),
    (re.compile(r'\b(tv|television|monitor|display|oled|lcd|led)\b', re.I), 'electronics', 'display'),
    (re.compile(r'\b(camera|lens|dslr|mirrorless|gopro|canon|nikon|sony alpha)\b', re.I), 'electronics', 'camera'),
    (re.compile(r'\b(drone|dji|mavic|quadcopter)\b', re.I), 'electronics', 'drone'),
    (re.compile(r'\b(smartwatch|fitbit|garmin|whoop)\b', re.I), 'electronics', 'wearable'),
    (re.compile(r'\b(playstation|ps[45]|xbox|nintendo|switch|gaming console)\b', re.I), 'electronics', 'gaming'),
    (re.compile(r'\b(router|wifi|modem|network|ethernet)\b', re.I), 'electronics', 'networking'),
    (re.compile(r'\b(nokia|motorola|blackberry|mobile phone|cell phone)\b', re.I), 'electronics', 'mobile'),

    # Vehicles & Parts
    (re.compile(r'\b(motorcycle|motorbike|harley|ducati|triumph|bmw r\d|honda cb|kawasaki|yamaha)\b', re.I), 'vehicle', 'motorcycle'),
    (re.compile(r'\b(motogadget|rizoma|ohlins|brembo|akrapovic|motoscope)\b', re.I), 'vehicle', 'motorcycle_parts'),
    (re.compile(r'\b(car|auto|vehicle|ford|toyota|honda civic|bmw|audi|mercedes)\b', re.I), 'vehicle', 'car'),
    (re.compile(r'\b(bicycle|cycling|shimano|sram|trek|specialized|cannondale)\b', re.I), 'vehicle', 'bicycle'),
    (re.compile(r'\b(lawnmower|mower|countax|ride.on|tractor)\b', re.I), 'vehicle', 'garden_equipment'),

    # Fashion & Clothing
    (re.compile(r'\b(jeans|trousers|pants|shorts|chinos)\b', re.I), 'fashion', 'clothing'),
    (re.compile(r'\b(jacket|coat|blazer|hoodie|sweater|cardigan)\b', re.I), 'fashion', 'outerwear'),
    (re.compile(r'\b(shirt|t-shirt|tee|polo|blouse|top)\b', re.I), 'fashion', 'tops'),
    (re.compile(r'\b(shoes?|boots?|trainers?|sneakers?|loafers?|oxfords?)\b', re.I), 'fashion', 'footwear'),
    (re.compile(r'\b(rolex|omega|seiko|casio|g-shock|wristwatch)\b', re.I), 'fashion', 'watches'),
    (re.compile(r'\b(sunglasses|glasses|ray-ban|oakley)\b', re.I), 'fashion', 'eyewear'),
    (re.compile(r'\b(bag|backpack|messenger|briefcase|wallet|purse)\b', re.I), 'fashion', 'accessories'),
    (re.compile(r'\b(rokker|belstaff|alpinestars|dainese|motorrad)\b', re.I), 'fashion', 'motorcycle_gear'),

    # Home & Garden
    (re.compile(r'\b(garden|lawn|hedge|trimmer|sweeper)\b', re.I), 'home', 'garden'),
    (re.compile(r'\b(furniture|sofa|chair|table|desk|bed|mattress)\b', re.I), 'home', 'furniture'),
    (re.compile(r'\b(lamp|light|lighting|chandelier|bulb)\b', re.I), 'home', 'lighting'),
    (re.compile(r'\b(kitchen|cookware|pan|pot|knife|mixer|blender)\b', re.I), 'home', 'kitchen'),
    (re.compile(r'\b(vacuum|dyson|roomba|cleaning)\b', re.I), 'home', 'appliances'),
    (re.compile(r'\b(tool|drill|saw|wrench|screwdriver|hammer|magnetic.+catch)\b', re.I), 'home', 'tools'),

    # Collectibles & Hobbies
    (re.compile(r'\b(vinyl|record|lp|turntable|hifi|hi-fi)\b', re.I), 'hobby', 'vinyl'),
    (re.compile(r'\b(guitar|bass|keyboard|synthesizer|synth|drum|pedal)\b', re.I), 'hobby', 'music_gear'),
    (re.compile(r'\b(lego|playmobil|model|miniature|figure|action figure)\b', re.I), 'hobby', 'collectibles'),
    (re.compile(r'\b(book|novel|textbook|hardcover|paperback)\b', re.I), 'book', None),
    (re.compile(r'\b(comic|manga|graphic novel)\b', re.I), 'book', 'comics'),
    (re.compile(r'\b(art|painting|print|poster|canvas|frame)\b', re.I), 'hobby', 'art'),
    (re.compile(r'\b(pinball|arcade|game machine)\b', re.I), 'hobby', 'arcade'),

    # Kids & Toys
    (re.compile(r'\b(toy|toys|kids|children|baby|toddler|nursery)\b', re.I), 'kids', 'toys'),
    (re.compile(r'\b(roary|peppa|paw patrol|disney|pixar|thomas the tank)\b', re.I), 'kids', 'characters'),
    (re.compile(r'\b(racing car|talking.*toy)\b', re.I), 'kids', 'toys'),

    # Sports & Fitness
    (re.compile(r'\b(gym|fitness|weight|dumbbell|barbell|treadmill|exercise)\b', re.I), 'fitness', 'equipment'),
    (re.compile(r'\b(golf|tennis|football|soccer|basketball|rugby)\b', re.I), 'sports', None),
    (re.compile(r'\b(ski|snowboard|surf|wetsuit|paddleboard)\b', re.I), 'sports', 'outdoor'),

    # Media
    (re.compile(r'\b(dvd|blu-ray|bluray|4k uhd|movie|film)\b', re.I), 'media', 'video'),
    (re.compile(r'\b(cd|album|music cd)\b', re.I), 'media', 'music'),
    (re.compile(r'\b(video game|ps[345] game|xbox game|nintendo game)\b', re.I), 'media', 'games'),
]


class EbayParser(BaseParser):
    """
    Parser for eBay GDPR data exports.

    Handles both HTML (GDPR export) and CSV formats:

    HTML files (GDPR export - primary format):
    - watchedItems.html - Items watched (moderate interest)
    - purchaseHistory.html - Items purchased (strong signal)
    - biddingHistory.html - Items bid on (strong intent)
    - savedSearches.html - Search patterns saved (interest patterns)
    - browsingHistory.html - Items browsed (weak signal)
    - sellingHistory.html - Items sold (weak signal - past ownership)

    CSV files (legacy/alternative format):
    - Purchase/order history
    - Bids
    - Watching list
    - Saved searches

    Time decay is applied based on item dates (10-year half-life, 40% floor).
    """

    source_name = "ebay"

    def can_parse(self, file_path: Path) -> bool:
        """Check if file is an eBay data export."""
        name = file_path.name.lower()
        full_path = str(file_path).lower()

        # Require 'ebay' in path to avoid false matches
        if 'ebay' not in full_path:
            return False

        # Check for ZIP file containing eBay reports
        if file_path.suffix.lower() == '.zip':
            try:
                with zipfile.ZipFile(file_path, 'r') as zf:
                    names = [n.lower() for n in zf.namelist()]
                    return any(
                        'watcheditems' in n or 'purchasehistory' in n or
                        'biddinghistory' in n or 'savedsearches' in n or
                        'browsinghistory' in n or 'sellinghistory' in n or
                        'feedbackhistory' in n or 'ebayreports' in n
                        for n in names
                    )
            except:
                return False

        # HTML files (GDPR export format)
        if file_path.suffix.lower() == '.html':
            return name in (
                'watcheditems.html', 'purchasehistory.html', 'biddinghistory.html',
                'savedsearches.html', 'browsinghistory.html', 'sellinghistory.html',
                'feedbackhistory.html'
            )

        # CSV files (legacy format)
        if file_path.suffix.lower() == '.csv':
            ebay_files = ["purchase", "order", "bid", "watching", "saved search"]
            return any(f in name for f in ebay_files)

        return False

    async def parse(
        self,
        file_path: Path,
        default_compartment: Optional[int] = None,
        **kwargs
    ) -> AsyncIterator[ParsedPreference]:
        """Parse eBay data export."""
        if default_compartment is None:
            default_compartment = 2  # L2 Trusted

        logger.info(f"Parsing eBay data from {file_path}")

        if file_path.suffix.lower() == '.zip':
            async for pref in self._parse_zip(file_path, default_compartment):
                yield pref
        elif file_path.suffix.lower() == '.html':
            async for pref in self._parse_html_file(file_path, default_compartment):
                yield pref
        elif file_path.suffix.lower() == '.csv':
            async for pref in self._parse_csv_file(file_path, default_compartment):
                yield pref

    async def _parse_zip(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse eBay ZIP archive."""
        with zipfile.ZipFile(file_path, 'r') as zf:
            for name in zf.namelist():
                name_lower = name.lower()

                # Skip index files and non-data files
                if 'index.html' in name_lower or not name_lower.endswith('.html'):
                    continue

                content = zf.read(name).decode('utf-8', errors='replace')

                if 'watcheditems' in name_lower:
                    async for pref in self._parse_watched_items(content, default_compartment):
                        yield pref

                elif 'purchasehistory' in name_lower:
                    async for pref in self._parse_purchase_history(content, default_compartment):
                        yield pref

                elif 'biddinghistory' in name_lower:
                    async for pref in self._parse_bidding_history(content, default_compartment):
                        yield pref

                elif 'savedsearches' in name_lower:
                    async for pref in self._parse_saved_searches(content, default_compartment):
                        yield pref

                elif 'browsinghistory' in name_lower:
                    async for pref in self._parse_browsing_history(content, default_compartment):
                        yield pref

                elif 'sellinghistory' in name_lower:
                    async for pref in self._parse_selling_history(content, default_compartment):
                        yield pref

                elif 'feedbackhistory' in name_lower:
                    async for pref in self._parse_feedback_history(content, default_compartment):
                        yield pref

    async def _parse_html_file(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse individual HTML file."""
        async with aiofiles.open(file_path, mode='r', encoding='utf-8', errors='replace') as f:
            content = await f.read()

        name = file_path.name.lower()

        if 'watcheditems' in name:
            async for pref in self._parse_watched_items(content, default_compartment):
                yield pref
        elif 'purchasehistory' in name:
            async for pref in self._parse_purchase_history(content, default_compartment):
                yield pref
        elif 'biddinghistory' in name:
            async for pref in self._parse_bidding_history(content, default_compartment):
                yield pref
        elif 'savedsearches' in name:
            async for pref in self._parse_saved_searches(content, default_compartment):
                yield pref
        elif 'browsinghistory' in name:
            async for pref in self._parse_browsing_history(content, default_compartment):
                yield pref
        elif 'sellinghistory' in name:
            async for pref in self._parse_selling_history(content, default_compartment):
                yield pref
        elif 'feedbackhistory' in name:
            async for pref in self._parse_feedback_history(content, default_compartment):
                yield pref

    async def _parse_csv_file(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse CSV file (legacy format)."""
        file_name = file_path.name.lower()

        if "purchase" in file_name or "order" in file_name:
            async for pref in self._parse_purchases_csv(file_path, default_compartment):
                yield pref
        elif "bid" in file_name:
            async for pref in self._parse_bids_csv(file_path, default_compartment):
                yield pref
        elif "watching" in file_name or "watch" in file_name:
            async for pref in self._parse_watching_csv(file_path, default_compartment):
                yield pref
        elif "saved search" in file_name or "search" in file_name:
            async for pref in self._parse_saved_searches_csv(file_path, default_compartment):
                yield pref

    def _parse_date(self, date_str: str) -> Optional[datetime]:
        """Parse eBay date formats."""
        if not date_str:
            return None

        date_str = date_str.strip()

        formats = [
            "%b %d, %Y %I:%M %p",   # "Jan 18, 2009 04:47 AM"
            "%b %d, %Y %I:%M%p",    # "Jan 18, 2009 04:47AM"
            "%b %d, %Y",            # "Jan 18, 2009"
            "%B %d, %Y",            # "January 18, 2009"
            "%Y-%m-%d",             # "2009-01-18"
            "%d-%b-%y",             # "18-Jan-09"
            "%d/%m/%Y",             # "18/01/2009"
            "%m/%d/%Y",             # "01/18/2009"
        ]

        for fmt in formats:
            try:
                return datetime.strptime(date_str, fmt)
            except ValueError:
                continue

        # Try parsing with regex for more flexibility
        # Match patterns like "Dec 06, 2008"
        match = re.match(r'(\w{3})\s+(\d{1,2}),\s+(\d{4})', date_str)
        if match:
            try:
                month_str, day, year = match.groups()
                return datetime.strptime(f"{month_str} {day}, {year}", "%b %d, %Y")
            except ValueError:
                pass

        return None

    def _detect_category(self, item_name: str) -> Tuple[str, Optional[str]]:
        """Detect item category from name using pattern matching."""
        item_lower = item_name.lower()

        for pattern, category, subcategory in CATEGORY_PATTERNS:
            if pattern.search(item_lower):
                return category, subcategory

        return "product", None  # Default category

    def _detect_brand(self, item_name: str) -> Optional[str]:
        """Extract brand from item name.

        Returns canonical brand name if detected, None otherwise.
        More comprehensive brand extraction happens in enrichment phase.
        """
        for pattern, brand_name in BRAND_PATTERNS:
            if pattern.search(item_name):
                return brand_name
        return None

    def _is_collectable_electronics(self, item_name: str) -> bool:
        """Check if an electronics item is a collectable (vintage/classic).

        Collectables get standard decay (10-year half-life, 40% floor).
        Regular electronics get faster decay (5-year half-life, 20% floor).
        """
        return bool(COLLECTABLE_ELECTRONICS_PATTERNS.search(item_name))

    def _get_decay_params(self, category: str, item_name: str) -> Dict[str, Any]:
        """Get decay parameters based on category and item characteristics.

        Returns dict with 'half_life_years' and 'floor' for the pipeline to use.
        """
        if category == 'electronics':
            if self._is_collectable_electronics(item_name):
                return DECAY_PARAMS["electronics_collectable"]
            else:
                return DECAY_PARAMS["electronics_regular"]
        return DECAY_PARAMS["default"]

    def _extract_table_rows(self, soup: BeautifulSoup) -> List[Dict[str, str]]:
        """Extract data from HTML table rows.

        Handles malformed HTML where rows may not have proper <tr> wrappers.
        """
        rows = []

        # Find main table
        tables = soup.find_all('table', class_='table')
        if not tables:
            tables = soup.find_all('table')

        for table in tables:
            # Get header row to identify columns
            header_row = table.find('tr')
            if not header_row:
                continue

            headers = []
            for th in header_row.find_all(['th', 'td']):
                header_text = th.get_text(strip=True).lower()
                # Normalize header names
                if 'date' in header_text:
                    if 'watch' in header_text:
                        headers.append('watch_date')
                    elif 'purchase' in header_text:
                        headers.append('purchase_date')
                    elif 'bid' in header_text:
                        headers.append('bid_date')
                    elif 'end' in header_text:
                        headers.append('end_date')
                    elif 'start' in header_text:
                        headers.append('start_date')
                    elif 'sale' in header_text:
                        headers.append('sale_date')
                    else:
                        headers.append('date')
                elif 'item' in header_text and ('name' in header_text or 'id' not in header_text):
                    headers.append('item_name')
                elif 'listing' in header_text and 'title' in header_text:
                    headers.append('item_name')
                elif 'search' in header_text and 'name' in header_text:
                    headers.append('search_name')
                elif 'price' in header_text:
                    if 'total' in header_text:
                        headers.append('total_price')
                    elif 'individual' in header_text:
                        headers.append('unit_price')
                    else:
                        headers.append('price')
                elif 'quantity' in header_text:
                    headers.append('quantity')
                elif 'currency' in header_text:
                    headers.append('currency')
                elif 'seller' in header_text:
                    headers.append('seller')
                elif 'buyer' in header_text:
                    headers.append('buyer')
                elif 'site' in header_text:
                    headers.append('site')
                elif 'url' in header_text:
                    headers.append('url')
                elif 'item' in header_text and 'id' in header_text:
                    headers.append('item_id')
                else:
                    headers.append(header_text.replace(' ', '_'))

            num_columns = len(headers)
            if num_columns == 0:
                continue

            # eBay HTML is often malformed - <td> elements may not be properly
            # wrapped in <tr> tags. Handle this by collecting ALL <td> elements
            # and grouping them by the expected column count.
            all_tds = table.find_all('td')

            if all_tds:
                # Group TDs into rows based on column count
                current_row = []
                for td in all_tds:
                    current_row.append(td.get_text(strip=True))
                    if len(current_row) == num_columns:
                        row_data = {}
                        for i, value in enumerate(current_row):
                            row_data[headers[i]] = value
                        if any(row_data.values()):
                            rows.append(row_data)
                        current_row = []

        return rows

    # ========================================
    # HTML Parsing Methods (GDPR Export)
    # ========================================

    async def _parse_watched_items(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse watched items - moderate interest signal."""
        soup = BeautifulSoup(content, 'lxml')
        rows = self._extract_table_rows(soup)

        logger.info(f"Processing {len(rows)} eBay watched items")
        count = 0

        for row in rows:
            try:
                item_name = row.get('item_name', '').strip()
                if not item_name:
                    continue

                # Parse date
                date_str = row.get('watch_date', row.get('date', ''))
                observed_at = self._parse_date(date_str)

                # Detect category and brand
                category, subcategory = self._detect_category(item_name)
                brand = self._detect_brand(item_name)
                decay_params = self._get_decay_params(category, item_name)

                extra = {
                    "type": "watch",
                    "signal_type": "watched",
                    "decay_half_life_years": decay_params["half_life_years"],
                    "decay_floor": decay_params["floor"],
                }

                if subcategory:
                    extra["subcategory"] = subcategory

                if brand:
                    extra["brand"] = brand

                site = row.get('site', '').strip()
                if site:
                    extra["site"] = site

                yield ParsedPreference(
                    subject=item_name,
                    preference_type="Like",
                    category=category,
                    strength=SIGNAL_STRENGTHS["watch"],
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size=self.classify_size(item_name, category),
                    observed_at=observed_at,
                    extra=extra
                )
                count += 1

            except Exception as e:
                logger.warning(f"Error parsing watched item: {e}")
                continue

        logger.info(f"Parsed {count} watched items")

    async def _parse_purchase_history(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse purchase history - strong signal (financial commitment)."""
        soup = BeautifulSoup(content, 'lxml')
        rows = self._extract_table_rows(soup)

        logger.info(f"Processing {len(rows)} eBay purchases")
        count = 0

        for row in rows:
            try:
                item_name = row.get('item_name', row.get('listing_title', '')).strip()
                if not item_name:
                    continue

                # Parse date
                date_str = row.get('purchase_date', row.get('date', ''))
                observed_at = self._parse_date(date_str)

                # Detect category and brand
                category, subcategory = self._detect_category(item_name)
                brand = self._detect_brand(item_name)
                decay_params = self._get_decay_params(category, item_name)

                extra = {
                    "type": "purchase",
                    "signal_type": "purchased",
                    "decay_half_life_years": decay_params["half_life_years"],
                    "decay_floor": decay_params["floor"],
                }

                if subcategory:
                    extra["subcategory"] = subcategory

                if brand:
                    extra["brand"] = brand

                # Add price info if available
                price = row.get('total_price', row.get('price', ''))
                if price:
                    extra["price"] = price

                currency = row.get('currency', '')
                if currency:
                    extra["currency"] = currency

                quantity = row.get('quantity', '')
                if quantity:
                    try:
                        extra["quantity"] = int(quantity)
                    except ValueError:
                        pass

                seller = row.get('seller', row.get('seller_name', ''))
                if seller:
                    extra["seller"] = seller

                item_id = row.get('item_id', '')
                if item_id:
                    extra["ebay_item_id"] = item_id

                yield ParsedPreference(
                    subject=item_name,
                    preference_type="Like",
                    category=category,
                    strength=SIGNAL_STRENGTHS["purchase"],
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size=self.classify_size(item_name, category),
                    observed_at=observed_at,
                    extra=extra
                )
                count += 1

            except Exception as e:
                logger.warning(f"Error parsing purchase: {e}")
                continue

        logger.info(f"Parsed {count} purchases")

    async def _parse_bidding_history(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse bidding history - strong intent signal.

        eBay bidding history has a complex nested structure:
        - Item rows: 4 TDs (Item ID, Title, Currency, Start price)
        - Bid rows: 5 TDs (Username, Bid amount, Quantity, Winning qty, Bid time)

        Multiple bids can follow each item. We yield one preference per item,
        using the last bid time as the observed_at date.
        """
        soup = BeautifulSoup(content, 'lxml')
        table = soup.find('table')

        if not table:
            logger.warning("No table found in bidding history")
            return

        tds = table.find_all('td')
        logger.info(f"Processing bidding history with {len(tds)} TD elements")

        count = 0
        i = 0
        current_item = None
        last_bid_time = None

        while i < len(tds):
            td_text = tds[i].get_text(strip=True)

            # Item rows have numeric Item ID as first field
            if td_text.isdigit() and len(td_text) > 8 and i + 3 < len(tds):
                # This looks like an Item ID - check if next fields match item pattern
                title = tds[i + 1].get_text(strip=True) if i + 1 < len(tds) else ''
                currency = tds[i + 2].get_text(strip=True) if i + 2 < len(tds) else ''
                price = tds[i + 3].get_text(strip=True) if i + 3 < len(tds) else ''

                # Validate: currency should be 3 letters, price should be numeric-ish
                if len(currency) == 3 and currency.isalpha():
                    # Yield previous item if exists
                    if current_item and current_item.get('title'):
                        try:
                            item_name = current_item['title']
                            category, subcategory = self._detect_category(item_name)
                            brand = self._detect_brand(item_name)
                            decay_params = self._get_decay_params(category, item_name)

                            extra = {
                                "type": "bid",
                                "signal_type": "bid",
                                "ebay_item_id": current_item.get('item_id'),
                                "currency": current_item.get('currency'),
                                "decay_half_life_years": decay_params["half_life_years"],
                                "decay_floor": decay_params["floor"],
                            }

                            if subcategory:
                                extra["subcategory"] = subcategory

                            if brand:
                                extra["brand"] = brand

                            if current_item.get('max_bid'):
                                extra["max_bid"] = current_item['max_bid']

                            if current_item.get('bid_count'):
                                extra["bid_count"] = current_item['bid_count']

                            yield ParsedPreference(
                                subject=item_name,
                                preference_type="Like",
                                category=category,
                                strength=SIGNAL_STRENGTHS["bid"],
                                source=self.source_name,
                                compartment_level=default_compartment,
                                size=self.classify_size(item_name, category),
                                observed_at=last_bid_time,
                                extra=extra
                            )
                            count += 1
                        except Exception as e:
                            logger.warning(f"Error yielding bid item: {e}")

                    # Start new item
                    current_item = {
                        'item_id': td_text,
                        'title': title,
                        'currency': currency,
                        'start_price': price,
                        'max_bid': None,
                        'bid_count': 0
                    }
                    last_bid_time = None
                    i += 4
                    continue

            # If we have a current item and see 5 TDs that look like a bid
            if current_item and i + 4 < len(tds):
                # Bid rows: Username, Amount, Quantity, Winning qty, Time
                username = td_text
                bid_amount = tds[i + 1].get_text(strip=True)
                quantity = tds[i + 2].get_text(strip=True)
                winning_qty = tds[i + 3].get_text(strip=True)
                bid_time_str = tds[i + 4].get_text(strip=True)

                # Validate: bid_amount should be numeric, quantity should be 1-2 digits
                try:
                    float(bid_amount.replace(',', ''))
                    bid_time = self._parse_date(bid_time_str)

                    if bid_time:
                        current_item['bid_count'] = current_item.get('bid_count', 0) + 1

                        # Track max bid
                        try:
                            amt = float(bid_amount.replace(',', ''))
                            if current_item['max_bid'] is None or amt > current_item['max_bid']:
                                current_item['max_bid'] = amt
                        except:
                            pass

                        # Use last bid time as observed_at
                        last_bid_time = bid_time

                    i += 5
                    continue
                except ValueError:
                    pass

            # Move to next TD if nothing matched
            i += 1

        # Yield final item
        if current_item and current_item.get('title'):
            try:
                item_name = current_item['title']
                category, subcategory = self._detect_category(item_name)
                brand = self._detect_brand(item_name)
                decay_params = self._get_decay_params(category, item_name)

                extra = {
                    "type": "bid",
                    "signal_type": "bid",
                    "ebay_item_id": current_item.get('item_id'),
                    "currency": current_item.get('currency'),
                    "decay_half_life_years": decay_params["half_life_years"],
                    "decay_floor": decay_params["floor"],
                }

                if subcategory:
                    extra["subcategory"] = subcategory

                if brand:
                    extra["brand"] = brand

                if current_item.get('max_bid'):
                    extra["max_bid"] = current_item['max_bid']

                if current_item.get('bid_count'):
                    extra["bid_count"] = current_item['bid_count']

                yield ParsedPreference(
                    subject=item_name,
                    preference_type="Like",
                    category=category,
                    strength=SIGNAL_STRENGTHS["bid"],
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size=self.classify_size(item_name, category),
                    observed_at=last_bid_time,
                    extra=extra
                )
                count += 1
            except Exception as e:
                logger.warning(f"Error yielding final bid item: {e}")

        logger.info(f"Parsed {count} bid items")

    async def _parse_saved_searches(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse saved searches - interest pattern signal."""
        soup = BeautifulSoup(content, 'lxml')
        rows = self._extract_table_rows(soup)

        logger.info(f"Processing {len(rows)} eBay saved searches")
        count = 0

        for row in rows:
            try:
                search_name = row.get('search_name', row.get('item_name', '')).strip()
                if not search_name:
                    continue

                # Parse dates
                start_date_str = row.get('follow_start_date', row.get('start_date', ''))
                end_date_str = row.get('follow_end_date', row.get('end_date', ''))

                observed_at = self._parse_date(start_date_str)

                # Detect category and brand from search term
                category, subcategory = self._detect_category(search_name)
                brand = self._detect_brand(search_name)
                decay_params = self._get_decay_params(category, search_name)

                extra = {
                    "type": "saved_search",
                    "signal_type": "search_pattern",
                    "decay_half_life_years": decay_params["half_life_years"],
                    "decay_floor": decay_params["floor"],
                }

                if subcategory:
                    extra["subcategory"] = subcategory

                if brand:
                    extra["brand"] = brand

                # Add URL if available (contains search parameters)
                url = row.get('url', '')
                if url:
                    extra["search_url"] = url

                # Add end date to track duration
                if end_date_str:
                    end_date = self._parse_date(end_date_str)
                    if end_date:
                        extra["end_date"] = end_date.isoformat()

                yield ParsedPreference(
                    subject=f"search: {search_name}",
                    preference_type="Pattern",
                    category=category,
                    strength=SIGNAL_STRENGTHS["saved_search"],
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    observed_at=observed_at,
                    extra=extra
                )
                count += 1

            except Exception as e:
                logger.warning(f"Error parsing saved search: {e}")
                continue

        logger.info(f"Parsed {count} saved searches")

    async def _parse_browsing_history(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse browsing history - weak interest signal.

        eBay browsing history has 8 columns:
        Date, Device type, Search query, Item ID, Referrer, Session start date, Page name, IP

        Most rows have empty search queries and item IDs. We extract:
        - Search queries (unique) as weak browse signals
        - Skip rows with only internal page tracking (no useful data)
        """
        soup = BeautifulSoup(content, 'lxml')
        table = soup.find('table')

        if not table:
            logger.warning("No table found in browsing history")
            return

        tds = table.find_all('td')
        num_columns = 8  # Fixed structure

        logger.info(f"Processing browsing history with {len(tds)} TD elements")

        seen_queries = set()
        count = 0

        for i in range(0, len(tds) - num_columns + 1, num_columns):
            try:
                date_str = tds[i].get_text(strip=True)
                search_query = tds[i + 2].get_text(strip=True)
                item_id = tds[i + 3].get_text(strip=True)

                # Skip if no useful data
                if not search_query and not item_id:
                    continue

                observed_at = self._parse_date(date_str)

                # Extract search queries (deduplicated)
                if search_query and search_query not in seen_queries:
                    seen_queries.add(search_query)

                    category, subcategory = self._detect_category(search_query)
                    brand = self._detect_brand(search_query)
                    decay_params = self._get_decay_params(category, search_query)

                    extra = {
                        "type": "browse_search",
                        "signal_type": "browsed",
                        "decay_half_life_years": decay_params["half_life_years"],
                        "decay_floor": decay_params["floor"],
                    }

                    if subcategory:
                        extra["subcategory"] = subcategory

                    if brand:
                        extra["brand"] = brand

                    yield ParsedPreference(
                        subject=f"browsed: {search_query}",
                        preference_type="Like",
                        category=category,
                        strength=SIGNAL_STRENGTHS["browse"],
                        source=self.source_name,
                        compartment_level=default_compartment,
                        size="Micro",
                        observed_at=observed_at,
                        extra=extra
                    )
                    count += 1

            except Exception as e:
                logger.warning(f"Error parsing browsing history row: {e}")
                continue

        logger.info(f"Parsed {count} browsing history items")

    async def _parse_selling_history(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse selling history - weak signal (past ownership)."""
        soup = BeautifulSoup(content, 'lxml')
        rows = self._extract_table_rows(soup)

        logger.info(f"Processing {len(rows)} eBay selling history items")
        count = 0

        for row in rows:
            try:
                item_name = row.get('item_name', row.get('listing_title', '')).strip()
                if not item_name:
                    continue

                # Parse date
                date_str = row.get('sale_date', row.get('date', row.get('end_date', '')))
                observed_at = self._parse_date(date_str)

                # Detect category and brand
                category, subcategory = self._detect_category(item_name)
                brand = self._detect_brand(item_name)
                decay_params = self._get_decay_params(category, item_name)

                extra = {
                    "type": "sell",
                    "signal_type": "sold",
                    "decay_half_life_years": decay_params["half_life_years"],
                    "decay_floor": decay_params["floor"],
                }

                if subcategory:
                    extra["subcategory"] = subcategory

                if brand:
                    extra["brand"] = brand

                # Add price info if available
                price = row.get('price', row.get('sale_price', ''))
                if price:
                    extra["sale_price"] = price

                buyer = row.get('buyer', '')
                if buyer:
                    extra["buyer"] = buyer

                yield ParsedPreference(
                    subject=item_name,
                    preference_type="Like",  # Past ownership still indicates some preference
                    category=category,
                    strength=SIGNAL_STRENGTHS["sell"],
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size=self.classify_size(item_name, category),
                    observed_at=observed_at,
                    extra=extra
                )
                count += 1

            except Exception as e:
                logger.warning(f"Error parsing selling history: {e}")
                continue

        logger.info(f"Parsed {count} selling history items")

    async def _parse_feedback_history(
        self,
        content: str,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """
        Parse feedback history - captures purchases not in purchaseHistory.

        FeedbackHistory contains items you've received feedback for as both
        BUYER (purchases) and SELLER (sales). Some older purchases only appear
        here and not in purchaseHistory.html.

        Structure: Role marker, then 14 columns per entry:
        date, item_name, price, feedback_date, rating, item_rating,
        communication_rating, dispatch_time_rating, dispatch_charge_rating,
        comment_type, receiver_comment, receiver_reply_date, follow_up, follow_up_date
        """
        soup = BeautifulSoup(content, 'lxml')
        tds = soup.find_all('td')

        logger.info(f"Processing feedback history with {len(tds)} TD elements")

        count = 0
        current_role = None
        i = 0

        while i < len(tds):
            text = tds[i].get_text(strip=True)

            # Check for role marker (BUYER or SELLER section)
            if text == 'Role:' and i + 1 < len(tds):
                current_role = tds[i + 1].get_text(strip=True)
                i += 2
                continue

            # Need at least 14 cells ahead for a complete entry
            if i + 14 > len(tds):
                break

            try:
                date_str = tds[i].get_text(strip=True)
                item_name = tds[i + 1].get_text(strip=True)
                price_str = tds[i + 2].get_text(strip=True)
                rating = tds[i + 4].get_text(strip=True)  # POSITIVE, NEGATIVE, NEUTRAL
                comment = tds[i + 10].get_text(strip=True)  # Receiver comment

                # Skip if not a valid entry start
                # Transaction date is short format "Jan 01, 2025" (~12 chars)
                # Received date has time "Aug 19, 2025 09:29 AM" (~22 chars) - skip these
                is_transaction_date = (
                    ',' in date_str and
                    len(date_str) < 18 and  # Transaction dates are shorter
                    'AM' not in date_str and
                    'PM' not in date_str
                )
                if not is_transaction_date or not item_name or item_name == 'Role:':
                    i += 1
                    continue

                # Only process BUYER feedback (purchases)
                # SELLER feedback is for items we sold, which are in sellingHistory
                if current_role != 'BUYER':
                    i += 14
                    continue

                observed_at = self._parse_date(date_str)

                # Detect category and brand
                category, subcategory = self._detect_category(item_name)
                brand = self._detect_brand(item_name)
                decay_params = self._get_decay_params(category, item_name)

                extra = {
                    "type": "feedback_purchase",
                    "signal_type": "purchased",  # Use same signal type as purchaseHistory
                    "decay_half_life_years": decay_params["half_life_years"],
                    "decay_floor": decay_params["floor"],
                    "feedback_source": True,  # Flag that this came from feedback, not purchase history
                }

                if subcategory:
                    extra["subcategory"] = subcategory

                if brand:
                    extra["brand"] = brand

                # Add price if available
                try:
                    price = float(price_str)
                    extra["price"] = price
                except (ValueError, TypeError):
                    pass

                # Add feedback rating - useful for sentiment analysis
                if rating in ('POSITIVE', 'NEGATIVE', 'NEUTRAL'):
                    extra["feedback_rating"] = rating.lower()

                if comment:
                    extra["feedback_comment"] = comment[:200]  # Truncate long comments

                yield ParsedPreference(
                    subject=item_name,
                    preference_type="Like",
                    category=category,
                    strength=SIGNAL_STRENGTHS["purchase"],  # Same strength as regular purchase
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size=self.classify_size(item_name, category),
                    observed_at=observed_at,
                    extra=extra
                )
                count += 1
                i += 14

            except Exception as e:
                logger.warning(f"Error parsing feedback history row: {e}")
                i += 1
                continue

        logger.info(f"Parsed {count} feedback history items (BUYER only)")

    # ========================================
    # CSV Parsing Methods (Legacy Format)
    # ========================================

    async def _parse_purchases_csv(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse eBay purchase history CSV."""
        logger.info(f"Parsing eBay purchases from CSV: {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                item_title = (row.get('Item title', '') or
                             row.get('Title', '') or
                             row.get('Item', '')).strip()

                purchase_date_str = (row.get('Sale date', '') or
                                    row.get('Purchase Date', '') or
                                    row.get('Order date', '')).strip()

                if not item_title:
                    continue

                timestamp = self._parse_date(purchase_date_str)
                category, subcategory = self._detect_category(item_title)

                extra = {
                    "type": "purchase",
                    "signal_type": "purchased"
                }
                if subcategory:
                    extra["subcategory"] = subcategory

                price_str = (row.get('Total price', '') or
                            row.get('Price', '') or
                            row.get('Sale price', '')).strip()
                if price_str:
                    extra["price"] = price_str

                yield ParsedPreference(
                    subject=item_title,
                    preference_type="Like",
                    category=category,
                    strength=SIGNAL_STRENGTHS["purchase"],
                    observed_at=timestamp,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size=self.classify_size(item_title, category),
                    extra=extra
                )

            except Exception as e:
                logger.warning(f"Error parsing purchase row: {e}")
                continue

    async def _parse_bids_csv(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse eBay bids CSV."""
        logger.info(f"Parsing eBay bids from CSV: {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                item_title = (row.get('Item title', '') or row.get('Title', '')).strip()
                bid_date_str = (row.get('Bid date', '') or row.get('Date', '')).strip()

                if not item_title:
                    continue

                timestamp = self._parse_date(bid_date_str)
                category, subcategory = self._detect_category(item_title)

                extra = {
                    "type": "bid",
                    "signal_type": "bid"
                }
                if subcategory:
                    extra["subcategory"] = subcategory

                yield ParsedPreference(
                    subject=item_title,
                    preference_type="Like",
                    category=category,
                    strength=SIGNAL_STRENGTHS["bid"],
                    observed_at=timestamp,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size=self.classify_size(item_title, category),
                    extra=extra
                )

            except Exception as e:
                logger.warning(f"Error parsing bid row: {e}")
                continue

    async def _parse_watching_csv(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse eBay watching list CSV."""
        logger.info(f"Parsing eBay watching list from CSV: {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                item_title = (row.get('Item title', '') or row.get('Title', '')).strip()

                if not item_title:
                    continue

                category, subcategory = self._detect_category(item_title)

                extra = {
                    "type": "watch",
                    "signal_type": "watched"
                }
                if subcategory:
                    extra["subcategory"] = subcategory

                yield ParsedPreference(
                    subject=item_title,
                    preference_type="Like",
                    category=category,
                    strength=SIGNAL_STRENGTHS["watch"],
                    observed_at=None,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size=self.classify_size(item_title, category),
                    extra=extra
                )

            except Exception as e:
                logger.warning(f"Error parsing watching row: {e}")
                continue

    async def _parse_saved_searches_csv(
        self,
        file_path: Path,
        default_compartment: int
    ) -> AsyncIterator[ParsedPreference]:
        """Parse eBay saved searches CSV."""
        logger.info(f"Parsing eBay saved searches from CSV: {file_path}")

        async with aiofiles.open(file_path, mode='r', encoding='utf-8-sig') as f:
            content = await f.read()

        reader = csv.DictReader(content.splitlines())

        for row in reader:
            try:
                search_name = (row.get('Search name', '') or row.get('Name', '')).strip()

                if not search_name:
                    continue

                category, subcategory = self._detect_category(search_name)

                extra = {
                    "type": "saved_search",
                    "signal_type": "search_pattern"
                }
                if subcategory:
                    extra["subcategory"] = subcategory

                yield ParsedPreference(
                    subject=f"search: {search_name}",
                    preference_type="Pattern",
                    category=category,
                    strength=SIGNAL_STRENGTHS["saved_search"],
                    observed_at=None,
                    source=self.source_name,
                    compartment_level=default_compartment,
                    size="Small",
                    extra=extra
                )

            except Exception as e:
                logger.warning(f"Error parsing saved search row: {e}")
                continue


# Keep the old class name for backwards compatibility
eBayParser = EbayParser
