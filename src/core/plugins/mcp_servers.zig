const std = @import("std");
const manager = @import("manager.zig");
const manifest = @import("manifest.zig");
const store = @import("store.zig");
const project_config = @import("../mcp/project_config.zig");
const io_mod = @import("../shared/io.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

pub const McpServerConfig = mcp_contract.McpServerConfig;

pub const Dirs = struct {
    home: ?[]const u8 = null,
    project: ?[]const u8 = null,
};

pub const root_mcp_file_name = ".mcp.json";
const max_root_mcp_bytes: usize = 1024 * 1024;
const plugin_root_placeholder = "${CLAUDE_PLUGIN_ROOT}";
const plugin_data_placeholder = "${CLAUDE_PLUGIN_DATA}";
const project_dir_placeholder = "${CLAUDE_PROJECT_DIR}";

pub fn appendEnabled(alloc: Allocator, plugins: []const manager.Plugin, out: *std.ArrayList(McpServerConfig)) !void {
    return appendEnabledIn(alloc, plugins, .{}, out);
}

pub fn appendEnabledIn(alloc: Allocator, plugins: []const manager.Plugin, dirs: Dirs, out: *std.ArrayList(McpServerConfig)) !void {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (plugins) |plugin| {
        if (!plugin.isOk() or !plugin.record.enabled) continue;
        const loaded = plugin.manifest orelse continue;
        const servers = (try declaredServers(arena, plugin.record.root, loaded.mcp_servers)) orelse continue;
        const placeholders: Placeholders = .{
            .root = plugin.record.root,
            .data = if (dirs.home) |home| try store.dataDir(arena, home, loaded.id) else null,
            .project = dirs.project,
            .profile_root = if (dirs.home) |home| try profile_paths.rootDir(arena, home) else null,
        };
        var iterator = servers.object.iterator();
        while (iterator.next()) |entry| {
            if (serverDisabled(plugin.record, entry.key_ptr.*)) continue;
            try appendServer(alloc, out, placeholders, loaded.id, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
}

pub fn declaredServers(arena: Allocator, root: []const u8, inline_servers: ?Value) !?Value {
    var servers: ObjectMap = .empty;
    if (inline_servers) |declared| {
        if (declared == .object) servers = try declared.object.clone(arena);
    }
    if (try rootFileServers(arena, root)) |from_file| {
        var iterator = from_file.iterator();
        while (iterator.next()) |entry| {
            if (servers.get(entry.key_ptr.*) != null) continue;
            try servers.put(arena, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    if (servers.count() == 0) return null;
    return .{ .object = servers };
}

fn rootFileServers(arena: Allocator, root: []const u8) !?ObjectMap {
    const path = try std.Io.Dir.path.join(arena, &.{ root, root_mcp_file_name });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), path, arena, .limited(max_root_mcp_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const document = std.json.parseFromSliceLeaky(Value, arena, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (document != .object) return null;
    if (document.object.get("mcpServers")) |wrapped| return if (wrapped == .object) wrapped.object else null;
    return document.object;
}

const Placeholders = struct {
    root: []const u8,
    data: ?[]const u8 = null,
    project: ?[]const u8 = null,
    profile_root: ?[]const u8 = null,
};

fn substitutePlaceholders(arena: Allocator, text: []const u8, placeholders: Placeholders) ![]const u8 {
    var current = try replaceEach(arena, text, plugin_root_placeholder, placeholders.root);
    if (placeholders.data) |data| {
        if (std.mem.find(u8, current, plugin_data_placeholder) != null) {
            std.Io.Dir.cwd().createDirPath(io_mod.getIo(), data) catch {};
            current = try replaceEach(arena, current, plugin_data_placeholder, data);
        }
    }
    if (placeholders.project) |project| current = try replaceEach(arena, current, project_dir_placeholder, project);
    return current;
}

fn replaceEach(arena: Allocator, text: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    if (std.mem.find(u8, text, needle) == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var rest = text;
    while (std.mem.find(u8, rest, needle)) |at| {
        try out.appendSlice(arena, rest[0..at]);
        try out.appendSlice(arena, replacement);
        rest = rest[at + needle.len ..];
    }
    try out.appendSlice(arena, rest);
    return out.items;
}

fn substituteInPlace(arena: Allocator, value: *Value, placeholders: Placeholders) Allocator.Error!void {
    switch (value.*) {
        .string => |text| value.* = .{ .string = try substitutePlaceholders(arena, text, placeholders) },
        .array => |list| for (list.items) |*item| try substituteInPlace(arena, item, placeholders),
        .object => |map| {
            var iterator = map.iterator();
            while (iterator.next()) |entry| try substituteInPlace(arena, entry.value_ptr, placeholders);
        },
        else => {},
    }
}

fn insidePluginRoot(arena: Allocator, text: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, text, plugin_root_placeholder)) return text;
    const rest = text[plugin_root_placeholder.len..];
    if (rest.len == 0) return "./";
    if (rest[0] != '/') return text;
    return std.mem.concat(arena, u8, &.{ ".", rest });
}

fn serverDisabled(record: store.Record, name: []const u8) bool {
    for (record.mcp_servers) |state| {
        if (std.mem.eql(u8, state.name, name)) return !state.enabled;
    }
    return false;
}

fn appendServer(
    alloc: Allocator,
    out: *std.ArrayList(McpServerConfig),
    placeholders: Placeholders,
    plugin_id: []const u8,
    server_name: []const u8,
    server_value: Value,
) !void {
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rewritten = (try rewriteServer(arena, placeholders, server_value)) orelse return;
    const key = try std.fmt.allocPrint(arena, "plugin-{s}:{s}", .{ plugin_id, server_name });
    var servers: ObjectMap = .empty;
    try servers.put(arena, key, rewritten);
    var document: ObjectMap = .empty;
    try document.put(arena, "mcpServers", .{ .object = servers });
    const text = try std.json.Stringify.valueAlloc(arena, Value{ .object = document }, .{});

    var configs = project_config.parseProfileJson(alloc, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer configs.deinit(alloc);
    try out.appendSlice(alloc, configs.items);
}

fn rewriteServer(arena: Allocator, placeholders: Placeholders, value: Value) !?Value {
    if (value != .object) return value;
    const copied = try copyValue(arena, value);
    var server = copied.object;
    if (server.get("url") == null) {
        if (!try keepInsidePlugin(arena, placeholders.root, &server)) return null;
        try runFromPluginRoot(arena, placeholders, &server);
    }
    var rewritten: Value = .{ .object = server };
    try substituteInPlace(arena, &rewritten, placeholders);
    return rewritten;
}

fn runFromPluginRoot(arena: Allocator, placeholders: Placeholders, server: *ObjectMap) !void {
    if (server.get("cwd") == null) try server.put(arena, "cwd", .{ .string = placeholders.root });
    var env: ObjectMap = .empty;
    if (server.get("env")) |declared| {
        if (declared == .object) env = try declared.object.clone(arena);
    }
    for (manager.hook_env_plugin_root_names) |name| try env.put(arena, name, .{ .string = placeholders.root });
    if (placeholders.profile_root) |profile_root| {
        for (manager.hook_env_home_names) |name| try env.put(arena, name, .{ .string = profile_root });
    }
    try server.put(arena, "env", .{ .object = env });
}

fn copyValue(arena: Allocator, value: Value) !Value {
    const text = try std.json.Stringify.valueAlloc(arena, value, .{});
    return std.json.parseFromSliceLeaky(Value, arena, text, .{});
}

fn keepInsidePlugin(arena: Allocator, root: []const u8, server: *ObjectMap) !bool {
    if (server.get("command")) |command| {
        if (command == .string) {
            const text = try insidePluginRoot(arena, command.string);
            if (std.mem.startsWith(u8, text, "./")) {
                const absolute = (try manifest.resolveInside(arena, root, text)) orelse return false;
                try server.put(arena, "command", .{ .string = absolute });
            } else if (std.mem.findScalar(u8, text, '/') != null or std.Io.Dir.path.isAbsolute(text)) {
                return false;
            }
        }
    }
    if (server.get("cwd")) |cwd| {
        if (cwd == .string) {
            const text = try insidePluginRoot(arena, cwd.string);
            if (!std.mem.startsWith(u8, text, "./")) return false;
            const absolute = (try manifest.resolveInside(arena, root, text)) orelse return false;
            try server.put(arena, "cwd", .{ .string = absolute });
        }
    }
    return true;
}

test "a plugin's .mcp.json servers load beside its inline ones, with the plugin, data and project directories substituted" {
    const testing = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "plugin/bin");
    try tmp.dir.createDirPath(testing.io, "home");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plugin/bin/server", .data = "#!/bin/sh\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plugin/kimi.plugin.json", .data = "{\"name\":\"acme\",\"mcpServers\":{\"inline\":{\"url\":\"https://mcp.example.test/mcp\"}}}" });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "plugin/.mcp.json",
        .data =
        \\{"mcpServers":{
        \\  "inline":{"url":"https://shadowed.example.test/mcp"},
        \\  "filed":{"command":"${CLAUDE_PLUGIN_ROOT}/bin/server","args":["--data","${CLAUDE_PLUGIN_DATA}/cache","--project","${CLAUDE_PROJECT_DIR}"],"env":{"PLUGIN_HOME":"${CLAUDE_PLUGIN_ROOT}"}}
        \\}}
        ,
    });
    const root = try tmp.dir.realPathFileAlloc(testing.io, "plugin", arena);
    const home = try tmp.dir.realPathFileAlloc(testing.io, "home", arena);
    const parsed = (try manifest.parse(arena, root)).manifest.?;

    const record: store.Record = .{ .id = "acme", .root = root, .source = root };
    const plugins = [_]manager.Plugin{.{ .record = record, .manifest = parsed }};
    var out: std.ArrayList(McpServerConfig) = .empty;
    defer {
        for (out.items) |*config| config.deinit(testing.allocator);
        out.deinit(testing.allocator);
    }
    try appendEnabledIn(testing.allocator, &plugins, .{ .home = home, .project = "/work/project" }, &out);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    var found_filed = false;
    for (out.items) |config| {
        if (std.mem.eql(u8, config.name, "plugin-acme:inline")) try testing.expectEqualStrings("https://mcp.example.test/mcp", config.url.?);
        if (!std.mem.eql(u8, config.name, "plugin-acme:filed")) continue;
        found_filed = true;
        try testing.expect(std.mem.startsWith(u8, config.command.?, root));
        try testing.expect(std.mem.endsWith(u8, config.command.?, "bin/server"));
        try testing.expectEqual(@as(usize, 4), config.args.len);
        try testing.expect(std.mem.endsWith(u8, config.args[1], "plugins/data/acme/cache"));
        try testing.expectEqualStrings("/work/project", config.args[3]);
    }
    try testing.expect(found_filed);
}

test "plugin MCP servers are named plugin-id:server and keep the plugin root for ./ paths" {
    const testing = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "bin");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bin/server", .data = "#!/bin/sh\n" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    const manifest_text =
        \\{"name":"acme","mcpServers":{
        \\  "local":{"command":"./bin/server","args":["--stdio"]},
        \\  "path":{"command":"/usr/bin/evil"},
        \\  "remote":{"url":"https://mcp.example.test/mcp"},
        \\  "escape":{"command":"./../outside"}
        \\}}
    ;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "kimi.plugin.json", .data = manifest_text });
    const parsed = (try manifest.parse(arena, root)).manifest.?;

    const record: store.Record = .{ .id = "acme", .root = root, .source = root };
    const plugins = [_]manager.Plugin{.{ .record = record, .manifest = parsed }};
    var out: std.ArrayList(McpServerConfig) = .empty;
    defer {
        for (out.items) |*config| config.deinit(testing.allocator);
        out.deinit(testing.allocator);
    }
    try appendEnabled(testing.allocator, &plugins, &out);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    var found_local = false;
    for (out.items) |config| {
        if (std.mem.eql(u8, config.name, "plugin-acme:local")) {
            found_local = true;
            try testing.expect(std.mem.startsWith(u8, config.command.?, root));
            try testing.expect(std.mem.endsWith(u8, config.command.?, "bin/server"));
        }
    }
    try testing.expect(found_local);
}

test "a plugin stdio MCP server runs in the plugin root with the plugin root and fx home in its environment" {
    const testing = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "plugin/work");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "plugin/kimi.plugin.json",
        .data = "{\"name\":\"acme\",\"mcpServers\":{\"plain\":{\"command\":\"node\",\"env\":{\"KEEP\":\"1\"}},\"placed\":{\"command\":\"node\",\"cwd\":\"./work\"},\"remote\":{\"url\":\"https://mcp.example.test/mcp\"}}}",
    });
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const root = try std.Io.Dir.path.join(arena, &.{ base, "plugin" });
    const parsed = (try manifest.parse(arena, root)).manifest.?;
    const plugins = [_]manager.Plugin{.{ .record = .{ .id = "acme", .root = root, .source = root }, .manifest = parsed }};
    var out: std.ArrayList(McpServerConfig) = .empty;
    defer {
        for (out.items) |*config| config.deinit(testing.allocator);
        out.deinit(testing.allocator);
    }
    try appendEnabledIn(testing.allocator, &plugins, .{ .home = base }, &out);
    const profile_root = try profile_paths.rootDir(arena, base);

    try testing.expectEqual(@as(usize, 3), out.items.len);
    var checked: usize = 0;
    for (out.items) |config| {
        if (std.mem.eql(u8, config.name, "plugin-acme:plain")) {
            checked += 1;
            try testing.expectEqualStrings(root, config.cwd orelse "");
            try testing.expectEqualStrings("1", envValue(config, "KEEP").?);
            try testing.expectEqualStrings(root, envValue(config, "FX_PLUGIN_ROOT").?);
            try testing.expectEqualStrings(root, envValue(config, "KIMI_PLUGIN_ROOT").?);
            try testing.expectEqualStrings(profile_root, envValue(config, "FX_HOME").?);
            try testing.expectEqualStrings(profile_root, envValue(config, "KIMI_CODE_HOME").?);
        }
        if (std.mem.eql(u8, config.name, "plugin-acme:placed")) {
            checked += 1;
            try testing.expect(std.mem.endsWith(u8, config.cwd.?, "/plugin/work"));
            try testing.expectEqualStrings(root, envValue(config, "KIMI_PLUGIN_ROOT").?);
        }
        if (std.mem.eql(u8, config.name, "plugin-acme:remote")) {
            checked += 1;
            try testing.expect(config.cwd == null);
            try testing.expect(envValue(config, "KIMI_PLUGIN_ROOT") == null);
        }
    }
    try testing.expectEqual(@as(usize, 3), checked);
}

fn envValue(config: McpServerConfig, key: []const u8) ?[]const u8 {
    for (config.env) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}

test "disabled plugin MCP servers are not offered" {
    const testing = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "kimi.plugin.json",
        .data = "{\"name\":\"acme\",\"mcpServers\":{\"remote\":{\"url\":\"https://mcp.example.test/mcp\"}}}",
    });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const parsed = (try manifest.parse(arena, root)).manifest.?;

    const states = [_]store.McpServerState{.{ .name = "remote", .enabled = false }};
    const record: store.Record = .{ .id = "acme", .root = root, .source = root, .mcp_servers = &states };
    const plugins = [_]manager.Plugin{.{ .record = record, .manifest = parsed }};
    var out: std.ArrayList(McpServerConfig) = .empty;
    defer {
        for (out.items) |*config| config.deinit(testing.allocator);
        out.deinit(testing.allocator);
    }
    try appendEnabled(testing.allocator, &plugins, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
