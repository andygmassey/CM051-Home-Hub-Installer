/**
 * Safari History Extension (Chrome) - Service Worker
 * Receives page payloads from content script and sends to PWG Gateway API.
 *
 * Chrome MV3 uses a service worker instead of a persistent background page.
 * Config (endpoint, API key) stored in chrome.storage.sync so user can change via popup.
 */

// Default endpoint assumes Hub-on-this-Mac. If your Hub runs on a different
// machine on your LAN, update via the popup.
const DEFAULT_ENDPOINT = 'http://localhost:8000/api/safari/ingest';
// Empty default – pairing flow with the Hub fills this in. The background
// worker refuses to send if the API key is empty.
const DEFAULT_API_KEY = '';
const MAX_HTML_SIZE = 500000; // 500KB
const MAX_RETRY_COUNT = 3;
const MIN_SEND_INTERVAL = 2000; // 2 seconds between sends

let lastSendTime = 0;

// Load config from storage (falls back to defaults)
async function getConfig() {
  const result = await chrome.storage.sync.get(['ingestEndpoint', 'apiKey']);
  return {
    endpoint: result.ingestEndpoint || DEFAULT_ENDPOINT,
    apiKey: result.apiKey || DEFAULT_API_KEY
  };
}

// Send payload to API
async function sendPayload(payload) {
  const config = await getConfig();

  if (!config.apiKey) {
    console.log('[HistoryExt] Skipping send – extension not paired with Hub. Open the popup to pair.');
    return false;
  }

  let html = payload.html || '';
  if (html.length > MAX_HTML_SIZE) {
    html = html.substring(0, MAX_HTML_SIZE);
    console.log('[HistoryExt] Truncated HTML to', MAX_HTML_SIZE, 'chars');
  }

  const body = {
    url: payload.url,
    title: payload.title,
    html: html,
    timestamp: payload.timestamp,
    device: payload.device || 'Chrome'
  };

  try {
    const response = await fetch(config.endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-API-Key': config.apiKey
      },
      body: JSON.stringify(body)
    });

    if (response.ok) {
      const data = await response.json();
      console.log('[HistoryExt] Sent:', payload.url, data);
      await updateStats(response.status);
      return true;
    } else {
      console.error('[HistoryExt] Server returned', response.status);
      await updateStats(response.status);
      return false;
    }
  } catch (error) {
    console.error('[HistoryExt] Network error:', error.message);
    return false;
  }
}

// Track capture stats in storage
async function updateStats(httpStatus) {
  try {
    const result = await chrome.storage.local.get(['captureCount']);
    const count = (result.captureCount || 0) + (httpStatus >= 200 && httpStatus < 300 ? 1 : 0);
    await chrome.storage.local.set({
      captureCount: count,
      lastCaptureTime: new Date().toISOString(),
      lastHttpStatus: httpStatus
    });
  } catch (err) {
    console.error('[HistoryExt] Failed to update stats:', err);
  }
}

// Listen for messages from content script and popup
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  try {
    if (message.type === 'processQueue') {
      console.log('[HistoryExt] Processing storage queue');
      processStorageQueue();
      return true;
    }

    if (message.type === 'getStatus') {
      (async () => {
        const config = await getConfig();
        const local = await chrome.storage.local.get([
          'captureCount', 'lastCaptureTime', 'lastHttpStatus', 'pendingQueue'
        ]);
        sendResponse({
          captureCount: local.captureCount || 0,
          lastCaptureTime: local.lastCaptureTime || null,
          lastHttpStatus: local.lastHttpStatus || null,
          queueSize: (local.pendingQueue || []).length,
          endpoint: config.endpoint
        });
      })();
      return true; // async response
    }

    if (message.type === 'saveConfig') {
      chrome.storage.sync.set({
        ingestEndpoint: message.endpoint,
        apiKey: message.apiKey
      }, () => {
        sendResponse({ ok: true });
      });
      return true;
    }

    if (!message.url) {
      console.log('[HistoryExt] Ignoring message without URL');
      return true;
    }

    console.log('[HistoryExt] Received:', message.url);

    // Rate limit sends
    const now = Date.now();
    const timeSinceLastSend = now - lastSendTime;
    lastSendTime = now;

    const doSend = async () => {
      const success = await sendPayload(message);
      if (!success) {
        await addToStorageQueue(message);
      }
    };

    if (timeSinceLastSend < MIN_SEND_INTERVAL) {
      setTimeout(doSend, MIN_SEND_INTERVAL - timeSinceLastSend);
    } else {
      doSend();
    }
  } catch (err) {
    console.error('[HistoryExt] Message handler error:', err);
  }

  return true;
});

// Add failed item to storage queue for retry
async function addToStorageQueue(payload) {
  try {
    const result = await chrome.storage.local.get(['pendingQueue', 'retryCount']);
    const queue = result.pendingQueue || [];
    const retryCount = result.retryCount || {};

    const key = payload.url;
    const currentRetries = retryCount[key] || 0;

    if (currentRetries >= MAX_RETRY_COUNT) {
      console.log('[HistoryExt] Max retries exceeded for:', key);
      return;
    }

    if (!queue.some(p => p.url === payload.url)) {
      queue.push(payload);
      retryCount[key] = currentRetries + 1;
      await chrome.storage.local.set({ pendingQueue: queue, retryCount: retryCount });
      console.log('[HistoryExt] Added to storage queue for retry');
    }
  } catch (err) {
    console.error('[HistoryExt] Failed to add to storage queue:', err);
  }
}

// Process storage queue
async function processStorageQueue() {
  try {
    const result = await chrome.storage.local.get(['pendingQueue', 'retryCount']);
    const queue = result.pendingQueue || [];
    const retryCount = result.retryCount || {};

    if (queue.length === 0) {
      return;
    }

    console.log('[HistoryExt] Processing', queue.length, 'items from storage queue');

    const remaining = [];
    const newRetryCount = { ...retryCount };

    for (const payload of queue) {
      const key = payload.url;
      const currentRetries = newRetryCount[key] || 0;

      if (currentRetries >= MAX_RETRY_COUNT) {
        console.log('[HistoryExt] Skipping (max retries):', key);
        delete newRetryCount[key];
        continue;
      }

      const success = await sendPayload(payload);
      if (!success) {
        newRetryCount[key] = currentRetries + 1;
        remaining.push(payload);
      } else {
        delete newRetryCount[key];
      }
    }

    await chrome.storage.local.set({ pendingQueue: remaining, retryCount: newRetryCount });
    console.log('[HistoryExt] Queue processed, remaining:', remaining.length);
  } catch (err) {
    console.error('[HistoryExt] Queue processing error:', err);
  }
}

// Watch for storage changes (retry queue)
chrome.storage.onChanged.addListener((changes, area) => {
  try {
    if (area === 'local' && changes.pendingQueue) {
      const newQueue = changes.pendingQueue.newValue || [];
      const oldQueue = changes.pendingQueue.oldValue || [];
      if (newQueue.length > oldQueue.length) {
        processStorageQueue();
      }
    }
  } catch (err) {
    console.error('[HistoryExt] Storage change handler error:', err);
  }
});

// Process queue on startup
processStorageQueue();

console.log('[HistoryExt] Service worker loaded - PWG Gateway mode');
