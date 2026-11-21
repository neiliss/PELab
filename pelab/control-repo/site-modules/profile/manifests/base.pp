# site-modules/profile/manifests/base.pp
# @summary A short summary of the purpose of this class
#
# A description of what this class does
#
# @example
#   include profile::base
class profile::base {
  class { 'motd':
    content => "Hello! You are in ${trusted['extensions']['pp_datacenter']}.\n",
  }
  class { 'puppet_operational_dashboards::enterprise_infrastructure':
    template_format => 'yaml',
  }
}
