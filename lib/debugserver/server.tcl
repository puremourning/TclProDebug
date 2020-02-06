package require parser

#
# Specification
#
# Launch:
#   tclsh  (string) path to tclsh to launch the script with
#   cwd    (string) path of working directory of script
#   target (string) path to the script to run
#   args   (list)   arguments to 'target'
#
# Attach:
#   host (string) IPv4 hostname (e.g. localhost)
#   port (int)    IPv4 port     (e.g. 2345, as supplied to remote_debug_wrapper)
#
# Both:
#   tolocal (list of mappings): defines regsubs which map remote file names to
#   local filenames when remote debugging 
#     keys: the keys are regular expression matches 
#     values: regular expression replacement strings
#        (as in [regsub $key $filename $value])
#
#   pauseOnEntry (string: true or false) whether to stop after connecting the
#                                        debugger
#   extensionDirs (list): List of glob patterns to find *.pdx files to source

namespace eval ::server {

    variable state UNINITIALIZED
    variable options
    variable launchConfig
    variable libdir_
    variable handlingError 0
    variable eval_requests [list]
    variable evaluating [list]

    variable onNewState
}

proc ::server::start { libdir } {
    variable libdir_
    set libdir_ $libdir
    set ::dbg::fileMapper ::server::mapFileName
    ::connection::connect ::server::handle
}

proc ::server::output { category msg args } {
    ::connection::notify output [json::write object \
        category [json::write string $category]     \
        output   [json::write string $msg]          \
        {*}$args
    ]
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

    set instrument::errorHandler ::server::instrumentErrorHandler

    # Initialize the debugger.

    dbg::initialize $libdir_

    if { "-verbose" in $::argv } {
        set ::dbg::debug 1
    } else {
        set ::dbg::debug 0
    }

    # read client capabilities/options

    if { ![dbg::setServerPort random] } {
        ::connection::reject $msg \
                             "Unable to allocate port for server"
        return
    }

    # FIXME : We just ignore what the client sends us ?
    set options(linesStartAt1) 1
    set options(columnsStartAt1) 1
    set options(pathFormat) path
    set options(supportsRunInterminalRequest) 1

    setState CONFIGURING
    ::connection::respond $msg [json::write object \
        supportsConfigurationDoneRequest true     \
    ]

    if { $options(supportsRunInterminalRequest) } {
        set ::dbg::appLaunchDelegate ::server::runInTerminal
    }

    # We don't have anything more to do here. We will initialize the debugging
    # connection later on the launch request, so we just send the initialized
    # notification now
    ::connection::notify initialized

    dbg::Log info {Initialized debug adapter}
}

proc ::server::OnRequest_setBreakpoints { msg } {
    variable state

    dbg::Log info {setBreakpoints request in $state}

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

    dbg::Log info {setFunctionBreakpoints request in $state}

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

    dbg::Log info {configurationDone request in $state}

    setState CONFIGURED

    ::connection::accept $msg
}

proc ::server::_DoLaunch { msg } {
    dbg::Log info {launch!}

    variable launchConfig
    set launchConfig [dict get $msg arguments]

    ::server::loadExtensions $launchConfig

    dbg::start [dict get $launchConfig tclsh] \
               [dict get $launchConfig cwd] \
               [dict get $launchConfig target] \
               [dict get $launchConfig args] \
               $msg
}

proc ::server::_DoAttach { msg } {
    dbg::Log info {attach!}

    variable attachRequest
    variable launchConfig
    set attachRequest $msg
    set launchConfig [dict get $msg arguments]

    ::server::loadExtensions $launchConfig

    dbg::attach_remote [dict get $launchConfig host] \
                       [dict get $launchConfig port]
}

proc ::server::loadExtensions { launchConfig } {
    if { [dict exists $launchConfig extensionDirs] } {
        set files [list]
        foreach dir [dict get $launchConfig extensionDirs] {
            set files [concat $files [glob -nocomplain [file join $dir *.pdx]]]
        }

        foreach file $files {
            dbg::Log message {Loading extension $file}
            if {[catch {uplevel \#0 [list source $file]} err]} {
                bgerror "Error loading $file:\n$err"
            }
        }
    } 
}

proc ::server::OnRequest_launch { msg } {
    variable state
    variable onNewState
    dbg::Log info {launch request in $state}
    if { $state eq "CONFIGURING" } {
        # Wait until we have all the configuration before launching
        dbg::Log info {delaying launch request in $state until CONFIGURED}
        runOnState CONFIGURED [list ::server::OnRequest_launch $msg]
        return
    } elseif { $state ne "CONFIGURED" } {
        ::connection::reject $msg \
                             "Invalid event 'launch' in state $state"
        return
    }

    _DoLaunch $msg
}

proc ::server::OnRequest_attach { msg } {
    variable state
    dbg::Log info {attach request in $state}
    if { $state eq "CONFIGURING" } {
        # Wait until we have all the configuration before launching
        dbg::Log info {delaying attach request in $state}
        runOnState CONFIGURED [list ::server::OnRequest_attach $msg]
        return
    } elseif { $state ne "CONFIGURED" } {
        ::connection::reject $msg \
                             "Invalid event 'launch' in state $state"
        return
    }

    _DoAttach $msg
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
    
    catch { set stack [lreverse [dbg::getStack]] } 

    set frames [list]


    for { set index 0 } { $index < [llength $stack] } { incr index } {
        set tcl_frame [lindex $stack $index]
        lassign [lrange $tcl_frame 0 2] level loc type
        set args [lrange $tcl_frame 3 end]

        ::dbg::Log message {frame: $tcl_frame ($index);}
        ::dbg::Log message {level/loc/type/args: $level $loc $type $args}

        set name ""
        for { set i 0 } { $i < $level } { incr i } {
            append name " "
        }
        append name " #$level: "

        switch -exact -- $type {
            "proc" {
                # Args: procName procArg0 ... procArgN
                append name "$type [lindex $args 0]"
            }
            "source" {
                # this is actually usually a global command
                append name "::"
            }
            "uplevel" {
                # don't put a name
            }
            "global" {
                # skp this one, it's probably the command line ? not sure
                append name "::"
            }
            default {
                append name $type
            }
        }

        if { $loc == {} } {
            # we don't know the source yet ?
            lappend frames [json::write object    \
                id     $index                     \
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
    catch { set stack [lreverse [dbg::getStack]] } 

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
            "proc" {
                set name "proc [lindex $args 0]"
            }
            "source" {
                set name "source [lindex $args 0]"
            }
            "uplevel" {
                continue
            }
            default {
                set name $type
            }
        }

        # The scopes are the TCL levels #0, #1... etc.
        # The maximum TCL level we report is the _current_ level
        # The name we give each scope is the lowest frame for that #level in the
        # context stack. For example a trace with uplevels like (latest call at
        # the top):
        #
        # 0   #1 proc XYZ
        # 1  #0 source F2
        # 2   #1 proc ABC
        # 3    #2 proc DEF
        # 4   #1 proc GHI
        # 5  #0 source F1
        # 6  #0 global
        #
        # With current frame 0:
        #  The scopes are: #0, #1 (#2 is lower than current scope #1)
        #  The names are:
        #    #1: proc XYZ
        #    #0: source F2
        #
        # With current frame 3:
        #  The scopes are: #0, #1, #2
        #  The names are:
        #    #2: proc DEF
        #    #1: proc GHI
        #    #0: source F1
        #
        if { $level <= $max_level } {
            if { ![info exists seen_levels($level)] } {
                set seen_levels($level) $name
            }
        }

    }
    foreach level [lsort -decreasing [array names seen_levels]] {
        lappend scopes [json::write object                             \
            name  [json::write string "#$level: $seen_levels($level)"] \
            variablesReference  [expr { $level + 1 }]                  \
            expensive true                                             \
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
    catch { set stack [lreverse [dbg::getStack]] } 

    # level loc type args...
    set level [lindex [lindex $stack $index] 0]

    set evaluating [list [::dbg::evaluate $level $expression] $msg]
}

proc ::server::OnRequest_disconnect { msg } {
    if { [catch { dbg::quit } output] } {
        # TODO: If we never started the app, the dbg::quit won't work.
        ::dbg::Log error {dbg::quit failed $output $::errorInfo}
        ::connection::notify terminated [json::write object]
    }

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
    dbg::step any

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

proc ::server::resultHandler { id code result errCode errInfo } {
    variable eval_requests
    variable evaluating

    if { [llength $evaluating] ==  0 || [lindex $evaluating 0] ne $id } {
        ::dbg::Log error {Unexpected response to request with id $id ($result)}
    } else {
        set msg [lindex $evaluating 1]
        set evaluating [list]
        ::connection::respond $msg [json::write object \
            result [::json::write string $result]      \
            variablesReference 0                       \
        ]
    }

    if { [llength $eval_requests] > 0 } {
        set msg [lindex $eval_requests 0]
        set eval_requests [lrange $eval_requests 1 end]

        ::server::_DoEvaluate $msg
    }
}

proc ::server::attachHandler { request } {
    variable state
    variable attachRequest
    setState DEBUGGING
    puts stderr "The debugger attached!"

    if { $request == "REMOTE" } {
        set request $attachRequest
    } 

    if { [::get $request true arguments pauseOnEntry] == "true" } {
        dbg::step any
    } else {
        dbg::step run
    }
    ::connection::accept $request
}

proc ::server::instrumentHandler { status block } {
    ::server::output console "Instrument $status for [blk::getFile $block]"
}

proc ::server::runOnState { newState script } {
    variable onNewState
    if { ![info exists onNewState($newState)] } {
        set onNewState($newState) [list]
    }

    lappend onNewState($newState) $script
}

proc ::server::setState { newState } {
    variable state
    variable onNewState

    set state $newState
    
    if { [info exists onNewState($newState)] } {
        while { [llength $onNewState($newState)] } {
            set script [lindex $onNewState($newState) 0]
            set onNewState($newState) [lrange $onNewState($newState) 1 end]
            eval $script
        }
        unset onNewState($newState)
    }
}

proc ::server::mapFileName { direction fileName } {
    variable launchConfig
    if { [dict exists $launchConfig $direction] } {
        foreach mapping [dict get $launchConfig $direction] {
            dict for {pattern replacement} $mapping  {
                if { [regsub $pattern $fileName $replacement mapped] > 0 } {
                    return $mapped
                }
            }
        }
    }
    return $fileName
}

proc ::server::bgerror { msg } {
    ::server::output console $msg
}

proc ::server::errorHandler { errMsg errStk errCode uncaught } {
    variable handlingError
    incr handlingError
    ::connection::notify stopped [json::write object  \
        reason      [json::write string "exception"] \
        description [json::write string "Error: $errMsg"] \
        threadId    1
    ]
    ::server::output console "Uncaught error: $errMsg"
    ::server::output console "  - errCode: $errCode"
    ::server::output console "  - errStk: $errStk"
    ::server::output console "  - uncaught: $uncaught"
    ::server::output console "  - Issue 'step out' to ignore"

}

proc ::server::instrumentErrorHandler {loc} {
    # See lib/tclgebugger/gui.tcl : instrumentErrorHandler

    set errorMsg [lindex $::errorCode end]

    ::dbg::Log error {Instrumentation errorCode: $::errorCode}

    ::server::output console "Instrument ERROR:\
                            \n$errorMsg\
                          \n\nInstrumentation may be incomplete."

    # TODO: We could actually throw a breakpoint here, vwait and intercept the
    # continue call, but let's not.

    # Ignore the error
    return 1
}

proc ::server::handleRunInterminalResponse { tempFile msg } {
    ::dbg::Log info {RunInternalResponse $msg}
}

proc ::server::runInTerminal { command stdin } {
    # When running in a terminal via the client, we can't write directly to the
    # standard input, so instead we write a wrapper
    set tempFile [exec mktemp]
    set f [open $tempFile w]
    puts $f "exec $command << {$stdin} >@stdout 2>@stderr"
    puts $f "file delete $tempFile"
    puts $f $stdin
    close $f

    set pipe [list [info nameofexecutable] $tempFile]

    set args [list]
    foreach arg $pipe {
        lappend args [json::write string $arg]
    }

    ::connection::request                                                  \
        runInTerminal                                                      \
        [list ::server::handleRunInterminalResponse $tempFile]             \
        [json::write object kind  [json::write string "integrated"]        \
                            title [json::write string [lindex $command 0]] \
                            cwd   [json::write string [pwd]]               \
                            args  [json::write array {*}$args]]
     
}
