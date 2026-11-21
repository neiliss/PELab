#!/bin/bash
# Reponano Client Toggle v2.2
set -e

BACKUP_DIR="/etc/apt/reponano_original_config"
REPO_PORT="3864"
DISTRO="${2:-ubuntu}"
# Auto-detect the node's OWN codename so it always points at the repo path that
# reponano populated (e.g. noble), even if the base image uses another codename.
VER="${3:-$(. /etc/os-release && echo "$VERSION_CODENAME")}"
ARCH="${4:-amd64}"

if [ "$EUID" -ne 0 ]; then 
  echo "Error: Please run as root"
  exit 1
fi

# --- RESTORE MODE ---
if [[ "$1" == "--restore" ]]; then
    echo "--- Restoring Original Online Configuration ---"
    
    if [ ! -d "$BACKUP_DIR" ]; then
        echo "Error: No initial backup found at $BACKUP_DIR."
        exit 1
    fi

    # Wipe existing (offline) config
    rm -f /etc/apt/sources.list
    rm -rf /etc/apt/sources.list.d/*

    # Restore original files
    cp -a "$BACKUP_DIR/sources.list" /etc/apt/sources.list
    if [ -d "$BACKUP_DIR/sources.list.d" ]; then
        cp -a "$BACKUP_DIR/sources.list.d/." /etc/apt/sources.list.d/
    fi

    # Cleanup metadata
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    
    echo "Updating mirrors..."
    if apt-get update; then
        echo "SUCCESS: Client is back ONLINE."
        # Optional: Remove backup dir if you want a clean slate
        # rm -rf "$BACKUP_DIR"
    else
        echo "WARNING: Files restored, but 'apt update' failed. Check internet."
    fi
    exit 0
fi

# --- OFFLINE MODE ---
REPO_NODE="${1:-reponano}"

echo "--- Switching to OFFLINE Mode (Node: $REPO_NODE) ---"

# 1. ONLY backup if the backup directory doesn't exist yet.
# This prevents backing up the 'offline' config over your 'online' config.
if [ ! -d "$BACKUP_DIR" ]; then
    echo "Creating permanent backup of original online config..."
    mkdir -p "$BACKUP_DIR"
    [ -f /etc/apt/sources.list ] && cp -a /etc/apt/sources.list "$BACKUP_DIR/"
    [ -d /etc/apt/sources.list.d ] && cp -a /etc/apt/sources.list.d "$BACKUP_DIR/"
else
    echo "Original backup already exists. Skipping backup step to protect online config."
fi

# 2. Clear current config
rm -f /etc/apt/sources.list
rm -rf /etc/apt/sources.list.d/*
mkdir -p /etc/apt/sources.list.d

# 3. Apply Reponano config
REPO_URL="http://${REPO_NODE}:${REPO_PORT}/repo/${DISTRO}/${VER}/${ARCH} /"
echo "deb [trusted=yes] ${REPO_URL}" > /etc/apt/sources.list

# 4. Refresh
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "Testing connection to Reponano..."
if apt-get update; then
    echo "SUCCESS: Client is now OFFLINE and linked to $REPO_NODE."
else
    echo "ERROR: Could not reach Reponano. Manual check required."
    exit 1
fi
