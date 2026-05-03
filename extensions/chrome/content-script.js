/**
 * Safari History Extension (Chrome) - Content Script
 * Captures page content and sends to PWG Gateway for preference extraction.
 *
 * Features:
 * - Privacy-first URL filtering (banking, medical, auth, etc.)
 * - HTML sanitisation (strips forms, scripts, sensitive attributes)
 * - SPA navigation handling (History API interception)
 * - Debouncing (2.5s dwell time before capture)
 */

(() => {
  // ===================
  // Configuration
  // ===================
  const DEBOUNCE_MS = 2500; // Wait 2.5s before capturing
  const MAX_HTML_SIZE = 500000; // 500KB

  // ===================
  // Privacy-First URL Filtering
  // ===================
  const SENSITIVE_PATTERNS = {
    // Banking & Finance
    banking: [
      /bank/i, /chase\.com/, /wellsfargo\.com/, /hsbc/i, /citi/i,
      /paypal\.com/, /venmo\.com/, /wise\.com/, /revolut\.com/,
      /capitalone/i, /barclays/i, /santander/i
    ],

    // Medical & Health
    medical: [
      /health/i, /medical/i, /patient/i, /mychart/i, /hospital/i,
      /doctor/i, /pharmacy/i, /\.gov.*health/i, /nhs\.uk/i,
      /webmd/i, /mayoclinic/i, /cvs\.com/i, /walgreens/i
    ],

    // Authentication & Security
    auth: [
      /login/i, /signin/i, /sign-in/i, /password/i, /oauth/i,
      /account.*security/i, /2fa/i, /mfa/i, /verify/i,
      /forgot.*password/i, /reset.*password/i
    ],

    // Financial Services
    finance: [
      /trading/i, /brokerage/i, /fidelity\.com/, /schwab\.com/,
      /vanguard\.com/, /crypto/i, /wallet/i, /invest/i,
      /robinhood/i, /coinbase/i, /binance/i, /etrade/i
    ],

    // Personal Records
    personal: [
      /tax/i, /irs\.gov/, /social.*security/i, /ssn/i,
      /insurance/i, /legal/i, /court/i, /gov.*benefits/i,
      /dmv/i, /passport/i
    ],

    // Adult/Private
    private: [
      /porn/i, /xxx/i, /adult/i, /dating/i, /tinder/i,
      /onlyfans/i, /bumble/i, /hinge/i, /grindr/i
    ]
  };

  // Additional skip patterns
  const SKIP_PATTERNS = [
    /\.(png|jpg|jpeg|gif|pdf|mp4|mp3|webp|svg|ico|woff|woff2|ttf)(\?.*)?$/i,
    /^chrome-extension:\/\//i,
    /^chrome:\/\//i,
    /^about:/i,
    /^file:/i,
    /^data:/i,
    /localhost/i,
    /127\.0\.0\.1/,
    /192\.168\./,
    /10\.0\./,
    /172\.(1[6-9]|2[0-9]|3[0-1])\./  // Private IP range
  ];

  function shouldSkip(url) {
    // Check sensitive patterns
    const sensitivePatterns = Object.values(SENSITIVE_PATTERNS).flat();
    if (sensitivePatterns.some(pattern => pattern.test(url))) {
      console.log('[HistoryExt] Skipping sensitive URL');
      return true;
    }

    // Check skip patterns
    if (SKIP_PATTERNS.some(pattern => pattern.test(url))) {
      console.log('[HistoryExt] Skipping filtered URL');
      return true;
    }

    return false;
  }

  // ===================
  // HTML Sanitisation
  // ===================
  function sanitiseHtml() {
    // Clone the document to avoid modifying the live page
    const clone = document.documentElement.cloneNode(true);

    // Remove all <script> tags
    for (const el of clone.querySelectorAll('script')) {
      el.remove();
    }

    // Remove all <input>, <textarea>, <select> elements (form data / PII)
    for (const el of clone.querySelectorAll('input, textarea, select')) {
      el.remove();
    }

    // Remove elements with sensitive autocomplete attributes
    const sensitiveAutocomplete = [
      '[autocomplete*="password"]',
      '[autocomplete*="cc-"]',
      '[autocomplete*="credit-card"]',
      '[autocomplete*="card"]',
      '[autocomplete*="ssn"]',
      '[autocomplete*="social"]',
      '[type="password"]',
      '[type="hidden"]'
    ].join(', ');
    for (const el of clone.querySelectorAll(sensitiveAutocomplete)) {
      el.remove();
    }

    // Remove all data-* attributes from every element
    const walker = document.createTreeWalker(clone, NodeFilter.SHOW_ELEMENT);
    let node;
    while ((node = walker.nextNode())) {
      const toRemove = [];
      for (const attr of node.attributes) {
        if (attr.name.startsWith('data-')) {
          toRemove.push(attr.name);
        }
      }
      for (const name of toRemove) {
        node.removeAttribute(name);
      }
    }

    let html = clone.outerHTML;

    // Enforce size limit
    if (html.length > MAX_HTML_SIZE) {
      html = html.substring(0, MAX_HTML_SIZE);
      console.log('[HistoryExt] Truncated HTML to', MAX_HTML_SIZE, 'chars');
    }

    return html;
  }

  // ===================
  // State Management
  // ===================
  let lastCapturedUrl = null;
  let captureTimeout = null;
  let lastUrl = location.href;

  // ===================
  // Capture & Send Logic
  // ===================
  function captureAndSend() {
    const currentUrl = location.href;

    // Don't re-capture same URL
    if (currentUrl === lastCapturedUrl) {
      console.log('[HistoryExt] Already captured this URL');
      return;
    }

    // Final check before sending
    if (shouldSkip(currentUrl)) {
      return;
    }

    lastCapturedUrl = currentUrl;

    const payload = {
      url: currentUrl,
      title: document.title,
      html: sanitiseHtml(),
      timestamp: new Date().toISOString(),
      device: 'Chrome'
    };

    console.log('[HistoryExt] Capturing:', currentUrl);

    chrome.runtime.sendMessage(payload).catch(err => {
      console.error('[HistoryExt] Failed to send message:', err);
    });
  }

  function scheduleCapture() {
    // Clear any pending capture
    if (captureTimeout) {
      clearTimeout(captureTimeout);
    }

    // Skip immediately if URL is filtered
    if (shouldSkip(location.href)) {
      return;
    }

    // Schedule capture after debounce period
    captureTimeout = setTimeout(() => {
      captureAndSend();
    }, DEBOUNCE_MS);
  }

  // ===================
  // SPA Navigation Handling
  // ===================
  function checkUrlChange() {
    if (location.href !== lastUrl) {
      console.log('[HistoryExt] URL changed:', lastUrl, '->', location.href);
      lastUrl = location.href;
      scheduleCapture();
    }
  }

  // Intercept History API for SPA navigation
  const originalPushState = history.pushState;
  const originalReplaceState = history.replaceState;

  history.pushState = function(...args) {
    originalPushState.apply(this, args);
    checkUrlChange();
  };

  history.replaceState = function(...args) {
    originalReplaceState.apply(this, args);
    checkUrlChange();
  };

  // Handle back/forward navigation
  window.addEventListener('popstate', checkUrlChange);

  // Some SPAs use hashchange
  window.addEventListener('hashchange', checkUrlChange);

  // ===================
  // Initial Capture
  // ===================
  scheduleCapture();

  console.log('[HistoryExt] Content script loaded');
})();
