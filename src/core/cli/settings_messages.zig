const std = @import("std");
const command_specs = @import("../slash_commands/command_specs.zig");
const cli_flags = @import("cli_flags.zig");
const settings_keys = @import("../config/settings_keys.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub fn closest(name: []const u8, known: []const []const u8) ?[]const u8 {
    var nearest: cli_flags.Nearest = .{ .word = name };
    for (known) |candidate| nearest.offer(candidate);
    return nearest.best;
}

pub fn formatUnknownSetting(alloc: Allocator, key: settings_keys.UnknownKey, display_path: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("unknown setting ");
    try writeDotted(writer, key.parent, key.name);
    try writer.print(" in {s}", .{display_path});
    try writeWorkspace(writer, key.workspace);
    try writeSuggestion(writer, key.parent, closest(key.name, key.known));
    return out.toOwnedSlice();
}

pub fn formatOlderName(alloc: Allocator, twice: settings_keys.OlderName, display_path: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    if (twice.both) {
        try writer.print("{s} and {s} are both set in {s}", .{ twice.older, twice.current, display_path });
        try writeWorkspace(writer, twice.workspace);
        try writer.print("; fx uses {s} where they differ, so remove {s}", .{ twice.current, twice.older });
    } else {
        try writer.print("{s} in {s}", .{ twice.older, display_path });
        try writeWorkspace(writer, twice.workspace);
        try writer.print(" " ++ command_specs.deprecated_until ++ "; rename it to {s}", .{twice.current});
    }
    return out.toOwnedSlice();
}

pub fn formatUnknownPath(alloc: Allocator, part: settings_keys.UnknownPart) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("unknown setting ");
    try writeDotted(&out.writer, part.parent, part.name);
    try writeSuggestion(&out.writer, part.parent, closest(part.name, part.known));
    return out.toOwnedSlice();
}

fn writeDotted(writer: *std.Io.Writer, parent: ?[]const u8, name: []const u8) !void {
    if (parent) |value| try writer.print("{f}.", .{text_utils.terminalSafe(value)});
    try writer.print("{f}", .{text_utils.terminalSafe(name)});
}

fn writeWorkspace(writer: *std.Io.Writer, workspace: ?[]const u8) !void {
    if (workspace) |path| try writer.print(" for workspace {f}", .{text_utils.terminalSafe(path)});
}

fn writeSuggestion(writer: *std.Io.Writer, parent: ?[]const u8, suggestion: ?[]const u8) !void {
    const name = suggestion orelse return;
    try writer.writeAll(" (did you mean ");
    try writeDotted(writer, parent, name);
    try writer.writeAll("?)");
}

test "unknown settings name the file, the workspace, and the closest key" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { key: settings_keys.UnknownKey, file: []const u8, expected: []const u8 }{
        .{
            .key = .{ .name = "fast_mdoe", .known = &.{ "fast_mode", "model" } },
            .file = "~/.fx/settings.json",
            .expected = "unknown setting fast_mdoe in ~/.fx/settings.json (did you mean fast_mode?)",
        },
        .{
            .key = .{ .name = "contxt", .parent = "statusLine", .workspace = "/w", .known = &.{ "context", "session" } },
            .file = "~/.fx/settings.json",
            .expected = "unknown setting statusLine.contxt in ~/.fx/settings.json for workspace /w (did you mean statusLine.context?)",
        },
        .{
            .key = .{ .name = "colour", .known = &.{ "model", "theme" } },
            .file = ".fx.json",
            .expected = "unknown setting colour in .fx.json",
        },
    };
    for (cases) |case| {
        const detail = try formatUnknownSetting(alloc, case.key, case.file);
        defer alloc.free(detail);
        try std.testing.expectEqualStrings(case.expected, detail);
    }
}

test "a setting under both its older and its current name names the one to remove" {
    const alloc = std.testing.allocator;
    const top = try formatOlderName(alloc, .{ .older = "statusLine", .current = "status_line" }, "~/.fx/settings.json");
    defer alloc.free(top);
    try std.testing.expectEqualStrings("statusLine and status_line are both set in ~/.fx/settings.json; fx uses status_line where they differ, so remove statusLine", top);
    const workspace = try formatOlderName(alloc, .{ .older = "notifications", .current = "sound", .workspace = "/w" }, "~/.fx/settings.json");
    defer alloc.free(workspace);
    try std.testing.expectEqualStrings("notifications and sound are both set in ~/.fx/settings.json for workspace /w; fx uses sound where they differ, so remove notifications", workspace);
}

test "an older setting name names the release that drops it" {
    const alloc = std.testing.allocator;
    const older = try formatOlderName(alloc, .{ .older = "statusLine", .current = "status_line", .both = false }, "~/.fx/settings.json");
    defer alloc.free(older);
    try std.testing.expectEqualStrings("statusLine in ~/.fx/settings.json is deprecated and stops working in fx 0.0.18; rename it to status_line", older);
}

test "a mistyped key on the command line gets the closest known key" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { path: []const u8, expected: []const u8 }{
        .{ .path = "fast_mdoe", .expected = "unknown setting fast_mdoe (did you mean fast_mode?)" },
        .{ .path = "status_line.sesion", .expected = "unknown setting status_line.sesion (did you mean status_line.session?)" },
        .{ .path = "statusLine.sesion", .expected = "unknown setting status_line.sesion (did you mean status_line.session?)" },
        .{ .path = "fast_mode.on", .expected = "unknown setting fast_mode.on" },
    };
    for (cases) |case| {
        const message = try formatUnknownPath(alloc, settings_keys.unknownPart(case.path).?);
        defer alloc.free(message);
        try std.testing.expectEqualStrings(case.expected, message);
    }
}
