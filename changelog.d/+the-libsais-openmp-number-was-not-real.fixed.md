`vendor/libsais/README.md` claimed OpenMP bought **1.65×** on the suffix sort and
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
