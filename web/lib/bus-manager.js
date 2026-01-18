/**
 * Bus Manager Module
 *
 * Discovers bus topology (which drives share which bus) and
 * provides bus reset functionality for crashed drives.
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

class BusManager {
    constructor(config) {
        this.config = config;
        this.busCache = null;
        this.cacheTime = 0;
        this.cacheTTL = 60000; // 1 minute cache
    }

    /**
     * Discover all buses and their attached optical drives
     * Returns array of bus objects with their drives
     */
    async discoverBuses() {
        // Return cached result if fresh
        if (this.busCache && (Date.now() - this.cacheTime) < this.cacheTTL) {
            return this.busCache;
        }

        const buses = new Map();

        try {
            // Find all sr* devices
            const devDir = '/dev';
            const files = await fs.promises.readdir(devDir);
            const srDevices = files.filter(f => f.match(/^sr\d+$/));

            for (const device of srDevices) {
                const busInfo = await this.getDeviceBus(device);
                if (busInfo) {
                    const busId = busInfo.busId;
                    if (!buses.has(busId)) {
                        buses.set(busId, {
                            id: busId,
                            type: busInfo.type,
                            path: busInfo.path,
                            controller: busInfo.controller,
                            drives: [],
                            resetSupported: busInfo.resetSupported,
                            resetPath: busInfo.resetPath,
                        });
                    }
                    buses.get(busId).drives.push({
                        device,
                        devicePath: `/dev/${device}`,
                        sysPath: busInfo.deviceSysPath,
                    });
                }
            }
        } catch (err) {
            console.error(`[BusManager] Discovery error: ${err.message}`);
        }

        this.busCache = Array.from(buses.values());
        this.cacheTime = Date.now();
        return this.busCache;
    }

    /**
     * Get bus information for a specific device
     */
    async getDeviceBus(device) {
        try {
            // Get the device's sysfs path
            const blockPath = `/sys/block/${device}`;

            if (!fs.existsSync(blockPath)) {
                return null;
            }

            // Follow the device symlink to find the actual hardware path
            const deviceLink = await fs.promises.readlink(path.join(blockPath, 'device'));
            const deviceSysPath = path.resolve(blockPath, deviceLink);

            // Walk up the path to find the bus controller
            let currentPath = deviceSysPath;
            let busInfo = null;

            while (currentPath && currentPath !== '/sys') {
                // Check for USB bus
                if (currentPath.includes('/usb') && fs.existsSync(path.join(currentPath, 'authorized'))) {
                    // Found USB device
                    const busMatch = currentPath.match(/\/usb\d+\/(\d+-[\d.]+)/);
                    if (busMatch) {
                        busInfo = {
                            type: 'usb',
                            busId: `usb-${busMatch[1]}`,
                            path: currentPath,
                            controller: this.getUsbController(currentPath),
                            resetSupported: true,
                            resetPath: path.join(currentPath, 'authorized'),
                            deviceSysPath,
                        };
                        break;
                    }
                }

                // Check for PCI device with reset capability
                const resetFile = path.join(currentPath, 'reset');
                if (fs.existsSync(resetFile)) {
                    const pciMatch = currentPath.match(/\/([0-9a-f:]+\.[0-9a-f]+)$/i);
                    if (pciMatch) {
                        busInfo = {
                            type: 'pci',
                            busId: `pci-${pciMatch[1]}`,
                            path: currentPath,
                            controller: await this.getPciController(currentPath),
                            resetSupported: true,
                            resetPath: resetFile,
                            deviceSysPath,
                        };
                        break;
                    }
                }

                // Check for SCSI host
                if (currentPath.includes('/host') && fs.existsSync(path.join(currentPath, 'scsi_host'))) {
                    const hostMatch = currentPath.match(/\/(host\d+)/);
                    if (hostMatch) {
                        // Find parent PCI device
                        const pciPath = await this.findParentPci(currentPath);
                        busInfo = {
                            type: 'sata',
                            busId: `sata-${hostMatch[1]}`,
                            path: currentPath,
                            controller: pciPath ? await this.getPciController(pciPath) : 'Unknown SATA',
                            resetSupported: pciPath && fs.existsSync(path.join(pciPath, 'reset')),
                            resetPath: pciPath ? path.join(pciPath, 'reset') : null,
                            deviceSysPath,
                        };
                        break;
                    }
                }

                currentPath = path.dirname(currentPath);
            }

            // Fallback if no specific bus found
            if (!busInfo) {
                busInfo = {
                    type: 'unknown',
                    busId: `unknown-${device}`,
                    path: deviceSysPath,
                    controller: 'Unknown',
                    resetSupported: false,
                    resetPath: null,
                    deviceSysPath,
                };
            }

            return busInfo;
        } catch (err) {
            console.error(`[BusManager] Error getting bus for ${device}: ${err.message}`);
            return null;
        }
    }

    /**
     * Find parent PCI device
     */
    async findParentPci(startPath) {
        let currentPath = startPath;
        while (currentPath && currentPath !== '/sys') {
            if (currentPath.match(/\/[0-9a-f:]+\.[0-9a-f]+$/i)) {
                if (fs.existsSync(path.join(currentPath, 'vendor'))) {
                    return currentPath;
                }
            }
            currentPath = path.dirname(currentPath);
        }
        return null;
    }

    /**
     * Get PCI controller description
     */
    async getPciController(pciPath) {
        try {
            const vendor = (await fs.promises.readFile(path.join(pciPath, 'vendor'), 'utf8')).trim();
            const device = (await fs.promises.readFile(path.join(pciPath, 'device'), 'utf8')).trim();

            // Try to get human-readable name from lspci
            try {
                const pciId = path.basename(pciPath);
                const lspciOutput = execSync(`lspci -s ${pciId} 2>/dev/null`, { encoding: 'utf8' });
                const match = lspciOutput.match(/: (.+)$/);
                if (match) {
                    return match[1].trim();
                }
            } catch (e) {
                // lspci not available or failed
            }

            return `PCI ${vendor}:${device}`;
        } catch (err) {
            return 'Unknown PCI';
        }
    }

    /**
     * Get USB controller description
     */
    getUsbController(usbPath) {
        try {
            const manufacturer = fs.readFileSync(path.join(usbPath, 'manufacturer'), 'utf8').trim();
            const product = fs.readFileSync(path.join(usbPath, 'product'), 'utf8').trim();
            return `${manufacturer} ${product}`;
        } catch (err) {
            return 'USB Device';
        }
    }

    /**
     * Reset a bus by ID
     */
    async resetBus(busId) {
        const buses = await this.discoverBuses();
        const bus = buses.find(b => b.id === busId);

        if (!bus) {
            throw new Error(`Bus ${busId} not found`);
        }

        if (!bus.resetSupported || !bus.resetPath) {
            throw new Error(`Reset not supported for bus ${busId}`);
        }

        console.log(`[BusManager] Resetting bus ${busId} (${bus.type}) at ${bus.resetPath}`);

        try {
            if (bus.type === 'usb') {
                // USB reset: toggle authorized flag
                await fs.promises.writeFile(bus.resetPath, '0');
                await this.sleep(1000);
                await fs.promises.writeFile(bus.resetPath, '1');
            } else {
                // PCI/SATA reset: write 1 to reset file
                await fs.promises.writeFile(bus.resetPath, '1');
            }

            // Wait for devices to re-enumerate
            await this.sleep(3000);

            // Clear cache to force re-discovery
            this.busCache = null;

            console.log(`[BusManager] Bus ${busId} reset complete`);
            return true;
        } catch (err) {
            console.error(`[BusManager] Reset failed: ${err.message}`);
            throw new Error(`Reset failed: ${err.message}. May require root privileges.`);
        }
    }

    /**
     * Sleep helper
     */
    sleep(ms) {
        return new Promise(resolve => setTimeout(resolve, ms));
    }

    /**
     * Get bus info for a specific device
     */
    async getBusForDevice(device) {
        const buses = await this.discoverBuses();
        return buses.find(bus => bus.drives.some(d => d.device === device)) || null;
    }
}

module.exports = BusManager;
