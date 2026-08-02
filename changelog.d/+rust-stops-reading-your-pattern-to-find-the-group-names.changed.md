`Regex::group_names` and `Regex::group_index` answer from the compiled pattern
now, not from a scan of the pattern text.

Filling that table used to mean walking the pattern bytes looking for `(?P<x>)`
and `(?<x>)` and then confirming each candidate through `irgx_group_index`.
It is a second parser, and it only ever had to be wrong once to lose you a name
silently. PCRE2's `(?'x'…)` was never taught to it, so that spelling vanished.
An escaped `\(` counted as a group and shifted every number after it. A `(?#`
comment is just text, and text is all the scanner could see. None of that is
fixable by scanning harder - the parenthesis you are looking at means whatever
the grammar that already ran decided it means.

ABI 2 adds `irgx_group_name`, so the table is now walked out of the handle:
group 1 through `irgx_group_count`, whatever the engine calls each one, the
same on the linear arm and the PCRE2 arm. Both textual helpers are gone. The
public shape did not move - still `(name, group number)` in declaration order,
still only the groups that have a name. The engine lends those bytes for as long
as the handle lives, and the handle goes back to the pool when the compile
returns, so each name is copied into an owned `str` on the way past.

Two more things arrived with ABI 2, and both are things you notice by nothing
going wrong.

`irgx_fault` now says which string its offset is measured in instead of
leaving you to work it out from a NULL path, so `Error::Syntax { at }` is filled
only from an offset the engine measured in the pattern - the string you would
print a caret under. There is no corpus behind this library and no verb here
opens a file, so a file-space offset is a debug assertion rather than a branch.

`find_all` reports how many matches the text HAS rather than how many fit in the
window it was handed. So `Regex::find_iter` over a text with more matches than
the first window holds is two searches, always: one that measures, one that
collects at exactly the size the first one reported. It used to double the
window and go around again, and a text whose match count landed exactly on a
window size paid a whole extra scan to discover it had already been finished.

`ABI_VERSION` is 2 and still checked before the first call, so a `libirgx`
handed in through `IRGX_LIB_DIR` that speaks ABI 1 says so in a sentence
naming both numbers rather than reading `at_space` out of a struct that does not
have one. The four vendored archives are rebuilt on it.
