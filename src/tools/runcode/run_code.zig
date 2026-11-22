const std = @import("std");
const build_options = @import("build_options");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const model_tool_schema = @import("../../core/tooling/model_tool_schema.zig");
const runcode = @import("../../core/runcode/runcode.zig");
const tool_admission = @import("../../core/tooling/tool_admission.zig");
const message = @import("../../core/shared/message.zig");
const permission_gate = @import("../../core/permissions/permission_gate.zig");
const command_admission = @import("../../core/permissions/command_admission.zig");
const host_verbs = @import("../../core/runcode/host_verbs.zig");
const host_verb_gate = @import("../../core/runcode/host_verb_gate.zig");
const managed_execution = @import("../../core/execution/managed_execution.zig");
const tool_mcp_registry = @import("../../core/tooling/tool_mcp_registry.zig");
const tool_mcp_runtime = @import("../../core/tooling/tool_mcp_runtime.zig");

pub const tool_name = "run_code";

pub const not_admitted_code = "EFX_TOOL_NOT_ADMITTED";

const description_head = "Run a JavaScript function body and return its value. gm.<verb>(args) calls a verb, gm.verbs({names:true}) lists names, gm.verbs({name}) gives a description and input schema. MCP tools are verbs named mcp__<server>__<tool>. Verbs: ";

pub fn describe(comptime tools: []const tool_dispatch.Tool) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var text: []const u8 = description_head;
        var first = true;
        for (tools) |tool| {
            if (std.mem.eql(u8, tool.name, tool_name)) continue;
            text = text ++ (if (first) "" else ",") ++ tool.name;
            first = false;
        }
        for (host_verbs.names) |name| text = text ++ "," ++ name;
        const final = text ++ ".";
        if (final.len > model_tool_schema.description_max_bytes) @compileError("the run_code description must fit the model description cap");
        return final;
    }
}

pub const properties = [_]model_tool_schema.Property{
    .{ .name = "body", .json_type = .string, .description = "Function body; the value it returns is the result." },
    .{ .name = "format", .json_type = .string, .description = "cjs (default) or esm, which allows import statements at the top." },
    .{ .name = "deadline_ms", .json_type = .integer, .description = "Wall-clock budget for the whole body, verb calls included. Default 120000." },
};

const max_deadline_ms: u64 = 3_600_000;

const Input = struct {
    alloc: std.mem.Allocator,
    body: []u8,
    format: runcode.Format,
    deadline_ms: u64,

    fn deinit(self: *Input) void {
        self.alloc.free(self.body);
        self.alloc.destroy(self);
    }
};

fn inputDeinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
    _ = alloc;
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit();
}

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "run_code arguments must be valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .failure = try ctx.allocator.dupe(u8, "run_code arguments must be an object") };
    const body_value = parsed.value.object.get("body") orelse return .{ .failure = try ctx.allocator.dupe(u8, "run_code field \"body\" is required") };
    if (body_value != .string) return .{ .failure = try ctx.allocator.dupe(u8, "run_code field \"body\" must be a string") };
    const format: runcode.Format = if (parsed.value.object.get("format")) |value| switch (value) {
        .string => |text| if (std.mem.eql(u8, text, "esm")) .esm else if (std.mem.eql(u8, text, "cjs")) .cjs else return .{ .failure = try ctx.allocator.dupe(u8, "run_code field \"format\" must be cjs or esm") },
        else => return .{ .failure = try ctx.allocator.dupe(u8, "run_code field \"format\" must be a string") },
    } else .cjs;
    const deadline_ms: u64 = if (parsed.value.object.get("deadline_ms")) |value| switch (value) {
        .integer => |ms| if (ms >= 1 and ms <= max_deadline_ms) @intCast(ms) else return .{ .failure = try ctx.allocator.dupe(u8, "run_code field \"deadline_ms\" must be between 1 and 3600000") },
        else => return .{ .failure = try ctx.allocator.dupe(u8, "run_code field \"deadline_ms\" must be an integer") },
    } else runcode.default_deadline_ms;

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{
        .alloc = ctx.allocator,
        .body = try ctx.allocator.dupe(u8, body_value.string),
        .format = format,
        .deadline_ms = deadline_ms,
    };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn irreversible(_: tool_dispatch.ToolInput) bool {
    return true;
}

const Bridge = struct {
    ctx: tool_dispatch.DispatchContext,
    registry: tool_dispatch.Registry,
    calls: usize = 0,
};

fn invokeVerb(context: *anyopaque, alloc: std.mem.Allocator, name: []const u8, args_json: []const u8) anyerror![]u8 {
    const bridge: *Bridge = @ptrCast(@alignCast(context));
    bridge.calls += 1;
    var verb_arena = std.heap.ArenaAllocator.init(alloc);
    defer verb_arena.deinit();
    const verb_alloc = verb_arena.allocator();
    const id = try std.fmt.allocPrint(verb_alloc, "run_code:{d}", .{bridge.calls});
    var ctx = bridge.ctx;
    ctx.allocator = verb_alloc;
    ctx.command_outcome = .{ .context = bridge, .outcome = commandOutcome };
    ctx.tool_call_id = id;
    ctx.tool_call_name = name;
    if (host_verbs.isHostVerb(name)) {
        if (!hostVerbAdmitted(ctx, name)) return notAdmittedReply(alloc, name);
        if (try host_verb_gate.refusal(ctx, bridge.registry, alloc, name, args_json)) |denied| return denied;
        return host_verbs.call(alloc, name, args_json);
    }
    const tool_call: message.ToolCall = .{ .id = id, .name = name, .arguments_json = args_json };
    if (bridge.registry.lookup(name) == null and ctx.mcp_ctx != null and ctx.mcp_call_tool != null) {
        ctx.mcp_call_options.call_id = id;
        ctx.mcp_call_options.expected_binding = null;
        ctx.mcp_call_options.expected_runtime_generation = null;
        ctx.mcp_execution_error_sink = null;
        ctx.mcp_call_status_sink = null;
        const mcp_tool = [_]tool_dispatch.Tool{tool_mcp_registry.dynamicTool(name)};
        const result = try tool_dispatch.dispatchToolCall(ctx, .{ .tools = &mcp_tool }, tool_call);
        return verbReply(alloc, result.status == .success, result.body);
    }
    if (!toolAdmitted(ctx, name)) return notAdmittedReply(alloc, name);
    const result = try tool_dispatch.dispatchToolCall(ctx, bridge.registry, tool_call);
    return verbReply(alloc, result.status == .success, result.body);
}

fn toolAdmitted(ctx: tool_dispatch.DispatchContext, name: []const u8) bool {
    const allowed = ctx.admitted_tool_names orelse return true;
    for (allowed) |entry| if (std.mem.eql(u8, entry, name)) return true;
    return false;
}

fn hostVerbAdmitted(ctx: tool_dispatch.DispatchContext, verb: []const u8) bool {
    const row = host_verb_gate.rowFor(verb) orelse return false;
    const gate_tool = host_verb_gate.toolNameFor(row.class) orelse return true;
    return toolAdmitted(ctx, gate_tool);
}

fn notAdmittedReply(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    const text = try std.fmt.allocPrint(alloc, "{s}: {s} is not in this agent's allowed tools", .{ not_admitted_code, name });
    defer alloc.free(text);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"ok\":false,\"code\":\"" ++ not_admitted_code ++ "\",\"error\":");
    try std.json.Stringify.value(text, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn commandOutcome(
    context: *anyopaque,
    arena: std.mem.Allocator,
    tool_call: message.ToolCall,
    permission_mode: permission_gate.PermissionMode,
) anyerror!command_admission.PermissionOutcome {
    const bridge: *Bridge = @ptrCast(@alignCast(context));
    return tool_admission.commandPermissionOutcome(.{
        .workspace_root = bridge.ctx.workspace_root,
        .tool_registry = bridge.registry,
    }, arena, tool_call, permission_mode);
}

fn verbReply(alloc: std.mem.Allocator, ok: bool, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (ok) {
        try out.writer.writeAll("{\"ok\":true,\"text\":");
    } else {
        try out.writer.writeAll("{\"ok\":false,\"error\":");
    }
    try std.json.Stringify.value(text, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn openCatalogEntry(writer: *std.Io.Writer, first: *bool, name: []const u8, description_text: []const u8, kind: []const u8) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try writer.writeAll("{\"name\":");
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(description_text, .{}, writer);
    try writer.writeAll(",\"kind\":\"");
    try writer.writeAll(kind);
    try writer.writeAll("\",\"input_schema\":");
}

fn buildCatalog(alloc: std.mem.Allocator, ctx: tool_dispatch.DispatchContext, registry: tool_dispatch.Registry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('[');
    var first = true;
    for (registry.tools) |tool| {
        if (std.mem.eql(u8, tool.name, tool_name) or !toolAdmitted(ctx, tool.name)) continue;
        try openCatalogEntry(&out.writer, &first, tool.name, tool.description, "tool");
        try model_tool_schema.writeObjectSchema(alloc, &out.writer, tool.model_schema.input_schema);
        try out.writer.writeByte('}');
    }
    for (host_verbs.verbs) |verb| {
        if (!hostVerbAdmitted(ctx, verb.name)) continue;
        try openCatalogEntry(&out.writer, &first, verb.name, verb.description, "host");
        try model_tool_schema.writeObjectSchema(alloc, &out.writer, verb.input_schema);
        try out.writer.writeByte('}');
    }
    var listing = std.heap.ArenaAllocator.init(alloc);
    defer listing.deinit();
    for (try mcpTools(listing.allocator(), ctx)) |tool| {
        try openCatalogEntry(&out.writer, &first, tool.name, tool.description, "mcp");
        try out.writer.writeAll(if (tool.input_schema_json.len == 0) "{}" else tool.input_schema_json);
        try out.writer.writeByte('}');
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

fn mcpTools(alloc: std.mem.Allocator, ctx: tool_dispatch.DispatchContext) ![]const tool_mcp_runtime.ListedTool {
    const runtime_context = ctx.mcp_ctx orelse return &.{};
    const list = ctx.mcp_list_tools orelse return &.{};
    return list(runtime_context, alloc, ctx.mcp_permission_rules, ctx.mcp_access, ctx.cancel_flag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
}

pub fn isCliToken(token: []const u8) bool {
    return std.mem.eql(u8, token, "run-code") or std.mem.eql(u8, token, "js");
}

test "run-code and its js alias are the two command tokens" {
    try std.testing.expect(isCliToken("run-code"));
    try std.testing.expect(isCliToken("js"));
    try std.testing.expect(!isCliToken("json"));
}

pub fn runCli(alloc: std.mem.Allocator, args: []const []const u8, ctx_base: tool_dispatch.DispatchContext, registry: tool_dispatch.Registry) !u8 {
    var ctx = ctx_base;
    var forwarded: std.ArrayList([]const u8) = .empty;
    defer forwarded.deinit(alloc);
    var edge_engine = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--engine") and index + 1 < args.len) {
            index += 1;
            edge_engine = std.mem.eql(u8, args[index], "edge");
            if (!edge_engine and !std.mem.eql(u8, args[index], "txiki")) return error.UsageRunCode;
            continue;
        }
        if (std.mem.eql(u8, args[index], "--permission-mode") and index + 1 < args.len) {
            index += 1;
            ctx.permission_mode = std.meta.stringToEnum(@TypeOf(ctx.permission_mode), args[index]) orelse return error.UsageRunCode;
            continue;
        }
        try forwarded.append(alloc, args[index]);
    }
    var managed = managed_execution.Runtime.init(alloc);
    defer managed.deinit();
    ctx.managed_executions = &managed;
    const catalog = try buildCatalog(alloc, ctx, registry);
    defer alloc.free(catalog);
    var bridge: Bridge = .{ .ctx = ctx, .registry = registry };
    const verbs: runcode.Verbs = .{ .context = &bridge, .catalog = catalog, .invoke = invokeVerb };
    if (edge_engine) {
        if (comptime build_options.edgejs) return @import("../../core/runcode/edge.zig").runCommand(alloc, forwarded.items, verbs, ctx.permission_mode != .yolo);
        return error.UsageRunCode;
    }
    return runcode.runCommand(alloc, forwarded.items, verbs);
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput, registry: tool_dispatch.Registry) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const catalog = buildCatalog(ctx.allocator, ctx, registry) catch return .{ .failure = try ctx.allocator.dupe(u8, "run_code could not list its verbs") };
    defer ctx.allocator.free(catalog);
    var bridge: Bridge = .{ .ctx = ctx, .registry = registry };
    const outcome = runcode.execute(ctx.allocator, input.body, .{
        .format = input.format,
        .deadline_ms = input.deadline_ms,
        .root = ctx.workspace_root,
        .verbs = .{ .context = &bridge, .catalog = catalog, .invoke = invokeVerb },
    }) catch return .{ .failure = try ctx.allocator.dupe(u8, "run_code could not start the txiki runtime") };
    defer outcome.deinit(ctx.allocator);
    const report = runcode.reportJson(ctx.allocator, outcome) catch return .{ .failure = try ctx.allocator.dupe(u8, "run_code could not format its result") };
    if (outcome.ok) return .{ .success = report };
    return .{ .failure = report };
}

test "model-facing run_code call runs its body through the embedded runtime" {
    const builtin_tools = @import("../../builtins/tools.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: tool_dispatch.DispatchContext = .{
        .allocator = arena.allocator(),
        .execution_authority = .ordinary,
        .workspace_root = ".",
        .permission_mode = .yolo,
    };
    const result = try tool_dispatch.dispatchToolCall(ctx, builtin_tools.registry_with_tower, .{
        .id = "model-run-code-1",
        .name = "run_code",
        .arguments_json = "{\"body\":\"return 1 + 1;\"}",
    });
    if (result.status != .success) return error.RunCodeDidNotSucceed;
    const text = result.body;
    std.debug.print("MODEL_RUN_CODE {s}\n", .{text});
    try std.testing.expect(std.mem.indexOf(u8, text, "\"ok\":true") != null);
}

test "an esm body imports node built-ins by their Node names through the fx:host alias table" {
    const builtin_tools = @import("../../builtins/tools.zig");
    const host_module = @import("../../core/runcode/host_module.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const ctx: tool_dispatch.DispatchContext = .{
        .allocator = alloc,
        .execution_authority = .ordinary,
        .workspace_root = ".",
        .permission_mode = .yolo,
    };
    const body =
        \\import fs from 'node:fs';
        \\import { join } from 'path';
        \\import host from 'fx:host';
        \\const names = Object.keys(host.modules);
        \\const missing = [];
        \\for (const name of names) {
        \\  const node = await import('node:' + name);
        \\  if (node !== await import(name)) missing.push(name);
        \\  for (const key of Object.keys(node)) if (node[key] === undefined) missing.push(name + '.' + key);
        \\}
        \\let gap = '';
        \\try { await import('node:inspector'); } catch (error) { gap = error.message; }
        \\return { joined: join('a', 'b'), read: typeof fs.readFileSync, names: names.length, missing, gap, verbs: typeof host.verbs.fs_read };
    ;
    const arguments_json = try std.json.Stringify.valueAlloc(alloc, .{ .body = body, .format = "esm" }, .{});
    const result = try tool_dispatch.dispatchToolCall(ctx, builtin_tools.registry_with_tower, .{
        .id = "model-run-code-node-aliases",
        .name = "run_code",
        .arguments_json = arguments_json,
    });
    if (result.status != .success) return error.RunCodeDidNotSucceed;
    const provided = comptime blk: {
        var count: usize = 0;
        for (host_module.table) |row| count += @intFromBool(row.target != null);
        break :blk count;
    };
    const names = try std.fmt.allocPrint(alloc, "\"names\":{d},", .{provided});
    for ([_][]const u8{ "\"joined\":\"a/b\"", "\"read\":\"function\"", names, "\"missing\":[]", "'node:inspector' is not provided by fx:host yet", "\"verbs\":\"function\"" }) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, result.body, expected) != null);
    }
}

test "a verb outside the agent's allowed tools is refused by name before dispatch and left out of the catalog" {
    const builtin_tools = @import("../../builtins/tools.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const allowed = [_][]const u8{ "run_code", "glob_files" };
    const ctx: tool_dispatch.DispatchContext = .{
        .allocator = alloc,
        .execution_authority = .ordinary,
        .workspace_root = ".",
        .permission_mode = .yolo,
        .admitted_tool_names = &allowed,
    };
    var bridge: Bridge = .{ .ctx = ctx, .registry = builtin_tools.registry_with_tower };
    for ([_][]const u8{ "read_file", "fs_read" }) |verb| {
        const reply = try invokeVerb(&bridge, alloc, verb, "{\"path\":\"build.zig\"}");
        try std.testing.expect(std.mem.indexOf(u8, reply, not_admitted_code) != null);
    }
    const catalog = try buildCatalog(alloc, ctx, builtin_tools.registry_with_tower);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"glob_files\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"process_info\"") != null);
    for ([_][]const u8{ "\"name\":\"read_file\"", "\"name\":\"fs_read\"", "\"name\":\"Bash\"", "\"name\":\"run_command\"" }) |absent| {
        try std.testing.expect(std.mem.indexOf(u8, catalog, absent) == null);
    }
}

const FakeMcpListing = struct {
    const types = @import("../../core/shared/types.zig");

    fn list(_: *anyopaque, alloc: std.mem.Allocator, _: types.PermissionRuleSet, _: tool_mcp_runtime.Access, _: ?*std.atomic.Value(bool)) anyerror![]const tool_mcp_runtime.ListedTool {
        const tools = try alloc.alloc(tool_mcp_runtime.ListedTool, 1);
        tools[0] = .{ .name = "mcp__fake__echo", .description = "Echo text.", .input_schema_json = "{\"type\":\"object\"}" };
        return tools;
    }
};

test "the verb catalog lists each MCP tool of the session with its input schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runtime_marker: u8 = 0;
    const ctx: tool_dispatch.DispatchContext = .{
        .allocator = arena.allocator(),
        .mcp_ctx = &runtime_marker,
        .mcp_list_tools = FakeMcpListing.list,
    };
    const catalog = try buildCatalog(arena.allocator(), ctx, .{ .tools = &.{} });
    try std.testing.expect(std.mem.indexOf(u8, catalog, "{\"name\":\"mcp__fake__echo\",\"description\":\"Echo text.\",\"kind\":\"mcp\",\"input_schema\":{\"type\":\"object\"}}") != null);
    const without_mcp = try buildCatalog(arena.allocator(), .{ .allocator = arena.allocator() }, .{ .tools = &.{} });
    try std.testing.expect(std.mem.indexOf(u8, without_mcp, "mcp__fake__echo") == null);
}

test "verbs gives names alone, one verb's description and input schema, and refuses an unknown name" {
    const builtin_tools = @import("../../builtins/tools.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx: tool_dispatch.DispatchContext = .{
        .allocator = arena.allocator(),
        .execution_authority = .ordinary,
        .workspace_root = ".",
        .permission_mode = .yolo,
    };
    const body =
        \\const names = gm.verbs({ names: true });
        \\let unknown = '';
        \\try { gm.verbs({ name: 'no_such_verb' }); } catch (error) { unknown = error.message; }
        \\return [
        \\  gm.verbs({ name: 'read_file' }).input_schema.required.join('|'),
        \\  gm.verbs({ name: 'fs_read' }).description,
        \\  gm.verbs({ name: 'fs_read' }).input_schema.required.join('|'),
        \\  names.every((name) => typeof name === 'string') && names.includes('read_file') && names.includes('fs_read') && !names.includes('run_code'),
        \\  unknown,
        \\].join(';');
    ;
    const arguments_json = try std.json.Stringify.valueAlloc(arena.allocator(), .{ .body = body }, .{});
    const result = try tool_dispatch.dispatchToolCall(ctx, builtin_tools.registry_with_tower, .{
        .id = "model-run-code-verbs",
        .name = "run_code",
        .arguments_json = arguments_json,
    });
    if (result.status != .success) return error.RunCodeDidNotSucceed;
    try std.testing.expect(std.mem.indexOf(u8, result.body, "path;Read a whole file as base64.;path;true;unknown verb: no_such_verb") != null);
}
