const std = @import("std");
const content = @import("content.zig");
const http_fetch = @import("http_fetch.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const url_policy = @import("url_policy.zig");

const Allocator = std.mem.Allocator;

const whitespace = " \t\r\n";

pub const accepted_fields = [_][]const u8{ "url", "timeout", "query", "regex" };
pub const max_query_bytes: usize = 1000;

const timeout_failure = std.fmt.comptimePrint(
    "FetchURL field \"timeout\" must be an integer from 1 to {d} seconds",
    .{http_fetch.max_call_timeout_seconds},
);
const query_failure = std.fmt.comptimePrint(
    "FetchURL field \"query\" must be a non-empty string of at most {d} bytes",
    .{max_query_bytes},
);

pub const Input = struct {
    url: []u8,
    timeout_seconds: ?u32 = null,
    query: ?[]u8 = null,
    query_is_regex: bool = false,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.url);
        if (self.query) |query| alloc.free(query);
        self.* = .{ .url = &.{} };
    }

    pub fn lineQuery(self: *const Input) ?content.LineQuery {
        const query = self.query orelse return null;
        return .{ .text = query, .is_regex = self.query_is_regex };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "FetchURL arguments must be valid JSON") };
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "FetchURL arguments must be an object") };
    }

    if (tool_args.firstUnknownKey(parsed.value.object, &accepted_fields)) |unknown| {
        return .{ .failure = try tool_args.unknownArgumentMessage(ctx.allocator, "FetchURL", unknown, &accepted_fields) };
    }

    const url_value = parsed.value.object.get("url") orelse {
        return .{ .failure = try ctx.allocator.dupe(u8, "FetchURL field \"url\" is required") };
    };
    if (url_value != .string) {
        return .{ .failure = try ctx.allocator.dupe(u8, "FetchURL field \"url\" must be a string") };
    }

    const timeout_seconds: ?u32 = if (parsed.value.object.get("timeout")) |value| switch (value) {
        .null => null,
        .integer => |seconds| if (seconds >= 1 and seconds <= http_fetch.max_call_timeout_seconds)
            @intCast(seconds)
        else
            return .{ .failure = try ctx.allocator.dupe(u8, timeout_failure) },
        else => return .{ .failure = try ctx.allocator.dupe(u8, timeout_failure) },
    } else null;

    const query_text: ?[]const u8 = if (parsed.value.object.get("query")) |value| switch (value) {
        .null => null,
        .string => |text| if (text.len == 0 or text.len > max_query_bytes)
            return .{ .failure = try ctx.allocator.dupe(u8, query_failure) }
        else
            text,
        else => return .{ .failure = try ctx.allocator.dupe(u8, query_failure) },
    } else null;

    const query_is_regex = if (parsed.value.object.get("regex")) |value| switch (value) {
        .null => false,
        .bool => |flag| flag,
        else => return .{ .failure = try ctx.allocator.dupe(u8, "FetchURL field \"regex\" must be a boolean") },
    } else false;
    if (query_is_regex and query_text == null) {
        return .{ .failure = try ctx.allocator.dupe(u8, "FetchURL field \"regex\" applies to \"query\"; pass a query") };
    }

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    const url = try ctx.allocator.dupe(u8, url_value.string);
    errdefer ctx.allocator.free(url);
    const query = if (query_text) |text| try ctx.allocator.dupe(u8, text) else null;
    input.* = .{
        .url = url,
        .timeout_seconds = timeout_seconds,
        .query = query,
        .query_is_regex = query_is_regex,
    };

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    if (input.lineQuery()) |line_query| {
        content.validateLineQuery(ctx.allocator, line_query) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPattern, error.TooComplex => return try ctx.allocator.dupe(
                u8,
                "FetchURL field \"query\" is not a valid regular expression; drop regex to match it as plain text",
            ),
        };
    }
    const trimmed = std.mem.trim(u8, input.url, whitespace);
    if (!std.mem.eql(u8, input.url, trimmed)) {
        const owned = try ctx.allocator.dupe(u8, trimmed);
        ctx.allocator.free(input.url);
        input.url = owned;
    }

    var normalized = url_policy.normalizeWith(ctx.allocator, input.url, ctx.host_fetch_loopback) catch |err| {
        return try ctx.allocator.dupe(u8, urlValidationMessage(err));
    };
    defer normalized.deinit(ctx.allocator);
    if (!std.mem.eql(u8, input.url, normalized.retrieval_url)) {
        const owned = try ctx.allocator.dupe(u8, normalized.retrieval_url);
        ctx.allocator.free(input.url);
        input.url = owned;
    }

    return null;
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

fn urlValidationMessage(err: url_policy.Error) []const u8 {
    return switch (err) {
        error.EmptyUrl => "FetchURL field \"url\" must not be empty",
        error.UrlTooLong => "FetchURL field \"url\" must be at most 2000 bytes",
        error.UnsupportedScheme => "web_fetch url must start with http:// or https://",
        error.MissingHost => "web_fetch url must include a host",
        error.CredentialedUrl => "web_fetch refuses credential-bearing URLs",
        error.NonPublicAddress,
        error.SingleLabelHost,
        => "web_fetch only fetches known public HTTP(S) URLs",
        error.MalformedPercentEncoding,
        error.PercentEncodedHost,
        error.UnicodeHost,
        error.ControlByte,
        error.InvalidPort,
        error.InvalidIpv4,
        error.ScopeIdRejected,
        error.MalformedHost,
        error.MalformedLocation,
        error.PortChanged,
        error.ProtocolChanged,
        error.RequestTargetWhitespace,
        error.OutOfMemory,
        error.WriteFailed,
        => "web_fetch url is malformed",
    };
}
