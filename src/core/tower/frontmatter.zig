const std = @import("std");

const Allocator = std.mem.Allocator;
const fence = "---";

pub const Pair = struct {
    key: []const u8,
    value: []const u8,
};

pub const Parsed = struct {
    fields: []const Pair,
    body: []const u8,

    pub fn get(self: Parsed, key: []const u8) ?[]const u8 {
        var index = self.fields.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.fields[index].key, key)) return self.fields[index].value;
        }
        return null;
    }
};

fn isFence(line: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), fence);
}

pub fn render(alloc: Allocator, pairs: []const Pair) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, fence);
    for (pairs) |pair| {
        if (std.mem.indexOfAny(u8, pair.value, "\r\n") != null) return error.MultilineFrontmatterValue;
        try out.append(alloc, '\n');
        try out.appendSlice(alloc, pair.key);
        try out.appendSlice(alloc, ": ");
        try out.appendSlice(alloc, pair.value);
    }
    try out.append(alloc, '\n');
    try out.appendSlice(alloc, fence);
    return out.toOwnedSlice(alloc);
}

pub fn parse(alloc: Allocator, text: []const u8) !Parsed {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse return .{ .fields = &.{}, .body = text };
    if (!isFence(first)) return .{ .fields = &.{}, .body = text };
    var pairs: std.ArrayList(Pair) = .empty;
    errdefer pairs.deinit(alloc);
    var offset = first.len + 1;
    while (lines.next()) |raw_line| {
        offset += raw_line.len + 1;
        if (isFence(raw_line)) {
            return .{
                .fields = try pairs.toOwnedSlice(alloc),
                .body = std.mem.trim(u8, text[@min(offset, text.len)..], " \t\r\n"),
            };
        }
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (separator == 0) continue;
        try pairs.append(alloc, .{
            .key = std.mem.trim(u8, line[0..separator], " \t\r"),
            .value = std.mem.trim(u8, line[separator + 1 ..], " \t\r"),
        });
    }
    pairs.deinit(alloc);
    return .{ .fields = &.{}, .body = text };
}

test "Tower frontmatter renders single-line fields between fences" {
    const alloc = std.testing.allocator;
    const rendered = try render(alloc, &.{
        .{ .key = "id", .value = "m1" },
        .{ .key = "status", .value = "active" },
    });
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings("---\nid: m1\nstatus: active\n---", rendered);
}

test "Tower frontmatter refuses a multi-line value" {
    try std.testing.expectError(error.MultilineFrontmatterValue, render(std.testing.allocator, &.{.{ .key = "note", .value = "a\nb" }}));
}

test "Tower frontmatter parses fields and the trimmed body" {
    const alloc = std.testing.allocator;
    const parsed = try parse(alloc, "---\r\nid: m1\r\nstatus: active\r\n---\r\n\r\nBody line\n");
    defer alloc.free(parsed.fields);
    try std.testing.expectEqualStrings("m1", parsed.get("id").?);
    try std.testing.expectEqualStrings("active", parsed.get("status").?);
    try std.testing.expectEqualStrings("Body line", parsed.body);
}

test "Tower frontmatter treats text without a closed fence as body" {
    const alloc = std.testing.allocator;
    const text = "plain text\nid: x";
    const parsed = try parse(alloc, text);
    try std.testing.expectEqual(@as(usize, 0), parsed.fields.len);
    try std.testing.expectEqualStrings(text, parsed.body);
}
