# Auto-Rip Installation

Automatic disc ripping for **Video Discs** (DVD/Blu-ray) and **Audio CDs** using udev rules.

## Features

- **Video Discs**: Rips DVD and Blu-ray using MakeMKV
- **Audio CDs**: Rips to FLAC/MP3 with automatic metadata lookup from MusicBrainz
- Automatic disc type detection
- Duplicate tracking (won't re-rip same disc)
- Auto-eject on success
- Error tracking with retry instructions
- Multiple drive support (parallel ripping)

## Prerequisites

### For Video Discs (DVD/Blu-ray)

1. **MakeMKV installed** with `makemkvcon` in PATH
   ```bash
   which makemkvcon  # Should return path
   ```

2. **MakeMKV license configured for root**
   ```bash
   sudo mkdir -p /root/.MakeMKV
   sudo cp ~/.MakeMKV/* /root/.MakeMKV/
   ```

### For Audio CDs

```bash
sudo apt install abcde cdparanoia cd-discid flac
# Optional for MP3 output:
sudo apt install lame
```

### Common Requirements

**Output directory** with write permissions:
```bash
sudo mkdir -p /ripped_discs
sudo chmod 777 /ripped_discs
```

## Installation

```bash
# 1. Copy the script
sudo cp autorip.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/autorip.sh

# 2. Install the udev rule
sudo cp 99-autorip.rules /etc/udev/rules.d/

# 3. Reload udev rules
sudo udevadm control --reload-rules

# 4. Verify installation
ls -la /usr/local/bin/autorip.sh
ls -la /etc/udev/rules.d/99-autorip.rules
```

## Configuration

Environment variables for customization:

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTORIP_OUTPUT` | `/ripped_discs` | Base output directory |
| `AUTORIP_VIDEO_OUTPUT` | `/ripped_discs/video` | Video disc output |
| `AUTORIP_AUDIO_OUTPUT` | `/ripped_discs/audio` | Audio CD output |
| `AUTORIP_AUDIO_FORMAT` | `flac` | Audio format (flac, mp3, ogg) |
| `AUTORIP_USER` | *(empty)* | Run rip process as this user |
| `AUTORIP_GROUP` | *(empty)* | Run rip process as this group |

### Running as a Specific User (NFS Support)

By default, the script runs as root. If your output directory is on an NFS mount with `root_squash` enabled (the default), root will be mapped to `nobody` and won't have write permissions.

To run as a specific user, edit `/usr/local/bin/autorip.sh` and set:

```bash
AUTORIP_USER="${AUTORIP_USER:-yourusername}"
AUTORIP_GROUP="${AUTORIP_GROUP:-yourusername}"
```

Or hardcode the values:
```bash
AUTORIP_USER="jstormes"
AUTORIP_GROUP="jstormes"
```

**Requirements when running as a non-root user:**
- User must be in the `cdrom` group for drive access: `sudo usermod -aG cdrom yourusername`
- MakeMKV license must be in the user's home: `~/.MakeMKV/settings.conf`
- User needs write permission to the output directory

## Testing

### Manual Test
```bash
# Clear any previous logs
sudo rm -f /tmp/autorip-sr0.log /tmp/autorip-sr0.lock

# Run manually with a disc inserted
sudo AUTORIP_DETACHED=1 /usr/local/bin/autorip.sh sr0
```

### Automatic Test (via udev)
1. Insert a disc - ripping should start automatically

2. Monitor the logs:
   ```bash
   tail -f /tmp/autorip-sr0.log
   ```

3. Check output directory:
   ```bash
   ls -la /ripped_discs/video/  # For DVDs/Blu-rays
   ls -la /ripped_discs/audio/  # For Audio CDs
   ```

## How It Works

1. **udev detects disc insertion** → triggers `autorip.sh sr0`
2. **Script spawns systemd service** (escapes udev restrictions)
3. **Detects disc type** (audio CD vs video disc)
4. **Routes to appropriate ripper**:
   - Audio CD → `abcde` with MusicBrainz lookup
   - Video disc → `makemkvcon`
5. **Checks duplicate tracking** file
6. **Rips content**
7. **Writes success.txt or error.txt**
8. **Ejects disc on success** (keeps disc on failure)

## Output Structure

```
/ripped_discs/
├── .ripped_discs                    # Duplicate tracking
├── audio/
│   ├── Artist_Name/
│   │   └── Album_Name/
│   │       ├── 01 - Track One.flac
│   │       ├── 02 - Track Two.flac
│   │       └── success.txt
│   └── _errors/                     # Failed audio rips
│       └── 20241225_123456/
│           ├── error.txt
│           └── rip_output.txt
└── video/
    ├── a1b2c3d4-Movie_Name/
    │   ├── disc_info_raw.txt
    │   ├── disc_info.json
    │   ├── title_t00.mkv
    │   └── success.txt
    └── b5c6d7e8-Failed_Disc/
        ├── disc_info_raw.txt
        └── error.txt
```

## Troubleshooting

### Disc type not detected correctly
```bash
# Test audio CD detection
cd-discid /dev/sr0

# Test video disc detection
blkid /dev/sr0
makemkvcon -r info disc:9999
```

### Audio CD: No metadata found
- Check internet connection
- MusicBrainz may not have the disc in database
- Tracks will be named "Track 01", "Track 02", etc.

### Audio CD: abcde not working
```bash
# Test manually
abcde -d /dev/sr0 -o flac -N
```

### Script dies during rip
Check systemd journal:
```bash
journalctl -xe | grep -E "autorip|abcde|makemkv"
```

### MakeMKV license issues
```bash
sudo makemkvcon -r info disc:9999
# If fails, copy license:
sudo cp ~/.MakeMKV/* /root/.MakeMKV/
```

## Uninstall

```bash
sudo rm /usr/local/bin/autorip.sh
sudo rm /etc/udev/rules.d/99-autorip.rules
sudo udevadm control --reload-rules
```

## Multiple Drives

The system supports multiple optical drives automatically:
- Each drive gets its own lock file and log file
- Rips can run in parallel on different drives
- udev triggers with specific device name (sr0, sr1, etc.)

## Clearing Duplicate Tracking

To re-rip a disc:
```bash
# Edit tracking file
nano /ripped_discs/.ripped_discs

# Or clear all tracking
rm /ripped_discs/.ripped_discs
```

## Changing Audio Format

Default is FLAC (lossless). For MP3:
```bash
# Edit the script or set environment variable
export AUTORIP_AUDIO_FORMAT=mp3
```

Or edit `/usr/local/bin/autorip.sh` line 27:
```bash
AUDIO_FORMAT="${AUTORIP_AUDIO_FORMAT:-mp3}"
```

## Monitoring Active Rips

```bash
# Check running services
systemctl list-units --type=service | grep autorip

# Watch log
tail -f /tmp/autorip-sr0.log

# Check journal
journalctl -f -t autorip
```
