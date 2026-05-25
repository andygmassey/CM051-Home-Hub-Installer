"""
Email Intelligence - Preference extraction from email archives.
"""

from .filters import EmailFilter, DomainFilter, LabelFilter, ContentFilter
from .parsers.mbox_parser import MboxParser, ParsedEmail, parse_mbox

__all__ = [
    'EmailFilter',
    'DomainFilter',
    'LabelFilter',
    'ContentFilter',
    'MboxParser',
    'ParsedEmail',
    'parse_mbox',
]
