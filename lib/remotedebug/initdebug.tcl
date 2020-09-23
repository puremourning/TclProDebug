# prodebug.tcl --
#
#	This file contains the public routines used to start debugging user
#	code in a remote application.
#
# Copyright (c) 1998-1999 by Scriptics Corporation.
# Copyright (c) 2017 Forward Folio LLC
# See the file "license.terms" for information on usage and redistribution of this file.
#


#
# This file comprises the public interface to the TclPro Debugger for use
# by applications that are not launched directly from the debugger.  The
# public interface consists of the two commands "debugger_init" and
# "debugger_eval".  A typical application will source this file then invoke
# "debugger_init" to initiate the connection to the debugger.  Once
# connected, the application can use the "debugger_eval" command to
# evaluate scripts that the debugger will be able to step through.
# Additionally, various other Tcl commands including "source" and "proc"
# will automatically instrument code.  Any blocks of code (e.g. procedure
# bodies) that existed before "debugger_init" was invoked will execute
# without any instrumentation.
#


# debugger_init --
#
#	This function initiates a connection to the TclPro Debugger.  Files
#	that are sourced and procedures that are defined after this
#	function completes will be instrumented by the debugger.
#
# Arguments:
#	host	Name of the host running the debugger.
#	port	TCP port that the debugger is using.
#
# Results:
#	Returns 1 on success and 0 on failure.

proc debugger_accept { channel clientAddress clientPort } {
    global debugger_accepted
    puts stderr "New connection from $clientAddress:$clientPort"
    if { [info exists debugger_accepted] } {
        error "Too many clients"
    }
    set debugger_accepted $channel
}

proc debugger_init_accept { {port  2576} } {
    debugger_init localhost $port 1
}

proc debugger_init {{host 127.0.0.1} {port 2576} {server 0}} {
    global tcl_version

    if { $server } {
        global debugger_accepted
        if {[catch {set socket [socket -server debugger_accept $port]} err] != 0} {
            puts stderr "Unable to listen on socket: $err"
            return 0
        }
        vwait debugger_accepted
        close $socket
        set socket $debugger_accepted 
    } else {
        if {[catch {set socket [socket $host $port]}] != 0} {
            return 0
        }
    }
    fconfigure $socket -blocking 1 -translation binary

    # On 8.1 and later versions we should ensure the socket is not doing
    # any encoding translations.

    if {$tcl_version >= 8.1} {
	fconfigure $socket -encoding utf-8
    }

    # Send the loader and tcl library version

    set msg [list HELLO 1.0 $tcl_version]
    puts $socket [string length $msg]
    puts -nonewline $socket $msg
    flush $socket

    # Get the rest of the nub library and evaluate it in the current scope.
    # Note that the nub code assumes there will be a "socket" variable that
    # contains the debugger socket channel.

    if {[gets $socket bytes] == -1} {
	close $socket
	return 0
    }
    set msg [read $socket $bytes]
    eval [lindex $msg 1]
    return 1
}

# debugger_eval --
#
#	Instrument and evaluate a script.  This routine is a trivial
#	implementation that is replaced when the nub is downloaded.
#
# Arguments:
#	args		One or more arguments, the last of which must
#			be the script to evaluate.
#
# Results:
#	Returns the result of evaluating the script.

proc debugger_eval {args} {
    global errorInfo errorCode
    set length [llength $args]
    if {$length < 1} {
	error "wrong # args: should be \"debugger_eval ?options? script\""
    }
    set code [catch {uplevel 1 [lindex $args [expr {$length - 1}]]} result]
    return -code $code -errorcode $errorCode -errorinfo $errorInfo $result
}

# debugger_break --
#
#	This command may be inserted in user code to cause a break 
#	to occur at the location of this command.  If the application
#	is not connected to the debugger this command is a no-op.
#
# Arguments:
#	str	(Optional) String that displays in debugger.
#
# Results:
#	None.  Will send break message to debugger.

proc debugger_break {{str ""}} {
    return
}
