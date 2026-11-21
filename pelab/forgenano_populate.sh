#!/usr/bin/env bash

# --- Config ---
FORGE_URL="http://localhost:6157/v3/modules"
PUPPETFILE="${1:-}"      # optional path to a Puppetfile to mirror its modules too
ADMIN_KEY="${2:-$(openssl rand -hex 16)}"
FORGE_TOKEN="${3:-}"     # optional Forge bearer token (for premium modules)

# --- Base built-in catalog (known modules to always mirror, incl. premium) ---
MODULES=(
    "puppetlabs-playbook_runner"
    "puppetlabs-edgeops"
    "puppetlabs-cd4peadm"
    "puppetlabs/comply"
    "puppetlabs-puppet_data_connector"
    "puppetlabs-nessus_transformer"
    "albatrossflavour-puppet_data_connector_enhancer"
    "puppet-python"
    "puppet-epel"
    "puppetlabs-node_encrypt"
    "puppetlabs-puppet_authorization"
    "puppetlabs-hocon"
    "puppetlabs-motd"
    "puppetlabs/concat"
    "puppet-grafana"
    "puppetlabs-puppet_operational_dashboards"
    "puppetlabs-puppet_conf"
    "puppet/archive"
    "puppetlabs/chocolatey"
    "puppetlabs/inifile"
    "puppetlabs/ruby_task_helper"
    "puppetlabs/registry"
    "puppet-systemd"
    "puppet-prometheus"
    "puppet-telegraf"
    "puppetlabs-influxdb"
    "puppetlabs-docker"
    "puppetlabs/stdlib"
    "puppetlabs-apt"
    "puppetlabs/powershell"
    "puppetlabs/reboot"
    "puppetlabs/pwshlib"
    "puppet-vault"
    "puppet-hashi_stack"
    "puppet-vault_lookup"
    "stm-file_capability"
    "puppetlabs-f5"
)

# Extend the list with every module declared in the given Puppetfile, so the
# local forge mirrors exactly what the control-repo needs (including premium
# modules that require the bearer token).  Prefer the FULL Puppetfile here.
if [[ -n "$PUPPETFILE" && -f "$PUPPETFILE" ]]; then
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*mod[[:space:]] ]] || continue
        # 'Puppetfile' entries:  mod 'owner/name', :version => 'x'
        m=$(echo "$line" | sed -n "s/.*mod[[:space:]]*['\"]\([^'\"]*\)['\"].*/\\1/p")
        # Normalise owner/name -> owner-name (forgenano's naming).
        m=$(echo "$m" | tr '/' '-')
        [[ -n "$m" ]] && MODULES+=("$m")
    done < "$PUPPETFILE"
fi

# Deduplicate while preserving order.
MODULES=($(printf '%s\n' "${MODULES[@]}" | awk '!seen[$0]++'))

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

_fnok=0; _fnbad=0
for MOD in "${MODULES[@]}"; do
    CLEAN_MOD=$(echo "$MOD" | tr '/' '-')
    echo -n "Building: $CLEAN_MOD ... "
    
    _fnbody=$(mktemp)
    _fncode=$(curl -s -o "$_fnbody" -w '%{http_code}' -X POST "$FORGE_URL" \
        -H "X-API-KEY: $ADMIN_KEY" \
        -H "X-FORGE-TOKEN: $FORGE_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"module\": \"$CLEAN_MOD\"}")
    if [[ "$_fncode" == "201" ]]; then
        echo "DONE"; _fnok=$((_fnok+1))
    elif _direct_mirror "$CLEAN_MOD"; then
        _fnok=$((_fnok+1))
    else
        echo "FAILED (HTTP ${_fncode}) - $(sed -e 's/\x1b\[[0-9;]*m//g' "$_fnbody" 2>/dev/null | cut -c1-160)"
        _fnbad=$((_fnbad+1))
    fi
    rm -f "$_fnbody"
done
echo
echo "Forgenano populate: ${_fnok} mirrored, ${_fnbad} failed (of ${#MODULES[@]})."
