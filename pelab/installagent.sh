#!/bin/bash

# Check if the required parameters are provided
if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <puppet_role> <install_url>"
  exit 1
fi

# Define variables
PUPPET_CERT_DIR="/etc/puppetlabs/puppet/ssl"
PUPPET_PACKAGE="puppet-agent"
PUPPET_ROLE=$1
INSTALL_URL=$2

# The wizard connects as root, and the base image has no `sudo` installed – so
# only use sudo if we're NOT already root.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

# Normalise the install URL: accept a bare host ("haproxy"), a host plus
# port ("haproxy:8140"), or a full URL ("https://haproxy:8140");
# always ends up https://HOST:8140/packages/current/install.bash
case "${INSTALL_URL}" in
  *://*)  INSTALL_URL="${INSTALL_URL#*://}" ;;   # strip scheme if present
esac
case "${INSTALL_URL}" in
  *:*81*) INSTALL_URL="${INSTALL_URL%%:*}" ;;   # already carries :8140
esac
INSTALL_URL="https://${INSTALL_URL}:8140/packages/current/install.bash"

# Function to remove Puppet Agent
remove_puppet_agent() {
  echo "Removing Puppet agent..."
  if command -v apt-get >/dev/null 2>&1; then $SUDO apt-get remove -y $PUPPET_PACKAGE
  elif command -v dnf >/dev/null 2>&1; then $SUDO dnf remove -y $PUPPET_PACKAGE
  elif command -v yum >/dev/null 2>&1; then $SUDO yum remove -y $PUPPET_PACKAGE
  else $SUDO rpm -e $PUPPET_PACKAGE 2>/dev/null || true; fi
  echo "Removing SSL certificates..."
  $SUDO rm -rf $PUPPET_CERT_DIR
  echo "Puppet agent and certificates successfully removed."
}

# Function to install Puppet Agent
install_puppet_agent() {
  echo "Installing Puppet agent from ${INSTALL_URL}"
  curl -k "${INSTALL_URL}" | $SUDO bash -s extension_requests:pp_role="${PUPPET_ROLE}"

  if [ $? -ne 0 ]; then
    echo "Error during Puppet agent installation."
    exit 1
  fi

  echo "Puppet agent installed successfully."
}

# Function to create custom fact
create_myrole_fact() {
  echo "Creating custom fact myrole=${PUPPET_ROLE}..."

  $SUDO mkdir -p /etc/puppetlabs/facter/facts.d

  $SUDO tee /etc/puppetlabs/facter/facts.d/myrole.yaml > /dev/null <<EOF
myrole: ${PUPPET_ROLE}
EOF

  $SUDO chmod 644 /etc/puppetlabs/facter/facts.d/myrole.yaml
}

# Execute steps
remove_puppet_agent
install_puppet_agent
create_myrole_fact

# Confirm installation and apply catalog
echo "Verifying Puppet agent installation..."
puppet agent -t
