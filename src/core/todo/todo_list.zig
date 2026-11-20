const std = @import("std");
const types = @import("../shared/types.zig");
const json_decode = @import("../shared/json_decode.zig");
const ledger = @import("../validation/ledger.zig");
const git_head = @import("git_head.zig");

const Allocator = std.mem.Allocator;

pub const tool_name = "TodoList";
pub const max_items: usize = 100;
pub const max_title_bytes: usize = 400;
pub const max_reason_bytes: usize = 1000;
pub const max_evidence_bytes: usize = 200;
const saved_version: u32 = 1;
const shown_head_len: usize = 12;

pub const Status = enum {
    pending,
    in_progress,
    blocked,
    done,

    pub fn parse(text: []const u8) ?Status {
        return std.meta.stringToEnum(Status, text);
    }

    pub fn actionable(self: Status) bool {
        return self == .pending or self == .in_progress;
    }

    fn marker(self: Status) []const u8 {
        return switch (self) {
            .pending => "[pending]",
            .in_progress => "[in_progress]",
            .blocked => "[blocked]",
            .done => "[done]",
        };
    }
};

pub const Kind = enum {
    work,
    question,

    pub fn parse(text: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, text);
    }
};

pub const Show = enum {
    all,
    open,
    blocked,
    done,

    pub fn parse(text: []const u8) ?Show {
        return std.meta.stringToEnum(Show, text);
    }

    fn includes(self: Show, status: Status) bool {
        return switch (self) {
            .all => true,
            .open => status.actionable(),
            .blocked => status == .blocked,
            .done => status == .done,
        };
    }
};

pub const Item = struct {
    id: []const u8 = "",
    title: []const u8,
    status: Status,
    kind: Kind = .work,
    reason: ?[]const u8 = null,
    evidence: ?[]const u8 = null,
    head: ?[]const u8 = null,
    check: ?[]const u8 = null,
    files: []const []const u8 = &.{},

    pub fn actionable(self: Item) bool {
        return self.status.actionable();
    }
};

pub const Entry = struct {
    id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    status: ?Status = null,
    kind: ?Kind = null,
    reason: ?[]const u8 = null,
    evidence: ?[]const u8 = null,
    check: ?[]const u8 = null,
    files: ?[]const []const u8 = null,
};

pub const Request = struct {
    replace: ?[]const Entry = null,
    update: []const Entry = &.{},
    remove: []const []const u8 = &.{},

    pub fn mutates(self: Request) bool {
        return self.replace != null or self.update.len > 0 or self.remove.len > 0;
    }
};

pub const Env = struct {
    history: []const types.HistoryTurn = &.{},
    workspace_root: []const u8 = "",
    now_ms: i64 = 0,
};

pub const ApplyResult = union(enum) {
    applied: []u8,
    rejected: []u8,

    pub fn deinit(self: ApplyResult, alloc: Allocator) void {
        switch (self) {
            .applied, .rejected => |text| alloc.free(text),
        }
    }
};

pub fn actionableCount(items: []const Item) usize {
    var count: usize = 0;
    for (items) |item| count += @intFromBool(item.actionable());
    return count;
}

pub fn renderList(alloc: Allocator, items: []const Item, checks: ?*const ledger.Ledger, show: Show) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    writeList(&out.writer, items, checks, show) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

pub const compaction_section_max_bytes: usize = 4096;

pub fn compactionSection(alloc: Allocator, items: []const Item) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    writeCompactionSection(&out.writer, items) catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeCompactionSection(writer: *std.Io.Writer, items: []const Item) std.Io.Writer.Error!void {
    var unfinished: usize = 0;
    for (items) |item| unfinished += @intFromBool(item.status != .done);
    var written: usize = 0;
    var listed: usize = 0;
    for (items) |item| {
        if (item.status == .done) continue;
        const line_bytes = item.status.marker().len + item.id.len + item.title.len + "-   \n".len;
        if (written + line_bytes > compaction_section_max_bytes) break;
        try writer.print("- {s} {s} {s}\n", .{ item.status.marker(), item.id, item.title });
        written += line_bytes;
        listed += 1;
    }
    if (unfinished > listed) try writer.print("- and {d} more; call TodoList to see them\n", .{unfinished - listed});
}

fn writeList(writer: *std.Io.Writer, items: []const Item, checks: ?*const ledger.Ledger, show: Show) std.Io.Writer.Error!void {
    var shown: usize = 0;
    for (items) |item| shown += @intFromBool(show.includes(item.status));
    if (items.len == 0) return writer.writeAll("Todo list is empty.");
    if (shown == 0) return writer.print("No todo is {s}; the list has {d}.", .{ @tagName(show), items.len });
    try writer.writeAll(if (show == .all) "Current todo list:" else "Todos shown by status:");
    for (items) |item| {
        if (!show.includes(item.status)) continue;
        try writer.writeAll("\n  ");
        try writer.writeAll(item.status.marker());
        try writer.writeByte(' ');
        if (item.id.len > 0) {
            try writer.writeAll(item.id);
            try writer.writeByte(' ');
        }
        if (item.kind == .question) try writer.writeAll("question: ");
        try writer.writeAll(item.title);
        if (item.reason) |reason| {
            try writer.print(" ({s}: {s})", .{ if (item.status == .blocked) "blocked" else "note", reason });
        }
        if (item.evidence) |evidence| {
            try writer.print(" (evidence {s}", .{evidence});
            if (item.head) |head| try writer.print(" at {s}", .{head[0..@min(head.len, shown_head_len)]});
            try writer.writeByte(')');
        }
        if (item.check) |check| {
            try writer.print("; check `{s}`", .{check});
            const row = if (checks) |known| known.find(item.id) else null;
            if (row) |found| {
                if (found.exit_code == null) try writer.writeAll(" (not run)") else try ledger.writeResult(writer, found);
            }
        }
    }
}

pub fn nextStepHint(alloc: Allocator, items: []const Item) Allocator.Error!?[]u8 {
    var open: usize = 0;
    var in_progress: usize = 0;
    var current: []const u8 = "";
    for (items) |item| {
        if (!item.actionable()) continue;
        open += 1;
        if (item.status != .in_progress) continue;
        in_progress += 1;
        current = item.title;
    }
    if (open == 0) return null;
    if (in_progress == 0) {
        return try alloc.dupe(u8, "No item is in_progress. Mark the one you are working on as in_progress.");
    }
    if (in_progress > 1) {
        return try alloc.dupe(u8, "Several items are in_progress. Keep only the one you are working on now in_progress.");
    }
    if (open == 1) {
        return try std.fmt.allocPrint(alloc, "\"{s}\" is the last open item. Once it is finished, mark it done before you write your final message; if it cannot be finished, leave it in_progress and say what blocks it.", .{current});
    }
    return try std.fmt.allocPrint(alloc, "When \"{s}\" is finished, mark it done and set the next item in_progress; that update can go in the same response as your next tool call.", .{current});
}

pub const View = struct {
    state: *State,
    history: []const types.HistoryTurn,
};

const Saved = struct {
    v: u32 = saved_version,
    next_id: u32 = 1,
    items: []const Item = &.{},
    checks: []const ledger.Row = &.{},
};

pub const State = struct {
    arena: ?std.heap.ArenaAllocator = null,
    items: []const Item = &.{},
    seeded: bool = false,
    next_id: u32 = 1,
    revision: u64 = 0,
    checks: ledger.Ledger = .{},
    turn_messages: ?*const std.ArrayList(types.ChatMessage) = null,

    pub fn deinit(self: *State) void {
        if (self.arena) |*arena| arena.deinit();
        self.checks.deinit();
        self.* = .{};
    }

    pub fn reset(self: *State) void {
        const revision = self.revision;
        self.deinit();
        self.revision = revision;
    }

    pub fn view(self: *State, history: []const types.HistoryTurn) Allocator.Error![]const Item {
        try self.seed(history);
        return self.items;
    }

    pub fn current(self: *const State, scratch: Allocator, history: []const types.HistoryTurn) Allocator.Error![]const Item {
        if (self.seeded) return self.items;
        const derived = try deriveFromHistory(scratch, history);
        var next_id = self.next_id;
        for (derived) |*item| item.id = try freshId(scratch, &next_id);
        return derived;
    }

    pub fn write(self: *State, items: []const Item) Allocator.Error!void {
        var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        const numbered = try scratch.dupe(Item, items);
        var next_id = self.next_id;
        for (numbered) |*item| {
            if (item.id.len == 0) item.id = try freshId(scratch, &next_id);
        }
        try self.install(numbered, next_id, 0);
        self.seeded = true;
        self.revision += 1;
    }

    pub fn apply(self: *State, alloc: Allocator, request: Request, env: Env) Allocator.Error!ApplyResult {
        var scratch_state = std.heap.ArenaAllocator.init(alloc);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        try self.seed(env.history);

        var notes: std.ArrayList(u8) = .empty;
        var work: std.ArrayList(Item) = .empty;
        var next_id = self.next_id;

        if (request.replace) |drafts| {
            const claimed = try scratch.alloc(bool, self.items.len);
            @memset(claimed, false);
            for (drafts) |draft| {
                const base_index = if (draft.id) |id|
                    indexOfId(self.items, id) orelse return reject(alloc, "TodoList: no todo has id \"{s}\"; fx assigns ids and shows them in the list, so leave id out for a new item", .{id})
                else
                    unclaimedTitle(self.items, claimed, draft.title orelse "");
                if (base_index) |index| {
                    if (claimed[index]) return reject(alloc, "TodoList: todo {s} appears twice in todos", .{self.items[index].id});
                    claimed[index] = true;
                }
                var item: Item = if (base_index) |index|
                    self.items[index]
                else
                    .{ .id = try freshId(scratch, &next_id), .title = "", .status = .pending };
                if (try self.merge(scratch, alloc, &item, draft, env)) |rejection| return .{ .rejected = rejection };
                try work.append(scratch, item);
            }
            for (self.items, claimed) |item, was_claimed| {
                if (was_claimed) continue;
                if (item.kind == .question and item.status != .done) {
                    try work.append(scratch, item);
                    try notes.print(scratch, "Kept open question {s} \"{s}\": answer it by marking it done with the answer as its reason, or mark it blocked with a reason.\n", .{ item.id, item.title });
                } else if (item.status != .done) {
                    try notes.print(scratch, "Removed {s} \"{s}\".\n", .{ item.id, item.title });
                }
            }
        } else {
            try work.appendSlice(scratch, self.items);
        }

        for (request.update) |patch| {
            const id = patch.id orelse return reject(alloc, "TodoList: every update entry needs the id of the todo it changes", .{});
            const index = indexOfId(work.items, id) orelse return reject(alloc, "TodoList: no todo has id \"{s}\"", .{id});
            if (try self.merge(scratch, alloc, &work.items[index], patch, env)) |rejection| return .{ .rejected = rejection };
        }

        for (request.remove) |id| {
            const index = indexOfId(work.items, id) orelse return reject(alloc, "TodoList: no todo has id \"{s}\"", .{id});
            const item = work.items[index];
            if (item.kind == .question and item.status != .done) {
                return reject(alloc, "TodoList: {s} is an open question and cannot be removed; answer it by marking it done with the answer as its reason, or mark it blocked with a reason", .{id});
            }
            _ = work.orderedRemove(index);
            try notes.print(scratch, "Removed {s} \"{s}\".\n", .{ item.id, item.title });
        }

        if (work.items.len > max_items) return reject(alloc, "TodoList: a list holds at most {d} todos", .{max_items});
        var with_check: usize = 0;
        for (work.items) |item| with_check += @intFromBool(item.check != null);
        if (with_check > ledger.max_rows) return reject(alloc, "TodoList: {s}", .{ledger.putErrorMessage(error.TooManyChecks)});

        try self.install(work.items, next_id, env.now_ms);
        self.seeded = true;
        self.revision += 1;
        return .{ .applied = try alloc.dupe(u8, std.mem.trimEnd(u8, notes.items, "\n")) };
    }

    pub fn recordCommand(self: *State, command: []const u8, exit_code: i64, wall_ms: u64, now_ms: i64) Allocator.Error!usize {
        const matched = try self.checks.observe(command, exit_code, wall_ms, now_ms);
        if (matched > 0) self.revision += 1;
        return matched;
    }

    pub fn recordFileChange(self: *State, path: []const u8) Allocator.Error!usize {
        const stale = try self.checks.invalidateFile(path);
        if (stale > 0) self.revision += 1;
        return stale;
    }

    pub fn encodeJson(self: *const State, alloc: Allocator) Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        const saved: Saved = .{ .next_id = self.next_id, .items = self.items, .checks = self.checks.rows };
        std.json.Stringify.value(saved, .{ .emit_null_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
        return out.toOwnedSlice() catch return error.OutOfMemory;
    }

    pub fn restoreJson(self: *State, json: ?[]const u8) void {
        self.reset();
        const text = json orelse return;
        var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        const saved = json_decode.parseFromSliceLeaky(Saved, scratch, text, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return;
        var kept: std.ArrayList(Item) = .empty;
        var next_id = @max(saved.next_id, 1);
        for (saved.items) |item| {
            if (item.title.len == 0 or kept.items.len >= max_items) continue;
            kept.append(scratch, item) catch return;
            next_id = @max(next_id, numberOfId(item.id) +| 1);
        }
        for (kept.items) |*item| {
            if (item.id.len == 0) item.id = freshId(scratch, &next_id) catch return;
        }
        self.checks.restore(saved.checks) catch return;
        self.install(kept.items, next_id, 0) catch {
            self.reset();
            return;
        };
        self.seeded = true;
    }

    fn seed(self: *State, history: []const types.HistoryTurn) Allocator.Error!void {
        if (self.seeded) return;
        var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();
        const derived = try deriveFromHistory(scratch, history);
        var next_id = self.next_id;
        for (derived) |*item| item.id = try freshId(scratch, &next_id);
        try self.install(derived, next_id, 0);
        self.seeded = true;
    }

    fn install(self: *State, items: []const Item, next_id: u32, now_ms: i64) Allocator.Error!void {
        var next = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer next.deinit();
        const arena = next.allocator();
        const owned = try arena.alloc(Item, items.len);
        for (items, owned) |source, *target| target.* = try dupeItem(arena, source);
        if (self.arena) |*old| old.deinit();
        self.arena = next;
        self.items = owned;
        self.next_id = next_id;
        try self.syncChecks(now_ms);
    }

    fn syncChecks(self: *State, now_ms: i64) Allocator.Error!void {
        for (self.items) |item| {
            const command = item.check orelse continue;
            self.checks.put(item.id, command, item.files, now_ms) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.TooManyChecks, error.CheckCommandEmpty, error.CheckCommandTooLong, error.TooManyCheckFiles => {},
            };
        }
        var index: usize = 0;
        while (index < self.checks.rows.len) {
            const row = self.checks.rows[index];
            const owner = indexOfId(self.items, row.id);
            if (owner != null and self.items[owner.?].check != null) {
                index += 1;
                continue;
            }
            var id_buffer: [64]u8 = undefined;
            const id = id_buffer[0..@min(row.id.len, id_buffer.len)];
            @memcpy(id, row.id[0..id.len]);
            if (!try self.checks.remove(id)) index += 1;
        }
    }

    fn merge(self: *const State, scratch: Allocator, alloc: Allocator, item: *Item, entry: Entry, env: Env) Allocator.Error!?[]u8 {
        if (entry.title) |title| {
            if (title.len == 0 or title.len > max_title_bytes) return try problem(alloc, "TodoList: a title is 1 to {d} bytes", .{max_title_bytes});
            item.title = title;
        }
        if (item.title.len == 0) return try problem(alloc, "TodoList: a new todo needs a title", .{});
        if (entry.kind) |kind| item.kind = kind;
        const before = item.status;
        if (entry.status) |status| item.status = status;
        if (entry.reason) |reason| {
            if (reason.len > max_reason_bytes) return try problem(alloc, "TodoList: a reason is at most {d} bytes", .{max_reason_bytes});
            item.reason = if (std.mem.trim(u8, reason, " \t\r\n").len == 0) null else reason;
        } else if (before == .blocked and item.status != .blocked) {
            item.reason = null;
        }
        if (item.status == .blocked and item.reason == null) {
            return try problem(alloc, "TodoList: \"{s}\" is blocked without a reason; pass a non-empty reason that says what it waits for", .{item.title});
        }
        if (entry.evidence) |evidence| {
            if (evidence.len == 0 or evidence.len > max_evidence_bytes or !evidenceKnown(evidence, env.history, self.turn_messages)) {
                return try problem(alloc, "TodoList: evidence \"{s}\" is not the id of a tool call fx holds for this session; pass the id of the tool call whose result shows \"{s}\"", .{ evidence[0..@min(evidence.len, max_evidence_bytes)], item.title });
            }
            const changed = if (item.evidence) |known| !std.mem.eql(u8, known, evidence) else true;
            if (changed) {
                item.evidence = evidence;
                item.head = try git_head.read(scratch, env.workspace_root);
            }
        }
        if (entry.check) |check| {
            if (check.len > ledger.max_command_bytes) return try problem(alloc, "TodoList: {s}", .{ledger.putErrorMessage(error.CheckCommandTooLong)});
            item.check = if (std.mem.trim(u8, check, " \t\r\n").len == 0) null else check;
        }
        if (entry.files) |files| {
            if (files.len > ledger.max_files) return try problem(alloc, "TodoList: {s}", .{ledger.putErrorMessage(error.TooManyCheckFiles)});
            item.files = files;
        }
        return null;
    }
};

fn reject(alloc: Allocator, comptime format: []const u8, args: anytype) Allocator.Error!ApplyResult {
    return .{ .rejected = try std.fmt.allocPrint(alloc, format, args) };
}

fn problem(alloc: Allocator, comptime format: []const u8, args: anytype) Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, format, args);
}

fn freshId(arena: Allocator, next_id: *u32) Allocator.Error![]const u8 {
    const id = try std.fmt.allocPrint(arena, "t{d}", .{next_id.*});
    next_id.* +|= 1;
    return id;
}

fn numberOfId(id: []const u8) u32 {
    if (id.len < 2 or id[0] != 't') return 0;
    return std.fmt.parseUnsigned(u32, id[1..], 10) catch 0;
}

fn indexOfId(items: []const Item, id: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.id, id)) return index;
    }
    return null;
}

fn unclaimedTitle(items: []const Item, claimed: []const bool, title: []const u8) ?usize {
    for (items, claimed, 0..) |item, was_claimed, index| {
        if (!was_claimed and std.mem.eql(u8, item.title, title)) return index;
    }
    return null;
}

fn dupeOptional(arena: Allocator, text: ?[]const u8) Allocator.Error!?[]const u8 {
    return if (text) |value| try arena.dupe(u8, value) else null;
}

fn dupeItem(arena: Allocator, source: Item) Allocator.Error!Item {
    const files = try arena.alloc([]const u8, source.files.len);
    for (source.files, files) |file, *target| target.* = try arena.dupe(u8, file);
    return .{
        .id = try arena.dupe(u8, source.id),
        .title = try arena.dupe(u8, source.title),
        .status = source.status,
        .kind = source.kind,
        .reason = try dupeOptional(arena, source.reason),
        .evidence = try dupeOptional(arena, source.evidence),
        .head = try dupeOptional(arena, source.head),
        .check = try dupeOptional(arena, source.check),
        .files = files,
    };
}

pub fn evidenceKnown(
    ref: []const u8,
    history: []const types.HistoryTurn,
    turn_messages: ?*const std.ArrayList(types.ChatMessage),
) bool {
    if (turn_messages) |messages| {
        for (messages.items) |message| {
            if (message.role != .tool) continue;
            const id = message.tool_call_id orelse continue;
            if (std.mem.eql(u8, id, ref)) return true;
        }
    }
    for (history) |turn| {
        const execution = switch (turn) {
            .compacted_summary => continue,
            .assistant => |entry| entry.execution,
            .interrupted => |entry| entry.execution,
        };
        for (execution.tool_steps) |step| {
            for (step.tool_results) |result| {
                if (std.mem.eql(u8, result.tool_call_id, ref)) return true;
            }
        }
    }
    return false;
}

pub fn deriveFromHistory(alloc: Allocator, history: []const types.HistoryTurn) Allocator.Error![]Item {
    var latest: ?[]Item = null;
    for (history) |turn| {
        switch (turn) {
            .compacted_summary => {},
            .assistant => |entry| latest = try lastWriteInExecution(alloc, entry.execution, latest),
            .interrupted => |entry| {
                latest = try lastWriteInExecution(alloc, entry.execution, latest);
                if (entry.tool_call) |call| {
                    if (try writtenItems(alloc, call)) |items| latest = items;
                }
            },
        }
    }
    return latest orelse try alloc.alloc(Item, 0);
}

fn lastWriteInExecution(alloc: Allocator, execution: types.ExecutionMemory, prior: ?[]Item) Allocator.Error!?[]Item {
    var latest = prior;
    for (execution.tool_steps) |step| {
        for (step.tool_calls) |call| {
            if (try writtenItems(alloc, call)) |items| latest = items;
        }
    }
    return latest;
}

fn writtenItems(alloc: Allocator, call: types.ToolCall) Allocator.Error!?[]Item {
    if (!std.mem.eql(u8, call.name, tool_name)) return null;
    const source = if (call.arguments_json.len == 0) "{}" else call.arguments_json;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, source, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const todos = parsed.value.object.get("todos") orelse return null;
    if (todos != .array) return null;
    var items: std.ArrayList(Item) = .empty;
    errdefer items.deinit(alloc);
    for (todos.array.items) |entry| {
        if (entry != .object) return null;
        const title = entry.object.get("title") orelse return null;
        const status = entry.object.get("status") orelse return null;
        if (title != .string or status != .string) return null;
        const parsed_status = Status.parse(status.string) orelse return null;
        const reason = entry.object.get("reason");
        try items.append(alloc, .{
            .title = try alloc.dupe(u8, title.string),
            .status = parsed_status,
            .reason = if (reason != null and reason.? == .string and reason.?.string.len > 0) try alloc.dupe(u8, reason.?.string) else null,
        });
    }
    return try items.toOwnedSlice(alloc);
}

fn expectApplied(result: ApplyResult) ![]u8 {
    return switch (result) {
        .applied => |notes| notes,
        .rejected => |text| {
            std.debug.print("unexpected rejection: {s}\n", .{text});
            std.testing.allocator.free(text);
            return error.TestUnexpectedResult;
        },
    };
}

fn expectRejected(result: ApplyResult, needle: []const u8) !void {
    switch (result) {
        .applied => |notes| {
            std.testing.allocator.free(notes);
            return error.TestUnexpectedResult;
        },
        .rejected => |text| {
            defer std.testing.allocator.free(text);
            try std.testing.expect(std.mem.find(u8, text, needle) != null);
        },
    }
}

fn applyOk(state: *State, request: Request, env: Env) !void {
    const notes = try expectApplied(try state.apply(std.testing.allocator, request, env));
    std.testing.allocator.free(notes);
}

test "the compaction section lists every todo that is not done and nothing when all are done" {
    const alloc = std.testing.allocator;
    const items = [_]Item{
        .{ .id = "t1", .title = "write the parser", .status = .in_progress },
        .{ .id = "t2", .title = "ship it", .status = .done },
        .{ .id = "t3", .title = "needs a key", .status = .blocked, .reason = "waits on the owner" },
        .{ .id = "t4", .title = "add the test", .status = .pending },
    };
    const section = try compactionSection(alloc, &items);
    defer alloc.free(section);
    try std.testing.expectEqualStrings("- [in_progress] t1 write the parser\n- [blocked] t3 needs a key\n- [pending] t4 add the test\n", section);

    const finished = [_]Item{.{ .id = "t1", .title = "ship it", .status = .done }};
    const empty = try compactionSection(alloc, &finished);
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("", empty);

    var long_title: [max_title_bytes]u8 = undefined;
    @memset(&long_title, 'x');
    var many: [max_items]Item = undefined;
    for (&many) |*item| item.* = .{ .id = "t9", .title = &long_title, .status = .pending };
    const capped = try compactionSection(alloc, &many);
    defer alloc.free(capped);
    try std.testing.expect(capped.len <= compaction_section_max_bytes + 64);
    try std.testing.expect(std.mem.endsWith(u8, capped, " more; call TodoList to see them\n"));
}

test "a plain title and status list replaces the list and every item gets a stable id" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit();
    try applyOk(&state, .{ .replace = &.{
        .{ .title = "plan", .status = .done },
        .{ .title = "edit", .status = .in_progress },
        .{ .title = "test", .status = .pending },
    } }, .{});
    try std.testing.expectEqual(@as(usize, 3), state.items.len);
    try std.testing.expectEqualStrings("t1", state.items[0].id);
    try std.testing.expectEqualStrings("t3", state.items[2].id);

    try applyOk(&state, .{ .replace = &.{
        .{ .title = "edit", .status = .done },
        .{ .title = "test", .status = .in_progress },
        .{ .title = "ship", .status = .pending },
    } }, .{});
    try std.testing.expectEqualStrings("t2", state.items[0].id);
    try std.testing.expectEqualStrings("t3", state.items[1].id);
    try std.testing.expectEqualStrings("t4", state.items[2].id);
    try std.testing.expectEqual(@as(u64, 2), state.revision);

    const listing = try renderList(alloc, state.items, &state.checks, .all);
    defer alloc.free(listing);
    try std.testing.expectEqualStrings("Current todo list:\n  [done] t2 edit\n  [in_progress] t3 test\n  [pending] t4 ship", listing);
}

test "a replacement names the open items it drops and keeps an open question" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit();
    try applyOk(&state, .{ .replace = &.{
        .{ .title = "edit", .status = .in_progress },
        .{ .title = "old work", .status = .done },
        .{ .title = "Which port?", .status = .pending, .kind = .question },
    } }, .{});
    const notes = try expectApplied(try state.apply(alloc, .{ .replace = &.{} }, .{}));
    defer alloc.free(notes);
    try std.testing.expectEqualStrings(
        "Removed t1 \"edit\".\n" ++
            "Kept open question t3 \"Which port?\": answer it by marking it done with the answer as its reason, or mark it blocked with a reason.",
        notes,
    );
    try std.testing.expectEqual(@as(usize, 1), state.items.len);
    try std.testing.expectEqualStrings("t3", state.items[0].id);
}

test "an update changes only the named todo and an unknown id is refused" {
    var state: State = .{};
    defer state.deinit();
    try applyOk(&state, .{ .replace = &.{
        .{ .title = "edit", .status = .in_progress },
        .{ .title = "test", .status = .pending },
    } }, .{});
    try applyOk(&state, .{ .update = &.{.{ .id = "t2", .status = .in_progress, .title = "test again" }} }, .{});
    try std.testing.expectEqualStrings("edit", state.items[0].title);
    try std.testing.expectEqual(Status.in_progress, state.items[1].status);
    try std.testing.expectEqualStrings("test again", state.items[1].title);
    try expectRejected(try state.apply(std.testing.allocator, .{ .update = &.{.{ .id = "t9", .status = .done }} }, .{}), "no todo has id \"t9\"");
    try expectRejected(try state.apply(std.testing.allocator, .{ .replace = &.{.{ .id = "t9", .title = "x", .status = .done }} }, .{}), "fx assigns ids");
    try std.testing.expectEqual(@as(u64, 2), state.revision);
}

test "a blocked todo needs a reason and loses it when work resumes" {
    var state: State = .{};
    defer state.deinit();
    try applyOk(&state, .{ .replace = &.{.{ .title = "deploy", .status = .in_progress }} }, .{});
    try expectRejected(try state.apply(std.testing.allocator, .{ .update = &.{.{ .id = "t1", .status = .blocked }} }, .{}), "blocked without a reason");
    try expectRejected(try state.apply(std.testing.allocator, .{ .update = &.{.{ .id = "t1", .status = .blocked, .reason = "  " }} }, .{}), "blocked without a reason");
    try applyOk(&state, .{ .update = &.{.{ .id = "t1", .status = .blocked, .reason = "waiting for credentials" }} }, .{});
    try std.testing.expectEqualStrings("waiting for credentials", state.items[0].reason.?);
    try std.testing.expectEqual(@as(usize, 0), actionableCount(state.items));
    try applyOk(&state, .{ .update = &.{.{ .id = "t1", .status = .in_progress }} }, .{});
    try std.testing.expect(state.items[0].reason == null);
    try std.testing.expectEqual(@as(usize, 1), actionableCount(state.items));
}

test "removal is explicit, by id, and an open question is answered instead of removed" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit();
    try applyOk(&state, .{ .replace = &.{
        .{ .title = "edit", .status = .pending },
        .{ .title = "Which port?", .status = .pending, .kind = .question },
    } }, .{});
    const notes = try expectApplied(try state.apply(alloc, .{ .remove = &.{"t1"} }, .{}));
    defer alloc.free(notes);
    try std.testing.expectEqualStrings("Removed t1 \"edit\".", notes);
    try expectRejected(try state.apply(alloc, .{ .remove = &.{"t2"} }, .{}), "open question");
    try expectRejected(try state.apply(alloc, .{ .remove = &.{"t1"} }, .{}), "no todo has id");
    try applyOk(&state, .{ .update = &.{.{ .id = "t2", .status = .done, .reason = "port 8080" }} }, .{});
    try applyOk(&state, .{ .remove = &.{"t2"} }, .{});
    try std.testing.expectEqual(@as(usize, 0), state.items.len);
}

fn toolResult(id: []const u8) types.ChatMessage {
    return .{ .role = .tool, .content = "ok", .tool_call_id = id, .tool_name = "Bash" };
}

test "evidence must name a tool call of this session and is kept with the git HEAD read then" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_mod = @import("../shared/io.zig");
    try tmp.dir.createDirPath(io_mod.getIo(), ".git");
    var head = try tmp.dir.createFile(io_mod.getIo(), ".git/HEAD", .{ .truncate = true });
    try head.writeStreamingAll(io_mod.getIo(), "0123456789abcdef0123456789abcdef01234567\n");
    head.close(io_mod.getIo());
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "");
    defer alloc.free(root);

    var turn_messages: std.ArrayList(types.ChatMessage) = .empty;
    defer turn_messages.deinit(alloc);
    try turn_messages.append(alloc, toolResult("call-test-run"));

    var state: State = .{};
    defer state.deinit();
    state.turn_messages = &turn_messages;
    const env: Env = .{ .workspace_root = root };
    try applyOk(&state, .{ .replace = &.{.{ .title = "run tests", .status = .in_progress }} }, env);
    try expectRejected(try state.apply(alloc, .{ .update = &.{.{ .id = "t1", .status = .done, .evidence = "call-missing" }} }, env), "is not the id of a tool call");
    try std.testing.expectEqual(Status.in_progress, state.items[0].status);
    try applyOk(&state, .{ .update = &.{.{ .id = "t1", .status = .done, .evidence = "call-test-run" }} }, env);
    try std.testing.expectEqualStrings("call-test-run", state.items[0].evidence.?);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", state.items[0].head.?);

    const listing = try renderList(alloc, state.items, &state.checks, .all);
    defer alloc.free(listing);
    try std.testing.expectEqualStrings("Current todo list:\n  [done] t1 run tests (evidence call-test-run at 0123456789ab)", listing);
}

test "evidence from an earlier turn of the session is accepted and a compacted turn is not" {
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("call-earlier"),
        .tool_name = @constCast("Bash"),
        .status = .success,
        .output = @constCast("ok"),
        .output_bytes = 2,
        .stored_output_bytes = 2,
    }};
    var steps = [_]types.ToolExecutionStep{.{ .tool_results = &results }};
    const history = [_]types.HistoryTurn{
        .{ .compacted_summary = .{ .summary = @constCast("summary"), .removed_turn_count = 1, .compaction_count = 1 } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("question") },
            .assistant = @constCast("answer"),
            .execution = .{ .tool_steps = &steps },
        } },
    };
    try std.testing.expect(evidenceKnown("call-earlier", &history, null));
    try std.testing.expect(!evidenceKnown("call-compacted", &history, null));
}

test "a todo's check becomes a ledger row that follows the todo" {
    const alloc = std.testing.allocator;
    var state: State = .{};
    defer state.deinit();
    try applyOk(&state, .{ .replace = &.{
        .{ .title = "unit tests", .status = .pending, .check = "make unit", .files = &.{"src/a.zig"} },
        .{ .title = "docs", .status = .pending },
    } }, .{ .now_ms = 40 });
    try std.testing.expectEqual(@as(usize, 1), state.checks.rows.len);
    try std.testing.expectEqual(@as(i64, 40), state.checks.find("t1").?.added_at_ms);
    try std.testing.expectEqual(@as(usize, 1), try state.recordCommand("make unit", 0, 1500, 50));
    try std.testing.expectEqual(@as(u64, 2), state.revision);

    const listing = try renderList(alloc, state.items, &state.checks, .all);
    defer alloc.free(listing);
    try std.testing.expectEqualStrings("Current todo list:\n  [pending] t1 unit tests; check `make unit` (passed, 1.5 s)\n  [pending] t2 docs", listing);

    try std.testing.expectEqual(@as(usize, 1), try state.recordFileChange("/work/src/a.zig"));
    try std.testing.expectEqual(ledger.Outcome.pending, state.checks.find("t1").?.outcome());
    try applyOk(&state, .{ .update = &.{.{ .id = "t1", .check = "" }} }, .{});
    try std.testing.expectEqual(@as(usize, 0), state.checks.rows.len);
    try applyOk(&state, .{ .update = &.{.{ .id = "t2", .check = "make docs" }} }, .{});
    try applyOk(&state, .{ .remove = &.{"t2"} }, .{});
    try std.testing.expectEqual(@as(usize, 0), state.checks.rows.len);
}

test "the saved list restores ids, reasons, evidence and check results" {
    const alloc = std.testing.allocator;
    var turn_messages: std.ArrayList(types.ChatMessage) = .empty;
    defer turn_messages.deinit(alloc);
    try turn_messages.append(alloc, toolResult("call-1"));
    var state: State = .{};
    defer state.deinit();
    state.turn_messages = &turn_messages;
    try applyOk(&state, .{ .replace = &.{
        .{ .title = "edit", .status = .done, .evidence = "call-1" },
        .{ .title = "deploy", .status = .blocked, .reason = "no credentials" },
        .{ .title = "Which port?", .status = .pending, .kind = .question },
        .{ .title = "suite", .status = .pending, .check = "make test" },
    } }, .{ .now_ms = 7 });
    _ = try state.recordCommand("make test", 2, 900, 9);
    const saved = try state.encodeJson(alloc);
    defer alloc.free(saved);
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"next_id\":5,\"items\":[" ++
            "{\"id\":\"t1\",\"title\":\"edit\",\"status\":\"done\",\"kind\":\"work\",\"evidence\":\"call-1\",\"files\":[]}," ++
            "{\"id\":\"t2\",\"title\":\"deploy\",\"status\":\"blocked\",\"kind\":\"work\",\"reason\":\"no credentials\",\"files\":[]}," ++
            "{\"id\":\"t3\",\"title\":\"Which port?\",\"status\":\"pending\",\"kind\":\"question\",\"files\":[]}," ++
            "{\"id\":\"t4\",\"title\":\"suite\",\"status\":\"pending\",\"kind\":\"work\",\"check\":\"make test\",\"files\":[]}]," ++
            "\"checks\":[{\"id\":\"t4\",\"command\":\"make test\",\"files\":[],\"added_at_ms\":7,\"runs\":1,\"exit_code\":2,\"wall_ms\":900,\"ran_at_ms\":9}]}",
        saved,
    );

    var resumed: State = .{};
    defer resumed.deinit();
    resumed.restoreJson(saved);
    try std.testing.expect(resumed.seeded);
    try std.testing.expectEqual(@as(usize, 4), resumed.items.len);
    try std.testing.expectEqualStrings("no credentials", resumed.items[1].reason.?);
    try std.testing.expectEqual(Kind.question, resumed.items[2].kind);
    try std.testing.expectEqual(ledger.Outcome.failed, resumed.checks.find("t4").?.outcome());
    try applyOk(&resumed, .{ .replace = &.{
        .{ .id = "t4", .title = "suite", .status = .in_progress },
        .{ .title = "new", .status = .pending },
    } }, .{});
    try std.testing.expectEqualStrings("t5", resumed.items[1].id);
    try std.testing.expectEqualStrings("t3", resumed.items[2].id);
    const again = try resumed.encodeJson(alloc);
    defer alloc.free(again);
    try std.testing.expect(std.mem.find(u8, again, "\"exit_code\":2") != null);
}

test "an unreadable or absent saved list leaves the list empty and unseeded" {
    var state: State = .{};
    defer state.deinit();
    try applyOk(&state, .{ .replace = &.{.{ .title = "edit", .status = .pending }} }, .{});
    state.restoreJson("{\"items\":[{\"title\":3}]}");
    try std.testing.expect(!state.seeded);
    try std.testing.expectEqual(@as(usize, 0), state.items.len);
    state.restoreJson(null);
    try std.testing.expect(!state.seeded);
    state.restoreJson("{\"v\":1,\"next_id\":1,\"items\":[{\"title\":\"kept\",\"status\":\"pending\"},{\"title\":\"\",\"status\":\"done\"}]}");
    try std.testing.expect(state.seeded);
    try std.testing.expectEqual(@as(usize, 1), state.items.len);
    try std.testing.expectEqualStrings("t1", state.items[0].id);
}

test "a session saved before todos were stored takes its list from the last TodoList call in history" {
    var calls = [_]types.ToolCall{.{
        .id = "call-todo",
        .name = tool_name,
        .arguments_json = "{\"todos\":[{\"title\":\"plan\",\"status\":\"done\"},{\"title\":\"edit\",\"status\":\"in_progress\"}]}",
    }};
    var steps = [_]types.ToolExecutionStep{.{ .tool_calls = &calls }};
    const history = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("question") },
        .assistant = @constCast("answer"),
        .execution = .{ .tool_steps = &steps },
    } }};
    var state: State = .{};
    defer state.deinit();
    const items = try state.view(&history);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("t2", items[1].id);
    try std.testing.expectEqual(Status.in_progress, items[1].status);
    try std.testing.expectEqual(@as(u64, 0), state.revision);
}

test "reading the current list before any write derives it from history and leaves the state unseeded" {
    var calls = [_]types.ToolCall{.{
        .id = "call-todo",
        .name = tool_name,
        .arguments_json = "{\"todos\":[{\"title\":\"plan\",\"status\":\"done\"},{\"title\":\"edit\",\"status\":\"in_progress\"}]}",
    }};
    var steps = [_]types.ToolExecutionStep{.{ .tool_calls = &calls }};
    const history = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("question") },
        .assistant = @constCast("answer"),
        .execution = .{ .tool_steps = &steps },
    } }};
    var scratch_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_state.deinit();
    var state: State = .{};
    defer state.deinit();
    const derived = try state.current(scratch_state.allocator(), &history);
    try std.testing.expectEqual(@as(usize, 2), derived.len);
    try std.testing.expectEqualStrings("t1", derived[0].id);
    try std.testing.expectEqualStrings("edit", derived[1].title);
    try std.testing.expect(!state.seeded);
    try std.testing.expectEqual(@as(u32, 1), state.next_id);
    try std.testing.expectEqual(@as(u64, 0), state.revision);

    try applyOk(&state, .{ .replace = &.{.{ .title = "ship", .status = .pending }} }, .{ .history = &history });
    const stored = try state.current(scratch_state.allocator(), &history);
    try std.testing.expectEqual(state.items.ptr, stored.ptr);
    try std.testing.expectEqual(@as(usize, 1), stored.len);
    try std.testing.expectEqualStrings("ship", stored[0].title);
}

test "the list can be shown by status" {
    const alloc = std.testing.allocator;
    const items = [_]Item{
        .{ .id = "t1", .title = "edit", .status = .in_progress },
        .{ .id = "t2", .title = "deploy", .status = .blocked, .reason = "no credentials" },
        .{ .id = "t3", .title = "plan", .status = .done },
    };
    const blocked = try renderList(alloc, &items, null, .blocked);
    defer alloc.free(blocked);
    try std.testing.expectEqualStrings("Todos shown by status:\n  [blocked] t2 deploy (blocked: no credentials)", blocked);
    const open = try renderList(alloc, &items, null, .open);
    defer alloc.free(open);
    try std.testing.expectEqualStrings("Todos shown by status:\n  [in_progress] t1 edit", open);
    const none = try renderList(alloc, items[2..], null, .open);
    defer alloc.free(none);
    try std.testing.expectEqualStrings("No todo is open; the list has 1.", none);
    const empty = try renderList(alloc, &.{}, null, .all);
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("Todo list is empty.", empty);
}

test "the next-step hint counts only pending and in_progress items as open" {
    const alloc = std.testing.allocator;
    const blocked_only = [_]Item{.{ .id = "t1", .title = "deploy", .status = .blocked, .reason = "x" }};
    try std.testing.expect(try nextStepHint(alloc, &blocked_only) == null);
    const none_started = [_]Item{.{ .id = "t1", .title = "edit", .status = .pending }};
    const hint = (try nextStepHint(alloc, &none_started)).?;
    defer alloc.free(hint);
    try std.testing.expectEqualStrings("No item is in_progress. Mark the one you are working on as in_progress.", hint);
}
