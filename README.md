---
doc_radar:
  counts:
    - description: "irregex src/ layers (kernel · corpus · surface) + the assay instrumentation floor"
      glob: pkg/kernels/irregex/src/*
      unit: dirs
      equals: 4
  sentinels:
    - description: "the Zig package identity is irregex"
      file: pkg/kernels/irregex/build.zig.zon
      contains: ".name = .irregex,"
    - description: "the C ABI is the irregex_* session surface (libirregex, include/irregex.h)"
      file: pkg/kernels/irregex/include/irregex.h
      contains: ["irregex_abi_version", "irregex_open", "irregex_search", "irregex_close"]
    - description: "registered in the changelog roster (OSS-package membership)"
      file: pkg/tools/support/chronicle/packages.py
      contains: 'Package("pkg/kernels/irregex"'
    - description: "the irregex primitives tier is a first-class root export"
      file: pkg/kernels/irregex/src/root.zig
      contains: "pub const irregex = struct"
    - description: "correctness remains ahead of performance in the proof pipeline"
      file: pkg/kernels/irregex/bench/gates/ci_order.sh
      contains: ["pcre parity -P", "index-elision parity", "macro certificate"]
    - description: "the certificate still carries the live ripgrep macro comparison (a re-mint may move every number, but never drop the section)"
      file: pkg/kernels/irregex/bench/certify/artifact/CERTIFICATE.md
      contains:
        - "## Layer A — macroscopic dominance over ripgrep"
        - "gist vs ripgrep across 12 classes"
    - description: "canary for the corpus + speedup range this README quotes in prose — a re-mint moves these, and breaking here is the signal to restate them"
      file: pkg/kernels/irregex/bench/certify/artifact/CERTIFICATE.md
      contains:
        - "corpus: 20660 files · 204.6 MiB"
        - "8.93x"
        - "5.78x"
    - description: "canary for the crest speedup distribution this README quotes in prose — a re-mint moves these rows, and breaking here is the signal to recompute the geometric mean and restate the floor/ceiling"
      file: pkg/kernels/irregex/bench/certify/artifact/crest.csv
      contains: ["27.758", "13.120", "3.234", "1.375", "96.42"]
    - description: "the honest optimality disclaimer survives every re-mint — the certificate never claims hardware optimality"
      file: pkg/kernels/irregex/bench/certify/artifact/CERTIFICATE.md
      absent:
        - "cycles/byte sits on the hardware ceiling"
        - "no implementation on this chip can go faster"
---

# irregex

## What it is

The **irregular expression engine** is one Zig kernel for three set-shaped
problems: regular-expression **match**, compression-based **relate**, and
engine-side **weave**. Regex asks _"does this text match?"_ irregex also asks
_"which of these N intents hit?"_, _"what in this tree is like this file?"_,
and _"does this string exist anywhere, proven rather than sampled?"_
([ADR-363](../../../docs/architecture/3-decisions/363-irregex-primitives.md)).

I kept coming back to one fact: text is bits. Flip one bit and the patterns
change. Gist started with a question: _can I use those differences to reject
most files before reading them?_ That pulled me from exact matching into
compression, similarity, and information retrieval. irregex is what came out.
The research record keeps that path auditable: product claims, inherited
ideas, and falsification evidence live separately under
[`research/`](research/README.md).

> **Scope:** build-time dev tooling for the coding agents that work _on_
> Billy. It has nothing to do with Billy-the-product.

## Why it exists

Agents search constantly. The tree keeps changing. Every extra line burns
context. I built irregex for that loop. Speed matters, but truth matters more;
the index can save reads, but it never gets to overrule current bytes.

Then I started thinking about compressors. They turn repeated structure into
shorter descriptions. What if I used that same math, but returned the files
most like a query instead of one compressed blob? That became `relate`. It aims
at a lane beside embeddings, not a disguised replacement: embeddings compare
learned semantic vectors; Relate exposes repeated bytes, compression kinship,
structural echoes, marginal information, and corpus provenance.

## Prior art

Most of the math here I did not invent. I put the pieces together, then made
each claim prove itself. The kernel builds on:

- Google Code Search's trigram index (Russ Cox), with a conservative live-tree
  freshness overlay rather than snapshot authority;
- Thompson/Pike/RE2-family linear matching plus opt-in, resource-capped PCRE2;
- for the scan tier above that DFA, four separately-invented ideas we adopted on
  merit rather than authorship: Parabix bit-parallel transposition (Cameron et
  al.), symbolic derivatives over a minterm alphabet (Veanes et al.), one-pass
  capture determinism (RE2 / rust `regex`), and over-approximating prefilter
  quotients (CODFA, Hyperscan). Each was refereed for priority, found
  anticipated, and built anyway — being second is a citation, not a reason;
- the Ferragina–Manzini FM-index, SA-IS, Huffman wavelet trees, and RRR
  bitvectors for the restorable compressed codex;
- LZJD, winnowing, Ziv–Merhav cross-parsing, and FM-index matching statistics
  for compression kinship and attribution.

One piece is mine: the **crest sieve**, a forced-class-run necessary condition
that prunes the literal-free class repetitions every index in the trigram
family concedes. New math, adversarially refereed for priority; the theorem,
calculus, and its own prior-art survey live in
[`research/crest/`](research/crest/PROOF.md).

I deliberately keep model-free byte kinship rather than dress it up as
semantic retrieval. `PatternSet` uses a fused gate only to skip all-miss files,
then confirms each pattern through Gist's own matcher; Hyperscan already owns
high-throughput expression-ID attribution, while this kernel claims equality
with N independent Gist searches. Research dossiers:

- [`research/gist/CLAIM.md`](research/gist/CLAIM.md) ·
  [`PRIOR_ART.md`](research/gist/PRIOR_ART.md) ·
  [`TESTING.md`](research/gist/TESTING.md) — product thesis, competitive
  ancestry, and evidence for agent-loop exact search
- [`research/relate/CLAIM.md`](research/relate/CLAIM.md) ·
  [`PRIOR_ART.md`](research/relate/PRIOR_ART.md) ·
  [`TESTING.md`](research/relate/TESTING.md) — compression-as-search,
  Language Trees lineage, and measured boundaries
- [`research/crest/PROOF.md`](research/crest/PROOF.md) ·
  [`PRIOR_ART.md`](research/crest/PRIOR_ART.md) ·
  [`TESTING.md`](research/crest/TESTING.md) — the novel forced-class-run
  sieve, its priority review, and its falsification plan

## Quick start

From the Billy checkout (the package requires the Zig version declared in
[`build.zig.zon`](build.zig.zon)):

```bash
make install-gist                    # build all three CLIs, link them, index the tree

gist 'SearchRequest' --rank          # ranked exact/regex search
gist 'foo(?=bar)' -P                 # indexed PCRE2 when a sound literal exists
relate similar path/to/file --top 5  # compression-nearest files
relate pack "how does CDC recover?"  # non-redundant context set

gist status
relate index --shelf                 # optional warm atlas + quotation shelf
relate status
```

Indexes are optional accelerators. Missing, stale, or uncertain state falls
back to current files rather than changing the answer. See the face-specific
docs for the complete CLI surfaces and standalone `zig build` commands.

## Gist in brief

Use `gist` when the question contains an exact string, regex, symbol, path
scope, or familiar grep-shaped output. Start with the ripgrep-shaped reflex —
`gist PATTERN [PATH...] [FLAGS]` — then choose Gist-native `--rank`,
`--no-index`, resident, or codex behavior only when the intent calls for it.
See the [`gist` README](src/surface/face/gist/README.md) for the full ergonomics guide,
niche flag choices, compatibility boundaries, and evidence.

## Relate in brief

Use `relate` when the question is about resemblance, non-redundant context,
provenance, duplicate families, renamed structure, or many attributed patterns.
Two verbs carry the kinship questions — **`similar`** (what is near _this_ one?)
and **`echoes`** (what repeats among _all_ of them?) — and the axes that used to
be separate verb names are flags on them: `--unit file|function`, `--as
copies|twins|shapes|any`, `--shape pairs|families|distinct`, and `--matching PAT`
to ask any of it inside an exact filter. `pack`, `quote`, and `patterns` answer
the three non-kinship shapes. See the
[`relate` README](src/surface/face/relate/README.md) for the complete verb guide,
score directions, corpus policy, warm-tier behavior, and evidence.

## In your editor

`make install-gist` also links [`editor/vim`](editor/vim/README.md) into the
package directory of every editor it finds, so a machine that already had Vim
or Neovim gets the integration with no configuration: `:grep` becomes gist,
`<Leader>gg` searches the word under the cursor, and results stream into the
quickfix list while the search is still running. `:help gist` is the full
guide; `:GistHealth` (`:checkhealth gist`) says what is wired.

The three faces stay themselves there: `:GistRank` is the definition-first
view, `:GistSimilar` is `relate similar` on the current buffer, and
`:GistBlast` puts a symbol's live blast radius in the quickfix list so `:cnext`
walks a change's consequences. `GIST_VIM_INSTALL=0` declines the whole thing.

## In your shell

`gist --generate {man,complete-bash,complete-zsh,complete-fish,complete-powershell}`
mints the manual and the completions from the same flag table argv is parsed
with, and `make install-gist` places each one where that shell already looks —
so `man gist` answers and `gist -<TAB>` completes with no configuration.
[`shell/`](shell/README.md) has the install sites; `GIST_SHELL_INSTALL=0` declines.

ripgrep's completions are the best hand-written ones in the field, and its zsh
function carries a comment asking you to re-run a CI script "to ensure that the
options supported by this function stay in synch with the `rg` binary". A drift
gate is an admission that there is drift to gate. Generating from the parse
table removes the category, and spends the difference on three things:

- **A tab costs no process.** `_rg_types` answers `-t<TAB>` by forking
  `rg --type-list` and re-parsing it, per keystroke. gist's menu is an array
  written into the file at generation: **~0.065 ms against ~5 ms, about 77×**,
  and its 239 candidates each carry that type's globs, where rg discards them
  and offers 224 bare names.
- **The menu is captioned.** `gist -<TAB>` arrives grouped by what a flag
  _changes_ — corpus, semantics, presentation, execution — rather than one
  alphabetical wall, and the man page is organized the same way, off the same
  `Reach` the parser already records.
- **Exclusions are derived.** `-i`/`-s`/`-S` rule each other out because they
  resolve to one case mode in the parser, not because a list was maintained.
- **The menu matches the grammar.** A verb is offered at `argv[1]` and nowhere
  else, because `gist -w index` searches for "index"; a glued short value is
  split, so `-t<TAB>` menus the registry where rg's generated bash dead-ends.

`make test-gist-shell` has each shell parse its own artifact, proves every flag
is filed in exactly one group, and fails if any generated file would run a
program at tab time.

## Configuration that outlives one invocation

Two files, split along a line ripgrep's `.ripgreprc` does not draw: **what the
tree is** versus **what one reader likes to look at**. Neither is required, and
`--no-config` (or `GIST_NO_CONFIG=1`) ignores both.

**`.irregex.toml` — committed, at the tree root.** Facts about the repository
that every clone and every agent should agree on. It holds no argv, only typed
keys, and all three faces honor it:

```toml
roots = ["services", "libs", "clients"]   # what "the corpus" means here
skip  = ["graphify-out", "vendor"]        # directories the corpus walk never enters
types = ["billy:*.billy"]                 # extra --type names
```

Discovery climbs from the working directory and **stops at the repository
boundary**, so a tree without its own declaration never inherits a parent
directory's. `roots` and `skip` size **the corpus** — what `gist index` and
`relate` enumerate — exactly as `GIST_ROOTS` and `GIST_SKIP` always did; an
ad-hoc `gist PAT some/dir` still searches what you point it at. This is the
first home for two facts that had nowhere good to live: search roots were a
per-shell `GIST_ROOTS` nobody else on the team has, and extra skip directories
were `<GIST_DIR>/skips.list` inside a gitignored artifact directory that every
cache clear deletes. Both are everyone's, and both now
travel with the clone. The file is ceilinged at **corpus** reach (below): a
shared file may say what the repository _is_, and may never quietly change what
matches for the people who clone it.

**`$XDG_CONFIG_HOME/gist/preferences` — machine-local, never committed.**
(`$GIST_PREFERENCES` overrides the location; `~/.config` is the fallback.) Flag
lines, one flag per line, prepended to argv so anything typed still wins:

```text
--heading
-n
--glob '!vendor/*'      # quotes are quotes, not glob characters
```

These apply **only when stdout is an interactive terminal**. That is not a rule
invented for this file — it is the envelope gist already draws for the answer
keep, the resident daemon, and color resolution. Riding the same line puts a
pipe, a redirect, `--json`, a script, CI, the daemon, and every agent
structurally outside its reach, so none of them ever needs `--no-config` to be
sure what it will get. Lines are tokenized with shell quoting (ripgrep's are
verbatim argv elements, which is why a quoted glob there arrives with its
quotes and silently matches nothing), every flag is checked against the catalog
as the file is read, and a line that does not start with a flag is refused —
a stray bare word in a persisted argv file is the search pattern for every
invocation forever.

**`GIST_HYPERLINK` — where a result should take you when you click it.** The
one preference that has to work in every face, since `relate` and `irregex`
share no flag struct with `gist`. Its value names a posture (`auto` · `always` ·
`never`), a destination (`vscode`, `zed`, `kitty`, … or a literal
`app://…{path}:{line}` format), or both as a `WHEN,WHERE` pair — so
`GIST_HYPERLINK=vscode` in a profile says _where_ and leaves the terminal probe
to say _whether_, and `always,vscode` overrides the probe too. Default `auto`
links only what a person is reading in an emulator known to render OSC-8; a
pipe, a redirect, `--json`, and NUL-framed `-0` output stay plain bytes, the
last two no matter what any posture says. `GIST_TRACE=link` prints the one-line
reason a run linked or didn't.

Underneath both is a **reach** axis on every flag, also emitted by
`gist --schema`: `corpus` (which files and bytes the engine sees), `semantics`
(which lines match), `presentation` (how it is rendered), `execution` (only how
it is computed). It is what lets a persisted layer be judged rather than
trusted, and what lets a zero-match run name a preferences file as the possible
cause — the one thing a reader cannot see in the line they typed.

### Asking what is in force

ripgrep has a configuration file and no way to interrogate it, which is why the
standing advice for a surprising result is "try `--no-config`" — bisection
standing in for introspection. Persisted state earns introspection or it should
not be persisted:

| Command             | Answers                                                                                                                                                                                                                                                                                                                                                        |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gist config`       | The resolved stack — each layer's path, what it declares, whether it is in force, and any `GIST_ROOTS`/`GIST_SKIP` in your shell that outranks the committed file. `--json` for the machine.                                                                                                                                                                   |
| `gist config check` | Is what I wrote valid, **without** running a search. Reports both layers before exiting (2 if either is malformed), so fixing a file takes one pass rather than one run per mistake.                                                                                                                                                                           |
| `gist config init`  | Writes `.irregex.toml` prefilled from what this machine already carries — `GIST_ROOTS`, `skips.list` — so the migration is not "learn the format". `--write` creates it. It lifts only facts you asserted and **never infers a skip from the shape of the tree**: a guessed skip silently hides files, which is the failure the whole layer exists to prevent. |

```text
$ gist config
corpus — what this tree is (committed, applies to everyone)
  ../../.irregex.toml                     # found by climbing; roots are relative to IT
    roots ../../services, ../../libs
    skip  graphify-out
  GIST_ROOTS=services:libs in this shell — overrides the charter's `roots`

taste — what you like to look at (machine-local, terminal only)
  ~/.config/gist/preferences
    --heading -n --smart-case
    NOT in force — stdout is not a terminal, so this file is invisible to this run
    contains flags that change WHICH LINES MATCH, not just how they render
```

`gist config` and `gist status` keep describing both files under `--no-config`
and `GIST_NO_CONFIG`, reporting suppression as a state of the run rather than
refusing to answer. A shell that exports it is precisely when a reader needs to
see what is on disk, and the one command whose job is introspection declining to
introspect would reproduce the defect this verb exists to repair.

Faults in either file are **located and quoted**, with a nearest-name guess when
one is worth making (`gist: .irregex.toml:3: unknown key` / "gist: try `roots = [...]` — `rootz` is not a charter key"). A malformed **charter** is
fatal to any search, because a corpus nobody described is worse than no file at
all. A malformed **preferences** file is fatal only to a run that would actually
have used it: a pipe, a script, and an agent never open it, so one person's typo
cannot fail everybody else's tooling with an error naming a path they cannot see.

## Use Gist and Relate in tandem

The tools are strongest as a loop: Relate finds the neighborhood; Gist proves
the exact claim inside it. A practical sequence is:

1. **Locate what you can name.** Start with `gist SYMBOL --rank` or a normal
   regex search. This gives exact, current-byte evidence.
2. **Recover what you cannot name.** If spelling is uncertain or the question
   is descriptive, hand `relate similar` free text instead of a path — a text
   probe is priced by coding gain, not distance; use `relate pack` when the goal
   is a compact reading set rather than another ranked list.
3. **Return to exact search.** Feed the surfaced symbol, phrase, or narrowed
   paths back into Gist to verify definitions, uses, and absence.
4. **Check for siblings before adding code.** Run `relate similar PATH` (or
   `PATH#Lnnn` for one function); `relate echoes --as copies` finds copy
   families and the default `twins` channel finds the same structure hidden
   behind renamed vocabulary.
5. **Batch exact intents once.** When several independent Gist searches form
   one audit, use `relate patterns -e A -e B …` for one walk with exact
   per-pattern attribution.
6. **Trace provenance when wording matters.** Use `relate quote TEXT` to
   attribute corpus-known phrases, then Gist the cited source for surrounding
   context.

```bash
gist 'ResidentSession' --rank
relate similar src/surface/exec/session/warm/resident.zig --as shapes --top 5
relate pack "fail-closed resident freshness and cold fallback" --top 6
gist 'decline|fallback' src/surface/exec/session -n
```

That is the intended division of labor, not a rigid pipeline. Keep exact
questions in Gist and set-, similarity-, or provenance-shaped questions in
Relate; check each individual README when choosing flags, lenses, thresholds,
or lifecycle controls.

## irregex in brief

When a question needs **both** engines in one step — not a hand-run pipeline —
compose them ([ADR-367](../../../docs/architecture/3-decisions/367-composed-irregex-cli.md)).
Exact match narrows a typed candidate set, then compression reasons only inside
it, so the statistical work never re-includes files the patterns excluded.

Composition-as-narrowing is a **modifier**: `--matching PAT` on `relate similar`,
`echoes`, or `pack`. Being a flag, it combines with every other axis those verbs
carry, which a fixed composed verb per corner of that space could not:

- `relate pack TEXT --matching P` — the minimal non-redundant reading set among
  files that actually match the patterns (exact filter, then coverage packing
  over only those files).
- `relate echoes --matching P` — of the files matching P, which are forks
  (`--as copies`) or renamed structural twins (the default `twins`) of each
  other, at either `--unit` and in any `--shape`.

The `irregex` CLI keeps the two questions that need the tree's **current bytes**
rather than a narrowing:

- `irregex provenance TEXT` — quotation attribution, then re-verification
  against the source's current bytes; a phrase surfaces only if the live file
  still holds it.
- `irregex blast SYMBOL [--budget N] [ROOT…]` — the live blast radius of a
  symbol from CURRENT bytes (no precomputed graph): seed definition + kind,
  direct dependents/dependencies, tangential twins/ripple, and the comments
  that mention it, as a compact token-budgeted report for an editing agent.

`gist` and `relate` stay the direct faces; `irregex` forwards none of their
verbs. See the [`irregex` README](src/surface/face/irregex/README.md) for the composed
workflows and the `CandidateSet` model.

## Choose a face

| Face        | What it is                                                                                                                                                                 | Docs                                                                       |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| **gist**    | the rg-parity code locator CLI: trigram + crest read-elision, ranked search, and a resident session; the agents' everyday search reflex                                    | [`src/surface/face/gist/README.md`](src/surface/face/gist/README.md)       |
| **relate**  | compression-as-search: retrieval/packing, quotation, kinship/families/echoes, and exact pattern sets; `index` / `status` own the warm lifecycle                            | [`src/surface/face/relate/README.md`](src/surface/face/relate/README.md)   |
| **irregex** | the composed face needing live bytes: `provenance` (quote, re-verified) and `blast` (live symbol radius). Reading-set / fork narrowing is `relate pack\|echoes --matching` | [`src/surface/face/irregex/README.md`](src/surface/face/irregex/README.md) |
| **codex**   | the compressed self-index: a corpus stored at entropy-bound size with exact O(m) `count`/`find` and byte-exact restoration; powers `gist codex` + `relate quote`           | [`src/corpus/index/codex/README.md`](src/corpus/index/codex/README.md)     |
| **ffi**     | the in-process C-ABI warm session (`irregex_open` / `irregex_search` / `irregex_close` over `libirregex`)                                                                  | [`src/surface/ffi/README.md`](src/surface/ffi/README.md)                   |

The three CLIs are separate faces over one shared floor (`src/kernel/`,
`src/corpus/`, `src/surface/`); none owns a
private copy of the corpus walk, scope machinery, indexes, or execution hosts.
Operational READMEs explain how to use each face; the
[`research dossiers`](research/README.md) explain why the claims deserve to
exist and where they stop.

## Guarantees and limits

- Indexes may skip reads, never own truth; current bytes verify every result.
- `gist` preserves rg-shaped output and 0/1/2 exit codes, but
  [`gist --schema`](src/surface/face/gist/README.md#the-search-contract), not folklore
  about ripgrep, defines supported flags.
- PCRE2 is opt-in (`-P` or `--engine auto`) and resource-capped. If required
  literals cannot be proven, gist scans instead of risking a false negative.
- `relate` provides deterministic byte-level kinship, attribution, and packing;
  it serves a retrieval-shaped purpose without pretending compression distance
  is learned semantic meaning.
- A resident daemon may **hold** an answer a client already computed, keyed to a
  corpus change epoch, but never computes one itself; if the tree moved, the
  held bytes are dropped rather than served. Repetition is an acceleration tier,
  never a source of truth.
- The C ABI is versioned and flat; the header and
  [`ffi` documentation](src/surface/ffi/README.md) are its public contract.

## Evidence: six runnable claims

The idea started the work. It did not prove anything. Every claim below has a
checked-in harness that tries to break it, with the complete claim → prior art
→ evidence chain indexed in [`research/README.md`](research/README.md).
“Only” means only the competitive field that harness actually runs.

### 1. PCRE2 semantics can ride a sound code-search index

The established indexed searchers in our field, **csearch** and **zoekt**, use
RE2-family matchers and cannot express lookaround or backreferences. The
PCRE-capable peers - ripgrep, ugrep, ag, GNU grep, and git grep - scan the tree.
Gist is the field's unusual intersection: a vendored, JIT'd, resource-capped
PCRE2 10.47 verifier behind the same persisted trigram index as its linear
engine. A conservative parser extracts only literals that every PCRE2 match
must contain; if it cannot prove one, gist scans rather than guessing.

The hand-authored `-P` matrix proves stdout, exit-code, and indexed
≡ `--no-index` parity against live `rg -P` for lookaround, backreferences,
atomic/possessive forms, Unicode switches, and resource-limit failures
(**30/30**). `bench/races/pcre_headtohead.sh` then times a row only after its
file set equals ripgrep's, and records csearch/zoekt as inexpressive rather than
pretending they lost a race they cannot enter.

### 2. A stale index can accelerate a live tree without owning truth

Most indexes answer from a snapshot. irregex makes the stronger operational
claim needed by a coworking tree: an index may only **elide reads**. The live
walk still chooses the corpus; changed files widen the candidate set; current
bytes verify every survivor; deletion and uncertainty make resident paths
decline to the cold path. Staleness can therefore cost time, never matches.

`bench/gates/index_elision_parity.sh` compares every indexed answer's byte-exact
line multiset and exit code with `--no-index`, including a match written after
the index anchor. Cross-file order is normalized because the parallel engine
streams worker-discovery order. The filesystem and resident-session gates
separately exercise new, modified, deleted, overflowed, and reconcile-racing
files. This is the proof behind “freshness-aware,” not a promise delegated to a
watcher.

### 3. A code index can replace the corpus and still answer it exactly

I followed the same idea from matching into description length. The **codex**
applies the FM-index family as a restorable code-corpus shelf: `count(P)` is
O(|P|), `find` locates occurrences, and `restore()` regenerates the source bytes
from the index alone. With a clean freshness walk,
`gist codex count == 0` proves corpus-wide absence with no source-file I/O;
categorically stronger than a trigram candidate filter.

`zig build codex-scale` checks every timed answer against a naive scan, then
save/load, locate, and byte-exact restoration at every size. At 128 MiB the
count index occupies **1.95 bits/character**, below the corpus's measured
H₂ of 2.90, while a 16-byte count stays flat at **~11 µs** from 1–128 MiB
(**3,727×** the top-size scan). The same shelf powers `relate quote`: known
corpus text prices near 0.15 bits/byte versus ~15 for foreign bytes, with each
maximal quotation attributed to a source file; a measured ~90× separation.

### 4. Set-shaped search can be exact, attributed, and anti-redundant

`PatternSet` compiles N intents once and walks once without erasing which
pattern hit which file. Its fused prefilter is skip-only: every emitted answer
must equal N independent single-pattern searches. The fused alternation alone
cannot satisfy that per-pattern Gist-equivalence contract; confirmation
restores exact attribution. Unit tests gate equality with the prefilter both
on and off; `bench/races/multipattern.sh` remains an ad hoc throughput race,
not a committed performance certificate.

Instead of collapsing shared information into a compressed blob, I use the
same accounting to return a **set**. In `relate pack`, corpus-priced
fingerprints make every pick pay only for bits not already covered by earlier
picks. The greedy max-coverage plan carries the standard (1−1/e)
approximation bound and emits marginal-bit receipts, so near-duplicate files
cannot quietly consume an agent's context budget as independent value.

### 5. A new necessary condition can close the trigram index's blind spot

Every index in the trigram family — csearch, pg_trgm, RE2's prefilter, zoekt,
Blackbird, gist's own — reduces a regex to required substrings, so a
literal-free class repetition like `[0-9a-f]{12}` extracts nothing and forces
a full scan. Gist's certificate records that hole honestly (cand% = 100% on
`regex-classcount`). The **crest sieve** is the formula I wrote to close it:
index each file's longest run per byte-class (16 bytes/doc), derive from the
regex the run every accepted string must contain, and skip any file that never
crests that high. It is not a substring test; the soundness theorem, the
min-of-max calculus over the AST, and an adversarially refereed priority
review live in [`research/crest/`](research/crest/PROOF.md).

The sieve reads the **engine's own AST** — the same parse, options, and case
fold the matcher compiles — because the one structural way to get a false
negative here is a second grammar that reads a construct differently. Deriving
ĝ from a private mini-parser did exactly that: it took `\<` for an escaped
literal `<` rather than a word-boundary assertion, so `\<foo\>` demanded a punct
run that a matching file need not contain. `zig build test` now checks the Sieve
Theorem itself — 1 500 generated patterns over every node kind × both engine
modes × caseless, asserting matched ⇒ never pruned — and `zig build crest`
repeats it fail-closed on the live corpus (20 661 files, 204.6 MiB), over every
file × query plus 96k randomized pattern/file pairs.

Measured through the shipped CLI — same binary, same index, only the sidecar
toggled — the eight narrow-class queries run **7.5× faster end-to-end at the
geometric mean**, with diff-identical match sets: 27.8× on `[0-9a-f]{12}`
(96.4% of files pruned), 13.1× on caseless hex-8, 3.2× on `[0-9]{4}`, down to
1.4× on `[A-Z]{4}`, where four-byte uppercase runs are common enough in code
that only 20% of files prune. The three wide-class controls (`\w{3,8}`,
`[A-Za-z]{5}`, caseless `[A-Z]{6}`) prune under 1% and pay 2–4% for asking —
the sieve's whole downside. The count-population cousin at the same thresholds
prunes ≤1% where the run prunes 93%: the run is the condition, not the count.

### 6. Performance claims can be certificates, not benchmark anecdotes

The idea got me moving. It did not prove the system. So I built the checked-in
**Dominance-and-Fit Certificate**. Correctness gates run first; only then do five
independent layers measure empirical
dominance (A), static and native port pressure (B/B′), the hardware roofline
(C), the algorithmic read lower bound (D), and the crest sieve's fail-closed
pruning of the trigram blind spot (E). A Layer-A win requires both a
lower median and Mann–Whitney p < 0.05; missing counters or tools are printed
as missing, never inferred.

The name states the reach, because each layer is narrower than "optimal" would
imply: Layer C measures the scan's _distance_ from the
DRAM roofline and reports that headroom rather than claiming the roof (the mint
run sits well below it); Layer A's cycles/byte are cross-checked against Layer
B's static microarchitectural bound, not measured on the mint machine; and
Layer D certifies the minimum candidate set the filter can _prove_, not a global
algorithmic minimum. So it certifies two things and says so on the cover:
measured **dominance** over a named baseline, and each layer's **fit** against a
stated bound — every line a measured number with a provenance, never a proof of
universal or hardware optimality. The certificate carries the same per-layer
disclaimers. It was called a "Certificate of Optimality" until that title
outran what Layers A–D actually establish.

The claim is deliberately narrow: it certifies `gist`'s fresh-process,
cold exact-search path over 12 literal/regex classes. It does **not** certify
every CLI shape (`--include-zero` is a serial count mode), the warm daemon,
`relate`, or the composed `irregex` face. Those surfaces keep separate
correctness and performance evidence under `bench/rgsuite/`, `bench/matrix/`,
`bench/session/`, and the relate harnesses; none inherits Layer A's dominance
claim by association.

On the recorded **20,660-file / 204.6 MiB macroscopic corpus**, the
end-to-end linear/literal path beats ripgrep in all 12 query classes by
**5.78×–8.93×**. The separately minted lower-bound layer covers the same
204.6 MiB corpus (20,661 files at its own mint) and checks the narrower structural statement:
trigram pruning touches no rejected file bytes, and the DFA verifies each
admitted byte exactly once. The artifact, raw data, machine identity, losses,
and rerun commands live in
[`bench/certify/artifact/CERTIFICATE.md`](bench/certify/artifact/CERTIFICATE.md);
`make bench-gist-certify` refreshes B–E on an existing Layer A, while
`CERT_FULL=1 CERT_PUBLISH=1 CERT_SUDO=1 make bench-gist-certify` remints and
publishes the full A–E bundle.

I carried the same discipline into the agent surface: `--rank` puts definitions
above call sites and demotes codegen; misses coach on stderr while stdout stays
pipe-clean; and output budgets protect the context window. The theory earns its
place only when the tool feels obvious in the hand.

## Package layout

| Dir            | What                                                                                                                                                                   |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/kernel/`  | pure compute: `match/` · `rank/` · `kinship/` · `batch/` · `compose/` · `primitives/` (incl. bits + crest)                                                             |
| `src/corpus/`  | tree walk · scope · persisted indexes (`trigrams/` · `postings/` · `codex/` · `atlas/` · `crest/`)                                                                     |
| `src/surface/` | transports + faces: `exec/{cold,session}` · `ffi/` · `face/{gist,relate,irregex}` · `cli/` shared vocabulary                                                           |
| `src/assay/`   | the instrumentation floor (imports only `std`): typed `Span`/`Duration`/`Anchor` clocks, `Tally(Schema)` counters, and the `GIST_TRACE` lens + sink diagnostic channel |
| `include/`     | `irregex.h`: the flat C ABI (`irregex_*` symbols)                                                                                                                      |
| `bindings/`    | Python (`billy-irregex` — all three faces, subprocess + optional cffi) and Rust (subprocess) faces                                                                     |
| `contract/`    | `search_api.toml`: the unified SearchRequest/irregex contract (ADR-352)                                                                                                |
| `bench/`       | certification + competitive benchmark harness (rgsuite, races, certify, roofline)                                                                                      |
| `editor/`      | the Vim/Neovim plugin (`vim/`) and the installer that links it into an editor that already exists                                                                      |
| `shell/`       | the generated `gist(1)` + bash/zsh/fish/pwsh completions: the installer that places them, and the suite that has each shell parse its own                              |

See [`src/README.md`](src/README.md) for the tier-by-tier map and
[`src/surface/face/gist/README.md`](src/surface/face/gist/README.md) for the gist architecture
narrative, competitive benchmarks, and the full flag table (supported +
improvements, where gist is strictly better than rg — never a regression).
[`bindings/python/README.md`](bindings/python/README.md) covers the importable
face, which deliberately diverges from the CLI where a program's needs do:
calibration grades and scored populations become fields instead of stderr
commentary, `Region.read()` hands back source rather than coordinates, and the
composed reports expose their conclusion (`Blast.paths`) next to their evidence.

## Build & test

```bash
make install-gist    # build (ReleaseFast) + symlink ~/.local/bin/{gist,relate,irregex} + index
                     # + link the editor plugin + place the manual and completions
make build-gist      # staticlib + dynlib (libirregex) + irregex.h → zig-out/
make test-gist       # zig build test: unit + differential-fuzz suites
make test-gist-vim   # the editor plugin's headless suite, run in both Vim and Neovim
make test-gist-shell # each shell parses its own generated completion; mandoc lints the page
```

One changelog covers the whole package (one version, one release unit):
`CHANGELOG.md` + `changelog.d/` at this root, roster row `irregex` in
`pkg/tools/support/chronicle/packages.py`.

## Project

- **License:** [Apache-2.0](LICENSE) — third-party attributions in [`NOTICE`](NOTICE)
- **Changes:** [`CHANGELOG.md`](CHANGELOG.md)
- **Contributing:** [repository guide](../../../CONTRIBUTING.md)
- **Security:** [reporting policy](../../../SECURITY.md)
