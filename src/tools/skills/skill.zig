const std = @import("std");
const testing_allocator = @import("../../core/shared/testing_allocator.zig");
const builtin_skills = @import("../../builtins/skills.zig");
const skill_arguments = @import("../../core/skills/skill_arguments.zig");
const skill_frontmatter = @import("../../core/skills/skill_frontmatter.zig");
const skill_invocation = @import("../../core/skills/skill_invocation.zig");
const skill_runtime = @import("../../core/skills/skill_runtime.zig");
const skill_contract = @import("../../core/skills/skill_contract.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_limits = @import("../../core/tooling/tool_result_limits.zig");
const context_limits = @import("../../core/config/context_limits.zig");
const io_mod = @import("../../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const Input = struct {
    name: ?[]u8 = null,
    location: ?[]u8 = null,
    resource: ?[]u8 = null,
    offset: usize = 0,
    args: ?[]u8 = null,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        if (self.name) |name| alloc.free(name);
        if (self.location) |location| alloc.free(location);
        if (self.resource) |resource| alloc.free(resource);
        if (self.args) |args| alloc.free(args);
        self.* = .{};
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try ctx.allocator.dupe(u8, "skill arguments must be valid JSON") },
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "skill arguments must be an object") };
    }
    var fields = parsed.value.object.iterator();
    while (fields.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, "skill") and !std.mem.eql(u8, entry.key_ptr.*, "args")) {
            return .{ .failure = try ctx.allocator.print("skill field \"{s}\" does not apply. Skill takes skill and args.", .{entry.key_ptr.*}) };
        }
    }

    const skill_value = parsed.value.object.get("skill") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "skill requires the name of a skill from the skill list") };
    };
    if (skill_value != .string or skill_value.string.len == 0) {
        return .{ .failure = try ctx.allocator.dupe(u8, "skill field \"skill\" must be a non-empty string") };
    }
    const args_value = parsed.value.object.get("args");
    if (args_value) |value| {
        if (value != .string) {
            return .{ .failure = try ctx.allocator.dupe(u8, "skill field \"args\" must be a string") };
        }
    }

    const name = try ctx.allocator.dupe(u8, skill_value.string);
    errdefer ctx.allocator.free(name);
    const args = if (args_value) |value| try ctx.allocator.dupe(u8, value.string) else null;
    errdefer if (args) |value| ctx.allocator.free(value);

    const input = try ctx.allocator.create(Input);
    input.* = .{ .name = name, .args = args };

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn presentation(_: std.json.ObjectMap) ?tool_dispatch.CallPresentation {
    return null;
}

pub fn prepare(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!skill_contract.CallPreparation {
    const decoded = try decode(ctx, args_json);
    const input = switch (decoded) {
        .failure => |reason| return .{ .failure = .{ .model_output = reason } },
        .input => |value| value,
    };
    defer input.deinit(ctx.allocator);
    const preparation = prepareInput(ctx, input.as(Input)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return error.Cancelled,
        else => return .{ .failure = .{ .model_output = try ctx.allocator.print("skill failed: {s}. Refresh available skills and retry with a skill name from the current skill listing.", .{@errorName(err)}) } },
    };
    const selected = switch (preparation) {
        .failure => return preparation,
        .selected => |value| value,
    };
    errdefer skill_invocation.freeCallPreparation(ctx.allocator, preparation);
    const refusal = try modelInvocationRefusal(ctx.allocator, selected.skill) orelse return preparation;
    skill_invocation.freeCallPreparation(ctx.allocator, preparation);
    return .{ .failure = .{ .model_output = refusal } };
}

pub fn modelInvocationRefusal(alloc: Allocator, skill: skill_contract.Skill) Allocator.Error!?[]u8 {
    if (skill.model_invocation_disabled) {
        return try std.fmt.allocPrint(alloc, "Skill \"{s}\" can only be triggered by the user (model invocation is disabled).", .{skill.name});
    }
    if (!skill.kind.modelInvocable()) {
        return try std.fmt.allocPrint(alloc, "Skill \"{s}\" is a {s} skill, not an inline skill, and cannot be invoked by the model.", .{ skill.name, skill.kind.label() });
    }
    return null;
}

fn prepareInput(ctx: tool_dispatch.DispatchContext, input: *const Input) !skill_contract.CallPreparation {
    if (ctx.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    const locations = if (ctx.skill_locations) |value| value.* else skill_contract.Locations{};
    const location = if (input.location) |value| try locations.resolve(ctx.allocator, value) else null;
    defer if (location) |value| ctx.allocator.free(value);
    if (location) |path| {
        for (locations.skills) |skill| {
            if (!std.mem.eql(u8, skill.path, path)) continue;
            return skill_invocation.prepareIdentity(ctx.allocator, .{ .skills = locations.skills, .diagnostics = locations.diagnostics }, input.name, path, ctx.max_tool_result_bytes);
        }
        if (std.mem.startsWith(u8, input.location.?, "skill:")) {
            return skill_invocation.prepareIdentity(ctx.allocator, .{ .skills = locations.skills, .diagnostics = locations.diagnostics }, input.name, path, ctx.max_tool_result_bytes);
        }
    }
    var discovery = try builtin_skills.loadVisibleSkillsForTool(ctx.allocator, ctx.workspace_root, ctx.skills_dir);
    defer discovery.deinit(ctx.allocator);
    skill_runtime.traceDiagnostics("skill_tool", discovery.diagnostics);
    return skill_invocation.prepareIdentity(ctx.allocator, .{ .skills = discovery.skills, .diagnostics = discovery.diagnostics }, input.name, location, ctx.max_tool_result_bytes);
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const result = loadInput(ctx, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return error.Cancelled,
        else => return .{ .failure = try ctx.allocator.print("skill failed: {s}", .{@errorName(err)}) },
    };
    errdefer skill_invocation.freeExecuteResult(ctx.allocator, result);
    if (result.contextNotice()) |notice| try tool_dispatch.reportContextNotice(ctx, notice);
    if (result.diagnosticNotice()) |notice| try tool_dispatch.reportContextNotice(ctx, notice);
    if (result == .loaded and result.loaded.complete) {
        if (ctx.model_content_kind_sink) |kind| kind.* = .complete_skill;
    }
    return switch (result) {
        .failure => .{ .failure = skill_invocation.takeModelOutput(ctx.allocator, result) },
        .loaded => .{ .success = skill_invocation.takeModelOutput(ctx.allocator, result) },
    };
}

fn expandLoaded(
    ctx: tool_dispatch.DispatchContext,
    result: skill_invocation.ExecuteResult,
    skill: skill_contract.Skill,
    raw_args: []const u8,
) Allocator.Error!skill_invocation.ExecuteResult {
    const output = switch (result) {
        .failure => return result,
        .loaded => |value| value,
    };
    const expanded = skill_invocation.expandLoadedSkill(ctx.allocator, output.model_output, raw_args, .{
        .skill_dir = skill_arguments.skillDirectory(skill),
        .session_id = ctx.terminal_owner_session_id orelse "",
    }) catch |err| {
        skill_invocation.freeExecuteResult(ctx.allocator, result);
        return err;
    };
    ctx.allocator.free(@constCast(output.model_output));
    var replaced = output;
    replaced.model_output = expanded;
    return .{ .loaded = replaced };
}

fn loadInput(ctx: tool_dispatch.DispatchContext, input: *const Input) !skill_invocation.ExecuteResult {
    if (ctx.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    if (ctx.resolved_skill) |skill| return loadSelected(ctx, input, skill.*);
    const preparation = try prepareInput(ctx, input);
    return switch (preparation) {
        .failure => |output| .{ .failure = output },
        .selected => |skill| selected: {
            defer skill_invocation.freeCallPreparation(ctx.allocator, preparation);
            break :selected try loadSelected(ctx, input, skill);
        },
    };
}

fn loadSelected(ctx: tool_dispatch.DispatchContext, input: *const Input, prepared: skill_contract.PreparedSkill) !skill_invocation.ExecuteResult {
    const skill = prepared.skill;
    if (try modelInvocationRefusal(ctx.allocator, skill)) |refusal| return .{ .failure = .{ .model_output = refusal } };
    const catalog: skill_invocation.Catalog = .{ .skills = &.{skill}, .diagnostics = prepared.diagnostics };
    const result = if (input.name != null)
        try skill_invocation.loadByIdentity(ctx.allocator, catalog, skill.name, skill.path, input.resource, input.offset, ctx.context_limits, ctx.max_tool_result_bytes)
    else
        try skill_invocation.loadWholeByLocation(ctx.allocator, catalog, skill.path, input.resource, ctx.context_limits, ctx.max_tool_result_bytes, ctx.cancel_flag);
    return withForkDirective(ctx.allocator, try expandLoaded(ctx, result, skill, input.args orelse ""), skill);
}

fn withForkDirective(
    alloc: Allocator,
    result: skill_invocation.ExecuteResult,
    skill: skill_contract.Skill,
) Allocator.Error!skill_invocation.ExecuteResult {
    const output = switch (result) {
        .failure => return result,
        .loaded => |value| value,
    };
    const fields = skill_frontmatter.parseLoadedSkillContent(output.model_output);
    if (!fields.context_fork) return result;
    var directed: std.Io.Writer.Allocating = .init(alloc);
    defer directed.deinit();
    const complete = written: {
        skill_frontmatter.writeForkDirective(&directed.writer, fields, skill.name) catch break :written false;
        directed.writer.writeAll(output.model_output) catch break :written false;
        break :written true;
    };
    const text: ?[]u8 = if (complete) directed.toOwnedSlice() catch null else null;
    const owned = text orelse {
        skill_invocation.freeExecuteResult(alloc, result);
        return error.OutOfMemory;
    };
    alloc.free(@constCast(output.model_output));
    var replaced = output;
    replaced.model_output = owned;
    return .{ .loaded = replaced };
}

test "a context fork skill loaded by the model carries the run-in-a-subagent directive ahead of its text" {
    const alloc = std.testing.allocator;
    const skill: skill_contract.Skill = .{ .name = "audit", .description = "", .path = "/s/audit", .source = .workspace_fx };
    const forked_text = try alloc.dupe(u8, "<skill_content name=\"audit\" resource=\"SKILL.md\" offset=\"0\" next_offset=\"60\">\n---\nname: audit\ndescription: d\ncontext: fork\nagent: explore\n---\nSTEPS\n</skill_content>");
    const forked = try withForkDirective(alloc, .{ .loaded = .{ .model_output = forked_text } }, skill);
    defer skill_invocation.freeExecuteResult(alloc, forked);
    try std.testing.expect(std.mem.startsWith(u8, forked.modelOutput(), "<skill_fork>"));
    try std.testing.expect(std.mem.find(u8, forked.modelOutput(), "subagent_type \"explore\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, forked.modelOutput(), "STEPS\n</skill_content>"));

    const inline_text = try alloc.dupe(u8, "<skill_content name=\"audit\" resource=\"SKILL.md\" offset=\"0\" next_offset=\"40\">\n---\nname: audit\ndescription: d\n---\nSTEPS\n</skill_content>");
    const inline_result = try withForkDirective(alloc, .{ .loaded = .{ .model_output = inline_text } }, skill);
    defer skill_invocation.freeExecuteResult(alloc, inline_result);
    try std.testing.expect(std.mem.startsWith(u8, inline_result.modelOutput(), "<skill_content "));
}

pub fn execute(arena: Allocator, workspace_root: []const u8, skills_dir: []const u8, args_json: []const u8) ![]u8 {
    const result = try executeForSession(arena, workspace_root, skills_dir, args_json);
    return skill_invocation.takeModelOutput(arena, result);
}

pub fn executeForSession(
    arena: Allocator,
    workspace_root: []const u8,
    skills_dir: []const u8,
    args_json: []const u8,
) !skill_invocation.ExecuteResult {
    const args = try tool_args.parseToolArgsObject(arena, args_json);
    const name = try tool_args.requiredStringArg(args, "skill");
    return loadByIdentity(
        arena,
        workspace_root,
        skills_dir,
        name,
        null,
        null,
        0,
        .{},
        tool_result_limits.default_max_tool_result_bytes,
    );
}

fn loadByIdentity(
    alloc: Allocator,
    workspace_root: []const u8,
    skills_dir: []const u8,
    name: []const u8,
    location: ?[]const u8,
    resource: ?[]const u8,
    offset: usize,
    limits: context_limits.Values,
    max_tool_result_bytes: ?usize,
) !skill_invocation.ExecuteResult {
    var discovery = try builtin_skills.loadVisibleSkillsForTool(alloc, workspace_root, skills_dir);
    defer discovery.deinit(alloc);
    skill_runtime.traceDiagnostics("skill_tool", discovery.diagnostics);
    return skill_invocation.loadByIdentity(
        alloc,
        .{ .skills = discovery.skills, .diagnostics = discovery.diagnostics },
        name,
        location,
        resource,
        offset,
        limits,
        max_tool_result_bytes,
    );
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
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expectEqualStrings(expected, body);
        },
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expect(false);
        },
    }
}

test "skill preparation discovers a skill by name added after the catalog" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "managed/new-directory");
    var file = try tmp.dir.createFile(io_mod.getIo(), "managed/new-directory/SKILL.md", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), "---\nname: newly-installed-name\ndescription: fixture\n---\nNEW INSTRUCTIONS\n");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const managed = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "managed");
    defer alloc.free(managed);
    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "managed/new-directory");
    defer alloc.free(path);
    const args = try std.json.Stringify.valueAlloc(alloc, .{ .skill = "newly-installed-name" }, .{});
    defer alloc.free(args);
    const empty_catalog: skill_contract.Locations = .{ .namespace = 3 };
    const preparation = try prepare(.{ .allocator = alloc, .workspace_root = root, .skills_dir = managed, .skill_locations = &empty_catalog }, args);
    defer skill_invocation.freeCallPreparation(alloc, preparation);
    const selected = switch (preparation) {
        .selected => |value| value,
        .failure => return error.NewSkillNotDiscovered,
    };
    try std.testing.expectEqualStrings("newly-installed-name", selected.skill.name);
    try std.testing.expectEqualStrings(path, selected.skill.path);
}

test "skill tool refuses user-only and non-inline skills and expands args into the loaded text" {
    const alloc = std.testing.allocator;
    const user_only = (try modelInvocationRefusal(alloc, .{ .name = "secret", .description = "", .path = "/s/secret", .source = .workspace_fx, .model_invocation_disabled = true })).?;
    defer alloc.free(user_only);
    try std.testing.expectEqualStrings("Skill \"secret\" can only be triggered by the user (model invocation is disabled).", user_only);
    const flow = (try modelInvocationRefusal(alloc, .{ .name = "pipeline", .description = "", .path = "/s/pipeline", .source = .workspace_fx, .kind = .flow })).?;
    defer alloc.free(flow);
    try std.testing.expectEqualStrings("Skill \"pipeline\" is a flow skill, not an inline skill, and cannot be invoked by the model.", flow);
    try std.testing.expect(try modelInvocationRefusal(alloc, .{ .name = "plain", .description = "", .path = "/s/plain", .source = .workspace_fx, .kind = .inline_text }) == null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "managed/ledger-deploy-fixture");
    try tmp.dir.createDirPath(io_mod.getIo(), "managed/ledger-secret-fixture");
    var deploy_file = try tmp.dir.createFile(io_mod.getIo(), "managed/ledger-deploy-fixture/SKILL.md", .{});
    defer deploy_file.close(io_mod.getIo());
    try deploy_file.writeStreamingAll(io_mod.getIo(), "---\nname: ledger-deploy-fixture\ndescription: ships\narguments: target\n---\nShip $target from ${FX_SKILL_DIR} with $ARGUMENTS[1].\n");
    var secret_file = try tmp.dir.createFile(io_mod.getIo(), "managed/ledger-secret-fixture/SKILL.md", .{});
    defer secret_file.close(io_mod.getIo());
    try secret_file.writeStreamingAll(io_mod.getIo(), "---\nname: ledger-secret-fixture\ndescription: user only\ndisableModelInvocation: true\n---\nHidden\n");
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const managed = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "managed");
    defer alloc.free(managed);
    const deploy_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "managed/ledger-deploy-fixture");
    defer alloc.free(deploy_dir);
    const ctx: tool_dispatch.DispatchContext = .{ .allocator = alloc, .workspace_root = root, .skills_dir = managed };

    const refused = try prepare(ctx, "{\"skill\":\"ledger-secret-fixture\"}");
    defer skill_invocation.freeCallPreparation(alloc, refused);
    switch (refused) {
        .failure => |output| try std.testing.expectEqualStrings("Skill \"ledger-secret-fixture\" can only be triggered by the user (model invocation is disabled).", output.model_output),
        .selected => return error.TestExpectedRefusal,
    }

    var input: Input = .{ .name = try alloc.dupe(u8, "ledger-deploy-fixture"), .args = try alloc.dupe(u8, "prod \"us east\"") };
    defer input.deinit(alloc);
    const result = try loadInput(ctx, &input);
    defer skill_invocation.freeExecuteResult(alloc, result);
    try std.testing.expect(result == .loaded);
    const expected_body = try std.fmt.allocPrint(alloc, "Ship prod from {s} with us east.", .{deploy_dir});
    defer alloc.free(expected_body);
    try std.testing.expect(std.mem.find(u8, result.modelOutput(), expected_body) != null);
    try std.testing.expect(std.mem.find(u8, result.modelOutput(), "ARGUMENTS:") == null);
    try std.testing.expect(std.mem.find(u8, result.modelOutput(), "<skill_content name=\"ledger-deploy-fixture\"") != null);
}

test "skill tool accepts a skill name and args" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"skill\":\"workflow\",\"args\":\"-m \\\"fix bug\\\"\"}");
    switch (decoded) {
        .input => |input| {
            defer input.deinit(alloc);
            try std.testing.expectEqualStrings("workflow", input.as(Input).name.?);
            try std.testing.expectEqualStrings("-m \"fix bug\"", input.as(Input).args.?);
            try std.testing.expect(input.as(Input).location == null);
        },
        .failure => |body| {
            defer alloc.free(body);
            return error.TestExpectedSkillInput;
        },
    }
}

test "skill tool decodes only valid argument shapes" {
    try expectDecodeFailure("{", "skill arguments must be valid JSON");
    try expectDecodeFailure("[]", "skill arguments must be an object");
    try expectDecodeFailure("{}", "skill requires the name of a skill from the skill list");
    try expectDecodeFailure("{\"skill\":\"\"}", "skill field \"skill\" must be a non-empty string");
    try expectDecodeFailure("{\"skill\":1}", "skill field \"skill\" must be a non-empty string");
    try expectDecodeFailure("{\"skill\":\"workflow\",\"args\":1}", "skill field \"args\" must be a string");
    try expectDecodeFailure("{\"skill\":\"workflow\",\"location\":\"/installed/workflow\"}", "skill field \"location\" does not apply. Skill takes skill and args.");
    try expectDecodeFailure("{\"skill\":\"workflow\",\"resource\":\"SKILL.md\"}", "skill field \"resource\" does not apply. Skill takes skill and args.");
    try expectDecodeFailure("{\"name\":\"workflow\"}", "skill field \"name\" does not apply. Skill takes skill and args.");
}

fn checkDecodeAllocationFailures(alloc: Allocator) !void {
    const decoded = try decode(
        .{ .allocator = alloc },
        "{\"skill\":\"workflow\",\"args\":\"fix\"}",
    );
    switch (decoded) {
        .input => |input| input.deinit(alloc),
        .failure => |body| {
            alloc.free(body);
            return error.TestExpectedDecodedInput;
        },
    }
}

test "skill tool decode cleans allocation failures" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        checkDecodeAllocationFailures,
        .{},
    );
}

test "skill presentation keeps the default label for every call" {
    for ([_][]const u8{ "{\"skill\":\"workflow\"}", "{\"skill\":\"workflow\",\"args\":\"fix\"}" }) |args| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, args, .{});
        defer parsed.deinit();
        try std.testing.expect(presentation(parsed.value.object) == null);
    }
}
