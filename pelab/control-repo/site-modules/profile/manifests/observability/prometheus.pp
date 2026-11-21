class profile::observability::prometheus (
  String $version = '2.52.0',
) {
  unless defined(Class['prometheus::server']) {
    class { 'prometheus::server':
      version        => $version,
      manage_service => true,
      service_enable => true,
      service_ensure => 'running',
      scrape_configs => [
        {
          job_name       => 'puppet_observability',
          scrape_interval=> '15s',
          static_configs => [{ targets => ['localhost:9100'], labels => { alias => 'puppet_observability' } }],
        },
      ],
    }
  }
}
