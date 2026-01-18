/**
 * Status Collector Module
 *
 * Monitors drive status files and detects crashed drives
 * based on stale heartbeats or I/O timeouts.
 */

const fs = require('fs');
const path = require('path');
const { EventEmitter } = require('events');
const { execSync, spawn } = require('child_process');

class StatusCollector extends EventEmitter {
    constructor(config) {
        super();
        this.config = config;
        this.statusDir = config.statusDir;
        this.crashTimeout = config.crashTimeout * 1000; // Convert to ms
        this.pollInterval = 2000; // 2 seconds
        this.drives = new Map();
        this.timer = null;
        this.watcher = null;
    }

    /**
     * Start monitoring status files
     */
    start() {
        console.log(`[StatusCollector] Starting - watching ${this.statusDir}`);

        // Ensure status directory exists
        if (!fs.existsSync(this.statusDir)) {
            try {
                fs.mkdirSync(this.statusDir, { recursive: true });
            } catch (err) {
                console.error(`[StatusCollector] Cannot create status directory: ${err.message}`);
            }
        }

        // Initial scan
        this.scanDrives();

        // Set up file watcher for quick updates
        try {
            this.watcher = fs.watch(this.statusDir, (eventType, filename) => {
                if (filename && filename.endsWith('.json')) {
                    this.updateDrive(filename.replace('.json', ''));
                }
            });
        } catch (err) {
            console.error(`[StatusCollector] Cannot watch directory: ${err.message}`);
        }

        // Periodic poll for crash detection and drive discovery
        this.timer = setInterval(() => {
            this.scanDrives();
            this.checkForCrashes();
        }, this.pollInterval);
    }

    /**
     * Stop monitoring
     */
    stop() {
        if (this.timer) {
            clearInterval(this.timer);
            this.timer = null;
        }
        if (this.watcher) {
            this.watcher.close();
            this.watcher = null;
        }
    }

    /**
     * Scan for all optical drives in the system
     */
    async scanDrives() {
        try {
            // Find all sr* devices
            const srDevices = [];
            const devDir = '/dev';

            const files = await fs.promises.readdir(devDir);
            for (const file of files) {
                if (file.match(/^sr\d+$/)) {
                    srDevices.push(file);
                }
            }

            // Update each drive
            for (const device of srDevices) {
                await this.updateDrive(device);
            }

            // Remove drives that no longer exist
            for (const device of this.drives.keys()) {
                if (!srDevices.includes(device)) {
                    this.drives.delete(device);
                }
            }

            // Emit update
            this.emit('update', Array.from(this.drives.values()));
        } catch (err) {
            console.error(`[StatusCollector] Scan error: ${err.message}`);
        }
    }

    /**
     * Update a single drive's status
     */
    async updateDrive(device) {
        const statusFile = path.join(this.statusDir, `${device}.json`);
        let status = null;

        // Try to read status file
        try {
            const data = await fs.promises.readFile(statusFile, 'utf8');
            status = JSON.parse(data);
        } catch (err) {
            // No status file - drive is idle or unknown
        }

        // Build drive info
        const driveInfo = {
            device,
            devicePath: `/dev/${device}`,
            state: status?.state || 'idle',
            discName: status?.discName || '',
            discType: status?.discType || '',
            progress: status?.progress || 0,
            eta: status?.eta || '',
            operation: status?.operation || '',
            titleCurrent: status?.titleCurrent || 0,
            titleTotal: status?.titleTotal || 0,
            errorMessage: status?.errorMessage || '',
            startTime: status?.startTime || null,
            elapsed: status?.elapsed || 0,
            heartbeat: status?.heartbeat || null,
            logFile: status?.logFile || `/tmp/autorip-${device}.log`,
        };

        // Check for crash condition (stale heartbeat during rip)
        if (driveInfo.state === 'ripping' && driveInfo.heartbeat) {
            const now = Math.floor(Date.now() / 1000);
            const heartbeatAge = now - driveInfo.heartbeat;

            if (heartbeatAge > this.config.crashTimeout) {
                driveInfo.state = 'crashed';
                driveInfo.errorMessage = `Heartbeat stale for ${heartbeatAge} seconds`;
            }
        }

        // Store and check for state changes
        const previous = this.drives.get(device);
        this.drives.set(device, driveInfo);

        // Emit crash event if state changed to crashed
        if (driveInfo.state === 'crashed' && previous?.state !== 'crashed') {
            this.emit('crash', driveInfo);
        }
    }

    /**
     * Check all drives for crash conditions
     */
    checkForCrashes() {
        const now = Math.floor(Date.now() / 1000);

        for (const [device, info] of this.drives) {
            if (info.state === 'ripping' && info.heartbeat) {
                const heartbeatAge = now - info.heartbeat;

                if (heartbeatAge > this.config.crashTimeout) {
                    // Verify with I/O probe
                    const isCrashed = this.probeDevice(device);

                    if (isCrashed) {
                        const previous = { ...info };
                        info.state = 'crashed';
                        info.errorMessage = `Drive unresponsive (heartbeat: ${heartbeatAge}s, I/O failed)`;
                        this.drives.set(device, info);

                        if (previous.state !== 'crashed') {
                            this.emit('crash', info);
                        }
                    }
                }
            }
        }
    }

    /**
     * Probe a device to check if it's responsive
     */
    probeDevice(device) {
        try {
            // Try a quick blkid with timeout
            execSync(`timeout 5 blkid /dev/${device}`, {
                timeout: 6000,
                stdio: 'pipe'
            });
            return false; // Device responded
        } catch (err) {
            // Check if it was a timeout or actual error
            if (err.killed || err.signal === 'SIGTERM') {
                return true; // Device timed out - likely crashed
            }
            // Other errors (no media, etc.) are not crash conditions
            return false;
        }
    }

    /**
     * Get all drive statuses
     */
    async getDrives() {
        // Refresh and return
        await this.scanDrives();
        return Array.from(this.drives.values());
    }

    /**
     * Get a specific drive's status
     */
    getDrive(device) {
        return this.drives.get(device) || null;
    }
}

module.exports = StatusCollector;
