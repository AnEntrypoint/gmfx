const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const runtime = @import("../../core/superagent/runtime.zig");
const command = @import("../../core/superagent/command.zig");
const managed_contract = @import("../../core/execution/managed_execution_contract.zig");

const Allocator = std.mem.Allocator;

pub const description = "A superagent controls persistent full root fx agents. Use action list_projects, start, stop, status, instruct, or journal. Managed peers receive prompts as ordinary user prompts on their own in-process root workers. instruct takes a prompt and an optional queue of later prompts; fx sends each queued prompt itself when the turn before it ends, and one event arrives when the root stops, goes idle or needs its owner. status shows alive and busy state only. journal opens a root's history in byte slices (offset, limit) on request.";

const default_journal_limit = 4000;

const Arguments = struct {
    action: []const u8,
    agent: []const u8 = "",
    prompt: []const u8 = "",
    cwd: []const u8 = "",
    session: []const u8 = "",
    queue: []const []const u8 = &.{},
    offset: usize = 0,
    limit: usize = default_journal_limit,
};

const Input = struct {
    arguments: Arguments,
    owner: std.json.Parsed(Arguments),
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const source = if (args_json.len == 0) "{}" else args_json;
    var parsed = std.json.parseFromSlice(Arguments, ctx.allocator, source, .{ .ignore_unknown_fields = true }) catch
        return .{ .failure = try ctx.allocator.dupe(u8, "superagent arguments must be a JSON object with an action") };
    errdefer parsed.deinit();
    return .{ .input = try wrap(ctx.allocator, .{ .arguments = parsed.value, .owner = parsed }) };
}

fn wrap(alloc: Allocator, input: Input) Allocator.Error!tool_dispatch.ToolInput {
    const slot = try alloc.create(Input);
    slot.* = input;
    return .{ .ptr = slot, .deinit_fn = inputDeinit };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.owner.deinit();
    alloc.destroy(input);
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const arguments = erased.as(Input).arguments;
    if (std.mem.eql(u8, arguments.action, "list_projects")) {
        const projects = runtime.listProjects(ctx.allocator) catch return failure(ctx, "could not list projects");
        defer runtime.freeProjects(ctx.allocator, projects);
        return .{ .success = try join(ctx.allocator, projects) };
    }
    if (std.mem.eql(u8, arguments.action, "status")) {
        const snapshots = runtime.statuses(ctx.allocator) catch return failure(ctx, "could not read peer status");
        defer runtime.freeStatuses(ctx.allocator, snapshots);
        return .{ .success = try renderStatus(ctx.allocator, snapshots) };
    }
    if (std.mem.eql(u8, arguments.action, "start")) {
        if (arguments.agent.len == 0) return failure(ctx, "start needs agent");
        runtime.start(ctx.allocator, .{
            .agent = arguments.agent,
            .prompt = "",
            .cwd = arguments.cwd,
            .session = if (arguments.session.len > 0) arguments.session else null,
        }) catch |err| return rootFailure(ctx, err, "could not start persistent peer root");
        const snapshot = runtime.status(ctx.allocator, arguments.agent) catch return .{ .success = try ctx.allocator.dupe(u8, "started") };
        defer runtime.freeSnapshot(ctx.allocator, snapshot);
        return .{ .success = try command.renderSnapshot(ctx.allocator, snapshot) };
    }
    if (std.mem.eql(u8, arguments.action, "stop")) {
        if (arguments.agent.len == 0) return failure(ctx, "stop needs agent");
        runtime.stop(ctx.allocator, arguments.agent) catch |err| return rootFailure(ctx, err, "could not stop persistent peer root");
        const snapshot = runtime.status(ctx.allocator, arguments.agent) catch return .{ .success = try ctx.allocator.dupe(u8, "stopped") };
        defer runtime.freeSnapshot(ctx.allocator, snapshot);
        return .{ .success = try command.renderSnapshot(ctx.allocator, snapshot) };
    }
    if (std.mem.eql(u8, arguments.action, "instruct")) {
        if (arguments.agent.len == 0 or arguments.prompt.len == 0) return failure(ctx, "instruct needs agent and prompt");
        const result = runtime.instruct(ctx.allocator, .{
            .agent = arguments.agent,
            .prompt = arguments.prompt,
            .cwd = arguments.cwd,
            .session = if (arguments.session.len > 0) arguments.session else null,
            .queue = arguments.queue,
        }) catch |err| return rootFailure(ctx, err, "could not instruct persistent peer root");
        defer runtime.freeResult(ctx.allocator, result);
        return .{ .success = try command.renderResult(ctx.allocator, result) };
    }
    if (std.mem.eql(u8, arguments.action, "journal")) {
        if (arguments.agent.len == 0) return failure(ctx, "journal needs agent");
        const slice = runtime.journal(ctx.allocator, arguments.agent, arguments.offset, arguments.limit) catch |err| return rootFailure(ctx, err, "could not read persistent peer root journal");
        defer runtime.freeJournal(ctx.allocator, slice);
        return .{ .success = try command.renderJournal(ctx.allocator, arguments.agent, slice) };
    }
    return failure(ctx, "unknown superagent action");
}

const unavailable_message = "superagent is not available in this session; run fx interactively to use persistent peer roots";
const memory_low_message = "superagent did not start a new root: the host has less free memory than task.root_min_free_mb allows; stop a root or free memory first";
const project_missing_message = "superagent project folder not found; list_projects shows the folders beside the workspace";

fn rootFailure(ctx: tool_dispatch.DispatchContext, err: anyerror, message: []const u8) tool_dispatch.ToolResult {
    if (err == error.SuperagentUnavailable) return failure(ctx, unavailable_message);
    if (err == error.ProjectNotFound) return failure(ctx, project_missing_message);
    if (err == error.HostMemoryLow) return failure(ctx, memory_low_message);
    return failure(ctx, message);
}

fn failure(ctx: tool_dispatch.DispatchContext, message: []const u8) tool_dispatch.ToolResult {
    return .{ .failure = ctx.allocator.dupe(u8, message) catch @constCast("superagent failure") };
}

fn join(alloc: Allocator, items: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (items, 0..) |item, index| {
        if (index > 0) try out.append(alloc, '\n');
        try out.appendSlice(alloc, item);
    }
    return out.toOwnedSlice(alloc);
}

fn renderStatus(alloc: Allocator, snapshots: []const runtime.Snapshot) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (snapshots, 0..) |snapshot, index| {
        if (index > 0) try out.append(alloc, '\n');
        const text = try command.renderSnapshot(alloc, snapshot);
        defer alloc.free(text);
        try out.appendSlice(alloc, text);
    }
    const host_line = try runtime.hostLine(alloc, managed_contract.taskSettings().root_min_free_mb);
    defer alloc.free(host_line);
    if (out.items.len > 0) try out.append(alloc, '\n');
    try out.appendSlice(alloc, host_line);
    return out.toOwnedSlice(alloc);
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "decode requires a well formed superagent action" {
    const decoded = try decode(.{ .allocator = std.testing.allocator }, "{\"action\":\"list_projects\"}");
    switch (decoded) {
        .input => |input| {
            defer input.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("list_projects", input.as(Input).arguments.action);
        },
        .failure => |message| {
            defer std.testing.allocator.free(message);
            return error.TestExpectedEqual;
        },
    }
}

test "an unbound session reports superagent as unavailable, not as a failed start" {
    runtime.unbind();
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"action\":\"start\",\"agent\":\"peer\"}");
    const input = switch (decoded) {
        .input => |value| value,
        .failure => |message| {
            alloc.free(message);
            return error.TestExpectedEqual;
        },
    };
    defer input.deinit(alloc);
    var result = try call(.{ .allocator = alloc }, input);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings(unavailable_message, result.failure);
}
