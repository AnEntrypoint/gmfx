const std = @import("std");
const http_headers = @import("http_headers.zig");
const wire = @import("wire.zig");
const mrtr = @import("mrtr.zig");

pub const max_ttl_ms: u32 = 24 * 60 * 60 * 1000;

pub const Page = struct {
    tools: []const u8,
    next_cursor: ?[]const u8,
    ttl_ms: u32,
};

pub fn parsePage(result: []const u8) wire.DecodeError!Page {
    var found: [3]?[]const u8 = undefined;
    try wire.objectFields(result, &.{ "tools", "nextCursor", "ttlMs" }, &found);
    const cursor = found[1];
    if (cursor) |c| if (c[0] != '"' and !std.mem.eql(u8, c, "null")) return error.InvalidResult;
    const ttl = wire.decimal(found[2] orelse "0") orelse 0;
    return .{
        .tools = found[0] orelse return error.InvalidResult,
        .next_cursor = if (cursor) |c| (if (c[0] == '"') c else null) else null,
        .ttl_ms = @intCast(@min(ttl, max_ttl_ms)),
    };
}

pub const Tool = struct {
    name: []const u8,
    raw: []const u8,
};

pub const List = struct {
    bytes: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(Span) = .empty,
    slots: std.ArrayList(u32) = .empty,

    const Span = struct { raw_start: u32, raw_len: u32, name_start: u32, name_len: u32 };

    pub fn deinit(list: *List, gpa: std.mem.Allocator) void {
        list.bytes.deinit(gpa);
        list.spans.deinit(gpa);
        list.slots.deinit(gpa);
    }

    pub fn clear(list: *List) void {
        list.bytes.clearRetainingCapacity();
        list.spans.clearRetainingCapacity();
        list.slots.clearRetainingCapacity();
    }

    pub fn len(list: *const List) usize {
        return list.spans.items.len;
    }

    pub fn get(list: *const List, index: usize) Tool {
        const s = list.spans.items[index];
        return .{
            .name = list.bytes.items[s.name_start..][0..s.name_len],
            .raw = list.bytes.items[s.raw_start..][0..s.raw_len],
        };
    }

    pub fn find(list: *const List, name: []const u8) ?Tool {
        const slots = list.slots.items;
        if (slots.len == 0) return null;
        var at = slotFor(name, slots.len);
        while (slots[at] != 0) : (at = (at + 1) & (slots.len - 1)) {
            const tool = list.get(slots[at] - 1);
            if (std.mem.eql(u8, tool.name, name)) return tool;
        }
        return null;
    }

    fn reserve(list: *List, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        const n = list.len() + 1;
        if (n * 2 <= list.slots.items.len) return;
        const size = std.math.ceilPowerOfTwo(usize, @max(16, n * 2)) catch return error.OutOfMemory;
        try list.slots.resize(gpa, size);
        @memset(list.slots.items, 0);
        for (0..list.len()) |i| list.place(i);
    }

    fn place(list: *List, index: usize) void {
        const slots = list.slots.items;
        var at = slotFor(list.get(index).name, slots.len);
        while (slots[at] != 0) at = (at + 1) & (slots.len - 1);
        slots[at] = @intCast(index + 1);
    }

    fn slotFor(name: []const u8, slots: usize) usize {
        return @as(usize, @truncate(std.hash.Wyhash.hash(0, name))) & (slots - 1);
    }
};

pub const Added = struct {
    added: u32 = 0,
    invalid: u32 = 0,
    duplicate: u32 = 0,
    bad_headers: u32 = 0,
    first_bad: ?struct { name: []const u8, reason: http_headers.Invalid } = null,
};

pub const AddError = wire.DecodeError || std.mem.Allocator.Error;

pub const Store = struct {
    current: List = .{},
    gathering: List = .{},
    cursor: std.ArrayList(u8) = .empty,
    has_cursor: bool = false,
    check_headers: bool = false,

    pub fn deinit(store: *Store, gpa: std.mem.Allocator) void {
        store.current.deinit(gpa);
        store.gathering.deinit(gpa);
        store.cursor.deinit(gpa);
    }

    pub fn addPage(store: *Store, gpa: std.mem.Allocator, page: Page) AddError!Added {
        var added: Added = .{};
        var elements: wire.Elements = undefined;
        try elements.init(page.tools);
        while (try elements.next()) |raw| {
            var found: [2]?[]const u8 = undefined;
            wire.objectFields(raw, &.{ "name", "inputSchema" }, &found) catch {
                added.invalid += 1;
                continue;
            };
            const name = wire.plainString(found[0] orelse "") orelse "";
            const schema = found[1] orelse "";
            if (name.len == 0 or schema.len == 0 or schema[0] != '{') {
                added.invalid += 1;
                continue;
            }
            if (store.gathering.find(name) != null) {
                added.duplicate += 1;
                continue;
            }
            if (store.check_headers) {
                var annotations: [http_headers.max_annotations]http_headers.Annotation = undefined;
                if (http_headers.annotations(schema, &annotations)) |_| {} else |reason| {
                    added.bad_headers += 1;
                    if (added.first_bad == null) added.first_bad = .{ .name = name, .reason = reason };
                    continue;
                }
            }
            const list = &store.gathering;
            const start = list.bytes.items.len;
            if (start + raw.len > std.math.maxInt(u32)) return error.OutOfMemory;
            try list.reserve(gpa);
            try list.spans.ensureUnusedCapacity(gpa, 1);
            try list.bytes.appendSlice(gpa, raw);
            const name_offset = @intFromPtr(name.ptr) - @intFromPtr(raw.ptr);
            list.spans.appendAssumeCapacity(.{
                .raw_start = @intCast(start),
                .raw_len = @intCast(raw.len),
                .name_start = @intCast(start + name_offset),
                .name_len = @intCast(name.len),
            });
            list.place(list.len() - 1);
            added.added += 1;
        }
        store.cursor.clearRetainingCapacity();
        store.has_cursor = page.next_cursor != null;
        if (page.next_cursor) |c| try store.cursor.appendSlice(gpa, c);
        return added;
    }

    pub fn nextCursor(store: *const Store) ?[]const u8 {
        return if (store.has_cursor) store.cursor.items else null;
    }

    pub fn discard(store: *Store) void {
        store.gathering.clear();
        store.has_cursor = false;
    }

    pub fn publish(store: *Store) void {
        std.mem.swap(List, &store.current, &store.gathering);
        store.discard();
    }
};

pub fn writeList(out: *std.Io.Writer, id: wire.RequestId, meta: wire.Meta, cursor: ?[]const u8) wire.EncodeError!void {
    var w: wire.Writer = try .request(out, id, "tools/list", meta);
    if (cursor) |c| {
        try w.field("cursor");
        try w.raw(c);
    }
    try w.end();
}

pub fn writeCall(out: *std.Io.Writer, id: wire.RequestId, meta: wire.Meta, name: []const u8, arguments: ?[]const u8, retry: mrtr.Retry) wire.EncodeError!void {
    var w: wire.Writer = try .request(out, id, "tools/call", meta);
    try w.field("name");
    try w.string(name);
    try w.field("arguments");
    try w.raw(arguments orelse "{}");
    try mrtr.writeRetry(&w, retry);
    try w.end();
}

pub const Call = union(enum) {
    result: struct { content: []const u8, structured: ?[]const u8, is_error: bool },
    input_required: []const u8,
    failure: wire.Failure,
    invalid,
};

pub fn classifyCall(body: @FieldType(wire.Response, "body")) Call {
    switch (body) {
        .failure => |failure| return .{ .failure = failure },
        .result => |result| {
            switch (result.kind) {
                .input_required => return .{ .input_required = result.raw },
                .unrecognized => return .invalid,
                .complete => {},
            }
            var found: [3]?[]const u8 = undefined;
            wire.objectFields(result.raw, &.{ "content", "structuredContent", "isError" }, &found) catch return .invalid;
            const content = found[0] orelse return .invalid;
            const is_error = found[2] orelse "false";
            if (content[0] != '[') return .invalid;
            if (!std.mem.eql(u8, is_error, "true") and !std.mem.eql(u8, is_error, "false")) return .invalid;
            return .{ .result = .{ .content = content, .structured = found[1], .is_error = is_error[0] == 't' } };
        },
    }
}

pub fn suggestsChangedList(call: Call) bool {
    return call == .failure and (call.failure.code == wire.code.method_not_found or call.failure.code == wire.code.invalid_params);
}

const testing = std.testing;

test "reads a page: tools, an opaque cursor, and the TTL" {
    const page = try parsePage("{\"tools\":[],\"nextCursor\":\"\",\"ttlMs\":300000}");
    try testing.expectEqualStrings("\"\"", page.next_cursor.?);
    try testing.expectEqual(@as(u32, 300000), page.ttl_ms);
    for ([_][]const u8{ "-5", "1.5", "3e5", "\"60\"", "99999999999999999999999" }) |ttl| {
        var buffer: [96]u8 = undefined;
        const result = try std.mem.print(&buffer, "{{\"tools\":[],\"ttlMs\":{s}}}", .{ttl});
        try testing.expectEqual(@as(u32, 0), (try parsePage(result)).ttl_ms);
    }
    try testing.expectEqual(max_ttl_ms, (try parsePage("{\"tools\":[],\"ttlMs\":999999999999}")).ttl_ms);
    try testing.expectEqual(@as(?[]const u8, null), (try parsePage("{\"tools\":[],\"nextCursor\":null}")).next_cursor);
    try testing.expectError(error.InvalidResult, parsePage("{\"nextCursor\":\"a\"}"));
    try testing.expectError(error.InvalidResult, parsePage("{\"tools\":[],\"nextCursor\":7}"));
}

test "gathers valid tools, skipping malformed ones and later duplicates" {
    var store: Store = .{};
    defer store.deinit(testing.allocator);
    const first = try store.addPage(testing.allocator, try parsePage(
        \\{"tools":[{"name":"a","inputSchema":{"type":"object"}},{"name":"","inputSchema":{}},
        \\{"name":"b"},{"name":"c","inputSchema":null},7,{"name":"\u0064","inputSchema":{}},
        \\{"name":"a","inputSchema":{}},{"name":"d","name":"e","inputSchema":{}}],"nextCursor":"p2"}
    ));
    try testing.expectEqual(Added{ .added = 1, .invalid = 6, .duplicate = 1 }, first);
    try testing.expectEqualStrings("\"p2\"", store.nextCursor().?);
    const second = try store.addPage(testing.allocator, try parsePage("{\"tools\":[{\"description\":\"x\",\"name\":\"b\",\"inputSchema\":{}},{\"name\":\"a\",\"inputSchema\":{}}]}"));
    try testing.expectEqual(Added{ .added = 1, .duplicate = 1 }, second);
    try testing.expectEqual(@as(?[]const u8, null), store.nextCursor());
    try testing.expectEqual(@as(usize, 0), store.current.len());
    store.publish();
    try testing.expectEqual(@as(usize, 2), store.current.len());
    try testing.expectEqual(@as(usize, 0), store.gathering.len());
    try testing.expectEqualStrings("b", store.current.get(1).name);
    try testing.expectEqualStrings("{\"description\":\"x\",\"name\":\"b\",\"inputSchema\":{}}", store.current.find("b").?.raw);
    try testing.expectEqual(@as(?Tool, null), store.current.find("c"));

    _ = try store.addPage(testing.allocator, try parsePage("{\"tools\":[{\"name\":\"z\",\"inputSchema\":{}}],\"nextCursor\":\"q\"}"));
    store.discard();
    try testing.expectEqual(@as(usize, 0), store.gathering.len());
    try testing.expectEqual(@as(?[]const u8, null), store.nextCursor());
    try testing.expectEqual(@as(usize, 2), store.current.len());
    try testing.expectError(error.NotAnArray, store.addPage(testing.allocator, .{ .tools = "{}", .next_cursor = null, .ttl_ms = 0 }));
}

test "a large list over pages: each tool is found as first listed, and a later one of the same name is skipped" {
    const gpa = testing.allocator;
    var store: Store = .{};
    defer store.deinit(gpa);
    var page: std.Io.Writer.Allocating = .init(gpa);
    defer page.deinit();

    for (0..2) |round| {
        for (0..3) |p| {
            page.clearRetainingCapacity();
            try page.writer.writeAll("{\"tools\":[");
            for (0..3000) |i| {
                const n = if (p == 1 and i % 2 == 0) i else p * 3000 + i;
                if (i > 0) try page.writer.writeByte(',');
                try page.writer.print("{{\"name\":\"t{d}\",\"inputSchema\":{{}},\"page\":{d}}}", .{ n, p });
            }
            try page.writer.writeAll("]}");
            const added = try store.addPage(gpa, try parsePage(page.written()));
            try testing.expectEqual(Added{ .added = if (p == 1) 1500 else 3000, .duplicate = if (p == 1) 1500 else 0 }, added);
        }

        if (round == 0) store.discard() else store.publish();
    }
    try testing.expectEqual(@as(usize, 7500), store.current.len());
    var name: [16]u8 = undefined;
    for (0..9000) |n| {
        const tool = store.current.find(try std.mem.print(&name, "t{d}", .{n}));
        if (n >= 3000 and n < 6000 and n % 2 == 0) {
            try testing.expectEqual(@as(?Tool, null), tool);
            continue;
        }
        const first: u8 = if (n < 3000) '0' else if (n < 6000) '1' else '2';
        try testing.expectEqualStrings(&.{ '"', 'p', 'a', 'g', 'e', '"', ':', first, '}' }, tool.?.raw[tool.?.raw.len - 9 ..]);
    }
    try testing.expectEqual(@as(?Tool, null), store.current.find("t9000"));
    try testing.expectEqual(@as(?Tool, null), store.gathering.find("t0"));
}

test "over HTTP, tools with an invalid x-mcp-header are dropped; the others stay" {
    var store: Store = .{ .check_headers = true };
    defer store.deinit(testing.allocator);
    const page = try parsePage(
        \\{"tools":[{"name":"valid_tool","inputSchema":{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"Region"}}}},
        \\{"name":"invalid_space","inputSchema":{"properties":{"v":{"type":"string","x-mcp-header":"My Region"}}}},
        \\{"name":"invalid_object","inputSchema":{"properties":{"d":{"type":"object","x-mcp-header":"Data"}}}}]}
    );
    const added = try store.addPage(testing.allocator, page);
    try testing.expectEqual(@as(u32, 1), added.added);
    try testing.expectEqual(@as(u32, 2), added.bad_headers);
    try testing.expectEqualStrings("invalid_space", added.first_bad.?.name);
    try testing.expectEqual(error.NotToken, added.first_bad.?.reason);

    var stdio: Store = .{};
    defer stdio.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), (try stdio.addPage(testing.allocator, page)).added);
}

test "a page whose memory runs out leaves the store usable" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    var store: Store = .{};
    defer store.deinit(failing.allocator());
    try testing.expectError(error.OutOfMemory, store.addPage(failing.allocator(), try parsePage("{\"tools\":[{\"name\":\"a\",\"inputSchema\":{}},{\"name\":\"b\",\"inputSchema\":{}}]}")));
    store.discard();
    try testing.expectEqual(@as(usize, 0), store.gathering.len());
}

test "writes tools/list and tools/call, cursor sent back unchanged" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeList(&out.writer, 4, .{}, "\"a\\\"b\"");
    try out.writer.writeByte('\n');
    try writeCall(&out.writer, 5, .{}, "get_weather", "{\"location\":\"New York\"}", .{});
    try out.writer.writeByte('\n');
    try writeCall(&out.writer, 6, .{}, "noargs", null, .{});
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/list\",\"params\":{\"cursor\":\"a\\\"b\"}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"get_weather\",\"arguments\":{\"location\":\"New York\"}}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"noargs\",\"arguments\":{}}}",
        out.written(),
    );
}

test "reads tool call answers" {
    const Case = struct { []const u8, std.meta.Tag(Call), bool };
    const cases = [_]Case{
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}", .result, false },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"input_required\",\"inputRequests\":{}}}", .input_required, false },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"task\"}}", .invalid, false },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"structuredContent\":{}}}", .invalid, false },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[],\"isError\":\"yes\"}}", .invalid, false },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"Unknown tool: x\"}}", .failure, true },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}", .failure, true },
        .{ "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32603,\"message\":\"Internal error\"}}", .failure, false },
    };
    for (cases) |case| {
        const call = classifyCall((try wire.decode(case[0])).response.body);
        try testing.expectEqual(case[1], std.meta.activeTag(call));
        try testing.expectEqual(case[2], suggestsChangedList(call));
    }
    const failed = classifyCall((try wire.decode("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[],\"structuredContent\":[1,2],\"isError\":true}}")).response.body);
    try testing.expect(failed.result.is_error);
    try testing.expectEqualStrings("[1,2]", failed.result.structured.?);
}
