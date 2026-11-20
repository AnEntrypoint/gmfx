const std = @import("std");
const todo_list = @import("../../core/todo/todo_list.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const io_mod = @import("../../core/shared/io.zig");

const Allocator = std.mem.Allocator;

pub const description =
    \\Maintain a structured TODO list for a multi-step task that spans several tool calls. Skip it for single-shot answers, trivial requests, and purely conversational replies.
    \\
    \\- Call with `todos: [...]` to replace the full list. Statuses: pending, in_progress, done.
    \\- Call with no `todos` argument to read the current list without changing it.
    \\- Call with `todos: []` to clear the list.
    \\- Keep exactly one item in_progress while work is underway. Mark an item done as soon as it is finished, not in a batch at the end.
    \\- Keep titles short and actionable.
    \\- Never mark an item done while tests fail, the implementation is partial, errors remain, or required files could not be found. A blocked item stays in_progress, or a pending item describes what must be resolved.
    \\- Do not re-send an unchanged list.
;

const invalid_todos_message = "TodoList todos must be an array of {title: non-empty string, status: pending | in_progress | done} objects";

pub const Input = struct {
    todos: ?[]todo_list.Item,

    fn deinit(self: Input, alloc: Allocator) void {
        if (self.todos) |items| freeItems(alloc, items);
    }
};

fn freeItems(alloc: Allocator, items: []const todo_list.Item) void {
    for (items) |item| alloc.free(item.title);
    alloc.free(items);
}

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const source = if (args_json.len == 0) "{}" else args_json;
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, source, .{}) catch {
        return .{ .failure = try ctx.allocator.dupe(u8, "TodoList arguments must be a JSON object") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "TodoList arguments must be a JSON object") };
    }
    const raw = parsed.value.object.get("todos") orelse {
        return .{ .input = try wrap(ctx.allocator, .{ .todos = null }) };
    };
    const items = parseItems(ctx.allocator, raw) catch |err| switch (err) {
        error.InvalidTodos => return .{ .failure = try ctx.allocator.dupe(u8, invalid_todos_message) },
        else => |other| return other,
    };
    errdefer freeItems(ctx.allocator, items);
    return .{ .input = try wrap(ctx.allocator, .{ .todos = items }) };
}

fn parseItems(alloc: Allocator, raw: std.json.Value) (Allocator.Error || error{InvalidTodos})![]todo_list.Item {
    if (raw != .array) return error.InvalidTodos;
    var items: std.ArrayList(todo_list.Item) = .empty;
    errdefer {
        for (items.items) |item| alloc.free(item.title);
        items.deinit(alloc);
    }
    for (raw.array.items) |entry| {
        if (entry != .object) return error.InvalidTodos;
        const title = entry.object.get("title") orelse return error.InvalidTodos;
        if (title != .string or title.string.len == 0) return error.InvalidTodos;
        const status_value = entry.object.get("status") orelse return error.InvalidTodos;
        if (status_value != .string) return error.InvalidTodos;
        const status = advertisedStatus(status_value.string) orelse return error.InvalidTodos;
        const owned_title = try alloc.dupe(u8, title.string);
        errdefer alloc.free(owned_title);
        try items.append(alloc, .{ .title = owned_title, .status = status });
    }
    return items.toOwnedSlice(alloc);
}

fn advertisedStatus(text: []const u8) ?todo_list.Status {
    const status = todo_list.Status.parse(text) orelse return null;
    return switch (status) {
        .pending, .in_progress, .done => status,
        .blocked => null,
    };
}

fn wrap(alloc: Allocator, input: Input) Allocator.Error!tool_dispatch.ToolInput {
    const slot = try alloc.create(Input);
    slot.* = input;
    return .{ .ptr = slot, .deinit_fn = inputDeinit };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const view = ctx.todo orelse return .{
        .failure = try ctx.allocator.dupe(u8, "TodoList is not available in this session."),
    };
    var scratch = std.heap.ArenaAllocator.init(ctx.scratch_allocator);
    defer scratch.deinit();
    const todos = input.todos orelse {
        const current = try view.state.current(scratch.allocator(), view.history);
        return .{ .success = try todo_list.renderList(ctx.allocator, current, &view.state.checks, .all) };
    };
    const replacement = try scratch.allocator().alloc(todo_list.Entry, todos.len);
    for (todos, replacement) |item, *entry| entry.* = .{ .title = item.title, .status = item.status };
    const notes = switch (try view.state.apply(ctx.allocator, .{ .replace = replacement }, .{
        .history = view.history,
        .workspace_root = ctx.workspace_root,
        .now_ms = io_mod.milliTimestamp(),
    })) {
        .rejected => |rejection| return .{ .failure = rejection },
        .applied => |applied_notes| applied_notes,
    };
    defer ctx.allocator.free(notes);
    const kept = view.state.items;
    if (kept.len == 0) return .{ .success = try ctx.allocator.dupe(u8, "Todo list cleared.") };
    const listing = try todo_list.renderList(ctx.allocator, kept, &view.state.checks, .all);
    defer ctx.allocator.free(listing);
    const hint = try todo_list.nextStepHint(ctx.allocator, kept);
    defer if (hint) |text| ctx.allocator.free(text);
    var body: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer body.deinit();
    body.writer.print("Todo list updated.\n{s}", .{listing}) catch return error.OutOfMemory;
    if (notes.len > 0) body.writer.print("\n\n{s}", .{notes}) catch return error.OutOfMemory;
    if (hint) |text| body.writer.print("\n\n{s}", .{text}) catch return error.OutOfMemory;
    return .{ .success = body.toOwnedSlice() catch return error.OutOfMemory };
}

pub fn readsOnly(input: tool_dispatch.ToolInput) bool {
    return input.as(Input).todos == null;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn decodeTodos(alloc: Allocator, args_json: []const u8) !tool_dispatch.ToolInput {
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .input => |input| return input,
        .failure => |failure| {
            defer alloc.free(failure);
            return error.TestUnexpectedResult;
        },
    }
}

test "TodoList without todos reads the current list and changes nothing" {
    const alloc = std.testing.allocator;
    const input = try decodeTodos(alloc, "{}");
    defer input.deinit(alloc);
    try std.testing.expect(input.as(Input).todos == null);
    try std.testing.expect(readsOnly(input));
}

test "TodoList with an empty todos array is a write that clears the list" {
    const alloc = std.testing.allocator;
    const input = try decodeTodos(alloc, "{\"todos\":[]}");
    defer input.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), input.as(Input).todos.?.len);
    try std.testing.expect(!readsOnly(input));
}

test "TodoList accepts the pending, in_progress and done statuses" {
    const alloc = std.testing.allocator;
    const input = try decodeTodos(
        alloc,
        "{\"todos\":[{\"title\":\"plan\",\"status\":\"done\"},{\"title\":\"edit\",\"status\":\"in_progress\"},{\"title\":\"test\",\"status\":\"pending\"}]}",
    );
    defer input.deinit(alloc);
    const items = input.as(Input).todos.?;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("plan", items[0].title);
    try std.testing.expectEqual(todo_list.Status.done, items[0].status);
    try std.testing.expectEqual(todo_list.Status.in_progress, items[1].status);
    try std.testing.expectEqual(todo_list.Status.pending, items[2].status);
}

test "TodoList rejects a blank title, an unknown status and a missing status" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "{\"todos\":[{\"title\":\"\",\"status\":\"pending\"}]}",
        "{\"todos\":[{\"title\":\"plan\",\"status\":\"blocked\"}]}",
        "{\"todos\":[{\"title\":\"plan\"}]}",
        "{\"todos\":\"plan\"}",
    };
    for (cases) |args_json| {
        const decoded = try decode(.{ .allocator = alloc }, args_json);
        switch (decoded) {
            .input => |input| {
                input.deinit(alloc);
                return error.TestUnexpectedResult;
            },
            .failure => |failure| {
                defer alloc.free(failure);
                try std.testing.expectEqualStrings(invalid_todos_message, failure);
            },
        }
    }
}

fn callTodos(alloc: Allocator, state: *todo_list.State, args_json: []const u8) !tool_dispatch.ToolResult {
    const ctx = tool_dispatch.DispatchContext{
        .allocator = alloc,
        .scratch_allocator = alloc,
        .todo = .{ .state = state, .history = &.{} },
    };
    const input = try decodeTodos(alloc, args_json);
    defer input.deinit(alloc);
    return call(ctx, input);
}

test "TodoList replaces the durable list, reads it back with ids and clears it" {
    const alloc = std.testing.allocator;
    var state: todo_list.State = .{};
    defer state.deinit();

    const written = try callTodos(alloc, &state, "{\"todos\":[{\"title\":\"plan\",\"status\":\"done\"},{\"title\":\"edit\",\"status\":\"in_progress\"}]}");
    defer written.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, written.success, "Todo list updated.\nCurrent todo list:\n  [done] t1 plan\n  [in_progress] t2 edit"));
    try std.testing.expectEqual(@as(usize, 2), state.items.len);

    const read = try callTodos(alloc, &state, "{}");
    defer read.deinit(alloc);
    try std.testing.expectEqualStrings("Current todo list:\n  [done] t1 plan\n  [in_progress] t2 edit", read.success);
    try std.testing.expectEqual(@as(u64, 1), state.revision);

    const replaced = try callTodos(alloc, &state, "{\"todos\":[{\"title\":\"ship\",\"status\":\"pending\"}]}");
    defer replaced.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, replaced.success, "  [pending] t3 ship") != null);
    try std.testing.expect(std.mem.find(u8, replaced.success, "Removed t2 \"edit\".") != null);

    const cleared = try callTodos(alloc, &state, "{\"todos\":[]}");
    defer cleared.deinit(alloc);
    try std.testing.expectEqualStrings("Todo list cleared.", cleared.success);
    try std.testing.expectEqual(@as(usize, 0), state.items.len);
}

test "TodoList answers that it is unavailable when the session holds no todo state" {
    const alloc = std.testing.allocator;
    const input = try decodeTodos(alloc, "{\"todos\":[]}");
    defer input.deinit(alloc);
    const result = try call(.{ .allocator = alloc }, input);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("TodoList is not available in this session.", result.failure);
}
