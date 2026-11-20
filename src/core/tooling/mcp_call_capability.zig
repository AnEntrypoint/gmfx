const std = @import("std");
const builtin = @import("builtin");
const types = @import("../shared/types.zig");
const mcp_resources = @import("../../mcp/protocol/resources.zig");

const Allocator = std.mem.Allocator;

pub const supported = switch (builtin.target.os.tag) {
    .linux, .macos => true,
    else => false,
};

pub const max_result_bytes: usize = 16 * 1024 * 1024;

pub const Authorization = union(enum) {
    allow: struct { binding: ?types.McpToolBinding = null },
    deny: []const u8,
};

pub const CallStatus = enum { ok, tool_error, failed };

pub const CallOutcome = struct {
    status: CallStatus,
    bytes: []const u8,
};

pub const Lookup = union(enum) {
    list: []const u8,
    search: []const u8,
    help: []const u8,
    resource: struct { server: []const u8, op: mcp_resources.Op },
};

pub const Capability = struct {
    context: *anyopaque,
    authorize_fn: *const fn (
        context: *anyopaque,
        arena: Allocator,
        request_id: []const u8,
        tool: []const u8,
        arguments_json: []const u8,
    ) anyerror!Authorization,
    call_fn: *const fn (
        context: *anyopaque,
        arena: Allocator,
        request_id: []const u8,
        tool: []const u8,
        arguments_json: []const u8,
        allowed: @FieldType(Authorization, "allow"),
        cancel: *std.atomic.Value(bool),
    ) anyerror!CallOutcome,
    lookup_fn: *const fn (
        context: *anyopaque,
        arena: Allocator,
        lookup: Lookup,
        cancel: *std.atomic.Value(bool),
    ) anyerror!CallOutcome,

    pub fn authorize(self: Capability, arena: Allocator, request_id: []const u8, tool: []const u8, arguments_json: []const u8) anyerror!Authorization {
        return self.authorize_fn(self.context, arena, request_id, tool, arguments_json);
    }

    pub fn call(self: Capability, arena: Allocator, request_id: []const u8, tool: []const u8, arguments_json: []const u8, allowed: @FieldType(Authorization, "allow"), cancel: *std.atomic.Value(bool)) anyerror!CallOutcome {
        return self.call_fn(self.context, arena, request_id, tool, arguments_json, allowed, cancel);
    }

    pub fn lookup(self: Capability, arena: Allocator, question: Lookup, cancel: *std.atomic.Value(bool)) anyerror!CallOutcome {
        return self.lookup_fn(self.context, arena, question, cancel);
    }
};
