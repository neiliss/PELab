# =============================================================================
# helpers.sh  –  extracted from setup.sh (lines 470-584)
# Sourced by pelab.sh.  Do not run directly.
# =============================================================================
build_fqdn() {
  local role="$1"
  if [[ "$runtime" == "docker" ]]; then
    echo "${nodeprefix}${role}"
    return
  fi
  case "$provider" in
    gcp)   echo "${nodeprefix}${role}.${gcp_dns_suffix}" ;;
    aws)   echo "${nodeprefix}-${role}.${aws_region}.compute.internal" ;;
    azure) echo "${nodeprefix}-${role}.internal.cloudapp.azure.com" ;;
    *)     echo "${nodeprefix}-${role}.local" ;;
  esac
}

# Extract the host from a git remote URL, supporting scp-like (git@host:path),
# ssh://, https://, http://, and git:// forms.  Used to auto-build r10k_known_hosts.
git_remote_host() {
  local url="$1" h=""
  if [[ "$url" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]]; then
    # scheme://[user@]host[:port]/path
    h="${url#*://}"; h="${h#*@}"; h="${h%%/*}"; h="${h%%:*}"
  else
    # scp-like: [user@]host:path
    h="${url%%:*}"; h="${h##*@}"
  fi
  echo "$h"
}

# Extract the port (if any) from a git remote URL; empty when not specified.
git_remote_port() {
  local url="$1" p=""
  if [[ "$url" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]]; then
    local rest="${url#*://}"; rest="${rest#*@}"; rest="${rest%%/*}"
    if [[ "$rest" == *:* ]]; then p="${rest##*:}"; fi
  fi
  echo "$p"
}


# FQDN of the single Docker-host VM (used when docker_host=cloud).  The PE
# containers run on this VM; the wizard host reaches them via its public IP.
build_dockerhost_fqdn() {
  case "$provider" in
    gcp)   echo "${nodeprefix}dockerhost.${gcp_dns_suffix}" ;;
    aws)   echo "${nodeprefix}-dockerhost.${aws_region}.compute.internal" ;;
    azure) echo "${nodeprefix}-dockerhost.internal.cloudapp.azure.com" ;;
    *)     echo "${nodeprefix}-dockerhost.local" ;;
  esac
}

# Ordered list of PE container roles (core, compiler, haproxy) for the current
# topology.  Used by inventory generation and Docker provisioning.
docker_roles() {
  local i
  for i in $(seq 0 $((node_count-1)));      do echo "core${i}"; done
  for i in $(seq 0 $((compiler_count-1))); do echo "compiler${i}"; done
  [[ "$instype" =~ ^(XL|LARGE)$ ]] && echo "haproxy"
}

# Ports to expose on a given container of the single Docker host (echoed as a
# space-separated list of host ports to map 1:1).  Multiple containers share
# the one host, so only the entry-point container(s) map PE ports externally
# and nothing is double-mapped (which would fail to bind).
#
#   STANDARD (no LB):  the primary (core0) exposes ALL PE ports.
#   LARGE/XL (+haproxy): the HAProxy fronts 8140 (agent LB); the primary
#       exposes the console + PE API ports (everything EXCEPT 8140, which the
#       LB owns).  Compilers / replica / PDB expose only SSH (mapped elsewhere).
docker_expose_ports() {
  local role="$1"
  local has_lb=no
  [[ "$instype" =~ ^(XL|LARGE)$ ]] && has_lb=yes
  if [[ "$has_lb" == "yes" && "$role" == "haproxy" ]]; then
    echo "8140"
    return
  fi
  if [[ "$role" == "core0" ]]; then
    if [[ "$has_lb" == "yes" ]]; then
      echo "80 443 3864 6157 9000 4430 4431 4432 4433 5432 5525 8080 8081 8142 8143 8147 8170"
    else
      echo "80 443 3864 6157 9000 4430 4431 4432 4433 5432 5525 8080 8081 8140 8142 8143 8147 8170"
    fi
  fi
  # all other containers (compilers, replica, PDB): SSH only
}

# SSH host port for a given container role on the single Docker host.  Each
# container's SSH (22) is mapped to a unique host port starting at 2201, in
# docker_roles order (core0..coreN, compiler0..compilerN, haproxy).
docker_ssh_port() {
  local role="$1" i=0 r
  for r in $(docker_roles); do
    if [[ "$r" == "$role" ]]; then
      echo $((2201 + i)); return
    fi
    i=$((i+1))
  done
}

# Global helper to run a command against the Docker host.  For docker_host=cloud
# it SSHes to the Docker-host VM; for docker_host=local (all-in-one on this
# host) it runs the command directly.  docker_provision_cloud defines its own
# local dh_ssh (shadowing this one) for its SSH-wait/install sequence.
dh_ssh() {
  if [[ "$docker_host" == "cloud" ]]; then
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=20 "${ssh_user}@${docker_host_ip}" "$@"
  else
    "$@"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# DEPENDENCY INSTALLATION
# ──────────────────────────────────────────────────────────────────────────────
