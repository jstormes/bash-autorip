# Product Design Requirements: Autorip Web Interface

## Document Status
**Version:** 1.0
**Author:** James Stormes
**Date:** 2026-01-18
**Status:** Ready for Final Review

## Technology Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Tech Stack** | Node.js | Native WebSocket support, npm ecosystem, good for real-time updates |
| **Deployment** | Systemd service | Direct hardware access, lower overhead, native Linux integration |
| **Bus Reset** | Smart auto-reset + manual button | Auto-reset when all drives on bus idle; manual button with alerts for active drives |
| **Authentication** | None (v1) | Localhost binding by default, rely on network firewall for remote access |
| **UI Framework** | Vanilla HTML/CSS/JS | Simple, no build step, readable for blog audience |
| **History Retention** | 30 days / 1000 entries | Whichever limit reached first |
| **Notifications** | Defer to v2 | Focus on core functionality first |

---

## 1. Problem Statement

### Background
The bash-autorip system automates CD/DVD/Blu-ray ripping using udev triggers. While the current implementation handles the ripping workflow reliably, operators lack visibility into the system's real-time status, especially in multi-drive environments.

### Core Problems

1. **No Operational Visibility** - Operators cannot see what's happening across multiple drives without manually tailing log files for each device.

2. **Drive Firmware Crashes** - Optical drives occasionally experience firmware lockups that require a bus reset (SATA/PCI or USB) to recover. Currently, there's no automated detection of this condition, leading to drives sitting in a crashed state indefinitely.

3. **No Progress Information** - Rips can take 15-90+ minutes. Operators have no way to know how much longer a rip will take without examining raw log output.

4. **Error Discovery Delay** - Failed rips are only discovered when checking the output directory or manually reviewing logs.

---

## 2. User Stories

### Primary Users
- **Home Media Server Operators** - Users with multi-drive setups ripping personal media collections
- **Media Archivists** - Users performing bulk digitization projects

### User Stories

| ID | As a... | I want to... | So that... |
|----|---------|--------------|------------|
| US-01 | Operator | See the status of all connected drives on a single dashboard | I can monitor the entire system at a glance |
| US-02 | Operator | See what disc is currently being ripped in each drive | I know which disc is being processed |
| US-03 | Operator | See progress percentage and estimated time remaining | I can plan when to load new discs |
| US-04 | Operator | See error logs for failed rips | I can diagnose problems without SSH access |
| US-05 | Operator | Be alerted when a drive has crashed/become unresponsive | I can reset the bus before the system sits idle |
| US-06 | Operator | See a history of recent rips (success/failure) | I can verify the system is working correctly |
| US-07 | Operator | View the dashboard from any device on my network | I don't need to be at the server console |
| US-08 | Operator | Have crashed drives automatically reset when safe | The system recovers without my intervention |
| US-09 | Operator | Manually reset a bus with appropriate warnings | I can force recovery when needed, understanding the risks |
| US-10 | Operator | See how many times each drive has crashed | I can identify failing drives that need replacement |
| US-11 | Operator | Know when individual video titles fail during a rip | I can re-rip specific titles that didn't copy successfully |

---

## 3. Functional Requirements

### FR-01: Drive Status Dashboard

**Description:** A web page displaying the real-time status of all optical drives.

**Display Elements per Drive:**
- Device identifier (sr0, sr1, etc.)
- Current state: `idle`, `detecting`, `ripping`, `ejecting`, `error`, `crashed`
- Disc name/title (when available)
- Disc type (Audio CD, DVD, Blu-ray)
- Progress percentage (0-100%)
- Estimated time remaining (HH:MM:SS)
- Current operation (e.g., "Ripping title 2 of 5")

**Update Frequency:** Poll every 2-5 seconds or use WebSocket for real-time updates.

### FR-02: Error Log Viewer

**Description:** Display error logs and output from current and recent rips.

**Requirements:**
- Show last N lines of current rip output (live tail)
- Show complete error logs for failed rips
- Filter by device
- Filter by time range
- Search within logs

### FR-03: Drive Health Monitoring

**Description:** Detect when a drive has become unresponsive.

**Crash Detection Indicators:**
- Rip process running but no progress for > 5 minutes
- Drive commands timeout (e.g., `blkid`, `eject` hang)
- Process stuck in uninterruptible sleep (D state)
- MakeMKV stuck with no output

**Alert Mechanism:**
- Visual indicator on dashboard (red status)
- Clear list of which specific drives are down
- Log entry for external monitoring integration

### FR-06: Bus Reset Management

**Description:** Provide mechanism to reset drives that have experienced firmware crashes.

**Bus Detection:**
- Discover bus topology (which drives share which bus)
- Support both SATA/PCI and USB bus types (generic implementation)
- Identify bus controller for each optical drive

**Auto-Reset Logic:**
- When a crashed drive is detected AND all drives on that bus are idle (not actively ripping)
- Automatically trigger bus reset
- Log the reset action
- Re-detect drives after reset

**Manual Reset:**
- Provide "Reset Bus" button per bus on dashboard
- If any drive on the bus is actively ripping, show warning:
  - "Warning: Drive sr1 is currently ripping. Reset will interrupt this operation."
  - List all drives that will be affected
- Require confirmation before proceeding
- Show which drives are down and which are active

**Technical Implementation:**
- Use `echo 1 > /sys/bus/pci/devices/XXXX/reset` for PCI/SATA
- Use `echo 1 > /sys/bus/usb/devices/X-X/authorized` toggle for USB
- Requires appropriate permissions (root or sudo)

### FR-04: Progress Tracking

**Description:** Capture and display rip progress.

**Data Sources:**
- MakeMKV: Parse `PRGV:current,total,max` messages
- abcde: Parse track progress output
- Calculate percentage and ETA

### FR-07: Drive Crash Statistics

**Description:** Track crash history per drive to identify failing hardware.

**Tracking Data:**
- Total crash count per drive (lifetime)
- Crash timestamps (last 30 days detailed)
- Crash rate (crashes per week/month)
- Last crash date

**Display:**
- Crash count badge on drive status card
- Warning indicator when crash rate exceeds threshold (e.g., >3 crashes/week)
- "Drive Health" indicator: Good / Warning / Replace Soon
- Drill-down view showing crash history timeline

**Persistence:**
- Store in `/var/lib/autorip/drive_stats.json`
- Survive service restarts
- Reset option per drive (after hardware replacement)

### FR-08: Partial Rip Failure Tracking

**Description:** Detect and report when individual video titles fail during an otherwise successful rip.

**Detection:**
- Parse MakeMKV output for per-title errors (MSG:5010, MSG:2010, etc.)
- Compare expected titles vs. successfully written MKV files
- Track titles that started but didn't complete

**Reporting:**
- Show "Partial Success" status (distinct from full success or full failure)
- List specific titles that failed with error details
- Include in rip history with clear indication
- Dashboard shows warning icon for partial failures

**Display per Rip:**
- Total titles attempted: X
- Titles succeeded: Y
- Titles failed: Z (with title names/numbers)
- Error messages for failed titles

**Use Case Example:**
```
Disc: "Movie Collection"
Status: PARTIAL SUCCESS (2 of 3 titles)
  ✓ Title 1: Feature Film (02:15:30) - OK
  ✓ Title 2: Behind the Scenes (00:45:00) - OK
  ✗ Title 3: Deleted Scenes (00:12:00) - Read error at sector 12345
```

### FR-05: Rip History

**Description:** Show recent rip activity.

**Display:**
- Last 50-100 rips
- Disc name, type, device, start time, duration, status
- Link to output directory
- Link to error logs (if failed)

---

## 4. Non-Functional Requirements

### NFR-01: Lightweight
- Minimal resource usage (server runs on low-power hardware)
- No heavy frameworks or databases
- Target: < 50MB RAM for web service

### NFR-02: Simple Deployment
- Single binary or simple script
- No external database required
- Configuration via environment variables (consistent with autorip.sh)

### NFR-03: Responsive Design
- Usable on mobile devices
- Auto-refresh without manual intervention

### NFR-04: Security
- Listen on localhost (127.0.0.1) by default
- Configurable bind address via environment variable for LAN access
- No authentication in v1 (rely on network-level security)
- No sensitive data exposure (disc names, paths only)

---

## 5. Technical Decisions (Resolved)

### Q1: Technology Stack - **DECIDED: Node.js**

Node.js selected for:
- Native WebSocket support for real-time updates
- npm ecosystem with good libraries for file watching, process management
- JavaScript/TypeScript throughout the stack
- Sufficient for system integration tasks

### Q2: State Storage - **DECIDED: File-based**

File-based JSON storage in `/var/lib/autorip/`:
- Matches existing autorip.sh patterns
- No database dependencies
- Easy to inspect/debug
- Survives service restarts
- autorip.sh writes status, web service reads

### Q3: Progress Capture Architecture - **DECIDED: Hybrid**

Two-part approach:
- **A) Modify autorip.sh** - Write structured progress to `/var/lib/autorip/status/{device}.json`
- **B) Log parsing** - Supplement with `/tmp/autorip-*.log` parsing for detailed output

### Q4: Drive Crash Detection Method - **DECIDED: Watchdog + I/O**

Combined approach:
- **A) Watchdog timer** - autorip.sh writes heartbeat to status file every 30 seconds
- **C) I/O monitoring** - Web service can probe drive responsiveness if heartbeat stale

### Q5: Bus Reset Capability - **DECIDED: Smart Auto + Manual**

- Auto-reset crashed drives when all drives on that bus are idle
- Manual reset button with warning if drives are active
- Generic implementation supporting SATA/PCI and USB buses

---

## 6. Architecture Sketch

```
┌─────────────────────────────────────────────────────────────────┐
│                        Web Browser                               │
│                    (Dashboard View)                              │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  Drive Status Cards  │  Log Viewer  │  Bus Reset Panel      ││
│  └─────────────────────────────────────────────────────────────┘│
└──────────────────────────┬──────────────────────────────────────┘
                           │ HTTP/WebSocket
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                 Node.js Web Service (systemd)                    │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │ REST API    │  │ WebSocket   │  │ Status Collector        │  │
│  │ /api/drives │  │ /ws/status  │  │ - Watch status files    │  │
│  │ /api/logs   │  │             │  │ - Detect stale heartbeat│  │
│  │ /api/history│  │             │  │ - Check drive health    │  │
│  │ /api/buses  │  │             │  │ - Auto-reset logic      │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘  │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ Bus Reset Manager                                            ││
│  │ - Discover bus topology from /sys                            ││
│  │ - Track which drives on which bus                            ││
│  │ - Auto-reset when all drives idle + crashed detected         ││
│  │ - Manual reset with confirmation                             ││
│  └─────────────────────────────────────────────────────────────┘│
└──────────────────────────┬──────────────────────────────────────┘
                           │ File I/O + /sys access
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Shared State Layer                            │
│  /var/lib/autorip/                                               │
│  ├── status/                                                     │
│  │   ├── sr0.json    # Per-drive status + heartbeat             │
│  │   └── sr1.json                                                │
│  ├── history.json    # Recent rip history (includes partial failures) │
│  ├── buses.json      # Discovered bus topology cache             │
│  └── drive_stats.json # Per-drive crash counts and health stats  │
└──────────────────────────┬──────────────────────────────────────┘
                           │
          ┌────────────────┴────────────────┐
          ▼                                 ▼
┌─────────────────────┐          ┌─────────────────────┐
│   autorip.sh (sr0)  │          │   autorip.sh (sr1)  │
│   - Writes status   │          │   - Writes status   │
│   - Heartbeat every │          │   - Heartbeat every │
│     30 seconds      │          │     30 seconds      │
└─────────────────────┘          └─────────────────────┘
          │                                 │
          └────────────┬────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Hardware Layer                                │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  PCI Bus 0000:03:00.0 (SATA Controller)                     ││
│  │    └── sr0, sr1 (optical drives)                            ││
│  │  PCI Bus 0000:05:00.0 (USB Controller)                      ││
│  │    └── sr2 (USB optical drive)                              ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

---

## 7. Open Questions

1. ~~**Deployment Environment:** Docker container, systemd service, or both?~~ **RESOLVED: Systemd service**

2. ~~**Authentication:** Is basic auth sufficient, or need something stronger?~~ **RESOLVED: None for v1**

3. ~~**Notification Integration:** Email, Slack, webhook on errors?~~ **RESOLVED: Defer to v2**

4. ~~**Historical Data:** How long to retain rip history?~~ **RESOLVED: 30 days or 1000 entries, whichever first**

5. **Multi-server:** Will multiple rip servers need a unified dashboard? **Out of scope for v1**

---

## 8. Success Criteria

1. Operator can view all drive statuses on a single page
2. Progress updates visible within 5 seconds of change
3. Crashed drives detected within 5 minutes and flagged
4. Error logs accessible without SSH
5. Mobile-friendly interface
6. Deployment requires < 5 minutes from fresh system
7. Drive crash history persists and shows meaningful health indicators
8. Partial rip failures clearly distinguished from full success/failure

---

## 9. Out of Scope (v1)

- Remote disc ejection control
- ~~Automatic bus reset~~ (Now IN scope)
- Integration with media servers (Plex, Jellyfin)
- Disc metadata editing
- Batch scheduling
- Multi-server aggregation
- Email/Slack notifications (defer to v2)
- Docker deployment option (defer to v2)

---

## 10. Blog Post Outline

**Title:** "Building a Web Dashboard for Automated Disc Ripping: Monitoring, Progress Tracking, and Self-Healing Drives"

### Part 1: The Problem
- Intro to bash-autorip project
- Multi-drive setup challenges
- The firmware crash problem (drives lock up, require bus reset)
- Why we need visibility

### Part 2: Requirements & Design
- User stories and functional requirements
- Technology choices (Node.js, systemd, vanilla JS)
- Architecture diagram and data flow
- Status file format design

### Part 3: Implementation - Backend
- Setting up the Node.js project
- Modifying autorip.sh for status reporting
- Building the REST API
- WebSocket real-time updates
- Bus topology discovery from /sys
- Crash detection with heartbeat monitoring
- Drive health statistics and crash counting
- Parsing MakeMKV output for partial title failures

### Part 4: Implementation - Frontend
- Vanilla HTML/CSS dashboard layout
- WebSocket client for live updates
- Drive status cards with progress bars
- Log viewer component
- Bus reset panel with warnings

### Part 5: Bus Reset Magic
- Understanding Linux bus reset mechanisms
- Discovering drive-to-bus mapping
- Implementing safe auto-reset logic
- Manual reset with confirmation UI

### Part 6: Deployment & Testing
- Systemd service configuration
- Testing with multiple drives
- Simulating firmware crashes
- Verifying auto-recovery

### Part 7: Conclusion
- What we built
- Future enhancements (notifications, Docker, multi-server)
- Links to source code

---

## Next Steps

1. ~~Review and finalize requirements~~ (This document)
2. ~~Select technology stack~~ (Node.js, vanilla JS, systemd)
3. **Save PRD to project** - Write this document as `/home/jstormes/code/bash-autorip/PRD.md`
4. Design API specification (JSON schemas)
5. Define status file format
6. Begin implementation
   - Phase 1: Modify autorip.sh for status reporting
   - Phase 2: Build Node.js backend
   - Phase 3: Build frontend dashboard
   - Phase 4: Implement bus reset logic
   - Phase 5: Testing and documentation
