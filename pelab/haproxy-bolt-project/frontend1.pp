plan haproxy::frontend1 {
  include haproxy

  haproxy::frontend { "$targets":
    ipaddress    => "$facts['networking']['ip']",
    ports        => '18140',
    mode         => 'tcp',
    bind_options => 'accept-proxy',
    options      => {
      'option'   => [
        'tcplog',
        'accept-invalid-http-request',
      ],
      'timeout client' => '30s',
      'balance'    => 'roundrobin'
    },
  }
}

