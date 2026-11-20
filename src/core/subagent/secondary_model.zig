const std = @import("std");

pub const max_model_bytes: usize = 255;
pub const setting_path = "secondary_model.default_model";
pub const usage = "usage: /secondary-model [MODEL|off]";
pub const unset_notice = "Secondary model: not set; subagents use the main model unless a call or profile names one.";
pub const cleared_notice = "Secondary model cleared; subagents use the main model unless a call or profile names one.";

var model_bytes: [max_model_bytes]u8 = undefined;
var model_len: usize = 0;

pub fn set(model: ?[]const u8) void {
    const value = std.mem.trim(u8, model orelse "", " \t\r\n");
    if (value.len == 0 or value.len > max_model_bytes) {
        model_len = 0;
        return;
    }
    @memcpy(model_bytes[0..value.len], value);
    model_len = value.len;
}

pub fn defaultModel() ?[]const u8 {
    if (model_len == 0) return null;
    return model_bytes[0..model_len];
}

pub const Command = union(enum) { show, clear, choose: []const u8, invalid };

pub fn parse(rest: []const u8) Command {
    const argument = std.mem.trim(u8, rest, " \t\r\n");
    if (argument.len == 0) return .show;
    if (std.mem.findAny(u8, argument, " \t") != null) return .invalid;
    if (argument.len > max_model_bytes) return .invalid;
    if (std.ascii.eqlIgnoreCase(argument, "off") or std.ascii.eqlIgnoreCase(argument, "inherit")) return .clear;
    return .{ .choose = argument };
}

pub fn catalogModel(ids: []const []u8, query: []const u8) ?[]const u8 {
    for (ids) |id| {
        if (std.ascii.eqlIgnoreCase(id, query)) return id;
    }
    var only: ?[]const u8 = null;
    for (ids) |id| {
        if (!nameAfterProvider(id, query)) continue;
        if (only != null) return null;
        only = id;
    }
    return only;
}

fn nameAfterProvider(id: []const u8, query: []const u8) bool {
    const slash = std.mem.findScalarLast(u8, id, '/') orelse return false;
    return std.ascii.eqlIgnoreCase(id[slash + 1 ..], query);
}

test "the secondary model is unset until one is chosen and blank or oversized values clear it" {
    set(null);
    defer set(null);
    try std.testing.expect(defaultModel() == null);
    set("  provider/small-model \n");
    try std.testing.expectEqualStrings("provider/small-model", defaultModel().?);
    set("   ");
    try std.testing.expect(defaultModel() == null);
}

test "/secondary-model shows with no argument, clears with off, and takes one model name" {
    try std.testing.expect(parse("") == .show);
    try std.testing.expect(parse(" OFF ") == .clear);
    try std.testing.expect(parse("inherit") == .clear);
    try std.testing.expect(parse("two words") == .invalid);
    switch (parse(" provider/small-model ")) {
        .choose => |model| try std.testing.expectEqualStrings("provider/small-model", model),
        else => return error.TestExpectedEqual,
    }
}

test "a secondary model is matched to a catalog id exactly or by its name after the provider" {
    var first = "anthropic/claude-small".*;
    var second = "openai/gpt-small".*;
    var third = "other/gpt-small".*;
    const ids = [_][]u8{ &first, &second, &third };
    try std.testing.expectEqualStrings("openai/gpt-small", catalogModel(&ids, "OpenAI/GPT-small").?);
    try std.testing.expectEqualStrings("anthropic/claude-small", catalogModel(&ids, "claude-small").?);
    try std.testing.expect(catalogModel(&ids, "gpt-small") == null);
    try std.testing.expect(catalogModel(&ids, "missing") == null);
}
