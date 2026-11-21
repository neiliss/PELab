#!/bin/bash
# =============================================================================
# pelab.sh  –  PE Lab Provisioning Wizard  (modular entry point)
# =============================================================================
# This is the entry point for the PE Lab provisioning wizard.  It sources the
# modules in ./lib/ and then runs the interactive wizard + provisioning flow.
#
# The original monolithic setup.sh is preserved untouched; this file is the
# modular equivalent, split into logical modules under ./lib/.
#
# Providers:  local (Docker all-in-one on this host) | gcp (active) | aws | azure
# Runtime:    vm (VMs directly on the cloud) | docker (containers on a cloud VM)
#
# SSH model:
#   • Key-pair lives on this host.
#   • PUBLIC key is baked into Terraform metadata AND pushed via bootstrap.
#   • PRIVATE key is used by Bolt for all connections.
#   • No password SSH – key-only enforced throughout.
# =============================================================================

set -euo pipefail
clear

# ──────────────────────────────────────────────────────────────────────────────
# GLOBALS  (all variables declared here so save/load is always complete)
# ──────────────────────────────────────────────────────────────────────────────
script_dir="$(cd "$(dirname "$0")" && pwd)"
defaults_file="${PE_DEFAULTS_FILE:-${script_dir}/setup_wizard_defaults.json}"
destroy_done=false

# CLI helper dispatch:  ./pelab.sh upgrade | helper | provision
#   upgrade    → run the PE upgrade helper directly
#   helper     → show the helpers menu
#   provision  → skip the action menu and go straight to provisioning
#                (used by the swing-migrate helper to build a parallel infra
#                against an alternate defaults file via PE_DEFAULTS_FILE)
_requested_helper=""
_force_provision=""
if [[ $# -gt 0 ]]; then
  case "$1" in
    upgrade)   _requested_helper="upgrade" ;;
    helper)    _requested_helper="menu"    ;;
    provision) _force_provision="true"     ;;
    *) echo "Unknown argument: $1 (expected: upgrade | helper | provision)"; exit 1 ;;
  esac
fi

# ──────────────────────────────────────────────────────────────────────────────
# SOURCE MODULES  (globals/colors/TUI first, then the rest)
# ──────────────────────────────────────────────────────────────────────────────
for _mod in common defaults helpers deps terraform artefacts gcp docker \
            embedded gitnano docker_provision prep peadm access installagent pe_helpers; do
  source "${script_dir}/lib/${_mod}.sh"
done
unset _mod

# Total interactive sections for progress counter
_step_cur=0

tui_banner

tui_info "This wizard provisions PE nodes (Docker all-in-one on THIS host, or on a"
tui_info "cloud provider such as GCP) and installs Puppet Enterprise via peadm.  It is"
tui_info "self-contained: it handles GCP auth, terraform, Docker, and the PEADM install."
tui_info "If anything fails, re-run the wizard – it cleans up and retries."
echo

# ── 1. Dependencies ───────────────────────────────────────────────────────────
tui_section "Checking Dependencies"
install_dependencies

# ── 2. Load saved defaults ────────────────────────────────────────────────────
tui_section "Loading Saved Defaults"
load_defaults

# ── 3. Bolt wrapper ───────────────────────────────────────────────────────────
if [[ $EUID -eq 0 ]]; then BOLT="bolt"; else BOLT="sudo bolt"; fi

# ── 3a. Tool updates (bolt / peadm) ──────────────────────────────────────────
# Check for newer bolt / peadm up front and offer to update before provisioning.
check_tool_updates

# ── 3b. Top-level action ─────────────────────────────────────────────────────
# The wizard can either provision a new environment or run a helper against an
# existing one.  A CLI arg (./pelab.sh upgrade|helper|provision) skips this menu.
if [[ -z "$_requested_helper" && "$_force_provision" != "true" ]]; then
  tui_section "What would you like to do?"
  tui_menu_default _action_choice "Select an action" 1 \
    "provision – provision a new PE environment (terraform + PEADM)" \
    "helper    – run a helper on an existing environment (upgrade, DR, swing, …)"
  _action=$(echo "$_action_choice" | awk '{print $1}')
  echo
  if [[ "$_action" == "helper" ]]; then
    run_helpers_menu
    exit 0
  fi
elif [[ -n "$_requested_helper" ]]; then
  if [[ "$_requested_helper" == "menu" ]]; then
    run_helpers_menu
    exit 0
  fi
  case "$_requested_helper" in
    upgrade) helper_upgrade ;;
  esac
  exit 0
fi
# _force_provision=true → neither branch ran → fall through to provisioning

# ── 4. Provider ───────────────────────────────────────────────────────────────
tui_section "Cloud Provider"
tui_info "GCP and Docker are fully active.  AWS and Azure are coming soon."
echo

_prov_default=1
case "$provider" in gcp) _prov_default=2 ;; aws) _prov_default=3 ;; azure) _prov_default=4 ;; esac

tui_menu_default _provider_choice "Target deployment" "$_prov_default" \
  "local   – run PE in Docker on THIS host (all-in-one, no cloud)" \
  "gcp     – Google Cloud Platform  (active)" \
  "aws     – Amazon Web Services    (coming soon)" \
  "azure   – Microsoft Azure        (coming soon)"
provider=$(echo "$_provider_choice" | awk '{print $1}')
echo
tui_ok "Deployment target: ${BOLD}${provider}${RESET}"

# Localhost: an all-in-one deployment on this very host.  PE runs in Docker
# containers here – no cloud provider, no terraform, no sizing questions.
if [[ "$provider" == "local" ]]; then
  runtime="docker"
  docker_host="local"
  tui_ok "Runtime: ${BOLD}docker${RESET} (local all-in-one – forced)"
  tui_warn "No new nodes/VMs are created – PE containers run directly on this host."
else
  # GCP is the active cloud provider – make sure the user is logged in before
  # proceeding.  (AWS/Azure are handled later when they become active.)
  if [[ "$provider" == "gcp" ]]; then
    check_gcp_auth
  fi

  # Runtime: VMs directly on the cloud, or Docker containers (which run on the
  # chosen cloud).  Docker is a runtime, not a provider – the cloud selection
  # above determines where the Docker host/containers live.
  _rt_default=1; [[ "$runtime" == "docker" ]] && _rt_default=2
  tui_menu_default _runtime_choice "Runtime" "$_rt_default" \
    "vm     – provision VMs directly on ${provider}" \
    "docker – run Docker containers (on ${provider})"
  runtime=$(echo "$_runtime_choice" | awk '{print $1}')
  echo
  tui_ok "Runtime: ${BOLD}${runtime}${RESET}"
fi

tui_section "Provider CLI Check"
install_provider_cli "$provider"

# ── 5. General parameters ─────────────────────────────────────────────────────
tui_section "General Parameters"
echo
tui_prompt nodeprefix "Node prefix"          "${nodeprefix:-myenv}"
tui_prompt adminpwd   "Console admin password" "${adminpwd:-$(openssl rand -base64 18)}"
tui_prompt pe_version "PE version"           "${pe_version:-latest}"
tui_prompt pe_tarball_path "Local PE tarball path (offline; empty to download)" "${pe_tarball_path:-}"
if [[ -n "$pe_tarball_path" ]]; then
  if [[ ! -f "$pe_tarball_path" ]]; then
    tui_warn "Tarball not found at $pe_tarball_path – will fall back to download"
    pe_tarball_path=""
  else
    # If version is 'latest', derive it from the tarball filename so the
    # version and tarball always match.
    if [[ "$pe_version" == "latest" ]]; then
      _tv=$(basename "$pe_tarball_path" | sed -n 's/^puppet-enterprise-\([0-9][0-9.]*\)-.*\.tar\.gz$/\1/p')
      if [[ -n "$_tv" ]]; then
        pe_version="$_tv"
        tui_ok "Derived PE version ${BOLD}${pe_version}${RESET} from tarball filename"
      else
        tui_warn "Could not derive version from tarball name – set PE version explicitly"
      fi
    fi
  fi
fi
echo

_inst_default=1
case "$instype" in LARGE) _inst_default=2 ;; XL) _inst_default=3 ;; esac

tui_menu_default _instype_raw "Installation type" "$_inst_default" \
  "STANDARD  – 1 primary (single-node, no replica)" \
  "LARGE     – primary + compilers + HAProxy + replica (optional)" \
  "XL        – primary + PDB + compilers + HAProxy + replica/PDB (optional)"
instype=$(echo "$_instype_raw" | awk '{print $1}')
echo
tui_ok "Install type: ${BOLD}${instype}${RESET}"

# ── 6. Provider parameters ────────────────────────────────────────────────────
if [[ "$provider" != "local" ]]; then
  tui_section "Provider Parameters"
  echo
  case "$provider" in
    gcp)
      tui_prompt gcp_project "GCP project ID"                      "${gcp_project:-my-gcp-project}"

      tui_prompt region      "Region  (e.g. us-central1)"          "${region:-us-central1}"

      # Normalise zone: if saved value looks like a full zone (e.g. "us-central1-a"),
      # extract just the trailing letter; if it's already a single letter leave it.
      if [[ "$zone" =~ ^[a-z]+-[a-z0-9]+-[a-z]$ ]]; then
        zone="${zone##*-}"   # "us-central1-a" → "a"
      fi
      tui_prompt zone "Zone letter  (a / b / c)" "${zone:-a}"
      # Validate: must be a single lowercase letter; if not, extract last segment
      if [[ ! "$zone" =~ ^[a-z]$ ]]; then
        zone="${zone##*-}"
        # If still not a single letter, default to a
        [[ ! "$zone" =~ ^[a-z]$ ]] && zone="a"
        tui_warn "Zone normalised to: ${zone}"
      fi
      tui_ok "Region → ${BOLD}${region}${RESET}   Zone → ${BOLD}${zone}${RESET}   (full: ${region}-${zone})"

      local_dns_default="${gcp_dns_suffix:-c.${gcp_project}.internal}"
      tui_prompt gcp_dns_suffix "Internal DNS suffix"               "$local_dns_default"
      echo
      if [[ "$runtime" == "docker" ]]; then
        # On Docker the DNS suffix applies to the Docker-host VM; the PE nodes are
        # containers on that VM (e.g. ${nodeprefix}core0) resolved via /etc/hosts.
        tui_info "Docker host VM FQDN → ${BOLD}${nodeprefix}dockerhost.${gcp_dns_suffix}${RESET}"
        tui_info "PE nodes are containers on it (${nodeprefix}core0, ${nodeprefix}compiler0…), not VMs"
      else
        tui_info "Example FQDN → ${BOLD}${nodeprefix}core0.${gcp_dns_suffix}${RESET}"
      fi
      ;;
    aws)
      tui_prompt aws_region    "AWS region"    "${aws_region:-us-east-1}"
      tui_prompt aws_vpc_id    "VPC ID"        "${aws_vpc_id:-}"
      tui_prompt aws_subnet_id "Subnet ID"     "${aws_subnet_id:-}"
      region="$aws_region"; zone=""
      ;;
    azure)
      tui_prompt azure_location       "Azure location"      "${azure_location:-eastus}"
      tui_prompt azure_resource_group "Resource group"      "${azure_resource_group:-pe-lab-rg}"
      region="$azure_location"; zone=""
      ;;
  esac

  # Compose full zone – region+letter for GCP, region-only for AWS/Azure
  [[ -n "$zone" ]] && full_zone="${region}-${zone}" || full_zone="${region}"
else
  # Localhost: no cloud region/zone/DNS questions.
  region=""; zone=""; full_zone=""; gcp_project=""; gcp_dns_suffix=""
fi

# ── Base OS (drives PE platform + Docker base) ────────────────────────────
tui_section "Base Operating System"
  # ── Base OS: ONE choice drives the PE platform + the Docker container base ──
  # PE's packages are OS-specific, so the PE platform and the Docker base image
  # MUST match.  Picking the OS once here keeps them (and the VM image) in sync.
  # Supported: Ubuntu 24.04 / 26.04 and RHEL 8 / 9 (el-8 / el-9).
  _bo_default="ubuntu-24.04"
  case "${pe_platform:-}" in
    ubuntu-26.04*) _bo_default="ubuntu-26.04" ;;
    ubuntu-24.04*) _bo_default="ubuntu-24.04" ;;
    el-8*)         _bo_default="el-8" ;;
    el-9*)         _bo_default="el-9" ;;
  esac
  _bo_idx=1
  case "$_bo_default" in
    ubuntu-26.04) _bo_idx=2 ;; el-8) _bo_idx=3 ;; el-9) _bo_idx=4 ;;
  esac
  tui_menu_default _bo_choice "Base operating system (PE platform / Docker base)" "$_bo_idx" \
    "ubuntu-24.04  | PE ubuntu-24.04-amd64  | Docker ubuntu:24.04" \
    "ubuntu-26.04  | PE ubuntu-26.04-amd64  | Docker ubuntu:26.04" \
    "el-8          | PE el-8-x86_64         | Docker rockylinux:8   (RHEL 8)" \
    "el-9          | PE el-9-x86_64         | Docker rockylinux:9   (RHEL 9)"
  base_os=$(echo "$_bo_choice" | awk '{print $1}')
  case "$base_os" in
    ubuntu-24.04) pe_platform="ubuntu-24.04-amd64" ;;
    ubuntu-26.04) pe_platform="ubuntu-26.04-amd64" ;;
    el-8)         pe_platform="el-8-x86_64" ;;
    el-9)         pe_platform="el-9-x86_64" ;;
  esac
  if [[ "$runtime" == "docker" ]]; then
    docker_base=$(docker_base_from_hint "$base_os")
    docker_default_tag="pe-lab-base:${docker_base#*:}"
    tui_ok "Base OS ${BOLD}${base_os}${RESET}  |  PE platform ${pe_platform}  |  Docker base ${BOLD}${docker_base}${RESET}"
  else
    tui_ok "Base OS ${BOLD}${base_os}${RESET}  |  PE platform ${pe_platform}"
  fi

# Docker runtime parameters (only when running containers).
if [[ "$runtime" == "docker" ]]; then
  if [[ "$provider" == "local" ]]; then
    # Local all-in-one: containers run directly on this host (no provisioned VM).
    docker_host="local"
    docker_host_ip="localhost"
    tui_ok "Docker host: ${BOLD}local${RESET} (containers run on this host)"
    tui_info "Docker network: ${BOLD}${docker_network:-${nodeprefix}net}${RESET}"
  else
    # Docker always runs on a provisioned (cloud) Docker-host VM.  The wizard
    # host is a utility/jump box and must NEVER contain the Puppet app or a
    # Docker daemon – containers live on a separate VM.
    docker_host="cloud"
    if [[ "$provider" != "gcp" ]]; then
      tui_err "Docker runtime requires docker-host-on-cloud, which is only implemented for GCP"
      exit 1
    fi
    tui_ok "Docker host: ${BOLD}cloud${RESET} (containers run on a provisioned VM)"
    tui_info "Docker-host VM name: ${BOLD}${nodeprefix}dockerhost${RESET}"
    tui_info "Docker-host VM FQDN: ${BOLD}$(build_dockerhost_fqdn)${RESET}"
    # Optional static internal IP for the Docker-host VM.  Default is derived
    # from THIS environment's subnet, but other environments can override or
    # opt out (enter 'auto').  Blank would be ephemeral and change on rebuild.
    tui_info "Docker-host VM static internal IP: pin for stability, or type ${BOLD}auto${RESET} (ephemeral) —"
    tui_info "  suggested for this subnet: ${BOLD}$(suggest_docker_host_ip)${RESET}"
    tui_prompt docker_host_static_ip "Docker-host static internal IP" "$(suggest_docker_host_ip)"
    if [[ "${docker_host_static_ip,,}" =~ ^(auto|none)$ ]]; then docker_host_static_ip=""; fi
  fi

  tui_prompt docker_image   "Docker image (blank = build ${docker_base:-systemd base} from Dockerfile)"   "${docker_image:-}"
  tui_prompt docker_network "Docker network" "${docker_network:-${nodeprefix}net}"
  # Docker is always "separate": one container per Puppet role, all on the
  # single Docker-host VM.  e.g. LARGE -> core0, compiler0, compiler1, haproxy.
  docker_topology="separate"
fi

if [[ "$instype" =~ ^(XL|LARGE)$ ]]; then
  if [[ "$provider" != "local" ]]; then
    tui_prompt nodepooladdress "Compiler pool CIDR" "${nodepooladdress:-10.0.0.0/24}"
  else
    # Localhost: no cloud CIDR – compiler_pool_address is derived from the
    # HAProxy container FQDN (docker LARGE/XL), so leave it empty.
    nodepooladdress=""
  fi
fi

# ── 7. Node sizing ────────────────────────────────────────────────────────────
if [[ "$provider" == "local" ]]; then
  tui_section "Node Sizing"
  echo
  node_size="Host"
  gcp_machine_type="this host"; gcp_compiler_type=""
  aws_instance_type="";  aws_compiler_type=""
  azure_vm_size="";      azure_compiler_type=""
  tui_info "Localhost uses the resources of THIS host – no VM sizing."
  tui_warn "Ensure this host has enough CPU/RAM for ${instype}:"
  tui_warn "  STANDARD ~2 vCPU/4GB · LARGE ~16 vCPU/32GB · XL ~32 vCPU/64GB · XXL ~32 vCPU/128GB (recommended minimums)"
  echo
else
  tui_section "Node Sizing"
  echo

  _size_default=2
  case "$node_size" in Small) _size_default=1 ;; Large) _size_default=3 ;; XXL) _size_default=4 ;; esac

  if [[ "$runtime" == "docker" ]]; then
    # Docker: the single Docker-host VM runs every container, so Small/Medium are
    # not recommended.  Large is the minimum; XL/XXL for heavier topologies.
    _size_opts=(
      "Large  - 16 vCPU / 32 GB RAM  (e2-custom-16-32768)  / m5.2xlarge / Standard_D8s_v3   (Docker min recommended)"
      "XL     - 32 vCPU / 64 GB RAM  (e2-custom-32-65536)  / m5.4xlarge / Standard_E16s_v5"
      "XXL    - 32 vCPU /128 GB RAM  (e2-custom-32-131072) / m5.8xlarge / Standard_E32s_v5 (Docker: one host runs all containers)"
    )
    case "$node_size" in
      XL)  _size_default=2 ;;
      XXL) _size_default=3 ;;
      *)   _size_default=1 ;;  # default to Large (min recommended)
    esac
  else
    _size_opts=(
      "Small  – e2-custom-2-4096  / t3.medium  / Standard_B2s"
      "Medium – e2-custom-6-8192  / t3.large   / Standard_B4ms"
      "Large  - 16 vCPU / 32 GB RAM  (e2-custom-16-32768) / m5.2xlarge / Standard_D8s_v3"
    )
  fi
  tui_menu_default _size_raw "VM size" "$_size_default" "${_size_opts[@]}"
  node_size=$(echo "$_size_raw" | awk '{print $1}')

  case "$node_size" in
    Small)
      gcp_machine_type="e2-custom-2-4096";  aws_instance_type="t3.medium";  azure_vm_size="Standard_B2s"
      gcp_compiler_type="e2-custom-2-4096"; aws_compiler_type="t3.medium";  azure_compiler_type="Standard_B2s" ;;
    Medium)
      gcp_machine_type="e2-custom-6-8192";  aws_instance_type="t3.large";   azure_vm_size="Standard_B4ms"
      gcp_compiler_type="e2-custom-2-4096"; aws_compiler_type="t3.medium";  azure_compiler_type="Standard_B2s" ;;
    Large)
      gcp_machine_type="e2-custom-16-32768"; aws_instance_type="m5.2xlarge"; azure_vm_size="Standard_D8s_v3"
      gcp_compiler_type="e2-custom-16-32768"; aws_compiler_type="m5.2xlarge"; azure_compiler_type="Standard_D8s_v3" ;;
    XL)
      gcp_machine_type="e2-custom-32-65536"; aws_instance_type="m5.4xlarge"; azure_vm_size="Standard_E16s_v5"
      gcp_compiler_type="e2-custom-32-65536"; aws_compiler_type="m5.4xlarge"; azure_compiler_type="Standard_E16s_v5" ;;
    XXL)
      # Docker-only: the single Docker-host VM must host every container, so size
      # it far above the VM topology sizes (32 vCPU / 128GB here).
      gcp_machine_type="e2-custom-32-131072"; aws_instance_type="m5.8xlarge"; azure_vm_size="Standard_E32s_v5"
      gcp_compiler_type="e2-custom-32-131072"; aws_compiler_type="m5.8xlarge"; azure_compiler_type="Standard_E32s_v5" ;;
    *)
      gcp_machine_type="e2-custom-6-8192";  aws_instance_type="t3.large";   azure_vm_size="Standard_B4ms"
      gcp_compiler_type="e2-custom-2-4096"; aws_compiler_type="t3.medium";  azure_compiler_type="Standard_B2s" ;;
  esac
  echo
  tui_ok "Size: ${BOLD}${node_size}${RESET}  infra=${gcp_machine_type}  compiler=${gcp_compiler_type}"

  echo
  tui_prompt custom_image "Base VM image (GCP; VM nodes + the Docker-host VM)" "${custom_image:-ubuntu-2404}"
  if [[ "$runtime" == "docker" && "$base_os" == "custom" ]]; then
    tui_prompt docker_base "Docker container base image (FROM)" "${docker_base:-ubuntu:24.04}"
    docker_default_tag="pe-lab-base:${docker_base#*:}"
  fi
  if [[ "$runtime" == "docker" ]]; then
    tui_info "Containers build FROM ${docker_base} -> tag ${docker_image:-$docker_default_tag} (matches PE ${pe_platform})."
  fi
fi

# ── 8. SSH ────────────────────────────────────────────────────────────────────
tui_section "SSH Configuration"
echo
tui_prompt ssh_user "SSH user on targets" "${ssh_user:-root}"
configure_ssh_key

# ── 9. R10K / Code Manager ───────────────────────────────────────────────────
tui_section "R10K / Code Manager"
echo

# Optional local git (gitnano) on the master – a lightweight control-repo
# manager (bare repo + HTTP API + SSH loopback for r10k).  Installed on core0
# after the PE install if enabled.  Asked FIRST so it can auto-configure r10k.
_gitnano_default="N"; [[ "$use_gitnano" == "true" ]] && _gitnano_default="Y"
tui_confirm use_gitnano "Use local git (gitnano) on master?" "$_gitnano_default"
if [[ "$use_gitnano" == "true" ]]; then
  tui_info "gitnano will be installed on ${BOLD}${nodeprefix}core0${RESET} after the PE install."
  tui_info "gitnano API port: ${gitnano_port}"
  # Auto-wire r10k to gitnano: the remote points at the local control-repo, and
  # the r10k private key is the same key gitnano will use (pre-placed on master).
  _gcore=$(build_fqdn core0)
  r10k_remote="gitnano@${_gcore}:/opt/gitnano/repos/control-repo.git"
  if [[ ! -f "${script_dir}/gitnano_id_rsa" ]]; then
    ssh-keygen -t rsa -b 4096 -N '' -f "${script_dir}/gitnano_id_rsa" >/dev/null 2>&1
  fi
  # peadm reads r10k_private_key_file from the Bolt controller (wizard host) and
  # places it on the puppetserver at /etc/puppetlabs/puppetserver/ssh/id-control_repo.rsa,
  # configuring r10k to use that path.  gitnano.sh reuses the same key (it only
  # generates one if absent), so r10k + gitnano share one keypair.
  r10k_private_key_file="${script_dir}/gitnano_id_rsa"
  r10k_known_hosts="[]"
  tui_info "r10k auto-configured to use gitnano: ${r10k_remote}"

  # Determine the control-repo seed source: use a local control-repo directory
  # if one exists in the script root, otherwise clone the Puppet reference repo.
  gitnano_seed_dir=""
  if [[ -d "${script_dir}/control-repo" ]]; then
    gitnano_seed_dir="${script_dir}/control-repo"
    tui_info "Using existing control-repo at ${gitnano_seed_dir}"
  else
    tui_info "No local control-repo found – cloning https://github.com/puppetlabs/control-repo"
    # Full clone (no --depth 1): a shallow clone can't be pushed from core0 if
    # the container has no internet, so seed with full history instead.
    if git clone https://github.com/puppetlabs/control-repo "${script_dir}/control-repo" >/dev/null 2>&1; then
      gitnano_seed_dir="${script_dir}/control-repo"
      tui_ok "Cloned reference control-repo to ${gitnano_seed_dir}"
    else
      tui_warn "Could not clone control-repo – gitnano will seed a minimal repo"
    fi
  fi
else
  tui_prompt r10k_remote \
    "R10K remote repo" \
    "${r10k_remote:-git@gitlab:puppet/control-repo.git}"

  tui_prompt r10k_private_key_file \
    "R10K private key path" \
    "${r10k_private_key_file:-/root/peadm/id_rsa}"

  if [[ -n "$r10k_private_key_file" && "$r10k_private_key_file" != /* ]]; then
    r10k_private_key_file="${script_dir}/${r10k_private_key_file}"
  fi

  # Auto-scan known host (timeout so an unreachable host can't hang the wizard).
  # The host is parsed from the r10k_remote URL (scp-like, ssh://, https://, …).
  auto_known_host="[]"
  if [[ -n "${r10k_remote:-}" ]]; then
    remote_host=$(git_remote_host "$r10k_remote")
    remote_port=$(git_remote_port "$r10k_remote")
    if [[ -n "$remote_host" ]]; then
      _scan_args=(-t ed25519)
      [[ -n "$remote_port" ]] && _scan_args+=(-p "$remote_port")
      ssh_key_line=$(timeout 10 ssh-keyscan "${_scan_args[@]}" "$remote_host" 2>/dev/null | head -n1 || true)
      if [[ -n "$ssh_key_line" ]]; then
        key_type=$(echo "$ssh_key_line" | awk '{print $2}')
        key_val=$(echo  "$ssh_key_line" | awk '{print $3}')
        # ssh-keyscan with a non-default port emits [host]:port as the name.
        _kh_name="$remote_host"
        [[ -n "$remote_port" ]] && _kh_name="[$remote_host]:$remote_port"
        [[ -n "$key_type" && -n "$key_val" ]] && \
          auto_known_host="[{\"name\":\"${_kh_name}\",\"type\":\"${key_type}\",\"key\":\"${key_val}\"}]"
      fi
    fi
  fi
  tui_prompt _r10k_kh_input \
    "R10K known-hosts JSON" \
    "$auto_known_host"

  if [[ -n "$_r10k_kh_input" ]]; then
    if echo "$_r10k_kh_input" | jq empty >/dev/null 2>&1; then
      r10k_known_hosts="$_r10k_kh_input"
    else
      r10k_known_hosts="[$_r10k_kh_input]"
    fi
  else
    r10k_known_hosts="$auto_known_host"
  fi
fi

# ── 9.4. Full offline build (gating question) ────────────────────────────────
# Makes the lab runnable WITHOUT internet after install: pulls the full reponano
# package manifest + the full forgenano module catalog, then switches the master
# + every client's apt to point at the master reponano and points the Puppetfile
# at the master forgenano (local forge).  Answering Y REQUIRES reponano, forgenano,
# scanano and openainano on the master, so the wizard enables them and skips the
# individual add-on prompts (configurable values default).
_full_offline_default="N"; [[ "$full_offline" == "true" ]] && _full_offline_default="Y"
tui_confirm full_offline "Full offline build? (pull all packages + modules, switch repo/forge to local)" "$_full_offline_default"
if [[ "$full_offline" == "true" ]]; then
  tui_info "Enabling reponano + forgenano + scanano + openainano (required for offline)."
  tui_info "After install, the wizard will:"
  tui_info "  1. Pull the full reponano package manifest into the local repo."
  tui_info "  2. Pull the full forgenano module catalog into the local forge."
  tui_info "  3. Point the master + every client's apt at the master reponano."
  tui_info "  4. Point the Puppetfile at the master forgenano (local forge)."
  tui_info "Result: the lab can run fully offline."
  use_openainano="true"
  use_reponano="true"
  use_forgenano="true"
  use_scanano="true"
  # Forge bearer token (optional) – lets forgenano pull PREMIUM modules from the
  # public Forge into the local mirror.  Blank = public modules only.
  tui_info "Forge bearer token (blank = public modules only; provide one for premium modules):"
  tui_prompt forgenano_forge_token "forgenano Forge token" "$forgenano_forge_token"
  tui_prompt forge_proxy "Forge proxy (optional, e.g. http://proxy:8080)" "$forge_proxy"
fi

# ── 9.5–9.9 Nano add-ons on the master ───────────────────────────────────────
# (Skipped when a full offline build is chosen – the add-ons are required and
# their configurable values use the saved defaults.)
if [[ "$full_offline" != "true" ]]; then

  # ── 9.5. OpenAINano (PE AI ↔ Ollama bridge) on the master ──────────────────
  # A Flask bridge (port 5001) that translates PE's AI infra-assistant to a local
  # Ollama instance (127.0.0.1:11434).  Installed on core0 after the PE install.
  # On by default.  NOTE: gitnano's API uses port 5000; openainano uses 5001.
  _openainano_default="Y"; [[ "$use_openainano" == "false" ]] && _openainano_default="N"
  tui_confirm use_openainano "Install OpenAINano (PE AI ↔ Ollama bridge) on master?" "$_openainano_default"
  if [[ "$use_openainano" == "true" ]]; then
    tui_info "openainano will be installed on ${BOLD}${nodeprefix}core0${RESET} after the PE install."
    tui_info "It bridges PE's AI infra-assistant to a local Ollama (http://127.0.0.1:11434)."
    tui_info "Ollama is installed on the master automatically."
    tui_info "openainano port: ${openainano_port}"
    tui_prompt openainano_model "openainano Ollama model (must be a cloud model)" "$openainano_model"
    tui_info "After install: run 'ollama login' then 'ollama run ${openainano_model}' to use it."
  fi

  # ── 9.6. Reponano (local apt/yum package repo) on the master ────────────────
  # A local apt/yum package repo manager (Flask, port 3864) installed on core0.
  # Offline nodes point their package manager at it.  On by default.
  _reponano_default="Y"; [[ "$use_reponano" == "false" ]] && _reponano_default="N"
  tui_confirm use_reponano "Install Reponano (local apt/yum repo) on master?" "$_reponano_default"
  if [[ "$use_reponano" == "true" ]]; then
    tui_info "reponano will be installed on ${BOLD}${nodeprefix}core0${RESET} after the PE install."
    tui_info "It hosts a local apt/yum repo on port ${reponano_port} for offline nodes."
  fi

  # ── 9.7. Forgenano (local Puppet Forge / module mirror) on the master ───────
  # A local Puppet Forge (Flask, port 6157) installed on core0.  Offline nodes
  # install modules from it instead of the public Forge.  On by default.
  _forgenano_default="Y"; [[ "$use_forgenano" == "false" ]] && _forgenano_default="N"
  tui_confirm use_forgenano "Install Forgenano (local Puppet Forge) on master?" "$_forgenano_default"
  if [[ "$use_forgenano" == "true" ]]; then
    tui_info "forgenano will be installed on ${BOLD}${nodeprefix}core0${RESET} after the PE install."
    tui_info "It mirrors Puppet Forge modules to a local repo on port ${forgenano_port} for offline nodes."
    tui_prompt forgenano_admin_key "forgenano admin key" "$forgenano_admin_key"
    tui_info "Forge token (blank = public modules only; provide one for premium modules):"
    tui_prompt forgenano_forge_token "forgenano Forge token" "$forgenano_forge_token"
    tui_prompt forge_proxy "Forge proxy (optional, e.g. http://proxy:8080)" "$forge_proxy"
    tui_info "After install, forgenano mirrors the control-repo Puppetfile modules and"
    tui_info "points the Puppetfile at the local forge (http://${nodeprefix}core0:${forgenano_port})."
  fi

  # ── 9.8. Hieranano (Hiera/eyaml UI) ────────────────────────────────────────
  # hieranano is always installed on the master; its port is a fixed default.
  # (no prompt – hieranano port: ${hieranano_port})

  # ── 9.9. Scanano (CVE-enabled vulnerability scan bridge) on the master ───────
  # A Nessus-API mimic (Flask, HTTPS port 9000) installed on core0.  Runs nmap
  # scans with the vulners script and exports Nessus XML.  On by default.
  _scanano_default="Y"; [[ "$use_scanano" == "false" ]] && _scanano_default="N"
  tui_confirm use_scanano "Install Scanano (vuln scan bridge) on master?" "$_scanano_default"
  if [[ "$use_scanano" == "true" ]]; then
    tui_info "scanano will be installed on ${BOLD}${nodeprefix}core0${RESET} after the PE install."
    tui_info "It mimics a Nessus API on port ${scanano_port} (HTTPS) for CVE-aware nmap scans."
    tui_prompt scanano_token "scanano API token" "$scanano_token"
  fi

fi

# ── 10. Disaster Recovery ─────────────────────────────────────────────────────
if [[ "$instype" != "STANDARD" ]]; then
  tui_section "Disaster Recovery"
  echo
  _dr_default="N"; [[ "$enable_dr" == "true" ]] && _dr_default="Y"
  tui_confirm enable_dr "Enable primary-replica DR?" "$_dr_default"
else
  enable_dr="false"
fi

# ── 10c. PE license file ──────────────────────────────────────────────────────
tui_section "PE License"
echo
tui_prompt suite_license_path \
  "PE license file path" \
  "${suite_license_path:-${script_dir}/suite-license.lic}"
if [[ -n "$suite_license_path" && "$suite_license_path" != /* ]]; then
  suite_license_path="${script_dir}/${suite_license_path}"
fi
echo

# ── 11. Node counts & hostnames ───────────────────────────────────────────────
case "$instype" in
  STANDARD)
    # STANDARD is always single-node – it never includes a replica.
    core_count=1
    compiler_count=0; haproxy_count=0 ;;
  LARGE)
    # LARGE co-locates PostgreSQL on the primary/replica (peadm "Large").
    # Only XL uses separate PDB nodes.
    core_count=1; [[ "$enable_dr" == "true" ]] && core_count=2
    compiler_count=2; haproxy_count=1 ;;
  XL)
    core_count=2; [[ "$enable_dr" == "true" ]] && core_count=4
    compiler_count=2; haproxy_count=1 ;;
  *)
    core_count=1; compiler_count=0; haproxy_count=0 ;;
esac
node_count=$core_count

# Docker is always "separate" – every role is its own container on the single
# Docker-host VM, so the standard node counts below apply as-is (no single-node
# override needed).

primary_host=$(build_fqdn core0)
if [[ "$instype" == "XL" ]]; then
  # XL uses a separate PDB node (core1).  STANDARD and LARGE co-locate
  # PostgreSQL on the primary, so leave primary_postgresql_host unset.  Setting
  # it to the primary would make peadm run pe_install twice on the same host,
  # and the second run fails because the first deletes the installer tarball.
  primary_postgresql_host=$(build_fqdn core1)
else
  primary_postgresql_host=""
fi

replica_host=""
replica_postgresql_host=""
if [[ "$enable_dr" == "true" ]]; then
  if [[ "$instype" == "XL" ]]; then
    replica_host=$(build_fqdn core2)
    replica_postgresql_host=$(build_fqdn core3)
  else
    # STANDARD and LARGE co-locate PostgreSQL on the replica.
    replica_host=$(build_fqdn core1)
    replica_postgresql_host=""
  fi
fi

# ── 12. Cleanup ───────────────────────────────────────────────────────────────
tui_section "Pre-Provisioning Cleanup"
echo
_del_default="N"; [[ "$del_now" == "true" ]] && _del_default="Y"
tui_confirm del_now \
  "Destroy existing '${nodeprefix}' resources first?" \
  "$_del_default"

# ── 13. Summary ───────────────────────────────────────────────────────────────
tui_section "Configuration Summary"
tui_summary_open

tui_summary_row "Provider"      "$provider"
tui_summary_row "Runtime"       "$runtime"
tui_summary_row "Node prefix"   "$nodeprefix"
tui_summary_row "Install type"  "$instype"
tui_summary_div
if [[ "$runtime" == "docker" ]]; then
  if [[ "$docker_host" == "local" ]]; then
    tui_summary_row "Docker host"   "local (this host)"
  else
    tui_summary_row "Docker host"   "cloud (${nodeprefix}dockerhost)"
  fi
  tui_summary_row "Docker image"  "${docker_image:-${docker_default_tag} (built from Dockerfile)}"
  tui_summary_row "Docker network" "${docker_network:-${nodeprefix}net}"
  tui_summary_row "Docker topology" "$docker_topology"
  if [[ "$docker_host" == "cloud" ]]; then
    tui_summary_row "Docker-host static IP" "${docker_host_static_ip:-ephemeral}"
  fi
else
  tui_summary_row "Region"        "${region}"
  tui_summary_row "Zone"          "${full_zone}"
  tui_summary_row "GCP Project"   "$gcp_project"
  tui_summary_row "DNS suffix"    "$gcp_dns_suffix"
fi
tui_summary_div
tui_summary_row "Node size"     "$node_size  (${gcp_machine_type})"
tui_summary_row "Core nodes"    "$core_count"
tui_summary_row "Compilers"     "$compiler_count"
tui_summary_row "HAProxy"       "$haproxy_count"
tui_summary_row "DR enabled"    "$enable_dr"
tui_summary_div
tui_summary_row "PE version"    "$pe_version"
if [[ -n "$pe_tarball_path" ]]; then
  tui_summary_row "PE tarball"     "$pe_tarball_path (offline)"
fi
if [[ "$runtime" != "docker" ]]; then
  tui_summary_row "Base image"    "$custom_image"
fi
tui_summary_div
tui_summary_row "Primary FQDN"  "$primary_host"
tui_summary_row "SSH user"      "$ssh_user"
tui_summary_row "SSH key"       "$ssh_key_path"

tui_summary_close

# ── 14. Save defaults ─────────────────────────────────────────────────────────
tui_section "Saving Settings"
save_defaults

# ── 15. Generate artefacts ────────────────────────────────────────────────────
tui_section "Generating Artefacts"
generate_params_json
generate_inventory_yaml
if [[ "$provider" != "local" ]]; then
  case "$provider" in
    gcp)   generate_terraform_gcp ;;
    aws)   generate_terraform_aws ;;
    azure) generate_terraform_azure ;;
  esac
fi
if [[ "$runtime" == "docker" ]]; then
  generate_docker_artefacts
fi

# ── Guarantee the access reference (helper.md) is written ────────────────────
# The full access reference is printed/written at the very end, but a partial or
# interrupted run should still leave helper.md.  This EXIT trap writes it (once)
# if the normal end-of-run call did not.
helper_md_written="no"
helper_on_exit() {
  [[ "${helper_md_written:-no}" == "yes" ]] && return 0
  helper_md_written="yes"
  tui_info "Writing the access reference from the current state (partial run)…"
  print_console_access 2>/dev/null || true
}
trap helper_on_exit EXIT

# ── 16. Provision now? ────────────────────────────────────────────────────────
echo
_run_prompt="Run provisioning now (terraform + PEADM)?"
[[ "$runtime" == "docker" && "$docker_host" == "local" ]] && \
  _run_prompt="Run local provisioning now (Docker + PEADM)?"
tui_confirm _run_now "$_run_prompt" "Y"

if [[ "$_run_now" != "true" ]]; then
  # Honour a "Y to delete" even when not provisioning now, so old resources are
  # cleaned up immediately rather than silently left behind.
  if [[ "$del_now" == "true" && "$destroy_done" != "true" ]]; then
    if [[ "$runtime" == "docker" ]]; then
      docker_destroy_existing
    fi
    case "$provider" in
      gcp) gcp_ensure_auth; gcp_destroy_existing ;;
    esac
    destroy_done=true
  fi

  if [[ "$runtime" == "docker" ]]; then
    if [[ "$docker_host" == "cloud" ]]; then
      printf '%s\n' \
        "cd ${tf_dir_active}" \
        "terraform init" \
        "terraform apply" \
        "# Then re-run this wizard to provision containers and install PE" \
        | tui_hint_box
    else
      printf '%s\n' \
        "Re-run this wizard to provision Docker containers and install PE" \
        | tui_hint_box
    fi
  else
    printf '%s\n' \
      "cd ${tf_dir_active}" \
      "terraform init" \
      "terraform apply" \
      "# Then re-run this wizard to install PE" \
      | tui_hint_box
  fi
  exit 0
fi

# ── 17. Auth ──────────────────────────────────────────────────────────────────
tui_section "Cloud Authentication"
case "$provider" in
  local)
    tui_info "Localhost deployment – no cloud authentication required." ;;
  gcp)
    tui_info "GCP auth needs BOTH of these (the wizard will prompt/launch them if missing):"
    tui_info "  1) an active account  ->  gcloud auth login"
    tui_info "  2) an ADC file        ->  gcloud auth application-default login --scopes=cloud-platform"
    tui_info "Terraform is forced to use the ADC file so it has compute access (the VM's"
    tui_info "metadata token is scope-limited and would fail with ACCESS_TOKEN_SCOPE_INSUFFICIENT)."
    export CLOUDSDK_COMPUTE_REGION="${region}"
    export CLOUDSDK_COMPUTE_ZONE="${full_zone}"
    gcp_ensure_auth ;;
  aws)   tui_info "Ensure AWS credentials are configured (aws configure / env vars)" ;;
  azure) tui_info "Ensure Azure CLI is logged in (az login)" ;;
esac
if [[ "$runtime" == "docker" ]]; then
  docker_ensure_auth
fi

# ── 18. Provision ────────────────────────────────────────────────────────────
tui_section "Provisioning"
if [[ "$runtime" == "docker" ]]; then
  if [[ "$docker_host" == "local" ]]; then
    tui_info "All-in-one: PE containers run on THIS host.  Container hostnames are"
    tui_info "resolved via /etc/hosts to their container IPs – SSH to a node on port 22 as"
    tui_info "${ssh_user}@${nodeprefix}core0, ${nodeprefix}compiler0, … (no port mapping)."
  else
    tui_info "Docker containers run on a single Docker-host VM.  To SSH to a node, use"
    tui_info "the Docker host's public IP + the mapped port (core0=2201, compiler0=2202,"
    tui_info "compiler1=2203, haproxy=2204, test=2205).  The container's internal IP is"
    tui_info "NOT reachable from outside – always use the host IP + mapped port."
  fi
  if [[ "$docker_host" == "cloud" ]]; then
    # Provision the Docker-host VM via terraform, then run containers on it.
    tui_section "Terraform Provisioning (Docker host)"
    tf_run init -input=false

    if [[ "$del_now" == "true" && "$destroy_done" != "true" ]]; then
      tf_destroy_current_prefix
      case "$provider" in
        gcp) gcp_destroy_existing ;;
      esac
      destroy_done=true
    fi

    [[ "$provider" == "gcp" ]] && gcp_verify_compute
    [[ "$provider" == "gcp" ]] && gcp_import_firewall
    # Fail fast if the chosen static Docker-host IP is already taken, instead of
    # letting terraform error and then waiting 10 min for SSH on a VM that never
    # got created.
    if [[ "$provider" == "gcp" && -n "${docker_host_static_ip:-}" ]]; then
      gcp_check_static_ip "$docker_host_static_ip"
    fi
    if ! tf_run apply -auto-approve -input=false; then
      tui_err "Terraform apply FAILED – not proceeding (check output above)."
      exit 1
    fi
    docker_provision_cloud
  else
    if [[ "$del_now" == "true" && "$destroy_done" != "true" ]]; then
      # Clean up old Docker containers AND any pre-existing cloud VMs (e.g. a
      # Docker host or leftover instances from a previous run).
      docker_destroy_existing
      case "$provider" in
        gcp) gcp_destroy_existing ;;
      esac
      destroy_done=true
    fi
    docker_provision
  fi
else
  tui_section "Terraform Provisioning"
  tf_run init -input=false

  if [[ "$del_now" == "true" && "$destroy_done" != "true" ]]; then
    # Destroy state-tracked resources for the CURRENT prefix first, then clean
    # up any pre-existing instances that Terraform doesn't know about (state may
    # be empty).  tf_destroy_current_prefix only destroys current-prefix
    # resources, so a stale state from a prior prefix is not wrongly deleted.
    tf_destroy_current_prefix
    case "$provider" in
      gcp) gcp_destroy_existing ;;
    esac
    destroy_done=true
  fi

  [[ "$provider" == "gcp" ]] && gcp_verify_compute
  [[ "$provider" == "gcp" ]] && gcp_import_firewall
  if ! tf_run apply -auto-approve -input=false; then
    tui_err "Terraform apply FAILED – not proceeding (check output above)."
    exit 1
  fi

  # The VMs now exist.  Stop so the user can ensure our public key is present and
  # PubkeyAuthentication is enabled on the fresh base-image targets before we try
  # to SSH into them (otherwise the bootstrap/connection step would fail).
  ssh_key_target_preflight
fi

# ── 19. Wait for SSH ──────────────────────────────────────────────────────────
wait_for_ssh

# ── 19.5. gitnano known_hosts (after provisioning, before PE install) ────────
# The master's SSH host key only exists after provisioning, so scan it now and
# regenerate params.json so r10k/code-manager can verify the gitnano remote.
set_gitnano_known_hosts
generate_params_json

# ── 20. Bootstrap SSH trust ───────────────────────────────────────────────────
bootstrap_ssh_trust

# ── 21. Pre-install prep ──────────────────────────────────────────────────────
pre_install_prep

# ── 23. HAProxy ───────────────────────────────────────────────────────────────
configure_haproxy

# ── 24. PEADM install ─────────────────────────────────────────────────────────
run_peadm_install

# ── 24a. Restart hardening (PostgreSQL crash-recovery timeout) ────────────────
# So a full Docker-host / container restart (incl. an unclean power cycle) can
# finish WAL recovery instead of being killed at PE's 300s startup cap.
harden_postgres_recovery || tui_warn "restart hardening did not complete – see output above"

# ── 24b. Local git (gitnano) on the master ───────────────────────────────────
# These are best-effort add-ons; a failure must not stop the run.
install_gitnano || tui_warn "gitnano install did not complete – see output above"

# ── 24c. Reponano (local apt/yum package repo) on the master ─────────────────
install_reponano || tui_warn "reponano install did not complete – see output above"

# ── 24d. Forgenano (local Puppet Forge / module mirror) on the master ───────
# Offline-critical: mirrors the modules (public via build, premium via the
# direct-mirror fallback) and installs the durable forge self-heal.
install_forgenano || tui_warn "forgenano install did not complete – see output above"

# ── 24e. Apply the control-repo Puppetfile (offline forge + deploy) ─────────
# Offline-critical: points the deployed Puppetfile at the local forgenano, sets
# the r10k/code-manager forge override, and deploys.  Runs BEFORE the optional
# UI add-ons so a failure in one of those can't leave the offline deploy unset.
install_active_puppetfile || tui_warn "Could not apply the control-repo Puppetfile – see output above"

# ── 24f. Hieranano (Hiera/eyaml UI) on the master ────────────────────────────
install_hieranano || tui_warn "hieranano install did not complete – see output above"

# ── 24g. OpenAINano (PE AI ↔ Ollama bridge) on the master ────────────────────
install_openainano || tui_warn "openainano install did not complete – see output above"

# ── 24h. installagent.sh utility on every node's /root ────────────────────────
install_installagent

# ── 24i. Scanano (CVE-enabled vulnerability scan bridge) on the master ────────
install_scanano || tui_warn "scanano install did not complete – see output above"

# ── Console access helper ─────────────────────────────────────────────────────
# Prints how to reach the PE console and connect agents.  For Docker-on-cloud
# the PE service ports are exposed on the Docker host, so the console and agents
# connect directly (no tunnel).  For LARGE/XL the HAProxy is the agent entry
# point on 8140; the console stays on the primary.

# ── 25. Done ──────────────────────────────────────────────────────────────────
tui_done
tui_summary_open
tui_summary_row "PE Console" "https://${primary_host}"
tui_summary_row "Username"   "admin"
tui_summary_row "Password"   "(as configured)"
tui_summary_row "Settings"   "${defaults_file}"
tui_summary_close
print_console_access
