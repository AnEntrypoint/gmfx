const std = @import("std");
const support = @import("support.zig");
const ToolSpec = @import("../../core/tooling/tool_specs.zig").ToolSpec;

const DispatchContext = support.DispatchContext;
const DecodeResult = support.DecodeResult;
const DispatchError = support.DispatchError;
const ToolInput = support.ToolInput;
const ToolResult = support.ToolResult;

pub const description = "Send an inbox message to a tower participant: a roster agent by name, \"tower\" (the control tower), or \"all\" (broadcast).";

const blank_refusal = "TowerSend to, subject and body must not be empty.";

const Arguments = struct {
    to: []const u8,
    subject: []const u8,
    body: []const u8,
    scope: ?[]const u8 = null,
    action: ?[]const u8 = null,
    consent_ref: ?[]const u8 = null,
};

pub fn decode(ctx: DispatchContext, args_json: []const u8) DispatchError!DecodeResult {
    const decoded = try support.decodeArguments(Arguments, ctx, args_json);
    const value = switch (decoded) {
        .input => |input| input,
        .failure => return decoded,
    };
    const args = support.valueOf(Arguments, value);
    if (isBlank(args.to) or isBlank(args.subject) or isBlank(args.body)) {
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

    const file = store.send(arena, .{
        .to = args.to,
        .subject = args.subject,
        .body = args.body,
        .scope = args.scope,
        .action = args.action,
        .consent_ref = args.consent_ref,
    }, support.nowMs()) catch |err| return support.fail(ctx, &store, err);
    return support.success(ctx, try std.fmt.allocPrint(arena, "sent: {s}", .{file}));
}

pub fn readsOnly(_: ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: ToolInput) bool {
    return false;
}

pub const spec = ToolSpec{
    .name = "TowerSend",
    .description = description,
    .model_schema = .{
        .name = "TowerSend",
        .description = description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "to", .json_type = .string, .description = "Recipient: a roster agent name, \"tower\", or \"all\"." },
                .{ .name = "subject", .json_type = .string, .description = "Short subject line for the message." },
                .{ .name = "body", .json_type = .string, .description = "Message body." },
                .{ .name = "scope", .json_type = .string, .description = "Optional scope the message concerns." },
                .{ .name = "action", .json_type = .string, .description = "Optional action the recipient is asked to take." },
                .{ .name = "consent_ref", .json_type = .string, .description = "Optional reference to the consent that authorizes the action." },
            },
            .required = &.{ "to", "subject", "body" },
            .additional_properties = false,
        },
    },
    .executor_kind = .tower,
    .activity_kind = .write,
    .requires_approval = false,
    .action_label = "Sending message",
    .completed_action_label = "Sent message",
    .label_arg_kind = .none,
    .label_arg_default = "",
    .permission_target_kind = .none,
    .decode = decode,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

test "Tower TowerSend refuses blank required fields and unknown keys" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc };
    const refused = [_][]const u8{
        "{\"to\":\"all\",\"subject\":\"  \",\"body\":\"hello\"}",
        "{\"to\":\"all\",\"subject\":\"hi\",\"body\":\"hello\",\"extra\":1}",
        "{\"to\":\"all\",\"subject\":\"hi\"}",
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

test "Tower TowerSend refuses with the not-initialized message when tower is absent" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc, .workspace_root = "/nonexistent-tower-root" };
    const decoded = try decode(ctx, "{\"to\":\"all\",\"subject\":\"hi\",\"body\":\"hello\"}");
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
