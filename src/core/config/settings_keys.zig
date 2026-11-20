const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Where = enum {
    profile,
    project_safe,
    retired,
    editor,
};

pub const Kind = enum {
    any,
    boolean,
    integer,
    string,
    string_or_null,
    strings,
    string_map,
    switches,
    object,
    objects,
    workspaces,
    refused,
};

pub const Key = struct {
    name: []const u8,
    where: Where,
    kind: Kind,
    description: []const u8,
    children: []const []const u8 = &.{},
    child_descriptions: []const []const u8 = &.{},
    values: []const []const u8 = &.{},
    minimum: ?i64 = null,
    maximum: ?i64 = null,
    max_items: ?usize = null,
    map: bool = false,
    renamed_to: ?[]const u8 = null,
    superseded_by: ?[]const u8 = null,
    workspace_only: bool = false,
    top_level_only: bool = false,

    pub fn hasChild(self: Key, name: []const u8) bool {
        for (self.children) |child| {
            if (std.mem.eql(u8, child, name)) return true;
        }
        return false;
    }

    pub fn deprecated(self: Key) bool {
        return self.where == .retired or self.renamed_to != null or self.superseded_by != null;
    }
};

const sound_children = [_][]const u8{ "attention_required", "max", "turn_end" };
const sound_child_descriptions = [_][]const u8{
    "Play a sound when fx needs your attention",
    "Play extra interaction sounds when sound is on",
    "Play a sound when a turn finishes",
};
const status_line_children = [_][]const u8{ "context", "session", "workspace" };
const status_line_child_descriptions = [_][]const u8{
    "Show context usage in the footer",
    "Show the session title in the footer",
    "Show the workspace path and Git branch in the footer",
};
const retired_description = "No longer used; fx ignores it";

pub const keys = [_]Key{
    .{ .name = "$schema", .where = .editor, .kind = .string, .top_level_only = true, .description = "The JSON Schema editors use to check this file" },
    .{ .name = "additional_directories", .where = .profile, .kind = .strings, .workspace_only = true, .description = "Directories added to this workspace; manage them with fx workspace" },
    .{ .name = "auto_compact_percent", .where = .profile, .kind = .integer, .minimum = 10, .maximum = 85, .description = "Start automatic compaction at this percentage of usable input capacity" },
    .{ .name = "auto_upgrade", .where = .profile, .kind = .boolean, .description = "Download and install updates in the background" },
    .{ .name = "browser", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Browser route and Birdman endpoint: route (birdman or cdp), and birdman with host, port and path" },
    .{ .name = "builtin_product_skills", .where = .profile, .kind = .boolean, .description = "Load the skills fx ships with; default on (Kimi builtinProductSkills)" },
    .{ .name = "cache_warming", .where = .profile, .kind = .boolean, .description = "Keep a waiting Claude conversation's prompt cache alive for up to 30 minutes" },
    .{ .name = "codex_model", .where = .profile, .kind = .string, .superseded_by = "models.codex", .description = "Older form of models.codex" },
    .{ .name = "collapse_tool_calls", .where = .profile, .kind = .boolean, .description = "Show a summary for each group of tool calls" },
    .{ .name = "context", .where = .project_safe, .kind = .boolean, .description = "Load project instructions such as AGENTS.md" },
    .{ .name = "context_limits", .where = .profile, .kind = .object, .map = true, .description = "Context limits by name, in bytes or off, as --context-limit takes them" },
    .{ .name = "credential_source", .where = .profile, .kind = .string, .values = &.{ "vercel_oidc_token", "ai_gateway_api_key", "fx_login", "stored_key", "chatgpt_subscription", "grok_subscription" }, .description = "The saved credential fx uses; fx login sets it" },
    .{ .name = "cron", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Scheduled task flags: debug, no_jitter, no_stale, disabled, manual_tick (all default off)" },
    .{ .name = "dangerous_command_guard", .where = .profile, .kind = .boolean, .description = "Ask before shell commands that match the dangerous-command list (default on)" },
    .{ .name = "database", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Persistence and search flags: base, global_search, search, search_sync_session_cap, search_sync_debounce_ms" },
    .{ .name = "default_model", .where = .profile, .kind = .string, .description = "Model id used when a session does not pick one" },
    .{ .name = "default_permission_mode", .where = .profile, .kind = .string, .values = &.{ "manual", "auto", "yolo" }, .description = "Permission mode for a session when no saved permission_mode exists; manual asks before actions, yolo asks only when needed, auto never asks" },
    .{ .name = "default_plan_mode", .where = .profile, .kind = .boolean, .description = "Start sessions in plan mode (default off)" },
    .{ .name = "disabledMcpjsonServers", .where = .profile, .kind = .strings, .workspace_only = true, .description = "Project MCP servers rejected in this workspace; manage them with fx mcp approve and reject" },
    .{ .name = "effort", .where = .profile, .kind = .string_or_null, .description = "Reasoning effort: auto or a name the model supports; null means auto" },
    .{ .name = "enableAllProjectMcpServers", .where = .profile, .kind = .boolean, .workspace_only = true, .description = "Approve every server in this workspace's .mcp.json; manage it with fx mcp approve and reject" },
    .{ .name = "enabledMcpjsonServers", .where = .profile, .kind = .strings, .workspace_only = true, .description = "Project MCP servers approved in this workspace; manage them with fx mcp approve and reject" },
    .{ .name = "experimental", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Experimental feature flags by name, each true or false" },
    .{ .name = "extra_agent_dirs", .where = .profile, .kind = .strings, .description = "Extra directories searched for agent profiles" },
    .{ .name = "extra_skill_dirs", .where = .profile, .kind = .strings, .description = "Extra directories searched for skills" },
    .{ .name = "fast_mode", .where = .profile, .kind = .boolean, .description = "Use faster inference when the model supports it" },
    .{ .name = "fast_mode_model_bound", .where = .profile, .kind = .boolean, .description = "Managed by fx alongside fast_mode" },
    .{ .name = "first_call_tool_choice", .where = .profile, .kind = .string, .values = &.{ "auto", "none" }, .description = "Tool choice for the first request of a turn" },
    .{ .name = "grok_model", .where = .profile, .kind = .string, .superseded_by = "models.grok", .description = "Older form of models.grok" },
    .{ .name = "hooks", .where = .profile, .kind = .objects, .description = "External command hooks: an array of objects with event, optional matcher, command, optional timeout (1-600 seconds, default 30) and optional onFailure (continue or block); or the Claude Code object keyed by event name, each holding matcher groups with a hooks list of {type: command, command, timeout, onFailure} (default timeout 600 seconds, 30 for UserPromptSubmit). Run /hooks to list them" },
    .{ .name = "identity", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Agent identity: name and slug strings" },
    .{ .name = "image", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Image budgets: max_edge_px and read_byte_budget (positive integers)" },
    .{ .name = "input_appearance", .where = .retired, .kind = .any, .description = retired_description },
    .{ .name = "loop_control", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Agent loop limits: max_steps_per_turn, max_attempts_per_step, max_ralph_iterations, reserved_context_size, compaction_trigger_ratio (0.5-0.99), compaction_max_attempts" },
    .{ .name = "max_agent_steps", .where = .project_safe, .kind = .integer, .minimum = 0, .description = "Most agent steps per turn; 0 means no limit" },
    .{ .name = "max_tool_result_bytes", .where = .project_safe, .kind = .integer, .minimum = 1024, .description = "Tool output budget in model context, in bytes" },
    .{ .name = "maxxing_mode", .where = .retired, .kind = .any, .description = retired_description },
    .{ .name = "mcp", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "MCP timeouts in milliseconds and deferred loading: startup_timeout_ms, tool_timeout_ms, default_deferred, reconnect_initial_delay_ms, reconnect_max_delay_ms" },
    .{ .name = "merge_all_available_skills", .where = .profile, .kind = .boolean, .description = "Merge every discovered skill root into the available list; default on" },
    .{ .name = "model", .where = .profile, .kind = .string, .superseded_by = "models.gateway", .description = "Older form of models.gateway" },
    .{ .name = "model_catalog", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Model catalog refresh: refresh_interval_ms and refresh_on_start" },
    .{ .name = "models", .where = .profile, .kind = .string_map, .map = true, .description = "The saved model for each provider or connection, such as {\"gateway\": \"<model id>\"}" },
    .{ .name = "notifications", .where = .profile, .kind = .switches, .children = &sound_children, .child_descriptions = &sound_child_descriptions, .renamed_to = "sound", .description = "Renamed to sound" },
    .{ .name = "output_style", .where = .profile, .kind = .string, .description = "Output style by its case-sensitive name: Default, Proactive, Concise, Explanatory, Learning, or a style file in ~/.fx/output-styles or .fx/output-styles; unset means Default" },
    .{ .name = "permission", .where = .profile, .kind = .object, .map = true, .description = "Permission rules; manage them with /permissions. Rule patterns take *, ?, [a-z] classes, {a,b} alternatives, a leading ! and, for file tools, ~/ for the home directory" },
    .{ .name = "permission_mode", .where = .profile, .kind = .string, .values = &.{ "ask", "manual", "auto", "yolo", "dontAsk" }, .description = "How fx handles tool calls that need permission; manual is Kimi's name for ask, yolo asks only when needed, auto never asks, dontAsk denies what would ask" },
    .{ .name = "permissions", .where = .profile, .kind = .object, .map = true, .description = "Claude Code's permissions block: allow, ask and deny rule lists such as Bash(npm run build), Read(./.env) or WebFetch(domain:example.com), added to the permission rules, and defaultMode (default, auto, dontAsk or bypassPermissions). additionalDirectories, disableBypassPermissionsMode and disableAutoMode are refused because fx does not enforce them" },
    .{ .name = "prompt_history", .where = .profile, .kind = .switches, .children = &.{"enabled"}, .child_descriptions = &.{"Save prompts and slash commands for input history"}, .description = "Input history" },
    .{ .name = "provider", .where = .profile, .kind = .string, .description = "The service for model requests: gateway, codex, grok, or a name under providers" },
    .{ .name = "provider_order", .where = .project_safe, .kind = .strings, .max_items = 8, .description = "Preferred AI Gateway providers, in order" },
    .{ .name = "provider_strict", .where = .project_safe, .kind = .boolean, .description = "Send AI Gateway requests only to the providers in provider_order" },
    .{ .name = "providers", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Named custom model connections" },
    .{ .name = "read", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Read tool caps in characters: default_max_chars and max_chars (positive integers)" },
    .{ .name = "review_model", .where = .profile, .kind = .string, .description = "The AI Gateway model that reviews actions in auto mode" },
    .{ .name = "sandbox", .where = .retired, .kind = .any, .description = retired_description },
    .{ .name = "secondary_model", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Secondary (subagent) model: default_model, default_effort, and a models map of name to model id" },
    .{ .name = "services", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Web services: moonshot_search and moonshot_fetch, each with base_url and api_key" },
    .{ .name = "session_titles", .where = .profile, .kind = .boolean, .description = "Name each session from its first prompt" },

    .{ .name = "skill_match_fuzzy", .where = .profile, .kind = .refused, .description = "No longer supported; fx refuses a file that sets it, so remove it" },
    .{ .name = "skill_symlink_authorities", .where = .profile, .kind = .strings, .description = "Absolute directories that symlinked skills may resolve into" },
    .{ .name = "slash_menu_categories", .where = .profile, .kind = .boolean, .description = "Show command categories and skill sources in slash menu results" },
    .{ .name = "sound", .where = .profile, .kind = .switches, .children = &sound_children, .child_descriptions = &sound_child_descriptions, .description = "Sounds" },
    .{ .name = "startup_scrollback", .where = .profile, .kind = .boolean, .description = "Restore terminal output at startup" },
    .{ .name = "statusLine", .where = .profile, .kind = .switches, .children = &status_line_children, .child_descriptions = &status_line_child_descriptions, .renamed_to = "status_line", .description = "Renamed to status_line" },
    .{ .name = "status_line", .where = .profile, .kind = .switches, .children = &status_line_children, .child_descriptions = &status_line_child_descriptions, .description = "What the footer shows" },
    .{ .name = "subagent", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Subagent limits: timeout_ms (default two hours)" },
    .{ .name = "swarm", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Swarm limits: timeout_ms (default two hours)" },
    .{ .name = "task", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Background task limits: max_running_tasks, keep_alive_on_exit, bash_auto_background_on_timeout, bash_task_timeout_s, kill_grace_period_ms, stuck_after_s, root_job_wait_s (how long fx waits for a job a superagent root left running, 1800 by default), root_min_free_mb (free memory a new superagent root needs, 512 by default, 0 for no check), print_background_mode (what fx ask does with background work when its turn ends: steer runs a new turn on each task notice, drain waits without new turns, exit leaves at once), print_max_turns (most turns one fx ask run takes, 100000 by default), print_wait_ceiling_s (longest fx ask waits for background work; CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS sets it in milliseconds, 0 for no ceiling), bash_output_max_chars (lowers the inline Bash output ceiling, 1 to 150000; BASH_MAX_OUTPUT_LENGTH sets it too), background_disabled (refuse run_in_background; CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 sets it too)" },
    .{ .name = "theme", .where = .profile, .kind = .string, .description = "light, dark, or the name of a theme file in ~/.fx/themes" },
    .{ .name = "thinking", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Reasoning: enabled and keep" },
    .{ .name = "token_counting", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Token counting strategy: measured+estimated (default), measured, or estimated" },
    .{ .name = "tools", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Tool policy: enabled (allow list) and disabled (deny list) tool names" },
    .{ .name = "ultrafast_mode", .where = .profile, .kind = .boolean, .description = "Request the higher-priced Ultrafast tier for an eligible AI Gateway model" },
    .{ .name = "update_channel", .where = .profile, .kind = .string, .values = &.{ "stable", "dev" }, .description = "Release channel for updates" },
    .{ .name = "wait_for", .where = .profile, .kind = .boolean, .superseded_by = "experimental.wait_for", .description = "Older form of experimental.wait_for" },
    .{ .name = "watch", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "File watch flag: enabled" },
    .{ .name = "web_fetch_worker_model", .where = .retired, .kind = .any, .description = retired_description },
    .{ .name = "workspace", .where = .profile, .kind = .object, .map = true, .top_level_only = true, .description = "Workspace trust: require_trust (default on)" },
    .{ .name = "workspaces", .where = .profile, .kind = .workspaces, .map = true, .top_level_only = true, .description = "Overrides for each workspace, by absolute path" },
    .{ .name = "yolo_acknowledged", .where = .profile, .kind = .boolean, .description = "Managed by fx after you first confirm full-access mode" },
};

const names = blk: {
    var list: [keys.len][]const u8 = undefined;
    for (keys, 0..) |key, index| list[index] = key.name;
    break :blk list;
};

pub fn find(name: []const u8) ?Key {
    for (keys) |key| {
        if (std.mem.eql(u8, key.name, name)) return key;
    }
    return null;
}

pub fn ignoredInProject(name: []const u8) bool {
    const key = find(name) orelse return false;
    return key.where == .profile;
}

pub fn currentPath(path: []const u8) []const u8 {
    inline for (keys) |key| {
        if (key.renamed_to) |current| {
            if (std.mem.eql(u8, path, key.name)) return current;
            inline for (key.children) |child| {
                if (std.mem.eql(u8, path, key.name ++ "." ++ child)) return current ++ "." ++ child;
            }
        }
    }
    return path;
}

pub const File = enum { profile, project };

pub const OlderName = struct {
    older: []const u8,
    current: []const u8,
    both: bool = true,
    workspace: ?[]const u8 = null,
};

pub fn findOlderNames(alloc: Allocator, root: std.json.Value, file: File) ![]OlderName {
    var found: std.ArrayList(OlderName) = .empty;
    errdefer found.deinit(alloc);
    if (root != .object) return found.toOwnedSlice(alloc);
    try appendOlderNames(alloc, &found, root.object, null);
    if (file == .profile) {
        if (root.object.get("workspaces")) |workspaces| {
            if (workspaces == .object) {
                var iterator = workspaces.object.iterator();
                while (iterator.next()) |entry| {
                    if (entry.value_ptr.* != .object) continue;
                    try appendOlderNames(alloc, &found, entry.value_ptr.object, entry.key_ptr.*);
                }
            }
        }
    }
    return found.toOwnedSlice(alloc);
}

fn appendOlderNames(alloc: Allocator, found: *std.ArrayList(OlderName), object: std.json.ObjectMap, workspace: ?[]const u8) !void {
    for (keys) |key| {
        const current = key.renamed_to orelse continue;
        const older_value = object.get(key.name) orelse continue;
        const current_value = object.get(current) orelse {
            try found.append(alloc, .{ .older = key.name, .current = current, .both = false, .workspace = workspace });
            continue;
        };

        if (older_value == .object and current_value != .object) continue;
        try found.append(alloc, .{ .older = key.name, .current = current, .workspace = workspace });
    }
}

pub const UnknownKey = struct {
    name: []const u8,
    parent: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    known: []const []const u8,
};

pub fn findUnknown(alloc: Allocator, root: std.json.Value, file: File) ![]UnknownKey {
    var found: std.ArrayList(UnknownKey) = .empty;
    errdefer found.deinit(alloc);
    if (root != .object) return found.toOwnedSlice(alloc);

    try appendUnknown(alloc, &found, root.object, null);
    if (file == .profile) {
        if (root.object.get("workspaces")) |workspaces| {
            if (workspaces == .object) {
                var iterator = workspaces.object.iterator();
                while (iterator.next()) |entry| {
                    if (entry.value_ptr.* != .object) continue;
                    try appendUnknown(alloc, &found, entry.value_ptr.object, entry.key_ptr.*);
                }
            }
        }
    }
    return found.toOwnedSlice(alloc);
}

fn appendUnknown(
    alloc: Allocator,
    found: *std.ArrayList(UnknownKey),
    object: std.json.ObjectMap,
    workspace: ?[]const u8,
) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const key = find(name) orelse {
            try found.append(alloc, .{ .name = name, .workspace = workspace, .known = &names });
            continue;
        };
        if (key.children.len == 0 or entry.value_ptr.* != .object) continue;
        var children = entry.value_ptr.object.iterator();
        while (children.next()) |child| {
            if (key.hasChild(child.key_ptr.*)) continue;
            try found.append(alloc, .{
                .name = child.key_ptr.*,
                .parent = key.name,
                .workspace = workspace,
                .known = key.children,
            });
        }
    }
}

pub const UnknownPart = struct {
    name: []const u8,
    parent: ?[]const u8 = null,
    known: []const []const u8,
};

pub fn unknownPart(path: []const u8) ?UnknownPart {
    const dot = std.mem.findScalar(u8, path, '.');
    const head = path[0 .. dot orelse path.len];
    const key = find(head) orelse return .{ .name = head, .known = &names };
    if (key.where == .retired) return .{ .name = head, .known = &names };
    const at = dot orelse return null;
    if (key.map) return null;
    const rest = path[at + 1 ..];
    const parent = key.renamed_to orelse key.name;
    if (key.children.len == 0) return .{ .name = rest, .parent = parent, .known = &.{} };
    if (std.mem.findScalar(u8, rest, '.') == null and key.hasChild(rest)) return null;
    return .{ .name = rest, .parent = parent, .known = key.children };
}

test "every key says what it holds and what it does" {
    for (keys) |key| {
        errdefer std.debug.print("key {s}\n", .{key.name});
        try std.testing.expect(key.description.len > 0);
        try std.testing.expectEqual(key.children.len, key.child_descriptions.len);
        try std.testing.expectEqual(key.children.len > 0, key.kind == .switches);
        try std.testing.expectEqual(key.where == .retired, key.kind == .any);
        try std.testing.expect(!(key.workspace_only and key.top_level_only));
        if (key.values.len > 0) try std.testing.expectEqual(Kind.string, key.kind);
        if (key.minimum != null or key.maximum != null) try std.testing.expectEqual(Kind.integer, key.kind);
        if (key.max_items != null) try std.testing.expectEqual(Kind.strings, key.kind);
        if (key.superseded_by) |path| {
            const dot = std.mem.findScalar(u8, path, '.') orelse path.len;
            try std.testing.expect(find(path[0..dot]) != null);
        }
    }
}

test "both spellings are reported only when fx would use the current one" {
    const alloc = std.testing.allocator;
    const text =
        \\{"notifications":{"turn_end":true},"sound":false,
        \\ "statusLine":{"context":true},"status_line":{"context":false}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    defer parsed.deinit();

    const found = try findOlderNames(alloc, parsed.value, .profile);
    defer alloc.free(found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("statusLine", found[0].older);
}

test "keys are unique and sorted so the list stays easy to scan" {
    for (keys[1..], 1..) |key, index| {
        try std.testing.expect(std.mem.order(u8, keys[index - 1].name, key.name) == .lt);
    }
}

test "renamed settings point to a current key with the same children" {
    for (keys) |key| {
        const current = find(key.renamed_to orelse continue).?;
        try std.testing.expect(current.renamed_to == null);
        try std.testing.expectEqual(key.where, current.where);
        try std.testing.expectEqual(key.children.len, current.children.len);
        for (key.children) |child| try std.testing.expect(current.hasChild(child));
    }
}

test "older names map to the current ones, in paths and in files" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { path: []const u8, expected: []const u8 }{
        .{ .path = "statusLine.context", .expected = "status_line.context" },
        .{ .path = "statusLine", .expected = "status_line" },
        .{ .path = "notifications.max", .expected = "sound.max" },
        .{ .path = "status_line.context", .expected = "status_line.context" },
        .{ .path = "statusLine.contxt", .expected = "statusLine.contxt" },
        .{ .path = "fast_mode", .expected = "fast_mode" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.expected, currentPath(case.path));

    try std.testing.expectEqualStrings("status_line", unknownPart("statusLine.contxt").?.parent.?);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"statusLine":{"context":true},"status_line":{"context":false},"notifications":{"max":true},
        \\ "workspaces":{"/w":{"notifications":{},"sound":{}},"/x":{"sound":{}}}}
    , .{});
    defer parsed.deinit();
    const twice = try findOlderNames(alloc, parsed.value, .profile);
    defer alloc.free(twice);

    try std.testing.expectEqual(@as(usize, 3), twice.len);
    try std.testing.expectEqualStrings("notifications", twice[0].older);
    try std.testing.expect(!twice[0].both and twice[0].workspace == null);
    try std.testing.expectEqualStrings("statusLine", twice[1].older);
    try std.testing.expectEqualStrings("status_line", twice[1].current);
    try std.testing.expect(twice[1].both and twice[1].workspace == null);
    try std.testing.expectEqualStrings("notifications", twice[2].older);
    try std.testing.expectEqualStrings("/w", twice[2].workspace.?);
}

test "project files ignore profile keys but not project-safe or retired ones" {
    try std.testing.expect(ignoredInProject("model"));
    try std.testing.expect(ignoredInProject("workspaces"));
    try std.testing.expect(ignoredInProject("enabledMcpjsonServers"));
    try std.testing.expect(!ignoredInProject("max_agent_steps"));
    try std.testing.expect(!ignoredInProject("provider_order"));
    try std.testing.expect(!ignoredInProject("maxxing_mode"));
    try std.testing.expect(!ignoredInProject("not_a_setting"));
}

test "unknown keys are found at the top level, in fixed objects, and in workspace overrides" {
    const alloc = std.testing.allocator;
    const text =
        \\{"fast_mdoe":true,"model":"m","maxxing_mode":1,"sandbox":"os",
        \\ "statusLine":{"context":true,"contxt":false},
        \\ "notifications":"off",
        \\ "models":{"anything":"m"},
        \\ "workspaces":{"/w":{"effort":"high","efort":"low","statusLine":{"sesion":true}},"/bad":3}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    defer parsed.deinit();

    const unknown = try findUnknown(alloc, parsed.value, .profile);
    defer alloc.free(unknown);
    try std.testing.expectEqual(@as(usize, 4), unknown.len);

    try std.testing.expectEqualStrings("fast_mdoe", unknown[0].name);
    try std.testing.expect(unknown[0].parent == null and unknown[0].workspace == null);
    try std.testing.expectEqual(@as(usize, keys.len), unknown[0].known.len);

    try std.testing.expectEqualStrings("contxt", unknown[1].name);
    try std.testing.expectEqualStrings("statusLine", unknown[1].parent.?);
    try std.testing.expectEqual(@as(usize, 3), unknown[1].known.len);

    try std.testing.expectEqualStrings("efort", unknown[2].name);
    try std.testing.expectEqualStrings("/w", unknown[2].workspace.?);

    try std.testing.expectEqualStrings("sesion", unknown[3].name);
    try std.testing.expectEqualStrings("statusLine", unknown[3].parent.?);
    try std.testing.expectEqualStrings("/w", unknown[3].workspace.?);
}

test "a project file is checked at its top level only" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\{"max_agent_step":5,"model":"m","workspaces":{"/w":{"efort":"low"}}}
    ,
        .{},
    );
    defer parsed.deinit();

    const unknown = try findUnknown(alloc, parsed.value, .project);
    defer alloc.free(unknown);
    try std.testing.expectEqual(@as(usize, 1), unknown.len);
    try std.testing.expectEqualStrings("max_agent_step", unknown[0].name);
}

test "dotted paths name listed keys, fixed children, and paths into maps" {
    for ([_][]const u8{ "fast_mode", "status_line", "status_line.context", "statusLine.context", "models", "models.codex", "providers.local.base_url" }) |path| {
        try std.testing.expect(unknownPart(path) == null);
    }

    const top = unknownPart("fast_mdoe").?;
    try std.testing.expectEqualStrings("fast_mdoe", top.name);
    try std.testing.expect(top.parent == null and top.known.len == keys.len);

    const child = unknownPart("status_line.contxt").?;
    try std.testing.expectEqualStrings("contxt", child.name);
    try std.testing.expectEqualStrings("status_line", child.parent.?);
    try std.testing.expectEqual(@as(usize, 3), child.known.len);

    const under_value = unknownPart("fast_mode.on").?;
    try std.testing.expectEqualStrings("on", under_value.name);
    try std.testing.expectEqual(@as(usize, 0), under_value.known.len);

    try std.testing.expect(unknownPart("statusLine.context.x") != null);
    try std.testing.expect(unknownPart("maxxing_mode") != null);
}

test "a non-object file has no unknown keys" {
    const unknown = try findUnknown(std.testing.allocator, .{ .integer = 3 }, .profile);
    defer std.testing.allocator.free(unknown);
    try std.testing.expectEqual(@as(usize, 0), unknown.len);
}
