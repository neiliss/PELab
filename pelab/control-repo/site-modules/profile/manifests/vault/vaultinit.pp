class profile::vault::vaultinit {

  $vault_addr     = 'http://127.0.0.1:8200'
  $permanent_dir  = '/etc/vault'
  $permanent_file = "${permanent_dir}/vault_init.txt"
  $temp_file      = '/tmp/vault_init.txt'

  # Debug: Check Puppet's view of variables before the exec runs
  notify { "DEBUG: Vault Init - Addr: ${vault_addr}, Perm: ${permanent_file}, Temp: ${temp_file}": }

  exec { 'vault_init_and_unseal':
    command   => "/bin/bash -c 'export VAULT_ADDR=\"${vault_addr}\"; \
                if ! vault operator init -status > /dev/null 2>&1 && [ ! -f ${permanent_file} ] && [ ! -f ${temp_file} ]; then \
                  echo \"DEBUG: Initializing Vault...\" >&2; \
                  vault operator init > ${temp_file} 2>&1; \
                fi; \
                [ -f ${temp_file} ] && FILE=${temp_file} || FILE=${permanent_file}; \
                echo \"DEBUG: Using init file: \$FILE\" >&2; \
                if [ -f \"\$FILE\" ] && vault status | grep -q \"Sealed.*true\"; then \
                  for i in 1 2 3; do \
                    KEY=\$(grep \"Unseal Key \$i:\" \"\$FILE\" | sed \"s/.*: //\"); \
                    echo \"DEBUG: Extracting Key \$i: \${KEY:0:5}...[hidden]\" >&2; \
                    vault operator unseal \"\$KEY\"; \
                    sleep 0.5; \
                  done; \
                  if vault status | grep -q \"Sealed.*false\"; then \
                    echo \"DEBUG: Vault successfully unsealed. Cleaning up...\" >&2; \
                    [ -f ${temp_file} ] && mv ${temp_file} ${permanent_file} && chmod 600 ${permanent_file}; \
                  fi; \
                else \
                  echo \"DEBUG: Vault already unsealed or init file not found.\" >&2; \
                fi'",
    user      => 'root',
    path      => ['/bin', '/usr/bin', '/usr/local/bin'],
    # logoutput => on_failure will show the "echo" statements if the command fails.
    # logoutput => true will show them every time.
    logoutput => true,
    unless    => "/bin/bash -c 'export VAULT_ADDR=\"${vault_addr}\"; vault status | grep -q \"Sealed.*false\"'",
    require   => [File[$permanent_dir], Service['vault']],
  }
}
