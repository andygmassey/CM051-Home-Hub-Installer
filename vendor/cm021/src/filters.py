"""
Email Signal Quality Filters

Configures which emails to process and how to weight their signals.
Based on MBOX analysis (2026-01-16) and user preferences.
"""

from dataclasses import dataclass, field
from typing import Set, Dict, List, Optional
from enum import Enum
import re


class SignalWeight(Enum):
    """Signal strength weights."""
    EXCLUDE = 0.0      # Don't process
    VERY_LOW = 0.2     # Noise, but might have occasional value
    LOW = 0.4          # General notifications
    MEDIUM = 0.6       # Newsletters, some engagement
    HIGH = 0.8         # Active subscriptions, purchases
    VERY_HIGH = 0.95   # Starred, explicitly marked important


@dataclass
class DomainFilter:
    """Configures domain-level filtering."""

    # EXCLUDE - These domains are pure noise
    # User confirmed: Quora, Pinterest, SCMP, Puck
    # NOTE: LinkedIn split - notifications excluded, recruiter emails kept
    exclude_domains: Set[str] = field(default_factory=lambda: {
        # Social notification spam (but NOT recruiter InMails)
        'quora.com',              # Random question digests
        'pinterest.com',          # Visual pins, can't extract meaning
        'discover.pinterest.com',
        'explore.pinterest.com',
        'bebee.com',              # Social noise
        'notification.bebee.com',
        'facebook.com',           # Notifications
        'twitter.com',            # Notifications
        'instagram.com',          # Notifications
        'tiktok.com',             # Notifications

        # News (not personalized)
        'scmp.com',               # South China Morning Post
        'e.scmp.com',
        'puck.news',              # Not personalized

        # Gift cards (exclude per user request)
        'giftcards.',             # Partial match
    })

    # EXCLUDE patterns (regex)
    exclude_patterns: List[str] = field(default_factory=lambda: [
        r'.*giftcard.*',          # Gift card domains
        # LinkedIn notification addresses (but NOT recruiter InMails)
        r'jobalerts-noreply@linkedin\.com',
        r'notifications-noreply@linkedin\.com',
        r'messages-noreply@linkedin\.com',  # Auto-notifications, not actual messages
        r'invitations@linkedin\.com',
    ])

    # LinkedIn recruiter patterns to KEEP (override exclude)
    linkedin_recruiter_patterns: List[str] = field(default_factory=lambda: [
        r'inmails?@linkedin\.com',         # Recruiter InMails
        r'recruiter.*@linkedin\.com',      # Recruiter messages
    ])

    # HIGH-VALUE transactional domains
    transactional_domains: Set[str] = field(default_factory=lambda: {
        # Major retailers
        'amazon.com', 'amazon.co.uk', 'amazon.de',
        'apple.com', 'insideapple.apple.com', 'email.apple.com',
        'paypal.com',
        'stripe.com',

        # Fashion/Retail
        'grailed.com', 'mail.grailed.com',
        'nike.com',
        'adidas.com',
        'uniqlo.com',
        # NOTE: operator-specific retailer entries were stripped on
        # 2026-05-26 during the CX-83 vendoring. CM021 upstream has
        # them baked in; the productised customer build keeps the
        # list operator-agnostic. v1.1 task: rebase CM021 upstream
        # to make these locale-driven instead of hard-coded.
        'saintandsofia.com',
        'net-a-porter.com',
        'mrporter.com',

        # Marketplaces
        'aliexpress.com', 'mail.aliexpress.com', 'deals.aliexpress.com',
        'buyee.jp',
        'ebay.com',

        # Services
        'uber.com',
        'ubereats.com',
        'deliveroo.com',
        'airbnb.com',
        'booking.com',
        'expedia.com',

        # Streaming/Digital
        'netflix.com',
        'spotify.com',
        'steampowered.com',
    })

    # Newsletter domains (keep for topic extraction)
    newsletter_domains: Set[str] = field(default_factory=lambda: {
        # Newsletter platforms
        'substack.com',
        'beehiiv.com', 'mail.beehiiv.com',
        'buttondown.email',
        'convertkit.com',
        'mailchimp.com',

        # Known valuable newsletters
        'tldrnewsletter.com',
        'morningbrew.com',
        'emails.hbr.org',
        'email.mckinsey.com',
        'email.businessoffashion.com',
        'divenewsletter.com',
        'therobinreport.com',
        'yankodesign.com',
        'uncrate.com',
        'digest.producthunt.com',
    })

    # Investment/Finance domains (keep per user request)
    investment_domains: Set[str] = field(default_factory=lambda: {
        'quiverquant.com',
        'news.crowdcube.com',
        'angel.co',
        'seedrs.com',
        # Note: Exclude bank statements unless user opts in
    })

    # Recruiter domains (keep per user request, refine later)
    recruiter_domains: Set[str] = field(default_factory=lambda: {
        'e.jobsdb.com',
        'mail3.ctgoodjobsnews.hk',
        'mail3.ctgoodjobsalert.hk',
        'careers.businessoffashion.com',
        # LinkedIn recruiter emails excluded at domain level
    })


@dataclass
class LabelFilter:
    """Configures Gmail label-based filtering."""

    # Priority labels - process these first with high confidence
    priority_labels: Dict[str, SignalWeight] = field(default_factory=lambda: {
        'Category purchases': SignalWeight.HIGH,
        'Category travel': SignalWeight.HIGH,
        'Category bills': SignalWeight.MEDIUM,
        'Starred': SignalWeight.VERY_HIGH,
    })

    # Weight boosters - increase signal strength when present
    weight_boosters: Dict[str, float] = field(default_factory=lambda: {
        'Important': 1.2,      # Gmail marked as important
        'Starred': 1.5,        # User starred
        'Opened': 1.1,         # User read it
    })

    # Unread handling is CONTEXT-DEPENDENT (not a flat boost)
    # - In high-value category + Unread → likely "want to come back to" → boost
    # - In low-value category + Unread → likely "didn't have time" → no boost
    # See calculate_weight_boost_contextual() for implementation

    # Exclude labels
    exclude_labels: Set[str] = field(default_factory=lambda: {
        'Spam',
        'Bin',                 # Deleted
        'Category social',     # Social notifications (Facebook, etc.)
    })

    # Negative signal labels (track as dislikes)
    negative_signal_labels: Set[str] = field(default_factory=lambda: {
        'Unsubscribed',
        # Also check subject for "unsubscribe confirmation"
    })


@dataclass
class ContentFilter:
    """Content-based signal detection patterns."""

    # Order/Transaction patterns
    order_patterns: List[str] = field(default_factory=lambda: [
        r'order\s*(#|confirmation|confirmed|received)',
        r'receipt\s*(for|from)',
        r'your\s*purchase',
        r'shipping\s*(confirmation|update|notification)',
        r'delivery\s*(scheduled|confirmed|update)',
        r'tracking\s*(number|info)',
        r'invoice\s*(#|for)',
        r'payment\s*(received|confirmed|successful)',
    ])

    # Return/Refund patterns (negative signals)
    return_patterns: List[str] = field(default_factory=lambda: [
        r'return\s*(confirmation|approved|processed|request)',
        r'refund\s*(processed|issued|confirmation)',
        r'cancellation\s*confirmed',
        r'order\s*cancelled',
    ])

    # Subscription patterns
    subscription_patterns: List[str] = field(default_factory=lambda: [
        r'your\s*subscription',
        r'membership\s*(renewal|update)',
        r'billing\s*statement',
        r'subscription\s*confirmation',
    ])

    # Newsletter patterns
    newsletter_patterns: List[str] = field(default_factory=lambda: [
        r'unsubscribe',        # All newsletters have this
        r'view\s*in\s*browser',
        r'\bweekly\b',
        r'\bmonthly\b',
        r'\bdigest\b',
        r'\bedition\b',
        r'\bissue\s*#?\d+\b',
    ])


class EmailFilter:
    """Main filter class for email processing."""

    def __init__(
        self,
        domain_filter: Optional[DomainFilter] = None,
        label_filter: Optional[LabelFilter] = None,
        content_filter: Optional[ContentFilter] = None,
    ):
        self.domain = domain_filter or DomainFilter()
        self.label = label_filter or LabelFilter()
        self.content = content_filter or ContentFilter()

    def should_exclude_domain(self, domain: str) -> bool:
        """Check if domain should be excluded."""
        domain = domain.lower()

        # Direct exclusion
        if domain in self.domain.exclude_domains:
            return True

        # Partial match exclusion
        for excluded in self.domain.exclude_domains:
            if excluded in domain:
                return True

        # Pattern exclusion (note: these are for email addresses, not domains)
        # Domain-level patterns handled separately
        return False

    def should_exclude_email(self, email_address: str, domain: str = None) -> tuple[bool, str]:
        """
        Check if email address should be excluded.

        Returns (should_exclude, reason).

        LinkedIn special handling:
        - Exclude: notifications, job alerts, invitations, auto-messages
        - Keep: InMails (recruiter outreach), actual recruiter messages
        """
        email_lower = email_address.lower()
        domain = domain or email_lower.split('@')[-1] if '@' in email_lower else ''

        # First check if it's a LinkedIn email - special handling
        if 'linkedin.com' in domain:
            # Check if it's a recruiter/InMail (KEEP these)
            for pattern in self.domain.linkedin_recruiter_patterns:
                if re.match(pattern, email_lower, re.IGNORECASE):
                    return False, "linkedin_recruiter"  # Keep

            # Check if it's a notification (EXCLUDE these)
            for pattern in self.domain.exclude_patterns:
                if re.match(pattern, email_lower, re.IGNORECASE):
                    return True, "linkedin_notification"  # Exclude

            # Unknown LinkedIn address - default to keep (might be human message)
            return False, "linkedin_other"

        # Check domain exclusion for non-LinkedIn
        if self.should_exclude_domain(domain):
            return True, "domain_excluded"

        # Check pattern exclusion for non-LinkedIn
        for pattern in self.domain.exclude_patterns:
            if re.match(pattern, email_lower, re.IGNORECASE):
                return True, "pattern_excluded"

        return False, "not_excluded"

    def should_exclude_labels(self, labels: List[str]) -> bool:
        """Check if email should be excluded based on labels."""
        for label in labels:
            if label in self.label.exclude_labels:
                return True
        return False

    def get_domain_category(self, domain: str) -> str:
        """Categorize domain for routing."""
        domain = domain.lower()

        # Check each category
        for d in self.domain.transactional_domains:
            if d in domain:
                return 'transactional'

        for d in self.domain.newsletter_domains:
            if d in domain:
                return 'newsletter'

        for d in self.domain.investment_domains:
            if d in domain:
                return 'investment'

        for d in self.domain.recruiter_domains:
            if d in domain:
                return 'recruiter'

        return 'unknown'

    def get_priority_category(self, labels: List[str]) -> Optional[str]:
        """Get priority category from Gmail labels."""
        for label in labels:
            if label in self.label.priority_labels:
                if label == 'Category purchases':
                    return 'order'
                elif label == 'Category travel':
                    return 'travel'
                elif label == 'Category bills':
                    return 'subscription'
                elif label == 'Starred':
                    return 'starred'
        return None

    def calculate_weight_boost(self, labels: List[str]) -> float:
        """Calculate weight multiplier from labels (basic version)."""
        boost = 1.0
        for label in labels:
            if label in self.label.weight_boosters:
                boost *= self.label.weight_boosters[label]
        return boost

    def calculate_weight_boost_contextual(
        self,
        labels: List[str],
        category: str,
        is_high_value: bool = False
    ) -> float:
        """
        Calculate weight multiplier with context-dependent Unread handling.

        Args:
            labels: Gmail labels
            category: Email category (order, newsletter, etc.)
            is_high_value: Whether email is in a high-value category

        The Unread label has different meaning depending on context:
        - High-value category + Unread = "want to come back to" → boost
        - Low-value category + Unread = "didn't have time for noise" → no boost
        """
        boost = 1.0

        # Apply standard boosters
        for label in labels:
            if label in self.label.weight_boosters:
                boost *= self.label.weight_boosters[label]

        # Context-dependent Unread handling
        if 'Unread' in labels:
            high_value_categories = {'order', 'travel', 'subscription', 'correspondence'}
            if is_high_value or category in high_value_categories:
                # Unread in high-value = "want to come back" → boost
                boost *= 1.15
            # else: Unread in low-value = "didn't have time" → no boost

        return boost

    def is_likely_order_email(self, subject: str, body: str) -> bool:
        """
        Check if email is likely an order confirmation vs marketing.

        More intelligent than just domain matching.
        Looks for order-specific content patterns.
        """
        text = f"{subject} {body[:500]}".lower()

        # Strong order indicators
        order_indicators = [
            r'order\s*(#|number|confirmation|confirmed)',
            r'order\s*id\s*[:\s]',
            r'thank\s*you\s*for\s*(your\s*)?(order|purchase)',
            r'receipt\s*(for|from|#)',
            r'shipping\s*address',
            r'delivery\s*address',
            r'tracking\s*(number|#)',
            r'your\s*order\s*(has\s*been|is)',
            r'payment\s*(received|confirmed|successful)',
            r'invoice\s*(#|number)',
        ]

        # Marketing indicators (if these dominate, it's not an order)
        marketing_indicators = [
            r'\d+%\s*off',
            r'sale\s*(ends|now|today)',
            r'shop\s*now',
            r'new\s*arrivals?',
            r'just\s*landed',
            r'trending',
            r'you\s*might\s*(also\s*)?like',
            r'recommended\s*for\s*you',
            r'view\s*in\s*browser',
            r'unsubscribe',
        ]

        order_score = sum(1 for p in order_indicators if re.search(p, text))
        marketing_score = sum(1 for p in marketing_indicators if re.search(p, text))

        # Order if order signals dominate
        return order_score >= 2 or (order_score >= 1 and marketing_score <= 1)

    def is_negative_signal(self, labels: List[str], subject: str) -> bool:
        """Check if this represents a negative preference signal."""
        # Label-based
        for label in labels:
            if label in self.label.negative_signal_labels:
                return True

        # Subject-based (returns, refunds)
        subject_lower = subject.lower()
        for pattern in self.content.return_patterns:
            if re.search(pattern, subject_lower):
                return True

        return False

    def classify_content(self, subject: str, body: str = '') -> str:
        """Classify email by content patterns."""
        text = f"{subject} {body}".lower()

        # Check each category
        for pattern in self.content.order_patterns:
            if re.search(pattern, text):
                return 'order'

        for pattern in self.content.subscription_patterns:
            if re.search(pattern, text):
                return 'subscription'

        for pattern in self.content.newsletter_patterns:
            if re.search(pattern, text):
                return 'newsletter'

        return 'unknown'


# Default filter instance
default_filter = EmailFilter()
