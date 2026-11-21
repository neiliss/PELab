class profile::observability::prometheus_fed (
  String $version = '2.52.0',
  Array[String] $targets = lookup('profile::prometheus_fed::targets', Array[String], 'first', []),
) {
  $default_target = 'localhost:9090'
  $all_targets    = unique($targets + [$default_target])

  unless defined(Class['prometheus::server']) {
    class { 'prometheus::server':
      version        => $version,
      manage_service => true,
      service_enable => true,
      service_ensure => 'running',
      scrape_configs => [
        {
          job_name        => 'federated',
          scrape_interval => '15s',
          honor_labels    => true,
          metrics_path    => '/federate',
          params => { 'match[]' => ['{job="puppet_observability"}'] },
          static_configs => [{ targets => $all_targets }],
        },
      ],
    }
  }
}
