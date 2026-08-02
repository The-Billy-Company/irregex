The row protocol now lives in `include/irgx.h` beside the status codes and
pattern flags: `irgx_row` / `irgx_rows` / `irgx_schema_*` / the four
`irgx_rows_*` walkers. Each product library still exports its own producer
(`gist_run`, `relate_run`, `blast_run`); they all hand back the same cursor, so
a host asking three packages three questions learns one way to read the answer.
