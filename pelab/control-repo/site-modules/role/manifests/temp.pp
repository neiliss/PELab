
class role::temp {
  #  include profile::scanner
     $test  = lookup('test')
     notify { "test  = ${test}": } 
 }
