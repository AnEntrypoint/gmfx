const std = @import("std");
const server = @import("server.zig");
const app_runtime_setup = @import("../core/app/app_runtime_setup.zig");
const builtin_skills = @import("../builtins/skills.zig");
const config_runtime = @import("../core/config/config_runtime.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const skill_runtime = @import("../core/skills/skill_runtime.zig");
const workspace_access = @import("../core/workspace/workspace_access.zig");

const Allocator = std.mem.Allocator;

pub const PrepareError = Allocator.Error || error{
    InvalidParams,
    InvalidCwd,
    CwdNotAbsolute,
    CwdUnavailable,
    WorkspaceSettingsUnavailable,
    AdditionalDirectoriesInvalid,
    AdditionalDirectoryUnavailable,
};

pub const Binding = struct {
    root: []u8,
    access: workspace_access.WorkspaceAccess,
    skills: app_runtime_setup.LoadedSkills,
    session_directories: bool = false,

    pub fn deinit(self: *Binding, alloc: Allocator) void {
        alloc.free(self.root);
        self.access.deinit(alloc);
        self.skills.deinit(alloc);
        self.* = undefined;
    }
};

pub fn prepareErrorMessage(err: PrepareError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "Out of memory",
        error.InvalidParams => "Invalid params",
        error.InvalidCwd => "cwd must be a string",
        error.CwdNotAbsolute => "cwd must be an absolute path",
        error.CwdUnavailable => "cwd must name an existing directory",
        error.WorkspaceSettingsUnavailable => "Workspace settings for cwd could not be loaded",
        error.AdditionalDirectoriesInvalid => "additionalDirectories must be an array of absolute paths",
        error.AdditionalDirectoryUnavailable => "additionalDirectories must name existing directories",
    };
}

pub fn prepare(state: *const server.ServerState, alloc: Allocator, params_raw: ?[]const u8) PrepareError!?Binding {
    if (state.cfg.minimal_kernel or state.cfg.workspace_root_override != null) return null;
    const raw = params_raw orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidParams,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidParams;
    const requested = try requestedDirectories(alloc, parsed.value.object);
    defer alloc.free(requested);
    const rebuilds_access = requested.len > 0 or state.session_directories_bound;
    const requested_cwd = try requestedCwd(parsed.value.object);
    if (requested_cwd == null and !rebuilds_access) return null;

    const root = io_mod.realpathAlloc(alloc, requested_cwd orelse state.workspace_root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CwdUnavailable,
    };
    var root_owned = true;
    defer if (root_owned) alloc.free(root);
    if (std.mem.eql(u8, root, state.workspace_root) and !rebuilds_access) return null;
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), root, .{}) catch return error.CwdUnavailable;
    dir.close(io_mod.getIo());

    var access = try loadAccess(state, alloc, root, requested);
    errdefer access.deinit(alloc);
    var skills = try app_runtime_setup.loadSkills(alloc, root, builtin_skills.root_policy);
    errdefer skills.deinit(alloc);
    skill_runtime.traceDiagnostics("acp_session_workspace", skills.diagnostics);

    root_owned = false;
    return .{ .root = root, .access = access, .skills = skills, .session_directories = requested.len > 0 };
}

fn requestedCwd(params: std.json.ObjectMap) PrepareError!?[]const u8 {
    const cwd = params.get("cwd") orelse return null;
    if (cwd == .null) return null;
    if (cwd != .string) return error.InvalidCwd;
    if (!std.Io.Dir.path.isAbsolute(cwd.string)) return error.CwdNotAbsolute;
    return cwd.string;
}

fn requestedDirectories(alloc: Allocator, params: std.json.ObjectMap) PrepareError![]const []const u8 {
    const value = params.get("additionalDirectories") orelse return &.{};
    if (value == .null) return &.{};
    if (value != .array) return error.AdditionalDirectoriesInvalid;
    const paths = try alloc.alloc([]const u8, value.array.items.len);
    errdefer alloc.free(paths);
    for (value.array.items, paths) |item, *path| {
        if (item != .string or !std.Io.Dir.path.isAbsolute(item.string)) return error.AdditionalDirectoriesInvalid;
        path.* = item.string;
    }
    return paths;
}

test "session params name additional directories as an array of absolute paths" {
    const alloc = std.testing.allocator;
    var listed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"cwd\":\"/w\",\"additionalDirectories\":[\"/a\",\"/b/c\"]}", .{});
    defer listed.deinit();
    const paths = try requestedDirectories(alloc, listed.value.object);
    defer alloc.free(paths);
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("/a", paths[0]);
    try std.testing.expectEqualStrings("/b/c", paths[1]);
    try std.testing.expectEqualStrings("/w", (try requestedCwd(listed.value.object)).?);

    var absent = try std.json.parseFromSlice(std.json.Value, alloc, "{\"additionalDirectories\":null}", .{});
    defer absent.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try requestedDirectories(alloc, absent.value.object)).len);
    try std.testing.expect((try requestedCwd(absent.value.object)) == null);

    var relative = try std.json.parseFromSlice(std.json.Value, alloc, "{\"additionalDirectories\":[\"lib\"]}", .{});
    defer relative.deinit();
    try std.testing.expectError(error.AdditionalDirectoriesInvalid, requestedDirectories(alloc, relative.value.object));
    var scalar = try std.json.parseFromSlice(std.json.Value, alloc, "{\"additionalDirectories\":\"/a\"}", .{});
    defer scalar.deinit();
    try std.testing.expectError(error.AdditionalDirectoriesInvalid, requestedDirectories(alloc, scalar.value.object));
    try std.testing.expectEqualStrings("additionalDirectories must name existing directories", prepareErrorMessage(error.AdditionalDirectoryUnavailable));
}

fn loadAccess(state: *const server.ServerState, alloc: Allocator, root: []const u8, requested: []const []const u8) PrepareError!workspace_access.WorkspaceAccess {
    var detailed = (if (state.cfg.home_override) |home|
        config_runtime.loadMergedSettingsDetailedFromHome(alloc, home, root)
    else
        config_runtime.loadMergedSettingsDetailed(alloc, root)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("acp", "session workspace settings unavailable err={s}", .{@errorName(err)});
            return error.WorkspaceSettingsUnavailable;
        },
    };
    defer detailed.deinit(alloc);
    const saved: []const []const u8 = if (detailed.additional_directory_sources) |paths| paths else &.{};
    const granted = try std.mem.concat(alloc, []const u8, &.{ state.cfg.additional_directories, requested });
    defer alloc.free(granted);
    return workspace_access.WorkspaceAccess.init(
        alloc,
        root,
        saved,
        granted,
        state.cfg.saved_directories_suppressed,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("acp", "session workspace access unavailable err={s}", .{@errorName(err)});
            return if (requested.len > 0) error.AdditionalDirectoryUnavailable else error.CwdUnavailable;
        },
    };
}

pub fn commit(state: *server.ServerState, binding: *Binding) Allocator.Error!void {
    std.debug.assert(state.active_session == null);
    try state.skills.replaceLoaded(state.alloc, binding.skills.dir, binding.skills.skills, binding.skills.diagnostics);
    binding.skills = .{};
    debug_trace.logf("acp", "session workspace rebound bytes={d}", .{binding.root.len});
    if (state.workspace_root.len > 0) state.alloc.free(state.workspace_root);
    state.workspace_root = binding.root;
    binding.root = &.{};
    state.workspace_access.deinit(state.alloc);
    state.workspace_access = binding.access;
    binding.access = .{};
    state.session_directories_bound = binding.session_directories;
    state.context_snapshot.deinit(state.alloc);
    state.context_snapshot = .{};
}
