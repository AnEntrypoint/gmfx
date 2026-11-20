const std = @import("std");
const jsonrpc = @import("../acp/jsonrpc.zig");
const skills = @import("skills.zig");
const runs = @import("runs.zig");
const prompts = @import("prompts.zig");
const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;

pub const max_values = 100;

pub const Error = error{InvalidParams};

pub fn write(alloc: Allocator, root: ?std.Io.Dir, params: std.json.Value, w: *std.Io.Writer, modern: bool) !void {
    if (params != .object) return error.InvalidParams;
    const ref = params.object.get("ref") orelse return error.InvalidParams;
    if (ref != .object) return error.InvalidParams;
    const ref_type = stringField(ref, "type") orelse return error.InvalidParams;
    if (!std.mem.eql(u8, ref_type, "ref/resource") and !std.mem.eql(u8, ref_type, "ref/prompt")) {
        return error.InvalidParams;
    }
    const argument = params.object.get("argument") orelse return error.InvalidParams;
    if (argument != .object) return error.InvalidParams;
    const name = stringField(argument, "name") orelse return error.InvalidParams;
    const prefix = stringField(argument, "value") orelse return error.InvalidParams;

    const candidates = try candidatesFor(alloc, root, name);
    var matches: std.ArrayList([]const u8) = .empty;
    for (candidates) |candidate| {
        if (!std.mem.startsWith(u8, candidate, prefix)) continue;
        if (containsString(matches.items, candidate)) continue;
        try matches.append(alloc, candidate);
    }

    const total = matches.items.len;
    const shown = @min(total, max_values);
    try w.writeByte('{');
    try wire.writeComplete(w, modern);
    try w.writeAll("\"completion\":{\"values\":[");
    for (matches.items[0..shown], 0..) |value, index| {
        if (index > 0) try w.writeByte(',');
        try jsonrpc.writeJsonStr(value, w);
    }
    try w.print("],\"total\":{d},\"hasMore\":{s}}}}}", .{
        total,
        if (total > shown) "true" else "false",
    });
}

fn candidatesFor(alloc: Allocator, root: ?std.Io.Dir, argument: []const u8) ![]const []const u8 {
    var values: std.ArrayList([]const u8) = .empty;
    if (std.mem.eql(u8, argument, "skill")) {
        for (skills.entries) |entry| {
            if (entry.served() == null) continue;
            try values.append(alloc, entry.skill);
        }
    } else if (std.mem.eql(u8, argument, "file")) {
        for (skills.entries) |entry| {
            if (entry.served() == null) continue;
            try values.append(alloc, entry.file);
        }
    } else if (std.mem.eql(u8, argument, "name")) {
        for (try prompts.servedNames(alloc)) |name| {
            try values.append(alloc, name);
        }
    } else if (std.mem.eql(u8, argument, "session")) {
        if (root) |dir| {
            for (try runs.list(alloc, dir)) |run| {
                try values.append(alloc, run.id);
            }
        }
    }
    return values.items;
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .string) field.string else null;
}

fn containsString(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}
