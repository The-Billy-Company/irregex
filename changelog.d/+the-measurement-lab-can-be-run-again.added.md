The fifteen engine measurement lanes are wired into `build.zig` again. The
extraction carried every source file across but none of the build graph that
reached them, so `crest`, `sieve`, `roofline`, `portbound`, `lowerbound`,
`scale`, `indexq`, `engine-census`, `compose-rung`, `parabix-rung`,
`automata-rung`, `patternid-rung`, `multipattern`, `sweep-rung`, and
`ladder-price` were code nothing could build. `zig build lab` installs all of
them; each is also its own named step. They stay off the default install, so a
bare `zig build` still pays only for the library and its C ABI.

The two postures a lane can take are now a declared field rather than a habit.
A certificate layer honours whatever `-Doptimize` you asked for, because a
cycles/byte number is a claim about *that* build; a production rung compiles at
`-Dlab-optimize` (ReleaseFast by default), because a rung that races the shipped
ladder has to be built the way the shipped ladder is or the ratio describes the
build mode instead of the machine.

`probes.zig`, `pmu.zig`, and `stats.zig` are exported as the `probes` / `pmu` /
`stats` modules and `bench/apparatus/harness` joins `build.zig.zon`'s `.paths`,
so `gist`'s harness reaches them the same way it already reaches `brigade.zig`.
One probe registry and one significance test across both repositories is what
lets a competitor race there and an engine rung here be compared by class name;
a second copy would drift and quietly stop meaning the same thing. `stats.zig`
now compiles as its own test root too — previously its bootstrap-CI and
Mann-Whitney tests rode a harness that has since moved, leaving the verdict math
every lane reports through compiled by nothing.

`abi()` is back on `src/root.zig`. The contract names it as the source of the
ABI integer and the export shim now returns it rather than restating the
literal, so the two cannot disagree.
