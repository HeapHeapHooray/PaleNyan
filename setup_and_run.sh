#!/bin/bash
# ==============================================================================
# setup_and_run.sh - Paper Locked-Down Server Automator (StartupCommands)
# ==============================================================================
# This script automatically creates all configuration files, directory structures,
# and plugin settings to make your Paper server 100% read-only, tick-frozen,
# and redstone/physics disabled.
#
# Startup commands (gamerules, gamemode, etc.) are run via the StartupCommands
# plugin after the server is fully booted.
# ==============================================================================

# Exit immediately if a command exits with a non-zero status
set -e

# ------------------------------------------------------------------------------
# 0. Load User Configuration (config.json)
# ------------------------------------------------------------------------------
CONFIG_FILE="config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating default $CONFIG_FILE..."
    cat << 'EOF' > "$CONFIG_FILE"
{
  "minimum_ram": "2G",
  "maximum_ram": "4G",
  "maximum_draw_distance": 10
}
EOF
fi

echo "Reading user configuration from $CONFIG_FILE..."
MIN_RAM=$(jq -r '.minimum_ram // "2G"' "$CONFIG_FILE")
MAX_RAM=$(jq -r '.maximum_ram // "4G"' "$CONFIG_FILE")
MAX_DRAW_DISTANCE=$(jq -r '.maximum_draw_distance // 10' "$CONFIG_FILE")

echo "Configured RAM: $MIN_RAM (Min) / $MAX_RAM (Max)"
echo "Configured Maximum Draw Distance: $MAX_DRAW_DISTANCE"

# Server Root Directory
SERVER_DIR="./server-instance"
rm -rf "$SERVER_DIR"
mkdir -p "$SERVER_DIR"



# Copy server icon if present
if [ -f "server-icon.png" ]; then
    cp "server-icon.png" "$SERVER_DIR/server-icon.png"
    echo "Copied server icon."
fi

echo "=========================================================="
echo " Copying worlds to server instance...                     "
echo "=========================================================="

# Copy world directories (with level.dat) from ./worlds to server instance
WORLDS_SRC="./worlds"
if [ -d "$WORLDS_SRC" ]; then
    for dir in "$WORLDS_SRC"/*/; do
        if [ -f "${dir}level.dat" ]; then
            world_name=$(basename "$dir")
            echo "Copying world: $world_name"
            cp -r "$dir" "$SERVER_DIR/$world_name"
        fi
    done
else
    echo "No ./worlds directory found."
fi

echo "=========================================================="
echo " Checking for PaperMC & Plugins...                        "
echo "=========================================================="

# ------------------------------------------------------------------------------
# 0. Component Downloader — driven by version_control.json if available
# ------------------------------------------------------------------------------
PLUGIN_MANIFEST="version_control.json"

# Ensure plugins directory exists before any downloads
mkdir -p "$SERVER_DIR/plugins"

# Functions to download from Modrinth / GitHub
download_modrinth() {
    local project_id=$1
    local name=$2
    local version=${3:-latest}
    local api_data=$(curl -s "https://api.modrinth.com/v2/project/$project_id/version")
    if [ "$version" = "latest" ]; then
        local entry=$(echo "$api_data" | jq '[.[] | select(.loaders | index("bukkit") or index("paper"))][0]')
    else
        local entry=$(echo "$api_data" | jq --arg v "$version" '[.[] | select(.version_number == $v and (.loaders | index("bukkit") or index("paper")))][0]')
        # Fall back to latest Bukkit version if pinned version not found
        if [ "$entry" = "null" ] || [ -z "$entry" ]; then
            echo "Version $version not found for Bukkit/Paper, falling back to latest..."
            local entry=$(echo "$api_data" | jq '[.[] | select(.loaders | index("bukkit") or index("paper"))][0]')
        fi
    fi
    local filename=$(echo "$entry" | jq -r '.files[0].filename // ""')
    local url=$(echo "$entry" | jq -r '.files[0].url // ""')
    if [ -f "$SERVER_DIR/plugins/$filename" ]; then
        echo "$name is already installed ($filename)."
    elif [ -n "$url" ] && [ "$url" != "null" ] && [ "$url" != "" ] && [ -n "$filename" ]; then
        echo "Downloading $name ($filename)..."
        wget -q -O "$SERVER_DIR/plugins/$filename" "$url"
        echo "Downloaded $name."
    else
        echo "Failed to fetch Modrinth URL for $name"
    fi
}

download_github() {
    local repo=$1
    local name=$2
    local version=${3:-latest}
    if [ "$version" = "latest" ]; then
        local filename=$(curl -s "https://api.github.com/repos/$repo/releases/latest" | jq -r '.assets[] | select(.name | endswith(".jar")) | .name' | head -1)
        local url=$(curl -s "https://api.github.com/repos/$repo/releases/latest" | grep "browser_download_url" | grep "\.jar" | head -n 1 | cut -d '"' -f 4)
    else
        local filename=$(curl -s "https://api.github.com/repos/$repo/releases/tags/$version" | jq -r '.assets[] | select(.name | endswith(".jar")) | .name' | head -1)
        local url=$(curl -s "https://api.github.com/repos/$repo/releases/tags/$version" | grep "browser_download_url" | grep "\.jar" | head -n 1 | cut -d '"' -f 4)
    fi
    if [ -f "$SERVER_DIR/plugins/$filename" ]; then
        echo "$name is already installed ($filename)."
    elif [ -n "$url" ] && [ -n "$filename" ] && [ "$filename" != "null" ]; then
        echo "Downloading $name ($filename)..."
        wget -q -O "$SERVER_DIR/plugins/$filename" "$url"
        echo "Downloaded $name."
    else
        echo "Failed to fetch Github Release URL for $name"
    fi
}

download_geysermc() {
    local project_id=$1
    local name=$2
    local version=${3:-latest}

    # Fetch project versions
    local proj_data=$(curl -s "https://download.geysermc.org/v2/projects/$project_id")
    if [ "$version" = "latest" ] || [ -z "$version" ] || [ "$version" = "null" ]; then
        version=$(echo "$proj_data" | jq -r '.versions[-1] // ""')
    fi

    # Fetch builds for version
    local ver_data=$(curl -s "https://download.geysermc.org/v2/projects/$project_id/versions/$version")
    local latest_build=$(echo "$ver_data" | jq '.builds[-1]')

    # Fetch download info
    local build_data=$(curl -s "https://download.geysermc.org/v2/projects/$project_id/versions/$version/builds/$latest_build")
    local filename=$(echo "$build_data" | jq -r '.downloads.spigot.name // ""')

    if [ -f "$SERVER_DIR/plugins/$filename" ]; then
        echo "$name is already installed ($filename)."
    elif [ -n "$filename" ] && [ "$filename" != "null" ]; then
        echo "Downloading $name ($filename) from GeyserMC API..."
        wget -q -O "$SERVER_DIR/plugins/$filename" "https://download.geysermc.org/v2/projects/$project_id/versions/$version/builds/$latest_build/downloads/spigot"
        echo "Downloaded $name."
    else
        echo "Failed to fetch GeyserMC download info for $name"
    fi
}

# Determine PaperMC version/build from manifest or latest
fetch_papermc_info() {
    local ver_override=$1
    local build_override=$2
    if [ -n "$ver_override" ] && [ "$ver_override" != "null" ]; then
        LATEST_VERSION="$ver_override"
        if [ -n "$build_override" ] && [ "$build_override" != "null" ]; then
            LATEST_BUILD="$build_override"
        else
            LATEST_BUILD=$(curl -s "https://api.papermc.io/v2/projects/paper/versions/${LATEST_VERSION}" | jq -r '.builds[-1]')
        fi
    else
        echo "Fetching latest PaperMC version information..."
        LATEST_VERSION=$(curl -s https://api.papermc.io/v2/projects/paper | jq -r '.versions[-1]')
        LATEST_BUILD=$(curl -s "https://api.papermc.io/v2/projects/paper/versions/${LATEST_VERSION}" | jq -r '.builds[-1]')
    fi
    JAR_NAME="paper-${LATEST_VERSION}-${LATEST_BUILD}.jar"
}

download_papermc() {
    if [ ! -f "$SERVER_DIR/$JAR_NAME" ]; then
        echo "Downloading PaperMC $LATEST_VERSION (build $LATEST_BUILD)..."
        rm -f "$SERVER_DIR"/paper-*.jar
        wget -q -O "$SERVER_DIR/$JAR_NAME" "https://api.papermc.io/v2/projects/paper/versions/${LATEST_VERSION}/builds/${LATEST_BUILD}/downloads/${JAR_NAME}"
        echo "PaperMC $JAR_NAME downloaded."
    else
        echo "PaperMC $JAR_NAME is already up to date."
    fi
}

# Read manifest if available
if [ -f "$PLUGIN_MANIFEST" ]; then
    echo "Found $PLUGIN_MANIFEST — downloading from manifest..."
    PAPER_VER=$(jq -r '.[] | select(.source == "papermc") | .version // ""' "$PLUGIN_MANIFEST")
    PAPER_BUILD=$(jq -r '.[] | select(.source == "papermc") | .build // ""' "$PLUGIN_MANIFEST")
    fetch_papermc_info "$PAPER_VER" "$PAPER_BUILD"
    download_papermc

    length=$(jq 'length' "$PLUGIN_MANIFEST")
    for i in $(seq 0 $((length - 1))); do
        source=$(jq -r ".[$i].source" "$PLUGIN_MANIFEST")
        [ "$source" = "papermc" ] && continue
        name=$(jq -r ".[$i].name" "$PLUGIN_MANIFEST")
        version=$(jq -r ".[$i].version // \"latest\"" "$PLUGIN_MANIFEST")
        if [ "$source" = "modrinth" ]; then
            project=$(jq -r ".[$i].project" "$PLUGIN_MANIFEST")
            download_modrinth "$project" "$name" "$version"
        elif [ "$source" = "github" ]; then
            repo=$(jq -r ".[$i].repo" "$PLUGIN_MANIFEST")
            download_github "$repo" "$name" "$version"
        elif [ "$source" = "geysermc" ]; then
            project=$(jq -r ".[$i].project" "$PLUGIN_MANIFEST")
            download_geysermc "$project" "$name" "$version"
        else
            echo "Unknown source '$source' for $name, skipping."
        fi
    done

    # Ensure PaperMC entry exists in manifest
    if [ -z "$PAPER_VER" ] || [ "$PAPER_VER" = "null" ]; then
        jq --arg v "$LATEST_VERSION" --arg b "$LATEST_BUILD" \
          '. += [{"source":"papermc","name":"PaperMC","version":$v,"build":$b}]' \
          "$PLUGIN_MANIFEST" > tmp.json && mv tmp.json "$PLUGIN_MANIFEST"
        echo "Added PaperMC $LATEST_VERSION (build $LATEST_BUILD) to $PLUGIN_MANIFEST."
    fi
else
    echo "No $PLUGIN_MANIFEST found — downloading latest and generating manifest with pinned versions."
    fetch_papermc_info "" ""
    download_papermc

    download_modrinth "luckperms" "LuckPerms-Bukkit"
    download_modrinth "worldedit" "worldedit-bukkit"
    download_modrinth "worldguard" "worldguard-bukkit"
    download_modrinth "multiverse-core" "multiverse-core"
    download_github "Tantrum90/MuseumWorld" "MuseumWorld"
    download_github "mattgd/StartupCommands" "StartupCommands"
    download_modrinth "P1OZGk5p" "ViaVersion"
    download_geysermc "geyser" "Geyser-Spigot"
    download_geysermc "floodgate" "Floodgate"

    LP_VER=$(curl -s "https://api.modrinth.com/v2/project/luckperms/version" | jq -r '[.[] | select(.loaders | index("bukkit") or index("paper"))][0].version_number')
    WE_VER=$(curl -s "https://api.modrinth.com/v2/project/worldedit/version" | jq -r '[.[] | select(.loaders | index("bukkit") or index("paper"))][0].version_number')
    WG_VER=$(curl -s "https://api.modrinth.com/v2/project/worldguard/version" | jq -r '[.[] | select(.loaders | index("bukkit") or index("paper"))][0].version_number')
    MV_VER=$(curl -s "https://api.modrinth.com/v2/project/multiverse-core/version" | jq -r '[.[] | select(.loaders | index("bukkit") or index("paper"))][0].version_number')
    MW_VER=$(curl -s "https://api.github.com/repos/Tantrum90/MuseumWorld/releases/latest" | jq -r '.tag_name')
    SC_VER=$(curl -s "https://api.github.com/repos/mattgd/StartupCommands/releases/latest" | jq -r '.tag_name')
    VV_VER=$(curl -s "https://api.modrinth.com/v2/project/P1OZGk5p/version" | jq -r '[.[] | select(.loaders | index("paper"))][0].version_number')
    GEYSER_VER=$(curl -s "https://download.geysermc.org/v2/projects/geyser" | jq -r '.versions[-1]')
    FLOODGATE_VER=$(curl -s "https://download.geysermc.org/v2/projects/floodgate" | jq -r '.versions[-1]')

    cat << EOF > "$PLUGIN_MANIFEST"
[
  {"source": "papermc", "name": "PaperMC", "version": "$LATEST_VERSION", "build": "$LATEST_BUILD"},
  {"source": "modrinth", "project": "luckperms", "name": "LuckPerms-Bukkit", "version": "$LP_VER"},
  {"source": "modrinth", "project": "worldedit", "name": "worldedit-bukkit", "version": "$WE_VER"},
  {"source": "modrinth", "project": "worldguard", "name": "worldguard-bukkit", "version": "$WG_VER"},
  {"source": "modrinth", "project": "multiverse-core", "name": "multiverse-core", "version": "$MV_VER"},
  {"source": "github", "repo": "Tantrum90/MuseumWorld", "name": "MuseumWorld", "version": "$MW_VER"},
  {"source": "github", "repo": "mattgd/StartupCommands", "name": "StartupCommands", "version": "$SC_VER"},
  {"source": "modrinth", "project": "P1OZGk5p", "name": "ViaVersion", "version": "$VV_VER"},
  {"source": "geysermc", "project": "geyser", "name": "Geyser-Spigot", "version": "$GEYSER_VER"},
  {"source": "geysermc", "project": "floodgate", "name": "Floodgate", "version": "$FLOODGATE_VER"}
]
EOF
    echo "$PLUGIN_MANIFEST generated with pinned versions."
fi

# Ensure plugin subdirectories exist
mkdir -p "$SERVER_DIR/plugins/LuckPerms/yaml-storage/groups"
mkdir -p "$SERVER_DIR/plugins/WorldGuard/worlds/world"
mkdir -p "$SERVER_DIR/plugins/WorldGuard/worlds/world_nether"
mkdir -p "$SERVER_DIR/plugins/WorldGuard/worlds/world_the_end"

# ------------------------------------------------------------------------------
# 0.7 World Detection
# ------------------------------------------------------------------------------
echo "Detecting existing worlds..."
DETECTED_WORLDS=()
# Loop through directories to find those with level.dat
for dir in "$SERVER_DIR"/*/; do
    if [ -f "${dir}level.dat" ]; then
        world_name=$(basename "$dir")
        DETECTED_WORLDS+=("$world_name")
        echo "Found world: $world_name"
    fi
done

# If no worlds found, default to standard worlds (server will generate them on first start)
if [ ${#DETECTED_WORLDS[@]} -eq 0 ]; then
    DETECTED_WORLDS=("world" "world_nether" "world_the_end")
    echo "No worlds found — will use default worlds (world, world_nether, world_the_end)."
fi

# ------------------------------------------------------------------------------
# 1. Standard Minecraft Configs
# ------------------------------------------------------------------------------

# eula.txt
echo "Accepting EULA..."
cat << 'EOF' > "$SERVER_DIR/eula.txt"
#By changing the setting below to TRUE you are indicating your agreement to our EULA (https://aka.ms/mcseula).
eula=true
EOF

# server.properties (use first non-nether/non-end world as level-name)
MAIN_WORLD="world"
for w in "${DETECTED_WORLDS[@]}"; do
    if [[ "$w" != *"nether"* && "$w" != *"end"* ]]; then
        MAIN_WORLD="$w"
        break
    fi
done
echo "Seeding server.properties (level-name=$MAIN_WORLD)..."
cat << EOF > "$SERVER_DIR/server.properties"
# Minecraft server properties
level-name=$MAIN_WORLD
spawn-protection=0
allow-flight=true
sync-chunk-writes=false
gamemode=creative
force-gamemode=true
difficulty=easy
pvp=true
motd=PaleNyan, Read-Only Frozen Paper Server
enable-command-block=false
allow-nether=false
allow-end=false
spawn-animals=false
spawn-monsters=false
spawn-npcs=false
enforce-secure-profile=false
view-distance=$MAX_DRAW_DISTANCE
simulation-distance=$MAX_DRAW_DISTANCE
EOF

# commands.yml (/spawn → /mvtp to main world)
cat << EOF > "$SERVER_DIR/commands.yml"
command-block-overrides: []
ignore-vanilla-permissions: false
aliases:
  spawn:
  - mvtp $MAIN_WORLD
  tp:
  - minecraft:teleport @s \$1-
  teleport:
  - minecraft:teleport @s \$1-
  minecraft:tp:
  - minecraft:teleport @s \$1-
  minecraft:teleport:
  - minecraft:teleport @s \$1-
EOF

# bukkit.yml (Disable global autosave)
echo "Seeding bukkit.yml..."
cat << 'EOF' > "$SERVER_DIR/bukkit.yml"
# Bukkit server configuration
settings:
  allow-end: false
  warn-on-overload: true
  permissions-file: permissions.yml
  update-folder: update
  plugin-profiling: false
  connection-throttle: 4000
  query-plugins: true
  deprecated-verbose: default
  shutdown-message: Server closed
  minimum-api: none
ticks-per:
  animal-spawns: 400
  monster-spawns: 1
  water-spawns: 1
  water-ambient-spawns: 1
  water-underground-creature-spawns: 1
  axolotl-spawns: 1
  ambient-spawns: 15
  autosave: 0
chunk-gc:
  period-in-ticks: 300
  load-threshold: 0
EOF

# ------------------------------------------------------------------------------
# 2. LuckPerms Configs (YAML Storage & Command Permissions)
# ------------------------------------------------------------------------------

echo "Seeding LuckPerms configurations..."
# config.yml
cat << 'EOF' > "$SERVER_DIR/plugins/LuckPerms/config.yml"
# LuckPerms configuration
storage-method: yaml
EOF

# default.yml (Seeding permissions)
cat << 'EOF' > "$SERVER_DIR/plugins/LuckPerms/yaml-storage/groups/default.yml"
name: default
permissions:
  - 'worldedit.navigation.*':
      value: true
  - 'worldedit.selection.*':
      value: true
  - 'worldguard.region.info':
      value: true
  - 'worldguard.region.list':
      value: true
  - 'worldguard.region.select':
      value: true
  - 'multiverse.teleport.self':
      value: true
  - 'multiverse.teleport.self.*':
      value: true
  - 'multiverse.core.list.worlds':
      value: true
  - 'mv.bypass.gamemode.*':
      value: true
  - 'minecraft.command.teleport':
      value: true
  - 'bukkit.command.teleport':
      value: true
  - 'minecraft.command.gamemode':
      value: true
EOF

# ------------------------------------------------------------------------------
# 2.5 GeyserMC and Floodgate Configs (Bedrock Support)
# ------------------------------------------------------------------------------
echo "Seeding GeyserMC configuration..."
mkdir -p "$SERVER_DIR/plugins/Geyser-Spigot"
cat << 'EOF' > "$SERVER_DIR/plugins/Geyser-Spigot/config.yml"
# GeyserMC Configuration (Minimal/Auto-Merging)
bedrock:
  address: 0.0.0.0
  port: 19132
remote:
  address: auto
  auth-type: floodgate
EOF

# ------------------------------------------------------------------------------
# 3. WorldGuard Configs (High Frequency, Gravity, & Region Restrictions)
# ------------------------------------------------------------------------------

echo "Seeding WorldGuard configurations..."
# Global WorldGuard config.yml
cat << 'EOF' > "$SERVER_DIR/plugins/WorldGuard/config.yml"
# WorldGuard Configuration
high-frequency-flags: true
physics:
    no-physics-gravel: true
    no-physics-sand: true
ignition:
    block-tnt: true
    block-tnt-block-damage: true
EOF

# Define the complete region-level state lockdown
REGIONS_CONTENT=$(cat << 'EOF'
regions:
    __global__:
        type: global
        priority: 0
        flags:
            passthrough: deny
            build: deny             # Blocks ALL block edits, including WorldEdit
            use: allow              # Allowed so players can open doors/gates (MuseumWorld blocks levers/buttons)
            chest-access: allow     # Allowed so players can VIEW contents (Plugin will block EDITS)
            redstone: deny          # COMPLETELY disables all redstone activity/clocks/updates
            pistons: deny           # Completely disables pistons extending/retracting
            damage-animals: deny
            pvp: deny
            entity-item-frame-destroy: deny
            entity-painting-destroy: deny
            mob-spawning: deny      # Blocks all natural/structure/spawner spawning
            ice-melt: deny          # Blocks ice melting
            ice-form: deny          # Blocks ice forming
            snow-melt: deny         # Blocks snow melting
            snow-fall: deny         # Blocks snow accumulation
            leaf-decay: deny        # Blocks leaf decay
            grass-growth: deny      # Blocks grass spreading
            mycelium-spread: deny   # Blocks mycelium spreading
            vine-growth: deny       # Blocks vine growth
            crop-growth: deny       # Blocks crops growing
            fire-spread: deny       # Blocks fire spreading
            lava-fire: deny         # Blocks lava igniting fires
            water-flow: deny        # Blocks water flowing
            lava-flow: deny         # Blocks lava flowing
            lighter: deny           # Blocks flint and steel
            tnt: deny               # Blocks TNT explosions
            other-explosion: deny   # Blocks creeper / other explosions
            mob-griefing: deny      # Blocks endermen / other mob block changes
EOF
)

# Apply regions config to all detected worlds
for world in "${DETECTED_WORLDS[@]}"; do
    mkdir -p "$SERVER_DIR/plugins/WorldGuard/worlds/$world"
    echo "$REGIONS_CONTENT" > "$SERVER_DIR/plugins/WorldGuard/worlds/$world/regions.yml"
done

# ------------------------------------------------------------------------------
# 4. Multiverse-Core Configs (Dynamic per World)
# ------------------------------------------------------------------------------
echo "Seeding Multiverse-Core configuration..."
mkdir -p "$SERVER_DIR/plugins/Multiverse-Core"

# Build the worlds.yml content dynamically
WORLDS_YML_CONTENT="worlds:\n"
for world in "${DETECTED_WORLDS[@]}"; do
    env="NORMAL"
    # Basic environment detection based on name
    if [[ "$world" == *"nether"* ]]; then env="NETHER"; fi
    if [[ "$world" == *"end"* ]]; then env="THE_END"; fi
    
    WORLDS_YML_CONTENT="${WORLDS_YML_CONTENT}  $world:\n"
    WORLDS_YML_CONTENT="${WORLDS_YML_CONTENT}    alias: $world\n"
    WORLDS_YML_CONTENT="${WORLDS_YML_CONTENT}    environment: $env\n"
    WORLDS_YML_CONTENT="${WORLDS_YML_CONTENT}    gameMode: CREATIVE\n"
    WORLDS_YML_CONTENT="${WORLDS_YML_CONTENT}    difficulty: EASY\n"
    WORLDS_YML_CONTENT="${WORLDS_YML_CONTENT}    allowFlight: true\n"
    WORLDS_YML_CONTENT="${WORLDS_YML_CONTENT}    autoLoad: true\n"
    WORLDS_YML_CONTENT="${WORLDS_YML_CONTENT}    keepSpawnInMemory: false\n"
done

printf "$WORLDS_YML_CONTENT" > "$SERVER_DIR/plugins/Multiverse-Core/worlds.yml"

# Generate Multiverse-Core config.yml to force gamemodes
cat << 'EOF' > "$SERVER_DIR/plugins/Multiverse-Core/config.yml"
multiverse-configuration:
  ==: com.onarandombox.MultiverseCore.MultiverseCoreConfiguration
  enforceaccess: 'false'
  prefixchat: 'false'
  prefixchatformat: '[%world%]%chat%'
  useasyncchat: 'true'
  teleportintercept: 'true'
  firstspawnoverride: 'true'
  displaypermerrors: 'true'
  globaldebug: '0'
  silentstart: 'true'
  messagecooldown: '5000'
  version: '2.9'
  firstspawnworld: 'world'
  teleportcooldown: '1000'
  defaultportalsearch: 'false'
  portalsearchradius: '16'
EOF

# ------------------------------------------------------------------------------
# 5. MuseumWorld Configs (Dynamic per World)
# ------------------------------------------------------------------------------

echo "Seeding MuseumWorld configuration..."
mkdir -p "$SERVER_DIR/plugins/MuseumWorld"

# Build the locked-worlds list for YAML
LOCKED_WORLDS_YAML=""
for world in "${DETECTED_WORLDS[@]}"; do
    LOCKED_WORLDS_YAML="${LOCKED_WORLDS_YAML}  - $world\n"
done

cat << EOF > "$SERVER_DIR/plugins/MuseumWorld/config.yml"
locked-worlds:
$(printf "$LOCKED_WORLDS_YAML")
notify-player: false
language: en
debug-mode: false
startup-summary-enabled: false
messages:
  cooldown-ms: 2500
block-entity-damage: true
blocked-entity-types:
  - ALLAY
  - ARMADILLO
  - AXOLOTL
  - BAT
  - BEE
  - BLAZE
  - CAMEL
  - CAT
  - CAVE_SPIDER
  - CHICKEN
  - COD
  - COW
  - CREEPER
  - DOLPHIN
  - DONKEY
  - DROWNED
  - ELDER_GUARDIAN
  - ENDER_DRAGON
  - ENDERMAN
  - ENDERMITE
  - EVOKER
  - FOX
  - FROG
  - GHAST
  - GLOW_SQUID
  - GOAT
  - GUARDIAN
  - HOGLIN
  - HORSE
  - HUSK
  - ILLUSIONER
  - IRON_GOLEM
  - LLAMA
  - MAGMA_CUBE
  - MOOSHROOM
  - MULE
  - OCELOT
  - PANDA
  - PARROT
  - PHANTOM
  - PIG
  - PIGLIN
  - PIGLIN_BRUTE
  - PILLAGER
  - POLAR_BEAR
  - PUFFERFISH
  - RABBIT
  - RAVAGER
  - SALMON
  - SHEEP
  - SHULKER
  - SILVERFISH
  - SKELETON
  - SKELETON_HORSE
  - SLIME
  - SNIFFER
  - SNOW_GOLEM
  - SPIDER
  - SQUID
  - STRAY
  - STRIDER
  - TADPOLE
  - TRADER_LLAMA
  - TROPICAL_FISH
  - TURTLE
  - VEX
  - VILLAGER
  - VINDICATOR
  - WANDERING_TRADER
  - WARDEN
  - WITCH
  - WITHER
  - WITHER_SKELETON
  - WOLF
  - ZOGLIN
  - ZOMBIE
  - ZOMBIE_HORSE
  - ZOMBIE_VILLAGER
  - ZOMBIFIED_PIGLIN
block-item-drop: true
block-item-pickup: true
block-bucket-use: true
block-fire-use: true
block-natural-growth: true
block-bone-meal-use: true
block-portal-creation: true
block-item-frame-rotation: true
block-armor-stand-manipulation: true
block-tnt-ignite: true
block-player-bed-use: true
block-hanging-break: true
block-vehicle-place-break: true
block-vehicle-enter: false
block-projectile-use: true
allow-elytra-firework-boost: true
block-lead-use: true
block-name-tag-use: true
block-readonly-interactions: true
readonly-blocks:
  - CHEST
  - TRAPPED_CHEST
  - BARREL
  - ENDER_CHEST
  - HOPPER
  - DISPENSER
  - DROPPER
  - FURNACE
  - BLAST_FURNACE
  - SMOKER
  - BREWING_STAND
  - SHULKER_BOX
  - WHITE_SHULKER_BOX
  - ORANGE_SHULKER_BOX
  - MAGENTA_SHULKER_BOX
  - LIGHT_BLUE_SHULKER_BOX
  - YELLOW_SHULKER_BOX
  - LIME_SHULKER_BOX
  - PINK_SHULKER_BOX
  - GRAY_SHULKER_BOX
  - LIGHT_GRAY_SHULKER_BOX
  - CYAN_SHULKER_BOX
  - PURPLE_SHULKER_BOX
  - BLUE_SHULKER_BOX
  - BROWN_SHULKER_BOX
  - GREEN_SHULKER_BOX
  - RED_SHULKER_BOX
  - BLACK_SHULKER_BOX
  - LECTERN
  - CHISELED_BOOKSHELF
  - LEVER
  - REPEATER
  - COMPARATOR
  - DAYLIGHT_DETECTOR
  - TRIPWIRE_HOOK
  - TARGET
  - NOTE_BLOCK
  - JUKEBOX
  - OAK_BUTTON
  - SPRUCE_BUTTON
  - BIRCH_BUTTON
  - JUNGLE_BUTTON
  - ACACIA_BUTTON
  - DARK_OAK_BUTTON
  - MANGROVE_BUTTON
  - CHERRY_BUTTON
  - BAMBOO_BUTTON
  - CRIMSON_BUTTON
  - WARPED_BUTTON
  - STONE_BUTTON
  - POLISHED_BLACKSTONE_BUTTON
  - OAK_PRESSURE_PLATE
  - SPRUCE_PRESSURE_PLATE
  - BIRCH_PRESSURE_PLATE
  - JUNGLE_PRESSURE_PLATE
  - ACACIA_PRESSURE_PLATE
  - DARK_OAK_PRESSURE_PLATE
  - MANGROVE_PRESSURE_PLATE
  - CHERRY_PRESSURE_PLATE
  - BAMBOO_PRESSURE_PLATE
  - CRIMSON_PRESSURE_PLATE
  - WARPED_PRESSURE_PLATE
  - STONE_PRESSURE_PLATE
  - POLISHED_BLACKSTONE_PRESSURE_PLATE
  - LIGHT_WEIGHTED_PRESSURE_PLATE
  - HEAVY_WEIGHTED_PRESSURE_PLATE
view-only-containers:
  - CHEST
  - TRAPPED_CHEST
  - BARREL
  - ENDER_CHEST
  - HOPPER
  - DISPENSER
  - DROPPER
  - FURNACE
  - BLAST_FURNACE
  - SMOKER
  - BREWING_STAND
  - SHULKER_BOX
  - WHITE_SHULKER_BOX
  - ORANGE_SHULKER_BOX
  - MAGENTA_SHULKER_BOX
  - LIGHT_BLUE_SHULKER_BOX
  - YELLOW_SHULKER_BOX
  - LIME_SHULKER_BOX
  - PINK_SHULKER_BOX
  - GRAY_SHULKER_BOX
  - LIGHT_GRAY_SHULKER_BOX
  - CYAN_SHULKER_BOX
  - PURPLE_SHULKER_BOX
  - BLUE_SHULKER_BOX
  - BROWN_SHULKER_BOX
  - GREEN_SHULKER_BOX
  - RED_SHULKER_BOX
  - BLACK_SHULKER_BOX
  - LECTERN
  - CHISELED_BOOKSHELF
update-checker-enabled: false
notify-admins-about-updates: false
create-config-reference: false
max-config-backups: 5
backup-config-before-auto-update: false
update-lists-on-next-reload: false
auto-clean-invalid-config-values: true
config-version: 7
EOF

# ------------------------------------------------------------------------------
# 6. StartupCommands Config (replaces FIFO-based delayed commands)
# ------------------------------------------------------------------------------

echo "Seeding StartupCommands configuration..."
mkdir -p "$SERVER_DIR/plugins/StartupCommands"

COMMANDS_CONTENT="commands:\n"
COMMANDS_CONTENT="${COMMANDS_CONTENT}  defaultgamemode creative:\n"
COMMANDS_CONTENT="${COMMANDS_CONTENT}    delay: 0\n"
COMMANDS_CONTENT="${COMMANDS_CONTENT}    notify-on-exec: false\n"

for world in "${DETECTED_WORLDS[@]}"; do
    env="NORMAL"
    if [[ "$world" == *"nether"* ]]; then env="NETHER"; fi
    if [[ "$world" == *"end"* ]]; then env="THE_END"; fi

    COMMANDS_CONTENT="${COMMANDS_CONTENT}  \"mv import $world $env\":\n"
    COMMANDS_CONTENT="${COMMANDS_CONTENT}    delay: 1\n"
    COMMANDS_CONTENT="${COMMANDS_CONTENT}    notify-on-exec: false\n"

    # Map standard worlds to their vanilla dimension IDs for execute in
    execute_ns=""
    if [[ "$world" == "world" ]]; then execute_ns="minecraft:overworld"; fi
    if [[ "$world" == "world_nether" ]]; then execute_ns="minecraft:the_nether"; fi
    if [[ "$world" == "world_the_end" ]]; then execute_ns="minecraft:the_end"; fi

    if [ -n "$execute_ns" ]; then
        COMMANDS_CONTENT="${COMMANDS_CONTENT}  \"execute in $execute_ns run gamerule randomTickSpeed 0\":\n"
        COMMANDS_CONTENT="${COMMANDS_CONTENT}    delay: 1\n"
        COMMANDS_CONTENT="${COMMANDS_CONTENT}    notify-on-exec: false\n"
        COMMANDS_CONTENT="${COMMANDS_CONTENT}  \"execute in $execute_ns run gamerule doMobSpawning false\":\n"
        COMMANDS_CONTENT="${COMMANDS_CONTENT}    delay: 1\n"
        COMMANDS_CONTENT="${COMMANDS_CONTENT}    notify-on-exec: false\n"
        COMMANDS_CONTENT="${COMMANDS_CONTENT}  \"execute in $execute_ns run gamerule doDaylightCycle false\":\n"
        COMMANDS_CONTENT="${COMMANDS_CONTENT}    delay: 1\n"
        COMMANDS_CONTENT="${COMMANDS_CONTENT}    notify-on-exec: false\n"
        COMMANDS_CONTENT="${COMMANDS_CONTENT}  \"execute in $execute_ns run gamerule doWeatherCycle false\":\n"
        COMMANDS_CONTENT="${COMMANDS_CONTENT}    delay: 1\n"
        COMMANDS_CONTENT="${COMMANDS_CONTENT}    notify-on-exec: false\n"
        COMMANDS_CONTENT="${COMMANDS_CONTENT}  \"execute in $execute_ns run gamerule showDeathMessages false\":\n"
        COMMANDS_CONTENT="${COMMANDS_CONTENT}    delay: 1\n"
        COMMANDS_CONTENT="${COMMANDS_CONTENT}    notify-on-exec: false\n"
        COMMANDS_CONTENT="${COMMANDS_CONTENT}  \"execute in $execute_ns run gamerule spawnChunkRadius 0\":\n"
        COMMANDS_CONTENT="${COMMANDS_CONTENT}    delay: 1\n"
        COMMANDS_CONTENT="${COMMANDS_CONTENT}    notify-on-exec: false\n"
    fi

    COMMANDS_CONTENT="${COMMANDS_CONTENT}  \"mvm $world set gamemode creative\":\n"
    COMMANDS_CONTENT="${COMMANDS_CONTENT}    delay: 2\n"
    COMMANDS_CONTENT="${COMMANDS_CONTENT}    notify-on-exec: false\n"
done

COMMANDS_CONTENT="${COMMANDS_CONTENT}  save-off:\n"
COMMANDS_CONTENT="${COMMANDS_CONTENT}    delay: 5\n"
COMMANDS_CONTENT="${COMMANDS_CONTENT}    notify-on-exec: false\n"

printf "$COMMANDS_CONTENT" > "$SERVER_DIR/plugins/StartupCommands/config.yml"

# ------------------------------------------------------------------------------
# 7. Paper Global Config (disable nether generation)
# ------------------------------------------------------------------------------
echo "Seeding Paper global configuration..."
mkdir -p "$SERVER_DIR/config"
cat << 'EOF' > "$SERVER_DIR/config/paper-global.yml"
_version: 31
anticheat:
  obfuscation:
    items:
      all-models:
        also-obfuscate: []
        dont-obfuscate:
        - minecraft:lodestone_tracker
        sanitize-count: true
      enable-item-obfuscation: false
      model-overrides:
        minecraft:elytra:
          also-obfuscate: []
          dont-obfuscate:
          - minecraft:damage
          sanitize-count: true
block-updates:
  disable-chorus-plant-updates: false
  disable-mushroom-block-updates: false
  disable-noteblock-updates: false
  disable-tripwire-updates: false
chunk-loading-advanced:
  auto-config-send-distance: true
  player-max-concurrent-chunk-generates: 2
  player-max-concurrent-chunk-loads: 4
chunk-loading-basic:
  player-max-chunk-generate-rate: 4.0
  player-max-chunk-load-rate: 16.0
  player-max-chunk-send-rate: 16.0
collisions:
  enable-player-collisions: true
  send-full-pos-for-hard-colliding-entities: true
commands:
  ride-command-allow-player-as-vehicle: false
  suggest-player-names-when-null-tab-completions: true
  time-command-affects-all-worlds: false
console:
  enable-brigadier-completions: true
  enable-brigadier-highlighting: true
  has-all-permissions: false
item-validation:
  book:
    author: 8192
    page: 16384
    title: 8192
  book-size:
    page-max: 2560
    total-multiplier: 0.98
  display-name: 8192
  lore-line: 8192
  resolve-selectors-in-books: false
logging:
  deobfuscate-stacktraces: true
messages:
  kick:
    authentication-servers-down: '<lang:multiplayer.disconnect.authservers_down>'
    connection-throttle: Connection throttled! Please wait before reconnecting.
    flying-player: '<lang:multiplayer.disconnect.flying>'
    flying-vehicle: '<lang:multiplayer.disconnect.flying>'
  no-permission: '<red>I''m sorry, but you do not have permission to perform this command.
    Please contact the server administrators if you believe that this is in error.'
  use-display-name-in-quit-message: false
misc:
  chat-threads:
    chat-executor-core-size: -1
    chat-executor-max-size: -1
  client-interaction-leniency-distance: default
  compression-level: default
  enable-nether: false
  fix-far-end-terrain-generation: true
  load-permissions-yml-before-plugins: true
  max-joins-per-tick: 5
  prevent-negative-villager-demand: false
  region-file-cache-size: 256
  send-full-pos-for-item-entities: false
  strict-advancement-dimension-check: false
  use-alternative-luck-formula: false
  use-dimension-type-for-custom-spawners: false
  xp-orb-groups-per-area: default
packet-limiter:
  all-packets:
    action: KICK
    interval: 7.0
    max-packet-rate: 500.0
  kick-message: '<red><lang:disconnect.exceeded_packet_rate>'
  overrides:
    minecraft:place_recipe:
      action: DROP
      interval: 4.0
      max-packet-rate: 5.0
player-auto-save:
  max-per-tick: -1
  rate: -1
proxies:
  bungee-cord:
    online-mode: true
  proxy-protocol: false
  velocity:
    enabled: false
    online-mode: true
    secret: ''
scoreboards:
  save-empty-scoreboard-teams: true
  track-plugin-scoreboards: false
spam-limiter:
  incoming-packet-threshold: 300
  recipe-spam-increment: 1
  recipe-spam-limit: 20
  tab-spam-increment: 1
  tab-spam-limit: 500
spark:
  enable-immediately: false
  enabled: true
unsupported-settings:
  allow-headless-pistons: false
  allow-permanent-block-break-exploits: false
  allow-piston-duplication: false
  allow-unsafe-end-portal-teleportation: false
  compression-format: ZLIB
  perform-username-validation: true
  skip-tripwire-hook-placement-validation: false
  skip-vanilla-damage-tick-when-shield-blocked: false
  update-equipment-on-player-actions: true
watchdog:
  early-warning-delay: 10000
  early-warning-every: 5000
EOF
echo "Paper nether generation disabled."

echo "=========================================================="
 echo " Config Seeding Complete!                                 "
echo " Starting Paper server with optimized flags... "
echo "=========================================================="

# Change to server instance directory so Paper creates files in the right place
cd "$SERVER_DIR"

# Clear Paper remap cache to avoid stale directory/jar conflicts
rm -rf plugins/.paper-remapped

# Start server
java -Xms"$MIN_RAM" -Xmx"$MAX_RAM" -XX:+UseG1GC \
 -XX:+ParallelRefProcEnabled \
 -XX:MaxGCPauseMillis=200 \
 -XX:+UnlockExperimentalVMOptions \
 -XX:+DisableExplicitGC \
 -XX:+AlwaysPreTouch \
 -XX:G1NewSizePercent=30 \
 -XX:G1MaxNewSizePercent=40 \
 -XX:G1HeapRegionSize=8M \
 -XX:G1ReservePercent=20 \
 -XX:InitiatingHeapOccupancyPercent=15 \
 -XX:SurvivorRatio=32 \
 -XX:+PerfDisableSharedMem \
 -XX:MaxTenuringThreshold=1 \
 -Dusing.aikars.flags=https://mcflags.emc.gs \
 -Daikars.new.flags=true \
 -DGeyser.PrintSecureChatInformation=false \
 -jar "$JAR_NAME" nogui
