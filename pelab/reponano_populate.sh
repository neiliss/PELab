#!/bin/bash
# Script to batch-sync specific packages to Reponano

REPO_IP="localhost"
PORT="3864"
DISTRO="ubuntu"
VER="$(. /etc/os-release && echo "$VERSION_CODENAME")"

# List of packages you want to download (no dependencies)
PACKAGES=(
    "sl"
    "hello"
    "tree"
    "ed"
    "htop"
    "vim-tiny"
)

echo "--- Starting Batch Sync to Reponano ---"

for PKG in "${PACKAGES[@]}"; do
    echo "Syncing: $PKG..."
    
    # Send the request to Reponano
    curl -s -X POST "http://$REPO_IP:$PORT/sync" \
         -H "Content-Type: application/json" \
         -d "{
               \"pkg\": \"$PKG\",
               \"distro\": \"$DISTRO\",
               \"ver\": \"$VER\",
               \"deps\": false
             }" | jq .

    echo "--------------------------------"
done

echo "Batch sync complete. Check 'sudo journalctl -u reponano -f' for logs."
