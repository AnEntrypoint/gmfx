const std = @import("std");

const Allocator = std.mem.Allocator;

pub const key_name = "commit_gate";
pub const max_text_bytes = 1024;
pub const default_check_timeout_s: u32 = 600;
pub const max_check_timeout_s: u32 = 3600;

pub const Settings = struct {
    explicit_paths: bool = false,
    forbid_trailers: bool = false,
    author: ?[]const u8 = null,
    check_command: ?[]const u8 = null,
    check_timeout_s: u32 = default_check_timeout_s,

    pub fn active(self: Settings) bool {
        return self.explicit_paths or self.forbid_trailers or self.author != null or self.check_command != null;
    }
};

pub const ValidationError = error{
    InvalidCommitGateType,
    InvalidCommitGateKey,
    InvalidCommitGateValue,
};

const child_names = [_][]const u8{ "author", "check_command", "check_timeout_s", "explicit_paths", "forbid_trailers" };

pub fn validate(value: std.json.Value) ValidationError!void {
    if (value != .object) return error.InvalidCommitGateType;
    var entries = value.object.iterator();
    while (entries.next()) |entry| {
        const name = entry.key_ptr.*;
        const child = entry.value_ptr.*;
        if (!known(name)) return error.InvalidCommitGateKey;
        if (isSwitch(name)) {
            if (child != .bool) return error.InvalidCommitGateValue;
        } else if (std.mem.eql(u8, name, "check_timeout_s")) {
            if (child != .integer or child.integer < 1 or child.integer > max_check_timeout_s) return error.InvalidCommitGateValue;
        } else if (child != .null) {
            if (child != .string) return error.InvalidCommitGateValue;
            if (child.string.len > max_text_bytes) return error.InvalidCommitGateValue;
            if (std.mem.findScalar(u8, child.string, 0) != null) return error.InvalidCommitGateValue;
        }
    }
}

fn known(name: []const u8) bool {
    for (child_names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn isSwitch(name: []const u8) bool {
    return std.mem.eql(u8, name, "explicit_paths") or std.mem.eql(u8, name, "forbid_trailers");
}

pub fn parseSettingsText(arena: Allocator, settings_json: []const u8, workspace_root: []const u8) Allocator.Error!Settings {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, settings_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{},
    };
    if (root != .object) return .{};
    var settings: Settings = .{};
    if (root.object.get(key_name)) |value| try apply(arena, &settings, value);
    const workspaces = root.object.get("workspaces") orelse return settings;
    if (workspaces != .object) return settings;
    const workspace = workspaces.object.get(workspace_root) orelse return settings;
    if (workspace != .object) return settings;
    if (workspace.object.get(key_name)) |value| try apply(arena, &settings, value);
    return settings;
}

fn apply(arena: Allocator, settings: *Settings, value: std.json.Value) Allocator.Error!void {
    validate(value) catch return;
    if (value.object.get("explicit_paths")) |child| settings.explicit_paths = child.bool;
    if (value.object.get("forbid_trailers")) |child| settings.forbid_trailers = child.bool;
    if (value.object.get("check_timeout_s")) |child| settings.check_timeout_s = @intCast(child.integer);
    if (value.object.get("author")) |child| settings.author = try textOf(arena, child);
    if (value.object.get("check_command")) |child| settings.check_command = try textOf(arena, child);
}

fn textOf(arena: Allocator, value: std.json.Value) Allocator.Error!?[]const u8 {
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try arena.dupe(u8, trimmed);
}

test "every commit gate check is off until a setting turns it on" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "{}", "", "not json", "[]", "{\"commit_gate\":{}}", "{\"commit_gate\":\"wrong\"}", "{\"commit_gate\":{\"explicit_paths\":\"yes\"}}" }) |text| {
        const settings = try parseSettingsText(arena, text, "/w");
        try std.testing.expect(!settings.active());
        try std.testing.expectEqual(default_check_timeout_s, settings.check_timeout_s);
    }

    const on = try parseSettingsText(arena,
        \\{"commit_gate":{"explicit_paths":true,"forbid_trailers":true,"author":" Example Author ","check_command":"make check","check_timeout_s":30}}
    , "/w");
    try std.testing.expect(on.active());
    try std.testing.expect(on.explicit_paths and on.forbid_trailers);
    try std.testing.expectEqualStrings("Example Author", on.author.?);
    try std.testing.expectEqualStrings("make check", on.check_command.?);
    try std.testing.expectEqual(@as(u32, 30), on.check_timeout_s);
}

test "a workspace entry overrides the profile's commit gate key by key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\{"commit_gate":{"explicit_paths":true,"author":"Example Author"},
        \\ "workspaces":{"/w":{"commit_gate":{"explicit_paths":false,"check_command":"./check.sh","author":null}},
        \\               "/other":{"commit_gate":{"forbid_trailers":true}}}}
    ;
    const here = try parseSettingsText(arena, text, "/w");
    try std.testing.expect(!here.explicit_paths);
    try std.testing.expect(!here.forbid_trailers);
    try std.testing.expectEqual(@as(?[]const u8, null), here.author);
    try std.testing.expectEqualStrings("./check.sh", here.check_command.?);

    const elsewhere = try parseSettingsText(arena, text, "/elsewhere");
    try std.testing.expect(elsewhere.explicit_paths);
    try std.testing.expectEqualStrings("Example Author", elsewhere.author.?);
    try std.testing.expectEqual(@as(?[]const u8, null), elsewhere.check_command);
}

test "the commit gate setting accepts only its own keys and types" {
    const cases = [_]struct { json: []const u8, expected: ?ValidationError }{
        .{ .json = "{}", .expected = null },
        .{ .json = "{\"explicit_paths\":true,\"forbid_trailers\":false,\"author\":\"Example Author\",\"check_command\":\"make\",\"check_timeout_s\":1}", .expected = null },
        .{ .json = "{\"author\":null,\"check_command\":null}", .expected = null },
        .{ .json = "\"wrong\"", .expected = error.InvalidCommitGateType },
        .{ .json = "{\"explicit\":true}", .expected = error.InvalidCommitGateKey },
        .{ .json = "{\"explicit_paths\":1}", .expected = error.InvalidCommitGateValue },
        .{ .json = "{\"author\":5}", .expected = error.InvalidCommitGateValue },
        .{ .json = "{\"check_timeout_s\":0}", .expected = error.InvalidCommitGateValue },
        .{ .json = "{\"check_timeout_s\":3601}", .expected = error.InvalidCommitGateValue },
    };
    for (cases) |case| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case.json, .{});
        defer parsed.deinit();
        if (case.expected) |expected| {
            try std.testing.expectError(expected, validate(parsed.value));
        } else {
            try validate(parsed.value);
        }
    }
}
