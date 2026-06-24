"""Data source parsers."""

from .base import BaseParser, ParsedPreference, derive_doc_id
from .csv_parser import CSVParser
from .google_takeout import GoogleTakeoutParser
from .spotify import SpotifyParser
from .meta import MetaParser
from .amazon import AmazonParser
from .linkedin import LinkedInParser
from .reddit import RedditParser
from .apple import AppleParser
from .twitter import TwitterParser
from .youtube import YouTubeParser
from .ebay import eBayParser
from .tiktok import TikTokParser
from .pinterest import PinterestParser
from .uber import UberParser
from .whoop import WhoopParser
from .disney import DisneyPlusParser
from .whatsapp import WhatsAppParser
from .discord import DiscordParser
from .netflix import NetflixParser
from .appletv import AppleTVParser
from .email import EmailParser
from .foursquare import FoursquareParser
from .content_preferences import ContentPreferenceParser, extract_preferences

__all__ = [
    "BaseParser",
    "ParsedPreference",
    "derive_doc_id",
    "CSVParser",
    "GoogleTakeoutParser",
    "SpotifyParser",
    "MetaParser",
    "AmazonParser",
    "LinkedInParser",
    "RedditParser",
    "AppleParser",
    "TwitterParser",
    "YouTubeParser",
    "eBayParser",
    "TikTokParser",
    "PinterestParser",
    "UberParser",
    "WhoopParser",
    "DisneyPlusParser",
    "WhatsAppParser",
    "DiscordParser",
    "NetflixParser",
    "AppleTVParser",
    "EmailParser",
    "FoursquareParser",
    "ContentPreferenceParser",
    "extract_preferences"
]
