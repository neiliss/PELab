#!/usr/bin/env bash
# reponano_forgenano_sync.sh - pull the OS packages required by the forgenano
# modules into reponano, so Puppet can install them fully offline.
# forgenano's /admin/inspect_all scans every built module's .pp files for
# `package { 'name': }` resources and returns the deduplicated set, which we
# feed to reponano /sync (deps=false -> the package + its direct deps).
set -euo pipefail

FORGE_IP="${1:-localhost}"
FORGE_PORT="${2:-6157}"
FORGE_KEY="${3:-$(openssl rand -hex 16)}"
REPO_IP="${4:-localhost}"
REPO_PORT="${5:-3864}"
DISTRO="${6:-ubuntu}"
VER="${7:-$(. /etc/os-release && echo "$VERSION_CODENAME")}"
ARCH="${8:-amd64}"

ADMIN_URL="http://$FORGE_IP:$FORGE_PORT/admin/inspect_all"
SYNC_URL="http://$REPO_IP:$REPO_PORT/sync"

echo "--- Querying forgenano for OS packages required by built modules ---"
JSON=$(curl -s -H "X-API-KEY: $FORGE_KEY" "$ADMIN_URL")

# Extract summary.unique_system_packages_required via python3 (present on the
# master via reponano/forgenano deps).  We only want the package NAMES.
PKGS=$(printf '%s' "$JSON" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    pkgs = sorted(set(d.get("summary", {}).get("unique_system_packages_required", [])))
    print("\n".join(pkgs))
except Exception as e:
    sys.stderr.write("ERROR parsing forgenano inspect_all: %s\n" % e)
    sys.exit(1)
' || true)

if [[ -z "$PKGS" ]]; then
  echo "No system packages declared by built modules (or nothing built yet)."
  exit 0
fi

COUNT=$(printf '%s\n' "$PKGS" | grep -c . || true)
echo "--- Forgenano modules require $COUNT OS packages; syncing into reponano ---"
while IFS= read -r PKG; do
  [[ -z "$PKG" ]] && continue
  echo -n "Syncing: $PKG ... "
  RESP=$(curl -s -X POST "$SYNC_URL" \
    -H "Content-Type: application/json" \
    -d "{\"pkg\":\"$PKG\",\"distro\":\"$DISTRO\",\"ver\":\"$VER\",\"arch\":\"$ARCH\",\"deps\":false}")
  if echo "$RESP" | grep -q '"status"[[:space:]]*:[[:space:]]*"success"'; then
    echo "DONE"
  else
    echo "FAILED: $RESP"
  fi
done <<< "$PKGS"
echo "--- Forgenano -> reponano package sync complete ---"
