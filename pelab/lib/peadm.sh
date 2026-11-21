# =============================================================================
# peadm.sh  –  extracted from setup.sh (lines 4668-4734)
# Sourced by pelab.sh.  Do not run directly.
# =============================================================================
run_peadm_install() {
  tui_section "PEADM Install"
  # peadm is installed into Bolt's modulepath by ensure_peadm_module during the
  # prerequisite check, so peadm::install resolves from any directory.
  #
  # Gate: peadm's configure step applies the node_manager class on the primary,
  # which needs the node_group resource type from the node_manager module to be
  # in Bolt's modulepath (Bolt bundles those modules into the apply).  Fail fast
  # here instead of after a ~12 min install if it is missing.
  if [[ ! -f "${HOME}/.puppetlabs/bolt/modules/node_manager/lib/puppet/type/node_group.rb" ]]; then
    tui_err "node_manager module (Node_group type) not found in Bolt modulepath"
    tui_err "${HOME}/.puppetlabs/bolt/modules/node_manager/lib/puppet/type/node_group.rb"
    tui_err "Re-run so ensure_peadm_module can install it, or run:"
    tui_err "  bolt project init && bolt module add puppetlabs-peadm"
    exit 1
  fi
  tui_ok "node_manager module (Node_group type) present in Bolt modulepath"

  ${BOLT} plan run peadm::install \
    --params "@${PARAMS_FILE}" \
    $(bolt_inv)
  local status=$?
  if [[ $status -ne 0 ]]; then
    tui_err "PEADM install failed (exit $status)"; exit $status
  fi
  tui_ok "PEADM install completed"

  local lic="${suite_license_path:-${script_dir}/suite-license.lic}"
  local core0_fqdn; core0_fqdn=$(build_fqdn core0)
  if [[ -f "$lic" ]]; then
    tui_step "Installing PE license"
    ${BOLT} file upload "$lic" "/etc/puppetlabs/suite-license.lic" \
      --targets "$core0_fqdn" $(bolt_inv)
    ${BOLT} command run \
      "chown root:root /etc/puppetlabs/suite-license.lic && \
       chmod 644 /etc/puppetlabs/suite-license.lic && \
       systemctl restart pe-console-services" \
      --targets "$core0_fqdn" $(bolt_inv) \
      || tui_warn "License steps failed – continuing"
    tui_ok "PE license installed"
  else
    tui_warn "No suite-license.lic found – skipping license upload"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Harden PostgreSQL for full container/host restarts.
#
# After an UNCLEAN shutdown (e.g. `gcloud compute instances reset`, or a hard
# Docker-host reboot) PostgreSQL performs WAL crash recovery.  When all the lab
# containers boot at once the disk I/O makes that recovery exceed PE's 300s
# startup cap (TimeoutSec + `pg_ctl -t 300`), so systemd kills postgres
# mid-recovery and pe-postgresql fails - cascading to puppetdb, puppetserver,
# console-services, orchestration-services and ace-server.  Raising both
# timeouts lets recovery finish, so a full Docker-node restart self-heals.
# ──────────────────────────────────────────────────────────────────────────────
harden_postgres_recovery() {
  local core0="${nodeprefix}core0"
  local fqdn; fqdn=$(build_fqdn core0)

  local _stmp; _stmp="$(mktemp)"
  cat > "$_stmp" <<'EOPG'
#!/bin/bash
set -euo pipefail
pgver=$(ls -d /opt/puppetlabs/server/data/postgresql/*/ 2>/dev/null | grep -oE '/[0-9]+/$' | tr -d '/' | sort -n | tail -1)
[ -z "$pgver" ] && pgver=17
mkdir -p /etc/systemd/system/pe-postgresql.service.d
cat > /etc/systemd/system/pe-postgresql.service.d/zz-recovery-timeout.conf <<EOF
[Service]
TimeoutStartSec=1800
TimeoutStopSec=1800
ExecStart=
ExecStart=/opt/puppetlabs/server/apps/postgresql/${pgver}/bin/pg_ctl start -D \${PGDATA} --log \${PGSTARTUPLOG} -o "-c log_directory='/var/log/puppetlabs/postgresql/${pgver}' -p \${PGPORT}" -s -w -t 1800
EOF
systemctl daemon-reload
echo "postgres restart-hardening drop-in written (pg${pgver})"
EOPG
  chmod +x "$_stmp"

  tui_section "Hardening PE for full restarts (PostgreSQL recovery timeout)"
  if [[ "$runtime" == "docker" ]]; then
    if [[ "$docker_host" == "local" ]]; then
      docker exec -i "${core0}" bash -c 'cat > /root/harden_postgres_recovery.sh' < "$_stmp"
      docker exec "${core0}" bash /root/harden_postgres_recovery.sh
    else
      scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$_stmp" "${ssh_user}@${docker_host_ip}:/tmp/harden_postgres_recovery.sh"
      dh_ssh "docker exec -i ${core0} bash -c 'cat > /root/harden_postgres_recovery.sh' < /tmp/harden_postgres_recovery.sh"
      dh_ssh "docker exec ${core0} bash /root/harden_postgres_recovery.sh"
    fi
  else
    scp -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$_stmp" "${ssh_user}@${fqdn}:/root/harden_postgres_recovery.sh"
    ssh -i "$ssh_key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "${ssh_user}@${fqdn}" "bash /root/harden_postgres_recovery.sh"
  fi
  rm -f "$_stmp"
  tui_ok "PostgreSQL restart-hardening applied on ${core0}"
}
