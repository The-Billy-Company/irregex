`flagbench` gains a `--json` record-emit floor — the hermetic, blocking guard
that locks in the per-record hot-path shaves (the `pathData` object cache,
`writeUint`, and the `asciiOnly` UTF-8 pre-check) so they can't silently rot.
It times the public per-file encoder core `json.emitOne` over the real corpus
(the exact serial stream every serial/shard/walk path shares, isolated from the
walk/read/fan-out), and self-checks the emitted `match`-record count against the
same independent per-line-hit oracle the `-l`/`-c` floors trust — a
dropped/duplicated record fails loud, byte-shape parity staying rgsuite's job.
The floor (≥ 500 MiB/s of bytes searched, ~half the observed slowest needle so
the shared coworking box's load never false-trips it) is advisory by default and
blocking under `--gate`, joining the `-i/-n/-v/-l/-c/-o/-w/-r` slate the
`ci_order.sh` performance phase already runs. Wiring it in also compiled the
formerly-dormant `-U --json` ripgrep-parity table test into `zig build test`
(the encoder is now reachable from the module root, so `refAllDecls` reaches its
tests), and made `output.MlHarness`'s constructor/teardown `pub` for the
cross-module reuse that test always intended.
