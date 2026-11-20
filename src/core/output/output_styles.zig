const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;

pub const default_name = "Default";
pub const directory_name = "output-styles";
pub const project_directory = ".fx/output-styles";
pub const max_style_bytes: usize = 256 * 1024;

pub const Builtin = struct {
    name: []const u8,
    description: []const u8,
    instructions: []const u8,
};

pub const builtin_styles = [_]Builtin{
    .{
        .name = default_name,
        .description = "fx's standard way of working and replying",
        .instructions = "",
    },
    .{
        .name = "Proactive",
        .description = "Acts on reasonable assumptions and keeps going instead of stopping to ask",
        .instructions =
        \\# Output style: Proactive
        \\Work with initiative. When a choice is reversible, make the most reasonable assumption, say in one line what you assumed, and keep going instead of stopping to ask.
        \\Carry a task through its obvious next steps: after a change, run the checks that prove it, and fix what they show.
        \\Stop and ask only before something destructive, something that cannot be undone, or a choice the request leaves truly open.
        ,
    },
    .{
        .name = "Concise",
        .description = "Short replies: the answer first, no preamble, no recap",
        .instructions =
        \\# Output style: Concise
        \\Keep replies short. Lead with the answer or the result, in as few words as carry it.
        \\Leave out preamble, restating the request, and closing summaries of what was just shown.
        \\Use a list or a code block only when it is shorter than the sentence it replaces.
        ,
    },
    .{
        .name = "Explanatory",
        .description = "Explains the reasons behind choices and how the codebase works while doing the task",
        .instructions =
        \\# Output style: Explanatory
        \\Do the task as usual, and teach along the way. Before or after a meaningful change, add a short insight: why this approach was chosen, what pattern the codebase follows here, and what trade-off was accepted.
        \\Keep each insight specific to this codebase and to the code just read or written, not general programming advice.
        ,
    },
    .{
        .name = "Learning",
        .description = "Pairs with you: explains, then leaves small, well-chosen pieces for you to write",
        .instructions =
        \\# Output style: Learning
        \\Work as a pair with someone who wants to learn by doing. Explain the reasons behind choices as in the Explanatory style.
        \\When a change contains a small, meaningful decision, such as a function body of a few lines, leave it for the user: mark the spot with a TODO(human) line, say what to write and what to consider, and wait for them before continuing.
        \\Ask for at most one such piece at a time, and do the routine parts yourself.
        ,
    },
};

pub fn findBuiltin(name: []const u8) ?Builtin {
    for (builtin_styles) |style| {
        if (std.mem.eql(u8, style.name, name)) return style;
    }
    return null;
}

pub const Custom = struct {
    name: []u8,
    description: []u8,
    instructions: []u8,
    keep_coding_instructions: bool = false,
    force_for_plugin: bool = false,

    pub fn deinit(self: *Custom, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.description);
        alloc.free(self.instructions);
        self.* = undefined;
    }
};

const Frontmatter = struct {
    fields: []const u8,
    body: []const u8,
};

fn splitFrontmatter(text: []const u8) Frontmatter {
    const opening = "---\n";
    if (!std.mem.startsWith(u8, text, opening)) return .{ .fields = "", .body = text };
    const after_opening = text[opening.len..];
    var offset: usize = 0;
    while (offset <= after_opening.len) {
        const line_end = std.mem.findScalarPos(u8, after_opening, offset, '\n') orelse after_opening.len;
        const line = std.mem.trimEnd(u8, after_opening[offset..line_end], " \t\r");
        if (std.mem.eql(u8, line, "---")) {
            const body_start = @min(line_end + 1, after_opening.len);
            return .{ .fields = after_opening[0..offset], .body = after_opening[body_start..] };
        }
        if (line_end == after_opening.len) break;
        offset = line_end + 1;
    }
    return .{ .fields = "", .body = text };
}

fn fieldValue(fields: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, fields, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " \t"), key)) continue;
        var value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0]) {
            value = value[1 .. value.len - 1];
        }
        return value;
    }
    return null;
}

fn fieldFlag(fields: []const u8, key: []const u8) bool {
    const value = fieldValue(fields, key) orelse return false;
    return std.ascii.eqlIgnoreCase(value, "true");
}

pub fn parseCustom(alloc: Allocator, file_stem: []const u8, text: []const u8) Allocator.Error!Custom {
    const split = splitFrontmatter(text);
    const named = fieldValue(split.fields, "name") orelse "";
    const name = try alloc.dupe(u8, if (named.len > 0) named else file_stem);
    errdefer alloc.free(name);
    const description = try alloc.dupe(u8, fieldValue(split.fields, "description") orelse "");
    errdefer alloc.free(description);
    const instructions = try alloc.dupe(u8, std.mem.trim(u8, split.body, " \t\r\n"));
    return .{
        .name = name,
        .description = description,
        .instructions = instructions,
        .keep_coding_instructions = fieldFlag(split.fields, "keep-coding-instructions"),
        .force_for_plugin = fieldFlag(split.fields, "force-for-plugin"),
    };
}

pub fn findCustomIn(alloc: Allocator, dir: std.Io.Dir, name: []const u8) Allocator.Error!?Custom {
    const suffix = ".md";
    var entries = dir.iterate();
    while (entries.next(io_mod.getIo()) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        var file = io_mod.openExistingRegularFile(dir, entry.name, .read_only) catch continue;
        defer file.close(io_mod.getIo());
        const bytes = io_mod.readFileToEnd(alloc, &file, max_style_bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer alloc.free(bytes);
        var custom = try parseCustom(alloc, entry.name[0 .. entry.name.len - suffix.len], bytes);
        if (std.mem.eql(u8, custom.name, name)) return custom;
        custom.deinit(alloc);
    }
    return null;
}

pub fn findCustom(alloc: Allocator, home: ?[]const u8, name: []const u8) Allocator.Error!?Custom {
    if (home) |home_path| {
        const user_dir = try profile_paths.rootPath(alloc, home_path, &.{directory_name});
        defer alloc.free(user_dir);
        if (std.Io.Dir.openDirAbsolute(io_mod.getIo(), user_dir, .{ .iterate = true })) |opened| {
            var dir = opened;
            defer dir.close(io_mod.getIo());
            if (try findCustomIn(alloc, dir, name)) |custom| return custom;
        } else |_| {}
    }
    if (std.Io.Dir.cwd().openDir(io_mod.getIo(), project_directory, .{ .iterate = true })) |opened| {
        var dir = opened;
        defer dir.close(io_mod.getIo());
        if (try findCustomIn(alloc, dir, name)) |custom| return custom;
    } else |_| {}
    return null;
}

pub const Resolution = union(enum) {
    default,
    instructions: []u8,
    unknown,
};

pub fn resolve(alloc: Allocator, home: ?[]const u8, configured: ?[]const u8) Allocator.Error!Resolution {
    const name = configured orelse return .default;
    if (name.len == 0) return .default;
    if (findBuiltin(name)) |style| {
        if (style.instructions.len == 0) return .default;
        return .{ .instructions = try alloc.dupe(u8, style.instructions) };
    }
    var custom = (try findCustom(alloc, home, name)) orelse return .unknown;
    defer custom.deinit(alloc);
    if (custom.instructions.len == 0) return .default;
    return .{ .instructions = try std.fmt.allocPrint(alloc, "# Output style: {s}\n{s}", .{ custom.name, custom.instructions }) };
}

var active_instructions: ?[]const u8 = null;
var active_name: []const u8 = default_name;
var active_lock: std.atomic.Mutex = .unlocked;

pub fn activeName() []const u8 {
    while (!active_lock.tryLock()) std.atomic.spinLoopHint();
    defer active_lock.unlock();
    return active_name;
}

fn setActiveName(name: []const u8) void {
    const kept = std.heap.page_allocator.dupe(u8, name) catch return;
    while (!active_lock.tryLock()) std.atomic.spinLoopHint();
    defer active_lock.unlock();
    active_name = kept;
}

pub const Switch = struct {
    changed: bool,
    message: []u8,
};

pub fn switchTo(alloc: Allocator, home: ?[]const u8, requested: []const u8) Allocator.Error!Switch {
    const name = std.mem.trim(u8, requested, " \t\r\n");
    if (name.len == 0) {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        out.writer.print("Output style: {s}\nBuilt-in styles:", .{activeName()}) catch return error.OutOfMemory;
        for (builtin_styles) |style| out.writer.print("\n  {s}: {s}", .{ style.name, style.description }) catch return error.OutOfMemory;
        out.writer.writeAll("\nCustom styles are Markdown files in ~/.fx/output-styles or .fx/output-styles. Switch with /output-style <name>.") catch return error.OutOfMemory;
        return .{ .changed = false, .message = try out.toOwnedSlice() };
    }
    switch (try resolve(alloc, home, name)) {
        .unknown => return .{
            .changed = false,
            .message = try std.fmt.allocPrint(alloc, "Unknown output style \"{s}\". Names are case-sensitive; run /output-style to list the styles.", .{name}),
        },
        .default => setActiveInstructions(null),
        .instructions => |text| {
            defer alloc.free(text);
            setActiveInstructions(text);
        },
    }
    setActiveName(name);
    return .{
        .changed = true,
        .message = try std.fmt.allocPrint(alloc, "Output style set to {s} for this session, from the next turn. To keep it, set \"output_style\": \"{s}\" in ~/.fx/settings.json.", .{ name, name }),
    };
}

pub fn activeInstructions() ?[]const u8 {
    while (!active_lock.tryLock()) std.atomic.spinLoopHint();
    defer active_lock.unlock();
    return active_instructions;
}

pub fn setActiveInstructions(instructions: ?[]const u8) void {
    const kept: ?[]const u8 = if (instructions) |text|
        (std.heap.page_allocator.dupe(u8, text) catch null)
    else
        null;
    while (!active_lock.tryLock()) std.atomic.spinLoopHint();
    defer active_lock.unlock();
    active_instructions = kept;
}

pub fn applyConfigured(alloc: Allocator, configured: ?[]const u8) void {
    const resolution = resolve(alloc, io_mod.homeDir(), configured) catch {
        debug_trace.logf("output_style", "resolve failed: out of memory", .{});
        return;
    };
    switch (resolution) {
        .default => {
            setActiveInstructions(null);
            setActiveName(default_name);
        },
        .unknown => {
            debug_trace.logf("output_style", "unknown style name={s}; using {s}", .{ configured orelse "", default_name });
            setActiveInstructions(null);
            setActiveName(default_name);
        },
        .instructions => |text| {
            defer alloc.free(text);
            setActiveInstructions(text);
            setActiveName(configured orelse default_name);
        },
    }
}

test "fx starts in the Default style and ships Proactive, Concise, Explanatory and Learning" {
    try std.testing.expectEqual(@as(usize, 5), builtin_styles.len);
    try std.testing.expectEqualStrings("Default", builtin_styles[0].name);
    try std.testing.expectEqual(@as(usize, 0), builtin_styles[0].instructions.len);
    inline for (.{ "Proactive", "Concise", "Explanatory", "Learning" }) |name| {
        const style = findBuiltin(name).?;
        try std.testing.expect(style.instructions.len > 0);
        try std.testing.expect(std.mem.startsWith(u8, style.instructions, "# Output style: " ++ name));
    }
    try std.testing.expect(findBuiltin("concise") == null);
    try std.testing.expect(findBuiltin("Nothing") == null);
}

test "an unset or Default output style adds nothing and a built-in adds its instructions" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(Resolution.default, try resolve(alloc, null, null));
    try std.testing.expectEqual(Resolution.default, try resolve(alloc, null, ""));
    try std.testing.expectEqual(Resolution.default, try resolve(alloc, null, "Default"));

    const concise = try resolve(alloc, null, "Concise");
    defer alloc.free(concise.instructions);
    try std.testing.expectEqualStrings(findBuiltin("Concise").?.instructions, concise.instructions);
}

test "a custom style file names itself in frontmatter and keeps its flags off unless set" {
    const alloc = std.testing.allocator;
    var named = try parseCustom(alloc, "file-stem",
        \\---
        \\name: Terse Reviewer
        \\description: "Reviews in bullet points"
        \\keep-coding-instructions: true
        \\---
        \\
        \\Reply as a reviewer.
        \\Use bullet points.
        \\
    );
    defer named.deinit(alloc);
    try std.testing.expectEqualStrings("Terse Reviewer", named.name);
    try std.testing.expectEqualStrings("Reviews in bullet points", named.description);
    try std.testing.expectEqualStrings("Reply as a reviewer.\nUse bullet points.", named.instructions);
    try std.testing.expect(named.keep_coding_instructions);
    try std.testing.expect(!named.force_for_plugin);

    var plain = try parseCustom(alloc, "file-stem", "Just the body.\n");
    defer plain.deinit(alloc);
    try std.testing.expectEqualStrings("file-stem", plain.name);
    try std.testing.expectEqualStrings("", plain.description);
    try std.testing.expectEqualStrings("Just the body.", plain.instructions);
    try std.testing.expect(!plain.keep_coding_instructions);
    try std.testing.expect(!plain.force_for_plugin);

    var unclosed = try parseCustom(alloc, "open", "---\nname: Lost\nBody without a closing rule.");
    defer unclosed.deinit(alloc);
    try std.testing.expectEqualStrings("open", unclosed.name);
}

test "a custom style is found by its case-sensitive name in a styles directory" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "reviewer.md", .data = "---\nname: Reviewer\n---\nReview first.\n" });
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = "notes.txt", .data = "---\nname: Reviewer\n---\nNot a style.\n" });

    var found = (try findCustomIn(alloc, tmp.dir, "Reviewer")).?;
    defer found.deinit(alloc);
    try std.testing.expectEqualStrings("Review first.", found.instructions);
    try std.testing.expect((try findCustomIn(alloc, tmp.dir, "reviewer")) == null);
}

test "/output-style lists the styles with no name, switches to a known one, and refuses an unknown one" {
    const alloc = std.testing.allocator;
    defer {
        setActiveInstructions(null);
        setActiveName(default_name);
    }

    const listing = try switchTo(alloc, null, "  ");
    defer alloc.free(listing.message);
    try std.testing.expect(!listing.changed);
    try std.testing.expect(std.mem.startsWith(u8, listing.message, "Output style: Default\n"));
    try std.testing.expect(std.mem.find(u8, listing.message, "\n  Learning: ") != null);

    const switched = try switchTo(alloc, null, " Concise ");
    defer alloc.free(switched.message);
    try std.testing.expect(switched.changed);
    try std.testing.expectEqualStrings("Concise", activeName());
    try std.testing.expectEqualStrings(findBuiltin("Concise").?.instructions, activeInstructions().?);

    const refused = try switchTo(alloc, null, "concise");
    defer alloc.free(refused.message);
    try std.testing.expect(!refused.changed);
    try std.testing.expectEqualStrings("Concise", activeName());

    const back = try switchTo(alloc, null, "Default");
    defer alloc.free(back.message);
    try std.testing.expect(back.changed);
    try std.testing.expect(activeInstructions() == null);
}

test "the active style follows what is set and clears on null" {
    setActiveInstructions("Reply in haiku.");
    try std.testing.expectEqualStrings("Reply in haiku.", activeInstructions().?);
    setActiveInstructions(null);
    try std.testing.expect(activeInstructions() == null);
}
