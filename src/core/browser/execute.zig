const std = @import("std");
const cdp = @import("cdp.zig");
const browser_session = @import("session.zig");

pub const Action = enum {
    targets,
    open,
    attach,
    evaluate,
    close,
};

pub const Command = struct {
    run_id: []const u8,
    request_id: []const u8,
    action: Action,
    target_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    params_json: []const u8 = "{}",
};

pub const Result = struct {
    request_id: []const u8,
    method: []const u8,
    request_json: []const u8,
    step_id: usize,
};

pub const Outcome = struct {
    step_id: usize,
    response: cdp.Response,
};

pub const Transport = struct {
    context: *anyopaque,
    send_fn: *const fn (context: *anyopaque, alloc: std.mem.Allocator, request_json: []const u8) anyerror![]u8,

    pub fn send(self: Transport, alloc: std.mem.Allocator, request_json: []const u8) anyerror![]u8 {
        return self.send_fn(self.context, alloc, request_json);
    }
};

pub fn methodFor(action: Action) []const u8 {
    return switch (action) {
        .targets => "Target.getTargets",
        .open => "Target.createTarget",
        .attach => "Target.attachToTarget",
        .evaluate => "Runtime.evaluate",
        .close => "Target.closeTarget",
    };
}

pub fn attachParamsJson(alloc: std.mem.Allocator, target_id: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{
        .targetId = target_id,
        .flatten = true,
    }, .{});
}

pub fn closeParamsJson(alloc: std.mem.Allocator, target_id: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(alloc, .{ .targetId = target_id }, .{});
}

fn requireTarget(command: Command) ![]const u8 {
    return command.target_id orelse error.MissingTarget;
}

fn requestParams(alloc: std.mem.Allocator, command: Command) ![]u8 {
    return switch (command.action) {
        .attach => attachParamsJson(alloc, try requireTarget(command)),
        .close => closeParamsJson(alloc, try requireTarget(command)),
        .targets, .open, .evaluate => alloc.dupe(u8, command.params_json),
    };
}

pub fn executeStep(
    alloc: std.mem.Allocator,
    session: *browser_session.Session,
    command: Command,
) !Result {
    const method = methodFor(command.action);
    const params_json = try requestParams(alloc, command);
    defer alloc.free(params_json);
    const request: cdp.Request = .{
        .id = command.request_id,
        .method = method,
        .params_json = params_json,
        .session_id = command.session_id,
    };
    const request_json = try cdp.encodeRequestAlloc(alloc, request);
    errdefer alloc.free(request_json);
    const run = session.findRun(command.run_id) orelse try session.startRun(alloc, command.run_id);
    const step_id = try run.begin(alloc, command.request_id, method, command.target_id, command.session_id);
    _ = run.markSent(step_id);
    return .{
        .request_id = command.request_id,
        .method = method,
        .request_json = request_json,
        .step_id = step_id,
    };
}

pub fn runStep(
    alloc: std.mem.Allocator,
    session: *browser_session.Session,
    transport: Transport,
    command: Command,
) !Outcome {
    const framed = try executeStep(alloc, session, command);
    defer alloc.free(framed.request_json);
    const reply = transport.send(alloc, framed.request_json) catch |err| {
        abandonStep(session, command.run_id, framed.step_id);
        return err;
    };
    defer alloc.free(reply);
    const response = try completeStep(alloc, session, command.run_id, framed.step_id, reply);
    return .{ .step_id = framed.step_id, .response = response };
}

pub fn completeStep(
    alloc: std.mem.Allocator,
    session: *browser_session.Session,
    run_id: []const u8,
    step_id: usize,
    response_bytes: []const u8,
) !cdp.Response {
    const run = session.findRun(run_id) orelse return error.UnknownRun;
    const step = run.findStep(step_id) orelse return error.UnknownStep;
    const response = cdp.decodeResponseAlloc(alloc, step.request_id, response_bytes) catch |err| {
        _ = run.finish(step_id, true);
        return err;
    };
    _ = run.finish(step_id, response.error_message != null);
    return response;
}

pub fn abandonStep(session: *browser_session.Session, run_id: []const u8, step_id: usize) void {
    const run = session.findRun(run_id) orelse return;
    _ = run.finish(step_id, true);
}

test "native_browser execute frames Runtime.evaluate and settles its step" {
    const alloc = std.testing.allocator;
    var session = browser_session.Session{ .id = "fx-native" };
    defer session.deinit(alloc);
    const result = try executeStep(alloc, &session, .{
        .run_id = "inspect-title",
        .request_id = "thebird-9",
        .action = .evaluate,
        .target_id = "tab-1",
        .session_id = "birdman-tab-1",
        .params_json = "{\"expression\":\"document.title\",\"returnByValue\":true}",
    });
    defer alloc.free(result.request_json);
    try std.testing.expectEqualStrings("Runtime.evaluate", result.method);
    var request = try std.json.parseFromSlice(std.json.Value, alloc, result.request_json, .{});
    defer request.deinit();
    try std.testing.expectEqualStrings("thebird-9", request.value.object.get("id").?.string);
    try std.testing.expectEqualStrings("birdman-tab-1", request.value.object.get("sessionId").?.string);

    const response = try completeStep(
        alloc,
        &session,
        "inspect-title",
        result.step_id,
        "{\"id\":\"thebird-9\",\"result\":{\"result\":{\"type\":\"string\",\"value\":\"fx native browser\"}}}",
    );
    defer cdp.responseOwnedDeinit(alloc, response);
    try std.testing.expect(response.error_message == null);
    try std.testing.expectEqual(browser_session.StepState.completed, session.findRun("inspect-title").?.findStep(result.step_id).?.state);
}

test "native_browser execute attach frames Target.attachToTarget with flatten and reads the session id" {
    const alloc = std.testing.allocator;
    var session = browser_session.Session{ .id = "fx-attach" };
    defer session.deinit(alloc);
    const result = try executeStep(alloc, &session, .{
        .run_id = "attach",
        .request_id = "thebird-attach",
        .action = .attach,
        .target_id = "TAB-3",
    });
    defer alloc.free(result.request_json);
    try std.testing.expectEqualStrings("Target.attachToTarget", result.method);
    var request = try std.json.parseFromSlice(std.json.Value, alloc, result.request_json, .{});
    defer request.deinit();
    const sent = request.value.object.get("params").?.object;
    try std.testing.expectEqualStrings("TAB-3", sent.get("targetId").?.string);
    try std.testing.expect(sent.get("flatten").?.bool);
    const response = try completeStep(alloc, &session, "attach", result.step_id, "{\"id\":\"thebird-attach\",\"result\":{\"sessionId\":\"S-42\"}}");
    defer cdp.responseOwnedDeinit(alloc, response);
    const attached = (try cdp.resultStringAlloc(alloc, response.result_json, "sessionId")).?;
    defer alloc.free(attached);
    try std.testing.expectEqualStrings("S-42", attached);
}

test "native_browser execute close and attach carry the command target into the CDP params" {
    const alloc = std.testing.allocator;
    var session = browser_session.Session{ .id = "fx-target" };
    defer session.deinit(alloc);
    const close = try executeStep(alloc, &session, .{
        .run_id = "target",
        .request_id = "close-1",
        .action = .close,
        .target_id = "T-9",
    });
    defer alloc.free(close.request_json);
    try std.testing.expectEqualStrings("Target.closeTarget", close.method);
    var close_request = try std.json.parseFromSlice(std.json.Value, alloc, close.request_json, .{});
    defer close_request.deinit();
    try std.testing.expectEqualStrings("T-9", close_request.value.object.get("params").?.object.get("targetId").?.string);
    try std.testing.expectError(error.MissingTarget, executeStep(alloc, &session, .{
        .run_id = "target",
        .request_id = "attach-none",
        .action = .attach,
    }));
    try std.testing.expect(session.findRun("target").?.steps.items.len == 1);
}

test "native_browser execute runStep sends through the transport and settles the step" {
    const alloc = std.testing.allocator;
    var session = browser_session.Session{ .id = "fx-transport" };
    defer session.deinit(alloc);
    const Echo = struct {
        fn send(context: *anyopaque, reply_alloc: std.mem.Allocator, request_json: []const u8) anyerror![]u8 {
            _ = context;
            var parsed = try std.json.parseFromSlice(std.json.Value, reply_alloc, request_json, .{});
            defer parsed.deinit();
            const id = parsed.value.object.get("id").?.string;
            return std.fmt.allocPrint(reply_alloc, "{{\"id\":\"{s}\",\"result\":{{\"targetInfos\":[]}}}}", .{id});
        }
    };
    var marker: u8 = 0;
    const transport = Transport{ .context = &marker, .send_fn = Echo.send };
    const outcome = try runStep(alloc, &session, transport, .{
        .run_id = "echo",
        .request_id = "echo-1",
        .action = .targets,
    });
    defer cdp.responseOwnedDeinit(alloc, outcome.response);
    try std.testing.expectEqualStrings("echo-1", outcome.response.id);
    try std.testing.expect(outcome.response.error_message == null);
    try std.testing.expectEqual(browser_session.StepState.completed, session.findRun("echo").?.findStep(outcome.step_id).?.state);
}

test "native_browser execute abandons the step when the transport fails" {
    const alloc = std.testing.allocator;
    var session = browser_session.Session{ .id = "fx-drop" };
    defer session.deinit(alloc);
    const Dropped = struct {
        fn send(context: *anyopaque, reply_alloc: std.mem.Allocator, request_json: []const u8) anyerror![]u8 {
            _ = context;
            _ = reply_alloc;
            _ = request_json;
            return error.ConnectionClosed;
        }
    };
    var marker: u8 = 0;
    const transport = Transport{ .context = &marker, .send_fn = Dropped.send };
    try std.testing.expectError(error.ConnectionClosed, runStep(alloc, &session, transport, .{
        .run_id = "drop",
        .request_id = "drop-1",
        .action = .targets,
    }));
    const step = session.findRun("drop").?.findStep(1).?;
    try std.testing.expectEqual(browser_session.StepState.failed, step.state);
    try std.testing.expect(!session.inFlight());
}
