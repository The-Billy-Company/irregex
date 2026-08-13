//! The in-process analytic plane: the symbol probe, the warm engine
//! cache, and the dispatch that turns a [`Query`] into a cursor.
//!
//! ## Why the symbols are probed, not linked
//!
//! Declaring a face's producer entry as an `extern` would make the crate
//! *unlinkable* against an engine that predates the analytic plane — the strictly worse
//! failure, because the subprocess tier can answer every one of these questions
//! already. So the plane is resolved with `dlsym` over the symbols already in
//! the process: present means in-process, absent means the ladder walks on. The
//! probe runs once, behind a [`OnceLock`], and its last step is the schema
//! handshake in [`super::handshake`] — a library whose row tables have moved is
//! refused loudly rather than decoded wrongly.

use std::cell::Cell;
use std::collections::HashMap;
use std::ffi::CStr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use super::answer::{Native, Rows};
use super::cancel::{self, CancelToken};
use super::{Error, Query, Result, handshake, sys};

// ── the probed plane ───────────────────────────────────────────────────────

/// The analytic entry points, resolved once.
pub(super) struct Vtable {
    /// Entry symbol -> the function that answers the verbs routed to it.
    ///
    /// Three face libraries produce these seventeen verbs (the exact face's
    /// entry for rank, the kinship face's for kinship/retrieval/sweep, the
    /// composed face's for the composed ones) and a verb names its own in the
    /// generated table, so the keys are the distinct entries that table declares
    /// rather than a list kept here. An entry the process has not loaded is
    /// simply absent: those verbs decline and the ladder answers them cold.
    runs: HashMap<&'static str, sys::AnalyticRunFn>,
    pub(super) next: sys::RowsNextFn,
    pub(super) next_batch: sys::RowsNextBatchFn,
    pub(super) stats: sys::RowsStatsFn,
    pub(super) close: sys::RowsCloseFn,
    engine_open: sys::EngineOpenFn,
    engine_close: sys::EngineCloseFn,
    /// The last-fault pull. Optional: it enriches a failure message, it is
    /// never load-bearing for correctness.
    last_fault: Option<sys::LastFaultFn>,
    /// The cancellation trio. Optional on the same grounds as `last_fault` — an
    /// engine that predates it still serves every query, just uninterruptibly.
    cancel: Option<cancel::Vtable>,
}

enum State {
    /// No analytic symbols in this process — the ladder walks on.
    Absent,
    /// The library's row tables disagree with this build's decoder.
    Drifted(String),
    Ready(Vtable),
}

/// Resolve `name` into a typed function pointer.
fn resolve<F: Copy>(name: &CStr) -> Option<F> {
    const { assert!(size_of::<F>() == size_of::<*mut std::ffi::c_void>()) };
    let p = sys::symbol(name)?;
    // A dlsym result is a code address; the typed shapes live in `sys` and are
    // checked against `include/irgx.h` by review, exactly as an `extern`
    // block is.
    Some(unsafe { std::mem::transmute_copy::<*mut std::ffi::c_void, F>(&p) })
}

fn probe() -> State {
    let (Some(next), Some(next_batch), Some(stats), Some(close)) = (
        resolve::<sys::RowsNextFn>(c"irgx_rows_next"),
        resolve::<sys::RowsNextBatchFn>(c"irgx_rows_next_batch"),
        resolve::<sys::RowsStatsFn>(c"irgx_rows_stats"),
        resolve::<sys::RowsCloseFn>(c"irgx_rows_close"),
    ) else {
        return State::Absent;
    };
    let (Some(engine_open), Some(engine_close)) = (
        resolve::<sys::EngineOpenFn>(ENGINE_OPENER),
        resolve::<sys::EngineCloseFn>(c"irgx_engine_close"),
    ) else {
        return State::Absent;
    };
    let runs = entries();
    // A cursor with nothing that produces one is not a plane. Whether the
    // ABSENT producers matter is per verb, decided at dispatch, because a host
    // that links only the exact face's library legitimately answers rank
    // in-process and the rest through the child.
    if runs.is_empty() {
        return State::Absent;
    }
    // No digest entry point at all is an older plane, not a drifted one.
    if let Some(digest) = resolve::<sys::SchemaDigestFn>(c"irgx_schema_digest") {
        let introspect =
            resolve::<sys::SchemaCountFn>(c"irgx_schema_count")
                .zip(resolve::<sys::SchemaGetFn>(c"irgx_schema_get"));
        if let Some(why) = handshake::drift(digest, introspect) {
            return State::Drifted(why);
        }
    }
    State::Ready(Vtable {
        runs,
        next,
        next_batch,
        stats,
        close,
        engine_open,
        engine_close,
        last_fault: resolve::<sys::LastFaultFn>(c"irgx_last_fault"),
        cancel: cancel::Vtable::resolve(sys::symbol),
    })
}

/// The cancellation trio this process resolved, if it has one.
///
/// Exposed to [`super::cancel`] rather than the reverse so the vtable stays the
/// one place symbols are probed.
pub(super) fn cancellation() -> Option<cancel::Vtable> {
    match state() {
        State::Ready(vt) => vt.cancel,
        State::Absent | State::Drifted(_) => None,
    }
}

/// The symbol that opens the engine every producer is handed. Named here so
/// [`entries`] can ask a producer's image whether it can see the same one.
const ENGINE_OPENER: &CStr = c"irgx_engine_open";

/// Resolve every distinct entry symbol the verb table names, keeping the ones
/// this process can actually call.
///
/// Two conditions, and the second is the load-bearing one: the symbol must be in
/// this process, AND the image that defines it must share this engine — see
/// [`sys::shares_engine`], which is why a producer carrying its own private copy
/// of the engine is dropped here rather than faulting at the call.
fn entries() -> HashMap<&'static str, sys::AnalyticRunFn> {
    let mut out = HashMap::new();
    for verb in crate::contract::schema::VERBS {
        if out.contains_key(verb.entry) {
            continue;
        }
        // The table's names are plain `&str`; dlsym wants the terminator.
        let Ok(name) = std::ffi::CString::new(verb.entry) else {
            continue;
        };
        if !sys::shares_engine(&name, ENGINE_OPENER) {
            continue;
        }
        if let Some(f) = resolve::<sys::AnalyticRunFn>(&name) {
            out.insert(verb.entry, f);
        }
    }
    out
}

fn state() -> &'static State {
    static STATE: OnceLock<State> = OnceLock::new();
    STATE.get_or_init(probe)
}

/// Whether an in-process analytic plane answered this process's last probe.
/// Diagnostic only — no behavior branches on it, the ladder does that itself.
#[must_use]
pub fn available() -> bool {
    matches!(state(), State::Ready(_))
}

// ── the engine cache ───────────────────────────────────────────────────────

/// A warm engine, freed once every cursor that borrows its corpus is gone.
pub(super) struct EngineHandle {
    ptr: *mut sys::irgx_engine,
    close: sys::EngineCloseFn,
}

// The pointer is handed to the engine's own thread-safe entry points and never
// dereferenced on the Rust side.
unsafe impl Send for EngineHandle {}
unsafe impl Sync for EngineHandle {}

impl Drop for EngineHandle {
    fn drop(&mut self) {
        unsafe { (self.close)(self.ptr) };
    }
}

/// Open (or reuse) the warm engine for `roots`.
///
/// The analytic corpus, atlas, and codex shelf load lazily on first analytic use
/// and are expensive to stand up, so an agent asking six questions about the
/// same tree should pay for it once. Keyed by the root set exactly as given: two
/// spellings of the same tree are two engines, which costs memory but can never
/// answer over the wrong corpus.
fn engine(vt: &Vtable, roots: &[PathBuf]) -> Result<Arc<EngineHandle>> {
    static CACHE: OnceLock<Mutex<HashMap<Vec<PathBuf>, Arc<EngineHandle>>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let Ok(mut map) = cache.lock() else {
        return Err(Error::Failed("engine cache poisoned".to_owned()));
    };
    if let Some(found) = map.get(roots) {
        return Ok(Arc::clone(found));
    }
    let owned = roots
        .iter()
        .map(|p| cstring(p))
        .collect::<Result<Vec<_>>>()?;
    let ptrs: Vec<*const std::os::raw::c_char> = owned.iter().map(|c| c.as_ptr()).collect();
    let mut out: *mut sys::irgx_engine = std::ptr::null_mut();
    let status = unsafe {
        (vt.engine_open)(
            if ptrs.is_empty() {
                std::ptr::null()
            } else {
                ptrs.as_ptr()
            },
            ptrs.len(),
            &raw mut out,
        )
    };
    if status != sys::OK {
        return Err(fault(vt, status, "analytic engine open"));
    }
    let handle = Arc::new(EngineHandle {
        ptr: out,
        close: vt.engine_close,
    });
    map.insert(roots.to_vec(), Arc::clone(&handle));
    Ok(handle)
}

/// A NUL-checked path → `CString` (a path with an interior NUL is unrepresentable).
fn cstring(p: &Path) -> Result<std::ffi::CString> {
    #[cfg(unix)]
    let bytes = {
        use std::os::unix::ffi::OsStrExt;
        p.as_os_str().as_bytes().to_vec()
    };
    #[cfg(not(unix))]
    let bytes = p.to_string_lossy().into_owned().into_bytes();
    std::ffi::CString::new(bytes)
        .map_err(|_| Error::Unrepresentable(format!("root path has interior NUL: {p:?}")))
}

/// Map a negative status to a typed error, enriched with the last-fault
/// detail when the engine exposes it — a status code names a *class*, the fault
/// names the incident (which file, which byte).
pub(super) fn fault(vt: &Vtable, status: i32, what: &str) -> Error {
    match vt.last_fault.and_then(incident) {
        Some(d) => Error::Failed(format!("{what}: {d} (status {status})")),
        None => Error::Failed(format!("{what}: native status {status}")),
    }
}

/// Render this thread's pending fault as one human clause, or `None` when there
/// is nothing to add. Split out from [`fault`] so the rendering is reachable
/// without a loaded engine: the whole function used to be a closure, and the
/// inverted status test below sat in it unexercised.
fn incident(pull: sys::LastFaultFn) -> Option<String> {
    let mut f = sys::Fault {
        struct_size: super::struct_size::<sys::Fault>(),
        status: 0,
        at_space: 0,
        name: std::ptr::null(),
        path: std::ptr::null(),
        path_len: 0,
        at: 0,
    };
    // `MATCH` is the pull's "a fault was written"; `OK` is "this thread has
    // nothing to confess". Testing for OK here inverted the answer, so every
    // enriched message this function exists to build was fetched and then
    // dropped, and every native failure read as a bare status number.
    if unsafe { pull(&raw mut f) } != sys::MATCH || f.name.is_null() {
        return None;
    }
    let mut msg = unsafe { CStr::from_ptr(f.name) }
        .to_string_lossy()
        .into_owned();
    if !f.path.is_null() {
        let path = unsafe { super::cell::slice(f.path, f.path_len) };
        msg.push_str(&format!(" at {}", String::from_utf8_lossy(path)));
        // Only a file offset belongs after a path: the engine names the space
        // now, so a pattern offset can no longer be rendered as a position
        // inside a filename.
        if f.at_space == crate::contract::AT_FILE {
            msg.push_str(&format!("+{}", f.at));
        }
    }
    Some(msg)
}

// ── dispatch ───────────────────────────────────────────────────────────────

/// The function that answers `op`, or `None` when its library is not loaded.
///
/// The op alone does not say: the numbers stayed ecosystem-wide when the
/// producers split, so `4` means `echoes` whether the kinship face's library is
/// loaded or not.
/// The generated table carries the entry symbol per verb, which is what makes an
/// op-range rule — and its silent mis-route on the next verb appended to a
/// family — unnecessary.
fn producer(vt: &Vtable, op: u32) -> Option<sys::AnalyticRunFn> {
    let verb = crate::contract::schema::VERBS.get(usize::try_from(op).ok()?.checked_sub(1)?)?;
    vt.runs.get(verb.entry).copied()
}

/// Run `query` in process.
///
/// `Ok(None)` is the **declinature**: no plane, the verb's producing library is
/// not in this process, or the engine returned `IRGX_STALE` because it cannot
/// serve this question warm. The caller falls through to the subprocess tier and
/// gets the identical answer.
///
/// # Errors
/// [`Error::SchemaDrift`] when the loaded library's row tables disagree with
/// this build, or [`Error::Failed`] for a genuine native fault.
pub fn run(query: &impl Query) -> Result<Option<Rows>> {
    run_until(query, None)
}

/// [`run`], abandonable through `token`.
///
/// A cancelled query comes back as the same `Ok(None)` declinature an absent
/// producer does, which is the useful shape: the caller's fall-through to the
/// subprocess tier already exists, so a host that cancelled because *this* call
/// was too slow is not then handed an error it has to classify. A host that
/// wants the giving-up to be final cancels and does not retry.
///
/// # Errors
/// As [`run`].
pub fn run_until(query: &impl Query, token: Option<&CancelToken>) -> Result<Option<Rows>> {
    let vt = match state() {
        State::Absent => return Ok(None),
        State::Drifted(why) => return Err(Error::SchemaDrift(why.clone())),
        State::Ready(vt) => vt,
    };
    // Before the corpus: a verb whose producer this process never loaded is
    // answered by the child, and standing an engine up for it would be work
    // thrown away.
    let Some(run) = producer(vt, query.op()) else {
        return Ok(None);
    };
    let engine = engine(vt, query.roots())?;
    // The pattern array has to outlive the params struct that points at it, and
    // this call is the only frame that outlives both.
    let patterns = query.texts();
    let views: Vec<sys::Text> = patterns
        .iter()
        .map(|p| sys::Text {
            ptr: p.as_ptr(),
            len: p.len(),
        })
        .collect();
    let mut wire = query.wire();
    wire.bind(&views);
    let mut out: *mut sys::irgx_rows = std::ptr::null_mut();
    let status = unsafe {
        run(
            engine.ptr,
            query.op(),
            wire.as_ptr(),
            // Null is still the right value for an uncancellable call — the ABI
            // reads it as "nobody will ask", not as a missing argument.
            token.map_or(std::ptr::null_mut(), CancelToken::raw),
            &raw mut out,
        )
    };
    match status {
        sys::OK | sys::MATCH => Ok(Some(Rows::native(Native {
            ptr: out,
            vt,
            done: Cell::new(false),
            _engine: engine,
        }))),
        sys::STALE => Ok(None),
        other => Err(fault(vt, other, "analytic run")),
    }
}

#[cfg(test)]
mod incidents {
    use super::*;

    /// What the engine would have left in the slot, staged for one fake pull.
    struct Staged {
        name: &'static CStr,
        path: Option<&'static [u8]>,
        at_space: i32,
        at: u64,
        status: i32,
    }

    // Thread-local for the same reason the real slot is: the fault window is
    // per-thread, so the fake inherits the shape and the tests can run in
    // parallel like any other.
    thread_local! {
        static STAGED: Cell<Option<Staged>> = const { Cell::new(None) };
    }

    unsafe extern "C" fn pull(out: *mut sys::Fault) -> i32 {
        let Some(s) = STAGED.take() else {
            return sys::OK;
        };
        let f = unsafe { &mut *out };
        f.name = s.name.as_ptr();
        f.path = s.path.map_or(std::ptr::null(), <[u8]>::as_ptr);
        f.path_len = s.path.map_or(0, <[u8]>::len);
        f.at_space = s.at_space;
        f.at = s.at;
        s.status
    }

    fn rendered(s: Option<Staged>) -> Option<String> {
        STAGED.set(s);
        incident(pull)
    }

    #[test]
    fn a_written_fault_is_the_message() {
        let msg = rendered(Some(Staged {
            name: c"Corrupt",
            path: Some(b"a/b.gist"),
            at_space: crate::contract::AT_FILE,
            at: 42,
            status: sys::MATCH,
        }));
        assert_eq!(msg.as_deref(), Some("Corrupt at a/b.gist+42"));
    }

    #[test]
    fn an_empty_slot_adds_nothing() {
        assert_eq!(rendered(None), None);
    }

    /// The regression: `OK` means the slot was empty, so a pull answering `OK`
    /// must add nothing even though it filled every other field.
    #[test]
    fn ok_is_an_empty_slot_not_a_fault() {
        let msg = rendered(Some(Staged {
            name: c"Corrupt",
            path: Some(b"a/b.gist"),
            at_space: crate::contract::AT_FILE,
            at: 42,
            status: sys::OK,
        }));
        assert_eq!(msg, None);
    }

    /// A pattern offset is a byte in the PATTERN, so appending it to the path
    /// would claim a position inside a filename that does not exist.
    #[test]
    fn only_a_file_offset_follows_the_path() {
        for (space, want) in [
            (crate::contract::AT_PATTERN, "BadPattern at (?=x)"),
            (crate::contract::AT_NONE, "BadPattern at (?=x)"),
            (crate::contract::AT_FILE, "BadPattern at (?=x)+3"),
        ] {
            let msg = rendered(Some(Staged {
                name: c"BadPattern",
                path: Some(b"(?=x)"),
                at_space: space,
                at: 3,
                status: sys::MATCH,
            }));
            assert_eq!(msg.as_deref(), Some(want), "at_space {space}");
        }
    }
}

/// Routing, proven without an engine.
///
/// Worth pinning here rather than only in the contract test, because a
/// mis-route has no symptom: the wrong library answers `IRGX_INVALID` for an
/// op it does not know, the ladder reads that as a declinature, and the verb
/// quietly costs a subprocess forever after.
#[cfg(test)]
mod routing {
    use super::*;

    unsafe extern "C" fn stub(
        _e: *mut sys::irgx_engine,
        _op: u32,
        _p: *const std::ffi::c_void,
        _c: *mut sys::irgx_cancel,
        _o: *mut *mut sys::irgx_rows,
    ) -> i32 {
        sys::OK
    }

    /// A vtable whose only real content is which entries resolved.
    fn with(entries: &[&'static str]) -> Vtable {
        Vtable {
            runs: entries
                .iter()
                .map(|e| (*e, stub as sys::AnalyticRunFn))
                .collect(),
            next: {
                unsafe extern "C" fn f(_: *mut sys::irgx_rows, _: *mut sys::Row) -> i32 {
                    sys::OK
                }
                f
            },
            next_batch: {
                unsafe extern "C" fn f(
                    _: *mut sys::irgx_rows,
                    _: *mut sys::Row,
                    _: usize,
                    _: *mut usize,
                ) -> i32 {
                    sys::OK
                }
                f
            },
            stats: {
                unsafe extern "C" fn f(_: *mut sys::irgx_rows, _: *mut sys::Stats) -> i32 {
                    sys::OK
                }
                f
            },
            close: {
                unsafe extern "C" fn f(_: *mut sys::irgx_rows) {}
                f
            },
            engine_open: {
                unsafe extern "C" fn f(
                    _: *const *const std::os::raw::c_char,
                    _: usize,
                    _: *mut *mut sys::irgx_engine,
                ) -> i32 {
                    sys::OK
                }
                f
            },
            engine_close: {
                unsafe extern "C" fn f(_: *mut sys::irgx_engine) {}
                f
            },
            last_fault: None,
            // Routing does not consult it, and a token is the one entry whose
            // absence is a documented state rather than a defect.
            cancel: None,
        }
    }

    fn op(verb: &str) -> u32 {
        crate::contract::schema::VERBS
            .iter()
            .find(|v| v.name == verb)
            .expect("verb")
            .op
    }

    #[test]
    fn a_verb_reaches_only_its_own_producer() {
        // Every entry present: every verb routes.
        let all = with(&["gist_run", "relate_run", "blast_run"]);
        for v in crate::contract::schema::VERBS {
            assert!(producer(&all, v.op).is_some(), "`{}` did not route", v.name);
        }
        // Only the exact face's library linked — the thin install. `rank` still
        // answers in process; the other sixteen decline and the ladder answers
        // them cold.
        let thin = with(&["gist_run"]);
        assert!(producer(&thin, op("rank")).is_some());
        for v in crate::contract::schema::VERBS {
            if v.entry != "gist_run" {
                assert!(
                    producer(&thin, v.op).is_none(),
                    "`{}` reached libgist",
                    v.name
                );
            }
        }
    }

    /// An op outside the table declines rather than indexing past it — the wire
    /// discriminant arrives from a caller, so it is input, not an invariant.
    #[test]
    fn an_op_the_table_lacks_declines() {
        let vt = with(&["gist_run", "relate_run", "blast_run"]);
        let past = u32::try_from(crate::contract::schema::VERBS.len()).unwrap() + 1;
        for bad in [0, past, u32::MAX] {
            assert!(producer(&vt, bad).is_none(), "op {bad} routed somewhere");
        }
    }
}
