A bare `zig build` now installs only the product surface — the `gist` +
`relate` CLIs and the C-ABI static/dynamic libraries — instead of also
compiling the six measurement-lab executables (`gist-bench`, `relate-knn`,
`codex-scale`, `gist-roofline`, `gist-lowerbound`, `gist-portbound`). Each
lab exe still installs via its named step (`zig build bench`, `zig build
roofline`, …) and the new `zig build lab` umbrella installs all six;
`certify_session.sh` builds the lab step explicitly. Cuts the default
rebuild to 4 artifacts from 10.
