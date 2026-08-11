Windows walk paths now have one spelling from root to leaf. A caller-supplied
root and every discovered suffix are normalized to `/` when the walk is
materialized, and the Go and Rust bindings translate native paths at their
membership boundary. Iterating a walk and asking whether it holds that same path
can no longer disagree because one side used `\`.
