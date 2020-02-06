# Visual Studio Code Exetension

This directory contains the necessary stuff to build a Visual Studio Code TCL
debugger extension on Linux/macOS.

Doesn't support windows, but PRs are welcome.

## Installation - User

1. Build the `tclparser` as normal

```
cd /path/to/TclProDebug/lib/tclparser
./configure
make`
```

1. change to this directory `cd /path/to/TclProDebug/vscode`
2. `./make_extension 0.1.0`. This will build the extension in `extensions/` as
   both a full directory and a tarball.
3. extract into your extension directory (you can also symlink)
    1. `cd $HOME/.vscode/extensions`
    2. `ln -s /path/to/TclProDebug/vscode/extension/purmourning.tclpro-debug.<version>`, or
    3. `tar zxfv /path/to/TclProDebug/vscode/extension/purmourning.tclpro-debug.<version>.tar.gz`
4. Restart VSCode


## Installation for developing

1. Build `tclparser` as above
2. change to this directory `cd /path/to/TclProDebug/vscode`
3. `./make_extension --dev`. `--dev` will create version `999.999.999`, and use
   symlinks so you can develop the server in-place.
4. symlink `extensions/puremourning.tclpro-debug-999.999.999` in to
   `$HOME/.vscode/extensions`
   
```
cd $HOME/.vscode/extensions
ln -s /path/to/TclProDebug/vscode/extension/purmourning.tclpro-debug.999.999.999
```

5. Restart VSCode

