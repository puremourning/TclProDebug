package require parser

namespace eval ::server {

    variable state UNINITIALIZED
    variable options
    variable libdir_
    variable handlingError 0
    variable eval_requests [list]
    variable evaluating [list]
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
                if { [catch {$p $msg} err] } {
                    ::dbg::Log error {Exception handling request $msg:\
                        $::errorInfo}
                    ::connection::reject $msg $err
                }
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

    if { $state ne "CONFIGURING" && $state ne "DEBUGGING" } {
        ::connection::reject $msg \
                             "Invalid event 'setBreakpoints' in state $state"
        return
    }

    set file [dict get $msg arguments source path]
    set block [blk::makeBlock $file]

    foreach bp [dbg::getLineBreakpoints] {
        set bpFile [blk::getFile [loc::getBlock [break::getLocation $bp]]]
        ::dbg::Log debug {Checking bp '$bp' against $file vs $bpFile}
        if { $bpFile  == $file } {
            ::dbg::Log debug {Remove $bp}
            dbg::removeBreakpoint $bp
        }
    } 

    if { [dict exists $msg arguments breakpoints] } {
        foreach breakpoint [dict get $msg arguments breakpoints] {
            set line [dict get $breakpoint line]
            set location [loc::makeLocation $block $line]
            ::dbg::Log debug {Adding bp at $file:$line: $location}
            dbg::addLineBreakpoint $location
        }
    }

    set breakpoints [list]
    foreach bp [dbg::getLineBreakpoints] {
        set loc [break::getLocation $bp]
        set block [loc::getBlock $loc]
        ::dbg::Log debug {Checking return bp $bp against $file vs [blk::getFile $block]}
        if { [blk::getFile $block] == $file } {
            ::dbg::Log debug {Returning bp $bp}
            lappend breakpoints [json::write object                            \
                verified true                                                  \
                source [json::write object                                     \
                    name [json::write string [file tail [blk::getFile $block]]]\
                    path [json::write string [blk::getFile $block]]            \
                ]                                                              \
                line [loc::getLine $loc]                                       \
            ]
        }
    }

    ::connection::respond $msg [json::write object      \
        breakpoints [json::write array {*}$breakpoints] \
    ]
}

proc ::server::OnRequest_setFunctionBreakpoints { msg } {
    variable state

    if { $state ne "CONFIGURING" && $state ne "DEBUGGING" } {
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


    for { set index 0 } { $index < [llength $stack] } { incr index } {
        set tcl_frame [lindex $stack $index]
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
                set name "source"
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
                id     $index                                   \
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

proc ::server::OnRequest_scopes { msg } {
    variable state
    if { $state ne "DEBUGGING" } {
        ::connection::reject $msg \
                             "Invalid event 'scopes' in state $state"
        return
    }

    set index [dict get $msg arguments frameId]

    set scopes [list]
    catch { set stack [dbg::getStack] } 

    set max_level -1
    set tcl_frame [lindex $stack $index]
    if { $tcl_frame != {} } {
        # level loc type args...
        set max_level [lindex $tcl_frame 0]
    }

    array set seen_levels [list]
    for { set index 0 } { $index < [llength $stack] } { incr index } {
        set tcl_frame [lindex $stack $index]
        lassign [lrange $tcl_frame 0 2] level loc type
        set args [lrange $tcl_frame 3 end]

        switch -exact -- $type {
            "global" {
                set name $type
            }
            "proc" {
                set name "proc [lindex $args 0]"
            }
            "source" {
                set name "source"
            }
        }

        if { $level <= $max_level } {
            if { [info exists seen_levels($level)] } {
                lappend seen_levels($level) $name
            } else {
                set seen_levels($level) [list $name]
            }
        }

    }
    foreach level [lsort [array names seen_levels]] {
        lappend scopes [json::write object                           \
            name  [json::write string [join $seen_levels($level) ,]] \
            variablesReference  [expr { $level + 1 }]                \
            expensive false                                          \
        ]
    }

    ::connection::respond $msg [json::write object \
        scopes [json::write array {*}$scopes] \
    ]
}

proc ::server::OnRequest_variables { msg } {
    variable state
    if { $state ne "DEBUGGING" } {
        ::connection::reject $msg \
                             "Invalid event 'scopes' in state $state"
        return
    }

    set level [expr { [dict get $msg arguments variablesReference] - 1 }]

    set variables [list]
    set varList [dbg::getVariables $level]
    dbg::Log message {Var list: $varList}
    set varNames [list]
    foreach var $varList {
        lappend varNames [lindex $var 0]
    }
    set vars [dbg::getVar $level 20 $varNames]
    dbg::Log message {Vars: $vars}


    array set TYPES {a Array s Scalar n Unknown}

    foreach tcl_var $vars {
        lassign $tcl_var name type value
        # TODO: We should make arrays expandable. The "value" here would be a
        # list of name/value pairs. We might be able to interpret lists and
        # dicts but i think the only type info we get is:
        #  s - scalar
        #  n - ???
        #  a - array
        #
        # TODO: if the value is truncated, make it expandable ?
        lappend variables [json::write object \
            name [json::write string $name]   \
            value [json::write string $value] \
            type [json::write string $TYPES($type)]    \
            variablesReference 0              \
        ]
    }

    ::connection::respond $msg [json::write object \
        variables [json::write array {*}$variables] \
    ]
}

proc ::server::OnRequest_evaluate { msg } {

    variable eval_requests
    variable evaluating

    if { [llength $evaluating] == 0 } {
        ::server::_DoEvaluate $msg
    } else {
        lappend eval_requests $msg
    }
}

proc ::server::_DoEvaluate { msg } {
    variable evaluating

    if { [catch {set index [dict get $msg arguments frameId]} err] } {
        set index 0
    }

    set expression [dict get $msg arguments expression]
    set context "watch"
    catch { set context [dict get $msg arguments context] }
    if { $context == "hover" } {
        set expression "set $expression"
    }

    set stack [list]
    catch { set stack [dbg::getStack] } 

    # level loc type args...
    set level [lindex [lindex $stack $index] 0]

    variable eval_requests
    set eval_requests([::dbg::evaluate $level $expression]) $msg
}

proc ::server::OnRequest_disconnect { msg } {
    catch { dbg::quit }

    # TODO restart ? terminateDebuggee ?

    ::connection::accept $msg

    set ::APP_STATE ended
}

proc ::server::OnRequest_pause { msg } {
    dbg::interrupt

    ::connection::accept $msg
}

proc ::server::OnRequest_continue { msg } {
    dbg::run

    ::connection::accept $msg
}

proc ::server::OnRequest_next { msg } {
    dbg::step over

    ::connection::accept $msg
}

proc ::server::OnRequest_stepIn { msg } {
    dbg::step in

    ::connection::accept $msg
}

proc ::server::OnRequest_stepOut { msg } {
    variable handlingError

    if { $handlingError > 0 } {
        dbg::ignoreError
        incr handlingError -1
    } else {
        dbg::step out
    }

    ::connection::accept $msg
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

    #TODO: We don't get the exitCode from the debugger ?
    ::connection::notify exited [json::write object \
        exitCode 0                                  \
    ]
    ::connection::notify terminated [json::write object]
}

proc ::server::errorHandler { errMsg errStk errCode uncaught } {
    variable handlingError
    incr handlingError
    ::connection::notify stopped [json::write object  \
        reason      [json::write string "exception"] \
        description [json::write string "Error: $errMsg"] \
        threadId    1
    ]
}

proc ::server::resultHandler { id code result errCode errInfo } {
    variable eval_requests
    if { [info exists eval_requests($id)] } {
        set msg $eval_requests($id)
        unset eval_requests($id)
        ::connection::respond $msg [json::write object \
            result [::json::write string $result]      \
            variablesReference 0                       \
        ]
    } else {
        ::dbg::Log error {Unexpected response to request with id $id ($result)}
    }
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

