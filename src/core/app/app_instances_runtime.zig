const std = @import("std");
const agents = @import("../agents/agents.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const app_agents_runtime = @import("app_agents_runtime.zig");
const app_process_runtime = @import("app_process_runtime.zig");
const app_profile_runtime = @import("app_profile_runtime.zig");
const host_record = @import("host_record.zig");
const profiles = @import("../profiles/profiles.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const config_runtime = @import("../config/config_runtime.zig");
const model_provider = @import("../config/model_provider.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Seed = struct {
    captured: bool = false,
    provider: model_provider.ProviderId = .gateway,
    configured_model: []u8 = &.{},
    model_source: config_runtime.ModelSource = .compiled_default,
    selected_model: []u8 = &.{},
    effort: types.ReasoningEffort = .auto,
    fast_mode: bool = false,
    fast_mode_model_bound: bool = false,
    configured_ultrafast_mode: bool = false,
    ultrafast_process_override: ?bool = null,
    effort_process_override: ?types.ReasoningEffort = null,
    fast_process_override: ?bool = null,
    provider_process_override: ?model_provider.ProviderId = null,
    permission_mode: types.PermissionMode = .ask,
    turn_settings: worker_runtime.AgentTurnSettings = .{},
    provider_order: [][]u8 = &.{},
    provider_strict: bool = false,
    agent_effort: types.ReasoningEffort = .auto,
    profile_name: ?[]u8 = null,

    pub fn deinit(self: *Seed, alloc: Allocator) void {
        alloc.free(self.configured_model);
        alloc.free(self.selected_model);
        for (self.provider_order) |name| alloc.free(name);
        alloc.free(self.provider_order);
        if (self.profile_name) |name| alloc.free(name);
        self.* = .{};
    }

    pub fn capturePreferences(
        self: *Seed,
        alloc: Allocator,
        provider: model_provider.ProviderId,
        configured_model: []const u8,
        model_source: config_runtime.ModelSource,
        selected_model: []const u8,
        effort: types.ReasoningEffort,
        fast_mode: bool,
        fast_mode_model_bound: bool,
        configured_ultrafast_mode: bool,
        ultrafast_process_override: ?bool,
        effort_process_override: ?types.ReasoningEffort,
        fast_process_override: ?bool,
        provider_process_override: ?model_provider.ProviderId,
    ) !void {
        const configured = try alloc.dupe(u8, configured_model);
        errdefer alloc.free(configured);
        const selected = try alloc.dupe(u8, selected_model);
        alloc.free(self.configured_model);
        alloc.free(self.selected_model);
        self.configured_model = configured;
        self.selected_model = selected;
        self.provider = provider;
        self.model_source = model_source;
        self.effort = effort;
        self.fast_mode = fast_mode;
        self.fast_mode_model_bound = fast_mode_model_bound;
        self.configured_ultrafast_mode = configured_ultrafast_mode;
        self.ultrafast_process_override = ultrafast_process_override;
        self.effort_process_override = effort_process_override;
        self.fast_process_override = fast_process_override;
        self.provider_process_override = provider_process_override;
    }

    pub fn captureAgent(self: *Seed, alloc: Allocator, agent: *const agents.Agent, mode: types.PermissionMode) !void {
        const order = try alloc.alloc([]u8, agent.worker.agent_turn_settings.provider_order.len);
        var filled: usize = 0;
        errdefer {
            for (order[0..filled]) |name| alloc.free(name);
            alloc.free(order);
        }
        for (agent.worker.agent_turn_settings.provider_order, 0..) |name, index| {
            order[index] = try alloc.dupe(u8, name);
            filled += 1;
        }
        for (self.provider_order) |name| alloc.free(name);
        alloc.free(self.provider_order);
        self.provider_order = order;
        self.provider_strict = agent.worker.agent_turn_settings.provider_strict;
        self.turn_settings = agent.worker.agent_turn_settings;
        self.turn_settings.provider_order = &.{};
        self.agent_effort = agent.effort;
        self.permission_mode = mode;
        self.captured = true;
    }

    pub fn captureProfile(self: *Seed, alloc: Allocator, name: ?[]const u8) !void {
        const owned = if (name) |value| try alloc.dupe(u8, value) else null;
        if (self.profile_name) |old| alloc.free(old);
        self.profile_name = owned;
    }
};

const Written = struct {
    id: []u8,
    profile: []u8,
};

pub const State = struct {
    seed: Seed = .{},
    launched: usize = 0,
    startup_count: usize = 1,
    label_buf: [192]u8 = undefined,
    first_open: bool = true,
    exit_handoff: ?app_session_runtime.ResumeHandoff = null,
    group_id: [host_record.group_id_len]u8 = undefined,
    has_group: bool = false,
    written: std.ArrayList(Written) = .empty,
    restore_pending: bool = false,
    agents_menu: app_agents_runtime.AgentsMenu = .{},
    restore_on_pick: bool = false,

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.seed.deinit(alloc);
        if (self.exit_handoff) |*handoff| handoff.deinit(alloc);
        self.exit_handoff = null;
        self.clearWritten(alloc);
        self.written.deinit(alloc);
        self.agents_menu.deinit(alloc);
    }

    fn clearWritten(self: *State, alloc: Allocator) void {
        for (self.written.items) |entry| {
            alloc.free(entry.id);
            alloc.free(entry.profile);
        }
        self.written.clearRetainingCapacity();
    }

    pub fn takeExitHandoff(self: *State) ?app_session_runtime.ResumeHandoff {
        const handoff = self.exit_handoff;
        self.exit_handoff = null;
        return handoff;
    }
};

pub fn testHookCount() usize {
    const raw = io_mod.getenv("FX_TEST_INSTANCES") orelse return 1;
    const count = std.fmt.parseUnsigned(usize, std.mem.trim(u8, raw, " \t\r\n"), 10) catch return 1;
    return @max(count, 1);
}

fn failureText(err: anyerror) []const u8 {
    return switch (err) {
        error.SessionNotFound => "its saved session is gone",
        error.SessionBusy => "another fx is using that session; close it there and try again",
        error.SessionStoreUnavailable, error.SessionPersistenceUnavailable => "fx can't open its saved sessions right now",
        error.OutOfMemory => "fx ran out of memory",
        error.SystemResources,
        error.ThreadQuotaExceeded,
        error.LockedMemoryLimitExceeded,
        => "the system won't start another thread; close an instance and try again",
        else => "something unexpected went wrong; run fx with FX_TRACE=1 to log why",
    };
}

test "instance failures read as sentences, not error names" {
    try std.testing.expectEqualStrings("its saved session is gone", failureText(error.SessionNotFound));
    try std.testing.expect(std.mem.find(u8, failureText(error.SessionBusy), "another fx") != null);
    try std.testing.expect(std.mem.find(u8, failureText(error.Unexpected), "FX_TRACE=1") != null);
    try std.testing.expect(std.mem.find(u8, failureText(error.ThreadQuotaExceeded), "Thread") == null);
}

pub fn Runtime(comptime App: type) type {
    return struct {
        const AgentsRuntime = app_agents_runtime.Runtime(App);
        const SessionRuntime = app_session_runtime.Runtime(App);
        const ChildAgent = app_agents_runtime.ChildAgent;

        pub fn launch(app: *App, profile_name: ?[]const u8) !*ChildAgent {
            return launchWith(app, profile_name, null);
        }

        pub fn launchResumed(app: *App, session_id: []const u8, profile_name: ?[]const u8) !*ChildAgent {
            return launchWith(app, profile_name, session_id);
        }

        fn resumeInContext(session_id: []const u8, app: *App, agent: *agents.Agent) anyerror!void {
            try SessionRuntime.resumeSessionById(app, agent, session_id);
        }

        fn launchWith(app: *App, profile_name: ?[]const u8, resume_id: ?[]const u8) !*ChildAgent {
            const seed = &app.instances.seed;
            if (!seed.captured) return error.HostNotStarted;
            const child = try AgentsRuntime.addInstance(app);
            errdefer AgentsRuntime.dropHosted(app, child);
            const agent = &child.agent;
            app_session_runtime.Persistence.initInto(&agent.session_persistence);
            const name = profile_name orelse seed.profile_name;
            if (name) |value| try app.applyInstanceProfile(agent, value);
            try SessionRuntime.configureStartupPreferences(
                app,
                agent,
                seed.provider,
                seed.configured_model,
                seed.model_source,
                seed.selected_model,
                seed.effort,
                seed.fast_mode,
                seed.fast_mode_model_bound,
                seed.configured_ultrafast_mode,
                seed.ultrafast_process_override,
                seed.effort_process_override,
                seed.fast_process_override,
                seed.provider_process_override,
            );
            agent.worker.agent_turn_settings = seed.turn_settings;
            agent.worker.agent_turn_settings.provider_order = &.{};
            try agent.worker.setProviderRouting(std.heap.c_allocator, constNames(seed.provider_order), seed.provider_strict);

            child.screen.fast_mode = agent.worker.agent_turn_settings.fast_mode;

            agent.effort = if (seed.effort_process_override) |effort|
                effort
            else if (name != null)
                agent.profile.profile.effort orelse seed.agent_effort
            else
                seed.agent_effort;
            agent.worker.agent_turn_settings.effort = agent.effort;
            agent.permission_mode = app.instanceProfileMode(agent, seed.permission_mode);
            try SessionRuntime.initializePersistence(app, agent, resume_id != null);
            if (resume_id) |id| {
                try AgentsRuntime.visit(app, child, id, resumeInContext);
                child.view_built = true;
            } else {
                try SessionRuntime.beginInstanceSession(app, agent);
                SessionRuntime.enableSessionStores(app, agent);

                try SessionRuntime.applyProcessModelOverride(app, agent);
            }
            try AgentsRuntime.nameInstance(app, child, SessionRuntime.activeSessionId(agent));
            child.session_attached = true;
            try app_process_runtime.Runtime(App).startAgentWorkerThread(app, agent);

            if (resume_id != null) SessionRuntime.startPendingResume(app, agent);
            app.instances.launched += 1;
            debug_trace.eventf("host", "instance_launched", .{}, "agent={s} profile={s} instances={d} resumed={s}", .{
                child.id,
                name orelse "default",
                app.instances.launched,
                if (resume_id != null) "true" else "false",
            });
            return child;
        }

        pub fn syncRecord(app: *App) void {
            const state = &app.instances;
            var count: usize = 0;
            var same = true;
            var profiled = false;
            if (AgentsRuntime.firstOpen(app)) noteMember(state, &app.main_agent, &count, &same, &profiled);
            for (app.child_agents.items) |child| {
                if (child.agent.role == .instance) noteMember(state, &child.agent, &count, &same, &profiled);
            }
            if (same and count == state.written.items.len) return;
            if (count < 2 and !profiled) {
                state.clearWritten(app.alloc);
                if (state.has_group) {
                    withHostsDir(app, removeRecord);
                    state.has_group = false;
                }
                return;
            }
            state.clearWritten(app.alloc);
            if (AgentsRuntime.firstOpen(app)) appendWritten(app, &app.main_agent) catch |err| return dropRecordUpdate(app, err);
            for (app.child_agents.items) |child| {
                if (child.agent.role != .instance) continue;
                appendWritten(app, &child.agent) catch |err| return dropRecordUpdate(app, err);
            }
            if (!state.has_group) {
                state.group_id = host_record.newGroupId();
                state.has_group = true;
                withHostsDir(app, pruneRecords);
            }
            withHostsDir(app, writeRecord);
        }

        fn noteMember(state: *const State, agent: *agents.Agent, count: *usize, same: *bool, profiled: *bool) void {
            const id = SessionRuntime.savedSessionId(agent) orelse return;
            const profile = profileName(agent);
            same.* = same.* and matchesWritten(state, count.*, id, profile);
            profiled.* = profiled.* or !std.mem.eql(u8, profile, profiles.main_name);
            count.* += 1;
        }

        fn dropRecordUpdate(app: *App, err: anyerror) void {
            app.instances.clearWritten(app.alloc);
            debug_trace.logf("host", "host_record_update_dropped err={s}", .{@errorName(err)});
        }

        fn profileName(agent: *const agents.Agent) []const u8 {
            return agent.profile.profile.name;
        }

        fn matchesWritten(state: *const State, index: usize, id: []const u8, profile: []const u8) bool {
            if (index >= state.written.items.len) return false;
            const entry = state.written.items[index];
            return std.mem.eql(u8, entry.id, id) and std.mem.eql(u8, entry.profile, profile);
        }

        fn appendWritten(app: *App, agent: *agents.Agent) !void {
            const saved = SessionRuntime.savedSessionId(agent) orelse return;
            const id = try app.alloc.dupe(u8, saved);
            errdefer app.alloc.free(id);
            const profile = try app.alloc.dupe(u8, profileName(agent));
            errdefer app.alloc.free(profile);
            try app.instances.written.append(app.alloc, .{ .id = id, .profile = profile });
        }

        fn withHostsDir(app: *App, comptime body: fn (*App, []const u8) anyerror!void) void {
            const home = io_mod.homeDir() orelse {
                debug_trace.logf("host", "host_record_skipped reason=no_home", .{});
                return;
            };
            const dir = profile_paths.hostsDir(app.alloc, home) catch |err| {
                debug_trace.logf("host", "host_record_skipped reason=hosts_dir err={s}", .{@errorName(err)});
                return;
            };
            defer app.alloc.free(dir);
            body(app, dir) catch |err| {
                debug_trace.logf("host", "host_record_failed err={s}", .{@errorName(err)});
            };
        }

        fn writeRecord(app: *App, dir: []const u8) anyerror!void {
            const state = &app.instances;
            const sessions = try app.alloc.alloc([]const u8, state.written.items.len);
            defer app.alloc.free(sessions);
            const names = try app.alloc.alloc(?[]const u8, state.written.items.len);
            defer app.alloc.free(names);
            for (state.written.items, sessions, names) |entry, *id, *name| {
                id.* = entry.id;
                name.* = entry.profile;
            }
            try host_record.write(app.alloc, dir, .{
                .group_id = &state.group_id,
                .updated_ms = io_mod.milliTimestamp(),
                .sessions = sessions,
                .profiles = names,
            });
            debug_trace.eventf("host", "host_record_written", .{}, "group={s} sessions={d}", .{ &state.group_id, state.written.items.len });
        }

        fn removeRecord(app: *App, dir: []const u8) anyerror!void {
            try host_record.remove(app.alloc, dir, &app.instances.group_id);
            debug_trace.eventf("host", "host_record_removed", .{}, "group={s}", .{&app.instances.group_id});
        }

        fn pruneRecords(app: *App, dir: []const u8) anyerror!void {
            var loaded = try host_record.loadAll(app.alloc, dir);
            defer loaded.deinit();
            _ = try host_record.pruneOldest(app.alloc, dir, loaded.records, &app.instances.group_id);
        }

        pub fn restoreGroup(app: *App) void {
            const resumed = SessionRuntime.activeSessionId(&app.main_agent) orelse return;
            const home = io_mod.homeDir() orelse {
                debug_trace.logf("host", "host_restore_skipped reason=no_home", .{});
                return;
            };
            const dir = profile_paths.hostsDir(app.alloc, home) catch |err| {
                debug_trace.logf("host", "host_restore_failed err={s}", .{@errorName(err)});
                return;
            };
            defer app.alloc.free(dir);
            var loaded = host_record.loadAll(app.alloc, dir) catch |err| {
                debug_trace.logf("host", "host_restore_failed err={s}", .{@errorName(err)});
                return;
            };
            defer loaded.deinit();
            const chosen = host_record.chooseRestore(app.alloc, loaded.records, resumed) catch |err| {
                debug_trace.logf("host", "host_restore_failed session={s} err={s}", .{ resumed, @errorName(err) });
                return;
            };
            _ = host_record.pruneOldest(app.alloc, dir, loaded.records, if (chosen) |value| value.group_id else null) catch |err| {
                debug_trace.logf("host", "host_record_prune_failed err={s}", .{@errorName(err)});
            };
            var restore = chosen orelse return;
            defer restore.deinit(app.alloc);
            if (restore.group_id.len == host_record.group_id_len) {
                @memcpy(&app.instances.group_id, restore.group_id);
                app.instances.has_group = true;
            }
            debug_trace.eventf("host", "host_restore", .{}, "group={s} sessions={d} profile={s}", .{
                restore.group_id,
                restore.others.len,
                restore.profile orelse "none",
            });
            if (restore.profile) |name| if (app.instances.seed.profile_name == null) restoreFirstProfile(app, name);
            for (restore.others) |member| {
                _ = launchResumed(app, member.id, member.profile) catch |err| {
                    debug_trace.logf("host", "host_restore_skipped session={s} err={s}", .{ member.id, @errorName(err) });
                    if (err == error.SessionNotFound) continue;
                    var prefix_buf: [192]u8 = undefined;
                    const prefix = std.mem.print(&prefix_buf, "Couldn't bring back session {s} with this one", .{member.id}) catch "Couldn't bring back a session with this one";
                    writeFailure(app, .neutral, prefix, member.profile, err);
                    continue;
                };
            }
        }

        pub fn launchAndShow(app: *App, profile_name: ?[]const u8) !void {
            const child = launch(app, profile_name) catch |err| {
                debug_trace.logf("host", "instance launch failed profile={s} err={s}", .{ profile_name orelse "default", @errorName(err) });
                writeFailure(app, .@"error", "Couldn't start another fx instance", profile_name, err);
                return;
            };
            try AgentsRuntime.show(app, child);
        }

        pub fn launchStartupInstances(app: *App) void {
            if (app.instances.restore_pending) {
                app.instances.restore_pending = false;
                restoreGroup(app);
            }
            while (app.instances.launched < app.instances.startup_count) {
                _ = launch(app, null) catch |err| {
                    debug_trace.logf("host", "startup instance launch failed index={d} err={s}", .{ app.instances.launched, @errorName(err) });
                    var prefix_buf: [128]u8 = undefined;
                    const prefix = std.mem.print(&prefix_buf, "Started {d} of {d} fx instances", .{
                        AgentsRuntime.openInstanceCount(app),
                        app.instances.startup_count + 1,
                    }) catch "Couldn't start every fx instance";
                    writeFailure(app, .@"error", prefix, null, err);
                    return;
                };
            }
        }

        pub fn closeOnScreen(app: *App) !void {
            if (app.agent_on_screen) |child| if (child.agent.role == .subagent) {
                try app.writeDomainNotice(.{ .topic = "instances", .tone = .neutral, .body = "/close closes an fx instance. This screen is a subagent's." }, true);
                return;
            };
            if (AgentsRuntime.openInstanceCount(app) <= 1) {
                SessionRuntime.requestResumeHandoff(agents.screenAgentOf(app));
                app.should_exit = true;
                return;
            }
            if (app.agent_on_screen) |child| {
                try AgentsRuntime.closeInstance(app, child);
                return;
            }
            try AgentsRuntime.closeFirstInstance(app);
        }

        fn writeFailure(app: *App, tone: types.NoticeTone, prefix: []const u8, profile_name: ?[]const u8, err: anyerror) void {
            const reason = if (profile_name) |name| app_profile_runtime.failureReason(app.alloc, name) catch null else null;
            defer if (reason) |text| app.alloc.free(text);
            const body = if (reason) |text|
                app.alloc.print("{s}: {s}", .{ prefix, text }) catch return
            else
                app.alloc.print("{s}: {s}.", .{ prefix, failureText(err) }) catch return;
            defer app.alloc.free(body);
            app.writeDomainNotice(.{ .topic = "instances", .tone = tone, .body = body }, true) catch |write_err| {
                debug_trace.logf("host", "instance_notice_dropped err={s}", .{@errorName(write_err)});
            };
        }

        fn restoreFirstProfile(app: *App, name: []const u8) void {
            if (std.mem.eql(u8, name, profileName(&app.main_agent))) return;
            app.applyFirstInstanceProfile(name) catch |err| {
                debug_trace.logf("host", "host_restore_profile_failed name={s} err={s}", .{ name, @errorName(err) });
                const reason = app_profile_runtime.failureReason(app.alloc, name) catch null;
                defer if (reason) |text| app.alloc.free(text);
                const body = if (reason) |text|
                    app.alloc.print("Couldn't use profile '{s}', which this session ran in: {s}", .{ name, text }) catch return
                else
                    app.alloc.print("Couldn't use profile '{s}', which this session ran in: {s}.", .{ name, failureText(err) }) catch return;
                defer app.alloc.free(body);
                app.writeDomainNotice(.{ .topic = "instances", .tone = .@"error", .body = body }, true) catch {};
            };
        }

        fn constNames(names: []const []u8) []const []const u8 {
            return @ptrCast(names);
        }
    };
}
