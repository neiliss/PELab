class role::master {
    include profile::base
    include profile::observability::data_collector
    include puppet_operational_dashboards::enterprise_infrastructure
    include profile::observability::prometheus
    include puppet_data_connector_enhancer
    include profile::observability::grafana_wrapper
    include profile::observability::prometheus_fed
    include profile::secure_eyaml_app
    # gitnano is deployed by the wizard's own tooling (gitnano.sh + install_active_puppetfile),
    # NOT via the classification.  The old profile::gitnano module is a hardcoded TESTING
    # version with stale values (old gitlab URL / wrong FQDN / placeholder token) and it
    # bypasses hiera, so it is deliberately left OUT of the master role.
    #include profile::gitnano
    #include profile::hieraeyaml
    #include profile::vault::vault
}
