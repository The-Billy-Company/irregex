//! Whole-buffer (`-U`) emit — byte-identical vs ripgrep.
//!
//! Every expected string below was captured from `upstream/ripgrep` (`rg -U …`) on
//! the same input, so these are ripgrep-parity assertions, not
//! self-consistency checks.

const std = @import("std");
const Opts = @import("../../argv/args.zig").Opts;
const MlHarness = @import("multibuf.zig").MlHarness;

/// One parity row: rg's captured output for a pattern + option set over a
/// body. Harness knobs derive from the options (`dotall` from
/// `multiline_dotall`, capture compilation from `-r`).
const MlCase = struct { pat: []const u8, o: Opts, body: []const u8, want: []const u8 };

test "-U whole-buffer emit parity table (captured from ripgrep)" {
    const cases = [_]MlCase{
        // -U cross-line span prints the full run of lines
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .line_num = true }, .body = "a\nb\nc\n", .want = "1:a\n2:b\n" },
        // -U match ending exactly at EOF with no trailing newline
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .line_num = true }, .body = "a\nb", .want = "1:a\n2:b\n" },
        // -U -o emits each line fragment of the match
        .{ .pat = "x\\ny", .o = .{ .multiline = true, .line_num = true, .only_matching = true }, .body = "x\ny\nx\ny\n", .want = "1:x\n2:y\n3:x\n4:y\n" },
        // -U -o --column -b: match-start col (block-relative) + abs offset per fragment
        .{ .pat = "YZcd\\nef", .o = .{ .multiline = true, .line_num = true, .only_matching = true, .column = true, .byte_offset = true }, .body = "abYZcd\nef\n", .want = "1:3:2:YZcd\n2:3:2:ef\n" },
        // -U -o --column: block-relative columns across coalesced matches
        // block base = line 1; match2 starts at buffer byte 4 ⇒ column 5.
        .{ .pat = "a\\nb|b\\nc", .o = .{ .multiline = true, .line_num = true, .only_matching = true, .column = true }, .body = "a\nb\nb\nc\n", .want = "1:1:a\n2:1:b\n3:5:b\n4:5:c\n" },
        // -U non-o --column repeats the match-start column on every line
        .{ .pat = "YZcd\\nef", .o = .{ .multiline = true, .line_num = true, .column = true }, .body = "abYZcd\nef\n", .want = "1:3:abYZcd\n2:3:ef\n" },
        // -U non-o -b reports each printed line's own offset
        .{ .pat = "YZcd\\nef", .o = .{ .multiline = true, .line_num = true, .byte_offset = true }, .body = "abYZcd\nef\n", .want = "1:0:abYZcd\n2:7:ef\n" },
        // -U -C1 context frames the multiline match
        .{ .pat = "c\\nd", .o = .{ .multiline = true, .line_num = true, .before = 1, .after = 1 }, .body = "a\nb\nc\nd\ne\nf\ng\n", .want = "2-b\n3:c\n4:d\n5-e\n" },
        // -U -A1 separates non-adjacent blocks with --
        .{ .pat = "a\\nb|e\\nf", .o = .{ .multiline = true, .line_num = true, .after = 1 }, .body = "a\nb\nc\nd\ne\nf\ng\n", .want = "1:a\n2:b\n3-c\n--\n5:e\n6:f\n7-g\n" },
        // -U -c counts distinct match-start lines; --count-matches counts spans
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .mode = .count }, .body = "a\nb\nx\na\nb\n", .want = "2\n" },
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .mode = .count_matches }, .body = "a\nb\nx\na\nb\n", .want = "2\n" },
        // -U -c with a nullable pattern counts start-lines, not all empties
        .{ .pat = "a*", .o = .{ .multiline = true, .mode = .count }, .body = "aa\nbb\n", .want = "2\n" },
        .{ .pat = "a*", .o = .{ .multiline = true, .mode = .count_matches }, .body = "aa\nbb\n", .want = "4\n" },
        // -U -v prints lines outside every match's span
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .line_num = true, .invert = true }, .body = "a\nb\nx\na\nb\n", .want = "3:x\n" },
        // -U -m caps the number of matches
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .line_num = true, .max_per_file = 2 }, .body = "a\nb\na\nb\na\nb\n", .want = "1:a\n2:b\n3:a\n4:b\n" },
        // -U -w rejects a span not on word boundaries
        // 'b' is preceded by 'a' (a word byte) ⇒ not a word match ⇒ no output.
        .{ .pat = "b\\nc", .o = .{ .multiline = true, .line_num = true, .word = true }, .body = "ab\ncd\n", .want = "" },
        // Isolated: 'b' at line start, 'c' at line end ⇒ word match.
        .{ .pat = "b\\nc", .o = .{ .multiline = true, .line_num = true, .word = true }, .body = "b\nc\n", .want = "1:b\n2:c\n" },
        // -U -x (line-anchored pattern) matches whole lines only
        .{ .pat = "^(?:a\\nb)$", .o = .{ .multiline = true, .line_num = true }, .body = "a\nb\nc\n", .want = "1:a\n2:b\n" },
        // -U --multiline-dotall lets . cross newlines
        .{ .pat = "a.b", .o = .{ .multiline = true, .multiline_dotall = true, .line_num = true }, .body = "a\nb\n", .want = "1:a\n2:b\n" },
        // -U without dotall: . does not cross a newline
        .{ .pat = "a.b", .o = .{ .multiline = true, .line_num = true }, .body = "a\nb\n", .want = "" },
        // -U match spanning many lines prints them all once
        .{ .pat = "a.*e", .o = .{ .multiline = true, .multiline_dotall = true, .line_num = true }, .body = "a\nb\nc\nd\ne\n", .want = "1:a\n2:b\n3:c\n4:d\n5:e\n" },
        // -U -o zero-width matches follow rg's progress rule
        // "aa" then three empties on line 2 (offsets 3,4,5); the phantom at EOF is dropped.
        // rg: `rg -U -o -n 'a*'` ⇒ 1:aa / 2: / 2: / 2: (empties emit — not lone on line 2).
        .{ .pat = "a*", .o = .{ .multiline = true, .line_num = true, .only_matching = true }, .body = "aa\nbb\n", .want = "1:aa\n2:\n2:\n2:\n" },
        // -U -o empties on line 2 take line-relative columns (not block-absolute)
        // rg `-U -o -n --column 'a*'` ⇒ 1:1:aa / 2:1: / 2:2: / 2:3: — the line-2 block
        // resets its column base to line 2, so the empties read 1,2,3 (not 4,5,6).
        .{ .pat = "a*", .o = .{ .multiline = true, .line_num = true, .only_matching = true, .column = true }, .body = "aa\nbb\n", .want = "1:1:aa\n2:1:\n2:2:\n2:3:\n" },
        // -U -o skips a blank line covered by a cross-line span
        // rg `-U --multiline-dotall -o -n 'a.*b'` over "a\n\nb\n" ⇒ 1:a / 3:b — the blank
        // middle line emits nothing, and the line number jumps 1→3.
        .{ .pat = "a.*b", .o = .{ .multiline = true, .multiline_dotall = true, .line_num = true, .only_matching = true }, .body = "a\n\nb\n", .want = "1:a\n3:b\n" },
        // -U -o lone ^ zero-width at line start emits nothing
        // rg `-U -o -n --column '^'` over "a\nb\n" ⇒ (empty). Each ^ is the only match
        // on its (non-blank) line and sits at the line start ⇒ rg emits nothing.
        .{ .pat = "^", .o = .{ .multiline = true, .line_num = true, .only_matching = true, .column = true }, .body = "a\nb\n", .want = "" },
        // -U -o separate empties on adjacent lines are line-relative, not one block
        // rg `-U -o -n --column 'x?'` over "a\nb\n" ⇒ 1:1: / 1:2: / 2:1: / 2:2: — two empties
        // per line; because neither span crosses a line, the two lines are separate blocks,
        // so line 2's columns reset (1,2) rather than continuing (3,4).
        .{ .pat = "x?", .o = .{ .multiline = true, .line_num = true, .only_matching = true, .column = true }, .body = "a\nb\n", .want = "1:1:\n1:2:\n2:1:\n2:2:\n" },
        // -U --crlf keeps the carriage return in the emitted line
        .{ .pat = "a\\r?\\nb", .o = .{ .multiline = true, .line_num = true, .crlf = true }, .body = "a\r\nb\r\nc\r\n", .want = "1:a\r\n2:b\r\n" },
        // -U --null-data uses NUL as the line terminator
        .{ .pat = "a", .o = .{ .multiline = true, .line_num = true, .null_data = true }, .body = "a\x00b\x00", .want = "1:a\x00" },
        // -U -o -r emits the expanded template once per match
        .{ .pat = "(a)\\n(b)", .o = .{ .multiline = true, .line_num = true, .only_matching = true, .replace = "<$1>" }, .body = "a\nb\n", .want = "1:<a>\n" },
        // -U -r replaces the cross-line match and re-splits the result
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .line_num = true, .replace = "Z" }, .body = "a\nb\nc\n", .want = "1:Z\n" },
        .{ .pat = "(a\\nb)", .o = .{ .multiline = true, .line_num = true, .replace = "P${1}Q" }, .body = "a\nb\nc\n", .want = "1:Pa\n2:bQ\n" },
        // -U -r keeps context line numbers original after a collapsing replace
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .line_num = true, .after = 1, .replace = "Z" }, .body = "a\nb\nc\n", .want = "1:Z\n3-c\n" },
        // -U empty buffer and no-match produce no output
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .line_num = true }, .body = "", .want = "" },
        .{ .pat = "a\\nb", .o = .{ .multiline = true, .line_num = true }, .body = "x\ny\nz\n", .want = "" },
    };
    for (&cases) |c| {
        var h = try MlHarness.init(c.pat, .{ .dotall = c.o.multiline_dotall, .replace = c.o.replace != null });
        defer h.deinit();
        try std.testing.expectEqualStrings(c.want, try h.run(c.o, c.body));
    }
}
