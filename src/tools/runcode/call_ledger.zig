const std = @import("std");
const text_utils = @import("../../core/shared/text_utils.zig");
const result_store = @import("../../core/session/result_store.zig");

pub const max_entries = 50;
pub const max_inline_output_bytes = 8 * 1024;
const max_args_bytes = 120;
const max_whole_value_bytes = 4096;

const Entry = struct {
    verb: []const u8,
    args: []const u8,
    ok: bool,
    notice: ?[]const u8 = null,
    deferred: ?bool = null,
    additions: ?u32 = null,
    deletions: ?u32 = null,
    output: ?[]const u8 = null,
    output_handle: ?[]const u8 = null,
    output_bytes: ?usize = null,
};

pub const Invoked = struct {
    reply: []u8,
    additions: u32 = 0,
    deletions: u32 = 0,
    output: ?[]u8 = null,
    output_handle: ?[]u8 = null,
    output_bytes: usize = 0,
    notice_pushed: bool = false,

    fn releaseOutput(self: Invoked, alloc: std.mem.Allocator) void {
        if (self.output) |text| alloc.free(text);
        if (self.output_handle) |handle| alloc.free(handle);
    }
};

pub const Store = struct {
    context: *anyopaque,
    write: *const fn (context: *anyopaque, alloc: std.mem.Allocator, name: []const u8, text: []const u8) anyerror!?[]u8,
};

pub const PointerReader = struct {
    context: *anyopaque,
    read: *const fn (context: *anyopaque, alloc: std.mem.Allocator, handle: []const u8, bytes: usize) anyerror![]u8,
};

const Reply = struct {
    ok: bool = false,
    text: ?[]const u8 = null,
    deferred: bool = false,
};

const Body = struct {
    notice: ?[]const u8 = null,
};

const Outcome = struct {
    ok: bool = false,
    notice: ?[]const u8 = null,
    deferred: bool = false,
};

pub const InvokeFn = *const fn (context: *anyopaque, alloc: std.mem.Allocator, name: []const u8, args_json: []const u8) anyerror!Invoked;

const Substitution = struct {
    body: []const u8,
    pointer: []const u8,
};

pub const Ledger = struct {
    arena: std.heap.ArenaAllocator,
    context: *anyopaque,
    inner: InvokeFn,
    store: ?Store,
    entries: std.ArrayList(Entry) = .empty,
    dropped: usize = 0,
    substitutions: std.ArrayList(Substitution) = .empty,

    pub fn init(alloc: std.mem.Allocator, context: *anyopaque, inner: InvokeFn, store: ?Store) Ledger {
        return .{ .arena = .init(alloc), .context = context, .inner = inner, .store = store };
    }

    pub fn deinit(self: *Ledger) void {
        self.arena.deinit();
    }

    pub fn invoke(context: *anyopaque, alloc: std.mem.Allocator, name: []const u8, args_json: []const u8) anyerror![]u8 {
        const self: *Ledger = @ptrCast(@alignCast(context));
        const invoked = try self.inner(self.context, alloc, name, args_json);
        errdefer alloc.free(invoked.reply);
        defer invoked.releaseOutput(alloc);
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
        const saved = try self.saveOutput(alloc, arena, name, invoked);
        if (saved.handle) |handle| {
            if (saved.output == null) try self.recordSubstitution(alloc, arena, invoked.reply, handle);
        }
        try self.entries.append(arena, .{
            .verb = try arena.dupe(u8, name),
            .args = try compactArgs(alloc, arena, args_json),
            .ok = outcome.ok,
            .notice = if (invoked.notice_pushed) null else outcome.notice,
            .deferred = if (outcome.deferred) true else null,
            .additions = if (invoked.additions > 0) invoked.additions else null,
            .deletions = if (invoked.deletions > 0) invoked.deletions else null,
            .output = saved.output,
            .output_handle = saved.handle,
            .output_bytes = saved.bytes,
        });
    }

    const Saved = struct {
        output: ?[]const u8 = null,
        handle: ?[]const u8 = null,
        bytes: ?usize = null,
    };

    fn saveOutput(self: *Ledger, alloc: std.mem.Allocator, arena: std.mem.Allocator, name: []const u8, invoked: Invoked) !Saved {
        if (invoked.output_handle) |handle| return .{ .handle = try arena.dupe(u8, handle), .bytes = invoked.output_bytes };
        const text = invoked.output orelse return .{};
        if (text.len <= max_inline_output_bytes) return .{ .output = try arena.dupe(u8, text) };
        const store = self.store orelse return .{};
        const handle = (try store.write(store.context, alloc, name, text)) orelse return .{};
        defer alloc.free(handle);
        return .{ .handle = try arena.dupe(u8, handle), .bytes = text.len };
    }

    fn recordSubstitution(self: *Ledger, alloc: std.mem.Allocator, arena: std.mem.Allocator, reply: []const u8, handle: []const u8) !void {
        const parsed = std.json.parseFromSlice(Reply, alloc, reply, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const body = parsed.value.text orelse return;
        if (body.len <= max_inline_output_bytes) return;
        const preview = try result_store.previewText(arena, body, result_store.preview_bytes);
        const pointer = try result_store.formatStoredResultOutput(arena, handle, preview, body.len);
        try self.substitutions.append(arena, .{
            .body = try jsonContent(arena, body),
            .pointer = try jsonContent(arena, pointer),
        });
    }

    fn substituteStoredBodies(self: *const Ledger, alloc: std.mem.Allocator, text: []const u8) ![]u8 {
        var current = try alloc.dupe(u8, text);
        errdefer alloc.free(current);
        for (self.substitutions.items) |sub| {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            var rest = current;
            var replaced = false;
            while (std.mem.indexOf(u8, rest, sub.body)) |at| {
                try out.writer.writeAll(rest[0..at]);
                try out.writer.writeAll(sub.pointer);
                rest = rest[at + sub.body.len ..];
                replaced = true;
            }
            if (!replaced) continue;
            try out.writer.writeAll(rest);
            alloc.free(current);
            current = try out.toOwnedSlice();
        }
        return current;
    }

    pub fn report(self: *const Ledger, alloc: std.mem.Allocator, base: []u8) ![]u8 {
        defer alloc.free(base);
        const shown = try alloc.dupe(Entry, self.entries.items);
        defer alloc.free(shown);
        for (shown) |*entry| {
            const notice = entry.notice orelse continue;
            if (std.mem.indexOf(u8, base, notice) != null) entry.notice = null;
        }
        const substituted = try self.substituteStoredBodies(alloc, base);
        defer alloc.free(substituted);
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeAll(substituted[0 .. substituted.len - 1]);
        try out.writer.writeAll(",\"calls\":");
        try std.json.Stringify.value(shown, .{ .emit_null_optional_fields = false }, &out.writer);
        try out.writer.print(",\"calls_dropped\":{d}}}", .{self.dropped});
        return out.toOwnedSlice();
    }
};

pub fn resolveOutput(alloc: std.mem.Allocator, output: ?[]const u8, handle: ?[]const u8, bytes: ?usize, reader: PointerReader) !?[]u8 {
    if (output) |text| return try alloc.dupe(u8, text);
    const pointer = handle orelse return null;
    const total = bytes orelse return error.MalformedCallOutput;
    return try reader.read(reader.context, alloc, pointer, total);
}

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
    const text = parsed.value.text orelse return .{ .ok = parsed.value.ok, .deferred = parsed.value.deferred };
    const body = std.json.parseFromSlice(Body, alloc, text, .{ .ignore_unknown_fields = true }) catch return .{ .ok = parsed.value.ok, .deferred = parsed.value.deferred };
    defer body.deinit();
    return .{
        .ok = parsed.value.ok,
        .notice = if (body.value.notice) |notice| try arena.dupe(u8, notice) else null,
        .deferred = parsed.value.deferred,
    };
}

fn jsonContent(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try std.json.Stringify.value(text, .{}, &out.writer);
    const quoted = try out.toOwnedSlice();
    return quoted[1 .. quoted.len - 1];
}

const Canned = struct {
    output: []const u8 = "",
    handle: ?[]const u8 = null,
    handle_bytes: usize = 0,
};

fn cannedInvoke(context: *anyopaque, alloc: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!Invoked {
    const canned: *Canned = @ptrCast(@alignCast(context));
    return .{
        .reply = try alloc.dupe(u8, "{\"ok\":true,\"text\":\"x\"}"),
        .output = if (canned.handle == null) try alloc.dupe(u8, canned.output) else null,
        .output_handle = if (canned.handle) |handle| try alloc.dupe(u8, handle) else null,
        .output_bytes = canned.handle_bytes,
    };
}

const FakeStore = struct {
    calls: usize = 0,

    fn write(context: *anyopaque, alloc: std.mem.Allocator, name: []const u8, text: []const u8) anyerror!?[]u8 {
        const self: *FakeStore = @ptrCast(@alignCast(context));
        self.calls += 1;
        return try std.fmt.allocPrint(alloc, "result-{s}-{d}.txt", .{ name, text.len });
    }

    fn store(self: *FakeStore) Store {
        return .{ .context = self, .write = write };
    }
};

const Reader = struct {
    calls: usize = 0,

    fn read(context: *anyopaque, alloc: std.mem.Allocator, handle: []const u8, bytes: usize) anyerror![]u8 {
        const self: *Reader = @ptrCast(@alignCast(context));
        self.calls += 1;
        return std.fmt.allocPrint(alloc, "{s}:{d}", .{ handle, bytes });
    }
};

const big_output = text_utils.repeat("o", max_inline_output_bytes + 1);

test "an output within the cap is kept inline and survives the report round trip" {
    const alloc = std.testing.allocator;
    var canned: Canned = .{ .output = "line one\nline two" };
    var fake: FakeStore = .{};
    var ledger = Ledger.init(alloc, &canned, cannedInvoke, fake.store());
    defer ledger.deinit();
    alloc.free(try Ledger.invoke(&ledger, alloc, "read_file", "{\"path\":\"a\"}"));
    try std.testing.expectEqualStrings("line one\nline two", ledger.entries.items[0].output.?);
    try std.testing.expect(ledger.entries.items[0].output_handle == null);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    const text = try ledger.report(alloc, try alloc.dupe(u8, "{\"ok\":true}"));
    defer alloc.free(text);
    const Replay = struct {
        calls: []const struct {
            output: ?[]const u8 = null,
            output_handle: ?[]const u8 = null,
            output_bytes: ?usize = null,
        },
    };
    const parsed = try std.json.parseFromSlice(Replay, alloc, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("line one\nline two", parsed.value.calls[0].output.?);
    try std.testing.expect(parsed.value.calls[0].output_handle == null);
}

test "an output past the cap is kept as a pointer with its byte count and no inline part" {
    const alloc = std.testing.allocator;
    var canned: Canned = .{ .output = big_output };
    var fake: FakeStore = .{};
    var ledger = Ledger.init(alloc, &canned, cannedInvoke, fake.store());
    defer ledger.deinit();
    alloc.free(try Ledger.invoke(&ledger, alloc, "read_file", "{}"));
    const entry = ledger.entries.items[0];
    try std.testing.expect(entry.output == null);
    try std.testing.expectEqualStrings("result-read_file-8193.txt", entry.output_handle.?);
    try std.testing.expectEqual(@as(?usize, big_output.len), entry.output_bytes);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    const text = try ledger.report(alloc, try alloc.dupe(u8, "{\"ok\":true}"));
    defer alloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"output_handle\":\"result-read_file-8193.txt\",\"output_bytes\":8193") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"output\":") == null);
}

test "a verb whose own result is already stored is pointed at that handle without storing again" {
    const alloc = std.testing.allocator;
    var canned: Canned = .{ .output = "preview", .handle = "result-inner.txt", .handle_bytes = 40000 };
    var fake: FakeStore = .{};
    var ledger = Ledger.init(alloc, &canned, cannedInvoke, fake.store());
    defer ledger.deinit();
    alloc.free(try Ledger.invoke(&ledger, alloc, "read_file", "{}"));
    const entry = ledger.entries.items[0];
    try std.testing.expect(entry.output == null);
    try std.testing.expectEqualStrings("result-inner.txt", entry.output_handle.?);
    try std.testing.expectEqual(@as(?usize, 40000), entry.output_bytes);
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "the ledger keeps max_entries entries and stores output only for the entries it keeps" {
    const alloc = std.testing.allocator;
    var canned: Canned = .{ .output = big_output };
    var fake: FakeStore = .{};
    var ledger = Ledger.init(alloc, &canned, cannedInvoke, fake.store());
    defer ledger.deinit();
    for (0..max_entries + 10) |_| alloc.free(try Ledger.invoke(&ledger, alloc, "read_file", "{}"));
    try std.testing.expectEqual(@as(usize, max_entries), ledger.entries.items.len);
    try std.testing.expectEqual(@as(usize, 10), ledger.dropped);
    try std.testing.expectEqual(@as(usize, max_entries), fake.calls);
}

test "resolveOutput returns inline output without reading and reads a pointer with its byte count" {
    const alloc = std.testing.allocator;
    var reader: Reader = .{};
    const source: PointerReader = .{ .context = &reader, .read = Reader.read };
    const inline_text = (try resolveOutput(alloc, "hello", null, null, source)).?;
    defer alloc.free(inline_text);
    try std.testing.expectEqualStrings("hello", inline_text);
    try std.testing.expectEqual(@as(usize, 0), reader.calls);
    const stored = (try resolveOutput(alloc, null, "result-a.txt", 9000, source)).?;
    defer alloc.free(stored);
    try std.testing.expectEqualStrings("result-a.txt:9000", stored);
    try std.testing.expectEqual(@as(usize, 1), reader.calls);
    try std.testing.expect((try resolveOutput(alloc, null, null, null, source)) == null);
    try std.testing.expectEqual(@as(usize, 1), reader.calls);
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

fn deferredInvoke(_: *anyopaque, alloc: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!Invoked {
    return .{ .reply = try alloc.dupe(u8, "{\"ok\":false,\"deferred\":true,\"error\":\"Scoped project instructions\"}") };
}

test "the ledger marks a context-deferred verb reply as deferred rather than failed" {
    const alloc = std.testing.allocator;
    var unused: u8 = 0;
    var ledger = Ledger.init(alloc, &unused, deferredInvoke, null);
    defer ledger.deinit();
    alloc.free(try Ledger.invoke(&ledger, alloc, "Bash", "{}"));
    try std.testing.expectEqual(@as(?bool, true), ledger.entries.items[0].deferred);
    try std.testing.expect(!ledger.entries.items[0].ok);
    const text = try ledger.report(alloc, try alloc.dupe(u8, "{\"ok\":true}"));
    defer alloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"deferred\":true") != null);
}

fn bodyInvoke(context: *anyopaque, alloc: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!Invoked {
    const body: *const []const u8 = @ptrCast(@alignCast(context));
    var reply: std.Io.Writer.Allocating = .init(alloc);
    defer reply.deinit();
    try reply.writer.writeAll("{\"ok\":true,\"text\":");
    try std.json.Stringify.value(body.*, .{}, &reply.writer);
    try reply.writer.writeByte('}');
    return .{ .reply = try reply.toOwnedSlice(), .output = try alloc.dupe(u8, body.*) };
}

test "a stored verb body the script returns is replaced by its pointer in the report" {
    const alloc = std.testing.allocator;
    var body: []const u8 = big_output;
    var fake: FakeStore = .{};
    var ledger = Ledger.init(alloc, &body, bodyInvoke, fake.store());
    defer ledger.deinit();
    alloc.free(try Ledger.invoke(&ledger, alloc, "read_file", "{}"));
    var value_json: std.Io.Writer.Allocating = .init(alloc);
    try std.json.Stringify.value(big_output, .{}, &value_json.writer);
    const encoded = try value_json.toOwnedSlice();
    defer alloc.free(encoded);
    const base = try std.fmt.allocPrint(alloc, "{{\"ok\":true,\"value\":{s}}}", .{encoded});
    const text = try ledger.report(alloc, base);
    defer alloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, big_output) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "handle=\\\"result-read_file-8193.txt\\\" stored_bytes=\\\"8193\\\"") != null);
}

test "the ledger carries a notice found in a verb's result body into the report" {
    const alloc = std.testing.allocator;
    var unused: u8 = 0;
    var ledger = Ledger.init(alloc, &unused, noticeInvoke, null);
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
    var ledger = Ledger.init(alloc, &unused, noticeInvoke, null);
    defer ledger.deinit();
    alloc.free(try Ledger.invoke(&ledger, alloc, "Bash", "{}"));
    const text = try ledger.report(alloc, try alloc.dupe(u8, "{\"ok\":true,\"value\":\"shell snapshot unavailable\"}"));
    defer alloc.free(text);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "shell snapshot unavailable"));
}

fn pushedNoticeInvoke(ctx: *anyopaque, alloc: std.mem.Allocator, name: []const u8, args_json: []const u8) anyerror!Invoked {
    var invoked = try noticeInvoke(ctx, alloc, name, args_json);
    invoked.notice_pushed = true;
    return invoked;
}

test "the ledger leaves out a notice already pushed as context" {
    const alloc = std.testing.allocator;
    var unused: u8 = 0;
    var ledger = Ledger.init(alloc, &unused, pushedNoticeInvoke, null);
    defer ledger.deinit();
    alloc.free(try Ledger.invoke(&ledger, alloc, "Bash", "{}"));
    try std.testing.expect(ledger.entries.items[0].notice == null);
    const text = try ledger.report(alloc, try alloc.dupe(u8, "{\"ok\":true}"));
    defer alloc.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "shell snapshot unavailable") == null);
}

test "the ledger keeps a write's args parseable and carries its diff counts into the report" {
    const alloc = std.testing.allocator;
    var unused: u8 = 0;
    var ledger = Ledger.init(alloc, &unused, diffInvoke, null);
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
    var ledger = Ledger.init(alloc, &unused, testInvoke, null);
    defer ledger.deinit();
    const path = text_utils.repeat("p", max_args_bytes * 2);
    alloc.free(try Ledger.invoke(&ledger, alloc, "read_file", "{\"path\":\"" ++ path ++ "\"}"));
    try std.testing.expectEqualStrings("{\"path\":\"" ++ path ++ "\"}", ledger.entries.items[0].args);
}

test "the ledger keeps a long command whole" {
    const alloc = std.testing.allocator;
    var unused: u8 = 0;
    var ledger = Ledger.init(alloc, &unused, testInvoke, null);
    defer ledger.deinit();
    const command = text_utils.repeat("c", max_args_bytes * 2);
    alloc.free(try Ledger.invoke(&ledger, alloc, "Bash", "{\"command\":\"" ++ command ++ "\"}"));
    try std.testing.expectEqualStrings("{\"command\":\"" ++ command ++ "\"}", ledger.entries.items[0].args);
}

test "the ledger records each verb call with a bounded args summary and appends it to the report" {
    const alloc = std.testing.allocator;
    var unused: u8 = 0;
    var ledger = Ledger.init(alloc, &unused, testInvoke, null);
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
