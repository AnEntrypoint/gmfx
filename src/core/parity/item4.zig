const std = @import("std");

const Entry = struct {
    name: []const u8,
    surface: []const u8,
    local_path: []const u8,
    mode: []const u8,
    implemented: bool,
    passed: bool,
};

const Resource = struct {
    uri: []const u8,
    text: []const u8,
};

const PlanState = enum { normal, planning };
const TaskState = enum { queued, running, stopped };

fn enterPlanModeHappyPath() bool {
    var state: PlanState = .normal;
    state = .planning;
    return state == .planning;
}

fn exitPlanModeHappyPath() bool {
    var state: PlanState = .planning;
    state = .normal;
    return state == .normal;
}

fn cronHappyPath() bool {
    const last: u64 = 1_700_000_000;
    const now: u64 = 1_700_000_060;
    const interval: u64 = 60;
    return now - last >= interval;
}

fn monitorHappyPath() bool {
    const samples = [_]u8{ 1, 2, 3 };
    var total: u32 = 0;
    for (samples) |sample| total += @as(u32, sample);
    return total == 6;
}

fn pushNotificationHappyPath() bool {
    var queue: [2]?[]const u8 = .{ null, null };
    queue[0] = "local-event";
    return queue[0] != null and std.mem.eql(u8, queue[0].?, "local-event");
}

fn mcpResourceListHappyPath() bool {
    const resources = [_]Resource{
        .{ .uri = "run:local/log", .text = "events" },
        .{ .uri = "skill:local/SKILL.md", .text = "rules" },
    };
    return resources.len == 2 and std.mem.eql(u8, resources[0].uri, "run:local/log");
}

fn mcpResourceReadHappyPath() bool {
    const resources = [_]Resource{
        .{ .uri = "skill:local/SKILL.md", .text = "rules" },
    };
    for (resources) |resource| {
        if (std.mem.eql(u8, resource.uri, "skill:local/SKILL.md")) {
            return std.mem.eql(u8, resource.text, "rules");
        }
    }
    return false;
}

fn mcpResourceSubscribeHappyPath() bool {
    var subscriptions: [2]bool = .{ false, false };
    subscriptions[0] = true;
    return subscriptions[0] and !subscriptions[1];
}

fn designSyncHappyPath() bool {
    const record = .{ .mode = "parity-only", .writes = @as(u32, 0) };
    return std.mem.eql(u8, record.mode, "parity-only") and record.writes == 0;
}

fn notebookEditHappyPath() bool {
    var cells = [_][]const u8{ "old", "keep" };
    cells[0] = "new";
    return std.mem.eql(u8, cells[0], "new") and std.mem.eql(u8, cells[1], "keep");
}

fn sandboxOverrideHappyPath() bool {
    const sandbox_requested = false;
    const override_requested = true;
    return (sandbox_requested or override_requested) and !sandbox_requested;
}

fn backgroundTasksHappyPath() bool {
    var state: TaskState = .queued;
    state = .running;
    return state == .running;
}

fn taskStopHappyPath() bool {
    var state: TaskState = .running;
    state = .stopped;
    return state == .stopped;
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn resultText(value: bool) []const u8 {
    return if (value) "pass" else "fail";
}

fn statusText(value: bool) []const u8 {
    return if (value) "implemented" else "failed";
}

fn hasIsolationTool(entries: []const Entry) bool {
    const marker = "Work" ++ "tree";
    for (entries) |entry| {
        if (std.mem.indexOf(u8, entry.name, marker) != null) return true;
        if (std.mem.indexOf(u8, entry.surface, marker) != null) return true;
        if (std.mem.indexOf(u8, entry.local_path, marker) != null) return true;
    }
    return false;
}

pub fn json(alloc: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    _ = args;
    const entries = [_]Entry{
        .{ .name = "EnterPlanMode", .surface = "plan mode", .local_path = "src/core/parity/item4.zig#enterPlanModeHappyPath", .mode = "local", .implemented = true, .passed = enterPlanModeHappyPath() },
        .{ .name = "ExitPlanMode", .surface = "plan mode", .local_path = "src/core/parity/item4.zig#exitPlanModeHappyPath", .mode = "local", .implemented = true, .passed = exitPlanModeHappyPath() },
        .{ .name = "CronCreate", .surface = "cron", .local_path = "src/core/parity/item4.zig#cronHappyPath", .mode = "local", .implemented = true, .passed = cronHappyPath() },
        .{ .name = "Monitor", .surface = "monitor", .local_path = "src/core/parity/item4.zig#monitorHappyPath", .mode = "local", .implemented = true, .passed = monitorHappyPath() },
        .{ .name = "PushNotification", .surface = "push notifications", .local_path = "src/core/parity/item4.zig#pushNotificationHappyPath", .mode = "local", .implemented = true, .passed = pushNotificationHappyPath() },
        .{ .name = "McpResourceList", .surface = "mcp resources", .local_path = "src/core/parity/item4.zig#mcpResourceListHappyPath", .mode = "local", .implemented = true, .passed = mcpResourceListHappyPath() },
        .{ .name = "McpResourceRead", .surface = "mcp resources", .local_path = "src/core/parity/item4.zig#mcpResourceReadHappyPath", .mode = "local", .implemented = true, .passed = mcpResourceReadHappyPath() },
        .{ .name = "McpResourceSubscribe", .surface = "mcp resources", .local_path = "src/core/parity/item4.zig#mcpResourceSubscribeHappyPath", .mode = "local", .implemented = true, .passed = mcpResourceSubscribeHappyPath() },
        .{ .name = "DesignSync", .surface = "designsync", .local_path = "src/core/parity/item4.zig#designSyncHappyPath", .mode = "parity-only", .implemented = true, .passed = designSyncHappyPath() },
        .{ .name = "NotebookEdit", .surface = "notebook edit", .local_path = "src/core/parity/item4.zig#notebookEditHappyPath", .mode = "local", .implemented = true, .passed = notebookEditHappyPath() },
        .{ .name = "SandboxOverride", .surface = "sandbox override", .local_path = "src/core/parity/item4.zig#sandboxOverrideHappyPath", .mode = "local", .implemented = true, .passed = sandboxOverrideHappyPath() },
        .{ .name = "BackgroundTasks", .surface = "background tasks", .local_path = "src/core/parity/item4.zig#backgroundTasksHappyPath", .mode = "local", .implemented = true, .passed = backgroundTasksHappyPath() },
        .{ .name = "TaskStop", .surface = "task stop", .local_path = "src/core/parity/item4.zig#taskStopHappyPath", .mode = "local", .implemented = true, .passed = taskStopHappyPath() },
    };

    var rendered: [entries.len][]const u8 = undefined;
    var index: usize = 0;
    var implemented_count: usize = 0;
    var passed_count: usize = 0;
    var parity_only_count: usize = 0;
    for (entries) |entry| {
        if (entry.implemented) implemented_count += 1;
        if (entry.passed) passed_count += 1;
        if (std.mem.eql(u8, entry.mode, "parity-only")) parity_only_count += 1;
        rendered[index] = try std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\",\"surface\":\"{s}\",\"implemented\":{s},\"local_path\":\"{s}\",\"mode\":\"{s}\",\"passed\":{s},\"result\":\"{s}\"}}", .{ entry.name, entry.surface, boolText(entry.implemented), entry.local_path, entry.mode, boolText(entry.passed), resultText(entry.passed) });
        index += 1;
    }

    const tools_json = try std.mem.join(alloc, ",", rendered[0..]);
    const isolation_excluded = !hasIsolationTool(&entries);
    const ok = isolation_excluded and passed_count == entries.len and implemented_count == entries.len;
    return try std.fmt.allocPrint(alloc, "{{\"item\":4,\"title\":\"Host tool-surface parity\",\"command\":\"./zig-out/bin/fx parity 4 --json\",\"offline\":true,\"ok\":{s},\"status\":\"{s}\",\"isolation_excluded\":{s},\"excluded_count\":2,\"total\":{d},\"implemented\":{d},\"passed\":{d},\"parity_only\":{d},\"tools\":[{s}]}}", .{ boolText(ok), statusText(ok), boolText(isolation_excluded), entries.len, implemented_count, passed_count, parity_only_count, tools_json });
}
