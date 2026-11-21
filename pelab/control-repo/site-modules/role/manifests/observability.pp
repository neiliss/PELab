# @summary A short summary of the purpose of this class
#
# A description of what this class does
#
# @example
#   include role::observability
class role::observability {
  include profile::base
  #include profile::prometheus
  include profile::observability::grafana_wrapper
  #include profile::pod
}
