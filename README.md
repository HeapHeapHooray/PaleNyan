# PaleNyan

A PaperMC server automator that builds a fresh, locked-down read-only Minecraft server instance on every run. Designed for museum/virtual-tour servers where the world must remain completely frozen.

## How it works

1. **`setup_and_run.sh`** — the only file that matters
2. Wipes `./server-instance/` and rebuilds it from scratch
3. Copies worlds from `./worlds/` and a server icon from `./server-icon.png`
4. Downloads PaperMC + plugins (versions pinned in `version_control.json`)
5. Generates all config files — WorldGuard, LuckPerms, Multiverse-Core, MuseumWorld, StartupCommands
6. Starts the server with Aikar's flags

## Usage

Run the script to automatically build and start the server:

```bash
./setup_and_run.sh
```

### Custom IP and Port Binding

You can specify a custom IP address and port for the server to listen on:

**Command-line arguments:**
```bash
./setup_and_run.sh --ip 127.0.0.1 --port 25569
# Or short flags
./setup_and_run.sh -i 127.0.0.1 -p 25569
```

**Environment variables:**
```bash
SERVER_IP=127.0.0.1 SERVER_PORT=25569 ./setup_and_run.sh
```

## Version pinning

`version_control.json` records the exact version of PaperMC and every plugin. Keep a backup of this file to roll back to a known-good state if an update breaks something. Edit it to pin specific versions:

```json
{"source": "modrinth", "project": "luckperms", "name": "LuckPerms-Bukkit", "version": "5.4.130"}
```

If the file doesn't exist, the script downloads the latest versions and generates it automatically.

## Configuration

All server behavior is configured through the script — no manual editing of server files needed:

- **Read-only worlds** — WorldGuard denies redstone, pistons, explosions, mob spawning, ice/snow melt, leaf decay, crop growth, fire spread, fluid flow, and more
- **No item drops/pickups** — WorldGuard denies item drop and item pickup globally across all dimensions
- **No nether/end** — `allow-nether=false`, `allow-end=false`, Paper's `enable-nether=false`
- **Gamerules** — `randomTickSpeed 0`, `doMobSpawning false`, `doDaylightCycle false`, `doWeatherCycle false`, `showDeathMessages false` (applied to standard dimensions)
- **MuseumWorld** — Blocks item drop/pickup, bucket use, fire use, bone meal, portal creation, TNT, projectile use, bed use; locked containers are view-only
- **Entity blocking** — All mob types blocked from spawning
- **Multiverse** — Worlds auto-imported on boot, gamemode forced to creative
- **Autosave disabled** — `save-off` after startup, `ticks-per.autosave: 0`
- **Spawn** — `/spawn` aliased to `/mvtp <main-world>`

## Directory structure

```
./
├── setup_and_run.sh         # the script
├── version_control.json     # pinned versions (auto-generated, editable)
├── server-icon.png          # optional, copied into instance
├── worlds/                  # world directories with level.dat
│   ├── world/
│   ├── world_nether/
│   └── ...
└── server-instance/         # created and wiped each run
```

## Requirements

- `bash`, `curl`, `wget`, `jq`, `java 21+`
- Internet access for downloading PaperMC and plugins
