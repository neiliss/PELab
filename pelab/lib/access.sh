# =============================================================================
# access.sh  –  extracted from setup.sh (lines 5427-5880)
# Sourced by pelab.sh.  Do not run directly.
# =============================================================================
print_console_access() {
  local primary_fqdn; primary_fqdn=$(build_fqdn core0)
  if [[ "$runtime" == "docker" && "$docker_host" == "cloud" ]]; then
    local cip="" whost lb_fqdn="" md="${script_dir}/helper.md" dh_fqdn
    dh_fqdn=$(build_dockerhost_fqdn)
    cip=$(ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=20 "${ssh_user}@${docker_host_ip}" \
            "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${primary_fqdn}" 2>/dev/null | tr -d '\r')
    whost=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ "$instype" =~ ^(XL|LARGE)$ ]] && lb_fqdn=$(build_fqdn haproxy)
    local test_fqdn; test_fqdn=$(build_fqdn test)
    local test_port=$((2201 + $(docker_roles | wc -l)))
    local agent_entry="${lb_fqdn:-$primary_fqdn}"

    # Build the SSH access table rows.
    local ssh_rows="" role
    for role in $(docker_roles); do
      local rport; rport=$(docker_ssh_port "$role")
      ssh_rows+="| \`${nodeprefix}${role}\` | **${rport}** | \`ssh -i ${ssh_key_path} -p ${rport} ${ssh_user}@${docker_host_ip}\` |\n"
    done
    # Add the plain test node (no PE/agent) to the table too.
    ssh_rows+="| \`${test_fqdn}\` | **${test_port}** | \`ssh -i ${ssh_key_path} -p ${test_port} ${ssh_user}@${docker_host_ip}\` |\n"

    # ── console output ──
    tui_blank
    tui_info "PE Console:  ${BOLD}https://${primary_fqdn}${RESET}   (login ${BOLD}admin${RESET} / password as configured)"
    tui_info "PE service ports are exposed on the Docker host, so the console and agents"
    tui_info "connect directly - no tunnel needed."
    tui_blank
    tui_info "To browse the console, add this to /etc/hosts on the machine you browse from:"
    tui_info "  ${docker_host_ip}   ${primary_fqdn}"
    tui_info "Then open  ${BOLD}https://${primary_fqdn}${RESET}  (accept the self-signed cert)."
    tui_blank
    if [[ -n "$lb_fqdn" ]]; then
      tui_info "LARGE/XL: agents connect via the HAProxy load balancer on 8140:"
      tui_info "  add to /etc/hosts:  ${docker_host_ip}   ${lb_fqdn}"
      tui_info "  install agent:  curl -k https://${lb_fqdn}:8140/packages/current/install.bash | bash"
    else
      tui_info "To connect a NEW agent node, on that node:"
      tui_info "  1. add to /etc/hosts:  ${docker_host_ip}   ${primary_fqdn}"
      tui_info "  2. install the agent:  curl -k https://${primary_fqdn}:8140/packages/current/install.bash | bash"
      tui_info "  3. run:  puppet agent -t"
    fi
    tui_info "Every node has /root/installagent.sh (executable) ready to (re)install the agent:"
    tui_info "  /root/installagent.sh <puppet_role> <install_url>"
    tui_blank
    tui_info "SSH to each container (mapped ports on the Docker host):"
    for role in $(docker_roles); do
      local rport; rport=$(docker_ssh_port "$role")
      tui_info "  ${nodeprefix}${role}  ->  ssh -i ${ssh_key_path} -p ${rport} ${ssh_user}@${docker_host_ip}"
    done
    tui_info "  ${test_fqdn}  ->  ssh -i ${ssh_key_path} -p ${test_port} ${ssh_user}@${docker_host_ip}   (plain test node, no PE/agent)"
    if [[ "$use_gitnano" == "true" ]]; then
      tui_blank
      tui_info "Local git (gitnano) on ${primary_fqdn}:"
      tui_info "  API: http://${primary_fqdn}:${gitnano_port}  (token: ${gitnano_token})"
      tui_info "  live worktree /var/www/production, r10k remote gitnano@${primary_fqdn}:/opt/gitnano/repos/control-repo.git"
      tui_info "  Example: cd /var/www/production && vi manifests/site.pp && git add . && git commit -m 'test commit' && git push gitnano production"
      tui_info "  Then: sudo /opt/puppetlabs/bin/puppet-code deploy production --wait && sudo /opt/puppetlabs/bin/puppet agent -t"
    fi
    tui_blank
    tui_info "Hieranano (Hiera/eyaml UI) on ${primary_fqdn}:"
    tui_info "  URL: https://${primary_fqdn}:${hieranano_port}/?token=${hieranano_token}   (http://…:${hieranano_http_port} fallback)"
    tui_info "  Browse/edit Hiera YAML + eyaml in /var/www/production, then Git Sync to commit & push"
    if [[ "$use_openainano" == "true" ]]; then
      tui_blank
      tui_info "OpenAINano (PE AI ↔ Ollama bridge) on ${primary_fqdn}:"
      tui_info "  URL: http://${primary_fqdn}:${openainano_port}  (bridges PE AI to local Ollama on 127.0.0.1:11434)"
      tui_info "  Ollama installed on the master; authenticate + pull a cloud model:"
      tui_info "    ollama login  &&  ollama run ${openainano_model}"
    fi
    if [[ "$use_reponano" == "true" ]]; then
      tui_blank
      tui_info "Reponano (local apt/yum package repo) on ${primary_fqdn}:"
      tui_info "  URL: http://${primary_fqdn}:${reponano_port}  (offline nodes point their package manager here)"
    fi
    if [[ "$use_forgenano" == "true" ]]; then
      tui_blank
      tui_info "Forgenano (local Puppet Forge / module mirror) on ${primary_fqdn}:"
      tui_info "  URL: http://${primary_fqdn}:${forgenano_port}  (offline nodes install modules from here)"
    fi
    if [[ "$use_scanano" == "true" ]]; then
      tui_blank
      tui_info "Scanano (CVE-enabled vuln scan bridge) on ${primary_fqdn}:"
      tui_info "  URL: https://${primary_fqdn}:${scanano_port}  (Nessus-API mimic, nmap vulners)"
    fi
    tui_blank
    tui_info "Current: Docker host ${docker_host_ip}, container ${primary_fqdn} = ${cip:-<container_ip>}"
    tui_info "A full reference (incl. restart behavior) was written to ${BOLD}${md}${RESET}"

    # ── write helper.md ──
    mdw() { printf '%s\n' "$@" >> "$md"; }
    : > "$md"
    mdw "# PE Lab — Access Reference"
    mdw ""
    mdw "Generated: $(date)"
    mdw ""
    mdw "Topology: **${instype}**  |  Runtime: **Docker (single host)**  |  Size: **${node_size}** (${gcp_machine_type})"
    mdw ""
    mdw "All PE containers run on a single cloud VM (the Docker host).  PE service ports"
    mdw "are exposed directly on the Docker host, so the console and agents connect"
    mdw "directly — no SSH tunnel needed."
    mdw ""
    mdw "---"
    mdw ""
    mdw "## 1. Docker host"
    mdw ""
    mdw "- Internal IP: \`${docker_host_ip}\`"
    mdw "- Internal FQDN: \`${dh_fqdn}\`"
    mdw "- SSH key: \`${ssh_key_path}\`  (ssh user: \`${ssh_user}\`)"
    mdw ""
    mdw "---"
    mdw ""
    mdw "## 2. Console (PE Web UI)"
    mdw ""
    mdw "- URL: **https://${primary_fqdn}**"
    mdw "- Login: \`admin\` / \`${adminpwd:-<as configured>}\`"
    mdw "- On the machine you browse from, add to \`/etc/hosts\`:"
    mdw ""
    mdw "    ${docker_host_ip}   ${primary_fqdn}"
    mdw ""
    mdw "Then open https://${primary_fqdn} and accept the self-signed cert."
    mdw ""
    mdw "---"
    mdw ""
    mdw "## 3. Agents"
    mdw ""
    if [[ -n "$lb_fqdn" ]]; then
      mdw "### LARGE / XL (HAProxy load balancer)"
      mdw "Agents connect to the HAProxy on 8140.  The HAProxy backend round-robins across"
      mdw "the primary + every compiler on :8140 (plus the replica if DR), so the nodepool"
      mdw "address distributes agent traffic to the compiler pool.  The nodepool is in the"
      mdw "cert SAN (compiler_pool_address), so TLS verification holds for any backend node:"
      mdw "- add to /etc/hosts:  ${docker_host_ip}   ${lb_fqdn}"
      mdw "- install:  curl -k https://${lb_fqdn}:8140/packages/current/install.bash | bash"
      mdw "- run:  puppet agent -t"
    else
      mdw "### STANDARD (no load balancer)"
      mdw "Agents connect to the primary on 8140:"
      mdw "- add to /etc/hosts:  ${docker_host_ip}   ${primary_fqdn}"
      mdw "- install:  curl -k https://${primary_fqdn}:8140/packages/current/install.bash | bash"
      mdw "- run:  puppet agent -t"
    fi
    mdw ""
    mdw "### installagent.sh (agent (re)installer) on every node"
    mdw ""
    mdw "Every node carries \`/root/installagent.sh\` (executable, owner root).  It removes"
    mdw "any existing agent, (re)installs one with a role fact, and applies a catalog:"
    mdw ""
    mdw "    /root/installagent.sh <puppet_role> <install_url>"
    mdw "    /root/installagent.sh pe_compiler ${lb_fqdn:-${primary_fqdn}}"
    mdw ""
    mdw "---"
    mdw ""
    mdw "## 4. SSH to each container"
    mdw ""
    mdw "Each container's SSH (22) is mapped to a unique port on the Docker host's internal IP:"
    mdw ""
    mdw "| Container | SSH port | Command |"
    mdw "|---|---|---|"
    mdw "$(printf '%b' "$ssh_rows")"
    mdw ""
    mdw "(From your laptop, copy the key over first and \`chmod 600\` it.)"
    mdw ""
    mdw "### SSH-key requirements on the targets"
    mdw ""
    mdw "Before the wizard can connect, **every target node** must already allow the"
    mdw "chosen public key, or the SSH/bootstrap step will fail:"
    mdw ""
    mdw "1. The public key (\`${ssh_key_path}.pub\`) is present in the ssh_user's"
    mdw "   \`~/.ssh/authorized_keys\` (for root: \`/root/.ssh/authorized_keys\`)."
    mdw "2. \`/etc/ssh/sshd_config\` has these **uncommented** (not hashed out):"
    mdw "   - \`PubkeyAuthentication yes\`"
    mdw "   - \`AuthorizedKeysFile .ssh/authorized_keys\`"
    mdw "3. \`~/.ssh\` and \`~/.ssh/authorized_keys\` permissions allow sshd to read the key"
    mdw "   (commonly \`chmod 700 ~/.ssh\` and \`chmod 600 ~/.ssh/authorized_keys\`)."
    mdw ""
    mdw "---"
    mdw ""
    mdw "## 5. Test node"
    mdw ""
    mdw "A plain test node (no PE/agent) is provisioned for general testing:"
    mdw ""
    mdw "- SSH: \`ssh -i ${ssh_key_path} -p ${test_port} ${ssh_user}@${docker_host_ip}\`"
    mdw "- It has nothing installed beyond SSH.  To use it as a PE agent, first install the agent:"
    mdw "  - add to /etc/hosts:  ${docker_host_ip}   ${test_fqdn}"
    mdw "  - install:  curl -k https://${agent_entry}:8140/packages/current/install.bash | bash"
    mdw "  - run:  puppet agent -t"
    mdw ""
    mdw "---"
    mdw ""
    if [[ "$use_gitnano" == "true" ]]; then
      mdw "## 6. Local git (gitnano) on the master"
      mdw ""
      mdw "A lightweight control-repo manager is installed on ${primary_fqdn}.  It hosts a"
      mdw "bare git repo and a small HTTP API, and r10k/code-manager pulls from it over SSH."
      mdw ""
      mdw "### Where things live"
      mdw ""
      mdw "- Bare repo: \`/opt/gitnano/repos/control-repo.git\`"
      mdw "- Live worktree (the \`production\` branch checked out): \`/var/www/production\`"
      mdw "- API: \`http://${primary_fqdn}:${gitnano_port}\`  (Bearer token: \`${gitnano_token}\`)"
      mdw "- r10k SSH key: \`/etc/puppetlabs/puppetserver/ssh/id-control_repo.rsa\`"
      mdw "- r10k remote: \`gitnano@${primary_fqdn}:/opt/gitnano/repos/control-repo.git\`"
      mdw "- r10k known_hosts (set on \`puppet_enterprise::profile::master\`):"
      mdw ""
      mdw "    \`${r10k_known_hosts}\`"
      mdw ""
      mdw "### How to interact with it"
      mdw ""
      mdw "SSH into the master (see section 4), then work in the live worktree:"
      mdw ""
      mdw "    cd /var/www/production"
      mdw "    git status"
      mdw "    git log --oneline -5"
      mdw ""
      mdw "### Simple example: make a change and deploy it"
      mdw ""
      mdw "1. Edit a file (e.g. add a class to the default node):"
      mdw ""
      mdw "       cd /var/www/production"
      mdw "       vi manifests/site.pp"
      mdw ""
      mdw "2. Commit and push to gitnano:"
      mdw ""
      mdw "       git add ."
      mdw "       git commit -m \"test commit\""
      mdw "       git push gitnano production"
      mdw ""
      mdw "3. Deploy to PE (r10k pulls the new commit):"
      mdw ""
      mdw "       sudo /opt/puppetlabs/bin/puppet-code deploy production --wait"
      mdw ""
      mdw "4. The change is now in the Puppet environment.  Run the agent to apply it:"
      mdw ""
      mdw "       sudo /opt/puppetlabs/bin/puppet agent -t"
      mdw ""
      mdw "### API (optional)"
      mdw ""
      mdw "The API is a git-over-HTTP bridge.  The \`gitnano\` remote in the worktree is"
      mdw "already configured to \`http://:@localhost:${gitnano_port}/control-repo.git\`, so"
      mdw "\`git push gitnano production\` works without extra setup."
      mdw ""
      mdw "### Troubleshooting"
      mdw ""
      mdw "- \`puppet code deploy\` fails with \`invalid or unknown remote ssh hostkey\`:"
      mdw "  set \`r10k_known_hosts\` (above) on \`puppet_enterprise::profile::master\` and run"
      mdw "  \`puppet agent -t\` on the master.  Regenerate the entry with:"
      mdw ""
      mdw "      ssh-keyscan -t ed25519 ${primary_fqdn}"
      mdw ""
      mdw "- \`puppet code deploy\` fails with \`remote rejected authentication\`: the key"
      mdw "  r10k uses doesn't match gitnano's authorized_keys.  Regenerate it:"
      mdw ""
      mdw "      sudo -u gitnano ssh-keygen -y -f /etc/puppetlabs/puppetserver/ssh/id-control_repo.rsa > /opt/gitnano/.ssh/authorized_keys"
      mdw ""
      mdw "- SSH login as an unprivileged user is refused with \`System is booting up\`:"
      mdw "  remove the nologin file:"
      mdw ""
      mdw "      rm -f /run/nologin /etc/nologin"
      mdw ""
      mdw "---"
      mdw ""
    fi
    mdw "## 7. Hieranano (Hiera/eyaml UI) on the master"
    mdw ""
    mdw "Hieranano is a web UI for working with Hiera and eyaml in the control-repo.  It is"
    mdw "always installed and running on ${primary_fqdn}."
    mdw ""
    mdw "- URL: \`https://${primary_fqdn}:${hieranano_port}/?token=${hieranano_token}\`  (self-signed; \`http://…:${hieranano_http_port}\` fallback)"
    mdw "- Control repo browsed/edited: \`/var/www/production\`"
    mdw "- eyaml keys: \`/etc/puppetlabs/puppet/keys/\` (public_key.pkcs7.pem / private_key.pkcs7.pem)"
    mdw "- Runs as systemd services (\`hieranano.service\` HTTPS on :${hieranano_port}, \`hieranano-http.service\` HTTP on :${hieranano_http_port}), so it survives container restarts."
    mdw ""
    mdw "### What you can do"
    mdw ""
    mdw "- Browse the Hiera data layers (.yaml) and the full repo tree in the sidebar."
    mdw "- Edit YAML in a visual grid or raw editor; encrypt/decrypt values with eyaml (🔒/🔓)."
    mdw "- Use **Git Sync** to commit & push your changes to the control-repo."
    mdw ""
    mdw "### Simple example: edit a Hiera value and deploy it"
    mdw ""
    mdw "1. Open the URL above (append \`?token=...\` if prompted)."
    mdw "2. Pick a .yaml file in the **HIERA DATA LAYERS** sidebar, edit a value, and **Save All**."
    mdw "3. Click **🔁 Git Sync**, enter a commit message, and **Commit & Push**."
    mdw "4. Deploy to PE:"
    mdw ""
    mdw "       sudo /opt/puppetlabs/bin/puppet-code deploy production --wait"
    mdw ""
    mdw "5. Run the agent to apply it:"
    mdw ""
    mdw "       sudo /opt/puppetlabs/bin/puppet agent -t"
    mdw ""
    mdw "---"
    mdw ""
    mdw "## 7.5 OpenAINano (PE AI ↔ Ollama bridge) on the master"
    mdw ""
    mdw "OpenAINano is a Flask bridge (port ${openainano_port}) that translates PE's AI"
    mdw "infra-assistant to a local Ollama instance (127.0.0.1:11434).  It is"
    mdw "installed on ${primary_fqdn} by default."
    mdw ""
    mdw "- URL: \`http://${primary_fqdn}:${openainano_port}\`"
    mdw "- Bridges to local Ollama: \`http://127.0.0.1:11434\`"
    mdw "- Runs as a systemd service (\`openainano.service\`), so it survives container restarts."
    mdw "- Ollama is installed on the master automatically (port 11434)."
    mdw "- A local model is not powerful enough – authenticate + pull a CLOUD model:"
    mdw "    ollama login  &&  ollama run ${openainano_model}"
    mdw "- NOTE: gitnano's API uses port ${gitnano_port} – openainano uses ${openainano_port}."
    mdw ""
    if [[ "$use_reponano" == "true" ]]; then
      mdw "## 7.6 Reponano (local apt/yum package repo) on the master"
      mdw ""
      mdw "Reponano hosts a local apt/yum package repo (Flask, port ${reponano_port}) on"
      mdw "${primary_fqdn}.  Offline nodes point their package manager at it instead of"
      mdw "the internet."
      mdw ""
      mdw "- URL: \`http://${primary_fqdn}:${reponano_port}\`"
      mdw "- Storage: \`/var/www/reponano\`  (\`<distro>/<ver>/<arch>\`)"
      mdw "- Runs as a systemd service (\`reponano.service\`), survives container restarts."
      mdw "- Sync a package: \`curl -X POST http://${primary_fqdn}:${reponano_port}/sync -H 'Content-Type: application/json' -d '{\"pkg\":\"sl\",\"distro\":\"ubuntu\",\"ver\":\"<codename>\"}'\`"
      mdw "- Client toggle on a node: \`/root/reponano_client.sh ${primary_fqdn}\`  (\`--restore\` to go back online)"
      mdw "- Full offline pull: \`/root/reponano_full_sync.sh\` + \`/root/reponano_forgenano_sync.sh\`  (manifest + module-required packages; codename auto-detected)"
      mdw "- Full offline build: pulls all packages + modules, then switches the repo/forge to local"
      mdw ""
    fi
    if [[ "$use_forgenano" == "true" ]]; then
      mdw "## 7.7 Forgenano (local Puppet Forge / module mirror) on the master"
      mdw ""
      mdw "Forgenano mirrors Puppet Forge modules to a local repo (Flask, port ${forgenano_port})"
      mdw "on ${primary_fqdn}.  Offline nodes install modules from it instead of the"
      mdw "public Forge."
      mdw ""
      mdw "- URL: \`http://${primary_fqdn}:${forgenano_port}\`"
      mdw "- Storage: \`/var/lib/puppet_localforge\`  (\`<owner>-<name>-<version>.tar.gz\`)"
      mdw "- Runs as a systemd service (\`forgenano.service\`), survives container restarts."
      mdw "- Add a module: \`curl -X POST http://${primary_fqdn}:${forgenano_port}/v3/modules -H 'X-API-KEY: <admin-key>' -H 'Content-Type: application/json' -d '{\"module\":\"puppetlabs-stdlib\"}'\`"
      mdw "- Populate: \`/root/forgenano_populate.sh\`   |   Workflow: \`/root/forgenano_local.sh\`"
      mdw "- Full offline build: also pulls the full module catalog into the local forge"
      mdw ""
    fi
    if [[ "$use_scanano" == "true" ]]; then
      mdw "## 7.9 Scanano (CVE-enabled vulnerability scan bridge) on the master"
      mdw ""
      mdw "Scanano mimics a Nessus API (Flask, HTTPS port ${scanano_port}) on"
      mdw "${primary_fqdn}.  It runs nmap scans with the vulners script and exports"
      mdw "results as Nessus XML."
      mdw ""
      mdw "- URL: \`https://${primary_fqdn}:${scanano_port}\`"
      mdw "- Runs as a systemd service (\`scanano.service\`), survives container restarts."
      mdw "- Test: \`curl -k https://${primary_fqdn}:${scanano_port}/scans\`"
      mdw "- API token: \`${scanano_token}\`"
      mdw ""
    fi
    mdw "---"
    mdw ""
    mdw "## 8. Restarting the Docker host"
    mdw ""
    mdw "- The containers were started with \`--restart unless-stopped\`, so when the VM"
    mdw "  reboots the Docker daemon automatically restarts every container, and the PE"
    mdw "  services (systemd inside each container) come back up."
    mdw "- After the host is back, the console and agents should be reachable again"
    mdw "  without re-running the wizard."
    mdw ""
    mdw "### ✅ Stable /etc/hosts connections"
    mdw ""
    mdw "- Every connection (console, agents, SSH) relies on \`/etc/hosts\` entries that"
    mdw "  map the Docker host's **internal network IP** to the container FQDNs"
    mdw "  (\`${primary_fqdn}\`, \`${lb_fqdn:-...}\`, ...)."
    mdw "- The internal IP is **stable**: it does not change on a VM restart, and it is"
    mdw "  present even in air-gapped environments where no external interface exists."
    mdw "- The wizard host must be on the same internal network to reach it"
    mdw "  (internal-to-internal only)."
    mdw "- The wizard host's \`/etc/hosts\` is updated automatically on each run.  Your"
    mdw "  laptop and agent nodes are **not** — update them manually."
    mdw ""
    mdw "---"
    mdw ""
    mdw "This file was written by the PE Lab wizard.  Re-run the wizard to regenerate it"
    mdw "with the current Docker host IP."
  elif [[ "$runtime" == "docker" && "$docker_host" == "local" ]]; then
    # Local all-in-one: containers run on this host, resolved via /etc/hosts to
    # their container IPs.  No port mapping – SSH on port 22.
    local md="${script_dir}/helper.md"
    local lb_fqdn=""
    [[ "$instype" =~ ^(XL|LARGE)$ ]] && lb_fqdn=$(build_fqdn haproxy)
    local test_fqdn; test_fqdn=$(build_fqdn test)
    local cip
    cip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$primary_fqdn" 2>/dev/null | tr -d '\r')
    # The Docker host's real (routable) IP.  Containers are reached from other
    # machines via this IP + the mapped ports below (same model as GCP docker).
    local dh_ip; dh_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    local test_port=$((2201 + $(docker_roles | wc -l)))

    tui_blank
    tui_info "PE Console:  ${BOLD}https://${primary_fqdn}${RESET}   (login admin / password as configured)"
    tui_info "PE service ports are exposed on this Docker host (${dh_ip:-<this-host-ip>}), so the"
    tui_info "console and agents connect directly - no tunnel needed."
    tui_blank
    tui_info "To browse the console, add this to /etc/hosts on the machine you browse from:"
    tui_info "  ${dh_ip:-<this-host-ip>}   ${primary_fqdn}"
    tui_info "Then open  ${BOLD}https://${primary_fqdn}${RESET}  (accept the self-signed cert)."
    tui_blank
    if [[ -n "$lb_fqdn" ]]; then
      tui_info "LARGE/XL: agents connect via the HAProxy load balancer on 8140:"
      tui_info "  add to /etc/hosts:  ${dh_ip:-<this-host-ip>}   ${lb_fqdn}"
      tui_info "  install agent:  curl -k https://${lb_fqdn}:8140/packages/current/install.bash | bash"
    else
      tui_info "To connect a NEW agent node, on that node:"
      tui_info "  1. add to /etc/hosts:  ${dh_ip:-<this-host-ip>}   ${primary_fqdn}"
      tui_info "  2. install the agent:  curl -k https://${primary_fqdn}:8140/packages/current/install.bash | bash"
      tui_info "  3. run:  puppet agent -t"
    fi
    tui_info "Every node has /root/installagent.sh (executable) ready to (re)install the agent:"
    tui_info "  /root/installagent.sh <puppet_role> <install_url>"
    tui_blank
    tui_info "SSH to each container (mapped ports on this Docker host):"
    for role in $(docker_roles); do
      local rport; rport=$(docker_ssh_port "$role")
      tui_info "  ${nodeprefix}${role}  ->  ssh -i ${ssh_key_path} -p ${rport} ${ssh_user}@${dh_ip:-<this-host-ip>}"
    done
    tui_info "  ${test_fqdn}  ->  ssh -i ${ssh_key_path} -p ${test_port} ${ssh_user}@${dh_ip:-<this-host-ip>}   (plain test node, no PE/agent)"
    if [[ "$use_gitnano" == "true" ]]; then
      tui_blank
      tui_info "Local git (gitnano) on ${primary_fqdn}:"
      tui_info "  API: http://${primary_fqdn}:${gitnano_port}  (token: ${gitnano_token})"
      tui_info "  live worktree /var/www/production, r10k remote gitnano@${primary_fqdn}:/opt/gitnano/repos/control-repo.git"
      tui_info "  Example: cd /var/www/production && vi manifests/site.pp && git add . && git commit -m 'test commit' && git push gitnano production"
      tui_info "  Then: sudo /opt/puppetlabs/bin/puppet-code deploy production --wait && sudo /opt/puppetlabs/bin/puppet agent -t"
    fi
    tui_blank
    tui_info "Hieranano (Hiera/eyaml UI) on ${primary_fqdn}:"
    tui_info "  URL: https://${primary_fqdn}:${hieranano_port}/?token=${hieranano_token}   (http://…:${hieranano_http_port} fallback)"
    tui_info "  Browse/edit Hiera YAML + eyaml in /var/www/production, then Git Sync to commit & push"
    if [[ "$use_openainano" == "true" ]]; then
      tui_blank
      tui_info "OpenAINano (PE AI ↔ Ollama bridge) on ${primary_fqdn}:"
      tui_info "  URL: http://${primary_fqdn}:${openainano_port}  (bridges PE AI to local Ollama on 127.0.0.1:11434)"
      tui_info "  Ollama installed on the master; authenticate + pull a cloud model:"
      tui_info "    ollama login  &&  ollama run ${openainano_model}"
    fi
    if [[ "$use_reponano" == "true" ]]; then
      tui_blank
      tui_info "Reponano (local apt/yum package repo) on ${primary_fqdn}:"
      tui_info "  URL: http://${primary_fqdn}:${reponano_port}  (offline nodes point their package manager here)"
    fi
    if [[ "$use_forgenano" == "true" ]]; then
      tui_blank
      tui_info "Forgenano (local Puppet Forge / module mirror) on ${primary_fqdn}:"
      tui_info "  URL: http://${primary_fqdn}:${forgenano_port}  (offline nodes install modules from here)"
    fi
    if [[ "$use_scanano" == "true" ]]; then
      tui_blank
      tui_info "Scanano (CVE-enabled vuln scan bridge) on ${primary_fqdn}:"
      tui_info "  URL: https://${primary_fqdn}:${scanano_port}  (Nessus-API mimic, nmap vulners)"
    fi
    tui_blank
    tui_info "Current: container ${primary_fqdn} = ${cip:-<container_ip>}"
    tui_info "A full reference (incl. restart behavior) was written to ${BOLD}${md}${RESET}"

    # ── write helper.md ──
    mdw() { printf '%s\n' "$@" >> "$md"; }
    : > "$md"
    local _dh_host; _dh_host=$(hostname 2>/dev/null || echo "this-host")
    local _dh_pub;  _dh_pub=$(curl -s --max-time 4 ifconfig.me 2>/dev/null || echo "")
    mdw "# PE Lab — Access Reference (Docker all-in-one on this host)"
    mdw ""
    mdw "Generated: $(date)"
    mdw ""
    mdw "Topology: **${instype}**  |  Runtime: **Docker (all-in-one on this host)**"
    mdw ""
    mdw "The PE containers run on this Docker host.  Their service ports are exposed on"
    mdw "this host's IP (${dh_ip:-<this-host-ip>}), so the console and agents connect"
    mdw "directly from any machine that can reach this host - no tunnel needed."
    mdw ""
    mdw "---"
    mdw ""
    mdw "## Console (PE Web UI)"
    mdw ""
    mdw "1. On the machine you browse from, add to \`/etc/hosts\`:"
    mdw ""
    mdw "       ${dh_ip:-<this-host-ip>}   ${primary_fqdn}"
    mdw ""
    mdw "2. Open **https://${primary_fqdn}**  (accept the self-signed cert)."
    mdw ""
    mdw "- Login: \`admin\` / \`${adminpwd:-<as configured>}\`"
    mdw ""
    mdw "## SSH (mapped ports on this Docker host)"
    mdw ""
    for role in $(docker_roles); do
      local rport; rport=$(docker_ssh_port "$role")
      mdw "- \`${nodeprefix}${role}\`: \`ssh -i ${ssh_key_path} -p ${rport} ${ssh_user}@${dh_ip:-<this-host-ip>}\`"
    done
    mdw "- \`${test_fqdn}\`: \`ssh -i ${ssh_key_path} -p ${test_port} ${ssh_user}@${dh_ip:-<this-host-ip>}\`  (plain test node, no PE/agent)"
    mdw ""
    if [[ -n "$lb_fqdn" ]]; then
      mdw "## Agents (LARGE/XL via HAProxy)"
      mdw ""
      mdw "Add to /etc/hosts:  ${dh_ip:-<this-host-ip>}   ${lb_fqdn}"
      mdw "Install agent:  \`curl -k https://${lb_fqdn}:8140/packages/current/install.bash | bash\`"
    else
      mdw "## Agents"
      mdw ""
      mdw "On the agent node, add to /etc/hosts:  ${dh_ip:-<this-host-ip>}   ${primary_fqdn}"
      mdw "Install agent:  \`curl -k https://${primary_fqdn}:8140/packages/current/install.bash | bash\`"
      mdw "Then run:  \`puppet agent -t\`"
    fi
    mdw ""
    mdw "Every node has /root/installagent.sh (executable) ready to (re)install the agent:"
    mdw "  \`/root/installagent.sh <puppet_role> <install_url>\`"
    mdw ""
    mdw "### SSH-key requirements on the targets"
    mdw ""
    mdw "Before the wizard can connect, **every target node** must already allow the"
    mdw "chosen public key, or the SSH/bootstrap step will fail:"
    mdw ""
    mdw "1. The public key (\`${ssh_key_path}.pub\`) is present in the ssh_user's"
    mdw "   \`~/.ssh/authorized_keys\` (for root: \`/root/.ssh/authorized_keys\`)."
    mdw "2. \`/etc/ssh/sshd_config\` has these **uncommented** (not hashed out):"
    mdw "   - \`PubkeyAuthentication yes\`"
    mdw "   - \`AuthorizedKeysFile .ssh/authorized_keys\`"
    mdw "3. \`~/.ssh\` and \`~/.ssh/authorized_keys\` permissions allow sshd to read the key"
    mdw "   (commonly \`chmod 700 ~/.ssh\` and \`chmod 600 ~/.ssh/authorized_keys\`)."
    mdw ""
    if [[ -n "$lb_fqdn" ]]; then
      mdw "## Agents (LARGE/XL via HAProxy)"
      mdw ""
      mdw "- Agent endpoint: **${lb_fqdn}** on 8140"
      mdw "- install:  curl -k https://${lb_fqdn}:8140/packages/current/install.bash | bash"
    else
      mdw "## Agents"
      mdw ""
      mdw "- install:  curl -k https://${primary_fqdn}:8140/packages/current/install.bash | bash"
    fi
    mdw ""
    mdw "## installagent.sh (agent (re)installer) on every node"
    mdw ""
    mdw "Every node carries \`/root/installagent.sh\` (executable, owner root).  It removes"
    mdw "any existing agent, (re)installs one with a role fact, and applies a catalog:"
    mdw ""
    mdw "    /root/installagent.sh <puppet_role> <install_url>"
    mdw "    /root/installagent.sh pe_compiler ${lb_fqdn:-${primary_fqdn}}"
    mdw ""
    mdw "## Test node"
    mdw ""
    mdw "A plain test node (no PE/agent) is provisioned for general testing.  It has"
    mdw "nothing installed beyond SSH.  To use it as a PE agent, first install the agent:"
    mdw "  - install:  curl -k https://${primary_fqdn}:8140/packages/current/install.bash | bash"
    mdw "  - run:  puppet agent -t"
    mdw ""
    if [[ "$use_gitnano" == "true" ]]; then
      mdw "## Local git (gitnano)"
      mdw ""
      mdw "- API: http://${primary_fqdn}:${gitnano_port}  (Bearer token: \`${gitnano_token}\`)"
      mdw "- Live worktree: \`/var/www/production\`"
      mdw "- r10k remote: \`gitnano@${primary_fqdn}:/opt/gitnano/repos/control-repo.git\`"
      mdw "- push/deploy:"
      mdw "    cd /var/www/production && git add . && git commit -m 'change' && git push gitnano production"
      mdw "    sudo /opt/puppetlabs/bin/puppet-code deploy production --wait && sudo /opt/puppetlabs/bin/puppet agent -t"
      mdw ""
    fi
    if [[ "$use_openainano" == "true" ]]; then
      mdw "## OpenAINano (PE AI ↔ Ollama bridge)"
      mdw ""
      mdw "- URL: \`http://${primary_fqdn}:${openainano_port}\`"
      mdw "- Bridges PE AI to local Ollama: \`http://127.0.0.1:11434\`"
      mdw "- Runs as a systemd service (\`openainano.service\`)."
      mdw "- Ollama is installed on the master automatically (port 11434)."
      mdw "- A local model is not powerful enough – authenticate + pull a CLOUD model:"
      mdw "    ollama login  &&  ollama run ${openainano_model}"
      mdw ""
    fi
    if [[ "$use_reponano" == "true" ]]; then
      mdw "## Reponano (local apt/yum package repo)"
      mdw ""
      mdw "- URL: \`http://${primary_fqdn}:${reponano_port}\`"
      mdw "- Storage: \`/var/www/reponano\`  (\`<distro>/<ver>/<arch>\`)"
      mdw "- Runs as a systemd service (\`reponano.service\`)."
      mdw "- Sync a package: \`curl -X POST http://${primary_fqdn}:${reponano_port}/sync -H 'Content-Type: application/json' -d '{\"pkg\":\"sl\",\"distro\":\"ubuntu\",\"ver\":\"<codename>\"}'\`"
      mdw "- Client toggle on a node: \`/root/reponano_client.sh ${primary_fqdn}\`  (\`--restore\` to go back online)"
      mdw "- Full offline pull: \`/root/reponano_full_sync.sh\` + \`/root/reponano_forgenano_sync.sh\`  (manifest + module-required packages; codename auto-detected)"
      mdw "- Full offline build: pulls all packages + modules, then switches the repo/forge to local"
      mdw ""
    fi
    if [[ "$use_forgenano" == "true" ]]; then
      mdw "## Forgenano (local Puppet Forge / module mirror)"
      mdw ""
      mdw "- URL: \`http://${primary_fqdn}:${forgenano_port}\`"
      mdw "- Storage: \`/var/lib/puppet_localforge\`  (\`<owner>-<name>-<version>.tar.gz\`)"
      mdw "- Runs as a systemd service (\`forgenano.service\`)."
      mdw "- Add a module: \`curl -X POST http://${primary_fqdn}:${forgenano_port}/v3/modules -H 'X-API-KEY: <admin-key>' -H 'Content-Type: application/json' -d '{\"module\":\"puppetlabs-stdlib\"}'\`"
      mdw "- Populate: \`/root/forgenano_populate.sh\`   |   Workflow: \`/root/forgenano_local.sh\`"
      mdw "- Full offline build: also pulls the full module catalog into the local forge"
      mdw ""
    fi
    if [[ "$use_scanano" == "true" ]]; then
      mdw "## Scanano (CVE-enabled vulnerability scan bridge)"
      mdw ""
      mdw "- URL: \`https://${primary_fqdn}:${scanano_port}\`"
      mdw "- Runs as a systemd service (\`scanano.service\`)."
      mdw "- Test: \`curl -k https://${primary_fqdn}:${scanano_port}/scans\`"
      mdw "- API token: \`${scanano_token}\`"
      mdw ""
    fi
    mdw "## Restart behavior"
    mdw ""
    mdw "Containers run with \`--restart unless-stopped\`, so PE comes back after this host"
    mdw "reboots (Docker + the containers auto-start).  If a container is down, restart it:"
    mdw ""
    mdw "    docker start ${primary_fqdn}"
    mdw ""
    mdw "---"
    mdw ""
    mdw "This file was written by the PE Lab wizard.  Re-run the wizard to regenerate it."
  else
    # VM topology: write a simpler helper.md
    local md="${script_dir}/helper.md"
    local test_fqdn; test_fqdn=$(build_fqdn test)
    mdw() { printf '%s\n' "$@" >> "$md"; }
    : > "$md"
    mdw "# PE Lab — Access Reference"
    mdw ""
    mdw "Generated: $(date)"
    mdw ""
    mdw "Topology: **${instype}**  |  Runtime: **VM**  |  Size: **${node_size}** (${gcp_machine_type})"
    mdw ""
    mdw "## Console"
    mdw ""
    mdw "- URL: **https://${primary_fqdn}**"
    mdw "- Login: \`admin\` / \`${adminpwd:-<as configured>}\`"
    mdw ""
    mdw "## SSH"
    mdw ""
    mdw "    ssh -i ${ssh_key_path} ${ssh_user}@${primary_fqdn}"
    mdw ""
    mdw "### SSH-key requirements on the targets"
    mdw ""
    mdw "Before the wizard can connect, **every target node** must already allow the"
    mdw "chosen public key, or the SSH/bootstrap step will fail:"
    mdw ""
    mdw "1. Public key (\`${ssh_key_path}.pub\`) present in the ssh_user's"
    mdw "   \`~/.ssh/authorized_keys\` (for root: \`/root/.ssh/authorized_keys\`)."
    mdw "2. \`/etc/ssh/sshd_config\` has these **uncommented** (not hashed out):"
    mdw "   - \`PubkeyAuthentication yes\`"
    mdw "   - \`AuthorizedKeysFile .ssh/authorized_keys\`"
    mdw "3. \`~/.ssh\` and \`~/.ssh/authorized_keys\` permissions allow sshd to read the key"
    mdw "   (commonly \`chmod 700 ~/.ssh\` and \`chmod 600 ~/.ssh/authorized_keys\`)."
    mdw ""
    mdw "For cloud/VM base-image deployments the wizard pauses after Terraform creates"
    mdw "the VMs so you can confirm/add these before it proceeds."
    mdw ""
    mdw "## Test node"
    mdw ""
    mdw "A plain test node (no PE/agent) is provisioned for general testing:"
    mdw ""
    mdw "- SSH: \`ssh -i ${ssh_key_path} ${ssh_user}@${test_fqdn}\`"
    mdw "- It has nothing installed beyond SSH.  To use it as a PE agent, first install the agent:"
    mdw "  - install:  curl -k https://${primary_fqdn}:8140/packages/current/install.bash | bash"
    mdw "  - run:  puppet agent -t"
    mdw ""
    mdw "## installagent.sh (agent (re)installer) on every node"
    mdw ""
    mdw "Every node carries \`/root/installagent.sh\` (executable, owner root).  It removes"
    mdw "any existing agent, (re)installs one with a role fact, and applies a catalog:"
    mdw ""
    mdw "    /root/installagent.sh <puppet_role> <install_url>"
    mdw "    /root/installagent.sh pe_compiler ${primary_fqdn}"
    mdw ""
    if [[ "$use_reponano" == "true" ]]; then
      mdw "## Reponano (local apt/yum package repo)"
      mdw ""
      mdw "- URL: \`http://${primary_fqdn}:${reponano_port}\`"
      mdw "- Storage: \`/var/www/reponano\`  (\`<distro>/<ver>/<arch>\`)"
      mdw "- Runs as a systemd service (\`reponano.service\`)."
      mdw "- Sync a package: \`curl -X POST http://${primary_fqdn}:${reponano_port}/sync -H 'Content-Type: application/json' -d '{\"pkg\":\"sl\",\"distro\":\"ubuntu\",\"ver\":\"<codename>\"}'\`"
      mdw "- Client toggle on a node: \`/root/reponano_client.sh ${primary_fqdn}\`  (\`--restore\` to go back online)"
      mdw "- Full offline pull: \`/root/reponano_full_sync.sh\` + \`/root/reponano_forgenano_sync.sh\`  (manifest + module-required packages; codename auto-detected)"
      mdw "- Full offline build: pulls all packages + modules, then switches the repo/forge to local"
      mdw ""
    fi
    if [[ "$use_forgenano" == "true" ]]; then
      mdw "## Forgenano (local Puppet Forge / module mirror)"
      mdw ""
      mdw "- URL: \`http://${primary_fqdn}:${forgenano_port}\`"
      mdw "- Storage: \`/var/lib/puppet_localforge\`  (\`<owner>-<name>-<version>.tar.gz\`)"
      mdw "- Runs as a systemd service (\`forgenano.service\`)."
      mdw "- Add a module: \`curl -X POST http://${primary_fqdn}:${forgenano_port}/v3/modules -H 'X-API-KEY: <admin-key>' -H 'Content-Type: application/json' -d '{\"module\":\"puppetlabs-stdlib\"}'\`"
      mdw "- Populate: \`/root/forgenano_populate.sh\`   |   Workflow: \`/root/forgenano_local.sh\`"
      mdw "- Full offline build: also pulls the full module catalog into the local forge"
      mdw ""
    fi
    if [[ "$use_scanano" == "true" ]]; then
      mdw "## Scanano (CVE-enabled vulnerability scan bridge)"
      mdw ""
      mdw "- URL: \`https://${primary_fqdn}:${scanano_port}\`"
      mdw "- Runs as a systemd service (\`scanano.service\`)."
      mdw "- Test: \`curl -k https://${primary_fqdn}:${scanano_port}/scans\`"
      mdw "- API token: \`${scanano_token}\`"
      mdw ""
    fi
    tui_info "Browse to:  ${BOLD}https://${primary_fqdn}${RESET}"
    tui_info "Test node:  ssh -i ${ssh_key_path} ${ssh_user}@${test_fqdn}  (plain, no PE/agent)"
    tui_info "Every node has /root/installagent.sh (executable) ready to (re)install the agent:"
    tui_info "  /root/installagent.sh <puppet_role> <install_url>"
    tui_info "A full reference was written to ${BOLD}${md}${RESET}"
  fi
  # Mark helper.md as written so the EXIT trap in pelab.sh does not re-run this.
  helper_md_written="yes"
}

