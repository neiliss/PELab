# =============================================================================
# deps.sh  –  extracted from setup.sh (lines 585-930)
# Sourced by pelab.sh.  Do not run directly.
# =============================================================================
install_dependencies() {
  tui_section "Checking Dependencies"

  local required_cmds=(curl jq bolt git ssh-keyscan)
  # Localhost (all-in-one Docker on this host) never runs terraform.
  [[ "$provider" != "local" ]] && required_cmds+=(terraform)
  local missing=()

  for cmd in "${required_cmds[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
      # Bolt can be installed but broken (e.g. a noble/24.04 package on an older
      # OS whose libc lacks GLIBC_2.38).  Detect that and reinstall the right one.
      if [[ "$cmd" == "bolt" ]] && ! bolt --version >/dev/null 2>&1; then
        tui_warn "bolt  ${DIM}(installed but broken – will reinstall)${RESET}"
        missing+=("$cmd")
      else
        tui_ok "$cmd"
      fi
    else
      tui_warn "$cmd  ${DIM}(missing)${RESET}"
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    # All tools are present, but we still must ensure the peadm module (and its
    # node_manager dependency, which provides the Node_group type) is available
    # to Bolt.  Otherwise a host that already has peadm but lacks node_manager
    # would skip the install and fail later during the peadm configure apply.
    ensure_peadm_module
    return 0
  fi

  tui_blank; tui_info "Attempting to install missing tools…"

  if ! command -v lsb_release >/dev/null 2>&1; then
    sudo apt-get update -qq && sudo apt-get install -y -qq lsb-release
  fi
  sudo apt-get update -qq
  sudo apt-get install -y -qq curl jq git openssh-client wget

  # Terraform
  if printf '%s\n' "${missing[@]}" | grep -qx "terraform"; then
    tui_step "Installing Terraform"
    curl -fsSL https://apt.releases.hashicorp.com/gpg \
      | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
      | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq terraform \
      || { tui_err "Failed to install terraform"; exit 1; }
    tui_ok "terraform installed"
  fi

  # Puppet Bolt
  if printf '%s\n' "${missing[@]}" | grep -qx "bolt"; then
    tui_step "Installing Puppet Bolt"
    tui_prompt_secret _bolt_lic "PE License ID (for Bolt repo auth – not echoed)"

    # Use the host's own Ubuntu codename so the Bolt package matches the local
    # libc (a noble/24.04 package needs GLIBC_2.38 and won't run on 22.04).
    local codename; codename=$(lsb_release -cs)
    # Puppet's apt repo only publishes repo-config + bolt packages for a subset
    # of Ubuntu releases (noble/jammy/focal).  Newer codenames (e.g. 26.04
    # "resolute") aren't published yet, so fall back to the newest supported LTS.
    # The release .deb is only a repo-config package and glibc is
    # backward-compatible, so a noble-built bolt runs fine on newer releases.
    case "$codename" in
      noble|jammy|focal) : ;;   # supported as-is
      *) codename="noble" ;;   # unsupported/newer -> newest supported LTS
    esac
    local rel="puppet8-release-${codename}.deb"
    wget -q "https://apt-puppetcore.puppet.com/public/${rel}" \
      -O "/tmp/${rel}" \
      || { tui_err "Failed to download ${rel}"; exit 1; }
    sudo dpkg -i "/tmp/${rel}" \
      || { tui_err "Failed to install ${rel}"; exit 1; }

    local auth_file="/etc/apt/auth.conf.d/apt-puppetcore-puppet.conf"
    sudo mkdir -p "$(dirname "$auth_file")"
    printf 'machine apt-puppetcore.puppet.com login license-id password %s\n' \
      "$_bolt_lic" | sudo tee "$auth_file" >/dev/null
    sudo chmod 600 "$auth_file"

    sudo apt-get update -qq \
      || { tui_err "apt-get update failed after Puppet repo"; exit 1; }
    # Remove any broken Bolt first so the correct one replaces it cleanly.
    sudo apt-get remove -y -qq puppet-bolt 2>/dev/null || true
    sudo apt-get install -y -qq puppet-bolt \
      || { tui_err "Failed to install puppet-bolt"; exit 1; }
    tui_ok "puppet-bolt installed"
  fi

  # PEADM module must be available to Bolt regardless of whether Bolt was just
  # installed or already present – otherwise `bolt plan run peadm::install`
  # cannot find the module at install time.
  ensure_peadm_module

  # Final verify
  local still_missing=()
  for cmd in "${required_cmds[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || still_missing+=("$cmd")
  done
  if [[ ${#still_missing[@]} -gt 0 ]]; then
    tui_err "Still missing: ${still_missing[*]} – install manually and re-run"
    exit 1
  fi
  tui_ok "All base dependencies satisfied"
}

# ──────────────────────────────────────────────────────────────────────────────
# PEADM MODULE FOR BOLT
# Installs puppetlabs-peadm (+ dependencies) into Bolt's user modulepath
# (~/.puppetlabs/bolt/modules) so `bolt plan run peadm::install` resolves the
# module from any directory.  bolt module add needs a Bolt project, so we use a
# scratch project to resolve the dependency tree, then stage the modules into
# Bolt's user modulepath (no CWD/project dependency afterwards).
# ──────────────────────────────────────────────────────────────────────────────
# Print the installed peadm version (from its metadata.json).
_peadm_version() {
  grep '"version"' "${HOME}/.puppetlabs/bolt/modules/peadm/metadata.json" 2>/dev/null \
    | head -1 | sed -E 's/.*"version": *"([^"]+)".*/\1/'
}

ensure_peadm_module() {
  tui_step "Ensuring PEADM module for Bolt…"

  local _dest="${HOME}/.puppetlabs/bolt/modules"
  mkdir -p "$_dest"

  # A LOCAL/custom peadm module (e.g. an unreleased/experimental build, or an
  # offline bundle) takes precedence over fetching the latest from the Forge.
  # Existing dependency modules (stdlib, node_manager, …) are kept.
  if [[ -n "${peadm_module_dir:-}" ]]; then
    if [[ -f "${peadm_module_dir}/metadata.json" ]]; then
      tui_info "Using local PEADM module from ${peadm_module_dir}"
      rm -rf "${_dest}/peadm"
      cp -r "$peadm_module_dir" "${_dest}/peadm"
      # If the local module bundles deps in a sibling .modules/, copy them too.
      if [[ -d "${peadm_module_dir}/../.modules" ]]; then
        cp -r "${peadm_module_dir}/../.modules/." "$_dest/"
      fi
      if [[ -f "${_dest}/node_manager/lib/puppet/type/node_group.rb" ]]; then
        tui_ok "PEADM module installed from local path (v$(_peadm_version))"
        return 0
      fi
      tui_warn "Local PEADM installed but node_manager (Node_group) is missing – fetching dependencies"
    else
      tui_warn "peadm_module_dir set but not a valid module (${peadm_module_dir}) – fetching latest"
    fi
  fi

  # Always try to fetch the LATEST peadm (and its deps) so we don't get stuck on
  # an old version.  If the update fails, keep whatever is already present.
  local scratch
  scratch=$(mktemp -d "${script_dir}/peadm-install.XXXXXX") || {
    tui_warn "Could not create scratch dir – PEADM not ensured"; return 0
  }

  if (cd "$scratch" \
        && bolt project init peadm >/dev/null 2>&1 \
        && bolt module add puppetlabs-peadm >/dev/null 2>&1); then
    mkdir -p "${HOME}/.puppetlabs/bolt/modules"
    cp -r "${scratch}/.modules/." "${HOME}/.puppetlabs/bolt/modules/"
    rm -rf "$scratch"
    if bolt plan show 2>/dev/null | grep -q 'peadm::install' \
       && [[ -f "${HOME}/.puppetlabs/bolt/modules/node_manager/lib/puppet/type/node_group.rb" ]]; then
      tui_ok "PEADM module updated to latest for Bolt (v$(_peadm_version), with dependencies)"
      return 0
    fi
  fi
  rm -rf "$scratch"

  # Update failed – fall back to whatever is already present.
  local has_peadm=no has_nm=no
  bolt plan show 2>/dev/null | grep -q 'peadm::install' && has_peadm=yes
  [[ -f "${HOME}/.puppetlabs/bolt/modules/node_manager/lib/puppet/type/node_group.rb" ]] && has_nm=yes
  if [[ "$has_peadm" == "yes" && "$has_nm" == "yes" ]]; then
    tui_ok "PEADM module already available to Bolt (v$(_peadm_version), update failed – keeping existing)"
    return 0
  fi

  # Fallback: clone just the peadm module into the user modulepath.
  tui_warn "bolt module add failed – falling back to git clone"
  if [[ ! -d "${HOME}/.puppetlabs/bolt/modules/peadm" ]]; then
    git clone --depth 1 https://github.com/puppetlabs/puppetlabs-peadm.git \
      "${HOME}/.puppetlabs/bolt/modules/peadm" \
      || { tui_err "Failed to install PEADM module"; return 1; }
  fi
  # The git-clone fallback only fetches peadm, not its dependencies.  The
  # node_manager module provides the Node_group resource type peadm's configure
  # step needs during apply, so clone it too if still missing.
  if [[ ! -f "${HOME}/.puppetlabs/bolt/modules/node_manager/lib/puppet/type/node_group.rb" ]]; then
    git clone --depth 1 https://github.com/puppetlabs/puppetlabs-node_manager.git \
      "${HOME}/.puppetlabs/bolt/modules/node_manager" \
      || tui_warn "Could not clone node_manager (Node_group) module"
  fi
  tui_ok "PEADM cloned to ${HOME}/.puppetlabs/bolt/modules/peadm"
}

# ──────────────────────────────────────────────────────────────────────────────
# PROVIDER CLI INSTALL
# ──────────────────────────────────────────────────────────────────────────────
install_provider_cli() {
  local prov="$1"
  case "$prov" in
    gcp)
      if ! command -v gcloud >/dev/null 2>&1; then
        tui_step "Installing Google Cloud SDK"
        sudo apt-get install -y -qq apt-transport-https ca-certificates gnupg
        sudo mkdir -p -m 0755 /etc/apt/keyrings
        curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
          | sudo gpg --dearmor -o /etc/apt/keyrings/google-cloud-sdk.gpg
        echo "deb [signed-by=/etc/apt/keyrings/google-cloud-sdk.gpg] \
https://packages.cloud.google.com/apt cloud-sdk main" \
          | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
        sudo apt-get update -qq && sudo apt-get install -y -qq google-cloud-sdk
        tui_ok "google-cloud-sdk installed"
      else
        tui_ok "gcloud  $(gcloud --version 2>/dev/null | head -1)"
      fi ;;
    aws)
      command -v aws >/dev/null 2>&1 \
        && tui_ok "aws  $(aws --version 2>/dev/null)" \
        || tui_warn "AWS CLI not found – install from https://aws.amazon.com/cli/" ;;
    azure)
      command -v az >/dev/null 2>&1 \
        && tui_ok "az  $(az --version 2>/dev/null | head -1)" \
        || tui_warn "Azure CLI not found – install from https://aka.ms/installazurecli" ;;
  esac

  if [[ "$runtime" == "docker" && "$docker_host" != "cloud" ]]; then
    # Local all-in-one: actually install + start Docker on this host.
    ensure_docker_local
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# GCP AUTH CHECK
# Makes the script work one-shot on a brand-new jump host for GCP.  Ensures:
#   1. the user is logged in to gcloud (gcloud auth login), and
#   2. Application Default Credentials exist (gcloud auth application-default
#      login) – required for the Compute REST API calls the script makes.
# If either is missing it prints the command and offers to run it interactively.
# ──────────────────────────────────────────────────────────────────────────────
# True if the account is the GCE VM's DEFAULT service account
# (NNN-compute@developer.gserviceaccount.com).  This appears automatically on a
# Compute Engine VM without any `gcloud auth login`, so it is NOT a real user
# login and must not satisfy the user-login check below.
_is_vm_default_service_account() {
  [[ "$1" == *"@developer.gserviceaccount.com" ]]
}

check_gcp_auth() {
  if ! command -v gcloud >/dev/null 2>&1; then
    tui_err "gcloud is not installed – cannot check GCP auth"
    return 1
  fi

  # 1. User login (gcloud auth login).  On a GCE VM the active account is the
  # VM's default service account, which is NOT a user login – so we still prompt.
  local acct
  acct=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
  if [[ -z "$acct" ]] || _is_vm_default_service_account "$acct"; then
    if _is_vm_default_service_account "$acct"; then
      tui_warn "Only the GCE VM's default service account is active (${acct})."
      tui_info "That is not a user login – a real account is required for gcloud compute commands."
    else
      tui_warn "You are not logged in to Google Cloud."
    fi
    tui_info "Run:  ${BOLD}gcloud auth login${RESET}   (browser opens, or it prints a URL + code)"
    echo
    tui_confirm _launch "Launch gcloud auth login now?" "Y"
    if [[ "$_launch" == "true" ]]; then
      gcloud auth login
      acct=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
      if [[ -z "$acct" ]] || _is_vm_default_service_account "$acct"; then
        tui_err "Still not authenticated with a user account.  Run 'gcloud auth login' manually and re-run the wizard."
        exit 1
      fi
    else
      tui_err "GCP login is required to continue.  Run 'gcloud auth login' and re-run the wizard."
      exit 1
    fi
  fi
  tui_ok "GCP authenticated as ${BOLD}${acct}${RESET}"

  # 2. Application Default Credentials – needed for the Compute REST API and
  # terraform.  We require the well-known ADC *file* to exist (not just a token)
  # because on a GCE jump host the metadata server returns the VM service-account
  # token, which may lack the compute scope and break terraform with
  # "insufficient authentication scopes".  A real authorized_user file from
  # `gcloud auth application-default login` always carries cloud-platform.
  local adc_file="${HOME}/.config/gcloud/application_default_credentials.json"
  if [[ ! -f "$adc_file" ]] || ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
    tui_warn "Application Default Credentials (ADC) are missing."
    tui_info "The script needs an ADC file (cloud-platform scope) for GCP API calls."
    tui_info "Run:  ${BOLD}gcloud auth application-default login${RESET}"
    echo
    tui_confirm _launch_adc "Set up ADC now?" "Y"
    if [[ "$_launch_adc" == "true" ]]; then
      gcloud auth application-default login \
        --scopes=https://www.googleapis.com/auth/cloud-platform
      if [[ ! -f "$adc_file" ]] || ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
        tui_err "ADC setup failed.  Run 'gcloud auth application-default login' and re-run the wizard."
        exit 1
      fi
    else
      tui_err "ADC is required to continue.  Run 'gcloud auth application-default login' and re-run the wizard."
      exit 1
    fi
  fi
  tui_ok "ADC valid (compute access confirmed)"
}

# ──────────────────────────────────────────────────────────────────────────────
# SSH KEY MANAGEMENT
# ──────────────────────────────────────────────────────────────────────────────
configure_ssh_key() {
  tui_section "SSH Key Configuration"
  tui_info "PRIVATE key stays on this host – used by Bolt for all connections."
  tui_info "PUBLIC key is baked into Terraform metadata AND pushed to all nodes."
  tui_blank

  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  else
    user_home="$HOME"
  fi
  local default_key="${ssh_key_path:-${user_home}/.ssh/id_rsa}"

  tui_prompt ssh_key_path "Path to SSH PRIVATE key" "$default_key"

  if [[ ! -f "$ssh_key_path" ]]; then
    tui_warn "Key not found at $ssh_key_path"
    local _gen
    tui_confirm _gen "Generate a new RSA-4096 key-pair here?" "Y"
    if [[ "$_gen" == "true" ]]; then
      mkdir -p "$(dirname "$ssh_key_path")"
      ssh-keygen -t rsa -b 4096 -N '' -f "$ssh_key_path" >/dev/null 2>&1 \
        || { tui_err "ssh-keygen failed"; exit 1; }
      chmod 600 "$ssh_key_path"
      chmod 644 "${ssh_key_path}.pub"
      tui_ok "Key-pair generated: $ssh_key_path"
    else
      tui_err "No SSH key – cannot continue."; exit 1
    fi
  fi

  if ! ssh-keygen -l -f "$ssh_key_path" >/dev/null 2>&1; then
    tui_err "Cannot read key at $ssh_key_path – check permissions/format."; exit 1
  fi

  # Normalise to an absolute path.  Bolt resolves a relative private-key path
  # against ~/.puppetlabs/bolt/ (not the inventory file or CWD), so a bare
  # relative path like "id_ed25519" would break every connection.
  if [[ "$ssh_key_path" != /* ]]; then
    ssh_key_path="$(cd "$(dirname "$ssh_key_path")" && pwd)/$(basename "$ssh_key_path")"
  fi

  local pub_key="${ssh_key_path}.pub"
  if [[ ! -f "$pub_key" ]]; then
    tui_warn "Public key $pub_key missing – regenerating…"
    ssh-keygen -y -f "$ssh_key_path" > "$pub_key" \
      || { tui_err "Could not derive public key"; exit 1; }
    chmod 644 "$pub_key"
  fi

  tui_ok "Private key : $ssh_key_path"
  tui_ok "Public key  : $pub_key"
  tui_info "Fingerprint : $(ssh-keygen -l -f "$ssh_key_path" | awk '{print $2, $4}')"

  # Requirements on the TARGET nodes, or the wizard's connections will fail.
  tui_blank
  tui_warn "THE TARGET NODES MUST SATISFY THESE, OR THE SCRIPT WILL FAIL:"
  tui_warn "  1. The PUBLIC key at ${BOLD}$pub_key${RESET} must already be present on each"
  tui_warn "     target in the ssh_user's \`~/.ssh/authorized_keys\`"
  tui_warn "     (for user \`${ssh_user}\` that is commonly \`/root/.ssh/authorized_keys\`)."
  tui_warn "  2. \`/etc/ssh/sshd_config\` on each target must have these UNCOMMENTED"
  tui_warn "     (not hashed out):"
  tui_warn "       PubkeyAuthentication yes"
  tui_warn "       AuthorizedKeysFile  .ssh/authorized_keys"
  tui_warn "  3. The \`~/.ssh\` and \`~/.ssh/authorized_keys\` permissions must let sshd"
  tui_warn "     read the key (commonly \`chmod 700 ~/.ssh\` and \`chmod 600 ~/.ssh/authorized_keys\`)."
  tui_warn "If any target is missing these, the SSH/bootstrap step will fail.  Either fix"
  tui_warn "them on the target, bake the key + sshd settings into the base image/VM, and re-run."
  tui_blank

  # For non-root sudo bolt, copy key where sudo can read it
  if [[ $EUID -ne 0 ]]; then
    local tmp_key="/tmp/bolt_key_$$"
    cp "$ssh_key_path" "$tmp_key"
    chmod 600 "$tmp_key"
    bolt_ssh_key="$tmp_key"
    tui_info "Bolt key copy: $bolt_ssh_key"
  else
    bolt_ssh_key="$ssh_key_path"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# SSH KEY TARGET PRE-FLIGHT PAUSE
# Called AFTER Terraform creates the VMs (cloud/VM base-image deployments) but
# BEFORE the wizard tries to SSH into them.  Fresh base-image VMs may not have
# our public key or PubkeyAuthentication enabled, and the wizard cannot reach
# them yet (chicken-and-egg), so we stop and let the user confirm/fix manually.
# ──────────────────────────────────────────────────────────────────────────────
ssh_key_target_preflight() {
  local pub="${ssh_key_path}.pub"
  local core0_fqdn; core0_fqdn=$(build_fqdn core0)
  local max_retries=4 interval=15 retry=0
  local _ok

  tui_section "SSH Key Pre-flight (target VMs)"
  tui_info "Verifying the wizard can SSH into the freshly-created target"
  tui_info "  ${BOLD}${ssh_user}@${core0_fqdn}${RESET}  using key ${BOLD}${ssh_key_path}${RESET}."

  # Actually test SSH with the key.  Retry briefly to let the VM finish booting,
  # then ONLY pause if SSH genuinely fails (bad/missing key, sshd not accepting
  # it, etc.).  If SSH works, we proceed without interrupting the user.
  while (( retry < max_retries )); do
    if timeout 15 ssh -i "$ssh_key_path" -p 22 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 "${ssh_user}@${core0_fqdn}" "echo ok" >/dev/null 2>&1; then
      tui_ok "SSH connectivity verified on ${core0_fqdn} with ${ssh_key_path} – no action needed."
      tui_blank
      return 0
    fi
    retry=$((retry+1))
    if (( retry < max_retries )); then
      tui_info "Not reachable yet (attempt ${retry}/${max_retries}) – retrying in ${interval}s"
      sleep "$interval"
    fi
  done

  # SSH failed – pause and tell the user exactly what to do.
  tui_warn "Could NOT reach ${core0_fqdn} (${ssh_user}@${core0_fqdn}:22) with the SSH key"
  tui_warn "  ${ssh_key_path}"
  tui_warn "This usually means the PUBLIC key is not yet on the target, or sshd is not"
  tui_warn "accepting it.  The wizard cannot continue until SSH works."
  tui_blank
  tui_warn "On EACH target node, confirm ALL of these are true before continuing:"
  tui_warn "  1. Public key (${pub}) is present in the ssh_user's"
  tui_warn "     \`~/.ssh/authorized_keys\`  (for \`${ssh_user}\` commonly /root/.ssh/authorized_keys)."
  tui_warn "     Copy the contents of \`${pub}\` and append it to \`~/.ssh/authorized_keys\`."
  tui_warn "  2. \`/etc/ssh/sshd_config\` has, UNCOMMENTED (not hashed out):"
  tui_warn "       PubkeyAuthentication yes"
  tui_warn "       AuthorizedKeysFile .ssh/authorized_keys"
  tui_warn "  3. \`~/.ssh\` and \`~/.ssh/authorized_keys\` permissions allow sshd to read the key."
  tui_blank
  tui_confirm _ok "Are keys + PubkeyAuthentication now in place on ALL targets?" "Y"
  if [[ "$_ok" == "true" ]]; then
    tui_ok "Proceeding with the existing keys."
  else
    tui_warn "If they are NOT in the base image, add them manually on each target now"
    tui_warn "(append the public key to \`~/.ssh/authorized_keys\`, enable PubkeyAuthentication)."
    tui_prompt _sp_ready "Press ENTER once keys are in place on all targets (or Ctrl-C to abort)"
  fi
  tui_blank
}

# ──────────────────────────────────────────────────────────────────────────────
# BOLT INVENTORY HELPER
# Returns the --inventoryfile flag string for use in every bolt call
# ──────────────────────────────────────────────────────────────────────────────
bolt_inv() { echo "--inventoryfile ${script_dir}/inventory.yaml"; }

# ──────────────────────────────────────────────────────────────────────────────
# GENERATE TERRAFORM – GCP
# ──────────────────────────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────────────────────
# TOOL UPDATES – check bolt and peadm for newer versions and offer to update.
# Run early in pelab.sh (right after the dependency install) so the user can
# bring the tooling up to date before provisioning.  Best-effort: if the Forge
# or apt is unreachable (offline lab) it just reports and continues.
# ──────────────────────────────────────────────────────────────────────────────
# Returns 0 if version $1 is OLDER than $2 (i.e. an update is available).
_version_lt() {
  [[ "$1" == "$2" ]] && return 1
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V 2>/dev/null | head -1)" == "$1" ]]
}

check_tool_updates() {
  tui_section "Tool Updates (bolt / peadm)"

  # ── bolt: installed vs the apt candidate ──────────────────────────────────
  local _bcur _bcand
  _bcur=$(bolt --version 2>/dev/null | head -1)
  if command -v apt-get >/dev/null 2>&1; then
    (sudo apt-get update -qq >/dev/null 2>&1) || true
    _bcand=$(apt-cache policy puppet-bolt 2>/dev/null | awk '/Candidate:/{print $2}' | sed 's/-.*//')
  fi
  if [[ -n "$_bcur" && -n "$_bcand" ]] && _version_lt "$_bcur" "$_bcand"; then
    tui_warn "bolt ${_bcur} is installed – ${BOLD}${_bcand}${RESET} is available."
    local _upd
    tui_confirm _upd "Update bolt to ${_bcand} now?" "Y"
    if [[ "$_upd" == "true" ]]; then
      if sudo apt-get install -y -qq puppet-bolt >/dev/null 2>&1; then
        tui_ok "bolt updated to $(bolt --version 2>/dev/null | head -1)"
      else
        tui_warn "bolt update failed – continuing with ${_bcur}"
      fi
    fi
  elif [[ -n "$_bcur" && -n "$_bcand" ]]; then
    tui_ok "bolt ${_bcur} is up to date"
  else
    tui_info "bolt ${_bcur:-unknown} (could not determine the latest – offline?)"
  fi

  # ── peadm: installed vs the Forge's latest ────────────────────────────────
  local _pcur _plate _pfile="${HOME}/.puppetlabs/bolt/modules/peadm/metadata.json"
  _pcur=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$_pfile" 2>/dev/null \
            | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  _plate=$(curl -sf --max-time 10 https://forgeapi.puppet.com/v3/modules/puppetlabs-peadm 2>/dev/null \
             | jq -r '.current_release.version // empty' 2>/dev/null)
  if [[ -n "$_pcur" && -n "$_plate" ]] && _version_lt "$_pcur" "$_plate"; then
    tui_warn "peadm ${_pcur} is installed – ${BOLD}${_plate}${RESET} is available."
    local _updp
    tui_confirm _updp "Update peadm to ${_plate} now?" "Y"
    if [[ "$_updp" == "true" ]]; then
      ensure_peadm_module || tui_warn "peadm update failed – continuing with ${_pcur}"
    fi
  elif [[ -n "$_pcur" && -n "$_plate" ]]; then
    tui_ok "peadm ${_pcur} is up to date"
  else
    tui_info "peadm ${_pcur:-unknown} (could not reach the Forge – offline?)"
  fi
}
