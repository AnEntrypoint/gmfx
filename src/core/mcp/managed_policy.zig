const std = @import("std");
const builtin = @import("builtin");
const mcp_contract = @import("mcp_contract.zig");
const project_config = @import("project_config.zig");

const Allocator = std.mem.Allocator;
const McpServerConfig = mcp_contract.McpServerConfig;
const Diagnostic = project_config.WorkspaceDiagnostic;

pub const directory = switch (builtin.target.os.tag) {
    .macos => "/Library/Application Support/fx",
    .windows => "C:\\Program Files\\fx",
    else => "/etc/fx",
};
pub const exclusive_file_name = "managed-mcp.json";
pub const settings_file_name = "managed-settings.json";

pub const allowed_key = "allowedMcpServers";
pub const denied_key = "deniedMcpServers";
pub const managed_servers_key = "managedMcpServers";

pub const Files = struct {
    exclusive: ?[]const u8 = null,
    settings: ?[]const u8 = null,

    pub fn none(self: Files) bool {
        return self.exclusive == null and self.settings == null;
    }
};

pub const Matcher = union(enum) {
    name: []const u8,
    url: []const u8,
    command: []const []const u8,
};

pub const Rules = struct {
    allowed: ?[]const Matcher = null,
    denied: []const Matcher = &.{},
    managed_servers: ?std.json.Value = null,

    pub fn manages(self: Rules, name: []const u8) bool {
        const servers = self.managed_servers orelse return false;
        return servers == .object and servers.object.contains(name);
    }
};

pub const Verdict = enum { allowed, denied, not_allowed };

pub const RulesError = Allocator.Error || error{ManagedPolicyUnreadable};

pub fn parseRules(arena: Allocator, settings_text: []const u8) RulesError!Rules {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, settings_text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ManagedPolicyUnreadable,
    };
    if (root != .object) return error.ManagedPolicyUnreadable;
    var rules: Rules = .{};
    if (root.object.get(allowed_key)) |value| rules.allowed = try parseMatchers(arena, value);
    if (root.object.get(denied_key)) |value| rules.denied = try parseMatchers(arena, value);
    if (root.object.get(managed_servers_key)) |value| {
        if (value != .object) return error.ManagedPolicyUnreadable;
        rules.managed_servers = value;
    }
    return rules;
}

fn parseMatchers(arena: Allocator, value: std.json.Value) RulesError![]const Matcher {
    if (value != .array) return error.ManagedPolicyUnreadable;
    var matchers: std.ArrayList(Matcher) = .empty;
    for (value.array.items) |item| {
        if (item != .object) return error.ManagedPolicyUnreadable;
        if (item.object.get("serverName")) |name| {
            if (name != .string) return error.ManagedPolicyUnreadable;
            try matchers.append(arena, .{ .name = name.string });
        } else if (item.object.get("serverUrl")) |url| {
            if (url != .string) return error.ManagedPolicyUnreadable;
            try matchers.append(arena, .{ .url = url.string });
        } else if (item.object.get("serverCommand")) |command| {
            if (command != .array or command.array.items.len == 0) return error.ManagedPolicyUnreadable;
            const argv = try arena.alloc([]const u8, command.array.items.len);
            for (command.array.items, argv) |word, *slot| {
                if (word != .string) return error.ManagedPolicyUnreadable;
                slot.* = word.string;
            }
            try matchers.append(arena, .{ .command = argv });
        } else return error.ManagedPolicyUnreadable;
    }
    return matchers.items;
}

pub fn verdict(rules: Rules, config: *const McpServerConfig) Verdict {
    for (rules.denied) |matcher| if (matches(matcher, config)) return .denied;
    const allowed = rules.allowed orelse return .allowed;
    const own_kind: std.meta.Tag(Matcher) = if (config.transport == .stdio) .command else .url;
    const own_kind_listed = for (allowed) |matcher| {
        if (std.meta.activeTag(matcher) == own_kind) break true;
    } else false;
    const deciding_kind: std.meta.Tag(Matcher) = if (own_kind_listed) own_kind else .name;
    for (allowed) |matcher| {
        if (std.meta.activeTag(matcher) != deciding_kind) continue;
        if (matches(matcher, config)) return .allowed;
    }
    return .not_allowed;
}

fn matches(matcher: Matcher, config: *const McpServerConfig) bool {
    switch (matcher) {
        .name => |name| return std.mem.eql(u8, name, config.name),
        .url => |pattern| {
            if (config.transport == .stdio) return false;
            const url = config.url orelse return false;
            return wildcardMatch(pattern, url);
        },
        .command => |argv| {
            if (config.transport != .stdio) return false;
            const command = config.command orelse return false;
            if (argv.len != config.args.len + 1) return false;
            if (!std.mem.eql(u8, argv[0], command)) return false;
            for (argv[1..], config.args) |wanted, given| {
                if (!std.mem.eql(u8, wanted, given)) return false;
            }
            return true;
        },
    }
}

pub fn wildcardMatch(pattern: []const u8, text: []const u8) bool {
    var pattern_at: usize = 0;
    var text_at: usize = 0;
    var star_at: ?usize = null;
    var star_text_at: usize = 0;
    while (text_at < text.len) {
        if (pattern_at < pattern.len and pattern[pattern_at] == '*') {
            star_at = pattern_at;
            star_text_at = text_at;
            pattern_at += 1;
        } else if (pattern_at < pattern.len and pattern[pattern_at] == text[text_at]) {
            pattern_at += 1;
            text_at += 1;
        } else if (star_at) |star| {
            pattern_at = star + 1;
            star_text_at += 1;
            text_at = star_text_at;
        } else return false;
    }
    while (pattern_at < pattern.len and pattern[pattern_at] == '*') pattern_at += 1;
    return pattern_at == pattern.len;
}

fn remoteOnly(entry: std.json.Value) bool {
    if (entry != .object) return false;
    const object = entry.object;
    for ([_][]const u8{ "command", "args", "env", "environment", "headersHelper" }) |forbidden| {
        if (object.contains(forbidden)) return false;
    }
    if (object.get("type") orelse object.get("transport")) |kind| {
        if (kind != .string) return false;
        const known = std.mem.eql(u8, kind.string, "http") or
            std.mem.eql(u8, kind.string, "streamable-http") or
            std.mem.eql(u8, kind.string, "sse");
        if (!known) return false;
    }
    const url = object.get("url") orelse return false;
    return url == .string and std.mem.startsWith(u8, url.string, "https://");
}

fn managedServersText(arena: Allocator, servers: std.json.Value, refused: *std.ArrayList([]const u8)) Allocator.Error![]const u8 {
    var kept: std.json.ObjectMap = .empty;
    var entries = servers.object.iterator();
    while (entries.next()) |entry| {
        if (!remoteOnly(entry.value_ptr.*)) {
            try refused.append(arena, entry.key_ptr.*);
            continue;
        }
        try kept.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    }
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "mcpServers", .{ .object = kept });
    var out: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(std.json.Value{ .object = root }, .{}, &out.writer) catch return error.OutOfMemory;
    return out.written();
}

fn note(alloc: Allocator, diagnostics: *std.ArrayList(Diagnostic), cause: project_config.WorkspaceDiagnosticCause, server_name: ?[]const u8) Allocator.Error!void {
    const owned: ?[]u8 = if (server_name) |name| try alloc.dupe(u8, name) else null;
    errdefer if (owned) |name| alloc.free(name);
    try diagnostics.append(alloc, .{ .profile = true, .server_name = owned, .cause = cause });
}

fn dropAll(alloc: Allocator, configs: *std.ArrayList(McpServerConfig)) void {
    for (configs.items) |*config| config.deinit(alloc);
    configs.clearRetainingCapacity();
}

fn dropNamed(alloc: Allocator, configs: *std.ArrayList(McpServerConfig), name: []const u8) void {
    var index: usize = 0;
    while (index < configs.items.len) {
        if (!std.mem.eql(u8, configs.items[index].name, name)) {
            index += 1;
            continue;
        }
        var removed = configs.orderedRemove(index);
        removed.deinit(alloc);
    }
}

fn parseManagedServers(alloc: Allocator, text: []const u8, diagnostics: *std.ArrayList(Diagnostic)) Allocator.Error!?std.ArrayList(McpServerConfig) {
    const parsed = project_config.parseProfileServers(alloc, text, diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return parsed;
}

fn adopt(alloc: Allocator, configs: *std.ArrayList(McpServerConfig), incoming: *std.ArrayList(McpServerConfig)) Allocator.Error!void {
    errdefer {
        for (incoming.items) |*config| config.deinit(alloc);
        incoming.deinit(alloc);
    }
    try configs.ensureUnusedCapacity(alloc, incoming.items.len);
    for (incoming.items) |config| dropNamed(alloc, configs, config.name);
    configs.appendSliceAssumeCapacity(incoming.items);
    incoming.clearRetainingCapacity();
    incoming.deinit(alloc);
}

pub fn install(
    alloc: Allocator,
    files: Files,
    configs: *std.ArrayList(McpServerConfig),
    diagnostics: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    if (files.exclusive) |text| {
        dropAll(alloc, configs);
        if (try parseManagedServers(alloc, text, diagnostics)) |parsed| {
            var only = parsed;
            try adopt(alloc, configs, &only);
        } else try note(alloc, diagnostics, .managed_unreadable, null);
    }
    const settings_text = files.settings orelse return;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rules = parseRules(arena, settings_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ManagedPolicyUnreadable => return,
    };
    const servers = rules.managed_servers orelse return;
    var refused: std.ArrayList([]const u8) = .empty;
    const text = try managedServersText(arena, servers, &refused);
    for (refused.items) |name| try note(alloc, diagnostics, .managed_refused, name);
    if (try parseManagedServers(alloc, text, diagnostics)) |parsed| {
        var managed = parsed;
        try adopt(alloc, configs, &managed);
    }
}

pub fn filter(
    alloc: Allocator,
    files: Files,
    configs: *std.ArrayList(McpServerConfig),
    diagnostics: *std.ArrayList(Diagnostic),
) Allocator.Error!void {
    const settings_text = files.settings orelse return;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const rules = parseRules(arena_state.allocator(), settings_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ManagedPolicyUnreadable => {
            dropAll(alloc, configs);
            return note(alloc, diagnostics, .managed_unreadable, null);
        },
    };
    var index: usize = 0;
    while (index < configs.items.len) {
        const config = &configs.items[index];
        const decided = verdict(rules, config);
        const kept = decided == .allowed or (decided == .not_allowed and rules.manages(config.name));
        if (kept) {
            index += 1;
            continue;
        }
        try note(alloc, diagnostics, if (decided == .denied) .managed_denied else .managed_not_allowed, config.name);
        var removed = configs.orderedRemove(index);
        removed.deinit(alloc);
    }
}

const testing = std.testing;

fn freeAll(alloc: Allocator, configs: *std.ArrayList(McpServerConfig), diagnostics: *std.ArrayList(Diagnostic)) void {
    for (configs.items) |*config| config.deinit(alloc);
    configs.deinit(alloc);
    for (diagnostics.items) |*diagnostic| diagnostic.deinit(alloc);
    diagnostics.deinit(alloc);
}

fn parseUserServers(alloc: Allocator, text: []const u8) !std.ArrayList(McpServerConfig) {
    return project_config.parseProfileJson(alloc, text);
}

const user_servers =
    \\{"mcpServers":{
    \\"github":{"type":"http","url":"https://api.github.example/mcp"},
    \\"files":{"command":"npx","args":["-y","files-server"]},
    \\"rogue":{"command":"python","args":["rogue.py"]},
    \\"intranet":{"type":"http","url":"https://mcp.corp.example/tools"}
    \\}}
;

test "a url pattern matches with * standing for any run of characters" {
    try testing.expect(wildcardMatch("https://mcp.corp.example/*", "https://mcp.corp.example/tools"));
    try testing.expect(wildcardMatch("https://*.corp.example/*", "https://mcp.corp.example/tools"));
    try testing.expect(wildcardMatch("*", ""));
    try testing.expect(wildcardMatch("https://a.example/mcp", "https://a.example/mcp"));
    try testing.expect(!wildcardMatch("https://a.example/mcp", "https://a.example/mcp2"));
    try testing.expect(!wildcardMatch("https://*.corp.example/*", "https://corp.example.evil.test/x"));
}

test "with no allowlist every server loads, an empty allowlist loads none, and the denylist always wins" {
    const alloc = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var configs = try parseUserServers(alloc, user_servers);
    defer {
        for (configs.items) |*config| config.deinit(alloc);
        configs.deinit(alloc);
    }
    const github = &configs.items[0];
    const files = &configs.items[1];
    const rogue = &configs.items[2];
    const intranet = &configs.items[3];

    const open = try parseRules(arena, "{}");
    try testing.expectEqual(Verdict.allowed, verdict(open, rogue));

    const closed = try parseRules(arena, "{\"allowedMcpServers\":[]}");
    try testing.expectEqual(Verdict.not_allowed, verdict(closed, github));
    try testing.expectEqual(Verdict.not_allowed, verdict(closed, files));

    const by_name = try parseRules(arena, "{\"allowedMcpServers\":[{\"serverName\":\"github\"},{\"serverName\":\"files\"}],\"deniedMcpServers\":[{\"serverName\":\"files\"}]}");
    try testing.expectEqual(Verdict.allowed, verdict(by_name, github));
    try testing.expectEqual(Verdict.denied, verdict(by_name, files));
    try testing.expectEqual(Verdict.not_allowed, verdict(by_name, rogue));

    const by_kind = try parseRules(arena, "{\"allowedMcpServers\":[{\"serverName\":\"rogue\"},{\"serverCommand\":[\"npx\",\"-y\",\"files-server\"]},{\"serverUrl\":\"https://*.corp.example/*\"}]}");
    try testing.expectEqual(Verdict.allowed, verdict(by_kind, files));
    try testing.expectEqual(Verdict.not_allowed, verdict(by_kind, rogue));
    try testing.expectEqual(Verdict.allowed, verdict(by_kind, intranet));
    try testing.expectEqual(Verdict.not_allowed, verdict(by_kind, github));

    const deny_url = try parseRules(arena, "{\"deniedMcpServers\":[{\"serverUrl\":\"https://api.github.example/*\"},{\"serverCommand\":[\"python\",\"rogue.py\"]}]}");
    try testing.expectEqual(Verdict.denied, verdict(deny_url, github));
    try testing.expectEqual(Verdict.denied, verdict(deny_url, rogue));
    try testing.expectEqual(Verdict.allowed, verdict(deny_url, files));

    try testing.expectError(error.ManagedPolicyUnreadable, parseRules(arena, "{\"allowedMcpServers\":[{\"server\":\"x\"}]}"));
    try testing.expectError(error.ManagedPolicyUnreadable, parseRules(arena, "not json"));
}

test "managed-mcp.json makes only its servers load, and an empty map loads none" {
    const alloc = testing.allocator;
    var configs = try parseUserServers(alloc, user_servers);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer freeAll(alloc, &configs, &diagnostics);

    try install(alloc, .{ .exclusive = "{\"mcpServers\":{\"approved\":{\"type\":\"http\",\"url\":\"https://mcp.corp.example/approved\"}}}" }, &configs, &diagnostics);
    try testing.expectEqual(@as(usize, 1), configs.items.len);
    try testing.expectEqualStrings("approved", configs.items[0].name);
    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);

    try install(alloc, .{ .exclusive = "{\"mcpServers\":{}}" }, &configs, &diagnostics);
    try testing.expectEqual(@as(usize, 0), configs.items.len);

    var again = try parseUserServers(alloc, user_servers);
    defer {
        for (again.items) |*config| config.deinit(alloc);
        again.deinit(alloc);
    }
    try install(alloc, .{ .exclusive = "{ broken" }, &again, &diagnostics);
    try testing.expectEqual(@as(usize, 0), again.items.len);
    try testing.expectEqual(project_config.WorkspaceDiagnosticCause.managed_unreadable, diagnostics.items[0].cause);
}

test "managedMcpServers adds https remote servers above the user's own, and refuses a command or a plain http url" {
    const alloc = testing.allocator;
    var configs = try parseUserServers(alloc, user_servers);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer freeAll(alloc, &configs, &diagnostics);

    const settings: Files = .{ .settings =
        \\{"managedMcpServers":{
        \\"github":{"type":"http","url":"https://mcp.corp.example/github"},
        \\"events":{"type":"sse","url":"https://mcp.corp.example/events"},
        \\"local":{"command":"node","args":["x.js"]},
        \\"plain":{"type":"http","url":"http://mcp.corp.example/plain"},
        \\"helper":{"type":"http","url":"https://mcp.corp.example/h","headersHelper":"get-token"}
        \\},"allowedMcpServers":[{"serverName":"files"}]}
    };
    try install(alloc, settings, &configs, &diagnostics);
    try testing.expectEqual(@as(usize, 5), configs.items.len);
    try testing.expectEqualStrings("github", configs.items[3].name);
    try testing.expectEqualStrings("https://mcp.corp.example/github", configs.items[3].url.?);
    try testing.expectEqual(mcp_contract.McpTransport.sse, configs.items[4].transport);
    try testing.expectEqual(@as(usize, 3), diagnostics.items.len);
    for (diagnostics.items) |diagnostic| try testing.expectEqual(project_config.WorkspaceDiagnosticCause.managed_refused, diagnostic.cause);
    try testing.expectEqualStrings("local", diagnostics.items[0].server_name.?);

    try filter(alloc, settings, &configs, &diagnostics);
    try testing.expectEqual(@as(usize, 3), configs.items.len);
    try testing.expectEqualStrings("files", configs.items[0].name);
    try testing.expectEqualStrings("github", configs.items[1].name);
    try testing.expectEqualStrings("events", configs.items[2].name);
    try testing.expectEqual(@as(usize, 5), diagnostics.items.len);
    try testing.expectEqual(project_config.WorkspaceDiagnosticCause.managed_not_allowed, diagnostics.items[3].cause);
    try testing.expectEqualStrings("rogue", diagnostics.items[3].server_name.?);
    try testing.expectEqualStrings("intranet", diagnostics.items[4].server_name.?);
}

test "a managed policy fx can't read loads no server and says so, and no managed files change nothing" {
    const alloc = testing.allocator;
    var configs = try parseUserServers(alloc, user_servers);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer freeAll(alloc, &configs, &diagnostics);

    try install(alloc, .{}, &configs, &diagnostics);
    try filter(alloc, .{}, &configs, &diagnostics);
    try testing.expectEqual(@as(usize, 4), configs.items.len);
    try testing.expectEqual(@as(usize, 0), diagnostics.items.len);
    try testing.expect((Files{}).none());

    try install(alloc, .{ .settings = "[]" }, &configs, &diagnostics);
    try filter(alloc, .{ .settings = "[]" }, &configs, &diagnostics);
    try testing.expectEqual(@as(usize, 0), configs.items.len);
    try testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    const text = try project_config.renderWorkspaceDiagnostic(alloc, diagnostics.items[0]);
    defer alloc.free(text);
    try testing.expectEqualStrings("fx can't read this machine's managed MCP policy, so no MCP server is loaded; ask your administrator to fix it.", text);

    const denied = try project_config.renderWorkspaceDiagnostic(alloc, .{ .profile = true, .server_name = @constCast("rogue"), .cause = .managed_denied });
    defer alloc.free(denied);
    try testing.expectEqualStrings("MCP server 'rogue' is not loaded: this machine's managed MCP policy denies it.", denied);
}
