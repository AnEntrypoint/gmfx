const std = @import("std");
const plan_mode = @import("../../core/permissions/plan_mode.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const description =
    "Ask the user to approve the plan you wrote in plan mode, offering up to three options. Pass the full plan in plan, or write it to .fx/plans/plan.md first and leave plan out. The user can approve, reject, or ask for revisions. " ++ plan_mode.guidance;

const max_options = 3;
const max_label_bytes = 80;
const max_plan_bytes = 16384;
const reserved_labels = [_][]const u8{ "Approve", "Reject", "Reject and Exit", "Revise" };
const exited_message = "Exited plan mode.";
const selected_approach_format = "Selected approach: {s}\nExecute ONLY the selected approach. Do not execute any unselected alternatives.\n\n";
const plan_mode_deactivated_message = "Plan mode deactivated. All tools are now available.";
const plan_saved_format = "Plan saved to: {s}\n\n";
const approved_plan_heading = "## Approved Plan:";
const shape_refusal = "ExitPlanMode arguments must be a JSON object with an optional plan string and an optional options array.";
const plan_refusal = "ExitPlanMode takes a plan of at most 16384 bytes.";
const options_refusal = "ExitPlanMode options must be 1 to 3 objects with a non-empty label of at most 80 bytes, unique and not Approve, Reject, Reject and Exit, or Revise.";

const Option = struct {
    label: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

const Arguments = struct {
    plan: ?[]const u8 = null,
    options: ?[]const Option = null,
};

pub const Input = struct {
    option_count: usize,
    plan: []const u8,
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arguments = std.json.parseFromSliceLeaky(Arguments, arena_state.allocator(), args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, shape_refusal) };
    };
    const raw_plan = arguments.plan orelse "";
    const plan = std.mem.trim(u8, raw_plan, " \t\r\n");
    if (raw_plan.len > max_plan_bytes) return .{ .failure = try ctx.allocator.dupe(u8, plan_refusal) };
    const count = if (arguments.options) |options| blk: {
        if (!validOptions(options)) return .{ .failure = try ctx.allocator.dupe(u8, options_refusal) };
        break :blk options.len;
    } else 0;
    const owned_plan = try ctx.allocator.dupe(u8, plan);
    errdefer ctx.allocator.free(owned_plan);
    return .{ .input = try wrap(ctx.allocator, .{ .option_count = count, .plan = owned_plan }) };
}

fn validOptions(options: []const Option) bool {
    if (options.len < 1 or options.len > max_options) return false;
    for (options, 0..) |option, index| {
        const raw = option.label orelse return false;
        const label = std.mem.trim(u8, raw, " \t\r\n");
        if (label.len == 0 or raw.len > max_label_bytes) return false;
        for (reserved_labels) |reserved| {
            if (std.ascii.eqlIgnoreCase(label, reserved)) return false;
        }
        for (options[0..index]) |earlier| {
            const earlier_label = std.mem.trim(u8, earlier.label orelse continue, " \t\r\n");
            if (std.ascii.eqlIgnoreCase(label, earlier_label)) return false;
        }
    }
    return true;
}

fn wrap(alloc: Allocator, input: Input) Allocator.Error!tool_dispatch.ToolInput {
    const slot = try alloc.create(Input);
    slot.* = input;
    return .{ .ptr = slot, .deinit_fn = inputDeinit };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    alloc.free(input.plan);
    alloc.destroy(input);
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const state = ctx.plan_mode orelse return .{ .failure = try ctx.allocator.dupe(u8, plan_mode.not_active_message) };
    if (!state.isActive()) return .{ .failure = try ctx.allocator.dupe(u8, plan_mode.not_active_message) };
    const review = state.takeReview() orelse plan_mode.Review.approved(null, null);
    switch (review.verdict) {
        .dismissed => return .{ .success = try ctx.allocator.dupe(u8, plan_mode.dismissed_message) },
        .revise => return .{ .success = try plan_mode.reviseResult(ctx.allocator, review.feedback()) },
        .approved => {},
    }
    const stored_plan = if (input.plan.len == 0) plan_mode.readPlanFile(ctx.allocator, ctx.workspace_root) else null;
    defer if (stored_plan) |text| ctx.allocator.free(text);
    const plan = if (input.plan.len == 0)
        std.mem.trim(u8, stored_plan orelse return .{ .failure = try plan_mode.missingPlanMessage(ctx.allocator, ctx.workspace_root) }, " \t\r\n")
    else
        input.plan;
    if (!state.leave()) return .{ .failure = try ctx.allocator.dupe(u8, plan_mode.not_active_message) };
    return .{ .success = try approvedResult(ctx.allocator, review, plan) };
}

fn approvedResult(alloc: Allocator, review: plan_mode.Review, plan: []const u8) Allocator.Error![]u8 {
    const selected_approach = if (review.selectedOption()) |label|
        try alloc.print(selected_approach_format, .{label})
    else
        try alloc.dupe(u8, "");
    defer alloc.free(selected_approach);
    const saved_to = if (review.savedLocation()) |location|
        try alloc.print(plan_saved_format, .{location})
    else
        try alloc.dupe(u8, "");
    defer alloc.free(saved_to);
    return alloc.print("{s} {s}{s}\n{s}{s}\n{s}", .{
        exited_message,
        selected_approach,
        plan_mode_deactivated_message,
        saved_to,
        approved_plan_heading,
        plan,
    });
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "ExitPlanMode accepts a plan with one to three distinct options" {
    const accepted = [_][]const u8{
        "{\"plan\":\"Edit the parser and run its tests.\"}",
        "{\"plan\":\"Edit the parser.\",\"options\":[{\"label\":\"Ship it\"}]}",
        "{\"plan\":\"Edit the parser.\",\"options\":[{\"label\":\"Ship it\",\"description\":\"merge now\"},{\"label\":\"Keep planning\"},{\"label\":\"Split work\"}]}",
    };
    for (accepted) |args| {
        const decoded = try decode(.{ .allocator = std.testing.allocator, .tool_call_name = "ExitPlanMode" }, args);
        switch (decoded) {
            .input => |input| input.deinit(std.testing.allocator),
            .failure => |message| {
                defer std.testing.allocator.free(message);
                return error.TestExpectedEqual;
            },
        }
    }
}

test "ExitPlanMode leaves the plan to the plan file when plan is missing or blank and refuses an oversized plan" {
    const from_plan_file = [_][]const u8{
        "{}",
        "{\"options\":[{\"label\":\"Ship it\"}]}",
        "{\"plan\":\"   \"}",
        "{\"plan\":\"\"}",
    };
    for (from_plan_file) |args| {
        const decoded = try decode(.{ .allocator = std.testing.allocator, .tool_call_name = "ExitPlanMode" }, args);
        switch (decoded) {
            .input => |input| {
                defer input.deinit(std.testing.allocator);
                try std.testing.expectEqualStrings("", input.as(Input).plan);
            },
            .failure => |message| {
                defer std.testing.allocator.free(message);
                return error.TestExpectedEqual;
            },
        }
    }
    const oversized = try std.testing.allocator.alloc(u8, max_plan_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'p');
    const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"plan\":\"{s}\"}}", .{oversized});
    defer std.testing.allocator.free(args);
    const decoded = try decode(.{ .allocator = std.testing.allocator, .tool_call_name = "ExitPlanMode" }, args);
    switch (decoded) {
        .input => |input| {
            input.deinit(std.testing.allocator);
            return error.TestExpectedEqual;
        },
        .failure => |message| std.testing.allocator.free(message),
    }
}

test "ExitPlanMode refuses bad option counts, labels, and reserved words" {
    const refused = [_][]const u8{
        "{\"plan\":\"p\",\"options\":[]}",
        "{\"plan\":\"p\",\"options\":[{\"label\":\"a\"},{\"label\":\"b\"},{\"label\":\"c\"},{\"label\":\"d\"}]}",
        "{\"plan\":\"p\",\"options\":[{\"label\":\"Same\"},{\"label\":\" same \"}]}",
        "{\"plan\":\"p\",\"options\":[{\"label\":\"approve\"}]}",
        "{\"plan\":\"p\",\"options\":[{\"label\":\"Reject and Exit\"}]}",
        "{\"plan\":\"p\",\"options\":[{\"label\":\"  \"}]}",
        "{\"plan\":\"p\",\"options\":[{}]}",
        "{\"plan\":\"p\",\"options\":[{\"label\":\"x\"}],\"extra\":true}",
        "{\"plan\":\"p\",\"options\":[{\"label\":\"x\",\"extra\":true}]}",
    };
    for (refused) |args| {
        const decoded = try decode(.{ .allocator = std.testing.allocator, .tool_call_name = "ExitPlanMode" }, args);
        switch (decoded) {
            .input => |input| {
                input.deinit(std.testing.allocator);
                return error.TestExpectedEqual;
            },
            .failure => |message| std.testing.allocator.free(message),
        }
    }
}

test "ExitPlanMode description tells the model that only the user turns plan mode on" {
    try std.testing.expect(std.mem.find(u8, description, "only the user can turn on") != null);
    try std.testing.expect(std.mem.find(u8, description, "you cannot enter it yourself") != null);
    try std.testing.expect(std.mem.find(u8, description, plan_mode.plan_file_relative) != null);
}

test "ExitPlanMode fails outside plan mode" {
    const decoded = try decode(.{ .allocator = std.testing.allocator, .tool_call_name = "ExitPlanMode" }, "{\"plan\":\"Edit the parser.\"}");
    const input = switch (decoded) {
        .input => |value| value,
        .failure => |message| {
            std.testing.allocator.free(message);
            return error.TestExpectedEqual;
        },
    };
    defer input.deinit(std.testing.allocator);
    const result = try call(.{ .allocator = std.testing.allocator, .tool_call_name = "ExitPlanMode" }, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ExitPlanMode can only be called while plan mode is active. Only the user can turn plan mode on.", result.failure);
}

test "ExitPlanMode leaves plan mode and records the approved plan when the approved call runs" {
    var state: plan_mode.State = .{};
    state.set(true);
    const decoded = try decode(.{ .allocator = std.testing.allocator, .tool_call_name = "ExitPlanMode" }, "{\"plan\":\"1. Edit the parser.\\n2. Run its tests.\"}");
    const input = switch (decoded) {
        .input => |value| value,
        .failure => |message| {
            std.testing.allocator.free(message);
            return error.TestExpectedEqual;
        },
    };
    defer input.deinit(std.testing.allocator);
    const result = try call(.{ .allocator = std.testing.allocator, .tool_call_name = "ExitPlanMode", .plan_mode = &state }, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "Exited plan mode. Plan mode deactivated. All tools are now available.\n## Approved Plan:\n1. Edit the parser.\n2. Run its tests.",
        result.success,
    );
    try std.testing.expect(!state.isActive());
}

fn decodedPlanCall(args: []const u8) !tool_dispatch.ToolInput {
    const decoded = try decode(.{ .allocator = std.testing.allocator, .tool_call_name = "ExitPlanMode" }, args);
    return switch (decoded) {
        .input => |value| value,
        .failure => |message| {
            std.testing.allocator.free(message);
            return error.TestExpectedEqual;
        },
    };
}

test "ExitPlanMode reports the selected approach and where the approved plan was saved" {
    var state: plan_mode.State = .{};
    state.set(true);
    state.recordReview(.approved("Split work", "session-a.md"));
    const input = try decodedPlanCall("{\"plan\":\"Edit the parser.\"}");
    defer input.deinit(std.testing.allocator);
    const result = try call(.{ .allocator = std.testing.allocator, .tool_call_name = "ExitPlanMode", .plan_mode = &state }, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "Exited plan mode. Selected approach: Split work\nExecute ONLY the selected approach. Do not execute any unselected alternatives.\n\nPlan mode deactivated. All tools are now available.\nPlan saved to: session-a.md\n\n## Approved Plan:\nEdit the parser.",
        result.success,
    );
    try std.testing.expect(!state.isActive());
}

test "ExitPlanMode returns revision feedback or a dismissal without leaving plan mode" {
    var state: plan_mode.State = .{};
    state.set(true);
    const input = try decodedPlanCall("{\"plan\":\"Edit the parser.\"}");
    defer input.deinit(std.testing.allocator);

    state.recordReview(.revise("cover the tokenizer too"));
    const revised = try call(.{ .allocator = std.testing.allocator, .tool_call_name = "ExitPlanMode", .plan_mode = &state }, input);
    defer revised.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("User rejected the plan. Feedback:\n\ncover the tokenizer too", revised.success);
    try std.testing.expect(state.isActive());

    state.recordReview(.revise(null));
    const unexplained = try call(.{ .allocator = std.testing.allocator, .tool_call_name = "ExitPlanMode", .plan_mode = &state }, input);
    defer unexplained.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("User requested revisions. Plan mode remains active.", unexplained.success);
    try std.testing.expect(state.isActive());

    state.recordReview(.dismissed());
    const dismissed = try call(.{ .allocator = std.testing.allocator, .tool_call_name = "ExitPlanMode", .plan_mode = &state }, input);
    defer dismissed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Plan approval dismissed. Plan mode remains active.", dismissed.success);
    try std.testing.expect(state.isActive());
}

test "ExitPlanMode reads the plan file when plan is left out and names the file when it is empty" {
    const alloc = std.testing.allocator;
    const io_mod = @import("../../core/shared/io.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    var state: plan_mode.State = .{};
    state.set(true);
    const input = try decodedPlanCall("{}");
    defer input.deinit(alloc);

    const missing = try call(.{ .allocator = alloc, .tool_call_name = "ExitPlanMode", .plan_mode = &state, .workspace_root = workspace }, input);
    defer missing.deinit(alloc);
    const expected_missing = try std.fmt.allocPrint(alloc, "No plan file found. Write your plan to {s}/.fx/plans/plan.md first, then call ExitPlanMode.", .{workspace});
    defer alloc.free(expected_missing);
    try std.testing.expectEqualStrings(expected_missing, missing.failure);
    try std.testing.expect(state.isActive());

    const path = try plan_mode.preparePlanFile(alloc, workspace);
    defer alloc.free(path);
    try io_mod.writeFileAtomic(alloc, path, "1. Edit the parser.\n");
    const approved = try call(.{ .allocator = alloc, .tool_call_name = "ExitPlanMode", .plan_mode = &state, .workspace_root = workspace }, input);
    defer approved.deinit(alloc);
    try std.testing.expectEqualStrings(
        "Exited plan mode. Plan mode deactivated. All tools are now available.\n## Approved Plan:\n1. Edit the parser.",
        approved.success,
    );
    try std.testing.expect(!state.isActive());
}
