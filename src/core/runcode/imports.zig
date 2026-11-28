const std = @import("std");

pub const Hoisted = struct {
    imports: []u8,
    code: []u8,

    pub fn deinit(self: Hoisted, alloc: std.mem.Allocator) void {
        alloc.free(self.imports);
        alloc.free(self.code);
    }
};

pub fn hoist(alloc: std.mem.Allocator, body: []const u8) !Hoisted {
    var imports: std.ArrayList(u8) = .empty;
    errdefer imports.deinit(alloc);
    var code: std.ArrayList(u8) = .empty;
    errdefer code.deinit(alloc);

    var index: usize = 0;
    var at_line_start = true;
    while (index < body.len) {
        if (at_line_start) {
            const start = skipBlanks(body, index);
            if (importKeywordEnd(body, start)) |keyword_end| {
                const statement_end = statementEnd(body, keyword_end);
                const statement = body[start..statement_end];
                for (body[index..start]) |c| try code.append(alloc, c);
                for (statement) |c| {
                    try imports.append(alloc, if (c == '\n') ' ' else c);
                    try code.append(alloc, if (c == '\n') '\n' else ' ');
                }
                if (statement.len == 0 or statement[statement.len - 1] != ';') try imports.append(alloc, ';');
                try imports.append(alloc, ' ');
                index = statement_end;
                at_line_start = false;
                continue;
            }
        }
        const c = body[index];
        try code.append(alloc, c);
        at_line_start = c == '\n' or (at_line_start and (c == ' ' or c == '\t'));
        index += 1;
    }

    return .{ .imports = try imports.toOwnedSlice(alloc), .code = try code.toOwnedSlice(alloc) };
}

fn skipBlanks(body: []const u8, from: usize) usize {
    var index = from;
    while (index < body.len and (body[index] == ' ' or body[index] == '\t')) index += 1;
    return index;
}

fn importKeywordEnd(body: []const u8, start: usize) ?usize {
    const keyword = "import";
    if (!std.mem.startsWith(u8, body[start..], keyword)) return null;
    const after = start + keyword.len;
    if (after >= body.len) return null;
    return switch (body[after]) {
        ' ', '\t', '\n', '\r', '{', '*', '"', '\'' => after,
        else => null,
    };
}

fn attributesEnd(body: []const u8, start: usize) ?usize {
    if (!std.mem.startsWith(u8, body[start..], "with")) return null;
    var index = skipBlanks(body, start + "with".len);
    if (index >= body.len or body[index] != '{') return null;
    while (index < body.len and body[index] != '}') index += 1;
    return if (index < body.len) index + 1 else null;
}

fn statementEnd(body: []const u8, from: usize) usize {
    var index = from;
    while (index < body.len) {
        switch (body[index]) {
            '"', '\'' => {
                const quote = body[index];
                index += 1;
                while (index < body.len and body[index] != quote) : (index += 1) {
                    if (body[index] == '\\') index += 1;
                }
                index = @min(index + 1, body.len);
                var after_blanks = skipBlanks(body, index);
                if (attributesEnd(body, after_blanks)) |end| {
                    index = end;
                    after_blanks = skipBlanks(body, index);
                }
                if (after_blanks < body.len and body[after_blanks] == ';') return after_blanks + 1;
                return index;
            },
            ';' => return index + 1,
            else => index += 1,
        }
    }
    return body.len;
}

test "hoist moves a multi-line import and keeps line numbers" {
    const body = "import {\n  a,\n  b\n} from 'x';\nconst v = a + b;\nreturn v;\n";
    const split = try hoist(std.testing.allocator, body);
    defer split.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("import {   a,   b } from 'x'; ", split.imports);
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, split.code, "\n"));
    try std.testing.expectEqualStrings("const v = a + b;\nreturn v;\n", split.code[split.code.len - 27 ..]);
}

test "hoist leaves dynamic import calls in place" {
    const body = "const m = await import('x');\nreturn m;\n";
    const split = try hoist(std.testing.allocator, body);
    defer split.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", split.imports);
    try std.testing.expectEqualStrings(body, split.code);
}

test "an import attributes clause stays inside the hoisted import" {
    const body = "import data from './d.json' with { type: 'json' }\nreturn data;\n";
    const split = try hoist(std.testing.allocator, body);
    defer split.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("import data from './d.json' with { type: 'json' }; ", split.imports);
}
