const std = @import("std");
const domain = @import("../../core/subagent/domain.zig");
const model_contract = @import("../../core/subagent/model_contract.zig");
const profiles = @import("../../core/profiles/profiles.zig");
const tool_provider = @import("../../core/subagent/tool_provider.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const io_mod = @import("../../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    request: model_contract.Request,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        self.request.deinit(alloc);
        self.* = undefined;
    }
};

pub const agent_fields = [_][]const u8{ "prompt", "description", "subagent_type", "resume", "run_in_background", "fork", "model" };

const DecodeError = error{
    OutOfMemory,
    InvalidFieldType,
    MissingField,
    UnknownField,
    UnsupportedFork,
    ResumeWithType,
};

const fork_disabled_text = "fork is disabled: the subagent_fork experimental flag is off.";

const Problem = struct {
    field: []const u8 = "",
};

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, arena, args_json, .{}) catch {
        return decodeFailure(ctx, "invalid_json", null) catch return error.OutOfMemory;
    };
    defer parsed.deinit();

    var problem: Problem = .{};
    const request_input = parseRoot(arena, ctx.tool_call_id, parsed.value, &problem) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("subagent", "request decode rejected code={s} field={s}", .{ decodeErrorCode(err), problem.field });
        const correction = try problemText(arena, err, problem);
        return decodeFailure(ctx, decodeErrorCode(err), correction) catch return error.OutOfMemory;
    };
    const request = model_contract.validateRequest(ctx.allocator, request_input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("subagent", "request validation rejected code={s}", .{validationErrorCode(err)});
        return decodeFailure(ctx, validationErrorCode(err), null) catch return error.OutOfMemory;
    };
    errdefer {
        var owned = request;
        owned.deinit(ctx.allocator);
    }

    const input = try ctx.allocator.create(Input);
    input.* = .{ .request = request };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn decodeFailure(
    ctx: tool_dispatch.DispatchContext,
    code: []const u8,
    correction: ?[]const u8,
) !tool_dispatch.DecodeResult {
    return .{ .failure = try model_contract.encodeResultAlloc(ctx.allocator, .{
        .ok = false,
        .result = correction,
        .error_code = code,
    }) };
}

fn problemText(arena: Allocator, err: DecodeError, problem: Problem) Allocator.Error![]const u8 {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.MissingField => "Agent needs prompt and description.",
        error.UnknownField => try arena.print(
            "{s} does not apply to Agent. Agent takes prompt, description, subagent_type, resume, run_in_background, fork, and model.",
            .{problem.field},
        ),
        error.InvalidFieldType => if (problem.field.len == 0)
            "Agent arguments must be a JSON object."
        else
            try arena.print("{s} has the wrong type for Agent.", .{problem.field}),
        error.UnsupportedFork => fork_disabled_text,
        error.ResumeWithType => "Cannot set subagent_type when resuming an existing agent. Resume by agent id only.",
    };
}

fn decodeErrorCode(err: DecodeError) []const u8 {
    return switch (err) {
        error.OutOfMemory => unreachable,
        error.InvalidFieldType => "invalid_field_type",
        error.MissingField => "missing_field",
        error.UnknownField => "unknown_field",
        error.UnsupportedFork => "unsupported_fork",
        error.ResumeWithType => "resume_with_subagent_type",
    };
}

fn validationErrorCode(err: model_contract.ValidationError) []const u8 {
    return switch (err) {
        error.OutOfMemory => unreachable,
        error.InvalidAgent => "invalid_agent",
        error.InvalidReport => "invalid_report",
        error.InvalidParentMessage => "invalid_parent_message",
        error.InvalidInstructions => "invalid_instructions",
        error.InvalidMessage => "invalid_message",
        error.InvalidModel => "invalid_model",
        error.InvalidEffort => "invalid_effort",
        error.InvalidProfile => "invalid_profile",
    };
}

fn parseRoot(
    arena: Allocator,
    tool_call_id: []const u8,
    value: std.json.Value,
    problem: *Problem,
) DecodeError!model_contract.RequestInput {
    const root = try objectValue(value);
    try rejectUnknown(root, &agent_fields, problem);
    const prompt = try requiredString(root, "prompt", problem);
    _ = try requiredString(root, "description", problem);
    const background = (try optionalBool(root, "run_in_background", problem)) orelse
        startsInBackgroundByDefault(io_mod.getenv(background_default_env));
    if ((try optionalBool(root, "fork", problem)) orelse false) return error.UnsupportedFork;

    if (try optionalString(root, "resume", problem)) |resume_agent| {
        const agent = std.mem.trim(u8, resume_agent, " \t\r\n");
        if (agent.len > 0) {
            if (try optionalString(root, "subagent_type", problem)) |requested| {
                if (requested.len > 0) return error.ResumeWithType;
            }
            return .{ .message = .{ .agent = agent, .message = prompt, .foreground = !background } };
        }
    }
    return .{ .message = .{
        .agent = try generatedAgentName(arena, tool_call_id),
        .message = prompt,
        .model = try optionalString(root, "model", problem),
        .profile = try subagentType(root, problem),
        .foreground = !background,
    } };
}

const background_default_env = "CLAUDE_CODE_FORK_SUBAGENT";

fn startsInBackgroundByDefault(env_value: ?[]const u8) bool {
    const value = std.mem.trim(u8, env_value orelse return false, " \t\r\n");
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}

test "CLAUDE_CODE_FORK_SUBAGENT=1 starts an Agent call in the background when run_in_background is left out" {
    try std.testing.expect(!startsInBackgroundByDefault(null));
    try std.testing.expect(!startsInBackgroundByDefault(""));
    try std.testing.expect(!startsInBackgroundByDefault("0"));
    try std.testing.expect(!startsInBackgroundByDefault("false"));
    try std.testing.expect(startsInBackgroundByDefault("1"));
    try std.testing.expect(startsInBackgroundByDefault(" TRUE\n"));
}

fn subagentType(object: std.json.ObjectMap, problem: *Problem) DecodeError![]const u8 {
    const requested = (try optionalString(object, "subagent_type", problem)) orelse "";
    if (requested.len == 0) return profiles.default_subagent_name;
    return if (profiles.validName(requested)) requested else profiles.canonicalName(requested);
}

fn generatedAgentName(arena: Allocator, tool_call_id: []const u8) Allocator.Error![]const u8 {
    const prefix = "agent-";
    const suffix_len = @min(tool_call_id.len, domain.max_agent_name_bytes - prefix.len);
    const name = try arena.alloc(u8, prefix.len + suffix_len);
    @memcpy(name[0..prefix.len], prefix);
    for (tool_call_id[0..suffix_len], name[prefix.len..]) |byte, *out| {
        out.* = if (std.ascii.isAlphanumeric(byte)) std.ascii.toLower(byte) else '-';
    }
    return name;
}

fn objectValue(value: std.json.Value) DecodeError!std.json.ObjectMap {
    return if (value == .object) value.object else error.InvalidFieldType;
}

fn stringValue(value: std.json.Value) DecodeError![]const u8 {
    return if (value == .string) value.string else error.InvalidFieldType;
}

fn requiredString(
    object: std.json.ObjectMap,
    key: []const u8,
    problem: *Problem,
) DecodeError![]const u8 {
    problem.field = key;
    const value = object.get(key) orelse return error.MissingField;
    return stringValue(value);
}

fn optionalString(
    object: std.json.ObjectMap,
    key: []const u8,
    problem: *Problem,
) DecodeError!?[]const u8 {
    problem.field = key;
    const value = object.get(key) orelse return null;
    return try stringValue(value);
}

fn optionalBool(
    object: std.json.ObjectMap,
    key: []const u8,
    problem: *Problem,
) DecodeError!?bool {
    problem.field = key;
    const value = object.get(key) orelse return null;
    return if (value == .bool) value.bool else error.InvalidFieldType;
}

fn rejectUnknown(
    object: std.json.ObjectMap,
    allowed: []const []const u8,
    problem: *Problem,
) DecodeError!void {
    var fields = object.iterator();
    while (fields.next()) |entry| {
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) break;
        } else {
            problem.field = entry.key_ptr.*;
            return error.UnknownField;
        }
    }
}

pub fn validate(
    _: tool_dispatch.DispatchContext,
    _: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const provider = ctx.subagent_provider orelse {
        const body = model_contract.encodeResultAlloc(ctx.allocator, .{
            .ok = false,
            .error_code = "host_unavailable",
        }) catch return error.OutOfMemory;
        return .{ .failure = body };
    };
    const request = &erased.as(Input).request;
    debug_trace.logf(
        "subagent",
        "request accepted action={s} agent={s} model_override={s} effort_override={s}",
        .{
            @tagName(request.action()),
            request.agentName() orelse "none",
            request.override().model orelse "none",
            if (request.override().effort) |effort| effort.label() else "none",
        },
    );
    const result = try provider.execute(
        ctx.allocator,
        request,
        ctx.tool_call_id,
    );
    return switch (result.status) {
        .success => .{ .success = result.body },
        .failure => .{ .failure = result.body },
    };
}

pub fn readsOnly(erased: tool_dispatch.ToolInput) bool {
    return switch (erased.as(Input).request) {
        .wait, .status => true,
        .message, .stop, .close => false,
    };
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn expectDecodeFailure(args_json: []const u8, code: []const u8) !void {
    const alloc = std.testing.allocator;
    const result = try decode(.{ .allocator = alloc }, args_json);
    switch (result) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |message| {
            defer alloc.free(message);
            const needle = try alloc.print("\"error_code\":\"{s}\"", .{code});
            defer alloc.free(needle);
            try std.testing.expect(std.mem.find(u8, message, needle) != null);
        },
    }
}

fn expectAgentName(
    args_json: []const u8,
    tool_call_id: []const u8,
    expected: []const u8,
) !void {
    const alloc = std.testing.allocator;
    const result = try decode(.{ .allocator = alloc, .tool_call_id = tool_call_id }, args_json);
    switch (result) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expectEqual(model_contract.Action.message, input.as(Input).request.action());
            try std.testing.expectEqualStrings(expected, input.as(Input).request.agentName().?);
        },
    }
}

fn expectCorrection(args_json: []const u8, code: []const u8, correction: []const u8) !void {
    const alloc = std.testing.allocator;
    try expectDecodeFailure(args_json, code);
    const result = try decode(.{ .allocator = alloc }, args_json);
    const body = switch (result) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |message| message,
    };
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const text = parsed.value.object.get("result").?.string;
    try std.testing.expect(std.mem.find(u8, text, correction) != null);
}

test "call executes a validated managed request through the provider" {
    const Fixture = struct {
        calls: usize = 0,
        request: ?*model_contract.Request = null,
        invocation_id: ?[]const u8 = null,

        fn execute(
            raw_context: ?*anyopaque,
            alloc: Allocator,
            request: *model_contract.Request,
            invocation_id: []const u8,
        ) Allocator.Error!tool_provider.Result {
            const self: *@This() = @ptrCast(@alignCast(raw_context.?));
            self.calls += 1;
            self.request = request;
            self.invocation_id = invocation_id;
            return .{
                .status = .success,
                .body = try alloc.dupe(u8, "{\"ok\":true}"),
            };
        }
    };

    const alloc = std.testing.allocator;
    const decoded = try decode(
        .{ .allocator = alloc, .tool_call_id = "call-1" },
        "{\"prompt\":\"review this\",\"description\":\"Review\"}",
    );
    var fixture = Fixture{};
    switch (decoded) {
        .failure => |reason| {
            defer alloc.free(reason);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const result = try call(.{
                .allocator = alloc,
                .tool_call_id = "call-1",
                .subagent_provider = .{
                    .context = &fixture,
                    .execute_fn = Fixture.execute,
                },
            }, input);
            defer result.deinit(alloc);
            switch (result) {
                .rich => return error.TestUnexpectedRichResult,
                .success => |body| try std.testing.expectEqualStrings("{\"ok\":true}", body),
                .failure => return error.TestUnexpectedResult,
            }
            try std.testing.expect(fixture.request.? == &input.as(Input).request);
            try std.testing.expectEqual(model_contract.Action.message, fixture.request.?.action());
            try std.testing.expectEqualStrings("call-1", fixture.invocation_id.?);
        },
    }
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "decode maps a spawn to a generated agent name and a resume to the named agent" {
    try expectAgentName("{\"prompt\":\"review\",\"description\":\"Review\"}", "call-1", "agent-call-1");
    try expectAgentName("{\"prompt\":\"review\",\"description\":\"Review\",\"resume\":\" reviewer \"}", "call-2", "reviewer");
    try expectAgentName("{\"prompt\":\"review\",\"description\":\"Review\",\"resume\":\"  \"}", "Call_3", "agent-call-3");
}

test "decode forwards subagent_type and model when starting a new agent" {
    const alloc = std.testing.allocator;
    const result = try decode(
        .{ .allocator = alloc, .tool_call_id = "call-4" },
        "{\"prompt\":\"audit\",\"description\":\"Audit\",\"subagent_type\":\"agent\",\"model\":\"gpt-5.6-sol-fast\"}",
    );
    switch (result) {
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const override = input.as(Input).request.override();
            try std.testing.expectEqualStrings("agent", override.profile.?);
            try std.testing.expectEqualStrings("gpt-5.6-sol-fast", override.model.?);
        },
    }
}

test "decode starts a new subagent as coder when subagent_type is omitted or empty" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "{\"prompt\":\"fix\",\"description\":\"Fix\"}",
        "{\"prompt\":\"fix\",\"description\":\"Fix\",\"subagent_type\":\"\"}",
    };
    for (cases) |args_json| {
        const result = try decode(.{ .allocator = alloc, .tool_call_id = "call-5" }, args_json);
        switch (result) {
            .failure => |message| {
                defer alloc.free(message);
                return error.TestUnexpectedResult;
            },
            .input => |input| {
                defer input.deinit(alloc);
                try std.testing.expectEqualStrings("coder", input.as(Input).request.override().profile.?);
            },
        }
    }
}

test "decode reads Claude Code's capitalised Explore and Plan agent types as fx's explore and plan" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { args_json: []const u8, profile: []const u8 }{
        .{ .args_json = "{\"prompt\":\"look\",\"description\":\"Look\",\"subagent_type\":\"Explore\"}", .profile = "explore" },
        .{ .args_json = "{\"prompt\":\"plan\",\"description\":\"Plan\",\"subagent_type\":\"Plan\"}", .profile = "plan" },
        .{ .args_json = "{\"prompt\":\"do\",\"description\":\"Do\",\"subagent_type\":\"general-purpose\"}", .profile = "general-purpose" },
    };
    for (cases) |case| {
        const result = try decode(.{ .allocator = alloc, .tool_call_id = "call-6" }, case.args_json);
        switch (result) {
            .failure => |message| {
                defer alloc.free(message);
                return error.TestUnexpectedResult;
            },
            .input => |input| {
                defer input.deinit(alloc);
                try std.testing.expectEqualStrings(case.profile, input.as(Input).request.override().profile.?);
            },
        }
    }
}

test "decode runs an Agent call in the foreground unless run_in_background is true" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { json: []const u8, foreground: bool }{
        .{ .json = "{\"prompt\":\"p\",\"description\":\"d\"}", .foreground = true },
        .{ .json = "{\"prompt\":\"p\",\"description\":\"d\",\"run_in_background\":false}", .foreground = true },
        .{ .json = "{\"prompt\":\"p\",\"description\":\"d\",\"run_in_background\":true}", .foreground = false },
        .{ .json = "{\"prompt\":\"p\",\"description\":\"d\",\"resume\":\"scout\",\"run_in_background\":true}", .foreground = false },
    };
    for (cases) |case| {
        const result = try decode(.{ .allocator = alloc, .tool_call_id = "call-6" }, case.json);
        switch (result) {
            .failure => |message| {
                defer alloc.free(message);
                return error.TestUnexpectedResult;
            },
            .input => |input| {
                defer input.deinit(alloc);
                try std.testing.expectEqual(case.foreground, input.as(Input).request.message.foreground);
            },
        }
    }
}

test "decode accepts only the Agent fields and rejects the rest" {
    try expectDecodeFailure("{\"description\":\"d\"}", "missing_field");
    try expectDecodeFailure("{\"prompt\":\"p\"}", "missing_field");
    try expectDecodeFailure("{\"prompt\":\"p\",\"description\":\"d\",\"action\":\"message\"}", "unknown_field");
    try expectDecodeFailure("{\"prompt\":\"p\",\"description\":\"d\",\"fork\":true}", "unsupported_fork");
    try expectDecodeFailure("{\"prompt\":7,\"description\":\"d\"}", "invalid_field_type");
    try expectDecodeFailure("{\"prompt\":\"p\",\"description\":\"d\",\"run_in_background\":\"yes\"}", "invalid_field_type");
    try expectDecodeFailure("{\"prompt\":\"p\",\"description\":\"d\",\"model\":\"\"}", "invalid_model");
    try expectDecodeFailure("[]", "invalid_field_type");
}

test "decode names what a rejected Agent call got wrong" {
    try expectCorrection("{\"prompt\":\"p\",\"description\":\"d\",\"action\":\"wait\"}", "unknown_field", "action does not apply to Agent.");
    try expectCorrection("{\"prompt\":\"p\",\"description\":\"d\",\"fork\":true}", "unsupported_fork", "fork is disabled: the subagent_fork experimental flag is off.");
    try expectCorrection("{\"prompt\":\"p\",\"description\":\"d\",\"resume\":\"reviewer\",\"subagent_type\":\"plan\"}", "resume_with_subagent_type", "Cannot set subagent_type when resuming an existing agent. Resume by agent id only.");
    try expectCorrection("{\"description\":\"d\"}", "missing_field", "Agent needs prompt and description.");
    try expectCorrection("{\"prompt\":\"p\",\"description\":\"d\",\"run_in_background\":\"yes\"}", "invalid_field_type", "run_in_background has the wrong type for Agent.");
    try expectCorrection("[]", "invalid_field_type", "Agent arguments must be a JSON object.");
}

test "call reports compact host unavailability" {
    const alloc = std.testing.allocator;
    const decoded = try decode(
        .{ .allocator = alloc },
        "{\"prompt\":\"wait\",\"description\":\"Wait\"}",
    );
    switch (decoded) {
        .failure => |reason| {
            defer alloc.free(reason);
            return error.TestUnexpectedResult;
        },
        .input => |input| {
            defer input.deinit(alloc);
            const result = try call(.{ .allocator = alloc }, input);
            defer result.deinit(alloc);
            switch (result) {
                .rich => return error.TestUnexpectedRichResult,
                .success => return error.TestUnexpectedResult,
                .failure => |body| try std.testing.expect(std.mem.find(
                    u8,
                    body,
                    "\"error_code\":\"host_unavailable\"",
                ) != null),
            }
        },
    }
}
