//! The subprocess transport: locate a certified binary, run it under a
//! wall-clock guard, read its streams.
//!
//! This is the authoritative tier — every answer the crate can give, it can
//! give here. Results come from the *same* engine the CLI uses, never a second
//! matcher, and the engine's fail-loud `die()` → `exit(2)` becomes a typed
//! error rather than a terminated host, which is the property that made
//! subprocess the floor of the ladder in the first place.
//!
//! Three binaries wear the one engine — `gist` (exact), `relate` (compression),
//! `irregex` (composed) — so resolution is by name with a per-binary env
//! override. The parsers for the two *human-shaped* streams live here too:
//! ripgrep's `--json` records, and the `--rank` view, which predates `--json`
//! and still prints for people.

use std::collections::HashMap;
use std::env;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use super::readout::parse_json;
use super::{Error, Result};
use crate::contract::{EXIT_ERROR, EXIT_MATCHED, EXIT_NO_MATCH, Match};
use crate::request::SearchRequest;

/// Default wall-clock ceiling for a single engine invocation.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);

// stderr phrases the engine prints when a pattern/flag is outside its
// linear-time syntax but ANOTHER tier could answer it — so retrying on
// `engine="auto"`/`"pcre2"` is real advice (see
// `src/exec/cold/writ/arm.zig: dieUnexpressible`, `argv/args.zig`).
const UNSUPPORTED_MARKERS: &[&str] = &[
    "unsupported",
    "use ripgrep",
    "use rg for this",
    "linear-time syntax",
    "not yet implemented",
];

// The opposite verdict: no grammar the engine has accepts this pattern, so no
// `engine` choice lifts it and a PCRE2 retry only fails again. The engine prints
// this line ONLY after asking PCRE2 and being refused too
// (`writ/arm.zig: blame`), so it is that probe's answer rather than a guess —
// the same split the C ABI draws as `GIST_STALE` vs a `BadPattern` fault.
const MALFORMED_MARKER: &str = "no engine here compiles it";

/// Absolute path to the `gist` binary.
///
/// # Errors
/// [`Error::NotFound`] when no binary resolves.
pub fn binary() -> Result<PathBuf> {
    binary_named("gist", "GIST_BIN")
}

/// Absolute path to a certified binary. Resolution order: the `env` override,
/// a built `zig-out/bin/<name>` in this checkout or an ancestor of it, the
/// sibling checkout that owns the name, then `PATH` — checkout-local ahead of
/// `PATH` so a worktree never drives a stale globally installed build.
/// Successes are cached; a failure re-resolves on the next call, so building
/// the binary mid-session takes effect without restarting the host.
///
/// # Errors
/// [`Error::NotFound`] when no binary resolves, naming every path it looked at.
pub fn binary_named(name: &'static str, env_var: &'static str) -> Result<PathBuf> {
    static CACHE: OnceLock<Mutex<HashMap<&'static str, PathBuf>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(map) = cache.lock()
        && let Some(found) = map.get(name)
    {
        return Ok(found.clone());
    }
    let resolved = resolve(name, env_var)?;
    if let Ok(mut map) = cache.lock() {
        map.insert(name, resolved.clone());
    }
    Ok(resolved)
}

fn resolve(name: &str, env_var: &str) -> Result<PathBuf> {
    if let Some(raw) = env::var_os(env_var) {
        let p = expand_tilde(&raw);
        if p.is_file() {
            return Ok(p);
        }
        return Err(Error::NotFound(format!(
            "{env_var}={} is not a file",
            p.display()
        )));
    }
    let looked = candidates(name);
    if let Some(found) = looked.iter().find(|p| p.is_file()) {
        return Ok(found.clone());
    }
    if let Some(p) = which(name) {
        return Ok(p);
    }
    Err(Error::NotFound(unfound(name, env_var, &looked)))
}

/// How far up the tree the ancestor walk climbs. Sixteen is the ceiling the Go
/// binding uses: deeper than any real checkout, and a bound on the work when
/// the anchor is a registry path with nothing of ours above it.
const ASCENT: usize = 16;

/// Where the ancestor walk starts, nearest anchor first.
///
/// Two anchors, because this file is read in two unrelated situations and
/// neither one alone covers both. The **working directory** is the runtime
/// truth and is what the Go binding walks: `cargo test` inside
/// `blast/bindings/rust` stands in the blast checkout no matter which crate
/// compiled this source. **`CARGO_MANIFEST_DIR`** is baked in at compile time,
/// and — because `env!` expands where it is written — it names *this* crate's
/// directory even when relate or blast is the consumer. That is why it cannot
/// be the only anchor: from blast it can only ever describe irregex's tree,
/// which is the reason asking it for `relate` used to be unanswerable. It is
/// kept as the second anchor for a host that has chdir'd away from its
/// checkout, and it is harmlessly inert for a crates.io consumer, whose
/// manifest dir is a registry path holding no `zig-out` and no `build.zig`.
fn anchors() -> Vec<PathBuf> {
    let mut from = Vec::with_capacity(2);
    if let Ok(cwd) = env::current_dir() {
        from.push(cwd);
    }
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    if !from.contains(&manifest) {
        from.push(manifest);
    }
    from
}

/// The ordered ladder of `zig-out/bin/<name>` paths a local build could occupy.
///
/// Two passes, in the order the Python and Go bindings already resolve in
/// (`bindings/python/irgx/runtime/shell.py`, `_locate_root`;
/// `bindings/go/runtime/cold.go`, `candidates`): an already-built binary
/// anywhere up the chain, then the sibling checkout that owns the name. All
/// three are describing the same fact about one filesystem, so they must agree.
///
/// The four packages are flat siblings of one workspace — `relate` sits at
/// `../relate/zig-out/bin/relate` whether the process runs inside irregex or
/// blast — and a sibling is only believed when it carries the `build.zig` that
/// makes it that package's checkout rather than a directory that happens to
/// share a name.
///
/// Own build ahead of sibling on purpose: the checkout you are standing in is
/// the one you just rebuilt, and a sibling's `zig-out` may hold something
/// older. No rung dates what it finds, so pin an exact build with the env
/// override when the difference matters.
///
/// Nothing here builds. The Python binding will run `zig build` as an in-repo
/// last resort; a `cargo test` that silently spends ten minutes in the Zig
/// compiler is a worse surprise than a legible failure, which is the same call
/// the Go binding made.
fn candidates(name: &str) -> Vec<PathBuf> {
    let built = |dir: &Path| dir.join("zig-out").join("bin").join(name);
    let (mut own, mut siblings) = (Vec::new(), Vec::new());
    for anchor in anchors() {
        for dir in anchor.ancestors().take(ASCENT) {
            own.push(built(dir));
            // An ancestor named `name` IS the owning checkout, and its build is
            // already the candidate just pushed.
            if dir.file_name().is_some_and(|base| base == name) || !dir.join("build.zig").is_file()
            {
                continue;
            }
            if let Some(sibling) = dir.parent().map(|up| up.join(name))
                && sibling.join("build.zig").is_file()
            {
                siblings.push(built(&sibling));
            }
        }
    }
    own.append(&mut siblings);
    once_each(own)
}

/// Order-preserving dedupe. Two anchors reaching the same directory is one
/// rung, and a failure that lists a path twice reads as two places checked.
fn once_each(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut kept: Vec<PathBuf> = Vec::with_capacity(paths.len());
    for p in paths {
        if !kept.contains(&p) {
            kept.push(p);
        }
    }
    kept
}

/// The failure, naming every location in the order it was tried. Naming them is
/// the point: the alternative is the reader re-deriving the ladder from this
/// file, which is how two agents came to investigate the same dead rung twice.
fn unfound(name: &str, env_var: &str, looked: &[PathBuf]) -> String {
    let rungs: String = if looked.is_empty() {
        "\n\t(nowhere — no anchor directory could be read)".to_owned()
    } else {
        looked
            .iter()
            .map(|p| format!("\n\t{}", p.display()))
            .collect()
    };
    format!(
        "no `{name}` binary: {env_var} is unset, `{name}` is not on PATH, and no build exists at \
         any of:{rungs}\nbuild one with `zig build -Doptimize=ReleaseFast` in the {name} checkout"
    )
}

fn expand_tilde(raw: &std::ffi::OsStr) -> PathBuf {
    raw.to_string_lossy()
        .strip_prefix("~/")
        .and_then(|rest| env::var_os("HOME").map(|home| PathBuf::from(home).join(rest)))
        .unwrap_or_else(|| PathBuf::from(raw))
}

fn which(name: &str) -> Option<PathBuf> {
    let paths = env::var_os("PATH")?;
    env::split_paths(&paths)
        .map(|d| d.join(name))
        .find(|p| p.is_file())
}

/// Outcome of one child invocation: the exit code plus captured streams.
struct Output {
    code: i32,
    stdout: String,
    stderr: String,
}

/// Run `bin args...` and return its stdout, rejecting the engine's fail-loud
/// exit 2. Exit 1 is "ran cleanly, found nothing" and is a normal answer.
///
/// # Errors
/// [`Error::UnsupportedPattern`] when stderr names a syntax the engine declines,
/// [`Error::Failed`] on any other non-zero exit, [`Error::Io`] on spawn failure.
pub fn capture(bin: &Path, args: &[String], cwd: Option<&Path>) -> Result<String> {
    Ok(both(bin, args, cwd)?.0)
}

/// The same run, keeping stderr as well.
///
/// The compression face splits its answer across both streams by policy —
/// results on stdout, diagnostics (including the per-verb summary the analytic
/// stats are read from) on stderr — so a caller that wants the whole answer has
/// to take both. See [`capture`] for the error set.
///
/// # Errors
/// As [`capture`].
pub fn both(bin: &Path, args: &[String], cwd: Option<&Path>) -> Result<(String, String)> {
    let mut cmd = Command::new(bin);
    cmd.args(args);
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    let out = check(spawn_with_timeout(cmd, DEFAULT_TIMEOUT)?, bin)?;
    Ok((out.stdout, out.stderr))
}

fn check(out: Output, bin: &Path) -> Result<Output> {
    let name = bin
        .file_name()
        .map_or_else(|| "gist".to_owned(), |n| n.to_string_lossy().into_owned());
    if out.code == EXIT_ERROR {
        let stderr = out.stderr.trim();
        let low = stderr.to_lowercase();
        // Malformed is tested FIRST because it is the stronger claim and the two
        // texts can overlap: PCRE2's own message may contain "not supported", and
        // the malformed diagnostic echoes the user's pattern, which could contain
        // any marker word at all.
        if low.contains(MALFORMED_MARKER) {
            return Err(Error::BadPattern(nonempty(stderr, "malformed pattern")));
        }
        if UNSUPPORTED_MARKERS.iter().any(|m| low.contains(m)) {
            return Err(Error::UnsupportedPattern(nonempty(
                stderr,
                "unsupported pattern",
            )));
        }
        return Err(Error::Failed(nonempty(stderr, &format!("{name} exited 2"))));
    }
    if out.code != EXIT_MATCHED && out.code != EXIT_NO_MATCH {
        return Err(Error::Failed(format!(
            "{name} exited {}: {}",
            out.code,
            out.stderr.trim()
        )));
    }
    Ok(out)
}

fn nonempty(s: &str, fallback: &str) -> String {
    if s.is_empty() {
        fallback.to_owned()
    } else {
        s.to_owned()
    }
}

/// Run `gist rg <flags> <tail> --regexp <pattern> [paths]` under the request's
/// timeout. `--regexp` carries the pattern so it can never be mistaken for a
/// flag or a path.
fn invoke(tail: &[&str], request: &SearchRequest) -> Result<Output> {
    let bin = binary()?;
    let mut cmd = Command::new(&bin);
    cmd.arg("rg");
    cmd.args(request.to_argv());
    cmd.args(tail);
    cmd.arg("--regexp").arg(&request.pattern);
    cmd.args(&request.paths);
    if let Some(dir) = &request.cwd {
        cmd.current_dir(dir);
    }
    check(spawn_with_timeout(cmd, request.timeout)?, &bin)
}

/// How long a drained stream may stay open *after* its child exited before the
/// bytes already read are taken as the whole answer. The engine self-spawns a
/// resident `gist serve` daemon for warm-eligible queries, and that grandchild
/// inherits the write end of our pipe — so waiting for EOF can outlive the
/// query by the daemon's whole lifetime. Everything the child itself wrote is
/// in the pipe before it exits, so the wait is only ever for a closer.
const DRAIN_GRACE: Duration = Duration::from_millis(250);

const POLL: Duration = Duration::from_millis(5);

/// One stream being drained on its own thread, readable before that thread ends.
struct Reader {
    bytes: Arc<Mutex<Vec<u8>>>,
    thread: thread::JoinHandle<()>,
}

impl Reader {
    fn spawn<R: Read + Send + 'static>(pipe: Option<R>) -> Self {
        let bytes = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&bytes);
        let thread = thread::spawn(move || {
            let Some(mut pipe) = pipe else { return };
            let mut buf = [0_u8; 8192];
            while let Ok(n) = pipe.read(&mut buf) {
                if n == 0 {
                    break;
                }
                if let Ok(mut sink) = sink.lock() {
                    sink.extend_from_slice(&buf[..n]);
                }
            }
        });
        Self { bytes, thread }
    }

    /// What was drained, once the pipe closed or `deadline` passed. Decoding is
    /// deferred to here so a multi-byte character split across two reads is
    /// still one character.
    fn settle(self, deadline: Instant) -> String {
        while !self.thread.is_finished() && Instant::now() < deadline {
            thread::sleep(POLL);
        }
        self.bytes.lock().map_or_else(
            |_| String::new(),
            |b| String::from_utf8_lossy(&b).into_owned(),
        )
    }
}

/// Spawn `cmd`, draining stdout/stderr on reader threads so a full pipe can
/// never deadlock the wait, and kill the child if it outlives `timeout`.
/// stdin is detached (`/dev/null`) so the engine always walks the tree rather
/// than reading stdin when no path args are given.
fn spawn_with_timeout(mut cmd: Command, timeout: Duration) -> Result<Output> {
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn()?;
    let out_reader = Reader::spawn(child.stdout.take());
    let err_reader = Reader::spawn(child.stderr.take());

    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            let grace = Instant::now() + DRAIN_GRACE;
            let _ = out_reader.settle(grace);
            let _ = err_reader.settle(grace);
            return Err(Error::Failed(format!(
                "gist timed out after {}s",
                timeout.as_secs()
            )));
        }
        thread::sleep(POLL);
    };

    let grace = Instant::now() + DRAIN_GRACE;
    Ok(Output {
        code: status.code().unwrap_or(EXIT_ERROR),
        stdout: out_reader.settle(grace),
        stderr: err_reader.settle(grace),
    })
}

/// Execute a request and return structured matches.
///
/// # Errors
/// See [`SearchRequest::run`].
pub fn run(request: &SearchRequest) -> Result<Vec<Match>> {
    Ok(parse_json(&invoke(&["--json"], request)?.stdout))
}

/// Paths of files with ≥1 matching line (`-l`), sorted.
///
/// # Errors
/// See [`SearchRequest::files`].
pub fn files(request: &SearchRequest) -> Result<Vec<String>> {
    let out = invoke(&["-l"], request)?;
    let mut paths: Vec<String> = out
        .stdout
        .lines()
        .filter(|l| !l.is_empty())
        .map(str::to_owned)
        .collect();
    paths.sort();
    Ok(paths)
}

/// Total matching lines across the searched tree.
///
/// rg `-c`/`--count`: one line counted once regardless of how many times the
/// pattern hits it — the semantic every other count surface shares (the
/// resident daemon's `countLines`, the in-process FFI's per-line stream, the
/// Python `count`). Was `--count-matches` (per-occurrence), which over-counted
/// a line with repeated hits and, under `-m N`, silently diverged from the
/// warm transports.
///
/// # Errors
/// See [`SearchRequest::count`].
pub fn count(request: &SearchRequest) -> Result<usize> {
    let out = invoke(&["--count", "--no-filename"], request)?;
    Ok(out
        .stdout
        .lines()
        .filter_map(|l| l.trim().parse::<usize>().ok())
        .sum())
}

/// The persisted-index report (`gist status`) — is an index ready, how fresh,
/// how big. Read-only; safe to call blind.
///
/// # Errors
/// [`Error::NotFound`] when no binary resolves, [`Error::Io`] on spawn failure.
pub fn status() -> Result<String> {
    let bin = binary()?;
    let mut cmd = Command::new(&bin);
    cmd.arg("status");
    Ok(spawn_with_timeout(cmd, DEFAULT_TIMEOUT)?.stdout)
}

/// Build or refresh a persisted artifact (`gist index`, `relate index`).
///
/// # Errors
/// [`Error::NotFound`] when no binary resolves, [`Error::Failed`] on a non-zero
/// exit.
pub fn lifecycle(bin: &'static str, env_var: &'static str, args: &[&str]) -> Result<String> {
    let path = binary_named(bin, env_var)?;
    let mut cmd = Command::new(&path);
    cmd.args(args);
    Ok(check(spawn_with_timeout(cmd, DEFAULT_TIMEOUT)?, &path)?.stdout)
}

/// The driven binary's semver (from `gist --version`).
///
/// # Errors
/// [`Error::NotFound`] when no binary resolves, [`Error::Io`] on spawn failure.
pub fn version() -> Result<String> {
    let bin = binary()?;
    let mut cmd = Command::new(&bin);
    cmd.arg("--version");
    let out = spawn_with_timeout(cmd, DEFAULT_TIMEOUT)?;
    // `gist 0.1.0` → `0.1.0`. Current binaries answer on stdout (rg parity);
    // stderr is the fallback for one that predates that, so either is read.
    let banner = if out.stdout.trim().is_empty() {
        out.stderr
    } else {
        out.stdout
    };
    Ok(banner
        .split_whitespace()
        .last()
        .unwrap_or_default()
        .to_owned())
}
