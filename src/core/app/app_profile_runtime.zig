const std = @import("std");
const profiles = @import("../profiles/profiles.zig");
const tool_set = @import("../tooling/tool_set.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");
const agents = @import("../agents/agents.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");

pub const ProfileTools = struct {
    profile: *const profiles.Profile,
    role: profiles.Role,

    pub fn allows(self: ProfileTools, name: []const u8) bool {
        return profiles.allowsTool(self.profile, name);
    }
};

fn toolNames(arena: std.mem.Allocator, tools: []const @import("../tooling/tool_dispatch.zig").Tool) ![]const []const u8 {
    const names = try arena.alloc([]const u8, tools.len);
    for (tools, names) |tool, *name| name.* = tool.name;
    return names;
}

pub fn launchFailure(alloc: std.mem.Allocator, name: []const u8) !?[]u8 {
    const reason = try failureReason(alloc, name) orelse return null;
    defer alloc.free(reason);
    return try alloc.print("fx: {s}\n", .{reason});
}

pub fn failureReason(alloc: std.mem.Allocator, name: []const u8) !?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const workspace_root = io_mod.realpathAlloc(arena, ".") catch null;
    const roots = try profiles.Roots.init(arena, io_mod.homeDir(), workspace_root);
    var failure: ?[]const u8 = null;
    _ = profiles.load(arena, roots, name, &failure) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try alloc.dupe(u8, failure orelse @errorName(err)),
    };
    return null;
}

pub fn launchModel(model_flag: ?[]const u8, provider_flag: bool, env_model: ?[]const u8, profile_model: ?[]const u8) ?[]const u8 {
    if (model_flag) |model| return model;
    if (provider_flag or env_model != null) return null;
    return profile_model;
}

test "the launch profile's model gives way to the model the process chose" {
    try std.testing.expectEqualStrings("profile/model", launchModel(null, false, null, "profile/model").?);
    try std.testing.expect(launchModel(null, false, "env/model", "profile/model") == null);
    try std.testing.expect(launchModel(null, true, null, "profile/model") == null);
    try std.testing.expectEqualStrings("flag/model", launchModel("flag/model", true, "env/model", "profile/model").?);
    try std.testing.expect(launchModel(null, false, null, null) == null);
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = agents.Agent;
        pub fn applyLaunchProfile(
            app: *App,
            name: []const u8,
            base_prompt: []const u8,
            base_tools: tool_set.ToolSet,
        ) !void {
            try applyProfile(app, &app.main_agent, name, base_prompt, base_tools);
        }

        pub fn applyProfile(
            app: *App,
            agent: *AppAgent,
            name: []const u8,
            base_prompt: []const u8,
            base_tools: tool_set.ToolSet,
        ) !void {
            const workspace_root = io_mod.realpathAlloc(app.alloc, ".") catch null;
            defer if (workspace_root) |root| app.alloc.free(root);
            var failure: ?[]u8 = null;
            defer if (failure) |message| app.alloc.free(message);
            agent.profile.replace(app.alloc, io_mod.homeDir(), workspace_root, name, base_prompt, &failure) catch |err| {
                debug_trace.eventf("profile", "profile_failed", .{}, "name={s} reason={s}", .{
                    name,
                    failure orelse @errorName(err),
                });
                return err;
            };
            const held = &agent.profile;
            agent.profile_tools = try tool_set.narrow(held.arena.?.allocator(), base_tools, ProfileTools{
                .profile = &held.profile,
                .role = .main,
            });
            agent.profile_tool_names = if (agent.profile_tools) |set| try toolNames(held.arena.?.allocator(), set.registry.tools) else null;
        }

        pub fn applyLaunchMode(app: *App) !void {
            try reportProfile(app, &app.main_agent, "main");
            const permission = app_permission_runtime.Runtime(App);
            permission.initMode(app, &app.main_agent, profileMode(&app.main_agent, "main", permission.modeOf(app, &app.main_agent)));
        }

        pub fn profileMode(agent: *AppAgent, label: []const u8, parent: types.PermissionMode) types.PermissionMode {
            const profile = &agent.profile.profile;
            const mode = profiles.permissionMode(profile, parent);
            debug_trace.eventf("profile", "profile_mode", .{}, "agent={s} name={s} parent={s} mode={s}", .{
                label,
                profile.name,
                @tagName(parent),
                @tagName(mode),
            });
            return mode;
        }

        pub fn reportProfile(app: *App, agent: *AppAgent, label: []const u8) !void {
            const held = &agent.profile;
            for (held.profile.ignored) |ignored| {
                debug_trace.eventf("profile", "profile_key_ignored", .{}, "name={s} key={s} reason={s}", .{
                    held.profile.name,
                    ignored.key,
                    @tagName(ignored.reason),
                });
            }

            var names: std.ArrayList(u8) = .empty;
            defer names.deinit(app.alloc);
            if (agent.profile_tools) |set| {
                for (set.registry.tools, 0..) |tool, index| {
                    if (index > 0) try names.append(app.alloc, ',');
                    try names.appendSlice(app.alloc, tool.name);
                }
            } else try names.append(app.alloc, '*');
            debug_trace.eventf("profile", "profile_resolved", .{}, "agent={s} name={s} source={s} prompt={s} tools={s}", .{
                label,
                held.profile.name,
                @tagName(held.profile.source),
                if (held.system_prompt == null) "fx" else @tagName(held.profile.prompt_mode),
                names.items,
            });
        }
    };
}
