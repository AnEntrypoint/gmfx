const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");
const toml_reader = @import("../config/toml_reader.zig");
const workspace_config = @import("../mcp/workspace_config.zig");
const workspace_trust = @import("../mcp/workspace_trust.zig");
const shell_runtime = @import("../../ui/shell_runtime.zig");

const Allocator = std.mem.Allocator;

pub const title = "Trust this folder?";
pub const key_hint = "↑↓ navigate · Enter select · Esc exit";
pub const remembered_notice = "Trust is remembered for this folder, including future project config changes.";
pub const approvals_notice = "Tool approvals follow your permission settings.";
pub const nothing_to_activate = "No project integrations or instructions to activate.";
pub const inspection_failed_notice = "Could not inspect project settings.";
pub const option_labels = [_][]const u8{ "Trust and continue", "Exit" };

const select_pointer = "❯";
const raw_line_end = "\r\n";
const erase_line = "\r\x1b[2K";
const max_project_file_bytes: usize = 1024 * 1024;
const root_mcp_file = ".mcp.json";
const project_mcp_file = ".kimi-code/mcp.json";
const project_local_file = ".kimi-code/local.toml";
const instruction_file_names = [_][]const u8{ "AGENTS.md", "agents.md" };
const project_skills_dir = ".fx/skills";
const project_agents_dir = ".fx/agents";

pub const Disclosure = struct {
    mcp_servers: usize = 0,
    mcp_configs: []const []const u8 = &.{},
    outside_folders: usize = 0,
    outside_folder_config: ?[]const u8 = null,
    instruction_sources: []const []const u8 = &.{},
    has_instructions: bool = false,
    has_agent_profiles: bool = false,
    inspection_failed: bool = false,
};

pub fn collect(arena: Allocator, workspace_root: []const u8) Disclosure {
    return collectChecked(arena, workspace_root) catch .{ .inspection_failed = true };
}

fn collectChecked(arena: Allocator, workspace_root: []const u8) !Disclosure {
    var disclosure: Disclosure = .{};
    const project_root = try workspace_config.projectRoot(arena, workspace_root);

    var server_names: std.ArrayList([]const u8) = .empty;
    var configs: std.ArrayList([]const u8) = .empty;
    if (try workspace_config.readRootFile(arena, workspace_root)) |bytes| {
        const before = server_names.items.len;
        try addServerNames(arena, &server_names, bytes);
        if (server_names.items.len > before) {
            try configs.append(arena, try projectFileLabel(arena, workspace_root, project_root, root_mcp_file));
        }
    }
    if (try workspace_config.readProjectFile(arena, workspace_root)) |bytes| {
        const before = server_names.items.len;
        try addServerNames(arena, &server_names, bytes);
        if (server_names.items.len > before) try configs.append(arena, project_mcp_file);
    }
    disclosure.mcp_servers = server_names.items.len;
    disclosure.mcp_configs = configs.items;

    const local_path = try std.Io.Dir.path.join(arena, &.{ project_root, project_local_file });
    if (try readOptionalFile(arena, local_path)) |text| {
        disclosure.outside_folders = try additionalDirectoryCount(arena, text);
        if (disclosure.outside_folders > 0) {
            disclosure.outside_folder_config = try projectFileLabel(arena, workspace_root, project_root, project_local_file);
        }
    }

    var sources: std.ArrayList([]const u8) = .empty;
    for (instruction_file_names) |name| {
        if (try pathExists(arena, project_root, name)) {
            try sources.append(arena, try projectFileLabel(arena, workspace_root, project_root, name));
            disclosure.has_instructions = true;
            break;
        }
    }
    if (try pathExists(arena, project_root, project_skills_dir)) {
        try sources.append(arena, try projectFileLabel(arena, workspace_root, project_root, project_skills_dir));
        disclosure.has_instructions = true;
    }
    if (try pathExists(arena, project_root, project_agents_dir)) {
        try sources.append(arena, try projectFileLabel(arena, workspace_root, project_root, project_agents_dir));
        disclosure.has_agent_profiles = true;
    }
    disclosure.instruction_sources = sources.items;
    return disclosure;
}

fn addServerNames(arena: Allocator, names: *std.ArrayList([]const u8), bytes: []const u8) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    if (parsed != .object) return;
    const servers = parsed.object.get("mcpServers") orelse return;
    if (servers != .object) return;
    var iterator = servers.object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const known = for (names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) break true;
        } else false;
        if (!known) try names.append(arena, name);
    }
}

fn additionalDirectoryCount(arena: Allocator, text: []const u8) !usize {
    const document = try toml_reader.parse(arena, text);
    const workspace = document.object.get("workspace") orelse return 0;
    if (workspace != .object) return 0;
    const directories = workspace.object.get("additional_dir") orelse return 0;
    return switch (directories) {
        .array => |list| list.items.len,
        .string => 1,
        else => 0,
    };
}

fn projectFileLabel(arena: Allocator, workspace_root: []const u8, project_root: []const u8, relative: []const u8) ![]const u8 {
    if (std.mem.eql(u8, workspace_root, project_root)) return relative;
    return std.Io.Dir.path.join(arena, &.{ project_root, relative });
}

fn pathExists(arena: Allocator, root: []const u8, relative: []const u8) !bool {
    const path = try std.Io.Dir.path.join(arena, &.{ root, relative });
    if (std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{ .follow_symlinks = true })) |_| {
        return true;
    } else |_| {
        return false;
    }
}

fn readOptionalFile(arena: Allocator, path: []const u8) !?[]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), path, arena, .limited(max_project_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return bytes;
}

fn writeJoined(writer: *std.Io.Writer, items: []const []const u8, separator: []const u8) std.Io.Writer.Error!void {
    for (items, 0..) |item, index| {
        if (index > 0) try writer.writeAll(separator);
        try writer.print("{f}", .{text_utils.terminalSafe(item)});
    }
}

pub fn writeDisclosure(writer: *std.Io.Writer, disclosure: Disclosure, line_end: []const u8) std.Io.Writer.Error!void {
    var wrote_line = false;
    if (disclosure.mcp_servers > 0) {
        try writer.print(" Start {d} MCP {s} automatically{s}", .{
            disclosure.mcp_servers,
            if (disclosure.mcp_servers == 1) "server" else "servers",
            line_end,
        });
        try writer.writeAll("   Config: ");
        try writeJoined(writer, disclosure.mcp_configs, ", ");
        try writer.print("{s}{s}", .{ line_end, line_end });
        wrote_line = true;
    }
    if (disclosure.outside_folders > 0) {
        try writer.print(" Access {d} {s} outside this project{s}", .{
            disclosure.outside_folders,
            if (disclosure.outside_folders == 1) "folder" else "folders",
            line_end,
        });
        if (disclosure.outside_folder_config) |config| {
            try writer.print("   Config: {f}{s}", .{ text_utils.terminalSafe(config), line_end });
        }
        try writer.writeAll(line_end);
        wrote_line = true;
    }
    if (disclosure.instruction_sources.len > 0) {
        const subject = if (disclosure.has_instructions)
            (if (disclosure.has_agent_profiles) "instructions and agent profiles" else "instructions")
        else
            "agent profiles";
        try writer.print(" Load project {s}{s}", .{ subject, line_end });
        try writer.writeAll("   Check: ");
        try writeJoined(writer, disclosure.instruction_sources, " · ");
        try writer.print("{s}{s}", .{ line_end, line_end });
        wrote_line = true;
    }
    if (disclosure.inspection_failed) {
        try writer.print(" {s}{s}", .{ inspection_failed_notice, line_end });
        wrote_line = true;
    }
    if (!wrote_line) try writer.print(" {s}{s}{s}", .{ nothing_to_activate, line_end, line_end });
}

pub fn writeOptions(writer: *std.Io.Writer, selected: usize, line_end: []const u8) std.Io.Writer.Error!void {
    for (option_labels, 0..) |label, index| {
        try writer.print("{s}  {s} {s}{s}", .{
            erase_line,
            if (index == selected) select_pointer else " ",
            label,
            line_end,
        });
    }
}

pub fn writePrompt(
    writer: *std.Io.Writer,
    workspace_root: []const u8,
    disclosure: Disclosure,
    selected: usize,
    line_end: []const u8,
) std.Io.Writer.Error!void {
    try writer.print(" {s}{s}", .{ title, line_end });
    try writer.print(" {s}{s}{s}", .{ key_hint, line_end, line_end });
    try writer.print(" {f}{s}{s}", .{ text_utils.terminalSafe(workspace_root), line_end, line_end });
    try writeDisclosure(writer, disclosure, line_end);
    try writer.print(" {s}{s}", .{ remembered_notice, line_end });
    try writer.print(" {s}{s}{s}", .{ approvals_notice, line_end, line_end });
    try writeOptions(writer, selected, line_end);
}

pub const Key = enum { up, down, confirm, exit, ignored };

pub fn decodeKey(bytes: []const u8) Key {
    if (bytes.len == 0) return .ignored;
    if (std.mem.eql(u8, bytes, "\x1b") or bytes[0] == 0x03 or bytes[0] == 0x04) return .exit;
    if (bytes[0] == '\r' or bytes[0] == '\n' or bytes[0] == ' ') return .confirm;
    if (std.mem.eql(u8, bytes, "\x1b[A") or std.mem.eql(u8, bytes, "\x1bOA")) return .up;
    if (std.mem.eql(u8, bytes, "\x1b[B") or std.mem.eql(u8, bytes, "\x1bOB")) return .down;
    return .ignored;
}

pub const Step = union(enum) {
    stay,
    select: usize,
    choose: workspace_trust.PromptChoice,
};

pub fn step(selected: usize, key: Key) Step {
    return switch (key) {
        .up => .{ .select = selected -| 1 },
        .down => .{ .select = @min(selected + 1, option_labels.len - 1) },
        .confirm => .{ .choose = if (selected == 0) .trust else .distrust },
        .exit => .{ .choose = .distrust },
        .ignored => .stay,
    };
}

pub fn chooseWithKeys(workspace_root: []const u8) !?workspace_trust.PromptChoice {
    if (comptime builtin.target.os.tag == .wasi) return null;
    var terminal: shell_runtime.TerminalState = .{};
    terminal.captureOriginalTermios() catch return null;
    terminal.enableRawMode() catch return null;
    defer terminal.disableRawMode();

    var arena_state: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const stdout = std.Io.File.stdout();
    const zio = io_mod.getIo();

    var selected: usize = 0;
    var frame: std.Io.Writer.Allocating = .init(arena);
    try writePrompt(&frame.writer, workspace_root, collect(arena, workspace_root), selected, raw_line_end);
    try stdout.writeStreamingAll(zio, frame.written());

    var input: [32]u8 = undefined;
    while (true) {
        const count = terminal.read(&input) catch return .distrust;
        if (count == 0) return .distrust;
        switch (step(selected, decodeKey(input[0..count]))) {
            .stay => {},
            .select => |index| {
                selected = index;
                var options: std.Io.Writer.Allocating = .init(arena);
                try options.writer.print("\x1b[{d}A", .{option_labels.len});
                try writeOptions(&options.writer, selected, raw_line_end);
                try stdout.writeStreamingAll(zio, options.written());
            },
            .choose => |choice| return choice,
        }
    }
}

fn writeFixtureFile(tmp: *std.testing.TmpDir, sub_path: []const u8, content: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| try tmp.dir.createDirPath(io_mod.getIo(), parent);
    var file = try tmp.dir.createFile(io_mod.getIo(), sub_path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn renderForTest(alloc: Allocator, workspace_root: []const u8, disclosure: Disclosure, selected: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writePrompt(&out.writer, workspace_root, disclosure, selected, "\n");
    return alloc.dupe(u8, out.written());
}

test "the trust prompt for a folder with nothing to activate shows Kimi's title, notices and two options" {
    const alloc = std.testing.allocator;
    const text = try renderForTest(alloc, "/Users/example/project", .{}, 0);
    defer alloc.free(text);

    const expected =
        " Trust this folder?\n" ++
        " ↑↓ navigate · Enter select · Esc exit\n" ++
        "\n" ++
        " /Users/example/project\n" ++
        "\n" ++
        " No project integrations or instructions to activate.\n" ++
        "\n" ++
        " Trust is remembered for this folder, including future project config changes.\n" ++
        " Tool approvals follow your permission settings.\n" ++
        "\n" ++
        "\r\x1b[2K  ❯ Trust and continue\n" ++
        "\r\x1b[2K    Exit\n";
    try std.testing.expectEqualStrings(expected, text);
}

test "the trust prompt moves the pointer to the selected option" {
    const alloc = std.testing.allocator;
    const text = try renderForTest(alloc, "/Users/example/project", .{}, 1);
    defer alloc.free(text);
    try std.testing.expect(std.mem.find(u8, text, "    Trust and continue\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "  ❯ Exit\n") != null);
}

test "the trust disclosure names servers, outside folders and instructions with singular and plural nouns" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeDisclosure(&out.writer, .{
        .mcp_servers = 2,
        .mcp_configs = &.{ ".mcp.json", ".kimi-code/mcp.json" },
        .outside_folders = 1,
        .outside_folder_config = ".kimi-code/local.toml",
        .instruction_sources = &.{ "AGENTS.md", ".fx/agents" },
        .has_instructions = true,
        .has_agent_profiles = true,
    }, "\n");
    try std.testing.expectEqualStrings(
        " Start 2 MCP servers automatically\n" ++
            "   Config: .mcp.json, .kimi-code/mcp.json\n" ++
            "\n" ++
            " Access 1 folder outside this project\n" ++
            "   Config: .kimi-code/local.toml\n" ++
            "\n" ++
            " Load project instructions and agent profiles\n" ++
            "   Check: AGENTS.md · .fx/agents\n" ++
            "\n",
        out.written(),
    );

    var single: std.Io.Writer.Allocating = .init(alloc);
    defer single.deinit();
    try writeDisclosure(&single.writer, .{
        .mcp_servers = 1,
        .mcp_configs = &.{".mcp.json"},
        .outside_folders = 3,
        .instruction_sources = &.{".fx/agents"},
        .has_agent_profiles = true,
    }, "\n");
    try std.testing.expect(std.mem.find(u8, single.written(), " Start 1 MCP server automatically\n") != null);
    try std.testing.expect(std.mem.find(u8, single.written(), " Access 3 folders outside this project\n") != null);
    try std.testing.expect(std.mem.find(u8, single.written(), " Load project agent profiles\n") != null);

    var failed: std.Io.Writer.Allocating = .init(alloc);
    defer failed.deinit();
    try writeDisclosure(&failed.writer, .{ .inspection_failed = true }, "\n");
    try std.testing.expectEqualStrings(" Could not inspect project settings.\n", failed.written());
}

test "the trust disclosure is collected from the project files and counts a shadowed server once" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.git");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.fx/agents");
    try tmp.dir.createDirPath(io_mod.getIo(), "empty/.git");
    try writeFixtureFile(&tmp, "workspace/.mcp.json", "{\"mcpServers\":{\"a\":{\"command\":\"a-server\"},\"b\":{\"command\":\"b-server\"}}}");
    try writeFixtureFile(&tmp, "workspace/.kimi-code/mcp.json", "{\"mcpServers\":{\"b\":{\"command\":\"other\"},\"c\":{\"command\":\"c-server\"}}}");
    try writeFixtureFile(&tmp, "workspace/.kimi-code/local.toml", "[workspace]\nadditional_dir = [\"/Users/example/shared\", \"/Users/example/other\"]\n");
    try writeFixtureFile(&tmp, "workspace/AGENTS.md", "rules\n");
    const root = try io_mod.dirRealpathAlloc(arena, tmp.dir, "workspace");
    const empty = try io_mod.dirRealpathAlloc(arena, tmp.dir, "empty");

    const disclosure = collect(arena, root);
    try std.testing.expect(!disclosure.inspection_failed);
    try std.testing.expectEqual(@as(usize, 3), disclosure.mcp_servers);
    try std.testing.expectEqual(@as(usize, 2), disclosure.mcp_configs.len);
    try std.testing.expectEqualStrings(".mcp.json", disclosure.mcp_configs[0]);
    try std.testing.expectEqualStrings(".kimi-code/mcp.json", disclosure.mcp_configs[1]);
    try std.testing.expectEqual(@as(usize, 2), disclosure.outside_folders);
    try std.testing.expectEqualStrings(".kimi-code/local.toml", disclosure.outside_folder_config.?);
    try std.testing.expect(disclosure.has_instructions);
    try std.testing.expect(disclosure.has_agent_profiles);
    try std.testing.expectEqual(@as(usize, 2), disclosure.instruction_sources.len);
    try std.testing.expectEqualStrings("AGENTS.md", disclosure.instruction_sources[0]);
    try std.testing.expectEqualStrings(".fx/agents", disclosure.instruction_sources[1]);

    const nothing = collect(arena, empty);
    try std.testing.expect(!nothing.inspection_failed);
    try std.testing.expectEqual(@as(usize, 0), nothing.mcp_servers);
    try std.testing.expectEqual(@as(usize, 0), nothing.outside_folders);
    try std.testing.expectEqual(@as(usize, 0), nothing.instruction_sources.len);
}

test "a project config that cannot be parsed is reported as an inspection failure" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.git");
    try writeFixtureFile(&tmp, "workspace/.mcp.json", "{not json");
    const root = try io_mod.dirRealpathAlloc(arena, tmp.dir, "workspace");

    try std.testing.expect(collect(arena, root).inspection_failed);
}

test "trust prompt keys: arrows move, Enter and Space confirm, Esc and Ctrl-C exit" {
    try std.testing.expectEqual(Key.up, decodeKey("\x1b[A"));
    try std.testing.expectEqual(Key.up, decodeKey("\x1bOA"));
    try std.testing.expectEqual(Key.down, decodeKey("\x1b[B"));
    try std.testing.expectEqual(Key.down, decodeKey("\x1bOB"));
    try std.testing.expectEqual(Key.confirm, decodeKey("\r"));
    try std.testing.expectEqual(Key.confirm, decodeKey("\n"));
    try std.testing.expectEqual(Key.confirm, decodeKey(" "));
    try std.testing.expectEqual(Key.exit, decodeKey("\x1b"));
    try std.testing.expectEqual(Key.exit, decodeKey("\x03"));
    try std.testing.expectEqual(Key.exit, decodeKey("\x04"));
    try std.testing.expectEqual(Key.ignored, decodeKey("x"));
    try std.testing.expectEqual(Key.ignored, decodeKey("\x1b[C"));
    try std.testing.expectEqual(Key.ignored, decodeKey(""));
}

test "trust prompt steps: Enter trusts on the first row and exits on the second, Esc always exits" {
    try std.testing.expectEqual(Step{ .choose = .trust }, step(0, .confirm));
    try std.testing.expectEqual(Step{ .choose = .distrust }, step(1, .confirm));
    try std.testing.expectEqual(Step{ .choose = .distrust }, step(0, .exit));
    try std.testing.expectEqual(Step{ .select = 1 }, step(0, .down));
    try std.testing.expectEqual(Step{ .select = 1 }, step(1, .down));
    try std.testing.expectEqual(Step{ .select = 0 }, step(1, .up));
    try std.testing.expectEqual(Step{ .select = 0 }, step(0, .up));
    try std.testing.expectEqual(Step.stay, step(0, .ignored));
}
