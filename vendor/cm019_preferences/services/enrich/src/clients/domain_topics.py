"""Domain to topic mapping for bookmark enrichment.

This provides deterministic topic inference from bookmark domains without
needing to fetch URLs (which may be dead after years).

The insight: The domain IS the signal. Bookmarking mckinsey.com 4 times
tells us about business/strategy interests, regardless of specific pages.
"""

import logging
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set
from urllib.parse import urlparse

logger = logging.getLogger(__name__)


@dataclass
class DomainInfo:
    """Information about a domain's topics and classification."""
    topics: List[str]
    category: str
    wikidata_id: Optional[str] = None
    subcategory: Optional[str] = None

    def __post_init__(self):
        # Normalize topics to lowercase with underscores
        self.topics = [t.lower().replace(" ", "_").replace("-", "_") for t in self.topics]


# Comprehensive domain to topic mapping
# Organized by category for maintainability
DOMAIN_MAP: Dict[str, DomainInfo] = {
    # =============================================================================
    # BUSINESS & CONSULTING
    # =============================================================================
    "mckinsey.com": DomainInfo(
        topics=["management_consulting", "business_strategy", "corporate_leadership"],
        category="consulting",
        wikidata_id="Q40909"
    ),
    "bcg.com": DomainInfo(
        topics=["management_consulting", "business_strategy"],
        category="consulting",
        wikidata_id="Q680805"
    ),
    "bain.com": DomainInfo(
        topics=["management_consulting", "business_strategy"],
        category="consulting",
        wikidata_id="Q245093"
    ),
    "hbr.org": DomainInfo(
        topics=["business", "management", "leadership", "strategy"],
        category="business_media",
        wikidata_id="Q2566804"
    ),
    "hbs.edu": DomainInfo(
        topics=["business_education", "mba", "management"],
        category="education",
        wikidata_id="Q1392590"
    ),
    "economist.com": DomainInfo(
        topics=["economics", "business", "politics", "world_news"],
        category="news",
        wikidata_id="Q1063431"
    ),
    "ft.com": DomainInfo(
        topics=["finance", "business", "economics", "markets"],
        category="news",
        wikidata_id="Q212159"
    ),
    "wsj.com": DomainInfo(
        topics=["finance", "business", "markets", "news"],
        category="news",
        wikidata_id="Q164746"
    ),
    "bloomberg.com": DomainInfo(
        topics=["finance", "markets", "business_news", "economics"],
        category="news",
        wikidata_id="Q238964"
    ),
    "forbes.com": DomainInfo(
        topics=["business", "entrepreneurship", "wealth", "leadership"],
        category="business_media",
        wikidata_id="Q241279"
    ),
    "inc.com": DomainInfo(
        topics=["entrepreneurship", "startups", "small_business"],
        category="business_media"
    ),
    "fastcompany.com": DomainInfo(
        topics=["business", "innovation", "technology", "design"],
        category="business_media",
        wikidata_id="Q1396774"
    ),
    "businessinsider.com": DomainInfo(
        topics=["business", "technology", "finance"],
        category="business_media"
    ),

    # =============================================================================
    # TECHNOLOGY & SOFTWARE
    # =============================================================================
    "github.com": DomainInfo(
        topics=["software_development", "open_source", "programming", "version_control"],
        category="developer",
        wikidata_id="Q186055"
    ),
    "gitlab.com": DomainInfo(
        topics=["software_development", "devops", "version_control"],
        category="developer",
        wikidata_id="Q16639197"
    ),
    "stackoverflow.com": DomainInfo(
        topics=["programming", "software_development", "coding"],
        category="developer",
        wikidata_id="Q549037"
    ),
    "medium.com": DomainInfo(
        topics=["blogging", "writing", "technology", "startups"],
        category="publishing",
        wikidata_id="Q19641189"
    ),
    "dev.to": DomainInfo(
        topics=["software_development", "programming", "web_development"],
        category="developer"
    ),
    "hackernews.com": DomainInfo(
        topics=["technology", "startups", "programming"],
        category="tech_news"
    ),
    "news.ycombinator.com": DomainInfo(
        topics=["technology", "startups", "programming", "venture_capital"],
        category="tech_news",
        wikidata_id="Q15568283"
    ),
    "techcrunch.com": DomainInfo(
        topics=["technology", "startups", "venture_capital", "innovation"],
        category="tech_news",
        wikidata_id="Q739529"
    ),
    "wired.com": DomainInfo(
        topics=["technology", "culture", "science", "business"],
        category="tech_media",
        wikidata_id="Q1142885"
    ),
    "theverge.com": DomainInfo(
        topics=["technology", "consumer_electronics", "gaming", "science"],
        category="tech_media",
        wikidata_id="Q2475971"
    ),
    "arstechnica.com": DomainInfo(
        topics=["technology", "science", "gaming", "it"],
        category="tech_media",
        wikidata_id="Q306048"
    ),
    "engadget.com": DomainInfo(
        topics=["consumer_electronics", "technology", "gadgets"],
        category="tech_media",
        wikidata_id="Q620315"
    ),
    "gizmodo.com": DomainInfo(
        topics=["technology", "gadgets", "science"],
        category="tech_media"
    ),
    "slashdot.org": DomainInfo(
        topics=["technology", "open_source", "linux", "programming"],
        category="tech_media",
        wikidata_id="Q207263"
    ),

    # =============================================================================
    # WEB DEVELOPMENT & DESIGN
    # =============================================================================
    "css-tricks.com": DomainInfo(
        topics=["css", "web_development", "frontend", "design"],
        category="developer"
    ),
    "smashingmagazine.com": DomainInfo(
        topics=["web_design", "ux", "frontend", "css", "javascript"],
        category="design",
        wikidata_id="Q2294448"
    ),
    "alistapart.com": DomainInfo(
        topics=["web_design", "web_standards", "accessibility", "ux"],
        category="design"
    ),
    "codepen.io": DomainInfo(
        topics=["frontend", "css", "javascript", "web_development"],
        category="developer"
    ),
    "dribbble.com": DomainInfo(
        topics=["design", "ui_ux", "graphic_design", "portfolio"],
        category="design",
        wikidata_id="Q6475279"
    ),
    "behance.net": DomainInfo(
        topics=["design", "portfolio", "creative", "graphic_design"],
        category="design",
        wikidata_id="Q816tried"
    ),
    "awwwards.com": DomainInfo(
        topics=["web_design", "ui_ux", "digital_design"],
        category="design"
    ),
    "thecssawards.com": DomainInfo(
        topics=["web_design", "css", "frontend"],
        category="design"
    ),
    "sixrevisions.com": DomainInfo(
        topics=["web_design", "web_development", "tutorials"],
        category="design"
    ),
    "webdesignerdepot.com": DomainInfo(
        topics=["web_design", "graphic_design", "ui_ux"],
        category="design"
    ),
    "creativebloq.com": DomainInfo(
        topics=["design", "graphic_design", "web_design", "art"],
        category="design"
    ),
    "designmodo.com": DomainInfo(
        topics=["web_design", "ui_ux", "frameworks"],
        category="design"
    ),
    "sitepoint.com": DomainInfo(
        topics=["web_development", "programming", "design"],
        category="developer"
    ),

    # =============================================================================
    # DIGITAL MARKETING
    # =============================================================================
    "econsultancy.com": DomainInfo(
        topics=["digital_marketing", "ecommerce", "analytics"],
        category="marketing"
    ),
    "moz.com": DomainInfo(
        topics=["seo", "digital_marketing", "analytics"],
        category="marketing",
        wikidata_id="Q6927024"
    ),
    "searchengineland.com": DomainInfo(
        topics=["seo", "sem", "digital_marketing", "ppc"],
        category="marketing"
    ),
    "hubspot.com": DomainInfo(
        topics=["marketing", "sales", "crm", "inbound_marketing"],
        category="marketing",
        wikidata_id="Q5930434"
    ),
    "mailchimp.com": DomainInfo(
        topics=["email_marketing", "marketing_automation"],
        category="marketing",
        wikidata_id="Q6737042"
    ),
    "marketingweek.com": DomainInfo(
        topics=["marketing", "branding", "advertising"],
        category="marketing"
    ),
    "adweek.com": DomainInfo(
        topics=["advertising", "marketing", "media"],
        category="marketing"
    ),
    "adage.com": DomainInfo(
        topics=["advertising", "marketing", "branding"],
        category="marketing"
    ),

    # =============================================================================
    # NEWS & MEDIA
    # =============================================================================
    "theguardian.com": DomainInfo(
        topics=["news", "politics", "culture", "uk_news"],
        category="news",
        wikidata_id="Q11148"
    ),
    "bbc.com": DomainInfo(
        topics=["news", "uk_news", "world_news", "media"],
        category="news",
        wikidata_id="Q9531"
    ),
    "bbc.co.uk": DomainInfo(
        topics=["news", "uk_news", "entertainment", "media"],
        category="news",
        wikidata_id="Q9531"
    ),
    "nytimes.com": DomainInfo(
        topics=["news", "us_news", "politics", "culture"],
        category="news",
        wikidata_id="Q9684"
    ),
    "washingtonpost.com": DomainInfo(
        topics=["news", "us_news", "politics"],
        category="news",
        wikidata_id="Q166032"
    ),
    "reuters.com": DomainInfo(
        topics=["news", "world_news", "finance", "business"],
        category="news",
        wikidata_id="Q83296"
    ),
    "cnn.com": DomainInfo(
        topics=["news", "us_news", "world_news", "politics"],
        category="news",
        wikidata_id="Q48340"
    ),
    "scmp.com": DomainInfo(
        topics=["news", "hong_kong", "asia", "china"],
        category="news",
        wikidata_id="Q755656"
    ),

    # =============================================================================
    # STOCK PHOTOGRAPHY & CREATIVE ASSETS
    # =============================================================================
    "dreamstime.com": DomainInfo(
        topics=["stock_photography", "design", "creative_assets"],
        category="creative"
    ),
    "shutterstock.com": DomainInfo(
        topics=["stock_photography", "stock_video", "creative_assets"],
        category="creative",
        wikidata_id="Q3481754"
    ),
    "istockphoto.com": DomainInfo(
        topics=["stock_photography", "creative_assets"],
        category="creative"
    ),
    "gettyimages.com": DomainInfo(
        topics=["stock_photography", "editorial", "creative_assets"],
        category="creative",
        wikidata_id="Q326491"
    ),
    "unsplash.com": DomainInfo(
        topics=["stock_photography", "free_photos", "creative"],
        category="creative"
    ),
    "pexels.com": DomainInfo(
        topics=["stock_photography", "free_photos", "stock_video"],
        category="creative"
    ),
    "absolutvision.com": DomainInfo(
        topics=["stock_photography", "royalty_free"],
        category="creative"
    ),
    "clipart.com": DomainInfo(
        topics=["clipart", "design", "creative_assets"],
        category="creative"
    ),

    # =============================================================================
    # CLOUD & DEVELOPER TOOLS
    # =============================================================================
    "aws.amazon.com": DomainInfo(
        topics=["cloud_computing", "aws", "infrastructure", "devops"],
        category="cloud",
        wikidata_id="Q456157"
    ),
    "cloud.google.com": DomainInfo(
        topics=["cloud_computing", "gcp", "infrastructure"],
        category="cloud",
        wikidata_id="Q5571145"
    ),
    "azure.microsoft.com": DomainInfo(
        topics=["cloud_computing", "azure", "microsoft"],
        category="cloud",
        wikidata_id="Q725967"
    ),
    "digitalocean.com": DomainInfo(
        topics=["cloud_computing", "hosting", "vps"],
        category="cloud"
    ),
    "heroku.com": DomainInfo(
        topics=["cloud_computing", "paas", "deployment"],
        category="cloud",
        wikidata_id="Q906620"
    ),
    "netlify.com": DomainInfo(
        topics=["web_hosting", "jamstack", "deployment"],
        category="cloud"
    ),
    "vercel.com": DomainInfo(
        topics=["web_hosting", "nextjs", "frontend", "deployment"],
        category="cloud"
    ),
    "docker.com": DomainInfo(
        topics=["containers", "devops", "docker"],
        category="developer",
        wikidata_id="Q15206305"
    ),
    "kubernetes.io": DomainInfo(
        topics=["kubernetes", "containers", "orchestration", "devops"],
        category="developer",
        wikidata_id="Q22661306"
    ),

    # =============================================================================
    # APIS & INTEGRATION
    # =============================================================================
    "stripe.com": DomainInfo(
        topics=["payments", "fintech", "api", "ecommerce"],
        category="developer",
        wikidata_id="Q7624104"
    ),
    "twilio.com": DomainInfo(
        topics=["communications", "api", "sms", "voip"],
        category="developer",
        wikidata_id="Q7857744"
    ),
    "mulesoft.com": DomainInfo(
        topics=["api", "integration", "enterprise"],
        category="developer"
    ),
    "zapier.com": DomainInfo(
        topics=["automation", "integration", "no_code"],
        category="productivity"
    ),
    "ifttt.com": DomainInfo(
        topics=["automation", "smart_home", "integration"],
        category="productivity"
    ),

    # =============================================================================
    # APPLE ECOSYSTEM
    # =============================================================================
    "apple.com": DomainInfo(
        topics=["apple", "technology", "consumer_electronics"],
        category="technology",
        wikidata_id="Q312"
    ),
    "developer.apple.com": DomainInfo(
        topics=["ios_development", "macos", "swift", "apple"],
        category="developer"
    ),
    "9to5mac.com": DomainInfo(
        topics=["apple", "ios", "macos", "technology"],
        category="tech_media"
    ),
    "macrumors.com": DomainInfo(
        topics=["apple", "ios", "macos", "rumors"],
        category="tech_media"
    ),

    # =============================================================================
    # GOOGLE ECOSYSTEM
    # =============================================================================
    "google.com": DomainInfo(
        topics=["google", "search", "technology"],
        category="technology",
        wikidata_id="Q95"
    ),
    "developers.google.com": DomainInfo(
        topics=["google", "android", "web_development", "api"],
        category="developer"
    ),
    "analytics.google.com": DomainInfo(
        topics=["analytics", "marketing", "data"],
        category="marketing"
    ),

    # =============================================================================
    # SOCIAL & PRODUCTIVITY
    # =============================================================================
    "twitter.com": DomainInfo(
        topics=["social_media", "news", "networking"],
        category="social",
        wikidata_id="Q918"
    ),
    "x.com": DomainInfo(
        topics=["social_media", "news", "networking"],
        category="social",
        wikidata_id="Q918"
    ),
    "linkedin.com": DomainInfo(
        topics=["professional_networking", "career", "business"],
        category="social",
        wikidata_id="Q213660"
    ),
    "facebook.com": DomainInfo(
        topics=["social_media", "networking"],
        category="social",
        wikidata_id="Q355"
    ),
    "instagram.com": DomainInfo(
        topics=["social_media", "photography", "visual"],
        category="social",
        wikidata_id="Q209330"
    ),
    "reddit.com": DomainInfo(
        topics=["social_media", "community", "forums"],
        category="social",
        wikidata_id="Q1136"
    ),
    "slack.com": DomainInfo(
        topics=["team_communication", "collaboration", "productivity"],
        category="productivity",
        wikidata_id="Q15965524"
    ),
    "notion.so": DomainInfo(
        topics=["productivity", "note_taking", "project_management"],
        category="productivity"
    ),
    "trello.com": DomainInfo(
        topics=["project_management", "productivity", "kanban"],
        category="productivity",
        wikidata_id="Q15099490"
    ),
    "asana.com": DomainInfo(
        topics=["project_management", "productivity", "teamwork"],
        category="productivity"
    ),

    # =============================================================================
    # E-COMMERCE
    # =============================================================================
    "amazon.com": DomainInfo(
        topics=["ecommerce", "shopping", "retail"],
        category="ecommerce",
        wikidata_id="Q3884"
    ),
    "ebay.com": DomainInfo(
        topics=["ecommerce", "auctions", "marketplace"],
        category="ecommerce",
        wikidata_id="Q58024"
    ),
    "etsy.com": DomainInfo(
        topics=["ecommerce", "handmade", "crafts", "vintage"],
        category="ecommerce",
        wikidata_id="Q1370378"
    ),
    "shopify.com": DomainInfo(
        topics=["ecommerce", "retail", "small_business"],
        category="ecommerce",
        wikidata_id="Q4418214"
    ),
    "alibaba.com": DomainInfo(
        topics=["ecommerce", "wholesale", "b2b", "china"],
        category="ecommerce",
        wikidata_id="Q306706"
    ),

    # =============================================================================
    # EDUCATION & LEARNING
    # =============================================================================
    "coursera.org": DomainInfo(
        topics=["online_learning", "mooc", "education"],
        category="education",
        wikidata_id="Q2996297"
    ),
    "udemy.com": DomainInfo(
        topics=["online_learning", "courses", "education"],
        category="education",
        wikidata_id="Q5865118"
    ),
    "edx.org": DomainInfo(
        topics=["online_learning", "mooc", "education"],
        category="education",
        wikidata_id="Q10378835"
    ),
    "khanacademy.org": DomainInfo(
        topics=["education", "learning", "tutorials"],
        category="education",
        wikidata_id="Q1151120"
    ),
    "skillshare.com": DomainInfo(
        topics=["online_learning", "creative", "design"],
        category="education"
    ),
    "lynda.com": DomainInfo(
        topics=["online_learning", "professional_development"],
        category="education"
    ),
    "pluralsight.com": DomainInfo(
        topics=["technology_training", "software_development", "it"],
        category="education"
    ),
    "codecademy.com": DomainInfo(
        topics=["programming", "coding", "education"],
        category="education"
    ),
    "freecodecamp.org": DomainInfo(
        topics=["programming", "web_development", "education"],
        category="education"
    ),

    # =============================================================================
    # SCIENCE & RESEARCH
    # =============================================================================
    "arxiv.org": DomainInfo(
        topics=["academic_research", "physics", "computer_science", "preprints"],
        category="academic",
        wikidata_id="Q118398"
    ),
    "nature.com": DomainInfo(
        topics=["science", "research", "academic"],
        category="academic",
        wikidata_id="Q180445"
    ),
    "sciencedirect.com": DomainInfo(
        topics=["academic_research", "journals", "science"],
        category="academic"
    ),
    "researchgate.net": DomainInfo(
        topics=["academic_research", "networking", "science"],
        category="academic",
        wikidata_id="Q752937"
    ),
    "scholar.google.com": DomainInfo(
        topics=["academic_research", "citations", "papers"],
        category="academic"
    ),

    # =============================================================================
    # AI & DATA SCIENCE
    # =============================================================================
    "openai.com": DomainInfo(
        topics=["artificial_intelligence", "machine_learning", "gpt"],
        category="ai",
        wikidata_id="Q21708200"
    ),
    "huggingface.co": DomainInfo(
        topics=["machine_learning", "nlp", "transformers"],
        category="ai"
    ),
    "kaggle.com": DomainInfo(
        topics=["data_science", "machine_learning", "competitions"],
        category="ai",
        wikidata_id="Q14463848"
    ),
    "towardsdatascience.com": DomainInfo(
        topics=["data_science", "machine_learning", "analytics"],
        category="ai"
    ),
    "tensorflow.org": DomainInfo(
        topics=["machine_learning", "deep_learning", "tensorflow"],
        category="ai",
        wikidata_id="Q21447879"
    ),
    "pytorch.org": DomainInfo(
        topics=["machine_learning", "deep_learning", "pytorch"],
        category="ai",
        wikidata_id="Q28865365"
    ),

    # =============================================================================
    # HONG KONG & ASIA SPECIFIC
    # =============================================================================
    "openrice.com": DomainInfo(
        topics=["restaurants", "food", "hong_kong", "dining"],
        category="local",
        wikidata_id="Q7096098"
    ),
    "hk01.com": DomainInfo(
        topics=["news", "hong_kong", "local_news"],
        category="news"
    ),
    "thestandard.com.hk": DomainInfo(
        topics=["news", "hong_kong", "business"],
        category="news"
    ),
    "timeout.com.hk": DomainInfo(
        topics=["lifestyle", "hong_kong", "entertainment", "dining"],
        category="lifestyle"
    ),
    "discoverhongkong.com": DomainInfo(
        topics=["travel", "hong_kong", "tourism"],
        category="travel"
    ),
    "gocarsite.com": DomainInfo(
        topics=["automotive", "cars", "hong_kong"],
        category="automotive"
    ),
    "automall.com.hk": DomainInfo(
        topics=["automotive", "cars", "hong_kong"],
        category="automotive"
    ),
    "littlestepsasia.com": DomainInfo(
        topics=["parenting", "family", "hong_kong", "kids"],
        category="lifestyle"
    ),

    # =============================================================================
    # ENTERTAINMENT & MEDIA
    # =============================================================================
    "imdb.com": DomainInfo(
        topics=["movies", "tv", "entertainment", "celebrities"],
        category="entertainment",
        wikidata_id="Q37312"
    ),
    "rottentomatoes.com": DomainInfo(
        topics=["movies", "tv", "reviews"],
        category="entertainment"
    ),
    "netflix.com": DomainInfo(
        topics=["streaming", "movies", "tv"],
        category="entertainment",
        wikidata_id="Q907311"
    ),
    "spotify.com": DomainInfo(
        topics=["music", "streaming", "podcasts"],
        category="entertainment",
        wikidata_id="Q689141"
    ),
    "youtube.com": DomainInfo(
        topics=["video", "streaming", "entertainment"],
        category="entertainment",
        wikidata_id="Q866"
    ),
    "twitch.tv": DomainInfo(
        topics=["gaming", "streaming", "esports"],
        category="entertainment",
        wikidata_id="Q1066593"
    ),

    # =============================================================================
    # TRAVEL
    # =============================================================================
    "tripadvisor.com": DomainInfo(
        topics=["travel", "hotels", "restaurants", "reviews"],
        category="travel",
        wikidata_id="Q1234311"
    ),
    "booking.com": DomainInfo(
        topics=["travel", "hotels", "accommodation"],
        category="travel",
        wikidata_id="Q5316366"
    ),
    "airbnb.com": DomainInfo(
        topics=["travel", "accommodation", "vacation_rentals"],
        category="travel",
        wikidata_id="Q7621455"
    ),
    "expedia.com": DomainInfo(
        topics=["travel", "flights", "hotels"],
        category="travel",
        wikidata_id="Q837147"
    ),
    "lonelyplanet.com": DomainInfo(
        topics=["travel", "guides", "destinations"],
        category="travel",
        wikidata_id="Q1755953"
    ),

    # =============================================================================
    # FINANCE & FINTECH
    # =============================================================================
    "robinhood.com": DomainInfo(
        topics=["investing", "stocks", "fintech"],
        category="finance"
    ),
    "coinbase.com": DomainInfo(
        topics=["cryptocurrency", "bitcoin", "fintech"],
        category="finance",
        wikidata_id="Q16951649"
    ),
    "investopedia.com": DomainInfo(
        topics=["investing", "finance", "education"],
        category="finance"
    ),
    "morningstar.com": DomainInfo(
        topics=["investing", "funds", "analysis"],
        category="finance",
        wikidata_id="Q1946217"
    ),
    "seekingalpha.com": DomainInfo(
        topics=["investing", "stocks", "analysis"],
        category="finance"
    ),

    # =============================================================================
    # PRODUCTIVITY & TOOLS
    # =============================================================================
    "evernote.com": DomainInfo(
        topics=["note_taking", "productivity", "organization"],
        category="productivity",
        wikidata_id="Q1351764"
    ),
    "todoist.com": DomainInfo(
        topics=["task_management", "productivity", "gtd"],
        category="productivity"
    ),
    "1password.com": DomainInfo(
        topics=["security", "passwords", "privacy"],
        category="security"
    ),
    "lastpass.com": DomainInfo(
        topics=["security", "passwords", "privacy"],
        category="security"
    ),
    "dropbox.com": DomainInfo(
        topics=["cloud_storage", "file_sharing", "productivity"],
        category="productivity",
        wikidata_id="Q201167"
    ),
    "drive.google.com": DomainInfo(
        topics=["cloud_storage", "productivity", "google"],
        category="productivity"
    ),

    # =============================================================================
    # DOCUMENTATION & WIKIS
    # =============================================================================
    "wikipedia.org": DomainInfo(
        topics=["encyclopedia", "reference", "knowledge"],
        category="reference",
        wikidata_id="Q52"
    ),
    "docs.python.org": DomainInfo(
        topics=["python", "programming", "documentation"],
        category="documentation"
    ),
    "developer.mozilla.org": DomainInfo(
        topics=["web_development", "javascript", "html", "css"],
        category="documentation"
    ),
    "w3schools.com": DomainInfo(
        topics=["web_development", "tutorials", "html", "css"],
        category="education"
    ),
}


class DomainTopicMapper:
    """Maps domains to topics for bookmark enrichment."""

    def __init__(self):
        self._domain_map = DOMAIN_MAP
        self._cache: Dict[str, Optional[DomainInfo]] = {}

    def lookup(self, domain: str) -> Optional[DomainInfo]:
        """Look up topics for a domain.

        Args:
            domain: Domain name (e.g., "mckinsey.com")

        Returns:
            DomainInfo if found, None otherwise
        """
        if not domain:
            return None

        # Normalize domain
        domain = domain.lower().strip()

        # Check cache
        if domain in self._cache:
            return self._cache[domain]

        # Direct lookup
        if domain in self._domain_map:
            self._cache[domain] = self._domain_map[domain]
            return self._domain_map[domain]

        # Try without www.
        if domain.startswith("www."):
            base_domain = domain[4:]
            if base_domain in self._domain_map:
                self._cache[domain] = self._domain_map[base_domain]
                return self._domain_map[base_domain]

        # Try parent domain (e.g., blog.example.com -> example.com)
        parts = domain.split(".")
        if len(parts) > 2:
            parent = ".".join(parts[-2:])
            if parent in self._domain_map:
                self._cache[domain] = self._domain_map[parent]
                return self._domain_map[parent]

        # No match
        self._cache[domain] = None
        return None

    def lookup_url(self, url: str) -> Optional[DomainInfo]:
        """Extract domain from URL and look up topics.

        Args:
            url: Full URL

        Returns:
            DomainInfo if domain found and mapped, None otherwise
        """
        try:
            parsed = urlparse(url)
            domain = parsed.netloc or parsed.path.split("/")[0]
            return self.lookup(domain)
        except Exception:
            return None

    def get_tld_category(self, domain: str) -> Optional[str]:
        """Infer category from TLD when domain not in map.

        Args:
            domain: Domain name

        Returns:
            Inferred category or None
        """
        if not domain:
            return None

        domain = domain.lower()

        # Educational
        if domain.endswith(".edu") or domain.endswith(".ac.uk"):
            return "education"

        # Government
        if domain.endswith(".gov") or domain.endswith(".gov.uk"):
            return "government"

        # Organization
        if domain.endswith(".org"):
            return "organization"

        # Regional
        if domain.endswith(".hk"):
            return "hong_kong"
        if domain.endswith(".uk") or domain.endswith(".co.uk"):
            return "uk"
        if domain.endswith(".cn"):
            return "china"

        return None

    def batch_lookup(self, domains: List[str]) -> Dict[str, Optional[DomainInfo]]:
        """Look up multiple domains at once.

        Args:
            domains: List of domain names

        Returns:
            Dict mapping domain -> DomainInfo (or None)
        """
        return {domain: self.lookup(domain) for domain in domains}

    def get_stats(self) -> Dict[str, int]:
        """Get mapping statistics."""
        return {
            "total_domains": len(self._domain_map),
            "cached_lookups": len(self._cache),
            "cache_hits": sum(1 for v in self._cache.values() if v is not None),
            "cache_misses": sum(1 for v in self._cache.values() if v is None),
        }

    def get_all_topics(self) -> Set[str]:
        """Get all unique topics in the mapping."""
        topics = set()
        for info in self._domain_map.values():
            topics.update(info.topics)
        return topics

    def get_domains_by_category(self, category: str) -> List[str]:
        """Get all domains in a category."""
        return [
            domain for domain, info in self._domain_map.items()
            if info.category == category
        ]


# Convenience function
def lookup_domain(domain: str) -> Optional[DomainInfo]:
    """Look up topics for a domain (convenience function)."""
    mapper = DomainTopicMapper()
    return mapper.lookup(domain)
