namespace eval debugserver {
    variable contents {
        connection.tcl
        server.tcl
    }
    
    proc Load { dir } {
        package provide debugserver 1.0

        variable contents
        foreach file $contents {
            source [file join $dir $file]
        }
    }
}
package ifneeded debugserver 1.0 [list debugserver::Load $dir]
