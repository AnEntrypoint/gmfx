const std = @import("std");
const agents = @import("../agents/agents.zig");
const question_prompt = @import("../agent/question_prompt.zig");
const composer_stash = @import("../input/composer_stash.zig");
const input_action = @import("../input/input_action.zig");
const transcript_runtime = @import("../../ui/transcript/runtime.zig");
const assistant_pacer = @import("../../ui/assistant/pacer.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const app_agent_runtime = @import("app_agent_runtime.zig");
const ui_render = @import("../../ui/render.zig");
const render_input = @import("../../ui/footer/render_input.zig");
const agents_menu_presentation = @import("../../ui/footer/agents_menu_presentation.zig");
const session_mod = @import("../session/session.zig");
const app_worker_runtime = @import("app_worker_runtime.zig");
const app_process_runtime = @import("app_process_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const profiles = @import("../profiles/profiles.zig");
const subagent_execution = @import("../subagent/execution.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const subagent_authority = @import("../subagent/authority.zig");
const subagent_reports = @import("../subagent/reports.zig");
const subagent_child_state = @import("../subagent/child_state.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const permission_request = @import("../permissions/permission_request.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;
const AssistantPacer = assistant_pacer.AssistantPacer;

pub const ScreenSlot = struct {
    transcript: transcript_runtime.TranscriptSlot = .{},
    pacer: AssistantPacer = .{},
    draft: composer_stash.State = .{},
    fast_mode: bool = false,

    pub fn deinit(self: *ScreenSlot, alloc: Allocator) void {
        TranscriptRuntime.deinitSlot(&self.transcript, alloc);
        self.pacer.deinit(alloc);
        self.draft.deinit(alloc);
        self.* = undefined;
    }
};

pub const ChildAgent = struct {
    id: []u8,
    agent: agents.Agent = .{},
    screen: ScreenSlot = .{},
    bound: subagent_execution.HostedRelease = .{},
    view_built: bool = false,
    session_attached: bool = false,
    saved_reply_at_ms: i64 = 0,
    parent_host: ?*subagent_tool_host.Runtime = null,
    name: []u8 = &.{},
    profile: []u8 = &.{},
    approval_asked: u64 = 0,
    question_asked: u64 = 0,
    label_buf: [160]u8 = undefined,

    pub fn displayName(self: *const ChildAgent) []const u8 {
        return if (self.name.len > 0) self.name else self.id;
    }

    fn footerLabel(self: *ChildAgent) []const u8 {
        if (self.workGoing()) return self.displayName();
        return std.mem.print(&self.label_buf, "{s} · done", .{self.displayName()}) catch self.displayName();
    }

    fn workGoing(self: *ChildAgent) bool {
        if (self.agent.child_run) |*run| if (run.inFlight()) return true;
        return turnInFlight(&self.agent) or self.agent.worker.hasPendingEvents();
    }
};

pub const AgentsMenu = struct {
    open: bool = false,
    selected: usize = 0,
    window_start: usize = 0,
    origin: ?*ChildAgent = null,
    close_armed: ?*ChildAgent = null,
    rows: std.ArrayList(render_input.AgentsMenuRow) = .empty,

    pub fn deinit(self: *AgentsMenu, alloc: Allocator) void {
        self.rows.deinit(alloc);
        self.* = .{};
    }
};

const InstanceState = enum {
    needs_approval,
    has_question,
    needs_you,
    working,
    finished,
    idle,

    pub fn label(self: InstanceState) []const u8 {
        return switch (self) {
            .needs_approval => "needs approval",
            .has_question => "has a question",
            .needs_you => "needs you",
            .working => "working",
            .finished => "finished",
            .idle => "idle",
        };
    }
};

pub const Busiest = enum { needs_approval, has_question, needs_you, working, idle };

pub const BusyAgent = struct { name: []const u8, doing: Busiest };

fn busyAs(state: InstanceState) ?Busiest {
    return switch (state) {
        .needs_approval => .needs_approval,
        .has_question => .has_question,
        .needs_you => .needs_you,
        .working => .working,
        .finished, .idle => null,
    };
}

fn moreUrgent(a: InstanceState, b: InstanceState) InstanceState {
    return if (@backingInt(a) <= @backingInt(b)) a else b;
}

fn instanceState(agent: *agents.Agent, request_waits: bool) InstanceState {
    if (agent.approval_prompt.isActive()) return .needs_approval;
    if (agent.question_prompt.isActive()) return .has_question;
    if (request_waits) return .needs_you;
    if (turnInFlight(agent)) return .working;
    if (agent.finished_unseen) return .finished;
    return .idle;
}

fn turnInFlight(agent: *agents.Agent) bool {
    return agent.worker.isProcessing() or agent.worker.queuedPromptCount() > 0;
}

const handoff_alloc = std.heap.c_allocator;

pub const Handoffs = struct {
    mutex: std.Io.Mutex = .init,
    closed: bool = false,
    posts: std.ArrayList(*Post) = .empty,
    reports: std.ArrayList(*ReportPost) = .empty,

    pub fn deinit(self: *Handoffs) void {
        self.posts.deinit(handoff_alloc);
        self.reports.deinit(handoff_alloc);
        self.* = .{};
    }
};

pub const ReportPost = struct {
    host: *subagent_tool_host.Runtime,
    kind: enum { report, message },
    from_owner: bool = false,
    agent: []u8,
    child_id: []u8,
    work_id: []u8,
    outcome: subagent_child_state.Outcome = .completed,
    text: []u8,
    dropped: usize = 0,
    end: subagent_child_state.EndFacts = .{},

    fn create(host: *subagent_tool_host.Runtime, delivery: subagent_tool_host.Delivery) !*ReportPost {
        const post = try handoff_alloc.create(ReportPost);
        errdefer handoff_alloc.destroy(post);
        const agent, const child_id, const work_id, const text = switch (delivery) {
            .report => |report| .{ report.agent, report.child_id, report.work_id, report.output },
            .message => |message| .{ message.agent, message.child_id, "", message.text },
        };
        const owned_agent = try handoff_alloc.dupe(u8, agent);
        errdefer handoff_alloc.free(owned_agent);
        const owned_child = try handoff_alloc.dupe(u8, child_id);
        errdefer handoff_alloc.free(owned_child);
        const owned_work = try handoff_alloc.dupe(u8, work_id);
        errdefer handoff_alloc.free(owned_work);
        post.* = .{
            .host = host,
            .kind = if (delivery == .report) .report else .message,
            .from_owner = delivery == .message and delivery.message.to == .owners_parent,
            .agent = owned_agent,
            .child_id = owned_child,
            .work_id = owned_work,
            .outcome = if (delivery == .report) delivery.report.outcome else .completed,
            .text = try handoff_alloc.dupe(u8, text),
            .dropped = if (delivery == .report) delivery.report.dropped else 0,
            .end = if (delivery == .report) delivery.report.end else .{},
        };
        return post;
    }

    fn destroy(self: *ReportPost) void {
        handoff_alloc.free(self.agent);
        handoff_alloc.free(self.child_id);
        handoff_alloc.free(self.work_id);
        handoff_alloc.free(self.text);
        handoff_alloc.destroy(self);
    }
};

test "a report's hand-off keeps the count a user's stop dropped, and who started and stopped its work" {
    var host: subagent_tool_host.Runtime = undefined;
    const end: subagent_child_state.EndFacts = .{ .started_by = .user, .cause = .user_stop };
    const post = try ReportPost.create(&host, .{ .report = .{ .agent = "reviewer", .child_id = "c1", .work_id = "w1", .outcome = .cancelled, .output = "", .dropped = 2, .end = end } });
    defer post.destroy();
    try std.testing.expectEqual(@as(usize, 2), post.dropped);
    try std.testing.expectEqual(subagent_child_state.Outcome.cancelled, post.outcome);
    try std.testing.expectEqual(end, post.end);
}

pub fn postDelivery(handoffs: *Handoffs, host: *subagent_tool_host.Runtime, delivery: subagent_tool_host.Delivery) subagent_tool_host.PostReportError!void {
    const post = try ReportPost.create(host, delivery);
    handoffs.mutex.lockUncancelable(io_mod.getIo());
    defer handoffs.mutex.unlock(io_mod.getIo());
    if (handoffs.closed) {
        post.destroy();
        return error.AgentGone;
    }
    handoffs.reports.append(handoff_alloc, post) catch {
        post.destroy();
        return error.OutOfMemory;
    };
}

pub const Post = struct {
    turn: *subagent_execution.TurnContext,
    run: ?agents.ChildRun = null,
    message: []const u8 = "",
    state: std.atomic.Value(State) = .init(.posted),
    held: bool = false,

    settled: std.Io.Event = .unset,

    pub const State = enum(u8) { posted, taken, failed, closed };

    pub fn settle(self: *Post, state: State) void {
        self.settled.set(io_mod.getIo());
        self.state.store(state, .release);
    }
};

pub const PostError = error{ OutOfMemory, Cancelled, Failed };

pub fn postAndWait(handoffs: *Handoffs, post: *Post, cancel: *std.atomic.Value(bool)) PostError!void {
    {
        handoffs.mutex.lockUncancelable(io_mod.getIo());
        defer handoffs.mutex.unlock(io_mod.getIo());
        if (handoffs.closed) return error.Cancelled;
        try handoffs.posts.append(handoff_alloc, post);
    }
    while (true) {
        switch (post.state.load(.acquire)) {
            .taken => return,
            .failed => return error.Failed,
            .closed => return error.Cancelled,
            .posted => {},
        }
        if (cancel.load(.seq_cst) and withdraw(handoffs, post)) return error.Cancelled;

        post.settled.waitTimeout(io_mod.getIo(), wake_check) catch {};
    }
}

const wake_check: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } };

const release_timeout_ms: i64 = 5_000;

fn withdraw(handoffs: *Handoffs, post: *Post) bool {
    handoffs.mutex.lockUncancelable(io_mod.getIo());
    defer handoffs.mutex.unlock(io_mod.getIo());
    for (handoffs.posts.items, 0..) |item, index| if (item == post) {
        _ = handoffs.posts.orderedRemove(index);
        return true;
    };
    return false;
}

pub fn waitForCompletion(
    completion: *agents.ChildRunCompletion,
    cancel: *std.atomic.Value(bool),
    worker: *worker_runtime.WorkerRuntime,
) agents.ChildRunCompletion.Outcome {
    while (true) {
        if (completion.result()) |outcome| return outcome;
        if (cancel.load(.seq_cst)) worker.requestTurnCancel();
        completion.done.waitTimeout(io_mod.getIo(), wake_check) catch {};
    }
}

fn orderByListing(children: []*ChildAgent, listing: anytype) void {
    var next: usize = 0;
    for (listing) |entry| {
        for (children[next..], next..) |child, index| {
            if (!std.mem.eql(u8, child.id, entry.id)) continue;
            std.mem.rotate(*ChildAgent, children[next .. index + 1], index - next);
            next += 1;
            break;
        }
    }
}

pub fn appOf(comptime App: type, agent: *@FieldType(App, "main_agent")) *App {
    if (comptime @hasField(@FieldType(App, "main_agent"), "app")) {
        if (agent.app) |owner| return @ptrCast(@alignCast(owner));
    }
    return @alignCast(@fieldParentPtr("main_agent", agent));
}

const OrderEntry = struct {
    role: agents.Role,
    root: usize = 0,
    working: bool = false,
    reply_at_ms: i64 = 0,
};

fn latestReplyAt(history: []const types.HistoryTurn) i64 {
    var index = history.len;
    while (index > 0) {
        index -= 1;
        switch (history[index]) {
            .assistant => |entry| {
                if (entry.assistant.len == 0) continue;
                if (entry.execution.turn_summary) |summary| {
                    if (summary.completed_at_ms > 0) return summary.completed_at_ms;
                }
            },
            .interrupted, .compacted_summary => {},
        }
    }
    return 0;
}

fn switchOrder(entries: []const OrderEntry, out: []usize) void {
    std.debug.assert(out.len == entries.len + 1);
    var next: usize = 0;
    out[next] = 0;
    next += 1;
    appendGroup(entries, 0, out, &next);
    var ordinal: usize = 0;
    for (entries, 0..) |entry, index| {
        if (entry.role != .instance) continue;
        ordinal += 1;
        out[next] = index + 1;
        next += 1;
        appendGroup(entries, ordinal, out, &next);
    }
    std.debug.assert(next == out.len);
}

fn sortMenuOrder(entries: []const OrderEntry, first: OrderEntry, order: []usize) void {
    const Context = struct {
        entries: []const OrderEntry,
        first: OrderEntry,

        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            const left = if (a == 0) ctx.first else ctx.entries[a - 1];
            const right = if (b == 0) ctx.first else ctx.entries[b - 1];
            if (left.working != right.working) return left.working;
            return !left.working and left.reply_at_ms > right.reply_at_ms;
        }
    };
    sort_utils.sort(usize, order, Context{ .entries = entries, .first = first }, Context.lessThan);
}

fn appendGroup(entries: []const OrderEntry, root: usize, out: []usize, next: *usize) void {
    for (entries, 0..) |entry, index| {
        if (entry.role != .subagent or entry.root != root) continue;
        out[next.*] = index + 1;
        next.* += 1;
    }
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const AppAgent = if (@hasField(App, "main_agent")) @FieldType(App, "main_agent") else struct {};
        pub fn visit(
            app: *App,
            child: *ChildAgent,
            context: anytype,
            comptime body: fn (@TypeOf(context), *App, *agents.Agent) anyerror!void,
        ) !void {
            try visitScreen(app, &child.agent, &child.screen, context, body);
        }

        fn visitScreen(
            app: *App,
            agent: *agents.Agent,
            screen: *ScreenSlot,
            context: anytype,
            comptime body: fn (@TypeOf(context), *App, *agents.Agent) anyerror!void,
        ) !void {
            const previous = app.screen_owner;
            app.screen_owner = agent;
            app.shell.swapSlot(&screen.transcript);
            std.mem.swap(AssistantPacer, &app.pacer, &screen.pacer);
            std.mem.swap(bool, &app.fast_mode, &screen.fast_mode);
            defer {
                std.mem.swap(bool, &app.fast_mode, &screen.fast_mode);
                std.mem.swap(AssistantPacer, &app.pacer, &screen.pacer);
                app.shell.swapSlot(&screen.transcript);
                app.screen_owner = previous;
            }
            try body(context, app, agent);
        }

        pub fn hasPendingWork(child: *ChildAgent) bool {
            return child.agent.worker.hasPendingEvents() or child.screen.pacer.hasPending();
        }

        pub fn tickChildren(
            app: *App,
            context: anytype,
            comptime body: fn (@TypeOf(context), *App, *agents.Agent) anyerror!void,
        ) !void {
            try app_worker_runtime.Runtime(App).pushHookFailureNotice(app, &app.main_agent);
            if (app.agent_on_screen != null and
                (app.main_agent.worker.hasPendingEvents() or app.main_screen.pacer.hasPending() or
                    approvalOutOfDate(&app.main_agent, false)))
            {
                try visitScreen(app, &app.main_agent, &app.main_screen, context, body);
            }
            for (app.child_agents.items) |child| {
                if (child == app.agent_on_screen) continue;
                if (!hasPendingWork(child) and !approvalOutOfDate(&child.agent, app.approval_lender == child)) continue;
                try visit(app, child, context, body);
            }
        }

        fn approvalOutOfDate(agent: *agents.Agent, lent: bool) bool {
            const prompt = &agent.approval_prompt;
            const shown = lent or (prompt.isActive() and prompt.rule_management == null);
            return agent.worker.awaitsPermissionDecision() != shown;
        }

        pub fn prepareOwnTurn(app: *App, agent: *AppAgent) !bool {
            const child = app.agent_on_screen orelse return false;

            if (child.agent.role == .instance) return false;
            if (child.agent.worker_thread == null) _ = try ensureChild(app, child.id);
            if (!child.session_attached) try attachSession(app, agent, child);
            const admitted = child.agent.child_run == null or !turnGoing(app, child);
            if (admitted) try admitOwnTurn(app, agent, child);
            debug_trace.eventf("host", "input_routed", .{}, "agent={s}", .{child.id});
            return admitted;
        }

        pub fn openOwnTurnWork(app: *App) void {
            const child = app.agent_on_screen orelse return;
            const run = if (child.agent.child_run) |*value| value else return;
            if (run.inFlight() or run.turn_work_id.len > 0) return;
            const host = hostOf(app, child) orelse return;
            if (host.beginUserWork(app.alloc, child.id, &child.agent.worker)) |work_id| run.turn_work_id = work_id;
        }

        fn setUserRequests(app: *App, agent: *AppAgent, run: *agents.ChildRun) !void {
            var requests: std.ArrayList([]u8) = .empty;
            errdefer {
                for (requests.items) |text| app.alloc.free(text);
                requests.deinit(app.alloc);
            }
            var complete = true;
            for (agent.session.agent.history.items) |turn| {
                const user = switch (turn) {
                    .compacted_summary => {
                        complete = false;
                        continue;
                    },
                    .assistant => |entry| entry.user,
                    .interrupted => |entry| entry.user,
                };
                if (user.work_id != null) continue;
                try requests.append(app.alloc, try app.alloc.dupe(u8, user.text));
            }
            for (run.root_user_messages) |text| app.alloc.free(text);
            app.alloc.free(run.root_user_messages);
            run.root_user_messages = try requests.toOwnedSlice(app.alloc);
            run.root_user_evidence_complete = complete;
        }

        fn admitOwnTurn(app: *App, agent: *AppAgent, child: *ChildAgent) !void {
            const host = hostOf(app, child) orelse return error.SubagentHostUnavailable;
            var admitted = try host.admitUserTurn(app.alloc, child.id, app_permission_runtime.Runtime(App).livePermissionSnapshot(app, &child.agent).mode);
            defer admitted.deinit(app.alloc);
            var run = try app_agent_runtime.Runtime(App).prepareOwnTurnRun(app, child.id, host.authorityResolver(), admitted.instructions, admitted.admission);
            errdefer run.deinit(app.alloc);
            try setUserRequests(app, agent, &run);

            if (child.agent.child_run) |*previous| endUserWork(app.alloc, host, previous, .cancelled, "");
            installChildRun(app, child, run);
            debug_trace.eventf("host", "own_turn_admitted", .{}, "agent={s} model={s} permission_mode={s}", .{
                child.id,
                child.agent.child_run.?.admission.model,
                @tagName(child.agent.child_run.?.admission.permission_mode),
            });
        }

        fn instanceOnScreen(app: *App) ?*AppAgent {
            const on_screen = app.agent_on_screen orelse return &app.main_agent;
            return if (on_screen.agent.role == .instance) &on_screen.agent else null;
        }

        pub const PromptKind = enum { approval, question };

        pub fn notePromptAsked(app: *App, agent: *const agents.Agent, kind: PromptKind) void {
            const child = for (app.child_agents.items) |child| {
                if (&child.agent == agent) break child;
            } else return;
            app.prompt_order += 1;
            switch (kind) {
                .approval => child.approval_asked = app.prompt_order,
                .question => child.question_asked = app.prompt_order,
            }
        }

        pub fn lendPrompt(app: *App) void {
            if (app.approval_lender != null or app.question_lender != null) return;
            const borrower = instanceOnScreen(app) orelse return;
            if (borrower.approval_prompt.isActive() or borrower.question_prompt.isActive()) return;
            var oldest: ?struct { child: *ChildAgent, kind: PromptKind, asked: u64 } = null;
            for (app.child_agents.items) |child| {
                if (!lendsTo(app, child, borrower)) continue;
                const approval = &child.agent.approval_prompt;
                if (approval.isActive() and approval.rule_management == null) {
                    if (oldest == null or child.approval_asked < oldest.?.asked) oldest = .{ .child = child, .kind = .approval, .asked = child.approval_asked };
                }
                if (child.agent.question_prompt.isActive()) {
                    if (oldest == null or child.question_asked < oldest.?.asked) oldest = .{ .child = child, .kind = .question, .asked = child.question_asked };
                }
            }
            const lent = oldest orelse return;
            switch (lent.kind) {
                .approval => lendApproval(app, borrower, lent.child),
                .question => lendQuestion(app, borrower, lent.child),
            }
            app.shell.render_requests.request(.modal);
        }

        fn lendQuestion(app: *App, borrower: *AppAgent, child: *ChildAgent) void {
            std.mem.swap(question_prompt.QuestionPrompt, &borrower.question_prompt, &child.agent.question_prompt);
            borrower.question_prompt.asker = child.displayName();
            app.question_lender = child;
            debug_trace.eventf("host", "question_lent", .{}, "agent={s}", .{child.id});
        }

        pub fn returnQuestion(app: *App) ?*ChildAgent {
            const child = app.question_lender orelse return null;
            const borrower = rootInstance(app, child);
            borrower.question_prompt.asker = "";
            std.mem.swap(question_prompt.QuestionPrompt, &borrower.question_prompt, &child.agent.question_prompt);
            app.question_lender = null;
            app.shell.render_requests.request(.modal);
            return child;
        }

        pub fn settleLentQuestion(app: *App) void {
            const child = app.question_lender orelse return;
            if (child.agent.worker.hasPendingQuestionBatch()) return;
            _ = returnQuestion(app);
            child.agent.question_prompt.discard(app.alloc, "owner_cleared");
        }

        pub fn answerLentQuestion(app: *App, comptime body: fn (*App, *AppAgent) anyerror!void) !bool {
            const child = returnQuestion(app) orelse return false;
            const Answer = struct {
                fn run(_: void, a: *App, lender: *agents.Agent) anyerror!void {
                    try body(a, lender);
                }
            };
            try visit(app, child, {}, Answer.run);
            return true;
        }

        fn lendApproval(app: *App, borrower: *AppAgent, child: *ChildAgent) void {
            std.mem.swap(@TypeOf(child.agent.approval_prompt), &borrower.approval_prompt, &child.agent.approval_prompt);
            app.approval_lender = child;
            debug_trace.eventf("host", "approval_lent", .{}, "agent={s}", .{child.id});
        }

        pub fn returnApproval(app: *App) ?*ChildAgent {
            const child = app.approval_lender orelse return null;
            const borrower = rootInstance(app, child);
            std.mem.swap(@TypeOf(child.agent.approval_prompt), &borrower.approval_prompt, &child.agent.approval_prompt);
            app.approval_lender = null;
            app.shell.render_requests.request(.modal);
            return child;
        }

        pub fn keepLentApproval(app: *App, agent: *AppAgent, pending: ?permission_request.PermissionRequest) bool {
            const lender = app.approval_lender orelse return false;
            const borrower = rootInstance(app, lender);
            if (agent == borrower) {
                if (pending == null) return true;
            } else if (agent == &lender.agent) {
                if (borrower.approval_prompt.request) |lent| {
                    if (pending) |request| if (request.id == lent.id) return true;
                }
            } else return false;
            _ = returnApproval(app);
            return false;
        }

        pub fn lentApproval(app: *App, agent: *AppAgent) ?*ChildAgent {
            const lender = app.approval_lender orelse return null;
            if (agent != rootInstance(app, lender)) return null;
            return lender;
        }

        pub fn answerLentApproval(app: *App, agent: *AppAgent, comptime body: fn (*App, *AppAgent) anyerror!void) !bool {
            if (lentApproval(app, agent) == null) return false;
            const child = returnApproval(app).?;
            const Answer = struct {
                fn run(_: void, a: *App, lender: *agents.Agent) anyerror!void {
                    try body(a, lender);
                }
            };
            try visit(app, child, {}, Answer.run);
            return true;
        }

        pub fn hasAnotherAgent(app: *App) bool {
            syncChildList(app) catch |err| {
                debug_trace.logf("host", "child list sync failed err={s}", .{@errorName(err)});
            };
            return openAgentCount(app) > 1;
        }

        fn openAgentCount(app: *App) usize {
            return @as(usize, if (firstOpen(app)) 1 else 0) + app.child_agents.items.len;
        }

        fn syncChildList(app: *App) !void {
            var hosts: std.ArrayList(*subagent_tool_host.Runtime) = .empty;
            defer hosts.deinit(app.alloc);
            if (app_session_runtime.Runtime(App).subagentHost(app)) |host| try hosts.append(app.alloc, host);
            if (comptime agents.hasAgentField(App, "session_persistence")) {
                for (app.child_agents.items) |hosted| {
                    if (hosted.agent.role != .instance) continue;
                    if (hosted.agent.session_persistence.subagent_host) |host| try hosts.append(app.alloc, host);
                }
            }
            const Listed = struct { id: []const u8 };
            var order: std.ArrayList(Listed) = .empty;
            defer order.deinit(app.alloc);
            var listings: std.ArrayList([]subagent_tool_host.Runtime.ChildListing) = .empty;
            defer {
                for (listings.items) |listing| subagent_tool_host.Runtime.freeChildListing(app.alloc, listing);
                listings.deinit(app.alloc);
            }
            for (hosts.items) |host| {
                const listing = try host.listChildren(app.alloc);
                listings.append(app.alloc, listing) catch |err| {
                    subagent_tool_host.Runtime.freeChildListing(app.alloc, listing);
                    return err;
                };
                for (listing) |entry| {
                    const child = findChild(app, entry.id) orelse restored: {
                        const history = host.childHistory(app.alloc, entry.id) catch |err| {
                            debug_trace.logf("host", "saved reply time unavailable agent={s} err={s}", .{ entry.id, @errorName(err) });
                            break :restored try addChild(app, entry.id);
                        };
                        defer types.freeHistoryTurnSlice(app.alloc, history);
                        const restored_child = try addChild(app, entry.id);
                        restored_child.saved_reply_at_ms = latestReplyAt(history);
                        break :restored restored_child;
                    };
                    if (child.name.len == 0 and entry.name.len > 0) child.name = try app.alloc.dupe(u8, entry.name);
                    if (child.profile.len == 0) child.profile = try app.alloc.dupe(u8, entry.profile);
                    if (child.parent_host == null) setParentHost(app, child, host);
                    try order.append(app.alloc, .{ .id = entry.id });
                }
            }
            orderByListing(app.child_agents.items, order.items);
        }

        pub fn switchList(app: *App, out: *std.ArrayList(?*ChildAgent)) !void {
            const hosted = app.child_agents.items;
            const entries = try app.alloc.alloc(OrderEntry, hosted.len);
            defer app.alloc.free(entries);
            for (hosted, entries) |child, *entry| entry.* = .{
                .role = child.agent.role,
                .root = if (child.agent.role == .subagent) instanceOrdinal(app, rootInstance(app, child)) else 0,
                .working = instanceState(&child.agent, requestWaitsForUser(app, child)) == .working,
                .reply_at_ms = @max(child.saved_reply_at_ms, latestReplyAt(child.agent.session.agent.history.items)),
            };
            const order = try app.alloc.alloc(usize, hosted.len + 1);
            defer app.alloc.free(order);
            switchOrder(entries, order);
            sortMenuOrder(entries, .{
                .role = .instance,
                .working = firstOpen(app) and instanceState(&app.main_agent, requestWaitsForUser(app, null)) == .working,
                .reply_at_ms = if (firstOpen(app)) latestReplyAt(app.main_agent.session.agent.history.items) else 0,
            }, order);
            try out.ensureUnusedCapacity(app.alloc, order.len);
            for (order) |position| {
                if (position == 0 and !firstOpen(app)) continue;
                out.appendAssumeCapacity(if (position == 0) null else hosted[position - 1]);
            }

            if (menuActive(app)) {
                app.instances.agents_menu.selected = positionIn(out.items, app.agent_on_screen) orelse 0;
            }
        }

        pub fn noteName(app: *App, child: ?*ChildAgent, buf: []u8) []const u8 {
            if (child) |value| if (value.agent.role == .subagent) return value.displayName();
            if (openInstanceCount(app) <= 1) return "main";
            const number = instanceNumber(app, child) orelse return "fx";
            return std.mem.print(buf, "fx {d}", .{number}) catch "fx";
        }

        pub fn instanceNumber(app: *App, child: ?*ChildAgent) ?usize {
            var number: usize = 0;
            if (firstOpen(app)) {
                number += 1;
                if (child == null) return number;
            }
            for (app.child_agents.items) |value| {
                if (value.agent.role != .instance) continue;
                number += 1;
                if (value == child) return number;
            }
            return null;
        }

        pub const Home = struct { name: []const u8, key: []const u8 };

        pub fn homeOfScreen(app: *App, name_buf: []u8) ?Home {
            const child = app.agent_on_screen orelse return null;
            if (child.agent.role != .subagent) return null;
            return .{ .name = noteName(app, screenInstance(app), name_buf), .key = switchKey(app) };
        }

        fn screenInstance(app: *App) ?*ChildAgent {
            const child = app.agent_on_screen orelse return null;
            if (child.agent.role != .subagent) return child;
            const root = rootInstance(app, child);
            if (root == &app.main_agent) return null;
            for (app.child_agents.items) |entry| if (&entry.agent == root) return entry;
            return null;
        }

        pub fn waitingNote(app: *App, buf: []u8) []const u8 {
            var first: ?*ChildAgent = null;
            var found = false;
            var state: InstanceState = .needs_approval;
            var count: usize = 0;
            if (app.agent_on_screen != null and firstOpen(app)) {
                const main_waiting = if (app.main_agent.approval_prompt.request) |request|
                    request.origin == .active_session
                else
                    false;
                const asks = app.main_agent.question_prompt.isActive();
                if (main_waiting or asks or requestWaitsForUser(app, null)) {
                    found = true;
                    state = if (main_waiting) .needs_approval else if (asks) .has_question else .needs_you;
                    count += 1;
                }
            }
            for (app.child_agents.items) |child| {
                if (child == app.agent_on_screen) continue;
                const approval = child.agent.approval_prompt.isActive();
                const asks = child.agent.question_prompt.isActive();
                if (!approval and !asks and !requestWaitsForUser(app, child)) continue;
                if (!found) {
                    first = child;
                    found = true;
                    state = if (approval) .needs_approval else if (asks) .has_question else .needs_you;
                }
                count += 1;
            }
            if (!found) return finishedNote(app, buf);
            var name_buf: [32]u8 = undefined;
            const name = noteName(app, first, &name_buf);
            return if (count > 1)
                std.mem.print(buf, "{s} and {d} more need you", .{ name, count - 1 }) catch ""
            else
                std.mem.print(buf, "{s} {s}", .{ name, state.label() }) catch "";
        }

        pub fn switchKey(app: *App) []const u8 {
            return if (composerIdle(app)) "↓" else "ctrl+x";
        }

        pub fn composerIdle(app: *App) bool {
            if (comptime !@hasField(App, "input_runtime")) return true;
            const input = &app.input_runtime;
            if (input.edit_state.input.items.len > 0) return false;
            if (input.entities.pasted_blocks.items.len > 0) return false;
            if (agents.screenAgentOf(app).pending_images.items.len > 0) return false;
            return input.composer_history.activeIndex() == null;
        }

        fn positionIn(order: []const ?*ChildAgent, agent: ?*ChildAgent) ?usize {
            for (order, 0..) |value, index| if (value == agent) return index;
            return null;
        }

        pub fn anyWorkGoing(app: *App) bool {
            if (app.main_agent.worker.isProcessing() or app.main_agent.worker.queuedPromptCount() > 0) return true;
            for (app.child_agents.items) |child| if (child.workGoing()) return true;
            return false;
        }

        pub fn busiest(app: *App) Busiest {
            var most: InstanceState = .idle;
            if (firstOpen(app)) most = moreUrgent(most, instanceState(&app.main_agent, requestWaitsForUser(app, null)));
            for (app.child_agents.items) |child| {
                most = moreUrgent(most, instanceState(&child.agent, requestWaitsForUser(app, child)));
            }
            return busyAs(most) orelse .idle;
        }

        pub fn busyAgentElsewhere(app: *App, buf: []u8) ?BusyAgent {
            if (app.agent_on_screen != null and firstOpen(app)) {
                if (busyAs(instanceState(&app.main_agent, requestWaitsForUser(app, null)))) |doing| {
                    return .{ .name = noteName(app, null, buf), .doing = doing };
                }
            }
            for (app.child_agents.items) |child| {
                if (child == app.agent_on_screen) continue;
                if (busyAs(instanceState(&child.agent, requestWaitsForUser(app, child)))) |doing| {
                    return .{ .name = noteName(app, child, buf), .doing = doing };
                }
            }
            return null;
        }

        fn targetAgent(app: *App, target: ?*ChildAgent) *AppAgent {
            return if (target) |child| &child.agent else &app.main_agent;
        }

        pub fn noteFinishedTurns(app: *App) void {
            var changed = false;
            if (firstOpen(app)) changed = noteFinished(&app.main_agent, app.agent_on_screen == null) or changed;
            for (app.child_agents.items) |child| {
                if (child.agent.role != .instance) continue;
                changed = noteFinished(&child.agent, child == app.agent_on_screen) or changed;
            }
            if (changed) app.shell.render_requests.request(.footer);
        }

        fn noteFinished(agent: *AppAgent, on_screen: bool) bool {
            const going = turnInFlight(agent);
            const finished = if (on_screen) false else agent.finished_unseen or (agent.was_working and !going);
            const changed = going != agent.was_working or finished != agent.finished_unseen;
            agent.was_working = going;
            agent.finished_unseen = finished;
            return changed;
        }

        pub fn workingNote(app: *App, buf: []u8) []const u8 {
            var count: usize = 0;
            for (app.child_agents.items) |child| {
                if (child.agent.role != .subagent or child == app.agent_on_screen) continue;
                if (turnInFlight(&child.agent)) count += 1;
            }
            if (count == 0) return "";
            return std.mem.print(buf, "{d} subagent{s} working", .{ count, if (count == 1) "" else "s" }) catch "";
        }

        pub fn finishedNote(app: *App, buf: []u8) []const u8 {
            if (openInstanceCount(app) <= 1) return "";
            var first: ?*ChildAgent = null;
            var found = false;
            var count: usize = 0;
            if (firstOpen(app) and app.agent_on_screen != null and app.main_agent.finished_unseen) {
                found = true;
                count += 1;
            }
            for (app.child_agents.items) |child| {
                if (child.agent.role != .instance or child == app.agent_on_screen or !child.agent.finished_unseen) continue;
                if (!found) first = child;
                found = true;
                count += 1;
            }
            if (!found) return "";
            var name_buf: [32]u8 = undefined;
            const name = noteName(app, first, &name_buf);
            return if (count > 1)
                std.mem.print(buf, "{s} and {d} more finished", .{ name, count - 1 }) catch ""
            else
                std.mem.print(buf, "{s} finished", .{name}) catch "";
        }

        pub fn menuActive(app: *App) bool {
            if (comptime !@hasField(App, "instances")) return false;
            return app.instances.agents_menu.open;
        }

        pub fn openMenu(app: *App) !void {
            if (comptime !@hasField(App, "instances")) return;
            syncChildList(app) catch |err| {
                debug_trace.logf("host", "child list sync failed err={s}", .{@errorName(err)});
            };
            var order: std.ArrayList(?*ChildAgent) = .empty;
            defer order.deinit(app.alloc);
            try switchList(app, &order);
            const menu = &app.instances.agents_menu;
            menu.selected = positionIn(order.items, app.agent_on_screen) orelse 0;
            menu.window_start = 0;
            menu.origin = app.agent_on_screen;
            menu.open = true;
            debug_trace.eventf("host", "agents_menu_opened", .{}, "agents={d} position={d} agent={s}", .{
                order.items.len,
                menu.selected + 1,
                nameOf(app.agent_on_screen),
            });
            app.shell.render_requests.request(.footer);
        }

        pub fn closeMenu(app: *App) bool {
            if (!menuActive(app)) return false;
            endMenu(app);
            debug_trace.eventf("host", "agents_menu_closed", .{}, "agent={s}", .{nameOf(app.agent_on_screen)});
            return true;
        }

        fn endMenu(app: *App) void {
            const menu = &app.instances.agents_menu;
            menu.open = false;
            menu.origin = null;
            app.shell.render_requests.request(.footer);
        }

        pub fn backMenu(app: *App) !bool {
            if (!menuActive(app)) return false;
            const origin = app.instances.agents_menu.origin;
            endMenu(app);
            var order: std.ArrayList(?*ChildAgent) = .empty;
            defer order.deinit(app.alloc);
            try switchList(app, &order);
            if (positionIn(order.items, origin) != null) {
                try show(app, origin);
            } else {
                debug_trace.logf("host", "agents menu origin closed; keeping agent={s}", .{nameOf(app.agent_on_screen)});
            }
            debug_trace.eventf("host", "agents_menu_back", .{}, "agent={s}", .{nameOf(app.agent_on_screen)});
            return true;
        }

        pub fn moveMenu(app: *App, delta: i32, row_budget: u16) !bool {
            if (!menuActive(app)) return false;
            disarmClose(app);
            var order: std.ArrayList(?*ChildAgent) = .empty;
            defer order.deinit(app.alloc);
            try switchList(app, &order);
            if (order.items.len == 0) return true;
            const menu = &app.instances.agents_menu;
            const last: i64 = @intCast(order.items.len - 1);
            const current: i64 = @intCast(@min(menu.selected, order.items.len - 1));
            menu.selected = @intCast(std.math.clamp(current + delta, 0, last));
            const target = order.items[menu.selected];
            if (target != app.agent_on_screen) try show(app, target);
            menu.window_start = agents_menu_presentation.windowStart(menuProjection(app), row_budget);
            app.shell.render_requests.request(.footer);
            debug_trace.eventf("host", "agents_menu_previewed", .{}, "position={d} agent={s}", .{ menu.selected + 1, nameOf(target) });
            return true;
        }

        pub fn submitMenu(app: *App) !bool {
            if (!menuActive(app)) return false;
            var order: std.ArrayList(?*ChildAgent) = .empty;
            defer order.deinit(app.alloc);
            try switchList(app, &order);
            const selected = app.instances.agents_menu.selected;
            endMenu(app);

            if (order.items.len > 0) {
                const chosen = order.items[@min(selected, order.items.len - 1)];
                if (chosen != app.agent_on_screen) try show(app, chosen);
            }
            debug_trace.eventf("host", "agents_menu_chosen", .{}, "agent={s}", .{nameOf(app.agent_on_screen)});
            return true;
        }

        pub fn menuProjection(app: *App) render_input.AgentsMenuProjection {
            if (!menuActive(app)) return .{};
            const menu = &app.instances.agents_menu;
            var order: std.ArrayList(?*ChildAgent) = .empty;
            defer order.deinit(app.alloc);
            switchList(app, &order) catch return .{};
            menu.rows.clearRetainingCapacity();
            menu.rows.ensureTotalCapacity(app.alloc, order.items.len) catch return .{};
            for (order.items) |target| {
                const agent = targetAgent(app, target);
                const subagent: ?*ChildAgent = if (target) |child| (if (child.agent.role == .subagent) child else null) else null;
                const model = provider_runtime.modelOf(app, agent);
                menu.rows.appendAssumeCapacity(.{
                    .number = if (subagent == null) instanceNumber(app, target) orelse 0 else 0,
                    .subagent_name = if (subagent) |child| child.displayName() else "",
                    .title = agent.session_title.items,

                    .profile = if (subagent) |child| (if (child.profile.len > 0) child.profile else profiles.main_name) else agent.profile.profile.name,
                    .state = instanceState(agent, requestWaitsForUser(app, target)).label(),
                    .on_screen = target == menu.origin,
                    .model = model,
                    .effort = effortLabel(app, agent, model),
                });
            }
            if (menu.selected >= menu.rows.items.len) menu.selected = menu.rows.items.len -| 1;
            const chosen: ?*ChildAgent = if (order.items.len > 0) order.items[@min(menu.selected, order.items.len - 1)] else null;
            const closable = if (chosen) |child| child.agent.role == .subagent else false;
            return .{
                .rows = menu.rows.items,
                .selected = menu.selected,
                .window_start = menu.window_start,
                .selected_closable = closable,
                .close_armed = closable and menu.close_armed == chosen,
            };
        }

        pub fn pressCloseKey(app: *App) !bool {
            if (!menuActive(app)) return false;
            var order: std.ArrayList(?*ChildAgent) = .empty;
            defer order.deinit(app.alloc);
            try switchList(app, &order);
            if (order.items.len == 0) return true;
            const menu = &app.instances.agents_menu;
            const target = order.items[@min(menu.selected, order.items.len - 1)] orelse return true;
            if (target.agent.role != .subagent) return true;
            if (menu.close_armed != target) {
                menu.close_armed = target;
                debug_trace.eventf("host", "agents_menu_close_armed", .{}, "agent={s}", .{target.id});

                app.shell.render_requests.request(.footer);
                return true;
            }
            menu.close_armed = null;
            try closeSubagent(app, target);
            return true;
        }

        pub fn disarmClose(app: *App) void {
            if (comptime !@hasField(App, "instances")) return;
            const menu = &app.instances.agents_menu;
            if (menu.close_armed == null) return;
            menu.close_armed = null;
            debug_trace.eventf("host", "agents_menu_close_disarmed", .{}, "reason=key", .{});
            app.shell.render_requests.request(.footer);
        }

        fn closeSubagent(app: *App, child: *ChildAgent) !void {
            const host = hostOf(app, child) orelse {
                debug_trace.logf("host", "close dropped agent={s} reason=no_host", .{child.id});
                return;
            };
            const id = try app.alloc.dupe(u8, child.id);
            defer app.alloc.free(id);
            const closed = host.closeChild(id, .user) catch |err| switch (err) {
                error.CloseNotSaved => {
                    debug_trace.logf("host", "close not saved agent={s}", .{id});
                    return;
                },
                else => return err,
            };
            if (closed == null) {
                debug_trace.logf("host", "close found no child agent={s}", .{id});
                return;
            }
            _ = try dropClosedSubagents(app);
        }

        pub fn dropClosedSubagents(app: *App) !bool {
            var dropped = false;

            while (try takeAnyClosed(app)) |ids| {
                defer {
                    for (ids) |id| app.alloc.free(id);
                    app.alloc.free(ids);
                }
                for (ids) |id| if (findChild(app, id)) |child| {
                    try closeBranch(app, child);
                    dropped = true;
                };
            }
            return dropped;
        }

        fn takeAnyClosed(app: *App) !?[][]u8 {
            if (comptime !agents.hasAgentField(App, "session_persistence")) return null;
            if (firstOpen(app)) if (app.main_agent.session_persistence.subagent_host) |host| {
                const ids = try host.takeClosed(app.alloc);
                if (ids.len > 0) return ids;
            };
            for (app.child_agents.items) |child| if (child.agent.session_persistence.subagent_host) |host| {
                const ids = try host.takeClosed(app.alloc);
                if (ids.len > 0) return ids;
            };
            return null;
        }

        fn descendsFrom(app: *App, entry: *const ChildAgent, ancestor: *const ChildAgent) bool {
            var current = entry;
            while (current.agent.role == .subagent) {
                const owner = ownerOf(app, hostOf(app, current)) orelse return false;
                const hosted = hostedOf(app, owner) orelse return false;
                if (hosted == ancestor) return true;
                current = hosted;
            }
            return false;
        }

        fn inBranch(branch: []const *ChildAgent, value: ?*ChildAgent) bool {
            const wanted = value orelse return false;
            return std.mem.findScalar(*ChildAgent, branch, wanted) != null;
        }

        fn closeBranch(app: *App, child: *ChildAgent) !void {
            var branch: std.ArrayList(*ChildAgent) = .empty;
            defer branch.deinit(app.alloc);
            try branch.append(app.alloc, child);
            for (app.child_agents.items) |entry| {
                if (entry != child and descendsFrom(app, entry, child)) try branch.append(app.alloc, entry);
            }
            const parent: ?*ChildAgent = if (ownerOf(app, hostOf(app, child))) |owner| hostedOf(app, owner) else null;
            if (inBranch(branch.items, app.agent_on_screen)) try show(app, parent);
            const menu = &app.instances.agents_menu;
            if (inBranch(branch.items, menu.origin)) menu.origin = parent;
            stopSet(app, branch.items, null);
            debug_trace.eventf("host", "subagent_closed", .{}, "agent={s} subagents={d}", .{ child.id, branch.items.len - 1 });
            dropSet(app, branch.items);

            if (menuActive(app)) {
                var order: std.ArrayList(?*ChildAgent) = .empty;
                defer order.deinit(app.alloc);
                try switchList(app, &order);
                menu.selected = positionIn(order.items, app.agent_on_screen) orelse 0;
                menu.window_start = @min(menu.window_start, menu.selected);
                app.shell.render_requests.request(.footer);
            }
        }

        fn stopSet(app: *App, set: []const *ChildAgent, first_host: ?*subagent_tool_host.Runtime) void {
            const menu = &app.instances.agents_menu;
            if (inBranch(set, menu.close_armed)) {
                menu.close_armed = null;
                debug_trace.eventf("host", "agents_menu_close_disarmed", .{}, "reason=closed", .{});
            }
            if (inBranch(set, app.approval_lender)) _ = returnApproval(app);
            if (inBranch(set, app.question_lender)) _ = returnQuestion(app);
            if (comptime agents.hasAgentField(App, "session_persistence")) {
                if (first_host) |host| host.closeTree();
                for (set) |entry| if (entry.agent.session_persistence.subagent_host) |host| host.closeTree();
            }
            for (set) |entry| {
                entry.agent.worker.requestCancel();
                entry.agent.worker.requestShutdown();
                entry.agent.managed_executions.shutdown();
            }
            for (set) |entry| {
                if (entry.agent.worker_thread) |thread| thread.join();
                entry.agent.worker_thread = null;
                if (entry.agent.child_run) |*run| {
                    finishRun(run, .cancelled);

                    if (hostOf(app, entry)) |host| endUserWork(app.alloc, host, run, .cancelled, "");
                }
            }
        }

        fn dropSet(app: *App, set: []const *ChildAgent) void {
            var index = set.len;
            while (index > 0) {
                index -= 1;
                dropHosted(app, set[index]);
            }
        }

        fn effortLabel(app: *App, agent: *const AppAgent, model: []const u8) []const u8 {
            if (agent.effort.isDefault()) return "";
            const capabilities = model_capabilities.resolveForApp(App, app, model);
            if (capabilities.reasoning_efforts.len == 0) return "";
            if (!model_capabilities.reasoningEffortSupported(capabilities, agent.effort)) return "";
            return agent.effort.displayLabel();
        }

        pub fn pollSessionTitles(app: *App) !bool {
            const SessionRuntime = app_session_runtime.Runtime(App);
            var changed = false;
            if (firstOpen(app)) changed = try SessionRuntime.pollSessionTitleGeneration(app, &app.main_agent);
            for (app.child_agents.items) |child| {
                if (try SessionRuntime.pollSessionTitleGeneration(app, &child.agent)) changed = true;
            }
            return changed;
        }

        pub fn firstOpen(app: anytype) bool {
            if (comptime !@hasField(App, "instances")) return true;
            return app.instances.first_open;
        }

        pub fn firstInstance(app: anytype) ?*AppAgent {
            if (firstOpen(app)) return &app.main_agent;
            for (app.child_agents.items) |child| if (child.agent.role == .instance) return &child.agent;
            return null;
        }

        pub fn openInstanceCount(app: *App) usize {
            var count: usize = if (firstOpen(app)) 1 else 0;
            for (app.child_agents.items) |child| {
                if (child.agent.role == .instance) count += 1;
            }
            return count;
        }

        fn instanceOrdinal(app: *App, agent: *const AppAgent) usize {
            var ordinal: usize = 0;
            for (app.child_agents.items) |child| {
                if (child.agent.role != .instance) continue;
                ordinal += 1;
                if (&child.agent == agent) return ordinal;
            }
            return 0;
        }

        pub fn footerIndicator(app: *App) []const u8 {
            if (openAgentCount(app) <= 1) return "";
            var name_buf: [32]u8 = undefined;
            const name = footerName(app, &name_buf);
            const key = switchKey(app);
            const separator = if (composerIdle(app)) " " else " · ";
            return std.mem.print(&app.instances.label_buf, "{s}{s}{s}", .{ name, separator, key }) catch key;
        }

        fn footerName(app: *App, buf: []u8) []const u8 {
            if (app.agent_on_screen) |child| if (child.agent.role == .subagent) return child.footerLabel();
            const total = openInstanceCount(app);
            if (total <= 1) return "main";
            const position = instanceNumber(app, app.agent_on_screen) orelse 1;
            return std.mem.print(buf, "fx {d}/{d}", .{ position, total }) catch "fx";
        }

        pub fn rootInstance(app: *App, child: *const ChildAgent) *AppAgent {
            var current = child;
            while (true) {
                const owner = ownerOf(app, hostOf(app, current)) orelse return &app.main_agent;
                if (owner == &app.main_agent) return owner;
                const hosted = hostedOf(app, owner) orelse return &app.main_agent;
                if (hosted.agent.role == .instance) return owner;
                current = hosted;
            }
        }

        fn ownerOf(app: *App, host: ?*subagent_tool_host.Runtime) ?*AppAgent {
            const wanted = host orelse return null;
            if (app_session_runtime.Runtime(App).ownSubagentHost(&app.main_agent) == wanted) return &app.main_agent;
            for (app.child_agents.items) |child| {
                if (app_session_runtime.Runtime(App).ownSubagentHost(&child.agent) == wanted) return &child.agent;
            }
            return null;
        }

        fn hostedOf(app: *App, agent: *const AppAgent) ?*ChildAgent {
            for (app.child_agents.items) |child| if (&child.agent == agent) return child;
            return null;
        }

        fn lendsTo(app: *App, child: *const ChildAgent, borrower: *const AppAgent) bool {
            return child.agent.role == .subagent and rootInstance(app, child) == borrower;
        }

        pub fn show(app: *App, target: ?*ChildAgent) !void {
            const from = app.agent_on_screen;
            if (from == target) return;
            attach(app, target);
            if (target) |child| {
                if (!child.view_built) buildSavedView(app, agents.screenAgentOf(app), child);

                if (!child.session_attached) attachSession(app, agents.screenAgentOf(app), child) catch |err| {
                    debug_trace.logf("host", "session not opened on show agent={s} err={s}", .{ child.id, @errorName(err) });
                };
            }
            debug_trace.eventf("host", "agent_switched", .{}, "agent={s} from={s}", .{ nameOf(target), nameOf(from) });

            app_session_runtime.Runtime(App).syncTerminalTitle(app, agents.screenAgentOf(app));
            try app.shell.requestTerminalReset(&app.metrics);
            app.shell.render_requests.request(.footer);
            debug_trace.eventf("host", "screen_reprinted", .{}, "agent={s} entries={d}", .{
                nameOf(target),
                app.shell.notebook.entries.items.len,
            });
        }

        fn buildView(app: *App, agent: *AppAgent, history: []const types.HistoryTurn) !void {
            if (history.len > 0) return app_session_runtime.Runtime(App).rebuildChildView(app, agent, history);
            const welcome = try ui_render.welcomeMessage(app.alloc);
            defer app.alloc.free(welcome);
            try app.writeTranscriptClassified(welcome, true, .welcome);
        }

        fn buildSavedView(app: *App, agent: *AppAgent, child: *ChildAgent) void {
            child.view_built = true;

            if (child.agent.role == .instance) {
                buildView(app, agent, child.agent.session.agent.history.items) catch |err| {
                    debug_trace.logf("host", "instance view failed agent={s} err={s}", .{ child.id, @errorName(err) });
                };
                return;
            }
            const host = hostOf(app, child) orelse return;
            const history = host.childHistory(app.alloc, child.id) catch |err| {
                debug_trace.logf("host", "saved view unavailable agent={s} err={s}", .{ child.id, @errorName(err) });
                return;
            };
            defer types.freeHistoryTurnSlice(app.alloc, history);
            buildView(app, agent, history) catch |err| {
                debug_trace.logf("host", "saved view failed agent={s} err={s}", .{ child.id, @errorName(err) });
                return;
            };
            debug_trace.eventf("host", "agent_view_rebuilt", .{}, "agent={s} turns={d}", .{ child.id, history.len });
        }

        fn attach(app: *App, target: ?*ChildAgent) void {
            _ = returnQuestion(app);
            _ = returnApproval(app);
            const leaving = screenOf(app, app.agent_on_screen);
            const arriving = screenOf(app, target);
            if (leaving == arriving) return;
            leaving.draft = composer_stash.State.capture(app.input_runtime.composerStashView());
            app.shell.swapSlot(&leaving.transcript);
            std.mem.swap(AssistantPacer, &app.pacer, &leaving.pacer);
            std.mem.swap(bool, &app.fast_mode, &leaving.fast_mode);
            app.shell.swapSlot(&arriving.transcript);
            std.mem.swap(AssistantPacer, &app.pacer, &arriving.pacer);
            std.mem.swap(bool, &app.fast_mode, &arriving.fast_mode);
            arriving.draft.restore(app.alloc, app.input_runtime.composerStashView());
            app.agent_on_screen = target;
            app.screen_owner = if (target) |child| &child.agent else null;
        }

        fn turnGoing(app: *App, child: *ChildAgent) bool {
            const pacer = if (app.agent_on_screen == child) &app.pacer else &child.screen.pacer;
            return child.workGoing() or pacer.hasPending();
        }

        fn screenOf(app: *App, child: ?*ChildAgent) *ScreenSlot {
            return if (child) |value| &value.screen else &app.main_screen;
        }

        fn requestWaitsForUser(app: *App, target: ?*ChildAgent) bool {
            if (target == app.agent_on_screen) {
                if (comptime !@hasDecl(@TypeOf(app.shell), "worker_status_state")) return false;
                return app.shell.worker_status_state().waitsForUser();
            }
            return screenOf(app, target).transcript.notebook.worker_status.waitsForUser();
        }

        fn nameOf(child: ?*ChildAgent) []const u8 {
            return if (child) |value| value.id else "main";
        }

        pub fn shutdownChildren(app: *App) void {
            noteQuitting(app);
            attach(app, null);
            closeHandoffs(app);
            var index = app.child_agents.items.len;
            while (index > 0) {
                index -= 1;
                const child = app.child_agents.items[index];
                visit(app, child, {}, shutdownInContext) catch |err| {
                    app_session_runtime.Runtime(App).recordShutdownFailure(firstInstance(app) orelse &app.main_agent, err);
                };
            }

            for (app.child_agents.items) |child| {
                if (!child.bound.waitReleased(release_timeout_ms)) {
                    debug_trace.logf("host", "child_release_timeout child={s} at=shutdown", .{child.id});
                }
            }
        }

        pub fn stopChildren(app: *App, comptime mode: enum { cooperative, force }) void {
            noteQuitting(app);

            attach(app, null);
            closeHandoffs(app);
            for (app.child_agents.items) |child| {
                child.agent.worker.requestCancel();
                child.agent.worker.requestShutdown();
                switch (mode) {
                    .cooperative => child.agent.managed_executions.shutdown(),
                    .force => child.agent.managed_executions.terminateForProcessExit(),
                }
            }
            for (app.child_agents.items) |child| {
                if (child.agent.worker_thread) |thread| thread.join();
                child.agent.worker_thread = null;
                if (child.agent.child_run) |*run| finishRun(run, .cancelled);
            }
        }

        fn closeHandoffs(app: *App) void {
            app.child_handoffs.mutex.lockUncancelable(io_mod.getIo());
            defer app.child_handoffs.mutex.unlock(io_mod.getIo());
            app.child_handoffs.closed = true;
            for (app.child_handoffs.posts.items) |post| post.settle(.closed);
            app.child_handoffs.posts.clearRetainingCapacity();
            for (app.child_handoffs.reports.items) |post| {
                debug_trace.eventf("host", "child_delivery_dropped", .{}, "child={s} work_id={s} reason=shutdown", .{ post.child_id, post.work_id });
                post.destroy();
            }
            app.child_handoffs.reports.clearRetainingCapacity();
        }

        fn deliverReports(app: *App) void {
            var posted: std.ArrayList(*ReportPost) = .empty;
            {
                app.child_handoffs.mutex.lockUncancelable(io_mod.getIo());
                defer app.child_handoffs.mutex.unlock(io_mod.getIo());
                if (app.child_handoffs.closed) return;
                std.mem.swap(std.ArrayList(*ReportPost), &posted, &app.child_handoffs.reports);
            }
            defer posted.deinit(handoff_alloc);
            for (posted.items) |post| {
                defer post.destroy();
                deliverReport(app, post) catch |err| {
                    debug_trace.eventf("host", "child_delivery_dropped", .{}, "child={s} work_id={s} kind={s} reason={s}", .{ post.child_id, post.work_id, @tagName(post.kind), @errorName(err) });
                };
            }
        }

        fn receiverOf(app: *App, host: *subagent_tool_host.Runtime, from_owner: bool) ?*AppAgent {
            const owner = ownerOf(app, host) orelse return null;
            if (!from_owner) return owner;
            const child = hostedOf(app, owner) orelse return null;
            return ownerOf(app, hostOf(app, child));
        }

        pub fn reserveMessagePlace(app: *App, host: *subagent_tool_host.Runtime, from_owner: bool) subagent_tool_host.PostReportError!void {
            const receiver = blk: {
                app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
                defer app.permission_state.authority_mutex.unlock(io_mod.getIo());
                break :blk receiverOf(app, host, from_owner) orelse return error.AgentGone;
            };

            if (!receiver.worker.reserveAgentMessage()) return error.QueueFull;
        }

        pub fn releaseMessagePlace(app: *App, host: *subagent_tool_host.Runtime, from_owner: bool) void {
            const receiver = blk: {
                app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
                defer app.permission_state.authority_mutex.unlock(io_mod.getIo());
                break :blk receiverOf(app, host, from_owner) orelse return;
            };
            receiver.worker.releaseAgentMessage();
        }

        fn deliverReport(app: *App, post: *ReportPost) !void {
            const message = post.kind == .message;
            const target = receiverOf(app, post.host, message and post.from_owner) orelse return error.AgentGone;

            const owner_child: ?*ChildAgent = if (message and post.from_owner) blk: {
                const owner = ownerOf(app, post.host) orelse return error.AgentGone;
                break :blk hostedOf(app, owner) orelse return error.AgentGone;
            } else null;
            const sender = if (owner_child) |child| (if (child.name.len > 0) child.name else child.id) else post.agent;

            const started_by: ?subagent_reports.StartedBy = if (!message)
                null
            else if (owner_child) |child|
                if (hostOf(app, child)) |host| host.turnStartedBy(child.id) else null
            else
                post.host.turnStartedBy(post.child_id);
            const limit = target.worker.effectiveAgentTurnSettings().max_tool_result_bytes;
            const text = switch (post.kind) {
                .report => try subagent_reports.message(app.alloc, .{
                    .agent = sender,
                    .child_id = post.child_id,
                    .work_id = post.work_id,
                    .outcome = post.outcome,
                    .output = post.text,
                    .dropped = post.dropped,
                    .end = post.end,
                }, limit),
                .message => subagent_reports.messageText(app.alloc, sender, post.child_id, post.text, limit, started_by) catch |err| {
                    target.worker.releaseAgentMessage();
                    return err;
                },
            };
            defer app.alloc.free(text);
            try app.postAgentMessage(target, text, .child, if (message) .message else .report);
            debug_trace.eventf("host", "child_delivery_posted", .{}, "child={s} work_id={s} kind={s}", .{ post.child_id, post.work_id, @tagName(post.kind) });
        }

        fn deliverTaskNotices(app: *App) void {
            if (comptime !agents.hasAgentField(App, "managed_executions")) return;
            const notices = app.main_agent.managed_executions.takeUnclaimedNotices(app.alloc) catch return;
            defer managed_execution.freeNotices(app.alloc, notices);
            for (notices) |notice| {
                app.postAgentMessage(&app.main_agent, notice, .child, .report) catch |err| {
                    debug_trace.eventf("host", "task_notice_dropped", .{}, "err={s}", .{@errorName(err)});
                };
            }
        }

        pub fn takePosts(app: *App) void {
            deliverReports(app);
            deliverTaskNotices(app);
            var posts: std.ArrayList(*Post) = .empty;
            {
                app.child_handoffs.mutex.lockUncancelable(io_mod.getIo());
                defer app.child_handoffs.mutex.unlock(io_mod.getIo());
                if (app.child_handoffs.closed) return;
                std.mem.swap(std.ArrayList(*Post), &posts, &app.child_handoffs.posts);
            }
            defer posts.deinit(handoff_alloc);
            var held: std.ArrayList(*Post) = .empty;
            defer held.deinit(handoff_alloc);
            for (posts.items) |post| {
                if (post.run != null) if (findChild(app, post.turn.child_id orelse "")) |child| if (turnGoing(app, child)) {
                    held.append(handoff_alloc, post) catch {
                        debug_trace.eventf("host", "child_handoff_failed", .{}, "agent={s} kind=run reason=OutOfMemory", .{child.id});
                        post.settle(.failed);
                        continue;
                    };
                    if (!post.held) debug_trace.eventf("host", "child_run_held", .{}, "agent={s} reason=turn_going", .{child.id});
                    post.held = true;
                    continue;
                };
                const kind = if (post.run == null) "bind" else "run";
                const taken = if (post.run == null) bindPost(app, post) else startPost(app, post);
                if (taken) |_| {
                    post.settle(.taken);
                } else |err| {
                    debug_trace.eventf("host", "child_handoff_failed", .{}, "agent={s} kind={s} reason={s}", .{ post.turn.child_id orelse "", kind, @errorName(err) });
                    post.settle(.failed);
                }
            }
            if (held.items.len == 0) return;

            app.child_handoffs.mutex.lockUncancelable(io_mod.getIo());
            defer app.child_handoffs.mutex.unlock(io_mod.getIo());
            if (app.child_handoffs.closed) {
                for (held.items) |post| post.settle(.closed);
            } else app.child_handoffs.posts.insertSlice(handoff_alloc, 0, held.items) catch {
                for (held.items) |post| post.settle(.failed);
            };
        }

        fn setParentHost(app: *App, child: *ChildAgent, host: *subagent_tool_host.Runtime) void {
            app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
            defer app.permission_state.authority_mutex.unlock(io_mod.getIo());
            child.parent_host = host;
            if (child.agent.root_instance == null) child.agent.root_instance = rootInstance(app, child);
        }

        fn noteQuitting(app: *App) void {
            if (app_session_runtime.Runtime(App).subagentHost(app)) |host| host.noteQuitting();
            for (app.child_agents.items) |child| {
                const host = child.agent.session_persistence.subagent_host orelse continue;
                host.noteQuitting();
            }
        }

        fn hostWithResolver(app: *App, resolver: *subagent_authority.Resolver) ?*subagent_tool_host.Runtime {
            if (app_session_runtime.Runtime(App).subagentHost(app)) |host| if (host.authorityResolver() == resolver) return host;
            for (app.child_agents.items) |child| {
                const host = child.agent.session_persistence.subagent_host orelse continue;
                if (host.authorityResolver() == resolver) return host;
            }
            return null;
        }

        fn hostOf(app: *App, child: *const ChildAgent) ?*subagent_tool_host.Runtime {
            return child.parent_host orelse app_session_runtime.Runtime(App).subagentHost(app);
        }

        fn bindPost(app: *App, post: *Post) !void {
            const child = try ensureChild(app, post.turn.child_id orelse return error.ChildNotAttached);
            if (post.turn.live_authority) |resolver| if (hostWithResolver(app, resolver)) |host| setParentHost(app, child, host);
            child.bound.hold();
            post.turn.hosted_worker = &child.agent.worker;
            post.turn.hosted_release = &child.bound;
        }

        fn startPost(app: *App, post: *Post) !void {
            const child = findChild(app, post.turn.child_id orelse return error.ChildNotAttached) orelse
                return error.ChildNotAttached;
            if (child.agent.child_run) |*run| if (run.inFlight()) return error.ChildBusy;
            if (child.name.len == 0) if (post.turn.child_name) |name| {
                child.name = try app.alloc.dupe(u8, name);
            };
            installChildRun(app, child, post.run.?);
            post.run = null;
            const start: Start = .{ .post = post, .child = child };
            visit(app, child, start, startInContext) catch |err| {
                finishRun(&child.agent.child_run.?, .failed);
                return err;
            };
            debug_trace.eventf("host", "child_run_started", .{}, "agent={s} work_id={s}", .{ child.id, child.agent.child_run.?.work_id });
        }

        const Start = struct { post: *Post, child: *ChildAgent };

        fn attachSession(app: *App, agent: *AppAgent, child: *ChildAgent) !void {
            if (comptime app_process_runtime.cooperativeHost(App)) return error.SubagentHostUnavailable;
            const host = hostOf(app, child) orelse return error.SubagentHostUnavailable;
            const session = try host.openChildSession(child.id);
            try app_session_runtime.Runtime(App).attachChildV2Session(app, agent, session);
            child.session_attached = true;
            debug_trace.eventf("host", "child_session_opened", .{}, "agent={s} turns={d}", .{ child.id, agent.session.agent.history.items.len });
        }

        fn startInContext(start: Start, app: *App, agent: *agents.Agent) anyerror!void {
            const post = start.post;
            if (!start.child.session_attached) try attachSession(app, agent, start.child);

            if (!start.child.view_built) {
                const history = agent.session.agent.history.items;
                try buildView(app, agent, history);
                start.child.view_built = true;
                debug_trace.eventf("host", "agent_view_rebuilt", .{}, "agent={s} turns={d}", .{ start.child.id, history.len });
            }

            agent.prompt_work_id = start.child.agent.child_run.?.work_id;
            defer agent.prompt_work_id = null;
            if (!try app.enqueuePrompt(agent, post.message)) return error.PromptNotAdmitted;
        }

        fn ensureChild(app: *App, id: []const u8) !*ChildAgent {
            const child = findChild(app, id) orelse try addChild(app, id);
            if (child.agent.worker_thread == null) {
                try app_process_runtime.Runtime(App).startAgentWorkerThread(app, &child.agent);
                debug_trace.eventf("host", "agent_started", .{}, "agent={s}", .{id});
            }
            return child;
        }

        fn addChild(app: *App, id: []const u8) !*ChildAgent {
            const child = try app.alloc.create(ChildAgent);
            errdefer app.alloc.destroy(child);
            child.* = .{ .id = try app.alloc.dupe(u8, id), .agent = .{ .app = @ptrCast(app), .role = .subagent } };
            errdefer app.alloc.free(child.id);
            {
                app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
                defer app.permission_state.authority_mutex.unlock(io_mod.getIo());
                try app.child_agents.append(app.alloc, child);
            }

            debug_trace.eventf("host", "agent_registered", .{}, "agent={s} parent=main", .{child.id});
            child.agent.worker.trace_agent = child.id;
            child.agent.worker.trace_registered = true;
            child.agent.worker.hands_back_leftover_feedback = true;
            return child;
        }

        pub fn addInstance(app: *App) !*ChildAgent {
            const child = try app.alloc.create(ChildAgent);
            errdefer app.alloc.destroy(child);
            child.* = .{ .id = try app.alloc.dupe(u8, "instance"), .agent = .{ .app = @ptrCast(app), .role = .instance } };
            errdefer app.alloc.free(child.id);
            app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
            defer app.permission_state.authority_mutex.unlock(io_mod.getIo());
            try app.child_agents.append(app.alloc, child);
            return child;
        }

        pub fn nameInstance(app: *App, child: *ChildAgent, session_id: ?[]const u8) !void {
            const id = try app.alloc.dupe(u8, session_id orelse "instance");
            app.alloc.free(child.id);
            child.id = id;
            child.agent.worker.trace_agent = child.id;
            child.agent.worker.trace_registered = true;
            debug_trace.eventf("host", "agent_registered", .{}, "agent={s} parent=host", .{child.id});
        }

        pub fn closeInstance(app: *App, child: *ChildAgent) !void {
            try closeTree(app, &child.agent, child, nextInstanceAfter(app, child), child.id);
            dropHosted(app, child);
        }

        pub fn closeFirstInstance(app: *App) !void {
            const next = instanceAfterFirst(app) orelse return error.LastInstance;
            const first = &app.main_agent;
            try closeTree(app, first, null, next, "first");
            visitScreen(app, first, &app.main_screen, {}, shutdownInContext) catch |err| {
                app_session_runtime.Runtime(App).recordShutdownFailure(&next.agent, err);
            };
            app.main_screen.deinit(app.alloc);
            app.main_screen = .{};
            app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
            app.instances.first_open = false;
            app.permission_state.authority_mutex.unlock(io_mod.getIo());
        }

        pub fn liftResumeIntent(app: *App) void {
            for (app.child_agents.items) |child| {
                if (child.agent.role != .subagent) continue;
                const intent = child.agent.session_persistence.resume_handoff_intent;
                if (intent == .none) continue;
                child.agent.session_persistence.resume_handoff_intent = .none;
                rootInstance(app, child).session_persistence.resume_handoff_intent = intent;
            }
            var holder: ?*AppAgent = null;
            var saved: ?*AppAgent = null;
            if (firstOpen(app)) noteResumeCandidate(&app.main_agent, &holder, &saved);
            for (app.child_agents.items) |child| {
                if (child.agent.role == .instance) noteResumeCandidate(&child.agent, &holder, &saved);
            }
            const from = holder orelse return;
            const to = saved orelse return;
            if (from == to or app_session_runtime.Runtime(App).savedSessionId(from) != null) return;
            from.session_persistence.resume_handoff_intent = .none;
            to.session_persistence.resume_handoff_intent = .requested;
            debug_trace.logf("host", "resume_intent_moved reason=unsaved_instance", .{});
        }

        fn noteResumeCandidate(agent: *AppAgent, holder: *?*AppAgent, saved: *?*AppAgent) void {
            if (holder.* == null and agent.session_persistence.resume_handoff_intent == .requested) holder.* = agent;
            if (saved.* == null and app_session_runtime.Runtime(App).savedSessionId(agent) != null) saved.* = agent;
        }

        fn closeTree(app: *App, root: *AppAgent, hosted: ?*ChildAgent, next: ?*ChildAgent, label: []const u8) !void {
            var tree: std.ArrayList(*ChildAgent) = .empty;
            defer tree.deinit(app.alloc);
            for (app.child_agents.items) |entry| {
                if (entry.agent.role == .subagent and rootInstance(app, entry) == root) try tree.append(app.alloc, entry);
            }
            const on_screen = app.agent_on_screen;
            if (on_screen == hosted or inBranch(tree.items, on_screen)) try show(app, next);

            const root_host: ?*subagent_tool_host.Runtime = if (comptime agents.hasAgentField(App, "session_persistence")) root.session_persistence.subagent_host else null;
            stopSet(app, tree.items, root_host);
            root.worker.requestCancel();
            debug_trace.eventf("host", "instance_closed", .{}, "agent={s} subagents={d}", .{ label, tree.items.len });
            dropSet(app, tree.items);
        }

        fn nextInstanceAfter(app: *App, child: *const ChildAgent) ?*ChildAgent {
            var seen = false;
            for (app.child_agents.items) |entry| {
                if (entry.agent.role != .instance) continue;
                if (seen) return entry;
                if (entry == child) seen = true;
            }
            if (firstOpen(app)) return null;
            for (app.child_agents.items) |entry| {
                if (entry.agent.role == .instance and entry != child) return entry;
            }
            return null;
        }

        fn instanceAfterFirst(app: *App) ?*ChildAgent {
            for (app.child_agents.items) |entry| if (entry.agent.role == .instance) return entry;
            return null;
        }

        pub fn dropHosted(app: *App, child: *ChildAgent) void {
            visit(app, child, {}, shutdownInContext) catch |err| {
                app_session_runtime.Runtime(App).recordShutdownFailure(firstInstance(app) orelse &app.main_agent, err);
            };

            const released = child.bound.waitReleased(release_timeout_ms);
            if (!released) debug_trace.logf("host", "child_release_timeout child={s} at=drop kept_allocated=true", .{child.id});
            {
                app.permission_state.authority_mutex.lockUncancelable(io_mod.getIo());
                defer app.permission_state.authority_mutex.unlock(io_mod.getIo());
                for (app.child_agents.items, 0..) |entry, index| if (entry == child) {
                    _ = app.child_agents.orderedRemove(index);
                    break;
                };
            }
            if (!released) return;
            child.screen.deinit(app.alloc);
            if (child.name.len > 0) app.alloc.free(child.name);
            if (child.profile.len > 0) app.alloc.free(child.profile);
            app.alloc.free(child.id);
            app.alloc.destroy(child);
        }

        pub fn findChild(app: *App, id: []const u8) ?*ChildAgent {
            for (app.child_agents.items) |child| if (std.mem.eql(u8, child.id, id)) return child;
            return null;
        }

        fn runInFlight(app: *App, agent: *AppAgent) ?*agents.ChildRun {
            if (comptime !@hasField(App, "screen_owner")) return null;
            if (agent == &app.main_agent) return null;
            const run = if (agent.child_run) |*value| value else return null;
            return if (run.inFlight()) run else null;
        }

        pub fn commitChildTurn(app: *App, agent: *AppAgent, finished: types.FinishedPrompt) void {
            if (comptime !@hasField(App, "screen_owner")) return;
            if (agent.role != .subagent) return;

            const run = if (agent.child_run) |*value| value else return;
            const saved_work = session_mod.historyTurnWorkId(finished.turn);
            debug_trace.eventf("host", "child_turn_saved", .{}, "agent={s} work_id={s}", .{ run.child_id, saved_work orelse "none" });
            if (saved_work == null and run.turn_work_id.len > 0) {
                const host = hostOf(app, hostedOf(app, agent) orelse return) orelse return;
                const reply = switch (finished.turn) {
                    .assistant => |value| value.assistant,
                    .interrupted => |value| value.assistant orelse "",
                    .compacted_summary => "",
                };
                endAndFollowUserWork(app.alloc, host, run, &agent.worker, userWorkOutcome(run, finished.terminal_outcome orelse .completed), reply);
                return;
            }
            if (!run.inFlight()) return;
            if (!std.mem.eql(u8, saved_work orelse return, run.work_id)) return;
            const outcome = finished.terminal_outcome orelse .completed;
            debug_trace.eventf("host", "child_turn_committed", .{}, "agent={s} work_id={s} outcome={s}", .{ run.child_id, run.work_id, @tagName(outcome) });
            endRun(run, outcome);
        }

        pub fn noteUserStop(app: *App, agent: *AppAgent) void {
            const run = runInFlight(app, agent) orelse userWorkRun(app, agent) orelse return;
            const child = hostedOf(app, agent) orelse return;
            const host = hostOf(app, child) orelse return;
            const drop = agent.worker.dropAgentMessages(std.heap.c_allocator);
            host.userStopped(run.child_id, drop.from_parent);
        }

        pub fn noteChildTurnBegun(app: *App, agent: *AppAgent, author: types.MessageAuthor) void {
            if (runInFlight(app, agent) != null or userWorkRun(app, agent) != null) return;
            const child = hostedOf(app, agent) orelse return;
            if (child.agent.role != .subagent) return;
            const run = if (child.agent.child_run) |*value| value else return;
            const started_by: subagent_reports.StartedBy = switch (author) {
                .user => .user,
                .child => .child,
                else => return,
            };
            const host = hostOf(app, child) orelse return;
            if (host.beginTurnWork(app.alloc, child.id, started_by, &child.agent.worker)) |work_id| run.turn_work_id = work_id;
        }

        pub fn noteChildTurnFinished(app: *App, agent: *AppAgent, finished: types.TurnFinished) void {
            const run = runInFlight(app, agent) orelse userWorkRun(app, agent) orelse return;
            run.ended_as = finished.outcome;
            if (finished.outcome == .interrupted and agent.worker.handedOff(finished.turn_id)) {
                run.handed_off = true;
                debug_trace.eventf("host", "child_turn_handed_off", .{}, "agent={s} work_id={s} turn_id={d}", .{ run.child_id, run.work_id, finished.turn_id });
            }
        }

        pub fn settleChildRuns(app: *App) void {
            for (app.child_agents.items) |child| {
                const run = if (child.agent.child_run) |*value| value else continue;
                const outcome = run.ended_as orelse continue;
                if (hasPendingWork(child) or child.agent.worker.isProcessing()) continue;
                if (run.turn_work_id.len > 0) {
                    const host = hostOf(app, child) orelse continue;
                    endAndFollowUserWork(app.alloc, host, run, &child.agent.worker, userWorkOutcome(run, outcome), "");
                    continue;
                }
                if (!run.inFlight()) continue;
                endRun(run, outcome);
            }
        }

        fn userWorkRun(app: *App, agent: *AppAgent) ?*agents.ChildRun {
            if (agent == &app.main_agent) return null;
            const run = if (agent.child_run) |*value| value else return null;
            return if (run.turn_work_id.len > 0) run else null;
        }

        fn userWorkOutcome(run: *const agents.ChildRun, outcome: types.TurnPresentationOutcome) subagent_child_state.Outcome {
            return switch (outcome) {
                .completed => .completed,
                .failed => .failed,
                .interrupted => if (run.handed_off) .completed else .cancelled,
                .paused => .cancelled,
            };
        }

        fn endAndFollowUserWork(alloc: std.mem.Allocator, host: *subagent_tool_host.Runtime, run: *agents.ChildRun, worker: *worker_runtime.WorkerRuntime, outcome: subagent_child_state.Outcome, reply: []const u8) void {
            const handed_off = run.handed_off;
            endUserWork(alloc, host, run, outcome, reply);
            if (handed_off) if (host.beginUserWork(alloc, run.child_id, worker)) |work_id| {
                run.turn_work_id = work_id;
            };
        }

        fn endUserWork(alloc: std.mem.Allocator, host: *subagent_tool_host.Runtime, run: *agents.ChildRun, outcome: subagent_child_state.Outcome, reply: []const u8) void {
            if (run.turn_work_id.len == 0) return;
            const work_id = run.turn_work_id;
            run.turn_work_id = &.{};
            run.ended_as = null;
            run.handed_off = false;
            defer alloc.free(work_id);
            debug_trace.eventf("host", "user_work_ended", .{}, "agent={s} work_id={s} outcome={s}", .{ run.child_id, work_id, @tagName(outcome) });
            host.endUserWork(run.child_id, work_id, outcome, reply);
        }

        pub fn noteChildFailure(app: *App, agent: *AppAgent, status: types.RouteRecoveryStatus) void {
            if (status.kind != .terminal_provider_error) return;
            const run = runInFlight(app, agent) orelse return;
            run.failure = status.diagnostic orelse return;
        }

        fn finishRun(run: *agents.ChildRun, outcome: agents.ChildRunCompletion.Outcome) void {
            if (!run.inFlight()) return;
            debug_trace.eventf("host", "child_run_ended", .{}, "agent={s} work_id={s} outcome={s}", .{ run.child_id, run.work_id, @tagName(outcome) });
            run.finish(outcome);
        }

        fn endRun(run: *agents.ChildRun, outcome: types.TurnPresentationOutcome) void {
            switch (outcome) {
                .completed => finishRun(run, .completed),
                .failed => {
                    if (run.turn) |turn| if (turn.failureDiagnostic() == null) {
                        turn.failure_diagnostic = run.failure orelse
                            types.ModelFailureDiagnostic.init("agent_turn_failed");
                    };
                    finishRun(run, .failed);
                },

                .interrupted => finishRun(run, if (run.handed_off) .completed else .cancelled),
                .paused => finishRun(run, .cancelled),
            }
        }

        pub fn installChildRun(app: *App, child: *ChildAgent, run: agents.ChildRun) void {
            if (child.agent.child_run) |*previous| previous.deinit(app.alloc);
            var settings = (firstInstance(app) orelse &app.main_agent).worker.agent_turn_settings;
            settings.effort = run.admission.effort;

            settings.fast_mode = child.agent.worker.agent_turn_settings.fast_mode;
            settings.ultrafast_mode = settings.ultrafast_mode and run.admission.ultrafast_mode;
            child.agent.worker.agent_turn_settings = settings;
            var owned = run;

            if (owned.subagent_id == 0) owned.subagent_id = debug_trace.nextSubagentId();
            child.agent.child_run = owned;
        }

        fn finalizeInstancePersistence(app: *App, agent: *agents.Agent) void {
            const Session = app_session_runtime.Runtime(App);
            if (comptime @hasField(App, "instances")) {
                if (agent.role == .instance and agent.session_persistence.resume_handoff_intent != .none) {
                    const handoff = Session.finalizePersistenceWithResumeHandoff(app, agent);
                    if (app.instances.exit_handoff == null) {
                        app.instances.exit_handoff = handoff;
                    } else if (handoff) |value| {
                        var owned = value;
                        owned.deinit(app.alloc);
                    }
                    return;
                }
            }
            Session.finalizePersistence(app, agent);
        }

        fn shutdownInContext(_: void, app: *App, agent: *agents.Agent) anyerror!void {
            agent.worker.requestShutdown();
            agent.managed_executions.shutdown();
            if (agent.worker_thread) |thread| thread.join();
            agent.worker_thread = null;
            app_worker_runtime.Runtime(App).settleFinishedPromptsForShutdown(app, agent) catch |err| {
                app_session_runtime.Runtime(App).recordShutdownFailure(agent, err);
            };
            agent.managed_executions.deinit();
            finalizeInstancePersistence(app, agent);
            agent.worker.deinit(std.heap.c_allocator);
            app.clearPendingImages(agent);
            agent.pending_images.deinit(app.alloc);
            agent.session_title.deinit(app.alloc);
            app_session_runtime.Runtime(App).deinitPersistence(app, agent);
            agent.session.deinit(app.alloc);
            agent.approval_prompt.deinit(app.alloc);
            agent.question_prompt.deinit(app.alloc);
            app_permission_runtime.Runtime(App).deinitSessionGrants(app, agent);
            agent.change_tracker.deinit(std.heap.c_allocator);
            for (agent.diff_entries.items) |*entry| entry.deinit(std.heap.c_allocator);
            agent.diff_entries.deinit(std.heap.c_allocator);
            agent.context_snapshot.deinit(app.alloc);
            if (agent.child_run) |*run| run.deinit(app.alloc);
            agent.profile.deinit();
            agent.* = .{};
        }

        pub fn deinitChildren(app: *App) void {
            for (app.child_agents.items) |child| {
                child.screen.deinit(app.alloc);
                if (child.name.len > 0) app.alloc.free(child.name);
                if (child.profile.len > 0) app.alloc.free(child.profile);
                app.alloc.free(child.id);
                app.alloc.destroy(child);
            }
            app.child_agents.deinit(app.alloc);
            app.child_agents = .empty;
            app.main_screen.deinit(app.alloc);
            app.main_screen = .{};
            app.child_handoffs.deinit();
        }
    };
}

test "a slot thread's hand-off returns once the main loop takes it" {
    var handoffs: Handoffs = .{};
    defer handoffs.deinit();
    var cancel = std.atomic.Value(bool).init(false);

    var post = Post{ .turn = undefined };
    const Loop = struct {
        fn take(box: *Handoffs) void {
            while (true) {
                box.mutex.lockUncancelable(io_mod.getIo());
                if (box.posts.pop()) |taken| {
                    taken.settle(.taken);
                    box.mutex.unlock(io_mod.getIo());
                    return;
                }
                box.mutex.unlock(io_mod.getIo());
                io_mod.sleep(std.time.ns_per_ms);
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, Loop.take, .{&handoffs});
    try postAndWait(&handoffs, &post, &cancel);
    thread.join();
    try std.testing.expectEqual(Post.State.taken, post.state.load(.acquire));
}

test "a hand-off withdrawn on cancel, or posted after shutdown, never reaches the main loop" {
    var handoffs: Handoffs = .{};
    defer handoffs.deinit();
    var cancel = std.atomic.Value(bool).init(true);
    var post = Post{ .turn = undefined };
    try std.testing.expectError(error.Cancelled, postAndWait(&handoffs, &post, &cancel));
    try std.testing.expectEqual(@as(usize, 0), handoffs.posts.items.len);

    handoffs.closed = true;
    cancel.store(false, .seq_cst);
    try std.testing.expectError(error.Cancelled, postAndWait(&handoffs, &post, &cancel));
    try std.testing.expectEqual(@as(usize, 0), handoffs.posts.items.len);
}

test "the switch list follows the registry's start order, with an unlisted agent kept after it" {
    const ids = [_][]u8{ @constCast("new"), @constCast("second"), @constCast("first"), @constCast("stray") };
    var agents_storage: [4]ChildAgent = undefined;
    var children: [4]*ChildAgent = undefined;
    for (&agents_storage, &children, ids) |*agent, *slot, id| {
        agent.* = .{ .id = id };
        slot.* = agent;
    }

    const Entry = struct { id: []const u8 };
    const listing = [_]Entry{ .{ .id = "first" }, .{ .id = "second" }, .{ .id = "new" } };
    orderByListing(&children, &listing);
    var order: [4][]const u8 = undefined;
    for (children, &order) |child, *name| name.* = child.id;
    try std.testing.expectEqualDeep([4][]const u8{ "first", "second", "new", "stray" }, order);
}

fn expectSwitchOrder(entries: []const OrderEntry, order: []const usize) !void {
    try std.testing.expectEqual(entries.len + 1, order.len);
    var seen = try std.testing.allocator.alloc(bool, order.len);
    defer std.testing.allocator.free(seen);
    @memset(seen, false);
    for (order) |position| {
        try std.testing.expect(position < order.len);
        try std.testing.expect(!seen[position]);
        seen[position] = true;
    }
    try std.testing.expectEqual(@as(usize, 0), order[0]);
    var group: usize = 0;
    var last_instance: ?usize = null;
    var last_in_group: ?usize = null;
    for (order[1..]) |position| {
        const index = position - 1;
        switch (entries[index].role) {
            .instance => {
                if (last_instance) |previous| try std.testing.expect(previous < index);
                last_instance = index;
                group += 1;
                last_in_group = null;
            },
            .subagent => {
                try std.testing.expectEqual(group, entries[index].root);
                if (last_in_group) |previous| try std.testing.expect(previous < index);
                last_in_group = index;
            },
        }
    }
}

fn randomEntries(random: std.Random, buf: []OrderEntry) []OrderEntry {
    const len = random.uintAtMost(usize, buf.len);
    var instances: usize = 0;
    for (buf[0..len]) |*entry| {
        if (random.boolean()) {
            entry.* = .{ .role = .instance };
            instances += 1;
        } else entry.* = .{ .role = .subagent, .root = random.uintAtMost(usize, instances) };
    }
    return buf[0..len];
}

test "the switch order lists instances in launch order, each with its own subagents" {
    const entries = [_]OrderEntry{
        .{ .role = .subagent, .root = 0 },
        .{ .role = .instance },
        .{ .role = .subagent, .root = 1 },
        .{ .role = .subagent, .root = 0 },
        .{ .role = .instance },
        .{ .role = .subagent, .root = 2 },
    };
    var order: [entries.len + 1]usize = undefined;
    switchOrder(&entries, &order);

    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 4, 2, 3, 5, 6 }, &order);
    try expectSwitchOrder(&entries, &order);
}

test "the switch order holds for random hosts" {
    var prng = std.Random.DefaultPrng.init(0x5eed_4057);
    var buf: [24]OrderEntry = undefined;
    var order: [buf.len + 1]usize = undefined;
    for (0..10_000) |_| {
        const entries = randomEntries(prng.random(), &buf);
        switchOrder(entries, order[0 .. entries.len + 1]);
        try expectSwitchOrder(entries, order[0 .. entries.len + 1]);
    }
}

test "the switch order holds for fuzzed hosts" {
    try std.testing.fuzz({}, fuzzSwitchOrder, .{
        .corpus = &(.{""} ++ @import("fuzz_corpus").switch_order.*),
    });
}

fn fuzzSwitchOrder(_: void, smith: *std.testing.Smith) !void {
    var buf: [24]OrderEntry = undefined;
    var len: usize = 0;
    var instances: usize = 0;
    while (len < buf.len and !smith.eos()) : (len += 1) {
        if (smith.boolWeighted(1, 1)) {
            buf[len] = .{ .role = .instance };
            instances += 1;
        } else buf[len] = .{ .role = .subagent, .root = smith.valueRangeAtMost(u8, 0, @intCast(instances)) };
    }
    var order: [buf.len + 1]usize = undefined;
    switchOrder(buf[0..len], order[0 .. len + 1]);
    try expectSwitchOrder(buf[0..len], order[0 .. len + 1]);
}

test "working agents come first without changing the existing order within either group" {
    const entries = [_]OrderEntry{
        .{ .role = .subagent, .working = false },
        .{ .role = .instance, .working = true },
        .{ .role = .subagent, .root = 1, .working = true },
        .{ .role = .subagent, .working = true },
    };
    var order: [entries.len + 1]usize = undefined;
    switchOrder(&entries, &order);

    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 4, 2, 3 }, &order);
    sortMenuOrder(&entries, .{ .role = .instance }, &order);
    try std.testing.expectEqualSlices(usize, &.{ 4, 2, 3, 0, 1 }, &order);

    switchOrder(&entries, &order);
    sortMenuOrder(&entries, .{ .role = .instance, .working = true }, &order);
    try std.testing.expectEqualSlices(usize, &.{ 0, 4, 2, 3, 1 }, &order);
}

test "inactive agents sort by latest reply while working agents and ties keep their order" {
    const entries = [_]OrderEntry{
        .{ .role = .subagent, .reply_at_ms = 100 },
        .{ .role = .subagent, .working = true, .reply_at_ms = 1 },
        .{ .role = .subagent, .reply_at_ms = 300 },
        .{ .role = .subagent, .working = true, .reply_at_ms = 900 },
        .{ .role = .subagent, .reply_at_ms = 300 },
        .{ .role = .subagent },
    };
    var order: [entries.len + 1]usize = undefined;
    switchOrder(&entries, &order);
    sortMenuOrder(&entries, .{ .role = .instance, .reply_at_ms = 200 }, &order);
    try std.testing.expectEqualSlices(usize, &.{ 2, 4, 3, 5, 0, 1, 6 }, &order);
}

test "latest reply timestamp ignores interrupted turns and empty or untimed replies" {
    const user: types.UserTurn = .{ .text = @constCast("task") };
    const history = [_]types.HistoryTurn{
        .{ .assistant = .{ .user = user, .assistant = @constCast("older"), .execution = .{ .turn_summary = .{ .completed_at_ms = 100 } } } },
        .{ .assistant = .{ .user = user, .assistant = @constCast("newest reply"), .execution = .{ .turn_summary = .{ .completed_at_ms = 200 } } } },
        .{ .interrupted = .{ .user = user, .assistant = @constCast("stopped"), .execution = .{ .turn_summary = .{ .completed_at_ms = 900 } } } },
        .{ .assistant = .{ .user = user, .assistant = @constCast(""), .execution = .{ .turn_summary = .{ .completed_at_ms = 1000 } } } },
        .{ .assistant = .{ .user = user, .assistant = @constCast("no timestamp") } },
    };
    try std.testing.expectEqual(@as(i64, 200), latestReplyAt(&history));
    try std.testing.expectEqual(@as(i64, 0), latestReplyAt(&.{}));
    try std.testing.expectEqual(@as(i64, 0), latestReplyAt(history[2..]));
}
