# bash-autorip

A simple bash script for automatic disc ripping triggered by udev.

- **DVDs/Blu-rays** - Ripped via [MakeMKV](https://www.makemkv.com/)
- **Audio CDs** - Ripped via [abcde](https://abcde.einval.com/) with MusicBrainz metadata lookup

## How It Works

Insert a disc, walk away. The script automatically:

1. Detects disc type (video vs audio)
2. Rips content to `/ripped_discs/`
3. Looks up metadata (MusicBrainz for audio CDs)
4. Tracks duplicates (won't re-rip same disc)
5. Ejects disc on success

## Quick Start

```bash
# Install MakeMKV for Linux (required for DVD/Blu-ray)
# Follow instructions at: https://forum.makemkv.com/forum/viewtopic.php?f=3&t=224

# Install audio CD dependencies
sudo apt install abcde cdparanoia cd-discid flac

# Create output directory
sudo mkdir -p /ripped_discs && sudo chmod 777 /ripped_discs

# Install
sudo cp autorip.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/autorip.sh
sudo cp 99-autorip.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules

# Copy MakeMKV license for root user
sudo mkdir -p /root/.MakeMKV
sudo cp ~/.MakeMKV/* /root/.MakeMKV/
```

## Output

```
/ripped_discs/
├── video/
│   └── a1b2c3d4-Movie_Name/
│       ├── title_t00.mkv
│       └── success.txt
└── audio/
    └── Artist_Name/
        └── Album_Name_discid/
            ├── 01 - Track One.flac
            └── success.txt
```

## Monitoring

```bash
# Watch rip progress
tail -f /tmp/autorip-sr0.log

# Check running rips
systemctl list-units --type=service | grep autorip
```

## Files

| File | Purpose |
|------|---------|
| `autorip.sh` | Main ripping script |
| `99-autorip.rules` | udev rule to trigger on disc insert |
| `INSTALL.md` | Detailed installation and troubleshooting guide |

## Requirements

- Linux with udev and systemd
- [MakeMKV](https://forum.makemkv.com/forum/viewtopic.php?f=3&t=224) (for video discs)
- abcde, cdparanoia, cd-discid, flac (for audio CDs)
- Optional: lame (for MP3 output)

See [INSTALL.md](INSTALL.md) for detailed setup and troubleshooting.
