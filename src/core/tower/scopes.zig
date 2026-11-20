const std = @import("std");

pub fn scopeStem(raw: []const u8) []const u8 {
    var stem = raw;
    if (std.mem.endsWith(u8, stem, "/**")) {
        stem = stem[0 .. stem.len - 3];
    } else if (std.mem.endsWith(u8, stem, "/*")) {
        stem = stem[0 .. stem.len - 2];
    }
    stem = std.mem.trimEnd(u8, stem, "/");
    return std.mem.trimEnd(u8, stem, "*");
}

pub fn stemsOverlap(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (std.mem.startsWith(u8, a, b) and a.len > b.len and a[b.len] == '/') return true;
    return std.mem.startsWith(u8, b, a) and b.len > a.len and b[a.len] == '/';
}

pub fn scopesOverlap(a: []const []const u8, b: []const []const u8) bool {
    for (a) |raw_a| {
        const stem_a = scopeStem(raw_a);
        if (stem_a.len == 0) continue;
        for (b) |raw_b| {
            const stem_b = scopeStem(raw_b);
            if (stem_b.len == 0) continue;
            if (stemsOverlap(stem_a, stem_b)) return true;
        }
    }
    return false;
}

test "Tower scopes strip glob suffixes to a stem" {
    try std.testing.expectEqualStrings("src/core", scopeStem("src/core/**"));
    try std.testing.expectEqualStrings("src/core", scopeStem("src/core/*"));
    try std.testing.expectEqualStrings("src/core", scopeStem("src/core/"));
    try std.testing.expectEqualStrings("", scopeStem("**"));
}

test "Tower scopes overlap on equal stems and on directory prefixes only" {
    try std.testing.expect(scopesOverlap(&.{"src/core/**"}, &.{"src/core/tower"}));
    try std.testing.expect(scopesOverlap(&.{"src"}, &.{"src/core"}));
    try std.testing.expect(!scopesOverlap(&.{"src/core"}, &.{"src/coreutils"}));
    try std.testing.expect(!scopesOverlap(&.{"**"}, &.{"src"}));
}
