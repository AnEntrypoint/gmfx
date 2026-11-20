const std = @import("std");
const io_mod = @import("../shared/io.zig");
const markdown_agent = @import("../profiles/markdown_agent.zig");
const claude_marketplace = @import("claude_marketplace.zig");
const manifest = @import("manifest.zig");

const Allocator = std.mem.Allocator;

pub const passed_text = "Validation passed";
pub const passed_with_warnings_text = "Validation passed with warnings";
pub const failed_text = "Validation failed";
const skill_file_name = "SKILL.md";
const markdown_extension = ".md";
const max_component_bytes: usize = 1024 * 1024;

pub const Outcome = enum {
    passed,
    passed_with_warnings,
    failed,

    pub fn text(self: Outcome) []const u8 {
        return switch (self) {
            .passed => passed_text,
            .passed_with_warnings => passed_with_warnings_text,
            .failed => failed_text,
        };
    }
};

pub const Report = struct {
    outcome: Outcome,
    errors: []const []const u8 = &.{},
    warnings: []const []const u8 = &.{},

    pub fn render(self: Report, arena: Allocator) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.errors) |message| try out.appendSlice(arena, try std.fmt.allocPrint(arena, "error: {s}\n", .{message}));
        for (self.warnings) |message| try out.appendSlice(arena, try std.fmt.allocPrint(arena, "warning: {s}\n", .{message}));
        try out.appendSlice(arena, self.outcome.text());
        return out.items;
    }
};

const Findings = struct {
    arena: Allocator,
    errors: std.ArrayList([]const u8) = .empty,
    warnings: std.ArrayList([]const u8) = .empty,

    fn err(self: *Findings, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try self.errors.append(self.arena, try std.fmt.allocPrint(self.arena, fmt, args));
    }

    fn warn(self: *Findings, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try self.warnings.append(self.arena, try std.fmt.allocPrint(self.arena, fmt, args));
    }

    fn takeDiagnostics(self: *Findings, diagnostics: []const manifest.Diagnostic) Allocator.Error!void {
        for (diagnostics) |diagnostic| switch (diagnostic.severity) {
            .err => try self.errors.append(self.arena, diagnostic.message),
            .warn => try self.warnings.append(self.arena, diagnostic.message),
            .info => {},
        };
    }

    fn report(self: *Findings, strict: bool) Report {
        const outcome: Outcome = if (self.errors.items.len > 0)
            .failed
        else if (self.warnings.items.len == 0)
            .passed
        else if (strict)
            .failed
        else
            .passed_with_warnings;
        return .{ .outcome = outcome, .errors = self.errors.items, .warnings = self.warnings.items };
    }
};

pub fn validate(arena: Allocator, root: []const u8, strict: bool) !Report {
    var findings: Findings = .{ .arena = arena };
    const parsed = try manifest.parse(arena, root);
    const has_marketplace = try claude_marketplace.exists(arena, root);
    if (parsed.manifest_path == null and has_marketplace) {
        try findings.takeDiagnostics((try claude_marketplace.parseDir(arena, root)).diagnostics);
        return findings.report(strict);
    }
    try findings.takeDiagnostics(parsed.diagnostics);
    if (has_marketplace) try findings.takeDiagnostics((try claude_marketplace.parseDir(arena, root)).diagnostics);
    if (parsed.manifest) |loaded| {
        if (loaded.version == null) try findings.warn("\"version\" is not set", .{});
        if (loaded.description == null) try findings.warn("\"description\" is not set", .{});
        for (loaded.skills) |dir| {
            if (loaded.root_skill_fallback) {
                try checkSkill(&findings, dir, "the plugin root");
            } else {
                try checkSkillsDir(&findings, dir);
            }
        }
        for (loaded.commands) |command| try checkCommand(&findings, command);
        for (loaded.agents) |dir| try checkAgentsDir(&findings, dir);
    }
    return findings.report(strict);
}

fn checkSkillsDir(findings: *Findings, dir: []const u8) !void {
    const io = io_mod.getIo();
    var handle = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch {
        try findings.warn("skills directory cannot be read ({s})", .{dir});
        return;
    };
    defer handle.close(io);
    var entries = handle.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const skill_dir = try std.Io.Dir.path.join(findings.arena, &.{ dir, entry.name });
        try checkSkill(findings, skill_dir, entry.name);
    }
}

fn checkSkill(findings: *Findings, skill_dir: []const u8, label: []const u8) !void {
    const path = try std.Io.Dir.path.join(findings.arena, &.{ skill_dir, skill_file_name });
    const text = readComponent(findings.arena, path) orelse {
        try findings.warn("skill \"{s}\" has no readable {s}", .{ label, skill_file_name });
        return;
    };
    const document = try markdown_agent.parse(findings.arena, text);
    if (document.fields.len == 0) {
        try findings.err("skill \"{s}\" has no frontmatter in {s}", .{ label, skill_file_name });
        return;
    }
    if (fieldValue(document, "description") == null) try findings.warn("skill \"{s}\" has no description", .{label});
    if (fieldValue(document, "name")) |name| {
        if (!isComponentName(name)) try findings.err("skill \"{s}\" has an invalid name \"{s}\"", .{ label, name });
    }
}

fn checkCommand(findings: *Findings, command: manifest.Command) !void {
    const text = command.content orelse readComponent(findings.arena, command.path) orelse {
        try findings.err("command \"{s}\" cannot be read ({s})", .{ command.name, command.path });
        return;
    };
    if (opensFrontmatter(text) and (try markdown_agent.parse(findings.arena, text)).fields.len == 0) {
        try findings.err("command \"{s}\" has frontmatter that is empty or not closed", .{command.name});
    }
}

fn checkAgentsDir(findings: *Findings, dir: []const u8) !void {
    const io = io_mod.getIo();
    var handle = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch {
        try findings.warn("agents directory cannot be read ({s})", .{dir});
        return;
    };
    defer handle.close(io);
    var entries = handle.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, markdown_extension)) continue;
        const path = try std.Io.Dir.path.join(findings.arena, &.{ dir, entry.name });
        const text = readComponent(findings.arena, path) orelse {
            try findings.err("agent file {s} cannot be read", .{entry.name});
            continue;
        };
        const document = try markdown_agent.parse(findings.arena, text);
        if (fieldValue(document, "name") == null) try findings.err("agent file {s} has no name in its frontmatter", .{entry.name});
        if (fieldValue(document, "description") == null) try findings.err("agent file {s} has no description in its frontmatter", .{entry.name});
    }
}

fn readComponent(arena: Allocator, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), path, arena, .limited(max_component_bytes)) catch null;
}

fn opensFrontmatter(text: []const u8) bool {
    const line_end = std.mem.findScalar(u8, text, '\n') orelse text.len;
    return std.mem.eql(u8, std.mem.trimEnd(u8, text[0..line_end], "\r"), "---");
}

fn fieldValue(document: markdown_agent.Document, key: []const u8) ?[]const u8 {
    for (document.fields) |field| {
        if (!std.mem.eql(u8, field.key, key)) continue;
        return if (field.value.len == 0) null else field.value;
    }
    return null;
}

fn isComponentName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |byte| {
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '-') return false;
    }
    return true;
}

const testing = std.testing;

fn writeFixture(tmp: *testing.TmpDir, sub_path: []const u8, data: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |dir| try tmp.dir.createDirPath(testing.io, dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
}

test "validate passes a complete plugin and prints Validation passed" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, ".claude-plugin/plugin.json", "{\"name\":\"complete\",\"version\":\"1.0.0\",\"description\":\"Complete\"}");
    try writeFixture(&tmp, "skills/review/SKILL.md", "---\nname: review\ndescription: Reviews\n---\nReview.");
    try writeFixture(&tmp, "commands/go.md", "---\ndescription: Go\n---\nGo.");
    try writeFixture(&tmp, "agents/helper.md", "---\nname: helper\ndescription: Helps\n---\nHelp.");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    const report = try validate(arena, root, true);
    try testing.expectEqual(Outcome.passed, report.outcome);
    try testing.expectEqualStrings("Validation passed", try report.render(arena));
}

test "validate passes with warnings unless strict, which fails them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, ".claude-plugin/plugin.json", "{\"name\":\"sparse\",\"version\":\"1.0.0\"}");
    try writeFixture(&tmp, "skills/review/SKILL.md", "---\nname: review\n---\nReview.");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    const lenient = try validate(arena, root, false);
    try testing.expectEqual(Outcome.passed_with_warnings, lenient.outcome);
    try testing.expectEqual(@as(usize, 2), lenient.warnings.len);
    const rendered = try lenient.render(arena);
    try testing.expect(std.mem.startsWith(u8, rendered, "warning: \"description\" is not set\n"));
    try testing.expect(std.mem.endsWith(u8, rendered, "Validation passed with warnings"));

    const strict = try validate(arena, root, true);
    try testing.expectEqual(Outcome.failed, strict.outcome);
    try testing.expect(std.mem.endsWith(u8, try strict.render(arena), "Validation failed"));
}

test "validate fails on a missing manifest and on broken component frontmatter" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var empty = testing.tmpDir(.{});
    defer empty.cleanup();
    const empty_root = try empty.dir.realPathFileAlloc(testing.io, ".", arena);
    try testing.expectEqual(Outcome.failed, (try validate(arena, empty_root, false)).outcome);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, ".claude-plugin/plugin.json", "{\"name\":\"broken\",\"version\":\"1\",\"description\":\"Broken\"}");
    try writeFixture(&tmp, "skills/Bad/SKILL.md", "---\nname: Bad Name\ndescription: x\n---\n");
    try writeFixture(&tmp, "skills/plain/SKILL.md", "No frontmatter.");
    try writeFixture(&tmp, "commands/open.md", "---\ndescription: never closed\n");
    try writeFixture(&tmp, "agents/nameless.md", "---\ndescription: Nameless\n---\n");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);

    const report = try validate(arena, root, false);
    try testing.expectEqual(Outcome.failed, report.outcome);
    try testing.expectEqual(@as(usize, 4), report.errors.len);
    try testing.expectEqual(@as(usize, 0), report.warnings.len);
}

test "validate checks a marketplace directory that has no plugin manifest" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(&tmp, ".claude-plugin/marketplace.json", "{\"name\":\"m\",\"owner\":{\"name\":\"o\"},\"plugins\":[{\"name\":\"a\",\"source\":\"./a\"}]}");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", arena);
    try testing.expectEqual(Outcome.passed, (try validate(arena, root, true)).outcome);

    try writeFixture(&tmp, ".claude-plugin/marketplace.json", "{\"name\":\"m\",\"plugins\":[{\"name\":\"a\",\"source\":\"a\"}]}");
    const broken = try validate(arena, root, false);
    try testing.expectEqual(Outcome.failed, broken.outcome);
    try testing.expectEqual(@as(usize, 1), broken.errors.len);
}
