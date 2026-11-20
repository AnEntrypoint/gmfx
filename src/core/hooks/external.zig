const std = @import("std");
const regex = @import("../shared/regex.zig");

const Allocator = std.mem.Allocator;

pub const default_timeout_seconds: u32 = 30;
pub const min_timeout_seconds: i64 = 1;
pub const max_timeout_seconds: i64 = 600;
pub const heartbeat_interval_ms: u64 = 60_000;
pub const tool_output_preview_bytes: usize = 2000;
pub const client_type = "fx_cli";
const whitespace = " \t\r\n";

pub const Event = enum {
    PreToolUse,
    PostToolUse,
    PostToolUseFailure,
    PermissionRequest,
    PermissionResult,
    UserPromptSubmit,
    UserPromptQueued,
    TurnStarted,
    Stop,
    StopFailure,
    Interrupt,
    SessionStart,
    SessionEnd,
    SessionHeartbeat,
    SubagentStart,
    SubagentStop,
    TaskStarted,
    PreCompact,
    PostCompact,
    Notification,
    Setup,
    UserPromptExpansion,
    PermissionDenied,
    PostToolBatch,
    MessageDisplay,
    TaskCreated,
    TaskCompleted,
    TeammateIdle,
    InstructionsLoaded,
    ConfigChange,
    CwdChanged,
    DirectoryAdded,
    FileChanged,
    WorktreeCreate,
    WorktreeRemove,
    PreModelSwitch,
    PostModelSwitch,
    Elicitation,
    ElicitationResult,

    pub fn blockable(self: Event) bool {
        return switch (self) {
            .PreToolUse, .UserPromptSubmit, .Stop => true,
            else => false,
        };
    }

    pub fn acceptsDecision(self: Event, dialect: Dialect) bool {
        if (self.blockable()) return true;
        if (dialect != .claude) return false;
        return switch (self) {
            .PostToolUse, .SubagentStop, .PreCompact => true,
            else => false,
        };
    }

    pub fn emitted(self: Event) bool {
        return switch (self) {
            .Setup,
            .UserPromptExpansion,
            .MessageDisplay,
            .TeammateIdle,
            .InstructionsLoaded,
            .ConfigChange,
            .CwdChanged,
            .DirectoryAdded,
            .FileChanged,
            .WorktreeCreate,
            .WorktreeRemove,
            .PreModelSwitch,
            .PostModelSwitch,
            .Elicitation,
            .ElicitationResult,
            => false,
            else => true,
        };
    }

    pub fn observation(self: Event) bool {
        return switch (self) {
            .PostToolUse,
            .PostToolUseFailure,
            .PermissionRequest,
            .PermissionResult,
            .UserPromptQueued,
            .TurnStarted,
            .SessionStart,
            .SessionEnd,
            .SubagentStart,
            .SubagentStop,
            .TaskStarted,
            .PreCompact,
            .PostCompact,
            .Notification,
            .PermissionDenied,
            .PostToolBatch,
            .TaskCreated,
            .TaskCompleted,
            => true,
            else => false,
        };
    }
};

pub const claude_code_event_names = [_][]const u8{
    "SessionStart",      "Setup",             "UserPromptSubmit", "UserPromptExpansion", "PreToolUse",
    "PermissionRequest", "PermissionDenied",  "PostToolUse",      "PostToolUseFailure",  "PostToolBatch",
    "Notification",      "MessageDisplay",    "SubagentStart",    "SubagentStop",        "TaskCreated",
    "TaskCompleted",     "Stop",              "StopFailure",      "TeammateIdle",        "InstructionsLoaded",
    "ConfigChange",      "CwdChanged",        "DirectoryAdded",   "FileChanged",         "WorktreeCreate",
    "WorktreeRemove",    "PreCompact",        "PostCompact",      "PreModelSwitch",      "PostModelSwitch",
    "Elicitation",       "ElicitationResult", "SessionEnd",
};

pub const Dialect = enum {
    kimi,
    claude,
};

pub const OnFailure = enum {
    @"continue",
    block,
};

pub const session_end_budget_ms: u32 = 1500;

pub fn claudeDefaultTimeoutSeconds(event: Event) u32 {
    return switch (event) {
        .UserPromptSubmit, .PreModelSwitch, .PostModelSwitch => 30,
        .MessageDisplay => 10,
        .SessionEnd => 2,
        else => 600,
    };
}

pub const Policy = struct {
    on_failure: OnFailure = .@"continue",
    dialect: Dialect = .kimi,
    timeout_seconds: u32 = default_timeout_seconds,
};

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

pub const Definition = struct {
    event: Event,
    matcher: ?[]u8 = null,
    command: []u8,
    timeout_seconds: u32 = default_timeout_seconds,
    cwd: ?[]u8 = null,
    env: []const EnvVar = &.{},
    on_failure: OnFailure = .@"continue",
    dialect: Dialect = .kimi,
    deadline_ms: ?u32 = null,

    pub fn deadlineMs(self: Definition) u64 {
        if (self.deadline_ms) |budget| return budget;
        return @as(u64, self.timeout_seconds) * std.time.ms_per_s;
    }

    pub fn policy(self: Definition) Policy {
        return .{
            .on_failure = self.on_failure,
            .dialect = self.dialect,
            .timeout_seconds = self.timeout_seconds,
        };
    }

    pub fn deinit(self: *Definition, alloc: Allocator) void {
        if (self.matcher) |matcher| alloc.free(matcher);
        if (self.cwd) |cwd| alloc.free(cwd);
        freeEnv(alloc, self.env);
        alloc.free(self.command);
        self.* = undefined;
    }

    pub fn replaceEnv(self: *Definition, alloc: Allocator, env: []const EnvVar) Allocator.Error!void {
        const copy = try cloneEnv(alloc, env);
        freeEnv(alloc, self.env);
        self.env = copy;
    }
};

fn freeEnv(alloc: Allocator, env: []const EnvVar) void {
    if (env.len == 0) return;
    for (env) |variable| {
        alloc.free(variable.name);
        alloc.free(variable.value);
    }
    alloc.free(env);
}

fn cloneEnv(alloc: Allocator, env: []const EnvVar) Allocator.Error![]const EnvVar {
    if (env.len == 0) return &.{};
    const copy = try alloc.alloc(EnvVar, env.len);
    var filled: usize = 0;
    errdefer {
        for (copy[0..filled]) |variable| {
            alloc.free(variable.name);
            alloc.free(variable.value);
        }
        alloc.free(copy);
    }
    for (env) |variable| {
        const name = try alloc.dupe(u8, variable.name);
        errdefer alloc.free(name);
        copy[filled] = .{ .name = name, .value = try alloc.dupe(u8, variable.value) };
        filled += 1;
    }
    return copy;
}

pub const ParseError = error{ InvalidHooksConfig, OutOfMemory };

const known_keys = [_][]const u8{ "event", "matcher", "command", "timeout", "onFailure" };
const group_keys = [_][]const u8{ "matcher", "hooks", "timeout", "onFailure" };
const handler_keys = [_][]const u8{ "type", "command", "timeout", "onFailure", "statusMessage" };
const command_handler_type = "command";

pub fn parseDefinitions(alloc: Allocator, value: std.json.Value) ParseError![]Definition {
    var list: std.ArrayList(Definition) = .empty;
    errdefer {
        for (list.items) |*definition| definition.deinit(alloc);
        list.deinit(alloc);
    }
    switch (value) {
        .array => |items| for (items.items) |item| {
            var definition = try parseDefinition(alloc, item);
            errdefer definition.deinit(alloc);
            try list.append(alloc, definition);
        },
        .object => |events| try appendEventGroups(alloc, &list, events),
        else => return error.InvalidHooksConfig,
    }
    return list.toOwnedSlice(alloc);
}

fn appendEventGroups(alloc: Allocator, list: *std.ArrayList(Definition), events: std.json.ObjectMap) ParseError!void {
    var entries = events.iterator();
    while (entries.next()) |entry| {
        const event = std.meta.stringToEnum(Event, entry.key_ptr.*) orelse return error.InvalidHooksConfig;
        const groups = entry.value_ptr.*;
        if (groups != .array) return error.InvalidHooksConfig;
        for (groups.array.items) |group| try appendGroup(alloc, list, event, group);
    }
}

fn appendGroup(alloc: Allocator, list: *std.ArrayList(Definition), event: Event, group: std.json.Value) ParseError!void {
    if (group != .object) return error.InvalidHooksConfig;
    if (!onlyKeys(group.object, &group_keys)) return error.InvalidHooksConfig;
    const matcher_text: ?[]const u8 = if (group.object.get("matcher")) |matcher_value|
        stringValue(matcher_value) orelse return error.InvalidHooksConfig
    else
        null;
    const group_timeout = try optionalTimeout(group.object.get("timeout"));
    const group_on_failure = try optionalOnFailure(group.object.get("onFailure"));
    const handlers = group.object.get("hooks") orelse return error.InvalidHooksConfig;
    if (handlers != .array) return error.InvalidHooksConfig;
    for (handlers.array.items) |handler| {
        if (handler != .object) return error.InvalidHooksConfig;
        if (!onlyKeys(handler.object, &handler_keys)) return error.InvalidHooksConfig;
        const handler_type = stringValue(handler.object.get("type")) orelse command_handler_type;
        if (!std.mem.eql(u8, handler_type, command_handler_type)) return error.InvalidHooksConfig;
        const command_text = stringValue(handler.object.get("command")) orelse return error.InvalidHooksConfig;
        if (command_text.len == 0) return error.InvalidHooksConfig;
        const explicit_timeout = (try optionalTimeout(handler.object.get("timeout"))) orelse group_timeout;
        const on_failure = (try optionalOnFailure(handler.object.get("onFailure"))) orelse group_on_failure orelse OnFailure.@"continue";

        var definition = Definition{
            .event = event,
            .command = try alloc.dupe(u8, command_text),
            .timeout_seconds = explicit_timeout orelse claudeDefaultTimeoutSeconds(event),
            .on_failure = on_failure,
            .dialect = .claude,
            .deadline_ms = if (explicit_timeout == null and event == .SessionEnd) session_end_budget_ms else null,
        };
        errdefer definition.deinit(alloc);
        if (matcher_text) |text| definition.matcher = try alloc.dupe(u8, text);
        try list.append(alloc, definition);
    }
}

fn onlyKeys(object: std.json.ObjectMap, allowed: []const []const u8) bool {
    var keys = object.iterator();
    while (keys.next()) |entry| {
        if (!nameIn(allowed, entry.key_ptr.*)) return false;
    }
    return true;
}

fn nameIn(names: []const []const u8, name: []const u8) bool {
    for (names) |known| {
        if (std.mem.eql(u8, known, name)) return true;
    }
    return false;
}

fn optionalTimeout(value: ?std.json.Value) ParseError!?u32 {
    if (value == null) return null;
    return try timeoutValue(value);
}

fn optionalOnFailure(value: ?std.json.Value) ParseError!?OnFailure {
    const present = value orelse return null;
    const text = stringValue(present) orelse return error.InvalidHooksConfig;
    return std.meta.stringToEnum(OnFailure, text) orelse return error.InvalidHooksConfig;
}

pub fn parseDefinitionsIn(alloc: Allocator, value: std.json.Value, cwd: []const u8) ParseError![]Definition {
    const definitions = try parseDefinitions(alloc, value);
    errdefer freeDefinitions(alloc, definitions);
    for (definitions) |*definition| {
        definition.cwd = try alloc.dupe(u8, cwd);
    }
    return definitions;
}

pub fn freeDefinitions(alloc: Allocator, definitions: []Definition) void {
    for (definitions) |*definition| definition.deinit(alloc);
    alloc.free(definitions);
}

pub fn cloneDefinitions(alloc: Allocator, definitions: []const Definition) Allocator.Error![]Definition {
    var list: std.ArrayList(Definition) = .empty;
    errdefer {
        for (list.items) |*definition| definition.deinit(alloc);
        list.deinit(alloc);
    }
    for (definitions) |source| {
        var copy = Definition{
            .event = source.event,
            .command = try alloc.dupe(u8, source.command),
            .timeout_seconds = source.timeout_seconds,
            .on_failure = source.on_failure,
            .dialect = source.dialect,
            .deadline_ms = source.deadline_ms,
        };
        errdefer alloc.free(copy.command);
        copy.matcher = if (source.matcher) |matcher| try alloc.dupe(u8, matcher) else null;
        errdefer if (copy.matcher) |owned| alloc.free(owned);
        copy.cwd = if (source.cwd) |cwd| try alloc.dupe(u8, cwd) else null;
        errdefer if (copy.cwd) |owned| alloc.free(owned);
        copy.env = try cloneEnv(alloc, source.env);
        errdefer freeEnv(alloc, copy.env);
        try list.append(alloc, copy);
    }
    return list.toOwnedSlice(alloc);
}

fn parseDefinition(alloc: Allocator, value: std.json.Value) ParseError!Definition {
    if (value != .object) return error.InvalidHooksConfig;
    var keys = value.object.iterator();
    while (keys.next()) |entry| {
        if (!isKnownKey(entry.key_ptr.*)) return error.InvalidHooksConfig;
    }

    const event_name = stringValue(value.object.get("event")) orelse return error.InvalidHooksConfig;
    const event = std.meta.stringToEnum(Event, event_name) orelse return error.InvalidHooksConfig;
    const command_text = stringValue(value.object.get("command")) orelse return error.InvalidHooksConfig;
    if (command_text.len == 0) return error.InvalidHooksConfig;
    const timeout_seconds = try timeoutValue(value.object.get("timeout"));
    const on_failure = (try optionalOnFailure(value.object.get("onFailure"))) orelse OnFailure.@"continue";

    const command = try alloc.dupe(u8, command_text);
    errdefer alloc.free(command);
    var matcher: ?[]u8 = null;
    if (value.object.get("matcher")) |matcher_value| {
        const matcher_text = stringValue(matcher_value) orelse return error.InvalidHooksConfig;
        matcher = try alloc.dupe(u8, matcher_text);
    }
    errdefer if (matcher) |owned| alloc.free(owned);

    return .{
        .event = event,
        .matcher = matcher,
        .command = command,
        .timeout_seconds = timeout_seconds,
        .on_failure = on_failure,
    };
}

fn isKnownKey(key: []const u8) bool {
    return nameIn(&known_keys, key);
}

fn stringValue(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}

fn objectValue(value: ?std.json.Value) ?std.json.ObjectMap {
    const present = value orelse return null;
    return switch (present) {
        .object => |object| object,
        else => null,
    };
}

fn timeoutValue(value: ?std.json.Value) ParseError!u32 {
    const present = value orelse return default_timeout_seconds;
    if (present != .integer) return error.InvalidHooksConfig;
    if (present.integer < min_timeout_seconds or present.integer > max_timeout_seconds) return error.InvalidHooksConfig;
    return @intCast(present.integer);
}

pub fn hasEvent(definitions: []const Definition, event: Event) bool {
    for (definitions) |definition| {
        if (definition.event == event) return true;
    }
    return false;
}

pub fn matcherAccepts(alloc: Allocator, pattern: ?[]const u8, value: []const u8) bool {
    const text = pattern orelse return true;
    if (text.len == 0) return true;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const program = regex.compile(arena.allocator(), text, .{}) catch return false;
    var matcher = regex.Matcher.init(arena.allocator(), program) catch return false;
    return matcher.matches(value);
}

pub const MatchValues = struct {
    kimi: ?[]const u8,
    claude: ?[]const u8,

    fn of(self: MatchValues, dialect: Dialect) ?[]const u8 {
        return switch (dialect) {
            .kimi => self.kimi,
            .claude => self.claude,
        };
    }
};

pub fn selectMatching(
    alloc: Allocator,
    definitions: []const Definition,
    event: Event,
    value: []const u8,
) Allocator.Error![]*const Definition {
    return selectMatchingValues(alloc, definitions, event, .{ .kimi = value, .claude = value });
}

pub fn selectMatchingValues(
    alloc: Allocator,
    definitions: []const Definition,
    event: Event,
    values: MatchValues,
) Allocator.Error![]*const Definition {
    var list: std.ArrayList(*const Definition) = .empty;
    errdefer list.deinit(alloc);
    for (definitions) |*definition| {
        if (definition.event != event) continue;
        const value = values.of(definition.dialect) orelse continue;
        if (!matcherAccepts(alloc, definition.matcher, value)) continue;
        if (containsTarget(list.items, definition)) continue;
        try list.append(alloc, definition);
    }
    return list.toOwnedSlice(alloc);
}

fn containsTarget(selected: []const *const Definition, candidate: *const Definition) bool {
    for (selected) |definition| {
        if (std.mem.eql(u8, definition.command, candidate.command) and
            std.mem.eql(u8, cwdOf(definition), cwdOf(candidate))) return true;
    }
    return false;
}

fn cwdOf(definition: *const Definition) []const u8 {
    const cwd: []const u8 = if (definition.cwd) |owned| owned else "";
    return cwd;
}

pub const Base = struct {
    session_id: []const u8,
    cwd: []const u8,
    session_title: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    permission_mode: ?[]const u8 = null,
};

pub const Field = struct {
    key: []const u8,
    value: std.json.Value,
};

pub fn encodePayload(alloc: Allocator, event: Event, base: Base, fields: []const Field) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"hook_event_name\":");
    try std.json.Stringify.value(@tagName(event), .{}, writer);
    try writeMember(writer, "session_id", base.session_id);
    try writeMember(writer, "cwd", base.cwd);
    try writeMember(writer, "client_type", client_type);
    if (base.transcript_path) |path| try writeMember(writer, "transcript_path", path);
    if (base.permission_mode) |mode| try writeMember(writer, "permission_mode", mode);
    if (base.session_title) |title| {
        if (!carriesKey(fields, session_title_key)) try writeMember(writer, session_title_key, title);
    }
    for (fields) |field| try writeMember(writer, field.key, field.value);
    if (!carriesKey(fields, tool_use_id_key)) {
        for (fields) |field| {
            if (std.mem.eql(u8, field.key, tool_call_id_key)) try writeMember(writer, tool_use_id_key, field.value);
        }
    }
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

const session_title_key = "session_title";
const tool_call_id_key = "tool_call_id";
const tool_use_id_key = "tool_use_id";

fn carriesKey(fields: []const Field, key: []const u8) bool {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key)) return true;
    }
    return false;
}

fn writeMember(writer: *std.Io.Writer, key: []const u8, value: anytype) !void {
    try writer.writeByte(',');
    try std.json.Stringify.value(key, .{}, writer);
    try writer.writeByte(':');
    try std.json.Stringify.value(value, .{}, writer);
}

pub const Execution = struct {
    exit_code: ?u8 = null,
    timed_out: bool = false,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
};

pub const PermissionDecision = enum {
    allow,
    ask,
    @"defer",
    deny,

    fn rank(self: PermissionDecision) u8 {
        return switch (self) {
            .allow => 0,
            .ask => 1,
            .@"defer" => 2,
            .deny => 3,
        };
    }
};

pub fn strongerPermission(current: ?PermissionDecision, next: ?PermissionDecision) ?PermissionDecision {
    const held = current orelse return next;
    const offered = next orelse return held;
    return if (offered.rank() > held.rank()) offered else held;
}

pub const PermissionBehavior = enum {
    allow,
    deny,
};

pub const Verdict = struct {
    blocked: bool = false,
    structured: bool = false,
    reason: ?[]u8 = null,
    message: ?[]u8 = null,
    updated_input: ?[]u8 = null,
    permission: ?PermissionDecision = null,
    permission_behavior: ?PermissionBehavior = null,
    updated_permissions: ?[]u8 = null,
    stop_requested: bool = false,
    stop_reason: ?[]u8 = null,
    system_message: ?[]u8 = null,
    terminal_sequence: ?[]u8 = null,
    additional_context: ?[]u8 = null,
    updated_tool_output: ?[]u8 = null,
    initial_user_message: ?[]u8 = null,
    session_title: ?[]u8 = null,
    watch_paths: ?[]u8 = null,
    reload_skills: bool = false,

    pub fn deinit(self: *Verdict, alloc: Allocator) void {
        const owned = [_]?[]u8{
            self.reason,
            self.message,
            self.updated_input,
            self.updated_permissions,
            self.stop_reason,
            self.system_message,
            self.terminal_sequence,
            self.additional_context,
            self.updated_tool_output,
            self.initial_user_message,
            self.session_title,
            self.watch_paths,
        };
        for (owned) |text| {
            if (text) |bytes| alloc.free(bytes);
        }
        self.* = .{};
    }
};

pub fn decide(alloc: Allocator, event: Event, execution: Execution) Allocator.Error!Verdict {
    return resolve(alloc, .{}, event, execution);
}

pub fn resolve(alloc: Allocator, policy: Policy, event: Event, execution: Execution) Allocator.Error!Verdict {
    if (execution.timed_out) return failureVerdict(alloc, policy, event, execution);
    const code = execution.exit_code orelse return failureVerdict(alloc, policy, event, execution);
    if (code == 2) {
        if (!event.acceptsDecision(policy.dialect)) return .{};
        return .{
            .blocked = true,
            .reason = try blockReason(alloc, event, execution.stderr),
        };
    }
    if (code != 0) return failureVerdict(alloc, policy, event, execution);
    return structuredVerdict(alloc, event, execution.stdout);
}

fn failureVerdict(alloc: Allocator, policy: Policy, event: Event, execution: Execution) Allocator.Error!Verdict {
    if (!event.acceptsDecision(policy.dialect)) return .{};
    if (execution.timed_out and (event == .Stop or event == .SubagentStop)) return .{};
    const timed_out_tool_gate = execution.timed_out and policy.dialect == .claude and event == .PreToolUse;
    if (policy.on_failure != .block and !timed_out_tool_gate) return .{};
    const message = (try failureMessage(alloc, policy.timeout_seconds, execution)) orelse return .{};
    defer alloc.free(message);
    return .{
        .blocked = true,
        .reason = try std.fmt.allocPrint(alloc, "{s} hook {s}", .{ @tagName(event), message }),
    };
}

fn structuredVerdict(alloc: Allocator, event: Event, stdout: []const u8) Allocator.Error!Verdict {
    const text = std.mem.trim(u8, stdout, whitespace);
    if (text.len == 0) return .{};
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), text, .{}) catch return .{};
    const root = objectValue(parsed.value) orelse return .{};
    const specific = objectValue(root.get("hookSpecificOutput"));

    var verdict: Verdict = .{ .structured = true };
    errdefer verdict.deinit(alloc);
    verdict.message = try dupeOptional(alloc, stringValue(root.get("message")) orelse nestedString(specific, "message"));
    verdict.system_message = try dupeOptional(alloc, stringValue(root.get("systemMessage")));
    verdict.terminal_sequence = try dupeOptional(alloc, stringValue(root.get("terminalSequence")));
    verdict.additional_context = try dupeOptional(alloc, nestedString(specific, "additionalContext") orelse stringValue(root.get("additionalContext")));
    verdict.stop_requested = continueRefused(root);
    if (verdict.stop_requested) verdict.stop_reason = try dupeOptional(alloc, stringValue(root.get("stopReason")));

    switch (event) {
        .PostToolUse => verdict.updated_tool_output = try textOrJson(alloc, nestedValue(specific, "updatedToolOutput") orelse root.get("updatedToolOutput")),
        .PermissionRequest => try readPermissionRequestOutput(alloc, &verdict, specific),
        .SessionStart => {
            verdict.initial_user_message = try dupeOptional(alloc, nestedString(specific, "initialUserMessage"));
            verdict.session_title = try dupeOptional(alloc, nestedString(specific, "sessionTitle"));
            verdict.watch_paths = try jsonOf(alloc, nestedArray(specific, "watchPaths"));
            verdict.reload_skills = nestedTrue(specific, "reloadSkills");
        },
        else => {},
    }

    if (!event.acceptsDecision(.claude)) return verdict;

    verdict.permission = std.meta.stringToEnum(PermissionDecision, nestedString(specific, "permissionDecision") orelse "");
    const denied = if (verdict.permission) |permission| permission == .deny else false;
    const decision_blocks = std.mem.eql(u8, stringValue(root.get("decision")) orelse "", "block");
    const halted = verdict.stop_requested and event != .Stop and event != .SubagentStop;
    const stop_allowed = verdict.stop_requested and (event == .Stop or event == .SubagentStop);
    if (stop_allowed or !(denied or decision_blocks or halted)) {
        verdict.updated_input = try updatedInputJson(alloc, event, specific);
        return verdict;
    }

    const reason_text: []const u8 = if (denied)
        nestedString(specific, "permissionDecisionReason") orelse ""
    else if (decision_blocks)
        stringValue(root.get("reason")) orelse ""
    else
        stringValue(root.get("stopReason")) orelse "";
    verdict.blocked = true;
    verdict.reason = try blockReason(alloc, event, reason_text);
    return verdict;
}

fn continueRefused(root: std.json.ObjectMap) bool {
    const value = root.get("continue") orelse return false;
    return value == .bool and !value.bool;
}

fn readPermissionRequestOutput(alloc: Allocator, verdict: *Verdict, specific: ?std.json.ObjectMap) Allocator.Error!void {
    const decision = objectValue(nestedValue(specific, "decision")) orelse return;
    const behavior = std.meta.stringToEnum(PermissionBehavior, stringValue(decision.get("behavior")) orelse "") orelse return;
    verdict.permission_behavior = behavior;
    switch (behavior) {
        .allow => {
            if (decision.get("updatedInput")) |updated| {
                if (objectValue(updated) != null) verdict.updated_input = try std.json.Stringify.valueAlloc(alloc, updated, .{});
            }
            if (decision.get("updatedPermissions")) |updated| {
                if (updated == .array) verdict.updated_permissions = try std.json.Stringify.valueAlloc(alloc, updated, .{});
            }
        },
        .deny => verdict.reason = try dupeOptional(alloc, stringValue(decision.get("message"))),
    }
}

fn dupeOptional(alloc: Allocator, text: ?[]const u8) Allocator.Error!?[]u8 {
    const source = text orelse return null;
    return try alloc.dupe(u8, source);
}

fn nestedValue(specific: ?std.json.ObjectMap, key: []const u8) ?std.json.Value {
    const object = specific orelse return null;
    return object.get(key);
}

fn nestedString(specific: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return stringValue(nestedValue(specific, key));
}

fn nestedArray(specific: ?std.json.ObjectMap, key: []const u8) ?std.json.Value {
    const value = nestedValue(specific, key) orelse return null;
    return if (value == .array) value else null;
}

fn nestedTrue(specific: ?std.json.ObjectMap, key: []const u8) bool {
    const value = nestedValue(specific, key) orelse return false;
    return value == .bool and value.bool;
}

fn jsonOf(alloc: Allocator, value: ?std.json.Value) Allocator.Error!?[]u8 {
    const present = value orelse return null;
    return try std.json.Stringify.valueAlloc(alloc, present, .{});
}

fn textOrJson(alloc: Allocator, value: ?std.json.Value) Allocator.Error!?[]u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |text| try alloc.dupe(u8, text),
        .null => null,
        else => try std.json.Stringify.valueAlloc(alloc, present, .{}),
    };
}

fn updatedInputJson(alloc: Allocator, event: Event, specific: ?std.json.ObjectMap) Allocator.Error!?[]u8 {
    if (event != .PreToolUse) return null;
    const value = (specific orelse return null).get("updatedInput") orelse return null;
    _ = objectValue(value) orelse return null;
    return try std.json.Stringify.valueAlloc(alloc, value, .{});
}

pub fn blockReason(alloc: Allocator, event: Event, raw: []const u8) Allocator.Error![]u8 {
    const trimmed = std.mem.trim(u8, raw, whitespace);
    if (trimmed.len != 0) return alloc.dupe(u8, trimmed);
    return std.fmt.allocPrint(alloc, "Blocked by {s} hook", .{@tagName(event)});
}

pub fn failureMessage(alloc: Allocator, timeout_seconds: u32, execution: Execution) Allocator.Error!?[]u8 {
    if (execution.timed_out) return try std.fmt.allocPrint(alloc, "timed out after {d}s", .{timeout_seconds});
    const code = execution.exit_code orelse return try alloc.dupe(u8, "did not exit normally");
    if (code == 0 or code == 2) return null;
    return try std.fmt.allocPrint(alloc, "exited with exit code {d}", .{code});
}

pub const resolved_telemetry_event = "external_hook_resolved";

pub const Resolution = struct {
    event: Event,
    blocked: bool = false,
    matched_count: usize = 0,
    failed_count: usize = 0,

    pub fn action(self: Resolution) []const u8 {
        return if (self.blocked) "block" else "allow";
    }
};

pub fn executionFailed(execution: Execution) bool {
    if (execution.timed_out) return true;
    const code = execution.exit_code orelse return true;
    return code != 0 and code != 2;
}

pub fn failureNotice(alloc: Allocator, event: Event, message: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "A {s} hook failed to execute: {s}. Hooks always run on this local machine; check that the hook command works locally. Later hook failures in this session are logged without another warning.",
        .{ @tagName(event), message },
    );
}

pub fn renderHookResult(alloc: Allocator, event: Event, message: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "<hook_result hook_event=\"{s}\">\n{s}\n</hook_result>", .{ @tagName(event), message });
}

pub fn renderBlockedPrompt(alloc: Allocator, verdict: Verdict) Allocator.Error![]u8 {
    if (verdict.message) |message| {
        const text = std.mem.trim(u8, message, whitespace);
        if (text.len != 0) return renderHookResult(alloc, .UserPromptSubmit, text);
    }
    const reason: []const u8 = if (verdict.reason) |owned| owned else "Blocked by UserPromptSubmit hook";
    return renderHookResult(alloc, .UserPromptSubmit, reason);
}

pub fn userPromptAppendText(alloc: Allocator, execution: Execution, verdict: Verdict) Allocator.Error!?[]u8 {
    if (execution.timed_out) return null;
    if (execution.exit_code) |code| {
        if (code != 0) return null;
    }
    if (verdict.message) |message| {
        const text = std.mem.trim(u8, message, whitespace);
        if (text.len != 0) return try renderHookResult(alloc, .UserPromptSubmit, text);
    }
    if (verdict.structured) return null;
    const stdout = std.mem.trim(u8, execution.stdout, whitespace);
    if (stdout.len == 0) return null;
    return try renderHookResult(alloc, .UserPromptSubmit, stdout);
}

pub fn toolOutputPreview(text: []const u8) []const u8 {
    if (text.len <= tool_output_preview_bytes) return text;
    var end: usize = tool_output_preview_bytes;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

fn parseJsonForTest(text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
}

test "external hooks config accepts the four strict fields with a 30 second default" {
    var parsed = try parseJsonForTest(
        \\[{"event":"PreToolUse","matcher":"^bash$","command":"echo ok","timeout":5},
        \\ {"event":"Stop","command":"true"}]
    );
    defer parsed.deinit();
    const definitions = try parseDefinitions(std.testing.allocator, parsed.value);
    defer freeDefinitions(std.testing.allocator, definitions);

    try std.testing.expectEqual(@as(usize, 2), definitions.len);
    try std.testing.expectEqual(Event.PreToolUse, definitions[0].event);
    try std.testing.expectEqualStrings("^bash$", definitions[0].matcher.?);
    try std.testing.expectEqualStrings("echo ok", definitions[0].command);
    try std.testing.expectEqual(@as(u32, 5), definitions[0].timeout_seconds);
    try std.testing.expectEqual(Event.Stop, definitions[1].event);
    try std.testing.expect(definitions[1].matcher == null);
    try std.testing.expectEqual(default_timeout_seconds, definitions[1].timeout_seconds);
}

test "external hooks config rejects unknown keys, unknown events, empty commands, and bad timeouts" {
    const cases = [_][]const u8{
        "[{\"event\":\"Stop\",\"command\":\"true\",\"extra\":1}]",
        "[{\"event\":\"Bogus\",\"command\":\"true\"}]",
        "[{\"event\":\"Stop\",\"command\":\"\"}]",
        "[{\"event\":\"Stop\",\"command\":\"true\",\"timeout\":0}]",
        "[{\"event\":\"Stop\",\"command\":\"true\",\"timeout\":601}]",
        "[{\"event\":\"Stop\",\"command\":\"true\",\"matcher\":null}]",
        "{\"event\":\"Stop\",\"command\":\"true\"}",
    };
    for (cases) |text| {
        var parsed = try parseJsonForTest(text);
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidHooksConfig, parseDefinitions(std.testing.allocator, parsed.value));
    }
}

test "external hooks matcher is an unanchored regex, empty matches all, invalid matches nothing" {
    try std.testing.expect(matcherAccepts(std.testing.allocator, null, "anything"));
    try std.testing.expect(matcherAccepts(std.testing.allocator, "", "anything"));
    try std.testing.expect(matcherAccepts(std.testing.allocator, "bash", "run_bash_now"));
    try std.testing.expect(!matcherAccepts(std.testing.allocator, "^bash$", "run_bash_now"));
    try std.testing.expect(!matcherAccepts(std.testing.allocator, "([", "anything"));
}

test "external hooks selection keeps one entry per command for matching events" {
    var parsed = try parseJsonForTest(
        \\[{"event":"PreToolUse","matcher":"write","command":"guard"},
        \\ {"event":"PreToolUse","command":"guard"},
        \\ {"event":"PreToolUse","matcher":"read","command":"other"},
        \\ {"event":"Stop","command":"guard"}]
    );
    defer parsed.deinit();
    const definitions = try parseDefinitions(std.testing.allocator, parsed.value);
    defer freeDefinitions(std.testing.allocator, definitions);

    const selected = try selectMatching(std.testing.allocator, definitions, .PreToolUse, "write_file");
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqual(@as(usize, 1), selected.len);
    try std.testing.expectEqualStrings("guard", selected[0].command);
}

test "external hooks selection keeps the same command from different roots" {
    var parsed = try parseJsonForTest("[{\"event\":\"Stop\",\"command\":\"guard\"}]");
    defer parsed.deinit();
    const workspace = try parseDefinitions(std.testing.allocator, parsed.value);
    defer freeDefinitions(std.testing.allocator, workspace);
    const plugin = try parseDefinitionsIn(std.testing.allocator, parsed.value, "/plugins/demo");
    defer freeDefinitions(std.testing.allocator, plugin);

    const definitions = [_]Definition{ workspace[0], plugin[0] };
    const selected = try selectMatching(std.testing.allocator, &definitions, .Stop, "");
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqual(@as(usize, 2), selected.len);
}

test "external hooks definitions from a plugin root carry the root as their cwd" {
    var parsed = try parseJsonForTest("[{\"event\":\"Stop\",\"command\":\"true\"}]");
    defer parsed.deinit();
    const definitions = try parseDefinitionsIn(std.testing.allocator, parsed.value, "/plugins/demo");
    defer freeDefinitions(std.testing.allocator, definitions);
    try std.testing.expectEqualStrings("/plugins/demo", definitions[0].cwd.?);

    const copies = try cloneDefinitions(std.testing.allocator, definitions);
    defer freeDefinitions(std.testing.allocator, copies);
    try std.testing.expectEqualStrings("/plugins/demo", copies[0].cwd.?);
}

test "external hooks payload carries snake_case base and event fields" {
    const payload = try encodePayload(
        std.testing.allocator,
        .PreToolUse,
        .{ .session_id = "s1", .cwd = "/work", .session_title = "Title" },
        &.{
            .{ .key = "tool_name", .value = .{ .string = "write_file" } },
            .{ .key = "tool_call_id", .value = .{ .string = "call-1" } },
        },
    );
    defer std.testing.allocator.free(payload);

    try std.testing.expectEqualStrings(
        "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"s1\",\"cwd\":\"/work\",\"client_type\":\"fx_cli\",\"session_title\":\"Title\",\"tool_name\":\"write_file\",\"tool_call_id\":\"call-1\",\"tool_use_id\":\"call-1\"}",
        payload,
    );
}

test "external hooks payload omits an absent session title" {
    const payload = try encodePayload(std.testing.allocator, .Stop, .{ .session_id = "s", .cwd = "/" }, &.{});
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "session_title") == null);
}

test "exit code 2 blocks blockable events with trimmed stderr or the default reason" {
    var verdict = try decide(std.testing.allocator, .PreToolUse, .{ .exit_code = 2, .stderr = "  no writes \n" });
    defer verdict.deinit(std.testing.allocator);
    try std.testing.expect(verdict.blocked);
    try std.testing.expectEqualStrings("no writes", verdict.reason.?);

    var fallback = try decide(std.testing.allocator, .Stop, .{ .exit_code = 2, .stderr = " \n" });
    defer fallback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Blocked by Stop hook", fallback.reason.?);
}

test "exit 0 stdout JSON denies with the permission reason and keeps the message" {
    var verdict = try decide(
        std.testing.allocator,
        .UserPromptSubmit,
        .{ .exit_code = 0, .stdout = "{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"nope\",\"message\":\"note\"}}" },
    );
    defer verdict.deinit(std.testing.allocator);
    try std.testing.expect(verdict.blocked);
    try std.testing.expectEqualStrings("nope", verdict.reason.?);
    try std.testing.expectEqualStrings("note", verdict.message.?);
}

test "PreToolUse updatedInput object is carried as replacement arguments unless denied" {
    var allowed = try decide(std.testing.allocator, .PreToolUse, .{
        .exit_code = 0,
        .stdout = "{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\",\"updatedInput\":{\"path\":\"b.txt\"}}}",
    });
    defer allowed.deinit(std.testing.allocator);
    try std.testing.expect(!allowed.blocked);
    try std.testing.expectEqualStrings("{\"path\":\"b.txt\"}", allowed.updated_input.?);

    var non_object = try decide(std.testing.allocator, .PreToolUse, .{
        .exit_code = 0,
        .stdout = "{\"hookSpecificOutput\":{\"updatedInput\":[1]}}",
    });
    defer non_object.deinit(std.testing.allocator);
    try std.testing.expect(non_object.updated_input == null);

    var denied = try decide(std.testing.allocator, .PreToolUse, .{
        .exit_code = 0,
        .stdout = "{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"no\",\"updatedInput\":{\"path\":\"b.txt\"}}}",
    });
    defer denied.deinit(std.testing.allocator);
    try std.testing.expect(denied.blocked);
    try std.testing.expect(denied.updated_input == null);

    var other_event = try decide(std.testing.allocator, .UserPromptSubmit, .{
        .exit_code = 0,
        .stdout = "{\"hookSpecificOutput\":{\"updatedInput\":{\"path\":\"b.txt\"}}}",
    });
    defer other_event.deinit(std.testing.allocator);
    try std.testing.expect(other_event.updated_input == null);
}

test "exit 0 non-JSON stdout and other exit codes allow the call" {
    var plain = try decide(std.testing.allocator, .PreToolUse, .{ .exit_code = 0, .stdout = "hello" });
    defer plain.deinit(std.testing.allocator);
    try std.testing.expect(!plain.blocked);
    try std.testing.expect(plain.message == null);

    var failed = try decide(std.testing.allocator, .PreToolUse, .{ .exit_code = 1, .stderr = "boom" });
    defer failed.deinit(std.testing.allocator);
    try std.testing.expect(!failed.blocked);

    var timed_out = try decide(std.testing.allocator, .PreToolUse, .{ .exit_code = 2, .timed_out = true, .stderr = "late" });
    defer timed_out.deinit(std.testing.allocator);
    try std.testing.expect(!timed_out.blocked);
}

test "observation-only events never block and ignore stdout" {
    var verdict = try decide(std.testing.allocator, .SessionStart, .{ .exit_code = 2, .stderr = "stop" });
    defer verdict.deinit(std.testing.allocator);
    try std.testing.expect(!verdict.blocked);
    try std.testing.expect(verdict.message == null);
    try std.testing.expect(!Event.Notification.blockable());
    try std.testing.expect(Event.UserPromptSubmit.blockable());
}

test "observation events are classified apart from the blockable and lifecycle-routed events" {
    try std.testing.expect(Event.PostToolUse.observation());
    try std.testing.expect(Event.PermissionRequest.observation());
    try std.testing.expect(Event.Notification.observation());
    try std.testing.expect(!Event.UserPromptSubmit.observation());
    try std.testing.expect(!Event.Stop.observation());
    try std.testing.expect(!Event.StopFailure.observation());
    try std.testing.expect(!Event.SessionHeartbeat.observation());
}

test "external hooks heartbeat runs every minute and hasEvent finds the configured events" {
    try std.testing.expectEqual(@as(u64, 60_000), heartbeat_interval_ms);
    var parsed = try parseJsonForTest("[{\"event\":\"SessionHeartbeat\",\"command\":\"true\"}]");
    defer parsed.deinit();
    const definitions = try parseDefinitions(std.testing.allocator, parsed.value);
    defer freeDefinitions(std.testing.allocator, definitions);
    try std.testing.expect(hasEvent(definitions, .SessionHeartbeat));
    try std.testing.expect(!hasEvent(definitions, .Stop));
}

test "external hooks failure message names the timeout, the exit code and a missing status" {
    const timed = (try failureMessage(std.testing.allocator, 7, .{ .timed_out = true })).?;
    defer std.testing.allocator.free(timed);
    try std.testing.expectEqualStrings("timed out after 7s", timed);

    const exited = (try failureMessage(std.testing.allocator, 7, .{ .exit_code = 3 })).?;
    defer std.testing.allocator.free(exited);
    try std.testing.expectEqualStrings("exited with exit code 3", exited);

    const missing = (try failureMessage(std.testing.allocator, 7, .{})).?;
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqualStrings("did not exit normally", missing);

    try std.testing.expect((try failureMessage(std.testing.allocator, 7, .{ .exit_code = 0 })) == null);
    try std.testing.expect((try failureMessage(std.testing.allocator, 7, .{ .exit_code = 2 })) == null);
}

test "external hooks failure notice repeats the warning text" {
    const notice = try failureNotice(std.testing.allocator, .SessionStart, "exited with exit code 3");
    defer std.testing.allocator.free(notice);
    try std.testing.expectEqualStrings(
        "A SessionStart hook failed to execute: exited with exit code 3. Hooks always run on this local machine; check that the hook command works locally. Later hook failures in this session are logged without another warning.",
        notice,
    );
}

test "user prompt block renders the hook message, then the reason, then the default" {
    var with_message = try decide(
        std.testing.allocator,
        .UserPromptSubmit,
        .{ .exit_code = 0, .stdout = "{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"nope\",\"message\":\"  note  \"}}" },
    );
    defer with_message.deinit(std.testing.allocator);
    const message_text = try renderBlockedPrompt(std.testing.allocator, with_message);
    defer std.testing.allocator.free(message_text);
    try std.testing.expectEqualStrings("<hook_result hook_event=\"UserPromptSubmit\">\nnote\n</hook_result>", message_text);

    var exit_two = try decide(std.testing.allocator, .UserPromptSubmit, .{ .exit_code = 2, .stderr = " stop \n" });
    defer exit_two.deinit(std.testing.allocator);
    const reason_text = try renderBlockedPrompt(std.testing.allocator, exit_two);
    defer std.testing.allocator.free(reason_text);
    try std.testing.expectEqualStrings("<hook_result hook_event=\"UserPromptSubmit\">\nstop\n</hook_result>", reason_text);

    var silent = try decide(std.testing.allocator, .UserPromptSubmit, .{ .exit_code = 2, .stderr = " \n" });
    defer silent.deinit(std.testing.allocator);
    const default_text = try renderBlockedPrompt(std.testing.allocator, silent);
    defer std.testing.allocator.free(default_text);
    try std.testing.expectEqualStrings("<hook_result hook_event=\"UserPromptSubmit\">\nBlocked by UserPromptSubmit hook\n</hook_result>", default_text);
}

test "user prompt append renders plain stdout and skips failed, timed out, and structured hooks" {
    var plain_verdict = try decide(std.testing.allocator, .UserPromptSubmit, .{ .exit_code = 0, .stdout = " context line \n" });
    defer plain_verdict.deinit(std.testing.allocator);
    const plain = (try userPromptAppendText(std.testing.allocator, .{ .exit_code = 0, .stdout = " context line \n" }, plain_verdict)).?;
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("<hook_result hook_event=\"UserPromptSubmit\">\ncontext line\n</hook_result>", plain);

    try std.testing.expect((try userPromptAppendText(std.testing.allocator, .{ .exit_code = 1, .stdout = "ignored" }, .{})) == null);
    try std.testing.expect((try userPromptAppendText(std.testing.allocator, .{ .timed_out = true, .stdout = "late" }, .{})) == null);
    try std.testing.expect((try userPromptAppendText(std.testing.allocator, .{ .exit_code = 0, .stdout = "{\"hookSpecificOutput\":{}}" }, .{ .structured = true })) == null);
}

test "tool output preview keeps at most 2000 bytes on a UTF-8 boundary" {
    try std.testing.expectEqualStrings("abc", toolOutputPreview("abc"));

    var long: [2001]u8 = undefined;
    @memset(&long, 'a');
    try std.testing.expectEqual(@as(usize, 2000), toolOutputPreview(&long).len);

    var split: [2001]u8 = undefined;
    @memset(split[0..1999], 'a');
    split[1999] = 0xC3;
    split[2000] = 0xA9;
    try std.testing.expectEqual(@as(usize, 1999), toolOutputPreview(&split).len);
}

pub fn sessionHeartbeatEnabled(definitions: []const Definition) bool {
    return hasEvent(definitions, .SessionHeartbeat);
}

test "session lifecycle payloads name the event and carry their fields" {
    const alloc = std.testing.allocator;
    const start = try encodePayload(alloc, .SessionStart, .{ .session_id = "s", .cwd = "/w" }, &.{
        .{ .key = "source", .value = .{ .string = "startup" } },
    });
    defer alloc.free(start);
    try std.testing.expect(std.mem.indexOf(u8, start, "\"hook_event_name\":\"SessionStart\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, start, "\"source\":\"startup\"") != null);

    const end = try encodePayload(alloc, .SessionEnd, .{ .session_id = "s", .cwd = "/w" }, &.{
        .{ .key = "reason", .value = .{ .string = "exit" } },
    });
    defer alloc.free(end);
    try std.testing.expect(std.mem.indexOf(u8, end, "\"hook_event_name\":\"SessionEnd\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, end, "\"reason\":\"exit\"") != null);
}

test "session heartbeat gate reads only SessionHeartbeat definitions" {
    const stop_only = [_]Definition{.{ .event = .Stop, .command = @constCast("true") }};
    const heartbeat = [_]Definition{.{ .event = .SessionHeartbeat, .command = @constCast("true") }};
    try std.testing.expect(!sessionHeartbeatEnabled(&stop_only));
    try std.testing.expect(sessionHeartbeatEnabled(&heartbeat));
}

pub const SessionSource = enum {
    startup,
    @"resume",
    clear,
    compact,
    fork,

    pub fn kimiName(self: SessionSource) ?[]const u8 {
        return switch (self) {
            .startup, .clear => "startup",
            .@"resume" => "resume",
            .compact, .fork => null,
        };
    }
};

pub const SessionEndReason = enum {
    exit,
    archive,
};

pub const uptime_key = "uptime_ms";

pub fn sessionStartFields(source: SessionSource, model: []const u8, profile: ?[]const u8) [3]Field {
    return sessionStartFieldsNamed(@tagName(source), model, profile);
}

pub fn sessionStartFieldsNamed(source_name: []const u8, model: []const u8, profile: ?[]const u8) [3]Field {
    return .{
        .{ .key = "source", .value = .{ .string = source_name } },
        .{ .key = "model", .value = .{ .string = model } },
        .{ .key = "profile", .value = if (profile) |name| .{ .string = name } else .null },
    };
}

test "session start payload carries the source, model and profile next to the session id" {
    const alloc = std.testing.allocator;
    const named = sessionStartFields(.startup, "grok-4.7", "work");
    const named_payload = try encodePayload(alloc, .SessionStart, .{ .session_id = "s1", .cwd = "/tmp" }, &named);
    defer alloc.free(named_payload);
    try std.testing.expect(std.mem.indexOf(u8, named_payload, "\"session_id\":\"s1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, named_payload, "\"source\":\"startup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, named_payload, "\"model\":\"grok-4.7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, named_payload, "\"profile\":\"work\"") != null);

    const unnamed = sessionStartFields(.@"resume", "grok-4.7", null);
    const unnamed_payload = try encodePayload(alloc, .SessionStart, .{ .session_id = "s1", .cwd = "/tmp" }, &unnamed);
    defer alloc.free(unnamed_payload);
    try std.testing.expect(std.mem.indexOf(u8, unnamed_payload, "\"profile\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, unnamed_payload, "\"source\":\"resume\"") != null);
}

test "external hooks payload writes a session title field once when the event fields carry it" {
    const payload = try encodePayload(
        std.testing.allocator,
        .SubagentStart,
        .{ .session_id = "s1", .cwd = "/work", .session_title = "From the scope" },
        &.{.{ .key = "session_title", .value = .{ .string = "From the event" } }},
    );
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, payload, "\"session_title\""));
    try std.testing.expect(std.mem.indexOf(u8, payload, "From the event") != null);
}

test "external hooks definition env is owned, cloned and replaced without leaks" {
    const alloc = std.testing.allocator;
    var parsed = try parseJsonForTest("[{\"event\":\"Stop\",\"command\":\"true\"}]");
    defer parsed.deinit();
    const definitions = try parseDefinitionsIn(alloc, parsed.value, "/plugins/demo");
    defer freeDefinitions(alloc, definitions);
    try std.testing.expectEqual(@as(usize, 0), definitions[0].env.len);

    try definitions[0].replaceEnv(alloc, &.{.{ .name = "FX_PLUGIN_ROOT", .value = "/old" }});
    try definitions[0].replaceEnv(alloc, &.{
        .{ .name = "FX_PLUGIN_ROOT", .value = "/plugins/demo" },
        .{ .name = "FX_HOME", .value = "/home/example/.fx" },
    });

    const copies = try cloneDefinitions(alloc, definitions);
    defer freeDefinitions(alloc, copies);
    try std.testing.expectEqual(@as(usize, 2), copies[0].env.len);
    try std.testing.expectEqualStrings("FX_PLUGIN_ROOT", copies[0].env[0].name);
    try std.testing.expectEqualStrings("/plugins/demo", copies[0].env[0].value);
    try std.testing.expectEqualStrings("/home/example/.fx", copies[0].env[1].value);
}

test "external hook resolution counts timeouts, missing exits and non-blocking failures as failed" {
    try std.testing.expect(executionFailed(.{ .timed_out = true }));
    try std.testing.expect(executionFailed(.{}));
    try std.testing.expect(executionFailed(.{ .exit_code = 1 }));
    try std.testing.expect(!executionFailed(.{ .exit_code = 0 }));
    try std.testing.expect(!executionFailed(.{ .exit_code = 2 }));
    const blocked: Resolution = .{ .event = .PreToolUse, .blocked = true, .matched_count = 2, .failed_count = 1 };
    try std.testing.expectEqualStrings("block", blocked.action());
    const allowed: Resolution = .{ .event = .Stop };
    try std.testing.expectEqualStrings("allow", allowed.action());
    try std.testing.expectEqualStrings("external_hook_resolved", resolved_telemetry_event);
}

test "Claude Code settings shape groups hooks by event with a matcher, a timeout and onFailure" {
    var parsed = try parseJsonForTest(
        \\{"PreToolUse":[{"matcher":"bash|write_file","onFailure":"block","hooks":[{"type":"command","command":"guard","timeout":5},{"command":"audit","onFailure":"continue"}]}],
        \\ "Notification":[{"matcher":"","hooks":[{"type":"command","command":"notify"}]}],
        \\ "UserPromptSubmit":[{"hooks":[{"type":"command","command":"check"}]}],
        \\ "SessionEnd":[{"hooks":[{"type":"command","command":"bye"}]}],
        \\ "MessageDisplay":[{"timeout":7,"hooks":[{"type":"command","command":"show"}]}]}
    );
    defer parsed.deinit();
    const definitions = try parseDefinitions(std.testing.allocator, parsed.value);
    defer freeDefinitions(std.testing.allocator, definitions);

    try std.testing.expectEqual(@as(usize, 6), definitions.len);
    var seen_guard = false;
    var seen_audit = false;
    for (definitions) |definition| {
        try std.testing.expectEqual(Dialect.claude, definition.dialect);
        if (std.mem.eql(u8, definition.command, "guard")) {
            seen_guard = true;
            try std.testing.expectEqual(Event.PreToolUse, definition.event);
            try std.testing.expectEqualStrings("bash|write_file", definition.matcher.?);
            try std.testing.expectEqual(@as(u32, 5), definition.timeout_seconds);
            try std.testing.expectEqual(OnFailure.block, definition.on_failure);
        }
        if (std.mem.eql(u8, definition.command, "audit")) {
            seen_audit = true;
            try std.testing.expectEqual(@as(u32, 600), definition.timeout_seconds);
            try std.testing.expectEqual(OnFailure.@"continue", definition.on_failure);
        }
        if (std.mem.eql(u8, definition.command, "notify")) {
            try std.testing.expectEqualStrings("", definition.matcher.?);
            try std.testing.expect(matcherAccepts(std.testing.allocator, definition.matcher, "permission_prompt"));
            try std.testing.expect(matcherAccepts(std.testing.allocator, definition.matcher, "idle_prompt"));
        }
        if (std.mem.eql(u8, definition.command, "check")) {
            try std.testing.expect(definition.matcher == null);
            try std.testing.expectEqual(@as(u32, 30), definition.timeout_seconds);
        }
        if (std.mem.eql(u8, definition.command, "bye")) {
            try std.testing.expectEqual(@as(u64, 1500), definition.deadlineMs());
        }
        if (std.mem.eql(u8, definition.command, "show")) {
            try std.testing.expectEqual(@as(u64, 7000), definition.deadlineMs());
        }
    }
    try std.testing.expect(seen_guard and seen_audit);
}

test "Claude Code settings shape rejects unknown events, handler types, keys and onFailure values" {
    const cases = [_][]const u8{
        "{\"Bogus\":[{\"hooks\":[{\"command\":\"true\"}]}]}",
        "{\"Stop\":{\"hooks\":[]}}",
        "{\"Stop\":[{\"matcher\":\"\"}]}",
        "{\"Stop\":[{\"hooks\":[{\"type\":\"prompt\",\"command\":\"true\"}]}]}",
        "{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\"}]}]}",
        "{\"Stop\":[{\"hooks\":[{\"command\":\"true\",\"extra\":1}]}]}",
        "{\"Stop\":[{\"extra\":1,\"hooks\":[]}]}",
        "{\"Stop\":[{\"onFailure\":\"halt\",\"hooks\":[]}]}",
        "{\"Stop\":[{\"hooks\":[{\"command\":\"true\",\"timeout\":0}]}]}",
        "[{\"event\":\"Stop\",\"command\":\"true\",\"onFailure\":\"halt\"}]",
    };
    for (cases) |text| {
        var parsed = try parseJsonForTest(text);
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidHooksConfig, parseDefinitions(std.testing.allocator, parsed.value));
    }
}

test "the flat hooks array keeps the 30 second default and takes onFailure" {
    var parsed = try parseJsonForTest("[{\"event\":\"PreToolUse\",\"command\":\"guard\",\"onFailure\":\"block\"}]");
    defer parsed.deinit();
    const definitions = try parseDefinitions(std.testing.allocator, parsed.value);
    defer freeDefinitions(std.testing.allocator, definitions);
    try std.testing.expectEqual(Dialect.kimi, definitions[0].dialect);
    try std.testing.expectEqual(default_timeout_seconds, definitions[0].timeout_seconds);
    try std.testing.expectEqual(OnFailure.block, definitions[0].on_failure);
    try std.testing.expectEqual(@as(u64, 30_000), definitions[0].deadlineMs());

    const copies = try cloneDefinitions(std.testing.allocator, definitions);
    defer freeDefinitions(std.testing.allocator, copies);
    try std.testing.expectEqual(OnFailure.block, copies[0].on_failure);
}

test "every Claude Code hook event name parses and the emitted set is named" {
    try std.testing.expectEqual(@as(usize, 33), claude_code_event_names.len);
    var emitted_count: usize = 0;
    for (claude_code_event_names) |name| {
        const event = std.meta.stringToEnum(Event, name) orelse return error.TestUnexpectedResult;
        if (event.emitted()) emitted_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 18), emitted_count);
    try std.testing.expect(Event.PermissionDenied.emitted());
    try std.testing.expect(Event.TaskCreated.observation());
    try std.testing.expect(!Event.WorktreeCreate.emitted());
}

test "Claude Code default timeouts follow the event" {
    try std.testing.expectEqual(@as(u32, 600), claudeDefaultTimeoutSeconds(.PreToolUse));
    try std.testing.expectEqual(@as(u32, 30), claudeDefaultTimeoutSeconds(.UserPromptSubmit));
    try std.testing.expectEqual(@as(u32, 30), claudeDefaultTimeoutSeconds(.PreModelSwitch));
    try std.testing.expectEqual(@as(u32, 30), claudeDefaultTimeoutSeconds(.PostModelSwitch));
    try std.testing.expectEqual(@as(u32, 10), claudeDefaultTimeoutSeconds(.MessageDisplay));
    try std.testing.expectEqual(@as(u32, 1500), session_end_budget_ms);
}

test "permission decisions rank deny over defer over ask over allow" {
    try std.testing.expectEqual(@as(?PermissionDecision, null), strongerPermission(null, null));
    try std.testing.expectEqual(@as(?PermissionDecision, .allow), strongerPermission(null, .allow));
    try std.testing.expectEqual(@as(?PermissionDecision, .ask), strongerPermission(.allow, .ask));
    try std.testing.expectEqual(@as(?PermissionDecision, .ask), strongerPermission(.ask, .allow));
    try std.testing.expectEqual(@as(?PermissionDecision, .@"defer"), strongerPermission(.ask, .@"defer"));
    try std.testing.expectEqual(@as(?PermissionDecision, .deny), strongerPermission(.@"defer", .deny));
    try std.testing.expectEqual(@as(?PermissionDecision, .deny), strongerPermission(.deny, .allow));
}

test "PreToolUse permissionDecision carries allow, ask and defer without blocking" {
    const names = [_][]const u8{ "allow", "ask", "defer" };
    const expected = [_]PermissionDecision{ .allow, .ask, .@"defer" };
    for (names, expected) |name, decision| {
        const stdout = try std.fmt.allocPrint(std.testing.allocator, "{{\"hookSpecificOutput\":{{\"permissionDecision\":\"{s}\"}}}}", .{name});
        defer std.testing.allocator.free(stdout);
        var verdict = try decide(std.testing.allocator, .PreToolUse, .{ .exit_code = 0, .stdout = stdout });
        defer verdict.deinit(std.testing.allocator);
        try std.testing.expect(!verdict.blocked);
        try std.testing.expectEqual(@as(?PermissionDecision, decision), verdict.permission);
    }
}

test "a top-level decision block with a reason blocks Stop, UserPromptSubmit and PostToolUse" {
    const stdout = "{\"decision\":\"block\",\"reason\":\"tests are failing\"}";
    const events = [_]Event{ .Stop, .UserPromptSubmit, .PostToolUse, .SubagentStop, .PreCompact };
    for (events) |event| {
        var verdict = try decide(std.testing.allocator, event, .{ .exit_code = 0, .stdout = stdout });
        defer verdict.deinit(std.testing.allocator);
        try std.testing.expect(verdict.blocked);
        try std.testing.expectEqualStrings("tests are failing", verdict.reason.?);
    }
    var notification = try decide(std.testing.allocator, .Notification, .{ .exit_code = 0, .stdout = stdout });
    defer notification.deinit(std.testing.allocator);
    try std.testing.expect(!notification.blocked);
}

test "exit code 2 gives a decision on PostToolUse, SubagentStop and PreCompact only for Claude Code shaped hooks" {
    const claude: Policy = .{ .dialect = .claude };
    const events = [_]Event{ .PostToolUse, .SubagentStop, .PreCompact };
    for (events) |event| {
        var kimi = try resolve(std.testing.allocator, .{}, event, .{ .exit_code = 2, .stderr = "no" });
        defer kimi.deinit(std.testing.allocator);
        try std.testing.expect(!kimi.blocked);
        var blocked = try resolve(std.testing.allocator, claude, event, .{ .exit_code = 2, .stderr = "no" });
        defer blocked.deinit(std.testing.allocator);
        try std.testing.expect(blocked.blocked);
        try std.testing.expectEqualStrings("no", blocked.reason.?);
    }
    var notification = try resolve(std.testing.allocator, claude, .Notification, .{ .exit_code = 2, .stderr = "no" });
    defer notification.deinit(std.testing.allocator);
    try std.testing.expect(!notification.blocked);
    var permission_request = try resolve(std.testing.allocator, claude, .PermissionRequest, .{ .exit_code = 2, .stderr = "no" });
    defer permission_request.deinit(std.testing.allocator);
    try std.testing.expect(!permission_request.blocked);
    try std.testing.expect(permission_request.permission_behavior == null);
}

test "onFailure block turns a failed hook into a block and continue leaves it open" {
    const blocking: Policy = .{ .on_failure = .block, .timeout_seconds = 4 };
    var failed = try resolve(std.testing.allocator, blocking, .PreToolUse, .{ .exit_code = 1, .stderr = "boom" });
    defer failed.deinit(std.testing.allocator);
    try std.testing.expect(failed.blocked);
    try std.testing.expectEqualStrings("PreToolUse hook exited with exit code 1", failed.reason.?);

    var timed_out = try resolve(std.testing.allocator, blocking, .UserPromptSubmit, .{ .timed_out = true });
    defer timed_out.deinit(std.testing.allocator);
    try std.testing.expect(timed_out.blocked);
    try std.testing.expectEqualStrings("UserPromptSubmit hook timed out after 4s", timed_out.reason.?);

    var missing = try resolve(std.testing.allocator, blocking, .PreToolUse, .{});
    defer missing.deinit(std.testing.allocator);
    try std.testing.expect(missing.blocked);

    var open = try resolve(std.testing.allocator, .{ .on_failure = .@"continue" }, .PreToolUse, .{ .exit_code = 1 });
    defer open.deinit(std.testing.allocator);
    try std.testing.expect(!open.blocked);

    var observed = try resolve(std.testing.allocator, blocking, .Notification, .{ .exit_code = 1 });
    defer observed.deinit(std.testing.allocator);
    try std.testing.expect(!observed.blocked);

    var succeeded = try resolve(std.testing.allocator, blocking, .PreToolUse, .{ .exit_code = 0 });
    defer succeeded.deinit(std.testing.allocator);
    try std.testing.expect(!succeeded.blocked);
}

test "a timed out Claude Code shaped PreToolUse hook blocks and a timed out Stop hook gives no decision" {
    const claude: Policy = .{ .dialect = .claude, .timeout_seconds = 600 };
    var tool_gate = try resolve(std.testing.allocator, claude, .PreToolUse, .{ .timed_out = true });
    defer tool_gate.deinit(std.testing.allocator);
    try std.testing.expect(tool_gate.blocked);
    try std.testing.expectEqualStrings("PreToolUse hook timed out after 600s", tool_gate.reason.?);

    const blocking: Policy = .{ .dialect = .claude, .on_failure = .block };
    var stop = try resolve(std.testing.allocator, blocking, .Stop, .{ .timed_out = true });
    defer stop.deinit(std.testing.allocator);
    try std.testing.expect(!stop.blocked);
    var subagent_stop = try resolve(std.testing.allocator, blocking, .SubagentStop, .{ .timed_out = true });
    defer subagent_stop.deinit(std.testing.allocator);
    try std.testing.expect(!subagent_stop.blocked);

    var prompt = try resolve(std.testing.allocator, claude, .UserPromptSubmit, .{ .timed_out = true });
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expect(!prompt.blocked);
}

test "universal output fields: continue false stops with stopReason, systemMessage and terminalSequence are carried" {
    const stdout = "{\"continue\":false,\"stopReason\":\"budget spent\",\"suppressOutput\":true,\"systemMessage\":\"heads up\",\"terminalSequence\":\"\\u0007\"}";
    var tool_gate = try decide(std.testing.allocator, .PreToolUse, .{ .exit_code = 0, .stdout = stdout });
    defer tool_gate.deinit(std.testing.allocator);
    try std.testing.expect(tool_gate.blocked);
    try std.testing.expect(tool_gate.stop_requested);
    try std.testing.expectEqualStrings("budget spent", tool_gate.reason.?);
    try std.testing.expectEqualStrings("budget spent", tool_gate.stop_reason.?);
    try std.testing.expectEqualStrings("heads up", tool_gate.system_message.?);
    try std.testing.expectEqualStrings("\x07", tool_gate.terminal_sequence.?);

    var stop = try decide(std.testing.allocator, .Stop, .{ .exit_code = 0, .stdout = "{\"continue\":false,\"decision\":\"block\",\"reason\":\"keep going\"}" });
    defer stop.deinit(std.testing.allocator);
    try std.testing.expect(!stop.blocked);
    try std.testing.expect(stop.stop_requested);

    var carried = try decide(std.testing.allocator, .Notification, .{ .exit_code = 0, .stdout = "{\"continue\":true,\"systemMessage\":\"seen\"}" });
    defer carried.deinit(std.testing.allocator);
    try std.testing.expect(!carried.stop_requested);
    try std.testing.expectEqualStrings("seen", carried.system_message.?);
}

test "PostToolUse output carries updatedToolOutput and additionalContext from either level" {
    var nested = try decide(std.testing.allocator, .PostToolUse, .{
        .exit_code = 0,
        .stdout = "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"updatedToolOutput\":\"redacted\",\"additionalContext\":\"lint passed\"}}",
    });
    defer nested.deinit(std.testing.allocator);
    try std.testing.expect(!nested.blocked);
    try std.testing.expectEqualStrings("redacted", nested.updated_tool_output.?);
    try std.testing.expectEqualStrings("lint passed", nested.additional_context.?);

    var top = try decide(std.testing.allocator, .PostToolUse, .{
        .exit_code = 0,
        .stdout = "{\"updatedToolOutput\":{\"ok\":true},\"additionalContext\":\"note\"}",
    });
    defer top.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{\"ok\":true}", top.updated_tool_output.?);
    try std.testing.expectEqualStrings("note", top.additional_context.?);

    var other = try decide(std.testing.allocator, .PreToolUse, .{ .exit_code = 0, .stdout = "{\"updatedToolOutput\":\"x\"}" });
    defer other.deinit(std.testing.allocator);
    try std.testing.expect(other.updated_tool_output == null);
}

test "PermissionRequest output reads decision.behavior with updatedInput, updatedPermissions and the deny message" {
    var allowed = try decide(std.testing.allocator, .PermissionRequest, .{
        .exit_code = 0,
        .stdout = "{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\",\"updatedInput\":{\"command\":\"ls\"},\"updatedPermissions\":[{\"type\":\"setMode\",\"mode\":\"acceptEdits\"}]}}}",
    });
    defer allowed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?PermissionBehavior, .allow), allowed.permission_behavior);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", allowed.updated_input.?);
    try std.testing.expectEqualStrings("[{\"type\":\"setMode\",\"mode\":\"acceptEdits\"}]", allowed.updated_permissions.?);
    try std.testing.expect(!allowed.blocked);

    var denied = try decide(std.testing.allocator, .PermissionRequest, .{
        .exit_code = 0,
        .stdout = "{\"hookSpecificOutput\":{\"decision\":{\"behavior\":\"deny\",\"message\":\"not in CI\",\"updatedInput\":{\"command\":\"ls\"}}}}",
    });
    defer denied.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?PermissionBehavior, .deny), denied.permission_behavior);
    try std.testing.expectEqualStrings("not in CI", denied.reason.?);
    try std.testing.expect(denied.updated_input == null);

    var undecided = try decide(std.testing.allocator, .PermissionRequest, .{ .exit_code = 0, .stdout = "{\"hookSpecificOutput\":{\"decision\":{\"behavior\":\"later\"}}}" });
    defer undecided.deinit(std.testing.allocator);
    try std.testing.expect(undecided.permission_behavior == null);
}

test "SessionStart output carries additionalContext, initialUserMessage, watchPaths, sessionTitle and reloadSkills" {
    var verdict = try decide(std.testing.allocator, .SessionStart, .{
        .exit_code = 0,
        .stdout = "{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"branch main\",\"initialUserMessage\":\"run the tests\",\"watchPaths\":[\"/w/.env\"],\"sessionTitle\":\"Release\",\"reloadSkills\":true}}",
    });
    defer verdict.deinit(std.testing.allocator);
    try std.testing.expect(!verdict.blocked);
    try std.testing.expectEqualStrings("branch main", verdict.additional_context.?);
    try std.testing.expectEqualStrings("run the tests", verdict.initial_user_message.?);
    try std.testing.expectEqualStrings("[\"/w/.env\"]", verdict.watch_paths.?);
    try std.testing.expectEqualStrings("Release", verdict.session_title.?);
    try std.testing.expect(verdict.reload_skills);
}

test "hook payload carries transcript_path, permission_mode and tool_use_id beside the tool call id" {
    const payload = try encodePayload(
        std.testing.allocator,
        .PostToolUse,
        .{ .session_id = "s1", .cwd = "/work", .transcript_path = "/home/u/.fx/sessions/s1.jsonl", .permission_mode = "default" },
        &.{.{ .key = "tool_call_id", .value = .{ .string = "call-7" } }},
    );
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"transcript_path\":\"/home/u/.fx/sessions/s1.jsonl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"permission_mode\":\"default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tool_use_id\":\"call-7\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, payload, "\"tool_use_id\""));

    const plain = try encodePayload(std.testing.allocator, .Stop, .{ .session_id = "s", .cwd = "/" }, &.{});
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "tool_use_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "transcript_path") == null);
}

test "SessionStart sources name clear, compact and fork for Claude Code shaped hooks and keep the Kimi names" {
    try std.testing.expectEqualStrings("startup", SessionSource.startup.kimiName().?);
    try std.testing.expectEqualStrings("startup", SessionSource.clear.kimiName().?);
    try std.testing.expectEqualStrings("resume", SessionSource.@"resume".kimiName().?);
    try std.testing.expect(SessionSource.compact.kimiName() == null);
    try std.testing.expect(SessionSource.fork.kimiName() == null);

    var parsed = try parseJsonForTest("{\"SessionStart\":[{\"matcher\":\"clear|compact|fork\",\"hooks\":[{\"command\":\"claude\"}]}]}");
    defer parsed.deinit();
    const claude = try parseDefinitions(std.testing.allocator, parsed.value);
    defer freeDefinitions(std.testing.allocator, claude);
    var flat = try parseJsonForTest("[{\"event\":\"SessionStart\",\"matcher\":\"startup\",\"command\":\"kimi\"}]");
    defer flat.deinit();
    const kimi = try parseDefinitions(std.testing.allocator, flat.value);
    defer freeDefinitions(std.testing.allocator, kimi);
    const definitions = [_]Definition{ claude[0], kimi[0] };

    const cleared = try selectMatchingValues(std.testing.allocator, &definitions, .SessionStart, .{ .kimi = "startup", .claude = "clear" });
    defer std.testing.allocator.free(cleared);
    try std.testing.expectEqual(@as(usize, 2), cleared.len);

    const compacted = try selectMatchingValues(std.testing.allocator, &definitions, .SessionStart, .{ .kimi = null, .claude = "compact" });
    defer std.testing.allocator.free(compacted);
    try std.testing.expectEqual(@as(usize, 1), compacted.len);
    try std.testing.expectEqualStrings("claude", compacted[0].command);

    const started = try selectMatchingValues(std.testing.allocator, &definitions, .SessionStart, .{ .kimi = "startup", .claude = "startup" });
    defer std.testing.allocator.free(started);
    try std.testing.expectEqual(@as(usize, 1), started.len);
    try std.testing.expectEqualStrings("kimi", started[0].command);
}
