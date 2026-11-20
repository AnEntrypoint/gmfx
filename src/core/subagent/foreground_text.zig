const std = @import("std");
const child_state = @import("child_state.zig");

const Allocator = std.mem.Allocator;

const summary_marker = "[summary]\n";
const resume_marker = "\n\nresume_hint: ";
const failed_prefix = "Subagent failed: ";
const failed_suffix = ". Earlier tool calls may have completed; their effects are not rolled back.";

pub const StopReason = enum { completed, failed, cancelled, stopped };

pub const Parsed = struct {
    agent: []const u8,
    profile: []const u8,
    stop_reason: StopReason,
    output: []const u8,

    pub fn failureReason(self: Parsed) ?[]const u8 {
        if (self.stop_reason != .failed) return null;
        if (!std.mem.startsWith(u8, self.output, failed_prefix)) return null;
        const rest = self.output[failed_prefix.len..];
        const end = std.mem.find(u8, rest, failed_suffix) orelse return rest;
        return rest[0..end];
    }
};

const transport_failure_codes = [_][]const u8{
    "provider_http_error",
    "NetworkInterrupted",
    "ConnectionUnavailable",
    "StreamInterrupted",
    "gateway_stream_timeout",
    "provider_error",
    "HTTP 429",
    "agent_turn_failed: ProviderFailed",
    "agent_execution: ProviderFailed",
};

pub fn isTransportFailure(reason: []const u8) bool {
    for (transport_failure_codes) |code| {
        if (std.mem.startsWith(u8, reason, code)) return true;
    }
    return false;
}

pub fn format(
    alloc: Allocator,
    agent: []const u8,
    profile: []const u8,
    outcome: child_state.Outcome,
    output: []const u8,
) ![]u8 {
    const completed = outcome == .completed;
    const stop_reason = switch (outcome) {
        .completed => "completed",
        .failed => "error",
        .cancelled => "cancelled",
        .interrupted, .lost => "stopped",
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("agent_id: {s}\nactual_subagent_type: {s}\nstatus: {s}\nstop_reason: {s}\n\n", .{
        agent,
        profile,
        if (completed) "completed" else "failed",
        stop_reason,
    });
    if (completed) try out.writer.writeAll(summary_marker);
    try out.writer.print("{s}\n", .{output});
    if (outcome != .cancelled) {
        try out.writer.print("\nresume_hint: To continue this subagent, call Agent with resume \"{s}\" and a prompt.", .{agent});
    }
    return out.toOwnedSlice();
}

pub fn parse(text: []const u8) ?Parsed {
    const header_end = std.mem.find(u8, text, "\n\n") orelse return null;
    var agent: ?[]const u8 = null;
    var profile: ?[]const u8 = null;
    var stop_reason: ?StopReason = null;
    var lines = std.mem.splitScalar(u8, text[0..header_end], '\n');
    while (lines.next()) |line| {
        if (headerValue(line, "agent_id: ")) |value| agent = value;
        if (headerValue(line, "actual_subagent_type: ")) |value| profile = value;
        if (headerValue(line, "stop_reason: ")) |value| {
            stop_reason = if (std.mem.eql(u8, value, "completed"))
                .completed
            else if (std.mem.eql(u8, value, "error"))
                .failed
            else if (std.mem.eql(u8, value, "cancelled"))
                .cancelled
            else if (std.mem.eql(u8, value, "stopped"))
                .stopped
            else
                return null;
        }
    }
    var body = text[header_end + 2 ..];
    if (std.mem.findLast(u8, body, resume_marker)) |index| body = body[0..index];
    if (std.mem.startsWith(u8, body, summary_marker)) body = body[summary_marker.len..];
    if (std.mem.endsWith(u8, body, "\n")) body = body[0 .. body.len - 1];
    return .{
        .agent = agent orelse return null,
        .profile = profile orelse return null,
        .stop_reason = stop_reason orelse return null,
        .output = body,
    };
}

fn headerValue(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    return line[key.len..];
}

test "foreground text parses back to the agent, profile, stop reason and output it was formatted from" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { outcome: child_state.Outcome, output: []const u8, stop_reason: StopReason }{
        .{ .outcome = .completed, .output = "{\"path\":\"a.zig\"}\n\nsecond paragraph", .stop_reason = .completed },
        .{ .outcome = .failed, .output = "Subagent failed: provider_http_error: 503. Earlier tool calls may have completed; their effects are not rolled back.", .stop_reason = .failed },
        .{ .outcome = .cancelled, .output = "Its turn was cancelled before it finished.", .stop_reason = .cancelled },
        .{ .outcome = .interrupted, .output = "fx stopped before it finished.", .stop_reason = .stopped },
        .{ .outcome = .lost, .output = "never ran", .stop_reason = .stopped },
    };
    for (cases) |case| {
        const text = try format(alloc, "agent-call-1", "explore", case.outcome, case.output);
        defer alloc.free(text);
        const parsed = parse(text).?;
        try std.testing.expectEqualStrings("agent-call-1", parsed.agent);
        try std.testing.expectEqualStrings("explore", parsed.profile);
        try std.testing.expectEqual(case.stop_reason, parsed.stop_reason);
        try std.testing.expectEqualStrings(case.output, parsed.output);
    }
    try std.testing.expect(parse("not a foreground result") == null);
}

test "foreground failure reason is read from the failed sentence and classed as transport by its code" {
    const alloc = std.testing.allocator;
    const text = try format(alloc, "a", "coder", .failed, "Subagent failed: provider_http_error: 503. Earlier tool calls may have completed; their effects are not rolled back.\n\nPartial result:\nhalf");
    defer alloc.free(text);
    const parsed = parse(text).?;
    try std.testing.expectEqualStrings("provider_http_error: 503", parsed.failureReason().?);
    try std.testing.expect(isTransportFailure(parsed.failureReason().?));
    try std.testing.expect(isTransportFailure("StreamInterrupted"));
    try std.testing.expect(isTransportFailure("agent_turn_failed: ProviderFailed"));
    try std.testing.expect(!isTransportFailure("agent_turn_failed: SessionCommitFailed"));
    try std.testing.expect(!isTransportFailure("model_credential_missing: openai/gpt-5"));
}
