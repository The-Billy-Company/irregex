The Rust binding's binary lookup could not answer for two of the three faces it
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
