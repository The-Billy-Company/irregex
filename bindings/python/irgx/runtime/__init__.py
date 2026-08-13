"""How an answer actually gets here — the transports, the decoder, and the ladder.

Every verb in this binding is answered by the same certified engine; the only
question is which door it came through. This package owns all of them and the
order they are tried in:

    native (in-process C-ABI)  →  resident session (UDS)  →  subprocess CLI

Each rung is *complete on its own*, so a fall to the next one changes the
latency and nothing else. A declinature is not a failure: the kernel answers
`IRGX_STALE` when its in-process view cannot be trusted for this query, which
means "ask the tier below", and the caller never learns it happened.

  * `loader` — the face registry: a product package registers the library it
      owns, and this composes one cffi type universe and opens it. Nothing is
      mapped that no package claimed.
    * `analytic` — the seventeen analytic verbs: parameters lowered once, run
      through the owning library's `<face>_run`, rows pulled as a cursor with
      real batching, and the row-schema digest verified before a row is believed.
    * `decode` — one schema-driven decoder for every row type.
    * `cold` — the subprocess tier, rebuilding the same rows from the CLI's NDJSON
      so both transports feed one decoder.
    * `shell` — process invocation for every face's binary.
    * `errors` — the typed failures, including the two the analytic plane adds.

  The in-process session and the resident daemon are not here: they hold one
  product's corpus, so they live in that product's own package (its native and
  daemon modules) and register themselves with `loader`.
"""

from __future__ import annotations
