"""
Email parsers for various formats.
"""

from .mbox_parser import MboxParser, ParsedEmail, parse_mbox
from .fast_mbox_parser import FastMboxParser, FastEmail, fast_parse

__all__ = [
    'MboxParser',
    'ParsedEmail',
    'parse_mbox',
    'FastMboxParser',
    'FastEmail',
    'fast_parse',
]
