`Munch`'s anchored walks picked a transition table per byte: `trans_fin` for
the final position, `trans_in` everywhere else. The choice is a function of
the position alone - it flips exactly once, at the end - and it was spelled
as a conditional inside the per-byte loop, a branch the predictor mostly wins
and still pays for on every one of the megabytes a corpus scan feeds through.

The loop now runs `trans_in` to the second-to-last byte and handles the final
byte once, peeled out below it with `trans_fin` - same states, same accepts,
same answers, one fewer question per byte. `reach` and `first` each carry the
split, and the final table's contract is unchanged: it resolves `$`, and is
correct only on the true last byte of the caller's slice.
