const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const Allocator = std.mem.Allocator;

const characters = [_][]const u8{ "a", "Z", "0", " ", "\n", "\t", "\"", "\\", "/", "{", "\u{e9}", "\u{4e2d}", "\u{1f600}" };

pub const Text = struct {
    text: std.ArrayList(u8) = .empty,
    cuts: std.ArrayList(usize) = .empty,

    pub fn generate(self: *Text, alloc: Allocator, smith: *std.testing.Smith, prefix: []const u8, suffix: []const u8, json_escaped: bool) !void {
        try self.text.appendSlice(alloc, prefix);
        for (0..smith.valueRangeAtMost(u8, 0, 24)) |_| {
            try self.maybeCut(alloc, smith);
            const character = characters[smith.index(characters.len)];
            const escaped: ?[]const u8 = if (!json_escaped) null else switch (character[0]) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\t' => "\\t",
                else => null,
            };
            const sequence = escaped orelse {
                try self.text.appendSlice(alloc, character);
                continue;
            };
            try self.text.append(alloc, sequence[0]);
            try self.maybeCut(alloc, smith);
            try self.text.appendSlice(alloc, sequence[1..]);
        }
        try self.maybeCut(alloc, smith);
        try self.text.appendSlice(alloc, suffix);
    }

    fn maybeCut(self: *Text, alloc: Allocator, smith: *std.testing.Smith) !void {
        const len = self.text.items.len;
        if (len == 0 or (self.cuts.items.len > 0 and self.cuts.items[self.cuts.items.len - 1] == len)) return;
        if (smith.boolWeighted(1, 2)) try self.cuts.append(alloc, len);
    }

    pub fn pieces(self: Text, alloc: Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var start: usize = 0;
        for (self.cuts.items) |cut| {
            try out.append(alloc, self.text.items[start..cut]);
            start = cut;
        }
        try out.append(alloc, self.text.items[start..]);
        return out.items;
    }
};

pub fn appendEvent(wire: *std.Io.Writer, smith: *std.testing.Smith, comptime fmt: []const u8, piece: []const u8) !void {
    if (smith.boolWeighted(1, 7)) try wire.writeAll(": ping\n\n");
    try wire.writeAll("data: ");
    try wire.print(fmt, .{std.json.fmt(piece, .{})});
    try wire.writeAll("\n\n");
}

pub fn readBuffer(alloc: Allocator, smith: *std.testing.Smith) ![]u8 {
    return alloc.alloc(u8, smith.valueRangeAtMost(u8, 1, 64));
}

pub const Deltas = struct {
    alloc: Allocator,
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    failed: bool = false,

    pub fn onContent(context: *anyopaque, chunk: []const u8) void {
        const self: *Deltas = @ptrCast(@alignCast(context));
        self.append(&self.content, chunk);
    }

    pub fn onReasoning(context: *anyopaque, chunk: []const u8) void {
        const self: *Deltas = @ptrCast(@alignCast(context));
        self.append(&self.reasoning, chunk);
    }

    pub fn sink(self: *Deltas) stream_provider.EventSink {
        return .{ .context = self, .emit_fn = emit };
    }

    fn emit(context: *anyopaque, event: stream_provider.Event) void {
        switch (event) {
            .content_delta => |chunk| onContent(context, chunk),
            .reasoning_delta => |chunk| onReasoning(context, chunk),
            else => {},
        }
    }

    fn append(self: *Deltas, list: *std.ArrayList(u8), chunk: []const u8) void {
        list.appendSlice(self.alloc, chunk) catch {
            self.failed = true;
        };
    }

    pub fn expectEqual(self: Deltas, content: []const u8, reasoning: []const u8) !void {
        try std.testing.expect(!self.failed);
        try std.testing.expectEqualStrings(content, self.content.items);
        try std.testing.expectEqualStrings(reasoning, self.reasoning.items);
    }
};

pub fn expectToolCall(calls: []const types.ToolCall, streamed: bool, id: []const u8, arguments: []const u8) !void {
    if (!streamed) return std.testing.expectEqual(@as(usize, 0), calls.len);
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings(id, calls[0].id);
    try std.testing.expectEqualStrings("read_file", calls[0].name);
    try std.testing.expectEqualStrings(arguments, calls[0].arguments_json);
    try std.testing.expectEqual(types.ToolArgumentIntegrity.valid, calls[0].argument_integrity);
}
