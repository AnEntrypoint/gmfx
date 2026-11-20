const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const toml_reader = @import("toml_reader.zig");

const Allocator = std.mem.Allocator;
const ObjectMap = std.json.ObjectMap;
const Value = std.json.Value;

pub const config_file_name = "config.toml";
pub const tui_file_name = "tui.toml";
pub const project_local_dir = ".kimi-code";
pub const project_local_file = "local.toml";
const max_file_bytes: usize = 64 * 1024;

pub fn mergedUserSettings(alloc: Allocator, home: []const u8, primary: ?[]const u8) !?[]u8 {
    const config_path = try profile_paths.rootPath(alloc, home, &.{config_file_name});
    defer alloc.free(config_path);
    const tui_path = try profile_paths.rootPath(alloc, home, &.{tui_file_name});
    defer alloc.free(tui_path);

    const config_text = try readOptionalFile(alloc, config_path);
    defer if (config_text) |text| alloc.free(text);
    const tui_text = try readOptionalFile(alloc, tui_path);
    defer if (tui_text) |text| alloc.free(text);
    if (config_text == null and tui_text == null) return null;

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const root = try mergeDocuments(arena_state.allocator(), primary, config_text, tui_text);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(Value{ .object = root }, .{}, &out.writer);
    return try out.toOwnedSlice();
}

pub fn mergeDocuments(
    arena: Allocator,
    primary: ?[]const u8,
    config_text: ?[]const u8,
    tui_text: ?[]const u8,
) !ObjectMap {
    var root: ObjectMap = .empty;
    if (primary) |bytes| {
        const parsed = try std.json.parseFromSliceLeaky(Value, arena, bytes, .{});
        if (parsed != .object) return error.InvalidUserToml;
        root = parsed.object;
    }
    if (config_text) |text| try overlayConfigDocument(arena, &root, text);
    if (tui_text) |text| try overlayTuiDocument(arena, &root, text);
    return root;
}

fn overlayConfigDocument(arena: Allocator, root: *ObjectMap, text: []const u8) !void {
    const document = try toml_reader.parse(arena, text);
    var iterator = document.object.iterator();
    while (iterator.next()) |entry| try root.put(arena, entry.key_ptr.*, entry.value_ptr.*);
}

fn overlayTuiDocument(arena: Allocator, root: *ObjectMap, text: []const u8) !void {
    const document = try toml_reader.parse(arena, text);
    if (document.object.get("theme")) |theme| {
        if (theme != .string) return error.InvalidUserToml;
        if (!std.mem.eql(u8, theme.string, "auto")) try root.put(arena, "theme", theme);
    }
    if (document.object.get("auto_session_title")) |title| {
        if (title != .bool) return error.InvalidUserToml;
        try root.put(arena, "session_titles", title);
    }
    if (document.object.get("upgrade")) |upgrade| {
        if (upgrade != .object) return error.InvalidUserToml;
        if (upgrade.object.get("auto_install")) |install| {
            if (install != .bool) return error.InvalidUserToml;
            try root.put(arena, "auto_upgrade", install);
        }
    }
}

fn readOptionalFile(alloc: Allocator, path: []const u8) !?[]u8 {
    var file = io_mod.openExistingRegularFile(
        std.Io.Dir.cwd(),
        path,
        .read_only,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());

    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.size > max_file_bytes) return error.StreamTooLong;
    return try io_mod.readFileToEnd(alloc, &file, max_file_bytes + 1);
}

test "user toml files replace top-level sections and map the tui keys" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const root = try mergeDocuments(arena_state.allocator(), "{\"theme\":\"dark\",\"session_titles\":false,\"loop_control\":{\"max_steps_per_turn\":5}}",
        \\[loop_control]
        \\max_steps_per_turn = 40
        \\[[hooks]]
        \\event = "PreToolUse"
        \\
    ,
        \\theme = "auto"
        \\auto_session_title = true
        \\render_latex = true
        \\[upgrade]
        \\auto_install = false
        \\
    );
    try std.testing.expectEqualStrings("dark", root.get("theme").?.string);
    try std.testing.expectEqual(true, root.get("session_titles").?.bool);
    try std.testing.expectEqual(false, root.get("auto_upgrade").?.bool);
    try std.testing.expect(root.get("render_latex") == null);
    try std.testing.expectEqual(@as(i64, 40), root.get("loop_control").?.object.get("max_steps_per_turn").?.integer);
    try std.testing.expectEqualStrings("PreToolUse", root.get("hooks").?.array.items[0].object.get("event").?.string);
}

test "user toml files without a settings file build the settings from config.toml" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const root = try mergeDocuments(arena_state.allocator(), null, "theme = \"light\"\n", null);
    try std.testing.expectEqualStrings("light", root.get("theme").?.string);
    try std.testing.expectEqual(@as(usize, 1), root.count());
}

test "user toml files reject malformed documents and mistyped tui keys" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.InvalidToml, mergeDocuments(arena, null, "a = \n", null));
    try std.testing.expectError(error.InvalidUserToml, mergeDocuments(arena, null, null, "auto_session_title = \"yes\"\n"));
    try std.testing.expectError(error.InvalidUserToml, mergeDocuments(arena, "[]", null, null));
}
