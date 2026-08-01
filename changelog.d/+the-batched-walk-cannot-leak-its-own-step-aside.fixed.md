The batched-directory accelerator's step-aside is now unnameable outside the
file that raises it, instead of being `pub` and asking politely.

`sheaf.zig` raises `error.Declined` when the bulk-readdir syscall is absent or
the buffer it packed doesn't hold up; `bulkstat.zig` turns that into
`fault.Answer(…).declined = .capability_missing` so the caller falls back to the
per-file walk. That conversion was already right. What was wrong is that the
error set was `pub`, and the comment on it said it "is `pub` for exactly one
importer, `bulkstat.zig`, which converts it at the module boundary" - a property
the type system was not holding anywhere. Nothing stopped a second importer
grabbing `sheaf.Sheaf` and `try`ing its way straight past the fallback, and the
comment would still have read as true.

The PCRE2 shadow rewriter had the answer already: `error.Bail` is private and
`overapprox` returns `fault.Answer`, so the bail genuinely cannot escape. The
three arms here now do the same - each keeps its body verbatim as a private
`step`, and `next` returns `fault.Answer(?Entry)`, converting once at the seam.
The declinature rides the success position, which is what stops `try` mistaking
a step-aside for a failure; end-of-directory is `.got = null`, so "done" and
"couldn't" sit in different arms and cannot be confused.

`capability_missing` was written for this accelerator by name - its doc comment
in `fault.Decline` says "the platform lacks the syscall this accelerator rides
(bulk stat)" - so the vocabulary needed nothing new. `collect` now carries out
whichever reason the arm gave rather than restating one, so the two can't drift.

Behavior is unchanged on all three arms (Darwin `getattrlistbulk`, POSIX
`getdirentries`/`getdents64`, Windows `NtQueryDirectoryFile`); the Windows and
Linux arms were cross-compiled to check, since a host build only sees one.
