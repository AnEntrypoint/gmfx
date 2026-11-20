const std = @import("std");
const io_mod = @import("../shared/io.zig");
const mcp_contract = @import("mcp_contract.zig");
const project_config = @import("project_config.zig");
const workspace_trust = @import("workspace_trust.zig");

const max_config_bytes: usize = 1024 * 1024;
const root_file_name = ".mcp.json";
const kimi_dir_name = ".kimi-code";
const kimi_file_name = "mcp.json";
const trust_env_name = "KIMI_CODE_TRUST_WORKSPACE";
const trust_env_truthy = [_][]const u8{ "1", "true", "yes", "on" };

pub fn readRootFile(alloc: std.mem.Allocator, workspace_root: []const u8) !?[]u8 {
    const root = try projectRoot(alloc, workspace_root);
    defer alloc.free(root);
    return readFileIn(alloc, root, root_file_name);
}

pub fn readProjectFile(alloc: std.mem.Allocator, workspace_root: []const u8) !?[]u8 {
    const kimi_dir = try std.Io.Dir.path.join(alloc, &.{ workspace_root, kimi_dir_name });
    defer alloc.free(kimi_dir);
    return readFileIn(alloc, kimi_dir, kimi_file_name);
}

fn readFileIn(alloc: std.mem.Allocator, dir_path: []const u8, file_name: []const u8) !?[]u8 {
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    defer dir.close(io_mod.getIo());
    var file = io_mod.openExistingRegularFile(dir, file_name, .read_only) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.UnreadableConfig,
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.size > max_config_bytes) return error.UnreadableConfig;
    return io_mod.readFileToEnd(alloc, &file, max_config_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnreadableConfig,
    };
}

pub fn projectRoot(alloc: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    var current: []const u8 = workspace_root;
    while (std.Io.Dir.path.isAbsolute(current)) {
        const marker = try std.Io.Dir.path.join(alloc, &.{ current, ".git" });
        defer alloc.free(marker);
        if (std.Io.Dir.cwd().statFile(io_mod.getIo(), marker, .{ .follow_symlinks = true })) |_| {
            return alloc.dupe(u8, current);
        } else |_| {}
        const parent = std.Io.Dir.path.dirname(current) orelse break;
        if (parent.len >= current.len) break;
        current = parent;
    }
    return alloc.dupe(u8, workspace_root);
}

pub fn load(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    scope: mcp_contract.ConfigScope,
    choices: project_config.ProjectMcpChoices,
) !project_config.WorkspaceParseResult {
    var environment = io_mod.cloneEnvironMap(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.process.Environ.Map.init(alloc),
    };
    defer environment.deinit();
    return loadWithEnvironment(alloc, workspace_root, scope, choices, &environment, io_mod.homeDir());
}

pub fn loadWithEnvironment(
    alloc: std.mem.Allocator,
    workspace_root: []const u8,
    scope: mcp_contract.ConfigScope,
    choices: project_config.ProjectMcpChoices,
    environment: *const std.process.Environ.Map,
    home: ?[]const u8,
) !project_config.WorkspaceParseResult {
    var effective = choices;
    if (!effective.enable_all and !trustedByEnvironment(environment)) {
        effective.enable_all = (try workspace_trust.gate(alloc, home, workspace_root)).grantsAll();
    } else {
        effective.enable_all = true;
    }

    const root = try projectRoot(alloc, workspace_root);
    defer alloc.free(root);
    const kimi_dir = try std.Io.Dir.path.join(alloc, &.{ workspace_root, kimi_dir_name });
    defer alloc.free(kimi_dir);

    var result = try loadLayer(alloc, root, root_file_name, scope, effective);
    errdefer result.deinit(alloc);
    try anchorStdioCwd(alloc, &result.configs, root);

    var kimi_layer = try loadLayer(alloc, kimi_dir, kimi_file_name, scope, effective);
    defer kimi_layer.deinit(alloc);
    dropShadowed(alloc, &result.configs, kimi_layer.configs.items);
    try absorb(alloc, &result, &kimi_layer);

    const has_approved = for (result.configs.items) |config| {
        if (config.workspace_admission == .approved) break true;
    } else false;
    if (!has_approved) return result;
    try project_config.expandApprovedWorkspaceConfigs(alloc, &result, environment);
    return result;
}

fn trustedByEnvironment(environment: *const std.process.Environ.Map) bool {
    const raw = environment.get(trust_env_name) orelse return false;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    for (trust_env_truthy) |truthy| {
        if (std.ascii.eqlIgnoreCase(value, truthy)) return true;
    }
    return false;
}

fn loadLayer(
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    file_name: []const u8,
    scope: mcp_contract.ConfigScope,
    choices: project_config.ProjectMcpChoices,
) !project_config.WorkspaceParseResult {
    const bytes = (readFileIn(alloc, dir_path, file_name) catch |err| switch (err) {
        error.UnreadableConfig => return invalidResult(alloc),
        else => |e| return e,
    }) orelse return .{};
    defer alloc.free(bytes);
    return project_config.parseWorkspaceJson(alloc, bytes, scope, choices);
}

fn anchorStdioCwd(
    alloc: std.mem.Allocator,
    configs: *std.ArrayList(mcp_contract.McpServerConfig),
    anchor: []const u8,
) !void {
    for (configs.items) |*config| {
        if (config.transport != .stdio) continue;
        const configured = config.cwd orelse {
            config.cwd = try alloc.dupe(u8, anchor);
            continue;
        };
        if (std.Io.Dir.path.isAbsolute(configured)) continue;
        const resolved = try std.Io.Dir.path.resolveAlloc(alloc, &.{ anchor, configured });
        alloc.free(configured);
        config.cwd = resolved;
    }
}

fn dropShadowed(
    alloc: std.mem.Allocator,
    configs: *std.ArrayList(mcp_contract.McpServerConfig),
    shadowing: []const mcp_contract.McpServerConfig,
) void {
    var index: usize = 0;
    while (index < configs.items.len) {
        if (containsConfigName(shadowing, configs.items[index].name)) {
            var removed = configs.orderedRemove(index);
            removed.deinit(alloc);
            continue;
        }
        index += 1;
    }
}

fn containsConfigName(configs: []const mcp_contract.McpServerConfig, name: []const u8) bool {
    for (configs) |config| {
        if (std.mem.eql(u8, config.name, name)) return true;
    }
    return false;
}

fn absorb(
    alloc: std.mem.Allocator,
    dst: *project_config.WorkspaceParseResult,
    src: *project_config.WorkspaceParseResult,
) !void {
    try dst.configs.ensureUnusedCapacity(alloc, src.configs.items.len);
    try dst.diagnostics.ensureUnusedCapacity(alloc, src.diagnostics.items.len);
    dst.configs.appendSliceAssumeCapacity(src.configs.items);
    dst.diagnostics.appendSliceAssumeCapacity(src.diagnostics.items);
    src.configs.clearRetainingCapacity();
    src.diagnostics.clearRetainingCapacity();
}

fn invalidResult(alloc: std.mem.Allocator) !project_config.WorkspaceParseResult {
    var result: project_config.WorkspaceParseResult = .{};
    errdefer result.deinit(alloc);
    try result.diagnostics.append(alloc, .{ .cause = .invalid_entry });
    return result;
}

fn writeTestFile(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| {
        try tmp.dir.createDirPath(io_mod.getIo(), parent);
    }
    var file = try tmp.dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

test "project layers merge the git root .mcp.json under the cwd .kimi-code/mcp.json by name" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "repo/.git");
    try writeTestFile(&tmp, "repo/.mcp.json",
        \\{"mcpServers":{"shared":{"command":"root-shared"},"rootonly":{"command":"root-only"}}}
    );
    try writeTestFile(&tmp, "repo/app/.kimi-code/mcp.json",
        \\{"mcpServers":{"shared":{"command":"cwd-shared"}}}
    );
    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo/app");
    defer alloc.free(workspace_root);

    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    var result = try loadWithEnvironment(alloc, workspace_root, .workspace, .{ .enable_all = true }, &environment, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), result.configs.items.len);
    try std.testing.expectEqualStrings("rootonly", result.configs.items[0].name);
    try std.testing.expectEqualStrings("shared", result.configs.items[1].name);
    try std.testing.expectEqualStrings("cwd-shared", result.configs.items[1].command.?);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.items.len);
}

test "stdio servers from the git root .mcp.json run from the git root" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "repo/.git");
    try writeTestFile(&tmp, "repo/.mcp.json",
        \\{"mcpServers":{"local":{"command":"local-server"}}}
    );
    try writeTestFile(&tmp, "repo/app/.kimi-code/mcp.json",
        \\{"mcpServers":{"nested":{"command":"nested-server"}}}
    );
    const repo_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(repo_root);
    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo/app");
    defer alloc.free(workspace_root);

    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    var result = try loadWithEnvironment(alloc, workspace_root, .workspace, .{ .enable_all = true }, &environment, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), result.configs.items.len);
    try std.testing.expectEqualStrings(repo_root, result.configs.items[0].cwd.?);
    try std.testing.expect(result.configs.items[1].cwd == null);
}

test "a relative cwd in the git root .mcp.json resolves against the git root, and an absolute one is kept" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "repo/.git");
    try writeTestFile(&tmp, "repo/.mcp.json",
        \\{"mcpServers":{"absolute":{"command":"a","cwd":"/srv/data"},"relative":{"command":"r","cwd":"tools/server"}}}
    );
    const repo_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(repo_root);

    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    var result = try loadWithEnvironment(alloc, repo_root, .workspace, .{ .enable_all = true }, &environment, null);
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), result.configs.items.len);
    try std.testing.expectEqualStrings("/srv/data", result.configs.items[0].cwd.?);
    const expected = try std.Io.Dir.path.join(alloc, &.{ repo_root, "tools/server" });
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, result.configs.items[1].cwd.?);
}

test "project root is the nearest ancestor holding .git" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "outer/.git");
    try tmp.dir.createDirPath(io_mod.getIo(), "outer/inner/.git");
    try tmp.dir.createDirPath(io_mod.getIo(), "outer/inner/deep/work");
    const inner = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "outer/inner");
    defer alloc.free(inner);
    const start = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "outer/inner/deep/work");
    defer alloc.free(start);

    const root = try projectRoot(alloc, start);
    defer alloc.free(root);
    try std.testing.expectEqualStrings(inner, root);
}

test "project servers stay pending without trust and the trust env approves them" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "repo/.git");
    try writeTestFile(&tmp, "repo/.mcp.json",
        \\{"mcpServers":{"local":{"command":"local-server"}}}
    );
    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(workspace_root);

    var untrusted_environment = std.process.Environ.Map.init(alloc);
    defer untrusted_environment.deinit();
    var untrusted = try loadWithEnvironment(alloc, workspace_root, .workspace, .{}, &untrusted_environment, null);
    defer untrusted.deinit(alloc);
    try std.testing.expectEqual(mcp_contract.WorkspaceAdmission.pending, untrusted.configs.items[0].workspace_admission.?);

    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    try environment.put(trust_env_name, " Yes ");
    var trusted = try loadWithEnvironment(alloc, workspace_root, .workspace, .{}, &environment, null);
    defer trusted.deinit(alloc);
    try std.testing.expectEqual(mcp_contract.WorkspaceAdmission.approved, trusted.configs.items[0].workspace_admission.?);
}

test "the trust env does not lift a rejected project server" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "repo/.git");
    try writeTestFile(&tmp, "repo/.mcp.json",
        \\{"mcpServers":{"local":{"command":"local-server"}}}
    );
    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(workspace_root);
    var rejected_names = [_][]u8{@constCast("local")};
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    try environment.put(trust_env_name, "1");

    var result = try loadWithEnvironment(alloc, workspace_root, .workspace, .{ .rejected = &rejected_names }, &environment, null);
    defer result.deinit(alloc);
    try std.testing.expectEqual(mcp_contract.WorkspaceAdmission.rejected, result.configs.items[0].workspace_admission.?);
}

test "a malformed .kimi-code/mcp.json reports a diagnostic and keeps the root layer" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "repo/.git");
    try writeTestFile(&tmp, "repo/.mcp.json",
        \\{"mcpServers":{"local":{"command":"local-server"}}}
    );
    try writeTestFile(&tmp, "repo/.kimi-code/mcp.json", "{not json");
    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(workspace_root);

    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    var result = try loadWithEnvironment(alloc, workspace_root, .workspace, .{ .enable_all = true }, &environment, null);
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), result.configs.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.items.len);
    try std.testing.expectEqual(project_config.WorkspaceDiagnosticCause.invalid_json, result.diagnostics.items[0].cause);
}

test "a persisted workspace trust record approves project servers until it is revoked" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "repo/.git");
    try writeTestFile(&tmp, "repo/.mcp.json",
        \\{"mcpServers":{"local":{"command":"local-server"}}}
    );
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(workspace_root);
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();

    var pending = try loadWithEnvironment(alloc, workspace_root, .workspace, .{}, &environment, home);
    defer pending.deinit(alloc);
    try std.testing.expectEqual(mcp_contract.WorkspaceAdmission.pending, pending.configs.items[0].workspace_admission.?);

    try workspace_trust.grant(alloc, home, workspace_root, 1);
    var approved = try loadWithEnvironment(alloc, workspace_root, .workspace, .{}, &environment, home);
    defer approved.deinit(alloc);
    try std.testing.expectEqual(mcp_contract.WorkspaceAdmission.approved, approved.configs.items[0].workspace_admission.?);

    try workspace_trust.revoke(alloc, home, workspace_root);
    var revoked = try loadWithEnvironment(alloc, workspace_root, .workspace, .{}, &environment, home);
    defer revoked.deinit(alloc);
    try std.testing.expectEqual(mcp_contract.WorkspaceAdmission.pending, revoked.configs.items[0].workspace_admission.?);
}

test "require_trust false in the profile settings approves project servers without trust" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "repo/.git");
    try writeTestFile(&tmp, "repo/.mcp.json",
        \\{"mcpServers":{"local":{"command":"local-server"}}}
    );
    try writeTestFile(&tmp, "home/.fx/settings.json", "{\"workspace\":{\"require_trust\":false}}");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const workspace_root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "repo");
    defer alloc.free(workspace_root);
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();

    var result = try loadWithEnvironment(alloc, workspace_root, .workspace, .{}, &environment, home);
    defer result.deinit(alloc);
    try std.testing.expectEqual(mcp_contract.WorkspaceAdmission.approved, result.configs.items[0].workspace_admission.?);
}
