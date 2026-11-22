const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");

/// Callers pass a long-lived arena, so the arguments are parsed in scratch
/// memory and only the finished tree is copied into `alloc`, sized exactly.
/// The parser's own working lists would otherwise stay in that arena until it
/// is freed, which costs several times the size of the arguments on every call.
pub fn parseToolArgsObject(alloc: std.mem.Allocator, args_json: []const u8) !std.json.ObjectMap {
    var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer scratch.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), args_json, .{});
    if (parsed != .object) return error.InvalidToolArguments;

    const value = copyValue(alloc, parsed, max_copy_depth) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        // Deeper than the copy recurses: parse straight into `alloc`, as before.
        error.TooDeep => try std.json.parseFromSliceLeaky(std.json.Value, alloc, args_json, .{}),
    };
    return value.object;
}

const max_copy_depth = 64;

fn copyValue(alloc: std.mem.Allocator, value: std.json.Value, depth: usize) error{ OutOfMemory, TooDeep }!std.json.Value {
    switch (value) {
        .null, .bool, .integer, .float => return value,
        .number_string => |text| return .{ .number_string = try alloc.dupe(u8, text) },
        .string => |text| return .{ .string = try alloc.dupe(u8, text) },
        .array => |items| {
            if (depth == 0) return error.TooDeep;
            var copy = try std.json.Array.initCapacity(alloc, items.items.len);
            for (items.items) |item| copy.appendAssumeCapacity(try copyValue(alloc, item, depth - 1));
            return .{ .array = copy };
        },
        .object => |map| {
            if (depth == 0) return error.TooDeep;
            var copy: std.json.ObjectMap = .empty;
            try copy.ensureTotalCapacity(alloc, map.count());
            var entries = map.iterator();
            while (entries.next()) |entry| {
                const key = try alloc.dupe(u8, entry.key_ptr.*);
                copy.putAssumeCapacityNoClobber(key, try copyValue(alloc, entry.value_ptr.*, depth - 1));
            }
            return .{ .object = copy };
        },
    }
}

pub fn normalizeCompositeObjectValue(
    alloc: std.mem.Allocator,
    value: *std.json.Value,
) !void {
    return normalizeCompositeValue(alloc, value, .object);
}

pub fn normalizeCompositeArrayValue(
    alloc: std.mem.Allocator,
    value: *std.json.Value,
) !void {
    return normalizeCompositeValue(alloc, value, .array);
}

fn normalizeCompositeValue(
    alloc: std.mem.Allocator,
    value: *std.json.Value,
    kind: std.meta.Tag(std.json.Value),
) !void {
    if (value.* != .string) return;
    const decoded = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        value.string,
        .{ .allocate = .alloc_always },
    );
    if (std.meta.activeTag(decoded) != kind) return error.InvalidCompositeArgument;
    value.* = decoded;
}

pub fn requiredStringArg(args: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = args.get(key) orelse return error.InvalidToolArguments;
    if (value != .string) return error.InvalidToolArguments;
    return value.string;
}

pub fn optionalStringArg(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = args.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

pub fn isNullPlaceholderText(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, text, &std.ascii.whitespace), "null");
}

pub fn nullablePlaceholderStringArg(args: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const text = optionalStringArg(args, key) orelse return null;
    if (isNullPlaceholderText(text)) return null;
    return text;
}

pub fn optionalBoolArg(args: std.json.ObjectMap, key: []const u8) ?bool {
    const value = args.get(key) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

pub fn optionalIntArg(args: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = args.get(key) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

pub fn firstUnknownKey(args: std.json.ObjectMap, accepted: []const []const u8) ?[]const u8 {
    var keys = args.iterator();
    while (keys.next()) |entry| {
        if (!isAcceptedKey(entry.key_ptr.*, accepted)) return entry.key_ptr.*;
    }
    return null;
}

fn isAcceptedKey(key: []const u8, accepted: []const []const u8) bool {
    for (accepted) |name| {
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
}

pub fn unknownArgumentMessage(
    alloc: std.mem.Allocator,
    tool: []const u8,
    key: []const u8,
    accepted: []const []const u8,
) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.print(alloc, "{s} does not take argument \"{s}\"; accepted fields: ", .{ tool, key });
    for (accepted, 0..) |name, index| {
        if (index != 0) try out.appendSlice(alloc, ", ");
        try out.appendSlice(alloc, name);
    }
    return out.toOwnedSlice(alloc);
}

pub const ArgsDecoder = struct {
    alloc: std.mem.Allocator,
    tool: []const u8,
    failure: ?[]u8 = null,

    const Error = std.mem.Allocator.Error || error{InvalidArguments};

    /// The caller frees the result with `deinit` and copies what it keeps
    /// first. The tree is not allocated from `self.alloc`, which is usually a
    /// long-lived arena that would hold it until the arena is freed.
    pub fn parse(self: *ArgsDecoder, args_json: []const u8) Error!std.json.Parsed(std.json.Value) {
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, args_json, .{}) catch
            return self.fail("{s} arguments must be valid JSON", .{self.tool});
        errdefer parsed.deinit();
        if (parsed.value != .object) return self.fail("{s} arguments must be an object", .{self.tool});
        return parsed;
    }

    pub fn requiredString(self: *ArgsDecoder, args: std.json.ObjectMap, key: []const u8) Error![]const u8 {
        const value = args.get(key) orelse return self.fail("{s} requires string field \"{s}\"", .{ self.tool, key });
        if (value != .string) return self.stringFailure(key);
        return value.string;
    }

    pub fn optionalString(self: *ArgsDecoder, args: std.json.ObjectMap, key: []const u8) Error!?[]const u8 {
        const value = args.get(key) orelse return null;
        return switch (value) {
            .null => null,
            .string => |text| text,
            else => self.stringFailure(key),
        };
    }

    pub fn rejectUnknown(self: *ArgsDecoder, args: std.json.ObjectMap, accepted: []const []const u8) Error!void {
        const key = firstUnknownKey(args, accepted) orelse return;
        self.failure = try unknownArgumentMessage(self.alloc, self.tool, key, accepted);
        return error.InvalidArguments;
    }

    fn stringFailure(self: *ArgsDecoder, key: []const u8) Error {
        return self.fail("{s} field \"{s}\" must be a string", .{ self.tool, key });
    }

    fn fail(self: *ArgsDecoder, comptime fmt: []const u8, args: anytype) Error {
        self.failure = try self.alloc.print(fmt, args);
        return error.InvalidArguments;
    }

    pub fn takeFailure(self: *ArgsDecoder, err: Error) std.mem.Allocator.Error![]u8 {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidArguments => {
                const failure = self.failure.?;
                self.failure = null;
                return failure;
            },
        };
    }
};

test "ArgsDecoder rejectUnknown names the unknown argument and the accepted fields" {
    var decoder: ArgsDecoder = .{ .alloc = std.testing.allocator, .tool = "read_file" };
    var parsed = try decoder.parse("{\"path\":\"a.zig\",\"offset\":3}");
    defer parsed.deinit();

    const accepted = [_][]const u8{ "path", "start_line", "line_count" };
    try std.testing.expectError(error.InvalidArguments, decoder.rejectUnknown(parsed.value.object, &accepted));
    const failure = try decoder.takeFailure(error.InvalidArguments);
    defer std.testing.allocator.free(failure);
    try std.testing.expectEqualStrings(
        "read_file does not take argument \"offset\"; accepted fields: path, start_line, line_count",
        failure,
    );
}

test "ArgsDecoder rejectUnknown accepts an object made only of accepted fields" {
    var decoder: ArgsDecoder = .{ .alloc = std.testing.allocator, .tool = "read_file" };
    var parsed = try decoder.parse("{\"path\":\"a.zig\",\"line_count\":3}");
    defer parsed.deinit();

    const accepted = [_][]const u8{ "path", "start_line", "line_count" };
    try decoder.rejectUnknown(parsed.value.object, &accepted);
    try std.testing.expect(decoder.failure == null);
    try std.testing.expect(firstUnknownKey(parsed.value.object, &accepted) == null);
}

test "parseToolArgsObject parses object roots" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseToolArgsObject(arena, "{\"path\":\"src/main.zig\"}");

    try std.testing.expectEqualStrings("src/main.zig", args.get("path").?.string);
}

test "parseToolArgsObject rejects non-object roots" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.InvalidToolArguments, parseToolArgsObject(arena, "[]"));
}

test "requiredStringArg rejects missing and wrong-type values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseToolArgsObject(arena, "{\"path\":\"src/main.zig\",\"count\":3}");

    try std.testing.expectEqualStrings("src/main.zig", try requiredStringArg(args, "path"));
    try std.testing.expectError(error.InvalidToolArguments, requiredStringArg(args, "missing"));
    try std.testing.expectError(error.InvalidToolArguments, requiredStringArg(args, "count"));
}

test "optional typed args return payloads only for matching tags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseToolArgsObject(arena, "{\"name\":\"fx\",\"enabled\":true,\"count\":3,\"other\":1.25}");

    try std.testing.expectEqualStrings("fx", optionalStringArg(args, "name").?);
    try std.testing.expect(optionalStringArg(args, "missing") == null);
    try std.testing.expect(optionalStringArg(args, "enabled") == null);

    try std.testing.expectEqual(true, optionalBoolArg(args, "enabled").?);
    try std.testing.expect(optionalBoolArg(args, "missing") == null);
    try std.testing.expect(optionalBoolArg(args, "name") == null);

    try std.testing.expectEqual(@as(i64, 3), optionalIntArg(args, "count").?);
    try std.testing.expect(optionalIntArg(args, "missing") == null);
    try std.testing.expect(optionalIntArg(args, "other") == null);
}

test "null placeholder reads treat textual nulls as absent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try parseToolArgsObject(
        arena,
        "{\"cwd\":\"null\",\"profile\":\" NULL \",\"shell\":null,\"command\":\"echo null\",\"dir\":\"nullify\"}",
    );

    try std.testing.expect(nullablePlaceholderStringArg(args, "cwd") == null);
    try std.testing.expect(nullablePlaceholderStringArg(args, "profile") == null);
    try std.testing.expect(nullablePlaceholderStringArg(args, "shell") == null);
    try std.testing.expect(nullablePlaceholderStringArg(args, "missing") == null);
    try std.testing.expectEqualStrings("echo null", nullablePlaceholderStringArg(args, "command").?);
    try std.testing.expectEqualStrings("nullify", nullablePlaceholderStringArg(args, "dir").?);
    try std.testing.expectEqualStrings("null", optionalStringArg(args, "cwd").?);
}

test "composite object normalization preserves objects and decodes JSON strings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var object = std.json.Value{ .object = try parseToolArgsObject(
        arena,
        "{\"kind\":\"executable\",\"path\":\"/bin/bash\"}",
    ) };
    try normalizeCompositeObjectValue(arena, &object);
    try std.testing.expectEqualStrings("/bin/bash", object.object.get("path").?.string);

    var encoded = std.json.Value{ .string = "{\"kind\":\"executable\",\"path\":\"/bin/zsh\"}" };
    try normalizeCompositeObjectValue(arena, &encoded);
    try std.testing.expectEqualStrings("/bin/zsh", encoded.object.get("path").?.string);

    var invalid = std.json.Value{ .string = "[]" };
    try std.testing.expectError(
        error.InvalidCompositeArgument,
        normalizeCompositeObjectValue(arena, &invalid),
    );
}

test "composite array normalization preserves arrays and decodes JSON strings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var array = try std.json.parseFromSliceLeaky(std.json.Value, arena, "[1,2]", .{});
    try normalizeCompositeArrayValue(arena, &array);
    try std.testing.expectEqual(@as(usize, 2), array.array.items.len);

    var encoded = std.json.Value{ .string = "[{\"question\":\"Q\"}]" };
    try normalizeCompositeArrayValue(arena, &encoded);
    try std.testing.expectEqualStrings("Q", encoded.array.items[0].object.get("question").?.string);

    var number = std.json.Value{ .integer = 3 };
    try normalizeCompositeArrayValue(arena, &number);
    try std.testing.expectEqual(@as(i64, 3), number.integer);

    var object_text = std.json.Value{ .string = "{}" };
    try std.testing.expectError(
        error.InvalidCompositeArgument,
        normalizeCompositeArrayValue(arena, &object_text),
    );
    var not_json = std.json.Value{ .string = "not json" };
    try std.testing.expectError(
        error.SyntaxError,
        normalizeCompositeArrayValue(arena, &not_json),
    );
}

fn expectDecoderFailure(expected: []const u8, comptime read: fn (*ArgsDecoder, std.json.ObjectMap) ArgsDecoder.Error!void, args_json: []const u8) !void {
    const alloc = std.testing.allocator;
    var decoder: ArgsDecoder = .{ .alloc = alloc, .tool = "demo_tool" };
    var parsed = decoder.parse(args_json) catch |err| {
        const failure = try decoder.takeFailure(err);
        defer alloc.free(failure);
        return std.testing.expectEqualStrings(expected, failure);
    };
    defer parsed.deinit();
    read(&decoder, parsed.value.object) catch |err| {
        const failure = try decoder.takeFailure(err);
        defer alloc.free(failure);
        try std.testing.expectEqual(null, decoder.failure);
        return std.testing.expectEqualStrings(expected, failure);
    };
    return error.TestExpectedFailure;
}

fn readNothing(_: *ArgsDecoder, _: std.json.ObjectMap) ArgsDecoder.Error!void {
    return error.InvalidArguments;
}

fn readRequiredPath(decoder: *ArgsDecoder, args: std.json.ObjectMap) ArgsDecoder.Error!void {
    _ = try decoder.requiredString(args, "path");
}

fn readOptionalPath(decoder: *ArgsDecoder, args: std.json.ObjectMap) ArgsDecoder.Error!void {
    _ = try decoder.optionalString(args, "path");
}

test "ArgsDecoder reports each argument problem as the tool's failure text" {
    try expectDecoderFailure("demo_tool arguments must be valid JSON", readNothing, "{");
    try expectDecoderFailure("demo_tool arguments must be an object", readNothing, "[1]");
    try expectDecoderFailure("demo_tool requires string field \"path\"", readRequiredPath, "{}");
    try expectDecoderFailure("demo_tool field \"path\" must be a string", readRequiredPath, "{\"path\":7}");
    try expectDecoderFailure("demo_tool field \"path\" must be a string", readRequiredPath, "{\"path\":null}");
    try expectDecoderFailure("demo_tool field \"path\" must be a string", readOptionalPath, "{\"path\":[]}");
}

test "ArgsDecoder reads present strings and treats missing or null optional strings as absent" {
    const alloc = std.testing.allocator;
    var decoder: ArgsDecoder = .{ .alloc = alloc, .tool = "demo_tool" };
    var parsed = try decoder.parse("{\"path\":\"a.txt\",\"mode\":null}");
    defer parsed.deinit();
    const args = parsed.value.object;
    try std.testing.expectEqualStrings("a.txt", try decoder.requiredString(args, "path"));
    try std.testing.expectEqualStrings("a.txt", (try decoder.optionalString(args, "path")).?);
    try std.testing.expectEqual(null, try decoder.optionalString(args, "mode"));
    try std.testing.expectEqual(null, try decoder.optionalString(args, "include"));
    try std.testing.expectEqual(null, decoder.failure);
}

fn decodeRequiredPathAllocation(alloc: std.mem.Allocator) !void {
    var decoder: ArgsDecoder = .{ .alloc = alloc, .tool = "demo_tool" };
    var parsed = decoder.parse("{\"path\":3}") catch |err| {
        alloc.free(try decoder.takeFailure(err));
        return;
    };
    defer parsed.deinit();
    _ = decoder.requiredString(parsed.value.object, "path") catch |err| {
        alloc.free(try decoder.takeFailure(err));
        return;
    };
    return error.TestExpectedFailure;
}

test "ArgsDecoder keeps allocation failures as errors and leaks nothing" {
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, decodeRequiredPathAllocation, .{});
}

test "parsed tool arguments keep their values, key order and nesting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = try parseToolArgsObject(
        arena.allocator(),
        "{\"path\":\"a.txt\",\"limit\":3,\"big\":123456789012345678901234567890,\"flags\":[true,null,{\"x\":1.5}],\"empty\":\"\"}",
    );
    try std.testing.expectEqual(@as(usize, 5), args.count());
    try std.testing.expectEqualStrings("path", args.keys()[0]);
    try std.testing.expectEqualStrings("empty", args.keys()[4]);
    try std.testing.expectEqualStrings("a.txt", args.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 3), args.get("limit").?.integer);
    try std.testing.expectEqualStrings("123456789012345678901234567890", args.get("big").?.number_string);
    const flags = args.get("flags").?.array.items;
    try std.testing.expectEqual(true, flags[0].bool);
    try std.testing.expect(flags[1] == .null);
    try std.testing.expectEqual(@as(f64, 1.5), flags[2].object.get("x").?.float);
    try std.testing.expectEqualStrings("", args.get("empty").?.string);
    try std.testing.expectError(error.InvalidToolArguments, parseToolArgsObject(arena.allocator(), "[1]"));
}

test "tool arguments nested deeper than the copy limit still parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const depth = max_copy_depth + 8;
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(std.testing.allocator);
    try json.appendSlice(std.testing.allocator, "{\"deep\":");
    try json.appendNTimes(std.testing.allocator, '[', depth);
    try json.appendNTimes(std.testing.allocator, ']', depth);
    try json.append(std.testing.allocator, '}');
    const args = try parseToolArgsObject(arena.allocator(), json.items);
    var level = args.get("deep").?;
    var seen: usize = 0;
    while (level == .array and level.array.items.len == 1) : (seen += 1) level = level.array.items[0];
    try std.testing.expectEqual(depth - 1, seen);
}

test "parsed tool arguments take little more than their own size from the arena" {
    var buffer: [200 * 512]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    for (0..200) |_| _ = try parseToolArgsObject(fixed.allocator(), "{\"path\":\"evidence.txt\"}");
}
