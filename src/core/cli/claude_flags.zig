const std = @import("std");
const cli_config = @import("cli_config.zig");
const config_runtime = @import("../config/config_runtime.zig");
const io_mod = @import("../shared/io.zig");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const settings_file_limit: usize = 2 * 1024 * 1024;
pub const prompt_file_limit: usize = 1024 * 1024;

pub const SettingsProblem = union(enum) {
    none,
    unreadable: []const u8,
    too_large: []const u8,
    not_an_object,
    unsupported_value: []const u8,
    override: cli_config.OverrideProblem,
};

pub const SettingsError = error{ InvalidSettingsFlag, OutOfMemory };

pub fn settingsText(arena: Allocator, source: []const u8, problem: *SettingsProblem) SettingsError![]const u8 {
    const inline_json = std.mem.trim(u8, source, " \t\r\n");
    if (inline_json.len > 0 and inline_json[0] == '{') return inline_json;
    return std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), source, arena, .limited(settings_file_limit)) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return settingsProblem(problem, .{ .too_large = source }),
        else => return settingsProblem(problem, .{ .unreadable = source }),
    };
}

pub fn settingsOverrides(
    arena: Allocator,
    text: []const u8,
    problem: *SettingsProblem,
) SettingsError![]config_runtime.SettingOverride {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return settingsProblem(problem, .not_an_object),
    };
    if (parsed != .object) return settingsProblem(problem, .not_an_object);

    var overrides: std.ArrayList(config_runtime.SettingOverride) = .empty;
    var entries = parsed.object.iterator();
    while (entries.next()) |entry| {
        const name = entry.key_ptr.*;
        if (std.mem.eql(u8, name, "$schema")) continue;
        switch (entry.value_ptr.*) {
            .object => |children| {
                var child_entries = children.iterator();
                while (child_entries.next()) |child| {
                    const path = try std.fmt.allocPrint(arena, "{s}.{s}", .{ name, child.key_ptr.* });
                    try overrides.append(arena, try settingOverride(arena, path, child.value_ptr.*, problem));
                }
            },
            else => |value| try overrides.append(arena, try settingOverride(arena, name, value, problem)),
        }
    }
    return overrides.items;
}

fn settingOverride(
    arena: Allocator,
    path: []const u8,
    value: std.json.Value,
    problem: *SettingsProblem,
) SettingsError!config_runtime.SettingOverride {
    const text: []const u8 = switch (value) {
        .string => |string| string,
        .bool => |enabled| if (enabled) "true" else "false",
        .integer => |number| try std.fmt.allocPrint(arena, "{d}", .{number}),
        else => return settingsProblem(problem, .{ .unsupported_value = path }),
    };
    const assignment = try std.fmt.allocPrint(arena, "{s}={s}", .{ path, text });
    var override_problem: cli_config.OverrideProblem = .none;
    return cli_config.parseOverride(assignment, &override_problem) catch
        return settingsProblem(problem, .{ .override = override_problem });
}

fn settingsProblem(problem: *SettingsProblem, why: SettingsProblem) error{InvalidSettingsFlag} {
    problem.* = why;
    return error.InvalidSettingsFlag;
}

pub fn formatSettingsProblem(alloc: Allocator, problem: SettingsProblem) ![]u8 {
    return switch (problem) {
        .none, .not_an_object => alloc.dupe(u8, "--settings takes a JSON object, inline or in a file, such as --settings '{\"fast_mode\": true}'"),
        .unreadable => |path| alloc.print("--settings could not read {f}", .{text_utils.terminalSafe(path)}),
        .too_large => |path| alloc.print("--settings file {f} is larger than 2 MiB", .{text_utils.terminalSafe(path)}),
        .unsupported_value => |path| alloc.print("--settings takes a string, a number, or true or false for {f}", .{text_utils.terminalSafe(path)}),
        .override => |bad| replaceFlagName(alloc, try cli_config.formatOverrideProblem(alloc, bad)),
    };
}

fn replaceFlagName(alloc: Allocator, message: []u8) ![]u8 {
    defer alloc.free(message);
    return std.mem.replaceOwned(u8, alloc, message, "--config", "--settings");
}

pub const PromptFileError = error{ UnreadablePromptFile, OutOfMemory };

pub fn readPromptFile(alloc: Allocator, path: []const u8) PromptFileError![]u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(io_mod.getIo(), path, alloc, .limited(prompt_file_limit)) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnreadablePromptFile,
    };
    if (!text_utils.isModelSafeText(text)) {
        alloc.free(text);
        return error.UnreadablePromptFile;
    }
    return text;
}

pub fn appendedSystemPrompt(alloc: Allocator, base: []const u8, appended: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ std.mem.trimEnd(u8, base, " \t\r\n"), appended });
}

pub fn joinAppended(alloc: Allocator, earlier: ?[]u8, text: []const u8) Allocator.Error![]u8 {
    const previous = earlier orelse return alloc.dupe(u8, text);
    const joined = try std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ previous, text });
    alloc.free(previous);
    return joined;
}

test "--settings reads an inline JSON object into the overrides --config would make" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var problem: SettingsProblem = .none;
    const text = try settingsText(arena, " {\"fast_mode\": true, \"max_agent_steps\": 12, \"status_line\": {\"context\": false}, \"$schema\": \"https://fx.sh/schemas/settings.json\"} ", &problem);
    const overrides = try settingsOverrides(arena, text, &problem);
    try std.testing.expectEqual(@as(usize, 3), overrides.len);
    try std.testing.expectEqualStrings("fast_mode", overrides[0].key);
    try std.testing.expect(overrides[0].value.bool);
    try std.testing.expectEqualStrings("max_agent_steps", overrides[1].key);
    try std.testing.expectEqual(@as(i64, 12), overrides[1].value.integer);
    try std.testing.expectEqualStrings("status_line.context", overrides[2].key);
    try std.testing.expect(!overrides[2].value.bool);
}

test "--settings names what is wrong with its value" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var problem: SettingsProblem = .none;
    try std.testing.expectError(error.InvalidSettingsFlag, settingsOverrides(arena, "[1]", &problem));
    try std.testing.expect(problem == .not_an_object);

    try std.testing.expectError(error.InvalidSettingsFlag, settingsOverrides(arena, "{\"fast_mode\": null}", &problem));
    try std.testing.expectEqualStrings("fast_mode", problem.unsupported_value);

    try std.testing.expectError(error.InvalidSettingsFlag, settingsOverrides(arena, "{\"fast_mode\": \"sometimes\"}", &problem));
    const invalid = try formatSettingsProblem(alloc, problem);
    defer alloc.free(invalid);
    try std.testing.expectEqualStrings("invalid value for fast_mode: sometimes (use true or false)", invalid);

    try std.testing.expectError(error.InvalidSettingsFlag, settingsOverrides(arena, "{\"model\": \"some/model\"}", &problem));
    const refused = try formatSettingsProblem(alloc, problem);
    defer alloc.free(refused);
    try std.testing.expectEqualStrings("can't change model with --settings; use /model in a session", refused);

    try std.testing.expectError(error.InvalidSettingsFlag, settingsText(arena, "/nonexistent/fx-settings.json", &problem));
    try std.testing.expectEqualStrings("/nonexistent/fx-settings.json", problem.unreadable);
}

test "an appended system prompt follows the base prompt after one blank line, and repeats accumulate" {
    const alloc = std.testing.allocator;
    const composed = try appendedSystemPrompt(alloc, "base prompt\n", "extra rule");
    defer alloc.free(composed);
    try std.testing.expectEqualStrings("base prompt\n\nextra rule", composed);

    const first = try joinAppended(alloc, null, "one");
    const both = try joinAppended(alloc, first, "two");
    defer alloc.free(both);
    try std.testing.expectEqualStrings("one\n\ntwo", both);
}
