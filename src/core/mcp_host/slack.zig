const std = @import("std");
const io_mod = @import("../shared/io.zig");

pub const server_url = "https://mcp.slack.com/mcp";

pub const client_id = "12364000946.12017137861236";

pub const callback_port: u16 = 3118;

pub const scopes = "channels:history channels:read channels:write chat:write emoji:read files:write groups:history groups:read im:history im:read mpim:history mpim:read search:read.im search:read.mpim search:read.private search:read.public search:read.users users:read";

pub fn isSlack(url: ?[]const u8) bool {
    const u = url orelse return false;
    return std.mem.eql(u8, u, "https://mcp.slack.com") or std.mem.startsWith(u8, u, "https://mcp.slack.com/");
}

fn standIn() ?[]const u8 {
    const configured = io_mod.getenv("FX_TEST_SLACK_ORIGIN") orelse return null;
    return if (loopbackOrigin(configured)) configured else null;
}

pub fn appServer(url: ?[]const u8) bool {
    return appServerAt(url orelse return false, standIn());
}

fn appServerAt(url: []const u8, stand_in: ?[]const u8) bool {
    if (isSlack(url)) return true;
    const o = stand_in orelse return false;
    return std.mem.startsWith(u8, url, o) and std.mem.eql(u8, url[o.len..], "/mcp");
}

fn loopbackOrigin(o: []const u8) bool {
    const prefix = "http://127.0.0.1:";
    if (!std.mem.startsWith(u8, o, prefix)) return false;
    const port = std.fmt.parseInt(u16, o[prefix.len..], 10) catch return false;
    return port >= 1024;
}

const testing = std.testing;

test "only Slack's MCP server, and only a loopback test stand-in" {
    try testing.expect(isSlack("https://mcp.slack.com/mcp"));
    try testing.expect(isSlack("https://mcp.slack.com"));
    try testing.expect(!isSlack("https://mcp.slack.com.evil.example/mcp"));
    try testing.expect(!isSlack(null));
    try testing.expect(loopbackOrigin("http://127.0.0.1:8080"));
    try testing.expect(!loopbackOrigin("http://127.0.0.1:80"));
    try testing.expect(!loopbackOrigin("https://evil.example"));
    try testing.expect(!loopbackOrigin("http://127.0.0.1:8080/x"));
}

test "fx's Slack app signs in only to Slack's MCP server, or a test stand-in's own" {
    try testing.expect(appServerAt("https://mcp.slack.com/mcp", null));
    try testing.expect(!appServerAt("https://mcp.example.com/mcp", null));
    try testing.expect(!appServerAt("http://127.0.0.1:8080/mcp", null));
    try testing.expect(appServerAt("http://127.0.0.1:8080/mcp", "http://127.0.0.1:8080"));
    try testing.expect(appServerAt("https://mcp.slack.com/mcp", "http://127.0.0.1:8080"));
    try testing.expect(!appServerAt("http://127.0.0.1:9090/mcp", "http://127.0.0.1:8080"));
    try testing.expect(!appServerAt("http://127.0.0.1:80800/mcp", "http://127.0.0.1:8080"));
    try testing.expect(!appServerAt("http://127.0.0.1:8080/other", "http://127.0.0.1:8080"));
    try testing.expect(!appServer(null));
}
