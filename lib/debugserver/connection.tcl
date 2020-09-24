# connection.tcl
# 
# Copyright (c) Fidessa Plc. 2019
# 

package require json
package require json::write

namespace eval ::connection {
    # READ_HEADER, READ_BODY
    variable readState_ READ_HEADER

    # current input_ buffer
    variable input_

    # current headers_
    variable headers_

    # message handler
    variable handler_

    # last sequence number we sent
    variable lastSequenceNumber_ 0
}

proc ::connection::connect { handler } {
    variable readState_
    variable handler_
    variable lastSequenceNumber_

    set handler_ $handler

    set readState_ READ_HEADER

    # TODO: perhaps we should actually use -translation crlf? 
    # TODO: perhaps we should use -encoding utf-8 ?
    fconfigure stdin -blocking 0 -translation binary -buffering none
    fconfigure stdout -blocking 0 -translation binary -buffering none
    # we want the logging (which goes to stderr) to write sync for debugging
    # purposes
    fconfigure stderr -blocking 1 -translation auto -buffering none

    fileevent stdin readable ::connection::_read

    set lastSequenceNumber_ 0
}

proc ::connection::request { request handler { arguments "" } } {
    variable lastSequenceNumber_
    variable pendingRequests_

    set seqNo [incr lastSequenceNumber_]
    set pendingRequests_($seqNo) $handler

    set msg [list seq     $seqNo \
                  type    [json::write string "request"] \
                  command [json::write string $request]]

    if { $arguments ne "" } {
        lappend msg arguments $arguments
    }

    set msg [json::write object {*}$msg]
    _write $msg
}

proc ::connection::notify { event {body ""} } {
    variable lastSequenceNumber_

    set msg [list seq     [incr lastSequenceNumber_] \
                  type    [json::write string "event"] \
                  event   [json::write string $event]]

    if { $body ne "" } {
        lappend msg body $body
    }

    set msg [json::write object {*}$msg]
    _write $msg
}

proc ::connection::_respond { request error_message { body_or_error ""} } {
    variable lastSequenceNumber_

    set msg [list seq     [incr lastSequenceNumber_] \
                  type    [json::write string "response"] \
                  command [json::write string [dict get $request command]] \
                  request_seq [dict get $request seq]]

    if { $error_message eq "" } {
        lappend msg success true

        if { $body_or_error ne "" } {
            lappend msg body $body_or_error
        }
    } else {
        lappend msg success false \
                    message [json::write string $error_message]

        if { $body_or_error ne "" } {
            lappend msg error $body_or_error
        }
    }

    set msg [json::write object {*}$msg]

    _write $msg
}

proc ::connection::reject { request reason } {
    _respond $request $reason
}

proc ::connection::accept { request } {
    _respond $request ""
}

proc ::connection::respond { request body } {
    _respond $request "" $body
}

proc ::connection::_read { } {
    set data [read stdin]

    if { [eof stdin] } {
        ::dbg::Log info "The input channel was closed."
        set ::APP_STATE dead
        return
    }

    variable readState_
    variable input_
    variable headers_

    append input_ $data

    while { 1 } {
        if { $readState_ eq "READ_HEADER" } {
            _read_headers
        }

        if { $readState_ eq "READ_BODY" } {
            _read_body
        } else {
            break
        }

        if { $readState_ != "READ_HEADER" } {
            # We ran out of data waiting for a full message. Await more data.
            break
        }
        # Otherwise there are more headers_ in the input_ buffer, so loop round.
    }
}

proc ::connection::_read_headers { } {
    variable input_
    variable headers_
    variable readState_

    # TODO/FIXME: encoding. The input_ encoding must be utf-8
    set endOfHeaders [string first "\r\n\r\n" $input_]

    if { $endOfHeaders < 0 } {
        # We haven't received all of the headers yet. Wait for more data.
        return 
    } 

    set headers [string range $input_ 0 $endOfHeaders]
    set headers_ ""
    foreach header_line [split $headers "\r\n"] {
        if { [string trim $header_line] ne "" } {
            lassign [split $header_line :] key value
            dict set headers_ $key [string trim $value]
        }
    }
    # +4 is due to the \r\n\r\n
    set input_ [string range $input_ [expr { $endOfHeaders + 4 }] end]
    set readState_ READ_BODY
}

proc ::connection::_read_body { } {
    # TODO: Catch errors in this loop or do something with bderror
    variable headers_ 
    variable input_
    variable readState_
    variable pendingRequests_
    variable handler_

    set contentLength [dict get $headers_ Content-Length]

    if { [string length $input_] < $contentLength } {
        # need more data
        return 
    }

    set payload [string range $input_ 0 $contentLength]
    set input_ [string range $input_ $contentLength end]

    # TODO: Not sure this is exactly how we need to deal with encodings, as TCL
    # will do its own converstions (tcl strings are utf-16, and the read procs
    # use string operaitons, but the data is really in utf-8, with bytes)
    set msg [json::json2dict [encoding convertfrom utf-8 $payload]]

    ::dbg::Log DAP {RX: $msg}

    if { [catch {
        if { [dict get $msg type] == "response" } {
            set seqNo [dict get $msg request_seq]
            eval $pendingRequests_($seqNo) {$msg}
            unset pendingRequests_($seqNo)
        } else {
            $handler_ $msg
        }
    } err] } {
        ::dbg::Log error "Exception handling message: $::errorInfo"
    }

    set readState_ "READ_HEADER"
}

proc ::connection::_write { msg } {
    ::dbg::Log DAP {TX: $msg}
    puts -nonewline stdout "Content-Length: [string length $msg]\r\n"
    puts -nonewline stdout "\r\n"
    puts -nonewline stdout "$msg\r\n"
}


