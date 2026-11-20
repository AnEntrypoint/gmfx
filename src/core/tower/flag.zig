const std = @import("std");

pub const flag_name = "tower";
pub const env_variable = "KIMI_CODE_EXPERIMENTAL_TOWER";

pub fn enabled(experimental_tower: ?bool) bool {
    return experimental_tower orelse false;
}

test "Tower flag is off unless the experimental tower flag is on" {
    try std.testing.expect(!enabled(null));
    try std.testing.expect(!enabled(false));
    try std.testing.expect(enabled(true));
}
