# Changelog

All notable changes to the `irregex` kernel (formerly `gist`; the gist CLI is its flagship face) are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions track `build.zig.zon`.

<!-- towncrier release notes start -->

## [2.0.0] - 2026-08-05

### Added

- A character class parsed as a flat list of members. rust-regex parses it as a
  *set expression*, and the difference is three operators and a recursion this
  engine did not have: `&&` intersection, `--` difference, `~~` symmetric
  difference, and a bare `[` that opens a nested class rather than standing for
  itself.

  The absence was not visible as an error, which is why it lasted. `[a&&b]` read
  as the four members `a`, `&`, `&`, `b` - a class that matches, just not the
  class you wrote. `[[x]y]` read as `{[,x}` followed by a literal `y]`. rg calls
  both of those what they are: an intersection, and `error: unclosed character
  class` for the unterminated `[[x]`. Now so do we, in Unicode mode and under
  `(?-u)` alike.

  The operators fold left-to-right at equal precedence, which is what rust-regex
  actually does rather than what its documentation says (`&&` > `--` > `~~`).
  `[a-e&&b-d--c]` is `{b,d}` on both engines, and it would be `{b,d}` on neither
  reading if the precedence were real - forty cases spanning the operators, the
  nesting, POSIX classes as operands, and both engine modes are diffed against rg
  14 stdout-and-exit-code, and the parser tests carry the hand-computed sets
  beside them.

  One test changed rather than one being added: `core_test.zig` asserted that
  `[[x]` was the two-member class `{[,x}` and attributed that reading to rg. rg
  has never done that - measured 2026-08-05 against rg 14, `[[x]` is `error:
  unclosed character class`. The literal is `[\[x]`.

  Which is the part worth keeping. A parity test does not fail when the claim
  about the competitor is wrong; it fails when we stop agreeing with a claim
  nobody re-checked. That one asserted a divergence rg never had, passed green for
  its whole life, and was the reason a nested class read as a member for as long
  as it did. Every parity assertion here now cites the run and the date it was
  measured, so the next person can tell an agreement from a story about one.
- A leading `(?i)`, `(?s)`, `(?m)` or `(?-u)` is read as the flag it asks for and
  folded into the compile, in the C ABI and in every binding on top of it.

  This is the spelling every host language's own library documents.
  `re.compile("(?i)cat")`, `Regex::new("(?i)cat")`,
  `regexp.MustCompile("(?i)cat")` - and until now `irgx_compile("(?i)cat", 0)` was
  refused, because the recursive-descent parser has no production for a bare flag
  group and the seam had nothing that turned one into the option it asks for. That made the *documented*
  way to be case-insensitive unavailable to a host whose pattern came out of a
  config file it does not own, which is exactly the case where the host has no flag
  word to pass: it would have to read the pattern to know which one it needed.

  The reading lives in the syntax tier as one pure function, because it was already
  living in the CLI and a second grammar that agrees today is a divergence waiting
  to happen. Only the head is folded: `(?i)` inside a group and the scoped
  `(?i:…)` form are per-subexpression scoping, a real AST feature, and a fold that
  pretended otherwise would quietly apply a nested flag to the whole pattern. A
  non-leading global flag is also the case `re` itself has refused since 3.11.

  What the pattern says beats what the caller passed, since the pattern is the more
  specific statement - `IRGX_IGNORE_CASE` with `(?-i)cat` is case-sensitive. Under
  `IRGX_FIXED` nothing is folded, because the bytes are data. And `(?x)`, `(?U)`
  and `(?R)` are named rather than skipped past: they are flags of the wider grammar
  this engine does not implement, so the letter is reported and the pattern stays
  whole, which routes a host to the PCRE2 arm that does have them. Honoring the
  letters it recognized and dropping the rest is the silent wrong answer.

  Slates read the directive per pattern, so one member of a two-hundred-pattern set
  can fold case without the rest of it folding. `(?m)` and `(?s)` are refused there
  by index, the same refusal the flag word already gets, because that plane has
  nowhere to carry them.
- A munch answered one question: starting here, which pattern reaches furthest. Real lexers ask a narrower one, because only some terminals are legal where the parser currently stands - lex's start conditions, tree-sitter's valid-symbol set, Lezer's contextual tokenizer.

  `longestAmong` takes an `Allow` and answers among the permitted patterns only. It is not a filter over `longest`: a long illegal match hides every short legal one behind it, so by the time you have an answer to filter, the answer you wanted is already gone. tree-sitter-json is the smallest possible demonstration - `string_content` is `[^\\"\n]+`, which asked unconditionally takes `: [1, true, null],` in one bite and swallows six structural tokens. So the restriction rides the walk instead, where it costs one AND per accepting state and nothing per byte.

  `Allow` is addressed in the caller's own pattern ordinals and refilled per token, so a lexer asking a different question at every token allocates once. A pattern the slate refused has no seat, and admitting it is a no-op rather than a bit landing on somebody else's pattern.
- The certificate's meter had two backends and both were Apple's. Everywhere else - x86-64 Linux, Windows - cycles/byte silently became a wall clock, so the repo's most carefully measured numbers were unmeasurable on the platform most regex work actually runs on.

  Linux now opens `PERF_COUNT_HW_CPU_CYCLES` and `PERF_COUNT_HW_INSTRUCTIONS` as one group and reads both in a single `read()`, because two independent reads let a deschedule land between them and the pair then describes two different instants - an IPC no core can physically produce. `exclude_kernel` is what carries the event past `kernel.perf_event_paranoid = 2`, the hardened default Debian, Ubuntu, and most container images ship, so this needs no `sudo`, no capability, and no sysctl. Windows gets `QueryThreadCycleTime`: cycles only, and honestly so, because there is no unprivileged retired-instruction counter there. It reports `counts_instructions = false` rather than dividing by a wall clock and calling the quotient an IPC, and `Meter.has_instructions` is published before anything is measured so a report knows whether it has that column to print at all.

  Every backend still proves its counters advance across real work before claiming `has_pmu`. A paravirtual PMU that opens cleanly and never increments degrades to the wall clock with a note naming the wall it hit, since "one sysctl away from a real number" and "this box has no counters" are different situations for whoever reads the certificate. Provenance follows: `cpuBrand` reads the CPUID brand string on x86-64 for both new OSes, `/sys/devices/soc0` or `/proc/cpuinfo` on Linux aarch64. `requestPerformanceQos` gains a Windows arm and still returns false on Linux, where the only unprivileged lever is a hard affinity pin to a core we would have to guess was a fast one.
- The public surface is now a contract with a gate over it. Every top-level `pub`
  in `src/root.zig` has a row in the new `contract/exports.toml` naming its tier -
  `stable`, `provisional`, or `internal` - and stating in one line who it is for,
  and `quality/surface/check.py` fails when the two disagree in either direction.

  `contract/irregex.zone` already governed what a file inside this package may
  reach, and nothing governed what the package hands out. That asymmetry is how
  seventeen `regex_*` names shaped by one bench harness ended up in the front door
  with no note saying who they were for, beside a `commands` namespace that
  existed because a CLI once wanted that spelling. Someone arriving at the root
  could not tell the vocabulary every signature is written in from a door opened
  for one benchmark, because the file gave them no way to tell.

  A retired spelling carries `now = "<address>"` saying where the name went, and
  the gate checks that address still resolves - so a migration note cannot outlive
  the thing it points at, which is the failure that makes a deprecation worse than
  no deprecation. A name declared in two tiers, a row with an empty `why`, and a
  contract that stopped parsing are each their own error rather than fifty-three
  lines of phantom drift.

  The schedule is checked too, and that check earned its place immediately: the
  first draft of this contract scheduled the retired block for removal in `0.5.0`,
  on a package shipping `1.0.0`. Nothing would ever have come due, so the aliases
  would have been carried forever while reading as temporary. `[deprecation]
  remove_in` is now compared against `build.zig.zon`, and a target the live
  version has already passed fails the gate. The real target is `2.0.0`, because
  these names shipped in 1.0.0 - thirteen of the fifteen have no consumer left in
  the ecosystem, which is an argument for keeping them rather than against it,
  since an alias nobody here imports is exactly the one an outside consumer of
  1.0.0 might.

  It reads text and needs no Zig, like the ratchets it runs beside. The `why` is
  the load-bearing part: a name nobody can write one for is a name that should not
  be public.
- Windows portability now has native runtime evidence on x64 and arm64. The new lane executes the Zig suite, builds the shipped DLL, and loads it through the real Python `ctypes` binding, complementing the existing cross-target compile gate rather than mistaking compilation for execution.
- Windows was the one platform where "just install it" was not true. The engine
  built and passed there, and had for a while - `windows.yml` runs the suite on
  real x64 and arm64 kernels - but only Python could actually be installed, and
  only on x64. Go rejected Windows at compile time with a named constant, Rust had
  no vendored archive to find, and Windows arm64 had nothing anywhere. Three
  bindings, and Windows was first class in none of them.

  It is now in all three, on both architectures:

  - **Go** vendors `libirgx_windows_amd64.a` and `libirgx_windows_arm64.a`
    beside the other four, selected the same way, by the build constraint on a
    `link_windows_*.go` file. `link_unsupported.go` no longer catches Windows.
  - **Rust** vendors `x86_64-pc-windows-gnu` and `aarch64-pc-windows-gnullvm`.
    Those are the two names Rust gives the GNU ABI: x86_64 leads with `-gnu`
    (mingw-w64's gcc), and arm64 has no `-gnu` at all, because that toolchain was
    never ported to it. `x86_64-pc-windows-gnullvm` is the same runtime and the
    same COFF reached through clang, so `build.rs` maps it onto the `-gnu`
    directory rather than committing a second copy of three megabytes.
  - **Python** adds a `win_arm64` wheel, which is the last hole in a matrix that
    otherwise covered every other platform on both architectures.

  Two things had to be true for any of it. The archive has to carry its own C
  floor, which `build.zig` already does on COFF by splicing the two floor archives
  in with `zig ar qcsL` - COFF has no partial link, so the merged object every
  other platform packs is not available there. And the link has to name `ntdll`:
  the engine reaches the kernel through sixty `Nt*`/`Ldr*`/`Rtl*` symbols, which
  are Zig's std rather than ours, and mingw-w64's default library set stops at
  kernel32. Zig's own driver adds ntdll silently, which is exactly why every check
  made from a macOS laptop closed for a reason a consumer's link would not have.

  So `windows.yml` grew a second job. `native` compiles the engine here and proves
  the sources still hold; `bindings` asks the other question - whether what we
  ship links and runs under the toolchain a consumer has. On x64 that is
  mingw-w64's gcc, linking the committed archive for both Go and
  `x86_64-pc-windows-gnu`, exactly the way an install does. On arm64 Go links the
  committed archive through `zig cc`, and Rust runs `aarch64-pc-windows-msvc` -
  the target nearly every Windows arm64 Rust user is on, and the one rung no
  archive can serve, so `build.rs` builds the engine from source against the
  Visual Studio already on the runner. Between them, both rungs of that ladder now
  run on a real kernel, and until now neither did.

  `aarch64-pc-windows-gnullvm` is the one target nothing there links, because
  llvm-mingw is not on the image and Zig cannot stand in for it: Zig's mingw is
  UCRT-only, and Rust's GNU targets ask the linker for `msvcrt`. Its archive is
  not therefore unexercised - it is the same engine build, for the same Zig
  triple, that the Go arm64 step links and runs.

  Every Windows target pins Windows 10 RS4, which is the floor `build.zig`'s own
  `check-windows` drift gate compiles against, so the shipped artifact and the
  gate guarding it describe one platform. A wheel tag cannot carry a version the
  way `manylinux_2_17` can, so on Python that promise exists in the Zig triple and
  nowhere else.

  The one Windows ABI still missing a prebuilt is MSVC, and it is missing by
  construction rather than by oversight. Zig cross-compiles every target above
  from a single host; it cannot cross-compile to `*-pc-windows-msvc`, because the
  MSVC C runtime headers are not redistributable and there is nothing to compile
  PCRE2 against without Visual Studio on the machine. `build.rs` carries the MSVC
  triples for its source rung instead, so a Windows box with Zig installed builds
  and links normally, and one without gets a message that says which target it
  was, why no archive exists for it, and that `-pc-windows-gnu` is vendored.
- `(?i:…)`, `(?s:…)`, `(?u:…)` and `(?-u:…)` parse. The flags hold for the group's body and are put back at its closing paren, so the rest of the pattern is unaffected.

  This is not a corner of the syntax. Generated lexer slates are full of it: a language whose keywords are case-insensitive spells every one of them `(?i:…)`, and a generator that emits per-token Unicode mode wraps each token body in `(?u:…)`. Across thirty tree-sitter grammars pressed into slates, 114 of 115 refused patterns refused on this one construct, 87 of them in a single grammar.

  A scoped `i` folds its own subtree at the closing paren rather than waiting for the caller's whole-tree fold, which never runs when the caller did not ask for `-i`. Without that the pattern would parse and then match case-sensitively, which is worse than refusing.

  `m` and `x` refuse, and so does a bare `(?flags)`. This engine's `multiline` is whole-buffer matching rather than JavaScript's line-anchored `^`, `x` is not implemented, and a bare group's flags scope to the end of the enclosing group. Each of those is a wrong answer available cheaply; a refusal says so.

  `Munch` now says why it turned a pattern down. `declined` carries the ordinals and the new `because` carries a `Munch.Because` for each - `syntax`, `states`, or `word_context` - so a caller can tell a pattern this engine cannot express from one it merely would not build.
- `Brand` already let a fourth binary pick the name it signs a diagnostic with and the namespace its knobs live in, so an embedder could own `OUTLINER_TRACE` outright. It just had nothing to put through it. The lens vocabulary was a closed enum of this engine's own phases, and an embedder's phases are not `warm` or `reconcile` - so `OUTLINER_TRACE=press` lit nothing, and because an unrecognized token was dropped in the name of forward compatibility, it said nothing either. Rebranding got you a knob that looked wired and wasn't.

  A root module can now declare `pub const irgx_lenses = enum { lex, press, weave, folio };` the same way it declares `irgx_brand`, and those names are welded onto the engine's own set to make one enum. One enum, so there is still one mask, one env knob, one `all`, and one `trace` - a guest lens is not a second-class lens, and no call site knows which half it is naming. Engine lenses keep their ordinals, so adding a guest set can't renumber a mask somebody computed elsewhere.

  Two ways to get it wrong are compile errors instead of a lens that quietly never lights: more lenses than the 32-bit mask has bits, and a guest re-spelling a name the engine already owns. And a token matching neither half is now reported (`gist: note: TRACE names no lens 'pres'`) rather than ignored, because an ignored token and an unset knob looked identical from outside - which is the whole failure this was.

  One wrinkle worth naming, because the first embedder hit it inside an hour: the root module is a property of the compilation, not of the package, and it moves. Under a custom test runner the runner can be the root, and a C-ABI host has no Zig root at all - `std_options` lives with exactly this. So `lit` and `trace` now take the lens *name* (still spelled `.press`, no call site changed) and resolve it at comptime, which lets the answer differ where it should: an engine lens always resolves, a guest lens resolves wherever the declaration reached, and a name matching neither is a compile error where a guest set was declared - your own typo, worth stopping for - but a dark channel where none was, since nothing there can name it and no `TRACE` token can light it. Otherwise an embedder's own trace lines are the reason its test build fails.
- `Munch.adopt` assembles a slate from automata the caller already holds, and
  `Dfa.borrowed` says the tables under one are somebody else's to free.

  Determinizing a slate is the expensive half of `Munch.compile`, and its result
  is a pure function of the slate. A caller whose slate is fixed - shipped inside
  an artifact rather than written at the prompt - can now pay that cost once,
  store the automata, and arrive with the answer instead of the question. The
  tables can live in a mapping or in one inflate buffer, because a borrowed `Dfa`
  releases its handle and leaves the memory to whoever owns it.

  Both are additions. `Munch.compile` builds exactly the slate it always did,
  and a `Dfa` nobody marks `borrowed` frees exactly what it always freed.
- `Munch.shortestAmong` - the shortest non-empty match at an offset, beside the
  longest one that was already there.

  Maximal munch answers "which token is here" only when something vouched for the
  slate. Asked over every pattern a grammar has, it answers something else: such a
  slate always contains a run-of-anything-but-a-delimiter, and that member reaches
  further than every real token at every byte. The result is a fact about the
  grammar's widest regex rather than about the bytes - measured on outliner's wall
  survey, the median such answer was **1,777 bytes long**, and one of them named
  `xml_text` over a scala file containing no XML.

  So a caller with no state behind the question can now ask for the least the
  slate can commit to instead. The walk backing it stops at the first accept
  rather than the last, which makes it the cheaper of the two as well as the
  narrower; empty matches are passed over, since a nullable pattern would
  otherwise name every position at length zero.

  `longest` and `longestAmong` are untouched, and the shared `scan` takes the mode
  as a comptime-known enum, so neither pays for the other.
- `Pattern` is the door most callers actually wanted: compile once, then `isMatch`,
  `find`, `matches`, `groups`, `replace`, `split`. It owns its own scratch through
  a `Pool`, so no signature a consumer touches mentions a Pike VM thread list, and
  it compiles the capture arm only if somebody asks for a group. `regex.Regex` is
  still there for an index or a planner that genuinely wants the compiled program;
  it just stopped being the thing you have to hold to ask a question.

  The part worth reading twice is the walk. Resuming at `span.end` is right for a
  match that consumed something and an infinite loop for one that did not, so a
  cursor has to step past an empty match deliberately. It steps one **byte**. A
  codepoint-sized step is the plausible-looking mistake, and the first draft here
  made it: `l*` over `héllo` has an empty match at byte 2, the continuation byte of
  `é`, and stepping a whole character quietly loses it. Python, `rust-regex` and
  ripgrep all report that match. Measuring against them is what caught it; the
  test that had been written asserted the bug, in confident prose.

  Where the rules genuinely fork is the empty match *adjacent* to the previous one
  and the one at the very end of the text, and this package now answers that twice
  on purpose. `Cursor` reports both, matching Python `re`, `rust-regex` and JS.
  `kernel/query`'s `walk` - what the `gist` CLI runs, and what the C ABI hands a
  host's buffer to - suppresses both, matching ripgrep byte for byte. `b*` over
  `abcb` is five spans through one door and three through the other. Neither is a
  regression: rg drops those because it prints line-oriented rows and they are
  noise on a page, and a library that dropped them would disagree with every regex
  library its caller has used.

  That is the kind of difference someone eventually "fixes" into a single rule,
  because it reads like drift until you know which audience each side serves. So
  `kernel/query/zero_width_test.zig` holds both sequences side by side, each row
  carrying the outside authority it was measured against and one line saying why
  that row exists. A case where the two agree is in there for the same reason as
  one where they differ: it proves the fork stayed in the empty-match rule and did
  not leak into ordinary matching.

  Nothing in the C ABI or the three language bindings changed, and looking closely
  enough to be sure was the useful half of this. `irgx_find_all` hands the buffer
  to that same `walk` as one unterminated unit and returns the whole answer, and
  Go, Rust and Python all iterate what it returns rather than running a
  `find(from)` loop of their own. The advance rule was never written five times
  out there; it was written once, on purpose, and the header in
  `surface/ffi/pattern.zig` says so.
- `\p{...}` resolved general categories and scripts. It did not resolve `XID_Start` or `XID_Continue`, which is how Go, Java, C, Rust, and JavaScript each spell "identifier character" - so the single most common terminal in any language grammar was a pattern this engine rejected.

  The data was already pinned: `DerivedCoreProperties.txt` is where `\w`'s `Alphabetic` comes from, and the two identifier properties sit a few hundred lines further down the same file. What was missing was the generator reading it. It now reads every binary property in `DerivedCoreProperties.txt` and `PropList.txt` generically rather than lifting the three the Perl classes happened to need, which is 57 properties and matches what rust-regex resolves. A three-field row (`InCB; Linker`) is a property *value* and is skipped, so no class is invented that Unicode does not define; a name a category or script already claimed is dropped rather than emitted where the first-match lookup would never see it.

  The tables grow from 340 KB to 577 KB of source. Compile time did not move.
- `\p{Control}` now resolves, and so does every other UAX #44 long name for a
  general category - `\p{Uppercase_Letter}`, `\p{Other_Symbol}`,
  `\p{Space_Separator}`, and the rest of the forty. The generated property table
  carries these categories only by their two-letter abbreviation, so a pattern
  spelling the long name got `unknown property after \P or \p` and refused,
  where PCRE, ICU and rust-regex all take either spelling.

  The aliases are hand-written next to the lookup rather than folded into the
  generated table, because they are the property file's own names and do not move
  with a Unicode revision; the ranges they resolve to are still the generated
  ones, and the test asserts the two spellings return the same slice rather than
  merely both returning something. Matching stays loose in the same way the rest
  of the lookup is, so `gc=private use` and `Private_Use` are one name.

  Nothing that already compiled changes: the alias table is consulted only after
  the generated table has already failed to answer, and an undefined name still
  fails closed.
- `\p{Emoji}`, `\p{EMod}` and `\p{ExtPict}` were rejected, and so was every short
  property alias - `\p{Alpha}`, `\p{XIDS}`, `\p{WSpace}`. rg resolves all six.

  Both gaps were the generator lifting the names somebody happened to need rather
  than reading the file that defines them. The emoji properties live in UTS #51's
  `emoji-data.txt`, whose rows are the same two-field shape
  `DerivedCoreProperties.txt` already parses, so it joins the binary-property
  source list and nothing else changes. The aliases live in `PropertyAliases.txt`,
  so the alias table is generated from it instead of hand-kept: an alias whose
  long name this build does not carry is dropped rather than emitted, because an
  alias resolving to nothing reads at the call site exactly like a property we
  support and got wrong.

  Both files are vendored under `tools/ucd/` beside the rest of the UCD, at the
  same Unicode version, each with its own sha256 pin in that folder's README and
  its own line in `NOTICE` under the Unicode License v3 entry.

  Why it mattered enough to chase: the three emoji names are how Swift and Julia
  spell an identifier. A grammar whose identifier terminal will not build does not
  fail loudly - the terminal simply never wins, and every byte it should have
  owned surfaces downstream as a stray, hundreds of bytes away and wearing a
  different defect's name. Swift's parse went from 49.5% to 77.0% of the file
  under a root on the back of this and the class-set operators; Julia's from 21.2%
  to 67.2%. Measured by rebuilding the same parser against an engine with only
  these two changes reverted: the other twenty-eight grammars are byte-identical,
  and the two that move are exactly the two whose patterns contain this syntax.

  Not all of it is tree. Julia's 12,579 recovered bytes are 8,847 under a
  construct and 3,732 under a bare token - identifiers that now lex correctly
  inside a docstring whose external scanner still walls, so they are named rubble.
  Swift's landed under constructs. Same headline, different meanings, which is why
  the caller now reports both.
- `assay.Cadence` reads the core's real sustained rate off a dependent `ADD` chain, one cycle per link by construction, and it had an arm for exactly one architecture. Off AArch64 it returned null, so every consumer downstream of it went dark: the price lane cannot mint a coefficient without a clock, and `zig build ladder-price mint` is how the ladder's auction learns what a kernel costs. x86-64 had no minted row for the same reason it had no clock, which reads as "we never measured there" when the truth is that nothing there could measure.

  The x86-64 arm is two-operand and read-modify-write - the increment rides a register tied to the output rather than an immediate, since `$` is LLVM's own operand sigil inside an asm template. Emitted, the loop is sixteen `add r15, rdx` with the constant hoisted out and nothing between them, which is the same one-cycle chain the AArch64 arm builds. 32-bit x86 is deliberately left out instead of given a `u32` chain: a 64-bit add lowers to `add`/`adc` there, two instructions per link, and the whole reading rests on the link being one.

  Both arms select on architecture rather than `cpu.has`, which is the one shape the isa-floor ratchet exempts and for its stated reason - integer `add` is mandatory base ISA on both families, so there is no optional feature to ask about.

  `Cadence.measurable` is now published, because three benches were each answering "does this target have a clock" with their own copy of the arch test, and `bench/rungs/parabix` and `bench/rungs/shuffle` each carried a byte-identical copy of the chain itself. A copy is how a row's clock and the coefficient that row is compared against come to be divided by two different readings. They delegate now, as the price lane's probe already did.
- `commentMask` answered one bit per byte: is this commented out. That is the only question a ranker needs, and the wrong shape for a consumer that has to tell a call site apart from a name printed inside a string.

  `spanMask` returns the three-way answer the lexer already computed and threw away - `code`, `comment`, or `literal` - one `Span` per byte. `commentMask` is now a projection of it, so the two cannot disagree about where a comment ends, and both walk through one shared `paint` routine instead of two copies of the state machine.

  `lexspan` also joins the root test block by name. It sits a level below what `refAllDecls` analyzes, so its assertions compiled and never ran.

  `blast` is the first consumer: a symbol named in a benchmark's string constant is no longer reported as code that breaks when you change it.
- `irgx.runtime.shell._resolve` gained a fourth rung: a binary a *product's own*
  wheel bundled at `<name>/bin/<name>[.exe]`, checked through
  `importlib.resources` after the explicit `GIST_BIN`/`RELATE_BIN`/`BLAST_BIN`
  override and a sibling dev checkout's `zig-out/bin/<name>`, and before the
  plain `PATH` lookup. Nothing about the existing three rungs moved — an
  override still wins outright, and a dev checkout still wins over a packaged
  copy — so a contributor who never sees the new rung sees no change at all.

  The rung exists for the products this substrate underlies, not for this
  package itself: `gist-search`, `relate-search`, and `blast-search` each ship a
  per-platform wheel that bundles its own CLI now (`hatch_build.py` in each of
  those repositories), and until this change nothing in the shared resolver knew
  to look inside one. Without it, "the wheel bundles the binary" and "the
  binary is findable" were two separate, unconnected claims — a `pip install
  gist-search` would still raise `GistNotFoundError` the moment its first verb
  shelled out, because the resolver had no fourth place to check. `irregex`
  carries no bundled binary of its own and never will (it ships a shared
  library, not a CLI), so this package's own behavior is unchanged; it is
  purely the shared place three sibling products' bundling now has a matching
  lookup for.
- `libirgx` grew a slate plane: `irgx_slate_compile` takes N patterns, and
  `irgx_slate_is_match` / `irgx_slate_which` answer about all of them in one pass
  over the text, with attribution. Everything else in this ABI is about one
  pattern, and the two ways a C host had to fake this were both bad. N calls to
  `irgx_is_match` read the bytes N times. One fused `a|b|c` reads them once and
  throws away which pattern hit, which is usually the answer you wanted.

  The kernel has had this for a while - it is what `gist`'s `patterns` verb runs
  on, but it had it in the wrong unit. `PatternSet.docMask` answers per LINE, which
  is right for a grep walking a corpus and wrong for a plane whose neighbor treats
  the whole text as one unit: `^b` over `"a\nb"` is a match to a grep and not a
  match to a regex library, and shipping the line face would have meant one
  library telling a host two different things about the same string. So the kernel
  grew the buffer face first - `bufMask` / `bufAnyMatch`, confirming through the
  same `holds` the single-pattern plane goes through - and the parity suite holds
  it to `irgx_is_match` pattern by pattern, with the SIMD prefilter on and off,
  because a prefilter that changes an answer is a prefilter with a bug.

  The fused gate the line face uses is deliberately not on this path. It is an
  alternation of every pattern, which over-approximates per line and is unsound
  per buffer: `a\sb` over `"a\nb"` matches the buffer and no line, so a gate that
  says no would have withheld a real match.

  `*refused` is the part a single pattern never needed. With two hundred patterns,
  "one of them is unsupported" is not something you can act on, so a refusal names
  the index, and it names it in the vocabulary `irgx_compile` already uses -
  `IRGX_STALE` when `IRGX_PCRE` would take the pattern, a located `BadPattern`
  when nothing will. It costs one recompile per pattern on a path that already
  failed, and it is the only way to answer the question a host actually has.

  There is no per-pattern span verb, and that is the edge rather than an omission.
  A slate is a classifier: once you know pattern 7 is in this text,
  `irgx_find_all` on pattern 7 is the walk you were going to run anyway, against a
  text that is now known to be worth walking. `Munch` stayed out too - it has a
  Zig consumer and no C one, and a verb minted for nobody is a verb that gets
  maintained for nobody.

### Changed

- The Go module's import path is now
  `github.com/The-Billy-Company/irregex/bindings/go/v2` — Go's own
  major-version-suffix rule for a v2+ module, without which the proxy refuses
  to resolve the tag at all. `go get .../bindings/go/v2` and update the
  import; the package name (`irgx`) is unchanged.

- Both vendoring scripts link a probe program against each fresh archive before
  committing it, so a missing symbol is their failure rather than somebody's
  `go build` a week later. The catch is that nobody ever performs that link. A Go
  consumer's link is driven by the `#cgo LDFLAGS` line in
  `link_<goos>_<goarch>.go`; a Rust consumer's is driven by what `build.rs`
  emits. If either disagrees with what the probe used, the proof is evidence about
  a build that does not happen.

  That was harmless while every archive closed against libc alone. Windows ends
  it: those archives need `-lntdll`, and it is now the kind of thing a matrix can
  declare and a link file can quietly not.

  So each script checks the other side of the link before compiling anything.
  Go's reads every target's `link_*.go` and holds its `#cgo LDFLAGS` to the
  libraries the matrix declares - and holds `link_unsupported.go`'s build
  constraint to excluding every target the matrix now serves, which is the failure
  where you add a platform, forget the constraint, and both files compile at once
  and die on an undefined constant in the consumer's build. Rust's checks that
  every library a target declares is one `build.rs` actually emits. Both run off a
  file read, before the first byte is compiled, because the alternative costs
  several minutes per target to learn the same thing.

  Two smaller things fell out. Both scripts decided whether to *run* the probe
  rather than only link it by asking `os.uname()`, which does not exist on
  Windows, so somebody vendoring from a Windows machine got a cross-compile note
  for their own platform. That is `platform.machine()` now, and each target names
  the machines it is native to. And the Python wheel matrix pins Windows 10 RS4 in
  its triple like every other target pins its floor, rather than inheriting
  whatever Zig defaults to.
- Every package index this project publishes to now shows the repository's own
  `README.md` as the project's page, rather than the short one kept beside each
  binding. PyPI and crates.io are where most people meet this project first, and
  they were being shown a page about the ctypes surface and nothing else - not the toolkit that surface is a binding for, and not the three tools built on it.

  The README could not simply be pointed at, because a relative link resolves
  against whatever page displays it. `include/irgx.h` is correct on GitHub and a 404
  under `pypi.org/project/irregex/`. crates.io is the worse of the two: it rewrites
  relative links against the crate's own subdirectory, so the same path becomes a
  well-formed URL into `bindings/rust/` pointing at a file that was never there,
  and nothing looks broken.

  So `tools/registry_readme.py` is now the one rewriter both ends share. It
  absolutizes every relative target against the `repository` URL the manifest
  already declares, in the form that serves what the target is - `raw` for an
  image, `tree` or `blob` chosen by what the path is on disk - and a target the
  repository does not contain fails the build instead of publishing a dead link.
  GitHub's `> [!NOTE]` alert, which renders as literal text anywhere else, is
  lowered to a bold lead line. Headings need no help: both renderers rewrite
  in-document anchors to match the ids they mint, so the table of contents arrives
  intact.

  Python gets it through a Hatchling metadata hook, so the corrected page exists
  only inside the artifact. Cargo has no metadata hook, so `readme` now points at
  a gitignored `bindings/rust/PROJECT_README.md` that the same tool mints at
  package time - `cargo package` fails loudly if it was never generated, and
  `cargo build` never reads it. Both indexes end up with a byte-identical page.

  An sdist is the one artifact with no repository above it, so it carries the
  corrected README beside the sources and a source build reads that, rather than
  being asked for a file the archive does not contain.

  Go needed no rewriting - pkg.go.dev renders the README at the module root and
  resolves its links against the repository - but a dead one there is still a dead
  link on the module's landing page, and a Go module has no build step to catch
  it. `--check` now proves those targets resolve too, on every commit.

  The README stays written for the repository it lives in.
- The repository README now points its historical, mathematical, and benchmark
  narrative at the dedicated irregex technical report while keeping the API,
  contracts, architecture, and executable proof local.
- Three bindings, one C ABI, and until now three arrangements that happened to
  agree without anything saying they should. `bindings/README.md` is that
  something: a concern map across Zig's FFI plane, Rust, Go and Python, plus the
  reasons the three decompositions are deliberately not identical.

  The rule the map is built on is that the regex face **is** the binding's root.
  Somebody who wants a regex over a buffer is the larger audience by a wide margin,
  so they get `irgx.finditer`, `irgx::Regex::new`, `irgx.MustCompile` and pay for
  nothing; the analytic substrate a sibling product binding wants lives in named
  packages beside it (`contract/`, `request`, `runtime/`). Rust already said this
  in the language - private `mod`s for the regex face, `pub mod` reserved for the
  substrate - and Go said it by keeping the face at the package root. A Python
  `irgx.regex.pattern` was briefly a real import path here, and it was a level of
  nesting with no counterpart in the other two, so it is gone.

  Two things moved to finish the map. Python grew `_pool.py`, which is where a
  `Compiled` handle and the per-thread pool over it now live together; the handle
  had been sitting in the ABI module and the pool inline in `Pattern`, which meant
  the one genuinely hard invariant in the binding - *a C handle belongs to one
  thread, and it owns the scratch its finds run in* - was the only concern with no
  file to its name, in the one binding where that is true. Rust's `pool.rs` has
  carried it since the crate existed. Python's `_template.py` is `_replace.py` for
  the same reason: `replace.rs` and `replace.go` are named for what a caller asks
  for, and it was the last file named for the artifact instead. In Go,
  `irregex.go` is `pattern.go` - the package is `irgx`, the file was named after
  the repository, and the concern is the one every other surface spells
  `pattern`.

  What the map does *not* do is force one spelling everywhere. The file that
  projects a span into something a caller can slice is `matches.rs` in Rust,
  `find.go` in Go and `_match.py` in Python, because that is what the `regex`
  crate, the `regexp` package and `re` each call it, and a binding is worth having
  because it reads like the library its caller already knows. Nor does it force one
  file count: Rust splits its seam from its refusal vocabulary because it *links*
  the engine and its seam has no failure to report, where Python *loads* one and a
  wrong `IRGX_LIB` is a refusal the seam itself raises. Splitting those two in
  Python would be a cycle rather than a ladder. Each fusion in the table is a
  language forcing it, and each one now says so out loud instead of reading like
  somebody's oversight.

  No behavior changed, and no public name in any of the three bindings moved.

### Removed

- `PatternSet.ends` is gone, and with it the union automaton a slate used to
  determinize at compile time. Compiling eight mixed patterns went from ~175 ms to
  17 ms; the worst combination I could find in that set went from 194 ms to 34 ms.

  The verb had no callers. Not in the kernel, not in the three faces, not in any of
  the four consumer repos - and it cost every slate a powerset construction over
  the alternation of all N patterns. A Unicode `\d+` in the set is what makes that
  visible: the class expands to hundreds of ranges before the subset construction
  starts, so two patterns cost 7 ms and eight cost most of a fifth of a second, all
  of it for a `?Ends` nobody ever read. It surfaced through the new C ABI slate
  plane, where compiling a set is something a host does out loud rather than a
  step buried in a corpus walk.

  Nothing was lost. The automaton itself lives where it always did, in
  `regex/linear/program/chorus.zig`, tested there, and `Munch` compiles one
  directly for the lexer face. What went away is a slate holding one for free.
  Anyone who wants every end position - including the ends a leftmost scan
  swallows, which is the one question the confirm path genuinely cannot answer -
  compiles a `Chorus` and pays for it deliberately.

  Its absence from the hot path was already measured, which is why the removal is
  cheap to believe: `bench/rungs/patternid` puts one union walk against the N
  engine confirms it would replace and the union runs at 0.06x-0.41x their speed,
  because a literal pattern's confirm is a SIMD memmem that never reaches a DFA at
  all. So the slate was paying at compile time for something it correctly refused
  to use at match time.

### Fixed

- A calibration row is now claimed by the byte-permute it was measured over
  instead of by the CPU it was measured on, and the published manylinux wheel
  gets its vector rungs back.

  `Calibration.hosts` - a list of `builtin.cpu.model.name` prefixes - is replaced
  by `Calibration.isa`, one member of the new `lanes.Isa` (`portable`, `ssse3`,
  `avx`, `neon`). `price.active` selects the row whose class equals this build's
  `lanes.isa`. Both sides are comptime reads of the same feature bits that chose
  the SIMD arms in the first place, so a row is selected by the property its
  coefficients are a function of.

  The wheel is the reason. Its declared floor is x86-64-v2, so its model name is
  `x86_64_v2`, so it matched neither `apple_` nor `raptorlake`, so it fell to
  `unmeasured` - and `measured = false` is what the vector rungs consult before
  bidding. The thing most people install had the SSSE3 composition and the
  Parabix transposition compiled into it and never let either one bid, and
  nothing anywhere said so. Being precise about who a row spoke for had turned
  into almost nobody having one.

  Selecting on the permute is the middle of two spellings that were both wrong.
  `builtin.cpu.arch` claimed too much: every AArch64 target read the Apple row,
  so a Graviton, an Ampere part and a Raspberry Pi bid an M4 Max's ratios. The
  model name then claimed too little, in the way above. The permute is what the
  numbers actually vary on, and they vary a lot - `compose_eol` is 40% dearer
  under legacy `pshufb` than under VEX `vpshufb` on the identical core, and the
  two Parabix halves come out nearly inverted between them.

  A third row, `ssse3`, is minted for that floor. It is the same i5-13500 built
  `-Dcpu=x86_64_v2`, so the core is held fixed and the only difference from `avx`
  is the encoding. A real v2-only part is older than that core, which makes these
  numbers a modern CPU executing a conservative build - the case that actually
  ships rather than a hypothetical Nehalem.

  Giving the v2 floor a row of its own also changes what the auction does there,
  which is the point of having one. `compose_eol` at 1.418 against a 1.924 walk
  means the end-of-line composition LOSES on that floor where it wins on AVX at
  1.008 against 2.001, so `^[a-z]{6}[0-9]$` now goes to the fallback - and the
  bench measures that composition at 2.27 cyc/B, exactly what the row predicts,
  with worst regret across the slate at 1.00x. Two tests had been reading the
  agreement of the two rows that existed as a law and had to be told it was a
  measurement instead: one asserted the widest composition beats its walk with the
  end-of-line index on, which is now asked of the plain form (true everywhere) and
  pinned per class for the `+eol` form; the other floored a differential's case
  count at what the richest build arms, which failed the leaner build for arming
  correctly.

  The claim is now wider than the measurement behind it: a row speaks for every
  core in its class. That is the trade, taken deliberately, and `verify` is the
  instrument that reports when a given machine disagrees with its class. There is
  no AVX-512 member, because `shuffle` has no `vpermi2b` arm and a class for it
  would name a kernel this engine cannot build.

  `lanes.Isa` lives beside `shuffle` and `widest` rather than in the price plane,
  with a test holding the class and the lane cap in step, so adding an arm without
  a class fails at the arm rather than silently pricing the new one as the old.
- A sibling parser found uninitialized memory in its own persisted records and
  asked whether this engine had the same class of defect. It had one, in the AST
  interner: `Op.uclass` is `[]const [2]u21`, and both `hash` and `eql` read it
  through `std.mem.sliceAsBytes`.

  `@sizeOf(u21)` is four and only twenty-one bits are a bound, so eight bytes of a
  range carry forty-two bits of set and twenty-two bits of whatever the allocation
  last held. Two byte images of one class therefore compare unequal, and the
  hash-consed DAG keeps **two nodes for one Unicode class** — after which the
  alphabet, the determinization, and the automaton every consumer receives are
  downstream of a graph that failed to canonicalize.

  The reason `eql` read bytes is the part worth keeping. `std.mem.eql([2]u21, …)`
  **does not compile** — Zig will not apply `!=` to that type — so the byte view
  was the short spelling available, and it is the one this type cannot honor. A
  type that refuses the obvious comparison pushes every author toward the unsound
  one. Both halves now read values: `hash` widens each range through
  `extern struct { lo: u32, hi: u32 }`, whose fields tile it, and `eql` compares
  bounds.

  **Measured, and nothing moved.** Ten Unicode-heavy patterns interned on both
  arms give the same 79 offered / 49 distinct. An adversarial arm — one arena,
  `reset(.retain_capacity)`, a pointer-heavy non-class pattern parsed between
  rounds so the recycled bytes belong to `Node` structs — interns eight parses of
  `[α-ω]` to **one** node on both arms. The raw bytes say why: `b1 03 00 00 c9 03
  00 00` every round, because the parser's store path zero-extends. So the defect
  was latent, it was costing zero, and `gist` / `relate` / `blast` inherit that
  same zero. The number is recorded so nobody rediscovers the type and assumes it
  was expensive.

  It is still a fix rather than a formality: the guarantee is absent, and the
  absence is visible in this repo. The regression's `twoWays` helper assigns
  `dst.* = .{ src[0], src[1] }` and the `0xAA` poison **survives** in the slack,
  where the parser's own path zeroes it — two spellings of one type's store,
  disagreeing about the bytes. Today's canonical image is a property of which
  spelling the hot path uses, at this optimization level, on this target.

  The near-miss: my first regression built the second copy with `@memcpy` from a
  `.rodata` literal, which copies the source's zeroed slack over the poison, so it
  **passed against the unfixed code**. A test that reproduces a bug only when the
  bug is absent is worse than no test. It assigns element-wise now and opens by
  asserting the two sides really do differ byte-wise. `dag_test.zig`'s slice
  payload was green for the whole life of this defect for exactly that reason and
  has been given a heap allocation and a poison fill.

  The rule is now structural in three places. `frame.seamless(T)` is a comptime
  `@compileError` when a type's fields do not tile it; `phantom/treemap.zig`'s
  `Rec` and `Ent` assert it — which is what `Ent._pad: u8 = 0` has always been for
  and why it cannot be deleted as unused — and `crest/sidecar.zig` asserts it of
  `crest.Vector` before writing vectors to disk. `mix.SliceCtx(T)` refuses to
  instantiate over an element type with unowned bytes at all, so the shape cannot
  be respelled through the shared context. Anti-vacuity is a test that the
  predicate still says **no**, over `struct { hi: u32, mask: u64 }` and over
  `[2]u21` itself, because a predicate that says yes to everything reads exactly
  like a clean sweep.
- A slate now builds the accelerators for the face it will be asked:
  `PatternSet.compileFor(gpa, specs, .buffer)` skips the fused gate, and the C ABI's
  slate plane compiles that way. `PatternSet.compile` is the line face's
  constructor and is unchanged, so every corpus walk in the ecosystem compiles
  exactly what it did before.

  The gate is one `CompiledQuery` over `(?:p0)|(?:p1)|…`, so unlike everything else
  in a slate its price grows with the whole slate rather than with any one pattern.
  The buffer face cannot use it at any price - an alternation over-approximates per
  line and is outright unsound per buffer, which is why `bufMask` never consulted
  it - so a C host was paying, at compile time, for the one accelerator that could
  never answer its question.

  That is the difference between an ABI you can hand two hundred patterns and one
  you can't. `irgx_slate_compile` over 200 patterns of the shape `a<i>x+\d?` cost
  about 5.5 s with the gate; without it the slate compiles at parity with
  compiling the same patterns one at a time (0.5x-0.8x of that, since the muster
  pools their literals in one pass). The realistic case moved even further: the
  eight mixed patterns the binding suites use went from ~175 ms to 3.2 ms, and the
  Python suite's 497 tests from 35 s to 6.6 s.

  The muster stays on both faces, because both faces use it. A prefilter you run
  is worth its compile; a gate you refuse to run is not.
- Both vector rungs refused every x86-64 host at compile time, and neither refusal was about x86. Compose gated on `builtin.cpu.has(.aarch64, .neon)` and Parabix on `arch == .aarch64`; the comment defending the second one named a throughput measurement, which is a fact about who has run a benchmark, not about what instructions a machine has. So an architecture test was standing in for a pricing question on the target where most regex work actually happens, and the answer it gave was "no kernel here" when the truth was "nobody minted a coefficient here yet".

  Those are now two predicates, and the ladder takes the conjunction itself (`rungs.zig`: the kernel exists **and** `price.calibrated`). Widening a capability therefore arms nothing that was never measured - it makes the refusal legible, and mintable, instead of hiding a missing price behind a missing instruction.

  `lanes.native`, one NEON bool, became `lanes.widest: ?Width` plus `armed(w)`. One bool could only answer for the narrower width by lying about the wider: the 16-lane composition is a single 16-byte table lookup, which is `tbl` on NEON and `pshufb` on SSSE3 - `shuffle` has had both arms all along - while the 32-lane form needs a lookup across a register pair that SSSE3 has no equivalent for at any width. Every SSE machine was running a kernel it held the instruction for through the scalar oracle.

  `plane.on_neon` became `plane.vectorized`, on the same reasoning and with a measured floor. The transposition is three rounds of even/odd byte de-interleave and three delta swaps - `@shuffle` and shift/xor, portable Zig - so what differs per target is what it compiles to, and for one 128-byte block that is 178 instructions on NEON, 245 under AVX2, 292 under SSSE3, and 398 at SSE2 baseline. NEON wins because `uzp1`/`uzp2` *is* the de-interleave; SSE2 has to emulate it with `punpck` chains. 1.6x is a rung with something left to sell against the DFA, 2.2x is emulation, so the line sits at the byte permute - the same instruction the 16-lane arm draws its own line at, so there is one answer to "is there a shuffle unit here" rather than two that can drift.

  Both predicates now ask `cpu.has` rather than the architecture, which also closes a build that never produced an artifact at all: NEON is an optional AArch64 feature, and an arch-shaped gate in front of `shufflePair`'s feature-shaped `@compileError` meant any `-mcpu` profile without SIMD failed to compile rather than falling back.

  `zig build check-linux` and `check-windows` grew an `x86_64_v2` row each, because the arms this admits were compiled by no query in that table: baseline prunes them to their portable legs and the AArch64 host builds the NEON leg instead. The arms we ship to the most common target in the world were reachable from no gate on no machine, which is how the original conflation survived as long as it did. The full suite now also executes on x86-64 SSSE3, not merely type-checks there - `lanes`, the Parabix transposition against its scalar oracle, and the Compose differential all run on the instruction rather than beside it.
- Every README in the repository, all 118 of them, was audited against the
  source it documents and rewritten wherever it disagreed. Most of the drift
  traced to one cause: this package split out of Billy's monorepo, and the prose
  kept describing the shape it had before the move. The root `README.md` still
  named `regex_dfa` and `matcher` as sibling top-level exports, which retired
  when the engine consolidated behind one `regex` door; `vendor/README.md`
  pointed at a `libsais` path and a `zig build codex-scale` command that never
  existed; `tools/whatwg/README.md` and `tools/ucd/README.md` credited a sibling
  project's decoders for tables this engine's own kernel and corpus build.

  Real fixes beyond the split: `contract/README.md` now documents `exports.toml`
  and `contract/irregex.zone`, both born after the last time anyone touched that
  file. `quality/surface/README.md` described a deprecation-schedule table shape
  that isn't how `check.py` actually diffs `[removed]` entries against the last
  release tag. `src/kernel/regex/oracle/README.md` and the root `README.md` each
  cited a fixed differential case count for the composition, symbolic, and
  one-pass rungs - numbers that appear nowhere in the tree as constants, because
  the generators are randomized against an asserted floor rather than a fixed
  total. Both now cite the floor the test actually holds the build to. The
  `ladder/`, `shuffle/`, and `oracle/` accelerator docs had each drifted from
  `price.zig`'s live calibration independently, in three different directions,
  and no two of them agreed on the composition rung's own measured speedup until
  this pass traced all three back to the same reference run.

  Every table became a bulleted list, every bold-lead paragraph became a real
  heading, and every number left standing was checked against a committed source
  rather than an earlier draft's memory of one.
- Parabix is now priced as two costs instead of one. `Calibration` gained
  `parabix_base` beside `parabix_op`, and the scan model reads
  `parabix_base + parabix_op x (stripe_ops - transpose_ops) / stripe_width`
  rather than one slope through the origin.

  Every admitted program pays the same transposition to get the bytes into bit
  planes - `104 x plane.stripe` operations, now named `admit.transpose_ops`
  instead of living as a literal inside `stripeOps` - and then pays for the
  marker operations its pattern actually asked for. The old model summed those
  two into `stripe_ops` and fit a single slope through zero, which forces one
  number to stand for two costs with different physics. The fit then splits the
  difference: it over-charges the programs that are mostly transposition and
  under-charges the ones that are mostly markers.

  The two coefficients are not close, and they are not in the same proportion on
  both cores. On Raptor Lake the transposition is the dearer half by a factor of
  five (`1.208` against `0.223`); on the M4 they are near parity (`0.492` against
  `0.543`), because `tbl` does in one instruction what SSSE3 spends a sequence
  on. A single slope cannot express that, so the same arithmetic that read
  correctly on one machine had to read wrong on the other - which is the whole
  argument for a per-core calibration restated as a bug.

  The auction found it rather than the arithmetic looking suspicious.
  `\b[a-z]{4}[0-9]{4}` was priced 29% dear on x86 and lost to a fallback that
  measurement says it beats. That is what the regret gate is for: a model can be
  wrong in a way no coefficient looks wrong, and only the pick reveals it.

  `probe.separate` was generalized from the two-point line it had been to an
  ordinary least squares fit over N points, since separating an intercept from a
  slope needs more than two observations to mean anything. Both callers that were
  already passing two points get the identical answer - for `n = 2` the fit is
  the line through them. The mint now arms a slate of eight programs and fits
  across whichever of them the target can actually build.
- ShellCheck failed CI over `bench/apparatus/field.sh`, flagging `SCOPE` and
  every `HAVE_*` availability flag as unused. Both are true and neither is a bug:
  `field.sh` is vendored byte-identical across irregex/gist/relate/blast
  (`bench/apparatus/SHARED.sha256`), and only gist's own
  `bench/dominance/races/field.sh` sources it to build a rival-tool roster -
  irregex mints no races of its own to read them back. ShellCheck cannot see a
  downstream sourcer analyzing a file in isolation, so the same false positive
  gist's `.shellcheckrc` already carries for this exact file is now disabled
  here too, with the same reasoning recorded beside it.
- The Go vendoring matrix declares `-lm` on both Linux targets, so its link probe
  links the way a consumer's cgo build links.

  The two sides had drifted: `link_linux_amd64.go` and its arm64 twin carry
  `-lm`, while the matrix declared no library there, and the parity check added with
  the Windows targets refused to vendor a Linux archive until the two agreed. The
  archive really does need it - `exp` and `log` come out of the cost model
  undefined, and libm only merges into libc in glibc 2.34, well past the 2.17 these
  targets pin. What hid it is the same thing that hid `-lntdll`: `zig cc` links
  libm silently, so a probe that leaves it out closes anyway and proves nothing
  about the gcc that will actually perform the link.

  Reconciled toward the link file rather than away from it, because the link file is
  the one a consumer runs.
- The Rust install instructions named a package nobody can install. Both the
  binding README and the root README's Install section still said `irregex =
  "0.1"` and "a path or git dependency" - the former is an unrelated 2023 crate
  and the latter had not been true since the crate went to crates.io as
  [`irgx`](https://crates.io/crates/irgx) 1.0.0. Copying either got you a
  resolution error at best and a stranger's code at worst.

  Both now say `cargo add irgx`, and the Install section explains once why the
  name differs per registry rather than leaving three spellings unaccounted for:
  PyPI keeps `irregex` because it was free, crates.io takes `irgx` because it was
  not, and the import is `irgx` either way.
- The measurement instruments now compile to their documented wall-clock fallback on non-macOS targets instead of analyzing unavailable dynamic-library operations.
- The settled-pattern differential now reuses its immutable compiled queries across haystacks, preserving all 2,000 adverse cases while avoiding 24,000 redundant compilations.
- The software prefetch in the SIMD literal scan is now a named per-target policy
  in `simd.streamAhead`, and it is declined on x86-64.

  The block loop hinted eight vectors ahead on every core, which was measured on
  an M4 and never re-measured anywhere else. On Raptor Lake it costs **1.29x**
  (0.0450 against 0.0349 tick/B, `Qzxjvw` over 8 MiB, min-of-24 round-robin after
  warmup, pinned to a P-core). The L2 streamer recognizes a sequential stride
  immediately and the loop is issue-bound, so the hint buys a ramp that already
  happened and pays for it in slots.

  That single coefficient is why the exact literal kernel was losing to a bare
  `memchr` on x86 - `settle_literal_one` at 0.092 against `skip_scan` at 0.069
  cyc/B - and it cost the auction a 1.32x regret on `Qzxjvw`, which is how it
  surfaced. A kernel written to beat `memchr`, shipped losing to it on the most
  common target in the world, because a constant tuned on a laptop rode along.

  It was measured over many small documents as well as one large one, since the
  obvious defense of a prefetch is that it only pays on a cold stream the
  hardware has not learned yet. It does not pay there either.

  The hint stays on aarch64, where it was measured, and the roofline bench is
  what re-prices it. Both the kernel and `bench/bounds/roofline` now call the
  same function instead of each spelling the policy out, so a benchmark cannot
  measure a loop the engine does not run.
- Towncrier ran with `wrap = true`, which is right for one-line release notes and
  wrong for the multi-paragraph Markdown the fragments here actually are. It
  reflows each entry as one flat block, so a fenced code sample lost its fence, a
  hanging `-` at the end of a wrapped line became a setext heading, an inline code
  span got split across a paragraph break, and the `*` that fell to the start of
  the next line was read as a bullet. The v1.0.0 fold surfaced 25 markdownlint
  findings that were all the same bug wearing different rule numbers.

  Off, the fragment's own layout survives and towncrier only indents it. Three
  fragments that were relying on the reflow - a broken `len >= 16 * k * budget`
  span, an indented `pshufb` sample, and four `*` bullets in a document whose
  other lists are dashes - are corrected at the source, so the fold is clean
  rather than patched afterwards.
- `Munch.longestAmong` takes a permission set, and until now that set governed
  what the walk **recorded** and never how far it **ran**. The walk ran until the
  union automaton died, and a union of sixty-four patterns dies where the last of
  them does - so one wide member kept every narrow one walking. Ask a slate for
  `return` at a position where `[^'&]+` is also alive, and you paid for `[^'&]+`
  to reach end-of-file before being told about the six bytes you asked for.

  The old premise is in the doc comment that shipped, and it is true:

  > a forbidden pattern may still be on the path to a permitted longer one

  It is just not the whole rule. A forbidden pattern is worth following only while
  some *permitted* one can still reach an accept. Past that point no number of
  remaining bytes can produce a reportable match, so stopping is not an
  optimization with a correctness argument bolted on - it is the same answer,
  reached without the walk that could not have changed it.

  So a `Dfa` now carries `reach`, one `u64` per state saying which patterns still
  have an accept ahead of them, and the walk exits on `s == dead` **or**
  `reach[s] & permitted == 0`. It is built at freeze by a worklist fixpoint over
  reverse edges, only for an attributed automaton; single-pattern programs - which
  is most of what gist compiles - get no table and are not even asked.

  Two things about that fixpoint are load-bearing and neither is obvious. It
  unions successors over `trans_in` **and** `trans_fin`, because `trans_fin` is
  what resolves `$` and an accept can be reachable only through it, on the true
  last byte; an interior-only fixpoint would stop one byte short of an anchored
  accept, which is a wrong token stream rather than a slow one. And erring broad
  is free - a mask that admits too much only walks a little further - so where
  there was a choice it went that way.

  What it was worth, measured on outliner's javascript slate, where
  `unescaped_single_jsx_string_fragment` shares a voice with the keywords a
  statement parse asks for at nearly every position. Mean bytes walked per call,
  over a 128 KiB file:

  | grammar    | before   | after |
  | ---------- | -------- | ----- |
  | javascript | 16,322.6 | 1.9   |
  | java       | 78.5     | 1.8   |
  | json       | 3.8      | 2.4   |

  Call counts are identical to the byte on all three, which is the point: the
  answer never moved, only the distance traveled to reach it. Parsing that
  javascript file went from 34,776 ns/byte to 1,168, and the file that took 16.5 s
  takes 186 ms.

  The all-permitted caller was expected to be a no-op, since with every pattern
  permitted the test reduces to `reach[s] == 0`, which in a *minimal* automaton is
  the dead state and nothing else. These automata are not minimal, and the traps
  turn out to be worth having: with every terminal admitted, java walks 29% fewer
  bytes and json 25% fewer, for the same tokens. So it is a small win rather than
  nothing, which is the better half of the two answers that were available.

  The test pins the distance rather than the effect, because a walk that runs too
  far returns the same answer as one that stops - which is exactly why nobody
  noticed for so long. `munch.steps` counts bytes stepped under
  `builtin.is_test`, comptime-erased everywhere else, and the case asserts a
  keyword-only walk over a 4 KiB haystack costs under sixteen steps. Disabling the
  new exit turns that case red; without the counter it stayed green, which was the
  first draft.
- `Munch` determinized under `max_visits`, the same cost policy a search pays. Measured, that budget refuses `\w+`, `\p{L}+`, and `[_\p{XID_Start}][_\p{XID_Continue}]*` - respectively the most common token body in any grammar, and how five separate languages spell `identifier`. Each of them declined as `too_costly` and none as `too_large`, so nothing was ever too big to hold; the build was only judged too expensive to attempt.

  That judgment is right for the caller it was calibrated against - a pattern the user typed a second ago, run once against one haystack - and wrong by several orders of magnitude for a lexer slate, which is compiled once and then amortized over every byte of every file for the life of the process. Munch now builds unbudgeted. `max_states` is the safety bound rather than the cost policy and still applies, so the automaton stays bounded and the build still terminates; a group too large to hold declines exactly as before and the bisection narrows it.
- `isGenerated` read the first eight lines for a `Code generated ... DO NOT EDIT` banner. That works for the generators that stamp line one, and fails for every generator that carries its source contract's leading comment above its own banner - `protoc-gen-connect-go` puts a 24-line proto comment first, so the marker lands at line 26 and the file reads as hand-written.

  Now the header is the leading run of comment and blank lines, however long that is, and the old eight-line count survives as a floor for banners that sit just under a package clause. The scan still stops at the first line of real code, so a mention in the body is a mention, not a banner, and it is still capped at 2048 bytes.

  `isGeneratedPath` also learned `.connect.go` and `.connect.swift`, the two buf output names with no generator token in them. Callers holding no file bytes - the atlas-warm kinship verbs - get the demotion from the name alone.
- `libirgx` would not compile for any `-msvc` Windows target in zig 0.16.0,
  static or dynamic, whether or not a caller ever panicked. `std.Io.Threaded`'s
  vtable makes every method reachable the moment one instance exists, and its
  `netWriteFile` is `@panic("TODO implement netWriteFile")`-stubbed on every
  backend - so the mere presence of that vtable pulled the default panic
  handler's stack walk into the build. On the MSVC ABI that walk runs through
  `SelfInfo.Windows.zig`'s `loadNtdllProc`, which casts a `*anyopaque` to a
  function pointer without the `@alignCast` Zig itself now demands: a bug in the
  standard library, not in this engine, and one that blocks every `-msvc`
  target's static or object artifact regardless of whether the panic path is
  ever exercised at runtime.

  The artifact's root now declares its own panic namespace, `std.debug.
  simple_panic`, for `.msvc` only - message to stderr, then trap, no stack walk,
  no `SelfInfo`. Every other ABI keeps the default, fully symbolicated panic
  handler unchanged.
- `version_parity.py` discovers mirrors by walking for a marker rather than
  keeping a list, which is the right instinct - a mirror added next year is
  covered the day it is written. But a mirror is only guessed at: a line carrying
  `x-release-please-version` and a version number. Release notes defeat that,
  because their whole subject is versions and the machinery that moves them, so an
  entry describing a bot bumping the engine to `0.3.0` and naming the marker in
  the same sentence looks exactly like a stale mirror.

  `changelog.d` was already skipped for this reason; `CHANGELOG.md` was not, and
  nothing noticed until the 1.0.0 fold turned 237 fragments into one file. The
  second fault it raised was the tell that the rule was backwards: it wanted
  `CHANGELOG.md` added to release-please's `extra-files`, which would have the bot
  rewriting past releases' numbers. Towncrier owns that file and the bot is
  deliberately kept out of it, so the notes are now skipped before and after the
  fold.
- `zig build` now installs `libirgx.dylib` / `libirgx.a` at `ReleaseFast`
  regardless of the mode the rest of the build runs in, and `-Dlib-optimize`
  overrides that on its own.

  The default `optimize` mode is `Debug`, which is right for the test binary and
  for `zig build check`, and wrong for the artifact a host links. The Python
  binding loads the dynamic library, so a plain `zig build` handed it a Debug
  engine and nothing said so. Compiling `\w` cost 108 ms there against 2.6 ms in
  Go, which links the vendored archive and had therefore been optimized all along -
  a 40x gap that looked exactly like an engine problem in the Unicode class
  lowering, and was the build mode.

  A cache footgun is not a tuning knob. So the ABI artifacts get their own module
  tree at the shipped mode, while the module the tests and `check` compile keeps
  the caller's - the fast iteration loop stays fast, and what leaves the build is
  what a consumer should have.

## [1.0.0] - 2026-08-02

### Added

- "More mature" is now a number with a denominator ripgrep owns. `bench/rgsuite/surface.py` reads rg's documented flag surface at run time — longs from `rg --generate complete-bash`, shorts and value grammar from its man page — exercises each flag on a fixed miniature tree, and compares both binaries' stdout and exit code byte-for-byte. A difference only counts as conformant if it is a _declared_ boundary (gist naming itself, gist's superset type registry, gist's own palette) and its residual check passes this run; a rejected flag or an undeclared difference loses a point. An undo-pair lane covers the half a per-flag probe cannot see: most negations name the default, so a negation that silently no-ops looks correct alone — each pair places it after the positive flag it undoes on a fixture where the two answers differ. `bench/rgsuite/fuzz.py` is the third lane, generating invocations nobody curated (random pattern × composable flag set × a corpus built to be hostile: invalid UTF-8, NUL bytes, a 4 MiB line, a symlink cycle, an unreadable file, catastrophic-backtracking patterns) and demanding byte-identical agreement, with crash, hang, and peak-RSS measured in the same pass.
- **Interned AST** (`kernel/regex/ast/`): the pattern's shape hash-consed into a
  DAG over the new `kernel/math/dag.zig` substrate, canonicalized by the operator
  identities, and swept once for every synthesized fact at the same time. Compiling
  used to ask the parser's tree about fourteen separate questions, each a fresh
  recursion with no memo, and `requiredAny` was quadratic outright — it needed each
  node's mandatory literal to decide whether descending bought selectivity, and got
  it by calling `literalInfo`, which re-walked that node's whole subtree. Interning
  makes structural equality an integer compare, gives topological order for free
  (so a bottom-up analysis is a `for` loop with no recursion, stack or visited set),
  and raises bounded repetitions by squaring, so `a{1000}` is ~19 nodes rather than
  a thousand. One fold fills the literal facts, first-byte set, nullability, anchor,
  length bounds, star height and codepoint-class flag together; the next question
  costs a field, not a traversal.

  Re-association and the algebra are licensed by associativity and safe for every
  fact here, because each is a property of the flattened sequence rather than of
  the bracketing — but not for leftmost-first span selection, so `compile/` still
  lowers the parser's own tree and this stays an analysis structure. Held to a
  language oracle built from the semantics (not from either implementation), to
  per-walker agreement, and to a preservation invariant that canonicalization may
  only improve a fact.

  `compileOpts` now sources its required literal, its cover set and its anchor from
  one graph built in the arena it already holds (`linear/program/lower.zig`), which
  is the transfer the new `bench/rungs/sweep/` rung licensed: it races each consumer
  against its incumbent alone and bundled, classifies every disagreement against
  that question's own quality order, withholds the timing on any answer that got
  worse, and prints how many consumers must move together before the graph pays for
  itself. Asked one question the fabric loses by 30×; asked the two the planner
  actually needs it wins, and every consumer after that is free.
- **`--colors` now paints.** gist accepted ripgrep's color specs, validated their syntax, failed loud on a malformed one — and then discarded them, because gist paints a deliberate palette of its own. That is a fine answer for `match:fg:red`, which is taste, and the wrong answer for `match:none`, which is not: it is the only way to unstyle _one_ element, since `--color=never` is all-or-nothing. A caller who wanted path color without match highlighting had no way to ask.

  The full grammar is now honored — `{type}:none` or `{type}:{fg|bg|style}:{value}` over path/line/column/match, with named colors, 0-255, and `r,g,b` triples. Specs **merge into gist's defaults** exactly as ripgrep's merge into its own, so `--colors match:fg:blue` keeps the default's bold and underline and swaps only the hue, and specs accumulate in argv order so a later one wins its attribute. Two places gist differs on purpose: it renders one SGR sequence per element where rg emits a separate escape per attribute (`\e[1;4;34m` against rg's `\e[1m\e[34m`), and it paints column numbers only when a spec asks, because gist has never painted them and honoring a spec must not repaint an element nobody named.

  The palette rides `Opts`, resolved once at `seal`. `Opts` already reaches the serial engine, the swarm, and the daemon's facet renderer, so the four emitters learned a caller's specs without a single signature growing a parameter — and with no spec at all `resolve` returns the same four constants gist has always used, allocating nothing, so the default path cannot drift. That equivalence is a test rather than a comment: the defaults now exist twice, as constants and as merge attributes, and the suite pins them byte-for-byte.

  With this and the empty-hyperlink fix, the 446-case ripgrep differential mined from rg's own test suite reports **zero failures on both engines** — 409 PASS, 16 declared-divergence NA, 21 SKIP, supported-surface parity 100.0%.
- A determinizer stops when it runs out of **reachable** states, and reachable is not
  distinguishable. New `linear/automata/reduce.zig` collapses a finished dense table
  down to the automaton it means, and it owns **both** dimensions such a table is
  over-refined in: rows, where no suffix separates two states (Moore's refinement, i.e.
  the Myhill-Nerode congruence), and columns, where no state routes two byte classes
  differently. The order only runs one way and that is why they are one file rather than
  two passes a caller sequences — merging rows is what makes whole columns coincide,
  while merging columns can never create a row merge, because it does not change which
  suffixes distinguish a state.

  `symbolic/minimize.zig` is gone into it: the symbolic product carries a decoder phase
  the pattern cannot observe, so its rows are redundant by construction and
  `transcribe.zig` now asks for both dimensions in one call instead of running a
  minimizer and then a class merge of its own. Its floor got **tighter** rather than
  moved — the suite's `dfa.ncls <= byte.minimal_ncls` check now compares against the
  *reduced* byte class count, so the symbolic lane can no longer pass on the byte road's
  over-refinement instead of on what the language requires.

  **The byte road declines both passes, on measurement, and that is the interesting
  half.** `automata-rung -- reduce` prices each pass against the determinization that
  produced the table and then times the same walker on the raw and reduced tables, over
  three populations kept apart. Rows find 1 automaton in 32 for a geomean 19.4% of a
  build, because interning on the NFA-state *set* has already landed that construction
  near the Myhill-Nerode quotient. Forcing Unicode down the byte road is the shape that
  should have paid, and on the byte counts it looks like it does: columns collapse on 4
  trie rows in 5 for 0.6%, and `\w{3,8}` sheds a quarter of its states, a 1.0 MB table
  to 729 KB. **The walk does not notice** — every row whose table shrank scans inside a
  ±8% noise floor, which is claim C2's "area is free at constant touched breadth" holding
  one order of magnitude up from where it was measured.

  Two things the section had to fix about itself to get an honest answer. Five `\p{…}`
  rows had been compiled without `unicode`, built nothing, and been dropped by a bare
  `catch return` — so the one shape whose states are indistinguishable *by construction*
  had never been measured, and a row that will not compile now says so out loud. And the
  one row whose *states* collapse materially cannot be timed at all: `\w{3,8}` accepts
  any three word bytes, so no alphabet holding a word byte can spell a document it
  misses. It reports `matched` rather than a ratio earned on a prefix.

  The last residual is upstream of all of it. The single ASCII column merge is
  `(a|b|…|h){10}`, 9 columns to 2, and it exists because the lowering walks the parser's
  tree where that alternation is eight `consume` states — while `ast/algebra.zig` already
  knows an alternation of byte classes *is* a byte class. Folding it there gives one
  consuming set instead of eight and a determinization that is not the slate's third
  slowest at 59 µs for 11 states, none of which a post-hoc column merge recovers. Filed
  as its own claim rather than smuggled in here.

  The instrument stays, which is what makes the decline revisitable: the `reduce` section
  re-prices both passes and re-times both tables every run, so if a future lowering hands
  that determinizer a shape which does pay, the `scan` column says so.
- A fifth Zig ratchet, `isa-floor`, over the class of bug that put SSSE3 into a
  baseline wheel: an inline `asm` block selected by `builtin.cpu.arch` instead of
  `builtin.cpu.has`. It is the one codegen mistake nothing else in the stack can
  catch, because the compiler that would catch it is looking at a string.

  The rule is one finding per asm block whose mnemonic is not in a small exempt
  set and which no `cpu.has(` predicate covers between the enclosing `fn` and the
  block. A negated guard counts - a leaf that `@compileError`s off-feature has
  stated its precondition as clearly as one that branches.

  The exempt set is the interesting part. It holds mnemonics in their
  architecture's *mandatory* base ISA, where there is no optional feature to ask
  about, and it currently holds one entry (`add`). Everything else fails closed:
  an instruction nobody has classified needs a guard, so adding to the set is a
  one-line change that puts the claim "this needs no optional feature" in front of
  a reviewer instead of leaving it to silence.

  The baseline is empty, which makes this a floor rather than a burn-down, and an
  empty baseline is exactly the state where a gate can be quietly broken and look
  identical to a gate that is working. So the detector proofs run it against the
  verbatim pre-fix text of `lanes.shuffle` and require both findings back. Thirteen
  of them, beside the driver, in CI next to the scan.
- A one-pass capture engine. Most patterns never have two live alternatives, so
  their ε-closures determinize: `-r`/`--json` submatches for those now come from a
  small DFA that writes group offsets straight into the caller's slot vector,
  instead of the Pike VM's priority-ordered thread list with its slot copy on
  every `save`. It is a third arm of `Caps`, taken only when the pattern is
  provably unambiguous and falling back to the Pike VM otherwise — so which arm
  runs is a speed decision and never a semantic one, and the two are held to
  slot-exact parity by a randomized differential.
- A span search can now be bounded at both ends. `Window { hay, from, to }` says what to search and what to read while searching: `[from, to]` is the region a match may occupy, and `hay` is what every zero-width assertion (`^ $ \b \B \< \> \A \z`) still resolves against, end to end. `Regex.matchWindow` is the general form and `matchSpan` is the unbounded default, so no caller that doesn't ask for a bound pays for one. The distinction is the whole point: slicing a haystack to bound a search also moves its edges, so `$` and any look-around at the cut start answering a question about the slice instead of about the text — which makes a bounded confirm around a literal, an overlapping walk, and a half-match impossible to build out of slices without changing what the pattern means. Same separation rust-`regex` draws with `Input { haystack, span }`. The bound threads through all four span arms — the pure-literal SIMD scan, the span-exact class run, the caliper's two jaws, and the Pike VM — with the walk's ceiling moving and the text's edges staying put; `core_test.zig` pins both halves of that (a window equals a slice wherever the two must agree, and diverges exactly where assertions read the edges). `Matcher.matchWindow` returns a three-way `Verdict`, because the PCRE2 arm cannot honor a real bound without altering the semantics of its own assertions and says `decline` rather than answer a different question; `Matcher.windows()` states which engine can. Two tests, plus the caliper's differential fuzz now sampling five ceilings per span against the Pike oracle.
- A verification lane nearly certified this tree as immune to an environment
  variable on the strength of a run that never executed, so the trap is now written
  down in the README under "Build and test", where someone reaching for
  `-Dtest-filter` will actually meet it.

  The mechanism turned out to be the opposite of what I first assumed, which is
  half the reason it is worth documenting. My working theory was that environment
  variables are *not* part of Zig's build cache key, so a changed variable was
  being ignored. Measuring it says the reverse: they *are* in the key. `-Dtest-filter`
  reaches the harness as `BRIGADE_FILTER`, an environment variable set on the run
  step in `addShards`, and Zig hashes a run step's environment along with its argv.
  A new environment therefore always executes. What bites is the second visit -
  every environment you have already used has a durable cache entry, so going back
  to one replays it: step skipped, nothing run, exit 0 in about the time a no-op
  build takes.

  That is precisely the shape of an immunity probe. Run the suite with the variable
  set, then run it again without to confirm, and the confirming leg revisits an
  environment it has already been in - so it is a replay, and green by construction.
  The failure is in the third step of the experiment, not the first, which is why it
  survived review.

  The tell is not the exit code and not the test count. A cached run still reports
  `19/19 tests passed` under `--summary all`; the only thing that distinguishes a
  replay from an execution is the word `cached` where an executed step prints
  `success <n>ms`. Anything reading a test count as proof of execution is reading
  the wrong field.

  So the README now says to drive the compiled test binary directly for this class
  of question - it sits under no build-cache layer and executes every time - with
  `BRIGADE_TIMES=1` as the per-test evidence that it did, and a note that
  `--verbose` only prints the binary's path on a run that was not cached, which is
  its own small instance of the same trap.

  Measured rather than transcribed: A, B, A', B' over one probe variable gives
  `success 3ms`, `success 3ms`, `cached`, `cached`, all four exit 0 and all four
  claiming 19/19 passed. The same four legs against the binary directly execute
  every time. It reproduces identically in the gist package, which takes this
  harness from here.
- A walk that outlasts two seconds now reports its own progress on stderr instead of looking hung: elapsed time, directories walked and outstanding, and — on the first notice only — what would actually make it finish (dropping `-uu`, bounding the scope with a PATH argument). Later notices arrive on a doubling ramp, so a two-minute walk spends six lines rather than sixty. It rides the existing `GIST_HINTS` channel and speaks only when stderr is a terminal, so captured stderr stays byte-deterministic and stdout is untouched.
- Added **Windows** — all four of ripgrep's declared Windows triples now build from a macOS host with no cross toolchain, for all three faces (`gist`, `relate`, `irregex`), and three of them execute the full twelve-class conformance slate byte-identical to the native oracle. That closes the one half of "ripgrep is more portable" that was not a measurement problem but a missing port: the previous sweep scored 0 of 4, because gist's directory descent was `openat`/dirfd-relative all the way down and `openat` is the single POSIX primitive Windows has no spelling for.

  **One seam, not a `builtin.os` branch per call site.** `src/portal.zig` (exported as `irregex.portal`) is POSIX-shaped so the call sites read the way they always did, and states the difference in exactly one place: handle-relative open becomes `NtCreateFile` with `RootDirectory = dir`, which is the Win32 shape of the same idea; a whole-file map becomes `VirtualAlloc` plus an eager read, so the view still outlives the handle the way `mmap`'s does; `stat`'s mode bits become `NtQueryInformationFile` attributes plus a `GetFileType` device class, which is also what finally lets a pipe be told from a disk file on stdin; `realpath(3)` becomes `GetFinalPathNameByHandle` with symlinks already followed, degrading to `GetFullPathName` when the open is refused; and the argument list becomes a command-line string that must be _parsed_, so the iterator takes an allocator. Every fork is a `comptime` branch whose POSIX arm is the call it replaced, so the fifteen executed POSIX rows and Layers A–C are untouched by construction.

  **Two things degrade instead of blocking, which is why this fits in one pass.** The resident daemon wants a unix socket, `flock`, and `SCM_RIGHTS`; Windows has none of the three, so `portal.resident_sessions` is a `comptime` `false` there and the socket writer, the fd-passing receive, the shared-memory map, and the singleton lock each decline through it. The warm tier is an optimization the cold path never depends on, so a Windows build simply answers cold — and gating at the _entry_ rather than at each syscall keeps the whole listener graph out of semantic analysis instead of half-porting it. Pager advice is a no-op for the same reason it costs nothing: `madvise(SEQUENTIAL|WILLNEED)` batches faults the Windows arm has already paid by reading eagerly.

  **The evidence is labeled for what it is.** No Windows kernel is reachable from the measuring host, so the executed rows ran under Wine, and Layer H records them at a rung of their own — `conforms-wine` — sitting strictly above `runs` and strictly below `conforms`. The ceiling is declared per lane in `bench/targets/matrix.py` and read by the scorer at its last promotion, so a translation layer reproducing every byte cannot be rounded up no matter how clean it looks, and the certificate reporter fails closed if a Windows triple ever appears at the native rung. `aarch64-windows-gnu` builds and stops at `builds` with its reason recorded: Wine emulates Win32, not the CPU, so an ARM64 PE needs an ARM64 Wine host. Even so, an executed Windows row is strictly stronger evidence than ripgrep's own release pipeline produces for any of its targets, which verifies each with `--version` and never runs a search.
- Added **`--line-buffered`**, **`--block-buffered`**, **`--buffer-size`**, **`-p`/`--pretty`**, and the native **`--plain`** — and, behind them, a stdout **drain**: one place that decides _when_ result bytes leave the process, and in how many syscalls. Until now that was an unstated policy, and the wrong one at both ends: the serial engine held a whole run in one buffer and flushed it at exit, while the parallel engine paid one `write(2)` per file. A terminal wants a matching line the moment it is found; a pipe being fed ten thousand small files wants those fragments coalesced.

  ripgrep names the same two ends and implements them with the Rust standard library's writers. gist keeps both promises and pays less for each. Under **`--line-buffered`** no finished line is ever held, but every finished line already in hand leaves in **one** write — rg's `LineWriter` pays one syscall per line for the same interactivity, and the boundary here is the run's real terminator, so `--null-data` records flush on NUL (rg's line writer only ever knows `\n`, and holds NUL-terminated output until its buffer fills). Under **`--block-buffered`** the buffer _ramps_: the first fragment of a run is never held and the flush threshold then doubles from 1 KiB to the ceiling, so `gist … | head -1` still answers immediately and a closed pipe is discovered within a kilobyte, where a plain `BufWriter` holds the first byte exactly as long as the last. The ceiling is the caller's (`--buffer-size`, default 64 KiB — a Linux pipe's capacity); rg's 8 KiB is a constant. **`--buffer-size=0`** names the third cadence rather than degenerating into the second: nothing is held at all, each fragment goes straight through, which is what you want pointed at a slow producer and what neither of rg's two flags can say. Measured on `-n std src/` in this package — 1.04 MB of results, byte-identical to ripgrep's — writes counted exactly by giving the child a datagram socketpair for stdout, where message boundaries survive: `rg -j1 --line-buffered` 15,782, gist `--line-buffered` 342; ripgrep's default piped posture 342, gist's 23, and 11 at `--buffer-size=1M`. Time to first byte falls with the trip count rather than trading against it (5 ms against ripgrep's 9), because the ramp primes.

  Neither policy is allowed to change a byte or an order — only the trip count — and the drain is fail-open by construction: if its buffer cannot be allocated it stays in pass-through, so the worst outcome of an arming failure is the syscall count gist had before this module existed. Every exit seam settles it, including the fatal `die` path and the daemon's keep, whose carbon copy is taken at the syscall rather than at the emit site.

  `-p`/`--pretty` is rg's `--color always --heading --line-number` alias, routed through the same precedence machinery `--vimgrep` uses so a later `-N` still wins. **`--plain`** is its gist-native inverse and the flag rg has no answer for: it pins the answer to what a **pipe** would receive even on a terminal — no color, no long-line elision, coalesced — because gist has three destination-conditional behaviors and an interactive run that must reproduce a captured one should not have to remember and re-spell each of them.
- Added **clickable results** — OSC-8 hyperlinks across all three faces, so a match in iTerm2 / WezTerm / Kitty / Ghostty / VS Code's terminal opens at the right line in the right editor. ripgrep spends a dedicated printer module on this and still leaves it off unless you find the flag, ties it to nothing you can inspect when it silently does nothing, and — by its own help — **only writes a link "when a path is also in the output and colors are enabled"**. Both halves of that bite: one explicit file argument prints no filename, so rg has nowhere to hang the link and emits none, and a link into a pipe costs `--color=always`, which forces color into the pipe too — rg's documented colorless escape hatch still wraps every field in `ESC[0m`. The interesting work here was not the escape sequence; it was deciding when a link is a service and when it is corruption.

  **One axis, three spellings, and a default that is actually on.** `--hyperlink[=auto|always|never|<alias>|<format>]`, `--no-hyperlink`, and rg's `--hyperlink-format` all drive one value. The default is `auto`: links appear when a person is reading in a terminal on a roster of emulators known to _render_ OSC-8 rather than print its bytes, and disappear the moment the bytes are bound elsewhere. That roster is fail-closed — an unrecognized emulator gets plain text, because the cost of guessing wrong is escape soup in every result line. Links are deliberately **not** on the `--color` / `NO_COLOR` axis the way rg's are: a link is navigation, not paint, and a reader who turned colors off did not ask to stop being able to click.

  **Naming a destination on the command line turns links on.** Typing `--hyperlink=vscode` and getting silence because a probe disagreed is precisely the mystery this layer exists to remove. The standing-preference spelling is separate and quieter: `GIST_HYPERLINK` in a profile may carry a destination alone (`vscode` — says _where_, leaves the probe to say _whether_, so redirecting to a file still cannot smear escapes through it) or a `WHEN,WHERE` pair (`always,vscode`). A flag is an act; an environment variable is a preference. Two output shapes refuse every posture including `always`, because there the filename's bytes _are_ the payload: `--json` records and NUL-framed `-0` path lists, which exist to be read by `xargs -0`.

  **Free, on the measurements this tree can make.** No `realpath(2)` per file — rg canonicalizes each path, which costs a syscall and hands the reader `/private/var/…` for a `/tmp/…` they typed; gist folds one logical `$PWD` lexically per run (inode-verified) and keeps the click inside the tree the query named. Each file's URL is then split **once** into a `Waypoint` of literal chunks around the holes a row fills, so emitting a link is a few memcpys and a decimal write, never a format pass. Linking 93,175 matches — 12.4 MB of additional escape bytes — costs ~5.5 ms, about 60 ns each, inside the run-to-run noise of the unlinked run. With links off the output is byte-identical to ripgrep's: 3,889,733 bytes on a whole-repo query, verified across `-n`, `-l`, `-c`, `--vimgrep`, `--column`, `-A/-B`, and `--files`.

  **Every shape that prints a filename, and one refusal rg doesn't make.** Match rows, headings, `-l`/`--files` lists (sorted or streamed), `-c` counts, the binary notice, and — the one that matters most for a human — the `--rank` view, whose entire premise is that its top row is the file to open. Against that: a filename carrying a **control byte** declines the frame, because you cannot see where a click target starts and stops when the bytes between the escapes don't render — and a raw newline in a name splits the anchor across two terminal lines outright. The URL is still exact (`%0A`), and a locator made only of digits stays clickable; it is the _text between the escapes_ that is refused. rg frames those and emits the two-line link. On percent-encoding the two agree exactly: 87 URLs over an adversarial fixture tree of spaces, quotes, `#?&%+`, brackets, emoji, and CJK, zero differences.

  **Decoration is free against the truncation cap.** The output ceiling counts what a reader reads, not the escapes around it, so turning links or color on never costs a result. Under a deterministic order (`--sort path`) the surviving content is _byte-identical_ across frame sizes from 48 B to 3 KB per row — the same rows survive carrying 0 B of chrome and carrying 635 KB of it. Only order-stable runs can state that: gist's file walk is not deterministic by default, so the truncation point already moves on its own — 1001–1118 rows over fifteen identical _unlinked_ runs on a frozen corpus, against 984 every time under `--sort path`. Links widen that by nothing.

  **It works everywhere a path is printed, not just in gist's match rows.** `relate similar` / `echoes` / `pack` / `quote` and `irregex blast` / `provenance` link their rows too — including `path#L120` fragment labels, which carry the function's line into the URL. Beyond rg's alias table: `zed`, `windsurf`, `cursor-remote`, and `vscode-remote`, the last two solving a case rg has no answer for at all — inside a Remote-SSH session a plain `file://` URL points at a file the local editor cannot open. The format grammar is otherwise rg's exactly, validated against rg's own failure taxonomy, so a format it accepts gist accepts and one it rejects gist rejects with the same sentence. When nothing links and you expected it to, `GIST_TRACE=link` prints the single reason why — and it prints one in _every_ case, naming the posture (`turned off`), the reader (`output is a byte protocol`, `machine-shaped output`), or the terminal (`stdout is not a terminal`, `terminal does not advertise OSC-8`); a diagnostic that answers six times out of seven and goes quiet on the seventh is worse than none, since silence reads as "nothing to report". Lighting the lens is itself enough to hold a run off the warm path, which renders its own frames and has no beacon to explain. `gist --schema` publishes the full alias roster for agents.
- Added **persisted configuration**, split along the line ripgrep's `.ripgreprc` conflates: what the TREE is, versus what one reader likes to look at. The first is a committed `.irregex.toml` at the tree root — `roots`, `skip`, `types` — a strict typed-key grammar with no argv in it, discovered by climbing from the working directory and stopping at the repository boundary so a tree without its own declaration never inherits a parent's. It is the first home for facts that were previously stranded: the search roots lived in `GIST_ROOTS` (a per-shell environment variable nobody else on the team has) and the extra skip directories lived in `<GIST_DIR>/skips.list` (a gitignored artifact directory, deleted by every cache clear). Both are corpus facts, both are everyone's, and both now travel with the clone. The second layer is a machine-local preferences file (`$GIST_PREFERENCES`, else `$XDG_CONFIG_HOME/gist/preferences`) holding flag lines, prepended to argv so anything typed still wins.

  The reason this is safe where ripgrep's is not: **preferences apply only when stdout is an interactive terminal.** That is not a new rule invented for this feature — it is the envelope boundary gist already draws for the answer keep, the resident daemon, and color resolution. Riding the same line puts a pipe, a redirect, `--json`, a script, CI, the daemon, and every agent structurally outside the file's reach, so none of them needs `--no-config` to be sure of what it will get. The reason ripgrep had to invent that flag, and expects tooling to pass it, is that its file has no such boundary.

  Underneath both layers is a new **reach** axis on the flag catalog — `corpus` (which files and bytes the engine sees), `semantics` (which lines match), `presentation` (how the answer is rendered), `execution` (only how it is computed). It is exhaustive over every `Opts` field at comptime, so a new option is a compile error until someone says how far it travels. The committed layer is ceilinged at `corpus`: a shared file may say what the repository IS and may never quietly change what matches for everyone who clones it. Reach also rides each row of `gist --schema`, so an agent can tell which flags could change its answer without running anything, and a zero-match run whose flags came from a preferences file now says so on the coaching channel — the one cause a reader cannot see in the line they typed.

  Two smaller repairs of the same feature. Preference lines are **tokenized with shell quoting**, where ripgrep's are verbatim argv elements: `--glob '!.git/*'` in a `.ripgreprc` reaches the glob engine with its apostrophes attached and silently matches nothing, the single most-reported confusion about that file. And every flag is checked against the catalog as the file is read, naming the file — a typo is a loud error before the search rather than a mystery in its results. A line that does not begin with a flag is refused outright, because a stray bare word in a persisted argv file becomes the search pattern for every invocation forever. `--no-config` and `GIST_NO_CONFIG=1` ignore both layers; the flag is answered from raw argv before either file is opened, since a flag that suppresses a file cannot be learned from it.

  **The gate is checked before the file is opened**, which is a correctness property rather than an optimization. Reading first and faulting second would mean one person's typo failing every piped run, script, and agent in the tree with an exit 2 naming a path they cannot see — the exact action-at-a-distance the terminal gate exists to rule out. A malformed preferences file is now fatal only to a run that would actually have used it, while a malformed _charter_ stays fatal to any search, because a corpus nobody described is worse than no file at all. `gist status` and `gist config` report a broken file either way, so it can never be silently invisible to the person who has to fix it.

  Faults in both layers are **located and quoted** — `.irregex.toml:3: unknown key` — and carry a nearest-name suggestion drawn from the live catalog, so a flag added tomorrow is suggestible tomorrow with no second list to maintain. The distance is Damerau–Levenshtein: plain Levenshtein charges 2 for a transposition, the most common typing error there is, which would force a budget too loose to reject genuine non-matches. Two candidates equally near yields no suggestion at all, as does a mistyped short flag, where every candidate is equidistant and a guess would be a coin flip dressed up as help. Whether a fault is even _about_ a name is owned by the layer rather than by whoever is printing, via one `didYouMean(fault, token)` — pairing a bare "nearest" with a caller's own idea of which faults are name faults answered an unterminated string whose last token happened to be `skip` with "try `skip` — `skip` is not a charter key".

  Added **`gist config`**, the introspection ripgrep's configuration file has never had — its absence is why the standing advice for a surprising result there is "try `--no-config`", bisection standing in for the ability to ask. `gist config` prints the resolved stack: each layer's path, what it declares, whether it is in force, and any `GIST_ROOTS`/`GIST_SKIP` in the current shell that outranks the committed file (reported whether or not a charter exists — "my charter is ignored" and "I have no charter but roots are set anyway" are one confusion from two directions). `gist config check` validates both layers without running a search, reporting both before it exits so fixing a file takes one pass rather than one run per mistake. Both it and `gist status` keep describing the files under `--no-config` / `GIST_NO_CONFIG`, reporting suppression as a state of the run rather than an empty answer — a shell exporting it is exactly when a reader needs to see what is on disk, so the readers expose _what the file says_ separately from _what this run honors_. `gist config init` writes the charter prefilled from what this machine already carries, so the migration off the stranded state is not "learn the format" — it lifts only facts the user already asserted and never infers a skip from the shape of the tree, since a guessed skip silently hides files, which is the failure the whole layer exists to prevent.
- Added `src/assay/`, the package's instrumentation floor — one dependency-free module (`std`-only, beneath all three query tiers) that owns the three concerns previously held together by convention: timing, counting, and gated diagnostics. `span.zig` makes the two clocks non-interchangeable — `Span`/`Duration` ride the monotonic-awake clock (the only thing that renders as `ms`) while `Anchor` rides the wall clock (the only stamp `fresh.writeAnchor` accepts), so a monotonic reading can no longer masquerade as a freshness anchor. `tally.zig` replaces the near-duplicate `json.Stats`/`grepfile.Stats` with one comptime-schema'd `Tally(Schema)` counter set plus an allocation-free vector `fold` for the parallel engine's per-worker → run merge. `channel.zig` centralizes the `GIST_*` env vocabulary and routes every diagnostic through a thread-local sink: the C-ABI/in-process session scopes `.dark` (making the never-write-stdout/stderr contract structural instead of a 90-site audit), the daemon scopes `.buffer` and ships captured bytes back over the protocol (so a warm `--rank` is now as measurable as a cold one), and the cold CLI keeps `.stderr`. The four bare-presence trace vars (`GIST_AMEND_TRACE`/`GIST_JOURNAL_TRACE`/`GIST_RECONCILE_TRACE`/`GIST_DEBUG_WARM`) collapse into one `GIST_TRACE=<lens>,…` list plus `GIST_TRACE_FORMAT=text|json`; a `--json` run's stderr diagnostic is now one NDJSON record parseable next to the stdout results, and `--stats`/`--json` `elapsed` fields carry real monotonic time instead of a hardcoded `0.000000`. The ~25 open-coded `nowNs`/`ms` pairs across the engines and the whole `bench/` harness now share these primitives; the duplicate `nowNs` in `args.zig` and `api.zig` is gone.
- Added the **analytic FFI plane** — the kinship, retrieval, sweep, and composed verbs now reach non-Zig hosts over the C ABI instead of only over `stdout`. Before this, `gist`'s exact search had an in-process seam while every `relate` / `irregex` verb was reachable only by spawning a CLI and parsing NDJSON, so each of the three bindings hand-mirrored the same seventeen result shapes with nothing able to prove they agreed: fifty-one structs, three JSON parsers, and a fork per query.

  The surface is deliberately **eight symbols for seventeen verbs**, because a verb is a `u32` op plus one of five declared params families (`kinship` · `retrieval` · `sweep` · `compose` · `rank`) rather than a symbol of its own — so the next verb costs no new C surface at all. `irgx_analytic_run` dispatches and materializes a cursor; `irgx_rows_next` / `_next_batch` / `_stats` / `_close` walk it; `irgx_schema_digest` / `_count` / `_get` expose the row table a binding decodes against. Results cross as ONE self-describing `irgx_row` — a schema id plus a flat `irgx_value` array — whose field order, tags, and enum ordinals are declared once in `contract/search_api.toml` (`[row_enums]` · `[row_schemas]` · `[analytic.params]` · `[analytic.verbs]`) and lowered by `make gen-gist-schema` into the engine's table and one decoder per binding, drift-gated by `gen-verify`. `Row.present` is a bit per field because absence is not zero — `distance = 0.0` means _identical_, so a row that spelled "no distance" as zero would report a stranger as a twin. Enums cross as ordinals, never labels, so a variant a binding predates is reported unknown rather than mis-named, and the whole table's digest is a startup check: a shared library that drifted from a decoder fails loudly instead of mis-reading rows.

  Two lifetime and safety properties are stronger here than on the exact plane, deliberately. An analytic answer is materialized whole into one cursor arena — `clusters` cannot know a component before it has seen every edge — so rows, nested rows, and texts stay valid until `irgx_rows_close`, not merely until the next pull, and a batching host can hold every batch it pulled without copying. And `params` is narrowed through one size- and flag-checked seam, so handing `pack` a kinship struct is `IRGX_INVALID` at the boundary rather than a pointer read out of an `f64`'s bytes.

  Verbs graduate into the plane one at a time behind that frozen ABI: `patterns` and `pattern_counts` answer in-process now, and every verb still to land returns `IRGX_STALE` — the ABI's _this tier declines, answer through the fallback_, the same fail-open contract the exact plane uses for a pattern outside linear syntax. That is what lets the bindings adopt the FFI once and gain each verb without changing a line, instead of re-plumbing their transport when the last verb lands.
- Added the **conjunctive cover planner** (`src/kernel/query/cover.zig`) and **Layer L**, the certificate layer that settles one specific accusation: _"your trigram index is csearch-class, not better."_ csearch is the acknowledged ancestor, so the answer had to be a measurement against the real thing, on the axis that actually defines an index. That axis is not wall time — wall time confounds the index with the walk, the IO and the matcher, and any of the three can win a race the index lost. It is **filter quality**: the candidate bytes a query admits before anything reads a file.

  **The comparison holds everything fixed except the formula.** One corpus, one built index, one evaluator, one verifier — and csearch's arm is _csearch's own formula_, lifted verbatim out of `csearch -verbose` by `bench/sieve/csearch_plan.py` and replayed against gist's postings. Not a reimplementation and not a proxy, because a reimplementation of a rival's planner is exactly the artifact nobody should believe. A third `gist-base` arm carries the pre-Layer-L planner, so every improvement is attributable rather than merely present, and the harness fails closed if the three arms ever disagree on a verified hit count.

  **What the old planner got wrong was arithmetic, not parsing.** It found the one longest required literal and stopped. But a pattern usually proves _several_ mandatory runs at once, and their conjunction is strictly stronger than the best of them: `if\s+err\s*!=\s*nil` proves `if`, `err` and `nil`, and intersecting three postings admits 25.4% of the corpus where the single best admits 74.3%. So the cover keeps every mandatory run, cross-products small classes into whole literals instead of stopping at 3-byte boundary trigrams, reads `x?` as the finite set {ε, x} so `https?://` factors into `http://` and `https://` rather than the trigrams that straddle the `?`, and slides a window along runs too large to cross-product so a UUID prefix still yields its dash-straddling clauses.

  **The planner proposes; the evaluator disposes.** Every sound clause is emitted, and `Index.queryPlan` — which knows real posting cardinalities and the size of the candidate set so far — orders them by cost and _declines_ the ones whose decode costs more than scanning what they would remove. Emitting more work for the cost model to reject turned out to be the point: a clause that pays on a corpus-wide query is a waste on a set already down to 400 documents, and only the evaluator is standing where that is knowable.

  **Measured, over twenty classes — the certificate's own twelve, reported first and unedited, plus eight planner-stress shapes.** gist admits **10.5% fewer candidate bytes** than csearch (1.949 GB vs 2.177 GB), winning six classes and losing none, from a **3% smaller index built 6.4× faster**. The two decisive rows are the ones a syntactic planner cannot reach: on `0x[0-9a-fA-F]{6}` csearch proves nothing at all (`query: +`, 100% of the corpus) where gist admits 16.9%, and on `\d{4}-\d{2}-\d{2}` csearch takes one dash-straddling window where gist conjoins all three. Eight of the twelve certificate classes cannot separate two planners at all — four are single-literal and four are structurally unfilterable — and they are published as ties rather than quietly dropped.

  **And it is wired, so the win is the product's and not a harness's.** `gate.winnow` builds the plan from the effective pattern under the same `arm.linearOptions` the matcher compiled with — one derivation, so the plan cannot disagree with the engine about what `-i`, `-U`, `--no-unicode` or an inline `(?-u)` mean — and `elide.askIndex` puts it to the index ahead of the flat OR, which remains the fallback for every decline. Multi-`-e` needs no special case: the engine already combines patterns into one alternation, and the planner emits a clause only where _every_ branch forces one, so an unplannable pattern widens the candidate set for the whole run rather than narrowing it wrongly. `-F` stays on the literal path, and PCRE2 keeps its engine-neutral literals rather than a cover read off a grammar it does not use. On the real corpus the wired path admits **41.8% fewer candidate bytes** across the default-flag slate (551 MB against 946 MB), which is **1.33× end-to-end** on the classes it narrows — against a 1.03× noise floor measured on the classes where the candidate set is byte-identical.

  **Soundness is the fixed point, not the variable.** The index may only elide reads, so `matched ⇒ never pruned` is brute-forced against the production matcher over an exhaustively enumerated document space in `cover_test.zig`; `bench/sieve/cover_parity.sh` then holds the wired binary to a byte-identical line multiset against its own pre-wiring prefilter, its own `--no-index` read, and ripgrep, over 21 cases on a frozen real-source corpus; `bench/gates/index_elision_parity.sh` stays green; and the reporter refuses to splice a win it cannot substantiate — a per-class regression, an arm disagreement, a wired path that admits more than the prefilter it replaced, or a selectivity gain bought with a pathologically bigger or slower index all exit non-zero and write nothing.
- CI never ran the formatter. It compiled the engine, ran the tests, ran the three
  binding suites and ran the four ratchets, and in none of that did anything ask
  `zig fmt` what it thought - so `zig fmt --check` was failing on committed code
  and there was no way to find that out short of typing it yourself.

  The drift that exposed it is worth describing, because it is not the kind you
  catch by reading a diff. A rename shortened a string inside a column-aligned
  multiline array literal. `zig fmt` pads those into a grid, so shrinking the
  widest cell leaves every row beneath it one space too wide, and the rows that
  move are in files nobody edited. Two test files were sitting wrong. The
  embarrassing part is that Rust here already runs `cargo fmt --check` and
  `cargo clippy -D warnings` on every push; Zig is the language this repository is
  written in and was the one with no formatting gate at all.

  So there is a sixth job, `fmt`, rather than a step bolted onto an existing one.
  Formatter drift is its own kind of news and has earned its own red X - folding
  it into `engine` would run it once per host for a verdict that cannot vary by
  host, and folding it into `ratchets` would put a Zig toolchain into the one job
  that deliberately has none. It pins the same `ZIG_VERSION` the engine builds
  with, because the formatter's output is a property of the compiler release and a
  gate on a different Zig checks a different grid.

  The file set is enumerated from git rather than written down, since a
  written-down path list drifts the same silent way the formatting did: the
  invocation I caught this with by hand named `tools`, which holds no Zig at all,
  and would have sailed straight past a new top-level directory that did. Tracked
  plus untracked-not-ignored is every Zig file this repository owns. What it
  leaves out is the ignored trees - `bindings/rust/target`, where cargo parks a
  whole semver-checks copy of this repo, and `zig-pkg/` - and those are named in
  `.gitignore`, where someone can review them, rather than being whatever happened
  to fall outside an argument list.

  I watched it go red before believing it: a deliberately mis-padded grid literal
  in a throwaway file fails the job and names the file, and deleting the file
  passes it again.
- CI now runs the whole suite a second time under an environment that disagrees
  with it, so a test that quietly reads the operator's machine fails here instead
  of on someone's laptop.

  This exists because the class it catches is invisible to every gate we had.
  Fourteen tests were reading the ambient skip overlay - fourteen, at once, all of
  them green on a clean box and red on a configured one. Nothing in `zig build
  test`, `zig fmt --check`, or the four ratchets can see that, because the code is
  correct and the suite passes; what is wrong is that the suite passes for a
  reason it never stated. The only instrument that finds it is running the tests
  somewhere the assumption is false.

  So the new `hermetic` job runs `zig build test` twice, once with `GIST_SKIP`
  naming the twenty-three directory names a real checkout is most likely to
  contain, and once with a `<GIST_DIR>/skips.list` holding the same list. Both,
  rather than one and an argument that the other is equivalent, because they are
  separate vectors into the same overlay and only the first names a skip in a
  variable - a fixture could lean on the file without any environment variable
  mentioning it. A charter `skip` is the third vector and is not covered here,
  since it lives in the tree rather than around it and a hostile one would have to
  be committed to have any effect.

  One host, because the defect is reading the environment and not the platform.
  It cannot share the engine job's cache: Zig keys the cache on the environment,
  and the environment is exactly what moves, which is the cost of the job and also
  the reason it genuinely re-runs instead of replaying a green.

  Proven to have teeth rather than assumed: over a tree holding `src/a.txt` and
  `other/b.txt`, a plain `gist -l` finds both, and each of the two vectors on its
  own finds only `other/b.txt`. A job whose hostile environment the engine ignored
  would be green forever and prove nothing, which is the failure mode worth
  checking before trusting a gate that is supposed to stay quiet.
- Codegen is something you can turn from the command line instead of by editing
  the build graph. Zig ships no rc file and rejects `-mllvm` on purpose, so
  `build.zig` is the only configuration file there is; three of the four tiers of
  LLVM control now have names on it, and the fourth is documented rather than
  folklore.

  `-Dframe-pointer` keeps the chain a sampling profiler walks, which ReleaseFast
  otherwise throws away (a no-op on aarch64-darwin, whose ABI pins the register
  regardless). `-Dlto=thin|full` turns on cross-language inlining over the Zig↔C
  seam for the shipped libraries and the lab executables; it is off by default
  because it moves real optimization work into the link that every edit then pays
  for. On a Darwin target it refuses outright and says why, rather than letting
  the driver fail three steps later with "using LLD to link macho files is
  unsupported" - LTO needs a link-time pass pipeline, only LLD hosts one, and Zig
  links Mach-O itself. Cross-compiling is unaffected. Both knobs live in one value
  that every module and artifact is handed, so one added later cannot silently
  miss them.

  `zig build ir` is the new instrument: one object, three views of the same
  compilation into `zig-out/llvm/`. The post-pipeline `.ll` answers what vector
  width a rung really got and which call did not inline, the `.s` is what
  `bench/bounds/port/mca.sh` already hands to `llvm-mca`, and the `.bc` is the
  handoff to an external `opt` and back in as an input file, which is the only way
  to run a pass pipeline of your own choosing. `-Dir=<file>` picks the root; the
  default is the C-ABI surface rather than `src/root.zig`, because Zig analyzes
  lazily and a library root that exports nothing lowers to nothing.

  `CONTRIBUTING.md` gains the tier below all of that - `-fopt-bisect-limit`,
  `--verbose-llvm-cpu-features`, and the bitcode round-trip - since none of it has
  a `std.Build` surface to hang an option on.

  It also records the option that deliberately does not exist. `-fno-llvm` reads
  like the last tier, and on x86_64 the self-hosted backend really is the quicker
  debug path, but on aarch64 in 0.16 it is not: three lines of Zig whose only
  weight is `std.debug.print` take 0.91 s through LLVM and 175.7 s without it,
  and the warm run is the slower of the two, so nothing amortizes. That is a trap
  with an inviting name, so it gets a table and a recheck-on-Zig-bump note
  instead of a `-D` flag somebody would reasonably set.

  One latent trap went with it: the ReleaseFast library twin the production rungs
  compile against was missing the engine's `build_options`, so a lane that touched
  `version_string` would have failed on a missing import rather than on anything
  it did.
- Every SIMD kernel here had a scalar oracle and a differential against it, and
  three of them were proving less than they looked like they were proving. The
  pattern is the same each time: a build compiles one arm and comptime-prunes the
  rest, so a test that goes through the front door only ever exercises whichever
  arm the host happened to have.

  **The shuffle primitive.** `lanes.shuffle` has three arms - NEON `tbl`, SSSE3
  `pshufb`, and a portable gather - and the portable one was reachable from no
  test on no machine. CI runs macOS/aarch64 and Linux/x86_64-native, and the
  shipped artifacts declare floors (`aarch64` baseline, `x86_64_v2`) that carry
  one of the two instructions; the arm that a `-Dcpu=baseline` build, a distro
  rebuild, or any third architecture actually executes had never run. It is now
  `pub fn shufflePortable`, compiled on every target, and `lanes_test.zig` holds
  the host's real instruction to it - so two CI hosts pin all three arms to one
  statement, because each asm arm is proved against the same shared reference.
  Three layers: hardware against portable over the in-range domain; an
  independently written restatement against both, which is what keeps the test
  honest on a build where those two are one function; and a characterization of
  where the arms disagree above index 15, so "these all do the same thing, drop
  the check" cannot pass review by being plausible. The 32-lane `shufflePair` gets
  the same treatment where NEON exists, and skips loudly where it does not.

  The in-range precondition is now asserted rather than documented, in
  `lanes.shuffle` and in `classrun.pshufb` (whose contract is the opposite one -
  truffle *relies* on the zeroing). Out of range the arms do not agree, so a
  caller that drifts does not get a wrong answer, it gets a different wrong answer
  per architecture, which no single-host test can see. The assert is live in every
  safe build and free in ReleaseFast, so the whole existing differential corpus
  now doubles as a probe for it. Nothing tripped, which is the answer I wanted.

  **The compose rung's own kernel differential.** "The vector fold equals the
  scalar definition" compared `lanes.run` against `lanes.reference`. Off AArch64,
  `run` dispatches to `runPortable`, and `reference` *is* `runPortable` - so on
  every Linux CI run it compared a function to itself and reported two thousand
  agreeing cases having proved none of them. It drives `runNative` now, which runs
  anywhere for the 16-lane width and, on SSSE3, exercises a `pshufb` composition
  production never reaches. The case count is asserted per target so a silently
  halved corpus shows up as a moved number.

  **The whole-buffer sieve.** `sheng.survivesDoc` cuts a buffer at newlines,
  advances four shuffle chains in lockstep, folds per-lane accumulators and
  finishes each remainder from the state its lane reached. No test called it. The
  one doc-grain test drove the per-line entry over 64-byte buffers, and the lane
  split needs 256 bytes to engage at all. There are now three: a randomized
  differential against the scalar oracle over multi-line buffers, a sweep that
  plants a derived positive at every offset so tails and cut-straddling matches
  are covered by construction rather than by hand-computed offsets, and a geometry
  pass over the split's three ways to decline. Each asserts a floor on
  `sheng.lanesEngaged`, a new predicate that asks the kernel whether it took the
  lane path, because a corpus of too-short buffers passes while executing nothing.

  **The JSON escaper.** `jsonstr.nextEscape` scans for the next byte needing an
  escape with a vector block loop and a scalar tail. Its two tests ran on 11-byte
  and 4-byte strings, and `vlen` is at least 16 everywhere, so the block loop had
  never executed. Three differentials now sweep length by plant-offset by start
  across the block/tail seam - the width is target-chosen, so the seam moves per
  build and cannot be probed with a fixed fixture - plus a random pass over every
  byte value and an end-to-end check of `write` against a byte-at-a-time escaper.

  All of it is mutation-verified rather than assumed. A one-lane rotation in
  `shufflePortable`, a one-byte-short tail in `docLanes`, and a narrowed control
  test in `nextEscape`'s vector arm: each is caught, and for the escaper the two
  pre-existing fixture tests pass through the bug the three new ones catch, which
  is the blind spot stated as a measurement.
- Every job in CI judged the code. Nothing judged the surface a stranger actually
  arrives at - the README, the fragments, the manifests, the workflows themselves.
  That is a strange gap for a repository whose whole pitch is that it explains
  itself, and it had been quietly collecting drift the entire time.

  So there is a `discipline` job now, and a matching set of checked-in configs:
  markdownlint for layout, typos for spelling, yamllint and taplo for the
  configuration that is executable here, editorconfig-checker for the byte shape
  underneath both, shellcheck for the bench scripts, ruff for the Python, and
  zizmor for the Actions perimeter. golangci-lint went into the `go` job instead,
  where the toolchain it needs is already standing up. It is one job because it is
  one kind of news, and it is a separate job because none of it needs Zig - a
  mistyped heading should cost you seconds, not a matrix build.

  It was not clean. Twenty-one code fences carried no language, so nothing was
  syntax-highlighting them and nothing had noticed; a comment in `scan/lanes.zig`
  had drifted into British spelling; `bar.py` zipped two lists it had just proven
  equal-length without saying `strict=True`; and twenty-two Python files had never
  been through the formatter that now gates them.

  The workflow findings were the ones worth having. Twenty-seven actions were
  pinned to a movable tag, ten checkouts left the repository token sitting in
  `.git/config` for every later step to read, and the release job - the one job
  whose output gets published - was restoring a cache any workflow on any branch
  can write to.

  One trap deserves writing down, because I walked into it before the gate did.
  Pinning an action to a commit is the standard advice, and `git ls-remote --tags
  --refs` looks like the way to get one. It is not: `--refs` strips the peeled
  `^{}` entries, so for an annotated tag you are handed the *tag object's* hash
  rather than the commit it points at. GitHub answers `No commit found for SHA`,
  and the workflow fails to resolve before it runs a step. Take the `^{}` line.

  `ruff` skips `*.gen.py`. A generated table is its generator's output, and
  `tools/build_schema_tables.py` does not emit the shape a formatter wants - left
  alone, the two gates would each demand the file the other rejects. The generator
  holds a contract, so it wins, and its own `--check` is what guards that file.
- Every one of these repositories has shipped a `deny.toml` since the crate existed, and not one of them ever ran it. Four checks were written down and none enforced: a RustSec advisory against anything in the graph, the banned crates that would mean a regex binding grew a TLS stack or an async runtime, the license allowlist, and which registries a crate may come from. A policy nobody runs is a policy nobody has.

  So `cargo deny check` is a step in the `rust` job now, on a prebuilt binary rather than the Docker action - that action takes a repo-root-relative manifest path and the checkout layout differs in every repo here, so a plain step inheriting the working directory is both shorter and harder to get wrong.

  It passed first try in all four, which is the good version of this news and also exactly why it needed wiring: nothing was wrong, so nothing would have said when something became wrong. One thing needed saying out loud. The allowlist is a policy - the licenses this project accepts - not a snapshot of today's graph, so most entries go unmatched and cargo-deny warns once each. Shrinking the list to silence that would invert the point, because the next permissively-licensed crate would fail and get fixed by widening the list again, one entry at a time, with nobody deciding anything. `unused-allowed-license = "allow"` says that instead.
- Four Zig lint gates that used to live in the monorepo this package was extracted from now live here, under `quality/ratchets/`. They only ever scanned this tree; leaving them behind would have left four gates guarding a directory that no longer exists.

  A ratchet counts one debt pattern per file and compares against a committed `.baseline`. It fails when a count goes up, which means a new file must be clean and an old one may only shrink. That is the whole trick, and it is what lets a gate ship over a codebase that does not satisfy it yet: the debt is written down per line instead of being either ignored or blocking. The baseline is never raised to go green; `--refresh` is for recording a floor you just lowered, never for silencing a red gate.

  The four: `oom` holds out-of-memory to the one canonical exit, so a fix cannot land in one spelling and miss its twin. `dup-helper` catches the same substantial `fn` body copy-pasted across two files, which is the same parity bug one level up. `fault-taxonomy` reads `[fault_domains]` out of `contract/engine.toml` at run time and flags any error name production Zig mints that is not a declared member; it is what keeps the closed vocabulary closed. `assay-bypass` catches a `std.debug.print` that goes around the `assay` channel and writes to an embedding host's real stderr.

  Running them is `python3 quality/ratchets/run.py`, optionally with a name. Stdlib-only, no dependencies, no Zig toolchain, no build step; a new gate is a new directory, since the runner discovers them structurally rather than from a roster. CI got a fifth job that runs the four gates and then the detectors' own unit tests - a ratchet that quietly stopped detecting reports a clean tree, which is the one failure it cannot self-report.

  Two of the four are red on arrival and I left them that way, because reseeding a baseline from the current scan is how a gate stops being a gate. `dup-helper` found three bodies copy-pasted across five files - `wallNowNs` in the two watcher backends, `thinner` in `analysis.zig` and `ast.zig`, and one body wearing two names as `uclassLiteral`/`litOfUclass`. `fault-taxonomy` found nineteen undeclared names in two files: sixteen of them are `sheaf.zig`'s `error.Declined`, which is a declinature riding the error channel and belongs in `fault.Answer(T)`, and three are Windows mapping faults in `portal.zig` that need either a domain or a mapping onto members that already exist. Both are small local fixes, and the gates go green when they land.

  Two things came over changed. The shared Zig lexer was a shim onto the monorepo's `ward` package; it is now a real implementation here, because the two copies scan disjoint trees and can never disagree about the same file. And three rows of the `assay-bypass` baseline pinned files that left in the ecosystem split rather than being cleaned up - the daemon client and `grade.zig` went to `gist`, `kinship.zig` to `relate` - so they were dropped on arrival. Dropping a row for a file this repo does not contain can only tighten the gate.
- Layer H — the executed portability matrix. `bench/targets/` cross-compiles gist
  for every triple ripgrep declares in its own release workflow, plus targets it
  publishes nothing for, **from one machine with no cross toolchains installed**,
  and grades each by what was actually proven rather than by what links:

  - `builds` — an artifact exists _and_ its own ELF/Mach-O/PE header reports the
    promised format, architecture, width, and endianness, so a build that silently
    fell back to the host fails here instead of passing;
  - `runs` — that artifact executed on a machine of that architecture (native,
    Rosetta, or a foreign-arch container) and answered a real query, including a
    PCRE2 lookbehind the linear engine cannot represent — so serving it proves the
    vendored C cross-compiled too;
  - `conforms` — all twelve of `bench/harness/probes.zig`'s query classes came back
    byte-identical, exit codes included, to a native oracle that is itself pinned
    byte-for-byte to a real `rg` on the same corpus, in **both** the live-scan and
    the indexed pass.

  The indexed pass on a big-endian target is what caught the bug this harness was
  worth building for: `@bitCast`ing a `@Vector(16, bool)` compare to a movemask
  follows target endianness, so on s390x lane 0 landed in the high bit and `@ctz`
  reported every match fifteen bytes from where it was. `kernel/math/bits.zig`'s
  `laneMask` now owns that conversion behind a `comptime` endian branch — 25 call
  sites across the scanner, class-run scanner, and regex prefilter — and
  little-endian builds lower to exactly the bare `@bitCast` they did before.

  Sweeps are hermetic against the coworker agents editing this tree: the package
  and its path dependencies are frozen once, compile-checked for the host's own
  triple, and every target is built from that recorded digest, so all rows describe
  one identical set of bytes. A build failure whose diagnostics also break the host
  is scored `tree-broken` rather than mistaken for a port gap.

  `bench/certify/certify_portable_report.py` splices the layer and is fail-closed:
  it refuses to publish unless every POSIX triple ripgrep declares is covered, the
  Windows gap is disclosed, the oracle was pinned to a real `rg`, and at least one
  _cross_ target conformed.
- Matching a byte-class DFA as a REDUCTION rather than a pointer chase. A
  transformation Q→Q is a |Q|-byte vector and composing two of them is one
  AArch64 `TBL`, so a chunk's per-byte transformations fold in a tree and only
  one shuffle per chunk stays on the critical path: **2.26 B/cycle against the
  shipped eager DFA's 0.335** over 206 MiB of the host corpus, byte-identical
  over 350,200 differential cases against the Pike VM. It is a decider — it
  declines at compile time above 31 states, under a `\b` word context, off
  AArch64, and below any armed literal skip, where retiring every byte loses
  6.7× to a `memchr` that touches almost none. `lanes.zig` is the shareable
  byte-shuffle primitive, importable without the rung.
- Multi-tier **literal-set engine** fronting the ladder (`scan/literal_set.zig`):
  a single dispatcher that decides a whole line or buffer in one pass with no
  automaton. Zero/one-needle patterns take a rare-byte / `memchr` / `memmem` scan;
  up to 64 literals go through grouped Teddy (the SIMD prefilter, widened from 8 to
  64 buckets); above 64, a sparse Aho–Corasick automaton. It answers a `Presence`
  or `Position` with `exact` or `candidate` authority — an `.exact` set (the
  pattern _is_ this alternation of literals) decides the match outright, while a
  `.candidate` (a cover union or a required literal) is a necessary condition, so a
  miss rejects the haystack before any rung runs and a hit falls through unchanged.

  Lowering builds it from the pattern's extracted literals and declines gracefully
  past its capacity (`../regex/linear/program/lower.zig`); `verdict.zig` consults
  it at the top of every boolean entry point, ahead of the class-run kernel and the
  accelerator tier. Byte-identical to the Pike VM on the sets it accepts.
- Nothing was checking the news fragments, and the way that fails is nastier than
  it sounds. `towncrier build --draft` does not complain about a filename it cannot
  parse; it just does not treat it as a fragment. So a file typed `.fixd.md`
  instead of `.fixed.md` renders nothing, exits 0, and stays invisible until
  somebody notices the entry missing from a release. With getting on for two
  hundred fragments queued in `changelog.d`, that is a lot of surface for one typo
  to hide in.

  I checked whether `--draft` on its own was the right gate before writing one, and
  it is not. Against the real fragment set it is completely blind: a typo'd type, a
  file with no type at all, a wrong-cased `.Fixed.md`, and an empty type all give
  exit 0 with stdout byte-identical to a clean run and nothing on stderr. Adding
  `--draft` alone would have been a green tick over exactly the defect it was
  supposed to catch, which is worse than no job because it reads as coverage.

  The strictness has to come from `ignore` in `towncrier.toml`. Setting that key
  flips towncrier from skipping unparseable filenames to failing on them, with a
  message naming the file and telling you to whitelist it if it was deliberate. The
  two names it whitelists here, `README.md` and `.gitkeep`, are the only
  non-fragments the directory is meant to hold. That is the right place for the
  rule: the fragment grammar stays in towncrier's hands instead of being re-spelled
  in a filename parser inside the workflow, the same reason `fmt` takes its file set
  from `git ls-files` rather than a path list. It also means a contributor running
  `towncrier build --draft` locally gets the identical error CI does, which a
  CI-only check would have missed.

  `towncrier check` is deliberately not what this runs - that verb asks whether a
  branch added a fragment, which is a contribution policy and a different argument.
  This job only asks whether the fragments that exist are well-formed.

  There is also a guard against the job passing over nothing, in the same spirit as
  `fmt`'s "found no .zig files": a misconfigured `directory` renders "No significant
  changes." and exits 0, so the job fails if fragments are sitting on disk while
  towncrier reports none. It is conditioned on fragments actually existing, so the
  honest empty draft right after a release still passes.

  Proven the whole way round: green on the real tree, exit 1 naming the file when I
  drop a `.fixd.md` into a faithful copy, green again once it is removed, and exit 1
  on the vacuous-green case when the fragment directory is pointed somewhere empty.
- On-demand determinization (RE2 / rust-`regex`'s hybrid DFA) beneath the eager
  one. The subset construction moved into `kernel/regex/linear/dfa/subset.zig`, and
  `powerset.zig` and `lazy.zig` are now two policies over that one core, so they
  cannot disagree about what a pattern means; the Pike VM stands behind both as the
  oracle. The eager driver runs first and freezes an immutable shared automaton,
  and what it declines is determinized one visited state at a time into a
  per-thread cache that quits to the Pike VM rather than thrash.

  The bill this removes was paid before a byte was ever read: `\w+X` determinizes
  to only 332 states, but every closure runs over the ~10³-state UTF-8 trie that
  Unicode `\w` (137,936 codepoints in 748 ranges) lowers to, so the eager walk
  spent ~18 ms discovering a small automaton — on every invocation, since compiled
  patterns are not cached across runs. Unicode-class patterns now compile 4.4-11.9x
  faster (`\w+\s+\w+\s+Holmes`: 45 ms → 3.8 ms).

  Determinization is metered in NFA-state visits rather than states or closures,
  which is the unit that actually costs time (measured linear at ~2-3 ns/visit
  across a 100,000x range) and the only one that separates the two families:
  ordinary ASCII patterns cost ~40-100 visits per state, Unicode-class ones ~26,000.
  `max_visits` is a calibrated cost policy, waived by `force_dfa` so the
  differential oracles reach the DFA on every pattern they generate; `max_states`
  remains a hard safety ceiling no caller may lift.

  The on-demand driver derives its own start-state acceleration from the start row
  alone, which costs `2 x ncls` closures no matter how large the automaton behind
  it is. Without it a 1000-branch alternation walked all 332 MB of a corpus that
  the Pike VM's first-byte skip flew over, losing to it by 2.2x; with it the same
  pattern beats the Pike VM, and a 3000-branch one by 1.5x.
- Parabix-style bit-parallel within-document scan rung for AArch64: byte-to-bit transposition, character classes compiled to boolean circuits over the bit planes, and MatchStar closure over 1024 positions at a time. A compile-time decider — it refuses nested Kleene, codepoint classes, and any pattern a cheaper machine already serves — measured 2.1-3.4x the shipped ladder on the admitted family and byte-identical to the Pike VM.
- SP-quotient sieve: a two-valued rung that harvests the substitution-property
  partition lattice of a pattern's DFA and runs a conjunction of ≤16-state
  quotients as a register-resident `tbl`/`pshufb` prefilter. It answers `.miss`
  (proven no match) or `.unproven`, never `.hit` — an over-approximating quotient
  can refute a match but never confirm one. Sound over 1.52 billion corpus
  byte-positions with zero violations; the kernel runs 2.4–5.8× the scalar
  transcription of the same automaton, and the one pattern the gate arms on the
  lane slate finishes its whole ladder in 2.24× the shipped engine. Arms only when
  a training-free compile-time selectivity estimate says the pre-pass pays and
  nothing above it is already skipping bytes.
- Selector quality is now a measured dimension of the benchmark suite instead of a
  property nothing in the suite could name.

  The anchor-pair collapse that just got fixed was running inside the certificate the
  whole time and no row reported it, because every literal probe was labeled by how
  many true matches it had — `rare` or `common` — and that single label carries two
  independent costs. `pgxpool` was the only "rare literal", and it is a lucky needle:
  `pg` is a genuinely rare digraph, so it selects a good offset pair and looks fast.
  The whole class was represented by its best case. Meanwhile the degenerate needles
  *were* being timed (`func`, `error`) but wore the label `common`, so their slowness
  was charged to true-match volume rather than to the prefilter failing. The suite
  could not distinguish "slow because there is real work" from "slow because the
  prefilter collapsed", and that is the only reason a 41% inversion survived in a
  shipped binary with a benchmark suite pointed straight at it.

  So `select` now names the prefilter's signal rather than the match count:
  `selective` (a discriminating rare byte exists), `degenerate` (every byte ties, so a
  marginal-rarity selector has nothing to choose on), `head-rare` / `tail-rare` (one
  rare byte at a known end). Eight new rows in the CLI-shape matrix and seven new
  classes in the no-index scanner lane fill it in: a degenerate low-match trap
  (`stepSec`) against a length-matched well-selecting control (`pgxpool`), same-class
  runs over each byte class that ties (`dialect`, `PENDING`, `1234567`, `}));`), and a
  `zeroing` / `dataviz` pair carrying the same rare byte at opposite ends so an
  implementation that quietly prefers one end of the needle has somewhere to show up.
  A degenerate needle with few matches is the load-bearing one, and the reason is
  narrow: there is no real work to blame its slowness on, so only the prefilter is
  left. All 27 shapes hold parity (gist-idx == gist-noidx == rg).

  The trap is only readable as a ratio against its control, and only from pairwise
  interleaved samples — that caveat is written into both probe sets because it is easy
  to get wrong in the direction of a false alarm. Whichever needle is timed first pays
  a colder page cache, worth ~10-15 ms on a ~190 ms cell, which is enough to cross the
  alarm line: back-to-back blocks on a healthy binary gave 1.031 with the trap first,
  0.984 with the control first, and a cold start reached 1.384 — indistinguishable
  from the 1.41 defect signature. Interleaved against each other, the same binary is
  1.007. Dividing two rows of a results table is not a measurement of this.
- Span extraction (`-o` and everything built on it — `--count-matches`, `--column`, `--vimgrep`, `--json`, `-w`, colored highlighting) is now determinized instead of interpreted. The Pike VM was the only general answer to _where_ a match lies, at roughly forty times the boolean DFA's per-byte cost because every byte re-closes every live thread. The new `linear/caliper/` package closes two jaws on the extent instead (RE2 / rust-`regex`'s construction): a **forward** leftmost-first walk records where a match ends, then a **backward** anchored walk over the reversed Thompson program (`reverse.zig`, built from the same lowering so no second parse can disagree about the pattern) records the leftmost start reaching that end — two table walks over the match region, no thread list, no per-state offset map. The determinizer (`automaton.zig`) is the one part a boolean DFA could not supply: a state is an **ordered list** in priority order rather than a bitset, because `a|ab` must report `a` and `a+` the whole run, and dedup-on-pop plus a strict priority DFS keeps a state at the rank of its best thread; reaching `match` abandons the rest of the worklist (match dominance), and the unanchored re-seed is suppressed once a match is committed, which together are exactly leftmost-first. Both jaws share one transcription of `^ $ \b \B \< \>` with the boolean DFA — `subset.passes`, extracted from `subset.close` — so the two tiers cannot drift on what a pattern means. Eligibility is decided at compile time and the caliper is simply absent otherwise: multiline (`-U`) stays on the Pike whole-buffer walk, and a pure-literal or span-exact class-run reduction still wins ahead of any automaton. Determinization is lazy and **quitting is a first-class answer** — an oversized pattern sets `quit` and the Pike span, still the oracle, answers that line. Proven by a differential sweep against that oracle (20,000 generated pattern/haystack pairs, 0 divergences) and at scale by byte-identical `-o` output across 2.3M spans on eight corpus-wide patterns, with span counts equal to ripgrep's. Measured on the host corpus (163 MiB, 16,458 files, warm index): `[a-z]+_[a-z]+_[a-z]+` 651 ms → 212 ms (user CPU 1849 ms → 661 ms), `[A-Z][a-z]+[A-Z][A-Za-z]*` 913 ms → 512 ms, `[a-z]+\.[a-z]+\([a-z]*\)` 344 ms → 152 ms, `[A-Z_]{4,}` 681 ms → 412 ms — 1.7×–3.1× wall, 1.7×–2.8× CPU. Boolean search never consults the caliper and is unchanged (65.6 ms vs 68.5 ms user CPU), as are compile cost and sparse-span queries.
- Sub-trigram substring tier — a 1- or 2-byte needle is now answered from the
  trigram directory that already exists instead of forcing a full corpus scan, and
  it adds **zero bytes to the index**: a sliver must sit inside one of its
  document's trigrams, so the union of the trigram families that could contain it
  over-approximates the answer. Documents too short to own a trigram are carried
  in a rescue set proved from the crest sidecar, so under-pruning stays the only
  possible failure mode.

  The two classes the certificate recorded at cand% = 100% — the whole corpus
  admitted — now prune: `})` falls to 49.18% and `panic|0x` to 37.42% of corpus
  bytes delivered to verify. The alternation cover in `requiredAny` no longer
  withholds itself when a branch is sub-trigram, which is what sent `panic|0x` to a
  full scan. Measured by `zig build scale` and certified fail-closed as Layer J.
- Symbolic (predicate) alphabet for the regex determinizer. A pattern whose Unicode classes would make the byte determinizer re-walk a ~10³-state UTF-8 trie on every closure is now determinized over minterms instead, then crossed with a UTF-8→minterm decoder back into the same byte-class DFA — same scan loop, same table size. `\w+X` costs 92 NFA-state visits to discover instead of 8,386,778, and reaches an eager table where the byte path declined to the on-demand tier. Declines to the byte path for anything the alphabet cannot express exactly; `Options.symbolic = .off` pins the old path as the differential oracle.
- The Go binding reaches the whole kernel, and no longer needs a compiler to do it. It was the furthest-behind face: one 405-line file, exact search only, cgo-or-nothing — so every kinship, retrieval, and composed question was unreachable from Go entirely, not merely awkward. The analytic plane is what closes that gap, and the binding is now six packages along the one-way edge `contract ← runtime ← {exact, relate, compose, index}`: all seventeen analytic verbs, exact search, the artifact lifecycle — two transports, one decoder. **The decoder is the load-bearing piece and there is exactly one of it** — `runtime.Assemble` walks `schemas[id-1]` positionally over the value array rather than switching per verb, so a new row schema in `search_api.toml` costs a regenerated table and no Go code at all. It honors the presence mask as a first-class distinction, which is not pedantry: `distance = 0.0` means _identical_, so `Row.Float` returns `(0, false)` for absent and `(0, true)` for measured-as-zero, and no sentinel can collapse the two. An enum ordinal the contract does not declare arrives as `Known: false` carrying the raw number — the one honest answer when a library is newer than its binding — and `rows:` fields recurse into child rows of their own schema, so `blast`'s six sections and `quote`'s phrases decode through the same path as a flat kinship row. **The subprocess transport is new; Go never had one.** That is what makes `CGO_ENABLED=0` a first-class mode rather than a degraded one: `runtime.Run` prefers `irgx_analytic_run` in-process and falls through to the certified `gist`/`relate`/`irregex` child, and the two tiers are held to producing the same rows by a differential test rather than by assertion. Every reason a tier steps aside is a **declinature, not an error** — `IRGX_STALE`, a library with no analytic plane, a pattern outside the linear-time engine, no cgo at all — so the ladder descends and the caller sees rows; only a real fault (a malformed pattern, a canceled context, no binary anywhere) is an `error`, and `IRGX_NO_FFI=1` forces the child tier for a host waiting on a rebuild. Because the analytic exports are additive, the cgo preamble gives each of them a **weak definition**, so a library predating the plane still links and `irgx_schema_digest()` returning NULL is the probe for its absence; a digest that is present and _disagrees_ fails loudly as `DriftError` naming the schema that moved, never as a silent mis-decode. Two ergonomics are deliberately Go's rather than shared: `NextBatch(dst []Row)` and `NextBatch(dst []Match)` fill a caller's slice straight off `irgx_rows_next_batch`, keeping the hot path free of per-row garbage, and a `context.Context` is wired to the `irgx_cancel` token by a watcher goroutine, so a deadline is the scan's wall-clock budget and a cancel stops an in-process scan cooperatively and kills a child. `rows_stats` is surfaced whole — `Foreign` is what separates "your text isn't in this repo" from "no results", and `Omitted` is a budget admitting it trimmed the tail. Above the runtime, each verb package answers in its own vocabulary rather than handing back generic rows: graded `Neighbor`s and whole `Cluster` families, `Pack` picks carrying marginal bits and coverage, a `Blast` split into dependents / dependencies / twins / ripple / mentions, and an `Atlas` that reports the codex shelf separately because `quote` and `provenance` need that one specifically. Scope refusal came along too — the composed verbs reject an unscoped query instead of silently sweeping `vendor/`. Verified by 37 tests, green under both `CGO_ENABLED=1` and `CGO_ENABLED=0`, with the decoder's expectations derived from the generated contract table (including a synthesized-row suite for absence, unknown ordinals, and nested recursion) and the verb suites checked against a real built binary over a planted corpus.
- The Linux shared object was 79% debug info - 9.24 MB of DWARF sitting on
  1.51 MB of `.text` - and the only lever against it was `-Dstrip`, which answers
  the size question by destroying the answer to every other one. There is a rung
  between the poles, it is now a named option, and on a released ELF target it is
  already on. `-Ddebug-compress` puts each `.debug_*` section behind a
  `SHF_COMPRESSED` header the debugger inflates on demand: 11.72 MB becomes
  4.83 MB with every DWARF byte still readable.

  The default is `zlib` and `zstd` is the ask, which inverts how the two codecs
  rank on the merits. `ELFCOMPRESS_ZSTD` has been in the generic ABI since 2022
  and is better than zlib on ratio, compression speed, and decompression speed at
  once, which is the finding it was standardized on - and it loses here on the
  only axis a default is decided by, which is who can read it. An older reader
  does not degrade on a zstd section, it refuses it, and the floor is gdb 13.2,
  binutils 2.40, elfutils 0.189, LLVM 16. So the default takes the 59% of the win
  nobody can be broken by and `-Ddebug-compress=zstd` takes the rest, at 4.57 MB.

  It is honest about where it does not reach: ELF only, link-time only, and
  release only. Link-time only means `libirgx.a` is the same bytes either way,
  because an archive is never linked. Release only is not a policy - LLD's
  compressor walks the output sections through a `parallelForEach`, and on the
  29 MB of DWARF `-ODebug` emits for this library it faults in a worker thread,
  `SIGSEGV`, no diagnostic, nothing written. ReleaseSafe (4.90 MB), ReleaseFast
  (4.83 MB), and ReleaseSmall (1.37 MB) all compress cleanly, so the default
  stands itself down at `-ODebug` and an explicit flag there is refused with the
  reason rather than left to crash the linker.

  `-Dstrip` gains the thing it always needed. A stripped artifact has no DWARF and
  therefore no identity - two builds of different commits are the same anonymous
  bytes, and a crash in a `pip install`ed wheel cannot be traced to what produced
  it. It now carries a `sha1` build ID note, the 20-byte shape `debuginfod`, the
  distro debug-file splitters, and the symbolizers were all built around, for
  36 bytes of section. `-Dbuild-id=` overrides in either direction.

  Both are refusals rather than degradations when they cannot work, joining the
  one `-Dlto` already had, because a link-time flag that does nothing still exits
  zero: an operator who asked for a 4.57 MB library and silently got an 11.72 MB
  one has no way to find out. `-Ddebug-compress` off ELF says so, `-Ddebug-compress`
  next to `-Dstrip=true` says the two contradict, `-Ddebug-compress` at `-ODebug`
  names the crash it would otherwise hand you, and either flag now also asks for
  LLD explicitly - Zig's own ELF linker takes the compression flag and emits
  uncompressed sections without comment.

  One thing that was never a flag stops pretending to be. The vendored C floor was
  built with a raw `-fno-sanitize=undefined` cflag countermanding the UBSan Zig
  had just turned on for it; the same decision is now `.sanitize_c = .off` on the
  two C modules, stated where Zig owns it. PCRE2's pointer and shift idioms and
  libsais's negative sentinel indices are deliberate and well-defined in practice,
  and both must fail as a clean Zig error rather than a sanitizer abort inside C.
- The Rust binding reaches the whole kernel, and the borrow checker is what keeps it honest. It could previously answer exactly one question — where a pattern occurs — and everything else was out of reach; the analytic plane closes that, and the crate is now six modules along the one-way edge `contract ← runtime ← {exact, relate, compose, index}`, mirroring the Python and Go faces. All seventeen analytic verbs are wired: kinship (`similar`/`dups`/`clusters`/`echoes`/`concepts`/`fragments`/`distinct`), retrieval (`recall`/`pack`/`quote`), the multi-pattern sweep, and the composed four (`context`/`family`/`provenance`/`blast`). **There is exactly one decoder and both transports lower into it** — it walks `SCHEMAS[id-1]` positionally rather than switching per verb, so a new row schema in `search_api.toml` costs a regenerated table and no Rust at all. Absence is modeled as absence: `distance = 0.0` means _identical_, so a field the presence mask does not set reads `None` and no sentinel can collapse the two, and a value array shorter than the schema reads as absent rather than out-of-bounds. An enum ordinal past this build's append-only table stays a raw `Variant` reporting `name() == None` — the one honest answer when the library is newer than its binding — and `rows:` fields recurse, so `blast`'s six sections and `quote`'s phrases decode through the same path as a flat kinship row. **The Rust-specific ergonomics are the point of having a Rust face**: a `Row` is a borrowed view into the cursor's arena, so the compiler — not a doc comment — is what stops one outliving the next pull, `to_owned()` is the explicit deep-copy exit, and `Rows::batches(n)` hands back `Batch<'_>` values whose lifetimes let several coexist while still being invalidated on schedule. Rows are validated once, on arrival, which is what makes every accessor afterwards infallible rather than another `Result` for the caller to thread. `irgx_rows_stats` is surfaced whole — `foreign` is what separates "your text isn't in this repo" from "no results", `omitted` is a budget admitting it trimmed the tail, and `tier` says whether the answer came live, from the atlas, from the codex shelf, or out of process. Every reason a tier steps aside is a **declinature, not an error**: `IRGX_STALE`, a library predating the analytic exports (probed with `dlsym`, so an old `libirgx` still links), or a build without the `native` feature all descend to the certified CLI and produce the same rows; only a real fault is an `Err`. The one loud refusal is a schema-digest mismatch, which walks the engine's own `irgx_schema_get` table to name the schema or field that drifted rather than mis-decoding a row that changed shape underneath us. The composed verbs refuse an unscoped query instead of silently sweeping `vendor/`, and the resident-session client was brought up to protocol v7 (relaying a warm query's diagnostics to stderr the way the CLI client does), which restores the warm/cold round-trip parity test. Three real defects fell out of testing against the certified binaries rather than against the implementation: grade banding read its distance table from the weak end, so a distance of `0.0` — _identical_ — graded as background and `min_grade` filtered out the one exact match in the answer; the subprocess tier read the per-verb summary from stdout only, silently zeroing `foreign` and `omitted` for every verb that prints its summary as a diagnostic; and a subprocess drain could block forever after its child exited, because the engine self-spawns the resident daemon and that grandchild inherits the write end of the pipe, so EOF never arrives — the drain is now bounded by a grace period on bytes that were already written. Verified by 88 tests — decoder expectations derived from the generated contract table over synthesized wire buffers (absence vs zero, unknown ordinals, nested recursion, non-UTF-8 refusal, batch partitioning), digest-drift naming against a synthesized engine table, subprocess lowering against lines the CLIs actually print, an end-to-end analytic suite driving the real `relate` binary over a planted corpus, and a contract-parity suite asserting every schema, verb, enum, grade band, and channel polarity against `search_api.toml` — with `clippy -D warnings` clean and no `unwrap`/`expect` outside tests.
- The automata ladder has a column that looks like a free 1.13x, and I went to collect it. Four of the eleven rows want the twelve-lane peeled walk; `Dfa.docMatch` dispatches four lanes for all eleven. The four that want twelve are exactly the four that wander, `seen` of 9, 9, 33, 65 against 1 or 2 everywhere else, so "dispatch twelve when the automaton wanders" reads like it is sitting right there.

  It is not there, and the reason is worth keeping. Those four rows are the four whose fill happens to be drawn from their own pattern's class, which is what drives them across states; the seven that park have a fill picked to contain nothing their first class accepts. `seen` is not a property of the automaton, it is a property of the automaton *and the document*, and the table was quietly conflating the two because every row pairs one pattern with one fill.

  So the ladder now carries `burst_control`: those same four patterns over a document their class rejects. Same compiled program, same state count, same mirror, same byte-indexed table size, everything a freeze-time predicate could possibly read is identical. They park (`seen` 9, 9, 33, 65 all collapse to 1) and every one of them flips from winning **~1.18x** on twelve lanes to losing **~1.31x** on them.

  That is the whole answer. A per-automaton predicate here is not underdetermined by a small sample, it is unavailable at any sample size, because the label is a function of bytes the predicate never gets to see. Eleven automata are not too few; eleven thousand would not help. I shipped no dispatch change and no threshold. What I shipped is the four rows that stop the next person from spending a day on it, and the note in `dfa.zig` saying the gap belongs to a working-set-aware walk at run time rather than a better guess at freeze time.
- The boolean ladder gained an **accelerator tier**: the optional machines that
  beat the byte-class DFA on the patterns they accept, behind one interface
  (`linear/ladder/rungs.zig`).

  Three rungs arrived from separate build lanes with three different shapes — one
  takes a DFA and returns a heap handle answering `bool`, one takes an AST and
  returns a value, one takes a DFA and answers `miss`/`unproven`. Wiring them
  directly would have put three fields on `Regex`, three constructors in the
  lowering, two verdict protocols and nine blocks in the dispatch. The tier absorbs
  all of it: the handle carries **one** field, the lowering makes **one** call, and
  each boolean entry point gains **one** line. Adding the next rung is an entry in
  one ordered table.

  A three-valued verdict (`hit` / `miss` / `unproven`) unifies the two rung kinds
  exactly rather than papering over them — a decider declines at compile time by
  being absent and never says "not sure" mid-scan, a sieve can only narrow — and
  both meanings of `miss` coincide, so one switch serves both.

  A second axis says **which question** a rung answers, because the two boolean
  entry points are genuinely different — a slice, versus the lines inside a buffer
  — and they coincide only where the haystack holds no newline. A rung that reads
  `\n` as a line boundary is consulted at the document grain only, unless the
  particular machine can prove its reset row is what the automaton would do on a
  newline anyway, in which case it answers both. The proof is published as a
  method the tier looks up at compile time, so a rung that never grows one is
  simply held to its kind's conservative reading.

  Measured on a 64 MiB corpus: transformation composition arms on 11 of 18 scan
  patterns including every realistic field pattern, holding ~8.3 GB/s where the DFA
  runs 0.9–1.25 GB/s, and halving to ~4.0 GB/s once the automaton passes 15 states.
  On the per-line entry point the proof above is worth 2.13–2.52× against controls
  at 0.94–1.05, and on `-U` — where the whole-buffer search already hands an
  assertion-free program to the DFA, so the slice question and the multiline one
  are the same question — 4.84–11.42×. An unarmed tier is free: the control
  patterns time identically with it present and absent.
- The determinizer can now name **which** patterns matched, not just that
  something did — and with it come overlapping ends and end-only (HalfMatch)
  search, neither of which the engine could express before.

  Each DFA state's key already ended in a spare `u64` holding a bare match flag.
  Widening that word into a 64-pattern mask is free in every dimension that costs
  (same key length, same allocation, same hash, same compare), and it is what
  turns "did something match here?" into "which patterns matched here?". `freeze`
  then sorts match states by accepted-pattern set so the whole attribution table
  collapses to a handful of `(bound, mask)` runs — 3 to 18 across the measured
  slates — instead of a `u64` per state.

  A one-pattern program is bit-for-bit unperturbed: its mask is exactly `{0, 1}`,
  the same values the flag held, so keys, hashes, discovery order, and the
  resulting automaton are unchanged, and the hot loop keeps its lone
  `s < match_hi` compare.

  The new `Chorus` (`kernel/regex/linear/program/chorus.zig`) lowers N patterns
  into one program whose N terminals sit at indices `0..N-1`, and walks it once to
  yield `(end, patterns)` pairs. Overlapping search falls out for free: on
  `foofoofoo` against `foo|foofoo|foofoofoo` it reports ends 3, 6 and 9, each
  naming the patterns that ended there. rust-`regex` needs `MatchKind::All` for
  that same answer, because its determinizer breaks out of the NFA walk on the
  first `Match` state and has already discarded the longer alternatives — and it
  pays for the flag with a larger automaton and a search loop that forgoes its
  4-byte unroll. Our recognizer never had a priority to preserve (leftmost-first
  lives downstream in the caliper), so All-mode is not a mode we enter.

  Measured and reported rather than assumed: one union walk does **not** beat N
  per-pattern confirms for presence questions (0.06x-0.41x on six slates, with
  identical answers), because a literal confirm never reaches a DFA at all and a
  regex confirm still carries a required-literal prefilter and the fused
  multi-lane document walk. So `PatternSet` keeps the muster and the confirm path
  exactly as they were, and exposes the chorus only through `ends` — the question
  presence cannot express at any price.

  `caliper/reverse.matchIndex` now declines a multi-terminal program instead of
  reversing from the last one it finds. Its contract always said "the lone
  `match`"; with a union program in the tree that assumption would have produced
  confidently wrong spans for every pattern but one.
- The eager DFA now carries a byte-indexed mirror of its transition tables, and the multi-line document walk steps through that instead of the classed ones — dropping the doc scan from three loads per byte to two. The classed recurrence has to translate a byte to its equivalence class before it can index a row (`trans[s + class[b]]`), and that class load sits directly in front of the transition load it feeds; the mirror folds the class column into the table so a raw byte indexes a row (`trans[s + b]`). This is RE2's dense layout, and rust-`regex`'s `dense::DFA` before its `ByteClasses` alphabet — which exists to shrink exactly this table, so the trade is resident bytes (`256/ncls`× the rows) for a load, and `Dfa.Wide.budget` is where we stop paying it (160 KiB, just past the widest automaton the ladder measured).

  It genuinely mirrors rather than replaces. `class`, `ncls`, `trans_in`, and `trans_fin` stay byte-for-byte what the determinizer froze, so the dwell derivation, quotient sieve, shuffle lowering, and symbolic transcription all read the numbers they always did, and an automaton with no mirror walks the classed tables unchanged. `freeze.widen` builds it before premultiplication (raw ids, so widening a target is one multiply rather than a divide back out of `ncls`), only for the automata that will actually walk it — unanchored, no start-dwell, no word context — and an `unfilled` row mirrors its sentinel across all 256 cells so a mirror row witnesses unfilledness exactly where its classed original does. `Dfa.tableBytes` deliberately does NOT count it: that number prices the classed walk the ladder routes on, and a mirror only the doc walk reads must not move a routing decision it has nothing to do with.

  Measured on an M4 over an 8 MiB match-free document, against the classed four-lane walk that shipped before: **1.27×–1.29× geomean** across repeat runs, per-row 1.02×–1.50×, no row slower in any run. The gain tracks how many table rows the document's bytes actually reach rather than how large the table is — a walk whose touched rows stay L1-resident keeps the whole win (0.3267 → 0.2305 ns/byte at 64 states, 2 rows reached), while one wandering over 33 reached rows spends most of it back on misses the class load was never the bottleneck for (0.3669 → 0.3555).

  Width was raced to sixteen lanes and deliberately rejected. Twelve lanes over the mirror cost a flat ~0.31 ns/byte at every table width — enough dependent-load chains in flight to cover the miss wherever it lives — beating four lanes on the wandering rows (0.3099 against 0.3555) and losing badly on the L1-resident ones (0.3058 against 0.2312). Wider lanes shorten the burst, because a burst runs to the *shortest* lane's line end and the minimum over twelve remainders is far shorter than over four, so the `$`-resolve-and-reseed tail runs proportionally more often; sixteen lanes lose everywhere (0.43–0.45) once that tail dominates and the frame spills too. Summed over the slate the two widths tie inside run-to-run variance, and choosing between them needs the *document* rather than the automaton — the same 14 KiB automaton parks on prose and wanders over hex — so the engine carries one width and the ladder keeps racing the others as the standing measurement of what a working-set-aware walk would recover (a per-row best-arm oracle lands ~1.29×, against ~1.28× shipped).

  Byte parity proven five ways, all zero-divergence. Two are new permanent tests in the engine's own slate, because the mirror previously had no coverage there at all: `docMatch` is fuzzed with the mirror present and then withheld — the same automaton walked both shapes, which must agree byte for byte — and a cell-exact check walks every state × all 256 bytes and demands each mirror cell hold exactly the classed cell that byte's class names, unfilled sentinels included. Both were verified adverse rather than assumed: corrupting a single mirror cell reddens each independently, the differential naming a concrete counterexample (`/[a-c]?a$/`). They cost ~5s, ~3% of the DFA slate.

  The other three: gist ≡ rg over the full 21,814-file / 217.7 MiB corpus (140 literal needles + 118 regexes); the `automata … burst` rung's mutation sweep, where every arm plus the shipped `docMatch` must match a scalar per-line oracle on ~2,000 of 4,000 rounds that *actually match* — planting the automaton's own BFS-derived witness, not slices of the pattern source, so a non-literal pattern can no longer prove parity on `false` alone; and the line/unicode/partition/phantom-walk parity gates plus `compose-rung`'s whole-buffer agreement.

  The port-optimality certificate gained a second DFA probe, and the pair answered a question the rung could not. `bench/bounds/port` previously bounded one transition recurrence and called it the doc walk's; that copy is now labeled as the **classed** probe it always was, beside a new `dfa_mirror` probe stepping the byte-indexed tables, both drift-guarded against the real `docMatch` (the mirrored one fails closed if no pattern on its slate carries a mirror, so it cannot pass with nothing to compare). Measured, the two are a **wash** — 4.59 against 4.62 ns/step — because `class[b]` depends on the document byte rather than on `s`, so it issues early and retires under the transition load's latency and was never on the loop-carried path. So the mirror's win is **port pressure, not recurrence latency**: it only cashes out with several independent chains in flight, which is exactly why the walk bursts four lines and why leaving the scalar, anchored, and dwell walks on the classed tables costs nothing. That also settles a standing prediction in `research/ceiling` — that only a change of bound type, not a better table layout, could move the serial number — in its favor.
- The engine no longer hardcodes the name of the program riding it. Three facts separate a product from the kernel inside it — the name that opens a diagnostic line, the namespace its environment knobs live in, and the directory its artifacts go to — and all three used to be the literal string `gist`, spelled out at ~80 call sites. That was not just untidy: running `relate`, a bad `GIST_HYPERLINK` was reported as `gist: note: ignoring …`, naming a program the user was not running. `assay/brand.zig` makes identity a declaration the root module supplies, the way `std.options` works: `pub const irgx_brand: irregex.Brand = .{ .name = "relate" };`, read at comptime with the historical `gist` spellings as the default. Because it folds at comptime, a knob name is still a string literal by the time `getenv` sees it (`assay.knob("DIR")` → `GIST_DIR`) and the tag is still concatenated into the format literal (`diag(assay.tag ++ "…")`), so the seam costs nothing at runtime and a program that declares nothing emits exactly the bytes it did before — `gist --help`, `--schema`, `--version`, `--generate`, and a search over a fixed tree are byte-identical across the change. The three fields deliberately do not move together: `name` is per-binary, while `env_prefix` and `artifact_dir` are per-ecosystem, because the sibling binaries share one trigram index, one kinship atlas, and one `GIST_TRACE` and would lose each other's warm tier if they disagreed. Only an embedder standing the engine up under its own name moves those, and it moves them together. Two knob reads in `kernel/scan/simd.zig` and one tag in `exec/cold/emit/render.zig` still spell `gist` directly; they are held by an in-flight lane and migrate when it lands.
- The fifteen engine measurement lanes are wired into `build.zig` again. The
  extraction carried every source file across but none of the build graph that
  reached them, so `crest`, `sieve`, `roofline`, `portbound`, `lowerbound`,
  `scale`, `indexq`, `engine-census`, `compose-rung`, `parabix-rung`,
  `automata-rung`, `patternid-rung`, `multipattern`, `sweep-rung`, and
  `ladder-price` were code nothing could build. `zig build lab` installs all of
  them; each is also its own named step. They stay off the default install, so a
  bare `zig build` still pays only for the library and its C ABI.

  The two postures a lane can take are now a declared field rather than a habit.
  A certificate layer honors whatever `-Doptimize` you asked for, because a
  cycles/byte number is a claim about *that* build; a production rung compiles at
  `-Dlab-optimize` (ReleaseFast by default), because a rung that races the shipped
  ladder has to be built the way the shipped ladder is or the ratio describes the
  build mode instead of the machine.

  `probes.zig`, `pmu.zig`, and `stats.zig` are exported as the `probes` / `pmu` /
  `stats` modules and `bench/apparatus/harness` joins `build.zig.zon`'s `.paths`,
  so `gist`'s harness reaches them the same way it already reaches `brigade.zig`.
  One probe registry and one significance test across both repositories is what
  lets a competitor race there and an engine rung here be compared by class name;
  a second copy would drift and quietly stop meaning the same thing. `stats.zig`
  now compiles as its own test root too — previously its bootstrap-CI and
  Mann-Whitney tests rode a harness that has since moved, leaving the verdict math
  every lane reports through compiled by nothing.

  `abi()` is back on `src/root.zig`. The contract names it as the source of the
  ABI integer and the export shim now returns it rather than restating the
  literal, so the two cannot disagree.
- The repository had a license, a NOTICE, and eight CI jobs, and nothing that told
  an outsider how to participate in any of it. Every fact a contributor needed -
  which Zig, how to filter the suite, that a ratchet baseline may only shrink,
  that a fragment goes in the same PR, where a security report is supposed to go
  instead of the issue tracker - lived in a workflow comment or in nobody's head.

  Six files now say it out loud.

  **`CONTRIBUTING.md`** is the practical half: the sibling-checkout layout the
  bindings path-depend on, the pinned toolchains and what pins them, the test loop
  that matters (`-Dtest-filter`, `-Dtest-shards=1`, `BRIGADE_TIMES=1`, and the
  direct-binary escape hatch for anything that reads the environment), what each
  of the eight CI jobs holds, and the three questions review asks before any
  others - what proves this, what does it cost, what did it replace.

  **`SECURITY.md`** draws the line this project actually has. Memory safety
  anywhere, a loader that trusts a persisted artifact, and superlinear blowup on
  the *linear* engine are vulnerabilities. PCRE2 going exponential behind `-P` is
  the documented trade you opt into, and cost proportional to input size is
  arithmetic. It also states the thing a reporter cannot guess: safety checks are
  off in the `ReleaseFast` build the faces ship, so a clean panic on your machine
  may be a memory-safety bug on theirs.

  **`CODE_OF_CONDUCT.md`** is Contributor Covenant 3.0, with the reporting and
  enforcement sections filled in rather than left as the template's bracketed
  notes. Its "failing to credit sources" clause is not decoration here; it is the
  same rule `NOTICE` and the `research/*/PRIOR_ART.md` dossiers already enforce in
  code.

  **`.editorconfig`** carries no second opinion: every value is the one the
  formatter that gates the file already emits, so an editor save and `zig fmt
  --check` cannot disagree. Vendored trees and the pinned UCD tables are exempt,
  because re-indenting somebody else's bytes on save turns a re-vendor into an
  unreviewable diff.

  **`.gitattributes`** normalizes line endings, marks the prebuilt archives
  binary, keeps vendored and generated files out of review and out of the language
  statistics, and binds git's hunk-header drivers. It deliberately does not use
  `export-ignore`: that would change the bytes of the tarball GitHub generates for
  a tag, which is exactly what a downstream `zig fetch` pin is a hash of.

  **`.mailmap`** collapses eight author spellings into the three people who wrote
  them - two laptops that had signed commits as `<user>@<hostname>.local`, and one
  personal address that later became a work address.

  Alongside them, `.github/` gains a CODEOWNERS routing table, a Dependabot
  configuration covering all four manifests (and explaining why Zig is absent:
  the `.zon` pins are provenance for bytes already vendored, so bumping one
  without re-vendoring would produce a manifest that lies), a pull-request
  template, and three issue forms. The first of those forms is the one this
  project needs most - a wrong-match report that asks for the pattern, the
  subject, the flags, and what an independent engine says, because a divergence
  from what a pattern means outranks nearly everything else in the queue.
- The row protocol now lives in `include/irgx.h` beside the status codes and
  pattern flags: `irgx_row` / `irgx_rows` / `irgx_schema_*` / the four
  `irgx_rows_*` walkers. Each product library still exports its own producer
  (`gist_run`, `relate_run`, `blast_run`); they all hand back the same cursor, so
  a host asking three packages three questions learns one way to read the answer.
- The status vocabulary is now gated against every artifact that restates it.
  `contract/engine.toml` declares it once and three places spell it again: the
  `Status` enum in `src/surface/ffi/contract.zig`, the `IRGX_*` defines in
  `include/irgx.h`, and the error sets in `src/fault.zig`. The contract's
  argument for declaring it in one place was that a single gate could then cover
  all of it. That gate did not exist. In any language: no Zig test parsed the
  contract, and the Rust and Go mirrors, which do resolve the file, never asserted
  this table against their own constants. It was a declaration nothing compared
  anything to.

  `bindings/python/tests/test_contract.py` is that comparison — the Zig enum
  against the table, the C defines against the `c` macro each row names, each
  fault domain against the Zig error set its key capitalizes to, `fault.Fault`'s
  union against the taxonomy's total membership, `fault.Decline` against
  `[decline_reasons]`, and the rule that every fault status names an existing
  domain and no two claim the same one.

  Nothing is listed twice. Every expectation is derived from the pair being
  compared, including the awkward one: nothing here knows that `out_of_memory`
  answers to `IRGX_OOM`, because the contract's `c` field says so and the
  assertion reads it from there. Rename a macro in both places and the gate
  follows; rename it in one and the gate stops you.

  It fails closed. An artifact it cannot find or read is a failure, never a skip —
  this repository has already had a parity test skip on an unresolvable path for a
  whole release while the thing it guarded drifted, and a gate that goes quiet
  when its subject moves is precisely the drift it exists to catch.

  Each of its seven assertions was checked by mutation: drift the Zig enum, drift a
  C value, mint a status macro the contract does not declare, drop a member from a
  Zig error set, add a fault the taxonomy does not name, rename a decline reason,
  point a status at a domain that does not exist. Every one of the seven is caught,
  and the suite still passes unmutated.
- The two-byte block filter can now price its anchor pair against the buffer in
  hand instead of a byte-frequency table shipped in the binary. `calibrate.zig`
  samples 64 KB in 256-byte stratified windows over up to 16 candidate offsets and
  returns the cheapest pair. Against the best pair that exists it lands at 1.04x on
  code, 1.03x on prose, and 1.03x on a heterogeneous base64+code+prose buffer,
  where the static table reads 1.50x / 2.21x / 1.39x - for 0.19% of a 213 MB scan.

  Stratification is the whole design and it is measured, not assumed: on the
  heterogeneous buffer a prefix sample lands at 4.30x and *does not improve with
  budget* (4.33x at 256 KB, 3.62x at 1 MB) because the bias is systematic, while
  stratified sampling lands at 1.04x. On homogeneous prose a prefix is fine
  (1.05x), which is exactly why measuring only prose would have shipped the bug.

  **The gate it needs is a claim about a document, not about a call.**
  `len >= 16 * k * budget` is 3.1 MB at a 3-byte needle, and the obvious call site
  cannot satisfy that: `query.zig` calls `simd.contains(line, needle)` once per
  *line*, so the gate declines on every real call, while removing the gate would
  re-pay 3.5-36.8 us per line. The 1.04x figures above were taken calibrating once
  over a 213 MB buffer, which is not a shape production had. So the module lands
  with the per-scan plan that gives it one - calibrate once per admitted document,
  thread the pair through every line of it, leave `indexOfPos` static so the
  roofline control cannot drift out of sync with the kernel - and the wiring, its
  two recorded surprises, and the end-to-end numbers are the companion "anchor
  decision is now a value" entry.
- This repository had no CI of any kind, which is precisely how a `requires-python` floor of `>=3.10` shipped in a package whose runtime uses syntax that is a parse error before 3.12: nothing ever installed the built artifact and tried to import it.

  `ci` runs the four faces as four jobs, because a Zig engine regression and a Rust clippy nit are different news and one job would report them as the same red X: the engine (`check` then `test`, on both Linux and macOS, since the build branches on the host), the Python binding on 3.12/3.13/3.14, and the Go and Rust bindings. Neither of those last two installs Zig — both ship a prebuilt archive per platform so that `go get` and `cargo build` need no toolchain, and installing one in CI would exercise a path no consumer takes.

  `release` builds the whole wheel matrix on a tag and publishes through PyPI Trusted Publishing, so there is no API token to leak or rotate. Two things gate the upload. The declared Python floor is proven against the artifact about to be published — the wheel is installed on 3.12 and imported from outside the source tree — rather than asserted in a TOML file, which is the specific check that would have caught the false floor. And because the three faces version independently (0.3.0, 0.2.0, 0.1.0), the tag is checked against the version it would actually publish, so `v0.3.0` refuses rather than quietly shipping 0.2.0.

  Publishing needs one manual step first: register this repository, workflow `release.yml`, environment `pypi` as a trusted publisher for the `irregex` project on PyPI.
- Two invariants in the symbolic determinizer are now written down where the code that depends on them lives, because both are held up by a debug-only `assert` that is `unreachable` in the release build, and both fail silently rather than loudly.

  `Decoder.follow` reads its `row` table unconditionally, so a `Decoder` that reaches it without `spread` having run does not panic — it indexes an empty slice with no bounds check and returns a wrong transition, which is a wrong automaton and a silently wrong match. What actually holds the precondition up is narrow enough to state: `build` is the only construction site and calls `spread` on both return paths, and `follow` has exactly two callers, both in `transcribe.zig`, both after `build` returned. `transcribe.intern` has the sharper version of the same shape — a landing carrying `pat == aut.dead == maxInt(u32)` would compute a slot of roughly 2³² × `nstates` and **write** there, so the failure is out-of-bounds heap corruption surfacing somewhere unrelated, long after the frame is gone.

  The `row` field also now carries its own trade: 1 KiB per node, unbounded, in exchange for the scan it replaced. That scan measured 21.5M edge comparisons for 1.4M lookups on `func\s+\w+\(`, and reverting it costs roughly 4× on compiling exactly the patterns agents search for most. It is worth the note because the engine census reports which machine answered and not the time spent choosing it, so undoing this would change no census row and no answer — the regression is invisible to the gate an engine change is normally read against, and only user-CPU compile timing against an ASCII twin sees it.
- Windows gets the warm tier. `portal.resident_sessions` was `comptime false`
  there, so every query on Windows answered cold — no resident session, no answer
  keep, and the two heaviest `relate` sweeps had no cheaper form to fall back on.
  The declared floor moves to `win10_rs4` (1803), which is where Windows shipped
  `AF_UNIX`, so the daemon speaks the same socket protocol as every other platform
  rather than a second named-pipe transport nobody would keep honest. Four seams
  grew a Win32 arm behind their existing `comptime` boundary: readiness waits on
  AFD's `IOCTL_AFD_POLL` (the mechanism `wepoll` and libuv use) instead of
  `poll(2)`; byte I/O threads through `std`'s socket vtable instead of raw
  `read`/`write`; the singleton is a share-mode exclusive open instead of `flock`;
  and the spawn is a detached `CreateProcessW` instead of `fork`+`execv`.
  Descriptor passing stays POSIX-only — `SCM_RIGHTS` has no portable Win32
  equivalent worth the surface — so `portal.fd_passing` split out as its own
  predicate and the Windows daemon serves shared-memory or chunk frames instead.
  Nothing about the cold path depends on any of it, which is why this is a speed
  change rather than a correctness one.
- Windows is now **compiled on every push and executed on every PR**, which is the
  difference between a port that was proven once and a port that stays proven. The
  previous sweep established that all four triples build and that three of them
  conform under Wine; nothing then stopped the next commit from breaking the Win32
  arm, because no gate on any machine compiled it.

  **`zig build check-windows` is the floor, and it is folded into `zig build test`.**
  It runs Sema plus codegen with no link over the CLI for `x86_64-windows-gnu`,
  `aarch64-windows-gnu`, and `x86-windows-gnu`, so a Windows-only compile error now
  fails a Linux and a macOS run. `the Windows CI lane (`zig build check-windows`)` is the same step
  standalone, which is the most a POSIX laptop can honestly claim about Windows.
  All three triples are there because they disagree: **x86 is the only one that
  caught two real bugs.** The lazy-DFA churn statistic divided a `usize` by a `u64`
  counter and assigned the `u64` quotient back, which only fails to compile where
  `usize` is 32 bits; and the executable-identity memo was a `std.atomic.Value(u64)`,
  which 32-bit x86 has no lock-free load for. That second one is now a plain `u64`
  published behind a `bool` flag with acquire/release ordering, so the full 64-bit
  stamp survives on every target instead of being narrowed to fit the narrowest one.

  **The runtime proof is native, on both architectures.**
  `.github/workflows/gist-windows.yml` runs the sharded suite, the ReleaseFast
  build, `index_elision_parity.sh`, and a CLI smoke that pins rg's exit-code
  contract through a real console, on `windows-2025` and `windows-11-arm`. Dagger
  runs inside a Linux container and cannot reach a Windows executor, which is the
  same argument `apple.yml` already makes for macOS, so this lane is registered
  against its `.github` path directly rather than mirrored from Forgejo. Both
  architectures run because arm64 is weakly ordered: the acquire/release pair above
  is decoration on x86's total store order and load-bearing there, and a matrix
  that only ran x64 would never say so.

  The gate that ports is the self-oracling one. `index_elision_parity.sh` diffs the
  index-accelerated answer against gist's own `--no-index` full read, so it needs no
  ripgrep on PATH and asserts a contract rather than a count; it is also the one
  conformance gate the Linux leg runs, so Windows clears the same bar rather than a
  taller one. It resolves `gist.exe` itself now, and honors the `${GIST}` override
  the three sibling gates already had.
- Windows is now the third exact freshness backend. A resident daemon has to know
  the tree moved before it serves an answer about it, and on Windows it knew
  nothing: the watcher seam had a Linux arm and a macOS arm, so a Windows daemon
  could only degrade to reconciling the whole strip. `notify.zig` subscribes
  recursively per root through `NtNotifyChangeDirectoryFileEx` with `WatchTree`,
  and drains onto one I/O completion port rather than APCs or per-root events —
  completion is thread-agnostic, so `flushSync` can drain packets the background
  loop never touched and the causal barrier holds without a thread rendezvous. The
  filter is derived from what `reconcile.one` actually compares (name, attributes,
  size, both write clocks, security, EA) rather than from the API's default set, so
  no field the reconciler would notice arrives unannounced.

  Two things it does that no POSIX arm can. A notify record carries the directory
  entry's own spelling, so `exact` keys arm on a case-insensitive volume without
  the refusal inotify needs there. And the extended record class carries the
  changed file's timestamps in-band, so the annals ledger is stamped with that
  file's `max(mtime, ctime)` instead of the drain clock's approximation of it —
  falling back to the wall clock only for removals, where there is no surviving
  file to ask. Buffer overflow marks doubt permanently rather than retrying, which
  is the same posture `IN_Q_OVERFLOW` gets on Linux.

  The contract cases moved out of `kqueue_test.zig` into a shared `rig.zig` on the
  way, so both exact backends are now judged by the same barrier suite — in-place
  edit, cross-directory move, case-only rename, deletion, root entry — instead of
  each proving whatever its own file happened to test.
- Windows now walks with batched directory metadata instead of a stat per file.
  `NtQueryDirectoryFile` hands back the name, the attributes, and both change
  clocks in one call, so `bulkstat.supported` and `names_supported` are finally
  true there — the freshness overlay, the cold descent, the parallel loader, and
  the phantom treemap all take the accelerated path they already take on Darwin.

  The old portable path was not merely slower, it was asking twice for something
  the kernel had already said: `std.Io.Dir.Iterator` requests a metadata-bearing
  information class, keeps the name and the kind, and drops the timestamps — and
  the freshness walk then re-opened every file to ask for them again. Per file
  that is an `NtCreateFile` + `NtQueryInformationFile` + `NtClose`, and on Windows
  an open is the expensive operation, because it is the one every filesystem
  filter driver (Defender included) sits on.

  The syscalls moved out of `bulkstat.zig` into a new `sheaf.zig` beside it, so
  the three platform ABIs live together and the policy — which entries a freshness
  walk cares about, how a declined batch degrades, how a listing outlives its
  buffer — reads as one rule rather than one per platform. Same fail-soft posture
  as before on every arm: a refusing batch declines and that subtree falls back to
  the proven per-entry stat walk, so uncertain metadata costs speed and never the
  conservative live-read decision.

  Two latent bugs fell out on the way. `portal.scratchDir` had no callers and had
  rotted against Zig 0.16 on *both* arms (`std.posix.getenv`, `std.mem.trimRight`)
  — unreferenced, so nothing ever Sema'd it; the bulkstat tests now call it instead
  of hardcoding `/tmp`, which is also what lets them run on the native Windows
  lane at all. And the Windows drain drops reparse points rather than reporting
  them as neither-file-nor-directory, because it serves as the names-only drain
  too and the phantom treemap records every row it is handed — returning one there
  would have made a Windows snapshot count links a POSIX snapshot of the same tree
  does not.
- Word-boundary patterns (`\b`/`\B`/`\<`/`\>`) now determinize into the byte-class DFA instead of always falling back to the Pike VM — the one shape the eager DFA previously bailed on. The powerset construction gains a second determinization axis (RE2 / rust-`regex`-`automata`): byte classes are refined by ASCII word-ness so a just-consumed byte fixes `word_before`, and the interior transition table is doubled on the _next_ byte's word-ness (`trans_in` when it is non-word, `trans_in_w` when it is a word byte), with the start state split the same way (`start`/`start_w`); the existing EOL table (`trans_fin`) already carries `word_after=false`. `Dfa.matchWord` then resolves word context at one table lookup per byte, exactly like `^`/`$`. Under Unicode a gap abutting a non-ASCII scalar is undecidable by an ASCII-classed DFA, so `matchWord` QUITS (returns null) and the Pike VM — still the correctness oracle — resolves that line; `(?-u)` word patterns never quit (a byte ≥0x80 is a non-word byte, byte-for-byte). Whole-document fused scanning stays Pike-served for word patterns this rung; the bounded literal still rides the T0 trigram prefilter (`\bfunc\b` ⇒ "func"). Proven by two independent oracles: a Pike differential fuzz over ASCII haystacks in both engine modes plus a Unicode quit-path soundness test (commit ⇒ Pike, integrated dispatch ⇒ Pike, quit path exercised) in `dfa_test.zig`, and an EXHAUSTIVE language-equivalence proof against a from-scratch word-resolving NFA `Spec` (every string ≤ 6, plus a randomized program fuzz) in `powerset_test.zig` — the full `zig build test` slate green with 0 divergences.
- `--docs` / `--code` / `--data` and their `--no-` complements, a corpus axis
  orthogonal to `-t <language>`. `-t` answers "which language is this?", which is
  the wrong grain for the question anyone actually asks — never "is this
  reStructuredText" but "am I reading the paper trail, or the implementation?".
  Spelling that with `-t` means naming sixteen types and still missing the
  extensionless `CHANGELOG`; spelling it with `-g` means hand-assembling globs that
  no longer say what they were for.

  New `corpus/scope/genus.zig` owns the partition: three genera, total and
  disjoint, so a flag and its `--no-` form are exact complements and no path falls
  through. Selections union, each name is also a type name (so `-t docs` and
  `--type-add 'docs:notes/**'` work and no new configuration key was needed), and
  the whole thing is daemon-warm — the selection rides `query_ext` as a two-byte
  trailer, verified byte-identical against the cold run for every polarity.

  **`code` is the leftover, never a recognized set.** An unfamiliar extension, a
  generated blob, or a file with no extension lands there, so the worst a gap in
  the table can do is show `--code` one line too many; the alternative default (a
  fourth `unknown` genus excluded from `--code`) turns every gap into a silent
  miss, the one failure an agent cannot detect. Same asymmetry decides the hard
  case: a doc directory or a `CHANGELOG`-class name only promotes what no language
  type claimed, so `docs/notes.md` is docs while `docs/conf.py` and a docs site's
  `*.tsx` stay code. A genus also narrows only — unlike `-t`/`-g` it never
  un-hides, because an un-hiding default would surface all of `.git/`.

  Against the `-t` union a person types instead — derived at run time from
  `gist --type-list --docs ∩ rg --type-list`, 25 type names, so it can be neither
  strawmanned nor left to drift — **2.9× faster cold and 21× warm** (geomean over
  the needle slate, `bench/dominance/partition/`, answer keep disabled so the warm
  arm is a search and not a memoized recall). On the tracked corpus the two rosters
  land within one file of each other, which is what a derived rival should do; what
  a genus knows that a basename glob cannot is proven on the lane's hermetic tree
  instead, where the union calls **three build recipes prose** (`CMakeLists.txt` —
  rg's `txt` type is `*.txt`, with no way to except a basename) and cannot name
  **two extensionless documents** gist promotes by location and by name. Those
  counts are asserted by equality against a written-down contract, not a captured
  measurement. No grep-class tool ships this axis at all: ripgrep's type globs are
  basename-only, so a `docs/` rule is inexpressible there even by hand
  (ripgrep#3339, open); ugrep's `text` type is five extensions with no code
  counterpart; zoekt links go-enry's `Prose`/`Data` classifiers and never calls them.

  Both halves are permanently gated. `partition_parity.sh` proves the set
  identities over the live tree on every `zig build test` — totality, disjointness,
  each `--no-` form as an exact complement, `-t`/`-T` alias parity, index and
  resident session as acceleration only, no genus un-hiding a path the walk
  refused, and the location rule still rescuing extensionless documents.
  `bench-gist-partition` holds the speed and the classification contract.

  The classification is comptime-proved against the 223-row type table in both
  directions — a new `-t` type is a compile error until it is classified, a renamed
  one until the rename lands here — and the runtime shadow set that keeps
  `CMakeLists.txt` a build recipe is derived from the table rather than listed, so
  a new collision on either side cannot go unnoticed. `genus_test.zig` re-derives
  the whole answer from the declaration for every glob in the table, with an
  explicit dispute list rather than a tolerance.
- `.mise.toml` and a committed `mise.lock` turn the Setup table in `CONTRIBUTING.md` into `mise install`. Zig, Rust, Go, Python, and uv are pinned at the versions CI already uses, with checksums recorded for all four release platforms. The pins are mirrors of `build.zig.zon`, `bindings/rust/rust-toolchain.toml`, `bindings/go/go.mod`, and the `--python` CI hands uv - never the authority, so a bump has to touch both files or nothing resolves the way it reads.

  The discipline gate's binaries are pinned the same way, and for the same reason a red X should mean the same thing in both places: markdownlint-cli2, typos, shellcheck, and golangci-lint, each at the version its CI step already resolves. Two of those come from the versions their actions bundle, which is why the markdownlint action moved up to v24.1.0 in the same pass - it had been running markdownlint-cli2 0.22.1, one minor behind the 0.23.1 pinned here.

  The other half of the gate is deliberately not here. Ruff, yamllint, taplo, editorconfig-checker, and zizmor arrive through `uv run --no-project --with <pkg>==<version>`, which is a version authority already - written in the workflow, repeated verbatim in `CONTRIBUTING.md`, and needing no install step at all. A second pin for those could only ever disagree with the first.

  The Rust pin also asks for `llvm-tools`, and that is the part worth explaining. The vendoring scripts under `bindings/*/scripts/` shell `llvm-nm` to ask an archive for its symbols and `llvm-strip` to drop the DWARF that dominates an unstripped ELF archive, which Apple's `strip` cannot do at all. Proving which instructions a shipped archive actually contains needs `llvm-objdump`, and neither Apple's `/usr/bin/objdump` nor `zig objdump` (which has no `-d`) answers that. Until now those came from whatever LLVM a machine happened to carry, found by walking a hardcoded list of Homebrew and apt prefixes. That list is a guess about other people's machines, and it fails in both directions: a contributor with no LLVM cannot run the scripts at all, and a contributor with one gets a version nothing recorded. Homebrew's `llvm` is also keg-only, so it is entirely possible to have it installed and still not have `llvm-objdump` on `PATH`.

  rustup builds those binutils from the same LLVM the compiler links, so pinning `rust = "1.96.0"` dates them too - LLVM 22.1.2 here, moving only when the pin moves. It is also the smaller half of the trade: 166 MB of binutils against 1.7 GB for a full Homebrew LLVM, which floats free of any pin, and mise's only other route to LLVM is an asdf plugin that builds it from source with cmake. `find_tool()` now tries that sysroot first, immediately after an explicit `$LLVM_*` override and ahead of `PATH`, Xcode, and the Homebrew prefixes, which stay as the fallback for a checkout without Rust. The tool a committed artifact was verified with is now a thing the repository states rather than a thing the laptop decided.
- `\b{start}`, `\b{end}`, `\b{start-half}`, and `\b{end-half}` now parse and run,
  so the four spellings rust-regex added are no longer a reason to reach for
  another tool. The first two are the names `\<` and `\>` already had. The halves
  are genuinely new: each constrains one side of the gap and says nothing about
  the other, which is what you want when the thing on the far side is the match
  itself rather than a word — `\b{start-half}foo` finds a `foo` nothing wordy runs
  into, whether or not `foo` starts with a word character.

  Adding them collapsed the family rather than growing it. All six word
  assertions ask one question about two neighbors, so there is now one AST node
  and one NFA state carrying a four-bit mask — a bit per (before, after) pair —
  where there used to be a node and a state per spelling. Every engine evaluates
  any of them with a shift and a test, the one-pass builder intersects two masks
  on an ε-path and sees `\B\<` collapse to the empty mask at build time instead of
  re-deciding it per byte, and a seventh spelling would be a table row rather than
  a case in nine switches.
- `automata-rung -- dwell` grew the two arms that settle claim C4 — skipping out of
  *every* dwell rather than only the start state. The census said the premise held:
  97.5% of a document's bytes sit in an interior state with a narrow exit set, and
  every refusal was the profitability bar rather than the automaton's shape. So the
  skip got built in the harness and timed, and the answer is **no**.

  Three arms interleaved over one buffer, because two of them answer different
  questions. `step` is the scalar walk and differs from the skip arm in exactly one
  respect, so `vs step` is attributable. `ship` is the multi-lane `docMatch` the engine
  actually runs, so `vs ship` is what decides. With the profitability bar **waived**,
  so every narrow-exit state is armed, C4 is **0.41× geomean** — a 2.5× regression.

  The new `stride` column says why in one number, by reporting the bytes a skip
  *actually* elides here instead of what the corpus prior predicted. `foo.*bar`'s
  interior dwell exits on `b`, its document contains `b`, so each skip elides 3.8 bytes
  and pays full vector-kernel entry for them: ~10× slower. `a.*b` wins 1.18× only
  because its fill excludes `b` outright and the stride becomes the whole distance to
  `\n`. Same exit set, same build-time prediction, opposite outcomes — the difference
  is a property of the document, which no build-time prior can see.

  A break-even sweep then found the threshold. Holding the automaton, alphabet, and
  instruction mix fixed and moving only the line length makes the realized stride the
  sole variable, and `vs ship` crosses 1.000× between a 23.1-byte stride (0.79×) and a
  31.0-byte one (1.03×). Break-even is a **≈30-byte** stride; the shipped
  `dwell.min_profitable_stride` is **32**, calibrated on the start case alone. It was
  right to within 6%, so there is nothing to change: the engine already arms this skip
  in the one place no `\n` caps the stride.

  The correctness oracle is the part worth keeping. A skip validated only on
  match-free documents is validated on its easy case, so each row must survive 4000
  single-mutation rounds where both walks agree — and half those mutations splice a
  random *substring of the pattern* over the document rather than random bytes, because
  spelling `bar` by chance is 1 in 2²⁴ and a uniform sweep silently degrades to "false
  agrees with false". A row whose mutations never produced a match **fails** instead of
  publishing a timing, which is how `foo.*bar` was caught reporting a number its oracle
  had not earned. The sweep also proved a real bug it was written for: after a skip,
  the state `trans_fin` needs for the last byte of a line is the dwell's own state, not
  the state before the last *stepped* byte.

  No engine behavior changes. `walkDwelling`, `observedStride`, and the mutation oracle
  live in the bench, which is where a declined claim's evidence belongs.
- `bindings/go/` is a Go binding now: cgo over a static archive vendored in the
  module, so `go get github.com/The-Billy-Company/irregex/bindings/go` followed by
  `go build` gives a working regex library on a machine with no Zig toolchain and
  nothing to install alongside it. Go has no `build.rs`, so there is no install-time
  hook to compile into; the module carries one archive per platform - darwin arm64
  and amd64, linux amd64 and arm64, about 6 MB in total - and the build constraint
  on a `link_*.go` file is what picks the matching one. The archives sit beside
  the Go source rather than a directory down, because `go mod vendor` copies a
  package's own files and skips a subdirectory holding no Go package; kept one
  level down, every vendored consumer would fail at the linker. All four come off
  one machine, cross-compiled by Zig against a glibc 2.17 and macOS 11 floor, and
  each one is proved to link before it is committed. `irgx_abi_version()` is checked
  at package init, so a library supplied through the `irgx_syslib` escape hatch
  that disagrees says so instead of mis-reading a struct.

  The surface is stdlib `regexp`'s, because that is the API a Go programmer
  already has in their fingers: `Compile` / `MustCompile`, the `Find` family with
  its `All`, `String`, `Index` and `Submatch` variants on both the `string` and
  `[]byte` side, `Split`, the `ReplaceAll` family, `Expand`, `SubexpNames` /
  `SubexpIndex`. The engine's flags have no `regexp` spelling, so they live in a
  `CompileOpts` struct with its own `Compile` and `MustCompile`; a struct rather
  than functional options because the C ABI closes the flag set, leaving nothing
  for an option function to extend. There is no `MatchReader` family and no
  `Longest`: the engine searches a buffer you already hold, and inventing either
  would be a semantic the library does not hold.

  Three properties are the whole reason this is a binding rather than a wrapper.
  Iteration is `irgx_find_all`, never a Go advance loop over `captures`, so the
  empty-match, adjacency and `-w` rules a nullable pattern depends on are the
  engine's; group detail is filled in afterwards by `captures(from: span.start)`
  per span the engine already blessed, and the two are checked against each other.
  Offsets need no translation at all, unlike the Python binding's: Go strings are
  UTF-8 and indexed by byte exactly as the engine's spans are, so an index this
  package returns slices the caller's own string, `café` and all. And a `*Regexp`
  is safe for concurrent use, as `regexp.Regexp` is and as every package-level
  `var re = MustCompile(...)` assumes, even though the C handle owns the scratch
  its finds run in and cannot be shared - goroutines are not threads, so there is
  no thread-local to hide one in, and a `sync.Pool` lends a handle out per call
  instead, with a finalizer to free what the pool drops.

  Writing it turned up two faults in the ABI, both fixed in the engine before this
  shipped. `irgx_compile` used to refuse a NULL pattern of length zero even
  though the empty pattern compiles fine, which a language whose empty string
  carries no data pointer trips over without meaning anything by it. And
  `irgx_is_match` used to answer a different question from `irgx_find_all`,
  splitting the buffer into lines, so `c$` over `"abc\n"` was a match to one and
  not the other. The nine-pattern by six-text anchor grid that found it is now a
  test here, checking that `MatchString` and `FindStringIndex` agree on all 54
  pairs and that neither reads the buffer as lines, because those two verbs
  drifting apart would split this package's answers down the middle.
- `bindings/python/` is a real Python binding now: `ctypes` over the bundled
  `libirgx`, so `pip install irregex` gives a working regex library with no Zig
  toolchain, no compiler, and nothing to install alongside it. The published 0.1.0
  shelled out to a CLI that no longer exists; 0.2.0 links the library the header
  describes and loads it out of the installed package, with an `IRGX_LIB`
  override for people pointing at their own build. `irgx_abi_version()` is
  checked at load, so a wheel and a library that disagree say so instead of
  mis-reading a struct.

  The surface is stdlib `re`'s, because that is the API a Python user already has
  in their fingers: module-level `compile` / `search` / `finditer` / `findall` /
  `split` / `sub` / `subn`, `Pattern` and `Match` with `group` / `groups` /
  `groupdict` / `span`. Flags are keyword arguments (`fixed`, `ignore_case`,
  `word`, `smart_case`, `unicode`, `pcre`) rather than an or-ed bitmask, since the
  C bits are already named and a keyword is what a reader can see at the call
  site. There is no `match` or `fullmatch`: the engine has no anchored verb, and
  inventing one out of a scan would be a semantic the library does not actually
  hold.

  Three properties are the whole reason this is a binding rather than a wrapper.
  Iteration is `irgx_find_all`, never a Python advance loop over `captures`, so
  the empty-match, adjacency, and `-w` rules a nullable pattern depends on are the
  engine's and not a re-invention of them; the group detail is filled in
  afterwards by `captures(from=span.start)` per span the engine already blessed.
  `str` in gives `str` out with **codepoint** indices, translated off the engine's
  byte offsets lazily and skipped entirely when the subject is ASCII, so
  `text[m.start():m.end()] == m.group()` holds for the caller's own string; a
  pattern compiled from `str` refuses `bytes` and the reverse, as `re` does. And a
  `Pattern` is safe at module scope under a thread pool, because the C handle owns
  the scratch its finds run in and cannot be shared — each thread gets its own
  lazily through `threading.local`, which costs one pure compile per thread and is
  released when the thread dies.

  Wheels are platform-tagged and carry the library, built by a hatch hook that
  cross-compiles with Zig: macOS arm64 and x86_64, manylinux x86_64 and aarch64,
  and Windows x86_64 all come off one machine.
- `bindings/rust/` is a Rust binding now: `extern "C"` over `libirgx`, with the
  engine vendored per target so `irregex = "0.1"` in a Cargo.toml gives a working
  regex library and nothing else to install. Four prebuilt static archives ship in
  the crate (macOS arm64 and x86_64, Linux x86_64 and aarch64 against glibc 2.17),
  each stripped and link-tested before it is written, and `build.rs` picks the one
  matching `TARGET`. The crate packs to 2.3 MiB compressed. A target with no archive
  is not an undefined symbol at link time: the build fails with a sentence naming
  the target and the two ways past it - `IRGX_LIB_DIR` pointing at your own
  library, or `zig` on PATH beside an engine checkout, which `build.rs` will drive
  itself. `irgx_abi_version()` is checked on the first compile, so a crate and
  a library that disagree say so rather than mis-reading a struct.

  The surface is the `regex` crate's, because that is the API a Rust programmer
  already has in their fingers: `Regex::new` / `is_match` / `find` / `find_iter` /
  `captures` / `captures_iter` / `split` / `replace` / `replace_all`, with `Match`
  carrying `start` / `end` / `range` / `as_str` and `Captures` indexable by number
  and by name. Flags are a `RegexBuilder` (`fixed`, `ignore_case`, `word`,
  `smart_case`, `unicode`, `pcre`) since the crate that shape is borrowed from has
  one. Every panicking verb has a `try_` sibling returning `Result`. There is no
  `shortest_match`, `find_at`, or byte-slice `Regex`: the ABI has no anchored or
  resumable verb, and faking one on an unanchored scan would be a semantic the
  library does not hold. `\A` and `\z` are in the grammar, which is how you ask.

  Four properties are why this is a binding and not a wrapper. Iteration is
  `irgx_find_all`, never a Rust loop over `captures`, so the empty-match,
  adjacency, and `-w` rules a nullable pattern depends on are the engine's; group
  detail is filled afterwards per span the engine already blessed, and a saturated
  window is re-scanned rather than trusted, since `written == cap` cannot be told
  from truncation through the ABI. Offsets need no translation at all - Rust `str`
  is UTF-8 indexed by byte, exactly like the engine's spans, so `&text[m.range()]`
  is the matched text by construction; the one span that cannot slice a `str` is a
  mid-codepoint boundary under `unicode(false)`, and that is a named
  `NotCharBoundary` error rather than a panic out of a slice index. `Regex` is
  `Send + Sync`, so a `static RE: LazyLock<Regex>` works, and it gets there with a
  pool of handles leased one per search rather than an `unsafe impl Sync` over a
  handle the header says is single-threaded. And `Error` implements
  `std::error::Error` carrying the fault name and the status sentence, with
  `IRGX_OOM` its own variant, so no negative status can become a wrong answer.

  Verified against the Python binding rather than against itself: a committed
  corpus of 94 pattern / flag / text triples, generated by driving the reference
  binding, asserts identical spans, identical group spans including the `(-1, -1)`
  a group that never participated reports, and an identical `is_match` for every
  one. The anchor contract gets a grid rather than a list, because "no match" is
  too weak a claim to prove it: an engine with per-line anchors and an engine whose
  anchors never fire both report no match for `\Aabc\z` over `"x\nabc\ny"`, so each
  row carries what all three readings predict and the test checks it still holds
  rows that separate them. Eight rows contradict the per-line reading; seven
  contradict dead anchors. `(?m)` is pinned as refused by the linear grammar and
  honored by the PCRE arm, which is the supported way to ask for per-line anchors.
- `irgx` has shipped its `py.typed` marker from the beginning, which is the only reason a consumer's type checker can see its annotations at all. Nothing guarded it. Deleting that file breaks no test and fails no build; it just quietly downgrades every downstream user to `Any`. There is a test for it now - the same one the three sibling packages got along with the marker itself.
- `libirgx` is now a real artifact, and it is a regex library rather than a
  search one: `irgx_compile` / `is_match` / `find_all` / `captures` /
  `group_count` / `group_index` over a buffer the host already holds, with
  `include/irgx.h` as the normative header. No corpus, no session, no index —
  those are `libgist`'s, and a host that only wants a regex no longer links them.

  Two things make it more than a wrapper. Every verb is a shim over the machinery
  the CLI already runs — the compiled-query kernel and the `Caps` capture arms —
  so an in-process answer is the same answer `gist --json` prints for the same
  pattern, down to the empty-match and `-w` rules. And the arm choice itself moved
  onto `Caps.compile`, so the C ABI and `exec/cold/writ/arm.zig` cannot drift on
  which engine a pattern belongs to; the CLI now supplies only its own half of the
  seam, which is that a bad pattern is a diagnosed exit rather than a status.

  The header also carries the substrate the whole ecosystem speaks: the six status
  codes and their dispositions, `irgx_last_fault`, `irgx_status_message`, and
  the pattern flag bits (now including `IRGX_PCRE` at bit 8, beside the bits
  `libgist` claims for its behavioral half). The `export fn` shims live in
  `surface/ffi/exports.zig`, the artifact's own root rather than the library
  module's, so linking two of the ecosystem's libraries cannot produce a duplicate
  definition of a symbol you asked for once.
- `relate patterns` now fronts its N compiled queries with **two SIMD prefilter tiers** in `src/kernel/slate/` — a **dragnet sieve** (`muster.zig`) for narrow slates and an Aho–Corasick **trawl** (`trawl.zig`) for wide ones — and the multi-pattern path was raced against **Vectorscan 5.4.12**, the maintained portable fork of Hyperscan, which is the reference implementation for simultaneous multi-pattern matching with expression-ID attribution. The README used to concede that race outright. It is now conceded only in one narrow band near N≈900.

  The sieve is Hyperscan's shape adapted rather than copied. Every literal extractable from the slate is bucketed, one bit per bucket, and the buckets are probed with nibble tables over the leading three bytes of each literal — so one 16-byte SIMD block costs a fixed number of shuffles regardless of how many literals are in play, and the three-byte stem makes a shared bucket produce roughly 256× fewer false candidates than a two-byte one would. Buckets are capped at four groups of eight, because the cost of a block is linear in the group count and measurement put the peak at four. Literals shorter than the stem wildcard their missing positions instead of being exiled to a slow path, and only single bytes fall through to `memchr`.

  That cap is also the sieve's ceiling, and it was the honest reason Hyperscan owned wide slates: past four groups, shared-bucket verification grows with N while Vectorscan's literal stage stays flat. The trawl lifts the ceiling instead of tuning against it. One automaton carries every pooled literal in DFA form — failure links resolved at build time, dictionary-suffix links so `she` also reports `he`, and an alphabet compacted to just the bytes the literals actually spell (typically ~64 columns rather than 256, which is what keeps the transition table in cache). Its per-byte cost is flat in the slate's width by construction.

  Making it _fast_ took one more thing. A textbook Aho–Corasick is latency-bound, not throughput-bound: each next state is a load whose address is the previous load's result, so a single stream stalls at cache latency per byte no matter how idle the core is. The trawl therefore sweeps **six interleaved streams** over disjoint regions, which have no dependency between them and so issue concurrently. Measured: 0.87 GB/s at two streams, 1.64 at four, **2.13 at six**, 1.95 at eight — six is the peak, and past it the live state exceeds what stays in registers. Each stream restarts at the root and runs `longest - 1` bytes past its end, which can only lose a match that began earlier, never invent one; the overlap guarantees every occurrence lies wholly inside some stream, and setting a play bit twice is idempotent.

  **Per byte, over one resident 64 MiB blob, gist is now faster than Vectorscan from N=2 through N=1024** — roughly 1.5–1.7× at small N on the dragnet, and 1.4–2.4× from N=20 up on the trawl, whose throughput moves only from ~2.2 to ~1.9 GB/s between 20 and 512 literals while the dragnet falls from 1.7 to 0.06 over the same span. Hyperscan keeps one band: from around **N≈900** its literal stage switches strategy and takes a ~1.1–1.2× lead, while the trawl is paying cache pressure on a transition table that has grown past L2 (~2.8 MB at that width). That row is printed beside the wins, because a table with no losing rows is not believable.

  The handover between tiers sits at **16 literals**, which is where the two curves measurably cross (dragnet 2.16 vs trawl 2.16 GB/s at 16; 1.83 vs 2.14 at 18). It is deliberately on the trawl's side of the tie: the curves are not symmetric there, so handing over one literal early costs nothing while handing over late costs the whole slope.

  **End to end over the corpus — the workload the surface actually exists for — gist wins by ~2×**: ten symbol patterns across the host tree in ~270 ms against Vectorscan's ~540 ms, ~1.2× faster than an `rg` alternation that does not even produce attribution, and ~13× faster than ten sequential `rg` runs that do. That win does not come from matching faster. It comes from the index, which decides which documents can contain each pattern before a byte of the rest is read — a filter a stream scanner structurally cannot have, because for Hyperscan correctness means every byte and every byte is the cost.

  That advantage has a boundary, and the harness now publishes it in the same mint rather than leaving it to be discovered. Arm 2's slate is drawn from a **selectivity band**, because corpus token frequency is not query frequency: an agent sweeps for `SessionStore`, never for `string`. Drawn from the raw token distribution instead, one literal in ten occurs ~49,000 times, every strategy must emit ~112,000 attributed lines, the index has nothing left to skip, and the same unmodified code measures 1.14× instead of 2×. That adverse pair is timed and printed beside the primary rows. Getting this wrong is easy and quiet — the first version of the mined slate did exactly it, and turned a real 2× into an apparent 1.02× with no code change at all.

  Exactness was the precondition, not an afterthought, and the tier split raised the bar rather than lowering it. The fused walk's output is byte-identical to N independent single-pattern runs; the arm-1 sweep re-derives the whole attribution vector at every N **in both tiers** — the one dispatch selected and the one it did not, forced through `GIST_MUSTER_TIER` — so tuning the width threshold can never move which mechanism has been proven exact; and it cross-checks per-pattern document counts against Vectorscan at every N. The trawl's own suite holds it to a plain substring oracle over suffix links, duplicate literals, overlapping occurrences, and the compacted alphabet, and plants a needle at every offset across every stream boundary. The certificate layer refuses to splice a timing if any of that fails, or if a row names a prefilter tier it cannot account for, and its gates whitelist the tokens that mean _proven_ instead of blacklisting the ones that mean _broken_ — a blacklist passes every spelling of failure it has never heard of.

  Three measured dead ends are recorded at their sites rather than quietly dropped. A four-byte stem cost more in table pressure than it bought in discrimination. Retiring a bucket's bit once all its patterns were found — which reads like a free win — made the nibble tables mutable, defeated register promotion, and measured worse across the whole sweep. And two interleaved streams in the trawl are _worse than none was worth_: at 0.87 GB/s the split's overlap costs more than the one extra concurrent load recovers, so the mechanism only pays from four streams up.

  One measurement hazard is worth naming because it nearly published a fabricated number. When a `gist serve` daemon is resident, the pure `relate` verbs consult its answer keep, which returns byte-identical stdout for a query already asked against an unchanged corpus. The harness gates arm 2's answer immediately before timing it, which primes that keep — so the first honest-looking run reported 3.2 ms and a 179× win over Vectorscan that was a hash lookup racing a search. Arm 2 now times with the keep disabled, and 4.3× is what the search actually earns.
- `vouch_test.zig` grades the premise the answer keep borrows — that two runs
  reading the same epoch saw the same corpus — against a real watcher over a real
  tree, on macOS and Linux alike. Neither suite that owns a half could see it:
  `keep.zig` is handed epochs by hand and does honest bookkeeping under whatever
  it is told, and `annals.zig` arms its own ledger and feeds itself synthetic
  `note` calls, so both stayed green while `inotify` never armed the annals at all
  and while lost coverage left the stamp standing still under a moving tree.
  `kqueue_test.zig` boots a real backend but is macOS-only by construction, so the
  Linux path had never been driven end-to-end. The new cases pin liveness (a
  backend that arms exact must actually vouch an epoch, the assertion the dead
  Linux keep would have failed), safety (across a randomized add/edit/delete/
  rename sequence, two samples reading the same non-null epoch must have read the
  same bytes, with a guard against passing vacuously on an epoch that never moved),
  and surrender (lost coverage must make the epoch decline outright, a deliberate
  shed must move it past anything held) — the last two graded through the keep,
  since a bit on a struct is not the hazard a served stale answer is.
- `zig build automata-rung` races the DFA against itself, because a whole-engine
  benchmark cannot attribute a layout change: a prefilter that skips the automaton
  entirely hides whatever the automaton did, and a document with matches in it
  spends its time reporting rather than walking. So the rung searches **match-free**
  documents with the automaton forced live, and reports a `seen` column — distinct
  states actually visited — so a row that never left the start state is visibly not
  evidence about the scan loop. Five arms: `shape` (alphabet, states, accepting,
  table bytes, build ns), `build` (ns/state, ns/step, visits/step, tier), `search`
  (the match test, head-to-head), `area` (throughput against table size at two line
  lengths, which separates *how big the table is* from *how much of it you touch*),
  and `width` (NFA words, so a claim about closure sparsity has to name the patterns
  where the premise holds). `bar.py` puts the same patterns through
  `regex-cli debug dense dfa` in byte mode for the cross-engine column. Two claims
  died on this rung's numbers and one landed — which is the point of building it
  before the optimization rather than after.

### Changed

- A Go caller can now retry a refused pattern instead of giving up on it.

  Every `Compile` failure used to be one `*irgx.Error` reading `invalid: bad
  argument, or a pattern this arm cannot compile (Unsupported)`. So if a pattern
  came from a config file or a flag or a user, there was nothing to branch on -
  `foo(?=bar)` is one flag away from working and `[abc` is just broken, and the
  binding could not tell you which one you had, or where.

  Now the two refusals are two Go types, and both fall out of the status code:

  ```go
  re, err := irgx.Compile(pattern)
  if errors.Is(err, irgx.ErrNeedsPCRE) {
  	re, err = irgx.CompileOpts{PCRE: true}.Compile(pattern)
  }
  ```

  `ErrNeedsPCRE` is the linear grammar declining a construct the vendored PCRE2
  has - lookaround, a backreference, an atomic group. It is not a defect, so it
  carries no offset and no fault: the seam declines by returning `IRGX_STALE`
  and installs nothing, and this binding reads nothing, which also means a
  declinature can never pick up the detail an earlier failure left on the same
  thread. Malformed text is a `*SyntaxError` instead, with `Expr`, the byte offset
  in `At`, and the engine's word for the defect, so you can print a caret under
  the byte it stopped on. `At` is `-1` when there is no position rather than a
  stand-in `0`, since byte 0 is a real answer. It unwraps to the `*irgx.Error`
  it always was, so nothing that used to work stopped.

  Both classes come from the return value alone. There is no fault-name string
  compared anywhere in the binding, which is the point - a construct list is the
  thing that drifts.

  The vendored archives are rebuilt on the fixed engine, and the retry idiom is
  covered end to end: four declined constructs that must compile once the flag is
  set, five malformed ones that must not, at the offsets the engine reports.
- A Python caller can now catch the refusal that has a fix, and fix it.

  `irgx.compile(r"(?<=\$)\d+")` used to raise the same `irgx.error` as
  `irgx.compile("[abc")`, so the only way to tell "this needs the other engine"
  from "this is broken" was to try `pcre=True` on everything and see what stuck.
  The first one is not a failure at all - the linear tier declines it and PCRE2
  takes it as it stands - and the engine says so on the return value now, so the
  binding does too.

  A declined pattern raises `irgx.UnsupportedPattern`, and the message says
  outright that `pcre=True` accepts it. So this is a real handler:

  ```python
  try:
      pattern = irgx.compile(user_pattern)
  except irgx.UnsupportedPattern:
      pattern = irgx.compile(user_pattern, pcre=True)
  ```

  It is a subclass of `irgx.error`, so nothing that already catches
  `irgx.error` changes.

  `irgx.error` also grew `re.error`'s three attributes - `msg`, `pattern`,
  `pos` - which is how a Python user already expects to find a bad pattern. `pos`
  is the byte offset the engine located the refusal at, so a program compiling
  patterns out of a config file can point at the character instead of reprinting
  the line. It is `None` on `UnsupportedPattern`, and not because we withheld it:
  a tier that stepped aside files no report at all.

  Which class you get is decided by the status code and nothing else. I had this
  keyed on the fault name matching the literal `"Unsupported"` for about an hour,
  which is a spelling agreement rather than a contract - rename it upstream and
  every binding quietly stops suggesting `pcre=True` instead of failing loudly. A
  declinature is a status, so there is no string compare left in the binding at
  all, and no keyword list of lookaround-ish constructs either; that would have
  been a second opinion on a question the engine already answers by asking PCRE2.
- A Rust caller can now retry a refused pattern on the other engine in two lines,
  and point at the byte a malformed one died on.

  `Regex::new(r"(?<=\$)\d+")` used to come back as one opaque `Error::Pattern`
  carrying a fault name and no position - the same answer `[abc` gave. So the two
  things you can do about a refusal, retry it with `pcre(true)` or show the user
  where they went wrong, were both unavailable, because you could not tell which
  refusal you had.

  Now the C seam answers `IRGX_STALE` for the first and `IRGX_INVALID` with
  an offset for the second, and the enum says so:

  ```rust
  match Regex::new(pattern) {
      Err(Error::NeedsPcre { .. }) => RegexBuilder::new(pattern).pcre(true).build(),
      other => other,
  }
  ```

  `Error::Syntax` carries `at`, a byte index into the pattern you handed over,
  and it is a real index - never past the end, never mid-codepoint - so
  `&pattern[..at]` is the part the engine got through and a caret under it needs
  no bounds check. An offset that would not slice is dropped to `Error::Pattern`
  rather than reported wrong. `Error::Pattern` is still there, and is now what it
  should always have been: the engine's own ceilings, where no single byte is the
  problem so there is no offset to invent.

  Which variant you get is decided by the status code alone. Nothing in the crate
  compares a fault name as a string any more, so a build that renames a fault
  cannot silently turn a retryable pattern into a syntax error. And because a
  declinature installs no fault, `NeedsPcre` reads nothing from the fault slot -
  it cannot pick up the leftovers of somebody else's failure.

  The retry is not done for you on purpose. The linear engine is linear in the
  length of the text and the PCRE2 arm is not, so a program compiling patterns
  a stranger typed may want to report and stop. Both are one match arm.

  Two new variants on a `#[non_exhaustive]` enum, appended, so `cargo-semver-checks`
  calls it minor.
- A `\b`-bearing program can now run through the memo like any other, instead of paying a call per byte.

  `Cache.glide` used to require the caller to prove one row for the whole run, and a word assertion cannot promise that: the landing gap's shape depends on the word class of the bytes either side of it, which changes as the haystack does. So `\b` / `\B` / `\<` / `\>` were excluded from the run outright and walked byte by byte through `step`, which recomputes the row and reloads the memo's base pointer every time because it is a call that might determinize and reallocate. That exclusion was the entire deficit: on a match-saturated line `\bfoo\b` sat below ripgrep while `f.o` — the same automaton work, no assertion — was comfortably ahead of it.

  **The row was never on the dependency chain.** The recurrence is `off = trans[off + base + class[b]]`. Both `base` and `class[b]` are derived from bytes alone, so an out-of-order machine has the address in hand while the previous load is still in flight, and per-byte latency is that one load whether the row moved or not. A word-bearing run therefore reads its row off the two bytes straddling each landing — the one just consumed, and the next one it would consume — indexed `word_before + 2*word_after` into the four rows an interior landing can wear. Scan direction decides which byte is on which side, so the backward jaw gets it for free. Past 0x7F the answer depends on a scalar a byte-shaped row cannot see the whole of, so a Unicode program stops the run before such a byte and lets `gapAt` decode it properly, and refuse where it must.

  The two grains are separate comptime loops, and the word one is deliberately the only one that pays a call: folding them — handing a word-free program four copies of its one row so the lookup is unconditional — reads better and costs 60% on a long glide, because two extra byte loads per iteration are nothing against a cache miss and everything against the L1 hit this loop is made of.

  On the 41.6 MB match-saturated line, `\bfoo\b` goes 0.86x ripgrep to 1.78x — and the arms that were already fast do not move (`f.o` 2.06x to 2.07x, `f.o|zzzzq` 1.55x to 1.56x, `foo \w+ x` 1.30x to 1.29x, `f[a-z]*o` 1.80x to 1.85x), which is the whole point of the split and of letting only the word arm pay the call.

  That closes the last shape ripgrep led on. End to end against the arm this began from, on the run that reproduces the dossier's recorded baseline: `f.o` 0.87x to **1.96x**, `f.o|zzzzq` 0.80x to **1.53x**, `foo \w+ x` 0.54x to **1.28x**, `f[a-z]*o` 0.71x to **1.87x**, `\bfoo\b` 0.49x to **1.76x** — every automaton arm now ahead, by 2.3x to 3.6x on where it stood.

  Answers are unchanged: 600 differential cases against ripgrep over a haystack of word/non-word churn, Unicode word characters and invalid UTF-8 — 20 patterns exercising `\b` `\B` `\<` `\>` `\w` `\d` bare and combined, each under `-i`, `--no-unicode`, `-w` and `-U`, each read out five ways (`-o`, `-c`, `-n`, `--column`, `--count-matches`) — agree byte for byte, and agree identically before and after this change. The caliper's differential sweep against the Pike VM oracle passes, as does the regex suite.
- A boolean document scan (`gist -l`, and the compiled-query path the resident
  session and the FFI share) no longer crosses the buffer twice. When a pattern has
  a mandatory literal, the ladder already scanned for it — and then threw away
  *where* it was, so the slowest machine in the ladder restarted from byte zero to
  rediscover a position the SIMD kernel had already had. `presence` is literally
  `findRaw(hay, 0) != null`; the offset was free and discarded.

  `docMatch` now calls `find` and hands the machines below it the suffix beginning
  at the line that holds that occurrence. It is sound for exactly the reason the
  per-line model exists: no match crosses `\n`, and every match contains the
  mandatory literal, so a line lying entirely before the literal's first occurrence
  cannot match. Finding the seam is one `lastIndexOfScalar` bounded by a line, so it
  costs a line's worth of work however large the buffer, and `-U` — the one model
  where a match may cross `\n` and the offset proves nothing about a start — enters
  through `bufMatch` and is guarded out explicitly.

  **16.30× geomean over 30 (pattern × match-position) pairs** on 2 MiB documents,
  28–37× on the eight slate rows with an interior literal and a late match
  (`[0-9a-f]{8}-…-[0-9a-f]{12}` 35.51×, `\w+X` 29.92×, `a.*b.*c` 28.08×). End to
  end against the incumbent on this repository, best of 5 with byte-identical file
  sets: `\w+X` 206 ms vs ripgrep's 386 ms, `[a-z]+_[a-z]+_[a-z]+` 209 vs 453,
  `if\s+err\s*!=\s*nil` 212 vs 347, `\w+\.\w+\(` 224 vs 585.

  The controls are why this is a free mechanism rather than a trade. Two slate rows
  read **1.00×**: their match-free fill can itself spell the literal, so the first
  occurrence is at lead 0%, the suffix is the whole buffer, and they save exactly
  nothing while costing exactly nothing. A new adverse arm makes that a measurement
  instead of an argument — the same documents with no match spliced at all, so every
  row rejects and the seam can only cost: **worst 0.98×**, the instrument's noise.
  It also fails the run if a suffix ever reports a match the whole buffer does not
  hold, which is the one way this could be wrong rather than slow.

  `automata-rung -- inner` carries the audit that scoped it. Of 33 rows, 25 prove a
  mandatory literal the engine already searches for, 11 of those are *interior* and
  so beyond a first-byte skip's reach, and where both strides are comparable the
  literal skips 6.9× further than the first-byte set. Only 3 rows could bound a
  confirmation *window* — an interior literal and a finite longest match — which is
  why this ships as a line seam and not as the reverse automaton the field builds
  for the same claim: `inf` is the ordinary case, so there is no window to confirm
  inside. Span queries are unchanged; the caliper's reverse jaw already answers
  those.
- A multi-pattern slate now settles every pattern whose literals are a match EQUIVALENCE, not just the bare `-F` needles. `slate/muster.zig` splits two facts a literal cover carries — is it COMPLETE (every match contains one of these, so a miss excludes the pattern) and is it EXACT (containing one is a match, so a hit needs no engine confirm) — and it had only ever read the first from a regex. The second was already proven elsewhere: `analysis.pureLiterals` decides whether a whole pattern is exactly an alternation of literals, `lower.zig::literalEngine` has long built the single-pattern `LiteralSet` at `.exact` authority from it, and the slate simply had no accessor. `CompiledQuery.equivalence` is that accessor (empty under `-i`/`-w`/`-U`, and `pureLiterals` already refuses a literal carrying `\n`, so the per-line claim holds), and `coverOf` now returns cover and authority together as one `Cover`, because deriving them apart is how a nominating literal gets mistaken for a deciding one. This settles more than alternations: a regex typed without `-F` that happens to be a plain literal (`err != nil`) was previously confirmed on every hit, since only a `.literal` BODY qualified. Measured in `bench/rungs/patternid` (new fifth section, every row checked against N independent single-pattern engines): a six-pattern all-settleable slate goes 3.26 -> 1.67 us/doc on a hitting document (1.95x) and 56.1 -> 18.6 us where the matches sit behind a long non-matching prefix (3.01x), which is the shape that isolates what settling removes — a skipped confirm is a skipped SECOND pass over the document, where an early hit lets the confirm exit at once. The miss control is unmoved at 17.6 us, as it must be: a document that matches nothing is rejected by the same SIMD roll either way. The mixed `re-6` slate is flat and that is the honest half of the result — four of its six bodies are classes and quantifiers whose confirms settling cannot touch, and they dominate the row.

  The differential fuzz written to guard this also found a live defect one layer up, now fixed. `PatternSet.anyMatch` returned the fused gate's verdict outright, but `buildGate` fuses pattern TEXT and never carried `-w`, so a slate holding a word query answered `true` for "concatenate" against `-w cat` — a false positive from an accelerator, in the API a batch workload spends most of its time in. The gate is a sound OVER-approximation, so it keeps its real job (rejection, which is exact) and loses the one it never had: `gate_exact` is false when any spec carries `-w` or `pcre`, and `anyMatch` confirms behind an inexact gate instead of trusting it. `docMask` now gates on the gate directly rather than routing through `anyMatch`, which drops a double confirm on the hit path. Both the settling boundary (anchored alternations, word queries, and literal-prefixed regexes must NOT settle, each chosen so that settling it would produce a wrong answer rather than a slower one) and the gate regression are pinned in `patterns_test.zig`, whose every parity assertion runs three ways: muster armed, muster stripped, and N independent engines.
- A pure-literal alternation now resolves its span in one fused SIMD jump instead of one scan per branch. `litSpan` walked `re.lits` calling `simd.indexOfPos` per literal and took the leftmost answer, so every span cost a full scan per branch — and a branch that occurs nowhere cost a full scan of the region every single time, which is quadratic in the number of absent literals. It now asks `simd.indexOfAnyPos` once for the leftmost position any needle starts at, then identifies which one in declaration order (leftmost-first needs the branch order, and `indexOfAnyPos` has already verified a needle is there). Measured on a 1 MB single line: `foo|zzzzq` 313.6 ms to 1.26 ms, `foo|bar|zzzzq|qqqqw` 925.5 ms to 0.75 ms — 248x and 1230x, and the ratio grows with the corpus because the old cost did. The single-literal case is special-cased back to one `indexOfPos` with no membership check, since a lone literal *is* the span and needs no attribution; that is the shape most code searches have (`gist SessionStore`), and it stays exactly the one scan and one add it was. Against ripgrep on a 41.6 MB saturated line, `foo|bar|zzzzq|qqqqw --count-matches` now runs 3.2x faster (8.9 ms vs 28.5 ms) at identical counts.
- A span no longer pays for what the prefilter has already told it, and a forward jaw that never re-seeded no longer wakes the backward one.

  **Stand on a candidate before opening one.** `forwardEnd` used to enter the automaton at the search origin and consult the prefilter only after the walk died there. On a match-dense line that is a start closure, a bound scan, and a glide that dies on its first byte — three quarters of a span's fixed cost, spent to rediscover what the prefilter was about to say. The license to skip ahead is the loop's own: a prefilter is offered only when no match can be zero-width, so every match consumes a first byte the prefilter admits, so a gap it refuses cannot begin one. Two things had to become explicit for the jump to be safe — a machine that can match nothing (`zeroWidth`) may not be skipped past, and an EMPTY first-byte set is `analyzeFirst` saying *I could not tell*, not *no byte begins a match*. The second only ever cost a wasted jump while the prefilter was consulted after a death; now that it decides whether there is a match at all, reading it as authoritative would report every haystack as matchless.

  **One hunt per span, not two.** A span asks the first-byte set where the next candidate begins (to stand on one) and where the one after it begins (to bound the glide, so the seeding decision holds for the whole run). On a match-dense line those are the same question one span apart: the second scan crosses exactly the bytes the next span's first scan would cross again, because a match ends before the candidate that bounded it. `Jaws.recall` remembers one answer as a claim about bytes rather than about a call — *the first candidate at index >= `from` is `at`* — and answers a later question only when that question's floor lies in `[from, at]`, where the recorded scan already proved there is nothing. The walk reads the haystack once.

  **A jaw that never re-seeded already knows the start.** `program/core.zig` compiles an ANCHORED program; unanchoredness is the caliper's re-seed and nothing else. So every thread alive at the end descends from the single start `enter` seeded, and if no step in between re-seeded, they all began at that one gap — which is the leftmost start reaching that end, which is the answer the backward jaw exists to compute. Under a first-byte prefilter a re-seed only fires where the prefilter admits a byte, so on the shape this engine is for — a match found by jumping to its own first byte — the second jaw does not run at all. When a re-seed did fire, some survivor may have begun later than the entry and only the reversed automaton can say which, so the fallback is the whole of the old behavior and nothing declines that did not decline before.

  **And the cache pointer stops being a decision.** `Jaws.cache` is called twice per span to arrive at a pointer that has been the same pointer since the first line of the file; it now inlines to a load and a branch, with `Cache.init` moved to a cold `open` beside it.

  Together these are what turn the saturated line around. On the 41.6 MB single line with a match every 40 bytes — the one shape ripgrep still led, where per-step cost is the whole workload and there is no prefilter skip to hide behind — every word-free automaton arm crosses from behind to ahead: `f.o` 0.91x to 2.06x, `f.o|zzzzq` 0.84x to 1.55x, `f[a-z]*o` 0.73x to 1.80x, `foo \w+ x` 0.56x to 1.30x. `\bfoo\b` moves 0.51x to 0.86x and stays behind, because a word assertion could not enter the run yet; the note after this one takes it. Measured interleaved against `rg --count-matches` with each arm's own process floor subtracted, counts identical on every pattern. A pure-literal alternation (`foo|bar|zzzzq|qqqqw`, 0.85x) is untouched by any of this and stays where it was — it never builds a caliper, resolving by SIMD substring scan instead.
- A wire format for the finished DFA — build the table once, embed or map it, skip
  determinization — was priced and will not be built as a performance feature, because
  the median table in this engine is cheaper to **construct** than to **read back**.

  Caching is an exchange, and the cost it *removes* is the only half usually measured.
  `automata-rung -- build` already timed the half being removed: determinization alone,
  min of 15, per pattern. The half being added is what a load costs, and at these sizes
  that is a syscall rather than a transfer. A frozen table is row-major
  `[state][class]` u32, so the widest pattern on the slate needs 6,168 bytes and an
  ordinary one 864; measured on this machine, `open`+`read`+`close` of a warm file
  costs **5.6 to 5.9 microseconds at best and does not care whether it is 1 KB or
  25 KB** — and 11 microseconds when the machine is busy.

  Put the two columns side by side and the feature inverts on half the slate. Median
  build is **5.5 to 5.7 microseconds** against a best-case load floor of the same
  size, so **16 to 18 of 33 patterns determinize faster than they could be read** —
  23 of 33 at the contended floor. A cache that cost literally nothing to maintain,
  key, or validate would still be a regression on them. The entire 33-pattern slate
  determinizes end to end in about **2.05 milliseconds**.

  Where it wins, it wins nothing that matters. The one pathological row — a 514-state
  automaton from a 512-repetition class — builds in ~1.5 ms, which is **3.19%** of that
  pattern's own 47.4 ms tree-wide query and inside its run-to-run deviation. For
  ordinary patterns the share is four orders down: **0.014%** of a 40 ms query. And the
  most build-heavy workload the tool can even express — 121 regexes compiled against a
  zero-byte file, where scanning is free by construction — spends **0.9 ms of 7.5 ms**
  on compilation, flat from 41 patterns onward, with the remainder being process
  startup that no table format touches.

  The structural finding is the one worth keeping. Table entries are premultiplied row
  offsets indexed directly, and the transition rows are deliberately **not total** —
  both properties are load-bearing for the engine's fastest inner loop. Together they
  mean a table read from disk is an unvalidated array of raw offsets, so a trustworthy
  loader must bounds-check every entry while preserving all-or-nothing row filling:
  a sweep over states times classes, **the same order as the determinization it was
  meant to avoid**. The honest load cost is therefore strictly worse than the floor it
  already loses to.

  The format keeps its case as a *feature* — an embedder that ships a fixed pattern set
  with no parser is a real request, and none of this touches it. What is settled is that
  such a format may never be sold as speed, and may never soften the premultiplied
  non-total layout to make serialization convenient: that trade would spend a measured
  1.10-1.16x on the hot loop to save a median 5.6 microseconds of construction.

  Nothing in the shipped engine changed. This is measurement, and it says which half of
  a cache to measure first.
- An alternation whose every branch consumes exactly one byte now lowers to **one**
  `consume` state over the union rather than to N consumes behind N−1 splits.
  `(a|b|c|d|e|f|g|h)` is a byte class written the long way, and the Thompson
  construction was taking it literally: `ast/algebra.zig` had always known this, but
  on a graph the compiler deliberately does not read, because interning
  re-associates the alternation spine and re-association is not leftmost-first-safe.
  So the fold lands at the Thompson seam itself (`compile.zig::oneByteUnion`),
  without re-bracketing anything.

  For `(a|b|c|d|e|f|g|h){10}`: **151 → 11** NFA states, **9 → 2** byte classes,
  **792 → 176** table bytes, and determinization **56.9 µs → 3.6 µs (15.8×)**. For
  `(a|b)*a(a|b){5}` and its 8-fold cousin: 21 → 9 and 30 → 12 NFA states, 1.40× and
  1.52× faster determinization, with DFA state count, accept count, and table bytes
  **byte-identical** — the language and the alphabet are unchanged there, so the win
  is purely a narrower closure per determinization step.

  It also closes a loose end rather than just adding a win. The table-reduction pass
  had one everyday-slate row where a post-hoc column merge still found redundancy,
  recorded as a suspected front-end artifact; that row now arrives minimal and the
  **ASCII column collapse went from 1/32 rows to 0/32**, which upgrades the
  suspicion to a result. The 4.5× of table came with a 15.8× faster build instead of
  costing 2% of a determinization already paid in full.

  **Why it is safe where re-associating an alternation is not.** Leftmost-first
  selection depends on branch order only when two branches reach the same start with
  different ends. When every branch consumes one byte to the same continuation, each
  branch's thread arrives at the identical (state, position) pair — which the Pike VM
  already dedupes — so the surviving thread is the same one whichever branch had
  priority. The fold therefore declines, by construction, everything that could
  observe order: `.concat` and `.uclass` (more than one byte), `.empty` and the
  assertions (none), and every quantifier (a variable count). `a|ab ⇒ a` is
  unaffected because `ab` is a concat, and the capture VM has its own alternation
  lowering, so no group boundary is reachable from here.

  Judged by two new structural tests (confirmed load-bearing by deliberately
  breaking them), the full suite including the Pike-vs-DFA differential fuzz and the
  independent adversarial oracle, identical ripgrep file sets on ten alternation
  patterns tree-wide, byte-identical `-o` streams per file, and 6/6 on the order
  probes that are the real hazard: `a|ab ⇒ a`, `ab|a ⇒ ab`, `e|er|err ⇒ e`,
  `err|er|e ⇒ err`. `(?:foo|bar|baz|qux|quux|corge){8}` is the untouched control —
  concat branches, so 209 states and 163 µs before and after.
- Changed **the terminal layout** — a `gist` run a human is watching now groups matches under a filename title and numbers the rows beneath it, the way `rg` has always done and gist never did. Typing the same query into a terminal used to return the piped shape: every row re-stating the same long monorepo path in front of the line you actually wanted to read. It is the one destination-conditional behavior that changes the *shape* of a row rather than its paint, and it arrives with the byte contract untouched — a pipe, a redirect, `--json`, `-0`, and `--plain` all still emit ripgrep's exact bytes, proven by the 411/411 differential and the line-parity gate.

  **The destination is the last party asked, never the loudest.** `--heading` joined `-n`/`-N`/`--column` in `answer.Locus`, which already existed to hold *"nobody has answered this yet"* — so a heading is recorded rather than applied, and the terminal fills only the silence. `--no-heading` and `-N` mean exactly what they say on a terminal, in either order, because there is no order left for them to depend on. Parsing stays free of I/O (every grammar test still runs without a tty); the unspent answers ride out on `Parsed.locus` and the one caller that knows the real fd re-resolves them. `--plain` remains the single spelling that stands the whole destination-conditional layer down, and is now byte-verified equal to the piped run.

  **Including the case rg leaves alone.** A stdin-only search stays unnumbered — `printf … | gist pat` prints bare lines, where mixing stdin with a real path numbers both — because there is one unnamed source and no walk, so a locator names nothing the reader did not already have. That divergence is what a 21-case layout sweep against real `rg` under a pty was built to catch, and did.

  **Two engines, one filename.** Painting the heading exposed that a path row had four implementations: the row prefix, the serial title, and the parallel worker's buffered `-l` list twice over. Only the first was painted, so `gist -l` printed the one uncolored filename in the program — and a naive fix would have colored the listing only when the run happened not to shard. The parallel writers now share a single `pathRow`, and `sift`'s hand-rolled title line is gone in favor of the emitter the serial engine uses, so a listing cannot change color depending on how the work was split.
- Charter `skip` now binds cold search too, including `-uu`. It used to size only
  the index and relate corpora — cold walks consulted gitignore and the hidden
  rule alone, so `--no-ignore --hidden` walked straight into every directory the
  tree had declared out of the corpus. On this repo that meant a `-uu` sweep of
  `.local`'s multi-gigabyte scratch (build artifacts, bench corpora, daemon state),
  which is what turned an interactive search into a minutes-long read of build
  artifacts.

  The cold prune now asks `haystack.isPolicySkip` first: charter `skip`,
  `GIST_SKIP`, and `<outDir()>/skips.list`. Those are structural — a fact about
  which directories exist in the corpus — so `-uu` and `-g` cannot un-hide them.
  Pointing a root at the directory itself (`gist PAT .local`) still searches what
  you named; only descending into it from a parent is refused. The generic
  baseline (`.git`, `node_modules`, …) stays off the cold path on purpose:
  ripgrep parity requires `-uu` to enter those.

  `.irregex.toml` now declares `skip = ["derived-out", ".local"]`. Proven on this
  tree: a root `-uu` for a token that lives in thirty `.local` fixtures returns
  only the four tracked/target copies and zero `.local/` paths; the same query
  scoped to `.local` still finds all thirty; and `-uu` over `.git` still answers
  (ripgrep parity — `.git` is baseline, not charter).
- Crest sieve: keep one forced crest per top-level alternative — a `crest.Swell` —
  instead of collapsing the branches into a single componentwise-min vector. The
  fold was sound but blind: two alternatives forcing disjoint classes min to `0⃗`,
  and multi-`-e` reaches the engine as exactly that shape, so every multi-pattern
  search ran with the sieve silently disarmed. A document is now pruned only when
  it clears no alternative, which is weakly more selective than the fold on every
  document and never less sound (PROOF.md §3.9, Theorem 4 + Corollary 4). On the
  206 MiB host corpus `[0-9a-f]{12}|~{60}` goes from 0.0% to 84.4% of files
  pruned and `[0-9]{6}|[A-Z]{6}` from 0.5% to 38.5%; `gist -e '[0-9a-f]{12}' -e
  '[~]{60}' -l` runs 2× faster end-to-end for a byte-identical answer, and every
  single-alternative query is bit-for-bit unchanged. The split walks the branch
  spine iteratively and holds 8 alternatives inline, so a longer chain degrades
  back toward the fold rather than allocating or recursing; one branch demanding
  nothing disarms the whole swell. `zig build crest` now carries the fold as a
  measured ablation column and fails closed if the disjunction ever leaves more
  survivors than it.
- Crest sieve: make `\d`, `\w`, and `\s` prune at the engine's default flags. The
  linear engine folds them over Unicode scalars, and the sieve measures bytes, so
  under Theorem 2 a `uclass` node certified nothing — the sieve stood entirely
  down for the ordinary spelling of the exact query family it exists for.
  `[0-9]{6}` pruned 92.7% of the corpus while `\d{6}` pruned 0.0% and ran at
  1.00x. The repair gives every class a scalar-closed twin, `C+u = C ∪
  [0x80,0xFF]`: every byte of a multi-byte UTF-8 sequence has bit 7 set, so a
  codepoint class whose ASCII members lie in `C` spends only bytes in `C+u`, and a
  run of n such codepoints is a run of at least n such bytes (PROOF.md §3.7,
  Lemma 2b). A `uclass` is now priced by the same `atom(set, min_len)` as a byte
  class, reading its encoding byte set and its cheapest UTF-8 length off the
  engine's own AST — no `unicode` flag reaches the calculus. Measured by ablation
  on the 21 854-file corpus: `\d{6}` 0.0% → 73.7% pruned and 1.00x → 2.12x,
  `\d{4}` 0.0% → 52.8% and 2.13x, `\s{4}` 5.5%, `\w{8}` 1.4% — the wide classes
  stay nearly worthless, which is the honest price of a class that excludes almost
  nothing. The eight ASCII lanes keep their indices and their numbers, so nothing
  that certified before certifies differently; the family simply grew a second
  half only a `uclass` reaches. The sidecar is 32 bytes per document instead of 16
  and its schema signet changes, so an existing crest table is rebuilt rather than
  misread. Byte parity of search output was checked over 32 query shapes against
  the same binary with the sieve disabled, on a frozen corpus, with the output
  budget lifted: identical result multisets on every one.
- Crest sieve: scan each document as four interleaved pieces instead of one pass,
  for 2.56x the throughput at a byte-identical answer. Widening the class family
  to 16 lanes cost no scan time — all of it is one 256-bit vector — but the
  per-byte update is a saturating add feeding an AND, a loop-carried chain about
  three cycles deep that a single scan cannot fill; it ran at 4.4 cycles/byte with
  the machine mostly idle, and preshaping the reset mask into a table to cut the
  op count moved it by nothing, which is what a latency bound looks like rather
  than a throughput one. Four pieces put four chains in flight and still fit `cur`

  - `best` in half the NEON register file. The pieces rejoin exactly, by the run
    algebra the query half already folds over the pattern AST: each piece reports
    its leading run, best interior run, trailing run, and whether it ever broke, and
    the join is `max(F₁, F₂, S₁+P₂)` — `swell.Profile.concat` under another name.
    Leading runs are measured in a separate scan that stops once every lane has
    broken, which ordinary text does within a few dozen bytes, so the main loop
    stays three operations wide. Ablated back to back on the 21 854-file corpus:
    single-thread scan 0.73 → 1.87 GiB/s, from 0.63x to 1.62x the scalar per-byte
    reference, and the sharded whole-corpus index build 45.4 → 19.1 ms. Byte-
    identical on all 21 854 documents, and `crest_test.zig` pins the split against
    the single-piece definition over documents that straddle the interleave floor,
    with breaks walked onto and around every cut, whole-piece runs that must carry
    through, and a run past the u16 cap so saturation crosses a join.
- Each level of the codex's wavelet tree is now woven in **one pass instead of two**, which makes the tree **2.7×** faster to build (2382 ms → 897 ms over a 200 MB corpus; 2.59× at 32 MB). The old node builder walked its sequence twice — once to code the level's bitvector, once to partition the sequence for the two children — because it only learned where the split fell by counting during the first walk. It never needed to count: a node holds _every_ occurrence of _every_ symbol in its alphabet, so the frequency histogram that already shapes the Huffman code also says exactly how long each half will be. Knowing the split up front collapses the two walks into one, and the O(σ) sweep that computes it now also fills a symbol→bit `route` table, turning the hot loop's Huffman bit extraction into a single byte load. The level's bits accumulate in a register and land one 64-bit word at a time rather than a read-modify-write per symbol.

  The combinadic RRR encoder walks the set bits directly (`@ctz`, then clear the low one) instead of scanning every position up to the last one — same sum, same table, `popcount` iterations instead of `last_set_bit + 1`, measured 2.0–2.2× on real root-level blocks.

  Neither is a new answer, and that is checked rather than asserted: the old and new node builders were run side by side in one process over the same BWT and agreed exactly on all 209,715,201 `access` results and every sampled `occ`, and the on-disk format is untouched.

  Both were measured, not guessed. `Codex.build` was profiled phase by phase after the libsais swap: the wavelet tree was 85% level-weaving and only 15% entropy transcode, and serialization — the suspected pole — was never one (51 ms for a 53 MiB blob at 200 MB). `Tree.build` now documents that `freq` must be the histogram _of_ `seq`, an assert both existing callers already satisfied.

  The same profiling rejected a change that looked free: folding the BWT histogram into the gather loop that produces it measures 0.87–0.90×, i.e. reliably _slower_, because the counter update depends on the byte just loaded and starves the gather's memory-level parallelism. It stays two passes, with the measurement recorded at the site.
- Every candidate prefilter now sweeps the per-branch alternation cover when a
  pattern has no pure-literal equivalence set, so a class-led alternation like
  `[A-Z]+_TYPE|[a-z]+_kind` gets the same one fused whole-buffer Teddy sweep a
  pure-literal alternation already got. Previously each site declined and the
  engine re-scanned for those same literals once per line. `maskLiterals` is now
  the single place that ranks which set is sound to sweep with, because the bug was
  that three sites each derived it themselves: the line-mode mask, the `--json`
  mask, and `--json`'s solo-shard jump — which fans one large file's record stream
  across cores and so had gone unnoticed entirely. Confirming the cover once per
  buffer instead cut the line-mode shape's CPU 1.6x (0.577s to 0.359s over
  llvm/lib) and the solo-shard shape's 1.9x (0.182s to 0.096s over a 107 MB
  single file, 0.99–1.02x on pure-literal and single-class-run controls), match
  volume held fixed and each measured against a binary differing in that one line.
  rg parity holds at 411/411 on both engines, plus 42/42 unsorted on the solo file
  — unsorted because the cover changes how much body the jump skips between hits,
  and the incremental `line_number` count and the shard merge order are what would
  show it. The cover is withheld under `-i` and `-U`, where a match need not
  contain its bytes verbatim.
- Every persisted artifact now carries the same BLAKE3 seal, minted through one new primitive — `signet` — instead of three answers and two silences. The kinship and fragment atlases had an FNV-1a u64 trailer, the codex an XxHash64 one, and the two largest blobs (`index.gist` at ~42 MB, `content.shard` at ~215 MB) plus the shelf, the phantom treemap, and the crest sidecar had nothing at all; each of those trailers was a hand-written write/verify pair kept in step by hand. A signet is a 256-bit digest under a NUL-terminated domain label (`artifact`, `content`, `schema`, `rollup`), so a schema digest can never be accepted as an artifact seal whatever the bytes, and a format's whole corruption story is now two calls: `sealInto`/`sealAt` on the way out, `unseal` (eager) or `body` + `verify` (deferred) on the way back. The split is deliberate — a mapped artifact exists so a query faults in the pages it touches and not the other quarter-gigabyte, so mapping takes the body and offers `verify` for the moment someone actually asks, while a loader that already reads every byte pays nothing to prove it. The crest sidecar gains the most: its rot is the one kind that produces a MISSED match rather than a wrong one, since a ρ(d) that decays downward prunes a document that would have matched while every layout check still passes. The crest sidecar's semantic-schema hash moves to the same primitive; the C-ABI schema digest deliberately stays on SHA-256, because four language bindings must mint it from Python and only SHA-256 is in all of their standard libraries. Hash-table keys stay on Wyhash and the LZ78 phrase hashes stay on FNV — one is never persisted and the other IS the sketch, not a checksum of it. On-disk formats bump (`GISTSHD2`, `GISTTRE2`, `GISTCRS3`, atlas v4, frag v2, codex v2, shelf v2, postings v3); existing caches fail closed and the generation lifecycle rebuilds them.
- Five kernel doc comments cited a scratch directory that only ever existed on
  one machine. A reader outside that machine got a filing location instead of a
  reason, which is the worst of both: the claim reads as measured, and the
  measurement is unreachable.

  Each citation is now the summary it should always have been. The calibration
  gate says its two rates were taken through the shipped code paths with the page
  cache pre-warmed, and that R_scan is an absent rare needle so every block
  filters out. The 17.6-17.9x hit-to-hit sweep says it is the `fileLit` loop
  shape clocked inside the kernel, best of 3, with the hit count asserted equal
  across arms - so nobody reads it as a CLI wall clock that also paid intake,
  walk and emit. The joint-correction table says its training split is held out
  by construction rather than after the fact. The rarity range says its oracle is
  brute force over every offset pair, not a heuristic standing in for one. The
  span walker's 3.2 ns/byte says what was walked and that three patterns agreed,
  and the boolean walk's ~0.25 it is measured against is now bracketed by a proof
  you can run: `zig build automata-rung -- burst` reports 0.23-0.36 ns/byte for
  the doc walk on a match-free document. The ladder's per-instance slice proof
  says it is a same-`Regex` A/B with the answers checked equal inside the timing
  loop, over a named 64 MiB corpus.

  Not one number moved and no code moved. The figures were always right; they
  just used to point somewhere you could not follow.
- Forty-two undeclared error names across seventeen files were spellings, not facts. The ratchet baseline that tracked them is now empty: every name a function produces is a declared member of one of five domains, and the conditions that were never failures at all left the error channel entirely.

  **A synonym is a handler that will never be written.** Zig unifies error names globally, so `BadFrame` and `BadOpcode` were two names one `switch` had to carry even though no caller anywhere distinguished them — and a third spelling could accrete tomorrow without anything noticing. The same fact had been minted repeatedly under different names at different call sites: `TooManyDocuments`, `SizeOverflow`, and `BufferTooSmall` all meant "this sidecar cannot be written as asked" and all produced the identical caller response; `TooLong` and `Overflow` were one varint's two ways of not being a canonical `u32`; `ForkFailed` and `WakePipeFailed` were both the OS refusing a handle. Each now names its fact once — `UnexpectedFrame`, `Oversized`, `NonCanonical`/`Corrupt`, `Exhausted` — and the three genuinely new facts (`BadPattern`, `Exhausted`, `Oversized`) were added to `src/fault.zig` **and** to `[fault_domains]` in `contract/search_api.toml` together, which is the only way to add one. `Io` in the wire set had zero producers and is gone.

  **"A slower tier can answer this" was never an error.** The larger correction is that eighteen of those names were not faults at all. `BulkStatUnsupported` meant macOS's `getattrlistbulk(2)` refused this directory, so enumerate it per-file; `NoIndex` and `NotWorthwhile` meant the trigram table would not pay for itself, so read live; `LocateUnsupported` meant the codex was built without positional samples; `NeedFull` meant the freshness scope could not be proven, so walk everything. Every one of them describes a **correct answer arriving by a different route**, and every one of them was riding the channel reserved for failure — where a `try` propagates it as if the query had died. They now return `fault.Answer(T)`, whose `.declined` arm carries a named `Decline` reason, and the distinction is enforced by the type: `bulkstat.listOneLevel` returns `error{OutOfMemory}!fault.Answer([]OwnedEntry)`, so the one genuine fault and the one declinature cannot be confused by a caller who reached for `try`.

  **The round trip that proved the point.** `api.Engine.search` returned `SearchError.UnsupportedPattern`, which `ffi/cursor.zig` converted straight back into the `stale` status — a declinature promoted to an error at one boundary and demoted at the next, with a Zig `try` in between that would have treated "ask this cold" as a dead query. The hosted API now returns `SearchError!fault.Answer(*Cursor)` with `SearchError` narrowed to `Allocator.Error` alone. The C ABI is byte-identical: `stale` still crosses the seam exactly as the contract specifies, so the Rust, Python, Go, and Swift bindings are untouched.

  **And what an honest reason buys is a bug.** Collapsing that round trip immediately exposed what the old name had been hiding. The resident tier's `compileFor` catches every non-OOM compile failure and declined with `freshness_unprovable` — but `CompileError` has exactly two members, so what it was actually relabelling was `Unsupported`: "the linear engine cannot express this pattern." Both reasons route to the same cold fallback, which is why the mislabel had stayed invisible. It is not invisible to `fault.Decline.refused`, where `unsupported_syntax` is the **only** refusable declinature — the one `--engine linear` converts into a fault, because forbidding PCRE2 leaves that fact with no answer anywhere, while an unproven-freshness decline always has the cold walk behind it. The API had been telling callers their resident bytes were stale when the truth was that their pattern needed another engine: a different fact with a different remedy. The switch is now exhaustive over both members. Relatedly, the declinature arm of `Engine.search` returned on the success channel without releasing the cursor it had already allocated — `errdefer` does not fire for a value return — so every "run this cold" leaked one cursor. Both were found by a test that could not have failed while one error name stood for four different things.

  **What a closed set buys is a compile error.** Adding three members did not require finding their handlers by hand — `Status.ofFault`'s exhaustive switch at the C seam and `--matching`'s failure renderer both refused to build until each new fault was given a status and a phrase, and the FFI's witness list, pinned to the taxonomy's own size, refused until it listed them. That is the whole payoff of law 2, collected the first time it was tested. The shared walk-error renderer took `anyerror` and fell through to `@errorName`, which is how a widened `std` set becomes a mystery string in a user's terminal; it now takes a named `WalkFault` — the union of what the serial walk, the parallel descent, and the explicit-path probe can actually produce, each of which coerces into it. Where `anyerror` survives it is because the fold is total by construction: `recall.zig`'s freshness failure means "unprovable" for every possible member, which is already the safe answer, so it is instrumented rather than typed — the discarded fault now goes to the `.fault` trace lens, making "why did the daemon answer cold?" a question `GIST_TRACE=fault` can answer instead of a silent, correct, microsecond-long decline.

  **Instrumentation belongs where the tier decides, not where it computes.** `kernel/kinship/cluster/echoes.zig` had grown `std.debug.print` timing scaffolding and a `std.time.nanoTimestamp` call, which both bypassed the `assay` channel and broke the kernel's no-I/O rule. The signal was not lost in removing them: `relate`'s survey phase already carries an `assay.trace(.query, …)` span, and it now reports the candidate and edge counts the survey was already returning. `crew.zig`'s daemon `note()` routes through `assay.diag` for the same reason — one channel, one policy, one place to mute it.
- Inline comments and package docs cited ripgrep almost exclusively - 1591 rg/ripgrep mentions across `src/` against 18 for csearch and 9 for zoekt. That is the right ratio in most of the tree, because rg genuinely is the spec for flag surface, output shape, gitignore precedence and regex semantics. It was the wrong ratio in the two places where an unindexed tool cannot be the comparator at all.

  `src/corpus/fresh/` cited nobody. The freshness law is the whole reason gist pays a metadata walk that the rest of the indexed field skips, and ripgrep is irrelevant to it: with no index there is no read to elide and freshness is free. The package now states the contrast it exists for, measured rather than asserted. Index a two-file corpus, then without reindexing add a file holding the needle, give a second file the needle, and take it out of the first; ground truth becomes the two files. csearch returns nothing, because it picks candidates from the index and greps live bytes, so it correctly drops the file that lost the needle but never opens the two that gained it - staleness as false negatives only. zoekt returns the file that lost it, matching content stored in its shard, so it is wrong in both directions at once. gist returns the two, identically cold, resident, and across an instant create or delete. Neither rival is broken; both are built to be reindexed on a cadence. The point is that "answers from current bytes" is a different guarantee from "answers fast from an index", and it is the one a query against a tree ten agents are editing needs.

  `src/exec/session/` cited rg 99 times and zoekt zero, which inverted the interesting comparison. rg is the output oracle and belongs in the invariant, but it holds nothing between runs so it has no residency to get wrong. zoekt is the rival that is also a warm resident server holding content in memory-mapped shards, and holding content resident is exactly why it can answer from bytes the tree no longer has. That is why `reconcile/` and `watch/` are planes rather than optimizations: the session is meant to be zoekt's residency without zoekt's staleness, which costs a proof-of-clean barrier in front of every warm answer.

  Also fixed the crate front door in `root.zig`, which defined gist against ripgrep alone in a sentence about not rescanning - the moment you claim an index, the field is csearch and zoekt. It now names both rivals and what each bounds, and points at the tracked `research/gist/PRIOR_ART.md` instead of an ideation dossier that no longer exists and was never readable by anyone else.
- Ladder admission moved from boolean gates to **costed offers**: every decider
  that can represent the pattern is built, each prices itself as an `Offer`
  (compile + per-byte scan cost), and exactly one is kept — they are alternatives,
  not a pipeline. The DFA fallback is an offer too, priced from the prefilter's
  expected stride (`analysis/prefilter.zig`'s `Economics`), so a rung can lose to a
  start-skip instead of merely standing down beside one; the sieve, which narrows
  without deciding, is offered the winner's per-byte cost and applies its own
  survival inequality against it.

  This is what lets Parabix and the SP-quotient sieve arm on their populations
  where the old order-and-boolean gates never reached them, and lets an
  unprofitable candidate decline at _compile_ time rather than arm into a loss —
  proven on the lane slate, where the sieve gate declines 6 of 9 patterns as
  `unprofitable` and the Parabix rung stands down on star-height-2 and codepoint
  classes while arming on the assertion populations composition cannot serve.
- Lowered the Go module floor from `go 1.26.3` to `go 1.24`. The split had raised it three releases — to a patch level, no less — for one piece of test sugar: `new(0.6)`, the Go 1.26 spelling of "address of a literal", used only to fill optional `*float64` knobs in tests. No production file needed anything past 1.24, so every consumer of a package we publish was locked out of `go get` by a convenience in a `_test.go` file.

  A four-line `ptr[T any]` helper replaces the sugar. 1.24 is the real floor: the suites use `t.Context()`.
- Ninety-seven READMEs carried a `doc_radar:` block - YAML frontmatter on most,
  an HTML comment on the rest - declaring path, count, and sentinel assertions for
  a freshness gate that lives in the monorepo this package was split out of. That
  gate was never ported here, so every one of those blocks was inert: prose that
  looked machine-checked, cost real maintenance on each rename, and proved
  nothing. They are gone. The documentation below each block is untouched.
- Plane selection now routes through one assay.serialForced() predicate instead of four scattered GIST_NO_PARALLEL env checks: swarm.eligible, both serial.zig emit shards, and json.runParallel share the single joint, so a new parallel entry point cannot silently skip the parity-gate knob and blind the serial column. Byte-identical output preserved (line + unicode parity gates pass on both engines).
- Priced a **positional index tier** across the full size/benefit surface and
  declined it, with the curve committed rather than the conclusion asserted
  (`bench/sliver/artifact/positional_pareto.tsv`). Sweeping block-position coverage
  by trigram document frequency × per-document cap shows the cheap end buys nothing
  — a threshold only carries a literal's positions once it reaches that literal's
  _rarest_ trigram, and those floor out high (`pgxpool` 560 documents, `panic`
  3933, `func` 7671 of 19440), because a trigram is a 3-byte window over a small
  alphabet. The large reductions are real (`panic` 46×, `pgxpool` 25×) and cost
  39.8% of corpus at df≤1024, 72.3% at df≤4096, and 130.6% uniform and uncapped —
  a sidecar larger than the text it indexes — while `func` measures 1.0× at every
  threshold below uniform. Positions would accelerate the classes gist is already
  fastest on and leave the ones that cost seconds untouched, so postings stay
  document-level **by choice at a measured price**. Layer J gates the refusal
  itself: any threshold costing ≤10% of corpus that delivers ≥2× on a probe fails
  the layer closed instead of letting the "declined" narrative stand.

  Also added `bench/sliver/scale_race.py`, racing gist against zoekt and csearch over
  a multi-GB corpus (352,316 files / 5.5 GiB) across the canonical 12 classes,
  reusing `_compete.sh`'s fairness contract and `certify_stats.py`'s statistics.
  gist indexes 3.32 GiB of text in 21.4 s — 11.0× faster than zoekt, 2.6× faster
  than csearch — into the smallest index (10.4% of its text against zoekt's 8.7 GiB
  of shards), and beats csearch on the five hardest classes (`literal-punct2`
  16.5×, `regex-litalt` 9.4×). One loss is published unnormalised: 14.50 GiB
  indexing peak RSS, 5.1× csearch.

  Corrected the **query-residency diagnosis**, which an earlier draft of this layer
  got wrong. A flat ~575 MiB `maximum resident set size` was read as gist loading
  its 389 MiB index instead of paging it; it is not. `vmmap` over a live query
  shows `index.gist` at **11.5 MiB resident of 354.9 MiB mapped** (3.2%), demand-paged
  as designed, and two controls isolate the cause: a zero-candidate needle whose
  filter elides _every_ read still costs 583 MiB, and `--no-index` — mapping no
  index at all — still costs 535 MiB. The residency is the live tree walk over all
  336,780 files, where one touched byte costs a 16 KiB page on ARM64, so it tracks
  file count rather than index size and every page is clean and evictable. On owned
  memory (`peak memory footprint`) gist is flat at **93–96 MiB** across every query
  class, ~10× csearch and **5.8× better than zoekt's 558 MiB**. Layer J now
  publishes both metrics with the controls beside them, so the maxrss gap reads as
  the price of freshness rather than an index architecture.
- Relicensed from MIT to Apache-2.0 — same permissive freedoms, plus an explicit patent grant with retaliation termination, a NOTICE/attribution obligation, and a stated-changes requirement. No API or behavior change.
- Renamed the performance artifact from the 'Certificate of Optimality' to the **Dominance-and-Fit Certificate**, in the artifact title, every layer splicer, the release gate, and every citation. The ladder, gates, and fail-closed verdicts are unchanged — only the claim on the cover. The old title outran what the layers establish: Layer C reports distance from the read roof (77% darwin / 50% linux) and refuses to certify saturation, Layer D certifies one-pass verification over the _admitted_ candidate set rather than a globally minimal one, Layer B bounds two cross-compiled reference cores rather than the mint machine, and Layer A certifies dominance over a named baseline on the minting machine (cold selective literals still lose to csearch, as the artifact's field-context sections record). The new title names exactly the two things the layers do establish. the Dominance-and-Fit Certificate layers keeps its number and filename and carries an amendment recording the rationale.
- Scrubbed the references to the private monorepo this package was extracted
  from. Test fixtures searched for a `WalletService` type in `wallet.go`, ranked
  a path under a vendored-tools subtree, wrote charters declaring `graphify-out`,
  and asserted against a build-graph source that only existed there; skip lists
  hardcoded `graphify-out` outright. None of those resolve to anything a reader
  outside that repo can look at, which makes a fixture read as a leak rather than
  an example. The ranking signals do not care what the identifier is called, so
  they are now `SessionStore`, `tools/indexer/uses.py`, `lib/build/graph.zig`,
  and `derived-out` - same shape, same assertions, nothing to look up.

  Doc comments citing real measurements kept the numbers and dropped the tree.
  "A ranked `graphify` silently dropped 470 real hits" was a true and useful
  sentence about a vendored subtree the index prunes and a search walk does not;
  it is now stated as that shape, because 470 is the part you can learn from.
  Changelog entries cited internal decision-record numbers - `ADR-352`,
  `ADR-363`, `ADR-367` and friends - which are unresolvable here, so the
  parenthetical is gone where the sentence stood without it and replaced with
  what the decision actually said where it did not.

  Two categories deliberately survive. The benchmark suite still resolves its
  corpus to that checkout and picks patterns against it, so `WalletService` in
  `bench/` is a high-match race pattern, not a fixture; renaming it would turn a
  saturating query into a zero-match one and quietly invalidate the measurement.
  Minted artifacts under `bench/**/artifact/` state which corpus was measured,
  and rewriting a record to be more presentable is just falsifying it. A public
  corpus for the benches is a separate job.
- The FM-index and its persisted shelf moved here from `relate`.

  `gist codex` needed the shelf, and the relate face needed gist's answer keep,
  so neither product package could own its own face without a cycle. The
  FM-index is an index tier (SA-IS → BWT → wavelet → RRR), and this library
  already owns every other index tier plus the succinct math floors it stands
  on — so the index and `vendor/libsais/` come home. The Ziv–Merhav cento
  quoter stays in `relate`.
- The Go binding gets its group names from the engine now, instead of reading the
  pattern you wrote.

  `SubexpNames()` is indexed by group number, and the only way to fill that slice
  used to be to scan the pattern source for `(?P<...>)` and `(?<...>)` and confirm
  each candidate through `irgx_group_index`. That is a second parser, and a
  worse one. It had never been taught PCRE2's `(?'name'x)`, so a name spelled that
  way just vanished; two groups sharing a name under `(?J)` came back as one name
  and one blank slot; and every shape that merely looks like a group - an escaped
  `\(`, a paren inside a character class, a `(?:` that takes no number - was a
  rule it had to re-derive correctly on its own, forever.

  ABI 2 adds `irgx_group_name`, the inverse of `irgx_group_index`, so the
  table is walked straight out of the compiled pattern: group 1 through group N,
  whatever the engine calls each one, identically on both grammars. The scanner is
  deleted. Nothing about the public contract moved - it is still stdlib `regexp`'s

  - `SubexpNames()` indexed by group number with `""` for an unnamed group and for
  element 0, `SubexpIndex` answering -1 for a name the pattern does not declare,
  and the first of two groups that share one. The engine lends those bytes rather
  than copying them, so they are copied into Go strings while the handle is still
  alive.

  Two more things came with ABI 2, and you notice both of them by nothing going
  wrong. `irgx_fault` states which string its offset is measured in instead of
  leaving you to infer it from a NULL path, so `SyntaxError.At` is filled only
  from an offset the engine measured in the pattern - which is the string you
  print a caret under. And `irgx_find_all` reports how many matches the text
  HAS rather than how many fit in the window it was given, so the grow-and-rescan
  loop is gone: one pass, then at most one more at exactly the count the engine
  just reported. The window can no longer be the reason you go around again twice,
  and the retry is a measurement rather than eight times the last guess.

  `abiVersion` is pinned to 2 and checked at package init, so a library handed in
  through the `irgx_syslib` tag that still speaks ABI 1 says so in a sentence
  naming both numbers. The vendored archives are rebuilt on it, and the link probe
  that gates them calls `irgx_group_name` too - an archive that cannot resolve
  it now fails when it is vendored rather than in somebody's `go build`.
- The Go runtime tests no longer discover their engine by filesystem archaeology.
  A `TestMain` resolves what the package needs once, and a package with no binary
  fails outright instead of skipping its way to `ok`.

  The two `t.Skipf("no relate binary")` guards this replaces are the shape that
  hid a dead rung in the resolver: discovery quietly returned nothing, every test
  that wanted a child skipped, and the package reported `ok` over a seam nothing
  had touched. A skip is a claim the thing was optional. `Binary` staying a
  *discovering* affordance is right for a library consumer, who genuinely has no
  other way to find the engine, but a test knows something the library cannot -
  which build it is judging - and a missing binary during a test run is a broken
  environment, not an optional capability. Package-level failure is the honest
  severity for that.

  One skip survives, and it is the other kind. `TestTiersAgree` is a cross-tier
  oracle, and the default build is pure Go because the in-process analytic tier is
  opt-in behind `-tags irgx_ffi`, so a `go get` consumer never tries to link a
  libirgx that cannot exist in the module cache. One tier present is nothing to
  compare, and no amount of building or installing changes that - only rebuilding
  the test binary with the tag does. Its message now says exactly that, so nobody
  later reads it as the same rot.

  Verified by pointing `RELATE_BIN` at a path that is not a file: the package
  fails, exits 1, and runs zero tests. The old shape, in that same environment,
  printed `ok`.
- The KMV Jaccard estimator every kinship channel shares now **merges in SIMD blocks and quits early when a pair has already lost**, which makes the heaviest repetition sweep **3.0×** faster end to end (`relate echoes --shape distinct --as copies`, 19607 ms → 6481 ms over a frozen 21,054-file corpus, byte-identical stdout). The merge itself is 2.8× on 128-slot byte sketches (258 → 91 ns/pair) and 2.4× on structure silhouettes: instead of stepping one union value at a time through an unpredictable three-way branch, it compares two ascending eight-lane blocks all-pairs and accumulates the equality count in a vector, paying one horizontal reduction per block rather than a movemask per lane — the expensive half of this kernel on NEON. Advancing the side with the smaller block maximum keeps every match inside the block pair being compared, so it finds exactly what the one-at-a-time merge finds.

  Every caller was already asking a **bounded** question — is this pair inside `--max-distance`, is it nearer than the nearest miss so far, does it belong in the top N — and answering the unbounded one first threw away the cheapest information available. `kmvWithin` returns the distance or null, where null means, and only means, `distance > ceiling`. Cost now tracks the ceiling rather than the record width, because a bounded merge retires about `budget − floor` slots where the full one retires `budget`: on file sketches a 0.05 ceiling is **8.2×** and a 0.15 ceiling **4.4×**, which is where the documented dedup recipes live (`--max-distance 0.05` 3779 → 1855 ms; `--shape families --min-size 3` 3956 → 2018 ms; `echoes --top 20` 3886 → 2480 ms). A ceiling loose enough to admit most pairs converges on the plain merge, having skipped nothing.

  The exactness is checked rather than asserted: 13,710,200 ceiling decisions across a ladder of thresholds and every pair of real sketches and silhouettes in this repository agreed exactly with the scalar reference — null precisely when the distance exceeded the threshold, and the identical `f64` to the bit otherwise. `kmvDistance` is now literally `kmvWithin(a, b, 1.0).?`, so the unbounded and bounded answers are one kernel that cannot drift apart, and the abort test is comptime-gated out of the unbounded instantiation rather than carried as a branch it can never take.

  The abort threshold is deliberately **conservative** — it may sit one hash below the true cutoff and never above it. Every verdict a caller receives is the finished `jaccard` compared against `ceiling` directly, so the threshold only decides _when to stop merging_; under-shooting costs one pair a slightly later exit, while the exact restatement it replaced cost every pair two float divides inside a correction loop, which on a 23-slot function silhouette is the entire merge.

  Three bounds that looked free were measured and **rejected**. Pruning by range population — binary-searching how many of one record fall under the other's maximum — is a valid bound and reliably slower, because two O(log k) searches with unpredictable branches cost more than the SIMD merge they were meant to avoid. Two attempts to gate the bound by record width (at two and at eight blocks of headroom) and one at its own break-even measured neutral to 0.91×, which disproved the hypothesis they were built on: the residual 6–8% that thin records pay is the bounded calling convention, not the bound, so the gate was removed rather than tuned. That cost is recorded honestly — `--unit function` silhouettes average 23 slots and are the one population where the bounded path is slightly behind the plain one, dominated by the 1.4–8× it wins elsewhere.

  Record building is no longer the serial half. Fingerprinting sized its thread count as `bytes ÷ floor`, conflating two different questions — a floor decides _whether_ a pass earns a fan-out, never how wide it may go — which silently capped every medium batch: a ~20 MiB fragment batch drew five threads on a sixteen-core box. It now gates on the shared build floor and then uses the whole machine, with staying serial expressed as the one-shard case rather than a second code path. The `--unit function` byte channel built its sketches inline while walking, a single-threaded LZ78 march over thousands of fragments with fifteen cores idle; resolving participants first and fingerprinting the batch in one pass separates the read-once cache (which forces a serial walk) from the fingerprinting (which does not). Fragment extraction shards across files the same way. The distinct sweep now runs at **99% parallel efficiency across 17 threads** (53.5 CPU-seconds in 3.2 s wall), which is also the honest ceiling: there is no parallelism headroom left in it, and further gains have to come from comparing fewer pairs.

  Measurement method changed too, because the first numbers were noise. This machine hosts ~10 coworker agents; at load average 47 the same 200 ms sweep measured 177, 194, and 486 ms, and a 10% decision cannot be read off that. Sweeps are now sized to a few milliseconds and reduced by minimum over 51 interleaved repetitions, which reproduces to within 1% run over run, and end-to-end A/B runs against a frozen worktree so that coworker edits can neither perturb the timing nor legitimately change the answer between halves.
- The Python binding stops re-deriving three things the C ABI now states, and one
  of them was quietly giving wrong answers.

  `Pattern.groupindex` used to be built by scanning the pattern text for
  `(?P<...>)` spellings and confirming each candidate through
  `irgx_group_index`. Confirmation caught everything the scan *invented*, and
  nothing it *missed* - so a name declared after a `[` the scan misread as a
  character class simply was not there:

  ```python
  >>> irgx.compile(r"(?#[)(?P<n>\w+)", pcre=True).groupindex
  {}                       # before - and m.group("n") raised IndexError
  {'n': 1}                 # now
  ```

  `\Q[\E(?P<n>\w+)` had the same hole. There is no scan left: the binding walks
  `1..groups` asking `irgx_group_name` what each one was declared as, which is
  the parser's own answer and cannot disagree with the numbering it came from. The
  names are decoded into Python strings where they are read, since the bytes
  borrow a handle that a thread can outlive.

  `finditer` over a text with more matches than the first span window now costs
  two searches instead of five. `irgx_find_all` reports how many matches the
  text HAS rather than how many fit, so a short window sizes its own retry exactly;
  the doubling schedule that grew 4096 spans to 32768 to 262144, rescanning the
  whole text at every rung, is gone. Same spans, same order.

  And `error.pos` reads the fault's declared coordinate space instead of inferring
  one from "there is an offset and no path came back with it". That conjunction
  was right, which is the problem with it - the day a compile fault arrives
  carrying a path, an inferring binding starts pointing a caret into the wrong
  string, and it does it silently.

  This needs ABI 2. The wheel refuses to load anything else, so an old library and
  a new wheel say so at import rather than mis-reading a struct.
- The README now carries the engine's own argument instead of pointing downstream
  for it: the two costs a search may refuse to pay, the Kleene-to-Thompson lineage
  and the fork the linear tier sits on, the match ladder rung by rung, the trigram
  index and the crest sieve that closes its blind spot, the freshness law against
  the two indexed engines that skip it, the rank fusion, the total corpus
  partition, and the bounds each layer is measured against. It names no product
  package; the faces reference the library, not the other way around.
- The `kin-8` slate in `bench/rungs/patternid` spelled its eight patterns
  `billy_{wallet,ledger,audit}_{grant,debit,hold}`, which named the monorepo this
  package came out of for no measurement reason. The prefix is now `store_`.

  The swap is measurement-neutral, and that was checked rather than assumed. What
  this slate exercises is subset collision between patterns that share a prefix and
  share a suffix, so what has to survive is the shape: eight patterns, one common
  6-character prefix, three distinct suffixes, and three 12-character prefix groups.
  `store_` is the same length as `billy_`, so every pattern keeps its exact byte
  length and all four of those properties are unchanged.

  It also could not have been corpus-tuned. The old patterns matched exactly one
  file anywhere in the corpus, and that file was the corpus's own copy of this
  bench source - so the real match density was zero before the rename and is zero
  after it. That is the difference between this slate and `lit-18` next to it,
  whose literals are genuine symbols with real density behind them (`WalletService`
  alone lands in 112 files); renaming those would change what is being measured, so
  they stay until the corpus question is settled.
- The anchor decision is now a value that is minted once per query instead of
  being re-derived inside every scan. `simd.Plan` holds the chosen probe/confirm
  pair plus the single-probe eligibility, `simd.planFor` is the one mint every
  consumer shares, and a `simd.Gate` carries its plan — so the whole-file drop and
  the hit-to-hit `find` loop reuse one decision rather than re-pricing fifteen
  candidate pairs against the fitted digraph table per file and per match. The
  per-line literal paths in `CompiledQuery`, the one-needle `LiteralSet`, and the
  candidate verify hoist the same way, and the wide tier only prices a pair when it
  will actually run, so a haystack shorter than one block no longer plans at all.

  Measured on one binary against itself via `GIST_NO_PLAN` (a two-build A/B cannot
  answer this in a tree many agents edit concurrently): 1.18–1.27× less CPU on
  line-dominated single-buffer scans of a 213 MB corpus, cold and warm alike, with
  paired per-repetition ratios inside 1%. Many-small-files scans, where the walk's
  syscalls dominate and the once-per-file decision is ~0.05% of the run, are
  unchanged — 0.998–1.047× median paired ratio over 31 single-threaded reps. Output
  is byte-identical in every arm — the pair only chooses which two offsets the block
  filter compares, and the `eql` verify is what decides a match.

  `simd.planOn` is the document-grain seam `calibrate.zig` was written for, and it
  adopts a calibrated pair through `calibrate.refine` rather than `calibrate.best`.
  Two defects are recorded there rather than shipped: adopting the sample's
  favorite unconditionally was a measured 0.5–1.1% CPU tax with no row it won (the
  shipped table is already right on most needles, and swapping off it also forfeits
  the single-probe shape), and a purely relative accept margin is a winner's curse —
  the argmin of up to 120 noisy estimates of the same density sits several sigma
  below the truth, which the randomized suite caught as a claimed 12.5% win over an
  incumbent that was in fact better. The margin is now the larger of 12.5% and four
  standard deviations of the incumbent's own count.

  **Large buffers now reach it on every literal path.** A plan is minted where a
  whole document arrives and reused by every scan of it, through three seams:
  `simd.Gate.on` re-prices the required-literal gate per body (called by
  `Emitter.openOn` for the serial render, the swarm worker, the single-file shard
  driver, stdin and the resident session's fold, by `json.emitOne` / `json.soloShard`
  for the record stream, and by `verify.gateWide` for the whole-file drop);
  `Emitter.lit_plan` carries the sweep decision for the loops that re-enter the scanner
  once per match, minted before any shard exists so cutting one file across cores
  cannot re-sample it per core; and `PikeScratch.litPlan` memoizes the span walks' plan
  on the haystack slice, so `litSpan`'s twenty callers each get one mint per haystack
  with no call site to remember. `LiteralSet.findOn` carries the same reasoning to the
  fused whole-document literal scan, and `render.anyHit`'s `-q` sweep mints one
  directly.

  Those per-hit hoists are also a straight cost fix, independent of calibration. Since
  `anchor.zig` gained its distance-conditioned joint correction, `anchor.select` costs
  ~21 ns on a typical 4–8 byte needle rather than ~3.7 ns, and every one of those loops
  re-derived it once per HIT before it took a plan.

  On a 200 MB buffer whose alphabet is the statically-rare bytes, holding needles whose
  locally-rarest byte the shipped table ranks common: **6.9–8.0× less CPU** for
  `-Fc`/`-F`/`-Fn`/`-Fo`/`--count-matches`, 7.8× for `--json` and 8.3× for `--json -o`,
  7.0× for `-q`, and 4.5–4.7× for `-Fl`, over three needles so no row is one needle's
  luck. The kernel sweep underneath is 70 ms on the table's pair
  and 3.9 ms re-priced (17.6–17.9×), against 4.09 M block survivors versus 34–42 — and
  the table's pair takes the *single*-probe shape there, so the fast loop aimed at the
  wrong byte loses to the two-probe loop aimed well by an order of magnitude.

  A regex carrying the same required literal gains where it sweeps and not where it
  does not: 2.00× on `-o`/`--count-matches`, 4.6× on `-l`, but 1.23–1.26× on
  `-c`/`-n`/`-w`/`-U`/`-A` because a 60-byte line is a single block and which two
  offsets inside it get compared barely matters. `-i` cannot gain at all —
  `containsCaseless` takes no pair. Both ceilings are structural rather than unwired.

  Neutral where the table was already right: median 1.002× (min 0.996×, max 1.012×)
  across 15 mode×needle rows on a 213 MB many-small-files code tree, where the size gate
  declines in two comparisons. That has to be read as a median of repeats rather than a
  best-of-N — at ~0.03 s a run one lucky outlier in either arm reads as a 1.4× swing,
  which manufactured a phantom `-q` regression that nine paired reps dissolved.
  Byte-identical throughout — 411/411 supported-surface
  ripgrep parity on both the parallel and serial engines, an unchanged differential
  fuzz residual, and 420 in-binary mode×needle×corpus differentials with zero
  divergence.
- The artifact home moved from `.local/gist-verify/` to `.gist/`. Everything the
  engine persists lives there - the trigram index, the kinship and fragment
  atlases, the codex shelf, the freshness anchor, the daemon socket, and
  `skips.list`. The old spelling was inherited from the monorepo this package was
  extracted from, where `.local/` was that repo's machine-local scratch
  convention and `gist-verify` was one bucket inside it. Neither half means
  anything in a clone that has never seen that tree, and a reader who found the
  directory could not tell whether it was ours. `.gist` names itself the way
  `.git`, `.ruff_cache`, `.mypy_cache`, and `.pytest_cache` do, and it reads
  correctly against the `GIST_DIR` override that was already there.

  This orphans any index you already built; nothing reads the old directory
  anymore, so the first query after upgrading answers live and slower. `gist
  index` rebuilds it in about three seconds, and `relate index --shelf` does the
  same for the kinship side. If you would rather keep the old location - a shared
  volume, a path you already back up, a tree where `.gist` is taken - `GIST_DIR`
  still pins it: `GIST_DIR=.local/gist-verify gist index` puts everything back
  where it was. Delete the stale directory yourself; we will not remove bytes we
  no longer claim to own.

  `.gist` also joined the corpus baseline skip set, next to `.zig-cache` and
  `node_modules`. The artifact home sits inside the walk root by default, so
  without this the tool indexes its own index - a couple of hundred megabytes of
  its own exhaust, on every tree, with no way to have wanted it. It is baseline
  rather than charter policy because it holds for any tree with no configuration
  at all. Naming the directory as a root still searches it, the same escape the
  rest of the baseline offers.
- The automata rung can now price a runtime-feedback mechanism *before* anyone builds it,
  and the first thing it priced turned out not to be worth building.

  A `memchr` skip out of every interior dwell — not just the unanchored start, where the
  engine already arms one — was retired earlier by measurement, with a loose end written
  down. Every loss came from a build-time prior predicting a stride the document then
  contradicts: two states with the same exit set get the same prediction, so `a.*b` won
  while `foo.*bar` lost by 10x. The named fix was a skip that measures its own realized
  stride and disarms itself. That residual is now answered without writing it.
  `automata-rung -- dwell` grew an *adaptive ceiling* arm that hands the mechanism its
  measurement free and without error, then times the decision it would converge on.
  Anything real is bounded by that, so a losing bound settles it.

  The headroom is real and the mechanism is learnable, which is what makes the result
  worth keeping rather than a foregone conclusion. Splitting every armed skip by whether
  it alone cleared the 32-byte bar shows `a.*b.*c` losing at 0.54-0.56x armed
  unconditionally while **77.8%** of its bytes sit under skips that individually pay. And the per-state
  mean strides — `8 70` inside `a.*b`, `8 8 61` inside `a.*b.*c`, `4 4` inside
  `foo.*bar` — show the dispersion separates *which* dwell rather than hiding inside one,
  so a per-state counter is a sufficient statistic for the decision.

  It still loses. Keeping exactly the states whose own realized stride pays reads
  **0.55-0.56x geomean against the shipped multi-lane `docMatch`** across four fresh
  runs, a stable 1.36-1.43x better than arming everything when both are measured in the
  same run, and a ~1.8x regression all the same. The one pattern that won unconditionally
  gets *worse* (1.11-1.18x down to 0.81-0.84x), because disarming its 8-byte state removed
  a skip that beat stepping even below the bar.

  The reason is structural rather than a tuning miss: the skip lives in the scalar walk,
  ~2.2x behind the shipped lanes, so **adaptivity can choose better states but cannot
  relocate the walk it runs in.** With nothing armed at all the arm still reads 0.78-0.81x
  of the scalar walk, because merely asking "is this state armed" costs per byte. A free,
  perfect *per-pattern* oracle — allowed to decline the skip entirely and fall back to the
  shipped path — reads only 1.04-1.06x over the same rows, on a slate hand-built to
  flatter the mechanism.

  So the only version left worth wanting is a skip built *inside* the shipped lanes, where
  it would be competing against a SIMD substring kernel already doing the same job better.
  The instruments stay as the evidence: `strideProfile` reports each skip's realized stride
  split by whether that skip alone paid, and the per-state arm times the kept subset. Both
  are numbers a future attempt has to beat before writing a line of it.

  Nothing in the shipped engine changed. This is measurement, and the measurement says a
  mechanism should not be built.
- The bench/ tree is reorganized from 22 flat concern folders into six evidence-genre buckets — apparatus (instruments + corpora), conformance (fail-closed correctness), dominance (measured performance), certificate (the published claim), bounds (distance from a stated limit), and rungs (per-mechanism proofs) — with the three unnavigable interiors (certify→certificate/{mint,report,guard,ledger}, gates→{parity,contract,oracle}, races de-stuttered) given real sub-structure. No behavior, baseline, or receipt changed; every build step, gate, and make shim points at the new paths.
- The codex build is now **parallel wherever a phase is a sweep over rows**, which is everywhere except the suffix sort itself. The BWT derivation and its histogram, the locate marks, and each level of the wavelet tree are divided by the same `kernel/math/parallel.zig` floor every other engine already shards on, so a 16-core box builds a shelf with 16 cores instead of one. Measured in-process against the serial shapes over real repo source: **8.5×** on the BWT + histogram, **4.2×** on the locate marks, and **1.45×** on the wavelet weave — the last one under a load average of 63 on 16 cores, i.e. with no idle core to win with, so it is a floor rather than a best case. Assembled from arms one process ran back to back, the whole build is **8.3–8.9×** (67.4s → 8.1s at 128 MB). End to end over the live repo (21,081 files, 209 MiB), `relate index --shelf` now builds the shelf in **5.1 s** and the whole three-artifact index in **9.0 s**, spending ~33 CPU-seconds in those 9 wall seconds where the serial build spent ~1.1 per wall second.

  Division needed a second shape to sit beside the existing one. `greedyBounds`/`shardBounds` weigh items because files differ in size and a few large ones must not stall a thread; a suffix-array row costs exactly what its neighbor costs, and weighing 200 million of them to discover that costs about as much as running a shard. So `evenBounds` splits arithmetically, at a caller-chosen grain — pass 64 where shards write into one shared bit-packed word array, so no two of them can carry a read-modify-write on the same word. It always yields at least one shard, which is the point: staying serial is the one-shard case rather than a second code path maintained beside the parallel one and free to drift from it. Index construction crosses into parallelism later than search does, so it gets its own `build_min_bytes` floor (4 MiB) beside the search one instead of borrowing it.

  The wavelet tree needed a real structural change to be shardable at all, and it pays for itself twice. Symbols used to compact in place as the tree descended, which no shard can do — it would overwrite symbols its neighbors have not read yet. They now shuttle between **two n-symbol halves ping-ponged by depth**: a node reads one over its row range and writes the other over the _same_ range, so ranges never move, siblings can never reach each other's symbols, and no node needs a private temp for the half it displaces. That last part also drops the per-node scratch allocation the old builder made on every internal node.

  Weaving a level keeps **both** shapes for a reason that is a property of the machine, not the algorithm. A lone worker knows where a symbol lands the moment it reads it, so it codes the bitvector and routes the symbol in one sweep. Shards cannot: a shard's destination offsets depend on how many symbols the shards before it sent left, and nobody knows that until they have looked, so they read the range twice — once to code and count, once to place. Two sweeps across a dozen threads only beats one sweep on one thread if there are cores to spare, so the two shapes were priced against each other inside one process, with the shipped builder's fan-out forced off standing in as a live third arm rather than the fused path being timed in a separate run. That is what the 1.45× above is measured against.

  `Codex.build` also hands the suffix array back **before** the wavelet tree rather than at return. The suffix array is the largest thing the function ever holds — 4n bytes against the tree's 2n — and both of its readers (the BWT, then the locate marks) now run before the tree, so the most memory-hungry phase begins with that room already free. Reordering the phases is what pays for the tree's second half.

  None of it is a new answer, and that is checked rather than asserted. A ground-truth test builds a 2 MiB + 7331-byte corpus — deliberately aligned to neither a 64-bit word nor a shard boundary — past the 4 MiB parallel floor and verifies the C table, `restore`, `count`, and `find` against independently computed oracles, so the sharded paths are covered by something that fails when a boundary is wrong rather than by the small-corpus tests that never reach them. The wavelet arms were run side by side in one process and agreed exactly on all 209,715,201 `access` results and every sampled `occ`.

  **libsais stays compiled serial** and the OpenMP entry point stays out. It was measured, not assumed: the best parallel arm ran the sort in 5662 ms against 5949 ms serial, about 1.05×, in exchange for a `libomp`/`libgomp` runtime that every build host, cross-compile target, and CI image would then have to carry. Five percent on one phase is not worth a link-time dependency on a machine-specific runtime when the phases we own were sitting at 1× and are pure `std.Thread`. The parallel arms also came off a loaded box and do not increase with threads, so they are a decline rather than a scaling curve; `vendor/libsais/README.md` records the flag, the numbers, and why it is off.
- The cold read plane's `grepfile.zig` is retired: its 770 lines were six unrelated jobs sharing an import path, and they are now six peer modules named for the question each answers. `read/slurp.zig` owns getting one candidate's bytes off disk (the staged `BUFCAP` prefix, the on-demand tail, the large-file mmap); `read/legible.zig` owns making those bytes matchable (BOM sniff, UTF-16 transcode, and ripgrep's line model — the single definition of where a line starts that both engines and the warm face share); `read/binary.zig` owns what a NUL costs you (the committed-prefix quit strategy, the line vs `-U` slice geometries, the two binary notes); `read/stats.zig` owns the `--stats`/`--json` tally and the `GIST_TRACE=query` diagnostic; `read/inode.zig` owns the portable `stat(2)` projection over statx or fstatat; and the walk-failure stderr vocabulary moved out of `read/` entirely to `quarry/notice.zig`, beside the descent it describes rather than the file bytes it never touched. All 19 consumers import the concern they actually use instead of the union of all six, so a call site now declares its dependency. No behavior change and no facade re-export shim: the split is a rename of the import path, not of the code.
- The crest and pincer dossiers cited a per-experiment scratch directory for
  their evidence, one that lived inside the private monorepo this package was
  extracted from. A reader outside that repo cannot open any of it, so every one
  of those citations was a dead pointer that also advertised a tree nobody else
  has. The claims now stand on their own: each pointer is replaced by what the
  spike actually established, in numbers already carried by the dossier or by the
  spike's own results.

  So crest's lineage no longer says "see the classrun-formula spike"; it says the
  Python reference sieve cleared 240,000 random `(regex, text)` pairs against
  Python `re`, 51,463 of them prunable, with zero false negatives, and that the
  count-cousin ablation separated the two designs by ~22× on `[0-9a-f]{8}` (92.9%
  pruned by the run against 4.2% by the population at the same threshold). The
  Ridge extension says 5,224 oracle checks, sound on every one and 98.2% exactly
  tight, plus a 160,000-pair sieve suite with no false negatives. Pincer's
  provenance paragraph now describes the instruments themselves - the held-out
  corpus split, the popcount oracle over per-offset match bitvectors, the sweep
  that refused to report until three plans agreed on the hit count - rather than
  naming four files you cannot read.

  The harder half was the two `TESTING.md` files, which are reproduction guides.
  A summary cannot replace a procedure, so where the procedure is gone they now
  say so out loud instead of printing a command that cannot run. Crest's §5
  oracle and both pincer spikes were pre-production Python and Zig scratch, and
  none of it shipped; what did ship is named in its place - `crest_test.zig` and
  `bench/rungs/crest/` for the sieve, `anchor_test.zig` and `calibrate_test.zig` for the
  anchor defect and the calibration improvement test. One real gap is stated
  rather than papered over: nothing in this tree re-times the kernel under the
  lazy, static, and calibrated plans, so pincer's 17.6-17.9× bare-sweep row rests
  on a dated measurement.

  No measurement moved. `.local/` stays this repo's scratch convention, and the
  `.local/crest-evidence/` output path is untouched.
- The eager DFA's `is_match[s]` lookup is gone. States are renumbered at build
  time so every accepting one precedes every non-accepting one, and the scan loops
  ask `s < match_hi` — one unsigned compare on a value already in a register,
  where before there was a second dependent load on the byte immediately after the
  transition load that produced `s`, into an array that was `ncls`-sparse by
  construction and therefore mostly padding in cache. **1.10–1.16× geomean** on the
  scalar per-line walk over 13 match-free patterns and **1.20–1.27×** on the rows
  whose walk actually wanders, against parity (0.98–1.19×) on the rows that sit in a
  self-loop, where the removed load was a perfectly-predicted L1 hit with nothing to
  win (`zig build automata-rung`); byte-identical over the Pike VM differential. rust-`regex`-`automata` reaches the same compare by shuffling its
  special states into a prefix, but needs a power-of-two stride to recover an index
  from a premultiplied id and pays that padding in every row; premultiplication is
  monotone in the id, so a contiguous id range is a contiguous offset range at any
  stride, and one bound suffices because the low end is zero. New `freeze.zig` owns
  the three ordered layout passes — renumber, accelerate, premultiply — that both
  determinizers previously transcribed separately.
- The emitter was one 1540-line file holding every way `rg` can be asked to print. It is now a façade over five modules split along the axis a regression actually travels: not the flag, but the model of the file the flag implies.

  **A flag-shaped file hides a model-shaped bug.** `output.zig` grew by accretion — each new rg flag arrived as another branch inside whichever function already looked closest — so `-o`, `-v`, `--passthru`, `-c`, `--vimgrep`, `-U`, `-r`, `--trim`, and `-M` all interleaved in one scope. What the file never said out loud is that those flags are not peers. Three of them disagree about what a file _is_: the default path treats it as a grid of physical lines, the pure-literal fast path treats it as raw bytes with a needle in them and never builds the line array at all, and `-U` treats it as one buffer because a match may cross a line boundary. The other flags are downstream of that choice — they decide how a line the model already selected becomes bytes. Splitting by flag would have cut across all three models and left every module holding a piece of each; splitting by model puts the disagreement in three named files and makes the equivalence between them the thing you are looking at.

  **`grid`, `skim`, `multibuf` — and the invariant they owe each other.** These are three routes to the same stdout. A file that qualifies for the skim path must print exactly what the grid path would have printed, byte for byte; that equivalence is the entire justification for taking the fast path, and it was previously an unstated property of code that happened to sit nearby. The eligibility predicates that guard the fast routes (`litFastEligible`, `fusedFileEligible`) now live in the module whose model they admit you into, next to the loop that assumes they held, so a flag added without teaching the gate about it is a local omission rather than a distant one. `display` and `replace` serve all three: `display` is the one place a chosen line becomes bytes (`--trim`, `-M` and its preview, color, the terminator model), and `replace` owns `-r` expansion — with `expandInto` still taking its allocator explicitly, because the `--json` stream calls the same expander on the same templates and a second dialect of `$1` is exactly the divergence worth preventing.

  **The struct stayed one declaration.** Zig 0.16 removed `usingnamespace`, so methods cannot be scattered across files and reassembled. The `Emitter` — the mutable per-file state every mode shares: match base, body end, literal gate, capture program, color, scratch simulators — remains a single struct in `output.zig` alongside the small writer vocabulary the modes frame output with. The modes are free functions over `*Emitter`, the same shape `render.zig` next door already used, and the five verbs (`file`, `buffer`, `fileLit`, and the two eligibility gates) forward from the façade. Every existing import path is unchanged; nothing outside the folder learned that the split happened.

  **Parity was the acceptance test, not a follow-up.** The `-U` parity table captured from real ripgrep moved into its own `multibuf_test.zig` rather than riding along in the implementation file. The relocation is verbatim — the diff normalizes to visibility modifiers, import rewrites, and method-to-free-function conversion — and all 199 tests across `output.zig` and every module that imports it pass, including the warm session's cold-Emitter byte-parity suite, which is the check that matters most: the resident path deliberately drives this emitter rather than a re-derived formatter, so warm frames are cold frames by construction and a silent divergence here would surface as two answers to one query.
- The freshness watcher is now a five-module package behind one facade:
  `watch.zig` still owns the public `Watcher(Session)` — the shared per-session
  state, the comptime backend selection, and the cross-backend invariants — while
  the backends live beside it under `watch/`: `inotify.zig` (the Linux event
  loop, coverage extension, and casefold detection), `kqueue.zig` (the macOS
  `EVFILT_VNODE` registration, drain, rescan, and retire) + `coverage.zig` (the
  macOS admission walk that selects the watch set from the corpus's own `Ignore`
  policy) + `budget.zig` (the descriptor ceiling clamped against the limits the
  kernel actually enforces). Each backend is a set of free functions over the
  generic `Watcher`, so the accelerator's every-note-precedes-markDirty ordering,
  its fail-closed arm-exactness, and its coverage-poison contract read as three
  cohesive modules instead of one 1,000-line file — with the same public entry
  points (`start` / `stop` / `shed` / `flushSync` / `held`) and byte-identical
  behavior on both targets. No behavior changed; the file dropped its MONOLITHIC
  deferral.
- The fused work-stealing engine is now the `swarm` package — seven modules split
  by **lifetime** rather than by flag: what is decided once per run (`swarm.zig`:
  eligibility, pool sizing, the oracle race, spawn/join), what every worker shares
  (`queue` the work-stealing spine, `sink` the single writer), what one worker owns
  (`crew`: arena, scratch, held fragments, the ordered `--sort` replay), and what
  happens per directory (`descent`) and per file (`sift`). `roster` keeps the
  callable file-set walk the resident session reconciles against as a peer entry
  point, not a search with its output suppressed. The published surface is two
  functions, `eligible` and `run`.

  The read-elision oracle moved out from under the parallel engine to
  `cold/quarry/elide.zig`, where both cold engines admit the same one — the first
  half of the tier's single-owner-per-policy restructure, and the seam the serial
  engine's `IndexSkip` folds into next. Its three private early exits ("no anchor",
  "no index", "the path table would not pay for itself") are now a declared
  file-private error set converted to a typed declinature at the module boundary,
  so an early exit can no longer read as a fault.

  Five worker helpers became `Worker` methods, and the pool spawn/join is written
  once for both the search walk and the file-set walk. No behavior change: the
  whole supported flag surface is byte-identical against real ripgrep on **both**
  engines, and the parallel path's per-worker ordering, coalescing, and budget
  contracts are unchanged.
- The identifier a caller types is now `irgx`, everywhere a caller types one. The C ABI prefix is `irgx_*` rather than `irregex_*`, the installed header is `include/irgx.h` (guard `IRGX_H`), the Python package is `import irgx`, and the Rust crate is `use irgx::`. The project is still irregex - and so is every name that identifies the project rather than the symbol: the PyPI distribution is still `irregex` (`pip install irregex` then `import irgx`, the bs4/PIL pattern), the crates.io package is still `irregex` with `[lib] name = "irgx"` beside it, the Zig package is still `.irregex` and consumers still write `@import("irregex")`, and the Go module path is unchanged. This lands before v1.0.0 deliberately: v1 freezes the C ABI, so this was the last window in which the prefix was free to move. Both vendored archive sets were re-cut off the renamed engine, so the Go and Rust rungs that link a prebuilt library link the new symbols; a checkout that skips that step fails at the linker rather than at runtime. `irregex` survives in exactly the places it names the project rather than a symbol: the Zig package and its ward declaration, the module path, the distribution names, and shipped CHANGELOG history.
- The ladder's auction now settles in a currency someone minted. Every bid was a
  hand-written literal — `30_000` for any DFA, `500 + 30_000/stride` for a skipping
  one, `4_400`/`8_000` for composition, `9_000 + stripe_ops/8` for Parabix, and a
  `speed_ratio` constant standing for both sides of the sieve's inequality — and
  the sieve's arming condition still carried a `delete this when measured` comment.
  An auction can be internally consistent in an invented currency and still buy the
  wrong machine, which is exactly what it was doing.

  **One plane, two halves that may not mix.** `ladder/price.zig` owns a
  `Calibration` of measured cycles-per-byte coefficients, each minted on a named
  machine on a named date, and a `price(Machine)` function that is purely
  structural — it reads a pattern's own facts (skip stride, `^`, transformation
  width, end-of-line index, stripe ops, conjunct count, grain) and multiplies. No
  literal in the cost model is a performance claim and no coefficient knows what a
  pattern looks like, so a port re-mints the calibration without touching a model
  and a new rung adds a model without re-measuring anything. `unmeasured` exists
  only so the arithmetic is total on an unported host, and it withholds `measured`
  — which is what a vector rung consults before bidding, so arming is now the
  conjunction of _the kernel exists_ and _this target was minted_ rather than an
  `builtin.cpu.arch` check answering a question nobody asked.

  **What the measurements changed, as opposed to confirmed.** One constant covered
  the eager DFA, the lazy DFA and the Pike VM; measured they are 1.37, 9.52 and
  29.57 cyc/B, a 25× range challengers were bidding blind into. `^` is a per-_line_
  seed behind a `memchr`, not a per-byte walk — an anchored pattern was bid at 2.98
  and measures 0.31, so composition kept winning auctions it lost by **2.82×** in
  fact. Composition's `if (dfa.start_dwell != null) return null` gate was a boolean
  standing in for an inequality it could not state; the stride-priced fallback now
  outbids composition on strong-skip patterns and loses to it on weak ones, an
  outcome the boolean could not express in either direction. And a pattern decided
  _above_ the ladder by a literal set or a saturating class run is priced by the
  kernel that actually answers, classified by which backend that kernel chose:
  `memchr` at 0.073 cyc/B against Teddy at 0.517 is a 7.1× spread that one
  `settle_literal` coefficient had been quoting as a single number, which mattered
  because that price is the divisor in the sieve's survival inequality.

  **A residency axis shipped and was refuted, which is the more useful half.** The
  plane's first draft priced the walk by table footprint on the reasonable theory
  that a table too big for L1 walks slower. The sweep built to fit that curve
  killed it: a 1.4 MB table and a 216-byte table both walk at ~1.18 cyc/B, and the
  whole six-point spread over a 19,000× footprint range tracks automaton shape. It
  could not have been otherwise — the step is one dependent load from
  `table[state·stride + class[byte]]`, so the working set is the rows a haystack
  _visits_ times the classes it _uses_. The axis is gone and `Machine.walk` has no
  footprint field to misuse, but the sweep stays in `mint`, printing its spread
  every run, so a host that really is cache-sensitive shows the knee before
  anything silently misprices.

  **`zig build ladder-price` is the gate.** `mint` times each coefficient alone
  against a fixed 8 MiB synthetic haystack (min-of-9, two-point fits where a cost
  has both an intercept and a slope) and prints the calibration literal to paste
  back; `verify` re-times and reports drift; `regret` ignores the model entirely,
  builds _every_ machine each slate pattern admits, measures each, and fails when
  the auction's pick is more than 1.25× off measured-best. Regret is what found
  both mispricings above, and worst regret across the slate is now **1.00×**.
  `mint` is deliberately not the default verb, for the same reason a verifier may
  not produce the proof it judges. The whole lane costs no corpus load, no
  multi-gigabyte table, and about twenty seconds.

  **Downstream, the sieve gate declines two more patterns than it used to** —
  `digit-40` and `iso-date`, both of which the pre-plane boolean armed — because
  `selected_cost` now names the machine that would really front them instead of an
  assumed dense walk. One row (`uuid`) still arms into a measured 0.89× and the
  production proof publishes it as a loss rather than widening the gate around it:
  every term in the inequality is a minted cycle count, and the residual is one
  input — `fallthroughRate` prices each position under a _memoryless_ byte prior,
  where real bytes cluster 4–13× above their marginal share, so its error is
  exponential in the run a pattern requires (1.1× at one byte, 6.5× at eight,
  2.6e17 at forty). Only a persistence-aware prior closes that, and it is its own
  piece of work. The obvious cheaper fix was tried and refuted: re-minting every
  coefficient against a haystack drawn from the corpus's own byte shape moved
  `dfa_step` 2% while destabilizing `dfa_line` and `anchor_line` by 2.7× and 2.3×.
- The literal prefilter's kernel choice was audited against the alternative nobody
  measures — not arming one at all — and the cascade it was accused of being turns out
  to be right for a reason its critics and its author both had wrong.

  The accusation held on inspection. `scan/literal_set.zig` picks its kernel by
  **needle count and nothing else**: one needle takes rare-byte `memmem`, up to 64 take
  grouped Teddy, beyond that a sparse Aho-Corasick, and nothing anywhere on the path
  consults the corpus byte statistics the sieve already computes. Those statistics
  exist, they are described in their own header as "one fact shared by DFA
  acceleration, Compose, Parabix, and Sieve", and the literal dispatcher is not one of
  the sharers. So the hole is real and exactly where it looked.

  `automata-rung -- sift` prices it. Each pattern is paired against documents built to
  disagree — anchors saturating every position, anchors absent entirely, and a slab of
  real code — then run twice, once with the literal scan in place and once with it
  nulled out, so the delta is attributable to the prefilter rather than to the pattern.
  A helper walks widening alternations to find where the cascade actually changes
  kernels rather than trusting the constant.

  Arming pays on **10 of 11 rows**, geomean **2.47-2.95x**, and **3.96-4.16x** on the
  real-code documents that resemble what anyone actually searches. The single loss is
  **0.18x**, on a document tiled so densely with the needle's own anchor bytes that
  verification never stops running.

  That loss is not gateable, which is the finding. Its two twin rows share every number
  derivable from the pattern — same needles, same lengths, same rarity ranks — and want
  the opposite decision, so no pattern-derived predicate can separate them; only the
  document can, and the dispatcher runs before the document. Worse, the specific
  statistic proposed as the gate answers "don't arm" on **9 of 11 rows**, including
  rows where arming wins by 4x. It is the correct statistic for deciding whether to
  skip with a byte-class kernel and the wrong one for deciding whether to verify a
  nine-byte needle found from two rare anchors, because the two mechanisms fail for
  unrelated reasons.

  No engine behavior changes. The count-keyed cascade stays, now with a measured floor
  under it and a named adverse case, and the pricing that would have replaced it is
  recorded as the wrong currency rather than an untried idea.
- The phantom walk now **prices serving each directory against the listing it would displace**, instead of serving every directory the snapshot can prove fresh. On the cheap-literal shapes where the snapshot was quietly losing money that is **1.95x** end to end, on the filtered shapes where it wins it is a further **2.7x**, and stdout is byte-identical in every case.

  This started as a chase after zoekt, which is 10-17x faster than us on cheap literals. The honest finding first: zoekt has no better walk, because **zoekt does not walk**. It makes zero corpus syscalls at query time and answers entirely out of memory-mapped index shards, which means its results lag the tree by however long its re-indexer takes. That is a different freshness contract, not a faster algorithm, and it is not one we want - gist's index may never overrule live bytes. So there was nothing to steal at the top. What the comparison did do was force the question of where our own query-time syscalls actually go, and the answer was embarrassing: **158k `lstat` calls, ~592 ms of system time, to recover clocks we had already thrown away.**

  The snapshot proves _membership_, never content. So a served directory hands back children with no timestamps, and every file the filters admit then pays its own path-resolving `lstat` before index elision may skip it - where the live listing would have recovered every child's clocks inside the one `getattrlistbulk` it was already making. Serving is three syscalls cheaper per directory and one stat dearer per admitted file, so the trade inverts with the shape of the query, and we had been taking it unconditionally. Over 157,758 files of Linux + TypeScript source, `-g '*.rst' import` admits about one child per directory and beat an all-live walk 117.6 -> 30.6 ms, while `-l EXPORT_SYMBOL_GPL` admits every child and **lost to having no snapshot at all** (199.6 ms against 114.0 ms).

  The fix is a budget rather than a heuristic: a directory over it declines. The first cut set that budget by counting syscalls - the probing `lstat` spends one of the listing's three, leaving two for files - which is superseded by the measured constant of six in `+freshness-walk-cost-reattributed.fixed.md`; counting calls prices a listing as three fixed syscalls when `getattrlistbulk` in fact resolves attributes for every entry in the directory. The budget being finite is what averts the collapse below, and that holds either way. Counting the admitted children costs nothing extra, because the pass that notes which ignore files exist was already walking them - the ignore scan, the path-filter verdict and the count are now one fused pass, so a broad query declines before it spends a syscall. The count is a deliberate _upper_ bound: only filters that are pure functions of the path are consulted, ignore rules can admit strictly fewer files and never more, and over-counting merely routes a directory to a live listing that answers identically. Withholding the already-rejected children from `handleEntry` is where the filtered class picks up the rest of its win, since each one would otherwise re-derive the same verdict.

  Minimum of 30+ runs per arm, all three from one binary behind one branch, because this machine hosts ~10 coworker agents and the mean moves 2x under their builds:

  | query                  | snapshot off | serve whenever fresh | serve on the budget |
  | ---------------------- | -----------: | -------------------: | ------------------: |
  | `-g '*.rst' import`    |     117.6 ms |              30.6 ms |         **11.3 ms** |
  | `-l EXPORT_SYMBOL_GPL` |     114.0 ms |             199.6 ms |        **102.5 ms** |
  | `-l <no match>`        |     116.9 ms |             198.1 ms |        **102.8 ms** |
  | `--files`              |     104.0 ms |               8.0 ms |          **8.0 ms** |

  Broad queries land slightly _ahead_ of the all-live walk rather than behind it, the point being that the accelerator stops charging where it cannot pay - it still serves the directories that happen to hold at most the budget's worth of admitted files. `--files` wants no clocks at all, so nothing is budgeted, every recorded directory is served, and that class is untouched at ~13x. **The remaining gap to zoekt on cheap literals is the freshness contract itself, and closing it would mean giving up the guarantee.**

  Two things guard this. `bench/conformance/gates/parity/phantom_walk_parity.sh` is new, and is the differential twin of `index_elision_parity.sh` with the snapshot as its subject: 31 cases assert the phantom-served run has the same byte-exact line multiset as the same query under `GIST_NO_PHANTOM=1`, deliberately covering _both_ branches (broad cases that decline, filtered cases that serve) plus the two freshness adverse cases - a child rewritten in place leaves its parent's clocks untouched, so the directory stays servable while the file is stale, which is exactly the false negative the snapshot could manufacture. It carries a positive control, because two runs that both emit nothing agree perfectly and 26 of these cases once passed vacuously that way on a leaked `GIST_TEST_REQUIRE_ELISION`.

  The second guard exists because the fused pre-pass introduced a real crash. `--iglob` is the one path filter whose verdict allocates - it case-folds both the glob and the path, once per pattern - and its `lowerDup` **aborts the process** rather than reporting a short buffer, so folding on a fixed stack buffer meant enough `--iglob` patterns over a long enough path would kill the walk. The pre-pass now proves capacity before it folds and declines the directory when it cannot. Deleting that one line makes the gate's wide-`--iglob` cases exit 2 where the live listing exits 0, so the guard is load-bearing by proof rather than by assertion.
- The price lane had four hand-written timing loops that were the same loop. `mint.zig` and `regret.zig` each carried their own little `Doc` / `Cx` / `Pbx` wrapper to point the min-of-N timer at a DFA, a composed matcher, or a Parabix pass, and each of them threaded `gpa`, `io`, `clock`, `rounds` through by hand. Four copies of a timing loop is four places for a timing bug to live, and the whole value of the lane is that a regret row and the coefficient it judges are the *same* measurement.

  So now there is one instrument. A run builds a single `probe.Rig` — allocator, clock, round count — and every number in both tables is timed through it. The arms are one generic `probe.Pass(Machine, call)`, so the DFA, lazy-DFA, composition, and Parabix probes are that one shape pointed at different kernels instead of four near-copies that can drift apart. Nothing about the numbers changed; the surface a bug can hide behind got a lot smaller.

  The footprint sweep also had a pattern in it that could never work. `\p{L}{12}\p{N}{4}[0-9]{8}` was there to push the table-size range wider, and, being unbudgeted, it determinized happily until it crossed `powerset.max_states` (4,096) — the one ceiling `force_dfa` does not waive — and threw the entire automaton away. It printed no row, moved no coefficient, and cost **0.6 s of a 2.4 s gate on every single run**. Interleaved with-and-without runs put every other coefficient inside noise (`dfa_step` 1.354/1.367, `pike_step` 29.428/29.343, `sieve_line[0]` 1.363/1.199), so it was pure toll. It's gone, and why it can't work is recorded in `mint.zig` rather than deleted — widening that sweep past 1.4 MB needs a bigger `max_states`, not a bigger pattern.

  Gate is **1.8 s** where it was 2.4 s; `mint` alone is **1.2 s** where it was 1.85 s. The README claimed twenty, which was build time wearing a measurement's clothes, and it named the discarded `\p{L}{12}` as the heaviest thing in the lane — a determinization whose output was never once used. Both fixed, and the sweep's real ceiling is now pinned by a freshness sentinel on `max_states` itself so the prose can't outlive the number.

  One optimization here got tried and refused. The two-point fits (`skip_verify`, `anchor_line`) allocate and fill an 8 MiB haystack per point, and reusing one buffer across both points looks free. It isn't: point two then reads a warm buffer where point one read a cold one, and the coefficient *is* the difference between them, so the asymmetry lands directly on the answer — `anchor_line` and `skip_verify` both destabilized immediately. Reverted to a fresh draw per point. The one piece kept from the attempt is a correctness fix: `skip`'s planted twin now copies its bytes explicitly instead of trusting two draws from the same seed to agree.
- The published Linux wheel was 11 MB, of which roughly 9 MB was DWARF nobody who ran `pip install` was ever going to read. Debug info outweighed the code about four to one on ELF and PE; macOS only looked innocent because Mach-O keeps its DWARF in a separate `.dSYM` that never entered the wheel in the first place.

  `build.zig` now takes `-Dstrip`, off by default so a local build stays debuggable, and the wheel matrix passes it. Every wheel in the matrix is now under 0.8 MB and they are within 0.1 MB of each other instead of varying six-fold by platform. The full binding suite passes against the stripped library.
- The published metadata now says what this engine is for in the words somebody
  types when they have the problem. PyPI and crates.io both score name, summary,
  and keywords, and this package was spending all three on synonyms for its own
  name: `regex`, `regexp`, `re`, `pattern`, `bindings`. `pattern` is a word every
  crate in the category uses and `bindings` is what the category field already
  says, so neither was doing any work.

  The word that was missing is `redos`. Linear-time matching is the whole claim,
  and "my regex hung the worker" is how the problem gets searched - so the summary
  now leads with no catastrophic backtracking and no ReDoS rather than with the
  implementation detail that the engine rides in the wheel. The README says it
  too: the h1 carries the claim instead of just the package name, and the section
  explaining `(a+)+b` now names the attack it is describing.

  Also here: the trove classifiers grew the ones that were true and absent
  (`Typing :: Typed`, since `py.typed` has always shipped; the three supported
  operating systems; text-processing and indexing topics), the PyPI sidebar gained
  Documentation and Changelog links, and crates.io gained `readme`, `homepage`,
  `repository`, `documentation`, and three more categories. Nothing about the
  engine moved - this is the packaging telling the truth louder.

  One real fix rode along: the Python README claimed a 3.10 floor while
  `requires-python` has said 3.12 since the PEP 695 syntax went in. A reader on
  3.11 would have believed the README and gotten a resolver error.
- The regex syntax plane is six files instead of one, and `syntax.zig` is now a
  front door: one `pub const` per exported name. Nothing outside the folder
  changed - the same `@import("../syntax/syntax.zig")` still answers `syn.Node`,
  `syn.Parser`, `syn.State`, `syn.ByteSet`, `syn.Word`, `syn.foldCaseAst` - so this
  is invisible to every consumer and to the compiled output.

  The cut follows the grammar's own layering rather than file size, which is why
  each file only depends on the ones above it. `tree.zig` is what a parsed pattern
  *is* (the byte class, the AST node, the NFA instruction, the one error set);
  `assertion.zig` is the word-assertion truth table and its algebra, with zero
  imports, so every engine arm can share it; `scalars.zig` holds the Unicode range
  accumulator that no node ever carries plus the `-i` fold that rewrites a finished
  tree; `escape.zig` is what a backslash denotes, beside the POSIX tables `\d` is
  defined against; `bracket.zig` is what a `[...]` body denotes in both modes; and
  `parser.zig` keeps the cursor and only the four mutually-recursive grammar levels,
  so it reads as the shape of the grammar instead of the shape of the syntax.

  The `MONOLITHIC` marker is gone with it, since the reason it existed - the class,
  AST, and instruction invariants being co-maintained - turned out to name one file
  (`tree.zig`), not the whole plane. Functions moved as-is; the compiled `.text`
  segment differs by 48 bytes across the three binaries, which is the embedded
  source-location strings changing length, and the test suite is unchanged.
- The rename stopped at the header, and it showed. You included `irgx.h`, called `irgx_compile`, then linked `-lirregex` and compared the result against `IRREGEX_OK` - one API that could not decide what it was called. The rest of it has caught up.

  The artifact is `libirgx.a` / `libirgx.dylib` / `irgx.dll` and the flag is `-lirgx`. The whole uppercase family is `IRGX_*`: the status codes, the fault-locus and pattern-flag enums, the analytic bitsets, and the include guards. So are the build knobs - `IRGX_LIB`, `IRGX_LIB_DIR`, `IRGX_NO_FFI`, `IRGX_PREBUILT_LIB`, `IRGX_<NAME>_CONTRACT`, and the wheel platform / Zig target pair the packaging hook reads. Those were chased as strings rather than identifiers on purpose: a missed enum is a compile error, but a missed knob is silent - the variable simply stops being read and the build quietly takes the default path.

  Go got the limb it was missing. The package is `irgx`, so a caller writes `irgx.Compile` to reach `irgx_compile` instead of `irregex.Compile`, and the cgo tier builds under `-tags irgx_ffi` or `-tags irgx_syslib`. `relate` and `blast` had already moved to those tags, so until now there was no single tag that built the cgo rung across all four repos. The module path is still `github.com/The-Billy-Company/irregex/bindings/go`, because that is the repo URL and nobody types it as a name.

  Both vendored archive sets were re-cut off the renamed engine. A stale archive still exports the old symbols and fails at the linker after every source file already looks right, so a checkout that skips the rebuild finds out late.

  This is the same v1 window as the prefix itself: a library filename and a macro are compile- and link-time contracts, and tagging freezes them.
- The repo head was still the monorepo's search-product README with the product
  filed off. It opened by explaining itself as a cut of somebody else's crate
  layout, spent its inventory on the walk, the trigram index, and the rg-shaped
  output frames, and got to the regex engine as one bullet in a list of eight.
  Then it buried install, the bindings, and the build on page four, under an
  engine deep-dive nobody reaches before they have the thing compiling.

  `README.md` is rewritten and reordered around both problems.

  **What it says it is.** This package is the toolkit for building a search
  engine, not a search engine and not only a regex library, and the head now opens
  with that. The engine is the center; around it are the SIMD literal scanners
  that decide which bytes the matcher sees, the candidate indexes that decide
  which files it opens, the freshness law that keeps those indexes correct under a
  tree ten people are editing, the compiled query every transport lowers through,
  the two runtimes, ranking, multi-pattern attribution, and the FM-index. Take the
  whole stack and you have a grep; take three pieces and you have something else.

  **It is shaped like a manual now, not an essay.** A contents list, then a
  *Should I be using this?* table that routes you off this page if what you wanted
  was a binding or a terminal tool, then install, then recipes. The engine deep
  dive starts halfway down and the harnesses - build, proof, the measured bounds -
  sit at the end with the other contributor material, because nobody reaches them
  before they have the thing compiling.

  **What you need first is first.** Install, all four ways in, is the section
  after the routing table - Python, Rust, Go, Zig, and plain C, a
  `build.zig.zon` snippet, and a C snippet that actually compiles against the
  shipped header (`irgx_regex`, `irgx_compile`'s pointer+length signature, the
  `IRGX_STALE` re-compile, `irgx_free`).

  **Eight recipes, and the Zig in them is compiled against the module.** The
  three regex ones (match bytes you hold, hoist the compile without hoisting the
  scratch, escalate a pattern the grammar declines), the four you assemble an
  engine out of (many patterns in one walk with per-pattern attribution, a trigram
  candidate set, the crest sieve for patterns with no literal in them, one
  compiled query feeding both the prefilter and the match), and the warm engine
  with all of it already assembled behind a cancel token and a deadline.

  **Two sections were promoted out of the deep dive because they are decisions,
  not history.** *Choosing an engine* is the ladder as a menu - seven rungs, what
  takes each one, and the measured coefficients and regret arm that keep the order
  honest - so you can tell what your pattern is going to get. *Contracts* gathers
  the seven rules that hold across the Zig API, the C ABI, every binding, and the
  indexes: a refusal is a status rather than an error, the fault slot is
  per-thread and pull-based, one handle one thread, versions are three axes, an
  index accelerates and never answers, a stale artifact is still correct because
  freshness is one rule, and a ceiling declines instead of degrading. Five are
  promises; two are obligations you keep back if you build your own artifact on
  these parts.

  **A toolkit map that is actually an inventory.** What was one five-row table at
  the bottom is a full section: every one of the eight kernel packages with what
  it gives you, the five corpus packages, all seven persisted index artifacts by
  what each one *eliminates*, the two runtimes with cold's seven concern packages
  and the session's six planes, and the surface tier. It gives
  `query/` and `scan/` their own paragraphs, since those are the two people assume
  they have to build twice, and it defers the laws those tiers rest on to
  *Contracts* rather than restating them, because they bind anything you build on
  these parts and not only what ships here.

  **The engine sections are unchanged in substance** and keep their order:
  the eight-stage pipeline, the four front-end stages, Unicode, the two roads to a
  deterministic table, the priced ladder, the escape rungs with their published
  losses, spans, the PCRE2 handoff, crest, the proof strategy, and the bounds.

  Every number was re-derived from the source or the harness README that mints it
  rather than carried over. Two claims did not survive that: the roofline figures
  the old head quoted no longer matched the artifact, and a passes-per-candidate-
  byte range for the SIMD classes existed only in an untracked local baseline, so
  both are stated qualitatively now against what the tracked harnesses assert.
- The resident session prunes by the same stack the CLI does. Warm asked the
  trigram index exactly one question — the flat OR of the sound prefilter literals
  — while cold had been asking two stronger ones: the conjunctive cover plan and
  the crest sieve over per-document ρ(d). So the daemon was slower than the cold
  path it accelerates on a whole class of patterns: `[0-9a-f]{8}` forces no trigram
  at all, and warm read 100% of the corpus for it. It now reads 6%.

  Both prunings come off ONE parse. `query.winnow` returns the cover plan and the
  forced crest swell together, and cold's `Writ.compile` was paying `lower.parse`
  twice to read them separately, so the cold compile path got cheaper on the way
  past. `Mirror` grew a per-doc crest vector array built by the persisted sidecar's
  own builder — reused rather than re-looped, so a resident vector and the on-disk
  `crest.bin` vector for the same bytes are the same computation and cannot drift
  into disagreeing about ρ(d). It is 16 B/doc and rides an ingest that already
  touched those bytes; a failure to build it costs the sieve and never the load.

  Each stand-down is cold's, spelled once: caseless keeps its case-variant filter
  (the Unicode-fold bounds are stated in exactly one place and a folded-AST cover
  would be a second spelling of that argument), and a `-F` literal or a PCRE2 body
  arrives with a null `source`, which is the standing "do not re-parse"
  certificate. `GIST_NO_COVER` / `GIST_NO_CREST` stand one half down each, read in
  the daemon rather than the client because that is where the pruning is derived.

  Measured on 5,883 files of real host source, frozen: the cover plan narrows the
  index answer 39-93% on the patterns that force several literals, the sieve takes
  another 44-94% off the literal-free class repetitions, and end-to-end that is
  1.4-1.9x geomean over the ten patterns either half can prune. The candidate
  figures are exact and reproduce row for row; the wall-clock range is the honest
  one, because both arms are the same client spawn and socket handshake around a
  3-18 ms answer and a fixed cost in both terms compresses the ratio toward 1 by an
  amount that depends on the machine's load. `warm_parity.sh`
  holds all of it byte-identical across 27 cases against a second daemon with both
  knobs off, against gist's own `--no-index` read, and against ripgrep — and fails
  closed on a half that never fired, since parity is trivially satisfied by a
  pruning that does nothing.
- The span walk now prices its own prefilter and runs its own transitions, instead of borrowing the boolean walk's economics and paying a call per byte.

  **The bar was the wrong bar.** `pike/span.zig` held its first-byte skip to `dwell.min_profitable_stride`, calibrated for the boolean DFA's premultiplied table walk. A span step is an order of magnitude dearer — it reaches through a state's priority key to decide dead/matched, re-derives the gap's shape, and indexes a memo row keyed on both — so break-even sits an order of magnitude lower, since the thing a skip trades away (a `memchr` call plus a re-entry closure) does not get cheaper when the walker gets dearer. At 32 the skip was withheld from every pattern beginning with a merely-uncommon byte (`f` prices at stride 16), which is most of them, and those patterns then walked every byte between matches. `dwell.min_profitable_span_stride` restates the bar against the measured span cost (3.2 ns/byte vs the boolean walk's ~0.25), floored at 2 because a stride of 1 admits every byte and leaves nothing to skip to. `f.o` on a 1 MB line: 3354 ns/span to 101, and cost per span goes flat in the distance between matches where it used to scale with it.

  **Two facts, one byte.** `automaton.Cache` keeps a `Mark` per state — matched, dead — filled at `intern` time from what the closure already knew. The search loop's two questions were a walk into the state's key and then into that key's last word; they are now one load of a dense array.

  **One row, one loop.** `Cache.glide` consumes a run of bytes through the memo and nothing else, given the caller's proof that the row survives: every landing an interior gap, and one seeding decision throughout. `step` must recompute the row and reload the memo's base pointer per byte because it is a call that might determinize and reallocate; `glide` computes the row once, borrows the tables once, and reduces to a class lookup and one dependent load per byte — the shape a premultiplied lazy DFA walk has, which is the walk this engine has to keep up with. It stops before a byte it cannot decide and after any marked target, so a miss and a match both stay outside the loop. The backward jaw is eligible always (anchored, so it never seeds); the forward jaw is eligible whenever the seed decision holds, and where a prefilter is choosing per byte the run is simply the stretch before the next candidate — which the same jump already finds. Word-context programs stayed on `step` at this point, since `\b` re-reads the gap per byte; they were let into the run afterwards, and that change has its own note.

  Together, on a 1 MB line: `f.o` 176 to 34.6 ns/span at one match per 40 bytes, 3354 to 46.3 at one per 1000 (5.1x and 72x); `foo \w+ x` 509 to 285 and 10927 to 5524 (1.8x, 2.0x); a full non-matching class walk 3.46 to 0.58 ns/byte. Against ripgrep's `--count-matches` over a real multi-language source tree, every span pattern measured now wins: `foo|bar|zzzzq` 8.1x, `[0-9]{4}` 5.2x, `\bfoo\b` 5.1x, `foo \w+ x` 4.6x, `pgxpool\.\w+` 4.6x, `f.o` 3.9x, `[a-z]+_[a-z]+_[a-z]+` 3.7x, `func \w+\(` 2.5x, `[A-Z][a-z]+[A-Z]\w*` 1.2x. On a 41.6 MB *saturated* single line — a match every other 40 bytes, where per-step cost is the whole workload — the automaton arms move from ~5x behind to 0.87x (`f.o`), 0.78x (`f.o|zzzzq`), and 0.44x (`foo \w+ x`). That was the last shape ripgrep led on; the two notes after this one take it. Counts byte-identical throughout; the mined ripgrep conformance suite holds 411/411 on both the parallel and serial paths, cold and warm agree with each other and with ripgrep, and the caliper's differential fuzz against the Pike VM oracle runs both skip policies over every sampled ceiling.
- The start-state skip's derivation moved out of the byte determinizer into
  `linear/automata/dwell.zig` and the concept is now named for its structure rather
  than its effect: a **dwell** is a state the scan sits still in, and its **exit set**
  is the bytes that get it out.

  The rename is the point, not cosmetics. The old vocabulary was "acceleration"
  (`startAccel`, `Dfa.accel`, `matchAccel`), which names an *effect* — and a module
  named for an effect has a membership rule that admits everything, since the
  prefilter kernels, the trigram index, parabix, the shuffle rung, and the sieve all
  accelerate and each would have an honest claim to the file. Naming it for the
  question it answers, *which bytes leave this state*, makes the admission test
  structural: executing a skip stays with `analysis/prefilter.zig`, and a thing that
  merely goes faster is not a dwell. The rule is written into the file and into
  `linear/automata/README.md` so it cannot drift back.

  `dwell.zig` also answers the question the old code could not. The rule now has one
  transcription over two views of an automaton — pre-freeze (state ids, match flags in
  a side array) and frozen (premultiplied offsets, match status as C1's bound) — so
  `survey` can ask it about *every* state, and `min_profitable_stride` is an argument
  rather than a constant, which is what separates "no state has a narrow exit set"
  from "narrow, but the corpus prior says stepping is cheaper".

  That instrument is what the new `automata-rung -- dwell` section reports, and it is
  how claim C4 got settled. On documents built to *enter* an interior `.*` dwell and
  sit in it, `a.*b` spends **97.5%** of its bytes in a state with a narrow exit set
  and elides **0.0%** of them today — every refusal the profitability bar, none the
  automaton's shape. That reading says build it, so the section grew a cost arm that
  does; C4 is retired on the timing rather than the census.

  Behavior is unchanged — the engine still derives the start state's dwell only, on
  the same patterns, with the same exit sets.
- The third-party checkouts the differential tests and research dossiers read
  from moved out of a hidden dotfile bucket into `upstream/`. Those are clones of
  BurntSushi/ripgrep and rust-lang/regex - the oracle the conformance suite
  mines its cases from, and the semantics the regex engine is judged against -
  and they are gitignored, so nothing fetches them for you. That was another
  convention carried out of the monorepo, and it is a bad one to inherit: it
  looks like a dotfile bucket, it sorts out of sight, and nobody guesses that a
  clone of somebody else's repository is what belongs there. `upstream/` says
  what it holds. If you already have the clones, move the directory; if you do
  not, the differential rungs skip themselves the same way they always did.
- The unit suite went from **~17.7 minutes to ~70 seconds** on the edit loop,
  without weakening a single assertion. (Wall clocks are an idle 16-core box; this
  tree is shared by ~10 agents, so a busy machine stretches all of them.)

  The suite was never slow — it was **serial**. Zig's stock runner walks
  `builtin.test_functions` start to finish in one process, so 991 tests ran on one
  core of sixteen at `user/real = 0.64`. The chassis now compiles the test binary
  once and hangs _n_ independent `Run` steps off it, each owning the residues of
  `BRIGADE_SHARD=i/n`; the parallelism is the build runner's own scheduler, which
  already spreads independent steps across cores and gives each its own output
  pipe. No thread, no fork, nothing to make thread-safe — a shard is just another
  process. Per-test semantics (fresh allocator and `Io`, leak detection, skips,
  error-return traces, logged-error counting) are byte-identical to the stock
  runner, so sharding is invisible to test authors. The default is 2× the core
  count, deliberately over-decomposed so the runner's `cores - 1` in-flight limit
  behaves as a work queue: 16 shards 86 s, 32 shards 71 s, 64 shards 74 s.

  Sharding cannot split one test, so the floor becomes the slowest single one.
  `BRIGADE_TIMES=1` (per-test `<ms>\t<name>`) found four compile-bound
  differentials — the word-boundary Unicode quit path at 320 s, its ASCII
  counterpart at 160 s, and the two symbolic differentials at 101 s and 88 s —
  costing 669 s of the suite's 1059 s. They carry explicit coverage floors, so
  their sweeps stay exactly as they were; `build.zig` names them as `deep_tests`
  and `zig build test-quick` (`zig build test-quick`) runs everything else. Full
  `zig build test` is unchanged and remains what a push is judged by; the quick
  tier is a deliberately weaker proof and says so. A `deep_tests` entry that stops
  matching is reported by name and only ever makes the quick tier slower.

  `-Dtest-filter=` / `-Dtest-skip=` narrow by name substring, so the actual answer
  to "did the test I just touched break?" is now ~0.1 s rather than a coffee break.
- The version is written in exactly one place now: `build.zig.zon`. `build.zig` lifts `.version` into the module as a build option, so `src/root.zig`'s `version_string` - and therefore `irgx_version()` and every harness banner - reads the package manifest instead of restating it. The Rust binding's `ENGINE_VERSION` is `env!("CARGO_PKG_VERSION")`, and the Python package's `__version__` comes from its installed distribution metadata, falling back to whatever the linked engine reports in a source checkout that was never installed. None of those three can drift from the manifest, because none of them holds a copy.

  Four copies survive, and only because the file they live in cannot import anything: the contract, `Cargo.toml`, `pyproject.toml`, and the Go mirror, which has no way to read either its own module version or a file outside its module root. Each carries an `x-release-please-version` marker, and `release-please-config.json` lists all of them, so one merged release PR moves the whole lockstep in a single commit. `tools/version_parity.py` is what keeps that honest: it hunts the markers rather than holding a list, and fails both when a copy drifts and when a copy exists that the release config was never told about - the second being the quiet one, since nothing breaks until a release ships a package claiming last version's number. It runs in CI as the `version` job.

  This is the failure the contract already recorded in its own comments: `engine_version` sat a minor behind for a whole release because nothing moved it with the other two, and the parity test that should have caught it was skipping on an unresolvable path. The number can no longer be somewhere it was not typed.
- The walk stopped materializing every path it walks in the immortal worker arena. Priced on llvm-project (175,110 files, frozen so the number is reproducible), a `--no-index -l` sweep owns 3.0 MiB of worker arena where it used to own 26.4 MiB, and peaks at 69 MiB RSS instead of 88. The ratio holds around 8x on a `-uu` sweep of this repo, where it is worth a few hundred MiB of peak. Output is byte-identical: 22 query shapes over that frozen corpus, each arm run twice so per-arm determinism is proven before the arms are compared at all.

  Two things were paying for nothing. `task.rel` and `task.scope` are the same slice on the rootless whole-CWD walk and on any root whose scope prefix matches its display prefix, which is every walk but an explicitly-rooted one, and `handleEntry` was joining both - so every entry in the tree bought two copies of one string. One prefix compare per entry replaces the second join and the second copy. Then the remaining joins moved onto the per-directory scratch `workerMain` already recycles, and only the branches that genuinely outlive the directory dupe into the worker arena: a queued child `DirTask`, a file deferred while the elision oracle is still loading, and a `--sort` record. An explicitly-rooted walk cannot take the aliasing shortcut, and there the scratch routing carries it alone, 11.2 MiB down to 0.9. `--sort` owns its paths by definition and keeps the arena, so it moves least, 7.4 MiB to 5.0.

  Scored in the units the certificate actually argues in - `bench/rungs/sliver/walkcost.py`, the matched live-walk pair against real ripgrep, re-run today on both arms over the same tree - gist's owned working set for `-uu -F -c` drops from 92.2 MiB to 61.0 MiB and its maxrss from 105.4 to 73.6, which closes the owned ratio the walk-cost refutation turns on from 3.32x rg to 2.12x. (The committed `scale_walkcost.tsv` reads lower than either arm because it was captured when `upstream/` held 239,162 files; that staleness is the next mint's business, not this change's.)

  Do not read this as a speedup. Min-of-15 with the arms swapped every round puts this repo's live `-l` scan at 0.965x, and the other shapes land between 0.84x and 1.11x - but an indexed answer, which barely touches the walk arena at all, lands at 1.046x by itself, so that spread is the noise floor of a laptop running ten other agents, not a result. The walk is sys-bound and the arena was never on its critical path. What changed is the footprint.
- The walk's worker pool is now a starting bet the walk may revise. A `-uu` sweep
  of this repo (54 GiB once `.local`'s build artifacts and `.git` fold in) ran at
  the six-worker macOS ceiling and left most of an M4 Max idle on reads: 102.7 s at
  six workers against 81.3 s at twelve, with the extra time going nowhere but I/O
  wait. Nothing in the flags said so up front, which is why the ceiling had been
  tuned against the walks it was measured on - and it is right for those. A warm
  indexed scan answers in 40 ms and is FASTEST at six (2 workers 73.5 ms, 4 48.4,
  5 46.3, 6 40.6, 8 43.7, 12 47.6, 16 56.9), because that walk is namei-bound and
  more threads only add vnode contention.

  So the crew starts at `defaultWorkerCount` and hires. `crew.Crew` owns the
  roster; any worker that finishes a directory calls `consider`, which widens only
  when the walk has run past `patience_ns` (500 ms) AND the outstanding front holds
  at least two directories per hired worker. Elapsed time is the discriminator
  because queue depth is not: a front thousands deep is ordinary on any wide tree,
  where 500 ms of walking is something no interactive query on this corpus does.
  The front test is what keeps a walk with one enormous file left from hiring hands
  that cannot touch it. `-j`, `GIST_WORKERS`, and a transform run's own `ncpu`
  fan-out pin the ceiling to what the caller asked for; the file-set walk
  (`roster.collectFileSet`) is fixed-width by construction, since it reads no bytes
  and so has no I/O latency to hide.

  The ceiling is the machine's FAST core count, not `ncpu`: `portal.performanceCores`
  reads `hw.perflevel0.logicalcpu`, and a symmetric machine (every non-Darwin host,
  an Intel Mac) keeps ripgrep's scale-to-`ncpu` model. On this box that is 12 of 16,
  and the four efficiency cores are what the number buys you out of - against the
  twelve-worker run, the full-16 pool was 1.9% faster in wall time (79.7 s vs 81.3 s)
  for 62% more system time (310.7 s vs 191.7 s), which on a laptop running ten other
  agents is a loss.

  Measured on the reported case, one run each: 102.7 s at the old fixed six, 74.7 s
  elastic (1.38x), hiring 6 -> 12 as reported by `GIST_TRACE=walk`. System time is
  unchanged from the six-worker run (171 s vs 167.6 s), so the win is latency the
  pool was already paying, not new work. What hiring costs is one read scratch per
  new hand and nothing else - peak resident over the same `.local` sweep is 2208 MiB
  elastic against 2166 MiB pinned to six, a 2% difference against a 24 MiB scratch
  delta, so a wider crew does not hold a wider working set. Output is byte-identical to the fixed-width
  run over the whole 54 GiB sweep, and the interactive walks stay at six workers -
  `GIST_TRACE=walk` says `6 workers (from 6)` for both a warm whole-repo scan and a
  scoped one, so the topology those measurements pinned is untouched.
- There are two roads to a DFA here — the byte powerset construction and the
  symbolic predicate-alphabet determinizer — and they now share a floor instead of
  each carrying a copy of it. New `linear/automata/` holds the operations on a
  finished automaton that cannot say which road produced it, with one membership
  rule: shared *by nature*, not shared *by accident*. `freeze.zig` moves there from
  `linear/dfa/`, where it had been sitting inside one road's folder while the other
  reached across a boundary to borrow it; the three ordered layout passes it owns
  (match-first renumbering, start acceleration, premultiplication) are established
  once rather than transcribed twice. `dfa/dfa.zig` deliberately stays put — its
  path is pinned inside the frozen benchmark manifests under
  `bench/certificate/artifact/`, and tidying a folder is not a reason to rewrite
  recorded evidence. Claim C5's shared partition-refinement core is the next
  occupant.
- Unanchored determinization no longer re-walks the NFA start's epsilon-closure on every transition. `subset.step` re-seeds the start on each step (that is what "unanchored" means), so the start's whole closure was being rebuilt `nstates x ncls` times — and that closure is not small, since a Unicode class lowers to a ~10^3-state UTF-8 trie sitting immediately behind the start, and a fused N-pattern union puts the entire `chorus.zig` split tree there. It is also the determinizer's one loop-invariant: epsilon-closure distributes over union, so `close(A ∪ {start})` is `close(A) ∪ close({start})`, and the second term depends on nothing but the assertion gap. A step can present only eight distinguishable gaps (`at_start` is false everywhere but the start state, which `closeStart` seeds directly), so `Subset.primeSeeds` walks the start once per gap at init and `step` folds the cached consume-set and pattern mask in with a bitset OR. Identical automata — same states, same transitions, same masks — since the dedup bitset the fold bypasses only ever governed work, never the answer. Both drivers share `subset.zig`, so the eager `powerset.zig` build and the on-demand `lazy.zig` cache-miss path both get it. Measured in `bench/rungs/patternid` (new fourth section): union builds 1.26x (3 literals), 1.69x (8), 2.25x (18 literals), 1.58x (8 shared-affix), 1.75x (6 regex bodies), with the anchored control unmoved at 6.1 us as it must be, and small single-pattern automata (3-17 states) flat because the saving scales with `nstates x ncls`. The fold is charged to `Subset.visits`: uncharged, work the budget cannot see let a doomed build run 11% longer before reaching the same `too_costly` verdict, so the widest slate regressed 0.90x — charging one unit per bitset word restores decline parity at 1.00x while leaving successful builds their full speedup. The scalar-level `symbolic/determinize.zig` carried the same per-step re-seed and gets the same treatment with one gap dimension instead of three (no word context there, and `at_start` is false in every step, so two cached closures rather than eight); it is the identical invariant rather than a separately measured ratio. Full `zig build test` green, differential fuzz against the Pike VM oracle included.
- `Regex::group_names` and `Regex::group_index` answer from the compiled pattern
  now, not from a scan of the pattern text.

  Filling that table used to mean walking the pattern bytes looking for `(?P<x>)`
  and `(?<x>)` and then confirming each candidate through `irgx_group_index`.
  It is a second parser, and it only ever had to be wrong once to lose you a name
  silently. PCRE2's `(?'x'…)` was never taught to it, so that spelling vanished.
  An escaped `\(` counted as a group and shifted every number after it. A `(?#`
  comment is just text, and text is all the scanner could see. None of that is
  fixable by scanning harder - the parenthesis you are looking at means whatever
  the grammar that already ran decided it means.

  ABI 2 adds `irgx_group_name`, so the table is now walked out of the handle:
  group 1 through `irgx_group_count`, whatever the engine calls each one, the
  same on the linear arm and the PCRE2 arm. Both textual helpers are gone. The
  public shape did not move - still `(name, group number)` in declaration order,
  still only the groups that have a name. The engine lends those bytes for as long
  as the handle lives, and the handle goes back to the pool when the compile
  returns, so each name is copied into an owned `str` on the way past.

  Two more things arrived with ABI 2, and both are things you notice by nothing
  going wrong.

  `irgx_fault` now says which string its offset is measured in instead of
  leaving you to work it out from a NULL path, so `Error::Syntax { at }` is filled
  only from an offset the engine measured in the pattern - the string you would
  print a caret under. There is no corpus behind this library and no verb here
  opens a file, so a file-space offset is a debug assertion rather than a branch.

  `find_all` reports how many matches the text HAS rather than how many fit in the
  window it was handed. So `Regex::find_iter` over a text with more matches than
  the first window holds is two searches, always: one that measures, one that
  collects at exactly the size the first one reported. It used to double the
  window and go around again, and a text whose match count landed exactly on a
  window size paid a whole extra scan to discover it had already been finished.

  `ABI_VERSION` is 2 and still checked before the first call, so a `libirgx`
  handed in through `IRGX_LIB_DIR` that speaks ABI 1 says so in a sentence
  naming both numbers rather than reading `at_space` out of a struct that does not
  have one. The four vendored archives are rebuilt on it.
- `[status_codes]`, `[decline_reasons]` and `[fault_domains]` are declared here
  again, in `contract/engine.toml`. The ecosystem split had carried them out to
  `gist/contract/surface.toml` along with the row schemas that genuinely belong
  there, and it was the wrong home for a reason worth naming: `include/irgx.h`
  is what returns those codes and that fault struct, so a host linking only
  libirgx — the entire point of shipping this library separately — received a
  vocabulary that no contract in this repository declared. librelate, libgist and
  libblast speak it by linking it, not by redeclaring it.

  The file said so itself the whole time. Its own section header still argued that
  the in-process vocabulary "lives here because it is otherwise hand-copied four
  times", and promised "the three tables after it" — and after `[exit_codes]` the
  file simply ended. Nothing had gone wrong at runtime; the tables were fine where
  they sat. What had gone wrong is that the contract was describing a shape it no
  longer had.

  Two other things it claimed are now true rather than aspirational. It carried a
  second, pre-split table of contents advertising twelve tables and describing
  `irregex` as "the composed face" — that binary has since been renamed `blast` —
  so a reader learning the ownership model from this file learned the old one. And
  it said the bindings work from a vendored copy of it; they don't, and never did
  here: each one resolves this file from the authoring sibling checkout, which is
  why `tools/sync_contract.py` checks that the sibling exists instead of copying
  anything.

  Table contents are byte-identical to the pre-split declaration, verified against
  the monolithic `search_api.toml` still in git history: same six statuses, same
  five domains with the same members, same five decline reasons.
- `argv` is now a five-module package behind one facade: `args.zig` re-exports the
  interface the tree's thirty-odd importers see, while `verdict` / `intent` /
  `catalog` / `grammar` own value parsing, the request record and its builder, the
  declarative `flag_catalog`, and the argv walk. Adding a flag is usually one
  catalog row plus one `Opts` field, and the inside can be re-cut without a
  call-site edit.

  `die` / `oom` moved to `cli/outcome.zig`, beside the other ways a face ends —
  which also collapses the second OOM emitter the corpus layer kept in step by
  hand, and removes the layering inversion where `corpus/` reached up into the
  CLI's flag module to exit.

  A braced `-g '{a,b}'` glob no longer answers wrong on the warm resident path.
  The session's own argv classifier cannot expand an alternation, so it now
  declines one to cold — which expands it — instead of pushing the raw pattern
  into a flat filter that matched nothing.
- `bench/` keeps only the buckets whose subject is the kernel. The conformance
  slate and the corpus fetcher moved to the sibling `gist` package, because what
  they oracle is a compiled `gist` binary and this package does not build one —
  four of its parity gates had been looking for that binary in this repo's
  `zig-out`, where it will never appear.

  What stays is what this package can actually run: `rungs/` (per-mechanism
  production proofs), `bounds/` (distance from a stated limit), and
  `apparatus/harness/` (the `gist-bench` binaries, PMU counters, bootstrap
  statistics, and the 12-class probe registry that both repos' lanes read, so a
  competitor race there and an engine rung here still map 1:1 by class name).

  `apparatus/roots.sh` stays too, and now also names the checkout that owns the
  `relate` binary. It is deliberately duplicated rather than shared: it answers
  "where am I, and who is next to me," which only a package can answer about
  itself, and the two copies resolve differently on purpose.
- `contract/analytic.toml` is new here, and it is the rest of the split the
  previous entry started. That one moved thirteen tables out of this kernel's
  contract on the grounds that they described surfaces gist and relate own. Six of
  them turned out not to be owned by any product at all: `[row_enums]`,
  `[row_schemas]`, `[analytic]`, `[analytic.producers]`, `[analytic.params]` and
  `[analytic.verbs]` describe the one self-describing row that gist, relate AND
  blast all hand back through the same `irgx_rows` cursor. Row layout is
  substrate. It lives with the engine that emits it, not with whichever product
  declared it first.

  What stays with a product is that product's own surface: gist keeps
  `[package]`, `[transports]`, `[session]` and `[tool_boundary]` in
  `gist/contract/surface.toml`, and blast's `[compose]`, `[compose.verbs]` and
  `[compose.retired]` moved to the new `blast/contract/compose.toml`.

  `tools/build_schema_tables.py` came back with the tables it lowers, and the loop
  it could never close is now closed. Its own docstring had been carrying the
  hole: the Zig table is this package's file, but `[row_schemas]` was declared in
  gist's contract, so neither repo could own both ends and
  `src/surface/ffi/schema.gen.zig` had to be regenerated by hand from over there.
  It had duly drifted — by one comment line, which is exactly the drift you get
  from a generated file nothing regenerates. It is a TARGETS row now, and
  `--check` covers it.

  The split is textual, and the digest proves nothing moved but the addresses:
  `fe410e7f8ccb9a62c71bd28161f2e080` before and after, over the same 22 schemas,
  17 verbs and 4 enums.

  Two facts that had quietly gone false were corrected on the way past.
  `[analytic].handle` still said `gist_engine` after the engine moved down into
  `libirgx`, and the prose beside `[analytic.producers]` still said all three
  producers share a `gist_engine`; both name `irgx_engine` now.
- `contract/search_api.toml` is now `contract/engine.toml`, and it only declares
  what this kernel actually authors: the request surface, match kinds, exit codes,
  and the version axes. It used to carry fifteen tables while the kernel cited
  two; the other thirteen described surfaces belonging to `gist` and `relate`, and
  have moved to `gist/contract/surface.toml` and `relate/contract/kinship.toml`
  respectively. The clearest sign it had gone wrong: the single biggest table was
  named `[irregex]` and described relate's compression vocabulary.

  The split is textual, so every line of the prose explaining why a value is what
  it is moved with the value. All 419 leaf keys are accounted for; none was
  dropped, renamed, or invented, apart from `meta.package_dist` and
  `meta.package_import`, which name artifacts gist publishes and are now
  `[package] dist` / `import` in gist's contract.

  `tools/build_schema_tables.py` moved to `gist/tools/` alongside the files it
  generates. It had grown a walk into a sibling checkout to reach them, which only
  ever encoded living in the wrong repo. (It moved back here shortly after, once
  the row schemas were recognized as substrate rather than gist's — see the
  `analytic.toml` entry, which is where that reasoning finishes.)
- `gist index` peaks at **2528 MiB** where it peaked at 4067 MiB on the same corpus (llvm-project: 175,110 files, 1926.3 MiB), and still finishes in the same time — 6.7-8.1 s across four clean runs, against ~7.0 s before. `index.gist` is byte-identical (`9775cadb…`), and indexed answers match live-scan answers exactly on every probe tried. The trigram builder's intermediates no longer scale with the corpus at all.

  The old builder was correct and fast and had one structural flaw: **everything it needed in order to sort was proportional to the input.** Extraction materialized the whole `(trigram, doc)` pair table, the scatter allocated the whole doc-id array beside it, and a 16.7M-bucket histogram sat across both — 141.9M postings meant 1082 MiB of pairs plus 541 MiB of doc ids plus 64 MiB of histogram, all resident at once, to produce a 154 MiB index. That shape says the corpus must fit in memory several times over before an index exists, which is exactly why `csearch`, which spills, held a smaller peak than we did.

  `kiln.zig` sorts a **window** instead, and keeps only what compresses. Each worker fills a fixed block of pairs from its doc range, stable-radix-sorts it on the 24-bit trigram, and immediately encodes it into a *run* — the same delta-varint shape the finished index uses. Then it reuses the block. Measured: 370 runs holding 167.1 MiB, or **1.23 bytes a posting where the pair table spent 8**, against a 96 MiB block window that does not grow with the input. The one array still sized by the answer is the CSR body, which is the artifact.

  **The merge needs no comparison between doc ids, because the partition already carries the order a heap would have to rediscover.** A worker owns a contiguous ascending doc range and fills its blocks in doc order, so ordering the runs worker-major then block-major orders them by doc range; for any trigram, concatenating its group from run 0, run 1, … is already globally ascending. Stability is what makes that true and is the reason the sort is a radix pass on the trigram alone: postings were appended in ascending doc order, so a stable sort on the tag leaves every group's docs ascending, and the builder never compares a doc id anywhere. A document whose trigrams straddle a block boundary is still sound — each of its trigrams lands in exactly one block, so no trigram sees that doc twice.

  The one question the sweep does ask 661,572 times is which run holds the smallest trigram still unread, and **the textbook answer for it lost.** A tournament tree turns 370 predictable reads into nine dependent ones and measured 673 ms against a linear scan's 571 ms — asymptotically better, ~18% slower, because 370 keys are 1.5 KiB and the scan they defeat is L1-resident and vectorizable. What did pay was lifting the key out of the cursor: scanning `Cursor` in place reads a liveness flag and a trigram out of a 40-byte struct, and the stride is what defeats vectorization. A flat `u32` key array where a spent run carries `maxInt` and always loses reads **474-569 ms**, and the liveness branch is gone with it.

  The remaining sweep cost is not the ordering at all — it is transcoding 141.9M varints, since a group's first posting is the only one whose delta changes when runs are concatenated. Copying the rest verbatim would need each group's byte length and last doc stored in the run (~36 MiB more) to save ~350 ms, and that trade is not worth taking while the corpus itself is still the peak: 1926 of the 2528 MiB is the bodies, held because the trigram build, the crest sieve, and the content shard each read them once. Streaming the corpus past all three is the next rung, and it is the only one left that can move this number much.

  Both routes stay, and the differential is the proof rather than a claim. `GIST_NO_KILN=1` forces the comparison sort, which is also what a corpus under 4 MiB gets, where the block machinery costs more than the memory it saves; the two agree byte-for-byte on every corpus tried. `kiln_test.zig` checks the four CSR regions against an oracle written from the on-disk format — pairs collected, sorted, grouped, emitted, quadratic and obviously correct — rather than against another builder that would share the machinery under test, on corpora sized to force multi-block merging, a document larger than one block, a degenerate distribution where one group is concatenated out of every run at once, and documents too short to carry a trigram at all (which must still consume their doc id, or every later file's postings point one off).

  Two fail-closed edges came out of the 32-bit cross-check: the body's size bound can exceed the address space the posting count itself fits in, and the format counts postings in 32 bits, so a corpus past either is refused into the serial builder rather than wrapped into a short buffer or an index whose header disagrees with its own body.
- `gist index` peaks at 4067 MiB where it used to peak at 7571 MiB on the same corpus (llvm-project: 175,110 files, 1926.3 MiB), and finishes in ~7.0 s instead of ~9.4 s. `index.gist` is byte-identical, `content.shard` is identical except the build instant in its own header, and indexed answers still match live-scan answers exactly on every probe tried (up to a 15,539-file result). Three things were paying for nothing.

  The content shard was assembling a concatenation of the entire corpus in memory in order to seal it, so the build held a second full copy of every file it had just read - +1875 MiB, the largest single line item, and the format never asked for it. A seal covers bytes in order, so a rolling `signet.Scribe` reaches the identical digest through a 64 KiB window; the new `frame.Quill` (sibling `quill.zig`) is `writeAtomic`'s streaming twin, same temp-then-rename atomicity, same seal, blob never resident. The layout is now described exactly once by a private `emit`, which the streaming writer and the in-memory test encoder both drive, so a test blob is the production blob.

  The trigram build was carrying the trigram tag through its largest array for no reason. Once postings are grouped, a posting's trigram is implied by which group it sits in, so the intermediate is now doc ids alone: 141.9M postings went from 1082 MiB of `(tri, doc)` pairs to 541 MiB of `u32`. The same sweep that prefix-sums the 24-bit histogram into write cursors now also reads off the distinct trigrams and their group sizes, which means the CSR directory is sized by the 661,572 distinct trigrams instead of by the 141.9M postings - it was reserving 1.6 GiB of address space to hold 7.6 MiB of answer. Each shard's pair buffer is released the instant it has been drained, so the pair table and the doc array never both stand at full size. Net: -490 MiB and 7 billion fewer instructions retired.

  Corpus contiguity is now the caller's choice (`corpus.Layout`), not an unconditional step. `compact`'s one-blob copy buys the prefetcher's ramp across document boundaries for every later scan, which is worth its transient 2x for a resident session that scans the same corpus indefinitely and worth nothing to a build that reads each body a fixed twice and drops it. Measured on llvm-project, `.scattered` loads ~1.0 s faster, finishes ~1.2 s faster overall, and peaks 1027 MiB lower. The resident session, `relate`, `irregex blast`, and the benches all stay `.contiguous`.

  Also fixed while in there: when `Thread.spawn` failed partway through the parallel extraction, the assembler was told to consider only the shards that had been spawned, silently dropping every posting from the shards it had just run inline. A candidate filter that omits postings answers false negatives, which is the one failure mode this tier is not allowed to have.
- `irgx_abi_version` is 2. Three things a caller had to work around are now
  just answered, and two of them change what a v1 host would read.

  **A fault's offset says which string it indexes.** `at` is a byte in a file for
  a corpus fault and a byte in the pattern for a refused compile - two rulers, one
  field, and which one was in force had to be inferred from `path` coming back
  NULL. So every binding wrote the same three-clause conjunction, and any binding
  that missed a clause pointed a caret at the wrong string. `has_at` is now
  `at_space`, holding `IRGX_AT_NONE` / `AT_FILE` / `AT_PATTERN` - the boolean
  widened in place, same offset and width, so `struct_size` cannot catch the
  difference and the version gate is what has to. `AT_NONE` is 0 so a reader that
  only wanted "is there a position at all" still gets it from a zero test.

  **`find_all` counts what the text holds, not what fit.** Its sibling
  `captures` already reported the needed group count on a short buffer, which is
  what lets a caller size one retry. `find_all` reported the written count, where
  `written == cap` is equally a full window and an exact fit - undecidable, so all
  three bindings independently grew a buffer and searched again until a call came
  back short. It now reports the total either way, `cap = 0` with a NULL `out` is
  a cheap "how many are there", and the status is about the text rather than the
  window: a count query writes nothing and still returns `IRGX_MATCH`.

  **`irgx_group_name` tells you what group 3 is called.** There was a
  name→index lookup and no inverse, so each binding built its `groupindex` /
  `SubexpNames` / `name_table` by scanning the pattern text for `(?<...>` - three
  separate reimplementations of a parse the engine had already done, each with its
  own opinion about escapes and character classes. The engine answers now, from
  its own capture table and from PCRE2's name table when PCRE2 compiled it.
  Purely additive; it would not have bumped anything on its own.
- `portal.map` is a real demand-paged mapping on Windows now, not an eager copy.

  It was `VirtualAlloc` plus a whole-file read loop: the interface survived (a
  page-aligned read-only view whose lifetime is independent of the handle) and the
  property the interface exists for did not. A scan got no lazy fault-in, a sharded
  scan could not fault its ranges in parallel, and a query that stops at its first
  match a few pages in still paid for the whole file. It is now an NT section over
  the file (`NtCreateSection` + `NtMapViewOfSection`) with the section handle
  dropped immediately — a mapped view holds its own reference, so `Mapping` stays a
  plain slice and no caller has to carry a handle to `unmap`.

  Naming the section size instead of passing null makes this arm the *safer* of the
  two, not merely the equal: a read-only section may not exceed its file, so a file
  that shrank between the caller's `stat` and the map fails to create and the
  caller takes its copying fallback. POSIX cannot express that — it maps what it
  can and delivers SIGBUS on the vanished pages.

  `advise`'s `will_need` now lands on `PrefetchVirtualMemory`, which is the same
  instruction `MADV_WILLNEED` gives a POSIX pager: start the fault-in in bulk
  rather than one page-cluster per access fault. That is where the measured win in
  `slurp.mapWhole` came from, so it is the hint that ports. `sequential` still
  declines rather than being faked — NT spells that expectation as a flag on the
  *open*, decided before this seam sees a handle, and prefetching the whole range
  to pretend otherwise would quietly reintroduce the eager read.

  Measured on a 10,936-file tree, `x86_64-windows-gnu` under Wine, best of five:

  | lane | before | after | |
  |---|---|---|---|
  | indexed `-c WalletService` | 1519 ms | 987 ms | 1.54× |
  | indexed `-c` (no match) | 1519 ms | 1049 ms | 1.45× |
  | `index` rebuild | 984 ms | 533 ms | 1.85× |
  | cold walk, no index | 1014 ms | 983 ms | parity |

  The indexed rows carry the batched-directory-metadata change in the same
  measurement — the two land together because they are the same cost. Wine's Win32
  is a reimplementation, so treat these as the shape of the win rather than the
  native magnitude; the correctness claim beside them is exact, both Windows rows
  of `bench/conformance/targets` still coming back byte-identical to the
  ripgrep-pinned native oracle across all twelve probe classes on 64- and 32-bit.

  The cold-walk row is why `bulkstat.names_undercut_iterator` exists. On Windows
  `std.Io.Dir.Iterator` is *already* `NtQueryDirectoryFile`, so routing names alone
  through the batched drain bought an owned array and a copy for a syscall the
  iterator makes for free — measurably 3–6% worse. "Can this platform batch a
  listing" and "is batching cheaper than its own iterator here" turned out to be
  two questions, and the walk asks the second one.

### Removed

- `python/` is deleted. It was the pre-split placeholder that reserved the name on PyPI: a dependency-free subprocess wrapper (`executable()` / `run()` / `records()`) that shelled out to an installed `irregex` CLI. Two things retired it. The real binding is `bindings/python/`, which is ctypes over the bundled C ABI and needs no binary on `PATH` at all; and the CLI it wrapped is no longer this package's — after the split, the composed face is `blast`, so the shim shelled to a name that means something else now.

  Keeping it was a live hazard rather than dead weight: the repo carried two distributions both named `irregex`, one at `python/` and one at `bindings/python/`, so a publish from the wrong directory would have shipped the 0.1.0 subprocess stub over the 0.2.0 engine. Nothing referenced it — no workflow, no import, and the only `IRGX_BIN` readers left are in the monorepo copy that is itself slated for removal.

### Fixed

- A `--json` stream cut short by the agent-output ceiling now says so in the record
  stream, instead of just ending early.

  The soft ~25k-token cap is one of the deliberate places gist diverges from
  ripgrep, and for a human it's loud: the moment it fires, stderr carries the
  `output truncated at` line plus the `-l` / `-c` / `--uncap` follow-ups. But the
  protocol's terminator - the trailing `summary` record - was written through the
  same budgeted seam as the match rows, and it's written *last*, so it was the
  first record a spent budget refused. A capped run therefore ended on an `end`
  record, exit 0, no `summary`. An agent doing `gist --json pat > out.json` and
  reading stdout back got a short stream with nothing in it to say so, and no way
  to tell a truncated answer from a crashed one. That's the same failure the stream
  contract already guards for `-l` captures, one format over.

  Two changes. The terminator is written past the ceiling rather than through it,
  because it's bounded metadata (one record, a few hundred bytes) rather than a
  result row, which is the argument the chrome discount already makes for escapes
  nobody reads - and going past keeps the *rows* cut in exactly the same place,
  where reserving headroom would have moved every capped run's boundary. And when
  the run was cut, the record carries `"truncated":true`, so a consumer reading
  `matches` off it knows the tally describes a prefix.

  That field only ever appears in a case ripgrep can't produce, since ripgrep has
  no ceiling; an uncut run is byte-for-byte what it was, which the 411-test rg
  suite and a byte-exact `--json` diff both confirm. The flag is read from the
  budget inside the emitter rather than threaded in from its four callers, since by
  the time any of them reaches the terminator the cut is already decided, so a
  parameter could only ever disagree.

  The stream contract gate now asserts all of it on both engines: capped runs
  terminate on a flagged summary with every record still whole, and an uncut run
  carries no such field. It caught its own first draft passing vacuously, because
  the timing harness exports `GIST_UNCAP=1` and uncap outranks an explicit token
  budget.

  Worth saying what this was not: I went in expecting a match-dropping bug, after
  `gist -o` tree-wide reported 4,387 rows where ripgrep reported 680,661. That was
  the cap doing its job, and my own `2>/dev/null` throwing away the sentence
  explaining it. With `--uncap` the two are byte-identical, sorted, tree-wide.
- A `--type-add` type named with `-t` no longer cancels every other `-t` beside
  it. `-t` is a union; one custom name was turning it into an intersection.

  `--type-add 'tsx:*.tsx' -t go -t tsx` over a mixed tree returned 453 files, all
  of them `.tsx`. ripgrep returns 1,082 for the same line: 629 `.go` plus those
  453. Nothing errored and no flag was rejected, so the only symptom was a
  smaller answer than the one you asked for; that is the failure a search tool is
  least allowed to have. A five-type line (`-t go -t py -t rust -t ts -t tsx`)
  found 3 files where rg found 168.

  The cause is which bucket a custom type landed in. `PathFilter` keeps two
  positive dimensions and ANDs them: `exts` is the union of every `-t` type's
  globs, `includes` is the `-g` glob set. `Builder.addType` sent a built-in name
  to `exts` and a `--type-add` name to `includes`, so the two ANDed and a `.go`
  file could satisfy the type half but not the glob half. It only showed up in
  the MIX, which is why it lasted: built-ins union with built-ins correctly, and
  a custom type on its own matches rg exactly. The genus branch three lines above
  already had the rule written down - a widened genus joins `exts`, "so they add
  to the selection instead of becoming an override that decides alone" - the
  plain custom-type branch just never got it.

  It fixes a second, quieter divergence at the same time. `-t` may un-hide a
  dotfile but must never un-ignore a gitignored leaf; only `-g` does that
  (`filter.surfacesHidden`, and rg's own rule). While custom types lived in the
  `-g` set they were un-ignoring too.

  The gate is `bench/conformance/gates/parity/type_union_parity.sh` in the gist
  repo, with rg as the oracle over a corpus it synthesizes so the cases can't go
  vacuous in a checkout that happens to be single-language. Reverting this one
  line breaks 5 of its invariants.
- A file the macOS watcher could not open was counted as covered. `budget.zig`
  clamps the watch set against the ceilings Darwin enforces so registration
  declines up front rather than meeting `EMFILE` partway through — but that clamp
  is a prediction over a commons several daemons share, and a sibling arming in
  between spends the room it counted; an unreadable mode refuses the same call for
  its own reasons. In either case the walk still admitted and still searched the
  path, now with no delivery on it, so the session armed exact, the annals went on
  vouching an epoch that had never counted its edits, and a held answer could
  outlive the bytes it described. `coverage.zig` now judges the errno: only a path
  that VANISHED between listing and open may be skipped (nothing left to watch,
  and its parent names it again if it returns), while every other failure leaves
  the session unarmed on the reconcile-always baseline. `kqueue_test.zig` stages
  an unopenable file against a control tree that must arm without it, so the case
  cannot pass by never arming at all.
- A refused pattern now tells you whether a flag fixes it, and if not, where it
  went wrong.

  `(?=x)` is one flag away from working. `[abc` is just broken. Both used to come
  back as `IRGX_INVALID` with the fault name `Unsupported` and no position -
  one byte-identical answer for two problems, only one of which has a remedy. No
  binding could suggest `pcre` because no binding could tell them apart.

  `[fault_domains]` had already drawn the line and named both channels:
  `Unsupported` is "a declinature while PCRE2 can still answer it, a fault once
  PCRE2 has refused", and `BadPattern` is "the grammar itself rejects it, so no
  slower engine could answer it either". The seam just wasn't honoring it, because
  the kernel can't tell the two apart - its parser returns one `BadPattern` for
  both and the query layer folds that to `Unsupported`.

  So ask the authority. PCRE2 is definitionally the judge of what PCRE2 can
  express; a construct list kept in the seam would drift the first time PCRE2 grew
  one. It costs a second compile on a path that already failed. Now:

  - PCRE2 takes it, so the answer is `IRGX_STALE` - the routing fact, not an
    error. That is exactly `unsupported_syntax`, whose declared fallback *is*
    pcre2; `--engine auto` escalates across the same seam in the CLI, and here you
    escalate by setting `IRGX_PCRE`. Per the seam's own law a declinature never
    installs a fault, so this is decidable from the return value alone - no second
    call, and nothing anywhere has to compare a fault name as a string.
  - PCRE2 refuses it too, so it is `BadPattern`, carrying PCRE2's own error offset
    as a byte index into the pattern (`path` NULL, `at_space` `AT_PATTERN`).
  - There is no PCRE2 to escalate to - a build without it - so it stays the
    `Unsupported` fault. A tier that does not exist has refused, which is the
    moment the declinature above becomes the fault.

  No signature moved and no struct grew.
- A resident daemon started from a content-addressed build artifact no longer
  strands the warm tier. Retirement on build skew used to rest entirely on a
  daemon noticing its own executable had been rewritten, which a cache-path
  binary can never observe — the path embeds a hash of its own bytes, so they
  never change. Such a daemon held the socket for the rest of the day: every
  rebuilt client detected the skew, declined, and ran cold, and the idle TTL
  wants ten *continuous* quiet minutes that a tree ~10 coworker agents query
  never gets. Measured on one machine: 10 orphaned daemons resident at once, and
  every eligible query paying the full corpus walk — 60-160 ms where the daemon
  beside it answers in 0-20 ms.

  Build skew now settles with a tiebreak over the two stamps (`image.hosts`).
  It claims no recency — a stamp is still an identity and not an order — only
  that both peers compute the same winner from the same pair, so exactly one
  build hosts the rendezvous and two live builds can never take turns evicting
  each other. The loser stays cold exactly as it did before, so the worst case is
  the previous behavior, while a fresh install against a stale orphan gets the
  socket back after a single cold query.
- A stage-1 `-l` match proof no longer reaches past the last terminator ripgrep committed. A NUL-free 64 KiB prefix is not the same thing as a SEARCHED prefix: rg's line-mode reader commits only up to the last `\n` it has read, and the fill holding the first NUL is discarded whole, so a file whose first newline lands AFTER its first NUL commits zero bytes and matches nothing. `prefixProvesMatch`'s regex arm already bounded itself to that terminator; its pure-literal `lits_equiv` arm scanned the raw prefix, so `gist -uu -l dog` published two 155 KB ruff-cache blobs that `rg -uu -l dog` reports no match for (`--stats` agreed at `0 bytes searched`). The bound is now shared by all three arms, which also tightens a `-U` run whose pattern cannot match `\n` — line-model binary geometry, previously proven over the raw prefix. Found by the `--rank` set-parity invariant.
- A zero-match `gist --no-index -uu` over an 11 GiB tree held **274 MiB** of resident set. It now holds **~54 MiB**, against ripgrep's 34 MiB on the identical query — and it is very slightly *faster* for it (6.32 s ± 0.33 against 6.75 s ± 0.39 over six runs each). Answers are unchanged: order-insensitive md5 parity against live rg holds on every mode probed (default, `-i`, `-c`, `-l`, `-n --no-heading`) for literals and a class-repetition regex alike.

  The certificate had this as **6.0x ripgrep on owned memory** and called it "unattributed overhead in gist's walk path", which was the honest label for a number nobody had localized. It was two separate things wearing one number. The first was per-directory path allocations surviving in worker arenas, fixed already. The rest was this: a file past the read scratch cap is **memory-mapped** rather than slurped — the right call, it is what ripgrep does and it saves a 2x copy on a multi-GB blob — and nothing ever dropped the view. The comment said so plainly ("the mapping is never munmapped — both walk engines are one-shot processes"), and one-shot is true, so the leak was sound. It was also 274 MiB of live mapping on a tree with 289 files over 4 MiB, which means the resident set was tracking **the corpus** rather than the query. Clean, evictable page cache, yes. Still not a number I want to hand ripgrep.

  The fix is about lifetime, not about mmap. `slurp.readTail` now returns the mapping beside the bytes instead of laundering it into a plain slice, so the decision belongs to whoever knows the body's lifetime. In the parallel walk each worker renders a file into its own arena and `deliver` holds only that rendering, so the frame that read the file is exactly where the last reference dies — one `defer` per read path, and a walk holds one map per worker instead of every large file it ever touched. The serial path additionally drops a mapping the moment the required-literal gate proves the file cannot match, which is the same reasoning one step earlier. Callers that hand a body onward still keep their map, which is why the mapping is a return value rather than something `close()` guesses at.

  **The number is now measured rather than typed in**, which is the part that would have failed twice. Layer J's matched pair was two figures in a paragraph, so the fix invalidated the certificate silently and the certificate went on quoting the pre-fix number. `bench/rungs/sliver/walkcost.py` takes the pair — same needle, same `-uu` scope, same cwd, both counting, both a fresh process with no index and no daemon, so the only difference left is the implementation of walking — and Layer J renders `scale_walkcost.tsv`, ratios derived. An absent measurement now reads as absent instead of as the last one anybody took.
- An AArch64 target without NEON now builds. It did not, and the failure was a
  hard compile error rather than a slow path.

  `lanes.native` is the gate that decides whether to arm the 32-lane composition,
  and it read `switch (builtin.cpu.arch) { .aarch64, .aarch64_be => true, else =>
  false }`. NEON is an optional AArch64 feature, not a guaranteed one. So on any
  profile without SIMD the gate said yes, `run` dispatched to `runNative`,
  `Algebra.compose` reached `shufflePair`, and that function's own
  `@compileError` - "lanes.shufflePair is NEON-only - callers gate on `native`" -
  ended the build. Nothing shipped for that target. `zig build
  -Dtarget=aarch64-linux-gnu -Dcpu=baseline-neon` reproduces it exactly.

  The leaf stated its requirement in the feature's terms and the gate in front of
  it answered in the architecture's, which is the same mistake the `isa-floor`
  ratchet exists to stop one level down, in the `asm` blocks. A ratchet that reads
  asm templates cannot see a boolean derived from the wrong question. So the gate
  now asks the same question the leaf does: `builtin.cpu.has(.aarch64, .neon)`.

  Big-endian was never affected - `cpu.has(.aarch64, .neon)` is true on
  `aarch64_be`, so the arm the old switch reached for by name it now reaches by
  capability, and that target builds before and after. x86_64 at baseline was not
  affected either; its 16-lane shuffle has a portable arm to fall back to, where
  the 32-lane one has none.

  `zig build check-portable` is the new step that keeps it fixed, and it fails
  with the original error the moment the arch-shaped predicate comes back.
- An event the macOS kqueue backend could not attribute to a watch — an
  `EV_ERROR`, or a `udata` indexing no live slot — raised doubt in the dirty log
  alone, leaving the annals ledger vouching a change epoch it had never counted
  that event into. A reconcile's full walk protects the QUERY, which re-derives
  its answer from the tree; an answer already HELD is trusted purely on the epoch
  standing still, so the resident keep could serve a stale answer across such an
  event and a one-shot `gist index` amend could read a path set missing the file
  behind it. Both backends now route an unplaceable delivery through one shared
  `Watcher.noteUnattributable`, which loses the WHICH permanently (no walk exists
  in the ledger to re-derive a lost path) and still counts the WHETHER, so a held
  answer retires. `vouch_test.zig` grades it through the keep on whichever exact
  backend the platform ships.
- An explicitly named hidden or gitignored PATH (`gist needle .circleci`, `gist needle ign/`) returned nothing on the warm path while `--no-index` and ripgrep both answered — acceleration was changing results, not just speed. Cold exempts a root you name from the hidden and ignore rules (rg parity, via `Ignore.scopeToRoot`), but the resident mirror is the whole-tree default walk that pruned that directory, and a pruned directory leaves no `Extra` behind to reveal the gap. The request classifier now declines a root with a hidden segment, and `guardExtras` declines any root the mirror holds no file under, so both fall through to the certified cold path.
- Bounding what a resident daemon may hold stopped gist compiling for every 32-bit
  target.

  Two things in the new warden are 64-bit by declaration and can't be on a 32-bit
  machine. The ration is a `u64` count of bytes the machine will lend, handed
  straight to an allocator that takes a `usize` - and the resident ceiling is 4 GiB
  *exactly*, which is one byte past what a 32-bit `usize` holds (the
  `GIST_MEMORY_MB` override is unbounded outright). And the two diagnostic counters
  were `std.atomic.Value(u64)`, which has no lock-free instruction on i386 or ARM32,
  so it's a compile error there rather than a slow path.

  So `ration.addressable()` now narrows the machine fact to what the process can
  address, once, in the policy that owns the number - `standdown` still compares the
  unnarrowed one, because what this daemon can address says nothing about what
  another already holds - and `refusals`/`relieved` are one machine word each like
  `held` and `crest`, still reported as `u64` so the reported shape doesn't depend
  on the word size it was counted in.

  Found by the portability sweep, which is the point of having one: all five 32-bit
  rows (three ARM32 ABIs, two x86-32) had gone from `conforms` with 12/12 probe
  classes byte-identical to `unbuilt`, and nothing else noticed, because every host
  that runs the test suite is 64-bit. They conform again.
- Corrected what the freshness walk actually spends its time on. The note in `sheaf.zig` told the next reader that "attaching mtime + ctime to every entry" was the cold walk's cost, quoting 9.0 ms wall / 10.6 ms system without clocks against 37.2 / 166.9 with them, and closed by saying to spend effort on the clock surcharge. That is wrong, and it was wrong in the expensive direction: it aimed anyone optimizing the cold path at a surcharge that turns out to be about 1%.

  Priced properly - by attribute set, over a 162k-entry tree, min-of-7 with the variants interleaved so a slow stretch of machine time cannot land on one of them - `getattrlistbulk` costs 2.94 us/entry for names+kind alone, 2.93 with MODTIME, 3.02 with CHGTIME, and 2.96 with both. That spread is noise, and both-clocks came in faster than mtime-alone on one run of three. The timestamps ride the inode record the call has already fetched, so there is no second clock to save and dropping one buys nothing. Using minimum rather than mean is the whole reason these numbers hold on a box under load average 11: a competing process can only make a sample slower, so the minimum converges on the real cost from above instead of drifting.

  The cost is asking `getattrlistbulk` at all rather than the cheap `getdirentries` drain sitting next to it - 2.96 vs 2.00 us per comparable entry, 1.48x, and that ratio does not move with the attribute set. So the walk's price is set by how many entries it enumerates, not by what it asks about each one, which makes `phantom_stat_budget` the lever and the attribute list a dead end. The original 9.0 -> 37.2 ms figure came from single wall-clock runs on the same loaded machine that produced the 32 KiB buffer "win" this file already records as noise; it does not reproduce.

  Re-measured the head-to-head the same load-robust way while I was in here, since the previous numbers came from the same contaminated runs. On minimum of 25: the default resident path answers in 1.9 ms against csearch's 27.5 ms, 14.5x faster, with a standard deviation of 0.3 ms against csearch's 18.9 - and that answer is md5-identical to a cold `--no-index` full read, so it is live, not stale. Cold with the resident session disabled was 40.0 ms against 23.8, and the composition says why: 195 ms of system time against csearch's 17.1. That is the corpus-wide freshness proof, which csearch does not perform at all.

  Then took the lever the re-attribution points at, because "cut entries visited" turned out to have something sitting in it. `phantom_stat_budget` decides how many admitted files a snapshot-served directory may carry before listing it live is cheaper, and it was derived by counting syscalls: a listing is three, the probing `lstat` spends one, so two are left for files. That prices a listing as three fixed calls, but `getattrlistbulk` resolves attributes for every entry in the directory, so a listing's real cost scales with the directory's width - and the count undercounted by about 3x. Measured from the primitives, a path-resolving `lstat` costs 1.6-2.7 us against 1.9-2.7 us for one listed entry, putting break-even at 6.1 to 8.8 admitted files across four corpora. An end-to-end cap sweep agrees and finds the knee exactly there: 1 -> 46.1 ms, 2 -> 39.6, 3 -> 35.4, 4 -> 32.2, 6 -> 30.1, 8 -> 30.2, 12 -> 30.2. So the budget is now 6, worth 1.18-1.38x on the cold path across six query shapes times `-l`/`-n`, with output md5-identical to the old constant and to a `--no-index` full read on every one, and all three gates (phantom parity, elision parity, fail-closed) green - the phantom gate is the one that matters here, since it proves byte-exact equality across both the served and the declined branch and this change moves directories between them.

  How much that is worth depends on the tree, and the honest number is two numbers. The same sweep over llvm-project's 175k indexed files lands inside noise at every cap from 1 to 16 (0.85-1.16x, 6 at 0.96-1.08x), because the win needs directories holding 3-6 admitted files - the band the old constant excluded - and a corpus whose directories are each 10-50 source files exceeds any small cap either way. A tree of mostly generated and ignored siblings has many such directories; llvm has few. Clear win on one real corpus, neutral on the other, so it ships as a constant rather than a fitted curve.

  One refinement was tried and measured worse, recorded so it is not re-attempted: gating on directory width instead of a flat count - serve only when `1 + admitted < kids.len`, which is what the primitive costs literally imply - cost 0.82-0.84x across five queries. A served entry resolves its path from CWD through every component and allocates the join, where a listed entry rides an already-open dirfd, and that asymmetry is absent from the primitive model. Cold is now roughly 1.5x behind csearch rather than 1.7x. Closing the rest needs a freshness oracle sublinear in corpus size, and FSEvents - the only OS-level aggregate on offer here - is already recorded as unusable at 152-855 ms.
- Crest sieve: derive the forced crest `ĝ` from the engine's own AST instead of a
  private mini-parser inside the kernel. The two grammars disagreed on zero-width
  assertions — `\<` and `\>` were read as escaped literal `<`/`>` — so `\<foo\>`
  demanded a punct run and silently elided files that matched (700 of 2 200 files
  returned on the reproduction corpus). The calculus now lives in
  `kernel/regex/analysis/swell.zig` and consumes the `syntax.Node` tree the matcher
  compiles, through one shared `parse()`, so there is no second grammar to diverge
  from; PCRE2 patterns disable the sieve rather than being approximated. Constructs
  the old parser declined (`\x41`, malformed bounds) now certify correctly.
  `swell_test.zig` asserts the Sieve Theorem against the real matcher over 1 500
  generated patterns spanning every node kind × both engine modes × caseless.
- Every CI job now checks out one repository: this one. The Python, Go and Rust
  suites all reached sideways into a sibling clone before, so a public library's
  tests could not be run by the public.

  Three separate reaches, one cause. The Python cffi mirror declared `gist_open`,
  `gist_search`, the cursor family and all three `<face>_run` producers, so its
  header-parity gate needed gist.h, relate.h and blast.h to check them; those
  declarations belong to the libraries that export them and now travel with them,
  leaving this mirror to answer to `include/irgx.h` alone. The Rust crate mirrored
  gist's published names and tool boundary, whose parity test read gist's
  `contract/surface.toml`; both are in `gist::contract` now, next to the contract.
  The Go ladder's `TestMain` refused to run the package without a producer binary,
  and this repository builds none, so the binary it asked for was gist's.

  The tests that genuinely need a child moved to the repositories that build one:
  the row-and-stats comparison to gist's `exact`, the span oracle against
  `gist --json` to gist's Python suite, the kinship oracle to relate's bindings.
  What is left here is the ladder's own reasoning, which spawns nothing.

  The path resolvers lost their sibling fallback with the tests that wanted it. A
  gate that can satisfy itself from whatever happens to be cloned next to it is a
  gate on the neighbor, and relate's `kinship.toml` is vendored here anyway.
- Every parallel stage in the kernel sized itself from `std.Thread.getCpuCount()`,
  which on Windows reads the PEB's *primary processor group* and stops there — so a
  box with more than 64 logical processors was silently indexed, scanned, ranked and
  sketched at a fraction of its width, and the shortfall grew with the machine. That
  is the one class of Windows gap a benchmark on a small runner cannot see: nothing
  fails, the work just runs narrow.

  `portal.cpuCount()` is the seam that answers honestly, and all 22 call sites now
  ask it instead. Rather than sniff a build number, it asks about *this process*:
  before Windows 11 a process is confined to one group, so the primary count is
  already right and the all-groups total would overcount; from Windows 11 /
  Server 2022 a process spans every group by default. `GetProcessGroupAffinity`
  distinguishes those two without naming a version, and only then does
  `GetActiveProcessorCount(ALL_PROCESSOR_GROUPS)` replace the answer. It fails open
  in both directions — a refused query or a nonsense zero lands back on std's count
  — so the worst case is exactly the behavior this had before, and off Windows it is
  the same call it always was.
- Every published x86_64 artifact - the `manylinux_2_17_x86_64` wheel, the
  `win_amd64` DLL, the `macosx_11_0_x86_64` dylib - contained 55 `pshufb`
  instructions under a declared floor of generic x86_64. `pshufb` is SSSE3.
  Generic x86_64 is SSE2. So the tag promised one thing and the bytes needed
  another, and the machines that would have found out are the old AMD parts the
  tag was widest for.

  LLVM did not miss it; LLVM was never asked. It checks every instruction *it*
  selects against the subtarget and checks nothing inside an `asm` block, where
  the template is a string on its way to the assembler. The shuffles in
  `scan/lanes.zig` and `scan/classrun.zig` picked their arm with
  `switch (builtin.cpu.arch) { .x86_64 => … }`, and an architecture is not a
  feature - x86_64 has meant SSE2 and nothing more since 2003.

  Each arm now asks for the feature it actually needs, which is comptime and free
  at run time:

  ```zig
  if (comptime builtin.cpu.has(.x86, .ssse3)) return asm ("pshufb …");
  ```

  `math/bits.zig`'s NEON movemask fold and `lanes.zig`'s two-register `tbl` got the
  same treatment. Neither was live - aarch64's baseline includes NEON, so the arch
  test happened to be true wherever it was reached - but both were the same latent
  shape, and the two leaf helpers with no fallback now `@compileError` off-feature
  instead of trusting whoever calls them next.

  Then the floors got written down. The wheel matrix names a `-Dcpu` per target
  rather than inheriting Zig's default: `baseline` on aarch64, whose baseline
  already has every vector path the engine uses there, and `x86_64_v2` on x86_64,
  which is SSSE3 plus SSE4.2 plus POPCNT, is Nehalem and Bulldozer and up, and is
  the floor Red Hat picked for all of RHEL 9. It costs Core 2, whose SSE stops at
  4.1. It does not cost anything that runs the current wheel, because the current
  wheel already needs SSSE3 to survive its first shuffle.

  The wheel was not the only thing shipping. Four more channels build this engine,
  and each one had inherited a floor rather than named one:

  - The **Go module** carries a committed static archive per platform, because Go
    has no `build.rs` and a consumer cannot compile Zig at install time.
    `libirgx_linux_amd64.a` held 52 `pshufb` under a triple that promised SSE2.
  - The **Rust crate** vendors an archive per target for the same reason, and it
    is the rung a normal `cargo add` actually links.
    `vendor/x86_64-unknown-linux-gnu/libirgx.a` held the same 52.
  - `build.rs`'s **source rung** passes an explicit `-Dtarget`, which quietly opts
    out of native CPU detection - so someone compiling on their own modern box was
    getting the target's SSE2 baseline. Before this fix that produced the wrong
    instructions; after it, it would have produced the scalar fallback on hardware
    that had the real one. Both are the same missing sentence.
  - `hatch_build.py`'s **source rung** had the same shape, via `IRGX_ZIG_CPU`.

  All five now read from one rule, and the two vendored sets were rebuilt at the
  floors they now declare: 199 `pshufb` and zero `ymm` on x86_64, which is v2
  exactly - present because it is promised, and stopping where the promise does.
  Every archive still passes the link probe the vendoring scripts already ran, and
  the Go and Rust suites pass against the rebuilt bytes.

  Only two of those targets were ever wrong, which is worth saying plainly: Zig's
  default CPU for `x86_64-macos` already includes SSSE3 (every Intel Mac has it),
  while its `x86_64-linux` and `x86_64-windows` defaults do not. Depending on that
  difference is not the same as declaring it, and the macOS artifacts were correct
  by luck rather than by contract.

  Checked rather than assumed, on the real C-ABI surface at each posture: baseline
  x86_64 now emits zero SSSE3 and v2 emits 201 `pshufb`; aarch64 is untouched at
  183 `tbl` and 44 `addp`; and the whole suite passes built for `x86_64-macos` and
  run under Rosetta at *both* `baseline` and `x86_64_v2`, so the scalar fallback
  the fix newly reaches is executed and correct rather than merely compiled.

  One tier is knowingly left on the floor. At `x86_64_v3` the same surface emits
  9,841 `ymm` instructions against v2's 23k `xmm` ones - AVX2 is worth about
  double, and ripgrep gets it on every modern chip through runtime dispatch. A
  static v3 wheel would refuse to boot on anything before 2013, so the way to have
  that width is runtime dispatch over a v2 floor, and the engine does not do that
  yet. Naming it here beats it being invisible.
- Every test that builds its own directory tree now states the corpus scope it
  grades against, instead of inheriting whatever the operator's machine says is
  not part of a corpus. Fourteen of them were failing or panicking outright when
  it did. And when the resident suite does not get the warm answer it claims, it
  now fails and says which declinature fired, instead of panicking on a union
  accessor.

  The one that started it: `resident_test.zig`'s `a covered root stays warm` is
  the guard against over-declining. It writes `src/keep.zig` into a fixture under
  `/tmp` and queries with that `src` directory as an explicit root, proving the
  warm path answers a root the mirror covers rather than refusing every rooted
  query wholesale. A `<GIST_DIR>/skips.list` naming `src` prunes the fixture's own
  directory, so the root genuinely is not covered, the session correctly declines,
  and the test then reaches for `.got` on a union whose `.declined` arm is active
  and dies with `access of union field 'got' while field 'declined' is active`.
  Nothing in that message mentions a corpus, a root, or a skip list. `GIST_SKIP`
  does it too, and so does a charter `skip`, because all three feed one overlay.

  Two defects, and they want separate cures.

  The panic is the cheaper one. Every warm face returns `fault.Answer(T)`, a union
  whose other arm is a typed refusal, and forty-four sites in that file reached
  straight past it. A refusal is a legitimate answer the engine can give, so
  reaching for `.got` is not an assertion at all - it is a bet, paid out as a
  crash that names an accessor rather than the thing that happened. One helper,
  `warm`, now stands in front of all forty-four: it returns the payload, or prints
  `expected a warm answer, got declinature .freshness_unprovable` and fails. The
  tests that expect a refusal still read `.declined` outright; that arm is the
  claim they are making, and it was never the problem.

  The scope is the real one. Renaming the fixture directory is not a fix - it
  picks a name today's skips.list happens not to name - so the skip overlay got
  the same split the output budget got when `GIST_UNCAP` leaked into the two
  budget tests. `resolveSkipOverlay` returns the overlay in force, resolving
  `GIST_SKIP` + charter + `skips.list` on first ask exactly as the first walk
  always did, and that is all it does. `installSkipOverlay` binds a stated
  `SkipOverlay` and reads nothing. `stateSkipOverlay` is the two composed with the
  previous overlay handed back for restoring, because a fixture that states its
  own scope must not leave the process describing a corpus the next caller never
  asked for. Production is untouched: no shipping path calls install, so every
  walk still resolves lazily through the same `list()` it always did.

  That seam is also the thing the C ABI was missing. An embedder standing the
  engine up over a corpus it chose itself could previously only state a skip
  policy by editing the host process's environment, which is the same complaint
  `assay.install`'s `lenses: ?u32` override already answers for the trace mask.

  Verified. Before: the test panics under a `skips.list` naming `src`, under one
  naming `src lib tests docs`, and under `GIST_SKIP=src`; it passes with no
  `GIST_DIR`, an empty one, a nonexistent one, and one naming something else.
  After: all eight pass. The assertion is not weaker - point the fixture's own
  overlay at `src` and it still fails, now with the declinature named. Production
  was A/B'd by building one probe against the old and the new resolution and
  driving forty-six skip decisions plus six path decisions through twenty-four
  environments (each source alone and in every combination, an empty list, a
  missing list, a `skips.list` that is a directory, CRLF, comment and blank lines,
  a 9 KB single line, a 64-name list against the 32-name cap, and a malformed
  charter): the two outputs are the same 2602 lines, same sha256, and the probe is
  sensitive enough to tell those environments apart in ten distinct ways.

  Sweeping for the rest of the class found thirteen more, all the same shape and
  all fixed the same way: the eight cases of the exact-watch rig, its kqueue
  ignore-rule case, `vouch_test`'s one-epoch-one-corpus digest, `bulkstat`'s
  skip-dir differential, `haystack_test`'s nested-gitignore precedence, and
  `loadpar`'s serial parity - each of which writes a `sub/`, `nested/`, or
  `childdir/` and grades an oracle that still counts what the walk was told to
  prune. The whole 1101-test suite now passes under a `GIST_DIR` whose skips.list
  names twenty-two common source directory names, and under a `GIST_SKIP` naming
  the same twenty-two, where thirteen tests failed and one panicked before.
- Fixed two ripgrep-parity gaps that a 52-combo × 9-cadence differential sweep surfaced while the delivery cadence was being built.

  **`--context-separator` was honored by one render path out of four.** The `--` between non-adjacent context groups was a string literal at each site, so a custom separator, `--no-context-separator`, and `--null-data`'s NUL terminator all reached the emitter and were then ignored by the cross-file seam in the serial renderer, the parallel sink, and the daemon's facet renderer. The separator now has one owner — `Opts.groupSep()` returns the pair (separator, terminator) or nothing at all — and every path asks it. A `--null-data` run's group separators are NUL-terminated like its records, which ripgrep gets right and gist did not.

  **An empty hyperlink value turned links on instead of off.** `--hyperlink-format=` is how ripgrep says "no OSC-8 hyperlinks", and gist read the empty value as _no preference_ — the right reading for a `GIST_HYPERLINK=` standing preference in a profile, the wrong one for a flag, which then promoted it to `always` and linked every path with the default destination. An empty value written out is now the empty destination, the same thing the `none` alias already resolved to, and nowhere to point is the one destination that cannot be a link.

  **`--files-without-match` printed nothing under `--sort`.** The sorted emission arm tested two of the three modes whose record is a bare path, so asking for the complement of the match set in a deterministic order returned an empty, successful run — the worst shape a wrong answer can take. It now asks `Mode.pathPerFile()`, which is the question the arm was always trying to ask.
- Layer C published two fields that read as measurements and were not.
  `roofline.json` carried `dram_cyc_per_byte_ceiling` and `l2_cyc_per_byte_ceiling`
  unconditionally, each one the GB/s ceiling divided by a hardcoded 4.4 GHz
  whenever no counter tier opened, sitting next to a `ghz_source` sibling that said
  `assumed (no PMU)` and that no consumer had to read. `report.py` did not read it;
  it printed the figure as "derived" without saying the divisor was a guess. One of
  the published bundles is x86_64, where 4.4 GHz is not even the right guess - it
  is an Apple P-core number.

  Four options were on the table: drop the fields, rename them so the derivation
  is in the name, keep them and attach the provenance, or move measured and
  assumed inputs into visibly different places. The last one is the only one a
  future reader cannot undo, so the clock is now a `Clock` with a `measured` bool,
  and the single exit from GB/s is `Clock.cycPerByte`, which returns null on an
  assumed clock. The two ceilings moved inside an optional `derived_cyc_per_byte`
  object that carries the clock it divided by and is absent when there was none.
  The flat keys are gone rather than renamed, so a stale reader gets a `KeyError`
  instead of a stale number, and the artifact publishes `"ghz": null` rather than a
  divisor someone can reach past `measured` and multiply. A renamed field would
  have been honest for exactly as long as nobody shortened the name again.

  Then the same audit found the bigger version of it one level down. This rung's
  build posture is `.asked`, so it compiles at whatever `-Doptimize` you pass,
  which Zig defaults to Debug - and every documented invocation of it was a bare
  `zig build roofline`. Debug does not vectorize the kernel's unrolled reduction,
  so all three tiers report the same scalar issue rate. The artifact on disk read
  L1 8.0, L2 8.4, DRAM 8.3 GB/s: a flat hierarchy with L1 slower than L2, roughly
  an order of magnitude under the roof this same host records in the README, and
  well-formed JSON with a genuinely measured clock, so the derived cycles/byte
  inherited the defect honestly and looked like a result. Nothing in the numbers
  says which build produced them.

  `bench/README.md` has always said to build ReleaseFast. A standing instruction
  only the docs enforce is the shape this whole pass is closing, so the rung now
  refuses instead of publishing: unoptimized builds error out before spending a
  trial, and a tier ladder where L1 is not faster than DRAM errors out too, since a
  16 KiB working set that streams no faster than a 512 MiB one has not resolved a
  cache hierarchy whatever else it measured. A bandwidth roof is a claim about the
  machine, which is what separates it from Layer B's cycles/byte; that one is a
  claim about the build, so honoring the caller's mode is right there and wrong
  here.

  Layer B also stopped asserting a cause it could not know. It reported "kperf
  needs root" whenever no counters opened, which misread an unprivileged refusal as
  a password problem after `pmu.zig` grew an unprivileged per-thread tier; it now
  prints the meter's own note, which says which tiers were tried and why each
  declined. The dead `bench/portcert/portcert.sh` citations follow the directory to
  `bench/bounds/port/mca.sh`.

  No measured value moved, and nothing was replaced with a plausible-looking
  number. Two figures stopped existing on hosts that never earned them.
- Layer C's "production contiguous" rung published **3,029 GB/s** against the same run's measured **102 GB/s** STREAM roof. Twenty-nine times the memory bandwidth of the machine it ran on, sitting in an artifact I ship as a hardware-ceiling proof.

  The arm scans an absent needle on purpose, because a needle that is never found is the only way to make `simd.contains` sweep the whole buffer instead of returning early. The needle was the literal `Zq9_gist_roofline_absent_needle_`, written into `bandwidth.zig`. The corpus root defaults to the package, so `bandwidth.zig` is one of the corpus documents; the literal got tiled into the contiguous buffer along with everything else, and the scan found it a few hundred KiB in and returned. Every "bandwidth" number that rung ever published was the latency of an early return divided by a buffer it never read. It was not measuring a slow thing, it was measuring nothing, and it had never measured anything.

  Picking a fresh literal fixes it until the next person edits this file, so the needle is not written down any more. `absentNeedle` reads the bytes that are about to be scanned and returns 32 copies of whichever byte value has the shortest longest-run among them; a run of length N contains no run of length N+1, so absence is now a property of the corpus rather than of how I happened to spell something. It holds for the contiguous buffer and for every document individually, it survives any edit to any source file, and it is still re-checked with `simd.contains` on both before the run is allowed to publish. If all 256 values somehow carry a 32-long run it errors instead of degrading.

  With the arm actually sweeping: roof **103.3 GB/s**, matched gate control **91.1**, production contiguous **89.8**, real corpus scan **71.8**. That is a monotonic ladder for the first time, production contiguous lands at **87% of roof**, and the corpus operating point is **70%** with the gap being fragmentation and dispatch. The old claim that the gate runs near the roof survives and was never the broken arm; the number it was standing next to was.
- Layer C's matched ladder was inverted, and had been for a while. The "matched dual-window control" that exists to upper-bound the production scan measured **47.5 GB/s against production's 53.0** on aarch64, and 16.8 against 16.9 on x86_64. A control cannot come in under the thing it bounds; when it does, the ladder is not localizing a gap, it is comparing two unrelated kernels and publishing the difference as headroom.

  Four false assertions, all the same mistake - the benchmark describing production from memory instead of reading it. It declared a 16-byte stride where production runs 64, so on NEON it paid four times the loop overhead per byte. It anchored on first+last bytes, which stopped being true when the rarity table landed, so on the absent needle it filtered on a byte production never touches. It took a movemask per block, when `anyLane` exists precisely because that emulation is multi-uop on NEON. And it was unconditionally dual-window against a rare-anchored needle that production scans single-probe - a path 1.42x faster, so the control was bounding a loop production does not run. All four are recorded verbatim in `bandwidth.zig`'s header, and the control now reads its stride, anchors, gate, and promotion rule off `simd`'s published surface, so it does not get to have an opinion about any of them again.

  The denominator was wrong too. Every rung divided by a 512 MiB uniform-random buffer, which folds kernel, working-set size, and byte content into one number and calls it headroom. The ladder now runs on a corpus-sized buffer of corpus bytes with its own STREAM roof measured at that exact size, so consecutive rungs differ by exactly one thing: roof to gate is the gate's instruction cost, gate to production is verify and control flow, production to corpus is fragmentation alone. The 512 MiB tier stays where it belongs, as the cache-hierarchy datum it always actually was.

  Three attempts to speed up the dual loop itself are recorded next to it as negative results, because each one cost a day to disprove: instruction shaving at -1%, a shuffle-derived second window at -8.2%, and a single-load bitmask gate folded through `blockMask` at -14.6%, all measured under layout randomization. They fail the same way. On this core the loads are nearly free and the vector compare is the critical resource, so every trade of memory work for ALU work is a regression. The lever that is real is eligibility for the single-probe loop, and that is a question about anchors, not about the loop.
- Layer D stopped compiling. When the DFA traded its `is_match` array for a `match_hi` bound - the whole point being that a match test should be a comparison against a register-resident number rather than a second dependent load - `bench/bounds/lowerbound/audit.zig` kept indexing the array that no longer exists, and `zig build lab` failed on it. The audit's reference scan now calls `isMatch` at all three sites, which is the same test the production walk makes, on the same premultiplied row offsets it already had in hand.

  Worth saying how that fix is known to be right rather than merely green: the audit is a differential, so its reference scan's verdict is asserted equal to real `docMatch` for every document it touches. An inverted or misaligned match test would have shown up as a disagreement on the five `regex-*` classes, not as a passing build. It reports at the floor across all twelve classes and 1311 files.

  Also deleted `sieve.zig`'s `grainLen`, which lost its last caller when the worth test started lifting the decider's cost with `price.atGrain` instead of multiplying by a nominal grain length. `nominal_line` and `nominal_doc` stay - the survival curves and the sieve bench still read them.
- Layer J's build-lane verdict said **14.50 GiB peak RSS while indexing, 5.1x csearch** in a sentence, beside a table that read its numbers from `scale_build.tsv`. Firing the trigram build in blocks took that peak to **4.56 GiB** — re-measured on the same 5.5 GiB scale corpus, median of 5 — and the table moved while the sentence did not. Same failure the matched pair had, one section up: a paragraph is where a measurement goes to stop being one.

  The verdict is now derived from the rows it sits under. Wall-clock ratios come from whichever engines the file actually holds, the index-size comparison names the widest rival it finds, and the memory clause reads its own comparison instead of asserting a loss — so on the mint where gist stops losing that lane, the sentence says so rather than needing an editor. What it will not do is invent history: the 14.50 GiB it used to be lives in this fragment and in the artifact's own header, because a generator can only honestly print what this mint measured.

  The standing score on that corpus: **4.56 GiB, 1.6x csearch and 2.7x zoekt** — still the lane gist loses, and still published unnormalized. Build wall reads 26.0 s against the old row's 21.4 s, and that is the machine, not the builder: user time held at 24.8-25.1 s across all five reps while sys swung 19-41 s on a box ~10 coworker agents were also building on. csearch and zoekt keep their rows from a quieter session, so every ratio derived against them understates gist rather than flattering it.
- NOTICE now declares two bundled third-party components it had omitted: the pinned Unicode 16.0.0 Character Database under tools/ucd/ (Unicode License v3, whose full copyright and permission notice now ships beside the data as tools/ucd/LICENSE.txt) and the ripgrep-derived rgsuite oracle corpus in bench/rgsuite/spec.json (Unlicense OR MIT). The WHATWG entry now also covers encodings.json, and a closing paragraph separates bundled material from algorithms implemented from published descriptions, which stay credited at their point of use.
- No Zig package could depend on this one on Linux. `dep.artifact("irgx")`
  panicked the build runner before it compiled anything:

  ```text
  thread 2452 panic: artifact name 'irgx' is ambiguous
  ```

  Both libraries were installed as artifacts under the same name - the dynamic one
  the Python binding dlopens, and the static one Go cgo and a Rust `build.rs`
  link - and `installArtifact` is what publishes a name into the table a
  dependent's lookup searches. Two rows, one name, no way to answer.

  It failed only in the DEPENDENT and never here, so `zig build` in this
  repository was green throughout. And only on the branch macOS does not take: the
  macOS arm installs `libirgx.a` as a file already, for an unrelated ld64
  alignment reason, so a laptop never saw it. Both arms now install the archive
  the same way, leaving exactly one artifact answering to the name.
- On Windows the serial engine silently ignored your `.gitignore`, and miscounted
  `--max-depth`.

  `std.Io.Dir.Walker` joins with the platform's separator, so on Windows it hands
  back `sub\a.txt`. gist's serial walk passed that straight through to three
  consumers that all speak `/`: the gitignore protocol (a rule is *written* with
  `/`, so `sub/ignored.txt` matched nothing), `pathDepth` (which counts `/`, so
  every entry read as depth 1 and `--max-depth` stopped bounding anything), and the
  rendered output. The parallel swarm joins with `/` itself and was always correct,
  which is exactly why this survived: the two engines disagreed, and the engine the
  portability slate exercises was the right one.

  So the same query answered differently depending on which engine ran it — and the
  flags that route to serial are ordinary ones: `--files`, `-L`, `-q`, `-r`,
  `--max-filesize`, `--include-zero`, `--one-file-system`, a time-keyed `--sort`.
  Reproduced under Wine on a three-file tree: default engine returned `sub/kept.txt`
  alone, `GIST_NO_PARALLEL=1` returned `sub\ignored.txt` and `sub\kept.txt`.

  Normalized at the two seams a walker path can enter - gist's serial walk and the
  corpus `Haystack` - by one `paths.slashed`, beside the `stripDot`/`rootDepth`
  helpers whose module header already promised that per-file copies of this
  vocabulary are a parity bug by construction.

  The seam sits on the walk's hot path, so it is free where nothing needs doing: on
  a platform already spelling `/` it is comptime the identity and hands the input
  straight back, and where it must rewrite it does so in place. The walk gets its
  own buffer there (the walker lends bytes it then overwrites), and the `Haystack`
  gets none at all - it joins root and entry first, then fixes up the join's own
  buffer, which is why `joinRoot` now returns the `[]u8` it always allocated
  instead of narrowing it to const on the way out.

  That `/` render is a deliberate divergence from ripgrep, which renders the native
  separator while normalizing internally for matching. Same matching, different
  render: one spelling on every platform is what lets a captured expectation, a
  script, and an agent read identically everywhere — and it is already a *gated*
  claim, because `bench/conformance/targets` hashes Windows stdout and diffs it
  against the native oracle. Verified byte-identical against that oracle across all
  eight engine × flag combinations above, four of which the slate never reached.

  Nobody loses the native spelling by it: `--path-separator '\'` renders
  `.\sub\a.txt`, and that flag is rg's own. It also only started working on Windows
  with this change - replacing `/` in a path that already held `\` did half a job.
  So the platform default is the invariant one and the platform spelling is one flag
  away, where rg fixes the render per platform and offers the same flag to leave it.

  Wine proved the fix; it can't prove the platform. So each of these behaviors is now
  asserted on a real kernel too, in the native Windows lane
  (`.github/workflows/gist-windows.yml`) on both x64 and arm64: the `/` render, an
  ignore rule spelled through a separator, `--max-depth`'s component count,
  `--one-file-system` over a single volume, `--color=always` without a `TERM`, and
  `%LOCALAPPDATA%\gist\preferences` being found but staying out of force in a pipe.
  Contract facts over a purpose-built tree, so a concurrently edited checkout can't
  make them flaky.
- On a generic x86_64 build the quotient sieve armed a pre-pass that was slower
  than the DFA the pre-pass exists to skip.

  `sheng.resident` decides whether the sieve is worth running, and its own
  docstring says what it means: "False on targets where `lanes.shuffle` degrades
  to a scalar gather." It did not ask that. It read `switch (builtin.cpu.arch) {
  .aarch64, .aarch64_be, .x86_64 => true, else => false }`. But `lanes.shuffle`
  lowers to `pshufb` only under SSSE3, and the x86_64 baseline is SSE2 - so on any
  build that did not raise its floor, `resident` was true while the kernel
  underneath it was a sixteen-element scalar gather, per byte, in front of a DFA
  that would have been cheaper alone.

  The published wheels were not affected: they build `x86_64_v2`, which carries
  SSSE3, and that is the same floor-raising that fixed the `pshufb`-under-SSE2 bug
  earlier. What was affected is every from-source build at the default floor -
  `zig build`, a distro rebuild, anyone who took the declared baseline at its
  word.

  The predicate now names its dependency instead of guessing at it. `lanes` has
  always known which of its three arms it compiled; it just never said so out
  loud. It publishes that as `lanes.arm`, and `resident` is
  `tbl.arm != .portable` - one question, asked once, by the module that has the
  answer. There is no second derivation left to drift.
- Opening a warm engine over a repository root crashed instead of answering.

  `loadDir` remembered which directories it had loaded by the exact string it
  was handed, but buckets rules under a normalized key. The walk root is `""`
  to `init` and `"."` to a walker that names its own root, so one directory
  loaded twice and its rules landed in the `""` bucket twice. The compiled `""`
  tier borrows that bucket's slice, and the second append reallocates it, so
  every path judged afterwards read freed memory. Release builds got away with
  it because nothing had reused the block yet; any build with safety on took
  the segfault, which is what a host linking the library gets.

  Directories are now deduplicated by the same normalized key their rules are
  bucketed under, so a directory loads once however it is spelled. The tier
  also checks that it still describes the bucket it was compiled from before
  trusting it, and falls back to the linear fold if not: rules are only ever
  appended, so a length disagreement is enough to see the drift, and the two
  paths return the same verdict.
- Publishing an index generation now **retires the generations it supersedes**. `gist index` has always been generation-atomic — it stages `gens/<id>/` and flips `pair.gen` — but nothing ever spent the history that minted, so every invocation left its predecessor on disk forever. On this tree that had reached **277 generations and 8.7 GiB against a 208 MiB corpus**; the first runs carrying this change took the artifact directory from 9.5 GiB to 894 MiB and then held steady, with the index answering identically throughout.

  Retiring is safe because generations are self-contained by construction rather than by convention: a codicil publish hardlinks its base blobs _forward_ into the new directory instead of pointing at them in place, so no generation is reachable from another and the loader resolves every blob it needs inside the one directory `pair.gen` names. Removing an older sibling cannot make the live pair incomplete.

  What the policy actually guards is not correctness but the ~10 agents publishing into this tree concurrently, so a directory survives if **any one** of four independent fences holds: it is the published generation; its id is at or above the published one (a builder mints its id before it stages, so a higher id is someone's build in flight); it is younger than a grace window (an id _is_ a wall-clock nanosecond stamp, so it dates its own directory with no `stat` — this covers the case ordering misses, a build that lost the publish race and is still writing); or it is one of the `keep` most recent survivors, so a reader that resolved `pair.gen` an instant before the flip still finds what it is about to map. Underneath all four, correctness never depended on any of them: POSIX keeps an unlinked inode alive for anyone holding it mapped, and a reader that loses the race maps nothing and answers by live scan. The pass is best-effort throughout — a removal that fails is spared, never propagated into a publish.

  It is also bounded, so it cannot trade a disk problem for a latency one: the survivor window is a fixed array and at most 64 directories go per publish, which is why a deep backlog drains over several runs instead of stalling one. Both build paths flip the generation through a single function that also retires, so publication and the retention it obliges cannot drift apart, and a run that finds nothing to index retires too — that is precisely when there is time. `GIST_KEEP_GENS` tunes how much history survives (0 keeps only the live generation). Directory names are matched by round-tripping through the exact rendering a publish would mint, so a temp, a note, or anyone else's directory in `gens/` is never a candidate.
- Re-planning a literal gate on a document no longer recomputes the static anchor
  pair the gate is already carrying.

  `simd.Gate.on` is the per-file seam; `Emitter.openOn`, `json.emitOne`,
  `json.soloShard` and `verify.gateWide` all reach it once per body. It bought its
  idempotence - file N's pair must never become file N+1's incumbent - by deriving
  the incumbent through `planFor(bytes)` and deliberately ignoring `self.plan`.
  Correct, but `planFor` is `anchor.select`, which since the distance-conditioned
  joint correction costs ~21 ns on a 4-8 byte needle and ~37 ns at 32; the gate was
  minted from that same needle once per query and had the answer in a field. So
  every file in a walk paid a fifteen-pair pricing against the fitted digraph table
  to reconstruct a constant, plus two `getenv` calls - a linear walk of `environ`
  with a `strcmp` per entry - on the way to it.

  Idempotence now comes out of the type instead of out of the recomputation.
  `Gate.plan` is the effective plan and `Gate.base` remembers the static one, so the
  incumbent handed to `refineOn` is the same value on file N+1 as on file N by
  construction rather than by re-deriving it. `simd.refineOn(hay, needle, held)` is
  the seam that takes an incumbent a caller already holds; `simd.planOn` is now that
  call with `planFor` in front of it, unchanged for its own callers.
  `LiteralSet.findOn` refines against the plan `build` already put in
  `single.plan` for the same reason. `GIST_NO_CALIBRATE` is read once per process
  rather than once per document - nothing here calls `setenv`, and the A/B that knob
  exists for spawns a child per arm, so the answer cannot move under a run.

  Measured on one binary against itself, arms interleaved round-robin so a
  coworker's build lands on both: over this tree's 880 files (13.9 MiB, 16.5 KB
  mean), the gate seam plus its scan fell from 368.8 ns per file to 192.8 at a
  32-byte needle and 342.7 to 191.7 at 6 bytes, which is 1.79x and 1.67x. It now
  sits within 1.6% of the floor measured by running the same scan with no re-plan at
  all, and what remains is `calibrate.refine` declining below its own size gate at
  2.4 ns. Every arm reports the bytes it scanned and the hits it found, and all
  arms agree on both, so the speedup is not an early exit.

  Two things this is not. `Gate.base` is deliberately invisible to `in` and `find`:
  folding the choice of which field to scan with into those two - the hit-to-hit
  jump loop, entered once per MATCH - cost a measured 1.2x on `-o` and `-l` over
  this tree before it was taken back out, because trading a per-hit branch for a
  per-file `select` is the wrong direction by three orders of magnitude in call
  count. And it is not an end-to-end win: over 41 interleaved paired reps the CLI
  moves 0.97-1.05x with quartiles straddling 1.0, because the per-file cost of a
  real run is ~89 us of walk and intake against 0.19 us of scan dispatch. This
  removes work that was provably redundant; it does not move the number a user sees.

  Output is byte-identical - the pair only chooses which two offsets the block
  filter compares, and the `eql` verify is what decides a match. 411/411
  supported-surface ripgrep parity on both the parallel and serial engines, the full
  Zig suite green, and every row of the paired CLI A/B asserted identical stdout and
  exit code before it was allowed to report a ratio.
- Restored the engine-sharing guard in the Go runtime's producer lookup, so Go and Rust once again state the same invariant. `dlsym` with `RTLD_DEFAULT` searches everything the process has loaded, including libraries this module never chose; finding a symbol named `relate_run` does not establish that it speaks for *this* engine, and handing a foreign handle to a producer carrying its own statically compiled copy segfaults rather than declining. The lookup now asks the producer's own image whether it can resolve `irgx_engine_open` — `dladdr`, then `dlopen(…, RTLD_NOLOAD)`, then `dlsym` — and routes only if it can.

  The guard had been removed as dead defensive code on the grounds that every library we ship links the shared engine. That is true and stays true, which is why it lifts itself: our own producers pass it untouched. It earns its keep for producers we do not ship — these are published packages now, and the process namespace is open.

  Proven against real images in both directions: a synthesized dylib exporting `relate_run` while linking nothing is refused, and `librelate` / `libblast` / `libgist` are each admitted. `TestRoutingFollowsReachability` cannot prove that pair — with no product library loaded both its columns are false and it holds vacuously — so it now says so, and the C probe that does prove it is written down in the runtime README.
- Seven divergences from ripgrep that only a fuzzer could have found, each fixed where it was caused rather than excluded from the harness. A file the walk could not open was silently skipped, where rg names it on stderr and exits 2 — `slurp` now returns the open fault and both engines report it. `--encoding utf8` passed ill-formed bytes through, where rg replaces each ill-formed maximal subpart with U+FFFD (`encoding_rs`'s rule, matched byte-for-byte, including the one-U+FFFD-per-stray-byte case). `--field-match-separator` leaked into `-c` output, though rg documents it as "only used when printing matching lines" and a count is a summary, so `path:count` now carries its own fixed separator. `--files-without-match` combined with `-v` was mis-rendered by the fused parallel walk, which cannot answer a per-file verdict under an inverting or line-view-changing flag; that pair now routes to the serial engine, which can. Under `--stats`: `bytes printed` reported the buffer length in the summary modes where rg reports 0, `--files-without-match` printed its paths but never its stats block, and an empty file was not counted as searched. Finally `-m` was treating its cap as a demotion: a line inside the last match's after-context window that itself matches prints as a match (`:`) and counts, so `-m 1 -A 2` over three matching lines now prints three match rows and `-c -m 2 -A 2` over four reports 4 — the cap bounds how many matches anchor a window, not how the window's own lines are read.
- The CLI used to answer every pattern the linear engine declined with the same
  paragraph: *outside gist's linear-time syntax*, a list of constructs it does not
  own, and two flags to try. For `[abc` that was wrong three times over — the
  pattern contains no lookaround to blame, `-P` and `--engine auto` both fail on
  it too, and nothing said where the defect was. ripgrep names the error and
  points a caret at it.

  So the refusal now asks PCRE2 before it speaks, which is the same probe the C ABI
  already used to separate `IRGX_STALE` from a `BadPattern` fault. If PCRE2
  takes the pattern, the escalation really was the answer and the message is
  unchanged. If PCRE2 refuses it too, gist names the defect, points at the byte,
  and says that no engine here compiles it rather than sending you to a flag that
  cannot help:

  ```text
  gist: error: bad pattern — missing terminating ] for character class
  gist: note: [abc
  gist: note:     ^ here (byte 4)
  gist: note: no engine here compiles it, so -P / --engine auto cannot answer it either
  ```

  `-r/--replace` asked the same question and assumed the same answer, so it is
  fixed with it.

  One of these is a case where the advice was worse than missing: for `a\1`,
  ripgrep tells you to try `--pcre2`, and following that advice fails, because
  there is no group 1 to refer to. gist now says so up front.
- The FSEvents replay's kernel-side exclusion list is no longer a hardcoded guess. `journal.zig` asked the daemon to stop reporting a fixed set of noisy subtrees, and that set only happened to agree with what the corpus walk skips - which is the one place this accelerator could have become a correctness bug rather than a slow path. A subtree the daemon never reports is a subtree whose changes the replay cannot see, and every caller reads a successful replay as an exact account, so an exclusion the walk does _not_ also skip would make the replay a silent under-report. The names are now only a priority order (the API caps exclusions at 8, so something has to be dropped first), and each one is admitted only if `haystack.isSkipDir` - the walk's own predicate, including `GIST_SKIP` and the charter - also skips it. The guest list is therefore a proven subset of the walk's own blind spots by construction, not by coincidence.

  Also here, gated off: a corpus-wide freshness certificate (`fresh.Certificate`, `GIST_CERTIFY=1`) that tries to prove the whole tree unchanged in one journal round trip so a selective cold query can walk names-only instead of gathering every file's clocks. It stays opt-in because the measurement said no. The idea prices well exactly once - the first probe after an index build replays a zero-width window and certifies in 10.6 ms - and then falls apart, because replay cost belongs to `fseventsd` rather than to the corpus: 20 back-to-back queries measured 152.8 ms ± 304.3, and spacing them out made it worse at 855.4 ms ± 453.4 (max 1.6 s), against a ~40 ms baseline. It is kept as a measurement tool, and `fresh.moved` caches a refusal against the index anchor so a tree that genuinely moved is only charged for the discovery once.

  What the same investigation ruled out, so nobody re-derives it: the batched enumeration is not the problem (`getattrlistbulk` measured 3.39 us/file against 25.09 us/file for `readdir` + `fstatat` on the same tree, so reverting to per-file stats would be a 7.4x regression); the 8 KiB batch buffer is not the problem (a back-to-back A/B against 32 KiB came back inside the noise, 46.3 ms ± 7.4 vs 45.2 ms ± 4.1, and 64 KiB was no better again); and the six-worker ceiling is already the optimum on a 16-CPU box (2 workers 73.5 ms, 4 48.4, 5 46.3, 6 40.6, 8 43.7, 12 47.6, 16 56.9). Candidate reads cost nothing measurable at all - a query the index narrows to 580 candidates runs in 37.3 ms and one it narrows to zero runs in 37.2 ms, so the content shard is already free. The entire remaining cold-path gap is attaching mtime and ctime to every entry in the corpus: 9.0 ms wall / 10.6 ms system without clocks, 37.2 / 166.9 with them.
- The Go binary resolver ascended from the working directory looking for two
  things: `zig-out/bin/<name>`, and that same path nested under the kernel bucket
  of the monorepo these four packages were extracted from. The second can never
  resolve here - a dead rung, and one an earlier scrub missed.

  What it never had is the rung that matters now. The packages are flat siblings,
  so a process running in `irregex` that wants `relate` is looking at
  `../relate/zig-out/bin/relate`, and nothing on the ladder could see it.
  `Binary` fell through to PATH, found nothing, and four Go tests across two repos
  skipped themselves: `TestTiersAgree` and `TestColdSurfacesStats` here,
  `TestContextPicksOnlyMatchingFiles` and `TestFamilyNarrowsToMatching` in blast.
  The Python binding has had the sibling rung all along, which is why its suite ran
  everything while Go's quietly ran less.

  The ladder is now Python's `_locate_root`, spelled in Go: the env override, a
  built `zig-out/bin/<name>` anywhere up the tree, then the sibling checkout that
  owns the name - believed only when it carries the `build.zig` that makes it that
  package rather than a directory sharing its name - then PATH. Own build ahead of
  sibling on purpose: the checkout you are standing in is the one you just
  rebuilt, and a sibling's `zig-out` may hold something older. No rung dates what
  it finds, so pin an exact build with the env override when the difference
  matters.

  A failure now names every path it looked at, in order, instead of listing three
  things you could try. That is the whole reason this took two investigations to
  find.
- The Go runtime's child tier reported a signaled process as `exited -1`, which both invents an exit code a signaled process does not have and hides the one fact worth knowing: something outside the engine killed it, and there is no output because it never got to speak. It now names the signal — `killed by segmentation fault (no output; the engine did not fault)`.

  This was not cosmetic. An intermittent `gist status: exited -1` in the index lifecycle tests had been written off as machine noise; the first run under the new wording named it a **segmentation fault**, and the crash report puts it in `readGenerationFile` → `Io.Dir.readFileAlloc` under `status`. A diagnostic that misattributes a crash to the engine's exit code buys silence, not stability.
- The Python substrate's cffi mirror still named the engine `gist_engine_open`
  after the engine moved down here as `irgx_engine_open`, so every in-process
  call through it raised `AttributeError` on a symbol libgist has never exported.
  Nothing caught it because cffi resolves an ABI-mode symbol lazily and the tier
  that would have made the call was skipping for want of `cffi` in a standalone
  checkout — a rename hiding behind a dark test plane.

  The mirror now spells the engine, cancel token and all three `…_run` producers
  the way the headers do, and a new gate compares the two texts directly: every
  function the mirror declares must be declared by a reachable header with the
  same return type and the same parameter types, names ignored. It fails closed
  naming the header it wanted, since a mirror checked against a header that isn't
  there is not checked at all. Proven by mutation on four axes — the pre-move
  spelling, a wrong engine type in a parameter, a wrong return type, and that
  renaming a *parameter* is correctly ignored.

  Two smaller repairs alongside it. `_resolve_lib` now finds a package's shared
  library in that package's own tree, the same ancestor-then-sibling rule
  `_locate_root` already used for binaries; it had a special case withholding
  exactly that hop from `gist`, which made sense when the loader lived in gist and
  was backwards once it became substrate here. And the wrong-library refusal test
  discovers a stand-in extension module from the interpreter's own search paths
  instead of assuming `_ctypes` is a separate file — it is statically linked on the
  CPython builds uv ships, so the test could not run there at all.
- The Rust binding's binary lookup could not answer for two of the three faces it
  is supposed to serve. Asking it for `relate` from inside blast, or from inside
  relate itself, was structurally unanswerable.

  Three separate problems, one line each. It looked at `PATH` before the local
  checkout, the opposite precedence from the Python and Go bindings, so a worktree
  you had just rebuilt lost to whatever was installed globally. It had no sibling
  rung at all, where the other two both know the four packages sit flat beside each
  other. And its one checkout rung was
  `env!("CARGO_MANIFEST_DIR").join("../../zig-out/bin")`, which is worse than a
  brittle depth guess: `env!` expands where it is written, so that path is *this*
  crate's directory even when relate or blast is the consumer. It could only ever
  describe irregex's tree, and irregex does not build the product binaries. The
  rung had never answered for anything but `gist`, and nothing noticed because
  blast's Rust tests are builder smoke that opens no child.

  It now runs the same ladder Python and Go run: env override, an already-built
  `zig-out/bin/<name>` anywhere up the chain, the sibling checkout that owns the
  name and carries its own `build.zig`, then `PATH`. The walk climbs from the
  working directory first, which is the runtime truth and what Go already uses, and
  from `CARGO_MANIFEST_DIR` second, for a host that has chdir'd away from its
  checkout.

  Checkout-before-`PATH` is not a regression for a crates.io consumer, which was
  the one reading under which the old order made sense. The crate ships a vendored
  static archive and needs no checkout, and a registry source directory holds no
  `zig-out` and no `build.zig` - so the whole ladder self-disables there and falls
  through to `PATH` on its own, without a mode flag deciding which situation it is
  in. The order is only observable when both rungs *can* answer, which is exactly
  the developer-in-a-workspace case, and that is the case checkout-first is for.

  Nothing here builds. Python will run `zig build` as an in-repo last resort; a
  `cargo test` that silently spends ten minutes in the Zig compiler is a worse
  surprise than a legible failure, which is the call Go already made.

  A miss now names every path it tried, in order, the way Go's does, because a
  resolver that fails without saying where it looked is how the same dead rung got
  investigated twice. `Error::NotFound` also stopped prefixing every failure with
  "gist binary not found" while the body underneath said `relate`.
- The Windows static archive builds, so `libirgx.a` ships on all five targets.

  `libirgx.a` is meant to link standing alone - carrying PCRE2 and libsais rather than naming them and leaving a cgo or `build.rs` consumer to hunt down two more archives this package does not install. Everywhere with a partial link that is bought by packing a partially-linked object, which pulls the C floor in. COFF has no partial link: handed the two floor archives, `zig build-obj` refuses with "coff does not support linking multiple objects into one", and the Windows wheel never built.

  But an archive is a bag of members, and the property wanted is about what is in the bag. So Windows splices instead of merging: `zig ar qcsL` adds an input archive's contents rather than the archive itself, and the abi's own objects plus both floors land in one `libirgx.a` with the same closure the merged object gives elsewhere. Thirty-three members, and the symbol index carries `pcre2_compile_8` and `libsais_main_ctx` beside `irgx_engine_open`. Only the assembly differs; what a consumer links does not.

  Nothing had caught this because the release workflow had never run - it publishes on a tag, and there has not been one. A manual dry run is what surfaced it.
- The `ci_order.sh` conformance gate — the one that orders correctness before performance and validates the committed certificate bundle — had been running almost none of what it claims. The five-layer restructure moved every script it shells (`bench/rgsuite/` → `bench/conformance/rgsuite/`, `bench/gates/` → `bench/conformance/gates/{parity,contract}/`, `bench/matrix/matrix.py` → `bench/conformance/shapes/shapes.py`, `bench/session/` → `bench/dominance/session/`, `bench/certify/` → `bench/certificate/{mint,guard,ledger}/`) and the gate kept the old paths. All 18 invocations pointed at files that do not exist.

  The certificate half failed _open_, which is why it went unnoticed. `guard/artifacts.py` reports an absent bundle as exit 2, and a missing interpreter script is also exit 2, so the gate read its own broken invocation as "no certificate published yet", printed a NOTE, skipped the cold ratio floors, and passed. Infrastructure that cannot run is not evidence, so the guard script is now asserted to exist before its exit code is trusted, and a missing one is a hard failure rather than a benign state.

  Two of the gate's step labels also still named `matrix.py`, a script the restructure retired, so the report described a run that could not have happened; both now name `shapes.py`, and the `TESTING.md` freshness sentinel that pinned the retired spelling was repointed at the live one. That sentinel is the canary for these steps still being present, so it has to quote what the gate actually prints.

  Restoring the paths brought the committed gist-vs-csearch floors back under judgment — the two classes where csearch genuinely wins, `literal-rare` at 0.56x against a 0.45x floor and `regex-dotted` at 0.48x against 0.40x, both clearing. Those floors exist precisely so that gap cannot quietly widen, and nothing had been checking them. Also dropped `--require-head`, a flag the restructure deliberately removed along with the semantic (a bundle is judged from committed bytes, never from current HEAD) and which had since become an argparse error the gate swallowed as exit 2.
- The `fault-taxonomy` ratchet was flagging `portal.ntMap` for three error names it
  does not own. This is a detector fix, not a code change; the gate was wrong and
  the source was right.

  `ntMap` is declared `MapError!Mapping`, and `MapError` is `std.posix.MMapError`.
  `MappingAlreadyExists`, `MemoryMappingNotSupported` and `PermissionDenied` are
  members of that set, so the Windows arm is not minting private vocabulary - its
  signature obliges it to say exactly those words. The tell is the other arm of the
  same `pub fn map`: on POSIX it returns `std.posix.mmap` directly, which produces
  those three identical names from inside std, where the ratchet counts nothing. So
  they were already crossing irregex's API surface on every target; only the
  platform fork decided whether the token sat in our file or std's. Declaring them
  in `[fault_domains]` would have been the actively worse fix - it would have
  claimed std's vocabulary as ours, and parked `PermissionDenied` next to
  `AccessDenied` in one domain, which is the synonym pair this gate exists to
  prevent. std keeps those two apart on purpose; one is a mode conflict on the
  descriptor, the other is a `noexec` mount.

  So the missing rule is the mirror of the consuming-position one already there: a
  `return error.X` from a function whose *declared* error set resolves to std's own
  is restating std, not accreting a sixth spelling of `Corrupt`.

  The reason this is not just a hole I cut for myself is that the compiler enforces
  it, not the driver. A function with an explicit error set may only `return` a
  member of it, and Zig rejects anything else at that token - so smuggling a new
  fault name into one of these bodies is a build failure, not a finding the gate
  learned to ignore. The rule never has to know what std's members are; it only has
  to be sure the declared set really is std's. Everything else is fences around
  that: it is per function and innermost, so a nested `fn` is judged on its own
  signature and the rest of the file is untouched; it covers `return error.X` only,
  because a name bound to a local or declared in a set inside the body is never
  coerced into the declared set; an inferred `!T` never qualifies, since inferring
  your error set from whatever you return is the opposite of a closed vocabulary;
  and it engages only in a file that binds `std` to `@import("std")` and nowhere
  else, resolving one level of local aliasing, with a name bound twice resolving to
  nothing. `const MapError = error{ Sneaky };` and
  `std.posix.MMapError || error{ Sneaky }` both stay counted.

  Seventeen new detector tests pin that, and fourteen of them are adverse: a
  private set wearing the alias's name, an alias rebound in an inner scope, a union
  that sneaks a private member into a std-looking signature, a rebound `std`, a
  file that mixes one good `std` binding with one bad one, a file that never binds
  `std` at all, an alias cycle, an inferred signature, a nested closure, a value
  that is never returned, a set declared inside an excluded body, and two parsing
  fences (a function-typed parameter and a prototype, neither of which declares a
  body that could enclose anything). One proves the exclusion is per function
  rather than a whole-file amnesty: a new spelling accreting beside a legitimately
  excluded std-set function is still caught. Across the whole tree the rule changes
  exactly three findings in one file, and `sheaf.zig`'s sixteen `error.Declined` -
  the real debt - are untouched.
- The batched-directory accelerator's step-aside is now unnameable outside the
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
- The corpus byte-density table stopped throwing away the ordering it exists to carry.

  `rarity.zig` stored `min(255, P·32768)` in a `[256]u8`. The clamp was the load-bearing
  part: 30 printable bytes hit the ceiling, 20 of the 26 lowercase letters among them, so
  for a lowercase identifier every byte scored the same and the table had no opinion about
  which two the block filter should compare. Anchor selection then fell through to whatever
  its tie-break happened to do, and the module doc's "only the coarse ordering matters"
  was true in exactly the way that made this fatal - the clamp destroyed the only property
  the table promised.

  It is now `[256]u16` at `round(P · 65535)`, unclamped, re-measured over 253 MB of the
  tree (24,602 text files) by a checked-in generator, `tools/build_rarity_table.py`, so a
  regeneration is a reviewable diff rather than a hand-edit. On that census the old
  representation left 423 printable pairs and 171 lowercase pairs sharing a cell despite
  differing in real frequency; the new one leaves 7 printable pairs and no lowercase pair,
  with only the space at the top of the range and zero rank inversions across all 256 cells.
  The 7 survivors are bytes whose true frequencies differ by under 0.7% (`{`/`}` by 0.05%),
  where a tie is an honest statement rather than a representation failure.

  Measured with the anchor policy held fixed and only the table varying, over the 203 MB
  code corpus and 128 MB prose corpus of `research/pincer/`, priced against the best pair
  that exists for each needle: **2.55x -> 1.50x of oracle survivors on code** and
  **2.99x -> 2.21x on prose**. Against the selector as it shipped before any of this
  (4.61x code, 6.97x prose) the two repairs together are 3.08x and 3.15x. The prose figure
  is honestly cross-distribution: this is a code-corpus prior, and a prose-fitted census
  reaches 1.76x there.

  `single_probe_max` moved 48 -> 96, which is the same 0.15% probability bar under the new
  denominator, not a policy change. `analysis/prefilter.zig` lost the sentinel branch that
  expanded a saturated cell to a guessed 2048 - a made-up number that priced the space
  identically to `c` - and its `probability_scale` tracks the table's scale so every
  `stride` bar calibrated against it is unchanged.

  Byte-exactness is unaffected by construction: the table decides which filter runs, never
  which positions match, and every survivor is still `memcmp` verified.
- The discipline job's shell linter is pinned now, like everything else it runs.

  Every other tool in that job is a Python distribution installed at an exact version into uv's isolated environment, so the job's verdict moves when we move it and not when a formatter ships a release. ShellCheck was the one exception and came with the runner image, which meant a runner carrying an older build could report a finding nobody here caused: SC2317 against a `trap`-invoked cleanup, which newer ShellCheck reads correctly. Pinning `shellcheck-py` closes the gap; the finding was never in the script.
- The literal filter stopped picking the worst pair of bytes it could find, and the
  decision now lives in one module instead of being inlined in the scan loop.

  `indexOfPos` filters 64-byte blocks on two byte equalities at two needle offsets.
  Which two is the filter's only variable cost - everything else per block is fixed -
  and it was being chosen by ranking bytes on their individual corpus rarity and
  taking the two rarest. That prices a conjunction as `P(a)·P(b)`, which assumes the
  two probes are independent draws. Text is the worst possible case for that
  assumption: the correlated unit is the word, so byte correlation peaks at exactly
  the short distances a needle offers.

  Then the density table made it much worse. `rarity.zig` stored `min(255, P·32768)`,
  so 20 of the 26 lowercase letters saturated at the same value; for a lowercase
  identifier every byte tied, and the old strict `<` tie-break never displaced its
  initialisers, so it returned offsets `0` and `1`. The adjacent pair. The single most
  correlated choice available, and the one case where a two-byte conjunction buys
  almost nothing over one byte. That fired on 122 of 177 code needles and 78 of 90
  prose needles, which made the "two rarest bytes" selector *worse than the fixed
  first+last it replaced*, in both regimes, on every summary statistic.

  The clamp itself is fixed separately (see the rarity-table dynamic-range entry).
  **Those two wins are redundant, not additive - do not multiply them.** Priced across
  all four corners, the table was the larger defect: fixing only the tie-break takes
  survivors from 4.61x to 2.55x of the best-possible pair, fixing only the table takes
  it to 1.49x, and doing both lands at 1.50x. This entry is what keeps the failure
  *graceful* if a future census ever re-introduces ties, rather than a second
  multiplier on top.

  It was visible in the shipped binary without a patch: `stepSec` (7 bytes, 464 real
  hits) ran **41% slower** than `pgxpool` (7 bytes, 8,856 real hits). Far more actual
  work, less time, because `pg` is a rare digraph and `st` is not.

  Selection moved to `kernel/scan/anchor.zig`, and ties now resolve toward the widest
  separation rather than falling out of a comparison. Ties mean the table has no
  opinion, and separation is the one correlation-reducing axis available without a
  model, so there is no magic constant in it. Measured over the 213 MB code corpus on
  eight all-tied needles, anchor pair as the only variable: **2.07x geometric mean**,
  best case 4.27x (`internal`, 40.7ms to 9.5ms), and the worst cases move from ~5 GB/s
  to ~22 GB/s.

  One needle regresses 1.52x, and it is the most useful row in the table. `namespace`
  was genuinely better on the adjacent pair, because `na` is a rarer digraph than
  `n`-then-`e`-at-8. So separation is a tie-break and not a selectivity model; it is
  worth 2x on average and cannot be trusted per needle. Only measured pair statistics
  reach the best-possible pair, and the compact ways of shipping those were tried and
  lost - both are written down in `research/pincer/` so nobody re-runs them.

  Byte-exactness is unchanged and structurally so: the anchor pair decides which
  filter runs, never which positions match, and every survivor is still `memcmp`
  verified. The measurement harness fails closed if two anchor choices ever disagree
  on a hit count, and none did.

  One more slip, caught before it shipped and recorded in the code so it cannot come
  back: an early draft sorted the returned pair by offset for tidiness, which put the
  common byte in the probe slot and silently cost the single-load fast path 1.42x on
  the needles that had earned it. Rarity decides which slot a byte takes. Never sort
  that pair.
- The one direction gist is not allowed to fail in — a stale index costing a match rather than time — is now a written-down model with a test per assumption, and the two places it could actually have failed are closed. The crest sidecar's seal used to be an option the query path declined: `decode` checked magic, version, schema digest, doc count, length, and alignment, and every one of those passes over a table whose ρ(d) rotted DOWNWARD, which is the single corruption in this format family whose symptom is a document pruned instead of read. The loader now spends the digest at admission (`persist.sealedCrest`), so nothing downstream can inherit an unproven table, and `short_docs` — derived from the same bytes, where an upward rot instead hides a short document from the sliver tier — falls with it. It stays affordable because the pages were already paid for: 0.18 ms of BLAKE3 at 1.93 GB/s over the production 345 KB / 21.6k-doc sidecar, on a table the loader walks record-by-record immediately afterwards. The codicil carried the same rows with no seal at all and is now sealed in full (`GISTCOD1` → `GISTCOD2`; a v1 blob reads as absent and the next amend rebuilds it, which costs kilobytes), verified before any field is believed, since a broken seal means the ids, the tombstones, the crest rows, and the embedded postings are all bytes of unknown provenance. And the claim itself is no longer stated unconditionally in one place and honestly in another: `src/corpus/fresh/README.md` § The model names the one predicate that carries it — a read may be elided only when BOTH mtime and ctime are strictly behind the build anchor — the three filesystem assumptions it rests on, and the five cases outside it, where `--no-index` costs time and nothing else. Each assumption is now a test that drives real syscalls rather than a mocked stat: an ordinary write is surfaced, an mtime rewound behind the anchor is still surfaced through ctime (`touch -r` cannot hide a rewrite), a rename over an indexed path is surfaced despite the index being path-keyed, an unstattable path stays conservatively fresh, the predicate's whole 4×4 boundary admits elision at exactly one combination, and each of the three conjuncts in `Oracle.skip` is shown to be necessary over a real published pair.
- The parabix and shuffle suites now run on every architecture, not just the one
  the rungs ship on.

  Both rungs are AArch64-only on purpose. `plane.on_neon` and `lanes.native` are
  compile-time predicates about where the throughput was measured, and off AArch64
  the field stays null and the ladder falls through unchanged. That part was fine.
  What was not fine is that thirteen tests in those two directories read the
  production entrance and assumed it had armed, so the first time CI ran the suite
  on Linux it came back with seven differential failures, four `RungDeclined`s, two
  `.target`-instead-of-`.star_height` mismatches, and two `SIGABRT`s from
  unwrapping a null build.

  None of that was an engine defect. `.target` is decided before any other refusal
  reason and short-circuits all of them, so every shape gate off AArch64 was
  asserting nothing but a column of `.target`s, and every differential floor
  (`admitted > 100`, `armed > 1000`, `slice_yes > 100`) was unmeetable because
  nothing armed. The vacuity guards were doing exactly their job; they were the
  only reason this was visible at all.

  The fix is not to skip. `admit.planFor(comptime neon, …)` already existed for
  this exact reason - so the gate test could drive the verdict the *other* build
  produces - and everything under the arch predicate is portable Zig that means
  the same thing everywhere: the lowering, the marker chain, the lane assignment,
  the end-of-line axis, the `slice_safe` proof. `lanes.run` already carries a
  portable fold to drive it through. So the seam grew two siblings,
  `Parabix.buildFor` and `Compose.lowerFor`, the suites pass `true`, and all three
  parabix oracles plus all four shuffle layers now run wherever CI runs. Nothing in
  production passes anything but the real predicate, and the gate that decides it
  keeps its own test on both sides.

  Two tests skip off AArch64 instead, because the ladder's arming decision *is*
  their subject: the auction against an armed literal skip, and the `sliceSafe`
  proof driven through `re.rungs.compose`. There is no tier there to hold to a
  slice question.

  Measured after the change, on a real x86_64 Linux ELF built for `x86_64_v3` and
  run in an amd64 container: 377,640 compose line-and-doc cases, 23,220 parabix
  verdicts, 0 divergences, all eight shards green. Which is the answer to the
  question the red CI was actually asking - the machinery agrees with the Pike VM
  on both architectures, and now we find out from a test rather than from a user.
- The quotient sieve's worth test is now judged once **per grain**, and the field is
  admitted if either grain pays — with the ladder holding each path to its own verdict
  through the mirrored pair `lineSafe` / `docSafe`.

  Arming had gated on `pays(.line)` alone. That is the dearer of the two kernels: the
  per-line chains run at ~1.27 cyc/B where `survivesDoc` takes four lines at a time at
  0.729, and on every row of the production slate the buffer total comes out cheaper. So
  the single line-grain gate was a silently _stricter_ policy than the one being
  published — the doc comment on `nominal_line`/`nominal_doc` said arming was judged at
  the coarser grain, and the bench banner printed "at buffer grain", while the code
  withheld the sieve entirely wherever the incumbent's price fell between the two
  totals. That band is the document path, which is what `docMatch` actually walks.

  The premise the old wording rested on — "a sieve serves both paths from one field, so
  it has to pay at the harder grain" — had already been retired by `doc_ok`, the
  per-grain license that makes serving one path without the other safe. `lineSafe` is
  its missing twin: worth-only, with no correctness half, so it gates the ladder's line
  walk and never an assert.

  The defect was latent, and the production proof says so rather than being taken on
  faith: `zig build sieve` after the change reproduces the slate exactly — the same 6 of
  9 patterns declined, the same single published `uuid` loss, 0 soundness violations over
  1.60 B byte-positions — because no pattern on the slate falls in the band. Both
  residuals behind that `uuid` row now have measured fix shapes rather than conjectures,
  built in a separate Rust sheng sibling: a persistence-aware (block, class)
  chain that stops pricing a `k`-byte run as `p^k`, and a rival term read from the
  engine's own start-state accelerator with an excursion coefficient for what a tripped
  skip really costs.
- The rename that scrubbed the monorepo's vocabulary out of the test fixtures left
  two files crooked, because nobody re-ran `zig fmt` after it.
  `anchor_test.zig` swapped `"WalletService"` for `"SessionStore"` and
  `haystack_test.zig` grew a `.gist` row, both inside multiline array literals -
  which the formatter lays out as a grid, every column padded to its widest cell.
  Shorten the widest cell by one character and every row under it is one space too
  wide, so the file stops round-tripping. The tokens never moved, which is exactly
  why nothing noticed: CI runs `zig build check` and `zig build test`, and neither
  of those formats anything. The tree passes `zig fmt --check` again, and the two
  diffs are whitespace only - same bytes with the spaces removed, before and after.

  The other leftover was two `doc_radar` pins in
  `bench/rungs/multipattern/README.md`, which claimed
  `bench/dominance/races/multipattern.sh` and
  `bench/certificate/report/multipattern.py` sit under this root. Both left with
  the product, and the prose in that same file already cites them as `../gist/…`.
  A `paths_exist:` block is a claim about this package's disk, so a file in a
  sibling checkout cannot be pinned there at all - the entries are gone rather than
  reworded. Every `paths_exist:` entry in the tree resolves now.
- The resident answer keep now works on Linux, and it fails closed when watch
  coverage is lost rather than when it is merely uncertain. The inotify backend
  never armed the annals ledger — only `coverage.coverRoots` did, and only the
  kqueue backend calls it — so `epoch()` returned null and the keep was silently
  dead on every Linux daemon; inotify now arms the strip prefix, opens coverage
  once its watches are registered, and notes exact FILE deliveries with the same
  file/directory split `kqueue.note` applies. Separately, losing coverage
  (`IN_Q_OVERFLOW`, a subtree that could not be re-watched) poisoned only the
  seqlock: reconciling protected the query while the epoch stood still under a
  moving tree, so an answer already held could read fresh indefinitely. Coverage
  loss now blinds the ledger, which is the one state that makes `epoch()` decline
  outright, and a deliberate idle shed lapses it so answers held before the
  unwatched window retire instead of surviving the re-arm.
- The resident record stream now reports context rows the way ripgrep does. Two
  things were wrong, and both only showed up once a caller asked for context
  through the in-process face rather than the CLI.

  Submatch spans were collected only for rows classified as matches, and only
  when the search was not inverted. But rg paints spans on whatever line it
  prints, and under `-v` a context row is *by definition* a line the pattern
  matched — so `rg -v -C1` reports that line's spans and we reported none. The
  cold path already had this right and said so in a comment; the resident twin
  had drifted. Spans are now collected from the line's own content, which
  answers correctly for every combination without a special case.

  Separately, `-m` was treated as a hard stop. rg stops *selecting* at the cap
  but keeps searching that match's after-context window, and a line inside the
  window that matches prints as a match rather than as context; the window does
  not chain. `gist -m1 -A1` through the resident face called that line context
  and dropped its spans. The cap is now a position to measure from, mirroring
  the cold engine's `cap_at`.

  Found by the FFI-vs-cold parity suite, which compares every face against the
  cold engine that is itself held byte-identical to ripgrep.
- The resident record stream was built on the wrong one of the cold engine's two
  span iterators, so a nullable pattern could report a line as no match at all.

  Cold has `nextSpan` and `Rows`. They look interchangeable and are not: `nextSpan`
  drops every zero-width span, because its consumers - `-o`, `--column`,
  highlighting - all need bytes to point at. `Rows` keeps them, and `Rows` is what
  the `--json` stream is actually built on. The resident twin mirrored `nextSpan`
  while claiming parity with the JSON stream, which held for every non-nullable
  pattern and quietly failed for the rest: `rg -w 'x*'` paints an empty submatch
  at each word boundary and matches eight lines of our own test corpus, and we
  reported one.

  `collectSpans` now reproduces `Rows`. That means three rules the old code did not
  have. An empty span is real only for a nullable pattern; it is dropped when it
  sits exactly at the previous match's end, which is why `a*` over "aa" is one row
  and not two; and at end-of-content it exists only on a line that carried a
  newline in the file, since that is where rg's zero-width match sits. Callers now
  pass whether the line was terminated, which the line walker already knew.

  The `-w` twin folded back into the one function while this was being fixed. It
  existed to filter word-invalid spans, which is a flag on `Rows`, not a separate
  walk - and it had drifted on its own account, advancing past a rejected
  candidate's whole span where rg retries one byte on. A rejected candidate never
  consumed anything, because rg compiles `-w` into the pattern.

  Found by the FFI-vs-cold parity suite. The cold path was right throughout; only
  the resident face was wrong.
- The rg-conformance suite scored `-e ')('` as a design decline — *gist refuses
  this by design, use `-P`* — which was never true, and the new diagnostic made it
  say so out loud. Chasing it down turned up something better than a
  classification bug.

  `)(` is not a regex. ripgrep answers it anyway because it wraps every pattern in
  `(?:...)`, which pairs the user's stray parens with its own: `)(` compiles as
  `(?:)()`, a valid pattern matching the empty string at every position, which is
  exactly what `rg --json` reports. So rg's exit 0 is not evidence that the pattern
  is valid — it silently searched for something nobody asked for. gist refuses it,
  and PCRE2 agrees there is nothing there to compile.

  The case is still NA, because gist cannot claim parity with an answer it
  considers wrong, and it is not a FAIL, because refusing a malformed pattern is
  the fail-closed contract working. What changed is that the recorded reason is now
  the true one. `is_malformed_refusal` reads the engine's own verdict — the CLI
  prints that line only after PCRE2 refused too — so the scorer is not re-deriving
  a judgment the engine already made.

  The differential fuzzer learns the same verdict as `malformed`, kept separate from
  `declined` because the two ask for opposite responses: one means another tier
  could answer this, the other means no tier can. Without it a generated `)(` would
  have landed in the ratcheted residual as a fresh divergence class and failed the
  next certificate mint over a case gist gets right.

  Scoreboard unmoved: 411 PASS / 14 NA / 21 SKIP, 100.0% supported-surface parity.
- The root LICENSE was still the placeholder repo's MIT text, months after the package itself relicensed to Apache-2.0 — the extraction kept the file the standalone repo already had rather than the one the kernel shipped. LICENSE is now the Apache-2.0 text the NOTICE, the README, and the changelog have all been describing, the python bridge declares `Apache-2.0` (with the license file beside its pyproject, where PEP 639 looks for it), and LICENSE + NOTICE are in `.paths` so they ship with the package instead of being left behind at fetch time. NOTICE also drops the libsais entry, which left with `relate`.
- The root declaration the brand seam looks for is `irgx_brand`, not `irregex_brand`.

  `relate` and `blast` had already renamed theirs, so `@hasDecl(root, "irregex_brand")` was answering false for both and each binary silently fell back to the default `gist` identity. Running `relate`, a bad knob was reported as `gist: note: ...` - naming a program the user was not running, which is the exact failure the seam was built to end. It compiled clean either way, which is how it survived a rename that touched everything around it.

  Only the declaration moved. The type is still `irregex.Brand`, because that is the Zig package name and consumers still write `@import("irregex")`.
- The split moved directories that the prose kept naming by their old addresses,
  so a reader following a citation landed nowhere. Every current-location path
  cite I could verify now resolves.

  `bench/harness/` became `bench/apparatus/harness/` for the three instruments that
  stayed here, and `gist/bench/apparatus/harness/` for `bench.zig` / `flagbench`
  which left with the product. `bench/crest/`, `bench/sieve/`, `bench/sliver/`,
  `bench/multipattern/`, `bench/parabix/`, `bench/roofline/`, and
  `bench/lowerbound/` all gained their bucket prefix (`rungs/` or `bounds/`), and
  the lowerbound Zig file is `audit.zig` now, not `lowerbound.zig`. The certificate
  scripts renamed when they crossed into the sibling `gist` package, so
  `bench/certify/certify_stats.py` is `gist/bench/certificate/report/stats.py`,
  `certify_layers.sh` is `mint/splice.sh`, `ratio_regress.py` is `guard/ratio.py`,
  and the same for the rest of that table. The gates and the rgsuite moved with
  conformance, so those cites say `gist/bench/conformance/…` now too.

  One exception inside this tree: `bench/rungs/sliver/scale_race.py` already imports
  its quantile / bootstrap / Mann-Whitney math from `bench/apparatus/stats.py`, so
  those cites point here, not at gist's copy.

  Scrubbing the monorepo's name out of paths had left **empty backticks** where the
  path used to be - seven `(from ``)` holes across the bench rung READMEs and the
  crest proof, each of which had once said where to run the command from. They say
  "from the repository root" now. Three code blocks still ran `cd ../../..`, which
  used to climb from the package's nest up to the monorepo root and after
  extraction just walks out of the tree before running tree-relative paths.

  Four phantom filenames went too. `census.zig` → `emit.py` were offered as the way
  to regenerate the PMI table and neither is anywhere, so the recipe they stood for
  is written out instead; the recipe was always the contract rather than the digits.
  `probe18` and `probe19` were spike files named as if you could open them, so the
  measurements they produced are described by method. `bench/multipattern/sweep.py`
  turned out to be a second name for the crossing race seven lines above it in the
  same doc comment, which is real and now the only one cited.

  **Nothing here was reachable by `make`.** This package has no Makefile - it never
  did, the targets belonged to the monorepo - so every `make install-gist`,
  `make gen`, `make gen-gist-schema`, and `make bench-gist-certify` was an
  instruction that could only fail. Three of them were shipped user-facing error
  text: the Python and Go binding both tell you to run `make install-gist` when they
  cannot find a binary, and the schema-drift failure told you to reconcile with
  `make gen`. They name `zig build -Doptimize=ReleaseFast` and
  `python3 tools/build_schema_tables.py` now, which is what the generator's own
  staleness message and the Rust binding already said.

  One test moved with them. `test_a_drifted_digest_is_a_named_failure` asserted the
  literal string `make gen` appeared in the drift message; it was pinning the
  monorepo contract, so it now asserts on the instruction that can actually run. The
  assertion's job is unchanged - the failure still has to say how to reconcile the
  two sides.

  The Python contract docstrings also still said `schema.gen.py` is lowered from
  `contract/surface.toml`. That was true before the contract split by ownership;
  the analytic tables are `contract/analytic.toml` here, and `surface.toml` is
  gist's.

  Not fixed, because fixing it is a decision rather than an edit:
  `bench/rungs/sieve/indexcost.sh` still sources `../../dominance/races/field.sh`,
  which is not in this package, so that script cannot run here; and a few contract
  keys still name sibling-repo paths as if they lived under this root.
- The test runner is pinned by url and hash instead of assumed to sit beside this
  repository.

  `.brigade = .{ .path = "../brigade" }` resolves on a machine that happens to have
  the sibling checked out, and nowhere else - so a fresh clone, and CI, could not
  build this package at all. brigade is a published package now
  (github.com/The-Billy-Company/brigade), pinned the way pcre2 and libsais already
  were, though not `.lazy` like those two: the vendored engines are never fetched,
  and the runner really is.
- The two output-budget tests in `corpus.zig` now assert against the budget they
  name, instead of against whatever `GIST_*` the shell that ran them happened to
  export.

  Both tests are claims about the DEFAULT ceiling - one that the budget charges
  content rather than the escapes around it, one that a sharded merge cuts on
  content so a decorated run keeps every file. Both opened by calling
  `initOutputBudget(false)`, which reads `GIST_UNCAP`, `GIST_MAX_OUTPUT_TOKENS`
  and `GIST_MAX_OUTPUT_BYTES` on its way to installing a ceiling. So a shell that
  had run the bench harness - which exports `GIST_UNCAP=1`, and the comment three
  lines above the read says so - lifted the soft guard, the merge stopped cutting,
  and `a sharded merge cuts on content` failed with `expected 2, found null`. CI
  was green the whole time, because CI has a clean environment. That is the worst
  shape a test can have: it is not wrong often enough to get fixed, and it is
  wrong exactly when the person running it has been doing the measurement work.

  The tempting fix is to have the tests set the variables they want and put them
  back. I did not do that, for two reasons. It leaves the design defect in place -
  a function that silently consults global state stays harder to reason about than
  one handed its inputs, and the test difficulty was the symptom, not the disease.
  And it makes every test in the process share one mutable environment, which
  trades a flake that at least reproduces for one that depends on test order.

  So the budget got the split it already wanted. `resolveOutputBudget` reads the
  flag and the three knobs and returns a `Budget`, and that is all it does;
  `installOutputBudget` binds a `Budget` and resets the run counters, and that is
  all IT does. `initOutputBudget` is now those two composed, so production is
  unchanged - the CLI still calls the same function, and `GIST_UNCAP` still lifts
  the soft guard for the harness that depends on it. The two ceilings moved out of
  the counter struct into `Budget` so there is one definition of them rather than
  two, and `Budget.default` is what a run with no flag and no environment is bound
  by. The tests install `.default` and say so.

  This is the shape `assay.install` already uses for the trace mask, whose
  `lenses: ?u32` exists, in its own words, "for the callers that have no
  environment to read: an embedder of the C ABI ..., and a test that must light a
  lens deterministically." A budget is the same kind of fact, and now has the same
  kind of seam. It also means the C-ABI embedder can state a ceiling outright,
  which it previously could only do by editing the host process's environment.

  Verified both ways round. The two tests pass with the three variables unset,
  with `GIST_UNCAP=1`, with `GIST_MAX_OUTPUT_BYTES=99991`, with
  `GIST_MAX_OUTPUT_TOKENS=1000`, and with all three at once - where before they
  failed under every one of those. Production was A/B'd by building the same probe
  against the old and new code and driving `initOutputBudget` through twelve
  environments (each knob alone, the falsy `GIST_UNCAP=0`, the `--uncap` flag with
  no env, `GIST_MAX_OUTPUT_BYTES=0`, and the overlapping pairs): the resolved
  ceilings are identical, line for line.

  One sibling has the same disease and a different cure, so it is reported rather
  than papered over here: `resident_test.zig`'s `a covered root stays warm` writes
  a `src/` subdirectory into its fixture and queries with that as an explicit root,
  so an inherited `<GIST_DIR>/skips.list` naming `src` prunes the fixture's own
  directory, the session correctly declines, and the test panics reaching for
  `.got`. That is the same class as the `GIST_DIR` inheritance that already bit
  `haystack_test`, but the fix is a corpus-scope question rather than a
  policy-install one, and guessing at it inside a budget change would be worse
  than naming it.
- The two prefilter parity gates under `bench/rungs/sieve/` froze their corpus
  from four path literals baked into the script. Three of the four are not
  directories this package has, and `git ls-files` does not complain about a
  pathspec that matches nothing — it just returns fewer files. So `warm_parity.sh`
  was silently measuring 355 files from the one slice that survived while its
  source said it was measuring four, and had that last slice been renamed too the
  list would have gone empty, piped straight into `rsync`, and the gate would have
  reported every arm agreeing about nothing.

  `GIST_SIEVE_CORPUS` declares the slices instead: a space-separated path list,
  relative to the corpus root, defaulting to `src bench` so a bare clone measures
  itself (438 tracked files). `cover_parity.sh` reads the same knob, so the two
  gates freeze the same tree unless you tell them otherwise; it keeps its own
  degradation to the whole tree, while the warm gate — which had no fallback at
  all — now enumerates before it copies and refuses an empty resolution outright,
  naming what it was asked for. Every arm agrees trivially on an empty corpus, and
  a benchmark that measures nothing is worse than one that will not run.

  Verified on a bare clone with the artifact home scrubbed from the environment:
  `cover_parity.sh` proves 21 cases and narrows 5 classes, `warm_parity.sh` proves
  27 cases with the cover plan narrowing 5 patterns and the sieve 7 more, geomean
  1.49x end-to-end. `GIST_SIEVE_CORPUS=/definitely/not/here` and a list naming only
  paths this tree lacks both exit 1 with the refusal rather than a green run; an
  explicit `GIST_SIEVE_CORPUS=bench` freezes 101 files in both gates, so the knob
  is load-bearing and the two agree about what it means.
- The warm line renderer set only one end of its per-document window, and a text
  document following a binary one inherited the binary's end address. `handleBinary`
  re-points the pair at the committed pre-NUL prefix, so the next document's
  `body_end` pointed into a region that was not its own — and every fused
  whole-buffer pass inside `Emitter.file` reconstructs its body from that pair, so
  this was not a lost optimization but a scan over another document's address
  range. `panic|0x` (pure literals with no single needle, which is what engages the
  SIMD candidate sweep) walked off the end of the mirror's shard mapping and killed
  the daemon; the unterminated-tail framing was reading the same stale end. Both
  ends are now assigned per document, exactly as the cold renderer does it.
- This package could not be built by anyone who only had this package. `build.zig.zon` reached for `.kernelkit = .{ .path = "../_buildkit" }`, a sibling that exists on one machine and has no remote, so a fresh clone failed at configure time with `unable to open '../_buildkit'` — before compiling a line. That broke every clone, every CI runner, and any `pip install` that had to build from the sdist rather than a wheel.

  The whole of what it borrowed was one file: `brigade.zig`, the shard-aware test runner, now living here beside `build.zig` and shipped as part of the package. `gist` and `relate` pick it up through the dependency on this package they already declared, so the build-tooling package leaves the graph entirely rather than being replaced by a published one. Nothing about how tests run changed — same sharding, same `BRIGADE_*` levers, same per-test semantics.

  The prose that pointed at the old package went with it, including two comments citing a `_buildkit/build.zig` helper that is no longer reachable from any of these repositories.
- Three helper bodies were living in two files each, which is the shape a parity
  bug arrives in: a fix lands in one twin and quietly misses the other, and
  nothing fails until the two answers are compared.

  The watcher's POSIX arms each kept their own `wallNowNs`, so Linux and macOS
  could drift on what instant a delivery is stamped with. That is not cosmetic;
  the annals date every observed change against that clock, and a held answer is
  trusted purely on the epoch it mints. The reading now lives in
  `watch/stamp.zig` and both arms read it. Windows is not a third copy of it -
  its notify records carry the changed file's timestamps in-band, so it stamps
  from those and reaches for a clock only on a removal.

  The cover calculus was the worse one, because it had already started to drift.
  `analysis.zig` derives the required-literal cover by recursive descent and
  `ast/ast.zig` derives it by a forward sweep over the interned DAG; the whole
  point is that both reach the identical verdict, and yet each carried its own
  `thinner` and `weakest`, with the two `weakest` bodies already written
  differently while still agreeing. Both now read the rule from `analysis.zig`,
  which the DAG side already imports, so there is exactly one definition of which
  of two covers is more selective. Same story for the single-codepoint `uclass`
  literal, which the sweep spelled `litOfUclass` and the analysis spelled
  `uclassLiteral`: one question deserves one answer, and it kept the name that
  reads like what it returns.

  No behavior moved; the surviving bodies are the ones that were already there.
- Three of the nine `GIST_TRACE` lenses were advertised and dark. `rank`, `index`, and `session` were declared in `assay.Lens`, listed in `assay/README.md`, and printed by `--schema` — and had **zero** call sites, so `GIST_TRACE=rank` was indistinguishable from a lens that did not exist. A promised diagnostic that answers silence is worse than an absent one: it costs a debugging session before you learn the channel was never wired.

  **What the summary structurally cannot say.** Each dark lens sat over a phase sequence that an always-on `assay.summary` was already collapsing into a single number. `gist index` reported one total for a corpus walk, a trigram build, a crest sieve, a generation-atomic publish, and five best-effort sidecars — so "the index build got slow" had four unrelated causes and one number that distinguished none of them. `--rank` reported `rank_ms` for candidate resolve, root scoping, parallel read, and feature extraction together, and never reported fuse+render **at all**, because the summary reads its span before the render runs. The daemon had no per-request instrumentation whatsoever: the worker's own summary travels to the _client's_ stderr through its buffer sink, which means "which requests are slow, and are any being dropped" was unobservable from the operator's side of a running `gist serve`. Each lens now emits the splits its summary cannot, sharing that summary's clock rather than adding one.

  **A lens must be honest on every tier, or it lies by omission.** Wiring only the cold rank path would have made `GIST_TRACE=rank` go dark exactly when the resident daemon serves — the common case — while still printing a summary, which reads as "this phase took no time" rather than "this phase was not measured." The live and warm ranks now carry the same two-phase split, tagged with the tier that produced them, and the warm split rides the buffer sink to the _client's_ stderr, so a warm `--rank` narrates itself to the process that asked. The per-request `session` line deliberately sits outside that sink scope and lands on the daemon's own stderr, where an operator is watching. Because the lens mask is per-process and installed at startup, a warm query is traced by the daemon that serves it — `GIST_TRACE=rank,session gist serve` lights both.

  The verification found what the instrument was built to find: the first ranked query after a cold start spends 85.7 ms of an 86.0 ms "rank" inside candidate resolve, because the resident-session self-spawn happens within that span. Real wall time, correctly attributed, and completely invisible to the one number that preceded it.

  **One production `catch {}` left.** The keep's fire-and-forget answer offer discarded its failure into an empty block — the shape fault-channel law 8 bans precisely because it is indistinguishable from forgetting. It now routes through `fault.spare` with its intent named, so `GIST_TRACE=fault` shows an offer that never landed instead of silently costing the next run its reuse. The remaining empty blocks are inline-test fixture teardown, which the ratchet already excludes.
- Three ways a character class could disagree with ripgrep, all of them found while
  re-reading the class parser rather than by a bug report, and all three the same
  mistake wearing different hats: taking a complement in the wrong place.

  `-i` over a negated class was matching the character it excludes. The fold ran as
  a pass over the finished tree, so `[^k]` had already become "everything but `k`" -
  which still holds `K` - and folding that set handed `k` straight back.
  `gist -i '[^k]'` matched both `k` and `K` where rg matches neither. The fold now
  happens before the complement, on the members as written, which is what rust-regex
  does; the later whole-tree pass is left in place because a fold-closed set is
  closed under folding again, so it can only be a no-op. That covers `[^k]`,
  `[^a-z]`, `\P{Lu}`, and both POSIX spellings.

  A shorthand class was allowed to bound a range. `[a-\d]` quietly meant `a`, a
  literal `-`, and `\d`, and `[A-\d]` meant the range `A`-`\` plus `d`; rg rejects
  both with "invalid range boundary, must be a literal". Now so do we, on either
  side of the dash and in both engine modes. The byte path got the same
  literal-vs-class split the Unicode path already had, which fixed a third thing on
  the way: `(?-u)[\t-\r]` was three literal bytes instead of the range 0x09-0x0D, so
  it never matched a vertical tab.

  And `[[:^lower:]]` complemented the 256 bytes rather than the whole scalar space,
  so in Unicode mode it admitted `é` but not `日`. The POSIX reader no longer applies
  the complement itself - it reports what the bracket said and each mode takes the
  complement in its own universe, bytes under `(?-u)` and scalars otherwise. The
  outer spelling `[^[:lower:]]` was always right, which is how the split surfaced.

  648 pattern/flag/corpus comparisons against rg now agree, where the same sweep
  caught all three of these before, and each fix carries a parser-level test that
  fails if you back the fix out.
- Two test fixtures asserted `.gitignore` behavior they were not actually
  creating the conditions for, and passed anyway because of where the test binary
  happened to be run from.

  `.gitignore` governs a repository and nothing else - `Ignore` finds one by
  ascending from CWD, ripgrep's require-git rule. Neither the `loadpar` parity
  fixture nor the `scoped` session fixtures put a `.git` in the corpus they built,
  so their VCS rules were switched on only by the ambient fact that the runner sat
  inside this checkout. Run the suite from anywhere else and the rules simply did
  not apply:

  ```text
  MEMBER: /tmp/gist_loadpar_parity_fixture/foo.log        # `*.log` said drop it
  MEMBER: /tmp/gist_loadpar_parity_fixture/sub/ignored.txt # so did `ignored.txt`
  ```

  Both walks agreed on that six-file answer, so the parity half of the test was
  still honest - what had quietly stopped holding was every assertion about what
  should have been pruned. The scoped suite failed the same way one step further
  along: the `.gitignore` it writes mid-test changed no verdict, so the file it
  was meant to drop stayed admitted and the count came back one too high.

  Each fixture now creates its own `.git`, which is what makes it a repository and
  what the production probe actually stats. The assertions are unchanged; they
  just describe the corpus under test instead of the directory the runner was
  launched from. Caught by running the suite on a bare x86_64 box with no checkout
  above it, where both tests went red.
- Two things a Windows user could not reach: their preferences file, and color.

  **Preferences.** `locate()` looked in `$XDG_CONFIG_HOME`, then `$HOME` — neither of
  which a Windows shell sets — so the machine-local preferences file was
  unreachable on the platform and `gist config` had nothing to report. It now falls
  through to `%LOCALAPPDATA%`, then `%USERPROFILE%\.config` for a ported dotfile
  setup. `LOCALAPPDATA` rather than `APPDATA` is the whole point of the feature:
  `APPDATA` roams between machines, and a preferences file that follows you onto
  another machine is precisely the `.ripgreprc` hazard this design exists to avoid.
  `XDG_CONFIG_HOME` is still consulted first everywhere, because a Windows user who
  sets it means it.

  **Color.** `--color=auto` resolved to *off* on every Windows console, because an
  absent `TERM` was read as "not a terminal" — and no Windows console sets `TERM`.
  `termcolor` has the asymmetry ripgrep inherits (`should_attempt_color` falls back
  to `cfg!(windows)`), and the port had copied only its POSIX branch. Absent `TERM`
  now suppresses on POSIX and does not on Windows.

  The console-mode question is asked separately, and asked properly: Windows Terminal
  arrives with VT processing enabled, legacy conhost has to be told, and
  `std.Io.File.enableAnsiEscapeCodes` both tells it and answers whether it worked —
  also recognizing a Cygwin/MSYS pty, which is not a console at all and which
  `isTty` alone answers wrong. A console that refuses gets no escapes, since garbage
  bytes read worse than plain text. An explicit `--color=always`/`ansi` still asks
  the console to interpret, so a deliberate request renders instead of printing its
  own escape sequences, and is still never vetoed. On POSIX the call degenerates to
  the `isTty` it replaced, so that arm is unchanged byte for byte.

  Also: `GIST_DIR` trailing-separator trimming only knew `/`, so a shell-completed
  `C:\tmp\gist\` produced a doubled separator in every artifact path.
- `--count-matches` counted only non-empty spans, so a nullable pattern reported far fewer matches than ripgrep: `--count-matches 'a*'` over "aa\nbb" answered 1 where rg answers 4, and a pattern whose every match is zero-width (`x?`) reported no matches at all instead of 6. The `-o` printer was already correct on the same input, so the two disagreed about what a match is. Both now step through one walk (`output.Rows`) that owns the zero-width admission and progress rule, making `--count-matches` exactly "how many rows `-o` prints" — ripgrep's own identity. The whole-buffer `-U` parity table gained the pattern shape that can actually reach that emitter: `a*` never claims `\n`, so rg keeps it on the line counter and gist routes it away from the `-U` path for the same reason, which made the old row a probe of a path neither tool uses.
- `--crlf` no longer reports matches ripgrep does not have. `.` and every
  character class now decline `\r`, so nothing consuming can cross a CRLF
  terminator.

  `rg --crlf -o -e '(.{2,}|\S)fn'` over a small mixed CRLF/LF tree printed one
  match; gist printed three. Same flag, same corpus, and gist's extra rows spanned
  two lines each - because with `\n` as the terminator and `--crlf` on, the CR is
  still sitting at the end of the line's bytes, and gist's `.` was happy to eat
  it. Once a thread consumes the CR it is inside the next line, and one match
  covers two.

  `--crlf` in ripgrep is not an engine mode; it is a pattern rewrite.
  `grep-regex` runs `strip_from_match` over the parsed HIR and takes `\r` out of
  every class it finds - `.`, a spelled-out `[…]`, a negated class, `\S`, all of
  them - before the regex is ever compiled. Line furniture stops being content.

  gist now does the same, as an AST pass (`syntax/scalars.zig::stripCpAst`) run
  after the `-i` fold so a class promoted to `uclass` by folding is stripped too,
  and applied by the same `parse` both the match engine and the capture VM go
  through, so `-r`/`--json` cannot disagree with the match. Measured against real
  rg over `alpha\r\nbeta\r\ngamma\n`, `a.*`, `[^x]+`, `a[^q]*`, `.$` and
  `alpha.beta` are now byte-identical, and the count under `--count-matches` that
  the fuzzer caught at 5-vs-4 now agrees.

  Two related divergences remain, and are not touched here:

  - ripgrep REFUSES a literal `\r` (or `\n`) in the pattern under `--crlf`, exiting
    2 with "the literal \r is not allowed in a regex". gist keeps its own posture -
    the class of one empties, the pattern is unmatchable, and the hint channel says
    which flag would have matched - the same answer it already gives for a literal
    `\n` under the per-line model. Divergent in exit code, deliberately.
  - ripgrep treats a LONE `\r` as a line boundary for `^`/`$` under `--crlf`, where
    gist only recognizes a `\r\n` pair. That is a line-anchor question rather than a
    class question, it crosses both engines, and it is still open.
- `--files-without-match` no longer lists a binary file whose NUL sits past the
  first few kilobytes. Both engines had a second, weaker definition of "binary" on
  this path, and a file could be text by one and binary by the other.

  `rg --files-without-match -e generated .` over a 140 KB file of text ending in a
  NUL lists nothing; gist listed the file. Two independent causes, one per engine,
  both the same mistake - the negated path asked a different question than the
  searcher asks.

  Serial asked `corpus.isBinary`, which is the INDEX's membership rule: a NUL in
  the first 8 KiB. That is the right rule for deciding what belongs in a trigram
  corpus and the wrong one for deciding what ripgrep searched, because rg detects a
  NUL in whatever read buffer it lands in, however deep. `fileWithoutMatch` now
  asks what `renderFile` asks - `verify.firstNulWide` over the whole body, with the
  `-U` clause that a NUL the slice model never reads leaves the file text - so the
  listing rule and the emit rule are one rule again. It also honors `--null-data`
  now (`writ.binaryDetect`'s third flag), where NUL is the line terminator and
  therefore not evidence of anything.

  Parallel had the gap in the other direction. `gateMiss` - the whole-file literal
  gate proving the pattern absent - listed the path in this mode with no binary
  question asked at all. Stage 1's prefix sniff hides that most of the time by
  returning before the gate runs, but not always: a NUL in the TAIL of a >64 KiB
  file is past the sniffed prefix, and a transform run (`-E`/`-z`) reads the whole
  file through `ingest` and skips stage 1 entirely, which is why `-E utf-8` was
  enough to make gist list four binaries rg suppresses. The two arms now share one
  `binaryCut` definition, so which side of the gate a file arrives on cannot change
  whether it is listable - the file still carries the exit code through
  `Sink.unlisted`, since its abandoned search did find no match.

  This was the last of the fuzzer's `--files-without-match` residual: seed 20260727
  at 6000 iterations drops from 13 divergences to 9, and the `line-count+exit`
  class is gone entirely.
- `--files-without-match` now exits 0 over a tree whose only walked file is
  binary, which is what ripgrep does. It used to exit 1.

  I had this one filed as a ripgrep self-contradiction, and it is not. rg prints
  no path for a walked NUL-bearing file - its Summary printer refuses to list a
  file whose search it abandoned - and yet exits 0, so the stream says "none" while
  the code says "found". Read as "0 iff a path was listed", that is incoherent, and
  gist's exit 1 looked like the coherent answer.

  But that is not the question rg's exit code answers. `SummarySink::has_match` for
  `PathWithoutMatch` is `match_count == 0`: the success condition is "some file's
  search found no match". An abandoned binary search found none, so it counts. The
  printer's refusal to LIST an unproven file is a separate rule, which is exactly
  why the two part company on this one file shape and agree everywhere else. rg is
  answering a different question, coherently, and gist was answering the wrong one.

  So the verdict now rides back from the per-file decider rather than being read off
  the emitted bytes. `render.fileWithoutMatch` returns whether the file's search
  found no match - true for the suppressed binary, true for a listed text file,
  false only for a file that HAS the pattern - and both engines fold it: the serial
  loop ORs it across files (and through the sharded driver, where a shard holding
  only binaries emits nothing yet still carries the run), and the parallel engine
  banks it in a `Sink.unlisted` counter kept apart from `matched_files`, because
  that counter doubles as `--stats`'s `files_with_match` and a suppressed binary
  contained no match. `Sink.succeeded()` is the one place the two are read together.

  Fixing this also surfaced that `--files-without-match -q --stats` printed nothing
  at all: the quiet branch cleared the whole stream, block included, where rg prints
  its trailing block under `-q` in every mode. The path list is what `-q` drops.
- `--one-file-system` does something on Windows now.

  The Windows stat leg reports every field `RawStat` projects except a volume id, so
  it reported a constant `0` and the flag compared `0 == 0` forever: never pruning,
  on any tree. Documented as a deliberate under-filter, which is the right failure
  direction and still leaves the flag inert on a platform where ripgrep's walker
  honors it — `walkdir` compares the volume serial there.

  Volume identity is now its own entry point, `inode.devicePath`, rather than a
  `RawStat` field. That is what keeps it free: Windows answers it from a *different*
  query than the rest of the projection, so folding it in would have taxed every stat
  in the walk — and the freshness overlay's — to serve a flag that is off by default
  and, when on, is consulted once per directory. POSIX keeps paying nothing, since
  `st_dev` already rode along.

  It reads `FILE_ID_INFORMATION`, not `FileFsVolumeInformation`. The latter is the
  obvious choice and is the one Wine answers `STATUS_NOT_IMPLEMENTED` — which the
  first cut shipped, and which a unit test running under the Wine lane caught as a
  null id, i.e. as the same silently-inert flag in a new disguise. It is also the
  better id on its merits: 64 bits where the volume-information struct carries 32,
  and one fixed-size query where that struct trails a variable-length label. A
  volume that declines to answer still yields null, so the failure mode stays "stops
  pruning" rather than "prunes wrongly".

  Both halves are asserted, because a platform query that quietly stops answering
  breaks this flag invisibly: an id must exist, and it must be the *same* id for two
  paths on one volume. Cross-volume discrimination stays a real-Windows claim — Wine
  reports serial 0 for every drive in the container, so the lane can prove the call
  answers and cannot prove it discriminates.
- `--rank`'s file set is now the walk's, so it equals the same query's `gist -l` set by construction. The ranked view used to enumerate candidates out of the persisted index's path table, which made the index answer "what is in the corpus" instead of "which of these files can possibly match" (fault-channel law 1). Three things fell through that seam: `-t`/`-T`/`-g`/`--iglob` and the `--docs`/`--code`/`--data` genus flags were re-derived from positional roots alone, so `gist -t ts pat --rank` ranked every language in the corpus and printed rows byte-identical to its own negation `-T ts`; the index's corpus policy prunes `vendor/`, so on a tree carrying a large vendored subtree a ranked query silently dropped 470 real hits; and no walk-widening flag reached the view at all, so `-uu` — whose walk admits ~15x the files — ranked the default corpus and called it an answer. The lens now ranks the bytes the walk gathered, still index-ACCELERATED through read elision, and the superseded indexed tier is gone.
- `--stats` no longer faults in a whole binary file to re-find a NUL it already
  found. Stage 1 reads the first 64 KiB of every file to decide binary-ness, and a
  plain run stops there. Under `--stats` the run reads on, because the tally has to
  report bytes searched and the emitter has to name the file - but everything either
  one needs is bounded by that first NUL. `committedPrefix` returns at the fill that
  read it, so both the searched region and `handleBinary`'s emitted region lie inside
  the prefix, and `multilineBinary`'s verdict (`nul < min(len, BUFCAP)`) answers the
  same for the prefix as for the whole file, so even the `-U` arm is unchanged. The
  tail was paying for nothing.

  It was paying a lot. `gist -uu --stats` over `.git` cost 2.26 s against 0.02 s for
  the same query without the flag - a 100x tax on asking for a byte count - because
  every pack file in the repository was read end to end. It is now 0.02 s either
  way, and the tally is byte-identical to ripgrep's on the same tree: 1218 files
  searched, 2,048,128 bytes searched, matching and non-matching patterns alike.
- `--vimgrep` rows now come from one shared shape (`display.vimgrepLine`) instead of a copy in the physical-line driver and another in the `-U` whole-buffer driver. The two copies had drifted into four ripgrep parity gaps, all closed: `-M/--max-columns` reports the line's match count (`[Omitted long line with N matches]`) as rg's per-match printer does; `-r` recomputes columns against the replaced text; and `-U -r` both applies the replacement to the row and keeps its `-A/-B/-C` context window, measured against the replaced block rg re-splits (rg #1311). The one legitimate difference between the drivers — rg reports the match's `--byte-offset` from a line-oriented sink and the printed line's from a `-U` block sink — is now a declared field rather than an accident.
- `-w` diverged from ripgrep on any pattern that can match empty, in two opposite directions at once. The span filter was too permissive: it read the neighbor as a boundary _assertion_, so `-o -w 'x*'` emitted rows at byte offsets inside a multi-byte codepoint (three spurious rows inside the em-dash of `a—b`), where rg's `-w` is `(?:^|\W)…(?:$|\W)` and needs a real non-word codepoint to _consume_. The line verdict was too strict: it asked only whether a NON-EMPTY word-valid span existed, so `-c -w 'x*'` dropped every line carried by a word-valid empty match — rg selects `a  b` on the gap between its spaces and `.dot` at the line start, gist selected neither, an 8× undercount on the differential corpus. `wordOk` now lives once in `syntax/word.zig`, distinguishing "no codepoint here" from "a non-word codepoint here", and both the cold printer and the warm query walk spans through the same rule, so `-o`, `-c`, `--count-matches`, and `--column` agree with each other and with rg across the 168-combination flag matrix.
- `-w`/`--word-regexp` no longer misses a match ripgrep finds. The word boundary
  is now part of the language the engine searches for, not a verdict passed over
  the span it already settled on.

  `rg -w -o -e 'abc|abcd'` over `x abcd` prints `abcd`; gist printed nothing. The
  cause is where the rule lived. gist compiled the bare pattern, let the engine
  settle leftmost-first on `abc` at offset 2, then asked `wordOk` whether that
  span was word-bounded. It is not - a `d` sits right after it - so the offset was
  abandoned and the scan resumed past it. But the offset was fine; only that ARM
  was wrong, and `abcd` at the same offset is a match. A vet that sees one span
  per offset cannot express "try the next arm here", so every pattern whose greedy
  arm ends inside a word lost the shorter admissible one behind it.

  ripgrep does not vet. `grep-regex` sets the `word` config, which rewrites the
  pattern into `\b{start-half}(?:pat)\b{end-half}` before compiling, so the
  assertions are inside the program and the engine's own backtracking finds the
  admissible arm. gist now does the same rewrite, on the parsed root rather than
  the pattern text (`syntax/scalars.zig::wordBoundedAst`), which makes the
  precedence free: `-w 'a|bc'` binds the alternation, never just its first arm.
  The linear arm gets the two `.word` assertion nodes it already had for `\b`; the
  PCRE2 arm gets a `(?<!\w)(?:pat)(?!\w)` wrap, with the error caret discounted by
  the lead so a bad pattern still points at the byte the user typed. Both arms and
  both capture VMs read one option, so `-r`/`--json` cannot drift from the match.

  It is the HALF boundaries, not `\b(pat)\b`. `rg -w -o -e -` finds the dash in
  `foo - bar` where `\b-\b` finds nothing, and finds no dash in `foo-bar`: a half
  boundary judges the neighboring byte, not the span's own first byte. gist
  agrees on both.

  The vet stays for the `.literal` body, where there is no program to rewrite and
  a single literal has exactly one span per offset - the case the vet was always
  right about.

  The rewrite is also faster than the vet it replaces, which is the answer to the
  obvious worry about putting work inside a hot flag. Measured against a pre-fix
  binary built from the same tree, `-w -c` over one 211 MB body where every line
  matches (hyperfine, 5 runs, `--no-index` so the trigram gate cannot mask the
  engine): a literal word 484.3 ms -> 171.4 ms (2.83x), `fn \w+` 226.0 ms ->
  191.9 ms (1.18x), `abc|abcd` 333.3 ms -> 242.6 ms (1.37x); the counts are
  identical (2,400,000 lines each) and match rg's, so it is the same work. The vet
  paid a second span search per candidate offset; an assertion the DFA already
  knows how to fail costs nothing.

  That said, `-w` is still the flag where ripgrep is ahead of us on that corpus -
  100-113 ms against our 170-243 ms - and it is `-w` specific: without the flag the
  same literal is 21.4 ms against rg's 54.8 ms. `-w` puts a literal body on the
  regex path and off the single-file sharded literal scan. That gap is older than
  this fix and this fix halved it; closing it is a separate change with its own
  measurement.

  The pinned regression covers the alternation cases in both arm
  orders, the punctuation half-boundary pair, and the control that separates a fix
  from an overcorrection: a pattern whose every span is word-internal must still
  find nothing.
- `TestColdSurfacesStats` failed the moment the resolver let it run, and it was
  right to.

  The verb summary counts whole milliseconds, so a recall over a three-file
  fixture reports `"ms":0`, and the cold tier handed that straight back as
  `Stats.Elapsed` - a zero duration for an answer that demonstrably cost a process
  spawn. The in-process tier reports nanoseconds for the same verb, so the two
  tiers disagreed about whether any time had passed, which is the one thing a
  ladder of tiers is not allowed to do.

  The child's measured wall clock is the floor under `Elapsed` now. A summary that
  does report time still wins, because it is the finer account of where the time
  went; when it reports nothing, the caller gets what it actually waited instead
  of a zero.

  The test was not touched.
- `\B` no longer matches inside a character. Over the line `a—b` it reported two
  matches, at the gaps between the em dash's three bytes; rg reports none, and rg
  is right — those offsets are not positions in the text.

  The cause is that "is the character before me a word character?" answers *false*
  for a comma and for half of `é` alike, and an assertion that fires on silence
  cannot tell the two apart. Every such assertion — `\B` and the two new halves,
  which are exactly the masks admitting the all-quiet pair — now also asks whether
  each side it reads is a whole character. `\b`, `\<`, and `\>` need no guard and
  pay for none: firing requires a word character on some side, and a word
  character is a whole one. Under `(?-u)` no decode is attempted at all, so the
  ASCII path is untouched.

  Both determinized engines quit rather than represent the new case, which is the
  strategy the byte-class DFA already used for Unicode word context: the caliper
  now declines a line at the first gap that splits a character and hands it to the
  Pike VM. 960 comparisons against rg across six output modes — valid multi-byte
  text, combining marks, CJK, Cyrillic, and invalid UTF-8 — now agree exactly.
- `bench/rungs/sliver/artifact/scale_race.json` was tracked in git with its
  `corpus` field set to an absolute path on the machine that minted it, so the
  artifact published a username and the interior layout of the private monorepo
  this package was extracted from. It now records what the corpus **was** rather
  than where it sat: shallow clones of linux, llvm, go, rust, **352316 files on
  disk**, **5.5 GiB incl. VCS metadata** - the same description `scale_build.tsv`
  already carried one file over. That build lane's own header gave the corpus a
  scratch path too, and now says only that the four clones sat under one corpus
  root.

  The bench and vendor prose had the softer version of the same problem: four
  citations pointing into a per-experiment scratch directory a reader outside
  that repo cannot open. Each pointer is replaced by what the spike
  established, so the claim can be judged where it stands.

  The patternid rung no longer says it gates a document you cannot read; it says
  what it gates and how the gate came out. Attribution, overlapping matches, and
  an end-only HalfMatch stream are one mechanism seen three ways, all riding one
  ratio, and the design scan read rust-regex's determinizer, dense DFA, NFA,
  search, and overlapping/half-match paths before settling the shape and leaving
  exactly one thing unmeasured: whether widening the state key multiplies states.
  It does not. **1.017-1.121** over six slates, worst on `kin-8`, the slate built
  deliberately adversarial out of eight patterns that share both prefixes and
  suffixes. The sliver README and the Pareto artifact now name the instrument
  instead of its path: a standalone probe over gist's own trigram directory,
  **19,440 documents** and **188.2 MiB** at a 256-byte block, pricing every
  `(trigram, document)` posting once with a real delta+varint encoder and
  bucketing by document frequency so `cost(T)` is a prefix sum rather than a
  re-run per threshold. The vendored libsais note describes the harness that
  priced OpenMP and declined it: the same translation unit built twice from one
  `build.zig`, once plain and once with `-DLIBSAIS_OPENMP` against Homebrew
  `libomp`, timed inside the real codex pipeline over a 200 MB corpus at min of 2
  reps, with the adapter identity proved byte for byte on every arm and the
  thread-scaling table taken only once the box went quiet.

  No measured value moved. The three files under `artifact/` changed in their
  comment headers and in that one `corpus` string, and nowhere else. `.local/`
  stays this repo's scratch convention; only the per-experiment citations went.
- `bench/rungs/sliver/scale_race.py` could not start. It reached for its verdict
  math at `bench/certificate/report/stats.py`, and the certificate is a `gist`
  concern that went to `gist` in the split - so the `sys.path` entry pointed at a
  directory this package does not have, and the script died on `No module named
  'stats'` before parsing an argument. Nothing downstream could fix it either:
  `gist` depends on this package, not the reverse, so there is no import path back.

  The statistical core - Type-7 quantiles, bootstrap-CI medians, and the
  tie-corrected Mann-Whitney dominance call - now lives at
  `bench/apparatus/stats.py`, beside the Zig instruments it mirrors, for the same
  reason those are there: a rung in this package has to be runnable from this
  package. The certificate keeps its own copy, and the bodies are byte-identical,
  so a class judged here and a class judged over there still mean the same thing.

  `bench/apparatus/test_stats.py` is the guard against that stopping being true.
  Its expectations come from the definitions - what Type-7 says the median of an
  even-length sample is, and what a fail-closed verdict has to do with identical
  distributions - rather than from a run of the module beneath it, because a twin
  checked only against itself can drift while both halves keep agreeing.

  Also fixed while proving the script ran: the race artifact recorded the corpus
  as whatever absolute path was passed, which published a home directory into a
  committed file. `--corpus-label` now records what the corpus *was*, defaulting
  to the directory's leaf name, which cannot carry one.
- `check-linux` and `check-windows` were passing without looking at the engine,
  and I only found out because I wrote a third one and it failed to catch a bug I
  had just watched a real build catch.

  Both steps built an `addObject` rooted at `src/root.zig`. Zig analyzes what a
  compilation reaches, and an object that exports nothing reaches almost nothing:
  the module's `pub` decls are lazy, so Sema stopped near the top and the step
  went green. The proof is a side-by-side. With the arch-shaped `lanes.native`
  regression in place, `zig build -Dtarget=aarch64-linux-gnu
  -Dcpu=baseline-neon` - the real library - failed with the `shufflePair`
  compile error, while the cross-check object for the same target passed on a
  cold cache. A portability gate over code it never read.

  The shipped `libirgx` is rooted at `src/surface/ffi/exports.zig`, not at
  `root.zig`, for its own unrelated reason (an `export fn` is emitted by every
  compilation that reaches it, so the shims live in the artifact's root to avoid
  duplicate symbols in `libgist`/`librelate`/`libblast`). That turns out to be
  exactly what a check needs too: `export fn` is what forces Sema down into the
  kernels. All three cross-checks now build the same two-module shape the artifact
  does - the engine over `root.zig`, the object over the export surface importing
  it - so they analyze what the library analyzes.

  They stay green at the new depth, which is the part I was least sure of.
  Deepening a gate that was never really running usually means finding out what it
  would have been saying; here it means the Linux and Windows legs were fine all
  along and only the gate was hollow.
- `contract/search_api.toml` declares three deliberately independent version axes, and one of them had quietly fallen out of step. `engine_version` is defined as a mirror of `src/root.zig`'s `version_string` and `build.zig.zon`'s `.version`, but only those two carried the `x-release-please-version` marker, so when the release bot moved the engine to `0.3.0` the contract stayed at `0.2.0` — and with it the Go, Python, and Rust binding mirrors that take the contract as their oracle. The parity tests that exist precisely to refuse this were skipping on an unresolvable path, so a stale minor rode through a whole release unremarked. The marker is now on all three, and the comment describing the axis says why it is there.
- `gist -l` no longer skips the first 64 KiB of a file whose first 64 KiB holds no
  newline, and `--files-without-match` no longer swears such a file has no match
  when it does.

  One 100 KB line with `fn` near the front, and `rg -l` listed it while gist said
  nothing; inverted, gist affirmatively published the file under
  `--files-without-match`. The cutover bisected to exactly `BUFCAP - 1` for a
  two-byte literal - found at offset 65535, missed at 65534 - which is the tell
  that a gate was starting at 65535 rather than 0.

  The cause is two questions with one answer between them. Stage 1 runs two scans
  over the first `BUFCAP` bytes: a NUL sniff across the whole prefix, and the `-l`
  literal proof across only `provableRegion`, the prefix cut at its LAST newline.
  That cut is right and stays - a stage-1 proof must not claim to have reached
  past the last terminator ripgrep committed. But `covered` recorded the NUL
  sniff's extent, and the whole-file literal gate derived its start from
  `covered` too. With no newline in the prefix, `provableRegion` returns null, the
  literal proof reads zero bytes, and the gate was still told to begin at 65535 -
  skipping 64 KiB nobody had looked at. Only `-l` and `--files-without-match` ride
  that gate offset, which is why `-c`, `-n`, `-o` and the default mode were fine.

  I did not fix this by computing `provableRegion` a second time at the gate. Two
  derivations of one fact drifting apart is the bug, and writing a second one down
  just arms it again. Stage 1 now reports what it read: `provePrefix` returns a
  `Proof` of `{ matched, read }`, and `read` - raw prefix bytes the proof actually
  looked at, zero when nothing was provable - is the only thing the gate is
  allowed to skip past. `covered` and the new `proven` now sit next to each other
  with a comment saying out loud that they answer different questions.

  Instrumented, a file whose prefix has terminators still reports
  `covered=65536 proven=65520 gate_from=65518`, so the optimization is intact and
  this is not a "rescan everything" retreat; the same file with no newline in its
  prefix reports `proven=0 gate_from=0`, which is the only sound answer. Every
  offset from 65400 to 65700 now agrees with real rg for `-l` and
  `--files-without-match`, as do an eight-byte literal across the straddle window,
  caseless, pure alternations, `-F`, `-U`, a leading UTF-8 BOM (the offset shifts
  by three, and it now shifts correctly), and the no-match control. The stage-1
  terminator-bound test this sits beside still passes.
- `gist index` and `gist serve` no longer treat a mistyped flag as a directory. Both verbs appended every remaining argv token to their root list without looking at it, so `gist serve --detach` asked for a root literally named `--detach` (which is where that `No such file or directory (os error 2)` came from) and `gist index --help` asked for one named `--help` instead of printing help. A root that resolves to nothing then sent each verb down its worst branch while reporting success: `serve` fell back to a resident session over whatever directory you were standing in, and `index` wrote the empty result over a working index - so a single typo took a 2-file index to `no index at … run 'gist index' first`, exit 0, and silently demoted every later query to a live scan. Both now honor `--help` and exit 2 naming the flag they did not recognize, which is the fail-loud contract the search path has always had. A bare `-` is still a root, the stdin spelling.

  The two loops collapsed into one `collectRoots` helper rather than being fixed twice, since "collect trailing `[ROOT...]`" is one contract with one right answer. Every verb now rejects an unknown flag with exit 2 (`index`, `status`, `serve`, `search`, `rg`, `config`, `codex` - audited, not assumed). `--help` itself is still uneven: `index`/`serve`/`search`/`rg` answer it, while `status`/`config`/`codex` fail loud with exit 2 instead. That is a papercut rather than a hazard, and it is left alone here.

  Pinned in `bench/conformance/gates/contract/fail_closed.sh`, which already owned "an unknown flag must fail loud" for the search path and now owns it for verbs. The cases assert an exact exit code instead of reusing the gate's `bad` helper, and that detail is the point: `bad` accepts any exit >= 2, so it would have read the old quiet exit 0 as a failure for the wrong reason and a timeout kill as a clean rejection. One case asserts the damage rather than the symptom - that a rejected `index` flag leaves the index intact - because the exit code was never what hurt. Both detectors were verified to actually catch this by rebuilding binaries with each bug restored: the unknown-flag case reported exit 0 against a contract wanting 2, and the survival case reported `index was 'indexed 2', after a rejected flag status says '<gone>'`. The `--help` cases pass on the buggy binaries too, so they are recorded as pinning the contract rather than as coverage of the regression, and everything runs under a `timeout` guard because the worst-case signature here is a daemon that never returns.
- `irgx_is_match` and `irgx_find_all` disagreed about every anchored
  pattern. `c$` over `"abc\n"` was a match to one and no match to the other; so
  were `^a` over `"\nabc"`, `\Aabc\z` over `"x\nabc\ny"`, and 19 of 54 probed
  pairs. Two independent bindings hit it while being written, and both had to
  route their predicate through `find_all` to get one answer out of the library.

  `is_match` was riding the boolean *document* kernel, which is the faster
  routine but answers a different question: it splits a buffer into lines and
  asks whether any line matches, so `^` and `$` become per-line anchors. In this
  plane the buffer IS the unit - there is no corpus behind it - so those are its
  ends, which is what `find_all` and `captures` already said. It now runs the
  same walk `find_all` runs, stopped at the first span.

  Which meant giving the kernel one walk instead of two. `collectSpans` and the
  new line-scoped `holds` predicate share `walk`, whose only difference is
  whether there is a sink to append to; a null sink returns at the first span.
  The empty-match, adjacency and `-w` rules are subtle enough that a
  hand-written second version is precisely how a predicate starts disagreeing
  with the list it summarizes, which is the bug above. An iterator would have
  been the obvious shape and is the wrong one here: splitting the walk into an
  inner and an outer loop cost a measured 2.5% on short matches, and 3.8% on a
  nullable pattern once inlined to win the first back. `walk` is `inline` with
  a comptime-known sink instead, so each caller still compiles to the single
  tight loop, measured at parity on both shapes.

  Also: `irgx_compile` rejected a NULL pattern of length zero, though the
  empty pattern compiles fine and every search verb already reads NULL with
  length zero as the empty text. A language whose empty string carries no data
  pointer, like Go, hands that in without meaning anything by it.
- `irgx_last_fault` now clears the struct when there is no fault, instead of
  leaving your own stack in it.

  It used to return `IRGX_OK` and touch nothing, which sounds harmless and
  isn't: a host that cleared only the field it went on to test kept whatever
  garbage was in the rest, and nothing downstream could tell that `at` had never
  been set. Two bindings independently had to defend against it, which is the tell
  that it was the seam's problem and not theirs. So the seam does it once - every
  field zeroed, and `name` goes to `""` rather than NULL so it keeps its promise.

  While I was in there I wrote down the rule both of those bindings had to work
  out for themselves: don't follow an `IRGX_STALE` with a fault read. A
  declinature installs nothing, the slot is per-thread and never consumed, so what
  you'd get back is an *earlier* call's fault wearing a fresh face. Decide a
  declinature from the status code and stop.
- `libirgx.a` was only self-contained on macOS, and by accident. The installed
  ELF archive held this package's Zig objects and nothing else, so a consumer who
  linked it got undefined `pcre2_compile_8` and friends and had to go find two
  more archives the build never installs. Darwin escaped it because `ld64`
  rejects the member alignment `zig ar` writes, so that arm already repacked
  through `libtool -static` - which archives a partially-linked object, which
  pulls the C floor in. The workaround happened to be the fix.

  That accident is now the design. Both platforms pack the archive from
  `addObject`, and only the archiver differs: `libtool -static` on Darwin for the
  alignment, `zig ar` everywhere else, which is the compiler already in hand
  rather than one more host tool to have installed. The ELF archive now defines
  70 PCRE2 and libsais symbols and references none of them undefined; a C program
  built with nothing but `zig cc c.c libirgx.a` links and runs on both platforms,
  where the Linux side previously did not link at all.

  Three consumers stop routing around it. The Rust `build.rs` had its source
  rungs link the shared library and burn an rpath, purely because a static link
  could not work on ELF; they link the archive now, like the vendored rung
  always did. The Go and Rust vendoring scripts each carried a merge step that
  read `libpcre2irregex.a` back out of a Zig build cache by glob and folded it in
  with `zig ar -M`; both are gone, and the PCRE2 symbol probe they used to branch
  on is now a precondition that fails loudly, because an archive arriving there
  without its floor is a regression in the build rather than a platform to
  compensate for.

  One thing the archive fixed exposed another. `-l static=irgx` does not actually
  mean static when the search directory holds `libirgx.a` beside
  `libirgx.dylib`: `ld64` takes the dylib, so pointing `IRGX_LIB_DIR` at an
  install prefix - the exact shape of `zig-out/lib` - produced a dynamically
  linked test binary with no rpath to find its library at run time. The archive
  is staged alone into `$OUT_DIR` and searched for there, so the linker has no
  choice to get wrong.
- `parabix/README.md` blamed the ~3× gap against the research lane on the generic class-circuit interpreter — "a gate whose two operand references are runtime values cannot keep its basis in registers, so each gate pays ~16 vector loads and 8 stores around 8 ALU ops." That sentence is about `.fallback` circuits, and **not one row of the measured table above it executes one.** Every class in the benchmarked family is a single byte or a couple of contiguous ranges, so its shape is `one`/`ranges1`/`ranges2` and `Circuit.eval` returns before the gate loop. `Scratch` and the per-gate dispatch are dead code for exactly the patterns the ~3× was measured on, which made "closing it needs a specialized emitter" a plan to specialize something the bench never runs.

  The class phase does spill, and the cause is the grain rather than the operand refs. `plane.Wide` is eight q-registers, so a `[8]WideBasis` is **64 of a 32-register file** before a single class output is held live beside it. Compiling a comptime-specialized `between` with every bound baked in — no dynamic refs left at all — still spills at stripe grain: **6 spills per block for `[a-z]`, 25 for `[0-9A-Z_a-z]`**, against **0** for both at block grain, with per-block vector work identical across grains (1.00–1.02×). Statically the inlined striped path carries **3,224 spill instructions against 6,446 vector ops**, where `Parabix.block` carries 22 against 1,099. Counted per `.cfi` proc out of `zig build-obj -femit-asm`, so these are instructions, not cycles.

  The obvious next step — run the class phase at block grain, since catalogue shapes have no dispatch to amortize — is the one `plane.zig` already refuses, and its ladder was measured with the shape catalogue in place, so whatever the stripe buys those shapes is already inside the 7.62 GB/s. That attempt was built and reverted unbenched, and what it left behind is a second refutation in the comment rather than a second silent rediscovery: the register-file argument has now been derived twice and lost twice, and this constant moves on a phase-ladder measurement or not at all. `research/ceiling/CLOSED.md` entry 1 carries the coefficient a DFA→cascade front-end would need out of this lane — `parabix_op ≤ 0.444` — pinned by a Doc Radar sentinel so a re-mint fails the gate instead of quietly staling the verdict.
- `pmu.zig` read hardware counters through exactly one backend - Apple's private
  `kperf` - and that backend is root-gated. So on any machine where `sudo -n`
  doesn't answer, every benchmark in the repo silently fell back to wall-clock. A
  24-mechanism profiling baseline came back with zero measured cycle counts, which
  meant the ladder auction's cost model couldn't be re-priced and no claim in the
  certificate could be stated in cycles/byte.

  The gate is not the framework load, which is worth stating because it's the
  natural guess. `dlopen` of kperf succeeds fine unprivileged; the refusal is the
  first counter call. In xnu every `kpc_*` call routes through `ktrace_read_check()`,
  which passes for the blessed pid or for euid 0 and returns `EPERM` for everyone
  else, so `kpc_force_all_ctrs_get` is where an unprivileged run actually dies.

  The fix isn't privilege. macOS has an unprivileged per-thread counter syscall,
  `thread_selfcounts`, that returns retired cycles and instructions for the calling
  thread, and it was simply never wired up. `pmu.zig` now tries three backends in
  order - `kperf`, then `thread_selfcounts`, then honest wall-clock - so the numbers
  the certificate quotes need no password at all. `zig build roofline` reports
  3.938 GHz measured and 0.4773 cyc/byte DRAM on an M4 Max with no sudo anywhere in
  the picture.

  Backends are not interchangeable and the reports no longer pretend they are. The
  roofline's `meter:` and `clock:` lines were hardcoded to credit kperf; they now
  name whichever backend actually answered, so a number can't quietly change
  meaning when the tier underneath it does. Seven tests hold the new backend to its
  contract: that a meter is either honestly instrumented or honestly wall-clock,
  that counters advance across real work, that they measure work rather than
  elapsed time, that a busy neighbor thread can't inflate them, and - the one that
  catches a struct-layout drift the coarse IPC bound would miss - that an undersized
  read is refused rather than half-filled, since the kernel will otherwise fill only
  what fits and report success.

  What privilege still buys is kperf's *configurable* events - cache misses, branch
  mispredicts, port pressure - and nothing else. For that residual case
  `bench/apparatus/privilege/` stages a helper that gets blessed, drops privileges
  irrevocably, and execs the benchmark as the invoking user, behind a digest-pinned
  sudoers rule on a root-owned path. It is staged and documented rather than
  recommended: its README says plainly that the ask that motivated it is now moot,
  and that a standing NOPASSWD grant on a machine running ten autonomous agents
  isn't worth a convenience none of the current claims need.
- `portal.realpath` returned native `\` separators on Windows, into a codebase
  whose entire path vocabulary is `/`. The walker already normalized its own output
  before an ignore rule or a depth count saw it, but the resolver did not, so
  anything downstream that split on `/` read a resolved path as a single component:
  `delta.keyFor` could not derive a dirty-log key, which made a scoped reconcile
  key on the whole path and symlink identity compare unequal to the same file
  reached another way. It now normalizes non-UNC results the way the walker does,
  so one path spelling means one thing on both platforms. `--path-separator` still
  renders native `\` on request; that is a presentation choice at the edge, which
  is where it belonged all along.
- `requires-python` said `>=3.10`, and that was a claim the package could not honor. The runtime uses PEP 695 generic syntax (`def mixin[C: type]` in `runtime/decode.py`) and PEP 695 `type` aliases, both parse errors before 3.12, and `contract/grades.py` imports `StrEnum`, which is 3.11. So `pip install irregex` on 3.10 or 3.11 succeeded — metadata admitted it — and then raised `SyntaxError` or `ImportError` on the first import. The floor is now `>=3.12`, which is what the code has always required, with 3.12/3.13/3.14 declared as classifiers.

  The failure mode is the reason this matters more than a version bump: a wrong floor does not degrade, it lies. Installation is the moment a user can still choose a different library, and metadata is the only thing that speaks then. Proven both directions against a built wheel — a bare 3.12 venv installs it and runs compile/search/findall/split off the bundled library, and 3.10 now refuses at resolve time with `requires a different Python: 3.10.20 not in '>=3.12'` instead of failing after the install looked fine.
- `vendor/libsais/README.md` claimed OpenMP bought **1.65×** on the suffix sort and
  saturated at 8 threads. Neither half survives the dossier it came from. The
  figure 1.65 does not appear anywhere in the evaluation, and the one table that
  does exist reports serial libsais at 5949 ms against parallel arms of 7647 ms
  (4 threads), 10471 ms (8), 6512 ms (12), and 5662 ms (16). The best arm is
  therefore about 1.05× over serial, not 1.65×, and the 8-thread arm the README
  named as the saturation point is the slowest of the four and slower than serial.

  The numbers also do not increase with threads, which is the tell: they were taken
  on a box with other tenants on it, and `omp-scale.sh` was written specifically to
  retake them in a quiet window. It never caught one - its output file is empty -
  so no trustworthy thread-scaling table for this dependency was ever captured, and
  the README should not have described one as taken.

  The decision this passage exists to justify is unaffected, and is in fact better
  supported than the wrong number made it look: five percent on one phase does not
  buy a `libomp`/`libgomp` runtime that every build host, cross-compile target, and
  CI image would have to carry. The README now states the measured figures, credits
  the pin to the serial path (5949 ms against 15304 ms for Zig's own `sais.build`,
  2.57×), and says plainly that the scaling question is still open. The same claim
  was repeated in an unreleased changelog fragment, which is corrected in place so
  it does not ship.

## [0.2.0] - 2026-07-24

### Added

- A SIMD class-run kernel for dense character classes
  (`src/kernel/scan/classrun.zig`) — the family the byte-class DFA was
  slowest on. A pattern that _is_ a class repetition (`\w+`, `[a-z]{3,}`,
  `[0-9a-f]{8}` — decided algebraically by `analysis.classRunShape`) is no
  longer an automaton problem: boolean match reduces to "≥ min consecutive
  members of one byte set", classified 64 bytes at a time (two-compare range
  lanes for ≤ 4 contiguous ranges, Hyperscan-truffle nibble shuffles otherwise;
  on aarch64 the four chunk verdicts fold into the block mask via the simdjson
  `addp` chain instead of per-chunk movemask ladders) with shift-AND run
  detection and a cross-block carry — load _bandwidth_ instead of the DFA's
  loop-carried load latency. Unicode codepoint classes go further than a
  projection: the analysis carries the class's full codepoint ranges, so the
  kernel resolves ≥ 0x80 spans itself (scalar UTF-8 with an inlined 2-byte
  decode + a direct ≤ 0x7FF membership bitmap; ASCII blocks stay pure SIMD) —
  Unicode `\w{3,8}` compiles skip powerset determinization exactly like `(?-u)`
  ones (was ~168 ms of dead-weight subset construction per compile), and no
  verdict ever defers. The kernel also ships a STREAMING whole-buffer
  `countLines` (rg `-c` line model): membership and newline masks from one
  pass, lines settled with segment bit-tests — no `memchr` re-read, no per-line
  restart — and the emit layers answer `-c`/`-l` for these patterns from the
  whole buffer with no line split at all. The kernel also EXTRACTS spans:
  `analysis.classSpanShape` proves the strictly stronger window rule — for a
  concatenation of same-class quantifiers (`\w+`, `[a-z]{3,8}`, `\w\w+?`;
  alternations/anchors decline), the leftmost-first match at `p` is exactly
  "run(p) ≥ min, cut at lazy ? min : min(run, max)" — so `nextSpan` chunks
  member runs straight off the membership masks (codepoint-counted,
  byte-addressed in Unicode mode) and
  `-o`/`--count-matches`/`--column`/`--vimgrep`/`--json` never run the Pike
  VM's per-byte thread closures for these patterns; a fused whole-buffer doc
  pre-gate settles span-mode misses without walking a single line. `force_dfa`
  keeps the determinizer's own proof harness honest. Held by scalar-oracle
  differential fuzzes (boolean, per-line count, codepoint-mode with junk-byte
  corpora, and byte/codepoint span-window fuzzes — all on both backends), a
  kernel-vs-Pike `matchSpan` iteration fuzz, and the 446-case rgsuite at 100%
  parity on both engines. Measured vs ripgrep 15.1.0: dense `-c '(?-u)\w{3,8}'`
  2.4–2.8× faster (was 1.5× _slower_), Unicode-mode `-c '\w{3,8}'` 2.5× (was
  **8.5× slower**), miss-heavy Unicode `-c` 1.7× (was 19× slower), miss-heavy
  `-c`/`-l` 1.7–2.0×, a 50%-non-ASCII adversarial corpus 1.12×; spans: dense
  `-o '\w+'` 1.8–1.9× (was 3.1× slower), Unicode `-o '\w{3,8}'` 1.9–2.1× (was
  **~100× slower**), `--count-matches` 1.9–2.2×, miss-heavy span modes at
  parity.
- A fused parallel walk+read corpus loader (`corpus/tree/loadpar.zig`), now the
  default path for every build verb that funnels through `corpus.load` (`gist
  index`, `relate index`, `codex build`). The serial loader walked one
  directory at a time with a single cursor for the whole tree — ~⅓ of the
  index-build wall clock, but every core but one idle. The new loader fuses
  walking and reading into one work-stealing pipeline: each worker pops a
  directory, opens it ONCE, and reads that directory's member files through the
  still-open directory fd (`openat(dirfd, name)` — one-component namei) before
  donating its surplus subdirectories to idle peers. On the whole-repo corpus
  (20,497 files · 196 MiB) that cuts the index build from ~1.78 s to ~1.39 s
  (~22%), with the load phase itself dropping ~575 ms → ~170 ms; 8 workers is
  the sweet spot (the walk is syscall/namei-bound, so 12/16 add contention
  without shortening the tail). Membership is byte-identical to the serial
  `haystack.Walker` by construction — the ignore verdict comes from the SAME
  `ignore.zig` rule core (a frozen base `Ignore` plus the immutable
  per-directory `IgNode` chain each worker builds as it descends — the
  parallel-walk plumbing now lives in `ignore.zig`, one source shared with the
  search engine so the two walkers cannot drift), directory pruning applies
  `haystack.isSkipDir` then the ignore verdict in the same order, and file
  admission reuses the shared `corpus.per_file_cap`/`corpus.isBinary`
  predicates. Doc ids are assigned by sorting on path, so the build is
  deterministic run-to-run (reproducible index bytes) despite the
  nondeterministic walk order. A hermetic fixture test pins the parallel
  membership to the serial oracle across gitignore
  (anchored/slash-less/negated), nested per-dir ignores, hidden files, the
  build-dir skip list, binary, empty, and oversize files.
  `GIST_NO_PARALLEL_LOAD` forces the serial reference (parity gate + escape
  hatch, mirroring the engine's `GIST_NO_PARALLEL`); `GIST_WORKERS` overrides
  the worker count.
- A new `relate concepts` verb drops kinship from the file to the FUNCTION:
  where `clusters`/`echoes` answer "which files are forks?",
  `concepts` answers the finer question an agent actually asks — "which
  functions across the tree are the same idea (the repeated engine, the
  duplicated JSON dump, the copy-pasted validator), regardless of name or
  file?" The comparison unit is the function fragment (`regions.extractAll`
  over authored brace-family + Python source): a helper cloned into six files
  surfaces as one six-member family, not six unrelated files. With no `TEXT` it
  returns package-wide families ranked by consolidation opportunity —
  conservative `repeated_lines` (shortest member span × redundant copies) then
  channel confidence, never a fused score; with `TEXT` it retrieves the nearest
  fragments to that concept. `--lens structure|bytes|echo` picks the channel
  (structure is default and warm-only; byte sketches are computed only for the
  fragments a query nominates, never a repo-wide byte pass). It reuses the
  shared silhouette/sketch channels, seed nomination, and the union-find
  `components` pass, over a new persisted **fragment atlas** (`concepts.frag`)
  folded for freshness exactly like the kinship atlas, so function-level
  discovery answers warm with `--no-index`-identical bytes. Documented in
  `contract/search_api.toml` `[irregex.verbs]`/`[irregex.lifecycle]` and
  advertised by `--schema`; `relate index` builds it and `relate status`
  reports its readiness.
- A new `src/engine/query.zig` deep module owns the transport-neutral compiled
  query: a `(pattern, fixed, ignore_case, mode)` spec lowers once
  into an immutable matcher (literal SIMD fast path, else the linear-time regex
  engine, escaping a `-F -i` literal), exposing the sound trigram `prefilter`
  for index candidate pruning and the per-doc `docMatches`/`countLines`
  decision. It is fail-closed (a pattern outside the linear-time syntax is
  `error.Unsupported`, never a `die()`) and thread-safe (immutable query;
  per-worker `Scratch` is caller-owned), so the cold CLI and the warm resident
  session now execute through one shared compile → prefilter → match core.
- A new `src/search/` primitives tier makes the engine set-shaped —
  match ∪ relate ∪ weave: `PatternSet` compiles N patterns once through the
  shared `engine/query.zig` core with exact per-pattern attribution
  (`docMask`/`lineHits`) behind a skip-only fused alternation gate; `Sketch`
  measures compression kinship via LZJD (LZ78 phrase dictionary, bottom-k=128
  MinHash, `min_phrase=3` noise floor) with no parsing or language list; and
  `loom.Plan` executes a closed filter → group → sort → limit op set
  engine-side over attributed rows. Three CLI faces surface them through the
  dedicated `relate` binary — `relate similar <path>` (nearest files by
  kinship), `relate dups` (near-duplicate pairs, closest first), `relate
  patterns -e P…` (one pass, N patterns, attributed, loom-shaped via
  `--by`/`--under`/`--top`) — each documented in `contract/search_api.toml`
  `[irregex]`, advertised by `--schema`, and mirrored by typed Python bindings
  (`gist.similar`/`dups`/`patterns`/`pattern_counts`).
- Add a habit-safe search verb: gist search PATTERN PATHS now aliases the same
  engine as gist rg and the bare gist PATTERN shorthand. Previously it
  misparsed the pattern as a path and failed with os error 2; a bare gist
  search with no pattern still searches for the literal word search, so nothing
  regresses.
- Added Layer C (roofline) of the performance certificate under
  `bench/roofline/`: a zero-dependency STREAM-style read-bandwidth
  microbenchmark that measures this machine's single-core L1/L2/DRAM roof and
  gist's SIMD scan throughput. The report records distance from the roof
  without treating a sub-ceiling result as proof of saturation.
- Added a zero-copy emit transport to the warm `gist serve` daemon: a large
  `lines` answer now reaches the client as an anonymous shared-memory fd passed
  over the UDS `SCM_RIGHTS` control channel instead of being copied through the
  socket. After the parallel render, the emit was output-transfer-bound — the
  rendered bytes were copied user→kernel→user twice as `chunk` frames — so the
  daemon gathers the shards straight into one shm buffer (Linux `memfd_create`
  +
  `F_SEAL_*` · macOS `shm_open`→`ftruncate`→`mmap`→immediate `shm_unlink`,
  mapping
  bounded to the exact length) and hands its fd to the client in a single
  `chunk_fd` frame carrying `{length, matched}`; the client mmaps it read-only
  and
  writes it out in one shot, so the answer never traverses the socket.

  The path is a negotiated SESSION capability, not a query flag (the flags byte
  is
  full): the client appends a `cap_fd_transport` byte after the version in its
  HELLO, and the daemon uses the fd path only when the client advertised it AND
  the
  answer clears `fd_transport_floor` (1 MiB). Fail-open, never a new failure
  mode —
  any shm/`sendmsg` error, a below-floor or unadvertised answer, an old peer
  (no
  caps byte), or a non-shm target transparently falls to the byte-identical
  `chunk`
  frames; a peer that never advertises keeps working unchanged (the Python and
  Rust
  UDS clients answer files/count and simply don't advertise).
  `GIST_NO_FD_TRANSPORT`
  opts the CLI client out for A/B.

  Measured warm emit-heavy A/B on macOS (fd vs chunk, same daemon, `the
  --uncap`):
  32 MiB answer (services corpus) 112 → not-copied ≈1.10× to `/dev/null`, and
  1.6× (min-time 1.19×) when the output is actually consumed (`| wc -c`); 68
  MiB
  answer (repo-wide) 528 → 353 ms ≈1.50× piped. The win scales with the emit
  and
  with a real downstream reader, which is the agent-capture workload. The
  committed
  session gate is unregressed (armed geomean 474× vs the 5× floor).

  Byte-identity is the whole ballgame and is proven two ways. Within one render
  the
  fd bytes are byte-for-byte identical to that render's `chunk` framing —
  asserted
  deterministically over a single-doc corpus in `serve_test` (plus an explicit
  forced-fallback test: an injected shm-create failure drops the fd-eligible
  answer
  onto `chunk` frames and the bytes match). Across the live tree the CLI
  answers
  agree on content: warm(fd) == warm(chunk) == cold(`--no-index`) == `rg`
  (sort-normalized, since the parallel render's doc order is unstable across
  separate invocations independent of transport; the only gist↔rg gap is gist's
  pre-existing dotfile skip). New: `shm.zig` portable buffer, `wire.zig`
  `sendWithFd`/`recvFrameWithFd`, the `chunk_fd` opcode + capability
  negotiation,
  `render.renderLinesShm`, and `resident.queryLinesShm`.
  (see also: gist)
- (in `gist`) Added the gist operational-envelope matrix under `bench/evaluate/`:…
- Composed family search now compares exact-hit functions or match windows
  instead of only whole files, ranks families by conservative repeated-line
  opportunity, offers a scope-relative `--brief` worklist and `--only` answer
  filtering, and retains nearest-neighbor receipts for genuinely distinct
  implementations.
- Multi-corpus differential battery (`bench/corpora/`): a pinned fetcher
  installs
  five foreign trees (linux v6.10 · cpython v3.13.0 · typescript v5.8.3 ·
  OpenSubtitles en+ru 256 MiB prefixes · a deterministic adversarial `torture`
  generator) under `.local/gist-corpora/`, and `sweep.py` replays an rg-oracle
  slate on each — 472 cases across both engines, all green. The first runs
  flushed out and fixed at the root: JSON base64 `bytes` for invalid UTF-8 ·
  full `--crlf` terminator parity · rg's implicit-path "No files were searched"
  exit-2 heuristic · `-L` dangling-symlink reporting + ancestor-loop detection
  with rg's message · Unicode-aware `-w` word boundaries · `-M` terminator-
  inclusive width · rg's full binary model (the line-buffer
  **committed-prefix**
  geometry — 3-byte BOM-sniff read, per-fill commit at the last newline, the
  NUL-bearing fill discarded — plus the `-U` slice-vs-line routing keyed on
  whether the pattern can actually match `\n`, explicit-file convert semantics,
  and the byte-count clamps in `--json`/`--stats`) · an uninitialized
  generation
  array in the capture VM that made `-r` nondeterministic under ReleaseFast.
- New `ward` primitive (`kernel/math/lease.zig`): a shared reader/writer
  discipline over `std.Io.RwLock` with `Read`/`Write` lease guards and the
  double-checked `readReconciled` fast-read / upgrade-refresh / downgrade
  dance. The warm resident session now rides it instead of hand-rolling
  `RwLock` lock/unlock pairs at each answer face.
- New one-shot install surface: 'make install-gist' builds the ReleaseFast CLI,
  symlinks it onto PATH (~/.local/bin/gist), and builds/refreshes the persisted
  trigram index — the setup step for agents dogfooding gist as the repo's
  default code search.
- New shared bit-identities primitive src/math/bits.zig: a two's-complement
  floor (ones set-bit iterator via ctz + x&(x-1); edge-safe prefixMask +
  in-word rank; Stream, a shift-window cursor over dense packed bit fields; and
  Field(Word) word-packed bit sets with word-masked setRange over caller-owned
  slices) now backing powerset determinization, PatternSet attribution masks,
  ByteSet (setRange went O(words) instead of O(hi−lo)), SA-IS suffix-type maps,
  RRR bitvectors, and the SIMD survivor walks — one audited implementation, 1
  bit per flag instead of a byte. Profiled on the codex FM-index (macOS sample
  over codex-scale, 16MB): the seek class walk was ~41% of count() samples; the
  Stream cursor with paired 12-bit takes plus an O(1) offset-0 scanBlock fast
  path measured ~5% median / ~14% best count-latency improvement, with the
  evidence pinned in PROFILING-DERIVED comments at each site.
- Structured stderr guidance channel for agents
  (src/runtime/cold/emit/hints.zig): a no-match run now ends with a one-line
  `gist: no matches for '…' · N files scanned · scope: …` summary plus up to
  three ranked suggestion lines in rustc's help/note split — `gist: try <flag
  or move> — <why>` for a concrete retry (`-i` when the pattern carries
  uppercase, `-U` when it spans a line break, `-F` when it has regex
  metacharacters, `-uu`/scope-widening when the walk was filtered) and `gist:
  note: <fact>` for what can't be flagged away (an inverted `-v` miss,
  literal-space semantics) — derived purely from the query's own shape and
  wired into every engine exit seam (serial, parallel, ranked live+indexed,
  stdin, and the warm daemon client via the resident classifier). The
  bad-pattern and truncation diagnostics share the same `gist: error:` / `gist:
  try` / `gist: note:` grammar, `--rank`'s timing line gained the `gist:`
  prefix, `usage()` was reorganized (search views / lifecycle / aliases /
  introspection / channels+env) and moved to stdout, and `--schema` documents
  the new `hints` channel. `GIST_HINTS=0` mutes the channel wholesale;
  `--quiet`/`--json`/`--files` never hint; a query with a hit still emits
  nothing on stderr — asserted by the extended bench/gates/streams.sh contract
  (structured-miss + kill-switch cases).
  (see also: gist)
- The `-P` PCRE2 backend gains a _shadow gate_ (`pcre2/shadow.zig`): every
  backreference/lookaround pattern is rewritten into a provably
  language-containing linear over-approximation — assertions erase, backrefs
  splice a copy of their group's source, atomic/possessive relax to greedy —
  and the compiled shadow's O(1)/byte byte-class DFA rejects lines/buffers
  PCRE2 would have backtracked through, so the backtracking engine only ever
  confirms candidates. The same containment makes the shadow's NFA-derived
  required-literal/cover sound for the PCRE pattern (`(foo)bar\1` now
  prefilters on `foobarfoo`, not `bar`), handing `-P` the trigram index it
  never had. Any construct outside the provable subset (recursion, subroutines,
  conditionals, inline flags) declines silently and PCRE2 runs raw, exactly as
  before. The matrix's one declared structural loss flips: `pcre-backref-files`
  (`(\w{4,})\s+\1`, dominated by ~11 s of catastrophic backtracking both
  engines paid on one 3.6 MB base64 fixture) goes 0.94x parity → **15.7x win**
  (735 ms vs rg's 11.6 s), with byte-identical output across all 19 parity
  shapes; a gated≡ungated differential test holds every primitive on
  adversarial corpora, including caseless folding and `-U` multiline.
- The index loader now fails closed on a corrupt blob, and the benchmark-timer
  fail-closed contract is committed as a runnable gate.
  `Index.fromBytes`/`fromMappedBytes` previously trusted most of a `writeInto`
  body — unchecked `dir_off`, no varint length/canonical bound, doc ids never
  bounded against `doc_count`, and `fromMappedBytes` `@alignCast`ing an
  arbitrary slice — so a corrupt or hostile index (the format is a
  native-endian local rebuildable cache, not a portable/untrusted artifact, but
  still) could panic, be silently accepted, or read out of bounds. Both loaders
  now run one `validateStructure` pass and reject anything that violates it
  with `LoadError.BadFormat`: `posting_count` fits u32; trigrams distinct +
  strictly ascending; every group non-empty, in-bounds, and EXACTLY consumed;
  every posting-body varint canonical, `<= 5` bytes, and `<= maxInt(u32)` via
  the new `varint.decodeBoundedCanonical`; doc ids strictly ascending, `<
  doc_count`, with no wrap; and `sum(dir_count) == posting_count`.
  `fromMappedBytes` also verifies 4-byte alignment before the `@alignCast`
  instead of trapping. A ~30-case adversarial suite
  (`src/index/trigram_load_test.zig`) plus a bit-flip mutation fuzz-lite (both
  loaders must agree, accepted blobs must be safe) exercises all of it — and
  surfaced a pre-existing 1-byte leak where an empty-body index
  (canonical-empty / all-docs-under-three-bytes) allocated `@max(len, 1)` but
  freed a zero-length slice, now fixed in both `fromBytes` and `compact`.
  Separately, `bench/gates/fail_closed.sh` pins the benchmark-timer contract as
  a committed gate: its `run_drained` helper drains output (full work + swallow
  the exit-1 no-match) while surfacing a hard error (exit >= 2), proven against
  pure-shell cases and the wired gist CLI (an unbalanced regex and an unknown
  flag must fail, not be timed as a fast search).
  (see also: gist)
- The resident (warm) session now serves `-P`/`--pcre2`/`--engine=pcre2`
  queries
  warm instead of punting them to a cold process. `CompiledQuery.body` migrated
  from a linear-only regex arm to an engine-neutral `Matcher` union, so the
  shared
  query core compiles, prefilters, and matches through the same PCRE2 JIT
  backend
  the cold path uses — including lookahead, lookbehind, backreferences, and
  negative lookahead. A single `pcre` trailer byte rides the additive
  `query_ext`
  opcode (protocol v4→v5); `request.classify` sets `Request.pcre` and still
  declines `-P`+`--rank` (ranked view stays linear-only). Caseless PCRE
  prefilters
  decline soundly rather than risk a false narrow. Proven byte-exact against
  the
  cold `--no-index` walk across lines/`-n`/`-c`/`-l`/`-c -w` on the live corpus
  —
  the warm hit is identical, just without the per-query trigram-index + corpus
  load.
- The resident session now arms a native macOS **FSEvents** watcher — one
  recursive stream over the roots driven on a private CFRunLoop thread — so
  warm
  queries take the microsecond clean path during quiescent windows instead of
  always paying the corpus-wide freshness reconcile that macOS previously fell
  back to (`src/runtime/session/watch.zig`; frameworks wired in `build.zig`).
  It mirrors
  the Linux inotify backend's fail-closed contract: it only ever calls
  `markDirty`/`armWatcher`, arms the session solely on a fully-started stream,
  and
  degrades to the reconcile-always baseline if the stream can't start — so
  read-your-writes and ripgrep parity are unchanged and soundness never rests
  on
  the watcher.
- The resident-session machinery now carries its unit suite:
  the eligibility classifier's fail-closed boundary, the UDS wire codec's
  lossless round-trip and fail-closed framing, and — over a real directory tree
  — resident==rg parity, read-your-writes, and the watcher-barrier seqlock.
- The rg CLI now prints a stderr note when a bundled -r value looks like a
  grep-style flag bundle (e.g. -rn parsing as --replace=n), pointing at the
  ripgrep semantics instead of leaving silently rewritten output. Parsing is
  unchanged — stdout parity with ripgrep is preserved.
- Warm `lines` mode: the bare default `gist <pattern>` search (and `-n`) now
  routes through the resident daemon, pre-rendered daemon-side through the cold
  Emitter itself and chunk-streamed over the v1 wire — cold's own per-file
  bytes and exit code, in the deterministic `pathLess` file order warm `-l`
  already speaks. The resident corpus became faithful (`session/mirror.zig`:
  full reads with no size cap, BOM/UTF-16 decode, whole-body first-NUL
  offsets), closing latent warm-vs-cold gaps for binary, UTF-16, and >4 MiB
  files across all modes; TTY-stdout and readable-stdin queries decline to
  cold, and an errored walk declines instead of serving a gapped set.
- Warm resident session eligibility for `-v`/`--invert-match`, byte-identical
  to
  cold and now FASTER on the faces the math proves winnable — overturning the
  earlier "keep invert cold" result. The daemon answers `-v` by the
  set-complement
  `non_matching(f) = lines(f) − matching(f)`: the trigram prefilter stays SOUND
  for
  the positive MATCH set (a ruled-out file matches nothing by construction, a
  candidate false positive is corrected by the scan), so `matching(f)` is exact
  and
  the complement is exact. Per-file line counts and the corpus total are
  counted
  once at Mirror load and maintained on reconcile, so `-c -v` = `TOTAL − Σ
  match`
  and `-l -v` (file qualifies iff `match(f) < lines(f)`) subtract cached
  invariants
  with ZERO scan on the ruled-out majority — strictly less work than cold's
  full-corpus `-v` scan. On a 1833-file / 238k-line corpus warm `-c -v` runs
  0.05–5.3 ms vs cold 39–48 ms (9–760×, versus the prior warm 106–286 ms), and
  `-l -v` wins 2.7–10.8×. The bare-`-v` emit selects nearly every line of every
  doc, so it shards its render over cores through `src/math/parallel.zig`
  (`greedyBounds` + `fanOut`, concatenated in original doc order) and stays
  byte-identical to the serial core; end-to-end it holds parity with cold's
  16-core
  scan (output-transfer-bound, winning for common patterns). The v2 query flags
  byte is now fully assigned — `invert` (bit 4) joins `known_flags` alongside
  fixed/ignore_case/line_num/word/smart_case/quiet/max_count — and, with every
  bit
  carrying a semantic, fail-closed now rests on the version handshake plus the
  length/opcode gates. Non-invert hot paths stay byte-for-byte unchanged; the
  session gate is unregressed (geomean 474×). Eligible across the UDS daemon
  (`-l`/`-c`/emit), the in-process FFI, and the Python + Rust bindings
  (`_FLAG_INVERT`, `invert` out of the warm-ineligible set), all proven against
  cold on controlled fixtures.
- Warm resident session protocol v2 with smart-case eligibility:
  `-S`/`--smart-case`
  (and its precedence siblings `-s`/`--case-sensitive`) now route warm,
  byte-identical
  to cold. The v2 query flags byte carries the frozen flag-family table
  (`smart_case`
  bit live; `word`/`invert`/`quiet`/`max_count` reserved) and `decodeQuery`
  fails
  closed on any bit outside `known_flags` (BadFrame → decline → cold), so an
  unimplemented flag is never silently dropped server-side. Smart-case resolves
  at
  exactly one Zig site — `request.Request.effectiveIgnoreCase` (cold's
  `hasUpper`
  fold) — feeding the engine fold, the trigram-prefilter caseless decline, and
  the
  no-match hints; Python/Rust clients ship the raw bit and never re-implement
  the
  fold. The Python eligibility predicate forked: `warm_eligible` (UDS) admits
  smart-case while the new stricter `ffi_eligible` keeps the in-process
  transport
  declining flags its C flag word cannot express.
- `-P`/`--pcre2` selects a vendored PCRE2 10.47 JIT backend
  (`src/regex/pcre2.zig`) for the constructs the linear engine can't express —
  lookaround, backreferences, named captures — with per-thread match scratch
  and
  fail-closed resource ceilings (10M match / 10k depth) so pathological input
  trips a clean no-match instead of hanging. `--engine auto` (and rg's
  deprecated
  `--auto-hybrid-regex` alias) is the hybrid: compile the linear engine first
  for
  its speed + trigram AST, escalate to PCRE2 only for a pattern the linear
  engine
  declines. Crucially, PCRE2 patterns are **trigram-prefiltered** too — sound
  required-literal extraction (`src/regex/pcre2/literal.zig`) skips files that
  provably can't match before PCRE2 runs, making gist the only _indexed_ PCRE
  search in the field: it wins the `bench/races/pcre_headtohead.sh` lookaround
  /
  backreference slate against every PCRE-capable competitor (rg -P, ugrep, ag,
  grep -P, git grep -P), with rg -P as the correctness oracle. `--rank` and
  template replace remain linear-engine-only. The flag catalog, `--schema`,
  `README.md`, and `.cursor/rules/irregex.mdc` now reflect that no ripgrep long
  flag
  is unsupported-fail-loud any more; the fail-loud contract now guards unknown
  flags and patterns outside the chosen engine, always naming the `-P` /
  `--engine
  auto` fallback.
  (see also: gist)
- `GIST_DEBUG_WARM=1` now prints the classifier's routing verdict — `gist:
  [eligible]` / `gist: [ineligible]` — _before_ the daemon dial, so a cold
  outcome from "ineligible argv" is distinguishable from "eligible but no
  daemon listening". This makes `src/runtime/session/request.zig::classify`
  observable independently of any running daemon, giving the cross-binding
  parity test a daemon-free oracle for the exact argv the resident path will
  accept.
- (in `gist`) `bench/gates/freshness_fs.sh` — the live-filesystem half of the "no false…
- `flagbench` gains a `--json` record-emit floor — the hermetic, blocking guard
  that locks in the per-record hot-path shaves (the `pathData` object cache,
  `writeUint`, and the `asciiOnly` UTF-8 pre-check) so they can't silently rot.
  It times the public per-file encoder core `json.emitOne` over the real corpus
  (the exact serial stream every serial/shard/walk path shares, isolated from
  the
  walk/read/fan-out), and self-checks the emitted `match`-record count against
  the
  same independent per-line-hit oracle the `-l`/`-c` floors trust — a
  dropped/duplicated record fails loud, byte-shape parity staying rgsuite's
  job.
  The floor (≥ 500 MiB/s of bytes searched, ~half the observed slowest needle
  so
  the shared coworking box's load never false-trips it) is advisory by default
  and
  blocking under `--gate`, joining the `-i/-n/-v/-l/-c/-o/-w/-r` slate the
  `ci_order.sh` performance phase already runs. Wiring it in also compiled the
  formerly-dormant `-U --json` ripgrep-parity table test into `zig build test`
  (the encoder is now reachable from the module root, so `refAllDecls` reaches
  its
  tests), and made `output.MlHarness`'s constructor/teardown `pub` for the
  cross-module reuse that test always intended.
- `gist index` is now incremental and answers in ~2 ms when nothing changed
  (~450× the ~950 ms full rebuild; ≈1,400× the pre-sweep ~3 s). The default
  path is an AMEND: with a generation-published base for the same roots, it
  derives the changed set since the last freshness anchor and publishes a
  CODICIL (`corpus/index/trigrams/codicil.zig`) — a small delta segment
  carrying re-indexed postings, crest rows, appended new-doc paths, and
  tombstones, hardlinked forward over the base blobs and generation-atomic like
  every publish. Queries union base ∪ codicil ∪ tombstones with byte-identical
  answers (proven against a full rebuild on live-corpus probes). The changed
  set comes from three tiers, each the next one's fallback: (1) the resident
  daemon's new ANNALS — a never-drained `path → last-delivery-instant` ledger
  fed by the live FSEvents stream, queried over the UDS protocol (v6,
  `changed`/`annals` opcodes) behind an `FSEventStreamFlushSync` causal
  barrier, ~0.6 ms; (2) a one-shot FSEvents historical-journal replay from the
  `journal.tok` since-token minted at full-build time (~25 ms); (3) the proven
  stat walk. The annals are fail-closed end to end:
  unarmed/multi-root/pre-coverage/poisoned ledgers decline (sticky doubt on any
  inexact event; eviction advances the coverage floor so an amputated answer is
  impossible), a declined consult auto-spawns the daemon for the next round and
  falls back, and every daemon answer is re-confirmed by live stat and the
  walk's own admission filter before use. A small change amends in ~8–25 ms
  (pair load, delta index, and publish, proportional to accumulated drift; past
  `GIST_AMEND_MAX` it compacts via full rebuild). `GIST_NO_AMEND=1` forces the
  full build and `GIST_NO_ANNALS=1` forces the non-daemon tiers (parity gates
  and escape hatches); full builds also got a bitmap trigram dedup and
  hardlinked stable aliases (~950 ms whole-repo, down ~3×).
- `gist index` now emits a **content shard** (`corpus/index/content/shard.zig`,
  `content.shard`): every corpus body the trigram index already ingested is
  concatenated into one mmap'd blob with a doc→offset catalog, so a query
  serves each unchanged file's bytes from a single memory map instead of
  `openat`+`read`+`close`-ing it. This closes the last full-scan floor — the
  per-file syscall wall on queries with no usable trigram filter (a 2-byte
  literal like `})`, a dense class count, a bare `-c`) where ~20k file opens
  had left gist behind zoekt's static server index. The blob is a read
  accelerator only: a slice is handed back exactly when the same T3 clock rule
  the elide overlay uses proves the file unchanged (`bulkstat.needsLiveRead` —
  `mtime < anchor AND ctime < anchor`), and a
  changed/new/binary/oversize/out-of-scope file misses the lookup and is read
  live, so the walk's answer is identical whether or not a shard loads.
  Self-anchored and fail-open — a missing/corrupt/foreign/future-dated blob
  loads as null; `GIST_NO_SHARD=1` and `--no-index` disable it. Measured
  across-the-board: 2-byte punct full scan (`-cF '})'`) 174.3 ms → 49.3 ms
  (**3.53×**, beating zoekt's ~68 ms) and `-l` **5.33×**; the rare literal (`-c
  pgxpool`) 32.0 ms → 30.4 ms (**1.05×**, beating csearch's 34.4 ms) — the two
  classes gist had been losing. Byte-exact parity vs the `--no-index` live walk
  is held continuously by new `shard-*` and post-index `shard-freshness` cases
  in `bench/gates/index_elision_parity.sh`.
  (see also: gist)
- `irregex blast SYMBOL` — a live symbol blast radius for editing agents:
  the seed's definition + kind, direct dependents (functions
  referencing it, def/use classified) and dependencies (identifiers its body
  resolves), tangential twins (compression kin of its file) and ripple
  (same-language second-hop callers), and comments that mention it — computed
  from CURRENT bytes with no precomputed graph, as compact `--json` or a human
  digest with a `--budget` token cap. Built on a new shared
  `kernel/compose/lexspan.zig` span lexer that also powers `gist --in-comments`
  / `--in-code`.
- `relate` grows a structure channel beside LZJD: every corpus file gets a
  silhouette — identifiers/numbers/strings normalized to `I`/`N`/`S`, comments
  and whitespace dropped, 5-token grams winnowed (w=4) into a k=256 KMV sketch
  —
  so a renamed Type-2 twin lands at exactly distance 0. Surfaced two ways:
  `relate similar --lens bytes|structure|fused` (bytes stays the default), and
  the new `relate echoes` verb, which ranks pairs by `bytes − structure`
  distance
  (`--min-echo`, default 0.15) to report DRY/abstraction candidates that `dups`
  can't see — same skeleton, different vocabulary. The kinship atlas is now v3
  (silhouette rows persisted beside sketch rows, both folded on freshness);
  older
  atlases read as corrupt and degrade to a live build with a `relate index`
  hint.
- `relate` grows from a five-verb sketch face into a standalone engine with two
  new set-shaped verbs: `relate pack <query|file>` selects an anti-redundant
  context set by greedy submodular max-coverage over corpus-priced fingerprints
  — each pick is scored by _marginal_ bits saved given everything already
  chosen, so near-duplicates of a prior pick contribute nothing and never make
  the cut; `relate clusters` union-finds verified near-duplicate pairs into
  fork families (size-sorted, `--min-size`/`--max-dist`/`--json`), turning
  pairwise `dups` output into the restructure-ready unit of work. Both are
  documented in `contract/search_api.toml` `[irregex]` and advertised by
  `relate --schema`.
- `src/index/trigram_fuzz.zig` — the long / nightly companion to the CI-safe
  fuzz-lite. It seeds a corpus (empty index · one trigram/one doc · one
  trigram/many docs · many trigrams/sparse · zero-trigram with `doc_count > 0`
  · a max-width 5-byte doc id · realistic built indexes · the deterministic
  malformed blobs) and mutates it (truncation, bit flips, byte overwrites),
  asserting on every input: `fromBytes` never panics or reads out of bounds (it
  either rejects with `BadFormat` or returns an index `queryLiteral` can walk
  under ReleaseSafe/Debug memory safety); an accepted index also passes an
  **independent** canonical re-walk (`safeCanonical` — deliberately not the
  loader's own `validateStructure`, so a bug that accepts a noncanonical blob
  is caught); and `fromBytes` / `fromMappedBytes` always agree. `fuzz_iters` is
  the CI-safe default budget (10k mutations per `zig build test`); raise it and
  run `-Doptimize=ReleaseSafe` for a nightly/pre-release soak.

### Changed

- **The two search engines merged into one.** `gist`'s certified ripgrep-parity
  walk-and-emit pipeline (`src/runtime/cold/`) is now the _sole_ engine, and it
  gained a second, much faster candidate source: the persisted trigram index.
  When
  a fresh index covers the searched subtree it is used automatically as an
  _acceleration structure_ — reads of files the index can prove cannot match
  (trigram non-candidates unchanged since the index was built) are elided,
  while
  the live walk stays authoritative for path discovery and `.gitignore`
  semantics,
  so output is byte-identical to a pure walk. `--no-index` forces the live
  walk;
  `--index` forces the accelerated path (default: auto-detect). A new
  `bench/gates/index_elision_parity.sh` differential gate proves the core
  safety
  claim continuously — every query's index-accelerated output equals its
  `--no-index` full read across literal / regex / caseless / word / count /
  files-with(out) / context / invert / only-matching / type- / path-scoped
  cases,
  plus the freshness overlay (16/16 byte-identical).

  `--rank[=N]` folds in gist's one output shape ripgrep can't express — the
  definition-first ranked view (RRF fusion over per-file signals, a symbol's
  definition outranking its call sites, codegen demoted) — now a flag on the
  unified engine (`src/runtime/cold/engine/ranked.zig`) instead of a separate
  verb.

  **The `search` verb is gone.** Bare `gist <pattern> [PATH...]` is canonical
  (`index` and `status` remain the only lifecycle verbs); `gist rg` is the same
  engine addressed explicitly. rgsuite parity held at the 278/282 baseline
  throughout and the full `zig build test` slate stays green.
  (see also: gist)
- **Trigram index switches from a flat `(trigram,doc)` pair table to a CSR
  directory over delta-varint posting bodies**
  (`src/index/trigrams/trigram.zig`, new
  `src/index/postings/varint.zig`) — the fix for the README's own documented
  weak point:
  "gist trails csearch/zoekt on the cold literal one-shot because it maps a
  177 MiB index where csearch mmaps 28 MiB." A flat table spent 8 bytes/posting
  (4 tag + 4 doc) and most of the tag was redundant — a distinct trigram
  carries
  dozens of postings on average. The index now stores three parallel arrays
  over
  the `n` DISTINCT trigrams (`dir_tri`/`dir_off`/`dir_count` — csearch's own
  per-trigram index-entry triple, `index/write.go`) plus one `body` blob: each
  group's ascending doc ids are delta-encoded (successor `doc[i]-doc[i-1]`,
  always ≥ 1) and LEB128-varint-packed, so a locally-clustered doc-id run — the
  common case — costs ~1 byte/posting instead of 4, while the zero-copy `mmap`
  load (`persist.zig`) is unchanged: `dir_*`/`body` still alias the mapped
  pages
  directly (`fromMappedBytes`), so a cold query still touches only the handful
  of pages its binary search + a few small per-trigram decodes probe.
  Rarest-first
  query intersection is preserved via the explicit `dir_count` column (sort
  groups by size before decoding, same algorithm as before).

  **Measured on this repo (18,910 files, 160.1 MiB corpus, 343,857 distinct
  trigrams, 25.56M postings):** index footprint **195.0 MiB flat → 30.1 MiB
  CSR+varint (6.5×)** — smaller than `csearch`'s own index over the identical
  corpus (31.1 MiB) for the first time. `bench/coldquery.sh`'s cross-tool cold
  literal race (fresh process, hyperfine mean, 8 runs, 8 needles) moves the
  geomean gist/csearch ratio **0.3× → 0.7×** and gist/zoekt **0.5× → 0.8×** —
  gist now outright _wins_ 7/11 needles against zoekt (up from a near-total
  loss) and still trails csearch geomean, but by roughly half the prior margin.
  The residual gap is no longer index size (gist's is now the smaller of the
  two) — profiling traces it to the corpus-wide freshness `stat()` walk
  (`src/index/trigrams/fresh.zig`) that runs on every cold query regardless of
  hit/miss;
  that is the next rung, tracked separately, not hidden.

  Correctness re-proven: format bumped to `format_version = 2` (a v1 cache is
  rejected, not misread); the full trigram/varint/ngram unit suite (`zig build
  test`, 207/207) and the `gist ≡ rg` equality oracle are green on the new
  format.

  **Confirmed on the fail-closed macro certificate**
  (`bench/certify/certify.sh`
  — fresh-process, hyperfine 20 runs + 3 warmup, gist-vs-rg verdict requires a
  lower median _and_ Mann-Whitney p<0.05): **7 win · 1 parity · 1 loss** across
  9 measured classes (up from a documented 8 win/3 loss at the old index size —
  methodology differs slightly, see README), and the vs-csearch/vs-zoekt split
  moved from "rivals win most cold classes" to a genuine ~50/50 split
  (geomean ≈1.0× csearch, ≈0.8× zoekt). `certify_stats.py` also hardened to
  skip a rival's malformed/empty hyperfine export (a transient hiccup, not a
  real result) instead of aborting the whole certificate for one missing cell.
  (see also: gist)
- A transforming (`-z`/`--pre`/`-E`) pipeline run now scales its worker pool to
  all logical CPUs instead of the 6-worker ceiling tuned for the
  syscall/namei-bound plaintext walk. Per-file decompression (gzip/zstd/xz
  inflate) and transcoding are CPU-bound and embarrassingly parallel — exactly
  like the serial engine's parallel read-shards, which already fan out to
  `min(candidates, ncpu)` — so the old cap throttled decode-heavy codecs
  (xz/zstd) below the serial path on wide machines. On a 16-core box over a
  nested compressed corpus this lifts `-z` past ripgrep AND ugrep on the
  in-process formats (gzip/zstd/xz), where gist decodes in-process while both
  rivals fork a decompressor per file.
- Accelerate the SIMD scan floor on two load-port-bound fronts. First, widen
  the
  single-load byte scanners in `scan.simd` from the 16-byte NEON register to a
  64-byte stride (`scan_vlen`): `memchr` (line-end find), `countByte`
  (line-number
  counter), `countByteWithFlag` (`--json` base pass), the reverse
  `lastIndexOfScalar`
  (line-start walk), and the caseless single-byte find. These issue one load
  per
  block, so the out-of-order core runs the four independent 16-byte loads
  across its
  NEON pipes — measured ~35% faster (17→23 GiB/s, Apple M4). A `vlen`-wide
  second
  tier runs before the scalar tail so a haystack under 64 bytes still
  vectorizes (no
  short-line/small-gap regression). The two-load substring kernel (`indexOfPos`
  &
  co.) deliberately stays at `vlen` — its strided second load already saturates
  the
  ports, so widening measured flat.

  Second, add `scan.teddy` — the Hyperscan/ripgrep Teddy multi-literal
  prefilter —
  and hand the fused any-of gate (`scan.simd.containsAny`/`indexOfAnyPos`, the
  whole-buffer prefilter for needle-less alternations like
  `func|const|return|struct`)
  off to it at 4+ needles. The fused first+last gate pays `1 + N` loads per
  block, so
  its cost grows linearly in the alternation size; Teddy pre-bakes every
  needle's
  first two bytes into nibble→bucket tables and resolves all N with one `tbl`
  (NEON) /
  `pshufb` (SSSE3) shuffle per position, collapsing the block cost to a
  CONSTANT 2
  loads regardless of N. Slim Teddy, one bucket per needle (≤ 8), fixed
  16-wide, with
  a scalar-gather fallback on other arches. The N ≥ 4 handoff is where the
  load-count
  win dominates on every architecture regardless of vector width, so N = 2,3
  keep the
  fused gate (better on wide-vector AVX2/512); both paths are byte-exact — a
  throughput dispatch, not a fallback.

  Byte-exact throughout: the `simd_test.zig` differential oracles stay green
  (the new
  Teddy fuzz vs the `std.mem.indexOfPos` leftmost minimum over random needle
  sets/resume offsets, plus the widened
  `memchr`/`lastIndexOfScalar`/`countByte`
  scanners vs `std`), and `gist` counts match `rg` exactly on 4- and 8-literal
  alternations across ~290k lines. Measured Teddy speedup over the fused path
  on the
  mostly-miss file-gate corpus (Apple M4): N=4 1.6×, N=8 2.2×.
- Add `Ward.reconcileHeld`: a double-checked reconcile that starts from an
  already-held read lease and keeps a live lease on every path (error
  included), returning the refresh error beside the lease rather than in place
  of it. The resident session's `guardExtras` now rides it instead of
  hand-rolling the release/upgrade/recheck/downgrade dance.
- Beat ripgrep on the single-file line-scan modes by adopting the two things
  its
  one-file-one-thread architecture can't: **data-parallel single-file
  sharding**
  and **mmap'd reads**, plus an NFA-free span path. On a 57 MB single-file
  corpus
  (`function|const|return|struct`, warm cache, hyperfine): `-c` 2.0×, `-o`
  2.0×,
  `-b` 1.95×, `--count-matches` 1.96×, `-n` 1.81× faster than `rg` — the
  `--json` match stream stays byte-identical and ahead.

  - **Single-file sharding** (`serial.zig`
  `emitFileSharded`/`lineShardBounds`):
    a lone big file is split at line boundaries into byte-balanced shards, each
    running the line-free literal fast path (`Emitter.fileLit`) over the SHARED
    global body on its own core, then merged in line order (emit modes) or
  summed
    (count modes). Byte offsets, the unterminated tail, and `-n` line numbers
    (each shard's global base via one cumulative `countByte` pass) all stay
    global, so output is identical to the serial scan — this is the win rg
  leaves
    on the table for a single file.
  - **mmap for large files** (`grepfile.mapFile`, wired into
  `readOneCandidate`):
    an untransformed file ≥ 4 MiB is memory-mapped instead of read-loop + arena
    duped, so its pages fault in lazily during the (sharded) scan rather than
    paying a serial ~2× copy up front — ripgrep's large-file strategy.
  - **Parallel binary detection** (`verify.firstNulWide`): the whole-buffer NUL
    scan that gates the fast path is fanned across cores with a
  quit-at-first-NUL
    poll (the binary-detection twin of `gateWide`), so it faults pages in
  parallel
    instead of serializing one redundant full pass ahead of the scan.
  - **NFA-free literal spans** (`output.zig` `litNextSpan`/`emitMatchesLit`,
    `prefixFree`): for a prefix-free literal set (no literal a prefix of
  another —
    so at most one matches at any offset), `-o`/`--count-matches`/`--column`
    resolve each span with one `indexOfAnyPos` jump + a length lookup instead
  of a
    Pike-VM run per line, and never allocate a `SpanSim`. A non-prefix-free set
    (e.g. `con|const|co`) falls back to `matchSpan`, so spans stay byte-exact.
  - **Early-exit presence** (`anyMatch`): `-q` short-circuits on the first
  literal
    occurrence (`indexOfAnyPos`) instead of materializing every line of the
  body
    — an 11× → parity swing on a top-matching 57 MB file.

  Byte-identical to ripgrep — `bench/rgsuite/run.py` 409/409 (parallel and
  serial), full Zig unit + differential-fuzz suite green (new `memchr` /
  `lastIndexOfScalar` / `countByte` / `firstNulWide` oracles vs `std.mem`), and
  span-mode spot-checks over `-o`/`-n`/`-b`/`--column`/`--count-matches`
  including
  the prefix-overlap adverse case. The repo-wide _indexed_ `-l`/`-c` race is
  unaffected and still 6–100× over rg's unindexed walk.
  (see also: gist)
- CREST sidecars now bind their full semantic schema with a canonical SHA-256
  digest under `GISTCRS2`; stale v1 or semantically incompatible caches fail
  closed and rebuild without changing search results.
- Caseless runs (`-i`/resolved `-S`) now ride the same SIMD literal gates as
  case-sensitive ones instead of paying the fold-heavy engine per byte. A new
  ASCII-caseless kernel (`simd.containsCaseless` — first+last byte splatted in
  both case spellings, survivors verified bytewise) backs a `Gate` type
  threaded through every needle consumer (whole-file drop, per-line engine
  bypass, the wide multi-GiB fan-out); the gate literal is the longest
  fold-closed window of the raw (pre-fold) required literal
  (`query.zig::foldClosedWindow` — ASCII-only, `k`/`s` split the window under
  Unicode fold since KELVIN SIGN/LONG S escape ASCII), and when the window is
  the whole pattern and the pattern is one pure literal the gate is a proven
  match equivalence, so caseless `-l` emits with zero engine runs. A
  containment-only gate still drives `-l` hit-to-hit (`gatedDocMatch`: SIMD
  jump to each gate hit, engine on just that line). The warm compiled query
  mines the same gate + caseless trigram variants, so the resident daemon
  prunes and gates `-i` identically. Multi-root caseless `-l` over eight source
  roots: 1.24s → 0.33s (rg 0.45s); matrix `ignore-case-rare-files` holds
  ~4.2–5.0x with 19/19 parity and rgsuite 409/409 intact.
- Chasing the roofline Layer C headroom found the substring kernel paying a
  per-block movemask it almost never needed: on NEON the `@bitCast`-to-integer
  mask emulation is a multi-µop cross-lane sequence, spent on every 16-byte
  block of a miss-dominated stream. Every scan loop (`indexOfPos`, `memchrPos`,
  the fused any-of pair, the caseless kernel) now runs 64-byte blocks gated on
  `anyLane` — a word-wide OR-reduce "did anything hit?" — with the movemask
  paid only inside proven-hot blocks. Anchors got smarter too: a corpus-derived
  byte-density table (`rarity.zig`, the memchr crate's rare-byte idea measured
  over a large polyglot monorepo) picks the needle's two rarest bytes at any offsets
  instead of first+last, a genuinely-rare probe earns a single-load block
  filter, and a runtime hit counter demotes that shape mid-buffer when the
  table misdescribes the bytes (base64, random-looking text) — the
  misprediction collapse that costs, measured on a uniform-random buffer, half
  the throughput. Per-file tails stopped calling `std.mem.indexOfPos`, whose
  Boyer-Moore-Horspool preprocessing built a 256-entry skip table per call — a
  many-small-files corpus paid it ~20k times per scan — replaced by one
  overlapped final vector block. Roofline on M4: contiguous streaming 44.8 →
  53.6 GB/s, per-file corpus full-scan 20.8 → 30.2 GB/s (24% → 36% of the DRAM
  ceiling), matched lanes up 3–5%. Byte-parity proven by `zig build test`, the
  SIMD differential fuzz, `scan_regress.sh` (0 FN / 0 FP), and an rg-parity
  battery over indexed + live paths.
- Close the searcher-loop gap to ripgrep on needle-less literal alternations
  (`function|const|return|struct`) — the case with no single required literal
  for
  the existing per-line gate to skip on, so gist ran the engine on EVERY line
  while `rg` scanned the whole buffer through a Teddy prefilter. A new fused
  multi-literal primitive `scan.simd.indexOfAnyPos` (the position-returning
  twin of
  `containsAny`: one pass, per-needle first+last-byte SIMD fingerprints OR'd
  into a
  survivor mask, leftmost verified survivor wins) drives a whole-buffer
  prefilter:
  one sweep marks the candidate lines around literal hits, and the per-line
  classify then skips ~every non-candidate without an engine run. Wired into
  both
  the text emit (`output.zig` —
  `file`/`onlyMatching`/`countMatches`/`passthru`)
  and the `--json` classification (`json.zig`), gated on `re.lits`
  (`analysis.pureLiterals` — the same match-equivalence set `matchSpan` uses,
  empty
  under `-i`/`-w`/`-U`). The mask is a SUPERSET of the true match set (a hit in
  a
  line's trailing `\r`/terminator maps to that line — the engine still confirms
  each candidate), never a subset, and declines under `-v` (a match LACKS the
  literals) and `--stop-on-nonmatch`, so output stays byte-identical.

  Byte-identical to ripgrep — `bench/rgsuite` `run.py` 409/409 (parallel and
  serial), the `indexOfAnyPos` differential-fuzz oracle green (leftmost-hit vs
  the
  `std.mem.indexOfPos` minimum over random needle sets/resume offsets), and
  49/49
  edge-corpus spot-checks (no-trailing-newline, CRLF, single-line,
  first/last-line
  hits, blank-line runs, empty) across
  `-o`/`-c`/plain/`-n`/`--column`/`-A`/`-v`.
  Measured on a 57 MB single-file corpus (A/B vs the pre-change litSpan
  binary):
  `-o function|const|return|struct` 257→76 ms (3.4×), `--json` 283→102 ms
  (2.8×),
  `-c` 230→51 ms (4.5×). The gap to `rg` on the alternation collapses from
  11.8× to
  3.6× (`-o`), 3.9× to 1.5× (`--json`), and 14× to 3.0× (`-c`).
- Cut the `--json` record stream's serial-engine cost with two byte-identical
  emit-path changes (`src/exec/cold/emit/json.zig`). The classification
  loop now threads the engine's required-literal `simd.Gate`
  (`serial.zig::requiredLiteralGate`, the same gate the line path uses) from
  `run`
  → `runParallel`/shards → `emitOne` → `emitFile`: a line lacking the pattern's
  forced literal skips the NFA entirely. Sound only when non-inverted — exactly
  when the gate exists — so the `-v` classification is unchanged. And each
  matched
  line's spans are now enumerated ONCE at classification and cached on the
  `Line`
  (`matchSpans`), reused for both the `matches` tally (`countMatches` became a
  sum,
  no engine) and `submatches` emission (`emitSubmatches` iterates the cache),
  so a
  matched line pays the engine once instead of up to three times; the dead
  `firstSpan` is removed. Byte-identical to `rg --json` on both engines
  (`bench/rgsuite` core/multiline/pcre cases green). Measured on a frozen 54 MB
  /
  1.7 M-line single-file corpus (read/walk ≈ 0, serial emit isolated, A/B vs
  the
  pre-change binary): `func` 638→124 ms (5.2×), `func\s+\w+` 966→277 ms (3.5×),
  `WalletService` 523→92 ms (5.7×), `import` 591→100 ms (5.9×) — a 3.5–5.9×
  internal emit speedup on top of the earlier `jsonstr` SIMD rewrite. This
  narrows
  but does not overtake `rg --json`, which still leads because `--json`
  disables
  gist's index read-elision (it must tally `searches`/`bytes_searched` for
  every
  searched file), racing rg's parallel walk+search+emit without gist's index
  advantage; the standing `--json` claim remains byte-parity, not a speed win.
- Eliminated Gist's remaining cold-query structural overheads without weakening
  freshness: trusted local indexes now mmap with bounded structural validation
  and defer posting-group decode until queried; the parallel path folds
  freshness into directory enumeration, uses a compact exact path table,
  declines unprofitable/narrow index loads, routes selective work to
  topology-aware worker counts, and reuses compiled regex required literals as
  SIMD file/line gates. The fail-closed 20-run full-field certificate moves
  from 0/11 to 10/11 wins versus ripgrep on the same Apple M2, while the
  140-literal + 70-regex oracle and live dense-scan gate remain 0 FN / 0 FP.

  The adversarial verification pass also fixed two pre-existing rg-parity
  defects the live gate exposed: walked binary files can no longer match after
  the NUL cutoff under `-l`, and unsorted multi-root walks now reproduce
  ripgrep's VCS-ignore re-anchoring. The persisted blob codec/validator moved
  out of `trigram.zig`, dropping the index core below the 500-line cap;
  oversized rg protocol modules are now explicitly registered rather than
  remaining undocumented shape debt.

  The benchmark field now copies the deterministic `zig-out/bin/gist` produced
  by the immediately preceding ReleaseFast build. It no longer guesses among
  hash-named Zig cache artifacts by mtime, which could silently benchmark an
  older intermediate binary and certify code other than the current tree.
- Expand Gist and Relate help into intent-first ergonomics guides so people and
  agents can choose familiar, native, and niche search shapes from the CLI
  itself.
- Files-only searches now stop after the first matching line, and the committed
  performance gate bounds the two known csearch-selective gaps without
  overstating them as wins.
- Generalized the warm session's data-parallelism from the invert emit to EVERY
  positive warm face, so a common token no longer loses to cold purely on core
  count. The invert-only `renderLinesInvertParallel` became the shared
  `render.renderLinesParallel`, and its floor/shard gate was lifted into one
  `math/parallel.zig::shardBounds` primitive that all faces now cross into
  parallelism through: (1) `queryLines` positive emit shards the candidate doc
  slice byte-balanced and renders each shard through the cold `Emitter` into
  its
  own buffer, concatenated in doc order; (2) the `-l`/`-c` fold (`query`)
  splits
  its candidate walk into `eachBase` (sharded, per-thread scratch +
  `Accumulator`
  over the immutable mirror — `-c` sums, `-l` concatenates then sorts once) and
  `eachOverlay` (the bounded mutation set, always serial); (3) the FFI `search`
  record stream collects each shard's per-line spans into its own buffer, then
  feeds the sink SERIALLY in doc order honoring early `halt`, so the stream
  stays
  byte-identical and stops at the same record. All share the 256 KiB byte floor
  —
  below it (or on one core) each face falls straight through to its serial
  core, so
  tiny queries never pay thread-spawn. Every shard is read-only over the mirror
  under the held session lock with its own arena, and the fail-closed per-hit
  existence check is preserved per shard.

  Measured on the live 20k-file / 193 MiB repo corpus (warm files-mode p50,
  serial → sharded): `import` (13838 files) 10.5 → 5.9 ms, `})` (7780) 12.7 →
  5.0 ms
  (2.5×), `def` (4908) 6.4 → 3.0 ms (2.1×), `func` (3690) 5.1 → 2.5 ms (2.0×),
  `context.Context` (1756) 2.8 → 1.4 ms (2.0×); small/rare needles stay on the
  serial core, unchanged. Byte-parity proven `warm == --no-index == rg` (with
  `--uncap` past the soft output budget) on a controlled 400-file fixture
  crossing
  the floor (8/8 cases: `-l`/`-c`/bare/`-n`, large + rare set) and the live
  tree
  (16/16), plus a resident-suite test over a >256 KiB tree asserting the
  sharded
  `-l`/`-c`/emit/stream against ground truth (path-sorted `-l`, exact `-c` sum,
  ascending record stream). The committed session gate is unregressed (armed
  geomean 474×). The now-orphaned invert-only render helper was removed.
- Give the span engine a pure-literal fast path, so every "where is the match"
  operation (`-o`, `--json`, `--column`, `--vimgrep`, `-w`, `-r`, colored
  highlighting) stops paying the Pike VM on literal and literal-alternation
  queries — the code-search common case. `Regex.matchSpan`
  (`src/kernel/regex/linear/pike/span.zig`) now short-circuits through
  `litSpan`
  whenever `re.lits` is non-empty (the `analysis.pureLiterals`
  match-equivalence
  set — an assertion-free alternation of pure literals, per-line only): the
  span
  is found by one SIMD `scan.simd.indexOfPos` per literal (≤ 8) instead of a
  per-byte NFA closure. Leftmost-first semantics are preserved exactly — the
  strictly-earliest occurrence wins (leftmost start dominates branch priority),
  and a positional tie keeps the lowest branch index (pattern order = NFA
  priority), because no literal occurring at the winning position can have an
  earlier occurrence of its own. `-i` folds a literal byte to a non-singleton
  class, so `re.lits` is empty and the shortcut cleanly declines to the Pike
  VM;
  `-U` disables `re.lits` outright, so multiline is untouched.

  Byte-identical to ripgrep — `bench/rgsuite` `run.py` 409/409 (parallel and
  serial), the differential-fuzz oracle green, and byte-exact `-o`/`--column`/
  `--vimgrep`/`-w`/`--json` spot-checks including the `return|ret` tie-break.
  Measured on a 57 MB single-file corpus (A/B vs the pre-change binary):
  `--json TODO` 560→69 ms (8.2×), `--json function|const|return|struct`
  3363→284 ms (11.9×), `--json return|ret` 1452→130 ms (11.2×),
  `-o function|const|return|struct` 2914→256 ms (11.4×). The remaining gap to
  `rg` on these is no longer span-finding but the searcher loop — gist splits
  and
  verifies per line where rg scans the whole buffer through a Teddy/memmem
  prefilter and touches only candidate lines.
- Graduate GIST from a single canary consumer to the repository-wide search
  substrate of the monorepo it was born in: every first-party executable
  ripgrep consumer now drives the certified `gist` engine — lint gates, doc
  freshness wrappers, the relocate/restructure/comment-quality/pentest
  tooling, several shell scripts, and the agent-facing code-search tool
  (resolved binary, with its health probe reporting availability).
  Patternless `rg --files` inventories moved to the git
  index,
  each consumer carries a committed `*_gist_parity.py` guard, and a fail-closed
  `gist-adoption` ratchet ratchets first-party ripgrep executions to zero. Raw
  `rg` survives only as GIST's independent parity/benchmark oracle.
- Index read-elision now engages in two places it used to stand down. Scoped
  roots: `indexElisionWanted` no longer requires a broad root — the
  elide-oracle loader already runs concurrently with the walk and the
  end-of-walk flush never blocks on it, so a nested-root query (`gist Foo
  some/nested/dir`) gets its non-candidate reads elided like a rootless
  scan (subtree matrix shape 1.66x → ~4.5–7.8x) while a tiny scope that outruns
  the load pays only the deferral append. Caseless: `-i`/resolved `-S` no
  longer disables the trigram prefilter wholesale — the raw (pre-fold) required
  literal is recovered from a case-sensitive throwaway compile and one window
  of it expands into a ≤16-variant case OR-set the index can query
  (`query.zig::caselessVariants`), with the soundness bounds owned there:
  ASCII-only windows, and `k`/`s` inadmissible under Unicode fold since their
  simple-fold orbits (KELVIN SIGN U+212A, LONG S U+017F) escape ASCII
  (ignore-case matrix shape 1.43x → ~4.9x). Any decline reproduces the old
  no-elision behavior exactly; 19/19 parity holds gist-idx == gist-noidx == rg.
- Profiling the cold `--rank` path on a fat-candidate probe found 4.2 s hiding
  in two places, neither of them ranking. First, freshness: the macOS journal
  replay blocked ~1.9 s in `FSEventStreamFlushSync` before draining a single
  event — the flush is gone, the runloop drain now runs under an explicit
  budget (75 ms per query, 500 ms at daemon boot), a lost race writes a
  per-token `journal.skip` marker so later queries jump straight to the sweep
  walk, and `amend` re-mints the since-token exactly like a full build so the
  replay window stays "since the last amend" instead of growing forever.
  Second, feature extraction: `fileDoc` ran a full per-line pass over every
  candidate and only then consulted `docMatch` — inverted, one fused
  whole-buffer `docMatch` now rejects trigram false positives at the one-pass
  floor and only real matchers fund the per-line signals (also fixing a
  phantom-final-line overcount for `^$`-shaped patterns under rg's line model).
  Cold fat-probe rank drops 4.2 s → ~30 ms with a fresh index (~150 ms on a
  busy tree paying the bounded probe), set-equal with `gist -l` and
  def-boost/gen-demotion invariants intact.
- Purposeful profiling of the per-file pipeline (walk → literal gate → staged
  read → SIMD scan → emit) found the residual multi-root tax living entirely in
  giant mmap'd bodies: the pager faulted the 2.1 GiB blob in one page-cluster
  at a time (13.7 GiB/s) and its whole-file presence gate ran on a single
  worker thread. Two fixes, measured on the live corpus: `mapWhole` now advises
  `MADV_SEQUENTIAL|WILLNEED` (fault-ahead batching, 13.7 → ~40 GiB/s on the
  page-cached blob), and the file-level required-literal gate routes through
  `verify.containsAnyWide` — identical single-thread SIMD kernels below 16 MiB
  (one length compare, no syscalls, no spawn), chunked across cores with
  needle-overlap seams and cooperative early-exit above it. `gist pgxpool
  services libs -l` drops 196 → ~84 ms (rg: ~160–230 ms on the same roots); a
  no-hit scan of the single 2.1 GiB file drops 190 → ~79 ms (rg: ~199 ms).
  Byte-parity proven by the seam-adversarial differential test in
  `simd_test.zig`, `scan_regress.sh` (0 FN / 0 FP over five no-prefilter
  patterns), and `index_elision_parity.sh`.
- Ranked search now identifies declarations from Unicode-aware delimiter
  geometry—including labels, prefix forms, equations, and symbolic
  bodies—instead of a project/language keyword catalogue, and applies
  Relate-style corpus pricing to normalized match-line shapes so definitions
  outrank repeated imports, annotations, and calls across diverse repositories.
- Ranked searches now demote cached source mirrors and identify exact canonical
  duplicates, keeping widened searches focused on editable code.
- Register the Python binding in the parent workspace so development and tests
  import the local package reliably. The production image deliberately omits
  the package, the binary, and the repository corpus, making repository search
  unavailable instead of searching an unrelated container filesystem.
- Replaced the T3 freshness overlay's per-file `readdir()` + `statFile()` walk
  with `getattrlistbulk(2)` batched directory enumeration on Darwin
  (src/corpus/tree/bulkstat.zig — hand-declared FFI, no Zig std binding
  exists), collapsing O(files) metadata syscalls into O(directories) bulk calls
  that return name+type+mtime for every sibling at once. Fails soft,
  directory-by-directory, back to the exact prior stat-based walk on any
  bulk-call error — never a false negative, only a speed trade. Differentially
  tested against the old walk (bulkstat_test.zig) for byte-identical output.
  Measured on this corpus (18.9k files, ReleaseFast, back-to-back A/B toggle
  under identical load): the freshness+cold-load "pre" phase dropped from a
  52-66ms range (median ~57.6ms) to 47-54ms (median ~51ms), an ~11% cut with
  roughly half the variance.
- Replaced the freshness walk's static one-thread-per-root sharding with a
  self-balancing work-stealing pool (src/index/trigrams/fresh.zig:
  buildWorkItems/Worker/workerRun). The old scheme pinned one thread per entry
  in `default_roots` regardless of size — on this repo `services`+`clients`
  outweigh `contracts`+`quality` by 40x+, so wall time tracked the single
  slowest root while the other threads sat idle well before it finished, and
  never used more than 6 threads no matter how many cores were free. The walk
  now breadth-expands roots one directory level at a time (via
  `getattrlistbulk`/`Dir.Iterator` one-level listings) until there are `ncpu *
  8` fine-grained work items, then dispatches them across an atomic-cursor pool
  of `ncpu` workers — self-balancing regardless of which subtree happens to be
  huge, and more resilient under contention since a stalled thread only holds
  up one small unit of work instead of an entire multi-thousand-file root.
  Measured on this corpus (16 cores, real contention from concurrent
  coworking-agent load, load avg ~9.4): the "pre" phase (cold-load + freshness)
  median dropped from ~51ms (post-bulkstat, static shards) to ~40ms, and a
  head-to-head against ripgrep on the same corpus flipped from GIST trailing to
  1.93x faster (σ 9.8ms vs rg's 54ms) on a corpus-saturating literal — the exact
  high-match
  "saturating pattern" the README previously called out as GIST's weak spot —
  and 6.45x faster on a selective literal (`fetchAdd`).
- Rewrote the package root and relate READMEs to the OSS convention (What it is
  / Why it exists / Prior art): measured wins with harness citations, honest
  prior-art framing (csearch/RE2/FM-index/LZJD lineage, Hyperscan and
  embeddings deliberately declined), and the relate corpus-policy asymmetries
  documented.
- Stack-backs common query and worker scratch while reusing retained verifier
  output capacity, removing up to six allocator round trips from repeated
  searches without changing match order or semantics.
- Structural-debt and efficiency sweep across the search planes. The serial
  engine's index-freshness stat-walk now overlaps the gather walk on its own
  thread (mirroring the parallel engine's lazy elide loader) — ~10% faster
  serial runs on a warm indexed corpus. `Emitter` gained a caller-threaded
  reusable `Matcher.Sim` slot (per-worker in the pipeline, per-run in the
  serial
  engine), replacing three allocations per file; `queryAny` branches share one
  lazy `doc_count`-sized decode scratch instead of alloc/freeing per needle.
  The
  last ASCII case-fold twins (`args.lowerDup` / `ignore.lower`) collapsed into
  `paths.lowerDup`. Four >500-line files (`syntax.zig`, `regex/core.zig`,
  `encoding.zig`, `grepfile.zig`) got MONOLITHIC markers + registry rows.
  Byte-parity verified before/after on literals, alternations, and regex
  queries; the rg line-parity, equality, and freshness gates all pass.
- The `gist` CLI — the on-PATH product binary (`~/.local/bin/gist` →
  `zig-out/bin/gist`) whose whole reason to exist is out-running ripgrep — now
  builds **ReleaseFast by default**, so a bare `zig build` (the step that
  refreshes the installed binary) can no longer silently install a Debug build.
  A Debug `gist` is 4–8× slower — a rare literal over the repo took ~4.5 s and
  a
  common substring (`tel`) ~8.3 s — which reads to a caller like a hang ("runs
  forever"). The same queries on the ReleaseFast binary are ~0.9 s (near
  ripgrep's ~0.5 s over the same six roots), the search path it was always
  meant
  to be. The build stays overridable: `zig build -Dcli-optimize=Debug` yields a
  debug CLI for engine work, and tests / kcov coverage / the C-ABI libs keep
  their standard safety-checked, DWARF-carrying default optimize untouched —
  the
  CLI now links a dedicated ReleaseFast engine module so only the product
  surface
  is affected.

  The gitignore matcher (`ignore.zig`) is now bucketed by source directory
  instead of one flat rule list. A candidate path can only be governed by rules
  from its own ancestor directories — a `.gitignore` scopes its subtree, never
  a
  sibling's — so `decide` consults just the CWD/ancestor tier plus each
  ancestor
  dir's bucket (O(path depth)) rather than testing every path against every
  rule
  ever loaded anywhere in the tree (O(paths × rules): rules were never scoped
  back out as the walk unwound). Loaded-dir dedup moved from a linear scan to a
  hash set (O(dirs), not O(dirs²)). Verdicts are byte-identical — the same rule
  sequence per path, minus the sibling rules that could never match — verified
  against the full `rgsuite` differential harness (275 supported-surface PASS,
  no ignore regression) and an unchanged 16 179-file walk set; ~10–13% faster
  on
  whole-tree queries here, and asymptotically far better on deep, ignore-heavy
  trees.
- The `rg`-compatible engine now runs on a parallel fused walk+read+match
  pipeline (`src/runtime/cold/engine/parallel.zig`): work-stealing directory
  walk with immutable per-dir ignore chains + a compiled literal/extension
  ignore tier, bulk-stat listings, inline index/freshness read-elision loaded
  asynchronously, a required-literal SIMD line gate (now also under `-w`), and
  per-worker sorted fragments k-way-merged into byte-identical (sorted) output.
  Ineligible flag combinations fall through to the proven serial engine
  unchanged. Warm-tree result: gist beats ripgrep on every benchmarked shape —
  1.2x on `--files`, 1.5–1.8x on scoped/filtered searches, 2.9–4x on whole-repo
  literal queries.
- The cold engine's match+emit phase now fans out across cores for the modes
  the parallel work-stealing engine leaves on the serial path — `--json`,
  `--stats`, `--sort`/`--sortr`, `-r` replace, and `--files-without-match`.
  Each shards its per-file work over byte-balanced `shardBounds`/`fanOut` (the
  shared `kernel/math/parallel.zig` primitive the warm engine's
  `streamParallel` already proved), renders into a per-shard buffer, and merges
  in file order, so the bytes stay identical to the serial loop. The soft/hard
  output budget is unified into one `corpus.appendBudgeted` helper that cuts
  the merged stream at the same per-file boundary the serial `outputFull` break
  would hit — the parallel truncation point is byte-for-byte the serial one
  (`--json` carries its per-file summary tally to the matching cut).
  `GIST_NO_PARALLEL` forces the serial emit so the parity harness exercises
  both paths against each other.
- The cold walk no longer re-enumerates an unchanged tree. `gist index` now
  publishes `tree.map` — a self-anchored directory-membership snapshot (names +
  kinds, recorded with the query walk's own admission semantics) — and the
  parallel engine proves each recorded directory current with ONE `lstat`
  (POSIX bumps a directory's mtime/ctime on any direct membership change,
  compared conservatively against the snapshot anchor exactly like the T3
  freshness overlay), serving its child list straight from the mapping instead
  of `openat`+`getattrlistbulk`+`close`. Membership only, fail-open everywhere:
  ignore/hidden/glob admission is decided live per entry, a stale or unrecorded
  directory (and any subtree behind a changed level) live-lists and resumes
  phantom below it, admitted files still `lstat` live before index elision may
  skip them, explicit positional roots resolve into the snapshot by name, and a
  missing/corrupt/future-dated `tree.map` (or `GIST_NO_PHANTOM=1`) returns the
  walk to its live path byte-identically. Walk-bound shapes moved most: on the
  home corpus `-g '*.go'`/`-t go` races went 2.2× → **7.6–7.8×** over ripgrep,
  the whole-matrix span is now 2.3×–16.1× (19/19 wins, floors republished), and
  rgsuite holds 409/409 on both engines.
- The in-process C search callback (`irregex_match_fn`) now returns `int32_t`
  instead of `void`: return 0 to keep receiving matching lines, or non-zero to
  STOP the stream early — a bounded / first-match query then returns
  `IRREGEX_MATCH` and leaves the rest of the corpus unscanned, so it costs only
  what it reads. This one general primitive subsumes per-call max-count /
  first-only / exists-early without widening the ABI surface. The callback
  signature change bumps `irregex_abi_version` 1 → 2 (mirrored across
  `contract/search_api.toml`, the Python `ABI_VERSION`, and the Rust
  `ABI_VERSION`); the halt is plumbed through the shared resident match stream
  (`emitDoc`/`search`) and exercised end to end by the C-ABI smoke test.
- The no-prefilter scan floor dropped across the board — every pattern in the
  permanent gate now beats ripgrep by 1.48–2.25×, including the formerly-losing
  sparse `panic|0x` case (0.93× → 1.60×). The structural changes: candidate
  files are read in two stages (a 64 KiB prefix first; `-l` emits from a
  prefix-proven match without reading the tail — 86% of corpus bytes are tails
  of >64 KiB files — and the tail read rescans only unseen bytes plus a
  literal-width seam window), opens resolve one path component against the
  walk's still-open parent directory fd (`openat`) instead of re-walking the
  full path, a pattern that is exactly a pure-literal alternation is answered
  by a fused single-pass SIMD `containsAny` (per-needle first+last-byte
  fingerprints over shared block loads) as a match equivalence with no regex
  engine run at all, and each pipeline worker reuses one match-scratch across
  every file it searches. Match sets stay byte-identical to rg (0 FN / 0 FP on
  the live-tree gate; 140-literal + 70-regex oracle clean; all 11 live certify
  ratio classes clear their committed floors).
- The resident `gist serve` daemon now scales across the coworker fleet and the
  largest corpora without regressing warm latency or the parity contract
  (`resident == gist --no-index == rg`):

  - **Concurrent warm queries.** The poll thread stays the sole connection
  owner
    but now dispatches `query`/`query_ext` frames to a persistent worker pool
    (`min(cpu/2, 8)`, `GIST_SERVE_WORKERS` override, `serve.zig`): an in-flight
    query leaves the poll set, its worker owns the fd and writes the response
    (incl. `chunk_fd`) directly, and a self-pipe wakeup re-registers the fd on
    completion — so one slow scan no longer stalls every other client's
    clean-window probe. `hello`/`status`/`ping`/`changed`/`shutdown` stay
  inline;
    the reconcile/abort counters the poll thread samples are now atomic. The
    session rides the `ward` reader/writer discipline, so readers answer in
    parallel and only a reconcile takes the writer lease.

  - **Shard-backed resident mirror.** `corpus.load` is now a two-tier byte
  store
    (`session/corpus.zig`): an unchanged member binds its bytes to the
  persisted
    `content.shard` mmap (zero heap, page-cache-evictable) and only a
    changed/new/binary/oversize/BOM-carrying doc — or the whole corpus when no
    shard is on disk — heap-reads. Resident heap drops from O(corpus) to
    O(churn + exceptions) with byte-identical ingest (full body, BOM/UTF-16
    decode, whole-body first-NUL offsets, empty docs dropped); no shard ⇒
    fail-open to the old full-heap mirror.

  - **Linux exact scoped reconcile.** The inotify backend realpaths its roots
  and
    `note`s each changed path into the dirty log (unmapped wd / malformed
  record /
    `Q_OVERFLOW` ⇒ doubt), arming exactness on case-sensitive roots
    (`FS_IOC_GETFLAGS`/`FS_CASEFOLD_FL` gates a casefolded root back to
  coarse).
    Linux now reconciles O(changed) like macOS FSEvents instead of always
  walking
    the tree.

  - **Non-ASCII paths scope too.** The `delta` resolver drops its "any byte ≥
  0x80
    ⇒ needs_full" gate: `realpath` canonicalizes macOS case + NFC/NFD aliasing
  to
    the on-disk spelling, so non-ASCII events resolve to normal
    `file`/`subtree`/`gone` verdicts. The one residual hazard — a stale
    normalization/case TWIN of a path the batch never named — is retired by a
    session-side sweep of the (almost always empty) set of non-ASCII corpus
  keys
    through `keyIsCurrent`, O(changed + |non-ASCII keys|). Adversarial
    `scoped_test.zig` cases (case-rename, NFC↔NFD twin, delete-then-recreate
  under
    another normalization) assert scoped answers stay oracle-exact.
- The resident session's freshness proof is now O(changed) instead of O(tree)
  whenever it can be proven sound. macOS FSEvents runs with per-file events and
  feeds an exact dirty-path log (`src/runtime/session/dirty.zig`: bounded,
  deduped,
  overflow/OOM ⇒ sticky doubt); the reconcile drains it and — when the backend
  promised exactness, the batch is doubt-free, one covering full pass already
  ran, and no ignore-semantics path (`.gitignore`/`.ignore`/`.rgignore`, `.git`
  topology) is in the batch — verifies exactly those paths through the cold
  walk's own `Ignore` admission rules (`src/runtime/session/delta.zig`:
  canonical
  realpath mapping, ASCII case-alias tombstoning, subtree enumeration for
  coalesced directory events) instead of re-walking the tree. Every refusal
  degrades to the full walk, never to trusting stale bytes; `.git` internal
  churn (index/objects/refs) now costs a hash probe instead of a full
  reconcile.
  Rootless daemons previously armed an FSEvents stream over an empty path array
  and silently watched nothing (reconcile-always); they now watch `.`. Linux
  inotify stays coarse (never arms exactness) and now poisons the session
  permanently on queue overflow or an unwatchable newly-created directory
  instead of racing a staleness hole. Measured on this 150k-file repo: an
  edit-then-query warm cycle drops from ~290 ms (full covering walk per dirty
  query) to ~6.6 ms (scoped drain), ~44× on the O(changed) path, with
  warm-clean
  latency and the cold/unindexed paths unchanged. Adversarial suite
  (`src/runtime/session/scoped_test.zig`) asserts scoped answers against an
  independent
  on-disk oracle and proves the fail-closed degradations (ignore-source edit,
  doubted/overflowed batch, non-exact backend, poisoned watcher, racing
  writes).
- The unified-search contract (`contract/search_api.toml`) now reports `uds` as
  an `operational-accelerator` rather than `machinery-landed-daemon-planned`:
  the `gist serve` daemon, its fail-open front-door client, and the `gist
  serve` verb are landed, wired into the bare-`gist` path, and covered end to
  end (`src/commands/{serve,client}`, `src/commands/serve/serve_test.zig`), so
  both `subprocess` and `uds` are callable transports today — the warm path
  routes only what it answers byte-identically to cold
  (`-l`/files-with-matches) and falls open to `subprocess` otherwise.
- (in `gist`) The warm resident session (`src/runtime/session/resident.zig`) and the cold…
- Un-hardcoded the corpus roots — gist and relate now index and query any tree,
  not just the monorepo it was born in. `gist index [ROOT...]` / `relate index` take
  roots positionally; with none given, `corpus.resolveRoots` picks per tree (a
  `GIST_ROOTS` env override split on `:`/`,`/space, else `.` — the whole tree).
  Every artifact is now self-describing: the trigram index generation-publishes
  a NUL-separated `roots.list` beside `index.gist`/`paths.list`, and the
  kinship atlas format bumped to v2 with an embedded roots blob — queries,
  read-elision, `--rank`, freshness stat-walks, `status`, and the codex shelf
  all scope to the _persisted_ build roots instead of a compile-time constant.
  A `.` root normalizes to bare relative paths (`joinRoot`), so foreign-tree
  output is byte-identical to a live scan. Legacy pre-roots artifacts (missing
  `roots.list`) fall back to `.` on load — a sound superset (elision keys on
  the persisted path set); atlas v1 reads as corrupt and rebuilds. Verified
  end-to-end on the CPython corpus: `gist index` inside the foreign tree,
  indexed-vs-`--no-index` output parity, and ~4× warm elision (11 ms vs 48 ms).
- Unified the four duplicated corpus walkers (index build, --live, T3 freshness
  stat-walk, no-prefilter live scan) onto one shared Haystack/Walker
  abstraction (src/corpus/tree/haystack.zig), and hand-tuned its two per-call
  hot paths in the process: isSkipDir moved from a 35-entry linear std.mem.eql
  scan to a comptime std.StaticStringMap (18.5ns to 2.8ns/call, 6.6x, measured
  over 1786 real repo directory basenames), and the per-file root/rel path join
  moved from std.fmt.allocPrint to a manual sized alloc + memcpy (20.9ns to
  9.9ns/call, 2.1x, measured over 200k calls) since the walk yields 18.9k files
  but only thousands of directories.
- _2026-07-19_ — Build: **`engineModules` + `twin` for post-hoc decorations.**
  The root/test-twin framework + PCRE2 wiring collapses to one loop; the CLI
  engine is a `kernelkit.twin` at `-Dcli-optimize` instead of a hand-rolled
  `createModule`.
- `--type-list` now prints in ripgrep's exact presentation — type names sorted
  lexicographically (one line per alias) and each type's globs sorted
  lexicographically — over a strict superset of ripgrep's type registry. Most
  rows are byte-identical to `rg --type-list`; the remainder differ only by
  being richer (gist-only types and per-type glob enrichments).
- `-U` multiline now rides the parallel per-file pipeline instead of falling
  through to the serial engine, and an assertion-free multiline pattern
  (nothing positional to resolve — no `^ $ \b \A \z`) determinizes exactly, so
  `bufMatch` answers from the O(1)/byte byte-class DFA instead of a Pike
  re-seed per position; `-U -l` additionally short-circuits at the first kept
  span (`Emitter.buffer` files-only fast path). Both declared `-U` matrix
  losses flip to wins — `multiline-rare-files` 0.84x → ~3.5x and
  `multiline-common-lazy-dotstar-files` (`import \([\s\S]*?\)`, the table's
  deepest loss) 0.36x → ~2.8x — with byte-identical parity held by a new
  assertion-free-multiline differential fuzz lane against the Pike oracle.
- `-w` word searches now ride the required-literal gate (`\bLIT\b` can only
  match where LIT occurs — the boundary check only ever rejects), and the
  emitter gained a per-line SIMD memmem gate so lines without the literal never
  touch the regex engine. `-w Config` over a large Go service tree dropped from
  72ms to 43ms (user CPU 297ms → 62ms), 1.5x faster than ripgrep.
- `walkFresh` now runs its first shard inline on the calling thread and only
  spawns workers for the rest, so a single-shard walk (a small tree — the
  common resident-reconcile case, hit on every non-clean query) spawns zero
  threads instead of paying a spawn+join per query, while a multi-shard walk
  still saturates every core with the caller taking a share rather than idling
  on join. Output is byte-identical; this is a scheduling change only.
- `zig build test` is ~4× faster (5.5 min → ~85 s) and a passing run is now
  silent. The unit-test binary is pinned to ReleaseSafe via kernelkit's new
  `test_optimize` knob — the differential-fuzz suites (DFA vs Pike, powerset
  language equivalence, adversarial oracles, index-loader mutation soak) keep
  every safety check at optimized speed; `-Dtest-optimize=Debug` restores a
  debuggable binary and the kcov `coverage` step stays Debug for full DWARF.
  The daemon's "serve: warm" lifecycle line and the `-rn` grep-ism note are
  suppressed under test builds — any stderr from a passing test binary made
  Zig's build runner print a spurious `failed command:` banner on green runs.
- gist: collapse the ripgrep-compatibility matrix to two live categories —
  `supported` (behaves as rg) and `improvements` (identical-or-superset results
  that are strictly better: `--binary`, `-P/--pcre2`, `-z/--search-zip`,
  `--sort`/`--sortr`, `--type-list`). The former "supported-with-differences"
  bucket is gone: the six over-claiming rows were reconciled to parity and
  `--pre` now feeds the file's bytes on the child's stdin as well as the path
  argv (rg's exact contract, deadlock-free via the open file fd), closing the
  last genuine gap. `gist --schema` reports the new `improvements` bucket; the
  transforms parity slate adds an argv-ignoring stdin-only preprocessor case.

### Removed

- Drop the README-only cli/irg umbrella-CLI contract; gist and relate remain
  the product faces.
- Removed the orphaned `scan/sweep.zig` no-prefilter live-scan prototype: its
  fused work-stealing walk+read+scan idiom had already graduated into the
  production `faces/cli/search/engine/parallel.zig` engine, leaving the module
  with zero callers repo-wide (proven via gist + repo-wide grep). The `scan/`
  tier is now exactly the byte-level verify primitives (`simd` + `verify`); the
  READMEs and source comments that cited the dead path are reweaved onto the
  engine that actually drives the fan-out.

### Fixed

- **A leading `(?flags)` inline directive died with a bare `bad pattern`.** The
  README promised rust-regex/rg's leading flag-group syntax was "honored where
  gist can, loud where it can't", but the parser rejected every `(?…)` group
  outright — `gist '(?i)todo'` exited 2 with no reason and no fallback, a
  pattern ripgrep accepts.

  `combinePatterns` now resolves a leading `(?flags)` directive per pattern
  (`stripLeadingFlags`): `(?i)`/`(?-i)` set ASCII caseless run-wide (riding the
  same plumbing as `-i`, overriding a resolved `-S`, exactly rg's
  inline-beats-CLI precedence); `(?m)`/`(?s)` and negations are inert in the
  per-line model (`^$` already anchor every line, no line carries a `\n`);
  `(?-u)` is inert (byte semantics are gist's native behavior). Directives the
  engine genuinely can't reproduce — `(?u)` `(?x)` `(?U)` `(?R)` — and mixed
  per-pattern case demands across `-e`/`-f` patterns (gist compiles one global
  engine; rg scopes flags per branch) fail loud with the reason and the rg
  fallback. Under `-F` the bytes `(?i)` stay a literal, as in rg. The generic
  bad-pattern death (lookaround, backreferences, mid-pattern flags) now names
  the pattern, the reason, and the `rg` fallback instead of a bare
  `bad pattern`. Guarded by unit tests plus a case-twisted black-box exit-code
  guard in `build.zig` (`zig build test`).
- **Finished the search-engine unification the previous entry started.** The
  `search` verb's removal (see `unify-search-engine`) left the old
  `src/commands/search/` package dead (deleted, minus its one still-needed
  `looksLikeRegex` helper, moved into `ripgrep/args.zig`), `root.zig` still
  exporting/testing it, and stale doc comments across `index/persist.zig`,
  `corpus/corpus.zig`, and `corpus/haystack.zig` pointing at it.

  **The bench gates and README were still asserting the pre-unification
  contract.** `bench/gates/streams.sh` and `bench/gates/scan_regress.sh` (plus
  `bench/races/_compete.sh`'s shared invocation helpers) still shelled the
  removed `gist search <pattern> --show files` syntax and asserted the old
  `search` verb's wider-than-`rg` corpus (`--no-ignore --hidden`) and a
  "routes to the live scan" stderr announcement that no longer exists — so both
  gates were silently non-functional (argument-parse failures, not green
  checks) rather than actually verifying anything. Rewrote both against the
  unified engine's real contract: `gist <pattern> -l`, `.gitignore`/hidden
  parity with `rg`'s default, and stderr silent except `--rank`'s timing line.
  `scan_regress.sh` now surfaces real FN/FP counts against `rg` for
  no-prefilter patterns instead of skipping the comparison — worth a follow-up
  look, since a first run found genuine mismatches (binary-file handling
  divergence) it was never actually catching before.

  `README.md`, `bench/gates/README.md`, `src/commands/cli/README.md`, and the
  `project-overview.mdc` navigation line were all rewritten to match: the
  canonical usage is the bare `gist <pattern>`/`gist rg`, `.gitignore` and
  hidden-file semantics now match `rg` exactly (no more documented
  superset-of-`rg` corpus), and `--rank`/`-l` replace the removed `search
  --rank`/`--show files` spelling throughout.
  (see also: gist)
- **`gist` could hang forever with no output.** `readableStdin()` mirrors
  ripgrep's own `is_readable_stdin` check (regular file, FIFO, or socket on fd
  0
  ⇒ search stdin instead of walking the tree) — correct against a real shell
  pipe, but some sandboxed shell/tool-call harnesses wire fd 0 to a long-lived
  socket that never writes a byte and never closes. A blocking `read(2)`
  against
  that blocks indefinitely; an agent-facing tool can't afford that.

  `readableStdin()` now classifies fd 0 by stream type (`stdinKind`) and guards
  _only a socket_: a socket is admitted to the stdin path — and each chunk of
  its
  read loop is gated — through a 200 ms `poll(2)` deadline, so the pathological
  "open forever, silent" control channel times out and falls through to the
  directory walk instead of hanging. A FIFO (pipe) or regular file is
  classified
  readable immediately and block-read straight to true EOF with **no** poll
  guard:
  `cmd | gist pattern` is the canonical stream, a slow or paused writer just
  makes
  `read` wait, and the writer's close is the EOF — byte-for-byte ripgrep, with
  no
  delayed-pipe truncation. (An earlier revision poll-guarded FIFOs too, which
  dropped a producer whose first bytes arrived after the deadline to the walk —
  a
  delayed-pipe false negative this split eliminates.)
- A resident file reconciled into the mutation overlay and then deleted is no
  longer reported off the watcher-clean path: overlay matches are now
  existence-checked with the same fail-closed stat-per-hit the base docs use,
  so a delete that vanishes from the metadata walk can never surface a stale
  hit (preserving resident==rg).
- An explicit PATH arg that can't be opened (missing/unreadable) is now
  reported to stderr and forces exit 2, matching ripgrep; previously such a
  path was dropped silently with a no-match exit 1, which read like an instant
  crash on a typo'd path (e.g. 'gist search tel').
- CREST now distinguishes epsilon, unknown, and optional profiles, preserves
  one-sided class certificates through repetition, and saturates large counted
  powers without the former 4,096-copy precision clamp.
- (in `gist`) Closed the last supported-surface divergences between `gist rg` and ripgrep…
- Cold-query evidence now fails closed before measurement: every gist timing
  cell proves its complete file set against official rg, timed wrappers
  preserve hard failures, and deterministic gates reject both status and
  semantic faults. Line parity generates the cited 265,286- and 147,087-line
  classes on demand and requires exact bytes for explicit files on both
  engines. Certificate bundles now carry microscopic and macroscopic CSVs,
  hashed corpus rows, exact executable identities, raw-cell/command parity, and
  honest runtime-cache versus evidence-workspace accounting, with fresh and
  committed bundles both gated.
- (in `gist`) Fixed a drift risk between Layer A (`certify.zig`) and Layer D…
- Fixed two `rg`-compat bugs found by adversarial-testing against ripgrep's own
  issue history: files at/above the 4 MiB indexing-corpus budget silently
  returned zero matches instead of being searched in full (the read path reused
  `per_file_cap` as a hard ceiling; it now keeps reading past it), and
  `-L`/`--follow` hung forever on a self-referential symlink cycle (the depth
  counter alone didn't stop it; the walk now also tracks each ancestor's
  realpath and refuses to re-descend into one already on the current DFS stack,
  while still following legitimate non-cyclic diamonds).
- Gist's public claims now match its shipped surface: `--schema` renders a
  four-bucket ripgrep compatibility matrix from the parser's own declarative
  flag catalog, including ASCII-only `-i`/`\b`/`\w` differences and fail-loud
  exclusions; the C ABI is documented and gated as the existing two-symbol
  primitive surface, with a real C compile/link/run smoke in `zig build test`;
  and `PRIOR_ART.md` distinguishes Gist's agent-workload composition from
  established indexed, semantic, and structural code-search systems.
- Linux targets build again. Zig 0.16's `std.c` declares no `fstat`/`fstatat`
  on
  Linux and `std.posix.close` is gone, which had silently rotted every
  comptime-pruned Linux leg (`--one-file-system` device ids, `--sort created`
  birth times, stdin classification, the mmap fast path's sizing stat, the
  session reconciler's lstat, and the inotify watcher's fd closes) — invisible
  from the macOS dev boxes. Raw stat now lives behind one portable shim
  (`grepfile.RawStat` + `statPath`/`lstatPath`/`statFd`): `statx(2)` on Linux,
  the exact libc `fstatat`/`fstat` calls it replaced everywhere else, so macOS
  behavior is byte-identical while Linux additionally gains real `statx` BTIME
  birth times for `--sort created`. Watcher closes use `std.os.linux.close`
  directly in their comptime-Linux branches. A `zig build check-linux` drift
  gate (folded into `zig build test`) cross-compiles the full CLI module for
  x86_64-linux as a no-link object — full Sema + codegen over every
  Linux-reachable line in ~1 s warm — proven to fail on exactly this class of
  breakage; x86_64-gnu, x86_64-musl, and aarch64-gnu full builds all verified
  green.
- Made indexed read elision fail closed on local filesystem change metadata:
  Darwin bulkstat and portable stat now carry both mtime and ctime, and a file
  is live-read when either clock is at/after the build anchor or either value
  is unavailable. This closes ordinary preserved-mtime append and same-size
  overwrite false negatives without per-query content hashing. The tracked
  model now qualifies timestamp resolution and concurrent-write semantics,
  while the >1024-file filesystem gate synchronously requires real elision and
  covers mtime/ctime equality, add/edit/delete/rename, unreadable directories,
  and serial-overlay compatibility.
- Multi-root queries that sweep large gitignored files (rg-parity re-anchors
  CWD-tier ignore rules per explicit root, pulling multi-GiB training blobs
  into the scan) no longer pay a copy-loop tax: `readTail` now maps the whole
  regular file read-only via `mmap` and re-views the already-drained prefix
  through the mapping — one consistent snapshot, zero intermediate copies —
  falling back to the old growable-buffer read only when the fd isn't a regular
  mappable file. `gist pgxpool services libs -l` dropped 543 ms → ~190 ms warm
  (rg: ~180 ms), output byte-identical.
- Promote gitignore admission into the shared corpus layer so gist indexes,
  relate, and composed irregex exclude ignored and hidden files with the same
  precedence as live gist search.
- Published certificates now pass through the repository's canonical prose
  formatter before artifact verification, preventing generated Markdown drift.
- Ranked --rank snippets now window around the match instead of taking a
  leading 120-byte prefix, so a hit past column 120 still surfaces the matched
  token (with … markers on truncated edges) instead of a line of filler with
  the token gone.
- Reconciled the C-ABI compatibility integer so every axis agrees on the
  truthful value. The rung-3 match callback (`irregex_match_fn`) had already
  gained its `int32_t` abort return — a breaking signature change the changelog
  documented as stepping `irregex_abi_version` 1 → 2 — but `src/root.zig`'s
  `abi()`, the `build.zig` C smoke assertion, and the Python FFI loader
  (`_ffi._ABI_VERSION`) were never bumped, so the live library reported `1`
  while the contract, the Python/Rust mirrors, and the changelog all claimed
  `2`. `abi()` now returns `2`, the C smoke asserts `2u`, and the loader gates
  on `2`; the contract `[meta]` comment additionally spells out that the C-ABI
  integer, engine semver, UDS protocol version, and persisted index/atlas
  formats are independent version axes.
  (see also: relate)
- Relate search and pack now nominate from the persisted trigram codebook
  instead of rebuilding a whole-corpus fingerprint lexicon per query, recover
  three-byte queries such as `dog`, bound exact cross-parsing to query-bearing
  evidence windows, and choose live sketching automatically when a narrow scope
  is cheaper than loading the global atlas.
  Warm retrieval now shares canonical scope and coverage kernels, distinguishes
  foreign chunks from ubiquitous zero-bit evidence, rejects non-finite
  similarity thresholds, and falls back live instead of retaining stale atlas
  rows after refresh failure.
- The freshness walk (`index/trigrams/fresh.zig`) no longer emits a file twice
  when its parent directory expands to children but no subdirectories:
  `buildWorkItems` re-queued such childless directories as leaf items after
  `expandOneLevel` had already emitted their files, double-visiting every file
  underneath. Surfaced by the kinship-atlas fold tests (a changed file
  re-sketched twice inflated the folded path count); fixed at the walk so every
  consumer of the changed-file report sees each path exactly once.
- The in-process C-ABI session seam is now null-hardened: gist_open with a null
  out (or null roots with nroots > 0) and gist_search with a null pattern
  (pattern_len > 0) return GIST_INVALID instead of dereferencing blind, and
  nroots == 0 / pattern_len == 0 never read their pointer. Also fixed an
  OOM-path leak of the transcoded body in the mirror's readDocOwned.
- The parallel ripgrep engine (pipeline.zig) had regressed two rg-parity fixes
  present in the serial engine: -g/--iglob whitelist overrides for ignore rules
  were not respected, and directory-walk errors (e.g. EACCES) were silently
  swallowed instead of exiting 2 like ripgrep. Both are now ported into the
  parallel engine, and the line_parity, freshness_fs, and rgsuite test
  harnesses now exercise both engines (serial forced via the internal
  GIST_NO_PARALLEL env var), confirming genuine zero-FAIL parity on both.
- The persisted-index loader now verifies the doc→path table matches the index.
  `persist.load` mapped `paths.list` and split it without checking the count,
  so a torn or stale table (fewer or more entries than the index's `doc_count`)
  could let a candidate doc id — bounded `< doc_count` by the index but never
  against the table — index past `paths.items`. `validatePersistedPair` now
  requires `paths.len == doc_count`; a mismatch is treated as a no-usable-index
  miss (fall back to the full walk with rebuild guidance) rather than a
  possible out-of-bounds path lookup. The NUL-split is factored into
  `parsePathTable`, and both are unit-tested in `persist_test.zig`.
- The resident session's reconcile no longer re-reads the whole corpus on every
  query: its freshness cursor is anchored at the session's own load instant
  (captured before the corpus read, so a write racing the load is caught by the
  first reconcile rather than baked into stale base bytes) and advances
  incrementally per reconcile, instead of being pinned backward to the
  persisted index's global build anchor — a different index's clock that
  predates any file touched since the last `gist index` and silently defeated
  the incremental catch-up, forcing a full corpus re-read (and a metadata-walk
  thread pool) on every warm query.
- The resident session's socket writes can no longer kill the daemon (or a
  client) with SIGPIPE when the peer half-closes mid-write: `protocol.writeAll`
  now issues a no-signal send (Linux `MSG_NOSIGNAL`; Darwin/BSD `SO_NOSIGPIPE`
  armed idempotently on the fd), so a broken connection surfaces as EPIPE and
  costs one dropped connection instead of a fatal signal that takes down the
  whole process. The CLI's stdout SIGPIPE (the `gist | head` early exit) is
  deliberately left intact.
- The single-byte legacy decoders (`x-user-defined` and the windows/ISO/KOI/mac
  table family) reserved `buf.len` bytes up front and then used
  `appendAssumeCapacity` for ASCII bytes — but once an earlier high byte
  expands to multi-byte UTF-8 via `appendSlice`, the geometric growth policy
  guarantees no spare headroom, so a long ASCII tail after enough high bytes
  could write past the reservation (undefined behavior in ReleaseFast, an
  assert in Debug). Caught by a 4000-buffer differential fuzz over all 35
  legacy encodings during the decoder consolidation; both paths now use
  bounds-checked appends, decoding byte-identically on every input that didn't
  crash before.
- The soft output budget (the ~25k-token agent-context guard) now applies
  symmetrically across every content-search path. A warm daemon-served answer
  is pre-rendered as one buffer, so the client's single stdout write previously
  let the whole result land — the crossing-fragment-lands-whole straddle
  silently defeated the cap, dumping the full result (e.g. 9.4 MB) where a
  daemon-less --no-index run truncated at ~100 KiB. The warm client
  (emitRaw/emitFd) now bounds via corpus.writeStdoutCapped, cutting at a
  whole-line boundary; because the daemon renders in canonical path-sorted
  order the surviving prefix is the same reproducible cut the cold serial
  loop's outputFull poll produces (stable run-to-run), not the parallel sink's
  order-nondeterministic subset. Under the cap the paths stay byte-identical;
  GIST_UNCAP still lifts it.
- Warm client gates every post-connect recv with a 2s poll deadline so a wedged
  daemon (accepts but never READY) falls through to cold instead of parking
  forever.
- `--json` now disables index read-elision, exactly like `--stats` always has.
  The JSON summary message embeds the same `searches`/`bytes_searched`
  counters, so eliding index-cleared files under-reported both relative to
  ripgrep (which reads every walked file) — acceleration was changing
  observable output, caught by the multi-corpus sweep on CPython. With the gate
  added to `trigramFilter`, the full 472-case sweep (5 corpora × both engines)
  passes clean.
- `--rank` now compiles the pattern through the same regex engine as the line
  search (so `foo|bar` and `claim.*job` rank real matches instead of looking
  for those bytes literally) and honors positional PATH roots when scoping the
  candidate set.
- `codex.Cursor.bytes` guarded reads with `pos + len > buf.len`, which can wrap
  on an adversarial huge length and risk a safety panic instead of a verdict.
  The check is now the overflow-proof `len > buf.len - pos` — identical on
  every non-overflowing input, and a corrupt blob declaring an absurd length
  now fails closed with `error.Corrupt`. Atlas's near-identical private cursor
  (which already used the subtraction form) is deleted in favor of the shared
  `codex.Cursor`, so CDX1/SHLF/ATLS parsing all take the hardened path.
- `engine.count` (the cold oracle behind `gist.count`/`Session.count`) counted
  per-occurrence via `--count-matches`, contradicting its own docstring ("total
  matching lines") and silently diverging from every warm path — the resident
  daemon's `countLines`, and the in-process FFI's per-line stream — on any line
  the pattern hits more than once. It now uses `-c`/`--count` (rg line
  semantics: a line is counted once regardless of repeats), so cold ≡ UDS ≡ FFI
  agree, matching the documented contract and doc_radar's own `count_matches`
  ("number of matching lines"). The doc_radar canary's rg oracle was likewise
  counting `--count-matches` (occurrences) while its docstring claimed
  "matching lines" — a latent mismatch masked only because `gist.count` was
  equally wrong; it now counts `--count` (lines), so the byte-equivalence gate
  checks the real line contract. Caught by the new FFI-vs-cold parity test over
  a corpus with a repeated-hit line, plus the doc_radar canary.
- `gist --rank` now falls back to ranking the normal live-walk matches when the
  persisted index is missing, incomplete, corrupt, or explicitly disabled with
  `--no-index`.
- `gist --rank` now honors ripgrep's default binary-file policy, so the ranked
  view is a true reordering of the `gist -l` set rather than a superset. The
  `--rank` no-fabrication certificate invariant caught the divergence: because
  the ranked read pass scanned every candidate's full bytes, a symbol living
  only in a committed binary's symbol table (e.g. `atomic.(*Int32).Store`
  inside
  `tools/mdns_verify/mdns_verify`) surfaced as a ranked hit
  that
  the locate path — and rg — correctly skip.

  - `ranked.zig`'s `fileDoc` clips a NUL-bearing walked file to the bytes rg's
    quit strategy committed before the NUL (`grepfile.committedPrefix`),
  matching
    the locate default; `-a`/`--text` (`binary_detect = false`) reads the whole
    body as text, exactly as `gist -la` does. The rule threads through all
  three
    rank paths — cold index (`run`), live `--no-index` (`runLive`), and the
  warm
    daemon (`renderLive`, where the resident rank path previously leaked
  binaries
    its own `-l`/`-c` visitors already dropped).
  - The `--rank` certificate lane report (`certify_rank_report.py`) now parses
    ranked rows whose paths contain spaces (`(.+?)` up to the `:line [kind]`
    anchor, not `\S+?`) and decodes captures with `surrogateescape`, so a
    non-UTF-8 source line can no longer abort the whole lane.

  Proven by a new fail-closed `fileDoc` unit test and re-validated end-to-end:
  all six rank probes hold 0 fabrication.
  (see also: gist)
- `gist --schema` and the bare `usage()` banner now document the
  `gist <pattern> [PATH...]` shorthand (no verb, no index required) as a
  first-class capability instead of leaving it undiscoverable — the schema
  manifest gained a `"shorthand"` field and a corrected exit-code description.

  Also fixed several stale doc comments left over from the pre-`search`-verb-
  collapse design that misdescribed the whole-tree `rg`-compatible engine: a
  dead `commands/grep/` reference (the folder itself, empty and unused, is
  deleted), and incorrect claims that the engine ignores `.gitignore` and fails
  loud on `--json`/`--column`, when it actually supports both.
- `gist rg` no longer ignore-filters a positional PATH argument itself — only
  what's found beneath it, matching ripgrep's own depth-0 exemption
  (`crates/ignore/src/walk.rs`'s `add_parents`: ancestor ignore state is loaded
  at the root, but the root entry is never matched against it, only its
  descendants are). Previously, naming a directory that an ancestor
  `.gitignore` happened to match (e.g. `gist rg pat upstream/some-dir` when `upstream/`
  is gitignored at the repo root) silently returned zero results — a
  divergence from real `rg`, which always searches an explicitly-named path
  while still honoring ignore rules nested _inside_ it. This made `gist rg
  --files`/`--iglob` unusable as a `find`/`find -iname` replacement for any
  path under a gitignored ancestor, forcing a fallback to raw `find`.

  Fixed with a new `Ignore.scopeToRoot` in `ignore.zig`: a component-depth
  floor on the rule matcher that exempts a positional root's own path segments
  from CWD/ancestor-sourced rules (`Rule.base == ""`) while leaving rules
  loaded from _within_ the given root's own subtree unaffected. Verified
  byte-identical against real `find -iname` and `rg -n -i <files>` on the
  reproducing case, and against the full `rgsuite` differential-parity harness
  (441 mined ripgrep cases, 278/278 supported-surface parity, zero
  regressions).
- `gist rg` now clears the whole mined rgsuite at ripgrep's own assertion bar —
  **409 PASS / 0 ORDER / 0 FAIL** on both engines. The scoring harness honors
  each mined test's upstream comparison mode (`eqnice!` pins bytes;
  `eqnice_sorted!` compares sorted lines because rg's parallel walk is
  genuinely nondeterministic there), which retires the ORDER bucket as a
  soft-pass class. The multiline (`-U`) emitter closes its last nine
  byte-parity holes: CRLF-aware span collection so `$` anchors at logical line
  ends and remaps to original offsets; block-level `-r` replacement matching rg
  #1311 (adjacent matches coalesce into one sink block, non-matching bytes
  preserved, replaced text re-split into renumbered physical lines,
  `--passthru` widens the window); `--vimgrep` per-match-one-line rows (rg
  #1866) with the filename forced on even for a single explicit file; and
  `--trim`/`-M --max-columns-preview` applied per fragment with rebased match
  offsets. `--sort`/`--sortr` semantics now replicate rg exactly: ascending
  `path` is the walker sort (per PATH argument in argv order, component-wise
  within each root), while `--sortr path` and every time key are global
  collect-and-sort with rg's error-files-last (ascending) placement; a
  multi-root `--sort path` over the live tree is byte-identical to rg and ~2.6×
  faster (parallel reads vs rg's forced single thread).
- `session.warm_eligible` (the Python leg's warm/cold router)
  accepted any non-scoped request regardless of pattern shape, so a `\n`, NUL,
  or empty pattern was routed to the resident daemon — whose whole-document
  engine can match across line boundaries where the cold per-line walk cannot,
  a silent warm≠cold divergence. It now declines an empty, `\n`-, or
  NUL-bearing pattern up front, mirroring `session/request.zig::classify`
  term-for-term, so every request the two accept answers byte-identically on
  both paths.
- gist serve now poll-multiplexes its accept loop (listener + every connected
  client in one poll set, one frame per readable client per wakeup), so an idle
  persistent Session no longer starves other clients in the listen backlog —
  previously one agent's long-lived warm session blocked every other agent's
  connect for minutes. The Python binding's Session also arms a 2 s socket
  deadline on connect/handshake/query (the twin of the Zig client's
  client_io_timeout_ms), failing open to the certified cold path instead of
  blocking indefinitely on a busy or wedged daemon.
- gitignore negation semantics are now entity-only, matching git/ripgrep: a
  rule is tested against the candidate itself (full path for anchored patterns,
  basename for slash-less ones), never against ancestor components or path
  prefixes — ancestor exclusion is the walk's directory pruning. Previously a
  re-include like `!tools/indexer/build/` leaked everything beneath it (e.g.
  its `__pycache__/`) into results in both the serial and parallel engines; two
  rgsuite cases regained byte-identical PASS.
- rg-parity fixes across the regex escape parser: \\0–\\9 (backreference
  syntax), unrecognized letter escapes (\\q, \\e, \\Z, …), and assertion
  escapes inside a class ([\\b], [\\A], [\\<]) now fail loud with exit 2
  exactly like ripgrep instead of silently matching a wrong literal; \\A/\\z
  (haystack anchors) and \\</\\> (word start/end boundaries) are now supported
  with rg-identical semantics in both the per-line default and multiline
  engine.

## [0.1.0] - 2026-07-01

### Added

- **Byte-class DFA — the sole non-Pike engine** (`src/regex_dfa.zig`, tests in
  `src/regex_dfa_test.zig`; supersedes and removes the interim bit-parallel
  Glushkov engine). The Pike VM is O(active-threads)/byte, so on the
  no-prefilter
  scan tail — a *selective but common* first byte (`;$`, `[0-9]{4}`,
  `panic|0x`)
  re-seeds a closure at nearly every byte — it lost to rg's O(1)/byte lazy DFA.
  This determinizes the Thompson NFA (Cox → RE2 / rust-`regex` lineage, an
  eager
  capped variant) into an immutable, scratch-free automaton that spends **one
  table lookup per byte regardless of match density**:
  - **Byte classes** collapse the 256-byte alphabet to the handful of columns
  any
    consuming state actually distinguishes (RE2/rust-`regex` `ByteClasses`),
    shrinking the transition table.
  - **Line anchors without a `.*` hack** — `^` is resolved once in the start
    state's closure (`at_start=true`); `$` by a separate **final** transition
    table closed with `at_end=true` (the single-line analogue of RE2's one-byte
    match delay). Unanchored search re-seeds the NFA start into every
  transition;
    an `^`-anchored program never re-seeds and dead-states to `false` the
  instant
    its thread set drains.
  - **Eager + capped** — built at compile (these patterns are tiny); past
    `max_states=4096` the build bails to null and the Pike VM keeps serving (so
    `{1000}`-style expansion stays linear, only a pathological alternation
  trips
    the cap). One immutable `Dfa` is shared lock-free across all reader
  threads.
  - **Single-pass `docMatch`** — scans the whole file buffer in **one fused
  loop**
    that detects `\n` inline, so each byte is touched exactly once. (The
  per-line
    path memchr-scans for `\n` *and then* re-scans the bytes in the automaton —
    double byte-traffic, the dominant cost of a no-prefilter full scan.)
- **Counted repetition `{n}` / `{n,}` / `{n,m}`** (`src/regex_syntax.zig`):
  parsed
  and desugared into the existing node vocabulary (`min` mandatory copies, then
  `(max-min)` optional copies or a trailing `*` when unbounded) — the `atom`
  pointer is shared across copies (the AST becomes a read-only DAG), so the NFA
  compiler and literal extractor are untouched and `ab{3}c` still prefilters on
  `abbbc`. Expansion is capped at 1000 to bound NFA size. **Mirrors rust-regex
  brace semantics exactly**: an unescaped `{` must begin a valid count or it's
  a
  `BadPattern` (ripgrep errors identically — `interface{}` is rejected, the
  literal is `\{`), while a stray `}` stays literal. Proven byte-identical to
  `rg (?-u)`: the oracle battery adds `[0-9]{4}`, `\w{3,8}`, `x{2,4}`,
  `0x[0-9a-fA-F]{2,}`, `interface\{\}` + a `{0}\w{2,4}` template (0 FN / 0 FP).
- **DFA start-state acceleration** (`src/regex/dfa.zig`,
  `src/regex/powerset.zig`).
  The byte-class DFA's unanchored start state self-loops on most bytes; only a
  few
  "relevant" bytes can begin a match (`trans_in` leaves start) or match at EOL
  (`trans_fin` is a match — the `$`-literal case like `;$`). `powerset`
  collects
  that set and, when ≤ 3 bytes, attaches a SIMD `Prefilter`; the scanner then
  `memchr`/range-skips the dead run to the next relevant byte instead of a
  table
  lookup per byte (the rust-`regex`/RE2 `accel.rs` trick). For unanchored
  patterns
  where `\n` is irrelevant and no empty line matches, the skip **crosses
  newlines** — collapsing `;$` to a single-byte `memchr ;` (rg's exact
  strategy)
  and the prefilter from a two-range scan to one. Sound because a skipped byte
  both
  keeps start in itself *and* can't match under `$`; the byte-at-a-time inner
  loop
  still stops at `\n`, so `$`/line-end resolution is unchanged. **Verified by
  the
  existing doc-level differential fuzz vs the Pike VM** (12k patterns ×
  multi-line
  buffers, *anchors + `$`-literals included*) — **0 divergences**.
  Kernel-level:
  the no-prefilter end-to-end is read-floor-bound (the scan is ~1 % of wall, <
  30 ms
  User vs ~300 ms System), so this makes the automaton optimal without moving
  the
  IO-bound macro number — the lever for that stays the read floor above.
- **DFA transition-table premultiplication** (`src/regex/powerset.zig`,
  `src/regex/dfa.zig`). The dense no-prefilter scan's hot loop is one load-use
  recurrence per byte: `next = trans[state * ncls + class[byte]]`. The `state *
  ncls`
  multiply sat *on* the loop-carried dependency chain — every step had to
  compute
  the row offset before it could issue the load that produces the next state.
  `powerset` now stores every transition target, `start`, and `dead`
  **pre-scaled
  by `ncls`** (a row *offset*, not a state id) and lays `is_match` out
  offset-indexed,
  so the recurrence collapses to a bare `next = trans[state + class[byte]]` —
  the
  `madd` leaves the critical path entirely (the rust-`regex`/RE2
  premultiplied-DFA
  representation). **Correctness:** structural invariants + exhaustive language
  equivalence (`powerset_test.zig`, updated for the offset representation) and
  the
  doc-level DFA↔Pike differential fuzz (12k patterns × multi-line buffers) —
  **0
  divergences** — plus `scan_regress.sh` end-to-end (5 no-prefilter patterns,
  **0
  FN / 0 FP** vs `rg` over the identical 17.5k-file tree). **Measured** (Apple
  Silicon, kperf FIXED_CYCLES/INSTRUCTIONS, min-of-N, real 137 MB corpus,
  `[0-9a-f]{8}-[0-9a-f]{4}`): **6.62 → 3.98 cyc/byte (−40 %, 1.66×)**, ins/byte
  16.89 → 14.99 (−1.9), IPC 2.55 → 3.76. The signature is unambiguously
  latency-bound — instructions fell ~11 % but cycles fell 40 % *and* IPC rose,
  because shortening the recurrence (madd→load ⇒ load) exposed the ILP the
  dependency chain had been hiding. The dense DFA now sits at the scalar-DFA
  hard
  floor (~one L1 load-use per byte), at/ahead of rg's premultiplied lazy DFA.
- **Expanded scenario slates**: the warm/oracle slate (`bench.zig`) grows to 20
  literals (added cross-language keywords `goroutine`/`panic(`/`Result<`/`def`/
  `.unwrap()`) + 30 regexes (added `if\s+err\s*!=\s*nil`, `const\s+\w+\s*=`,
  `\w+\.\w+\(`, `[a-z]+_[a-z]+_[a-z]+`, `[a-z]+[A-Z]\w+`, `[0-9a-f]{8}-…`); the
  cold literal slate adds a guaranteed miss +
  `goroutine`/`SELECT`/`func(`/`})`;
  the cold regex slate grows to 22 tiers (decl, err-idiom, uuid/snake/camel,
  dotted-call). Re-proven sound: **50 literals + 68 regexes, 0 FN / 0 FP** vs
  rg.
- **Latent Pike `.skip` soundness fix** (`src/regex.zig` `eol_empty`). The DFA
  doc-fuzz surfaced it: a nullable prefix flowing into `$` (`\d*$`, `a*`,
  `x|$`)
  matches the zero-width end of **every** line, but skip mode only seeds
  first-byte positions and never evaluated the end-of-line empty match — a real
  false-negative the DFA exposed. `compile` now precomputes whether the start
  epsilon-reaches `match` at `(at_start=false, at_end=true)` and short-circuits
  to
  true (also a fast path for the DFA: no full-line scan for a match-everything
  pattern). `^`-anchored programs correctly stay false.
  - **Verification — two oracles, both fail-closed.** The rg `(?-u)` equality
    battery (135 literals + 64 regexes over 17.1k files / 126 MiB → **0 FN / 0
    FP**) *and* two **differential fuzzes vs the proven Pike VM**, hermetic (no
  rg
    needed): a line-level fuzz (6,000 random patterns — *anchors included* — ×
  10
    inputs) and a **doc-level fuzz** (6,000 patterns × 8 multi-line buffers
  with
    empty lines + trailing newlines) proving the single-pass scan
  byte-identical
    to the per-line path. **Zero divergences** in `zig build test`. The fuzzes
    earned their keep — they caught the Pike `.skip` bug above and a last-byte
    `trans_fin` edge in the single-pass scanner during development.
  - **Measured** (`bench/regex_headtohead.sh` + direct warm-cache query timing,
    17.1k files / 126 MiB, min-of-runs to filter shared-box load): the
    no-prefilter scan tail dropped **7–21%** of query time and now sits **at
  rg's
    own scan floor** (~248–264 ms vs rg ~250–280 ms) — the residual gap is
  purely
    gist's ~27 ms cold-load that rg never pays. The former clear losers flipped
  to
    ties: `[a-z]+_[a-z]+_[a-z]+` 326→258 ms query (355→285 ms total vs rg 278),
    `panic|0x` 313→248 ms. Prefilterable tiers still win outright
  (`pgxpool\.\w+`
    ~3×, `^func\s` ~2.5×, alternations 1.4–1.65×) because the trigram prefilter
    reads a fraction of the corpus while rg re-walks all of it.
  (see also: gist)
- **Line anchors `^` / `$`** (`src/regex_syntax.zig`, `src/regex.zig`):
  zero-width
  assertions resolved during the Pike epsilon-closure from per-position
  (start, end)-of-line flags — `^`/`$` add no NFA bytes, so an anchored
  pattern's
  required literal is unchanged (`^func` ⇒ prefilter "func"). `\^`/`\$` stay
  literal. Fixed `docMatch` to grep's line model (a trailing `\n` *terminates*
  the last line rather than seeding a phantom empty one — otherwise `^$`/`$`
  over-match every newline-terminated file vs rg). Proven byte-identical to
  `rg (?-u)`: the oracle's 52-regex battery now includes 8 anchored shapes +
  `^{0}`/`{0}$`/`^\s*{0}` templates (0 FN / 0 FP), and the cold CLI path
  matches
  rg on `^$` (15,572 files with a real blank line), `^func\s`, `\)$`, `;$`,
  `^}$`.
- **Measured competitive standing (17,112 files · 126.5 MiB, shared dev box,
  hyperfine geomeans):** WARM resident gist beats every scanner
  **1,028×–5,992×**
  (15/15; up to 270,000× on a miss) — uncontested, the indexed rivals have no
  resident CLI. COLD one-shot gist beats every *unindexed* tool **1.9×–9.2×**
  (10–11/11). COLD regex gist lands **≈ csearch (0.9×, 14/22 wins) and faster
  than
  zoekt (1.4×, 13/22)**, **≥ rg (1.3×)** — the old dense floor `\w{3,8}` now
  beats
  both indexed rivals. The **one honest loss**: COLD *literal* one-shot vs the
  indexed rivals (csearch 0.3×, zoekt 0.5× geomean), because gist deserializes
  a
  177 MiB index (30 ms) where csearch mmaps 28 MiB, and runs a corpus-wide T3
  freshness stat-walk they skip — both causes recorded as the next rung, not
  hidden. gist still beats csearch on the dense / 2-byte needles (`})` 1.5×).
- **Multi-literal alternation prefilter** (`src/regex_syntax.zig`
  `requiredAny`,
  `src/trigram.zig` `Index.queryAny`): an alternation has no single mandatory
  literal, so it used to full-scan. Now a cover set is extracted — a set of ≥3
  B
  literals such that *every* match contains one (`foo|bar|baz` ⇒ {foo, bar,
  baz})
  — and the candidate set is the UNION of each literal's trigram candidates.
  Sound
  by construction: the union is a superset of every match, so no true match is
  dropped; the existing verify pass still gates false positives. It's admitted
  only when **every** branch yields a ≥3 B literal (a `<3` or unfilterable
  branch
  ⇒ no cover ⇒ full scan, e.g. `panic|0x`), a single mandatory literal still
  wins
  over a union, and the set is capped at 32 branches. Wired through the cold
  CLI
  (`fresh.candidates` now takes a filter *set*) and the oracle. Proven
  byte-identical to `rg (?-u)`: the battery adds `return|continue|break`,
  `func|struct|enum`, `TODO|FIXME|XXX`, `import\s+\(|^package`,
  `context|errors`,
  `panic|0x` + the `({0}|{1})` template (0 FN / 0 FP over 17,028 files); the
  cold
  CLI on `panic|throttle|leaky` reads only 1,071/17,029 files (union prefilter,
  not a scan) and returns rg's exact 694-file set.
- **No-prefilter regex → direct live-tree scan** (`bench/scan.zig`, dispatched
  from `bench/cli.zig` `runRegex`). A regex with no usable trigram prefilter —
  no
  ≥3 B required literal and no all-≥3 alternation cover (`[0-9]{4}`,
  `panic|0x`,
  `[a-f0-9]{2,}`, `\w{3,8}`, `[a-z]+_[a-z]+_[a-z]+`) — makes the index filter
  *nothing*: every doc is a candidate. The cold index path then paid **two**
  full
  tree traversals — a corpus-wide T3 freshness `statFile` walk **and** a
  candidate
  read of all ~17 k files — where rg pays one (walk + read). The tier is
  IO-bound
  (profiled: System time dwarfs the automaton's User time — the scan engine was
  never the bottleneck, the redundant traversal was), and the freshness
  stat-walk
  is the dominant tax: measured **255 ms → 187 ms** (~67 ms) by toggling the
  anchor on a `panic|0x` full scan. So for that case gist now **skips the index
  entirely** and walks the LIVE tree once, reading + DFA-scanning each file
  like
  rg. This is strictly **more** correct than the index+freshness path — it
  reads
  current bytes, sees files created since the build, honors deletions, with no
  staleness window — so no freshness walk is needed at all. Same skip-dirs /
  NUL-binary / 4 MiB cap as the indexed corpus.
  - **Fused work-stealing pipeline (a tie was never the floor).** The first cut
    was phased — a parallel walk to collect every path, *then* a sharded
  read+scan
    — and profiling (process-internal clock, build-wrapper-independent) caught
  it
    leaking two ways: a **~63 ms walk barrier** overlapping nothing, and **~169
  ms
    of straggler idle** (static file-count sharding stranded the big files on
  one
    core — fastest core done in 158 ms, slowest 327 ms). Rewritten so walkers
    stream discovered paths into a shared MPMC queue while a core-sized pool
  steals
    files in batches and reads+scans *as the walk still runs*: **worker-span
    Δ 169 ms → 2.5 ms** (near-perfect byte-balance) and the walk folded under
  the
    scan — **~1.7× internal speedup**. Oversubscription was *measured, not
    assumed*: warm-cache the tier is CPU/syscall-bound (~190 µs/file
    open+read+close, the DFA pass a rounding error), so ×1 worker/logical-core
  beat
    ×2/×3 on both wall-clock and balance.
  - **Correctness:** byte-identical to `rg (?-u) -l` over the same logical
  corpus
    (rg run with `--no-ignore --hidden` + gist's dir-excludes so both scan the
    same file set): **0 FN / 0 FP** across `[0-9]{4}`, `panic|0x`,
  `[a-f0-9]{2,}`,
    `[0-9a-f]{8}-…`, `[a-z]+_[a-z]+_[a-z]+`, `\w{3,8}`, `x{2,4}` — the only
    residual diffs being 3 multi-MB data blobs (`train_text.txt` 2.2 GB,
    `val_text.txt` 22 MB) whose first match sits past the **pre-existing 4 MiB
    `per_file_cap`** the indexed corpus caps identically.
  - **Measured** (ReleaseFast, release-vs-release vs `rg (?-u) -l` on its
  fastest
    gitignore-respecting path, min-of-N back-to-back, shared dev box; gist
  scans a
    gitignore-*superset*, so it wins while reading **more** bytes): `\w{3,8}`
    **1.3–3.0×** · `[a-f0-9]{2,}` **1.3–1.4×** · `[a-z]+_[a-z]+_[a-z]+`
  **1.2×** ·
    `[0-9]{4}` **1.1×** · `panic|0x` **win-or-tie (~1.0×)** — **0 FN / 0 FP**
  vs rg
    throughout (one `[0-9]{4}` `rg_only` file: a >4 MiB blob past the shared
    `per_file_cap`). gist wins or ties all five. (The earlier Debug-build
  numbers
    understated gist — release-vs-release is the honest race.)
  - **Permanent regression** (`bench/scan_regress.sh`): the scan path is a
    different code path than the index path `bench/equality.sh` proves, so it
  gets
    its own permanent oracle — asserts each pattern still **routes** to the
  scan
    path, diffs gist's scan set vs `rg (?-u)` over the identical corpus and
  **exits
    1 on any FN/FP** (cap-skips excepted by size), and prints the worker-span Δ
  as a
    **straggler canary** so a future regression of the work-stealing balance
  fails
    loudly. Keeps the win honest and the floor measured for the next
  exploration.
  - **Why the verdict is structural (off the data, not vibes):** gist's time is
    **pattern-independent** (~240 ms across all five — it sits at the per-file
    syscall floor, the DFA being a single early-exiting pass), whereas rg's
  swings
    **2–373 ms with match density** (floor + per-byte scan). gist therefore
  wins
    every scan-expensive pattern and ties only the cheapest sparse-literal
    (`panic|0x`), where rg's scan is near-free and both rest on the same read
  floor.
  - **Named next rung (recorded, not hidden):** beating rg on the
  sparse-literal
    tie means dropping *below* the read floor — batch the per-file
    `openat`+`read`+`close` (io_uring / `readv`), since at ~190 µs/file the
    syscalls, not the scanned bytes, are the wall. A prefilter can't help a
  tier
    already at its IO floor.
  (see also: gist)
- **Regex engine gains AST-level ASCII case-folding, so `-i` / `(?i)` matches
  caseless across every backend** (`src/regex/syntax.zig`). Case-insensitivity
  used
  to be handled ad-hoc at the grep layer; it now lives in the engine where the
  NFA, lazy DFA, and Pike capture VM all inherit it from one place.

  - **`ByteSet.foldCase`** admits the opposite-case twin of every letter
  present in
    a consuming class (`a`⇄`A`), and **`foldCaseAst`** walks the AST applying
  it to
    every class (zero-width assertions and structure untouched, `capture` nodes
    recursed transparently). It's idempotent, so re-visiting a shared `{n,m}`
  atom
    in the DAG is harmless.
  - **Trigram soundness preserved**: a folded literal byte becomes a 2-member
  set,
    which the `only`/`required` literal extraction reports as non-singleton —
  so a
    caseless pattern yields an empty required-literal and the query soundly
  falls
    back to a full scan (gist's trigram index is case-sensitive). No false
    negatives from a case-folded search.

  Proven against real ripgrep as the oracle: `-i` cases (ASCII caseless literal
  and
  class) diff to **0 bytes** vs `rg`, with the engine's existing differential
  and
  prefilter-soundness tests still green.
- **Regex parser expands the control + hex escape set (`\f \v \a \0 \xNN
  \x{H..H}`)** (`src/regex/syntax.zig`). ripgrep patterns reach for these
  byte escapes routinely; gist previously only decoded `\t \n \r`, so a legal
  pattern like `\x7F` or `\0` was mis-parsed as a literal `x`/`0`.

  - **Control escapes**: `\f`→`0x0C`, `\v`→`0x0B`, `\a`→`0x07`, `\0`→NUL (rg's
    `\0`), alongside the existing `\t \n \r`.
  - **Hex escapes**: `\xNN` (two hex digits) and the braced codepoint form
    `\x{H..H}` (`hexByte`/`hexVal`). gist is a byte engine, so a value `> 0xFF`
    is a hard `BadPattern` (rg's `(?-u)` byte-mode behavior) rather than a
  silent
    truncation — fail-loud beats a wrong match.

  Proven against real ripgrep as the oracle: the escape cases (`\x` byte,
  braced
  codepoint, `\0`/control) diff to **0 bytes** vs `rg`; over-`0xFF` `\x{…}`
  errors
  loud as designed. The regex engine's differential tests stay green.
- **Regex scan accelerators** (`src/regex.zig`, split into
  `src/regex_test.zig`):
  the verify-time Pike search that used to re-seed the start thread at *every*
  byte — wasted closure work — now compiles three position invariants and
  dispatches `lineMatch` to the cheapest sound strategy (semantics unchanged,
  proven by the rg oracle + an overlapping-start unit battery):
  - **Anchored fast path** — `startsAnchored` (every alternation branch begins
    with `^`) seeds only at line position 0 and bails the instant the thread
  list
    drains, so a non-matching line for `^}$` / `^$` is ~O(1) instead of O(len).
  - **First-byte skip** — `analyzeFirst` walks the NFA for the byte set that
  can
    *begin* a match mid-line (traversing `^`, blocking `$`; the
  over-approximation
    is sound — a mid-line seed of an `^`-only branch dies on the failed
  assertion).
    When the thread list empties the scanner jumps to the next viable start
    instead of stepping dead bytes: SIMD `indexOfScalar` for a singleton set
    (`;$`, `0x…`), a **SIMD range scan** (`lo ≤ b ≤ hi` per `@Vector` window,
  OR'd
    over ≤6 contiguous ranges) for `[0-9]{4}` / `[a-f0-9]{2,}` / `\w{3,8}`,
  else a
    scalar byteset probe. The earlier blocking-`^` version dropped 408
  `^package`
    matches in `import\s+\(|^package` — caught by the oracle, now a regression
  test.
  - **Plain path** — unchanged re-seed-every-byte loop for an empty first set
    (a bare `$`), which the skip can't drive.
  Measured cold head-to-head vs `rg (?-u) -l` at its fastest
  gitignore-respecting
  walk (`bench/regex_headtohead.sh`, hyperfine p-mean, warm cache, 17.1k
  files):
  gist wins **every prefilterable tier robustly** (stable run-to-run) —
  `pgxpool\.\w+` **≈3.0×**, `^func\s` **≈2.5×**, `func\s+\w+\(` **≈1.9×**,
  `func|struct|enum`/`error|panic|fatal` **≈1.5–1.65×**,
  `return|continue|break`
  **≈1.5×** — because the prefilter reads a fraction of the corpus while rg
  re-walks all of it. The **no-literal full-scan tail oscillates around
  parity**
  (≈0.8–1.1×, noise-dominated): with no prefilter for *either* tool both read
  the
  whole 126 MiB, so it's a straight scan race sensitive to the shared dev box's
  load. The skip turned the old clear losses (`^}$` 0.54×, `;$` 0.77×) into
  ties.   The hard floor is `\w{3,8}` — dense matching where `\w` covers most
  bytes
  so the skip never engages and it's Pike-VM-per-byte vs rg's O(1)/byte lazy
  DFA;
  closing it is the identified next rung (a lazy DFA / bit-parallel NFA step).
  (see also: gist)
- **Sub-trigram literals → the same live-tree scan** (`bench/scan.zig`
  generalized to verify a literal via `simd.contains` as well as a regex via
  `docMatch`; `bench/cli.zig` `runQuery` routes `needle.len < 3` there). A `<3
  B`
  literal (`})`, `=>`) has no trigram filter, so the index path seeded every
  doc
  **and** ran the corpus-wide freshness `statFile` walk on top of the read —
  the
  same two-traversals-vs-rg's-one tax the no-prefilter *regex* path already
  escaped. Short literals now skip the index and walk the live tree once
  through
  the proven work-stealing pipeline. **Correctness:** the literal scan is
  byte-identical to the trusted DFA scan over the identical tree (`} )` literal
  vs
  `/\}\)/` regex → same 5,610-file set, 0 diff), and `scan_regress.sh` stays
  green
  (0 FN / 0 FP). The ≥ 3 B indexed path is untouched (`pgxpool` still reads
  409/17,513 files, ~1.7 ms cold-load).
- **T0 trigram candidate index** (`src/trigram.zig`): allocation-light,
  container-API-free positional-trigram inverted index over a fixed document
  set. `Index.build` + `Index.queryLiteral` (sound superset of literal matches
  via posting-list AND), queried by hand-rolled binary search. Filter semantics
  (false positives expected, zero false negatives for literals ≥ 3 bytes) and
  the `NeedleTooShort` fallback contract are covered by unit tests.
- **T1 persistence** (`src/trigram.zig`): `serializedSize` / `writeInto` /
  `fromBytes` — IO-free native-endian local-cache serialization (the harness
  does the file IO; the kernel stays filesystem-agnostic). A session builds the
  index once (~6.4s) and warm-starts from disk in ~28ms (227× faster).
  Round-trip +
  malformed-blob-rejection tests added.
- **T1 rarest-first query** (`src/trigram.zig`): `queryLiteral` now resolves
  every trigram's posting range up front, seeds the candidate set from the
  *rarest* trigram, and intersects outward (AND is commutative, so results are
  identical — the work is just bounded by the rarest gram instead of the
  lexicographically-first one). Collapsed the `context.Context` tail from
  ~530µs
  to ~9µs at libs scale.
- **T2 regex tier** (`src/regex.zig`): a linear-time **Thompson NFA** over
  bytes
  (RE2/ripgrep philosophy — no backtracking, no catastrophic blowup) with a
  recursive-descent parser for literals, `.`, `[...]`/`[^...]` ranges, `* + ?`,
  `|`, `()`, and `\d \w \s \D \W \S \t \n \r` + metachar escapes. Includes
  sound
  required-literal extraction (a conservative slice of Cox's regexp→trigram
  analysis) so a regex reuses the T0 prefilter, falling back to a full scan
  only
  when no literal is mandatory. Unit-tested incl. the `(a+)+` pathological
  case.
- **`-g`/`--glob` supports `{a,b,c}` brace alternation** (`bench/rgargs.zig`).
  ripgrep's glob dialect expands `{…}` groups; gist treated the braces
  literally, so
  `--glob '*.{js,py,go}'` matched nothing.

  - **`braceExpand`** lowers a glob into the cartesian product of every brace
  group
    (nesting-aware, unbalanced `{` left literal) at registration time, so
    `*.{js,py}` becomes the include set `*.js`, `*.py` and
    `!{.git,node_modules}/**` becomes the excludes `!.git/**`,
  `!node_modules/**`.
    `addGlob` expands, then routes each variant through `addGlobOne` (the prior
    include/exclude/iglob logic) — one glob dialect across `-g`, `--iglob`, and
    `--type-add`.

  Proven against real ripgrep as the oracle: `r391` (a real editor's
  `!{.git,node_modules,plugged}/**` + `*.{js,json,…,py,…}` glob combo) now
  diffs to
  **0 bytes** vs `rg`.
- **`grep` accepts the reflexive ripgrep surface an agent's muscle memory
  types**
  (`bench/grepargs.zig`, extracted from `bench/lines.zig`;
  `bench/pathfilter.zig`).
  Found by dogfooding gist _as the agent_ against `rg` on real repo questions:
  the
  goal is to _never reach for ripgrep_, but three reflexive invocations still
  broke
  — one of them silently, the worst failure mode. All three are closed,
  byte-exact
  vs `rg` (9/9 head-to-head, `.local/gist-dogfood/prove.sh`):

  - **Positional PATH args now scope the search** — `grep WalletService
  <subtree>/`
    used to search the _whole repo_ while the agent believed it scoped (a
    wrong-but-confident result). Every non-flag token after the pattern is now
  a
    path root AND-ed into the `PathFilter` and **pruned before any read** —
  gist's
    structural edge, not just parity: the same search scoped to one service
    subtree
    reads **28 candidates** (vs 86 unscoped, vs rg's whole-subtree walk) and
  runs
    **1.14× faster than rg at ~⅕ the syscall time** (112 ms vs 590 ms system,
    hyperfine 15-run), output byte-identical.
  - **Bundled short flags** — `-ln`, `-in`, `-nw`, `-nC3` used to fail loud as
    "unknown flag". A `-xyz` cluster is now decomposed left-to-right; the first
    _value_ flag consumes the cluster remainder (`-nC3` ⇒ `-n -C 3`, `-tgo` ⇒
    `-t go`) or the next token.
  - **Harmless rg flags** — `-n` (line numbers, always on), `-H`, `-r`/`-R`,
    `--no-heading`, `--color[=X]`, `--with-filename` are accepted as **no-ops**
    under gist's fixed `path:line:text` model (they used to fail loud); `-N` /
    `--no-line-number` drops the line column for real, and `-S` /
  `--smart-case`
    folds iff the pattern carries no uppercase (rg's rule). Every existing flag
    also gained its rg **long spelling** (`--ignore-case`, `--context=N`,
    `--type=<lang>`, `--glob=<glob>`, `--max-count=N`, …).

  Fail-loud is preserved for genuinely unknown flags (a silent empty result is
  the
  worst agent failure) — the diagnostic now prints the full supported surface.
  The
  parser moved to its own module so `lines.zig` (line emit/verify) drops from
  479 →
  344 lines and the larger compatibility table lives on its own (both under the
  500-line shape cap). New adversarial tests (`bench/grepargs_test.zig`, 12
  cases)
  pin bundling, no-ops, long-flag `=`/next-token values, smart-case, `-e`/`--`
  leading-dash safety, and the fail-loud contract; `bench/pathfilter_test.zig`
  gains positional-root coverage (dir-prefix `/`-boundary, exact file, `.`
  whole-corpus, `normalizeRoot`). The `gist ≡ rg` set oracle is unchanged.
- **`grep` closes three reflexive-invocation gaps found by dogfooding gist _as
  the
  agent_ against `rg`** (`bench/grepargs.zig`, `bench/lines.zig`,
  `bench/pathfilter.zig`). Racing the two tools on real repo questions surfaced
  one
  silent-wrong landmine, one fail-loud on a legal pattern, and a robustness win
  rg
  lacks — each of which broke a call an agent's muscle memory actually types:

  - **`-r` / `--replace` was a silent-wrong landmine — now a real value flag.**
  rg's
    `-r` _consumes_ the replacement, but gist had it mis-listed among the
  boolean
    no-ops, so `grep -r X pat` parsed `X` as the pattern and `pat` as a path
  root — a
    wrong-but-confident empty result (the worst agent failure). It now stores
    `opts.replace` and rewrites each match before emit: `$0`/`${0}`/`$&` expand
  to
    the whole match, `$$` is a literal `$`. A capture-group ref (`$1`, `${2}`)
  is
    rejected **at parse time** — gist's span engine tracks the whole-match
  extent,
    not per-group captures, so failing loud beats a silently-dropped
  substitution.
    Proven byte-identical to `rg -o -r`/`rg -r` over the shared `-t go` corpus.
  - **Leading inline flag groups `(?i)` / `(?-u)` / `(?m)` are now honored.**
  An agent
    pastes rg patterns carrying a global flag group reflexively; gist used to
  reject
    the whole (legal-to-rg) pattern. Now `i`→ASCII caseless
  (`(?i)sessionstore` is
    byte-identical to `-i`), `m`/`u`/`U`/any `-…` form → no-op (gist is
  per-line,
    byte-oriented — exactly rg `(?-u)`), while `s` (dotall across newlines) and
  `x`
    (extended) still fail **loud** rather than silently mismatch. `-F` keeps
  `(?i)`
    a literal; a non-capturing `(?:…)`/lookahead `(?=…)` is left for the
  compiler.
  - **`-t tsx/jsx/vue/svelte/rego/mdc/cedar` resolve.** Convenience rows for
  types an
    agent types that even `rg` lacks (`tsx`/`jsx`) or that are repo-native
  (`rego`,
    Cursor `.mdc`, Cedar policy), so a reflexive `-t tsx useState` scopes
  instead of
    erroring.

  Also documented but _not_ a gist change — the decisive reason to prefer gist
  in an
  agent loop: in a harness where stdin is a non-tty pipe (how Cursor/Claude
  Code/
  Codex spawn shells), a bare `rg PATTERN` with no path arg **blocks forever
  reading
  stdin**; gist always searches its indexed roots and never has this failure
  mode
  (`rg PATTERN </dev/null` returns instantly with the same result).

  Correctness unchanged: the `gist ≡ rg` set oracle still proves 0 FN / 0 FP
  (80
  literals + 94 regexes), the parser carries 4 new adversarial tests (value
  consumption, inline-flag map, `-F` literal, group-ref reject), and all five
  new
  behaviors diff to **0 lines** vs `rg` on the shared scope.
- **`grep` gains `--files` (file discovery) and `-o`/`--only-matching` (span
  extraction)** — the two reflexive ripgrep invocations dogfooding surfaced as
  the
  next holes in the "never reach for `rg`" goal. Both fail-loud gaps before
  this
  (`unknown flag`), so an agent's `rg --files -g …` / `rg -o …` muscle memory
  hit a
  wall mid-loop.

  - **`--files [PATH…]`** lists every corpus file the `-t`/`-g`/PATH filter
  admits
    — and does it with **zero file reads and zero tree walk**. gist already
  holds
    the whole path list in the mmap'd index, so discovery is a pure in-memory
    filter + sort where `rg --files` must walk the entire tree. On this repo
  that's
    the difference between an instant answer and a walk that, from the
  _uncurated_
    root, stalls on the 106 GB of build/vendor mass gist's corpus policy
  already
    excludes (measured: `rg` content-search from repo root **hangs >20 s**, `rg
  --files` 93 ms; gist projects the index in a few ms). Read-your-own-writes is
    preserved — the freshness overlay folds in files created since the build (a
    stat-only walk, no reads) so a coworker's just-written file still appears;
  a
    file _deleted_ since the last `index` may still list (no read to verify it
  away)
    and self-heals on rebuild, the same tolerated false-positive the trigram
  filter
    carries. The projection is intentionally the curated code set: no build
  caches
    (`.zig-cache/`, `dist-types/`, `.local/`), no binaries, no >4 MiB blobs —
  arguably
    a _better_ discovery list for an agent than rg's raw walk.

  - **`-o`/`--only-matching`** emits each non-overlapping match's TEXT alone
  (not
    the whole line), one `path:line:text` row per match — extraction of idents,
    symbols, URLs, hex, etc. The DFA is match/no-match only, so spans run the
  Pike
    VM with a per-state start-offset side-channel added to the ε-closure
  (`starts`
    in `Closure`, null on the hot boolean path — no cost to
  `lineMatch`/`docMatch`).
    Semantics are rg's `(?-u)` exactly: **leftmost start, then the
  highest-priority
    thread wins the end** — earlier alternation branches and greedy quantifiers
    extend maximally (empirically fixed against `rg -o`: `a|ab`→`a`,
  `a+`→greedy,
    `[0-9]{2,}`→longest run). After a match at `[s,e)` the next search resumes
  at
    `e` (non-overlapping); a zero-width match steps one byte so a nullable
  pattern
    can't loop.

  **Proof (byte-exact vs `rg -o` on the shared corpus):** an 11-pattern
  differential battery (`func \w+`, `[A-Z]\w+Error`, `return|continue|break`,
  `\bfunc\b`, `[a-z]+[A-Z]\w+`, `a|ab`, `[0-9]{2,}`, …) over
  a single Go service tree
  diffs to **0 lines** against `rg -o -n --no-heading --no-ignore --hidden
  --no-unicode` (`.local/gist-dogfood/o_battery.sh`); every residual divergence
  across the wider tree is a `.gitignore`/hidden/`isSkipDir` file — gist's
  documented corpus policy, not a match bug. Permanent regression coverage:
  `matchSpan` leftmost-first/greedy/anchor/boundary cases in `core_test.zig`,
  and
  `-o`/`--files` argv parsing (bundling, pattern-optional, roots) in
  `grepargs_test.zig`.
- **`grep` gains the agent's full ripgrep flag surface** (`bench/lines.zig`,
  `bench/pathfilter.zig`). Found by dogfooding gist _as the agent_, racing
  every
  query against `rg`: the three flags an agent reaches for after `-n` were
  missing,
  and an unknown flag was silently swallowed as the pattern — the worst failure
  mode (a wrong-but-confident empty result). Now:

  - **`-A/-B/-C N` context lines** — read the code _around_ a hit without a
  second
    file round-trip (the #1 affordance after `-n`). Byte-exact `:`/`-`/`--`
  framing:
    a 17-line `-C2` block and an asymmetric `-A1 -B1` block both diff to **0
  lines**
    against `rg -n --no-heading -C`, group separators and all.
  - **`-t <lang>` / `-g <glob>` path scoping** (`pathfilter.zig`) — confine to
  one
    language or subtree. The type table is **codebase-agnostic** (~75 languages
  with
    rg-compatible names — `java kotlin ruby php c cpp cs haskell elixir
  terraform
  dockerfile …`, not just the monorepo's seven), so `-t <name>` accepts the
  same
    name an agent already types at rg, and a row may carry a bare filename
    (`Makefile`, `Dockerfile`, `go.mod`) as well as an extension. This is also
  the
    one place gist _beats_ rg structurally instead of merely matching it: rg
  applies
    the filter while walking the whole tree, but gist already holds the path
  list,
    so it **prunes candidate ids before touching disk**. `-t go pgxpool.Pool`
  reads 234 of 18 608 files and runs **1.44× faster
    than `rg -t go`** (55 ms vs 79 ms, hyperfine 20-run, byte-identical
  output); the
    pre-fix `-t go` swallowed the flag and degenerated to reading all 18 608
  (459 ms).
    Globs are gitignore/rg-shaped (`*` per-segment, `**` across `/`, `?`,
  `[a-z]`
    classes, `!`-exclude), basename-matched when slash-free.
  - **`-w` word-boundary** (wraps `\b(…)\b`), **`-F` fixed-string** (escapes
  regex
    metachars), **`-l` files-with-matches**, **`-c` per-file count**, **`-v`
  invert**
    (seeds all docs — an inverted match can occur in a file lacking the
  literal).
  - **Fail-loud parsing** — an unrecognized `-x` now errors with the
  supported-flag
    list (use `-e <pat>` or `-- <pat>` for a leading-dash literal) instead of
    searching for it.

  Correctness is unchanged and re-proven: the new `pathfilter` glob matcher
  carries
  its own adversarial tests (segment vs `/` boundaries, `**` zero-dir, class
  negation, pathological star backtracking, exclude veto); a 7-feature
  line-output
  battery (`-w`, `-F`, `^`-anchor, `$`-eol, alternation, class, counted) diffs
  to
  **0 lines** vs `rg` on the shared scope; and the `gist ≡ rg` set oracle still
  proves 0 false negatives / 0 false positives. The grep line loop also adopts
  rg's
  `\n`-terminates semantics (a trailing newline yields no phantom empty final
  line),
  so `$`/`^$` match exactly as rg does. Path scoping respects the same
  documented
  corpus policy as the rest of gist (skips `vendor`/`dist-types`/build output)
  — the
  only residual deltas vs a raw `rg` path-arg run, all in skipped subtrees.
- **`rg --json` emits ripgrep's JSON Lines record stream — was a fail-loud
  gap**
  (`bench/rgjson.zig` (new), `bench/rgcompat.zig`, `bench/rgemit.zig`,
  `bench/rgsuite/run.py`). `--json` is how tools consume ripgrep structurally,
  so
  the drop-in has to speak it, not decline it.

  - **Exact message sequence** (`rgjson.zig`): one JSON object per line — a
  `begin`
    per matched file, a `match`/`context` per emitted line with byte-accurate
    `submatches` (and, under `-r`, per-match `replacement`), an `end` carrying
  that
    file's stats, then a trailing `summary`. It rides the _one_ regex engine
    (`matchSpan` for spans, the capture VM for `-r`) and reuses
  `rgemit.expandInto`
    for template expansion, so there's no second matcher or replacer to drift.
  - **`-A/-B/-C` context, `-v` invert, `-m` cap, `--crlf`** are all reflected
  in the
    record stream and the aggregated `stats` (`matches`, `matched_lines`,
    `searches`, `bytes_searched`); `--quiet` still tallies stats while
  suppressing
    the record body.
  - **Deterministic-only fields are real; wall-clock/printer-internal ones are
    normalized.** `elapsed`/`elapsed_total`/`bytes_printed` are inherently
    non-reproducible, so both sides emit placeholders that `rgsuite/run.py`
    normalizes (mirroring what it already does for `--stats` seconds); every
    correctness field is emitted for real.
  - **Strings use rg's escaping** — `\"` `\\`, `\n`/`\r`/`\t` short forms,
  other C0
    as `\u00XX` (all harness fixtures are UTF-8).

  Proven against real ripgrep as the oracle: the `--json` cases diff to **0
  bytes**
  after the shared timing/`bytes_printed` normalization, and `--json` is
  removed
  from the fail-loud deferral list.
  (see also: gist)
- **`rg --type-add` defines and composes custom file types**
  (`bench/rgargs.zig`).
  The type surface already resolved built-in names (`-t go`); ripgrep also lets
  a
  caller _mint_ a type on the command line, and its tests exercise both forms —
  so
  the parser now accepts them instead of erroring on an unknown type.

  - **`--type-add 'name:glob'`** registers a user type from one or more globs
    (`--type-add web:*.html --type-add web:*.css`, accumulated in order),
  usable
    immediately via `-t name`/`-T name`. Bare extensions are lifted to `*.ext`.
  - **`--type-add 'name:include:t1,t2'`** composes an existing set of types
  into a
    new alias, resolving each member (custom-first, then the built-in table)
    recursively.
  - **Resolution order fixed**: `-t <name>` checks `--type-add` definitions
  before
    the built-in `pathfilter` table, so a redefinition wins. (Along the way
  this
    fixed a Zig control-flow bug where an `else die` bound to a `for`'s `else`
    clause mis-reported valid built-in types like `py` as "unrecognized".)

  Proven against real ripgrep as the oracle: the `--type-add` single-glob and
  `:include:` composition cases (`file_type_add`, `file_type_add_compose`) diff
  to
  **0 bytes** vs `rg`. `--type-list` itself stays a documented NA (gist's type
  table
  is a distinct catalogue, not rg's exact list).
- **`rg` auto-detects a UTF-16 BOM and transcodes to UTF-8**
  (`bench/rgcompat.zig`).
  ripgrep's default (`--encoding auto`) sniffs a byte-order mark and decodes;
  gist
  read raw bytes, so a UTF-16 file's (UTF-8) pattern never matched and its NUL
  bytes tripped binary detection into skipping the file entirely.

  - **`decodeBom`** runs once per file at ingest: a UTF-8 BOM is stripped, a
    UTF-16 LE (`FF FE`) / BE (`FE FF`) BOM transcodes the whole file to UTF-8
  via
    **`utf16ToUtf8`** (surrogate pairs resolved; a lone/invalid surrogate or a
    trailing odd byte becomes U+FFFD, matching rust-encoding's lossy decode).
  It's
    applied at every read site (walk, symlink target, explicit path arg), so
  the
    transcoded UTF-8 flows through matching _and_ binary detection uniformly.
  - **Scope stays honest**: only _BOM-marked_ UTF-16 is auto-detected. BOM-less
    UTF-16 and other charsets still require explicit `-E`/`--encoding`, which
    remains a fail-loud NA (gist is a UTF-8/byte engine).

  Proven against real ripgrep as the oracle: `f1_utf16_auto` (a BOM'd UTF-16
  file
  searched for a Cyrillic literal) now diffs to **0 bytes** vs `rg`.
- **`rg` gains `--color` support and match highlighting — the one CLI feature
  demo'd against real ripgrep that gist visibly lacked** (`color.zig` (new),
  `output.zig`, `run.zig`, `args.zig`, `cli/main.zig`). `--color=always`/`ansi`
  previously failed loud (`unsupported by design — gist emits no ANSI`); the
  default `auto` mode silently emitted nothing. Both are now real, resolved
  once
  per run in the new `color.zig`.

  - **`--color auto|always|never|ansi`**, matching ripgrep's own resolution
    rules: `auto` (the default) colorizes iff stdout is a real terminal *and*
    the environment doesn't opt out (`NO_COLOR` — any value,
  <https://no-color.org>
    — or an absent/`dumb` `TERM`) *and* no flag that implies plain text
    (`--json`, `--vimgrep`) is active; `always`/`ansi` force it on regardless
  of
    destination or environment (rg's own override rule — an explicit request
    beats `NO_COLOR`); `never` forces it off.
  - **Match highlighting tuned to beat ripgrep's own default on legibility, not
    just parity**: rg's `fg:red,style:bold` is the "normal" red (SGR `31`),
    which reads muddy against a lot of terminal palettes. gist paints a match
    bold + underlined *bright* red (`1;4;91`) — still coloring the letters, no
    filled background block — so it reads at a glance without inventing a new
    visual language. Path (bold magenta) and line-number (green) keep rg's own
    hues; separators are dimmed one notch so the match is the only thing
    competing for the eye. Wired through every text-emitting path: the default
    `path:line:text` frame, `-o`/`--only-matching`, `--vimgrep`, `--passthru`,
    and `-w` word-bounded spans (an `-r`/`--replace` line is left unpainted —
    the substituted text isn't "the match" any more).

  **Proof:** piped/non-tty output — the common agent-loop case, and the whole
  point of the earlier stdin-parity work — is untouched: `color.enabled`
  resolves to `false` whenever stdout isn't a real terminal, so `make | gist
  "pat"` stays byte-identical to `make | rg "pat"`. `--color=always` verified
  against real `rg --color=always` on the same fixture (`-n`, `-o`, `-w`): the
  path/line-number/match ANSI runs decode correctly and non-tty parity holds
  with color forced off.
- **`rg` gains a capture-group engine — `-r $1`/named-group replacement and
  JSON
  submatches, no longer a fail-loud gap** (`src/regex/captures.zig` (new),
  `src/regex/syntax.zig`, `src/regex/analysis.zig`, `src/regex/compile.zig`,
  `src/root.zig`, `bench/rgemit.zig`). The prior `-r` handled only whole-match
  `$0`/`$$` and _rejected_ a group ref at parse time; ripgrep's own test suite
  leans on `$1`/`${name}` substitution, so the drop-in couldn't reach those
  cases.

  - **Group parsing** (`syntax.zig`): `(…)` and named `(?P<n>…)`/`(?<n>…)` now
    capture (1-based index in opening-paren order, names recorded only when a
  sink
    is given so the hot main-engine parse allocates nothing); `(?:…)` is
    non-capturing; lookaround (`(?=`,`(?!`,`(?<=`,`(?<!`) fails loud as
    `BadPattern` (gist's linear engine can't backtrack).
  - **A dedicated capture VM** (`captures.zig`) compiles the same `syntax.zig`
  AST
    into a Pike VM that threads per-group slot vectors, so a leftmost-first
  match
    now yields each group's `[start,end)` — without touching the hot
  boolean/span
    matcher (the new `.capture` AST node the analysis/compile/prefilter passes
    recurse through transparently, so trigram prefilters and anchoring are
    unchanged). Slot count is capped to keep the closure stack bounded.
  - **`-r` expands real templates** — `$1`, `${2}`, `$name`, `${name}`, `$0`,
    `$$` — with rust-regex `Replacer` semantics (unknown/out-of-range group →
    empty). The expander is a shared free function (`rgemit.expandInto`) so the
    text printer and the JSON stream replace identically.
  - **Two `-r` × `--max-columns` edge cases now match rg byte-for-byte.** A
    replaced over-long line reports match granularity
    (`[Omitted long line with N matches]`, and `--max-columns-preview`'s
    `[... N more matches]`) instead of the granular-less
    `[Omitted long matching line]`; and an empty match whose
    start coincides with the previous match's end is skipped (rust-regex
    `find_iter` progress rule), so `-r '${0}f'` over `.*` yields `af`, not
  `aff`.

  Proven against real ripgrep as the oracle: the `-r`/replacement and
  max-columns-granularity cases (`f129_replace`,
  `r1739_replacement_lineterm_match`,
  `f1078_max_columns_preview2`) all diff to **0 bytes** vs `rg`, and the regex
  engine's adversarial differential/prefilter tests still pass with the new
  node.
- **`rg` honors a linked git worktree's shared `info/exclude`**
  (`bench/rgignore.zig`,
  `bench/rgcompat.zig`). The ignore engine only read `.git/info/exclude` at CWD
  via
  a shallow `.git`-dir check, so searching a _worktree_ path (whose `.git` is a
  gitfile pointing elsewhere) missed the repo's excludes and surfaced ignored
  files.

  - **`Ignore.init` now takes the search's positional roots** and probes each
  for
    its own `.git`, so `rg <flags> some-repo` honors that repo's VCS ignores
  even
    when CWD isn't a repo (`anyRootRepo`).
  - **`resolveGitDir`** mirrors ripgrep's `resolve_git_commondir`: a `.git`
    directory is the git dir; a `.git` **file** is followed through `gitdir: …`
  →
    its `commondir` (relative commondir joined to the worktree git dir,
  absolute
    used as-is), and `<commondir>/info/exclude` is loaded anchored to the
  worktree
    root. `isGitRepo` was refactored onto the shared `hasDotGit` probe so a CWD
    worktree gitfile is now detected too.

  Proven against real ripgrep as the oracle:
  `r1446_respect_excludes_in_worktree`
  (a worktree whose commondir exclude ignores one file) now diffs to **0
  bytes**
  vs `rg`.
- **`rg` honors ancestor ignore files and finds the git repo by ascent**
  (`bench/rgignore.zig`). ripgrep reads `.gitignore`/`.ignore` from every
  directory
  _above_ the search root and discovers `.git` at any ancestor; gist only read
  CWD-and-below, so searching from a repo subdirectory ignored the wrong set.

  - **`gitRootDepth`** ascends from CWD looking for `.git` (dir or worktree
  file),
    replacing the CWD-only `isGitRepo` — so a search run inside `repo/sub/` now
    enables VCS ignores from `repo/`'s `.gitignore` (`no_parent_ignore_git`).
  - **`loadParents`** walks each ancestor shallow→deep (deeper wins), reading
  its
    `.gitignore` (bounded to the git root) and `.ignore`/`.rgignore` (to `/`),
    skipped under `--no-ignore-parent`. An **anchored ancestor rule is
  re-anchored**
    onto the search subtree: `readFile`/`addLine` take a `strip` prefix (CWD's
  path
    relative to that ancestor) — a rule like `/parent/*.txt` seen from
  `parent/`
    becomes `*.txt`, and a rule targeting a sibling of CWD is dropped.
  Slash-less
    ancestor rules match a basename at any depth unchanged.

  Proven against real ripgrep as the oracle: `no_parent_ignore_git`,
  `r829_2778`,
  `r3173_hidden_whitelist_only_dot`, and `f1757` (a `.ignore` above the search
  root
  excluding `target/`) now diff to **0 bytes** vs `rg`.
- **`rg` now honors the `.gitignore` boundary — the single biggest drop-in gap
  closed** (`bench/rgignore.zig` (new), `bench/rgargs.zig`,
  `bench/rgcompat.zig`).
  gist was deliberately ignore-agnostic, so any ripgrep scenario with a
  `.gitignore`/`.ignore` searched a superset and diverged. The walk now applies
  the
  same "what's tracked" filter rg does, as a proper per-directory rule model
  rather
  than a bolt-on path test.

  - **Full gitignore dialect** (`rgignore.zig`, reusing `pathfilter.globMatch`
  so
    there's one glob dialect): leading/embedded `/` anchors to the ignore
  file's
    dir, a slash-less pattern matches a basename at any depth, a trailing `/`
    restricts to directories, `!pat` re-includes, and **last matching rule
  wins**
    with deeper dirs + `.ignore`/`.rgignore`/`--ignore-file` outranking a
  shallower
    `.gitignore`. Rules accumulate as the walk descends (loaded once per dir),
  and
    an ignored directory is _pruned_ — so `/*` + `!/dir` re-includes `dir`
  while
    keeping its siblings excluded, exactly like git.
  - **Hidden-file interaction**: a `!`-whitelisted dotfile is un-hidden
  (overrides
    the default dotfile skip), and `.git` is never walked.
  - **The `--no-ignore*` / `-u` control surface is now real**, not a no-op:
    `--no-ignore`, `--no-ignore-vcs` (VCS sources only), `--no-ignore-dot`,
    `--no-ignore-exclude`, `--no-ignore-files`, `--no-require-git` (honor
    `.gitignore` outside a repo), `--ignore-file <path>` (ordered, later wins),
    `--ignore-file-case-insensitive`; `-u`→`--no-ignore`, `-uu`→`+--hidden`.
  VCS
    rules (`.gitignore`, `.git/info/exclude`) apply only inside a git repo
  unless
    `--no-require-git`.

  Proven against real ripgrep as the oracle: this converts **~30 previously
  divergent cases to byte-exact PASS** (anchoring, negation/whitelist,
  precedence,
  `--ignore-file`, `--no-ignore-vcs`, per-dir `.ignore`, hidden whitelist),
  lifting
  supported-surface parity to 98.9% with no regression elsewhere.
- Initial scaffold mirroring the conventions of its sibling C-ABI kernel: `build.zig`
  (static + dynamic libs, header install, `test` + `coverage` steps),
  `build.zig.zon`, flat C-ABI in `include/gist.h`, `src/root.zig`.
  (see also: gist)
- `gist_trigram_count` C export — the deterministic cross-language parity
  oracle.

### Changed

- **CLI collapses six competitor-shaped verbs into three real ones, on a native
  flag vocabulary with a separated legacy alias layer**
  (`src/commands/search/`,
  `src/commands/status/`, `src/commands/cli/{main,schema}.zig`). The old
  surface
  (`index` · `query` · `regex` · `rank` · `grep` · `rg`) named _which
  competitor's
  argv it aped_, not what gist does — and `query`/`regex`/`rank`/`grep` were
  four
  verbs answering one question (_what matches, and how do you want it shaped_)
  over
  one engine. The new surface says what gist actually does:

  - **`gist search <pattern> [PATH…]`** — the one search verb. Pattern is
    auto-detected literal-or-regex (a literal is its own required literal, so
  it
    rides the same trigram prefilter — no second code path). Output shape is a
    **flag, not a verb**: `--show lines` (default, the byte-exact `rg -n`
    drop-in) / `--show files` (was `query`/`regex`) / `--show count` /
    `--rank [=N]` (was `rank`, top-K default 20). The dispatcher
    (`search/run.zig`) still routes each request to its fastest backend — the
    `drivers` fast paths for `--show files`/`--rank`, the full line engine
    (`emit.zig`) for the feature flags.
  - **`gist status`** — new, read-only introspection: whether an index exists,
    file / distinct-trigram / posting counts, on-disk size, build age vs the
    freshness anchor, and corpus roots. Answers "am I ready to search fast"
    before an agent commits to a query, with zero search work.
  - **`gist index`** — unchanged, the mutating build/refresh lifecycle action.

  **Two flag sets, one behavior each.** Set B (native) is the primary,
  documented
  vocabulary — `--show`, `--rank`, `--lang`, `--glob`, `--word`, `--fixed`,
  `--ignore-case`, `--smart-case`, `--invert`, `--before/--after/--context`,
  `--limit`, `--spans`, `--replace`, `--only-matching`, `--pattern`, plus two
  genuinely new capabilities: **`--live`** (skip the index, scan the live tree
  —
  the capability `gist rg` carried, without keeping a competitor-shaped verb)
  and
  **`--json`** (structured records, the one thing rgsuite marked NA against
  `rg --json`). Set A (legacy) is every `rg`/`grep` spelling an agent's muscle
  memory types — `-A/-B/-C -i -w -F -l -c -v -o -n -N -S -m -e -t -g -r`, the
  long
  forms, short-flag bundling, the no-op set, the fail-loud set — each an
  **alias
  onto exactly one native option**, split into its own module
  (`search/compat.zig`) so the ergonomic surface reads clean.

  **Agent discovery.** `gist --schema` emits a JSON capability manifest (verbs
  →
  flags → `{native_name, type, default, legacy_aliases, description}` + exit
  codes)
  so the two-set model is machine-checkable, not just prose — the seed for
  wiring
  gist into an agent's tool catalog.

  Dead-code shake per the refactoring rule: `src/commands/grep/` and
  `src/commands/cli/drivers.zig` are **deleted**, not deprecated-and-kept;
  their
  logic lives in `search/`. The `ripgrep/` differential-parity engine stays
  wired
  but **undocumented** (dropped from `--help`/`--schema`) — it's the `rgsuite`
  441-test harness plumbing, not a public verb. Every bench script
  (`_compete.sh`, `streams.sh`, `scan_regress.sh`) and the README are rewritten
  around `search`; `bench/rgsuite/run.py` still targets the internal `rg` path,
  so
  the parity certificate is unaffected. Native + legacy parsing is guarded by
  the
  superset test suite `search/args_test.zig`.
  (see also: gist)
- **Cold / first-query win** (`bench/cli.zig`, `bench/coldquery.sh`): a
  one-shot
  CLI — `cli -- index` builds + persists the index (postings + a doc→path
  table) once; `cli -- query <needle>` is a **fresh process** that cold-loads
  the
  index (~30 ms) and reads & verifies **only the candidate files**. rg has no
  index, so every invocation re-walks the tree and reads every byte. Measured
  fresh-process via hyperfine (spawn included, warm cache): `queryLiteral`
  39ms→290ms (**7.4×**, 7 files read), `pgxpool` 47ms→274ms (**5.9×**, 399),
  `rate_limit` 46ms→293ms (**6.4×**), `func` 140ms→252ms (**1.8×**), `import`
  212ms→376ms (**1.8×**). rg now wins only the one-time build (~1.3 s) and a
  bare
  <3-byte needle (full read ⇒ tie). gist wins **every query after the first
  build — warm and cold.**
  (see also: gist)
- **Cold regex query** (`bench/cli.zig`): `cli -- regex <pattern>` runs the T2
  Thompson NFA on the cold path — prefiltered on the regex's required literal
  (sound, so no true match is dropped), `docMatch`-verified per candidate with
  a
  per-thread `Sim` over the existing parallel read fan-out (the `Regex` is
  shared
  immutably; only the `Sim` scratch is per-thread). The literal `query` path is
  unchanged (its benchmark contract is preserved). Proven e2e: 11 regex shapes
  (incl. `[a-z]+_[a-z]+` at 12,803 files and `//\s*TODO` at 16)
  **byte-identical
  to `rg (?-u) -l`** over gist's exact indexed file list, 0 FN / 0 FP.
  Refactored
  the shared cold-load / candidate-resolve / emit into `loadPersisted` /
  `candidateIds` / `emitMatches` so literal + regex share one path.
- **Parallel build + counting sort** (`src/trigram.zig`): `Index.build` now
  fans
  trigram extraction across all cores (byte-balanced contiguous doc shards,
  each
  thread filling a private region — no contention) and replaces the O(n log n)
  comparison sort over ~22.8M postings with an O(n) **counting sort** on the
  24-bit trigram key. The count is stable and the concatenated postings are
  doc-major, so each bucket lands doc-ascending — **byte-identical** to the old
  index. Small corpora keep the single-threaded comparison sort (the 64 MiB
  histogram isn't worth it below 4 MiB). **6.5 s → 1.0 s (6.4×), 124 MiB/s**;
  re-proven sound by the equality oracle on the new path. Degrades gracefully
  to
  the serial path on any spawn/alloc failure.
- **Parallel cold read** (`bench/cli.zig`): the cold path is IO-bound (read
  every
  candidate's bytes), and it was the one place a heavy cold query could lose —
  rg reads multi-threaded, gist read single-threaded. Fanned the candidate
  read+verify across one `std.Thread` per core, each shard doing **blocking
  `std.posix` reads** into a reused `per_file_cap` scratch buffer (no per-file
  alloc; same cap as the indexer ⇒ byte-identical corpus). Cold head-to-head
  now:
  `import` 212→**155 ms** (1.9×), `func` 140→**109 ms** (2.4×),
  `context.Context`
  **58 ms** (4.9×), selective queries 40–44 ms (6.6–7.5×). gist wins **every**
  cold query 1.9×–7.5×. Posix read path proven faithful: `queryLiteral` (7) and
  `pgxpool` (401) match the index-based counts exactly.
  - **Negative result (recorded, not hidden):** the first cut fanned this out
  via
    `std.Io.Group.concurrent`. Measured on the macOS io backend it was **~6×
    slower** (`pgxpool` 43→252 ms, `import` 212→1305 ms) — fiber/scheduling
    overhead dwarfed the reads and the concurrent file IO didn't parallelize.
    Raw `std.Thread` + blocking syscalls (what `search.zig` already uses) is
  the
    proven-fast path; the io event loop is bypassed for the worker reads.
- **Ranking signals are now language-agnostic** (`bench/signals.zig`, extracted
  from
  `bench/cli.zig`). The two byte-level heuristics the T4 ranker consumes — the
  **definition boost** (`definesNeedle`) and **codegen demotion**
  (`isGenerated`) —
  hardcoded only the monorepo's seven languages, so on any other codebase the
  def-boost stayed flat (a search for a Ruby/Kotlin/C# symbol never recognized
  its
  declaration) and generated files weren't demoted. Now:

  - `definesNeedle` knows the declaration keywords of the **mainstream
  ecosystem**
    (Kotlin `fun`, Elixir `defmodule`/`defp`, Perl `sub`, Scala `object`, Swift
    `protocol`/`actor`/`extension`, `record`/`namespace`/`trait`/`impl`/…
  alongside
    the original `fn`/`func`/`def`/`class`/`struct`/…), so the def-first
  ordering
    fires on any repo.
  - `isGenerated` leans first on the **universal** first-line markers
  (`@generated`,
    `Code generated`, `DO NOT EDIT`, `AUTO-GENERATED`, … — language-independent
  and
    far more reliable than any suffix list) and broadens the suffix fast-path
  across
    ecosystems (`.pb.cc`, `.pb.h`, `_pb2_grpc.py`, `.g.dart`, `.designer.cs`,
    `.min.js`, …).

  Dogfooding the extraction caught a **real latent bug**: `definesNeedle` only
  checked the identifier boundary _before_ the needle, so searching `Session`
  treated
  `type SessionStore struct` as its _definition_ (a prefix hit). It now
  requires a
  whole-word match on **both** sides. The signal still only ever reorders
  (never
  drops) a match, so it stays sound; the fix only sharpens the def-first order.
  New
  adversarial tests (`bench/signals_test.zig`) pin definition detection across
  ten
  languages, the use-vs-decl discriminators, and generated detection by suffix
  and
  by marker. Extracting the module also returns `bench/cli.zig` under the
  500-line
  shape cap (it had drifted to 554 with no `MONOLITHIC` marker).
- **SIMD substring scan** (`bench/simd.zig`): reading `std/mem.zig::findPos`
  shows `std.mem.indexOf` is SIMD only for a 1-byte needle — lengths **2–4**
  fall
  to `findPosLinear` (a naive byte loop) and 5+ to scalar Boyer-Moore-Horspool.
  Code search is dominated by 2–4 byte needles (`})`, `ctx`, `func`, `=>`,
  `::`,
  `fn`), so that naive path was the hot loss. `simd.contains` runs the memchr
  "generic SIMD": splat the needle's first + last byte, vector-compare both
  lanes
  across a V-wide window, AND the masks, and `eql`-verify only survivors.
  **Isolated single-thread full-corpus scan (125 MiB), std → SIMD MiB/s:** `})`
  2233→41051 (**18.4×**), `ctx` 2093→37735 (**18.0×**), `func` 2274→40713
  (**17.9×**), `=>` 1866→32019 (**17.2×**), `import` 6085→40757 (**6.7×**),
  `context.Context` 3560→19525 (**5.5×**) — std's ~2.2 GB/s naive path vs
  SIMD's
  ~40 GB/s. Wired into the parallel verify (`search.zig`) and the cold CLI
  (`cli.zig`). Byte-exact with `std.mem.indexOf`, proven by a 5000-case
  differential fuzz (`zig build test`, now wired) **and** the rg equality
  oracle
  (135 literals + 44 regexes, 0 FN / 0 FP, re-proven on the SIMD verify path).
- **Shape refactor**: extracted corpus loading into `bench/corpus.zig` and the
  parallel verify into `bench/search.zig`; the cold CLI lives in
  `bench/cli.zig`.
  Every file stays under the 500-line cap.
- **T3 freshness overlay** (`bench/fresh.zig`): keeps a persisted index correct
  against a working tree many agents rewrite many times a minute, without
  rebuilding and without consulting git history (the fragile part under heavy,
  overlapping, rebased commit churn). Insight: the cold query already reads &
  *verifies* every candidate against live bytes, so a stale/edited/deleted
  match
  is never a false **positive** — the only gap is a false **negative** (a file
  that now matches but wasn't a trigram candidate). So freshness only *widens*
  the candidate set with files touched since build; the existing verify does
  the
  rest. Anchor = the build's wall-clock instant (a `real` Io.Clock timestamp,
  same UTC-ns domain as file mtime); a file is fresh iff `mtime ≥ anchor`.
  Immune
  to commit chaos — rebases/overlaps/races never undo the fact that writing a
  file's bytes (incl. a `git checkout`/merge/pull landing a coworker's commit)
  advances its mtime — so it has no false negatives and cannot break, where
  `git diff HEAD` is *unsound* (a coworker commit already in HEAD shows no diff
  yet differs from our pre-commit index). The discovery stat-walk fans across
  the
  roots in parallel (private page-backed arenas, no shared-allocator
  contention).
  Proven end-to-end on a single probe file: a **new** file, a **modified** file
  whose new trigrams the index never saw, and a **deleted** file (stale posting
  reads-fails gracefully → no match, no crash) are each handled. Cold process
  wall **~42 ms vs ripgrep's ~555 ms (13×)**; worst-case cold-cache walk ~95 ms
  still ~6×. Backward compatible: no anchor file ⇒ freshness is skipped,
  behavior
  byte-identical to the pre-T3 cold path. `widen` dedup carries a unit test.
- **T4 fusion + rank** (`src/rank.zig`, `cli -- rank`): the lexical tiers
  return
  an unordered match *set*; an agent wants the one line that answers first — a
  symbol's **definition**, not its 200 call sites — and pays tokens for every
  line below. Ranking via **weighted Reciprocal Rank Fusion** (Cormack 2009):
  score(d) = Σ wᵢ/(k+rankᵢ) over three rank-based signals — lexical density,
  symbol/definition boost (weight 2), shallow-path — plus an optional external
  ranking (a graph-centrality hook; null until wired). RRF needs no
  per-signal normalization and admits new signals for free; embeddings stay out
  (CoREB: short keyword queries collapse them). The harness extracts per-file
  features in a parallel posix read pass (matching-line count, a cross-language
  definition-line detector, the representative best line) and prints ranked,
  token-compressed `path:line [def|use] ×n  <line>`. Proven on real symbols:
  the
  `pub fn` definition of `queryLiteral` / `parallelVerify` /
  `extractSortedUnique`
  ranks **#1** above every call site, ~25–42 ms cold. rrf + signals carry 4
  unit
  tests (definition beats a 25×-hotter usage; external graph drives + is
  weight-controlled). Kernel suite 28/28.
- **T4 ranking now demotes codegen output** (`src/rank.zig`). A fourth RRF
  signal,
  `authored`, sinks generated files (`*_grpc.pb.go`, `*_pb2.py`,
  `*.connect.go`, …)
  below hand-written code. Found by dogfooding: `rank context.Context` returned
  a
  head of `*_grpc.pb.go` stubs because a generated file wins _both_ the lexical
  signal (most occurrences) and the definition boost (its boilerplate `func (c
  *…)`
  parses as a decl) — yet it is never an agent's edit target. The class split
  is
  fused tie-aware (authored docs share rank 0, generated docs share rank
  `n_authored`), so it is neutral _within_ a class and never re-votes the
  density/def order among real files; when a symbol lives only in generated
  files
  the demotion is uniform and the def-first order is untouched. Detection
  mirrors
  the repo shape gates (generated filename suffixes + first-line `// Code
  generated` / `@generated` markers). Match sets are unchanged — the gist ≡ rg
  oracle still proves 0 false negatives / 0 false positives. `rank` output
  gains a
  `[gen]` tag.
- **The engine now lives entirely under `src/`, split into concern-scoped
  tiers;
  `bench/` is the benchmark/verify harness only** — a clean separation of the
  product from the tooling that measures it. Engine logic had accreted inside
  `bench/` next to the latency harness; it moved out into six tiers, each a
  subfolder with its own `README.md`:

  - `src/index/` (**T0** trigram candidate index —
  `ngram`/`trigram`/`persist`),
    `src/regex/` (Thompson NFA + byte-class DFA + Pike VM), `src/rank/` (**T4**
  RRF
    fusion + language-agnostic signals), `src/scan/` (no-prefilter parallel
  verify
    — `simd`/`sweep`/`verify`), `src/corpus/` (loading + mtime freshness
  overlay),
    `src/commands/` (the CLI driver surfaces that compose the tiers).
  - The `rg` drop-in was **renamed off ripgrep's source layout onto its
  features**:
    the one `rgcompat` monolith became
  `src/commands/ripgrep/{args,ignore,output,
  json,run}.zig`, `rgemit` became `output.zig`, and `pathfilter` split into
    `src/commands/scope/{glob,types}.zig`. Each module is now named for what it
  _is_.
  - `build.zig` builds two artifacts on the shared kernel — the production
  `gist`
    CLI (`src/surface/face/gist/main.zig`) and a separate `gist-bench` harness
    (`bench/bench.zig`); they no longer share a binary.

  Pure structural move — every `*_test.zig` rides `src/root.zig` and the full
  suite
  (177 tests, incl. the differential Pike-VM fuzz oracle) stays green.
  Rule-of-Five
  registry entries record the `src/` tier fan-out and the harness-only
  `bench/`.
  (see also: gist)

### Fixed

- **A `./root` positional no longer breaks anchored ignore matching**
  (`bench/rgignore.zig`). When the search root was given as `./some_dir`, gist
  prefixed every walked path with `./`, so an anchored rule (or a whitelist
  like
  `!/some_dir/build/`) failed to match and the path was mis-ignored.

  - **`match` normalizes a leading `./`** (new `stripDot`) on both the
  candidate
    path and the rule's `base` before comparing, so `./some_dir/build/foo` is
    matched identically to `some_dir/build/foo` — the anchored/negated rules
  now
    fire regardless of how the root was spelled. Output still keeps the `./`
  prefix
    ripgrep prints.

  Proven against real ripgrep as the oracle: `r829_2731` (`-l string
  ./some_dir`
  with a `build/` ignore + `!/some_dir/build/` whitelist) and `f1757`'s
  `./rust1`
  invocation now diff to **0 bytes** vs `rg`.
- **DFA compilation no longer churns the allocator on every subset-map probe,
  so
  compiling a pathological pattern is ~9× faster** (`src/regex/powerset.zig`).
  The
  determinizer interns each transition target into the subset map
  ~`states×ncls×2`
  times; a genuine blow-up probes it ≈86k times before bailing at `max_states`.

  - **`intern` now probes with a reusable scratch key** and heap-allocates a
    permanent key **only when the state proves genuinely new** — one alloc per
    interned state, not one alloc+free per probe. On a real fuzzer-surfaced
    cap-busting pattern this drops allocations from ≈86k to **4184** (≈
  `nstates`),
    and per-compile time from **~175ms → ~19ms** ReleaseFast (~5s → ~0.37s
  Debug).
  - Because interning duplicates is the common case in _any_ determinization,
  the
    win applies to every DFA compile, not just the pathological bail path.

  Proven with a before/after timing harness and pinned by a new deterministic
  regression guard (`powerset_test.zig`): a counting allocator asserts a
  cap-busting compile allocates `< 2×max_states` — it would jump ~20× if
  alloc-per-probe ever returns. Full regex suite (177 tests, incl. the
  differential
  Pike-VM fuzz oracle) stays green — no correctness change.
- **Query results now go to stdout, diagnostics to stderr** (`bench/cli.zig`,
  `bench/scan.zig`, `bench/corpus.zig`). The `query` / `regex` / `rank` paths
  printed _everything_ — match paths, ranked rows, and the timing summary —
  through `std.debug.print`, which writes to **stderr**. Found by dogfooding
  gist
  as an agent: `gist query Foo > files.txt` captured an **empty file** and
  `gist query Foo | head` mixed the `—` summary line into the paths — the
  opposite
  of the `rg` convention every agent and shell pipeline assumes. The match list
  (literal `query`), the ranked rows (`rank`), and the live-tree scan match set
  (`regex` / sub-trigram `query`) now emit on **stdout** via a raw
  `posix.write`
  loop (`corpus.emitStdout`, EPIPE-safe so `| head` exiting early can't crash
  the
  query); the human-facing `—` summary, the `[pipeline]` straggler canary, and
  the
  `no index` / `bad pattern` guidance stay on **stderr**. Match sets are
  byte-for-
  byte unchanged — the `gist ≡ rg` equality oracle (50 literals + 68 regexes)
  and
  the no-prefilter `scan_regress.sh` gate both still prove 0 false negatives /
  0 false positives, and every bench harness (which captures `2>&1` and splits
  by
  content shape) is unaffected. New permanent guard: `bench/streams.sh` asserts
  the results→stdout / diagnostics→stderr split across the literal, rank, and
  scan
  paths and reproduces the original empty-file bug as a falsifiable regression.
  (see also: gist)
- **README benchmark prose + `regex/adversarial_test.zig`** — escaped the bare
  `_loaders_` / trailing-underscore emphasis in the cold-loader notes (markdown
  lint), and switched the rg second-oracle differential's temp-path `bufPrint`
  from `catch unreachable` to `try` so a formatting error propagates instead of
  panicking (zig-safety ratchet). No behavior change to the search path.
- **`--ignore-file` precedence + `-u`/`--require-git` semantics match ripgrep**
  (`bench/rgignore.zig`, `bench/rgargs.zig`). Three ignore-source ordering
  bugs:

  - **`--ignore-file` is now lowest precedence** — added _before_ the in-tree
    `.ignore`/`.gitignore` (not after), so a repo `.ignore` `!imp.log`
  correctly
    overrides an `--ignore-file` `*.log` (`f45_precedence_with_others`).
  - **`-u`/`--no-ignore` no longer disables `--ignore-file`** — the explicit
    `--ignore-file` sources are loaded before the `no_ignore` early-return,
  matching
    rg (an explicit ignore file is honored even unrestricted); only
    `--no-ignore-files` drops them, and **`--ignore-files`** re-enables them
    (`f1466_no_ignore_files`).
  - **`--require-git` now undoes `--no-require-git`** (last flag wins) instead
  of
    being a no-op, so `--no-require-git --require-git` again requires a real
  `.git`
    before honoring `.gitignore` (`f1414_no_require_git`).

  Proven against real ripgrep as the oracle: all three regressions diff to **0
  bytes** vs `rg`.
- **`.skip` search no longer drops a zero-width match at a bare boundary /
  EOL**
  (`src/regex/analysis.zig`, `src/regex/core.zig`). The first-byte `.skip`
  search
  seeds a start only at line position 0 and immediately _before_ a byte in the
  first-set — never at a bare word-boundary gap or at end-of-line. That is
  sound
  for a match that must consume a first byte, but a **conditionally-nullable**
  branch can match with no consumed byte at a position the skip never visits.
  So a
  pattern like `zzz|\b{4,6}$` or `q|\B{2}` — where one branch supplies a
  first-set
  (forcing `.skip`) while another matches zero-width via a word boundary —
  silently
  missed the zero-width branch. `reachesMatchEol` couldn't rescue it: it
  deliberately won't cross a `\b`/`\B`, so its `eol_empty` shortcut stays false
  for
  these _content-dependent_ EOL matches.

  Surfaced by the regex engine's own adversarial differential fuzzer against
  the
  `rg` oracle: `MATCH-DIVERGENCE pat=/^\S\w{2}|\b{4,6}$/` and
  `DOC-DIVERGENCE pat=/…|\B+\B{4,6}$/` (gist returned `false` where `rg`
  matched).

  Fix: a new conservative analysis predicate `reachesMatchZeroWidth` — does the
  start ε-reach `match` through a zero-width path that may cross _any_
  assertion
  (`^ $ \b \B`)? — sets a `Regex.nullable` flag, and `lineMatchPike` routes
  nullable
  patterns to the `.plain` search (which re-seeds every position, EOL included)
  instead of `.skip`. Sound by construction: a false "nullable" only forgoes
  the
  skip optimization, never a match, and genuinely consuming patterns
  (`func\s+\w+`, `pgxpool`, …) stay non-nullable on the fast `.skip` path. The
  full
  differential fuzz suite is green again; permanent regression coverage lands
  in
  `src/regex/core_test.zig` (the `z|\b{4,6}$` / `z|\B{2}` / `z|\b{2,}$`
  skip-mode
  cases, expectations cross-checked against `rg`).
- **`grep` closes four more reflexive-invocation gaps found by dogfooding gist
  _as
  the agent_ against `rg`** (`bench/grepargs.zig`, `bench/lines.zig`). Racing
  the
  two on real repo questions surfaced one silent-wrong landmine and three
  fail-loud-on-a-legal-call breaks — each of which an agent's muscle memory
  hits:

  - **`--count-matches` was a silent-wrong landmine — now a true match count.**
  It
    aliased to `-c`/`--count`, so it counted matching _lines_ where rg counts
    individual match _spans_ — on `e` in one file gist said `165` (lines) while
  rg
    said `988` (matches), a wrong-but-confident number (the worst agent
  failure).
    It now counts non-overlapping leftmost-first spans via the same span engine
    `-o` rides (a per-shard `SpanSim`, allocated only when the flag is set),
  while
    `-c`/`--count` stays line-count. `-m N` caps the total; `--count-matches
  -v`
    falls back to counting non-matching lines (rg's behavior — invert has no
  span
    to count). **Proven byte-identical to `rg --count-matches`** across 11
    literal + regex patterns over the shared `-g '*.go'` scope on a large Go
    service tree (up to 2 591 files each, 0 mismatches).
  - **Corpus-policy no-ops gist already satisfies are accepted, not
  fail-loud.**
    `--hidden`, `--no-ignore[-vcs/-parent/-dot/-global]`, `-u`/`-uu`/
    `--unrestricted`, `--one-file-system` all ask rg to widen its corpus toward
    what gist's index **already** searches (it ignores `.gitignore` and
  includes
    hidden dotfiles — README "Scope vs ripgrep"), so they're no-ops here, not
    errors. Proven to leave output byte-identical to the bare query.
  - **`--sort`/`--sortr` swallow their value (gist emits path-ascending
  already).**
    gist's `grep` output is sorted by path (a stable, deterministic order),
  which
    _is_ `--sort path` — the overwhelmingly common agent request — so the flag
  is
    a no-op that consumes its value instead of erroring.
  - **Recognized-but-unsupportable flags fail LOUD with the reason + `rg`
    fallback, not the generic "unknown flag" dump.** `-P`/`--pcre2` (PCRE
    backreferences/lookaround — gist runs a linear-time RE2-style engine),
    `-U`/`--multiline[-dotall]` (gist matches per line), and
    `--json`/`--vimgrep`/`--column` (gist emits fixed `path:line:text`) now
  print
    a one-line "why + use `rg …`" instead of leaving the agent to guess whether
  it
    typo'd or hit a real limit. Crucially still fail loud — never silently
  ignored
    (which would give a wrong result on a genuinely PCRE/multiline pattern).

  Correctness unchanged: the `gist ≡ rg` set oracle still proves **0 FN / 0
  FP**
  (140 literals + 70 regexes over the byte-identical snapshot), and the parser
  carries 4 new adversarial tests (count-matches ≠ count, the corpus no-op
  family,
  `--sort` value-swallow, the fail-loud contract for `-P`/`-U`/`--json`/…).
- **`rg -o` emits zero-width matches for a nullable pattern, matching rg's
  `find_iter`** (`bench/rgemit.zig`). gist's only-matching span loop
  unconditionally
  skipped empty spans, so `-o ''` (and other nullable patterns) produced
  nothing
  where ripgrep prints an empty `-o` line per zero-width match.

  - **`emitMatches`** now emits a zero-width match when the regex is
  **nullable**
    (`re.nullable`), following rg's progress rule — an empty match adjacent to
  the
    previous match's end is skipped, empties advance one byte — and honoring
  `-w`
    (word-boundary check on the empty span). A **non-nullable** pattern never
    produces an empty span, so its output is byte-identical to before: **zero
    regression risk** for every previously-passing `-o`/`-w` case (verified: no
    passing test regressed).

  Proven against real ripgrep as the oracle: `r1891` (`-won ''` over `"\n##\n"`
  →
  one empty match on the blank line, three on `##`) now diffs to **0 bytes** vs
  `rg`, taking the drop-in to **100% supported-surface parity (265/265)**.
- **`rg` drop-in matches ripgrep's stdin heuristic exactly — the socket fd type
  is
  no longer a silent divergence** (`bench/rgcompat.zig`). ripgrep decides to
  search
  stdin (vs. walking `./`) with `!is_terminal(fd0) && (is_file || is_fifo ||
  is_socket)` (grep/cli `is_readable_stdin`). gist's `readableStdin`
  whitelisted
  only regular files and FIFOs, so `sock_producer | gist rg pat` — and, more
  commonly, any exec API that wires fd0 to a `socketpair` — fell through to a
  directory walk while real `rg` searched the stream. Added `S.IFSOCK` to the
  whitelist; the three-type set still excludes a tty and `/dev/null` (a char
  device), so bare `rg pat` and `rg pat </dev/null` keep walking `./`.

  **Proven byte-identical to `rg` across all four fd types** (socket, pipe,
  regular-file, `/dev/null`) via a `socketpair`-backed differential probe:
  socket
  and pipe search the stream (`match here`, rc 0), `/dev/null` and a bare tty
  walk
  the CWD, a redirected regular file searches that one source.
  Supported-surface
  parity over the 330 mined ripgrep tests stays **61/61 = 100%**.

  Note: the "`rg foo` appears to hang" failure mode in exec-spawned shells (a
  pipe/socket wired to fd0 that never sends data or EOF) is ripgrep's own
  documented, unmitigable heuristic — its source calls it "a terrible failure
  mode, but there really is no good way to mitigate it" (core/flags/hiargs.rs).
  gist now reproduces it faithfully; non-interactive callers should redirect
  `</dev/null` exactly as they would for `rg`.
