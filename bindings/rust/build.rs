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
//! 3. `zig-out/lib/libirgx.{dylib,so}` in an engine checkout above this
//!    crate, when the host is the target. What a source checkout already has.
//! 4. `zig build` in that checkout, when `zig` is on `PATH`.
//!
//! Rungs 3 and 4 link the SHARED library rather than the archive, and burn an
//! rpath so the result runs without `DYLD_LIBRARY_PATH`. That is not a style
//! choice: on ELF the installed archive carries the Zig objects only, so a
//! static link fails on `pcre2_compile_8`, while the shared object is fully
//! linked. The vendored archives are pre-merged, which is why rung 2 can be
//! static and needs no rpath at all.
//!
//! A target none of the rungs can serve fails here, naming the target and both
//! remedies, rather than producing a crate that cannot link.

use std::path::{Path, PathBuf};
use std::process::Command;

/// Rust target triple to Zig triple, for the source-build rung.
///
/// Each Zig triple names an explicit minimum platform version. Letting Zig
/// inherit the host SDK would build a library that refuses to load on an older
/// machine than the one that built it.
const ZIG_TRIPLES: &[(&str, &str)] = &[
    ("aarch64-apple-darwin", "aarch64-macos.11.0"),
    ("x86_64-apple-darwin", "x86_64-macos.11.0"),
    ("x86_64-unknown-linux-gnu", "x86_64-linux-gnu.2.17"),
    ("aarch64-unknown-linux-gnu", "aarch64-linux-gnu.2.17"),
    ("x86_64-unknown-linux-musl", "x86_64-linux-musl"),
    ("aarch64-unknown-linux-musl", "aarch64-linux-musl"),
];

fn main() {
    println!("cargo:rerun-if-env-changed=IRGX_LIB_DIR");
    let target = env("TARGET");
    let host = env("HOST");
    let crate_dir = PathBuf::from(env("CARGO_MANIFEST_DIR"));

    if let Some(dir) = std::env::var_os("IRGX_LIB_DIR") {
        let dir = PathBuf::from(dir);
        let Some(kind) = library_in(&dir) else {
            fail(&format!(
                "IRGX_LIB_DIR points at {}, which holds no irregex library. Expected \
                 one of libirgx.a, libirgx.dylib or libirgx.so there. It is an \
                 error rather than a fallback because linking a different engine than the \
                 one you named would report results from a library you did not choose.",
                dir.display()
            ));
        };
        return link(&dir, kind);
    }

    let vendored = crate_dir.join("vendor").join(&target).join("libirgx.a");
    println!("cargo:rerun-if-changed={}", vendored.display());
    if vendored.is_file() {
        return link(vendored.parent().unwrap(), Kind::Static);
    }

    let Some(checkout) = engine_checkout(&crate_dir) else {
        fail(&unserved(&target, &crate_dir));
    };

    if target == host {
        let built = checkout.join("zig-out").join("lib");
        if let Some(kind @ Kind::Shared) = shared_in(&built) {
            println!("cargo:rerun-if-changed={}", built.display());
            return link(&built, kind);
        }
    }

    match zig_build(&checkout, &target) {
        Ok(dir) => link(&dir, Kind::Shared),
        Err(why) => fail(&format!("{}\n\n{why}", unserved(&target, &crate_dir))),
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Static,
    Shared,
}

fn link(dir: &Path, kind: Kind) {
    println!("cargo:rustc-link-search=native={}", dir.display());
    match kind {
        Kind::Static => println!("cargo:rustc-link-lib=static=irgx"),
        Kind::Shared => {
            println!("cargo:rustc-link-lib=dylib=irgx");
            // So the linked binary resolves the library at run time. Only the
            // shared rungs need it; a static link has nothing to find later.
            println!("cargo:rustc-link-arg=-Wl,-rpath,{}", dir.display());
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

fn shared_in(dir: &Path) -> Option<Kind> {
    let found = ["libirgx.dylib", "libirgx.so"]
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

/// Build the engine into `$OUT_DIR`, returning the directory holding the result.
fn zig_build(checkout: &Path, target: &str) -> Result<PathBuf, String> {
    let Some((_, zig_target)) = ZIG_TRIPLES.iter().find(|(rust, _)| *rust == target) else {
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
    if shared_in(&dir).is_some() {
        return Ok(dir);
    }
    Err(format!(
        "and `zig build` produced no shared library under {}.",
        dir.display()
    ))
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
    format!(
        "irregex has no prebuilt engine for {target}. This crate vendors an archive for \
         {}, and nothing else. There is no pure-Rust fallback: the engine is Zig, so \
         either it links or the crate does not build.",
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
