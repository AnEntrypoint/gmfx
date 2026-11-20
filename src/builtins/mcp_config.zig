const std = @import("std");

const Allocator = std.mem.Allocator;

pub const command = "/mcp-config";
pub const summary = "Configure MCP servers and handle MCP OAuth login.";
pub const instructions = @embedFile("mcp_config.md");

pub const Request = union(enum) {
    login: ?[]const u8,
    edit: ?[]const u8,
};

pub fn parse(rest: []const u8) Request {
    const text = std.mem.trim(u8, rest, " \t\r\n");
    if (text.len == 0) return .{ .edit = null };
    var words = std.mem.tokenizeAny(u8, text, " \t");
    const first = words.next().?;
    if (!std.mem.eql(u8, first, "login")) return .{ .edit = text };
    const server = words.next() orelse return .{ .login = null };
    if (words.next() != null) return .{ .edit = text };
    return .{ .login = server };
}

pub fn prompt(alloc: Allocator, rest: []const u8) Allocator.Error![]u8 {
    return switch (parse(rest)) {
        .login => |named| if (named) |server|
            std.fmt.allocPrint(
                alloc,
                "{s}\n## The user's request\n\n`{s} login {s}`: log in to the MCP server `{s}` by calling its `mcp__{s}__authenticate` tool.\n",
                .{ instructions, command, server, server, server },
            )
        else
            std.fmt.allocPrint(
                alloc,
                "{s}\n## The user's request\n\n`{s} login`: log in to the MCP server that is waiting for a login.\n",
                .{ instructions, command },
            ),
        .edit => |described| if (described) |text|
            std.fmt.allocPrint(alloc, "{s}\n## The user's request\n\n`{s}` {s}\n", .{ instructions, command, text })
        else
            std.fmt.allocPrint(alloc, "{s}\n## The user's request\n\n`{s}` with no arguments.\n", .{ instructions, command }),
    };
}

test "/mcp-config login NAME is the login flow, and anything else describes a config edit" {
    try std.testing.expect(parse("  ").edit == null);
    try std.testing.expect(parse("login").login == null);
    try std.testing.expectEqualStrings("linear", parse(" login  linear ").login.?);
    try std.testing.expectEqualStrings("add a filesystem server for /tmp", parse(" add a filesystem server for /tmp ").edit.?);
    try std.testing.expectEqualStrings("login to linear please", parse("login to linear please").edit.?);
    try std.testing.expectEqualStrings("list", parse("list").edit.?);
}

test "the /mcp-config prompt carries the instructions and routes a login to the server's authenticate tool" {
    const alloc = std.testing.allocator;
    const login = try prompt(alloc, "login linear");
    defer alloc.free(login);
    try std.testing.expect(std.mem.startsWith(u8, login, "# Interactive MCP server configuration"));
    try std.testing.expect(std.mem.endsWith(
        u8,
        login,
        "`/mcp-config login linear`: log in to the MCP server `linear` by calling its `mcp__linear__authenticate` tool.\n",
    ));

    const edit = try prompt(alloc, "remove the docs server");
    defer alloc.free(edit);
    try std.testing.expect(std.mem.endsWith(u8, edit, "## The user's request\n\n`/mcp-config` remove the docs server\n"));

    const bare = try prompt(alloc, "");
    defer alloc.free(bare);
    try std.testing.expect(std.mem.endsWith(u8, bare, "`/mcp-config` with no arguments.\n"));
}

test "the /mcp-config instructions name the files fx reads and the flows Kimi's skill has" {
    for ([_][]const u8{
        "`mcp__<server>__authenticate`",
        "## Login",
        "## Config edit",
        "## Secrets",
        "`<FX_HOME>/mcp.json`",
        "`<project root>/.mcp.json`",
        "`<cwd>/.kimi-code/mcp.json`",
        "{ \"mcpServers\": { \"<name>\": { /* entry */ } } }",
        "`bearerTokenEnvVar: \"ENV_NAME\"`",
        "start a new session (for example `/new`) or restart `fx`",
    }) |expected| {
        try std.testing.expect(std.mem.find(u8, instructions, expected) != null);
    }
    try std.testing.expect(std.mem.find(u8, instructions, "KIMI_CODE_HOME") == null);
    try std.testing.expect(std.mem.find(u8, instructions, "config.toml") == null);
}
