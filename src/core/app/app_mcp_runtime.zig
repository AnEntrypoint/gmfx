const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const mcp_access = @import("../mcp/access_policy.zig");
const mcp_contract = @import("../mcp/mcp_contract.zig");
const elicitation = @import("../mcp/elicitation.zig");
const mcp_model_catalog = @import("../mcp/model_catalog.zig");
const selected_schema = @import("../mcp/selected_schema.zig");
const workspace_config = @import("../mcp/workspace_config.zig");
const workspace_trust = @import("../mcp/workspace_trust.zig");
const workspace_trust_prompt = @import("workspace_trust_prompt.zig");
const mcp_host = @import("../mcp_host/host.zig");
const mcp_verbs = @import("../mcp_host/verbs.zig");
const mcp_menu = @import("../mcp_host/menu.zig");
const config_file = @import("../mcp_host/config_file.zig");
const config_runtime = @import("../config/config_runtime.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const editor_state = @import("../input/editor_state.zig");
const command_lex = @import("../shell_command/command_lex.zig");
const mod_registry = @import("../mods/registry.zig");
const context_limits = @import("../config/context_limits.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const tool_mcp_runtime = @import("../tooling/tool_mcp_runtime.zig");
const mcp_resources = @import("../../mcp/protocol/resources.zig");
const types = @import("../shared/types.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

fn typedLoginServer(arena: Allocator, args: []const []const u8) Allocator.Error!?[]const u8 {
    return switch (try mcp_verbs.parse(arena, .shell, args)) {
        .command => |command| switch (command) {
            .login => |login| login.name,
            else => null,
        },
        .usage, .moved => null,
    };
}

fn configStamp(alloc: Allocator, home: ?[]const u8, workspace_root: []const u8) u64 {
    var h: std.hash.Wyhash = .init(0);
    if (home) |dir| stampFile(alloc, &h, readProfileConfig(alloc, dir));
    stampFile(alloc, &h, workspace_config.readRootFile(alloc, workspace_root));
    stampFile(alloc, &h, workspace_config.readProjectFile(alloc, workspace_root));
    if (home) |dir| {
        if (config_runtime.loadProjectMcpChoicesFromHome(alloc, dir, workspace_root)) |loaded| {
            var load = loaded;
            defer load.deinit(alloc);
            h.update(&.{ 1, @intFromBool(load.choices.enable_all) });
            for ([_][]const []u8{ load.choices.approved, load.choices.rejected }) |names| {
                h.update(std.mem.asBytes(&names.len));
                for (names) |name| stampBytes(&h, name);
            }
        } else |err| stampError(&h, err);
        if (workspace_trust.gate(alloc, dir, workspace_root)) |state| {
            h.update(&.{ 3, @intFromBool(state.require_trust), @intFromBool(state.persisted) });
        } else |err| stampError(&h, err);
    }
    return h.final();
}

fn readProfileConfig(alloc: Allocator, home: []const u8) anyerror!?[]u8 {
    const path = try profile_paths.mcpConfigPath(alloc, home);
    defer alloc.free(path);
    return config_file.read(alloc, path);
}

fn stampFile(alloc: Allocator, h: *std.hash.Wyhash, read: anyerror!?[]u8) void {
    const text = read catch |err| return stampError(h, err);
    const bytes = text orelse return h.update(&.{0});
    defer alloc.free(bytes);
    h.update(&.{1});
    stampBytes(h, bytes);
}

fn stampBytes(h: *std.hash.Wyhash, bytes: []const u8) void {
    h.update(std.mem.asBytes(&bytes.len));
    h.update(bytes);
}

fn stampError(h: *std.hash.Wyhash, err: anyerror) void {
    h.update(&.{2});
    stampBytes(h, @errorName(err));
}

pub const TrustPrompt = struct {
    ctx: ?*anyopaque,
    choose: *const fn (ctx: ?*anyopaque, workspace_root: []const u8) anyerror!workspace_trust.PromptChoice,
};

pub fn startupTrustGate(
    alloc: Allocator,
    home: ?[]const u8,
    workspace_root: []const u8,
    env_trusted: bool,
    prompt: ?TrustPrompt,
) !workspace_trust.PromptOutcome {
    const dir = home orelse return .continue_session;
    const current = try workspace_trust.gate(alloc, dir, workspace_root);
    if (!workspace_trust.promptRequired(current, env_trusted)) return .continue_session;
    const surface = prompt orelse return .continue_session;
    const choice = try surface.choose(surface.ctx, workspace_root);
    return workspace_trust.applyPromptChoice(alloc, dir, workspace_root, choice, io_mod.milliTimestamp());
}

pub fn gateBeforeLoad(
    alloc: Allocator,
    home: ?[]const u8,
    workspace_root: []const u8,
    env_trusted: bool,
    prompt: ?TrustPrompt,
) !void {
    const outcome = try startupTrustGate(alloc, home, workspace_root, env_trusted, prompt);
    if (outcome == .exit_program) return error.WorkspaceTrustDeclined;
}

var process_trust_resolved: bool = false;

pub fn gateBeforeSession(
    alloc: Allocator,
    home: ?[]const u8,
    workspace_root: []const u8,
    env_trusted: bool,
    prompt: ?TrustPrompt,
) !void {
    if (process_trust_resolved) return;
    try gateBeforeLoad(alloc, home, workspace_root, env_trusted, prompt);
    process_trust_resolved = true;
}

pub fn trustEnvironmentSet() bool {
    const raw = io_mod.getenv("KIMI_CODE_TRUST_WORKSPACE") orelse return false;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    for ([_][]const u8{ "1", "true", "yes", "on" }) |truthy| {
        if (std.ascii.eqlIgnoreCase(value, truthy)) return true;
    }
    return false;
}

pub fn stdinPrompt() ?TrustPrompt {
    const zio = io_mod.getIo();
    const interactive = (std.Io.File.stdin().isTty(zio) catch false) and (std.Io.File.stdout().isTty(zio) catch false);
    return if (interactive) stdinTrustPrompt() else null;
}

fn hasProjectLayer(alloc: Allocator, workspace_root: []const u8) !bool {
    if (try workspace_config.readRootFile(alloc, workspace_root)) |bytes| {
        alloc.free(bytes);
        return true;
    }
    if (try workspace_config.readProjectFile(alloc, workspace_root)) |bytes| {
        alloc.free(bytes);
        return true;
    }
    return false;
}

pub fn untrustedProjectServersWarning(
    alloc: Allocator,
    home: ?[]const u8,
    workspace_root: []const u8,
    env_trusted: bool,
) ?[]u8 {
    return untrustedProjectServersWarningChecked(alloc, home, workspace_root, env_trusted) catch null;
}

fn untrustedProjectServersWarningChecked(
    alloc: Allocator,
    home: ?[]const u8,
    workspace_root: []const u8,
    env_trusted: bool,
) !?[]u8 {
    if (env_trusted) return null;
    const dir = home orelse return null;
    if (!try hasProjectLayer(alloc, workspace_root)) return null;
    const current = try workspace_trust.gate(alloc, dir, workspace_root);
    if (current.grantsAll()) return null;

    var choice_load = try config_runtime.loadProjectMcpChoicesFromHome(alloc, dir, workspace_root);
    defer choice_load.deinit(alloc);
    var environment = std.process.Environ.Map.init(alloc);
    defer environment.deinit();
    var workspace = try workspace_config.loadWithEnvironment(alloc, workspace_root, .workspace, choice_load.choices, &environment, dir);
    defer workspace.deinit(alloc);

    var names: std.Io.Writer.Allocating = .init(alloc);
    defer names.deinit();
    var skipped: usize = 0;
    for (workspace.configs.items) |config| {
        if (config.workspace_admission == .approved or config.workspace_admission == .rejected) continue;
        if (skipped > 0) try names.writer.writeAll(", ");
        try names.writer.print("{f}", .{text_utils.terminalSafe(config.name)});
        skipped += 1;
    }
    if (skipped == 0) return null;
    return try std.fmt.allocPrint(
        alloc,
        "Warning: this folder is not trusted; skipped {d} project-level MCP {s}: {s}.\n" ++
            "  Run `fx` here and choose \"Trust this folder\", or set KIMI_CODE_TRUST_WORKSPACE=1, to enable them.\n\n",
        .{ skipped, if (skipped == 1) "server" else "servers", names.written() },
    );
}

pub fn stdinTrustPrompt() TrustPrompt {
    return .{ .ctx = null, .choose = chooseOnStdin };
}

fn chooseOnStdin(_: ?*anyopaque, workspace_root: []const u8) anyerror!workspace_trust.PromptChoice {
    if (try workspace_trust_prompt.chooseWithKeys(workspace_root)) |choice| return choice;
    return chooseOnStdinLine(workspace_root);
}

fn chooseOnStdinLine(workspace_root: []const u8) anyerror!workspace_trust.PromptChoice {
    const stdout = std.Io.File.stdout();
    const zio = io_mod.getIo();
    try stdout.writeStreamingAll(zio, workspace_trust_prompt.title ++ "\n");
    try stdout.writeStreamingAll(zio, workspace_root);
    try stdout.writeStreamingAll(zio, "\n" ++ workspace_trust_prompt.remembered_notice ++ "\n" ++ workspace_trust_prompt.approvals_notice ++ "\n  Enter or t: " ++ workspace_trust_prompt.option_labels[0] ++ "\n  e: " ++ workspace_trust_prompt.option_labels[1] ++ "\n> ");
    var read_buf: [1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(zio, &read_buf);
    const line = reader.interface.takeDelimiter('\n') catch return .distrust;
    return parseTrustAnswer(line orelse return .distrust);
}

fn parseTrustAnswer(line: []const u8) workspace_trust.PromptChoice {
    const answer = std.mem.trim(u8, line, " \t\r");
    if (answer.len == 0) return .trust;
    for ([_][]const u8{ "t", "trust", "y", "yes" }) |accepted| {
        if (std.ascii.eqlIgnoreCase(answer, accepted)) return .trust;
    }
    return .distrust;
}

pub const State = struct {
    host: ?*mcp_host.Host = null,
    host_mutex: std.Io.Mutex = .init,
    host_load: ?mcp_host.LoadFn = null,
    host_questions: elicitation.Capabilities = .{},
    host_sink: ?*HostSink = null,
    host_completion: []const mod_registry.ArgumentCompletion = &.{},
    host_completion_arena: ?std.heap.ArenaAllocator = null,
    host_completion_at_ms: i64 = 0,
    host_reload_requested: std.atomic.Value(bool) = .init(false),
    host_config_stamp: ?u64 = null,
    host_menu: mcp_menu.State = .{},
    host_menu_rows: []const mcp_menu.Row = &.{},
    host_menu_notes: usize = 0,
    host_menu_arena: ?std.heap.ArenaAllocator = null,
    host_menu_at_ms: i64 = 0,
    host_menu_tools: mcp_menu.Tools = .loading,
    host_menu_sign_in: ?[]u8 = null,
    host_status_buf: [120]u8 = undefined,
    host_status_len: usize = 0,
    host_status_at_ms: i64 = 0,
    host_started_ms: i64 = 0,
    host_status_seen: ?mcp_menu.Seen = null,
    host_status_dismiss_requested: bool = false,
    host_menu_tools_arena: ?std.heap.ArenaAllocator = null,
    host_menu_load: usize = 0,
    host_menu_loaded: ?MenuLoadedAs = null,
    host_verbs: std.atomic.Value(usize) = .init(0),
    host_closing: std.atomic.Value(bool) = .init(false),
    process_exiting: std.atomic.Value(bool) = .init(false),
    model_catalog_baseline_lock: std.Io.Mutex = .init,
    model_catalog_baseline: ?[]mcp_model_catalog.BaselineEntry = null,

    pub fn loadHost(
        self: *State,
        load: mcp_host.LoadFn,
        alloc: Allocator,
        home: ?[]const u8,
        workspace_root: []const u8,
        registry: tool_dispatch.Registry,
        questions: elicitation.Capabilities,
    ) !void {
        self.host_load = load;
        self.host_questions = questions;
        if (self.host_sink == null) {
            const sink = try std.heap.c_allocator.create(HostSink);
            sink.* = .{};
            self.host_sink = sink;
        }

        self.host_config_stamp = configStamp(alloc, home, workspace_root);
        self.replaceHost(try load(alloc, workspace_root, registry, .{ .questions = questions, .notify = self.host_sink.?.notify(), .slash_commands = true }));
    }

    pub const RefreshCheck = enum {
        requested,
        files,
    };

    pub fn refreshHost(
        self: *State,
        alloc: Allocator,
        home: ?[]const u8,
        workspace_root: []const u8,
        registry: tool_dispatch.Registry,
        check: RefreshCheck,
    ) bool {
        if (self.host_load == null) return false;
        const requested = self.takeHostReload();
        if (!requested and check == .requested) return false;

        const stamp = configStamp(alloc, home, workspace_root);
        if (!requested) if (self.host_config_stamp) |last| if (last == stamp) return false;
        self.host_config_stamp = stamp;
        debug_trace.logf("mcp", "MCP config loaded again reason={s}", .{if (requested) "mcp_command" else "config_files_changed"});
        self.reloadHost(alloc, workspace_root, registry) catch |err| {
            debug_trace.logf("mcp", "MCP reload failed err={s}", .{@errorName(err)});
            const sink = self.host_sink orelse return true;
            sink.push(std.heap.c_allocator.print("The MCP config changed, but fx couldn't load it: {s}. Your current servers are still active.", .{mcp_verbs.describe(err)}) catch return true, true);
        };
        return true;
    }

    fn reloadHost(self: *State, alloc: Allocator, workspace_root: []const u8, registry: tool_dispatch.Registry) !void {
        const load = self.host_load orelse return;
        const sink = self.host_sink orelse return;
        const lease = self.leaseHost();
        defer if (lease) |l| l.deinit();
        const current = if (lease) |l| l.host else null;
        const next = try load(alloc, workspace_root, registry, .{ .questions = self.host_questions, .notify = sink.notify(), .slash_commands = true, .reuse = current, .session_open = true });
        if (next != current) self.replaceHost(next);
        self.startHostServers();
    }

    pub fn hostStatusText(self: *const State) []const u8 {
        return self.host_status_buf[0..self.host_status_len];
    }

    pub fn refreshHostStatus(self: *State, now_ms: i64) bool {
        if (self.host_status_at_ms != 0 and now_ms - self.host_status_at_ms < 250) return false;
        self.host_status_at_ms = now_ms;
        var next: [120]u8 = undefined;
        const text = self.hostStatusLine(&next, now_ms);
        if (std.mem.eql(u8, text, self.hostStatusText())) return false;
        @memcpy(self.host_status_buf[0..text.len], text);
        self.host_status_len = text.len;
        return true;
    }

    fn hostStatusLine(self: *State, buf: []u8, now_ms: i64) []const u8 {
        const sink = self.host_sink orelse return "";
        const lease = self.leaseHost() orelse return "";
        defer lease.deinit();
        var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const statuses = lease.host.runtime.statusesNow(a) catch return "";
        sink.mutex.lockUncancelable(io_mod.getIo());
        const news: ?[]const u8 = if (sink.news) |text|
            (if (now_ms - sink.news_at_ms < mcp_menu.news_ms) a.dupe(u8, text) catch null else null)
        else
            null;
        const signing_in: ?[]const u8 = if (sink.sign_in) |waiting|
            a.dupe(u8, waiting[0 .. std.mem.findScalar(u8, waiting, 0) orelse waiting.len]) catch null
        else
            null;
        sink.mutex.unlock(io_mod.getIo());

        if (self.host_started_ms != 0 and !mcp_menu.startupSettled(statuses, now_ms - self.host_started_ms))
            return mcp_menu.statusLine(buf, &.{}, signing_in, news, 0);
        if (self.host_status_dismiss_requested) {
            var seen: mcp_menu.Seen = .{};
            seen.record(statuses);
            self.host_status_seen = seen;
            self.host_status_dismiss_requested = false;
        }

        if (self.host_status_seen) |*seen| {
            const fresh = a.alloc(std.meta.Elem(@TypeOf(statuses)), statuses.len) catch return "";
            return mcp_menu.statusLine(buf, mcp_menu.unseen(statuses, seen, fresh), signing_in, news, 0);
        }
        return mcp_menu.statusLine(buf, statuses, signing_in, news, lease.host.notes.len);
    }

    pub fn dismissHostStatus(self: *State) void {
        self.host_status_dismiss_requested = true;

        self.host_status_at_ms = 0;
    }

    pub fn startHostServers(self: *State) void {
        const lease = self.leaseHost() orelse return;
        defer lease.deinit();
        self.host_started_ms = io_mod.milliTimestamp();
        for (lease.host.runtime.servers()) |s| lease.host.runtime.prepare(s.name) catch |err| {
            debug_trace.logf("mcp", "MCP servers not started in the background server={s} err={s}", .{ s.name, @errorName(err) });
            return;
        };
    }

    pub const HostLease = struct {
        state: *State,
        host: *mcp_host.Host,

        pub fn deinit(l: HostLease) void {
            l.state.releaseHost(l.host);
        }
    };

    pub fn leaseHost(self: *State) ?HostLease {
        self.host_mutex.lockUncancelable(io_mod.getIo());
        defer self.host_mutex.unlock(io_mod.getIo());
        const h = self.host orelse return null;
        h.leases += 1;
        return .{ .state = self, .host = h };
    }

    pub fn hostStatuses(self: *State, alloc: Allocator) Allocator.Error!?[]mcp_host.Status {
        const lease = self.leaseHost() orelse return null;
        defer lease.deinit();
        return try lease.host.runtime.statuses(alloc);
    }

    pub fn hostStatusesNow(self: *State, alloc: Allocator) Allocator.Error!?[]mcp_host.Status {
        const lease = self.leaseHost() orelse return null;
        defer lease.deinit();
        return try lease.host.runtime.statusesNow(alloc);
    }

    fn releaseHost(self: *State, h: *mcp_host.Host) void {
        self.host_mutex.lockUncancelable(io_mod.getIo());
        h.leases -= 1;
        const last = h.retired and h.leases == 0;
        self.host_mutex.unlock(io_mod.getIo());
        if (last) h.stop();
    }

    fn replaceHost(self: *State, next: ?*mcp_host.Host) void {
        self.host_mutex.lockUncancelable(io_mod.getIo());
        const old = self.host;

        if (old) |h| h.retire();
        self.host = next;
        const unused = if (old) |h| unused: {
            h.retired = true;
            break :unused h.leases == 0;
        } else false;
        self.host_mutex.unlock(io_mod.getIo());

        if (next != null) self.host_started_ms = io_mod.milliTimestamp();
        if (unused) old.?.stop();
    }

    fn destroyHost(self: *State) void {
        self.host_closing.store(true, .release);
        if (self.process_exiting.load(.acquire)) {
            mcp_host.signalServersForExit();
            return;
        }

        self.closeHostMenu();
        var waited: usize = 0;
        while (self.host_verbs.load(.acquire) > 0 and waited < 500) : (waited += 1) io_mod.sleep(10 * std.time.ns_per_ms);
        if (self.host_verbs.load(.acquire) > 0) debug_trace.logf("mcp", "MCP commands still running at exit count={d}", .{self.host_verbs.load(.acquire)});
        self.replaceHost(null);

        mcp_host.waitRetired();
        if (self.host_completion_arena) |*arena| arena.deinit();
        self.host_completion_arena = null;
        self.host_completion = &.{};

        if (self.host_sink) |sink| {
            sink.deinit();
            std.heap.c_allocator.destroy(sink);
            self.host_sink = null;
        }
    }

    pub const HostNotice = struct { text: []u8, warning: bool };

    pub const HostSink = struct {
        mutex: std.Io.Mutex = .init,
        notices: std.ArrayList(HostNotice) = .empty,
        typed: std.ArrayList([]u8) = .empty,
        news: ?[]u8 = null,
        news_at_ms: i64 = 0,
        menu_job: ?*MenuToolsJob = null,
        menu_tools: ?MenuTools = null,
        sign_in: ?[]u8 = null,
        sign_in_when_loaded: ?[]u8 = null,

        fn deinit(sink: *HostSink) void {
            if (sink.menu_tools) |*done| done.arena.deinit();
            if (sink.sign_in) |waiting| std.heap.c_allocator.free(waiting);
            if (sink.sign_in_when_loaded) |name| std.heap.c_allocator.free(name);
            for (sink.notices.items) |n| std.heap.c_allocator.free(n.text);
            sink.notices.deinit(std.heap.c_allocator);
            for (sink.typed.items) |name| std.heap.c_allocator.free(name);
            sink.typed.deinit(std.heap.c_allocator);
            if (sink.news) |text| std.heap.c_allocator.free(text);
        }

        fn notify(sink: *HostSink) mcp_host.Notify {
            return .{ .context = sink, .notice = onNotice };
        }

        fn onNotice(context: *anyopaque, notice: mcp_host.Notice) void {
            const sink: *HostSink = @ptrCast(@alignCast(context));
            const a = std.heap.c_allocator;
            var arena: std.heap.ArenaAllocator = .init(a);
            defer arena.deinit();
            const aa = arena.allocator();
            sink.mutex.lockUncancelable(io_mod.getIo());
            defer sink.mutex.unlock(io_mod.getIo());
            switch (notice) {
                .authorize => |n| {
                    sink.waitForSignIn(n.server, n.url);

                    if (!sink.isTyped(n.server)) return;
                    sink.pushLocked(signInText(a, aa, n.server, n.url) catch return, false);
                },
                .signed_in => |server| {
                    sink.endSignIn(server);
                    sink.report(server, a.print("Signed in to {s}.", .{safeText(aa, server, 160)}) catch return, false);
                },
                .sign_in_failed => |n| {
                    sink.endSignIn(n.server);
                    sink.report(n.server, a.print("Couldn't sign in to {s}: {s}.", .{ safeText(aa, n.server, 160), safeText(aa, n.reason, 240) }) catch return, true);
                },

                .needs_login => {},
                .not_saved => |n| {
                    const server = safeText(aa, n.server, 160);
                    const text = a.print("Couldn't save {s}'s new login: {s}. It keeps working here, but after a restart {s} needs a login again.", .{ server, safeText(aa, n.reason, 240), server }) catch return;
                    sink.pushLocked(text, true);
                },
            }
        }

        fn report(sink: *HostSink, server: []const u8, text: []u8, warning: bool) void {
            if (sink.untype(server)) return sink.pushLocked(text, warning);
            if (sink.news) |old| std.heap.c_allocator.free(old);
            sink.news = text;
            sink.news_at_ms = io_mod.milliTimestamp();
        }

        fn markTyped(sink: *HostSink, server: []const u8) void {
            sink.mutex.lockUncancelable(io_mod.getIo());
            defer sink.mutex.unlock(io_mod.getIo());
            if (sink.isTyped(server)) return;
            const a = std.heap.c_allocator;

            const name = a.dupe(u8, server) catch return;
            sink.typed.append(a, name) catch a.free(name);
        }

        fn isTyped(sink: *const HostSink, server: []const u8) bool {
            for (sink.typed.items) |name| if (std.mem.eql(u8, name, server)) return true;
            return false;
        }

        fn untype(sink: *HostSink, server: []const u8) bool {
            for (sink.typed.items, 0..) |name, i| if (std.mem.eql(u8, name, server)) {
                std.heap.c_allocator.free(sink.typed.swapRemove(i));
                return true;
            };
            return false;
        }

        fn waitForSignIn(sink: *HostSink, server: []const u8, url: []const u8) void {
            const a = std.heap.c_allocator;
            const next = std.mem.concat(a, u8, &.{ server, "\x00", url }) catch null;
            if (sink.sign_in) |old| a.free(old);
            sink.sign_in = next;
        }

        fn endSignIn(sink: *HostSink, server: []const u8) void {
            const waiting = sink.sign_in orelse return;
            const end = std.mem.findScalar(u8, waiting, 0) orelse waiting.len;
            if (!std.mem.eql(u8, waiting[0..end], server)) return;
            std.heap.c_allocator.free(waiting);
            sink.sign_in = null;
        }

        fn keepSignInWhenLoaded(sink: *HostSink, name: []u8) void {
            sink.mutex.lockUncancelable(io_mod.getIo());
            defer sink.mutex.unlock(io_mod.getIo());
            if (sink.sign_in_when_loaded == null) {
                sink.sign_in_when_loaded = name;
                return;
            }
            debug_trace.logf("mcp", "MCP sign-in after add dropped server={s} reason=another server was added", .{name});
            std.heap.c_allocator.free(name);
        }

        fn push(sink: *HostSink, text: []u8, warning: bool) void {
            sink.mutex.lockUncancelable(io_mod.getIo());
            defer sink.mutex.unlock(io_mod.getIo());
            sink.pushLocked(text, warning);
        }

        fn pushLocked(sink: *HostSink, text: []u8, warning: bool) void {
            sink.notices.append(std.heap.c_allocator, .{ .text = text, .warning = warning }) catch {
                debug_trace.logf("mcp", "MCP notice dropped: out of memory", .{});
                std.heap.c_allocator.free(text);
            };
        }

        fn safeText(arena: Allocator, raw: []const u8, max: usize) []const u8 {
            return (text_utils.encodeTerminalSafeInline(arena, raw, max) catch return "?").bytes;
        }

        fn signInText(alloc: Allocator, arena: Allocator, server: []const u8, url: []const u8) ![]u8 {
            const name = safeText(arena, server, 160);
            if (text_utils.isLinkTarget(url))
                return alloc.print("Sign in to {s} in your browser. Didn't open? \x1b]8;id=fx-mcp-sign-in;{s}\x1b\\" ++ mcp_menu.sign_in_link_label ++ "\x1b]8;;\x1b\\.", .{ name, url });
            return alloc.print("Sign in to {s} in your browser. If it didn't open, go to:\n  {s}", .{ name, safeText(arena, url, 16 * 1024) });
        }
    };

    pub fn takeHostNotices(self: *State) []HostNotice {
        const sink = self.host_sink orelse return &.{};
        sink.mutex.lockUncancelable(io_mod.getIo());
        defer sink.mutex.unlock(io_mod.getIo());
        return sink.notices.toOwnedSlice(std.heap.c_allocator) catch &.{};
    }

    const verb_completions = [_]mod_registry.ArgumentCompletion{
        .{ .full = "/mcp list", .description = "configured servers" },
        .{ .full = "/mcp show", .description = "connect to a server and list its tools" },
        .{ .full = "/mcp add", .description = "add a server" },
        .{ .full = "/mcp remove", .description = "remove a server and its login" },
        .{ .full = "/mcp login", .description = "sign in to an HTTP server" },
        .{ .full = "/mcp logout", .description = "sign out of an HTTP server" },
        .{ .full = "/mcp approve", .description = "approve a project server" },
        .{ .full = "/mcp reject", .description = "reject a project server" },
    };

    pub fn refreshCompletion(self: *State) void {
        if (self.host_sink == null) return;
        const now = io_mod.milliTimestamp();
        if (self.host_completion.len > 0 and now - self.host_completion_at_ms < 500) return;
        self.host_completion_at_ms = now;
        var next: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
        const entries = self.buildCompletion(next.allocator()) catch {
            next.deinit();
            return;
        };
        if (self.host_completion_arena) |*old| old.deinit();
        self.host_completion_arena = next;
        self.host_completion = entries;
    }

    fn buildCompletion(self: *State, a: Allocator) ![]const mod_registry.ArgumentCompletion {
        var out: std.ArrayList(mod_registry.ArgumentCompletion) = .empty;
        try out.appendSlice(a, &verb_completions);
        const lease = self.leaseHost() orelse return out.items;
        defer lease.deinit();

        const statuses = try lease.host.runtime.statusesNow(a);
        for (statuses, lease.host.runtime.servers()) |status, server| {
            if (!mcp_verbs.isValidServerName(status.name)) continue;
            const description = try mcp_verbs.statusText(a, status);
            const in_config = status.state != .removed;
            const applies = [_]struct { verb: []const u8, ok: bool }{
                .{ .verb = "show", .ok = true },
                .{ .verb = "remove", .ok = in_config },
                .{ .verb = "login", .ok = in_config and server.transport != .stdio },
                .{ .verb = "logout", .ok = in_config and server.transport != .stdio },
                .{ .verb = "approve", .ok = in_config and server.source == .workspace },
                .{ .verb = "reject", .ok = in_config and server.source == .workspace },
            };
            for (applies) |verb| if (verb.ok) try out.append(a, .{
                .full = try a.print("/mcp {s} {s}", .{ verb.verb, status.name }),
                .description = description,
            });
        }
        return out.items;
    }

    pub fn takeHostReload(self: *State) bool {
        return self.host_reload_requested.swap(false, .acq_rel);
    }

    pub fn runVerbs(self: *State, home: []const u8, workspace_root: []const u8, rest: []const u8) !void {
        const a = std.heap.c_allocator;
        var argv = command_lex.tokenize_argv(a, rest) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                const sink = self.host_sink orelse return;
                sink.push(try a.dupe(u8, "/mcp: that command line has an unmatched quote or a character fx doesn't take here."), true);
                return;
            },
        };
        defer argv.deinit(a);
        const args = try a.alloc([]const u8, argv.tokens.len);
        defer a.free(args);
        for (argv.tokens, args) |t, *arg| arg.* = t.value;
        if (self.host_sink) |sink| {
            var arena: std.heap.ArenaAllocator = .init(a);
            defer arena.deinit();
            if (try typedLoginServer(arena.allocator(), args)) |server| sink.markTyped(server);
        }
        try self.startVerbs(home, workspace_root, args, .transcript);
    }

    const VerbReport = enum { transcript, warnings_only };

    fn startVerbs(self: *State, home: []const u8, workspace_root: []const u8, args: []const []const u8, report: VerbReport) !void {
        if (comptime builtin.single_threaded) return error.ThreadsUnsupported;
        const a = std.heap.c_allocator;
        const job = try a.create(VerbJob);
        errdefer a.destroy(job);
        job.* = .{ .state = self, .report = report };
        errdefer job.free();
        const owned = try a.alloc([]const u8, args.len);
        @memset(owned, "");
        job.args = owned;
        for (args, owned) |arg, *copy| copy.* = try a.dupe(u8, arg);
        job.home = try a.dupe(u8, home);
        job.workspace_root = try a.dupe(u8, workspace_root);
        _ = self.host_verbs.fetchAdd(1, .acq_rel);
        errdefer _ = self.host_verbs.fetchSub(1, .acq_rel);
        const thread = std.Thread.spawn(.{}, VerbJob.run, .{job}) catch |err| {
            _ = self.host_verbs.fetchSub(1, .acq_rel);
            debug_trace.logf("mcp", "MCP command not started verb={s} err={s}", .{ if (args.len > 0) args[0] else "", @errorName(err) });
            const notice = a.print("fx couldn't start /mcp {s}: {s}. Nothing was changed; try it again.", .{ if (args.len > 0) args[0] else "", mcp_verbs.describe(err) }) catch null;
            job.free();
            a.destroy(job);
            if (self.host_sink) |sink| if (notice) |text| sink.push(text, true);
            return;
        };
        thread.detach();
    }

    const VerbJob = struct {
        state: *State,
        report: VerbReport,
        args: []const []const u8 = &.{},
        home: []const u8 = "",
        workspace_root: []const u8 = "",

        fn free(job: *VerbJob) void {
            const a = std.heap.c_allocator;
            for (job.args) |arg| a.free(arg);
            a.free(job.args);
            a.free(job.home);
            a.free(job.workspace_root);
        }

        fn run(job: *VerbJob) void {
            const a = std.heap.c_allocator;
            const self = job.state;
            const args = job.args;
            defer {
                job.free();
                a.destroy(job);
                _ = self.host_verbs.fetchSub(1, .acq_rel);
            }
            var out: std.Io.Writer.Allocating = .init(a);
            defer out.deinit();
            var err: std.Io.Writer.Allocating = .init(a);
            defer err.deinit();
            _ = mcp_verbs.run(.{
                .gpa = a,
                .out = &out.writer,
                .err = &err.writer,
                .surface = .shell,
                .home = job.home,
                .workspace_root = job.workspace_root,
                .hosts = .{ .context = self, .get = getHost, .release = putHost, .changed = configChanged, .sign_in_when_loaded = signInWhenLoaded },
                .cancel = &self.host_closing,
            }, args);
            const sink = self.host_sink orelse return;
            for ([_]*std.Io.Writer.Allocating{ &out, &err }, [_]bool{ false, true }) |w, warning| {
                if (!warning and job.report == .warnings_only) continue;
                const text = std.mem.trimEnd(u8, w.written(), "\n");
                if (text.len == 0) continue;
                sink.push(a.dupe(u8, text) catch continue, warning);
            }
        }

        fn getHost(context: *anyopaque, _: ?mcp_host.Notify) anyerror!?*mcp_host.Host {
            const self: *State = @ptrCast(@alignCast(context));
            return if (self.leaseHost()) |l| l.host else null;
        }

        fn putHost(context: *anyopaque, h: *mcp_host.Host) void {
            const self: *State = @ptrCast(@alignCast(context));
            self.releaseHost(h);
        }

        fn configChanged(context: *anyopaque) void {
            const self: *State = @ptrCast(@alignCast(context));
            self.host_reload_requested.store(true, .release);
        }

        fn signInWhenLoaded(context: *anyopaque, name: []const u8) void {
            const self: *State = @ptrCast(@alignCast(context));
            const sink = self.host_sink orelse return;
            const copy = std.heap.c_allocator.dupe(u8, name) catch {
                debug_trace.logf("mcp", "MCP sign-in after add dropped server={s} reason=out of memory", .{name});
                return;
            };
            sink.mutex.lockUncancelable(io_mod.getIo());
            defer sink.mutex.unlock(io_mod.getIo());
            if (sink.sign_in_when_loaded) |old| {
                debug_trace.logf("mcp", "MCP sign-in after add dropped server={s} reason=another server was added", .{old});
                std.heap.c_allocator.free(old);
            }
            sink.sign_in_when_loaded = copy;
        }
    };

    pub fn signInAfterAdd(self: *State) void {
        const sink = self.host_sink orelse return;
        const name = take: {
            sink.mutex.lockUncancelable(io_mod.getIo());
            defer sink.mutex.unlock(io_mod.getIo());
            const name = sink.sign_in_when_loaded orelse return;
            sink.sign_in_when_loaded = null;
            break :take name;
        };
        var keep = false;
        defer if (keep) sink.keepSignInWhenLoaded(name) else std.heap.c_allocator.free(name);

        if (self.host_reload_requested.load(.acquire)) {
            keep = true;
            return;
        }
        const lease = self.leaseHost() orelse return debug_trace.logf("mcp", "MCP sign-in after add dropped server={s} reason=no MCP host", .{name});
        defer lease.deinit();
        var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
        defer arena.deinit();
        const statuses = lease.host.runtime.statusesNow(arena.allocator()) catch return debug_trace.logf("mcp", "MCP sign-in after add dropped server={s} reason=out of memory", .{name});
        const status = for (statuses) |s| {
            if (std.mem.eql(u8, s.name, name)) break s;
        } else return debug_trace.logf("mcp", "MCP sign-in after add dropped server={s} reason=not in the loaded config", .{name});
        if (!status.needs_login) {
            keep = status.state == .idle or status.state == .connecting or status.state == .retrying;
            if (!keep) debug_trace.logf("mcp", "MCP sign-in after add not needed server={s} state={s}", .{ name, @tagName(status.state) });
            return;
        }

        sink.markTyped(name);
        lease.host.runtime.login(name, mcp_verbs.canOpenBrowser()) catch |err| {
            debug_trace.logf("mcp", "MCP sign-in after add failed server={s} err={s}", .{ name, @errorName(err) });
            sink.mutex.lockUncancelable(io_mod.getIo());
            _ = sink.untype(name);
            sink.mutex.unlock(io_mod.getIo());
            sink.push(std.heap.c_allocator.print("Couldn't start signing in to {s}. Try /mcp login {s}.", .{ name, name }) catch return, true);
        };
    }

    pub fn hostMenuActive(self: *const State) bool {
        return self.host_menu.active;
    }

    pub fn openHostMenu(self: *State) void {
        self.closeHostMenu();
        mcp_menu.open(&self.host_menu);
        _ = self.refreshHostMenu("");
    }

    pub fn swapHostMenuFilter(self: *State, was: mcp_menu.Screen, alloc: Allocator, composer: *editor_state.State) Allocator.Error!void {
        if (!self.host_menu.active) return;
        if (was == .list and self.host_menu.screen == .server) {
            self.host_menu.keepListFilter(composer.input.items);
            composer.clearRetainingCapacity();
        } else if (was != .list and self.host_menu.screen == .list) {
            try composer.setText(alloc, self.host_menu.listFilter());
        }
    }

    pub fn hostMenuFilterChanged(self: *State, filter: []const u8) void {
        if (!self.host_menu.active or self.host_menu.screen != .server) return;
        const view = mcp_menu.viewOf(&self.host_menu, self.host_menu_rows, filter, self.host_menu_tools, &.{});
        mcp_menu.filterChanged(&self.host_menu, view, filter.len > 0);
    }

    pub fn closeHostMenu(self: *State) void {
        self.stopMenuTools();
        self.host_menu = .{};
        if (self.host_menu_arena) |*arena| arena.deinit();
        self.host_menu_arena = null;
        self.host_menu_rows = &.{};
        self.host_menu_notes = 0;
        self.host_menu_at_ms = 0;
        if (self.host_menu_sign_in) |waiting| std.heap.c_allocator.free(waiting);
        self.host_menu_sign_in = null;
    }

    pub fn hostMenuSignInUrl(self: *const State) ?[]const u8 {
        if (self.host_menu.screen == .list) return null;
        const waiting = self.host_menu_sign_in orelse return null;
        const end = std.mem.findScalar(u8, waiting, 0) orelse return null;
        if (!std.mem.eql(u8, waiting[0..end], self.host_menu.selectedName())) return null;
        return waiting[end + 1 ..];
    }

    fn takeSignIn(self: *State) bool {
        const sink = self.host_sink orelse return false;
        sink.mutex.lockUncancelable(io_mod.getIo());
        defer sink.mutex.unlock(io_mod.getIo());
        const now = sink.sign_in;
        const had = self.host_menu_sign_in;
        if (now == null and had == null) return false;
        if (now != null and had != null and std.mem.eql(u8, now.?, had.?)) return false;
        const a = std.heap.c_allocator;
        if (had) |old| a.free(old);
        self.host_menu_sign_in = if (now) |w| a.dupe(u8, w) catch null else null;
        return true;
    }

    pub fn hostMenuKey(self: *State, key: mcp_menu.Key, filter: []const u8, home: []const u8, workspace_root: []const u8) !void {
        const buf = try std.heap.c_allocator.alloc(mcp_menu.Row, self.host_menu_rows.len);
        defer std.heap.c_allocator.free(buf);
        const view = mcp_menu.viewOf(&self.host_menu, self.host_menu_rows, filter, self.host_menu_tools, buf);
        const screen_before = self.host_menu.screen;
        defer debug_trace.logf("mcp", "MCP menu key={s} screen={s}->{s} selected={s} rows={d} shown={d}", .{ @tagName(key), @tagName(screen_before), @tagName(self.host_menu.screen), self.host_menu.selectedName(), self.host_menu_rows.len, view.rows.len });
        switch (mcp_menu.press(&self.host_menu, view, key)) {
            .none => {},
            .close => self.closeHostMenu(),
            .open => |name| self.startMenuTools(name) catch |err|
                debug_trace.logf("mcp", "MCP menu tools not loaded server={s} err={s}", .{ name, @errorName(err) }),
            .back => self.stopMenuTools(),
            .run => |run| {
                if (self.host_menu.screen == .list) self.stopMenuTools();
                try self.startVerbs(home, workspace_root, &.{ run.choice.verb(), run.server }, .warnings_only);

                self.host_menu_at_ms = 0;
            },
        }
    }

    pub fn refreshHostMenu(self: *State, filter: []const u8) bool {
        if (!self.host_menu.active) return false;
        var changed = false;
        const now = io_mod.milliTimestamp();
        if (now - self.host_menu_at_ms >= 250) {
            changed = true;
            self.host_menu_at_ms = now;
            var next: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
            if (self.buildMenuRows(next.allocator())) |rows| {
                if (self.host_menu_arena) |*old| old.deinit();
                self.host_menu_arena = next;
                self.host_menu_rows = rows;
            } else |err| {
                next.deinit();
                debug_trace.logf("mcp", "MCP menu kept its old rows err={s}", .{@errorName(err)});
            }
        }
        if (self.takeMenuTools()) changed = true;
        if (self.takeSignIn()) changed = true;
        const view = mcp_menu.viewOf(&self.host_menu, self.host_menu_rows, filter, self.host_menu_tools, &.{});
        if (mcp_menu.settle(&self.host_menu, view) == .back) {
            debug_trace.logf("mcp", "MCP menu went back to the list: the open server is not in the rows server={s} rows={d}", .{ self.host_menu.selectedName(), self.host_menu_rows.len });
            self.stopMenuTools();
            return true;
        }

        const open = view.open orelse return changed;
        if (self.host_menu_tools == .ready or self.host_menu_tools == .loading) return changed;
        if (open.status.needs_login or (open.status.state != .ready and open.status.state != .idle)) return changed;
        if (self.host_menu_loaded) |was| if (std.meta.eql(was, MenuLoadedAs.of(open))) return changed;
        self.startMenuTools(open.status.name) catch |err|
            debug_trace.logf("mcp", "MCP menu tools reload failed err={s}", .{@errorName(err)});
        return true;
    }

    fn buildMenuRows(self: *State, a: Allocator) ![]const mcp_menu.Row {
        const lease = self.leaseHost() orelse {
            debug_trace.logf("mcp", "MCP menu rows empty: no MCP host is loaded", .{});
            self.host_menu_notes = 0;
            return &.{};
        };
        defer lease.deinit();

        const statuses = try lease.host.runtime.statusesNow(a);
        if (statuses.len != self.host_menu_rows.len) debug_trace.logf("mcp", "MCP menu rows changed count was={d} now={d}", .{ self.host_menu_rows.len, statuses.len });
        const rows = try a.alloc(mcp_menu.Row, statuses.len);
        for (statuses, lease.host.runtime.servers(), rows) |status, server, *row| row.* = .{
            .status = status,
            .target = if (server.url orelse server.command) |target| try a.dupe(u8, target) else null,
        };
        self.host_menu_notes = lease.host.notes.len;
        return rows;
    }

    pub const MenuTools = struct { load: usize, arena: std.heap.ArenaAllocator, tools: mcp_menu.Tools };

    const MenuLoadedAs = struct {
        state: @import("../mcp_host/runtime.zig").State,
        needs_login: bool,
        signed_in: bool,

        fn of(row: mcp_menu.Row) MenuLoadedAs {
            return .{ .state = row.status.state, .needs_login = row.status.needs_login, .signed_in = row.status.signed_in };
        }
    };

    fn startMenuTools(self: *State, name: []const u8) !void {
        if (comptime builtin.single_threaded) return error.ThreadsUnsupported;
        self.stopMenuTools();
        self.host_menu_load +%= 1;
        const open = for (self.host_menu_rows) |row| {
            if (std.mem.eql(u8, row.status.name, name)) break row;
        } else null;
        self.host_menu_loaded = if (open) |row| MenuLoadedAs.of(row) else null;
        const sink = self.host_sink orelse return;
        const a = std.heap.c_allocator;
        const job = try a.create(MenuToolsJob);
        errdefer a.destroy(job);
        job.* = .{ .state = self, .load = self.host_menu_load, .name = try a.dupe(u8, name) };
        errdefer a.free(job.name);
        _ = self.host_verbs.fetchAdd(1, .acq_rel);
        errdefer _ = self.host_verbs.fetchSub(1, .acq_rel);

        sink.mutex.lockUncancelable(io_mod.getIo());
        sink.menu_job = job;
        sink.mutex.unlock(io_mod.getIo());
        const thread = std.Thread.spawn(.{}, MenuToolsJob.run, .{job}) catch |err| {
            sink.mutex.lockUncancelable(io_mod.getIo());
            sink.menu_job = null;
            sink.mutex.unlock(io_mod.getIo());
            return err;
        };
        thread.detach();
    }

    fn stopMenuTools(self: *State) void {
        if (self.host_sink) |sink| {
            sink.mutex.lockUncancelable(io_mod.getIo());
            defer sink.mutex.unlock(io_mod.getIo());
            if (sink.menu_job) |job| job.cancel.store(true, .release);
            sink.menu_job = null;
            if (sink.menu_tools) |*done| done.arena.deinit();
            sink.menu_tools = null;
        }
        if (self.host_menu_tools_arena) |*arena| arena.deinit();
        self.host_menu_tools_arena = null;
        self.host_menu_tools = .loading;
    }

    fn takeMenuTools(self: *State) bool {
        const sink = self.host_sink orelse return false;
        sink.mutex.lockUncancelable(io_mod.getIo());
        const done = sink.menu_tools orelse {
            sink.mutex.unlock(io_mod.getIo());
            return false;
        };
        sink.menu_tools = null;
        sink.mutex.unlock(io_mod.getIo());
        if (done.load != self.host_menu_load) {
            done.arena.deinit();
            return false;
        }
        if (self.host_menu_tools_arena) |*old| old.deinit();
        self.host_menu_tools_arena = done.arena;
        self.host_menu_tools = done.tools;
        return true;
    }

    const MenuToolsJob = struct {
        state: *State,
        load: usize,
        name: []const u8,
        cancel: std.atomic.Value(bool) = .init(false),

        fn run(job: *MenuToolsJob) void {
            const a = std.heap.c_allocator;
            const self = job.state;
            defer {
                a.free(job.name);
                a.destroy(job);
                _ = self.host_verbs.fetchSub(1, .acq_rel);
            }
            var arena: std.heap.ArenaAllocator = .init(a);
            const tools = job.list(arena.allocator()) catch |err| switch (err) {
                error.OutOfMemory => mcp_menu.Tools{ .failed = "fx ran out of memory" },
                else => mcp_menu.Tools{ .failed = "the server stopped answering" },
            };
            const sink = self.host_sink orelse return arena.deinit();
            sink.mutex.lockUncancelable(io_mod.getIo());
            defer sink.mutex.unlock(io_mod.getIo());

            if (sink.menu_job != job) return arena.deinit();
            sink.menu_job = null;
            if (sink.menu_tools) |*old| old.arena.deinit();
            sink.menu_tools = .{ .load = job.load, .arena = arena, .tools = tools };
        }

        fn list(job: *MenuToolsJob, arena: Allocator) !mcp_menu.Tools {
            const lease = job.state.leaseHost() orelse return .{ .failed = "MCP isn't running" };
            defer lease.deinit();
            return switch (try lease.host.runtime.tools(arena, job.name, &job.cancel)) {
                .tools => |found| blk: {
                    const out = try arena.alloc(mcp_menu.Tool, found.len);
                    for (found, out) |t, *o| o.* = .{ .name = t.name, .description = (try mcp_verbs.toolDescription(arena, t.raw)) orelse "" };
                    break :blk .{ .ready = out };
                },
                .needs_login => .needs_login,
                .failed => |reason| .{ .failed = reason },
                .unknown_server => .{ .failed = "it's no longer configured" },
            };
        }
    };

    pub fn hasTool(self: *State, name: []const u8, access: tool_mcp_runtime.Access) bool {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return l.host.catalog.hasTool(name, access);
        }
        return false;
    }

    pub fn validateTool(
        self: *State,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
        access: tool_mcp_runtime.Access,
    ) !tool_mcp_runtime.ValidationResult {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return l.host.catalog.validateTool(arena, name, arguments_json, access);
        }
        return .not_available;
    }

    pub fn callTool(
        self: *State,
        arena: Allocator,
        name: []const u8,
        arguments_json: []const u8,
        max_tool_result_bytes: usize,
        options: tool_mcp_runtime.CallOptions,
    ) !?tool_mcp_runtime.CallResult {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return l.host.catalog.callTool(arena, name, arguments_json, max_tool_result_bytes, options);
        }
        return null;
    }

    pub fn readResource(
        self: *State,
        arena: Allocator,
        server: []const u8,
        op: mcp_resources.Op,
        access: tool_mcp_runtime.Access,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !tool_mcp_runtime.ResourceResult {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return l.host.catalog.readResource(arena, server, op, access, cancel_flag);
        }
        return .{ .failure = .{ .code = 0, .message = "MCP is not available in this session." } };
    }

    pub fn searchTools(
        self: *State,
        arena: Allocator,
        request: tool_mcp_runtime.SearchRequest,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: tool_mcp_runtime.Access,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !tool_mcp_runtime.SearchResult {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return l.host.catalog.searchTools(arena, request, permission_rules, limits, access, cancel_flag);
        }
        return .{ .model_output = try arena.dupe(u8, "{\"tools\":[],\"count\":0}") };
    }

    pub fn toolSchema(
        self: *State,
        arena: Allocator,
        name: []const u8,
        permission_rules: types.PermissionRuleSet,
        limits: context_limits.Values,
        access: tool_mcp_runtime.Access,
        cancel_flag: ?*std.atomic.Value(bool),
    ) !?tool_mcp_runtime.ToolSchemaResult {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return l.host.catalog.toolSchema(arena, name, permission_rules, limits, access, cancel_flag);
        }
        return null;
    }

    pub fn listTools(
        self: *State,
        arena: Allocator,
        permission_rules: types.PermissionRuleSet,
        access: tool_mcp_runtime.Access,
        cancel_flag: ?*std.atomic.Value(bool),
    ) ![]const tool_mcp_runtime.ListedTool {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return l.host.catalog.listTools(arena, permission_rules, access, cancel_flag);
        }
        return &.{};
    }

    pub fn snapshotToolDefinition(self: *State, alloc: Allocator, name: []const u8, known: tool_mcp_runtime.Binding, permission_rules: types.PermissionRuleSet, limits: context_limits.Values, access: tool_mcp_runtime.Access) !tool_mcp_runtime.DefinitionSnapshot {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return l.host.catalog.snapshotToolDefinition(alloc, name, known, permission_rules, limits, access);
        }
        return .unavailable;
    }

    pub fn prepareAlwaysLoadedServers(self: *State, cancel_flag: ?*std.atomic.Value(bool)) !void {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            try l.host.catalog.prepareAlwaysLoadedServers(cancel_flag);
        }
    }

    pub fn snapshotToolNames(
        self: *State,
        alloc: Allocator,
        permission_rules: types.PermissionRuleSet,
    ) ![][]u8 {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return l.host.catalog.snapshotToolNames(alloc, permission_rules);
        }
        return alloc.alloc([]u8, 0);
    }

    pub fn snapshotAccessView(
        self: *State,
        alloc: Allocator,
        owner_id: []const u8,
        parent_id: []const u8,
        permission_rules: types.PermissionRuleSet,
    ) !?mcp_access.View {
        if (self.leaseHost()) |l| {
            defer l.deinit();
            return try l.host.catalog.snapshotAccessView(alloc, owner_id, parent_id, permission_rules);
        }
        return null;
    }

    pub fn snapshotModelCatalog(
        self: *State,
        alloc: Allocator,
        baseline_alloc: Allocator,
    ) !mcp_model_catalog.Report {
        var snapshot = if (self.leaseHost()) |l| leased: {
            defer l.deinit();
            break :leased try l.host.catalog.modelSnapshot(alloc);
        } else return .{ .snapshot = try mcp_model_catalog.Snapshot.empty(alloc) };
        errdefer snapshot.deinit(alloc);
        const notice = try self.updateModelCatalogBaseline(alloc, baseline_alloc, snapshot.servers);
        return .{ .snapshot = snapshot, .change_notice = notice };
    }

    fn updateModelCatalogBaseline(
        self: *State,
        alloc: Allocator,
        baseline_alloc: Allocator,
        current: []const mcp_model_catalog.ServerSummary,
    ) !?[]u8 {
        for (current) |server| {
            if (server.availability == .discovering) return null;
        }
        self.model_catalog_baseline_lock.lockUncancelable(io_mod.getIo());
        defer self.model_catalog_baseline_lock.unlock(io_mod.getIo());
        const notice = if (self.model_catalog_baseline) |baseline|
            try mcp_model_catalog.renderChangeNotice(alloc, baseline, current)
        else
            null;
        errdefer if (notice) |text| alloc.free(text);
        try self.replaceModelCatalogBaselineLocked(baseline_alloc, current);
        return notice;
    }

    fn replaceModelCatalogBaselineLocked(
        self: *State,
        baseline_alloc: Allocator,
        current: []const mcp_model_catalog.ServerSummary,
    ) !void {
        var next = try baseline_alloc.alloc(mcp_model_catalog.BaselineEntry, current.len);
        var initialized: usize = 0;
        errdefer {
            for (next[0..initialized]) |entry| baseline_alloc.free(entry.name);
            baseline_alloc.free(next);
        }
        for (current, 0..) |server, index| {
            next[index] = .{
                .name = try baseline_alloc.dupe(u8, server.name),
                .availability = server.availability,
            };
            initialized += 1;
        }
        self.clearModelCatalogBaselineLocked(baseline_alloc);
        self.model_catalog_baseline = next;
    }

    fn clearModelCatalogBaselineLocked(self: *State, baseline_alloc: Allocator) void {
        const baseline = self.model_catalog_baseline orelse return;
        for (baseline) |entry| baseline_alloc.free(entry.name);
        baseline_alloc.free(baseline);
        self.model_catalog_baseline = null;
    }

    pub fn deinitForProcessExit(self: *State) void {
        self.process_exiting.store(true, .release);
        self.destroyHost();
    }

    pub fn deinit(self: *State, alloc: Allocator) void {
        self.destroyHost();
        self.model_catalog_baseline_lock.lockUncancelable(io_mod.getIo());
        self.clearModelCatalogBaselineLocked(alloc);
        self.model_catalog_baseline_lock.unlock(io_mod.getIo());
        self.* = .{};
    }
};

test "a typed /mcp login names its server wherever --no-browser goes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { args: []const []const u8, server: ?[]const u8 }{
        .{ .args = &.{ "login", "web" }, .server = "web" },
        .{ .args = &.{ "login", "--no-browser", "web" }, .server = "web" },
        .{ .args = &.{ "login", "web", "--no-browser" }, .server = "web" },
        .{ .args = &.{ "login", "--no-browser" }, .server = null },
        .{ .args = &.{ "login", "web", "docs" }, .server = null },
        .{ .args = &.{ "login", "web", "--json" }, .server = null },
        .{ .args = &.{ "login", "web", "--help" }, .server = null },
        .{ .args = &.{"login"}, .server = null },
        .{ .args = &.{}, .server = null },
        .{ .args = &.{ "logout", "web" }, .server = null },
        .{ .args = &.{ "show", "web" }, .server = null },
    };
    for (cases) |case| {
        const server = try typedLoginServer(arena.allocator(), case.args);
        if (case.server) |want| {
            try std.testing.expectEqualStrings(want, server orelse return error.TestExpectedEqual);
        } else try std.testing.expectEqual(@as(?[]const u8, null), server);
    }
}

test "model catalog baseline surfaces availability changes once" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    const before = [_]mcp_model_catalog.ServerSummary{
        .{ .name = @constCast("linear"), .availability = .authentication_required },
    };
    const first = try state.updateModelCatalogBaseline(alloc, alloc, &before);
    try std.testing.expectEqual(@as(?[]u8, null), first);

    const after = [_]mcp_model_catalog.ServerSummary{
        .{ .name = @constCast("linear"), .availability = .ready, .tool_count = 74 },
    };
    const changed = try state.updateModelCatalogBaseline(alloc, alloc, &after);
    defer if (changed) |notice| alloc.free(notice);
    try std.testing.expect(changed != null);
    try std.testing.expect(std.mem.find(u8, changed.?, "linear: authentication_required -> ready (74 tools)") != null);

    const settled = try state.updateModelCatalogBaseline(alloc, alloc, &after);
    try std.testing.expectEqual(@as(?[]u8, null), settled);
}

test "model catalog baseline waits out discovery before recording state" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    const discovering = [_]mcp_model_catalog.ServerSummary{
        .{ .name = @constCast("linear"), .availability = .discovering },
    };
    const during_discovery = try state.updateModelCatalogBaseline(alloc, alloc, &discovering);
    try std.testing.expectEqual(@as(?[]u8, null), during_discovery);
    try std.testing.expect(state.model_catalog_baseline == null);

    const ready = [_]mcp_model_catalog.ServerSummary{
        .{ .name = @constCast("linear"), .availability = .ready, .tool_count = 74 },
    };
    const settled = try state.updateModelCatalogBaseline(alloc, alloc, &ready);
    try std.testing.expectEqual(@as(?[]u8, null), settled);
    try std.testing.expect(state.model_catalog_baseline != null);

    const failed = [_]mcp_model_catalog.ServerSummary{
        .{ .name = @constCast("linear"), .availability = .failed },
    };
    const outage = try state.updateModelCatalogBaseline(alloc, alloc, &failed);
    defer if (outage) |notice| alloc.free(notice);
    try std.testing.expect(outage != null);
    try std.testing.expect(std.mem.find(u8, outage.?, "linear: ready -> failed") != null);
}

test "model catalog baseline reports removals" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    const before = [_]mcp_model_catalog.ServerSummary{
        .{ .name = @constCast("slack"), .availability = .ready, .tool_count = 3 },
    };
    _ = try state.updateModelCatalogBaseline(alloc, alloc, &before);

    const removed = try state.updateModelCatalogBaseline(alloc, alloc, &.{});
    defer if (removed) |notice| alloc.free(notice);
    try std.testing.expect(removed != null);
    try std.testing.expect(std.mem.find(u8, removed.?, "slack: removed") != null);
}

test "a typed sign-in prints an address that can't be a link, to copy" {
    var sink: State.HostSink = .{};
    defer sink.deinit();
    const notify = sink.notify();
    sink.markTyped("docs");
    notify.notice(notify.context, .{ .authorize = .{ .server = "docs", .url = "https://a.example/a b\x1b[2J" } });
    try std.testing.expectEqual(@as(usize, 1), sink.notices.items.len);
    const text = sink.notices.items[0].text;
    try std.testing.expect(std.mem.startsWith(u8, text, "Sign in to docs in your browser. If it didn't open, go to:\n  https://a.example/a b"));
    try std.testing.expect(std.mem.findScalar(u8, text, 0x1b) == null);
}

test "a typed sign-in reports in the transcript, any other on the status line" {
    var sink: State.HostSink = .{};
    defer sink.deinit();
    const notify = sink.notify();
    sink.markTyped("docs");
    notify.notice(notify.context, .{ .authorize = .{ .server = "docs", .url = "https://a.example/authorize" } });
    notify.notice(notify.context, .{ .signed_in = "docs" });
    try std.testing.expectEqual(@as(usize, 2), sink.notices.items.len);

    try std.testing.expectEqualStrings(
        "Sign in to docs in your browser. Didn't open? \x1b]8;id=fx-mcp-sign-in;https://a.example/authorize\x1b\\Open the sign-in page\x1b]8;;\x1b\\.",
        sink.notices.items[0].text,
    );
    try std.testing.expectEqualStrings("Signed in to docs.", sink.notices.items[1].text);
    try std.testing.expect(sink.news == null);

    notify.notice(notify.context, .{ .authorize = .{ .server = "docs", .url = "https://a.example/authorize" } });
    try std.testing.expect(sink.sign_in != null);
    notify.notice(notify.context, .{ .sign_in_failed = .{ .server = "docs", .reason = "it said no" } });
    try std.testing.expectEqual(@as(usize, 2), sink.notices.items.len);
    try std.testing.expectEqualStrings("Couldn't sign in to docs: it said no.", sink.news.?);
    try std.testing.expect(sink.sign_in == null);

    notify.notice(notify.context, .{ .needs_login = "docs" });
    try std.testing.expectEqual(@as(usize, 2), sink.notices.items.len);
}

fn writeTestFile(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| try tmp.dir.createDirPath(io_mod.getIo(), parent);
    var file = try tmp.dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

test "the config stamp follows every MCP config layer, the trust state and project choices, and nothing else" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.git");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    const none = configStamp(alloc, home, root);
    try std.testing.expectEqual(none, configStamp(alloc, home, root));

    try writeTestFile(&tmp, "home/.fx/mcp.json", "");
    const blank = configStamp(alloc, home, root);
    try std.testing.expect(blank != none);
    try writeTestFile(&tmp, "home/.fx/mcp.json",
        \\{"mcp":{"linear":{"url":"https://mcp.linear.app/mcp"}}}
    );
    const profile = configStamp(alloc, home, root);
    try std.testing.expect(profile != blank);
    try writeTestFile(&tmp, "workspace/.mcp.json",
        \\{"mcpServers":{"p":{"command":"p-server"}}}
    );
    const project = configStamp(alloc, home, root);
    try std.testing.expect(project != profile);

    try writeTestFile(&tmp, "workspace/.kimi-code/mcp.json",
        \\{"mcpServers":{"nested":{"command":"nested-server"}}}
    );
    const nested = configStamp(alloc, home, root);
    try std.testing.expect(nested != project);

    try workspace_trust.grant(alloc, home, root, 1);
    const granted = configStamp(alloc, home, root);
    try std.testing.expect(granted != nested);

    const unrelated = try alloc.print("{{\"permission_mode\":\"auto\",\"workspaces\":{{\"{s}\":{{\"max_agent_steps\":10}}}}}}", .{root});
    defer alloc.free(unrelated);
    try writeTestFile(&tmp, "home/.fx/settings.json", unrelated);
    try std.testing.expectEqual(granted, configStamp(alloc, home, root));

    try writeTestFile(&tmp, "home/.fx/settings.json", "{\"workspace\":{\"require_trust\":false}}");
    const relaxed = configStamp(alloc, home, root);
    try std.testing.expect(relaxed != granted);

    const approved = try alloc.print("{{\"workspaces\":{{\"{s}\":{{\"" ++ @import("../mcp/project_config.zig").enabled_servers_key ++ "\":[\"p\"]}}}}}}", .{root});
    defer alloc.free(approved);
    try writeTestFile(&tmp, "home/.fx/settings.json", approved);

    var load = try config_runtime.loadProjectMcpChoicesFromHome(alloc, home, root);
    defer load.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), load.choices.approved.len);
    try std.testing.expect(configStamp(alloc, home, root) != relaxed);
}

const FakeTrustPrompt = struct {
    choice: workspace_trust.PromptChoice,
    calls: usize = 0,

    fn choose(ctx: ?*anyopaque, _: []const u8) anyerror!workspace_trust.PromptChoice {
        const self: *FakeTrustPrompt = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        return self.choice;
    }

    fn prompt(self: *FakeTrustPrompt) TrustPrompt {
        return .{ .ctx = self, .choose = choose };
    }
};

test "the startup trust gate prompts for every untrusted folder and acts on the choice" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.git");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    var fake = FakeTrustPrompt{ .choice = .distrust };
    try std.testing.expectEqual(workspace_trust.PromptOutcome.continue_session, try startupTrustGate(alloc, null, root, false, fake.prompt()));
    try std.testing.expectEqual(workspace_trust.PromptOutcome.continue_session, try startupTrustGate(alloc, home, root, true, fake.prompt()));
    try std.testing.expectEqual(workspace_trust.PromptOutcome.continue_session, try startupTrustGate(alloc, home, root, false, null));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);

    try std.testing.expectEqual(workspace_trust.PromptOutcome.exit_program, try startupTrustGate(alloc, home, root, false, fake.prompt()));
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expect(!try workspace_trust.persisted(alloc, home, root));

    fake.choice = .trust;
    try std.testing.expectEqual(workspace_trust.PromptOutcome.continue_session, try startupTrustGate(alloc, home, root, false, fake.prompt()));
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
    try std.testing.expect(try workspace_trust.persisted(alloc, home, root));

    try std.testing.expectEqual(workspace_trust.PromptOutcome.continue_session, try startupTrustGate(alloc, home, root, false, fake.prompt()));
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}

test "the startup trust gate does not prompt when workspace.require_trust is off" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.git");
    try writeTestFile(&tmp, "home/.fx/settings.json", "{\"workspace\":{\"require_trust\":false}}");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    var fake = FakeTrustPrompt{ .choice = .distrust };
    try std.testing.expectEqual(workspace_trust.PromptOutcome.continue_session, try startupTrustGate(alloc, home, root, false, fake.prompt()));
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
    try std.testing.expect(!try workspace_trust.persisted(alloc, home, root));
}

test "a headless run in an untrusted folder is warned about the project MCP servers it skips" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.git");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    try std.testing.expect(untrustedProjectServersWarning(alloc, home, root, false) == null);

    try writeTestFile(&tmp, "workspace/.mcp.json", "{\"mcpServers\":{\"docs\":{\"command\":\"docs-server\"},\"search\":{\"command\":\"search-server\"}}}");
    const warning = untrustedProjectServersWarning(alloc, home, root, false) orelse return error.TestUnexpectedResult;
    defer alloc.free(warning);
    try std.testing.expect(std.mem.startsWith(u8, warning, "Warning: this folder is not trusted; skipped 2 project-level MCP servers: "));
    try std.testing.expect(std.mem.find(u8, warning, "docs") != null);
    try std.testing.expect(std.mem.find(u8, warning, "search") != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        warning,
        ".\n  Run `fx` here and choose \"Trust this folder\", or set KIMI_CODE_TRUST_WORKSPACE=1, to enable them.\n\n",
    ));

    try std.testing.expect(untrustedProjectServersWarning(alloc, home, root, true) == null);
    try std.testing.expect(untrustedProjectServersWarning(alloc, null, root, false) == null);

    try workspace_trust.grant(alloc, home, root, 1);
    try std.testing.expect(untrustedProjectServersWarning(alloc, home, root, false) == null);
}

test "the session trust gate asks at most once per process after the folder is accepted" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.git");
    try tmp.dir.createDirPath(io_mod.getIo(), "other/.git");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    const other = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "other");
    defer alloc.free(other);
    process_trust_resolved = false;
    defer process_trust_resolved = false;

    var declined = FakeTrustPrompt{ .choice = .distrust };
    try std.testing.expectError(error.WorkspaceTrustDeclined, gateBeforeSession(alloc, home, root, false, declined.prompt()));
    try std.testing.expect(!process_trust_resolved);

    var accepted = FakeTrustPrompt{ .choice = .trust };
    try gateBeforeSession(alloc, home, root, false, accepted.prompt());
    try std.testing.expectEqual(@as(usize, 1), accepted.calls);
    try gateBeforeSession(alloc, home, other, false, accepted.prompt());
    try std.testing.expectEqual(@as(usize, 1), accepted.calls);
}

test "gateBeforeLoad stops the MCP load when the trust prompt is declined and lets a trusted load through" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.git");
    try writeTestFile(&tmp, "workspace/.mcp.json", "{\"mcpServers\":{\"p\":{\"command\":\"p-server\"}}}");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);

    var declined = FakeTrustPrompt{ .choice = .distrust };
    try std.testing.expectError(error.WorkspaceTrustDeclined, gateBeforeLoad(alloc, home, root, false, declined.prompt()));
    try std.testing.expectEqual(@as(usize, 1), declined.calls);

    var accepted = FakeTrustPrompt{ .choice = .trust };
    try gateBeforeLoad(alloc, home, root, false, accepted.prompt());
    try std.testing.expectEqual(@as(usize, 1), accepted.calls);
    try gateBeforeLoad(alloc, home, root, false, accepted.prompt());
    try std.testing.expectEqual(@as(usize, 1), accepted.calls);
}

test "the stdin trust answer trusts on Enter, t or yes and exits otherwise" {
    try std.testing.expectEqual(workspace_trust.PromptChoice.trust, parseTrustAnswer(""));
    try std.testing.expectEqual(workspace_trust.PromptChoice.trust, parseTrustAnswer(" Yes\r"));
    try std.testing.expectEqual(workspace_trust.PromptChoice.trust, parseTrustAnswer("t"));
    try std.testing.expectEqual(workspace_trust.PromptChoice.distrust, parseTrustAnswer("e"));
    try std.testing.expectEqual(workspace_trust.PromptChoice.distrust, parseTrustAnswer("no"));
}

const TestLoader = struct {
    var loads: usize = 0;
    var fail = false;

    fn load(_: Allocator, _: []const u8, _: tool_dispatch.Registry, _: mcp_host.Extras) anyerror!?*mcp_host.Host {
        loads += 1;
        if (fail) return error.McpConfigInvalidJson;
        return null;
    }
};

test "the host loads again when its config files change outside the session, once per change" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.git");
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
    defer alloc.free(home);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    TestLoader.loads = 0;
    TestLoader.fail = false;
    const registry: tool_dispatch.Registry = .{ .tools = &.{} };
    var state: State = .{};
    defer state.deinit(alloc);

    try state.loadHost(TestLoader.load, alloc, home, root, registry, .{});
    try std.testing.expectEqual(@as(usize, 1), TestLoader.loads);
    try std.testing.expect(!state.refreshHost(alloc, home, root, registry, .files));

    try writeTestFile(&tmp, "home/.fx/mcp.json",
        \\{"mcp":{"linear":{"url":"https://mcp.linear.app/mcp"}}}
    );
    try std.testing.expect(!state.refreshHost(alloc, home, root, registry, .requested));
    try std.testing.expect(state.refreshHost(alloc, home, root, registry, .files));
    try std.testing.expectEqual(@as(usize, 2), TestLoader.loads);
    try std.testing.expect(!state.refreshHost(alloc, home, root, registry, .files));

    state.host_reload_requested.store(true, .release);
    try std.testing.expect(state.refreshHost(alloc, home, root, registry, .requested));
    try std.testing.expectEqual(@as(usize, 3), TestLoader.loads);

    TestLoader.fail = true;
    try writeTestFile(&tmp, "workspace/.mcp.json",
        \\{"mcpServers":{"p":{"command":"p-server"}}}
    );
    try std.testing.expect(state.refreshHost(alloc, home, root, registry, .files));
    try std.testing.expect(!state.refreshHost(alloc, home, root, registry, .files));
    try std.testing.expectEqual(@as(usize, 4), TestLoader.loads);
    const notices = state.takeHostNotices();
    defer {
        for (notices) |n| std.heap.c_allocator.free(n.text);
        std.heap.c_allocator.free(notices);
    }
    try std.testing.expectEqual(@as(usize, 1), notices.len);
    try std.testing.expect(notices[0].warning);
    try std.testing.expectEqualStrings("The MCP config changed, but fx couldn't load it: ~/.fx/mcp.json isn't valid JSON. Your current servers are still active.", notices[0].text);
}
