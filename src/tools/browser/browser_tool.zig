const std = @import("std");
const browser_request = @import("../../core/browser/request.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const request = try ctx.allocator.create(browser_request.Request);
    errdefer ctx.allocator.destroy(request);
    request.* = browser_request.Request.parse(ctx.allocator, args_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            ctx.allocator.destroy(request);
            return .{ .failure = try ctx.allocator.dupe(u8, browser_request.failureMessage(err)) };
        },
    };
    return .{ .input = .{ .ptr = request, .deinit_fn = deinitInput } };
}

fn deinitInput(raw: *anyopaque, alloc: Allocator) void {
    const request: *browser_request.Request = @ptrCast(@alignCast(raw));
    request.deinit();
    alloc.destroy(request);
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const provider = ctx.browser_provider orelse return .{
        .failure = try ctx.allocator.dupe(u8, "The browser route is not available in this session."),
    };
    return provider.execute(ctx, input);
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

test "browser tool decodes a targets request and rejects a malformed one" {
    const alloc = std.testing.allocator;
    const ctx = tool_dispatch.DispatchContext{ .allocator = alloc };
    const decoded = try decode(ctx, "{\"action\":\"targets\"}");
    switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            return error.TestUnexpectedResult;
        },
        .input => |input| input.deinit(alloc),
    }
    const rejected = try decode(ctx, "{\"action\":\"open\"}");
    switch (rejected) {
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expect(std.mem.indexOf(u8, body, "url") != null);
        },
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
    }
}

test "browser tool without an app-owned provider answers with a failure, not a crash" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"action\":\"targets\"}");
    const input = switch (decoded) {
        .input => |input| input,
        .failure => |body| {
            defer alloc.free(body);
            return error.TestUnexpectedResult;
        },
    };
    defer input.deinit(alloc);
    const result = try call(.{ .allocator = alloc }, input);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("The browser route is not available in this session.", result.failure);
}
