/**
 * Drive Statistics Module
 *
 * Tracks crash history and health statistics for each drive.
 */

const fs = require('fs');
const path = require('path');

class DriveStats {
    constructor(config) {
        this.config = config;
        this.statsFile = config.driveStatsFile;
        this.stats = {};
        this.dirty = false;
        this.saveInterval = null;

        this.load();

        // Auto-save every 30 seconds if dirty
        this.saveInterval = setInterval(() => {
            if (this.dirty) {
                this.save();
            }
        }, 30000);
    }

    /**
     * Load stats from file
     */
    load() {
        try {
            const data = fs.readFileSync(this.statsFile, 'utf8');
            this.stats = JSON.parse(data);
            console.log(`[DriveStats] Loaded stats for ${Object.keys(this.stats).length} drives`);
        } catch (err) {
            if (err.code !== 'ENOENT') {
                console.error(`[DriveStats] Error loading: ${err.message}`);
            }
            this.stats = {};
        }

        // Clean up old entries (older than 30 days)
        this.cleanup();
    }

    /**
     * Save stats to file
     */
    save() {
        try {
            const dir = path.dirname(this.statsFile);
            if (!fs.existsSync(dir)) {
                fs.mkdirSync(dir, { recursive: true });
            }
            fs.writeFileSync(this.statsFile, JSON.stringify(this.stats, null, 2));
            this.dirty = false;
        } catch (err) {
            console.error(`[DriveStats] Error saving: ${err.message}`);
        }
    }

    /**
     * Get stats for all drives
     */
    getAll() {
        const result = {};
        for (const [device, data] of Object.entries(this.stats)) {
            result[device] = this.enrichStats(device, data);
        }
        return result;
    }

    /**
     * Get stats for a specific drive
     */
    get(device) {
        const data = this.stats[device];
        if (!data) {
            return {
                device,
                crashCount: 0,
                resetCount: 0,
                lastCrash: null,
                lastReset: null,
                crashHistory: [],
                health: 'good',
                crashRate: 0,
            };
        }
        return this.enrichStats(device, data);
    }

    /**
     * Enrich raw stats with computed values
     */
    enrichStats(device, data) {
        const now = Date.now();
        const weekAgo = now - (7 * 24 * 60 * 60 * 1000);
        const monthAgo = now - (30 * 24 * 60 * 60 * 1000);

        // Filter crash history to last 30 days
        const recentCrashes = (data.crashHistory || []).filter(c => c.timestamp > monthAgo);

        // Count crashes in last week
        const crashesThisWeek = recentCrashes.filter(c => c.timestamp > weekAgo).length;

        // Determine health status
        let health = 'good';
        if (crashesThisWeek >= 5) {
            health = 'replace';
        } else if (crashesThisWeek >= 3) {
            health = 'warning';
        }

        return {
            device,
            crashCount: data.crashCount || 0,
            resetCount: data.resetCount || 0,
            lastCrash: data.lastCrash || null,
            lastReset: data.lastReset || null,
            crashHistory: recentCrashes,
            health,
            crashRate: crashesThisWeek,
            crashesThisWeek,
            crashesThisMonth: recentCrashes.length,
        };
    }

    /**
     * Record a crash event
     */
    recordCrash(device) {
        const now = Date.now();

        if (!this.stats[device]) {
            this.stats[device] = {
                crashCount: 0,
                resetCount: 0,
                lastCrash: null,
                lastReset: null,
                crashHistory: [],
            };
        }

        this.stats[device].crashCount++;
        this.stats[device].lastCrash = now;
        this.stats[device].crashHistory.push({
            timestamp: now,
            type: 'crash',
        });

        this.dirty = true;
        console.log(`[DriveStats] Recorded crash for ${device} (total: ${this.stats[device].crashCount})`);
    }

    /**
     * Record a reset event
     */
    recordReset(device) {
        const now = Date.now();

        if (!this.stats[device]) {
            this.stats[device] = {
                crashCount: 0,
                resetCount: 0,
                lastCrash: null,
                lastReset: null,
                crashHistory: [],
            };
        }

        this.stats[device].resetCount++;
        this.stats[device].lastReset = now;
        this.stats[device].crashHistory.push({
            timestamp: now,
            type: 'reset',
        });

        this.dirty = true;
        console.log(`[DriveStats] Recorded reset for ${device} (total: ${this.stats[device].resetCount})`);
    }

    /**
     * Reset stats for a specific device (after hardware replacement)
     */
    resetDevice(device) {
        delete this.stats[device];
        this.dirty = true;
        console.log(`[DriveStats] Reset stats for ${device}`);
    }

    /**
     * Clean up old entries (older than 30 days)
     */
    cleanup() {
        const cutoff = Date.now() - (30 * 24 * 60 * 60 * 1000);
        let cleaned = false;

        for (const device of Object.keys(this.stats)) {
            const data = this.stats[device];
            if (data.crashHistory) {
                const before = data.crashHistory.length;
                data.crashHistory = data.crashHistory.filter(c => c.timestamp > cutoff);
                if (data.crashHistory.length < before) {
                    cleaned = true;
                }
            }
        }

        if (cleaned) {
            this.dirty = true;
        }
    }

    /**
     * Stop the auto-save interval
     */
    stop() {
        if (this.saveInterval) {
            clearInterval(this.saveInterval);
            this.saveInterval = null;
        }
        this.save();
    }
}

module.exports = DriveStats;
