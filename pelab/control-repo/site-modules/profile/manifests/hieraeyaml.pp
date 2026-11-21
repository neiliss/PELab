class profile::hieraeyaml {
  package { 'hiera-eyaml':
  ensure   => 'installed',
  provider => 'puppetserver_gem',
}
file { ['/etc/puppetlabs/puppet', '/etc/puppetlabs/puppet/keys']:
  ensure => directory,
  owner  => 'pe-puppet',
  group  => 'pe-puppet',
  mode   => '0755',
}

exec { 'eyaml-createkeys':
  command => '/usr/local/bin/eyaml createkeys --keys-dir /etc/puppetlabs/puppet/keys',
  path    => ['/usr/local/bin','/usr/bin','/bin'],
  onlyif  => 'test ! -f /etc/puppetlabs/puppet/keys/private_key.pkcs7.pem',
  require => File['/etc/puppetlabs/puppet/keys'],
  user    => 'root',
}
}
