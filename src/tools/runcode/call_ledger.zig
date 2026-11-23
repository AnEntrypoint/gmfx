const std = @import("std");
const text_utils = @import("../../core/shared/text_utils.zig");

pub const max_entries = 50;
const max_args_bytes = 120;

const Entry = struct {
    verb: []const u8,
    args: []const u8,
    ok: bool,
    notice: ?[]const u8 = null,
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

pub const InvokeFn = *const fn (context: *anyopaque, alloc: std.mem.Allocator, name: []const u8, args_json: []const u8) anyerror![]u8;

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
        const reply = try self.inner(self.context, alloc, name, args_json);
        errdefer alloc.free(reply);
        try self.record(alloc, name, args_json, reply);
        return reply;
    }

    fn record(self: *Ledger, alloc: std.mem.Allocator, name: []const u8, args_json: []const u8, reply: []const u8) !void {
        if (self.entries.items.len == max_entries) {
            self.dropped += 1;
            return;
        }
        const arena = self.arena.allocator();
        const outcome = try replyOutcome(alloc, arena, reply);
        try self.entries.append(arena, .{
            .verb = try arena.dupe(u8, name),
            .args = try arena.dupe(u8, text_utils.utf8PrefixByBytes(args_json, max_args_bytes)),
            .ok = outcome.ok,
            .notice = outcome.notice,
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

fn testInvoke(_: *anyopaque, alloc: std.mem.Allocator, name: []const u8, _: []const u8) anyerror![]u8 {
    return alloc.dupe(u8, if (std.mem.eql(u8, name, "bad")) "{\"ok\":false,\"error\":\"no\"}" else "{\"ok\":true,\"text\":\"x\"}");
}

fn noticeInvoke(_: *anyopaque, alloc: std.mem.Allocator, _: []const u8, _: []const u8) anyerror![]u8 {
    return alloc.dupe(u8, "{\"ok\":true,\"text\":\"{\\\"exit\\\":0,\\\"notice\\\":\\\"shell snapshot unavailable\\\"}\"}");
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

test "the ledger records each verb call with a bounded args summary and appends it to the report" {
    const alloc = std.testing.allocator;
    var unused: u8 = 0;
    var ledger = Ledger.init(alloc, &unused, testInvoke);
    defer ledger.deinit();
    alloc.free(try Ledger.invoke(&ledger, alloc, "read_file", "{\"path\":\"a\"}"));
    alloc.free(try Ledger.invoke(&ledger, alloc, "bad", "{\"q\":\"" ++ text_utils.repeat("y", 200) ++ "\"}"));
    try std.testing.expectEqual(@as(usize, max_args_bytes), ledger.entries.items[1].args.len);
    for (0..max_entries) |_| alloc.free(try Ledger.invoke(&ledger, alloc, "read_file", "{}"));
    const text = try ledger.report(alloc, try alloc.dupe(u8, "{\"ok\":true,\"value\":1}"));
    defer alloc.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "{\"ok\":true,\"value\":1,\"calls\":[{\"verb\":\"read_file\",\"args\":\"{\\\"path\\\":\\\"a\\\"}\",\"ok\":true},{\"verb\":\"bad\","));
    try std.testing.expect(std.mem.endsWith(u8, text, "],\"calls_dropped\":2}"));
}
