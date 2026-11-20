const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;

pub const file_name = "keybindings.json";
pub const chord_timeout_ms: i64 = 3000;
pub const max_chord_keystrokes: usize = 4;
pub const max_file_bytes: usize = 256 * 1024;
const dropped_byte: u8 = 0xff;

pub const contexts = [_][]const u8{
    "Global", "Chat",            "Autocomplete",  "Settings",  "Confirmation", "Tabs",
    "Help",   "Transcript",      "HistorySearch", "Task",      "ThemePicker",  "Attachments",
    "Footer", "MessageSelector", "DiffDialog",    "DiffPanel", "ModelPicker",  "EffortSlider",
    "Select", "Plugin",          "AbovePrompt",   "Pane",      "Agents",       "Scroll",
};

pub fn knownContext(name: []const u8) bool {
    for (contexts) |context| {
        if (std.mem.eql(u8, context, name)) return true;
    }
    return false;
}

pub const Modifiers = packed struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,
};

pub const Keystroke = struct {
    modifiers: Modifiers = .{},
    key: []const u8,

    pub fn controlByte(self: Keystroke) ?u8 {
        if (!self.modifiers.ctrl or self.modifiers.shift or self.modifiers.alt or self.modifiers.super) return null;
        if (self.key.len != 1) return null;
        const key = std.ascii.toLower(self.key[0]);
        return switch (key) {
            'a'...'z' => key - 'a' + 1,
            '[' => 27,
            '\\' => 28,
            ']' => 29,
            '^' => 30,
            '_' => 31,
            else => null,
        };
    }

    pub fn reserved(self: Keystroke) bool {
        if (std.ascii.eqlIgnoreCase(self.key, "capslock")) return true;
        const byte = self.controlByte() orelse return false;
        return reservedControlByte(byte);
    }
};

pub fn reservedControlByte(byte: u8) bool {
    return switch (byte) {
        3, 4, 8, 9, 13, 27 => true,
        else => false,
    };
}

fn modifierNamed(name: []const u8) ?Modifiers {
    const table = [_]struct { name: []const u8, modifiers: Modifiers }{
        .{ .name = "ctrl", .modifiers = .{ .ctrl = true } },
        .{ .name = "control", .modifiers = .{ .ctrl = true } },
        .{ .name = "shift", .modifiers = .{ .shift = true } },
        .{ .name = "alt", .modifiers = .{ .alt = true } },
        .{ .name = "opt", .modifiers = .{ .alt = true } },
        .{ .name = "option", .modifiers = .{ .alt = true } },
        .{ .name = "meta", .modifiers = .{ .alt = true } },
        .{ .name = "cmd", .modifiers = .{ .super = true } },
        .{ .name = "command", .modifiers = .{ .super = true } },
        .{ .name = "super", .modifiers = .{ .super = true } },
        .{ .name = "win", .modifiers = .{ .super = true } },
    };
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.modifiers;
    }
    return null;
}

pub fn parseKeystroke(text: []const u8) ?Keystroke {
    if (text.len == 0) return null;
    var modifiers: Modifiers = .{};
    var rest = text;
    while (std.mem.findScalar(u8, rest, '+')) |plus| {
        if (plus == 0) break;
        if (plus + 1 >= rest.len) return null;
        const added = modifierNamed(rest[0..plus]) orelse return null;
        modifiers.ctrl = modifiers.ctrl or added.ctrl;
        modifiers.shift = modifiers.shift or added.shift;
        modifiers.alt = modifiers.alt or added.alt;
        modifiers.super = modifiers.super or added.super;
        rest = rest[plus + 1 ..];
    }
    if (rest.len == 0) return null;
    if (modifierNamed(rest) != null) return null;
    return .{ .modifiers = modifiers, .key = rest };
}

pub fn parseChord(text: []const u8, storage: *[max_chord_keystrokes]Keystroke) ?[]const Keystroke {
    var count: usize = 0;
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |word| {
        if (count == max_chord_keystrokes) return null;
        storage[count] = parseKeystroke(word) orelse return null;
        count += 1;
    }
    if (count == 0) return null;
    return storage[0..count];
}

pub const Availability = enum {
    rebindable,
    fixed,
    unavailable,
};

pub const Action = struct {
    name: []const u8,
    context: []const u8,
    default_keys: []const u8,
    availability: Availability,
    control_byte: ?u8 = null,
};

pub const actions = [_]Action{
    .{ .name = "app:interrupt", .context = "Global", .default_keys = "ctrl+c", .availability = .fixed },
    .{ .name = "app:exit", .context = "Global", .default_keys = "ctrl+d", .availability = .fixed },
    .{ .name = "app:toggleTranscript", .context = "Global", .default_keys = "ctrl+o", .availability = .rebindable, .control_byte = 15 },
    .{ .name = "app:redraw", .context = "Global", .default_keys = "ctrl+l", .availability = .rebindable, .control_byte = 12 },
    .{ .name = "app:toggleTodos", .context = "Global", .default_keys = "ctrl+t", .availability = .unavailable },
    .{ .name = "history:search", .context = "Global", .default_keys = "ctrl+r", .availability = .rebindable, .control_byte = 18 },
    .{ .name = "chat:submit", .context = "Chat", .default_keys = "enter", .availability = .fixed },
    .{ .name = "chat:cycleMode", .context = "Chat", .default_keys = "shift+tab", .availability = .fixed },
    .{ .name = "chat:newline", .context = "Chat", .default_keys = "ctrl+j", .availability = .rebindable, .control_byte = 10 },
    .{ .name = "chat:modelPicker", .context = "Chat", .default_keys = "ctrl+p", .availability = .rebindable, .control_byte = 16 },
    .{ .name = "chat:agentList", .context = "Chat", .default_keys = "ctrl+x", .availability = .rebindable, .control_byte = 24 },
    .{ .name = "chat:lineStart", .context = "Chat", .default_keys = "ctrl+a", .availability = .rebindable, .control_byte = 1 },
    .{ .name = "chat:lineEnd", .context = "Chat", .default_keys = "ctrl+e", .availability = .rebindable, .control_byte = 5 },
    .{ .name = "chat:characterLeft", .context = "Chat", .default_keys = "ctrl+b", .availability = .rebindable, .control_byte = 2 },
    .{ .name = "chat:characterRight", .context = "Chat", .default_keys = "ctrl+f", .availability = .rebindable, .control_byte = 6 },
    .{ .name = "chat:historyNext", .context = "Chat", .default_keys = "ctrl+n", .availability = .rebindable, .control_byte = 14 },
    .{ .name = "chat:killToLineEnd", .context = "Chat", .default_keys = "ctrl+k", .availability = .rebindable, .control_byte = 11 },
    .{ .name = "chat:killToLineStart", .context = "Chat", .default_keys = "ctrl+u", .availability = .rebindable, .control_byte = 21 },
    .{ .name = "chat:killWord", .context = "Chat", .default_keys = "ctrl+w", .availability = .rebindable, .control_byte = 23 },
    .{ .name = "chat:yank", .context = "Chat", .default_keys = "ctrl+y", .availability = .rebindable, .control_byte = 25 },
    .{ .name = "chat:undo", .context = "Chat", .default_keys = "ctrl+_", .availability = .rebindable, .control_byte = 31 },
    .{ .name = "chat:externalEditor", .context = "Chat", .default_keys = "ctrl+g", .availability = .unavailable },
    .{ .name = "chat:stash", .context = "Chat", .default_keys = "ctrl+s", .availability = .rebindable, .control_byte = 19 },
    .{ .name = "chat:fastMode", .context = "Chat", .default_keys = "meta+o", .availability = .unavailable },
    .{ .name = "voice:pushToTalk", .context = "Chat", .default_keys = "space", .availability = .unavailable },
};

pub fn findAction(name: []const u8) ?Action {
    for (actions) |action| {
        if (std.mem.eql(u8, action.name, name)) return action;
    }
    return null;
}

pub const ControlRemap = struct {
    table: [32]u8 = identity,

    const identity: [32]u8 = blk: {
        var bytes: [32]u8 = undefined;
        for (&bytes, 0..) |*slot, index| slot.* = @intCast(index);
        break :blk bytes;
    };

    pub fn resolve(self: *const ControlRemap, byte: u8) ?u8 {
        if (byte >= self.table.len) return byte;
        const mapped = self.table[byte];
        return if (mapped == dropped_byte) null else mapped;
    }

    pub fn changed(self: *const ControlRemap) bool {
        return !std.mem.eql(u8, &self.table, &identity);
    }
};

pub const DiagnosticKind = enum {
    parse_error,
    unknown_context,
    invalid_keystroke,
    unknown_action,
    reserved_key,
    duplicate_binding,
    fixed_action,
    unavailable_action,
    unsupported_key,

    pub fn message(self: DiagnosticKind) []const u8 {
        return switch (self) {
            .parse_error => "the file is not a JSON object with a bindings array of context blocks",
            .unknown_context => "unknown context",
            .invalid_keystroke => "keystroke does not parse",
            .unknown_action => "unknown action",
            .reserved_key => "reserved shortcut cannot be rebound",
            .duplicate_binding => "key is bound more than once in this context; the last binding wins",
            .fixed_action => "fx does not let this action move off its default key",
            .unavailable_action => "fx has no such action yet",
            .unsupported_key => "fx rebinds only single ctrl+key shortcuts; this binding is not applied",
        };
    }
};

pub const Diagnostic = struct {
    kind: DiagnosticKind,
    context: []u8,
    key: []u8,
    action: []u8,
};

pub const Loaded = struct {
    remap: ControlRemap = .{},
    diagnostics: []Diagnostic = &.{},
    applied: usize = 0,

    pub fn deinit(self: *Loaded, alloc: Allocator) void {
        for (self.diagnostics) |diagnostic| {
            alloc.free(diagnostic.context);
            alloc.free(diagnostic.key);
            alloc.free(diagnostic.action);
        }
        if (self.diagnostics.len > 0) alloc.free(self.diagnostics);
        self.* = .{};
    }
};

const Collector = struct {
    alloc: Allocator,
    list: std.ArrayList(Diagnostic) = .empty,

    fn add(self: *Collector, kind: DiagnosticKind, context: []const u8, key: []const u8, action: []const u8) !void {
        const owned_context = try self.alloc.dupe(u8, context);
        errdefer self.alloc.free(owned_context);
        const owned_key = try self.alloc.dupe(u8, key);
        errdefer self.alloc.free(owned_key);
        const owned_action = try self.alloc.dupe(u8, action);
        errdefer self.alloc.free(owned_action);
        try self.list.append(self.alloc, .{ .kind = kind, .context = owned_context, .key = owned_key, .action = owned_action });
    }

    fn discard(self: *Collector) void {
        for (self.list.items) |diagnostic| {
            self.alloc.free(diagnostic.context);
            self.alloc.free(diagnostic.key);
            self.alloc.free(diagnostic.action);
        }
        self.list.deinit(self.alloc);
    }
};

pub fn parse(alloc: Allocator, bytes: []const u8) Allocator.Error!Loaded {
    var collector: Collector = .{ .alloc = alloc };
    errdefer collector.discard();
    var loaded: Loaded = .{};

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try collector.add(.parse_error, "", "", "");
            loaded.diagnostics = try collector.list.toOwnedSlice(alloc);
            return loaded;
        },
    };
    defer parsed.deinit();

    const blocks = blocksOf(parsed.value) orelse {
        try collector.add(.parse_error, "", "", "");
        loaded.diagnostics = try collector.list.toOwnedSlice(alloc);
        return loaded;
    };

    var bound_by_context: [contexts.len][32]bool = @splat(@splat(false));
    for (blocks) |block| {
        if (block != .object) {
            try collector.add(.parse_error, "", "", "");
            continue;
        }
        const context_value = block.object.get("context") orelse {
            try collector.add(.parse_error, "", "", "");
            continue;
        };
        const bindings_value = block.object.get("bindings") orelse {
            try collector.add(.parse_error, "", "", "");
            continue;
        };
        if (context_value != .string or bindings_value != .object) {
            try collector.add(.parse_error, "", "", "");
            continue;
        }
        const context = context_value.string;
        const context_index = contextIndex(context) orelse {
            try collector.add(.unknown_context, context, "", "");
            continue;
        };

        var iterator = bindings_value.object.iterator();
        while (iterator.next()) |entry| {
            const key_text = entry.key_ptr.*;
            const action_name: ?[]const u8 = switch (entry.value_ptr.*) {
                .null => null,
                .string => |name| name,
                else => {
                    try collector.add(.unknown_action, context, key_text, "");
                    continue;
                },
            };
            var storage: [max_chord_keystrokes]Keystroke = undefined;
            const chord = parseChord(key_text, &storage) orelse {
                try collector.add(.invalid_keystroke, context, key_text, action_name orelse "");
                continue;
            };
            var names_reserved = false;
            for (chord) |keystroke| names_reserved = names_reserved or keystroke.reserved();
            if (names_reserved) {
                try collector.add(.reserved_key, context, key_text, action_name orelse "");
                continue;
            }
            var target: u8 = dropped_byte;
            if (action_name) |name| {
                const action = findAction(name) orelse {
                    try collector.add(.unknown_action, context, key_text, name);
                    continue;
                };
                switch (action.availability) {
                    .fixed => {
                        try collector.add(.fixed_action, context, key_text, name);
                        continue;
                    },
                    .unavailable => {
                        try collector.add(.unavailable_action, context, key_text, name);
                        continue;
                    },
                    .rebindable => target = action.control_byte.?,
                }
            }
            const source = if (chord.len == 1) chord[0].controlByte() else null;
            const byte = source orelse {
                try collector.add(.unsupported_key, context, key_text, action_name orelse "");
                continue;
            };
            if (bound_by_context[context_index][byte]) {
                try collector.add(.duplicate_binding, context, key_text, action_name orelse "");
            }
            bound_by_context[context_index][byte] = true;
            loaded.remap.table[byte] = target;
            loaded.applied += 1;
        }
    }

    loaded.diagnostics = try collector.list.toOwnedSlice(alloc);
    return loaded;
}

fn blocksOf(root: std.json.Value) ?[]const std.json.Value {
    if (root != .object) return null;
    const bindings = root.object.get("bindings") orelse return null;
    if (bindings != .array) return null;
    return bindings.array.items;
}

fn contextIndex(name: []const u8) ?usize {
    for (contexts, 0..) |context, index| {
        if (std.mem.eql(u8, context, name)) return index;
    }
    return null;
}

var active_remap: ControlRemap = .{};

pub fn activeControlByte(byte: u8) ?u8 {
    return active_remap.resolve(byte);
}

pub fn setActive(remap: ControlRemap) void {
    active_remap = remap;
}

pub fn traceDiagnostics(diagnostics: []const Diagnostic) void {
    for (diagnostics) |diagnostic| {
        debug_trace.logf("keybindings", "{s} context={s} key={s} action={s}: {s}", .{
            @tagName(diagnostic.kind),
            diagnostic.context,
            diagnostic.key,
            diagnostic.action,
            diagnostic.kind.message(),
        });
    }
}

pub const template =
    \\{
    \\  "$docs": "Each block names a context and maps a keystroke to an action, or to null to unbind it. fx applies single ctrl+key bindings.",
    \\  "bindings": [
    \\    {
    \\      "context": "Chat",
    \\      "bindings": {}
    \\    }
    \\  ]
    \\}
    \\
;

pub fn userFilePath(alloc: Allocator) !?[]u8 {
    const home = io_mod.homeDir() orelse return null;
    return try profile_paths.rootPath(alloc, home, &.{file_name});
}

pub const FileState = enum {
    missing,
    loaded,
};

pub const FileLoad = struct {
    state: FileState = .missing,
    loaded: Loaded = .{},

    pub fn deinit(self: *FileLoad, alloc: Allocator) void {
        self.loaded.deinit(alloc);
        self.* = .{};
    }
};

pub fn loadUserFile(alloc: Allocator) Allocator.Error!FileLoad {
    const path = (try userFilePath(alloc)) orelse return .{};
    defer alloc.free(path);
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return .{};
    defer file.close(io_mod.getIo());
    const bytes = io_mod.readFileToEnd(alloc, &file, max_file_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{},
    };
    defer alloc.free(bytes);
    return .{ .state = .loaded, .loaded = try parse(alloc, bytes) };
}

pub fn applyUserFile(alloc: Allocator) void {
    var result = loadUserFile(alloc) catch {
        debug_trace.logf("keybindings", "load failed: out of memory", .{});
        return;
    };
    defer result.deinit(alloc);
    setActive(result.loaded.remap);
    traceDiagnostics(result.loaded.diagnostics);
    if (result.state == .loaded) {
        debug_trace.logf("keybindings", "loaded applied={d} diagnostics={d}", .{ result.loaded.applied, result.loaded.diagnostics.len });
    }
}

pub fn renderReport(alloc: Allocator, path: []const u8, created: bool, loaded: *const Loaded) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    writeReport(&out.writer, path, created, loaded) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeReport(writer: *std.Io.Writer, path: []const u8, created: bool, loaded: *const Loaded) std.Io.Writer.Error!void {
    try writer.print("Keybindings file: {s}", .{path});
    if (created) try writer.writeAll(" (created)");
    try writer.print("\nApplied {d} binding{s}. Edit the file and run /keybindings again to apply changes.", .{
        loaded.applied,
        if (loaded.applied == 1) "" else "s",
    });
    for (loaded.diagnostics) |diagnostic| {
        try writer.print("\n  {s}", .{diagnostic.kind.message()});
        if (diagnostic.context.len > 0) try writer.print(" [context {s}]", .{diagnostic.context});
        if (diagnostic.key.len > 0) try writer.print(" [key {s}]", .{diagnostic.key});
        if (diagnostic.action.len > 0) try writer.print(" [action {s}]", .{diagnostic.action});
    }
}

pub const Reload = union(enum) {
    no_home,
    write_failed: anyerror,
    report: []u8,
};

pub fn reloadUserFile(alloc: Allocator) Allocator.Error!Reload {
    const path = (try userFilePath(alloc)) orelse return .no_home;
    defer alloc.free(path);
    var created = false;
    if (std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{})) |opened| {
        var file = opened;
        file.close(io_mod.getIo());
    } else |_| {
        io_mod.writeFileAtomic(alloc, path, template) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .write_failed = err },
        };
        created = true;
    }
    var result = try loadUserFile(alloc);
    defer result.deinit(alloc);
    setActive(result.loaded.remap);
    traceDiagnostics(result.loaded.diagnostics);
    return .{ .report = try renderReport(alloc, path, created, &result.loaded) };
}

test "the /keybindings report names the file, the applied count and each problem" {
    const alloc = std.testing.allocator;
    var loaded = try parse(alloc,
        \\{"bindings":[{"context":"Chat","bindings":{"ctrl+t":"chat:newline","ctrl+c":"chat:yank"}}]}
    );
    defer loaded.deinit(alloc);
    const report = try renderReport(alloc, "/home/me/.fx/keybindings.json", true, &loaded);
    defer alloc.free(report);
    try std.testing.expectEqualStrings(
        "Keybindings file: /home/me/.fx/keybindings.json (created)\n" ++
            "Applied 1 binding. Edit the file and run /keybindings again to apply changes.\n" ++
            "  reserved shortcut cannot be rebound [context Chat] [key ctrl+c] [action chat:yank]",
        report,
    );
}

test "a keystroke names its modifiers by any accepted alias" {
    const plain = parseKeystroke("k").?;
    try std.testing.expectEqualStrings("k", plain.key);
    try std.testing.expect(!plain.modifiers.ctrl);

    const ctrl = parseKeystroke("ctrl+k").?;
    try std.testing.expect(ctrl.modifiers.ctrl);
    try std.testing.expectEqual(@as(?u8, 11), ctrl.controlByte());

    inline for (.{ "alt+p", "opt+p", "option+p", "meta+p" }) |text| {
        const parsed = parseKeystroke(text).?;
        try std.testing.expect(parsed.modifiers.alt);
        try std.testing.expectEqualStrings("p", parsed.key);
    }
    inline for (.{ "cmd+k", "super+k" }) |text| {
        try std.testing.expect(parseKeystroke(text).?.modifiers.super);
    }
    const combined = parseKeystroke("ctrl+shift+c").?;
    try std.testing.expect(combined.modifiers.ctrl and combined.modifiers.shift);
    try std.testing.expectEqual(@as(?u8, null), combined.controlByte());

    try std.testing.expect(parseKeystroke("") == null);
    try std.testing.expect(parseKeystroke("hyper+k") == null);
    try std.testing.expect(parseKeystroke("ctrl+") == null);
    try std.testing.expect(parseKeystroke("ctrl") == null);
}

test "a chord is space-separated keystrokes that follow each other within three seconds" {
    var storage: [max_chord_keystrokes]Keystroke = undefined;
    const chord = parseChord("ctrl+x ctrl+e", &storage).?;
    try std.testing.expectEqual(@as(usize, 2), chord.len);
    try std.testing.expectEqual(@as(?u8, 24), chord[0].controlByte());
    try std.testing.expectEqual(@as(?u8, 5), chord[1].controlByte());
    try std.testing.expectEqual(@as(i64, 3000), chord_timeout_ms);
    try std.testing.expect(parseChord("  ", &storage) == null);
    try std.testing.expect(parseChord("a b c d e", &storage) == null);
}

test "ctrl+c, ctrl+d, ctrl+m, ctrl+[, ctrl+i, ctrl+h and caps lock are reserved" {
    inline for (.{ "ctrl+c", "ctrl+d", "ctrl+m", "ctrl+[", "ctrl+i", "ctrl+h", "capslock", "CapsLock" }) |text| {
        try std.testing.expect(parseKeystroke(text).?.reserved());
    }
    inline for (.{ "ctrl+k", "ctrl+j", "alt+c", "c" }) |text| {
        try std.testing.expect(!parseKeystroke(text).?.reserved());
    }
}

test "every documented context is known and an unknown one is not" {
    try std.testing.expectEqual(@as(usize, 24), contexts.len);
    inline for (.{ "Global", "Chat", "Autocomplete", "HistorySearch", "DiffPanel", "EffortSlider", "AbovePrompt", "Scroll" }) |name| {
        try std.testing.expect(knownContext(name));
    }
    try std.testing.expect(!knownContext("chat"));
    try std.testing.expect(!knownContext("Nowhere"));
}

test "the chat actions keep their documented names and fx default keys" {
    try std.testing.expectEqualStrings("enter", findAction("chat:submit").?.default_keys);
    try std.testing.expectEqualStrings("shift+tab", findAction("chat:cycleMode").?.default_keys);
    try std.testing.expectEqualStrings("ctrl+j", findAction("chat:newline").?.default_keys);
    try std.testing.expectEqual(Availability.unavailable, findAction("chat:externalEditor").?.availability);
    try std.testing.expectEqual(Availability.rebindable, findAction("chat:stash").?.availability);
    try std.testing.expectEqual(@as(?u8, 19), findAction("chat:stash").?.control_byte);
    try std.testing.expectEqual(Availability.unavailable, findAction("voice:pushToTalk").?.availability);
    try std.testing.expect(findAction("chat:nothing") == null);
    try std.testing.expectEqualStrings("ctrl+r", findAction("history:search").?.default_keys);
    try std.testing.expectEqual(@as(?u8, 18), findAction("history:search").?.control_byte);
    for (actions) |action| {
        try std.testing.expect(knownContext(action.context));
        try std.testing.expectEqual(action.availability == .rebindable, action.control_byte != null);
        if (action.control_byte) |byte| try std.testing.expect(!reservedControlByte(byte));
    }
}

test "a bindings file rebinds a ctrl key, unbinds a default with null, and keeps $schema and $docs" {
    const alloc = std.testing.allocator;
    var loaded = try parse(alloc,
        \\{"$schema":"https://example.invalid/keybindings.json","$docs":"notes",
        \\ "bindings":[{"context":"Chat","bindings":{"ctrl+t":"chat:newline","ctrl+k":null}}]}
    );
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), loaded.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 2), loaded.applied);
    try std.testing.expectEqual(@as(?u8, 10), loaded.remap.resolve(20));
    try std.testing.expectEqual(@as(?u8, null), loaded.remap.resolve(11));
    try std.testing.expectEqual(@as(?u8, 10), loaded.remap.resolve(10));
    try std.testing.expectEqual(@as(?u8, 'a'), loaded.remap.resolve('a'));
    try std.testing.expect(loaded.remap.changed());
}

test "parse errors, unknown actions, reserved conflicts and duplicate bindings each leave a diagnostic" {
    const alloc = std.testing.allocator;

    var broken = try parse(alloc, "{not json");
    defer broken.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), broken.diagnostics.len);
    try std.testing.expectEqual(DiagnosticKind.parse_error, broken.diagnostics[0].kind);
    try std.testing.expect(!broken.remap.changed());

    var shapeless = try parse(alloc, "{\"bindings\":{}}");
    defer shapeless.deinit(alloc);
    try std.testing.expectEqual(DiagnosticKind.parse_error, shapeless.diagnostics[0].kind);

    var loaded = try parse(alloc,
        \\{"bindings":[
        \\ {"context":"Chat","bindings":{"ctrl+t":"chat:nothing","ctrl+c":"chat:newline","ctrl+r":"chat:newline","alt+x":"chat:yank","ctrl+q":"chat:submit","ctrl+v":"chat:externalEditor","hyper+z":"chat:yank"}},
        \\ {"context":"Chat","bindings":{"ctrl+r":"chat:yank"}},
        \\ {"context":"Elsewhere","bindings":{"ctrl+r":"chat:yank"}}
        \\]}
    );
    defer loaded.deinit(alloc);
    const expected = [_]DiagnosticKind{ .unknown_action, .reserved_key, .unsupported_key, .fixed_action, .unavailable_action, .invalid_keystroke, .duplicate_binding, .unknown_context };
    for (expected) |kind| {
        var found = false;
        for (loaded.diagnostics) |diagnostic| found = found or diagnostic.kind == kind;
        try std.testing.expect(found);
    }
    try std.testing.expectEqual(expected.len, loaded.diagnostics.len);
    try std.testing.expectEqual(@as(?u8, 25), loaded.remap.resolve(18));
    try std.testing.expectEqual(@as(?u8, 3), loaded.remap.resolve(3));
    try std.testing.expectEqual(@as(?u8, 20), loaded.remap.resolve(20));
}

test "the template is a valid bindings file with nothing bound" {
    const alloc = std.testing.allocator;
    var loaded = try parse(alloc, template);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), loaded.diagnostics.len);
    try std.testing.expect(!loaded.remap.changed());
}

test "the active remap starts as identity and follows setActive" {
    try std.testing.expectEqual(@as(?u8, 20), activeControlByte(20));
    var remap: ControlRemap = .{};
    remap.table[20] = 10;
    setActive(remap);
    defer setActive(.{});
    try std.testing.expectEqual(@as(?u8, 10), activeControlByte(20));
}
