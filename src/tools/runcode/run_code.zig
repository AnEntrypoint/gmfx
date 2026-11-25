const std = @import("std");
const build_options = @import("build_options");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const model_tool_schema = @import("../../core/tooling/model_tool_schema.zig");
const runcode = @import("../../core/runcode/runcode.zig");
const tool_admission = @import("../../core/tooling/tool_admission.zig");
const message = @import("../../core/shared/message.zig");
const core_types = @import("../../core/shared/types.zig");
const permission_gate = @import("../../core/permissions/permission_gate.zig");
const command_admission = @import("../../core/permissions/command_admission.zig");
const host_verbs = @import("../../core/runcode/host_verbs.zig");
const host_verb_gate = @import("../../core/runcode/host_verb_gate.zig");
const managed_execution = @import("../../core/execution/managed_execution.zig");
const tool_mcp_registry = @import("../../core/tooling/tool_mcp_registry.zig");
const tool_mcp_runtime = @import("../../core/tooling/tool_mcp_runtime.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const call_ledger = @import("call_ledger.zig");
const result_store = @import("../../core/session/result_store.zig");
const parallel_execution = @import("../../core/agent/runtime/parallel_execution.zig");
const file_mutation = @import("../../core/tooling/file_mutation.zig");

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

const accepted_fields = blk: {
    var names: [properties.len][]const u8 = undefined;
    for (properties, &names) |property, *name| name.* = property.name;
    const final = names;
    break :blk final;
};

pub const batching_notice = "Three run_code bodies in a row each made one verb call; put a step's independent calls in one body, for example with Promise.all.";
const batching_threshold: usize = 3;

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
    if (tool_args.firstUnknownKey(parsed.value.object, &accepted_fields)) |unknown| {
        return .{ .failure = try tool_args.unknownArgumentMessage(ctx.allocator, tool_name, unknown, &accepted_fields) };
    }
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
    images: std.ArrayList(core_types.ToolImage) = .empty,
    command_result_json: ?[]u8 = null,
    committed_file_handoff: ?file_mutation.CommittedFileHandoff = null,
    inner_handoff_count: usize = 0,
    command_process_presentation: ?core_types.CommandProcessPresentation = null,
    denied: bool = false,

    fn keepCommandResult(self: *Bridge, ok: bool, json: ?[]const u8) !void {
        const failed_json = json orelse return;
        if (ok) return;
        const copy = try self.ctx.allocator.dupe(u8, failed_json);
        if (self.command_result_json) |previous| self.ctx.allocator.free(previous);
        self.command_result_json = copy;
    }

    fn keepCommittedFileHandoff(self: *Bridge, handoff: ?file_mutation.CommittedFileHandoff) void {
        const value = handoff orelse return;
        self.inner_handoff_count += 1;
        if (self.inner_handoff_count > 1) {
            if (self.committed_file_handoff) |previous| previous.deinit(self.ctx.allocator);
            self.committed_file_handoff = null;
            return;
        }
        self.committed_file_handoff = parallel_execution.duplicateCommittedFileHandoff(self.ctx.allocator, value) catch return;
    }

    fn keepCommandProcessPresentation(self: *Bridge, ok: bool, presentation: ?core_types.CommandProcessPresentation) void {
        if (ok) return;
        if (presentation) |value| self.command_process_presentation = value;
    }

    fn keepImages(self: *Bridge, images: []const core_types.ToolImage) !void {
        const copies = try core_types.dupeToolImages(self.ctx.allocator, images);
        defer self.ctx.allocator.free(copies);
        try self.images.appendSlice(self.ctx.allocator, copies);
    }
};

fn storeVerbOutput(context: *anyopaque, alloc: std.mem.Allocator, name: []const u8, text: []const u8) anyerror!?[]u8 {
    const bridge: *Bridge = @ptrCast(@alignCast(context));
    if (bridge.ctx.session_child_capability) |capability| {
        return try result_store.storeLargeResultManaged(alloc, capability, bridge.ctx.tool_call_id, name, text);
    }
    const dir = bridge.ctx.tool_result_dir orelse return null;
    return try result_store.storeLargeResult(alloc, dir, bridge.ctx.tool_call_id, name, text);
}

fn invokeVerb(context: *anyopaque, alloc: std.mem.Allocator, name: []const u8, args_json: []const u8) anyerror![]u8 {
    return (try invokeCountedVerb(context, alloc, name, args_json)).reply;
}

fn invokeCountedVerb(context: *anyopaque, alloc: std.mem.Allocator, name: []const u8, args_json: []const u8) anyerror!call_ledger.Invoked {
    const bridge: *Bridge = @ptrCast(@alignCast(context));
    bridge.calls += 1;
    var verb_arena = std.heap.ArenaAllocator.init(alloc);
    defer verb_arena.deinit();
    const verb_alloc = verb_arena.allocator();
    const parent_id = if (bridge.ctx.tool_call_id.len == 0) tool_name else bridge.ctx.tool_call_id;
    const id = try std.fmt.allocPrint(verb_alloc, "{s}:{d}", .{ parent_id, bridge.calls });
    var ctx = bridge.ctx;
    ctx.allocator = verb_alloc;
    ctx.command_outcome = .{ .context = bridge, .outcome = commandOutcome };
    ctx.tool_call_id = id;
    ctx.tool_call_name = name;
    const host = host_verbs.isHostVerb(name);
    const mcp = !host and bridge.registry.lookup(name) == null and ctx.mcp_ctx != null and ctx.mcp_call_tool != null;
    const admitted = if (host) hostVerbAdmitted(ctx, name) else mcp or toolAdmitted(ctx, name);
    if (!admitted) return .{ .reply = try notAdmittedReply(alloc, name) };
    const proposed: message.ToolCall = .{ .id = id, .name = name, .arguments_json = args_json };
    const gate = ctx.inner_call_gate orelse return .{ .reply = try ungatedReply(bridge, ctx, alloc, proposed, host, mcp) };
    const verb_call: message.ToolCall = switch (try gate.start_fn(gate.context, verb_alloc, proposed)) {
        .refuse => |reason| return .{ .reply = try verbReply(alloc, false, reason) },
        .proceed => |arguments_json| .{ .id = id, .name = name, .arguments_json = arguments_json },
    };
    const reply = if (host) try hostVerbReply(ctx, bridge.registry, verb_call) else try gate.run_fn(gate.context, verb_alloc, verb_call);
    try bridge.keepImages(reply.images);
    try bridge.keepCommandResult(reply.ok, reply.command_result_json);
    bridge.keepCommandProcessPresentation(reply.ok, reply.command_process_presentation);
    bridge.keepCommittedFileHandoff(reply.committed_file_handoff);
    bridge.denied = bridge.denied or reply.denied;
    gate.finish_fn(gate.context, verb_alloc, verb_call, reply);
    const reply_text = if (host) try alloc.dupe(u8, reply.body) else if (reply.deferred) try deferredVerbReply(alloc, reply.body) else try verbReply(alloc, reply.ok, reply.body);
    errdefer alloc.free(reply_text);
    return .{
        .reply = reply_text,
        .additions = reply.additions,
        .deletions = reply.deletions,
        .output = if (reply.output_handle == null) try alloc.dupe(u8, reply.body) else null,
        .output_handle = if (reply.output_handle) |handle| try alloc.dupe(u8, handle) else null,
        .output_bytes = reply.output_bytes,
        .notice_pushed = reply.notice_pushed,
    };
}

fn ungatedReply(
    bridge: *Bridge,
    base: tool_dispatch.DispatchContext,
    alloc: std.mem.Allocator,
    verb_call: message.ToolCall,
    host: bool,
    mcp: bool,
) ![]u8 {
    if (host) return alloc.dupe(u8, (try hostVerbReply(base, bridge.registry, verb_call)).body);
    if (!mcp) {
        const result = try tool_dispatch.dispatchToolCall(base, bridge.registry, verb_call);
        try bridge.keepImages(result.images);
        try bridge.keepCommandResult(result.status == .success, result.command_result_json);
        return verbReply(alloc, result.status == .success, result.body);
    }
    var ctx = base;
    ctx.mcp_call_options.call_id = verb_call.id;
    ctx.mcp_call_options.expected_binding = null;
    ctx.mcp_call_options.expected_runtime_generation = null;
    ctx.mcp_execution_error_sink = null;
    ctx.mcp_call_status_sink = null;
    const mcp_tool = [_]tool_dispatch.Tool{tool_mcp_registry.dynamicTool(verb_call.name)};
    const result = try tool_dispatch.dispatchToolCall(ctx, .{ .tools = &mcp_tool }, verb_call);
    return verbReply(alloc, result.status == .success, result.body);
}

fn hostVerbReply(ctx: tool_dispatch.DispatchContext, registry: tool_dispatch.Registry, verb_call: message.ToolCall) !tool_dispatch.InnerCallReply {
    if (try host_verb_gate.refusal(ctx, registry, ctx.allocator, verb_call.name, verb_call.arguments_json)) |denied| return .{ .ok = false, .body = denied };
    const body = try host_verbs.call(ctx.allocator, verb_call.name, verb_call.arguments_json);
    return .{ .ok = std.mem.startsWith(u8, body, "{\"ok\":true"), .body = body };
}

fn batchingNotice(single_verb_bodies: ?*usize, calls: usize) ?[]const u8 {
    const streak = single_verb_bodies orelse return null;
    streak.* = if (calls == 1) streak.* + 1 else 0;
    return if (streak.* >= batching_threshold) batching_notice else null;
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

fn deferredVerbReply(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"ok\":false,\"deferred\":true,\"error\":");
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

fn bodyNeedsMcpCatalog(body: []const u8) bool {
    return std.mem.find(u8, body, "mcp__") != null or std.mem.find(u8, body, "verbs") != null;
}

fn verbReachable(tool: tool_dispatch.Tool) bool {
    return tool.model_visible or switch (tool.executor_kind) {
        .create_goal, .get_goal, .set_goal_budget, .update_goal => true,
        else => false,
    };
}

fn buildCatalog(alloc: std.mem.Allocator, ctx: tool_dispatch.DispatchContext, registry: tool_dispatch.Registry, with_mcp: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeByte('[');
    var first = true;
    for (registry.tools) |tool| {
        if (std.mem.eql(u8, tool.name, tool_name) or !verbReachable(tool) or !toolAdmitted(ctx, tool.name)) continue;
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
    const listed = if (with_mcp) try mcpTools(listing.allocator(), ctx) else &[_]tool_mcp_runtime.ListedTool{};
    for (listed) |tool| {
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
    const catalog = try buildCatalog(alloc, ctx, registry, true);
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
    const catalog = buildCatalog(ctx.allocator, ctx, registry, bodyNeedsMcpCatalog(input.body)) catch return .{ .failure = try ctx.allocator.dupe(u8, "run_code could not list its verbs") };
    defer ctx.allocator.free(catalog);
    var bridge: Bridge = .{ .ctx = ctx, .registry = registry };
    var ledger = call_ledger.Ledger.init(ctx.allocator, &bridge, invokeCountedVerb, .{ .context = &bridge, .write = storeVerbOutput });
    defer ledger.deinit();
    const outcome = runcode.execute(ctx.allocator, input.body, .{
        .format = input.format,
        .deadline_ms = input.deadline_ms,
        .root = ctx.workspace_root,
        .verbs = .{ .context = &ledger, .catalog = catalog, .invoke = call_ledger.Ledger.invoke },
    }) catch return .{ .failure = try ctx.allocator.dupe(u8, "run_code could not start the txiki runtime") };
    defer outcome.deinit(ctx.allocator);
    const base = runcode.reportJson(ctx.allocator, outcome, batchingNotice(ctx.single_verb_bodies, bridge.calls)) catch return .{ .failure = try ctx.allocator.dupe(u8, "run_code could not format its result") };
    const report = ledger.report(ctx.allocator, base) catch return .{ .failure = try ctx.allocator.dupe(u8, "run_code could not format its result") };
    if (bridge.command_result_json) |json| tool_dispatch.reportCommandResultJson(ctx, json);
    if (bridge.committed_file_handoff) |handoff| tool_dispatch.reportCommittedFileHandoff(ctx, handoff);
    if (bridge.command_process_presentation) |presentation| tool_dispatch.reportToolResultMemory(ctx, .{ .command_process_presentation = presentation });
    if (bridge.denied) tool_dispatch.reportPermissionDenied(ctx);
    const succeeded = outcome.ok and bridge.command_result_json == null and !bridge.denied;
    if (bridge.images.items.len > 0) return .{ .rich = .{
        .text = report,
        .images = bridge.images.toOwnedSlice(ctx.allocator) catch return .{ .failure = try ctx.allocator.dupe(u8, "run_code could not attach its images") },
        .is_error = !succeeded,
    } };
    if (succeeded) return .{ .success = report };
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
    const catalog = try buildCatalog(alloc, ctx, builtin_tools.registry_with_tower, true);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"glob_files\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"process_info\"") != null);
    for ([_][]const u8{ "\"name\":\"read_file\"", "\"name\":\"fs_read\"", "\"name\":\"Bash\"", "\"name\":\"run_command\"" }) |absent| {
        try std.testing.expect(std.mem.indexOf(u8, catalog, absent) == null);
    }
}

test "every model-visible builtin is a verb of the catalog, vision and Agent included" {
    const builtin_tools = @import("../../builtins/tools.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const ctx: tool_dispatch.DispatchContext = .{
        .allocator = alloc,
        .execution_authority = .ordinary,
        .workspace_root = ".",
        .permission_mode = .yolo,
    };
    const catalog = try buildCatalog(alloc, ctx, builtin_tools.registry_with_tower, false);
    for (builtin_tools.advertisement_set.order) |name| {
        if (std.mem.eql(u8, name, tool_name)) continue;
        const tool = builtin_tools.registry_with_tower.lookup(name) orelse continue;
        if (!tool.model_visible) continue;
        const needle = try std.fmt.allocPrint(alloc, "\"name\":\"{s}\"", .{name});
        try std.testing.expect(std.mem.indexOf(u8, catalog, needle) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"vision\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"Agent\"") != null);
}

test "run_code refuses an argument it does not take by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decoded = try decode(.{ .allocator = arena.allocator() }, "{\"body\":\"return 1;\",\"timeout\":5}");
    switch (decoded) {
        .failure => |reason| try std.testing.expectEqualStrings("run_code does not take argument \"timeout\"; accepted fields: body, format, deadline_ms", reason),
        .input => return error.TestExpectedDecodeFailure,
    }
}

const RecordingGate = struct {
    alloc: std.mem.Allocator,
    images: []const core_types.ToolImage = &.{},
    ok: bool = true,
    command_result_json: ?[]const u8 = null,
    denied: bool = false,
    ids: std.ArrayList([]const u8) = .empty,

    fn gate(self: *RecordingGate) tool_dispatch.InnerCallGate {
        return .{ .context = self, .start_fn = start, .authorize_fn = authorize, .run_fn = run, .finish_fn = finish };
    }

    fn start(raw: *anyopaque, _: std.mem.Allocator, verb_call: message.ToolCall) anyerror!tool_dispatch.InnerCallStart {
        const self: *RecordingGate = @ptrCast(@alignCast(raw));
        try self.ids.append(self.alloc, try self.alloc.dupe(u8, verb_call.id));
        return .{ .proceed = verb_call.arguments_json };
    }

    fn authorize(_: *anyopaque, _: std.mem.Allocator, _: message.ToolCall) anyerror!?[]const u8 {
        return null;
    }

    fn run(raw: *anyopaque, _: std.mem.Allocator, _: message.ToolCall) anyerror!tool_dispatch.InnerCallReply {
        const self: *RecordingGate = @ptrCast(@alignCast(raw));
        return .{ .ok = self.ok, .body = "done", .images = self.images, .command_result_json = self.command_result_json, .denied = self.denied };
    }

    fn finish(_: *anyopaque, _: std.mem.Allocator, _: message.ToolCall, _: tool_dispatch.InnerCallReply) void {}
};

test "inner call ids carry the parent call id, so two bodies never repeat one" {
    const builtin_tools = @import("../../builtins/tools.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var recorder = RecordingGate{ .alloc = alloc };
    for ([_][]const u8{ "call-a", "call-b" }) |parent| {
        const ctx: tool_dispatch.DispatchContext = .{
            .allocator = alloc,
            .execution_authority = .ordinary,
            .workspace_root = ".",
            .permission_mode = .yolo,
            .tool_call_id = parent,
            .inner_call_gate = recorder.gate(),
        };
        const result = try tool_dispatch.dispatchToolCall(ctx, builtin_tools.registry_with_tower, .{
            .id = parent,
            .name = "run_code",
            .arguments_json = "{\"body\":\"gm.glob_files({ pattern: 'a' }); gm.glob_files({ pattern: 'b' }); return 1;\"}",
        });
        if (result.status != .success) return error.RunCodeDidNotSucceed;
    }
    try std.testing.expectEqual(@as(usize, 4), recorder.ids.items.len);
    const expected = [_][]const u8{ "call-a:1", "call-a:2", "call-b:1", "call-b:2" };
    for (expected, recorder.ids.items) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "an image an inner verb returns reaches the run_code result's attachments" {
    const builtin_tools = @import("../../builtins/tools.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var data = [_]u8{ 1, 2, 3 };
    var mime = "image/png".*;
    const images = [_]core_types.ToolImage{.{ .data = &data, .mime_type = &mime }};
    var recorder = RecordingGate{ .alloc = alloc, .images = &images };
    const ctx: tool_dispatch.DispatchContext = .{
        .allocator = alloc,
        .execution_authority = .ordinary,
        .workspace_root = ".",
        .permission_mode = .yolo,
        .tool_call_id = "call-image",
        .inner_call_gate = recorder.gate(),
    };
    const result = try tool_dispatch.dispatchToolCall(ctx, builtin_tools.registry_with_tower, .{
        .id = "call-image",
        .name = "run_code",
        .arguments_json = "{\"body\":\"gm.glob_files({ pattern: 'a' }); gm.glob_files({ pattern: 'b' }); return 1;\"}",
    });
    try std.testing.expectEqual(tool_dispatch.DispatchResult.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 2), result.images.len);
    try std.testing.expectEqualSlices(u8, &data, result.images[0].data);
    try std.testing.expectEqualStrings("image/png", result.images[1].mime_type);
}

test "a failed inner command's result json reaches the run_code result and fails it" {
    const builtin_tools = @import("../../builtins/tools.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const json = "{\"termination_indeterminate\":true}";
    var recorder = RecordingGate{ .alloc = alloc, .ok = false, .command_result_json = json };
    var captured: ?[]const u8 = null;
    const ctx: tool_dispatch.DispatchContext = .{
        .allocator = alloc,
        .execution_authority = .ordinary,
        .workspace_root = ".",
        .permission_mode = .yolo,
        .tool_call_id = "call-command",
        .inner_call_gate = recorder.gate(),
        .command_result_json_sink = &captured,
    };
    const result = try tool_dispatch.dispatchToolCall(ctx, builtin_tools.registry_with_tower, .{
        .id = "call-command",
        .name = "run_code",
        .arguments_json = "{\"body\":\"return gm.glob_files({ pattern: 'a' });\"}",
    });
    try std.testing.expectEqual(tool_dispatch.DispatchResult.Status.failure, result.status);
    try std.testing.expectEqualStrings(json, result.command_result_json.?);
    try std.testing.expectEqualStrings(json, captured.?);
}

test "a denied inner call reports the permission denial and fails the run_code result" {
    const builtin_tools = @import("../../builtins/tools.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var recorder = RecordingGate{ .alloc = alloc, .ok = false, .denied = true };
    var denied = false;
    const ctx: tool_dispatch.DispatchContext = .{
        .allocator = alloc,
        .execution_authority = .ordinary,
        .workspace_root = ".",
        .permission_mode = .yolo,
        .tool_call_id = "call-denied",
        .inner_call_gate = recorder.gate(),
        .permission_denied_sink = &denied,
    };
    const result = try tool_dispatch.dispatchToolCall(ctx, builtin_tools.registry_with_tower, .{
        .id = "call-denied",
        .name = "run_code",
        .arguments_json = "{\"body\":\"try { gm.glob_files({ pattern: 'a' }); } catch (error) {} return 1;\"}",
    });
    try std.testing.expectEqual(tool_dispatch.DispatchResult.Status.failure, result.status);
    try std.testing.expect(denied);
}

test "an inner call that succeeds leaves the run_code result without command json" {
    const builtin_tools = @import("../../builtins/tools.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var recorder = RecordingGate{ .alloc = alloc, .command_result_json = "{\"exit_code\":0}" };
    const ctx: tool_dispatch.DispatchContext = .{
        .allocator = alloc,
        .execution_authority = .ordinary,
        .workspace_root = ".",
        .permission_mode = .yolo,
        .tool_call_id = "call-ok",
        .inner_call_gate = recorder.gate(),
    };
    const result = try tool_dispatch.dispatchToolCall(ctx, builtin_tools.registry_with_tower, .{
        .id = "call-ok",
        .name = "run_code",
        .arguments_json = "{\"body\":\"return gm.glob_files({ pattern: 'a' });\"}",
    });
    try std.testing.expectEqual(tool_dispatch.DispatchResult.Status.success, result.status);
    try std.testing.expect(result.command_result_json == null);
}

test "the batching notice follows the third consecutive single-verb body and not the second" {
    const builtin_tools = @import("../../builtins/tools.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var single_verb_bodies: usize = 0;
    const ctx: tool_dispatch.DispatchContext = .{
        .allocator = arena.allocator(),
        .execution_authority = .ordinary,
        .workspace_root = ".",
        .permission_mode = .yolo,
        .single_verb_bodies = &single_verb_bodies,
    };
    for (0..3) |index| {
        const result = try tool_dispatch.dispatchToolCall(ctx, builtin_tools.registry_with_tower, .{
            .id = "single-verb",
            .name = "run_code",
            .arguments_json = "{\"body\":\"gm.process_info({}); return 1;\"}",
        });
        if (result.status != .success) return error.RunCodeDidNotSucceed;
        try std.testing.expectEqual(index == 2, std.mem.indexOf(u8, result.body, batching_notice) != null);
    }
}

test "an error thrown while loading a required file names the file and its line" {
    const builtin_tools = @import("../../builtins/tools.zig");
    const io_mod = @import("../../core/shared/io.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "broken.cjs", .data = "const a = 1;\nconst b = 2;\nthrow new Error('boom');\n" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try io_mod.dirRealpathAlloc(arena.allocator(), tmp.dir, ".");
    const ctx: tool_dispatch.DispatchContext = .{
        .allocator = arena.allocator(),
        .execution_authority = .ordinary,
        .workspace_root = root,
        .permission_mode = .yolo,
    };
    const result = try tool_dispatch.dispatchToolCall(ctx, builtin_tools.registry_with_tower, .{
        .id = "load-error",
        .name = "run_code",
        .arguments_json = "{\"body\":\"return require('./broken.cjs');\"}",
    });
    try std.testing.expectEqual(tool_dispatch.DispatchResult.Status.failure, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "broken.cjs:3: boom") != null);
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
    const catalog = try buildCatalog(arena.allocator(), ctx, .{ .tools = &.{} }, true);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "{\"name\":\"mcp__fake__echo\",\"description\":\"Echo text.\",\"kind\":\"mcp\",\"input_schema\":{\"type\":\"object\"}}") != null);
    const without_mcp = try buildCatalog(arena.allocator(), .{ .allocator = arena.allocator() }, .{ .tools = &.{} }, true);
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
