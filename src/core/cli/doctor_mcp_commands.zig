const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const project_config = @import("../mcp/project_config.zig");

const Allocator = std.mem.Allocator;

pub const check_name = "mcp_commands";
const workspace_config_file = ".mcp.json";
const max_config_bytes: usize = 4 * 1024 * 1024;
const max_missing_shown: usize = 10;
const windows_suffixes = [_][]const u8{ "", ".exe", ".cmd", ".bat" };
const other_suffixes = [_][]const u8{""};

pub const Report = struct {
    commands: usize = 0,
    missing: usize = 0,
    detail: ?[]u8 = null,
};

pub fn appendCheck(checks: anytype, alloc: Allocator, workspace_root: []const u8) !void {
    var configs: std.ArrayList(mcp_contract.McpServerConfig) = .empty;
    defer {
        for (configs.items) |*config| config.deinit(alloc);
        configs.deinit(alloc);
    }
    if (io_mod.homeDir()) |home| {
        const profile_path = try profile_paths.mcpConfigPath(alloc, home);
        defer alloc.free(profile_path);
        try appendConfigsFrom(alloc, &configs, profile_path);
    }
    const workspace_path = try std.Io.Dir.path.join(alloc, &.{ workspace_root, workspace_config_file });
    defer alloc.free(workspace_path);
    try appendConfigsFrom(alloc, &configs, workspace_path);

    const report = try inspect(alloc, configs.items, io_mod.getenv("PATH") orelse "", workspace_root);
    const detail = report.detail orelse return;
    errdefer alloc.free(detail);
    try checks.append(alloc, .{
        .name = check_name,
        .status = if (report.missing > 0) .warn else .ok,
        .detail = detail,
        .owned_detail = detail,
    });
}

fn appendConfigsFrom(alloc: Allocator, configs: *std.ArrayList(mcp_contract.McpServerConfig), path: []const u8) Allocator.Error!void {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return;
    defer file.close(io_mod.getIo());
    const text = io_mod.readFileToEnd(alloc, &file, max_config_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer alloc.free(text);
    var skipped: std.ArrayList(project_config.WorkspaceDiagnostic) = .empty;
    defer {
        for (skipped.items) |*note| note.deinit(alloc);
        skipped.deinit(alloc);
    }
    var parsed = project_config.parseProfileServers(alloc, text, &skipped) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer parsed.deinit(alloc);
    try configs.ensureUnusedCapacity(alloc, parsed.items.len);
    for (parsed.items) |config| configs.appendAssumeCapacity(config);
    parsed.clearRetainingCapacity();
}

pub fn inspect(alloc: Allocator, configs: []const mcp_contract.McpServerConfig, path_env: []const u8, workspace_root: []const u8) Allocator.Error!Report {
    var report: Report = .{};
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (configs) |config| {
        if (config.transport != .stdio or !config.enabled) continue;
        const command = config.command orelse continue;
        if (command.len == 0 or std.mem.find(u8, command, "${") != null) continue;
        report.commands += 1;
        if (try commandExists(alloc, command, path_env, config.cwd orelse workspace_root)) continue;
        report.missing += 1;
        if (report.missing > max_missing_shown) continue;
        if (report.missing > 1) out.writer.writeAll("; ") catch return error.OutOfMemory;
        out.writer.print("server '{s}' command '{s}' was not found", .{ config.name, command }) catch return error.OutOfMemory;
        if (!hasSeparator(command)) out.writer.writeAll(" on PATH") catch return error.OutOfMemory;
    }
    if (report.commands == 0) return report;
    if (report.missing == 0) {
        report.detail = try std.fmt.allocPrint(alloc, "{d} MCP server command{s} found on disk", .{ report.commands, if (report.commands == 1) "" else "s" });
        return report;
    }
    if (report.missing > max_missing_shown) {
        out.writer.print("; and {d} more", .{report.missing - max_missing_shown}) catch return error.OutOfMemory;
    }
    report.detail = try out.toOwnedSlice();
    return report;
}

fn hasSeparator(command: []const u8) bool {
    return std.mem.findAny(u8, command, "/\\") != null;
}

pub fn commandExists(alloc: Allocator, command: []const u8, path_env: []const u8, base_dir: []const u8) Allocator.Error!bool {
    const suffixes: []const []const u8 = if (builtin.target.os.tag == .windows) &windows_suffixes else &other_suffixes;
    if (std.Io.Dir.path.isAbsolute(command)) return existsWithSuffix(alloc, "", command, suffixes);
    if (hasSeparator(command)) return existsWithSuffix(alloc, base_dir, command, suffixes);
    var entries = std.mem.splitScalar(u8, path_env, std.Io.Dir.path.delimiter);
    while (entries.next()) |entry| {
        if (entry.len == 0 or !std.Io.Dir.path.isAbsolute(entry)) continue;
        if (try existsWithSuffix(alloc, entry, command, suffixes)) return true;
    }
    return false;
}

fn existsWithSuffix(alloc: Allocator, directory: []const u8, command: []const u8, suffixes: []const []const u8) Allocator.Error!bool {
    const joined = if (directory.len == 0) try alloc.dupe(u8, command) else try std.Io.Dir.path.join(alloc, &.{ directory, command });
    defer alloc.free(joined);
    if (!std.Io.Dir.path.isAbsolute(joined)) return false;
    for (suffixes) |suffix| {
        const candidate = try std.mem.concat(alloc, u8, &.{ joined, suffix });
        defer alloc.free(candidate);
        const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), candidate, .{}) catch continue;
        if (stat.kind != .directory) return true;
    }
    return false;
}

const TestCheck = struct {
    name: []const u8,
    status: enum { ok, warn, fail },
    detail: []const u8,
    owned_detail: ?[]u8 = null,
};

test "doctor resolves a bare MCP command through PATH and a path-like one directly" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "bin");
    try tmp.dir.createDirPath(std.testing.io, "repo/tools");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bin/notes-server", .data = "#!/bin/sh\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/tools/local-server", .data = "#!/bin/sh\n" });
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const bin = try std.Io.Dir.path.join(alloc, &.{ root, "bin" });
    defer alloc.free(bin);
    const repo = try std.Io.Dir.path.join(alloc, &.{ root, "repo" });
    defer alloc.free(repo);
    const absolute = try std.Io.Dir.path.join(alloc, &.{ bin, "notes-server" });
    defer alloc.free(absolute);
    const path_env = try std.fmt.allocPrint(alloc, "relative-entry{c}{c}{s}", .{ std.Io.Dir.path.delimiter, std.Io.Dir.path.delimiter, bin });
    defer alloc.free(path_env);

    try std.testing.expect(try commandExists(alloc, "notes-server", path_env, repo));
    try std.testing.expect(!try commandExists(alloc, "missing-server", path_env, repo));
    try std.testing.expect(!try commandExists(alloc, "notes-server", "", repo));
    try std.testing.expect(try commandExists(alloc, absolute, "", repo));
    try std.testing.expect(try commandExists(alloc, "./tools/local-server", "", repo));
    try std.testing.expect(try commandExists(alloc, "tools/local-server", "", repo));
    try std.testing.expect(!try commandExists(alloc, "tools/absent", path_env, repo));
    try std.testing.expect(!try commandExists(alloc, "tools", path_env, repo));
}

test "doctor reports each configured MCP server whose command is not on disk" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "bin");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bin/present", .data = "x" });
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const bin = try std.Io.Dir.path.join(alloc, &.{ root, "bin" });
    defer alloc.free(bin);

    const none = try inspect(alloc, &.{.{ .name = "web", .transport = .http, .url = "https://example.test/mcp" }}, bin, root);
    try std.testing.expectEqual(@as(?[]u8, null), none.detail);

    const found = try inspect(alloc, &.{
        .{ .name = "a", .command = "present" },
        .{ .name = "templated", .command = "${TOOLS}/server" },
        .{ .name = "off", .command = "absent", .enabled = false },
    }, bin, root);
    defer alloc.free(found.detail.?);
    try std.testing.expectEqual(@as(usize, 1), found.commands);
    try std.testing.expectEqual(@as(usize, 0), found.missing);
    try std.testing.expectEqualStrings("1 MCP server command found on disk", found.detail.?);

    const missing = try inspect(alloc, &.{
        .{ .name = "a", .command = "present" },
        .{ .name = "b", .command = "absent" },
        .{ .name = "c", .command = "./tools/absent" },
    }, bin, root);
    defer alloc.free(missing.detail.?);
    try std.testing.expectEqual(@as(usize, 2), missing.missing);
    try std.testing.expectEqualStrings("server 'b' command 'absent' was not found on PATH; server 'c' command './tools/absent' was not found", missing.detail.?);
}

test "doctor adds no MCP command check when the workspace configures no stdio server" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    var configs: std.ArrayList(mcp_contract.McpServerConfig) = .empty;
    defer configs.deinit(alloc);
    const workspace_path = try std.Io.Dir.path.join(alloc, &.{ root, workspace_config_file });
    defer alloc.free(workspace_path);
    try appendConfigsFrom(alloc, &configs, workspace_path);
    try std.testing.expectEqual(@as(usize, 0), configs.items.len);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = workspace_config_file, .data = "{\"mcpServers\":{\"gone\":{\"command\":\"fx-doctor-test-absent-command\"},\"bad\":{\"command\":3}}}" });
    try appendConfigsFrom(alloc, &configs, workspace_path);
    defer for (configs.items) |*config| config.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), configs.items.len);

    var checks: std.ArrayList(TestCheck) = .empty;
    defer checks.deinit(alloc);
    const report = try inspect(alloc, configs.items, "", root);
    const detail = report.detail.?;
    defer alloc.free(detail);
    try checks.append(alloc, .{ .name = check_name, .status = .warn, .detail = detail, .owned_detail = detail });
    try std.testing.expectEqualStrings("server 'gone' command 'fx-doctor-test-absent-command' was not found on PATH", checks.items[0].detail);
}
