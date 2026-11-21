# init.pp
node '$target' {
  class { 'xhaproxy':
    package_ensure => 'present',
    service_ensure => 'running',
    global_options => {
      'log'     => '/var/log/haproxy.log',
      'chroot'  => '/var/lib/haproxy',
      'user'    => 'haproxy',
      'group'   => 'haproxy',
      'daemon'  => '',
      'maxconn' => '256',
    },
    defaults_options => {
      'log'     => 'global',
      'mode'    => 'http',
      'option'  => ['httplog', 'dontlognull'],
      'retries' => '3',
      'timeout' => [
        'http-request' => '10s',
        'queue'        => '1m',
        'connect'      => '10s',
        'client'       => '1m',
        'server'       => '1m',
        'http-keep-alive' => '10s',
        'check'        => '10s',
      ],
      'balance' => 'roundrobin',
    },
    listen => {
      'puppet' => {
        'collect_exported' => false,
        'ipaddress'        => $::ipaddress,
        'ports'            => '8140',
        'options'          => {
          'mode'  => 'tcp',
          'option' => ['tcplog'],
        },
      },
    },
  }
}

