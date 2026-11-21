const std = @import("std");

const builtin_tools = @import("tools.zig");
const mode_contract = @import("../core/modes/mode_contract.zig");
const mode_registry = @import("../core/modes/mode_registry.zig");
const tool_set_contract = @import("../core/tooling/tool_set.zig");
const tool_projection = @import("../core/tooling/tool_projection.zig");

pub const ModeSpec = mode_contract.ModeSpec;
pub const ToolPolicy = mode_contract.ToolPolicy;
pub const default_mode_id = "auto";

pub const all = [_]ModeSpec{
    .{ .id = "auto", .name = "Auto", .description = "Check actions with an automatic safety review instead of asking", .permission_mode = .auto },
    .{ .id = "ask", .name = "Ask", .description = "Request permission before making any changes", .permission_mode = .ask },
    .{ .id = "full-access", .name = "Full access", .description = "Run every action without fx permission checks", .permission_mode = .yolo },
    .{ .id = "dontAsk", .name = "Don't ask", .description = "Deny anything that would prompt instead of asking", .permission_mode = .dontAsk },
};

pub const registry = mode_registry.Registry{
    .default_mode_id = default_mode_id,
    .modes = all[0..],
};

pub const acp_all = [_]ModeSpec{
    .{ .id = "default", .name = "Default", .description = "Manual approvals; tools execute normally.", .permission_mode = .ask },
    .{ .id = "plan", .name = "Plan", .description = "Read-only planning; no tool execution.", .permission_mode = .ask, .tool_policy = .read_only, .tool_policy_denial_message = "Plan mode only allows read-only workspace inspection tools." },
    .{ .id = "auto", .name = "Auto", .description = "Auto-approve safe operations.", .permission_mode = .auto },
    .{ .id = "yolo", .name = "YOLO", .description = "Auto-approve everything.", .permission_mode = .yolo },
};

pub const acp_registry = mode_registry.Registry{
    .default_mode_id = "default",
    .modes = acp_all[0..],
};

pub fn lookup(id: []const u8) ?*const ModeSpec {
    return registry.lookup(id);
}

test "built-in modes register the CLI permission modes in ACP order" {
    const expected = [_]struct { id: []const u8, name: []const u8, permission_mode: @TypeOf(all[0].permission_mode) }{
        .{ .id = "auto", .name = "Auto", .permission_mode = .auto },
        .{ .id = "ask", .name = "Ask", .permission_mode = .ask },
        .{ .id = "full-access", .name = "Full access", .permission_mode = .yolo },
        .{ .id = "dontAsk", .name = "Don't ask", .permission_mode = .dontAsk },
    };
    try std.testing.expectEqual(expected.len, all.len);
    for (expected, all) |want, mode| {
        try std.testing.expectEqualStrings(want.id, mode.id);
        try std.testing.expectEqualStrings(want.name, mode.name);
        try std.testing.expectEqual(want.permission_mode, mode.permission_mode);
        try std.testing.expectEqual(ToolPolicy.full, mode.tool_policy);
    }

    try std.testing.expectEqualStrings("auto", default_mode_id);
    try std.testing.expectEqualStrings(default_mode_id, registry.default_mode_id);
    try std.testing.expect(lookup("code") == null);
    try std.testing.expect(lookup("yolo") == null);
    try std.testing.expect(lookup("unknown") == null);
}

test "built-in mode projections carry included custom provider guidance" {
    inline for (&.{ "auto", "ask", "full-access" }) |mode_id| {
        var projection = try registry.buildModelToolProjection(
            std.testing.allocator,
            builtin_tools.advertisement_set,
            mode_id,
            .{ .run_code_surface = false },
        );
        defer projection.deinit(std.testing.allocator);

        try std.testing.expect(tool_projection.containsName(projection.advertised_names, "WebSearch"));
        try std.testing.expectEqualStrings(builtin_tools.web_search.description, projection.custom_guidance);
    }
}

test "built-in mode projections use the supplied tool set" {
    const tools = [_]builtin_tools.ToolSpec{
        builtin_tools.lookup("read_file") orelse return error.TestExpectedEqual,
    };
    const ordered_names = [_][]const u8{ "write_file", "read_file" };
    const read_only_names = [_][]const u8{ "write_file", "read_file" };
    const tool_set = tool_set_contract.ToolSet{
        .registry = .{ .tools = tools[0..] },
        .order = ordered_names[0..],
        .read_only_tool_names = read_only_names[0..],
    };

    var projection = try registry.buildModelToolProjection(std.testing.allocator, tool_set, "ask", .{});
    defer projection.deinit(std.testing.allocator);
    try std.testing.expect(tool_projection.containsName(projection.advertised_names, "read_file"));
    try std.testing.expect(!tool_projection.containsName(projection.advertised_names, "write_file"));
    try std.testing.expectEqualStrings("", projection.custom_guidance);
}

test "ACP modes are default, plan, auto and yolo, and only plan is read-only" {
    const ids = [_][]const u8{ "default", "plan", "auto", "yolo" };
    try std.testing.expectEqual(ids.len, acp_all.len);
    for (ids, acp_all) |id, mode| try std.testing.expectEqualStrings(id, mode.id);
    try std.testing.expect(acp_all[0].permission_mode == .ask);
    try std.testing.expect(acp_all[1].permission_mode == .ask);
    try std.testing.expect(acp_all[2].permission_mode == .auto);
    try std.testing.expect(acp_all[3].permission_mode == .yolo);
    try std.testing.expectEqual(ToolPolicy.full, acp_all[0].tool_policy);
    try std.testing.expectEqual(ToolPolicy.read_only, acp_all[1].tool_policy);
    try std.testing.expectEqual(ToolPolicy.full, acp_all[2].tool_policy);
    try std.testing.expectEqual(ToolPolicy.full, acp_all[3].tool_policy);
    try std.testing.expectEqualStrings("default", acp_registry.default_mode_id);
    try std.testing.expectEqualStrings("default", acp_registry.startingModeId(.ask));
    try std.testing.expectEqualStrings("auto", acp_registry.startingModeId(.auto));
    try std.testing.expectEqualStrings("yolo", acp_registry.startingModeId(.yolo));
    try std.testing.expect(acp_registry.lookup("ask") == null);
    try std.testing.expect(acp_registry.lookup("full-access") == null);
}
