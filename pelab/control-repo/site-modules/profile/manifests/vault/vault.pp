class profile::vault::vault {
if $facts['osfamily'] != 'windows' {
    package { 'wget':
        ensure => present,
          }
            package { 'unzip':
                ensure => present,
                  }
                    Archive {
                        provider => 'wget',
                            require  => Package['wget', 'unzip'],
                              }
                              }
file { '/var/lib/vault':
ensure  => directory,
owner   => 'vault',
group   => 'vault',
mode    => '0700',
recurse => true,
}
class { 'vault':
  storage => {
    file => {
      path => '/var/lib/vault',
    }
  },
  listener => [
    {
      tcp => {
        address     => '127.0.0.1:8200',
        tls_disable => 1,
      }
    },
    {
      tcp => {
        address => '0.0.0.0:8200',
      }
    }
  ]
}
include vault
#
include profile::vault::vaultinit
}
