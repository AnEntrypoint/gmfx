const std = @import("std");
const external = @import("../hooks/external.zig");
const manager = @import("manager.zig");

const Allocator = std.mem.Allocator;

pub const Root = struct {
    plugin_id: []const u8,
    path: []const u8,
    instructions: ?[]const u8,
};

pub const SessionStart = struct {
    plugin_id: []const u8,
    skill: []const u8,
};

pub const SystemPrompt = struct {
    plugin_id: []const u8,
    text: []const u8,
};

fn contributes(plugin: manager.Plugin) bool {
    return plugin.record.enabled and plugin.isOk();
}

pub fn skillRoots(arena: Allocator, plugins: []const manager.Plugin) ![]const Root {
    var out: std.ArrayList(Root) = .empty;
    for (plugins) |plugin| {
        if (!contributes(plugin)) continue;
        const loaded = plugin.manifest orelse continue;
        for (loaded.skills) |path| {
            try out.append(arena, .{ .plugin_id = plugin.record.id, .path = path, .instructions = loaded.skill_instructions });
        }
    }
    return out.toOwnedSlice(arena);
}

pub fn skillDirs(arena: Allocator, plugins: []const manager.Plugin) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (plugins) |plugin| {
        if (!contributes(plugin)) continue;
        const loaded = plugin.manifest orelse continue;
        if (loaded.root_skill_fallback) continue;
        try out.appendSlice(arena, loaded.skills);
    }
    return out.toOwnedSlice(arena);
}

pub fn agentRoots(arena: Allocator, plugins: []const manager.Plugin) ![]const Root {
    var out: std.ArrayList(Root) = .empty;
    for (plugins) |plugin| {
        if (!contributes(plugin)) continue;
        const loaded = plugin.manifest orelse continue;
        for (loaded.agents) |path| {
            try out.append(arena, .{ .plugin_id = plugin.record.id, .path = path, .instructions = null });
        }
    }
    return out.toOwnedSlice(arena);
}

pub fn sessionStarts(arena: Allocator, plugins: []const manager.Plugin) ![]const SessionStart {
    var out: std.ArrayList(SessionStart) = .empty;
    for (plugins) |plugin| {
        if (!contributes(plugin)) continue;
        const loaded = plugin.manifest orelse continue;
        const skill = loaded.session_start_skill orelse continue;
        try out.append(arena, .{ .plugin_id = plugin.record.id, .skill = skill });
    }
    return out.toOwnedSlice(arena);
}

pub fn systemPrompts(arena: Allocator, plugins: []const manager.Plugin) ![]const SystemPrompt {
    var out: std.ArrayList(SystemPrompt) = .empty;
    for (plugins) |plugin| {
        if (!contributes(plugin)) continue;
        const loaded = plugin.manifest orelse continue;
        const text = loaded.system_prompt orelse continue;
        try out.append(arena, .{ .plugin_id = plugin.record.id, .text = text });
    }
    return out.toOwnedSlice(arena);
}

pub fn withSystemPrompts(arena: Allocator, base: []const u8, plugins: []const manager.Plugin) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, base);
    for (try systemPrompts(arena, plugins)) |prompt| {
        try text.appendSlice(arena, "\n\n");
        try text.appendSlice(arena, prompt.text);
    }
    return text.items;
}

pub fn hooks(arena: Allocator, plugins: []const manager.Plugin) ![]const external.Definition {
    var out: std.ArrayList(external.Definition) = .empty;
    for (plugins) |plugin| {
        if (!contributes(plugin)) continue;
        const loaded = plugin.manifest orelse continue;
        try out.appendSlice(arena, loaded.hooks);
    }
    return out.toOwnedSlice(arena);
}

test "enabled plugins contribute skill and agent roots and skip disabled and broken ones" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const skills_a = [_][]const u8{"/p/a/skills"};
    const agents_a = [_][]const u8{"/p/a/agents"};
    const skills_off = [_][]const u8{"/p/off/skills"};
    const plugins = [_]manager.Plugin{
        .{
            .record = .{ .id = "a", .root = "/p/a", .source = "/p/a" },
            .manifest = .{ .name = "a", .id = "a", .skills = &skills_a, .agents = &agents_a, .skill_instructions = "Use the a skills." },
        },
        .{
            .record = .{ .id = "off", .root = "/p/off", .source = "/p/off", .enabled = false },
            .manifest = .{ .name = "off", .id = "off", .skills = &skills_off },
        },
        .{
            .record = .{ .id = "bad", .root = "/p/bad", .source = "/p/bad" },
            .load_error = "No manifest",
        },
    };

    const skills = try skillRoots(arena, &plugins);
    try std.testing.expectEqual(@as(usize, 1), skills.len);
    try std.testing.expectEqualStrings("a", skills[0].plugin_id);
    try std.testing.expectEqualStrings("/p/a/skills", skills[0].path);
    try std.testing.expectEqualStrings("Use the a skills.", skills[0].instructions.?);

    const agents = try agentRoots(arena, &plugins);
    try std.testing.expectEqual(@as(usize, 1), agents.len);
    try std.testing.expectEqualStrings("/p/a/agents", agents[0].path);
    try std.testing.expect(agents[0].instructions == null);
}

test "skill directories of enabled plugins are listed for discovery, without disabled plugins or single-skill roots" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const skills_a = [_][]const u8{ "/p/a/skills", "/p/a/extra" };
    const skills_off = [_][]const u8{"/p/off/skills"};
    const skills_single = [_][]const u8{"/p/single"};
    const plugins = [_]manager.Plugin{
        .{
            .record = .{ .id = "a", .root = "/p/a", .source = "/p/a" },
            .manifest = .{ .name = "a", .id = "a", .skills = &skills_a },
        },
        .{
            .record = .{ .id = "off", .root = "/p/off", .source = "/p/off", .enabled = false },
            .manifest = .{ .name = "off", .id = "off", .skills = &skills_off },
        },
        .{
            .record = .{ .id = "single", .root = "/p/single", .source = "/p/single" },
            .manifest = .{ .name = "single", .id = "single", .skills = &skills_single, .root_skill_fallback = true },
        },
    };

    const dirs = try skillDirs(arena, &plugins);
    try std.testing.expectEqual(@as(usize, 2), dirs.len);
    try std.testing.expectEqualStrings("/p/a/skills", dirs[0]);
    try std.testing.expectEqualStrings("/p/a/extra", dirs[1]);
}

test "session start skills and system prompts come from enabled plugins only" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plugins = [_]manager.Plugin{
        .{
            .record = .{ .id = "a", .root = "/p/a", .source = "/p/a" },
            .manifest = .{ .name = "a", .id = "a", .session_start_skill = "intro", .system_prompt = "Be brief." },
        },
        .{
            .record = .{ .id = "off", .root = "/p/off", .source = "/p/off", .enabled = false },
            .manifest = .{ .name = "off", .id = "off", .session_start_skill = "other", .system_prompt = "Ignored." },
        },
    };

    const starts = try sessionStarts(arena, &plugins);
    try std.testing.expectEqual(@as(usize, 1), starts.len);
    try std.testing.expectEqualStrings("intro", starts[0].skill);
    try std.testing.expectEqualStrings("a", starts[0].plugin_id);

    const prompts = try systemPrompts(arena, &plugins);
    try std.testing.expectEqual(@as(usize, 1), prompts.len);
    try std.testing.expectEqualStrings("Be brief.", prompts[0].text);
}

test "plugin system prompts are appended to the base prompt when enabled" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plugins = [_]manager.Plugin{
        .{
            .record = .{ .id = "a", .root = "/p/a", .source = "/p/a" },
            .manifest = .{ .name = "a", .id = "a", .system_prompt = "Be brief." },
        },
        .{
            .record = .{ .id = "off", .root = "/p/off", .source = "/p/off", .enabled = false },
            .manifest = .{ .name = "off", .id = "off", .system_prompt = "Ignored." },
        },
    };
    try std.testing.expectEqualStrings("Base.\n\nBe brief.", try withSystemPrompts(arena, "Base.", &plugins));
}

test "plugin hook definitions are collected from enabled plugins only" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const command = try arena.dupe(u8, "./check.sh");
    const hooks_a = [_]external.Definition{.{ .event = .PreToolUse, .command = command, .cwd = command }};
    const plugins = [_]manager.Plugin{
        .{
            .record = .{ .id = "a", .root = "/p/a", .source = "/p/a" },
            .manifest = .{ .name = "a", .id = "a", .hooks = &hooks_a },
        },
        .{
            .record = .{ .id = "off", .root = "/p/off", .source = "/p/off", .enabled = false },
            .manifest = .{ .name = "off", .id = "off", .hooks = &hooks_a },
        },
    };

    const collected = try hooks(arena, &plugins);
    try std.testing.expectEqual(@as(usize, 1), collected.len);
    try std.testing.expectEqual(external.Event.PreToolUse, collected[0].event);
    try std.testing.expectEqualStrings("./check.sh", collected[0].command);
}
