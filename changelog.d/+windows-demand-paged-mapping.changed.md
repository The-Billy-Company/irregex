`portal.map` is a real demand-paged mapping on Windows now, not an eager copy.

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
