#!/bin/sh
#\
exec tclsh "$0" "$@"

proc Puts { args } {
  ::test::Puts {*}$args
}

namespace eval ::test {
  proc Puts { args } {
    puts {*}$args
  }

  proc DoTop { args } {
    uplevel #0 {*}$args
  }
  proc Test { } {
    uplevel 1 Puts -nonewline "Hello,"

    DoTop Puts "World!"
  }
}

set args 0
foreach arg $::argv {
    incr args
    puts "ARG: $arg"

}
puts "There were $args args"

set something_like_a_list {a b c d}
lappend something_like_a_list e f g

set not_a_dict { a b c }
set list_of_lists { a {b B} {c C c} }
set dict_of_dicts { a {a A} b {b B} c {c C} }

puts "done"

proc Toast { } {
  ::test::Test
}

Toast
