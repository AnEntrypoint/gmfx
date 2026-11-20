const std = @import("std");
const profile_paths = @import("../shared/profile_paths.zig");
const auth_runtime = @import("../auth/auth_runtime.zig");
const builtin_context = @import("../../builtins/context.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const agent_steps = @import("../config/agent_steps.zig");
const config_runtime = @import("../config/config_runtime.zig");
const settings_keys = @import("../config/settings_keys.zig");
const settings_messages = @import("settings_messages.zig");
const host = @import("../hosts/host.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const mcp_health = @import("../mcp/health.zig");
const session_adapter = @import("../session/session_adapter.zig");
const types = @import("../shared/types.zig");
const model_provider = @import("../config/model_provider.zig");

const Allocator = std.mem.Allocator;
const default_session_diagnostics_limit: usize = 64;
const instruction_file_names = builtin_context.agents_md_file_names;
const instruction_file_warn_bytes: usize = builtin_context.project_instruction_size_guide_bytes;
const instruction_file_read_limit_bytes: usize = 64 * 1024 * 1024;
const instruction_missing_paths_shown: usize = 20;
const instruction_path_rejected_bytes = " \t*?<>{}$|()=\"'";
const instruction_path_trailing_punctuation = ".,;:";

pub const CheckStatus = enum {
    ok,
    warn,
    fail,
};

pub const Check = struct {
    name: []const u8,
    status: CheckStatus,
    detail: []const u8,
    owned_detail: ?[]u8 = null,

    pub fn deinit(self: *Check, alloc: Allocator) void {
        if (self.owned_detail) |detail| alloc.free(detail);
        self.* = undefined;
    }
};

pub const Snapshot = struct {
    workspace_root: []u8,
    model: []const u8,
    provider: model_provider.ProviderId = .gateway,
    owned_model: ?[]u8 = null,
    auth: auth_runtime.StatusSnapshot = .{},
    permission_mode: types.PermissionMode,
    agent_step_limit: usize,
    checks: []Check,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        alloc.free(self.workspace_root);
        if (self.owned_model) |model| alloc.free(model);
        self.auth.deinit(alloc);
        for (self.checks) |*entry| entry.deinit(alloc);
        alloc.free(self.checks);
        self.* = undefined;
    }
};

pub fn collect(
    alloc: Allocator,
    secret_store: host.SecretStore,
    default_model: []const u8,
    default_agent_step_limit: usize,
    mcp_config_diagnostic: mcp_contract.ProfileConfigDiagnostic,
    mcp_servers: []const mcp_health.ConfiguredServerSnapshot,
) !Snapshot {
    const workspace_root = try io_mod.realpathAlloc(alloc, ".");
    debug_trace.configureFromEnv(alloc, workspace_root);

    var checks: std.ArrayList(Check) = .empty;
    errdefer {
        for (checks.items) |*entry| entry.deinit(alloc);
        checks.deinit(alloc);
    }

    var snapshot = Snapshot{
        .workspace_root = workspace_root,
        .model = default_model,
        .permission_mode = config_runtime.default_permission_mode,
        .agent_step_limit = default_agent_step_limit,
        .checks = &.{},
    };
    errdefer {
        alloc.free(snapshot.workspace_root);
        if (snapshot.owned_model) |model| alloc.free(model);
        snapshot.auth.deinit(alloc);
    }

    const workspace_detail = try alloc.print("using workspace {s}", .{snapshot.workspace_root});
    try appendCheckOwned(&checks, alloc, "workspace", .ok, workspace_detail);

    const paths = try config_runtime.discoverPaths(alloc, snapshot.workspace_root);
    defer {
        var mutable_paths = paths;
        mutable_paths.deinit(alloc);
    }

    var detailed = config_runtime.loadMergedSettingsDetailed(alloc, snapshot.workspace_root) catch |err| {
        snapshot.auth = try auth_runtime.loadStatusSnapshot(alloc, secret_store, null);
        try appendConfigLoadFailureCheck(&checks, alloc, "config", "failed to load config", err);
        try appendMcpConfigCheck(&checks, alloc, mcp_config_diagnostic);
        try appendUnusedExtensionCheck(&checks, alloc, mcp_servers);
        try appendAuthCheck(&checks, alloc, snapshot.auth);
        try appendConfigLoadFailureCheck(&checks, alloc, "startup", "failed to resolve startup settings", err);
        try appendStateChecks(&checks, alloc);
        try appendGitCheck(&checks, alloc, snapshot.workspace_root);
        try appendInstructionFileChecks(&checks, alloc, snapshot.workspace_root);
        try appendGhCheck(&checks, alloc);

        snapshot.checks = try checks.toOwnedSlice(alloc);
        return snapshot;
    };
    defer detailed.deinit(alloc);
    snapshot.provider = detailed.settings.provider orelse .gateway;

    snapshot.auth = try auth_runtime.loadStatusSnapshotForProvider(
        alloc,
        secret_store,
        snapshot.provider,
        detailed.settings.credential_source,
    );

    try appendConfigCheck(&checks, alloc, paths, detailed.diagnostics);
    try appendConfigDiagnosticChecks(&checks, alloc, detailed.diagnostics);
    try appendUnknownSettingChecks(&checks, alloc, paths);
    try appendMcpConfigCheck(&checks, alloc, mcp_config_diagnostic);
    try appendUnusedExtensionCheck(&checks, alloc, mcp_servers);
    try appendAuthCheck(&checks, alloc, snapshot.auth);
    const selection = config_runtime.selectProviderModel(
        default_model,
        &detailed.settings,
        null,
        config_runtime.modelEnvOverride(),
    );
    try appendResolvedStartupCheck(&snapshot, &checks, alloc, selection, .{
        .permission_mode = detailed.settings.permission_mode,
        .max_agent_steps = detailed.settings.max_agent_steps,
    }, default_agent_step_limit);
    try appendStateChecks(&checks, alloc);
    try appendGitCheck(&checks, alloc, snapshot.workspace_root);
    try appendInstructionFileChecks(&checks, alloc, snapshot.workspace_root);
    try appendGhCheck(&checks, alloc);

    snapshot.checks = try checks.toOwnedSlice(alloc);
    return snapshot;
}

fn appendConfigDiagnosticChecks(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    diagnostics: []const config_runtime.ConfigDiagnostic,
) !void {
    for (diagnostics) |diagnostic| {
        var detail_writer: std.Io.Writer.Allocating = .init(alloc);
        defer detail_writer.deinit();
        try detail_writer.writer.print(
            "{s} config diagnostic: {s}",
            .{ @tagName(diagnostic.layer), @tagName(diagnostic.cause) },
        );
        try config_runtime.writeDiagnosticMetadata(&detail_writer.writer, diagnostic);
        const detail = try detail_writer.toOwnedSlice();
        try appendCheckOwned(checks, alloc, "config", .warn, detail);
    }
}

fn appendUnknownSettingChecks(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    paths: config_runtime.Paths,
) !void {
    if (paths.user_settings) |path| try appendUnknownSettingChecksFor(checks, alloc, path, profile_paths.displayText("~/.fx/settings.json"), .profile);
    try appendUnknownSettingChecksFor(checks, alloc, paths.workspace_settings, ".fx.json", .project);
}

fn appendUnknownSettingChecksFor(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    path: []const u8,
    display_path: []const u8,
    file: settings_keys.File,
) !void {
    const loaded = config_runtime.readSettingsFileJson(alloc, path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    var parsed = loaded orelse return;
    defer parsed.deinit();
    const unknown = try settings_keys.findUnknown(alloc, parsed.value, file);
    defer alloc.free(unknown);
    for (unknown) |key| {
        try appendCheckOwned(checks, alloc, "config", .warn, try settings_messages.formatUnknownSetting(alloc, key, display_path));
    }
    const older = try settings_keys.findOlderNames(alloc, parsed.value, file);
    defer alloc.free(older);
    for (older) |entry| {
        try appendCheckOwned(checks, alloc, "config", .warn, try settings_messages.formatOlderName(alloc, entry, display_path));
    }
}

fn appendConfigCheck(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    paths: config_runtime.Paths,
    diagnostics: []const config_runtime.ConfigDiagnostic,
) !void {
    const user_exists = if (paths.user_settings) |path|
        try fileExists(path) and !configLayerRejected(diagnostics, .user)
    else
        false;
    const repo_exists = try fileExists(paths.workspace_settings) and
        !configLayerRejected(diagnostics, .project);

    if (!user_exists and !repo_exists) {
        try appendCheck(checks, alloc, "config", .warn, "no config files found; using defaults and env overrides");
        return;
    }

    const detail = try formatConfigPresence(alloc, user_exists, repo_exists);
    try appendCheckOwned(checks, alloc, "config", .ok, detail);
}

fn configLayerRejected(
    diagnostics: []const config_runtime.ConfigDiagnostic,
    layer: config_runtime.ConfigLayer,
) bool {
    for (diagnostics) |diagnostic| {
        if (diagnostic.layer != layer) continue;
        switch (diagnostic.cause) {
            .malformed_settings,
            .settings_too_large,
            .durable_path_unsafe,
            .private_state_permissions_unsupported,
            .invalid_model_id,
            .retired_skill_match_fuzzy,
            .invalid_context_limits,
            .invalid_ultrafast_mode_override,
            .invalid_skill_symlink_authorities,
            => return true,
            .invalid_additional_directories,
            .ignored_project_user_only_setting,
            .legacy_workspace_preferences,
            .manual_backup_available,
            .private_state_permissions_tightened,
            => {},
        }
    }
    return false;
}

fn appendAuthCheck(checks: *std.ArrayList(Check), alloc: Allocator, auth: auth_runtime.StatusSnapshot) !void {
    if (auth.missingHelp(.cli)) |help| {
        try appendCheck(checks, alloc, "auth", .fail, help);
        return;
    }

    const detail = try auth.formatDoctorDetail(alloc);
    try appendCheckOwned(checks, alloc, "auth", if (auth.expired) .warn else .ok, detail);
}

fn appendResolvedStartupCheck(
    snapshot: *Snapshot,
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    selection: config_runtime.ModelSelectionError!model_provider.ProviderSelection,
    settings: config_runtime.StartupStatusSettings,
    default_agent_step_limit: usize,
) !void {
    snapshot.permission_mode = try resolvePermissionMode(settings.permission_mode);
    snapshot.agent_step_limit = try resolveAgentStepLimit(default_agent_step_limit, settings.max_agent_steps);
    if (snapshot.owned_model) |model| alloc.free(model);
    snapshot.owned_model = null;
    const selected = selection catch |err| {
        snapshot.model = "";
        try appendCheck(checks, alloc, "startup", .fail, config_runtime.modelNotSelectedMessage(err) orelse @errorName(err));
        return;
    };
    const model = try alloc.dupe(u8, config_runtime.modelEnvOverride() orelse selected.model);
    snapshot.model = model;
    snapshot.owned_model = model;

    const detail = try alloc.print(
        "resolved model={s}, permission_mode={s}, agent_step_limit={d}",
        .{ snapshot.model, permissionModeLabel(snapshot.permission_mode), snapshot.agent_step_limit },
    );
    try appendCheckOwned(checks, alloc, "startup", .ok, detail);
}

fn appendConfigLoadFailureCheck(checks: *std.ArrayList(Check), alloc: Allocator, name: []const u8, prefix: []const u8, err: anyerror) !void {
    const detail = try formatConfigLoadFailure(alloc, prefix, err);
    try appendCheckOwned(checks, alloc, name, .fail, detail);
}

fn formatConfigLoadFailure(alloc: Allocator, prefix: []const u8, err: anyerror) ![]u8 {
    return alloc.print("{s}: {s}", .{ prefix, @errorName(err) });
}

fn appendStateChecks(checks: *std.ArrayList(Check), alloc: Allocator) !void {
    var store = session_adapter.Store.openFromEnv(alloc) catch |err| {
        const status: CheckStatus = if (err == error.HomeNotSet) .warn else .fail;
        const detail = try alloc.print("failed to inspect sessions: {s}", .{@errorName(err)});
        try appendCheckOwned(checks, alloc, "state", status, detail);
        return;
    };
    defer store.deinit(alloc);
    var report = session_adapter.doctor(&store, alloc, default_session_diagnostics_limit, io_mod.milliTimestamp()) catch |err| {
        const detail = try alloc.print("failed to inspect sessions: {s}", .{@errorName(err)});
        try appendCheckOwned(checks, alloc, "state", .fail, detail);
        return;
    };
    defer report.deinit(alloc);
    try appendCheck(checks, alloc, "state", .ok, "sessions ready");
    for (report.damaged.items) |id| {
        const detail = try alloc.print("session {s} has a damaged log; `fx session recover {s}` copies its good turns", .{ id, id });
        try appendCheckOwned(checks, alloc, "session", .warn, detail);
    }
    for (report.stuck.items) |stuck| try appendStuckCheck(checks, alloc, stuck);
    for (report.kept_children) |kept| {
        const detail = try alloc.print("session {s}, a subagent an older fx saved, is kept as it is: {s}", .{ kept.id, kept.reason });
        try appendCheckOwned(checks, alloc, "session", .ok, detail);
    }

    if (report.checked < report.sessions + report.unconverted) try appendSessionDiagnosticsTruncatedCheck(checks, alloc, report.checked);
    if (report.removed > 0) {
        const detail = try alloc.print("removed {d} terminal or side folder(s) whose session is gone", .{report.removed});
        try appendCheckOwned(checks, alloc, "session", .ok, detail);
    }
    if (report.kept > 0) {
        const detail = try alloc.print("{d} terminal or side folder(s) whose session is gone could not be removed", .{report.kept});
        try appendCheckOwned(checks, alloc, "session", .warn, detail);
    }
    if (report.keeps_left_out > 0) {
        const detail = try alloc.print("{d} earlier session folder(s) under ~/.fx/sessions keep files their conversion left out", .{report.keeps_left_out});
        try appendCheckOwned(checks, alloc, "sessions", .ok, detail);
    }
    const convertible = report.unconverted - report.stuck.items.len;
    if (convertible > 0) {
        const detail = try alloc.print("{d} session(s) saved by an older fx will be converted when first opened", .{convertible});
        try appendCheckOwned(checks, alloc, "sessions", .ok, detail);
    }
    try appendSessionsCountCheck(checks, alloc, report.sessions, report.latest orelse "", report.unconverted > 0);
}

fn appendStuckCheck(checks: *std.ArrayList(Check), alloc: Allocator, stuck: session_adapter.Doctor.Stuck) !void {
    const detail = switch (stuck.recover) {
        .without_rules => try alloc.print(
            "session {s} saved by an older fx can't be converted: {s}; `fx session recover {s}` copies its conversation without its saved permission rules",
            .{ stuck.id, stuck.reason, stuck.id },
        ),
        .good_turns => try alloc.print(
            "session {s} saved by an older fx can't be converted: {s}; `fx session recover {s}` copies its good turns",
            .{ stuck.id, stuck.reason, stuck.id },
        ),
        .nothing => try alloc.print(
            "session {s} saved by an older fx can't be converted: {s}; nothing in it can be copied, so it is kept as it is",
            .{ stuck.id, stuck.reason },
        ),
    };
    try appendCheckOwned(checks, alloc, "session", .warn, detail);
}

fn appendSessionDiagnosticsTruncatedCheck(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    inspected_count: usize,
) !void {
    const detail = try alloc.print(
        "session diagnostics truncated after {d} session director{s} to keep doctor bounded",
        .{ inspected_count, if (inspected_count == 1) "y" else "ies" },
    );
    try appendCheckOwned(checks, alloc, "session", .warn, detail);
}

fn appendSessionsCountCheck(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    count: usize,
    latest_id: []const u8,
    older_saved: bool,
) !void {
    if (count == 0) {
        if (!older_saved) try appendCheck(checks, alloc, "sessions", .warn, "no saved sessions yet");
        return;
    }

    const detail = try alloc.print("{d} saved session(s); latest={s}", .{ count, latest_id });
    try appendCheckOwned(checks, alloc, "sessions", .ok, detail);
}

fn appendGitCheck(checks: *std.ArrayList(Check), alloc: Allocator, workspace_root: []const u8) !void {
    if (try hasGitMetadata(alloc, workspace_root)) {
        try appendCheck(checks, alloc, "git", .ok, "git metadata detected for this workspace");
        return;
    }
    try appendCheck(checks, alloc, "git", .warn, "not a git repository; pr/issue workflows will be limited");
}

fn appendGhCheck(checks: *std.ArrayList(Check), alloc: Allocator) !void {
    if (try commandInPath(alloc, "gh")) {
        try appendCheck(checks, alloc, "gh", .ok, "GitHub CLI found in PATH");
        return;
    }
    try appendCheck(checks, alloc, "gh", .warn, "GitHub CLI not found in PATH; publish workflows unavailable");
}

fn appendInstructionFileChecks(checks: *std.ArrayList(Check), alloc: Allocator, workspace_root: []const u8) !void {
    for (instruction_file_names) |file_name| {
        const path = try std.Io.Dir.path.join(alloc, &.{ workspace_root, file_name });
        defer alloc.free(path);
        const text = std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), path, alloc, .limited(instruction_file_read_limit_bytes)) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const detail = try alloc.print("could not read {s}: {s}", .{ file_name, @errorName(err) });
                try appendCheckOwned(checks, alloc, "instructions", .warn, detail);
                return;
            },
        };
        defer alloc.free(text);
        try appendInstructionSizeCheck(checks, alloc, file_name, text.len);
        try appendInstructionPathsCheck(checks, alloc, workspace_root, file_name, text);
        return;
    }
}

fn appendInstructionSizeCheck(checks: *std.ArrayList(Check), alloc: Allocator, file_name: []const u8, size: usize) !void {
    if (size > instruction_file_warn_bytes) {
        const detail = try alloc.print(
            "{s} is {d} bytes, above the {d}-byte guide; move detail into scoped files or docs so the whole file stays in context",
            .{ file_name, size, instruction_file_warn_bytes },
        );
        try appendCheckOwned(checks, alloc, "instructions", .warn, detail);
        return;
    }
    const detail = try alloc.print("{s} is {d} bytes", .{ file_name, size });
    try appendCheckOwned(checks, alloc, "instructions", .ok, detail);
}

fn appendInstructionPathsCheck(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    workspace_root: []const u8,
    file_name: []const u8,
    text: []const u8,
) !void {
    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(alloc);
    try collectMissingInstructionPaths(alloc, workspace_root, text, &missing);
    if (missing.items.len == 0) {
        const detail = try alloc.print("every backticked repository path in {s} exists", .{file_name});
        try appendCheckOwned(checks, alloc, "instructions", .ok, detail);
        return;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{s} names {d} path{s} that do{s} not exist: ", .{
        file_name,
        missing.items.len,
        if (missing.items.len == 1) "" else "s",
        if (missing.items.len == 1) "es" else "",
    });
    const shown = @min(missing.items.len, instruction_missing_paths_shown);
    for (missing.items[0..shown], 0..) |path, index| {
        if (index > 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(path);
    }
    if (missing.items.len > shown) try out.writer.print(" (+{d} more)", .{missing.items.len - shown});
    try appendCheckOwned(checks, alloc, "instructions", .warn, try out.toOwnedSlice());
}

fn collectMissingInstructionPaths(
    alloc: Allocator,
    workspace_root: []const u8,
    text: []const u8,
    missing: *std.ArrayList([]const u8),
) !void {
    var fenced = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const indented = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, indented, "```") or std.mem.startsWith(u8, indented, "~~~")) {
            fenced = !fenced;
            continue;
        }
        if (fenced) continue;
        var spans = std.mem.splitScalar(u8, line, '`');
        var inside_span = false;
        while (spans.next()) |span| : (inside_span = !inside_span) {
            if (!inside_span) continue;
            const candidate = instructionRepoPath(span) orelse continue;
            if (containsPath(missing.items, candidate)) continue;
            if (!try instructionPathIsMissing(alloc, workspace_root, candidate)) continue;
            try missing.append(alloc, candidate);
        }
    }
}

fn instructionRepoPath(span: []const u8) ?[]const u8 {
    var path = std.mem.trimEnd(u8, span, instruction_path_trailing_punctuation);
    path = std.mem.trimEnd(u8, stripLineSuffix(path), instruction_path_trailing_punctuation);
    if (std.mem.startsWith(u8, path, "./")) path = path[2..];
    if (path.len == 0) return null;
    if (std.mem.findAny(u8, path, instruction_path_rejected_bytes) != null) return null;
    if (std.mem.find(u8, path, "://") != null) return null;
    if (std.mem.findScalar(u8, path, '/') == null) return null;
    if (path[0] == '/' or path[0] == '~' or path[0] == '-') return null;
    if (std.mem.findNone(u8, path, "./") == null) return null;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return null;
    }
    return path;
}

fn stripLineSuffix(path: []const u8) []const u8 {
    var rest = path;
    while (std.mem.findScalarLast(u8, rest, ':')) |colon| {
        const suffix = rest[colon + 1 ..];
        if (suffix.len == 0 or !std.ascii.isDigit(suffix[0])) break;
        if (std.mem.findNone(u8, suffix, "0123456789-") != null) break;
        rest = rest[0..colon];
    }
    return rest;
}

fn instructionPathIsMissing(alloc: Allocator, workspace_root: []const u8, path: []const u8) !bool {
    const first_slash = std.mem.findScalar(u8, path, '/') orelse return false;
    const top_level = try std.Io.Dir.path.join(alloc, &.{ workspace_root, path[0..first_slash] });
    defer alloc.free(top_level);
    if (!pathExists(top_level)) return false;
    const full = try std.Io.Dir.path.join(alloc, &.{ workspace_root, std.mem.trimEnd(u8, path, "/") });
    defer alloc.free(full);
    return !pathExists(full);
}

fn containsPath(paths: []const []const u8, needle: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, needle)) return true;
    }
    return false;
}

fn resolvePermissionMode(configured: ?types.PermissionMode) !types.PermissionMode {
    const fallback = configured orelse config_runtime.default_permission_mode;
    const raw = io_mod.getenv("FX_PERMISSION_MODE") orelse return fallback;
    return config_runtime.parsePermissionMode(raw) orelse fallback;
}

fn resolveAgentStepLimit(fallback: usize, configured: ?usize) !usize {
    return agent_steps.resolveMaxAgentStepsWithOverride(
        configured,
        fallback,
        io_mod.getenv("FX_MAX_AGENT_STEPS"),
    );
}

fn appendCheck(checks: *std.ArrayList(Check), alloc: Allocator, name: []const u8, status: CheckStatus, detail: []const u8) !void {
    try checks.append(alloc, .{
        .name = name,
        .status = status,
        .detail = detail,
    });
}

fn appendCheckOwned(checks: *std.ArrayList(Check), alloc: Allocator, name: []const u8, status: CheckStatus, detail: []u8) !void {
    errdefer alloc.free(detail);
    try checks.append(alloc, .{
        .name = name,
        .status = status,
        .detail = detail,
        .owned_detail = detail,
    });
}

fn appendMcpConfigCheck(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    diagnostic: mcp_contract.ProfileConfigDiagnostic,
) !void {
    switch (diagnostic) {
        .clear => return,
        .warning => |warning| {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            try out.writer.print(
                "{s}/mcp.json warning: {s}",
                .{ profile_paths.displayRoot(), @tagName(warning.cause) },
            );
            if (warning.key()) |key| try out.writer.print(" key={s}", .{key});
            try out.writer.print(
                " additional_matches={d}",
                .{warning.additional_matches},
            );
            try appendCheckOwned(
                checks,
                alloc,
                "mcp_config",
                .warn,
                try out.toOwnedSlice(),
            );
            return;
        },
        .failed => |err| {
            const detail = try alloc.print(
                "failed to load {s}/mcp.json: {s}",
                .{ profile_paths.displayRoot(), @errorName(err) },
            );
            try appendCheckOwned(checks, alloc, "mcp_config", .fail, detail);
            return;
        },
    }
}

fn appendUnusedExtensionCheck(
    checks: *std.ArrayList(Check),
    alloc: Allocator,
    servers: []const mcp_health.ConfiguredServerSnapshot,
) !void {
    var unused_count: usize = 0;
    for (servers) |server| {
        if (unusedReason(server) != null) unused_count += 1;
    }
    if (unused_count == 0) return;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{d} configured MCP server(s) not in use: ", .{unused_count});
    var first = true;
    for (servers) |server| {
        const reason = unusedReason(server) orelse continue;
        if (!first) try out.writer.writeAll(", ");
        first = false;
        try out.writer.print("{s} ({s})", .{ server.configured_name, reason });
    }
    try out.writer.writeAll(
        "; fix: set \"enabled\": true in the MCP config for a disabled server, or run fx mcp approve <name> for a workspace server awaiting approval",
    );
    try appendCheckOwned(checks, alloc, "extensions", .warn, try out.toOwnedSlice());
}

fn unusedReason(server: mcp_health.ConfiguredServerSnapshot) ?[]const u8 {
    if (!server.enabled) return "disabled";
    if (server.workspace_admission == .pending) return "awaiting approval";
    return null;
}

fn formatConfigPresence(alloc: Allocator, user_exists: bool, repo_exists: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("loaded config from ");
    var first = true;
    if (user_exists) {
        if (!first) try out.writer.writeAll(", ");
        first = false;
        try out.writer.writeAll(profile_paths.displayText("~/.fx/settings.json"));
    }
    if (repo_exists) {
        if (!first) try out.writer.writeAll(", ");
        try out.writer.writeAll(".fx.json");
    }
    return try out.toOwnedSlice();
}

fn fileExists(path: []const u8) !bool {
    if (comptime @import("builtin").target.os.tag != .windows) {
        return accessPath(path);
    }
    std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn hasGitMetadata(alloc: Allocator, workspace_root: []const u8) !bool {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const git_path = std.mem.print(&path_buf, "{s}" ++ std.Io.Dir.path.sep_str ++ ".git", .{workspace_root}) catch {
        const owned = try std.Io.Dir.path.join(alloc, &.{ workspace_root, ".git" });
        defer alloc.free(owned);
        return try fileExists(owned);
    };
    return try fileExists(git_path);
}

fn commandInPath(alloc: Allocator, command_name: []const u8) !bool {
    const path_env = io_mod.getenv("PATH") orelse return false;

    return commandInPathValue(alloc, command_name, path_env);
}

fn commandInPathValue(alloc: Allocator, command_name: []const u8, path_env: []const u8) !bool {
    var it = std.mem.splitScalar(u8, path_env, std.Io.Dir.path.delimiter);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;

        var candidate_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const candidate = std.mem.print(&candidate_buf, "{s}" ++ std.Io.Dir.path.sep_str ++ "{s}", .{ entry, command_name }) catch {
            const owned = try std.Io.Dir.path.join(alloc, &.{ entry, command_name });
            defer alloc.free(owned);
            if (pathExists(owned)) return true;
            continue;
        };

        if (pathExists(candidate)) {
            return true;
        }
    }

    return false;
}

fn pathExists(path: []const u8) bool {
    if (comptime @import("builtin").target.os.tag != .windows) {
        return accessPath(path) catch false;
    }

    if (std.Io.Dir.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch return false;
        return true;
    }

    std.Io.Dir.cwd().access(io_mod.getIo(), path, .{}) catch return false;
    return true;
}

fn accessPath(path: []const u8) !bool {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_z = std.mem.printSentinel(&path_buf, "{s}", .{path}, 0) catch return false;
    const rc = std.c.access(path_z.ptr, std.c.F_OK);
    if (rc == 0) return true;
    return switch (std.posix.errno(rc)) {
        .NOENT, .NOTDIR => false,
        .ACCES => false,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

fn permissionModeLabel(mode: types.PermissionMode) []const u8 {
    return switch (mode) {
        .ask => "ask",
        .auto => "auto",
        .yolo => "full access",
        .dontAsk => "dontAsk",
    };
}

test "format config presence names existing layers" {
    const detail = try formatConfigPresence(std.testing.allocator, true, false);
    defer std.testing.allocator.free(detail);

    try std.testing.expectEqualStrings("loaded config from ~/.fx/settings.json", detail);
}

test "MCP config diagnostic maps only failures to one doctor check" {
    const alloc = std.testing.allocator;
    var checks: std.ArrayList(Check) = .empty;
    defer {
        for (checks.items) |*entry| entry.deinit(alloc);
        checks.deinit(alloc);
    }

    try appendMcpConfigCheck(&checks, alloc, .clear);
    try std.testing.expectEqual(@as(usize, 0), checks.items.len);

    try appendMcpConfigCheck(
        &checks,
        alloc,
        .{ .failed = error.McpConfigInvalidJson },
    );
    try std.testing.expectEqual(@as(usize, 1), checks.items.len);
    try std.testing.expectEqualStrings("mcp_config", checks.items[0].name);
    try std.testing.expectEqual(CheckStatus.fail, checks.items[0].status);
    try std.testing.expectEqualStrings(
        "failed to load ~/.fx/mcp.json: McpConfigInvalidJson",
        checks.items[0].detail,
    );
}

test "config check handles user and workspace config files together" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try writeDoctorFixtureFile(tmp.dir, "home/.fx/settings.json", "{\"permission_mode\":\"ask\"}");
    try writeDoctorFixtureFile(tmp.dir, "workspace/.fx.json", "{\"permission_mode\":\"auto\"}");

    const home_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "home");
    defer std.testing.allocator.free(home_root);
    const workspace_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "workspace");
    defer std.testing.allocator.free(workspace_root);

    var paths = try config_runtime.discoverPathsFromHome(std.testing.allocator, home_root, workspace_root);
    defer paths.deinit(std.testing.allocator);

    var checks: std.ArrayList(Check) = .empty;
    defer {
        for (checks.items) |*entry| entry.deinit(std.testing.allocator);
        checks.deinit(std.testing.allocator);
    }

    try appendConfigCheck(&checks, std.testing.allocator, paths, &.{});

    try std.testing.expectEqual(@as(usize, 1), checks.items.len);
    try std.testing.expectEqual(CheckStatus.ok, checks.items[0].status);
    try std.testing.expect(std.mem.find(u8, checks.items[0].detail, "~/.fx/settings.json") != null);
    try std.testing.expect(std.mem.find(u8, checks.items[0].detail, ".fx.json") != null);
}

test "config check does not claim rejected user settings loaded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try writeDoctorFixtureFile(tmp.dir, "home/.fx/settings.json", "{\"permission_mode\":\"ask\"}");
    try writeDoctorFixtureFile(tmp.dir, "workspace/.fx.json", "{\"permission_mode\":\"auto\"}");

    const home_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "home");
    defer std.testing.allocator.free(home_root);
    const workspace_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "workspace");
    defer std.testing.allocator.free(workspace_root);

    var paths = try config_runtime.discoverPathsFromHome(std.testing.allocator, home_root, workspace_root);
    defer paths.deinit(std.testing.allocator);

    var checks: std.ArrayList(Check) = .empty;
    defer {
        for (checks.items) |*entry| entry.deinit(std.testing.allocator);
        checks.deinit(std.testing.allocator);
    }

    const diagnostics = [_]config_runtime.ConfigDiagnostic{
        .{
            .layer = .user,
            .cause = .private_state_permissions_unsupported,
        },
    };
    try appendConfigCheck(&checks, std.testing.allocator, paths, &diagnostics);

    try std.testing.expectEqual(@as(usize, 1), checks.items.len);
    try std.testing.expectEqual(CheckStatus.ok, checks.items[0].status);
    try std.testing.expect(std.mem.find(u8, checks.items[0].detail, "~/.fx/settings.json") == null);
    try std.testing.expect(std.mem.find(u8, checks.items[0].detail, ".fx.json") != null);
}

test "session count check preserves empty and latest details" {
    const alloc = std.testing.allocator;
    var checks: std.ArrayList(Check) = .empty;
    defer {
        for (checks.items) |*entry| entry.deinit(alloc);
        checks.deinit(alloc);
    }

    try appendSessionsCountCheck(&checks, alloc, 0, "", false);
    try appendSessionsCountCheck(&checks, alloc, 2, "session-2", false);

    try appendSessionsCountCheck(&checks, alloc, 0, "", true);

    try std.testing.expectEqual(@as(usize, 2), checks.items.len);
    try std.testing.expectEqualStrings("sessions", checks.items[0].name);
    try std.testing.expectEqual(CheckStatus.warn, checks.items[0].status);
    try std.testing.expectEqualStrings("no saved sessions yet", checks.items[0].detail);
    try std.testing.expectEqualStrings("sessions", checks.items[1].name);
    try std.testing.expectEqual(CheckStatus.ok, checks.items[1].status);
    try std.testing.expectEqualStrings("2 saved session(s); latest=session-2", checks.items[1].detail);
}

test "doctor startup check fails when the provider has no model to run" {
    const alloc = std.testing.allocator;
    var checks: std.ArrayList(Check) = .empty;
    defer {
        for (checks.items) |*entry| entry.deinit(alloc);
        checks.deinit(alloc);
    }
    var snapshot = Snapshot{
        .workspace_root = "",
        .model = "default/model",
        .permission_mode = config_runtime.default_permission_mode,
        .agent_step_limit = 25,
        .checks = &.{},
    };

    try appendResolvedStartupCheck(&snapshot, &checks, alloc, error.CodexModelNotSelected, .{ .max_agent_steps = 7 }, 25);
    try std.testing.expectEqualStrings("", snapshot.model);
    try std.testing.expectEqual(@as(usize, 7), snapshot.agent_step_limit);
    try std.testing.expectEqual(CheckStatus.fail, checks.items[0].status);
    try std.testing.expect(std.mem.startsWith(u8, checks.items[0].detail, "no Codex model is selected;"));

    try appendResolvedStartupCheck(&snapshot, &checks, alloc, .{ .provider = .codex, .model = "gpt-saved" }, .{}, 25);
    defer if (snapshot.owned_model) |model| alloc.free(model);
    try std.testing.expectEqualStrings("gpt-saved", snapshot.model);
    try std.testing.expectEqual(CheckStatus.ok, checks.items[1].status);
}

test "doctor names configured MCP servers that are disabled or awaiting approval" {
    const alloc = std.testing.allocator;
    var servers = [_]mcp_health.ConfiguredServerSnapshot{
        .{ .configured_name = try alloc.dupe(u8, "ready"), .source = .profile, .scope = .profile, .required = false, .transport = .stdio },
        .{ .configured_name = try alloc.dupe(u8, "off"), .source = .profile, .scope = .profile, .required = false, .transport = .stdio, .enabled = false },
        .{ .configured_name = try alloc.dupe(u8, "team"), .source = .workspace, .scope = .workspace, .required = false, .transport = .http, .workspace_admission = .pending },
    };
    defer for (&servers) |*server| server.deinit(alloc);
    var checks: std.ArrayList(Check) = .empty;
    defer {
        for (checks.items) |*entry| entry.deinit(alloc);
        checks.deinit(alloc);
    }

    try appendUnusedExtensionCheck(&checks, alloc, &servers);

    try std.testing.expectEqual(@as(usize, 1), checks.items.len);
    try std.testing.expectEqualStrings("extensions", checks.items[0].name);
    try std.testing.expectEqual(CheckStatus.warn, checks.items[0].status);
    try std.testing.expect(std.mem.find(
        u8,
        checks.items[0].detail,
        "2 configured MCP server(s) not in use: off (disabled), team (awaiting approval); fix:",
    ) != null);
    try std.testing.expect(std.mem.find(u8, checks.items[0].detail, "fx mcp approve <name>") != null);
}

test "doctor adds no extensions check when every configured MCP server is in use" {
    const alloc = std.testing.allocator;
    var servers = [_]mcp_health.ConfiguredServerSnapshot{
        .{ .configured_name = try alloc.dupe(u8, "ready"), .source = .profile, .scope = .profile, .required = false, .transport = .stdio },
        .{ .configured_name = try alloc.dupe(u8, "approved"), .source = .workspace, .scope = .workspace, .required = false, .transport = .http, .workspace_admission = .approved },
    };
    defer for (&servers) |*server| server.deinit(alloc);
    var checks: std.ArrayList(Check) = .empty;
    defer {
        for (checks.items) |*entry| entry.deinit(alloc);
        checks.deinit(alloc);
    }

    try appendUnusedExtensionCheck(&checks, alloc, &servers);

    try std.testing.expectEqual(@as(usize, 0), checks.items.len);
}

test "bounded doctor warnings use existing check stream" {
    const alloc = std.testing.allocator;
    var checks: std.ArrayList(Check) = .empty;
    defer {
        for (checks.items) |*entry| entry.deinit(alloc);
        checks.deinit(alloc);
    }

    try appendSessionDiagnosticsTruncatedCheck(&checks, alloc, 64);

    try std.testing.expectEqual(@as(usize, 1), checks.items.len);
    try std.testing.expectEqualStrings("session", checks.items[0].name);
    try std.testing.expectEqual(CheckStatus.warn, checks.items[0].status);
    try std.testing.expect(std.mem.find(
        u8,
        checks.items[0].detail,
        "truncated after 64 session directories",
    ) != null);
}

test "a saved permission_mode yolo is the name settings accept and raises no doctor warning" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeDoctorFixtureFile(tmp.dir, "settings.json", "{\"permission_mode\":\"yolo\",\"workspaces\":{\"/w\":{\"permission_mode\":\"yolo\"}}}");
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    const path = try std.Io.Dir.path.join(alloc, &.{ dir, "settings.json" });
    defer alloc.free(path);
    var checks: std.ArrayList(Check) = .empty;
    defer {
        for (checks.items) |*entry| entry.deinit(alloc);
        checks.deinit(alloc);
    }

    try appendUnknownSettingChecksFor(&checks, alloc, path, "~/.fx/settings.json", .profile);

    try std.testing.expectEqual(@as(usize, 0), checks.items.len);
    try std.testing.expectEqual(@import("../shared/types.zig").PermissionMode.yolo, config_runtime.parsePermissionMode("yolo").?);
    try std.testing.expect(config_runtime.parsePermissionMode("full-access") == null);
}

fn writeDoctorFixtureFile(dir: std.Io.Dir, sub_path: []const u8, text: []const u8) !void {
    var file = try dir.createFile(std.testing.io, sub_path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, text);
}

test "has git metadata detects .git file or directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.git");
    const workspace_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "workspace");
    defer std.testing.allocator.free(workspace_root);

    try std.testing.expect(try hasGitMetadata(std.testing.allocator, workspace_root));
}

test "command in path checks explicit path entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_mod.getIo(), "bin");
    var file = try tmp.dir.createFile(std.testing.io, "bin/gh", .{});
    file.close(io_mod.getIo());

    const bin_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "bin");
    defer std.testing.allocator.free(bin_root);

    const path_env = try std.testing.allocator.print("{s}", .{bin_root});
    defer std.testing.allocator.free(path_env);

    try std.testing.expect(try commandInPathValue(std.testing.allocator, "gh", path_env));
    try std.testing.expect(!(try commandInPathValue(std.testing.allocator, "missing-command", path_env)));
}

fn instructionFixtureChecks(tmp: *std.testing.TmpDir, text: []const u8, checks: *std.ArrayList(Check)) !void {
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/src");
    try writeDoctorFixtureFile(tmp.dir, "workspace/src/present.zig", "");
    try writeDoctorFixtureFile(tmp.dir, "workspace/AGENTS.md", text);
    const workspace_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "workspace");
    defer std.testing.allocator.free(workspace_root);
    try appendInstructionFileChecks(checks, std.testing.allocator, workspace_root);
}

fn deinitChecks(checks: *std.ArrayList(Check)) void {
    for (checks.items) |*entry| entry.deinit(std.testing.allocator);
    checks.deinit(std.testing.allocator);
}

test "doctor adds no instruction check when the workspace has no instruction file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace_root = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "workspace");
    defer std.testing.allocator.free(workspace_root);
    var checks: std.ArrayList(Check) = .empty;
    defer deinitChecks(&checks);

    try appendInstructionFileChecks(&checks, std.testing.allocator, workspace_root);

    try std.testing.expectEqual(@as(usize, 0), checks.items.len);
}

test "doctor passes an instruction file at or under the size guide" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text = try std.testing.allocator.alloc(u8, instruction_file_warn_bytes);
    defer std.testing.allocator.free(text);
    @memset(text, 'a');
    var checks: std.ArrayList(Check) = .empty;
    defer deinitChecks(&checks);

    try instructionFixtureChecks(&tmp, text, &checks);

    try std.testing.expectEqual(@as(usize, 2), checks.items.len);
    try std.testing.expectEqualStrings("instructions", checks.items[0].name);
    try std.testing.expectEqual(CheckStatus.ok, checks.items[0].status);
    try std.testing.expectEqualStrings("AGENTS.md is 30720 bytes", checks.items[0].detail);
    try std.testing.expectEqual(CheckStatus.ok, checks.items[1].status);
    try std.testing.expectEqualStrings("every backticked repository path in AGENTS.md exists", checks.items[1].detail);
}

test "doctor warns with the size when the instruction file is above the size guide" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text = try std.testing.allocator.alloc(u8, instruction_file_warn_bytes + 1);
    defer std.testing.allocator.free(text);
    @memset(text, 'a');
    var checks: std.ArrayList(Check) = .empty;
    defer deinitChecks(&checks);

    try instructionFixtureChecks(&tmp, text, &checks);

    try std.testing.expectEqual(CheckStatus.warn, checks.items[0].status);
    try std.testing.expect(std.mem.startsWith(u8, checks.items[0].detail, "AGENTS.md is 30721 bytes, above the 30720-byte guide"));
}

test "doctor lists a missing backticked path once and skips paths that exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var checks: std.ArrayList(Check) = .empty;
    defer deinitChecks(&checks);

    try instructionFixtureChecks(
        &tmp,
        "Read `src/present.zig` and `src/gone.zig`.\nAgain `src/gone.zig:42`, `./src/gone.zig:7-9`, and `src/`.\n",
        &checks,
    );

    try std.testing.expectEqual(@as(usize, 2), checks.items.len);
    try std.testing.expectEqual(CheckStatus.warn, checks.items[1].status);
    try std.testing.expectEqualStrings("AGENTS.md names 1 path that does not exist: src/gone.zig", checks.items[1].detail);
}

test "doctor ignores backticked text that is not a path inside the repository" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var checks: std.ArrayList(Check) = .empty;
    defer deinitChecks(&checks);

    try instructionFixtureChecks(
        &tmp,
        "`zig build test`, `src/*.zig`, `https://example.com/src/x`, `/src/abs.zig`, `~/src/x`, `--flag/x`, `../src/x`, `text/plain`, `src/$NAME`, `present.zig`, `../..`\n",
        &checks,
    );

    try std.testing.expectEqual(CheckStatus.ok, checks.items[1].status);
}

test "doctor ignores paths inside fenced code blocks of the instruction file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var checks: std.ArrayList(Check) = .empty;
    defer deinitChecks(&checks);

    try instructionFixtureChecks(
        &tmp,
        "```sh\ncat `src/fenced.zig`\n```\nafter `src/open.zig`\n",
        &checks,
    );

    try std.testing.expectEqualStrings("AGENTS.md names 1 path that does not exist: src/open.zig", checks.items[1].detail);
}

test "doctor bounds the missing path list and counts the rest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    for (0..instruction_missing_paths_shown + 3) |index| try text.writer.print("`src/gone-{d}.zig`\n", .{index});
    var checks: std.ArrayList(Check) = .empty;
    defer deinitChecks(&checks);

    try instructionFixtureChecks(&tmp, text.written(), &checks);

    const detail = checks.items[1].detail;
    try std.testing.expectEqual(CheckStatus.warn, checks.items[1].status);
    try std.testing.expect(std.mem.startsWith(u8, detail, "AGENTS.md names 23 paths that do not exist: src/gone-0.zig, "));
    try std.testing.expect(std.mem.endsWith(u8, detail, "src/gone-19.zig (+3 more)"));
    try std.testing.expect(std.mem.find(u8, detail, "src/gone-20.zig") == null);
}
