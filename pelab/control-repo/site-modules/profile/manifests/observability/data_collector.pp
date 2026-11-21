class profile::observability::data_collector { 
   class { 'puppet_data_connector': 
      dropzone  => '/opt/puppetlabs/puppet/prometheus_dropzone', 
      stale_time => 30, 
   } 
   class { 'puppet_data_connector_enhancer': 
      dropzone  => '/opt/puppetlabs/puppet/prometheus_dropzone/reports', 
   } 
} 
