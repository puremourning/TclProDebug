#!/bin/sh
#\
exec tclsh "$0" "$@"

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
