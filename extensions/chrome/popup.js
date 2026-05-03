/**
 * Popup script - shows extension status, capture stats, and settings.
 */

document.addEventListener('DOMContentLoaded', async () => {
  const statusEl = document.getElementById('status');
  const countEl = document.getElementById('count');
  const lastCaptureEl = document.getElementById('last-capture');
  const httpStatusEl = document.getElementById('http-status');
  const queueEl = document.getElementById('queue');
  const endpointInput = document.getElementById('endpoint');
  const apikeyInput = document.getElementById('apikey');
  const saveBtn = document.getElementById('save-btn');
  const saveMsg = document.getElementById('save-msg');

  // Load saved config into fields
  const config = await chrome.storage.sync.get(['ingestEndpoint', 'apiKey']);
  endpointInput.value = config.ingestEndpoint || 'http://localhost:8000/api/safari/ingest';
  apikeyInput.value = config.apiKey || '';

  // Get status from background service worker
  try {
    const response = await chrome.runtime.sendMessage({ type: 'getStatus' });

    if (response) {
      countEl.textContent = response.captureCount.toLocaleString();
      queueEl.textContent = response.queueSize > 0
        ? `${response.queueSize} pending`
        : 'empty';

      if (response.lastHttpStatus != null) {
        httpStatusEl.textContent = response.lastHttpStatus;
      }

      if (response.lastCaptureTime) {
        const date = new Date(response.lastCaptureTime);
        const now = new Date();
        const diffMs = now - date;
        const diffMins = Math.floor(diffMs / 60000);

        if (diffMins < 1) {
          lastCaptureEl.textContent = 'just now';
        } else if (diffMins < 60) {
          lastCaptureEl.textContent = `${diffMins}m ago`;
        } else if (diffMins < 1440) {
          lastCaptureEl.textContent = `${Math.floor(diffMins / 60)}h ago`;
        } else {
          lastCaptureEl.textContent = date.toLocaleDateString();
        }
      }

      // Check endpoint connectivity
      checkEndpoint(response.endpoint);
    }
  } catch (err) {
    statusEl.innerHTML = '<span class="dot disconnected"></span>Error';
    console.error('[HistoryExt] Popup error:', err);
  }

  // Save settings
  saveBtn.addEventListener('click', async () => {
    const endpoint = endpointInput.value.trim();
    const apiKey = apikeyInput.value.trim();

    if (!endpoint) {
      endpointInput.focus();
      return;
    }

    await chrome.runtime.sendMessage({
      type: 'saveConfig',
      endpoint: endpoint,
      apiKey: apiKey
    });

    saveMsg.style.display = 'inline';
    setTimeout(() => { saveMsg.style.display = 'none'; }, 2000);

    // Re-check connectivity with new endpoint
    checkEndpoint(endpoint);
  });
});

async function checkEndpoint(endpoint) {
  const statusEl = document.getElementById('status');
  try {
    const healthUrl = endpoint.replace(/\/api\/safari\/ingest$/, '/health');
    const response = await fetch(healthUrl, { signal: AbortSignal.timeout(5000) });
    if (response.ok) {
      statusEl.innerHTML = '<span class="dot connected"></span>Connected';
    } else {
      statusEl.innerHTML = '<span class="dot disconnected"></span>Server error';
    }
  } catch {
    statusEl.innerHTML = '<span class="dot disconnected"></span>Disconnected';
  }
}
