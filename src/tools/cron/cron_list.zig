const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const model_tool_schema = @import("../../core/tooling/model_tool_schema.zig");
const calendar = @import("../../core/cron/calendar.zig");
const cron_expr = @import("../../core/cron/expr.zig");
const cron_runtime = @import("../../core/cron/runtime.zig");
const io_mod = @import("../../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const name = "CronList";

pub const description =
    \\List this session's cron tasks. Read-only. `stale: true` marks a recurring task whose next fire is its last. After a context compaction, call this instead of guessing ids.
;

pub const input_schema: model_tool_schema.ObjectSchema = .{
    .properties = &.{},
    .additional_properties = false,
};

const unavailable_message = "Cron tools are only supported by the main agent.";
const arguments_message = "CronList takes no arguments.";
const preview_bytes = 200;
const ms_per_day = calendar.ms_per_day;

const Input = struct {
    fn deinit(self: Input, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};

fn decodeFailure(alloc: Allocator, text: []const u8) Allocator.Error!tool_dispatch.DecodeResult {
    return .{ .failure = try alloc.dupe(u8, text) };
}

fn resultFailure(alloc: Allocator, text: []const u8) Allocator.Error!tool_dispatch.ToolResult {
    return .{ .failure = try alloc.dupe(u8, text) };
}

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const alloc = ctx.allocator;
    if (ctx.cron == null) return decodeFailure(alloc, unavailable_message);
    const source = if (args_json.len == 0) "{}" else args_json;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, source, .{}) catch {
        return decodeFailure(alloc, arguments_message);
    };
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() != 0) return decodeFailure(alloc, arguments_message);
    return .{ .input = try wrap(alloc, .{}) };
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    _ = erased;
    const alloc = ctx.allocator;
    const runtime = ctx.cron orelse return resultFailure(alloc, unavailable_message);
    const now = io_mod.milliTimestamp();
    const tasks = runtime.list();
    const header = try std.fmt.allocPrint(alloc, "cron_jobs: {d}", .{tasks.len});
    defer alloc.free(header);
    if (tasks.len == 0) {
        return .{ .success = try std.fmt.allocPrint(alloc, "{s}\nNo cron jobs scheduled.", .{header}) };
    }
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    for (tasks, 0..) |task, index| {
        if (index > 0) try body.appendSlice(alloc, "\n---\n");
        const record = try renderRecord(alloc, runtime, task, now);
        defer alloc.free(record);
        try body.appendSlice(alloc, record);
    }
    return .{ .success = try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ header, body.items }) };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn renderRecord(alloc: Allocator, runtime: *const cron_runtime.Runtime, task: cron_runtime.Task, now_ms: i64) Allocator.Error![]u8 {
    const id_text: []const u8 = &task.id;
    const preview = try previewPrompt(alloc, task.prompt);
    defer alloc.free(preview);
    const quoted = std.json.Stringify.valueAlloc(alloc, preview, .{}) catch return error.OutOfMemory;
    defer alloc.free(quoted);
    var diag: cron_expr.Diagnostic = .{};
    const schedule = cron_expr.parse(task.cron, &diag) catch null;
    const human = if (schedule) |expr| try cron_expr.humanSchedule(alloc, expr, task.cron) else try alloc.dupe(u8, task.cron);
    defer alloc.free(human);
    const next_text: []u8 = if (runtime.nextFireFor(task, now_ms)) |at|
        try calendar.formatLocalIsoWithOffset(alloc, at)
    else
        try alloc.dupe(u8, "null");
    defer alloc.free(next_text);
    const recurring_text: []const u8 = if (task.recurring) "true" else "false";
    const stale_text: []const u8 = if (runtime.isStale(task, now_ms)) "true" else "false";
    const age_days = @as(f64, @floatFromInt(now_ms - task.created_at_ms)) / @as(f64, @floatFromInt(ms_per_day));
    return std.fmt.allocPrint(
        alloc,
        "id: {s}\ncron: {s}\nhumanSchedule: {s}\nprompt: {s}\nnextFireAt: {s}\nrecurring: {s}\nageDays: {d:.2}\nstale: {s}",
        .{ id_text, task.cron, human, quoted, next_text, recurring_text, age_days, stale_text },
    );
}

fn previewPrompt(alloc: Allocator, prompt: []const u8) Allocator.Error![]u8 {
    if (prompt.len <= preview_bytes) return alloc.dupe(u8, prompt);
    var end: usize = preview_bytes;
    while (end > 0 and (prompt[end] & 0b1100_0000) == 0b1000_0000) end -= 1;
    return std.fmt.allocPrint(alloc, "{s}\u{2026}(truncated)", .{prompt[0..end]});
}

fn wrap(alloc: Allocator, input: Input) Allocator.Error!tool_dispatch.ToolInput {
    const slot = try alloc.create(Input);
    slot.* = input;
    return .{ .ptr = slot, .deinit_fn = inputDeinit };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

test "CronList reports an empty store" {
    const alloc = std.testing.allocator;
    var runtime = cron_runtime.Runtime.init(alloc, .{});
    defer runtime.deinit();
    const ctx: tool_dispatch.DispatchContext = .{ .allocator = alloc, .cron = &runtime };
    const decoded = try decode(ctx, "");
    const ready = switch (decoded) {
        .input => |value| value,
        .failure => |text| {
            alloc.free(text);
            return error.TestUnexpectedResult;
        },
    };
    defer ready.deinit(alloc);
    const result = try call(ctx, ready);
    defer result.deinit(alloc);
    const text = switch (result) {
        .success => |body| body,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("cron_jobs: 0\nNo cron jobs scheduled.", text);
}

test "CronList rejects arguments it does not take" {
    const alloc = std.testing.allocator;
    var runtime = cron_runtime.Runtime.init(alloc, .{});
    defer runtime.deinit();
    const decoded = try decode(.{ .allocator = alloc, .cron = &runtime }, "{\"id\":\"x\"}");
    switch (decoded) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |text| {
            defer alloc.free(text);
            try std.testing.expectEqualStrings(arguments_message, text);
        },
    }
}

test "CronList shows each job with its schedule, prompt preview and stale flag" {
    const alloc = std.testing.allocator;
    var runtime = cron_runtime.Runtime.init(alloc, .{ .no_jitter = true });
    defer runtime.deinit();
    const created = io_mod.milliTimestamp();
    const id = try runtime.newId(created);
    _ = try runtime.add(id, "* * * * *", "check the build", created, true);
    const ctx: tool_dispatch.DispatchContext = .{ .allocator = alloc, .cron = &runtime };
    const decoded = try decode(ctx, "{}");
    const ready = switch (decoded) {
        .input => |value| value,
        .failure => |text| {
            alloc.free(text);
            return error.TestUnexpectedResult;
        },
    };
    defer ready.deinit(alloc);
    const result = try call(ctx, ready);
    defer result.deinit(alloc);
    const text = switch (result) {
        .success => |body| body,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.startsWith(u8, text, "cron_jobs: 1\nid: "));
    try std.testing.expect(std.mem.indexOf(u8, text, "humanSchedule: every minute\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "prompt: \"check the build\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "recurring: true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "stale: false") != null);
}

test "CronList truncates long prompts on a character boundary" {
    const alloc = std.testing.allocator;
    const long = try alloc.alloc(u8, 300);
    defer alloc.free(long);
    @memset(long, 'a');
    const preview = try previewPrompt(alloc, long);
    defer alloc.free(preview);
    try std.testing.expect(std.mem.endsWith(u8, preview, "(truncated)"));
    try std.testing.expectEqual(@as(usize, 200 + "\u{2026}(truncated)".len), preview.len);
}
