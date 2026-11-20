const std = @import("std");
const execution_observation = @import("../agent/runtime/observation.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const approval_registry = @import("approval_registry.zig");
const reports = @import("reports.zig");
const agents = @import("../agents/agents.zig");
const authority = @import("authority.zig");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const execution = @import("execution.zig");
const foreground_text = @import("foreground_text.zig");
const hooks = @import("../hooks/hooks.zig");
const managed_owner = @import("managed_owner.zig");
const session_adapter = @import("../session/session_adapter.zig");
const live_metrics = @import("live_metrics.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const model_contract = @import("model_contract.zig");
const secondary_model = @import("secondary_model.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const git_context = @import("../github/git_context.zig");
const profiles = @import("../profiles/profiles.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const mode_registry = @import("../modes/mode_registry.zig");
const model_provider = @import("../config/model_provider.zig");
const permissions = @import("../permissions/permissions.zig");
const session = @import("../session/session.zig");
const session_codec = @import("../session/session_codec.zig");
const session_permission_state = @import("../permissions/session_permission_state.zig");
const session_store = @import("../session/session_store.zig");
const tool_set_contract = @import("../tooling/tool_set.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
pub const Defaults = struct {
    provider: model_provider.ProviderId,
    model: []const u8,
    effort: types.ReasoningEffort,
    fast_mode: bool = false,
    ultrafast_mode: bool = false,
    conversation_language: session.ConversationLanguage,
};

pub const ChildRunner = struct {
    context: ?*anyopaque = null,
    bind_fn: ?*const fn (
        ?*anyopaque,
        *execution.TurnContext,
        *std.atomic.Value(bool),
    ) execution.ServiceError!void = null,
    run_fn: *const fn (
        ?*anyopaque,
        *execution.TurnContext,
        domain.QueuedMessage,
        domain.AdmissionSnapshot,
        *std.atomic.Value(bool),
    ) execution.ServiceError!execution.RunOutcome = unavailableChildRun,
};

fn unavailableChildRun(
    _: ?*anyopaque,
    _: *execution.TurnContext,
    _: domain.QueuedMessage,
    _: domain.AdmissionSnapshot,
    _: *std.atomic.Value(bool),
) execution.ServiceError!execution.RunOutcome {
    return error.ProviderFailed;
}

test "managed execution receipts retain the pending contract" {
    var runtime: Runtime = undefined;
    for ([_]bool{ false, true }) |pending| {
        const result = try runtime.encodeManaged(std.testing.allocator, .{ .ok = true, .pending = pending });
        defer std.testing.allocator.free(result.body);
        try std.testing.expectEqual(pending, result.pending);
    }
}

pub const ReportSink = struct {
    context: ?*anyopaque = null,
    post_fn: *const fn (?*anyopaque, *Runtime, Delivery) PostReportError!void,

    pub fn post(self: ReportSink, host: *Runtime, delivery: Delivery) PostReportError!void {
        return self.post_fn(self.context, host, delivery);
    }
};

pub const Delivery = union(enum) {
    report: reports.Report,
    message: reports.Message,
};

pub const PostReportError = error{ OutOfMemory, AgentGone, QueueFull };

pub const ProgressSink = struct {
    context: *anyopaque,
    publish_fn: *const fn (*anyopaque, types.SubagentStatus) void,

    pub fn publish(self: ProgressSink, status: types.SubagentStatus) void {
        self.publish_fn(self.context, status);
    }
};

pub const ModelOverrideResolver = struct {
    context: ?*anyopaque = null,
    resolve_fn: *const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
    ) Allocator.Error!model_contract.ModelCatalogMatch,

    pub fn resolve(
        self: ModelOverrideResolver,
        alloc: Allocator,
        raw_model: []const u8,
    ) Allocator.Error!model_contract.ModelCatalogMatch {
        return self.resolve_fn(self.context, alloc, raw_model);
    }
};

pub const ExecuteOptions = struct {
    observer: ?*execution_observation.Observer = null,
    caller_id: []const u8,
    invocation_id: []const u8,
    parent_permission_mode: types.PermissionMode = .yolo,
    root_user_intent_context: []const u8 = "",
    root_user_messages: []const []const u8 = &.{},
    root_user_evidence_complete: bool = false,
    defaults: Defaults,
    max_result_bytes: usize,
    timestamp_ms: i64,
    identity_epoch: u64 = 0,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    caller_worker: ?*worker_runtime.WorkerRuntime = null,
    progress: ?ProgressSink = null,
    model_capability_resolver: ?model_capabilities.Resolver = null,
    model_override_resolver: ?ModelOverrideResolver = null,
    prompt_prefix: []const u8 = "",
    write_root: ?[]const u8 = null,
    tower_child: bool = false,
};

const AwaitedWork = struct {
    work_id: []u8,
    outcome: child_state.Outcome = .completed,
    output: ?[]u8 = null,
    report_owed: bool = false,
};

const ForegroundFinish = struct {
    outcome: child_state.Outcome,
    output: []u8,
    report_owed: bool,
};

pub const ManagedExecutionResult = struct {
    pending: bool = false,
    success: bool,
    body: []u8,
    final_status: ?types.SubagentStatus = null,
};

pub const BackgroundWork = struct {
    context: *anyopaque,
    live_fn: *const fn (context: *anyopaque) bool,

    fn live(self: BackgroundWork) bool {
        return self.live_fn(self.context);
    }
};

pub const Runtime = struct {
    alloc: Allocator,
    children: *child_state.V2Children,
    root_id: []u8,
    host_authority: authority.HostResolver,
    child_runner: ChildRunner,
    report_sink: ?ReportSink = null,
    background_work: ?BackgroundWork = null,
    approvals: approval_registry.Registry,
    authority_resolver: authority.Resolver,
    profile_cache: ?authority.ProfileCache = null,
    managed: managed_owner.Owner,
    admission_mutex: std.Io.Mutex = .init,
    pending: std.ArrayList(Pending) = .empty,
    busy: std.ArrayList([]u8) = .empty,
    work_calls: std.ArrayList(WorkCall) = .empty,
    user_dropped: std.ArrayList(UserDrop) = .empty,
    turn_works: std.ArrayList(TurnWork) = .empty,
    closing: std.ArrayList([]u8) = .empty,
    write_roots: std.ArrayList(WriteRoot) = .empty,
    closed_unseen: std.ArrayList([]u8) = .empty,
    closed_waiting: std.atomic.Value(bool) = .init(false),
    settling: usize = 0,
    waiter_mutex: std.Io.Mutex = .init,
    waiter: ?*worker_runtime.WorkerRuntime = null,
    owner_has_parent: bool = false,
    foreground_mutex: std.Io.Mutex = .init,
    foreground_changed: std.Io.Condition = .init,
    foreground: std.ArrayList(AwaitedWork) = .empty,

    pub fn create(
        alloc: Allocator,
        children: *child_state.V2Children,
        host_authority: authority.HostResolver,
        child_runner: ChildRunner,
    ) !*Runtime {
        const root_id = children.parent.id();
        try domain.validateId(root_id);
        const runtime = try alloc.create(Runtime);
        errdefer alloc.destroy(runtime);
        const owned_root = try alloc.dupe(u8, root_id);
        errdefer alloc.free(owned_root);
        runtime.* = .{
            .alloc = alloc,
            .children = children,
            .root_id = owned_root,
            .host_authority = host_authority,
            .child_runner = child_runner,
            .approvals = undefined,
            .authority_resolver = undefined,
            .managed = undefined,
        };
        runtime.approvals = .{
            .alloc = alloc,
        };
        runtime.profile_cache = .{ .alloc = alloc };
        runtime.authority_resolver = .{
            .children = children,
            .root_id = runtime.root_id,
            .host = host_authority,
            .profiles = &runtime.profile_cache.?,
        };
        runtime.managed = runtime.managedOwnerValue();
        runtime.managed.on_end = .{ .context = runtime, .end_fn = workEnded };
        errdefer runtime.approvals.deinit();
        errdefer runtime.managed.deinit();
        try runtime.managed.recoverInterrupted();
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        self.managed.deinit();
        for (self.pending.items) |*item| {
            debug_trace.eventf("mailbox", "dropped", .{}, "child={s} work_id={s} reason=host_closed", .{ item.child_id, item.work.id });
            item.deinit(self.alloc);
        }
        self.pending.deinit(self.alloc);
        for (self.busy.items) |id| self.alloc.free(id);
        self.busy.deinit(self.alloc);
        for (self.work_calls.items) |*call| call.deinit(self.alloc);
        self.work_calls.deinit(self.alloc);
        for (self.user_dropped.items) |drop| self.alloc.free(drop.child_id);
        self.user_dropped.deinit(self.alloc);
        for (self.turn_works.items) |*work| work.deinit(self.alloc);
        self.turn_works.deinit(self.alloc);
        for (self.closing.items) |id| {
            debug_trace.eventf("mailbox", "close_dropped", .{}, "child={s} reason=host_closed", .{id});
            self.alloc.free(id);
        }
        self.closing.deinit(self.alloc);
        for (self.write_roots.items) |entry| {
            self.alloc.free(entry.child_id);
            self.alloc.free(entry.root);
        }
        self.write_roots.deinit(self.alloc);
        for (self.closed_unseen.items) |id| self.alloc.free(id);
        self.closed_unseen.deinit(self.alloc);
        for (self.foreground.items) |item| {
            self.alloc.free(item.work_id);
            if (item.output) |output| self.alloc.free(output);
        }
        self.foreground.deinit(self.alloc);
        self.approvals.deinit();
        if (self.profile_cache) |*cache| cache.deinit();
        self.alloc.free(self.root_id);
        const alloc = self.alloc;
        self.* = undefined;
        alloc.destroy(self);
    }

    pub fn setLifecycle(self: *Runtime, lifecycle: execution.Lifecycle) void {
        self.managed.services.lifecycle = lifecycle;
    }

    pub fn closeTree(self: *Runtime) void {
        self.managed.closeTree();
        debug_trace.eventf("mailbox", "tree_closed", .{}, "owner={s}", .{self.ownerName()});
    }

    pub fn rebindHost(
        self: *Runtime,
        host_context: ?*anyopaque,
        host_authority: authority.HostResolver,
    ) void {
        self.host_authority = host_authority;
        self.child_runner.context = host_context;
        if (self.report_sink) |*sink| sink.context = host_context;
        self.authority_resolver.children = self.children;
        self.authority_resolver.root_id = self.root_id;
        self.authority_resolver.host = host_authority;
        self.managed.children = self.children;
        self.managed.state_store.children = self.children;
        self.managed.services.context = self;
        self.managed.on_end = .{ .context = self, .end_fn = workEnded };
        self.managed.authority_resolver = &self.authority_resolver;
        self.managed.approvals = &self.approvals;
    }

    pub fn openChildSession(self: *Runtime, child_id: []const u8) !*session_adapter.Session {
        return managed_owner.openChildForAgent(&self.managed, child_id);
    }

    pub const ChildListing = struct {
        id: []u8,
        name: []u8,
        profile: []u8,
    };

    pub fn listChildren(self: *Runtime, alloc: Allocator) ![]ChildListing {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try self.managed.state_store.load(alloc);
        defer registry.deinit(alloc);

        var count: usize = 0;
        for (registry.children) |child| {
            if (self.closingIndexLocked(child.id) == null) count += 1;
        }
        const listing = try alloc.alloc(ChildListing, count);
        var filled: usize = 0;
        errdefer {
            for (listing[0..filled]) |entry| freeListed(alloc, entry);
            alloc.free(listing);
        }
        for (registry.children) |child| {
            if (self.closingIndexLocked(child.id) != null) continue;
            const id = try alloc.dupe(u8, child.id);
            errdefer alloc.free(id);
            const name = try alloc.dupe(u8, child.agentName() orelse "");
            errdefer alloc.free(name);
            listing[filled] = .{ .id = id, .name = name, .profile = try alloc.dupe(u8, child.profile orelse profiles.main_name) };
            filled += 1;
        }
        return listing;
    }

    pub fn freeChildListing(alloc: Allocator, listing: []ChildListing) void {
        for (listing) |entry| freeListed(alloc, entry);
        alloc.free(listing);
    }

    fn freeListed(alloc: Allocator, entry: ChildListing) void {
        alloc.free(entry.id);
        alloc.free(entry.name);
        alloc.free(entry.profile);
    }

    pub fn childHistory(self: *Runtime, alloc: Allocator, child_id: []const u8) ![]types.HistoryTurn {
        return self.children.parent.store.childHistory(alloc, child_id);
    }

    pub const UserTurnAdmission = struct {
        admission: domain.AdmissionSnapshot,
        instructions: []u8,

        pub fn deinit(self: *UserTurnAdmission, alloc: Allocator) void {
            self.admission.deinit(alloc);
            alloc.free(self.instructions);
            self.* = undefined;
        }
    };

    pub fn admitUserTurn(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        permission_mode: types.PermissionMode,
    ) !UserTurnAdmission {
        const instructions = blk: {
            var lock = self.managed.state_store.acquireLock();
            defer lock.release();
            var registry = try self.managed.state_store.load(alloc);
            defer registry.deinit(alloc);
            const child = registry.findById(child_id) orelse return error.ChildUnavailable;
            if (child.agentName() == null) return error.OneOffChild;
            break :blk try alloc.dupe(u8, child.instructions());
        };
        errdefer alloc.free(instructions);
        var preferences = try managed_owner.readChildPreferences(&self.managed, child_id);
        defer preferences.deinit(self.managed.alloc);
        var snapshot = try self.authority_resolver.resolveForUser(alloc, child_id, permission_mode);
        defer snapshot.deinit(alloc);
        const admission = try admissionFrom(alloc, .{
            .child_id = child_id,
            .parent_id = self.managed.state_store.parent_id,
            .source_id = self.managed.state_store.parent_id,
            .preferences = managed_owner.turnPreferencesForDurable(preferences),
        }, &snapshot);
        return .{ .admission = admission, .instructions = instructions };
    }

    pub fn authorityResolver(self: *Runtime) *authority.Resolver {
        return &self.authority_resolver;
    }

    pub fn issueOperationIdentity(
        self: *Runtime,
        invocation_id: []const u8,
    ) u64 {
        _ = self;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("model");
        hash.update(&.{0});
        hash.update(invocation_id);
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        return std.mem.readInt(u64, digest[0..8], .little) | 1;
    }

    pub fn executeManaged(
        self: *Runtime,
        alloc: Allocator,
        request: *model_contract.Request,
        options: ExecuteOptions,
    ) !ManagedExecutionResult {
        const identity_epoch = if (options.identity_epoch != 0)
            options.identity_epoch
        else
            self.issueOperationIdentity(options.invocation_id);
        const operation_id = try operationIdAlloc(
            alloc,
            options.invocation_id,
            identity_epoch,
        );
        defer alloc.free(operation_id);
        const from_root = std.mem.eql(u8, options.caller_id, self.root_id);

        switch (request.*) {
            .wait => return self.waitForMail(alloc, options),
            .status => {
                if (!from_root) return self.encodeManaged(alloc, .{ .ok = false, .error_code = "caller_unavailable" });
                return self.statusOf(alloc, request.status.agent);
            },
            .stop => {
                if (!from_root) return self.encodeManaged(alloc, .{ .ok = false, .error_code = "caller_unavailable" });
                return self.stopChild(alloc, request.stop.agent);
            },
            .close => {
                if (!from_root) return self.encodeManaged(alloc, .{ .ok = false, .error_code = "caller_unavailable" });
                return self.closeNamed(alloc, request.close.agent);
            },
            .message => {},
        }
        if (request.toParent()) return self.messageParent(alloc, request.message.message, options, from_root);
        if (!from_root) return self.encodeManaged(alloc, .{ .ok = false, .error_code = "caller_unavailable" });

        var profile_arena = std.heap.ArenaAllocator.init(alloc);
        defer profile_arena.deinit();
        var explore_prefix: ?[]u8 = null;
        defer if (explore_prefix) |prefix| alloc.free(prefix);
        var profiled = options;
        var model_override = request.override();
        if (model_override.profile) |name| {
            const profile = switch (try loadChildProfile(profile_arena.allocator(), name)) {
                .rejected => |failure| return self.encodeManaged(alloc, failure),
                .loaded => |value| value,
            };
            if (model_override.model == null) model_override.model = profile.model;
            if (model_override.effort == null) {
                if (profile.effort) |effort| profiled.defaults.effort = effort;
            }
            const tower_worker_launch = options.tower_child and std.mem.eql(u8, profile.name, profiles.tower_worker_name);
            if (!tower_worker_launch and !profiles.allowedSubagentType(&profile)) return self.encodeManaged(alloc, try subagentTypeRejected(profile_arena.allocator(), name));
            if (profile.source == .builtin and std.mem.eql(u8, profile.name, profiles.explore_name)) {
                const prefix = try git_context.explorePrefix(alloc);
                explore_prefix = prefix;
                profiled.prompt_prefix = prefix;
            }
        }
        if (model_override.model == null) model_override.model = secondary_model.defaultModel();
        const resolved_model: ?[]const u8 = switch (try resolveOverrideModel(alloc, model_override, profiled)) {
            .rejected => |failure| return self.encodeManaged(alloc, failure),
            .accepted => |model| model,
        };
        if (request.override().model == null) {
            if (model_override.model) |raw| profiled.defaults.model = resolved_model orelse raw;
        }
        if (options.cancel_flag) |cancel| if (cancel.load(.seq_cst)) return error.Cancelled;
        const fingerprint = model_contract.requestFingerprint(request.*);
        if (self.managed.feedbackReplay(operation_id, fingerprint)) |replay| {
            return self.encodeManaged(alloc, switch (replay) {
                .receipt => |delivery| model_contract.feedbackResult(delivery),
                else => .{ .ok = false, .error_code = "operation_conflict" },
            });
        }

        try self.rememberCall(operation_id, options.invocation_id);
        var keep_call = false;
        defer if (!keep_call) self.forgetCall(operation_id);
        var admission_arena = std.heap.ArenaAllocator.init(self.alloc);
        defer admission_arena.deinit();
        const admission_alloc = admission_arena.allocator();
        var admitted = try self.admitAndStartManagedWork(admission_alloc, request.*, operation_id, profiled, resolved_model);
        defer admitted.deinit(admission_alloc);
        const agent = request.message.agent;
        switch (admitted) {
            .rejected => |failure| return self.encodeManaged(alloc, .{
                .ok = false,
                .error_code = failure.code,
            }),
            .ready => |ready| {
                keep_call = true;
                if (options.write_root) |root| try self.recordWriteRoot(ready.child_id, root);
                if (options.observer) |observer| observer.emit(.{ .delegation = .{ .call_id = options.invocation_id, .child_id = ready.child_id, .work_id = operation_id, .phase = .dispatched } });
                if (request.action() == .message and request.message.foreground) {
                    return self.foregroundResult(alloc, agent, ready.child_id, operation_id, options);
                }
                var buf: [sent_result_bytes]u8 = undefined;
                return self.encodeManaged(alloc, .{ .ok = true, .result = sentResult(&buf, agent) });
            },
            .completed => |completed| {
                if (options.observer) |observer| observer.emit(.{ .delegation = .{ .call_id = options.invocation_id, .child_id = completed.child_id, .work_id = operation_id, .phase = .replayed } });
                return self.encodeManaged(alloc, .{ .ok = true, .result = "This message was sent earlier, and the subagent's work on it has ended. Its report went to you then." });
            },
        }
    }

    const WorkCall = struct {
        work_id: []u8,
        call_id: []u8,

        fn deinit(self: *WorkCall, alloc: Allocator) void {
            alloc.free(self.work_id);
            alloc.free(self.call_id);
        }
    };

    fn rememberCall(self: *Runtime, work_id: []const u8, call_id: []const u8) !void {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        for (self.work_calls.items) |call| if (std.mem.eql(u8, call.work_id, work_id)) return;
        const owned_work = try self.alloc.dupe(u8, work_id);
        errdefer self.alloc.free(owned_work);
        const owned_call = try self.alloc.dupe(u8, call_id);
        errdefer self.alloc.free(owned_call);
        try self.work_calls.append(self.alloc, .{ .work_id = owned_work, .call_id = owned_call });
    }

    fn forgetCall(self: *Runtime, work_id: []const u8) void {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        self.forgetCallLocked(work_id);
    }

    fn forgetCallLocked(self: *Runtime, work_id: []const u8) void {
        for (self.work_calls.items, 0..) |*call, i| {
            if (!std.mem.eql(u8, call.work_id, work_id)) continue;
            call.deinit(self.alloc);
            _ = self.work_calls.swapRemove(i);
            return;
        }
    }

    fn callOf(self: *Runtime, a: Allocator, work_id: []const u8) []const u8 {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        for (self.work_calls.items) |call| {
            if (std.mem.eql(u8, call.work_id, work_id)) return a.dupe(u8, call.call_id) catch "";
        }
        return "";
    }

    const Pending = struct {
        child_id: []u8,
        agent: []u8,
        work: child_state.ActiveWork,

        fn deinit(self: *Pending, alloc: Allocator) void {
            alloc.free(self.child_id);
            alloc.free(self.agent);
            self.work.deinit(alloc);
        }
    };

    fn dropPendingLocked(self: *Runtime, child_id: []const u8, reason: []const u8) usize {
        var dropped: usize = 0;
        var index: usize = 0;
        while (index < self.pending.items.len) {
            if (!std.mem.eql(u8, self.pending.items[index].child_id, child_id)) {
                index += 1;
                continue;
            }
            var item = self.pending.orderedRemove(index);
            debug_trace.eventf("mailbox", "dropped", .{}, "child={s} work_id={s} reason={s}", .{ child_id, item.work.id, reason });
            self.forgetCallLocked(item.work.id);
            item.deinit(self.alloc);
            dropped += 1;
        }
        return dropped;
    }

    fn isBusyLocked(self: *const Runtime, child_id: []const u8) bool {
        for (self.busy.items) |id| if (std.mem.eql(u8, id, child_id)) return true;
        return false;
    }

    fn markBusyLocked(self: *Runtime, child_id: []const u8) !void {
        if (self.isBusyLocked(child_id)) return;
        try self.busy.append(self.alloc, try self.alloc.dupe(u8, child_id));
    }

    fn clearBusyLocked(self: *Runtime, child_id: []const u8) void {
        for (self.busy.items, 0..) |id, index| if (std.mem.eql(u8, id, child_id)) {
            self.alloc.free(self.busy.swapRemove(index));
            return;
        };
    }

    fn anyWorking(self: *Runtime) bool {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        return self.busy.items.len > 0 or self.pending.items.len > 0 or self.closing.items.len > 0 or self.settling > 0;
    }

    pub fn launchTowerChild(
        self: *Runtime,
        alloc: Allocator,
        name: []const u8,
        prompt: []const u8,
        model: ?[]const u8,
        options: ExecuteOptions,
    ) !ManagedExecutionResult {
        var request: model_contract.Request = .{ .message = .{
            .agent = try alloc.dupe(u8, name),
            .message = try alloc.dupe(u8, prompt),
            .model = if (model) |raw| try alloc.dupe(u8, raw) else null,
            .profile = try alloc.dupe(u8, profiles.tower_worker_name),
            .foreground = false,
        } };
        defer request.deinit(alloc);
        return self.executeManaged(alloc, &request, towerChildOptions(options, self.root_id));
    }

    const WriteRoot = struct { child_id: []u8, root: []u8 };

    pub fn towerChildOptions(options: ExecuteOptions, root_id: []const u8) ExecuteOptions {
        var launch = options;
        launch.caller_id = root_id;
        launch.parent_permission_mode = .auto;
        launch.tower_child = true;
        return launch;
    }

    fn recordWriteRoot(self: *Runtime, child_id: []const u8, root: []const u8) !void {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        const owned_id = try self.alloc.dupe(u8, child_id);
        errdefer self.alloc.free(owned_id);
        const owned_root = try self.alloc.dupe(u8, root);
        errdefer self.alloc.free(owned_root);
        try self.write_roots.append(self.alloc, .{ .child_id = owned_id, .root = owned_root });
    }

    pub fn writeRootFor(self: *Runtime, child_id: []const u8) ?[]const u8 {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        for (self.write_roots.items) |entry| {
            if (std.mem.eql(u8, entry.child_id, child_id)) return entry.root;
        }
        return null;
    }

    pub fn quiet(self: *Runtime) bool {
        return !self.anyWorking();
    }

    pub const TreeWake = enum { mail, quiet, stopped };
    const cancel_poll: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } };

    pub fn awaitMailOrQuiet(self: *Runtime, worker: *worker_runtime.WorkerRuntime, cancel: ?*const std.atomic.Value(bool)) TreeWake {
        return self.awaitMailOrQuietUntil(worker, cancel, null);
    }

    pub fn awaitMailOrQuietUntil(self: *Runtime, worker: *worker_runtime.WorkerRuntime, cancel: ?*const std.atomic.Value(bool), deadline_ms: ?i64) TreeWake {
        self.setWaiter(worker);
        defer self.setWaiter(null);
        while (true) {
            if (cancel) |flag| if (flag.load(.seq_cst)) return .stopped;
            if (worker.queuedPromptCount() > 0) return .mail;
            const background_live = if (self.background_work) |work| work.live() else false;
            if (!self.anyWorking() and !background_live) return .quiet;
            if (deadline_ms) |deadline| if (io_mod.milliTimestamp() >= deadline) return .stopped;
            const wake = if (cancel != null or background_live or deadline_ms != null)
                worker.waitForPostOrNudgeTimeout(cancel_poll) orelse continue
            else
                worker.waitForPostOrNudge();
            switch (wake) {
                .posted => return .mail,
                .nudged => continue,
                .stopped => return .stopped,
            }
        }
    }

    fn ownerName(self: *const Runtime) []const u8 {
        return if (self.owner_has_parent) self.root_id else "main";
    }

    fn setWaiter(self: *Runtime, worker: ?*worker_runtime.WorkerRuntime) void {
        self.waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.waiter_mutex.unlock(io_mod.getIo());
        self.waiter = worker;
    }

    fn nudgeWaiter(self: *Runtime) void {
        self.waiter_mutex.lockUncancelable(io_mod.getIo());
        defer self.waiter_mutex.unlock(io_mod.getIo());
        if (self.waiter) |worker| worker.nudgeWaiter();
    }

    fn workEnded(raw: *anyopaque, end: managed_owner.WorkEnd) bool {
        const self: *Runtime = @ptrCast(@alignCast(raw));
        self.deliverEnd(end);
        if (self.endClosingWork(end)) {
            _ = self.settleClose(end.child_id);
            return false;
        }
        var ended = blk: {
            self.admission_mutex.lockUncancelable(io_mod.getIo());
            defer self.admission_mutex.unlock(io_mod.getIo());
            self.forgetCallLocked(end.work_id);
            self.queueLeftoversLocked(end);
            switch (self.openWaitingTurnWorkLocked(end.child_id)) {
                .none => return self.nextOrIdleLocked(end.child_id),

                .opened => {
                    self.managed.markEnding(end.child_id);
                    return false;
                },
                .ended => |work| break :blk work,
            }
        };

        defer ended.deinit(self.alloc);
        const reply = ended.ended.?.reply;
        self.finishTurnWork(ended, ended.ended.?.outcome, reply);
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        return self.nextOrIdleLocked(end.child_id);
    }

    fn nextOrIdleLocked(self: *Runtime, child_id: []const u8) bool {
        if (self.startNextPendingLocked(child_id)) return true;
        self.clearBusyLocked(child_id);
        self.managed.markEnding(child_id);
        return false;
    }

    fn queueLeftoversLocked(self: *Runtime, end: managed_owner.WorkEnd) void {
        if (end.leftovers.len == 0) return;
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const name = self.childName(scratch.allocator(), end.child_id) catch end.child_id;
        var at: usize = self.pending.items.len;
        for (self.pending.items, 0..) |item, index| if (std.mem.eql(u8, item.child_id, end.child_id)) {
            at = index;
            break;
        };
        for (end.leftovers) |work| {
            const queued = for (self.pending.items) |item| {
                if (std.mem.eql(u8, item.work.id, work.id)) break true;
            } else false;
            if (queued) continue;
            self.insertPendingLocked(at, end.child_id, name, work) catch |err| {
                debug_trace.eventf("mailbox", "dropped", .{}, "child={s} work_id={s} reason={s}", .{ end.child_id, work.id, @errorName(err) });
                continue;
            };
            at += 1;
            debug_trace.eventf("mailbox", "handed_back", .{}, "child={s} work_id={s}", .{ end.child_id, work.id });
        }
    }

    fn insertPendingLocked(self: *Runtime, at: usize, child_id: []const u8, agent: []const u8, work: child_state.ActiveWork) !void {
        var copy = try work.clone(self.alloc);
        errdefer copy.deinit(self.alloc);
        const owned_child = try self.alloc.dupe(u8, child_id);
        errdefer self.alloc.free(owned_child);
        const owned_agent = try self.alloc.dupe(u8, agent);
        errdefer self.alloc.free(owned_agent);
        try self.pending.insert(self.alloc, at, .{ .child_id = owned_child, .agent = owned_agent, .work = copy });
    }

    const UserDrop = struct { child_id: []u8, count: usize, closed: bool = false };

    pub fn noteQuitting(self: *Runtime) void {
        self.managed.noteQuitting();
    }

    pub fn userStopped(self: *Runtime, child_id: []const u8, from_queue: usize) void {
        self.managed.noteUserStop(child_id);
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (self.findTurnWorkLocked(child_id)) |index| self.turn_works.items[index].stopped_by = .user;
        const dropped = self.dropPendingLocked(child_id, "stopped_by_user") + from_queue;
        debug_trace.eventf("mailbox", "stop", .{}, "target={s} by=user running={} dropped={d}", .{ child_id, self.isBusyLocked(child_id), dropped });
        self.noteUserDropLocked(child_id, dropped, false);
    }

    fn noteUserDropLocked(self: *Runtime, child_id: []const u8, dropped: usize, closed: bool) void {
        if (dropped == 0) return;
        for (self.user_dropped.items) |*drop| {
            if (!std.mem.eql(u8, drop.child_id, child_id)) continue;
            drop.count += dropped;
            drop.closed = drop.closed or closed;
            return;
        }
        const owned = self.alloc.dupe(u8, child_id) catch return self.logLostDrop(child_id, dropped);
        self.user_dropped.append(self.alloc, .{ .child_id = owned, .count = dropped, .closed = closed }) catch {
            self.alloc.free(owned);
            return self.logLostDrop(child_id, dropped);
        };
    }

    fn logLostDrop(_: *Runtime, child_id: []const u8, dropped: usize) void {
        debug_trace.logf("mailbox", "stop notice lost child={s} dropped={d} reason=out_of_memory", .{ child_id, dropped });
    }

    fn takeUserDropped(self: *Runtime, child_id: []const u8) Dropped {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        for (self.user_dropped.items, 0..) |drop, index| {
            if (!std.mem.eql(u8, drop.child_id, child_id)) continue;
            _ = self.user_dropped.swapRemove(index);
            self.alloc.free(drop.child_id);
            return .{ .count = drop.count, .closed = drop.closed };
        }
        return .{};
    }

    const Dropped = struct { count: usize = 0, closed: bool = false };

    fn deliverEnd(self: *Runtime, end: managed_owner.WorkEnd) void {
        debug_trace.eventf("mailbox", "child_end", .{}, "child={s} work_id={s} outcome={s} report={}", .{ end.child_id, end.work_id, @tagName(end.outcome), end.report_owed });
        const dropped = self.takeUserDropped(end.child_id);
        if (self.finishForeground(end)) {
            if (dropped.count > 0) self.postReportWith(.{ .child_id = end.child_id, .work_id = "", .outcome = .cancelled, .report_owed = false }, dropped);
            return;
        }
        if (end.report_owed) return self.postReportWith(end, dropped);

        if (dropped.count > 0) return self.postReportWith(.{ .child_id = end.child_id, .work_id = "", .outcome = .cancelled, .report_owed = false }, dropped);
        self.nudgeWaiter();
    }

    fn awaitedIndexLocked(self: *const Runtime, work_id: []const u8) ?usize {
        for (self.foreground.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.work_id, work_id)) return index;
        }
        return null;
    }

    fn expectForeground(self: *Runtime, work_id: []const u8) !void {
        self.foreground_mutex.lockUncancelable(io_mod.getIo());
        defer self.foreground_mutex.unlock(io_mod.getIo());
        const owned = try self.alloc.dupe(u8, work_id);
        errdefer self.alloc.free(owned);
        try self.foreground.append(self.alloc, .{ .work_id = owned });
    }

    fn finishForeground(self: *Runtime, end: managed_owner.WorkEnd) bool {
        if (end.work_id.len == 0) return false;
        {
            self.foreground_mutex.lockUncancelable(io_mod.getIo());
            defer self.foreground_mutex.unlock(io_mod.getIo());
            if (self.awaitedIndexLocked(end.work_id) == null) return false;
        }
        var arena_state = std.heap.ArenaAllocator.init(self.alloc);
        defer arena_state.deinit();
        const text = self.reportOutput(arena_state.allocator(), end) catch "";
        const owned = self.alloc.dupe(u8, text) catch (self.alloc.alloc(u8, 0) catch unreachable);

        self.foreground_mutex.lockUncancelable(io_mod.getIo());
        defer self.foreground_mutex.unlock(io_mod.getIo());
        const index = self.awaitedIndexLocked(end.work_id) orelse {
            self.alloc.free(owned);
            return false;
        };
        const item = &self.foreground.items[index];
        if (item.output != null) {
            self.alloc.free(owned);
            return true;
        }
        item.outcome = end.outcome;
        item.output = owned;
        item.report_owed = end.report_owed;
        self.foreground_changed.broadcast(io_mod.getIo());
        return true;
    }

    fn awaitForeground(self: *Runtime, work_id: []const u8, cancel: ?*const std.atomic.Value(bool)) !ForegroundFinish {
        self.foreground_mutex.lockUncancelable(io_mod.getIo());
        defer self.foreground_mutex.unlock(io_mod.getIo());
        while (true) {
            const index = self.awaitedIndexLocked(work_id) orelse return error.Cancelled;
            if (self.foreground.items[index].output) |output| {
                const removed = self.foreground.swapRemove(index);
                self.alloc.free(removed.work_id);
                return .{ .outcome = removed.outcome, .output = output, .report_owed = removed.report_owed };
            }
            if (cancel) |flag| {
                if (flag.load(.seq_cst)) {
                    const removed = self.foreground.swapRemove(index);
                    self.alloc.free(removed.work_id);
                    if (removed.output) |output| self.alloc.free(output);
                    return error.Cancelled;
                }
            }
            self.foreground_changed.waitTimeout(io_mod.getIo(), &self.foreground_mutex, cancel_poll) catch {};
        }
    }

    fn profileOfChild(self: *Runtime, alloc: Allocator, agent: []const u8) ![]const u8 {
        const listing = try self.listChildren(alloc);
        defer Runtime.freeChildListing(alloc, listing);
        for (listing) |child| {
            if (std.mem.eql(u8, child.name, agent)) return alloc.dupe(u8, child.profile);
        }
        return alloc.dupe(u8, profiles.main_name);
    }

    fn foregroundResult(self: *Runtime, alloc: Allocator, agent: []const u8, child_id: []const u8, work_id: []const u8, options: ExecuteOptions) !ManagedExecutionResult {
        const finished = try self.awaitForeground(work_id, options.cancel_flag);
        defer self.alloc.free(finished.output);
        const profile = try self.profileOfChild(alloc, agent);
        const text = try foregroundText(alloc, agent, profile, finished.outcome, finished.output);
        const result = try self.encodeManaged(alloc, .{ .ok = finished.outcome == .completed, .result = text });
        if (finished.report_owed) self.markReportTaken(child_id, work_id);
        return result;
    }

    fn markReportTaken(self: *Runtime, child_id: []const u8, work_id: []const u8) void {
        self.managed.state_store.reportTaken(child_id, work_id) catch |err| {
            debug_trace.eventf("mailbox", "report_taken_unmarked", .{}, "child={s} work_id={s} err={s}", .{ child_id, work_id, @errorName(err) });
            return;
        };
        debug_trace.eventf("mailbox", "report_taken", .{}, "child={s} work_id={s} by=foreground_result", .{ child_id, work_id });
    }

    pub fn resumeReports(self: *Runtime, parent: *session_adapter.Session) void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const lines = (parent.pendingReportLines(a) catch |err| {
            debug_trace.eventf("mailbox", "resume_reports_failed", .{}, "session={s} err={s}", .{ parent.id(), @errorName(err) });
            return;
        }) orelse return;
        const pending = reports.pendingReports(a, lines) catch |err| {
            debug_trace.eventf("mailbox", "resume_reports_failed", .{}, "session={s} err={s}", .{ parent.id(), @errorName(err) });
            return;
        };
        for (pending) |item| {
            debug_trace.eventf("mailbox", "report_resumed", .{}, "session={s} child={s} work_id={s} outcome={s}", .{ parent.id(), item.child_id, item.work_id, @tagName(item.outcome) });
            self.postReport(.{ .child_id = item.child_id, .work_id = item.work_id, .outcome = item.outcome, .report_owed = true, .end = item.end });
        }
    }

    fn postReport(self: *Runtime, end: managed_owner.WorkEnd) void {
        self.postReportWith(end, .{});
    }

    fn postReportWith(self: *Runtime, end: managed_owner.WorkEnd, dropped: Dropped) void {
        const sink = self.report_sink orelse {
            debug_trace.eventf("mailbox", "report_held", .{}, "child={s} work_id={s} reason=no_sink", .{ end.child_id, end.work_id });
            return self.nudgeWaiter();
        };
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const notice = end.work_id.len == 0;
        const output = if (notice)
            (a.print("The user {s} it, and {d} of your messages waiting for it were dropped.", .{
                if (dropped.closed) "closed" else "stopped",
                dropped.count,
            }) catch "")
        else
            self.reportOutput(a, end) catch "";
        const agent = self.childName(a, end.child_id) catch end.child_id;
        sink.post(self, .{ .report = .{
            .agent = agent,
            .child_id = end.child_id,
            .work_id = end.work_id,
            .call_id = if (notice) "" else self.callOf(a, end.work_id),
            .outcome = end.outcome,
            .output = output,
            .dropped = dropped.count,
            .end = end.end,
        } }) catch |err| {
            debug_trace.eventf("mailbox", "report_held", .{}, "child={s} work_id={s} reason={s} notice={}", .{ end.child_id, end.work_id, @errorName(err), notice });
            return self.nudgeWaiter();
        };
        if (notice) {
            debug_trace.eventf("mailbox", "notice_queued", .{}, "to={s} from={s} dropped={d}", .{ self.ownerName(), end.child_id, dropped.count });
        } else {
            self.managed.services.lifecycle.observeTaskNotification(.{
                .session_id = self.managed.state_store.parent_id,
                .agent_id = end.child_id,
                .task_id = end.work_id,
                .status = execution.TaskStatus.of(end.outcome),
                .body = output,
            });
            debug_trace.eventf("mailbox", "report_queued", .{}, "to={s} from={s} work={s} dropped={d} started_by={s} cause={s}", .{
                self.ownerName(),
                end.child_id,
                end.work_id,
                dropped.count,
                @tagName(end.end.started_by),
                if (end.end.cause) |cause| @tagName(cause) else "none",
            });
        }
    }

    fn reportOutput(self: *Runtime, a: Allocator, end: managed_owner.WorkEnd) ![]const u8 {
        const saved = if (end.reply) |reply|
            reply
        else
            self.managedResultText(a, end.child_id, end.work_id) catch null;

        const text = if (saved) |value| (if (value.len > 0) value else null) else null;
        return switch (end.outcome) {
            .completed => text orelse "The subagent ended its turn without a reply.",
            .failed => formatFailedResult(a, if (end.failure) |*failure| failure.view() else null, text),
            .cancelled => withPartial(a, cancelledSentence(end.end.cause), text),
            .interrupted => withPartial(a, "fx stopped before it finished.", text),
            .lost => lost_result,
        };
    }

    fn childName(self: *Runtime, a: Allocator, child_id: []const u8) ![]const u8 {
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try self.managed.state_store.load(a);
        if (registry.findById(child_id)) |child| return a.dupe(u8, child.agentName() orelse child_id);

        return (try self.managed.state_store.closedName(a, child_id)) orelse child_id;
    }

    fn startNextPendingLocked(self: *Runtime, child_id: []const u8) bool {
        const index = for (self.pending.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.child_id, child_id)) break i;
        } else return false;
        var item = self.pending.orderedRemove(index);
        defer item.deinit(self.alloc);
        self.absorbPendingLocked(&item, index);
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = self.managed.state_store.load(self.alloc) catch |err| return self.dropStart(item, err);
        defer registry.deinit(self.alloc);
        _ = registry.startPersistentWork(self.alloc, item.agent, null, item.work) catch |err| return self.dropStart(item, err);
        self.managed.state_store.save(self.alloc, registry) catch |err| return self.dropStart(item, err);
        debug_trace.eventf("mailbox", "next_turn", .{}, "child={s} work_id={s}", .{ child_id, item.work.id });
        return true;
    }

    fn absorbPendingLocked(self: *Runtime, head: *Pending, from: usize) void {
        var index = from;
        while (index < self.pending.items.len) {
            const next = &self.pending.items[index];
            if (!std.mem.eql(u8, next.child_id, head.child_id)) {
                index += 1;
                continue;
            }
            const joined = std.mem.concat(self.alloc, u8, &.{ head.work.message, "\n\n", next.work.message }) catch {
                debug_trace.logf("mailbox", "absorb skipped child={s} work_id={s} reason=out_of_memory", .{ head.child_id, next.work.id });
                return;
            };
            self.alloc.free(head.work.message);
            head.work.message = joined;
            std.mem.swap([]u8, &head.work.root_user_intent_context, &next.work.root_user_intent_context);
            std.mem.swap([][]u8, &head.work.root_user_messages, &next.work.root_user_messages);
            std.mem.swap(bool, &head.work.root_user_evidence_complete, &next.work.root_user_evidence_complete);
            debug_trace.eventf("mailbox", "absorbed", .{}, "child={s} work_id={s} into={s}", .{ head.child_id, next.work.id, head.work.id });
            var absorbed = self.pending.orderedRemove(index);
            self.forgetCallLocked(absorbed.work.id);
            absorbed.deinit(self.alloc);
        }
    }

    fn inTurnWorkLocked(self: *const Runtime, child_id: []const u8) bool {
        return self.findTurnWorkLocked(child_id) != null;
    }

    fn findTurnWorkLocked(self: *const Runtime, child_id: []const u8) ?usize {
        for (self.turn_works.items, 0..) |work, index| if (std.mem.eql(u8, work.child_id, child_id)) return index;
        return null;
    }

    const TurnWork = struct {
        child_id: []u8,
        work_id: []u8,
        started_by: reports.StartedBy,
        worker: ?*worker_runtime.WorkerRuntime,
        opened: bool,
        stopped_by: enum { none, parent, user } = .none,
        ended: ?struct { outcome: child_state.Outcome, reply: []u8 } = null,

        fn deinit(self: *TurnWork, alloc: Allocator) void {
            alloc.free(self.child_id);
            alloc.free(self.work_id);
            if (self.ended) |ended| alloc.free(ended.reply);
        }
    };

    pub fn beginUserWork(self: *Runtime, alloc: Allocator, child_id: []const u8, worker: ?*worker_runtime.WorkerRuntime) ?[]u8 {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (self.isBusyLocked(child_id) or self.closingIndexLocked(child_id) != null) return null;
        return self.openTurnWorkLocked(alloc, child_id, .user, worker, true) catch |err| {
            debug_trace.eventf("mailbox", "user_work_failed", .{}, "child={s} err={s}", .{ child_id, @errorName(err) });
            return null;
        };
    }

    pub fn beginTurnWork(self: *Runtime, alloc: Allocator, child_id: []const u8, started_by: reports.StartedBy, worker: ?*worker_runtime.WorkerRuntime) ?[]u8 {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (self.inTurnWorkLocked(child_id) or self.closingIndexLocked(child_id) != null) return null;
        return self.openTurnWorkLocked(alloc, child_id, started_by, worker, !self.isBusyLocked(child_id)) catch |err| {
            debug_trace.eventf("mailbox", "turn_work_failed", .{}, "child={s} err={s}", .{ child_id, @errorName(err) });
            return null;
        };
    }

    pub fn turnStartedBy(self: *Runtime, child_id: []const u8) ?reports.StartedBy {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        const index = self.findTurnWorkLocked(child_id) orelse return null;
        return self.turn_works.items[index].started_by;
    }

    fn openTurnWorkLocked(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        started_by: reports.StartedBy,
        worker: ?*worker_runtime.WorkerRuntime,
        open_now: bool,
    ) ![]u8 {
        const suffix = try session_store.generateSessionId(self.alloc);
        defer self.alloc.free(suffix);
        const work_id = try alloc.print("{s}:{s}", .{ if (started_by == .user) "fxuser" else "fxwake", suffix });
        errdefer alloc.free(work_id);
        if (open_now) try self.startTurnWorkInLog(child_id, work_id, started_by);
        var work: TurnWork = .{
            .child_id = try self.alloc.dupe(u8, child_id),
            .work_id = undefined,
            .started_by = started_by,
            .worker = worker,
            .opened = open_now,
        };
        errdefer self.alloc.free(work.child_id);
        work.work_id = try self.alloc.dupe(u8, work_id);
        errdefer self.alloc.free(work.work_id);
        try self.turn_works.append(self.alloc, work);
        errdefer _ = self.turn_works.pop();
        try self.markBusyLocked(child_id);
        debug_trace.eventf("mailbox", if (started_by == .user) "user_work" else "turn_work", .{}, "child={s} work_id={s} started_by={s} opened={}", .{ child_id, work_id, @tagName(started_by), open_now });
        return work_id;
    }

    fn startTurnWorkInLog(self: *Runtime, child_id: []const u8, work_id: []const u8, started_by: reports.StartedBy) !void {
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try self.managed.state_store.load(self.alloc);
        defer registry.deinit(self.alloc);
        const child = registry.findById(child_id) orelse return error.ChildUnavailable;
        const agent = child.agentName() orelse return error.OneOffChild;
        _ = try registry.startPersistentWork(self.alloc, agent, null, .{
            .id = @constCast(work_id),
            .message = @constCast(""),
            .created_at_ms = io_mod.milliTimestamp(),
            .started_by = started_by,
        });
        try self.managed.state_store.save(self.alloc, registry);
    }

    fn openWaitingTurnWorkLocked(self: *Runtime, child_id: []const u8) union(enum) { none, opened, ended: TurnWork } {
        const index = self.findTurnWorkLocked(child_id) orelse return .none;
        const work = &self.turn_works.items[index];
        if (work.opened) return .none;
        self.startTurnWorkInLog(child_id, work.work_id, work.started_by) catch |err| {
            debug_trace.eventf("mailbox", "turn_work_failed", .{}, "child={s} work_id={s} err={s}", .{ child_id, work.work_id, @errorName(err) });
            var dropped = self.turn_works.swapRemove(index);
            dropped.deinit(self.alloc);
            return .none;
        };
        work.opened = true;
        debug_trace.eventf("mailbox", "turn_work_opened", .{}, "child={s} work_id={s}", .{ child_id, work.work_id });
        if (work.ended == null) return .opened;
        return .{ .ended = self.turn_works.swapRemove(index) };
    }

    pub fn endUserWork(self: *Runtime, child_id: []const u8, work_id: []const u8, outcome: child_state.Outcome, reply: []const u8) void {
        var work = blk: {
            self.admission_mutex.lockUncancelable(io_mod.getIo());
            defer self.admission_mutex.unlock(io_mod.getIo());
            const index = self.findTurnWorkLocked(child_id) orelse return;
            const item = &self.turn_works.items[index];
            if (!std.mem.eql(u8, item.work_id, work_id)) return;
            if (!item.opened) {
                const owned = self.alloc.dupe(u8, reply) catch "";
                item.ended = .{ .outcome = outcome, .reply = @constCast(owned) };
                debug_trace.eventf("mailbox", "turn_work_ended_early", .{}, "child={s} work_id={s} outcome={s}", .{ child_id, work_id, @tagName(outcome) });
                return;
            }
            break :blk self.turn_works.swapRemove(index);
        };
        defer work.deinit(self.alloc);
        self.finishTurnWork(work, outcome, reply);
        defer _ = self.settleClose(child_id);
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (self.closingIndexLocked(child_id) != null) return;
        if (self.startNextPendingLocked(child_id)) {
            _ = self.managed.start(child_id) catch |err| {
                debug_trace.eventf("mailbox", "start_failed", .{}, "child={s} error={s}", .{ child_id, @errorName(err) });
                self.clearBusyLocked(child_id);
            };
            return;
        }
        self.clearBusyLocked(child_id);
    }

    fn finishTurnWork(self: *Runtime, work: TurnWork, outcome: child_state.Outcome, reply: []const u8) void {
        const finished = self.managed.finishTurnWork(work.child_id, work.work_id, outcome, work.started_by, switch (work.stopped_by) {
            .none => .none,
            .parent => .parent,
            .user => .user,
        });
        self.deliverEnd(.{
            .child_id = work.child_id,
            .work_id = work.work_id,
            .outcome = outcome,
            .report_owed = finished.report_owed,
            .reply = reply,
            .end = finished.end,
        });
    }

    fn dropStart(self: *Runtime, item: Pending, err: anyerror) bool {
        debug_trace.eventf("mailbox", "dropped", .{}, "child={s} work_id={s} reason={s}", .{ item.child_id, item.work.id, @errorName(err) });
        self.forgetCallLocked(item.work.id);
        return false;
    }

    fn waitForMail(self: *Runtime, alloc: Allocator, options: ExecuteOptions) !ManagedExecutionResult {
        const worker = options.caller_worker orelse return self.encodeManaged(alloc, .{ .ok = false, .error_code = "wait_unavailable" });

        self.setWaiter(worker);
        defer self.setWaiter(null);
        if (worker.queuedPromptCount() == 0 and !self.anyWorking()) {
            debug_trace.eventf("mailbox", "wait_skipped", .{}, "agent={s} reason=quiet", .{self.ownerName()});
            return self.encodeManaged(alloc, .{ .ok = true, .result = "No subagent is working and no message is waiting, so nothing more will arrive. Continue, or end your turn." });
        }
        debug_trace.eventf("mailbox", "wait_begin", .{}, "agent={s}", .{self.ownerName()});
        const wake = worker.waitForPostOrNudge();
        debug_trace.eventf("mailbox", "wait_end", .{}, "agent={s} reason={s}", .{ self.ownerName(), @tagName(wake) });
        return switch (wake) {
            .posted => self.encodeManaged(alloc, .{ .ok = true, .result = "A report or message arrived. It follows this result." }),
            .nudged => self.encodeManaged(alloc, .{ .ok = true, .result = "A subagent's turn ended without a report. Call status to see where things stand, or wait again." }),
            .stopped => error.Cancelled,
        };
    }

    fn statusOf(self: *Runtime, alloc: Allocator, agent: ?[]const u8) !ManagedExecutionResult {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var out: std.Io.Writer.Allocating = .init(a);
        var listed: usize = 0;
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        const registry = try self.managed.state_store.load(a);
        for (registry.children) |child| {
            const name = child.agentName() orelse continue;
            if (self.closingIndexLocked(child.id) != null) continue;
            if (agent) |wanted| if (!std.mem.eql(u8, wanted, name)) continue;
            var waiting: usize = 0;
            for (self.pending.items) |item| {
                if (std.mem.eql(u8, item.child_id, child.id)) waiting += 1;
            }
            const state = if (child.phase == .awaiting_approval) "waiting for an approval" else if (self.isBusyLocked(child.id)) "working" else switch (child.phase) {
                .interrupted => "interrupted",
                .finished => "finished",
                else => "idle",
            };
            if (listed > 0) try out.writer.writeByte('\n');
            try out.writer.print("{s}: {s}", .{ name, state });
            if (waiting > 0) try out.writer.print(", {d} waiting message{s}", .{ waiting, if (waiting == 1) "" else "s" });
            if (child.last_outcome) |outcome| try out.writer.print(", last work {s}", .{@tagName(outcome)});
            try out.writer.print(", reports {s}", .{@tagName(child.report_rule)});
            listed += 1;
        }
        if (agent != null and listed == 0) return self.encodeManaged(alloc, .{ .ok = false, .error_code = "child_unavailable" });
        if (listed == 0) try out.writer.writeAll("No subagents yet.");
        return self.encodeManaged(alloc, .{ .ok = true, .result = out.written() });
    }

    fn stopChild(self: *Runtime, alloc: Allocator, agent: []const u8) !ManagedExecutionResult {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const child_id = blk: {
            var lock = self.managed.state_store.acquireLock();
            defer lock.release();
            var registry = try self.managed.state_store.load(a);
            const child = registry.findPersistent(agent) orelse return self.encodeManaged(alloc, .{ .ok = false, .error_code = "child_unavailable" });
            break :blk try a.dupe(u8, child.id);
        };
        const dropped, const stopped = blk: {
            self.admission_mutex.lockUncancelable(io_mod.getIo());
            defer self.admission_mutex.unlock(io_mod.getIo());
            const dropped = self.dropPendingLocked(child_id, "stopped");
            break :blk .{ dropped, self.managed.stop(child_id) or self.stopTurnWorkLocked(child_id, .parent) };
        };
        debug_trace.eventf("mailbox", "stop", .{}, "target={s} by=parent running={} dropped={d}", .{ child_id, stopped, dropped });
        const dropped_text = switch (dropped) {
            0 => "",
            1 => "the message waiting for it was dropped",
            else => try a.print("the {d} messages waiting for it were dropped", .{dropped}),
        };
        const text = if (stopped)
            try a.print("Stopped {s}: its turn ended{s}{s}.", .{ agent, if (dropped > 0) ", and " else "", dropped_text })
        else
            try a.print("{s} was not working{s}{s}.", .{ agent, if (dropped > 0) "; " else "", dropped_text });
        return self.encodeManaged(alloc, .{ .ok = true, .result = text });
    }

    fn stopTurnWorkLocked(self: *Runtime, child_id: []const u8, by: CloseBy) bool {
        const index = self.findTurnWorkLocked(child_id) orelse return false;
        const work = &self.turn_works.items[index];
        work.stopped_by = if (by == .user) .user else .parent;
        if (work.worker) |worker| worker.requestTurnCancel();
        return true;
    }

    pub const CloseBy = enum { parent, user };

    pub const Closed = struct { stopped: bool, dropped: usize };

    pub fn closeChild(self: *Runtime, child_id: []const u8, by: CloseBy) !?Closed {
        {
            var lock = self.managed.state_store.acquireLock();
            defer lock.release();
            var registry = try self.managed.state_store.load(self.alloc);
            defer registry.deinit(self.alloc);
            if (registry.findById(child_id) == null) return null;
        }
        const result: Closed, const settle_now = blk: {
            self.admission_mutex.lockUncancelable(io_mod.getIo());
            defer self.admission_mutex.unlock(io_mod.getIo());
            if (self.closingIndexLocked(child_id) != null) break :blk .{ .{ .stopped = false, .dropped = 0 }, false };
            const owned = try self.alloc.dupe(u8, child_id);
            errdefer self.alloc.free(owned);
            const unseen = try self.alloc.dupe(u8, child_id);
            errdefer self.alloc.free(unseen);
            try self.closing.ensureUnusedCapacity(self.alloc, 1);
            try self.closed_unseen.ensureUnusedCapacity(self.alloc, 1);
            const dropped = self.dropPendingLocked(child_id, "closed");

            if (by == .user) self.noteUserDropLocked(child_id, dropped, true);
            const stopped = switch (by) {
                .parent => self.managed.stop(child_id) or self.stopTurnWorkLocked(child_id, .parent),
                .user => self.managed.closeByUser(child_id) or self.stopTurnWorkLocked(child_id, .user),
            };
            self.closing.appendAssumeCapacity(owned);
            self.closed_unseen.appendAssumeCapacity(unseen);
            self.closed_waiting.store(true, .release);
            debug_trace.eventf("mailbox", "close", .{}, "target={s} by={s} running={} dropped={d}", .{ child_id, @tagName(by), stopped, dropped });
            break :blk .{ .{ .stopped = stopped, .dropped = dropped }, !self.isBusyLocked(child_id) and !self.inTurnWorkLocked(child_id) };
        };
        if (settle_now and !self.settleClose(child_id)) return error.CloseNotSaved;
        return result;
    }

    fn closeNamed(self: *Runtime, alloc: Allocator, agent: []const u8) !ManagedExecutionResult {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const child_id = blk: {
            var lock = self.managed.state_store.acquireLock();
            defer lock.release();
            var registry = try self.managed.state_store.load(a);
            const child = registry.findPersistent(agent) orelse return self.encodeManaged(alloc, .{ .ok = false, .error_code = "child_unavailable" });
            break :blk try a.dupe(u8, child.id);
        };
        const closed = (self.closeChild(child_id, .parent) catch |err| switch (err) {
            error.CloseNotSaved => return self.encodeManaged(alloc, .{
                .ok = false,
                .error_code = "close_not_saved",
                .result = try a.print("The close of {s} couldn't be saved, so it is still open.", .{agent}),
            }),
            else => return err,
        }) orelse return self.encodeManaged(alloc, .{ .ok = false, .error_code = "child_unavailable" });
        const dropped_text = switch (closed.dropped) {
            0 => "",
            1 => " The message waiting for it was dropped.",
            else => try a.print(" The {d} messages waiting for it were dropped.", .{closed.dropped}),
        };
        const text = try a.print("Closed {s}{s}.{s} A later message to {s} starts a new one.", .{
            agent,
            if (closed.stopped) ", ending its turn" else "",
            dropped_text,
            agent,
        });
        return self.encodeManaged(alloc, .{ .ok = true, .result = text });
    }

    pub fn takeClosed(self: *Runtime, alloc: Allocator) ![][]u8 {
        if (!self.closed_waiting.load(.acquire)) return &.{};
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        const ids = try alloc.alloc([]u8, self.closed_unseen.items.len);
        var moved: usize = 0;
        errdefer {
            for (ids[0..moved]) |id| alloc.free(id);
            alloc.free(ids);
        }
        for (self.closed_unseen.items) |id| {
            ids[moved] = try alloc.dupe(u8, id);
            moved += 1;
        }
        for (self.closed_unseen.items) |id| self.alloc.free(id);
        self.closed_unseen.clearRetainingCapacity();
        self.closed_waiting.store(false, .release);
        return ids;
    }

    fn closingIndexLocked(self: *const Runtime, child_id: []const u8) ?usize {
        for (self.closing.items, 0..) |id, index| if (std.mem.eql(u8, id, child_id)) return index;
        return null;
    }

    fn endClosingWork(self: *Runtime, end: managed_owner.WorkEnd) bool {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (self.closingIndexLocked(end.child_id) == null) return false;
        self.forgetCallLocked(end.work_id);
        _ = self.dropPendingLocked(end.child_id, "closed");

        if (self.findTurnWorkLocked(end.child_id)) |index| if (!self.turn_works.items[index].opened) {
            var waiting = self.turn_works.swapRemove(index);
            debug_trace.eventf("mailbox", "turn_work_dropped", .{}, "child={s} work_id={s} reason=closed", .{ end.child_id, waiting.work_id });
            waiting.deinit(self.alloc);
        };
        self.clearBusyLocked(end.child_id);
        self.managed.markEnding(end.child_id);
        return true;
    }

    fn settleClose(self: *Runtime, child_id: []const u8) bool {
        const owned = blk: {
            self.admission_mutex.lockUncancelable(io_mod.getIo());
            defer self.admission_mutex.unlock(io_mod.getIo());
            const index = self.closingIndexLocked(child_id) orelse return true;
            if (self.isBusyLocked(child_id) or self.inTurnWorkLocked(child_id)) return true;
            self.settling += 1;
            break :blk self.closing.swapRemove(index);
        };
        defer self.alloc.free(owned);
        defer self.endSettling();
        const work_id = self.alloc.print("fxclose:{s}", .{owned}) catch |err| return self.closeNotWritten(owned, err);
        defer self.alloc.free(work_id);

        const failure: ?anyerror = blk: {
            var lock = self.managed.state_store.acquireLock();
            defer lock.release();
            self.managed.state_store.close(owned, work_id) catch |err| break :blk err;
            break :blk null;
        };
        if (failure) |err| return self.closeNotWritten(owned, err);
        debug_trace.eventf("mailbox", "closed", .{}, "child={s}", .{owned});
        return true;
    }

    fn endSettling(self: *Runtime) void {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        self.settling -= 1;
    }

    fn closeNotWritten(self: *Runtime, child_id: []const u8, err: anyerror) bool {
        debug_trace.logf("mailbox", "close not written child={s} err={s}", .{ child_id, @errorName(err) });
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        for (self.closed_unseen.items, 0..) |id, index| {
            if (!std.mem.eql(u8, id, child_id)) continue;
            self.alloc.free(self.closed_unseen.orderedRemove(index));
            break;
        }
        if (self.closed_unseen.items.len == 0) self.closed_waiting.store(false, .release);
        return false;
    }

    fn messageParent(self: *Runtime, alloc: Allocator, text: []const u8, options: ExecuteOptions, from_root: bool) !ManagedExecutionResult {
        const sink = self.report_sink orelse return self.encodeManaged(alloc, .{ .ok = false, .error_code = "no_parent" });
        if (from_root and !self.owner_has_parent) return self.encodeManaged(alloc, .{ .ok = false, .error_code = "no_parent" });
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const agent = if (from_root) "" else self.childName(arena.allocator(), options.caller_id) catch options.caller_id;
        sink.post(self, .{ .message = .{
            .to = if (from_root) .owners_parent else .owner,
            .agent = agent,
            .child_id = options.caller_id,
            .text = text,
        } }) catch |err| return self.encodeManaged(alloc, .{
            .ok = false,
            .error_code = if (err == error.QueueFull) "queue_full" else "no_parent",
        });
        debug_trace.eventf("mailbox", "post", .{}, "from={s} to={s}", .{ options.caller_id, if (from_root) "owners_parent" else self.ownerName() });
        return self.encodeManaged(alloc, .{ .ok = true, .result = "Sent to your parent. It arrives as your message, never as the user's." });
    }

    const ChildProfile = union(enum) {
        loaded: profiles.Profile,
        rejected: model_contract.Result,
    };

    fn profileRoots(arena: Allocator) !profiles.Roots {
        const workspace_root = io_mod.realpathAlloc(arena, ".") catch null;
        return profiles.Roots.init(arena, io_mod.homeDir(), workspace_root);
    }

    fn subagentTypeRejected(arena: Allocator, name: []const u8) !model_contract.Result {
        const entries = try profiles.list(arena, try profileRoots(arena));
        const allowed = try profiles.subagentTypeNames(arena, entries);
        return .{
            .ok = false,
            .error_code = "agent_type_not_allowed",
            .result = try arena.print("Subagent type \"{s}\" is not allowed for this agent. Allowed subagent types: {s}.", .{ name, allowed }),
        };
    }

    fn loadChildProfile(arena: Allocator, name: []const u8) !ChildProfile {
        const roots = try profileRoots(arena);
        var failure: ?[]const u8 = null;
        const profile = profiles.load(arena, roots, name, &failure) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .rejected = .{ .ok = false, .error_code = "profile_unavailable", .result = failure } },
        };
        debug_trace.eventf("profile", "profile_admitted", .{}, "name={s} source={s} mode={s}", .{
            profile.name,
            @tagName(profile.source),
            if (profile.permission_mode) |mode| @tagName(mode) else "inherit",
        });
        return .{ .loaded = profile };
    }

    const OverrideModelResolution = union(enum) {
        accepted: ?[]const u8,
        rejected: model_contract.Result,
    };

    fn resolveOverrideModel(
        alloc: Allocator,
        override: model_contract.Override,
        options: ExecuteOptions,
    ) !OverrideModelResolution {
        const raw_model = override.model orelse return .{ .accepted = null };

        if (options.defaults.provider != .gateway) {
            debug_trace.logf("subagent", "model override resolution skipped raw={s} reason=non_gateway_provider", .{raw_model});
            return .{ .accepted = null };
        }
        const resolver = options.model_override_resolver orelse {
            debug_trace.logf("subagent", "model override resolution skipped raw={s} reason=no_resolver", .{raw_model});
            return .{ .accepted = null };
        };
        switch (try resolver.resolve(alloc, raw_model)) {
            .no_catalog => {
                debug_trace.logf("subagent", "model override resolution skipped raw={s} reason=no_catalog", .{raw_model});
                return .{ .accepted = null };
            },
            .matched => |id| {
                if (!std.mem.eql(u8, id, raw_model)) {
                    debug_trace.logf(
                        "subagent",
                        "model override resolved raw={s} resolved={s}",
                        .{ raw_model, id },
                    );
                }
                return .{ .accepted = id };
            },
            .ambiguous => |candidates| {
                debug_trace.logf(
                    "subagent",
                    "model override rejected raw={s} code=ambiguous_model candidates={d}",
                    .{ raw_model, candidates.len },
                );
                return .{ .rejected = .{
                    .ok = false,
                    .error_code = "ambiguous_model",
                    .result = try modelOverrideFailureMessage(alloc, .ambiguous, raw_model, candidates),
                } };
            },
            .unknown => |candidates| {
                debug_trace.logf(
                    "subagent",
                    "model override rejected raw={s} code=unknown_model candidates={d}",
                    .{ raw_model, candidates.len },
                );
                return .{ .rejected = .{
                    .ok = false,
                    .error_code = "unknown_model",
                    .result = try modelOverrideFailureMessage(alloc, .unknown, raw_model, candidates),
                } };
            },
        }
    }

    fn managedOwnerValue(self: *Runtime) managed_owner.Owner {
        return .{
            .alloc = self.alloc,
            .children = self.children,
            .state_store = self.childStateStore(),
            .services = .{
                .context = self,
                .bind_fn = if (self.child_runner.bind_fn != null) bindChild else null,
                .capture_fn = captureAdmission,
                .run_fn = runChild,
            },
            .authority_resolver = &self.authority_resolver,
            .approvals = &self.approvals,
        };
    }

    fn childStateStore(self: *Runtime) child_state.Store {
        return .{ .children = self.children, .parent_id = self.root_id };
    }

    const ManagedAdmission = union(enum) {
        ready: struct { child_id: []u8, created: bool = false },
        completed: struct {
            child_id: []u8,
            observation: managed_owner.Observation,
        },
        rejected: struct {
            child_id: ?[]u8 = null,
            code: []const u8,
        },

        fn deinit(self: *ManagedAdmission, alloc: Allocator) void {
            switch (self.*) {
                .ready => |ready| alloc.free(ready.child_id),
                .completed => |completed| alloc.free(completed.child_id),
                .rejected => |failure| if (failure.child_id) |child_id| {
                    alloc.free(child_id);
                },
            }
            self.* = undefined;
        }
    };

    fn admitAndStartManagedWork(
        self: *Runtime,
        alloc: Allocator,
        request: model_contract.Request,
        operation_id: []const u8,
        options: ExecuteOptions,
        resolved_model: ?[]const u8,
    ) !ManagedAdmission {
        self.admission_mutex.lockUncancelable(io_mod.getIo());
        defer self.admission_mutex.unlock(io_mod.getIo());
        if (options.cancel_flag) |cancel| if (cancel.load(.seq_cst)) return error.Cancelled;
        if (atConcurrentSubagentLimit(self.busy.items.len, concurrentSubagentLimit(io_mod.getenv(concurrent_subagents_env)))) {
            debug_trace.logf("subagent", "admission rejected operation={s} code={s} running={d}", .{ operation_id, concurrent_subagent_limit_code, self.busy.items.len });
            return managedAdmissionRejected(alloc, null, concurrent_subagent_limit_code);
        }
        var admitted = try self.admitManagedWork(alloc, request, operation_id, options, resolved_model);
        errdefer admitted.deinit(alloc);
        if (admitted == .ready) {
            const child_id = admitted.ready.child_id;
            if (request.action() == .message and request.message.foreground) try self.expectForeground(operation_id);
            try self.markBusyLocked(child_id);
            _ = self.managed.start(child_id) catch |err| {
                debug_trace.eventf("mailbox", "start_failed", .{}, "child={s} work_id={s} error={s}", .{ child_id, operation_id, @errorName(err) });
                self.clearBusyLocked(child_id);
                return err;
            };
            if (admitted.ready.created)
                debug_trace.eventf("mailbox", "launch", .{}, "child={s} work_id={s}", .{ child_id, operation_id })
            else
                debug_trace.eventf("mailbox", "message", .{}, "child={s} work_id={s} delivery=next_turn", .{ child_id, operation_id });
        }
        return admitted;
    }

    fn admitManagedWork(
        self: *Runtime,
        alloc: Allocator,
        request: model_contract.Request,
        operation_id: []const u8,
        options: ExecuteOptions,
        resolved_model: ?[]const u8,
    ) !ManagedAdmission {
        const fingerprint = model_contract.requestFingerprint(request);
        const defaults = effectiveDefaults(options.defaults, request.override(), resolved_model);
        debug_trace.logf(
            "subagent",
            "admission requested operation={s} action={s} agent={s} override={s}",
            .{
                operation_id,
                @tagName(request.action()),
                request.agentName() orelse "none",
                if (request.override().present()) "yes" else "no",
            },
        );
        var lock = self.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try self.managed.state_store.load(alloc);
        defer registry.deinit(alloc);
        if (registry.findByOperation(operation_id)) |existing| {
            const observed = child_state.Registry.operationFingerprint(
                existing.*,
                operation_id,
            ) orelse return managedAdmissionRejected(
                alloc,
                existing.id,
                "operation_conflict",
            );
            if (!std.mem.eql(u8, &observed, &fingerprint)) {
                debug_trace.logf(
                    "subagent",
                    "admission rejected operation={s} child_id={s} code=operation_conflict",
                    .{ operation_id, existing.id },
                );
                return managedAdmissionRejected(
                    alloc,
                    existing.id,
                    "operation_conflict",
                );
            }
            try self.ensureManagedChildSession(
                existing.id,
                operation_id,
                defaults,
            );
            if (existing.last_work_id) |work_id| {
                if (std.mem.eql(u8, work_id, operation_id)) return .{ .completed = .{
                    .child_id = try alloc.dupe(u8, existing.id),
                    .observation = .{
                        .phase = existing.phase,
                        .outcome = existing.last_outcome,
                        .failure = existing.last_failure,
                    },
                } };
            }
            return managedAdmissionReady(alloc, existing.id, false);
        }

        var active = try makeManagedWork(
            alloc,
            operation_id,
            fingerprint,
            request,
            options,
        );
        defer active.deinit(alloc);
        switch (request) {
            .wait, .status, .stop, .close => unreachable,
            .message => |message| {
                if (registry.findPersistent(message.agent)) |child| {
                    if (self.closingIndexLocked(child.id) != null) return managedAdmissionRejected(alloc, child.id, "child_closing");
                    if (request.override().present()) {
                        debug_trace.logf(
                            "subagent",
                            "admission rejected operation={s} child_id={s} agent={s} code=override_after_create",
                            .{ operation_id, child.id, message.agent },
                        );
                        return managedAdmissionRejected(
                            alloc,
                            child.id,
                            "override_after_create",
                        );
                    }

                    const phase: child_state.Phase = if (self.isBusyLocked(child.id)) .running else child.phase;
                    const plan = model_contract.plan(request, .{ .kind = .persistent, .phase = phase });
                    if (plan != .reject) if (message.report) |rule| {
                        try registry.setReportRule(child.id, rule);
                        try self.managed.state_store.save(alloc, registry);
                    };
                    switch (plan) {
                        .reject => |code| return managedAdmissionRejected(alloc, child.id, @tagName(code)),
                        .continue_persistent => {},
                        .create_persistent => unreachable,
                    }
                    const started = try registry.startPersistentWork(
                        alloc,
                        message.agent,
                        message.instructions,
                        active,
                    );
                    try self.managed.state_store.save(alloc, registry);

                    try self.ensureManagedChildSession(started.id, active.id, defaults);
                    return managedAdmissionReady(alloc, started.id, false);
                }
                const child_id = try session_store.generateSessionId(alloc);
                defer alloc.free(child_id);
                try registry.appendPersistent(
                    alloc,
                    child_id,
                    message.agent,
                    message.instructions orelse "",
                    active,
                );

                try registry.setProfile(alloc, child_id, request.override().profile orelse profiles.main_name);
                if (message.report) |rule| try registry.setReportRule(child_id, rule);
                try self.managed.state_store.save(alloc, registry);
                try self.ensureManagedChildSession(child_id, active.id, defaults);
                return managedAdmissionReady(
                    alloc,
                    registry.children[registry.children.len - 1].id,
                    true,
                );
            },
        }
    }

    fn ensureManagedChildSession(
        self: *Runtime,
        child_id: []const u8,
        work_id: []const u8,
        defaults: Defaults,
    ) !void {
        try self.children.rememberSeed(child_id, .{
            .preferences = .{
                .provider = defaults.provider,
                .model = @constCast(defaults.model),
                .effort = defaults.effort,
                .fast_mode = defaults.fast_mode,
                .ultrafast_mode = defaults.ultrafast_mode,
            },
            .language = defaults.conversation_language,
        });
        debug_trace.logf(
            "subagent",
            "child session reserved child_id={s} work_id={s} provider={s} model={s} effort={s} fast_mode={} ultrafast_mode={}",
            .{ child_id, work_id, @tagName(defaults.provider), defaults.model, defaults.effort.label(), defaults.fast_mode, defaults.ultrafast_mode },
        );
    }

    fn managedResultText(
        self: *Runtime,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
    ) !?[]u8 {
        const history = self.children.parent.store.childHistory(alloc, child_id) catch return null;
        defer types.freeHistoryTurnSlice(alloc, history);
        const text = assistantTextForWork(history, work_id) orelse return null;
        return @as(?[]u8, try alloc.dupe(u8, text));
    }

    fn childPreferences(self: *Runtime, alloc: Allocator, child_id: []const u8) !session_codec.DurableSessionPreferences {
        return self.children.parent.store.childPreferences(alloc, child_id);
    }

    fn encodeManaged(
        self: *Runtime,
        alloc: Allocator,
        result: model_contract.Result,
    ) !ManagedExecutionResult {
        _ = self;
        return .{
            .success = result.ok,
            .pending = result.pending,
            .body = try model_contract.encodeResultAlloc(alloc, result),
        };
    }
};

fn operationIdAlloc(
    alloc: Allocator,
    invocation_id: []const u8,
    epoch: u64,
) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(invocation_id, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.print("fxop:2:m:{d}:{s}", .{ epoch, &hex });
}

test "internal operation identity is deterministic and invocation-bound" {
    const alloc = std.testing.allocator;
    const first = try operationIdAlloc(alloc, "call-1", 41);
    defer alloc.free(first);
    const replay = try operationIdAlloc(alloc, "call-1", 41);
    defer alloc.free(replay);
    const changed = try operationIdAlloc(alloc, "call-2", 41);
    defer alloc.free(changed);
    try std.testing.expectEqualStrings(first, replay);
    try std.testing.expect(!std.mem.eql(u8, first, changed));
    try std.testing.expect(std.mem.startsWith(u8, first, "fxop:2:m:41:"));
}

test "creation defaults keep parent values unless the request overrides them" {
    const parent = Defaults{
        .provider = .gateway,
        .model = "parent-model",
        .effort = .auto,
        .conversation_language = session.ConversationLanguage.default(),
    };
    const inherited = effectiveDefaults(parent, .{}, null);
    try std.testing.expectEqualStrings("parent-model", inherited.model);
    try std.testing.expect(inherited.effort.isDefault());
    const overridden = effectiveDefaults(parent, .{
        .model = "gpt-5.6-sol-fast",
        .effort = types.ReasoningEffort.parse("medium"),
    }, null);
    try std.testing.expectEqualStrings("gpt-5.6-sol-fast", overridden.model);
    try std.testing.expectEqualStrings("medium", overridden.effort.label());
    try std.testing.expectEqual(parent.provider, overridden.provider);

    const model_only = effectiveDefaults(parent, .{ .model = "other-model" }, null);
    try std.testing.expectEqualStrings("other-model", model_only.model);
    try std.testing.expect(model_only.effort.isDefault());

    const resolved = effectiveDefaults(parent, .{ .model = "terra-fast" }, "openai/gpt-5.6-terra-fast");
    try std.testing.expectEqualStrings("openai/gpt-5.6-terra-fast", resolved.model);

    const no_override = effectiveDefaults(parent, .{}, "openai/gpt-5.6-terra-fast");
    try std.testing.expectEqualStrings("parent-model", no_override.model);
}

const MailboxFixture = struct {
    hold: bool = false,
    fail_first: bool = false,
    empty_reply: bool = false,
    release: std.Io.Event = .unset,
    runs: std.atomic.Value(usize) = .init(0),
    mutex: std.Io.Mutex = .init,
    reports: std.ArrayList([]u8) = .empty,
    ends: std.ArrayList(child_state.EndFacts) = .empty,
    worker: ?*worker_runtime.WorkerRuntime = null,

    fn deinit(self: *MailboxFixture) void {
        for (self.reports.items) |line| std.testing.allocator.free(line);
        self.reports.deinit(std.testing.allocator);
        self.ends.deinit(std.testing.allocator);
    }

    fn resolve(_: ?*anyopaque, alloc: Allocator, _: []const u8) authority.HostResolveError!authority.HostAuthority {
        return authority.HostAuthority.capture(alloc, &.{}, &.{}, .{}, &.{});
    }

    fn run(raw: ?*anyopaque, turn: *execution.TurnContext, message: domain.QueuedMessage, _: domain.AdmissionSnapshot, cancel: *std.atomic.Value(bool)) execution.ServiceError!execution.RunOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        const run_number = self.runs.fetchAdd(1, .seq_cst) + 1;
        while (self.hold and !self.release.isSet() and !cancel.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
        if (cancel.load(.seq_cst)) return error.Cancelled;
        if (self.fail_first and run_number == 1) return error.ProviderFailed;
        const reply = if (self.empty_reply)
            std.testing.allocator.dupe(u8, "") catch return error.ProviderFailed
        else
            std.testing.allocator.print("DONE {s}", .{message.content}) catch return error.ProviderFailed;
        defer std.testing.allocator.free(reply);
        turn.commit(turn.active_work_id.?, .{ .assistant = .{
            .user = .{ .text = message.content },
            .assistant = reply,
        } }) catch return error.ProviderFailed;
        return .completed;
    }

    fn post(raw: ?*anyopaque, _: *Runtime, delivery: Delivery) PostReportError!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        const report = delivery.report;
        const line = if (report.dropped > 0)
            try std.testing.allocator.print("{s} {s} {s} {s} {s} dropped={d}", .{ report.agent, report.call_id, report.work_id, @tagName(report.outcome), report.output, report.dropped })
        else
            try std.testing.allocator.print("{s} {s} {s} {s} {s}", .{ report.agent, report.call_id, report.work_id, @tagName(report.outcome), report.output });
        errdefer std.testing.allocator.free(line);
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        try self.ends.ensureUnusedCapacity(std.testing.allocator, 1);
        try self.reports.append(std.testing.allocator, line);
        self.ends.appendAssumeCapacity(report.end);
        if (self.worker) |worker| {
            worker.postMail(std.testing.allocator, .{
                .prompt = try std.testing.allocator.dupe(u8, line),
                .images = &.{},
                .model = &.{},
                .api_key = &.{},
                .permission_mode = .ask,
                .history = &.{},
                .grants = &.{},
                .author = .child,
            }) catch return error.AgentGone;
        }
    }

    fn reportCount(self: *MailboxFixture) usize {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.reports.items.len;
    }
};

fn mailboxRuntime(alloc: Allocator, fixture: *MailboxFixture, parent: *child_state.TestParent) !*Runtime {
    const runtime = try Runtime.create(alloc, &parent.children, .{ .resolve_fn = MailboxFixture.resolve }, .{ .context = fixture, .run_fn = MailboxFixture.run });
    runtime.report_sink = .{ .context = fixture, .post_fn = MailboxFixture.post };
    return runtime;
}

fn callTool(runtime: *Runtime, arena: Allocator, input: model_contract.RequestInput, invocation_id: []const u8, worker: ?*worker_runtime.WorkerRuntime) ![]const u8 {
    var request = try model_contract.validateRequest(std.testing.allocator, input);
    defer request.deinit(std.testing.allocator);
    const result = try runtime.executeManaged(arena, &request, .{
        .caller_id = runtime.root_id,
        .invocation_id = invocation_id,
        .defaults = .{ .provider = .gateway, .model = "test", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .caller_worker = worker,
    });
    return result.body;
}

fn waitForRuns(fixture: *MailboxFixture, count: usize) !void {
    for (0..5000) |_| {
        if (fixture.runs.load(.seq_cst) >= count) return;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.Timeout;
}

const SubagentObservationRecorder = struct {
    starts: usize = 0,
    stops: usize = 0,
    agent_tasks_started: std.atomic.Value(usize) = .init(0),
    completed_task_notifications: std.atomic.Value(usize) = .init(0),

    fn run(raw: *anyopaque, input: hooks.ObservationInput) hooks.HandlerError!void {
        const self: *SubagentObservationRecorder = @ptrCast(@alignCast(raw));
        switch (input.event) {
            .SubagentStart => self.starts += 1,
            .SubagentStop => self.stops += 1,
            .TaskStarted => {
                if (std.mem.eql(u8, input.matcher_value, "agent")) _ = self.agent_tasks_started.fetchAdd(1, .seq_cst);
            },
            .Notification => {
                if (std.mem.eql(u8, input.matcher_value, "task.completed")) _ = self.completed_task_notifications.fetchAdd(1, .seq_cst);
            },
            else => {},
        }
    }

    fn waitForCompletedTaskNotification(self: *SubagentObservationRecorder) !void {
        for (0..5000) |_| {
            if (self.completed_task_notifications.load(.seq_cst) > 0) return;
            io_mod.sleep(std.time.ns_per_ms);
        }
        return error.Timeout;
    }
};

test "a host child run fires an agent TaskStarted and a task.completed Notification when its report is posted" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    var recorder = SubagentObservationRecorder{};
    var hook_runtime = hooks.Runtime.init(alloc);
    defer hook_runtime.deinit();
    try hook_runtime.registerObservation(.{ .name = "subagent_task_recorder", .ctx = &recorder, .run = SubagentObservationRecorder.run });
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();
    runtime.setLifecycle(.{ .view = hook_runtime.freeze(), .workspace_root = "/work" });

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "check" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    try recorder.waitForCompletedTaskNotification();

    try std.testing.expectEqual(@as(usize, 1), recorder.agent_tasks_started.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), recorder.completed_task_notifications.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
}

test "a host child run fires SubagentStart and SubagentStop through the lifecycle view it is given" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    var recorder = SubagentObservationRecorder{};
    var hook_runtime = hooks.Runtime.init(alloc);
    defer hook_runtime.deinit();
    try hook_runtime.registerObservation(.{ .name = "subagent_observation_recorder", .ctx = &recorder, .run = SubagentObservationRecorder.run });
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();
    runtime.setLifecycle(.{ .view = hook_runtime.freeze(), .workspace_root = "/work" });

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "check" } }, "call-1", null);
    try waitUntilQuiet(runtime);

    try std.testing.expectEqual(@as(usize, 1), recorder.starts);
    try std.testing.expectEqual(@as(usize, 1), recorder.stops);
}

test "a message returns at once, and the subagent's report reaches its parent on its own" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    const body = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "check" } }, "call-1", null);
    try std.testing.expect(std.mem.find(u8, body, "Sent to reviewer") != null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    const line = fixture.reports.items[0];

    try std.testing.expect(std.mem.startsWith(u8, line, "reviewer call-1 "));
    try std.testing.expect(std.mem.find(u8, line, " completed DONE check") != null);

    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expect(registry.findPersistent("reviewer").?.last_report_owed);

    const status = try callTool(runtime, arena, .{ .status = .{} }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, status, "reviewer: idle, last work completed, reports final") != null);
}

test "a work that saves an empty reply reports that it ended without one" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .empty_reply = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "check" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[0], " completed The subagent ended its turn without a reply."));
}

fn reviewerId(runtime: *Runtime, arena: Allocator) ![]const u8 {
    var lock = runtime.managed.state_store.acquireLock();
    defer lock.release();
    var registry = try runtime.managed.state_store.load(arena);
    return try arena.dupe(u8, registry.findPersistent("reviewer").?.id);
}

test "a work fx's quit cancels says so in its report" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const child_id = try reviewerId(runtime, arena);
    runtime.noteQuitting();
    try runtime.managed.cancel(child_id);
    try waitUntilQuiet(runtime);

    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    try std.testing.expectEqual(child_state.EndFacts{ .cause = .fx_quit }, fixture.ends.items[0]);
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[0], " cancelled fx quit before it finished.") != null);

    var lock = runtime.managed.state_store.acquireLock();
    defer lock.release();
    var registry = try runtime.managed.state_store.load(arena);
    try std.testing.expectEqual(child_state.EndFacts{ .cause = .fx_quit }, registry.findPersistent("reviewer").?.last_end);
}

test "a user's stop of a work that owes no report posts no report, and a message sent while it ran is refused" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working", .report = "never" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const refused = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "next" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, refused, "child_already_running") != null);
    const child_id = try reviewerId(runtime, arena);
    runtime.userStopped(child_id, 0);
    try runtime.managed.cancel(child_id);
    try waitUntilQuiet(runtime);

    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), fixture.reportCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.user_dropped.items.len);
}

test "a turn the user starts on an idle subagent is a work, and reports its reply under every_turn" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working", .report = "every_turn" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    const child_id = try reviewerId(runtime, arena);

    try std.testing.expectEqual(@as(?reports.StartedBy, null), runtime.turnStartedBy(child_id));
    const work_id = runtime.beginUserWork(alloc, child_id, null).?;
    defer alloc.free(work_id);

    try std.testing.expectEqual(@as(?reports.StartedBy, .user), runtime.turnStartedBy(child_id));
    {
        var lock = runtime.managed.state_store.acquireLock();
        defer lock.release();
        var registry = try runtime.managed.state_store.load(arena);
        const child = registry.findPersistent("reviewer").?;
        try std.testing.expectEqual(child_state.Phase.running, child.phase);
        try std.testing.expectEqualStrings(work_id, child.active.?.id);
    }

    try std.testing.expect(runtime.beginUserWork(alloc, child_id, null) == null);
    runtime.endUserWork(child_id, work_id, .completed, "USER_TURN_REPLY");
    try std.testing.expectEqual(@as(?reports.StartedBy, null), runtime.turnStartedBy(child_id));
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    const line = fixture.reports.items[1];
    try std.testing.expect(std.mem.find(u8, line, work_id) != null);
    try std.testing.expect(std.mem.endsWith(u8, line, " completed USER_TURN_REPLY"));
    try std.testing.expect(!runtime.anyWorking());

    try std.testing.expectEqual(reports.StartedBy.parent, fixture.ends.items[0].started_by);
    try std.testing.expectEqual(child_state.EndFacts{ .started_by = .user }, fixture.ends.items[1]);
}

test "a parent's message to a running subagent is refused, and a failed turn does not carry it forward" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true, .fail_first = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const refused = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "also this" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, refused, "child_already_running") != null);
    fixture.release.set(io_mod.getIo());
    try waitUntilQuiet(runtime);

    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[0], " failed ") != null);

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "again" } }, "call-3", null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 2), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[1], " completed DONE again"));
}

test "a parent's message to a running subagent is refused, and the parent's stop ends the turn without a report" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const refused = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "also this" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, refused, "child_already_running") != null);
    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, stopped, "Stopped reviewer: its turn ended.") != null);
    try std.testing.expect(std.mem.find(u8, stopped, "dropped") == null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), fixture.reportCount());
}

test "the parent's stop ends a turn the user started on the child's screen, which owes no report" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working", .report = "every_turn" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    const child_id = try reviewerId(runtime, arena);

    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    try std.testing.expect(worker.beginDirectProcessing(5));
    const work_id = runtime.beginUserWork(alloc, child_id, &worker).?;
    defer alloc.free(work_id);

    const refused = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "during the user's turn" } }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, refused, "child_already_running") != null);
    try std.testing.expectEqual(@as(usize, 0), worker.queuedPromptCount());

    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-4", null);
    try std.testing.expect(std.mem.find(u8, stopped, "Stopped reviewer: its turn ended") != null);
    try std.testing.expect(worker.isCancelRequested());
    runtime.endUserWork(child_id, work_id, .cancelled, "");

    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    try std.testing.expect(!runtime.anyWorking());
}

test "a turn the child's own child woke while the parent's work ended opens as that work ends, and reports" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const child_id = try reviewerId(runtime, arena);

    const work_id = runtime.beginTurnWork(alloc, child_id, .child, null).?;
    defer alloc.free(work_id);
    try std.testing.expect(runtime.beginTurnWork(alloc, child_id, .child, null) == null);
    const refused = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "after" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, refused, "child_already_running") != null);
    fixture.release.set(io_mod.getIo());
    try waitForActiveWork(runtime, arena, child_id, work_id);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));

    runtime.endUserWork(child_id, work_id, .completed, "WOKEN_REPLY");
    try waitUntilQuiet(runtime);

    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.endsWith(u8, fixture.reports.items[1], " completed WOKEN_REPLY"));
    try std.testing.expectEqual(child_state.EndFacts{ .started_by = .child }, fixture.ends.items[1]);
}

test "a woken turn that ends before its work could open still finishes and reports" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const child_id = try reviewerId(runtime, arena);
    const work_id = runtime.beginTurnWork(alloc, child_id, .user, null).?;
    defer alloc.free(work_id);

    runtime.endUserWork(child_id, work_id, .failed, "");
    fixture.release.set(io_mod.getIo());
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[1], work_id) != null);
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[1], " failed ") != null);
}

test "a user's turn under the final rule reports only when it fails" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    const child_id = try reviewerId(runtime, arena);
    const done = runtime.beginUserWork(alloc, child_id, null).?;
    defer alloc.free(done);
    runtime.endUserWork(child_id, done, .completed, "fine");
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    const failed = runtime.beginUserWork(alloc, child_id, null).?;
    defer alloc.free(failed);
    runtime.endUserWork(child_id, failed, .failed, "");
    try std.testing.expectEqual(@as(usize, 2), fixture.reportCount());
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[1], " failed ") != null);
}

test "a parent's message while the user's turn runs is refused, and nothing waits to start when the turn ends" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    const child_id = try reviewerId(runtime, arena);
    const work_id = runtime.beginUserWork(alloc, child_id, null).?;
    defer alloc.free(work_id);
    const refused = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "after the user" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, refused, "child_already_running") != null);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));

    runtime.endUserWork(child_id, work_id, .completed, "");
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "after the user" } }, "call-3", null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 2), fixture.runs.load(.seq_cst));
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[1], "DONE after the user") != null);
}

test "a work that ends after its tree closed owes no report and posts none" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    runtime.closeTree();
    fixture.release.set(io_mod.getIo());
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 0), fixture.reportCount());
    var lock = runtime.managed.state_store.acquireLock();
    defer lock.release();
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), registry.children.len);
    try std.testing.expect(!registry.children[0].last_report_owed);
}

test "stop ends a subagent's turn without a report, and a message sent while it ran is refused" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const refused = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "second" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, refused, "child_already_running") != null);
    const stopped = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, stopped, "Stopped reviewer: its turn ended.") != null);
    try std.testing.expect(std.mem.find(u8, stopped, "dropped") == null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), fixture.reportCount());
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    const child = registry.findPersistent("reviewer").?;
    try std.testing.expectEqual(child_state.Outcome.cancelled, child.last_outcome.?);
    try std.testing.expect(!child.last_report_owed);
    const again = try callTool(runtime, arena, .{ .stop = .{ .agent = "reviewer" } }, "call-4", null);
    try std.testing.expect(std.mem.find(u8, again, "reviewer was not working.") != null);
    const missing = try callTool(runtime, arena, .{ .stop = .{ .agent = "nobody" } }, "call-5", null);
    try std.testing.expect(std.mem.find(u8, missing, "child_unavailable") != null);
}

test "the parent's close ends a working subagent's turn without a report and removes it for good" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const refused = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "second" } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, refused, "child_already_running") != null);
    const child_id = try reviewerId(runtime, arena);
    const closed = try callTool(runtime, arena, .{ .close = .{ .agent = "reviewer" } }, "call-3", null);
    try std.testing.expect(std.mem.find(u8, closed, "Closed reviewer, ending its turn. A later message to reviewer starts a new one.") != null);

    const listing = try runtime.listChildren(alloc);
    defer Runtime.freeChildListing(alloc, listing);
    try std.testing.expectEqual(@as(usize, 0), listing.len);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), fixture.reportCount());
    {
        var registry = try runtime.managed.state_store.load(alloc);
        defer registry.deinit(alloc);
        try std.testing.expect(registry.findById(child_id) == null);
    }
    const status = try callTool(runtime, arena, .{ .status = .{} }, "call-4", null);
    try std.testing.expect(std.mem.find(u8, status, "No subagents yet.") != null);

    const taken = try runtime.takeClosed(alloc);
    defer {
        for (taken) |id| alloc.free(id);
        alloc.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 1), taken.len);
    try std.testing.expectEqualStrings(child_id, taken[0]);
    try std.testing.expectEqual(@as(usize, 0), (try runtime.takeClosed(alloc)).len);
    const missing = try callTool(runtime, arena, .{ .close = .{ .agent = "reviewer" } }, "call-5", null);
    try std.testing.expect(std.mem.find(u8, missing, "child_unavailable") != null);
}

test "a closing subagent is not quiet until its registry entry is settled" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "done" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    const child_id = try reviewerId(runtime, arena);
    {
        runtime.admission_mutex.lockUncancelable(io_mod.getIo());
        defer runtime.admission_mutex.unlock(io_mod.getIo());
        try runtime.closing.ensureUnusedCapacity(alloc, 1);
        try runtime.busy.ensureUnusedCapacity(alloc, 1);
        runtime.closing.appendAssumeCapacity(try alloc.dupe(u8, child_id));
        runtime.busy.appendAssumeCapacity(try alloc.dupe(u8, child_id));
    }

    try std.testing.expect(runtime.endClosingWork(.{ .child_id = child_id, .work_id = "fxwork:closing", .outcome = .cancelled, .report_owed = false }));
    try std.testing.expect(!runtime.quiet());
    try std.testing.expect(runtime.settleClose(child_id));
    try std.testing.expect(runtime.quiet());
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expect(registry.findById(child_id) == null);
}

test "a user close that finds no running subagent still records that the user stopped its open turn" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "done" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    const child_id = try reviewerId(runtime, arena);
    const work_id = blk: {
        runtime.admission_mutex.lockUncancelable(io_mod.getIo());
        defer runtime.admission_mutex.unlock(io_mod.getIo());
        break :blk try runtime.openTurnWorkLocked(alloc, child_id, .user, null, false);
    };
    defer alloc.free(work_id);

    const closed = (try runtime.closeChild(child_id, .user)).?;
    try std.testing.expect(closed.stopped);
    const index = runtime.findTurnWorkLocked(child_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(runtime.turn_works.items[index].stopped_by == .user);
    _ = runtime.endClosingWork(.{ .child_id = child_id, .work_id = work_id, .outcome = .cancelled, .report_owed = false });
    try std.testing.expect(runtime.settleClose(child_id));
}

test "the user's close of a working subagent reports that the user closed it" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "working" } }, "call-1", null);
    try waitForRuns(&fixture, 1);
    const child_id = try reviewerId(runtime, arena);
    const closed = (try runtime.closeChild(child_id, .user)).?;
    try std.testing.expect(closed.stopped);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    try std.testing.expectEqual(child_state.EndFacts{ .cause = .user_close }, fixture.ends.items[0]);
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[0], "The user closed it before it finished.") != null);
    try std.testing.expect(std.mem.startsWith(u8, fixture.reports.items[0], "reviewer "));
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expect(registry.findById(child_id) == null);

    try std.testing.expectEqualStrings("reviewer", try runtime.childName(arena, child_id));
    const taken = try runtime.takeClosed(alloc);
    defer {
        for (taken) |id| alloc.free(id);
        alloc.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 1), taken.len);
}

test "an idle subagent closes at once, and its name then starts a new one" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    const old_id = try reviewerId(runtime, arena);
    const closed = (try runtime.closeChild(old_id, .parent)).?;
    try std.testing.expect(!closed.stopped);
    try std.testing.expectEqual(@as(usize, 0), closed.dropped);
    {
        var registry = try runtime.managed.state_store.load(alloc);
        defer registry.deinit(alloc);
        try std.testing.expect(registry.findById(old_id) == null);
    }
    try std.testing.expect((try runtime.closeChild(old_id, .parent)) == null);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "again" } }, "call-2", null);
    try waitUntilQuiet(runtime);
    const new_id = try reviewerId(runtime, arena);
    try std.testing.expect(!std.mem.eql(u8, old_id, new_id));
    const taken = try runtime.takeClosed(alloc);
    defer {
        for (taken) |id| alloc.free(id);
        alloc.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 1), taken.len);
}

test "a child started with a prompt prefix gets the prefix ahead of its message" {
    const alloc = std.testing.allocator;
    const request: model_contract.Request = .{ .message = .{
        .agent = @constCast("scout"),
        .message = @constCast("find the parser"),
        .profile = @constCast("explore"),
    } };
    var work = try makeManagedWork(alloc, "op-1", @as([32]u8, @splat(0)), request, .{
        .caller_id = "root",
        .invocation_id = "call-1",
        .defaults = undefined,
        .max_result_bytes = 0,
        .timestamp_ms = 0,
        .prompt_prefix = "<git-context>\nBranch: main\n</git-context>",
    });
    defer work.deinit(alloc);
    try std.testing.expectEqualStrings("<git-context>\nBranch: main\n</git-context>\n\nfind the parser", work.message);
}

test "a new subagent starts in the main profile unless its message names one, and the list says which" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "look" } }, "call-1", null);
    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "copier", .message = "copy", .profile = "plan" } }, "call-2", null);
    try waitUntilQuiet(runtime);

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "copier", .message = "again" } }, "call-3", null);
    try waitUntilQuiet(runtime);

    const listing = try runtime.listChildren(alloc);
    defer Runtime.freeChildListing(alloc, listing);
    try std.testing.expectEqual(@as(usize, 2), listing.len);
    try std.testing.expectEqualStrings("reviewer", listing[0].name);
    try std.testing.expectEqualStrings("main", listing[0].profile);
    try std.testing.expectEqualStrings("copier", listing[1].name);
    try std.testing.expectEqualStrings("plan", listing[1].profile);
}

test "a foreground Agent call returns the subagent's reply and posts no separate report" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    const result = try callTool(runtime, arena, .{ .message = .{ .agent = "scout", .message = "look", .foreground = true } }, "call-1", null);
    try std.testing.expect(std.mem.find(u8, result, "status: completed") != null);
    try std.testing.expect(std.mem.find(u8, result, "[summary]") != null);
    try std.testing.expect(std.mem.find(u8, result, "DONE look") != null);
    try std.testing.expect(std.mem.find(u8, result, "resume_hint") != null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 0), fixture.reportCount());
}

test "a report handed back as a foreground Agent result is not pending after the session is reopened" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    {
        const runtime = try mailboxRuntime(alloc, &fixture, &parent);
        defer runtime.deinit();
        const foreground = try callTool(runtime, arena, .{ .message = .{ .agent = "scout", .message = "look", .foreground = true } }, "call-1", null);
        try std.testing.expect(std.mem.find(u8, foreground, "DONE look") != null);
        _ = try callTool(runtime, arena, .{ .message = .{ .agent = "runner", .message = "dig" } }, "call-2", null);
        try waitUntilQuiet(runtime);
        try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    }

    const pending = try reopenedPendingReports(arena, &parent);
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expect(std.mem.startsWith(u8, fixture.reports.items[0], "runner "));
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[0], pending[0].work_id) != null);
}

test "a foreground Agent call cut before its result was handed back leaves its report pending" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    {
        const runtime = try mailboxRuntime(alloc, &fixture, &parent);
        defer runtime.deinit();
        var request = try model_contract.validateRequest(alloc, .{ .message = .{ .agent = "scout", .message = "look", .foreground = true } });
        defer request.deinit(alloc);
        var cut: std.atomic.Value(bool) = .init(false);
        const Cutter = struct {
            fn run(seen: *MailboxFixture, flag: *std.atomic.Value(bool)) void {
                waitForRuns(seen, 1) catch {};
                flag.store(true, .seq_cst);
            }
        };
        const cutter = try std.Thread.spawn(.{}, Cutter.run, .{ &fixture, &cut });
        defer cutter.join();
        try std.testing.expectError(error.Cancelled, runtime.executeManaged(arena, &request, .{
            .caller_id = runtime.root_id,
            .invocation_id = "call-1",
            .defaults = .{ .provider = .gateway, .model = "test", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
            .max_result_bytes = 4096,
            .timestamp_ms = 1,
            .cancel_flag = &cut,
        }));
        fixture.release.set(io_mod.getIo());
        try waitUntilQuiet(runtime);
        try std.testing.expectEqual(@as(usize, 1), fixture.reportCount());
    }

    const pending = try reopenedPendingReports(arena, &parent);
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expect(std.mem.startsWith(u8, fixture.reports.items[0], "scout "));
    try std.testing.expect(std.mem.find(u8, fixture.reports.items[0], pending[0].work_id) != null);
}

fn reopenedPendingReports(arena: Allocator, parent: *child_state.TestParent) ![]reports.Pending {
    const parent_id = try arena.dupe(u8, parent.parent.id());
    parent.parent.close();
    parent.parent = try session_adapter.Session.resumeSession(parent.alloc, &parent.store, .{ .id = parent_id }, parent.home, .ask);
    const lines = (try parent.parent.pendingReportLines(arena)) orelse return &.{};
    return reports.pendingReports(arena, lines);
}

test "a root may start only the allowed agent types, and the refusal names them" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    const refused = try callTool(runtime, arena, .{ .message = .{ .agent = "copier", .message = "copy", .profile = "agent" } }, "call-1", null);
    try std.testing.expect(std.mem.find(u8, refused, "agent_type_not_allowed") != null);
    try std.testing.expect(std.mem.find(u8, refused, "Allowed subagent types: coder, explore, plan") != null);
    const listing = try runtime.listChildren(alloc);
    defer Runtime.freeChildListing(alloc, listing);
    try std.testing.expectEqual(@as(usize, 0), listing.len);
}

const BackgroundWorkProbe = struct {
    live: std.atomic.Value(bool) = .init(true),
    asked: std.atomic.Value(usize) = .init(0),

    fn isLive(raw: *anyopaque) bool {
        const self: *BackgroundWorkProbe = @ptrCast(@alignCast(raw));
        _ = self.asked.fetchAdd(1, .seq_cst);
        return self.live.load(.seq_cst);
    }

    fn endSoon(self: *BackgroundWorkProbe) void {
        io_mod.sleep(30 * std.time.ns_per_ms);
        self.live.store(false, .seq_cst);
    }
};

test "the tree is not quiet while a background task of the turn is live, and no mail is needed to end the wait" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    var fixture = MailboxFixture{ .worker = &worker };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    try std.testing.expectEqual(Runtime.TreeWake.quiet, runtime.awaitMailOrQuiet(&worker, null));

    var probe = BackgroundWorkProbe{};
    runtime.background_work = .{ .context = &probe, .live_fn = BackgroundWorkProbe.isLive };
    const ender = try std.Thread.spawn(.{}, BackgroundWorkProbe.endSoon, .{&probe});
    defer ender.join();
    try std.testing.expectEqual(Runtime.TreeWake.quiet, runtime.awaitMailOrQuiet(&worker, null));
    try std.testing.expect(probe.asked.load(.seq_cst) >= 2);
}

test "a wait with a passed deadline stops while a background task is still live" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    var fixture = MailboxFixture{ .worker = &worker };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    var probe = BackgroundWorkProbe{};
    runtime.background_work = .{ .context = &probe, .live_fn = BackgroundWorkProbe.isLive };
    try std.testing.expectEqual(Runtime.TreeWake.stopped, runtime.awaitMailOrQuietUntil(&worker, null, io_mod.milliTimestamp() - 1));
    try std.testing.expectEqual(Runtime.TreeWake.stopped, runtime.awaitMailOrQuietUntil(&worker, null, io_mod.milliTimestamp() + 60));
    probe.live.store(false, .seq_cst);
    try std.testing.expectEqual(Runtime.TreeWake.quiet, runtime.awaitMailOrQuietUntil(&worker, null, io_mod.milliTimestamp() - 1));
}

test "mail posted while only a background task is live wakes the wait" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    var fixture = MailboxFixture{ .worker = &worker };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    var probe = BackgroundWorkProbe{};
    runtime.background_work = .{ .context = &probe, .live_fn = BackgroundWorkProbe.isLive };
    const Poster = struct {
        fn run(target: *worker_runtime.WorkerRuntime) void {
            io_mod.sleep(20 * std.time.ns_per_ms);
            const text = std.testing.allocator.dupe(u8, "Background task notice") catch return;
            target.postMail(std.testing.allocator, .{
                .prompt = text,
                .images = &.{},
                .model = &.{},
                .api_key = &.{},
                .permission_mode = .ask,
                .history = &.{},
                .grants = &.{},
                .author = .child,
                .mail = .report,
            }) catch std.testing.allocator.free(text);
        }
    };
    const poster = try std.Thread.spawn(.{}, Poster.run, .{&worker});
    defer poster.join();
    try std.testing.expectEqual(Runtime.TreeWake.mail, runtime.awaitMailOrQuiet(&worker, null));
    try std.testing.expectEqual(@as(usize, 1), worker.queuedPromptCount());
}

test "wait returns at once when nothing works, and when a report arrives" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var worker = worker_runtime.WorkerRuntime{};
    defer worker.deinit(alloc);
    var fixture = MailboxFixture{ .hold = true, .worker = &worker };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    const quiet = try callTool(runtime, arena, .wait, "call-1", &worker);
    try std.testing.expect(std.mem.find(u8, quiet, "nothing more will arrive") != null);

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "reviewer", .message = "first" } }, "call-2", &worker);
    try waitForRuns(&fixture, 1);
    const Releaser = struct {
        fn run(target: *MailboxFixture) void {
            io_mod.sleep(20 * std.time.ns_per_ms);
            target.release.set(io_mod.getIo());
        }
    };
    const releaser = try std.Thread.spawn(.{}, Releaser.run, .{&fixture});
    defer releaser.join();
    const woken = try callTool(runtime, arena, .wait, "call-3", &worker);
    try std.testing.expect(std.mem.find(u8, woken, "A report or message arrived") != null);
    try std.testing.expectEqual(@as(usize, 1), worker.queuedPromptCount());
    const queued = worker.takeQueuedPrompt(alloc).?;
    defer worker_runtime.freeQueuedPrompt(alloc, queued);
    try std.testing.expectEqual(types.MessageAuthor.child, queued.author);
}

test "a subagent that reports never stays quiet when its work completes" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try callTool(runtime, arena, .{ .message = .{ .agent = "quiet", .message = "go", .report = "never" } }, "call-1", null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 0), fixture.reportCount());
    const status = try callTool(runtime, arena, .{ .status = .{} }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, status, "quiet: idle, last work completed, reports never") != null);
}

test "rebinding a moved host context moves its report sink too" {
    const alloc = std.testing.allocator;
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var before = MailboxFixture{};
    defer before.deinit();
    var after = MailboxFixture{};
    defer after.deinit();
    const runtime = try mailboxRuntime(alloc, &before, &parent);
    defer runtime.deinit();
    runtime.rebindHost(&after, .{ .resolve_fn = MailboxFixture.resolve });
    try std.testing.expectEqual(@as(?*anyopaque, &after), runtime.report_sink.?.context);
    try std.testing.expectEqual(@as(?*anyopaque, &after), runtime.child_runner.context);
}

test "the root has no parent to message" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{};
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();
    const body = try callTool(runtime, arena, .{ .message = .{ .agent = "parent", .message = "done" } }, "call-1", null);
    try std.testing.expect(std.mem.find(u8, body, "no_parent") != null);
}

fn childIdNamed(runtime: *Runtime, arena: Allocator, name: []const u8) ![]const u8 {
    var lock = runtime.managed.state_store.acquireLock();
    defer lock.release();
    var registry = try runtime.managed.state_store.load(arena);
    return try arena.dupe(u8, registry.findPersistent(name).?.id);
}

test "a tower child runs in auto mode under the root, with its worktree as its write root" {
    const options = Runtime.towerChildOptions(.{
        .caller_id = "someone-else",
        .invocation_id = "call-tower",
        .parent_permission_mode = .yolo,
        .defaults = .{ .provider = .gateway, .model = "test", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .write_root = "/repo/.tower/worktrees/wt-1",
    }, "root-id");
    try std.testing.expectEqual(types.PermissionMode.auto, options.parent_permission_mode);
    try std.testing.expectEqualStrings("root-id", options.caller_id);
    try std.testing.expectEqualStrings("/repo/.tower/worktrees/wt-1", options.write_root.?);
}

test "a tower child's worktree is recorded as its write root once the child starts" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    const worktree = "/repo/.tower/worktrees/wt-1";
    _ = try runtime.launchTowerChild(arena, "agent-build", "mission text", null, .{
        .caller_id = runtime.root_id,
        .invocation_id = "call-tower",
        .defaults = .{ .provider = .gateway, .model = "test", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .write_root = worktree,
    });
    try waitForRuns(&fixture, 1);
    const child_id = try childIdNamed(runtime, arena, "agent-build");
    try std.testing.expectEqualStrings(worktree, runtime.writeRootFor(child_id).?);
    try std.testing.expect(runtime.writeRootFor("no-such-child") == null);
    fixture.release.set(io_mod.getIo());
    try waitUntilQuiet(runtime);
}

test "a tower child launches the tower-worker profile, which the Agent tool still refuses" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = MailboxFixture{ .hold = true };
    defer fixture.deinit();
    const runtime = try mailboxRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    _ = try runtime.launchTowerChild(arena, "agent-build", "mission text", null, .{
        .caller_id = runtime.root_id,
        .invocation_id = "call-tower",
        .defaults = .{ .provider = .gateway, .model = "test", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .write_root = "/repo/.tower/worktrees/wt-1",
    });
    try waitForRuns(&fixture, 1);
    try std.testing.expectEqualStrings(profiles.tower_worker_name, try childProfileNamed(runtime, arena, "agent-build"));
    const refused = try callTool(runtime, arena, .{ .message = .{ .agent = "copier", .message = "copy", .profile = profiles.tower_worker_name } }, "call-2", null);
    try std.testing.expect(std.mem.find(u8, refused, "agent_type_not_allowed") != null);
    fixture.release.set(io_mod.getIo());
    try waitUntilQuiet(runtime);
}

fn childProfileNamed(runtime: *Runtime, arena: Allocator, name: []const u8) ![]const u8 {
    var lock = runtime.managed.state_store.acquireLock();
    defer lock.release();
    var registry = try runtime.managed.state_store.load(arena);
    return try arena.dupe(u8, registry.findPersistent(name).?.profile.?);
}

fn waitForActiveWork(runtime: *Runtime, arena: Allocator, child_id: []const u8, work_id: []const u8) !void {
    for (0..5000) |_| {
        {
            var lock = runtime.managed.state_store.acquireLock();
            defer lock.release();
            var registry = try runtime.managed.state_store.load(arena);
            if (registry.findById(child_id)) |child| if (child.active) |active| if (std.mem.eql(u8, active.id, work_id)) return;
        }
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.Timeout;
}

fn waitUntilQuiet(runtime: *Runtime) !void {
    for (0..5000) |_| {
        if (runtime.quiet()) return;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return error.Timeout;
}

const OverrideResolverFixture = struct {
    runs: usize = 0,
    observed_model: ?[]u8 = null,
    catalog: []const []const u8 = &.{ "openai/gpt-5.6-terra", "openai/gpt-5.6-terra-fast", "openai/gpt-6-astra" },

    fn resolve(_: ?*anyopaque, alloc: Allocator, _: []const u8) authority.HostResolveError!authority.HostAuthority {
        return authority.HostAuthority.capture(alloc, &.{}, &.{}, .{}, &.{});
    }

    fn run(raw: ?*anyopaque, turn: *execution.TurnContext, message: domain.QueuedMessage, _: domain.AdmissionSnapshot, _: *std.atomic.Value(bool)) execution.ServiceError!execution.RunOutcome {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.runs += 1;
        var preferences = turn.child.?.currentPreferences(std.testing.allocator) catch return error.ProviderFailed;
        defer preferences.deinit(std.testing.allocator);
        self.observed_model = std.testing.allocator.dupe(u8, preferences.model) catch return error.ProviderFailed;
        if (!turn.worker.beginDirectProcessing(1)) return error.ProviderFailed;
        turn.commit(turn.active_work_id.?, .{ .assistant = .{
            .user = .{ .text = message.content },
            .assistant = @constCast("CHILD_OK"),
        } }) catch return error.ProviderFailed;
        return .completed;
    }

    fn resolveModel(raw: ?*anyopaque, alloc: Allocator, raw_model: []const u8) Allocator.Error!model_contract.ModelCatalogMatch {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        return model_contract.matchCatalogModel(alloc, self.catalog, raw_model);
    }
};

fn overrideResolverFixtureRuntime(
    alloc: Allocator,
    fixture: *OverrideResolverFixture,
    parent: *child_state.TestParent,
) !*Runtime {
    return Runtime.create(alloc, &parent.children, .{ .resolve_fn = OverrideResolverFixture.resolve }, .{ .context = fixture, .run_fn = OverrideResolverFixture.run });
}

test "model override resolves against the catalog before child creation" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = OverrideResolverFixture{};
    defer if (fixture.observed_model) |model| alloc.free(model);
    const runtime = try overrideResolverFixtureRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    var request = try model_contract.validateRequest(alloc, .{ .message = .{ .agent = "probe", .message = "probe", .model = "terra-fast" } });
    defer request.deinit(alloc);
    const result = try runtime.executeManaged(arena, &request, .{
        .caller_id = parent.parent.id(),
        .invocation_id = "override-resolve",
        .defaults = .{ .provider = .gateway, .model = "parent-model", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .model_override_resolver = .{ .context = &fixture, .resolve_fn = OverrideResolverFixture.resolveModel },
    });

    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.find(u8, result.body, "Sent to probe") != null);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs);
    try std.testing.expectEqualStrings("openai/gpt-5.6-terra-fast", fixture.observed_model.?);
}

test "unknown and ambiguous model overrides reject before any child session" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = OverrideResolverFixture{};
    defer if (fixture.observed_model) |model| alloc.free(model);
    const runtime = try overrideResolverFixtureRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    const options = ExecuteOptions{
        .caller_id = parent.parent.id(),
        .invocation_id = "override-reject",
        .defaults = .{ .provider = .gateway, .model = "parent-model", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .model_override_resolver = .{ .context = &fixture, .resolve_fn = OverrideResolverFixture.resolveModel },
    };

    var unknown = try model_contract.validateRequest(alloc, .{ .message = .{ .agent = "probe", .message = "probe", .model = "skldjf" } });
    defer unknown.deinit(alloc);
    const unknown_result = try runtime.executeManaged(arena, &unknown, options);
    try std.testing.expect(!unknown_result.success);
    try std.testing.expect(std.mem.find(u8, unknown_result.body, "\"error_code\":\"unknown_model\"") != null);
    try std.testing.expect(std.mem.find(u8, unknown_result.body, "skldjf") != null);
    try std.testing.expect(std.mem.find(u8, unknown_result.body, "omit model to inherit") != null);

    var ambiguous = try model_contract.validateRequest(alloc, .{ .message = .{ .agent = "probe", .message = "probe", .model = "terra" } });
    defer ambiguous.deinit(alloc);
    const ambiguous_result = try runtime.executeManaged(arena, &ambiguous, options);
    try std.testing.expect(!ambiguous_result.success);
    try std.testing.expect(std.mem.find(u8, ambiguous_result.body, "\"error_code\":\"ambiguous_model\"") != null);
    try std.testing.expect(std.mem.find(u8, ambiguous_result.body, "openai/gpt-5.6-terra") != null);
    try std.testing.expect(std.mem.find(u8, ambiguous_result.body, "openai/gpt-5.6-terra-fast") != null);

    try std.testing.expectEqual(@as(usize, 0), fixture.runs);
    var lock = runtime.managed.state_store.acquireLock();
    defer lock.release();
    var registry = try runtime.managed.state_store.load(alloc);
    defer registry.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), registry.children.len);
}

test "model override passes through for non-gateway providers" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: child_state.TestParent = undefined;
    try parent.init(alloc);
    defer parent.deinit();
    var fixture = OverrideResolverFixture{};
    defer if (fixture.observed_model) |model| alloc.free(model);
    const runtime = try overrideResolverFixtureRuntime(alloc, &fixture, &parent);
    defer runtime.deinit();

    var request = try model_contract.validateRequest(alloc, .{ .message = .{ .agent = "probe", .message = "probe", .model = "unknown-model" } });
    defer request.deinit(alloc);
    const result = try runtime.executeManaged(arena, &request, .{
        .caller_id = parent.parent.id(),
        .invocation_id = "override-non-gateway",
        .defaults = .{ .provider = .codex, .model = "parent-model", .effort = .auto, .conversation_language = session.ConversationLanguage.literal("en") },
        .max_result_bytes = 4096,
        .timestamp_ms = 1,
        .model_override_resolver = .{ .context = &fixture, .resolve_fn = OverrideResolverFixture.resolveModel },
    });

    try std.testing.expect(result.success);
    try waitUntilQuiet(runtime);
    try std.testing.expectEqual(@as(usize, 1), fixture.runs);
    try std.testing.expectEqualStrings("unknown-model", fixture.observed_model.?);
}

fn foregroundText(
    alloc: Allocator,
    agent: []const u8,
    profile: []const u8,
    outcome: child_state.Outcome,
    output: []const u8,
) ![]u8 {
    return foreground_text.format(alloc, agent, profile, outcome, output);
}

fn formatFailedResult(alloc: Allocator, failure: ?[]const u8, partial: ?[]const u8) ![]u8 {
    const reason = failure orelse "failure reason unavailable";
    const text = partial orelse "";
    return alloc.print("Subagent failed: {s}. Earlier tool calls may have completed; their effects are not rolled back.{s}{s}", .{
        reason,
        if (text.len > 0) "\n\nPartial result:\n" else "",
        text,
    });
}

test "subagent failure result distinguishes runtime cause from retained partial text" {
    const alloc = std.testing.allocator;
    const text = try formatFailedResult(alloc, "agent_turn_failed: SessionCommitFailed", "one edit completed");
    defer alloc.free(text);
    try std.testing.expect(std.mem.find(u8, text, "SessionCommitFailed") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "Partial result:\none edit completed"));
    const legacy = try formatFailedResult(alloc, null, "");
    defer alloc.free(legacy);
    try std.testing.expect(std.mem.find(u8, legacy, "failure reason unavailable") != null);
    try std.testing.expect(std.mem.find(u8, legacy, "Partial result:") == null);
}

test "a failed foreground result parses back to the failure reason the host wrote" {
    const alloc = std.testing.allocator;
    const failed = try formatFailedResult(alloc, "provider_http_error: 503", "half done");
    defer alloc.free(failed);
    const text = try foregroundText(alloc, "agent-call-1", "coder", .failed, failed);
    defer alloc.free(text);
    const parsed = foreground_text.parse(text).?;
    try std.testing.expectEqual(foreground_text.StopReason.failed, parsed.stop_reason);
    try std.testing.expectEqualStrings("provider_http_error: 503", parsed.failureReason().?);
    try std.testing.expect(foreground_text.isTransportFailure(parsed.failureReason().?));
}

fn terminalResult(
    observation: managed_owner.Observation,
    result: ?[]const u8,
) model_contract.Result {
    return switch (observation.outcome orelse return .{
        .ok = false,
        .result = result,
        .error_code = "child_result_unavailable",
    }) {
        .completed => if (result != null) .{
            .ok = true,
            .result = result,
        } else .{
            .ok = false,
            .error_code = "child_result_unavailable",
        },
        .failed => .{
            .ok = false,
            .result = result,
            .error_code = "child_failed",
        },
        .cancelled => .{
            .ok = false,
            .result = result,
            .error_code = "child_cancelled",
        },
        .interrupted => .{
            .ok = false,
            .result = result,
            .error_code = "child_interrupted",
        },
        .lost => .{
            .ok = false,
            .result = result orelse lost_result,
            .error_code = "child_lost",
        },
    };
}

const sent_result_bytes = 256 + domain.max_agent_name_bytes;

fn sentResult(buf: []u8, agent: []const u8) []const u8 {
    return std.mem.print(buf, "Sent to {s}, which works on it now. Its report arrives on its own when the work ends; keep working or end your turn.", .{agent}) catch "Sent.";
}

fn cancelledSentence(cause: ?child_state.Cause) []const u8 {
    const known = cause orelse return "Its turn was cancelled before it finished.";
    return switch (known) {
        .user_stop => "The user stopped its turn before it finished.",
        .fx_quit => "fx quit before it finished.",
        .user_close => "The user closed it before it finished. A later message to its name starts a new one.",
    };
}

fn withPartial(a: Allocator, note: []const u8, partial: ?[]const u8) ![]const u8 {
    const text = partial orelse return note;
    return a.print("{s}\n\nWhat it had written:\n{s}", .{ note, text });
}

const lost_result = "fx stopped before this message reached the subagent, so it never ran. Send it again if it is still needed.";

test "terminal result projects every managed outcome without a lifecycle phase" {
    const completed = terminalResult(.{
        .phase = .finished,
        .outcome = .completed,
    }, "done");
    try std.testing.expect(completed.ok);
    try std.testing.expectEqualStrings("done", completed.result.?);
    try std.testing.expect(completed.error_code == null);

    const cases = [_]struct {
        outcome: child_state.Outcome,
        error_code: []const u8,
    }{
        .{ .outcome = .failed, .error_code = "child_failed" },
        .{ .outcome = .cancelled, .error_code = "child_cancelled" },
        .{ .outcome = .interrupted, .error_code = "child_interrupted" },
        .{ .outcome = .lost, .error_code = "child_lost" },
    };
    for (cases) |case| {
        const projected = terminalResult(.{
            .phase = .interrupted,
            .outcome = case.outcome,
        }, "partial");
        try std.testing.expect(!projected.ok);
        try std.testing.expectEqualStrings("partial", projected.result.?);
        try std.testing.expectEqualStrings(case.error_code, projected.error_code.?);
    }

    const lost = terminalResult(.{ .phase = .interrupted, .outcome = .lost }, null);
    try std.testing.expect(!lost.ok);
    try std.testing.expectEqualStrings(lost_result, lost.result.?);

    const missing = terminalResult(.{
        .phase = .finished,
        .outcome = .completed,
    }, null);
    try std.testing.expect(!missing.ok);
    try std.testing.expectEqualStrings("child_result_unavailable", missing.error_code.?);
}

fn managedAdmissionReady(
    alloc: Allocator,
    child_id: []const u8,
    created: bool,
) !Runtime.ManagedAdmission {
    return .{ .ready = .{ .child_id = try alloc.dupe(u8, child_id), .created = created } };
}

pub const concurrent_subagents_env = "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS";
const concurrent_subagent_limit_code = "concurrent_subagent_limit_reached";

fn concurrentSubagentLimit(raw: ?[]const u8) ?usize {
    const text = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    const limit = std.fmt.parseInt(usize, text, 10) catch return null;
    return if (limit == 0) null else limit;
}

fn atConcurrentSubagentLimit(running: usize, limit: ?usize) bool {
    return running >= (limit orelse return false);
}

test "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS caps the subagents working at once, and unset leaves no cap" {
    try std.testing.expectEqual(@as(?usize, null), concurrentSubagentLimit(null));
    try std.testing.expectEqual(@as(?usize, null), concurrentSubagentLimit("0"));
    try std.testing.expectEqual(@as(?usize, null), concurrentSubagentLimit("plenty"));
    try std.testing.expectEqual(@as(?usize, 20), concurrentSubagentLimit(" 20 "));
    try std.testing.expect(!atConcurrentSubagentLimit(500, null));
    try std.testing.expect(!atConcurrentSubagentLimit(19, 20));
    try std.testing.expect(atConcurrentSubagentLimit(20, 20));
    try std.testing.expect(atConcurrentSubagentLimit(21, 20));
}

fn managedAdmissionRejected(
    alloc: Allocator,
    child_id: ?[]const u8,
    code: []const u8,
) !Runtime.ManagedAdmission {
    return .{ .rejected = .{
        .child_id = if (child_id) |value| try alloc.dupe(u8, value) else null,
        .code = code,
    } };
}

fn makeManagedWork(
    alloc: Allocator,
    operation_id: []const u8,
    request_fingerprint: [32]u8,
    request: model_contract.Request,
    options: ExecuteOptions,
) !child_state.ActiveWork {
    const id = try alloc.dupe(u8, operation_id);
    errdefer alloc.free(id);
    const owned_message = if (options.prompt_prefix.len > 0)
        try alloc.print("{s}\n\n{s}", .{ options.prompt_prefix, request.message.message })
    else
        try alloc.dupe(u8, request.message.message);
    errdefer alloc.free(owned_message);
    const root_context = if (options.root_user_intent_context.len == 0)
        &.{}
    else
        try alloc.dupe(u8, options.root_user_intent_context);
    errdefer if (root_context.len > 0) alloc.free(root_context);
    return .{
        .id = id,
        .request_fingerprint = request_fingerprint,
        .message = owned_message,
        .root_user_intent_context = @constCast(root_context),
        .root_user_messages = try cloneStrings(alloc, options.root_user_messages),
        .root_user_evidence_complete = options.root_user_evidence_complete,
        .permission_mode = options.parent_permission_mode,
        .created_at_ms = options.timestamp_ms,
    };
}

fn assistantTextForWork(
    history: []const types.HistoryTurn,
    work_id: []const u8,
) ?[]const u8 {
    var index = history.len;
    while (index > 0) {
        index -= 1;
        const candidate = history[index];
        const candidate_work_id = session.historyTurnWorkId(candidate) orelse continue;
        if (!std.mem.eql(u8, candidate_work_id, work_id)) continue;
        return switch (candidate) {
            .assistant => |value| value.assistant,
            .interrupted => |value| value.assistant orelse "",
            .compacted_summary => null,
        };
    }
    return null;
}

fn modelOverrideFailureMessage(
    alloc: Allocator,
    comptime kind: enum { ambiguous, unknown },
    raw_model: []const u8,
    candidates: []const []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    switch (kind) {
        .ambiguous => {
            try writer.print("model override '{s}' matches multiple catalog models: ", .{raw_model});
            for (candidates, 0..) |candidate, index| {
                if (index > 0) try writer.writeAll(", ");
                try writer.writeAll(candidate);
            }
            try writer.writeAll(". Retry with an exact catalog model ID.");
        },
        .unknown => {
            try writer.print("unknown model override '{s}'", .{raw_model});
            if (candidates.len > 0) {
                try writer.writeAll(". Closest catalog matches: ");
                for (candidates, 0..) |candidate, index| {
                    if (index > 0) try writer.writeAll(", ");
                    try writer.writeAll(candidate);
                }
                try writer.writeByte('.');
            } else {
                try writer.writeAll("; no catalog model names match it.");
            }
            try writer.writeAll(" Use an exact catalog model ID, or omit model to inherit the parent's model.");
        },
    }
    return out.toOwnedSlice();
}

fn effectiveDefaults(
    defaults: Defaults,
    override: model_contract.Override,
    resolved_model: ?[]const u8,
) Defaults {
    var resolved = defaults;
    if (override.model) |model| resolved.model = resolved_model orelse model;
    if (override.effort) |effort| resolved.effort = effort;
    return resolved;
}

fn captureAdmission(
    raw: ?*anyopaque,
    alloc: Allocator,
    request: execution.CaptureRequest,
) execution.ServiceError!domain.AdmissionSnapshot {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    var snapshot = self.authority_resolver.resolve(alloc, request.child_id) catch
        return error.AdmissionFailed;
    defer snapshot.deinit(alloc);
    return admissionFrom(alloc, request, &snapshot);
}

fn admissionFrom(
    alloc: Allocator,
    request: execution.CaptureRequest,
    snapshot: *const authority.Snapshot,
) execution.ServiceError!domain.AdmissionSnapshot {
    return domain.captureAdmission(alloc, .{
        .parent_id = request.parent_id,
        .source_id = request.source_id,
        .model = request.preferences.model,
        .provider = request.preferences.provider,
        .effort = request.preferences.effort,
        .ultrafast_mode = request.preferences.ultrafast_mode,
        .permission_mode = snapshot.permission_mode,
        .tool_names = snapshot.tools,
        .rules = snapshot.rules,
        .grants = snapshot.grants,
        .permission_state = snapshot.permission_state,
        .integration_names = snapshot.integrations,
        .authority_generation = if (snapshot.mcp_view) |view|
            mcp_access.authorityGeneration(view)
        else
            0,
        .mcp_view = snapshot.mcp_view,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.AdmissionFailed,
    };
}

fn bindChild(
    raw: ?*anyopaque,
    turn: *execution.TurnContext,
    cancel: *std.atomic.Value(bool),
) execution.ServiceError!void {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    const bind_fn = self.child_runner.bind_fn orelse return;
    return bind_fn(self.child_runner.context, turn, cancel);
}

fn runChild(
    raw: ?*anyopaque,
    turn: *execution.TurnContext,
    message: domain.QueuedMessage,
    admission: domain.AdmissionSnapshot,
    cancel: *std.atomic.Value(bool),
) execution.ServiceError!execution.RunOutcome {
    const self: *Runtime = @ptrCast(@alignCast(raw.?));
    return self.child_runner.run_fn(
        self.child_runner.context,
        turn,
        message,
        admission,
        cancel,
    );
}

fn cloneStrings(
    alloc: Allocator,
    source: []const []const u8,
) ![][]u8 {
    const result = try alloc.alloc([]u8, source.len);
    var built: usize = 0;
    errdefer {
        for (result[0..built]) |value| alloc.free(value);
        alloc.free(result);
    }
    for (source) |value| {
        result[built] = try alloc.dupe(u8, value);
        built += 1;
    }
    return result;
}

pub const ModePolicy = union(enum) {
    full,
    active: struct {
        registry: mode_registry.Registry,
        id: []const u8,
    },

    fn allows(
        self: ModePolicy,
        tool_set: tool_set_contract.ToolSet,
        tool_name: []const u8,
    ) bool {
        return switch (self) {
            .full => true,
            .active => |active| active.registry.toolAllowed(
                tool_set,
                active.id,
                tool_name,
            ),
        };
    }
};

pub const CapabilityPolicy = struct {
    tool_set: tool_set_contract.ToolSet,
    mode: ModePolicy,
};

pub fn captureHostAuthorityWithMcpView(
    alloc: Allocator,
    policy: CapabilityPolicy,
    integration_names: []const []const u8,
    rules: types.PermissionRuleSet,
    grants: []const types.PermissionGrant,
    permission_state: session_permission_state.State,
    mcp_view: ?*const mcp_access.View,
) !authority.HostAuthority {
    var tool_names: std.ArrayList([]const u8) = .empty;
    defer tool_names.deinit(alloc);
    for (policy.tool_set.registry.tools) |registered_tool| {
        if (!policy.mode.allows(policy.tool_set, registered_tool.name)) continue;
        if (permissions.rulesDenyAllTargetsForTool(rules, registered_tool.name)) continue;
        try tool_names.append(alloc, registered_tool.name);
    }
    return authority.HostAuthority.captureWithPermissionStateAndMcpView(
        alloc,
        tool_names.items,
        integration_names,
        rules,
        grants,
        permission_state,
        mcp_view,
    );
}
