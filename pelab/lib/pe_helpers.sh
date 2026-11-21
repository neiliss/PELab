# =============================================================================
# pe_helpers.sh  –  PE Lab "helpers": post-provisioning operations that assume
# the infrastructure and PE are ALREADY running and built.  Each helper asks
# the questions needed to build the correct inventory.yaml + params.json, then
# runs the relevant peadm plan.  No infrastructure is provisioned.
#
# Sourced by pelab.sh.  Do not run directly.
# =============================================================================

# ──────────────────────────────────────────────────────────────────────────────
# APPEND A RECORD OF A COMPLETED HELPER RUN TO helper.md
# Appends a timestamped section so the user has a persistent log of what each
# helper prepared / ran, alongside the access reference in helper.md.
# ──────────────────────────────────────────────────────────────────────────────
append_helper_md() {
  local title="$1"; shift
  local md="${script_dir}/helper.md"
  {
    echo ""
    echo "---"
    echo ""
    echo "## ${title}"
    echo ""
    echo "_$(date -u '+%Y-%m-%d %H:%M:%S UTC')_"
    echo ""
    echo '```'
    local _l
    for _l in "$@"; do printf '%s\n' "$_l"; done
    echo '```'
  } >> "$md"
  tui_ok "Recorded run in ${script_dir}/helper.md"
}

# ──────────────────────────────────────────────────────────────────────────────
# SAVED ENVIRONMENT CONTEXT
# Shows what was last set up / run (from the loaded $defaults_file) so the user
# knows the version, topology and connection details before picking a helper.
#   e.g. before an upgrade they can see which PE version was last saved/used.
# ──────────────────────────────────────────────────────────────────────────────
show_saved_context() {
  local _dc="$(basename "${defaults_file:-setup_wizard_defaults.json}")"
  tui_info "Last saved environment (from ${BOLD}${_dc}${RESET}):"
  tui_summary_open
  tui_summary_row "Node prefix" "${nodeprefix:-–}"
  tui_summary_row "Primary certname" "$(build_fqdn core0 2>/dev/null || echo –)"
  tui_summary_row "PE version"   "${pe_version:-–}"
  tui_summary_row "Provider"     "${provider:-–} · ${runtime:-–}"
  tui_summary_row "Sizing"       "${instype:-–}${node_size:+ (${node_size})}"
  tui_summary_row "Region"       "${region:-–}${zone:+ / ${zone}}"
  tui_summary_row "Project"      "${gcp_project:-–}"
  tui_summary_row "DR enabled"   "${enable_dr:-false}"
  tui_summary_row "SSH"          "${ssh_user:-root} @ ${ssh_key_path:-–}"
  tui_summary_close

  # Recent helper audit entries (title + timestamp) from helper.md.
  if [[ -f "${script_dir}/helper.md" ]]; then
    local _recent
    _recent=$(awk '/^## /{t=$0} /^_[0-9]{4}-/{print t"  ("$0")"}' "${script_dir}/helper.md" | tail -5)
    if [[ -n "$_recent" ]]; then
      tui_info "Most recent helper runs:"
      local _l
      while IFS= read -r _l; do tui_info "  ${_l}"; done <<< "$_recent"
      echo
    fi
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# HELPER MENU / DISPATCH
# ──────────────────────────────────────────────────────────────────────────────
run_helpers_menu() {
  tui_section "PE Lab Helpers"
  tui_info "These helpers operate on an ALREADY-BUILT PE environment."
  tui_info "No infrastructure is provisioned – they only build the inventory/"
  tui_info "params and run the relevant peadm plan against your existing nodes."
  echo
  show_saved_context
  echo
  tui_menu_default _helper_choice "Select a helper" 1 \
    "upgrade      – upgrade PE to a new version (peadm::upgrade)" \
    "add-compiler – add + provision compiler(s) to an existing cluster (peadm::add_compilers)" \
    "remove-compiler – remove a compiler (strip pe_compiler role + LB + revoke cert)" \
    "add-replica  – add/provision a DR primary replica (peadm::add_replica)" \
    "backup       – back up the primary (peadm::backup)" \
    "restore      – restore the primary from a backup (peadm::restore)" \
    "backup-ca    – back up the PE CA / certs (peadm::backup_ca)" \
    "restore-ca   – restore the PE CA / certs (peadm::restore_ca)" \
    "dr-test      – test DR: promote replica to primary, verify, fail back (peadm)" \
    "swing-migrate – build a parallel infra + swing traffic to it (provision→backup→restore)" \
    "swing-migrate-peadm – same as swing-migrate but via peadm::migrate (one plan)" \
    "openainano    – (re)install the PE AI ↔ Ollama bridge on the master" \
    "reponano      – (re)install the local apt/yum package repo on the master" \
    "forgenano     – (re)install the local Puppet Forge / module mirror on the master" \
    "scanano       – (re)install the CVE-enabled vuln scan bridge on the master" \
    "hieranano     – (re)install the Hiera/eyaml web UI on the master" \
    "ssh-keys      – print SSH-key requirements for the target nodes" \
    "hosts-sync    – push this env's /etc/hosts entries to other nodes"
  local _helper
  _helper=$(echo "$_helper_choice" | awk '{print $1}')
  echo
  case "$_helper" in
    upgrade)      helper_upgrade ;;
    add-compiler) helper_add_compiler ;;
    remove-compiler) helper_remove_compiler ;;
    add-replica)  helper_add_replica ;;
    backup)       helper_backup ;;
    restore)      helper_restore ;;
    backup-ca)    helper_backup_ca ;;
    restore-ca)   helper_restore_ca ;;
    dr-test)      helper_dr_test ;;
    swing-migrate) helper_swing_migrate ;;
    swing-migrate-peadm) helper_swing_migrate_peadm ;;
    openainano)    helper_openainano ;;
    reponano)      helper_reponano ;;
    forgenano)     helper_forgenano ;;
    scanano)       helper_scanano ;;
    hieranano)     helper_hieranano ;;
    ssh-keys)      helper_ssh_keys ;;
    hosts-sync)    helper_hosts_sync ;;
    *) tui_warn "Helper not yet implemented – nothing to do"; return 0 ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# PROVISION A SINGLE NEW COMPILER NODE
# Creates ONE new compiler node (docker container, or best-effort GCP VM) so
# peadm::add_compilers can then configure it.  Used by helper_add_compiler.
#   $1 = compiler hostname (certname, no port)
#   $2 = host SSH port (docker/cloud only; empty for VM)
# Depends on DOCKER_HOST_IP / DOCKER_NET / DOCKER_IMG and dh_ssh() being set up
# by the caller (helper_add_compiler) when runtime is docker/cloud.
# ──────────────────────────────────────────────────────────────────────────────
provision_compiler_node() {
  local cname="$1" port="$2"

  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    # ── Docker/cloud: create a container on the Docker host ────────────────
    tui_step "Provisioning compiler container ${cname} (host port ${port})…"
    dh_ssh "docker rm -f $cname >/dev/null 2>&1 || true"
    if ! dh_ssh "docker run -d --restart unless-stopped --name $cname --network $DOCKER_NET --privileged --cgroupns=host \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run:rw,exec --tmpfs /tmp:rw,exec \
        -p ${port}:22 --hostname $cname $DOCKER_IMG /sbin/init"; then
      tui_err "Failed to create container ${cname}"; return 1
    fi

    local pub_key_content; pub_key_content=$(cat "${ssh_key_path}.pub")
    for _ in $(seq 1 30); do
      dh_ssh "docker exec $cname true" >/dev/null 2>&1 && break
      sleep 2
    done
    tui_step "Configuring SSH on ${cname}…"
    dh_ssh "timeout 180 docker exec $cname bash -c \"apt-get update -qq && \
      apt-get install -y -qq nano openssh-server >/dev/null 2>&1 && \
      mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
      echo '${pub_key_content}' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && \
      sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
      rm -f /run/nologin /etc/nologin && \
      (service ssh start || systemctl start ssh || /usr/sbin/sshd)\"" >/dev/null 2>&1
    for _ in $(seq 1 30); do
      dh_ssh "docker exec $cname pgrep -x sshd" >/dev/null 2>&1 && break
      dh_ssh "docker exec $cname /usr/sbin/sshd" >/dev/null 2>&1 || true
      sleep 2
    done

    # Map hostname to the Docker-host IP on the wizard host (backup + narrow
    # removal so existing /etc/hosts entries are preserved).
    hosts_remove_name "$cname"
    hosts_add "$DOCKER_HOST_IP" "$cname"
    tui_ok "Provisioned ${cname} at ${cname}:${port}"
    return 0
  fi

  # ── VM/GCP: create an instance (best-effort) ─────────────────────────────
  tui_step "Provisioning GCP VM ${cname}…"
  if ! command -v gcloud >/dev/null 2>&1; then
    tui_warn "gcloud not available – create the VM ${cname} manually, then re-run."
    return 1
  fi
  local _zone="${full_zone:-${region}-${zone}}"
  if gcloud compute instances describe "$cname" --zone="$_zone" --project="$gcp_project" >/dev/null 2>&1; then
    tui_ok "VM ${cname} already exists"
    return 0
  fi
  if gcloud compute instances create "$cname" \
      --project="$gcp_project" --zone="$_zone" \
      --machine-type="$gcp_compiler_type" \
      --image="$custom_image" \
      --metadata="ssh-keys=${ssh_user}:$(cat "${ssh_key_path}.pub")" >/dev/null 2>&1; then
    tui_ok "Created GCP VM ${cname}"
    return 0
  fi
  tui_warn "gcloud create failed for ${cname} – create it manually, then re-run."
  return 1
}

# Return the next free host SSH port by inspecting the running containers on
# the Docker host (host ports are mapped 0.0.0.0:<host>:22).  Falls back to a
# topology-based guess if the host query fails.
_docker_next_port() {
  local _out
  _out=$(dh_ssh "docker ps --format '{{.Names}} {{.Ports}}'" 2>/dev/null || true)
  local _max=2200 _hp
  while IFS= read -r _hp; do
    if [[ "$_hp" =~ ^[0-9]+$ ]] && (( _hp > _max )); then _max=$_hp; fi
  done < <(printf '%s\n' "$_out" | grep -oE '0\.0\.0\.0:[0-9]+->22' | sed -E 's/.*:([0-9]+)->22/\1/')
  if (( _max <= 2200 )); then
    echo $((2201 + node_count + compiler_count + haproxy_count + 1))
  else
    echo $((_max + 1))
  fi
}

# Return the host port that maps to container $1's SSH (port 22).
# The container→port map is fetched ONCE per script invocation (cached) with a
# single fast-fail `docker ps` query, rather than a separate `ssh docker port`
# per node – that was one ~20s SSH round-trip after EVERY host prompt when the
# Docker host is slow or unreachable.  Each script run executes exactly one
# helper, so a module-level cache is naturally scoped to that single run.
_DOCKER_PORT_MAP=""
_DOCKER_PORT_MAP_LOADED="0"
_docker_port_cache() {
  # Optional 'force' arg re-queries the map even if already loaded (a first,
  # transient failure may have left the cache empty for a container we need).
  if [[ "$_DOCKER_PORT_MAP_LOADED" == "1" && "${1:-}" != "force" ]]; then return 0; fi
  _DOCKER_PORT_MAP_LOADED="1"
  # Fast-fail: BatchMode + short ConnectTimeout so an unreachable/slow Docker
  # host returns in ~4s once instead of hanging ~20s after every host prompt.
  _DOCKER_PORT_MAP=$(ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=4 \
    -o ConnectionAttempts=1 "${ssh_user}@${DOCKER_HOST_IP}" \
    "docker ps --format '{{.Names}} {{.Ports}}'" 2>/dev/null || true)
}

_docker_port_for() {
  local cname="$1" _p=""
  _docker_port_cache
  _p=$(printf '%s\n' "$_DOCKER_PORT_MAP" |
    awk -v n="$cname" '$1==n{ if (match($0,/0\.0\.0\.0:[0-9]+->22/)) { \
      s=substr($0,RSTART,RLENGTH); sub(/.*:/,"",s); sub(/->.*/,"",s); print s; exit } }')
  # If the cache was empty/missed (e.g. transient ssh timeout), re-query once.
  if [[ -z "$_p" ]]; then
    _docker_port_cache force
    _p=$(printf '%s\n' "$_DOCKER_PORT_MAP" |
      awk -v n="$cname" '$1==n{ if (match($0,/0\.0\.0\.0:[0-9]+->22/)) { \
        s=substr($0,RSTART,RLENGTH); sub(/.*:/,"",s); sub(/->.*/,"",s); print s; exit } }')
  fi
  # If still empty, DOCKER_HOST_IP may be stale (e.g. the swing now targets a NEW
  # Docker-host VM).  Re-resolve for the current node prefix and re-query so the
  # right host is always used.
  if [[ -z "$_p" ]]; then
    DOCKER_HOST_IP=""
    _resolve_docker_host_ip "${nodeprefix}"
    _DOCKER_PORT_MAP=""
    _DOCKER_PORT_MAP_LOADED="0"
    _docker_port_cache force
    _p=$(printf '%s\n' "$_DOCKER_PORT_MAP" |
      awk -v n="$cname" '$1==n{ if (match($0,/0\.0\.0\.0:[0-9]+->22/)) { \
        s=substr($0,RSTART,RLENGTH); sub(/.*:/,"",s); sub(/->.*/,"",s); print s; exit } }')
  fi
  echo "$_p"
}

# Ensure a docker/cloud target carries its mapped host port.  Accepts "host" or
# "host:port" and returns "host:port", so Bolt reaches the container rather than
# the Docker-host VM (which would otherwise lack the PE Ruby interpreter).
_docker_uri() {
  local h="$1" name; name=$(_hostname_only "$h")
  if [[ "$h" == *:* ]]; then
    echo "$h"
  else
    local p; p=$(_docker_port_for "$name")
    echo "${name}:${p}"
  fi
}

# Resolve the Docker-host IP for a given node prefix, in order:
#   1. /etc/hosts mapping for <prefix>core0
#   2. saved docker_host_ip from the defaults JSON (persisted at provision time)
#   3. terraform output dockerhost_ip from the active tf dir
# Only prompts if none of those resolve.  This means wiping /etc/hosts no longer
# forces an IP prompt as long as the docker host was provisioned & saved.
_resolve_docker_host_ip() {
  local prefix="$1"
  DOCKER_HOST_IP=$(awk -v h="${prefix}core0" '$2==h{print $1; exit}' /etc/hosts)
  if [[ -z "$DOCKER_HOST_IP" && -n "${docker_host_ip:-}" ]]; then
    DOCKER_HOST_IP="$docker_host_ip"
  fi
  if [[ -z "$DOCKER_HOST_IP" && -n "${tf_dir_active:-}" ]]; then
    DOCKER_HOST_IP=$(cd "$tf_dir_active" 2>/dev/null && terraform output -raw dockerhost_ip 2>/dev/null) || true
  fi
  if [[ -z "$DOCKER_HOST_IP" ]]; then
    tui_prompt DOCKER_HOST_IP "Docker host IP" ""
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# ──────────────────────────────────────────────────────────────────────────────
# SERVE A LOCAL PE INSTALLER TARBALL OVER HTTP
# peadm::upgrade's download task runs `curl` on the TARGETS, so a local tarball
# on the Bolt host must be reachable over HTTP.  This starts a background HTTP
# server in the tarball's directory and prints the URL to use as
# pe_installer_source.  (Targets – VMs or docker containers – reach the Bolt
# host via its primary IP.)
# ──────────────────────────────────────────────────────────────────────────────
_serve_installer_tarball() {
  local _tarball="$1"
  if [[ ! -f "$_tarball" ]]; then
    tui_err "Installer tarball not found: $_tarball"; return 1
  fi
  local _dir _name _port _host _url
  _dir=$(dirname "$_tarball")
  _name=$(basename "$_tarball")
  _port="${PE_INSTALLER_PORT:-8000}"
  _host=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ -z "$_host" ]] && _host="127.0.0.1"
  _installer_server_port="$_port"
  if command -v python3 >/dev/null 2>&1; then
    if command -v setsid >/dev/null 2>&1; then
      ( cd "$_dir" && setsid nohup python3 -m http.server "$_port" >/dev/null 2>&1 & )
    else
      ( cd "$_dir" && nohup python3 -m http.server "$_port" >/dev/null 2>&1 & )
    fi
  elif command -v busybox >/dev/null 2>&1; then
    ( cd "$_dir" && nohup busybox httpd -f -p "$_port" >/dev/null 2>&1 & )
  else
    tui_err "No HTTP server available (python3 or busybox) to serve the tarball"; return 1
  fi
  sleep 1
  _url="http://${_host}:${_port}/${_name}"
  # Range-request the first byte only (fast) to confirm the server is up.
  if ! curl -s -o /dev/null --max-time 5 -r 0-0 "$_url"; then
    tui_err "Could not reach the installer server at ${_url}"; return 1
  fi
  _installer_source_url="$_url"
  tui_ok "Serving installer at ${_url}"
  return 0
}

# Stop the background installer HTTP server started by _serve_installer_tarball.
_stop_installer_server() {
  local _port="${_installer_server_port:-}"
  [[ -z "$_port" ]] && return 0
  # [p] character-class trick so the pattern never matches this shell's own cmdline.
  pkill -f "http.serve[r] ${_port}" 2>/dev/null || true
  pkill -f "busybox http[d] -f -p ${_port}" 2>/dev/null || true
  _installer_server_port=""
}

# UPGRADE HELPER  (peadm::upgrade)
# Asks the questions needed to build params.json + inventory.yaml for a
# peadm::upgrade run against an existing PE deployment, then runs the plan.
# ──────────────────────────────────────────────────────────────────────────────
helper_upgrade() {
  tui_section "PE Upgrade Helper (peadm::upgrade)"
  tui_info "Upgrades an existing PE deployment to a new version.  Assumes the"
  tui_info "infrastructure and PE are already running and built."
  echo
  # Always surface what was last saved/provisioned (version, prefix, hosts)
  # so the user knows the current baseline even when invoked via CLI.
  show_saved_context
  echo

  # SSH key is needed for the inventory (Bolt connects with it).
  configure_ssh_key

  # ── 1. Target version / installer source ─────────────────────────────────
  # Optionally point at a specific (possibly new/unsupported) installer tarball
  # or URL instead of the standard version-based download.
  tui_confirm _use_src "Use a specific PE installer tarball/URL (new/unsupported build)?" "N"
  upgrade_installer_source=""
  if [[ "$_use_src" == "true" ]]; then
    tui_prompt upgrade_installer_source "Installer source (local path or http(s) URL)" \
      "${upgrade_installer_source:-}"
    if [[ -z "$upgrade_installer_source" ]]; then
      tui_err "An installer source is required"; return 1
    fi
    if [[ "$upgrade_installer_source" != http* ]]; then
      _serve_installer_tarball "$upgrade_installer_source" || return 1
      upgrade_installer_source="$_installer_source_url"
    fi
    # Derive the target version from the tarball name (peadm does the same).
    upgrade_version=$(basename "$upgrade_installer_source" | sed -E 's/^puppet-enterprise-([0-9.]+)-.*/\1/')
    upgrade_permit_unsafe="true"
  else
    tui_prompt upgrade_version "Target PE version" "${upgrade_version:-}"
    if [[ -z "$upgrade_version" ]]; then
      tui_err "A target PE version is required (e.g. 2025.11.0)"
      return 1
    fi
  fi
  echo

  # ── 2. Architecture ───────────────────────────────────────────────────────
  # Pre-select based on saved instype + enable_dr.
  local _arch_default=1
  case "${instype}-${enable_dr}" in
    LARGE-false) _arch_default=2 ;;
    XL-false)    _arch_default=3 ;;
    LARGE-true)  _arch_default=4 ;;
    XL-true)     _arch_default=5 ;;
  esac
  tui_menu_default _arch_raw "Architecture" "$_arch_default" \
    "standard  – primary only" \
    "large     – primary + compilers + HAProxy" \
    "xl        – primary + PDB + compilers + HAProxy" \
    "large-ha  – primary + replica + compilers + HAProxy" \
    "xl-ha     – primary + replica + PDB + compilers + HAProxy"
  upgrade_arch=$(echo "$_arch_raw" | awk '{print $1}')
  echo
  tui_ok "Architecture: ${BOLD}${upgrade_arch}${RESET}"

  # Map architecture → instype/enable_dr so build_fqdn / docker_roles work.
  case "$upgrade_arch" in
    standard) instype="STANDARD"; enable_dr="false" ;;
    large)    instype="LARGE";    enable_dr="false" ;;
    xl)       instype="XL";       enable_dr="false" ;;
    large-ha) instype="LARGE";    enable_dr="true" ;;
    xl-ha)    instype="XL";       enable_dr="true" ;;
  esac

  # ── 3. Hosts ─────────────────────────────────────────────────────────────
  upgrade_hosts=()
  upgrade_compiler_hosts=()

  # Docker/cloud: connect to the Docker host so we can resolve each node's
  # mapped host port (otherwise Bolt hits the Docker-host VM, not the container).
  local _is_docker="no"
  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    _is_docker="yes"
    _resolve_docker_host_ip "${nodeprefix}"
    if [[ -z "$DOCKER_HOST_IP" ]]; then
      tui_err "Docker host IP is required"; return 1
    fi
    dh_ssh() {
      ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=20 "${ssh_user}@${DOCKER_HOST_IP}" "$@"
    }
  fi

  # Resolve a prompted host to its docker URI (host:port) when applicable.
  local _dh_host
  _dh_host=$(build_fqdn core0)
  [[ "$_is_docker" == "yes" ]] && _dh_host=$(_docker_uri "$_dh_host")
  tui_prompt primary_host "Primary host" "$_dh_host"
  [[ "$_is_docker" == "yes" ]] && primary_host=$(_docker_uri "$primary_host")
  upgrade_hosts+=("$primary_host")

  if [[ "$upgrade_arch" == "xl" || "$upgrade_arch" == "xl-ha" ]]; then
    _dh_host=$(build_fqdn core1)
    [[ "$_is_docker" == "yes" ]] && _dh_host=$(_docker_uri "$_dh_host")
    tui_prompt primary_postgresql_host "Primary PDB host" "$_dh_host"
    [[ "$_is_docker" == "yes" ]] && primary_postgresql_host=$(_docker_uri "$primary_postgresql_host")
    upgrade_hosts+=("$primary_postgresql_host")
  fi

  if [[ "$upgrade_arch" == "large-ha" || "$upgrade_arch" == "xl-ha" ]]; then
    # For xl-ha the replica is a distinct node (primary=core0, PDB=core1,
    # replica=core2, replica PDB=core3).  For large-ha there is no external
    # PDB, so the replica is core1.
    _dh_host=$(build_fqdn core1)
    [[ "$upgrade_arch" == "xl-ha" ]] && _dh_host=$(build_fqdn core2)
    [[ "$_is_docker" == "yes" ]] && _dh_host=$(_docker_uri "$_dh_host")
    tui_prompt replica_host "Replica host" "$_dh_host"
    [[ "$_is_docker" == "yes" ]] && replica_host=$(_docker_uri "$replica_host")
    upgrade_hosts+=("$replica_host")
    if [[ "$upgrade_arch" == "xl-ha" ]]; then
      _dh_host=$(build_fqdn core3)
      [[ "$_is_docker" == "yes" ]] && _dh_host=$(_docker_uri "$_dh_host")
      tui_prompt replica_postgresql_host "Replica PDB host" "$_dh_host"
      [[ "$_is_docker" == "yes" ]] && replica_postgresql_host=$(_docker_uri "$replica_postgresql_host")
      upgrade_hosts+=("$replica_postgresql_host")
    fi
  fi

  if [[ "$upgrade_arch" == "large" || "$upgrade_arch" == "xl" \
        || "$upgrade_arch" == "large-ha" || "$upgrade_arch" == "xl-ha" ]]; then
    local _ncomp="${upgrade_compiler_count:-2}"
    tui_prompt _ncomp "Number of compilers" "$_ncomp"
    upgrade_compiler_count="$_ncomp"
    local _i
    for _i in $(seq 0 $((upgrade_compiler_count-1))); do
      local _ch
      _dh_host=$(build_fqdn "compiler${_i}")
      [[ "$_is_docker" == "yes" ]] && _dh_host=$(_docker_uri "$_dh_host")
      tui_prompt _ch "Compiler ${_i} host" "$_dh_host"
      [[ "$_is_docker" == "yes" ]] && _ch=$(_docker_uri "$_ch")
      upgrade_compiler_hosts+=("$_ch")
      upgrade_hosts+=("$_ch")
    done
    # The compiler pool address is a HOSTNAME (PE appends :8140 when it builds
    # the agent/puppet-server URL).  Using the docker uri (host:<ssh-port>) here
    # would produce a broken "https://host:2204:8140" that crashes pe-ace-server,
    # so keep the pool address as the bare FQDN.
    _dh_host=$(build_fqdn haproxy)
    tui_prompt compiler_pool_address "Compiler pool address" \
      "${compiler_pool_address:-$_dh_host}"
  fi
  echo

  # ── 4. r10k known hosts (required for 2023.4+ upgrades) ──────────────────
  tui_prompt _r10k_kh "R10K known-hosts JSON" "${r10k_known_hosts:-[]}"
  if [[ -n "$_r10k_kh" ]]; then
    if echo "$_r10k_kh" | jq empty >/dev/null 2>&1; then
      upgrade_r10k_known_hosts="$_r10k_kh"
    else
      upgrade_r10k_known_hosts="[$_r10k_kh]"
    fi
  else
    upgrade_r10k_known_hosts="[]"
  fi

  # ── 5. RBAC token (needed when compilers are present) ─────────────────────
  if [[ ${#upgrade_compiler_hosts[@]} -gt 0 ]]; then
    tui_prompt token_file "RBAC token file" "${token_file:-/root/.puppetlabs/token}"
  fi

  # ── 6. Download / staging options ────────────────────────────────────────
  tui_menu_default _dm "Download mode" 1 \
    "bolthost – download to Bolt host, then upload to targets" \
    "direct   – download directly on each target"
  upgrade_download_mode=$(echo "$_dm" | awk '{print $1}')

  tui_prompt upgrade_stagingdir "Staging dir (Bolt host)" "${upgrade_stagingdir:-/tmp}"
  tui_prompt upgrade_uploaddir  "Upload dir (targets)"     "${upgrade_uploaddir:-/tmp}"

  tui_menu_default _fas "Final agent state" 1 \
    "running – start puppet agent after upgrade" \
    "stopped – leave puppet agent stopped"
  upgrade_final_agent_state=$(echo "$_fas" | awk '{print $1}')

  # LAB BUILD: always permit any PE version - never ask, never block.
  # (Version gating is also disabled in the vendored peadm itself.)
  upgrade_permit_unsafe="true"
  tui_prompt begin_at_step "Begin at step (resume; empty = start)" "${begin_at_step:-}"
  echo

  # ── 7. Build artefacts ─────────────────────────────────────────────────────
  build_upgrade_params
  build_upgrade_inventory

  # ── 8. Summary ───────────────────────────────────────────────────────────
  tui_section "Upgrade Summary"
  tui_summary_open
  tui_summary_row "Target version" "$upgrade_version"
  [[ -n "${upgrade_installer_source:-}" ]] && tui_summary_row "Installer src" "$upgrade_installer_source"
  tui_summary_row "Architecture"   "$upgrade_arch"
  tui_summary_row "Primary"        "$primary_host"
  [[ -n "${primary_postgresql_host:-}" ]] && tui_summary_row "Primary PDB" "$primary_postgresql_host"
  [[ -n "${replica_host:-}" ]] && tui_summary_row "Replica" "$replica_host"
  [[ -n "${replica_postgresql_host:-}" ]] && tui_summary_row "Replica PDB" "$replica_postgresql_host"
  if [[ ${#upgrade_compiler_hosts[@]} -gt 0 ]]; then
    tui_summary_row "Compilers" "$(IFS=,; echo "${upgrade_compiler_hosts[*]}")"
    tui_summary_row "Pool addr" "${compiler_pool_address:-}"
  fi
  tui_summary_row "Download"     "$upgrade_download_mode"
  tui_summary_row "Agent state"  "$upgrade_final_agent_state"
  tui_summary_close

  # ── 8b. Record run in helper.md ─────────────────────────────────────────
  append_helper_md "PE Upgrade (peadm::upgrade)" \
    "Bolt:   ${BOLT} plan run peadm::upgrade --params @${PARAMS_FILE} $(bolt_inv)" \
    "Version:  ${upgrade_version}" \
    "Installer: ${upgrade_installer_source:-standard download}" \
    "Arch:     ${upgrade_arch}" \
    "Primary:  ${primary_host}" \
    "Compilers: $(IFS=,; echo "${upgrade_compiler_hosts[*]}")"
  tui_blank
  tui_info "For access details and a record of this run, see ${script_dir}/helper.md"

  # ── 9. Run ───────────────────────────────────────────────────────────────
  tui_confirm _run_upgrade "Run peadm::upgrade now?" "Y"
  if [[ "$_run_upgrade" != "true" ]]; then
    tui_info "params.json and inventory.yaml are ready.  Run manually with:"
    printf '%s\n' \
      "${BOLT} plan run peadm::upgrade --params @${PARAMS_FILE} $(bolt_inv)" \
      | tui_hint_box
    if [[ -n "${_installer_server_port:-}" ]]; then
      tui_info "Installer HTTP server is still running on port ${_installer_server_port}."
      tui_info "Stop it after the manual run with: pkill -f 'http.server ${_installer_server_port}'"
    fi
    return 0
  fi

  tui_section "Running peadm::upgrade"
  ${BOLT} plan run peadm::upgrade --params "@${PARAMS_FILE}" $(bolt_inv)
  local _status=$?
  _stop_installer_server
  if [[ $_status -ne 0 ]]; then
    tui_err "peadm::upgrade failed (exit $_status)"; return $_status
  fi
  tui_ok "peadm::upgrade completed"
}

# ──────────────────────────────────────────────────────────────────────────────
# BUILD PARAMS.JSON for peadm::upgrade
# ──────────────────────────────────────────────────────────────────────────────
build_upgrade_params() {
  local params_file="${script_dir}/params.json"

  local compiler_hosts_json="[]"
  if [[ ${#upgrade_compiler_hosts[@]} -gt 0 ]]; then
    # Strip any :port so params use certnames; the inventory keeps the URIs.
    local _chosts=() _ch
    for _ch in "${upgrade_compiler_hosts[@]}"; do _chosts+=("$(_hostname_only "$_ch")"); done
    compiler_hosts_json=$(printf '%s\n' "${_chosts[@]}" | jq -R . | jq -s .)
  fi

  local r10k_json="[]"
  [[ -n "${upgrade_r10k_known_hosts:-}" ]] && r10k_json="$upgrade_r10k_known_hosts"

  jq -n \
    --arg version "$upgrade_version" \
    --arg pe_installer_source "${upgrade_installer_source:-}" \
    --arg primary_host "$(_hostname_only "$primary_host")" \
    --arg primary_postgresql_host "$(_hostname_only "${primary_postgresql_host:-}")" \
    --arg replica_host "$(_hostname_only "${replica_host:-}")" \
    --arg replica_postgresql_host "$(_hostname_only "${replica_postgresql_host:-}")" \
    --argjson compiler_hosts "$compiler_hosts_json" \
    --argjson r10k_known_hosts "$r10k_json" \
    --arg compiler_pool_address "${compiler_pool_address:-}" \
    --arg token_file "${token_file:-}" \
    --arg stagingdir "${upgrade_stagingdir:-/tmp}" \
    --arg uploaddir "${upgrade_uploaddir:-/tmp}" \
    --arg final_agent_state "${upgrade_final_agent_state:-running}" \
    --arg download_mode "${upgrade_download_mode:-bolthost}" \
    --arg begin_at_step "${begin_at_step:-}" \
    --argjson permit_unsafe_versions "${upgrade_permit_unsafe:-true}" \
    '{
      version: $version,
      primary_host: $primary_host,
      compiler_hosts: $compiler_hosts,
      r10k_known_hosts: $r10k_known_hosts,
      stagingdir: $stagingdir,
      uploaddir: $uploaddir,
      final_agent_state: $final_agent_state,
      download_mode: $download_mode,
      permit_unsafe_versions: $permit_unsafe_versions
    }
    + (if $pe_installer_source != "" then { pe_installer_source: $pe_installer_source } else {} end)
    + (if $primary_postgresql_host != "" then { primary_postgresql_host: $primary_postgresql_host } else {} end)
    + (if $replica_host != "" then { replica_host: $replica_host } else {} end)
    + (if $replica_postgresql_host != "" then { replica_postgresql_host: $replica_postgresql_host } else {} end)
    + (if $compiler_pool_address != "" then { compiler_pool_address: $compiler_pool_address } else {} end)
    + (if $token_file != "" then { token_file: $token_file } else {} end)
    + (if $begin_at_step != "" then { begin_at_step: $begin_at_step } else {} end)' \
    > "$params_file"

  PARAMS_FILE="$params_file"
  tui_ok "params.json written for peadm::upgrade"
}

# ──────────────────────────────────────────────────────────────────────────────
# BUILD INVENTORY.YAML for peadm::upgrade
# ──────────────────────────────────────────────────────────────────────────────
build_upgrade_inventory() {
  local inv="${script_dir}/inventory.yaml"
  _inventory_hosts_valid "${upgrade_hosts[@]}" || return 1
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

  # peadm connects to targets by certname (no port).  Name each target with the
  # certname and set uri to the actual host:port so Bolt applies the group config
  # (host-key-check: false) and reaches the docker container's mapped port.
  local _h _nm
  for _h in "${upgrade_hosts[@]}"; do
    _nm=$(_hostname_only "$_h")
    echo "      - name: ${_nm}" >> "$inv"
    echo "        uri: ${_h}" >> "$inv"
  done

  tui_ok "inventory.yaml written for peadm::upgrade"
  tui_blank
  tui_info "Targets in inventory:"
  grep '      - ' "$inv" | while read -r _line; do
    tui_info "  $_line"
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# ADD-COMPILER HELPER  (peadm::add_compilers)
# Asks the questions, provisions the new compiler node(s) (docker containers or
# best-effort VMs), then runs peadm::add_compilers to configure them.
# ──────────────────────────────────────────────────────────────────────────────
helper_add_compiler() {
  tui_section "Add Compiler Helper (peadm::add_compilers)"
  if [[ "$instype" == "STANDARD" ]]; then
    tui_err "Adding compilers is not supported for a STANDARD topology (single-node)."
    tui_info "Use LARGE or XL if you need compilers."
    return 1
  fi
  tui_info "Adds new compilers to an existing PE cluster.  The helper first"
  tui_info "provisions the new node(s) (docker containers or VMs), then configures"
  tui_info "them with peadm::add_compilers – all in one go."
  echo

  configure_ssh_key

  # ── 0. Docker/cloud: set up connection to the Docker host ───────────────
  local _is_docker="no"
  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    _is_docker="yes"
    _resolve_docker_host_ip "${nodeprefix}"
    if [[ -z "$DOCKER_HOST_IP" ]]; then
      tui_err "Docker host IP is required"; return 1
    fi
    DOCKER_NET="${docker_network:-${nodeprefix}net}"
    DOCKER_IMG="${docker_image:-${docker_default_tag}}"
    dh_ssh() {
      ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=20 "${ssh_user}@${DOCKER_HOST_IP}" "$@"
    }
  fi

  # ── 1. Compiler hosts (required) ──────────────────────────────────────────
  local _ncomp="${ac_compiler_count:-1}"
  tui_prompt _ncomp "Number of new compilers" "$_ncomp"
  ac_compiler_count="$_ncomp"

  # ── 2. Primary host (required) ────────────────────────────────────────────
  # For docker/cloud the primary is a container, so include its mapped host port
  # (e.g. core0:2201) – otherwise Bolt hits the Docker-host VM instead.
  local _primary_default; _primary_default=$(build_fqdn core0)
  if [[ "$_is_docker" == "yes" ]]; then
    _primary_default="$(_docker_uri "$_primary_default")"
  fi
  tui_prompt primary_host "Primary host" "$_primary_default"
  if [[ "$_is_docker" == "yes" ]]; then
    primary_host="$(_docker_uri "$primary_host")"
  fi

  ac_compiler_hosts=()
  # Determine the next free compiler index so a new compiler doesn't collide
  # with existing ones.  E.g. a LARGE build already has compiler0/1, so the next
  # new compiler should default to compiler2, not overwrite compiler0.
  local _next=0 _maxidx="" _i _ch _cname
  if [[ "$_is_docker" == "yes" ]]; then
    _maxidx=$(dh_ssh "docker ps --format '{{.Names}}'" 2>/dev/null \
      | grep -E "^${nodeprefix}compiler[0-9]+$" 2>/dev/null \
      | sed -E "s/^.*compiler([0-9]+)\$/\1/" | sort -n | tail -1)
  else
    # VM: derive from the configured topology (e.g. LARGE has compiler_count=2).
    [[ "${compiler_count:-0}" -gt 0 ]] && _maxidx=$((compiler_count-1))
  fi
  [[ "$_maxidx" =~ ^[0-9]+$ ]] && _next=$((_maxidx+1))
  tui_info "Existing compilers up to index ${_maxidx:-0} – new compiler(s) will be numbered from ${_next}"

  for _i in $(seq 0 $((ac_compiler_count-1))); do
    tui_prompt _ch "Compiler $((_next+_i)) host" "$(build_fqdn "compiler$((_next+_i))")"
    _cname=$(_hostname_only "$_ch")
    if [[ "$_is_docker" == "yes" ]]; then
      local _port; _port=$(_docker_next_port)
      if ! provision_compiler_node "$_cname" "$_port"; then
        tui_err "Aborting – failed to provision ${_cname}"; return 1
      fi
      ac_compiler_hosts+=("${_cname}:${_port}")
    else
      if ! provision_compiler_node "$_cname" ""; then
        tui_err "Aborting – could not provision ${_cname}"; return 1
      fi
      ac_compiler_hosts+=("$_cname")
    fi
  done
  echo

  # ── 3. Availability group (optional, default A) ───────────────────────────
  local _avail_default=1; [[ "${ac_avail_group:-A}" == "B" ]] && _avail_default=2
  tui_menu_default _avail "Availability group" "$_avail_default" \
    "A – assign to primary group (default)" \
    "B – assign to replica group"
  ac_avail_group=$(echo "$_avail" | awk '{print $1}')
  echo
  tui_ok "Availability group: ${BOLD}${ac_avail_group}${RESET}"

  # ── 4. Build artefacts ─────────────────────────────────────────────────────
  build_add_compiler_params
  build_add_compiler_inventory

  # ── 5. Pre-flight reachability check ──────────────────────────────────────
  # Catches unreachable nodes (e.g. a compiler that was never provisioned)
  # BEFORE the plan starts, instead of mid-run like the earlier failure.
  tui_section "Pre-flight connectivity check"
  local _all_ok="yes" _target _tname
  for _target in "$primary_host" "${ac_compiler_hosts[@]}"; do
    _tname=$(_hostname_only "$_target")
    tui_info "Checking ${_tname} …"
    if ${BOLT} command run "echo ok" --targets "$_tname" $(bolt_inv) >/dev/null 2>&1; then
      tui_ok "reachable: ${_tname}"
    else
      tui_err "NOT reachable: ${_tname}  (provision it first, then re-run)"
      _all_ok="no"
    fi
  done
  if [[ "$_all_ok" == "no" ]]; then
    tui_err "Aborting – make every node reachable, then re-run the helper."
    return 1
  fi
  echo

  # ── 6. Summary ───────────────────────────────────────────────────────────
  tui_section "Add Compiler Summary"
  tui_summary_open
  tui_summary_row "Primary"     "$primary_host"
  tui_summary_row "Compilers"   "$(IFS=,; echo "${ac_compiler_hosts[*]}")"
  tui_summary_row "Avail group" "$ac_avail_group"
  tui_summary_close

  # ── 6b. Record run in helper.md ─────────────────────────────────────────
  append_helper_md "Add Compiler (peadm::add_compilers)" \
    "Bolt:   ${BOLT} plan run peadm::add_compilers --params @${PARAMS_FILE} $(bolt_inv)" \
    "Primary:  ${primary_host}" \
    "Compilers: $(IFS=,; echo "${ac_compiler_hosts[*]}")" \
    "Avail group: ${ac_avail_group}"
  tui_blank
  tui_info "For access details and a record of this run, see ${script_dir}/helper.md"

  # ── 7. Run ───────────────────────────────────────────────────────────────
  tui_confirm _run_addc "Run peadm::add_compilers now?" "Y"
  if [[ "$_run_addc" != "true" ]]; then
    tui_info "params.json and inventory.yaml are ready.  Run manually with:"
    printf '%s\n' \
      "${BOLT} plan run peadm::add_compilers --params @${PARAMS_FILE} $(bolt_inv)" \
      | tui_hint_box
    return 0
  fi

  tui_section "Running peadm::add_compilers"
  # --no-host-key-check: the new compiler is a fresh container/VM whose host key
  # is unknown, so force Bolt to skip host-key verification for the whole plan.
  ${BOLT} plan run peadm::add_compilers --params "@${PARAMS_FILE}" --no-host-key-check $(bolt_inv)
  local _status=$?
  if [[ $_status -ne 0 ]]; then
    tui_err "peadm::add_compilers failed (exit $_status)"; return $_status
  fi
  tui_ok "peadm::add_compilers completed"

  # Reconfigure HAProxy so the new compiler(s) join the round-robin backend.
  # configure_haproxy expects bare hostnames (not docker URIs) and a compiler_count
  # that reflects the new total (existing + newly added).
  local _hp_primary="$primary_host"
  primary_host="$(_hostname_only "$primary_host")"
  compiler_count=$(( ${compiler_count:-0} + ac_compiler_count ))
  configure_haproxy
  primary_host="$_hp_primary"
}

# Strip a ":port" suffix from a target spec, returning the certname.  The
# plan's params need the certname (no port); the inventory needs the connection
# URI (which may include a port).
_hostname_only() { echo "${1%%:*}"; }

# ──────────────────────────────────────────────────────────────────────────────
# BUILD PARAMS.JSON for peadm::add_compilers
# ──────────────────────────────────────────────────────────────────────────────
build_add_compiler_params() {
  local params_file="${script_dir}/params.json"

  # compiler_hosts is a string for a single compiler, an array for multiples.
  local _hosts=() _h
  for _h in "${ac_compiler_hosts[@]}"; do _hosts+=("$(_hostname_only "$_h")"); done

  local compiler_hosts_json
  if [[ ${#_hosts[@]} -eq 1 ]]; then
    compiler_hosts_json=$(jq -n --arg h "${_hosts[0]}" '$h')
  else
    compiler_hosts_json=$(printf '%s\n' "${_hosts[@]}" | jq -R . | jq -s .)
  fi

  jq -n \
    --arg primary_host "$(_hostname_only "$primary_host")" \
    --arg avail_group_letter "$ac_avail_group" \
    --argjson compiler_hosts "$compiler_hosts_json" \
    '{
      avail_group_letter: $avail_group_letter,
      compiler_hosts: $compiler_hosts,
      primary_host: $primary_host
    }' > "$params_file"

  PARAMS_FILE="$params_file"
  tui_ok "params.json written for peadm::add_compilers"
}

# ──────────────────────────────────────────────────────────────────────────────
# BUILD INVENTORY.YAML for peadm::add_compilers
# Uses the node names/URIs exactly as the user provided – the connection model
# (docker vs vm, /etc/hosts, DNS, ports) is the user's concern, not this helper.
# ──────────────────────────────────────────────────────────────────────────────
build_add_compiler_inventory() {
  local inv="${script_dir}/inventory.yaml"

  local hosts=("$primary_host")
  hosts+=("${ac_compiler_hosts[@]}")

  # peadm also stops the PE agent on the DR replica (if any) when reconfiguring.
  # It connects to targets by certname, so the replica must be in this inventory
  # with its docker uri (host:port); otherwise Bolt reaches the Docker-host VM
  # (port 22, no puppet) and "systemctl stop puppet.service" fails there.
  if [[ "$_is_docker" == "yes" ]]; then
    local _rep
    for _rep in $(dh_ssh "docker ps --format '{{.Names}}'" 2>/dev/null \
        | grep -E "^${nodeprefix}core[0-9]+$" | grep -v "^${nodeprefix}core0$"); do
      hosts+=("$(_docker_uri "$_rep")")
    done
  fi


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

  local _h _nm
  for _h in "${hosts[@]}"; do
    # peadm connects to targets by certname (no port), so the target must be
    # named with the certname while the uri carries the actual host:port.  This
    # lets Bolt apply the group config (host-key-check: false) and reach the
    # docker container (mapped port) instead of the Docker-host VM.
    _nm=$(_hostname_only "$_h")
    echo "      - name: ${_nm}" >> "$inv"
    echo "        uri: ${_h}" >> "$inv"
  done

  tui_ok "inventory.yaml written for peadm::add_compilers"
  tui_blank
  tui_info "Targets in inventory:"
  grep '      - ' "$inv" | while read -r _line; do
    tui_info "  $_line"
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# ADD-REPLICA HELPER  (peadm::add_replica)
# Adds DR to an existing PE cluster by provisioning a new primary replica node
# (docker container or best-effort VM), then runs peadm::add_replica to install
# the agent and configure it as a replica.  Mirrors helper_add_compiler.
# ──────────────────────────────────────────────────────────────────────────────
helper_add_replica() {
  tui_section "Add Replica Helper (peadm::add_replica)"
  if [[ "$instype" == "STANDARD" ]]; then
    tui_err "Adding a DR replica is not supported for a STANDARD topology (single-node)."
    tui_info "Use LARGE or XL if you need a replica."
    return 1
  fi
  tui_info "Sets up DR by adding a primary replica.  The helper first provisions"
  tui_info "the new replica node (docker container or VM), then configures it with"
  tui_info "peadm::add_replica – all in one go."
  tui_warn "Code Manager MUST be enabled on the primary, or the plan will fail."
  echo

  configure_ssh_key

  # ── 0. Docker/cloud: set up connection to the Docker host ───────────────
  local _is_docker="no"
  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    _is_docker="yes"
    _resolve_docker_host_ip "${nodeprefix}"
    if [[ -z "$DOCKER_HOST_IP" ]]; then
      tui_err "Docker host IP is required"; return 1
    fi
    DOCKER_NET="${docker_network:-${nodeprefix}net}"
    DOCKER_IMG="${docker_image:-${docker_default_tag}}"
    dh_ssh() {
      ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=20 "${ssh_user}@${DOCKER_HOST_IP}" "$@"
    }
  fi

  # ── 1. Primary host (required) ────────────────────────────────────────────
  local _primary_default; _primary_default=$(build_fqdn core0)
  if [[ "$_is_docker" == "yes" ]]; then
    _primary_default="$(_docker_uri "$_primary_default")"
  fi
  tui_prompt primary_host "Primary host" "$_primary_default"
  if [[ "$_is_docker" == "yes" ]]; then
    primary_host="$(_docker_uri "$primary_host")"
  fi

  # ── 2. Replica host (required, the node to provision) ─────────────────────
  local _replica_default; _replica_default=$(build_fqdn core1)
  if [[ "$_is_docker" == "yes" ]]; then
    _replica_default="$(_docker_uri "$_replica_default")"
  fi
  tui_prompt replica_host "Replica host" "$_replica_default"
  local _rep_cname; _rep_cname=$(_hostname_only "$replica_host")

  if [[ "$_is_docker" == "yes" ]]; then
    local _port; _port=$(_docker_next_port)
    if ! provision_compiler_node "$_rep_cname" "$_port"; then
      tui_err "Aborting – failed to provision replica ${_rep_cname}"; return 1
    fi
    replica_host="${_rep_cname}:${_port}"
  else
    if ! provision_compiler_node "$_rep_cname" ""; then
      tui_err "Aborting – could not provision replica ${_rep_cname}"; return 1
    fi
    replica_host="$_rep_cname"
  fi
  echo

  # ── 3. Replica PDB host (XL only; optional) ───────────────────────────────
  # For an Extra Large infrastructure with an external DB, a replica of the DB
  # is also needed.  Assumed already provisioned (not created by this helper).
  local _rpdb_default=""
  if [[ "$instype" == "XL" && -n "${replica_postgresql_host:-}" ]]; then
    _rpdb_default="$replica_postgresql_host"
  fi
  tui_prompt replica_postgresql_host "Replica PDB host (XL only; empty to skip)" "$_rpdb_default"

  # ── 4. RBAC token (optional) ──────────────────────────────────────────────
  local _token_default="${replica_token_file:-}"
  tui_prompt replica_token_file "RBAC token file (optional)" "$_token_default"

  # ── 5. Build artefacts ─────────────────────────────────────────────────────
  build_add_replica_params
  build_add_replica_inventory

  # ── 6. Pre-flight reachability check ──────────────────────────────────────
  tui_section "Pre-flight connectivity check"
  local _hosts=("$primary_host" "$replica_host")
  [[ -n "$replica_postgresql_host" ]] && _hosts+=("$replica_postgresql_host")
  local _all_ok="yes" _target _tname
  for _target in "${_hosts[@]}"; do
    _tname=$(_hostname_only "$_target")
    tui_info "Checking ${_tname} …"
    if ${BOLT} command run "echo ok" --targets "$_tname" $(bolt_inv) >/dev/null 2>&1; then
      tui_ok "reachable: ${_tname}"
    else
      tui_err "NOT reachable: ${_tname}  (provision it first, then re-run)"
      _all_ok="no"
    fi
  done
  if [[ "$_all_ok" == "no" ]]; then
    tui_err "Aborting – make every node reachable, then re-run the helper."
    return 1
  fi
  echo

  # ── 7. Summary ───────────────────────────────────────────────────────────
  tui_section "Add Replica Summary"
  tui_summary_open
  tui_summary_row "Primary"       "$primary_host"
  tui_summary_row "Replica"       "$replica_host"
  if [[ -n "$replica_postgresql_host" ]]; then
    tui_summary_row "Replica PDB" "$replica_postgresql_host"
  fi
  if [[ -n "$replica_token_file" ]]; then
    tui_summary_row "Token file" "$replica_token_file"
  fi
  tui_summary_close

  # ── 7b. Record run in helper.md ─────────────────────────────────────────
  append_helper_md "Add Replica (peadm::add_replica)" \
    "Bolt:   ${BOLT} plan run peadm::add_replica --params @${PARAMS_FILE} $(bolt_inv)" \
    "Primary:  ${primary_host}" \
    "Replica:  ${replica_host}" \
    "Replica PDB: ${replica_postgresql_host:-<none>}" \
    "Token file: ${replica_token_file:-<default>}"
  tui_blank
  tui_info "For access details and a record of this run, see ${script_dir}/helper.md"

  # ── 8. Run ───────────────────────────────────────────────────────────────
  tui_confirm _run_replica "Run peadm::add_replica now?" "Y"
  if [[ "$_run_replica" != "true" ]]; then
    tui_info "params.json and inventory.yaml are ready.  Run manually with:"
    printf '%s\n' \
      "${BOLT} plan run peadm::add_replica --params @${PARAMS_FILE} $(bolt_inv)" \
      | tui_hint_box
    return 0
  fi

  tui_section "Running peadm::add_replica"
  ${BOLT} plan run peadm::add_replica --params "@${PARAMS_FILE}" $(bolt_inv)
  local _status=$?
  if [[ $_status -ne 0 ]]; then
    tui_err "peadm::add_replica failed (exit $_status)"; return $_status
  fi
  tui_ok "peadm::add_replica completed"
}

# ──────────────────────────────────────────────────────────────────────────────
# BUILD PARAMS.JSON for peadm::add_replica
# ──────────────────────────────────────────────────────────────────────────────
build_add_replica_params() {
  local params_file="${script_dir}/params.json"

  jq -n \
    --arg primary_host "$(_hostname_only "$primary_host")" \
    --arg replica_host "$(_hostname_only "$replica_host")" \
    --arg replica_postgresql_host "$(_hostname_only "$replica_postgresql_host")" \
    --arg token_file "$replica_token_file" \
    '{ primary_host: $primary_host, replica_host: $replica_host }
     + (if $replica_postgresql_host != "" then { replica_postgresql_host: $replica_postgresql_host } else {} end)
     + (if $token_file != "" then { token_file: $token_file } else {} end)' \
    > "$params_file"

  PARAMS_FILE="$params_file"
  tui_ok "params.json written for peadm::add_replica"
}

# ──────────────────────────────────────────────────────────────────────────────
# BUILD INVENTORY.YAML for peadm::add_replica
# ──────────────────────────────────────────────────────────────────────────────
build_add_replica_inventory() {
  local inv="${script_dir}/inventory.yaml"

  local hosts=("$primary_host" "$replica_host")
  [[ -n "$replica_postgresql_host" ]] && hosts+=("$replica_postgresql_host")

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

  local _h _nm
  for _h in "${hosts[@]}"; do
    # peadm connects to targets by certname (no port); name the target with the
    # certname and set uri to the actual host:port so Bolt applies the group
    # config and reaches the container's mapped port.
    _nm=$(_hostname_only "$_h")
    echo "      - name: ${_nm}" >> "$inv"
    echo "        uri: ${_h}" >> "$inv"
  done

  tui_ok "inventory.yaml written for peadm::add_replica"
  tui_blank
  tui_info "Targets in inventory:"
  grep '      - ' "$inv" | while read -r _line; do
    tui_info "  $_line"
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# BACKUP / RESTORE HELPERS  (peadm::backup / peadm::restore)
# ──────────────────────────────────────────────────────────────────────────────

# Build a JSON object of all PE services as true/false from a comma-separated
# include list (used for the 'custom' backup / restore item selection).
_build_items_json() {
  local included="$1"
  local obj="{}" item
  for item in activity ca classifier code config orchestrator puppetdb rbac; do
    if [[ ",${included}," == *",${item},"* ]]; then
      obj=$(printf '%s' "$obj" | jq --arg k "$item" '. + {($k): true}')
    else
      obj=$(printf '%s' "$obj" | jq --arg k "$item" '. + {($k): false}')
    fi
  done
  printf '%s' "$obj"
}

# ──────────────────────────────────────────────────────────────────────────────
# BACKUP HELPER  (peadm::backup)
# ──────────────────────────────────────────────────────────────────────────────
helper_backup() {
  tui_section "Backup Helper (peadm::backup)"
  tui_info "Creates a backup of the PE primary.  The default is a full"
  tui_info "'recovery' backup; 'custom' backs up only the services you choose."
  echo

  configure_ssh_key

  # ── 0. Docker/cloud: set up connection to the Docker host ───────────────
  local _is_docker="no"
  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    _is_docker="yes"
    _resolve_docker_host_ip "${nodeprefix}"
    if [[ -z "$DOCKER_HOST_IP" ]]; then
      tui_err "Docker host IP is required"; return 1
    fi
    DOCKER_NET="${docker_network:-${nodeprefix}net}"
    DOCKER_IMG="${docker_image:-${docker_default_tag}}"
    dh_ssh() {
      ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=20 "${ssh_user}@${DOCKER_HOST_IP}" "$@"
    }
  fi

  # ── 1. Primary host (required) ────────────────────────────────────────────
  local _primary_default; _primary_default=$(build_fqdn core0)
  if [[ "$_is_docker" == "yes" ]]; then
    _primary_default="$(_docker_uri "$_primary_default")"
  fi
  tui_prompt primary_host "Primary host" "$_primary_default"
  if [[ "$_is_docker" == "yes" ]]; then
    primary_host="$(_docker_uri "$primary_host")"
  fi

  # ── 2. Backup type ───────────────────────────────────────────────────────
  local _bt_default=1
  tui_menu_default _bt "Backup type" "$_bt_default" \
    "recovery – full backup of primary and all services (default)" \
    "custom   – back up only selected services"
  backup_type=$(echo "$_bt" | awk '{print $1}')
  echo
  tui_ok "Backup type: ${BOLD}${backup_type}${RESET}"

  backup_items_json="{}"
  if [[ "$backup_type" == "custom" ]]; then
    tui_prompt backup_items "Items to back up (comma list; default all)" \
      "${backup_items:-activity,ca,classifier,code,config,orchestrator,puppetdb,rbac}"
    backup_items_json=$(_build_items_json "$backup_items")
  fi

  # ── 3. Output directory ──────────────────────────────────────────────────
  tui_prompt backup_output_directory "Output directory" "${backup_output_directory:-/tmp}"

  # ── 4. Build artefacts ─────────────────────────────────────────────────────
  build_backup_params
  build_backup_inventory

  # ── 5. Pre-flight reachability check ──────────────────────────────────────
  tui_section "Pre-flight connectivity check"
  local _tname; _tname=$(_hostname_only "$primary_host")
  if ${BOLT} command run "echo ok" --targets "$_tname" $(bolt_inv) >/dev/null 2>&1; then
    tui_ok "reachable: ${_tname}"
  else
    tui_err "NOT reachable: ${_tname}  (backup requires the primary to be up)"
    return 1
  fi
  echo

  # ── 6. Summary ───────────────────────────────────────────────────────────
  tui_section "Backup Summary"
  tui_summary_open
  tui_summary_row "Primary"  "$primary_host"
  tui_summary_row "Type"     "$backup_type"
  tui_summary_row "Output"   "$backup_output_directory"
  tui_summary_close

  # ── 6b. Record run in helper.md ─────────────────────────────────────────
  append_helper_md "Backup (peadm::backup)" \
    "Bolt:   ${BOLT} plan run peadm::backup --params @${PARAMS_FILE} $(bolt_inv)" \
    "Primary:  ${primary_host}" \
    "Type:     ${backup_type}" \
    "Output:   ${backup_output_directory}"
  tui_blank
  tui_info "For access details and a record of this run, see ${script_dir}/helper.md"

  # ── 7. Run ───────────────────────────────────────────────────────────────
  tui_confirm _run_backup "Run peadm::backup now?" "Y"
  if [[ "$_run_backup" != "true" ]]; then
    tui_info "params.json and inventory.yaml are ready.  Run manually with:"
    printf '%s\n' \
      "${BOLT} plan run peadm::backup --params @${PARAMS_FILE} $(bolt_inv)" \
      | tui_hint_box
    return 0
  fi

  tui_section "Running peadm::backup"
  ${BOLT} plan run peadm::backup --params "@${PARAMS_FILE}" $(bolt_inv)
  local _status=$?
  if [[ $_status -ne 0 ]]; then
    tui_err "peadm::backup failed (exit $_status)"; return $_status
  fi
  tui_ok "peadm::backup completed"
}

# ──────────────────────────────────────────────────────────────────────────────
# BUILD PARAMS.JSON for peadm::backup
# ──────────────────────────────────────────────────────────────────────────────
build_backup_params() {
  local params_file="${script_dir}/params.json"
  jq -n \
    --arg targets "$(_hostname_only "$primary_host")" \
    --arg backup_type "$backup_type" \
    --arg output_directory "$backup_output_directory" \
    --argjson backup "${backup_items_json:-{}}" \
    '{ targets: $targets, backup_type: $backup_type, output_directory: $output_directory }
     + (if $backup_type == "custom" then { backup: $backup } else {} end)' \
    > "$params_file"

  PARAMS_FILE="$params_file"
  tui_ok "params.json written for peadm::backup"
}

# ──────────────────────────────────────────────────────────────────────────────
# BUILD INVENTORY.YAML for peadm::backup
# ──────────────────────────────────────────────────────────────────────────────
build_backup_inventory() {
  local inv="${script_dir}/inventory.yaml"
  local hosts=("$primary_host")
  _write_pe_inventory "$inv" "${hosts[@]}"
  tui_ok "inventory.yaml written for peadm::backup"
  tui_blank
  tui_info "Targets in inventory:"
  grep '      - ' "$inv" | while read -r _line; do
    tui_info "  $_line"
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# RESTORE HELPER  (peadm::restore)
# ──────────────────────────────────────────────────────────────────────────────
helper_restore() {
  tui_section "Restore Helper (peadm::restore)"
  tui_info "Restores the primary from a peadm::backup tarball.  The primary's"
  tui_info "hostname MUST match the one the backup was created from."
  echo

  configure_ssh_key

  # ── 0. Docker/cloud: set up connection to the Docker host ───────────────
  local _is_docker="no"
  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    _is_docker="yes"
    _resolve_docker_host_ip "${nodeprefix}"
    if [[ -z "$DOCKER_HOST_IP" ]]; then
      tui_err "Docker host IP is required"; return 1
    fi
    DOCKER_NET="${docker_network:-${nodeprefix}net}"
    DOCKER_IMG="${docker_image:-${docker_default_tag}}"
    dh_ssh() {
      ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=20 "${ssh_user}@${DOCKER_HOST_IP}" "$@"
    }
  fi

  # ── 1. Primary host (required) ────────────────────────────────────────────
  local _primary_default; _primary_default=$(build_fqdn core0)
  if [[ "$_is_docker" == "yes" ]]; then
    _primary_default="$(_docker_uri "$_primary_default")"
  fi
  tui_prompt primary_host "Primary host" "$_primary_default"
  if [[ "$_is_docker" == "yes" ]]; then
    primary_host="$(_docker_uri "$primary_host")"
  fi

  # ── 2. Restore type ─────────────────────────────────────────────────────
  local _rt_default=1
  tui_menu_default _rt "Restore type" "$_rt_default" \
    "recovery    – full restore from a recovery backup (default)" \
    "recovery-db – restore the primary database server (XL DR)" \
    "custom      – restore only selected services"
  restore_type=$(echo "$_rt" | awk '{print $1}')
  echo
  tui_ok "Restore type: ${BOLD}${restore_type}${RESET}"

  # ── 3. Input file (required) ─────────────────────────────────────────────
  tui_prompt restore_input_file "Backup input file (.tar.gz)" "${restore_input_file:-}"
  if [[ "$restore_input_file" != *.tar.gz ]]; then
    tui_err "input_file must end in .tar.gz"; return 1
  fi

  restore_items_json="{}"
  if [[ "$restore_type" == "custom" ]]; then
    tui_prompt restore_items "Items to restore (comma list; default all)" \
      "${restore_items:-activity,ca,classifier,code,config,orchestrator,puppetdb,rbac}"
    restore_items_json=$(_build_items_json "$restore_items")
  fi

  # ── 4. Console password (optional) ───────────────────────────────────────
  tui_prompt restore_console_password "Console password (optional)" "${restore_console_password:-}"

  # ── 5. Additional cluster hosts (HA/XL only, optional) ───────────────────
  # For HA/XL, restore also touches the replica / compilers / external DBs.
  # Standard deployments need only the primary.  Comma-separated host:port list.
  tui_prompt restore_extra_hosts "Extra cluster hosts (comma, for HA/XL; empty to skip)" \
    "${restore_extra_hosts:-}"

  # ── 6. Build artefacts ─────────────────────────────────────────────────────
  build_restore_params
  build_restore_inventory

  # ── 7. Pre-flight reachability check ──────────────────────────────────────
  tui_section "Pre-flight connectivity check"
  local _all_ok="yes" _target _tname
  for _target in "$primary_host" ${restore_extra_hosts//,/ }; do
    _tname=$(_hostname_only "$_target")
    tui_info "Checking ${_tname} …"
    if ${BOLT} command run "echo ok" --targets "$_tname" $(bolt_inv) >/dev/null 2>&1; then
      tui_ok "reachable: ${_tname}"
    else
      tui_err "NOT reachable: ${_tname}  (make every node reachable, then re-run)"
      _all_ok="no"
    fi
  done
  if [[ "$_all_ok" == "no" ]]; then
    tui_err "Aborting – make every node reachable, then re-run the helper."
    return 1
  fi
  echo

  # ── 8. Summary ───────────────────────────────────────────────────────────
  tui_section "Restore Summary"
  tui_summary_open
  tui_summary_row "Primary" "$primary_host"
  tui_summary_row "Type"    "$restore_type"
  tui_summary_row "Input"   "$restore_input_file"
  if [[ -n "$restore_extra_hosts" ]]; then
    tui_summary_row "Extra"  "$restore_extra_hosts"
  fi
  tui_summary_close

  # ── 8b. Record run in helper.md ─────────────────────────────────────────
  append_helper_md "Restore (peadm::restore)" \
    "Bolt:   ${BOLT} plan run peadm::restore --params @${PARAMS_FILE} $(bolt_inv)" \
    "Primary:  ${primary_host}" \
    "Type:     ${restore_type}" \
    "Input:    ${restore_input_file}" \
    "Extra:    ${restore_extra_hosts:-<none>}"
  tui_blank
  tui_info "For access details and a record of this run, see ${script_dir}/helper.md"

  # ── 9. Run ───────────────────────────────────────────────────────────────
  tui_confirm _run_restore "Run peadm::restore now?" "Y"
  if [[ "$_run_restore" != "true" ]]; then
    tui_info "params.json and inventory.yaml are ready.  Run manually with:"
    printf '%s\n' \
      "${BOLT} plan run peadm::restore --params @${PARAMS_FILE} $(bolt_inv)" \
      | tui_hint_box
    return 0
  fi

  tui_section "Running peadm::restore"
  ${BOLT} plan run peadm::restore --params "@${PARAMS_FILE}" $(bolt_inv)
  local _status=$?
  if [[ $_status -ne 0 ]]; then
    tui_err "peadm::restore failed (exit $_status)"; return $_status
  fi
  tui_ok "peadm::restore completed"
}

# ──────────────────────────────────────────────────────────────────────────────
# BUILD PARAMS.JSON for peadm::restore
# ──────────────────────────────────────────────────────────────────────────────
build_restore_params() {
  local params_file="${script_dir}/params.json"
  jq -n \
    --arg targets "$(_hostname_only "$primary_host")" \
    --arg restore_type "$restore_type" \
    --arg input_file "$restore_input_file" \
    --arg console_password "$restore_console_password" \
    --argjson restore "$restore_items_json" \
    '{ targets: $targets, restore_type: $restore_type, input_file: $input_file }
     + (if $restore_type == "custom" then { restore: $restore } else {} end)
     + (if $console_password != "" then { console_password: $console_password } else {} end)' \
    > "$params_file"

  PARAMS_FILE="$params_file"
  tui_ok "params.json written for peadm::restore"
}

# ──────────────────────────────────────────────────────────────────────────────
# BUILD INVENTORY.YAML for peadm::restore
# ──────────────────────────────────────────────────────────────────────────────
build_restore_inventory() {
  local inv="${script_dir}/inventory.yaml"
  local hosts=("$primary_host")
  local _cn
  for _cn in ${restore_extra_hosts//,/ }; do
    _cn="${_cn// /}"
    [[ -n "$_cn" ]] && hosts+=("$_cn")
  done
  _write_pe_inventory "$inv" "${hosts[@]}"
  tui_ok "inventory.yaml written for peadm::restore"
  tui_blank
  tui_info "Targets in inventory:"
  grep '      - ' "$inv" | while read -r _line; do
    tui_info "  $_line"
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# SHARED INVENTORY WRITER  (certname-name + host:port-uri targets)
# Writes a Bolt inventory with the given host specs.  peadm connects to targets
# by certname (no port), so each target is named with the certname and its uri
# carries the actual host:port – letting Bolt apply the group config and reach
# the right container.
# ──────────────────────────────────────────────────────────────────────────────
# Validate a list of inventory hosts before writing.  Refuses to emit invalid
# YAML – specifically a host with an EMPTY docker host port ("host:"), which
# happens when the Docker host is unreachable and the mapped port can't be
# resolved.  Writing "uri: host:" breaks Bolt's YAML parser with a cryptic
# "mapping values are not allowed" error, so we catch it and explain instead.
_inventory_hosts_valid() {
  local bad=0 _h
  for _h in "$@"; do
    if [[ -z "$_h" ]]; then
      tui_err "Inventory host is empty – cannot write inventory.yaml."
      bad=1
    elif [[ "$_h" == *: && "$_h" != *:[0-9]* ]]; then
      tui_err "Host '$_h' has an EMPTY Docker host port."
      bad=1
    fi
  done
  if [[ $bad -ne 0 ]]; then
    tui_err "The Docker host could not be reached to map the container port."
    tui_err "Check the Docker host is up and /etc/hosts has the node entries, then re-run."
    return 1
  fi
}

_write_pe_inventory() {
  local inv="$1"; shift
  local hosts=("$@")
  _inventory_hosts_valid "${hosts[@]}" || return 1
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

  local _h _nm
  for _h in "${hosts[@]}"; do
    _nm=$(_hostname_only "$_h")
    echo "      - name: ${_nm}" >> "$inv"
    echo "        uri: ${_h}" >> "$inv"
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# BACKUP/restore_ca HELPERS  (peadm::backup_ca / peadm::restore_ca)
# ──────────────────────────────────────────────────────────────────────────────
helper_backup_ca() {
  tui_section "Backup CA Helper (peadm::backup_ca)"
  tui_info "Backs up the PE CA and SSL certificates (certs scope) into a tarball."
  echo

  configure_ssh_key

  # ── 0. Docker/cloud: set up connection to the Docker host ───────────────
  local _is_docker="no"
  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    _is_docker="yes"
    _resolve_docker_host_ip "${nodeprefix}"
    if [[ -z "$DOCKER_HOST_IP" ]]; then
      tui_err "Docker host IP is required"; return 1
    fi
    DOCKER_NET="${docker_network:-${nodeprefix}net}"
    DOCKER_IMG="${docker_image:-${docker_default_tag}}"
    dh_ssh() {
      ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=20 "${ssh_user}@${DOCKER_HOST_IP}" "$@"
    }
  fi

  # ── 1. Primary host (required) ────────────────────────────────────────────
  local _primary_default; _primary_default=$(build_fqdn core0)
  if [[ "$_is_docker" == "yes" ]]; then
    _primary_default="$(_docker_uri "$_primary_default")"
  fi
  tui_prompt primary_host "Primary host" "$_primary_default"
  if [[ "$_is_docker" == "yes" ]]; then
    primary_host="$(_docker_uri "$primary_host")"
  fi

  # ── 2. Output directory ──────────────────────────────────────────────────
  tui_prompt backup_ca_output_directory "Output directory" "${backup_ca_output_directory:-/tmp}"

  # ── 3. Build artefacts ─────────────────────────────────────────────────────
  build_backup_ca_params
  _write_pe_inventory "${script_dir}/inventory.yaml" "$primary_host"
  tui_ok "inventory.yaml written for peadm::backup_ca"

  # ── 4. Pre-flight reachability check ──────────────────────────────────────
  tui_section "Pre-flight connectivity check"
  local _tname; _tname=$(_hostname_only "$primary_host")
  if ${BOLT} command run "echo ok" --targets "$_tname" $(bolt_inv) >/dev/null 2>&1; then
    tui_ok "reachable: ${_tname}"
  else
    tui_err "NOT reachable: ${_tname}  (backup_ca requires the primary to be up)"
    return 1
  fi
  echo

  # ── 5. Summary ───────────────────────────────────────────────────────────
  tui_section "Backup CA Summary"
  tui_summary_open
  tui_summary_row "Primary"  "$primary_host"
  tui_summary_row "Output"   "$backup_ca_output_directory"
  tui_summary_close

  # ── 5b. Record run in helper.md ─────────────────────────────────────────
  append_helper_md "Backup CA (peadm::backup_ca)" \
    "Bolt:   ${BOLT} plan run peadm::backup_ca --params @${PARAMS_FILE} $(bolt_inv)" \
    "Primary:  ${primary_host}" \
    "Output:   ${backup_ca_output_directory}"
  tui_blank
  tui_info "For access details and a record of this run, see ${script_dir}/helper.md"

  # ── 6. Run ───────────────────────────────────────────────────────────────
  tui_confirm _run_backup_ca "Run peadm::backup_ca now?" "Y"
  if [[ "$_run_backup_ca" != "true" ]]; then
    tui_info "params.json and inventory.yaml are ready.  Run manually with:"
    printf '%s\n' \
      "${BOLT} plan run peadm::backup_ca --params @${PARAMS_FILE} $(bolt_inv)" \
      | tui_hint_box
    return 0
  fi

  tui_section "Running peadm::backup_ca"
  ${BOLT} plan run peadm::backup_ca --params "@${PARAMS_FILE}" $(bolt_inv)
  local _status=$?
  if [[ $_status -ne 0 ]]; then
    tui_err "peadm::backup_ca failed (exit $_status)"; return $_status
  fi
  tui_ok "peadm::backup_ca completed"
}

build_backup_ca_params() {
  local params_file="${script_dir}/params.json"
  jq -n \
    --arg target "$(_hostname_only "$primary_host")" \
    --arg output_directory "$backup_ca_output_directory" \
    '{ target: $target, output_directory: $output_directory }' \
    > "$params_file"

  PARAMS_FILE="$params_file"
  tui_ok "params.json written for peadm::backup_ca"
}

# ──────────────────────────────────────────────────────────────────────────────
# RESTORE CA HELPER  (peadm::restore_ca)
# ──────────────────────────────────────────────────────────────────────────────
helper_restore_ca() {
  tui_section "Restore CA Helper (peadm::restore_ca)"
  tui_info "Restores the PE CA and SSL certificates from a ca_backup tarball."
  tui_warn "This stops PE services, restores the CA, then restarts them –"
  tui_warn "there will be a few minutes of downtime."
  echo

  configure_ssh_key

  # ── 0. Docker/cloud: set up connection to the Docker host ───────────────
  local _is_docker="no"
  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    _is_docker="yes"
    _resolve_docker_host_ip "${nodeprefix}"
    if [[ -z "$DOCKER_HOST_IP" ]]; then
      tui_err "Docker host IP is required"; return 1
    fi
    DOCKER_NET="${docker_network:-${nodeprefix}net}"
    DOCKER_IMG="${docker_image:-${docker_default_tag}}"
    dh_ssh() {
      ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=20 "${ssh_user}@${DOCKER_HOST_IP}" "$@"
    }
  fi

  # ── 1. Primary host (required) ────────────────────────────────────────────
  local _primary_default; _primary_default=$(build_fqdn core0)
  if [[ "$_is_docker" == "yes" ]]; then
    _primary_default="$(_docker_uri "$_primary_default")"
  fi
  tui_prompt primary_host "Primary host" "$_primary_default"
  if [[ "$_is_docker" == "yes" ]]; then
    primary_host="$(_docker_uri "$primary_host")"
  fi

  # ── 2. Backup file path (required) ───────────────────────────────────────
  tui_prompt restore_ca_file_path "Backup CA file path (.tgz)" "${restore_ca_file_path:-}"
  if [[ -z "$restore_ca_file_path" ]]; then
    tui_err "file_path is required"; return 1
  fi

  # ── 3. Recovery directory (optional) ─────────────────────────────────────
  tui_prompt restore_ca_recovery_directory "Recovery directory" \
    "${restore_ca_recovery_directory:-/tmp/peadm_recovery}"

  # ── 4. Build artefacts ─────────────────────────────────────────────────────
  build_restore_ca_params
  _write_pe_inventory "${script_dir}/inventory.yaml" "$primary_host"
  tui_ok "inventory.yaml written for peadm::restore_ca"

  # ── 5. Pre-flight reachability check ──────────────────────────────────────
  tui_section "Pre-flight connectivity check"
  local _tname; _tname=$(_hostname_only "$primary_host")
  if ${BOLT} command run "echo ok" --targets "$_tname" $(bolt_inv) >/dev/null 2>&1; then
    tui_ok "reachable: ${_tname}"
  else
    tui_err "NOT reachable: ${_tname}  (restore_ca requires the primary to be up)"
    return 1
  fi
  echo

  # ── 6. Summary ───────────────────────────────────────────────────────────
  tui_section "Restore CA Summary"
  tui_summary_open
  tui_summary_row "Primary"  "$primary_host"
  tui_summary_row "File"     "$restore_ca_file_path"
  tui_summary_row "Recovery" "$restore_ca_recovery_directory"
  tui_summary_close

  # ── 6b. Record run in helper.md ─────────────────────────────────────────
  append_helper_md "Restore CA (peadm::restore_ca)" \
    "Bolt:   ${BOLT} plan run peadm::restore_ca --params @${PARAMS_FILE} $(bolt_inv)" \
    "Primary:  ${primary_host}" \
    "File:     ${restore_ca_file_path}" \
    "Recovery: ${restore_ca_recovery_directory}"
  tui_blank
  tui_info "For access details and a record of this run, see ${script_dir}/helper.md"

  # ── 7. Run ───────────────────────────────────────────────────────────────
  tui_confirm _run_restore_ca "Run peadm::restore_ca now?" "Y"
  if [[ "$_run_restore_ca" != "true" ]]; then
    tui_info "params.json and inventory.yaml are ready.  Run manually with:"
    printf '%s\n' \
      "${BOLT} plan run peadm::restore_ca --params @${PARAMS_FILE} $(bolt_inv)" \
      | tui_hint_box
    return 0
  fi

  tui_section "Running peadm::restore_ca"
  ${BOLT} plan run peadm::restore_ca --params "@${PARAMS_FILE}" $(bolt_inv)
  local _status=$?
  if [[ $_status -ne 0 ]]; then
    tui_err "peadm::restore_ca failed (exit $_status)"; return $_status
  fi
  tui_ok "peadm::restore_ca completed"
}

build_restore_ca_params() {
  local params_file="${script_dir}/params.json"
  jq -n \
    --arg target "$(_hostname_only "$primary_host")" \
    --arg file_path "$restore_ca_file_path" \
    --arg recovery_directory "$restore_ca_recovery_directory" \
    '{ target: $target, file_path: $file_path, recovery_directory: $recovery_directory }' \
    > "$params_file"

  PARAMS_FILE="$params_file"
  tui_ok "params.json written for peadm::restore_ca"
}

# ──────────────────────────────────────────────────────────────────────────────
# SWING MIGRATION HELPER  (provision new → backup old → restore → finalize)
#
# All-in-one wrapper that wires the existing provision + backup + restore flows
# together to build a brand-new PARALLEL PE infra, back up the current one,
# restore that backup onto the new infra, then promote the new infra to become
# the current defaults.  Node migration (pointing agents at the new infra) is a
# documented placeholder until a pattern is agreed.  Decommissioning the old
# infra is intentionally left as a manual next step.
# ──────────────────────────────────────────────────────────────────────────────

# Extract the SSH port from a host:port URI (defaults to 22).
_uri_port() { local h="$1"; [[ "$h" == *:* ]] && echo "${h##*:}" || echo 22; }

# Echo the full cluster host list (docker-aware) for the CURRENT globals.
# Used to build the restore inventory for LARGE/XL (replica, PDB, compilers).
_swing_cluster_hosts() {
  local _list
  _list="$(build_fqdn core0)"
  if [[ "$instype" == "XL" ]]; then
    _list="${_list} $(build_fqdn core1)"
  fi
  if [[ "$enable_dr" == "true" ]]; then
    if [[ "$instype" == "XL" ]]; then
      _list="${_list} $(build_fqdn core2) $(build_fqdn core3)"
    else
      _list="${_list} $(build_fqdn core1)"
    fi
  fi
  local _i
  for _i in $(seq 0 $((compiler_count - 1))); do
    _list="${_list} $(build_fqdn "compiler${_i}")"
  done
  local _h _out=""
  for _h in $_list; do
    if [[ "$_is_docker" == "yes" ]]; then _h=$(_docker_uri "$_h"); fi
    _out="${_out} ${_h}"
  done
  echo "${_out# }"
}

# Run a peadm plan that returns a 'path' value (e.g. peadm::backup) and echo the
# captured path.  Uses --format json and a defensive jq parse; falls back to a
# manual prompt if the path can't be parsed from the output.
_swing_run_plan_capture_path() {
  local plan="$1"
  tui_section "Running ${plan}"
  local _out _status _path _clean
  _out=$(${BOLT} plan run "$plan" --params "@${PARAMS_FILE}" $(bolt_inv) --format json 2>/dev/null) || true
  _status=$?
  # The wizard spinner redraws the section box on stdout while bolt runs, and its
  # ANSI frames can get mixed into the captured JSON.  Strip all escape/control
  # sequences first so the path is parsed from clean text.
  _clean=$(printf '%s' "$_out" \
    | sed -r 's/\x1B\[[0-9;]*[ -/]*[@-~]//g; s/\x1B\[[()][0-9A-B]//g; s/\x1B[()][0-9A-B]//g; s/\r$//' \
    | tr -d '\000\033')
  _path=$(printf '%s' "$_clean" | jq -r '(if type=="object" then (.result.path // .path // empty) else empty end)' 2>/dev/null || echo "")
  # Safety net: whatever got parsed/mangled, extract the actual backup tarball
  # path wherever it appears in the output.
  if [[ -z "$_path" ]]; then
    _path=$(printf '%s' "$_clean" | grep -oE '/tmp/pe-backup-[A-Za-z0-9._-]*\.tar\.gz' | head -1 || echo "")
  fi
  if [[ -z "$_path" ]]; then
    tui_warn "Could not parse the returned path from ${plan}."
    tui_prompt _manual_path "Enter the backup path manually (or blank to skip)" ""
    _path="$_manual_path"
  fi
  echo "$_path"
}

# Offload a backup tarball FROM a target (old primary) TO the wizard host, so it
# survives the provisioning cutover (the old Docker-host VM is destroyed when the
# new infra is provisioned).  Echoes the local path on success, non-zero on failure.
#   $1 = source uri   $2 = source path
#
# For docker, the tarball lives INSIDE the container, so we must scp via the
# Docker host's MAPPED SSH port for the container (host:port) – NOT the Docker
# host's own /tmp (which would give a misleading "No such file" since the file is
# inside the container).  We resolve+validate that port and pre-check the file.
_swing_offload() {
  local src_uri="$1" src_path="$2"
  # Defensively re-extract the real tarball path and strip any ANSI/control
  # bytes that the wizard's spinner may have leaked into the captured path.
  local _sp=$(printf '%s' "$src_path" | grep -oE '/tmp/pe-backup-[A-Za-z0-9._-]*\.tar\.gz' | head -1)
  [[ -n "$_sp" ]] && src_path="$_sp"
  src_path=$(printf '%s' "$src_path" | sed -r 's/\x1B\[[0-9;]*[ -/]*[@-~]//g' | tr -d '\000\033')
  local base; base=$(basename "$src_path")
  local bak_dir="${script_dir}/backups"
  mkdir -p "$bak_dir"
  local local_path="${bak_dir}/${base}"
  local _so="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20"

  if [[ "$_is_docker" == "yes" ]]; then
    local _host="${DOCKER_HOST_IP:-}"
    if [[ -z "$_host" ]]; then
      _resolve_docker_host_ip "${nodeprefix}"
      _host="${DOCKER_HOST_IP:-}"
    fi
    if [[ -z "$_host" ]]; then
      tui_err "Cannot offload: Docker host is unknown (no IP resolvable)."
      return 1
    fi
    # Mapped SSH port for the container (fall back to live docker map if the URI
    # didn't carry it or it was empty).
    local _cname; _cname=$(_hostname_only "$src_uri")
    local _sport; _sport=$(_uri_port "$src_uri")
    if [[ ! "$_sport" =~ ^[0-9]+$ ]]; then
      _sport=$(_docker_port_for "$_cname")
    fi
    if [[ ! "$_sport" =~ ^[0-9]+$ ]]; then
      tui_err "Cannot offload: no mapped SSH port for container '${_cname}' on ${_host}."
      tui_err "Is that container running with a published ->22 port?"
      return 1
    fi

    tui_step "Offloading backup ${base} from ${_host}:${_sport} (container ${_cname}) → ${local_path}…" >&2
    # IMPORTANT: the tarball is streamed via `ssh ... cat` (a shell command), NOT
    # scp/SFTP.  Observed failure mode: on this docker-host the container's SFTP
    # subsystem lags far behind the shell — `ls` (shell) shows the file while
    # `scp` (SFTP) reports "No such file" for minutes, even after the tar is done.
    # `ssh cat` uses the same shell view that reliably sees the file.  We poll
    # until the remote size is stable (tar finished) and only accept the stream
    # once the full byte count has landed locally.
    #
    # We ALSO surface the raw ssh error on any failed attempt, so a connectivity /
    # key / known-hosts problem is immediately visible instead of being swallowed.
    local _attempt _rsize _lsize _sserr="" _serrf
    _serrf=$(mktemp)
    local _stream_ok=""
    for _attempt in {1..48}; do
      _rsize=""; _sserr=""
      if _rsize=$(ssh -p "$_sport" -i "$ssh_key_path" $_so \
          "${ssh_user}@${_host}" "stat -c%s '${src_path}'" 2>"$_serrf"); then
        :
      else
        _sserr="$(cat "$_serrf" 2>/dev/null)"
        [[ -z "$_sserr" ]] && _sserr="ssh returned an error"
      fi
      if [[ "$_rsize" =~ ^[0-9]+$ && "$_rsize" -gt 0 ]]; then
        if ssh -p "$_sport" -i "$ssh_key_path" $_so \
            "${ssh_user}@${_host}" "cat '${src_path}'" > "$local_path" 2>"$_serrf"; then
          _ssize=$(stat -c%s "$local_path" 2>/dev/null || echo 0)
          if [[ "$_ssize" == "$_rsize" && "$_ssize" -gt 0 ]]; then
            rm -f "$_serrf"; echo "$local_path"; return 0
          fi
        fi
        rm -f "$local_path"   # partial/truncated copy — retry
      fi
      [[ "$_attempt" == "1" ]] && tui_warn "Offloading '${src_path}' from ${_host}:${_sport} — waiting for it to be ready (up to ~4 min)…" >&2
      if [[ -n "$_sserr" ]]; then
        tui_warn "  [ssh diagnostic] $_sserr" >&2
      fi
      sleep 5
    done
    rm -f "$_serrf"

    # Exact path never became streamable — fall back to the newest pe-backup
    # tarball on the container (safe: it is the just-created backup of the same
    # infra).  Always stream it via ssh cat, whether it matches or not.
    tui_warn "Requested '${src_path}' still not ready on ${_host}:${_sport}." >&2
    local _latest
    _latest=$(ssh -p "$_sport" -i "$ssh_key_path" $_so \
        "${ssh_user}@${_host}" "ls -t /tmp/pe-backup-*.tar.gz 2>/dev/null | head -1" 2>/dev/null)
    tui_warn "Newest backup present on container: ${_latest:-none}" >&2
    if [[ -n "$_latest" ]]; then
      local _nb; _nb=$(basename "$_latest")
      if [[ "$_nb" != "$base" ]]; then
        src_path="$_latest"; base="$_nb"; local_path="${bak_dir}/${base}"
        tui_warn "Falling back to offloading newest backup ${base}…" >&2
      else
        tui_warn "Retrying offload of ${base} now that it is visible on the container…" >&2
      fi
      for _attempt in {1..20}; do
        _rsize=""; _sserr=""
        if _rsize=$(ssh -p "$_sport" -i "$ssh_key_path" $_so \
            "${ssh_user}@${_host}" "stat -c%s '${src_path}'" 2>"$_serrf"); then
          :
        else
          _sserr="$(cat "$_serrf" 2>/dev/null)"
        fi
        if [[ "$_rsize" =~ ^[0-9]+$ && "$_rsize" -gt 0 ]] && \
           ssh -p "$_sport" -i "$ssh_key_path" $_so \
            "${ssh_user}@${_host}" "cat '${src_path}'" > "$local_path" 2>/dev/null; then
          _ssize=$(stat -c%s "$local_path" 2>/dev/null || echo 0)
          if [[ "$_ssize" == "$_rsize" && "$_ssize" -gt 0 ]]; then
            echo "$local_path"; return 0
          fi
        fi
        if [[ -n "$_sserr" ]]; then
          tui_warn "  [ssh diagnostic: $_sserr]" >&2
        fi
        rm -f "$local_path"
        sleep 4
      done
    fi
    tui_warn "Offload failed after multiple attempts to ${_host}:${_sport} (container ${_cname})." >&2
    tui_warn "If the backup file '${src_path}' is really not on the container, the backup didn't complete." >&2
    return 1
  else
    tui_step "Offloading backup ${base} from ${src_uri} to ${local_path}…" >&2
    if scp -q -i "$ssh_key_path" $_so \
        "${ssh_user}@${src_uri}:${src_path}" "$local_path"; then
      echo "$local_path"; return 0
    fi
  fi
  tui_warn "Offload failed – backup NOT safe.  Copy ${src_path} off the old infra manually." >&2
  return 1
}

# Load a (previously offloaded) backup tarball from the wizard host ONTO a target
# (the new primary), so peadm::restore can read it.  Echoes the remote path on
# success, non-zero on failure.
#   $1 = dest uri   $2 = local path
_swing_load_onto() {
  local dst_uri="$1" local_path="$2"
  local base; base=$(basename "$local_path")
  local dst_path="/tmp/${base}"
  local _so="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20"

  if [[ "$_is_docker" == "yes" ]]; then
    # Always resolve for the CURRENT node prefix so the load targets the right
    # Docker host (the new infra has its OWN VM, so the swing must not reuse the
    # old infra's DOCKER_HOST_IP that was cached at swing start).
    DOCKER_HOST_IP=""
    _resolve_docker_host_ip "${nodeprefix}"
    local _host="${DOCKER_HOST_IP:-}"
    if [[ -z "$_host" ]]; then
      tui_err "Cannot load backup: Docker host is unknown (no IP resolvable for ${nodeprefix})."
      return 1
    fi
    local _cname; _cname=$(_hostname_only "$dst_uri")
    local _dport; _dport=$(_uri_port "$dst_uri")
    if [[ ! "$_dport" =~ ^[0-9]+$ ]]; then
      _dport=$(_docker_port_for "$_cname")
    fi
    if [[ ! "$_dport" =~ ^[0-9]+$ ]]; then
      tui_err "Cannot load backup: no mapped SSH port for container '${_cname}' on ${_host}."
      return 1
    fi
    if [[ ! -f "$local_path" ]]; then
      tui_err "Cannot load backup: local file not found: ${local_path}"
      return 1
    fi
    local _lsize; _lsize=$(stat -c%s "$local_path" 2>/dev/null || echo 0)
    tui_step "Loading backup ${base} (${_lsize} bytes) onto ${_host}:${_dport} (container ${_cname}) as ${dst_path}…" >&2
    # Stream via `ssh ... cat` (shell) rather than scp/SFTP for the same reason
    # as the offload: the container's SFTP subsystem lags the shell view.
    local _rsize _lerr
    for _attempt in 1 2 3 4 5 6 7 8; do
      _lerr="${script_dir}/load_onto_err.log"
      if [[ "$_lsize" -gt 0 ]] && \
         ssh -p "$_dport" -i "$ssh_key_path" $_so \
            "${ssh_user}@${_host}" "cat > '${dst_path}'" < "$local_path" 2>"$_lerr"; then
        _rsize=$(ssh -p "$_dport" -i "$ssh_key_path" $_so \
            "${ssh_user}@${_host}" "stat -c%s '${dst_path}' 2>/dev/null" 2>/dev/null)
        if [[ "$_rsize" == "$_lsize" ]]; then
          tui_ok "Backup loaded: ${dst_path} on ${_host}:${_dport} (${_rsize} bytes verified)" >&2
          echo "$dst_path"; return 0
        fi
        tui_warn "  [load diagnostic] copy rc=0 but size mismatch (sent ${_lsize}, got ${_rsize:-0}) – retrying…" >&2
      else
        tui_warn "  [load diagnostic] attempt ${_attempt}: ssh/copy failed" >&2
        tui_warn "  [ssh diagnostic] $(head -c 600 "$_lerr" 2>/dev/null | tr '\n' ' ')" >&2
      fi
      sleep 3
    done
  else
    tui_step "Loading backup ${base} onto ${dst_uri} as ${dst_path}…" >&2
    if scp -q -i "$ssh_key_path" $_so \
        "$local_path" "${ssh_user}@${dst_uri}:${dst_path}"; then
      echo "$dst_path"; return 0
    fi
  fi
  tui_warn "Load failed – place ${local_path} on ${dst_uri} manually." >&2
  return 1
}

# Rebrand the restored PE on the new primary from the OLD infra's hostnames to the
# NEW infra's hostnames (config scope), restart PE, and converge a Puppet run.
# This is swing Phase 4 – turning the restored (old-name) config into a functional
# new-name standalone primary.  A plain `recovery` restore imports the old infra's
# config wholesale, leaving e.g. `server_list = <old>core0:8140`, which is exactly
# what makes the post-restore `wait_for_puppet_run` check fail.  Emits diagnostics
# to stderr; echoes nothing on stdout.
#   $1 = dest uri (new primary, e.g. labn12core0:2201)
#   $2 = old node prefix (e.g. labn1)
#   $3 = new node prefix (e.g. labn12)
_swing_migrate_nodes() {
  local _dst="$1" _op="$2" _np="$3"
  local _host _port _so
  _host=$(_hostname_only "$_dst"); _port=$(_uri_port "$_dst")
  _so="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20"

  tui_step "Rebranding restored PE from ${_op}* to ${_np}* on ${_host}…" >&2
  # Skip anything under a .git dir (the code-repo alternates/objects) so we don't
  # corrupt git alternates; rewrite the PE config scope, also transform the
  # classifier DB (which a plain `recovery` restore leaves carrying the old
  # hostname), restart PE, and converge.  A heredoc keeps the SQL/quoting clean.
  local _rc
  ssh -p "$_port" -i "$ssh_key_path" $_so "${ssh_user}@${_host}" 'bash -s' <<REMOTE
set -e
grep -rlE '${_op}(core0|test)' /etc/puppetlabs/ 2>/dev/null | grep -v '/\\.git/' | xargs -r sed -i -e 's/${_op}core0/${_np}core0/g' -e 's/${_op}test/${_np}test/g' || true
su - pe-postgres -s /bin/bash -c "/opt/puppetlabs/server/bin/psql -d pe-classifier -c \"UPDATE group_class_parameters SET value=replace(value,'${_op}core0','${_np}core0'); UPDATE group_hiera_data SET value=replace(value,'${_op}core0','${_np}core0'); UPDATE group_variables SET value=replace(value,'${_op}core0','${_np}core0');\""
/opt/puppetlabs/bin/puppet resource service pe-puppetserver pe-puppetdb pe-console-services pe-orchestration-services pe-nginx ensure=running >/dev/null 2>&1 || true
/opt/puppetlabs/bin/puppet agent -t >/dev/null 2>&1 || true
/opt/puppetlabs/bin/puppet infra status
REMOTE
  _rc=$?
  if [[ $_rc -ne 0 ]]; then
    tui_err "Node migration on ${_host} reported problems (ssh rc $_rc)."
    tui_err "The restored config still carries ${_op}* hostnames; re-run or migrate manually."
    return $_rc
  fi
  tui_ok "New primary ${_host} now identified as ${_np}*; PE services running."
  return 0
}

# Copy the OLD infra's hiera-eyaml keys to the NEW primary so the restored
# (old-infra) hiera data can be decrypted.  Best-effort – if the old keys can't
# be read, warn and continue (the new infra's own keys remain in place).
_swing_copy_eyaml_keys() {
  local _old="$1" _new="$2"
  local _so="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20"
  local _old_host _old_port _new_host _new_port
  _old_host=$(_hostname_only "$_old"); _old_port=$(_uri_port "$_old")
  _new_host=$(_hostname_only "$_new"); _new_port=$(_uri_port "$_new")
  [[ "$_old_port" =~ ^[0-9]+$ ]] || _old_port=22
  [[ "$_new_port" =~ ^[0-9]+$ ]] || _new_port=22

  tui_step "Copying hiera-eyaml keys from ${_old_host} to ${_new_host}…" >&2
  local _pub _priv
  _pub=$(ssh -p "$_old_port" -i "$ssh_key_path" $_so "${ssh_user}@${_old_host}" \
    "cat /etc/puppetlabs/puppet/keys/public_key.pkcs7.pem 2>/dev/null" 2>/dev/null)
  _priv=$(ssh -p "$_old_port" -i "$ssh_key_path" $_so "${ssh_user}@${_old_host}" \
    "cat /etc/puppetlabs/puppet/keys/private_key.pkcs7.pem 2>/dev/null" 2>/dev/null)
  if [[ -z "$_pub" || -z "$_priv" ]]; then
    tui_warn "Could not read old eyaml keys from ${_old_host} – skipping key copy." >&2
    return 0
  fi
  ssh -p "$_new_port" -i "$ssh_key_path" $_so "${ssh_user}@${_new_host}" \
    "mkdir -p /etc/puppetlabs/puppet/keys && cat > /etc/puppetlabs/puppet/keys/public_key.pkcs7.pem && chown pe-puppet:pe-puppet /etc/puppetlabs/puppet/keys/public_key.pkcs7.pem && chmod 644 /etc/puppetlabs/puppet/keys/public_key.pkcs7.pem" \
    <<<"$_pub" 2>/dev/null
  ssh -p "$_new_port" -i "$ssh_key_path" $_so "${ssh_user}@${_new_host}" \
    "cat > /etc/puppetlabs/puppet/keys/private_key.pkcs7.pem && chown pe-puppet:pe-puppet /etc/puppetlabs/puppet/keys/private_key.pkcs7.pem && chmod 600 /etc/puppetlabs/puppet/keys/private_key.pkcs7.pem" \
    <<<"$_priv" 2>/dev/null
  tui_ok "hiera-eyaml keys copied to ${_new_host}" >&2
}

# ──────────────────────────────────────────────────────────────────────────────
# REPLICA DR TEST HELPER
# Tests disaster recovery by promoting the replica to primary (failover),
# verifying it is serving, then failing back to the original primary.  Requires
# an ACTIVE replica (DR enabled).  A safety backup of the primary is taken first.
# ──────────────────────────────────────────────────────────────────────────────
helper_dr_test() {
  tui_section "Replica DR Test Helper"
  tui_info "Tests disaster recovery: promotes the replica to primary (failover),"
  tui_info "verifies it is serving, then fails back to the original primary."
  echo
  tui_warn "⚠  This is a DESTRUCTIVE, production-affecting test."
  tui_warn "An ACTIVE replica MUST already exist (DR enabled) – this helper does"
  tui_warn "NOT create one.  A safety backup of the primary is taken first, but"
  tui_warn "you should have a current backup regardless."
  if [[ "${enable_dr:-false}" != "true" ]]; then
    tui_warn "Saved context does not show DR enabled (enable_dr != true)."
    tui_warn "Confirm an ACTIVE replica exists before continuing."
  fi
  echo

  configure_ssh_key

  # ── 0. Docker/cloud: set up connection to the Docker host ───────────────
  local _is_docker="no"
  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    _is_docker="yes"
    _resolve_docker_host_ip "${nodeprefix}"
    if [[ -z "$DOCKER_HOST_IP" ]]; then
      tui_err "Docker host IP is required"; return 1
    fi
    DOCKER_NET="${docker_network:-${nodeprefix}net}"
    DOCKER_IMG="${docker_image:-${docker_default_tag}}"
    dh_ssh() {
      ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=20 "${ssh_user}@${DOCKER_HOST_IP}" "$@"
    }
  fi

  # ── 1. Primary host (required) ────────────────────────────────────────────
  local _primary_default; _primary_default=$(build_fqdn core0)
  [[ "$_is_docker" == "yes" ]] && _primary_default="$(_docker_uri "$_primary_default")"
  tui_prompt primary_host "Primary host" "$_primary_default"
  [[ "$_is_docker" == "yes" ]] && primary_host="$(_docker_uri "$primary_host")"

  # ── 1b. Auto-detect the ACTIVE replica from the primary's infra status ─────
  # Flexible for LARGE/XL/added-replica topologies where the replica isn't
  # always core1 (e.g. XL-HA with separate DB nodes).  Best-effort: falls back
  # to the core1 default if detection fails.  Uses direct SSH/docker exec (not
  # Bolt) so it works before the DR inventory is built.
  local _detected_replica="" _pname_detect _istatus
  _pname_detect=$(_hostname_only "$primary_host")
  # NOTE: `timeout` is an external binary and cannot run the dh_ssh shell
  # function, so the timeout must go INSIDE the remote command.
  if [[ "$_is_docker" == "yes" ]]; then
    _istatus=$(dh_ssh "timeout 60 docker exec ${_pname_detect} /opt/puppetlabs/bin/puppet infra status" 2>/dev/null) || _istatus=""
  else
    _istatus=$(ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@${_pname_detect}" "timeout 60 /opt/puppetlabs/bin/puppet infra status" 2>/dev/null) || _istatus=""
  fi
  _detected_replica=$(printf '%s' "$_istatus" | sed -e 's/\x1b\[[0-9;]*m//g' \
      | awk '/^Replica:/{print $2; exit}' | tr -d '\r') || _detected_replica=""
  if [[ -n "$_detected_replica" ]]; then
    tui_ok "Detected active replica: ${_detected_replica}"
  else
    tui_info "Could not auto-detect the replica from infra status."
  fi

  # ── 2. Replica host (required, must be an ACTIVE replica) ─────────────────
  local _replica_default; _replica_default=$(build_fqdn core1)
  [[ -n "$_detected_replica" ]] && _replica_default="$_detected_replica"
  [[ "$_is_docker" == "yes" ]] && _replica_default="$(_docker_uri "$_replica_default")"
  tui_prompt replica_host "Replica host (must be an ACTIVE replica)" "$_replica_default"
  [[ "$_is_docker" == "yes" ]] && replica_host="$(_docker_uri "$replica_host")"

  local _pname _rname
  _pname=$(_hostname_only "$primary_host")
  _rname=$(_hostname_only "$replica_host")

  # Build one inventory containing both hosts (used for pre-flight, backup,
  # promote and verify).
  build_dr_test_inventory

  # ── 3. Pre-flight checks ─────────────────────────────────────────────────
  tui_section "Pre-flight checks"
  local _all_ok="yes" _target _tname
  for _target in "$primary_host" "$replica_host"; do
    _tname=$(_hostname_only "$_target")
    tui_info "Checking reachability of ${_tname} …"
    if ${BOLT} command run "echo ok" --targets "$_tname" $(bolt_inv) >/dev/null 2>&1; then
      tui_ok "reachable: ${_tname}"
    else
      tui_err "NOT reachable: ${_tname}"; _all_ok="no"
    fi
  done
  if [[ "$_all_ok" == "no" ]]; then
    tui_err "Aborting – make every node reachable, then re-run."
    return 1
  fi

  # Verify the replica is an ACTIVE replica (reports as a replica, PE up).
  tui_info "Checking replica ${_rname} is an active replica …"
  local _rstatus
  if _rstatus=$(${BOLT} command run "/opt/puppetlabs/bin/puppet infra status" --targets "$_rname" $(bolt_inv) 2>&1); then
    _rstatus=$(printf '%s' "$_rstatus" | sed -e 's/\x1b\[[0-9;]*m//g')
    if grep -qiE "replica" <<<"$_rstatus"; then
      tui_ok "replica ${_rname} is active (reports as a replica)"
    else
      tui_warn "Replica ${_rname} is reachable but does not clearly report as a replica."
      tui_warn "Confirm it is an ACTIVE replica before continuing."
    fi
  else
    tui_warn "Could not confirm replica ${_rname} status (PE may be down)."
    tui_warn "Confirm it is an ACTIVE replica before continuing."
  fi
  echo

  # ── 4. Safety backup of the primary ──────────────────────────────────────
  tui_section "Safety backup of the primary"
  tui_info "A recovery backup of the primary is taken before promoting, so you can"
  tui_info "restore if the test goes wrong."
  local _dr_backup_dir="${backup_output_directory:-/tmp}"
  tui_prompt _dr_backup_dir "Backup output directory" "$_dr_backup_dir"
  backup_output_directory="$_dr_backup_dir"
  backup_type="recovery"
  build_backup_params
  tui_confirm _run_dr_backup "Take the safety backup now?" "Y"
  if [[ "$_run_dr_backup" == "true" ]]; then
    tui_section "Running peadm::backup (safety)"
    ${BOLT} plan run peadm::backup --params "@${PARAMS_FILE}" $(bolt_inv)
    local _bstatus=$?
    if [[ $_bstatus -ne 0 ]]; then
      tui_err "Safety backup failed (exit $_bstatus).  Aborting DR test."
      return $_bstatus
    fi
    tui_ok "Safety backup completed"
  else
    tui_warn "Skipping safety backup.  Proceeding without a fresh backup."
  fi
  echo

  # ── 5. Promote the replica (failover) ────────────────────────────────────
  tui_section "Promote replica → primary (failover)"
  tui_warn "This makes ${_rname} the primary.  The original primary ${_pname} becomes"
  tui_warn "a replica.  Agents will be redirected to ${_rname}."
  tui_confirm _do_promote "Promote ${_rname} to primary now?" "N"
  if [[ "$_do_promote" != "true" ]]; then
    tui_info "DR test aborted before promotion.  No changes were made."
    return 0
  fi
  tui_info "Running 'puppet infrastructure promote replica' on ${_rname} …"
  tui_info "(this can take several minutes; output streams below)"
  # peadm uses --topology mono-with-compile for replica promote (the only
  # topology the promote command accepts non-interactively).
  if ${BOLT} command run "/opt/puppetlabs/bin/puppet infrastructure promote replica --topology mono-with-compile --yes" --targets "$_rname" $(bolt_inv); then
    tui_ok "Promotion command completed on ${_rname}"
  else
    tui_err "Promotion command failed on ${_rname}."
    tui_err "The DR test cannot continue.  Check the replica and re-run."
    return 1
  fi
  echo

  # ── 6. Verify the promoted replica ───────────────────────────────────────
  tui_section "Verify promoted replica"
  tui_info "Waiting ~30s for services to settle, then checking ${_rname} …"
  sleep 30
  if ${BOLT} command run "/opt/puppetlabs/bin/puppet infra status" --targets "$_rname" $(bolt_inv); then
    tui_ok "${_rname} is now serving as primary"
  else
    tui_warn "${_rname} did not report fully operational.  Inspect it manually."
  fi
  echo

  # ── 7. Fail back to the original primary ────────────────────────────────
  tui_section "Fail back to original primary"
  tui_warn "To complete the DR test, the original primary ${_pname} is promoted back."
  tui_confirm _do_failback "Fail back: promote ${_pname} to primary again?" "N"
  if [[ "$_do_failback" != "true" ]]; then
    tui_warn "DR test left in the FAILED-OVER state: ${_rname} is now primary."
    tui_warn "To fail back later, run 'puppet infrastructure promote replica' on ${_pname}."
    append_helper_md "Replica DR Test (failover only)" \
      "Promoted replica ${_rname} to primary.  Original primary ${_pname} left as replica."
    return 0
  fi
  tui_info "Running 'puppet infrastructure promote replica' on ${_pname} …"
  if ${BOLT} command run "/opt/puppetlabs/bin/puppet infrastructure promote replica --topology mono-with-compile --yes" --targets "$_pname" $(bolt_inv); then
    tui_ok "Fail-back promotion completed on ${_pname}"
  else
    tui_err "Fail-back promotion failed on ${_pname}."
    tui_err "The cluster is in a failed-over state (${_rname} is primary)."
    return 1
  fi
  echo

  # ── 8. Verify failback ──────────────────────────────────────────────────
  tui_section "Verify failback"
  tui_info "Waiting ~30s for services to settle, then checking ${_pname} …"
  sleep 30
  if ${BOLT} command run "/opt/puppetlabs/bin/puppet infra status" --targets "$_pname" $(bolt_inv); then
    tui_ok "${_pname} is serving as primary again"
  else
    tui_warn "${_pname} did not report fully operational after failback."
  fi
  echo

  # ── 9. Record run ────────────────────────────────────────────────────────
  append_helper_md "Replica DR Test (failover + failback)" \
    "Primary:  ${primary_host}" \
    "Replica:  ${replica_host}" \
    "Result:   Promoted replica to primary, verified, then failed back to original primary."
  tui_blank
  tui_ok "Replica DR test completed (failover + failback)."
  tui_info "For a record of this run, see ${script_dir}/helper.md"
}

# ──────────────────────────────────────────────────────────────────────────────
# BUILD INVENTORY.YAML for the replica DR test (primary + replica)
# ──────────────────────────────────────────────────────────────────────────────
build_dr_test_inventory() {
  local inv="${script_dir}/inventory.yaml"
  _write_pe_inventory "$inv" "$primary_host" "$replica_host"
  tui_ok "inventory.yaml written for replica DR test"
  tui_blank
  tui_info "Targets in inventory:"
  grep '      - ' "$inv" | while read -r _line; do
    tui_info "  $_line"
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN ORCHESTRATOR
# ──────────────────────────────────────────────────────────────────────────────
helper_swing_migrate() {
  tui_section "Swing Migration Helper (backup → provision → restore → finalize)"
  tui_info "Builds a NEW PE infra, backs up the current one, restores that backup"
  tui_info "onto the new infra, then promotes the new infra to be the current defaults."
  echo
  tui_warn "⚠  Builds a NEW infra in a DEDICATED VM, leaving the current infra running."
  tui_warn "For docker/cloud, the new infra is provisioned into its own fresh"
  tui_warn "Docker-host VM (separate terraform state), so provisioning NEVER destroys"
  tui_warn "the current infra or its containers.  To stay safe this helper still"
  tui_warn "backs up the current infra and offloads the tarball to the wizard host"
  tui_warn "BEFORE provisioning anything (belt & braces)."
  echo
  tui_info "If a backup cannot be taken and offloaded, the helper refuses to continue."
  echo

  # ── 0. Capture OLD infra details (before anything changes) ────────────────
  local _old_defaults="$defaults_file"
  local _old_prefix="${nodeprefix}"
  configure_ssh_key

  # ── Docker/cloud connection (same Docker host hosts old AND new infra) ────
  local _is_docker="no"
  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    _is_docker="yes"
    _resolve_docker_host_ip "${_old_prefix}"
    if [[ -z "$DOCKER_HOST_IP" ]]; then
      tui_err "Docker host IP is required"; return 1
    fi
    DOCKER_NET="${docker_network:-${_old_prefix}net}"
    DOCKER_IMG="${docker_image:-${docker_default_tag}}"
    dh_ssh() {
      ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=20 "${ssh_user}@${DOCKER_HOST_IP}" "$@"
    }
  fi

  local _old_primary; _old_primary=$(build_fqdn core0)
  if [[ "$_is_docker" == "yes" ]]; then _old_primary="$(_docker_uri "$_old_primary")"; fi
  tui_ok "Current (old) infra primary: ${BOLD}${_old_primary}${RESET}"

  # ── Setup: label + new prefix + swing defaults file ───────────────────────
  tui_section "Setup – swing identity"
  local _label="${swing_label:-swing1}"
  tui_prompt _label "Swing label (new defaults file name)" "$_label"
  swing_label="$_label"

  local _new_prefix="${swing_new_prefix:-${_old_prefix}2}"
  tui_prompt _new_prefix "NEW node prefix (must differ from '${_old_prefix}')" "$_new_prefix"
  swing_new_prefix="$_new_prefix"
  if [[ "$swing_new_prefix" == "$_old_prefix" ]]; then
    tui_err "New prefix must differ from the old prefix '${_old_prefix}'"; return 1
  fi

  local _swing_file="${script_dir}/setup_wizard_defaults.${swing_label}.json"
  local _swing_bakdir="${script_dir}/backups"
  tui_ok "New settings will be saved to: ${BOLD}${_swing_file}${RESET}"
  tui_ok "Backups will be offloaded to:   ${BOLD}${_swing_bakdir}${RESET}"
  echo

  # ═══ PHASE 1 – Backup the OLD infra + offload (REQUIRED, hard gate) ═══════
  tui_section "Phase 1 – Backup current (old) infra + offload"
  tui_info "A backup is taken of the CURRENT infra and copied off it to the wizard"
  tui_info "host.  This MUST succeed before anything is provisioned."
  tui_confirm _go_backup "Back up the CURRENT infra (${_old_primary}) now?" "Y"
  if [[ "$_go_backup" != "true" ]]; then
    tui_err "Aborting – the current infra will be destroyed during provisioning,"
    tui_err "so a backup + offload is mandatory.  Re-run when ready."
    return 1
  fi

  primary_host="$_old_primary"
  backup_type="recovery"
  backup_items_json="{}"
  backup_output_directory="/tmp"
  build_backup_params
  _write_pe_inventory "${script_dir}/inventory.yaml" "$primary_host"
  local _backup_path
  _backup_path=$(_swing_run_plan_capture_path "peadm::backup")
  if [[ -z "$_backup_path" ]]; then
    tui_err "No backup path captured – cannot continue safely."; return 1
  fi
  tui_ok "Old-infra backup created at: ${_backup_path}"

  # Offload the tarball OFF the old infra (it will be destroyed on provisioning).
  local _offloaded
  if ! _offloaded=$(_swing_offload "$_old_primary" "$_backup_path"); then
    tui_err "Backup was NOT offloaded – refusing to proceed.  The old infra would"
    tui_err "be destroyed with the backup still on it.  Offload ${_backup_path} first."
    return 1
  fi
  tui_ok "Backup is safe on the wizard host: ${_offloaded}"

  # ═══ PHASE 2 – Provision the NEW infra (dedicated VM; source stays running) ════
  tui_section "Phase 2 – Provision new infra (builds a NEW VM, keeps the source)"
  tui_info "The new infra (${swing_new_prefix}) is provisioned into a DEDICATED"
  tui_info "terraform state (${script_dir}/terraform/swing-${swing_label}).  It gets its"
  tui_info "own fresh Docker-host VM, so the CURRENT infra and its containers are"
  tui_info "LEFT RUNNING and are never destroyed by provisioning."
  tui_info "The backup is also safe at: ${_offloaded}"
  echo

  # Seed the swing file from current defaults, forcing the new prefix and no
  # pre-provision destroy.  Point the swing's provisioning at a SEPARATE
  # terraform state dir so apply creates the NEW VM alongside the old one
  # instead of replacing (destroying) the current Docker-host VM.
  jq '.nodeprefix = $p | .del_now = false' --arg p "$swing_new_prefix" "$_old_defaults" > "$_swing_file"
  chmod 600 "$_swing_file"
  tui_ok "Seeded swing defaults (prefix=${swing_new_prefix}, del_now=false)"

  tui_confirm _go_provision "Provision the NEW infra now (new VM, current infra stays up)?" "Y"
  if [[ "$_go_provision" != "true" ]]; then
    tui_info "Stopped before provisioning.  Backup is safe at ${_offloaded}."
    tui_info "Swing defaults staged at ${_swing_file}.  Re-run this helper to continue."
    return 0
  fi

  # Idempotency: if the new infra is ALREADY provisioned (e.g. a previous swing
  # run built it), skip re-provisioning so we don't rebuild/break it.  Detect by
  # loading the swing defaults and checking whether the new primary is reachable
  # with PE installed.
  defaults_file="$_swing_file"
  load_defaults
  local _new_primary_pre; _new_primary_pre=$(build_fqdn core0)
  if [[ "$_is_docker" == "yes" ]]; then
    DOCKER_HOST_IP=""
    _DOCKER_PORT_MAP=""
    _DOCKER_PORT_MAP_LOADED="0"
    _resolve_docker_host_ip "${nodeprefix}"
    _new_primary_pre="$(_docker_uri "$_new_primary_pre")"
  fi
  defaults_file="$_old_defaults"
  local _already_up="no"
  if [[ -n "$_new_primary_pre" ]]; then
    local _ph _pp
    _ph=$(_hostname_only "$_new_primary_pre"); _pp=$(_uri_port "$_new_primary_pre")
    if ssh -p "$_pp" -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "${ssh_user}@${_ph}" 'test -d /opt/puppetlabs && echo up' 2>/dev/null | grep -q up; then
      _already_up="yes"
    fi
  fi

  # Re-run the wizard as a CHILD so it uses the swing defaults file and does NOT
  # clobber the current defaults json.  Pointing PE_TF_DIR at the swing's own
  # terraform dir isolates its state, so the current infra's VM is never
  # destroyed/recreated.  Control returns here once it completes.
  local _provision_status=0
  if [[ "$_already_up" == "yes" ]]; then
    tui_confirm _skip_provision "New infra (${_new_primary_pre}) is already provisioned. Skip re-provisioning and continue to restore?" "Y"
    if [[ "$_skip_provision" == "true" ]]; then
      tui_ok "Skipping re-provisioning – continuing to restore."
    else
      tui_info "Re-provisioning the new infra (rebuilds containers + reinstalls PE)…"
      PE_TF_DIR="${script_dir}/terraform/swing-${swing_label}" \
      PE_DEFAULTS_FILE="$_swing_file" bash "${script_dir}/pelab.sh" provision
      _provision_status=$?
    fi
  else
    PE_TF_DIR="${script_dir}/terraform/swing-${swing_label}" \
    PE_DEFAULTS_FILE="$_swing_file" bash "${script_dir}/pelab.sh" provision
    _provision_status=$?
  fi
  if [[ $_provision_status -ne 0 ]]; then
    tui_err "Provisioning of the new infra returned non-zero (exit $_provision_status)."
    return $_provision_status
  fi

  # Load the swing file so this process now knows the NEW infra's details.
  defaults_file="$_swing_file"
  load_defaults
  # The new infra runs on its OWN fresh Docker-host VM, so re-resolve the host IP
  # to the NEW VM (and drop any cached port map from the OLD host).  Otherwise
  # the global DOCKER_HOST_IP set at swing start (old infra) would be reused and
  # `_docker_port_for` would query the OLD VM, which has none of the new
  # containers → empty port → restore fails.
  if [[ "$_is_docker" == "yes" ]]; then
    DOCKER_HOST_IP=""
    _DOCKER_PORT_MAP=""
    _DOCKER_PORT_MAP_LOADED="0"
    _resolve_docker_host_ip "${nodeprefix}"
    if [[ -z "$DOCKER_HOST_IP" ]]; then
      tui_err "Cannot resolve the NEW Docker host IP for prefix ${nodeprefix}"
      return 1
    fi
  fi
  # Recompute node counts from instype/enable_dr (mirrors pelab.sh step 11).
  core_count=1; compiler_count=0; haproxy_count=0
  case "$instype" in
    LARGE) core_count=1; compiler_count=2; haproxy_count=1; [[ "$enable_dr" == "true" ]] && core_count=2 ;;
    XL)    core_count=2; compiler_count=2; haproxy_count=1; [[ "$enable_dr" == "true" ]] && core_count=4 ;;
  esac
  node_count=$core_count

  local _new_primary; _new_primary=$(build_fqdn core0)
  if [[ "$_is_docker" == "yes" ]]; then _new_primary="$(_docker_uri "$_new_primary")"; fi
  local _new_prefix2="${nodeprefix}"
  defaults_file="$_old_defaults"
  tui_ok "New infra primary: ${BOLD}${_new_primary}${RESET}"
  echo
  tui_info "New infra is provisioned.  Settings saved to ${_swing_file}."

  # ═══ PHASE 3 – Restore the backup into the NEW infra ═════════════════════
  tui_section "Phase 3 – Restore backup into new infra"
  tui_warn "Restore stops/restarts PE services on the new infra.  This can take minutes."
  tui_confirm _go_restore "Restore the backup into the NEW infra (${_new_primary}) now?" "Y"
  if [[ "$_go_restore" != "true" ]]; then
    tui_info "Skipping restore.  Backup is safe at ${_offloaded}."
    return 0
  fi

  # Load the offloaded backup from the wizard host onto the new primary.
  local _restore_input
  if ! _restore_input=$(_swing_load_onto "$_new_primary" "$_offloaded"); then
    tui_prompt _restore_input "Path of the backup ON the new primary" ""
    if [[ -z "$_restore_input" ]]; then
      tui_err "No restore input path – cannot continue."; return 1
    fi
  fi

  primary_host="$_new_primary"
  restore_type="recovery"
  restore_input_file="$_restore_input"
  restore_items_json="{}"
  restore_console_password=""
  restore_extra_hosts="$(_swing_cluster_hosts)"
  # _swing_cluster_hosts already includes the primary; build a host list without
  # duplicate primary for the inventory.
  local _restore_hosts=("$_new_primary")
  local _eh _nm
  for _eh in $restore_extra_hosts; do
    _nm=$(_hostname_only "$_eh")
    if [[ "$_nm" != "$(_hostname_only "$_new_primary")" ]]; then
      _restore_hosts+=("$_eh")
    fi
  done
  build_restore_params
  _write_pe_inventory "${script_dir}/inventory.yaml" "${_restore_hosts[@]}"

  tui_section "Running peadm::restore"
  local _restore_status
  tui_info "Restore output streams below and can take several minutes (it is expected"
  tui_info "to end with an error about the OLD hostname – that is normal, see below)."
  # Run under an `if` so set -e does NOT kill the script when the restore returns
  # non-zero.  Bolt runs DIRECTLY (no pipe/tee): piping would buffer its output and
  # make the restore look hung for several minutes.  The `if` captures the exit
  # status safely.
  if ${BOLT} plan run peadm::restore --params "@${PARAMS_FILE}" $(bolt_inv); then
    _restore_status=0
  else
    _restore_status=$?
  fi
  if [[ $_restore_status -ne 0 ]]; then
    # A `recovery` restore imports the OLD infra's config wholesale, so the new
    # primary's server_list still points at the OLD hostname (e.g. core0).
    # The restore DATA import completes, but the plan's final wait_for_puppet_run
    # check cannot reach that old hostname and fails.  That is EXPECTED for a
    # recovery restore onto a renamed cluster.  Phase 4 rebrands the config and
    # validates the infra is sound (via `puppet infra status`), so a non-zero
    # restore status is tolerated here and Phase 4 is the safety net.
    tui_warn "peadm::restore returned exit $_restore_status (expected for a recovery"
    tui_warn "restore onto a renamed cluster: its final puppet-check still points at"
    tui_warn "the OLD hostname ${_old_prefix}core0).  The data import completed."
    tui_warn "Phase 4 will rebrand the config and verify the infra.  Continuing…"
  fi
  tui_ok "Restore into new infra completed"

  # Copy the OLD infra's hiera-eyaml keys to the new primary so the restored
  # (old-infra) hiera data can be decrypted.
  _swing_copy_eyaml_keys "$_old_primary" "$_new_primary"

  # ═══ PHASE 4 – Node migration (rebrand restored config) ═══════════════════
  tui_section "Phase 4 – Migrate nodes to the new infra"
  tui_info "Rewriting the restored (old-infra) hostnames to the new infra's"
  tui_info "hostnames in the PE config, restarting services, and converging Puppet."
  if ! _swing_migrate_nodes "$_new_primary" "$_old_prefix" "$_new_prefix2"; then
    tui_err "Phase 4 node migration failed – cannot finalize."
    tui_info "Backup safe at ${_offloaded}.  Re-run to retry, or migrate manually."
    return 1
  fi
  echo
  tui_confirm _go_finalize "Continue to finalize (promote new infra + verify backup)?" "Y"
  if [[ "$_go_finalize" != "true" ]]; then
    tui_info "Stopped after Phase 3.  Backup safe at ${_offloaded}.  Finalize manually or re-run."
    return 0
  fi

  # ═══ PHASE 5 – Finalize ══════════════════════════════════════════════════
  tui_section "Phase 5 – Finalize"
  cp "$_swing_file" "$_old_defaults"
  chmod 600 "$_old_defaults"
  tui_ok "Promoted new infra: ${_swing_file} → $(basename "$_old_defaults")"

  # Verify: take a fresh backup of the NEW infra to confirm it is safe/sound.
  tui_info "Taking a verification backup of the new infra…"
  primary_host="$_new_primary"
  backup_type="recovery"
  backup_items_json="{}"
  backup_output_directory="/tmp"
  build_backup_params
  _write_pe_inventory "${script_dir}/inventory.yaml" "$primary_host"
  local _verify_path
  _verify_path=$(_swing_run_plan_capture_path "peadm::backup") || true
  if [[ -n "$_verify_path" ]]; then
    tui_ok "Verification backup of new infra: ${_verify_path}"
  else
    tui_warn "Verification backup did not report a path – check the plan output."
  fi

  # ── helper.md audit record ──────────────────────────────────────────────
  append_helper_md "Swing Migration" \
    "Old infra primary:  ${_old_primary} (prefix ${_old_prefix})" \
    "New infra primary:  ${_new_primary} (prefix ${_new_prefix2})" \
    "Swing defaults:     ${_swing_file}" \
    "Backup (old):       ${_backup_path}" \
    "Offloaded to:       ${_offloaded}" \
    "Restore input:      ${_restore_input:-<none>}" \
    "Verification backup:${_verify_path:-<not reported>}" \
    "Status:             phases 1-4 complete; node migration + restore verified" \
    "                     (restore final-check tolerated: recovery restore leaves old" \
    "                     server_list; Phase 4 rebranded it)" \
    "" \
    "NEXT STEPS (manual):" \
    "  1. Decommission the OLD infra (${_old_prefix}) once traffic has swung"

  tui_done
  tui_section "Swing Migration – Action Required"
  tui_summary_open
  tui_summary_row "New infra primary" "$_new_primary"
  tui_summary_row "Old infra primary" "$_old_primary"
  tui_summary_row "Backup (offloaded)" "$_offloaded"
  tui_summary_row "New defaults"      "$(basename "$_old_defaults") (promoted)"
  tui_summary_close
  tui_warn "You now need to:"
  tui_warn "  1) DECOMMISSION the old infra (${_old_prefix}) once the swing is confirmed."
  tui_info "Full details + audit recorded in ${script_dir}/helper.md"
}

# ──────────────────────────────────────────────────────────────────────────────
# SWING MIGRATION HELPER – peadm::migrate variant
# Same as helper_swing_migrate (build a parallel infra) but migrates the current
# PE installation onto the new infra using the peadm::migrate plan (backup →
# install → restore → purge in ONE plan) instead of the manual backup→restore→
# node-migration flow.
# ──────────────────────────────────────────────────────────────────────────────
helper_swing_migrate_peadm() {
  tui_section "Swing Migration Helper (peadm::migrate)"
  tui_info "Builds a NEW PE infra, then migrates the current PE installation onto it"
  tui_info "using the peadm::migrate plan (backup → install → restore → purge in one plan)."
  echo
  tui_warn "⚠  Builds a NEW infra in a DEDICATED VM, leaving the current infra running."
  tui_warn "For docker/cloud, the new infra is provisioned into its own fresh"
  tui_warn "Docker-host VM (separate terraform state), so provisioning NEVER destroys"
  tui_warn "the current infra or its containers.  To stay safe this helper still"
  tui_warn "backs up the current infra and offloads the tarball to the wizard host"
  tui_warn "BEFORE provisioning anything (belt & braces)."
  echo
  tui_info "peadm::migrate installs PE on the NEW primary with download_mode=direct,"
  tui_info "so the NEW primary must be able to reach the internet to download the"
  tui_info "installer.  If your lab is air-gapped, use the standard swing-migrate"
  tui_info "helper instead."
  echo

  # ── 0. Capture OLD infra details (before anything changes) ────────────────
  local _old_defaults="$defaults_file"
  local _old_prefix="${nodeprefix}"
  configure_ssh_key

  # ── Docker/cloud connection (same Docker host hosts old AND new infra) ────
  local _is_docker="no"
  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    _is_docker="yes"
    _resolve_docker_host_ip "${_old_prefix}"
    if [[ -z "$DOCKER_HOST_IP" ]]; then
      tui_err "Docker host IP is required"; return 1
    fi
    DOCKER_NET="${docker_network:-${_old_prefix}net}"
    DOCKER_IMG="${docker_image:-${docker_default_tag}}"
    dh_ssh() {
      ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=20 "${ssh_user}@${DOCKER_HOST_IP}" "$@"
    }
  fi

  local _old_primary; _old_primary=$(build_fqdn core0)
  if [[ "$_is_docker" == "yes" ]]; then _old_primary="$(_docker_uri "$_old_primary")"; fi
  tui_ok "Current (old) infra primary: ${BOLD}${_old_primary}${RESET}"

  # ── Setup: label + new prefix + swing defaults file ───────────────────────
  tui_section "Setup – swing identity"
  local _label="${swing_label:-swing1}"
  tui_prompt _label "Swing label (new defaults file name)" "$_label"
  swing_label="$_label"

  local _new_prefix="${swing_new_prefix:-${_old_prefix}2}"
  tui_prompt _new_prefix "NEW node prefix (must differ from '${_old_prefix}')" "$_new_prefix"
  swing_new_prefix="$_new_prefix"
  if [[ "$swing_new_prefix" == "$_old_prefix" ]]; then
    tui_err "New prefix must differ from the old prefix '${_old_prefix}'"; return 1
  fi

  local _swing_file="${script_dir}/setup_wizard_defaults.${swing_label}.json"
  local _swing_bakdir="${script_dir}/backups"
  tui_ok "New settings will be saved to: ${BOLD}${_swing_file}${RESET}"
  tui_ok "Backups will be offloaded to:   ${BOLD}${_swing_bakdir}${RESET}"
  echo

  # ═══ PHASE 1 – Backup the OLD infra + offload (REQUIRED, hard gate) ═══════
  tui_section "Phase 1 – Backup current (old) infra + offload"
  tui_info "A backup is taken of the CURRENT infra and copied off it to the wizard"
  tui_info "host.  This MUST succeed before anything is provisioned."
  tui_confirm _go_backup "Back up the CURRENT infra (${_old_primary}) now?" "Y"
  if [[ "$_go_backup" != "true" ]]; then
    tui_err "Aborting – the current infra will be destroyed during provisioning,"
    tui_err "so a backup + offload is mandatory.  Re-run when ready."
    return 1
  fi

  primary_host="$_old_primary"
  backup_type="recovery"
  backup_items_json="{}"
  backup_output_directory="/tmp"
  build_backup_params
  _write_pe_inventory "${script_dir}/inventory.yaml" "$primary_host"
  local _backup_path
  _backup_path=$(_swing_run_plan_capture_path "peadm::backup")
  if [[ -z "$_backup_path" ]]; then
    tui_err "No backup path captured – cannot continue safely."; return 1
  fi
  tui_ok "Old-infra backup created at: ${_backup_path}"

  # Offload the tarball OFF the old infra (it will be destroyed on provisioning).
  local _offloaded
  if ! _offloaded=$(_swing_offload "$_old_primary" "$_backup_path"); then
    tui_err "Backup was NOT offloaded – refusing to proceed.  The old infra would"
    tui_err "be destroyed with the backup still on it.  Offload ${_backup_path} first."
    return 1
  fi
  tui_ok "Backup is safe on the wizard host: ${_offloaded}"

  # ═══ PHASE 2 – Provision the NEW infra (dedicated VM; source stays running) ════
  tui_section "Phase 2 – Provision new infra (builds a NEW VM, keeps the source)"
  tui_info "The new infra (${swing_new_prefix}) is provisioned into a DEDICATED"
  tui_info "terraform state (${script_dir}/terraform/swing-${swing_label}).  It gets its"
  tui_info "own fresh Docker-host VM, so the CURRENT infra and its containers are"
  tui_info "LEFT RUNNING and are never destroyed by provisioning."
  tui_info "The backup is also safe at: ${_offloaded}"
  echo

  # Seed the swing file from current defaults, forcing the new prefix and no
  # pre-provision destroy.  Point the swing's provisioning at a SEPARATE
  # terraform state dir so apply creates the NEW VM alongside the old one
  # instead of replacing (destroying) the current Docker-host VM.
  jq '.nodeprefix = $p | .del_now = false' --arg p "$swing_new_prefix" "$_old_defaults" > "$_swing_file"
  chmod 600 "$_swing_file"
  tui_ok "Seeded swing defaults (prefix=${swing_new_prefix}, del_now=false)"

  tui_confirm _go_provision "Provision the NEW infra now (new VM, current infra stays up)?" "Y"
  if [[ "$_go_provision" != "true" ]]; then
    tui_info "Stopped before provisioning.  Backup is safe at ${_offloaded}."
    tui_info "Swing defaults staged at ${_swing_file}.  Re-run this helper to continue."
    return 0
  fi

  # Idempotency: if the new infra is ALREADY provisioned (e.g. a previous swing
  # run built it), skip re-provisioning so we don't rebuild/break it.  Detect by
  # loading the swing defaults and checking whether the new primary is reachable
  # with PE installed.
  defaults_file="$_swing_file"
  load_defaults
  local _new_primary_pre; _new_primary_pre=$(build_fqdn core0)
  if [[ "$_is_docker" == "yes" ]]; then
    DOCKER_HOST_IP=""
    _DOCKER_PORT_MAP=""
    _DOCKER_PORT_MAP_LOADED="0"
    _resolve_docker_host_ip "${nodeprefix}"
    _new_primary_pre="$(_docker_uri "$_new_primary_pre")"
  fi
  defaults_file="$_old_defaults"
  local _already_up="no"
  if [[ -n "$_new_primary_pre" ]]; then
    local _ph _pp
    _ph=$(_hostname_only "$_new_primary_pre"); _pp=$(_uri_port "$_new_primary_pre")
    if ssh -p "$_pp" -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "${ssh_user}@${_ph}" 'test -d /opt/puppetlabs && echo up' 2>/dev/null | grep -q up; then
      _already_up="yes"
    fi
  fi

  # Re-run the wizard as a CHILD so it uses the swing defaults file and does NOT
  # clobber the current defaults json.  Pointing PE_TF_DIR at the swing's own
  # terraform dir isolates its state, so the current infra's VM is never
  # destroyed/recreated.  Control returns here once it completes.
  local _provision_status=0
  if [[ "$_already_up" == "yes" ]]; then
    tui_confirm _skip_provision "New infra (${_new_primary_pre}) is already provisioned. Skip re-provisioning and continue to migrate?" "Y"
    if [[ "$_skip_provision" == "true" ]]; then
      tui_ok "Skipping re-provisioning – continuing to migrate."
    else
      tui_info "Re-provisioning the new infra (rebuilds containers + reinstalls PE)…"
      PE_TF_DIR="${script_dir}/terraform/swing-${swing_label}" \
      PE_DEFAULTS_FILE="$_swing_file" bash "${script_dir}/pelab.sh" provision
      _provision_status=$?
    fi
  else
    PE_TF_DIR="${script_dir}/terraform/swing-${swing_label}" \
    PE_DEFAULTS_FILE="$_swing_file" bash "${script_dir}/pelab.sh" provision
    _provision_status=$?
  fi
  if [[ $_provision_status -ne 0 ]]; then
    tui_err "Provisioning of the new infra returned non-zero (exit $_provision_status)."
    return $_provision_status
  fi

  # Load the swing file so this process now knows the NEW infra's details.
  defaults_file="$_swing_file"
  load_defaults
  # The new infra runs on its OWN fresh Docker-host VM, so re-resolve the host IP
  # to the NEW VM (and drop any cached port map from the OLD host).  Otherwise
  # the global DOCKER_HOST_IP set at swing start (old infra) would be reused and
  # `_docker_port_for` would query the OLD VM, which has none of the new
  # containers → empty port → migrate fails.
  if [[ "$_is_docker" == "yes" ]]; then
    DOCKER_HOST_IP=""
    _DOCKER_PORT_MAP=""
    _DOCKER_PORT_MAP_LOADED="0"
    _resolve_docker_host_ip "${nodeprefix}"
    if [[ -z "$DOCKER_HOST_IP" ]]; then
      tui_err "Cannot resolve the NEW Docker host IP for prefix ${nodeprefix}"
      return 1
    fi
  fi
  # Recompute node counts from instype/enable_dr (mirrors pelab.sh step 11).
  core_count=1; compiler_count=0; haproxy_count=0
  case "$instype" in
    LARGE) core_count=1; compiler_count=2; haproxy_count=1; [[ "$enable_dr" == "true" ]] && core_count=2 ;;
    XL)    core_count=2; compiler_count=2; haproxy_count=1; [[ "$enable_dr" == "true" ]] && core_count=4 ;;
  esac
  node_count=$core_count

  local _new_primary; _new_primary=$(build_fqdn core0)
  if [[ "$_is_docker" == "yes" ]]; then _new_primary="$(_docker_uri "$_new_primary")"; fi
  local _new_prefix2="${nodeprefix}"
  defaults_file="$_old_defaults"
  tui_ok "New infra primary: ${BOLD}${_new_primary}${RESET}"
  echo
  tui_info "New infra is provisioned.  Settings saved to ${_swing_file}."

  # ═══ PHASE 3 – Migrate via peadm::migrate ═════════════════════════════════
  tui_section "Phase 3 – Migrate via peadm::migrate"
  tui_info "The peadm::migrate plan backs up the OLD primary (migration type),"
  tui_info "installs PE on the NEW primary, restores the data, and purges the old"
  tui_info "nodes – all in one plan.  It needs the OLD and NEW primaries reachable."
  echo

  old_primary_host="$_old_primary"
  new_primary_host="$_new_primary"

  # Optional replica (only meaningful if DR is enabled).
  local _rep_default=""
  if [[ "${enable_dr:-false}" == "true" ]]; then
    _rep_default=$(build_fqdn core1)
    [[ "$_is_docker" == "yes" ]] && _rep_default="$(_docker_uri "$_rep_default")"
  fi
  tui_prompt migrate_replica_host "NEW replica host (optional, blank to skip)" "$_rep_default"
  [[ -n "$migrate_replica_host" && "$_is_docker" == "yes" ]] && migrate_replica_host="$(_docker_uri "$migrate_replica_host")"

  # Optional upgrade version.
  tui_prompt migrate_upgrade_version "Upgrade PE version after migrate (optional, blank to keep old version)" ""

  # LAB BUILD: peadm::migrate runs its in-plan upgrade with
  # permit_unsafe_versions HARDCODED to false (no parameter to override), so a
  # version peadm doesn't know would abort the WHOLE migrate.  Split it out:
  # migrate first, then upgrade separately via peadm::upgrade, which always
  # permits any version (permit_unsafe_versions=true).
  local _post_migrate_upgrade=""
  if [[ -n "${migrate_upgrade_version:-}" ]]; then
    local _vn _nn
    _vn=$(printf '%s\n' "$migrate_upgrade_version" | awk -F. '{printf "%d%02d", $1, $2}')
    _nn=$(printf '%s\n' "$peadm_newest" | awk -F. '{printf "%d%02d", $1, $2}')
    if (( _vn > _nn )); then
      _post_migrate_upgrade="$migrate_upgrade_version"
      migrate_upgrade_version=""
      tui_info "PE ${_post_migrate_upgrade} is newer than peadm's known newest (${peadm_newest}) -"
      tui_info "peadm::migrate's in-plan upgrade cannot be version-permitted, so the"
      tui_info "upgrade will run SEPARATELY via peadm::upgrade (permit_unsafe_versions=true)."
    fi
  fi

  tui_confirm _go_migrate "Run peadm::migrate now (old → new)?" "Y"
  if [[ "$_go_migrate" != "true" ]]; then
    tui_info "Skipping migrate.  Backup safe at ${_offloaded}."
    return 0
  fi

  build_migrate_params
  build_migrate_inventory

  tui_section "Running peadm::migrate"
  tui_info "This can take a long time (backup + install + restore + purge).  Output streams below."
  if ${BOLT} plan run peadm::migrate --params "@${PARAMS_FILE}" $(bolt_inv); then
    tui_ok "peadm::migrate completed"
  else
    local _mstatus=$?
    tui_err "peadm::migrate failed (exit $_mstatus).  Check the plan output."
    tui_info "Backup safe at ${_offloaded}.  Re-run to retry, or migrate manually."
    return $_mstatus
  fi
  echo

  # ── Post-migrate upgrade (split out of peadm::migrate for unknown versions) ──
  # Runs whenever the requested upgrade version is newer than peadm knows:
  # peadm::upgrade always receives permit_unsafe_versions=true, so ANY version
  # proceeds regardless of peadm's supported-version list.
  if [[ -n "$_post_migrate_upgrade" ]]; then
    tui_section "Post-migrate upgrade to PE ${_post_migrate_upgrade}"
    tui_info "Running peadm::upgrade with permit_unsafe_versions=true …"
    _write_pe_inventory "${script_dir}/inventory.yaml" "$_new_primary"
    jq -n \
      --arg primary_host "$(_hostname_only "$_new_primary")" \
      --arg version "$_post_migrate_upgrade" \
      '{ primary_host: $primary_host,
         version: $version,
         permit_unsafe_versions: true,
         download_mode: "direct" }' > "${PARAMS_FILE}"
    if ${BOLT} plan run peadm::upgrade --params "@${PARAMS_FILE}" $(bolt_inv); then
      tui_ok "New infra upgraded to PE ${_post_migrate_upgrade}"
    else
      tui_err "peadm::upgrade failed.  The migrate itself completed -"
      tui_info "retry the version bump later with:  ./pelab.sh upgrade"
    fi
  fi
  echo

  # ═══ PHASE 4 – Finalize ══════════════════════════════════════════════════
  tui_section "Phase 4 – Finalize"
  cp "$_swing_file" "$_old_defaults"
  chmod 600 "$_old_defaults"
  tui_ok "Promoted new infra: ${_swing_file} → $(basename "$_old_defaults")"

  # Verify: take a fresh backup of the NEW infra to confirm it is safe/sound.
  tui_info "Taking a verification backup of the new infra…"
  primary_host="$_new_primary"
  backup_type="recovery"
  backup_items_json="{}"
  backup_output_directory="/tmp"
  build_backup_params
  _write_pe_inventory "${script_dir}/inventory.yaml" "$primary_host"
  local _verify_path
  _verify_path=$(_swing_run_plan_capture_path "peadm::backup") || true
  if [[ -n "$_verify_path" ]]; then
    tui_ok "Verification backup of new infra: ${_verify_path}"
  else
    tui_warn "Verification backup did not report a path – check the plan output."
  fi

  # ── helper.md audit record ──────────────────────────────────────────────
  append_helper_md "Swing Migration (peadm::migrate)" \
    "Old infra primary:  ${_old_primary} (prefix ${_old_prefix})" \
    "New infra primary:  ${_new_primary} (prefix ${_new_prefix2})" \
    "Swing defaults:     ${_swing_file}" \
    "Backup (old):       ${_backup_path}" \
    "Offloaded to:       ${_offloaded}" \
    "Replica:            ${migrate_replica_host:-<none>}" \
    "Upgrade version:    ${_post_migrate_upgrade:-${migrate_upgrade_version:-<none>}}" \
    "Verification backup:${_verify_path:-<not reported>}" \
    "Status:             peadm::migrate completed; new infra promoted" \
    "" \
    "NEXT STEPS (manual):" \
    "  1. Decommission the OLD infra (${_old_prefix}) once traffic has swung"

  tui_done
  tui_section "Swing Migration (peadm::migrate) – Action Required"
  tui_summary_open
  tui_summary_row "New infra primary" "$_new_primary"
  tui_summary_row "Old infra primary" "$_old_primary"
  tui_summary_row "Backup (offloaded)" "$_offloaded"
  tui_summary_row "New defaults"      "$(basename "$_old_defaults") (promoted)"
  tui_summary_close
  tui_warn "You now need to:"
  tui_warn "  1) DECOMMISSION the old infra (${_old_prefix}) once the swing is confirmed."
  tui_info "Full details + audit recorded in ${script_dir}/helper.md"
}

# ──────────────────────────────────────────────────────────────────────────────
# BUILD PARAMS.JSON for peadm::migrate
# ──────────────────────────────────────────────────────────────────────────────
build_migrate_params() {
  local _old _new _rep _pg _pgrep _ver
  _old=$(_hostname_only "$old_primary_host")
  _new=$(_hostname_only "$new_primary_host")
  _rep=""; [[ -n "${migrate_replica_host:-}" ]] && _rep=$(_hostname_only "$migrate_replica_host")
  _pg="";  [[ -n "${migrate_primary_postgresql_host:-}" ]] && _pg=$(_hostname_only "$migrate_primary_postgresql_host")
  _pgrep=""; [[ -n "${migrate_replica_postgresql_host:-}" ]] && _pgrep=$(_hostname_only "$migrate_replica_postgresql_host")
  _ver="${migrate_upgrade_version:-}"
  jq -n \
    --arg old "$_old" --arg new "$_new" \
    --arg rep "$_rep" --arg pg "$_pg" --arg pgrep "$_pgrep" --arg ver "$_ver" \
    '{ old_primary_host: $old, new_primary_host: $new }
     + (if $rep   != "" then { replica_host: $rep } else {} end)
     + (if $pg    != "" then { primary_postgresql_host: $pg } else {} end)
     + (if $pgrep != "" then { replica_postgresql_host: $pgrep } else {} end)
     + (if $ver   != "" then { upgrade_version: $ver } else {} end)' > "$PARAMS_FILE"
  tui_ok "migrate params written to ${PARAMS_FILE}"
}

# ──────────────────────────────────────────────────────────────────────────────
# BUILD INVENTORY.YAML for peadm::migrate (old + new + optional replica/pg)
# ──────────────────────────────────────────────────────────────────────────────
build_migrate_inventory() {
  local _hosts=("$old_primary_host" "$new_primary_host")
  local _h
  for _h in "${migrate_replica_host:-}" "${migrate_primary_postgresql_host:-}" "${migrate_replica_postgresql_host:-}"; do
    [[ -n "$_h" ]] && _hosts+=("$_h")
  done
  _write_pe_inventory "${script_dir}/inventory.yaml" "${_hosts[@]}"
  tui_ok "inventory.yaml written for peadm::migrate"
}

# ──────────────────────────────────────────────────────────────────────────────
# OPENAINANO HELPER – (re)install the PE AI ↔ Ollama bridge on the master
# ──────────────────────────────────────────────────────────────────────────────
helper_openainano() {
  tui_section "OpenAINano Helper (PE AI ↔ Ollama bridge)"
  tui_info "Installs/reinstalls the openainano bridge on the master (${nodeprefix}core0)."
  tui_info "It translates PE's AI infra-assistant to a local Ollama instance"
  tui_info "(http://127.0.0.1:11434) and runs on port ${openainano_port}."
  tui_info "Ollama is installed on the master automatically."
  tui_warn "A local model is not powerful enough – you must authenticate and pull a CLOUD model:"
  tui_info "  1. ollama login"
  tui_info "  2. ollama run ${openainano_model}"
  tui_warn "Port ${openainano_port} must be reachable from the PE console."
  if [[ "$use_gitnano" == "true" ]]; then
    tui_warn "NOTE: gitnano's API also uses port 5000 – they conflict.  Disable one."
  fi
  echo

  configure_ssh_key

  # ── Docker/cloud connection (needed for dh_ssh) ───────────────────────────
  local _is_docker="no"
  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    _is_docker="yes"
    _resolve_docker_host_ip "${nodeprefix}"
    if [[ -z "$DOCKER_HOST_IP" ]]; then
      tui_err "Docker host IP is required"; return 1
    fi
    DOCKER_NET="${docker_network:-${nodeprefix}net}"
    DOCKER_IMG="${docker_image:-${docker_default_tag}}"
    dh_ssh() {
      ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=20 "${ssh_user}@${DOCKER_HOST_IP}" "$@"
    }
  fi

  local _master; _master=$(build_fqdn core0)
  if [[ "$_is_docker" == "yes" ]]; then _master="$(_docker_uri "$_master")"; fi

  tui_confirm _go "Install/reinstall openainano on ${_master}?" "Y"
  if [[ "$_go" != "true" ]]; then
    tui_info "Skipped."
    return 0
  fi

  use_openainano="true"
  install_openainano

  append_helper_md "OpenAINano (re)install" \
    "Master:  ${_master}" \
    "Port:    ${openainano_port} (bridges PE AI to local Ollama on 127.0.0.1:11434)" \
    "Ollama:  installed on the master; authenticate + pull a cloud model:" \
    "         ollama login  &&  ollama run ${openainano_model}"
  tui_blank
  tui_ok "openainano (re)install complete on ${_master}."
  tui_info "For a record of this run, see ${script_dir}/helper.md"
}

# ──────────────────────────────────────────────────────────────────────────────
# SSH-KEYS HELPER – print the SSH-key requirements for the target nodes
# ──────────────────────────────────────────────────────────────────────────────
helper_ssh_keys() {
  tui_section "SSH-Key Requirements (target nodes)"
  tui_info "PRIVATE key (${ssh_key_path:-<set in wizard>}) stays on THIS host – used by"
  tui_info "Bolt for all connections.  The target nodes must already accept its PUBLIC"
  tui_info "key, or every SSH/bootstrap step will fail:"
  tui_blank
  tui_warn "On EACH target node, ALL of these must be true:"
  tui_warn "  1. The public key (${ssh_key_path:-<key>}.pub) is present in the ssh_user's"
  tui_warn "     \`~/.ssh/authorized_keys\`  (for root: /root/.ssh/authorized_keys)."
  tui_warn "  2. /etc/ssh/sshd_config has these UNCOMMENTED (not hashed out):"
  tui_warn "       PubkeyAuthentication yes"
  tui_warn "       AuthorizedKeysFile  .ssh/authorized_keys"
  tui_warn "  3. ~/.ssh and ~/.ssh/authorized_keys permissions allow sshd to read the key"
  tui_warn "     (commonly chmod 700 ~/.ssh and chmod 600 ~/.ssh/authorized_keys)."
  tui_blank
  tui_info "Quick check from this host for each target:"
  tui_info "    ssh -i ${ssh_key_path:-<key>} ${ssh_user:-root}@<target> 'cat ~/.ssh/authorized_keys | grep -c \"$(cat ${ssh_key_path:-<key>}.pub 2>/dev/null | awk '{print $2}')\"'"
  tui_info ""
  tui_info "For cloud/VM base-image deployments the wizard prints this and pauses after"
  tui_info "Terraform creates the VMs, so you can add the key / enable PubkeyAuthentication"
  tui_info "before it proceeds."
  echo
  tui_prompt _ssh_any "Press ENTER to return to the menu"
}

# ──────────────────────────────────────────────────────────────────────────────
# HOSTS-SYNC HELPER – push this environment's /etc/hosts entries to other nodes.
# The wizard host already maps each container/FQDN to the Docker-host (or VM)
# internal IP in ITS OWN /etc/hosts.  This helper propagates those same
# <ip> <fqdn> mappings to any other node(s) you want to reach from, so they too
# resolve the environment without manual edits.  Idempotent.
# ──────────────────────────────────────────────────────────────────────────────
helper_hosts_sync() {
  tui_section "Hosts-Sync (/etc/hosts → other nodes)"
  if [[ -z "${nodeprefix:-}" ]]; then
    tui_warn "No nodeprefix loaded (none saved in ${defaults_file:-setup_wizard_defaults.json})."
    tui_warn "Cannot determine which entries belong to this environment."
    return 0
  fi

  # This environment's <ip> <fqdn> mappings currently in THIS host's /etc/hosts.
  local entries
  entries=$(grep -E "${nodeprefix}" /etc/hosts 2>/dev/null | awk '{ print $1, $2 }' | awk '!seen[$0]++')
  if [[ -z "$entries" ]]; then
    tui_warn "No /etc/hosts entries matching prefix '${nodeprefix}' on this wizard host."
    tui_info "They are written when you provision the environment (e.g. Docker-host IP → containers)."
    return 0
  fi

  tui_info "Entries on THIS wizard host (prefix '${nodeprefix}') to push:"
  while IFS= read -r l; do tui_info "    $l"; done <<< "$entries"
  echo

  tui_info "Connections use key ${BOLD}${ssh_key_path:-<key>}${RESET} and user ${BOLD}${ssh_user:-root}${RESET}."
  tui_prompt _hs_targets "Target node(s) (space-separated host/IP)" ""
  [[ -n "${_hs_targets:-}" ]] || { tui_warn "No targets given – nothing to do."; return 0; }

  local _k="${ssh_key_path:-}"
  local _u="${ssh_user:-root}"
  local _ok
  tui_confirm _ok "Continue and append /etc/hosts entries on the target(s)?" "N"
  [[ "$_ok" == "true" ]] || { tui_warn "Skipped – no entries were pushed."; return 0; }

  local _t _done=0
  for _t in $_hs_targets; do
    tui_step "Syncing /etc/hosts to ${_u}@${_t}…"
    # Remote loop reads pushed entries from stdin.  Idempotent: only appends a
    # <ip> <fqdn> mapping whose exact alias isn't already resolved.  Multiple
    # lines sharing an IP are valid in /etc/hosts, so a simple add-if-absent is
    # safe and avoids fragile in-place line rewrites.
    if ssh -i "${_k:-/dev/null}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=12 "${_u}@${_t}" '
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        ip=${line%% *}
        rest=${line#"$ip" }
        [ -n "$rest" ] || continue
        if ! grep -qE "^${ip}[[:space:]]+${rest}([[:space:]]|$)" /etc/hosts; then
          echo "$ip $rest" >> /etc/hosts
          echo "  added: $ip $rest"
        else
          echo "  already present: $ip $rest"
        fi
      done
      echo "  /etc/hosts on $(hostname) is up to date"
    ' <<< "$entries"; then
      _done=1
    else
      tui_warn "SSH to ${_u}@${_t} failed – /etc/hosts not updated."
    fi
  done

  if [[ "$_done" -eq 1 ]]; then
    tui_ok "Hosts-sync complete."
    append_helper_md "Hosts-sync (/etc/hosts → targets)" \
      "prefix = ${nodeprefix}" "targets = ${_hs_targets}" "entries pushed = $(echo "$entries" | wc -l) mapping(s)"
  fi
  echo
}

# ──────────────────────────────────────────────────────────────────────────────
# REPONANO HELPER – (re)install the local apt/yum package repo on the master
# ──────────────────────────────────────────────────────────────────────────────
helper_reponano() {
  tui_section "Reponano Helper (local apt/yum package repo)"
  tui_info "Installs/reinstalls the reponano repo manager on the master (${nodeprefix}core0)."
  tui_info "It hosts a local apt/yum repo on port 3864 (Flask + systemd) that offline"
  tui_info "nodes point their package manager at."
  tui_warn "Requires internet on the master to apt-get install the repo tooling."
  echo

  configure_ssh_key

  # ── Docker/cloud connection (needed for dh_ssh) ───────────────────────────
  local _is_docker="no"
  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    _is_docker="yes"
    _resolve_docker_host_ip "${nodeprefix}"
    if [[ -z "$DOCKER_HOST_IP" ]]; then
      tui_err "Docker host IP is required"; return 1
    fi
    DOCKER_NET="${docker_network:-${nodeprefix}net}"
    DOCKER_IMG="${docker_image:-${docker_default_tag}}"
    dh_ssh() {
      ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=20 "${ssh_user}@${DOCKER_HOST_IP}" "$@"
    }
  fi

  local _master; _master=$(build_fqdn core0)
  if [[ "$_is_docker" == "yes" ]]; then _master="$(_docker_uri "$_master")"; fi

  tui_confirm _go "Install/reinstall reponano on ${_master}?" "Y"
  if [[ "$_go" != "true" ]]; then
    tui_info "Skipped."
    return 0
  fi

  use_reponano="true"
  install_reponano

  append_helper_md "Reponano (re)install" \
    "Master:  ${_master}" \
    "Port:    3864 (local apt/yum package repo)"
  tui_blank
  tui_ok "reponano (re)install complete on ${_master}."
  tui_info "For a record of this run, see ${script_dir}/helper.md"
}

# ──────────────────────────────────────────────────────────────────────────────
# FORGENANO HELPER – (re)install the local Puppet Forge / module mirror
# ──────────────────────────────────────────────────────────────────────────────
helper_forgenano() {
  tui_section "Forgenano Helper (local Puppet Forge / module mirror)"
  tui_info "Installs/reinstalls the forgenano module mirror on the master (${nodeprefix}core0)."
  tui_info "It mirrors Puppet Forge modules to a local repo on port 6157 (Flask + systemd)"
  tui_info "that offline nodes install modules from."
  tui_info "After install it mirrors the control-repo Puppetfile modules into the local"
  tui_info "forge (the Puppetfile itself is left unchanged)."
  tui_warn "Requires internet on the master to apt-get install the tooling and to"
  tui_warn "mirror modules from the public Forge."
  echo

  configure_ssh_key

  # ── Docker/cloud connection (needed for dh_ssh) ───────────────────────────
  local _is_docker="no"
  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    _is_docker="yes"
    _resolve_docker_host_ip "${nodeprefix}"
    if [[ -z "$DOCKER_HOST_IP" ]]; then
      tui_err "Docker host IP is required"; return 1
    fi
    DOCKER_NET="${docker_network:-${nodeprefix}net}"
    DOCKER_IMG="${docker_image:-${docker_default_tag}}"
    dh_ssh() {
      ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=20 "${ssh_user}@${DOCKER_HOST_IP}" "$@"
    }
  fi

  local _master; _master=$(build_fqdn core0)
  if [[ "$_is_docker" == "yes" ]]; then _master="$(_docker_uri "$_master")"; fi

  tui_confirm _go "Install/reinstall forgenano on ${_master}?" "Y"
  if [[ "$_go" != "true" ]]; then
    tui_info "Skipped."
    return 0
  fi

  use_forgenano="true"
  install_forgenano

  append_helper_md "Forgenano (re)install" \
    "Master:  ${_master}" \
    "Port:    6157 (local Puppet Forge / module mirror)"
  tui_blank
  tui_ok "forgenano (re)install complete on ${_master}."
  tui_info "For a record of this run, see ${script_dir}/helper.md"
}

# ──────────────────────────────────────────────────────────────────────────────
# SCANANO HELPER – (re)install the CVE-enabled vulnerability scan bridge
# ──────────────────────────────────────────────────────────────────────────────
helper_scanano() {
  tui_section "Scanano Helper (CVE-enabled vulnerability scan bridge)"
  tui_info "Installs/reinstalls the scanano bridge on the master (${nodeprefix}core0)."
  tui_info "It mimics a Nessus API on port ${scanano_port} (HTTPS) and runs nmap scans"
  tui_info "with the vulners script, exporting results as Nessus XML."
  tui_warn "Requires internet on the master to apt-get install nmap + pip packages."
  echo

  configure_ssh_key

  # ── Docker/cloud connection (needed for dh_ssh) ───────────────────────────
  local _is_docker="no"
  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    _is_docker="yes"
    _resolve_docker_host_ip "${nodeprefix}"
    if [[ -z "$DOCKER_HOST_IP" ]]; then
      tui_err "Docker host IP is required"; return 1
    fi
    DOCKER_NET="${docker_network:-${nodeprefix}net}"
    DOCKER_IMG="${docker_image:-${docker_default_tag}}"
    dh_ssh() {
      ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=20 "${ssh_user}@${DOCKER_HOST_IP}" "$@"
    }
  fi

  local _master; _master=$(build_fqdn core0)
  if [[ "$_is_docker" == "yes" ]]; then _master="$(_docker_uri "$_master")"; fi

  tui_confirm _go "Install/reinstall scanano on ${_master}?" "Y"
  if [[ "$_go" != "true" ]]; then
    tui_info "Skipped."
    return 0
  fi

  use_scanano="true"
  install_scanano

  append_helper_md "Scanano (re)install" \
    "Master:  ${_master}" \
    "Port:    ${scanano_port} (CVE-enabled vuln scan bridge, HTTPS)"
  tui_blank
  tui_ok "scanano (re)install complete on ${_master}."
  tui_info "For a record of this run, see ${script_dir}/helper.md"
}

helper_hieranano() {
  tui_section "Hieranano Helper (Hiera/eyaml web UI)"
  tui_info "Installs/reinstalls hieranano on the master (${nodeprefix}core0)."
  tui_info "It serves a visual Hiera grid + raw editor (with eyaml encrypt/decrypt)"
  tui_info "on port ${hieranano_port} (HTTPS) / ${hieranano_http_port} (HTTP fallback)."
  tui_warn "Requires internet on the master to install python3-venv etc."
  echo

  configure_ssh_key

  # ── Docker/cloud connection (needed for dh_ssh) ───────────────────────────
  local _is_docker="no"
  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    _is_docker="yes"
    _resolve_docker_host_ip "${nodeprefix}"
    if [[ -z "$DOCKER_HOST_IP" ]]; then
      tui_err "Docker host IP is required"; return 1
    fi
    DOCKER_NET="${docker_network:-${nodeprefix}net}"
    DOCKER_IMG="${docker_image:-${docker_default_tag}}"
    dh_ssh() {
      ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=20 "${ssh_user}@$DOCKER_HOST_IP" "$@"
    }
  fi

  local _master; _master=$(build_fqdn core0)
  if [[ "$_is_docker" == "yes" ]]; then _master="$(_docker_uri "$_master")"; fi

  tui_blank
  tui_info "This re-deploys hieranano on ${_master}, picking up the latest app code"
  tui_info "(including the raw-editor Save button)."
  tui_confirm _go "Install/reinstall hieranano on ${_master}?" "Y"
  if [[ "$_go" != "true" ]]; then
    tui_info "Skipped."
    return 0
  fi

  install_hieranano

  append_helper_md "Hieranano (re)install" \
    "Master:  ${_master}" \
    "Port:    ${hieranano_port} (Hiera/eyaml UI, HTTPS)"
  tui_blank
  tui_ok "hieranano (re)install complete on ${_master}."
  tui_info "For a record of this run, see ${script_dir}/helper.md"
}

# ──────────────────────────────────────────────────────────────────────────────
# Remove a compiler from the current environment.
#
# peadm has no remove-compiler plan, so this reverses the pieces add_compilers
# sets up, reusing peadm + the wizard:
#   1. strip the pe_compiler role (peadm::modify_cert_extensions remove pp_auth_role)
#   2. drop the node from the HAProxy round-robin (configure_haproxy exclusion)
#   3. revoke its certificate on the primary (puppetserver ca clean)
#   4. optionally destroy its container / VM
# ──────────────────────────────────────────────────────────────────────────────
helper_remove_compiler() {
  tui_section "Remove Compiler Helper"
  if [[ "$instype" == "STANDARD" ]]; then
    tui_err "STANDARD has no compilers to remove."; return 1
  fi
  tui_info "Removes a compiler from THIS environment: it loses the pe_compiler role,"
  tui_info "is dropped from the HAProxy round-robin, and its certificate is revoked."
  tui_info "You can optionally destroy its container/VM as the final step."
  echo

  configure_ssh_key

  # ── 0. Docker/cloud connection ────────────────────────────────────────────
  local _is_docker="no"
  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    _is_docker="yes"
    _resolve_docker_host_ip "${nodeprefix}"
    if [[ -z "$DOCKER_HOST_IP" ]]; then tui_err "Docker host IP is required"; return 1; fi
    DOCKER_NET="${docker_network:-${nodeprefix}net}"
    DOCKER_IMG="${docker_image:-${docker_default_tag}}"
    dh_ssh() {
      ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=20 "${ssh_user}@${DOCKER_HOST_IP}" "$@"
    }
  fi

  # ── 1. Primary host ───────────────────────────────────────────────────────
  local _primary_default; _primary_default=$(build_fqdn core0)
  [[ "$_is_docker" == "yes" ]] && _primary_default="$(_docker_uri "$_primary_default")"
  tui_prompt primary_host "Primary host" "$_primary_default"
  [[ "$_is_docker" == "yes" ]] && primary_host="$(_docker_uri "$primary_host")"
  local _core0; _core0=$(_hostname_only "$primary_host")
  local _pfqdn; _pfqdn=$(build_fqdn core0)

  # ── 2. Discover compilers (PE role via PuppetDB) ──────────────────────────
  tui_section "Compilers in this environment"
  local _pql='inventory[certname] { trusted.extensions.pp_auth_role = "pe_compiler" }'
  local _raw=""
  if [[ "$_is_docker" == "yes" ]]; then
    _raw=$(dh_ssh "docker exec ${_core0} /opt/puppetlabs/bin/puppet query '${_pql}' 2>/dev/null" 2>/dev/null)
  else
    _raw=$(ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@${_pfqdn}" "/opt/puppetlabs/bin/puppet query '${_pql}' 2>/dev/null" 2>/dev/null)
  fi
  local _comps=() _c
  # Sort so the menu order is deterministic and matches the compiler names
  # (otherwise the user can pick the wrong node by position).
  while IFS= read -r _c; do [[ -n "$_c" ]] && _comps+=("$_c"); done \
    < <(printf '%s' "$_raw" | jq -r '.[].certname' 2>/dev/null | sort)
  # Fallback: running compiler containers (if the PDB query returned nothing).
  if [[ ${#_comps[@]} -eq 0 && "$_is_docker" == "yes" ]]; then
    while IFS= read -r _c; do [[ -n "$_c" ]] && _comps+=("$_c"); done \
      < <(dh_ssh "docker ps --format '{{.Names}}'" 2>/dev/null | grep -E "^${nodeprefix}compiler[0-9]+$" | sort)
  fi
  if [[ ${#_comps[@]} -eq 0 ]]; then
    tui_err "No compilers found in this environment."; return 1
  fi
  local _opts=()
  for _c in "${_comps[@]}"; do _opts+=("${_c}  – remove this compiler"); done
  tui_menu_default _pick "Select the compiler to REMOVE" 1 "${_opts[@]}"
  local _target; _target=$(echo "$_pick" | awk '{print $1}')
  [[ -z "$_target" ]] && { tui_err "No compiler selected"; return 1; }

  tui_warn "Remove compiler ${BOLD}${_target}${RESET} from ${_core0}?  This changes the live cluster."
  tui_confirm _doit "Proceed with removal?" "N"
  [[ "$_doit" != "true" ]] && { tui_info "Aborted – nothing changed."; return 0; }
  echo

  # ── 3. Inventory (primary + target) ───────────────────────────────────────
  local _turi="$_target"
  [[ "$_is_docker" == "yes" ]] && _turi="$(_docker_uri "$_target")"
  cat > "${script_dir}/inventory.yaml" <<EOIY
---
version: 2
groups:
  - name: peadm_nodes
    config:
      transport: ssh
      ssh:
        user: ${ssh_user}
        private-key: ${bolt_ssh_key}
        host-key-check: false
        run-as: root
    targets:
      - name: ${_core0}
        uri: ${primary_host}
      - name: ${_target}
        uri: ${_turi}
EOIY

  # ── 4. Strip the pe_compiler role ─────────────────────────────────────────
  tui_section "Removing the pe_compiler role from ${_target}"
  ${BOLT} plan run peadm::modify_cert_extensions \
    --params "{\"targets\":\"${_target}\",\"primary_host\":\"${_core0}\",\"remove\":[\"pp_auth_role\"]}" \
    --no-host-key-check $(bolt_inv)
  local _rc=$?
  if [[ $_rc -ne 0 ]]; then
    tui_warn "peadm::modify_cert_extensions failed (exit ${_rc}) – continuing with the rest."
  else
    tui_ok "pe_compiler role removed from ${_target}"
  fi

  # ── 5. Drop it from the HAProxy round-robin ───────────────────────────────
  tui_section "Removing ${_target} from the HAProxy round-robin"
  local _hp_primary="$primary_host"
  primary_host="$_core0"
  haproxy_exclude_compilers="$_target"
  configure_haproxy
  primary_host="$_hp_primary"
  unset haproxy_exclude_compilers

  # ── 6. Revoke its certificate on the primary ──────────────────────────────
  tui_section "Revoking ${_target}'s certificate on ${_core0}"
  local _cleancmd="/opt/puppetlabs/bin/puppetserver ca clean --certname ${_target} 2>&1 | tail -2"
  if [[ "$_is_docker" == "yes" ]]; then
    dh_ssh "docker exec ${_core0} bash -c \"${_cleancmd}\"" 2>/dev/null || tui_warn "cert clean returned non-zero (may already be gone)"
    [[ -n "${gcp_dns_suffix:-}" ]] && dh_ssh "docker exec ${_core0} /opt/puppetlabs/bin/puppetserver ca clean --certname ${_target}.${gcp_dns_suffix} 2>&1 | tail -1" 2>/dev/null || true
  else
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@${_pfqdn}" "$_cleancmd" 2>/dev/null || tui_warn "cert clean returned non-zero"
  fi

  # ── 7. Optionally destroy the container/VM ────────────────────────────────
  tui_confirm _rmnode "Also DESTROY the ${_target} container/VM?" "N"
  if [[ "$_rmnode" == "true" ]]; then
    if [[ "$_is_docker" == "yes" ]]; then
      dh_ssh "docker rm -f ${_target} >/dev/null 2>&1" 2>/dev/null || true
      declare -f hosts_remove_name >/dev/null 2>&1 && hosts_remove_name "$_target" || true
      tui_ok "Container ${_target} destroyed"
    else
      tui_warn "Destroy the VM manually, e.g.:  gcloud compute instances delete ${_target}"
    fi
  fi

  tui_ok "Compiler ${_target} removed from ${_core0}"
  tui_info "Re-add a compiler any time with the add-compiler helper."
  append_helper_md "Remove Compiler" \
    "Removed compiler: ${_target}" \
    "Primary: ${_core0}" 2>/dev/null || true
}
