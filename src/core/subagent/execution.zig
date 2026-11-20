const std = @import("std");
const managed_execution = @import("../execution/managed_execution.zig");
const permission_request = @import("../permissions/permission_request.zig");
const permission_prompter = @import("../permissions/permission_prompter.zig");
const runtime_deps = @import("../agent/runtime/deps.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const agents = @import("../agents/agents.zig");
const authority_mod = @import("authority.zig");
const approval_registry_mod = @import("approval_registry.zig");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const live_metrics = @import("live_metrics.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const session = @import("../session/session.zig");
const session_adapter = @import("../session/session_adapter.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_codec = @import("../session/session_codec.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const session_store = @import("../session/session_store.zig");
const text_utils = @import("../shared/text_utils.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const types = @import("../shared/types.zig");
const history_range = @import("../shared/history_range.zig");
const hooks = @import("../hooks/hooks.zig");

const Allocator = std.mem.Allocator;

pub fn liveMcpViewFrom(
    alloc: Allocator,
    authority: *authority_mod.Snapshot,
) !tool_mcp_runtime.ResolvedLiveView {
    defer authority.deinit(alloc);
    const view = authority.mcp_view orelse return error.McpRuntimeUnavailable;
    authority.mcp_view = null;
    return .{
        .authority_generation = mcp_access.authorityGeneration(view),
        .action_authority_generation = authority.generation,
        .view = view,
    };
}

pub fn resolveLiveToolActionFor(
    resolver: *authority_mod.Resolver,
    child_id: []const u8,
    user_mode: ?types.PermissionMode,
    alloc: Allocator,
    call: types.ToolCall,
    workspace_root: []const u8,
    target: []const u8,
    target_kind: tool_dispatch.PermissionTargetKind,
) !runtime_deps.ResolvedLiveToolAuthority {
    const snapshot = if (user_mode) |mode|
        try resolver.resolveForUser(alloc, child_id, mode)
    else
        try resolver.resolve(alloc, child_id);
    const decision = try authority_mod.decideToolAuthority(
        alloc,
        snapshot.view(),
        workspace_root,
        call.name,
        target,
        target_kind,
    );
    const permission_state = try alloc.create(session_permission_state.State);
    permission_state.* = snapshot.permission_state;
    return .{
        .authority = .{
            .generation = snapshot.generation,
            .root_id = snapshot.root_id,
            .tools = snapshot.tools,
            .integrations = snapshot.integrations,
            .rules = snapshot.rules,
            .grants = snapshot.grants,
            .permission_state = permission_state,
            .permission_mode = snapshot.permission_mode,
        },
        .decision = switch (decision) {
            .allow => .allow,
            .ask => .ask,
            .deny => .deny,
            .unavailable => .unavailable,
        },
    };
}

test "a hosted run's turn context leaves saving to the child's own agent" {
    var turn = TurnContext.initHosted(std.testing.allocator, 8);
    defer turn.deinit();
    try std.testing.expect(turn.isHosted());
    try turn.beginTurn();
    try std.testing.expectError(error.ChildCapabilityUnavailable, turn.childCapability());
    const saved: types.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = @constCast("task"), .work_id = @constCast("work-1") },
        .assistant = @constCast("answer"),
    } };
    try std.testing.expectError(error.SessionCommitFailed, turn.commit("work-1", saved));
    try std.testing.expect(!turn.committed);
}

test "child compaction preserves work identity and permits final commit" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    const child = try parent.openChild("child-compaction", &.{});
    defer child.close();
    var turn = try TurnContext.init(alloc, child, 0);
    defer turn.deinit();
    turn.active_work_id = "work-checkpoint";
    try turn.beginTurn();
    try turn.commitContextCompaction(.{
        .summary = @constCast("<context_handoff>continue child work</context_handoff>"),
        .removed_turn_count = 0,
        .compaction_count = 1,
    }, .{ .user = .{ .text = @constCast("child request") }, .assistant = @constCast("") }, null);
    try std.testing.expect(!turn.committed);
    try turn.commit("work-checkpoint", .{ .assistant = .{
        .user = .{ .text = @constCast("child request") },
        .assistant = @constCast("child done"),
    } });
    try std.testing.expect(turn.committed);

    const history = try parent.store.childHistory(alloc, "child-compaction");
    defer types.freeHistoryTurnSlice(alloc, history);
    var requests: usize = 0;
    for (history) |entry| switch (entry) {
        .assistant => |done| if (std.mem.eql(u8, done.user.text, "child request")) {
            requests += 1;
            try std.testing.expectEqualStrings("work-checkpoint", done.user.work_id.?);
            try std.testing.expectEqualStrings("child done", done.assistant);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), requests);
}

pub const TurnPreferences = struct {
    provider: @import("../config/model_provider.zig").ProviderId = .gateway,
    model: []const u8,
    effort: types.ReasoningEffort,
    ultrafast_mode: bool = false,
};

pub const CaptureRequest = struct {
    child_id: []const u8,
    parent_id: []const u8,
    source_id: []const u8,
    preferences: TurnPreferences,
};

pub const RunOutcome = enum { completed, awaiting_approval, paused };

pub const ServiceError = error{
    OutOfMemory,
    AdmissionFailed,
    ProviderFailed,
    Cancelled,
};

pub const Services = struct {
    context: ?*anyopaque = null,
    bind_fn: ?*const fn (
        ?*anyopaque,
        *TurnContext,
        *std.atomic.Value(bool),
    ) ServiceError!void = null,
    capture_fn: *const fn (
        ?*anyopaque,
        Allocator,
        CaptureRequest,
    ) ServiceError!domain.AdmissionSnapshot,
    run_fn: *const fn (
        ?*anyopaque,
        *TurnContext,
        domain.QueuedMessage,
        domain.AdmissionSnapshot,
        *std.atomic.Value(bool),
    ) ServiceError!RunOutcome,
    lifecycle: Lifecycle = .{},

    pub fn bind(self: Services, turn: *TurnContext, cancel: *std.atomic.Value(bool)) ServiceError!void {
        const bind_fn = self.bind_fn orelse return;
        return bind_fn(self.context, turn, cancel);
    }

    pub fn capture(
        self: Services,
        alloc: Allocator,
        request: CaptureRequest,
    ) ServiceError!domain.AdmissionSnapshot {
        return self.capture_fn(self.context, alloc, request);
    }

    pub fn run(
        self: Services,
        turn: *TurnContext,
        message: domain.QueuedMessage,
        admission: domain.AdmissionSnapshot,
        cancel: *std.atomic.Value(bool),
    ) ServiceError!RunOutcome {
        self.lifecycle.observeTaskStarted(turn, message, admission);
        self.lifecycle.observeStart(turn, message, admission, cancel);
        const outcome = try self.run_fn(self.context, turn, message, admission, cancel);
        if (outcome != .completed) return outcome;
        const continuation = self.lifecycle.observeStop(turn, admission) orelse return outcome;
        defer stop_hook_allocator.free(continuation);
        var follow_up = message;
        follow_up.content = continuation;
        const continued = try self.run_fn(self.context, turn, follow_up, admission, cancel);
        if (continued == .completed) {
            if (self.lifecycle.observeStop(turn, admission)) |ignored| stop_hook_allocator.free(ignored);
        }
        return continued;
    }
};

const stop_hook_allocator = std.heap.c_allocator;

const task_kind_agent = "agent";

pub const TaskStatus = enum {
    completed,
    failed,
    killed,
    lost,

    pub fn of(outcome: child_state.Outcome) TaskStatus {
        return switch (outcome) {
            .completed => .completed,
            .failed => .failed,
            .cancelled, .interrupted => .killed,
            .lost => .lost,
        };
    }

    fn notificationType(self: TaskStatus) []const u8 {
        return switch (self) {
            .completed => "task.completed",
            .failed => "task.failed",
            .killed => "task.killed",
            .lost => "task.lost",
        };
    }

    fn title(self: TaskStatus) []const u8 {
        return switch (self) {
            .completed => "Background agent completed",
            .failed => "Background agent failed",
            .killed => "Background agent killed",
            .lost => "Background agent lost",
        };
    }

    fn severity(self: TaskStatus) []const u8 {
        return if (self == .completed) "info" else "warning";
    }
};

pub const TaskNotification = struct {
    session_id: []const u8,
    agent_id: []const u8,
    task_id: []const u8,
    status: TaskStatus,
    body: []const u8,
};

pub const Lifecycle = struct {
    view: hooks.RuntimeView = hooks.RuntimeView.empty(),
    workspace_root: []const u8 = "",
    session_title: []const u8 = "",

    fn observeStart(
        self: Lifecycle,
        turn: *TurnContext,
        message: domain.QueuedMessage,
        admission: domain.AdmissionSnapshot,
        cancel: *std.atomic.Value(bool),
    ) void {
        const agent_name = turn.child_name orelse "";
        const fields = [_]hooks.external.Field{
            .{ .key = "agent_name", .value = .{ .string = agent_name } },
            .{ .key = "prompt", .value = .{ .string = message.content } },
            .{ .key = "session_title", .value = .{ .string = self.session_title } },
        };
        self.observe(.SubagentStart, agent_name, admission.parent_id, fields[0..self.fieldCount()], cancel, null);
    }

    fn observeStop(self: Lifecycle, turn: *TurnContext, admission: domain.AdmissionSnapshot) ?[]u8 {
        const agent_name = turn.child_name orelse "";
        const response = turn.sessionRuntime().lastAssistantReply() orelse "";
        const fields = [_]hooks.external.Field{
            .{ .key = "agent_name", .value = .{ .string = agent_name } },
            .{ .key = "response", .value = .{ .string = response } },
            .{ .key = "session_title", .value = .{ .string = self.session_title } },
        };
        var outcome: hooks.ObservationOutcome = .{ .alloc = stop_hook_allocator };
        defer outcome.deinit();
        self.observe(.SubagentStop, agent_name, admission.parent_id, fields[0..self.fieldCount()], null, &outcome);
        if (!outcome.blocked) return null;
        const reason = outcome.reason orelse return null;
        if (reason.len == 0) return null;
        outcome.reason = null;
        return reason;
    }

    fn observeTaskStarted(
        self: Lifecycle,
        turn: *TurnContext,
        message: domain.QueuedMessage,
        admission: domain.AdmissionSnapshot,
    ) void {
        const fields = [_]hooks.external.Field{
            .{ .key = "task_id", .value = .{ .string = message.id } },
            .{ .key = "kind", .value = .{ .string = task_kind_agent } },
            .{ .key = "description", .value = .{ .string = turn.child_name orelse "" } },
            .{ .key = "status", .value = .{ .string = "running" } },
            .{ .key = "detached", .value = .{ .bool = true } },
            .{ .key = "started_at", .value = .{ .integer = io_mod.milliTimestamp() } },
        };
        self.observe(.TaskStarted, task_kind_agent, admission.parent_id, &fields, null, null);
    }

    pub fn observeTaskNotification(self: Lifecycle, notification: TaskNotification) void {
        const fields = [_]hooks.external.Field{
            .{ .key = "sink", .value = .{ .string = "context" } },
            .{ .key = "agent_id", .value = .{ .string = notification.agent_id } },
            .{ .key = "notification_type", .value = .{ .string = notification.status.notificationType() } },
            .{ .key = "title", .value = .{ .string = notification.status.title() } },
            .{ .key = "body", .value = .{ .string = notification.body } },
            .{ .key = "severity", .value = .{ .string = notification.status.severity() } },
            .{ .key = "source_kind", .value = .{ .string = "background_task" } },
            .{ .key = "source_id", .value = .{ .string = notification.task_id } },
        };
        self.observe(.Notification, notification.status.notificationType(), notification.session_id, &fields, null, null);
    }

    fn fieldCount(self: Lifecycle) usize {
        return if (self.session_title.len == 0) 2 else 3;
    }

    fn observe(
        self: Lifecycle,
        event: hooks.external.Event,
        matcher_value: []const u8,
        session_id: []const u8,
        fields: []const hooks.external.Field,
        cancel_flag: ?*std.atomic.Value(bool),
        outcome: ?*hooks.ObservationOutcome,
    ) void {
        self.view.runObservation(.{
            .invocation = .{
                .scope = .{
                    .kind = .subagent,
                    .workspace_root = self.workspace_root,
                    .session_id = session_id,
                },
                .cancel_flag = cancel_flag,
            },
            .event = event,
            .matcher_value = matcher_value,
            .fields = fields,
            .outcome = outcome,
        });
    }
};

const ObservationRecorder = struct {
    calls: usize = 0,
    kind: ?hooks.ScopeKind = null,
    event: ?hooks.external.Event = null,
    matcher: []const u8 = "",
    session_id: []const u8 = "",
    field_count: usize = 0,
    agent_name: []const u8 = "",
    prompt: []const u8 = "",
    response: []const u8 = "",
    session_title: []const u8 = "",
    start_cancel_flag: ?*std.atomic.Value(bool) = null,
    task_started_calls: usize = 0,
    task_id: []const u8 = "",
    task_kind: []const u8 = "",
    notification_type: []const u8 = "",
    severity: []const u8 = "",
    source_id: []const u8 = "",
    body: []const u8 = "",

    fn observe(raw: *anyopaque, input: hooks.ObservationInput) hooks.HandlerError!void {
        const self: *ObservationRecorder = @ptrCast(@alignCast(raw));
        if (input.event == .TaskStarted) {
            self.task_started_calls += 1;
            self.task_kind = input.matcher_value;
            for (input.fields) |field| {
                if (std.mem.eql(u8, field.key, "task_id")) self.task_id = field.value.string;
            }
            return;
        }
        for (input.fields) |field| {
            if (std.mem.eql(u8, field.key, "notification_type")) self.notification_type = field.value.string;
            if (std.mem.eql(u8, field.key, "severity")) self.severity = field.value.string;
            if (std.mem.eql(u8, field.key, "source_id")) self.source_id = field.value.string;
            if (std.mem.eql(u8, field.key, "body")) self.body = field.value.string;
        }
        self.calls += 1;
        self.kind = input.invocation.scope.kind;
        self.event = input.event;
        if (input.event == .SubagentStart) self.start_cancel_flag = input.invocation.cancel_flag;
        self.matcher = input.matcher_value;
        self.session_id = input.invocation.scope.session_id orelse "";
        self.field_count = input.fields.len;
        for (input.fields) |field| {
            if (std.mem.eql(u8, field.key, "agent_name")) self.agent_name = field.value.string;
            if (std.mem.eql(u8, field.key, "prompt")) self.prompt = field.value.string;
            if (std.mem.eql(u8, field.key, "response")) self.response = field.value.string;
            if (std.mem.eql(u8, field.key, "session_title")) self.session_title = field.value.string;
        }
    }
};

const ServiceStub = struct {
    recorder: *const ObservationRecorder,
    outcome: RunOutcome,
    reply: []const u8,
    calls_before_run: usize = 0,

    fn capture(_: ?*anyopaque, _: Allocator, _: CaptureRequest) ServiceError!domain.AdmissionSnapshot {
        return error.AdmissionFailed;
    }

    fn run(
        raw: ?*anyopaque,
        turn: *TurnContext,
        _: domain.QueuedMessage,
        _: domain.AdmissionSnapshot,
        _: *std.atomic.Value(bool),
    ) ServiceError!RunOutcome {
        const self: *ServiceStub = @ptrCast(@alignCast(raw.?));
        self.calls_before_run = self.recorder.calls;
        turn.runtime.appendAssistantHistoryTurn(turn.alloc, "request", self.reply) catch return error.ProviderFailed;
        return self.outcome;
    }
};

fn testLifecycleServices(stub: *ServiceStub, view: hooks.RuntimeView) Services {
    return .{
        .context = stub,
        .capture_fn = ServiceStub.capture,
        .run_fn = ServiceStub.run,
        .lifecycle = .{ .view = view, .workspace_root = "/work", .session_title = "Review run" },
    };
}

test "subagent start observation runs before the child and names the agent, prompt and parent session" {
    const alloc = std.testing.allocator;
    var recorder: ObservationRecorder = .{};
    var runtime = hooks.Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerObservation(.{ .name = "subagent-recorder", .ctx = &recorder, .run = ObservationRecorder.observe });
    var stub: ServiceStub = .{ .recorder = &recorder, .outcome = .paused, .reply = "done" };
    const services = testLifecycleServices(&stub, runtime.freeze());
    var turn = TurnContext.initHosted(alloc, 8);
    defer turn.deinit();
    turn.child_name = "reviewer";
    var cancel = std.atomic.Value(bool).init(false);
    const message: domain.QueuedMessage = .{
        .id = @constCast("message-1"),
        .source_id = @constCast("parent-session"),
        .content = @constCast("review the diff"),
        .created_at_ms = 1,
    };
    const admission: domain.AdmissionSnapshot = .{
        .parent_id = @constCast("parent-session"),
        .source_id = @constCast("parent-session"),
        .model = @constCast("model"),
        .effort = .auto,
        .tool_names = &.{},
        .rules = .{},
        .grants = &.{},
        .integration_names = &.{},
    };
    try std.testing.expectEqual(RunOutcome.paused, try services.run(&turn, message, admission, &cancel));
    try std.testing.expectEqual(@as(usize, 1), stub.calls_before_run);
    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqual(hooks.ScopeKind.subagent, recorder.kind.?);
    try std.testing.expectEqual(hooks.external.Event.SubagentStart, recorder.event.?);
    try std.testing.expectEqualStrings("reviewer", recorder.matcher);
    try std.testing.expectEqualStrings("parent-session", recorder.session_id);
    try std.testing.expectEqualStrings("reviewer", recorder.agent_name);
    try std.testing.expectEqualStrings("review the diff", recorder.prompt);
    try std.testing.expectEqualStrings("Review run", recorder.session_title);
    try std.testing.expectEqual(@as(usize, 3), recorder.field_count);
    try std.testing.expectEqual(@as(usize, 1), recorder.task_started_calls);
    try std.testing.expectEqualStrings("agent", recorder.task_kind);
    try std.testing.expectEqualStrings("message-1", recorder.task_id);
    try std.testing.expect(recorder.start_cancel_flag == &cancel);
}

test "subagent task notification observation names the task status, severity and source for the owning session" {
    const alloc = std.testing.allocator;
    var recorder: ObservationRecorder = .{};
    var runtime = hooks.Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerObservation(.{ .name = "subagent-recorder", .ctx = &recorder, .run = ObservationRecorder.observe });
    const lifecycle: Lifecycle = .{ .view = runtime.freeze(), .workspace_root = "/work" };

    lifecycle.observeTaskNotification(.{
        .session_id = "parent-session",
        .agent_id = "child-1",
        .task_id = "work-1",
        .status = TaskStatus.of(.completed),
        .body = "all checks pass",
    });
    try std.testing.expectEqual(hooks.external.Event.Notification, recorder.event.?);
    try std.testing.expectEqualStrings("task.completed", recorder.matcher);
    try std.testing.expectEqualStrings("task.completed", recorder.notification_type);
    try std.testing.expectEqualStrings("info", recorder.severity);
    try std.testing.expectEqualStrings("work-1", recorder.source_id);
    try std.testing.expectEqualStrings("all checks pass", recorder.body);
    try std.testing.expectEqualStrings("parent-session", recorder.session_id);
    try std.testing.expectEqual(@as(usize, 8), recorder.field_count);

    lifecycle.observeTaskNotification(.{
        .session_id = "parent-session",
        .agent_id = "child-1",
        .task_id = "work-2",
        .status = TaskStatus.of(.cancelled),
        .body = "stopped",
    });
    try std.testing.expectEqualStrings("task.killed", recorder.matcher);
    try std.testing.expectEqualStrings("warning", recorder.severity);
    try std.testing.expectEqualStrings("task.lost", TaskStatus.of(.lost).notificationType());
    try std.testing.expectEqualStrings("task.failed", TaskStatus.of(.failed).notificationType());
}

test "subagent stop observation carries the last reply and fires only when the run completes" {
    const alloc = std.testing.allocator;
    var recorder: ObservationRecorder = .{};
    var runtime = hooks.Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerObservation(.{ .name = "subagent-recorder", .ctx = &recorder, .run = ObservationRecorder.observe });
    var stub: ServiceStub = .{ .recorder = &recorder, .outcome = .completed, .reply = "done" };
    const services = testLifecycleServices(&stub, runtime.freeze());
    var turn = TurnContext.initHosted(alloc, 8);
    defer turn.deinit();
    turn.child_name = "reviewer";
    var cancel = std.atomic.Value(bool).init(false);
    const message: domain.QueuedMessage = .{
        .id = @constCast("message-2"),
        .source_id = @constCast("parent-session"),
        .content = @constCast("summarize"),
        .created_at_ms = 2,
    };
    const admission: domain.AdmissionSnapshot = .{
        .parent_id = @constCast("parent-session"),
        .source_id = @constCast("parent-session"),
        .model = @constCast("model"),
        .effort = .auto,
        .tool_names = &.{},
        .rules = .{},
        .grants = &.{},
        .integration_names = &.{},
    };
    try std.testing.expectEqual(RunOutcome.completed, try services.run(&turn, message, admission, &cancel));
    try std.testing.expectEqual(@as(usize, 2), recorder.calls);
    try std.testing.expectEqual(hooks.external.Event.SubagentStop, recorder.event.?);
    try std.testing.expectEqualStrings("reviewer", recorder.matcher);
    try std.testing.expectEqualStrings("reviewer", recorder.agent_name);
    try std.testing.expectEqualStrings("done", recorder.response);
    try std.testing.expectEqualStrings("Review run", recorder.session_title);

    stub.outcome = .paused;
    try std.testing.expectEqual(RunOutcome.paused, try services.run(&turn, message, admission, &cancel));
    try std.testing.expectEqual(@as(usize, 3), recorder.calls);
    try std.testing.expectEqual(hooks.external.Event.SubagentStart, recorder.event.?);
}

test "a SubagentStop hook block sends its reason to the child as one more message" {
    const alloc = std.testing.allocator;
    const Blocker = struct {
        stops: usize = 0,
        fn observe(raw: *anyopaque, input: hooks.ObservationInput) hooks.HandlerError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (input.event != .SubagentStop) return;
            self.stops += 1;
            const outcome = input.outcome orelse return;
            outcome.blocked = true;
            outcome.reason = outcome.alloc.dupe(u8, "also run the tests") catch return error.Failed;
        }
    };
    const Child = struct {
        runs: usize = 0,
        saw_continuation: bool = false,
        fn capture(_: ?*anyopaque, _: Allocator, _: CaptureRequest) ServiceError!domain.AdmissionSnapshot {
            return error.AdmissionFailed;
        }
        fn run(raw: ?*anyopaque, _: *TurnContext, message: domain.QueuedMessage, _: domain.AdmissionSnapshot, _: *std.atomic.Value(bool)) ServiceError!RunOutcome {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.runs += 1;
            if (std.mem.eql(u8, message.content, "also run the tests")) self.saw_continuation = true;
            return .completed;
        }
    };
    var blocker: Blocker = .{};
    var runtime = hooks.Runtime.init(alloc);
    defer runtime.deinit();
    try runtime.registerObservation(.{ .name = "subagent-stop-blocker", .ctx = &blocker, .run = Blocker.observe });
    var child: Child = .{};
    const services: Services = .{
        .context = &child,
        .capture_fn = Child.capture,
        .run_fn = Child.run,
        .lifecycle = .{ .view = runtime.freeze(), .workspace_root = "/work" },
    };
    var turn = TurnContext.initHosted(alloc, 8);
    defer turn.deinit();
    turn.child_name = "reviewer";
    var cancel = std.atomic.Value(bool).init(false);
    const message: domain.QueuedMessage = .{
        .id = @constCast("message-1"),
        .source_id = @constCast("parent-session"),
        .content = @constCast("review the diff"),
        .created_at_ms = 1,
    };
    const admission: domain.AdmissionSnapshot = .{
        .parent_id = @constCast("parent-session"),
        .source_id = @constCast("parent-session"),
        .model = @constCast("model"),
        .effort = .auto,
        .tool_names = &.{},
        .rules = .{},
        .grants = &.{},
        .integration_names = &.{},
    };
    try std.testing.expectEqual(RunOutcome.completed, try services.run(&turn, message, admission, &cancel));
    try std.testing.expectEqual(@as(usize, 2), child.runs);
    try std.testing.expect(child.saw_continuation);
    try std.testing.expectEqual(@as(usize, 2), blocker.stops);
}

pub const CommitError = error{
    OutOfMemory,
    InvalidWorkId,
    TurnAlreadyCommitted,
    SessionCommitFailed,
};

pub const HostedRelease = struct {
    count: std.atomic.Value(u32) = .init(0),
    released: std.Io.Event = .unset,

    pub fn hold(self: *HostedRelease) void {
        _ = self.count.fetchAdd(1, .acq_rel);
    }

    pub fn release(self: *HostedRelease) void {
        self.released.set(io_mod.getIo());
        _ = self.count.fetchSub(1, .release);
    }

    pub fn held(self: *const HostedRelease) bool {
        return self.count.load(.acquire) > 0;
    }

    pub fn waitReleased(self: *HostedRelease, timeout_ms: i64) bool {
        const deadline = io_mod.milliTimestamp() + timeout_ms;
        while (true) {
            if (!self.held()) return true;
            if (io_mod.milliTimestamp() >= deadline) return false;
            self.released.reset();

            if (!self.held()) return true;
            self.released.waitTimeout(io_mod.getIo(), .{ .duration = .{
                .raw = .fromMilliseconds(50),
                .clock = .awake,
            } }) catch {};
        }
    }
};

test "a hosted agent's waiter wakes when the last hold lets go, or times out" {
    var hosted: HostedRelease = .{};
    try std.testing.expect(hosted.waitReleased(0));
    hosted.hold();
    try std.testing.expect(!hosted.waitReleased(20));
    const Releaser = struct {
        fn run(target: *HostedRelease) void {
            io_mod.sleep(10 * std.time.ns_per_ms);
            target.release();
        }
    };
    const thread = try std.Thread.spawn(.{}, Releaser.run, .{&hosted});
    defer thread.join();
    try std.testing.expect(hosted.waitReleased(5_000));
}

pub const TurnContext = struct {
    alloc: Allocator,
    runtime: session.SessionRuntime,
    worker: worker_runtime.WorkerRuntime = .{},
    hosted_worker: ?*worker_runtime.WorkerRuntime = null,
    hosted_release: ?*HostedRelease = null,
    managed_executions: managed_execution.Runtime,
    child: ?*session_adapter.Session,
    live_authority: ?*authority_mod.Resolver = null,
    approval_registry: ?*approval_registry_mod.Registry = null,
    approval_worker_route: ?approval_registry_mod.WorkerRoute = null,
    child_id: ?[]const u8 = null,
    child_name: ?[]const u8 = null,
    active_work_id: ?[]const u8 = null,
    phase_context: ?*anyopaque = null,
    phase_fn: ?*const fn (
        *anyopaque,
        []const u8,
        []const u8,
        child_state.Phase,
    ) anyerror!void = null,
    live_metrics: ?*live_metrics.LiveMetrics = null,
    failure_diagnostic: ?types.ModelFailureDiagnostic = null,
    committed: bool = false,

    pub fn init(
        alloc: Allocator,
        child: *session_adapter.Session,
        max_history_turns: usize,
    ) !TurnContext {
        var restored = try child.restore(alloc);
        defer restored.deinit(alloc);
        var runtime = session.SessionRuntime{ .max_history_turns = max_history_turns };
        errdefer runtime.deinit(alloc);
        try runtime.restoreWithPermissionState(
            alloc,
            restored.language,
            restored.history,
            restored.permission_state orelse .{},
        );
        runtime.agent.todo.restoreJson(restored.todos);
        return .{
            .alloc = alloc,
            .runtime = runtime,
            .managed_executions = managed_execution.Runtime.init(alloc),
            .child = child,
        };
    }

    pub fn initHosted(alloc: Allocator, max_history_turns: usize) TurnContext {
        return .{
            .alloc = alloc,
            .runtime = .{ .max_history_turns = max_history_turns },
            .managed_executions = managed_execution.Runtime.init(alloc),
            .child = null,
        };
    }

    pub fn isHosted(self: *const TurnContext) bool {
        return self.child == null;
    }

    pub fn deinit(self: *TurnContext) void {
        if (self.hosted_release) |hosted| hosted.release();
        self.managed_executions.deinit();
        self.worker.deinit(self.alloc);
        self.runtime.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn setFailureDiagnostic(
        self: *TurnContext,
        code: []const u8,
        detail: []const u8,
    ) void {
        if (self.failure_diagnostic != null) return;
        self.failure_diagnostic = failureDiagnosticValue(code, detail);
    }

    pub fn failureDiagnostic(self: *const TurnContext) ?types.ModelFailureDiagnostic {
        return self.failure_diagnostic;
    }

    pub fn sessionRuntime(self: *TurnContext) *session.SessionRuntime {
        return &self.runtime;
    }

    pub fn beginTurn(self: *TurnContext) !void {
        const child = self.child orelse return;
        try child.beginTurn();
    }

    pub fn childCapability(
        self: *TurnContext,
    ) !*session_child_store.SessionChildCapability {
        const child = self.child orelse return error.ChildCapabilityUnavailable;
        return child.childCapability();
    }

    pub fn workerRuntime(self: *TurnContext) *worker_runtime.WorkerRuntime {
        return self.hosted_worker orelse &self.worker;
    }

    pub fn managedExecutionRuntime(self: *TurnContext) *managed_execution.Runtime {
        return &self.managed_executions;
    }

    pub fn appendLiveText(_: *TurnContext, _: []const u8) void {}

    pub fn appendLiveEvent(
        _: *TurnContext,
        _: worker_runtime.WorkerEvent,
    ) void {}

    pub fn resolveLiveAuthority(
        self: *TurnContext,
        alloc: Allocator,
    ) authority_mod.Error!authority_mod.Snapshot {
        const resolver = self.live_authority orelse
            return error.HostAuthorityUnavailable;
        return resolver.resolve(
            alloc,
            self.child_id orelse return error.ChildNotAttached,
        );
    }

    pub fn liveToolAuthorityProvider(
        self: *TurnContext,
    ) runtime_deps.LiveToolAuthorityProvider {
        return .{ .context = self, .resolve_fn = resolveLiveToolAction };
    }

    pub fn toolActivityRecorder(self: *TurnContext) runtime_deps.ToolActivityRecorder {
        return .{ .context = self, .record_fn = recordToolActivity };
    }

    pub fn permissionPrompter(self: *TurnContext) permission_prompter.Prompter {
        return .{ .context = self, .request_fn = requestChildPermission };
    }

    fn requestChildPermission(
        raw: *anyopaque,
        alloc: Allocator,
        request: permission_request.PermissionRequest,
        call: types.ToolCall,
        review: ?*const @import("../output/diff.zig").FileReview,
        grant_offer: ?[]const types.PermissionGrant,
    ) !permission_request.OwnedPermissionResponse {
        const self: *TurnContext = @ptrCast(@alignCast(raw));
        const child_id = self.child_id orelse return error.ChildNotAttached;
        const work_id = self.active_work_id orelse return error.StaleRequest;
        const prepared = approval_registry_mod.preparedRequestFingerprint(request);
        const grant = types.PermissionGrant{
            .tool_name = @constCast(call.name),
            .target_path = @constCast(request.command orelse call.name),
        };
        var context = PermissionObservation{
            .turn = self,
            .stable_id = approval_registry_mod.stableApprovalId(
                child_id,
                work_id,
                prepared,
            ),
            .grants = grant_offer orelse &.{grant},
        };
        return self.workerRuntime().requestPermissionBlockingObserved(
            alloc,
            request,
            review,
            .{ .context = &context, .observe_fn = PermissionObservation.observe },
        );
    }

    const PermissionObservation = struct {
        turn: *TurnContext,
        stable_id: [64]u8,
        grants: []const types.PermissionGrant,

        fn observe(
            raw: *anyopaque,
            _: *worker_runtime.WorkerRuntime,
            request: permission_request.PermissionRequest,
        ) error{
            OutOfMemory,
            PermissionRegistrationFailed,
            PermissionCapacityExceeded,
        }!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.turn.registerApproval(
                self.turn.alloc,
                &self.stable_id,
                request,
                self.grants,
            ) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.CapacityExceeded => error.PermissionCapacityExceeded,
                else => error.PermissionRegistrationFailed,
            };
        }
    };

    fn resolveLiveToolAction(
        raw: *anyopaque,
        alloc: Allocator,
        call: types.ToolCall,
        workspace_root: []const u8,
        target: []const u8,
        target_kind: tool_dispatch.PermissionTargetKind,
    ) !runtime_deps.ResolvedLiveToolAuthority {
        const self: *TurnContext = @ptrCast(@alignCast(raw));
        const resolver = self.live_authority orelse return error.HostAuthorityUnavailable;
        return resolveLiveToolActionFor(
            resolver,
            self.child_id orelse return error.ChildNotAttached,
            null,
            alloc,
            call,
            workspace_root,
            target,
            target_kind,
        );
    }

    fn recordToolActivity(
        _: *anyopaque,
        _: []const u8,
        _: []const u8,
        _: runtime_deps.ToolActivityPhase,
    ) !void {}

    pub fn registerApproval(
        self: *TurnContext,
        alloc: Allocator,
        stable_request_id: []const u8,
        request: permission_request.PermissionRequest,
        grants: []const types.PermissionGrant,
    ) (approval_registry_mod.Error || authority_mod.Error)!void {
        const registry = self.approval_registry orelse
            return error.RegistryClosed;
        const worker_route = self.approval_worker_route orelse
            return error.RegistryClosed;
        const child_id = self.child_id orelse return error.ChildNotAttached;
        const work_id = self.active_work_id orelse return error.StaleRequest;
        var authority = try self.resolveLiveAuthority(alloc);
        defer authority.deinit(alloc);
        try self.transitionPhase(work_id, .awaiting_approval);
        registry.registerTool(
            stable_request_id,
            child_id,
            authority.root_id,
            work_id,
            request,
            grants,
            worker_route,
            io_mod.milliTimestamp(),
        ) catch |err| {
            try self.transitionPhase(work_id, .running);
            return err;
        };
    }

    fn transitionPhase(
        self: *TurnContext,
        work_id: []const u8,
        phase: child_state.Phase,
    ) approval_registry_mod.Error!void {
        const apply = self.phase_fn orelse return error.CommitFailed;
        apply(
            self.phase_context orelse return error.CommitFailed,
            self.child_id orelse return error.CommitFailed,
            work_id,
            phase,
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.CommitFailed,
        };
    }

    pub fn commit(self: *TurnContext, work_id: []const u8, turn: types.HistoryTurn) CommitError!void {
        if (self.child == null) return error.SessionCommitFailed;
        if (self.committed) return error.TurnAlreadyCommitted;
        try self.appendCommittedHistory(work_id, turn);
        self.committed = true;
    }

    fn appendCommittedHistory(self: *TurnContext, work_id: []const u8, turn: types.HistoryTurn) CommitError!void {
        var committed_turn = session.dupeHistoryTurn(self.alloc, turn) catch
            return error.OutOfMemory;
        defer session.freeHistoryTurn(self.alloc, committed_turn);
        session.copyWorkIdToTurn(self.alloc, &committed_turn, work_id) catch |err| {
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidWorkId, error.ConflictingWorkId => error.InvalidWorkId,
            };
        };
        var prepared = self.runtime.prepareHistoryEntry(self.alloc, committed_turn) catch
            return error.OutOfMemory;
        var prepared_owned = true;
        defer if (prepared_owned) session.freeHistoryTurn(self.alloc, prepared);

        const child = self.child orelse return error.SessionCommitFailed;
        child.prepareTurn(&prepared) catch |err| return commitFailed(child, work_id, "prepare", err);
        child.commitTurn(prepared, self.runtime.languageSnapshot()) catch |err| return commitFailed(child, work_id, "commit", err);
        self.runtime.commitPreparedHistoryEntry(self.alloc, prepared);
        prepared_owned = false;
    }

    pub fn commitContextCompaction(
        self: *TurnContext,
        summary: types.CompactedSummaryHistoryTurn,
        active_prefix: ?types.AssistantHistoryTurn,
        retained_from: ?types.ContextHistoryCut,
    ) !void {
        const child = self.child orelse return error.SessionCommitFailed;
        var prefix: ?types.HistoryTurn = if (active_prefix) |value|
            try session.dupeHistoryTurn(self.alloc, .{ .assistant = value })
        else
            null;
        defer if (prefix) |value| session.freeHistoryTurn(self.alloc, value);
        if (prefix) |*value| {
            try session.copyWorkIdToTurn(self.alloc, value, self.active_work_id orelse return error.InvalidWorkId);
        }
        const prepared = try session.prepareCompactedHistory(self.alloc, self.runtime.agent.history.items, summary, retained_from orelse .{ .turns = history_range.rawHistoryTurnCount(self.runtime.agent.history.items) });
        errdefer types.freeHistoryTurnSlice(self.alloc, prepared);

        try child.commitCompaction(summary, prefix != null, retained_from);
        self.runtime.commitCompactedHistory(self.alloc, prepared);
    }
};

fn commitFailed(child: *session_adapter.Session, work_id: []const u8, stage: []const u8, err: anyerror) CommitError {
    debug_trace.logf("subagent", "child turn dropped child_id={s} work_id={s} stage={s} err={s}", .{ child.id(), work_id, stage, @errorName(err) });
    return if (err == error.OutOfMemory) error.OutOfMemory else error.SessionCommitFailed;
}

pub fn failureDiagnosticValue(code: []const u8, detail: []const u8) types.ModelFailureDiagnostic {
    const max_bytes = types.ModelFailureDiagnostic.max_bytes;
    const prefix = text_utils.utf8PrefixByBytes(code, max_bytes);
    const safe_detail = if (text_utils.isTerminalSafe(detail))
        text_utils.utf8PrefixByBytes(detail, max_bytes -| prefix.len -| 2)
    else
        "";
    if (safe_detail.len == 0) return types.ModelFailureDiagnostic.init(prefix);
    var buffer: [max_bytes]u8 = undefined;
    const text = buffer[0 .. prefix.len + 2 + safe_detail.len];
    @memcpy(text[0..prefix.len], prefix);
    @memcpy(text[prefix.len..][0..2], ": ");
    @memcpy(text[prefix.len + 2 ..], safe_detail);
    return types.ModelFailureDiagnostic.init(text);
}

test "subagent failure capture is bounded and keeps the first cause without allocation" {
    var turn: TurnContext = undefined;
    turn.failure_diagnostic = null;
    turn.setFailureDiagnostic("agent_turn_failed", "SessionCommitFailed");
    turn.setFailureDiagnostic("cleanup", "OutOfMemory");
    const retained = turn.failureDiagnostic().?;
    turn.failure_diagnostic = null;
    try std.testing.expectEqualStrings("agent_turn_failed: SessionCommitFailed", retained.view());
    const long = failureDiagnosticValue("stage", text_utils.repeat("界", 200));
    try std.testing.expect(long.view().len <= types.ModelFailureDiagnostic.max_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(long.view()));
    const unsafe = failureDiagnosticValue("provider_http_error", "unsafe\x1b[31m");
    try std.testing.expectEqualStrings("provider_http_error", unsafe.view());
}

test "a subagent's tool calls are decided against its admission, whichever engine runs its turn" {
    const Host = struct {
        fn resolve(_: ?*anyopaque, alloc: Allocator, _: []const u8) authority_mod.HostResolveError!authority_mod.HostAuthority {
            return authority_mod.HostAuthority.capture(alloc, &.{ "read_file", "Agent" }, &.{}, .{}, &.{}) catch
                return error.OutOfMemory;
        }
    };
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    const store = parent.stateStore();
    var registry = try child_state.Registry.init(alloc, parent.parent.id());
    defer registry.deinit(alloc);
    var work = child_state.ActiveWork{
        .id = try alloc.dupe(u8, "work-one"),
        .message = try alloc.dupe(u8, "review"),
        .permission_mode = .ask,
        .created_at_ms = 1,
    };
    defer work.deinit(alloc);
    try registry.appendPersistent(alloc, "authority-child", "worker", "", work);
    try store.save(alloc, registry);
    var resolver = authority_mod.Resolver{
        .children = &parent.children,
        .root_id = parent.parent.id(),
        .host = .{ .resolve_fn = Host.resolve },
    };

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const Case = struct { name: []const u8, available: bool };
    for ([_]Case{
        .{ .name = "Agent", .available = true },
        .{ .name = "write_file", .available = false },
        .{ .name = "read_file", .available = true },
    }) |case| {
        const resolved = try resolveLiveToolActionFor(
            &resolver,
            "authority-child",
            null,
            arena.allocator(),
            .{ .id = "call-1", .name = case.name, .arguments_json = "{}" },
            home,
            "",
            .none,
        );
        errdefer std.debug.print("tool {s}: decision {s}\n", .{ case.name, @tagName(resolved.decision) });
        try std.testing.expectEqual(case.available, resolved.decision != .unavailable);
        try std.testing.expectEqual(types.PermissionMode.ask, resolved.authority.permission_mode);
    }
    try std.testing.expectError(
        error.ChildNotAttached,
        resolveLiveToolActionFor(&resolver, "missing-child", null, arena.allocator(), .{ .id = "call-2", .name = "read_file", .arguments_json = "{}" }, home, "", .none),
    );
}
