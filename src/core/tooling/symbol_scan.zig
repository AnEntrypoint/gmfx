const std = @import("std");

pub const Language = enum {
    zig,
    generic,

    pub fn ofPath(path: []const u8) Language {
        return if (std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, ".zon")) .zig else .generic;
    }
};

pub const OccurrenceKind = enum {
    definition,
    call,
    member,

    pub fn label(self: OccurrenceKind) []const u8 {
        return @tagName(self);
    }
};

pub const Import = struct {
    specifier: []const u8,
    dotted: bool = false,
};

pub const max_name_bytes: usize = 128;

pub fn isIdentifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$' or byte >= 0x80;
}

pub fn isIdentifier(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    if (std.ascii.isDigit(name[0])) return false;
    for (name) |byte| {
        if (!isIdentifierByte(byte)) return false;
    }
    return true;
}

const zig_definition_keywords = [_][]const u8{"fn"};
const zig_binding_keywords = [_][]const u8{ "const", "var" };
const generic_definition_keywords = [_][]const u8{
    "function",  "function*", "def",  "func",   "fn",        "class",  "struct",
    "interface", "enum",      "type", "trait",  "module",    "sub",    "macro",
    "defp",      "fun",       "proc", "object", "namespace", "record", "union",
};
const generic_binding_keywords = [_][]const u8{ "const", "let", "var", "static", "val" };
const not_a_type_words = [_][]const u8{
    "return", "new",   "else",  "await", "yield",  "throw",  "case",  "in",  "of",
    "and",    "or",    "not",   "if",    "while",  "for",    "do",    "try", "typeof",
    "delete", "print", "raise", "from",  "import", "export", "defer", "go",
};
const not_a_call_names = [_][]const u8{
    "if",       "for",    "while",    "switch", "return", "fn",     "function", "def",    "catch",
    "sizeof",   "defer",  "try",      "else",   "elif",   "and",    "or",       "not",    "in",
    "func",     "match",  "typeof",   "await",  "new",    "throw",  "class",    "struct", "union",
    "errdefer", "orelse", "comptime", "inline", "test",   "assert", "print",    "super",  "this",
    "self",     "do",     "with",     "lambda", "except", "raise",  "yield",    "delete", "enum",
};

pub fn isCommentLine(line: []const u8, language: Language) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, trimmed, "//")) return true;
    if (language == .zig) return false;
    if (std.mem.startsWith(u8, trimmed, "/*") or std.mem.startsWith(u8, trimmed, "* ") or std.mem.eql(u8, trimmed, "*")) return true;
    if (std.mem.startsWith(u8, trimmed, "# ") or std.mem.startsWith(u8, trimmed, "#!")) return true;
    return false;
}

pub fn classify(line: []const u8, name: []const u8, language: Language) ?OccurrenceKind {
    if (name.len == 0 or line.len < name.len) return null;
    if (isCommentLine(line, language)) return null;
    var best: ?OccurrenceKind = null;
    var from: usize = 0;
    while (std.mem.findPos(u8, line, from, name)) |at| {
        from = at + 1;
        const end = at + name.len;
        if (at > 0 and isIdentifierByte(line[at - 1])) continue;
        if (end < line.len and isIdentifierByte(line[end])) continue;
        const kind = classifyAt(line, at, end, language) orelse continue;
        if (kind == .definition) return .definition;
        if (best == null or (best.? == .member and kind == .call)) best = kind;
    }
    return best;
}

fn classifyAt(line: []const u8, at: usize, end: usize, language: Language) ?OccurrenceKind {
    const before = std.mem.trimEnd(u8, line[0..at], " \t");
    const after = std.mem.trimStart(u8, line[end..], " \t");
    const opens_call = end < line.len and line[end] == '(';
    const previous_word = lastWord(before);

    switch (language) {
        .zig => {
            if (wordIn(previous_word, &zig_definition_keywords)) return .definition;
            if (wordIn(previous_word, &zig_binding_keywords) and (std.mem.startsWith(u8, after, "=") or std.mem.startsWith(u8, after, ":"))) return .definition;
        },
        .generic => {
            if (wordIn(previous_word, &generic_definition_keywords)) return .definition;
            if (wordIn(previous_word, &generic_binding_keywords) and assignsCallable(after)) return .definition;
            if (before.len == 0 and assignsCallable(after)) return .definition;
            if (opens_call and declaresWithBody(line, before, end)) return .definition;
        },
    }

    if (!opens_call) return null;
    if (before.len > 0 and before.len == at and before[before.len - 1] == '.') return .member;
    if (before.len > 1 and before.len == at and std.mem.endsWith(u8, before, "->")) return .member;
    if (before.len > 1 and before.len == at and std.mem.endsWith(u8, before, "::")) return .member;
    return .call;
}

fn assignsCallable(after: []const u8) bool {
    var rest = after;
    if (std.mem.startsWith(u8, rest, ":")) {
        rest = std.mem.trimStart(u8, rest[1..], " \t");
        return std.mem.startsWith(u8, rest, "function") or std.mem.startsWith(u8, rest, "async") or (std.mem.startsWith(u8, rest, "(") and std.mem.find(u8, rest, "=>") != null);
    }
    if (!std.mem.startsWith(u8, rest, "=") or std.mem.startsWith(u8, rest, "==")) return false;
    rest = std.mem.trimStart(u8, rest[1..], " \t");
    if (std.mem.startsWith(u8, rest, "function") or std.mem.startsWith(u8, rest, "async") or std.mem.startsWith(u8, rest, "lambda")) return true;
    return std.mem.find(u8, rest, "=>") != null;
}

fn declaresWithBody(line: []const u8, before: []const u8, name_end: usize) bool {
    const close = matchingParen(line, name_end) orelse return false;
    const tail = std.mem.trim(u8, line[close + 1 ..], " \t\r");
    if (tail.len == 0 or tail[tail.len - 1] != '{') return false;
    for (tail[0 .. tail.len - 1]) |byte| {
        if (byte == '(' or byte == ')' or byte == ';' or byte == '=') return false;
    }
    if (before.len == 0) return true;
    for (before) |byte| {
        if (isIdentifierByte(byte)) continue;
        switch (byte) {
            ' ', '\t', '*', '&', '<', '>', ':', ',', '[', ']' => {},
            else => return false,
        }
    }
    return !wordIn(lastWord(before), &not_a_type_words);
}

fn matchingParen(line: []const u8, open: usize) ?usize {
    if (open >= line.len or line[open] != '(') return null;
    var depth: usize = 0;
    var index = open;
    while (index < line.len) : (index += 1) {
        switch (line[index]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return index;
            },
            else => {},
        }
    }
    return null;
}

fn lastWord(text: []const u8) []const u8 {
    var start = text.len;
    while (start > 0 and (isIdentifierByte(text[start - 1]) or text[start - 1] == '*')) start -= 1;
    return text[start..];
}

fn wordIn(word: []const u8, words: []const []const u8) bool {
    if (word.len == 0) return false;
    for (words) |candidate| {
        if (std.mem.eql(u8, candidate, word)) return true;
    }
    return false;
}

pub fn callNames(line: []const u8, language: Language, sink: anytype) !void {
    if (isCommentLine(line, language)) return;
    var index: usize = 0;
    while (index < line.len) {
        if (!isIdentifierByte(line[index])) {
            index += 1;
            continue;
        }
        const start = index;
        while (index < line.len and isIdentifierByte(line[index])) index += 1;
        if (index >= line.len or line[index] != '(') continue;
        const name = line[start..index];
        if (!isIdentifier(name) or name.len < 3) continue;
        if (start > 0 and line[start - 1] == '@') continue;
        if (wordIn(name, &not_a_call_names)) continue;
        if (classifyAt(line, start, index, language) == .definition) continue;
        try sink.add(name);
    }
}

pub fn importOf(line: []const u8, language: Language) ?Import {
    if (isCommentLine(line, language)) return null;
    switch (language) {
        .zig => {
            const quoted = quotedAfter(line, "@import(") orelse return null;
            if (!std.mem.endsWith(u8, quoted, ".zig")) return null;
            return .{ .specifier = quoted };
        },
        .generic => {},
    }
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, trimmed, "#include")) {
        const rest = std.mem.trimStart(u8, trimmed["#include".len..], " \t");
        if (rest.len < 2 or rest[0] != '"') return null;
        const close = std.mem.findScalarPos(u8, rest, 1, '"') orelse return null;
        return nonEmpty(rest[1..close]);
    }
    if (quotedAfter(line, "require(")) |quoted| return nonEmpty(quoted);
    if (quotedAfter(line, "import(")) |quoted| return nonEmpty(quoted);
    if (std.mem.startsWith(u8, trimmed, "import ") or std.mem.startsWith(u8, trimmed, "export ")) {
        if (std.mem.find(u8, trimmed, " from ")) |from_at| {
            if (firstQuoted(trimmed[from_at + " from ".len ..])) |quoted| return nonEmpty(quoted);
        }
        if (std.mem.startsWith(u8, trimmed, "import ")) {
            const rest = std.mem.trimStart(u8, trimmed["import ".len..], " \t");
            if (rest.len > 0 and (rest[0] == '"' or rest[0] == '\'')) {
                if (firstQuoted(rest)) |quoted| return nonEmpty(quoted);
            }
            if (std.mem.findAny(u8, rest, "\"'{(") == null) return dottedModule(rest);
        }
        return null;
    }
    if (std.mem.startsWith(u8, trimmed, "from ")) {
        const rest = std.mem.trimStart(u8, trimmed["from ".len..], " \t");
        if (std.mem.find(u8, rest, " import ") == null) return null;
        return dottedModule(rest);
    }
    return null;
}

fn nonEmpty(specifier: []const u8) ?Import {
    if (specifier.len == 0) return null;
    return .{ .specifier = specifier };
}

fn dottedModule(rest: []const u8) ?Import {
    var end: usize = 0;
    while (end < rest.len and (isIdentifierByte(rest[end]) or rest[end] == '.')) end += 1;
    if (end == 0) return null;
    return .{ .specifier = rest[0..end], .dotted = true };
}

fn quotedAfter(line: []const u8, marker: []const u8) ?[]const u8 {
    const at = std.mem.find(u8, line, marker) orelse return null;
    const rest = std.mem.trimStart(u8, line[at + marker.len ..], " \t");
    if (rest.len == 0 or (rest[0] != '"' and rest[0] != '\'' and rest[0] != '`')) return null;
    return firstQuoted(rest);
}

fn firstQuoted(text: []const u8) ?[]const u8 {
    const open = std.mem.findAny(u8, text, "\"'`") orelse return null;
    const close = std.mem.findScalarPos(u8, text, open + 1, text[open]) orelse return null;
    return text[open + 1 .. close];
}

const TestNames = struct {
    names: [8][]const u8 = undefined,
    len: usize = 0,

    pub fn add(self: *TestNames, name: []const u8) !void {
        if (self.len == self.names.len) return error.TooManyNames;
        self.names[self.len] = name;
        self.len += 1;
    }
};

test "symbol scan classifies Zig definitions, calls, member calls and plain mentions" {
    try std.testing.expectEqual(OccurrenceKind.definition, classify("pub fn parseRetry(text: []const u8) !u32 {", "parseRetry", .zig).?);
    try std.testing.expectEqual(OccurrenceKind.definition, classify("    fn parseRetry(self: *Self) void {", "parseRetry", .zig).?);
    try std.testing.expectEqual(OccurrenceKind.definition, classify("const parseRetry = @import(\"retry.zig\").parse;", "parseRetry", .zig).?);
    try std.testing.expectEqual(OccurrenceKind.definition, classify("pub const Limits: type = struct {", "Limits", .zig).?);
    try std.testing.expectEqual(OccurrenceKind.call, classify("    const wait = try parseRetry(header);", "parseRetry", .zig).?);
    try std.testing.expectEqual(OccurrenceKind.member, classify("    const wait = retry.parseRetry(header);", "parseRetry", .zig).?);
    try std.testing.expectEqual(OccurrenceKind.call, classify("    return parseRetry(a) + other.parseRetry(b);", "parseRetry", .zig).?);
    try std.testing.expectEqual(@as(?OccurrenceKind, null), classify("    .decode = parseRetry,", "parseRetry", .zig));
    try std.testing.expectEqual(@as(?OccurrenceKind, null), classify("    const x = parseRetryAfter(header);", "parseRetry", .zig));
    try std.testing.expectEqual(@as(?OccurrenceKind, null), classify("    // parseRetry(header) is called later", "parseRetry", .zig));
}

test "symbol scan classifies definitions and calls in other languages" {
    try std.testing.expectEqual(OccurrenceKind.definition, classify("export function loadConfig(path) {", "loadConfig", .generic).?);
    try std.testing.expectEqual(OccurrenceKind.definition, classify("def load_config(path):", "load_config", .generic).?);
    try std.testing.expectEqual(OccurrenceKind.definition, classify("func LoadConfig(path string) (*Config, error) {", "LoadConfig", .generic).?);
    try std.testing.expectEqual(OccurrenceKind.definition, classify("class LoadConfig:", "LoadConfig", .generic).?);
    try std.testing.expectEqual(OccurrenceKind.definition, classify("const loadConfig = async (path) => {", "loadConfig", .generic).?);
    try std.testing.expectEqual(OccurrenceKind.definition, classify("static int load_config(const char *path) {", "load_config", .generic).?);
    try std.testing.expectEqual(OccurrenceKind.definition, classify("  loadConfig(path) {", "loadConfig", .generic).?);
    try std.testing.expectEqual(OccurrenceKind.call, classify("  const config = loadConfig(path);", "loadConfig", .generic).?);
    try std.testing.expectEqual(OccurrenceKind.call, classify("  return loadConfig(path, function () {", "loadConfig", .generic).?);
    try std.testing.expectEqual(OccurrenceKind.member, classify("  settings.loadConfig(path)", "loadConfig", .generic).?);
    try std.testing.expectEqual(OccurrenceKind.member, classify("  settings->load_config(path);", "load_config", .generic).?);
    try std.testing.expectEqual(@as(?OccurrenceKind, null), classify("# loadConfig(path) reads the file", "loadConfig", .generic));
    try std.testing.expectEqual(@as(?OccurrenceKind, null), classify("  handlers.push(loadConfig);", "loadConfig", .generic));
}

test "symbol scan reads import edges for Zig and other languages" {
    try std.testing.expectEqualStrings("../shared/io.zig", importOf("const io_mod = @import(\"../shared/io.zig\");", .zig).?.specifier);
    try std.testing.expectEqual(@as(?Import, null), importOf("const std = @import(\"std\");", .zig));
    try std.testing.expectEqualStrings("./config", importOf("import { load } from './config';", .generic).?.specifier);
    try std.testing.expectEqualStrings("./side-effect.js", importOf("import \"./side-effect.js\";", .generic).?.specifier);
    try std.testing.expectEqualStrings("../util", importOf("const util = require('../util');", .generic).?.specifier);
    try std.testing.expectEqualStrings("util.h", importOf("#include \"util.h\"", .generic).?.specifier);
    try std.testing.expectEqual(@as(?Import, null), importOf("#include <stdio.h>", .generic));
    const python = importOf("from app.settings import load", .generic).?;
    try std.testing.expectEqualStrings("app.settings", python.specifier);
    try std.testing.expect(python.dotted);
    try std.testing.expectEqualStrings("os.path", importOf("import os.path", .generic).?.specifier);
}

test "symbol scan lists called names and skips keywords, builtins and definitions" {
    var names: TestNames = .{};
    try callNames("    if (ready) return finish(try loadConfig(path), @intCast(count));", .zig, &names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("finish", names.names[0]);
    try std.testing.expectEqualStrings("loadConfig", names.names[1]);

    var defined: TestNames = .{};
    try callNames("pub fn loadConfig(path: []const u8) !Config {", .zig, &defined);
    try std.testing.expectEqual(@as(usize, 0), defined.len);
}
