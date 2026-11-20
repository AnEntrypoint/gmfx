const std = @import("std");
const builtin = @import("builtin");
const hooks = @import("../../core/hooks/hooks.zig");
const external = @import("../../core/hooks/external.zig");
const external_run = @import("../../core/hooks/external_run.zig");
const io_mod = @import("../../core/shared/io.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const types = @import("../../core/shared/types.zig");
const permission_prompter = @import("../../core/permissions/permission_prompter.zig");
const permission_request = @import("../../core/permissions/permission_request.zig");

const Allocator = std.mem.Allocator;

pub const State = struct {
    definitions: ?[]external.Definition = null,
    retained: ?[]u8 = null,
    continued_turn: ?u64 = null,
    failure_warned: bool = false,
    pending_notice: ?[]u8 = null,
    session_id: ?[]u8 = null,
    session_title: ?[]u8 = null,
    last_resolution: ?external.Resolution = null,
    session_context: ?[]u8 = null,
    initial_user_message: ?[]u8 = null,
    transcript_path: ?[]u8 = null,
    permission_mode: ?[]u8 = null,
    permission_answer: ?PermissionAnswer = null,
    forced_ask_call: ?[]u8 = null,
    dispatch_mutex: std.Io.Mutex = .init,
    notice_mutex: std.Io.Mutex = .init,
    session_mutex: std.Io.Mutex = .init,
    answer_mutex: std.Io.Mutex = .init,

    pub fn replaceDefinitions(self: *State, alloc: Allocator, definitions: ?[]external.Definition) void {
        const io = io_mod.getIo();
        self.dispatch_mutex.lockUncancelable(io);
        defer self.dispatch_mutex.unlock(io);
        if (self.definitions) |old| external.freeDefinitions(alloc, old);
        self.definitions = definitions;
    }

    pub fn noteSession(self: *State, alloc: Allocator, session_id: ?[]const u8, session_title: []const u8) void {
        const io = io_mod.getIo();
        self.session_mutex.lockUncancelable(io);
        defer self.session_mutex.unlock(io);
        replaceText(alloc, &self.session_id, session_id orelse "");
        replaceText(alloc, &self.session_title, session_title);
    }

    pub fn noteSessionTitle(self: *State, alloc: Allocator, session_title: []const u8) void {
        const io = io_mod.getIo();
        self.session_mutex.lockUncancelable(io);
        defer self.session_mutex.unlock(io);
        replaceText(alloc, &self.session_title, session_title);
    }

    pub fn notedSessionIs(self: *State, session_id: ?[]const u8) bool {
        const io = io_mod.getIo();
        self.session_mutex.lockUncancelable(io);
        defer self.session_mutex.unlock(io);
        const noted: []const u8 = if (self.session_id) |owned| owned else "";
        return std.mem.eql(u8, noted, session_id orelse "");
    }

    pub fn noteTranscriptPath(self: *State, alloc: Allocator, transcript_path: []const u8) void {
        const io = io_mod.getIo();
        self.session_mutex.lockUncancelable(io);
        defer self.session_mutex.unlock(io);
        replaceText(alloc, &self.transcript_path, transcript_path);
    }

    pub fn notePermissionMode(self: *State, alloc: Allocator, permission_mode: []const u8) void {
        const io = io_mod.getIo();
        self.session_mutex.lockUncancelable(io);
        defer self.session_mutex.unlock(io);
        replaceText(alloc, &self.permission_mode, permission_mode);
    }

    fn noteSessionStartOutput(self: *State, alloc: Allocator, context: []const u8, initial_user_message: ?[]u8) void {
        const io = io_mod.getIo();
        self.session_mutex.lockUncancelable(io);
        defer self.session_mutex.unlock(io);
        if (context.len != 0) replaceText(alloc, &self.session_context, context);
        if (initial_user_message) |message| {
            if (self.initial_user_message) |old| alloc.free(old);
            self.initial_user_message = message;
        }
    }

    pub fn takeSessionContext(self: *State) ?[]u8 {
        const io = io_mod.getIo();
        self.session_mutex.lockUncancelable(io);
        defer self.session_mutex.unlock(io);
        const context = self.session_context;
        self.session_context = null;
        return context;
    }

    pub fn takeInitialUserMessage(self: *State) ?[]u8 {
        const io = io_mod.getIo();
        self.session_mutex.lockUncancelable(io);
        defer self.session_mutex.unlock(io);
        const message = self.initial_user_message;
        self.initial_user_message = null;
        return message;
    }

    fn notePermissionAnswer(self: *State, alloc: Allocator, call_id: []const u8, behavior: external.PermissionBehavior, reason: ?[]const u8) void {
        const io = io_mod.getIo();
        self.answer_mutex.lockUncancelable(io);
        defer self.answer_mutex.unlock(io);
        const owned_call = alloc.dupe(u8, call_id) catch return;
        const feedback: ?[]u8 = if (reason) |text| alloc.dupe(u8, text) catch null else null;
        if (self.permission_answer) |*old| old.deinit();
        self.permission_answer = .{
            .alloc = alloc,
            .call_id = owned_call,
            .decision = switch (behavior) {
                .allow => .once,
                .deny => .deny,
            },
            .feedback = feedback,
        };
    }

    fn noteForcedAsk(self: *State, alloc: Allocator, call_id: ?[]const u8) void {
        const io = io_mod.getIo();
        self.answer_mutex.lockUncancelable(io);
        defer self.answer_mutex.unlock(io);
        replaceText(alloc, &self.forced_ask_call, call_id orelse "");
    }

    pub fn hookAnswers(self: *State) permission_prompter.HookAnswers {
        return .{ .context = self, .take_fn = takePermissionAnswer, .asks_fn = asksForPrompt };
    }

    fn takePermissionAnswer(raw: *anyopaque, alloc: Allocator, call_id: []const u8) ?permission_request.OwnedPermissionResponse {
        const self: *State = @ptrCast(@alignCast(raw));
        const io = io_mod.getIo();
        self.answer_mutex.lockUncancelable(io);
        defer self.answer_mutex.unlock(io);
        var answer = self.permission_answer orelse return null;
        if (!std.mem.eql(u8, answer.call_id, call_id)) return null;
        self.permission_answer = null;
        defer answer.deinit();
        const feedback: ?[]u8 = if (answer.feedback) |text| alloc.dupe(u8, text) catch null else null;
        return permission_request.OwnedPermissionResponse.init(alloc, answer.decision, feedback);
    }

    fn asksForPrompt(raw: *anyopaque, call_id: []const u8) bool {
        const self: *State = @ptrCast(@alignCast(raw));
        const io = io_mod.getIo();
        self.answer_mutex.lockUncancelable(io);
        defer self.answer_mutex.unlock(io);
        const forced = self.forced_ask_call orelse return false;
        return std.mem.eql(u8, forced, call_id);
    }

    fn replaceText(alloc: Allocator, slot: *?[]u8, text: []const u8) void {
        const next: ?[]u8 = if (text.len == 0) null else alloc.dupe(u8, text) catch return;
        if (slot.*) |old| alloc.free(old);
        slot.* = next;
    }

    fn sessionFacts(self: *State, alloc: Allocator, scope: hooks.Scope) Allocator.Error!SessionFacts {
        const io = io_mod.getIo();
        self.session_mutex.lockUncancelable(io);
        defer self.session_mutex.unlock(io);
        const noted_id: []const u8 = if (self.session_id) |owned| owned else "";
        const noted_title: []const u8 = if (self.session_title) |owned| owned else "";
        const scope_title: []const u8 = scope.session_title orelse "";
        const session_id = try alloc.dupe(u8, scope.session_id orelse noted_id);
        errdefer alloc.free(session_id);
        const noted_title_applies = scope.kind == .subagent or scope.session_id == null or std.mem.eql(u8, scope.session_id.?, noted_id);
        const fallback_title: []const u8 = if (noted_title_applies) noted_title else "";
        const title = try alloc.dupe(u8, if (scope_title.len != 0) scope_title else fallback_title);
        errdefer alloc.free(title);
        const transcript_path = try alloc.dupe(u8, if (self.transcript_path) |owned| owned else "");
        errdefer alloc.free(transcript_path);
        const permission_mode = try alloc.dupe(u8, if (self.permission_mode) |owned| owned else "");
        return .{
            .session_id = session_id,
            .session_title = title,
            .transcript_path = transcript_path,
            .permission_mode = permission_mode,
        };
    }

    pub fn takeNotice(self: *State) ?[]u8 {
        const io = io_mod.getIo();
        self.notice_mutex.lockUncancelable(io);
        defer self.notice_mutex.unlock(io);
        const notice = self.pending_notice;
        self.pending_notice = null;
        return notice;
    }

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.replaceDefinitions(alloc, null);
        if (self.retained) |text| alloc.free(text);
        if (self.pending_notice) |notice| alloc.free(notice);
        if (self.session_id) |session_id| alloc.free(session_id);
        if (self.session_title) |session_title| alloc.free(session_title);
        if (self.session_context) |context| alloc.free(context);
        if (self.initial_user_message) |message| alloc.free(message);
        if (self.transcript_path) |transcript_path| alloc.free(transcript_path);
        if (self.permission_mode) |permission_mode| alloc.free(permission_mode);
        if (self.permission_answer) |*answer| answer.deinit();
        if (self.forced_ask_call) |call_id| alloc.free(call_id);
        self.* = .{};
    }
};

const PermissionAnswer = struct {
    alloc: Allocator,
    call_id: []u8,
    decision: types.ToolPermissionDecision,
    feedback: ?[]u8 = null,

    fn deinit(self: *PermissionAnswer) void {
        self.alloc.free(self.call_id);
        if (self.feedback) |feedback| self.alloc.free(feedback);
        self.* = undefined;
    }
};

pub const SessionOpening = struct {
    session_id: ?[]const u8,
    session_title: []const u8 = "",
    source: external.SessionSource = .startup,
    model: []const u8,
    profile: ?[]const u8 = null,
};

const SessionFacts = struct {
    session_id: []u8,
    session_title: []u8,
    transcript_path: []u8,
    permission_mode: []u8,

    fn deinit(self: *SessionFacts, alloc: Allocator) void {
        alloc.free(self.session_id);
        alloc.free(self.session_title);
        alloc.free(self.transcript_path);
        alloc.free(self.permission_mode);
        self.* = undefined;
    }
};

const HookRun = struct {
    alloc: Allocator,
    definition: *const external.Definition,
    cwd: []const u8,
    payload: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    outcome: external_run.Outcome = .{},
    out_of_memory: bool = false,

    fn execute(self: *HookRun) void {
        self.outcome = external_run.runWithin(
            self.alloc,
            self.definition.command,
            self.cwd,
            self.definition.env,
            self.definition.deadlineMs(),
            self.payload,
            self.cancel_flag,
        ) catch {
            self.out_of_memory = true;
            return;
        };
    }
};

const Offer = struct {
    kimi: ?Side,
    claude: ?Side,

    const Side = struct {
        matcher_value: []const u8,
        fields: []const external.Field,
    };

    fn matchValues(self: Offer) external.MatchValues {
        return .{
            .kimi = if (self.kimi) |side| side.matcher_value else null,
            .claude = if (self.claude) |side| side.matcher_value else null,
        };
    }

    fn sidesShareFields(self: Offer) bool {
        const kimi_side = self.kimi orelse return false;
        const claude_side = self.claude orelse return false;
        return kimi_side.fields.ptr == claude_side.fields.ptr and kimi_side.fields.len == claude_side.fields.len;
    }
};

const runs_in_parallel = !builtin.single_threaded and builtin.target.os.tag != .wasi;
const task_completed_notification = "task.completed";
const permission_prompt_notification = "permission_prompt";
const idle_prompt_notification = "idle_prompt";
const elicitation_dialog_notification = "elicitation_dialog";

fn executeAll(alloc: Allocator, runs: []HookRun) void {
    if (comptime runs_in_parallel) {
        executeConcurrently(alloc, runs);
    } else {
        executeInOrder(runs);
    }
}

fn executeInOrder(runs: []HookRun) void {
    for (runs) |*hook_run| hook_run.execute();
}

fn executeConcurrently(alloc: Allocator, runs: []HookRun) void {
    if (runs.len == 1) return runs[0].execute();
    const threads = alloc.alloc(?std.Thread, runs.len - 1) catch return executeInOrder(runs);
    defer alloc.free(threads);
    for (runs[1..], threads) |*hook_run, *thread| {
        thread.* = std.Thread.spawn(.{}, HookRun.execute, .{hook_run}) catch null;
    }
    runs[0].execute();
    for (runs[1..], threads) |*hook_run, thread| {
        if (thread) |spawned| spawned.join() else hook_run.execute();
    }
}

const Settled = struct {
    blocked: ?external.Verdict = null,
    appended: std.ArrayList(u8) = .empty,
    rewritten: ?[]u8 = null,
    permission: ?external.PermissionDecision = null,
    permission_behavior: ?external.PermissionBehavior = null,
    permission_reason: ?[]u8 = null,
    stop_requested: bool = false,
    additional_context: std.ArrayList(u8) = .empty,
    updated_tool_output: ?[]u8 = null,
    initial_user_message: ?[]u8 = null,

    fn deinit(self: *Settled, alloc: Allocator) void {
        if (self.blocked) |*verdict| verdict.deinit(alloc);
        self.appended.deinit(alloc);
        if (self.rewritten) |arguments_json| alloc.free(arguments_json);
        if (self.permission_reason) |reason| alloc.free(reason);
        self.additional_context.deinit(alloc);
        if (self.updated_tool_output) |output| alloc.free(output);
        if (self.initial_user_message) |message| alloc.free(message);
        self.* = .{};
    }

    fn asksForPrompt(self: *const Settled) bool {
        if (self.blocked != null) return false;
        const decision = self.permission orelse return false;
        return decision == .ask;
    }

    fn takeInitialUserMessage(self: *Settled) ?[]u8 {
        const message = self.initial_user_message;
        self.initial_user_message = null;
        return message;
    }

    fn settlePermissionRequest(self: *Settled, alloc: Allocator, verdict: *external.Verdict) void {
        const behavior = verdict.permission_behavior orelse return;
        const held_denies = if (self.permission_behavior) |held| held == .deny else false;
        if (self.permission_behavior != null and (held_denies or behavior != .deny)) return;
        self.permission_behavior = behavior;
        if (self.permission_reason) |old| alloc.free(old);
        self.permission_reason = verdict.reason;
        verdict.reason = null;
    }

    fn fill(self: *const Settled, outcome: *hooks.ObservationOutcome) void {
        if (self.blocked) |verdict| {
            outcome.blocked = true;
            const reason: []const u8 = if (verdict.reason) |owned| owned else "";
            if (outcome.reason == null) outcome.reason = outcome.alloc.dupe(u8, reason) catch null;
        }
        if (self.additional_context.items.len != 0 and outcome.additional_context == null) {
            outcome.additional_context = outcome.alloc.dupe(u8, self.additional_context.items) catch null;
        }
        if (self.updated_tool_output) |output| {
            if (outcome.updated_tool_output == null) outcome.updated_tool_output = outcome.alloc.dupe(u8, output) catch null;
        }
    }

    fn takeBlockReason(self: *Settled) ?[]u8 {
        if (self.blocked) |*verdict| {
            const reason = verdict.reason;
            verdict.reason = null;
            return reason;
        }
        return null;
    }

    fn takeRewrite(self: *Settled) ?[]u8 {
        const arguments_json = self.rewritten;
        self.rewritten = null;
        return arguments_json;
    }
};

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn configure(app: *App) !void {
            const definitions = app.command_hooks.definitions orelse return;
            if (external.hasEvent(definitions, .PreToolUse)) {
                try app.lifecycle_runtime.registerPreToolUse(.{
                    .name = "fx.command.pre_tool_use",
                    .ctx = app,
                    .run = preToolUse,
                });
            }
            if (external.hasEvent(definitions, .Stop)) {
                try app.lifecycle_runtime.registerStop(.{
                    .name = "fx.command.stop",
                    .ctx = app,
                    .run = stop,
                });
            }
            if (external.hasEvent(definitions, .Notification)) {
                try app.lifecycle_runtime.registerAttentionRequired(.{
                    .name = "fx.command.attention_required",
                    .ctx = app,
                    .run = attentionRequired,
                });
            }
            if (external.hasEvent(definitions, .StopFailure) or external.hasEvent(definitions, .Interrupt) or external.hasEvent(definitions, .Notification)) {
                try app.lifecycle_runtime.registerPostTurnEnd(.{
                    .name = "fx.command.post_turn_end",
                    .ctx = app,
                    .run = postTurnEnd,
                });
            }
            if (external.hasEvent(definitions, .UserPromptSubmit) or external.hasEvent(definitions, .SessionStart)) {
                try app.lifecycle_runtime.registerUserPromptSubmit(.{
                    .name = "fx.command.user_prompt_submit",
                    .ctx = app,
                    .run = userPromptSubmit,
                });
            }
            if (hasObservation(definitions)) {
                try app.lifecycle_runtime.registerObservation(.{
                    .name = "fx.command.observation",
                    .ctx = app,
                    .run = observation,
                });
            }
        }

        fn hasObservation(definitions: []const external.Definition) bool {
            for (definitions) |definition| {
                if (definition.event.observation()) return true;
            }
            return false;
        }

        pub fn fire(
            app: *App,
            event: external.Event,
            matcher_value: []const u8,
            scope: hooks.Scope,
            fields: []const external.Field,
            cancel_flag: ?*std.atomic.Value(bool),
        ) void {
            observe(app, event, matcher_value, scope, fields, cancel_flag);
        }

        pub fn openSession(app: *App, scope: hooks.Scope, opening: SessionOpening) void {
            app.command_hooks.noteSession(app.alloc, opening.session_id, opening.session_title);
            const claude_fields = external.sessionStartFields(opening.source, opening.model, opening.profile);
            const kimi_fields = external.sessionStartFieldsNamed(opening.source.kimiName() orelse "", opening.model, opening.profile);
            var settled = dispatchOffer(app, .SessionStart, .{
                .kimi = if (opening.source.kimiName()) |name| .{ .matcher_value = name, .fields = &kimi_fields } else null,
                .claude = .{ .matcher_value = @tagName(opening.source), .fields = &claude_fields },
            }, scope, null) catch return;
            defer settled.deinit(app.alloc);
            app.command_hooks.noteSessionStartOutput(app.alloc, settled.additional_context.items, settled.takeInitialUserMessage());
        }

        pub fn closeSession(app: *App, scope: hooks.Scope, reason: external.SessionEndReason) void {
            const fields = [_]external.Field{
                .{ .key = "reason", .value = .{ .string = @tagName(reason) } },
            };
            observe(app, .SessionEnd, @tagName(reason), scope, &fields, null);
        }

        pub fn switchSession(app: *App, scope: hooks.Scope, opening: SessionOpening) void {
            if (app.command_hooks.notedSessionIs(opening.session_id)) return;
            if (opening.source.kimiName() != null) closeSession(app, scope, .exit);
            openSession(app, scope, opening);
        }

        fn sessionCompacted(app: *App, scope: hooks.Scope) void {
            if (scope.kind == .subagent) return;
            const fields = [_]external.Field{
                .{ .key = "source", .value = .{ .string = @tagName(external.SessionSource.compact) } },
            };
            var settled = dispatchOffer(app, .SessionStart, .{
                .kimi = null,
                .claude = .{ .matcher_value = @tagName(external.SessionSource.compact), .fields = &fields },
            }, scope, null) catch return;
            defer settled.deinit(app.alloc);
            app.command_hooks.noteSessionStartOutput(app.alloc, settled.additional_context.items, settled.takeInitialUserMessage());
        }

        fn preToolUse(ctx: *anyopaque, input: hooks.PreToolUseInput) hooks.HandlerError!hooks.PreToolUseAction {
            const app: *App = @ptrCast(@alignCast(ctx));
            var arena = std.heap.ArenaAllocator.init(app.alloc);
            defer arena.deinit();
            const fields = [_]external.Field{
                .{ .key = "tool_name", .value = .{ .string = input.tool_name } },
                .{ .key = "tool_input", .value = parseToolInput(arena.allocator(), input.arguments_json) },
                .{ .key = "tool_call_id", .value = .{ .string = input.call_id } },
            };
            var settled = dispatch(app, .PreToolUse, input.tool_name, input.invocation.scope, &fields, input.invocation.cancel_flag) catch return .continue_;
            defer settled.deinit(app.alloc);
            app.command_hooks.noteForcedAsk(app.alloc, if (settled.asksForPrompt()) input.call_id else null);
            if (settled.stop_requested) requestStop(input.invocation.cancel_flag);
            if (settled.takeBlockReason()) |reason| return .{ .block = retain(app, reason) };
            if (settled.takeRewrite()) |arguments_json| return .{ .rewrite_arguments = retain(app, arguments_json) };
            return .continue_;
        }

        fn stop(ctx: *anyopaque, input: hooks.StopInput) hooks.HandlerError!hooks.StopAction {
            const app: *App = @ptrCast(@alignCast(ctx));
            if (!input.can_continue) return .allow;
            const turn_id = input.invocation.turn_id orelse return .allow;
            if (app.command_hooks.continued_turn == turn_id) return .allow;
            const fields = [_]external.Field{
                .{ .key = "stop_hook_active", .value = .{ .bool = false } },
            };
            var settled = dispatch(app, .Stop, "", input.invocation.scope, &fields, input.invocation.cancel_flag) catch return .allow;
            defer settled.deinit(app.alloc);
            const reason = settled.takeBlockReason() orelse return .allow;
            app.command_hooks.continued_turn = turn_id;
            return .{ .continue_once = retain(app, reason) };
        }

        fn userPromptSubmit(ctx: *anyopaque, input: hooks.UserPromptSubmitInput) hooks.HandlerError!hooks.UserPromptSubmitAction {
            const app: *App = @ptrCast(@alignCast(ctx));
            const fields = [_]external.Field{
                .{ .key = "prompt", .value = .{ .string = input.prompt_text } },
                .{ .key = "is_steer", .value = .{ .bool = input.is_steer } },
            };
            var settled = dispatch(app, .UserPromptSubmit, input.prompt_text, input.invocation.scope, &fields, input.invocation.cancel_flag) catch return .allow;
            defer settled.deinit(app.alloc);
            if (settled.blocked) |verdict| {
                const text = external.renderBlockedPrompt(app.alloc, verdict) catch return .allow;
                return .{ .block = retain(app, text) };
            }
            var combined: std.ArrayList(u8) = .empty;
            defer combined.deinit(app.alloc);
            if (input.invocation.scope.kind != .subagent) {
                if (app.command_hooks.takeSessionContext()) |context| {
                    defer app.alloc.free(context);
                    appendHookResult(app.alloc, &combined, .SessionStart, context) catch return .allow;
                }
            }
            if (settled.additional_context.items.len != 0) {
                appendHookResult(app.alloc, &combined, .UserPromptSubmit, settled.additional_context.items) catch return .allow;
            }
            if (settled.appended.items.len != 0) {
                appendParagraph(app.alloc, &combined, settled.appended.items) catch return .allow;
            }
            if (combined.items.len == 0) return .allow;
            const text = combined.toOwnedSlice(app.alloc) catch return .allow;
            return .{ .append = retain(app, text) };
        }

        fn postTurnEnd(ctx: *anyopaque, input: hooks.PostTurnEndInput) hooks.HandlerError!void {
            const app: *App = @ptrCast(@alignCast(ctx));
            switch (input.outcome) {
                .failed => {
                    const error_type: []const u8 = input.error_name orelse if (input.provider_disposition) |disposition| @tagName(disposition) else "failed";
                    const fields = [_]external.Field{
                        .{ .key = "error_type", .value = .{ .string = error_type } },
                        .{ .key = "error_message", .value = .{ .string = input.error_message orelse "" } },
                    };
                    observe(app, .StopFailure, error_type, input.invocation.scope, &fields, input.invocation.cancel_flag);
                },
                .interrupted => {
                    const fields = [_]external.Field{
                        .{ .key = "turn_id", .value = .{ .integer = @intCast(input.invocation.turn_id orelse 0) } },
                        .{ .key = "reason", .value = .{ .string = "cancelled" } },
                    };
                    observe(app, .Interrupt, "", input.invocation.scope, &fields, input.invocation.cancel_flag);
                },
                .completed => {
                    if (input.invocation.scope.kind != .interactive) return;
                    notifyWaiting(app, input.invocation, idle_prompt_notification, "fx is waiting for your input");
                },
                .paused => {},
            }
        }

        fn attentionRequired(ctx: *anyopaque, input: hooks.AttentionRequiredInput) hooks.HandlerError!void {
            const app: *App = @ptrCast(@alignCast(ctx));
            switch (input.kind) {
                .permission => notifyWaiting(app, input.invocation, permission_prompt_notification, "fx needs your permission to use a tool"),
                .question => notifyWaiting(app, input.invocation, elicitation_dialog_notification, "fx is waiting for your answer"),
                .route_recovery, .limit => notifyWaiting(app, input.invocation, @tagName(input.kind), "fx needs your attention"),
            }
        }

        fn notifyWaiting(app: *App, invocation: hooks.Invocation, notification_type: []const u8, message: []const u8) void {
            const fields = [_]external.Field{
                .{ .key = "notification_type", .value = .{ .string = notification_type } },
                .{ .key = "message", .value = .{ .string = message } },
            };
            observe(app, .Notification, notification_type, invocation.scope, &fields, invocation.cancel_flag);
        }

        fn observation(ctx: *anyopaque, input: hooks.ObservationInput) hooks.HandlerError!void {
            const app: *App = @ptrCast(@alignCast(ctx));
            var settled = dispatch(app, input.event, input.matcher_value, input.invocation.scope, input.fields, input.invocation.cancel_flag) catch return;
            defer settled.deinit(app.alloc);
            if (input.event == .PermissionRequest) {
                if (settled.permission_behavior) |behavior| {
                    if (toolCallId(input.fields)) |call_id| {
                        app.command_hooks.notePermissionAnswer(app.alloc, call_id, behavior, settled.permission_reason);
                    }
                }
            }
            if (settled.stop_requested and stopsTheTurn(input.event)) requestStop(input.invocation.cancel_flag);
            if (input.outcome) |outcome| settled.fill(outcome);
            if (input.event == .PostCompact) sessionCompacted(app, input.invocation.scope);
            if (claudeCodeTwin(input)) |twin| {
                observe(app, twin, input.matcher_value, input.invocation.scope, input.fields, input.invocation.cancel_flag);
            }
        }

        fn claudeCodeTwin(input: hooks.ObservationInput) ?external.Event {
            return switch (input.event) {
                .TaskStarted => .TaskCreated,
                .PermissionResult => if (permissionWasDenied(input.fields)) .PermissionDenied else null,
                .Notification => if (std.mem.eql(u8, input.matcher_value, task_completed_notification)) .TaskCompleted else null,
                else => null,
            };
        }

        fn permissionWasDenied(fields: []const external.Field) bool {
            for (fields) |field| {
                if (!std.mem.eql(u8, field.key, "decision")) continue;
                const name = switch (field.value) {
                    .string => |text| text,
                    else => return false,
                };
                const decision = std.meta.stringToEnum(types.ToolPermissionDecision, name) orelse return false;
                return decision.isDenied();
            }
            return false;
        }

        fn stopsTheTurn(event: external.Event) bool {
            return switch (event) {
                .PostToolUse, .PostToolUseFailure, .PostToolBatch => true,
                else => false,
            };
        }

        fn requestStop(cancel_flag: ?*std.atomic.Value(bool)) void {
            if (cancel_flag) |flag| flag.store(true, .seq_cst);
        }

        fn toolCallId(fields: []const external.Field) ?[]const u8 {
            for (fields) |field| {
                if (!std.mem.eql(u8, field.key, "tool_call_id")) continue;
                return switch (field.value) {
                    .string => |text| text,
                    else => null,
                };
            }
            return null;
        }

        fn appendParagraph(alloc: Allocator, list: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
            if (list.items.len != 0) try list.appendSlice(alloc, "\n\n");
            try list.appendSlice(alloc, text);
        }

        fn appendHookResult(alloc: Allocator, list: *std.ArrayList(u8), event: external.Event, text: []const u8) Allocator.Error!void {
            const rendered = try external.renderHookResult(alloc, event, text);
            defer alloc.free(rendered);
            try appendParagraph(alloc, list, rendered);
        }

        fn stderrIsForTheUser(definition: *const external.Definition, event: external.Event, execution: external.Execution) bool {
            if (definition.dialect != .claude or event.acceptsDecision(.claude)) return false;
            const code = execution.exit_code orelse return false;
            return code == 2 and !execution.timed_out;
        }

        fn noteSystemMessage(app: *App, scope: hooks.Scope, message: ?[]const u8) Allocator.Error!void {
            const text = std.mem.trim(u8, message orelse return, " \t\r\n");
            if (text.len == 0 or scope.kind == .subagent) return;
            const io = io_mod.getIo();
            app.command_hooks.notice_mutex.lockUncancelable(io);
            defer app.command_hooks.notice_mutex.unlock(io);
            const combined = if (app.command_hooks.pending_notice) |old|
                try std.fmt.allocPrint(app.alloc, "{s}\n{s}", .{ old, text })
            else
                try app.alloc.dupe(u8, text);
            if (app.command_hooks.pending_notice) |old| app.alloc.free(old);
            app.command_hooks.pending_notice = combined;
        }

        fn observe(
            app: *App,
            event: external.Event,
            matcher_value: []const u8,
            scope: hooks.Scope,
            fields: []const external.Field,
            cancel_flag: ?*std.atomic.Value(bool),
        ) void {
            var settled = dispatch(app, event, matcher_value, scope, fields, cancel_flag) catch return;
            settled.deinit(app.alloc);
        }

        fn dispatch(
            app: *App,
            event: external.Event,
            matcher_value: []const u8,
            scope: hooks.Scope,
            fields: []const external.Field,
            cancel_flag: ?*std.atomic.Value(bool),
        ) !Settled {
            const side: Offer.Side = .{ .matcher_value = matcher_value, .fields = fields };
            return dispatchOffer(app, event, .{ .kimi = side, .claude = side }, scope, cancel_flag);
        }

        fn dispatchOffer(
            app: *App,
            event: external.Event,
            offer: Offer,
            scope: hooks.Scope,
            cancel_flag: ?*std.atomic.Value(bool),
        ) !Settled {
            const alloc = app.alloc;
            var settled: Settled = .{};
            errdefer settled.deinit(alloc);
            const io = io_mod.getIo();
            app.command_hooks.dispatch_mutex.lockUncancelable(io);
            defer app.command_hooks.dispatch_mutex.unlock(io);
            const definitions = app.command_hooks.definitions orelse return settled;
            const selected = try external.selectMatchingValues(alloc, definitions, event, offer.matchValues());
            defer alloc.free(selected);
            if (selected.len == 0) return settled;

            var facts = try app.command_hooks.sessionFacts(alloc, scope);
            defer facts.deinit(alloc);
            const base: external.Base = .{
                .session_id = facts.session_id,
                .cwd = scope.workspace_root,
                .session_title = if (facts.session_title.len != 0) facts.session_title else null,
                .transcript_path = if (facts.transcript_path.len != 0) facts.transcript_path else null,
                .permission_mode = if (facts.permission_mode.len != 0) facts.permission_mode else null,
            };
            const kimi_payload: ?[]u8 = if (offer.kimi) |kimi_side| try external.encodePayload(alloc, event, base, kimi_side.fields) else null;
            defer if (kimi_payload) |payload| alloc.free(payload);
            const claude_payload: ?[]u8 = if (offer.sidesShareFields())
                null
            else if (offer.claude) |claude_side|
                try external.encodePayload(alloc, event, base, claude_side.fields)
            else
                null;
            defer if (claude_payload) |payload| alloc.free(payload);

            const runs = try alloc.alloc(HookRun, selected.len);
            defer alloc.free(runs);
            for (runs, selected) |*hook_run, definition| {
                const own_payload = switch (definition.dialect) {
                    .kimi => kimi_payload,
                    .claude => claude_payload orelse kimi_payload,
                };
                hook_run.* = .{
                    .alloc = alloc,
                    .definition = definition,
                    .cwd = definition.cwd orelse scope.workspace_root,
                    .payload = own_payload orelse "{}",
                    .cancel_flag = cancel_flag,
                };
            }
            defer for (runs) |*hook_run| hook_run.outcome.deinit(alloc);
            executeAll(alloc, runs);

            var resolution: external.Resolution = .{ .event = event, .matched_count = runs.len };
            defer recordResolution(app, &resolution, &settled);
            for (runs) |*hook_run| {
                if (hook_run.out_of_memory) return error.OutOfMemory;
                if (hook_run.outcome.cancelled) return settled;
                const execution = hook_run.outcome.execution();
                if (external.executionFailed(execution)) resolution.failed_count += 1;
                try noteFailure(app, event, hook_run.definition.timeout_seconds, scope, execution);
                var verdict = try external.resolve(alloc, hook_run.definition.policy(), event, execution);
                defer verdict.deinit(alloc);
                try noteSystemMessage(app, scope, verdict.system_message);
                if (stderrIsForTheUser(hook_run.definition, event, execution)) try noteSystemMessage(app, scope, execution.stderr);
                if (verdict.stop_requested) settled.stop_requested = true;
                if (verdict.additional_context) |context| try appendParagraph(alloc, &settled.additional_context, context);
                if (verdict.blocked) {
                    if (settled.blocked == null) {
                        settled.blocked = .{ .blocked = true, .reason = verdict.reason, .message = verdict.message };
                        verdict.reason = null;
                        verdict.message = null;
                    }
                    continue;
                }
                settled.permission = external.strongerPermission(settled.permission, verdict.permission);
                settled.settlePermissionRequest(alloc, &verdict);
                if (event == .PreToolUse and settled.rewritten == null) {
                    settled.rewritten = verdict.updated_input;
                    verdict.updated_input = null;
                }
                if (event == .PostToolUse and settled.updated_tool_output == null) {
                    settled.updated_tool_output = verdict.updated_tool_output;
                    verdict.updated_tool_output = null;
                }
                if (event == .SessionStart and settled.initial_user_message == null) {
                    settled.initial_user_message = verdict.initial_user_message;
                    verdict.initial_user_message = null;
                }
                if (event == .UserPromptSubmit) {
                    if (try external.userPromptAppendText(alloc, execution, verdict)) |text| {
                        defer alloc.free(text);
                        if (settled.appended.items.len != 0) try settled.appended.appendSlice(alloc, "\n\n");
                        try settled.appended.appendSlice(alloc, text);
                    }
                }
            }
            return settled;
        }

        fn recordResolution(app: *App, resolution: *external.Resolution, settled: *const Settled) void {
            resolution.blocked = settled.blocked != null;
            app.command_hooks.last_resolution = resolution.*;
            debug_trace.eventf(
                "hooks",
                external.resolved_telemetry_event,
                .{},
                "event={s} action={s} matched_count={d} failed_count={d}",
                .{ @tagName(resolution.event), resolution.action(), resolution.matched_count, resolution.failed_count },
            );
        }

        fn noteFailure(
            app: *App,
            event: external.Event,
            timeout_seconds: u32,
            scope: hooks.Scope,
            execution: external.Execution,
        ) !void {
            if (scope.kind == .subagent) return;
            const io = io_mod.getIo();
            app.command_hooks.notice_mutex.lockUncancelable(io);
            defer app.command_hooks.notice_mutex.unlock(io);
            if (app.command_hooks.failure_warned) return;
            const message = (try external.failureMessage(app.alloc, timeout_seconds, execution)) orelse return;
            defer app.alloc.free(message);
            const notice = try external.failureNotice(app.alloc, event, message);
            app.command_hooks.failure_warned = true;
            if (app.command_hooks.pending_notice) |old| app.alloc.free(old);
            app.command_hooks.pending_notice = notice;
        }

        fn retain(app: *App, text: []u8) []const u8 {
            if (app.command_hooks.retained) |old| app.alloc.free(old);
            app.command_hooks.retained = text;
            return text;
        }

        fn parseToolInput(alloc: Allocator, arguments_json: []const u8) std.json.Value {
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{}) catch return .{ .string = arguments_json };
            return parsed.value;
        }
    };
}

const CommandTestApp = struct {
    alloc: Allocator,
    lifecycle_runtime: hooks.Runtime,
    command_hooks: State = .{},
};

fn commandTestApp(definitions_json: []const u8) !CommandTestApp {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, definitions_json, .{});
    defer parsed.deinit();
    const definitions = try external.parseDefinitions(std.testing.allocator, parsed.value);
    var app = CommandTestApp{
        .alloc = std.testing.allocator,
        .lifecycle_runtime = hooks.Runtime.init(std.testing.allocator),
    };
    app.command_hooks.replaceDefinitions(std.testing.allocator, definitions);
    return app;
}

test "command hook PreToolUse blocks through the lifecycle view with the hook stderr reason" {
    var app = try commandTestApp(
        \\[{"event":"PreToolUse","matcher":"write","command":"echo no writes >&2; exit 2"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();

    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();
    var outcome = try view.runPreToolUse(std.testing.allocator, .{
        .invocation = .{ .scope = .{ .kind = .interactive, .workspace_root = "/tmp", .session_id = "s1" } },
        .step_index = 0,
        .call_id = "call-1",
        .tool_name = "write_file",
        .arguments_json = "{\"path\":\"a.txt\"}",
    });
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome == .blocked);
    try std.testing.expectEqualStrings("no writes", outcome.blocked);
}

test "command hook PreToolUse updatedInput replaces the arguments through the lifecycle view" {
    var app = try commandTestApp(
        \\[{"event":"PreToolUse","matcher":"read_file","command":"printf '%s' '{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\",\"updatedInput\":{\"path\":\"b.txt\"}}}'"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();

    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();
    var outcome = try view.runPreToolUse(std.testing.allocator, .{
        .invocation = .{ .scope = .{ .kind = .interactive, .workspace_root = "/tmp", .session_id = "s1" } },
        .step_index = 0,
        .call_id = "call-1",
        .tool_name = "read_file",
        .arguments_json = "{\"path\":\"a.txt\"}",
    });
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome == .rewritten);
    try std.testing.expectEqualStrings("{\"path\":\"b.txt\"}", outcome.rewritten);
}

test "command hook Stop continues a turn at most once" {
    var app = try commandTestApp(
        \\[{"event":"Stop","command":"echo keep going >&2; exit 2"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();

    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();
    const input = hooks.StopInput{
        .invocation = .{ .scope = .{ .kind = .interactive, .workspace_root = "/tmp", .session_id = "s1" }, .turn_id = 7 },
        .step_index = 0,
        .assistant_text = "done",
        .provider_disposition = .completed,
        .can_continue = true,
    };
    var first = view.runStop(std.testing.allocator, input);
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first == .continue_once);
    try std.testing.expectEqualStrings("keep going", first.continue_once);

    var second = view.runStop(std.testing.allocator, input);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(second == .allow);
}

test "command hook UserPromptSubmit blocks with a hook_result block text" {
    var app = try commandTestApp(
        \\[{"event":"UserPromptSubmit","matcher":"deploy","command":"echo blocked by policy >&2; exit 2"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();

    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();
    const action = view.runUserPromptSubmit(.{
        .invocation = .{ .scope = .{ .kind = .interactive, .workspace_root = "/tmp", .session_id = "s1" } },
        .prompt_text = "deploy now",
        .is_steer = false,
    });
    try std.testing.expect(action == .block);
    try std.testing.expectEqualStrings(
        "<hook_result hook_event=\"UserPromptSubmit\">\nblocked by policy\n</hook_result>",
        action.block,
    );
}

test "command hook UserPromptSubmit appends plain stdout as a hook_result" {
    var app = try commandTestApp(
        \\[{"event":"UserPromptSubmit","command":"echo extra context"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();

    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();
    const action = view.runUserPromptSubmit(.{
        .invocation = .{ .scope = .{ .kind = .interactive, .workspace_root = "/tmp", .session_id = "s1" } },
        .prompt_text = "hello",
        .is_steer = false,
    });
    try std.testing.expect(action == .append);
    try std.testing.expectEqualStrings(
        "<hook_result hook_event=\"UserPromptSubmit\">\nextra context\n</hook_result>",
        action.append,
    );
}

test "command hook observation feeds the event payload to the hook" {
    var app = try commandTestApp(
        \\[{"event":"PostToolUse","matcher":"^write_file$","command":"cat | grep -q '\"tool_call_id\":\"call-9\"' || exit 4; exit 2"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();

    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();
    const fields = [_]external.Field{
        .{ .key = "tool_call_id", .value = .{ .string = "call-8" } },
    };
    view.runObservation(.{
        .invocation = .{ .scope = .{ .kind = .interactive, .workspace_root = "/tmp", .session_id = "s1" } },
        .event = .PostToolUse,
        .matcher_value = "write_file",
        .fields = &fields,
    });
    const notice = app.command_hooks.takeNotice() orelse return error.TestExpectedNotice;
    defer std.testing.allocator.free(notice);
    try std.testing.expectEqualStrings(
        "A PostToolUse hook failed to execute: exited with exit code 4. Hooks always run on this local machine; check that the hook command works locally. Later hook failures in this session are logged without another warning.",
        notice,
    );
}

test "command hook observation with the matching payload raises no warning" {
    var app = try commandTestApp(
        \\[{"event":"PostToolUse","matcher":"^write_file$","command":"cat | grep -q '\"tool_call_id\":\"call-9\"' || exit 4; exit 2"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();

    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();
    const fields = [_]external.Field{
        .{ .key = "tool_call_id", .value = .{ .string = "call-9" } },
    };
    view.runObservation(.{
        .invocation = .{ .scope = .{ .kind = .interactive, .workspace_root = "/tmp", .session_id = "s1" } },
        .event = .PostToolUse,
        .matcher_value = "write_file",
        .fields = &fields,
    });
    try std.testing.expect(app.command_hooks.takeNotice() == null);
}

test "command hook observation warns once per session and stays silent on the second failure" {
    var app = try commandTestApp(
        \\[{"event":"SessionStart","command":"exit 3"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();

    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();
    const invocation: hooks.Invocation = .{ .scope = .{ .kind = .interactive, .workspace_root = "/tmp", .session_id = "s1" } };
    view.runObservation(.{ .invocation = invocation, .event = .SessionStart, .matcher_value = "startup" });
    const notice = app.command_hooks.takeNotice() orelse return error.TestExpectedNotice;
    defer std.testing.allocator.free(notice);
    try std.testing.expectEqualStrings(
        "A SessionStart hook failed to execute: exited with exit code 3. Hooks always run on this local machine; check that the hook command works locally. Later hook failures in this session are logged without another warning.",
        notice,
    );

    view.runObservation(.{ .invocation = invocation, .event = .SessionStart, .matcher_value = "startup" });
    try std.testing.expect(app.command_hooks.takeNotice() == null);
}

test "command hook observation from a subagent scope raises no warning" {
    var app = try commandTestApp(
        \\[{"event":"SubagentStart","command":"exit 3"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();

    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();
    view.runObservation(.{
        .invocation = .{ .scope = .{ .kind = .subagent, .workspace_root = "/tmp", .session_id = "s1" } },
        .event = .SubagentStart,
        .matcher_value = "explore",
    });
    try std.testing.expect(app.command_hooks.takeNotice() == null);
}

test "command hook StopFailure matches on the error name" {
    var app = try commandTestApp(
        \\[{"event":"StopFailure","matcher":"^step_limit$","command":"exit 4"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();

    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();
    const scope: hooks.Scope = .{ .kind = .interactive, .workspace_root = "/tmp", .session_id = "s1" };
    view.runPostTurnEnd(.{
        .invocation = .{ .scope = scope, .turn_id = 3 },
        .outcome = .failed,
        .error_name = "other",
        .error_message = "unrelated",
    });
    try std.testing.expect(app.command_hooks.takeNotice() == null);

    view.runPostTurnEnd(.{
        .invocation = .{ .scope = scope, .turn_id = 4 },
        .outcome = .failed,
        .error_name = "step_limit",
        .error_message = "step limit reached",
    });
    const notice = app.command_hooks.takeNotice() orelse return error.TestExpectedNotice;
    defer std.testing.allocator.free(notice);
    try std.testing.expectEqualStrings(
        "A StopFailure hook failed to execute: exited with exit code 4. Hooks always run on this local machine; check that the hook command works locally. Later hook failures in this session are logged without another warning.",
        notice,
    );
}

test "command hook PermissionRequest and UserPromptQueued observations run their matching command" {
    var app = try commandTestApp(
        \\[{"event":"PermissionRequest","matcher":"^shell","command":"exit 4"},{"event":"UserPromptQueued","matcher":"^later","command":"exit 5"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();

    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();
    const scope: hooks.Scope = .{ .kind = .interactive, .workspace_root = "/tmp", .session_id = "s1" };
    view.runObservation(.{
        .invocation = .{ .scope = scope, .turn_id = 1 },
        .event = .PermissionRequest,
        .matcher_value = "shell.run",
    });
    const permission_notice = app.command_hooks.takeNotice() orelse return error.TestExpectedNotice;
    defer std.testing.allocator.free(permission_notice);
    try std.testing.expect(std.mem.indexOf(u8, permission_notice, "PermissionRequest") != null);

    app.command_hooks.failure_warned = false;
    view.runObservation(.{
        .invocation = .{ .scope = scope, .turn_id = 2 },
        .event = .UserPromptQueued,
        .matcher_value = "later prompt",
    });
    const queued_notice = app.command_hooks.takeNotice() orelse return error.TestExpectedNotice;
    defer std.testing.allocator.free(queued_notice);
    try std.testing.expect(std.mem.indexOf(u8, queued_notice, "UserPromptQueued") != null);
}

test "command hook payload carries the scope session title as session_title" {
    var app = try commandTestApp(
        \\[{"event":"SessionStart","matcher":"startup","command":"cat | grep -q '\"session_title\":\"Fix login\"' || exit 4"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();

    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();
    view.runObservation(.{
        .invocation = .{ .scope = .{ .kind = .interactive, .workspace_root = "/tmp", .session_id = "s1", .session_title = "Fix login" } },
        .event = .SessionStart,
        .matcher_value = "startup",
        .fields = &.{},
    });
    try std.testing.expect(app.command_hooks.takeNotice() == null);
}

test "command hook dispatch runs the matched hooks at the same time" {
    if (comptime !runs_in_parallel) return;
    var app = try commandTestApp(
        \\[{"event":"SessionStart","command":"sleep 1; exit 0"},{"event":"SessionStart","command":"sleep 1; true"},{"event":"SessionStart","command":"sleep 1; :"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();

    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();
    const started_ms = io_mod.milliTimestamp();
    view.runObservation(.{
        .invocation = .{ .scope = .{ .kind = .interactive, .workspace_root = "/tmp", .session_id = "s1" } },
        .event = .SessionStart,
        .matcher_value = "startup",
    });
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 2_500);
    try std.testing.expectEqual(@as(usize, 3), app.command_hooks.last_resolution.?.matched_count);
    try std.testing.expectEqual(@as(usize, 0), app.command_hooks.last_resolution.?.failed_count);
}

test "command hook block reason comes from the first blocking hook in configured order" {
    var app = try commandTestApp(
        \\[{"event":"PreToolUse","command":"sleep 0.3; echo first >&2; exit 2"},{"event":"PreToolUse","command":"echo second >&2; exit 2"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();

    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();
    var outcome = try view.runPreToolUse(std.testing.allocator, .{
        .invocation = .{ .scope = .{ .kind = .interactive, .workspace_root = "/tmp", .session_id = "s1" } },
        .step_index = 0,
        .call_id = "call-1",
        .tool_name = "write_file",
        .arguments_json = "{}",
    });
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome == .blocked);
    try std.testing.expectEqualStrings("first", outcome.blocked);
}

test "command hook dispatch records the external_hook_resolved action and counts" {
    var app = try commandTestApp(
        \\[{"event":"PreToolUse","command":"exit 2"},{"event":"PreToolUse","command":"exit 3"},{"event":"PreToolUse","matcher":"^read","command":"exit 0"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();

    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();
    try std.testing.expect(app.command_hooks.last_resolution == null);
    var outcome = try view.runPreToolUse(std.testing.allocator, .{
        .invocation = .{ .scope = .{ .kind = .subagent, .workspace_root = "/tmp", .session_id = "s1" } },
        .step_index = 0,
        .call_id = "call-1",
        .tool_name = "write_file",
        .arguments_json = "{}",
    });
    defer outcome.deinit(std.testing.allocator);
    const resolution = app.command_hooks.last_resolution orelse return error.TestExpectedResolution;
    try std.testing.expectEqual(external.Event.PreToolUse, resolution.event);
    try std.testing.expectEqualStrings("block", resolution.action());
    try std.testing.expectEqual(@as(usize, 2), resolution.matched_count);
    try std.testing.expectEqual(@as(usize, 1), resolution.failed_count);
}

test "command hook payload falls back to the noted session id and title when the scope has none" {
    var app = try commandTestApp(
        \\[{"event":"Notification","command":"cat > /dev/null; exit 0"},{"event":"SessionHeartbeat","command":"input=$(cat); echo \"$input\" | grep -q '\"session_id\":\"s-noted\"' || exit 4; echo \"$input\" | grep -q '\"session_title\":\"Noted title\"' || exit 5"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();
    app.command_hooks.noteSession(std.testing.allocator, "s-noted", "First title");
    app.command_hooks.noteSessionTitle(std.testing.allocator, "Noted title");
    try std.testing.expect(app.command_hooks.notedSessionIs("s-noted"));
    try std.testing.expect(!app.command_hooks.notedSessionIs(null));

    Runtime(CommandTestApp).fire(&app, .SessionHeartbeat, "", .{ .kind = .interactive, .workspace_root = "/tmp" }, &.{
        .{ .key = external.uptime_key, .value = .{ .integer = 5 } },
    }, null);
    try std.testing.expect(app.command_hooks.takeNotice() == null);
    try std.testing.expectEqual(@as(usize, 1), app.command_hooks.last_resolution.?.matched_count);
}

test "command hook payload keeps the scope session id and title over the noted ones" {
    var app = try commandTestApp(
        \\[{"event":"SessionEnd","command":"input=$(cat); echo \"$input\" | grep -q '\"session_id\":\"s-scope\"' || exit 4; echo \"$input\" | grep -q '\"session_title\":\"Scope title\"' || exit 5"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();
    app.command_hooks.noteSession(std.testing.allocator, "s-noted", "Noted title");

    Runtime(CommandTestApp).fire(&app, .SessionEnd, "exit", .{
        .kind = .interactive,
        .workspace_root = "/tmp",
        .session_id = "s-scope",
        .session_title = "Scope title",
    }, &.{.{ .key = "reason", .value = .{ .string = "exit" } }}, null);
    try std.testing.expect(app.command_hooks.takeNotice() == null);
}

test "command hook runs a plugin definition in its root with its env" {
    var app = try commandTestApp(
        \\[{"event":"Stop","command":"test \"$FX_PLUGIN_ROOT\" = /tmp || exit 4; test \"$KIMI_PLUGIN_ROOT\" = /tmp || exit 5; test \"$(pwd -P)\" = \"$(cd /tmp && pwd -P)\" || exit 6; echo from plugin >&2; exit 2"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();
    const definition = &app.command_hooks.definitions.?[0];
    definition.cwd = try std.testing.allocator.dupe(u8, "/tmp");
    try definition.replaceEnv(std.testing.allocator, &.{
        .{ .name = "FX_PLUGIN_ROOT", .value = "/tmp" },
        .{ .name = "KIMI_PLUGIN_ROOT", .value = "/tmp" },
    });

    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();
    var outcome = view.runStop(std.testing.allocator, .{
        .invocation = .{ .scope = .{ .kind = .interactive, .workspace_root = "/", .session_id = "s1" }, .turn_id = 1 },
        .step_index = 0,
        .assistant_text = "done",
        .provider_disposition = .completed,
        .can_continue = true,
    });
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome == .continue_once);
    try std.testing.expectEqualStrings("from plugin", outcome.continue_once);
    try std.testing.expect(app.command_hooks.takeNotice() == null);
}

test "command hook session switch ends the noted session before starting the next one" {
    var app = try commandTestApp(
        \\[{"event":"SessionEnd","matcher":"^exit$","command":"input=$(cat); echo \"$input\" | grep -q '\"session_id\":\"old\"' || exit 4; echo \"$input\" | grep -q '\"session_title\":\"Old title\"' || exit 5; echo \"$input\" | grep -q '\"reason\":\"exit\"' || exit 6"},{"event":"SessionStart","matcher":"^resume$","command":"input=$(cat); echo \"$input\" | grep -q '\"session_id\":\"new\"' || exit 7; echo \"$input\" | grep -q '\"source\":\"resume\"' || exit 8; echo \"$input\" | grep -q '\"session_title\":\"New title\"' || exit 9"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();
    const scope: hooks.Scope = .{ .kind = .interactive, .workspace_root = "/tmp" };
    const CommandHooks = Runtime(CommandTestApp);

    CommandHooks.openSession(&app, scope, .{ .session_id = "old", .session_title = "Old title", .model = "m" });
    try std.testing.expect(app.command_hooks.last_resolution == null);

    CommandHooks.switchSession(&app, scope, .{ .session_id = "old", .session_title = "Old title", .model = "m" });
    try std.testing.expect(app.command_hooks.last_resolution == null);

    CommandHooks.switchSession(&app, scope, .{ .session_id = "new", .session_title = "New title", .source = .@"resume", .model = "m" });
    try std.testing.expect(app.command_hooks.takeNotice() == null);
    const resolution = app.command_hooks.last_resolution orelse return error.TestExpectedResolution;
    try std.testing.expectEqual(external.Event.SessionStart, resolution.event);
    try std.testing.expectEqual(@as(usize, 0), resolution.failed_count);
    try std.testing.expect(app.command_hooks.notedSessionIs("new"));
}

const test_scope: hooks.Scope = .{ .kind = .interactive, .workspace_root = "/tmp", .session_id = "s1" };

fn runTestPreToolUse(app: *CommandTestApp, call_id: []const u8, tool_name: []const u8) !hooks.PreToolUseOutcome {
    const view = app.lifecycle_runtime.freeze();
    return view.runPreToolUse(std.testing.allocator, .{
        .invocation = .{ .scope = test_scope },
        .step_index = 0,
        .call_id = call_id,
        .tool_name = tool_name,
        .arguments_json = "{}",
    });
}

test "PreToolUse answers rank deny over defer over ask over allow across hooks" {
    var asking = try commandTestApp(
        \\[{"event":"PreToolUse","command":"printf '%s' '{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\"}}'"},
        \\ {"event":"PreToolUse","command":"printf '%s' '{\"hookSpecificOutput\":{\"permissionDecision\":\"ask\"}}'"}]
    );
    defer asking.command_hooks.deinit(std.testing.allocator);
    defer asking.lifecycle_runtime.deinit();
    try Runtime(CommandTestApp).configure(&asking);
    var asked = try runTestPreToolUse(&asking, "call-ask", "bash");
    defer asked.deinit(std.testing.allocator);
    try std.testing.expect(asked == .unchanged);
    const answers = asking.command_hooks.hookAnswers();
    try std.testing.expect(answers.asks("call-ask"));
    try std.testing.expect(!answers.asks("call-other"));

    var deferring = try commandTestApp(
        \\[{"event":"PreToolUse","command":"printf '%s' '{\"hookSpecificOutput\":{\"permissionDecision\":\"ask\"}}'"},
        \\ {"event":"PreToolUse","command":"printf '%s' '{\"hookSpecificOutput\":{\"permissionDecision\":\"defer\"}}'"}]
    );
    defer deferring.command_hooks.deinit(std.testing.allocator);
    defer deferring.lifecycle_runtime.deinit();
    try Runtime(CommandTestApp).configure(&deferring);
    var deferred = try runTestPreToolUse(&deferring, "call-defer", "bash");
    defer deferred.deinit(std.testing.allocator);
    try std.testing.expect(deferred == .unchanged);
    try std.testing.expect(!deferring.command_hooks.hookAnswers().asks("call-defer"));

    var denying = try commandTestApp(
        \\[{"event":"PreToolUse","command":"printf '%s' '{\"hookSpecificOutput\":{\"permissionDecision\":\"ask\"}}'"},
        \\ {"event":"PreToolUse","command":"printf '%s' '{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"policy\"}}'"}]
    );
    defer denying.command_hooks.deinit(std.testing.allocator);
    defer denying.lifecycle_runtime.deinit();
    try Runtime(CommandTestApp).configure(&denying);
    var denied = try runTestPreToolUse(&denying, "call-deny", "bash");
    defer denied.deinit(std.testing.allocator);
    try std.testing.expect(denied == .blocked);
    try std.testing.expectEqualStrings("policy", denied.blocked);
    try std.testing.expect(!denying.command_hooks.hookAnswers().asks("call-deny"));
}

test "onFailure block makes a failed PreToolUse hook block the call and the default leaves it open" {
    var blocking = try commandTestApp(
        \\{"PreToolUse":[{"matcher":"bash","onFailure":"block","hooks":[{"type":"command","command":"exit 3","timeout":5}]}]}
    );
    defer blocking.command_hooks.deinit(std.testing.allocator);
    defer blocking.lifecycle_runtime.deinit();
    try Runtime(CommandTestApp).configure(&blocking);
    var blocked = try runTestPreToolUse(&blocking, "call-1", "bash");
    defer blocked.deinit(std.testing.allocator);
    try std.testing.expect(blocked == .blocked);
    try std.testing.expectEqualStrings("PreToolUse hook exited with exit code 3", blocked.blocked);
    if (blocking.command_hooks.takeNotice()) |notice| std.testing.allocator.free(notice);

    var skipped = try runTestPreToolUse(&blocking, "call-2", "read_file");
    defer skipped.deinit(std.testing.allocator);
    try std.testing.expect(skipped == .unchanged);

    var open = try commandTestApp(
        \\{"PreToolUse":[{"hooks":[{"type":"command","command":"exit 3","timeout":5}]}]}
    );
    defer open.command_hooks.deinit(std.testing.allocator);
    defer open.lifecycle_runtime.deinit();
    try Runtime(CommandTestApp).configure(&open);
    var allowed = try runTestPreToolUse(&open, "call-3", "bash");
    defer allowed.deinit(std.testing.allocator);
    try std.testing.expect(allowed == .unchanged);
    if (open.command_hooks.takeNotice()) |notice| std.testing.allocator.free(notice);
}

test "PostToolUse hook output replaces the tool output, adds context and reports a block reason" {
    var app = try commandTestApp(
        \\[{"event":"PostToolUse","matcher":"^bash$","command":"printf '%s' '{\"decision\":\"block\",\"reason\":\"lint failed\",\"hookSpecificOutput\":{\"updatedToolOutput\":\"redacted\",\"additionalContext\":\"see lint.log\"}}'"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();
    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();

    var outcome: hooks.ObservationOutcome = .{ .alloc = std.testing.allocator };
    defer outcome.deinit();
    view.runObservation(.{
        .invocation = .{ .scope = test_scope },
        .event = .PostToolUse,
        .matcher_value = "bash",
        .outcome = &outcome,
    });
    try std.testing.expect(outcome.blocked);
    try std.testing.expectEqualStrings("lint failed", outcome.reason.?);
    try std.testing.expectEqualStrings("see lint.log", outcome.additional_context.?);
    try std.testing.expect(outcome.updated_tool_output == null);

    var replacing = try commandTestApp(
        \\[{"event":"PostToolUse","command":"printf '%s' '{\"hookSpecificOutput\":{\"updatedToolOutput\":\"redacted\"}}'"}]
    );
    defer replacing.command_hooks.deinit(std.testing.allocator);
    defer replacing.lifecycle_runtime.deinit();
    try Runtime(CommandTestApp).configure(&replacing);
    var replaced: hooks.ObservationOutcome = .{ .alloc = std.testing.allocator };
    defer replaced.deinit();
    replacing.lifecycle_runtime.freeze().runObservation(.{
        .invocation = .{ .scope = test_scope },
        .event = .PostToolUse,
        .matcher_value = "bash",
        .outcome = &replaced,
    });
    try std.testing.expect(!replaced.blocked);
    try std.testing.expectEqualStrings("redacted", replaced.updated_tool_output.?);
}

test "a Claude Code shaped PreCompact hook that exits 2 reports a block and the flat shape stays an observation" {
    var claude = try commandTestApp(
        \\{"PreCompact":[{"matcher":"auto","hooks":[{"type":"command","command":"echo keep the history >&2; exit 2"}]}]}
    );
    defer claude.command_hooks.deinit(std.testing.allocator);
    defer claude.lifecycle_runtime.deinit();
    try Runtime(CommandTestApp).configure(&claude);
    var blocked: hooks.ObservationOutcome = .{ .alloc = std.testing.allocator };
    defer blocked.deinit();
    claude.lifecycle_runtime.freeze().runObservation(.{ .invocation = .{ .scope = test_scope }, .event = .PreCompact, .matcher_value = "auto", .outcome = &blocked });
    try std.testing.expect(blocked.blocked);
    try std.testing.expectEqualStrings("keep the history", blocked.reason.?);

    var manual: hooks.ObservationOutcome = .{ .alloc = std.testing.allocator };
    defer manual.deinit();
    claude.lifecycle_runtime.freeze().runObservation(.{ .invocation = .{ .scope = test_scope }, .event = .PreCompact, .matcher_value = "manual", .outcome = &manual });
    try std.testing.expect(!manual.blocked);

    var flat = try commandTestApp(
        \\[{"event":"PreCompact","command":"exit 2"}]
    );
    defer flat.command_hooks.deinit(std.testing.allocator);
    defer flat.lifecycle_runtime.deinit();
    try Runtime(CommandTestApp).configure(&flat);
    var observed: hooks.ObservationOutcome = .{ .alloc = std.testing.allocator };
    defer observed.deinit();
    flat.lifecycle_runtime.freeze().runObservation(.{ .invocation = .{ .scope = test_scope }, .event = .PreCompact, .matcher_value = "auto", .outcome = &observed });
    try std.testing.expect(!observed.blocked);
}

test "a PermissionRequest hook matched on ExitPlanMode answers the prompt for that call only" {
    var app = try commandTestApp(
        \\{"PermissionRequest":[{"matcher":"ExitPlanMode","hooks":[{"type":"command","command":"printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\"}}}'"}]}]}
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();
    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();
    const answers = app.command_hooks.hookAnswers();

    const shell_fields = [_]external.Field{.{ .key = "tool_call_id", .value = .{ .string = "call-shell" } }};
    view.runObservation(.{ .invocation = .{ .scope = test_scope }, .event = .PermissionRequest, .matcher_value = "bash", .fields = &shell_fields });
    try std.testing.expect(answers.take(std.testing.allocator, "call-shell") == null);

    const plan_fields = [_]external.Field{.{ .key = "tool_call_id", .value = .{ .string = "call-plan" } }};
    view.runObservation(.{ .invocation = .{ .scope = test_scope }, .event = .PermissionRequest, .matcher_value = "ExitPlanMode", .fields = &plan_fields });
    try std.testing.expect(answers.take(std.testing.allocator, "call-shell") == null);
    var answered = answers.take(std.testing.allocator, "call-plan") orelse return error.TestExpectedAnswer;
    defer answered.deinit();
    try std.testing.expectEqual(types.ToolPermissionDecision.once, answered.decision);
    try std.testing.expect(answers.take(std.testing.allocator, "call-plan") == null);
}

test "a PermissionRequest hook deny answers the prompt with its message and beats an allow" {
    var app = try commandTestApp(
        \\[{"event":"PermissionRequest","command":"printf '%s' '{\"hookSpecificOutput\":{\"decision\":{\"behavior\":\"allow\"}}}'"},
        \\ {"event":"PermissionRequest","command":"printf '%s' '{\"hookSpecificOutput\":{\"decision\":{\"behavior\":\"deny\",\"message\":\"not on main\"}}}'"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();
    try Runtime(CommandTestApp).configure(&app);
    const fields = [_]external.Field{.{ .key = "tool_call_id", .value = .{ .string = "call-1" } }};
    app.lifecycle_runtime.freeze().runObservation(.{ .invocation = .{ .scope = test_scope }, .event = .PermissionRequest, .matcher_value = "bash", .fields = &fields });
    var answered = app.command_hooks.hookAnswers().take(std.testing.allocator, "call-1") orelse return error.TestExpectedAnswer;
    defer answered.deinit();
    try std.testing.expectEqual(types.ToolPermissionDecision.deny, answered.decision);
    try std.testing.expectEqualStrings("not on main", answered.feedback.?);
}

test "SessionStart additionalContext reaches the model with the next prompt, once" {
    var app = try commandTestApp(
        \\[{"event":"SessionStart","matcher":"startup","command":"printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"branch: main\",\"initialUserMessage\":\"run the tests\"}}'"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();
    const CommandHooks = Runtime(CommandTestApp);
    try CommandHooks.configure(&app);
    const view = app.lifecycle_runtime.freeze();
    CommandHooks.openSession(&app, .{ .kind = .interactive, .workspace_root = "/tmp" }, .{ .session_id = "s1", .model = "m" });

    const first = view.runUserPromptSubmit(.{ .invocation = .{ .scope = test_scope }, .prompt_text = "hello", .is_steer = false });
    try std.testing.expect(first == .append);
    try std.testing.expectEqualStrings("<hook_result hook_event=\"SessionStart\">\nbranch: main\n</hook_result>", first.append);

    const second = view.runUserPromptSubmit(.{ .invocation = .{ .scope = test_scope }, .prompt_text = "again", .is_steer = false });
    try std.testing.expect(second == .allow);

    const initial = app.command_hooks.takeInitialUserMessage() orelse return error.TestExpectedMessage;
    defer std.testing.allocator.free(initial);
    try std.testing.expectEqualStrings("run the tests", initial);
}

test "a hook systemMessage is shown to the user and continue false stops the turn" {
    var app = try commandTestApp(
        \\[{"event":"PreToolUse","command":"printf '%s' '{\"continue\":false,\"stopReason\":\"budget spent\",\"systemMessage\":\"hook says stop\"}'"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();
    try Runtime(CommandTestApp).configure(&app);
    var cancel = std.atomic.Value(bool).init(false);
    var outcome = try app.lifecycle_runtime.freeze().runPreToolUse(std.testing.allocator, .{
        .invocation = .{ .scope = test_scope, .cancel_flag = &cancel },
        .step_index = 0,
        .call_id = "call-1",
        .tool_name = "bash",
        .arguments_json = "{}",
    });
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome == .blocked);
    try std.testing.expectEqualStrings("budget spent", outcome.blocked);
    try std.testing.expect(cancel.load(.seq_cst));
    const notice = app.command_hooks.takeNotice() orelse return error.TestExpectedNotice;
    defer std.testing.allocator.free(notice);
    try std.testing.expectEqualStrings("hook says stop", notice);
}

test "hook payload carries the noted transcript path and permission mode with tool_use_id" {
    var app = try commandTestApp(
        \\[{"event":"PostToolUse","command":"input=$(cat); echo \"$input\" | grep -q '\"transcript_path\":\"/tmp/s1.jsonl\"' || exit 4; echo \"$input\" | grep -q '\"permission_mode\":\"plan\"' || exit 5; echo \"$input\" | grep -q '\"tool_use_id\":\"call-9\"' || exit 6"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();
    app.command_hooks.noteTranscriptPath(std.testing.allocator, "/tmp/s1.jsonl");
    app.command_hooks.notePermissionMode(std.testing.allocator, "plan");
    try Runtime(CommandTestApp).configure(&app);
    const fields = [_]external.Field{.{ .key = "tool_call_id", .value = .{ .string = "call-9" } }};
    app.lifecycle_runtime.freeze().runObservation(.{ .invocation = .{ .scope = test_scope }, .event = .PostToolUse, .matcher_value = "bash", .fields = &fields });
    try std.testing.expect(app.command_hooks.takeNotice() == null);
    try std.testing.expectEqual(@as(usize, 0), app.command_hooks.last_resolution.?.failed_count);
}

test "Claude Code event names run beside the fx events they describe" {
    var app = try commandTestApp(
        \\{"TaskCreated":[{"hooks":[{"type":"command","command":"exit 11"}]}],
        \\ "PermissionDenied":[{"matcher":"bash","hooks":[{"type":"command","command":"exit 12"}]}],
        \\ "TaskCompleted":[{"hooks":[{"type":"command","command":"exit 13"}]}]}
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();
    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();

    view.runObservation(.{ .invocation = .{ .scope = test_scope }, .event = .TaskStarted, .matcher_value = "process" });
    const created = app.command_hooks.takeNotice() orelse return error.TestExpectedNotice;
    defer std.testing.allocator.free(created);
    try std.testing.expect(std.mem.indexOf(u8, created, "A TaskCreated hook failed to execute: exited with exit code 11") != null);

    app.command_hooks.failure_warned = false;
    const allowed = [_]external.Field{.{ .key = "decision", .value = .{ .string = "once" } }};
    view.runObservation(.{ .invocation = .{ .scope = test_scope }, .event = .PermissionResult, .matcher_value = "bash", .fields = &allowed });
    try std.testing.expect(app.command_hooks.takeNotice() == null);
    const denied_fields = [_]external.Field{.{ .key = "decision", .value = .{ .string = "deny" } }};
    view.runObservation(.{ .invocation = .{ .scope = test_scope }, .event = .PermissionResult, .matcher_value = "bash", .fields = &denied_fields });
    const denied = app.command_hooks.takeNotice() orelse return error.TestExpectedNotice;
    defer std.testing.allocator.free(denied);
    try std.testing.expect(std.mem.indexOf(u8, denied, "A PermissionDenied hook failed to execute: exited with exit code 12") != null);

    app.command_hooks.failure_warned = false;
    view.runObservation(.{ .invocation = .{ .scope = test_scope }, .event = .Notification, .matcher_value = "task.failed" });
    try std.testing.expect(app.command_hooks.takeNotice() == null);
    view.runObservation(.{ .invocation = .{ .scope = test_scope }, .event = .Notification, .matcher_value = "task.completed" });
    const completed = app.command_hooks.takeNotice() orelse return error.TestExpectedNotice;
    defer std.testing.allocator.free(completed);
    try std.testing.expect(std.mem.indexOf(u8, completed, "A TaskCompleted hook failed to execute: exited with exit code 13") != null);
}

test "SessionStart tells Claude Code shaped hooks about clear and compact and keeps startup for the flat shape" {
    var app = try commandTestApp(
        \\{"SessionStart":[{"matcher":"clear","hooks":[{"type":"command","command":"cat | grep -q '\"source\":\"clear\"' || exit 4; printf '%s' '{\"hookSpecificOutput\":{\"additionalContext\":\"cleared\"}}'"}]},
        \\ {"matcher":"compact","hooks":[{"type":"command","command":"cat | grep -q '\"source\":\"compact\"' || exit 5; printf '%s' '{\"hookSpecificOutput\":{\"additionalContext\":\"compacted\"}}'"}]}]}
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();
    const CommandHooks = Runtime(CommandTestApp);
    try CommandHooks.configure(&app);
    const view = app.lifecycle_runtime.freeze();
    const scope: hooks.Scope = .{ .kind = .interactive, .workspace_root = "/tmp" };

    CommandHooks.openSession(&app, scope, .{ .session_id = "s1", .model = "m" });
    try std.testing.expect(app.command_hooks.takeSessionContext() == null);

    CommandHooks.switchSession(&app, scope, .{ .session_id = "s2", .source = .clear, .model = "m" });
    const cleared = app.command_hooks.takeSessionContext() orelse return error.TestExpectedContext;
    defer std.testing.allocator.free(cleared);
    try std.testing.expectEqualStrings("cleared", cleared);

    view.runObservation(.{ .invocation = .{ .scope = scope }, .event = .PostCompact, .matcher_value = "auto" });
    const compacted = app.command_hooks.takeSessionContext() orelse return error.TestExpectedContext;
    defer std.testing.allocator.free(compacted);
    try std.testing.expectEqualStrings("compacted", compacted);
    try std.testing.expect(app.command_hooks.takeNotice() == null);
}

test "a flat SessionStart hook matched on startup runs for a cleared session and not for a fork or a compaction" {
    var app = try commandTestApp(
        \\[{"event":"SessionStart","matcher":"^startup$","command":"cat | grep -q '\"source\":\"startup\"' || exit 4; exit 7"},
        \\ {"event":"SessionEnd","command":"exit 8"}]
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();
    const CommandHooks = Runtime(CommandTestApp);
    try CommandHooks.configure(&app);
    const scope: hooks.Scope = .{ .kind = .interactive, .workspace_root = "/tmp" };

    CommandHooks.switchSession(&app, scope, .{ .session_id = "s2", .source = .clear, .model = "m" });
    const notice = app.command_hooks.takeNotice() orelse return error.TestExpectedNotice;
    defer std.testing.allocator.free(notice);
    try std.testing.expect(std.mem.indexOf(u8, notice, "exited with exit code") != null);
    try std.testing.expectEqual(external.Event.SessionStart, app.command_hooks.last_resolution.?.event);
    try std.testing.expectEqual(@as(usize, 1), app.command_hooks.last_resolution.?.matched_count);

    app.command_hooks.last_resolution = null;
    CommandHooks.switchSession(&app, scope, .{ .session_id = "s3", .source = .fork, .model = "m" });
    try std.testing.expect(app.command_hooks.last_resolution == null);
    try std.testing.expect(app.command_hooks.notedSessionIs("s3"));
}

test "a Notification hook with an empty matcher runs when fx waits for permission and when it waits for input" {
    var app = try commandTestApp(
        \\{"Notification":[{"matcher":"","hooks":[{"type":"command","command":"cat | grep -q '\"notification_type\":\"permission_prompt\"' && exit 21; exit 22"}]},
        \\ {"matcher":"idle_prompt","hooks":[{"type":"command","command":"exit 23"}]}]}
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();
    try Runtime(CommandTestApp).configure(&app);
    const view = app.lifecycle_runtime.freeze();

    view.runAttentionRequired(.{ .invocation = .{ .scope = test_scope }, .kind = .permission });
    const waiting = app.command_hooks.takeNotice() orelse return error.TestExpectedNotice;
    defer std.testing.allocator.free(waiting);
    try std.testing.expect(std.mem.indexOf(u8, waiting, "A Notification hook failed to execute: exited with exit code 21") != null);
    try std.testing.expectEqual(@as(usize, 1), app.command_hooks.last_resolution.?.matched_count);

    view.runPostTurnEnd(.{ .invocation = .{ .scope = test_scope, .turn_id = 1 }, .outcome = .completed });
    try std.testing.expectEqual(external.Event.Notification, app.command_hooks.last_resolution.?.event);
    try std.testing.expectEqual(@as(usize, 2), app.command_hooks.last_resolution.?.matched_count);
    try std.testing.expectEqual(@as(usize, 2), app.command_hooks.last_resolution.?.failed_count);
    try std.testing.expect(!app.command_hooks.last_resolution.?.blocked);
}

test "exit code 2 from a Claude Code shaped SessionStart hook shows its stderr to the user and blocks nothing" {
    var app = try commandTestApp(
        \\{"SessionStart":[{"hooks":[{"type":"command","command":"echo check your VPN >&2; exit 2"}]}]}
    );
    defer app.command_hooks.deinit(std.testing.allocator);
    defer app.lifecycle_runtime.deinit();
    const CommandHooks = Runtime(CommandTestApp);
    try CommandHooks.configure(&app);
    CommandHooks.openSession(&app, .{ .kind = .interactive, .workspace_root = "/tmp" }, .{ .session_id = "s1", .model = "m" });
    const shown = app.command_hooks.takeNotice() orelse return error.TestExpectedNotice;
    defer std.testing.allocator.free(shown);
    try std.testing.expectEqualStrings("check your VPN", shown);
    try std.testing.expect(!app.command_hooks.last_resolution.?.blocked);
    try std.testing.expect(app.command_hooks.takeSessionContext() == null);
}
