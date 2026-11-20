const std = @import("std");
const engine = @import("engine.zig");
const foreground_call = @import("../../core/subagent/foreground_call.zig");
const foreground_text = @import("../../core/subagent/foreground_text.zig");
const model_contract = @import("../../core/subagent/model_contract.zig");
const profiles = @import("../../core/profiles/profiles.zig");
const result_schema = @import("../../core/subagent/result_schema.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_provider = @import("../../core/subagent/tool_provider.zig");

const Allocator = std.mem.Allocator;

pub const max_subagents = 128;
pub const max_stages: usize = 8;
pub const max_lenses: usize = 8;
pub const min_item_count: usize = 2;
pub const placeholder = "{{item}}";
const finding_placeholder = "{{finding}}";
const whitespace = " \t\r\n";

const invalid_arguments_message = "AgentSwarm arguments must be a JSON object";
const fork_disabled_message = "fork is disabled: the subagent_fork experimental flag is off.";
const too_few_items_message = "AgentSwarm requires at least 2 items unless resume_agent_ids is provided.";
const prompt_template_required_message = "prompt_template or stages is required when items are provided.";
const placeholder_missing_message = "prompt_template must include the {{item}} placeholder.";
const stage_placeholder_missing_message = "The first stage's prompt_template must include the {{item}} placeholder.";
const template_and_stages_message = "Pass prompt_template or stages, not both.";
const until_dry_needs_key_message = "until_dry needs dedup_key, so rounds can tell new results from ones already found.";
const until_dry_needs_items_message = "until_dry needs items: it repeats the fan-out over them.";
const verify_placeholder_missing_message = "verify.prompt_template must include the {{finding}} placeholder.";
const host_unavailable_message = "AgentSwarm did not start: no subagent host is available in this runtime.";

const swarm_fields = [_][]const u8{
    "description", "subagent_type", "prompt_template", "items",     "stages", "schema", "dedup_key",
    "max_results", "max_running",   "verify",          "until_dry", "critic", "fork",   "resume_agent_ids",
    "model",
};
const stage_fields = [_][]const u8{ "name", "prompt_template" };
const verify_fields = [_][]const u8{ "checkers", "lenses", "prompt_template" };
const until_dry_fields = [_][]const u8{"max_rounds"};

pub const Input = struct {
    arena_state: std.heap.ArenaAllocator,
    subagent_count: usize,
    config: engine.Config,
};

const Checked = union(enum) {
    config: engine.Config,
    failure: []const u8,
};

const FieldError = error{InvalidField};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            arena_state.deinit();
            return .{ .failure = try ctx.allocator.dupe(u8, invalid_arguments_message) };
        },
    };
    if (parsed != .object) {
        arena_state.deinit();
        return .{ .failure = try ctx.allocator.dupe(u8, invalid_arguments_message) };
    }
    switch (try check(arena, parsed.object)) {
        .failure => |message| {
            const owned = try ctx.allocator.dupe(u8, message);
            arena_state.deinit();
            return .{ .failure = owned };
        },
        .config => |config| {
            const input = try ctx.allocator.create(Input);
            input.* = .{
                .arena_state = arena_state,
                .subagent_count = config.items.len + config.resumed.len,
                .config = config,
            };
            return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
        },
    }
}

fn check(arena: Allocator, object: std.json.ObjectMap) Allocator.Error!Checked {
    if (unknownField(object, &swarm_fields)) |name| {
        return failFormat(arena, "AgentSwarm does not take \"{s}\".", .{name});
    }
    _ = (textField(object, "description") catch null) orelse return invalidField(arena, "description");
    const subagent_type = textField(object, "subagent_type") catch return invalidField(arena, "subagent_type");
    const model = textField(object, "model") catch return invalidField(arena, "model");
    const template = textField(object, "prompt_template") catch return invalidField(arena, "prompt_template");
    const dedup_key = textField(object, "dedup_key") catch return invalidField(arena, "dedup_key");
    const fork = boolField(object, "fork") catch return invalidField(arena, "fork");
    if (fork) return failText(arena, fork_disabled_message);
    const critic = boolField(object, "critic") catch
        return failText(arena, "AgentSwarm field \"critic\" must be true or false");

    const item_values: []const std.json.Value = switch (object.get("items") orelse .null) {
        .null => &.{},
        .array => |array| array.items,
        else => return invalidField(arena, "items"),
    };
    const items = try arena.alloc([]const u8, item_values.len);
    for (item_values, items) |item, *out| {
        if (item != .string) return invalidField(arena, "items");
        out.* = std.mem.trim(u8, item.string, whitespace);
        if (out.len == 0) return invalidField(arena, "items");
    }

    var resumed: std.ArrayList(engine.Resume) = .empty;
    switch (object.get("resume_agent_ids") orelse .null) {
        .null => {},
        .object => |map| {
            var iterator = map.iterator();
            while (iterator.next()) |entry| {
                const agent = std.mem.trim(u8, entry.key_ptr.*, whitespace);
                if (agent.len == 0) return invalidField(arena, "resume_agent_ids");
                if (entry.value_ptr.* != .string) return invalidField(arena, "resume_agent_ids");
                const prompt = std.mem.trim(u8, entry.value_ptr.string, whitespace);
                if (prompt.len == 0) return invalidField(arena, "resume_agent_ids");
                try resumed.append(arena, .{ .agent = agent, .prompt = prompt });
            }
        },
        else => return invalidField(arena, "resume_agent_ids"),
    }

    var stages: std.ArrayList(engine.Stage) = .empty;
    switch (object.get("stages") orelse .null) {
        .null => {},
        .array => |array| {
            if (template != null) return failText(arena, template_and_stages_message);
            if (array.items.len == 0 or array.items.len > max_stages) {
                return failFormat(arena, "AgentSwarm field \"stages\" must hold 1 to {d} stages", .{max_stages});
            }
            for (array.items, 0..) |stage, index| {
                if (stage != .object) return failFormat(arena, "AgentSwarm field \"stages[{d}]\" must be an object", .{index});
                if (unknownField(stage.object, &stage_fields)) |name| {
                    return failFormat(arena, "AgentSwarm field \"stages[{d}]\" does not take \"{s}\".", .{ index, name });
                }
                const name = (textField(stage.object, "name") catch null) orelse
                    return failFormat(arena, "AgentSwarm field \"stages[{d}].name\" must be a non-empty string", .{index});
                const stage_template = (textField(stage.object, "prompt_template") catch null) orelse
                    return failFormat(arena, "AgentSwarm field \"stages[{d}].prompt_template\" must be a non-empty string", .{index});
                try stages.append(arena, .{ .name = name, .prompt_template = stage_template });
            }
            if (std.mem.find(u8, stages.items[0].prompt_template, placeholder) == null) {
                return failText(arena, stage_placeholder_missing_message);
            }
        },
        else => return failFormat(arena, "AgentSwarm field \"stages\" must hold 1 to {d} stages", .{max_stages}),
    }

    if (resumed.items.len == 0 and items.len < min_item_count) return failText(arena, too_few_items_message);
    const total = items.len + resumed.items.len;
    if (total > max_subagents) return failFormat(arena, "AgentSwarm supports at most {d} subagents.", .{max_subagents});
    if (items.len > 0 and template == null and stages.items.len == 0) return failText(arena, prompt_template_required_message);
    if (template) |text| {
        if (std.mem.find(u8, text, placeholder) == null) return failText(arena, placeholder_missing_message);
        try stages.append(arena, .{ .name = "run", .prompt_template = text });
    }

    if (stages.items.len > 0) {
        var seen = std.StringHashMap(usize).init(arena);
        for (items, 0..) |item, index| {
            const prompt = try std.mem.replaceOwned(u8, arena, stages.items[0].prompt_template, placeholder, item);
            const entry = try seen.getOrPut(prompt);
            if (entry.found_existing) {
                return failFormat(
                    arena,
                    "Duplicate subagent prompts from items {d} and {d}. AgentSwarm requires distinct subagents.",
                    .{ entry.value_ptr.*, index + 1 },
                );
            }
            entry.value_ptr.* = index + 1;
        }
    }

    const schema: ?std.json.Value = switch (object.get("schema") orelse .null) {
        .null => null,
        else => |value| blk: {
            if (result_schema.schemaProblem(value)) |problem| {
                return failFormat(arena, "AgentSwarm field \"schema\" is not usable: {s}", .{problem});
            }
            break :blk value;
        },
    };

    const max_results = intField(object, "max_results", 1, engine.max_max_results, engine.default_max_results) catch
        return failFormat(arena, "AgentSwarm field \"max_results\" must be an integer from 1 to {d}", .{engine.max_max_results});
    const max_running = intField(object, "max_running", 1, engine.max_max_running, engine.default_max_running) catch
        return failFormat(arena, "AgentSwarm field \"max_running\" must be an integer from 1 to {d}", .{engine.max_max_running});

    var verify: ?engine.Verify = null;
    switch (object.get("verify") orelse .null) {
        .null => {},
        .object => |map| {
            if (unknownField(map, &verify_fields)) |name| {
                return failFormat(arena, "AgentSwarm field \"verify\" does not take \"{s}\".", .{name});
            }
            const checkers = intField(map, "checkers", engine.min_checkers, engine.max_checkers, engine.default_checkers) catch
                return failFormat(arena, "AgentSwarm field \"verify.checkers\" must be an integer from {d} to {d}", .{ engine.min_checkers, engine.max_checkers });
            const lens_values: []const std.json.Value = switch (map.get("lenses") orelse .null) {
                .null => &.{},
                .array => |array| array.items,
                else => return invalidField(arena, "verify.lenses"),
            };
            if (lens_values.len > max_lenses) {
                return failFormat(arena, "AgentSwarm field \"verify.lenses\" holds at most {d} lenses", .{max_lenses});
            }
            const lenses = try arena.alloc([]const u8, lens_values.len);
            for (lens_values, lenses) |lens, *out| {
                if (lens != .string) return invalidField(arena, "verify.lenses");
                out.* = std.mem.trim(u8, lens.string, whitespace);
                if (out.len == 0) return invalidField(arena, "verify.lenses");
            }
            const verify_template = textField(map, "prompt_template") catch return invalidField(arena, "verify.prompt_template");
            if (verify_template) |text| {
                if (std.mem.find(u8, text, finding_placeholder) == null) return failText(arena, verify_placeholder_missing_message);
            }
            verify = .{ .checkers = checkers, .lenses = lenses, .prompt_template = verify_template };
        },
        else => return failText(arena, "AgentSwarm field \"verify\" must be an object"),
    }

    var until_dry_max_rounds: ?usize = null;
    switch (object.get("until_dry") orelse .null) {
        .null => {},
        .object => |map| {
            if (unknownField(map, &until_dry_fields)) |name| {
                return failFormat(arena, "AgentSwarm field \"until_dry\" does not take \"{s}\".", .{name});
            }
            until_dry_max_rounds = intField(map, "max_rounds", 2, engine.max_until_dry_rounds, engine.default_until_dry_rounds) catch
                return failFormat(arena, "AgentSwarm field \"until_dry.max_rounds\" must be an integer from 2 to {d}", .{engine.max_until_dry_rounds});
            if (dedup_key == null) return failText(arena, until_dry_needs_key_message);
            if (items.len == 0) return failText(arena, until_dry_needs_items_message);
        },
        else => return failText(arena, "AgentSwarm field \"until_dry\" must be an object"),
    }

    return .{ .config = .{
        .items = items,
        .stages = stages.items,
        .resumed = resumed.items,
        .profile = subagent_type orelse profiles.default_subagent_name,
        .model = model,
        .schema = schema,
        .dedup_key = dedup_key,
        .max_results = max_results,
        .max_running = max_running,
        .verify = verify,
        .until_dry_max_rounds = until_dry_max_rounds,
        .critic = critic,
    } };
}

fn unknownField(object: std.json.ObjectMap, allowed: []const []const u8) ?[]const u8 {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const known = for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) break true;
        } else false;
        if (!known) return entry.key_ptr.*;
    }
    return null;
}

fn textField(object: std.json.ObjectMap, key: []const u8) FieldError!?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string) return error.InvalidField;
    const trimmed = std.mem.trim(u8, value.string, whitespace);
    if (trimmed.len == 0) return error.InvalidField;
    return trimmed;
}

fn boolField(object: std.json.ObjectMap, key: []const u8) FieldError!bool {
    const value = object.get(key) orelse return false;
    if (value == .null) return false;
    if (value != .bool) return error.InvalidField;
    return value.bool;
}

fn intField(object: std.json.ObjectMap, key: []const u8, min: usize, max: usize, default: usize) FieldError!usize {
    const value = object.get(key) orelse return default;
    if (value == .null) return default;
    if (value != .integer) return error.InvalidField;
    if (value.integer < 0) return error.InvalidField;
    const number: usize = std.math.cast(usize, value.integer) orelse return error.InvalidField;
    if (number < min or number > max) return error.InvalidField;
    return number;
}

fn invalidField(arena: Allocator, key: []const u8) Allocator.Error!Checked {
    return .{ .failure = try arena.print("AgentSwarm field \"{s}\" must be a non-empty string", .{key}) };
}

fn failText(arena: Allocator, text: []const u8) Allocator.Error!Checked {
    return .{ .failure = try arena.dupe(u8, text) };
}

fn failFormat(arena: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!Checked {
    return .{ .failure = try arena.print(fmt, args) };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.arena_state.deinit();
    alloc.destroy(input);
}

const ProviderRunner = struct {
    provider: tool_provider.Provider,
    cancel_flag: ?*std.atomic.Value(bool),

    fn runner(self: *ProviderRunner) engine.Runner {
        return .{ .context = self, .run_fn = run };
    }

    fn run(raw: *anyopaque, arena: Allocator, request: engine.ChildRequest) Allocator.Error!engine.ChildResult {
        const self: *ProviderRunner = @ptrCast(@alignCast(raw));
        const reply = try foreground_call.send(arena, self.provider, self.cancel_flag, .{
            .agent = request.agent,
            .prompt = request.prompt,
            .profile = request.profile,
            .model = request.model,
            .invocation_id = request.invocation_id,
            .continues = request.continues,
        });
        return .{
            .outcome = switch (reply.outcome) {
                .completed => .completed,
                .failed => .failed,
                .cancelled => .cancelled,
                .transport_error => .transport_error,
            },
            .text = reply.text,
            .turn_cancelled = reply.turn_cancelled,
        };
    }
};

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    return callWith(ctx, erased, std.heap.c_allocator);
}

fn callWith(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
    work_alloc: Allocator,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const provider = ctx.subagent_provider orelse
        return .{ .failure = try ctx.allocator.dupe(u8, host_unavailable_message) };
    var provider_runner = ProviderRunner{ .provider = provider, .cancel_flag = ctx.cancel_flag };
    var config = input.config;
    if (ctx.tool_call_id.len > 0) config.call_id = ctx.tool_call_id;
    var swarm = engine.Engine.init(work_alloc, config, provider_runner.runner(), ctx.cancel_flag);
    defer swarm.deinit();
    try swarm.run();
    const body = try swarm.encodeAlloc(ctx.allocator);
    return if (swarm.anyUnitCompleted()) .{ .success = body } else .{ .failure = body };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn expectDecodeFailure(args_json: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |failure| {
            defer alloc.free(failure);
            try std.testing.expectEqualStrings(expected, failure);
        },
    }
}

fn decodeForTest(args_json: []const u8) !tool_dispatch.ToolInput {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    return switch (decoded) {
        .input => |input| input,
        .failure => |failure| {
            defer alloc.free(failure);
            return error.TestUnexpectedResult;
        },
    };
}

fn expectSubagentCount(args_json: []const u8, expected: usize) !void {
    const input = try decodeForTest(args_json);
    defer input.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected, input.as(Input).subagent_count);
}

fn itemsJson(alloc: Allocator, count: usize, template: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"description\":\"sweep\",\"prompt_template\":\"");
    try out.writer.writeAll(template);
    try out.writer.writeAll("\",\"items\":[");
    for (0..count) |index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.print("\"item {d}\"", .{index});
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

test "AgentSwarm accepts two templated items and reports the subagent count" {
    try expectSubagentCount(
        "{\"description\":\"sweep\",\"prompt_template\":\"review {{item}}\",\"items\":[\"a.zig\",\"b.zig\"]}",
        2,
    );
    try expectSubagentCount("{\"description\":\"resume\",\"resume_agent_ids\":{\"agent-1\":\"continue\"}}", 1);
}

test "AgentSwarm needs two items unless a resume entry is given" {
    try expectDecodeFailure(
        "{\"description\":\"sweep\",\"prompt_template\":\"review {{item}}\",\"items\":[\"a.zig\"]}",
        too_few_items_message,
    );
}

test "AgentSwarm caps the total subagent count at 128" {
    const alloc = std.testing.allocator;
    const args = try itemsJson(alloc, max_subagents + 1, "review {{item}}");
    defer alloc.free(args);
    try expectDecodeFailure(args, "AgentSwarm supports at most 128 subagents.");
    const at_cap = try itemsJson(alloc, max_subagents, "review {{item}}");
    defer alloc.free(at_cap);
    try expectSubagentCount(at_cap, max_subagents);
}

test "AgentSwarm requires a prompt_template with the item placeholder" {
    try expectDecodeFailure(
        "{\"description\":\"sweep\",\"items\":[\"a\",\"b\"]}",
        prompt_template_required_message,
    );
    try expectDecodeFailure(
        "{\"description\":\"sweep\",\"prompt_template\":\"review it\",\"items\":[\"a\",\"b\"]}",
        placeholder_missing_message,
    );
}

test "AgentSwarm rejects items that expand to the same prompt" {
    try expectDecodeFailure(
        "{\"description\":\"sweep\",\"prompt_template\":\"review {{item}}\",\"items\":[\"a.zig\",\" a.zig \"]}",
        "Duplicate subagent prompts from items 1 and 2. AgentSwarm requires distinct subagents.",
    );
}

test "AgentSwarm rejects fork while the experimental flag is off" {
    try expectDecodeFailure(
        "{\"description\":\"sweep\",\"fork\":true,\"prompt_template\":\"review {{item}}\",\"items\":[\"a\",\"b\"]}",
        fork_disabled_message,
    );
}

test "AgentSwarm names the field with a blank or mistyped value" {
    try expectDecodeFailure("{\"description\":\"  \"}", "AgentSwarm field \"description\" must be a non-empty string");
    try expectDecodeFailure("{\"description\":\"sweep\",\"items\":\"a\"}", "AgentSwarm field \"items\" must be a non-empty string");
    try expectDecodeFailure("[]", invalid_arguments_message);
    try expectDecodeFailure("{\"description\":\"sweep\",\"itemz\":[]}", "AgentSwarm does not take \"itemz\".");
}

test "AgentSwarm validates stages, schema, caps, verify and until_dry before anything runs" {
    const base = "{\"description\":\"sweep\",\"items\":[\"a\",\"b\"],";
    const cases = [_]struct { rest: []const u8, expected: []const u8 }{
        .{ .rest = "\"prompt_template\":\"x {{item}}\",\"stages\":[{\"name\":\"s\",\"prompt_template\":\"y {{item}}\"}]}", .expected = template_and_stages_message },
        .{ .rest = "\"stages\":[]}", .expected = "AgentSwarm field \"stages\" must hold 1 to 8 stages" },
        .{ .rest = "\"stages\":[{\"name\":\"s\"}]}", .expected = "AgentSwarm field \"stages[0].prompt_template\" must be a non-empty string" },
        .{ .rest = "\"stages\":[{\"name\":\"s\",\"prompt_template\":\"y {{item}}\"},{\"prompt_template\":\"z\"}]}", .expected = "AgentSwarm field \"stages[1].name\" must be a non-empty string" },
        .{ .rest = "\"stages\":[{\"name\":\"s\",\"prompt_template\":\"no placeholder\"}]}", .expected = stage_placeholder_missing_message },
        .{ .rest = "\"stages\":[{\"name\":\"s\",\"prompt_template\":\"y {{item}}\",\"when\":1}]}", .expected = "AgentSwarm field \"stages[0]\" does not take \"when\"." },
        .{ .rest = "\"prompt_template\":\"x {{item}}\",\"schema\":[1]}", .expected = "AgentSwarm field \"schema\" is not usable: schema must be a JSON object" },
        .{ .rest = "\"prompt_template\":\"x {{item}}\",\"max_running\":17}", .expected = "AgentSwarm field \"max_running\" must be an integer from 1 to 16" },
        .{ .rest = "\"prompt_template\":\"x {{item}}\",\"max_results\":0}", .expected = "AgentSwarm field \"max_results\" must be an integer from 1 to 1000" },
        .{ .rest = "\"prompt_template\":\"x {{item}}\",\"verify\":{\"checkers\":1}}", .expected = "AgentSwarm field \"verify.checkers\" must be an integer from 2 to 5" },
        .{ .rest = "\"prompt_template\":\"x {{item}}\",\"verify\":{\"lenses\":[\"\"]}}", .expected = "AgentSwarm field \"verify.lenses\" must be a non-empty string" },
        .{ .rest = "\"prompt_template\":\"x {{item}}\",\"verify\":{\"prompt_template\":\"check it\"}}", .expected = verify_placeholder_missing_message },
        .{ .rest = "\"prompt_template\":\"x {{item}}\",\"verify\":true}", .expected = "AgentSwarm field \"verify\" must be an object" },
        .{ .rest = "\"prompt_template\":\"x {{item}}\",\"until_dry\":{}}", .expected = until_dry_needs_key_message },
        .{ .rest = "\"prompt_template\":\"x {{item}}\",\"dedup_key\":\"id\",\"until_dry\":{\"max_rounds\":11}}", .expected = "AgentSwarm field \"until_dry.max_rounds\" must be an integer from 2 to 10" },
        .{ .rest = "\"prompt_template\":\"x {{item}}\",\"critic\":\"yes\"}", .expected = "AgentSwarm field \"critic\" must be true or false" },
    };
    for (cases) |case| {
        const args = try std.mem.concat(std.testing.allocator, u8, &.{ base, case.rest });
        defer std.testing.allocator.free(args);
        try expectDecodeFailure(args, case.expected);
    }
}

test "AgentSwarm decodes stages, schema, verify, until_dry and caps into the engine config" {
    const input = try decodeForTest(
        \\{"description":"sweep","subagent_type":"explore","items":["a","b"],
        \\"stages":[{"name":"find","prompt_template":"find {{item}}"},{"name":"check","prompt_template":"check {{previous}}"}],
        \\"schema":{"type":"object","required":["id"]},"dedup_key":"id","max_results":50,"max_running":4,
        \\"verify":{"checkers":2,"lenses":["correctness"," security "]},"until_dry":{"max_rounds":3},"critic":true}
    );
    defer input.deinit(std.testing.allocator);
    const config = input.as(Input).config;
    try std.testing.expectEqual(@as(usize, 2), config.stages.len);
    try std.testing.expectEqualStrings("check", config.stages[1].name);
    try std.testing.expectEqualStrings("explore", config.profile.?);
    try std.testing.expect(config.schema.? == .object);
    try std.testing.expectEqualStrings("id", config.dedup_key.?);
    try std.testing.expectEqual(@as(usize, 50), config.max_results);
    try std.testing.expectEqual(@as(usize, 4), config.max_running);
    try std.testing.expectEqual(@as(usize, 2), config.verify.?.checkers);
    try std.testing.expectEqualStrings("security", config.verify.?.lenses[1]);
    try std.testing.expectEqual(@as(?usize, 3), config.until_dry_max_rounds);
    try std.testing.expect(config.critic);

    const defaults = try decodeForTest("{\"description\":\"sweep\",\"prompt_template\":\"review {{item}}\",\"items\":[\"a\",\"b\"]}");
    defer defaults.deinit(std.testing.allocator);
    const default_config = defaults.as(Input).config;
    try std.testing.expectEqual(engine.default_max_running, default_config.max_running);
    try std.testing.expectEqual(engine.default_max_results, default_config.max_results);
    try std.testing.expectEqualStrings(profiles.default_subagent_name, default_config.profile.?);
    try std.testing.expect(default_config.verify == null);
    try std.testing.expectEqualStrings("run", default_config.stages[0].name);
}

test "AgentSwarm reports that no subagent host is available and starts nothing" {
    const alloc = std.testing.allocator;
    const input = try decodeForTest("{\"description\":\"sweep\",\"prompt_template\":\"review {{item}}\",\"items\":[\"a\",\"b\"]}");
    defer input.deinit(alloc);
    const result = try callWith(.{ .allocator = alloc }, input, alloc);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings(host_unavailable_message, result.failure);
}

const ProviderFixture = struct {
    calls: std.atomic.Value(usize) = .init(0),
    overrides: std.atomic.Value(usize) = .init(0),

    fn execute(
        raw: ?*anyopaque,
        alloc: Allocator,
        request: *model_contract.Request,
        invocation_id: []const u8,
    ) tool_provider.ExecuteError!tool_provider.Result {
        const self: *ProviderFixture = @ptrCast(@alignCast(raw.?));
        _ = self.calls.fetchAdd(1, .seq_cst);
        if (request.message.profile != null) _ = self.overrides.fetchAdd(1, .seq_cst);
        if (std.mem.find(u8, invocation_id, "call-swarm:") == null) return error.Cancelled;
        const prompt = request.message.message;
        const reply: []const u8 = if (std.mem.find(u8, prompt, "did not match the required result schema") != null)
            "{\"path\":\"b.zig\",\"risk\":\"low\"}"
        else if (std.mem.find(u8, prompt, "review a.zig") != null)
            "```json\n{\"path\":\"a.zig\",\"risk\":\"high\"}\n```"
        else
            "b.zig looks fine";
        const text = foreground_text.format(alloc, request.message.agent, "explore", .completed, reply) catch
            return error.OutOfMemory;
        const body = model_contract.encodeResultAlloc(alloc, .{ .ok = true, .result = text }) catch
            return error.OutOfMemory;
        return .{ .status = .success, .body = body };
    }
};

test "AgentSwarm fans out through the subagent provider and returns validated objects with counts" {
    const alloc = std.testing.allocator;
    const input = try decodeForTest(
        \\{"description":"sweep","subagent_type":"explore","prompt_template":"review {{item}}","items":["a.zig","b.zig"],
        \\"schema":{"type":"object","required":["path","risk"]},"max_running":1}
    );
    defer input.deinit(alloc);
    var fixture = ProviderFixture{};
    const result = try callWith(.{
        .allocator = alloc,
        .tool_call_id = "call-swarm",
        .subagent_provider = .{ .context = &fixture, .execute_fn = ProviderFixture.execute },
    }, input, alloc);
    defer result.deinit(alloc);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.success, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const counts = root.get("counts").?.object;
    try std.testing.expectEqual(@as(i64, 2), counts.get("units").?.integer);
    try std.testing.expectEqual(@as(i64, 2), counts.get("started").?.integer);
    try std.testing.expectEqual(@as(i64, 1), counts.get("repaired").?.integer);
    try std.testing.expectEqual(@as(i64, 0), counts.get("invalid").?.integer);
    const results = root.get("results").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("high", results[0].object.get("value").?.object.get("risk").?.string);
    try std.testing.expectEqualStrings("b.zig", results[1].object.get("value").?.object.get("path").?.string);
    try std.testing.expectEqual(@as(usize, 3), fixture.calls.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), fixture.overrides.load(.seq_cst));
}
