const std = @import("std");
const todo_list = @import("todo_list.zig");
const text_utils = @import("../shared/text_utils.zig");

pub const max_named_items: usize = 5;
pub const max_title_bytes: usize = 120;
pub const reminder_capacity: usize = 1024;

const closing_line = "A turn ends only when no reachable item is left. Work these now. If one waits on the user, say which and why in your reply, then end the turn.";

pub const Reminder = struct {
    reminded_turn: u64 = 0,
    text: [reminder_capacity]u8 = undefined,

    pub fn owedFor(self: *const Reminder, turn_id: u64, items: []const todo_list.Item) bool {
        return self.reminded_turn != turn_id and openWorkCount(items) > 0;
    }

    pub fn forTurn(self: *Reminder, turn_id: u64, items: []const todo_list.Item) ?[]const u8 {
        if (self.reminded_turn == turn_id) return null;
        const written = render(&self.text, items) orelse return null;
        self.reminded_turn = turn_id;
        return written;
    }
};

pub fn openWorkCount(items: []const todo_list.Item) usize {
    var count: usize = 0;
    for (items) |item| {
        if (item.kind == .work and item.actionable()) count += 1;
    }
    return count;
}

pub fn render(buffer: []u8, items: []const todo_list.Item) ?[]const u8 {
    const open = openWorkCount(items);
    if (open == 0) return null;
    var writer = std.Io.Writer.fixed(buffer);
    writeReminder(&writer, items, open) catch {};
    return writer.buffered();
}

fn writeReminder(writer: *std.Io.Writer, items: []const todo_list.Item, open: usize) std.Io.Writer.Error!void {
    try writer.print("{d} todo item{s} still open and reachable:\n", .{ open, if (open == 1) " is" else "s are" });
    var named: usize = 0;
    for (items) |item| {
        if (item.kind != .work or !item.actionable()) continue;
        if (named == max_named_items) break;
        try writer.print("- {s} {s}\n", .{ item.id, text_utils.utf8PrefixByBytes(item.title, max_title_bytes) });
        named += 1;
    }
    if (open > named) try writer.print("- and {d} more\n", .{open - named});
    try writer.writeAll(closing_line);
}

test "open work items are named once per turn and done, blocked and question items are not" {
    const items = [_]todo_list.Item{
        .{ .id = "t1", .title = "write the parser", .status = .in_progress },
        .{ .id = "t2", .title = "ask which port", .status = .pending, .kind = .question },
        .{ .id = "t3", .title = "ship it", .status = .done },
        .{ .id = "t4", .title = "needs a key", .status = .blocked, .reason = "waits on the owner" },
        .{ .id = "t5", .title = "add the test", .status = .pending },
    };
    try std.testing.expectEqual(@as(usize, 2), openWorkCount(&items));

    var reminder: Reminder = .{};
    const first = reminder.forTurn(7, &items).?;
    try std.testing.expect(std.mem.startsWith(u8, first, "2 todo items are still open and reachable:\n- t1 write the parser\n- t5 add the test\n"));
    try std.testing.expect(std.mem.endsWith(u8, first, closing_line));
    try std.testing.expect(std.mem.find(u8, first, "t2") == null);
    try std.testing.expect(std.mem.find(u8, first, "t4") == null);
    try std.testing.expect(reminder.forTurn(7, &items) == null);
    try std.testing.expect(!reminder.owedFor(7, &items));
    try std.testing.expect(reminder.owedFor(8, &items));
    try std.testing.expect(!reminder.owedFor(8, &.{}));
    try std.testing.expect(reminder.forTurn(8, &items) != null);
}

test "no open work gives no reminder, and a long list names five and counts the rest" {
    const closed = [_]todo_list.Item{
        .{ .id = "t1", .title = "done already", .status = .done },
        .{ .id = "t2", .title = "a question", .status = .pending, .kind = .question },
    };
    var buffer: [reminder_capacity]u8 = undefined;
    try std.testing.expect(render(&buffer, &closed) == null);
    try std.testing.expect(render(&buffer, &.{}) == null);

    var many: [8]todo_list.Item = undefined;
    for (&many) |*item| item.* = .{ .id = "t", .title = "work", .status = .pending };
    const text = render(&buffer, &many).?;
    try std.testing.expect(std.mem.startsWith(u8, text, "8 todo items are still open and reachable:\n"));
    try std.testing.expect(std.mem.find(u8, text, "- and 3 more\n") != null);

    const single = [_]todo_list.Item{.{ .id = "t9", .title = "one", .status = .pending }};
    try std.testing.expect(std.mem.startsWith(u8, render(&buffer, &single).?, "1 todo item is still open and reachable:\n"));
}

test "a reminder that does not fit is cut at the buffer and still returned" {
    var small: [48]u8 = undefined;
    const items = [_]todo_list.Item{.{ .id = "t1", .title = "a title long enough to overflow the small buffer", .status = .pending }};
    const text = render(&small, &items).?;
    try std.testing.expect(text.len <= small.len);
    try std.testing.expect(std.mem.startsWith(u8, text, "1 todo item is still open"));
}
