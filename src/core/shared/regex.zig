const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_instructions: usize = 1 << 16;
pub const max_repeat: u32 = 1000;

pub const CompileError = error{ InvalidPattern, TooComplex } || Allocator.Error;

pub const Options = struct {
    case_insensitive: bool = false,
    dot_matches_newline: bool = false,
};

pub const Span = struct {
    start: usize,
    end: usize,
};

const ByteSet = [256]bool;

const Assertion = enum { line_start, line_end, word_boundary, not_word_boundary };

const Node = union(enum) {
    set: usize,
    assertion: Assertion,
    empty,
    concat: []const Node,
    alternation: []const Node,
    repeat: Repeat,
};

const Repeat = struct {
    body: *const Node,
    min: u32,
    max: ?u32,
    greedy: bool,
};

const Bounds = struct {
    min: u32,
    max: ?u32,
};

const Inst = union(enum) {
    set: usize,
    assertion: Assertion,
    split: Split,
    jump: usize,
    match,
};

const Split = struct {
    first: usize,
    second: usize,
};

pub const Program = struct {
    insts: []const Inst,
    sets: []const ByteSet,
};

fn emptySet() ByteSet {
    return @splat(false);
}

fn setRange(set: *ByteSet, low: u8, high: u8) void {
    var byte: usize = low;
    while (byte <= high) : (byte += 1) set[byte] = true;
}

fn foldCase(set: *ByteSet) void {
    var byte: usize = 'a';
    while (byte <= 'z') : (byte += 1) {
        const upper = byte - 'a' + 'A';
        if (set[byte] or set[upper]) {
            set[byte] = true;
            set[upper] = true;
        }
    }
}

fn invert(set: *ByteSet) void {
    for (set) |*value| value.* = !value.*;
}

fn mergeSet(into: *ByteSet, from: ByteSet) void {
    for (into, from) |*target, value| target.* = target.* or value;
}

fn classEscapeSet(byte: u8) ?ByteSet {
    var set = emptySet();
    switch (byte) {
        'd', 'D' => setRange(&set, '0', '9'),
        'w', 'W' => {
            setRange(&set, '0', '9');
            setRange(&set, 'a', 'z');
            setRange(&set, 'A', 'Z');
            set['_'] = true;
        },
        's', 'S' => {
            for (" \t\n\r\x0b\x0c") |space| set[space] = true;
        },
        else => return null,
    }
    if (byte == 'D' or byte == 'W' or byte == 'S') invert(&set);
    return set;
}

fn escapedByte(byte: u8) ?u8 {
    return switch (byte) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        'f' => 0x0c,
        'v' => 0x0b,
        '0' => 0,
        else => if (std.ascii.isAlphanumeric(byte)) null else byte,
    };
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn assertionHolds(kind: Assertion, text: []const u8, position: usize) bool {
    const before = position > 0 and isWordByte(text[position - 1]);
    const after = position < text.len and isWordByte(text[position]);
    return switch (kind) {
        .line_start => position == 0,
        .line_end => position == text.len,
        .word_boundary => before != after,
        .not_word_boundary => before == after,
    };
}

const Parser = struct {
    arena: Allocator,
    pattern: []const u8,
    options: Options,
    index: usize = 0,
    sets: std.ArrayList(ByteSet) = .empty,

    fn peek(self: *const Parser) ?u8 {
        return if (self.index < self.pattern.len) self.pattern[self.index] else null;
    }

    fn peekAt(self: *const Parser, offset: usize) ?u8 {
        const at = self.index + offset;
        return if (at < self.pattern.len) self.pattern[at] else null;
    }

    fn next(self: *Parser) ?u8 {
        const byte = self.peek() orelse return null;
        self.index += 1;
        return byte;
    }

    fn eat(self: *Parser, expected: u8) bool {
        if (self.peek() != expected) return false;
        self.index += 1;
        return true;
    }

    fn addSet(self: *Parser, set: ByteSet) CompileError!usize {
        try self.sets.append(self.arena, set);
        return self.sets.items.len - 1;
    }

    fn parseAlternation(self: *Parser) CompileError!Node {
        var branches: std.ArrayList(Node) = .empty;
        try branches.append(self.arena, try self.parseConcat());
        while (self.eat('|')) {
            try branches.append(self.arena, try self.parseConcat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return .{ .alternation = try branches.toOwnedSlice(self.arena) };
    }

    fn parseConcat(self: *Parser) CompileError!Node {
        var items: std.ArrayList(Node) = .empty;
        while (self.peek()) |byte| {
            if (byte == '|' or byte == ')') break;
            try items.append(self.arena, try self.parseRepeat());
        }
        if (items.items.len == 0) return .empty;
        if (items.items.len == 1) return items.items[0];
        return .{ .concat = try items.toOwnedSlice(self.arena) };
    }

    fn parseRepeat(self: *Parser) CompileError!Node {
        const atom = try self.parseAtom();
        const bounds = (try self.parseQuantifier()) orelse return atom;
        const body = try self.arena.create(Node);
        body.* = atom;
        const greedy = !self.eat('?');
        if (self.peek()) |byte| {
            if (byte == '*' or byte == '+' or byte == '?' or byte == '{') return error.InvalidPattern;
        }
        return .{ .repeat = .{ .body = body, .min = bounds.min, .max = bounds.max, .greedy = greedy } };
    }

    fn parseQuantifier(self: *Parser) CompileError!?Bounds {
        const byte = self.peek() orelse return null;
        return switch (byte) {
            '*' => blk: {
                self.index += 1;
                break :blk Bounds{ .min = 0, .max = null };
            },
            '+' => blk: {
                self.index += 1;
                break :blk Bounds{ .min = 1, .max = null };
            },
            '?' => blk: {
                self.index += 1;
                break :blk Bounds{ .min = 0, .max = 1 };
            },
            '{' => try self.parseBraces(),
            else => null,
        };
    }

    fn parseBraces(self: *Parser) CompileError!Bounds {
        self.index += 1;
        const min = try self.parseNumber();
        var max: ?u32 = min;
        if (self.eat(',')) {
            max = if (self.peek() == '}') null else try self.parseNumber();
        }
        if (!self.eat('}')) return error.InvalidPattern;
        if (max) |upper| {
            if (upper < min) return error.InvalidPattern;
        }
        if (min > max_repeat or (max orelse 0) > max_repeat) return error.TooComplex;
        return .{ .min = min, .max = max };
    }

    fn parseNumber(self: *Parser) CompileError!u32 {
        var value: u32 = 0;
        var digits: usize = 0;
        while (self.peek()) |byte| {
            if (!std.ascii.isDigit(byte)) break;
            self.index += 1;
            digits += 1;
            value = std.math.mul(u32, value, 10) catch return error.TooComplex;
            value = std.math.add(u32, value, byte - '0') catch return error.TooComplex;
        }
        if (digits == 0) return error.InvalidPattern;
        return value;
    }

    fn parseAtom(self: *Parser) CompileError!Node {
        const byte = self.next() orelse return error.InvalidPattern;
        return switch (byte) {
            '(' => blk: {
                if (self.eat('?') and !self.eat(':')) return error.InvalidPattern;
                const inner = try self.parseAlternation();
                if (!self.eat(')')) return error.InvalidPattern;
                break :blk inner;
            },
            '[' => .{ .set = try self.parseClass() },
            '.' => .{ .set = try self.addSet(self.dotSet()) },
            '^' => .{ .assertion = .line_start },
            '$' => .{ .assertion = .line_end },
            '*', '+', '?', '{' => error.InvalidPattern,
            '\\' => try self.parseEscape(),
            else => .{ .set = try self.literal(byte) },
        };
    }

    fn dotSet(self: *const Parser) ByteSet {
        var set: ByteSet = @splat(true);
        if (!self.options.dot_matches_newline) set['\n'] = false;
        return set;
    }

    fn literal(self: *Parser, byte: u8) CompileError!usize {
        var set = emptySet();
        set[byte] = true;
        if (self.options.case_insensitive) foldCase(&set);
        return self.addSet(set);
    }

    fn parseEscape(self: *Parser) CompileError!Node {
        const byte = self.next() orelse return error.InvalidPattern;
        if (byte == 'b') return .{ .assertion = .word_boundary };
        if (byte == 'B') return .{ .assertion = .not_word_boundary };
        if (classEscapeSet(byte)) |set| return .{ .set = try self.addSet(set) };
        const literal_byte = escapedByte(byte) orelse return error.InvalidPattern;
        return .{ .set = try self.literal(literal_byte) };
    }

    fn parseClass(self: *Parser) CompileError!usize {
        var set = emptySet();
        const negated = self.eat('^');
        var first = true;
        while (true) {
            const byte = self.next() orelse return error.InvalidPattern;
            if (byte == ']' and !first) break;
            first = false;
            var low = byte;
            if (byte == '\\') {
                const escaped = self.next() orelse return error.InvalidPattern;
                if (classEscapeSet(escaped)) |class| {
                    mergeSet(&set, class);
                    continue;
                }
                low = escapedByte(escaped) orelse return error.InvalidPattern;
            }
            var high = low;
            const range_follows = self.peek() == '-' and self.peekAt(1) != null and self.peekAt(1) != ']';
            if (range_follows) {
                self.index += 1;
                const raw = self.next() orelse return error.InvalidPattern;
                if (raw == '\\') {
                    const escaped = self.next() orelse return error.InvalidPattern;
                    high = escapedByte(escaped) orelse return error.InvalidPattern;
                } else {
                    high = raw;
                }
                if (high < low) return error.InvalidPattern;
            }
            setRange(&set, low, high);
        }
        if (self.options.case_insensitive) foldCase(&set);
        if (negated) invert(&set);
        return self.addSet(set);
    }
};

const Compiler = struct {
    arena: Allocator,
    insts: std.ArrayList(Inst) = .empty,

    fn emit(self: *Compiler, inst: Inst) CompileError!usize {
        if (self.insts.items.len >= max_instructions) return error.TooComplex;
        try self.insts.append(self.arena, inst);
        return self.insts.items.len - 1;
    }

    fn compile(self: *Compiler, node: Node) CompileError!void {
        switch (node) {
            .set => |index| {
                _ = try self.emit(.{ .set = index });
            },
            .assertion => |kind| {
                _ = try self.emit(.{ .assertion = kind });
            },
            .empty => {},
            .concat => |items| {
                for (items) |item| try self.compile(item);
            },
            .alternation => |branches| try self.compileAlternation(branches),
            .repeat => |repeat| try self.compileRepeat(repeat),
        }
    }

    fn compileAlternation(self: *Compiler, branches: []const Node) CompileError!void {
        var jumps: std.ArrayList(usize) = .empty;
        for (branches, 0..) |branch, index| {
            if (index + 1 == branches.len) {
                try self.compile(branch);
                continue;
            }
            const split = try self.emit(.{ .split = .{ .first = 0, .second = 0 } });
            self.insts.items[split].split.first = self.insts.items.len;
            try self.compile(branch);
            try jumps.append(self.arena, try self.emit(.{ .jump = 0 }));
            self.insts.items[split].split.second = self.insts.items.len;
        }
        for (jumps.items) |jump| self.insts.items[jump].jump = self.insts.items.len;
    }

    fn compileRepeat(self: *Compiler, repeat: Repeat) CompileError!void {
        var count: u32 = 0;
        while (count < repeat.min) : (count += 1) try self.compile(repeat.body.*);
        if (repeat.max) |max| {
            var optional_splits: std.ArrayList(usize) = .empty;
            var extra = repeat.min;
            while (extra < max) : (extra += 1) {
                try optional_splits.append(self.arena, try self.emit(.{ .split = .{ .first = 0, .second = 0 } }));
                try self.compile(repeat.body.*);
            }
            const exit = self.insts.items.len;
            for (optional_splits.items) |split| self.wireSplit(split, split + 1, exit, repeat.greedy);
            return;
        }
        const loop = try self.emit(.{ .split = .{ .first = 0, .second = 0 } });
        try self.compile(repeat.body.*);
        _ = try self.emit(.{ .jump = loop });
        self.wireSplit(loop, loop + 1, self.insts.items.len, repeat.greedy);
    }

    fn wireSplit(self: *Compiler, split: usize, body: usize, exit: usize, greedy: bool) void {
        self.insts.items[split].split = if (greedy)
            .{ .first = body, .second = exit }
        else
            .{ .first = exit, .second = body };
    }
};

pub fn compile(arena: Allocator, pattern: []const u8, options: Options) CompileError!Program {
    var parser: Parser = .{ .arena = arena, .pattern = pattern, .options = options };
    const root = try parser.parseAlternation();
    if (parser.index != pattern.len) return error.InvalidPattern;
    var compiler: Compiler = .{ .arena = arena };
    try compiler.compile(root);
    _ = try compiler.emit(.match);
    return .{
        .insts = try compiler.insts.toOwnedSlice(arena),
        .sets = try parser.sets.toOwnedSlice(arena),
    };
}

const Thread = struct {
    pc: usize,
    start: usize,
};

const ThreadList = struct {
    items: []Thread,
    len: usize = 0,
};

pub const Matcher = struct {
    program: Program,
    current: ThreadList,
    next: ThreadList,
    seen: []usize,
    generation: usize = 0,

    pub fn init(arena: Allocator, program: Program) Allocator.Error!Matcher {
        const size = program.insts.len;
        const seen = try arena.alloc(usize, size);
        @memset(seen, 0);
        return .{
            .program = program,
            .current = .{ .items = try arena.alloc(Thread, size) },
            .next = .{ .items = try arena.alloc(Thread, size) },
            .seen = seen,
        };
    }

    pub fn find(self: *Matcher, text: []const u8, from: usize) ?Span {
        var best: ?Span = null;
        self.current.len = 0;
        self.generation += 1;
        var generation = self.generation;
        var position = from;
        while (true) {
            if (best == null) self.addThread(&self.current, 0, position, text, generation, position);
            self.generation += 1;
            const next_generation = self.generation;
            self.next.len = 0;
            for (self.current.items[0..self.current.len]) |thread| {
                switch (self.program.insts[thread.pc]) {
                    .match => {
                        best = .{ .start = thread.start, .end = position };
                        break;
                    },
                    .set => |index| {
                        if (position < text.len and self.program.sets[index][text[position]]) {
                            self.addThread(&self.next, thread.pc + 1, thread.start, text, next_generation, position + 1);
                        }
                    },
                    .assertion, .split, .jump => {},
                }
            }
            if (position >= text.len) break;
            if (self.next.len == 0 and best != null) break;
            std.mem.swap(ThreadList, &self.current, &self.next);
            generation = next_generation;
            position += 1;
        }
        return best;
    }

    pub fn matches(self: *Matcher, text: []const u8) bool {
        return self.find(text, 0) != null;
    }

    fn addThread(self: *Matcher, list: *ThreadList, pc: usize, start: usize, text: []const u8, generation: usize, position: usize) void {
        if (self.seen[pc] == generation) return;
        self.seen[pc] = generation;
        switch (self.program.insts[pc]) {
            .jump => |target| self.addThread(list, target, start, text, generation, position),
            .split => |split| {
                self.addThread(list, split.first, start, text, generation, position);
                self.addThread(list, split.second, start, text, generation, position);
            },
            .assertion => |kind| {
                if (assertionHolds(kind, text, position)) self.addThread(list, pc + 1, start, text, generation, position);
            },
            .set, .match => {
                list.items[list.len] = .{ .pc = pc, .start = start };
                list.len += 1;
            },
        }
    }
};

fn expectSpan(pattern: []const u8, options: Options, text: []const u8, from: usize, start: ?usize, end: ?usize) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const program = try compile(arena, pattern, options);
    var matcher = try Matcher.init(arena, program);
    const found = matcher.find(text, from);
    if (start == null) {
        try std.testing.expect(found == null);
        return;
    }
    const span = found orelse return error.TestExpectedMatch;
    try std.testing.expectEqual(start.?, span.start);
    try std.testing.expectEqual(end.?, span.end);
}

fn expectInvalid(pattern: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.InvalidPattern, compile(arena_state.allocator(), pattern, .{}));
}

test "regex literals match leftmost occurrence" {
    try expectSpan("needle", .{}, "hay needle hay", 0, 4, 10);
    try expectSpan("needle", .{}, "hay only", 0, null, null);
}

test "regex dot and quantifiers follow leftmost-first semantics" {
    try expectSpan("a.c", .{}, "xxabcxx", 0, 2, 5);
    try expectSpan("ab*", .{}, "abbbc", 0, 0, 4);
    try expectSpan("ab*?", .{}, "abbbc", 0, 0, 1);
    try expectSpan("ab+", .{}, "ac ab", 0, 3, 5);
    try expectSpan("colou?r", .{}, "color", 0, 0, 5);
    try expectSpan("x{2,3}", .{}, "xxxxx", 0, 0, 3);
    try expectSpan("x{2}", .{}, "x xx", 0, 2, 4);
    try expectSpan("x{2,}", .{}, "x xxxx", 0, 2, 6);
}

test "regex alternation and groups" {
    try expectSpan("cat|dog", .{}, "hotdog", 0, 3, 6);
    try expectSpan("(ab)+c", .{}, "xababc", 0, 1, 6);
    try expectSpan("(?:ab|cd)e", .{}, "cde", 0, 0, 3);
}

test "regex classes escapes and anchors" {
    try expectSpan("[0-9]+", .{}, "id 42x", 0, 3, 5);
    try expectSpan("[^a-z]", .{}, "abc1", 0, 3, 4);
    try expectSpan("\\d\\w\\s", .{}, "--7a !", 0, 2, 5);
    try expectSpan("\\.", .{}, "a.b", 0, 1, 2);
    try expectSpan("^abc", .{}, "xabc", 0, null, null);
    try expectSpan("^abc", .{}, "abc", 0, 0, 3);
    try expectSpan("abc$", .{}, "abcx", 0, null, null);
    try expectSpan("\\bcat\\b", .{}, "concat cat", 0, 7, 10);
}

test "regex case-insensitive folds ASCII letters" {
    try expectSpan("NeEdLe", .{ .case_insensitive = true }, "a needle", 0, 2, 8);
    try expectSpan("[a-c]+", .{ .case_insensitive = true }, "xABC", 0, 1, 4);
}

test "regex dot matches newline only when enabled" {
    try expectSpan("a.b", .{}, "a\nb", 0, null, null);
    try expectSpan("a.b", .{ .dot_matches_newline = true }, "a\nb", 0, 0, 3);
}

test "regex rejects malformed patterns" {
    try expectInvalid("(ab");
    try expectInvalid("ab)");
    try expectInvalid("*a");
    try expectInvalid("[abc");
    try expectInvalid("a{2,1}");
    try expectInvalid("a{x}");
    try expectInvalid("\\q");
}
