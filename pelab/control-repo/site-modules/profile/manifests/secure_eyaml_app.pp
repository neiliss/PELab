# =========================================================================
# File: site-modules/profile/manifests/secure_eyaml_app.pp
# Version: PLATINUM 2.1
# =========================================================================
class profile::secure_eyaml_app {

  $app_user     = 'root'
  $app_group    = 'root'
  $exec_wrapper = '/usr/local/bin/vault_wrapper.sh'

  # 1. Provision the Execution Wrapper Script
  file { $exec_wrapper:
    ensure => file,
    owner  => $app_user,
    group  => $app_group,
    mode   => '0700',
    source => 'puppet:///modules/profile/vault_wrapper.sh',
  }

  # 2. Pure Flat Deferred Lookup
  # Resolves cleanly against your secrets.yaml file now that quotes are removed.
  $resolved_secret = Deferred('lookup', ['profile::secure_eyaml_app::db_password'])

  # 3. Hardened Execution Wrapper Pipe
  exec { 'execute_secure_vault_sync':
    command     => $exec_wrapper,
    logoutput   => false,
    refreshonly => false,
    require     => File[$exec_wrapper],
    environment => [
      "SECURE_VAULT_PASSWORD=${resolved_secret}"
    ],
  }
}