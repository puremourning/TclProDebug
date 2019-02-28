# debug_server.tcl
# 
# Copyright (c) Fidessa Plc. 2019
# 

package require cmdline
package require debugserver

namespace eval ::debugger {
    if {[catch {package require tbcload}] == 1} {
	variable ::hasLoader 0
    } else {
	variable ::hasLoader 1
    }
    variable libdir [file join [file dirname [info script]] .. lib tcldebugger]

    variable parameters
}

proc ::debugger::init {} {
    variable libdir
    variable parameters
    array set parameters [list \
        aboutImage $libdir/images/about.gif \
        aboutCopyright "" \
        appType local \
        iconImage $libdir/images/debugUnixIcon.gif \
        productName "DebugAdapter" \
    ]

    # Remove the send command.  This will keep other applications
    # from being able to poke into our interp via the send command.
    if {[info commands send] == "send"} {
	rename send ""
    }

    system::initGroups

    # Restore instrumentation preferences.

    # instrument::extension incrTcl [pref::prefGet instrumentIncrTcl]
    # instrument::extension tclx   [pref::prefGet instrumentTclx]
    # instrument::extension expect [pref::prefGet instrumentExpect]
    # Register events sent from the engine to the GUI.
    #

    server::start $libdir

    namespace eval :: {namespace import -force ::instrument::*}
    set files [glob -nocomplain \
	    [file join [file dir [info nameofexecutable]] ../../lib/*.pdx]]
    if {[info exists ::env(TCLPRO_LOCAL)]} {
	set files [concat $files [glob -nocomplain \
		[file join $::env(TCLPRO_LOCAL) *.pdx]]]
    }
    foreach file $files {
	if {[catch {uplevel \#0 [list source $file]} err]} {
	    bgerror "Error loading $file:\n$err"
	}
    }
    
}

proc ::Source { path } {
    variable ::hasLoader

    set stem [file rootname $path]
    set loadTcl 1
    if {($hasLoader == 1) && ([file exists $stem.tbc] == 1)} {
	set loadTcl [catch {uplevel 1 [list source $stem.tbc]}]
    }
    
    if {$loadTcl == 1} {
	uplevel 1 [list source $stem.tcl]
    }
}

proc ::bgerror { msg } {
    ::server::bgerror $msg
}

Source [file join $::debugger::libdir pref.tcl]
Source [file join $::debugger::libdir system.tcl]

Source [file join $::debugger::libdir dbg.tcl]
Source [file join $::debugger::libdir break.tcl]
Source [file join $::debugger::libdir block.tcl]
Source [file join $::debugger::libdir instrument.tcl]

Source [file join $::debugger::libdir projWin.tcl]
Source [file join $::debugger::libdir coverage.tcl]

Source [file join $::debugger::libdir location.tcl]
Source [file join $::debugger::libdir util.tcl]

source [file join $::debugger::libdir uplevel.pdx]
source [file join $::debugger::libdir tcltest.pdx]
#source [file join $::debugger::libdir blend.pdx]
source [file join $::debugger::libdir oratcl.pdx]
source [file join $::debugger::libdir tclCom.pdx]
source [file join $::debugger::libdir xmlGen.pdx]


debugger::init

global APP_STATE
set APP_STATE "running"
while { $APP_STATE eq "running" } {
    vwait APP_STATE
    puts "APP_STATE is $APP_STATE"
}

puts "Quiting debug adapter due to state: $APP_STATE"
