const std = @import("std");
const io_mod = @import("../shared/io.zig");
const runtime = @import("../superagent/runtime.zig");
const app_agents_runtime = @import("../app/app_agents_runtime.zig");
const app_instances_runtime = @import("../app/app_instances_runtime.zig");
const app_process_runtime = @import("../app/app_process_runtime.zig");
const session_runtime = @import("../app/app_session_runtime.zig");
const app_session_persistence = @import("../app/session_persistence.zig");
const agents = @import("../agents/agents.zig");
const command = @import("command.zig");
const roots_ledger = @import("roots_ledger.zig");
const machine = @import("machine.zig");
const host_checks = @import("host_checks.zig");
const process_tree = @import("../execution/process_tree.zig");
const managed_execution = @import("../execution/managed_execution.zig");
const managed_contract = @import("../execution/managed_execution_contract.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const builtin = @import("builtin");

const ledger_supported = !builtin.single_threaded and
    (builtin.target.os.tag == .linux or builtin.target.os.tag == .macos);

pub fn cutMainSession(alloc: Allocator, workspace_root: []const u8) ?[]u8 {
    if (comptime !ledger_supported) return null;
    const home = io_mod.homeDir() orelse return null;
    const path = roots_ledger.filePath(alloc, home, workspace_root) catch return null;
    defer alloc.free(path);
    var loaded = (roots_ledger.read(alloc, path) catch return null) orelse return null;
    defer loaded.deinit();
    const ledger = loaded.value;
    if (!roots_ledger.wasCut(ledger, hostStateOf(alloc, ledger))) return null;
    if (ledger.main_session.len == 0) return null;
    return alloc.dupe(u8, ledger.main_session) catch null;
}

fn hostStateOf(alloc: Allocator, ledger: roots_ledger.Ledger) roots_ledger.HostState {
    if (comptime !ledger_supported) return .live;
    const pid = std.math.cast(std.posix.pid_t, ledger.host_pid) orelse return .gone;
    if (pid <= 0) return .gone;
    return if (process_tree.sameProcessIsAlive(alloc, pid, ledger.host_stamp)) .live else .gone;
}

const Allocator = std.mem.Allocator;
const ChildAgent = app_agents_runtime.ChildAgent;

pub fn bind(comptime App: type, app: *App) void {
    const Host = AppHost(App);
    const host = app.alloc.create(Host) catch {
        runtime.unbind();
        return;
    };
    host.* = .{ .app = app };
    runtime.bind(.{
        .context = host,
        .start = Host.start,
        .prompt = Host.prompt,
        .status = Host.status,
        .list = Host.list,
        .stop = Host.stop,
        .projects = Host.projects,
        .journal = Host.journal,
        .turn_finished = Host.turnFinished,
        .turn_ended = Host.turnEnded,
        .drain = Host.drainTurnEvents,
        .close = Host.close,
    });
}

fn AppHost(comptime App: type) type {
    return struct {
        const Self = @This();
        const AgentsRuntime = app_agents_runtime.Runtime(App);
        const InstancesRuntime = app_instances_runtime.Runtime(App);
        const SessionAppRuntime = session_runtime.Runtime(App);
        const ProcessRuntime = app_process_runtime.Runtime(App);

        app: *App,
        roots: std.StringHashMapUnmanaged(*Root) = .empty,
        counter: u64 = 0,
        pending_ends: std.ArrayList(PendingEnd) = .empty,
        ledger_path: ?[]u8 = null,
        ledger_main_session: []const u8 = "",
        restart_checked: bool = false,
        state_lock: std.Io.Mutex = .init,
        job_lock: std.Io.Mutex = .init,
        job_mail: std.ArrayList(JobNote) = .empty,
        job_news: std.atomic.Value(bool) = .init(false),

        const JobNote = struct {
            root: *Root,
            text: []u8,
        };

        const PidSlot = struct {
            pid: i32,
            timeout_ms: u64,
            state: std.atomic.Value(State) = .init(.waiting),
            outcome: runtime.PidWait = .still_running,
            news: *std.atomic.Value(bool),

            const State = enum(u8) { waiting, done, abandoned };

            fn run(slot: *PidSlot) void {
                slot.outcome = runtime.waitForPid(slot.pid, slot.timeout_ms);
                if (slot.state.cmpxchgStrong(.waiting, .done, .acq_rel, .acquire) == null) {
                    slot.news.store(true, .release);
                    return;
                }
                std.heap.page_allocator.destroy(slot);
            }

            fn release(slot: *PidSlot) void {
                if (slot.state.cmpxchgStrong(.waiting, .abandoned, .acq_rel, .acquire) == null) return;
                std.heap.page_allocator.destroy(slot);
            }
        };

        const JobWait = struct {
            deadline_ms: i64,
            pid_slot: ?*PidSlot = null,
            tasks: usize = 0,
        };

        const PendingEnd = struct {
            agent: *agents.Agent,
            final: []u8,
            end: ?runtime.TurnEnd = null,
            waited_one_drain: bool = false,

            fn carriesNoReply(self: PendingEnd) bool {
                return self.end != null and self.end.? != .blocked and self.final.len == 0;
            }
        };

        const Root = struct {
            child: *ChildAgent,
            name: []const u8,
            cwd: []const u8,
            session: []const u8,
            prompt_id: []const u8 = "",
            last_prompt: []const u8 = "",
            phase: machine.State = .idle,
            queue: std.ArrayList([]u8) = .empty,
            carried: std.ArrayList([]u8) = .empty,
            job_notes: std.ArrayList([]u8) = .empty,
            job_wait: ?JobWait = null,
            sends: u64 = 0,
            turn_ends: u64 = 0,
            child_gone: bool = false,
            revived: bool = false,
            open_steps: u32 = 0,
            blocked_steps: u32 = 0,
        };

        fn advance(root: *Root, event: machine.Event) bool {
            const next = machine.step(root.phase, event) orelse {
                debug_trace.logf("superagent", "root {s} in state {s} refused event {s}", .{ root.name, @tagName(root.phase), @tagName(event) });
                return false;
            };
            root.phase = next;
            return true;
        }

        fn rootAlive(root: *Root) bool {
            return machine.isLive(root.phase) and root.child.agent.worker_thread != null;
        }

        fn factsOf(root: *Root) machine.AdmissionFacts {
            const running = rootAlive(root);
            return .{
                .state = root.phase,
                .worker_running = running,
                .worker_busy = running and busyWorker(&root.child.agent.worker),
                .queued = root.queue.items.len,
            };
        }

        fn minFreeMb() u64 {
            return host_checks.minFreeMb(managed_contract.taskSettings().root_min_free_mb);
        }

        fn start(raw: ?*anyopaque, alloc: Allocator, request: runtime.Request) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(raw.?));
            self.state_lock.lockUncancelable(io_mod.getIo());
            defer self.state_lock.unlock(io_mod.getIo());
            return self.startLocked(alloc, request);
        }

        fn startLocked(self: *Self, _: Allocator, request: runtime.Request) anyerror!void {
            const app = self.app;
            if (self.roots.get(request.agent)) |root| {
                if (rootAlive(root)) return;
                const ended: ?*ChildAgent = if (root.child_gone) null else root.child;
                self.removeRoot(app.alloc, request.agent);
                if (ended) |child| AgentsRuntime.dropHosted(app, child);
            }
            if (comptime !@hasField(App, "instances")) return error.SuperagentUnavailable;
            if (!app.instances.seed.captured) return error.HostNotStarted;
            const project = try resolveProject(app.alloc, app, request);
            errdefer app.alloc.free(project);
            if (request.session) |id| {
                if (openInstanceWithSession(app, id)) |restored| {
                    try self.rememberRoot(restored, request.agent, project, id);
                    restored.agent.project_root = project;
                    return;
                }
            }
            if (host_checks.admitStart(.{ .available_kb = host_checks.availableKb(), .min_free_mb = minFreeMb() }) == .refuse_low_memory) return error.HostMemoryLow;
            const child = try AgentsRuntime.addInstance(app);
            errdefer AgentsRuntime.dropHosted(app, child);
            const agent = &child.agent;
            agent.project_root = project;
            app_session_persistence.Persistence.initInto(&agent.session_persistence);
            try SessionAppRuntime.configureStartupPreferences(
                app,
                agent,
                app.instances.seed.provider,
                app.instances.seed.configured_model,
                app.instances.seed.model_source,
                app.instances.seed.selected_model,
                app.instances.seed.effort,
                app.instances.seed.fast_mode,
                app.instances.seed.fast_mode_model_bound,
                app.instances.seed.configured_ultrafast_mode,
                app.instances.seed.ultrafast_process_override,
                app.instances.seed.effort_process_override,
                app.instances.seed.fast_process_override,
                app.instances.seed.provider_process_override,
            );
            agent.worker.agent_turn_settings = app.instances.seed.turn_settings;
            agent.permission_mode = app.instanceProfileMode(agent, app.instances.seed.permission_mode);
            try SessionAppRuntime.initializePersistence(app, agent, request.session != null);
            if (request.session) |id| {
                try AgentsRuntime.visit(app, child, id, resumeInContext);
                child.view_built = true;
            } else {
                try SessionAppRuntime.beginInstanceSession(app, agent);
                SessionAppRuntime.enableSessionStores(app, agent);
                SessionAppRuntime.applyProjectModel(app, agent);
                try SessionAppRuntime.applyProcessModelOverride(app, agent);
            }
            const session_id = SessionAppRuntime.activeSessionId(agent) orelse request.agent;
            try AgentsRuntime.nameInstance(app, child, session_id);
            child.session_attached = true;
            try ProcessRuntime.startAgentWorkerThread(app, agent);
            if (request.session != null) SessionAppRuntime.startPendingResume(app, agent);
            try self.rememberRoot(child, request.agent, project, session_id);
        }

        fn rememberRoot(self: *Self, child: *ChildAgent, name: []const u8, project: []const u8, session_id: []const u8) !void {
            const alloc = self.app.alloc;
            const root = try alloc.create(Root);
            errdefer alloc.destroy(root);
            const owned_root_name = try alloc.dupe(u8, name);
            errdefer alloc.free(owned_root_name);
            const owned_session = try alloc.dupe(u8, session_id);
            errdefer alloc.free(owned_session);
            root.* = .{
                .child = child,
                .name = owned_root_name,
                .cwd = project,
                .session = owned_session,
            };
            const owned_key = try alloc.dupe(u8, name);
            errdefer alloc.free(owned_key);
            try self.roots.put(alloc, owned_key, root);
            self.saveLedger();
        }

        fn openInstanceWithSession(app: *App, session_id: []const u8) ?*ChildAgent {
            for (app.child_agents.items) |child| {
                if (child.agent.role != .instance) continue;
                const saved = SessionAppRuntime.savedSessionId(&child.agent) orelse continue;
                if (std.mem.eql(u8, saved, session_id)) return child;
            }
            return null;
        }

        fn ledgerPath(self: *Self) ?[]const u8 {
            if (self.ledger_path) |path| return path;
            const home = io_mod.homeDir() orelse return null;
            self.ledger_path = roots_ledger.filePath(self.app.alloc, home, self.app.workspace_root) catch return null;
            return self.ledger_path;
        }

        fn saveLedger(self: *Self) void {
            self.writeLedger(.live);
        }

        const LedgerOwner = enum { live, released };

        fn writeLedger(self: *Self, owner: LedgerOwner) void {
            if (comptime !ledger_supported) return;
            const alloc = self.app.alloc;
            const path = self.ledgerPath() orelse return;
            var records: std.ArrayList(roots_ledger.Root) = .empty;
            defer records.deinit(alloc);
            var iterator = self.roots.iterator();
            while (iterator.next()) |entry| {
                const root = entry.value_ptr.*;
                if (!machine.isLive(root.phase)) continue;
                const alive = root.child.agent.worker_thread != null;
                records.append(alloc, .{
                    .agent = root.name,
                    .cwd = root.cwd,
                    .session = root.session,
                    .prompt = roots_ledger.savedPrompt(root.last_prompt),
                    .in_flight = alive and busyWorker(&root.child.agent.worker),
                    .queue = root.queue.items,
                    .sends = root.sends,
                    .turn_ends = root.turn_ends,
                }) catch return;
            }
            const own_pid: std.posix.pid_t = @intCast(std.c.getpid());
            const main_session = SessionAppRuntime.savedSessionId(&self.app.main_agent) orelse "";
            setOwned(&self.ledger_main_session, alloc, main_session);
            roots_ledger.write(alloc, path, .{
                .workspace = self.app.workspace_root,
                .host_pid = if (owner == .live) own_pid else 0,
                .host_stamp = if (owner == .live) process_tree.liveProcessStamp(alloc, own_pid) orelse 0 else 0,
                .main_session = main_session,
                .roots = records.items,
            }) catch |err| debug_trace.logf("superagent", "roots ledger not written err={s}", .{@errorName(err)});
        }

        fn recordMainSessionOnceSaved(self: *Self) void {
            if (self.roots.count() == 0) return;
            const current = SessionAppRuntime.savedSessionId(&self.app.main_agent) orelse return;
            if (std.mem.eql(u8, current, self.ledger_main_session)) return;
            self.saveLedger();
        }

        fn close(raw: ?*anyopaque, exit: runtime.HostExit) void {
            const self: *Self = @ptrCast(@alignCast(raw.?));
            if (self.roots.count() == 0) return;
            if (exit == .asked) self.writeLedger(.released);
        }

        fn resumeAfterCut(self: *Self) void {
            if (comptime !ledger_supported) return;
            if (comptime !@hasField(App, "instances")) return;
            if (self.restart_checked) return;
            if (!self.app.instances.seed.captured) return;
            if (self.app.instances.restore_pending or self.app.instances.restore_on_pick) return;
            self.restart_checked = true;
            const alloc = self.app.alloc;
            const path = self.ledgerPath() orelse return;
            var loaded = (roots_ledger.read(alloc, path) catch |err| {
                debug_trace.logf("superagent", "roots ledger unreadable err={s}", .{@errorName(err)});
                return;
            }) orelse return;
            defer loaded.deinit();
            const ledger = loaded.value;
            const host = hostStateOf(alloc, ledger);
            if (!roots_ledger.wasCut(ledger, host)) return;
            var brought_back: usize = 0;
            for (ledger.roots) |record| {
                self.startLocked(alloc, .{
                    .agent = record.agent,
                    .prompt = "",
                    .cwd = record.cwd,
                    .session = record.session,
                }) catch |err| {
                    debug_trace.logf("superagent", "root not brought back agent={s} session={s} err={s}", .{ record.agent, record.session, @errorName(err) });
                    continue;
                };
                brought_back += 1;
                if (self.roots.get(record.agent)) |root| {
                    root.sends = record.sends;
                    root.turn_ends = record.turn_ends;
                    for (record.queue) |item| self.queueItem(root, item);
                }
                if (record.in_flight and record.prompt.len > 0) {
                    self.runAgain(record) catch |err| {
                        debug_trace.logf("superagent", "cut prompt not sent again agent={s} err={s}", .{ record.agent, @errorName(err) });
                    };
                    continue;
                }
                if (self.roots.get(record.agent)) |root| self.sendQueuedItem(root);
            }
            self.saveLedger();
            if (brought_back == 0) return;
            const event = roots_ledger.resumedEvent(alloc, ledger, host) catch return;
            defer alloc.free(event);
            self.app.postAgentMessage(&self.app.main_agent, event, .child, .report) catch {};
        }

        fn runAgain(self: *Self, record: roots_ledger.Root) !void {
            const alloc = self.app.alloc;
            const root = self.roots.get(record.agent) orelse return error.PeerNotFound;
            const text = try roots_ledger.resumePrompt(alloc, record);
            defer alloc.free(text);
            if (machine.step(root.phase, .prompt_sent) == null) return error.PeerNotAlive;
            const admitted = try self.app.enqueuePrompt(&root.child.agent, text);
            if (!admitted) return error.PromptNotAdmitted;
            setOwned(&root.last_prompt, alloc, record.prompt);
            root.sends += 1;
            _ = advance(root, .prompt_sent);
            self.journalEntry(root, .send, "restart", "", "", record.prompt);
        }

        fn resolveProject(alloc: Allocator, app: *App, request: runtime.Request) ![]u8 {
            const parent = std.Io.Dir.path.dirname(app.workspace_root) orelse app.workspace_root;
            const named = if (request.cwd.len > 0) request.cwd else request.agent;
            const candidate = if (std.fs.path.isAbsolute(named))
                try alloc.dupe(u8, named)
            else
                try std.Io.Dir.path.join(alloc, &.{ parent, named });
            errdefer alloc.free(candidate);
            if (!isProjectDirectory(candidate)) return error.ProjectNotFound;
            return candidate;
        }

        fn isProjectDirectory(path: []const u8) bool {
            var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), path, .{}) catch return false;
            dir.close(io_mod.getIo());
            return true;
        }

        fn resumeInContext(session_id: []const u8, app: *App, agent: *agents.Agent) anyerror!void {
            try SessionAppRuntime.resumeSessionById(app, agent, session_id);
        }

        fn prompt(raw: ?*anyopaque, alloc: Allocator, request: runtime.Request) anyerror!runtime.Result {
            const self: *Self = @ptrCast(@alignCast(raw.?));
            if (request.prompt.len == 0) return error.EmptyPrompt;
            self.state_lock.lockUncancelable(io_mod.getIo());
            defer self.state_lock.unlock(io_mod.getIo());
            try self.ensureRunning(alloc, request);
            const root = self.roots.get(request.agent) orelse return error.PeerNotFound;
            const admission = machine.admit(factsOf(root));
            if (admission == .refuse_not_alive) return error.PeerNotAlive;
            const held = admission == .queue_behind;
            if (held) {
                self.queueItem(root, request.prompt);
            } else {
                try self.send(root, request.prompt, "owner");
            }
            for (request.queue) |item| {
                if (item.len > 0) self.queueItem(root, item);
            }
            self.saveLedger();
            const text = if (held)
                try std.fmt.allocPrint(alloc, "queued on persistent agent {s} behind its running work ({d} queued); fx sends each queued item when the turn before it ends, so do not instruct it again", .{ root.name, root.queue.items.len })
            else if (root.queue.items.len > 0)
                try std.fmt.allocPrint(alloc, "sent as a normal root user prompt to persistent agent {s}, with {d} more queued; fx sends each queued item when the turn before it ends", .{ root.name, root.queue.items.len })
            else
                try std.fmt.allocPrint(alloc, "queued as a normal root user prompt on persistent agent {s}", .{root.name});
            return .{
                .agent = try alloc.dupe(u8, request.agent),
                .cwd = try alloc.dupe(u8, root.cwd),
                .prompt_id = try alloc.dupe(u8, root.prompt_id),
                .session = try alloc.dupe(u8, root.session),
                .text = text,
                .status = try alloc.dupe(u8, "queued"),
            };
        }

        fn ensureRunning(self: *Self, alloc: Allocator, request: runtime.Request) !void {
            const existing = self.roots.get(request.agent) orelse return self.startLocked(alloc, .{
                .agent = request.agent,
                .prompt = "",
                .cwd = request.cwd,
                .session = request.session,
            });
            if (rootAlive(existing)) return;
            const carried_queue = existing.queue;
            existing.queue = .empty;
            errdefer {
                var dropped = carried_queue;
                for (dropped.items) |item| alloc.free(item);
                dropped.deinit(self.app.alloc);
            }
            const saved_session = try alloc.dupe(u8, existing.session);
            defer alloc.free(saved_session);
            const saved_cwd = try alloc.dupe(u8, existing.cwd);
            defer alloc.free(saved_cwd);
            try self.startLocked(alloc, .{
                .agent = request.agent,
                .prompt = "",
                .cwd = saved_cwd,
                .session = request.session orelse saved_session,
            });
            if (self.roots.get(request.agent)) |started| started.queue = carried_queue;
        }

        fn queueItem(self: *Self, root: *Root, item: []const u8) void {
            const alloc = self.app.alloc;
            const owned = alloc.dupe(u8, item) catch return;
            root.queue.append(alloc, owned) catch alloc.free(owned);
        }

        fn send(self: *Self, root: *Root, text: []const u8, by: []const u8) !void {
            const alloc = self.app.alloc;
            if (machine.step(root.phase, .prompt_sent) == null) return error.PeerNotAlive;
            const admitted = try self.app.enqueuePrompt(&root.child.agent, text);
            if (!admitted) return error.PromptNotAdmitted;
            self.counter += 1;
            var id_buf: [32]u8 = undefined;
            const prompt_id = std.fmt.bufPrint(&id_buf, "p{d}", .{self.counter}) catch unreachable;
            setOwned(&root.prompt_id, alloc, prompt_id);
            setOwned(&root.last_prompt, alloc, text);
            root.sends += 1;
            _ = advance(root, .prompt_sent);
            self.journalEntry(root, .send, by, "", "", text);
        }

        fn journalEntry(self: *Self, root: *Root, event: roots_ledger.JournalEvent, by: []const u8, decision: []const u8, report: []const u8, text: []const u8) void {
            if (comptime !ledger_supported) return;
            const path = self.ledgerPath() orelse return;
            roots_ledger.appendJournal(self.app.alloc, path, .{
                .at_ms = io_mod.milliTimestamp(),
                .root = root.name,
                .session = root.session,
                .event = event,
                .by = by,
                .decision = decision,
                .report = report,
                .queued = root.queue.items.len,
                .text = text,
            }) catch |err| debug_trace.logf("superagent", "journal line not written err={s}", .{@errorName(err)});
        }

        fn sendQueuedItem(self: *Self, root: *Root) void {
            if (root.queue.items.len == 0) return;
            const item = root.queue.orderedRemove(0);
            defer self.app.alloc.free(item);
            self.send(root, item, "runtime") catch |err| self.handToOwner(root, "", @errorName(err));
        }

        fn status(raw: ?*anyopaque, alloc: Allocator, agent_name: []const u8) anyerror!runtime.Snapshot {
            const self: *Self = @ptrCast(@alignCast(raw.?));
            const root = self.roots.get(agent_name) orelse return error.PeerNotFound;
            const alive = rootAlive(root);
            const peer_activity = machine.activity(factsOf(root));
            const busy = peer_activity == .busy;
            const peer_status: runtime.Status = switch (peer_activity) {
                .stopped => .stopped,
                .busy => .busy,
                .idle => .idle,
            };
            return .{
                .agent = try alloc.dupe(u8, root.name),
                .cwd = try alloc.dupe(u8, root.cwd),
                .status = peer_status,
                .busy = busy,
                .alive = alive,
                .prompt_id = try alloc.dupe(u8, root.prompt_id),
                .session = try alloc.dupe(u8, root.session),
            };
        }

        fn busyWorker(worker: anytype) bool {
            return worker.isProcessing() or worker.queuedPromptCount() > 0 or worker.hasPendingEvents();
        }

        fn journal(raw: ?*anyopaque, alloc: Allocator, agent_name: []const u8, offset: usize, limit: usize) anyerror!runtime.Journal {
            const self: *Self = @ptrCast(@alignCast(raw.?));
            const root = self.roots.get(agent_name) orelse return error.PeerNotFound;
            if (root.child_gone) return error.PeerNotAlive;
            const full = try journalText(alloc, root);
            defer alloc.free(full);
            const start_at = @min(offset, full.len);
            const end_at = @min(full.len, start_at +| limit);
            return .{
                .text = try alloc.dupe(u8, full[start_at..end_at]),
                .total = full.len,
                .offset = start_at,
            };
        }

        fn journalText(alloc: Allocator, root: *Root) ![]u8 {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(alloc);
            for (root.child.agent.session.agent.history.items) |turn| {
                switch (turn) {
                    .assistant => |entry| {
                        const line = try std.fmt.allocPrint(alloc, "assistant: {s}\n", .{entry.assistant});
                        defer alloc.free(line);
                        try out.appendSlice(alloc, line);
                    },
                    .interrupted => try out.appendSlice(alloc, "interrupted\n"),
                    .compacted_summary => try out.appendSlice(alloc, "compacted summary\n"),
                }
            }
            return out.toOwnedSlice(alloc);
        }

        fn turnFinished(raw: ?*anyopaque, agent_ptr: *anyopaque, final_response: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(raw.?));
            const agent: *agents.Agent = @ptrCast(@alignCast(agent_ptr));
            if (rootFor(self, agent) == null) return;
            const owned = self.app.alloc.dupe(u8, final_response) catch return;
            self.pending_ends.append(self.app.alloc, .{ .agent = agent, .final = owned }) catch {
                self.app.alloc.free(owned);
            };
        }

        fn turnEnded(raw: ?*anyopaque, agent_ptr: *anyopaque, end: runtime.TurnEnd, text: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(raw.?));
            const agent: *agents.Agent = @ptrCast(@alignCast(agent_ptr));
            if (rootFor(self, agent) == null) return;
            const owned = self.app.alloc.dupe(u8, text) catch return;
            self.pending_ends.append(self.app.alloc, .{ .agent = agent, .final = owned, .end = end }) catch {
                self.app.alloc.free(owned);
            };
        }

        fn drainTurnEvents(raw: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(raw.?));
            if (!self.state_lock.tryLock()) return;
            defer self.state_lock.unlock(io_mod.getIo());
            self.resumeAfterCut();
            self.recordMainSessionOnceSaved();
            self.reapDeadRoots();
            self.settleJobWaits();
            if (self.pending_ends.items.len == 0) return;
            const alloc = self.app.alloc;
            const pending = self.pending_ends.toOwnedSlice(alloc) catch return;
            defer alloc.free(pending);
            for (pending, 0..) |item, index| {
                const root = rootFor(self, item.agent) orelse {
                    alloc.free(item.final);
                    continue;
                };
                if (item.carriesNoReply()) {
                    if (laterEndFor(pending[index + 1 ..], item.agent)) {
                        alloc.free(item.final);
                        continue;
                    }
                    if (!item.waited_one_drain) {
                        var waiting = item;
                        waiting.waited_one_drain = true;
                        self.pending_ends.append(alloc, waiting) catch alloc.free(item.final);
                        continue;
                    }
                }
                defer alloc.free(item.final);
                if (item.end) |end| {
                    root.turn_ends += 1;
                    _ = advance(root, .turn_ended);
                    self.journalEntry(root, .turn_end, "root", @tagName(runtime.Decision.hand_to_owner), @tagName(end), item.final);
                    self.postTurnEnded(root, end, item.final);
                } else self.decideTurnEnd(root, item.final);
            }
        }

        fn decideTurnEnd(self: *Self, root: *Root, final_response: []const u8) void {
            const final = if (final_response.len > 0) final_response else finalResponse(root);
            const report = runtime.reportOf(final);
            root.turn_ends += 1;
            if (!machine.ownsOpenTurn(root.phase)) {
                self.journalEntry(root, .turn_end, "root", @tagName(runtime.Decision.leave_idle), @tagName(report.state), final);
                self.postTurnEnd(root, final);
                return;
            }
            _ = advance(root, .turn_ended);
            self.takeJobNotices(root);
            const named_pid = if (root.phase != .waiting_job) liveNamedPid(self.app.alloc, report) else null;
            const running_tasks = liveTaskCount(self.app.alloc, root);
            const decision = runtime.decide(.{
                .report = report.state,
                .queued = root.queue.items.len,
                .running_jobs = running_tasks + @intFromBool(named_pid != null),
                .finished_job_notes = root.job_notes.items.len,
                .open_steps = root.open_steps,
                .blocked_steps = root.blocked_steps,
            });
            const summary = if (report.line.len > 0) report.line else final;
            self.journalEntry(root, .turn_end, "root", @tagName(decision), @tagName(report.state), summary);
            if (!runtime.wakesOwner(decision)) self.carry(root, summary);
            root.revived = false;
            switch (report.state) {
                .finished, .none => {
                    root.open_steps = 0;
                    root.blocked_steps = 0;
                },
                .open, .blocked => {},
            }
            switch (decision) {
                .send_queued_item => self.sendQueuedItem(root),
                .wait_for_job => self.beginJobWait(root, running_tasks, named_pid),
                .send_job_result => self.sendJobResult(root, ""),
                .send_next_step => {
                    if (report.state == .blocked) root.blocked_steps += 1 else root.open_steps += 1;
                    const text = runtime.nextStepPrompt(self.app.alloc, report) catch return;
                    defer self.app.alloc.free(text);
                    self.send(root, text, "runtime") catch |err| self.handToOwner(root, final, @errorName(err));
                },
                .stop_root => {
                    _ = advance(root, .stop_asked);
                    root.child.agent.worker.requestStop();
                    self.journalEntry(root, .stop, "runtime", @tagName(decision), @tagName(report.state), "report finished and nothing queued");
                    self.postTurnEnd(root, final);
                },
                .leave_idle => self.postTurnEnd(root, final),
                .hand_to_owner => self.handToOwner(root, final, ""),
            }
            self.saveLedger();
        }

        fn childListed(self: *Self, child: *ChildAgent) bool {
            for (self.app.child_agents.items) |listed| {
                if (listed == child) return true;
            }
            return false;
        }

        fn deathOf(self: *Self, root: *Root) ?runtime.Death {
            if (!machine.isLive(root.phase)) return null;
            if (!self.childListed(root.child)) return .instance_closed;
            if (root.child.agent.worker.worker_loop_ended.load(.acquire)) return .worker_ended;
            return null;
        }

        fn reapDeadRoots(self: *Self) void {
            const alloc = self.app.alloc;
            const Dead = struct { root: *Root, decision: runtime.DeathDecision, was_waiting: bool, turn_was_open: bool };
            var dead: std.ArrayList(Dead) = .empty;
            defer dead.deinit(alloc);
            var iterator = self.roots.iterator();
            while (iterator.next()) |entry| {
                const root = entry.value_ptr.*;
                const death = self.deathOf(root) orelse continue;
                root.child_gone = death == .instance_closed;
                const turn_was_open = machine.ownsOpenTurn(root.phase);
                const was_waiting = root.phase == .waiting_job;
                self.endJobWait(root);
                _ = advance(root, .died);
                const decision = runtime.decideDeath(.{
                    .turn_open = turn_was_open,
                    .queued = root.queue.items.len,
                    .waiting_on_job = was_waiting,
                    .revived_already = root.revived,
                });
                dead.append(alloc, .{ .root = root, .decision = decision, .was_waiting = was_waiting, .turn_was_open = turn_was_open }) catch continue;
                self.journalEntry(root, .stop, "root", @tagName(decision), "", runtime.deathPhrase(death));
                const event = command.renderDied(alloc, root.name, root.session, death, decision, root.queue.items.len) catch continue;
                defer alloc.free(event);
                self.app.postAgentMessage(&self.app.main_agent, event, .child, .report) catch {};
            }
            for (dead.items) |item| self.actOnDeath(item.root, item.decision, item.turn_was_open, item.was_waiting and !item.turn_was_open);
            if (dead.items.len > 0) self.saveLedger();
        }

        fn actOnDeath(self: *Self, root: *Root, decision: runtime.DeathDecision, turn_was_open: bool, lost_job_wait: bool) void {
            const alloc = self.app.alloc;
            if (decision == .stay_stopped) return;
            const name = alloc.dupe(u8, root.name) catch return;
            defer alloc.free(name);
            const cut_prompt = alloc.dupe(u8, root.last_prompt) catch return;
            defer alloc.free(cut_prompt);
            const session = alloc.dupe(u8, root.session) catch return;
            defer alloc.free(session);
            const cwd = alloc.dupe(u8, root.cwd) catch return;
            defer alloc.free(cwd);
            const sends = root.sends;
            const turn_ends = root.turn_ends;
            self.ensureRunning(alloc, .{ .agent = name, .prompt = "", .cwd = cwd, .session = session }) catch |err| {
                debug_trace.logf("superagent", "dead root not started again agent={s} err={s}", .{ name, @errorName(err) });
                return;
            };
            const started = self.roots.get(name) orelse return;
            started.revived = true;
            started.sends = sends;
            started.turn_ends = turn_ends;
            if (lost_job_wait) {
                const text = runtime.jobResultPrompt(alloc, "fx lost this root while it waited for the job, so the job's result was not read. Check the job yourself.") catch return;
                defer alloc.free(text);
                self.send(started, text, "runtime") catch |err| self.handToOwner(started, "", @errorName(err));
                return;
            }
            if (turn_was_open and cut_prompt.len > 0) {
                self.runAgain(.{ .agent = name, .cwd = cwd, .session = session, .prompt = cut_prompt, .in_flight = true }) catch |err| {
                    debug_trace.logf("superagent", "dead root's turn not sent again agent={s} err={s}", .{ name, @errorName(err) });
                };
                return;
            }
            self.sendQueuedItem(started);
        }

        fn carry(self: *Self, root: *Root, summary: []const u8) void {
            const alloc = self.app.alloc;
            const line_end = std.mem.findScalar(u8, summary, '\n') orelse summary.len;
            const owned = alloc.dupe(u8, summary[0..@min(line_end, 400)]) catch return;
            root.carried.append(alloc, owned) catch alloc.free(owned);
        }

        fn takeCarried(self: *Self, root: *Root, final: []const u8) ?[]u8 {
            const alloc = self.app.alloc;
            if (root.carried.items.len == 0) return null;
            defer {
                for (root.carried.items) |line| alloc.free(line);
                root.carried.clearRetainingCapacity();
            }
            return command.renderCarried(alloc, root.carried.items, final) catch null;
        }

        fn handToOwner(self: *Self, root: *Root, final: []const u8, failure: []const u8) void {
            const alloc = self.app.alloc;
            const alive = rootAlive(root);
            const body = self.takeCarried(root, final);
            defer if (body) |text| alloc.free(text);
            const event = command.renderNeedsOwner(alloc, .{
                .agent = root.name,
                .cwd = root.cwd,
                .status = if (alive) .idle else .stopped,
                .busy = false,
                .alive = alive,
                .prompt_id = root.prompt_id,
                .session = root.session,
            }, root.queue.items.len, failure, body orelse final) catch return;
            defer alloc.free(event);
            self.app.postAgentMessage(&self.app.main_agent, event, .child, .report) catch {};
            root.open_steps = 0;
            root.blocked_steps = 0;
        }

        fn liveTaskCount(alloc: Allocator, root: *Root) usize {
            if (comptime !agents.hasAgentField(App, "managed_executions")) return 0;
            const live = root.child.agent.managed_executions.liveTaskSummaries(alloc) catch return 0;
            defer managed_execution.freeLiveTaskSummaries(alloc, live);
            return live.len;
        }

        fn liveNamedPid(alloc: Allocator, report: runtime.Report) ?i32 {
            if (comptime !ledger_supported) return null;
            const named = runtime.jobPidIn(report.line);
            const is_alive = if (named) |pid| process_tree.liveProcessStamp(alloc, pid) != null else false;
            return switch (host_checks.jobProcess(named, @intCast(std.c.getpid()), is_alive)) {
                .wait_on_it => named,
                .own_process, .not_a_process => null,
            };
        }

        fn takeJobNotices(self: *Self, root: *Root) void {
            if (comptime !agents.hasAgentField(App, "managed_executions")) return;
            const alloc = self.app.alloc;
            const notices = root.child.agent.managed_executions.takeUnclaimedNotices(alloc) catch return;
            defer alloc.free(notices);
            for (notices) |notice| root.job_notes.append(alloc, notice) catch alloc.free(notice);
        }

        fn beginJobWait(self: *Self, root: *Root, running_tasks: usize, named_pid: ?i32) void {
            const wait_ms = jobWaitMs();
            if (!advance(root, .job_wait_began)) return;
            var wait: JobWait = .{
                .deadline_ms = io_mod.milliTimestamp() + @as(i64, @intCast(wait_ms)),
                .tasks = running_tasks,
            };
            if (named_pid) |pid| wait.pid_slot = self.spawnPidWait(pid, wait_ms);
            root.job_wait = wait;
            if (comptime agents.hasAgentField(App, "managed_executions")) {
                if (running_tasks > 0) {
                    root.child.agent.managed_executions.setNoticeSink(.{ .context = self, .owner = root, .post_fn = postJobNotice });
                    self.takeJobNotices(root);
                    if (root.job_notes.items.len > 0) self.job_news.store(true, .release);
                }
            }
            var detail_buf: [96]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buf, "tasks={d} pid={d} timeout_ms={d}", .{ running_tasks, named_pid orelse 0, wait_ms }) catch "";
            self.journalEntry(root, .wait, "runtime", @tagName(runtime.Decision.wait_for_job), "", detail);
        }

        fn jobWaitMs() u64 {
            return runtime.jobWaitMs(managed_contract.taskSettings().root_job_wait_ms);
        }

        fn spawnPidWait(self: *Self, pid: i32, wait_ms: u64) ?*PidSlot {
            if (comptime builtin.single_threaded) return null;
            const slot = std.heap.page_allocator.create(PidSlot) catch return null;
            slot.* = .{ .pid = pid, .timeout_ms = wait_ms, .news = &self.job_news };
            const thread = std.Thread.spawn(.{}, PidSlot.run, .{slot}) catch {
                std.heap.page_allocator.destroy(slot);
                return null;
            };
            thread.detach();
            return slot;
        }

        fn postJobNotice(raw: ?*anyopaque, owner: ?*anyopaque, text: []const u8) bool {
            const self: *Self = @ptrCast(@alignCast(raw.?));
            const root: *Root = @ptrCast(@alignCast(owner.?));
            const owned = self.app.alloc.dupe(u8, text) catch return false;
            self.job_lock.lockUncancelable(io_mod.getIo());
            defer self.job_lock.unlock(io_mod.getIo());
            self.job_mail.append(self.app.alloc, .{ .root = root, .text = owned }) catch {
                self.app.alloc.free(owned);
                return false;
            };
            self.job_news.store(true, .release);
            return true;
        }

        fn collectJobMail(self: *Self) void {
            const alloc = self.app.alloc;
            self.job_lock.lockUncancelable(io_mod.getIo());
            var mail = self.job_mail;
            self.job_mail = .empty;
            self.job_lock.unlock(io_mod.getIo());
            defer mail.deinit(alloc);
            for (mail.items) |note| {
                if (!self.ownsRoot(note.root)) {
                    alloc.free(note.text);
                    continue;
                }
                note.root.job_notes.append(alloc, note.text) catch alloc.free(note.text);
            }
        }

        fn ownsRoot(self: *Self, candidate: *Root) bool {
            var iterator = self.roots.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.* == candidate) return true;
            }
            return false;
        }

        fn settleJobWaits(self: *Self) void {
            const news = self.job_news.swap(false, .acq_rel);
            if (news) self.collectJobMail();
            const now_ms = io_mod.milliTimestamp();
            var iterator = self.roots.iterator();
            while (iterator.next()) |entry| {
                const root = entry.value_ptr.*;
                const wait = root.job_wait orelse continue;
                const timed_out = now_ms >= wait.deadline_ms;
                if (!news and !timed_out) continue;
                if (busyWorker(&root.child.agent.worker)) continue;
                const pid_done = if (wait.pid_slot) |slot| slot.state.load(.acquire) == .done else true;
                const tasks_done = wait.tasks == 0 or liveTaskCount(self.app.alloc, root) == 0;
                if (!timed_out and !(pid_done and tasks_done)) continue;
                var pid_note_buf: [96]u8 = undefined;
                const pid_note = if (wait.pid_slot) |slot|
                    std.fmt.bufPrint(&pid_note_buf, "process {d} {s}", .{ slot.pid, runtime.pidWaitPhrase(if (pid_done) slot.outcome else .still_running) }) catch ""
                else
                    "";
                self.endJobWait(root);
                self.sendJobResult(root, pid_note);
                self.saveLedger();
            }
        }

        fn endJobWait(self: *Self, root: *Root) void {
            _ = self;
            const wait = root.job_wait orelse return;
            if (root.phase == .waiting_job) _ = advance(root, .job_wait_settled);
            if (wait.pid_slot) |slot| slot.release();
            if (comptime agents.hasAgentField(App, "managed_executions")) {
                if (wait.tasks > 0 and !root.child_gone) root.child.agent.managed_executions.setNoticeSink(null);
            }
            root.job_wait = null;
        }

        fn sendJobResult(self: *Self, root: *Root, pid_note: []const u8) void {
            const alloc = self.app.alloc;
            var result: std.ArrayList(u8) = .empty;
            defer result.deinit(alloc);
            for (root.job_notes.items) |note| {
                result.appendSlice(alloc, note) catch {};
                result.append(alloc, '\n') catch {};
                alloc.free(note);
            }
            root.job_notes.clearRetainingCapacity();
            result.appendSlice(alloc, pid_note) catch {};
            const still_running = liveTaskCount(alloc, root);
            if (still_running > 0) result.print(alloc, "\n{d} task(s) were still running when the wait of {d} ms ended; read them with TaskOutput.", .{ still_running, jobWaitMs() }) catch {};
            const text = runtime.jobResultPrompt(alloc, std.mem.trim(u8, result.items, "\n")) catch return;
            defer alloc.free(text);
            self.send(root, text, "runtime") catch |err| self.handToOwner(root, "", @errorName(err));
        }

        fn laterEndFor(later: []const PendingEnd, agent: *agents.Agent) bool {
            for (later) |item| {
                if (item.agent == agent and !item.carriesNoReply()) return true;
            }
            return false;
        }

        fn postTurnEnded(self: *Self, root: *Root, end: runtime.TurnEnd, text: []const u8) void {
            const alloc = self.app.alloc;
            const alive = rootAlive(root);
            const snapshot: runtime.Snapshot = .{
                .agent = root.name,
                .cwd = root.cwd,
                .status = if (!alive) .stopped else switch (end) {
                    .failed => .failed,
                    .blocked => .blocked,
                    .interrupted, .paused => .idle,
                },
                .busy = end == .blocked,
                .alive = alive,
                .prompt_id = root.prompt_id,
                .session = root.session,
            };
            const event = command.renderTurnEnded(alloc, snapshot, end, text) catch return;
            defer alloc.free(event);
            self.app.postAgentMessage(&self.app.main_agent, event, .child, .report) catch {};
            self.saveLedger();
        }

        fn rootFor(self: *Self, agent: *agents.Agent) ?*Root {
            var iterator = self.roots.iterator();
            while (iterator.next()) |entry| {
                if (&entry.value_ptr.*.child.agent == agent) return entry.value_ptr.*;
            }
            return null;
        }

        fn postTurnEnd(self: *Self, root: *Root, final_response: []const u8) void {
            const alloc = self.app.alloc;
            const alive = rootAlive(root);
            const snapshot: runtime.Snapshot = .{
                .agent = root.name,
                .cwd = root.cwd,
                .status = if (alive) .idle else .stopped,
                .busy = false,
                .alive = alive,
                .prompt_id = root.prompt_id,
                .session = root.session,
            };
            const last = if (final_response.len > 0) final_response else finalResponse(root);
            const with_carried = self.takeCarried(root, last);
            defer if (with_carried) |body| alloc.free(body);
            const final = with_carried orelse last;
            const text = command.renderTurnEvent(alloc, snapshot, final) catch return;
            defer alloc.free(text);
            self.app.postAgentMessage(&self.app.main_agent, text, .child, .report) catch {};
            self.saveLedger();
        }

        fn finalResponse(root: *Root) []const u8 {
            const history = root.child.agent.session.agent.history.items;
            var index = history.len;
            while (index > 0) {
                index -= 1;
                switch (history[index]) {
                    .assistant => |turn| return turn.assistant,
                    else => {},
                }
            }
            return "";
        }

        fn announceGone(self: *Self, alloc: Allocator, name: []const u8) void {
            const text = command.renderGone(alloc, name) catch return;
            defer alloc.free(text);
            self.app.postAgentMessage(&self.app.main_agent, text, .child, .report) catch {};
        }

        fn list(raw: ?*anyopaque, alloc: Allocator) anyerror![]runtime.Snapshot {
            const self: *Self = @ptrCast(@alignCast(raw.?));
            var names: std.ArrayList([]const u8) = .empty;
            defer names.deinit(alloc);
            var it = self.roots.iterator();
            while (it.next()) |entry| try names.append(alloc, try alloc.dupe(u8, entry.key_ptr.*));
            defer for (names.items) |name| alloc.free(name);
            var out: std.ArrayList(runtime.Snapshot) = .empty;
            errdefer {
                for (out.items) |item| runtime.freeSnapshot(alloc, item);
                out.deinit(alloc);
            }
            for (names.items) |name| try out.append(alloc, try Self.status(raw, alloc, name));
            return out.toOwnedSlice(alloc);
        }

        fn stop(raw: ?*anyopaque, alloc: Allocator, agent_name: []const u8) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(raw.?));
            self.state_lock.lockUncancelable(io_mod.getIo());
            defer self.state_lock.unlock(io_mod.getIo());
            const root = self.roots.get(agent_name) orelse return error.PeerNotFound;
            self.endJobWait(root);
            _ = advance(root, .stop_asked);
            if (!root.child_gone) root.child.agent.worker.requestStop();
            self.journalEntry(root, .stop, "owner", "", "", "");
            self.announceGone(alloc, root.name);
            self.saveLedger();
        }

        fn projects(raw: ?*anyopaque, alloc: Allocator) anyerror![][]const u8 {
            const self: *Self = @ptrCast(@alignCast(raw.?));
            const parent = std.Io.Dir.path.dirname(self.app.workspace_root) orelse self.app.workspace_root;
            var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), parent, .{ .iterate = true }) catch return alloc.alloc([]const u8, 0);
            defer dir.close(io_mod.getIo());
            var out: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (out.items) |name| alloc.free(name);
                out.deinit(alloc);
            }
            var iterator = dir.iterate();
            while (try iterator.next(io_mod.getIo())) |entry| {
                if (std.mem.startsWith(u8, entry.name, ".")) continue;
                const is_directory = switch (entry.kind) {
                    .directory => true,
                    .sym_link => if (dir.openDir(io_mod.getIo(), entry.name, .{})) |target| blk: {
                        var opened = target;
                        opened.close(io_mod.getIo());
                        break :blk true;
                    } else |_| false,
                    else => false,
                };
                if (!is_directory) continue;
                try out.append(alloc, try alloc.dupe(u8, entry.name));
            }
            std.mem.sort([]const u8, out.items, {}, struct {
                fn less(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.less);
            return out.toOwnedSlice(alloc);
        }

        fn removeRoot(self: *Self, alloc: Allocator, name: []const u8) void {
            if (self.roots.fetchRemove(name)) |entry| {
                const root = entry.value;
                self.endJobWait(root);
                if (!root.child_gone) root.child.agent.worker.requestStop();
                if (machine.isLive(root.phase)) self.announceGone(alloc, name);
                alloc.free(entry.key);
                self.deinitRoot(alloc, root);
            }
        }

        fn deinitRoot(_: *Self, alloc: Allocator, root: *Root) void {
            alloc.free(root.name);
            alloc.free(root.cwd);
            alloc.free(root.session);
            if (root.prompt_id.len > 0) alloc.free(root.prompt_id);
            if (root.last_prompt.len > 0) alloc.free(root.last_prompt);
            inline for (.{ &root.queue, &root.carried, &root.job_notes }) |owned_lines| {
                for (owned_lines.items) |item| alloc.free(item);
                owned_lines.deinit(alloc);
            }
            alloc.destroy(root);
        }

        fn setOwned(target: *[]const u8, alloc: Allocator, value: []const u8) void {
            if (target.len > 0) alloc.free(target.*);
            target.* = alloc.dupe(u8, value) catch value;
        }
    };
}

pub fn unbindFromApp() void {
    runtime.unbind();
}
