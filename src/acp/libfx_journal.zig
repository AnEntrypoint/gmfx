const std = @import("std");
const observation = @import("../core/agent/runtime/observation.zig");
const jsonrpc = @import("jsonrpc.zig");
const journal = @import("../core/agent/runtime/journal.zig");
const session_runtime = @import("../core/session/session.zig");
const session_codec = @import("../core/session/session_codec.zig");
const types = @import("../core/shared/types.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const session_adapter = @import("../core/session/session_adapter.zig");
const checkpoint_codec = @import("../core/agent/runtime/checkpoint.zig");
const execution_memory = @import("../core/agent/execution_memory.zig");
const runtime_execution_memory = @import("../core/agent/runtime/execution_memory.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const Event = journal.Event;
pub const max_load_bytes = journal.max_load_bytes;
const resume_notice = runtime_execution_memory.resume_notice;

pub const TurnId = struct {
    bytes: [journal.max_turn_id_bytes]u8 = undefined,
    len: u8 = 0,

    pub fn of(id: ?[]const u8) TurnId {
        const value = id orelse return .{};
        std.debug.assert(value.len <= journal.max_turn_id_bytes);
        var turn_id: TurnId = .{ .len = @intCast(value.len) };
        @memcpy(turn_id.bytes[0..value.len], value);
        return turn_id;
    }

    pub fn slice(self: *const TurnId) ?[]const u8 {
        return if (self.len == 0) null else self.bytes[0..self.len];
    }
};

pub const Journal = struct {
    writer: *jsonrpc.Writer,
    cursor: journal.Cursor = .{},
    progress_open: bool = false,
    pending_resume: ?session_codec.RecoveryCheckpoint = null,
    pending_resume_answered: ?usize = null,
    barrier_next_progress: bool = false,
    placed_next: std.ArrayList([]const u8) = .empty,
    pending_inputs: []journal.PendingInput = &.{},
    pending_follow_ups: []journal.PendingInput = &.{},
    follow_ups_waiting: usize = 0,
    steers_waiting: usize = 0,
    placing_follow_up: ?[]u8 = null,
    cancelled_progress: ?session_codec.RecoveryCheckpoint = null,
    next_turn_id: TurnId = .{},
    open_turn_id: TurnId = .{},
    last_turn_id: TurnId = .{},
    yield_at_ms: ?i64 = null,
    yield_armed: bool = false,
    inputs_durable: bool = false,
    pending_resume_yielded: bool = false,
    image_store: bool = false,
    image_window: session_codec.ImageWindow = .{},
    stored_images: session_codec.StoredImages = .{},
    pending_resume_ambiguous: []types.ToolCall = &.{},
    last_progress: ?LastProgress = null,

    const LastProgress = struct {
        seq: u64,
        hashes: session_codec.ExecutionHashes,
        stale: bool = false,
    };

    pub fn deinit(self: *Journal, alloc: Allocator) void {
        self.stored_images.deinit(alloc);
        if (self.last_progress) |*last| last.hashes.deinit(alloc);
        self.last_progress = null;
        self.dropPendingResume(alloc);
        self.clearPlaced(alloc);
        self.placed_next.deinit(alloc);
        if (self.placing_follow_up) |id| alloc.free(id);
        if (self.cancelled_progress) |*checkpoint| checkpoint.deinit(alloc);
        self.cancelled_progress = null;
        journal.freePendingInputs(alloc, self.takeFollowUps());
    }

    pub fn nameNextTurn(self: *Journal, id: ?[]const u8) void {
        self.next_turn_id = TurnId.of(id);
    }

    pub fn takeFollowUps(self: *Journal) []journal.PendingInput {
        const follow_ups = self.pending_follow_ups;
        self.pending_follow_ups = &.{};
        return follow_ups;
    }

    pub fn dropPendingResume(self: *Journal, alloc: Allocator) void {
        if (self.pending_resume) |*checkpoint| checkpoint.deinit(alloc);
        self.pending_resume = null;
        self.pending_resume_answered = null;
        self.pending_resume_yielded = false;
        types.freeToolCallSlice(alloc, self.pending_resume_ambiguous);
        self.pending_resume_ambiguous = &.{};
        if (self.pending_inputs.len > 0) {
            debug_trace.logf("session", "event=libfx_journal_inputs_dropped count={d} reason=resume_replaced", .{self.pending_inputs.len});
        }
        self.dropPendingInputs(alloc);
    }

    pub fn ambiguousCalls(self: *const Journal) []const types.ToolCall {
        if (self.pending_resume == null) return &.{};
        return self.pending_resume_ambiguous;
    }

    pub fn takePendingInputs(self: *Journal) []journal.PendingInput {
        const inputs = self.pending_inputs;
        self.pending_inputs = &.{};
        return inputs;
    }

    fn dropPendingInputs(self: *Journal, alloc: Allocator) void {
        journal.freePendingInputs(alloc, self.pending_inputs);
        self.pending_inputs = &.{};
    }

    pub fn notePlaced(self: *Journal, alloc: Allocator, ids: []const []const u8) Allocator.Error!void {
        if (ids.len == 0) return;
        try self.placed_next.ensureUnusedCapacity(alloc, ids.len);
        for (ids) |id| self.placed_next.appendAssumeCapacity(try alloc.dupe(u8, id));
        if (!self.inputs_durable) self.barrier_next_progress = true;
    }

    pub fn startYieldClock(self: *Journal, yield_at_ms: ?i64) void {
        self.yield_at_ms = yield_at_ms;
        self.yield_armed = false;
    }

    pub fn yieldsAt(self: *Journal, now_ms: i64) bool {
        const deadline = self.yield_at_ms orelse return false;
        if (!self.yield_armed) {
            self.yield_armed = true;
            return false;
        }
        return now_ms >= deadline;
    }

    pub fn keepYielded(self: *Journal, session_alloc: Allocator, checkpoint: session_codec.RecoveryCheckpoint) Allocator.Error!void {
        const owned = try checkpoint.dupe(session_alloc);
        self.dropPendingResume(session_alloc);
        self.pending_resume = owned;
        self.pending_resume_yielded = true;
        self.yield_at_ms = null;
    }

    fn clearPlaced(self: *Journal, alloc: Allocator) void {
        for (self.placed_next.items) |id| alloc.free(id);
        self.placed_next.clearRetainingCapacity();
    }

    pub fn endUnplaced(self: *Journal, alloc: Allocator, session_alloc: Allocator, session_id: []const u8) !void {
        if (self.placing_follow_up) |id| {
            try self.append(alloc, session_id, .{ .input_withdrawn = id });
            debug_trace.logf("session", "event=libfx_journal_follow_up_withdrawn reason=turn_ended_before_request", .{});
            self.follow_ups_waiting -|= 1;
            session_alloc.free(id);
            self.placing_follow_up = null;
        }
        if (self.placed_next.items.len == 0) return;
        debug_trace.logf("session", "event=libfx_journal_inputs_dropped count={d} reason=turn_ended_before_request", .{self.placed_next.items.len});
        self.clearPlaced(session_alloc);
    }

    pub fn takeCancelledProgress(self: *Journal) ?session_codec.RecoveryCheckpoint {
        const checkpoint = self.cancelled_progress;
        self.cancelled_progress = null;
        return checkpoint;
    }

    pub fn appendProgress(
        self: *Journal,
        alloc: Allocator,
        session_alloc: Allocator,
        session_id: []const u8,
        checkpoint: session_codec.RecoveryCheckpoint,
        model: []const u8,
    ) !void {
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const hashes = try session_codec.executionHashes(scratch.allocator(), checkpoint);
        const delta: ?journal.Delta = if (self.last_progress) |last|
            if (self.progress_open and !last.stale and hashes.extends(last.hashes))
                .{ .base_seq = last.seq, .from = last.hashes.counts() }
            else
                null
        else
            null;
        const seq = self.cursor.next_seq;
        try self.appendMarked(alloc, session_id, .{ .turn_progress = .{
            .checkpoint = checkpoint,
            .placed = self.placed_next.items,
            .model = model,
            .turn_id = self.next_turn_id.slice(),
            .delta = delta,
        } }, self.barrier_next_progress);

        if (self.last_progress) |*last| last.hashes.deinit(session_alloc);
        self.last_progress = null;
        if (hashes.dupe(session_alloc)) |owned| {
            self.last_progress = .{ .seq = seq, .hashes = owned };
        } else |_| {
            debug_trace.logf("session", "event=libfx_journal_progress_base_dropped seq={d} reason=out_of_memory next=full", .{seq});
        }
        const follow_up_placed: usize = @intFromBool(self.placing_follow_up != null);
        self.steers_waiting -|= self.placed_next.items.len -| follow_up_placed;
        if (self.next_turn_id.len > 0) {
            self.open_turn_id = self.next_turn_id;
            self.next_turn_id = .{};
        }
        if (self.placing_follow_up) |id| {
            self.follow_ups_waiting -|= 1;
            session_alloc.free(id);
            self.placing_follow_up = null;
        }
        self.clearPlaced(session_alloc);
    }

    pub fn append(self: *Journal, alloc: Allocator, session_id: []const u8, event: Event) !void {
        return self.appendMarked(alloc, session_id, event, false);
    }

    pub fn appendMarked(self: *Journal, alloc: Allocator, session_id: []const u8, event: Event, barrier: bool) !void {
        var params: std.Io.Writer.Allocating = .init(alloc);
        defer params.deinit();
        try params.writer.writeAll("{\"sessionId\":");
        try jsonrpc.writeJsonStr(session_id, &params.writer);
        try params.writer.writeAll(",\"events\":[");
        const next = if (self.storedImages()) |stored|
            try self.cursor.writeNamingImages(&params.writer, event, stored)
        else
            try self.cursor.write(&params.writer, event);
        try params.writer.writeByte(']');
        if (barrier) try params.writer.writeAll(",\"barrier\":true");
        try params.writer.writeByte('}');
        try self.writer.writeNotification(alloc, "libfx/journal_append", params.written());
        self.cursor = next;

        switch (event) {
            .turn_progress => self.progress_open = true,
            .turn_committed, .turn_progress_cleared => {
                self.progress_open = false;
                self.last_turn_id = self.open_turn_id;
                self.open_turn_id = .{};

                self.steers_waiting = 0;

                if (self.last_progress) |*last| last.stale = true;
            },
            .input_accepted => |input| switch (input.kind) {
                .follow_up => self.follow_ups_waiting += 1,
                .steer => self.steers_waiting += 1,
            },
            .tool_intent, .history_replaced, .input_withdrawn, .turn_yielded, .tool_result => {},
        }
    }

    pub fn storedImages(self: *const Journal) ?*const session_codec.StoredImages {
        return if (self.image_store) &self.stored_images else null;
    }

    pub fn noteStoredImage(
        self: *Journal,
        alloc: Allocator,
        image: types.ImageAttachment,
        name: session_codec.ImageName,
    ) Allocator.Error!void {
        if (!self.image_store) return;
        const digest = image.snapshot_sha256 orelse return;
        if (image.inline_data == null or !std.mem.eql(u8, digest, &name)) {
            debug_trace.logf("session", "event=libfx_image_not_stored id={d} reason=name_mismatch", .{image.id});
            return;
        }
        try self.stored_images.add(alloc, name);
    }

    pub fn dropOutsideWindow(
        self: *Journal,
        alloc: Allocator,
        history_alloc: Allocator,
        history: []types.HistoryTurn,
    ) Allocator.Error!void {
        if (!self.image_store) return;
        var held: std.ArrayList(HeldImage) = .empty;
        defer held.deinit(alloc);
        var sizes: std.ArrayList(?usize) = .empty;
        defer sizes.deinit(alloc);
        for (history) |*turn| {
            if (userOf(turn)) |user| for (user.images) |*image| {
                if (try countSize(alloc, &sizes, windowSize(image.*))) try held.append(alloc, .{ .prompt = image });
            };
            if (executionOf(turn)) |execution| for (execution.tool_steps) |step| for (step.tool_results) |result| for (result.tool_images) |*image| {
                if (try countSize(alloc, &sizes, toolWindowSize(image.*))) try held.append(alloc, .{ .tool = image });
            };
        }
        const outside = self.image_window.oldestOutside(sizes.items);
        var dropped: usize = 0;
        for (held.items[0..outside]) |image| switch (image) {
            .prompt => |prompt| {
                const bytes = prompt.inline_data orelse continue;
                history_alloc.free(bytes);
                prompt.inline_data = null;
                dropped += 1;
            },
            .tool => |tool| {
                if (tool.droppedFromSession()) continue;
                if (tool.name == null) {
                    tool.name = try inlineToolImageName(alloc, tool.data) orelse {
                        debug_trace.logf("session", "event=libfx_image_kept reason=inline_tool_image_not_base64 bytes={d}", .{tool.data.len});
                        continue;
                    };
                }
                const empty = try history_alloc.alloc(u8, 0);
                history_alloc.free(tool.data);
                tool.data = empty;
                dropped += 1;
            },
        };
        if (dropped > 0) debug_trace.logf("session", "event=libfx_images_dropped count={d} reason=image_window max_images={d} max_bytes={d}", .{ dropped, self.image_window.max_images, self.image_window.max_bytes });
    }

    pub fn recordToolResult(self: *Journal, alloc: Allocator, session_id: []const u8, result: journal.ToolResult) !void {
        if (!self.progress_open) return;
        try self.append(alloc, session_id, .{ .tool_result = result });
    }

    pub fn placeFollowUp(self: *Journal, alloc: Allocator, id: []const u8) Allocator.Error!void {
        const owned = try alloc.dupe(u8, id);
        errdefer alloc.free(owned);
        try self.notePlaced(alloc, &.{id});
        if (self.placing_follow_up) |old| alloc.free(old);
        self.placing_follow_up = owned;
    }

    pub fn quiet(self: *const Journal) bool {
        return !self.progress_open and self.pending_resume == null and
            self.follow_ups_waiting == 0 and self.cursor.next_seq > 1;
    }

    pub fn yieldedQuiet(self: *const Journal) bool {
        return self.progress_open and self.pending_resume != null and self.pending_resume_yielded and
            self.pending_resume_answered == null and self.pending_inputs.len == 0 and
            self.steers_waiting == 0 and self.follow_ups_waiting == 0;
    }

    pub fn noteOpenTurnSnapshot(self: *Journal) void {
        if (self.last_progress) |*last| last.stale = true;
    }

    pub fn clearProgress(self: *Journal, alloc: Allocator, session_id: []const u8) !void {
        if (!self.progress_open) return;
        try self.append(alloc, session_id, .turn_progress_cleared);
    }
};

pub const Opened = struct {
    turns: usize,
    resumable: bool,
    open_turn_id: TurnId = .{},
    last_turn_id: TurnId = .{},
    yielded: bool = false,
    checkpoint_meta: checkpoint_codec.Meta = .{},
};

fn dupePendingInputs(alloc: Allocator, inputs: []const journal.PendingInput) Allocator.Error![]journal.PendingInput {
    const owned = try alloc.alloc(journal.PendingInput, inputs.len);
    var filled: usize = 0;
    errdefer {
        for (owned[0..filled]) |input| {
            alloc.free(input.id);
            alloc.free(input.text);
        }
        alloc.free(owned);
    }
    for (inputs) |input| {
        const id = try alloc.dupe(u8, input.id);
        errdefer alloc.free(id);
        owned[filled] = .{ .id = id, .text = try alloc.dupe(u8, input.text) };
        filled += 1;
    }
    return owned;
}

fn userOf(turn: *types.HistoryTurn) ?*types.UserTurn {
    return switch (turn.*) {
        .assistant => |*entry| &entry.user,
        .interrupted => |*entry| &entry.user,
        .compacted_summary => null,
    };
}

fn executionOf(turn: *types.HistoryTurn) ?*types.ExecutionMemory {
    return switch (turn.*) {
        .assistant => |*entry| &entry.execution,
        .interrupted => |*entry| &entry.execution,
        .compacted_summary => null,
    };
}

const HeldImage = union(enum) {
    prompt: *types.ImageAttachment,
    tool: *types.ToolImage,
};

const MissingImages = std.array_hash_map.Auto(session_codec.ImageName, usize);

const WindowSize = union(enum) {
    bytes: usize,
    dropped,
    none,
};

fn windowSize(image: types.ImageAttachment) WindowSize {
    if (image.inline_data) |bytes| return .{ .bytes = bytes.len };
    return if (image.droppedFromSession()) .dropped else .none;
}

fn toolWindowSize(image: types.ToolImage) WindowSize {
    if (image.droppedFromSession()) return .dropped;
    if (image.data.len == 0) return .none;
    return .{ .bytes = std.base64.standard.Decoder.calcSizeForSlice(image.data) catch image.data.len };
}

fn inlineToolImageName(alloc: Allocator, data: []const u8) Allocator.Error!?session_codec.ImageName {
    const size = std.base64.standard.Decoder.calcSizeForSlice(data) catch return null;
    const bytes = try alloc.alloc(u8, size);
    defer alloc.free(bytes);
    std.base64.standard.Decoder.decode(bytes, data) catch return null;
    return session_codec.imageNameOf(bytes);
}

const Unstaged = struct { name: session_codec.ImageName, size: usize };

fn unstaged(image: types.ImageAttachment, missing: *const MissingImages) ?Unstaged {
    if (!image.droppedFromSession()) return null;
    const name = session_codec.imageName(image.snapshot_sha256.?) orelse return null;
    return .{ .name = name, .size = missing.get(name) orelse return null };
}

fn unstagedTool(image: types.ToolImage, missing: *const MissingImages) ?Unstaged {
    if (!image.droppedFromSession()) return null;
    const name = image.name.?;
    return .{ .name = name, .size = missing.get(name) orelse return null };
}

fn countSize(alloc: Allocator, sizes: *std.ArrayList(?usize), size: WindowSize) Allocator.Error!bool {
    switch (size) {
        .bytes => |bytes| try sizes.append(alloc, bytes),
        .dropped => try sizes.append(alloc, null),
        .none => return false,
    }
    return true;
}

fn keepNeededImages(
    alloc: Allocator,
    images: *session_codec.ImageResolver,
    history: []const types.HistoryTurn,
    open_user: ?types.UserTurn,
    open_execution: ?types.ExecutionMemory,
    open_finished: []const journal.Finished,
    window: session_codec.ImageWindow,
) Allocator.Error!void {
    var sizes: std.ArrayList(?usize) = .empty;
    defer sizes.deinit(alloc);
    var names: std.ArrayList(?session_codec.ImageName) = .empty;
    defer names.deinit(alloc);
    for (history) |turn| {
        const user, const execution = switch (turn) {
            .assistant => |entry| .{ entry.user, entry.execution },
            .interrupted => |entry| .{ entry.user, entry.execution },
            .compacted_summary => continue,
        };
        try countOpenedImages(alloc, &sizes, &names, user.images, &images.missing);
        try countOpenedToolImages(alloc, &sizes, &names, execution, &images.missing);
    }
    const outside = window.oldestOutside(sizes.items);
    var needed: MissingImages = .empty;
    errdefer needed.deinit(images.alloc);
    for (names.items[outside..], sizes.items[outside..]) |name, size| {
        if (name) |value| try needed.put(images.alloc, value, size.?);
    }
    if (open_user) |user| for (user.images) |image| {
        if (unstaged(image, &images.missing)) |found| try needed.put(images.alloc, found.name, found.size);
    };
    if (open_execution) |execution| for (execution.tool_steps) |step| for (step.tool_results) |result| for (result.tool_images) |image| {
        if (unstagedTool(image, &images.missing)) |found| try needed.put(images.alloc, found.name, found.size);
    };

    for (open_finished) |finished| for (finished.images) |image| {
        if (unstagedTool(image, &images.missing)) |found| try needed.put(images.alloc, found.name, found.size);
    };
    if (outside > 0) debug_trace.logf("session", "event=libfx_image_window_open outside={d} needed={d}", .{ outside, needed.count() });
    images.missing.deinit(images.alloc);
    images.missing = needed;
}

fn countOpenedImages(
    alloc: Allocator,
    sizes: *std.ArrayList(?usize),
    names: *std.ArrayList(?session_codec.ImageName),
    user_images: []const types.ImageAttachment,
    missing: *const MissingImages,
) Allocator.Error!void {
    for (user_images) |image| {
        const pending = unstaged(image, missing);
        if (!try countSize(alloc, sizes, if (pending) |found| .{ .bytes = found.size } else windowSize(image))) continue;
        try names.append(alloc, if (pending) |found| found.name else null);
    }
}

fn countOpenedToolImages(
    alloc: Allocator,
    sizes: *std.ArrayList(?usize),
    names: *std.ArrayList(?session_codec.ImageName),
    execution: types.ExecutionMemory,
    missing: *const MissingImages,
) Allocator.Error!void {
    for (execution.tool_steps) |step| for (step.tool_results) |result| for (result.tool_images) |image| {
        const pending = unstagedTool(image, missing);
        if (!try countSize(alloc, sizes, if (pending) |found| .{ .bytes = found.size } else toolWindowSize(image))) continue;
        try names.append(alloc, if (pending) |found| found.name else null);
    };
}

pub fn open(
    alloc: Allocator,
    session_alloc: Allocator,
    writer: *jsonrpc.Writer,
    runtime: *session_runtime.SessionRuntime,
    events_json: []const u8,
    snapshot: ?[]const u8,
    inputs_durable: bool,
    images: *session_codec.ImageResolver,
    image_store: bool,
    window: session_codec.ImageWindow,
) !struct { Journal, Opened } {
    if (!runtime.agent.fresh or runtime.agent.history.items.len != 0) return error.AgentNotFresh;
    var base: journal.Base = .{ .images = images };
    var decoded: ?checkpoint_codec.Decoded = null;
    defer if (decoded) |*value| value.deinit(alloc);
    var saved_meta: checkpoint_codec.Meta = .{};
    errdefer saved_meta.free(alloc);
    if (snapshot) |bytes| {
        const parsed = try journal.parseSnapshot(bytes);
        decoded = checkpoint_codec.decodeWithImages(alloc, parsed.checkpoint, images) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnsupportedCheckpointVersion => return error.UnsupportedJournalVersion,
            else => return error.InvalidJournal,
        };
        saved_meta = try decoded.?.meta.dupe(alloc);
        base = .{
            .history = decoded.?.history,
            .cursor = .{ .next_seq = parsed.seq + 1, .turn = parsed.turn },
            .last_turn_id = parsed.last_turn_id,
            .open_turn = parsed.open_turn,
            .images = images,
        };
    }
    var folded = try journal.foldFrom(alloc, events_json, base);
    defer folded.deinit(alloc);
    if (image_store and images.missing.count() > 0) {
        try keepNeededImages(alloc, images, folded.history, if (folded.open_turn) |turn| turn.user else null, if (folded.open_turn) |turn| turn.execution else null, folded.finished, window);
    }

    if (images.missing.count() > 0) {
        debug_trace.logf("session", "event=libfx_journal_images_missing count={d}", .{images.missing.count()});
        return error.ImagesMissing;
    }
    if (folded.history.len > 0) try runtime.agent.restoreHistory(alloc, folded.history);
    if (decoded) |value| runtime.agent.turn_usage = value.usage;
    var state: Journal = .{
        .writer = writer,
        .cursor = folded.cursor,
        .progress_open = folded.open_turn != null,
        .pending_follow_ups = try dupePendingInputs(session_alloc, folded.pending_follow_ups),
        .follow_ups_waiting = folded.pending_follow_ups.len,
        .open_turn_id = TurnId.of(folded.open_turn_id),
        .last_turn_id = TurnId.of(folded.last_turn_id),
        .inputs_durable = inputs_durable,
        .steers_waiting = folded.pending_inputs.len,
        .image_store = image_store,
        .image_window = window,
    };
    errdefer state.deinit(session_alloc);

    if (image_store) for (images.resolved.keys()) |name| try state.stored_images.add(session_alloc, name);
    try state.dropOutsideWindow(alloc, alloc, runtime.agent.history.items);
    const checkpoint = folded.open_turn orelse {
        return .{ state, .{ .turns = folded.history.len, .resumable = false, .last_turn_id = state.last_turn_id, .checkpoint_meta = saved_meta } };
    };

    debug_trace.logf("session", "event=libfx_journal_open_turn turn={d} running_calls={d} finished_calls={d} resolved=pending_resume", .{ folded.cursor.turn, folded.running_calls.len, folded.finished.len });
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var answered = checkpoint;
    forgetUnrecordedCalls(&answered, folded.running_calls.len);
    const answered_step = answered.execution.tool_steps.len;
    try answerRunning(scratch.allocator(), &answered, folded.running_calls, folded.finished);
    state.pending_resume = try answered.dupe(session_alloc);
    if (folded.running_calls.len > 0) state.pending_resume_answered = answered_step;
    state.pending_resume_ambiguous = try unfinishedCalls(session_alloc, folded.running_calls, folded.finished);
    state.pending_resume_yielded = folded.yielded;
    state.pending_inputs = try dupePendingInputs(session_alloc, folded.pending_inputs);
    return .{ state, .{
        .turns = folded.history.len,
        .resumable = true,
        .open_turn_id = state.open_turn_id,
        .last_turn_id = state.last_turn_id,
        .yielded = folded.yielded,
        .checkpoint_meta = saved_meta,
    } };
}

pub fn resumeCheckpoint(
    alloc: Allocator,
    pending: session_codec.RecoveryCheckpoint,
    inputs: []const journal.PendingInput,
    yielded: bool,
) !session_codec.RecoveryCheckpoint {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var view = pending;
    const old = view.execution.steering;
    const notices: usize = if (yielded) 0 else 1;
    const steering = try scratch.allocator().alloc(types.PersistedSteering, old.len + notices + inputs.len);
    @memcpy(steering[0..old.len], old);
    const after = view.execution.tool_steps.len;
    if (!yielded) steering[old.len] = .{ .text = @constCast(resume_notice), .after_tool_step_count = after };
    for (inputs, steering[old.len + notices ..]) |input, *entry| {
        entry.* = .{ .text = input.text, .after_tool_step_count = after };
    }
    view.execution.steering = steering;
    view.consumed_provider_attempts = 0;
    view.outstanding_reservation = false;
    return view.dupe(alloc);
}

fn forgetUnrecordedCalls(turn: *session_codec.RecoveryCheckpoint, running: usize) void {
    if (running > 0 or turn.tool_state != .uncertain) return;
    debug_trace.logf("session", "event=libfx_journal_response_dropped reason=calls_never_recorded assistant_bytes={d}", .{turn.assistant_source.len});
    turn.tool_state = .none;
    turn.assistant_source = @constCast("");
}

fn unfinishedCalls(alloc: Allocator, calls: []const types.ToolCall, finished: []const journal.Finished) Allocator.Error![]types.ToolCall {
    var kept: std.ArrayList(types.ToolCall) = .empty;
    errdefer {
        for (kept.items) |call| types.freeToolCall(alloc, call);
        kept.deinit(alloc);
    }
    for (calls) |call| {
        if (finishedResult(finished, call.id) != null) continue;
        const copy = try types.dupeToolCall(alloc, call);
        kept.append(alloc, copy) catch |err| {
            types.freeToolCall(alloc, copy);
            return err;
        };
    }
    return kept.toOwnedSlice(alloc);
}

fn finishedResult(finished: []const journal.Finished, id: []const u8) ?journal.Finished {
    for (finished) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
    return null;
}

fn answerRunning(scratch: Allocator, turn: *session_codec.RecoveryCheckpoint, calls: []types.ToolCall, finished: []const journal.Finished) Allocator.Error!void {
    if (calls.len == 0) return;
    const unfinished = session_adapter.unfinished_tool_output;
    const results = try scratch.alloc(types.PersistedToolResult, calls.len);
    for (calls, results) |call, *result| {
        const recorded = finishedResult(finished, call.id);
        const output: []const u8 = if (recorded) |entry| entry.output else unfinished;
        result.* = .{
            .tool_call_id = @constCast(call.id),
            .tool_name = @constCast(call.name),
            .status = if (recorded) |entry| (if (entry.failed) .failure else .success) else .failure,
            .output = @constCast(output),
            .tool_images = if (recorded) |entry| entry.images else &.{},
            .output_bytes = output.len,
            .stored_output_bytes = output.len,
        };
    }
    const old = turn.execution.tool_steps;
    const steps = try scratch.alloc(types.ToolExecutionStep, old.len + 1);
    @memcpy(steps[0..old.len], old);
    steps[old.len] = .{
        .assistant = if (turn.assistant_source.len > 0) turn.assistant_source else null,
        .tool_calls = calls,
        .tool_results = results,
    };
    turn.execution.tool_steps = steps;
    turn.assistant_source = @constCast("");
    turn.tool_state = .confirmed;
}

pub fn rerunCalls(
    alloc: Allocator,
    checkpoint: *session_codec.RecoveryCheckpoint,
    step_index: usize,
    runner: anytype,
    observer: ?*observation.Observer,
) !usize {
    const steps = checkpoint.execution.tool_steps;
    if (step_index >= steps.len) return 0;
    const step = &steps[step_index];
    var reran: usize = 0;
    for (step.tool_calls, step.tool_results) |call, *result| {
        if (!runner.rerun(call)) continue;
        const outcome = (try runner.run(alloc, call)) orelse {
            debug_trace.logf("session", "event=libfx_resume_rerun_stopped call={s} reran={d} kept=may_have_partly_run", .{ call.id, reran });
            break;
        };
        defer outcome.deinit(alloc);
        const replacement = try persistedResult(alloc, call, outcome);
        types.freePersistedToolResult(alloc, result.*);
        result.* = replacement;
        if (observer) |sink| sink.emit(.{ .tool_result = .{ .call = call, .output = replacement.output, .status = replacement.status } });
        reran += 1;
        debug_trace.logf("session", "event=libfx_resume_rerun call={s} tool={s} status={s}", .{ call.id, call.name, @tagName(replacement.status) });
    }
    return reran;
}

fn persistedResult(alloc: Allocator, call: types.ToolCall, outcome: tool_dispatch.ToolResult) !types.PersistedToolResult {
    return switch (outcome) {
        .success => |text| execution_memory.makePersistedToolResult(alloc, call.id, call.name, .success, text, null),
        .failure => |text| execution_memory.makePersistedToolResult(alloc, call.id, call.name, .failure, text, null),
        .rich => |content| execution_memory.makePersistedToolResult(
            alloc,
            call.id,
            call.name,
            if (content.is_error) .failure else .success,
            content.text,
            .{ .tool_images = content.images, .output_bytes = content.text.len, .stored_output_bytes = content.text.len },
        ),
    };
}

const TestCapture = struct {
    frames: std.ArrayList(u8) = .empty,

    fn write(raw: ?*anyopaque, frame: []const u8) !void {
        const self: *TestCapture = @ptrCast(@alignCast(raw.?));
        try self.frames.appendSlice(std.testing.allocator, frame);
    }
};

fn testProgress(alloc: Allocator) !session_codec.RecoveryCheckpoint {
    return .{
        .turn_id = 1,
        .user = .{ .text = try alloc.dupe(u8, "prompt") },
        .assistant_source = try alloc.dupe(u8, ""),
        .cause = .network_interrupted,
        .action = .retrying_request,
        .authority = .{ .provider = .gateway, .model = try alloc.dupe(u8, "fake/model") },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 3,
        .consumed_provider_attempts = 0,
    };
}

test "inputs taken for a request that never went out are not placed by the next turn" {
    const alloc = std.testing.allocator;
    var capture: TestCapture = .{};
    defer capture.frames.deinit(alloc);
    var writer = jsonrpc.Writer.initCallback(&capture, TestCapture.write);
    var session: Journal = .{ .writer = &writer };
    defer session.deinit(alloc);
    var progress = try testProgress(alloc);
    defer progress.deinit(alloc);

    try session.notePlaced(alloc, &.{"steer-1"});

    try session.endUnplaced(alloc, alloc, "session");
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    try std.testing.expect(std.mem.find(u8, capture.frames.items, "steer-1") == null);
}

test "a progress places the follow-up its turn runs" {
    const alloc = std.testing.allocator;
    var capture: TestCapture = .{};
    defer capture.frames.deinit(alloc);
    var writer = jsonrpc.Writer.initCallback(&capture, TestCapture.write);
    var session: Journal = .{ .writer = &writer, .follow_ups_waiting = 1, .cursor = .{ .next_seq = 3, .turn = 2 } };
    defer session.deinit(alloc);
    var progress = try testProgress(alloc);
    defer progress.deinit(alloc);

    try session.placeFollowUp(alloc, "follow-1");
    try std.testing.expectEqual(@as(usize, 1), session.follow_ups_waiting);
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    try std.testing.expectEqual(@as(usize, 0), session.follow_ups_waiting);
    try std.testing.expect(std.mem.find(u8, capture.frames.items, "\"inputs\":[\"follow-1\"]") != null);

    try session.endUnplaced(alloc, alloc, "session");
    try std.testing.expect(std.mem.find(u8, capture.frames.items, "input_withdrawn") == null);
}

test "a follow-up whose turn ended before its request is withdrawn, so it never runs again" {
    const alloc = std.testing.allocator;
    var capture: TestCapture = .{};
    defer capture.frames.deinit(alloc);
    var writer = jsonrpc.Writer.initCallback(&capture, TestCapture.write);
    var session: Journal = .{ .writer = &writer, .follow_ups_waiting = 1, .cursor = .{ .next_seq = 3, .turn = 2 } };
    defer session.deinit(alloc);

    try session.placeFollowUp(alloc, "follow-1");
    try std.testing.expect(!session.quiet());
    try session.endUnplaced(alloc, alloc, "session");
    try std.testing.expectEqual(@as(usize, 0), session.follow_ups_waiting);
    try std.testing.expect(session.quiet());
    try std.testing.expect(std.mem.find(u8, capture.frames.items, "\"type\":\"input_withdrawn\",\"data\":{\"id\":\"follow-1\"}") != null);
}

test "a turn's id reaches its first progress only, and is the last turn's once the turn ends" {
    const alloc = std.testing.allocator;
    var capture: TestCapture = .{};
    defer capture.frames.deinit(alloc);
    var writer = jsonrpc.Writer.initCallback(&capture, TestCapture.write);
    var session: Journal = .{ .writer = &writer };
    defer session.deinit(alloc);
    var progress = try testProgress(alloc);
    defer progress.deinit(alloc);

    session.nameNextTurn("turn-1");
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, capture.frames.items, "\"turnId\":\"turn-1\""));
    try std.testing.expectEqualStrings("turn-1", session.open_turn_id.slice().?);

    try session.clearProgress(alloc, "session");
    try std.testing.expect(session.open_turn_id.slice() == null);
    try std.testing.expectEqualStrings("turn-1", session.last_turn_id.slice().?);

    session.nameNextTurn(null);
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    try session.clearProgress(alloc, "session");
    try std.testing.expect(session.last_turn_id.slice() == null);
}

test "a response whose calls never reached the journal is asked for again" {
    const alloc = std.testing.allocator;
    var progress = try testProgress(alloc);
    defer progress.deinit(alloc);

    var lost = progress;
    lost.tool_state = .uncertain;
    lost.assistant_source = @constCast("Let me look that up.");
    forgetUnrecordedCalls(&lost, 0);
    try std.testing.expectEqual(session_codec.RecoveryToolState.none, lost.tool_state);
    try std.testing.expectEqualStrings("", lost.assistant_source);

    var recorded = progress;
    recorded.tool_state = .uncertain;
    recorded.assistant_source = @constCast("Let me look that up.");
    forgetUnrecordedCalls(&recorded, 1);
    try std.testing.expectEqual(session_codec.RecoveryToolState.uncertain, recorded.tool_state);
    try std.testing.expectEqualStrings("Let me look that up.", recorded.assistant_source);

    var partial = progress;
    partial.assistant_source = @constCast("The answer is");
    forgetUnrecordedCalls(&partial, 0);
    try std.testing.expectEqual(session_codec.RecoveryToolState.none, partial.tool_state);
    try std.testing.expectEqualStrings("The answer is", partial.assistant_source);
}

const TestRerunner = struct {
    ids: []const []const u8,
    stop_at: ?[]const u8 = null,
    ran: *std.ArrayList([]const u8),

    pub fn rerun(self: TestRerunner, call: types.ToolCall) bool {
        for (self.ids) |id| if (std.mem.eql(u8, id, call.id)) return true;
        return false;
    }

    pub fn run(self: TestRerunner, alloc: Allocator, call: types.ToolCall) !?tool_dispatch.ToolResult {
        if (self.stop_at) |id| if (std.mem.eql(u8, call.id, id)) return null;
        try self.ran.append(std.testing.allocator, call.id);
        return .{ .success = try alloc.print("ran again as {s}", .{call.id}) };
    }
};

fn testAnswered(alloc: Allocator, calls: []types.ToolCall) !session_codec.RecoveryCheckpoint {
    var progress = try testProgress(alloc);
    defer progress.deinit(alloc);
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var answered = progress;
    try answerRunning(scratch.allocator(), &answered, calls, &.{});
    return answered.dupe(alloc);
}

test "a progress after its turn's first carries only what is new, and the next turn's first carries all" {
    const alloc = std.testing.allocator;
    var capture: TestCapture = .{};
    defer capture.frames.deinit(alloc);
    var writer = jsonrpc.Writer.initCallback(&capture, TestCapture.write);
    var session: Journal = .{ .writer = &writer };
    defer session.deinit(alloc);
    var progress = try testProgress(alloc);
    defer progress.deinit(alloc);

    session.barrier_next_progress = true;
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    session.barrier_next_progress = false;
    try std.testing.expect(std.mem.find(u8, capture.frames.items, "\"barrier\":true") != null);
    try std.testing.expect(std.mem.find(u8, capture.frames.items, "\"user\"") != null);
    const first = capture.frames.items.len;
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    const second = capture.frames.items[first..];
    try std.testing.expect(std.mem.find(u8, second, "\"v\":2") != null);
    try std.testing.expect(std.mem.find(u8, second, "\"base\":1,\"steps\":0") != null);
    try std.testing.expect(std.mem.find(u8, second, "\"user\"") == null);
    try std.testing.expect(std.mem.find(u8, second, "\"barrier\"") == null);

    try session.recordToolResult(alloc, "session", .{ .id = "call-1", .name = "lookup", .failed = false, .output = "done" });
    try std.testing.expect(std.mem.find(u8, capture.frames.items, "\"type\":\"tool_result\"") != null);

    try session.clearProgress(alloc, "session");
    const next = capture.frames.items.len;
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    try std.testing.expect(std.mem.find(u8, capture.frames.items[next..], "\"base\"") == null);
    try std.testing.expect(std.mem.find(u8, capture.frames.items[next..], "\"user\"") != null);
}

test "a progress after a snapshot that holds its turn carries all of it" {
    const alloc = std.testing.allocator;
    var capture: TestCapture = .{};
    defer capture.frames.deinit(alloc);
    var writer = jsonrpc.Writer.initCallback(&capture, TestCapture.write);
    var session: Journal = .{ .writer = &writer };
    defer session.deinit(alloc);
    var progress = try testProgress(alloc);
    defer progress.deinit(alloc);

    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");

    session.noteOpenTurnSnapshot();
    const next = capture.frames.items.len;
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    try std.testing.expect(std.mem.find(u8, capture.frames.items[next..], "\"base\"") == null);
    try std.testing.expect(std.mem.find(u8, capture.frames.items[next..], "\"user\"") != null);

    const after = capture.frames.items.len;
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    try std.testing.expect(std.mem.find(u8, capture.frames.items[after..], "\"base\":2,") != null);
}

test "a resumed turn runs again the calls the host asks for and leaves the rest to the model" {
    const alloc = std.testing.allocator;
    var calls = [_]types.ToolCall{
        .{ .id = "call-1", .name = "read", .arguments_json = "{}" },
        .{ .id = "call-2", .name = "send", .arguments_json = "{}" },
        .{ .id = "call-3", .name = "read", .arguments_json = "{}" },
    };
    var answered = try testAnswered(alloc, &calls);
    defer answered.deinit(alloc);
    var ran: std.ArrayList([]const u8) = .empty;
    defer ran.deinit(alloc);

    const ids = [_][]const u8{ "call-1", "call-3" };
    const reran = try rerunCalls(alloc, &answered, 0, TestRerunner{ .ids = &ids, .ran = &ran }, null);
    try std.testing.expectEqual(@as(usize, 2), reran);
    try std.testing.expectEqual(@as(usize, 2), ran.items.len);
    const results = answered.execution.tool_steps[0].tool_results;

    try std.testing.expectEqualStrings("call-1", results[0].tool_call_id);
    try std.testing.expectEqualStrings("ran again as call-1", results[0].output);
    try std.testing.expectEqual(types.PersistedToolStatus.success, results[0].status);
    try std.testing.expectEqualStrings(session_adapter.unfinished_tool_output, results[1].output);
    try std.testing.expectEqual(types.PersistedToolStatus.failure, results[1].status);
    try std.testing.expectEqualStrings("ran again as call-3", results[2].output);
}

test "a resume cancelled during a rerun keeps that call and the later ones answered" {
    const alloc = std.testing.allocator;
    var calls = [_]types.ToolCall{
        .{ .id = "call-1", .name = "read", .arguments_json = "{}" },
        .{ .id = "call-2", .name = "read", .arguments_json = "{}" },
        .{ .id = "call-3", .name = "read", .arguments_json = "{}" },
    };
    var answered = try testAnswered(alloc, &calls);
    defer answered.deinit(alloc);
    var ran: std.ArrayList([]const u8) = .empty;
    defer ran.deinit(alloc);

    const ids = [_][]const u8{ "call-1", "call-2", "call-3" };
    const reran = try rerunCalls(alloc, &answered, 0, TestRerunner{ .ids = &ids, .stop_at = "call-2", .ran = &ran }, null);
    try std.testing.expectEqual(@as(usize, 1), reran);
    const results = answered.execution.tool_steps[0].tool_results;
    try std.testing.expectEqualStrings("ran again as call-1", results[0].output);
    try std.testing.expectEqualStrings(session_adapter.unfinished_tool_output, results[1].output);
    try std.testing.expectEqualStrings(session_adapter.unfinished_tool_output, results[2].output);

    try std.testing.expectEqual(@as(usize, 0), try rerunCalls(alloc, &answered, 5, TestRerunner{ .ids = &ids, .ran = &ran }, null));
}

fn windowTestImage(alloc: Allocator, id: usize, size: usize) !types.ImageAttachment {
    const bytes = try alloc.alloc(u8, size);
    errdefer alloc.free(bytes);
    @memset(bytes, 'x');
    const path = try alloc.dupe(u8, "inline://image");
    errdefer alloc.free(path);
    const media_type = try alloc.dupe(u8, "image/png");
    errdefer alloc.free(media_type);
    const digest = session_codec.imageNameOf(bytes);
    return .{ .id = id, .path = path, .media_type = media_type, .snapshot_sha256 = try alloc.dupe(u8, &digest), .inline_data = bytes };
}

test "the image window drops the oldest history images, and not for an open turn's" {
    const alloc = std.testing.allocator;
    var capture: TestCapture = .{};
    defer capture.frames.deinit(alloc);
    var writer = jsonrpc.Writer.initCallback(&capture, TestCapture.write);
    var session: Journal = .{ .writer = &writer, .image_store = true, .image_window = .{ .max_images = 2 } };
    defer session.deinit(alloc);
    var images: [3]types.ImageAttachment = undefined;
    for (&images, 0..) |*image, index| image.* = try windowTestImage(alloc, index + 1, 10);
    defer for (images) |image| types.freeImageAttachment(alloc, image);
    var history: [3]types.HistoryTurn = undefined;
    for (&history, &images) |*turn, *image| {
        turn.* = .{ .assistant = .{ .user = .{ .text = @constCast("look"), .images = image[0..1] }, .assistant = @constCast("ok") } };
    }

    try session.dropOutsideWindow(alloc, alloc, &history);
    try std.testing.expect(images[0].droppedFromSession());
    try std.testing.expect(images[1].inline_data != null and images[2].inline_data != null);

    var pending = try testProgress(alloc);
    pending.user.images = try alloc.alloc(types.ImageAttachment, 1);
    pending.user.images[0] = try windowTestImage(alloc, 4, 10);
    session.pending_resume = pending;
    try session.dropOutsideWindow(alloc, alloc, &history);
    try std.testing.expect(images[1].inline_data != null and images[2].inline_data != null);
    try std.testing.expect(session.pending_resume.?.user.images[0].inline_data != null);
}

fn windowTestToolImages(alloc: Allocator, size: usize, named: bool) ![]types.ToolImage {
    const bytes = try alloc.alloc(u8, size);
    defer alloc.free(bytes);
    @memset(bytes, 't');
    const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(size));
    errdefer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    const mime_type = try alloc.dupe(u8, "image/png");
    errdefer alloc.free(mime_type);
    const images = try alloc.alloc(types.ToolImage, 1);
    images[0] = .{ .data = encoded, .mime_type = mime_type, .name = if (named) session_codec.imageNameOf(bytes) else null };
    return images;
}

fn windowTestToolStep(results: *[1]types.PersistedToolResult, steps: *[1]types.ToolExecutionStep, images: []types.ToolImage) types.ExecutionMemory {
    results.* = .{.{
        .tool_images = images,
        .tool_call_id = @constCast("call"),
        .tool_name = @constCast("screenshot"),
        .status = .success,
        .output = @constCast("took it"),
        .output_bytes = 7,
        .stored_output_bytes = 7,
    }};
    steps.* = .{.{ .tool_results = results }};
    return .{ .tool_steps = steps };
}

test "the image window counts a turn's tool images after its prompt's, inline ones too, and drops them by name" {
    const alloc = std.testing.allocator;
    var capture: TestCapture = .{};
    defer capture.frames.deinit(alloc);
    var writer = jsonrpc.Writer.initCallback(&capture, TestCapture.write);
    var session: Journal = .{ .writer = &writer, .image_store = true, .image_window = .{ .max_images = 2 } };
    defer session.deinit(alloc);
    var prompts: [2]types.ImageAttachment = undefined;
    for (&prompts, 0..) |*image, index| image.* = try windowTestImage(alloc, index + 1, 10);
    defer for (prompts) |image| types.freeImageAttachment(alloc, image);
    var tools: [2][]types.ToolImage = undefined;
    for (&tools) |*images| images.* = try windowTestToolImages(alloc, 10, true);
    defer for (tools) |images| types.freeToolImages(alloc, images);

    const unstored = try windowTestToolImages(alloc, 12, false);
    defer types.freeToolImages(alloc, unstored);
    var unstored_bytes: [12]u8 = undefined;
    try std.base64.standard.Decoder.decode(&unstored_bytes, unstored[0].data);
    var results: [3][1]types.PersistedToolResult = undefined;
    var steps: [3][1]types.ToolExecutionStep = undefined;
    var history: [3]types.HistoryTurn = undefined;
    history[0] = .{ .assistant = .{ .user = .{ .text = @constCast("one"), .images = prompts[0..1] }, .assistant = @constCast("ok"), .execution = windowTestToolStep(&results[0], &steps[0], unstored) } };
    history[1] = .{ .assistant = .{ .user = .{ .text = @constCast("two"), .images = prompts[1..2] }, .assistant = @constCast("ok"), .execution = windowTestToolStep(&results[1], &steps[1], tools[0]) } };
    history[2] = .{ .assistant = .{ .user = .{ .text = @constCast("three") }, .assistant = @constCast("ok"), .execution = windowTestToolStep(&results[2], &steps[2], tools[1]) } };

    try session.dropOutsideWindow(alloc, alloc, &history);
    try std.testing.expect(prompts[0].droppedFromSession());
    try std.testing.expect(unstored[0].droppedFromSession());
    try std.testing.expectEqualSlices(u8, &session_codec.imageNameOf(&unstored_bytes), &unstored[0].name.?);
    try std.testing.expect(prompts[1].droppedFromSession());
    try std.testing.expect(!tools[0][0].droppedFromSession() and tools[0][0].data.len > 0);
    try std.testing.expect(!tools[1][0].droppedFromSession() and tools[1][0].data.len > 0);
}

test "an open needs the newest tool images its window keeps, and every one of the open turn" {
    const alloc = std.testing.allocator;
    var staged: session_codec.StagedImages = .{};
    defer staged.deinit(alloc);
    var resolver: session_codec.ImageResolver = .{ .alloc = alloc, .staged = &staged };
    defer resolver.deinit();

    var names: [3]session_codec.ImageName = undefined;
    var images: [3][1]types.ToolImage = undefined;
    for (&names, &images, 0..) |*name, *image, index| {
        name.* = session_codec.imageNameOf(&.{@as(u8, @intCast(index))});
        image.* = .{.{ .data = @constCast(&[_]u8{}), .mime_type = @constCast("image/png"), .name = name.* }};
        try resolver.missing.put(alloc, name.*, 10);
    }
    var results: [3][1]types.PersistedToolResult = undefined;
    var steps: [3][1]types.ToolExecutionStep = undefined;
    var history: [2]types.HistoryTurn = undefined;
    for (&history, 0..) |*turn, index| {
        turn.* = .{ .assistant = .{ .user = .{ .text = @constCast("look") }, .assistant = @constCast("ok"), .execution = windowTestToolStep(&results[index], &steps[index], &images[index]) } };
    }
    const open_execution = windowTestToolStep(&results[2], &steps[2], &images[2]);

    try keepNeededImages(alloc, &resolver, &history, null, open_execution, &.{}, .{ .max_images = 1 });
    try std.testing.expectEqual(@as(usize, 2), resolver.missing.count());
    try std.testing.expect(!resolver.missing.contains(names[0]));
    try std.testing.expect(resolver.missing.contains(names[1]) and resolver.missing.contains(names[2]));
}

test "an open needs the images of a result its open turn recorded before a crash" {
    const alloc = std.testing.allocator;
    var staged: session_codec.StagedImages = .{};
    defer staged.deinit(alloc);
    var resolver: session_codec.ImageResolver = .{ .alloc = alloc, .staged = &staged };
    defer resolver.deinit();
    const name = session_codec.imageNameOf("recorded shot");
    try resolver.missing.put(alloc, name, 13);
    var images = [_]types.ToolImage{.{ .data = @constCast(&[_]u8{}), .mime_type = @constCast("image/png"), .name = name }};
    const finished = [_]journal.Finished{.{ .id = @constCast("call-1"), .failed = false, .output = @constCast("took it"), .images = &images }};

    try keepNeededImages(alloc, &resolver, &.{}, null, null, &finished, .{ .max_images = 1 });
    try std.testing.expectEqual(@as(usize, 1), resolver.missing.count());
    try std.testing.expectEqual(@as(?usize, 13), resolver.missing.get(name));
}

test "an open needs only the named images its window keeps, and every image of the open turn" {
    const alloc = std.testing.allocator;
    var staged: session_codec.StagedImages = .{};
    defer staged.deinit(alloc);
    var resolver: session_codec.ImageResolver = .{ .alloc = alloc, .staged = &staged };
    defer resolver.deinit();

    var names: [4]session_codec.ImageName = undefined;
    var images: [4]types.ImageAttachment = undefined;
    for (&names, &images, 0..) |*name, *image, index| {
        name.* = session_codec.imageNameOf(&.{@as(u8, @intCast(index))});
        image.* = .{ .id = index + 1, .path = @constCast("inline://image"), .media_type = @constCast("image/png"), .snapshot_sha256 = name };
    }
    const reset = struct {
        fn run(target: *session_codec.ImageResolver, all: []const session_codec.ImageName) !void {
            target.missing.clearRetainingCapacity();
            for (all) |name| try target.missing.put(target.alloc, name, 10);
        }
    }.run;
    var history: [3]types.HistoryTurn = undefined;
    for (&history, images[0..3]) |*turn, *image| {
        turn.* = .{ .assistant = .{ .user = .{ .text = @constCast("look"), .images = image[0..1] }, .assistant = @constCast("ok") } };
    }

    try reset(&resolver, &names);
    try keepNeededImages(alloc, &resolver, &history, .{ .text = @constCast("now"), .images = images[3..4] }, null, &.{}, .{ .max_images = 2 });
    try std.testing.expectEqual(@as(usize, 3), resolver.missing.count());
    try std.testing.expect(!resolver.missing.contains(names[0]));

    try reset(&resolver, &names);
    try keepNeededImages(alloc, &resolver, history[0..2], .{ .text = @constCast("now"), .images = images[2..4] }, null, &.{}, .{ .max_images = 1 });
    try std.testing.expectEqual(@as(usize, 3), resolver.missing.count());
    try std.testing.expect(!resolver.missing.contains(names[0]));
}
