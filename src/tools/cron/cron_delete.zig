const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const model_tool_schema = @import("../../core/tooling/model_tool_schema.zig");
const cron_runtime = @import("../../core/cron/runtime.zig");
const ulid = @import("../../core/cron/ulid.zig");

const Allocator = std.mem.Allocator;

pub const name = "CronDelete";

pub const description =
    \\Cancel a live cron task by its `id`. Fired one-shots and expired tasks are already gone; if an id is not found, call CronList instead of retrying it.
;

pub const input_schema: model_tool_schema.ObjectSchema = .{
    .properties = &.{
        .{
            .name = "id",
            .description = "The cron job id (ULID) returned by CronCreate / CronList.",
            .json_type = .string,
        },
    },
    .required = &.{"id"},
};

const unavailable_message = "Cron tools are only supported by the main agent.";
const shape_message = "CronDelete arguments must be a JSON object with a string id.";

const Arguments = struct {
    id: ?[]const u8 = null,
};

const Input = struct {
    id: []u8,

    fn deinit(self: Input, alloc: Allocator) void {
        alloc.free(self.id);
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
    const parsed = std.json.parseFromSlice(Arguments, alloc, source, .{ .ignore_unknown_fields = true }) catch {
        return decodeFailure(alloc, shape_message);
    };
    defer parsed.deinit();
    const id_text = parsed.value.id orelse return decodeFailure(alloc, shape_message);
    if (!ulid.isId(id_text)) {
        const message = try std.fmt.allocPrint(alloc, "Invalid cron job id \"{s}\"; must be a ULID.", .{id_text});
        return .{ .failure = message };
    }
    const owned = try alloc.dupe(u8, id_text);
    errdefer alloc.free(owned);
    return .{ .input = try wrap(alloc, .{ .id = owned }) };
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const alloc = ctx.allocator;
    const input = erased.as(Input);
    const runtime = ctx.cron orelse return resultFailure(alloc, unavailable_message);
    const removed = try runtime.remove(input.id);
    if (!removed) {
        const message = try std.fmt.allocPrint(alloc, "No cron job with id {s}.", .{input.id});
        return .{ .failure = message };
    }
    const output = try std.fmt.allocPrint(alloc, "Deleted cron job {s}.", .{input.id});
    return .{ .success = output };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
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

test "CronDelete rejects an id that is not a ULID before approval" {
    const alloc = std.testing.allocator;
    var runtime = cron_runtime.Runtime.init(alloc, .{});
    defer runtime.deinit();
    const decoded = try decode(.{ .allocator = alloc, .cron = &runtime }, "{\"id\":\"not-an-id\"}");
    switch (decoded) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |text| {
            defer alloc.free(text);
            try std.testing.expectEqualStrings("Invalid cron job id \"not-an-id\"; must be a ULID.", text);
        },
    }
}

test "CronDelete removes a live job and reports a missing id on the second call" {
    const alloc = std.testing.allocator;
    var runtime = cron_runtime.Runtime.init(alloc, .{});
    defer runtime.deinit();
    const id = try runtime.newId(1_704_067_200_000);
    _ = try runtime.add(id, "0 0 * * *", "daily", 1_704_067_200_000, true);
    const ctx: tool_dispatch.DispatchContext = .{ .allocator = alloc, .cron = &runtime };
    const id_text: []const u8 = &id;
    const args = try std.fmt.allocPrint(alloc, "{{\"id\":\"{s}\"}}", .{id_text});
    defer alloc.free(args);

    const first = try decode(ctx, args);
    const first_input = switch (first) {
        .input => |value| value,
        .failure => |text| {
            alloc.free(text);
            return error.TestUnexpectedResult;
        },
    };
    defer first_input.deinit(alloc);
    const removed = try call(ctx, first_input);
    defer removed.deinit(alloc);
    const removed_text = switch (removed) {
        .success => |body| body,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(std.mem.startsWith(u8, removed_text, "Deleted cron job "));
    try std.testing.expectEqual(@as(usize, 0), runtime.list().len);

    const second = try decode(ctx, args);
    const second_input = switch (second) {
        .input => |value| value,
        .failure => |text| {
            alloc.free(text);
            return error.TestUnexpectedResult;
        },
    };
    defer second_input.deinit(alloc);
    const missing = try call(ctx, second_input);
    defer missing.deinit(alloc);
    switch (missing) {
        .failure => |text| try std.testing.expect(std.mem.startsWith(u8, text, "No cron job with id ")),
        else => return error.TestUnexpectedResult,
    }
}
