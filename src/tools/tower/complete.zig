const std = @import("std");
const support = @import("support.zig");
const ToolSpec = @import("../../core/tooling/tool_specs.zig").ToolSpec;

const DispatchContext = support.DispatchContext;
const DecodeResult = support.DecodeResult;
const DispatchError = support.DispatchError;
const ToolInput = support.ToolInput;
const ToolResult = support.ToolResult;

pub const description = "Complete the mission owned by the calling tower worker and persist its standard completion notification in one locked protocol flow.";

const blank_refusal = "TowerComplete report must not be empty";

const Arguments = struct {
    report: []const u8,
};

pub fn decode(ctx: DispatchContext, args_json: []const u8) DispatchError!DecodeResult {
    const decoded = try support.decodeArguments(Arguments, ctx, args_json);
    const value = switch (decoded) {
        .input => |input| input,
        .failure => return decoded,
    };
    if (std.mem.trim(u8, support.valueOf(Arguments, value).report, " \t\r\n").len == 0) {
        value.deinit(ctx.allocator);
        return .{ .failure = try ctx.allocator.dupe(u8, blank_refusal) };
    }
    return decoded;
}

pub fn call(ctx: DispatchContext, erased: ToolInput) DispatchError!ToolResult {
    const args = support.valueOf(Arguments, erased);
    var store = support.storeFor(ctx);

    const rel = store.completeMission(args.report) catch |err| return support.fail(ctx, &store, err);
    return support.success(ctx, rel);
}

pub fn readsOnly(_: ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: ToolInput) bool {
    return false;
}

pub const spec = ToolSpec{
    .name = "TowerComplete",
    .description = description,
    .model_schema = .{
        .name = "TowerComplete",
        .description = description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "report", .json_type = .string, .description = "Completion report for the mission." },
            },
            .required = &.{"report"},
            .additional_properties = false,
        },
    },
    .executor_kind = .tower,
    .activity_kind = .write,
    .requires_approval = false,
    .action_label = "Completing mission",
    .completed_action_label = "Completed mission",
    .label_arg_kind = .none,
    .label_arg_default = "",
    .permission_target_kind = .none,
    .decode = decode,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

test "Tower TowerComplete refuses a blank report and unknown keys" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc };
    const refused = [_][]const u8{
        "{\"report\":\"  \\n\"}",
        "{\"report\":\"done\",\"owner\":\"M1\"}",
        "{}",
    };
    for (refused) |args| {
        const decoded = try decode(ctx, args);
        switch (decoded) {
            .input => |input| {
                input.deinit(alloc);
                return error.TestExpectedEqual;
            },
            .failure => |message| alloc.free(message),
        }
    }
}

test "Tower TowerComplete passes through the worker-only refusal" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc, .workspace_root = "/nonexistent-tower-root" };
    const decoded = try decode(ctx, "{\"report\":\"all tasks done\"}");
    const input = switch (decoded) {
        .input => |value| value,
        .failure => |message| {
            alloc.free(message);
            return error.TestExpectedEqual;
        },
    };
    defer input.deinit(alloc);
    const result = try call(ctx, input);
    defer result.deinit(alloc);
    switch (result) {
        .failure => |message| try std.testing.expectEqualStrings("cannot use TowerComplete — only the worker who owns a mission can complete it", message),
        else => return error.TestExpectedEqual,
    }
}
