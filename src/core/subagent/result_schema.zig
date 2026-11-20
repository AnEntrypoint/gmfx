const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_invalid_text_bytes: usize = 2000;
pub const max_schema_depth: usize = 32;

pub const Checked = union(enum) {
    valid: std.json.Value,
    invalid: []const u8,
};

pub fn schemaProblem(schema: std.json.Value) ?[]const u8 {
    if (schema != .object) return "schema must be a JSON object";
    const type_value = schema.object.get("type") orelse return null;
    switch (type_value) {
        .string => |name| {
            if (!knownType(name)) return "schema.type names an unknown JSON type";
        },
        .array => |names| {
            for (names.items) |name| {
                if (name != .string or !knownType(name.string)) return "schema.type names an unknown JSON type";
            }
        },
        else => return "schema.type must be a string or an array of strings",
    }
    return null;
}

fn knownType(name: []const u8) bool {
    const names = [_][]const u8{ "object", "array", "string", "number", "integer", "boolean", "null" };
    for (names) |known| {
        if (std.mem.eql(u8, known, name)) return true;
    }
    return false;
}

pub fn check(arena: Allocator, schema: std.json.Value, text: []const u8) Allocator.Error!Checked {
    const value = (try extractJson(arena, text)) orelse
        return .{ .invalid = "the reply holds no JSON value" };
    if (try validate(arena, schema, value, "$", 0)) |problem| return .{ .invalid = problem };
    return .{ .valid = value };
}

pub fn extractJson(arena: Allocator, text: []const u8) Allocator.Error!?std.json.Value {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (try parseValue(arena, trimmed)) |value| return value;
    if (fencedBlock(trimmed)) |block| {
        if (try parseValue(arena, block)) |value| return value;
    }
    if (firstBalanced(trimmed)) |candidate| {
        if (try parseValue(arena, candidate)) |value| return value;
    }
    return null;
}

fn parseValue(arena: Allocator, text: []const u8) Allocator.Error!?std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

fn fencedBlock(text: []const u8) ?[]const u8 {
    const fence = "```";
    const open = std.mem.find(u8, text, fence) orelse return null;
    const after_open = text[open + fence.len ..];
    const line_end = std.mem.findScalar(u8, after_open, '\n') orelse return null;
    const body = after_open[line_end + 1 ..];
    const close = std.mem.find(u8, body, fence) orelse return null;
    return std.mem.trim(u8, body[0..close], " \t\r\n");
}

fn firstBalanced(text: []const u8) ?[]const u8 {
    const start = for (text, 0..) |byte, index| {
        if (byte == '{' or byte == '[') break index;
    } else return null;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (text[start..], start..) |byte, index| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        switch (byte) {
            '"' => in_string = true,
            '{', '[' => depth += 1,
            '}', ']' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return text[start .. index + 1];
            },
            else => {},
        }
    }
    return null;
}

pub fn validate(
    arena: Allocator,
    schema: std.json.Value,
    value: std.json.Value,
    path: []const u8,
    depth: usize,
) Allocator.Error!?[]const u8 {
    if (schema != .object) return null;
    if (depth > max_schema_depth) return try arena.print("{s}: schema nests deeper than {d} levels", .{ path, max_schema_depth });
    const rules = schema.object;

    if (rules.get("type")) |type_value| {
        const matches = switch (type_value) {
            .string => |name| typeMatches(name, value),
            .array => |names| for (names.items) |name| {
                if (name == .string and typeMatches(name.string, value)) break true;
            } else false,
            else => true,
        };
        if (!matches) {
            return try arena.print("{s}: expected {s}, got {s}", .{ path, try typeLabel(arena, type_value), valueTypeName(value) });
        }
    }

    if (rules.get("enum")) |allowed| {
        if (allowed == .array) {
            const found = for (allowed.array.items) |candidate| {
                if (try valuesEqual(arena, candidate, value)) break true;
            } else false;
            if (!found) return try arena.print("{s}: value is not one of the allowed enum values", .{path});
        }
    }

    switch (value) {
        .object => |object| {
            if (rules.get("required")) |required| {
                if (required == .array) {
                    for (required.array.items) |key| {
                        if (key != .string) continue;
                        if (object.get(key.string) == null) {
                            return try arena.print("{s}: required key \"{s}\" is missing", .{ path, key.string });
                        }
                    }
                }
            }
            if (rules.get("properties")) |properties| {
                if (properties == .object) {
                    var iterator = properties.object.iterator();
                    while (iterator.next()) |entry| {
                        const child = object.get(entry.key_ptr.*) orelse continue;
                        const child_path = try arena.print("{s}.{s}", .{ path, entry.key_ptr.* });
                        if (try validate(arena, entry.value_ptr.*, child, child_path, depth + 1)) |problem| return problem;
                    }
                }
            }
        },
        .array => |array| {
            if (rules.get("items")) |item_schema| {
                for (array.items, 0..) |item, index| {
                    const child_path = try arena.print("{s}[{d}]", .{ path, index });
                    if (try validate(arena, item_schema, item, child_path, depth + 1)) |problem| return problem;
                }
            }
        },
        else => {},
    }
    return null;
}

fn typeMatches(name: []const u8, value: std.json.Value) bool {
    if (std.mem.eql(u8, name, "object")) return value == .object;
    if (std.mem.eql(u8, name, "array")) return value == .array;
    if (std.mem.eql(u8, name, "string")) return value == .string;
    if (std.mem.eql(u8, name, "boolean")) return value == .bool;
    if (std.mem.eql(u8, name, "null")) return value == .null;
    if (std.mem.eql(u8, name, "number")) return value == .integer or value == .float or value == .number_string;
    if (std.mem.eql(u8, name, "integer")) return switch (value) {
        .integer => true,
        .float => |number| number == @floor(number),
        else => false,
    };
    return true;
}

fn typeLabel(arena: Allocator, type_value: std.json.Value) Allocator.Error![]const u8 {
    return switch (type_value) {
        .string => |name| name,
        .array => |names| blk: {
            var out: std.Io.Writer.Allocating = .init(arena);
            for (names.items, 0..) |name, index| {
                if (name != .string) continue;
                if (index > 0) out.writer.writeAll(" or ") catch return error.OutOfMemory;
                out.writer.writeAll(name.string) catch return error.OutOfMemory;
            }
            break :blk out.written();
        },
        else => "a listed type",
    };
}

fn valueTypeName(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "boolean",
        .integer => "integer",
        .float, .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

fn valuesEqual(arena: Allocator, left: std.json.Value, right: std.json.Value) Allocator.Error!bool {
    if (left == .string and right == .string) return std.mem.eql(u8, left.string, right.string);
    const left_text = try stringifyAlloc(arena, left);
    const right_text = try stringifyAlloc(arena, right);
    return std.mem.eql(u8, left_text, right_text);
}

pub fn stringifyAlloc(arena: Allocator, value: std.json.Value) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(value, .{}, &out.writer) catch return error.OutOfMemory;
    return out.written();
}

pub fn boundedText(text: []const u8) []const u8 {
    if (text.len <= max_invalid_text_bytes) return text;
    var end = max_invalid_text_bytes;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

pub fn repairPrompt(arena: Allocator, problem: []const u8, schema: std.json.Value) Allocator.Error![]const u8 {
    return arena.print(
        "Your last reply did not match the required result schema: {s}. Reply again with only one JSON value that matches this schema, and no other text:\n{s}",
        .{ problem, try stringifyAlloc(arena, schema) },
    );
}

pub fn schemaInstruction(arena: Allocator, schema: std.json.Value) Allocator.Error![]const u8 {
    return arena.print(
        "\n\nEnd with a final reply that is only one JSON value matching this schema, and no other text:\n{s}",
        .{try stringifyAlloc(arena, schema)},
    );
}

fn parseForTest(arena: Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
}

test "result schema accepts a bare value, a fenced block and the first balanced value in prose" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const schema = try parseForTest(arena, "{\"type\":\"object\",\"required\":[\"path\"],\"properties\":{\"path\":{\"type\":\"string\"}}}");

    const bare = try check(arena, schema, " {\"path\":\"a.zig\"} ");
    try std.testing.expectEqualStrings("a.zig", bare.valid.object.get("path").?.string);

    const fenced = try check(arena, schema, "Here it is:\n```json\n{\"path\":\"b.zig\"}\n```\nDone.");
    try std.testing.expectEqualStrings("b.zig", fenced.valid.object.get("path").?.string);

    const prose = try check(arena, schema, "The result is {\"path\":\"c } .zig\"} as asked.");
    try std.testing.expectEqualStrings("c } .zig", prose.valid.object.get("path").?.string);

    const none = try check(arena, schema, "no structured value here");
    try std.testing.expectEqualStrings("the reply holds no JSON value", none.invalid);
}

test "result schema names the path of a missing key, a wrong type and a value outside an enum" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const schema = try parseForTest(arena,
        \\{"type":"object","required":["findings"],"properties":{"findings":{"type":"array","items":{
        \\"type":"object","required":["key","severity"],"properties":{"key":{"type":"string"},
        \\"severity":{"enum":["low","high"]},"line":{"type":"integer"}}}}}}
    );

    const missing = try check(arena, schema, "{}");
    try std.testing.expectEqualStrings("$: required key \"findings\" is missing", missing.invalid);

    const wrong_type = try check(arena, schema, "{\"findings\":[{\"key\":7,\"severity\":\"low\"}]}");
    try std.testing.expectEqualStrings("$.findings[0].key: expected string, got integer", wrong_type.invalid);

    const outside_enum = try check(arena, schema, "{\"findings\":[{\"key\":\"a\",\"severity\":\"medium\"}]}");
    try std.testing.expectEqualStrings("$.findings[0].severity: value is not one of the allowed enum values", outside_enum.invalid);

    const fractional = try check(arena, schema, "{\"findings\":[{\"key\":\"a\",\"severity\":\"low\",\"line\":1.5}]}");
    try std.testing.expectEqualStrings("$.findings[0].line: expected integer, got number", fractional.invalid);

    const valid = try check(arena, schema, "{\"findings\":[{\"key\":\"a\",\"severity\":\"high\",\"line\":3}]}");
    try std.testing.expect(valid == .valid);
}

test "result schema accepts a list of types and rejects a schema that is not an object" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const schema = try parseForTest(arena, "{\"type\":[\"string\",\"null\"]}");
    try std.testing.expect((try check(arena, schema, "null")) == .valid);
    try std.testing.expect((try check(arena, schema, "\"text\"")) == .valid);
    const wrong = try check(arena, schema, "[1]");
    try std.testing.expectEqualStrings("$: expected string or null, got array", wrong.invalid);

    try std.testing.expect(schemaProblem(schema) == null);
    try std.testing.expectEqualStrings("schema must be a JSON object", schemaProblem(.{ .bool = true }).?);
    const unknown = try parseForTest(arena, "{\"type\":\"tuple\"}");
    try std.testing.expectEqualStrings("schema.type names an unknown JSON type", schemaProblem(unknown).?);
}

test "result schema repair prompt names the problem and bounded text keeps whole code points" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const schema = try parseForTest(arena, "{\"type\":\"object\"}");
    const prompt = try repairPrompt(arena, "$: expected object, got string", schema);
    try std.testing.expect(std.mem.find(u8, prompt, "$: expected object, got string") != null);
    try std.testing.expect(std.mem.find(u8, prompt, "{\"type\":\"object\"}") != null);

    const long = try arena.alloc(u8, max_invalid_text_bytes + 2);
    @memset(long, 'a');
    @memcpy(long[max_invalid_text_bytes - 1 ..][0..3], "界");
    const bounded = boundedText(long);
    try std.testing.expect(bounded.len <= max_invalid_text_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(bounded));
}
