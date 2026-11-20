const std = @import("std");

const Allocator = std.mem.Allocator;

pub const usage_notice = "High usage: Swarm is built for large parallel jobs and can use many times the tokens of a normal task. Start small, and run /swarm off when you're done.";
pub const on_notice = "Swarm mode: ON";
pub const off_notice = "Swarm mode: OFF";
pub const already_on_notice = "Swarm mode is already on.";
pub const already_off_notice = "Swarm mode is already off.";
pub const task_unavailable_notice = "a swarm task cannot be started in this runtime";

pub const enter_reminder =
    \\## Swarm Mode
    \\
    \\You are now in "agent swarm" mode. The user may send tasks that require a large number of parallel subagents.
    \\
    \\## Workflow
    \\
    \\You do not need to use TodoList to record this workflow.
    \\
    \\1. First, you may need to do a small amount of exploratory work before deciding how to divide the task across subagents. You may not need subagents during this exploratory phase.
    \\
    \\2. After exploring, if you are convinced no subagent is needed to complete the task, tell the user why and wait for further instructions; otherwise, continue with the appropriate delegation.
    \\
    \\3. Once you have enough context, do not handle the main work yourself. Use AgentSwarm with a `prompt_template` containing the `{{item}}` placeholder and an `items` array for the requested or appropriate number of subagents, partitioning the problem so each item gives one subagent a distinct part of the work. Pass `subagent_type` when the whole swarm should use a non-default subagent profile.
    \\
    \\## Coordination
    \\
    \\- Give each subagent a distinct scope of work.
    \\- Avoid duplicating work across subagents.
    \\- Avoid assigning conflicting changes or responsibilities to different subagents.
    \\- Remember that subagents have your full capabilities. Do not overload their prompts with excessive detail; only describe the necessary background and each subagent's specific task.
    \\- Unless the user explicitly specifies a lower limit, do not try to conserve the number of agents. AgentSwarm supports up to 128 subagents and queues launches automatically, so decompose work as finely as possible while keeping subagent responsibilities non-conflicting; combine tasks only when they are genuinely inseparable. If the subagents only need to read, inspect, or report back without making changes, their scopes may overlap slightly.
;

pub const exit_reminder =
    \\## Swarm Mode Ended
    \\
    \\Swarm Mode has ended. You are no longer required to follow the Swarm Mode workflow.
    \\
    \\The user's next request is likely to be a regular request. Handle the request yourself, and launch subagents only if it explicitly asks for them.
;

pub const Command = union(enum) { toggle, enable, disable, task: []const u8 };

pub fn parse(rest: []const u8) Command {
    const argument = std.mem.trim(u8, rest, " \t\r\n");
    if (argument.len == 0) return .toggle;
    if (std.ascii.eqlIgnoreCase(argument, "on")) return .enable;
    if (std.ascii.eqlIgnoreCase(argument, "off")) return .disable;
    return .{ .task = argument };
}

const Owed = enum { nothing, enter, exit };

var active: bool = false;
var owed: Owed = .nothing;
var model_was_told_swarm_is_on: bool = false;

pub fn isActive() bool {
    return active;
}

pub fn enter() void {
    if (active) return;
    active = true;
    owed = if (model_was_told_swarm_is_on) .nothing else .enter;
}

pub fn exit() void {
    if (!active) return;
    active = false;
    owed = if (model_was_told_swarm_is_on) .exit else .nothing;
}

pub fn forget() void {
    active = false;
    owed = .nothing;
    model_was_told_swarm_is_on = false;
}

pub fn owedReminder() ?[]const u8 {
    return switch (owed) {
        .nothing => null,
        .enter => enter_reminder,
        .exit => exit_reminder,
    };
}

pub fn reminderDelivered() void {
    switch (owed) {
        .nothing => {},
        .enter => model_was_told_swarm_is_on = true,
        .exit => model_was_told_swarm_is_on = false,
    }
    owed = .nothing;
}

pub fn promptWithReminder(alloc: Allocator, prompt: []const u8, reminder: []const u8) Allocator.Error![]u8 {
    const separator: []const u8 = if (prompt.len == 0) "" else "\n\n";
    return std.fmt.allocPrint(alloc, "{s}{s}<system-reminder>\n{s}\n</system-reminder>", .{ prompt, separator, reminder });
}

test "/swarm with no argument toggles, on and off set the mode, and any other text is a task" {
    try std.testing.expect(parse("  ") == .toggle);
    try std.testing.expect(parse("ON") == .enable);
    try std.testing.expect(parse(" off ") == .disable);
    switch (parse("  audit every package  ")) {
        .task => |task| try std.testing.expectEqualStrings("audit every package", task),
        else => return error.TestExpectedEqual,
    }
}

test "the model is told once when swarm mode starts and once when it ends" {
    forget();
    defer forget();
    try std.testing.expect(owedReminder() == null);

    enter();
    try std.testing.expect(isActive());
    try std.testing.expectEqualStrings(enter_reminder, owedReminder().?);
    reminderDelivered();
    try std.testing.expect(owedReminder() == null);

    enter();
    try std.testing.expect(owedReminder() == null);

    exit();
    try std.testing.expect(!isActive());
    try std.testing.expectEqualStrings(exit_reminder, owedReminder().?);
    reminderDelivered();
    try std.testing.expect(owedReminder() == null);
}

test "swarm mode turned on and off before any prompt owes the model nothing" {
    forget();
    defer forget();
    enter();
    exit();
    try std.testing.expect(owedReminder() == null);
}

test "a reminder follows the prompt so the prompt keeps its own byte offsets" {
    const alloc = std.testing.allocator;
    const with_task = try promptWithReminder(alloc, "audit every package", "be a swarm");
    defer alloc.free(with_task);
    try std.testing.expectEqualStrings("audit every package\n\n<system-reminder>\nbe a swarm\n</system-reminder>", with_task);

    const alone = try promptWithReminder(alloc, "", "be a swarm");
    defer alloc.free(alone);
    try std.testing.expectEqualStrings("<system-reminder>\nbe a swarm\n</system-reminder>", alone);
}
