# =============================================================================
# prep.sh  –  extracted from setup.sh (lines 4480-4667)
# Sourced by pelab.sh.  Do not run directly.
# =============================================================================
bootstrap_ssh_trust() {
  tui_section "SSH Trust Bootstrap"
  local pub_key_content
  pub_key_content=$(cat "${ssh_key_path}.pub")
  local core0_fqdn; core0_fqdn=$(build_fqdn core0)

  # Build full target FQDN list
  local all_fqdns=()
  for i in $(seq 0 $((node_count-1)));      do all_fqdns+=("$(build_fqdn "core${i}")"); done
  for i in $(seq 0 $((compiler_count-1))); do all_fqdns+=("$(build_fqdn "compiler${i}")"); done
  [[ "$instype" =~ ^(XL|xl|LARGE|large)$ ]] && all_fqdns+=("$(build_fqdn haproxy)")

  local targets_csv; targets_csv=$(IFS=,; echo "${all_fqdns[*]}")

  tui_info "Ensuring public key on all nodes (deduplicating)…"
  # Idempotent: only appends if key not already present
  ${BOLT} command run \
    "mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
     touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && \
     grep -qxF '${pub_key_content}' /root/.ssh/authorized_keys || \
     echo '${pub_key_content}' >> /root/.ssh/authorized_keys" \
    --targets "$targets_csv" \
    $(bolt_inv)

  tui_ok "Wizard public key confirmed on all nodes"

  # Cross-node SSH trust from primary master
  tui_step "Cross-node SSH trust from primary master (${core0_fqdn})"

  ${BOLT} command run \
    "[ -f /root/.ssh/id_rsa ] || ssh-keygen -t rsa -b 4096 -N '' -f /root/.ssh/id_rsa" \
    --targets "$core0_fqdn" \
    $(bolt_inv)

  local primary_pub
  primary_pub=$(${BOLT} command run "cat /root/.ssh/id_rsa.pub" \
    --targets "$core0_fqdn" \
    $(bolt_inv) --format json \
    | jq -r '.items[0].result.stdout' | tr -d '\n')

  # Distribute primary's key to all nodes
  ${BOLT} command run \
    "grep -qxF '${primary_pub}' /root/.ssh/authorized_keys || \
     echo '${primary_pub}' >> /root/.ssh/authorized_keys" \
    --targets "$targets_csv" \
    $(bolt_inv)

  # Populate known_hosts on primary for all targets
  local space_targets; space_targets=$(IFS=' '; echo "${all_fqdns[*]}")
  ${BOLT} command run \
    "ssh-keyscan ${space_targets} >> /root/.ssh/known_hosts 2>/dev/null && \
     sort -u /root/.ssh/known_hosts -o /root/.ssh/known_hosts" \
    --targets "$core0_fqdn" \
    $(bolt_inv)

  tui_ok "Cross-node SSH trust established"
}

# ──────────────────────────────────────────────────────────────────────────────
# PRE-INSTALL PREP
# ──────────────────────────────────────────────────────────────────────────────
pre_install_prep() {
  tui_section "Pre-install Package Updates"

  if ! command -v git >/dev/null 2>&1; then
    sudo apt-get update -qq && sudo apt-get install -y -qq git
  fi

  ${BOLT} command run \
    'export DEBIAN_FRONTEND=noninteractive; export NEEDRESTART_MODE=a; apt-get update -qq && apt-get upgrade -y -qq -o Dpkg::Options::="--force-confold" && apt-get install -y -qq nano' \
    --targets puppet-enterprise-nodes \
    $(bolt_inv) || true

  ${BOLT} command run "mkdir -p /root/peadm" \
    --targets puppet-enterprise-nodes \
    $(bolt_inv)

  # Local source of the r10k key on the wizard host (for gitnano this differs
  # from the remote path peadm configures r10k to use on the puppetserver).
  local _key_src="${r10k_private_key_source:-$r10k_private_key_file}"
  if [[ -f "$_key_src" ]]; then
    ${BOLT} file upload "$_key_src" /root/peadm/id_rsa \
      --targets puppet-enterprise-nodes \
      $(bolt_inv) || true
    ${BOLT} command run "chmod 600 /root/peadm/id_rsa" \
      --targets puppet-enterprise-nodes \
      $(bolt_inv) || true
    tui_ok "R10K private key distributed"
  else
    tui_warn "R10K private key not found at $_key_src – skipping"
  fi

  # gitnano: pre-place the same r10k key at gitnano's expected path on the
  # master, so gitnano.sh reuses it (it only generates a key if one is absent)
  # and r10k + gitnano share one keypair.
  if [[ "$use_gitnano" == "true" && -f "$_key_src" ]]; then
    local _gcore; _gcore=$(build_fqdn core0)
    ${BOLT} command run "mkdir -p /etc/puppetlabs/puppetserver/ssh" \
      --targets "$_gcore" $(bolt_inv) || true
    ${BOLT} file upload "$_key_src" /etc/puppetlabs/puppetserver/ssh/id-control_repo.rsa \
      --targets "$_gcore" $(bolt_inv) || true
    ${BOLT} command run "chmod 600 /etc/puppetlabs/puppetserver/ssh/id-control_repo.rsa" \
      --targets "$_gcore" $(bolt_inv) || true
    tui_ok "gitnano r10k key pre-placed on master"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# HAPROXY CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────
configure_haproxy() {
  [[ ! "$instype" =~ ^(XL|xl|LARGE|large)$ ]] && return 0

  tui_section "HAProxy Configuration"
  local haproxy_fqdn; haproxy_fqdn=$(build_fqdn haproxy)

  # For docker+cloud the haproxy is a container whose SSH is on a mapped host
  # port (not 22), so Bolt must connect via uri: fqdn:port.  For VM deployments
  # it is a normal VM on port 22, so no port is needed.
  local haproxy_port=""
  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    # Use the ACTUAL mapped host SSH port of the haproxy CONTAINER.  Never use a
    # static role-index guess -- if the guess is wrong Bolt targets the wrong
    # node (e.g. haproxy:2201 is the PRIMARY, not the haproxy container),
    # so xhaproxy/upload fail against a node with no haproxy and no /etc/haproxy.
    if declare -f dh_ssh >/dev/null 2>&1; then
      haproxy_port=$(dh_ssh "docker port ${nodeprefix}haproxy 22 2>/dev/null | head -1 | sed 's/.*://'" 2>/dev/null | tr -dc '0-9')
    fi
    [[ -z "$haproxy_port" ]] && haproxy_port=$(_docker_port_for haproxy 2>/dev/null)
    [[ -z "$haproxy_port" ]] && haproxy_port=$(docker_ssh_port haproxy)
  fi

  local hp_project="${script_dir}/haproxy-bolt-project"
  local hp_inv="--inventoryfile ${hp_project}/inventory.yaml"
  mkdir -p "$hp_project"
  cat > "${hp_project}/inventory.yaml" <<EOHPINV
---
version: 2
groups:
  - name: haproxy
    config:
      transport: ssh
      ssh:
        user: ${ssh_user}
        private-key: ${bolt_ssh_key}
        host-key-check: false
        run-as: root
    targets:
      - name: ${haproxy_fqdn}
        uri: ${haproxy_fqdn}${haproxy_port:+:${haproxy_port}}
EOHPINV

  cat > /tmp/haproxy.cfg <<EOHPCFG
global
    log /dev/log local0
    log /dev/log local1 notice
    maxconn 4096
    daemon
    stats socket /var/run/haproxy.sock mode 660 level admin expose-fd listeners

defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 10s
    timeout client  30s
    timeout server  30s

frontend puppet_front
    bind *:8140
    default_backend puppet_back

backend puppet_back
    mode tcp
    balance roundrobin
    option tcp-check
    server master ${primary_host}:8140 check
EOHPCFG

  if [[ "$enable_dr" == "true" && -n "$replica_host" ]]; then
    echo "    server replica ${replica_host}:8140 check" >> /tmp/haproxy.cfg
  fi

  # Compiler pool: the HAProxy is the nodepool / compiler_pool_address that fronts
  # 8140, so agent traffic must round-robin across every compiler (plus the primary
  # already above).  Each compiler's hostname is in the cert SAN (via
  # compiler_pool_address in params.json), so agents reaching them through the LB
  # pass TLS hostname verification regardless of which compiler serves the request.
  local _ci _cname _skip _ex _hpc
  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]] && declare -f dh_ssh >/dev/null 2>&1; then
    # Enumerate the ACTUAL running compiler containers so the LB only references
    # real nodes (handles churn/re-creation where the index numbering drifts
    # from compiler_count).
    for _cname in $(dh_ssh "docker ps --format '{{.Names}}'" 2>/dev/null \
        | grep -E "^${nodeprefix}compiler[0-9]+$" | sort); do
      _skip=0; for _ex in ${haproxy_exclude_compilers:-}; do [[ "$_ex" == "$_cname" ]] && _skip=1; done
      [[ "$_skip" == 1 ]] && continue
      echo "    server ${_cname} ${_cname}:8140 check" >> /tmp/haproxy.cfg
    done
  else
    for _ci in $(seq 0 $((compiler_count-1))); do
      _hpc="compiler${_ci}"
      _skip=0; for _ex in ${haproxy_exclude_compilers:-}; do [[ "$_ex" == "$_hpc" ]] && _skip=1; done
      [[ "$_skip" == 1 ]] && continue
      echo "    server ${_hpc} $(build_fqdn "$_hpc"):8140 check" >> /tmp/haproxy.cfg
    done
  fi

  if [[ -d "${script_dir}/haproxy-bolt-project" ]]; then
    (cd "${script_dir}/haproxy-bolt-project" && \
      ${BOLT} plan run xhaproxy --targets "$haproxy_fqdn" 2>/dev/null || true)
  fi

  ${BOLT} file upload /tmp/haproxy.cfg /etc/haproxy/haproxy.cfg \
    --targets "$haproxy_fqdn" $hp_inv
  ${BOLT} command run "systemctl reload-or-restart haproxy" \
    --targets "$haproxy_fqdn" $hp_inv

  tui_ok "HAProxy configured on ${haproxy_fqdn}"

  # ── Verify the LB is working as expected ────────────────────────────────
  tui_section "HAProxy verification"
  local _vcmd
  _vcmd="echo '=== configured backend ==='; grep -E '^    server' /etc/haproxy/haproxy.cfg; "
  _vcmd+="echo; echo '=== config syntax ==='; haproxy -c -f /etc/haproxy/haproxy.cfg; "
  _vcmd+="echo; echo '=== backend reachability (8140) ==='; "
  _vcmd+="for s in \$(grep -E '^    server' /etc/haproxy/haproxy.cfg | awk '{print \$3}'); do "
  _vcmd+="  if timeout 3 bash -c \"cat </dev/null >/dev/tcp/\$s/8140\" 2>/dev/null; then echo \"UP:   \$s\"; else echo \"DOWN: \$s\"; fi; done"
  ${BOLT} command run "$_vcmd" --targets "$haproxy_fqdn" $hp_inv
}

# ──────────────────────────────────────────────────────────────────────────────
# PEADM INSTALL
# ──────────────────────────────────────────────────────────────────────────────
