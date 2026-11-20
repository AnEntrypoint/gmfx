const std = @import("std");
const kimi_sections = @import("kimi_sections.zig");

const Allocator = std.mem.Allocator;
const Sections = kimi_sections.Sections;
const usize_max: usize = std.math.maxInt(usize);
const timeout_max: usize = @intCast(kimi_sections.max_timeout_ms);

pub const Lookup = *const fn (name: []const u8) ?[]const u8;

pub fn apply(alloc: Allocator, sections: *Sections, lookup: Lookup) !void {
    setUsize(&sections.loop_max_steps_per_turn, lookup("KIMI_LOOP_MAX_STEPS_PER_TURN"), 0, usize_max);
    setUsize(&sections.loop_max_attempts_per_step, lookup("KIMI_LOOP_MAX_ATTEMPTS_PER_STEP"), 0, usize_max);

    setUsize(&sections.mcp_startup_timeout_ms, lookup("MCP_TIMEOUT"), 1, timeout_max);
    setUsize(&sections.mcp_tool_timeout_ms, lookup("MCP_TOOL_TIMEOUT"), 1, timeout_max);
    setUsize(&sections.mcp_startup_timeout_ms, lookup("MCP_TIMEOUT"), 1, timeout_max);
    setUsize(&sections.mcp_startup_timeout_ms, lookup("KIMI_MCP_STARTUP_TIMEOUT_MS"), 1, timeout_max);
    setUsize(&sections.mcp_tool_timeout_ms, lookup("KIMI_MCP_TOOL_TIMEOUT_MS"), 1, timeout_max);
    setUsize(&sections.mcp_reconnect_initial_delay_ms, lookup("KIMI_MCP_RECONNECT_INITIAL_DELAY_MS"), 1, timeout_max);
    setUsize(&sections.mcp_reconnect_max_delay_ms, lookup("KIMI_MCP_RECONNECT_MAX_DELAY_MS"), 1, timeout_max);

    setUsize(&sections.task_max_running_tasks, lookup("KIMI_CODE_BACKGROUND_MAX_RUNNING_TASKS"), 1, usize_max);
    setBool(&sections.task_keep_alive_on_exit, lookup("KIMI_CODE_BACKGROUND_KEEP_ALIVE_ON_EXIT"));
    setUsize(&sections.task_bash_timeout_s, lookup("KIMI_CODE_BACKGROUND_BASH_TASK_TIMEOUT_S"), 0, usize_max);
    setUsizeCapped(&sections.task_bash_output_max_chars, lookup("BASH_MAX_OUTPUT_LENGTH"), 1, kimi_sections.max_bash_output_chars);
    setBool(&sections.task_background_disabled, lookup("CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"));
    setPrintWaitCeilingFromMs(&sections.task_print_wait_ceiling_s, lookup("CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS"));
    setUsize(&sections.task_print_wait_ceiling_s, lookup("KIMI_CODE_BACKGROUND_PRINT_WAIT_CEILING_S"), 1, usize_max);
    setUsize(&sections.task_print_max_turns, lookup("KIMI_CODE_BACKGROUND_PRINT_MAX_TURNS"), 1, usize_max);
    if (trimmed(lookup("KIMI_CODE_BACKGROUND_PRINT_BACKGROUND_MODE"))) |text| {
        if (kimi_sections.PrintBackgroundMode.parse(text)) |mode| sections.task_print_background_mode = mode;
    }

    setUsize(&sections.image_max_edge_px, lookup("KIMI_IMAGE_MAX_EDGE_PX"), 1, usize_max);
    setUsize(&sections.image_read_byte_budget, lookup("KIMI_IMAGE_READ_BYTE_BUDGET"), 1, usize_max);

    if (trimmed(lookup("KIMI_TOKEN_COUNTING_STRATEGY"))) |text| {
        if (kimi_sections.TokenCountingStrategy.parse(text)) |strategy| sections.token_counting_strategy = strategy;
    }
    setUsize(&sections.subagent_timeout_ms, lookup("KIMI_SUBAGENT_TIMEOUT_MS"), 0, timeout_max);
    setUsize(&sections.swarm_timeout_ms, lookup("KIMI_CODE_SWARM_TIMEOUT_MS"), 0, timeout_max);

    try setString(alloc, &sections.identity_name, lookup("KIMI_CODE_IDENTITY_NAME"));
    try setString(alloc, &sections.identity_slug, lookup("KIMI_CODE_IDENTITY_SLUG"));
    try setString(alloc, &sections.env_base_url, lookup("KIMI_CODE_BASE_URL"));
    try setString(alloc, &sections.env_oauth_host, lookup("KIMI_CODE_OAUTH_HOST"));

    setBool(&sections.watch_enabled, lookup("KIMI_CODE_WATCH"));
    setBool(&sections.cron_debug, lookup("KIMI_CRON_DEBUG"));
    setBool(&sections.cron_no_jitter, lookup("KIMI_CRON_NO_JITTER"));
    setBool(&sections.cron_no_stale, lookup("KIMI_CRON_NO_STALE"));
    setBool(&sections.cron_manual_tick, lookup("KIMI_CRON_MANUAL_TICK"));
    setBool(&sections.cron_disabled, lookup("KIMI_DISABLE_CRON"));
    setBool(&sections.dangerous_command_guard, lookup("KIMI_CODE_DANGEROUS_COMMAND_GUARD"));
    setBool(&sections.builtin_product_skills, lookup("KIMI_CODE_BUILTIN_PRODUCT_SKILLS"));

    setBool(&sections.database_global_search, lookup("KIMI_CODE_GLOBAL_SEARCH"));
    setUsize(&sections.database_search_sync_session_cap, lookup("KIMI_CODE_SEARCH_SYNC_SESSION_CAP"), 1, usize_max);
    setUsize(&sections.database_search_sync_debounce_ms, lookup("KIMI_CODE_SEARCH_SYNC_DEBOUNCE_MS"), 0, usize_max);

    try setString(alloc, &sections.log_level, lookup("KIMI_LOG_LEVEL"));
    setUsize(&sections.log_global_max_bytes, lookup("KIMI_LOG_GLOBAL_MAX_BYTES"), 1, usize_max);
    setUsize(&sections.log_global_files, lookup("KIMI_LOG_GLOBAL_FILES"), 1, usize_max);
    setUsize(&sections.log_session_max_bytes, lookup("KIMI_LOG_SESSION_MAX_BYTES"), 1, usize_max);
    setUsize(&sections.log_session_files, lookup("KIMI_LOG_SESSION_FILES"), 1, usize_max);

    try applyToolSearchSwitch(alloc, sections, lookup("ENABLE_TOOL_SEARCH"));
    try applyExperimentalFlags(alloc, sections, lookup);

    try applyModelOverlay(alloc, &sections.model_env, lookup);
}

fn applyToolSearchSwitch(alloc: Allocator, sections: *Sections, raw: ?[]const u8) !void {
    const enabled = parseBool(trimmed(raw) orelse return) orelse return;
    try setExperimentalFlag(alloc, sections, "tool_select", enabled);
    if (enabled and sections.mcp_default_deferred == null) sections.mcp_default_deferred = true;
}

fn toolSearchOnLookup(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "ENABLE_TOOL_SEARCH")) return "true";
    return null;
}

fn toolSearchOffLookup(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "ENABLE_TOOL_SEARCH")) return "false";
    return null;
}

test "ENABLE_TOOL_SEARCH turns MCP tool search on with tools deferred by default, or off" {
    var searching: Sections = .{};
    defer searching.deinit(std.testing.allocator);
    try apply(std.testing.allocator, &searching, toolSearchOnLookup);
    try std.testing.expect(kimi_sections.experimentalEnabled(&searching, "tool_select"));
    try std.testing.expectEqual(true, searching.mcp_default_deferred.?);

    var eager: Sections = .{};
    defer eager.deinit(std.testing.allocator);
    try setExperimentalFlag(std.testing.allocator, &eager, "tool_select", true);
    try apply(std.testing.allocator, &eager, toolSearchOffLookup);
    try std.testing.expect(!kimi_sections.experimentalEnabled(&eager, "tool_select"));
    try std.testing.expect(eager.mcp_default_deferred == null);
}

fn applyExperimentalFlags(alloc: Allocator, sections: *Sections, lookup: Lookup) !void {
    const pairs = [_]struct { name: []const u8, variable: []const u8 }{
        .{ .name = "wait_for", .variable = "KIMI_CODE_EXPERIMENTAL_WAIT_FOR" },
        .{ .name = "tool_select", .variable = "KIMI_CODE_EXPERIMENTAL_TOOL_SELECT" },
        .{ .name = "notify_user", .variable = "KIMI_CODE_EXPERIMENTAL_NOTIFY_USER" },
        .{ .name = "subagent_fork", .variable = "KIMI_CODE_EXPERIMENTAL_SUBAGENT_FORK" },
        .{ .name = "tower", .variable = "KIMI_CODE_EXPERIMENTAL_TOWER" },
    };
    const master = parseBool(trimmed(lookup("KIMI_CODE_EXPERIMENTAL_FLAG")) orelse "") orelse false;
    for (pairs) |pair| {
        if (parseBool(trimmed(lookup(pair.variable)) orelse "")) |enabled| {
            try setExperimentalFlag(alloc, sections, pair.name, enabled);
        } else if (master and kimi_sections.experimentalConfigured(sections, pair.name) == null) {
            try setExperimentalFlag(alloc, sections, pair.name, true);
        }
    }
}

pub fn setExperimentalFlag(alloc: Allocator, sections: *Sections, name: []const u8, enabled: bool) !void {
    if (sections.experimental) |flags| {
        for (flags) |*flag| {
            if (std.mem.eql(u8, flag.name, name)) {
                flag.enabled = enabled;
                return;
            }
        }
    }
    const old_len: usize = if (sections.experimental) |flags| flags.len else 0;
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    const grown = try alloc.alloc(kimi_sections.Flag, old_len + 1);
    if (sections.experimental) |flags| @memcpy(grown[0..old_len], flags);
    grown[old_len] = .{ .name = owned_name, .enabled = enabled };
    if (sections.experimental) |old| alloc.free(old);
    sections.experimental = grown;
}

fn applyModelOverlay(alloc: Allocator, overlay: *kimi_sections.ModelOverlay, lookup: Lookup) !void {
    try setString(alloc, &overlay.api_key, lookup("KIMI_MODEL_API_KEY"));
    try setString(alloc, &overlay.provider_type, lookup("KIMI_MODEL_PROVIDER_TYPE"));
    try setString(alloc, &overlay.base_url, lookup("KIMI_MODEL_BASE_URL"));
    try setString(alloc, &overlay.name, lookup("KIMI_MODEL_NAME"));
    try setString(alloc, &overlay.thinking_effort, lookup("KIMI_MODEL_THINKING_EFFORT"));
    try setString(alloc, &overlay.thinking_keep, lookup("KIMI_MODEL_THINKING_KEEP"));
    setFloat(&overlay.temperature, lookup("KIMI_MODEL_TEMPERATURE"));
    setFloat(&overlay.top_p, lookup("KIMI_MODEL_TOP_P"));
    setUsize(&overlay.max_tokens, lookup("KIMI_MODEL_MAX_TOKENS"), 1, usize_max);
    setUsize(&overlay.max_context_size, lookup("KIMI_MODEL_MAX_CONTEXT_SIZE"), 1, usize_max);
    setUsize(&overlay.max_output_size, lookup("KIMI_MODEL_MAX_OUTPUT_SIZE"), 1, usize_max);
}

fn trimmed(raw: ?[]const u8) ?[]const u8 {
    const text = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    if (text.len == 0) return null;
    return text;
}

fn parseBool(text: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(text, "1") or std.ascii.eqlIgnoreCase(text, "true") or
        std.ascii.eqlIgnoreCase(text, "yes") or std.ascii.eqlIgnoreCase(text, "on")) return true;
    if (std.ascii.eqlIgnoreCase(text, "0") or std.ascii.eqlIgnoreCase(text, "false") or
        std.ascii.eqlIgnoreCase(text, "no") or std.ascii.eqlIgnoreCase(text, "off")) return false;
    return null;
}

fn setUsize(slot: *?usize, raw: ?[]const u8, min: usize, max: usize) void {
    const text = trimmed(raw) orelse return;
    const value = std.fmt.parseInt(usize, text, 10) catch return;
    if (value < min or value > max) return;
    slot.* = value;
}

fn setUsizeCapped(slot: *?usize, raw: ?[]const u8, min: usize, cap: usize) void {
    const text = trimmed(raw) orelse return;
    const value = std.fmt.parseInt(usize, text, 10) catch return;
    if (value < min) return;
    slot.* = @min(value, cap);
}

fn setPrintWaitCeilingFromMs(slot: *?usize, raw: ?[]const u8) void {
    const text = trimmed(raw) orelse return;
    const milliseconds = std.fmt.parseInt(usize, text, 10) catch return;
    slot.* = if (milliseconds == 0)
        kimi_sections.print_wait_no_ceiling_s
    else
        @min((milliseconds +| 999) / 1000, kimi_sections.print_wait_no_ceiling_s);
}

fn setBool(slot: *?bool, raw: ?[]const u8) void {
    const text = trimmed(raw) orelse return;
    slot.* = parseBool(text) orelse return;
}

fn setFloat(slot: *?f64, raw: ?[]const u8) void {
    const text = trimmed(raw) orelse return;
    slot.* = std.fmt.parseFloat(f64, text) catch return;
}

fn setString(alloc: Allocator, slot: *?[]u8, raw: ?[]const u8) !void {
    const text = trimmed(raw) orelse return;
    const copy = try alloc.dupe(u8, text);
    if (slot.*) |old| alloc.free(old);
    slot.* = copy;
}

fn fakeLookup(name: []const u8) ?[]const u8 {
    const values = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "KIMI_LOOP_MAX_STEPS_PER_TURN", .value = " 12 " },
        .{ .name = "KIMI_MCP_STARTUP_TIMEOUT_MS", .value = "0" },
        .{ .name = "KIMI_CODE_IDENTITY_NAME", .value = "Lantern" },
        .{ .name = "KIMI_CODE_EXPERIMENTAL_WAIT_FOR", .value = "on" },
        .{ .name = "KIMI_TOKEN_COUNTING_STRATEGY", .value = "estimated" },
        .{ .name = "KIMI_MODEL_TEMPERATURE", .value = "0.4" },
        .{ .name = "KIMI_MODEL_API_KEY", .value = "sk-test" },
        .{ .name = "KIMI_CRON_DEBUG", .value = "maybe" },
    };
    for (values) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

test "KIMI env names override file values for coded sections" {
    var sections: Sections = .{};
    defer sections.deinit(std.testing.allocator);
    sections.loop_max_steps_per_turn = 3;
    sections.identity_name = try std.testing.allocator.dupe(u8, "old");
    try apply(std.testing.allocator, &sections, fakeLookup);
    try std.testing.expectEqual(@as(usize, 12), sections.loop_max_steps_per_turn.?);
    try std.testing.expectEqualStrings("Lantern", sections.identity_name.?);
    try std.testing.expect(sections.token_counting_strategy.? == .estimated);
}

fn printPolicyLookup(name: []const u8) ?[]const u8 {
    const values = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "KIMI_CODE_BACKGROUND_PRINT_BACKGROUND_MODE", .value = " exit " },
        .{ .name = "KIMI_CODE_BACKGROUND_PRINT_MAX_TURNS", .value = "9" },
        .{ .name = "KIMI_CODE_BACKGROUND_PRINT_WAIT_CEILING_S", .value = "0" },
    };
    for (values) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

test "KIMI env sets the print background mode and turn limit and ignores a zero wait ceiling" {
    var sections: Sections = .{ .task_print_wait_ceiling_s = 60 };
    defer sections.deinit(std.testing.allocator);
    try apply(std.testing.allocator, &sections, printPolicyLookup);
    try std.testing.expectEqual(kimi_sections.PrintBackgroundMode.exit, sections.task_print_background_mode.?);
    try std.testing.expectEqual(@as(usize, 9), sections.task_print_max_turns.?);
    try std.testing.expectEqual(@as(usize, 60), sections.task_print_wait_ceiling_s.?);
}

test "KIMI env ignores out of range and unparseable values" {
    var sections: Sections = .{};
    defer sections.deinit(std.testing.allocator);
    try apply(std.testing.allocator, &sections, fakeLookup);
    try std.testing.expect(sections.mcp_startup_timeout_ms == null);
    try std.testing.expect(sections.cron_debug == null);
    try std.testing.expect(sections.loop_max_attempts_per_step == null);
}

test "KIMI env experimental flag and model overlay are recorded" {
    var sections: Sections = .{};
    defer sections.deinit(std.testing.allocator);
    try apply(std.testing.allocator, &sections, fakeLookup);
    try std.testing.expectEqualStrings("wait_for", sections.experimental.?[0].name);
    try std.testing.expectEqual(true, sections.experimental.?[0].enabled);
    try std.testing.expectEqualStrings("sk-test", sections.model_env.api_key.?);
    try std.testing.expectEqual(@as(f64, 0.4), sections.model_env.temperature.?);
}

fn mcpTimeoutLookup(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "MCP_TIMEOUT")) return "10000";
    if (std.mem.eql(u8, name, "MCP_TOOL_TIMEOUT")) return "720000";
    if (std.mem.eql(u8, name, "KIMI_MCP_TOOL_TIMEOUT_MS")) return "45000";
    return null;
}

test "MCP_TIMEOUT and MCP_TOOL_TIMEOUT set the MCP startup and tool timeouts, and a KIMI name wins over them" {
    var sections: Sections = .{};
    defer sections.deinit(std.testing.allocator);
    try apply(std.testing.allocator, &sections, mcpTimeoutLookup);
    try std.testing.expectEqual(@as(usize, 10_000), sections.mcp_startup_timeout_ms.?);
    try std.testing.expectEqual(@as(usize, 45_000), sections.mcp_tool_timeout_ms.?);
}

fn claudeCodeLookup(name: []const u8) ?[]const u8 {
    const values = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "MCP_TIMEOUT", .value = "45000" },
        .{ .name = "BASH_MAX_OUTPUT_LENGTH", .value = "900000" },
        .{ .name = "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS", .value = "1" },
        .{ .name = "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS", .value = "600001" },
    };
    for (values) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
}

fn claudeCodeAndKimiLookup(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "KIMI_MCP_STARTUP_TIMEOUT_MS")) return "9000";
    if (std.mem.eql(u8, name, "BASH_MAX_OUTPUT_LENGTH")) return "0";
    if (std.mem.eql(u8, name, "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS")) return "0";
    return claudeCodeLookup(name);
}

test "MCP_TIMEOUT, BASH_MAX_OUTPUT_LENGTH, CLAUDE_CODE_DISABLE_BACKGROUND_TASKS and CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS set their sections" {
    var sections: Sections = .{};
    defer sections.deinit(std.testing.allocator);
    try apply(std.testing.allocator, &sections, claudeCodeLookup);
    try std.testing.expectEqual(@as(usize, 45_000), sections.mcp_startup_timeout_ms.?);
    try std.testing.expectEqual(kimi_sections.max_bash_output_chars, sections.task_bash_output_max_chars.?);
    try std.testing.expectEqual(true, sections.task_background_disabled.?);
    try std.testing.expectEqual(@as(usize, 601), sections.task_print_wait_ceiling_s.?);

    var both: Sections = .{ .task_bash_output_max_chars = 5000, .task_print_wait_ceiling_s = 60 };
    defer both.deinit(std.testing.allocator);
    try apply(std.testing.allocator, &both, claudeCodeAndKimiLookup);
    try std.testing.expectEqual(@as(usize, 9_000), both.mcp_startup_timeout_ms.?);
    try std.testing.expectEqual(@as(usize, 5000), both.task_bash_output_max_chars.?);
    try std.testing.expectEqual(kimi_sections.print_wait_no_ceiling_s, both.task_print_wait_ceiling_s.?);
}

fn masterLookup(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "KIMI_CODE_EXPERIMENTAL_FLAG")) return "true";
    if (std.mem.eql(u8, name, "KIMI_CODE_EXPERIMENTAL_TOOL_SELECT")) return "false";
    return null;
}

test "KIMI master experimental flag applies to unconfigured flags only" {
    var sections: Sections = .{};
    defer sections.deinit(std.testing.allocator);
    try setExperimentalFlag(std.testing.allocator, &sections, "wait_for", false);
    try apply(std.testing.allocator, &sections, masterLookup);
    try std.testing.expect(!kimi_sections.experimentalEnabled(&sections, "wait_for"));
    try std.testing.expect(kimi_sections.experimentalEnabled(&sections, "notify_user"));
    try std.testing.expect(!kimi_sections.experimentalEnabled(&sections, "tool_select"));
    try std.testing.expect(kimi_sections.experimentalEnabled(&sections, "subagent_fork"));
}
