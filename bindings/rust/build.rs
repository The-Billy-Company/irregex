//! Find the engine and link it.
//!
//! The crate carries a stripped static archive per supported target, so the
//! usual install links a prebuilt engine and needs no Zig toolchain. Everything
//! else is a fallback for the cases a vendored set cannot cover: someone on an
//! unvendored target, someone hacking on the engine, someone who wants their own
//! build linked instead of ours.
//!
//! The ladder, in order, and it stops at the first rung that answers:
//!
//! 1. `$IRGX_LIB_DIR` - link the library in that directory. Set, it wins;
//!    set and empty of a library, it is a hard error rather than a silent fall
//!    through to a build the caller did not choose.
//! 2. `vendor/<target-triple>/libirgx.a` - the prebuilt archive. Self
//!    contained: the vendoring script folds the PCRE2 floor in and strips DWARF.
//! 3. `zig-out/lib/libirgx.a` in an engine checkout above this crate, when the
//!    host is the target. What a source checkout already has.
//! 4. `zig build` in that checkout, when `zig` is on `PATH`.
//!
//! Every rung prefers the archive and only falls back to the shared library,
//! which is a recent luxury: the engine's ELF `libirgx.a` used to carry the Zig
//! objects alone, so a static link died on `pcre2_compile_8` and rungs 3 and 4
//! had to link the dylib and burn an rpath to route around it. `build.zig` now
//! packs both platforms' archives from a partially-linked object that carries
//! the C floor, so a source rung links the same way a vendored one does. The
//! rpath survives only for the shared fallback, which is the one case that has
//! something to find at run time.
//!
//! A target none of the rungs can serve fails here, naming the target and both
//! remedies, rather than producing a crate that cannot link.

use std::path::{Path, PathBuf};
use std::process::Command;

/// Rust target triple to Zig triple and CPU floor, for the source-build rung.
///
/// Each Zig triple names an explicit minimum platform version. Letting Zig
/// inherit the host SDK would build a library that refuses to load on an older
/// machine than the one that built it.
///
/// The CPU floor has to be named for the opposite reason. Passing `-Dtarget`
/// at all makes Zig resolve `-mcpu` to that target's *baseline* rather than to
/// this machine, and x86_64's baseline is SSE2 - so without a floor here, a
/// consumer compiling on their own modern box would silently get the scalar
/// fallback for every shuffle the scan kernels have. The values match
/// `bindings/python/scripts/build_wheels.py`; one rule, four channels.
const ZIG_TRIPLES: &[(&str, &str, &str)] = &[
    ("aarch64-apple-darwin", "aarch64-macos.11.0", "baseline"),
    ("x86_64-apple-darwin", "x86_64-macos.11.0", "x86_64_v2"),
    (
        "x86_64-unknown-linux-gnu",
        "x86_64-linux-gnu.2.17",
        "x86_64_v2",
    ),
    (
        "aarch64-unknown-linux-gnu",
        "aarch64-linux-gnu.2.17",
        "baseline",
    ),
    (
        "x86_64-unknown-linux-musl",
        "x86_64-linux-musl",
        "x86_64_v2",
    ),
    (
        "aarch64-unknown-linux-musl",
        "aarch64-linux-musl",
        "baseline",
    ),
    (
        "x86_64-pc-windows-gnu",
        "x86_64-windows.win10_rs4-gnu",
        "x86_64_v2",
    ),
    (
        "x86_64-pc-windows-gnullvm",
        "x86_64-windows.win10_rs4-gnu",
        "x86_64_v2",
    ),
    // Rust has no `aarch64-pc-windows-gnu`: mingw-w64's gcc was never ported to
    // arm64, so `-gnullvm` (llvm-mingw) is the only GNU-ABI arm64 Windows
    // target there is. Zig emits the same ABI either way.
    (
        "aarch64-pc-windows-gnullvm",
        "aarch64-windows.win10_rs4-gnu",
        "baseline",
    ),
    // The MSVC arms are here and deliberately not vendored. Zig cannot
    // cross-compile to them - the MSVC CRT headers are not redistributable, so
    // it has nothing to compile the PCRE2 floor against unless Visual Studio is
    // on the machine - which means an archive for them cannot come off the same
    // host as every other one. Naming the triples still buys the source rung:
    // on a Windows box with Zig and VS installed, `cargo build` for the default
    // Windows toolchain builds the engine and links it.
    (
        "x86_64-pc-windows-msvc",
        "x86_64-windows.win10_rs4-msvc",
        "x86_64_v2",
    ),
    (
        "aarch64-pc-windows-msvc",
        "aarch64-windows.win10_rs4-msvc",
        "baseline",
    ),
];

/// Rust target triples that name an ABI another triple already vendors.
///
/// `x86_64-pc-windows-gnu` and `x86_64-pc-windows-gnullvm` are one ABI under
/// two names - the same mingw-w64 runtime and the same COFF, reached through
/// gcc in the first case and clang in the second. A C archive that never
/// unwinds cannot tell them apart, so vendoring a second copy of three
/// megabytes would buy a directory name and nothing else.
const VENDOR_ALIASES: &[(&str, &str)] = &[("x86_64-pc-windows-gnullvm", "x86_64-pc-windows-gnu")];

/// System libraries a target needs beyond what `std` already links.
///
/// Only Windows has an entry. The engine reaches the kernel through ntdll -
/// 60 `Nt*`/`Ldr*`/`Rtl*` symbols, which come from Zig's std rather than from
/// this crate - and while `std` happens to link ntdll today, that is its
/// implementation detail and not a promise to a C archive riding alongside it.
/// Declared here so the link closes because this build script said so.
fn system_libs(target: &str) -> &'static [&'static str] {
    if target.contains("-windows") {
        &["ntdll"]
    } else {
        &[]
    }
}

fn main() {
    println!("cargo:rerun-if-env-changed=IRGX_LIB_DIR");
    let target = env("TARGET");
    let host = env("HOST");
    let crate_dir = PathBuf::from(env("CARGO_MANIFEST_DIR"));

    if let Some(dir) = std::env::var_os("IRGX_LIB_DIR") {
        let dir = PathBuf::from(dir);
        let Some(kind) = library_in(&dir) else {
            fail(&format!(
                "IRGX_LIB_DIR points at {}, which holds no irregex library. Expected one of \
                 libirgx.a, libirgx.dylib, libirgx.so, or - on Windows - irgx.lib beside \
                 the DLL. It is an error rather than a fallback because linking a \
                 different engine than the one you named would report results from a \
                 library you did not choose.",
                dir.display()
            ));
        };
        return link(&dir, kind, &target);
    }

    let vendored_as = VENDOR_ALIASES
        .iter()
        .find_map(|(alias, served_by)| (*alias == target).then_some(*served_by))
        .unwrap_or(&target);
    let vendored = crate_dir.join("vendor").join(vendored_as).join("libirgx.a");
    println!("cargo:rerun-if-changed={}", vendored.display());
    if vendored.is_file() {
        return link(vendored.parent().unwrap(), Kind::Static, &target);
    }

    let Some(checkout) = engine_checkout(&crate_dir) else {
        fail(&unserved(&target, &crate_dir));
    };

    if target == host {
        let built = checkout.join("zig-out").join("lib");
        if let Some(kind) = library_in(&built) {
            println!("cargo:rerun-if-changed={}", built.display());
            return link(&built, kind, &target);
        }
    }

    match zig_build(&checkout, &target) {
        Ok((dir, kind)) => link(&dir, kind, &target),
        Err(why) => fail(&format!("{}\n\n{why}", unserved(&target, &crate_dir))),
    }
}

#[derive(Clone, Copy)]
enum Kind {
    Static,
    Shared,
}

fn link(dir: &Path, kind: Kind, target: &str) {
    // Every rung watches the library it actually chose, named as a file rather
    // than as the directory holding it - cargo compares a file's mtime, and a
    // directory's does not move when a library inside it is overwritten in place,
    // which is exactly what rebuilding the engine does.
    //
    // This lives here rather than at each rung so no rung can be the one that
    // forgets. `IRGX_LIB_DIR` was, and it is the rung where it matters most: its
    // whole purpose is linking an engine you just rebuilt, and without this a
    // `cargo test` after a `zig build` silently re-ran the old archive's
    // behavior and reported it as the new one's.
    for name in [
        "libirgx.a",
        "libirgx.dylib",
        "libirgx.so",
        "irgx.lib",
        "irgx.dll",
    ] {
        let candidate = dir.join(name);
        if candidate.is_file() {
            println!("cargo:rerun-if-changed={}", candidate.display());
        }
    }
    for lib in system_libs(target) {
        println!("cargo:rustc-link-lib=dylib={lib}");
    }
    match kind {
        // The archive is staged into `$OUT_DIR` and searched for there rather
        // than linked out of `dir`, because a directory holding `libirgx.a`
        // beside `libirgx.dylib` is ambiguous and `-l static=` does not settle
        // it: ld64 takes the dylib, so an install prefix - the exact shape of
        // `zig-out/lib` - links shared while every line of this build script
        // says static, and the binary has no rpath to find it with at run
        // time. Staging removes the choice instead of restating the
        // preference. A search path rather than the archive's own path as a
        // link arg, because link args do not reach a crate that depends on
        // this one and `rustc-link-search` does.
        //
        // The staging copy is also where one naming difference is absorbed.
        // `build.zig` installs the archive as `libirgx.a` on every target, but
        // rustc asks the platform's linker for `irgx`, and MSVC's spells that
        // `irgx.lib`. Renaming on the way into `$OUT_DIR` keeps the vendored
        // set one shape and puts the platform's spelling only where the
        // platform's linker reads it.
        Kind::Static => {
            let staged = PathBuf::from(env("OUT_DIR")).join("link");
            let source = dir.join("libirgx.a");
            let linkable = if target.ends_with("-msvc") {
                "irgx.lib"
            } else {
                "libirgx.a"
            };
            std::fs::create_dir_all(&staged)
                .and_then(|()| std::fs::copy(&source, staged.join(linkable)))
                .unwrap_or_else(|why| {
                    fail(&format!(
                        "could not stage {} into {}: {why}",
                        source.display(),
                        staged.display()
                    ))
                });
            println!("cargo:rustc-link-search=native={}", staged.display());
            println!("cargo:rustc-link-lib=static=irgx");
        },
        Kind::Shared => {
            println!("cargo:rustc-link-search=native={}", dir.display());
            println!("cargo:rustc-link-lib=dylib=irgx");
            // So the linked binary resolves the library at run time. Only the
            // shared rungs need it; a static link has nothing to find later.
            // Windows is excluded because it has no rpath at all - a DLL is
            // resolved from the loader's search path - so the flag would be an
            // unknown argument to its linker rather than a no-op.
            if !target.contains("-windows") {
                println!("cargo:rustc-link-arg=-Wl,-rpath,{}", dir.display());
            }
        },
    }
}

/// Which library form `dir` holds, preferring the static one.
fn library_in(dir: &Path) -> Option<Kind> {
    if dir.join("libirgx.a").is_file() {
        return Some(Kind::Static);
    }
    shared_in(dir)
}

/// On Windows the linkable half of a shared build is the import library beside
/// the DLL rather than the DLL itself, so both spellings count as "there is a
/// shared engine here".
fn shared_in(dir: &Path) -> Option<Kind> {
    let found = ["libirgx.dylib", "libirgx.so", "irgx.lib", "libirgx.dll.a"]
        .iter()
        .any(|name| dir.join(name).is_file());
    found.then_some(Kind::Shared)
}

/// The engine checkout above this crate, identified by its `build.zig`.
fn engine_checkout(crate_dir: &Path) -> Option<PathBuf> {
    crate_dir
        .ancestors()
        .find(|root| root.join("build.zig").is_file())
        .map(Path::to_path_buf)
}

/// Build the engine into `$OUT_DIR`, returning where the result landed and
/// which form of it to link.
fn zig_build(checkout: &Path, target: &str) -> Result<(PathBuf, Kind), String> {
    let Some((_, zig_target, zig_cpu)) = ZIG_TRIPLES.iter().find(|(rust, ..)| *rust == target)
    else {
        return Err(format!(
            "and this crate does not know a Zig triple for {target}, so it cannot build \
             the engine from source for it either. Add one to ZIG_TRIPLES in build.rs, or \
             build the engine yourself and point IRGX_LIB_DIR at it."
        ));
    };
    let prefix = PathBuf::from(env("OUT_DIR")).join("engine");
    let run = Command::new("zig")
        .current_dir(checkout)
        .args([
            "build",
            "-Doptimize=ReleaseFast",
            &format!("-Dtarget={zig_target}"),
            &format!("-Dcpu={zig_cpu}"),
            "--prefix",
        ])
        .arg(&prefix)
        .status();
    match run {
        Ok(status) if status.success() => {},
        Ok(status) => {
            return Err(format!(
                "and `zig build -Dtarget={zig_target}` in {} exited with {status}.",
                checkout.display()
            ));
        },
        Err(why) => {
            return Err(format!(
                "and `zig` could not be run ({why}), so the engine cannot be built from \
                 the source in {}. Install Zig, or build the engine elsewhere and point \
                 IRGX_LIB_DIR at the directory holding the library.",
                checkout.display()
            ));
        },
    }
    let dir = prefix.join("lib");
    match library_in(&dir) {
        Some(kind) => Ok((dir, kind)),
        None => Err(format!(
            "and `zig build` produced no library under {}.",
            dir.display()
        )),
    }
}

fn unserved(target: &str, crate_dir: &Path) -> String {
    let mut served: Vec<String> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(crate_dir.join("vendor")) {
        for entry in entries.flatten() {
            if entry.path().join("libirgx.a").is_file() {
                served.push(entry.file_name().to_string_lossy().into_owned());
            }
        }
    }
    served.sort();
    // The MSVC arms land here by design rather than by omission, and saying so
    // is the difference between "this crate forgot Windows" and "this archive
    // cannot be built anywhere but a Windows machine with Visual Studio".
    let msvc = if target.ends_with("-msvc") {
        " No archive is vendored for any MSVC target and none can be: Zig cross-compiles \
         to every other target from one host, but the MSVC C runtime headers are not \
         redistributable, so an MSVC archive can only be produced on a machine that has \
         Visual Studio. Install Zig beside it and this build script will build the engine \
         from source, or use the -pc-windows-gnu target, which is vendored."
    } else {
        ""
    };
    format!(
        "irregex has no prebuilt engine for {target}. This crate vendors an archive for \
         {}, and nothing else. There is no pure-Rust fallback: the engine is Zig, so \
         either it links or the crate does not build.{msvc}",
        if served.is_empty() {
            "no target (the vendor directory is empty)".to_owned()
        } else {
            served.join(", ")
        }
    )
}

fn env(key: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| panic!("cargo did not set {key}"))
}

/// Report and stop. `panic!` is how a build script fails, and cargo prints the
/// message; the explicit `-> !` keeps the call sites readable.
fn fail(message: &str) -> ! {
    panic!("{message}");
}
