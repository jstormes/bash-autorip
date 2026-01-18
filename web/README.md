# Autorip Web Dashboard

A real-time web dashboard for monitoring the bash-autorip disc ripping system.

## Features

- **Real-time drive monitoring** - See status of all optical drives at a glance
- **Progress tracking** - Watch rip progress with percentage and ETA
- **Crash detection** - Automatic detection of crashed/unresponsive drives
- **Bus reset management** - Reset crashed drives directly from the web interface
- **Live log viewer** - Stream logs from any drive in real-time
- **Rip history** - Track success/failure rates and partial rips
- **Drive health stats** - Monitor crash frequency to identify failing hardware

## Quick Start

```bash
# Clone or copy the repository to your server
# Then run the installer:

cd bash-autorip/web
sudo bash install.sh

# Dashboard will be available at http://your-server:8080
```

The installer will:
1. Check for and install Node.js 20.x if needed
2. Create `/opt/autorip-web` and copy application files
3. Create `/var/lib/autorip/status` for status files
4. Install and start the systemd service
5. Configure the service to start on boot

## Manual Installation

If you prefer to install manually:

```bash
# 1. Install Node.js (>= 18)
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# 2. Create directories
sudo mkdir -p /opt/autorip-web/lib /opt/autorip-web/public
sudo mkdir -p /var/lib/autorip/status

# 3. Copy files
sudo cp server.js package.json /opt/autorip-web/
sudo cp lib/*.js /opt/autorip-web/lib/
sudo cp public/* /opt/autorip-web/public/

# 4. Set permissions
sudo chmod 755 /opt/autorip-web/server.js
sudo chmod 755 /var/lib/autorip /var/lib/autorip/status

# 5. Install dependencies
cd /opt/autorip-web
sudo npm install --production

# 6. Create systemd service (see install.sh for service file contents)
# Or copy the service file:
sudo cp autorip-web.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable autorip-web
sudo systemctl start autorip-web
```

## Configuration

Configuration is done via environment variables in the systemd service file:

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTORIP_WEB_PORT` | `8080` | HTTP server port |
| `AUTORIP_WEB_HOST` | `127.0.0.1` | Bind address (use `0.0.0.0` for LAN access) |
| `AUTORIP_STATUS_DIR` | `/var/lib/autorip/status` | Directory for status files |
| `AUTORIP_HISTORY_FILE` | `/var/lib/autorip/history.json` | Rip history file |
| `AUTORIP_DRIVE_STATS_FILE` | `/var/lib/autorip/drive_stats.json` | Drive statistics file |
| `AUTORIP_CRASH_TIMEOUT` | `300` | Seconds without heartbeat before crash detection |
| `AUTORIP_AUTO_RESET` | `true` | Enable automatic bus reset for crashed drives |

Edit the service file to change settings:
```bash
sudo systemctl edit autorip-web
```

Add overrides:
```ini
[Service]
Environment=AUTORIP_WEB_HOST=0.0.0.0
Environment=AUTORIP_WEB_PORT=8081
```

Then restart:
```bash
sudo systemctl restart autorip-web
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/drives` | GET | List all drives with status |
| `/api/history` | GET | Get rip history (supports `?limit=N&offset=N`) |
| `/api/logs/:device` | GET | Get log for device (supports `?lines=N`) |
| `/api/buses` | GET | Get bus topology |
| `/api/buses/:id/reset` | POST | Reset a bus (add `?confirm=true` to force) |
| `/api/stats` | GET | Get drive statistics |
| `/api/stats/:device/reset` | POST | Reset stats for a device |

## WebSocket

Connect to `ws://host:port/` for real-time updates. Messages are JSON with:

```json
{
  "type": "drives|crash|reset",
  "data": { ... },
  "timestamp": 1234567890123
}
```

## Status File Format

The autorip.sh script writes status to `/var/lib/autorip/status/{device}.json`:

```json
{
  "device": "sr0",
  "devicePath": "/dev/sr0",
  "state": "ripping",
  "discName": "Movie Title",
  "discType": "video",
  "progress": 45,
  "operation": "Ripping title 2 of 5",
  "titleCurrent": 2,
  "titleTotal": 5,
  "heartbeat": 1234567890,
  "startTime": "1234567800",
  "elapsed": 90
}
```

## Architecture

```
┌─────────────────┐     ┌──────────────────┐
│  Web Browser    │────▶│  Node.js Server  │
│  (Dashboard)    │◀────│  (port 8080)     │
└─────────────────┘ WS  └────────┬─────────┘
                                 │
                    ┌────────────┼────────────┐
                    ▼            ▼            ▼
              ┌──────────┐ ┌──────────┐ ┌──────────┐
              │ Status   │ │ History  │ │ /sys     │
              │ Files    │ │ File     │ │ (buses)  │
              └──────────┘ └──────────┘ └──────────┘
                    ▲
                    │ writes
              ┌──────────┐
              │autorip.sh│
              │ (udev)   │
              └──────────┘
```

## Troubleshooting

### Dashboard shows "No drives detected"
- Ensure `/var/lib/autorip/status` exists and is writable
- Check that autorip.sh is running and writing status files
- Verify optical drives are detected: `ls /dev/sr*`

### Bus reset fails
- Bus reset requires root privileges
- Check that the service is running as root
- USB drives may need the `authorized` file to be writable

### Connection lost / reconnecting
- Check service status: `sudo systemctl status autorip-web`
- View logs: `sudo journalctl -u autorip-web -f`
- Verify port is not blocked by firewall

### Crash detection too sensitive/insensitive
- Adjust `AUTORIP_CRASH_TIMEOUT` (default 300 seconds)
- Lower values detect crashes faster but may trigger false positives
