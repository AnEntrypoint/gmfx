const std = @import("std");
const content_contract = @import("../../core/tooling/web_fetch_content_contract.zig");
const regex = @import("../../core/shared/regex.zig");
const text_utils = @import("../../core/shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const max_converted_content_bytes = content_contract.max_converted_content_bytes;
pub const Kind = content_contract.Kind;
pub const Classification = content_contract.Classification;

pub fn classify(alloc: Allocator, content_type: ?[]const u8, body: []const u8) !Classification {
    if (content_type) |declared| {
        const normalized = try normalizedMime(alloc, declared);
        errdefer alloc.free(normalized);
        return .{
            .kind = declaredKind(normalized),
            .mime_type = normalized,
            .declared = true,
        };
    }

    if (text_utils.isModelSafeText(body)) {
        return .{
            .kind = .text,
            .mime_type = try alloc.dupe(u8, "text/plain"),
            .declared = false,
        };
    }

    return .{
        .kind = .binary,
        .mime_type = try alloc.dupe(u8, "application/octet-stream"),
        .declared = false,
    };
}

fn normalizedMime(alloc: Allocator, content_type: []const u8) ![]u8 {
    const parameter_start = std.mem.findScalar(u8, content_type, ';') orelse content_type.len;
    const trimmed = std.mem.trim(u8, content_type[0..parameter_start], " \t\r\n");
    if (trimmed.len == 0) return alloc.dupe(u8, "application/octet-stream");

    const normalized = try alloc.alloc(u8, trimmed.len);
    for (trimmed, 0..) |char, index| normalized[index] = std.ascii.toLower(char);
    return normalized;
}

fn declaredKind(mime: []const u8) Kind {
    if (std.mem.eql(u8, mime, "text/html")) return .html;
    if (std.mem.eql(u8, mime, "application/xhtml+xml")) return .html;
    if (std.mem.startsWith(u8, mime, "text/")) return .text;
    if (std.mem.eql(u8, mime, "application/json")) return .text;
    if (std.mem.eql(u8, mime, "application/xml")) return .text;
    if (std.mem.eql(u8, mime, "application/javascript")) return .text;
    if (std.mem.eql(u8, mime, "application/x-javascript")) return .text;
    if (std.mem.startsWith(u8, mime, "application/") and std.mem.endsWith(u8, mime, "+json")) return .text;
    if (std.mem.startsWith(u8, mime, "application/") and std.mem.endsWith(u8, mime, "+xml")) return .text;
    return .binary;
}

pub const LineQuery = struct {
    text: []const u8,
    is_regex: bool = false,
};

pub const FilteredLines = struct {
    text: []u8,
    kept_lines: usize,
    dropped_lines: usize,

    pub fn deinit(self: *FilteredLines, alloc: Allocator) void {
        alloc.free(self.text);
        self.* = undefined;
    }
};

pub fn validateLineQuery(alloc: Allocator, query: LineQuery) regex.CompileError!void {
    if (!query.is_regex) return;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = try regex.compile(arena_state.allocator(), query.text, .{});
}

pub fn filterLines(alloc: Allocator, text: []const u8, query: LineQuery) regex.CompileError!FilteredLines {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var matcher: ?regex.Matcher = if (query.is_regex)
        try regex.Matcher.init(arena_state.allocator(), try regex.compile(arena_state.allocator(), query.text, .{}))
    else
        null;

    var kept: std.ArrayList(u8) = .empty;
    errdefer kept.deinit(alloc);
    var kept_lines: usize = 0;
    var dropped_lines: usize = 0;

    const body = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
    if (body.len == 0) return .{ .text = try kept.toOwnedSlice(alloc), .kept_lines = 0, .dropped_lines = 0 };

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const matched = if (matcher) |*compiled|
            compiled.matches(line)
        else
            std.ascii.findIgnoreCase(line, query.text) != null;
        if (!matched) {
            dropped_lines += 1;
            continue;
        }
        if (kept_lines != 0) try kept.append(alloc, '\n');
        try kept.appendSlice(alloc, line);
        kept_lines += 1;
    }

    return .{
        .text = try kept.toOwnedSlice(alloc),
        .kept_lines = kept_lines,
        .dropped_lines = dropped_lines,
    };
}

test "FetchURL query keeps literal matching lines without case and counts the dropped lines" {
    const alloc = std.testing.allocator;
    const body = "Intro\nVersion 4.2 released\nnothing here\nthe VERSION number\n";

    var filtered = try filterLines(alloc, body, .{ .text = "version" });
    defer filtered.deinit(alloc);

    try std.testing.expectEqualStrings("Version 4.2 released\nthe VERSION number", filtered.text);
    try std.testing.expectEqual(@as(usize, 2), filtered.kept_lines);
    try std.testing.expectEqual(@as(usize, 2), filtered.dropped_lines);
}

test "FetchURL query treats regex characters as plain text unless regex is set" {
    const alloc = std.testing.allocator;
    const body = "price: $4.20 (sale)\nprice: 4x20\nfoo.bar()\nfooXbar()\r\n";

    var literal = try filterLines(alloc, body, .{ .text = "foo.bar()" });
    defer literal.deinit(alloc);
    try std.testing.expectEqualStrings("foo.bar()", literal.text);
    try std.testing.expectEqual(@as(usize, 1), literal.kept_lines);
    try std.testing.expectEqual(@as(usize, 3), literal.dropped_lines);

    var pattern = try filterLines(alloc, body, .{ .text = "^price: [0-9]", .is_regex = true });
    defer pattern.deinit(alloc);
    try std.testing.expectEqualStrings("price: 4x20", pattern.text);
    try std.testing.expectEqual(@as(usize, 1), pattern.kept_lines);
    try std.testing.expectEqual(@as(usize, 3), pattern.dropped_lines);

    var dotted = try filterLines(alloc, body, .{ .text = "foo.bar", .is_regex = true });
    defer dotted.deinit(alloc);
    try std.testing.expectEqualStrings("foo.bar()\nfooXbar()", dotted.text);
    try std.testing.expectEqual(@as(usize, 2), dotted.kept_lines);
    try std.testing.expectEqual(@as(usize, 2), dotted.dropped_lines);
}

test "FetchURL query reports zero kept lines, empty bodies and invalid patterns" {
    const alloc = std.testing.allocator;

    var none = try filterLines(alloc, "alpha\nbeta", .{ .text = "gamma" });
    defer none.deinit(alloc);
    try std.testing.expectEqualStrings("", none.text);
    try std.testing.expectEqual(@as(usize, 0), none.kept_lines);
    try std.testing.expectEqual(@as(usize, 2), none.dropped_lines);

    var empty = try filterLines(alloc, "", .{ .text = "gamma" });
    defer empty.deinit(alloc);
    try std.testing.expectEqualStrings("", empty.text);
    try std.testing.expectEqual(@as(usize, 0), empty.kept_lines);
    try std.testing.expectEqual(@as(usize, 0), empty.dropped_lines);

    var blank_kept = try filterLines(alloc, "a\n\nb\n", .{ .text = "^$", .is_regex = true });
    defer blank_kept.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), blank_kept.kept_lines);
    try std.testing.expectEqual(@as(usize, 2), blank_kept.dropped_lines);

    try std.testing.expectError(error.InvalidPattern, filterLines(alloc, "alpha", .{ .text = "(unclosed", .is_regex = true }));
    try std.testing.expectError(error.InvalidPattern, validateLineQuery(alloc, .{ .text = "(unclosed", .is_regex = true }));
    try validateLineQuery(alloc, .{ .text = "(unclosed" });
    try validateLineQuery(alloc, .{ .text = "a+b", .is_regex = true });
}

test "web_fetch classifies declared mime and missing content type deterministically" {
    const alloc = std.testing.allocator;

    const cases = [_]struct {
        content_type: ?[]const u8,
        body: []const u8 = "hello",
        kind: Kind,
        mime_type: []const u8,
        declared: bool = true,
    }{
        .{ .content_type = "Text/HTML; Charset=UTF-8", .kind = .html, .mime_type = "text/html" },
        .{ .content_type = "TEXT/PLAIN", .kind = .text, .mime_type = "text/plain" },
        .{ .content_type = "application/json; charset=utf-8", .kind = .text, .mime_type = "application/json" },
        .{ .content_type = "application/activity+json", .kind = .text, .mime_type = "application/activity+json" },
        .{ .content_type = "application/xml", .kind = .text, .mime_type = "application/xml" },
        .{ .content_type = "application/rss+xml", .kind = .text, .mime_type = "application/rss+xml" },
        .{ .content_type = "application/javascript", .kind = .text, .mime_type = "application/javascript" },
        .{ .content_type = "application/x-javascript", .kind = .text, .mime_type = "application/x-javascript" },
        .{ .content_type = "application/pdf", .kind = .binary, .mime_type = "application/pdf" },
        .{ .content_type = null, .kind = .text, .mime_type = "text/plain", .declared = false },
        .{ .content_type = null, .body = "bad\x00text", .kind = .binary, .mime_type = "application/octet-stream", .declared = false },
    };

    for (cases) |case| {
        var classification = try classify(alloc, case.content_type, case.body);
        defer classification.deinit(alloc);

        try std.testing.expectEqual(case.kind, classification.kind);
        try std.testing.expectEqualStrings(case.mime_type, classification.mime_type);
        try std.testing.expectEqual(case.declared, classification.declared);
    }
}
