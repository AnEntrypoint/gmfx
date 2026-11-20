const std = @import("std");
const credentials = @import("credentials.zig");
const mcp = @import("../../mcp/mcp.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const slack = @import("slack.zig");
const external_run = @import("../hooks/external_run.zig");
const hook_external = @import("../hooks/external.zig");

const Allocator = std.mem.Allocator;
const McpServerConfig = mcp_contract.McpServerConfig;

pub const Held = enum {
    disabled,
    waiting_for_approval,
    rejected,
    unsupported,
    missing_env,
    invalid_env,
    removed,
    nested,
};

pub const Server = struct {
    name: []const u8,
    source: mcp_contract.ConfigSource,
    scope: mcp_contract.ConfigScope,
    transport: mcp_contract.McpTransport,
    url: ?[]const u8,
    command: ?[]const u8,
    callback_port: ?u16,
    slack_app: bool = false,
    held: ?Held = null,
    always_loaded: bool = false,
    static_credentials: bool = false,
    missing: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    enabled_tools: ?[]const []const u8 = null,
    disabled_tools: ?[]const []const u8 = null,
    headers_helper: ?[]const u8 = null,

    pub fn credentialKey(s: Server) credentials.Key {
        return .{ .name = s.name, .url = s.url.?, .workspace = s.workspace };
    }
};

pub const Resolved = struct {
    servers: []Server,
    engine: []mcp.engine.Config,
    engine_server: []usize,
};

pub const depth_variable = "FX_MCP_DEPTH";
pub const project_dir_variable = "CLAUDE_PROJECT_DIR";
pub const max_depth: u32 = 2;
pub const launcher_startup_timeout_ms: u32 = 600_000;
const package_launchers = [_][]const u8{ "npx", "npm", "npx.cmd", "npm.cmd" };

pub fn nestingDepth(inherited: *const std.process.Environ.Map) u32 {
    const text = inherited.get(depth_variable) orelse return 0;
    return std.fmt.parseInt(u32, std.mem.trim(u8, text, " \t"), 10) catch max_depth;
}

pub fn tooDeep(depth: u32) bool {
    return depth >= max_depth;
}

pub fn startupTimeoutMs(c: *const McpServerConfig) u32 {
    if (c.startup_timeout_configured or c.startup_timeout_ms != mcp_contract.default_startup_timeout_ms) return c.startup_timeout_ms;
    const command = c.command orelse return c.startup_timeout_ms;
    if (c.transport != .stdio) return c.startup_timeout_ms;
    const base = command[if (std.mem.findLastAny(u8, command, "/\\")) |at| at + 1 else 0..];
    for (package_launchers) |launcher| {
        if (std.ascii.eqlIgnoreCase(base, launcher)) return launcher_startup_timeout_ms;
    }
    return c.startup_timeout_ms;
}

pub fn ignoreLines(arena: Allocator, configs: []const McpServerConfig, servers: []const Server) Allocator.Error![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    for (configs, servers) |c, s| {
        if (s.held != null) continue;
        try lines.appendSlice(arena, c.ignore);
    }
    return lines.items;
}

fn dupNames(arena: Allocator, names: ?[][]u8) Allocator.Error!?[]const []const u8 {
    const source = names orelse return null;
    const out = try arena.alloc([]const u8, source.len);
    for (source, out) |name, *o| o.* = try arena.dupe(u8, name);
    return out;
}

pub fn toolAllowed(server: Server, tool: []const u8) bool {
    if (server.enabled_tools) |allowed| if (!containsName(allowed, tool)) return false;
    if (server.disabled_tools) |blocked| if (containsName(blocked, tool)) return false;
    return true;
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

fn commandLine(arena: Allocator, command: []const u8, args: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..args.len + 1) |k| {
        const word = if (k == 0) command else args[k - 1];
        if (k > 0) try out.append(arena, ' ');
        const plain = word.len > 0 and std.mem.findAny(u8, word, " \t\n'\"$`\\") == null;
        if (plain) {
            try out.appendSlice(arena, word);
            continue;
        }
        try out.append(arena, '\'');
        for (word) |b| if (b == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, b);
        try out.append(arena, '\'');
    }
    return out.items;
}

pub fn resolve(
    arena: Allocator,
    configs: []const McpServerConfig,
    inherited: *const std.process.Environ.Map,
    workspace_root: []const u8,
) Allocator.Error!Resolved {
    const servers = try arena.alloc(Server, configs.len);
    const depth = nestingDepth(inherited);
    var engine: std.ArrayList(mcp.engine.Config) = .empty;
    var engine_server: std.ArrayList(usize) = .empty;
    for (configs, servers, 0..) |*c, *s, i| {
        s.* = .{
            .name = try arena.dupe(u8, c.name),
            .source = c.source,
            .scope = c.scope,
            .transport = c.transport,
            .url = if (c.url) |u| try arena.dupe(u8, u) else null,
            .command = if (c.command) |command| try commandLine(arena, command, c.args) else null,
            .callback_port = if (c.auth) |a| a.callback_port else null,
            .always_loaded = c.always_loaded,
            .static_credentials = c.usesStaticCredentials(),
            .enabled_tools = try dupNames(arena, c.enabled_tools),
            .disabled_tools = try dupNames(arena, c.disabled_tools),
            .workspace = if (c.source == .workspace) try arena.dupe(u8, workspace_root) else null,
            .headers_helper = if (c.headers_helper) |helper| try arena.dupe(u8, helper) else null,
        };
        s.held = heldFor(c);
        if (s.held == null and tooDeep(depth)) s.held = .nested;
        if (s.held != null) continue;
        const transport = (try transportFor(arena, c, inherited, s, workspace_root)) orelse continue;
        var auth: @FieldType(mcp.engine.Config, "auth") = .{};
        if (c.auth) |a| {
            auth.client_id = a.client_id;
            auth.client_metadata_url = a.client_metadata_url;
            auth.auth_server_metadata_url = a.auth_server_metadata_url;
            auth.resource = a.resource;

            if (a.scopes.len > 0) auth.scopes = try std.mem.join(arena, " ", a.scopes);
            if (a.client_secret_env) |variable| {
                auth.client_secret = inherited.get(variable) orelse {
                    s.held = .missing_env;
                    s.missing = try arena.dupe(u8, variable);
                    continue;
                };
            }
        }

        if (auth.client_id == null and slack.isSlack(s.url)) auth.client_id = slack.client_id;

        const fx_slack_app = if (auth.client_id) |id| std.mem.eql(u8, id, slack.client_id) else false;
        s.slack_app = fx_slack_app and slack.appServer(s.url);
        if (s.slack_app) {
            if (s.callback_port == null) s.callback_port = slack.callback_port;
            if (auth.scopes == null) auth.scopes = slack.scopes;

            if (auth.resource == null) if (s.url) |url| {
                auth.resource = try arena.print("{s}/", .{origin(url)});
            };
        }

        if (s.url != null) auth.refresh_via_host = true;

        var timeouts: @FieldType(mcp.engine.Options, "timeouts") = .{};
        timeouts.start_ms = startupTimeoutMs(c);
        timeouts.idle_ms = c.operation_timeout_ms;
        timeouts.hard_ms = @max(timeouts.hard_ms, c.operation_timeout_ms);
        try engine.append(arena, .{ .name = s.name, .transport = transport, .auth = auth, .timeouts = timeouts });
        try engine_server.append(arena, i);
    }
    return .{ .servers = servers, .engine = engine.items, .engine_server = engine_server.items };
}

pub fn keepServers(arena: Allocator, servers: []const Server, prior: []const Server) Allocator.Error![]Server {
    const out = try arena.alloc(Server, servers.len);
    for (servers, out) |s, *o| {
        const old: ?Server = for (prior) |p| {
            if (std.mem.eql(u8, p.name, s.name)) break p;
        } else null;
        o.* = s;
        o.name = if (old) |p| p.name else try arena.dupe(u8, s.name);
        inline for (.{ "url", "command", "missing", "workspace", "headers_helper" }) |field| {
            @field(o, field) = try reuse(arena, @field(s, field), if (old) |p| @field(p, field) else null);
        }
    }
    return out;
}

fn reuse(arena: Allocator, value: ?[]const u8, old: ?[]const u8) Allocator.Error!?[]const u8 {
    const v = value orelse return null;
    if (old) |o| if (std.mem.eql(u8, o, v)) return o;
    return try arena.dupe(u8, v);
}

fn origin(url: []const u8) []const u8 {
    const authority = (std.mem.find(u8, url, "://") orelse return url) + 3;
    return url[0 .. std.mem.findScalarPos(u8, url, authority, '/') orelse url.len];
}

fn heldFor(c: *const McpServerConfig) ?Held {
    if (!c.enabled) return .disabled;
    if (c.source == .workspace) if (c.workspace_admission) |admission| switch (admission) {
        .pending => return .waiting_for_approval,
        .rejected => return .rejected,
        .approved => {},
    };
    if (c.acp_server_id != null) return .unsupported;
    return null;
}

const inherited_names = [_][]const u8{ "HOME", "LOGNAME", "PATH", "SHELL", "TERM", "USER" };

fn transportFor(
    arena: Allocator,
    c: *const McpServerConfig,
    inherited: *const std.process.Environ.Map,
    s: *Server,
    workspace_root: []const u8,
) Allocator.Error!?mcp.engine.Transport {
    switch (c.transport) {
        .stdio => {
            const argv = try arena.alloc([]const u8, 1 + c.args.len);
            argv[0] = c.command orelse return null;
            @memcpy(argv[1..], c.args);

            const cwd = if (c.cwd) |dir| try arena.dupe(u8, dir) else null;
            const map = try arena.create(std.process.Environ.Map);
            map.* = .init(arena);
            for (inherited_names) |name| if (inherited.get(name)) |value| {
                if (!std.mem.startsWith(u8, value, "()")) try map.put(name, value);
            };
            if (workspace_root.len > 0) try map.put(project_dir_variable, workspace_root);
            for (c.env) |e| try map.put(e.key, e.value);
            try map.put(depth_variable, try arena.print("{d}", .{nestingDepth(inherited) +| 1}));
            return .{ .stdio = .{ .argv = argv, .environ_map = map, .cwd = cwd } };
        },
        .http, .sse => {
            var headers: std.ArrayList(std.http.Header) = .empty;
            for (c.headers) |h| try headers.append(arena, .{ .name = h.name, .value = h.value });
            for (c.header_env) |h| {
                const value = inherited.get(h.env) orelse return hold(arena, s, .missing_env, h.env);
                try headers.append(arena, .{ .name = h.name, .value = value });
                if (!mcp.http_headers.sendable(headers.items[headers.items.len - 1 ..])) return hold(arena, s, .invalid_env, h.env);
            }
            if (c.bearer_token_env) |variable| {
                const token = inherited.get(variable) orelse return hold(arena, s, .missing_env, variable);
                try headers.append(arena, .{ .name = "Authorization", .value = try arena.print("Bearer {s}", .{token}) });
                if (!mcp.http_headers.sendable(headers.items[headers.items.len - 1 ..])) return hold(arena, s, .invalid_env, variable);
            }
            const url = s.url orelse return null;
            if (unexpandedVariable(url)) |variable| return hold(arena, s, .missing_env, variable);
            if (c.headers_helper) |helper| {
                const printed = try runHeadersHelper(arena, helper, s.name, url, workspace_root);
                const produced = (try helperHeaders(arena, printed orelse "")) orelse return hold(arena, s, .invalid_env, headers_helper_key);
                for (produced) |header| {
                    try headers.append(arena, header);
                    if (!mcp.http_headers.sendable(headers.items[headers.items.len - 1 ..])) return hold(arena, s, .invalid_env, headers_helper_key);
                }
            }
            const link: mcp.engine.HttpTransport = .{ .url = url, .headers = headers.items };
            const transport: mcp.engine.Transport = if (c.transport == .sse) .{ .sse = link } else .{ .http = link };
            return transport;
        },
    }
}

pub const headers_helper_key = "headersHelper";
pub const headers_helper_timeout_seconds: u32 = 10;

pub fn runHeadersHelper(arena: Allocator, helper: []const u8, server_name: []const u8, url: []const u8, workspace_root: []const u8) Allocator.Error!?[]const u8 {
    const told = [_]hook_external.EnvVar{
        .{ .name = "CLAUDE_CODE_MCP_SERVER_NAME", .value = server_name },
        .{ .name = "CLAUDE_CODE_MCP_SERVER_URL", .value = url },
    };
    const cwd = if (workspace_root.len > 0) workspace_root else ".";
    const outcome = try external_run.run(arena, helper, cwd, &told, headers_helper_timeout_seconds, "", null);
    if (outcome.timed_out or outcome.cancelled) return null;
    const exit_code = outcome.exit_code orelse return null;
    if (exit_code != 0) return null;
    return outcome.stdout.items;
}

pub fn helperHeaders(arena: Allocator, printed: []const u8) Allocator.Error!?[]const std.http.Header {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, printed, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (value != .object) return null;
    var headers: std.ArrayList(std.http.Header) = .empty;
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) return null;
        try headers.append(arena, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.*.string });
    }
    return headers.items;
}

fn unexpandedVariable(text: []const u8) ?[]const u8 {
    const start = (std.mem.find(u8, text, "${") orelse return null) + 2;
    const end = std.mem.findAnyPos(u8, text, start, ":}") orelse text.len;
    return text[start..end];
}

fn hold(arena: Allocator, s: *Server, why: Held, variable: []const u8) Allocator.Error!?mcp.engine.Transport {
    s.held = why;
    s.missing = try arena.dupe(u8, variable);
    return null;
}

const testing = std.testing;

fn envVar(comptime key: []const u8, comptime value: []const u8) mcp_contract.McpEnvVar {
    return .{ .key = @constCast(key), .value = @constCast(value) };
}

test "tool filters keep the enabled allowlist and drop disabled names" {
    const allow = [_][]const u8{ "read", "write" };
    const block = [_][]const u8{"write"};
    const base: Server = .{ .name = "s", .source = .profile, .scope = .profile, .transport = .stdio, .url = null, .command = null, .callback_port = null };
    try testing.expect(toolAllowed(base, "anything"));
    var allowlisted = base;
    allowlisted.enabled_tools = &allow;
    try testing.expect(toolAllowed(allowlisted, "read"));
    try testing.expect(!toolAllowed(allowlisted, "delete"));
    var blocked = allowlisted;
    blocked.disabled_tools = &block;
    try testing.expect(!toolAllowed(blocked, "write"));
    try testing.expect(toolAllowed(blocked, "read"));
}

test "an approved .mcp.json server keeps its login under its own workspace, never the profile's" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var inherited: std.process.Environ.Map = .init(testing.allocator);
    defer inherited.deinit();
    const configs = [_]McpServerConfig{
        .{ .name = "linear", .transport = .http, .url = "https://mcp.linear.app/mcp" },
        .{ .name = "team", .transport = .http, .url = "https://mcp.linear.app/mcp", .source = .workspace, .scope = .workspace, .workspace_admission = .approved },
    };
    const r = try resolve(arena, &configs, &inherited, "/Users/example/repo");
    try testing.expectEqual(@as(?[]const u8, null), r.servers[0].workspace);
    try testing.expectEqual(@as(?[]const u8, null), r.servers[0].credentialKey().workspace);
    try testing.expectEqualStrings("/Users/example/repo", r.servers[1].workspace.?);
    try testing.expectEqualStrings("/Users/example/repo", r.servers[1].credentialKey().workspace.?);
}

test "a server's startup and operation timeouts become its engine limits" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var inherited: std.process.Environ.Map = .init(testing.allocator);
    defer inherited.deinit();
    const configs = [_]McpServerConfig{
        .{ .name = "plain", .command = "x" },
        .{ .name = "tuned", .transport = .http, .url = "https://t.example/mcp", .startup_timeout_ms = 5_000, .operation_timeout_ms = 900_000 },
    };
    const r = try resolve(arena_state.allocator(), &configs, &inherited, "/Users/example/repo");
    try testing.expectEqual(@as(u32, 30_000), r.engine[0].timeouts.?.start_ms);
    try testing.expectEqual(@as(u32, 60_000), r.engine[0].timeouts.?.idle_ms);
    try testing.expectEqual(@as(u32, 600_000), r.engine[0].timeouts.?.hard_ms);
    try testing.expectEqual(@as(u32, 5_000), r.engine[1].timeouts.?.start_ms);
    try testing.expectEqual(@as(u32, 900_000), r.engine[1].timeouts.?.idle_ms);

    try testing.expectEqual(@as(u32, 900_000), r.engine[1].timeouts.?.hard_ms);
}

test "stdio, HTTP, and SSE servers become engine configs; the rest are held back with the reason" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var inherited: std.process.Environ.Map = .init(testing.allocator);
    defer inherited.deinit();
    try inherited.put("PATH", "/usr/bin");
    try inherited.put("TEAM_TOKEN", "t1");
    try inherited.put("CLIENT_SECRET", "s1");

    var env = [_]mcp_contract.McpEnvVar{envVar("HOME", "/Users/me")};
    var header_env = [_]mcp_contract.McpHttpHeaderEnv{.{ .name = @constCast("X-Team"), .env = @constCast("TEAM_TOKEN") }};
    var missing_header = [_]mcp_contract.McpHttpHeaderEnv{.{ .name = @constCast("X-Key"), .env = @constCast("NOT_SET") }};
    const configs = [_]McpServerConfig{
        .{ .name = "ctx", .command = "node", .args = &.{"ctx.js"} },
        .{ .name = "kit", .command = "kit", .env = &env },
        .{ .name = "linear", .transport = .http, .url = "https://mcp.linear.app/mcp", .header_env = &header_env, .auth = .{ .client_id = @constCast("c1"), .client_secret_env = @constCast("CLIENT_SECRET"), .callback_port = 33418 } },
        .{ .name = "off", .command = "x", .enabled = false },
        .{ .name = "pending", .command = "x", .source = .workspace, .workspace_admission = .pending },
        .{ .name = "no", .command = "x", .source = .workspace, .workspace_admission = .rejected },
        .{ .name = "old", .transport = .sse, .url = "https://old.example/sse" },
        .{ .name = "keyless", .transport = .http, .url = "https://k.example/mcp", .header_env = &missing_header },
        .{ .name = "carried", .transport = .http, .url = "http://acp.invalid/x", .source = .acp, .acp_server_id = @constCast("x") },
    };
    const r = try resolve(arena, &configs, &inherited, "/Users/example/repo");

    try testing.expectEqual(@as(usize, 4), r.engine.len);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 6 }, r.engine_server);
    try testing.expectEqualStrings("ctx.js", r.engine[0].transport.stdio.argv[1]);
    const ctx_env = r.engine[0].transport.stdio.environ_map.?;
    try testing.expectEqual(@as(usize, 3), ctx_env.count());
    try testing.expectEqualStrings("/Users/example/repo", ctx_env.get(project_dir_variable).?);
    try testing.expectEqualStrings("/usr/bin", ctx_env.get("PATH").?);
    try testing.expectEqualStrings("1", ctx_env.get(depth_variable).?);
    const kit_env = r.engine[1].transport.stdio.environ_map.?;
    try testing.expectEqual(@as(usize, 4), kit_env.count());
    try testing.expectEqualStrings("/Users/me", kit_env.get("HOME").?);
    try testing.expectEqualStrings("/usr/bin", kit_env.get("PATH").?);

    const linear = r.engine[2];
    try testing.expectEqualStrings("https://mcp.linear.app/mcp", linear.transport.http.url);
    try testing.expectEqualStrings("X-Team", linear.transport.http.headers[0].name);
    try testing.expectEqualStrings("t1", linear.transport.http.headers[0].value);
    try testing.expectEqualStrings("c1", linear.auth.client_id.?);
    try testing.expectEqualStrings("s1", linear.auth.client_secret.?);

    try testing.expect(linear.auth.saved == null);

    try testing.expect(linear.auth.refresh_via_host);
    try testing.expectEqual(@as(?u16, 33418), r.servers[2].callback_port);

    const old = r.engine[3];
    try testing.expectEqualStrings("https://old.example/sse", old.transport.sse.url);

    try testing.expectEqual(@as(?Held, .disabled), r.servers[3].held);
    try testing.expectEqual(@as(?Held, .waiting_for_approval), r.servers[4].held);
    try testing.expectEqual(@as(?Held, .rejected), r.servers[5].held);
    try testing.expectEqual(@as(?Held, null), r.servers[6].held);
    try testing.expectEqual(@as(?Held, .missing_env), r.servers[7].held);
    try testing.expectEqual(@as(?Held, .unsupported), r.servers[8].held);
    try testing.expectEqualStrings("NOT_SET", r.servers[7].missing.?);
}

test "Slack signs in as fx's Slack app on port 3118 with the app's scopes, unless the config names its own app or port; no other server does" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var inherited: std.process.Environ.Map = .init(testing.allocator);
    defer inherited.deinit();
    const configs = [_]McpServerConfig{
        .{ .name = "slack", .transport = .http, .url = "https://mcp.slack.com/mcp" },
        .{ .name = "mine", .transport = .http, .url = "https://mcp.slack.com/mcp", .auth = .{ .client_id = @constCast("my-app") } },
        .{ .name = "linear", .transport = .http, .url = "https://mcp.linear.app/mcp" },
        .{ .name = "posing", .transport = .http, .url = "https://mcp.example.com/mcp", .auth = .{ .client_id = @constCast(slack.client_id) } },
        .{ .name = "ported", .transport = .http, .url = "https://mcp.slack.com/mcp", .auth = .{ .callback_port = 4242 } },
    };
    const r = try resolve(arena_state.allocator(), &configs, &inherited, "/Users/example/repo");
    try testing.expectEqualStrings(slack.client_id, r.engine[0].auth.client_id.?);
    try testing.expect(r.servers[0].slack_app);
    try testing.expectEqual(@as(?u16, 3118), r.servers[0].callback_port);
    try testing.expectEqualStrings(slack.scopes, r.engine[0].auth.scopes.?);
    try testing.expectEqualStrings("https://mcp.slack.com/", r.engine[0].auth.resource.?);
    try testing.expectEqualStrings("my-app", r.engine[1].auth.client_id.?);
    try testing.expect(!r.servers[1].slack_app);
    try testing.expect(r.servers[1].callback_port == null);
    try testing.expect(r.engine[1].auth.scopes == null);
    try testing.expect(r.engine[1].auth.resource == null);
    try testing.expect(r.engine[2].auth.client_id == null);
    try testing.expect(!r.servers[2].slack_app);

    try testing.expectEqualStrings(slack.client_id, r.engine[3].auth.client_id.?);
    try testing.expect(!r.servers[3].slack_app);
    try testing.expect(r.servers[3].callback_port == null);
    try testing.expect(r.engine[3].auth.scopes == null);
    try testing.expect(r.engine[3].auth.resource == null);

    try testing.expect(r.servers[4].slack_app);
    try testing.expectEqual(@as(?u16, 4242), r.servers[4].callback_port);
}

test "a stdio server gets only the MCP SDKs' few variables of fx's, then its own env" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var inherited: std.process.Environ.Map = .init(testing.allocator);
    defer inherited.deinit();
    for ([_][2][]const u8{
        .{ "HOME", "/Users/me" },       .{ "LOGNAME", "me" },          .{ "PATH", "/usr/bin" },
        .{ "SHELL", "() { :; }" },      .{ "TERM", "xterm" },          .{ "USER", "me" },
        .{ "AI_GATEWAY_API_KEY", "k" }, .{ "VERCEL_OIDC_TOKEN", "t" }, .{ "HTTPS_PROXY", "http://p" },
    }) |pair| try inherited.put(pair[0], pair[1]);
    var env = [_]mcp_contract.McpEnvVar{ envVar("GITHUB_TOKEN", "g"), envVar("TERM", "dumb") };
    const configs = [_]McpServerConfig{.{ .name = "gh", .command = "gh-mcp", .env = &env }};
    const r = try resolve(arena_state.allocator(), &configs, &inherited, "/Users/example/repo");
    const got = r.engine[0].transport.stdio.environ_map.?;

    try testing.expectEqual(@as(usize, 8), got.count());
    for ([_][2][]const u8{ .{ "HOME", "/Users/me" }, .{ "LOGNAME", "me" }, .{ "PATH", "/usr/bin" }, .{ "USER", "me" }, .{ "TERM", "dumb" }, .{ "GITHUB_TOKEN", "g" }, .{ "FX_MCP_DEPTH", "1" } }) |pair| {
        try testing.expectEqualStrings(pair[1], got.get(pair[0]).?);
    }
    try testing.expect(got.get("AI_GATEWAY_API_KEY") == null);
    try testing.expect(got.get("VERCEL_OIDC_TOKEN") == null);
    try testing.expect(got.get("HTTPS_PROXY") == null);
}

test "a stdio server starts in the directory its config names" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var inherited: std.process.Environ.Map = .init(testing.allocator);
    defer inherited.deinit();
    const configs = [_]McpServerConfig{
        .{ .name = "proj", .command = "node", .args = &.{"s.js"}, .cwd = @constCast("/work/app") },
        .{ .name = "here", .command = "node", .args = &.{"s.js"} },
    };
    const r = try resolve(arena_state.allocator(), &configs, &inherited, "/Users/example/repo");
    try testing.expectEqualStrings("/work/app", r.engine[0].transport.stdio.cwd.?);
    try testing.expect(r.engine[1].transport.stdio.cwd == null);
}

test "a token from the environment becomes the Authorization header" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var inherited: std.process.Environ.Map = .init(testing.allocator);
    defer inherited.deinit();
    try inherited.put("PLAIN_KEY", "k1");
    const configs = [_]McpServerConfig{
        .{ .name = "plain", .transport = .http, .url = "https://mcp.plain.com/mcp", .bearer_token_env = @constCast("PLAIN_KEY") },
        .{ .name = "unset", .transport = .http, .url = "https://u.example/mcp", .bearer_token_env = @constCast("UNSET_KEY") },
    };
    const r = try resolve(arena_state.allocator(), &configs, &inherited, "/Users/example/repo");
    try testing.expectEqual(@as(usize, 1), r.engine.len);
    try testing.expectEqualStrings("Authorization", r.engine[0].transport.http.headers[0].name);
    try testing.expectEqualStrings("Bearer k1", r.engine[0].transport.http.headers[0].value);
    try testing.expect(r.servers[0].static_credentials);
    try testing.expectEqual(@as(?Held, .missing_env), r.servers[1].held);
    try testing.expectEqualStrings("UNSET_KEY", r.servers[1].missing.?);
}

test "oauth.scopes reach the sign-in space-separated, and without them the server's own are asked for" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var inherited: std.process.Environ.Map = .init(testing.allocator);
    defer inherited.deinit();
    var scopes = [_][]u8{ @constCast("custom.scope"), @constCast("other.scope") };
    const configs = [_]McpServerConfig{
        .{ .name = "scoped", .transport = .http, .url = "https://s.example/mcp", .auth = .{ .scopes = &scopes } },
        .{ .name = "plain", .transport = .http, .url = "https://p.example/mcp", .auth = .{} },
    };
    const r = try resolve(arena_state.allocator(), &configs, &inherited, "/Users/example/repo");
    try testing.expectEqualStrings("custom.scope other.scope", r.engine[0].auth.scopes.?);
    try testing.expectEqual(@as(?[]const u8, null), r.engine[1].auth.scopes);
}

test "a variable a header can't carry holds its server back, named, and never reaches a request" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var inherited: std.process.Environ.Map = .init(testing.allocator);
    defer inherited.deinit();
    try inherited.put("CRLF_KEY", "a\r\nb");
    try inherited.put("LF_TEAM", "x\nInjected: yes");
    try inherited.put("GOOD_TEAM", "a b\tc");
    var lf_team = [_]mcp_contract.McpHttpHeaderEnv{.{ .name = @constCast("X-Team"), .env = @constCast("LF_TEAM") }};
    var good_team = [_]mcp_contract.McpHttpHeaderEnv{.{ .name = @constCast("X-Team"), .env = @constCast("GOOD_TEAM") }};
    const configs = [_]McpServerConfig{
        .{ .name = "token", .transport = .http, .url = "https://t.example/mcp", .bearer_token_env = @constCast("CRLF_KEY") },
        .{ .name = "header", .transport = .http, .url = "https://h.example/mcp", .header_env = &lf_team },
        .{ .name = "good", .transport = .http, .url = "https://g.example/mcp", .header_env = &good_team },
    };
    const r = try resolve(arena_state.allocator(), &configs, &inherited, "/Users/example/repo");
    try testing.expectEqual(@as(usize, 1), r.engine.len);
    try testing.expectEqualStrings("a b\tc", r.engine[0].transport.http.headers[0].value);
    try testing.expectEqual(@as(?Held, .invalid_env), r.servers[0].held);
    try testing.expectEqualStrings("CRLF_KEY", r.servers[0].missing.?);
    try testing.expectEqual(@as(?Held, .invalid_env), r.servers[1].held);
    try testing.expectEqualStrings("LF_TEAM", r.servers[1].missing.?);
}

test "a stdio server's command line quotes what a shell would split" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("node server.js --port 3", try commandLine(arena.allocator(), "node", &.{ "server.js", "--port", "3" }));
    try std.testing.expectEqualStrings("npx '' 'a b' 'it'\\''s' '$HOME'", try commandLine(arena.allocator(), "npx", &.{ "", "a b", "it's", "$HOME" }));
}

test "a stdio server started through npx or npm waits ten minutes to start unless a timeout was set" {
    const cases = [_]struct { config: McpServerConfig, want: u32 }{
        .{ .config = .{ .name = "a", .command = "npx" }, .want = 600_000 },
        .{ .config = .{ .name = "b", .command = "/usr/local/bin/npm" }, .want = 600_000 },
        .{ .config = .{ .name = "c", .command = "C:\\node\\NPX.CMD" }, .want = 600_000 },
        .{ .config = .{ .name = "d", .command = "node" }, .want = 30_000 },
        .{ .config = .{ .name = "e", .command = "npxx" }, .want = 30_000 },
        .{ .config = .{ .name = "f", .command = "npx", .startup_timeout_ms = 30_000, .startup_timeout_configured = true }, .want = 30_000 },
        .{ .config = .{ .name = "g", .command = "npx", .startup_timeout_ms = 5_000 }, .want = 5_000 },
        .{ .config = .{ .name = "h", .transport = .http, .url = "https://example.test/npx" }, .want = 30_000 },
    };
    for (cases) |case| try testing.expectEqual(case.want, startupTimeoutMs(&case.config));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var inherited: std.process.Environ.Map = .init(testing.allocator);
    defer inherited.deinit();
    const configs = [_]McpServerConfig{.{ .name = "pkg", .command = "npx", .args = &.{ "-y", "server" } }};
    const r = try resolve(arena.allocator(), &configs, &inherited, "/Users/example/repo");
    try testing.expectEqual(@as(u32, 600_000), r.engine[0].timeouts.?.start_ms);
}

test "a stdio server is told how deep it is nested and nothing is started two levels down" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var inherited: std.process.Environ.Map = .init(testing.allocator);
    defer inherited.deinit();
    try testing.expectEqual(@as(u32, 0), nestingDepth(&inherited));
    try testing.expect(!tooDeep(0));
    try testing.expect(!tooDeep(1));
    try testing.expect(tooDeep(2));

    var env = [_]mcp_contract.McpEnvVar{envVar("FX_MCP_DEPTH", "0")};
    const configs = [_]McpServerConfig{
        .{ .name = "self", .command = "fx", .env = &env },
        .{ .name = "web", .transport = .http, .url = "https://example.test/mcp" },
    };
    const top = try resolve(arena.allocator(), &configs, &inherited, "/Users/example/repo");
    try testing.expectEqual(@as(usize, 2), top.engine.len);
    try testing.expectEqualStrings("1", top.engine[0].transport.stdio.environ_map.?.get("FX_MCP_DEPTH").?);

    try inherited.put("FX_MCP_DEPTH", "1");
    const inner = try resolve(arena.allocator(), &configs, &inherited, "/Users/example/repo");
    try testing.expectEqualStrings("2", inner.engine[0].transport.stdio.environ_map.?.get("FX_MCP_DEPTH").?);

    try inherited.put("FX_MCP_DEPTH", "2");
    const deepest = try resolve(arena.allocator(), &configs, &inherited, "/Users/example/repo");
    try testing.expectEqual(@as(usize, 0), deepest.engine.len);
    try testing.expectEqual(@as(?Held, .nested), deepest.servers[0].held);
    try testing.expectEqual(@as(?Held, .nested), deepest.servers[1].held);

    try inherited.put("FX_MCP_DEPTH", "not a number");
    try testing.expectEqual(max_depth, nestingDepth(&inherited));
}

test "only the servers that will start contribute their ignore lines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var inherited: std.process.Environ.Map = .init(testing.allocator);
    defer inherited.deinit();
    const configs = [_]McpServerConfig{
        .{ .name = "on", .command = "node", .ignore = &.{ ".on-state/", "cache/" } },
        .{ .name = "off", .command = "node", .enabled = false, .ignore = &.{".off-state/"} },
        .{ .name = "plain", .command = "node" },
    };
    const r = try resolve(arena.allocator(), &configs, &inherited, "/Users/example/repo");
    const lines = try ignoreLines(arena.allocator(), &configs, r.servers);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings(".on-state/", lines[0]);
    try testing.expectEqualStrings("cache/", lines[1]);
}

test "a stdio server is told the project root in CLAUDE_PROJECT_DIR unless its own env sets it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var inherited: std.process.Environ.Map = .init(testing.allocator);
    defer inherited.deinit();
    var own = [_]mcp_contract.McpEnvVar{envVar("CLAUDE_PROJECT_DIR", "/elsewhere")};
    const configs = [_]McpServerConfig{
        .{ .name = "plain", .command = "node" },
        .{ .name = "own", .command = "node", .env = &own },
    };
    const r = try resolve(arena.allocator(), &configs, &inherited, "/Users/example/repo");
    try testing.expectEqualStrings("/Users/example/repo", r.engine[0].transport.stdio.environ_map.?.get(project_dir_variable).?);
    try testing.expectEqualStrings("/elsewhere", r.engine[1].transport.stdio.environ_map.?.get(project_dir_variable).?);
}

test "a url that still holds a ${VAR} is held back naming the variable, never connected to" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var inherited: std.process.Environ.Map = .init(testing.allocator);
    defer inherited.deinit();
    const configs = [_]McpServerConfig{
        .{ .name = "templated", .transport = .http, .url = "${API_BASE:-https://a.example}/mcp" },
        .{ .name = "plain", .transport = .http, .url = "https://p.example/mcp" },
    };
    const r = try resolve(arena.allocator(), &configs, &inherited, "/Users/example/repo");
    try testing.expectEqual(@as(usize, 1), r.engine.len);
    try testing.expectEqual(@as(?Held, .missing_env), r.servers[0].held);
    try testing.expectEqualStrings("API_BASE", r.servers[0].missing.?);
}

test "a headersHelper's printed JSON object becomes the server's headers, and anything else holds the server back" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const produced = (try helperHeaders(arena, "{\"Authorization\":\"Bearer t1\",\"X-Team\":\"core\"}\n")).?;
    try testing.expectEqual(@as(usize, 2), produced.len);
    try testing.expectEqualStrings("Authorization", produced[0].name);
    try testing.expectEqualStrings("Bearer t1", produced[0].value);
    try testing.expectEqualStrings("core", produced[1].value);
    try testing.expect((try helperHeaders(arena, "")) == null);
    try testing.expect((try helperHeaders(arena, "[\"a\"]")) == null);
    try testing.expect((try helperHeaders(arena, "{\"X-Count\":3}")) == null);

    if (@import("builtin").target.os.tag == .windows or @import("builtin").target.os.tag == .wasi) return;
    var inherited: std.process.Environ.Map = .init(testing.allocator);
    defer inherited.deinit();
    const configs = [_]McpServerConfig{
        .{ .name = "signed", .transport = .http, .url = "https://s.example/mcp", .headers_helper = @constCast("printf '{\"X-Server\":\"%s\"}' \"$CLAUDE_CODE_MCP_SERVER_NAME\"") },
        .{ .name = "broken", .transport = .http, .url = "https://b.example/mcp", .headers_helper = @constCast("exit 3") },
        .{ .name = "garbled", .transport = .http, .url = "https://g.example/mcp", .headers_helper = @constCast("printf 'not json'") },
    };
    const r = try resolve(arena, &configs, &inherited, "/tmp");
    try testing.expectEqual(@as(usize, 1), r.engine.len);
    try testing.expectEqualStrings("X-Server", r.engine[0].transport.http.headers[0].name);
    try testing.expectEqualStrings("signed", r.engine[0].transport.http.headers[0].value);
    try testing.expectEqualStrings("printf '{\"X-Server\":\"%s\"}' \"$CLAUDE_CODE_MCP_SERVER_NAME\"", r.servers[0].headers_helper.?);
    try testing.expectEqual(@as(?Held, .invalid_env), r.servers[1].held);
    try testing.expectEqualStrings(headers_helper_key, r.servers[1].missing.?);
    try testing.expectEqual(@as(?Held, .invalid_env), r.servers[2].held);
}
