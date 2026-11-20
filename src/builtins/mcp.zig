const std = @import("std");
const testing_allocator = @import("../core/shared/testing_allocator.zig");

const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const mcp_contract = @import("../core/mcp/mcp_contract.zig");
const mcp_health = @import("../core/mcp/health.zig");
const project_config = @import("../core/mcp/project_config.zig");
const workspace_config = @import("../core/mcp/workspace_config.zig");
const mcp_host = @import("../core/mcp_host/host.zig");
const config_file = @import("../core/mcp_host/config_file.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");
const build_options = @import("build_options");
const config_runtime = @import("../core/config/config_runtime.zig");
const elicitation = @import("../core/mcp/elicitation.zig");
const profile_paths = @import("../core/shared/profile_paths.zig");
const kimi_sections = @import("../core/config/kimi_sections.zig");
const plugin_manager = @import("../core/plugins/manager.zig");
const plugin_mcp = @import("../core/plugins/mcp_servers.zig");
const managed_policy = @import("../core/mcp/managed_policy.zig");
const text_utils = @import("../core/shared/text_utils.zig");

const Allocator = std.mem.Allocator;
const McpServerConfig = mcp_contract.McpServerConfig;
const McpTransport = mcp_contract.McpTransport;

pub fn configPathFromHome(alloc: Allocator, home: []const u8) ![]u8 {
    return profile_paths.mcpConfigPath(alloc, home);
}

pub const NativeConfigs = struct {
    configs: std.ArrayList(McpServerConfig) = .empty,
    diagnostics: std.ArrayList(project_config.WorkspaceDiagnostic) = .empty,

    pub fn deinit(self: *NativeConfigs, alloc: Allocator) void {
        freeConfigs(alloc, &self.configs);
        for (self.diagnostics.items) |*diagnostic| diagnostic.deinit(alloc);
        self.diagnostics.deinit(alloc);
        self.* = undefined;
    }
};

pub fn loadNativeConfigs(alloc: Allocator, workspace_root: []const u8) !NativeConfigs {
    var profile: std.ArrayList(McpServerConfig) = .empty;
    errdefer freeConfigs(alloc, &profile);

    var loaded: NativeConfigs = .{};
    errdefer loaded.deinit(alloc);
    var local: std.ArrayList(McpServerConfig) = .empty;
    defer freeConfigs(alloc, &local);
    if (io_mod.homeDir()) |home| {
        const config_path = try configPathFromHome(alloc, home);
        defer alloc.free(config_path);
        profile = try readProfile(alloc, config_path, &loaded.diagnostics);
        local = try readLocalServers(alloc, config_path, workspace_root, &loaded.diagnostics);
    }

    var choice_load = config_runtime.loadProjectMcpChoices(alloc, workspace_root) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("mcp", "workspace MCP choices unavailable err={s}", .{@errorName(err)});
        loaded.configs = profile;
        profile = .empty;
        try project_config.overrideWith(alloc, &loaded.configs, &local);
        try project_config.noteIgnoredKeys(alloc, &loaded.diagnostics, loaded.configs.items);
        return loaded;
    };
    defer choice_load.deinit(alloc);
    for (choice_load.diagnostics.items) |diagnostic| {
        var name_buf: [256]u8 = undefined;
        debug_trace.logf(
            "mcp",
            "workspace MCP choice diagnostic cause={s} server={s}",
            .{
                @tagName(diagnostic.cause),
                if (diagnostic.server_name) |name|
                    debug_trace.terminalPreview(name_buf[0..], name)
                else
                    "none",
            },
        );
    }

    var workspace = try workspace_config.load(
        alloc,
        workspace_root,
        .workspace,
        choice_load.choices,
    );
    defer workspace.deinit(alloc);
    traceWorkspaceDiagnostics(workspace.diagnostics.items);

    try loaded.diagnostics.appendSlice(alloc, workspace.diagnostics.items);
    workspace.diagnostics.clearRetainingCapacity();

    loaded.configs = try project_config.mergeNative(alloc, &profile, &workspace.configs);
    profile.deinit(alloc);
    profile = .empty;
    try project_config.overrideWith(alloc, &loaded.configs, &local);
    try project_config.noteIgnoredKeys(alloc, &loaded.diagnostics, loaded.configs.items);
    return loaded;
}

fn readLocalServers(
    alloc: Allocator,
    profile_path: []const u8,
    workspace_root: []const u8,
    skipped: *std.ArrayList(project_config.WorkspaceDiagnostic),
) Allocator.Error!std.ArrayList(McpServerConfig) {
    const json_text = (config_file.read(alloc, profile_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .empty,
    }) orelse return .empty;
    defer alloc.free(json_text);
    return project_config.parseLocalServers(alloc, json_text, workspace_root, skipped) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("mcp", "local MCP servers unavailable err={s}", .{@errorName(err)});
            return .empty;
        },
    };
}

fn appendPluginMcpConfigs(alloc: Allocator, workspace_root: []const u8, loaded: *NativeConfigs) !void {
    const home = io_mod.homeDir() orelse return;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const plugins = plugin_manager.load(arena_state.allocator(), home) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("mcp", "plugin MCP servers unavailable err={s}", .{@errorName(err)});
        return;
    };
    try plugin_mcp.appendEnabledIn(alloc, plugins, .{ .home = home, .project = workspace_root }, &loaded.configs);
}

const ManagedFiles = struct {
    exclusive: ?[]u8 = null,
    settings: ?[]u8 = null,

    fn read(alloc: Allocator) Allocator.Error!ManagedFiles {
        var files: ManagedFiles = .{};
        errdefer files.deinit(alloc);
        files.exclusive = try readManagedFile(alloc, managed_policy.exclusive_file_name);
        files.settings = try readManagedFile(alloc, managed_policy.settings_file_name);
        return files;
    }

    fn texts(self: *const ManagedFiles) managed_policy.Files {
        return .{ .exclusive = self.exclusive, .settings = self.settings };
    }

    fn deinit(self: *ManagedFiles, alloc: Allocator) void {
        if (self.exclusive) |text| alloc.free(text);
        if (self.settings) |text| alloc.free(text);
        self.* = .{};
    }
};

fn readManagedFile(alloc: Allocator, name: []const u8) Allocator.Error!?[]u8 {
    const path = try std.Io.Dir.path.join(alloc, &.{ managed_policy.directory, name });
    defer alloc.free(path);
    return config_file.read(alloc, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("mcp", "managed MCP policy file unreadable name={s} err={s}", .{ name, @errorName(err) });
            return try alloc.dupe(u8, "");
        },
    };
}

pub fn enforceManagedPolicy(alloc: Allocator, configs: *std.ArrayList(McpServerConfig)) Allocator.Error!void {
    var managed = try ManagedFiles.read(alloc);
    defer managed.deinit(alloc);
    if (managed.texts().none()) return;
    var diagnostics: std.ArrayList(project_config.WorkspaceDiagnostic) = .empty;
    defer {
        for (diagnostics.items) |*diagnostic| diagnostic.deinit(alloc);
        diagnostics.deinit(alloc);
    }
    try managed_policy.install(alloc, managed.texts(), configs, &diagnostics);
    try managed_policy.filter(alloc, managed.texts(), configs, &diagnostics);
    traceWorkspaceDiagnostics(diagnostics.items);
}

fn skipUnprintableNames(alloc: Allocator, loaded: *NativeConfigs) Allocator.Error!void {
    var i: usize = 0;
    while (i < loaded.configs.items.len) {
        const c = &loaded.configs.items[i];
        if (text_utils.isTerminalSafe(c.name)) {
            i += 1;
            continue;
        }
        try loaded.diagnostics.ensureUnusedCapacity(alloc, 1);
        const name = try alloc.dupe(u8, c.name);
        loaded.diagnostics.appendAssumeCapacity(.{ .profile = c.source != .workspace, .server_name = name, .cause = .invalid_entry, .problem = .name });
        var removed = loaded.configs.orderedRemove(i);
        removed.deinit(alloc);
    }
}

const KimiMcpSettings = struct {
    reconnect_initial_delay_ms: ?u32 = null,
    reconnect_max_delay_ms: ?u32 = null,
    startup_timeout_ms: ?u32 = null,
    tool_timeout_ms: ?u32 = null,
    default_deferred: ?bool = null,
    tool_select: bool = false,
};

fn loadKimiMcpSettings(alloc: Allocator, workspace_root: []const u8) KimiMcpSettings {
    var settings = config_runtime.loadMergedSettings(alloc, workspace_root) catch |err| {
        debug_trace.logf("mcp", "MCP global settings unavailable err={s}", .{@errorName(err)});
        return .{};
    };
    defer settings.deinit(alloc);
    config_runtime.applyEnvSettingOverrides(alloc, &settings) catch |err| {
        debug_trace.logf("mcp", "MCP global settings read without environment overrides err={s}", .{@errorName(err)});
    };
    return .{
        .reconnect_initial_delay_ms = millisecondsOrNull(settings.kimi.mcp_reconnect_initial_delay_ms),
        .reconnect_max_delay_ms = millisecondsOrNull(settings.kimi.mcp_reconnect_max_delay_ms),
        .startup_timeout_ms = millisecondsOrNull(settings.kimi.mcp_startup_timeout_ms),
        .tool_timeout_ms = millisecondsOrNull(settings.kimi.mcp_tool_timeout_ms),
        .default_deferred = settings.kimi.mcp_default_deferred,
        .tool_select = kimi_sections.experimentalEnabled(&settings.kimi, "tool_select"),
    };
}

fn millisecondsOrNull(value: ?usize) ?u32 {
    return std.math.cast(u32, value orelse return null);
}

fn applyGlobalTimeouts(configs: []McpServerConfig, settings: KimiMcpSettings) void {
    for (configs) |*config| {
        if (!config.startup_timeout_configured) if (settings.startup_timeout_ms) |global_ms| {
            config.startup_timeout_ms = global_ms;
        };
        if (!config.operation_timeout_configured) if (settings.tool_timeout_ms) |global_ms| {
            config.operation_timeout_ms = global_ms;
        };
    }
}

test "a global MCP timeout fills only the servers that set none of their own" {
    var configs = [_]McpServerConfig{
        .{ .name = "plain", .command = "node" },
        .{ .name = "tuned", .command = "node", .startup_timeout_ms = 125, .operation_timeout_ms = 250, .startup_timeout_configured = true, .operation_timeout_configured = true },
        .{ .name = "half", .command = "node", .startup_timeout_ms = 30_000, .startup_timeout_configured = true },
    };
    applyGlobalTimeouts(&configs, .{ .startup_timeout_ms = 5_000, .tool_timeout_ms = 9_000 });
    try std.testing.expectEqual(@as(u32, 5_000), configs[0].startup_timeout_ms);
    try std.testing.expectEqual(@as(u32, 9_000), configs[0].operation_timeout_ms);
    try std.testing.expectEqual(@as(u32, 125), configs[1].startup_timeout_ms);
    try std.testing.expectEqual(@as(u32, 250), configs[1].operation_timeout_ms);
    try std.testing.expectEqual(@as(u32, 30_000), configs[2].startup_timeout_ms);
    try std.testing.expectEqual(@as(u32, 9_000), configs[2].operation_timeout_ms);

    applyGlobalTimeouts(&configs, .{});
    try std.testing.expectEqual(@as(u32, 5_000), configs[0].startup_timeout_ms);
}

fn applyToolLoading(configs: []McpServerConfig, settings: KimiMcpSettings) void {
    for (configs) |*config| {
        const deferred = settings.tool_select and (config.deferred orelse settings.default_deferred orelse false);
        config.always_loaded = !deferred;
    }
}

test "MCP tools load at the top level unless tool_select is on and the server or the global default defers them" {
    var configs = [_]McpServerConfig{
        .{ .name = "plain", .command = "node" },
        .{ .name = "deferred", .command = "node", .deferred = true },
        .{ .name = "eager", .command = "node", .deferred = false },
    };
    applyToolLoading(&configs, .{});
    for (configs) |config| try std.testing.expect(config.always_loaded);

    applyToolLoading(&configs, .{ .default_deferred = true });
    for (configs) |config| try std.testing.expect(config.always_loaded);

    applyToolLoading(&configs, .{ .tool_select = true });
    try std.testing.expect(configs[0].always_loaded);
    try std.testing.expect(!configs[1].always_loaded);
    try std.testing.expect(configs[2].always_loaded);

    applyToolLoading(&configs, .{ .tool_select = true, .default_deferred = true });
    try std.testing.expect(!configs[0].always_loaded);
    try std.testing.expect(!configs[1].always_loaded);
    try std.testing.expect(configs[2].always_loaded);
}

pub fn loadHost(
    alloc: Allocator,
    workspace_root: []const u8,
    builtins: tool_dispatch.Registry,
    extras: mcp_host.Extras,
) !?*mcp_host.Host {
    var loaded = try loadNativeConfigs(alloc, workspace_root);
    defer loaded.deinit(alloc);
    try appendPluginMcpConfigs(alloc, workspace_root, &loaded);
    const home = io_mod.homeDir() orelse return null;

    var managed = try ManagedFiles.read(alloc);
    defer managed.deinit(alloc);
    try managed_policy.install(alloc, managed.texts(), &loaded.configs, &loaded.diagnostics);

    var inherited = try io_mod.cloneEnvironMap(alloc);
    defer inherited.deinit();
    try project_config.expandProfileConfigs(alloc, &loaded.configs, &loaded.diagnostics, &inherited);
    try managed_policy.filter(alloc, managed.texts(), &loaded.configs, &loaded.diagnostics);
    try skipUnprintableNames(alloc, &loaded);

    if (loaded.configs.items.len == 0 and loaded.diagnostics.items.len == 0 and extras.reuse == null) return null;
    const kimi_mcp = loadKimiMcpSettings(alloc, workspace_root);
    applyGlobalTimeouts(loaded.configs.items, kimi_mcp);
    applyToolLoading(loaded.configs.items, kimi_mcp);
    if (extras.session_open and extras.reuse == null) {
        debug_trace.logf("mcp", "MCP servers left for the next session count={d} reason=this session started without MCP servers", .{loaded.configs.items.len});
        return null;
    }
    if (extras.reuse) |h| {
        if (h.reload(loaded.configs.items, &inherited, try renderNotes(alloc, loaded.diagnostics.items))) |_| return h else |err| {
            debug_trace.logf("mcp", "MCP host not reloaded in place, starting a new one err={s}", .{@errorName(err)});
        }
    }
    const notes = try renderNotes(alloc, loaded.diagnostics.items);
    errdefer {
        for (notes) |note| alloc.free(note);
        alloc.free(notes);
    }
    const h = try mcp_host.Host.create(alloc, io_mod.getIo(), loaded.configs.items, &inherited, .{
        .client_version = build_options.app_version,
        .credentials = .{ .detect = home },
        .workspace_root = workspace_root,
        .questions = extras.questions,
        .notify = extras.notify,
        .slash_commands = extras.slash_commands,
        .reconnect_initial_delay_ms = kimi_mcp.reconnect_initial_delay_ms,
        .reconnect_max_delay_ms = kimi_mcp.reconnect_max_delay_ms,
    }, builtins);
    h.notes = notes;
    return h;
}

fn renderNotes(alloc: Allocator, diagnostics: []const project_config.WorkspaceDiagnostic) ![]const []const u8 {
    const notes = try alloc.alloc([]const u8, diagnostics.len);
    var rendered: usize = 0;
    errdefer {
        for (notes[0..rendered]) |note| alloc.free(note);
        alloc.free(notes);
    }
    for (diagnostics, notes) |diagnostic, *note| {
        note.* = try project_config.renderWorkspaceDiagnostic(alloc, diagnostic);
        rendered += 1;
    }
    return notes;
}

fn traceWorkspaceDiagnostics(diagnostics: []const project_config.WorkspaceDiagnostic) void {
    for (diagnostics) |diagnostic| {
        var name_buf: [256]u8 = undefined;
        var variable_buf: [160]u8 = undefined;
        debug_trace.logf(
            "mcp",
            "workspace MCP config skipped cause={s} server={s} field={s} variable={s}",
            .{
                @tagName(diagnostic.cause),
                if (diagnostic.server_name) |name|
                    debug_trace.terminalPreview(name_buf[0..], name)
                else
                    "none",
                if (diagnostic.environment_field) |field| @tagName(field) else "none",
                if (diagnostic.environment_variable) |name|
                    debug_trace.terminalPreview(variable_buf[0..], name)
                else
                    "none",
            },
        );
    }
}

pub fn inspectProfileConfig(
    alloc: Allocator,
) error{OutOfMemory}!mcp_contract.ProfileConfigDiagnostic {
    const home = io_mod.homeDir() orelse return .clear;
    const config_path = try configPathFromHome(alloc, home);
    defer alloc.free(config_path);

    var document = loadProfileDocumentFromPath(alloc, config_path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failed = err };
    };
    defer document.deinit(alloc);
    return if (document.diagnostic) |warning|
        .{ .warning = warning }
    else
        .clear;
}

pub fn inspectLocalConfig(
    alloc: Allocator,
    workspace_root: []const u8,
) error{OutOfMemory}!mcp_health.LocalConfigInspection {
    var profile: std.ArrayList(McpServerConfig) = .empty;
    defer freeConfigs(alloc, &profile);
    var profile_diagnostic: mcp_contract.ProfileConfigDiagnostic = .clear;
    if (io_mod.homeDir()) |home| {
        const config_path = try configPathFromHome(alloc, home);
        defer alloc.free(config_path);
        var document = loadProfileDocumentFromPath(alloc, config_path) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return emptyLocalInspection(alloc, .{ .failed = err }, @errorName(err));
        };
        defer document.deinit(alloc);
        profile_diagnostic = if (document.diagnostic) |warning|
            .{ .warning = warning }
        else
            .clear;
        profile = document.configs;
        document.configs = .empty;
    }

    var choice_load = config_runtime.loadProjectMcpChoices(alloc, workspace_root) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return localInspectionFromConfigs(
            alloc,
            profile.items,
            &.{},
            profile_diagnostic,
            null,
        );
    };
    defer choice_load.deinit(alloc);
    var workspace = workspace_config.load(
        alloc,
        workspace_root,
        .workspace,
        choice_load.choices,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return emptyLocalInspection(
            alloc,
            profile_diagnostic,
            @errorName(err),
        );
    };
    defer workspace.deinit(alloc);
    var configs = project_config.mergeNative(
        alloc,
        &profile,
        &workspace.configs,
    ) catch return error.OutOfMemory;
    defer freeConfigs(alloc, &configs);
    return localInspectionFromConfigs(
        alloc,
        configs.items,
        workspace.diagnostics.items,
        profile_diagnostic,
        null,
    );
}

fn emptyLocalInspection(
    alloc: Allocator,
    profile_diagnostic: mcp_contract.ProfileConfigDiagnostic,
    inspection_error: ?[]const u8,
) error{OutOfMemory}!mcp_health.LocalConfigInspection {
    return localInspectionFromConfigs(
        alloc,
        &.{},
        &.{},
        profile_diagnostic,
        inspection_error,
    );
}

fn localInspectionFromConfigs(
    alloc: Allocator,
    configs: []const McpServerConfig,
    diagnostics: []const project_config.WorkspaceDiagnostic,
    profile_diagnostic: mcp_contract.ProfileConfigDiagnostic,
    inspection_error: ?[]const u8,
) error{OutOfMemory}!mcp_health.LocalConfigInspection {
    const servers = try alloc.alloc(mcp_health.ConfiguredServerSnapshot, configs.len);
    var servers_initialized: usize = 0;
    errdefer {
        for (servers[0..servers_initialized]) |*server| server.deinit(alloc);
        alloc.free(servers);
    }
    for (configs, 0..) |config, index| {
        var encoded_name = try text_utils.encodeTerminalSafe(alloc, config.name, 256);
        servers[index] = .{
            .configured_name = encoded_name.bytes,
            .source = config.source,
            .scope = config.scope,
            .workspace_admission = config.workspace_admission,
            .required = config.required,
            .transport = config.transport,
            .enabled = config.enabled,
        };
        encoded_name = undefined;
        servers_initialized += 1;
    }

    const issues = try alloc.alloc(mcp_health.ConfigurationIssue, diagnostics.len);
    var issues_initialized: usize = 0;
    errdefer {
        for (issues[0..issues_initialized]) |*issue| issue.deinit(alloc);
        alloc.free(issues);
    }
    for (diagnostics, 0..) |diagnostic, index| {
        issues[index] = .{
            .message = try project_config.renderWorkspaceDiagnostic(alloc, diagnostic),
        };
        issues_initialized += 1;
    }
    return .{
        .profile_diagnostic = profile_diagnostic,
        .snapshot = .{
            .servers = servers,
            .configuration_issues = issues,
        },
        .inspection_error = inspection_error,
    };
}

pub fn loadConfigFromPath(alloc: Allocator, path: []const u8) !std.ArrayList(McpServerConfig) {
    return readProfile(alloc, path, null);
}

fn readProfile(alloc: Allocator, path: []const u8, skipped: ?*std.ArrayList(project_config.WorkspaceDiagnostic)) !std.ArrayList(McpServerConfig) {
    const json_text = (config_file.read(alloc, path) catch |err| {
        logConfigFailure("read", path, err);

        return switch (err) {
            error.SymLinkLoop => error.McpConfigLinkLoop,
            error.StreamTooLong => error.McpConfigTooLarge,
            error.DurablePathUnsafe => error.McpConfigNotPlainFile,
            else => err,
        };
    }) orelse return .empty;
    defer alloc.free(json_text);

    return project_config.parseProfileServers(alloc, json_text, skipped) catch |err| {
        logConfigFailure("load", path, err);
        return err;
    };
}

fn loadConfigFromJson(alloc: Allocator, json_text: []const u8) !std.ArrayList(McpServerConfig) {
    return project_config.parseProfileJson(alloc, json_text);
}

fn loadProfileDocumentFromPath(
    alloc: Allocator,
    path: []const u8,
) !project_config.ProfileParseResult {
    const json_text = (try config_file.read(alloc, path)) orelse return .{};
    defer alloc.free(json_text);
    return project_config.parseProfileDocument(alloc, json_text);
}

fn saveConfigsToPath(alloc: Allocator, path: []const u8, configs: []const McpServerConfig) !void {
    const json = try renderConfigJson(alloc, configs);
    defer alloc.free(json);
    try config_file.replaceProfile(alloc, path, json);
}

fn freeConfigs(alloc: Allocator, configs: *std.ArrayList(McpServerConfig)) void {
    for (configs.items) |config| {
        var mutable = config;
        mutable.deinit(alloc);
    }
    configs.deinit(alloc);
}

fn findConfig(configs: []const McpServerConfig, name: []const u8) ?*const McpServerConfig {
    for (configs) |*config| {
        if (std.mem.eql(u8, config.name, name)) return config;
    }
    return null;
}

noinline fn logConfigFailure(action: []const u8, path: []const u8, err: anyerror) void {
    debug_trace.logf(
        "mcp",
        "failed to {s} config {s}: {s}",
        .{ action, path, @errorName(err) },
    );
}

fn renderConfigJson(alloc: Allocator, configs: []const McpServerConfig) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"mcp\":{");
    for (configs, 0..) |config, i| {
        if (i > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(config.name, .{}, &out.writer);
        try out.writer.writeAll(":{");

        switch (config.transport) {
            .stdio => {
                try out.writer.writeAll("\"type\":\"local\",\"command\":[");
                try std.json.Stringify.value(try config.stdioCommand(), .{}, &out.writer);
                for (config.args) |arg| {
                    try out.writer.writeByte(',');
                    try std.json.Stringify.value(arg, .{}, &out.writer);
                }
                try out.writer.writeByte(']');
            },
            .sse => {
                try out.writer.writeAll("\"type\":\"sse\",\"url\":");
                try std.json.Stringify.value(try config.remoteUrl(), .{}, &out.writer);
            },
            .http => {
                try out.writer.writeAll("\"type\":\"http\",\"url\":");
                try std.json.Stringify.value(try config.remoteUrl(), .{}, &out.writer);
            },
        }

        try out.writer.print(",\"enabled\":{s}", .{if (config.enabled) "true" else "false"});
        if (config.required) try out.writer.writeAll(",\"required\":true");
        if (config.transport == .stdio or
            config.transport == .http or
            config.transport == .sse)
        {
            try out.writer.print(
                ",\"startupTimeoutMs\":{d},\"toolTimeoutMs\":{d}",
                .{ config.startup_timeout_ms, config.operation_timeout_ms },
            );
        }
        if (config.transport == .stdio) {
            try out.writer.print(",\"restart_limit\":{d}", .{config.restart_limit});
        }
        if (config.headers.len > 0) {
            try out.writer.writeAll(",\"headers\":{");
            for (config.headers, 0..) |header, header_i| {
                if (header_i > 0) try out.writer.writeByte(',');
                try std.json.Stringify.value(header.name, .{}, &out.writer);
                try out.writer.writeByte(':');
                try std.json.Stringify.value(header.value, .{}, &out.writer);
            }
            try out.writer.writeByte('}');
        }
        if (config.header_env.len > 0) {
            try out.writer.writeAll(",\"header_env\":{");
            for (config.header_env, 0..) |ref, ref_i| {
                if (ref_i > 0) try out.writer.writeByte(',');
                try std.json.Stringify.value(ref.name, .{}, &out.writer);
                try out.writer.writeByte(':');
                try std.json.Stringify.value(ref.env, .{}, &out.writer);
            }
            try out.writer.writeByte('}');
        }
        if (config.bearer_token_env) |env_name| {
            try out.writer.writeAll(",\"bearerTokenEnvVar\":");
            try std.json.Stringify.value(env_name, .{}, &out.writer);
        }
        if (config.auth) |auth| {
            try out.writer.writeAll(",\"oauth\":{");
            var first_auth = true;
            if (auth.resource) |field| try writeOptionalJsonField(&out.writer, &first_auth, "resource", field);
            if (auth.issuer) |field| try writeOptionalJsonField(&out.writer, &first_auth, "issuer", field);
            if (auth.client_id) |field| try writeOptionalJsonField(&out.writer, &first_auth, "client_id", field);
            if (auth.client_secret_env) |field| try writeOptionalJsonField(&out.writer, &first_auth, "client_secret_env", field);
            if (auth.client_metadata_url) |field| try writeOptionalJsonField(&out.writer, &first_auth, "client_metadata_url", field);
            if (auth.auth_server_metadata_url) |field| try writeOptionalJsonField(&out.writer, &first_auth, "authServerMetadataUrl", field);
            if (auth.scopes_configured or auth.scopes.len > 0) {
                if (!first_auth) try out.writer.writeByte(',');
                first_auth = false;
                try out.writer.writeAll("\"scopes\":[");
                for (auth.scopes, 0..) |scope, scope_i| {
                    if (scope_i > 0) try out.writer.writeByte(',');
                    try std.json.Stringify.value(scope, .{}, &out.writer);
                }
                try out.writer.writeByte(']');
            }
            if (auth.callback_port) |port| {
                if (!first_auth) try out.writer.writeByte(',');
                first_auth = false;
                try out.writer.print("\"callback_port\":{d}", .{port});
            }
            try out.writer.writeByte('}');
        }
        if (config.env.len > 0) {
            try out.writer.writeAll(",\"environment\":{");
            for (config.env, 0..) |entry, env_i| {
                if (env_i > 0) try out.writer.writeByte(',');
                try std.json.Stringify.value(entry.key, .{}, &out.writer);
                try out.writer.writeByte(':');
                try std.json.Stringify.value(entry.value, .{}, &out.writer);
            }
            try out.writer.writeByte('}');
        }
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

fn writeOptionalJsonField(
    writer: *std.Io.Writer,
    first: *bool,
    key: []const u8,
    value: []const u8,
) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try std.json.Stringify.value(key, .{}, writer);
    try writer.writeByte(':');
    try std.json.Stringify.value(value, .{}, writer);
}

const TestHome = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, home: ?[]const u8) !*TestHome {
        const self = try alloc.create(TestHome);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();

        if (home) |value| {
            try self.map.put("HOME", value);
        }

        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestHome) void {
        io_mod.resetEnvironForTest();
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

const ListFixture = struct {
    text: []const u8,
    calls: usize = 0,
    summary_calls: usize = 0,

    fn list(raw_ctx: *anyopaque, alloc: Allocator) ![]u8 {
        const self: *ListFixture = @ptrCast(@alignCast(raw_ctx));
        self.calls += 1;
        return alloc.dupe(u8, self.text);
    }

    fn summary(raw_ctx: *anyopaque, alloc: Allocator) ![]u8 {
        const self: *ListFixture = @ptrCast(@alignCast(raw_ctx));
        self.summary_calls += 1;
        return alloc.dupe(u8, "MCP: no servers configured. Use /mcp add <name> <command> [args...].");
    }
};

fn tmpRoot(alloc: Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
}

fn tmpPath(alloc: Allocator, root: []const u8, name: []const u8) ![]u8 {
    return std.Io.Dir.path.join(alloc, &.{ root, name });
}

test "a server whose name a terminal can't show is skipped with a note that escapes it" {
    const alloc = std.testing.allocator;

    const json =
        \\{"mcpServers":{"ok":{"command":"true"},"evil\u001b]0;x\u0007":{"command":"true"},"rtl\u202etxt":{"command":"true"},"caf\u00e9 two":{"command":"true"}}}
    ;
    var loaded: NativeConfigs = .{};
    defer loaded.deinit(alloc);
    loaded.configs = try project_config.parseProfileServers(alloc, json, &loaded.diagnostics);
    try std.testing.expectEqual(@as(usize, 4), loaded.configs.items.len);
    alloc.free(loaded.configs.items[0].name);
    loaded.configs.items[0].name = try alloc.dupe(u8, "bad\xff");

    try skipUnprintableNames(alloc, &loaded);
    try std.testing.expectEqual(@as(usize, 1), loaded.configs.items.len);
    try std.testing.expectEqualStrings("caf\u{e9} two", loaded.configs.items[0].name);
    try std.testing.expectEqual(@as(usize, 3), loaded.diagnostics.items.len);
    const expected = [_][]const u8{
        "~/.fx/mcp.json server 'bad\\xff' was skipped: its name has a character fx won't print.",
        "~/.fx/mcp.json server 'evil\\x1b]0;x\\x07' was skipped: its name has a character fx won't print.",
        "~/.fx/mcp.json server 'rtl\\u{202e}txt' was skipped: its name has a character fx won't print.",
    };
    for (loaded.diagnostics.items, expected) |diagnostic, want| {
        const note = try project_config.renderWorkspaceDiagnostic(alloc, diagnostic);
        defer alloc.free(note);
        try std.testing.expectEqualStrings(want, note);
    }
}

test "saving MCP config replaces the file durably" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = "{\"mcp\":{\"stale\":{\"command\":\"echo\"}}}";
    try writeTempFile(&tmp, "home/.fx/mcp.json", original);
    const path = try tmpDirPath(alloc, tmp.dir, "home/.fx/mcp.json");
    defer alloc.free(path);

    var fx_dir = try tmp.dir.openDir(io_mod.getIo(), "home/.fx", .{ .iterate = true });
    defer fx_dir.close(io_mod.getIo());

    {
        var seed = try fx_dir.openFile(io_mod.getIo(), "mcp.json", .{ .mode = .read_write });
        defer seed.close(io_mod.getIo());
        try seed.setPermissions(io_mod.getIo(), std.Io.File.Permissions.fromMode(0o644));
    }

    var held = try fx_dir.openFile(io_mod.getIo(), "mcp.json", .{});
    defer held.close(io_mod.getIo());

    try saveConfigsToPath(alloc, path, &.{});

    const held_stat = try held.stat(io_mod.getIo());
    try std.testing.expectEqual(@as(u64, 0), held_stat.nlink);
    const held_bytes = try io_mod.readFileToEnd(alloc, &held, 4096);
    defer alloc.free(held_bytes);
    try std.testing.expectEqualStrings(original, held_bytes);

    const written = try readFileForTest(alloc, path);
    defer alloc.free(written);
    try std.testing.expect(std.mem.find(u8, written, "stale") == null);

    const stat = try fx_dir.statFile(io_mod.getIo(), "mcp.json", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);

    var it = fx_dir.iterate();
    var entries: usize = 0;
    while (try it.next(io_mod.getIo())) |entry| {
        entries += 1;
        try std.testing.expectEqualStrings("mcp.json", entry.name);
    }
    try std.testing.expectEqual(@as(usize, 1), entries);
}

fn tmpDirPath(alloc: Allocator, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, dir, sub_path);
}

fn writeTempFile(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn readFileForTest(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
}

test "MCP config diagnostic treats nonblocking profile states as clear" {
    const alloc = std.testing.allocator;

    {
        const test_home = try TestHome.install(alloc, null);
        defer test_home.deinit();

        switch (try inspectProfileConfig(alloc)) {
            .clear, .warning => {},
            .failed => return error.TestUnexpectedResult,
        }
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const home_path = try tmpDirPath(alloc, tmp.dir, "home");
    defer alloc.free(home_path);

    {
        const test_home = try TestHome.install(alloc, home_path);
        defer test_home.deinit();

        switch (try inspectProfileConfig(alloc)) {
            .clear, .warning => {},
            .failed => return error.TestUnexpectedResult,
        }
    }

    try writeTempFile(&tmp, "home/.fx/mcp.json", "{\"mcp\":{}}");
    {
        const test_home = try TestHome.install(alloc, home_path);
        defer test_home.deinit();

        switch (try inspectProfileConfig(alloc)) {
            .clear, .warning => {},
            .failed => return error.TestUnexpectedResult,
        }
    }
}

test "MCP config diagnostic propagates allocation failure" {
    const alloc = testing_allocator.no_resize;
    const test_home = try TestHome.install(alloc, "/tmp");
    defer test_home.deinit();

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        inspectProfileConfig(failing.allocator()),
    );
}

test "MCP config diagnostic preserves parser allocation failure" {
    var failing = std.testing.FailingAllocator.init(
        testing_allocator.no_resize,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        loadConfigFromJson(failing.allocator(), "{\"mcp\":{}}"),
    );
}

test "workspace MCP loading expands command args environment and HTTP headers" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.git");
    try writeTempFile(&tmp, "workspace/.mcp.json",
        \\{"mcpServers":{"local":{"command":"${MCP_COMMAND}","args":["--token=${MCP_TOKEN}","${MCP_OPTIONAL:-fallback}"],"env":{"TOKEN":"${MCP_TOKEN}"}},"remote":{"type":"http","url":"https://example.test/mcp","headers":{"X-MCP-Token":"Bearer ${MCP_TOKEN}"}}}}
    );
    const workspace_root = try tmpDirPath(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace_root);

    const environment = try TestHome.install(alloc, "/tmp");
    defer environment.deinit();
    try environment.map.put("MCP_COMMAND", "node");
    try environment.map.put("MCP_TOKEN", "secret-value");
    var approved_names = [_][]u8{ @constCast("local"), @constCast("remote") };

    var result = try workspace_config.load(
        alloc,
        workspace_root,
        .workspace,
        .{ .approved = &approved_names },
    );
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), result.configs.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
    const local = result.configs.items[0];
    try std.testing.expectEqualStrings("node", local.command.?);
    try std.testing.expectEqualStrings("--token=secret-value", local.args[0]);
    try std.testing.expectEqualStrings("fallback", local.args[1]);
    try std.testing.expectEqualStrings("secret-value", local.env[0].value);
    const remote = result.configs.items[1];
    try std.testing.expectEqualStrings("Bearer secret-value", remote.headers[0].value);
}

test "fx mcp approve saves the approval of a project server" {
    const alloc = std.testing.allocator;
    const mcp_verbs = @import("../core/mcp_host/verbs.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.git");
    try writeTempFile(&tmp, "workspace/.mcp.json",
        \\{"mcpServers":{"fixture":{"command":"fixture-server"}}}
    );
    const home = try tmpDirPath(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace_root = try tmpDirPath(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace_root);
    const test_home = try TestHome.install(alloc, home);
    defer test_home.deinit();

    try test_home.map.put("FX_DISABLE_KEYCHAIN", "1");

    const Hosts = struct {
        workspace_root: []const u8,

        fn get(context: *anyopaque, notify: ?mcp_verbs.Notify) anyerror!?*mcp_host.Host {
            const self: *@This() = @ptrCast(@alignCast(context));
            return loadHost(std.testing.allocator, self.workspace_root, @import("tools.zig").registry, .{ .notify = notify });
        }

        fn release(_: *anyopaque, h: *mcp_host.Host) void {
            h.destroy();
        }

        fn changed(_: *anyopaque) void {}
    };
    var hosts: Hosts = .{ .workspace_root = workspace_root };
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(alloc);
    defer err.deinit();

    const code = mcp_verbs.run(.{
        .gpa = alloc,
        .out = &out.writer,
        .err = &err.writer,
        .surface = .cli,
        .home = home,
        .workspace_root = workspace_root,
        .hosts = .{ .context = &hosts, .get = Hosts.get, .release = Hosts.release, .changed = Hosts.changed },
    }, &.{ "approve", "fixture" });
    try std.testing.expectEqualStrings("", err.written());
    try std.testing.expectEqualStrings("Approved fixture, which runs: fixture-server\n", out.written());
    try std.testing.expectEqual(@as(u8, 0), code);

    var choices = try config_runtime.loadProjectMcpChoices(alloc, workspace_root);
    defer choices.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), choices.choices.approved.len);
    try std.testing.expectEqualStrings("fixture", choices.choices.approved[0]);
}

test "saving MCP config refuses a symlinked target" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const external = "{\"mcp\":{\"fs\":{\"command\":\"node\"}}}";
    try writeTempFile(&tmp, "home/external.json", external);
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    const external_path = try tmpDirPath(alloc, tmp.dir, "home/external.json");
    defer alloc.free(external_path);
    try tmp.dir.symLink(io_mod.getIo(), external_path, "home/.fx/mcp.json", .{ .is_directory = false });

    const path = try std.Io.Dir.path.join(alloc, &.{ std.Io.Dir.path.dirname(external_path).?, ".fx", "mcp.json" });
    defer alloc.free(path);

    try std.testing.expectError(error.DurablePathUnsafe, saveConfigsToPath(alloc, path, &.{}));

    const untouched = try readFileForTest(alloc, external_path);
    defer alloc.free(untouched);
    try std.testing.expectEqualStrings(external, untouched);
}

test "a profile config fx can't read fails with an error named for the file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpDirPath(alloc, tmp.dir, ".");
    defer alloc.free(root);

    try tmp.dir.symLink(io_mod.getIo(), "loop.json", "loop.json", .{ .is_directory = false });
    const loop = try std.Io.Dir.path.join(alloc, &.{ root, "loop.json" });
    defer alloc.free(loop);
    try std.testing.expectError(error.McpConfigLinkLoop, loadConfigFromPath(alloc, loop));

    const big = try alloc.alloc(u8, 1024 * 1024 + 1);
    defer alloc.free(big);
    @memset(big, ' ');
    try writeTempFile(&tmp, "big.json", big);
    const big_path = try std.Io.Dir.path.join(alloc, &.{ root, "big.json" });
    defer alloc.free(big_path);
    try std.testing.expectError(error.McpConfigTooLarge, loadConfigFromPath(alloc, big_path));
}

test "loadConfigFromJson parses canonical local config with command array" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"myserver":{"type":"local","command":["node","server.js"]}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqual(McpTransport.stdio, configs.items[0].transport);
    try std.testing.expectEqualStrings("myserver", configs.items[0].name);
    try std.testing.expectEqualStrings("node", try configs.items[0].stdioCommand());
    try std.testing.expectEqual(@as(usize, 1), configs.items[0].args.len);
    try std.testing.expectEqualStrings("server.js", configs.items[0].args[0]);
    try std.testing.expect(configs.items[0].enabled);
}

test "loadConfigFromJson parses local config with environment enabled and args" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"everything":{"type":"local","command":["npx","-y","@modelcontextprotocol/server-everything"],"enabled":false,"environment":{"TOKEN":"abc"}}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqualStrings("everything", configs.items[0].name);
    try std.testing.expectEqualStrings("npx", try configs.items[0].stdioCommand());
    try std.testing.expectEqual(@as(usize, 2), configs.items[0].args.len);
    try std.testing.expectEqualStrings("-y", configs.items[0].args[0]);
    try std.testing.expectEqualStrings("@modelcontextprotocol/server-everything", configs.items[0].args[1]);
    try std.testing.expectEqual(@as(usize, 1), configs.items[0].env.len);
    try std.testing.expectEqualStrings("TOKEN", configs.items[0].env[0].key);
    try std.testing.expectEqualStrings("abc", configs.items[0].env[0].value);
    try std.testing.expect(!configs.items[0].enabled);
}

test "loadConfigFromJson returns empty for empty config" {
    const alloc = std.testing.allocator;
    var configs = try loadConfigFromJson(alloc, "{}");
    defer freeConfigs(alloc, &configs);
    try std.testing.expectEqual(@as(usize, 0), configs.items.len);
}

test "loadConfigFromJson reports invalid json" {
    try std.testing.expectError(
        error.McpConfigInvalidJson,
        loadConfigFromJson(std.testing.allocator, "{not json"),
    );
}

test "loadConfigFromJson parses stdio type as stdio" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"stdio_server":{"type":"stdio","command":["node","server.js"]}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqual(McpTransport.stdio, configs.items[0].transport);
    try std.testing.expectEqualStrings("node", try configs.items[0].stdioCommand());
}

test "profile required policy defaults optional and roundtrips canonically" {
    const alloc = std.testing.allocator;
    var configs = try loadConfigFromJson(
        alloc,
        "{\"mcp\":{\"optional\":{\"type\":\"stdio\",\"command\":[\"node\"]},\"required\":{\"type\":\"stdio\",\"command\":[\"node\"],\"required\":true}}}",
    );
    defer freeConfigs(alloc, &configs);
    const optional_config = findConfig(configs.items, "optional").?;
    const required_config = findConfig(configs.items, "required").?;
    try std.testing.expect(!optional_config.required);
    try std.testing.expect(required_config.required);
    try std.testing.expectEqual(mcp_contract.ConfigSource.profile, optional_config.source);
    try std.testing.expectEqual(mcp_contract.ConfigScope.profile, optional_config.scope);

    const rendered = try renderConfigJson(alloc, configs.items);
    defer alloc.free(rendered);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "\"required\":true"));

    var reparsed = try loadConfigFromJson(alloc, rendered);
    defer freeConfigs(alloc, &reparsed);
    try std.testing.expect(!findConfig(reparsed.items, "optional").?.required);
    try std.testing.expect(findConfig(reparsed.items, "required").?.required);
}

test "profile config reports invalid required policy" {
    try std.testing.expectError(
        error.McpConfigInvalidRequired,
        loadConfigFromJson(
            std.testing.allocator,
            "{\"mcp\":{\"server\":{\"command\":[\"node\"],\"required\":\"yes\"}}}",
        ),
    );
}

test "loadConfigFromJson parses string command with args" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"string_command":{"type":"local","command":"node","args":["server.js","--flag"]}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqualStrings("node", try configs.items[0].stdioCommand());
    try std.testing.expectEqual(@as(usize, 2), configs.items[0].args.len);
    try std.testing.expectEqualStrings("server.js", configs.items[0].args[0]);
    try std.testing.expectEqualStrings("--flag", configs.items[0].args[1]);
}

test "loadConfigFromJson parses sse config with url" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"remote":{"type":"sse","url":"https://mcp.example.com/rpc","enabled":true,"startupTimeoutMs":2500,"toolTimeoutMs":5000}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqualStrings("remote", configs.items[0].name);
    try std.testing.expectEqual(McpTransport.sse, configs.items[0].transport);
    try std.testing.expectEqualStrings("https://mcp.example.com/rpc", try configs.items[0].remoteUrl());
    try std.testing.expect(configs.items[0].enabled);
    try std.testing.expectEqual(
        @as(u32, 2500),
        configs.items[0].startup_timeout_ms,
    );
    try std.testing.expectEqual(
        @as(u32, 5000),
        configs.items[0].operation_timeout_ms,
    );
}

test "loadConfigFromJson preserves HTTP identity headers and timeouts" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"api":{"type":"http","url":"https://api.example.com/mcp","headers":{"X-Workspace":"one"},"startupTimeoutMs":2500,"toolTimeoutMs":5000}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqualStrings("api", configs.items[0].name);
    try std.testing.expectEqual(McpTransport.http, configs.items[0].transport);
    try std.testing.expectEqualStrings("https://api.example.com/mcp", try configs.items[0].remoteUrl());
    try std.testing.expectEqualStrings("X-Workspace", configs.items[0].headers[0].name);
    try std.testing.expectEqualStrings("one", configs.items[0].headers[0].value);
    try std.testing.expectEqual(@as(u32, 2500), configs.items[0].startup_timeout_ms);
    try std.testing.expectEqual(@as(u32, 5000), configs.items[0].operation_timeout_ms);
}

test "remote config keeps credential references and OAuth policy without secrets" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"api":{"type":"http","url":"https://api.example.com/mcp","header_env":{"X-Workspace":"MCP_WORKSPACE"},"bearerTokenEnvVar":"MCP_TOKEN","oauth":{"resource":"https://api.example.com/mcp","issuer":"https://login.example.com","client_id":"fx-client","client_secret_env":"MCP_CLIENT_SECRET","client_metadata_url":"https://client.example/fx.json","scopes":["tools.read","tools.call"]}}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    const config = configs.items[0];
    try std.testing.expectEqual(@as(usize, 1), config.header_env.len);
    try std.testing.expectEqualStrings("X-Workspace", config.header_env[0].name);
    try std.testing.expectEqualStrings("MCP_WORKSPACE", config.header_env[0].env);
    try std.testing.expectEqualStrings("MCP_TOKEN", config.bearer_token_env.?);
    const auth = config.auth.?;
    try std.testing.expectEqualStrings(
        "https://api.example.com/mcp",
        auth.resource.?,
    );
    try std.testing.expectEqualStrings("https://login.example.com", auth.issuer.?);
    try std.testing.expectEqualStrings("fx-client", auth.client_id.?);
    try std.testing.expectEqualStrings("MCP_CLIENT_SECRET", auth.client_secret_env.?);
    try std.testing.expectEqual(@as(usize, 2), auth.scopes.len);
    try std.testing.expectEqual(@as(?u16, null), auth.callback_port);
}

test "remote config keeps a pinned OAuth callback port" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"slack":{"type":"http","url":"https://mcp.slack.com/mcp","oauth":{"client_id":"fx-client","callback_port":3118}}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    const auth = configs.items[0].auth.?;
    try std.testing.expectEqualStrings("fx-client", auth.client_id.?);
    try std.testing.expectEqual(@as(?u16, 3118), auth.callback_port);
}

test "profile config rejects out-of-range OAuth callback ports" {
    const cases = [_][]const u8{
        \\{"mcp":{"api":{"type":"http","url":"https://api.example.com/mcp","oauth":{"callback_port":null}}}}
        ,
        \\{"mcp":{"api":{"type":"http","url":"https://api.example.com/mcp","oauth":{"callback_port":0}}}}
        ,
        \\{"mcp":{"api":{"type":"http","url":"https://api.example.com/mcp","oauth":{"callback_port":65536}}}}
        ,
        \\{"mcp":{"api":{"type":"http","url":"https://api.example.com/mcp","oauth":{"callback_port":"3118"}}}}
        ,
    };
    for (cases) |json| {
        try std.testing.expectError(
            error.McpConfigInvalidOAuth,
            loadConfigFromJson(std.testing.allocator, json),
        );
    }
}

test "profile config rejects a mixed set containing invalid client metadata URLs" {
    const json =
        \\{"mcp":{"loopback":{"type":"http","url":"https://api.example.com/mcp","oauth":{"client_metadata_url":"http://127.0.0.1:4321/client.json"}},"pathless":{"type":"http","url":"https://api.example.com/mcp","oauth":{"client_metadata_url":"https://client.example"}},"root":{"type":"http","url":"https://api.example.com/mcp","oauth":{"client_metadata_url":"https://client.example/"}},"valid":{"type":"http","url":"https://api.example.com/mcp","oauth":{"client_metadata_url":"https://client.example/fx.json"}}}}
    ;
    try std.testing.expectError(
        error.McpConfigInvalidOAuth,
        loadConfigFromJson(std.testing.allocator, json),
    );
}

test "profile config reports literal authorization secrets" {
    try std.testing.expectError(
        error.McpConfigAuthorizationHeader,
        loadConfigFromJson(std.testing.allocator,
            \\{"mcp":{"unsafe":{"type":"http","url":"https://api.example.com/mcp","headers":{"Authorization":"Bearer secret-value"}}}}
        ),
    );
}

test "loadConfigFromJson rejects a mixed set containing insecure HTTP endpoints" {
    const json =
        \\{"mcp":{"insecure":{"type":"http","url":"http://example.com/mcp"},"reserved":{"type":"http","url":"https://api.example.com/mcp","headers":{"Mcp-Method":"override"}},"valid":{"type":"http","url":"http://localhost:4321/mcp"}}}
    ;
    try std.testing.expectError(
        error.McpConfigInvalidUrl,
        loadConfigFromJson(std.testing.allocator, json),
    );
}

test "loadConfigFromJson reports sse config without url" {
    const json =
        \\{"mcp":{"broken":{"type":"sse"}}}
    ;
    try std.testing.expectError(
        error.McpConfigMissingUrl,
        loadConfigFromJson(std.testing.allocator, json),
    );
}

test "loadConfigFromJson parses mixed stdio and sse configs" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"local":{"type":"local","command":["node","server.js"]},"remote":{"type":"sse","url":"https://mcp.example.com"}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 2), configs.items.len);
    try std.testing.expectEqual(McpTransport.stdio, configs.items[0].transport);
    try std.testing.expectEqualStrings("local", configs.items[0].name);
    try std.testing.expectEqual(McpTransport.sse, configs.items[1].transport);
    try std.testing.expectEqualStrings("remote", configs.items[1].name);
}

test "save and reload preserves mixed stdio and sse configs" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmpRoot(alloc, tmp);
    defer alloc.free(root);
    const path = try tmpPath(alloc, root, "mcp.json");
    defer alloc.free(path);

    var configs = try loadConfigFromJson(alloc,
        \\{"mcp":{"local":{"type":"local","command":["node","server.js"],"enabled":false},"remote":{"type":"sse","url":"https://mcp.example.com","enabled":true}}}
    );
    defer freeConfigs(alloc, &configs);

    try saveConfigsToPath(alloc, path, configs.items);

    var reloaded = try loadConfigFromPath(alloc, path);
    defer freeConfigs(alloc, &reloaded);

    try std.testing.expectEqual(@as(usize, 2), reloaded.items.len);
    try std.testing.expectEqual(McpTransport.stdio, reloaded.items[0].transport);
    try std.testing.expectEqualStrings("node", try reloaded.items[0].stdioCommand());
    try std.testing.expect(!reloaded.items[0].enabled);
    try std.testing.expectEqual(McpTransport.sse, reloaded.items[1].transport);
    try std.testing.expectEqualStrings("https://mcp.example.com", try reloaded.items[1].remoteUrl());
}

test "save and reload preserves HTTP identity and headers" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmpRoot(alloc, tmp);
    defer alloc.free(root);
    const path = try tmpPath(alloc, root, "mcp.json");
    defer alloc.free(path);

    var configs = try loadConfigFromJson(alloc,
        \\{"mcp":{"local":{"type":"local","command":["node"]},"remote":{"type":"http","url":"https://api.example.com/mcp","headers":{"X-Workspace":"one"}}}}
    );
    defer freeConfigs(alloc, &configs);

    try saveConfigsToPath(alloc, path, configs.items);

    const rendered = try readFileForTest(alloc, path);
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "\"type\":\"http\"") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "\"type\":\"sse\"") == null);
    try std.testing.expect(std.mem.find(u8, rendered, "\"X-Workspace\":\"one\"") != null);

    var reloaded = try loadConfigFromPath(alloc, path);
    defer freeConfigs(alloc, &reloaded);
    try std.testing.expectEqual(@as(usize, 2), reloaded.items.len);
    try std.testing.expectEqual(McpTransport.http, reloaded.items[1].transport);
    try std.testing.expectEqualStrings("https://api.example.com/mcp", try reloaded.items[1].remoteUrl());
    try std.testing.expectEqualStrings("X-Workspace", reloaded.items[1].headers[0].name);
    try std.testing.expectEqualStrings("one", reloaded.items[1].headers[0].value);
}

test "loadConfigFromJson parses env alias when environment is absent" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"server":{"type":"local","command":["node"],"env":{"TOKEN":"alias"}}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqual(@as(usize, 1), configs.items[0].env.len);
    try std.testing.expectEqualStrings("TOKEN", configs.items[0].env[0].key);
    try std.testing.expectEqualStrings("alias", configs.items[0].env[0].value);
}

test "loadConfigFromJson prefers environment over env alias" {
    const alloc = std.testing.allocator;
    const json =
        \\{"mcp":{"server":{"type":"local","command":["node"],"environment":{"TOKEN":"primary"},"env":{"TOKEN":"alias"}}}}
    ;
    var configs = try loadConfigFromJson(alloc, json);
    defer freeConfigs(alloc, &configs);

    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqual(@as(usize, 1), configs.items[0].env.len);
    try std.testing.expectEqualStrings("primary", configs.items[0].env[0].value);
}

test "loadConfigFromJson reports non-string environment values" {
    const json =
        \\{"mcp":{"server":{"type":"local","command":["node"],"environment":{"TOKEN":123}}}}
    ;
    try std.testing.expectError(
        error.McpConfigInvalidEnvironment,
        loadConfigFromJson(std.testing.allocator, json),
    );
}

test "stdio lifecycle policy parses defaults and roundtrips explicit values" {
    const alloc = std.testing.allocator;
    var defaults = try loadConfigFromJson(
        alloc,
        "{\"mcp\":{\"default\":{\"type\":\"local\",\"command\":[\"node\"]}}}",
    );
    defer freeConfigs(alloc, &defaults);
    try std.testing.expectEqual(
        mcp_contract.default_startup_timeout_ms,
        defaults.items[0].startup_timeout_ms,
    );
    try std.testing.expectEqual(
        mcp_contract.default_operation_timeout_ms,
        defaults.items[0].operation_timeout_ms,
    );
    try std.testing.expectEqual(
        mcp_contract.default_restart_limit,
        defaults.items[0].restart_limit,
    );

    var explicit = try loadConfigFromJson(
        alloc,
        "{\"mcp\":{\"bounded\":{\"type\":\"stdio\",\"command\":[\"node\"],\"startupTimeoutMs\":125,\"toolTimeoutMs\":250,\"restart_limit\":2}}}",
    );
    defer freeConfigs(alloc, &explicit);
    try std.testing.expectEqual(@as(u32, 125), explicit.items[0].startup_timeout_ms);
    try std.testing.expectEqual(@as(u32, 250), explicit.items[0].operation_timeout_ms);
    try std.testing.expectEqual(@as(u8, 2), explicit.items[0].restart_limit);

    const rendered = try renderConfigJson(alloc, explicit.items);
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "\"startupTimeoutMs\":125") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "\"toolTimeoutMs\":250") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "\"restart_limit\":2") != null);
}

test "invalid stdio lifecycle policy reports its field" {
    for ([_]struct { json: []const u8, expected: anyerror }{
        .{ .json = "{\"mcp\":{\"bad\":{\"type\":\"local\",\"command\":[\"node\"],\"startupTimeoutMs\":0}}}", .expected = error.McpConfigInvalidStartupTimeout },
        .{ .json = "{\"mcp\":{\"bad\":{\"type\":\"local\",\"command\":[\"node\"],\"toolTimeoutMs\":\"slow\"}}}", .expected = error.McpConfigInvalidOperationTimeout },
        .{ .json = "{\"mcp\":{\"bad\":{\"type\":\"local\",\"command\":[\"node\"],\"restart_limit\":256}}}", .expected = error.McpConfigInvalidRestartLimit },
    }) |case| {
        try std.testing.expectError(
            case.expected,
            loadConfigFromJson(std.testing.allocator, case.json),
        );
    }
}

test "freeConfigs accepts an empty ArrayList" {
    const alloc = std.testing.allocator;
    var configs: std.ArrayList(McpServerConfig) = .empty;
    freeConfigs(alloc, &configs);
}
