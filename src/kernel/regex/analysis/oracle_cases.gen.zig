// Generated from the independent Python automata oracle; DO NOT EDIT.
// Sources: research/crest/oracle/{contract,export_zig,fixtures,nfa,oracle,syntax}.py
//          and contract.toml (assertions = "refuse").
// Determinism: partition all 532 nodes by exact (q2,q1) thresholds, take
// 1 q2-positive + 2 q1=3 + 10 q1=2 + 9 q1=1 + 10 q1=0 nodes, each ordered
// by (sha256(repr(node)), repr(node)), then evaluate order statistics 1..4 for {a}.
// All 15 contract projections map a to the least member and b to the least nonmember.
// The consuming family contains no assertion, and none is generated here.
pub const source_sha256 = "a1b20026009cb37b904608f6a5ae54e089aaa14b30434766f777767a92fda4f8";
pub const family_sha256 = "424f10fbc14e1b7ca30106fb2ee9b775c6ff2866d141db6e92269c48b7669209";
pub const contract_sha256 = "d47a7bf851030c8809e3920c8b3f9cc3a6d79974ce4eeed877f9611360cd6aa6";
pub const family_count: usize = 532;
pub const selected_count: usize = 32;
pub const fixture_count: usize = selected_count * projections.len;
pub const supported_production_ranks = [_]u8{ 1, 2, 4 };
pub const order_statistics = [_]u8{ 1, 2, 3, 4 };

pub const Predicate = enum { digit, hex, upper, lower, alpha, word, space, punct, literal_space, dot, quote, lparen, slash, underscore, assign_sep };
pub const Projection = struct { predicate: Predicate, member: u8, nonmember: u8 };
pub const projections = [_]Projection{
    .{ .predicate = .digit, .member = '0', .nonmember = '\x00' },
    .{ .predicate = .hex, .member = '0', .nonmember = '\x00' },
    .{ .predicate = .upper, .member = 'A', .nonmember = '\x00' },
    .{ .predicate = .lower, .member = 'a', .nonmember = '\x00' },
    .{ .predicate = .alpha, .member = 'A', .nonmember = '\x00' },
    .{ .predicate = .word, .member = '0', .nonmember = '\x00' },
    .{ .predicate = .space, .member = '\x09', .nonmember = '\x00' },
    .{ .predicate = .punct, .member = '!', .nonmember = '\x00' },
    .{ .predicate = .literal_space, .member = '\x20', .nonmember = '\x00' },
    .{ .predicate = .dot, .member = '.', .nonmember = '\x00' },
    .{ .predicate = .quote, .member = '"', .nonmember = '\x00' },
    .{ .predicate = .lparen, .member = '(', .nonmember = '\x00' },
    .{ .predicate = .slash, .member = '/', .nonmember = '\x00' },
    .{ .predicate = .underscore, .member = '_', .nonmember = '\x00' },
    .{ .predicate = .assign_sep, .member = ':', .nonmember = '\x00' },
};

pub const Case = struct {
    pattern: []const u8,
    oracle: [order_statistics.len]u16,
    exact_subset: bool,
};

pub const cases = [_]Case{
    .{ .pattern = "(?:(?:a)(?:b))(?:a)", .oracle = .{ 1, 1, 0, 0 }, .exact_subset = true },
    .{ .pattern = "(?:(?:a)(?:a))(?:a)", .oracle = .{ 3, 0, 0, 0 }, .exact_subset = true },
    .{ .pattern = "(?:(?:a){2,3})(?:a)", .oracle = .{ 3, 0, 0, 0 }, .exact_subset = true },
    .{ .pattern = "(?:(?:[ab])(?:a))(?:a)", .oracle = .{ 2, 0, 0, 0 }, .exact_subset = false },
    .{ .pattern = "(?:(?:a|a))(?:a)", .oracle = .{ 2, 0, 0, 0 }, .exact_subset = true },
    .{ .pattern = "(?:a)(?:a)", .oracle = .{ 2, 0, 0, 0 }, .exact_subset = true },
    .{ .pattern = "(?:(?:a){2,3})(?:(?:))", .oracle = .{ 2, 0, 0, 0 }, .exact_subset = true },
    .{ .pattern = "(?:(?:a){1,2})(?:a)", .oracle = .{ 2, 0, 0, 0 }, .exact_subset = true },
    .{ .pattern = "(?:(?:a)(?:a))(?:b)", .oracle = .{ 2, 0, 0, 0 }, .exact_subset = true },
    .{ .pattern = "(?:(?:a)(?:a))(?:(?:))", .oracle = .{ 2, 0, 0, 0 }, .exact_subset = true },
    .{ .pattern = "(?:(?:(?:))(?:a))(?:a)", .oracle = .{ 2, 0, 0, 0 }, .exact_subset = true },
    .{ .pattern = "(?:a){2,3}", .oracle = .{ 2, 0, 0, 0 }, .exact_subset = true },
    .{ .pattern = "(?:(?:a)(?:(?:)))(?:a)", .oracle = .{ 2, 0, 0, 0 }, .exact_subset = true },
    .{ .pattern = "(?:a|a)", .oracle = .{ 1, 0, 0, 0 }, .exact_subset = true },
    .{ .pattern = "(?:(?:a){1,2}){1,2}", .oracle = .{ 1, 0, 0, 0 }, .exact_subset = true },
    .{ .pattern = "a", .oracle = .{ 1, 0, 0, 0 }, .exact_subset = true },
    .{ .pattern = "(?:(?:[ab])(?:a))(?:(?:))", .oracle = .{ 1, 0, 0, 0 }, .exact_subset = false },
    .{ .pattern = "(?:(?:b)(?:(?:)))(?:a)", .oracle = .{ 1, 0, 0, 0 }, .exact_subset = true },
    .{ .pattern = "(?:[ab])(?:a)", .oracle = .{ 1, 0, 0, 0 }, .exact_subset = false },
    .{ .pattern = "(?:(?:a|a))(?:[ab])", .oracle = .{ 1, 0, 0, 0 }, .exact_subset = false },
    .{ .pattern = "(?:(?:(?:)){0,2})(?:a)", .oracle = .{ 1, 0, 0, 0 }, .exact_subset = true },
    .{ .pattern = "(?:(?:[ab])(?:(?:)))(?:a)", .oracle = .{ 1, 0, 0, 0 }, .exact_subset = false },
    .{ .pattern = "(?:(?:(?:)|[ab]))(?:b)", .oracle = .{ 0, 0, 0, 0 }, .exact_subset = false },
    .{ .pattern = "(?:(?:[ab]|[ab]))(?:(?:))", .oracle = .{ 0, 0, 0, 0 }, .exact_subset = false },
    .{ .pattern = "(?:(?:(?:)){0,1}|a)", .oracle = .{ 0, 0, 0, 0 }, .exact_subset = true },
    .{ .pattern = "(?:(?:b)(?:[ab])|a)", .oracle = .{ 0, 0, 0, 0 }, .exact_subset = false },
    .{ .pattern = "(?:(?:(?:))(?:[ab]))(?:[ab])", .oracle = .{ 0, 0, 0, 0 }, .exact_subset = false },
    .{ .pattern = "(?:(?:[ab])(?:(?:)))(?:(?:))", .oracle = .{ 0, 0, 0, 0 }, .exact_subset = false },
    .{ .pattern = "(?:(?:[ab])(?:a)|[ab])", .oracle = .{ 0, 0, 0, 0 }, .exact_subset = false },
    .{ .pattern = "(?:(?:[ab]|b)|(?:))", .oracle = .{ 0, 0, 0, 0 }, .exact_subset = false },
    .{ .pattern = "(?:(?:(?:))(?:(?:)))(?:[ab])", .oracle = .{ 0, 0, 0, 0 }, .exact_subset = false },
    .{ .pattern = "(?:(?:b)(?:b)|b)", .oracle = .{ 0, 0, 0, 0 }, .exact_subset = true },
};
