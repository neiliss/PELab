# =============================================================================
# gcp.sh  –  extracted from setup.sh (lines 1598-1822)
# Sourced by pelab.sh.  Do not run directly.
# =============================================================================
tf_run() {
  local action="$1"; shift
  tui_step "terraform $action"
  # Guarantee terraform uses the user's ADC file (cloud-platform scope), not the
  # VM metadata service-account token which may lack the compute scope and fail
  # with "insufficient authentication scopes".
  local adc="${HOME}/.config/gcloud/application_default_credentials.json"
  if [[ -f "$adc" ]]; then
    export GOOGLE_APPLICATION_CREDENTIALS="$adc"
  fi
  (cd "$tf_dir_active" && terraform "$action" "$@")
}

# Destroy ONLY state-tracked resources that belong to the CURRENT prefix.
# A stale terraform state from a PRIOR prefix must not be destroyed here (the
# user asked to delete the NEW prefix's resources); gcp_destroy_existing handles
# those.  If the state has no current-prefix resources, skip terraform destroy
# and let the subsequent apply reconcile the stale state.
tf_destroy_current_prefix() {
  local has
  # `|| has=0`: with `set -e` (pelab.sh) a failed state pull here would
  # silently kill the wizard; treat any failure as "no matching resources".
  has=$(cd "$tf_dir_active" 2>/dev/null && terraform state pull 2>/dev/null \
        | jq -r --arg p "$nodeprefix" \
          '[.resources[]?.instances[]?.attributes.name // empty | select(startswith($p))] | length' 2>/dev/null) || has=0
  has="${has:-0}"
  if [[ "$has" -gt 0 ]]; then
    tf_run destroy -auto-approve -input=false || true
  else
    tui_info "Terraform state has no '${nodeprefix}' resources – skipping terraform destroy"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# GCP AUTH
# ──────────────────────────────────────────────────────────────────────────────
gcp_ensure_auth() {
  # Make any gcloud CLI command the user runs target the right project.
  if [[ -n "$gcp_project" ]]; then
    gcloud config set project "$gcp_project" >/dev/null 2>&1 || true
    tui_ok "gcloud project set to ${BOLD}${gcp_project}${RESET}"
  fi

  # Full one-shot credential setup: user login + ADC.
  check_gcp_auth

  # Force terraform (and gcloud libs) to use the user's ADC file rather than the
  # VM metadata service-account token.  On a jump host the VM's access scopes are
  # often limited (no compute), so the metadata token fails terraform apply with
  # "insufficient authentication scopes".  The authorized_user ADC file always
  # carries cloud-platform.
  local adc="${HOME}/.config/gcloud/application_default_credentials.json"
  if [[ -f "$adc" ]]; then
    export GOOGLE_APPLICATION_CREDENTIALS="$adc"
    tui_ok "terraform will use ADC: ${BOLD}${adc}${RESET}"
  fi

  # Verify we can obtain a usable compute token.  This works on GCE only if the
  # VM's access scopes include compute; otherwise gcp_get_token falls back to
  # gcloud ADC (which carries the compute scope).
  if gcp_get_token >/dev/null 2>&1; then
    tui_ok "GCP credentials valid (compute access confirmed)"
    return 0
  fi

  tui_info "No usable compute token – re-running ADC setup…"
  gcloud auth application-default login \
    --scopes=https://www.googleapis.com/auth/cloud-platform
  gcp_get_token >/dev/null 2>&1 && tui_ok "GCP credentials valid"
}

# Hard gate before any terraform apply: confirm the ADC token can actually reach
# the Compute API.  Catches the "insufficient authentication scopes" failure
# (VM metadata token with limited scopes) before terraform runs, with a clear
# message instead of a cryptic 403.
gcp_verify_compute() {
  local adc="${HOME}/.config/gcloud/application_default_credentials.json"
  if [[ ! -f "$adc" ]]; then
    tui_err "ADC file not found: ${adc}"
    tui_err "Run 'gcloud auth application-default login --scopes=https://www.googleapis.com/auth/cloud-platform' and re-run."
    exit 1
  fi
  export GOOGLE_APPLICATION_CREDENTIALS="$adc"
  local tok
  # `|| tok=""`: a failed token fetch must hit OUR error path, not set -e.
  tok=$(gcloud auth application-default print-access-token 2>/dev/null) || tok=""
  if [[ -z "$tok" ]]; then
    tui_err "Could not obtain an ADC access token."
    exit 1
  fi
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $tok" \
    "https://compute.googleapis.com/compute/v1/projects/${gcp_project}/zones/${full_zone}" 2>/dev/null) || code=""
  if [[ "$code" != "200" ]]; then
    tui_warn "GCP compute access check failed (HTTP $code) – ADC token lacks the compute scope."
    tui_info "Re-running ADC setup with the cloud-platform scope…"
    gcloud auth application-default login \
      --scopes=https://www.googleapis.com/auth/cloud-platform
    tok=$(gcloud auth application-default print-access-token 2>/dev/null) || tok=""
    code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $tok" \
      "https://compute.googleapis.com/compute/v1/projects/${gcp_project}/zones/${full_zone}" 2>/dev/null) || code=""
    if [[ "$code" != "200" ]]; then
      tui_err "GCP compute access still failing (HTTP $code)."
      tui_err "Run manually:  gcloud auth application-default login --scopes=https://www.googleapis.com/auth/cloud-platform"
      exit 1
    fi
  fi
  tui_ok "GCP compute access verified (HTTP 200)"
}

# Adopt orphaned per-prefix firewalls into terraform state.  Prior runs leave
# firewalls in GCP (created outside the current/empty per-prefix state), so a
# fresh apply would fail with "409 already exists".  If a firewall exists in GCP
# but is not in state, import it so apply manages (not recreates) it.
gcp_import_firewall() {
  local token
  token=$(gcp_get_token) \
    || { tui_info "No GCP token available – skipping firewall adoption check"; return 0; }

  # <terraform-resource>:<gcp-firewall-name>
  local _spec _res _name _code
  for _spec in "dockerhost:${nodeprefix}-dockerhost" "hieranano:${nodeprefix}-hieranano"; do
    _res="${_spec%%:*}"; _name="${_spec##*:}"
    tui_info "Checking for orphaned firewall ${BOLD}${_name}${RESET}…"
    _code=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $token" \
      "https://compute.googleapis.com/compute/v1/projects/${gcp_project}/global/firewalls/${_name}" 2>/dev/null) || _code=""
    if [[ "$_code" != "200" ]]; then
      tui_info "Firewall ${_name} not present in GCP (HTTP ${_code:-no-response}) – apply will create it"
      continue
    fi
    if (cd "$tf_dir_active" && terraform state list 2>/dev/null | grep -q "google_compute_firewall.${_res}"); then
      tui_info "Firewall ${_name} exists and is already tracked in terraform state"
      continue
    fi
    tui_info "Importing existing firewall ${BOLD}${_name}${RESET} into terraform state…"
    (cd "$tf_dir_active" && terraform import "google_compute_firewall.${_res}[0]" \
      "projects/${gcp_project}/global/firewalls/${_name}") \
      || tui_warn "Firewall import failed for ${_name} – apply may report 'already exists'"
  done
}

# GCP access token for the Compute REST API.
# On GCE the metadata token is instant, but only works if the VM's access
# scopes include compute/cloud-platform.  If the VM was created with limited
# scopes (e.g. no compute), fall back to the (slower) gcloud ADC token.
gcp_get_token() {
  local tok=""
  if curl -sf --max-time 10 -H "Metadata-Flavor: Google" \
      http://metadata.google.internal/computeMetadata/v1/instance/id \
      >/dev/null 2>&1; then
    local scopes
    scopes=$(curl -sf --max-time 10 -H "Metadata-Flavor: Google" \
      "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/scopes" 2>/dev/null)
    if [[ "$scopes" == *"cloud-platform"* || "$scopes" == *"compute"* ]]; then
      tok=$(curl -sf --max-time 10 -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
        | jq -r '.access_token' 2>/dev/null)
    fi
  fi
  if [[ -z "$tok" ]] && command -v gcloud >/dev/null 2>&1; then
    # Timeout: if the OAuth refresh hangs the wizard would otherwise sit silent
    # forever with no output after the "GCP compute access verified" line.
    tok=$(timeout 30 gcloud auth application-default print-access-token 2>/dev/null)
  fi
  [[ -n "$tok" ]] && echo "$tok"
}

# ──────────────────────────────────────────────────────────────────────────────
# GCP DESTROY EXISTING
# Terraform state may be empty even when instances matching the prefix already
# exist (e.g. created outside this config, or the state was lost).  `terraform
# destroy` only removes state-tracked resources, so we also delete any matching
# GCP instances directly before apply.
#
# Uses the compute REST API with the ADC token (the same credentials the
# Terraform provider uses) because the gcloud CLI may not be authenticated on
# this host (e.g. when running on GCE with a VM service account).
# ──────────────────────────────────────────────────────────────────────────────
gcp_destroy_existing() {
  tui_step "Destroying existing '${nodeprefix}' instances in GCP…"
  local token
  token=$(gcp_get_token) \
    || { tui_warn "Could not obtain GCP token – skipping GCP cleanup"; return 0; }

  local json
  json=$(curl -sf --max-time 15 -H "Authorization: Bearer $token" \
      "https://compute.googleapis.com/compute/v1/projects/${gcp_project}/aggregated/instances" 2>/dev/null) \
    || { tui_warn "Failed to query GCP instances"; return 0; }

  # Collect matching instances (skip TERMINATED ones – nothing to delete, and
  # some are protected against deletion, which would otherwise fail the DELETE).
  local instances=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    instances+=("$line")
  done < <(echo "$json" | jq -r --arg p "$nodeprefix" \
      '.items | to_entries[] | .key as $z | .value.instances[]? | select(.name | startswith($p)) | select(.status != "TERMINATED") | "\(.name)  \($z | sub("zones/"; ""))"')

  if [[ ${#instances[@]} -eq 0 ]]; then
    tui_info "No existing '${nodeprefix}' instances found"
    return 0
  fi

  # Fire ALL DELETE requests first (each is fast – it just starts the op),
  # collecting the operation names.  This avoids serial delete+wait per node.
  local ops=()
  for line in "${instances[@]}"; do
    local name zone op
    name=$(echo "$line" | awk '{print $1}')
    zone=$(echo "$line" | awk '{print $2}')
    tui_info "Deleting ${name} (${zone})"
    # `|| op=""`: a failed DELETE (e.g. protected/terminated instance) must
    # not kill the wizard under `set -e` – log and continue instead.
    op=$(curl -sf --max-time 15 -X DELETE -H "Authorization: Bearer $token" \
        "https://compute.googleapis.com/compute/v1/projects/${gcp_project}/zones/${zone}/instances/${name}" \
        | jq -r '.name' 2>/dev/null) || op=""
    if [[ -n "$op" ]]; then
      ops+=("$name $zone $op")
    else
      tui_warn "Failed to delete ${name}"
    fi
  done

  # Poll all operations together until every one is DONE (parallel wait).
  local remaining=${#ops[@]}
  local deadline=$(( $(date +%s) + 180 ))
  while (( remaining > 0 )); do
    local still=()
    for entry in "${ops[@]}"; do
      local name zone op st
      name=$(echo "$entry" | awk '{print $1}')
      zone=$(echo "$entry" | awk '{print $2}')
      op=$(echo "$entry" | awk '{print $3}')
      st=$(curl -sf --max-time 15 -H "Authorization: Bearer $token" \
          "https://compute.googleapis.com/compute/v1/projects/${gcp_project}/zones/${zone}/operations/${op}" \
          | jq -r '.status' 2>/dev/null)
      if [[ "$st" == "DONE" ]]; then
        tui_ok "Deleted ${name}"
      else
        still+=("$entry")
      fi
    done
    ops=("${still[@]}")
    remaining=${#ops[@]}
    if (( remaining > 0 )); then
      if (( $(date +%s) >= deadline )); then
        tui_warn "Timed out waiting for ${remaining} delete operation(s)"
        break
      fi
      sleep 3
    fi
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# STATIC INTERNAL IP AVAILABILITY
# Best-effort GCP scan to see whether a chosen internal IP is already in use in
# the project, so we can fail fast BEFORE terraform apply (which otherwise
# errors on the conflict and the wizard would keep waiting for SSH on an IP
# that was never created).
#   gcp_ip_in_use <ip> [exclude-instance-name]
#   returns 0 = in use, 1 = free, 2 = could not determine
# ──────────────────────────────────────────────────────────────────────────────
gcp_ip_in_use() {
  local ip="$1" exclude="${2:-}"
  local token
  token=$(gcp_get_token 2>/dev/null) || return 2

  # 1) Reserved internal addresses (google_compute_address / static reservations).
  local addrs
  addrs=$(curl -sf --max-time 20 -H "Authorization: Bearer $token" \
      "https://compute.googleapis.com/compute/v1/projects/${gcp_project}/aggregated/addresses" 2>/dev/null) \
    || return 2
  if echo "$addrs" | jq -r '.items | to_entries[] | .value.addresses[]? | .address' 2>/dev/null | grep -qx "$ip"; then
    return 0
  fi

  # 2) Instance network IPs (optionally excluding the dockerhost being replaced).
  local insts
  insts=$(curl -sf --max-time 20 -H "Authorization: Bearer $token" \
      "https://compute.googleapis.com/compute/v1/projects/${gcp_project}/aggregated/instances" 2>/dev/null) \
    || return 2
  if echo "$insts" | jq -r --arg ex "$exclude" \
      '.items | to_entries[] | .value.instances[]? | select(.name != $ex) | .networkInterfaces[]?.networkIP' 2>/dev/null | grep -qx "$ip"; then
    return 0
  fi
  return 1
}

# Warn/abort if the chosen static Docker-host IP is already in use.
gcp_check_static_ip() {
  local ip="$1" rc
  tui_info "Verifying static IP ${BOLD}${ip}${RESET} is free in project ${gcp_project}…"
  # NOTE: gcp_ip_in_use returns 1 when the IP is FREE (the good case) and 2
  # when it could not determine.  With `set -e` (pelab.sh) a bare call would
  # silently kill the wizard on the happy path – guard it explicitly.
  local rc=0
  gcp_ip_in_use "$ip" "${nodeprefix}dockerhost" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    tui_warn "Static Docker-host IP ${BOLD}${ip}${RESET} is ALREADY IN USE in project ${gcp_project}."
    tui_warn "Terraform apply would fail.  Pick a free IP, or use 'auto' for an ephemeral one."
    local _ok
    tui_confirm _ok "Continue anyway (apply will likely fail)?" "N"
    [[ "$_ok" == "true" ]] || { tui_err "Aborting – choose a different static IP."; exit 1; }
  elif [[ "$rc" -eq 2 ]]; then
    tui_info "Could not verify IP ${ip} availability – relying on terraform to catch conflicts."
  else
    tui_ok "Static Docker-host IP ${BOLD}${ip}${RESET} appears free in project ${gcp_project}."
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# DOCKER PROVIDER
# Provisions PE nodes as Docker containers on a custom bridge network.  Each
# container runs a systemd-enabled image with openssh-server so Bolt can connect
# exactly as it does to cloud VMs.  Container names are added to /etc/hosts so
# the host (and Bolt) can resolve them.
# ──────────────────────────────────────────────────────────────────────────────
