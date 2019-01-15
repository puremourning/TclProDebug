package require parser

namespace eval ::server {

    variable state UNINITIALIZED
    variable options
    variable libdir_
}

proc ::server::start { libdir } {
    variable libdir_
    set libdir_ $libdir
    ::connection::connect ::server::handle
}

proc ::server::handle { msg } {
    set type [dict get $msg type]
    switch -exact -- $type {
        "request" {
            set p "OnRequest_[dict get $msg command]"
            if { $p ni [info procs] } {
                puts stderr "WARNING: Rejecting unhandled request: $type"
                ::connection::reject \
                    $msg \
                    "Unrecognised request: [dict get $msg command]"
            } else {
                $p $msg
            }
        }

        "response" {
            error "Did not expect to handle a response here"
        }

        "event" {
            set p "OnEvent_[dict get $msg event]"

            if { $p ni [info procs] } {
                puts stderr "WARNING: Ignoring unhandled event: $type"
            } else {
                $p $msg
            }
        }

        default {
            error "Unhandled message type: $type"
        }
    }
}

proc ::get { d def args } {
    if { [dict exists $d {*}$args ] } {
        return [dict get $d {*}$args]
    }
    return $def
}


proc ::server::OnRequest_initialize { msg } {
    variable state
    variable options
    variable libdir_

    if { $state ne "UNINITIALIZED" } {
        ::connection::reject $msg\
                             "Invalid event 'initialize' in state $state"
        return
    }

    set args [dict get $msg arguments]

    if { [dict get $args adapterID] ne "tclpro" } {
        ::connection::reject $msg \
                             "Initialize was not meant for the 'tclpro' adapter"
        return
    }

    foreach option { linesStartAt1
                     columnsStartAt1
                     pathFormat
                     supportsRunInterminalRequest } {
        if { [dict exists $args $option] } {
            set options($option) [dict get $args $option]
        }
    }

    dbg::register linebreak  {::server::linebreakHandler}
    dbg::register varbreak   {::server::varbreakHandler}
    dbg::register userbreak  {::server::userbreakHandler}
    dbg::register cmdresult  {::server::cmdresultHandler}
    dbg::register exit       {::server::exitHandler}
    dbg::register error      {::server::errorHandler}
    dbg::register result     {::server::resultHandler}
    dbg::register attach     {::server::attachHandler}
    dbg::register instrument {::server::instrumentHandler}

    # Register the error handler for errors during instrumentation.

    set instrument::errorHandler debugger::instrumentErrorHandler

    # Initialize the debugger.

    dbg::initialize $libdir_

    if { "-debug" in $::argv } {
        set ::dbg::debug 1
    }


    # read client capabilities/options

    if { ![dbg::setServerPort random] } {
        ::connection::reject $msg \
                             "Unable to allocate port for server"
        return
    }

    set options(linesStartAt1) 1
    set options(columnsStartAt1) 1
    set options(pathFormat) path
    set options(supportsRunInterminalRequest) 0

    set state CONFIGURING
    ::connection::respond $msg [json::write object \
        supportsConfigurationDoneRequest true     \
    ]

    # We don't have anything more to do here. We will initialize the debugging
    # connection later on the laucnh request, so we just send the initialized
    # notification now
    ::connection::notify initialized
}

proc ::server::OnRequest_setBreakpoints { msg } {
    variable state

    if { $state ne "CONFIGURING" } {
        ::connection::reject $msg \
                             "Invalid event 'setBreakpoints' in state $state"
        return
    }

    # TODO
    ::connection::respond $msg [json::write object \
        breakpoints [json::write array]            \
    ]
}

proc ::server::OnRequest_setFunctionBreakpoints { msg } {
    variable state

    if { $state ne "CONFIGURING" } {
        ::connection::reject $msg \
                             "Invalid event 'setFunctionBreakpoints' in state\
                              $state"
        return
    }

    # TODO
    ::connection::respond $msg [json::write object \
        breakpoints [json::write array]            \
    ]
}

proc ::server::OnRequest_configurationDone { msg } {
    # not sure we really care, but hey-ho
    variable state
    set state CONFIGURED

    ::connection::accept $msg
}

proc ::server::OnRequest_launch { msg } {
    variable state
    if { $state ne "CONFIGURED" } {
        ::connection::reject $msg \
                             "Invalid event 'launch' in state $state"
        return
    }

    set args [dict get $msg arguments]
    set ::launch_request $msg
    dbg::start [dict get $args tclsh] \
               [dict get $args cwd] \
               [dict get $args target] \
               [dict get $args args] \
               $msg
}

proc ::server::OnRequest_threads { msg } {
    variable state
    if { $state ne "DEBUGGING" } {
        ::connection::reject $msg \
                             "Invalid event 'threads' in state $state"
        return
    }

    ::connection::respond $msg [json::write object     \
        threads [json::write array [json::write object \
            id    1                                    \
            name [json::write string "Main"]           \
        ] ]                                            \
    ]
}

proc ::server::_LSPLine { tclProLine } {
    variable options
    if { $options(linesStartAt1) } {
        return [expr { $tclProLine + 1 }]
    }
    return $tclProLine
}

proc ::server::_LSPCol { tclProCol } {
    variable options
    if { $options(columnsStartAt1) } {
        return [expr { $tclProCol + 1 }]
    }
    return $tclProCol
}

proc ::server::_TCLProLine { lspLine } {
    variable options
    if { $options(linesStartAt1) } {
        return [expr { $lspLine - 1 }]
    }
    return $lspLine
}

proc ::server::_TCLProCol { lspCol } {
    variable options
    if { $options(columnsStartAt1) } {
        return [expr { $lspCol - 1 }]
    }
    return $lspCol    
}

proc ::server::_LSPPath { tclProPath } {
    return $tclProPath
}

proc ::server::OnRequest_stackTrace { msg } {
    variable state
    if { $state ne "DEBUGGING" } {
        ::connection::reject $msg \
                             "Invalid event 'stackTrace' in state $state"
        return
    }

    set args [dict get $msg arguments]

    if { [dict get $args threadId] != 1 } {
        ::connection::reject $msg \
                             "Invalid threadId, must be 1"
        return
    }

    # TODO:
    #  - startFrame
    #  - levels
    #  - format
    
    set stack [list]
    
    catch { set stack [dbg::getStack] } 

    set frames [list]

    foreach tcl_frame $stack {
        lassign [lrange $tcl_frame 0 2] level loc type
        set args [lrange $tcl_frame 3 end]

        ::dbg::Log message {frame: $tcl_frame}
        ::dbg::Log message {level/loc/type/args: $level $loc $type $args}

        switch -exact -- $type {
            "global" {
                set name $type
            }
            "proc" {
                set name "proc [lindex $args 0]"
            }
            "source" {
                set name "source script"
            }
        }

        if { $loc == {} } {
            # we don't know the source yet ?
            lappend frames [json::write object    \
                id     $level                     \
                name   [json::write string $name] \
                line    0 \
                column  0 \
            ]
        } else {
            set blk   [loc::getBlock $loc]
            set line  [loc::getLine $loc]
            set range [loc::getRange $loc]

            set file  [blk::getFile $blk]
            set ver   [blk::getVersion $blk]
            set src   [blk::getSource $blk] ;# FIXME catch errors

            if { $line == {} } {
                set cmdStart [dict create line 0 col 0]
                # FIXME TclPro codeWin uses the end of file
                # set cmdEnd   [line 0 col 0] 
            } elseif { $range == {} } {
                set cmdStart [dict create line $line col 0]
                # set cmdEnd [line $line col -1]
            } else {
                set start [parse charindex $src $range]
                set textToStart [string range $src 0 $start]
                set lines [split $textToStart \n]
                set cmdStart [dict create \
                    line [expr { [llength $lines] - 1 }] \
                    col [expr { [string length [lindex $lines end]] - 1 }] \
                ]
            }

            lappend frames [json::write object                  \
                id     $level                                   \
                name   [json::write string $name]               \
                source [json::write object                      \
                    name [json::write string [file tail $file]] \
                    path [json::write string [_LSPPath $file]]  \
                ]                                               \
                line   [_LSPLine [dict get $cmdStart line]]     \
                column [_LSPCol  [dict get $cmdStart col]]      \
            ]
        }
    }

    ::connection::respond $msg [json::write object \
        stackFrames [json::write array {*}$frames] \
    ]
}

proc ::server::OnRequest_disconnect { msg } {
    variable state
    if { $state eq "DEBUGGING" } {
        catch { dbg::quit }
    }

    # TODO restart ? terminateDebuggee ?

    ::connection::accept $msg

    set ::APP_STATE ended
}

proc ::server::OnRequest_pause { msg } {
    dbg::interrupt
}

proc ::server::linebreakHandler { args } {
    puts stderr "Line break: $args"

    ::connection::notify stopped [json::write object  \
        reason      [json::write string "breakpoint"] \
        description [json::write string "Line break"] \
        threadId    1
    ]
}

proc ::server::varbreakHandler { args } {
    puts stderr "Var break: $args"

    ::connection::notify stopped [json::write object  \
        reason      [json::write string "breakpoint"] \
        description [json::write string "Var break"] \
        threadId    1
    ]
}

proc ::server::userbreakHandler { args } {
    puts stderr "User break: $args"

    ::connection::notify stopped [json::write object  \
        reason      [json::write string "breakpoint"] \
        description [json::write string "User break"] \
        threadId    1
    ]
}

proc ::server::cmdresultHandler { args } {
    puts stderr "Command result: $args"
}

proc ::server::exitHandler { args } {
    puts stderr "Exit: $args"
}

proc ::server::errorHandler { args } {
    puts stderr "Error: $args"
}

proc ::server::resultHandler { args } {
    puts stderr "REsult: $args"
}

proc ::server::attachHandler { request } {
    variable state
    set state DEBUGGING
    puts stderr "The debugger attached!"
    if { [::get $request true arguments pauseOnEntry] == "true" } {
        dbg::step any
    } else {
        dbg::step run
    }
    ::connection::accept $request
}

proc ::server::instrumentHandler { status block } {
    puts stderr "Instrumenting: $status ($block)"
}

