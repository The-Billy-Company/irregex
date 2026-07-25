const std = @import("std");
const t = std.testing;
const core = @import("core.zig");

test "DBG dfa.match vs docMatch on bounded shorthand class" {
    const pats = [_][]const u8{ "\\s{1,2}", "\\w{1,2}", "\\d{1,2}", "\\s+", "\\s{1}", "a{1,2}", "[ ]{1,2}" };
    inline for (.{ true, false }) |uni| {
        for (pats) |p| {
            var re = try core.Regex.compileOpts(t.allocator, p, .{ .unicode = uni });
            defer re.deinit();
            var sim = try core.Regex.Sim.init(t.allocator, &re);
            defer sim.deinit();
            const lm = re.lineMatch(&sim, "a b c");
            const dm = re.docMatch(&sim, "a b c");
            const pk = re.lineMatchPike(&sim, "a b c");
            std.debug.print("DBG u={} /{s}/ lineMatch={} docMatch={} pike={} dfa={} anchored={} accel={}\n", .{ uni, p, lm, dm, pk, re.dfa != null, re.anchored, if (re.dfa) |d| d.accel != null else false });
        }
    }
}
