# Security Policy

`irregex` is a library that runs attacker-influenced input by design. A regex
engine's whole job is to take a pattern from one place and bytes from another
and walk them against each other, and the faces built on it point that
machinery at whatever files a tree happens to contain. So the interesting
failures here are not configuration mistakes; they are memory safety, resource
exhaustion, and a parser trusting an artifact it should have re-derived.

## Reporting a vulnerability

**Do not open a public issue, pull request, or discussion.**

Use GitHub's private reporting - the **Security** tab on this repository,
"Report a vulnerability" - which opens a thread only the maintainers can read.
If that is unavailable to you, email **security@billylives.com**.

Please include:

- what you found and what it lets an attacker do;
- the smallest reproduction you can manage: the pattern, the subject bytes or
  corpus, the flags, and which surface you drove (the Zig API, the C ABI, or one
  of the bindings);
- the commit or release you tested, the target triple, and the Zig version if
  you built it yourself;
- a crashing input file if you have one, attached rather than pasted, so
  whitespace and invalid UTF-8 survive the trip.

We will acknowledge within **72 hours** and give you a triage verdict with a
severity within **7 days**. If it is real we will agree a disclosure date with
you, credit you in the changelog fragment and the release notes unless you would
rather we did not, and ship the fix before the details go public. There is no
paid bounty.

We will not pursue anyone who reports in good faith, works against their own
data and their own machines, and gives us a reasonable window to fix the thing
before publishing.

## Supported versions

Pre-1.0, and the version number says so. Fixes land on `main` and ship in the
next release; there are no maintained release branches and no backports to
earlier tags. The C ABI freezes at 1.0.0 - see the release notes for what that
promises - and this policy will grow a support window when it does.

If you are pinning by url and hash in a `build.zig.zon`, or by version in a
`Cargo.toml` / `go.mod` / lockfile, a security fix requires you to move the pin.
Watch releases on this repository.

## What we consider a vulnerability here

Not everything that goes wrong is a security issue, and calling everything one
would make this page useless. These are the classes we treat as security:

- **Memory safety anywhere in the engine.** An out-of-bounds read or write, a
  use-after-free, or a wild pointer reachable from any pattern and any subject.
  Zig's safety checks are on in `Debug` and `ReleaseSafe` and off in
  `ReleaseFast`, which is what ships in the faces - so a bug that is a clean
  panic for you may be a memory-safety bug for the people running the release
  build. Report it as one.
- **A parser trusting a persisted artifact.** The candidate indexes, the
  freshness anchor, and the FM-index shelf are files on disk, and a malicious or
  corrupt one must be rejected rather than followed. An artifact that steers the
  loader into an out-of-bounds read, an unbounded allocation, or an infinite
  loop is a vulnerability, not a "don't do that".
- **Wrong answers that cross a trust boundary.** A hit reported for a file that
  does not contain the pattern, or a miss on a file that does, is a correctness
  bug in general - and a security bug when a caller uses the engine to decide
  something (a scanner, a filter, a policy check). Say so in the report if that
  is your case.
- **Superlinear blowup on the linear engine.** The default engines are
  linear-time in the length of the subject, and that is a promise, not a
  tendency. A pattern that makes them behave otherwise is a bug in the ladder.
- **Bugs in vendored code as we build it.** PCRE2 and libsais are carried under
  `vendor/` and pinned by url and hash in `build.zig.zon`. If an upstream
  advisory affects the version we ship, tell us and we will re-vendor. If our
  build options or our call sites make an upstream component unsafe in a way it
  is not upstream, that one is ours.
- **The C ABI corrupting a caller.** A binding that follows the contract in
  [`include/irgx.h`](include/irgx.h) must not be able to end up with dangling
  memory or a double free. Handle lifetime, error paths, and the re-compile
  path after a stale handle are all in scope.

## What is not a vulnerability

- **PCRE2 backtracking.** `-P` selects a vendored PCRE2, and PCRE2 is a
  backtracking engine: a pattern with nested quantifiers can go exponential.
  That is the documented trade you make by opting in, and it is why the
  linear engines are the default. Bound it with PCRE2's own match limits at your
  call site. An unbounded *linear-engine* pattern is a different story - see
  above.
- **Cost proportional to the input.** A large corpus takes longer to search than
  a small one, and a pattern with no required trigram cannot be prefiltered.
  That is arithmetic, not a denial of service.
- **Misusing the C ABI.** Freeing a handle twice from your own code, or reading
  a match after the subject buffer went away, is caller error. If the header
  fails to *say* it is caller error, that is a documentation bug worth filing in
  public.
- **A dependency advisory with no reachable path here.** Tell us anyway - we
  would rather re-vendor than argue - but it will be triaged as maintenance.

## What already tries to catch this

None of it is a guarantee, and finding something these missed is exactly the
kind of report we want:

- a fuzz target for the trigram index loader
  (`src/corpus/index/trigrams/trigram_fuzz.zig`) - the artifact-parsing path
  named above;
- a corpus mined from ripgrep's own `rgtest!` suite, so an independent
  implementation is the correctness oracle rather than a hardcoded expectation,
  and a `python_oracle.json` the bindings check their answers against;
- `zig build test` on every push, on both Linux and macOS, at the Zig pinned in
  [`.github/workflows/ci.yml`](.github/workflows/ci.yml) - plus a `hermetic` job
  that re-runs the whole suite under a deliberately hostile environment, because
  a test that reads ambient configuration is green here and red on the only
  machine that matters, someone's;
- ratchets under [`quality/ratchets/`](quality/ratchets/README.md) that hold
  behavior a test cannot: one canonical out-of-memory exit, a fault taxonomy
  every error path is drawn from, and a gate against bypassing the assay;
- an architecture contract ([`contract/irregex.zone`](contract/irregex.zone))
  that machine-checks the import topology, so a zone cannot quietly reach past
  the boundary it was given.

## Provenance and supply chain

[`NOTICE`](NOTICE) lists every vendored and borrowed component with its license
and what it is used for. Third-party code is physically vendored rather than
fetched at build time: `zig build` is hermetic and offline, and the `.lazy`
entries in `build.zig.zon` exist to pin the exact upstream release by url and
content hash. To re-vendor, `zig fetch --save` the new release and refresh the
bytes under `vendor/` in the same commit as the pin.
