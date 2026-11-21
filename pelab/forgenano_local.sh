#!/bin/bash

# --- Configuration ---
SEARCH_IP="127.0.0.1"
KNOWN_HOSTS="/etc/ssh/ssh_known_hosts"
PUPPETFILE_PATH="/var/www/production/Puppetfile"
PUPPETFILE_BACKUP="/root/Puppetfile"
CONTROL_REPO_DIR="/var/www/production"

# 1. Dynamically get the FQDN via Facter (Puppet's source of truth)
DYNAMIC_FQDN=$(facter networking.fqdn)

# 2. Extract and sanitize the SSH key
# tail -n 1 ensures we get the most recent entry
# tr -d removes newlines and spaces that cause JSON breakage
RAW_KEY=$(grep "$SEARCH_IP" "$KNOWN_HOSTS" | grep "ssh-ed25519" | tail -n 1 | awk '{print $3}' | tr -d '\n\r ')

# 3. Validation
if [ -z "$RAW_KEY" ]; then
    echo "Error: ssh-ed25519 key for $SEARCH_IP not found in $KNOWN_HOSTS"
    exit 1
fi

if [ -z "$DYNAMIC_FQDN" ]; then
    echo "Error: Could not determine FQDN via facter."
    exit 1
fi

# 4. Construct the JSON string
PUPPET_JSON=$(cat <<EOF
[
  {
    "name": "$DYNAMIC_FQDN",
    "type": "ssh-ed25519",
    "key": "$RAW_KEY"
  }
]
EOF
)

# 5. Display Result and Confirmation
echo "--- Generated Puppet JSON for $DYNAMIC_FQDN ---"
echo "$PUPPET_JSON"
echo "------------------------------------------------"
echo "Check that r10_known_hosts is updated if required."
read -n 1 -s -r -p "Press any key to begin the deployment workflow..."
echo -e "\n"

# --- Deployment Workflow ---

# A. Clear Puppetfile to reset environment state
echo "Step A: Clearing Puppetfile and running agent..."
rm -f "$PUPPETFILE_PATH"
puppet agent -t

# B. Commit the empty state to Git
echo "Step B: Pushing empty state to Git..."
cd "$CONTROL_REPO_DIR" || exit
git add .
git commit -m "nano: clearing environment" || echo "Nothing to commit"
git push

# C. Deploy empty state and sync
echo "Step C: Deploying production code (empty)..."
puppet code deploy production --wait
puppet agent -t

# D. Restore the actual Puppetfile
echo "Step D: Restoring Puppetfile from $PUPPETFILE_BACKUP..."
cp "$PUPPETFILE_BACKUP" "$PUPPETFILE_PATH"

# E. Commit the restored Puppetfile
echo "Step E: Pushing restored Puppetfile to Git..."
cd "$CONTROL_REPO_DIR" || exit
git add .
git commit -m "nano: restoring modules" || echo "Nothing to commit"
git push

# F. Final Deployment
echo "Step F: Final code deploy and agent sync..."
puppet code deploy production --wait
puppet agent -t

echo "--- Workflow Complete ---"
