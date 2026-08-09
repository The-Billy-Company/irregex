A horizontal parity gate over the bindings - `contract/bindings.toml` plus
`quality/parity/check.py` - and the five capability gaps it found, now closed.

Every gate in this package was **vertical**: does the Zig root export what
`contract/exports.toml` says, does the header declare it, does each binding compile
against it. Each binding passed. Nothing ever compared them to *each other*, and
that is exactly how they drifted:

- **go** had no windowed-search plane at all (`irgx_is_match_in`,
  `irgx_find_all_in`, `irgx_pattern_windows`) - a capability a Go caller simply did
  not have, with nothing anywhere saying so.
- **rust** declared the opaque `irgx_cancel` type and threaded a `*mut irgx_cancel`
  through its analytic request struct, and never bound the three functions that
  make one. The field could only ever be null: a cancellation surface that looks
  present and cannot work. A `--shape distinct` sweep is a documented 27 seconds,
  which is precisely the call a host wants to be able to give up on.
- **python** was complete, which is the only reason none of it was visible - there
  was always one binding that could do the thing, so no bug report ever said
  "irregex cannot", only "irregex cannot from here".

None of it was decided; it was just never looked at. So the rule is blunt and
horizontal: every symbol `exports.zig` exports is named in every binding's own
sources, or waived *for that binding* with a reason. A waiver is a design decision
on the record - `Set.Len()` is a field in both Go and Rust, and both waive
`irgx_slate_len` for the same reason, arrived at independently, which is the
outcome this gate is for. A gap without a reason is the drift above, and fails.

What closed, per binding:

- **Rust** gains `CancelToken` (`Send + Sync + Clone`, freeing the C token when the
  last handle drops) and a `run_until`, plus `Regex::windows` and
  `Regex::is_match_within`. An `Error::BadWindow` names a crossed pair rather than
  passing it down, since the ABI answers a crossed window and an out-of-range one
  with the same code and the caller would not learn which mistake it made.
- **Go** gains `Regexp.Windows`, `MatchStringIn`/`MatchIn`, and
  `FindAllStringIndexIn`/`FindAllIndexIn`, with a bad window panicking the way a
  slice expression does rather than returning an error Go would not expect.

It has a **second lane**, for a binding that ships the engine instead of linking
one. The Go module commits a static archive per platform, because Go has no
`build.rs` and a consumer with no Zig has to be able to `go get` and build - build
output under version control, whose only instruction to keep up with the engine was
a sentence in a README. That did not hold: the archives went behind the day the
munch plane landed, so the *default* `go test` path - the one CI and every consumer
takes - died at the linker on undefined `irgx_munch_*` while the source-built path
was green. Same species as the `build.rs` above, found the same way, by hand. So a
declared archive is now read for the ABI names it actually carries, by scanning its
bytes: the symbol table spells them in ASCII in ELF, Mach-O and COFF alike, which
keeps it a stdlib check rather than an `nm` that would have to exist and understand
three object formats. Waivers do not reach this lane - an archive is not a host
choosing a different route, it is the engine, and it either has the plane compiled
in or is old. A glob matching nothing is a contract fault, since a lane that reads
nothing approves everything.

The gate reads only code that could actually *call* a symbol, which took two
iterations to get right and both are pinned by its own proofs. Comments are
stripped, because prose about a symbol is the false pass: `sys.rs` contains the
sentence "`irgx_find_all` is deliberately not declared", and a rule that reads it
concludes the symbol is bound - the sentence should fail and the waiver row should
pass. But cgo's preamble is *spelled* as a block comment and *compiled* as C, and it
is the only place the Go binding calls the engine at all, so blanking it reported a
complete binding as reaching nothing - the same rule's inverse failure. The preamble
adjacent to `import "C"` is read back as code; a `/* */` genuinely used as prose in
Go still is not.
