`vouch_test.zig` grades the premise the answer keep borrows — that two runs
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
