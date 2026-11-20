const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;

pub const plugins_dir_name = "plugins";
pub const managed_dir_name = "managed";
pub const data_dir_name = "data";
const installed_file_name = "installed.json";
const store_version: u8 = 1;
const max_store_bytes: usize = 4 * 1024 * 1024;

pub const McpServerState = struct {
    name: []const u8,
    enabled: bool = true,
};

pub const OptionValue = struct {
    key: []const u8,
    value: []const u8,
};

pub const Record = struct {
    id: []const u8,
    root: []const u8,
    source: []const u8,
    enabled: bool = true,
    installed_at_ms: i64 = 0,
    updated_at_ms: i64 = 0,
    mcp_servers: []const McpServerState = &.{},
    options: []const OptionValue = &.{},
    source_kind: []const u8 = source_kind_local_path,
    origin: []const u8 = origin_custom,
    catalog_id: ?[]const u8 = null,
    marketplace_source: ?[]const u8 = null,
    github: ?GithubInstall = null,
};

pub const source_kind_local_path = "local-path";
pub const source_kind_zip_url = "zip-url";
pub const source_kind_github = "github";
pub const origin_custom = "custom";
pub const origin_marketplace = "marketplace";
pub const origin_unknown = "unknown";

pub const GithubInstall = struct {
    owner: []const u8,
    repo: []const u8,
    ref_kind: []const u8,
    ref_value: []const u8,
    installed_sha: ?[]const u8 = null,
};

pub const File = struct {
    version: u8 = store_version,
    plugins: []const Record = &.{},
};

pub fn storeDir(alloc: Allocator, home: []const u8) ![]u8 {
    return profile_paths.rootPath(alloc, home, &.{plugins_dir_name});
}

pub fn installedPath(alloc: Allocator, home: []const u8) ![]u8 {
    return profile_paths.rootPath(alloc, home, &.{ plugins_dir_name, installed_file_name });
}

pub fn dataDir(alloc: Allocator, home: []const u8, id: []const u8) ![]u8 {
    return profile_paths.rootPath(alloc, home, &.{ plugins_dir_name, data_dir_name, id });
}

pub fn managedRoot(alloc: Allocator, home: []const u8, id: []const u8) ![]u8 {
    return profile_paths.rootPath(alloc, home, &.{ plugins_dir_name, managed_dir_name, id });
}

pub fn read(arena: Allocator, home: []const u8) !File {
    const path = try installedPath(arena, home);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), path, arena, .limited(max_store_bytes + 1)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const file = try std.json.parseFromSliceLeaky(File, arena, bytes, .{ .ignore_unknown_fields = true });
    if (file.version != store_version) return error.UnsupportedPluginStoreVersion;
    return file;
}

pub fn write(alloc: Allocator, home: []const u8, file: File) !void {
    const dir = try storeDir(alloc, home);
    defer alloc.free(dir);
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), dir);
    const path = try installedPath(alloc, home);
    defer alloc.free(path);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(file, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    try io_mod.writeFileAtomic(alloc, path, out.written());
}

test "store round trips records and defaults to an empty plugin list" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    const empty = try read(arena, home);
    try std.testing.expectEqual(@as(usize, 0), empty.plugins.len);

    const servers = [_]McpServerState{.{ .name = "docs", .enabled = false }};
    const records = [_]Record{.{
        .id = "acme.tools",
        .root = "/home/x/.fx/plugins/managed/acme.tools",
        .source = "/src/acme",
        .enabled = false,
        .installed_at_ms = 10,
        .updated_at_ms = 20,
        .mcp_servers = &servers,
    }};
    try write(arena, home, .{ .plugins = &records });

    const loaded = try read(arena, home);
    try std.testing.expectEqual(@as(usize, 1), loaded.plugins.len);
    const record = loaded.plugins[0];
    try std.testing.expectEqualStrings("acme.tools", record.id);
    try std.testing.expect(!record.enabled);
    try std.testing.expectEqual(@as(i64, 20), record.updated_at_ms);
    try std.testing.expectEqualStrings("docs", record.mcp_servers[0].name);
    try std.testing.expect(!record.mcp_servers[0].enabled);

    const written = try tmp.dir.readFileAlloc(std.testing.io, ".fx/plugins/installed.json", arena, .limited(max_store_bytes));
    try std.testing.expect(std.mem.indexOf(u8, written, "\"version\": 1") != null);
}

test "store keeps plugin option values and places plugin data beside the managed copies" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    const options = [_]OptionValue{.{ .key = "api_endpoint", .value = "https://api.example" }};
    const records = [_]Record{.{ .id = "acme", .root = "/r", .source = "/s", .options = &options }};
    try write(arena, home, .{ .plugins = &records });

    const loaded = try read(arena, home);
    try std.testing.expectEqualStrings("api_endpoint", loaded.plugins[0].options[0].key);
    try std.testing.expectEqualStrings("https://api.example", loaded.plugins[0].options[0].value);
    try std.testing.expect(std.mem.endsWith(u8, try dataDir(arena, home, "acme"), "/plugins/data/acme"));
}

test "store rejects an unknown store version" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".fx/plugins");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".fx/plugins/installed.json", .data = "{\"version\":2,\"plugins\":[]}" });
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    try std.testing.expectError(error.UnsupportedPluginStoreVersion, read(arena, home));
}
