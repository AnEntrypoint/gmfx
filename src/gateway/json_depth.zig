const std = @import("std");
const text_utils = @import("../core/shared/text_utils.zig");

pub const max_depth = 64;

pub fn exceeds(text: []const u8) bool {
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (text) |byte| {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') quoted = false;
        } else switch (byte) {
            '"' => quoted = true,
            '{', '[' => {
                if (depth == max_depth) return true;
                depth += 1;
            },
            '}', ']' => if (depth > 0) {
                depth -= 1;
            },
            else => {},
        }
    }
    return false;
}

test "json depth allows the limit and rejects one level past it" {
    const at_limit = text_utils.repeat("[", max_depth) ++ text_utils.repeat("]", max_depth);
    const past_limit = text_utils.repeat("[", max_depth + 1) ++ text_utils.repeat("]", max_depth + 1);
    try std.testing.expect(!exceeds(at_limit));
    try std.testing.expect(exceeds(past_limit));
    try std.testing.expect(exceeds("{\"a\":" ++ text_utils.repeat("{\"a\":", max_depth) ++ "0" ++ text_utils.repeat("}", max_depth + 1)));
}

test "json depth ignores brackets in strings and stray closers" {
    const quoted = "{\"text\":\"" ++ text_utils.repeat("[{", 200) ++ "\\\"\"}";
    try std.testing.expect(!exceeds(quoted));
    try std.testing.expect(!exceeds(text_utils.repeat("]}", 200) ++ "[]"));

    try std.testing.expect(!exceeds(text_utils.repeat("{}", 10_000)));
}
