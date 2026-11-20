const std = @import("std");
const birdman = @import("birdman.zig");
const cdp = @import("cdp.zig");
const execute = @import("execute.zig");
const fake_transport = @import("fake_transport.zig");
const orchestrator = @import("orchestrator.zig");
const request_mod = @import("request.zig");
const tool_dispatch = @import("../tooling/tool_dispatch.zig");
const kimi_sections = @import("../config/kimi_sections.zig");

const Allocator = std.mem.Allocator;

pub const Route = kimi_sections.BrowserRoute;

pub const birdman_unanswered_message = "The Birdman extension did not answer. Click its toolbar button on this tab.";
pub const cdp_unanswered_message = "The CDP browser endpoint did not answer. Check that a browser with remote debugging is listening at the configured endpoint.";
pub const unavailable_state = "unavailable";

const app_session_id = "fx-native";
const id_bytes = 32;

pub const Dialer = *const fn (alloc: Allocator, options: birdman.Options) birdman.Error!birdman.Link;

pub const BrowserView = struct {
    state: []const u8 = "none",
    tabs: usize = 0,
};

pub const RunError = error{ BrowserUnavailable, OutOfMemory, NoSpaceLeft };

pub const AppBrowser = struct {
    orchestrator: orchestrator.Orchestrator = orchestrator.Orchestrator.init(app_session_id),
    link: ?birdman.Link = null,
    unavailable: bool = false,
    endpoint: kimi_sections.BrowserEndpoint = .{},
    runs_started: usize = 0,
    dialer: Dialer = &birdman.Link.open,
    bluf_buf: [orchestrator.bluf_max_bytes]u8 = undefined,

    pub fn deinit(self: *AppBrowser, alloc: Allocator) void {
        self.dropLink();
        self.orchestrator.deinit(alloc);
        self.* = undefined;
    }

    pub fn view(self: *const AppBrowser) BrowserView {
        const status = self.orchestrator.browserStatus();
        return .{
            .state = if (self.unavailable) unavailable_state else @tagName(status.state),
            .tabs = status.tab_count,
        };
    }

    pub fn bluf(self: *AppBrowser) []const u8 {
        return self.orchestrator.bluf(&self.bluf_buf);
    }

    pub fn provider(self: *AppBrowser) tool_dispatch.BrowserProvider {
        return .{ .ctx = self, .execute_fn = executeProvider };
    }

    pub fn runRequest(self: *AppBrowser, alloc: Allocator, request: *const request_mod.Request) RunError!cdp.Response {
        return switch (self.endpoint.route) {
            .birdman, .cdp => self.runLink(alloc, request),
        };
    }

    pub fn unavailableMessage(route: Route) []const u8 {
        return switch (route) {
            .birdman => birdman_unanswered_message,
            .cdp => cdp_unanswered_message,
        };
    }

    fn runLink(self: *AppBrowser, alloc: Allocator, request: *const request_mod.Request) RunError!cdp.Response {
        if (self.link == null) try self.connectLink(alloc);
        if (self.link) |*link| {
            return self.runOver(alloc, link.executeTransport(), request) catch |err| {
                if (err == error.BrowserUnavailable) self.dropLink();
                return err;
            };
        }
        return error.BrowserUnavailable;
    }

    fn connectLink(self: *AppBrowser, alloc: Allocator) RunError!void {
        const link = self.dialer(alloc, self.birdmanOptions()) catch {
            self.unavailable = true;
            return error.BrowserUnavailable;
        };
        self.link = link;
        self.acceptProbe();
    }

    fn birdmanOptions(self: *const AppBrowser) birdman.Options {
        return .{
            .host = self.endpoint.host.slice(),
            .port = self.endpoint.port,
            .path = self.endpoint.path.slice(),
        };
    }

    fn acceptProbe(self: *AppBrowser) void {
        self.unavailable = false;
        self.orchestrator.markConnected();
    }

    fn dropLink(self: *AppBrowser) void {
        if (self.link) |*link| link.close();
        self.link = null;
    }

    fn runOver(self: *AppBrowser, alloc: Allocator, transport: execute.Transport, request: *const request_mod.Request) RunError!cdp.Response {
        var run_buf: [id_bytes]u8 = undefined;
        const run_id = try std.fmt.bufPrint(&run_buf, "browser-{d}", .{self.runs_started});
        self.runs_started += 1;
        var request_buf: [id_bytes]u8 = undefined;
        const request_id = try std.fmt.bufPrint(&request_buf, "{s}-1", .{run_id});
        const commands = [_]execute.Command{request.command(run_id, request_id)};
        var out: [commands.len]cdp.Response = undefined;
        const count = self.orchestrator.runSequence(alloc, transport, run_id, &commands, &out) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.unavailable = true;
                return error.BrowserUnavailable;
            },
        };
        self.unavailable = false;
        return out[count - 1];
    }
};

fn executeProvider(
    raw: ?*anyopaque,
    dispatch: tool_dispatch.DispatchContext,
    input: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const self: *AppBrowser = @ptrCast(@alignCast(raw.?));
    const request = input.as(request_mod.Request);
    const response = self.runRequest(dispatch.allocator, request) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BrowserUnavailable, error.NoSpaceLeft => return .{
            .failure = try dispatch.allocator.dupe(u8, AppBrowser.unavailableMessage(self.endpoint.route)),
        },
    };
    defer cdp.responseOwnedDeinit(dispatch.allocator, response);
    if (response.error_message) |message| return .{ .failure = try dispatch.allocator.dupe(u8, message) };
    return .{ .success = try dispatch.allocator.dupe(u8, response.result_json) };
}

fn refuseDial(_: Allocator, _: birdman.Options) birdman.Error!birdman.Link {
    return error.ConnectFailed;
}

fn deinitRequest(raw: *anyopaque, alloc: Allocator) void {
    const request: *request_mod.Request = @ptrCast(@alignCast(raw));
    request.deinit();
    alloc.destroy(request);
}

fn parsedInput(alloc: Allocator, args_json: []const u8) !tool_dispatch.ToolInput {
    const request = try alloc.create(request_mod.Request);
    errdefer alloc.destroy(request);
    request.* = try request_mod.Request.parse(alloc, args_json);
    return .{ .ptr = request, .deinit_fn = deinitRequest };
}

const DialRecord = struct {
    var host: []const u8 = "";
    var port: u16 = 0;
    var path: []const u8 = "";

    fn dial(alloc: Allocator, options: birdman.Options) birdman.Error!birdman.Link {
        _ = alloc;
        host = options.host;
        port = options.port;
        path = options.path;
        return error.ConnectFailed;
    }
};

test "native_browser link dials the configured endpoint" {
    const alloc = std.testing.allocator;
    var browser = AppBrowser{ .dialer = &DialRecord.dial };
    defer browser.deinit(alloc);
    try browser.endpoint.host.set("10.0.0.5");
    browser.endpoint.port = 9222;
    try browser.endpoint.path.set("/x/birdman");

    try std.testing.expectError(error.BrowserUnavailable, browser.connectLink(alloc));
    try std.testing.expectEqualStrings("10.0.0.5", DialRecord.host);
    try std.testing.expectEqual(@as(u16, 9222), DialRecord.port);
    try std.testing.expectEqualStrings("/x/birdman", DialRecord.path);
}

test "native_browser CDP route dials the configured endpoint and reports when it does not answer" {
    const alloc = std.testing.allocator;
    var browser = AppBrowser{ .dialer = &DialRecord.dial };
    defer browser.deinit(alloc);
    browser.endpoint.route = .cdp;
    try browser.endpoint.host.set("127.0.0.1");
    browser.endpoint.port = 9333;
    try browser.endpoint.path.set("/devtools/browser/abc");
    const input = try parsedInput(alloc, "{\"action\":\"targets\"}");
    defer input.deinit(alloc);

    const result = try executeProvider(&browser, .{ .allocator = alloc }, input);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings(cdp_unanswered_message, result.failure);
    try std.testing.expectEqualStrings("127.0.0.1", DialRecord.host);
    try std.testing.expectEqual(@as(u16, 9333), DialRecord.port);
    try std.testing.expectEqualStrings("/devtools/browser/abc", DialRecord.path);
}

test "native_browser provider reports the CDP message when the endpoint routes to CDP and does not answer" {
    const alloc = std.testing.allocator;
    var browser = AppBrowser{ .dialer = &refuseDial };
    defer browser.deinit(alloc);
    browser.endpoint.route = .cdp;
    const input = try parsedInput(alloc, "{\"action\":\"targets\"}");
    defer input.deinit(alloc);

    const result = try executeProvider(&browser, .{ .allocator = alloc }, input);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings(cdp_unanswered_message, result.failure);
}

test "native_browser route reports the Birdman message when the extension does not answer" {
    const alloc = std.testing.allocator;
    var browser = AppBrowser{ .dialer = &refuseDial };
    defer browser.deinit(alloc);
    var request = try request_mod.Request.parse(alloc, "{\"action\":\"targets\"}");
    defer request.deinit();

    try std.testing.expectError(error.BrowserUnavailable, browser.runRequest(alloc, &request));
    try std.testing.expectEqualStrings(unavailable_state, browser.view().state);
    try std.testing.expectEqualStrings("", browser.bluf());
}

test "native_browser provider maps an unanswered Birdman extension to the user-facing failure" {
    const alloc = std.testing.allocator;
    var browser = AppBrowser{ .dialer = &refuseDial };
    defer browser.deinit(alloc);
    const input = try parsedInput(alloc, "{\"action\":\"targets\"}");
    defer input.deinit(alloc);

    const result = try executeProvider(&browser, .{ .allocator = alloc }, input);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings(birdman_unanswered_message, result.failure);
}

test "native_browser probe answer makes the status idle before any step" {
    const alloc = std.testing.allocator;
    var browser = AppBrowser{};
    defer browser.deinit(alloc);
    try std.testing.expectEqualStrings("none", browser.view().state);

    browser.acceptProbe();

    try std.testing.expectEqualStrings("idle", browser.view().state);
    try std.testing.expectEqual(@as(usize, 0), browser.view().tabs);
}

test "native_browser run over the transport counts tabs and reports idle" {
    const alloc = std.testing.allocator;
    var browser = AppBrowser{};
    defer browser.deinit(alloc);
    var fake = fake_transport.Fake{ .alloc = alloc };
    defer fake.deinit();
    var request = try request_mod.Request.parse(alloc, "{\"action\":\"targets\"}");
    defer request.deinit();

    const response = try browser.runOver(alloc, fake.transport(), &request);
    defer cdp.responseOwnedDeinit(alloc, response);

    try std.testing.expect(response.error_message == null);
    try std.testing.expectEqualStrings("idle", browser.view().state);
    try std.testing.expectEqual(@as(usize, 2), browser.view().tabs);
    try std.testing.expectEqualStrings("browser-0", browser.orchestrator.snapshot.run_id);
}

test "native_browser transport failure marks the browser unavailable and asks for a reconnect" {
    const alloc = std.testing.allocator;
    var browser = AppBrowser{};
    defer browser.deinit(alloc);
    var fake = fake_transport.Fake{ .alloc = alloc, .drop_on = "Target.getTargets" };
    defer fake.deinit();
    var request = try request_mod.Request.parse(alloc, "{\"action\":\"targets\"}");
    defer request.deinit();

    try std.testing.expectError(error.BrowserUnavailable, browser.runOver(alloc, fake.transport(), &request));
    try std.testing.expectEqualStrings(unavailable_state, browser.view().state);
}

test "native_browser CDP error reply reaches the tool as a failure without marking the route unavailable" {
    const alloc = std.testing.allocator;
    var browser = AppBrowser{};
    defer browser.deinit(alloc);
    browser.acceptProbe();
    var fake = fake_transport.Fake{ .alloc = alloc, .error_on = "Target.createTarget" };
    defer fake.deinit();
    var request = try request_mod.Request.parse(alloc, "{\"action\":\"open\",\"url\":\"about:blank\"}");
    defer request.deinit();

    const response = try browser.runOver(alloc, fake.transport(), &request);
    defer cdp.responseOwnedDeinit(alloc, response);

    try std.testing.expectEqualStrings("Method not found", response.error_message.?);
    try std.testing.expectEqualStrings("idle", browser.view().state);
    try std.testing.expectEqualStrings("{\"url\":\"about:blank\"}", request.params_json);
}
