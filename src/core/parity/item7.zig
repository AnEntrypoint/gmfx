const std = @import("std");
const io_mod = @import("../shared/io.zig");
const item1 = @import("item1.zig");

const Allocator = std.mem.Allocator;
const mcp_rel = "mcp/server.json";

const Entry = struct {
    name: []const u8,
    passed: bool,
    detail: []const u8,
};

const Report = struct {
    item: u8,
    kind: []const u8,
    offline: bool,
    status: []const u8,
    ok: bool,
    root: []const u8,
    mcp_server_instructions: []const u8,
    resources: []const []const u8,
    entries: []const Entry,
};

pub fn json(alloc: Allocator, args: []const []const u8) ![]const u8 {
    _ = args;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = item1.envValue("FX_PARITY_CONTEXT_ROOT") orelse item1.envValue("HOME") orelse return error.MissingContextRoot;

    const mcp_text = (try item1.readOptional(a, try item1.join(a, root, mcp_rel))) orelse "";
    const resources = try item1.collectQuotedValues(a, mcp_text, "uri");
    const instructions = (try item1.quotedValue(a, mcp_text, "instructions")) orelse "";
    const skill_uri = item1.firstWithPrefix(resources, "skill://") orelse "";
    const skill = item1.resolveSkill(a, root, skill_uri) catch |err| switch (err) {
        error.InvalidSkillResource => item1.ResolvedSkill{ .path = "", .rel = "" },
        else => return err,
    };
    const skill_text = if (skill.path.len > 0) ((try item1.readOptional(a, skill.path)) orelse "") else "";
    const skill_dir = if (skill.path.len > 0) (std.Io.Dir.path.dirname(skill.path) orelse "") else "";
    const skill_dir_count = if (skill_dir.len > 0) try countEntries(skill_dir) else 0;

    const entries = [_]Entry{
        .{
            .name = "ListMcpResourcesTool",
            .passed = resources.len > 0,
            .detail = if (resources.len > 0) "uri entries listed from mcp/server.json" else "no uri entries in mcp/server.json",
        },
        .{
            .name = "ReadMcpResourceTool",
            .passed = skill_text.len > 0,
            .detail = if (skill_text.len > 0) "skill resource read from the skills directory" else "skill resource has no readable file under the context root",
        },
        .{
            .name = "ReadMcpResourceDirTool",
            .passed = skill_dir_count > 0,
            .detail = if (skill_dir_count > 0) "skill directory listed" else "skill directory is missing or empty",
        },
        .{
            .name = "MCP server instructions",
            .passed = instructions.len > 0,
            .detail = if (instructions.len > 0) "instructions read from mcp/server.json" else "no instructions in mcp/server.json",
        },
    };
    var ok = true;
    for (entries) |entry| {
        if (!entry.passed) ok = false;
    }
    const report = Report{
        .item = 7,
        .kind = "mcp-resources",
        .offline = true,
        .status = if (ok) "implemented" else "open",
        .ok = ok,
        .root = root,
        .mcp_server_instructions = instructions,
        .resources = resources,
        .entries = &entries,
    };
    const text = try std.json.Stringify.valueAlloc(a, report, .{});
    return try alloc.dupe(u8, text);
}

fn countEntries(path: []const u8) !usize {
    const zio = io_mod.getIo();
    var dir = std.Io.Dir.openDirAbsolute(zio, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(zio);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(zio)) |_| count += 1;
    return count;
}
