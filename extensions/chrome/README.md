# Ostler Browser History (Chrome)

Chrome MV3 extension. Captures every page you visit and POSTs it to your local Ostler Hub for memory recall queries. Also works on Edge, Brave, Arc, and other Chromium browsers.

## Installation

### Chrome Web Store (post-launch)
Search for **Ostler – Browser History** in the Chrome Web Store and click **Add to Chrome**. The Ostler installer opens this listing automatically at the end of install.

### Sideload (developer mode)

1. Open Chrome and navigate to `chrome://extensions/`
2. Enable **Developer mode** (toggle in top-right)
3. Click **Load unpacked**
4. Select the `Chrome/` directory from this repo
5. The extension icon should appear in the toolbar

## Configuration

Click the extension icon to open the popup. Two fields:

- **Ingest endpoint** – your Hub URL. Defaults to `http://localhost:8000/api/safari/ingest` (assumes the Hub runs on this Mac). If your Hub runs on a different machine on your LAN, set the IP here.
- **API key** – your paired token. Empty until you pair with the Hub. The popup shows "Disconnected" until both fields are set and the Hub is reachable.

The extension **will not send anything** until the API key is non-empty. Open your Hub UI and use **Connect browser extension** to pair, then paste the token here.

Settings persist via `chrome.storage.sync`, so they survive across browsers signed in to the same Google profile.

## Features

- Privacy-first URL filtering (banking, medical, auth pages skipped)
- SPA navigation handling (History API interception)
- 2.5s debounce before capture
- Reader-mode plain-text extraction (no HTML/CSS/JS leaves your browser)
- Retry queue for failed sends (persisted in `chrome.storage.local`)
- Popup showing capture stats and connection status

## Testing

1. Load the extension in Chrome
2. Pair with your Hub via the popup
3. Visit a few non-sensitive pages (e.g., news sites, tech blogs)
4. Open DevTools → Console to see `[HistoryExt]` log messages
5. Click the extension icon to see capture count and status
6. Check the service worker console: `chrome://extensions/` → Details → "Inspect views: service worker"

## Architecture

```
content-script.js  →  chrome.runtime.sendMessage  →  background.js (service worker)
                                                          ↓
                                                      fetch() POST
                                                          ↓
                                                   Ostler Hub /api/safari/ingest
```

Failed sends are queued in `chrome.storage.local` and retried on next page load or storage-change event.
