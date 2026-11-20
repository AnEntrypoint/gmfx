const std = @import("std");
const plugin_manager = @import("../plugins/manager.zig");
const plugin_validate = @import("../plugins/validate.zig");
const plugin_marketplace = @import("../plugins/marketplace.zig");
const plugin_mcp_servers = @import("../plugins/mcp_servers.zig");
const plugin_remote = @import("../plugins/remote.zig");
const plugin_store = @import("../plugins/store.zig");
const plugin_updates = @import("../plugins/updates.zig");
const plugin_manifest = @import("../plugins/manifest.zig");
const plugin_commands = @import("../plugins/commands.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Outcome = struct {
    tone: types.NoticeTone,
    body: []const u8,
};

pub const McpAction = struct {
    enabled: bool,
    id: []const u8,
    server: []const u8,
};

pub const ValidateAction = struct {
    path: []const u8,
    strict: bool,
};

pub const OptionAction = struct {
    id: []const u8,
    key: []const u8,
    value: []const u8,
};

pub const InstallAction = struct {
    source: []const u8,
    trusted: bool,
};

pub const MarketplaceAction = struct {
    source: []const u8 = "",
    install_id: ?[]const u8 = null,
    trusted: bool = false,
};

pub const RemoveAction = struct {
    id: []const u8,
    confirmed: bool,
};

pub const Env = struct {
    fetcher: plugin_remote.Fetcher = plugin_remote.live,
    work_dir: ?[]const u8 = null,
};

const strict_word = "strict";
const trust_flag = "--trust";
const confirm_flag = "--yes";

pub const Action = union(enum) {
    list,
    reload,
    enable: []const u8,
    disable: []const u8,
    remove: RemoveAction,
    install: InstallAction,
    marketplace: MarketplaceAction,
    info: []const u8,
    updates,
    update: []const u8,
    commands,
    mcp: McpAction,
    validate: ValidateAction,
    option: OptionAction,
    dir: []const u8,
    unknown: []const u8,
};

const usage_hint = "Use list, commands, install SOURCE, marketplace [SOURCE], marketplace install ID [SOURCE], info ID, updates, update ID, reload, enable ID, disable ID, remove ID, mcp enable|disable ID SERVER, option ID KEY VALUE, validate PATH [strict], or dir PATH.";

pub fn parse(rest: []const u8) Action {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0) return .list;
    const verb_end = std.mem.findAny(u8, trimmed, " \t") orelse trimmed.len;
    const verb = trimmed[0..verb_end];
    const tail = std.mem.trim(u8, trimmed[verb_end..], " \t");
    if (std.mem.eql(u8, verb, "list") and tail.len == 0) return .list;
    if (std.mem.eql(u8, verb, "reload") and tail.len == 0) return .reload;
    if (std.mem.eql(u8, verb, "enable") and isSingleWord(tail)) return .{ .enable = tail };
    if (std.mem.eql(u8, verb, "disable") and isSingleWord(tail)) return .{ .disable = tail };
    if (std.mem.eql(u8, verb, "remove")) return parseRemove(tail) orelse .{ .unknown = trimmed };
    if (std.mem.eql(u8, verb, "install")) return parseInstall(tail) orelse .{ .unknown = trimmed };
    if (std.mem.eql(u8, verb, "marketplace")) return parseMarketplace(tail) orelse .{ .unknown = trimmed };
    if (std.mem.eql(u8, verb, "info") and tail.len == 0) return .list;
    if (std.mem.eql(u8, verb, "info") and isSingleWord(tail)) return .{ .info = tail };
    if (std.mem.eql(u8, verb, "updates") and tail.len == 0) return .updates;
    if (std.mem.eql(u8, verb, "commands") and tail.len == 0) return .commands;
    if (std.mem.eql(u8, verb, "update") and isSingleWord(tail)) return .{ .update = tail };
    if (std.mem.eql(u8, verb, "mcp")) return parseMcp(tail) orelse .{ .unknown = trimmed };
    if (std.mem.eql(u8, verb, "validate")) return parseValidate(tail) orelse .{ .unknown = trimmed };
    if (std.mem.eql(u8, verb, "option")) return parseOption(tail) orelse .{ .unknown = trimmed };
    if (std.mem.eql(u8, verb, "dir") and tail.len > 0) return .{ .dir = tail };
    return .{ .unknown = trimmed };
}

fn isSingleWord(text: []const u8) bool {
    return text.len > 0 and std.mem.findAny(u8, text, " \t") == null;
}

const Flagged = struct {
    rest: []const u8,
    present: bool,
};

fn isGap(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn takeFlag(text: []const u8, flag: []const u8) Flagged {
    if (std.mem.eql(u8, text, flag)) return .{ .rest = "", .present = true };
    if (std.mem.startsWith(u8, text, flag) and isGap(text[flag.len])) {
        return .{ .rest = std.mem.trim(u8, text[flag.len..], " \t"), .present = true };
    }
    if (std.mem.endsWith(u8, text, flag) and isGap(text[text.len - flag.len - 1])) {
        return .{ .rest = std.mem.trim(u8, text[0 .. text.len - flag.len], " \t"), .present = true };
    }
    return .{ .rest = text, .present = false };
}

fn parseRemove(tail: []const u8) ?Action {
    const flagged = takeFlag(tail, confirm_flag);
    if (!isSingleWord(flagged.rest)) return null;
    return .{ .remove = .{ .id = flagged.rest, .confirmed = flagged.present } };
}

fn parseInstall(tail: []const u8) ?Action {
    const flagged = takeFlag(tail, trust_flag);
    if (flagged.rest.len == 0) return null;
    return .{ .install = .{ .source = flagged.rest, .trusted = flagged.present } };
}

fn parseMarketplace(tail: []const u8) ?Action {
    const install_word = "install";
    const is_install = std.mem.eql(u8, tail, install_word) or (std.mem.startsWith(u8, tail, install_word) and isGap(tail[install_word.len]));
    if (!is_install) return .{ .marketplace = .{ .source = tail } };
    const flagged = takeFlag(std.mem.trim(u8, tail[install_word.len..], " \t"), trust_flag);
    if (flagged.rest.len == 0) return null;
    const id_end = std.mem.findAny(u8, flagged.rest, " \t") orelse flagged.rest.len;
    return .{ .marketplace = .{
        .source = std.mem.trim(u8, flagged.rest[id_end..], " \t"),
        .install_id = flagged.rest[0..id_end],
        .trusted = flagged.present,
    } };
}

fn parseMcp(tail: []const u8) ?Action {
    var words = std.mem.tokenizeAny(u8, tail, " \t");
    const verb = words.next() orelse return null;
    const id = words.next() orelse return null;
    const server = words.next() orelse return null;
    if (words.next() != null) return null;
    if (std.mem.eql(u8, verb, "enable")) return .{ .mcp = .{ .enabled = true, .id = id, .server = server } };
    if (std.mem.eql(u8, verb, "disable")) return .{ .mcp = .{ .enabled = false, .id = id, .server = server } };
    return null;
}

fn parseValidate(tail: []const u8) ?Action {
    if (tail.len == 0) return null;
    if (std.mem.eql(u8, tail, strict_word)) return null;
    const last_gap = std.mem.findLastAny(u8, tail, " \t") orelse return .{ .validate = .{ .path = tail, .strict = false } };
    if (!std.mem.eql(u8, tail[last_gap + 1 ..], strict_word)) return .{ .validate = .{ .path = tail, .strict = false } };
    return .{ .validate = .{ .path = std.mem.trim(u8, tail[0..last_gap], " \t"), .strict = true } };
}

fn parseOption(tail: []const u8) ?Action {
    const id_end = std.mem.findAny(u8, tail, " \t") orelse return null;
    const after_id = std.mem.trim(u8, tail[id_end..], " \t");
    const key_end = std.mem.findAny(u8, after_id, " \t") orelse return null;
    const value = std.mem.trim(u8, after_id[key_end..], " \t");
    if (value.len == 0) return null;
    return .{ .option = .{ .id = tail[0..id_end], .key = after_id[0..key_end], .value = value } };
}

fn sessionDirOutcome(arena: Allocator, path: []const u8) !Outcome {
    const root = std.Io.Dir.cwd().realPathFileAlloc(io_mod.getIo(), path, arena) catch return .{
        .tone = .@"error",
        .body = try std.fmt.allocPrint(arena, "Could not load {s}: no such directory.", .{path}),
    };
    const report = try plugin_validate.validate(arena, root, false);
    if (report.outcome == .failed) return .{ .tone = .@"error", .body = try report.render(arena) };
    plugin_manager.addSessionPluginDir(root) catch |err| return .{
        .tone = .@"error",
        .body = try std.fmt.allocPrint(arena, "Could not load {s}: {s}.", .{ path, switch (err) {
            error.TooManySessionPluginDirs => "this session already loads the most plugin directories it can",
            error.SessionPluginDirTooLong => "the path is too long",
        } }),
    };
    return .{
        .tone = .success,
        .body = try std.fmt.allocPrint(arena, "Loaded the plugin at {s} for this session, without installing it. Its commands and agents are available now; run /new to apply its hooks and MCP servers.", .{root}),
    };
}

fn validateOutcome(arena: Allocator, action: ValidateAction) !Outcome {
    const root = std.Io.Dir.cwd().realPathFileAlloc(io_mod.getIo(), action.path, arena) catch return .{
        .tone = .@"error",
        .body = try std.fmt.allocPrint(arena, "Could not validate {s}: no such directory.", .{action.path}),
    };
    const report = try plugin_validate.validate(arena, root, action.strict);
    const tone: types.NoticeTone = switch (report.outcome) {
        .passed => .success,
        .passed_with_warnings => .warning,
        .failed => .@"error",
    };
    return .{ .tone = tone, .body = try report.render(arena) };
}

fn setOptionOutcome(arena: Allocator, home: []const u8, action: OptionAction, now_ms: i64) !Outcome {
    plugin_manager.setOption(arena, home, action.id, action.key, action.value, now_ms) catch |err| return failure(
        arena,
        "set an option for",
        action.id,
        err,
    );
    return .{
        .tone = .success,
        .body = try std.fmt.allocPrint(arena, "Set {s} for {s}. Run /new to apply.", .{ action.key, action.id }),
    };
}

pub fn run(arena: Allocator, home: []const u8, rest: []const u8, now_ms: i64) !Outcome {
    return runWith(arena, home, rest, now_ms, .{});
}

pub fn runWith(arena: Allocator, home: []const u8, rest: []const u8, now_ms: i64, env: Env) !Outcome {
    rememberLoadedPlugins(arena, home);
    return switch (parse(rest)) {
        .list => .{ .tone = .information, .body = try listBody(arena, home) },
        .reload => try reloadOutcome(arena, home),
        .enable => |id| try setEnabledOutcome(arena, home, id, true, now_ms),
        .disable => |id| try setEnabledOutcome(arena, home, id, false, now_ms),
        .remove => |action| try removeOutcome(arena, home, action),
        .install => |action| try installOutcome(arena, home, action, now_ms, env),
        .marketplace => |action| try marketplaceOutcome(arena, home, action, now_ms, env),
        .info => |id| try infoOutcome(arena, home, id),
        .updates => try updatesOutcome(arena, home, now_ms, env),
        .commands => .{ .tone = .information, .body = try commandsBody(arena, home) },
        .update => |id| try updateOutcome(arena, home, id, now_ms, env),
        .mcp => |action| try setMcpOutcome(arena, home, action, now_ms),
        .validate => |action| try validateOutcome(arena, action),
        .option => |action| try setOptionOutcome(arena, home, action, now_ms),
        .dir => |path| try sessionDirOutcome(arena, path),
        .unknown => |text| try unknownOutcome(arena, home, text),
    };
}

fn unknownOutcome(arena: Allocator, home: []const u8, text: []const u8) !Outcome {
    if (isSingleWord(text)) {
        if (try installedPlugin(arena, home, text)) |_| return infoOutcome(arena, home, text);
    }
    return .{
        .tone = .@"error",
        .body = try std.fmt.allocPrint(arena, "Unknown /plugins action: {s}. {s}", .{ text, usage_hint }),
    };
}

fn installedPlugin(arena: Allocator, home: []const u8, id: []const u8) !?plugin_manager.Plugin {
    if (!plugin_manifest.isValidName(id)) return null;
    const key = try plugin_manifest.normalizeId(arena, id);
    const plugins = plugin_manager.list(arena, home) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    for (plugins) |plugin| {
        if (std.mem.eql(u8, plugin.record.id, key)) return plugin;
    }
    return null;
}

var loaded_ids_snapshot: ?[]const u8 = null;
const snapshot_allocator = std.heap.page_allocator;

pub fn forgetLoadedPlugins() void {
    if (loaded_ids_snapshot) |snapshot| snapshot_allocator.free(snapshot);
    loaded_ids_snapshot = null;
}

fn rememberLoadedPlugins(arena: Allocator, home: []const u8) void {
    if (loaded_ids_snapshot != null) return;
    replaceLoadedPlugins(arena, home);
}

fn replaceLoadedPlugins(arena: Allocator, home: []const u8) void {
    const plugins = plugin_manager.list(arena, home) catch return;
    var joined: std.ArrayList(u8) = .empty;
    for (plugins) |plugin| {
        joined.appendSlice(arena, plugin.record.id) catch return;
        joined.append(arena, '\n') catch return;
    }
    const copy = snapshot_allocator.dupe(u8, joined.items) catch return;
    forgetLoadedPlugins();
    loaded_ids_snapshot = copy;
}

fn loadedPluginIds(arena: Allocator) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, loaded_ids_snapshot orelse "", '\n');
    while (lines.next()) |id| try ids.append(arena, try arena.dupe(u8, id));
    return ids.toOwnedSlice(arena);
}

fn workDir(arena: Allocator, env: Env) ![]const u8 {
    if (env.work_dir) |dir| return dir;
    const current: []const u8 = std.Io.Dir.cwd().realPathFileAlloc(io_mod.getIo(), ".", arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return "/",
    };
    return current;
}

fn resolveInstallSource(arena: Allocator, home: []const u8, source: []const u8, env: Env) ![]const u8 {
    if (std.mem.startsWith(u8, source, "http://") or std.mem.startsWith(u8, source, "https://")) return source;
    return plugin_marketplace.resolveLocalPath(arena, source, try workDir(arena, env), home);
}

fn installOutcome(arena: Allocator, home: []const u8, action: InstallAction, now_ms: i64, env: Env) !Outcome {
    const source = try resolveInstallSource(arena, home, action.source, env);
    if (!action.trusted and !plugin_marketplace.isOfficialSource(source)) return .{
        .tone = .warning,
        .body = try std.fmt.allocPrint(
            arena,
            "Install a plugin from {s}? A plugin can run hooks, MCP servers and commands on this machine, so install only from a source you trust. To go ahead, run /plugins install {s} {s}",
            .{ source, trust_flag, action.source },
        ),
    };
    const was_installed = try installedBefore(arena, home);
    const installed = plugin_manager.install(arena, home, source, now_ms, .{ .trusted = true, .fetcher = env.fetcher }) catch |err| return installFailure(arena, source, err);
    return installedOutcome(arena, was_installed, installed);
}

fn installedBefore(arena: Allocator, home: []const u8) ![]const []const u8 {
    const plugins = plugin_manager.list(arena, home) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    const ids = try arena.alloc([]const u8, plugins.len);
    for (plugins, 0..) |plugin, index| ids[index] = plugin.record.id;
    return ids;
}

fn installedOutcome(arena: Allocator, was_installed: []const []const u8, installed: plugin_manager.Plugin) !Outcome {
    var updated = false;
    for (was_installed) |id| {
        if (std.mem.eql(u8, id, installed.record.id)) updated = true;
    }
    const version: []const u8 = if (installed.manifest) |loaded| loaded.version orelse "" else "";
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena, try std.fmt.allocPrint(arena, "{s} {s}{s}{s}.", .{
        if (updated) "Updated" else "Installed",
        installed.record.id,
        if (version.len > 0) " " else "",
        version,
    }));
    for (installed.diagnostics) |diagnostic| {
        if (diagnostic.severity == .info) continue;
        try body.appendSlice(arena, try std.fmt.allocPrint(arena, "\n{s}: {s}", .{ if (diagnostic.severity == .err) "error" else "warning", diagnostic.message }));
    }
    try body.appendSlice(arena, "\nRun /new to apply plugin changes.");
    return .{ .tone = if (installed.isOk()) .success else .warning, .body = body.items };
}

fn installFailure(arena: Allocator, source: []const u8, err: anyerror) !Outcome {
    const reason: []const u8 = switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RelativePluginSource => "the source must be an absolute path, an https zip URL, or a github.com repository URL",
        error.FileNotFound, error.NotDir => "no such directory",
        error.PluginManifestInvalid => "no valid kimi.plugin.json or .kimi-plugin/plugin.json was found",
        error.InvalidPluginId => "the plugin name in its manifest is not a valid plugin id",
        error.PluginIdMismatch => "the plugin's manifest name does not match the catalog id",
        error.PluginDownloadFailed => "the download failed",
        error.PluginChecksumMismatch => "the archive does not match the catalog's sha256",
        error.PluginArchiveInvalid => "the download is not a zip archive fx can read",
        error.PluginArchivePathTraversal => "the archive has an entry that points outside the plugin",
        error.PluginArchiveTooLarge => "the archive unpacks to more than fx allows for one plugin",
        error.MarketplaceInstallNeedsZipUrl => "a catalog zip install needs an https zip URL",
        error.MarketplaceEntryNeedsSha256 => "the catalog entry has no sha256sum, and fx installs catalog zips only when the catalog gives one",
        error.MarketplaceEntryUnsupportedHost => "the catalog does not offer that plugin for this client and platform",
        error.MarketplacePluginNotFound => "the catalog has no plugin with that id",
        error.PluginTrustRequired => "the source was not confirmed as trusted",
        else => @errorName(err),
    };
    return .{
        .tone = .@"error",
        .body = try std.fmt.allocPrint(arena, "Could not install from {s}: {s}.", .{ source, reason }),
    };
}

fn sourceLabel(arena: Allocator, record: plugin_store.Record) ![]const u8 {
    if (record.github) |github| {
        return std.fmt.allocPrint(arena, "github {s}/{s}@{s}", .{ github.owner, github.repo, github.ref_value });
    }
    if (std.mem.eql(u8, record.source_kind, plugin_store.source_kind_zip_url)) {
        const scheme_end = (std.mem.find(u8, record.source, "://") orelse return record.source_kind) + "://".len;
        const host_end = std.mem.findAnyPos(u8, record.source, scheme_end, "/?#") orelse record.source.len;
        return std.fmt.allocPrint(arena, "via {s}", .{record.source[scheme_end..host_end]});
    }
    return record.source_kind;
}

fn infoOutcome(arena: Allocator, home: []const u8, id: []const u8) !Outcome {
    const plugin = (try installedPlugin(arena, home, id)) orelse return failure(arena, "show", id, error.PluginNotFound);
    const record = plugin.record;
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena, try std.fmt.allocPrint(arena, "{s} ({s})", .{ record.id, if (record.enabled) "enabled" else "disabled" }));
    if (plugin.manifest) |loaded| {
        if (loaded.version) |version| try body.appendSlice(arena, try std.fmt.allocPrint(arena, "\nVersion: {s}", .{version}));
        if (loaded.description) |description| try body.appendSlice(arena, try std.fmt.allocPrint(arena, "\nDescription: {s}", .{description}));
        if (loaded.homepage) |homepage| try body.appendSlice(arena, try std.fmt.allocPrint(arena, "\nHomepage: {s}", .{homepage}));
    }
    try body.appendSlice(arena, try std.fmt.allocPrint(arena, "\nSource: {s} ({s})", .{ try sourceLabel(arena, record), record.source }));
    try body.appendSlice(arena, try std.fmt.allocPrint(arena, "\nOrigin: {s}", .{record.origin}));
    if (record.github) |github| {
        if (github.installed_sha) |sha| try body.appendSlice(arena, try std.fmt.allocPrint(arena, "\nCommit: {s}", .{sha}));
    }
    try body.appendSlice(arena, try std.fmt.allocPrint(arena, "\nRoot: {s}", .{record.root}));
    if (plugin.manifest) |loaded| {
        try body.appendSlice(arena, try std.fmt.allocPrint(arena, "\nSkill directories: {d}, agent directories: {d}, commands: {d}, hooks: {d}", .{
            loaded.skills.len,
            loaded.agents.len,
            loaded.commands.len,
            loaded.hooks.len,
        }));
        for (loaded.commands) |command| {
            try body.appendSlice(arena, try std.fmt.allocPrint(arena, "\n  /{s}:{s}", .{ record.id, command.name }));
        }
        if (try plugin_mcp_servers.declaredServers(arena, record.root, loaded.mcp_servers)) |servers| {
            var iterator = servers.object.iterator();
            while (iterator.next()) |entry| {
                try body.appendSlice(arena, try std.fmt.allocPrint(arena, "\nMCP server {s}: {s}", .{
                    entry.key_ptr.*,
                    if (mcpServerEnabled(record, entry.key_ptr.*)) "enabled" else "disabled",
                }));
            }
        }
    }
    if (plugin.load_error) |message| try body.appendSlice(arena, try std.fmt.allocPrint(arena, "\nLoad error: {s}", .{message}));
    for (plugin.diagnostics) |diagnostic| {
        try body.appendSlice(arena, try std.fmt.allocPrint(arena, "\n{s}: {s}", .{ @tagName(diagnostic.severity), diagnostic.message }));
    }
    return .{ .tone = if (plugin.isOk()) .information else .warning, .body = body.items };
}

fn mcpServerEnabled(record: plugin_store.Record, name: []const u8) bool {
    for (record.mcp_servers) |state| {
        if (std.mem.eql(u8, state.name, name)) return state.enabled;
    }
    return true;
}

const marketplace_unset_text = "No plugin marketplace is set. Name a catalog URL or file with /plugins marketplace SOURCE, or set FX_PLUGIN_MARKETPLACE_URL.";

fn marketplaceFailure(arena: Allocator, detail: plugin_marketplace.Failure, err: anyerror) !Outcome {
    const reason: []const u8 = switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PluginMarketplaceNotConfigured => return .{ .tone = .@"error", .body = marketplace_unset_text },
        error.PluginMarketplaceUntrustedHost => "a remote catalog must be served over https (plain http is accepted only from this machine)",
        error.PluginMarketplaceUnreadable => "the catalog could not be read",
        error.PluginMarketplaceInvalid => detail.message,
        else => @errorName(err),
    };
    return .{
        .tone = .@"error",
        .body = try std.fmt.allocPrint(arena, "Could not load the plugin marketplace: {s}", .{reason}),
    };
}

fn marketplaceOutcome(arena: Allocator, home: []const u8, action: MarketplaceAction, now_ms: i64, env: Env) !Outcome {
    var failure_detail: plugin_marketplace.Failure = .{};
    const explicit: ?[]const u8 = if (action.source.len > 0) action.source else null;
    const catalog = plugin_marketplace.load(arena, home, try workDir(arena, env), explicit, env.fetcher, now_ms, &failure_detail) catch |err| return marketplaceFailure(arena, failure_detail, err);
    const install_id = action.install_id orelse return .{ .tone = .information, .body = try catalogBody(arena, home, catalog) };

    const entry = plugin_marketplace.findEntry(catalog, install_id) orelse return installFailure(arena, install_id, error.MarketplacePluginNotFound);
    if (!action.trusted and plugin_marketplace.entryNeedsTrustPrompt(catalog, entry)) return .{
        .tone = .warning,
        .body = try std.fmt.allocPrint(
            arena,
            "Install {s} from {s}?{s}{s} A plugin can run hooks, MCP servers and commands on this machine, so install only from a source you trust. To go ahead, run /plugins marketplace install {s} {s}{s}{s}",
            .{
                entry.id,
                entry.source,
                if (entry.sha256sum != null) " SHA-256 " else "",
                entry.sha256sum orelse "",
                entry.id,
                trust_flag,
                if (action.source.len > 0) " " else "",
                action.source,
            },
        ),
    };
    const was_installed = try installedBefore(arena, home);
    const installed = plugin_marketplace.installEntry(arena, home, catalog, entry.id, now_ms, .{ .trusted = true, .fetcher = env.fetcher }) catch |err| return installFailure(arena, entry.source, err);
    return installedOutcome(arena, was_installed, installed);
}

fn catalogBody(arena: Allocator, home: []const u8, catalog: plugin_marketplace.Catalog) ![]const u8 {
    const plugins: []const plugin_manager.Plugin = plugin_manager.list(arena, home) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => &.{},
    };
    var body: std.ArrayList(u8) = .empty;
    var shown: usize = 0;
    for (catalog.plugins) |entry| {
        if (!plugin_marketplace.visibleOnHost(entry.clients, entry.platforms, plugin_marketplace.host_client, plugin_marketplace.hostPlatform())) continue;
        shown += 1;
        const badge: []const u8 = if (entry.tier) |tier| switch (tier) {
            .official => " [official]",
            .curated => " [curated]",
        } else " [third-party]";
        try body.appendSlice(arena, try std.fmt.allocPrint(arena, "\n- {s}{s}{s}{s}{s}", .{
            entry.id,
            if (entry.version != null) " " else "",
            entry.version orelse "",
            badge,
            try catalogEntryState(arena, plugins, entry),
        }));
        if (entry.description) |description| try body.appendSlice(arena, try std.fmt.allocPrint(arena, "\n  {s}", .{description}));
    }
    const heading = try std.fmt.allocPrint(arena, "Marketplace {s} ({d})", .{ catalog.source, shown });
    if (shown == 0) return std.fmt.allocPrint(arena, "{s}\nThe catalog offers no plugins for this client and platform.", .{heading});
    return std.fmt.allocPrint(arena, "{s}{s}\nInstall one with /plugins marketplace install ID.", .{ heading, body.items });
}

fn catalogEntryState(arena: Allocator, plugins: []const plugin_manager.Plugin, entry: plugin_marketplace.Entry) ![]const u8 {
    if (!plugin_marketplace.installableOnHost(entry.clients, entry.platforms, plugin_marketplace.host_client, plugin_marketplace.hostPlatform())) {
        return " (not installable on this platform)";
    }
    for (plugins) |plugin| {
        if (!std.ascii.eqlIgnoreCase(plugin.record.catalog_id orelse plugin.record.id, entry.id)) continue;
        const installed_version: []const u8 = if (plugin.manifest) |loaded| loaded.version orelse "" else "";
        if (entry.version) |latest| {
            if (plugin_updates.isNewer(latest, installed_version)) {
                return std.fmt.allocPrint(arena, " (installed {s}, update available)", .{installed_version});
            }
        }
        return " (installed)";
    }
    return "";
}

fn updateStatuses(arena: Allocator, home: []const u8, now_ms: i64, env: Env) ![]const plugin_updates.Status {
    const plugins = try plugin_manager.list(arena, home);
    var statuses: std.ArrayList(plugin_updates.Status) = .empty;
    try statuses.appendSlice(arena, try plugin_updates.checkGithub(arena, plugins, env.fetcher));
    var failure_detail: plugin_marketplace.Failure = .{};
    if (plugin_marketplace.load(arena, home, try workDir(arena, env), null, env.fetcher, now_ms, &failure_detail)) |catalog| {
        try statuses.appendSlice(arena, try plugin_updates.checkMarketplace(arena, plugins, catalog));
    } else |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
    }
    return statuses.items;
}

fn updatesOutcome(arena: Allocator, home: []const u8, now_ms: i64, env: Env) !Outcome {
    const statuses = updateStatuses(arena, home, now_ms, env) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{
            .tone = .@"error",
            .body = try std.fmt.allocPrint(arena, "Plugin update check failed: {s}.", .{@errorName(err)}),
        },
    };
    var body: std.ArrayList(u8) = .empty;
    var available: usize = 0;
    for (statuses) |status| {
        if (!status.update_available) continue;
        if (available > 0) try body.append(arena, '\n');
        try body.appendSlice(arena, try plugin_updates.noticeLine(arena, status));
        available += 1;
    }
    if (available == 0) return .{
        .tone = .information,
        .body = try std.fmt.allocPrint(arena, "No plugin updates found ({d} checked).", .{statuses.len}),
    };
    return .{ .tone = .warning, .body = body.items };
}

fn updateOutcome(arena: Allocator, home: []const u8, id: []const u8, now_ms: i64, env: Env) !Outcome {
    const plugin = (try installedPlugin(arena, home, id)) orelse return failure(arena, "update", id, error.PluginNotFound);
    const record = plugin.record;
    const was_installed = try installedBefore(arena, home);
    if (std.mem.eql(u8, record.origin, plugin_store.origin_marketplace)) {
        var failure_detail: plugin_marketplace.Failure = .{};
        if (plugin_marketplace.load(arena, home, try workDir(arena, env), null, env.fetcher, now_ms, &failure_detail)) |catalog| {
            const catalog_id = record.catalog_id orelse record.id;
            if (plugin_marketplace.findEntry(catalog, catalog_id)) |entry| {
                const installed = plugin_marketplace.installEntry(arena, home, catalog, entry.id, now_ms, .{ .trusted = true, .fetcher = env.fetcher }) catch |err| return installFailure(arena, entry.source, err);
                return installedOutcome(arena, was_installed, installed);
            }
        } else |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
        }
    }
    const installed = plugin_manager.install(arena, home, record.source, now_ms, .{
        .trusted = true,
        .origin = record.origin,
        .catalog_id = record.catalog_id,
        .marketplace_source = record.marketplace_source,
        .fetcher = env.fetcher,
    }) catch |err| return installFailure(arena, record.source, err);
    return installedOutcome(arena, was_installed, installed);
}

fn commandsBody(arena: Allocator, home: []const u8) ![]const u8 {
    const plugins = try plugin_manager.load(arena, home);
    const commands = try plugin_commands.collect(arena, plugins);
    if (commands.len == 0) return "No enabled plugin provides a slash command.";
    var lines: std.ArrayList(u8) = .empty;
    try lines.appendSlice(arena, try std.fmt.allocPrint(arena, "Plugin commands ({d})", .{commands.len}));
    for (commands) |command| {
        try lines.appendSlice(arena, try std.fmt.allocPrint(arena, "\n/{s}{s}{s}  {s}", .{
            command.slash_name,
            if (command.argument_hint != null) " " else "",
            command.argument_hint orelse "",
            command.description,
        }));
    }
    try lines.appendSlice(arena, "\nType one as /PLUGIN:NAME followed by its arguments.");
    return lines.items;
}

const list_hint = "\nUse /plugins info ID for details, /plugins install SOURCE to add one, and /plugins marketplace to browse a catalog.";

fn listBody(arena: Allocator, home: []const u8) ![]const u8 {
    const plugins = try plugin_manager.list(arena, home);
    if (plugins.len == 0) return "No plugins installed." ++ list_hint;
    var lines: std.ArrayList(u8) = .empty;
    try lines.appendSlice(arena, try std.fmt.allocPrint(arena, "Plugins ({d})", .{plugins.len}));
    for (plugins) |plugin| {
        const state = if (plugin.record.enabled) "enabled" else "disabled";
        const suffix: []const u8 = if (plugin.load_error) |message|
            try std.fmt.allocPrint(arena, " error: {s}", .{message})
        else
            "";
        const version: []const u8 = if (plugin.manifest) |loaded| loaded.version orelse "" else "";
        try lines.appendSlice(arena, try std.fmt.allocPrint(arena, "\n- {s}{s}{s} ({s}, {s}){s}", .{
            plugin.record.id,
            if (version.len > 0) " " else "",
            version,
            state,
            try sourceLabel(arena, plugin.record),
            suffix,
        }));
    }
    try lines.appendSlice(arena, list_hint);
    return lines.items;
}

fn reloadOutcome(arena: Allocator, home: []const u8) !Outcome {
    const previous_ids = try loadedPluginIds(arena);
    const summary = plugin_manager.reload(arena, home, previous_ids) catch |err| return .{
        .tone = .@"error",
        .body = try std.fmt.allocPrint(arena, "Plugin reload failed: {s}.", .{@errorName(err)}),
    };
    replaceLoadedPlugins(arena, home);
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena, try std.fmt.allocPrint(arena, "Reload: +{d} -{d}", .{ summary.added.len, summary.removed.len }));
    if (summary.errors.len > 0) try body.appendSlice(arena, try std.fmt.allocPrint(arena, " ({d} errors)", .{summary.errors.len}));
    for (summary.added) |id| try body.appendSlice(arena, try std.fmt.allocPrint(arena, "\n+ {s}", .{id}));
    for (summary.removed) |id| try body.appendSlice(arena, try std.fmt.allocPrint(arena, "\n- {s}", .{id}));
    for (summary.errors) |load_error| try body.appendSlice(arena, try std.fmt.allocPrint(arena, "\n! {s}: {s}", .{ load_error.id, load_error.message }));
    try body.appendSlice(arena, "\nRun /new to apply plugin changes.");
    const tone: types.NoticeTone = if (summary.errors.len > 0) .warning else .success;
    return .{ .tone = tone, .body = body.items };
}

fn setEnabledOutcome(arena: Allocator, home: []const u8, id: []const u8, enabled: bool, now_ms: i64) !Outcome {
    plugin_manager.setEnabled(arena, home, id, enabled, now_ms) catch |err| return failure(
        arena,
        if (enabled) "enable" else "disable",
        id,
        err,
    );
    return .{
        .tone = .success,
        .body = try std.fmt.allocPrint(arena, "{s} {s}. Run /new to apply.", .{ if (enabled) "Enabled" else "Disabled", id }),
    };
}

fn removeOutcome(arena: Allocator, home: []const u8, action: RemoveAction) !Outcome {
    const id = action.id;
    if (!action.confirmed) {
        if ((try installedPlugin(arena, home, id)) == null) return failure(arena, "remove", id, error.PluginNotFound);
        return .{
            .tone = .warning,
            .body = try std.fmt.allocPrint(
                arena,
                "Remove {s}? Its skills, commands, hooks and MCP servers stop loading in new sessions. To go ahead, run /plugins remove {s} {s}",
                .{ id, id, confirm_flag },
            ),
        };
    }
    plugin_manager.remove(arena, home, id) catch |err| return failure(arena, "remove", id, err);
    return .{
        .tone = .success,
        .body = try std.fmt.allocPrint(arena, "Removed {s}. Run /new to apply plugin changes.", .{id}),
    };
}

fn setMcpOutcome(arena: Allocator, home: []const u8, action: McpAction, now_ms: i64) !Outcome {
    plugin_manager.setMcpServerEnabled(arena, home, action.id, action.server, action.enabled, now_ms) catch |err| return failure(
        arena,
        "change an MCP server for",
        action.id,
        err,
    );
    return .{
        .tone = .success,
        .body = try std.fmt.allocPrint(arena, "{s} MCP server {s} for {s}. Run /new to apply.", .{
            if (action.enabled) "Enabled" else "Disabled",
            action.server,
            action.id,
        }),
    };
}

fn failure(arena: Allocator, action: []const u8, id: []const u8, err: anyerror) !Outcome {
    const reason = switch (err) {
        error.PluginNotFound => "no plugin with that id is installed",
        error.McpServerNotDeclared => "that plugin does not declare that MCP server",
        error.InvalidPluginId => "that plugin id is not valid",
        error.PluginOptionNotDeclared => "that plugin does not declare that option in userConfig",
        error.PluginOptionSensitive => "that option is marked sensitive, and fx does not store sensitive plugin options yet",
        else => return err,
    };
    return .{
        .tone = .@"error",
        .body = try std.fmt.allocPrint(arena, "Could not {s} {s}: {s}.", .{ action, id, reason }),
    };
}

test "plugins parse maps an empty payload and list to the list action" {
    try std.testing.expectEqual(Action.list, parse(""));
    try std.testing.expectEqual(Action.list, parse("  \t"));
    try std.testing.expectEqual(Action.list, parse("list"));
}

test "plugins parse accepts enable disable and remove with one id" {
    switch (parse("enable acme-tools")) {
        .enable => |id| try std.testing.expectEqualStrings("acme-tools", id),
        else => return error.TestExpectedPluginsEnable,
    }
    switch (parse("  disable acme-tools  ")) {
        .disable => |id| try std.testing.expectEqualStrings("acme-tools", id),
        else => return error.TestExpectedPluginsDisable,
    }
    switch (parse("remove acme-tools")) {
        .remove => |action| {
            try std.testing.expectEqualStrings("acme-tools", action.id);
            try std.testing.expect(!action.confirmed);
        },
        else => return error.TestExpectedPluginsRemove,
    }
    switch (parse("remove acme-tools --yes")) {
        .remove => |action| {
            try std.testing.expectEqualStrings("acme-tools", action.id);
            try std.testing.expect(action.confirmed);
        },
        else => return error.TestExpectedPluginsRemove,
    }
    try std.testing.expect(std.meta.activeTag(parse("remove")) == .unknown);
    try std.testing.expect(std.meta.activeTag(parse("enable")) == .unknown);
    try std.testing.expect(std.meta.activeTag(parse("enable two ids")) == .unknown);
}

test "plugins parse accepts mcp enable and disable with a plugin id and server" {
    switch (parse("mcp enable acme-tools search")) {
        .mcp => |action| {
            try std.testing.expect(action.enabled);
            try std.testing.expectEqualStrings("acme-tools", action.id);
            try std.testing.expectEqualStrings("search", action.server);
        },
        else => return error.TestExpectedPluginsMcp,
    }
    switch (parse("mcp disable acme-tools search")) {
        .mcp => |action| try std.testing.expect(!action.enabled),
        else => return error.TestExpectedPluginsMcp,
    }
    try std.testing.expect(std.meta.activeTag(parse("mcp enable acme-tools")) == .unknown);
    try std.testing.expect(std.meta.activeTag(parse("mcp toggle acme-tools search")) == .unknown);
}

test "plugins parse accepts validate with a path and an optional trailing strict" {
    switch (parse("validate ./my plugin")) {
        .validate => |action| {
            try std.testing.expectEqualStrings("./my plugin", action.path);
            try std.testing.expect(!action.strict);
        },
        else => return error.TestExpectedPluginsValidate,
    }
    switch (parse("validate /srv/plugin  strict")) {
        .validate => |action| {
            try std.testing.expectEqualStrings("/srv/plugin", action.path);
            try std.testing.expect(action.strict);
        },
        else => return error.TestExpectedPluginsValidate,
    }
    try std.testing.expect(std.meta.activeTag(parse("validate")) == .unknown);
    try std.testing.expect(std.meta.activeTag(parse("validate strict")) == .unknown);
}

test "plugins dir loads a plugin directory for the session and refuses a missing or invalid one" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "dev/.claude-plugin");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dev/.claude-plugin/plugin.json", .data = "{\"name\":\"dev-plugin\"}" });
    try tmp.dir.createDirPath(std.testing.io, "empty");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const dev = try std.Io.Dir.path.join(arena, &.{ base, "dev" });

    switch (parse("dir  /tmp/my plugin ")) {
        .dir => |path| try std.testing.expectEqualStrings("/tmp/my plugin", path),
        else => return error.TestExpectedPluginsDir,
    }
    try std.testing.expect(std.meta.activeTag(parse("dir")) == .unknown);

    plugin_manager.clearSessionPluginDirs();
    defer plugin_manager.clearSessionPluginDirs();
    const loaded = try run(arena, base, try std.fmt.allocPrint(arena, "dir {s}", .{dev}), 0);
    try std.testing.expectEqual(types.NoticeTone.success, loaded.tone);
    const plugins = try plugin_manager.list(arena, base);
    try std.testing.expectEqual(@as(usize, 1), plugins.len);
    try std.testing.expectEqualStrings("dev-plugin", plugins[0].record.id);

    const missing = try run(arena, base, try std.fmt.allocPrint(arena, "dir {s}/absent", .{base}), 0);
    try std.testing.expectEqual(types.NoticeTone.@"error", missing.tone);
    const invalid = try run(arena, base, try std.fmt.allocPrint(arena, "dir {s}/empty", .{base}), 0);
    try std.testing.expectEqual(types.NoticeTone.@"error", invalid.tone);
    try std.testing.expectEqual(@as(usize, 1), (try plugin_manager.list(arena, base)).len);
}

test "plugins parse accepts option with an id, a key and a value that may hold spaces" {
    switch (parse("option acme-tools api_endpoint https://api.example/v1 beta")) {
        .option => |action| {
            try std.testing.expectEqualStrings("acme-tools", action.id);
            try std.testing.expectEqualStrings("api_endpoint", action.key);
            try std.testing.expectEqualStrings("https://api.example/v1 beta", action.value);
        },
        else => return error.TestExpectedPluginsOption,
    }
    try std.testing.expect(std.meta.activeTag(parse("option acme-tools api_endpoint")) == .unknown);
    try std.testing.expect(std.meta.activeTag(parse("option acme-tools")) == .unknown);
}

test "plugins run validates a plugin directory and reports a missing one" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".claude-plugin");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".claude-plugin/plugin.json", .data = "{\"name\":\"ok\",\"version\":\"1\",\"description\":\"Ok\"}" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    const passed = try run(arena, "/unused", try std.fmt.allocPrint(arena, "validate {s} strict", .{root}), 0);
    try std.testing.expectEqual(types.NoticeTone.success, passed.tone);
    try std.testing.expectEqualStrings("Validation passed", passed.body);

    const missing = try run(arena, "/unused", try std.fmt.allocPrint(arena, "validate {s}/absent", .{root}), 0);
    try std.testing.expectEqual(types.NoticeTone.@"error", missing.tone);
    try std.testing.expect(std.mem.find(u8, missing.body, "no such directory") != null);
}

test "plugins run reports an option for a plugin that is not installed" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    const outcome = try run(arena, home, "option absent region eu", 0);
    try std.testing.expectEqual(types.NoticeTone.@"error", outcome.tone);
    try std.testing.expectEqualStrings("Could not set an option for absent: no plugin with that id is installed.", outcome.body);
}

test "plugins run reports unknown verbs as an error with the usage hint" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try run(arena.allocator(), "/unused", "frobnicate https://example.invalid/p.zip", 0);
    try std.testing.expectEqual(types.NoticeTone.@"error", outcome.tone);
    try std.testing.expect(std.mem.find(u8, outcome.body, "Unknown /plugins action: frobnicate https://example.invalid/p.zip.") != null);
    try std.testing.expect(std.mem.find(u8, outcome.body, "Use list, commands, install SOURCE") != null);
}

test "plugins parse reads install, marketplace, info, updates and update with their flags" {
    switch (parse("install --trust /srv/my plugin")) {
        .install => |action| {
            try std.testing.expectEqualStrings("/srv/my plugin", action.source);
            try std.testing.expect(action.trusted);
        },
        else => return error.TestExpectedPluginsInstall,
    }
    switch (parse("install https://example.test/p.zip")) {
        .install => |action| {
            try std.testing.expectEqualStrings("https://example.test/p.zip", action.source);
            try std.testing.expect(!action.trusted);
        },
        else => return error.TestExpectedPluginsInstall,
    }
    try std.testing.expect(std.meta.activeTag(parse("install")) == .unknown);
    try std.testing.expect(std.meta.activeTag(parse("install --trust")) == .unknown);

    switch (parse("marketplace")) {
        .marketplace => |action| {
            try std.testing.expectEqualStrings("", action.source);
            try std.testing.expect(action.install_id == null);
        },
        else => return error.TestExpectedPluginsMarketplace,
    }
    switch (parse("marketplace ./catalog.json")) {
        .marketplace => |action| try std.testing.expectEqualStrings("./catalog.json", action.source),
        else => return error.TestExpectedPluginsMarketplace,
    }
    switch (parse("marketplace install acme /srv/catalog.json --trust")) {
        .marketplace => |action| {
            try std.testing.expectEqualStrings("acme", action.install_id.?);
            try std.testing.expectEqualStrings("/srv/catalog.json", action.source);
            try std.testing.expect(action.trusted);
        },
        else => return error.TestExpectedPluginsMarketplace,
    }
    try std.testing.expect(std.meta.activeTag(parse("marketplace install")) == .unknown);

    switch (parse("info acme")) {
        .info => |id| try std.testing.expectEqualStrings("acme", id),
        else => return error.TestExpectedPluginsInfo,
    }
    try std.testing.expectEqual(Action.list, parse("info"));
    try std.testing.expectEqual(Action.updates, parse("updates"));
    switch (parse("update acme")) {
        .update => |id| try std.testing.expectEqualStrings("acme", id),
        else => return error.TestExpectedPluginsUpdate,
    }
}

fn writePluginFixture(tmp: *std.testing.TmpDir, dir: []const u8, manifest_text: []const u8) !void {
    try tmp.dir.createDirPath(std.testing.io, dir);
    const manifest_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/kimi.plugin.json", .{dir});
    defer std.testing.allocator.free(manifest_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = manifest_text });
}

test "plugins install asks for trust first, installs a relative path once trusted, and shows it in list and info" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePluginFixture(&tmp, "work/acme", "{\"name\":\"Acme\",\"version\":\"1.2.0\",\"description\":\"Acme tools\"}");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const env: Env = .{ .work_dir = try std.Io.Dir.path.join(arena, &.{ base, "work" }) };
    forgetLoadedPlugins();
    defer forgetLoadedPlugins();

    const asked = try runWith(arena, home, "install ./acme", 1, env);
    try std.testing.expectEqual(types.NoticeTone.warning, asked.tone);
    try std.testing.expect(std.mem.find(u8, asked.body, "/plugins install --trust ./acme") != null);
    try std.testing.expect(std.mem.find(u8, (try runWith(arena, home, "list", 1, env)).body, "No plugins installed.") != null);

    const installed = try runWith(arena, home, "install --trust ./acme", 2, env);
    try std.testing.expectEqual(types.NoticeTone.success, installed.tone);
    try std.testing.expect(std.mem.startsWith(u8, installed.body, "Installed acme 1.2.0."));

    const listed = try runWith(arena, home, "", 3, env);
    try std.testing.expect(std.mem.find(u8, listed.body, "Plugins (1)\n- acme 1.2.0 (enabled, local-path)") != null);

    const info = try runWith(arena, home, "info ACME", 3, env);
    try std.testing.expectEqual(types.NoticeTone.information, info.tone);
    try std.testing.expect(std.mem.startsWith(u8, info.body, "acme (enabled)\nVersion: 1.2.0\nDescription: Acme tools"));
    try std.testing.expect(std.mem.find(u8, info.body, "\nOrigin: custom") != null);
    const by_bare_id = try runWith(arena, home, "acme", 3, env);
    try std.testing.expectEqualStrings(info.body, by_bare_id.body);

    const again = try runWith(arena, home, "install --trust ./acme", 4, env);
    try std.testing.expect(std.mem.startsWith(u8, again.body, "Updated acme 1.2.0."));

    const missing = try runWith(arena, home, "install --trust ./absent", 5, env);
    try std.testing.expectEqual(types.NoticeTone.@"error", missing.tone);
    try std.testing.expect(std.mem.find(u8, missing.body, "no such directory") != null);
    const unknown_info = try runWith(arena, home, "info absent", 5, env);
    try std.testing.expectEqualStrings("Could not show absent: no plugin with that id is installed.", unknown_info.body);
}

test "plugins remove asks for confirmation and removes only with the confirm flag" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePluginFixture(&tmp, "work/acme", "{\"name\":\"acme\"}");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const env: Env = .{ .work_dir = try std.Io.Dir.path.join(arena, &.{ base, "work" }) };
    forgetLoadedPlugins();
    defer forgetLoadedPlugins();
    _ = try runWith(arena, home, "install --trust ./acme", 1, env);

    const asked = try runWith(arena, home, "remove acme", 2, env);
    try std.testing.expectEqual(types.NoticeTone.warning, asked.tone);
    try std.testing.expect(std.mem.find(u8, asked.body, "/plugins remove acme --yes") != null);
    try std.testing.expectEqual(@as(usize, 1), (try plugin_manager.list(arena, home)).len);

    const removed = try runWith(arena, home, "remove acme --yes", 3, env);
    try std.testing.expectEqualStrings("Removed acme. Run /new to apply plugin changes.", removed.body);
    try std.testing.expectEqual(@as(usize, 0), (try plugin_manager.list(arena, home)).len);
    const absent = try runWith(arena, home, "remove acme", 4, env);
    try std.testing.expectEqualStrings("Could not remove acme: no plugin with that id is installed.", absent.body);
}

test "plugins reload reports the plugins added and removed since the session loaded them" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePluginFixture(&tmp, "work/first", "{\"name\":\"first\"}");
    try writePluginFixture(&tmp, "work/second", "{\"name\":\"second\"}");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const work = try std.Io.Dir.path.join(arena, &.{ base, "work" });
    const env: Env = .{ .work_dir = work };
    _ = try plugin_manager.install(arena, home, try std.Io.Dir.path.join(arena, &.{ work, "first" }), 1, .{ .trusted = true });
    forgetLoadedPlugins();
    defer forgetLoadedPlugins();

    const unchanged = try runWith(arena, home, "reload", 2, env);
    try std.testing.expect(std.mem.startsWith(u8, unchanged.body, "Reload: +0 -0\n"));

    _ = try plugin_manager.install(arena, home, try std.Io.Dir.path.join(arena, &.{ work, "second" }), 3, .{ .trusted = true });
    try plugin_manager.remove(arena, home, "first");
    const changed = try runWith(arena, home, "reload", 4, env);
    try std.testing.expectEqual(types.NoticeTone.success, changed.tone);
    try std.testing.expect(std.mem.startsWith(u8, changed.body, "Reload: +1 -1\n+ second\n- first\n"));

    const settled = try runWith(arena, home, "reload", 5, env);
    try std.testing.expect(std.mem.startsWith(u8, settled.body, "Reload: +0 -0\n"));
}

test "plugins marketplace lists a catalog file and installs an entry after the trust question" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePluginFixture(&tmp, "work/acme", "{\"name\":\"acme\",\"version\":\"1.0.0\"}");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "work/catalog.json",
        .data = "{\"plugins\":[{\"id\":\"acme\",\"source\":\"./acme\",\"version\":\"1.0.0\",\"tier\":\"curated\",\"description\":\"Acme tools\"},{\"id\":\"cloudy\",\"source\":\"./cloudy\",\"platforms\":[\"cloud\"]}]}",
    });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const env: Env = .{ .work_dir = try std.Io.Dir.path.join(arena, &.{ base, "work" }) };
    forgetLoadedPlugins();
    defer forgetLoadedPlugins();

    const listed = try runWith(arena, home, "marketplace ./catalog.json", 1, env);
    try std.testing.expectEqual(types.NoticeTone.information, listed.tone);
    try std.testing.expect(std.mem.find(u8, listed.body, "\n- acme 1.0.0 [curated]\n  Acme tools") != null);
    try std.testing.expect(std.mem.find(u8, listed.body, "\n- cloudy [third-party] (not installable on this platform)") != null);

    const asked = try runWith(arena, home, "marketplace install acme ./catalog.json", 2, env);
    try std.testing.expectEqual(types.NoticeTone.warning, asked.tone);
    try std.testing.expect(std.mem.find(u8, asked.body, "/plugins marketplace install acme --trust ./catalog.json") != null);

    const installed = try runWith(arena, home, "marketplace install acme ./catalog.json --trust", 3, env);
    try std.testing.expect(std.mem.startsWith(u8, installed.body, "Installed acme 1.0.0."));
    const plugins = try plugin_manager.list(arena, home);
    try std.testing.expectEqualStrings(plugin_store.origin_marketplace, plugins[0].record.origin);

    const relisted = try runWith(arena, home, "marketplace ./catalog.json", 4, env);
    try std.testing.expect(std.mem.find(u8, relisted.body, "\n- acme 1.0.0 [curated] (installed)") != null);

    const cloud_only = try runWith(arena, home, "marketplace install cloudy ./catalog.json --trust", 5, env);
    try std.testing.expectEqual(types.NoticeTone.@"error", cloud_only.tone);
    const invalid = try runWith(arena, home, "marketplace ./acme/kimi.plugin.json", 6, env);
    try std.testing.expectEqualStrings("Could not load the plugin marketplace: Plugin marketplace must contain a \"plugins\" array.", invalid.body);
}

test "plugins updates names a github plugin whose branch moved and update reinstalls it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const plugin_archive = @import("../plugins/archive.zig");
    const zip_bytes = try plugin_archive.buildStoredZip(arena, &.{
        .{ .name = "tools-main/kimi.plugin.json", .data = "{\"name\":\"tools\"}" },
    });
    const old_sha = "1111111111111111111111111111111111111111";
    const new_sha = "2222222222222222222222222222222222222222";
    const source = "https://github.com/acme/tools/tree/main";
    forgetLoadedPlugins();
    defer forgetLoadedPlugins();

    var before: plugin_remote.CannedFetcher = .{ .replies = &.{
        .{ .url = "https://github.com/acme/tools/commits/main.atom", .body = "Grit::Commit/" ++ old_sha },
        .{ .url = "https://codeload.github.com/acme/tools/zip/" ++ old_sha, .body = zip_bytes },
    } };
    const installed = try runWith(arena, home, "install --trust " ++ source, 1, .{ .fetcher = before.fetcher(), .work_dir = home });
    try std.testing.expect(std.mem.startsWith(u8, installed.body, "Installed tools."));
    const steady = try runWith(arena, home, "updates", 2, .{ .fetcher = before.fetcher(), .work_dir = home });
    try std.testing.expectEqualStrings("No plugin updates found (1 checked).", steady.body);

    var after: plugin_remote.CannedFetcher = .{ .replies = &.{
        .{ .url = "https://github.com/acme/tools/commits/main.atom", .body = "Grit::Commit/" ++ new_sha },
        .{ .url = "https://codeload.github.com/acme/tools/zip/" ++ new_sha, .body = zip_bytes },
    } };
    const moved = try runWith(arena, home, "updates", 3, .{ .fetcher = after.fetcher(), .work_dir = home });
    try std.testing.expectEqual(types.NoticeTone.warning, moved.tone);
    try std.testing.expect(std.mem.find(u8, moved.body, "Run /plugins update tools to install it.") != null);

    const updated = try runWith(arena, home, "update tools", 4, .{ .fetcher = after.fetcher(), .work_dir = home });
    try std.testing.expect(std.mem.startsWith(u8, updated.body, "Updated tools."));
    const plugins = try plugin_manager.list(arena, home);
    try std.testing.expectEqualStrings(new_sha, plugins[0].record.github.?.installed_sha.?);
    const info = try runWith(arena, home, "info tools", 5, .{ .fetcher = after.fetcher(), .work_dir = home });
    try std.testing.expect(std.mem.find(u8, info.body, "\nSource: github acme/tools@main (" ++ source ++ ")") != null);
}

test "plugins commands lists the slash commands of enabled plugins with their descriptions" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writePluginFixture(&tmp, "work/acme", "{\"name\":\"acme\",\"commands\":\"./commands\"}");
    try tmp.dir.createDirPath(std.testing.io, "work/acme/commands");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "work/acme/commands/review.md", .data = "---\ndescription: Review the diff\n---\nReview $ARGUMENTS." });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    const env: Env = .{ .work_dir = try std.Io.Dir.path.join(arena, &.{ base, "work" }) };
    forgetLoadedPlugins();
    defer forgetLoadedPlugins();

    const none = try runWith(arena, home, "commands", 1, env);
    try std.testing.expectEqualStrings("No enabled plugin provides a slash command.", none.body);
    _ = try runWith(arena, home, "install --trust ./acme", 2, env);
    const listed = try runWith(arena, home, "commands", 3, env);
    try std.testing.expect(std.mem.startsWith(u8, listed.body, "Plugin commands (1)\n/acme:review  Review the diff\n"));
    _ = try runWith(arena, home, "disable acme", 4, env);
    try std.testing.expectEqualStrings("No enabled plugin provides a slash command.", (try runWith(arena, home, "commands", 5, env)).body);
}
