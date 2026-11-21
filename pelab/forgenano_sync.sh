#!/usr/bin/env bash
set -euo pipefail

# forgenano_sync.sh – mirror the modules listed in the control-repo Puppetfile
# into the local forgenano forge.  The Puppetfile itself is left UNCHANGED.
#
# Usage: forgenano_sync.sh <forge_token> <admin_key> <port> [puppetfile_path]
#   forge_token     – Puppet Forge bearer token (blank = public modules only)
#   admin_key       – forgenano admin key (default: random)
#   port            – forgenano port (default 6157)
#   puppetfile_path – path to the Puppetfile (default /var/www/production/Puppetfile)

FORGE_TOKEN="${1:-}"
ADMIN_KEY="${2:-$(openssl rand -hex 16)}"
PORT="${3:-6157}"
PUPPETFILE_PATH="${4:-/var/www/production/Puppetfile}"
FORGENANO_URL="http://localhost:${PORT}/v3/modules"

if [ ! -f "$PUPPETFILE_PATH" ]; then
    echo "Error: Puppetfile not found at $PUPPETFILE_PATH"
    exit 1
fi

echo "--- Reading Puppetfile: $PUPPETFILE_PATH ---"

# Extract forge module names from `mod 'owner-name'[, 'version']` lines.
# Skip modules with :git / :path / :svn / :hg sources (not from the Forge).
MODULES=$(grep -E "^\s*mod\s+['\"]" "$PUPPETFILE_PATH" \
    | grep -vE ":\s*(git|path|svn|hg)\b" \
    | sed -E "s/^\s*mod\s+['\"]([^'\"]+)['\"].*/\1/" \
    | tr '/' '-' \
    | sort -u)

if [ -z "$MODULES" ]; then
    echo "No forge modules found in Puppetfile."
else
    echo "--- Mirroring $(echo "$MODULES" | wc -l) modules into forgenano ---"
# Fallback: mirror the module's tarball DIRECTLY from the Forge (with the token)
# when the build path fails -- e.g. premium "release-token" modules whose file
# download 401s via `puppet module install` even though the Forge API + file
# download work with a valid token.  The local forge serves whatever tarballs
# are present in STORAGE_DIR, so a direct mirror is enough for r10k/code-manager.
_direct_mirror() {
    local mod="$1"
    local storage="${PUPPET_FORGE_STORAGE:-/var/lib/puppet_localforge}"
    [ -z "$FORGE_TOKEN" ] && return 1
    [ -d "$storage" ] || return 1
    local meta ver url
    meta=$(curl -s --max-time 20 -H "Authorization: Bearer $FORGE_TOKEN" \
             "https://forgeapi.puppet.com/v3/modules/${mod}" 2>/dev/null)
    ver=$(printf '%s' "$meta" | python3 -c 'import sys,json;print(json.load(sys.stdin)["current_release"]["version"])' 2>/dev/null)
    [ -z "$ver" ] && return 1
    url="https://forgeapi.puppet.com/v3/files/${mod}-${ver}.tar.gz"
    if curl -s -f --max-time 120 -H "Authorization: Bearer $FORGE_TOKEN" \
         -o "${storage}/${mod}-${ver}.tar.gz" "$url"; then
        chown localforge:localforge "${storage}/${mod}-${ver}.tar.gz" 2>/dev/null || true
        echo "DONE (direct mirror ${ver})"
        return 0
    fi
    rm -f "${storage}/${mod}-${ver}.tar.gz"
    return 1
}

    for MOD in $MODULES; do
        echo -n "Building: $MOD ... "
        CURL_ARGS=(-s -X POST "$FORGENANO_URL" \
            -H "X-API-KEY: $ADMIN_KEY" \
            -H "Content-Type: application/json" \
            -d "{\"module\": \"$MOD\"}")
        if [ -n "$FORGE_TOKEN" ]; then
            CURL_ARGS+=(-H "X-FORGE-TOKEN: $FORGE_TOKEN")
        fi
        _fnbody=$(mktemp)
        _fncode=$(curl -s -o "$_fnbody" -w '%{http_code}' "${CURL_ARGS[@]}")
        if [[ "$_fncode" == "201" ]]; then
            echo "DONE"
        elif _direct_mirror "$MOD"; then
            :
        else
            echo "FAILED (HTTP ${_fncode}) - $(sed -e 's/\x1b\[[0-9;]*m//g' "$_fnbody" 2>/dev/null | cut -c1-160)"
        fi
        rm -f "$_fnbody"
    done
fi

# NOTE: The control-repo Puppetfile is left UNCHANGED (the user manages it).
# forgenano only mirrors the modules it lists; it does NOT rewrite the forge URL
# or commit anything.
echo "--- forgenano sync complete (Puppetfile left unchanged) ---"
