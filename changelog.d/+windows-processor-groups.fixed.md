Every parallel stage in the kernel sized itself from `std.Thread.getCpuCount()`,
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
