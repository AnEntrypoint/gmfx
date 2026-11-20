const std = @import("std");
const external = @import("../hooks/external.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const manifest = @import("manifest.zig");
const plugin_mcp_servers = @import("mcp_servers.zig");
const sources = @import("source.zig");
const store = @import("store.zig");
const remote = @import("remote.zig");
const archive = @import("archive.zig");
const availability = @import("availability.zig");
const marketplace = @import("marketplace.zig");

const Allocator = std.mem.Allocator;
const cwd = std.Io.Dir.cwd;

pub const Error = error{
    RelativePluginSource,
    UnsupportedPluginSource,
    PluginManifestInvalid,
    PluginNotFound,
    InvalidPluginId,
    PluginTrustRequired,
    PluginIdMismatch,
    MarketplaceInstallNeedsZipUrl,
};

pub const InstallOptions = struct {
    trusted: bool = false,
    expected_id: ?[]const u8 = null,
    expected_sha256: ?[]const u8 = null,
    origin: []const u8 = store.origin_custom,
    catalog_id: ?[]const u8 = null,
    marketplace_source: ?[]const u8 = null,
    fetcher: remote.Fetcher = remote.live,
};

pub const Plugin = struct {
    record: store.Record,
    manifest: ?manifest.Manifest = null,
    diagnostics: []const manifest.Diagnostic = &.{},
    load_error: ?[]const u8 = null,

    pub fn isOk(self: Plugin) bool {
        return self.load_error == null and self.manifest != null;
    }
};

pub const ReloadError = struct {
    id: []const u8,
    message: []const u8,
};

pub const ReloadSummary = struct {
    added: []const []const u8 = &.{},
    removed: []const []const u8 = &.{},
    errors: []const ReloadError = &.{},
};

pub fn load(arena: Allocator, home: []const u8) ![]Plugin {
    const file = try store.read(arena, home);
    const offered = try availability.readOrEmpty(arena, home);
    const session_plugins = try sessionPlugins(arena);
    var out: std.ArrayList(Plugin) = .empty;
    for (file.plugins) |record| {
        if (!try availability.supports(arena, offered, record, marketplace.host_client, marketplace.hostPlatform())) continue;
        if (pluginWithId(session_plugins, record.id) != null) continue;
        try out.append(arena, try materialize(arena, record));
    }
    try out.appendSlice(arena, session_plugins);
    return out.toOwnedSlice(arena);
}

pub const max_session_plugin_dirs: usize = 16;
const max_session_plugin_dir_bytes: usize = 4096;
var session_plugin_dir_buffers: [max_session_plugin_dirs][max_session_plugin_dir_bytes]u8 = undefined;
var session_plugin_dir_lens: [max_session_plugin_dirs]usize = @splat(0);
var session_plugin_dir_count: usize = 0;

pub const SessionPluginDirError = error{ TooManySessionPluginDirs, SessionPluginDirTooLong };

pub fn addSessionPluginDir(absolute_dir: []const u8) SessionPluginDirError!void {
    if (absolute_dir.len > max_session_plugin_dir_bytes) return error.SessionPluginDirTooLong;
    for (0..session_plugin_dir_count) |index| {
        if (std.mem.eql(u8, sessionPluginDir(index), absolute_dir)) return;
    }
    if (session_plugin_dir_count == max_session_plugin_dirs) return error.TooManySessionPluginDirs;
    @memcpy(session_plugin_dir_buffers[session_plugin_dir_count][0..absolute_dir.len], absolute_dir);
    session_plugin_dir_lens[session_plugin_dir_count] = absolute_dir.len;
    session_plugin_dir_count += 1;
}

pub fn clearSessionPluginDirs() void {
    session_plugin_dir_count = 0;
}

fn sessionPluginDir(index: usize) []const u8 {
    return session_plugin_dir_buffers[index][0..session_plugin_dir_lens[index]];
}

fn sessionPlugins(arena: Allocator) ![]const Plugin {
    var out: std.ArrayList(Plugin) = .empty;
    for (0..session_plugin_dir_count) |index| {
        const dir = try arena.dupe(u8, sessionPluginDir(index));
        const parsed = try manifest.parse(arena, dir);
        const id = if (parsed.manifest) |loaded| loaded.id else try manifest.normalizeId(arena, std.Io.Dir.path.basename(dir));
        if (pluginWithId(out.items, id) != null) continue;
        try out.append(arena, try materialize(arena, .{ .id = id, .root = dir, .source = dir }));
    }
    return out.toOwnedSlice(arena);
}

fn pluginWithId(plugins: []const Plugin, id: []const u8) ?Plugin {
    for (plugins) |plugin| {
        if (std.mem.eql(u8, plugin.record.id, id)) return plugin;
    }
    return null;
}

pub fn list(arena: Allocator, home: []const u8) ![]Plugin {
    const plugins = try load(arena, home);
    std.mem.sort(Plugin, plugins, {}, lessThanById);
    return plugins;
}

pub const hook_env_home_names = [_][]const u8{ "FX_HOME", "KIMI_CODE_HOME" };
pub const hook_env_plugin_root_names = [_][]const u8{ "FX_PLUGIN_ROOT", "KIMI_PLUGIN_ROOT" };
pub const claude_plugin_root_env = "CLAUDE_PLUGIN_ROOT";
pub const claude_plugin_data_env = "CLAUDE_PLUGIN_DATA";
pub const claude_plugin_option_env_prefix = "CLAUDE_PLUGIN_OPTION_";

pub fn hookDefinitions(alloc: Allocator, home: []const u8, configured: []const external.Definition, plugins: []const Plugin) ![]external.Definition {
    var out: std.ArrayList(external.Definition) = .empty;
    errdefer {
        for (out.items) |*definition| definition.deinit(alloc);
        out.deinit(alloc);
    }
    try appendOwnedDefinitions(alloc, &out, configured);
    const profile_root = try profile_paths.rootDir(alloc, home);
    defer alloc.free(profile_root);
    for (plugins) |plugin| {
        if (!plugin.record.enabled or !plugin.isOk()) continue;
        const loaded = plugin.manifest orelse continue;
        const first_plugin_hook = out.items.len;
        try appendOwnedDefinitions(alloc, &out, loaded.hooks);
        const data_dir = try store.dataDir(alloc, home, plugin.record.id);
        defer alloc.free(data_dir);
        var option_names: std.ArrayList([]u8) = .empty;
        defer {
            for (option_names.items) |name| alloc.free(name);
            option_names.deinit(alloc);
        }
        var env: std.ArrayList(external.EnvVar) = .empty;
        defer env.deinit(alloc);
        try env.appendSlice(alloc, &.{
            .{ .name = hook_env_home_names[0], .value = profile_root },
            .{ .name = hook_env_home_names[1], .value = profile_root },
            .{ .name = hook_env_plugin_root_names[0], .value = plugin.record.root },
            .{ .name = hook_env_plugin_root_names[1], .value = plugin.record.root },
            .{ .name = claude_plugin_root_env, .value = plugin.record.root },
            .{ .name = claude_plugin_data_env, .value = data_dir },
        });
        for (loaded.user_config) |option| {
            const value = optionValue(plugin.record, option) orelse continue;
            const name = try optionEnvName(alloc, option.key);
            option_names.append(alloc, name) catch |err| {
                alloc.free(name);
                return err;
            };
            try env.append(alloc, .{ .name = name, .value = value });
        }
        for (out.items[first_plugin_hook..]) |*definition| {
            try substituteUserConfig(alloc, definition, plugin.record, loaded.user_config);
            try definition.replaceEnv(alloc, env.items);
        }
    }
    return out.toOwnedSlice(alloc);
}

pub fn optionValue(record: store.Record, option: manifest.UserConfigOption) ?[]const u8 {
    for (record.options) |stored| {
        if (std.mem.eql(u8, stored.key, option.key)) return stored.value;
    }
    return option.default_value;
}

pub fn optionEnvName(alloc: Allocator, key: []const u8) Allocator.Error![]u8 {
    const name = try std.fmt.allocPrint(alloc, "{s}{s}", .{ claude_plugin_option_env_prefix, key });
    for (name[claude_plugin_option_env_prefix.len..]) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return name;
}

fn substituteUserConfig(alloc: Allocator, definition: *external.Definition, record: store.Record, options: []const manifest.UserConfigOption) Allocator.Error!void {
    for (options) |option| {
        const value = optionValue(record, option) orelse continue;
        const placeholder = try std.fmt.allocPrint(alloc, "{s}{s}}}", .{ manifest.user_config_placeholder_prefix, option.key });
        defer alloc.free(placeholder);
        if (std.mem.find(u8, definition.command, placeholder) == null) continue;
        const replaced = try std.mem.replaceOwned(u8, alloc, definition.command, placeholder, value);
        alloc.free(definition.command);
        definition.command = replaced;
    }
}

pub fn setOption(arena: Allocator, home: []const u8, id: []const u8, key: []const u8, value: []const u8, now_ms: i64) !void {
    const plugin_key = try manifest.normalizeId(arena, id);
    const existing = try store.read(arena, home);
    const records = try arena.dupe(store.Record, existing.plugins);
    for (records) |*record| {
        if (!std.mem.eql(u8, record.id, plugin_key)) continue;
        const declared = (try manifest.parse(arena, record.root)).manifest orelse return error.PluginOptionNotDeclared;
        const option = declaredOption(declared.user_config, key) orelse return error.PluginOptionNotDeclared;
        if (option.sensitive) return error.PluginOptionSensitive;

        var values: std.ArrayList(store.OptionValue) = .empty;
        for (record.options) |stored| {
            if (!std.mem.eql(u8, stored.key, key)) try values.append(arena, stored);
        }
        try values.append(arena, .{ .key = key, .value = value });
        record.options = values.items;
        record.updated_at_ms = now_ms;
        try store.write(arena, home, .{ .plugins = records });
        return;
    }
    return error.PluginNotFound;
}

fn declaredOption(options: []const manifest.UserConfigOption, key: []const u8) ?manifest.UserConfigOption {
    for (options) |option| {
        if (std.mem.eql(u8, option.key, key)) return option;
    }
    return null;
}

pub fn runtimeHookDefinitions(alloc: Allocator, home: ?[]const u8, configured: ?[]const external.Definition) Allocator.Error!?[]external.Definition {
    const configured_hooks: []const external.Definition = configured orelse &.{};
    const merged = mergedWithInstalledPlugins(alloc, home, configured_hooks) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            debug_trace.logf("hooks", "plugin hooks unavailable err={s} kept=configured_hooks", .{@errorName(err)});
            break :blk try external.cloneDefinitions(alloc, configured_hooks);
        },
    };
    if (merged.len == 0 and configured == null) {
        alloc.free(merged);
        return null;
    }
    return merged;
}

fn mergedWithInstalledPlugins(alloc: Allocator, home: ?[]const u8, configured: []const external.Definition) ![]external.Definition {
    const plugin_home = home orelse return external.cloneDefinitions(alloc, configured);
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const plugins = try load(arena_state.allocator(), plugin_home);
    for (plugins) |plugin| {
        if (!plugin.record.enabled or !plugin.isOk()) continue;
        const data_dir = try store.dataDir(arena_state.allocator(), plugin_home, plugin.record.id);
        cwd().createDirPath(io_mod.getIo(), data_dir) catch |err| {
            debug_trace.logf("hooks", "plugin data directory not created id={s} err={s}", .{ plugin.record.id, @errorName(err) });
        };
    }
    return hookDefinitions(alloc, plugin_home, configured, plugins);
}

fn appendOwnedDefinitions(alloc: Allocator, out: *std.ArrayList(external.Definition), source: []const external.Definition) !void {
    const copies = try external.cloneDefinitions(alloc, source);
    errdefer external.freeDefinitions(alloc, copies);
    try out.appendSlice(alloc, copies);
    alloc.free(copies);
}

fn lessThanById(_: void, lhs: Plugin, rhs: Plugin) bool {
    return std.mem.lessThan(u8, lhs.record.id, rhs.record.id);
}

fn materialize(arena: Allocator, record: store.Record) !Plugin {
    const parsed = try manifest.parse(arena, record.root);
    if (parsed.manifest) |loaded| {
        return .{ .record = record, .manifest = loaded, .diagnostics = parsed.diagnostics };
    }
    return .{
        .record = record,
        .diagnostics = parsed.diagnostics,
        .load_error = firstError(parsed.diagnostics) orelse "no manifest",
    };
}

fn firstError(diagnostics: []const manifest.Diagnostic) ?[]const u8 {
    for (diagnostics) |diagnostic| {
        if (diagnostic.severity == .err) return diagnostic.message;
    }
    return null;
}

pub fn install(arena: Allocator, home: []const u8, raw_source: []const u8, now_ms: i64, options: InstallOptions) !Plugin {
    if (!options.trusted) return error.PluginTrustRequired;
    const resolved = try sources.resolve(arena, raw_source);
    if (options.expected_sha256 != null and resolved != .zip_url) return error.MarketplaceInstallNeedsZipUrl;
    const io = io_mod.getIo();
    var fetched: ?remote.Fetched = null;
    defer if (fetched) |download| cwd().deleteTree(io, download.scratch_dir) catch {};
    const source_root = switch (resolved) {
        .local_path => |path| try cwd().realPathFileAlloc(io, path, arena),
        .zip_url, .github => from_remote: {
            const download = try remote.fetchPlugin(arena, home, resolved, now_ms, options.fetcher, options.expected_sha256);
            fetched = download;
            break :from_remote download.root;
        },
    };
    const original_source: []const u8 = switch (resolved) {
        .local_path => source_root,
        .zip_url, .github => try arena.dupe(u8, std.mem.trim(u8, raw_source, " \t\r\n")),
    };
    const source_kind: []const u8 = switch (resolved) {
        .local_path => store.source_kind_local_path,
        .zip_url => store.source_kind_zip_url,
        .github => store.source_kind_github,
    };
    const github_install: ?store.GithubInstall = if (fetched) |download| download.github else null;

    const parsed = try manifest.parse(arena, source_root);
    const id = (parsed.manifest orelse return error.PluginManifestInvalid).id;
    if (!manifest.isValidName(id)) return error.InvalidPluginId;
    if (options.expected_id) |expected| {
        if (!std.mem.eql(u8, try manifest.normalizeId(arena, expected), id)) return error.PluginIdMismatch;
    }

    const managed = try store.managedRoot(arena, home, id);
    const staging = try std.fmt.allocPrint(arena, "{s}.staging", .{managed});
    const previous = try std.fmt.allocPrint(arena, "{s}.previous", .{managed});
    try cwd().createDirPath(io, std.Io.Dir.path.dirname(managed) orelse return error.InvalidPluginId);
    cwd().deleteTree(io, staging) catch {};
    try copyTree(io, arena, source_root, staging);

    const staged = try manifest.parse(arena, staging);
    if (staged.manifest == null) {
        cwd().deleteTree(io, staging) catch {};
        return error.PluginManifestInvalid;
    }

    const had_previous = pathExists(io, managed);
    if (had_previous) {
        cwd().deleteTree(io, previous) catch {};
        try cwd().rename(managed, cwd(), previous, io);
    }
    cwd().rename(staging, cwd(), managed, io) catch |err| {
        if (had_previous) cwd().rename(previous, cwd(), managed, io) catch {};
        return err;
    };

    const existing = try store.read(arena, home);
    var records: std.ArrayList(store.Record) = .empty;
    var replaced: ?store.Record = null;
    for (existing.plugins) |old| {
        if (std.mem.eql(u8, old.id, id)) {
            replaced = old;
            try records.append(arena, .{
                .id = id,
                .root = managed,
                .source = original_source,
                .enabled = old.enabled,
                .installed_at_ms = old.installed_at_ms,
                .updated_at_ms = now_ms,
                .mcp_servers = old.mcp_servers,
                .options = old.options,
                .source_kind = source_kind,
                .origin = options.origin,
                .catalog_id = options.catalog_id,
                .marketplace_source = options.marketplace_source orelse old.marketplace_source,
                .github = github_install,
            });
        } else {
            try records.append(arena, old);
        }
    }
    if (replaced == null) {
        try records.append(arena, .{
            .id = id,
            .root = managed,
            .source = original_source,
            .enabled = staged.manifest.?.default_enabled,
            .installed_at_ms = now_ms,
            .updated_at_ms = now_ms,
            .source_kind = source_kind,
            .origin = options.origin,
            .catalog_id = options.catalog_id,
            .marketplace_source = options.marketplace_source,
            .github = github_install,
        });
    }

    store.write(arena, home, .{ .plugins = records.items }) catch |err| {
        cwd().deleteTree(io, managed) catch {};
        if (had_previous) cwd().rename(previous, cwd(), managed, io) catch {};
        return err;
    };
    if (had_previous) cwd().deleteTree(io, previous) catch {};

    for (records.items) |record| {
        if (std.mem.eql(u8, record.id, id)) return materialize(arena, record);
    }
    return error.PluginNotFound;
}

pub fn setEnabled(arena: Allocator, home: []const u8, id: []const u8, enabled: bool, now_ms: i64) !void {
    const key = try manifest.normalizeId(arena, id);
    const existing = try store.read(arena, home);
    const records = try arena.dupe(store.Record, existing.plugins);
    for (records) |*record| {
        if (!std.mem.eql(u8, record.id, key)) continue;
        if (record.enabled == enabled) return;
        record.enabled = enabled;
        record.updated_at_ms = now_ms;
        try store.write(arena, home, .{ .plugins = records });
        return;
    }
    return error.PluginNotFound;
}

pub fn setMcpServerEnabled(arena: Allocator, home: []const u8, id: []const u8, server: []const u8, enabled: bool, now_ms: i64) !void {
    const key = try manifest.normalizeId(arena, id);
    const existing = try store.read(arena, home);
    const records = try arena.dupe(store.Record, existing.plugins);
    for (records) |*record| {
        if (!std.mem.eql(u8, record.id, key)) continue;
        const declared = (try manifest.parse(arena, record.root)).manifest orelse return error.McpServerNotDeclared;
        const servers = (try plugin_mcp_servers.declaredServers(arena, record.root, declared.mcp_servers)) orelse return error.McpServerNotDeclared;
        if (servers != .object or servers.object.get(server) == null) return error.McpServerNotDeclared;

        var states: std.ArrayList(store.McpServerState) = .empty;
        var found = false;
        for (record.mcp_servers) |state| {
            if (std.mem.eql(u8, state.name, server)) {
                found = true;
                try states.append(arena, .{ .name = server, .enabled = enabled });
            } else {
                try states.append(arena, state);
            }
        }
        if (!found) try states.append(arena, .{ .name = server, .enabled = enabled });
        record.mcp_servers = states.items;
        record.updated_at_ms = now_ms;
        try store.write(arena, home, .{ .plugins = records });
        return;
    }
    return error.PluginNotFound;
}

pub fn remove(arena: Allocator, home: []const u8, id: []const u8) !void {
    const key = try manifest.normalizeId(arena, id);
    const existing = try store.read(arena, home);
    var records: std.ArrayList(store.Record) = .empty;
    var removed: ?store.Record = null;
    for (existing.plugins) |record| {
        if (std.mem.eql(u8, record.id, key)) {
            removed = record;
        } else {
            try records.append(arena, record);
        }
    }
    if (removed == null) return error.PluginNotFound;
    try store.write(arena, home, .{ .plugins = records.items });
}

pub fn reload(arena: Allocator, home: []const u8, previous_ids: []const []const u8) !ReloadSummary {
    const plugins = try list(arena, home);
    var added: std.ArrayList([]const u8) = .empty;
    var errors: std.ArrayList(ReloadError) = .empty;
    for (plugins) |plugin| {
        if (!containsId(previous_ids, plugin.record.id)) try added.append(arena, plugin.record.id);
        if (plugin.load_error) |message| try errors.append(arena, .{ .id = plugin.record.id, .message = message });
    }
    var removed: std.ArrayList([]const u8) = .empty;
    for (previous_ids) |id| {
        var still_installed = false;
        for (plugins) |plugin| {
            if (std.mem.eql(u8, plugin.record.id, id)) still_installed = true;
        }
        if (!still_installed) try removed.append(arena, id);
    }
    return .{
        .added = try added.toOwnedSlice(arena),
        .removed = try removed.toOwnedSlice(arena),
        .errors = try errors.toOwnedSlice(arena),
    };
}

fn containsId(ids: []const []const u8, id: []const u8) bool {
    for (ids) |candidate| {
        if (std.mem.eql(u8, candidate, id)) return true;
    }
    return false;
}

fn pathExists(io: std.Io, path: []const u8) bool {
    cwd().access(io, path, .{}) catch return false;
    return true;
}

fn copyTree(io: std.Io, arena: Allocator, source: []const u8, dest: []const u8) !void {
    try cwd().createDirPath(io, dest);
    var from = try cwd().openDir(io, source, .{ .iterate = true });
    defer from.close(io);
    var entries = from.iterate();
    while (try entries.next(io)) |entry| {
        const from_path = try std.Io.Dir.path.join(arena, &.{ source, entry.name });
        const to_path = try std.Io.Dir.path.join(arena, &.{ dest, entry.name });
        switch (entry.kind) {
            .directory => try copyTree(io, arena, from_path, to_path),
            .file => try from.copyFile(entry.name, cwd(), to_path, io, .{}),
            else => {},
        }
    }
}

const testing = std.testing;

fn writeFixture(tmp: *testing.TmpDir, sub_path: []const u8, data: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |dir| try tmp.dir.createDirPath(testing.io, dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
}

fn fixturePlugin(tmp: *testing.TmpDir, name: []const u8) !void {
    const manifest_text = try std.fmt.allocPrint(testing.allocator, "{{\"name\":\"{s}\",\"version\":\"1\"}}", .{name});
    defer testing.allocator.free(manifest_text);
    try writeFixture(tmp, "src/kimi.plugin.json", manifest_text);
    try writeFixture(tmp, "src/SKILL.md", "---\nname: root\n---\n");
}

test "install records a plugin disabled when its manifest sets defaultEnabled false, and a reinstall keeps the user's choice" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "src/.claude-plugin/plugin.json", "{\"name\":\"quiet\",\"defaultEnabled\":false}");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const source = try std.Io.Dir.path.join(arena, &.{ base, "src" });

    const installed = try install(arena, home, source, 1, .{ .trusted = true });
    try testing.expect(!installed.record.enabled);

    try setEnabled(arena, home, "quiet", true, 2);
    const reinstalled = try install(arena, home, source, 3, .{ .trusted = true });
    try testing.expect(reinstalled.record.enabled);
}

test "install copies the plugin into the managed root and records it enabled" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixturePlugin(&tmp, "Acme.Tools");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const source = try std.Io.Dir.path.join(arena, &.{ base, "src" });

    const installed = try install(arena, home, source, 100, .{ .trusted = true });
    try testing.expectEqualStrings("acme.tools", installed.record.id);
    try testing.expect(installed.record.enabled);
    try testing.expect(installed.isOk());
    try testing.expect(std.mem.endsWith(u8, installed.record.root, "/.fx/plugins/managed/acme.tools"));
    try testing.expect(pathExists(testing.io, installed.record.root));

    const plugins = try list(arena, home);
    try testing.expectEqual(@as(usize, 1), plugins.len);
    try testing.expectEqualStrings("Acme.Tools", plugins[0].manifest.?.name);
}

test "install refuses relative sources and remote sources it cannot fetch" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    var offline: remote.CannedFetcher = .{ .replies = &.{} };
    try testing.expectError(error.RelativePluginSource, install(arena, home, "relative/path", 1, .{ .trusted = true }));
    try testing.expectError(error.PluginDownloadFailed, install(arena, home, "https://example.test/p.zip", 1, .{ .trusted = true, .fetcher = offline.fetcher() }));
    try testing.expectError(error.PluginDownloadFailed, install(arena, home, "https://github.com/acme/tools", 1, .{ .trusted = true, .fetcher = offline.fetcher() }));
    try testing.expectEqual(@as(usize, 0), (try list(arena, home)).len);
}

test "install from a zip URL extracts the archive, records the URL, and leaves no scratch directory" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    const zip_bytes = try archive.buildStoredZip(arena, &.{
        .{ .name = "zipped-1.0/kimi.plugin.json", .data = "{\"name\":\"Zipped\",\"version\":\"1.0\"}" },
        .{ .name = "zipped-1.0/SKILL.md", .data = "---\nname: root\n---\n" },
    });
    var canned: remote.CannedFetcher = .{ .replies = &.{
        .{ .url = "https://example.test/zipped.zip", .body = zip_bytes },
    } };

    const installed = try install(arena, home, " https://example.test/zipped.zip ", 5, .{ .trusted = true, .fetcher = canned.fetcher() });
    try testing.expectEqualStrings("zipped", installed.record.id);
    try testing.expectEqualStrings("https://example.test/zipped.zip", installed.record.source);
    try testing.expectEqualStrings(store.source_kind_zip_url, installed.record.source_kind);
    try testing.expect(installed.isOk());
    try testing.expect(pathExists(testing.io, try std.Io.Dir.path.join(arena, &.{ installed.record.root, "SKILL.md" })));
    try testing.expect(!pathExists(testing.io, try std.Io.Dir.path.join(arena, &.{ home, ".fx/plugins/tmp/fetch-5" })));
}

test "install from a github repo pins the resolved commit and records the release tag" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    const zip_bytes = try archive.buildStoredZip(arena, &.{
        .{ .name = "tools-abc/kimi.plugin.json", .data = "{\"name\":\"tools\"}" },
    });
    const sha = "0123456789abcdef0123456789abcdef01234567";
    var canned: remote.CannedFetcher = .{ .replies = &.{
        .{ .url = "https://api.github.com/repos/acme/tools/releases/latest", .body = "{\"tag_name\":\"v2.0.0\"}" },
        .{ .url = "https://github.com/acme/tools/commits/v2.0.0.atom", .body = "Grit::Commit/" ++ sha },
        .{ .url = "https://codeload.github.com/acme/tools/zip/" ++ sha, .body = zip_bytes },
    } };

    const installed = try install(arena, home, "https://github.com/acme/tools", 7, .{ .trusted = true, .fetcher = canned.fetcher() });
    try testing.expectEqualStrings("tools", installed.record.id);
    try testing.expectEqualStrings(store.source_kind_github, installed.record.source_kind);
    const github = installed.record.github orelse return error.TestExpectedGithubInstall;
    try testing.expectEqualStrings("acme", github.owner);
    try testing.expectEqualStrings("tag", github.ref_kind);
    try testing.expectEqualStrings("v2.0.0", github.ref_value);
    try testing.expectEqualStrings(sha, github.installed_sha.?);

    const reloaded = try load(arena, home);
    try testing.expectEqualStrings(sha, reloaded[0].record.github.?.installed_sha.?);
}

test "a marketplace install needs a zip URL and a matching sha256" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixturePlugin(&tmp, "local");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const source = try std.Io.Dir.path.join(arena, &.{ base, "src" });

    const zip_bytes = try archive.buildStoredZip(arena, &.{
        .{ .name = "kimi.plugin.json", .data = "{\"name\":\"catalogued\"}" },
    });
    var canned: remote.CannedFetcher = .{ .replies = &.{
        .{ .url = "https://example.test/c.zip", .body = zip_bytes },
    } };
    const right = remote.sha256Hex(zip_bytes);
    const wrong = "1111111111111111111111111111111111111111111111111111111111111111";

    try testing.expectError(error.MarketplaceInstallNeedsZipUrl, install(arena, home, source, 1, .{ .trusted = true, .expected_sha256 = &right }));
    try testing.expectError(error.PluginChecksumMismatch, install(arena, home, "https://example.test/c.zip", 2, .{ .trusted = true, .expected_sha256 = wrong, .fetcher = canned.fetcher() }));
    try testing.expectEqual(@as(usize, 0), (try list(arena, home)).len);

    const installed = try install(arena, home, "https://example.test/c.zip", 3, .{
        .trusted = true,
        .expected_sha256 = &right,
        .expected_id = "catalogued",
        .origin = store.origin_marketplace,
        .catalog_id = "catalogued",
        .marketplace_source = "https://example.test/catalog.json",
        .fetcher = canned.fetcher(),
    });
    try testing.expectEqualStrings(store.origin_marketplace, installed.record.origin);
    try testing.expectEqualStrings("catalogued", installed.record.catalog_id.?);
    try testing.expectEqualStrings("https://example.test/catalog.json", installed.record.marketplace_source.?);
}

test "install without trust copies nothing and reports PluginTrustRequired" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixturePlugin(&tmp, "Acme.Tools");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const source = try std.Io.Dir.path.join(arena, &.{ base, "src" });

    try testing.expectError(error.PluginTrustRequired, install(arena, home, source, 1, .{}));
    try testing.expectEqual(@as(usize, 0), (try list(arena, home)).len);
    try testing.expect(!pathExists(testing.io, try store.managedRoot(arena, home, "acme.tools")));
}

test "install checks the expected id before anything is copied" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixturePlugin(&tmp, "Acme.Tools");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const source = try std.Io.Dir.path.join(arena, &.{ base, "src" });

    try testing.expectError(error.PluginIdMismatch, install(arena, home, source, 1, .{ .trusted = true, .expected_id = "other.tools" }));
    try testing.expectEqual(@as(usize, 0), (try list(arena, home)).len);
    const installed = try install(arena, home, source, 1, .{ .trusted = true, .expected_id = "ACME.tools" });
    try testing.expectEqualStrings("acme.tools", installed.record.id);
}

test "install of a directory without a manifest leaves the store untouched" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "src/readme.txt", "no manifest here");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const source = try std.Io.Dir.path.join(arena, &.{ base, "src" });

    try testing.expectError(error.PluginManifestInvalid, install(arena, home, source, 1, .{ .trusted = true }));
    try testing.expectEqual(@as(usize, 0), (try list(arena, home)).len);
}

test "reinstall keeps the enabled flag and the original position" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixturePlugin(&tmp, "first");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const source = try std.Io.Dir.path.join(arena, &.{ base, "src" });

    _ = try install(arena, home, source, 1, .{ .trusted = true });
    try setEnabled(arena, home, "FIRST", false, 2);
    _ = try install(arena, home, source, 3, .{ .trusted = true });

    const plugins = try load(arena, home);
    try testing.expectEqual(@as(usize, 1), plugins.len);
    try testing.expect(!plugins[0].record.enabled);
    try testing.expectEqual(@as(i64, 1), plugins[0].record.installed_at_ms);
    try testing.expectEqual(@as(i64, 3), plugins[0].record.updated_at_ms);
}

test "load and list leave out a marketplace plugin whose catalog entry does not offer this host" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixturePlugin(&tmp, "hosted");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const source = try std.Io.Dir.path.join(arena, &.{ base, "src" });

    _ = try install(arena, home, source, 1, .{ .trusted = true, .origin = store.origin_marketplace, .catalog_id = "hosted" });
    try testing.expectEqual(@as(usize, 1), (try list(arena, home)).len);

    const cloud_only = [_]marketplace.Platform{.cloud};
    const elsewhere = [_]marketplace.Entry{.{ .id = "hosted", .display_name = "Hosted", .source = source, .platforms = &cloud_only }};
    try testing.expect(try availability.update(arena, home, .{ .source = "/srv/catalog.json", .plugins = &elsewhere }, 2));
    try testing.expectEqual(@as(usize, 0), (try list(arena, home)).len);
    try testing.expectEqual(@as(usize, 0), (try load(arena, home)).len);
    try testing.expectEqual(@as(usize, 1), (try store.read(arena, home)).plugins.len);

    const everywhere = [_]marketplace.Entry{.{ .id = "hosted", .display_name = "Hosted", .source = source }};
    try testing.expect(try availability.update(arena, home, .{ .source = "/srv/catalog.json", .plugins = &everywhere }, 3));
    try testing.expectEqual(@as(usize, 1), (try list(arena, home)).len);
}

test "setEnabled persists the flag and reports unknown plugins" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixturePlugin(&tmp, "toggle");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const source = try std.Io.Dir.path.join(arena, &.{ base, "src" });

    _ = try install(arena, home, source, 1, .{ .trusted = true });
    try setEnabled(arena, home, "toggle", false, 2);
    const plugins = try list(arena, home);
    try testing.expect(!plugins[0].record.enabled);
    try testing.expectError(error.PluginNotFound, setEnabled(arena, home, "missing", true, 3));
}

test "remove drops the record and leaves the managed copy for sessions that still run from it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixturePlugin(&tmp, "gone");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const source = try std.Io.Dir.path.join(arena, &.{ base, "src" });

    const installed = try install(arena, home, source, 1, .{ .trusted = true });
    try remove(arena, home, "gone");
    try testing.expectEqual(@as(usize, 0), (try list(arena, home)).len);
    try testing.expect(pathExists(testing.io, installed.record.root));
    try testing.expectError(error.PluginNotFound, remove(arena, home, "gone"));
    const reinstalled = try install(arena, home, source, 2, .{ .trusted = true });
    try testing.expectEqualStrings(installed.record.root, reinstalled.record.root);
    try testing.expect(!pathExists(testing.io, try std.fmt.allocPrint(arena, "{s}.previous", .{installed.record.root})));
}

test "load reports a plugin whose managed copy went missing without failing the rest" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixturePlugin(&tmp, "broken");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const source = try std.Io.Dir.path.join(arena, &.{ base, "src" });

    const installed = try install(arena, home, source, 1, .{ .trusted = true });
    try cwd().deleteTree(testing.io, installed.record.root);
    const plugins = try list(arena, home);
    try testing.expectEqual(@as(usize, 1), plugins.len);
    try testing.expect(!plugins[0].isOk());
    try testing.expect(plugins[0].load_error != null);
}

test "list sorts by id and reload names added, removed, and broken plugins" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixturePlugin(&tmp, "zeta");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const source = try std.Io.Dir.path.join(arena, &.{ base, "src" });

    _ = try install(arena, home, source, 1, .{ .trusted = true });
    const previous = [_][]const u8{"old"};
    const summary = try reload(arena, home, &previous);
    try testing.expectEqual(@as(usize, 1), summary.added.len);
    try testing.expectEqualStrings("zeta", summary.added[0]);
    try testing.expectEqual(@as(usize, 1), summary.removed.len);
    try testing.expectEqualStrings("old", summary.removed[0]);
    try testing.expectEqual(@as(usize, 0), summary.errors.len);
}

test "setMcpServerEnabled persists per-server state for declared servers only" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "src/kimi.plugin.json", "{\"name\":\"withmcp\",\"mcpServers\":{\"docs\":{\"url\":\"https://mcp.example.test/mcp\"}}}");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const source = try std.Io.Dir.path.join(arena, &.{ base, "src" });

    _ = try install(arena, home, source, 1, .{ .trusted = true });
    try setMcpServerEnabled(arena, home, "withmcp", "docs", false, 2);
    const plugins = try list(arena, home);
    try testing.expectEqual(@as(usize, 1), plugins[0].record.mcp_servers.len);
    try testing.expect(!plugins[0].record.mcp_servers[0].enabled);
    try testing.expectError(error.McpServerNotDeclared, setMcpServerEnabled(arena, home, "withmcp", "other", true, 3));
}

test "hook definitions merge configured hooks before enabled plugin hooks with the plugin root as cwd" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "src/kimi.plugin.json", "{\"name\":\"hooky\",\"hooks\":[{\"event\":\"PreToolUse\",\"command\":\"./check.sh\"}]}");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const source = try std.Io.Dir.path.join(arena, &.{ base, "src" });

    _ = try install(arena, home, source, 1, .{ .trusted = true });
    const plugins = try list(arena, home);
    const configured_command = try arena.dupe(u8, "echo done");
    const configured = [_]external.Definition{.{ .event = .Stop, .command = configured_command }};

    const merged = try hookDefinitions(testing.allocator, home, &configured, plugins);
    defer external.freeDefinitions(testing.allocator, merged);
    try testing.expectEqual(@as(usize, 2), merged.len);
    try testing.expectEqual(external.Event.Stop, merged[0].event);
    try testing.expectEqualStrings("echo done", merged[0].command);
    try testing.expect(merged[0].cwd == null);
    try testing.expectEqual(external.Event.PreToolUse, merged[1].event);
    try testing.expectEqualStrings("./check.sh", merged[1].command);
    try testing.expectEqualStrings(plugins[0].record.root, merged[1].cwd.?);
    try testing.expectEqual(@as(usize, 0), merged[0].env.len);
    const profile_root = try profile_paths.rootDir(arena, home);
    try testing.expectEqual(@as(usize, 6), merged[1].env.len);
    try testing.expectEqualStrings("FX_HOME", merged[1].env[0].name);
    try testing.expectEqualStrings(profile_root, merged[1].env[0].value);
    try testing.expectEqualStrings("KIMI_CODE_HOME", merged[1].env[1].name);
    try testing.expectEqualStrings(profile_root, merged[1].env[1].value);
    try testing.expectEqualStrings("FX_PLUGIN_ROOT", merged[1].env[2].name);
    try testing.expectEqualStrings(plugins[0].record.root, merged[1].env[2].value);
    try testing.expectEqualStrings("KIMI_PLUGIN_ROOT", merged[1].env[3].name);
    try testing.expectEqualStrings(plugins[0].record.root, merged[1].env[3].value);
    try testing.expectEqualStrings("CLAUDE_PLUGIN_ROOT", merged[1].env[4].name);
    try testing.expectEqualStrings(plugins[0].record.root, merged[1].env[4].value);
    try testing.expectEqualStrings("CLAUDE_PLUGIN_DATA", merged[1].env[5].name);
    try testing.expect(std.mem.endsWith(u8, merged[1].env[5].value, "/plugins/data/hooky"));
}

test "a session plugin directory loads without an install and stands in for an installed plugin of the same id" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixturePlugin(&tmp, "Acme.Tools");
    try writeFixture(&tmp, "dev/.claude-plugin/plugin.json", "{\"name\":\"acme.tools\",\"version\":\"2-dev\"}");
    try writeFixture(&tmp, "dev/skills/hello/SKILL.md", "---\ndescription: Greets\n---\nSay hello.");
    try writeFixture(&tmp, "other/.claude-plugin/plugin.json", "{\"name\":\"other\"}");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    _ = try install(arena, home, try std.Io.Dir.path.join(arena, &.{ base, "src" }), 1, .{ .trusted = true });
    const dev = try std.Io.Dir.path.join(arena, &.{ base, "dev" });
    const other = try std.Io.Dir.path.join(arena, &.{ base, "other" });

    clearSessionPluginDirs();
    defer clearSessionPluginDirs();
    try addSessionPluginDir(dev);
    try addSessionPluginDir(dev);
    try addSessionPluginDir(other);

    const plugins = try list(arena, home);
    try testing.expectEqual(@as(usize, 2), plugins.len);
    try testing.expectEqualStrings("acme.tools", plugins[0].record.id);
    try testing.expectEqualStrings(dev, plugins[0].record.root);
    try testing.expectEqualStrings("2-dev", plugins[0].manifest.?.version.?);
    try testing.expectEqual(@as(usize, 1), plugins[0].manifest.?.skills.len);
    try testing.expectEqualStrings("other", plugins[1].record.id);

    clearSessionPluginDirs();
    const installed_only = try list(arena, home);
    try testing.expectEqual(@as(usize, 1), installed_only.len);
    try testing.expect(std.mem.endsWith(u8, installed_only[0].record.root, "/plugins/managed/acme.tools"));
    var overlong_dir: [max_session_plugin_dir_bytes + 1]u8 = undefined;
    @memset(&overlong_dir, 'x');
    try testing.expectError(error.SessionPluginDirTooLong, addSessionPluginDir(&overlong_dir));
}

test "plugin hooks get userConfig values as CLAUDE_PLUGIN_OPTION variables and in their commands" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "src/.claude-plugin/plugin.json", "{\"name\":\"configured\",\"userConfig\":{\"api_endpoint\":{\"default\":\"https://default.example\"},\"region\":{},\"api_token\":{\"sensitive\":true}}}");
    try writeFixture(&tmp, "src/hooks/hooks.json", "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"notify ${user_config.api_endpoint} ${user_config.region}\"}]}]}}");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const source = try std.Io.Dir.path.join(arena, &.{ base, "src" });
    _ = try install(arena, home, source, 1, .{ .trusted = true });

    const defaults = try hookDefinitions(testing.allocator, home, &.{}, try list(arena, home));
    defer external.freeDefinitions(testing.allocator, defaults);
    try testing.expectEqualStrings("notify https://default.example ${user_config.region}", defaults[0].command);
    try testing.expectEqual(@as(usize, 7), defaults[0].env.len);
    try testing.expectEqualStrings("CLAUDE_PLUGIN_OPTION_API_ENDPOINT", defaults[0].env[6].name);
    try testing.expectEqualStrings("https://default.example", defaults[0].env[6].value);

    try setOption(arena, home, "configured", "api_endpoint", "https://set.example", 2);
    try setOption(arena, home, "configured", "region", "eu", 3);
    try testing.expectError(error.PluginOptionNotDeclared, setOption(arena, home, "configured", "unknown", "x", 4));
    try testing.expectError(error.PluginOptionSensitive, setOption(arena, home, "configured", "api_token", "secret", 4));
    try testing.expectError(error.PluginNotFound, setOption(arena, home, "absent", "region", "eu", 4));

    const stored = try hookDefinitions(testing.allocator, home, &.{}, try list(arena, home));
    defer external.freeDefinitions(testing.allocator, stored);
    try testing.expectEqualStrings("notify https://set.example eu", stored[0].command);
    try testing.expectEqual(@as(usize, 8), stored[0].env.len);
    try testing.expectEqualStrings("CLAUDE_PLUGIN_OPTION_REGION", stored[0].env[7].name);
    try testing.expectEqualStrings("eu", stored[0].env[7].value);
}

test "runtime hook definitions add the installed plugin hooks to the configured hooks" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "src/kimi.plugin.json", "{\"name\":\"hooky\",\"hooks\":[{\"event\":\"SessionStart\",\"command\":\"./start.sh\"}]}");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const source = try std.Io.Dir.path.join(arena, &.{ base, "src" });
    _ = try install(arena, home, source, 1, .{ .trusted = true });

    const plugin_only = (try runtimeHookDefinitions(testing.allocator, home, null)) orelse return error.TestExpectedPluginHooks;
    defer external.freeDefinitions(testing.allocator, plugin_only);
    try testing.expectEqual(@as(usize, 1), plugin_only.len);
    try testing.expectEqual(external.Event.SessionStart, plugin_only[0].event);
    try testing.expect(plugin_only[0].cwd != null);
    try testing.expectEqual(@as(usize, 6), plugin_only[0].env.len);
    try testing.expect(pathExists(testing.io, try store.dataDir(arena, home, "hooky")));

    const configured_command = try arena.dupe(u8, "echo done");
    const configured = [_]external.Definition{.{ .event = .Stop, .command = configured_command }};
    const merged = (try runtimeHookDefinitions(testing.allocator, home, &configured)) orelse return error.TestExpectedMergedHooks;
    defer external.freeDefinitions(testing.allocator, merged);
    try testing.expectEqual(@as(usize, 2), merged.len);
    try testing.expectEqualStrings("echo done", merged[0].command);
    try testing.expectEqualStrings("./start.sh", merged[1].command);
}

test "runtime hook definitions follow the order plugins were installed in, not their ids" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "zeta/kimi.plugin.json", "{\"name\":\"zeta\",\"hooks\":[{\"event\":\"Stop\",\"command\":\"./zeta.sh\"}]}");
    try writeFixture(&tmp, "alpha/kimi.plugin.json", "{\"name\":\"alpha\",\"hooks\":[{\"event\":\"Stop\",\"command\":\"./alpha.sh\"}]}");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    _ = try install(arena, home, try std.Io.Dir.path.join(arena, &.{ base, "zeta" }), 1, .{ .trusted = true });
    _ = try install(arena, home, try std.Io.Dir.path.join(arena, &.{ base, "alpha" }), 2, .{ .trusted = true });

    const in_store_order = try load(arena, home);
    try testing.expectEqualStrings("zeta", in_store_order[0].record.id);
    try testing.expectEqualStrings("alpha", in_store_order[1].record.id);
    const sorted = try list(arena, home);
    try testing.expectEqualStrings("alpha", sorted[0].record.id);

    const merged = (try runtimeHookDefinitions(testing.allocator, home, null)) orelse return error.TestExpectedPluginHooks;
    defer external.freeDefinitions(testing.allocator, merged);
    try testing.expectEqual(@as(usize, 2), merged.len);
    try testing.expectEqualStrings("./zeta.sh", merged[0].command);
    try testing.expectEqualStrings("./alpha.sh", merged[1].command);
}

test "runtime hook definitions are absent without configured hooks, plugins or a home" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(base);
    try testing.expect((try runtimeHookDefinitions(testing.allocator, base, null)) == null);
    try testing.expect((try runtimeHookDefinitions(testing.allocator, null, null)) == null);

    const none: []const external.Definition = &.{};
    const configured_empty = (try runtimeHookDefinitions(testing.allocator, null, none)) orelse return error.TestExpectedEmptyHooks;
    defer external.freeDefinitions(testing.allocator, configured_empty);
    try testing.expectEqual(@as(usize, 0), configured_empty.len);
}

test "hook definitions skip the hooks of disabled plugins and keep the configured hooks" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "src/kimi.plugin.json", "{\"name\":\"hooky\",\"hooks\":[{\"event\":\"PreToolUse\",\"command\":\"./check.sh\"}]}");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const source = try std.Io.Dir.path.join(arena, &.{ base, "src" });

    _ = try install(arena, home, source, 1, .{ .trusted = true });
    try setEnabled(arena, home, "hooky", false, 2);
    const plugins = try list(arena, home);
    const configured_command = try arena.dupe(u8, "echo done");
    const configured = [_]external.Definition{.{ .event = .Stop, .command = configured_command }};

    const merged = try hookDefinitions(testing.allocator, home, &configured, plugins);
    defer external.freeDefinitions(testing.allocator, merged);
    try testing.expectEqual(@as(usize, 1), merged.len);
    try testing.expectEqualStrings("echo done", merged[0].command);
}

test "hook definitions skip the hooks of plugins whose manifest failed to load" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, "src/kimi.plugin.json", "{\"name\":\"hooky\",\"hooks\":[{\"event\":\"PreToolUse\",\"command\":\"./check.sh\"}]}");
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const source = try std.Io.Dir.path.join(arena, &.{ base, "src" });

    const installed = try install(arena, home, source, 1, .{ .trusted = true });
    try cwd().deleteTree(testing.io, installed.record.root);
    const plugins = try list(arena, home);
    const none: []const external.Definition = &.{};

    const merged = try hookDefinitions(testing.allocator, home, none, plugins);
    defer external.freeDefinitions(testing.allocator, merged);
    try testing.expectEqual(@as(usize, 0), merged.len);
}
