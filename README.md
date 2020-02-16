The TclPro Debugger version 3.0 is an upgrade of of the debugger included in the
TclPro product version 1.5 released and open-sourced by Scriptics Corporation.

Notably, this fork of TclProDebug provides a [Debug Adapter Protocol](https://microsoft.github.io/debug-adapter-protocol/)
implementation allowing it to be used by any client implementing that protocol,
including: 

- [Vimspector](https://github.com/puremourning/vimspector)
- Visual Studio Code

Note: It's only tested with Vimspector.

## Install

To install: You will need to install the extension in lib/tclparser to add the
parse command to Tcl.

    cd lib/tclparser && autoreconf && ./configure && make install

## Debug Adapter

To use the debug adapter with vimspector, use the following example
`.vimspector.json`:

```json
{
    "adapters": {
        "tclpro": {
            "name": "tclpro",
            "command": [
                "$HOME/path/to/TclProDebug/bin/debugadapter"
            ]
        }
    },
    "configurations": {
        "launch": {
            "adapter": "tclpro",
            "configuration": {
                "request": "launch",
                "tclsh": "/usr/bin/wish",
                "cwd": "${workspaceRoot}",
                "target": "${workspaceRoot}/main.tcl",
                "args": [ "this", "is", "a", "test" ]
            }
        }
    }
}
```

Notes:

* Debug adapter is highly experimental and probably very very buggy.
* Debugger breaks on `error`. Use "Step Out" command to suppress an error when
  it is trapped by the debugger. Then use "Step Over" or "Step In" to continue.
  To deliver the error, just use "Stop Over" or "Step In" and the application
  will terminate.
* pass `-debug` to `debugserver` to trace a lot of spam to `stderr`
* only stdout/stdin DAP supported (no sockets)
* `attach` request not supported
* `tclsh` may be a tclsh or a wish (or possibly an `expect`)
* `target` is the script to launch
* `cwd` is the working directory to launch the script in
* `args` is list of command line arguments
* All launch options are mandatory but `args` may be an empty list.

## GUI

To run the standalone GUI: execute the file bin/prodebug

The Help menu item on the Debugger's menu bar has an option to open the TclPro
user's guide, which will appear as a PDF file in the user's default browser.
The information in the chapter on the Debugger is still valid.

## Changes since TclPro

The debugger code has been upgraded to function with up-to-date releases of 
Tcl/Tk (i.e., versions 8.5, 8.6):


* Tk GUI code upgraded to work with current Tk API.

* Upgraded OS interaction code to work with current operating system releases.

* Instrumentation code added to accomodate the expand operator.

* Code added for proper custom instrumentation of new Tcl commands (e.g. apply,
dict, try) and subcommands.

* Put remote-debugging client code file into package for ease of access.

* Cleanup and correction of doc files.

* Files and directories re-arranged into starkit-ready format.

* Added script to wrap debugger code into a starkit of minimum size.

* Miscellaneous bug fixes.
