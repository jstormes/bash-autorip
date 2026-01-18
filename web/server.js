#!/usr/bin/env node
/**
 * Autorip Web Dashboard Server
 *
 * Provides REST API and WebSocket connections for monitoring
 * the autorip disc ripping system.
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const { WebSocketServer } = require('ws');

const StatusCollector = require('./lib/status-collector');
const BusManager = require('./lib/bus-manager');
const DriveStats = require('./lib/drive-stats');

// Configuration from environment variables
const CONFIG = {
    port: parseInt(process.env.AUTORIP_WEB_PORT || '8080', 10),
    host: process.env.AUTORIP_WEB_HOST || '127.0.0.1',
    statusDir: process.env.AUTORIP_STATUS_DIR || '/var/lib/autorip/status',
    historyFile: process.env.AUTORIP_HISTORY_FILE || '/var/lib/autorip/history.json',
    driveStatsFile: process.env.AUTORIP_DRIVE_STATS_FILE || '/var/lib/autorip/drive_stats.json',
    logDir: process.env.AUTORIP_LOG_DIR || '/tmp',
    crashTimeout: parseInt(process.env.AUTORIP_CRASH_TIMEOUT || '300', 10), // 5 minutes
    autoReset: process.env.AUTORIP_AUTO_RESET !== 'false', // Default enabled
};

// MIME types for static files
const MIME_TYPES = {
    '.html': 'text/html',
    '.css': 'text/css',
    '.js': 'application/javascript',
    '.json': 'application/json',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.ico': 'image/x-icon',
};

// Initialize services
const statusCollector = new StatusCollector(CONFIG);
const busManager = new BusManager(CONFIG);
const driveStats = new DriveStats(CONFIG);

// WebSocket clients
const wsClients = new Set();

// Broadcast to all WebSocket clients
function broadcast(type, data) {
    const message = JSON.stringify({ type, data, timestamp: Date.now() });
    wsClients.forEach(client => {
        if (client.readyState === 1) { // WebSocket.OPEN
            client.send(message);
        }
    });
}

// Status change handler
statusCollector.on('update', (drives) => {
    broadcast('drives', drives);
});

statusCollector.on('crash', (drive) => {
    console.log(`[CRASH] Drive ${drive.device} detected as crashed`);
    driveStats.recordCrash(drive.device);
    broadcast('crash', drive);

    // Auto-reset logic
    if (CONFIG.autoReset) {
        handleAutoReset(drive);
    }
});

// Auto-reset handler
async function handleAutoReset(crashedDrive) {
    try {
        const buses = await busManager.discoverBuses();
        const driveBus = buses.find(bus =>
            bus.drives.some(d => d.device === crashedDrive.device)
        );

        if (!driveBus) {
            console.log(`[AUTO-RESET] Cannot find bus for ${crashedDrive.device}`);
            return;
        }

        // Check if all drives on this bus are safe to reset
        const drives = await statusCollector.getDrives();
        const busDevices = driveBus.drives.map(d => d.device);
        const activeOnBus = drives.filter(d =>
            busDevices.includes(d.device) &&
            d.state === 'ripping'
        );

        if (activeOnBus.length > 0) {
            console.log(`[AUTO-RESET] Cannot reset bus ${driveBus.id} - active rips on: ${activeOnBus.map(d => d.device).join(', ')}`);
            return;
        }

        console.log(`[AUTO-RESET] Resetting bus ${driveBus.id} for crashed drive ${crashedDrive.device}`);
        await busManager.resetBus(driveBus.id);
        driveStats.recordReset(crashedDrive.device);
        broadcast('reset', { bus: driveBus, drive: crashedDrive.device });
    } catch (err) {
        console.error(`[AUTO-RESET] Error:`, err);
    }
}

// HTTP request handler
async function handleRequest(req, res) {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const pathname = url.pathname;

    // CORS headers
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method === 'OPTIONS') {
        res.writeHead(204);
        res.end();
        return;
    }

    // API routes
    if (pathname.startsWith('/api/')) {
        return handleApiRequest(req, res, pathname, url);
    }

    // Static files
    return handleStaticRequest(req, res, pathname);
}

// API request handler
async function handleApiRequest(req, res, pathname, url) {
    res.setHeader('Content-Type', 'application/json');

    try {
        // GET /api/drives - List all drives and their status
        if (pathname === '/api/drives' && req.method === 'GET') {
            const drives = await statusCollector.getDrives();
            const stats = driveStats.getAll();

            // Merge stats into drive data
            const enrichedDrives = drives.map(drive => ({
                ...drive,
                stats: stats[drive.device] || { crashCount: 0, lastCrash: null, health: 'good' }
            }));

            res.writeHead(200);
            res.end(JSON.stringify(enrichedDrives));
            return;
        }

        // GET /api/history - Get rip history
        if (pathname === '/api/history' && req.method === 'GET') {
            const limit = parseInt(url.searchParams.get('limit') || '100', 10);
            const offset = parseInt(url.searchParams.get('offset') || '0', 10);
            const history = await getHistory(limit, offset);
            res.writeHead(200);
            res.end(JSON.stringify(history));
            return;
        }

        // GET /api/logs/:device - Get log file for device
        if (pathname.startsWith('/api/logs/') && req.method === 'GET') {
            const device = pathname.split('/')[3];
            const lines = parseInt(url.searchParams.get('lines') || '100', 10);
            const log = await getDeviceLog(device, lines);
            res.writeHead(200);
            res.end(JSON.stringify({ device, log }));
            return;
        }

        // GET /api/buses - Get bus topology
        if (pathname === '/api/buses' && req.method === 'GET') {
            const buses = await busManager.discoverBuses();
            res.writeHead(200);
            res.end(JSON.stringify(buses));
            return;
        }

        // POST /api/buses/:id/reset - Reset a bus
        if (pathname.match(/^\/api\/buses\/[^/]+\/reset$/) && req.method === 'POST') {
            const busId = pathname.split('/')[3];
            const confirm = url.searchParams.get('confirm') === 'true';

            // Get bus info
            const buses = await busManager.discoverBuses();
            const bus = buses.find(b => b.id === busId);

            if (!bus) {
                res.writeHead(404);
                res.end(JSON.stringify({ error: 'Bus not found' }));
                return;
            }

            // Check for active rips
            const drives = await statusCollector.getDrives();
            const busDevices = bus.drives.map(d => d.device);
            const activeOnBus = drives.filter(d =>
                busDevices.includes(d.device) &&
                d.state === 'ripping'
            );

            if (activeOnBus.length > 0 && !confirm) {
                res.writeHead(409);
                res.end(JSON.stringify({
                    error: 'Active rips on bus',
                    activeDevices: activeOnBus.map(d => d.device),
                    requiresConfirm: true
                }));
                return;
            }

            // Perform reset
            await busManager.resetBus(busId);

            // Record stats for all crashed drives on this bus
            const crashedOnBus = drives.filter(d =>
                busDevices.includes(d.device) &&
                d.state === 'crashed'
            );
            crashedOnBus.forEach(d => driveStats.recordReset(d.device));

            broadcast('reset', { bus, manual: true });

            res.writeHead(200);
            res.end(JSON.stringify({ success: true, bus: busId }));
            return;
        }

        // GET /api/stats - Get drive statistics
        if (pathname === '/api/stats' && req.method === 'GET') {
            const stats = driveStats.getAll();
            res.writeHead(200);
            res.end(JSON.stringify(stats));
            return;
        }

        // POST /api/stats/:device/reset - Reset stats for a device
        if (pathname.match(/^\/api\/stats\/[^/]+\/reset$/) && req.method === 'POST') {
            const device = pathname.split('/')[3];
            driveStats.resetDevice(device);
            res.writeHead(200);
            res.end(JSON.stringify({ success: true }));
            return;
        }

        // 404 for unknown API routes
        res.writeHead(404);
        res.end(JSON.stringify({ error: 'Not found' }));

    } catch (err) {
        console.error('API error:', err);
        res.writeHead(500);
        res.end(JSON.stringify({ error: err.message }));
    }
}

// Static file handler
function handleStaticRequest(req, res, pathname) {
    // Default to index.html
    if (pathname === '/') {
        pathname = '/index.html';
    }

    const filePath = path.join(__dirname, 'public', pathname);
    const ext = path.extname(filePath);
    const mimeType = MIME_TYPES[ext] || 'application/octet-stream';

    fs.readFile(filePath, (err, data) => {
        if (err) {
            if (err.code === 'ENOENT') {
                res.writeHead(404, { 'Content-Type': 'text/plain' });
                res.end('Not Found');
            } else {
                res.writeHead(500, { 'Content-Type': 'text/plain' });
                res.end('Internal Server Error');
            }
            return;
        }

        res.writeHead(200, { 'Content-Type': mimeType });
        res.end(data);
    });
}

// Get history from file
async function getHistory(limit, offset) {
    try {
        const data = await fs.promises.readFile(CONFIG.historyFile, 'utf8');
        const history = JSON.parse(data);
        return history.slice(offset, offset + limit);
    } catch (err) {
        if (err.code === 'ENOENT') {
            return [];
        }
        throw err;
    }
}

// Get device log
async function getDeviceLog(device, lines) {
    const logFile = path.join(CONFIG.logDir, `autorip-${device}.log`);
    try {
        const data = await fs.promises.readFile(logFile, 'utf8');
        const allLines = data.split('\n');
        return allLines.slice(-lines).join('\n');
    } catch (err) {
        if (err.code === 'ENOENT') {
            return '';
        }
        throw err;
    }
}

// Create HTTP server
const server = http.createServer(handleRequest);

// Create WebSocket server
const wss = new WebSocketServer({ server });

wss.on('connection', (ws, req) => {
    console.log(`[WS] Client connected from ${req.socket.remoteAddress}`);
    wsClients.add(ws);

    // Send initial state
    statusCollector.getDrives().then(drives => {
        const stats = driveStats.getAll();
        const enrichedDrives = drives.map(drive => ({
            ...drive,
            stats: stats[drive.device] || { crashCount: 0, lastCrash: null, health: 'good' }
        }));
        ws.send(JSON.stringify({ type: 'drives', data: enrichedDrives, timestamp: Date.now() }));
    });

    ws.on('close', () => {
        console.log('[WS] Client disconnected');
        wsClients.delete(ws);
    });

    ws.on('error', (err) => {
        console.error('[WS] Error:', err);
        wsClients.delete(ws);
    });
});

// Start server
server.listen(CONFIG.port, CONFIG.host, () => {
    console.log(`
╔══════════════════════════════════════════════════════════════╗
║           Autorip Web Dashboard                              ║
╠══════════════════════════════════════════════════════════════╣
║  Server running at http://${CONFIG.host}:${CONFIG.port.toString().padEnd(24)}║
║  Status directory: ${CONFIG.statusDir.padEnd(39)}║
║  Auto-reset: ${(CONFIG.autoReset ? 'enabled' : 'disabled').padEnd(46)}║
╚══════════════════════════════════════════════════════════════╝
`);
});

// Start status collector
statusCollector.start();

// Graceful shutdown
process.on('SIGTERM', () => {
    console.log('\nShutting down...');
    statusCollector.stop();
    driveStats.save();
    server.close(() => {
        process.exit(0);
    });
});

process.on('SIGINT', () => {
    console.log('\nShutting down...');
    statusCollector.stop();
    driveStats.save();
    server.close(() => {
        process.exit(0);
    });
});
