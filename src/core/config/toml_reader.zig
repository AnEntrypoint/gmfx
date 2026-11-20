const std = @import("std");

const Allocator = std.mem.Allocator;
const ObjectMap = std.json.ObjectMap;
const Value = std.json.Value;

pub const Error = error{ InvalidToml, OutOfMemory };

pub fn parse(arena: Allocator, text: []const u8) Error!Value {
    var parser: Parser = .{ .arena = arena, .text = text };
    try parser.document();
    return Value{ .object = parser.root };
}

fn enter(slot: *Value) Error!*ObjectMap {
    switch (slot.*) {
        .object => |*object| return object,
        .array => |*array| {
            if (array.items.len == 0) return error.InvalidToml;
            const last = &array.items[array.items.len - 1];
            switch (last.*) {
                .object => |*object| return object,
                else => return error.InvalidToml,
            }
        },
        else => return error.InvalidToml,
    }
}

fn isBareKeyByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn isScalarByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte == '+' or byte == '.';
}

const Parser = struct {
    arena: Allocator,
    text: []const u8,
    pos: usize = 0,
    root: ObjectMap = .empty,
    table: []const []const u8 = &.{},

    fn document(self: *Parser) Error!void {
        while (true) {
            self.skipBlank();
            if (self.pos >= self.text.len) return;
            if (self.peek() == '[') {
                try self.tableHeader();
            } else {
                try self.keyValue();
            }
            try self.endOfLine();
        }
    }

    fn tableHeader(self: *Parser) Error!void {
        self.pos += 1;
        const is_array = self.consume('[');
        const keys = try self.keyPath();
        self.skipSpaces();
        if (!self.consume(']')) return error.InvalidToml;
        if (is_array and !self.consume(']')) return error.InvalidToml;
        const parent = try self.descend(&self.root, keys[0 .. keys.len - 1]);
        const last = keys[keys.len - 1];
        if (is_array) {
            if (parent.getPtr(last)) |slot| {
                if (slot.* != .array) return error.InvalidToml;
                try slot.array.append(Value{ .object = .empty });
            } else {
                var list: std.json.Array = .init(self.arena);
                try list.append(Value{ .object = .empty });
                try parent.put(self.arena, last, Value{ .array = list });
            }
        } else {
            _ = try self.child(parent, last);
        }
        self.table = keys;
    }

    fn keyValue(self: *Parser) Error!void {
        const keys = try self.keyPath();
        self.skipSpaces();
        if (!self.consume('=')) return error.InvalidToml;
        self.skipSpaces();
        const parsed_value = try self.value();
        const base = try self.tableAt(self.table);
        try self.assign(base, keys, parsed_value);
    }

    fn assign(self: *Parser, base: *ObjectMap, keys: []const []const u8, entry: Value) Error!void {
        const parent = try self.descend(base, keys[0 .. keys.len - 1]);
        const last = keys[keys.len - 1];
        if (parent.contains(last)) return error.InvalidToml;
        try parent.put(self.arena, last, entry);
    }

    fn tableAt(self: *Parser, path: []const []const u8) Error!*ObjectMap {
        return self.descend(&self.root, path);
    }

    fn descend(self: *Parser, start: *ObjectMap, segments: []const []const u8) Error!*ObjectMap {
        var map = start;
        for (segments) |segment| map = try self.child(map, segment);
        return map;
    }

    fn child(self: *Parser, map: *ObjectMap, key_text: []const u8) Error!*ObjectMap {
        if (map.getPtr(key_text) == null) try map.put(self.arena, key_text, Value{ .object = .empty });
        return enter(map.getPtr(key_text).?);
    }

    fn keyPath(self: *Parser) Error![]const []const u8 {
        var keys: std.ArrayList([]const u8) = .empty;
        while (true) {
            self.skipSpaces();
            try keys.append(self.arena, try self.key());
            self.skipSpaces();
            if (!self.consume('.')) break;
        }
        return keys.toOwnedSlice(self.arena);
    }

    fn key(self: *Parser) Error![]const u8 {
        const byte = self.peek() orelse return error.InvalidToml;
        if (byte == '"') return self.basicString();
        if (byte == '\'') return self.literalString();
        const start = self.pos;
        while (self.peek()) |candidate| {
            if (!isBareKeyByte(candidate)) break;
            self.pos += 1;
        }
        if (self.pos == start) return error.InvalidToml;
        return try self.arena.dupe(u8, self.text[start..self.pos]);
    }

    fn value(self: *Parser) Error!Value {
        const byte = self.peek() orelse return error.InvalidToml;
        return switch (byte) {
            '"' => if (self.startsWith("\"\"\""))
                Value{ .string = try self.multilineBasicString() }
            else
                Value{ .string = try self.basicString() },
            '\'' => if (self.startsWith("'''"))
                Value{ .string = try self.multilineLiteralString() }
            else
                Value{ .string = try self.literalString() },
            '[' => try self.array(),
            '{' => try self.inlineTable(),
            else => try self.scalar(),
        };
    }

    fn basicString(self: *Parser) Error![]const u8 {
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const byte = self.next() orelse return error.InvalidToml;
            switch (byte) {
                '"' => return try out.toOwnedSlice(self.arena),
                '\n', '\r' => return error.InvalidToml,
                '\\' => try self.escape(&out),
                else => try out.append(self.arena, byte),
            }
        }
    }

    fn multilineBasicString(self: *Parser) Error![]const u8 {
        self.pos += 3;
        self.trimOpeningNewline();
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const byte = self.next() orelse return error.InvalidToml;
            switch (byte) {
                '"' => {
                    var run: usize = 1;
                    while (run < 5 and self.consume('"')) run += 1;
                    if (run < 3) {
                        try out.appendNTimes(self.arena, '"', run);
                        continue;
                    }
                    try out.appendNTimes(self.arena, '"', run - 3);
                    return try out.toOwnedSlice(self.arena);
                },
                '\\' => {
                    if (self.skipLineEndingBackslash()) continue;
                    try self.escape(&out);
                },
                '\r' => {
                    if (!self.consume('\n')) return error.InvalidToml;
                    try out.append(self.arena, '\n');
                },
                else => try out.append(self.arena, byte),
            }
        }
    }

    fn literalString(self: *Parser) Error![]const u8 {
        self.pos += 1;
        const start = self.pos;
        while (true) {
            const byte = self.next() orelse return error.InvalidToml;
            if (byte == '\'') return try self.arena.dupe(u8, self.text[start .. self.pos - 1]);
            if (byte == '\n' or byte == '\r') return error.InvalidToml;
        }
    }

    fn multilineLiteralString(self: *Parser) Error![]const u8 {
        self.pos += 3;
        self.trimOpeningNewline();
        const start = self.pos;
        const close = std.mem.findPos(u8, self.text, start, "'''") orelse return error.InvalidToml;
        var run: usize = 0;
        while (run < 5 and close + run < self.text.len and self.text[close + run] == '\'') run += 1;
        self.pos = close + run;
        return try self.arena.dupe(u8, self.text[start .. close + run - 3]);
    }

    fn escape(self: *Parser, out: *std.ArrayList(u8)) Error!void {
        const byte = self.next() orelse return error.InvalidToml;
        const decoded: u8 = switch (byte) {
            'b' => 0x08,
            't' => '\t',
            'n' => '\n',
            'f' => 0x0C,
            'r' => '\r',
            '"' => '"',
            '\\' => '\\',
            'u' => return self.unicodeEscape(out, 4),
            'U' => return self.unicodeEscape(out, 8),
            else => return error.InvalidToml,
        };
        try out.append(self.arena, decoded);
    }

    fn unicodeEscape(self: *Parser, out: *std.ArrayList(u8), comptime digits: usize) Error!void {
        if (self.pos + digits > self.text.len) return error.InvalidToml;
        const code = std.fmt.parseInt(u32, self.text[self.pos .. self.pos + digits], 16) catch return error.InvalidToml;
        self.pos += digits;
        const code_point = std.math.cast(u21, code) orelse return error.InvalidToml;
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(code_point, &buffer) catch return error.InvalidToml;
        try out.appendSlice(self.arena, buffer[0..length]);
    }

    fn skipLineEndingBackslash(self: *Parser) bool {
        var probe = self.pos;
        while (probe < self.text.len and (self.text[probe] == ' ' or self.text[probe] == '\t')) probe += 1;
        if (probe >= self.text.len) return false;
        if (self.text[probe] != '\n' and self.text[probe] != '\r') return false;
        self.pos = probe;
        while (self.pos < self.text.len and std.ascii.isWhitespace(self.text[self.pos])) self.pos += 1;
        return true;
    }

    fn trimOpeningNewline(self: *Parser) void {
        if (self.consume('\n')) return;
        if (self.startsWith("\r\n")) self.pos += 2;
    }

    fn array(self: *Parser) Error!Value {
        self.pos += 1;
        var items: std.json.Array = .init(self.arena);
        while (true) {
            self.skipBlank();
            if (self.consume(']')) break;
            try items.append(try self.value());
            self.skipBlank();
            if (self.consume(']')) break;
            if (!self.consume(',')) return error.InvalidToml;
        }
        return Value{ .array = items };
    }

    fn inlineTable(self: *Parser) Error!Value {
        self.pos += 1;
        var map: ObjectMap = .empty;
        self.skipSpaces();
        if (self.consume('}')) return Value{ .object = map };
        while (true) {
            const keys = try self.keyPath();
            self.skipSpaces();
            if (!self.consume('=')) return error.InvalidToml;
            self.skipSpaces();
            const entry = try self.value();
            try self.assign(&map, keys, entry);
            self.skipSpaces();
            if (self.consume('}')) return Value{ .object = map };
            if (!self.consume(',')) return error.InvalidToml;
            self.skipSpaces();
        }
    }

    fn scalar(self: *Parser) Error!Value {
        if (self.consumeKeyword("true")) return Value{ .bool = true };
        if (self.consumeKeyword("false")) return Value{ .bool = false };
        const start = self.pos;
        while (self.peek()) |byte| {
            if (!isScalarByte(byte)) break;
            self.pos += 1;
        }
        if (self.pos == start) return error.InvalidToml;
        return self.number(self.text[start..self.pos]);
    }

    fn number(self: *Parser, token: []const u8) Error!Value {
        if (std.mem.eql(u8, token, "inf") or std.mem.eql(u8, token, "+inf")) return Value{ .float = std.math.inf(f64) };
        if (std.mem.eql(u8, token, "-inf")) return Value{ .float = -std.math.inf(f64) };
        if (std.mem.eql(u8, token, "nan") or std.mem.eql(u8, token, "+nan") or std.mem.eql(u8, token, "-nan")) {
            return Value{ .float = std.math.nan(f64) };
        }
        const clean = try self.stripUnderscores(token);
        if (clean.len > 2 and clean[0] == '0') {
            const radix: ?u8 = switch (clean[1]) {
                'x' => 16,
                'o' => 8,
                'b' => 2,
                else => null,
            };
            if (radix) |base| {
                const integer = std.fmt.parseInt(i64, clean[2..], base) catch return error.InvalidToml;
                return Value{ .integer = integer };
            }
        }
        if (std.mem.findAny(u8, clean, ".eE") != null) {
            const float = std.fmt.parseFloat(f64, clean) catch return error.InvalidToml;
            return Value{ .float = float };
        }
        const integer = std.fmt.parseInt(i64, clean, 10) catch return error.InvalidToml;
        return Value{ .integer = integer };
    }

    fn stripUnderscores(self: *Parser, token: []const u8) Error![]const u8 {
        if (std.mem.findScalar(u8, token, '_') == null) return token;
        var out: std.ArrayList(u8) = .empty;
        for (token) |byte| {
            if (byte == '_') continue;
            try out.append(self.arena, byte);
        }
        return try out.toOwnedSlice(self.arena);
    }

    fn skipBlank(self: *Parser) void {
        while (self.peek()) |byte| {
            switch (byte) {
                ' ', '\t', '\n', '\r' => {
                    self.pos += 1;
                },
                '#' => self.skipComment(),
                else => return,
            }
        }
    }

    fn skipComment(self: *Parser) void {
        while (self.peek()) |byte| {
            if (byte == '\n') return;
            self.pos += 1;
        }
    }

    fn endOfLine(self: *Parser) Error!void {
        self.skipSpaces();
        if (self.peek() == '#') self.skipComment();
        if (self.pos >= self.text.len) return;
        _ = self.consume('\r');
        if (self.consume('\n')) return;
        return error.InvalidToml;
    }

    fn skipSpaces(self: *Parser) void {
        while (self.peek()) |byte| {
            if (byte != ' ' and byte != '\t') return;
            self.pos += 1;
        }
    }

    fn consumeKeyword(self: *Parser, word: []const u8) bool {
        if (!self.startsWith(word)) return false;
        const after = self.pos + word.len;
        if (after < self.text.len and isScalarByte(self.text[after])) return false;
        self.pos = after;
        return true;
    }

    fn startsWith(self: *Parser, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.text[self.pos..], prefix);
    }

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.text.len) return null;
        return self.text[self.pos];
    }

    fn next(self: *Parser) ?u8 {
        const byte = self.peek() orelse return null;
        self.pos += 1;
        return byte;
    }

    fn consume(self: *Parser, expected: u8) bool {
        if (self.peek() != expected) return false;
        self.pos += 1;
        return true;
    }
};

test "toml reader builds tables, dotted keys, arrays of tables and inline tables" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try parse(arena,
        \\top = "value"
        \\dotted.inner = 3
        \\[loop_control]
        \\max_steps_per_turn = 40
        \\compaction_trigger_ratio = 0.75
        \\[[hooks]]
        \\event = "PreToolUse"
        \\[[hooks]]
        \\event = "PostToolUse"
        \\[models.fast]
        \\model = "m1"
        \\overrides = { max_context_size = 1_000, capabilities = ["image_in"] }
        \\
    );
    try std.testing.expectEqualStrings("value", root.object.get("top").?.string);
    try std.testing.expectEqual(@as(i64, 3), root.object.get("dotted").?.object.get("inner").?.integer);
    const loop = root.object.get("loop_control").?.object;
    try std.testing.expectEqual(@as(i64, 40), loop.get("max_steps_per_turn").?.integer);
    try std.testing.expectEqual(@as(f64, 0.75), loop.get("compaction_trigger_ratio").?.float);
    const hooks = root.object.get("hooks").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), hooks.len);
    try std.testing.expectEqualStrings("PostToolUse", hooks[1].object.get("event").?.string);
    const fast = root.object.get("models").?.object.get("fast").?.object;
    try std.testing.expectEqualStrings("m1", fast.get("model").?.string);
    const overrides = fast.get("overrides").?.object;
    try std.testing.expectEqual(@as(i64, 1000), overrides.get("max_context_size").?.integer);
    try std.testing.expectEqualStrings("image_in", overrides.get("capabilities").?.array.items[0].string);
}

test "toml reader decodes string forms, number bases and booleans" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try parse(arena,
        \\basic = "tab\there \u00e9 \"q\""
        \\literal = 'C:\path'
        \\multi = """
        \\first
        \\second \
        \\third"""
        \\literal_multi = '''
        \\raw\n'''
        \\hex = 0xFF
        \\octal = 0o17
        \\binary = 0b101
        \\signed = -42
        \\exp = 1e3
        \\inf_value = inf
        \\flag = false
        \\
    );
    try std.testing.expectEqualStrings("tab\there \u{e9} \"q\"", root.object.get("basic").?.string);
    try std.testing.expectEqualStrings("C:\\path", root.object.get("literal").?.string);
    try std.testing.expectEqualStrings("first\nsecond third", root.object.get("multi").?.string);
    try std.testing.expectEqualStrings("raw\\n", root.object.get("literal_multi").?.string);
    try std.testing.expectEqual(@as(i64, 255), root.object.get("hex").?.integer);
    try std.testing.expectEqual(@as(i64, 15), root.object.get("octal").?.integer);
    try std.testing.expectEqual(@as(i64, 5), root.object.get("binary").?.integer);
    try std.testing.expectEqual(@as(i64, -42), root.object.get("signed").?.integer);
    try std.testing.expectEqual(@as(f64, 1000), root.object.get("exp").?.float);
    try std.testing.expect(std.math.isInf(root.object.get("inf_value").?.float));
    try std.testing.expectEqual(false, root.object.get("flag").?.bool);
}

test "toml reader rejects duplicate keys, bad values and unterminated input" {
    const cases = [_][]const u8{
        "a = 1\na = 2\n",
        "a = \n",
        "a = 1979-05-27\n",
        "[table\nx = 1\n",
        "a = \"unterminated\n",
        "a = [1, 2\n",
        "a = { b = 1 c = 2 }\n",
        "a = 1 b = 2\n",
        "t = 1\n[t]\n",
    };
    for (cases) |text| {
        var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena_state.deinit();
        try std.testing.expectError(error.InvalidToml, parse(arena_state.allocator(), text));
    }
}
