# This is a Bolt plan
plan xhaproxy (
  TargetSpec $targets,
  String $node = "$targets"
) {
  # Install the HAProxy package
  run_task('package', $targets,
    name => 'haproxy',
    action => 'install',
  )
  # Ensure the service is running
  run_task('service', $targets,
    name => 'haproxy',
    action => 'start',
)
  run_task('service', $targets,
    name => 'haproxy',
    action => 'enable',
  )
}

