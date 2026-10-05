We use Rust's pinned LLVM tools when exporting archives on Windows, including
executable suffixes. Both Windows binding jobs check the actual tool paths and
versions before testing the bindings.
