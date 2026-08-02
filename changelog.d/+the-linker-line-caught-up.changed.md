The rename stopped at the header, and it showed. You included `irgx.h`, called `irgx_compile`, then linked `-lirregex` and compared the result against `IRREGEX_OK` - one API that could not decide what it was called. The rest of it has caught up.

The artifact is `libirgx.a` / `libirgx.dylib` / `irgx.dll` and the flag is `-lirgx`. The whole uppercase family is `IRGX_*`: the status codes, the fault-locus and pattern-flag enums, the analytic bitsets, and the include guards. So are the build knobs - `IRGX_LIB`, `IRGX_LIB_DIR`, `IRGX_NO_FFI`, `IRGX_PREBUILT_LIB`, `IRGX_<NAME>_CONTRACT`, and the wheel platform / Zig target pair the packaging hook reads. Those were chased as strings rather than identifiers on purpose: a missed enum is a compile error, but a missed knob is silent - the variable simply stops being read and the build quietly takes the default path.

Go got the limb it was missing. The package is `irgx`, so a caller writes `irgx.Compile` to reach `irgx_compile` instead of `irregex.Compile`, and the cgo tier builds under `-tags irgx_ffi` or `-tags irgx_syslib`. `relate` and `blast` had already moved to those tags, so until now there was no single tag that built the cgo rung across all four repos. The module path is still `github.com/The-Billy-Company/irregex/bindings/go`, because that is the repo URL and nobody types it as a name.

Both vendored archive sets were re-cut off the renamed engine. A stale archive still exports the old symbols and fails at the linker after every source file already looks right, so a checkout that skips the rebuild finds out late.

This is the same v1 window as the prefix itself: a library filename and a macro are compile- and link-time contracts, and tagging freezes them.
