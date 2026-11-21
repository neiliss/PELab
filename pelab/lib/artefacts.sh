# =============================================================================
# artefacts.sh  –  extracted from setup.sh (lines 1409-1597)
# Sourced by pelab.sh.  Do not run directly.
# =============================================================================
generate_params_json() {
  local params_file="${script_dir}/params.json"

  local compiler_hosts_json="[]"
  if [[ $compiler_count -gt 0 ]]; then
    compiler_hosts_json="["
    for i in $(seq 0 $((compiler_count-1))); do
      compiler_hosts_json+="\"$(build_fqdn "compiler${i}")\""
      [[ $i -lt $((compiler_count-1)) ]] && compiler_hosts_json+=","
    done
    compiler_hosts_json+="]"
  fi

  # Compiler pool address = the service address agents use to reach the
  # compiler pool.  For Docker LARGE/XL the HAProxy container fronts 8140, so
  # agents must point at its FQDN; for a plain VM LARGE the user-supplied
  # nodepooladdress (load-balancer/CIDR) is used.  An empty value must become
  # null (undef) – an empty string breaks peadm's Optional[String[1]] param.
  local cpa_value=""
  if [[ "$runtime" == "docker" && "$instype" =~ ^(XL|LARGE)$ ]]; then
    cpa_value=$(build_fqdn haproxy)
  elif [[ -n "$nodepooladdress" ]]; then
    cpa_value="$nodepooladdress"
  fi
  local cpa_json
  if [[ -n "$cpa_value" ]]; then
    cpa_json=$(jq -n --arg v "$cpa_value" '$v')
  else
    cpa_json="null"
  fi

  local dns_alt_names_arr=("puppet" "$primary_host")
  # For docker, build_fqdn returns the short name; add the FQDN (with the GCP
  # DNS suffix) so the cert matches the hostname pe_repo / facter actually use.
  if [[ "$runtime" == "docker" && -n "${gcp_dns_suffix:-}" ]]; then
    dns_alt_names_arr+=("${primary_host}.${gcp_dns_suffix}")
  fi
  [[ -n "$cpa_value" ]] && dns_alt_names_arr+=("$cpa_value")
  [[ "$enable_dr" == "true" && -n "$replica_host" ]] && dns_alt_names_arr+=("$replica_host")
  local dns_json
  dns_json=$(printf '%s\n' "${dns_alt_names_arr[@]}" | jq -R . | jq -s .)

  local replica_extra="null"
  if [[ "$enable_dr" == "true" && -n "$replica_host" ]]; then
    # replica_postgresql_host is only set for XL (separate replica PDB node).
    # For STANDARD/LARGE it is left unset so peadm co-locates PostgreSQL on the
    # replica.  An empty string would be treated as a real host by peadm, so it
    # must be omitted entirely.
    local rp_extra="null"
    if [[ -n "$replica_postgresql_host" ]]; then
      rp_extra=$(jq -n --arg rph "$replica_postgresql_host" \
        '{ replica_postgresql_host: $rph }')
    fi
    replica_extra=$(jq -n \
      --arg rh "$replica_host" \
      --argjson rp_extra "$rp_extra" \
      '{ replica_host: $rh } + (if $rp_extra != null then $rp_extra else {} end)')
  fi

  # primary_postgresql_host is only set for XL (separate PDB node).  For
  # STANDARD/LARGE it is left unset so peadm co-locates PostgreSQL on the
  # primary.
  local primary_extra="null"
  if [[ -n "$primary_postgresql_host" ]]; then
    primary_extra=$(jq -n \
      --arg pph "$primary_postgresql_host" \
      '{ primary_postgresql_host: $pph }')
  fi

  # Offline PE tarball: peadm's retrieve_and_upload plan uses the tarball
  # already present at ${stagingdir}/${pe_tarball_name} on the Bolt host and
  # skips the download.  Stage the user's tarball under the exact name peadm
  # expects (puppet-enterprise-<version>-<platform>.tar.gz) so the version and
  # tarball always match.
  # LAB BUILD: permit_unsafe_versions is ALWAYS true so any PE version
  # (e.g. 2025.12.0, 2026.0.0) proceeds even when this peadm build doesn't
  # know it yet.  The vendored peadm has version gating disabled as well.
  local stagingdir_json="null" permit_unsafe_json="true"
  if [[ -n "$pe_tarball_path" && -f "$pe_tarball_path" ]]; then
    local pe_tarball_name="puppet-enterprise-${pe_version}-${pe_platform}.tar.gz"
    local staging_dir="/tmp"
    local _staged="${staging_dir}/${pe_tarball_name}"

    # Stage the tarball under the name peadm expects.  Pre-release / EA builds
    # sometimes ship an UNCOMPRESSED .tar, but the staging dir and peadm expect
    # <name>.tar.gz (this function only copies - it never gzipped), so an
    # uncompressed tarball previously failed to extract.  Compress on the fly.
    local _fmt; _fmt=$(file -b "$pe_tarball_path" 2>/dev/null || echo "")
    if [[ "$_fmt" == gzip* ]]; then
      [[ "$pe_tarball_path" != "$_staged" ]] && cp -f "$pe_tarball_path" "$_staged"
      tui_ok "Staged PE tarball (gzip) as ${_staged}"
    else
      tui_info "PE tarball is not gzip-compressed (${_fmt:-unknown}) – compressing to ${pe_tarball_name} …"
      if ! gzip -c "$pe_tarball_path" > "$_staged"; then
        tui_err "Failed to gzip the PE tarball: $pe_tarball_path"
        rm -f "$_staged"; exit 1
      fi
      tui_ok "Compressed + staged PE tarball as ${_staged}"
    fi

    # Validate BEFORE uploading: gzip integrity + a full tar listing.  A truncated
    # download otherwise fails deep inside peadm::install on the target with
    # "tar: Unexpected EOF in archive" / "rmtlseek not stopped at a record
    # boundary" - fail fast here with an actionable message instead.
    if ! gzip -t "$_staged" 2>/dev/null; then
      tui_err "Staged PE tarball is not valid gzip: ${_staged}"
      tui_err "The archive is incomplete/corrupt – re-download it and retry."
      exit 1
    fi
    if ! tar -tzf "$_staged" >/dev/null 2>&1; then
      tui_err "Staged PE tarball failed integrity check (tar listing hit EOF):"
      tui_err "  ${_staged}"
      tui_err "The tarball is TRUNCATED/incomplete – fetch the complete archive and retry."
      exit 1
    fi
    tui_ok "PE tarball validated (gzip + complete tar listing OK)"

    stagingdir_json=$(jq -n --arg s "$staging_dir" '$s')
    # Informational only: flag versions newer than peadm's known newest.
    local _vn _nn
    _vn=$(printf '%s\n' "$pe_version" | awk -F. '{printf "%d%02d", $1, $2}')
    _nn=$(printf '%s\n' "$peadm_newest" | awk -F. '{printf "%d%02d", $1, $2}')
    if [[ "$_vn" -gt "$_nn" ]]; then
      tui_info "PE ${pe_version} is newer than peadm's known newest (${peadm_newest}) -"
      tui_info "proceeding anyway (permit_unsafe_versions=true, version gating disabled)."
    fi
  fi

  # The Forge token is used by forgenano to mirror modules.  For NON-offline
  # builds it's ALSO injected into pe.conf (via pe_conf_data) so code-manager/r10k
  # can pull premium modules from the public Forge.  For OFFLINE/air-gap builds
  # the Puppetfile is pointed at the local forgenano mirror and NO public-forge
  # token is set in pe.conf.
  local pe_conf_json="null"
  if [[ "$full_offline" != "true" && -n "$forgenano_forge_token" ]]; then
    local forge_auth="Bearer ${forgenano_forge_token}"
    pe_conf_json=$(jq -n --arg tok "$forge_auth" \
      '{ "puppet_enterprise::master::code_management::forge_authorization_token": $tok }')
  fi

  jq -n \
    --arg  primary_host            "$primary_host" \
    --argjson compiler_pool_address   "$cpa_json" \
    --arg  console_password        "$adminpwd" \
    --arg  version                 "$pe_version" \
    --arg  r10k_remote             "$r10k_remote" \
    --arg  r10k_private_key_file   "$r10k_private_key_file" \
    --argjson compiler_hosts       "$compiler_hosts_json" \
    --argjson dns_alt_names        "$dns_json" \
    --argjson r10k_known_hosts     "$r10k_known_hosts" \
    --argjson primary_extra        "$primary_extra" \
    --argjson replica_extra        "$replica_extra" \
    --argjson stagingdir           "$stagingdir_json" \
    --argjson permit_unsafe_versions "$permit_unsafe_json" \
    --argjson pe_conf_data        "$pe_conf_json" \
    '{
      primary_host:            $primary_host,
      compiler_hosts:          $compiler_hosts,
      compiler_pool_address:   $compiler_pool_address,
      console_password:        $console_password,
      dns_alt_names:           $dns_alt_names,
      version:                 $version,
      code_manager_auto_configure: true,
      r10k_remote:             $r10k_remote,
      r10k_private_key_file:   $r10k_private_key_file,
      r10k_known_hosts:        $r10k_known_hosts,
      permit_unsafe_versions: $permit_unsafe_versions
    } + (if $stagingdir != null then { stagingdir: $stagingdir } else {} end) + (if $primary_extra != null then $primary_extra else {} end) + (if $replica_extra != null then $replica_extra else {} end) + (if $pe_conf_data != null then { pe_conf_data: $pe_conf_data } else {} end)' \
    > "$params_file"

  PARAMS_FILE="$params_file"
  tui_ok "params.json written"
}

# ──────────────────────────────────────────────────────────────────────────────
# GENERATE INVENTORY.YAML
# All bolt calls use --inventoryfile explicitly – never rely on CWD discovery.
# host-key-check is false here because bootstrap_ssh_trust populates known_hosts
# on the TARGET nodes, not on this host.  The wizard host connects outbound.
# ──────────────────────────────────────────────────────────────────────────────
generate_inventory_yaml() {
  local inv="${script_dir}/inventory.yaml"

  cat > "$inv" <<EOIY
---
version: 2
groups:
  - name: puppet-enterprise-nodes
    config:
      transport: ssh
      ssh:
        user: ${ssh_user}
        private-key: ${bolt_ssh_key}
        host-key-check: false
        run-as: root
    targets:
EOIY

  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    # Containers run on a remote Docker-host VM.  Each container's SSH (port 22)
    # is mapped to a unique host port on the Docker host, so Bolt connects to
    # the container hostname on that mapped port.
    local port=2201 role
    for role in $(docker_roles); do
      # Bolt needs the connection address in the target's uri (the container
      # hostname, resolved to the Docker-host IP via /etc/hosts) plus the mapped
      # host port.  A bare name with config.ssh.port leaves Bolt without a host.
      cat >> "$inv" <<EOIY
      - name: $(build_fqdn "$role")
        uri: $(build_fqdn "$role"):${port}
EOIY
      port=$((port+1))
    done
  else
    for i in $(seq 0 $((node_count-1))); do
      echo "      - $(build_fqdn "core${i}")" >> "$inv"
    done

    if [[ $compiler_count -gt 0 ]]; then
      for i in $(seq 0 $((compiler_count-1))); do
        echo "      - $(build_fqdn "compiler${i}")" >> "$inv"
      done
    fi

    if [[ "$instype" =~ ^(XL|xl|LARGE|large)$ ]]; then
      echo "      - $(build_fqdn haproxy)" >> "$inv"
    fi
  fi

  tui_ok "inventory.yaml written"
  tui_blank
  tui_info "Targets in inventory:"
  grep '      - ' "$inv" | while read -r line; do
    tui_info "  $line"
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# TERRAFORM HELPER
# ──────────────────────────────────────────────────────────────────────────────
