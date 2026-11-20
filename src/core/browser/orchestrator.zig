const std = @import("std");
const cdp = @import("cdp.zig");
const browser_session = @import("session.zig");
const browser_execute = @import("execute.zig");
const fake_transport = @import("fake_transport.zig");

pub const RouteKind = enum { native_tool, mcp, browser_cdp, shell, file, code };
pub const RouteState = enum { queued, running, waiting_approval, browser_wait, completed, failed };

pub const Snapshot = struct {
    run_id: []const u8 = "",
    step_id: usize = 0,
    route: RouteKind = .code,
    state: RouteState = .queued,
    tool: []const u8 = "",
    job: []const u8 = "",
    session_id: ?[]const u8 = null,
    browser_target: ?[]const u8 = null,
    approval_pending: bool = false,
    completed_steps: usize = 0,
    total_steps: usize = 0,
};

pub const BrowserState = enum { none, idle, busy };

pub const BrowserStatus = struct {
    state: BrowserState = .none,
    tab_count: usize = 0,
};

pub const bluf_max_bytes = 256;

pub const BlufCoalescer = struct {
    bytes: [bluf_max_bytes]u8 = undefined,
    len: usize = 0,
    has_value: bool = false,

    pub fn update(self: *BlufCoalescer, orchestrator: *const Orchestrator) bool {
        var next: [bluf_max_bytes]u8 = undefined;
        const next_line = orchestrator.bluf(&next);
        const changed = !self.has_value or self.len != next_line.len or
            !std.mem.eql(u8, self.bytes[0..self.len], next_line);
        if (changed) {
            @memcpy(self.bytes[0..next_line.len], next_line);
            self.len = next_line.len;
            self.has_value = true;
        }
        return changed;
    }

    pub fn line(self: *const BlufCoalescer) []const u8 {
        return if (self.has_value) self.bytes[0..self.len] else "";
    }
};

pub const Orchestrator = struct {
    session: browser_session.Session,
    snapshot: Snapshot = .{},
    connected: bool = false,
    tab_count: usize = 0,

    pub fn init(id: []const u8) Orchestrator {
        return .{ .session = .{ .id = id } };
    }

    pub fn deinit(self: *Orchestrator, alloc: std.mem.Allocator) void {
        self.session.deinit(alloc);
        self.* = undefined;
    }

    pub fn beginRun(self: *Orchestrator, alloc: std.mem.Allocator, run_id: []const u8, total_steps: usize) !void {
        const run = try self.session.startRun(alloc, run_id);
        self.snapshot = .{
            .run_id = run.id,
            .state = .running,
            .total_steps = total_steps,
        };
    }

    pub fn prepareStep(
        self: *Orchestrator,
        alloc: std.mem.Allocator,
        command: browser_execute.Command,
    ) !browser_execute.Result {
        self.snapshot.route = routeFor(command.action);
        self.snapshot.tool = toolLabel(command.action);
        self.snapshot.session_id = command.session_id;
        self.snapshot.browser_target = command.target_id;
        self.snapshot.state = if (command.action == .evaluate) .browser_wait else .running;
        const result = try browser_execute.executeStep(alloc, &self.session, command);
        if (self.session.findRun(command.run_id)) |run| self.snapshot.run_id = run.id;
        self.snapshot.step_id = result.step_id;
        return result;
    }

    pub fn runStep(
        self: *Orchestrator,
        alloc: std.mem.Allocator,
        transport: browser_execute.Transport,
        command: browser_execute.Command,
    ) !cdp.Response {
        const prepared = try self.prepareStep(alloc, command);
        defer alloc.free(prepared.request_json);
        const reply = transport.send(alloc, prepared.request_json) catch |err| {
            browser_execute.abandonStep(&self.session, command.run_id, prepared.step_id);
            self.snapshot.state = .failed;
            return err;
        };
        defer alloc.free(reply);
        const response = try self.complete(alloc, command.run_id, prepared.step_id, reply);
        errdefer cdp.responseOwnedDeinit(alloc, response);
        try self.trackTabs(alloc, command.action, response);
        return response;
    }

    pub fn runSequence(
        self: *Orchestrator,
        alloc: std.mem.Allocator,
        transport: browser_execute.Transport,
        run_id: []const u8,
        commands: []const browser_execute.Command,
        out: []cdp.Response,
    ) !usize {
        if (out.len < commands.len) return error.OutputTooSmall;
        try self.beginRun(alloc, run_id, commands.len);
        var filled: usize = 0;
        errdefer for (out[0..filled]) |response| cdp.responseOwnedDeinit(alloc, response);
        for (commands) |command| {
            out[filled] = try self.runStep(alloc, transport, command);
            filled += 1;
            if (out[filled - 1].error_message != null) break;
        }
        return filled;
    }

    pub fn browserStatus(self: *const Orchestrator) BrowserStatus {
        const state: BrowserState = if (self.session.inFlight())
            .busy
        else if (self.connected)
            .idle
        else
            .none;
        return .{ .state = state, .tab_count = self.tab_count };
    }

    pub fn markConnected(self: *Orchestrator) void {
        self.connected = true;
    }

    pub fn noteApproval(self: *Orchestrator, pending: bool) void {
        self.snapshot.approval_pending = pending;
        if (pending) self.snapshot.state = .waiting_approval;
    }

    pub fn complete(
        self: *Orchestrator,
        alloc: std.mem.Allocator,
        run_id: []const u8,
        step_id: usize,
        response_bytes: []const u8,
    ) !cdp.Response {
        const response = browser_execute.completeStep(alloc, &self.session, run_id, step_id, response_bytes) catch |err| {
            self.snapshot.state = .failed;
            return err;
        };
        self.snapshot.completed_steps +|= 1;
        const failed = response.error_message != null;
        self.connected = self.connected or !failed;
        self.snapshot.state = if (failed) .failed else .completed;
        return response;
    }

    fn trackTabs(self: *Orchestrator, alloc: std.mem.Allocator, action: browser_execute.Action, response: cdp.Response) !void {
        if (response.error_message != null) return;
        switch (action) {
            .targets => self.tab_count = try countPages(alloc, response.result_json),
            .open => self.tab_count +|= 1,
            .close => self.tab_count -|= 1,
            .attach, .evaluate => {},
        }
    }

    pub fn routeFor(action: browser_execute.Action) RouteKind {
        return switch (action) {
            .targets, .open, .attach, .evaluate, .close => .browser_cdp,
        };
    }

    fn toolLabel(action: browser_execute.Action) []const u8 {
        return switch (action) {
            .targets => "tabs",
            .open => "open tab",
            .attach => "attach tab",
            .evaluate => "browser evaluate",
            .close => "close tab",
        };
    }

    pub fn bluf(self: *const Orchestrator, out: []u8) []const u8 {
        if (self.snapshot.run_id.len == 0) return "";
        const state = switch (self.snapshot.state) {
            .queued => "queued",
            .running => "running",
            .waiting_approval => "needs approval",
            .browser_wait => "browser",
            .completed => "done",
            .failed => "failed",
        };
        const route = switch (self.snapshot.route) {
            .native_tool => "tool",
            .mcp => "mcp",
            .browser_cdp => "browser",
            .shell => "shell",
            .file => "file",
            .code => "code",
        };
        var progress_buf: [24]u8 = undefined;
        const progress = std.fmt.bufPrint(&progress_buf, "{d}/{d}", .{
            @min(self.snapshot.completed_steps, self.snapshot.total_steps),
            self.snapshot.total_steps,
        }) catch "0/0";
        const approval = if (self.snapshot.approval_pending) " · approval" else "";
        return std.fmt.bufPrint(out, "fx run {s} · {s} · {s} · {s} · step {d} {s}{s}", .{
            self.snapshot.run_id,
            route,
            state,
            if (self.snapshot.tool.len > 0) self.snapshot.tool else "idle",
            self.snapshot.step_id,
            progress,
            approval,
        }) catch "";
    }
};

fn countPages(alloc: std.mem.Allocator, result_json: []const u8) !usize {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, result_json, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return 0,
    };
    const infos = switch (root.get("targetInfos") orelse return 0) {
        .array => |array| array.items,
        else => return 0,
    };
    var count: usize = 0;
    for (infos) |info| {
        const kind = switch (info) {
            .object => |object| object.get("type") orelse continue,
            else => continue,
        };
        switch (kind) {
            .string => |text| {
                if (std.mem.eql(u8, text, "page")) count += 1;
            },
            else => {},
        }
    }
    return count;
}

test "native_browser bluf snapshots coalesce instead of requesting repeated repaints" {
    const alloc = std.testing.allocator;
    var orchestration = Orchestrator.init("coalesce");
    defer orchestration.deinit(alloc);
    try orchestration.beginRun(alloc, "watch", 1);
    var coalescer = BlufCoalescer{};

    try std.testing.expect(coalescer.update(&orchestration));
    try std.testing.expectEqualStrings("fx run watch · code · running · idle · step 0 0/1", coalescer.line());
    var repaint_requests: usize = 1;
    var frame: usize = 0;
    while (frame < 10_000) : (frame += 1) {
        if (coalescer.update(&orchestration)) repaint_requests += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), repaint_requests);

    orchestration.noteApproval(true);
    try std.testing.expect(coalescer.update(&orchestration));
    try std.testing.expect(std.mem.endsWith(u8, coalescer.line(), " · approval"));
}

test "native_browser bluf produces one compact line for a browser evaluate step" {
    const alloc = std.testing.allocator;
    var orchestrator = Orchestrator.init("fx-native");
    defer orchestrator.deinit(alloc);
    try orchestrator.beginRun(alloc, "inspect", 2);
    const result = try orchestrator.prepareStep(alloc, .{
        .run_id = "inspect",
        .request_id = "fx-1",
        .action = .evaluate,
        .target_id = "tab-1",
        .session_id = "birdman-tab-1",
        .params_json = "{\"expression\":\"document.title\"}",
    });
    defer alloc.free(result.request_json);
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "fx run inspect · browser · browser · browser evaluate · step 1 0/2",
        orchestrator.bluf(&out),
    );
    orchestrator.noteApproval(true);
    try std.testing.expect(std.mem.endsWith(u8, orchestrator.bluf(&out), " · approval"));
}

test "native_browser sequence runs targets, open, attach and evaluate in order through a fake transport" {
    const alloc = std.testing.allocator;
    var orchestration = Orchestrator.init("seq");
    defer orchestration.deinit(alloc);
    var fake = fake_transport.Fake{ .alloc = alloc };
    defer fake.deinit();
    const commands = [_]browser_execute.Command{
        .{ .run_id = "seq", .request_id = "r1", .action = .targets },
        .{ .run_id = "seq", .request_id = "r2", .action = .open, .params_json = "{\"url\":\"about:blank\"}" },
        .{ .run_id = "seq", .request_id = "r3", .action = .attach, .target_id = "T-1", .params_json = "{\"targetId\":\"T-1\",\"flatten\":true}" },
        .{ .run_id = "seq", .request_id = "r4", .action = .evaluate, .target_id = "T-1", .session_id = "S-1", .params_json = "{\"expression\":\"document.title\"}" },
    };
    var out: [commands.len]cdp.Response = undefined;
    const count = try orchestration.runSequence(alloc, fake.transport(), "seq", &commands, &out);
    defer for (out[0..count]) |response| cdp.responseOwnedDeinit(alloc, response);

    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(@as(usize, 4), fake.sent.items.len);
    try std.testing.expect(std.mem.indexOf(u8, fake.sent.items[0], "\"method\":\"Target.getTargets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.sent.items[1], "\"method\":\"Target.createTarget\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.sent.items[3], "\"sessionId\":\"S-1\"") != null);
    for (out[0..count], 0..) |response, index| {
        var expected: [3]u8 = undefined;
        const id = try std.fmt.bufPrint(&expected, "r{d}", .{index + 1});
        try std.testing.expectEqualStrings(id, response.id);
        try std.testing.expect(response.error_message == null);
    }
    const attached = (try cdp.resultStringAlloc(alloc, out[2].result_json, "sessionId")).?;
    defer alloc.free(attached);
    try std.testing.expectEqualStrings("S-1", attached);

    const run = orchestration.session.findRun("seq").?;
    try std.testing.expectEqual(@as(usize, 4), run.steps.items.len);
    for (run.steps.items) |step| try std.testing.expectEqual(browser_session.StepState.completed, step.state);
    try std.testing.expectEqual(@as(usize, 3), orchestration.tab_count);
    try std.testing.expectEqual(@as(usize, 4), orchestration.snapshot.completed_steps);
    try std.testing.expect(!orchestration.session.inFlight());
}

test "native_browser sequence stops at a CDP error response and reports the failed step" {
    const alloc = std.testing.allocator;
    var orchestration = Orchestrator.init("err");
    defer orchestration.deinit(alloc);
    var fake = fake_transport.Fake{ .alloc = alloc, .error_on = "Target.createTarget" };
    defer fake.deinit();
    const commands = [_]browser_execute.Command{
        .{ .run_id = "err", .request_id = "e1", .action = .targets },
        .{ .run_id = "err", .request_id = "e2", .action = .open },
        .{ .run_id = "err", .request_id = "e3", .action = .evaluate, .session_id = "S-1" },
    };
    var out: [commands.len]cdp.Response = undefined;
    const count = try orchestration.runSequence(alloc, fake.transport(), "err", &commands, &out);
    defer for (out[0..count]) |response| cdp.responseOwnedDeinit(alloc, response);

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(out[0].error_message == null);
    try std.testing.expectEqualStrings("Method not found", out[1].error_message.?);
    try std.testing.expectEqual(@as(usize, 2), fake.sent.items.len);
    try std.testing.expectEqual(@as(usize, 2), orchestration.session.findRun("err").?.steps.items.len);
    try std.testing.expectEqual(browser_session.StepState.failed, orchestration.session.findRun("err").?.steps.items[1].state);
    try std.testing.expectEqual(RouteState.failed, orchestration.snapshot.state);
    try std.testing.expectEqual(@as(usize, 2), orchestration.tab_count);
}

test "native_browser transport failure abandons the step and leaves nothing in flight" {
    const alloc = std.testing.allocator;
    var orchestration = Orchestrator.init("drop");
    defer orchestration.deinit(alloc);
    var fake = fake_transport.Fake{ .alloc = alloc, .drop_on = "Target.getTargets" };
    defer fake.deinit();
    const commands = [_]browser_execute.Command{
        .{ .run_id = "drop", .request_id = "d1", .action = .targets },
    };
    var out: [commands.len]cdp.Response = undefined;
    try std.testing.expectError(error.ConnectionClosed, orchestration.runSequence(alloc, fake.transport(), "drop", &commands, &out));
    try std.testing.expect(!orchestration.session.inFlight());
    try std.testing.expectEqual(browser_session.StepState.failed, orchestration.session.findRun("drop").?.steps.items[0].state);
    try std.testing.expectEqual(BrowserState.none, orchestration.browserStatus().state);
}

test "native_browser status is none before connection, busy during a step, idle after" {
    const alloc = std.testing.allocator;
    var orchestration = Orchestrator.init("status");
    defer orchestration.deinit(alloc);
    try std.testing.expectEqual(BrowserState.none, orchestration.browserStatus().state);
    try std.testing.expectEqual(@as(usize, 0), orchestration.browserStatus().tab_count);

    var fake = fake_transport.Fake{ .alloc = alloc, .observed = &orchestration };
    defer fake.deinit();
    const commands = [_]browser_execute.Command{
        .{ .run_id = "status", .request_id = "s1", .action = .targets },
        .{ .run_id = "status", .request_id = "s2", .action = .close, .target_id = "T-1" },
    };
    var out: [commands.len]cdp.Response = undefined;
    const count = try orchestration.runSequence(alloc, fake.transport(), "status", &commands, &out);
    defer for (out[0..count]) |response| cdp.responseOwnedDeinit(alloc, response);

    try std.testing.expectEqual(BrowserState.busy, fake.observed_status.?.state);
    const after = orchestration.browserStatus();
    try std.testing.expectEqual(BrowserState.idle, after.state);
    try std.testing.expectEqual(@as(usize, 1), after.tab_count);
}
