const std = @import("std");
const wire = @import("wire.zig");

pub const Prompt = struct { name: []const u8, arguments: ?[]const u8 };

pub const Op = union(enum) {
    list: ?[]const u8,
    templates: ?[]const u8,
    read: []const u8,
    prompts: ?[]const u8,
    prompt: Prompt,

    pub fn method(self: Op) []const u8 {
        return switch (self) {
            .list => "resources/list",
            .templates => "resources/templates/list",
            .read => "resources/read",
            .prompts => "prompts/list",
            .prompt => "prompts/get",
        };
    }

    pub fn dupe(self: Op, a: std.mem.Allocator) std.mem.Allocator.Error!Op {
        return switch (self) {
            .list => |cursor| .{ .list = if (cursor) |c| try a.dupe(u8, c) else null },
            .templates => |cursor| .{ .templates = if (cursor) |c| try a.dupe(u8, c) else null },
            .read => |uri| .{ .read = try a.dupe(u8, uri) },
            .prompts => |cursor| .{ .prompts = if (cursor) |c| try a.dupe(u8, c) else null },
            .prompt => |p| .{ .prompt = .{
                .name = try a.dupe(u8, p.name),
                .arguments = if (p.arguments) |args| try a.dupe(u8, args) else null,
            } },
        };
    }
};

pub const Answer = union(enum) {
    result: []const u8,
    failure: wire.Failure,
    invalid,
};

pub fn write(out: *std.Io.Writer, id: wire.RequestId, meta: wire.Meta, op: Op) wire.EncodeError!void {
    var w: wire.Writer = try .request(out, id, op.method(), meta);
    switch (op) {
        .list, .templates, .prompts => |cursor| if (cursor) |c| {
            try w.field("cursor");
            try w.string(c);
        },
        .read => |uri| {
            try w.field("uri");
            try w.string(uri);
        },
        .prompt => |p| {
            try w.field("name");
            try w.string(p.name);
            if (p.arguments) |args| {
                try w.field("arguments");
                try w.raw(args);
            }
        },
    }
    try w.end();
}

pub fn classify(body: @FieldType(wire.Response, "body")) Answer {
    return switch (body) {
        .failure => |failure| .{ .failure = failure },
        .result => |result| if (result.kind == .complete) .{ .result = result.raw } else .invalid,
    };
}

test "a list writes the cursor only when one is given" {
    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try write(&out, 7, .{}, .{ .list = null });
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"cursor\"") == null);
    out.end = 0;
    try write(&out, 8, .{}, .{ .list = "" });
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"cursor\":\"\"") != null);
}

test "a prompt request names the prompt and its arguments" {
    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try write(&out, 10, .{}, .{ .prompt = .{ .name = "review", .arguments = "{\"tone\":\"formal\"}" } });
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"method\":\"prompts/get\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"arguments\":{\"tone\":\"formal\"}") != null);
}

test "a read names the uri it reads" {
    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try write(&out, 9, .{}, .{ .read = "custom://alpha" });
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"method\":\"resources/read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"uri\":\"custom://alpha\"") != null);
}
