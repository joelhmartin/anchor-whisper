const { invoke } = window.__TAURI__.core;

// Import global shortcut plugin
let globalShortcut;
try {
  globalShortcut = window.__TAURI__['global-shortcut'] || window.__TAURI__.globalShortcut;
} catch (e) {
  console.log('Global shortcut not available:', e);
}

// DOM elements - Record page
let apiKeyInput, saveKeyBtn, keyStatus;
let recordBtn, recordText, recordingIndicator;
let rawTextEl, formattedTextEl, copyBtn, pasteBtn;
let errorMsg, loadingEl;
let autoPasteCheckbox, hotkeyDisplay;

// DOM elements - Settings page
let hotkeyInput, saveHotkeyBtn, hotkeyStatus;
let keywordSpoken, keywordReplacement, addKeywordBtn, keywordsList;
let customPromptEl, savePromptBtn, resetPromptBtn, promptStatus;

// DOM elements - Navigation
let navRecord, navSettings, pageRecord, pageSettings;

// DOM elements - Update
let updateBanner, updateVersion, updateBtn, dismissUpdateBtn, appVersionEl;

// State
let isRecording = false;
let formattedResult = '';
let currentHotkey = 'Control+Space';
let pendingHotkey = '';
let registeredShortcut = null;

// Navigation
function showPage(page) {
  pageRecord.classList.toggle('hidden', page !== 'record');
  pageSettings.classList.toggle('hidden', page !== 'settings');
  navRecord.classList.toggle('active', page === 'record');
  navSettings.classList.toggle('active', page === 'settings');
}

// Status helpers
function showStatus(element, message, type) {
  element.textContent = message;
  element.className = `status ${type}`;
  setTimeout(() => {
    element.textContent = '';
    element.className = 'status';
  }, 3000);
}

function showError(message) {
  errorMsg.textContent = message;
  errorMsg.classList.remove('hidden');
  setTimeout(() => {
    errorMsg.classList.add('hidden');
  }, 5000);
}

function setLoading(loading) {
  loadingEl.classList.toggle('hidden', !loading);
}

// API Key
async function saveApiKey() {
  const key = apiKeyInput.value.trim();
  if (!key) {
    showStatus(keyStatus, 'Please enter an API key', 'error');
    return;
  }
  try {
    await invoke('set_api_key', { key });
    showStatus(keyStatus, 'API key saved!', 'success');
    apiKeyInput.value = '';
    apiKeyInput.placeholder = 'Key saved (hidden)';
  } catch (err) {
    showStatus(keyStatus, `Error: ${err}`, 'error');
  }
}

// Recording
async function startRecording() {
  if (isRecording) return;
  try {
    await invoke('start_recording');
    await invoke('show_overlay');
    isRecording = true;
    recordBtn.classList.add('recording');
    recordText.textContent = 'Recording...';
    recordingIndicator.classList.remove('hidden');
  } catch (err) {
    showError(`Failed to start recording: ${err}`);
  }
}

async function stopRecording() {
  if (!isRecording) return;
  try {
    await invoke('stop_recording');
    await invoke('hide_overlay');
    isRecording = false;
    recordBtn.classList.remove('recording');
    recordText.textContent = 'Hold to Record';
    recordingIndicator.classList.add('hidden');
    await transcribe();
  } catch (err) {
    showError(`Failed to stop recording: ${err}`);
    await invoke('hide_overlay');
  }
}

async function transcribe() {
  setLoading(true);
  rawTextEl.innerHTML = '<p class="placeholder">Transcribing...</p>';
  formattedTextEl.innerHTML = '<p class="placeholder">Formatting...</p>';

  try {
    const result = await invoke('transcribe_audio');
    rawTextEl.innerHTML = `<p>${escapeHtml(result.raw_text)}</p>`;
    formattedTextEl.innerHTML = formatTextHtml(result.formatted_text);
    formattedResult = result.formatted_text;
    copyBtn.disabled = false;
    pasteBtn.disabled = false;

    // Auto-paste if enabled
    if (autoPasteCheckbox.checked) {
      await injectText(result.formatted_text);
    }
  } catch (err) {
    showError(`Transcription failed: ${err}`);
    rawTextEl.innerHTML = '<p class="placeholder">Raw speech-to-text will appear here...</p>';
    formattedTextEl.innerHTML = '<p class="placeholder">AI-formatted text will appear here...</p>';
  } finally {
    setLoading(false);
  }
}

function escapeHtml(text) {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

function formatTextHtml(text) {
  let html = escapeHtml(text);
  html = html.replace(/^[-*]\s+(.+)$/gm, '<li>$1</li>');
  html = html.replace(/(<li>.*<\/li>\n?)+/g, '<ul>$&</ul>');
  html = html.replace(/^\d+\.\s+(.+)$/gm, '<li>$1</li>');
  html = html.split('\n\n').map(p => `<p>${p}</p>`).join('');
  return html;
}

async function copyToClipboard() {
  if (!formattedResult) return;
  try {
    await navigator.clipboard.writeText(formattedResult);
    copyBtn.textContent = 'Copied!';
    setTimeout(() => { copyBtn.textContent = 'Copy'; }, 2000);
  } catch (err) {
    showError('Failed to copy to clipboard');
  }
}

async function injectText(text) {
  try {
    await invoke('inject_text', { text: text || formattedResult });
  } catch (err) {
    showError(`Failed to paste: ${err}`);
  }
}

// Hotkey management
async function registerHotkey(hotkey) {
  if (!globalShortcut) {
    console.log('Global shortcut not available');
    return;
  }

  try {
    // Unregister previous shortcut
    if (registeredShortcut) {
      try {
        await globalShortcut.unregister(registeredShortcut);
      } catch (e) {
        console.log('Failed to unregister previous shortcut:', e);
      }
    }

    // Register new shortcut
    await globalShortcut.register(hotkey, async (event) => {
      if (event.state === 'Pressed') {
        await startRecording();
      } else if (event.state === 'Released') {
        await stopRecording();
      }
    });

    registeredShortcut = hotkey;
    currentHotkey = hotkey;
    hotkeyDisplay.textContent = hotkey;
    console.log(`Registered hotkey: ${hotkey}`);
  } catch (err) {
    console.error('Failed to register hotkey:', err);
    showError(`Failed to register hotkey: ${err}`);
  }
}

function handleHotkeyCapture(e) {
  e.preventDefault();
  const parts = [];
  if (e.ctrlKey) parts.push('Control');
  if (e.altKey) parts.push('Alt');
  if (e.shiftKey) parts.push('Shift');
  if (e.metaKey) parts.push('Super');

  // Add the actual key if it's not a modifier
  const key = e.key;
  if (!['Control', 'Alt', 'Shift', 'Meta'].includes(key)) {
    // Normalize key names for Tauri
    let normalizedKey = key;
    if (key === ' ') normalizedKey = 'Space';
    else if (key.length === 1) normalizedKey = key.toUpperCase();
    parts.push(normalizedKey);
  }

  if (parts.length > 0) {
    pendingHotkey = parts.join('+');
    hotkeyInput.value = pendingHotkey;
  }
}

async function saveHotkey() {
  if (!pendingHotkey) {
    showStatus(hotkeyStatus, 'Please press a key combination first', 'error');
    return;
  }
  try {
    await invoke('set_hotkey', { hotkey: pendingHotkey });
    await registerHotkey(pendingHotkey);
    showStatus(hotkeyStatus, 'Hotkey saved!', 'success');
  } catch (err) {
    showStatus(hotkeyStatus, `Error: ${err}`, 'error');
  }
}

// Keywords management
async function loadKeywords() {
  try {
    const keywords = await invoke('get_keywords');
    renderKeywords(keywords);
  } catch (err) {
    console.error('Failed to load keywords:', err);
  }
}

function renderKeywords(keywords) {
  const entries = Object.entries(keywords);
  if (entries.length === 0) {
    keywordsList.innerHTML = '<p class="placeholder">No keywords added yet</p>';
    return;
  }

  keywordsList.innerHTML = entries.map(([spoken, replacement]) => `
    <div class="keyword-item">
      <span class="keyword-spoken">${escapeHtml(spoken)}</span>
      <span class="arrow">→</span>
      <span class="keyword-replacement">${escapeHtml(replacement)}</span>
      <button class="remove-keyword" data-spoken="${escapeHtml(spoken)}">×</button>
    </div>
  `).join('');

  // Add remove handlers
  keywordsList.querySelectorAll('.remove-keyword').forEach(btn => {
    btn.addEventListener('click', async () => {
      const spoken = btn.dataset.spoken;
      try {
        await invoke('remove_keyword', { spoken });
        await loadKeywords();
      } catch (err) {
        showError(`Failed to remove keyword: ${err}`);
      }
    });
  });
}

async function addKeyword() {
  const spoken = keywordSpoken.value.trim();
  const replacement = keywordReplacement.value.trim();

  if (!spoken || !replacement) {
    showError('Please enter both spoken word and replacement');
    return;
  }

  try {
    await invoke('add_keyword', { spoken, replacement });
    keywordSpoken.value = '';
    keywordReplacement.value = '';
    await loadKeywords();
  } catch (err) {
    showError(`Failed to add keyword: ${err}`);
  }
}

// Prompt management
async function loadPrompt() {
  try {
    const prompt = await invoke('get_custom_prompt');
    customPromptEl.value = prompt;
  } catch (err) {
    console.error('Failed to load prompt:', err);
  }
}

async function savePrompt() {
  const prompt = customPromptEl.value.trim();
  if (!prompt) {
    showStatus(promptStatus, 'Prompt cannot be empty', 'error');
    return;
  }
  try {
    await invoke('set_custom_prompt', { prompt });
    showStatus(promptStatus, 'Prompt saved!', 'success');
  } catch (err) {
    showStatus(promptStatus, `Error: ${err}`, 'error');
  }
}

async function resetPrompt() {
  try {
    const defaultPrompt = await invoke('reset_prompt_to_default');
    customPromptEl.value = defaultPrompt;
    showStatus(promptStatus, 'Prompt reset to default', 'success');
  } catch (err) {
    showStatus(promptStatus, `Error: ${err}`, 'error');
  }
}

// Load settings
async function loadSettings() {
  try {
    const hotkey = await invoke('get_hotkey');
    currentHotkey = hotkey;
    hotkeyInput.value = hotkey;
    hotkeyDisplay.textContent = hotkey;
    await registerHotkey(hotkey);
  } catch (err) {
    console.error('Failed to load hotkey:', err);
  }

  await loadKeywords();
  await loadPrompt();
}

// Update management
async function checkForUpdate() {
  try {
    const update = await invoke('check_for_update');
    if (update.available) {
      updateVersion.textContent = `v${update.version}`;
      updateBanner.classList.remove('hidden');
    }
  } catch (err) {
    console.log('Update check failed:', err);
  }
}

async function installUpdate() {
  updateBtn.textContent = 'Updating...';
  updateBtn.disabled = true;
  try {
    await invoke('install_update');
    updateBtn.textContent = 'Restarting...';
  } catch (err) {
    showError(`Update failed: ${err}`);
    updateBtn.textContent = 'Update Now';
    updateBtn.disabled = false;
  }
}

async function loadVersion() {
  try {
    const version = await invoke('get_version');
    appVersionEl.textContent = `v${version}`;
  } catch (err) {
    console.error('Failed to load version:', err);
  }
}

// Initialize
window.addEventListener("DOMContentLoaded", async () => {
  // Request macOS permissions on startup (triggers permission dialogs if needed)
  try {
    await invoke('request_permissions');
  } catch (e) {
    console.log('Permission request:', e);
  }

  // Get DOM elements - Record page
  apiKeyInput = document.getElementById('api-key');
  saveKeyBtn = document.getElementById('save-key-btn');
  keyStatus = document.getElementById('key-status');
  recordBtn = document.getElementById('record-btn');
  recordText = document.getElementById('record-text');
  recordingIndicator = document.getElementById('recording-indicator');
  rawTextEl = document.getElementById('raw-text');
  formattedTextEl = document.getElementById('formatted-text');
  copyBtn = document.getElementById('copy-btn');
  pasteBtn = document.getElementById('paste-btn');
  errorMsg = document.getElementById('error-msg');
  loadingEl = document.getElementById('loading');
  autoPasteCheckbox = document.getElementById('auto-paste');
  hotkeyDisplay = document.getElementById('hotkey-display');

  // Get DOM elements - Settings page
  hotkeyInput = document.getElementById('hotkey-input');
  saveHotkeyBtn = document.getElementById('save-hotkey-btn');
  hotkeyStatus = document.getElementById('hotkey-status');
  keywordSpoken = document.getElementById('keyword-spoken');
  keywordReplacement = document.getElementById('keyword-replacement');
  addKeywordBtn = document.getElementById('add-keyword-btn');
  keywordsList = document.getElementById('keywords-list');
  customPromptEl = document.getElementById('custom-prompt');
  savePromptBtn = document.getElementById('save-prompt-btn');
  resetPromptBtn = document.getElementById('reset-prompt-btn');
  promptStatus = document.getElementById('prompt-status');

  // Get DOM elements - Navigation
  navRecord = document.getElementById('nav-record');
  navSettings = document.getElementById('nav-settings');
  pageRecord = document.getElementById('page-record');
  pageSettings = document.getElementById('page-settings');

  // Get DOM elements - Update
  updateBanner = document.getElementById('update-banner');
  updateVersion = document.getElementById('update-version');
  updateBtn = document.getElementById('update-btn');
  dismissUpdateBtn = document.getElementById('dismiss-update');
  appVersionEl = document.getElementById('app-version');

  // Navigation events
  navRecord.addEventListener('click', () => showPage('record'));
  navSettings.addEventListener('click', () => showPage('settings'));

  // API key events
  saveKeyBtn.addEventListener('click', saveApiKey);
  apiKeyInput.addEventListener('keypress', (e) => {
    if (e.key === 'Enter') saveApiKey();
  });

  // Record button events
  recordBtn.addEventListener('mousedown', startRecording);
  recordBtn.addEventListener('mouseup', stopRecording);
  recordBtn.addEventListener('mouseleave', () => {
    if (isRecording) stopRecording();
  });
  recordBtn.addEventListener('touchstart', (e) => {
    e.preventDefault();
    startRecording();
  });
  recordBtn.addEventListener('touchend', (e) => {
    e.preventDefault();
    stopRecording();
  });

  // Copy/paste buttons
  copyBtn.addEventListener('click', copyToClipboard);
  pasteBtn.addEventListener('click', () => injectText());

  // Hotkey events
  hotkeyInput.addEventListener('keydown', handleHotkeyCapture);
  hotkeyInput.addEventListener('focus', () => {
    hotkeyInput.value = 'Press keys...';
    pendingHotkey = '';
  });
  saveHotkeyBtn.addEventListener('click', saveHotkey);

  // Keyword events
  addKeywordBtn.addEventListener('click', addKeyword);
  keywordReplacement.addEventListener('keypress', (e) => {
    if (e.key === 'Enter') addKeyword();
  });

  // Prompt events
  savePromptBtn.addEventListener('click', savePrompt);
  resetPromptBtn.addEventListener('click', resetPrompt);

  // Auto-paste checkbox
  autoPasteCheckbox.addEventListener('change', async () => {
    try {
      await invoke('set_auto_paste', { enabled: autoPasteCheckbox.checked });
    } catch (err) {
      console.error('Failed to save auto-paste setting:', err);
    }
  });

  // Update events
  updateBtn.addEventListener('click', installUpdate);
  dismissUpdateBtn.addEventListener('click', () => {
    updateBanner.classList.add('hidden');
  });

  // Load settings and check for updates
  await loadSettings();
  await loadVersion();
  await checkForUpdate();
});
