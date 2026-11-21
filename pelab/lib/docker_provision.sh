# =============================================================================
# docker_provision.sh  –  extracted from setup.sh (lines 4160-4479)
# Sourced by pelab.sh.  Do not run directly.
# =============================================================================

# IP of a container on its Docker network (local docker = the wizard host's own
# docker; cloud = ssh to the Docker host first).  Used to build the internal
# FQDN->IP map that gets written into every container's /etc/hosts.
_docker_container_ip() {
  local cname="$1"
  if [[ "$docker_host" == "cloud" ]]; then
    dh_ssh "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $cname" 2>/dev/null
  else
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cname" 2>/dev/null
  fi
}

# Build the "<container-fqdn> <container-ip>" mapping lines for every PE node
# plus the test node, as a plain <ip> <fqdn> per line.  Docker's embedded DNS
# only resolves short container names, so the .internal FQDNs used by PE (and
# the nodepool / compiler_pool_address) have to be pinned in /etc/hosts inside
# each container.
docker_etc_hosts_mappings() {
  local role cname ip fqdn
  for role in $(docker_roles); do
    cname="${nodeprefix}${role}"
    ip=$(_docker_container_ip "$cname")
    [[ -n "$ip" ]] || continue
    fqdn=$(build_fqdn "$role")
    printf '%s %s\n' "$ip" "$fqdn"
  done
  local tn="${nodeprefix}test"
  local tip; tip=$(_docker_container_ip "$tn")
  if [[ -n "$tip" ]]; then
    printf '%s %s\n' "$tip" "$(build_fqdn test)"
  fi
}

# Write the FQDN->IP map into one container's /etc/hosts (idempotent: skips
# lines already present, so re-runs / re-provisioning don't accumulate).  The
# script is streamed over stdin via bash -s, avoiding fragile multi-level shell
# quoting through dh_ssh / docker exec.
docker_etc_hosts_apply_one() {
  local cname="$1" mappings="$2"
  local script
  script='#!/bin/bash
while IFS= read -r line; do
  [ -n "$line" ] || continue
  ip=${line%% *}
  fqdn=${line#* }
  ipre=${ip//./\\.}
  grep -qE "^${ipre}[[:space:]]+${fqdn}([[:space:]]|$)" /etc/hosts \
    || echo "$ip $fqdn" >> /etc/hosts
done
'
  script+="$mappings"
  if [[ "$docker_host" == "cloud" ]]; then
    printf '%s' "$script" | dh_ssh "docker exec -i $cname bash -s"
  else
    printf '%s' "$script" | docker exec -i "$cname" bash -s
  fi
}

# Pin every node's FQDN->IP into each container's /etc/hosts so the nodepool
# (haproxy) and peer .internal FQDNs resolve inside the containers.  Best-effort:
# a failure on one container is reported, not fatal.
docker_etc_hosts_provision() {
  [[ "$instype" =~ ^(XL|LARGE)$ ]] || return 0
  local mappings; mappings=$(docker_etc_hosts_mappings)
  [[ -n "$mappings" ]] || return 0
  tui_section "Pinning internal FQDNs into container /etc/hosts"
  local role cname extra
  for role in $(docker_roles); do
    cname="${nodeprefix}${role}"
    docker_etc_hosts_apply_one "$cname" "$mappings" \
      || tui_warn "hosts pin failed for ${cname}"
  done
  docker_etc_hosts_apply_one "${nodeprefix}test" "$mappings" \
    || tui_warn "hosts pin failed for ${nodeprefix}test"
  tui_ok "Internal FQDNs pinned into all container /etc/hosts"
}

docker_provision() {
  tui_section "Docker Provisioning"
  local net="${docker_network:-${nodeprefix}net}"
  docker network create "$net" 2>/dev/null || true

  # Ensure the container base image exists.  Build it from the Dockerfile when
  # no image was specified OR when it is our locally-built pe-lab-base:<ver> tag
  # (e.g. after the Docker host VM was recreated and the image is gone).
  local img="${docker_image:-${docker_default_tag}}"
  if [[ -z "$docker_image" || "$docker_image" == pe-lab-base* ]]; then
    build_docker_image
  fi

  local roles=()
  while IFS= read -r r; do roles+=("$r"); done < <(docker_roles)

  local pub_key_content; pub_key_content=$(cat "${ssh_key_path}.pub")

  # Publish each container's SSH on a unique host port (2201+) and the PE
  # service ports on the host, so the console/agents are reachable from other
  # machines via this host's IP (same model as GCP docker).
  local port=2201 role
  for role in "${roles[@]}"; do
    local cname="${nodeprefix}${role}"
    docker rm -f "$cname" >/dev/null 2>&1 || true
    tui_info "Creating container ${cname} (host port ${port})"
    local pe_args="" p
    for p in $(docker_expose_ports "$role"); do pe_args="$pe_args -p ${p}:${p}"; done
    # --cgroupns=host + cgroup/tmpfs mounts are required for systemd to run as
    # PID 1 inside the container (cgroup v2 hosts).
    docker run -d --name "$cname" --network "$net" --privileged --cgroupns=host \
      -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
      --tmpfs /run:rw,exec --tmpfs /tmp:rw,exec \
      -p ${port}:22 ${pe_args} --hostname "$cname" \
      "$img" /sbin/init >/dev/null 2>&1 \
      || { tui_err "Failed to create ${cname}"; exit 1; }
    port=$((port+1))
  done

  # Wait for containers, install openssh-server, add the wizard public key
  for role in "${roles[@]}"; do
    local cname="${nodeprefix}${role}"
    for _ in $(seq 1 30); do
      docker exec "$cname" true 2>/dev/null && break
      sleep 2
    done
    tui_info "Configuring SSH on ${cname}"
    # Robust: use ';' so the key setup runs even if apt fails, and start sshd
    # via systemctl/service/direct with a final check (systemd may not be ready
    # right after container creation, so `service ssh start` alone can fail).
    timeout 180 docker exec "$cname" bash -c \
      "apt-get update -qq; apt-get install -y -qq nano openssh-server >/dev/null 2>&1; \
       mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
       echo '${pub_key_content}' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && \
       sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config; \
       (systemctl start ssh 2>/dev/null || service ssh start 2>/dev/null || /usr/sbin/sshd); \
       pgrep -x sshd >/dev/null || /usr/sbin/sshd" >/dev/null 2>&1 || true
  done

  # Add /etc/hosts entries so Bolt (on the host) can resolve container names
  for role in "${roles[@]}"; do
    local cname="${nodeprefix}${role}"
    local ip
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cname" 2>/dev/null)
    if [[ -n "$ip" ]]; then
      hosts_add "$ip" "$cname"
    fi
  done

  # Test node: a plain container (no PE/agent) for general testing, same base
  # image, only SSH installed, on the same network.  Not in docker_roles() so
  # peadm ignores it.
  local test_name="${nodeprefix}test"
  docker rm -f "$test_name" >/dev/null 2>&1 || true
  tui_info "Creating test container ${test_name} (host port ${port})"
  docker run -d --name "$test_name" --network "$net" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run:rw,exec --tmpfs /tmp:rw,exec \
    -p ${port}:22 --hostname "$test_name" \
    "$img" /sbin/init >/dev/null 2>&1 \
    || { tui_err "Failed to create ${test_name}"; exit 1; }
  for _ in $(seq 1 30); do
    docker exec "$test_name" true 2>/dev/null && break
    sleep 2
  done
  tui_info "Configuring SSH on ${test_name}"
  timeout 180 docker exec "$test_name" bash -c \
    "apt-get update -qq; apt-get install -y -qq nano openssh-server >/dev/null 2>&1; \
     mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
     echo '${pub_key_content}' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && \
     sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config; \
     (systemctl start ssh 2>/dev/null || service ssh start 2>/dev/null || /usr/sbin/sshd); \
     pgrep -x sshd >/dev/null || /usr/sbin/sshd" >/dev/null 2>&1 || true
  local t_ip
  t_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$test_name" 2>/dev/null)
  if [[ -n "$t_ip" ]]; then
    hosts_add "$t_ip" "$test_name"
  fi

  docker_etc_hosts_provision

  tui_ok "Docker containers provisioned"
}

generate_docker_artefacts() {
  local d_dir="${script_dir}/docker"
  mkdir -p "$d_dir"
  # For local docker the docker dir is the "active" dir.  For cloud, the
  # terraform dir (already set by generate_terraform_*) must stay active so
  # docker_provision_cloud can read its output.
  if [[ "$docker_host" != "cloud" ]]; then
    tf_dir_active="$d_dir"
  fi
  tui_ok "Docker provisioning prepared in ${d_dir}/"
}

# ──────────────────────────────────────────────────────────────────────────────
# DOCKER PROVISION – CLOUD HOST
# Runs all PE containers on a single provisioned cloud VM (the Docker host).
# Each container's SSH (port 22) is mapped to a unique host port (2201+) on the
# Docker host's internal network IP.  The wizard host resolves container
# hostnames to that IP via /etc/hosts and connects on the mapped port (set in
# inventory.yaml).  The internal IP is stable across restarts and works in
# air-gapped environments (internal-to-internal only).
# ──────────────────────────────────────────────────────────────────────────────
docker_provision_cloud() {
  tui_section "Docker Provisioning (cloud host)"
  local net="${docker_network:-${nodeprefix}net}"
  local img="${docker_image:-${docker_default_tag}}"

  # Internal network IP of the Docker-host VM, from the terraform output.
  local dh_ip
  dh_ip=$(cd "$tf_dir_active" && terraform output -raw dockerhost_ip 2>/dev/null) || dh_ip=""
  if [[ -z "$dh_ip" ]]; then
    tui_err "Could not determine Docker-host internal IP (terraform output dockerhost_ip)"
    exit 1
  fi
  docker_host_ip="$dh_ip"
  # Persist the Docker-host IP into the saved defaults so helpers can resolve
  # it even if /etc/hosts is later cleared or re-derived elsewhere.
  if [[ -n "$defaults_file" && -f "$defaults_file" ]]; then
    jq --arg ip "$docker_host_ip" '.docker_host_ip = $ip' "$defaults_file" > "${defaults_file}.tmp" \
      && mv "${defaults_file}.tmp" "$defaults_file" && chmod 600 "$defaults_file"
  fi

  # SSH helper into the Docker host (uses the same key/user as the PE nodes).
  dh_ssh() {
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=20 "${ssh_user}@${docker_host_ip}" "$@"
  }

  # The VM was just created by terraform – wait for sshd to come up before
  # trying to install Docker (otherwise we get "Connection refused").
  # Fresh GCP VMs can occasionally take several minutes to accept SSH, so use
  # a generous window (40 × 15s = 10 min) and log each attempt to a file.
  local slog="${script_dir}/dockerhost_ssh.log"
  tui_step "Waiting for SSH on ${docker_host_ip}… (log: $slog)"
  : > "$slog"
  local retry=0
  while (( retry < 40 )); do
    local err
    if err=$(dh_ssh true 2>&1); then
      tui_ok "SSH to Docker host ready"
      break
    fi
    echo "$(date +%H:%M:%S) attempt $((retry+1)) FAIL: $err" >> "$slog"
    if (( retry < 3 )); then
      # Show the real reason for the first few retries (timeout vs auth vs refused)
      tui_warn "Not reachable yet ($err)"
    else
      tui_warn "Not reachable yet – retrying in 15s (attempt $((retry+1))/40)"
    fi
    sleep 15
    retry=$((retry+1))
  done
  if (( retry >= 40 )); then
    tui_err "SSH to Docker host ${docker_host_ip} failed after 40 attempts"
    tui_info "Full connection log: $slog"
    exit 1
  fi

  tui_step "Installing Docker on ${docker_host_ip}…"
  dh_ssh "export DEBIAN_FRONTEND=noninteractive; export NEEDRESTART_MODE=a; \
    apt-get update -qq && apt-get install -y -qq docker.io" \
    || { tui_err "Docker install failed on ${docker_host_ip}"; exit 1; }

  dh_ssh "docker network create $net 2>/dev/null || true"

  # Ensure the container base image exists on the Docker host.  Build it from
  # the Dockerfile when none was specified OR when it is our locally-built
  # pe-lab-base:<ver> tag (e.g. the Docker host VM was just recreated); skip the
  # build if the image is already present.
  local _di="${docker_image:-${docker_default_tag}}"
  if [[ -z "$docker_image" || "$docker_image" == pe-lab-base* ]]; then
    if dh_ssh "docker image inspect ${_di} >/dev/null 2>&1"; then
      tui_ok "Docker base image already present on host: ${_di}"
    else
      ensure_dockerfile
      tui_step "Building base image on Docker host…"
      dh_ssh "mkdir -p /root/docker"
      scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "${script_dir}/docker/Dockerfile" "${ssh_user}@${docker_host_ip}:/root/docker/Dockerfile" \
        || { tui_err "Could not copy Dockerfile to host"; exit 1; }
      dh_ssh "cd /root/docker && docker build -t ${_di} ." \
        || { tui_err "Image build failed on host"; exit 1; }
    fi
    img="${_di}"
  fi

  # Run each PE container with its SSH mapped to a unique host port.  The
  # entry-point container(s) additionally map PE service ports so agents and the
  # console can reach them directly (no tunnel).  Multiple containers share the
  # one host, so each PE port is mapped on exactly one container.
  local port=2201 role
  for role in $(docker_roles); do
    local cname="${nodeprefix}${role}"
    dh_ssh "docker rm -f $cname >/dev/null 2>&1 || true"
    tui_info "Creating container ${cname} (host port ${port})"
    local pe_args="" p
    for p in $(docker_expose_ports "$role"); do pe_args="$pe_args -p ${p}:${p}"; done
    dh_ssh "docker run -d --restart unless-stopped --name $cname --network $net --privileged --cgroupns=host \
      -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run:rw,exec --tmpfs /tmp:rw,exec \
      -p ${port}:22 ${pe_args} --hostname $cname $img /sbin/init" \
      || { tui_err "Failed to create ${cname}"; exit 1; }
    port=$((port+1))
  done

  # Configure SSH inside each container (add wizard key, start sshd).
  local pub_key_content; pub_key_content=$(cat "${ssh_key_path}.pub")
  for role in $(docker_roles); do
    local cname="${nodeprefix}${role}"
    # Wait for the container to be ready before exec'ing into it.
    for _ in $(seq 1 30); do
      dh_ssh "docker exec $cname true" >/dev/null 2>&1 && break
      sleep 2
    done
    tui_info "Configuring SSH on ${cname}"
    dh_ssh "timeout 180 docker exec $cname bash -c \"apt-get update -qq && \
      apt-get install -y -qq nano openssh-server >/dev/null 2>&1 && \
      mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
      echo '${pub_key_content}' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && \
      sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \
      rm -f /run/nologin /etc/nologin && \
      (service ssh start || systemctl start ssh || /usr/sbin/sshd)\"" >/dev/null 2>&1 || true
    # The Dockerfile trims systemd units, so sshd is NOT auto-started on boot.
    # Ensure sshd is actually running and listening before we move on.
    for _ in $(seq 1 30); do
      dh_ssh "docker exec $cname pgrep -x sshd" >/dev/null 2>&1 && break
      dh_ssh "docker exec $cname /usr/sbin/sshd" >/dev/null 2>&1 || true
      sleep 2
    done
  done

  # Map container hostnames to the Docker-host internal IP on the wizard host.
  # Remove ONLY stale entries for this nodeprefix (any container from prior runs,
  # e.g. a different topology or an older VM IP) so only the current mapping
  # remains, then re-add the current containers.  Backup happens first and any
  # unrelated/custom entries are preserved.
  hosts_remove_prefix "$nodeprefix"
  for role in $(docker_roles); do
    hosts_add "$docker_host_ip" "${nodeprefix}${role}"
  done

  # Test node: a plain container (no PE/agent) for general testing.  It uses the
  # same base image but nothing is installed on it beyond SSH.  Its SSH (22) is
  # mapped to the next available host port after the PE containers.
  local test_name="${nodeprefix}test"
  dh_ssh "docker rm -f $test_name >/dev/null 2>&1 || true"
  tui_info "Creating test container ${test_name} (host port ${port})"
  dh_ssh "docker run -d --restart unless-stopped --name $test_name --network $net --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run:rw,exec --tmpfs /tmp:rw,exec \
    -p ${port}:22 --hostname $test_name $img /sbin/init" \
    || { tui_err "Failed to create ${test_name}"; exit 1; }
  for _ in $(seq 1 30); do
    dh_ssh "docker exec $test_name true" >/dev/null 2>&1 && break
    sleep 2
  done
  tui_info "Configuring SSH on ${test_name}"
  dh_ssh "timeout 180 docker exec $test_name bash -c \"apt-get update -qq && \\
    apt-get install -y -qq nano openssh-server >/dev/null 2>&1 && \\
    mkdir -p /root/.ssh && chmod 700 /root/.ssh && \\
    echo '${pub_key_content}' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && \\
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && \\
    (service ssh start || systemctl start ssh || /usr/sbin/sshd)\"" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    dh_ssh "docker exec $test_name pgrep -x sshd" >/dev/null 2>&1 && break
    dh_ssh "docker exec $test_name /usr/sbin/sshd" >/dev/null 2>&1 || true
    sleep 2
  done
  hosts_remove_name "$test_name"
  hosts_add "$docker_host_ip" "$test_name"

  docker_etc_hosts_provision

  tui_ok "Docker containers provisioned on ${docker_host_ip}"
}

# ──────────────────────────────────────────────────────────────────────────────
# SSH WAIT LOOP
# Uses bolt with explicit inventory and the FQDN of core0 directly.
# ──────────────────────────────────────────────────────────────────────────────
wait_for_ssh() {
  local max_retries=20 interval=30 retry=0
  local core0_fqdn; core0_fqdn=$(build_fqdn core0)

  tui_section "Waiting for SSH Availability"
  if [[ "$runtime" == "docker" ]]; then
    tui_info "Docker containers – skipping long boot wait"
  else
    tui_info "Initial 120 s wait for instances to boot…"
    sleep 120
  fi

  while (( retry < max_retries )); do
    printf "  ${CYAN}[%2d/%d]${RESET}  SSH check on %s…\n" \
      "$((retry+1))" "$max_retries" "$core0_fqdn"
    if [[ "$runtime" == "docker" ]]; then
      # For Docker, check the container SSH directly.  Local all-in-one connects
      # to the container via /etc/hosts on port 22; cloud uses the Docker-host's
      # mapped port.  Either way this bypasses stale /etc/hosts resolution for
      # the core0 fqdn.
      local dport=22 dhost="$core0_fqdn"
      if [[ "$docker_host" == "cloud" ]]; then
        dport=$(docker_ssh_port core0); dhost="$docker_host_ip"
      fi
      if timeout 15 ssh -i "$ssh_key_path" -p "$dport" \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=10 "${ssh_user}@${dhost}" "echo ok" >/dev/null 2>&1; then
        tui_ok "SSH connectivity verified on $core0_fqdn"
        return 0
      fi
    else
      if ${BOLT} command run "echo ok" \
          --targets "$core0_fqdn" \
          $(bolt_inv) >/dev/null 2>&1; then
        tui_ok "SSH connectivity verified on $core0_fqdn"
        return 0
      fi
    fi
    tui_warn "Not reachable yet – retrying in ${interval}s"
    sleep "$interval"
    retry=$((retry+1))
  done

  tui_err "SSH connectivity failed after $max_retries attempts on $core0_fqdn"
  exit 1
}

# ──────────────────────────────────────────────────────────────────────────────
# SSH TRUST BOOTSTRAP
# Public key already in GCP metadata so nodes boot authorised.
# This step deduplicates/confirms and sets up cross-node trust.
# All bolt calls use explicit --targets FQDNs + --inventoryfile.
# ──────────────────────────────────────────────────────────────────────────────
