const std = @import("std");
const profile_paths = @import("../shared/profile_paths.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const mcp_contract = @import("mcp_contract.zig");
const http_config = @import("http_config.zig");
const text_utils = @import("../shared/text_utils.zig");
const mem_utils = @import("../shared/mem_utils.zig");
const ignore_lines = @import("ignore_lines.zig");

const Allocator = std.mem.Allocator;
const McpAuthConfig = mcp_contract.McpAuthConfig;
const McpEnvVar = mcp_contract.McpEnvVar;
const McpHttpHeader = mcp_contract.McpHttpHeader;
const McpHttpHeaderEnv = mcp_contract.McpHttpHeaderEnv;
const McpServerConfig = mcp_contract.McpServerConfig;
const McpTransport = mcp_contract.McpTransport;

pub const enabled_servers_key = "enabledMcpjsonServers";
pub const disabled_servers_key = "disabledMcpjsonServers";
pub const enable_all_key = "enableAllProjectMcpServers";

pub const ProjectMcpChoices = struct {
    enable_all: bool = false,
    approved: [][]u8 = &.{},
    rejected: [][]u8 = &.{},

    pub fn deinit(self: *ProjectMcpChoices, alloc: Allocator) void {
        freeOwnedStrings(alloc, self.approved);
        freeOwnedStrings(alloc, self.rejected);
        self.* = undefined;
    }
};

pub const ProjectMcpAction = union(enum) {
    approve: []const u8,
    reject: []const u8,
    approve_all,
    reset,
};

pub const ProjectMcpTransition = struct {
    choices: ProjectMcpChoices,
    authority_reduced: bool,
};

const ParsePolicy = struct {
    source: mcp_contract.ConfigSource,
    scope: mcp_contract.ConfigScope,
    force_optional: bool = false,
    allow_stored_credentials: bool = false,
    allow_authorization_header: bool = false,
    workspace_admission: ?mcp_contract.WorkspaceAdmission = null,
};

const ParsedTimeouts = struct {
    startup_ms: u32,
    operation_ms: u32,
    startup_configured: bool,
    operation_configured: bool,
};

pub const WorkspaceDiagnosticCause = enum {
    invalid_json,
    root_must_be_object,
    servers_must_be_object,
    invalid_entry,
    missing_environment_variable,
    environment_expansion_limit_exceeded,
    approved_rejected_overlap,
    ignored_alias,
    ignored_key,
    managed_unreadable,
    managed_denied,
    managed_not_allowed,
    managed_refused,
};

pub const IgnoredKey = enum { required, restart_limit };

pub const WorkspaceEnvironmentField = enum {
    command,
    argument,
    environment,
    http_header,
    url,
};

pub const EntryProblem = enum {
    not_object,
    command,
    type,
    url,
    headers,
    authorization,
    oauth,
    env,
    bearer_token_env,
    enabled,
    required,
    startup_timeout_ms,
    operation_timeout_ms,
    restart_limit,
    cwd,
    ignore,
    deferred,
    environment_id,
    remote_environment,
    variable,
    name,
    websocket,
    other,
};

fn noteInvalidEntry(alloc: Allocator, notes: *std.ArrayList(WorkspaceDiagnostic), profile: bool, name: []const u8, err: anyerror) Allocator.Error!void {
    const owned = try alloc.dupe(u8, name);
    errdefer alloc.free(owned);
    try notes.append(alloc, .{ .profile = profile, .server_name = owned, .cause = .invalid_entry, .problem = entryProblem(err) });
}

fn entryProblem(err: anyerror) EntryProblem {
    return switch (err) {
        error.McpConfigServerMustBeObject => .not_object,
        error.McpConfigInvalidCommand => .command,
        error.McpConfigInvalidType => .type,
        error.McpConfigMissingUrl, error.McpConfigInvalidUrl => .url,
        error.McpConfigInvalidHeaders => .headers,
        error.McpConfigAuthorizationHeader => .authorization,
        error.McpConfigInvalidOAuth => .oauth,
        error.McpConfigInvalidEnvironment => .env,
        error.McpConfigInvalidBearerEnvironment => .bearer_token_env,
        error.McpConfigInvalidEnabled => .enabled,
        error.McpConfigInvalidRequired => .required,
        error.McpConfigInvalidStartupTimeout => .startup_timeout_ms,
        error.McpConfigInvalidOperationTimeout => .operation_timeout_ms,
        error.McpConfigInvalidRestartLimit => .restart_limit,
        error.McpConfigInvalidCwd => .cwd,
        error.McpConfigInvalidIgnore => .ignore,
        error.McpConfigInvalidDeferred => .deferred,
        error.McpConfigInvalidEnvironmentId => .environment_id,
        error.McpConfigRemoteEnvironment => .remote_environment,
        error.McpConfigWebSocket => .websocket,
        else => .other,
    };
}

pub const WorkspaceDiagnostic = struct {
    profile: bool = false,
    server_name: ?[]u8 = null,
    environment_variable: ?[]u8 = null,
    environment_field: ?WorkspaceEnvironmentField = null,
    problem: ?EntryProblem = null,
    ignored_key: ?IgnoredKey = null,
    cause: WorkspaceDiagnosticCause,

    pub fn deinit(self: *WorkspaceDiagnostic, alloc: Allocator) void {
        if (self.server_name) |name| alloc.free(name);
        if (self.environment_variable) |name| alloc.free(name);
        self.* = undefined;
    }
};

pub fn renderWorkspaceDiagnostic(
    alloc: Allocator,
    diagnostic: WorkspaceDiagnostic,
) ![]u8 {
    var encoded_server = try text_utils.encodeTerminalSafe(
        alloc,
        diagnostic.server_name orelse "unknown",
        160,
    );
    defer encoded_server.deinit(alloc);
    if (diagnostic.cause == .missing_environment_variable) {
        var encoded_variable = try text_utils.encodeTerminalSafe(
            alloc,
            diagnostic.environment_variable orelse "unknown",
            max_rendered_environment_name_bytes,
        );
        defer encoded_variable.deinit(alloc);
        const field = if (diagnostic.environment_field) |value|
            @tagName(value)
        else
            "value";
        return alloc.print(
            "{s} server '{s}' field {s} requires environment variable '{s}'; set it or use ${{{s}:-default}}.",
            .{
                diagnosticFile(diagnostic),
                encoded_server.bytes,
                field,
                encoded_variable.bytes,
                encoded_variable.bytes,
            },
        );
    }
    switch (diagnostic.cause) {
        .managed_unreadable => return alloc.dupe(u8, "fx can't read this machine's managed MCP policy, so no MCP server is loaded; ask your administrator to fix it."),
        .managed_denied, .managed_not_allowed, .managed_refused => |cause| return alloc.print(
            "MCP server '{s}' is not loaded: this machine's managed MCP policy {s}.",
            .{ encoded_server.bytes, switch (cause) {
                .managed_denied => "denies it",
                .managed_not_allowed => "doesn't list it as allowed",
                else => "adds only https servers of type http or sse, with no command, args, env or headersHelper",
            } },
        ),
        else => {},
    }
    if (diagnostic.cause == .ignored_key) return alloc.print(
        "{s} server '{s}' sets \"{s}\", which fx ignores; remove it.",
        .{ diagnosticFile(diagnostic), encoded_server.bytes, @tagName(diagnostic.ignored_key orelse .required) },
    );

    const why: []const u8 = if (diagnostic.cause == .invalid_entry) switch (diagnostic.problem orelse .other) {
        .not_object => "it isn't a JSON object",
        .command => "it needs a \"command\", with any \"args\" as strings",
        .variable => "a ${...} in it isn't valid",
        .name => "its name has a character fx won't print",
        .websocket => "its \"type\" is \"ws\", and fx connects to MCP servers over http, sse or stdio only",
        .remote_environment => "its \"environment_id\" names a remote environment, and fx starts MCP servers only on this machine; remove it or set it to \"local\"",
        .authorization => "fx won't send its Authorization header; put the token in \"bearerTokenEnvVar\", or sign in with login",
        .ignore => "its \"ignore\" must be a list of at most 64 relative .gitignore lines with no .. segment and no leading !",
        .other => "fx can't read it",
        inline else => |field| "its \"" ++ @tagName(field) ++ "\" isn't valid",
    } else if (diagnostic.cause == .ignored_alias)
        "the file has both \"mcpServers\" and \"mcp\", and fx reads only \"mcpServers\"; merge them into one"
    else
        @tagName(diagnostic.cause);
    return alloc.print(
        "{s} server '{s}' was skipped: {s}.",
        .{ diagnosticFile(diagnostic), encoded_server.bytes, why },
    );
}

pub fn noteIgnoredKeys(
    alloc: Allocator,
    notes: *std.ArrayList(WorkspaceDiagnostic),
    configs: []const McpServerConfig,
) Allocator.Error!void {
    for (configs) |c| {
        const keys = [_]?IgnoredKey{
            if (c.required) .required else null,
            if (c.restart_limit != mcp_contract.default_restart_limit) .restart_limit else null,
        };
        for (keys) |maybe| if (maybe) |key| {
            const owned = try alloc.dupe(u8, c.name);
            errdefer alloc.free(owned);
            try notes.append(alloc, .{ .profile = c.source != .workspace, .server_name = owned, .cause = .ignored_key, .ignored_key = key });
        };
    }
}

fn diagnosticFile(diagnostic: WorkspaceDiagnostic) []const u8 {
    return if (diagnostic.profile) profile_paths.displayText("~/.fx/mcp.json") else ".mcp.json";
}

pub const WorkspaceParseResult = struct {
    configs: std.ArrayList(McpServerConfig) = .empty,
    diagnostics: std.ArrayList(WorkspaceDiagnostic) = .empty,

    pub fn deinit(self: *WorkspaceParseResult, alloc: Allocator) void {
        for (self.configs.items) |*config| config.deinit(alloc);
        self.configs.deinit(alloc);
        for (self.diagnostics.items) |*diagnostic| diagnostic.deinit(alloc);
        self.diagnostics.deinit(alloc);
        self.* = undefined;
    }
};

const ProfileDiagnosticCause = mcp_contract.ProfileConfigWarningCause;
pub const ProfileDiagnostic = mcp_contract.ProfileConfigWarning;

pub const ProfileParseResult = struct {
    configs: std.ArrayList(McpServerConfig) = .empty,
    diagnostic: ?ProfileDiagnostic = null,
    mutation_allowed: bool = true,

    pub fn deinit(self: *ProfileParseResult, alloc: Allocator) void {
        deinitConfigs(alloc, &self.configs);
        self.* = undefined;
    }
};

const max_profile_root_scan_entries: usize = 64;
const max_profile_child_scan_entries: usize = 64;
const max_profile_key_bytes: usize = mcp_contract.max_profile_config_warning_key_bytes;

const SuspiciousKeyScan = union(enum) {
    clear,
    found: struct {
        key: []const u8,
        additional_matches: usize,
    },
    indeterminate,
};

pub fn parseProfileJson(alloc: Allocator, json_text: []const u8) !std.ArrayList(McpServerConfig) {
    return parseProfileServers(alloc, json_text, null);
}

pub fn parseProfileServers(alloc: Allocator, json_text: []const u8, skipped: ?*std.ArrayList(WorkspaceDiagnostic)) !std.ArrayList(McpServerConfig) {
    var result = try parseProfileDocumentInto(alloc, json_text, skipped);
    defer result.deinit(alloc);
    const configs = result.configs;
    result.configs = .empty;
    return configs;
}

inline fn failProfileParse(err: anytype) @TypeOf(err)!ProfileParseResult {
    return @errorCast(failProfileParseDynamic(err));
}

noinline fn failProfileParseDynamic(err: anyerror) anyerror!ProfileParseResult {
    return err;
}

pub fn parseProfileDocument(alloc: Allocator, json_text: []const u8) !ProfileParseResult {
    return parseProfileDocumentInto(alloc, json_text, null);
}

fn parseProfileDocumentInto(alloc: Allocator, json_text: []const u8, skipped: ?*std.ArrayList(WorkspaceDiagnostic)) !ProfileParseResult {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return failProfileParse(error.OutOfMemory),
        else => return failProfileParse(error.McpConfigInvalidJson),
    };
    defer parsed.deinit();
    if (parsed.value != .object) return failProfileParse(error.McpConfigRootMustBeObject);

    const object = parsed.value.object;
    const canonical = object.get("mcpServers");
    const alias = object.get("mcp");
    if (canonical orelse alias) |servers| {
        var result = ProfileParseResult{ .configs = try parseProfileServerMap(alloc, servers, skipped) };
        errdefer result.deinit(alloc);
        switch (scanSuspiciousProfileKeys(object)) {
            .clear => if (canonical != null and alias != null and profileAliasIsNonEmpty(alias.?)) {
                result.diagnostic = ProfileDiagnostic.init(
                    .ignored_mcp_alias,
                    "mcp",
                    0,
                );
                if (skipped) |notes| try noteIgnoredAlias(alloc, notes, canonical.?, alias.?);
            },
            .found => |found| {
                result.diagnostic = ProfileDiagnostic.init(
                    .suspicious_server_key,
                    found.key,
                    found.additional_matches,
                );
                result.mutation_allowed = false;
            },
            .indeterminate => {
                result.diagnostic = ProfileDiagnostic.init(
                    .suspicious_key_scan_indeterminate,
                    null,
                    0,
                );
                result.mutation_allowed = false;
            },
        }
        return result;
    }

    return switch (scanSuspiciousProfileKeys(object)) {
        .clear => .{},
        .found => |found| blk: {
            break :blk .{
                .diagnostic = ProfileDiagnostic.init(
                    .suspicious_server_key,
                    found.key,
                    found.additional_matches,
                ),
                .mutation_allowed = false,
            };
        },
        .indeterminate => .{
            .diagnostic = ProfileDiagnostic.init(
                .suspicious_key_scan_indeterminate,
                null,
                0,
            ),
            .mutation_allowed = false,
        },
    };
}

fn parseProfileServerMap(
    alloc: Allocator,
    servers: std.json.Value,
    skipped: ?*std.ArrayList(WorkspaceDiagnostic),
) !std.ArrayList(McpServerConfig) {
    if (servers != .object) return error.McpConfigServersMustBeObject;

    var configs: std.ArrayList(McpServerConfig) = .empty;
    errdefer deinitConfigs(alloc, &configs);
    var it = servers.object.iterator();
    while (it.next()) |entry| {
        const config = parseServerEntry(alloc, entry.key_ptr.*, entry.value_ptr.*, .{
            .source = .profile,
            .scope = .profile,
            .allow_stored_credentials = true,
        }) catch |err| {
            const notes = skipped orelse return err;
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try noteInvalidEntry(alloc, notes, true, entry.key_ptr.*, err);
            continue;
        };
        configs.append(alloc, config) catch |err| {
            var mutable = config;
            mutable.deinit(alloc);
            return err;
        };
    }
    return configs;
}

fn noteIgnoredAlias(
    alloc: Allocator,
    notes: *std.ArrayList(WorkspaceDiagnostic),
    canonical: std.json.Value,
    alias: std.json.Value,
) !void {
    if (alias != .object) return;
    for (alias.object.keys()) |name| {
        if (canonical == .object and canonical.object.contains(name)) continue;
        const owned = try alloc.dupe(u8, name);
        errdefer alloc.free(owned);
        try notes.append(alloc, .{ .profile = true, .server_name = owned, .cause = .ignored_alias });
    }
}

fn profileAliasIsNonEmpty(value: std.json.Value) bool {
    return switch (value) {
        .object => value.object.count() > 0,
        .array => value.array.items.len > 0,
        .string => value.string.len > 0,
        .null => false,
        else => true,
    };
}

fn scanSuspiciousProfileKeys(object: std.json.ObjectMap) SuspiciousKeyScan {
    if (object.count() > max_profile_root_scan_entries) return .indeterminate;

    var first: ?[]const u8 = null;
    var additional_matches: usize = 0;
    var it = object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "mcp") or std.mem.eql(u8, key, "mcpServers")) continue;
        if (key.len > max_profile_key_bytes) {
            if (serverMapShape(value) != .clear) return .indeterminate;
            continue;
        }
        if (!isSuspiciousNormalizedKey(key)) continue;
        switch (serverMapShape(value)) {
            .clear => {},
            .match => {
                if (first == null) {
                    first = key;
                } else {
                    additional_matches += 1;
                }
            },
            .indeterminate => return .indeterminate,
        }
    }
    if (first) |key| return .{ .found = .{
        .key = key,
        .additional_matches = additional_matches,
    } };
    return .clear;
}

const ServerMapShape = enum { clear, match, indeterminate };

fn serverMapShape(value: std.json.Value) ServerMapShape {
    if (value != .object) return .clear;
    var inspected: usize = 0;
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (inspected == max_profile_child_scan_entries) return .indeterminate;
        inspected += 1;
        if (serverEntryShape(entry.value_ptr.*)) return .match;
    }
    return .clear;
}

fn serverEntryShape(value: std.json.Value) bool {
    if (value != .object) return false;
    if (value.object.get("command")) |command| {
        if (command == .string or command == .array) return true;
    }
    if (value.object.get("url")) |url| if (url == .string) return true;
    if (value.object.get("type")) |kind| {
        if (kind != .string) return false;
        return std.mem.eql(u8, kind.string, "local") or
            std.mem.eql(u8, kind.string, "stdio") or
            std.mem.eql(u8, kind.string, "http") or
            std.mem.eql(u8, kind.string, "streamable-http") or
            std.mem.eql(u8, kind.string, "sse");
    }
    return false;
}

fn isSuspiciousNormalizedKey(raw: []const u8) bool {
    var normalized: [max_profile_key_bytes]u8 = undefined;
    var len: usize = 0;
    for (raw) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) continue;
        normalized[len] = std.ascii.toLower(byte);
        len += 1;
    }
    const key = normalized[0..len];
    return std.mem.eql(u8, key, "mcpserver") or
        std.mem.eql(u8, key, "mcpservers") or
        std.mem.eql(u8, key, "modelcontextprotocol") or
        std.mem.eql(u8, key, "modelcontextprotocolserver") or
        std.mem.eql(u8, key, "modelcontextprotocolservers") or
        std.mem.eql(u8, key, "servers");
}

pub fn parseWorkspaceJson(
    alloc: Allocator,
    json_text: []const u8,
    scope: mcp_contract.ConfigScope,
    choices: ProjectMcpChoices,
) Allocator.Error!WorkspaceParseResult {
    return parseWorkspaceJsonInternal(alloc, json_text, scope, choices);
}

pub fn parseWorkspaceJsonWithEnvironment(
    alloc: Allocator,
    json_text: []const u8,
    scope: mcp_contract.ConfigScope,
    choices: ProjectMcpChoices,
    environment: *const std.process.Environ.Map,
) Allocator.Error!WorkspaceParseResult {
    var result = try parseWorkspaceJsonInternal(alloc, json_text, scope, choices);
    errdefer result.deinit(alloc);
    try expandApprovedWorkspaceConfigs(alloc, &result, environment);
    return result;
}

fn parseWorkspaceJsonInternal(
    alloc: Allocator,
    json_text: []const u8,
    scope: mcp_contract.ConfigScope,
    choices: ProjectMcpChoices,
) Allocator.Error!WorkspaceParseResult {
    var result: WorkspaceParseResult = .{};
    errdefer result.deinit(alloc);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try result.diagnostics.append(alloc, .{ .cause = .invalid_json });
            return result;
        },
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try result.diagnostics.append(alloc, .{ .cause = .root_must_be_object });
        return result;
    }
    const servers = parsed.value.object.get("mcpServers") orelse return result;
    if (servers != .object) {
        try result.diagnostics.append(alloc, .{ .cause = .servers_must_be_object });
        return result;
    }

    var it = servers.object.iterator();
    while (it.next()) |entry| {
        const admission = resolveAdmission(entry.key_ptr.*, choices);
        const config = parseServerEntry(alloc, entry.key_ptr.*, entry.value_ptr.*, .{
            .source = .workspace,
            .scope = scope,
            .force_optional = true,
            .allow_stored_credentials = false,
            .allow_authorization_header = true,
            .workspace_admission = admission,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try noteInvalidEntry(alloc, &result.diagnostics, false, entry.key_ptr.*, err);
                continue;
            },
        };
        result.configs.append(alloc, config) catch |err| {
            var mutable = config;
            mutable.deinit(alloc);
            return err;
        };
    }
    return result;
}

pub fn expandApprovedWorkspaceConfigs(
    alloc: Allocator,
    result: *WorkspaceParseResult,
    environment: *const std.process.Environ.Map,
) Allocator.Error!void {
    return expandConfigs(alloc, &result.configs, &result.diagnostics, environment, false);
}

pub fn expandProfileConfigs(
    alloc: Allocator,
    configs: *std.ArrayList(McpServerConfig),
    diagnostics: *std.ArrayList(WorkspaceDiagnostic),
    environment: *const std.process.Environ.Map,
) Allocator.Error!void {
    return expandConfigs(alloc, configs, diagnostics, environment, true);
}

fn expandConfigs(
    alloc: Allocator,
    configs: *std.ArrayList(McpServerConfig),
    diagnostics: *std.ArrayList(WorkspaceDiagnostic),
    environment: *const std.process.Environ.Map,
    profile: bool,
) Allocator.Error!void {
    var expansion_budget = WorkspaceExpansionBudget.init();
    var index: usize = 0;
    while (index < configs.items.len) {
        const config = &configs.items[index];
        const expands = if (profile) config.source == .profile else config.workspace_admission == .approved;
        if (!expands) {
            index += 1;
            continue;
        }
        const failure = try expandWorkspaceConfig(
            alloc,
            config,
            environment,
            &expansion_budget,
        ) orelse {
            index += 1;
            continue;
        };
        const server_name = try alloc.dupe(u8, config.name);
        errdefer mem_utils.free(alloc, server_name);
        switch (failure) {
            .missing => |missing| {
                errdefer mem_utils.free(alloc, missing.variable_name);
                try diagnostics.append(alloc, .{
                    .profile = profile,
                    .server_name = server_name,
                    .environment_variable = missing.variable_name,
                    .environment_field = missing.field,
                    .cause = .missing_environment_variable,
                });
            },
            .invalid => try diagnostics.append(alloc, .{
                .profile = profile,
                .server_name = server_name,
                .cause = .invalid_entry,
                .problem = .variable,
            }),
            .invalid_url => try diagnostics.append(alloc, .{
                .profile = profile,
                .server_name = server_name,
                .cause = .invalid_entry,
                .problem = .url,
            }),
            .limit_exceeded => try diagnostics.append(alloc, .{
                .profile = profile,
                .server_name = server_name,
                .cause = .environment_expansion_limit_exceeded,
            }),
        }
        var removed = configs.orderedRemove(index);
        removed.deinit(alloc);
    }
}

const max_rendered_environment_name_bytes: usize = 128;
const max_expanded_workspace_value_bytes: usize = 1024 * 1024;
const max_expanded_workspace_total_bytes: usize = 1024 * 1024;

const WorkspaceExpansionBudget = struct {
    remaining: usize,

    fn init() WorkspaceExpansionBudget {
        return .{ .remaining = max_expanded_workspace_total_bytes };
    }

    fn consume(self: *WorkspaceExpansionBudget, byte_count: usize) bool {
        if (byte_count > self.remaining) {
            self.remaining = 0;
            return false;
        }
        self.remaining -= byte_count;
        return true;
    }
};

const WorkspaceTemplateExpansion = union(enum) {
    expanded: []u8,
    missing: []u8,
    invalid,
    limit_exceeded,

    pub fn deinit(self: *WorkspaceTemplateExpansion, alloc: Allocator) void {
        switch (self.*) {
            .expanded, .missing => |value| alloc.free(value),
            .invalid, .limit_exceeded => {},
        }
        self.* = undefined;
    }
};

fn expandWorkspaceTemplate(
    alloc: Allocator,
    input: []const u8,
    environment: *const std.process.Environ.Map,
    budget: *WorkspaceExpansionBudget,
) Allocator.Error!WorkspaceTemplateExpansion {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(alloc);

    var cursor: usize = 0;
    while (cursor < input.len) {
        const relative_start = std.mem.find(u8, input[cursor..], "${") orelse {
            if (!try appendExpandedBytes(alloc, &output, input[cursor..], budget)) return .limit_exceeded;
            return .{ .expanded = try output.toOwnedSlice(alloc) };
        };
        const start = cursor + relative_start;
        if (!try appendExpandedBytes(alloc, &output, input[cursor..start], budget)) return .limit_exceeded;
        const expression_start = start + 2;
        const relative_end = std.mem.findScalar(u8, input[expression_start..], '}') orelse
            return .invalid;
        const end = expression_start + relative_end;
        const expression = input[expression_start..end];
        const default_marker = std.mem.find(u8, expression, ":-");
        const variable_name = if (default_marker) |index| expression[0..index] else expression;
        const default_value = if (default_marker) |index| expression[index + 2 ..] else null;
        if (!isValidEnvName(variable_name)) {
            return .invalid;
        }
        const replacement = environment.get(variable_name) orelse default_value orelse {
            return .{ .missing = try alloc.dupe(u8, variable_name) };
        };
        if (!try appendExpandedBytes(alloc, &output, replacement, budget)) return .limit_exceeded;
        cursor = end + 1;
    }
    return .{ .expanded = try output.toOwnedSlice(alloc) };
}

fn appendExpandedBytes(
    alloc: Allocator,
    output: *std.ArrayList(u8),
    bytes: []const u8,
    budget: *WorkspaceExpansionBudget,
) Allocator.Error!bool {
    if (output.items.len > max_expanded_workspace_value_bytes or
        bytes.len > max_expanded_workspace_value_bytes - output.items.len)
    {
        return false;
    }
    if (!budget.consume(bytes.len)) return false;
    try output.appendSlice(alloc, bytes);
    return true;
}

const WorkspaceExpansionFailure = union(enum) {
    missing: struct {
        field: WorkspaceEnvironmentField,
        variable_name: []u8,
    },
    invalid,
    invalid_url,
    limit_exceeded,
};

pub fn holdsTemplate(text: []const u8) bool {
    return std.mem.find(u8, text, "${") != null;
}

fn expandWorkspaceConfig(
    alloc: Allocator,
    config: *McpServerConfig,
    environment: *const std.process.Environ.Map,
    budget: *WorkspaceExpansionBudget,
) Allocator.Error!?WorkspaceExpansionFailure {
    if (config.command) |*command| {
        if (try expandOwnedConstWorkspaceValue(alloc, command, environment, .command, budget)) |failure| {
            return failure;
        }
    }
    for (@constCast(config.args)) |*argument| {
        if (try expandOwnedConstWorkspaceValue(alloc, argument, environment, .argument, budget)) |failure| {
            return failure;
        }
    }
    if (config.url) |*url| if (holdsTemplate(url.*)) {
        if (try expandOwnedConstWorkspaceValue(alloc, url, environment, .url, budget)) |failure| {
            return failure;
        }
        http_config.validateEndpoint(url.*) catch return .invalid_url;
    };
    for (config.env) |*entry| {
        if (try expandOwnedMutableWorkspaceValue(alloc, &entry.value, environment, .environment, budget)) |failure| {
            return failure;
        }
    }
    for (config.headers) |*header| {
        if (try expandOwnedMutableWorkspaceValue(alloc, &header.value, environment, .http_header, budget)) |failure| {
            return failure;
        }
    }
    http_config.validateStaticHeaders(config.headers) catch return .invalid;
    return null;
}

fn expandOwnedConstWorkspaceValue(
    alloc: Allocator,
    value: *[]const u8,
    environment: *const std.process.Environ.Map,
    field: WorkspaceEnvironmentField,
    budget: *WorkspaceExpansionBudget,
) Allocator.Error!?WorkspaceExpansionFailure {
    var expansion = try expandWorkspaceTemplate(alloc, value.*, environment, budget);
    switch (expansion) {
        .expanded => |expanded| {
            alloc.free(value.*);
            value.* = expanded;
            expansion = undefined;
            return null;
        },
        .missing => |variable_name| {
            expansion = undefined;
            return .{ .missing = .{
                .field = field,
                .variable_name = variable_name,
            } };
        },
        .invalid => return .invalid,
        .limit_exceeded => return .limit_exceeded,
    }
}

fn expandOwnedMutableWorkspaceValue(
    alloc: Allocator,
    value: *[]u8,
    environment: *const std.process.Environ.Map,
    field: WorkspaceEnvironmentField,
    budget: *WorkspaceExpansionBudget,
) Allocator.Error!?WorkspaceExpansionFailure {
    var borrowed: []const u8 = value.*;
    const failure = try expandOwnedConstWorkspaceValue(
        alloc,
        &borrowed,
        environment,
        field,
        budget,
    );
    value.* = @constCast(borrowed);
    return failure;
}

pub fn parseChoices(
    alloc: Allocator,
    workspace_value: ?std.json.Value,
    diagnostics: *std.ArrayList(WorkspaceDiagnostic),
) !ProjectMcpChoices {
    const value = workspace_value orelse return .{};
    if (value != .object) return error.InvalidProjectMcpChoices;
    const object = value.object;
    const approved: [][]u8 = if (object.get(enabled_servers_key)) |field|
        try parseUniqueStringArray(alloc, field)
    else
        @constCast(&.{});
    var approved_owned = true;
    errdefer if (approved_owned) freeOwnedStrings(alloc, approved);
    const rejected: [][]u8 = if (object.get(disabled_servers_key)) |field|
        try parseUniqueStringArray(alloc, field)
    else
        @constCast(&.{});
    var rejected_owned = true;
    errdefer if (rejected_owned) freeOwnedStrings(alloc, rejected);
    const enable_all = if (object.get(enable_all_key)) |field| blk: {
        if (field != .bool) return error.InvalidProjectMcpChoices;
        break :blk field.bool;
    } else false;

    var normalized_approved: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedList(alloc, &normalized_approved);
    try normalized_approved.ensureTotalCapacity(alloc, approved.len);
    for (approved) |name| {
        if (containsName(rejected, name)) {
            const server_name = try alloc.dupe(u8, name);
            errdefer mem_utils.free(alloc, server_name);
            try diagnostics.append(alloc, .{
                .server_name = server_name,
                .cause = .approved_rejected_overlap,
            });
            continue;
        }
        normalized_approved.appendAssumeCapacity(try alloc.dupe(u8, name));
    }
    freeOwnedStrings(alloc, approved);
    approved_owned = false;
    const normalized = try normalized_approved.toOwnedSlice(alloc);
    errdefer freeOwnedStrings(alloc, normalized);
    rejected_owned = false;
    return .{
        .enable_all = enable_all,
        .approved = normalized,
        .rejected = rejected,
    };
}

pub fn applyAction(
    alloc: Allocator,
    current: ProjectMcpChoices,
    action: ProjectMcpAction,
) !ProjectMcpTransition {
    var approved: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedList(alloc, &approved);
    var rejected: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedList(alloc, &rejected);

    switch (action) {
        .approve => |name| {
            try appendNamesExcept(alloc, &approved, current.approved, null);
            if (!containsName(approved.items, name)) try appendOwnedName(alloc, &approved, name);
            try appendNamesExcept(alloc, &rejected, current.rejected, name);
        },
        .reject => |name| {
            try appendNamesExcept(alloc, &approved, current.approved, name);
            try appendNamesExcept(alloc, &rejected, current.rejected, null);
            if (!containsName(rejected.items, name)) try appendOwnedName(alloc, &rejected, name);
        },
        .approve_all => {
            try appendNamesExcept(alloc, &approved, current.approved, null);
            try appendNamesExcept(alloc, &rejected, current.rejected, null);
        },
        .reset => {},
    }

    const authority_reduced = switch (action) {
        .approve, .approve_all => false,
        .reject => |name| current.enable_all or containsName(current.approved, name),
        .reset => current.enable_all or current.approved.len > 0,
    };
    const approved_slice = try approved.toOwnedSlice(alloc);
    errdefer freeOwnedStrings(alloc, approved_slice);
    const rejected_slice = try rejected.toOwnedSlice(alloc);
    return .{
        .choices = .{
            .enable_all = switch (action) {
                .approve_all => true,
                .reset => false,
                else => current.enable_all,
            },
            .approved = approved_slice,
            .rejected = rejected_slice,
        },
        .authority_reduced = authority_reduced,
    };
}

fn resolveAdmission(
    name: []const u8,
    choices: ProjectMcpChoices,
) mcp_contract.WorkspaceAdmission {
    if (containsName(choices.rejected, name)) return .rejected;
    if (choices.enable_all or containsName(choices.approved, name)) return .approved;
    return .pending;
}

pub fn mergeNative(
    alloc: Allocator,
    primary: *std.ArrayList(McpServerConfig),
    workspace: *std.ArrayList(McpServerConfig),
) !std.ArrayList(McpServerConfig) {
    var merged: std.ArrayList(McpServerConfig) = .empty;
    errdefer deinitConfigs(alloc, &merged);
    try merged.ensureTotalCapacity(alloc, primary.items.len + workspace.items.len);
    while (primary.items.len > 0) merged.appendAssumeCapacity(primary.orderedRemove(0));
    while (workspace.items.len > 0) {
        var candidate = workspace.orderedRemove(0);
        if (indexOfConfigName(merged.items, candidate.name)) |index| {
            if (candidate.workspace_admission == .approved) {
                merged.items[index].deinit(alloc);
                merged.items[index] = candidate;
            } else {
                candidate.deinit(alloc);
            }
            continue;
        }
        merged.appendAssumeCapacity(candidate);
    }
    return merged;
}

pub const local_projects_key = "projects";

pub fn localProjectKey(workspace_root: []const u8) []const u8 {
    var end = workspace_root.len;
    while (end > 1 and workspace_root[end - 1] == '/') end -= 1;
    return workspace_root[0..end];
}

pub fn parseLocalServers(
    alloc: Allocator,
    json_text: []const u8,
    workspace_root: []const u8,
    skipped: ?*std.ArrayList(WorkspaceDiagnostic),
) !std.ArrayList(McpServerConfig) {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .empty,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .empty;
    const projects = parsed.value.object.get(local_projects_key) orelse return .empty;
    if (projects != .object) return .empty;
    const project = projects.object.get(localProjectKey(workspace_root)) orelse return .empty;
    if (project != .object) return .empty;
    const servers = project.object.get("mcpServers") orelse return .empty;
    return parseProfileServerMap(alloc, servers, skipped);
}

pub fn overrideWith(
    alloc: Allocator,
    merged: *std.ArrayList(McpServerConfig),
    winners: *std.ArrayList(McpServerConfig),
) Allocator.Error!void {
    try merged.ensureUnusedCapacity(alloc, winners.items.len);
    while (winners.items.len > 0) {
        const candidate = winners.orderedRemove(0);
        if (indexOfConfigName(merged.items, candidate.name)) |index| {
            merged.items[index].deinit(alloc);
            merged.items[index] = candidate;
        } else merged.appendAssumeCapacity(candidate);
    }
}

fn indexOfConfigName(configs: []const McpServerConfig, name: []const u8) ?usize {
    for (configs, 0..) |config, index| {
        if (std.mem.eql(u8, config.name, name)) return index;
    }
    return null;
}

pub fn appendWorkspaceAfterAcpPrimary(
    alloc: Allocator,
    output: *std.ArrayList(McpServerConfig),
    workspace: *std.ArrayList(McpServerConfig),
) !void {
    const primary_len = output.items.len;
    try output.ensureUnusedCapacity(alloc, workspace.items.len);
    while (workspace.items.len > 0) {
        var candidate = workspace.orderedRemove(0);
        if (configNamePresent(output.items[0..primary_len], candidate.name)) {
            candidate.deinit(alloc);
            continue;
        }
        output.appendAssumeCapacity(candidate);
    }
}

inline fn failServerConfig(err: anytype) @TypeOf(err)!McpServerConfig {
    return @errorCast(failServerConfigDynamic(err));
}

noinline fn failServerConfigDynamic(err: anyerror) anyerror!McpServerConfig {
    return err;
}

test "project config failures preserve exact error types and identities" {
    const invalid = failServerConfig(error.McpConfigInvalidType);
    try std.testing.expect(
        @TypeOf(invalid) == error{McpConfigInvalidType}!McpServerConfig,
    );
    try std.testing.expectError(error.McpConfigInvalidType, invalid);
    try std.testing.expectError(
        error.McpConfigServerMustBeObject,
        failServerConfig(error.McpConfigServerMustBeObject),
    );
    try std.testing.expectError(error.OutOfMemory, failServerConfig(error.OutOfMemory));

    const invalid_profile = failProfileParse(error.McpConfigInvalidJson);
    try std.testing.expect(
        @TypeOf(invalid_profile) == error{McpConfigInvalidJson}!ProfileParseResult,
    );
    try std.testing.expectError(error.McpConfigInvalidJson, invalid_profile);
}

fn parseServerEntry(
    alloc: Allocator,
    name: []const u8,
    value: std.json.Value,
    policy: ParsePolicy,
) !McpServerConfig {
    if (value != .object) return failServerConfig(error.McpConfigServerMustBeObject);
    if (!mcp_contract.sourceAllowsScope(policy.source, policy.scope) or
        !mcp_contract.sourceAllowsWorkspaceAdmission(policy.source, policy.workspace_admission))
    {
        return failServerConfig(error.McpConfigPolicyInvalid);
    }
    const object = value.object;
    const type_value = object.get("transport") orelse object.get("type");
    const type_string = if (type_value) |kind_value|
        (if (kind_value == .string) kind_value.string else return failServerConfig(error.McpConfigInvalidType))
    else if (object.get("command") == null and object.get("url") != null)
        "http"
    else
        "local";

    if (std.mem.eql(u8, type_string, "ws")) return failServerConfig(error.McpConfigWebSocket);
    const transport: McpTransport = if (std.mem.eql(u8, type_string, "sse"))
        .sse
    else if (std.mem.eql(u8, type_string, "http") or std.mem.eql(u8, type_string, "streamable-http"))
        .http
    else
        .stdio;
    if (transport == .stdio and
        !std.mem.eql(u8, type_string, "local") and
        !std.mem.eql(u8, type_string, "stdio")) return failServerConfig(error.McpConfigInvalidType);

    const enabled = if (object.get("enabled")) |field|
        if (field == .bool) field.bool else return failServerConfig(error.McpConfigInvalidEnabled)
    else
        true;
    const configured_required = if (object.get("required")) |field|
        if (field == .bool) field.bool else return failServerConfig(error.McpConfigInvalidRequired)
    else
        false;
    const required = if (policy.force_optional) false else configured_required;
    const deferred: ?bool = if (object.get("deferred")) |field|
        if (field == .bool) field.bool else return failServerConfig(error.McpConfigInvalidDeferred)
    else
        null;

    if (transport != .stdio) {
        const url_value = object.get("url") orelse return failServerConfig(error.McpConfigMissingUrl);
        if (url_value != .string) return failServerConfig(error.McpConfigInvalidUrl);
        if (!holdsTemplate(url_value.string)) {
            http_config.validateEndpoint(url_value.string) catch return failServerConfig(error.McpConfigInvalidUrl);
        }
        const timeouts = try parseTimeouts(object);
        const env = try parseSelectedEnvironment(alloc, object);
        errdefer freeEnvVars(alloc, env);
        const headers = try parseRemoteHeaders(
            alloc,
            object,
            policy.allow_authorization_header,
        );
        errdefer freeHttpHeaders(alloc, headers);
        const header_env = try parseRemoteHeaderEnv(alloc, object);
        errdefer freeHttpHeaderEnv(alloc, header_env);
        const bearer_token_env = try parseOptionalOwnedString(alloc, object, "bearerTokenEnvVar");
        errdefer if (bearer_token_env) |field| mem_utils.free(alloc, field);
        if (bearer_token_env) |field| if (!isValidEnvName(field)) return failServerConfig(error.McpConfigInvalidBearerEnvironment);
        const headers_helper = parseOptionalOwnedString(alloc, object, "headersHelper") catch |err| switch (err) {
            error.OutOfMemory => return failServerConfig(error.OutOfMemory),
            else => return failServerConfig(error.McpConfigInvalidHeaders),
        };
        errdefer if (headers_helper) |field| mem_utils.free(alloc, field);
        var auth = parseProfileAuth(alloc, object) catch |err| switch (err) {
            error.OutOfMemory => return failServerConfig(error.OutOfMemory),
            else => return failServerConfig(error.McpConfigInvalidOAuth),
        };
        errdefer if (auth) |*field| field.deinit(alloc);
        const oauth_requested = auth != null or if (object.get("auth")) |field|
            if (field == .string and std.mem.eql(u8, field.string, "oauth")) true else return failServerConfig(error.McpConfigInvalidOAuth)
        else
            false;
        const enabled_tools = parseToolNameFilter(alloc, object, "enabledTools") catch |err| switch (err) {
            error.OutOfMemory => return failServerConfig(error.OutOfMemory),
            else => return failServerConfig(error.McpConfigInvalidToolFilter),
        };
        errdefer mcp_contract.freeToolNames(alloc, enabled_tools);
        const disabled_tools = parseToolNameFilter(alloc, object, "disabledTools") catch |err| switch (err) {
            error.OutOfMemory => return failServerConfig(error.OutOfMemory),
            else => return failServerConfig(error.McpConfigInvalidToolFilter),
        };
        errdefer mcp_contract.freeToolNames(alloc, disabled_tools);
        const ignore = parseIgnoreLines(alloc, object) catch |err| switch (err) {
            error.OutOfMemory => return failServerConfig(error.OutOfMemory),
            else => return failServerConfig(error.McpConfigInvalidIgnore),
        };
        errdefer freeOwnedStrings(alloc, ignore);
        const owned_name = try alloc.dupe(u8, name);
        errdefer mem_utils.free(alloc, owned_name);
        const owned_url = try alloc.dupe(u8, url_value.string);
        return .{
            .ignore = ignore,
            .name = owned_name,
            .source = policy.source,
            .scope = policy.scope,
            .required = required,
            .transport = transport,
            .url = owned_url,
            .env = env,
            .headers = headers,
            .header_env = header_env,
            .bearer_token_env = bearer_token_env,
            .headers_helper = headers_helper,
            .auth = auth,
            .oauth_requested = oauth_requested,
            .allow_stored_credentials = policy.allow_stored_credentials,
            .enabled = enabled,
            .deferred = deferred,
            .workspace_admission = policy.workspace_admission,
            .startup_timeout_ms = timeouts.startup_ms,
            .operation_timeout_ms = timeouts.operation_ms,
            .startup_timeout_configured = timeouts.startup_configured,
            .operation_timeout_configured = timeouts.operation_configured,
            .enabled_tools = enabled_tools,
            .disabled_tools = disabled_tools,
        };
    }

    const timeouts = try parseTimeouts(object);
    const restart_limit = parseUnsignedPolicy(
        object,
        "restart_limit",
        mcp_contract.default_restart_limit,
        0,
        std.math.maxInt(u8),
    ) catch return failServerConfig(error.McpConfigInvalidRestartLimit);
    if (object.get("environment_id")) |field| {
        if (field != .string or field.string.len == 0) return failServerConfig(error.McpConfigInvalidEnvironmentId);
        if (!std.mem.eql(u8, field.string, local_environment_id)) return failServerConfig(error.McpConfigRemoteEnvironment);
    }

    const enabled_tools = parseToolNameFilter(alloc, object, "enabledTools") catch |err| switch (err) {
        error.OutOfMemory => return failServerConfig(error.OutOfMemory),
        else => return failServerConfig(error.McpConfigInvalidToolFilter),
    };
    errdefer mcp_contract.freeToolNames(alloc, enabled_tools);
    const disabled_tools = parseToolNameFilter(alloc, object, "disabledTools") catch |err| switch (err) {
        error.OutOfMemory => return failServerConfig(error.OutOfMemory),
        else => return failServerConfig(error.McpConfigInvalidToolFilter),
    };
    errdefer mcp_contract.freeToolNames(alloc, disabled_tools);
    const command = parseCommandSpec(alloc, object) catch |err| switch (err) {
        error.OutOfMemory => return failServerConfig(error.OutOfMemory),
        else => return failServerConfig(error.McpConfigInvalidCommand),
    };
    errdefer freeParsedCommandSpec(alloc, command);
    const env = try parseSelectedEnvironment(alloc, object);
    errdefer freeEnvVars(alloc, env);
    const cwd = parseWorkingDirectory(alloc, object) catch |err| switch (err) {
        error.OutOfMemory => return failServerConfig(error.OutOfMemory),
        error.McpConfigInvalidCwd => return failServerConfig(error.McpConfigInvalidCwd),
    };
    errdefer if (cwd) |dir| mem_utils.free(alloc, dir);
    const ignore = parseIgnoreLines(alloc, object) catch |err| switch (err) {
        error.OutOfMemory => return failServerConfig(error.OutOfMemory),
        else => return failServerConfig(error.McpConfigInvalidIgnore),
    };
    errdefer freeOwnedStrings(alloc, ignore);
    return .{
        .ignore = ignore,
        .name = try alloc.dupe(u8, name),
        .source = policy.source,
        .scope = policy.scope,
        .required = required,
        .transport = .stdio,
        .command = command.command,
        .args = command.args,
        .cwd = cwd,
        .env = env,
        .enabled = enabled,
        .deferred = deferred,
        .workspace_admission = policy.workspace_admission,
        .startup_timeout_ms = timeouts.startup_ms,
        .operation_timeout_ms = timeouts.operation_ms,
        .startup_timeout_configured = timeouts.startup_configured,
        .operation_timeout_configured = timeouts.operation_configured,
        .restart_limit = @intCast(restart_limit),
        .enabled_tools = enabled_tools,
        .disabled_tools = disabled_tools,
    };
}

const local_environment_id = "local";

fn parseWorkingDirectory(alloc: Allocator, object: std.json.ObjectMap) error{ OutOfMemory, McpConfigInvalidCwd }!?[]u8 {
    const value = object.get("cwd") orelse return null;
    if (value != .string or value.string.len == 0) return error.McpConfigInvalidCwd;
    return try alloc.dupe(u8, value.string);
}

fn parseTimeouts(object: std.json.ObjectMap) error{
    McpConfigInvalidStartupTimeout,
    McpConfigInvalidOperationTimeout,
}!ParsedTimeouts {
    const startup_ms = parseUnsignedPolicy(
        object,
        "startupTimeoutMs",
        mcp_contract.default_startup_timeout_ms,
        1,
        std.math.maxInt(u32),
    ) catch return error.McpConfigInvalidStartupTimeout;
    const operation_key: []const u8 = if (object.get("toolTimeoutMs") != null) "toolTimeoutMs" else "timeout";
    const operation_ms = parseUnsignedPolicy(
        object,
        operation_key,
        mcp_contract.default_operation_timeout_ms,
        1,
        std.math.maxInt(u32),
    ) catch return error.McpConfigInvalidOperationTimeout;
    return .{
        .startup_ms = @intCast(startup_ms),
        .operation_ms = @intCast(operation_ms),
        .startup_configured = object.get("startupTimeoutMs") != null,
        .operation_configured = object.get(operation_key) != null,
    };
}

fn parseRemoteHeaders(
    alloc: Allocator,
    object: std.json.ObjectMap,
    allow_authorization: bool,
) ![]McpHttpHeader {
    const value = object.get("headers") orelse return @constCast(&.{});
    if (value != .object) return error.McpConfigInvalidHeaders;
    var headers: std.ArrayList(McpHttpHeader) = .empty;
    errdefer freeHttpHeaderList(alloc, &headers);
    try headers.ensureTotalCapacity(alloc, value.object.count());
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.McpConfigInvalidHeaders;
        if (!allow_authorization and std.ascii.eqlIgnoreCase(entry.key_ptr.*, "authorization")) return error.McpConfigAuthorizationHeader;
        const owned_name = try alloc.dupe(u8, entry.key_ptr.*);
        errdefer mem_utils.free(alloc, owned_name);
        const owned_value = try alloc.dupe(u8, entry.value_ptr.*.string);
        headers.appendAssumeCapacity(.{ .name = owned_name, .value = owned_value });
    }
    http_config.validateStaticHeaders(headers.items) catch return error.McpConfigInvalidHeaders;
    return headers.toOwnedSlice(alloc);
}

fn parseRemoteHeaderEnv(alloc: Allocator, object: std.json.ObjectMap) ![]McpHttpHeaderEnv {
    const value = object.get("header_env") orelse return @constCast(&.{});
    if (value != .object) return error.McpConfigInvalidHeaders;
    var refs: std.ArrayList(McpHttpHeaderEnv) = .empty;
    errdefer freeHttpHeaderEnvList(alloc, &refs);
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "authorization")) return error.McpConfigAuthorizationHeader;
        if (entry.value_ptr.* != .string or
            !isValidEnvName(entry.value_ptr.*.string)) return error.McpConfigInvalidHeaders;
        for (refs.items) |previous| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, previous.name)) return error.McpConfigInvalidHeaders;
        }
        const owned_name = try alloc.dupe(u8, entry.key_ptr.*);
        errdefer mem_utils.free(alloc, owned_name);
        const owned_env = try alloc.dupe(u8, entry.value_ptr.*.string);
        errdefer mem_utils.free(alloc, owned_env);
        try refs.append(alloc, .{
            .name = owned_name,
            .env = owned_env,
        });
    }
    const validation = try alloc.alloc(McpHttpHeader, refs.items.len);
    defer alloc.free(validation);
    for (refs.items, 0..) |ref, index| validation[index] = .{ .name = ref.name, .value = @constCast("value") };
    http_config.validateStaticHeaders(validation) catch return error.McpConfigInvalidHeaders;
    return refs.toOwnedSlice(alloc);
}

fn parseProfileAuth(alloc: Allocator, object: std.json.ObjectMap) !?McpAuthConfig {
    const value = object.get("oauth") orelse return null;
    if (value != .object) return error.McpConfigInvalidOAuth;
    const auth_object = value.object;
    var auth: McpAuthConfig = .{};
    errdefer auth.deinit(alloc);
    auth.resource = try parseOptionalOwnedString(alloc, auth_object, "resource");
    auth.issuer = try parseOptionalOwnedString(alloc, auth_object, "issuer");
    auth.client_id = try parseOptionalOwnedString(alloc, auth_object, "client_id");
    auth.client_secret_env = try parseOptionalOwnedString(alloc, auth_object, "client_secret_env");
    auth.client_metadata_url = try parseOptionalOwnedString(alloc, auth_object, "client_metadata_url");
    auth.auth_server_metadata_url = try parseOptionalOwnedString(alloc, auth_object, "authServerMetadataUrl");
    if (auth.auth_server_metadata_url == null) auth.auth_server_metadata_url = try parseOptionalOwnedString(alloc, auth_object, "auth_server_metadata_url");
    if (auth_object.get("scopes")) |field| {
        auth.scopes = try parseStringArray(alloc, field);
        auth.scopes_configured = true;
    }
    auth.callback_port = try parseOptionalPort(auth_object, "callback_port");
    if (auth.client_secret_env) |field| {
        if (!isValidEnvName(field) or auth.client_id == null) return error.McpConfigInvalidOAuth;
    }
    if (auth.resource) |field| http_config.validateOAuthResource(field) catch return error.McpConfigInvalidOAuth;
    if (auth.client_metadata_url) |field| http_config.validateClientMetadataUrl(field) catch return error.McpConfigInvalidOAuth;
    if (auth.auth_server_metadata_url) |field| http_config.validateClientMetadataUrl(field) catch return error.McpConfigInvalidOAuth;
    return auth;
}

fn parseOptionalPort(object: std.json.ObjectMap, key: []const u8) !?u16 {
    const value = object.get(key) orelse return null;
    if (value != .integer) return error.McpConfigInvalidOAuth;
    if (value.integer < 1 or value.integer > 65535) return error.McpConfigInvalidOAuth;
    return @intCast(value.integer);
}

fn parseOptionalOwnedString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string or std.mem.trim(u8, value.string, " \t\r\n").len == 0) return error.McpConfigInvalidOAuth;
    return @as(?[]u8, try alloc.dupe(u8, value.string));
}

fn isValidEnvName(value: []const u8) bool {
    if (value.len == 0 or !(std.ascii.isAlphabetic(value[0]) or value[0] == '_')) return false;
    for (value[1..]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn parseUnsignedPolicy(
    object: std.json.ObjectMap,
    key: []const u8,
    default_value: anytype,
    min_value: u64,
    max_value: u64,
) !u64 {
    const value = object.get(key) orelse return @intCast(default_value);
    if (value != .integer or value.integer < 0) return error.McpConfigInvalidPolicy;
    const parsed = std.math.cast(u64, value.integer) orelse return error.McpConfigInvalidPolicy;
    if (parsed < min_value or parsed > max_value) return error.McpConfigInvalidPolicy;
    return parsed;
}

fn parseSelectedEnvironment(alloc: Allocator, object: std.json.ObjectMap) ![]McpEnvVar {
    const value = if (object.get("environment")) |environment|
        environment
    else
        object.get("env") orelse return @constCast(&.{});
    return parseEnvironment(alloc, value);
}

const ParsedCommandSpec = struct { command: []u8, args: [][]u8 };

fn parseCommandSpec(alloc: Allocator, object: std.json.ObjectMap) !ParsedCommandSpec {
    const command_value = object.get("command") orelse return error.McpMissingCommand;
    switch (command_value) {
        .string => {
            const args: [][]u8 = if (object.get("args")) |field|
                try parseStringArray(alloc, field)
            else
                @constCast(&.{});
            errdefer freeOwnedStrings(alloc, args);
            return .{
                .command = try alloc.dupe(u8, command_value.string),
                .args = args,
            };
        },
        .array => {
            if (command_value.array.items.len == 0 or command_value.array.items[0] != .string) {
                return error.McpMissingCommand;
            }
            const command = try alloc.dupe(u8, command_value.array.items[0].string);
            errdefer mem_utils.free(alloc, command);
            const args = try alloc.alloc([]u8, command_value.array.items.len - 1);
            errdefer mem_utils.free(alloc, args);
            var initialized: usize = 0;
            errdefer for (args[0..initialized]) |arg| mem_utils.free(alloc, arg);
            for (command_value.array.items[1..], 0..) |field, index| {
                if (field != .string) return error.McpMissingCommand;
                args[index] = try alloc.dupe(u8, field.string);
                initialized += 1;
            }
            return .{ .command = command, .args = args };
        },
        else => return error.McpMissingCommand,
    }
}

fn freeParsedCommandSpec(alloc: Allocator, spec: ParsedCommandSpec) void {
    alloc.free(spec.command);
    freeOwnedStrings(alloc, spec.args);
}

fn parseEnvironment(alloc: Allocator, value: std.json.Value) ![]McpEnvVar {
    if (value != .object) return error.McpConfigInvalidEnvironment;
    var vars: std.ArrayList(McpEnvVar) = .empty;
    errdefer {
        for (vars.items) |entry| {
            alloc.free(entry.key);
            alloc.free(entry.value);
        }
        vars.deinit(alloc);
    }
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) return error.McpConfigInvalidEnvironment;
        const key = try alloc.dupe(u8, entry.key_ptr.*);
        errdefer mem_utils.free(alloc, key);
        const entry_value = try alloc.dupe(u8, entry.value_ptr.*.string);
        errdefer mem_utils.free(alloc, entry_value);
        try vars.append(alloc, .{
            .key = key,
            .value = entry_value,
        });
    }
    return vars.toOwnedSlice(alloc);
}

fn parseStringArray(alloc: Allocator, value: std.json.Value) ![][]u8 {
    if (value != .array) return error.McpConfigInvalidStringArray;
    const items = try alloc.alloc([]u8, value.array.items.len);
    errdefer mem_utils.free(alloc, items);
    var initialized: usize = 0;
    errdefer for (items[0..initialized]) |item| mem_utils.free(alloc, item);
    for (value.array.items, 0..) |field, index| {
        if (field != .string) return error.McpConfigInvalidStringArray;
        items[index] = try alloc.dupe(u8, field.string);
        initialized += 1;
    }
    return items;
}

fn parseIgnoreLines(alloc: Allocator, object: std.json.ObjectMap) ![]const []const u8 {
    const value = object.get("ignore") orelse return &.{};
    const lines = try parseStringArray(alloc, value);
    errdefer freeOwnedStrings(alloc, lines);
    if (lines.len > ignore_lines.max_lines or ignore_lines.firstProblem(lines) != null) return error.McpConfigInvalidIgnore;
    return lines;
}

fn parseToolNameFilter(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) !?[][]u8 {
    const value = object.get(key) orelse return null;
    return try parseStringArray(alloc, value);
}

fn parseUniqueStringArray(alloc: Allocator, value: std.json.Value) ![][]u8 {
    const parsed = try parseStringArray(alloc, value);
    var parsed_owned = true;
    errdefer if (parsed_owned) freeOwnedStrings(alloc, parsed);
    var unique: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedList(alloc, &unique);
    for (parsed) |name| {
        if (name.len == 0) return error.InvalidProjectMcpChoices;
        if (!containsName(unique.items, name)) try appendOwnedName(alloc, &unique, name);
    }
    freeOwnedStrings(alloc, parsed);
    parsed_owned = false;
    return unique.toOwnedSlice(alloc);
}

fn appendNamesExcept(
    alloc: Allocator,
    output: *std.ArrayList([]u8),
    input: []const []const u8,
    excluded: ?[]const u8,
) !void {
    for (input) |name| {
        if (excluded) |value| if (std.mem.eql(u8, name, value)) continue;
        if (!containsName(output.items, name)) try appendOwnedName(alloc, output, name);
    }
}

fn appendOwnedName(
    alloc: Allocator,
    output: *std.ArrayList([]u8),
    name: []const u8,
) !void {
    const owned = try alloc.dupe(u8, name);
    errdefer mem_utils.free(alloc, owned);
    try output.append(alloc, owned);
}

fn cloneStrings(alloc: Allocator, values: []const []const u8) ![][]u8 {
    const result = try alloc.alloc([]u8, values.len);
    errdefer mem_utils.free(alloc, result);
    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |value| mem_utils.free(alloc, value);
    for (values, 0..) |value, index| {
        result[index] = try alloc.dupe(u8, value);
        initialized += 1;
    }
    return result;
}

fn containsName(values: []const []const u8, name: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, name)) return true;
    return false;
}

fn configNamePresent(configs: []const McpServerConfig, name: []const u8) bool {
    for (configs) |config| if (std.mem.eql(u8, config.name, name)) return true;
    return false;
}

fn deinitConfigs(alloc: Allocator, configs: *std.ArrayList(McpServerConfig)) void {
    for (configs.items) |*config| config.deinit(alloc);
    configs.deinit(alloc);
}

fn freeOwnedStrings(alloc: Allocator, values: []const []const u8) void {
    if (values.len == 0) return;
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

fn freeOwnedList(alloc: Allocator, values: *std.ArrayList([]u8)) void {
    for (values.items) |value| alloc.free(value);
    values.deinit(alloc);
}

fn freeEnvVars(alloc: Allocator, vars: []const McpEnvVar) void {
    mcp_contract.freeEnvVars(alloc, vars);
}

fn freeHttpHeaders(alloc: Allocator, headers: []const McpHttpHeader) void {
    if (headers.len == 0) return;
    for (headers) |header| {
        alloc.free(header.name);
        alloc.free(header.value);
    }
    alloc.free(headers);
}

fn freeHttpHeaderEnv(alloc: Allocator, headers: []const McpHttpHeaderEnv) void {
    mcp_contract.freeHttpHeaderEnv(alloc, headers);
}

fn freeHttpHeaderList(alloc: Allocator, headers: *std.ArrayList(McpHttpHeader)) void {
    for (headers.items) |header| {
        alloc.free(header.name);
        alloc.free(header.value);
    }
    headers.deinit(alloc);
}

fn freeHttpHeaderEnvList(alloc: Allocator, headers: *std.ArrayList(McpHttpHeaderEnv)) void {
    for (headers.items) |header| {
        alloc.free(header.name);
        alloc.free(header.env);
    }
    headers.deinit(alloc);
}

test "a server that sets required or a non-default restart_limit gets a note naming the key" {
    const alloc = std.testing.allocator;
    var notes: std.ArrayList(WorkspaceDiagnostic) = .empty;
    defer {
        for (notes.items) |*note| note.deinit(alloc);
        notes.deinit(alloc);
    }
    const configs = [_]McpServerConfig{
        .{ .name = "plain", .command = "x" },
        .{ .name = "gated", .transport = .http, .url = "https://g.example/mcp", .required = true },
        .{ .name = "retry", .command = "x", .restart_limit = 3, .source = .workspace },
    };
    try noteIgnoredKeys(alloc, &notes, &configs);
    try std.testing.expectEqual(@as(usize, 2), notes.items.len);
    const first = try renderWorkspaceDiagnostic(alloc, notes.items[0]);
    defer alloc.free(first);
    try std.testing.expectEqualStrings("~/.fx/mcp.json server 'gated' sets \"required\", which fx ignores; remove it.", first);
    const second = try renderWorkspaceDiagnostic(alloc, notes.items[1]);
    defer alloc.free(second);
    try std.testing.expectEqualStrings(".mcp.json server 'retry' sets \"restart_limit\", which fx ignores; remove it.", second);
}

test "profile document reads mcpServers as the canonical key" {
    const alloc = std.testing.allocator;
    var result = try parseProfileDocument(
        alloc,
        "{\"mcpServers\":{\"local\":{\"command\":\"node\",\"args\":[\"server.js\"]}}}",
    );
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), result.configs.items.len);
    try std.testing.expectEqualStrings("local", result.configs.items[0].name);
    try std.testing.expectEqualStrings("node", result.configs.items[0].command.?);
    try std.testing.expect(result.diagnostic == null);
    try std.testing.expect(result.mutation_allowed);
}

test "profile document reads the legacy mcp key only when mcpServers is absent" {
    const alloc = std.testing.allocator;
    var result = try parseProfileDocument(alloc, "{\"mcp\":{\"legacy\":{\"command\":\"x\"}}}");
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), result.configs.items.len);
    try std.testing.expectEqualStrings("legacy", result.configs.items[0].name);
    try std.testing.expect(result.diagnostic == null);
}

test "profile document keeps canonical mcpServers and reports ignored nonempty mcp" {
    const alloc = std.testing.allocator;
    var result = try parseProfileDocument(
        alloc,
        "{\"mcpServers\":{\"canonical\":{\"command\":\"one\"}},\"mcp\":{\"ignored\":{\"command\":\"two\"}}}",
    );
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), result.configs.items.len);
    try std.testing.expectEqualStrings("canonical", result.configs.items[0].name);
    try std.testing.expectEqual(ProfileDiagnosticCause.ignored_mcp_alias, result.diagnostic.?.cause);
    try std.testing.expect(result.mutation_allowed);
}

test "profile servers note each one ignored under mcp beside mcpServers" {
    const alloc = std.testing.allocator;
    var notes: std.ArrayList(WorkspaceDiagnostic) = .empty;
    defer {
        for (notes.items) |*note| note.deinit(alloc);
        notes.deinit(alloc);
    }
    var configs = try parseProfileServers(
        alloc,
        "{\"mcpServers\":{\"alpha\":{\"command\":\"one\"},\"shared\":{\"command\":\"two\"}},\"mcp\":{\"beta\":{\"command\":\"three\"},\"shared\":{\"command\":\"four\"}}}",
        &notes,
    );
    defer deinitConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 2), configs.items.len);
    try std.testing.expectEqualStrings("alpha", configs.items[0].name);
    try std.testing.expectEqualStrings("two", configs.items[1].command.?);

    try std.testing.expectEqual(@as(usize, 1), notes.items.len);
    const text = try renderWorkspaceDiagnostic(alloc, notes.items[0]);
    defer alloc.free(text);
    try std.testing.expectEqualStrings(
        "~/.fx/mcp.json server 'beta' was skipped: the file has both \"mcpServers\" and \"mcp\", and fx reads only \"mcpServers\"; merge them into one.",
        text,
    );
}

test "profile document blocks suspicious sibling keys beside canonical mcp" {
    const alloc = std.testing.allocator;
    var result = try parseProfileDocument(
        alloc,
        "{\"mcp\":{\"canonical\":{\"command\":\"one\"}},\"MCP-Servers\":{\"shadow\":{\"command\":\"two\"}},\"metadata\":{\"owner\":\"team\"}}",
    );
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), result.configs.items.len);
    try std.testing.expectEqualStrings("canonical", result.configs.items[0].name);
    try std.testing.expect(result.diagnostic != null);
    try std.testing.expectEqual(ProfileDiagnosticCause.suspicious_server_key, result.diagnostic.?.cause);
    try std.testing.expectEqualStrings("MCP-Servers", result.diagnostic.?.key().?);
    try std.testing.expect(!result.mutation_allowed);
}

test "profile document reports the first exact server-like unsupported key" {
    const alloc = std.testing.allocator;
    var result = try parseProfileDocument(
        alloc,
        "{\"metadata\":{\"entry\":{\"command\":\"ignored\"}},\"MCP-Servers\":{\"one\":{\"command\":\"node\"}},\"servers\":{\"two\":{\"url\":\"https://example.test/mcp\"}}}",
    );
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), result.configs.items.len);
    try std.testing.expectEqual(ProfileDiagnosticCause.suspicious_server_key, result.diagnostic.?.cause);
    try std.testing.expectEqualStrings("MCP-Servers", result.diagnostic.?.key().?);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostic.?.additional_matches);
    try std.testing.expect(!result.mutation_allowed);
}

test "profile document bounds suspicious-key scans" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('{');
    for (0..65) |index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.print("\"metadata{d}\":{{}}", .{index});
    }
    try out.writer.writeByte('}');
    const json = try out.toOwnedSlice();
    defer alloc.free(json);

    var result = try parseProfileDocument(alloc, json);
    defer result.deinit(alloc);
    try std.testing.expectEqual(ProfileDiagnosticCause.suspicious_key_scan_indeterminate, result.diagnostic.?.cause);
    try std.testing.expect(!result.mutation_allowed);
}

test "profile parser preserves validation precedence for multiply invalid entries" {
    const cases = .{
        .{
            .json = "{\"mcp\":{\"bad\":{\"type\":\"http\",\"startupTimeoutMs\":0,\"env\":3}}}",
            .expected = error.McpConfigMissingUrl,
        },
        .{
            .json = "{\"mcp\":{\"bad\":{\"type\":\"http\",\"url\":\"https://example.test/mcp\",\"startupTimeoutMs\":0,\"env\":3}}}",
            .expected = error.McpConfigInvalidStartupTimeout,
        },
        .{
            .json = "{\"mcp\":{\"bad\":{\"startupTimeoutMs\":0,\"restart_limit\":999,\"command\":3,\"env\":3}}}",
            .expected = error.McpConfigInvalidStartupTimeout,
        },
        .{
            .json = "{\"mcp\":{\"bad\":{\"restart_limit\":999,\"command\":3,\"env\":3}}}",
            .expected = error.McpConfigInvalidRestartLimit,
        },
        .{
            .json = "{\"mcp\":{\"bad\":{\"command\":3,\"env\":3}}}",
            .expected = error.McpConfigInvalidCommand,
        },
    };
    inline for (cases) |case| {
        try std.testing.expectError(
            case.expected,
            parseProfileJson(std.testing.allocator, case.json),
        );
    }
}

test "workspace parsing stamps optional credential-isolated configs" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcpServers":{"local":{"command":"node","args":["server.js"],"required":true},"remote":{"type":"http","url":"https://example.test/mcp"}}}
    ;
    var result = try parseWorkspaceJson(alloc, json, .workspace, .{});
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), result.configs.items.len);
    for (result.configs.items) |config| {
        try std.testing.expectEqual(mcp_contract.ConfigSource.workspace, config.source);
        try std.testing.expectEqual(mcp_contract.ConfigScope.workspace, config.scope);
        try std.testing.expect(!config.required);
        try std.testing.expect(!config.allow_stored_credentials);
        try std.testing.expectEqual(mcp_contract.WorkspaceAdmission.pending, config.workspace_admission.?);
    }
}

test "workspace template expansion is explicit bounded and deterministic" {
    const alloc = std.testing.allocator;
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    try environment.put("SET", "value");
    try environment.put("EMPTY", "");

    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "plain", .expected = "plain" },
        .{ .input = "before-${SET}-after", .expected = "before-value-after" },
        .{ .input = "${MISSING:-fallback}", .expected = "fallback" },
        .{ .input = "${EMPTY:-fallback}", .expected = "" },
        .{ .input = "${SET}/${SET}", .expected = "value/value" },
    };
    for (cases) |case| {
        var budget = WorkspaceExpansionBudget.init();
        var expansion = try expandWorkspaceTemplate(alloc, case.input, &environment, &budget);
        defer expansion.deinit(alloc);
        switch (expansion) {
            .expanded => |value| try std.testing.expectEqualStrings(case.expected, value),
            .missing, .invalid, .limit_exceeded => return error.TestUnexpectedResult,
        }
    }

    var missing_budget = WorkspaceExpansionBudget.init();
    var missing = try expandWorkspaceTemplate(alloc, "Bearer ${REQUIRED}", &environment, &missing_budget);
    defer missing.deinit(alloc);
    switch (missing) {
        .missing => |name| try std.testing.expectEqualStrings("REQUIRED", name),
        .expanded, .invalid, .limit_exceeded => return error.TestUnexpectedResult,
    }

    var malformed_budget = WorkspaceExpansionBudget.init();
    var malformed = try expandWorkspaceTemplate(alloc, "${NOT-CLOSED", &environment, &malformed_budget);
    defer malformed.deinit(alloc);
    try std.testing.expect(malformed == .invalid);

    var long_name: [129]u8 = undefined;
    long_name[0] = 'A';
    @memset(long_name[1..], 'B');
    try environment.put(&long_name, "long-name-value");
    const long_template = try alloc.print("${{{s}}}", .{long_name});
    defer alloc.free(long_template);
    var long_budget = WorkspaceExpansionBudget.init();
    var long_expansion = try expandWorkspaceTemplate(
        alloc,
        long_template,
        &environment,
        &long_budget,
    );
    defer long_expansion.deinit(alloc);
    switch (long_expansion) {
        .expanded => |value| try std.testing.expectEqualStrings("long-name-value", value),
        .missing, .invalid, .limit_exceeded => return error.TestUnexpectedResult,
    }
}

test "workspace environment diagnostics isolate entries and profile values stay literal" {
    const alloc = std.testing.allocator;
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    try environment.put("COMMAND", "node");
    var approved_names = [_][]u8{ @constCast("good"), @constCast("bad") };

    var workspace = try parseWorkspaceJsonWithEnvironment(
        alloc,
        "{\"mcpServers\":{\"good\":{\"command\":\"${COMMAND}\"},\"bad\":{\"command\":\"${REQUIRED}\"}}}",
        .workspace,
        .{ .approved = &approved_names },
        &environment,
    );
    defer workspace.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), workspace.configs.items.len);
    try std.testing.expectEqualStrings("node", workspace.configs.items[0].command.?);
    try std.testing.expectEqual(@as(usize, 1), workspace.diagnostics.items.len);
    const diagnostic = workspace.diagnostics.items[0];
    try std.testing.expectEqual(WorkspaceDiagnosticCause.missing_environment_variable, diagnostic.cause);
    try std.testing.expectEqual(WorkspaceEnvironmentField.command, diagnostic.environment_field.?);
    try std.testing.expectEqualStrings("REQUIRED", diagnostic.environment_variable.?);

    var profile = try parseProfileDocument(
        alloc,
        "{\"mcp\":{\"literal\":{\"command\":\"${COMMAND}\"}}}",
    );
    defer profile.deinit(alloc);
    try std.testing.expectEqualStrings("${COMMAND}", profile.configs.items[0].command.?);
}

test "workspace environment expansion requires approved admission" {
    const alloc = std.testing.allocator;
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    try environment.put("COMMAND", "node");
    try environment.put("VALUE", "expanded");

    var workspace = try parseWorkspaceJsonWithEnvironment(
        alloc,
        "{\"mcpServers\":{\"local\":{\"command\":\"${COMMAND}\",\"args\":[\"${VALUE}\"],\"env\":{\"TOKEN\":\"${VALUE}\"}},\"remote\":{\"type\":\"http\",\"url\":\"https://example.test/mcp\",\"headers\":{\"Authorization\":\"Bearer ${VALUE}\"}}}}",
        .workspace,
        .{},
        &environment,
    );
    defer workspace.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), workspace.configs.items.len);
    try std.testing.expectEqualStrings("${COMMAND}", workspace.configs.items[0].command.?);
    try std.testing.expectEqualStrings("${VALUE}", workspace.configs.items[0].args[0]);
    try std.testing.expectEqualStrings("${VALUE}", workspace.configs.items[0].env[0].value);
    try std.testing.expectEqualStrings("Bearer ${VALUE}", workspace.configs.items[1].headers[0].value);
    try std.testing.expectEqual(@as(usize, 0), workspace.diagnostics.items.len);
}

test "workspace environment expansion enforces one aggregate file budget" {
    const alloc = std.testing.allocator;
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    const large = try alloc.alloc(u8, 600 * 1024);
    defer alloc.free(large);
    @memset(large, 'x');
    try environment.put("LARGE", large);
    var approved_names = [_][]u8{ @constCast("first"), @constCast("second") };

    var workspace = try parseWorkspaceJsonWithEnvironment(
        alloc,
        "{\"mcpServers\":{\"first\":{\"command\":\"${LARGE}\"},\"second\":{\"command\":\"${LARGE}\"}}}",
        .workspace,
        .{ .approved = &approved_names },
        &environment,
    );
    defer workspace.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), workspace.configs.items.len);
    try std.testing.expectEqualStrings("first", workspace.configs.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), workspace.diagnostics.items.len);
    try std.testing.expectEqual(
        WorkspaceDiagnosticCause.environment_expansion_limit_exceeded,
        workspace.diagnostics.items[0].cause,
    );
    try std.testing.expectEqualStrings("second", workspace.diagnostics.items[0].server_name.?);
}

test "workspace environment expansion never refunds rejected entry work" {
    const alloc = std.testing.allocator;
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    const large = try alloc.alloc(u8, 600 * 1024);
    defer alloc.free(large);
    @memset(large, 'x');
    try environment.put("LARGE", large);
    var approved_names = [_][]u8{ @constCast("rejected_late"), @constCast("later") };

    var workspace = try parseWorkspaceJsonWithEnvironment(
        alloc,
        "{\"mcpServers\":{\"rejected_late\":{\"command\":\"${LARGE}\",\"args\":[\"${MISSING}\"]},\"later\":{\"command\":\"${LARGE}\"}}}",
        .workspace,
        .{ .approved = &approved_names },
        &environment,
    );
    defer workspace.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), workspace.configs.items.len);
    try std.testing.expectEqual(@as(usize, 2), workspace.diagnostics.items.len);
    try std.testing.expectEqual(
        WorkspaceDiagnosticCause.missing_environment_variable,
        workspace.diagnostics.items[0].cause,
    );
    try std.testing.expectEqual(
        WorkspaceDiagnosticCause.environment_expansion_limit_exceeded,
        workspace.diagnostics.items[1].cause,
    );
}

test "workspace environment expansion rejects exhausted budget before allocation" {
    const alloc = testing_allocator.no_resize;
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    try environment.put("TOKEN", "secret");

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    var value: []const u8 = "${TOKEN}";
    var budget = WorkspaceExpansionBudget{ .remaining = 0 };
    const failure = expandOwnedConstWorkspaceValue(
        failing.allocator(),
        &value,
        &environment,
        .command,
        &budget,
    ) catch |err| {
        try std.testing.expect(err != error.OutOfMemory);
        return;
    };
    try std.testing.expect(failure != null);
    try std.testing.expect(failure.? == .limit_exceeded);
}

test "workspace Authorization header expansion does not broaden profile headers" {
    const alloc = std.testing.allocator;
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    try environment.put("TOKEN", "secret");
    var approved_names = [_][]u8{@constCast("remote")};

    var workspace = try parseWorkspaceJsonWithEnvironment(
        alloc,
        "{\"mcpServers\":{\"remote\":{\"type\":\"http\",\"url\":\"https://example.test/mcp\",\"headers\":{\"Authorization\":\"Bearer ${TOKEN}\"}}}}",
        .workspace,
        .{ .approved = &approved_names },
        &environment,
    );
    defer workspace.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), workspace.configs.items.len);
    try std.testing.expectEqualStrings("Bearer secret", workspace.configs.items[0].headers[0].value);

    try std.testing.expectError(
        error.McpConfigAuthorizationHeader,
        parseProfileJson(
            alloc,
            "{\"mcp\":{\"remote\":{\"type\":\"http\",\"url\":\"https://example.test/mcp\",\"headers\":{\"Authorization\":\"Bearer ${TOKEN}\"}}}}",
        ),
    );
}

test "workspace parsing isolates invalid entries" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcpServers":{"good":{"command":["node","server.js"]},"bad":{"command":3}}}
    ;
    var result = try parseWorkspaceJson(alloc, json, .workspace, .{});
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), result.configs.items.len);
    try std.testing.expectEqualStrings("good", result.configs.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.items.len);
    try std.testing.expectEqualStrings("bad", result.diagnostics.items[0].server_name.?);
}

test "enabledTools and disabledTools are read per server" {
    const alloc = std.testing.allocator;
    var remote = try parseProfileJson(alloc, "{\"mcpServers\":{\"web\":{\"type\":\"http\",\"url\":\"https://w.example/mcp\",\"enabledTools\":[\"read\"],\"disabledTools\":[\"write\"]}}}");
    defer deinitConfigs(alloc, &remote);
    try std.testing.expectEqualStrings("read", remote.items[0].enabled_tools.?[0]);
    try std.testing.expectEqualStrings("write", remote.items[0].disabled_tools.?[0]);
    var local = try parseProfileJson(alloc, "{\"mcpServers\":{\"local\":{\"type\":\"local\",\"command\":[\"node\"],\"enabledTools\":[\"a\",\"b\"]}}}");
    defer deinitConfigs(alloc, &local);
    try std.testing.expectEqual(@as(usize, 2), local.items[0].enabled_tools.?.len);
    try std.testing.expect(local.items[0].disabled_tools == null);
}

test "cwd and deferred are read per server, and an absent deferred stays unset" {
    const alloc = std.testing.allocator;
    var local = try parseProfileJson(alloc, "{\"mcpServers\":{\"local\":{\"command\":\"node\",\"cwd\":\"/work/app\",\"deferred\":true}}}");
    defer deinitConfigs(alloc, &local);
    try std.testing.expectEqualStrings("/work/app", local.items[0].cwd.?);
    try std.testing.expectEqual(@as(?bool, true), local.items[0].deferred);
    var remote = try parseProfileJson(alloc, "{\"mcpServers\":{\"web\":{\"url\":\"https://w.example/mcp\",\"deferred\":false}}}");
    defer deinitConfigs(alloc, &remote);
    try std.testing.expectEqual(@as(?bool, false), remote.items[0].deferred);
    var plain = try parseProfileJson(alloc, "{\"mcpServers\":{\"plain\":{\"command\":\"node\"}}}");
    defer deinitConfigs(alloc, &plain);
    try std.testing.expect(plain.items[0].cwd == null);
    try std.testing.expect(plain.items[0].deferred == null);
}

test "a server's timeout in milliseconds limits its tool calls, and toolTimeoutMs wins when both are set" {
    const alloc = std.testing.allocator;
    var configs = try parseProfileJson(alloc, "{\"mcpServers\":{\"slow\":{\"command\":\"node\",\"timeout\":120000},\"both\":{\"command\":\"node\",\"timeout\":120000,\"toolTimeoutMs\":90000},\"plain\":{\"command\":\"node\"}}}");
    defer deinitConfigs(alloc, &configs);
    for (configs.items) |config| {
        if (std.mem.eql(u8, config.name, "slow")) {
            try std.testing.expectEqual(@as(u32, 120_000), config.operation_timeout_ms);
            try std.testing.expect(config.operation_timeout_configured);
        } else if (std.mem.eql(u8, config.name, "both")) {
            try std.testing.expectEqual(@as(u32, 90_000), config.operation_timeout_ms);
        } else {
            try std.testing.expectEqual(mcp_contract.default_operation_timeout_ms, config.operation_timeout_ms);
            try std.testing.expect(!config.operation_timeout_configured);
        }
    }
}

test "oauth.authServerMetadataUrl is kept when it is an https URL with a path and refused otherwise" {
    const alloc = std.testing.allocator;
    var pinned = try parseProfileJson(alloc, "{\"mcpServers\":{\"web\":{\"url\":\"https://w.example/mcp\",\"oauth\":{\"authServerMetadataUrl\":\"https://auth.example/custom/metadata.json\"}}}}");
    defer deinitConfigs(alloc, &pinned);
    try std.testing.expectEqualStrings("https://auth.example/custom/metadata.json", pinned.items[0].auth.?.auth_server_metadata_url.?);
    try std.testing.expectError(
        error.McpConfigInvalidOAuth,
        parseProfileJson(alloc, "{\"mcpServers\":{\"web\":{\"url\":\"https://w.example/mcp\",\"oauth\":{\"authServerMetadataUrl\":\"http://auth.example/custom/metadata.json\"}}}}"),
    );
}

test "auth oauth, or an oauth object, asks for OAuth beside static headers, and any other auth value is refused" {
    const alloc = std.testing.allocator;
    var asked = try parseProfileJson(alloc, "{\"mcpServers\":{\"web\":{\"url\":\"https://w.example/mcp\",\"headers\":{\"X-Key\":\"k\"},\"auth\":\"oauth\"}}}");
    defer deinitConfigs(alloc, &asked);
    try std.testing.expect(asked.items[0].oauth_requested);
    try std.testing.expect(!asked.items[0].usesStaticCredentials());
    var object = try parseProfileJson(alloc, "{\"mcpServers\":{\"web\":{\"url\":\"https://w.example/mcp\",\"oauth\":{\"client_id\":\"fx\"}}}}");
    defer deinitConfigs(alloc, &object);
    try std.testing.expect(object.items[0].oauth_requested);
    var static = try parseProfileJson(alloc, "{\"mcpServers\":{\"web\":{\"url\":\"https://w.example/mcp\",\"headers\":{\"X-Key\":\"k\"}}}}");
    defer deinitConfigs(alloc, &static);
    try std.testing.expect(!static.items[0].oauth_requested);
    try std.testing.expect(static.items[0].usesStaticCredentials());
    try std.testing.expectError(
        error.McpConfigInvalidOAuth,
        parseProfileJson(alloc, "{\"mcp\":{\"bad\":{\"url\":\"https://w.example/mcp\",\"auth\":\"basic\"}}}"),
    );
}

test "environment_id local starts the server on this machine, and a remote environment is refused by name" {
    const alloc = std.testing.allocator;
    var local = try parseProfileJson(alloc, "{\"mcpServers\":{\"local\":{\"command\":\"node\",\"environment_id\":\"local\"}}}");
    defer deinitConfigs(alloc, &local);
    try std.testing.expectEqual(McpTransport.stdio, local.items[0].transport);

    const cases = .{
        .{ .json = "{\"mcp\":{\"bad\":{\"command\":\"node\",\"environment_id\":\"dev-box\"}}}", .expected = error.McpConfigRemoteEnvironment },
        .{ .json = "{\"mcp\":{\"bad\":{\"command\":\"node\",\"environment_id\":\"\"}}}", .expected = error.McpConfigInvalidEnvironmentId },
        .{ .json = "{\"mcp\":{\"bad\":{\"command\":\"node\",\"environment_id\":3}}}", .expected = error.McpConfigInvalidEnvironmentId },
        .{ .json = "{\"mcp\":{\"bad\":{\"command\":\"node\",\"cwd\":3}}}", .expected = error.McpConfigInvalidCwd },
        .{ .json = "{\"mcp\":{\"bad\":{\"command\":\"node\",\"deferred\":\"yes\"}}}", .expected = error.McpConfigInvalidDeferred },
    };
    inline for (cases) |case| {
        try std.testing.expectError(case.expected, parseProfileJson(alloc, case.json));
    }

    const note = try renderWorkspaceDiagnostic(alloc, .{ .profile = false, .server_name = null, .cause = .invalid_entry, .problem = .remote_environment });
    defer alloc.free(note);
    try std.testing.expectEqualStrings(
        ".mcp.json server 'unknown' was skipped: its \"environment_id\" names a remote environment, and fx starts MCP servers only on this machine; remove it or set it to \"local\".",
        note,
    );
}

test "transport key selects the server transport like type does" {
    const alloc = std.testing.allocator;
    var profile = try parseProfileJson(alloc, "{\"mcpServers\":{\"web\":{\"transport\":\"http\",\"url\":\"https://w.example/mcp\"}}}");
    defer deinitConfigs(alloc, &profile);
    try std.testing.expectEqual(McpTransport.http, profile.items[0].transport);
    var stdio = try parseProfileJson(alloc, "{\"mcpServers\":{\"local\":{\"transport\":\"stdio\",\"command\":[\"node\"]}}}");
    defer deinitConfigs(alloc, &stdio);
    try std.testing.expectEqual(McpTransport.stdio, stdio.items[0].transport);
}

test "a url without a transport or type key selects http, and a command selects stdio" {
    const alloc = std.testing.allocator;
    var remote = try parseProfileJson(alloc, "{\"mcpServers\":{\"web\":{\"url\":\"https://w.example/mcp\"}}}");
    defer deinitConfigs(alloc, &remote);
    try std.testing.expectEqual(McpTransport.http, remote.items[0].transport);
    try std.testing.expectEqualStrings("https://w.example/mcp", remote.items[0].url.?);
    var both = try parseProfileJson(alloc, "{\"mcpServers\":{\"local\":{\"command\":\"node\",\"url\":\"https://w.example/mcp\"}}}");
    defer deinitConfigs(alloc, &both);
    try std.testing.expectEqual(McpTransport.stdio, both.items[0].transport);
    try std.testing.expectEqualStrings("node", both.items[0].command.?);
}

test "streamable-http reads as http in both files" {
    const alloc = std.testing.allocator;
    var profile = try parseProfileJson(alloc, "{\"mcpServers\":{\"web\":{\"type\":\"streamable-http\",\"url\":\"https://w.example/mcp\"}}}");
    defer deinitConfigs(alloc, &profile);
    try std.testing.expectEqual(McpTransport.http, profile.items[0].transport);
    var project = try parseWorkspaceJson(alloc, "{\"mcpServers\":{\"web\":{\"type\":\"streamable-http\",\"url\":\"https://w.example/mcp\"}}}", .workspace, .{});
    defer project.deinit(alloc);
    try std.testing.expectEqual(McpTransport.http, project.configs.items[0].transport);
    try std.testing.expectEqual(@as(usize, 0), project.diagnostics.items.len);
}

test "choice transitions are normalized and reject precedence is stable" {
    const alloc = std.testing.allocator;
    var current = ProjectMcpChoices{
        .enable_all = true,
        .approved = try cloneStrings(alloc, &.{ "alpha", "beta" }),
        .rejected = try cloneStrings(alloc, &.{"gamma"}),
    };
    defer current.deinit(alloc);
    var rejected = try applyAction(alloc, current, .{ .reject = "alpha" });
    defer rejected.choices.deinit(alloc);
    try std.testing.expect(rejected.authority_reduced);
    try std.testing.expectEqual(mcp_contract.WorkspaceAdmission.rejected, resolveAdmission("alpha", rejected.choices));
    try std.testing.expectEqual(mcp_contract.WorkspaceAdmission.approved, resolveAdmission("beta", rejected.choices));

    var approved = try applyAction(alloc, rejected.choices, .{ .approve = "alpha" });
    defer approved.choices.deinit(alloc);
    try std.testing.expect(!approved.authority_reduced);
    try std.testing.expectEqual(mcp_contract.WorkspaceAdmission.approved, resolveAdmission("alpha", approved.choices));
}

test "native merge keeps the profile entry when the project entry is not approved" {
    const alloc = std.testing.allocator;
    var primary: std.ArrayList(McpServerConfig) = .empty;
    defer deinitConfigs(alloc, &primary);
    try primary.append(alloc, .{ .name = try alloc.dupe(u8, "same"), .command = try alloc.dupe(u8, "profile") });
    var workspace: std.ArrayList(McpServerConfig) = .empty;
    defer deinitConfigs(alloc, &workspace);
    try workspace.append(alloc, .{
        .name = try alloc.dupe(u8, "same"),
        .source = .workspace,
        .scope = .workspace,
        .command = try alloc.dupe(u8, "workspace"),
        .workspace_admission = .pending,
    });
    try workspace.append(alloc, .{
        .name = try alloc.dupe(u8, "only"),
        .source = .workspace,
        .scope = .workspace,
        .command = try alloc.dupe(u8, "workspace"),
        .workspace_admission = .approved,
    });
    var merged = try mergeNative(alloc, &primary, &workspace);
    defer deinitConfigs(alloc, &merged);
    try std.testing.expectEqual(@as(usize, 2), merged.items.len);
    try std.testing.expectEqualStrings("profile", merged.items[0].command.?);
    try std.testing.expectEqualStrings("only", merged.items[1].name);
}

test "native merge lets an approved project entry replace the profile entry of the same name" {
    const alloc = std.testing.allocator;
    var primary: std.ArrayList(McpServerConfig) = .empty;
    defer deinitConfigs(alloc, &primary);
    try primary.append(alloc, .{ .name = try alloc.dupe(u8, "same"), .command = try alloc.dupe(u8, "profile") });
    try primary.append(alloc, .{ .name = try alloc.dupe(u8, "other"), .command = try alloc.dupe(u8, "profile") });
    var workspace: std.ArrayList(McpServerConfig) = .empty;
    defer deinitConfigs(alloc, &workspace);
    try workspace.append(alloc, .{
        .name = try alloc.dupe(u8, "same"),
        .source = .workspace,
        .scope = .workspace,
        .command = try alloc.dupe(u8, "workspace"),
        .workspace_admission = .approved,
    });
    var merged = try mergeNative(alloc, &primary, &workspace);
    defer deinitConfigs(alloc, &merged);
    try std.testing.expectEqual(@as(usize, 2), merged.items.len);
    try std.testing.expectEqualStrings("same", merged.items[0].name);
    try std.testing.expectEqualStrings("workspace", merged.items[0].command.?);
    try std.testing.expectEqualStrings("other", merged.items[1].name);
}

test "ACP primary duplicates remain ordered while workspace collisions are excluded" {
    const alloc = std.testing.allocator;
    var output: std.ArrayList(McpServerConfig) = .empty;
    defer deinitConfigs(alloc, &output);
    try output.append(alloc, .{
        .name = try alloc.dupe(u8, "same"),
        .source = .acp,
        .scope = .acp_session,
        .command = try alloc.dupe(u8, "one"),
    });
    try output.append(alloc, .{
        .name = try alloc.dupe(u8, "same"),
        .source = .acp,
        .scope = .acp_session,
        .command = try alloc.dupe(u8, "two"),
    });
    var workspace: std.ArrayList(McpServerConfig) = .empty;
    defer deinitConfigs(alloc, &workspace);
    try workspace.append(alloc, .{
        .name = try alloc.dupe(u8, "same"),
        .source = .workspace,
        .scope = .workspace,
        .command = try alloc.dupe(u8, "workspace"),
        .workspace_admission = .pending,
    });
    try workspace.append(alloc, .{
        .name = try alloc.dupe(u8, "only"),
        .source = .workspace,
        .scope = .workspace,
        .command = try alloc.dupe(u8, "workspace"),
        .workspace_admission = .pending,
    });
    try appendWorkspaceAfterAcpPrimary(alloc, &output, &workspace);
    try std.testing.expectEqual(@as(usize, 3), output.items.len);
    try std.testing.expectEqualStrings("one", output.items[0].command.?);
    try std.testing.expectEqualStrings("two", output.items[1].command.?);
    try std.testing.expectEqualStrings("only", output.items[2].name);
}

test "workspace parsing releases every partial allocation failure" {
    const json =
        \\{"mcpServers":{"bad":{"command":3},"remote":{"type":"http","url":"https://example.test/mcp","env":{"TOKEN":"value"},"header_env":{"X-Test":"TEST_ENV"}},"local":{"command":"node","args":["server.js"],"env":{"A":"B"}}}}
    ;
    var fail_index: usize = 0;
    while (fail_index < 256) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            testing_allocator.no_resize,
            .{ .fail_index = fail_index },
        );
        var result = parseWorkspaceJson(failing.allocator(), json, .workspace, .{}) catch |err| switch (err) {
            error.OutOfMemory => continue,
        };
        result.deinit(failing.allocator());
        break;
    }
    try std.testing.expect(fail_index < 256);
}

test "choice parsing and mutation release every partial allocation failure" {
    const alloc = testing_allocator.no_resize;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"enabledMcpjsonServers\":[\"alpha\",\"overlap\"],\"disabledMcpjsonServers\":[\"overlap\",\"beta\"],\"enableAllProjectMcpServers\":true}",
        .{},
    );
    defer parsed.deinit();
    var fail_index: usize = 0;
    while (fail_index < 128) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            alloc,
            .{ .fail_index = fail_index },
        );
        var diagnostics: std.ArrayList(WorkspaceDiagnostic) = .empty;
        defer {
            for (diagnostics.items) |*diagnostic| diagnostic.deinit(failing.allocator());
            diagnostics.deinit(failing.allocator());
        }
        var choices = parseChoices(
            failing.allocator(),
            parsed.value,
            &diagnostics,
        ) catch |err| switch (err) {
            error.OutOfMemory => continue,
            else => return err,
        };
        choices.deinit(failing.allocator());
        break;
    }
    try std.testing.expect(fail_index < 128);

    var current = ProjectMcpChoices{
        .enable_all = true,
        .approved = try cloneStrings(alloc, &.{ "alpha", "beta" }),
        .rejected = try cloneStrings(alloc, &.{ "gamma", "delta" }),
    };
    defer current.deinit(alloc);
    fail_index = 0;
    while (fail_index < 128) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            alloc,
            .{ .fail_index = fail_index },
        );
        var transition = applyAction(
            failing.allocator(),
            current,
            .{ .reject = "alpha" },
        ) catch |err| switch (err) {
            error.OutOfMemory => continue,
        };
        transition.choices.deinit(failing.allocator());
        break;
    }
    try std.testing.expect(fail_index < 128);
}

test "a profile entry fx can't read is skipped with a note naming it, and the rest load" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcpServers":{"webonly":{"url":"http://127.0.0.1:9/mcp"},"ok":{"command":"true"},"bad":{"type":"http","url":"https://x.example/mcp","enabled":"yes"}}}
    ;
    var skipped: std.ArrayList(WorkspaceDiagnostic) = .empty;
    defer {
        for (skipped.items) |*note| note.deinit(alloc);
        skipped.deinit(alloc);
    }
    var configs = try parseProfileServers(alloc, json, &skipped);
    defer deinitConfigs(alloc, &configs);
    try std.testing.expectEqual(@as(usize, 2), configs.items.len);
    try std.testing.expectEqualStrings("webonly", configs.items[0].name);
    try std.testing.expectEqualStrings("ok", configs.items[1].name);
    try std.testing.expectEqual(@as(usize, 1), skipped.items.len);
    const expected = [_][]const u8{
        "~/.fx/mcp.json server 'bad' was skipped: its \"enabled\" isn't valid.",
    };
    for (skipped.items, expected) |note, words| {
        const said = try renderWorkspaceDiagnostic(alloc, note);
        defer alloc.free(said);
        try std.testing.expectEqualStrings(words, said);
    }

    try std.testing.expectError(error.McpConfigInvalidEnabled, parseProfileJson(alloc, json));
}

test "a project entry fx can't read says why in words" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcpServers":{"odd":{"type":"pigeon","url":"https://x.example/mcp"},"plain":7}}
    ;
    var result = try parseWorkspaceJson(alloc, json, .workspace, .{});
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), result.configs.items.len);
    const expected = [_][]const u8{
        ".mcp.json server 'odd' was skipped: its \"type\" isn't valid.",
        ".mcp.json server 'plain' was skipped: it isn't a JSON object.",
    };
    try std.testing.expectEqual(expected.len, result.diagnostics.items.len);
    for (result.diagnostics.items, expected) |note, words| {
        const said = try renderWorkspaceDiagnostic(alloc, note);
        defer alloc.free(said);
        try std.testing.expectEqualStrings(words, said);
    }
}

test "a server's ignore list is kept when every line is relative and a bad line skips only that server with the reason" {
    const alloc = std.testing.allocator;
    var good = try parseProfileJson(alloc, "{\"mcpServers\":{\"notes\":{\"command\":\"node\",\"ignore\":[\".notes-state/\",\"cache/*.log\"]},\"remote\":{\"url\":\"https://example.test/mcp\",\"ignore\":[\".remote/\"]},\"plain\":{\"command\":\"node\"}}}");
    defer deinitConfigs(alloc, &good);
    try std.testing.expectEqual(@as(usize, 3), good.items.len);
    for (good.items) |config| {
        if (std.mem.eql(u8, config.name, "notes")) {
            try std.testing.expectEqual(@as(usize, 2), config.ignore.len);
            try std.testing.expectEqualStrings(".notes-state/", config.ignore[0]);
            try std.testing.expectEqualStrings("cache/*.log", config.ignore[1]);
        } else if (std.mem.eql(u8, config.name, "remote")) {
            try std.testing.expectEqual(@as(usize, 1), config.ignore.len);
        } else {
            try std.testing.expectEqual(@as(usize, 0), config.ignore.len);
        }
    }

    inline for (.{
        "{\"mcpServers\":{\"bad\":{\"command\":\"node\",\"ignore\":[\"../outside\"]}}}",
        "{\"mcpServers\":{\"bad\":{\"command\":\"node\",\"ignore\":[\"/abs\"]}}}",
        "{\"mcpServers\":{\"bad\":{\"command\":\"node\",\"ignore\":[\"!src/\"]}}}",
        "{\"mcpServers\":{\"bad\":{\"command\":\"node\",\"ignore\":\"state/\"}}}",
        "{\"mcpServers\":{\"bad\":{\"command\":\"node\",\"ignore\":[3]}}}",
    }) |json| {
        try std.testing.expectError(error.McpConfigInvalidIgnore, parseProfileJson(alloc, json));
    }

    var skipped: std.ArrayList(WorkspaceDiagnostic) = .empty;
    defer {
        for (skipped.items) |*note| note.deinit(alloc);
        skipped.deinit(alloc);
    }
    var kept = try parseProfileServers(alloc, "{\"mcpServers\":{\"bad\":{\"command\":\"node\",\"ignore\":[\"a/../../b\"]},\"fine\":{\"command\":\"node\"}}}", &skipped);
    defer deinitConfigs(alloc, &kept);
    try std.testing.expectEqual(@as(usize, 1), kept.items.len);
    try std.testing.expectEqualStrings("fine", kept.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), skipped.items.len);
    try std.testing.expectEqual(EntryProblem.ignore, skipped.items[0].problem.?);
    const said = try renderWorkspaceDiagnostic(alloc, skipped.items[0]);
    defer alloc.free(said);
    try std.testing.expect(std.mem.find(u8, said, "server 'bad' was skipped: its \"ignore\" must be a list") != null);
}

test "a ${VAR} in a server url expands from the environment, and the expanded url must still be one fx connects to" {
    const alloc = std.testing.allocator;
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    try environment.put("API_BASE", "https://api.example.test");
    try environment.put("PLAIN_BASE", "http://example.test");
    var approved_names = [_][]u8{ @constCast("good"), @constCast("fallback"), @constCast("insecure"), @constCast("unset") };

    var workspace = try parseWorkspaceJsonWithEnvironment(
        alloc,
        "{\"mcpServers\":{\"good\":{\"type\":\"http\",\"url\":\"${API_BASE}/mcp\"},\"fallback\":{\"type\":\"http\",\"url\":\"${OTHER_BASE:-https://other.example.test}/mcp\"},\"insecure\":{\"type\":\"http\",\"url\":\"${PLAIN_BASE}/mcp\"},\"unset\":{\"type\":\"http\",\"url\":\"${NO_BASE}/mcp\"}}}",
        .workspace,
        .{ .approved = &approved_names },
        &environment,
    );
    defer workspace.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), workspace.configs.items.len);
    try std.testing.expectEqualStrings("https://api.example.test/mcp", workspace.configs.items[0].url.?);
    try std.testing.expectEqualStrings("https://other.example.test/mcp", workspace.configs.items[1].url.?);
    try std.testing.expectEqual(@as(usize, 2), workspace.diagnostics.items.len);
    try std.testing.expectEqual(EntryProblem.url, workspace.diagnostics.items[0].problem.?);
    try std.testing.expectEqual(WorkspaceEnvironmentField.url, workspace.diagnostics.items[1].environment_field.?);
    try std.testing.expectEqualStrings("NO_BASE", workspace.diagnostics.items[1].environment_variable.?);
}

test "a server of type ws or sdk is skipped with a note, and ws is named" {
    const alloc = std.testing.allocator;
    var workspace = try parseWorkspaceJson(
        alloc,
        "{\"mcpServers\":{\"sock\":{\"type\":\"ws\",\"url\":\"wss://s.example.test/mcp\"},\"inproc\":{\"type\":\"sdk\",\"name\":\"x\"},\"web\":{\"type\":\"streamable-http\",\"url\":\"https://w.example.test/mcp\"}}}",
        .workspace,
        .{},
    );
    defer workspace.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), workspace.configs.items.len);
    try std.testing.expectEqualStrings("web", workspace.configs.items[0].name);
    try std.testing.expectEqual(McpTransport.http, workspace.configs.items[0].transport);
    try std.testing.expectEqual(@as(usize, 2), workspace.diagnostics.items.len);
    try std.testing.expectEqual(EntryProblem.websocket, workspace.diagnostics.items[0].problem.?);
    try std.testing.expectEqual(EntryProblem.type, workspace.diagnostics.items[1].problem.?);
    const note = try renderWorkspaceDiagnostic(alloc, workspace.diagnostics.items[0]);
    defer alloc.free(note);
    try std.testing.expectEqualStrings(
        ".mcp.json server 'sock' was skipped: its \"type\" is \"ws\", and fx connects to MCP servers over http, sse or stdio only.",
        note,
    );
}

test "headersHelper is read as the command that prints a remote server's headers" {
    const alloc = std.testing.allocator;
    var profile = try parseProfileJson(alloc, "{\"mcpServers\":{\"web\":{\"type\":\"http\",\"url\":\"https://w.example/mcp\",\"headersHelper\":\"/opt/bin/get-headers.sh\"},\"plain\":{\"type\":\"http\",\"url\":\"https://p.example/mcp\"}}}");
    defer deinitConfigs(alloc, &profile);
    try std.testing.expectEqualStrings("/opt/bin/get-headers.sh", profile.items[0].headers_helper.?);
    try std.testing.expect(profile.items[0].usesStaticCredentials());
    try std.testing.expect(profile.items[1].headers_helper == null);
    try std.testing.expectError(error.McpConfigInvalidHeaders, parseProfileJson(alloc, "{\"mcpServers\":{\"web\":{\"type\":\"http\",\"url\":\"https://w.example/mcp\",\"headersHelper\":7}}}"));
}

test "a local server is read from projects[root].mcpServers of the profile file and wins over the same name elsewhere" {
    const alloc = std.testing.allocator;
    const text =
        \\{"mcpServers":{"web":{"type":"http","url":"https://everywhere.example/mcp"},"shared":{"command":"node"}},
        \\"projects":{"/work/app":{"mcpServers":{"web":{"type":"http","url":"https://app-only.example/mcp"},"mine":{"command":"mine"}}},
        \\"/work/other":{"mcpServers":{"theirs":{"command":"theirs"}}}}}
    ;
    var merged = try parseProfileJson(alloc, text);
    defer deinitConfigs(alloc, &merged);
    try std.testing.expectEqual(@as(usize, 2), merged.items.len);

    var local = try parseLocalServers(alloc, text, "/work/app/", null);
    defer deinitConfigs(alloc, &local);
    try std.testing.expectEqual(@as(usize, 2), local.items.len);
    try overrideWith(alloc, &merged, &local);
    try std.testing.expectEqual(@as(usize, 3), merged.items.len);
    try std.testing.expectEqualStrings("web", merged.items[0].name);
    try std.testing.expectEqualStrings("https://app-only.example/mcp", merged.items[0].url.?);
    try std.testing.expectEqualStrings("shared", merged.items[1].name);
    try std.testing.expectEqualStrings("mine", merged.items[2].name);

    var elsewhere = try parseLocalServers(alloc, text, "/work/none", null);
    defer deinitConfigs(alloc, &elsewhere);
    try std.testing.expectEqual(@as(usize, 0), elsewhere.items.len);
}
