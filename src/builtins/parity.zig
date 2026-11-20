const std = @import("std");

const item1 = @import("../core/parity/item1.zig");
const item2 = @import("../core/parity/item2.zig");
const item3 = @import("../core/parity/item3.zig");
const item4 = @import("../core/parity/item4.zig");
const item5 = @import("../core/parity/item5.zig");
const item6 = @import("../core/parity/item6.zig");
const item7 = @import("../core/parity/item7.zig");
const item8 = @import("../core/parity/item8.zig");
const item9 = @import("../core/parity/item9.zig");
const item10 = @import("../core/parity/item10.zig");

const Allocator = std.mem.Allocator;

pub const context_test_env = "FX_TEST_PARITY_CONTEXT";

pub fn json(alloc: Allocator, args: []const []const u8) ![]const u8 {
    if (args.len < 2) return error.InvalidParityArguments;
    const item = std.fmt.parseInt(u8, args[0], 10) catch return error.InvalidParityItem;
    var json_flag = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) json_flag = true;
    }
    if (!json_flag) return error.MissingJsonFlag;
    const tail = args[1..];
    const text = switch (item) {
        1 => try item1.json(alloc, tail),
        2 => try item2.json(alloc, tail),
        3 => try item3.json(alloc, tail),
        4 => try item4.json(alloc, tail),
        5 => try item5.json(alloc, tail),
        6 => try item6.json(alloc, tail),
        7 => try item7.json(alloc, tail),
        8 => try item8.json(alloc, tail),
        9 => try item9.json(alloc, tail),
        10 => try item10.json(alloc, tail),
        else => return error.InvalidParityItem,
    };
    return text;
}

pub fn contextJson(alloc: Allocator, args: []const []const u8) ![]const u8 {
    return item1.json(alloc, args);
}

pub fn contextTestValue() ?[]const u8 {
    return item1.envValue(context_test_env);
}

pub fn askJson(alloc: Allocator, args: []const []const u8) ![]const u8 {
    return item1.askJson(alloc, args);
}

pub fn contextTestRequested(args: []const []const u8, value: ?[]const u8) bool {
    if (value == null or !std.mem.eql(u8, value.?, "1")) return false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) return true;
    }
    return false;
}
