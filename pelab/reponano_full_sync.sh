#!/usr/bin/env bash
# reponano_full_sync.sh – pull the full package manifest into reponano.
# Usage: reponano_full_sync.sh [repo-ip] [port] [distro] [ver] [arch]
set -euo pipefail

REPO_IP="${1:-localhost}"
PORT="${2:-3864}"
DISTRO="${3:-ubuntu}"
VER="${4:-$(. /etc/os-release && echo "$VERSION_CODENAME")}"
ARCH="${5:-amd64}"

# ── Full package manifest required for an offline PE lab ──────────────────
# Base OS + nano add-on dependencies + PE/agent packages + pdk + common tools.
# Each entry is POSTed to /sync with deps=false so the package plus its direct
# dependencies are pulled (the full recursive closure on a complete Ubuntu repo
# is impractically large).  Edit this list to match your lab's needs.
PACKAGES=(
  # reponano deps
  python3 python3-flask python3-pip dpkg-dev apt-rdepends createrepo-c dnf curl jq
  # forgenano deps
  python3-venv gunicorn
  # openainano deps
  python3-venv python3-pip
  # scanano deps
  nmap
  # hieranano deps
  python3-flask
  # pdk (puppet-tools repo)
  pdk
  # PE / agent packages (PE repo)
  puppet-agent puppetdb puppetserver pe-console-services pe-puppetserver \
  pe-puppetdb pe-puppetdb-termini pe-bolt-server pe-orchestration-services \
  pe-r10k pe-nginx pe-postgresql
  # common tools
  git vim htop tree ca-certificates gnupg lsb-release openssh-server haproxy
)

echo "--- Full offline sync: ${#PACKAGES[@]} packages (with deps) into reponano ---"
for PKG in "${PACKAGES[@]}"; do
  echo -n "Syncing: $PKG ... "
  RESP=$(curl -s -X POST "http://$REPO_IP:$PORT/sync" \
    -H "Content-Type: application/json" \
    -d "{\"pkg\":\"$PKG\",\"distro\":\"$DISTRO\",\"ver\":\"$VER\",\"arch\":\"$ARCH\",\"deps\":false}")
  if echo "$RESP" | grep -q '"status"[[:space:]]*:[[:space:]]*"success"'; then
    echo "DONE"
  else
    echo "FAILED: $RESP"
  fi
done
echo "--- Full offline sync complete ---"
