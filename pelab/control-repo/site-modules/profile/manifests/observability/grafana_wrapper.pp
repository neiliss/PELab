class profile::observability::grafana_wrapper {
  # 1. Realize the apt class to ensure apt::update is available
  include apt

  # 2. Enforce that apt::update finishes completely BEFORE the grafana class starts
  Class['apt::update'] -> Class['grafana']

  # 3. Declare the grafana class
  class { 'grafana': }
}