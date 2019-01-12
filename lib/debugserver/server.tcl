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
    ::connection::accept $msg [json::write object \
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

proc ::server::linebreakHandler { args } {
    puts stderr "Line break: $args"
}

proc ::server::varbreakHandler { args } {
    puts stderr "Var break: $args"
}

proc ::server::userbreakHandler { args } {
    puts stderr "User break: $args"
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

