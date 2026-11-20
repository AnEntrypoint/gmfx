const std = @import("std");
const support = @import("support.zig");
const git = @import("../../core/tower/git.zig");
const ToolSpec = @import("../../core/tooling/tool_specs.zig").ToolSpec;

const DispatchContext = support.DispatchContext;
const DecodeResult = support.DecodeResult;
const DispatchError = support.DispatchError;
const ToolInput = support.ToolInput;
const ToolResult = support.ToolResult;

pub const description = "Submit a review verdict for a branch you were assigned to review (via TowerSpawn review_target).";

const blank_refusal = "TowerReview target, status, findings and decision must not be empty.";

const MergeVerdict = enum { merge, @"fix-then-merge", hold };

const Arguments = struct {
    target: []const u8,
    status: []const u8,
    merge: MergeVerdict,
    findings: []const u8,
    checks: []const []const u8 = &.{},
    decision: []const u8,
};

pub fn decode(ctx: DispatchContext, args_json: []const u8) DispatchError!DecodeResult {
    const decoded = try support.decodeArguments(Arguments, ctx, args_json);
    const value = switch (decoded) {
        .input => |input| input,
        .failure => return decoded,
    };
    const args = support.valueOf(Arguments, value);
    if (isBlank(args.target) or isBlank(args.status) or isBlank(args.findings) or isBlank(args.decision)) {
        value.deinit(ctx.allocator);
        return .{ .failure = try ctx.allocator.dupe(u8, blank_refusal) };
    }
    return decoded;
}

fn isBlank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r\n").len == 0;
}

pub fn call(ctx: DispatchContext, erased: ToolInput) DispatchError!ToolResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = support.valueOf(Arguments, erased);
    var store = support.storeFor(ctx);

    _ = store.load(arena) catch |err| return support.fail(ctx, &store, err);
    const reviewed_commit = git.branchTip(arena, store.root, args.target) catch {
        const message = try std.fmt.allocPrint(arena, "review target \"{s}\" does not resolve to a commit", .{args.target});
        return support.fail(ctx, &store, store.refuse(message));
    };
    const rel = store.submitReview(arena, .{
        .target = args.target,
        .status = args.status,
        .merge = @tagName(args.merge),
        .findings = args.findings,
        .checks = args.checks,
        .decision = args.decision,
    }, reviewed_commit, support.nowMs()) catch |err| return support.fail(ctx, &store, err);
    return support.success(ctx, try std.fmt.allocPrint(arena, "review submitted: {s}", .{rel}));
}

pub fn readsOnly(_: ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: ToolInput) bool {
    return false;
}

pub const spec = ToolSpec{
    .name = "TowerReview",
    .description = description,
    .model_schema = .{
        .name = "TowerReview",
        .description = description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "target", .json_type = .string, .description = "Branch under review, as assigned by TowerSpawn review_target." },
                .{ .name = "status", .json_type = .string, .description = "clean, p1-<n>items or p2-<n>items." },
                .{ .name = "merge", .json_type = .string, .description = "Merge verdict.", .shape = &.{ .enum_values = &.{ "merge", "fix-then-merge", "hold" } } },
                .{ .name = "findings", .json_type = .string, .description = "Findings written as the review body." },
                .{ .name = "checks", .json_type = .array, .description = "Checks that were run and passed.", .shape = &.{ .array_values = .{ .json_type = .string } } },
                .{ .name = "decision", .json_type = .string, .description = "Decision rationale." },
            },
            .required = &.{ "target", "status", "merge", "findings", "decision" },
            .additional_properties = false,
        },
    },
    .executor_kind = .tower,
    .activity_kind = .write,
    .requires_approval = false,
    .action_label = "Submitting review",
    .completed_action_label = "Submitted review",
    .label_arg_kind = .none,
    .label_arg_default = "",
    .permission_target_kind = .none,
    .decode = decode,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

test "Tower TowerReview refuses an unknown merge verdict, blank findings and unknown keys" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc };
    const refused = [_][]const u8{
        "{\"target\":\"feat/x\",\"status\":\"clean\",\"merge\":\"maybe\",\"findings\":\"none\",\"decision\":\"ok\"}",
        "{\"target\":\"feat/x\",\"status\":\"clean\",\"merge\":\"merge\",\"findings\":\" \",\"decision\":\"ok\"}",
        "{\"target\":\"feat/x\",\"status\":\"clean\",\"merge\":\"merge\",\"findings\":\"none\",\"decision\":\"ok\",\"reviewer\":\"me\"}",
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

test "Tower TowerReview accepts a hyphenated merge verdict and checks" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc };
    const decoded = try decode(ctx, "{\"target\":\"feat/x\",\"status\":\"p2-1items\",\"merge\":\"fix-then-merge\",\"findings\":\"nit\",\"checks\":[\"build\"],\"decision\":\"ok\"}");
    switch (decoded) {
        .input => |input| input.deinit(alloc),
        .failure => |message| {
            alloc.free(message);
            return error.TestExpectedEqual;
        },
    }
}

test "Tower TowerReview refuses with the not-initialized message when tower is absent" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc, .workspace_root = "/nonexistent-tower-root" };
    const decoded = try decode(ctx, "{\"target\":\"feat/x\",\"status\":\"clean\",\"merge\":\"merge\",\"findings\":\"none\",\"decision\":\"ok\"}");
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
        .failure => |message| try std.testing.expectEqualStrings("tower is not initialized in this repository — run TowerInit first", message),
        else => return error.TestExpectedEqual,
    }
}
