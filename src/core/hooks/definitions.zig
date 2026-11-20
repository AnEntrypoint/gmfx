const std = @import("std");
const types = @import("../shared/types.zig");
const external = @import("external.zig");

pub const HookKind = enum {
    pre_tool_use,
    stop,
    post_turn_end,
    attention_required,
    user_prompt_submit,
    observation,

    pub fn definition(self: HookKind) HookDefinition {
        return switch (self) {
            .pre_tool_use => pre_tool_use,
            .stop => stop,
            .post_turn_end => post_turn_end,
            .attention_required => attention_required,
            .user_prompt_submit => user_prompt_submit,
            .observation => observation,
        };
    }
};

pub const HookDefinition = struct {
    kind: HookKind,
    lifecycle_event: []const u8,
    agent_loop_point: []const u8,
    purpose: []const u8,
};

pub const pre_tool_use = HookDefinition{
    .kind = .pre_tool_use,
    .lifecycle_event = "PreToolUse",
    .agent_loop_point = "before local tool validation, permissions, and execution",
    .purpose = "lets handlers keep a call unchanged, rewrite its arguments, or block it",
};

pub const stop = HookDefinition{
    .kind = .stop,
    .lifecycle_event = "Stop",
    .agent_loop_point = "after a terminal assistant candidate before turn finalization",
    .purpose = "lets handlers allow completion or request one synthetic continuation",
};

pub const post_turn_end = HookDefinition{
    .kind = .post_turn_end,
    .lifecycle_event = "PostTurnEnd",
    .agent_loop_point = "after a terminal turn outcome is accepted",
    .purpose = "lets handlers observe terminal turns and run side effects without changing the turn outcome",
};

pub const attention_required = HookDefinition{
    .kind = .attention_required,
    .lifecycle_event = "AttentionRequired",
    .agent_loop_point = "after a user decision prompt becomes active",
    .purpose = "lets handlers observe when a foreground turn is waiting for user attention",
};

pub const user_prompt_submit = HookDefinition{
    .kind = .user_prompt_submit,
    .lifecycle_event = "UserPromptSubmit",
    .agent_loop_point = "before a user prompt is submitted to the transcript and the model",
    .purpose = "lets handlers append text to the prompt or block the prompt before the model call",
};

pub const observation = HookDefinition{
    .kind = .observation,
    .lifecycle_event = "ExternalObservation",
    .agent_loop_point = "at the external observation points for tools, permissions, prompts, turns, sessions, subagents, tasks, compaction, and notifications",
    .purpose = "lets handlers observe one external hook event with its payload without changing the outcome",
};

pub const all_hooks = [_]HookDefinition{
    pre_tool_use,
    stop,
    post_turn_end,
    attention_required,
    user_prompt_submit,
    observation,
};

pub const ScopeKind = enum {
    interactive,
    ask,
    acp,
    subagent,
};

pub const Scope = struct {
    kind: ScopeKind,
    workspace_root: []const u8,
    session_id: ?[]const u8 = null,
    subagent_id: ?u64 = null,
    session_title: ?[]const u8 = null,
};

pub const Invocation = struct {
    scope: Scope,
    turn_id: ?u64 = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,
};

pub const Limits = struct {
    pub const handler_name_bytes = 128;
    pub const reason_bytes = 4 * 1024;
    pub const context_bytes = 64 * 1024;
    pub const arguments_json_bytes = 1024 * 1024;
};

pub const RegistrationError = error{
    EmptyHandlerName,
    HandlerNameTooLong,
    InvalidHandlerName,
    DuplicateHandlerName,
    RuntimeFrozen,
};

pub const ViewError = error{
    RuntimeNotFrozen,
};

pub const HandlerError = error{
    Failed,
    Cancelled,
};

pub const MutationDispatchError = error{
    OutOfMemory,
    HandlerFailed,
    Cancelled,
    InvalidHandlerOutput,
    HandlerOutputTooLarge,
};

pub const PreToolUseInput = struct {
    invocation: Invocation,
    step_index: usize,
    call_id: []const u8,
    tool_name: []const u8,
    arguments_json: []const u8,
};

pub const PreToolUseAction = union(enum) {
    continue_,
    rewrite_arguments: []const u8,
    block: []const u8,
};

pub const PreToolUseOutcome = union(enum) {
    unchanged,
    rewritten: []u8,
    blocked: []u8,

    pub fn deinit(self: *PreToolUseOutcome, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .rewritten => |arguments_json| alloc.free(arguments_json),
            .blocked => |reason| alloc.free(reason),
            .unchanged => {},
        }
        self.* = .unchanged;
    }
};

pub const PreToolUseHandler = struct {
    name: []const u8,
    ctx: *anyopaque,
    run: *const fn (
        ctx: *anyopaque,
        input: PreToolUseInput,
    ) HandlerError!PreToolUseAction,
};

pub const StopInput = struct {
    invocation: Invocation,
    step_index: usize,
    assistant_text: []const u8,
    provider_disposition: types.ProviderCompletionDisposition,
    can_continue: bool,
};

pub const StopAction = union(enum) {
    allow,
    continue_once: []const u8,
};

pub const StopOutcome = union(enum) {
    allow,
    continue_once: []u8,

    pub fn deinit(self: *StopOutcome, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .continue_once => |context| alloc.free(context),
            .allow => {},
        }
        self.* = .allow;
    }
};

pub const StopHandler = struct {
    name: []const u8,
    ctx: *anyopaque,
    run: *const fn (
        ctx: *anyopaque,
        input: StopInput,
    ) HandlerError!StopAction,
    applies: ?*const fn (ctx: *anyopaque, invocation: Invocation) bool = null,
};

pub const PostTurnEndInput = struct {
    invocation: Invocation,
    outcome: types.TurnPresentationOutcome,
    provider_disposition: ?types.ProviderCompletionDisposition = null,
    error_name: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

pub const PostTurnEndHandler = struct {
    name: []const u8,
    ctx: *anyopaque,
    run: *const fn (
        ctx: *anyopaque,
        input: PostTurnEndInput,
    ) HandlerError!void,
};

pub const AttentionKind = enum {
    permission,
    question,
    route_recovery,
    limit,
};

pub const AttentionRequiredInput = struct {
    invocation: Invocation,
    kind: AttentionKind,
};

pub const AttentionRequiredHandler = struct {
    name: []const u8,
    ctx: *anyopaque,
    run: *const fn (
        ctx: *anyopaque,
        input: AttentionRequiredInput,
    ) HandlerError!void,
};

pub const UserPromptSubmitInput = struct {
    invocation: Invocation,
    prompt_text: []const u8,
    is_steer: bool,
};

pub const UserPromptSubmitAction = union(enum) {
    allow,
    append: []const u8,
    block: []const u8,
};

pub const UserPromptSubmitHandler = struct {
    name: []const u8,
    ctx: *anyopaque,
    run: *const fn (
        ctx: *anyopaque,
        input: UserPromptSubmitInput,
    ) HandlerError!UserPromptSubmitAction,
};

pub const ObservationOutcome = struct {
    alloc: std.mem.Allocator,
    blocked: bool = false,
    reason: ?[]u8 = null,
    additional_context: ?[]u8 = null,
    updated_tool_output: ?[]u8 = null,

    pub fn deinit(self: *ObservationOutcome) void {
        if (self.reason) |reason| self.alloc.free(reason);
        if (self.additional_context) |context| self.alloc.free(context);
        if (self.updated_tool_output) |output| self.alloc.free(output);
        const alloc = self.alloc;
        self.* = .{ .alloc = alloc };
    }
};

pub const ObservationInput = struct {
    invocation: Invocation,
    event: external.Event,
    matcher_value: []const u8 = "",
    fields: []const external.Field = &.{},
    outcome: ?*ObservationOutcome = null,
};

pub const ObservationHandler = struct {
    name: []const u8,
    ctx: *anyopaque,
    run: *const fn (
        ctx: *anyopaque,
        input: ObservationInput,
    ) HandlerError!void,
};

test "hook definitions enumerate current hook surfaces" {
    try std.testing.expectEqual(@as(usize, 6), all_hooks.len);
    try std.testing.expectEqual(HookKind.pre_tool_use, all_hooks[0].kind);
    try std.testing.expectEqual(HookKind.stop, all_hooks[1].kind);
    try std.testing.expectEqual(HookKind.post_turn_end, all_hooks[2].kind);
    try std.testing.expectEqual(HookKind.attention_required, all_hooks[3].kind);
    try std.testing.expectEqual(HookKind.user_prompt_submit, all_hooks[4].kind);
    try std.testing.expectEqual(HookKind.observation, all_hooks[5].kind);
    try std.testing.expectEqualStrings("UserPromptSubmit", HookKind.user_prompt_submit.definition().lifecycle_event);
    try std.testing.expectEqualStrings("ExternalObservation", HookKind.observation.definition().lifecycle_event);
    try std.testing.expectEqualStrings("PreToolUse", pre_tool_use.lifecycle_event);
    try std.testing.expectEqualStrings("Stop", stop.lifecycle_event);
    try std.testing.expectEqualStrings("PostTurnEnd", post_turn_end.lifecycle_event);
    try std.testing.expectEqualStrings("AttentionRequired", attention_required.lifecycle_event);
    try std.testing.expectEqual(HookKind.pre_tool_use, HookKind.pre_tool_use.definition().kind);
    try std.testing.expectEqual(HookKind.stop, HookKind.stop.definition().kind);
    try std.testing.expectEqual(HookKind.post_turn_end, HookKind.post_turn_end.definition().kind);
    try std.testing.expectEqual(HookKind.attention_required, HookKind.attention_required.definition().kind);
    try std.testing.expectEqualStrings("PreToolUse", HookKind.pre_tool_use.definition().lifecycle_event);
    try std.testing.expectEqualStrings("Stop", HookKind.stop.definition().lifecycle_event);
    try std.testing.expectEqualStrings("PostTurnEnd", HookKind.post_turn_end.definition().lifecycle_event);
    try std.testing.expectEqualStrings("AttentionRequired", HookKind.attention_required.definition().lifecycle_event);
    try std.testing.expect(pre_tool_use.agent_loop_point.len > 0);
    try std.testing.expect(pre_tool_use.purpose.len > 0);
    try std.testing.expect(stop.agent_loop_point.len > 0);
    try std.testing.expect(stop.purpose.len > 0);
    try std.testing.expect(post_turn_end.agent_loop_point.len > 0);
    try std.testing.expect(post_turn_end.purpose.len > 0);
    try std.testing.expect(attention_required.agent_loop_point.len > 0);
    try std.testing.expect(attention_required.purpose.len > 0);
}

test "Hooks v1.0 scope kinds remain limited to the current surfaces" {
    try std.testing.expectEqual(@as(usize, 4), @typeInfo(ScopeKind).@"enum".field_names.len);
}

test "an observation outcome frees what a handler stored and can be reused" {
    var outcome: ObservationOutcome = .{ .alloc = std.testing.allocator };
    outcome.blocked = true;
    outcome.reason = try std.testing.allocator.dupe(u8, "no");
    outcome.additional_context = try std.testing.allocator.dupe(u8, "context");
    outcome.updated_tool_output = try std.testing.allocator.dupe(u8, "output");
    outcome.deinit();
    try std.testing.expect(!outcome.blocked);
    try std.testing.expect(outcome.reason == null);
    const input: ObservationInput = .{
        .invocation = .{ .scope = .{ .kind = .interactive, .workspace_root = "/tmp" } },
        .event = .PostToolUse,
    };
    try std.testing.expect(input.outcome == null);
}
