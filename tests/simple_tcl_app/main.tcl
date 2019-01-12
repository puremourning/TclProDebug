#!/bin/sh
#\
exec tclsh "$0" "$@"

set args 0
foreach arg $::argv {
    incr args
    puts "ARG: $arg"

}
puts "There were $args args"
