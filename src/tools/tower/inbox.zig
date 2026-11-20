const std = @import("std");
const support = @import("support.zig");
const ToolSpec = @import("../../core/tooling/tool_specs.zig").ToolSpec;

const DispatchContext = support.DispatchContext;
const DecodeResult = support.DecodeResult;
const DispatchError = support.DispatchError;
const ToolInput = support.ToolInput;
const ToolResult = support.ToolResult;
const Message = support.Store.Message;

pub const description = "Read your tower inbox: messages addressed to you plus broadcasts, newest first.";

const default_limit: i64 = 20;
const limit_refusal = "TowerInbox limit must be a positive integer.";

const Arguments = struct {
    limit: i64 = default_limit,
    include_read: bool = false,
};

pub fn decode(ctx: DispatchContext, args_json: []const u8) DispatchError!DecodeResult {
    const decoded = try support.decodeArguments(Arguments, ctx, args_json);
    const value = switch (decoded) {
        .input => |input| input,
        .failure => return decoded,
    };
    if (support.valueOf(Arguments, value).limit < 1) {
        value.deinit(ctx.allocator);
        return refuseDecode(ctx, limit_refusal);
    }
    return decoded;
}

fn refuseDecode(ctx: DispatchContext, message: []const u8) DispatchError!DecodeResult {
    return .{ .failure = try ctx.allocator.dupe(u8, message) };
}

pub fn call(ctx: DispatchContext, erased: ToolInput) DispatchError!ToolResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = support.valueOf(Arguments, erased);
    var store = support.storeFor(ctx);

    const st = store.load(arena) catch |err| return support.fail(ctx, &store, err);
    const messages = store.listInbox(arena) catch |err| return support.fail(ctx, &store, err);
    const limit: usize = @intCast(args.limit);

    var visible: std.ArrayList(Message) = .empty;
    for (messages) |message| {
        if (visible.items.len >= limit) break;
        if (!args.include_read and containsId(st.inboxAckIds, message.message_id)) continue;
        try visible.append(arena, message);
    }

    const ids = try arena.alloc([]const u8, visible.items.len);
    for (visible.items, ids) |message, *id| id.* = message.message_id;
    const unread = store.ackInbox(arena, ids, support.nowMs()) catch |err| return support.fail(ctx, &store, err);

    if (visible.items.len == 0) {
        return support.success(ctx, try std.fmt.allocPrint(arena, "inbox empty for tower; {d} unread message(s) remaining", .{unread}));
    }
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "inbox for tower: {d} message(s) shown; {d} unread message(s) remaining", .{ visible.items.len, unread });
    for (visible.items) |message| {
        try out.appendSlice(arena, "\n\n");
        try renderMessage(arena, &out, message);
    }
    return support.success(ctx, out.items);
}

fn containsId(acked: ?[]const []const u8, id: []const u8) bool {
    const list = acked orelse return false;
    for (list) |item| {
        if (std.mem.eql(u8, item, id)) return true;
    }
    return false;
}

fn renderMessage(arena: std.mem.Allocator, out: *std.ArrayList(u8), message: Message) !void {
    try out.print(arena, "file: {s}\nfrom: {s}\nto: {s}\nsubject: {s}\nsent_at: {s}", .{
        message.file, message.from, message.to, message.subject, message.sent_at,
    });
    if (message.scope) |scope| try out.print(arena, "\nscope: {s}", .{scope});
    if (message.action) |action| try out.print(arena, "\naction: {s}", .{action});
    if (message.consent_ref) |consent_ref| try out.print(arena, "\nconsent_ref: {s}", .{consent_ref});
    try out.print(arena, "\n\n{s}", .{message.body});
}

pub fn readsOnly(_: ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: ToolInput) bool {
    return false;
}

pub const spec = ToolSpec{
    .name = "TowerInbox",
    .description = description,
    .model_schema = .{
        .name = "TowerInbox",
        .description = description,
        .input_schema = .{
            .properties = &.{
                .{ .name = "limit", .json_type = .integer, .description = "Most messages to show, at least 1. Defaults to 20.", .bounds = &.{ .minimum = 1 } },
                .{ .name = "include_read", .json_type = .boolean, .description = "Also show messages already read. Defaults to false." },
            },
            .additional_properties = false,
        },
    },
    .executor_kind = .tower,
    .activity_kind = .write,
    .requires_approval = false,
    .action_label = "Reading inbox",
    .completed_action_label = "Read inbox",
    .label_arg_kind = .none,
    .label_arg_default = "",
    .permission_target_kind = .none,
    .decode = decode,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

test "Tower TowerInbox refuses a non-positive limit and unknown keys" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc };
    for ([_][]const u8{ "{\"limit\":0}", "{\"unknown\":true}" }) |args| {
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

test "Tower TowerInbox refuses with the not-initialized message when tower is absent" {
    const alloc = std.testing.allocator;
    const ctx = DispatchContext{ .allocator = alloc, .workspace_root = "/nonexistent-tower-root" };
    const decoded = try decode(ctx, "{}");
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
