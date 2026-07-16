Warm client gates every post-connect recv with a 2s poll deadline so a wedged
daemon (accepts but never READY) falls through to cold instead of parking forever.
