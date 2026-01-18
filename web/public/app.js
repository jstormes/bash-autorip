/**
 * Autorip Dashboard Frontend
 */

// State
let ws = null;
let drives = [];
let buses = [];
let history = [];
let selectedLogDevice = '';
let pendingReset = null;

// DOM Elements
const connectionStatus = document.getElementById('connection-status');
const drivesContainer = document.getElementById('drives-container');
const busesContainer = document.getElementById('buses-container');
const logDeviceSelect = document.getElementById('log-device-select');
const logOutput = document.getElementById('log-output');
const logRefreshBtn = document.getElementById('log-refresh-btn');
const logAutoScroll = document.getElementById('log-auto-scroll');
const historyFilter = document.getElementById('history-filter');
const historyTbody = document.getElementById('history-tbody');
const resetModal = document.getElementById('reset-modal');
const resetModalBody = document.getElementById('reset-modal-body');
const resetCancelBtn = document.getElementById('reset-cancel-btn');
const resetConfirmBtn = document.getElementById('reset-confirm-btn');
const toast = document.getElementById('toast');
const toastMessage = document.getElementById('toast-message');

// Initialize
document.addEventListener('DOMContentLoaded', () => {
    connectWebSocket();
    loadBuses();
    loadHistory();
    setupEventListeners();
});

// WebSocket Connection
function connectWebSocket() {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const wsUrl = `${protocol}//${window.location.host}`;

    ws = new WebSocket(wsUrl);

    ws.onopen = () => {
        console.log('WebSocket connected');
        connectionStatus.classList.add('connected');
        connectionStatus.querySelector('.text').textContent = 'Connected';
    };

    ws.onclose = () => {
        console.log('WebSocket disconnected');
        connectionStatus.classList.remove('connected');
        connectionStatus.querySelector('.text').textContent = 'Disconnected';

        // Reconnect after 3 seconds
        setTimeout(connectWebSocket, 3000);
    };

    ws.onerror = (error) => {
        console.error('WebSocket error:', error);
    };

    ws.onmessage = (event) => {
        try {
            const message = JSON.parse(event.data);
            handleMessage(message);
        } catch (err) {
            console.error('Error parsing message:', err);
        }
    };
}

// Handle WebSocket messages
function handleMessage(message) {
    switch (message.type) {
        case 'drives':
            drives = message.data;
            renderDrives();
            updateLogDeviceSelect();
            updateBusesWithDriveStatus();
            break;

        case 'crash':
            showToast(`Drive ${message.data.device} has crashed!`, 'error');
            break;

        case 'reset':
            showToast(`Bus ${message.data.bus.id} has been reset`, 'success');
            loadBuses();
            break;
    }
}

// Render drive cards
function renderDrives() {
    if (drives.length === 0) {
        drivesContainer.innerHTML = '<div class="placeholder"><p>No drives detected</p></div>';
        return;
    }

    drivesContainer.innerHTML = drives.map(drive => {
        const stats = drive.stats || { crashCount: 0, health: 'good' };
        const healthClass = `health-${stats.health}`;

        return `
            <div class="drive-card" data-device="${drive.device}">
                <div class="drive-card-header">
                    <span class="drive-device">${drive.device}</span>
                    <span class="drive-state ${drive.state}">${drive.state}</span>
                </div>
                <div class="drive-info">
                    ${drive.discName ?
                        `<div class="drive-disc-name">${escapeHtml(drive.discName)}</div>` :
                        '<div class="drive-disc-name">No disc</div>'
                    }
                    ${drive.operation ?
                        `<div class="drive-operation">${escapeHtml(drive.operation)}</div>` :
                        ''
                    }
                    ${drive.discType ?
                        `<span class="drive-disc-type">${drive.discType}</span>` :
                        ''
                    }
                </div>
                ${drive.state === 'ripping' ? `
                    <div class="progress-container">
                        <div class="progress-bar">
                            <div class="progress-fill" style="width: ${drive.progress}%"></div>
                        </div>
                        <div class="progress-text">
                            <span>${drive.progress}%</span>
                            ${drive.titleTotal > 0 ?
                                `<span>Title ${drive.titleCurrent} of ${drive.titleTotal}</span>` :
                                ''
                            }
                            ${drive.elapsed ?
                                `<span>Elapsed: ${formatDuration(drive.elapsed)}</span>` :
                                ''
                            }
                        </div>
                    </div>
                ` : ''}
                ${drive.errorMessage && drive.state === 'error' ? `
                    <div class="drive-error">${escapeHtml(drive.errorMessage)}</div>
                ` : ''}
                <div class="drive-stats">
                    <div class="stat">
                        <span class="stat-label">Crashes:</span>
                        <span>${stats.crashCount}</span>
                    </div>
                    <div class="stat">
                        <span class="stat-label">Health:</span>
                        <span class="${healthClass}">${stats.health}</span>
                    </div>
                </div>
            </div>
        `;
    }).join('');
}

// Load bus information
async function loadBuses() {
    try {
        const response = await fetch('/api/buses');
        buses = await response.json();
        renderBuses();
    } catch (err) {
        console.error('Error loading buses:', err);
    }
}

// Render bus cards
function renderBuses() {
    if (buses.length === 0) {
        busesContainer.innerHTML = '<div class="placeholder"><p>No buses detected</p></div>';
        return;
    }

    busesContainer.innerHTML = buses.map(bus => {
        const driveChips = bus.drives.map(d => {
            const driveInfo = drives.find(dr => dr.device === d.device);
            const state = driveInfo?.state || 'idle';
            return `<span class="bus-drive-chip ${state}">${d.device}</span>`;
        }).join('');

        return `
            <div class="bus-card" data-bus-id="${bus.id}">
                <div class="bus-header">
                    <div>
                        <div class="bus-id">${bus.id}</div>
                        <div class="bus-type">${bus.type}</div>
                    </div>
                </div>
                <div class="bus-controller">${escapeHtml(bus.controller)}</div>
                <div class="bus-drives">${driveChips}</div>
                ${bus.resetSupported ?
                    `<button class="btn-reset" onclick="initiateReset('${bus.id}')">Reset Bus</button>` :
                    '<button class="btn-reset" disabled>Reset Not Supported</button>'
                }
            </div>
        `;
    }).join('');
}

// Update buses with current drive status
function updateBusesWithDriveStatus() {
    buses.forEach(bus => {
        const busCard = document.querySelector(`.bus-card[data-bus-id="${bus.id}"]`);
        if (!busCard) return;

        const drivesDiv = busCard.querySelector('.bus-drives');
        drivesDiv.innerHTML = bus.drives.map(d => {
            const driveInfo = drives.find(dr => dr.device === d.device);
            const state = driveInfo?.state || 'idle';
            return `<span class="bus-drive-chip ${state}">${d.device}</span>`;
        }).join('');
    });
}

// Initiate bus reset
async function initiateReset(busId) {
    const bus = buses.find(b => b.id === busId);
    if (!bus) return;

    // Check for active drives
    const activeOnBus = drives.filter(d =>
        bus.drives.some(bd => bd.device === d.device) &&
        d.state === 'ripping'
    );

    if (activeOnBus.length > 0) {
        pendingReset = busId;
        resetModalBody.innerHTML = `
            <p>The following drives are currently ripping and will be interrupted:</p>
            <div class="warning-list">
                <ul>
                    ${activeOnBus.map(d => `<li><strong>${d.device}</strong>: ${escapeHtml(d.discName || 'Unknown disc')}</li>`).join('')}
                </ul>
            </div>
            <p style="margin-top: 1rem;">Are you sure you want to reset bus <strong>${busId}</strong>?</p>
        `;
        resetModal.classList.remove('hidden');
    } else {
        // No active rips, reset directly
        await performReset(busId, false);
    }
}

// Perform bus reset
async function performReset(busId, confirm) {
    try {
        const url = `/api/buses/${busId}/reset${confirm ? '?confirm=true' : ''}`;
        const response = await fetch(url, { method: 'POST' });
        const result = await response.json();

        if (response.ok) {
            showToast(`Bus ${busId} reset successfully`, 'success');
            loadBuses();
        } else if (result.requiresConfirm) {
            // Handle confirmation required
            pendingReset = busId;
            resetModalBody.innerHTML = `
                <p>The following drives are currently active:</p>
                <div class="warning-list">
                    <ul>
                        ${result.activeDevices.map(d => `<li>${d}</li>`).join('')}
                    </ul>
                </div>
                <p style="margin-top: 1rem;">Are you sure you want to reset bus <strong>${busId}</strong>?</p>
            `;
            resetModal.classList.remove('hidden');
        } else {
            showToast(result.error || 'Reset failed', 'error');
        }
    } catch (err) {
        showToast(`Error: ${err.message}`, 'error');
    }
}

// Load history
async function loadHistory() {
    try {
        const response = await fetch('/api/history?limit=100');
        history = await response.json();
        renderHistory();
    } catch (err) {
        console.error('Error loading history:', err);
    }
}

// Render history table
function renderHistory() {
    const filter = historyFilter.value;
    const filtered = filter === 'all' ?
        history :
        history.filter(h => h.status === filter);

    if (filtered.length === 0) {
        historyTbody.innerHTML = '<tr><td colspan="7" style="text-align: center;">No history</td></tr>';
        return;
    }

    historyTbody.innerHTML = filtered.map(entry => {
        const startDate = new Date(entry.startTime * 1000);
        const titlesInfo = entry.titlesTotal > 0 ?
            `${entry.titlesSucceeded}/${entry.titlesTotal}` :
            '-';

        return `
            <tr>
                <td>${formatDate(startDate)}</td>
                <td>${entry.device}</td>
                <td>${escapeHtml(entry.discName || 'Unknown')}</td>
                <td>${entry.discType || '-'}</td>
                <td><span class="status-badge ${entry.status}">${entry.status}</span></td>
                <td>${formatDuration(entry.duration)}</td>
                <td>${titlesInfo}</td>
            </tr>
        `;
    }).join('');
}

// Update log device select
function updateLogDeviceSelect() {
    const currentValue = logDeviceSelect.value;
    logDeviceSelect.innerHTML = '<option value="">Select drive...</option>' +
        drives.map(d => `<option value="${d.device}">${d.device}</option>`).join('');

    if (currentValue && drives.some(d => d.device === currentValue)) {
        logDeviceSelect.value = currentValue;
    }
}

// Load device log
async function loadLog(device) {
    if (!device) {
        logOutput.textContent = '';
        return;
    }

    try {
        const response = await fetch(`/api/logs/${device}?lines=200`);
        const result = await response.json();
        logOutput.textContent = result.log || 'No log available';

        if (logAutoScroll.checked) {
            logOutput.scrollTop = logOutput.scrollHeight;
        }
    } catch (err) {
        logOutput.textContent = `Error loading log: ${err.message}`;
    }
}

// Setup event listeners
function setupEventListeners() {
    // Log device select
    logDeviceSelect.addEventListener('change', () => {
        selectedLogDevice = logDeviceSelect.value;
        loadLog(selectedLogDevice);
    });

    // Log refresh button
    logRefreshBtn.addEventListener('click', () => {
        loadLog(selectedLogDevice);
    });

    // History filter
    historyFilter.addEventListener('change', renderHistory);

    // Reset modal
    resetCancelBtn.addEventListener('click', () => {
        resetModal.classList.add('hidden');
        pendingReset = null;
    });

    resetConfirmBtn.addEventListener('click', async () => {
        if (pendingReset) {
            await performReset(pendingReset, true);
            resetModal.classList.add('hidden');
            pendingReset = null;
        }
    });

    // Close modal on backdrop click
    resetModal.addEventListener('click', (e) => {
        if (e.target === resetModal) {
            resetModal.classList.add('hidden');
            pendingReset = null;
        }
    });

    // Auto-refresh log
    setInterval(() => {
        if (selectedLogDevice) {
            loadLog(selectedLogDevice);
        }
    }, 5000);

    // Refresh history periodically
    setInterval(loadHistory, 30000);
}

// Show toast notification
function showToast(message, type = 'info') {
    toastMessage.textContent = message;
    toast.className = `toast ${type}`;

    setTimeout(() => {
        toast.classList.add('hidden');
    }, 5000);
}

// Utility functions
function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function formatDuration(seconds) {
    if (!seconds || seconds < 0) return '-';

    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    const secs = seconds % 60;

    if (hours > 0) {
        return `${hours}:${minutes.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')}`;
    }
    return `${minutes}:${secs.toString().padStart(2, '0')}`;
}

function formatDate(date) {
    const now = new Date();
    const diff = now - date;

    // If less than 24 hours ago, show relative time
    if (diff < 24 * 60 * 60 * 1000) {
        const hours = Math.floor(diff / (60 * 60 * 1000));
        if (hours === 0) {
            const minutes = Math.floor(diff / (60 * 1000));
            return `${minutes}m ago`;
        }
        return `${hours}h ago`;
    }

    // Otherwise show date
    return date.toLocaleDateString() + ' ' + date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

// Make initiateReset available globally
window.initiateReset = initiateReset;
