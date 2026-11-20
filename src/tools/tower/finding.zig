const std = @import("std");
const support = @import("support.zig");
const ToolSpec = @import("../../core/tooling/tool_specs.zig").ToolSpec;

const DispatchContext = support.DispatchContext;
const DecodeResult = support.DecodeResult;
const DispatchError = support.DispatchError;
const ToolInput = support.ToolInput;
const ToolResult = support.ToolResult;

pub const description = "File a structured finding (bug / improve / vuln / idea) into .tower/comms/findings/ for the tower to route.";

const blank_refusal = "TowerFinding title, summary, details and suggested_fix must not be empty.";

const FindingType = enum { bug, improve, vuln, idea };
const Severity = enum { low, medium, high, critical };

const Arguments = struct {
    type: FindingType,
    title: []const u8,
    severity: ?Severity = null,
    summary: []const u8,
    location: ?[]const u8 = null,
    details: []const u8,
    suggested_fix: []const u8,
};

pub fn decode(ctx: DispatchContext, args_json: []const u8) DispatchError!DecodeResult {
    const decoded = try support.decodeArguments(Arguments, ctx, args_json);
    const value = switch (decoded) {
        .input => |input| input,
        .failure => return decoded,
    };
    const args = support.valueOf(Arguments, value);
    if (isBlank(args.title) or isBlank(args.summary) or isBlank(args.details) or isBlank(args.suggested_fix)) {
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
    const severity: ?[]const u8 = if (args.severity) |value| @tagName(value) else null;
    const rel = store.fileFinding(arena, .{
        .finding_type = @tagName(args.type),
        .title = args.title,
        .severity = severity,
        .summary = args.summary,
        .location = args.location,
        .details = args.details,
        .suggested_fix = args.suggested_fix,
    }, support.nowMs()) catch |err| return support.fail(ctx, &store, err);
    return support.success(ctx, try std.fmt.allocPrint(arena, "finding filed: {s}", .{rel}));
}

pub fn readsOnly(_: ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: ToolInput) bool {
    return false;
}

pub const spec = ToolSpec{
    .name = "TowerFinding",
    .description = description,
    .model_schema = .{
        .name = "TowerFinding",
        .description = description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "type", .json_type = .string, .description = "Finding kind.", .shape = &.{ .enum_values = &.{ "bug", "improve", "vuln", "idea" } } },
                .{ .name = "title", .json_type = .string, .description = "Short title for the finding." },
                .{ .name = "severity", .json_type = .string, .description = "Optional severity. Defaults to medium.", .shape = &.{ .enum_values = &.{ "low", "medium", "high", "critical" } } },
                .{ .name = "summary", .json_type = .string, .description = "One-paragraph summary." },
                .{ .name = "location", .json_type = .string, .description = "Optional file or area the finding concerns." },
                .{ .name = "details", .json_type = .string, .description = "Full details and evidence." },
                .{ .name = "suggested_fix", .json_type = .string, .description = "Suggested fix or next action." },
            },
            .required = &.{ "type", "title", "summary", "details", "suggested_fix" },
            .additional_properties = false,
        },
    },
    .executor_kind = .tower,
    .activity_kind = .write,
    .requires_approval = false,
    .action_label = "Filing finding",
    .completed_action_label = "Filed finding",
    .label_arg_kind = .none,
    .label_arg_default = "",
    .permission_target_kind = .none,
    .decode = decode,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

test "Tower TowerFinding refuses an unknown type, blank text and unknown keys" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc };
    const refused = [_][]const u8{
        "{\"type\":\"nope\",\"title\":\"t\",\"summary\":\"s\",\"details\":\"d\",\"suggested_fix\":\"f\"}",
        "{\"type\":\"bug\",\"title\":\" \",\"summary\":\"s\",\"details\":\"d\",\"suggested_fix\":\"f\"}",
        "{\"type\":\"bug\",\"title\":\"t\",\"summary\":\"s\",\"details\":\"d\",\"suggested_fix\":\"f\",\"priority\":1}",
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

test "Tower TowerFinding refuses with the not-initialized message when tower is absent" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc, .workspace_root = "/nonexistent-tower-root" };
    const decoded = try decode(ctx, "{\"type\":\"idea\",\"severity\":\"low\",\"title\":\"t\",\"summary\":\"s\",\"details\":\"d\",\"suggested_fix\":\"f\"}");
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
