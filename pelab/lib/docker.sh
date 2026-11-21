# =============================================================================
# docker.sh  –  extracted from setup.sh (lines 1823-1988)
# Sourced by pelab.sh.  Do not run directly.
# =============================================================================
docker_ensure_auth() {
  # For cloud-hosted containers, Docker runs on the remote VM – no local daemon
  # is required.
  if [[ "$docker_host" == "cloud" ]]; then
    tui_ok "Docker runs on the cloud VM – no local daemon required"
    return 0
  fi
  # Local all-in-one: install and start the Docker daemon on THIS host.
  ensure_docker_local
}

# Install (if missing) and start the Docker daemon on the current host, for the
# "local" all-in-one deployment.  Idempotent: safe to call repeatedly.
ensure_docker_local() {
  if ! command -v docker >/dev/null 2>&1; then
    tui_step "Docker not found – installing (docker.io)…"
    if ! apt-get install -y -qq docker.io >/dev/null 2>&1; then
      apt-get update -qq >/dev/null 2>&1
      apt-get install -y -qq docker.io >/dev/null 2>&1 || {
        tui_err "Could not install Docker.  Install it manually: https://docs.docker.com/engine/install/"
        exit 1
      }
    fi
    tui_ok "Docker installed"
  fi

  # Ensure the daemon is actually running.
  if ! docker info >/dev/null 2>&1; then
    tui_step "Starting Docker daemon…"
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 \
      || service docker start >/dev/null 2>&1 \
      || { dockerd >/dev/null 2>&1 & sleep 5; }
    sleep 2
  fi

  if docker info >/dev/null 2>&1; then
    tui_ok "Docker daemon is running ($(docker --version 2>/dev/null))"
  else
    tui_err "Docker daemon not running – start it manually (systemctl start docker)"
    exit 1
  fi
}

# Writes the systemd-enabled base Dockerfile to ${script_dir}/docker/Dockerfile if
# it is missing.  Makes the wizard self-contained on a fresh host where only
# setup.sh was copied (the docker/ directory may not have been transferred).
ensure_dockerfile() {
  local d="${script_dir}/docker"
  mkdir -p "$d"
  # Always (re)write the Dockerfile from the embedded template so it can never be
  # stale (e.g. an image built from an old Dockerfile missing packages the PE
  # installer needs, like sudo).
  tui_info "Writing ${BOLD}${d}/Dockerfile${RESET} (embedded in setup.sh)…"
  cat > "${d}/Dockerfile" <<'DOCKERFILE'
# PE Lab Docker base image
# Builds a systemd-enabled image from ANY base that ships a supported package
# manager (Debian/Ubuntu apt, RHEL/CentOS/Rocky/Alma dnf|yum, SLES/openSUSE
# zypper) so PE services can run under systemd as PID 1.  The base OS is taken
# from ${docker_base} (see docker_base_from_hint), e.g. ubuntu:26.04 or
# rockylinux:9 -- it must MATCH the OS of the PE build being installed.
#
# Build:  docker build -t ${docker_image:-${docker_default_tag}} .
# Run:    docker run -d --privileged --cgroupns=host \
#           -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /tmp \
#           --name <node> ${docker_image:-${docker_default_tag}} /sbin/init

FROM ubuntu:24.04

ENV container docker
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash","-lc"]

# Install systemd + SSH + the tooling the PEADM/Bolt flow needs, using whatever
# package manager the base image provides.  python3-yaml is required by peadm
# Bolt tasks; cron for the Puppet cron provider; haproxy for the LB container.
RUN set -eux; \
    if command -v apt-get >/dev/null 2>&1; then \
        apt-get update -qq; \
        apt-get install -y --no-install-recommends \
          systemd systemd-sysv openssh-server nano ca-certificates curl gnupg sudo \
          iproute2 iputils-ping dnsutils cron python3 python3-yaml libyaml-0-2 \
          libssl3 libreadline8 libpcre2-8-0 zlib1g locales tzdata file tar wget rsync haproxy; \
        rm -rf /var/lib/apt/lists/*; \
        (locale-gen en_US.UTF-8 || true); (update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 || true); \
    elif command -v dnf >/dev/null 2>&1; then \
        dnf install -y --allowerasing --nobest systemd openssh-server nano ca-certificates gnupg2 sudo \
          iproute iputils bind-utils cronie python3 python3-pyyaml libyaml openssl-libs \
          readline pcre2 zlib glibc-langpack-en tzdata file tar wget rsync haproxy; \
        dnf clean all; \
    elif command -v yum >/dev/null 2>&1; then \
        yum install -y --allowerasing --nobest systemd openssh-server nano ca-certificates gnupg2 sudo \
          iproute iputils bind-utils cronie python3 python3-pyyaml libyaml openssl-libs \
          readline pcre2 zlib glibc-langpack-en tzdata file tar wget rsync haproxy; \
        yum clean all; \
    elif command -v zypper >/dev/null 2>&1; then \
        zypper -n install --no-recommends systemd openssh nano ca-certificates curl gpg2 sudo \
          iproute2 iputils bind-utils cron python3 python3-PyYAML libyaml-0-2 libopenssl1_1 \
          libreadline8 pcre2 zlib libc-locales tzdata file tar wget rsync haproxy; \
        zypper clean -a; \
    else \
        echo "Unsupported base image: no apt-get/dnf/yum/zypper found" >&2; exit 1; \
    fi

# Trim systemd to the minimal set required in a container (handles both the
# /lib/systemd/system and /usr/lib/systemd/system layouts), then set up SSH.
RUN set -eux; \
    for sd in /lib/systemd/system /usr/lib/systemd/system; do \
      [ -d "$sd" ] || continue; \
      ( cd "$sd/sysinit.target.wants" 2>/dev/null && for i in *; do \
          [ "$i" = systemd-tmpfiles-setup.service ] || rm -f "$i"; done ) || true; \
      rm -f "$sd"/multi-user.target.wants/* "$sd"/local-fs.target.wants/* \
            "$sd"/sockets.target.wants/*udev* "$sd"/sockets.target.wants/*initctl* \
            "$sd"/basic.target.wants/* "$sd"/anaconda.target.wants/* "$sd"/tmp.mount 2>/dev/null || true; \
    done; \
    rm -f /etc/systemd/system/*.wants/* 2>/dev/null || true; \
    mkdir -p /root/.ssh && chmod 700 /root/.ssh; \
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config || true; \
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config || true

VOLUME ["/sys/fs/cgroup", "/tmp", "/run"]

CMD ["/sbin/init"]
DOCKERFILE
  # Parameterize the base OS so the image matches the target PE platform
  # (e.g. ubuntu:26.04 for a PE build that ships ubuntu-26.04 packages).
  # ALWAYS pin the base OS to docker_base -- even if the Dockerfile already
  # exists -- so a stale Dockerfile or a changed OS never silently builds the
  # wrong base (e.g. ubuntu:24.04 tagged as pe-lab-base:26.04).
  sed -i "s|^FROM .*|FROM ${docker_base:-ubuntu:24.04}|" "${d}/Dockerfile"
}

# Map a base-image hint (GCP image name or PE platform) to a Docker base image.
#   ubuntu-2604 / ubuntu-26.04-amd64  -> ubuntu:26.04
#   ubuntu-2404 / ubuntu-24.04-amd64  -> ubuntu:24.04
#   lab-base-rhel-9 / rhel-9-x86_64            -> registry.access.redhat.com/ubi9/ubi
docker_base_from_hint() {
  local h; h=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  # Already a Docker image reference (ubuntu:26.04, repo/img:tag) -> use as-is.
  if [[ "$h" == *:* || "$h" == */* ]]; then echo "$1"; return; fi
  # Debian / Ubuntu:  ubuntu-26.04-amd64 | ubuntu-2404 | debian-12
  if [[ "$h" =~ ubuntu[-_]?([0-9]{2})[.]([0-9]{2}) ]]; then echo "ubuntu:${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"; return; fi
  if [[ "$h" =~ ubuntu[-_]?([0-9]{2})([0-9]{2}) ]]; then echo "ubuntu:${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"; return; fi
  if [[ "$h" =~ debian[-_]?([0-9]{1,2}) ]]; then echo "debian:${BASH_REMATCH[1]}"; return; fi
  # RHEL-family (el8/9, rhel, centos, rocky, alma, oracle)
  local _v
  [[ "$h" =~ (el|rhel|redhat|centos|rocky|almalinux|alma|oracle|ol)[-_]?([0-9]{1,2}) ]] && _v="${BASH_REMATCH[2]}"
  if [[ -n "${_v:-}" ]]; then
    case "$h" in
      *rhel*|*redhat*|*ubi*) echo "registry.access.redhat.com/ubi${_v}/ubi:latest" ;;
      *centos*)              echo "quay.io/centos/centos:stream${_v}" ;;
      *rocky*)               echo "rockylinux:${_v}" ;;
      *alma*)                echo "almalinux:${_v}" ;;
      *oracle*|*ol*)         echo "oraclelinux:${_v}" ;;
      *)                     echo "rockylinux:${_v}" ;;   # 'el' = RHEL-compatible
    esac
    return
  fi
  # SLES / openSUSE
  if [[ "$h" =~ (sles|suse|opensuse)[-_]?([0-9]{2}) ]]; then echo "registry.suse.com/suse/sle${BASH_REMATCH[2]}:latest"; return; fi
  echo ""
}

docker_destroy_existing() {
  # When docker_host=cloud the containers live on a remote Docker-host VM;
  # destroying that VM (gcp_destroy_existing / terraform destroy) removes them,
  # so there is nothing to clean up locally.
  if [[ "$docker_host" == "cloud" ]]; then
    tui_info "Docker containers run on a cloud VM – they are removed with the VM"
    return 0
  fi
  tui_step "Destroying existing '${nodeprefix}' containers…"
  local found=0
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    docker rm -f "$c" >/dev/null 2>&1
    tui_ok "Removed container $c"
    found=1
  done < <(docker ps -a --format '{{.Names}}' | grep "^${nodeprefix}")
  docker network rm "${docker_network:-${nodeprefix}net}" >/dev/null 2>&1 || true
  if [[ $found -eq 0 ]]; then
    tui_info "No existing '${nodeprefix}' containers found"
  fi
}

# Builds the systemd-enabled base image from docker/Dockerfile (FROM ubuntu:24.04)
# if it is not already present locally.  Delete the image to force a rebuild.
build_docker_image() {
  local tag="${docker_image:-${docker_default_tag}}"
  if docker image inspect "$tag" >/dev/null 2>&1; then
    tui_ok "Docker base image present: $tag"
    return 0
  fi
  ensure_dockerfile
  tui_step "Building systemd-enabled base image $tag (first run only)…"
  docker build -t "$tag" "${script_dir}/docker" >/dev/null 2>&1 \
    || { tui_err "Docker build failed – see ${script_dir}/docker/Dockerfile"; exit 1; }
  tui_ok "Built $tag"
}

# Writes the embedded gitnano.sh installer to ${script_dir}/gitnano.sh if it is
# missing, so the wizard is self-contained on a fresh host (mirrors
# ensure_dockerfile).  gitnano is a lightweight control-repo manager (bare repo +
# HTTP API + SSH loopback for r10k) installed on the master (core0).
