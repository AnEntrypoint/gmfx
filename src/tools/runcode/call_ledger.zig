const std = @import("std");
const text_utils = @import("../../core/shared/text_utils.zig");

pub const max_entries = 50;
const max_args_bytes = 120;
const max_whole_value_bytes = 4096;

const Entry = struct {
    verb: []const u8,
    args: []const u8,
    ok: bool,
    notice: ?[]const u8 = null,
    additions: ?u32 = null,
    deletions: ?u32 = null,
};

pub const Invoked = struct {
    reply: []u8,
    additions: u32 = 0,
    deletions: u32 = 0,
};

const Reply = struct {
    ok: bool = false,
    text: ?[]const u8 = null,
};

const Body = struct {
    notice: ?[]const u8 = null,
};

const Outcome = struct {
    ok: bool = false,
    notice: ?[]const u8 = null,
};

pub const InvokeFn = *const fn (context: *anyopaque, alloc: std.mem.Allocator, name: []const u8, args_json: []const u8) anyerror!Invoked;

pub const Ledger = struct {
    arena: std.heap.ArenaAllocator,
    context: *anyopaque,
    inner: InvokeFn,
    entries: std.ArrayList(Entry) = .empty,
    dropped: usize = 0,

    pub fn init(alloc: std.mem.Allocator, context: *anyopaque, inner: InvokeFn) Ledger {
        return .{ .arena = .init(alloc), .context = context, .inner = inner };
    }

    pub fn deinit(self: *Ledger) void {
        self.arena.deinit();
    }

    pub fn invoke(context: *anyopaque, alloc: std.mem.Allocator, name: []const u8, args_json: []const u8) anyerror![]u8 {
        const self: *Ledger = @ptrCast(@alignCast(context));
        const invoked = try self.inner(self.context, alloc, name, args_json);
        errdefer alloc.free(invoked.reply);
        try self.record(alloc, name, args_json, invoked);
        return invoked.reply;
    }

    fn record(self: *Ledger, alloc: std.mem.Allocator, name: []const u8, args_json: []const u8, invoked: Invoked) !void {
        if (self.entries.items.len == max_entries) {
            self.dropped += 1;
            return;
        }
        const arena = self.arena.allocator();
        const outcome = try replyOutcome(alloc, arena, invoked.reply);
        try self.entries.append(arena, .{
            .verb = try arena.dupe(u8, name),
            .args = try compactArgs(alloc, arena, args_json),
            .ok = outcome.ok,
            .notice = outcome.notice,
            .additions = if (invoked.additions > 0) invoked.additions else null,
            .deletions = if (invoked.deletions > 0) invoked.deletions else null,
        });
    }

    pub fn report(self: *const Ledger, alloc: std.mem.Allocator, base: []u8) ![]u8 {
        defer alloc.free(base);
        const shown = try alloc.dupe(Entry, self.entries.items);
        defer alloc.free(shown);
        for (shown) |*entry| {
            const notice = entry.notice orelse continue;
            if (std.mem.indexOf(u8, base, notice) != null) entry.notice = null;
        }
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeAll(base[0 .. base.len - 1]);
        try out.writer.writeAll(",\"calls\":");
        try std.json.Stringify.value(shown, .{ .emit_null_optional_fields = false }, &out.writer);
        try out.writer.print(",\"calls_dropped\":{d}}}", .{self.dropped});
        return out.toOwnedSlice();
    }
};

fn compactArgs(alloc: std.mem.Allocator, arena: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json, .{}) catch return arena.dupe(u8, text_utils.utf8PrefixByBytes(args_json, max_args_bytes));
    defer parsed.deinit();
    if (parsed.value != .object) return arena.dupe(u8, text_utils.utf8PrefixByBytes(args_json, max_args_bytes));
    var out: std.Io.Writer.Allocating = .init(arena);
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.beginObject();
    var fields = parsed.value.object.iterator();
    while (fields.next()) |field| {
        switch (field.value_ptr.*) {
            .string => |text| {
                try json.objectField(field.key_ptr.*);
                const limit: usize = if (std.mem.eql(u8, field.key_ptr.*, "path") or std.mem.eql(u8, field.key_ptr.*, "command")) max_whole_value_bytes else max_args_bytes;
                try json.write(text_utils.utf8PrefixByBytes(text, limit));
            },
            .integer, .float, .bool => {
                try json.objectField(field.key_ptr.*);
                try json.write(field.value_ptr.*);
            },
            else => {},
        }
    }
    try json.endObject();
    return out.written();
}

fn replyOutcome(alloc: std.mem.Allocator, arena: std.mem.Allocator, reply: []const u8) !Outcome {
    const parsed = std.json.parseFromSlice(Reply, alloc, reply, .{ .ignore_unknown_fields = true }) catch return .{};
    defer parsed.deinit();
    const text = parsed.value.text orelse return .{ .ok = parsed.value.ok };
    const body = std.json.parseFromSlice(Body, alloc, text, .{ .ignore_unknown_fields = true }) catch return .{ .ok = parsed.value.ok };
    defer body.deinit();
    return .{
        .ok = parsed.value.ok,
        .notice = if (body.value.notice) |notice| try arena.dupe(u8, notice) else null,
    };
}

fn testInvoke(_: *anyopaque, alloc: std.mem.Allocator, name: []const u8, _: []const u8) anyerror!Invoked {
    return .{ .reply = try alloc.dupe(u8, if (std.mem.eql(u8, name, "bad")) "{\"ok\":false,\"error\":\"no\"}" else "{\"ok\":true,\"text\":\"x\"}") };
}

fn diffInvoke(_: *anyopaque, alloc: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!Invoked {
    return .{ .reply = try alloc.dupe(u8, "{\"ok\":true,\"text\":\"x\"}"), .additions = 3 };
}

fn noticeInvoke(_: *anyopaque, alloc: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!Invoked {
    return .{ .reply = try alloc.dupe(u8, "{\"ok\":true,\"text\":\"{\\\"exit\\\":0,\\\"notice\\\":\\\"shell snapshot unavailable\\\"}\"}") };
}

test "the ledger carries a notice found in a verb's result body into the report" {
    const alloc = std.testing.allocator;
    var unused: u8 = 0;
    var ledger = Ledger.init(alloc, &unused, noticeInvoke);
    defer ledger.deinit();
    alloc.free(try Ledger.invoke(&ledger, alloc, "Bash", "{}"));
    try std.testing.expectEqualStrings("shell snapshot unavailable", ledger.entries.items[0].notice.?);
    const text = try ledger.report(alloc, try alloc.dupe(u8, "{\"ok\":true}"));
    defer alloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"notice\":\"shell snapshot unavailable\"") != null);
}

test "the ledger leaves out a notice the result value already carries" {
    const alloc = std.testing.allocator;
    var unused: u8 = 0;
    var ledger = Ledger.init(alloc, &unused, noticeInvoke);
    defer ledger.deinit();
    alloc.free(try Ledger.invoke(&ledger, alloc, "Bash", "{}"));
    const text = try ledger.report(alloc, try alloc.dupe(u8, "{\"ok\":true,\"value\":\"shell snapshot unavailable\"}"));
    defer alloc.free(text);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "shell snapshot unavailable"));
}

test "the ledger keeps a write's args parseable and carries its diff counts into the report" {
    const alloc = std.testing.allocator;
    var unused: u8 = 0;
    var ledger = Ledger.init(alloc, &unused, diffInvoke);
    defer ledger.deinit();
    alloc.free(try Ledger.invoke(&ledger, alloc, "write_file", "{\"path\":\"a.txt\",\"content\":\"" ++ text_utils.repeat("z", 400) ++ "\",\"nested\":{\"k\":1}}"));
    const entry = ledger.entries.items[0];
    try std.testing.expectEqual(@as(?u32, 3), entry.additions);
    try std.testing.expectEqual(@as(?u32, null), entry.deletions);
    const parsed = try std.json.parseFromSlice(struct { path: []const u8, content: []const u8 }, alloc, entry.args, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a.txt", parsed.value.path);
    try std.testing.expectEqual(@as(usize, max_args_bytes), parsed.value.content.len);
    try std.testing.expect(std.mem.find(u8, entry.args, "nested") == null);
}

test "the ledger keeps a long path whole" {
    const alloc = std.testing.allocator;
    var unused: u8 = 0;
    var ledger = Ledger.init(alloc, &unused, testInvoke);
    defer ledger.deinit();
    const path = text_utils.repeat("p", max_args_bytes * 2);
    alloc.free(try Ledger.invoke(&ledger, alloc, "read_file", "{\"path\":\"" ++ path ++ "\"}"));
    try std.testing.expectEqualStrings("{\"path\":\"" ++ path ++ "\"}", ledger.entries.items[0].args);
}

test "the ledger keeps a long command whole" {
    const alloc = std.testing.allocator;
    var unused: u8 = 0;
    var ledger = Ledger.init(alloc, &unused, testInvoke);
    defer ledger.deinit();
    const command = text_utils.repeat("c", max_args_bytes * 2);
    alloc.free(try Ledger.invoke(&ledger, alloc, "Bash", "{\"command\":\"" ++ command ++ "\"}"));
    try std.testing.expectEqualStrings("{\"command\":\"" ++ command ++ "\"}", ledger.entries.items[0].args);
}

test "the ledger records each verb call with a bounded args summary and appends it to the report" {
    const alloc = std.testing.allocator;
    var unused: u8 = 0;
    var ledger = Ledger.init(alloc, &unused, testInvoke);
    defer ledger.deinit();
    alloc.free(try Ledger.invoke(&ledger, alloc, "read_file", "{\"path\":\"a\"}"));
    alloc.free(try Ledger.invoke(&ledger, alloc, "bad", "{\"q\":\"" ++ text_utils.repeat("y", 200) ++ "\"}"));
    try std.testing.expectEqualStrings("{\"q\":\"" ++ text_utils.repeat("y", max_args_bytes) ++ "\"}", ledger.entries.items[1].args);
    for (0..max_entries) |_| alloc.free(try Ledger.invoke(&ledger, alloc, "read_file", "{}"));
    const text = try ledger.report(alloc, try alloc.dupe(u8, "{\"ok\":true,\"value\":1}"));
    defer alloc.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "{\"ok\":true,\"value\":1,\"calls\":[{\"verb\":\"read_file\",\"args\":\"{\\\"path\\\":\\\"a\\\"}\",\"ok\":true},{\"verb\":\"bad\","));
    try std.testing.expect(std.mem.endsWith(u8, text, "],\"calls_dropped\":2}"));
}
