# =============================================================================
# installagent.sh  –  helper module
# Deploys the standalone `installagent.sh` utility to every node's /root so it
# is ready to (re)install a Puppet agent with a role fact on any node:
#
#     /root/installagent.sh <puppet_role> <install_url>
#
# e.g.   /root/installagent.sh pe_compiler core0.example.com
#
# The utility (a separate, hand-maintained script) removes any existing agent,
# installs from https://<install_url>:8140/packages/current/install.bash with
# extension_requests:pp_role, writes a myrole custom fact, and applies a catalog.
#
# The file lives at ${script_dir}/installagent.sh (the wizard's own root) so a
# deployment uploads it from a local, self-contained copy rather than peadm's
# modules directory.  Sourced by pelab.sh.  Do not run directly.
# =============================================================================

# Ordered list of role names to deploy to, for the current topology.
installagent_roles() {
  local i
  for i in $(seq 0 $((node_count-1)));      do echo "core${i}"; done
  for i in $(seq 0 $((compiler_count-1)));  do echo "compiler${i}"; done
  [[ "$instype" =~ ^(XL|LARGE)$ ]] && echo "haproxy"
  # DR replica is core1 – the core loop already emits it when node_count>=2.
  echo "test"                                    # plain test node, no PE/agent
}

# Upload installagent.sh to a single node's /root and make it executable.
# Node is addressed as a Docker container (docker runtime) or by FQDN (VM).
installagent_deploy_one() {
  local role="$1"
  local script="${script_dir}/installagent.sh"
  local node; node=$(build_fqdn "$role")

  if [[ "$runtime" == "docker" ]]; then
    local cname="${nodeprefix}${role}"
    if [[ "$docker_host" == "local" ]]; then
      docker exec -i "$cname" bash -c 'cat > /root/installagent.sh && chmod +x /root/installagent.sh' < "$script"
    else
      # Containers run on the Docker-host VM; stream the file through it.
      dh_ssh "docker exec -i ${cname} bash -c 'cat > /root/installagent.sh && chmod +x /root/installagent.sh'" \
        < "$script"
    fi
  else
    # Real VM/cloud node: stream the file over SSH.
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=20 "${ssh_user}@${node}" \
      'cat > /root/installagent.sh && chmod +x /root/installagent.sh' < "$script"
  fi
  tui_ok "installagent.sh -> /root/installagent.sh on ${node} (+x)"
}

# Deploy installagent.sh to every node (best-effort; a failure on one node is
# reported but doesn't abort the run).
install_installagent() {
  local script="${script_dir}/installagent.sh"
  if [[ ! -f "$script" ]]; then
    tui_warn "installagent.sh not found at ${script} – skipping deployment."
    tui_warn "Place a copy of installagent.sh at the wizard root and re-run."
    return 0
  fi

  local roles=() role
  while IFS= read -r role; do roles+=("$role"); done < <(installagent_roles)
  # De-dupe (e.g. core1 may appear more than once in HA/DR topologies).
  local seen=() clean=() r skip
  for r in "${roles[@]}"; do
    skip=no
    for s in "${seen[@]}"; do [[ "$s" == "$r" ]] && { skip=yes; break; }; done
    if [[ "$skip" == "no" ]]; then seen+=("$r"); clean+=("$r"); fi
  done
  roles=("${clean[@]}")

  tui_section "Deploying installagent.sh to every node (/root, +x)"
  tui_info "Utility: /root/installagent.sh <puppet_role> <install_url>"
  for role in "${roles[@]}"; do
    installagent_deploy_one "$role" || tui_warn "deploy to ${role} failed – see output above"
  done
  tui_ok "installagent.sh deployed to ${#roles[@]} node(s)."
}
