node default {

  # 1. Try Hiera-based classification first
  $classes = lookup('classes', { default_value => undef })

  if $classes {

    case $classes {
      String[1]: {
        include $classes
      }

      Array[String[1], 1]: {
        $classes.unique.include
      }

      default: {
        fail('Invalid type for Hiera key "classes"')
      }
    }

  }
  # 2. Fallback to pp_role from CSR extensions
  elsif $trusted['extensions']['pp_role'] {

    $role = $trusted['extensions']['pp_role']
    include "role::${role}"

  }
  # 3. Fallback to external fact 'myrole'
  elsif $facts['myrole'] {

    $role = $facts['myrole']
    include "role::${role}"

  }
  # 4. Nothing matched - Assign fallback 'temp' role instead of failing
  else {
    
    include 'role::temp'
    
  }
}