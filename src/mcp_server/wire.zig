const std = @import("std");
const build_options = @import("build_options");
const jsonrpc = @import("../acp/jsonrpc.zig");

pub const latest_version = "2026-07-28";
pub const supported_versions = [_][]const u8{ "2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26" };

pub fn isSupported(version: []const u8) bool {
    for (supported_versions) |supported| {
        if (std.mem.eql(u8, supported, version)) return true;
    }
    return false;
}

fn writeHead(w: *std.Io.Writer, cacheable: bool) !void {
    try w.writeAll("\"resultType\":\"complete\",");
    if (cacheable) try w.writeAll("\"cacheScope\":\"public\",\"ttlMs\":0,");
    try w.writeAll("\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"fx\",\"version\":");
    try jsonrpc.writeJsonStr(build_options.app_version, w);
    try w.writeAll("}},");
}

pub fn writeCacheable(w: *std.Io.Writer, modern: bool) !void {
    if (modern) try writeHead(w, true);
}

pub fn writeComplete(w: *std.Io.Writer, modern: bool) !void {
    if (modern) try writeHead(w, false);
}

test "2026-07-28 is the newest supported version and 2025-11-25 stays supported" {
    try std.testing.expectEqualStrings("2026-07-28", supported_versions[0]);
    try std.testing.expect(isSupported("2025-11-25"));
    try std.testing.expect(!isSupported("1999-01-01"));
}
