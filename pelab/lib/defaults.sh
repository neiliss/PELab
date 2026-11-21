# =============================================================================
# defaults.sh  –  extracted from setup.sh (lines 296-469)
# Sourced by pelab.sh.  Do not run directly.
# =============================================================================
load_defaults() {
  # Purge files that still contain raw shell placeholders (legacy)
  if [[ -f "$defaults_file" ]] && grep -q '\${' "$defaults_file" 2>/dev/null; then
    tui_warn "Legacy defaults detected – removing $defaults_file"
    rm -f "$defaults_file"; return 0
  fi

  [[ ! -f "$defaults_file" ]] && return 0

  if ! jq empty "$defaults_file" >/dev/null 2>&1; then
    tui_warn "Defaults file is corrupt – ignoring"
    rm -f "$defaults_file"; return 0
  fi

  _jq() { jq -r "${1} // empty" "$defaults_file"; }

  # ── Every saved field ──────────────────────────────────────────────────────
  provider=$(_jq            '.provider')
  runtime=$(_jq              '.runtime')
  docker_host=$(_jq          '.docker_host')
  docker_host_static_ip=$(_jq '.docker_host_static_ip')
  docker_host_ip=$(_jq       '.docker_host_ip')
  nodeprefix=$(_jq          '.nodeprefix')
  adminpwd=$(_jq            '.adminpwd')
  instype=$(_jq             '.instype')
  region=$(_jq              '.region')
  _raw_zone=$(_jq '.zone')
  if [[ "$_raw_zone" =~ ^[a-z]+-[a-z0-9]+-[a-z]$ ]]; then
    zone="${_raw_zone##*-}"
  else
    zone="$_raw_zone"
  fi
  gcp_project=$(_jq         '.gcp_project')
  gcp_dns_suffix=$(_jq      '.gcp_dns_suffix')
  nodepooladdress=$(_jq     '.nodepooladdress')
  node_size=$(_jq           '.node_size')
  gcp_machine_type=$(_jq    '.gcp_machine_type')
  gcp_compiler_type=$(_jq   '.gcp_compiler_type')
  aws_instance_type=$(_jq   '.aws_instance_type')
  azure_vm_size=$(_jq       '.azure_vm_size')
  pe_version=$(_jq          '.pe_version')
  pe_tarball_path=$(_jq     '.pe_tarball_path')
  pe_platform=$(_jq         '.pe_platform')
  base_os=$(_jq             '.base_os')
  peadm_module_dir=$(_jq    '.peadm_module_dir')
  custom_image=$(_jq        '.custom_image')
  ssh_key_path=$(_jq        '.ssh_key_path')
  ssh_user=$(_jq            '.ssh_user')
  r10k_remote=$(_jq         '.r10k_remote')
  r10k_private_key_file=$(_jq '.r10k_private_key_file')
  enable_dr=$(_jq           '.enable_dr')
  del_now=$(_jq             '.del_now')
  aws_vpc_id=$(_jq          '.aws_vpc_id')
  aws_subnet_id=$(_jq       '.aws_subnet_id')
  aws_region=$(_jq          '.aws_region')
  azure_location=$(_jq      '.azure_location')
  azure_resource_group=$(_jq '.azure_resource_group')
  suite_license_path=$(_jq   '.suite_license_path')
  docker_image=$(_jq         '.docker_image')
  docker_base=$(_jq          '.docker_base')
  # If not set explicitly, derive the container base OS from the chosen base
  # image (or the PE platform) so the Docker image OS matches the PE build.
  if [[ -z "$docker_base" ]]; then
    docker_base=$(docker_base_from_hint "${custom_image:-}")
    [[ -z "$docker_base" ]] && docker_base=$(docker_base_from_hint "${pe_platform:-}")
    [[ -z "$docker_base" ]] && docker_base="ubuntu:24.04"
  fi
  docker_default_tag="pe-lab-base:${docker_base#*:}"
  docker_network=$(_jq       '.docker_network')
  docker_topology=$(_jq      '.docker_topology')
  use_gitnano=$(_jq          '.use_gitnano')
  use_openainano=$(_jq       '.use_openainano')
  use_reponano=$(_jq         '.use_reponano')
  use_forgenano=$(_jq        '.use_forgenano')
  use_scanano=$(_jq          '.use_scanano')
  full_offline=$(_jq         '.full_offline')
  gitnano_port=$(_jq         '.gitnano_port')
  hieranano_port=$(_jq       '.hieranano_port')
  hieranano_http_port=$(_jq  '.hieranano_http_port')
  openainano_port=$(_jq      '.openainano_port')
  openainano_model=$(_jq     '.openainano_model')
  reponano_port=$(_jq        '.reponano_port')
  forgenano_port=$(_jq       '.forgenano_port')
  forgenano_admin_key=$(_jq  '.forgenano_admin_key')
  forgenano_forge_token=$(_jq '.forgenano_forge_token')
  forge_proxy=$(_jq          '.forge_proxy')
  scanano_port=$(_jq         '.scanano_port')
  scanano_token=$(_jq        '.scanano_token')

  # r10k_known_hosts is a JSON value – load raw then validate
  local _rkh
  _rkh=$(jq -c '.r10k_known_hosts // empty' "$defaults_file" 2>/dev/null || echo "")
  if [[ -n "$_rkh" ]] && echo "$_rkh" | jq empty >/dev/null 2>&1; then
    r10k_known_hosts="$_rkh"
  else
    r10k_known_hosts="[]"
  fi

  # Apply safe fallbacks for anything that came back empty
  enable_dr="${enable_dr:-false}"
  del_now="${del_now:-Y}"
  docker_host="${docker_host:-cloud}"
  use_gitnano="${use_gitnano:-false}"
  use_openainano="${use_openainano:-true}"
  use_reponano="${use_reponano:-true}"
  use_forgenano="${use_forgenano:-true}"
  use_scanano="${use_scanano:-true}"
  full_offline="${full_offline:-false}"
  gitnano_port="${gitnano_port:-5000}"
  hieranano_port="${hieranano_port:-5525}"
  hieranano_http_port="${hieranano_http_port:-5526}"
  openainano_port="${openainano_port:-5001}"
  openainano_model="${openainano_model:-minimax-m2.5:cloud}"
  reponano_port="${reponano_port:-3864}"
  forgenano_port="${forgenano_port:-6157}"
  forgenano_admin_key="${forgenano_admin_key:-$(openssl rand -hex 16)}"
  forgenano_forge_token="${forgenano_forge_token:-}"
  forge_proxy="${forge_proxy:-}"
  scanano_port="${scanano_port:-9000}"
  scanano_token="${scanano_token:-$(openssl rand -hex 16)}"
  r10k_remote="${r10k_remote:-git@gitlab:puppet/control-repo.git}"
  r10k_private_key_file="${r10k_private_key_file:-/root/peadm/id_rsa}"
  suite_license_path="${suite_license_path:-${script_dir}/suite-license.lic}"

  tui_ok "Loaded saved defaults from $(basename "$defaults_file")"
}

# ──────────────────────────────────────────────────────────────────────────────
# SAVE DEFAULTS  – every field, via jq --arg so special chars are safe
# ──────────────────────────────────────────────────────────────────────────────
save_defaults() {
  jq -n \
    --arg  provider            "$provider" \
    --arg  runtime             "$runtime" \
    --arg  docker_host         "$docker_host" \
    --arg  docker_host_static_ip "${docker_host_static_ip:-}" \
    --arg  docker_host_ip      "${docker_host_ip:-}" \
    --arg  nodeprefix          "$nodeprefix" \
    --arg  adminpwd            "$adminpwd" \
    --arg  instype             "$instype" \
    --arg  region              "$region" \
    --arg  zone                "$zone" \
    --arg  gcp_project         "$gcp_project" \
    --arg  gcp_dns_suffix      "$gcp_dns_suffix" \
    --arg  nodepooladdress     "$nodepooladdress" \
    --arg  node_size           "$node_size" \
    --arg  gcp_machine_type    "$gcp_machine_type" \
    --arg  gcp_compiler_type   "$gcp_compiler_type" \
    --arg  aws_instance_type   "$aws_instance_type" \
    --arg  azure_vm_size       "$azure_vm_size" \
    --arg  pe_version          "$pe_version" \
    --arg  pe_tarball_path     "$pe_tarball_path" \
    --arg  pe_platform         "$pe_platform" \
    --arg  base_os            "$base_os" \
    --arg  peadm_module_dir    "$peadm_module_dir" \
    --arg  custom_image        "$custom_image" \
    --arg  ssh_key_path        "$ssh_key_path" \
    --arg  ssh_user            "$ssh_user" \
    --arg  r10k_remote         "$r10k_remote" \
    --arg  r10k_private_key_file "$r10k_private_key_file" \
    --arg  enable_dr           "$enable_dr" \
    --arg  del_now             "$del_now" \
    --arg  aws_vpc_id          "$aws_vpc_id" \
    --arg  aws_subnet_id       "$aws_subnet_id" \
    --arg  aws_region          "$aws_region" \
    --arg  azure_location      "$azure_location" \
    --arg  azure_resource_group "$azure_resource_group" \
    --arg  suite_license_path  "$suite_license_path" \
    --arg  docker_image        "$docker_image" \
    --arg  docker_base         "$docker_base" \
    --arg  docker_network      "$docker_network" \
    --arg  docker_topology     "$docker_topology" \
    --arg  use_gitnano         "$use_gitnano" \
    --arg  use_openainano      "$use_openainano" \
    --arg  use_reponano        "$use_reponano" \
    --arg  use_forgenano       "$use_forgenano" \
    --arg  use_scanano         "$use_scanano" \
    --arg  full_offline        "$full_offline" \
    --arg  gitnano_port        "$gitnano_port" \
    --arg  hieranano_port      "$hieranano_port" \
    --arg  hieranano_http_port  "$hieranano_http_port" \
    --arg  openainano_port     "$openainano_port" \
    --arg  openainano_model    "$openainano_model" \
    --arg  reponano_port       "$reponano_port" \
    --arg  forgenano_port      "$forgenano_port" \
    --arg  forgenano_admin_key "$forgenano_admin_key" \
    --arg  forgenano_forge_token "$forgenano_forge_token" \
    --arg  forge_proxy          "$forge_proxy" \
    --arg  scanano_port        "$scanano_port" \
    --arg  scanano_token       "$scanano_token" \
    --argjson r10k_known_hosts "$r10k_known_hosts" \
    '{
      provider:              $provider,
      runtime:               $runtime,
      docker_host:           $docker_host,
      docker_host_static_ip: $docker_host_static_ip,
      docker_host_ip:        $docker_host_ip,
      nodeprefix:            $nodeprefix,
      adminpwd:              $adminpwd,
      instype:               $instype,
      region:                $region,
      zone:                  $zone,
      gcp_project:           $gcp_project,
      gcp_dns_suffix:        $gcp_dns_suffix,
      nodepooladdress:       $nodepooladdress,
      node_size:             $node_size,
      gcp_machine_type:      $gcp_machine_type,
      gcp_compiler_type:     $gcp_compiler_type,
      aws_instance_type:     $aws_instance_type,
      azure_vm_size:         $azure_vm_size,
      pe_version:            $pe_version,
      pe_tarball_path:       $pe_tarball_path,
      pe_platform:           $pe_platform,
      base_os:               $base_os,
      peadm_module_dir:      $peadm_module_dir,
      custom_image:          $custom_image,
      ssh_key_path:          $ssh_key_path,
      ssh_user:              $ssh_user,
      r10k_remote:           $r10k_remote,
      r10k_private_key_file: $r10k_private_key_file,
      enable_dr:             $enable_dr,
      del_now:               $del_now,
      aws_vpc_id:            $aws_vpc_id,
      aws_subnet_id:         $aws_subnet_id,
      aws_region:            $aws_region,
      azure_location:        $azure_location,
      azure_resource_group:  $azure_resource_group,
      suite_license_path:    $suite_license_path,
      docker_image:          $docker_image,
      docker_base:           $docker_base,
      docker_network:        $docker_network,
      docker_topology:       $docker_topology,
      use_gitnano:           $use_gitnano,
      use_openainano:        $use_openainano,
      use_reponano:          $use_reponano,
      use_forgenano:         $use_forgenano,
      use_scanano:           $use_scanano,
      full_offline:          $full_offline,
      gitnano_port:          $gitnano_port,
      hieranano_port:        $hieranano_port,
      hieranano_http_port:   $hieranano_http_port,
      openainano_port:       $openainano_port,
      openainano_model:      $openainano_model,
      reponano_port:         $reponano_port,
      forgenano_port:        $forgenano_port,
      forgenano_admin_key:   $forgenano_admin_key,
      forgenano_forge_token: $forgenano_forge_token,
      forge_proxy:          $forge_proxy,
      scanano_port:          $scanano_port,
      scanano_token:         $scanano_token,
      r10k_known_hosts:      $r10k_known_hosts
    }' > "$defaults_file"
  chmod 600 "$defaults_file"
  tui_ok "Settings saved to $(basename "$defaults_file")"
}

# ──────────────────────────────────────────────────────────────────────────────
# HOSTNAME BUILDER
# For GCP the full internal FQDN is: <prefix><role>.c.<project>.internal
# The DNS suffix (.c.<project>.internal) is confirmed with the user and saved.
# ──────────────────────────────────────────────────────────────────────────────
