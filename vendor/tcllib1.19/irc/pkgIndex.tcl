# pkgIndex.tcl                                                    -*- tcl -*-
# $Id$
if { ![package vsatisfies [package provide Tcl] 8.3] } {
    # PRAGMA: returnok
    return 
}
package ifneeded irc     0.6.2 [list source [file join $dir irc.tcl]]
package ifneeded picoirc 0.5.2 [list source [file join $dir picoirc.tcl]]
