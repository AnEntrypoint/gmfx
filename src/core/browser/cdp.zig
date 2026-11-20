const std = @import("std");

pub const Error = error{
    InvalidMethod,
    InvalidSessionId,
    InvalidParams,
    ResponseIdMismatch,
    ResponseError,
    MalformedResponse,
};

pub const Request = struct {
    id: []const u8,
    method: []const u8,
    params_json: []const u8 = "{}",
    session_id: ?[]const u8 = null,
};

pub const Response = struct {
    id: []const u8,
    result_json: []const u8 = "{}",
    error_message: ?[]const u8 = null,
};

const default_error_text = "CDP error";

pub fn validateRequest(request: Request) Error!void {
    if (request.id.len == 0 or request.method.len == 0) return error.InvalidMethod;
    if (request.session_id) |session_id| {
        if (session_id.len == 0) return error.InvalidSessionId;
    }
}

pub fn encodeRequestAlloc(alloc: std.mem.Allocator, request: Request) ![]u8 {
    try validateRequest(request);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const params = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), request.params_json, .{}) catch
        return error.InvalidParams;
    if (request.session_id) |session_id| {
        return std.json.Stringify.valueAlloc(alloc, .{
            .id = request.id,
            .method = request.method,
            .params = params,
            .sessionId = session_id,
        }, .{});
    }
    return std.json.Stringify.valueAlloc(alloc, .{
        .id = request.id,
        .method = request.method,
        .params = params,
    }, .{});
}

pub fn decodeResponseAlloc(
    alloc: std.mem.Allocator,
    request_id: []const u8,
    bytes: []const u8,
) !Response {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.MalformedResponse,
    };
    const id = switch (root.get("id") orelse return error.ResponseIdMismatch) {
        .string => |value| value,
        else => return error.ResponseIdMismatch,
    };
    if (!std.mem.eql(u8, id, request_id)) return error.ResponseIdMismatch;
    const error_message: ?[]const u8 = if (root.get("error")) |value| switch (value) {
        .null => null,
        else => errorText(value),
    } else null;
    const result_json = if (root.get("result")) |result|
        try std.json.Stringify.valueAlloc(alloc, result, .{})
    else
        try alloc.dupe(u8, "{}");
    errdefer alloc.free(result_json);
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const owned_error: ?[]u8 = if (error_message) |text| try alloc.dupe(u8, text) else null;
    return .{
        .id = owned_id,
        .result_json = result_json,
        .error_message = owned_error,
    };
}

fn errorText(value: std.json.Value) []const u8 {
    return switch (value) {
        .string => |text| text,
        .object => |object| switch (object.get("message") orelse return default_error_text) {
            .string => |text| text,
            else => default_error_text,
        },
        else => default_error_text,
    };
}

pub fn resultStringAlloc(alloc: std.mem.Allocator, result_json: []const u8, field: []const u8) !?[]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), result_json, .{}) catch
        return error.ResponseError;
    const object = switch (parsed) {
        .object => |object| object,
        else => return null,
    };
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |text| try alloc.dupe(u8, text),
        else => null,
    };
}

pub fn responseOwnedDeinit(alloc: std.mem.Allocator, response: Response) void {
    alloc.free(response.id);
    alloc.free(response.result_json);
    if (response.error_message) |message| alloc.free(message);
}

test "native_browser cdp request encodes browser-level and session-level envelopes" {
    const alloc = std.testing.allocator;
    const browser = try encodeRequestAlloc(alloc, .{
        .id = "thebird-1",
        .method = "Target.getTargets",
    });
    defer alloc.free(browser);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, browser, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("thebird-1", parsed.value.object.get("id").?.string);
    try std.testing.expectEqualStrings("Target.getTargets", parsed.value.object.get("method").?.string);
    try std.testing.expect(parsed.value.object.get("sessionId") == null);

    const session = try encodeRequestAlloc(alloc, .{
        .id = "thebird-2",
        .method = "Runtime.evaluate",
        .params_json = "{\"expression\":\"document.title\"}",
        .session_id = "birdman-tab-7",
    });
    defer alloc.free(session);
    var session_parsed = try std.json.parseFromSlice(std.json.Value, alloc, session, .{});
    defer session_parsed.deinit();
    try std.testing.expectEqualStrings("birdman-tab-7", session_parsed.value.object.get("sessionId").?.string);
    try std.testing.expectEqualStrings(
        "document.title",
        session_parsed.value.object.get("params").?.object.get("expression").?.string,
    );
}

test "native_browser cdp request rejects empty ids, empty methods, empty session ids and bad params" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidMethod, encodeRequestAlloc(alloc, .{ .id = "", .method = "Page.enable" }));
    try std.testing.expectError(error.InvalidMethod, encodeRequestAlloc(alloc, .{ .id = "x", .method = "" }));
    try std.testing.expectError(error.InvalidSessionId, encodeRequestAlloc(alloc, .{
        .id = "x",
        .method = "Page.enable",
        .session_id = "",
    }));
    try std.testing.expectError(error.InvalidParams, encodeRequestAlloc(alloc, .{
        .id = "x",
        .method = "Page.enable",
        .params_json = "{not json",
    }));
}

test "native_browser cdp response matches request id and reports CDP errors" {
    const alloc = std.testing.allocator;
    const response = try decodeResponseAlloc(
        alloc,
        "thebird-2",
        "{\"id\":\"thebird-2\",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}",
    );
    defer responseOwnedDeinit(alloc, response);
    try std.testing.expectEqualStrings("thebird-2", response.id);
    try std.testing.expectEqualStrings("Method not found", response.error_message.?);
    try std.testing.expectError(
        error.ResponseIdMismatch,
        decodeResponseAlloc(alloc, "thebird-2", "{\"id\":\"other\",\"result\":{}}"),
    );
    try std.testing.expectError(
        error.ResponseIdMismatch,
        decodeResponseAlloc(alloc, "thebird-2", "{\"result\":{}}"),
    );
}

test "native_browser cdp response treats a null error as success and keeps the result" {
    const alloc = std.testing.allocator;
    const response = try decodeResponseAlloc(
        alloc,
        "r-7",
        "{\"id\":\"r-7\",\"error\":null,\"result\":{\"frameId\":\"F-1\"}}",
    );
    defer responseOwnedDeinit(alloc, response);
    try std.testing.expect(response.error_message == null);
    const frame = (try resultStringAlloc(alloc, response.result_json, "frameId")).?;
    defer alloc.free(frame);
    try std.testing.expectEqualStrings("F-1", frame);
}

test "native_browser cdp response rejects a non-object root as malformed" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.MalformedResponse, decodeResponseAlloc(alloc, "r-1", "[1,2,3]"));
    try std.testing.expectError(error.SyntaxError, decodeResponseAlloc(alloc, "r-1", "{not json"));
}

test "native_browser cdp result field extraction reads the attached session id and rejects bad results" {
    const alloc = std.testing.allocator;
    const session_id = (try resultStringAlloc(alloc, "{\"sessionId\":\"S-42\"}", "sessionId")).?;
    defer alloc.free(session_id);
    try std.testing.expectEqualStrings("S-42", session_id);
    try std.testing.expect((try resultStringAlloc(alloc, "{}", "sessionId")) == null);
    try std.testing.expectError(error.ResponseError, resultStringAlloc(alloc, "{not json", "sessionId"));
}
