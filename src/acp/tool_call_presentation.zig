const std = @import("std");
const acp_types = @import("types.zig");
const server = @import("server.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");
const tool_presentation = @import("../core/tooling/tool_presentation.zig");
const run_code_presentation = @import("../core/tooling/run_code_presentation.zig");
const tool_result_errors = @import("../core/tooling/tool_result_errors.zig");
const tool_set_contract = @import("../core/tooling/tool_set.zig");
const text_utils = @import("../core/shared/text_utils.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const builtin_tools = @import("../builtins/tools.zig");
const host_target = @import("../core/hosts/target.zig");
const types = @import("../core/shared/types.zig");
const catalog_state = @import("../core/mcp/catalog_state.zig");
const json_decode = @import("../core/shared/json_decode.zig");

const Allocator = std.mem.Allocator;
const ToolCall = types.ToolCall;

pub fn acpToolName(tool_name: []const u8) []const u8 {
    return if (tool_presentation.isProviderSearchAlias(tool_name)) "WebSearch" else tool_name;
}

pub fn mapToolKind(tool_name: []const u8) acp_types.ToolCallKind {
    if (tool_presentation.isProviderSearchAlias(tool_name)) return .search;
    if (run_code_presentation.isRunCode(tool_name)) return .execute;
    if (std.mem.eql(u8, tool_name, "glob_files")) return .read;
    if (std.mem.eql(u8, tool_name, "grep_files")) return .search;
    if (std.mem.eql(u8, tool_name, "read_file")) return .read;
    if (std.mem.eql(u8, tool_name, "FetchURL")) return .fetch;
    if (std.mem.eql(u8, tool_name, "WebSearch")) return .search;
    if (std.mem.eql(u8, tool_name, "write_file")) return .edit;
    if (std.mem.eql(u8, tool_name, "edit_file")) return .edit;
    if (std.mem.eql(u8, tool_name, "Bash")) return .execute;
    if (std.mem.eql(u8, tool_name, "terminal")) return .execute;
    if (std.mem.eql(u8, tool_name, "run_command")) return .execute;
    if (std.mem.eql(u8, tool_name, "Skill")) return .other;
    if (std.mem.eql(u8, tool_name, "install_skill")) return .other;
    return .other;
}

pub fn describeToolTitle(registry: tool_dispatch.Registry, arena: Allocator, call: ToolCall) ![]const u8 {
    if (run_code_presentation.isRunCode(call.name)) return run_code_presentation.title(arena, call);
    if (registry.lookup(call.name)) |tool| {
        if (try tool_presentation.formatSubagentPlainAction(arena, call, .identity)) |title| return title;

        if (tool.executor_kind == .read_tool_result) {
            return tool_presentation.formatPlainAction(arena, .{ .tool_registry = registry, .call = call });
        }
    }
    if (tool_presentation.isProviderSearchAlias(call.name)) {
        return tool_presentation.formatPlainAction(arena, .{
            .tool_registry = registry,
            .call = call,
        });
    }
    if (tool_dispatch.toolCallPresentation(arena, registry, call)) |presentation| {
        return arena.print("{s}", .{presentation.action_label});
    }
    return arena.print("{s}", .{call.name});
}

pub const ToolCallPresentation = struct {
    title: []const u8,
    meta: acp_types.ToolCallMeta,
};

pub fn describeToolCall(
    registry: tool_dispatch.Registry,
    arena: Allocator,
    call: ToolCall,
    mcp_identity: ?catalog_state.ToolIdentity,
) ToolCallPresentation {
    if (registry.lookup(call.name)) |tool| {
        return .{
            .title = describeToolTitle(registry, arena, call) catch "Tool call",
            .meta = .{ .internal = tool.internal },
        };
    }
    if (mcp_identity) |identity| {
        return .{
            .title = identity.title orelse identity.tool,
            .meta = .{ .mcp = .{ .server = identity.server, .tool = identity.tool } },
        };
    }
    return .{ .title = describeToolTitle(registry, arena, call) catch "Tool call", .meta = .{} };
}

pub fn activeToolSet(state: *const server.ServerState) tool_set_contract.ToolSet {
    if (state.host_tools.tools.len > 0) return state.host_tools.toolSet();
    if (comptime host_target.is_wasm) return tool_set_contract.empty;
    return if (state.cfg.allow_native_tools) builtin_tools.advertisement_set else tool_set_contract.empty;
}

pub fn activeToolRegistry(state: *const server.ServerState) tool_dispatch.Registry {
    return activeToolSet(state).registry;
}

const ShellResultView = struct {
    state: []const u8,
    output_delta: []const u8,
    output_truncated: bool = false,
    notice: ?[]const u8 = null,
};

const shell_output_cut_marker = "... output truncated ...";

const tool_update_preview_bytes = 200;

pub fn shellUpdateContentText(
    alloc: Allocator,
    tool_name: []const u8,
    output: []const u8,
) Allocator.Error!?[]u8 {
    if (!std.mem.eql(u8, tool_name, "Bash")) return null;
    const parsed = json_decode.parseFromSlice(
        ShellResultView,
        alloc,
        output,
        .{ .ignore_unknown_fields = true },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    const view = parsed.value;
    const preview = toolUpdateContentText(false, view.output_delta);

    const cut = preview.ptr == view.output_delta.ptr and
        (view.output_truncated or preview.len < view.output_delta.len);
    const marker_break: []const u8 = if (cut and preview.len > 0 and preview[preview.len - 1] != '\n') "\n" else "";
    return try std.mem.concat(alloc, u8, &.{
        view.notice orelse "",
        if (view.notice != null) "\n" else "",
        preview,
        marker_break,
        if (cut) shell_output_cut_marker else "",
    });
}

pub fn resultContentText(
    alloc: Allocator,
    registry: tool_dispatch.Registry,
    call: ToolCall,
    output: []const u8,
) Allocator.Error!?[]u8 {
    if (try run_code_presentation.detail(alloc, registry, call, output)) |text| return text;
    return shellUpdateContentText(alloc, call.name, output);
}

pub fn pendingContentText(alloc: Allocator, call: ToolCall) Allocator.Error!?[]u8 {
    return run_code_presentation.bodyBlock(alloc, call);
}

pub fn toolUpdateContentText(is_failure: bool, output: []const u8) []const u8 {
    if (!text_utils.isModelSafeText(output)) {
        debug_trace.logf(
            "acp",
            "tool update omitted binary or non-utf8 output bytes={d}",
            .{output.len},
        );
        return "binary or non-utf8 tool output omitted";
    }
    if (is_failure and
        (tool_result_errors.isToolPermissionDeniedOutput(output) or
            tool_result_errors.isToolReviewHeldOutput(output)))
    {
        return output;
    }
    return text_utils.utf8PrefixByBytes(output, tool_update_preview_bytes);
}

test "describeToolCall flags internal discovery and names MCP identity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const registry = builtin_tools.registry;

    const search = describeToolCall(registry, arena, .{ .id = "a", .name = "capability_search", .arguments_json = "{}" }, null);
    try std.testing.expect(search.meta.internal);
    const select = describeToolCall(registry, arena, .{ .id = "b", .name = "select_tools", .arguments_json = "{}" }, null);
    try std.testing.expect(select.meta.internal);
    const read = describeToolCall(registry, arena, .{ .id = "c", .name = "read_file", .arguments_json = "{}" }, null);
    try std.testing.expect(!read.meta.internal);
    try std.testing.expect(read.meta.mcp == null);

    var server_name = "mini".*;
    var tool_name = "browser_eval".*;
    const untitled = describeToolCall(registry, arena, .{ .id = "d", .name = "mcp_mini_browser_eval", .arguments_json = "{}" }, .{
        .server = &server_name,
        .tool = &tool_name,
    });
    try std.testing.expectEqualStrings("browser_eval", untitled.title);
    try std.testing.expectEqualStrings("mini", untitled.meta.mcp.?.server);
    var title = "Evaluate JavaScript".*;
    const titled = describeToolCall(registry, arena, .{ .id = "e", .name = "mcp_mini_browser_eval", .arguments_json = "{}" }, .{
        .server = &server_name,
        .tool = &tool_name,
        .title = &title,
    });
    try std.testing.expectEqualStrings("Evaluate JavaScript", titled.title);
    try std.testing.expect(!titled.meta.internal);
}

test "read titles say what they read while other tools keep their verb" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const registry = builtin_tools.registry;
    const read: ToolCall = .{
        .id = "read",
        .name = "read_tool_result",
        .arguments_json = "{\"request\":{\"handle\":\"fx-command-replay-0123.bin\",\"query\":\"error:\"}}",
        .resolved_display_target = "zig build test output for \"error:\"",
    };
    try std.testing.expectEqualStrings("Searching zig build test output for \"error:\"", describeToolCall(registry, arena, read, null).title);
    var unresolved = read;
    unresolved.resolved_display_target = null;
    try std.testing.expectEqualStrings("Searching command output", describeToolCall(registry, arena, unresolved, null).title);
    const file: ToolCall = .{ .id = "file", .name = "read_file", .arguments_json = "{\"path\":\"a.txt\"}" };
    try std.testing.expectEqualStrings("Reading", describeToolCall(registry, arena, file, null).title);
}

test "toolUpdateContentText clips long output and guards unsafe bytes" {
    const long = text_utils.repeat("x", 500);
    const clipped = toolUpdateContentText(false, long);
    try std.testing.expectEqual(@as(usize, 200), clipped.len);

    const unsafe = toolUpdateContentText(false, "ok\xFF\xFEbinary");
    try std.testing.expectEqualStrings("binary or non-utf8 tool output omitted", unsafe);

    const denied_json = "{\"error\":{\"type\":\"tool_permission_denied\",\"tool_name\":\"run_command\",\"message\":\"Permission denied by user\",\"reason\":\"user_denied\"}}";
    const denied = toolUpdateContentText(true, denied_json);
    try std.testing.expectEqualStrings(denied_json, denied);
}

test "run_code tool_call carries its body as JavaScript and its update lists each inner verb call" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const call = run_code_presentation.test_call;
    const presentation = describeToolCall(builtin_tools.registry, arena, call, null);
    var out: std.Io.Writer.Allocating = .init(arena);
    try acp_types.writeToolCallWithContent(&out.writer, call.id, acpToolName(call.name), presentation.title, mapToolKind(call.name), .pending, null, presentation.meta, try pendingContentText(arena, call));
    const pending = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.writer.buffered(), .{});
    try std.testing.expectEqualStrings("execute", pending.object.get("kind").?.string);
    try std.testing.expectEqualStrings("run_code const a = await gm.read_file({path:'a.txt'});", pending.object.get("title").?.string);
    const content = pending.object.get("content").?.array.items[0].object.get("content").?.object;
    try std.testing.expectEqualStrings("```js\n  const a = await gm.read_file({path:'a.txt'});\nreturn 3;\n```", content.get("text").?.string);
    const update_text = try resultContentText(arena, builtin_tools.registry, call, run_code_presentation.test_output);
    try std.testing.expectEqualStrings(run_code_presentation.test_detail, update_text orelse return error.TestExpectedRunCodeContent);
    try std.testing.expect(try pendingContentText(arena, .{ .id = "r", .name = "read_file", .arguments_json = "{}" }) == null);
}

fn expectShellUpdateContent(expected: ?[]const u8, tool_name: []const u8, output: []const u8) !void {
    const actual = try shellUpdateContentText(std.testing.allocator, tool_name, output);
    defer if (actual) |text| std.testing.allocator.free(text);
    if (expected) |text| {
        try std.testing.expectEqualStrings(text, actual orelse return error.TestExpectedShellContent);
    } else {
        try std.testing.expect(actual == null);
    }
}

test "shell update content shows the command output instead of the result JSON" {
    try expectShellUpdateContent(
        "hello-42\n",
        "Bash",
        "{\"session_id\":null,\"state\":\"completed\",\"output_truncated\":false,\"full_output_handle\":\"fx-command-replay-1.bin\",\"exit_code\":0,\"error\":null,\"output_delta\":\"hello-42\\n\"}",
    );
    try expectShellUpdateContent(
        "",
        "Bash",
        "{\"state\":\"completed\",\"output_truncated\":false,\"exit_code\":4,\"output_delta\":\"\"}",
    );
    try expectShellUpdateContent(
        "shell snapshot unavailable (x); startup files run for every command\nhello\n",
        "Bash",
        "{\"state\":\"completed\",\"output_delta\":\"hello\\n\",\"notice\":\"shell snapshot unavailable (x); startup files run for every command\"}",
    );

    try expectShellUpdateContent(
        ",\"notice\":\"x\"",
        "Bash",
        "{\"state\":\"completed\",\"output_delta\":\",\\\"notice\\\":\\\"x\\\"\"}",
    );
}

test "shell update content keeps the preview bound and marks cut output" {
    const long = text_utils.repeat("x", 500);
    try expectShellUpdateContent(
        text_utils.repeat("x", 200) ++ "\n" ++ shell_output_cut_marker,
        "Bash",
        "{\"state\":\"completed\",\"output_truncated\":false,\"output_delta\":\"" ++ long ++ "\"}",
    );

    try expectShellUpdateContent(
        "tail\n" ++ shell_output_cut_marker,
        "Bash",
        "{\"state\":\"completed\",\"output_truncated\":true,\"output_delta\":\"tail\\n\"}",
    );
    try expectShellUpdateContent(
        "binary or non-utf8 tool output omitted",
        "Bash",
        "{\"state\":\"completed\",\"output_truncated\":true,\"output_delta\":\"ok\\u0000binary\"}",
    );
}

test "shell update content leaves other results to the generic preview" {
    const result = "{\"state\":\"completed\",\"output_delta\":\"hello\\n\"}";
    try expectShellUpdateContent(null, "read_file", result);
    try expectShellUpdateContent(null, "Bash", "{\"exit_code\":0}");
    try expectShellUpdateContent(
        null,
        "Bash",
        "{\"error\":{\"type\":\"tool_permission_denied\",\"tool_name\":\"Bash\",\"message\":\"Permission denied by user\"}}",
    );
    try expectShellUpdateContent(null, "Bash", "{\"state\":\"completed\",\"output_delta\":\"cut mid-str");
    try expectShellUpdateContent(null, "Bash", "shell result is unavailable");
}
