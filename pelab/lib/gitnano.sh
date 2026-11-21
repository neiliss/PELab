# =============================================================================
# gitnano.sh  –  extracted from setup.sh (lines 3971-4159)
# Sourced by pelab.sh.  Do not run directly.
# =============================================================================
set_gitnano_known_hosts() {
  [[ "$use_gitnano" != "true" ]] && return 0
  local _gcore; _gcore=$(build_fqdn core0)
  local _scan_host="" _scan_port="22"
  if [[ "$runtime" == "docker" ]]; then
    if [[ "$docker_host" == "local" ]]; then
      # Local all-in-one: container reachable via /etc/hosts at its IP on port 22.
      _scan_host="$_gcore"
      _scan_port="22"
    else
      _scan_host="$docker_host_ip"
      _scan_port="$(docker_ssh_port core0)"
    fi
  else
    _scan_host=$(getent hosts "$_gcore" | awk '{print $1}')
  fi
  if [[ -n "$_scan_host" ]]; then
    local _kh_line
    _kh_line=$(timeout 10 ssh-keyscan -p "$_scan_port" -t ed25519 "$_scan_host" 2>/dev/null | head -n1 || true)
    if [[ -n "$_kh_line" ]]; then
      local _kt _kv
      _kt=$(echo "$_kh_line" | awk '{print $2}')
      _kv=$(echo "$_kh_line" | awk '{print $3}')
      if [[ -n "$_kt" && -n "$_kv" ]]; then
        r10k_known_hosts="[{\"name\":\"${_gcore}\",\"type\":\"${_kt}\",\"key\":\"${_kv}\"}]"
        tui_ok "r10k known_hosts set for gitnano: ${_gcore}"
        return 0
      fi
    fi
  fi
  tui_warn "Could not scan host key for ${_gcore} – r10k may fail to reach gitnano"
}

# Installs gitnano (local control-repo manager) on the master (core0) after the
# PE install.  For Docker it runs inside the core0 container; for VM runs it
# runs on the core0 VM.  Seeds a minimal control-repo when no upstream is given.
install_gitnano() {
  [[ "$use_gitnano" != "true" ]] && return 0
  local core0="${nodeprefix}core0"
  local fqdn; fqdn=$(build_fqdn core0)
  gitnano_token=$(openssl rand -hex 16)
  local script="${script_dir}/gitnano.sh"
  ensure_gitnano_script

  # Apply configurable API port (default 5000).  gitnano.sh is regenerated each
  # run, so a global 5000→port substitution is safe (all 5000s are port refs).
  if [[ "$gitnano_port" != "5000" ]]; then
    sed -i "s/5000/$gitnano_port/g" "$script"
  fi

  tui_section "Local Git (gitnano) on ${core0}"
  # Determine the seed source (set in the wizard).  If a control-repo dir is
  # available, transfer it to core0 and pass its path to gitnano.sh as arg 4.
  local seed="${gitnano_seed_dir:-}"
  local seed_arg="none"
  if [[ -n "$seed" && -d "$seed" ]]; then
    seed_arg="/root/control-repo-seed"
  fi
  if [[ "$runtime" == "docker" ]]; then
    if [[ "$docker_host" == "local" ]]; then
      # Local all-in-one: the script is already on this host.  Pipe it straight
      # into the core0 container (/tmp is a tmpfs mount, so write to /root).
      docker exec -i "${core0}" bash -c 'cat > /root/gitnano.sh' < "$script"
      if [[ "$seed_arg" != "none" ]]; then
        tar -C "$(dirname "$seed")" -czf /tmp/control-repo-seed.tgz "$(basename "$seed")"
        docker exec -i "${core0}" bash -c 'mkdir -p /root/control-repo-seed && tar -xzf - -C /root/control-repo-seed --strip-components=1' < /tmp/control-repo-seed.tgz
      fi
      docker exec "${core0}" bash /root/gitnano.sh none "$fqdn" "$gitnano_token" "$seed_arg"
    else
      # Copy the script from the wizard host to the Docker-host VM, then into the
      # core0 container (dh_ssh runs on the VM, so the file must be there first).
      scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$script" "${ssh_user}@${docker_host_ip}:/tmp/gitnano.sh"
      # /tmp is a tmpfs mount inside the container, so `docker cp` would write to
      # the shadowed overlay layer and the file would be invisible.  Pipe the file
      # in via stdin instead, to a non-tmpfs path (/root).
      dh_ssh "docker exec -i ${core0} bash -c 'cat > /root/gitnano.sh' < /tmp/gitnano.sh"
      if [[ "$seed_arg" != "none" ]]; then
        tar -C "$(dirname "$seed")" -czf /tmp/control-repo-seed.tgz "$(basename "$seed")"
        scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          /tmp/control-repo-seed.tgz "${ssh_user}@${docker_host_ip}:/tmp/control-repo-seed.tgz"
        dh_ssh "docker exec -i ${core0} bash -c 'mkdir -p /root/control-repo-seed && tar -xzf - -C /root/control-repo-seed --strip-components=1' < /tmp/control-repo-seed.tgz"
      fi
      dh_ssh "docker exec ${core0} bash /root/gitnano.sh none $fqdn $gitnano_token $seed_arg"
    fi
  else
    scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$script" "${ssh_user}@${fqdn}:/tmp/gitnano.sh"
    if [[ "$seed_arg" != "none" ]]; then
      tar -C "$(dirname "$seed")" -czf /tmp/control-repo-seed.tgz "$(basename "$seed")"
      scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        /tmp/control-repo-seed.tgz "${ssh_user}@${fqdn}:/tmp/control-repo-seed.tgz"
      ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "${ssh_user}@${fqdn}" "mkdir -p /root/control-repo-seed && tar -xzf /tmp/control-repo-seed.tgz -C /root/control-repo-seed --strip-components=1"
    fi
    # gitnano.sh restarts sshd mid-run, which would drop this SSH session and
    # kill the rest of the script.  Run it detached with nohup and poll the log
    # for a completion marker instead.
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@${fqdn}" \
      "nohup bash /tmp/gitnano.sh none $fqdn $gitnano_token $seed_arg > /tmp/gitnano.log 2>&1 &"
    local _gdone=no
    for _ in $(seq 1 60); do
      if ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          "${ssh_user}@${fqdn}" \
          "grep -qE 'INSTALLATION COMPLETE|Install done' /tmp/gitnano.log 2>/dev/null"; then
        _gdone=yes; break
      fi
      sleep 10
    done
    if [[ "$_gdone" != "yes" ]]; then
      tui_warn "gitnano install may not have completed – see /tmp/gitnano.log on ${fqdn}"
    fi
  fi
  tui_ok "gitnano installed on ${core0} (token: ${gitnano_token})"
}

# Creates a minimal control-repo at /var/www/production on core0 when gitnano
# was NOT chosen, so hieranano always has a repo to browse.  (When gitnano IS
# chosen, /var/www/production is already the gitnano live worktree.)
ensure_control_repo() {
  local cname="$1" repo="$2"
  local cmd="mkdir -p ${repo}/manifests ${repo}/hieradata ${repo}/modules && cd ${repo} && git init -q 2>/dev/null; git checkout -q -b production 2>/dev/null; printf 'forge \"https://forge.puppet.com\"\n' > Puppetfile; printf '# Default node classification\nnode default { notify { \"control-repo ready\": } }\n' > manifests/site.pp; git add -A 2>/dev/null; git -c user.email=hieranano@localhost -c user.name=Hieranano commit -q -m 'Initial control-repo' 2>/dev/null || true"
  if [[ "$runtime" == "docker" ]]; then
    dh_ssh "docker exec ${cname} bash -c \"$cmd\"" >/dev/null 2>&1 || true
  else
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@$(build_fqdn core0)" "$cmd" >/dev/null 2>&1 || true
  fi
}

# Installs hieranano (Hiera/eyaml web UI) on the master (core0).  Always runs,
# regardless of gitnano.  hieranano.sh is embedded in setup.sh and written out
# by ensure_hieranano_script().  Runs non-interactively via HIERANANO_* env vars
# and is registered as a systemd service so it survives container restarts.
install_hieranano() {
  local core0="${nodeprefix}core0"
  local fqdn; fqdn=$(build_fqdn core0)
  hieranano_token=$(openssl rand -hex 16)
  local script="${script_dir}/hieranano.sh"
  ensure_hieranano_script

  # hieranano.sh prints its banner with a hardcoded 127.0.0.1 (it runs inside
  # the container and can't know the external address).  Point $script at a temp
  # copy with the real reachable URL + configurable port substituted.  hieranano
  # now serves HTTPS (self-signed) on the primary port, so the banner uses https.
  sed -e "s#http://127.0.0.1:5525#https://${fqdn}:${hieranano_port}#g" \
      -e "s/5525/${hieranano_port}/g" "$script" > /tmp/hieranano_public.sh
  script="/tmp/hieranano_public.sh"

  tui_section "Hieranano (Hiera/eyaml UI) on ${core0}"
  local repo="/var/www/production"
  local pubkey="/etc/puppetlabs/puppet/keys/public_key.pkcs7.pem"
  local privkey="/etc/puppetlabs/puppet/keys/private_key.pkcs7.pem"

  # hieranano needs a control-repo to browse.  If gitnano wasn't chosen, create
  # a minimal one at /var/www/production.
  if [[ "$use_gitnano" != "true" ]]; then
    ensure_control_repo "$core0" "$repo"
  fi

  # Install deps hieranano needs that the base image may lack (sqlite3 CLI,
  # lsof, python3-venv).  eyaml comes from the PE install.  Also generate the
  # eyaml PKCS7 keypair if PE hasn't created it yet (hieranano needs it to
  # encrypt/decrypt Hiera secrets).
  local deps="apt-get update -qq && apt-get install -y -qq sqlite3 lsof python3-venv openssl >/dev/null 2>&1; mkdir -p /etc/puppetlabs/puppet/keys && { [ -f /etc/puppetlabs/puppet/keys/public_key.pkcs7.pem ] || /opt/puppetlabs/puppet/bin/eyaml createkeys --pkcs7-private-key /etc/puppetlabs/puppet/keys/private_key.pkcs7.pem --pkcs7-public-key /etc/puppetlabs/puppet/keys/public_key.pkcs7.pem; } && chown pe-puppet:pe-puppet /etc/puppetlabs/puppet/keys/private_key.pkcs7.pem /etc/puppetlabs/puppet/keys/public_key.pkcs7.pem && chmod 600 /etc/puppetlabs/puppet/keys/private_key.pkcs7.pem && chmod 644 /etc/puppetlabs/puppet/keys/public_key.pkcs7.pem || true"

  local run_cmd
  run_cmd="NONINTERACTIVE=1 HIERANANO_CONTROL_REPO_DIR='$repo' HIERANANO_EYAML_PUB_KEY='$pubkey' HIERANANO_EYAML_PRIV_KEY='$privkey' bash /root/hieranano.sh '$hieranano_token'"

  local svc
  svc=$'mkdir -p /root/.hieranano\n[ -f /root/.hieranano/hieranano.key ] || openssl req -x509 -newkey rsa:2048 -nodes -keyout /root/.hieranano/hieranano.key -out /root/.hieranano/hieranano.crt -days 3650 -subj "/CN=$(hostname -f)" 2>/dev/null\ncat > /etc/systemd/system/hieranano.service <<\'EOF\'\n[Unit]\nDescription=Hieranano Service (HTTPS)\nAfter=network.target\n[Service]\nUser=root\nWorkingDirectory=/root/.hieranano\nExecStart=/root/.hieranano/venv/bin/gunicorn --workers 1 --bind 0.0.0.0:5525 --certfile /root/.hieranano/hieranano.crt --keyfile /root/.hieranano/hieranano.key --chdir /root/.hieranano app:app\nRestart=always\n[Install]\nWantedBy=multi-user.target\nEOF\ncat > /etc/systemd/system/hieranano-http.service <<\'EOF\'\n[Unit]\nDescription=Hieranano Service (HTTP fallback)\nAfter=network.target\n[Service]\nUser=root\nWorkingDirectory=/root/.hieranano\nExecStart=/root/.hieranano/venv/bin/gunicorn --workers 1 --bind 0.0.0.0:5526 --chdir /root/.hieranano app:app\nRestart=always\n[Install]\nWantedBy=multi-user.target\nEOF\npkill -f \'gunicorn.*app:app\' 2>/dev/null || true\nsystemctl daemon-reload || true\nsystemctl enable hieranano hieranano-http >/dev/null 2>&1 || true\nif ! systemctl restart hieranano >/dev/null 2>&1; then\n  (cd /root/.hieranano && nohup venv/bin/python -m gunicorn --workers 1 --bind 0.0.0.0:5525 --certfile /root/.hieranano/hieranano.crt --keyfile /root/.hieranano/hieranano.key --chdir /root/.hieranano app:app >> /root/.hieranano/runtime.log 2>&1 &)\nfi\nsystemctl restart hieranano-http >/dev/null 2>&1 || true\ntrue'

  # Post-install verification: ensure both services are enabled (auto-start on
  # container restart) and running.  Retries enable/start so a transient failure
  # during install doesn't leave hieranano down.
  local verify
  verify=$'systemctl enable hieranano hieranano-http >/dev/null 2>&1 || true\nsystemctl restart hieranano hieranano-http >/dev/null 2>&1 || true\nsleep 1\nsystemctl is-active hieranano >/dev/null 2>&1 || systemctl start hieranano >/dev/null 2>&1 || true\nsystemctl is-active hieranano-http >/dev/null 2>&1 || systemctl start hieranano-http >/dev/null 2>&1 || true\nsystemctl is-enabled hieranano >/dev/null 2>&1 || systemctl enable hieranano >/dev/null 2>&1 || true\nsystemctl is-enabled hieranano-http >/dev/null 2>&1 || systemctl enable hieranano-http >/dev/null 2>&1 || true\ntrue'

  if [[ "$runtime" == "docker" ]]; then
    if [[ "$docker_host" == "local" ]]; then
      docker exec -i "${core0}" bash -c 'cat > /root/hieranano.sh' < "$script"
      docker exec "${core0}" bash -c "$deps && $run_cmd"
      docker exec "${core0}" bash -c "$svc"
      docker exec "${core0}" bash -c "$verify"
    else
      scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$script" "${ssh_user}@${docker_host_ip}:/tmp/hieranano.sh"
      dh_ssh "docker exec -i ${core0} bash -c 'cat > /root/hieranano.sh' < /tmp/hieranano.sh"
      dh_ssh "docker exec ${core0} bash -c \"$deps && $run_cmd\""
      dh_ssh "docker exec ${core0} bash -c \"$svc\""
      dh_ssh "docker exec ${core0} bash -c \"$verify\""
    fi
  else
    scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$script" "${ssh_user}@${fqdn}:/tmp/hieranano.sh"
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@${fqdn}" "$deps && $run_cmd"
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@${fqdn}" "$svc"
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@${fqdn}" "$verify"
  fi
  tui_ok "hieranano installed on ${core0} (token: ${hieranano_token})"
}

# Installs openainano (PE AI infra-assistant ↔ local Ollama bridge) on the master
# (core0) after the PE install.  It runs a Flask bridge on port 5000 that
# translates PE's AI requests to a local Ollama instance (127.0.0.1:11434).
# Installed by default (use_openainano=true).  openainano.sh is embedded in
# setup.sh and written out by ensure_openainano_script().
install_openainano() {
  [[ "$use_openainano" != "true" ]] && return 0
  local core0="${nodeprefix}core0"
  local fqdn; fqdn=$(build_fqdn core0)
  local script="${script_dir}/openainano.sh"
  ensure_openainano_script

  # Apply configurable values (Ollama model, port) with defaults.
  if [[ "$openainano_model" != "minimax-m2.5:cloud" ]]; then
    sed -i "s/TARGET_MODEL=\"[^\"]*\"/TARGET_MODEL=\"$openainano_model\"/g; s/TARGET_MODEL = \"[^\"]*\"/TARGET_MODEL = \"$openainano_model\"/g" "$script"
  fi
  # openainano.sh is write-if-missing, so only substitute when the port differs
  # from the embedded default (5000).  Both 5000s in the script are port refs.
  if [[ "$openainano_port" != "5000" ]]; then
    sed -i "s/5000/$openainano_port/g" "$script"
  fi

  tui_section "OpenAINano (PE AI ↔ Ollama bridge) on ${core0}"
  tui_info "openainano runs a Flask bridge on port ${openainano_port} that translates PE's AI"
  tui_info "infra-assistant to a local Ollama instance (http://127.0.0.1:11434)."
  tui_info "It is registered as a systemd service (openainano.service)."
  tui_info "Ollama will be installed on ${core0} too (a local model is not powerful enough,"
  tui_info "so you'll authenticate with 'ollama login' and pull a cloud model)."

  local run_cmd="bash /root/openainano.sh"

  if [[ "$runtime" == "docker" ]]; then
    if [[ "$docker_host" == "local" ]]; then
      docker exec -i "${core0}" bash -c 'cat > /root/openainano.sh' < "$script"
      docker exec "${core0}" bash -c "$run_cmd"
    else
      scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$script" "${ssh_user}@${docker_host_ip}:/tmp/openainano.sh"
      dh_ssh "docker exec -i ${core0} bash -c 'cat > /root/openainano.sh' < /tmp/openainano.sh"
      dh_ssh "docker exec ${core0} bash -c \"$run_cmd\""
    fi
  else
    scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$script" "${ssh_user}@${fqdn}:/tmp/openainano.sh"
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@${fqdn}" "cat > /root/openainano.sh < /tmp/openainano.sh && bash /root/openainano.sh"
  fi
  tui_ok "openainano installed on ${core0} (port ${openainano_port})"

  # ── Install Ollama on the master (openainano's bridge targets 127.0.0.1:11434).
  #    A local model is not powerful enough, so the user must authenticate with
  #    `ollama login` and pull a CLOUD model with `ollama run <model>`. ──────
  local ollama_script="${script_dir}/install_ollama.sh"
  ensure_ollama_script
  tui_section "Installing Ollama on ${core0}"
  tui_info "openainano needs Ollama (http://127.0.0.1:11434); installing if absent."
  local ollama_cmd="bash /root/install_ollama.sh '$openainano_model'"
  if [[ "$runtime" == "docker" ]]; then
    if [[ "$docker_host" == "local" ]]; then
      docker exec -i "${core0}" bash -c 'cat > /root/install_ollama.sh' < "$ollama_script"
      docker exec "${core0}" bash -c "$ollama_cmd"
    else
      scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$ollama_script" "${ssh_user}@${docker_host_ip}:/tmp/install_ollama.sh"
      dh_ssh "docker exec -i ${core0} bash -c 'cat > /root/install_ollama.sh' < /tmp/install_ollama.sh"
      dh_ssh "docker exec ${core0} bash -c \"$ollama_cmd\""
    fi
  else
    scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$ollama_script" "${ssh_user}@${fqdn}:/tmp/install_ollama.sh"
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@${fqdn}" "cat > /root/install_ollama.sh < /tmp/install_ollama.sh && $ollama_cmd"
  fi
  tui_ok "Ollama installed on ${core0} – run 'ollama login' then 'ollama run ${openainano_model}'"
}


install_reponano() {
  [[ "$use_reponano" != "true" ]] && return 0
  local core0="${nodeprefix}core0"
  local fqdn; fqdn=$(build_fqdn core0)
  local script="${script_dir}/reponano.sh"
  ensure_reponano_script

  # Apply configurable values (port) with defaults.
  if [[ "$reponano_port" != "3864" ]]; then
    sed -i "s/^PORT=[0-9]*/PORT=$reponano_port/; s/^PORT = [0-9]*/PORT = $reponano_port/" "$script"
  fi

  tui_section "Reponano (local apt/yum package repo) on ${core0}"
  tui_info "reponano hosts a local apt/yum repo on port 3864 (Flask + systemd)."
  tui_info "Offline nodes point their package manager at http://${fqdn}:3864/repo/…"
  tui_info "Client toggle: /root/reponano_client.sh <reponano-host>  (--restore to go back online)"

  local run_cmd="bash /root/reponano.sh"

  if [[ "$runtime" == "docker" ]]; then
    if [[ "$docker_host" == "local" ]]; then
      docker exec -i "${core0}" bash -c 'cat > /root/reponano.sh' < "$script"
      docker exec "${core0}" bash -c "$run_cmd"
    else
      scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$script" "${ssh_user}@${docker_host_ip}:/tmp/reponano.sh"
      dh_ssh "docker exec -i ${core0} bash -c 'cat > /root/reponano.sh' < /tmp/reponano.sh"
      dh_ssh "docker exec ${core0} bash -c \"$run_cmd\""
    fi
  else
    scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$script" "${ssh_user}@${fqdn}:/tmp/reponano.sh"
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@${fqdn}" "cat > /root/reponano.sh < /tmp/reponano.sh && bash /root/reponano.sh"
  fi
  tui_ok "reponano installed on ${core0} (port 3864)"

  # ── Full offline build: pull the package manifest + switch the repo ──────
  if [[ "$full_offline" == "true" ]]; then
    reponano_full_sync
    # NOTE: reponano_offline_switch runs AFTER forgenano populates + we sync its
    # module-required OS packages (see install_forgenano), so clients see every
    # package the lab needs before they go offline.
  fi
}

install_forgenano() {
  [[ "$use_forgenano" != "true" ]] && return 0
  local core0="${nodeprefix}core0"
  local fqdn; fqdn=$(build_fqdn core0)
  local script="${script_dir}/forgenano.sh"
  ensure_forgenano_script

  # Build a DEPLOY copy with config injected (port, admin key, Forge token)
  # WITHOUT modifying the source ${script_dir}/forgenano.sh – so the repo copy
  # stays clean / no token leakage.  Tokens live in the config .json and are
  # never committed into the .sh source.
  local _fgtmp; _fgtmp="$(mktemp)"
  cp -f "$script" "$_fgtmp"
  if [[ "$forgenano_port" != "6157" ]]; then
    sed -i "s/^PORT=[0-9]*/PORT=$forgenano_port/" "$_fgtmp"
  fi
  sed -i "s/^ADMIN_KEY=\"[^\"]*\"/ADMIN_KEY=\"$forgenano_admin_key\"/" "$_fgtmp"
  sed -i "s/^FORGE_TOKEN=\"[^\"]*\"/FORGE_TOKEN=\"$forgenano_forge_token\"/" "$_fgtmp"

  tui_section "Forgenano (local Puppet Forge / module mirror) on ${core0}"
  tui_info "forgenano mirrors Puppet Forge modules to a local repo on port 6157 (Flask + systemd)."
  tui_info "Offline nodes install modules from http://${fqdn}:6157 instead of the public Forge."
  tui_info "Populate: /root/forgenano_populate.sh   |   Workflow: /root/forgenano_local.sh"

  local run_cmd="bash /root/forgenano.sh"

  if [[ "$runtime" == "docker" ]]; then
    if [[ "$docker_host" == "local" ]]; then
      docker exec -i "${core0}" bash -c 'cat > /root/forgenano.sh' < "$_fgtmp"
      docker exec "${core0}" bash -c "$run_cmd"
    else
      scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$_fgtmp" "${ssh_user}@${docker_host_ip}:/tmp/forgenano.sh"
      dh_ssh "docker exec -i ${core0} bash -c 'cat > /root/forgenano.sh' < /tmp/forgenano.sh"
      dh_ssh "docker exec ${core0} bash -c \"$run_cmd\""
    fi
  else
    scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$_fgtmp" "${ssh_user}@${fqdn}:/tmp/forgenano.sh"
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@${fqdn}" "cat > /root/forgenano.sh < /tmp/forgenano.sh && bash /root/forgenano.sh"
  fi
  rm -f "$_fgtmp"
  tui_ok "forgenano installed on ${core0} (port ${forgenano_port})"

  # ── Ensure PDK is present on the master.  forgenano's /v3/modules endpoint
  #    runs `pdk build` to package each mirrored module, but PDK is NOT part of
  #    the PE install or the base image.  Run a standalone script (not an inline
  #    command) so the codename vars are evaluated inside the container. ──────
  local pdk_script="${script_dir}/ensure_pdk.sh"
  ensure_pdk_script
  tui_section "Ensuring PDK on ${core0}"
  tui_info "forgenano needs PDK to build mirrored modules; installing if absent."
  if [[ "$runtime" == "docker" ]]; then
    if [[ "$docker_host" == "local" ]]; then
      docker exec -i "${core0}" bash -c 'cat > /root/ensure_pdk.sh' < "$pdk_script"
      docker exec "${core0}" bash /root/ensure_pdk.sh
    else
      scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$pdk_script" "${ssh_user}@${docker_host_ip}:/tmp/ensure_pdk.sh"
      dh_ssh "docker exec -i ${core0} bash -c 'cat > /root/ensure_pdk.sh' < /tmp/ensure_pdk.sh"
      dh_ssh "docker exec ${core0} bash /root/ensure_pdk.sh"
    fi
  else
    scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$pdk_script" "${ssh_user}@${fqdn}:/tmp/ensure_pdk.sh"
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@${fqdn}" "cat > /root/ensure_pdk.sh < /tmp/ensure_pdk.sh && bash /root/ensure_pdk.sh"
  fi

  # ── Mirror the control-repo Puppetfile modules into forgenano, then point
  #    the Puppetfile at the local forge. ────────────────────────────────────
  local sync_script="${script_dir}/forgenano_sync.sh"
  ensure_forgenano_sync_script
  local sync_cmd="bash /root/forgenano_sync.sh '$forgenano_forge_token' '$forgenano_admin_key' '$forgenano_port'"
  tui_section "Forgenano sync (Puppetfile → local forge)"
  tui_info "Mirroring the modules in the control-repo Puppetfile into forgenano,"
  tui_info "then pointing the Puppetfile at http://${fqdn}:${forgenano_port}."
  if [[ "$runtime" == "docker" ]]; then
    if [[ "$docker_host" == "local" ]]; then
      docker exec -i "${core0}" bash -c 'cat > /root/forgenano_sync.sh' < "$sync_script"
      docker exec "${core0}" bash -c "$sync_cmd"
    else
      scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$sync_script" "${ssh_user}@${docker_host_ip}:/tmp/forgenano_sync.sh"
      dh_ssh "docker exec -i ${core0} bash -c 'cat > /root/forgenano_sync.sh' < /tmp/forgenano_sync.sh"
      dh_ssh "docker exec ${core0} bash -c \"$sync_cmd\""
    fi
  else
    scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$sync_script" "${ssh_user}@${fqdn}:/tmp/forgenano_sync.sh"
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@${fqdn}" "cat > /root/forgenano_sync.sh < /tmp/forgenano_sync.sh && $sync_cmd"
  fi
  tui_ok "forgenano sync complete – modules mirrored (Puppetfile left unchanged)"

  # ── Full offline build: pull the full forgenano module catalog ──────────
  if [[ "$full_offline" == "true" ]]; then
    local pop_script="${script_dir}/forgenano_populate.sh"
    ensure_forgenano_script   # ensures forgenano_populate.sh is written
    # Admin key + Forge token are passed as ARGS at runtime (never baked into
    # the source file, so the repo copy stays clean / no token leakage).

    # Puppetfile to mirror modules from: the active control-repo Puppetfile
    # (contains all modules incl. premium).  forgenano parses it at runtime so
    # the local forge has every module the control-repo will eventually need.
    local pf_full="" pf_target=/tmp/puppetfile_forgenano
    if [[ -f "${script_dir}/control-repo/Puppetfile" ]]; then
      pf_full="${script_dir}/control-repo/Puppetfile"
    fi

    tui_section "Forgenano full offline sync (pulling full module catalog)"
    if [[ -n "$pf_full" ]]; then
      tui_info "Mirroring modules from $(basename "$pf_full") (incl. premium) into the local forge on ${core0}."
    else
      tui_info "Mirroring the built-in forgenano module catalog into the local forge on ${core0}."
    fi
    local pop_cmd="bash /root/forgenano_populate.sh${pf_full:+ $pf_target} '$forgenano_admin_key' '$forgenano_forge_token'"
    local pf_host=/tmp/puppetfile_forgenano.host
    if [[ "$runtime" == "docker" ]]; then
      if [[ "$docker_host" == "local" ]]; then
        docker exec -i "${core0}" bash -c 'cat > /root/forgenano_populate.sh' < "$pop_script"
        [[ -n "$pf_full" ]] && docker exec -i "${core0}" bash -c "cat > $pf_target" < "$pf_full"
        docker exec "${core0}" bash -c "$pop_cmd"
      else
        scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          "$pop_script" "${ssh_user}@${docker_host_ip}:/tmp/forgenano_populate.sh"
        dh_ssh "docker exec -i ${core0} bash -c 'cat > /root/forgenano_populate.sh' < /tmp/forgenano_populate.sh"
        if [[ -n "$pf_full" ]]; then
          scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "$pf_full" "${ssh_user}@${docker_host_ip}:$pf_host"
          dh_ssh "docker exec -i ${core0} bash -c 'cat > $pf_target' < $pf_host"
        fi
        dh_ssh "docker exec ${core0} bash -c \"$pop_cmd\""
      fi
    else
      scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$pop_script" "${ssh_user}@${fqdn}:/tmp/forgenano_populate.sh"
      [[ -n "$pf_full" ]] && scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$pf_full" "${ssh_user}@${fqdn}:$pf_target"
      ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "${ssh_user}@${fqdn}" "cat > /root/forgenano_populate.sh < /tmp/forgenano_populate.sh && $pop_cmd"
    fi
    tui_ok "forgenano full offline sync complete"
    # Close the circular offline loop: pull the OS packages forgenano's built
    # modules declare (e.g. grafana module -> grafana package) into reponano,
    # then switch the master + every client to the (now complete) local repo.
    reponano_forgenano_sync
    reponano_offline_switch
    install_forgenano_offline_heal
  fi
}

# ──────────────────────────────────────────────────────────────────────────
# OFFLINE-BUILD HELPERS (reponano)
# ──────────────────────────────────────────────────────────────────────────

# Deploy + run reponano_client.sh on a single node, pointing it at the master.
reponano_client_deploy_one() {
  local role="$1" master_fqdn="$2"
  local node; node=$(build_fqdn "$role")
  local client="${script_dir}/reponano_client.sh"
  ensure_reponano_script   # ensures reponano_client.sh is written
  if [[ "$runtime" == "docker" ]]; then
    local cname="${nodeprefix}${role}"
    if [[ "$docker_host" == "local" ]]; then
      docker exec -i "$cname" bash -c 'cat > /root/reponano_client.sh && chmod +x /root/reponano_client.sh' < "$client"
      docker exec "$cname" bash /root/reponano_client.sh "$master_fqdn"
    else
      dh_ssh "docker exec -i ${cname} bash -c 'cat > /root/reponano_client.sh && chmod +x /root/reponano_client.sh'" < "$client"
      dh_ssh "docker exec ${cname} bash /root/reponano_client.sh '$master_fqdn'"
    fi
  else
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=20 "${ssh_user}@${node}" \
      "cat > /root/reponano_client.sh && chmod +x /root/reponano_client.sh && bash /root/reponano_client.sh '$master_fqdn'" < "$client"
  fi
  tui_ok "reponano_client.sh -> ${node} (offline, pointing at ${master_fqdn})"
}

# Pull the full package manifest into reponano (runs on the master).
reponano_full_sync() {
  [[ "$full_offline" != "true" ]] && return 0
  local core0="${nodeprefix}core0"
  local fqdn; fqdn=$(build_fqdn core0)
  local script="${script_dir}/reponano_full_sync.sh"
  ensure_reponano_full_sync_script
  tui_section "Reponano full offline sync (pulling full package manifest)"
  tui_info "Downloading every package in the manifest (with deps) into reponano on ${core0}."
  local run_cmd="bash /root/reponano_full_sync.sh localhost $reponano_port ubuntu"  # VER/ARCH auto-detected on the master
  if [[ "$runtime" == "docker" ]]; then
    if [[ "$docker_host" == "local" ]]; then
      docker exec -i "${core0}" bash -c 'cat > /root/reponano_full_sync.sh' < "$script"
      docker exec "${core0}" bash -c "$run_cmd"
    else
      scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$script" "${ssh_user}@${docker_host_ip}:/tmp/reponano_full_sync.sh"
      dh_ssh "docker exec -i ${core0} bash -c 'cat > /root/reponano_full_sync.sh' < /tmp/reponano_full_sync.sh"
      dh_ssh "docker exec ${core0} bash -c \"$run_cmd\""
    fi
  else
    scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$script" "${ssh_user}@${fqdn}:/tmp/reponano_full_sync.sh"
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@${fqdn}" "cat > /root/reponano_full_sync.sh < /tmp/reponano_full_sync.sh && $run_cmd"
  fi
  tui_ok "reponano full offline sync complete"
}

# Pull the OS packages required by forgenano's built modules (e.g. grafana module
# -> grafana package) into reponano, closing the circular offline loop.  Must run
# AFTER forgenano has built/populated its modules.
reponano_forgenano_sync() {
  [[ "$full_offline" != "true" ]] && return 0
  local core0="${nodeprefix}core0"
  local fqdn; fqdn=$(build_fqdn core0)
  local script="${script_dir}/reponano_forgenano_sync.sh"
  ensure_reponano_forgenano_sync_script
  tui_section "Forgenano -> reponano package sync (module-required OS packages)"
  tui_info "Asking forgenano for the OS packages its built modules declare, then syncing"
  tui_info "each (with direct deps) into reponano on ${core0}."
  # forgenano + reponano both run on the master; use container-localhost when docker.
  local run_cmd="bash /root/reponano_forgenano_sync.sh localhost $forgenano_port '$forgenano_admin_key' localhost $reponano_port ubuntu"  # VER/ARCH auto-detected on the master
  if [[ "$runtime" == "docker" ]]; then
    if [[ "$docker_host" == "local" ]]; then
      docker exec -i "${core0}" bash -c 'cat > /root/reponano_forgenano_sync.sh' < "$script"
      docker exec "${core0}" bash -c "$run_cmd"
    else
      scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$script" "${ssh_user}@${docker_host_ip}:/tmp/reponano_forgenano_sync.sh"
      dh_ssh "docker exec -i ${core0} bash -c 'cat > /root/reponano_forgenano_sync.sh' < /tmp/reponano_forgenano_sync.sh"
      dh_ssh "docker exec ${core0} bash -c \"$run_cmd\""
    fi
  else
    scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$script" "${ssh_user}@${fqdn}:/tmp/reponano_forgenano_sync.sh"
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@${fqdn}" "cat > /root/reponano_forgenano_sync.sh < /tmp/reponano_forgenano_sync.sh && $run_cmd"
  fi
  tui_ok "forgenano -> reponano package sync complete"
}

# Switch the master + every client to point their apt at the master reponano.
reponano_offline_switch() {
  [[ "$full_offline" != "true" ]] && return 0
  local core0="${nodeprefix}core0"
  local master_fqdn; master_fqdn=$(build_fqdn core0)
  tui_section "Switching master + clients to offline reponano (${master_fqdn})"
  tui_info "Pointing every node's apt at http://${master_fqdn}:${reponano_port}/repo/…"
  reponano_client_deploy_one core0 "$master_fqdn"
  local roles=() role
  while IFS= read -r role; do roles+=("$role"); done < <(installagent_roles)
  local seen=() r skip
  for r in "${roles[@]}"; do
    [[ "$r" == "core0" ]] && continue
    skip=no
    for s in "${seen[@]}"; do [[ "$s" == "$r" ]] && { skip=yes; break; }; done
    if [[ "$skip" == "no" ]]; then seen+=("$r"); reponano_client_deploy_one "$r" "$master_fqdn" || tui_warn "switch ${r} failed"; fi
  done
  tui_ok "master + clients now point at ${master_fqdn} reponano (offline)"
}

install_scanano() {
  [[ "$use_scanano" != "true" ]] && return 0
  local core0="${nodeprefix}core0"
  local fqdn; fqdn=$(build_fqdn core0)
  local script="${script_dir}/scanano.sh"
  ensure_scanano_script

  # Apply configurable values (port, token) with defaults.  scanano.sh is
  # regenerated each run, so a global substitution is safe.
  if [[ "$scanano_port" != "9000" ]]; then
    sed -i "s/9000/$scanano_port/g" "$script"
  fi
  # scanano token is now generated in scanano.sh; no placeholder to substitute

  tui_section "Scanano (CVE-enabled vulnerability scan bridge) on ${core0}"
  tui_info "scanano mimics a Nessus API on port ${scanano_port} (HTTPS) and runs nmap"
  tui_info "scans with the vulners script, exporting results as Nessus XML."
  tui_info "Test: curl -k https://${fqdn}:${scanano_port}/scans"

  local run_cmd="bash /root/scanano.sh"

  if [[ "$runtime" == "docker" ]]; then
    if [[ "$docker_host" == "local" ]]; then
      docker exec -i "${core0}" bash -c 'cat > /root/scanano.sh' < "$script"
      docker exec "${core0}" bash -c "$run_cmd"
    else
      scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$script" "${ssh_user}@${docker_host_ip}:/tmp/scanano.sh"
      dh_ssh "docker exec -i ${core0} bash -c 'cat > /root/scanano.sh' < /tmp/scanano.sh"
      dh_ssh "docker exec ${core0} bash -c \"$run_cmd\""
    fi
  else
    scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$script" "${ssh_user}@${fqdn}:/tmp/scanano.sh"
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@${fqdn}" "cat > /root/scanano.sh < /tmp/scanano.sh && bash /root/scanano.sh"
  fi
  tui_ok "scanano installed on ${core0} (port ${scanano_port})"
}

# ──────────────────────────────────────────────────────────────────────────────
# APPLY CONTROL-REPO PUPPETFILE
# The active control-repo Puppetfile already contains all modules (incl. premium);
# the Forge bearer token is injected natively via pe_conf_data, so Code Manager
# pulls them directly.  This just triggers a deploy + agent run to apply them.
# Best-effort – guarded so a transient puppet failure can't abort.
# ──────────────────────────────────────────────────────────────────────────────
# Deploy + run the durable offline-forge self-heal on the master, then install a
# timer so PE agent runs (which regenerate r10k.yaml/code-manager.conf and drop the
# local-forge override, sending r10k back to the public Forge) can never silently
# revert the Puppetfile or the config to the public forge.  Called from
# install_forgenano (which always runs) using its proven deploy pattern.
install_forgenano_offline_heal() {
  [[ "$full_offline" == "true" || "$use_forgenano" == "true" ]] || return 0
  local core0="${nodeprefix}core0"
  local fqdn; fqdn=$(build_fqdn core0)
  local _forge="http://${core0}:${forgenano_port}"

  local _htmp; _htmp="$(mktemp)"
  cat > "$_htmp" <<HEAL
#!/bin/bash
set -euo pipefail
FORGE="$_forge"
PF=/var/www/production
action=0
# 1) origin + working Puppetfile must point at the local forgenano
if ! grep -qF "forge '\$FORGE'" "\$PF/Puppetfile" 2>/dev/null; then
  sed -i "s|^[[:space:]]*forge[[:space:]].*|forge \"\$FORGE\"|" "\$PF/Puppetfile"
  (cd "\$PF" && git add Puppetfile && git -c user.email=wizard@localhost -c user.name=Wizard commit -q -m "Point Puppetfile at local forgenano (offline)" 2>/dev/null || true)
  (cd "\$PF" && git push -q origin HEAD:production 2>/dev/null || git push -q origin production 2>/dev/null || true)
  action=1
fi
# 2) r10k + code-manager must HONOR the Puppetfile's forge
if ! grep -q '^forge:' /etc/puppetlabs/r10k/r10k.yaml 2>/dev/null; then
  printf '\nforge:\n    allow_puppetfile_override: true\n    baseurl: %s\n' "\$FORGE" >> /etc/puppetlabs/r10k/r10k.yaml
  action=1
fi
if ! grep -q '  forge:' /etc/puppetlabs/puppetserver/conf.d/code-manager.conf 2>/dev/null; then
  python3 - /etc/puppetlabs/puppetserver/conf.d/code-manager.conf "\$FORGE" <<'PYI'
import io, sys
f, base = sys.argv[1], sys.argv[2]
block = '  forge: {\n    baseurl: "' + base + '"\n    allow_puppetfile_override: true\n  }\n}'
s = io.open(f).read().rstrip()
if '\n  forge: {' not in s and not s.endswith(block):
    s = s[:s.rfind('}')] + block if s.endswith('}') else s + block
    io.open(f, 'w').write(s)
PYI
  action=1
fi
# 3) if anything changed, restart puppetserver + redeploy so the local-forge Puppetfile is picked up
if [ "\$action" -eq 1 ]; then
  rm -rf /etc/puppetlabs/code-staging/environments/production
  systemctl restart pe-puppetserver >/dev/null 2>&1 || true
  sleep 8
  /opt/puppetlabs/bin/puppet-code deploy production --wait >/tmp/heal_deploy.log 2>&1 || true
fi
# 4) (idempotent) install/refresh the self-heal timer
cat > /etc/systemd/system/offline-forge-heal.service <<'SVCE'
[Unit]
Description=Re-apply local forgenano forge to PE r10k/code-manager
After=network.target
[Service]
Type=oneshot
ExecStart=/root/offline_forge_heal.sh
[Install]
WantedBy=multi-user.target
SVCE
cat > /etc/systemd/system/offline-forge-heal.timer <<'TMR'
[Unit]
Description=Re-apply local forgenano forge periodically
[Timer]
OnBootSec=2min
OnUnitActiveSec=3min
[Install]
WantedBy=timers.target
TMR
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable --now offline-forge-heal.timer >/dev/null 2>&1 || true
HEAL
  chmod +x "$_htmp"

  if [[ "$runtime" == "docker" ]]; then
    if [[ "$docker_host" == "local" ]]; then
      docker exec -i "${core0}" bash -c 'cat > /root/offline_forge_heal.sh' < "$_htmp"
      docker exec "${core0}" bash /root/offline_forge_heal.sh
    else
      scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$_htmp" "${ssh_user}@${docker_host_ip}:/tmp/offline_forge_heal.sh"
      dh_ssh "docker exec -i ${core0} bash -c 'cat > /root/offline_forge_heal.sh' < /tmp/offline_forge_heal.sh"
      dh_ssh "docker exec ${core0} bash /root/offline_forge_heal.sh"
    fi
  else
    scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$_htmp" "${ssh_user}@${fqdn}:/root/offline_forge_heal.sh"
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@${fqdn}" "bash /root/offline_forge_heal.sh"
  fi
  rm -f "$_htmp"
  tui_ok "Forgenano offline forge self-heal installed + applied on ${core0}"
}
install_active_puppetfile() {
  [[ "$full_offline" == "true" || "$use_forgenano" == "true" ]] || return 0
  local core0="${nodeprefix}core0"
  local fqdn; fqdn=$(build_fqdn core0)
  local repo="/var/www/production"
  local _forge="http://${core0}:${forgenano_port}"

  tui_section "Applying control-repo Puppetfile on ${core0}"
  if [[ "$full_offline" == "true" ]]; then
    tui_info "Offline/air-gap: pointing the Puppetfile's forge at THIS master's local"
    tui_info "forgenano mirror (${_forge}) - on the master only."
    tui_info "The source control-repo is never modified."
  else
    tui_info "The active Puppetfile already contains all modules (incl. premium); the"
    tui_info "Forge token is injected via pe_conf_data, so Code Manager pulls them directly."
  fi

  # A self-contained, quoting-safe helper deployed to the master.  (The old inline
  # nested-quote bash -c one-liner silently failed; a real script file avoids that.)
  local _stmp; _stmp="$(mktemp)"
  cat > "$_stmp" <<'EOWIZ'
#!/bin/bash
set -euo pipefail
PF="$1"; FORGE="$2"
# 1) point the live Puppetfile's forge at the local forgenano (master only)
if grep -qE '^[[:space:]]*forge[[:space:]]' "$PF/Puppetfile"; then
  sed -i "s|^[[:space:]]*forge[[:space:]].*|forge \"$FORGE\"|" "$PF/Puppetfile"
else
  echo "forge \"$FORGE\"" >> "$PF/Puppetfile"
fi
cd "$PF" || exit 1
git add Puppetfile
git -c user.email=wizard@localhost -c user.name=Wizard commit -q -m "Point Puppetfile at local forgenano (offline)" 2>/dev/null || true
git push -q origin HEAD:production 2>/dev/null || git push -q origin production 2>/dev/null || true
# 2) make r10k + code-manager HONOR the Puppetfile's forge
mkdir -p /etc/puppetlabs/r10k
grep -q '^forge:' /etc/puppetlabs/r10k/r10k.yaml 2>/dev/null || printf '\nforge:\n    allow_puppetfile_override: true\n    baseurl: %s\n' "$FORGE" >> /etc/puppetlabs/r10k/r10k.yaml
python3 - /etc/puppetlabs/puppetserver/conf.d/code-manager.conf "$FORGE" <<'PY'
import io, sys
f, base = sys.argv[1], sys.argv[2]
block = '  forge: {\n    baseurl: "' + base + '"\n    allow_puppetfile_override: true\n  }\n}'
s = io.open(f).read().rstrip()
if '\n  forge: {' not in s and not s.endswith(block):
    s = s[:s.rfind('}')] + block if s.endswith('}') else s + block
    io.open(f, 'w').write(s)
PY
rm -rf /etc/puppetlabs/code-staging/environments/production
systemctl restart pe-puppetserver >/dev/null 2>&1 || true
sleep 8
/opt/puppetlabs/bin/puppet-code deploy production --wait >/tmp/puppet_deploy.log 2>&1 || true

# 3) DURABLE self-heal: PE regenerates r10k.yaml/code-manager.conf on every agent
# run and drops the forge override (allow_puppetfile_override defaults to false),
# which sends r10k back to the public forge -> 401.  A systemd timer re-applies
# the override (and restarts puppetserver once) whenever it is missing.
cat > /root/offline_forge_heal.sh <<HEAL
#!/bin/bash
set -euo pipefail
FORGE="$FORGE"
changed=0
if ! grep -q '^forge:' /etc/puppetlabs/r10k/r10k.yaml 2>/dev/null; then
  printf '\nforge:\n    allow_puppetfile_override: true\n    baseurl: %s\n' "\$FORGE" >> /etc/puppetlabs/r10k/r10k.yaml
  changed=1
fi
if ! grep -q '  forge:' /etc/puppetlabs/puppetserver/conf.d/code-manager.conf 2>/dev/null; then
  python3 - /etc/puppetlabs/puppetserver/conf.d/code-manager.conf "\$FORGE" <<'PY2'
import io, sys
f, base = sys.argv[1], sys.argv[2]
block = '  forge: {\n    baseurl: "' + base + '"\n    allow_puppetfile_override: true\n  }\n}'
s = io.open(f).read().rstrip()
if '\n  forge: {' not in s and not s.endswith(block):
    s = s[:s.rfind('}')] + block if s.endswith('}') else s + block
    io.open(f, 'w').write(s)
PY2
  changed=1
fi
if [ "\$changed" -eq 1 ]; then
  systemctl restart pe-puppetserver >/dev/null 2>&1 || true
fi
HEAL
chmod +x /root/offline_forge_heal.sh
cat > /etc/systemd/system/offline-forge-heal.service <<UNIT
[Unit]
Description=Re-apply local forgenano forge to PE r10k/code-manager
After=network.target
[Service]
Type=oneshot
ExecStart=/root/offline_forge_heal.sh
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/systemd/system/offline-forge-heal.timer <<TIMER
[Unit]
Description=Re-apply local forgenano forge periodically
[Timer]
OnBootSec=2min
OnUnitActiveSec=3min
[Install]
WantedBy=timers.target
TIMER
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable --now offline-forge-heal.timer >/dev/null 2>&1 || true
EOWIZ
  chmod +x "$_stmp"

  local _run="bash /root/apply_forgenano_offline.sh '$repo' '$_forge'"
  if [[ "$runtime" == "docker" ]]; then
    if [[ "$docker_host" == "local" ]]; then
      docker exec -i "${core0}" bash -c 'cat > /root/apply_forgenano_offline.sh' < "$_stmp"
      docker exec "${core0}" bash -c "$_run"
    else
      scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$_stmp" "${ssh_user}@${docker_host_ip}:/tmp/apply_forgenano_offline.sh"
      dh_ssh "docker exec -i ${core0} bash -c 'cat > /root/apply_forgenano_offline.sh' < /tmp/apply_forgenano_offline.sh"
      dh_ssh "docker exec ${core0} bash -c \"$_run\""
    fi
  else
    scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$_stmp" "${ssh_user}@${fqdn}:/root/apply_forgenano_offline.sh"
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@${fqdn}" "bash -c \"$_run\""
  fi
  rm -f "$_stmp"
  tui_ok "Control-repo Puppetfile applied - all modules (incl. premium) installed"
}
