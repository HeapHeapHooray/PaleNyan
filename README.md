# PaleNyan

A PaperMC server automator that builds a fresh, locked-down read-only Minecraft server instance on every run. Designed for museum/virtual-tour servers where the world must remain completely frozen.

## How it works

1. **`setup_and_run.sh`** — the only file that matters
2. Wipes `./server-instance/` and rebuilds it from scratch (unless run-only mode is used)
3. Copies worlds from `./worlds/` and a server icon from `./server-icon.png`
4. Downloads PaperMC + plugins (versions pinned in `version_control.json`)
5. Generates all config files — WorldGuard, LuckPerms, Multiverse-Core, MuseumWorld, StartupCommands, Geyser-Spigot
6. Starts the server with Aikar's flags

## Command-Line Options

You can customize the execution of the script using the following command-line flags:

- `--run-only` (aliases: `--run`, `-r`, `--no-setup`):
  Skips the entire setup phase (does not wipe `./server-instance`, copy worlds, or download files) and immediately runs the existing Paper server.
- `--setup-only` (aliases: `--no-run`, `-s`):
  Runs the full setup phase (wipes the directory, copies worlds, downloads components, generates configs), but exits without starting the server.
- `--max-tick-time <value>` (e.g., `--max-tick-time 60000` or `--max-tick-time=-1`):
  Patches the `max-tick-time` property in `server.properties` with the provided value right before starting the server. This works with or without `--run-only`.

## Version pinning

`version_control.json` records the exact version of PaperMC and every plugin. Keep a backup of this file to roll back to a known-good state if an update breaks something. Edit it to pin specific versions:

```json
{"source": "modrinth", "project": "luckperms", "name": "LuckPerms-Bukkit", "version": "5.4.130"}
```

If the file doesn't exist, the script downloads the latest versions and generates it automatically.

## Configuration File (`config.json`)

You can configure memory allocations and maximum draw distance by editing the `config.json` file in the root directory. If this file does not exist, it will be automatically created with default values:

```json
{
  "minimum_ram": "2G",
  "maximum_ram": "4G",
  "maximum_draw_distance": 10
}
```

- **`minimum_ram`**: Sets the minimum JVM memory allocation (maps to `-Xms`).
- **`maximum_ram`**: Sets the maximum JVM memory allocation (maps to `-Xmx`).
- **`maximum_draw_distance`**: Sets the default view distance and simulation distance within `server.properties`.

## Configuration

All server behavior is configured through the script — no manual editing of server files needed:

- **Read-only worlds** — WorldGuard denies redstone, pistons, explosions, mob spawning, ice/snow melt, leaf decay, crop growth, fire spread, fluid flow, and more
- **No nether/end** — `allow-nether=false`, `allow-end=false`, Paper's `enable-nether=false`
- **Gamerules** — `randomTickSpeed 0`, `doMobSpawning false`, `doDaylightCycle false`, `doWeatherCycle false`, `showDeathMessages false` (applied to standard dimensions)
- **MuseumWorld** — Blocks item drop/pickup, bucket use, fire use, bone meal, portal creation, TNT, projectile use, bed use; locked containers are view-only
- **Entity blocking** — All mob types blocked from spawning
- **Multiverse** — Worlds auto-imported on boot, gamemode forced to creative
- **Autosave disabled** — `save-off` after startup, `ticks-per.autosave: 0`
- **Spawn** — `/spawn` aliased to `/mvtp <main-world>`
- **Bedrock Edition Cross-Play** — Integrates GeyserMC and Floodgate to allow Minecraft Bedrock players to join on UDP port `19132` without requiring a paid Java Edition account.

## Directory structure

```
./
├── setup_and_run.sh         # the script
├── config.json              # server RAM and draw distance configs (editable)
├── version_control.json     # pinned versions (auto-generated, editable)
├── server-icon.png          # optional, copied into instance
├── worlds/                  # world directories with level.dat
│   ├── world/
│   ├── world_nether/
│   └── ...
└── server-instance/         # created and wiped each run (preserved in run-only mode)
```

## Requirements

- `bash`, `curl`, `wget`, `jq`, `java 21+`
- Internet access for downloading PaperMC and plugins
