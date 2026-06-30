**Ranking signals are now language-agnostic** (`bench/signals.zig`, extracted from
`bench/cli.zig`). The two byte-level heuristics the T4 ranker consumes — the
**definition boost** (`definesNeedle`) and **codegen demotion** (`isGenerated`) —
hardcoded only the monorepo's seven languages, so on any other codebase the
def-boost stayed flat (a search for a Ruby/Kotlin/C# symbol never recognized its
declaration) and generated files weren't demoted. Now:

- `definesNeedle` knows the declaration keywords of the **mainstream ecosystem**
  (Kotlin `fun`, Elixir `defmodule`/`defp`, Perl `sub`, Scala `object`, Swift
  `protocol`/`actor`/`extension`, `record`/`namespace`/`trait`/`impl`/… alongside
  the original `fn`/`func`/`def`/`class`/`struct`/…), so the def-first ordering
  fires on any repo.
- `isGenerated` leans first on the **universal** first-line markers (`@generated`,
  `Code generated`, `DO NOT EDIT`, `AUTO-GENERATED`, … — language-independent and
  far more reliable than any suffix list) and broadens the suffix fast-path across
  ecosystems (`.pb.cc`, `.pb.h`, `_pb2_grpc.py`, `.g.dart`, `.designer.cs`,
  `.min.js`, …).

Dogfooding the extraction caught a **real latent bug**: `definesNeedle` only
checked the identifier boundary *before* the needle, so searching `Wallet` treated
`type WalletService struct` as its *definition* (a prefix hit). It now requires a
whole-word match on **both** sides. The signal still only ever reorders (never
drops) a match, so it stays sound; the fix only sharpens the def-first order. New
adversarial tests (`bench/signals_test.zig`) pin definition detection across ten
languages, the use-vs-decl discriminators, and generated detection by suffix and
by marker. Extracting the module also returns `bench/cli.zig` under the 500-line
shape cap (it had drifted to 554 with no `MONOLITHIC` marker).
