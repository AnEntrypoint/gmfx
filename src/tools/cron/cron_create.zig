const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const model_tool_schema = @import("../../core/tooling/model_tool_schema.zig");
const calendar = @import("../../core/cron/calendar.zig");
const cron_expr = @import("../../core/cron/expr.zig");
const cron_runtime = @import("../../core/cron/runtime.zig");
const ulid = @import("../../core/cron/ulid.zig");
const io_mod = @import("../../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const name = "CronCreate";

pub const description =
    \\Schedule a prompt to be enqueued later in this session, recurring or once.
    \\
    \\When the requested time is approximate, avoid minute 0 and 30 so fires from many users do not land at once: "around 9" → `57 8 * * *`, "hourly" → `7 * * * *`.
    \\
    \\Tasks fire only while this session is alive and idle, and never carry over to a new session. Missed fires collapse into one delivery with `coalescedCount` > 1: act on the latest state once. The final fire carries `stale="true"`, so call CronCreate again with the same `cron` and `prompt` if the schedule is still wanted.
    \\
    \\Users cannot manage cron tasks themselves: after creating one, tell the user its `id` and that they can ask you to cancel or change it.
;

pub const input_schema: model_tool_schema.ObjectSchema = .{
    .properties = &.{
        .{
            .name = "cron",
            .description = "5-field cron expression in local time: \"M H DoM Mon DoW\" (e.g. \"*/5 * * * *\" = every 5 minutes; \"30 14 28 2 *\" = Feb 28 at 2:30pm local; a pinned date like this repeats yearly unless you also pass recurring: false).",
            .json_type = .string,
        },
        .{
            .name = "prompt",
            .description = "The prompt to enqueue at each fire time. Limited to 8 KiB (UTF-8).",
            .json_type = .string,
            .bounds = &.{ .min_length = 1, .max_length = cron_runtime.max_prompt_bytes },
        },
        .{
            .name = "recurring",
            .description = "true (default) = fire on every cron match until deleted or auto-expired after 7 days. false = fire once at the next match, then auto-delete. Use false for \"remind me at X\" one-shot requests with pinned minute/hour/dom/month.",
            .json_type = .boolean,
        },
    },
    .required = &.{ "cron", "prompt" },
};

const unavailable_message = "Cron tools are only supported by the main agent.";
const disabled_message = "Cron scheduling is disabled (KIMI_DISABLE_CRON=1).";
const shape_message = "CronCreate arguments must be a JSON object with cron and a non-empty prompt, and an optional boolean recurring.";
const cap_message = "Cron job cap reached (max 50 per session).";
const id_message = "Cron job id could not be generated.";

const Arguments = struct {
    cron: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    recurring: ?bool = null,
};

const Input = struct {
    cron: []u8,
    prompt: []u8,
    recurring: bool,

    fn deinit(self: Input, alloc: Allocator) void {
        alloc.free(self.cron);
        alloc.free(self.prompt);
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
    const runtime = ctx.cron orelse return decodeFailure(alloc, unavailable_message);
    if (runtime.isDisabled()) return decodeFailure(alloc, disabled_message);
    const source = if (args_json.len == 0) "{}" else args_json;
    const parsed = std.json.parseFromSlice(Arguments, alloc, source, .{ .ignore_unknown_fields = true }) catch {
        return decodeFailure(alloc, shape_message);
    };
    defer parsed.deinit();
    const cron_text = parsed.value.cron orelse return decodeFailure(alloc, shape_message);
    const prompt_text = parsed.value.prompt orelse return decodeFailure(alloc, shape_message);
    if (prompt_text.len == 0) return decodeFailure(alloc, shape_message);
    const recurring = parsed.value.recurring orelse true;
    const now = io_mod.milliTimestamp();
    const normalized = try normalizeCron(alloc, cron_text);
    errdefer alloc.free(normalized);
    if (try refusal(alloc, runtime, normalized, prompt_text, recurring, now)) |message| {
        alloc.free(normalized);
        return .{ .failure = message };
    }
    const prompt = try alloc.dupe(u8, prompt_text);
    errdefer alloc.free(prompt);
    return .{ .input = try wrap(alloc, .{ .cron = normalized, .prompt = prompt, .recurring = recurring }) };
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const alloc = ctx.allocator;
    const input = erased.as(Input);
    const runtime = ctx.cron orelse return resultFailure(alloc, unavailable_message);
    const now = io_mod.milliTimestamp();
    if (runtime.list().len >= cron_runtime.max_jobs) return resultFailure(alloc, cap_message);
    var diag: cron_expr.Diagnostic = .{};
    const schedule = cron_expr.parse(input.cron, &diag) catch return resultFailure(alloc, diag.text());
    const id = runtime.newId(now) catch return resultFailure(alloc, id_message);
    const task = runtime.add(id, input.cron, input.prompt, now, input.recurring) catch |err| switch (err) {
        error.CapReached => return resultFailure(alloc, cap_message),
        error.OutOfMemory => return error.OutOfMemory,
    };
    const human = try cron_expr.humanSchedule(alloc, schedule, input.cron);
    defer alloc.free(human);
    const next_text: []u8 = if (cron_expr.nextRun(schedule, now)) |ideal|
        try calendar.formatLocalIsoWithOffset(alloc, runtime.jitteredNext(task, schedule, ideal))
    else
        try alloc.dupe(u8, "null");
    defer alloc.free(next_text);
    const id_text: []const u8 = &id;
    const recurring_text: []const u8 = if (input.recurring) "true" else "false";
    const output = try std.fmt.allocPrint(
        alloc,
        "id: {s}\ncron: {s}\nhumanSchedule: {s}\nrecurring: {s}\nnextFireAt: {s}",
        .{ id_text, input.cron, human, recurring_text, next_text },
    );
    return .{ .success = output };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn normalizeCron(alloc: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n\x0b\x0c");
    var first = true;
    while (tokens.next()) |token| {
        if (!first) try out.append(alloc, ' ');
        first = false;
        try out.appendSlice(alloc, token);
    }
    return out.toOwnedSlice(alloc);
}

fn refusal(
    alloc: Allocator,
    runtime: *const cron_runtime.Runtime,
    normalized: []const u8,
    prompt: []const u8,
    recurring: bool,
    now_ms: i64,
) Allocator.Error!?[]u8 {
    var diag: cron_expr.Diagnostic = .{};
    const schedule = cron_expr.parse(normalized, &diag) catch |err| switch (err) {
        error.CronExpressionInvalid => return try std.fmt.allocPrint(alloc, "Invalid cron expression: {s}", .{diag.text()}),
    };
    if (!cron_expr.hasFireWithinYears(schedule, 5, now_ms)) {
        return try std.fmt.allocPrint(alloc, "Cron expression \"{s}\" has no fire within 5 years; refusing to schedule.", .{normalized});
    }
    if (runtime.list().len >= cron_runtime.max_jobs) return try alloc.dupe(u8, cap_message);
    if (prompt.len > cron_runtime.max_prompt_bytes) {
        return try std.fmt.allocPrint(alloc, "Prompt exceeds {d} bytes (got {d}).", .{ cron_runtime.max_prompt_bytes, prompt.len });
    }
    if (!recurring) {
        if (cron_expr.nextRun(schedule, now_ms)) |first_fire| {
            if (first_fire - now_ms > cron_runtime.one_shot_horizon_ms) {
                const when = try calendar.formatLocalIsoWithOffset(alloc, first_fire);
                defer alloc.free(when);
                return try std.fmt.allocPrint(
                    alloc,
                    "One-shot cron \"{s}\" would not fire until {s} (more than a year out). If you meant today or a near date, the pinned day/month has already passed this year; pick a future date or use wildcards.",
                    .{ normalized, when },
                );
            }
        }
    }
    return null;
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

fn decodeInput(alloc: Allocator, ctx: tool_dispatch.DispatchContext, args_json: []const u8) !tool_dispatch.ToolInput {
    const decoded = try decode(ctx, args_json);
    switch (decoded) {
        .input => |input| return input,
        .failure => |text| {
            alloc.free(text);
            return error.TestUnexpectedResult;
        },
    }
}

test "CronCreate reports unavailable outside the main agent" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"cron\":\"* * * * *\",\"prompt\":\"x\"}");
    switch (decoded) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |text| {
            defer alloc.free(text);
            try std.testing.expectEqualStrings(unavailable_message, text);
        },
    }
}

test "CronCreate refuses an invalid expression before any approval prompt" {
    const alloc = std.testing.allocator;
    var runtime = cron_runtime.Runtime.init(alloc, .{});
    defer runtime.deinit();
    const decoded = try decode(.{ .allocator = alloc, .cron = &runtime }, "{\"cron\":\"61 * * * *\",\"prompt\":\"x\"}");
    switch (decoded) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |text| {
            defer alloc.free(text);
            try std.testing.expectEqualStrings("Invalid cron expression: cron minute value 61 out of range 0..59", text);
        },
    }
    try std.testing.expectEqual(@as(usize, 0), runtime.list().len);
}

test "CronCreate refuses an expression that never fires" {
    const alloc = std.testing.allocator;
    var runtime = cron_runtime.Runtime.init(alloc, .{});
    defer runtime.deinit();
    const decoded = try decode(.{ .allocator = alloc, .cron = &runtime }, "{\"cron\":\"0 0 31 2 *\",\"prompt\":\"x\"}");
    switch (decoded) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |text| {
            defer alloc.free(text);
            try std.testing.expectEqualStrings("Cron expression \"0 0 31 2 *\" has no fire within 5 years; refusing to schedule.", text);
        },
    }
}

test "CronCreate refuses a job once the session cap is reached" {
    const alloc = std.testing.allocator;
    var runtime = cron_runtime.Runtime.init(alloc, .{});
    defer runtime.deinit();
    const now = io_mod.milliTimestamp();
    var index: usize = 0;
    while (index < cron_runtime.max_jobs) : (index += 1) {
        const id = try runtime.newId(now);
        _ = try runtime.add(id, "0 0 * * *", "p", now, true);
    }
    const decoded = try decode(.{ .allocator = alloc, .cron = &runtime }, "{\"cron\":\"0 0 * * *\",\"prompt\":\"x\"}");
    switch (decoded) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |text| {
            defer alloc.free(text);
            try std.testing.expectEqualStrings(cap_message, text);
        },
    }
}

test "CronCreate reports disabled cron scheduling" {
    const alloc = std.testing.allocator;
    var runtime = cron_runtime.Runtime.init(alloc, .{ .disabled = true });
    defer runtime.deinit();
    const decoded = try decode(.{ .allocator = alloc, .cron = &runtime }, "{\"cron\":\"0 0 * * *\",\"prompt\":\"x\"}");
    switch (decoded) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |text| {
            defer alloc.free(text);
            try std.testing.expectEqualStrings(disabled_message, text);
        },
    }
}

test "CronCreate schedules a recurring job from normalized input and reports its id" {
    const alloc = std.testing.allocator;
    var runtime = cron_runtime.Runtime.init(alloc, .{ .no_jitter = true });
    defer runtime.deinit();
    const ctx: tool_dispatch.DispatchContext = .{ .allocator = alloc, .cron = &runtime };
    const input = try decodeInput(alloc, ctx, "{\"cron\":\"  */5  * * * * \",\"prompt\":\"check the build\"}");
    defer input.deinit(alloc);
    const result = try call(ctx, input);
    defer result.deinit(alloc);
    const text = switch (result) {
        .success => |body| body,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.indexOf(u8, text, "cron: */5 * * * *\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "humanSchedule: every 5 minutes\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "recurring: true\n") != null);
    try std.testing.expectEqual(@as(usize, 1), runtime.list().len);
    try std.testing.expect(ulid.isId(&runtime.list()[0].id));
    try std.testing.expectEqualStrings("check the build", runtime.list()[0].prompt);
}
