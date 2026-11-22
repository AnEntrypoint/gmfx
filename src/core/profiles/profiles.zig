const std = @import("std");
const types = @import("../shared/types.zig");
const io_mod = @import("../shared/io.zig");
const pathing = @import("../workspace/pathing.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const markdown_agent = @import("markdown_agent.zig");
const plugin_manager = @import("../plugins/manager.zig");
const plugin_contributions = @import("../plugins/contributions.zig");

const Allocator = std.mem.Allocator;

pub const max_name_bytes = 64;
pub const max_settings_bytes = 64 * 1024;
pub const max_prompt_bytes = 256 * 1024;
const max_list_entry_bytes = 256;

pub const settings_file_name = "profile.json";
pub const prompt_file_name = "prompt.md";
pub const main_name = "main";
pub const agent_name = "agent";
pub const coder_name = "coder";
pub const explore_name = "explore";
pub const plan_name = "plan";
pub const tower_worker_name = "tower-worker";
pub const default_subagent_name = coder_name;
const claude_dir_name = ".claude";

const NameAlias = struct {
    alias: []const u8,
    name: []const u8,
};

const claude_code_names = [_]NameAlias{
    .{ .alias = "general-purpose", .name = coder_name },
    .{ .alias = "claude", .name = coder_name },
    .{ .alias = "Explore", .name = explore_name },
    .{ .alias = "Plan", .name = plan_name },
};

pub fn canonicalName(name: []const u8) []const u8 {
    for (claude_code_names) |entry| {
        if (std.mem.eql(u8, entry.alias, name)) return entry.name;
    }
    return name;
}

const subagent_tool = "Agent";
const wildcard = "*";
const mcp_tool_prefix = "mcp__";
const mcp_loader_tools = [_][]const u8{ "capability_search", "select_tools" };

const coder_tools = [_][]const u8{
    "NotifyUser",
    "Bash",
    "edit_file",
    "glob_files",
    "grep_files",
    "read_file",
    "Skill",
    "TaskList",
    "TaskOutput",
    "TaskStop",
    "TodoList",
    "WaitFor",
    "WebSearch",
    "FetchURL",
    "write_file",
    "vision",
    "mcp__*",
};
const explore_tools = [_][]const u8{
    "NotifyUser",
    "Bash",
    "read_file",
    "vision",
    "glob_files",
    "grep_files",
    "WebSearch",
    "FetchURL",
};
const plan_tools = [_][]const u8{
    "NotifyUser",
    "read_file",
    "vision",
    "glob_files",
    "grep_files",
    "WebSearch",
    "FetchURL",
};

const coder_prompt =
    \\Your final message is the entire handoff. Make it technically complete: what you changed and why, the path of every file you touched, how you verified the change (tests or commands run, with results), and anything left undone or worth follow-up. If you are stopped before finishing, the parent receives only what you have written so far, so keep the handoff current.
;
const explore_prompt =
    \\You are a codebase exploration specialist. Your role is EXCLUSIVELY to search, read, and analyze existing code and resources. You do NOT have access to file editing tools.
    \\
    \\Guidelines:
    \\- Use glob_files for broad file pattern matching. Prefer patterns with a literal anchor (extension or subdirectory); pure wildcards like `*` or `**/*` are allowed but usually truncate at the match cap.
    \\- Use Bash only for read-only operations (ls, git status, git log, git diff, find); never use it for file creation or modification.
    \\- When WebSearch or FetchURL is available, use it when a question needs external context (library documentation, error messages, upstream APIs); the local codebase remains your primary domain.
    \\- Adapt your search depth based on the thoroughness level specified by the caller.
    \\
    \\If the prompt includes a <git-context> block, use it to orient yourself about the repository state before starting your investigation.
    \\
    \\You are meant to be a fast agent. Complete the search request efficiently and report your findings clearly in a structured format.
;
const tower_worker_tools = [_][]const u8{
    "Bash",
    "TowerComplete",
    "TowerFinding",
    "TowerInbox",
    "TowerMission",
    "TowerReview",
    "TowerSend",
    "TowerStatus",
    "CronCreate",
    "CronDelete",
    "CronList",
    "edit_file",
    "glob_files",
    "grep_files",
    "read_file",
    "Skill",
    "TaskList",
    "TaskOutput",
    "TaskStop",
    "TodoList",
    "NotifyUser",
    "WaitFor",
    "WebSearch",
    "FetchURL",
    "write_file",
    "vision",
    "mcp__*",
};
const task_agent_role_prefix =
    "You are a subagent; the main agent is your caller and all `user` messages come from it. The main agent sees only your final message. Do not ask the end user questions; explain ambiguities in your final handoff.";
const tower_worker_overlay =
    \\You are a tower worker/reviewer in a multi-agent tower workspace. All collaboration protocol traffic (inbox messages, findings, reviews, mission updates) goes through the Tower* tools ONLY — never create, edit, or delete protocol artifacts under `.tower/comms/` by hand; hand-written protocol files break the merge gate. Your TowerSpawn briefing names your mission (worker) or review target (reviewer) — stay inside it.
    \\
    \\Stay responsive while you work. Inbox messages sent to you while you are running are steered into your current turn as injected user messages — when one arrives, read TowerInbox and act on it at the next step boundary instead of deferring it. Long-running Bash commands (installs, builds, full test suites — anything expected to take more than a minute) must run with `run_in_background=true`; rely on their completion notifications or natural progress boundaries instead of calling WaitFor routinely, and never poll with tight TaskOutput checks, so you remain responsive to steered messages. Call WaitFor only when your next action genuinely cannot proceed without the background command's result. The only exception is a command you cannot retry safely when interrupted — those you may run in the foreground, and you check TowerInbox immediately after.
;
pub const tower_worker_prompt = task_agent_role_prefix ++ "\n\n" ++ coder_prompt ++ "\n\n" ++ tower_worker_overlay;

const plan_prompt =
    \\If you lack sufficient codebase context, recommend an explore subagent for the remaining questions. Return:
    \\1. What you know
    \\2. Unanswered questions for explore
    \\3. A preliminary plan if questions remain, otherwise a final implementation plan
    \\
    \\You are read-only: do not run commands or modify files, even when general instructions say to make changes. Return the plan as your final message.
;

pub const Source = enum { home, project, builtin, plugin };
pub const plugin_name_separator = ':';
pub const Role = enum { main, subagent };
pub const PromptMode = enum { append, replace };

pub const IgnoredReason = enum {
    unknown_key,
    project_cannot_set_permissions,
};

pub const Ignored = struct {
    key: []const u8,
    reason: IgnoredReason,
};

pub const Profile = struct {
    name: []const u8,
    description: []const u8,
    source: Source,
    model: ?[]const u8 = null,
    effort: ?types.ReasoningEffort = null,
    permission_mode: ?types.PermissionMode = null,
    tools: ?[]const []const u8 = null,
    mcp_servers: ?[]const []const u8 = null,
    max_turns: ?usize = null,
    prompt: []const u8 = "",
    prompt_mode: PromptMode = .append,
    ignored: []const Ignored = &.{},
};

pub const Entry = struct {
    name: []const u8,
    description: []const u8,
    source: Source,
    tools: ?[]const []const u8 = null,
    subagent_type: bool = false,
};

pub const ParseError = error{ OutOfMemory, InvalidProfile };
pub const LoadError = error{ OutOfMemory, InvalidProfile, ProfileNotFound, ReadFailed };

pub const Roots = struct {
    home: ?[]const u8 = null,
    project: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    claude_home: ?[]const u8 = null,
    claude_project: ?[]const u8 = null,
    plugin_agents: []const plugin_contributions.Root = &.{},

    pub fn init(arena: Allocator, home: ?[]const u8, workspace_root: ?[]const u8) !Roots {
        return .{
            .plugin_agents = if (home) |path| try installedPluginAgentRoots(arena, path) else &.{},
            .claude_home = if (home) |path| try std.Io.Dir.path.join(arena, &.{ path, claude_dir_name, profile_paths.agents_dir_name }) else null,
            .claude_project = if (workspace_root) |root|
                try std.Io.Dir.path.join(arena, &.{ root, claude_dir_name, profile_paths.agents_dir_name })
            else
                null,
            .home = if (home) |path| try profile_paths.agentsDir(arena, path) else null,
            .project = if (workspace_root) |root|
                try std.Io.Dir.path.join(arena, &.{ root, profile_paths.root_dir_name, profile_paths.agents_dir_name })
            else
                null,
            .repository = workspace_root,
        };
    }

    fn fileRoot(self: Roots, source: Source, dir: []const u8) ?[]const u8 {
        return switch (source) {
            .project => self.repository orelse dir,
            .home, .builtin, .plugin => null,
        };
    }
};

fn installedPluginAgentRoots(arena: Allocator, home: []const u8) Allocator.Error![]const plugin_contributions.Root {
    const plugins = plugin_manager.list(arena, home) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    return plugin_contributions.agentRoots(arena, plugins);
}

pub const Held = struct {
    arena: ?std.heap.ArenaAllocator = null,
    profile: Profile = builtin(main_name).?,
    system_prompt: ?[]const u8 = null,

    pub fn replace(
        self: *Held,
        alloc: Allocator,
        roots_home: ?[]const u8,
        workspace_root: ?[]const u8,
        name: []const u8,
        base_prompt: []const u8,
        failure: *?[]u8,
    ) LoadError!void {
        var next = std.heap.ArenaAllocator.init(alloc);
        errdefer next.deinit();
        const arena = next.allocator();
        const roots = try Roots.init(arena, roots_home, workspace_root);
        var message: ?[]const u8 = null;
        const profile = load_profile: {
            break :load_profile load(arena, roots, name, &message) catch |err| {
                if (message) |text| failure.* = alloc.dupe(u8, text) catch null;
                return err;
            };
        };
        const prompt = try systemPrompt(arena, &profile, base_prompt);
        self.deinit();
        self.* = .{
            .arena = next,
            .profile = profile,
            .system_prompt = if (prompt.ptr == base_prompt.ptr) null else prompt,
        };
    }

    pub fn deinit(self: *Held) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    const colon = std.mem.findScalar(u8, name, plugin_name_separator) orelse return validSegment(name);
    if (!validPluginId(name[0..colon])) return false;
    var segments = std.mem.splitScalar(u8, name[colon + 1 ..], plugin_name_separator);
    while (segments.next()) |segment| {
        if (!validSegment(segment)) return false;
    }
    return true;
}

fn validSegment(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    for (name) |byte| switch (byte) {
        'a'...'z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

fn validPluginId(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |byte| switch (byte) {
        'a'...'z', '0'...'9', '-', '_', '.', '@' => {},
        else => return false,
    };
    return true;
}

pub fn builtin(name: []const u8) ?Profile {
    if (std.mem.eql(u8, name, main_name)) return .{
        .name = main_name,
        .description = "fx itself, with every tool",
        .source = .builtin,
    };
    if (std.mem.eql(u8, name, agent_name)) return .{
        .name = agent_name,
        .description = "A copy of the agent that starts it",
        .source = .builtin,
    };
    if (std.mem.eql(u8, name, coder_name)) return .{
        .name = coder_name,
        .description = "General software engineering agent — the only subagent type with file-editing tools; use it for any delegated task that must modify code.",
        .source = .builtin,
        .tools = &coder_tools,
        .prompt = coder_prompt,
    };
    if (std.mem.eql(u8, name, explore_name)) return .{
        .name = explore_name,
        .description = "Fast codebase exploration with prompt-enforced read-only behavior.",
        .source = .builtin,
        .tools = &explore_tools,
        .prompt = explore_prompt,
    };
    if (std.mem.eql(u8, name, plan_name)) return .{
        .name = plan_name,
        .description = "Read-only implementation planning and architecture design.",
        .source = .builtin,
        .tools = &plan_tools,
        .prompt = plan_prompt,
    };
    if (std.mem.eql(u8, name, tower_worker_name)) return .{
        .name = tower_worker_name,
        .description = "Tower worker/reviewer agent — executes one tower mission in its own git worktree (or reviews one branch), coordinating only through Tower* tools. Spawned via the TowerSpawn tool.",
        .source = .builtin,
        .tools = &tower_worker_tools,
        .prompt = tower_worker_prompt,
    };
    return null;
}

pub fn parse(
    arena: Allocator,
    name: []const u8,
    source: Source,
    settings_json: []const u8,
    prompt: []const u8,
    failure: *?[]const u8,
) ParseError!Profile {
    if (!validName(name)) return fail(arena, failure, "profile name '{s}' must use lowercase letters, digits, '-', or '_'", .{name});
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, settings_json, .{}) catch
        return fail(arena, failure, "profile '{s}': {s} is not valid JSON", .{ name, settings_file_name });
    if (root != .object) return fail(arena, failure, "profile '{s}': {s} must be a JSON object", .{ name, settings_file_name });

    var profile: Profile = .{ .name = name, .description = "", .source = source, .prompt = prompt };
    var ignored: std.ArrayList(Ignored) = .empty;
    var disallowed_tools: ?[]const []const u8 = null;
    var it = root.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "description")) {
            profile.description = try stringField(arena, failure, name, key, value);
        } else if (std.mem.eql(u8, key, "model")) {
            profile.model = try stringField(arena, failure, name, key, value);
        } else if (std.mem.eql(u8, key, "effort")) {
            const raw = try stringField(arena, failure, name, key, value);
            profile.effort = types.ReasoningEffort.parse(raw) orelse
                return fail(arena, failure, "profile '{s}': unknown effort '{s}'", .{ name, raw });
        } else if (std.mem.eql(u8, key, "permission_mode") or std.mem.eql(u8, key, "permissionMode")) {
            if (source == .project) {
                try ignored.append(arena, .{ .key = key, .reason = .project_cannot_set_permissions });
                continue;
            }
            const raw = try stringField(arena, failure, name, key, value);
            profile.permission_mode = types.PermissionMode.parse(raw) orelse
                return fail(arena, failure, "profile '{s}': unknown permission_mode '{s}'", .{ name, raw });
        } else if (std.mem.eql(u8, key, "tools")) {
            profile.tools = try nameList(arena, failure, name, key, value);
        } else if (std.mem.eql(u8, key, "disallowedTools") or std.mem.eql(u8, key, "disallowed_tools")) {
            disallowed_tools = try nameList(arena, failure, name, key, value);
        } else if (std.mem.eql(u8, key, "maxTurns") or std.mem.eql(u8, key, "max_turns")) {
            if (value != .integer or value.integer < 1)
                return fail(arena, failure, "profile '{s}': {s} must be a positive whole number", .{ name, key });
            const turns: usize = @intCast(value.integer);
            profile.max_turns = turns;
        } else if (std.mem.eql(u8, key, "mcp_servers")) {
            profile.mcp_servers = try nameList(arena, failure, name, key, value);
        } else if (std.mem.eql(u8, key, "prompt")) {
            const raw = try stringField(arena, failure, name, key, value);
            profile.prompt_mode = std.meta.stringToEnum(PromptMode, raw) orelse
                return fail(arena, failure, "profile '{s}': prompt must be 'append' or 'replace'", .{name});
        } else {
            try ignored.append(arena, .{ .key = key, .reason = .unknown_key });
        }
    }
    if (profile.description.len == 0) return fail(arena, failure, "profile '{s}' needs a description", .{name});
    if (disallowed_tools) |refused| profile.tools = try toolsWithout(arena, profile.tools, refused);
    profile.ignored = ignored.items;
    return profile;
}

const every_tool = [_][]const u8{wildcard};
const withheld_from_markdown_subagents = [_][]const u8{
    "!" ++ subagent_tool,
    "!AgentSwarm",
    "!AskUserQuestion",
    "!EnterPlanMode",
    "!ExitPlanMode",
};

fn toolsWithout(arena: Allocator, allowed: ?[]const []const u8, refused: []const []const u8) Allocator.Error![]const []const u8 {
    const base: []const []const u8 = allowed orelse &every_tool;
    const out = try arena.alloc([]const u8, base.len + refused.len);
    @memcpy(out[0..base.len], base);
    for (refused, out[base.len..]) |tool, *slot| {
        slot.* = if (tool[0] == '!') tool else try std.fmt.allocPrint(arena, "!{s}", .{tool});
    }
    return out;
}

pub const verb_carrier_tool = "run_code";

pub fn allowsTool(profile: *const Profile, tool: []const u8) bool {
    if (std.mem.eql(u8, tool, verb_carrier_tool)) return true;
    const tools = profile.tools orelse return true;
    if (toolListAllows(tools, tool)) return true;
    return isMcpLoaderTool(tool) and admitsMcpTools(tools) and !toolListRefuses(tools, tool);
}

fn isMcpLoaderTool(tool: []const u8) bool {
    for (mcp_loader_tools) |loader| if (std.mem.eql(u8, loader, tool)) return true;
    return false;
}

fn admitsMcpTools(entries: []const []const u8) bool {
    for (entries) |entry| {
        if (entry.len > 1 and entry[0] == '!') continue;
        if (std.mem.startsWith(u8, entry, mcp_tool_prefix)) return true;
    }
    return false;
}

fn toolListRefuses(entries: []const []const u8, name: []const u8) bool {
    for (entries) |entry| {
        if (entry.len > 1 and entry[0] == '!' and toolPatternMatches(entry[1..], name)) return true;
    }
    return false;
}

pub fn allowedSubagentType(profile: *const Profile) bool {
    if (profile.source == .builtin) return isBuiltinSubagentType(profile.name);
    return !allowsTool(profile, subagent_tool);
}

fn isBuiltinSubagentType(name: []const u8) bool {
    return std.mem.eql(u8, name, coder_name) or std.mem.eql(u8, name, explore_name) or std.mem.eql(u8, name, plan_name);
}

pub fn allowsMcpServer(profile: *const Profile, server: []const u8) bool {
    const servers = profile.mcp_servers orelse return true;
    return listAllows(servers, server, false);
}

pub fn setsTools(profile: *const Profile) bool {
    return profile.tools != null;
}

pub fn setsMcpServers(profile: *const Profile) bool {
    return profile.mcp_servers != null;
}

pub fn stepLimit(profile: *const Profile, inherited: usize) usize {
    const cap = profile.max_turns orelse return inherited;
    return if (inherited == 0) cap else @min(inherited, cap);
}

test "a profile's maxTurns caps its steps below the inherited limit and bounds an unlimited one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const capped = try testParse(arena_state.allocator(), .home,
        \\{"description": "Capped", "maxTurns": 12}
    , "");
    try testing.expectEqual(@as(?usize, 12), capped.max_turns);
    try testing.expectEqual(@as(usize, 0), capped.ignored.len);
    try testing.expectEqual(@as(usize, 12), stepLimit(&capped, 0));
    try testing.expectEqual(@as(usize, 12), stepLimit(&capped, 40));
    try testing.expectEqual(@as(usize, 5), stepLimit(&capped, 5));
    const snake = try testParse(arena_state.allocator(), .home,
        \\{"description": "Snake", "max_turns": 3}
    , "");
    try testing.expectEqual(@as(?usize, 3), snake.max_turns);
    const open = try testParse(arena_state.allocator(), .home,
        \\{"description": "Open"}
    , "");
    try testing.expectEqual(@as(usize, 0), stepLimit(&open, 0));
    try testing.expectEqual(@as(usize, 40), stepLimit(&open, 40));
    try testing.expectError(error.InvalidProfile, testParse(arena_state.allocator(), .home,
        \\{"description": "Zero", "maxTurns": 0}
    , ""));
    try testing.expectError(error.InvalidProfile, testParse(arena_state.allocator(), .home,
        \\{"description": "Text", "maxTurns": "many"}
    , ""));
}

pub fn permissionMode(profile: *const Profile, parent: types.PermissionMode) types.PermissionMode {
    return profile.permission_mode orelse parent;
}

pub fn systemPrompt(arena: Allocator, profile: *const Profile, base: []const u8) ![]const u8 {
    const own = std.mem.trim(u8, profile.prompt, " \t\r\n");
    if (own.len == 0) return base;
    return switch (profile.prompt_mode) {
        .replace => own,
        .append => try arena.print("{s}\n\n{s}", .{ base, own }),
    };
}

pub fn load(arena: Allocator, roots: Roots, name: []const u8, failure: *?[]const u8) LoadError!Profile {
    const canonical = canonicalName(name);
    const aliased = canonical.ptr != name.ptr;
    if (aliased and !validName(name)) return load(arena, roots, canonical, failure);
    if (!validName(name)) return fail(arena, failure, "profile name '{s}' must use lowercase letters, digits, '-', or '_'", .{name});
    if (std.mem.eql(u8, name, main_name)) return builtin(main_name).?;
    if (std.mem.findScalar(u8, name, plugin_name_separator)) |colon| return loadPluginAgent(arena, roots, name, colon, failure);

    const owned = try arena.dupe(u8, name);
    if (roots.home) |dir| if (try readProfile(arena, dir, owned, .home, roots.fileRoot(.home, dir), failure)) |profile| return profile;
    if (roots.project) |dir| if (try readProfile(arena, dir, owned, .project, roots.fileRoot(.project, dir), failure)) |profile| return profile;
    if (roots.claude_home) |dir| if (try readProfile(arena, dir, owned, .home, roots.fileRoot(.home, dir), failure)) |profile| return profile;
    if (roots.claude_project) |dir| if (try readProfile(arena, dir, owned, .project, roots.fileRoot(.project, dir), failure)) |profile| return profile;
    if (builtin(name)) |profile| return profile;
    if (aliased) return load(arena, roots, canonical, failure);
    const names = try listNames(arena, roots);
    failure.* = try arena.print("no profile named '{s}'. Profiles: {s}", .{ name, names });
    return error.ProfileNotFound;
}

pub fn list(arena: Allocator, roots: Roots) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    const sources = [_]struct { dir: ?[]const u8, source: Source }{
        .{ .dir = roots.home, .source = .home },
        .{ .dir = roots.project, .source = .project },
        .{ .dir = roots.claude_home, .source = .home },
        .{ .dir = roots.claude_project, .source = .project },
    };
    for (sources) |root| {
        const dir_path = root.dir orelse continue;
        var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io_mod.getIo());
        var it = dir.iterate();
        while (it.next(io_mod.getIo()) catch null) |item| {
            const item_name: []const u8 = switch (item.kind) {
                .directory => item.name,
                .file => if (std.mem.endsWith(u8, item.name, markdown_agent.extension))
                    item.name[0 .. item.name.len - markdown_agent.extension.len]
                else
                    continue,
                else => continue,
            };
            if (!validSegment(item_name)) continue;
            if (std.mem.eql(u8, item_name, main_name)) continue;
            if (hasEntry(entries.items, item_name)) continue;
            const name = try arena.dupe(u8, item_name);
            var failure: ?[]const u8 = null;
            const profile = (readProfile(arena, dir_path, name, root.source, roots.fileRoot(root.source, dir_path), &failure) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            }) orelse continue;
            try entries.append(arena, entryOf(profile));
        }
    }
    for ([_][]const u8{ main_name, agent_name, coder_name, explore_name, plan_name, tower_worker_name }) |name| {
        if (hasEntry(entries.items, name)) continue;
        try entries.append(arena, entryOf(builtin(name).?));
    }
    for (roots.plugin_agents) |root| try appendPluginAgents(arena, &entries, root, root.path, root.plugin_id);
    sort_utils.sort(Entry, entries.items, {}, entryLessThan);
    return entries.items;
}

fn appendPluginAgents(
    arena: Allocator,
    entries: *std.ArrayList(Entry),
    root: plugin_contributions.Root,
    dir_path: []const u8,
    prefix: []const u8,
) Allocator.Error!void {
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io_mod.getIo());
    var it = dir.iterate();
    while (it.next(io_mod.getIo()) catch null) |item| {
        switch (item.kind) {
            .directory => {
                if (!validSegment(item.name)) continue;
                const child_dir = try std.Io.Dir.path.join(arena, &.{ dir_path, item.name });
                const child_prefix = try arena.print("{s}:{s}", .{ prefix, item.name });
                try appendPluginAgents(arena, entries, root, child_dir, child_prefix);
            },
            .file => {
                if (!std.mem.endsWith(u8, item.name, markdown_agent.extension)) continue;
                const stem = item.name[0 .. item.name.len - markdown_agent.extension.len];
                const name = try arena.print("{s}:{s}", .{ prefix, stem });
                if (!validName(name) or hasEntry(entries.items, name)) continue;
                var failure: ?[]const u8 = null;
                const colon = root.plugin_id.len;
                const profile = loadPluginAgent(arena, .{ .plugin_agents = &.{root} }, name, colon, &failure) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                try entries.append(arena, entryOf(profile));
            },
            else => {},
        }
    }
}

fn loadPluginAgent(arena: Allocator, roots: Roots, name: []const u8, colon: usize, failure: *?[]const u8) LoadError!Profile {
    const plugin_id = name[0..colon];
    const relative = try std.mem.replaceOwned(u8, arena, name[colon + 1 ..], ":", "/");
    const file_name = try arena.print("{s}{s}", .{ relative, markdown_agent.extension });
    for (roots.plugin_agents) |root| {
        if (!std.mem.eql(u8, root.plugin_id, plugin_id)) continue;
        const file_path = try std.Io.Dir.path.join(arena, &.{ root.path, file_name });
        const text = readFile(arena, file_path, max_prompt_bytes, root.path) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.OutOfMemory => return error.OutOfMemory,
            else => return fail(arena, failure, "profile '{s}': cannot read {s}: {s}", .{ name, file_path, try readFailure(arena, err, max_prompt_bytes) }),
        };
        var profile = parseMarkdown(arena, try arena.dupe(u8, name), .plugin, text, failure) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidProfile => return error.InvalidProfile,
        };
        profile.mcp_servers = null;
        return profile;
    }
    failure.* = try arena.print("no plugin agent named '{s}'", .{name});
    return error.ProfileNotFound;
}

fn entryOf(profile: Profile) Entry {
    return .{
        .name = profile.name,
        .description = profile.description,
        .source = profile.source,
        .tools = profile.tools,
        .subagent_type = allowedSubagentType(&profile),
    };
}

pub fn subagentTypeNames(arena: Allocator, entries: []const Entry) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (entries) |entry| {
        if (!entry.subagent_type) continue;
        if (out.items.len > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, entry.name);
    }
    return out.items;
}

fn listNames(arena: Allocator, roots: Roots) ![]const u8 {
    const entries = try list(arena, roots);
    var out: std.ArrayList(u8) = .empty;
    for (entries, 0..) |entry, index| {
        if (index > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, entry.name);
    }
    return out.items;
}

fn hasEntry(entries: []const Entry, name: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry.name, name)) return true;
    return false;
}

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn readProfile(
    arena: Allocator,
    dir: []const u8,
    name: []const u8,
    source: Source,
    within: ?[]const u8,
    failure: *?[]const u8,
) LoadError!?Profile {
    const settings_path = try std.Io.Dir.path.join(arena, &.{ dir, name, settings_file_name });
    const settings = readFile(arena, settings_path, max_settings_bytes, within) catch |err| switch (err) {
        error.FileNotFound => return readMarkdownProfile(arena, dir, name, source, within, failure),
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(arena, failure, "profile '{s}': cannot read {s}: {s}", .{ name, settings_path, try readFailure(arena, err, max_settings_bytes) }),
    };
    const prompt_path = try std.Io.Dir.path.join(arena, &.{ dir, name, prompt_file_name });
    const prompt = readFile(arena, prompt_path, max_prompt_bytes, within) catch |err| switch (err) {
        error.FileNotFound => "",
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(arena, failure, "profile '{s}': cannot read {s}: {s}", .{ name, prompt_path, try readFailure(arena, err, max_prompt_bytes) }),
    };
    return parse(arena, name, source, settings, prompt, failure) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidProfile => error.InvalidProfile,
    };
}

fn readMarkdownProfile(
    arena: Allocator,
    dir: []const u8,
    name: []const u8,
    source: Source,
    within: ?[]const u8,
    failure: *?[]const u8,
) LoadError!?Profile {
    const file_name = try arena.print("{s}{s}", .{ name, markdown_agent.extension });
    const file_path = try std.Io.Dir.path.join(arena, &.{ dir, file_name });
    const text = readFile(arena, file_path, max_prompt_bytes, within) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(arena, failure, "profile '{s}': cannot read {s}: {s}", .{ name, file_path, try readFailure(arena, err, max_prompt_bytes) }),
    };
    return parseMarkdown(arena, name, source, text, failure) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidProfile => error.InvalidProfile,
    };
}

pub fn parseMarkdown(
    arena: Allocator,
    name: []const u8,
    source: Source,
    text: []const u8,
    failure: *?[]const u8,
) ParseError!Profile {
    if (!validName(name)) return fail(arena, failure, "profile name '{s}' must use lowercase letters, digits, '-', or '_'", .{name});
    const document = try markdown_agent.parse(arena, text);
    var profile: Profile = .{ .name = name, .description = "", .source = source, .prompt = document.body };
    var ignored: std.ArrayList(Ignored) = .empty;
    var refused: []const []const u8 = &.{};
    for (document.fields) |field| {
        const key = field.key;
        if (std.mem.eql(u8, key, "name")) {
            continue;
        } else if (std.mem.eql(u8, key, "description")) {
            profile.description = field.value;
        } else if (std.mem.eql(u8, key, "model")) {
            if (field.value.len > 0 and !std.ascii.eqlIgnoreCase(field.value, "inherit")) profile.model = field.value;
        } else if (std.mem.eql(u8, key, "effort")) {
            profile.effort = types.ReasoningEffort.parse(field.value) orelse
                return fail(arena, failure, "profile '{s}': unknown effort '{s}'", .{ name, field.value });
        } else if (std.mem.eql(u8, key, "permission_mode") or std.mem.eql(u8, key, "permissionMode")) {
            if (source == .project or source == .plugin) {
                try ignored.append(arena, .{ .key = key, .reason = .project_cannot_set_permissions });
                continue;
            }
            profile.permission_mode = types.PermissionMode.parse(field.value) orelse
                return fail(arena, failure, "profile '{s}': unknown permission_mode '{s}'", .{ name, field.value });
        } else if (std.mem.eql(u8, key, "tools")) {
            profile.tools = try markdown_agent.fxToolNames(arena, try markdown_agent.names(arena, field), false);
        } else if (std.mem.eql(u8, key, "disallowedTools") or std.mem.eql(u8, key, "disallowed_tools")) {
            refused = try markdown_agent.fxToolNames(arena, try markdown_agent.names(arena, field), true);
        } else if (std.mem.eql(u8, key, "maxTurns") or std.mem.eql(u8, key, "max_turns")) {
            const turns = std.fmt.parseUnsigned(usize, std.mem.trim(u8, field.value, " \t"), 10) catch 0;
            if (turns == 0) return fail(arena, failure, "profile '{s}': {s} must be a positive whole number", .{ name, key });
            profile.max_turns = turns;
        } else if (std.mem.eql(u8, key, "mcp_servers") or std.mem.eql(u8, key, "mcpServers")) {
            var referenced: std.ArrayList([]const u8) = .empty;
            var inline_definitions = false;
            for (try markdown_agent.names(arena, field)) |server| {
                if (std.mem.findScalar(u8, server, ':') == null) {
                    try referenced.append(arena, server);
                } else {
                    inline_definitions = true;
                }
            }
            if (inline_definitions) try ignored.append(arena, .{ .key = key, .reason = .unknown_key });
            profile.mcp_servers = referenced.items;
        } else if (std.mem.eql(u8, key, "prompt")) {
            profile.prompt_mode = std.meta.stringToEnum(PromptMode, field.value) orelse
                return fail(arena, failure, "profile '{s}': prompt must be 'append' or 'replace'", .{name});
        } else {
            try ignored.append(arena, .{ .key = key, .reason = .unknown_key });
        }
    }
    if (profile.description.len == 0) return fail(arena, failure, "profile '{s}' needs a description", .{name});
    const delegates = if (profile.tools) |tools| toolListAllows(tools, subagent_tool) else false;
    if (refused.len > 0 or !delegates) {
        const without_delegation: []const []const u8 = if (delegates) refused else try std.mem.concat(arena, []const u8, &.{ refused, &withheld_from_markdown_subagents });
        profile.tools = try toolsWithout(arena, profile.tools, without_delegation);
    }
    profile.ignored = ignored.items;
    return profile;
}

fn readFailure(arena: Allocator, err: anyerror, max_bytes: usize) Allocator.Error![]const u8 {
    return switch (err) {
        error.StreamTooLong => if (max_bytes == max_prompt_bytes)
            "it is larger than the 256 KiB a profile file may hold"
        else
            "it is larger than the 64 KiB a profile file may hold",
        error.AccessDenied, error.PermissionDenied => "fx isn't allowed to read it",
        error.IsDir => "it is a folder, not a file",
        error.NotRegularFile => "it isn't a regular file",
        error.OutsideRepository => "it links outside the repository, and a repository's profile may read only its own files",
        else => try arena.print("the file couldn't be read ({s})", .{@errorName(err)}),
    };
}

test "profile read failures name the limit or the cause instead of an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(std.mem.find(u8, try readFailure(arena, error.StreamTooLong, max_prompt_bytes), "256 KiB") != null);
    try std.testing.expect(std.mem.find(u8, try readFailure(arena, error.StreamTooLong, max_settings_bytes), "64 KiB") != null);
    try std.testing.expectEqualStrings("it is a folder, not a file", try readFailure(arena, error.IsDir, max_prompt_bytes));
    try std.testing.expectEqualStrings("the file couldn't be read (SymLinkLoop)", try readFailure(arena, error.SymLinkLoop, max_prompt_bytes));
}

test "profile parsing stays bounded on fuzzed settings and prompts" {
    try std.testing.fuzz({}, fuzzProfileParse, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "{}",
            "{\"tools\": [\"read_file\"], \"prompt\": \"replace\"}",
            "{\"mcp_servers\": [\"*\"], \"model\": \"openai/gpt-5\", \"effort\": \"low\"}",
            "{\"tools\": 3, \"unknown\": null}",
            "\xff\x00{",
        }) ++ @import("fuzz_corpus").profile_parse.*),
    });
}

fn fuzzProfileParse(_: void, smith: *std.testing.Smith) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var settings_buffer: [4096]u8 = undefined;
    const settings = settings_buffer[0..@intCast(smith.slice(&settings_buffer))];
    var prompt_buffer: [512]u8 = undefined;
    const prompt = prompt_buffer[0..@intCast(smith.slice(&prompt_buffer))];
    var failure: ?[]const u8 = null;
    const profile = parse(arena.allocator(), "fuzz", .project, settings, prompt, &failure) catch |err| switch (err) {
        error.InvalidProfile => return std.testing.expect(failure != null),
        error.OutOfMemory => return err,
    };
    try std.testing.expectEqualStrings("fuzz", profile.name);
}

fn readFile(arena: Allocator, path: []const u8, max_bytes: usize, within: ?[]const u8) ![]u8 {
    const io = io_mod.getIo();
    const target = try io_mod.realpathAlloc(arena, path);
    if (within) |root_path| {
        const root = try io_mod.realpathAlloc(arena, root_path);
        if (!pathing.pathInside(root, target)) return error.OutsideRepository;
    }

    const stat = try std.Io.Dir.cwd().statFile(io, target, .{ .follow_symlinks = false });
    switch (stat.kind) {
        .file => {},
        .directory => return error.IsDir,
        else => return error.NotRegularFile,
    }
    var file = try std.Io.Dir.openFileAbsolute(io, target, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io);

    if ((try file.stat(io)).kind != .file) return error.NotRegularFile;
    return io_mod.readFileToEnd(arena, &file, max_bytes);
}

test {
    _ = markdown_agent;
}

fn linkTestFile(dir: std.Io.Dir, target: []const u8, sub_path: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| try dir.createDirPath(io_mod.getIo(), parent);
    try dir.symLink(io_mod.getIo(), target, sub_path, .{ .is_directory = false });
}

fn writeTestFile(dir: std.Io.Dir, sub_path: []const u8, bytes: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| try dir.createDirPath(io_mod.getIo(), parent);
    var file = try dir.createFile(io_mod.getIo(), sub_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), bytes);
}

test "a repository's profile reads only files inside the repository" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "outside/secret.txt", "SECRET");
    try writeTestFile(tmp.dir, "repo/prompts/review.md", "Review only.");
    const outside_secret = try io_mod.dirRealpathAlloc(arena, tmp.dir, "outside/secret.txt");
    const inside_prompt = try io_mod.dirRealpathAlloc(arena, tmp.dir, "repo/prompts/review.md");
    try writeTestProfile(tmp.dir, "repo/.fx/agents/evil", "{\"description\": \"Evil\"}");
    try linkTestFile(tmp.dir, outside_secret, "repo/.fx/agents/evil/prompt.md");
    try writeTestProfile(tmp.dir, "repo/.fx/agents/shared", "{\"description\": \"Shared prompt\"}");
    try linkTestFile(tmp.dir, inside_prompt, "repo/.fx/agents/shared/prompt.md");
    try writeTestFile(tmp.dir, "outside/settings/profile.json", "{\"description\": \"Elsewhere\"}");
    try linkTestFile(tmp.dir, try io_mod.dirRealpathAlloc(arena, tmp.dir, "outside/settings/profile.json"), "repo/.fx/agents/far/profile.json");
    const roots = try Roots.init(arena, null, try io_mod.dirRealpathAlloc(arena, tmp.dir, "repo"));

    var failure: ?[]const u8 = null;
    try testing.expectError(error.InvalidProfile, load(arena, roots, "evil", &failure));
    try testing.expect(std.mem.find(u8, failure.?, "links outside the repository") != null);
    try testing.expectError(error.InvalidProfile, load(arena, roots, "far", &failure));
    try testing.expect(std.mem.find(u8, failure.?, "links outside the repository") != null);

    const shared = try load(arena, roots, "shared", &failure);
    try testing.expectEqualStrings("Review only.", shared.prompt);

    const entries = try list(arena, roots);
    for (entries) |entry| try testing.expect(!std.mem.eql(u8, entry.name, "evil") and !std.mem.eql(u8, entry.name, "far"));
}

test "a profile reads only regular files, and the user's own may link anywhere" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "dotfiles/review.md", "Review only.");
    try writeTestProfile(tmp.dir, "home/linked", "{\"description\": \"Linked\"}");
    try linkTestFile(tmp.dir, try io_mod.dirRealpathAlloc(arena, tmp.dir, "dotfiles/review.md"), "home/linked/prompt.md");
    try writeTestProfile(tmp.dir, "home/device", "{\"description\": \"Device\"}");
    try linkTestFile(tmp.dir, "/dev/null", "home/device/prompt.md");
    try writeTestProfile(tmp.dir, "home/folder", "{\"description\": \"Folder\"}");
    try tmp.dir.createDirPath(io_mod.getIo(), "home/folder/prompt.md");
    const roots: Roots = .{ .home = try io_mod.dirRealpathAlloc(arena, tmp.dir, "home") };

    var failure: ?[]const u8 = null;
    const linked = try load(arena, roots, "linked", &failure);
    try testing.expectEqualStrings("Review only.", linked.prompt);
    try testing.expectError(error.InvalidProfile, load(arena, roots, "device", &failure));
    try testing.expect(std.mem.find(u8, failure.?, "isn't a regular file") != null);
    try testing.expectError(error.InvalidProfile, load(arena, roots, "folder", &failure));
    try testing.expect(std.mem.find(u8, failure.?, "it is a folder, not a file") != null);
}

fn toolListAllows(entries: []const []const u8, name: []const u8) bool {
    var allowed = false;
    for (entries) |entry| {
        if (entry.len > 1 and entry[0] == '!') {
            if (toolPatternMatches(entry[1..], name)) return false;
        } else if (toolPatternMatches(entry, name)) {
            allowed = true;
        }
    }
    return allowed;
}

fn toolPatternMatches(pattern: []const u8, name: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, wildcard)) {
        return std.mem.startsWith(u8, name, pattern[0 .. pattern.len - wildcard.len]);
    }
    return std.mem.eql(u8, pattern, name);
}

fn listAllows(entries: []const []const u8, name: []const u8, wildcard_skips: bool) bool {
    var allowed = false;
    for (entries) |entry| {
        if (entry.len > 1 and entry[0] == '!') {
            if (std.mem.eql(u8, entry[1..], name)) return false;
        } else if (std.mem.eql(u8, entry, wildcard)) {
            if (!wildcard_skips) allowed = true;
        } else if (std.mem.eql(u8, entry, name)) {
            allowed = true;
        }
    }
    return allowed;
}

fn stringField(arena: Allocator, failure: *?[]const u8, name: []const u8, key: []const u8, value: std.json.Value) ParseError![]const u8 {
    if (value != .string or value.string.len == 0)
        return fail(arena, failure, "profile '{s}': {s} must be a non-empty string", .{ name, key });
    return value.string;
}

fn nameList(arena: Allocator, failure: *?[]const u8, name: []const u8, key: []const u8, value: std.json.Value) ParseError![]const []const u8 {
    if (value != .array) return fail(arena, failure, "profile '{s}': {s} must be a list of names", .{ name, key });
    const out = try arena.alloc([]const u8, value.array.items.len);
    for (value.array.items, out) |item, *slot| {
        if (item != .string or item.string.len == 0 or item.string.len > max_list_entry_bytes)
            return fail(arena, failure, "profile '{s}': {s} must be a list of names", .{ name, key });
        slot.* = item.string;
    }
    return out;
}

fn fail(arena: Allocator, failure: *?[]const u8, comptime fmt: []const u8, args: anytype) error{ OutOfMemory, InvalidProfile } {
    failure.* = try arena.print(fmt, args);
    return error.InvalidProfile;
}

const testing = std.testing;

fn testParse(arena: Allocator, source: Source, json: []const u8, prompt: []const u8) !Profile {
    var failure: ?[]const u8 = null;
    return parse(arena, "reviewer", source, json, prompt, &failure);
}

test "a profile's settings, tools, and prompt parse from profile.json and prompt.md" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const profile = try testParse(arena_state.allocator(), .home,
        \\{"description": "Reviews pull requests", "model": "test/model", "effort": "high",
        \\ "permission_mode": "ask", "tools": ["read_file", "grep_files"], "mcp_servers": ["github"],
        \\ "prompt": "replace"}
    , "Review only.");
    try testing.expectEqualStrings("Reviews pull requests", profile.description);
    try testing.expectEqualStrings("test/model", profile.model.?);
    try testing.expect(profile.effort.?.eql(types.ReasoningEffort.literal("high")));
    try testing.expectEqual(types.PermissionMode.ask, profile.permission_mode.?);
    try testing.expectEqual(PromptMode.replace, profile.prompt_mode);
    try testing.expect(allowsTool(&profile, "read_file"));
    try testing.expect(!allowsTool(&profile, "write_file"));
    try testing.expect(allowsTool(&profile, verb_carrier_tool));
    try testing.expect(allowsMcpServer(&profile, "github"));
    try testing.expect(!allowsMcpServer(&profile, "slack"));
    try testing.expectEqual(@as(usize, 0), profile.ignored.len);
}

test "a repository's profile cannot set the permission mode, and unknown keys are reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const profile = try testParse(arena_state.allocator(), .project,
        \\{"description": "Repo agent", "permission_mode": "full-access", "colour": "blue"}
    , "");
    try testing.expect(profile.permission_mode == null);
    try testing.expectEqual(types.PermissionMode.ask, permissionMode(&profile, .ask));
    try testing.expectEqual(@as(usize, 2), profile.ignored.len);
    try testing.expectEqualStrings("permission_mode", profile.ignored[0].key);
    try testing.expectEqual(IgnoredReason.project_cannot_set_permissions, profile.ignored[0].reason);
    try testing.expectEqual(IgnoredReason.unknown_key, profile.ignored[1].reason);
}

test "the user's own profile sets the mode, and a profile without one inherits its parent's" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const own = try testParse(arena_state.allocator(), .home,
        \\{"description": "Fast", "permission_mode": "auto"}
    , "");
    try testing.expectEqual(types.PermissionMode.auto, permissionMode(&own, .ask));
    const plain = try testParse(arena_state.allocator(), .home,
        \\{"description": "Plain"}
    , "");
    try testing.expectEqual(types.PermissionMode.yolo, permissionMode(&plain, .yolo));
}

test "a profile without a description, with bad JSON, or with a bad value is refused with a message" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { json: []const u8, message: []const u8 }{
        .{ .json = "{}", .message = "needs a description" },
        .{ .json = "{not json", .message = "is not valid JSON" },
        .{ .json = "[]", .message = "must be a JSON object" },
        .{ .json = "{\"description\": \"x\", \"effort\": 3}", .message = "effort must be a non-empty string" },
        .{ .json = "{\"description\": \"x\", \"tools\": \"read_file\"}", .message = "must be a list of names" },
        .{ .json = "{\"description\": \"x\", \"prompt\": \"prepend\"}", .message = "'append' or 'replace'" },
    };
    for (cases) |case| {
        var failure: ?[]const u8 = null;
        try testing.expectError(error.InvalidProfile, parse(arena, "reviewer", .home, case.json, "", &failure));
        try testing.expect(std.mem.find(u8, failure.?, case.message) != null);
    }
    var failure: ?[]const u8 = null;
    try testing.expectError(error.InvalidProfile, parse(arena, "Bad Name", .home, "{\"description\": \"x\"}", "", &failure));
}

test "fx's main and agent profiles decide nothing, so an agent in either copies its parent" {
    const main = builtin(main_name).?;
    const agent = builtin(agent_name).?;
    try testing.expect(allowsTool(&main, "Agent"));
    try testing.expect(allowsTool(&main, "write_file"));
    try testing.expect(allowsTool(&agent, "Agent"));
    try testing.expect(allowsTool(&agent, "write_file"));
    try testing.expect(!setsTools(&main) and !setsTools(&agent));
    try testing.expect(!setsMcpServers(&main) and !setsMcpServers(&agent));
    try testing.expect(main.permission_mode == null and agent.permission_mode == null);
    try testing.expect(builtin("reviewer") == null);
}

test "a profile's disallowedTools removes tools from its allowlist, or from every tool when no allowlist is set" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const denied = try testParse(arena_state.allocator(), .home,
        \\{"description": "Denied", "disallowedTools": ["Bash", "mcp__github__*"]}
    , "");
    try testing.expect(setsTools(&denied));
    try testing.expect(allowsTool(&denied, "read_file"));
    try testing.expect(!allowsTool(&denied, "Bash"));
    try testing.expect(!allowsTool(&denied, "mcp__github__delete"));
    const narrowed = try testParse(arena_state.allocator(), .home,
        \\{"disallowed_tools": ["grep_files"], "description": "Narrowed", "tools": ["read_file", "grep_files"]}
    , "");
    try testing.expect(allowsTool(&narrowed, "read_file"));
    try testing.expect(!allowsTool(&narrowed, "grep_files"));
    try testing.expect(!allowsTool(&narrowed, "Bash"));
    try testing.expectEqual(@as(usize, 0), narrowed.ignored.len);
    const camel_mode = try testParse(arena_state.allocator(), .home,
        \\{"description": "Camel", "permissionMode": "manual"}
    , "");
    try testing.expectEqual(types.PermissionMode.ask, camel_mode.permission_mode.?);
}

test "a profile's * covers every tool, Agent included, and only !Agent leaves it out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const all = try testParse(arena_state.allocator(), .home,
        \\{"description": "All", "tools": ["*", "!Bash"]}
    , "");
    try testing.expect(allowsTool(&all, "read_file"));
    try testing.expect(!allowsTool(&all, "Bash"));
    try testing.expect(allowsTool(&all, "Agent"));
    const leaf = try testParse(arena_state.allocator(), .home,
        \\{"description": "Leaf", "tools": ["*", "!Agent"]}
    , "");
    try testing.expect(!allowsTool(&leaf, "Agent"));
    try testing.expect(allowsTool(&leaf, "read_file"));
    const none = try testParse(arena_state.allocator(), .home,
        \\{"description": "None", "tools": []}
    , "");
    try testing.expect(!allowsTool(&none, "read_file"));
    try testing.expect(setsTools(&none));
    const unset = try testParse(arena_state.allocator(), .home,
        \\{"description": "Unset"}
    , "");
    try testing.expect(!setsTools(&unset) and !setsMcpServers(&unset));
    try testing.expect(allowsTool(&unset, "Bash"));
}

test "a profile's prompt adds to fx's prompt, or replaces it when the profile says so" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const append = try testParse(arena, .home, "{\"description\": \"x\"}", "  Review only.\n");
    try testing.expectEqualStrings("BASE\n\nReview only.", try systemPrompt(arena, &append, "BASE"));
    const replace = try testParse(arena, .home, "{\"description\": \"x\", \"prompt\": \"replace\"}", "Review only.");
    try testing.expectEqualStrings("Review only.", try systemPrompt(arena, &replace, "BASE"));
    const empty = try testParse(arena, .home, "{\"description\": \"x\", \"prompt\": \"replace\"}", "\n");
    try testing.expectEqualStrings("BASE", try systemPrompt(arena, &empty, "BASE"));
}

fn writeTestProfile(dir: std.Io.Dir, sub_path: []const u8, json: []const u8) !void {
    try dir.createDirPath(io_mod.getIo(), sub_path);
    const file_path = try std.Io.Dir.path.join(testing.allocator, &.{ sub_path, settings_file_name });
    defer testing.allocator.free(file_path);
    var file = try dir.createFile(io_mod.getIo(), file_path, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), json);
}

test "a markdown agent file becomes a profile: tools map to fx names, disallowedTools refuses, and it cannot delegate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var failure: ?[]const u8 = null;

    const reviewer = try parseMarkdown(arena, "code-reviewer", .home,
        \\---
        \\name: code-reviewer
        \\description: Reviews code
        \\tools: Read, Grep, Glob, Bash, mcp__github__*
        \\disallowedTools: Bash
        \\model: inherit
        \\permissionMode: auto
        \\maxTurns: 12
        \\color: blue
        \\---
        \\You review code.
    , &failure);
    try testing.expectEqualStrings("Reviews code", reviewer.description);
    try testing.expectEqualStrings("You review code.", reviewer.prompt);
    try testing.expect(reviewer.model == null);
    try testing.expectEqual(types.PermissionMode.auto, reviewer.permission_mode.?);
    try testing.expect(allowsTool(&reviewer, "read_file"));
    try testing.expect(allowsTool(&reviewer, "grep_files"));
    try testing.expect(allowsTool(&reviewer, "mcp__github__search"));
    try testing.expect(!allowsTool(&reviewer, "mcp__linear__search"));
    try testing.expect(!allowsTool(&reviewer, "Bash"));
    try testing.expect(!allowsTool(&reviewer, "write_file"));
    try testing.expect(!allowsTool(&reviewer, subagent_tool));
    try testing.expect(allowedSubagentType(&reviewer));
    try testing.expectEqual(@as(?usize, 12), reviewer.max_turns);
    try testing.expectEqual(@as(usize, 1), reviewer.ignored.len);
    try testing.expectEqualStrings("color", reviewer.ignored[0].key);

    const helper = try parseMarkdown(arena, "helper", .project, "---\ndescription: Helps\nmodel: sonnet\npermissionMode: auto\ndisallowedTools: Write, Edit\n---\nHelp.", &failure);
    try testing.expectEqualStrings("sonnet", helper.model.?);
    try testing.expect(helper.permission_mode == null);
    try testing.expectEqual(IgnoredReason.project_cannot_set_permissions, helper.ignored[0].reason);
    try testing.expect(allowsTool(&helper, "read_file"));
    try testing.expect(allowsTool(&helper, "Bash"));
    try testing.expect(!allowsTool(&helper, "write_file"));
    try testing.expect(!allowsTool(&helper, "edit_file"));
    try testing.expect(!allowsTool(&helper, subagent_tool));
    try testing.expect(!allowsTool(&helper, "AskUserQuestion"));
    try testing.expect(!allowsTool(&helper, "ExitPlanMode"));

    const scoped = try parseMarkdown(arena, "scoped", .home, "---\ndescription: Scoped\nmcpServers:\n  - github\n  - slack:\n      type: stdio\n      command: slack-mcp\n---\nWork.", &failure);
    try testing.expectEqual(@as(usize, 1), scoped.mcp_servers.?.len);
    try testing.expectEqualStrings("github", scoped.mcp_servers.?[0]);
    try testing.expect(allowsMcpServer(&scoped, "github"));
    try testing.expect(!allowsMcpServer(&scoped, "slack"));
    try testing.expectEqualStrings("mcpServers", scoped.ignored[0].key);

    const lead = try parseMarkdown(arena, "lead", .home, "---\ndescription: Leads\ntools: Agent, Read\n---\nLead.", &failure);
    try testing.expect(allowsTool(&lead, subagent_tool));
    try testing.expect(allowsTool(&lead, "read_file"));
    try testing.expect(!allowsTool(&lead, "AskUserQuestion"));
    try testing.expect(!allowedSubagentType(&lead));

    try testing.expectError(error.InvalidProfile, parseMarkdown(arena, "empty", .home, "No frontmatter.", &failure));
    try testing.expect(std.mem.find(u8, failure.?, "needs a description") != null);
}

test "markdown agents load from the fx and .claude agent folders, and Claude Code's built-in names reach fx's" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestProfile(tmp.dir, "home/reviewer", "{\"description\": \"Home reviewer\"}");
    try writeTestFile(tmp.dir, "home/auditor.md", "---\ndescription: Home auditor\n---\nAudit.");
    try writeTestFile(tmp.dir, "claude-home/reviewer.md", "---\ndescription: Claude reviewer\n---\nReview.");
    try writeTestFile(tmp.dir, "claude-home/tester.md", "---\ndescription: Claude tester\n---\nTest.");
    try writeTestFile(tmp.dir, "claude-project/tester.md", "---\ndescription: Repo tester\n---\nTest.");
    try writeTestFile(tmp.dir, "claude-project/deployer.md", "---\ndescription: Repo deployer\npermissionMode: auto\n---\nDeploy.");
    try writeTestFile(tmp.dir, "claude-project/Not-Valid.md", "---\ndescription: Skipped\n---\n");
    try writeTestFile(tmp.dir, "claude-project/notes.txt", "not an agent");
    const roots: Roots = .{
        .home = try io_mod.dirRealpathAlloc(arena, tmp.dir, "home"),
        .claude_home = try io_mod.dirRealpathAlloc(arena, tmp.dir, "claude-home"),
        .claude_project = try io_mod.dirRealpathAlloc(arena, tmp.dir, "claude-project"),
    };

    var failure: ?[]const u8 = null;
    try testing.expectEqualStrings("Home reviewer", (try load(arena, roots, "reviewer", &failure)).description);
    try testing.expectEqualStrings("Home auditor", (try load(arena, roots, "auditor", &failure)).description);
    try testing.expectEqualStrings("Claude tester", (try load(arena, roots, "tester", &failure)).description);
    const deployer = try load(arena, roots, "deployer", &failure);
    try testing.expectEqual(Source.project, deployer.source);
    try testing.expect(deployer.permission_mode == null);
    try testing.expectEqualStrings(coder_name, (try load(arena, roots, "general-purpose", &failure)).name);
    try testing.expectEqualStrings(coder_name, (try load(arena, roots, "claude", &failure)).name);
    try testing.expectEqualStrings(explore_name, (try load(arena, roots, "Explore", &failure)).name);
    try testing.expectEqualStrings(plan_name, (try load(arena, roots, "Plan", &failure)).name);

    const entries = try list(arena, roots);
    try testing.expectEqualStrings("agent, auditor, coder, deployer, explore, main, plan, reviewer, tester, tower-worker", try listNames(arena, roots));
    try testing.expectEqualStrings("auditor, coder, deployer, explore, plan, tester", try subagentTypeNames(arena, entries));
}

test "agent directories of installed plugins are profile roots" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "src/agents");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/kimi.plugin.json", .data = "{\"name\":\"acme\",\"agents\":\"./agents\"}" });
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    const home = try std.Io.Dir.path.join(arena, &.{ base, "home" });
    _ = try plugin_manager.install(arena, home, try std.Io.Dir.path.join(arena, &.{ base, "src" }), 1, .{ .trusted = true });
    const roots = try Roots.init(arena, home, null);
    try testing.expectEqual(@as(usize, 1), roots.plugin_agents.len);
    try testing.expectEqualStrings("acme", roots.plugin_agents[0].plugin_id);
    try testing.expect(std.mem.endsWith(u8, roots.plugin_agents[0].path, "agents"));
}

test "plugin agents load as plugin:name with subfolders joined by colons, and drop their mode and MCP servers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "acme/agents/reviewer.md", "---\ndescription: Plugin reviewer\npermissionMode: auto\nmcpServers: [github]\nhooks: later\ninitialPrompt: go\n---\nReview.");
    try writeTestFile(tmp.dir, "acme/agents/ops/deploy.md", "---\ndescription: Plugin deployer\n---\nDeploy.");
    try writeTestFile(tmp.dir, "acme/agents/README.txt", "not an agent");
    const agents_dir = try io_mod.dirRealpathAlloc(arena, tmp.dir, "acme/agents");
    const roots: Roots = .{ .plugin_agents = &.{.{ .plugin_id = "acme.tools", .path = agents_dir, .instructions = null }} };

    var failure: ?[]const u8 = null;
    const reviewer = try load(arena, roots, "acme.tools:reviewer", &failure);
    try testing.expectEqual(Source.plugin, reviewer.source);
    try testing.expectEqualStrings("acme.tools:reviewer", reviewer.name);
    try testing.expectEqualStrings("Plugin reviewer", reviewer.description);
    try testing.expect(reviewer.permission_mode == null);
    try testing.expect(reviewer.mcp_servers == null);
    try testing.expect(allowedSubagentType(&reviewer));
    const deployer = try load(arena, roots, "acme.tools:ops:deploy", &failure);
    try testing.expectEqualStrings("Plugin deployer", deployer.description);
    try testing.expectError(error.ProfileNotFound, load(arena, roots, "acme.tools:missing", &failure));
    try testing.expectError(error.ProfileNotFound, load(arena, roots, "other:reviewer", &failure));

    try testing.expect(validName("acme.tools:ops:deploy"));
    try testing.expect(!validName("acme.tools"));
    try testing.expect(!validName("acme:"));
    try testing.expect(!validName(":reviewer"));
    try testing.expect(!validName("acme:../escape"));

    const entries = try list(arena, roots);
    try testing.expectEqualStrings("acme.tools:ops:deploy, acme.tools:reviewer, coder, explore, plan", try subagentTypeNames(arena, entries));
}

test "a name resolves from the user's profiles, then the repository's, then fx's" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestProfile(tmp.dir, "home/reviewer", "{\"description\": \"Home reviewer\"}");
    try writeTestProfile(tmp.dir, "project/reviewer", "{\"description\": \"Repo reviewer\"}");
    try writeTestProfile(tmp.dir, "project/tester", "{\"description\": \"Repo tester\", \"permission_mode\": \"full-access\"}");
    try writeTestProfile(tmp.dir, "project/broken", "{not json");
    try writeTestProfile(tmp.dir, "home/main", "{\"description\": \"Not fx\", \"tools\": []}");
    const roots: Roots = .{
        .home = try io_mod.dirRealpathAlloc(arena, tmp.dir, "home"),
        .project = try io_mod.dirRealpathAlloc(arena, tmp.dir, "project"),
    };

    var failure: ?[]const u8 = null;
    const reviewer = try load(arena, roots, "reviewer", &failure);
    try testing.expectEqual(Source.home, reviewer.source);
    try testing.expectEqualStrings("Home reviewer", reviewer.description);
    const tester = try load(arena, roots, "tester", &failure);
    try testing.expectEqual(Source.project, tester.source);
    try testing.expect(tester.permission_mode == null);
    const agent = try load(arena, roots, "agent", &failure);
    try testing.expectEqual(Source.builtin, agent.source);
    const main = try load(arena, roots, "main", &failure);
    try testing.expectEqual(Source.builtin, main.source);
    try testing.expect(allowsTool(&main, "read_file"));
    try testing.expectError(error.InvalidProfile, load(arena, roots, "broken", &failure));
    try testing.expect(std.mem.find(u8, failure.?, "not valid JSON") != null);
    try testing.expectError(error.ProfileNotFound, load(arena, roots, "missing", &failure));
    try testing.expectEqualStrings("no profile named 'missing'. Profiles: agent, coder, explore, main, plan, reviewer, tester, tower-worker", failure.?);

    const entries = try list(arena, roots);
    try testing.expectEqual(@as(usize, 8), entries.len);
    try testing.expectEqualStrings("reviewer", entries[5].name);
    try testing.expectEqual(Source.home, entries[5].source);
    try testing.expectEqual(Source.builtin, entries[0].source);
}

test "the built-in coder, explore and plan profiles carry Kimi's tool sets and none of them delegates" {
    const coder = builtin(coder_name).?;
    try testing.expect(allowsTool(&coder, "edit_file"));
    try testing.expect(allowsTool(&coder, "Bash"));
    try testing.expect(allowsTool(&coder, "mcp__github__issue_create"));
    try testing.expect(!allowsTool(&coder, "Agent"));

    const explore = builtin(explore_name).?;
    try testing.expect(allowsTool(&explore, "read_file"));
    try testing.expect(allowsTool(&explore, "Bash"));
    try testing.expect(!allowsTool(&explore, "edit_file"));
    try testing.expect(!allowsTool(&explore, "write_file"));
    try testing.expect(!allowsTool(&explore, "Agent"));

    const plan = builtin(plan_name).?;
    try testing.expect(allowsTool(&plan, "grep_files"));
    try testing.expect(!allowsTool(&plan, "Bash"));
    try testing.expect(!allowsTool(&plan, "write_file"));
    try testing.expect(!allowsTool(&plan, "Agent"));
    try testing.expect(std.mem.find(u8, plan.prompt, "recommend an explore subagent") != null);
}

test "the built-in tower-worker profile carries Kimi's tower tool set and role text and is no Agent subagent type" {
    const worker = builtin(tower_worker_name).?;
    try testing.expectEqualStrings("tower-worker", worker.name);
    try testing.expect(allowsTool(&worker, "TowerComplete"));
    try testing.expect(allowsTool(&worker, "write_file"));
    try testing.expect(allowsTool(&worker, "Bash"));
    try testing.expect(!allowsTool(&worker, "Agent"));
    try testing.expect(!allowedSubagentType(&worker));
    try testing.expect(std.mem.startsWith(u8, worker.prompt, "You are a subagent; the main agent is your caller"));
    try testing.expect(std.mem.find(u8, worker.prompt, "Your final message is the entire handoff.") != null);
    try testing.expect(std.mem.find(u8, worker.prompt, "TowerInbox") != null);
}

test "a profile that admits MCP tools also admits the tools that find and load them, unless it refuses them by name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const coder = builtin(coder_name).?;
    try testing.expect(allowsTool(&coder, "capability_search"));
    try testing.expect(allowsTool(&coder, "select_tools"));

    const explore = builtin(explore_name).?;
    try testing.expect(!allowsTool(&explore, "capability_search"));
    try testing.expect(!allowsTool(&explore, "select_tools"));

    const one_server = try testParse(arena_state.allocator(), .home,
        \\{"description": "Mcp", "tools": ["read_file", "mcp__github__*", "!select_tools"]}
    , "");
    try testing.expect(allowsTool(&one_server, "capability_search"));
    try testing.expect(!allowsTool(&one_server, "select_tools"));

    const refused = try testParse(arena_state.allocator(), .home,
        \\{"description": "No Mcp", "tools": ["read_file", "!mcp__github__delete"]}
    , "");
    try testing.expect(!allowsTool(&refused, "capability_search"));
}

test "a trailing * in a tool name matches by prefix, and a ! entry takes precedence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const profile = try testParse(arena_state.allocator(), .home,
        \\{"description": "Mcp", "tools": ["mcp__*", "!mcp__github__delete"]}
    , "");
    try testing.expect(allowsTool(&profile, "mcp__slack__post"));
    try testing.expect(!allowsTool(&profile, "mcp__github__delete"));
    try testing.expect(!allowsTool(&profile, "read_file"));
    try testing.expect(!allowsTool(&profile, "mcpx__slack__post"));
}

test "a held profile replaces the last only when the next one loads, and keeps its prompt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestProfile(tmp.dir, "fxhome/.fx/agents/reviewer", "{\"description\": \"Reviewer\", \"permission_mode\": \"ask\"}");
    {
        var file = try tmp.dir.createFile(io_mod.getIo(), "fxhome/.fx/agents/reviewer/prompt.md", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "Review only.");
    }
    const fx_home = try io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, "fxhome");
    defer testing.allocator.free(fx_home);

    var held: Held = .{};
    defer held.deinit();
    try testing.expectEqualStrings(main_name, held.profile.name);
    var failure: ?[]u8 = null;
    defer if (failure) |message| testing.allocator.free(message);
    try testing.expectError(error.ProfileNotFound, held.replace(testing.allocator, null, null, "reviewer", "BASE", &failure));
    try testing.expect(std.mem.find(u8, failure.?, "no profile named 'reviewer'") != null);
    try testing.expectEqualStrings(main_name, held.profile.name);
    try testing.expect(held.system_prompt == null);

    var name_buf = "reviewer".*;
    try held.replace(testing.allocator, fx_home, null, &name_buf, "BASE", &failure);
    @memset(&name_buf, 'x');
    try testing.expectEqualStrings("reviewer", held.profile.name);
    try testing.expectEqual(types.PermissionMode.ask, held.profile.permission_mode.?);
    try testing.expectEqualStrings("BASE\n\nReview only.", held.system_prompt.?);
}

test "a root may start coder, explore and plan, and a profile that cannot delegate; fx's main and agent are refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestProfile(tmp.dir, "home/boss", "{\"description\": \"Delegates\"}");
    try writeTestProfile(tmp.dir, "home/leaf", "{\"description\": \"Reads\", \"tools\": [\"read_file\"]}");
    try writeTestProfile(tmp.dir, "project/guard", "{\"description\": \"Guard\", \"tools\": [\"*\", \"!Agent\"]}");
    const roots: Roots = .{
        .home = try io_mod.dirRealpathAlloc(arena, tmp.dir, "home"),
        .project = try io_mod.dirRealpathAlloc(arena, tmp.dir, "project"),
    };

    const entries = try list(arena, roots);
    try testing.expectEqualStrings("coder, explore, guard, leaf, plan", try subagentTypeNames(arena, entries));
    var failure: ?[]const u8 = null;
    const boss = try load(arena, roots, "boss", &failure);
    const leaf = try load(arena, roots, "leaf", &failure);
    const guard = try load(arena, roots, "guard", &failure);
    const main = builtin(main_name).?;
    const coder = builtin(coder_name).?;
    try testing.expect(!allowedSubagentType(&boss));
    try testing.expect(allowedSubagentType(&leaf));
    try testing.expect(allowedSubagentType(&guard));
    try testing.expect(!allowedSubagentType(&main));
    const agent = builtin(agent_name).?;
    try testing.expect(!allowedSubagentType(&agent));
    try testing.expect(allowedSubagentType(&coder));
}
