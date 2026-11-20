const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const tool_call_ids = @import("tool_call_ids.zig");
const sse = @import("sse.zig");
const codec = @import("chat_completions_protocol.zig");

const Allocator = std.mem.Allocator;

pub const Limits = codec.Limits;
pub const Options = codec.Options;
pub const default_max_output_tokens = 4096;
pub const api_version = "2023-06-01";

pub fn build_request(alloc: Allocator, input: stream_provider.RequestData, options: Options) ![]u8 {
    try codec.validate_request(input);
    for (input.messages) |message| if (message.images.len != 0) return error.UnsupportedVision;
    try codec.validate_history(alloc, input.messages);
    var functions = try codec.select_functions(alloc, input.tools, input.tool_choice);
    defer functions.deinit(alloc);
    var projection = tool_call_ids.Projection.init(alloc, input.messages) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolCallId,
    };
    defer projection.deinit(alloc);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    write_request(&out.writer, alloc, input, options, functions.items, &projection) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |failure| return failure,
    };
    return out.toOwnedSlice();
}

fn write_request(
    writer: *std.Io.Writer,
    alloc: Allocator,
    request: stream_provider.RequestData,
    options: Options,
    functions: []const codec.Function,
    projection: *const tool_call_ids.Projection,
) !void {
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.print(",\"max_tokens\":{d},\"stream\":{}", .{ request.max_output_tokens orelse default_max_output_tokens, request.streaming });
    try write_system(writer, request.instructions);
    try writer.writeAll(",\"messages\":[");
    var encoder: MessageEncoder = .{ .alloc = alloc, .writer = writer, .projection = projection };
    for (request.messages) |message| try encoder.message(message);
    try encoder.close_results();
    try writer.writeByte(']');
    if (functions.len != 0) {
        try write_tools(writer, alloc, functions);
        if (options.tool_choice_mode == .send) try write_tool_choice(writer, request.tool_choice);
    }
    try writer.writeByte('}');
}

fn write_system(writer: *std.Io.Writer, instructions: []const types.ChatMessage) !void {
    var count: usize = 0;
    for (instructions) |message| {
        const text = message.content orelse continue;
        if (text.len == 0) continue;
        try writer.writeAll(if (count == 0) ",\"system\":[" else ",");
        count += 1;
        try write_text_block(writer, text);
    }
    if (count != 0) try writer.writeByte(']');
}

fn write_tools(writer: *std.Io.Writer, alloc: Allocator, functions: []const codec.Function) !void {
    try writer.writeAll(",\"tools\":[");
    for (functions, 0..) |function, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try std.json.Stringify.value(function.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try model_tool_schema.writeCappedDescriptionJsonString(alloc, writer, function.description);
        try writer.writeAll(",\"input_schema\":");
        switch (function.schema) {
            .builtin => |schema| try model_tool_schema.writeObjectSchema(alloc, writer, schema),
            .dynamic => |schema| try std.json.Stringify.value(schema, .{}, writer),
        }
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn write_tool_choice(writer: *std.Io.Writer, choice: types.ToolChoice) !void {
    const kind = switch (choice) {
        .auto => "auto",
        .required => "any",
        .none => return,
    };
    try writer.print(",\"tool_choice\":{{\"type\":\"{s}\"}}", .{kind});
}

fn write_text_block(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeAll("{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(text, .{}, writer);
    try writer.writeByte('}');
}

fn write_input(writer: *std.Io.Writer, alloc: Allocator, arguments_json: []const u8) !void {
    if (arguments_json.len == 0) return writer.writeAll("{}");
    try codec.check_json_depth(arguments_json);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments_json, .{}) catch return error.InvalidToolArguments;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToolArguments;
    try writer.writeAll(arguments_json);
}

const MessageEncoder = struct {
    alloc: Allocator,
    writer: *std.Io.Writer,
    projection: *const tool_call_ids.Projection,
    count: usize = 0,
    results_open: bool = false,

    fn message(self: *MessageEncoder, source: types.ChatMessage) !void {
        if (source.role == .tool) return self.tool_result(source);
        const text = source.content orelse "";
        if (source.role == .assistant and text.len == 0 and source.tool_calls.len == 0) return;
        try self.close_results();
        try self.begin();
        if (source.role != .assistant) {
            try self.writer.writeAll("{\"role\":\"user\",\"content\":");
            try std.json.Stringify.value(text, .{}, self.writer);
            try self.writer.writeByte('}');
            return;
        }
        try self.writer.writeAll("{\"role\":\"assistant\",\"content\":[");
        var blocks: usize = 0;
        if (text.len != 0) {
            try write_text_block(self.writer, text);
            blocks += 1;
        }
        for (source.tool_calls) |call| {
            if (blocks != 0) try self.writer.writeByte(',');
            blocks += 1;
            try self.tool_use(call);
        }
        try self.writer.writeAll("]}");
    }

    fn tool_use(self: *MessageEncoder, call: types.ToolCall) !void {
        try self.writer.writeAll("{\"type\":\"tool_use\",\"id\":");
        try std.json.Stringify.value(self.projection.resolve(call.id), .{}, self.writer);
        try self.writer.writeAll(",\"name\":");
        try std.json.Stringify.value(call.name, .{}, self.writer);
        try self.writer.writeAll(",\"input\":");
        try write_input(self.writer, self.alloc, call.arguments_json);
        try self.writer.writeByte('}');
    }

    fn tool_result(self: *MessageEncoder, source: types.ChatMessage) !void {
        const call_id = source.tool_call_id orelse return error.InvalidToolHistory;
        if (self.results_open) {
            try self.writer.writeByte(',');
        } else {
            try self.begin();
            try self.writer.writeAll("{\"role\":\"user\",\"content\":[");
            self.results_open = true;
        }
        try self.writer.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
        try std.json.Stringify.value(self.projection.resolve(call_id), .{}, self.writer);
        try self.writer.writeAll(",\"content\":");
        try std.json.Stringify.value(source.content orelse "", .{}, self.writer);
        if (source.tool_result_status == .failure) try self.writer.writeAll(",\"is_error\":true");
        try self.writer.writeByte('}');
    }

    fn begin(self: *MessageEncoder) !void {
        if (self.count != 0) try self.writer.writeByte(',');
        self.count += 1;
    }

    fn close_results(self: *MessageEncoder) !void {
        if (!self.results_open) return;
        try self.writer.writeAll("]}");
        self.results_open = false;
    }
};

pub fn consume_stream(
    alloc: Allocator,
    source: *std.Io.Reader,
    request: stream_provider.RequestData,
    limits: Limits,
    events: ?stream_provider.EventSink,
    cancel_flag: *const std.atomic.Value(bool),
    progress: ?sse.Progress,
) !stream_provider.Result {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    var reducer = Reducer.init(alloc, request, limits);
    defer reducer.deinit();
    var framing = sse.Reader{ .max_event_bytes = limits.event_bytes, .progress = progress };
    defer framing.deinit(alloc);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    while (true) {
        const remaining = limits.total_wire_bytes - framing.total_bytes;
        const event_limited = limits.event_bytes < remaining;
        framing.max_total_bytes = framing.total_bytes + @min(limits.event_bytes, remaining);
        const data = framing.next(alloc, source, cancel_flag) catch |err| switch (err) {
            error.StreamTooLarge => return if (event_limited) error.EventTooLarge else error.StreamTooLarge,
            else => return err,
        };
        const chunk = data orelse return error.IncompleteStream;
        _ = arena.reset(.retain_capacity);
        const delta = try reducer.accept(arena.allocator(), chunk);
        if (events) |sink| try emit(sink, delta, cancel_flag);
        if (reducer.phase == .done) {
            if (cancel_flag.load(.seq_cst)) return error.Cancelled;
            return reducer.finish();
        }
    }
}

pub fn consume_message(alloc: Allocator, body: []const u8, request: stream_provider.RequestData) !stream_provider.Result {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{}) catch return error.MalformedMessagesEvent;
    const kind = string_field(root, "type") orelse return error.MalformedMessagesEvent;
    if (std.mem.eql(u8, kind, "error")) return error.ProviderError;
    if (!std.mem.eql(u8, kind, "message")) return error.MalformedMessagesEvent;
    var reducer = Reducer.init(alloc, request, .{});
    defer reducer.deinit();
    reducer.started = true;
    if (string_field(root, "id")) |id| reducer.message_id = try alloc.dupe(u8, id);
    if (field(root, "usage")) |usage| reducer.read_usage(usage);
    const content = field(root, "content") orelse return error.MalformedMessagesEvent;
    if (content != .array) return error.MalformedMessagesEvent;
    for (content.array.items) |part| {
        const part_type = string_field(part, "type") orelse return error.MalformedMessagesEvent;
        if (std.mem.eql(u8, part_type, "text")) {
            try reducer.append_content(string_field(part, "text") orelse return error.MalformedMessagesEvent);
        } else if (std.mem.eql(u8, part_type, "tool_use")) {
            try reducer.append_tool_block(part);
        }
    }
    const raw = string_field(root, "stop_reason") orelse return error.IncompleteStream;
    reducer.stop = .{ .reason = try map_stop_reason(raw), .raw = types.ProviderFinishRaw.init(raw) };
    reducer.phase = .done;
    return reducer.finish();
}

const Started = struct { id: []const u8, name: []const u8 };

const Delta = struct {
    content: ?[]const u8 = null,
    tool_started: ?Started = null,
    tool_input: ?[]const u8 = null,
};

fn emit(sink: stream_provider.EventSink, delta: Delta, cancel_flag: *const std.atomic.Value(bool)) !void {
    if (delta.content) |text| {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        sink.emit(.{ .content_delta = text });
    }
    if (delta.tool_started) |started| sink.emit(.{ .tool_started = .{ .id = started.id, .name = started.name } });
    if (delta.tool_input) |text| sink.emit(.{ .tool_input_delta = text });
}

const Block = struct {
    kind: enum { text, tool, other } = .other,
    stopped: bool = false,
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *Block, alloc: Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
    }
};

const Stop = struct {
    reason: types.ProviderFinishReason,
    raw: types.ProviderFinishRaw,
};

const Reducer = struct {
    alloc: Allocator,
    choice: types.ToolChoice,
    limits: Limits,
    phase: enum { running, done, closed } = .running,
    started: bool = false,
    events: usize = 0,
    message_id: ?[]u8 = null,
    content: std.ArrayList(u8) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    tool_blocks: usize = 0,
    stop: ?Stop = null,
    usage: types.Usage = .{},

    fn init(alloc: Allocator, request: stream_provider.RequestData, limits: Limits) Reducer {
        return .{ .alloc = alloc, .choice = request.tool_choice, .limits = limits };
    }

    fn deinit(self: *Reducer) void {
        if (self.message_id) |id| self.alloc.free(id);
        self.content.deinit(self.alloc);
        for (self.blocks.items) |*block| block.deinit(self.alloc);
        self.blocks.deinit(self.alloc);
    }

    fn accept(self: *Reducer, arena: Allocator, chunk: []const u8) !Delta {
        if (self.phase != .running) return error.StreamClosed;
        self.events += 1;
        if (self.events > self.limits.events) return error.TooManyEvents;
        const root = std.json.parseFromSliceLeaky(std.json.Value, arena, chunk, .{}) catch return error.MalformedMessagesEvent;
        const kind = string_field(root, "type") orelse return error.MalformedMessagesEvent;
        if (std.mem.eql(u8, kind, "message_start")) return self.message_start(root);
        if (std.mem.eql(u8, kind, "content_block_start")) return self.block_start(root);
        if (std.mem.eql(u8, kind, "content_block_delta")) return self.block_delta(root);
        if (std.mem.eql(u8, kind, "content_block_stop")) return self.block_stop(root);
        if (std.mem.eql(u8, kind, "message_delta")) return self.message_delta(root);
        if (std.mem.eql(u8, kind, "message_stop")) return self.message_stop();
        if (std.mem.eql(u8, kind, "ping")) return .{};
        if (std.mem.eql(u8, kind, "error")) return error.ProviderError;
        return error.MalformedMessagesEvent;
    }

    fn message_start(self: *Reducer, root: std.json.Value) !Delta {
        if (self.started) return error.MalformedMessagesEvent;
        const message = field(root, "message") orelse return error.MalformedMessagesEvent;
        self.started = true;
        if (string_field(message, "id")) |id| self.message_id = try self.alloc.dupe(u8, id);
        if (field(message, "usage")) |usage| self.read_usage(usage);
        return .{};
    }

    fn block_start(self: *Reducer, root: std.json.Value) !Delta {
        if (!self.started or self.stop != null) return error.MalformedMessagesEvent;
        if (self.blocks.items.len != 0 and !self.blocks.items[self.blocks.items.len - 1].stopped) return error.MalformedMessagesEvent;
        const index = index_field(root, "index") orelse return error.MalformedMessagesEvent;
        if (index != self.blocks.items.len) return error.MalformedMessagesEvent;
        const content_block = field(root, "content_block") orelse return error.MalformedMessagesEvent;
        const block_type = string_field(content_block, "type") orelse return error.MalformedMessagesEvent;
        var block: Block = .{};
        errdefer block.deinit(self.alloc);
        var delta: Delta = .{};
        if (std.mem.eql(u8, block_type, "text")) {
            block.kind = .text;
            if (string_field(content_block, "text")) |text| {
                if (text.len != 0) {
                    try self.append_content(text);
                    delta.content = text;
                }
            }
        } else if (std.mem.eql(u8, block_type, "tool_use")) {
            block.kind = .tool;
            const id = string_field(content_block, "id") orelse return error.MalformedMessagesEvent;
            const name = string_field(content_block, "name") orelse return error.MalformedMessagesEvent;
            try codec.validate_name(name);
            if (self.tool_blocks >= self.limits.tool_calls) return error.TooManyTools;
            try block.id.appendSlice(self.alloc, id);
            try block.name.appendSlice(self.alloc, name);
            self.tool_blocks += 1;
            delta.tool_started = .{ .id = id, .name = name };
        }
        try self.blocks.append(self.alloc, block);
        return delta;
    }

    fn block_delta(self: *Reducer, root: std.json.Value) !Delta {
        const index = index_field(root, "index") orelse return error.MalformedMessagesEvent;
        if (self.blocks.items.len == 0 or index != self.blocks.items.len - 1) return error.MalformedMessagesEvent;
        const block = &self.blocks.items[index];
        if (block.stopped) return error.MalformedMessagesEvent;
        const delta_value = field(root, "delta") orelse return error.MalformedMessagesEvent;
        const delta_type = string_field(delta_value, "type") orelse return error.MalformedMessagesEvent;
        if (std.mem.eql(u8, delta_type, "text_delta")) {
            if (block.kind != .text) return error.MalformedMessagesEvent;
            const text = string_field(delta_value, "text") orelse return error.MalformedMessagesEvent;
            try self.append_content(text);
            return .{ .content = text };
        }
        if (std.mem.eql(u8, delta_type, "input_json_delta")) {
            if (block.kind != .tool) return error.MalformedMessagesEvent;
            const partial = string_field(delta_value, "partial_json") orelse return error.MalformedMessagesEvent;
            if (block.arguments.items.len + partial.len > self.limits.arguments_bytes) return error.ArgumentsTooLarge;
            try block.arguments.appendSlice(self.alloc, partial);
            return .{ .tool_input = partial };
        }
        if (std.mem.eql(u8, delta_type, "thinking_delta") or std.mem.eql(u8, delta_type, "signature_delta")) return .{};
        return error.MalformedMessagesEvent;
    }

    fn block_stop(self: *Reducer, root: std.json.Value) !Delta {
        const index = index_field(root, "index") orelse return error.MalformedMessagesEvent;
        if (self.blocks.items.len == 0 or index != self.blocks.items.len - 1) return error.MalformedMessagesEvent;
        const block = &self.blocks.items[index];
        if (block.stopped) return error.MalformedMessagesEvent;
        block.stopped = true;
        return .{};
    }

    fn message_delta(self: *Reducer, root: std.json.Value) !Delta {
        if (!self.started or self.stop != null) return error.MalformedMessagesEvent;
        if (field(root, "usage")) |usage| self.read_usage(usage);
        const delta_value = field(root, "delta") orelse return error.MalformedMessagesEvent;
        const raw = string_field(delta_value, "stop_reason") orelse return .{};
        self.stop = .{ .reason = try map_stop_reason(raw), .raw = types.ProviderFinishRaw.init(raw) };
        return .{};
    }

    fn message_stop(self: *Reducer) !Delta {
        if (!self.started) return error.MalformedMessagesEvent;
        for (self.blocks.items) |block| if (!block.stopped) return error.MalformedMessagesEvent;
        self.phase = .done;
        return .{};
    }

    fn read_usage(self: *Reducer, usage: std.json.Value) void {
        if (count_field(usage, "input_tokens")) |n| self.usage.input_tokens = n;
        if (count_field(usage, "output_tokens")) |n| self.usage.output_tokens = n;
        if (count_field(usage, "cache_read_input_tokens")) |n| self.usage.cache_read_tokens = n;
        if (count_field(usage, "cache_creation_input_tokens")) |n| self.usage.cache_write_tokens = n;
    }

    fn append_tool_block(self: *Reducer, part: std.json.Value) !void {
        const id = string_field(part, "id") orelse return error.MalformedMessagesEvent;
        const name = string_field(part, "name") orelse return error.MalformedMessagesEvent;
        const input = field(part, "input") orelse return error.MalformedMessagesEvent;
        if (input != .object) return error.InvalidToolArguments;
        try codec.validate_name(name);
        if (self.tool_blocks >= self.limits.tool_calls) return error.TooManyTools;
        var block: Block = .{ .kind = .tool, .stopped = true };
        errdefer block.deinit(self.alloc);
        try block.id.appendSlice(self.alloc, id);
        try block.name.appendSlice(self.alloc, name);
        var encoded: std.Io.Writer.Allocating = .init(self.alloc);
        defer encoded.deinit();
        try std.json.Stringify.value(input, .{}, &encoded.writer);
        if (encoded.written().len > self.limits.arguments_bytes) return error.ArgumentsTooLarge;
        try block.arguments.appendSlice(self.alloc, encoded.written());
        try self.blocks.append(self.alloc, block);
        self.tool_blocks += 1;
    }

    fn append_content(self: *Reducer, text: []const u8) !void {
        if (self.content.items.len + text.len > self.limits.content_bytes) return error.ContentTooLarge;
        try self.content.appendSlice(self.alloc, text);
    }

    fn finish(self: *Reducer) !stream_provider.Result {
        errdefer self.phase = .closed;
        if (self.phase != .done) return error.IncompleteStream;
        const stop = self.stop orelse return error.IncompleteStream;
        switch (stop.reason) {
            .stop, .tool_calls, .length => {},
            .content_filter => return error.ContentFiltered,
            else => return error.InvalidFinishReason,
        }
        if (stop.reason != .length) {
            if ((stop.reason == .tool_calls) != (self.tool_blocks != 0)) return error.InconsistentFinishReason;
            if (self.choice == .required and self.tool_blocks == 0) return error.RequiredToolMissing;
        }
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        for (self.blocks.items) |block| {
            if (block.kind != .tool) continue;
            try codec.validate_name(block.name.items);
            if (block.arguments.items.len == 0) continue;
            try codec.check_json_depth(block.arguments.items);
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), block.arguments.items, .{}) catch return error.InvalidToolArguments;
            if (parsed != .object) return error.InvalidToolArguments;
        }
        var calls: std.ArrayList(types.ToolCall) = .empty;
        errdefer {
            for (calls.items) |call| {
                self.alloc.free(call.id);
                self.alloc.free(call.name);
                self.alloc.free(call.arguments_json);
            }
            calls.deinit(self.alloc);
        }
        for (self.blocks.items) |*block| {
            if (block.kind != .tool) continue;
            const id = try block.id.toOwnedSlice(self.alloc);
            errdefer self.alloc.free(id);
            const name = try block.name.toOwnedSlice(self.alloc);
            errdefer self.alloc.free(name);
            const arguments = if (block.arguments.items.len == 0)
                try self.alloc.dupe(u8, "{}")
            else
                try block.arguments.toOwnedSlice(self.alloc);
            errdefer self.alloc.free(arguments);
            try calls.append(self.alloc, .{ .id = id, .name = name, .arguments_json = arguments });
        }
        const content = if (self.content.items.len != 0) try self.content.toOwnedSlice(self.alloc) else null;
        errdefer if (content) |text| self.alloc.free(text);
        const generation_id = self.message_id;
        self.message_id = null;
        errdefer if (generation_id) |id| self.alloc.free(id);
        const owned_calls = try calls.toOwnedSlice(self.alloc);
        self.phase = .closed;
        return .{ .completed = .{
            .completion = .{
                .content = content,
                .tool_calls = owned_calls,
                .generation_id = generation_id,
                .finish_reason = stop.reason,
                .finish_reason_raw = stop.raw,
                .usage = self.usage,
            },
            .ownership = .owned,
        } };
    }
};

fn map_stop_reason(raw: []const u8) !types.ProviderFinishReason {
    if (std.mem.eql(u8, raw, "end_turn") or std.mem.eql(u8, raw, "stop_sequence")) return .stop;
    if (std.mem.eql(u8, raw, "max_tokens")) return .length;
    if (std.mem.eql(u8, raw, "tool_use")) return .tool_calls;
    if (std.mem.eql(u8, raw, "refusal")) return error.Refused;
    return .other;
}

fn field(value: std.json.Value, name: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(name);
}

fn string_field(value: std.json.Value, name: []const u8) ?[]const u8 {
    const found = field(value, name) orelse return null;
    return if (found == .string) found.string else null;
}

fn count_field(value: std.json.Value, name: []const u8) ?u64 {
    const found = field(value, name) orelse return null;
    if (found != .integer or found.integer < 0) return null;
    return @intCast(found.integer);
}

fn index_field(value: std.json.Value, name: []const u8) ?usize {
    const number = count_field(value, name) orelse return null;
    return std.math.cast(usize, number);
}

const test_functions = [_]model_tool_schema.FunctionSchema{.{ .name = "read_file", .description = "Read a file.", .input_schema = .{
    .properties = &.{.{ .name = "path", .json_type = .string }},
    .required = &.{"path"},
    .additional_properties = false,
} }};

fn test_request() stream_provider.RequestData {
    return .{
        .model = "claude-test",
        .instructions = &.{ .{ .role = .system, .content = "be brief" }, .{ .role = .system, .content = "use tools" } },
        .messages = &.{.{ .role = .user, .content = "read a.txt" }},
        .tool_choice = .auto,
        .provider_options = .{},
    };
}

test "gateway.messages_protocol.test.request encodes system, tools, tool_use and merged tool_result blocks" {
    const alloc = std.testing.allocator;
    const calls = [_]types.ToolCall{
        .{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"a.txt\"}" },
        .{ .id = "call_2", .name = "read_file", .arguments_json = "{\"path\":\"b.txt\"}" },
    };
    const history = [_]types.ChatMessage{
        .{ .role = .user, .content = "read a.txt" },
        .{ .role = .assistant, .content = "Reading.", .tool_calls = &calls },
        .{ .role = .tool, .content = "hello", .tool_call_id = "call_1", .tool_result_status = .success },
        .{ .role = .tool, .content = "missing", .tool_call_id = "call_2", .tool_result_status = .failure },
    };
    var request = test_request();
    request.messages = &history;
    request.tools = .{ .advertised_names = &.{"read_file"}, .advertised_functions = &test_functions };
    request.tool_choice = .required;
    const body = try build_request(alloc, request, .{ .tool_choice_mode = .send });
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("claude-test", root.get("model").?.string);
    try std.testing.expectEqual(@as(i64, default_max_output_tokens), root.get("max_tokens").?.integer);
    try std.testing.expect(root.get("stream").?.bool);
    const system = root.get("system").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), system.len);
    try std.testing.expectEqualStrings("use tools", system[1].object.get("text").?.string);
    const messages = root.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    const assistant = messages[1].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("text", assistant[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("tool_use", assistant[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", assistant[1].object.get("id").?.string);
    try std.testing.expectEqualStrings("a.txt", assistant[1].object.get("input").?.object.get("path").?.string);
    const results = messages[2].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("tool_result", results[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", results[0].object.get("tool_use_id").?.string);
    try std.testing.expect(results[1].object.get("is_error").?.bool);
    const tools = root.get("tools").?.array.items;
    try std.testing.expectEqualStrings("read_file", tools[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("object", tools[0].object.get("input_schema").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("any", root.get("tool_choice").?.object.get("type").?.string);
}

const Collector = struct {
    text: std.ArrayList(u8) = .empty,
    input: std.ArrayList(u8) = .empty,
    tool_started: usize = 0,

    fn sink(self: *Collector) stream_provider.EventSink {
        return .{ .context = self, .emit_fn = on_event };
    }

    fn on_event(raw: *anyopaque, event: stream_provider.Event) void {
        const self: *Collector = @ptrCast(@alignCast(raw));
        switch (event) {
            .content_delta => |text| self.text.appendSlice(std.testing.allocator, text) catch unreachable,
            .tool_input_delta => |text| self.input.appendSlice(std.testing.allocator, text) catch unreachable,
            .tool_started => self.tool_started += 1,
            .reasoning_delta => {},
        }
    }

    fn deinit(self: *Collector) void {
        self.text.deinit(std.testing.allocator);
        self.input.deinit(std.testing.allocator);
    }
};

test "gateway.messages_protocol.test.stream yields text deltas and a completed end_turn result" {
    const alloc = std.testing.allocator;
    const wire =
        \\data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":12,"output_tokens":1}}}
        \\
        \\data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
        \\
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}
        \\
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}
        \\
        \\data: {"type":"content_block_stop","index":0}
        \\
        \\data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":2}}
        \\
        \\data: {"type":"message_stop"}
        \\
        \\
    ;
    var source = std.Io.Reader.fixed(wire);
    var collector: Collector = .{};
    defer collector.deinit();
    var cancelled = std.atomic.Value(bool).init(false);
    var result = try consume_stream(alloc, &source, test_request(), .{}, collector.sink(), &cancelled, null);
    defer result.deinit(alloc);
    const completion = result.completed.completion;
    try std.testing.expectEqualStrings("Hello", completion.content.?);
    try std.testing.expectEqualStrings("Hello", collector.text.items);
    try std.testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
    try std.testing.expectEqualStrings("msg_1", completion.generation_id.?);
    try std.testing.expectEqual(@as(?u64, 12), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 2), completion.usage.output_tokens);
    try std.testing.expectEqual(@as(usize, 0), completion.tool_calls.len);
}

test "gateway.messages_protocol.test.stream assembles tool_use input_json_delta into a tool call" {
    const alloc = std.testing.allocator;
    const wire =
        \\data: {"type":"message_start","message":{"id":"msg_2","usage":{"input_tokens":20,"output_tokens":1}}}
        \\
        \\data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
        \\
        \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Reading."}}
        \\
        \\data: {"type":"content_block_stop","index":0}
        \\
        \\data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_file","input":{}}}
        \\
        \\data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"pa"}}
        \\
        \\data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"th\":\"a.txt\"}"}}
        \\
        \\data: {"type":"content_block_stop","index":1}
        \\
        \\data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":9}}
        \\
        \\data: {"type":"message_stop"}
        \\
        \\
    ;
    var source = std.Io.Reader.fixed(wire);
    var collector: Collector = .{};
    defer collector.deinit();
    var cancelled = std.atomic.Value(bool).init(false);
    var result = try consume_stream(alloc, &source, test_request(), .{}, collector.sink(), &cancelled, null);
    defer result.deinit(alloc);
    const completion = result.completed.completion;
    try std.testing.expectEqualStrings("Reading.", completion.content.?);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("toolu_1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(usize, 1), collector.tool_started);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", collector.input.items);
    try std.testing.expectEqual(@as(?u64, 9), completion.usage.output_tokens);
}

test "gateway.messages_protocol.test.stream maps an error event to a provider failure" {
    const alloc = std.testing.allocator;
    const wire = "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"busy\"}}\n\n";
    var source = std.Io.Reader.fixed(wire);
    var cancelled = std.atomic.Value(bool).init(false);
    try std.testing.expectError(error.ProviderError, consume_stream(alloc, &source, test_request(), .{}, null, &cancelled, null));
}

test "gateway.messages_protocol.test.request sends stream false for a non-streaming request" {
    const alloc = std.testing.allocator;
    var request = test_request();
    request.streaming = false;
    const body = try build_request(alloc, request, .{});
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("stream").?.bool);
}

test "gateway.messages_protocol.test.message response decodes text and tool_use into a completed result" {
    const alloc = std.testing.allocator;
    const wire = "{\"id\":\"msg_9\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-test\",\"content\":[{\"type\":\"text\",\"text\":\"Reading.\"},{\"type\":\"tool_use\",\"id\":\"toolu_9\",\"name\":\"read_file\",\"input\":{\"path\":\"a.txt\"}}],\"stop_reason\":\"tool_use\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":30,\"output_tokens\":12,\"cache_read_input_tokens\":4}}";
    var request = test_request();
    request.tools = .{ .advertised_names = &.{"read_file"}, .advertised_functions = &test_functions };
    var result = try consume_message(alloc, wire, request);
    defer result.deinit(alloc);
    const completion = result.completed.completion;
    try std.testing.expectEqualStrings("Reading.", completion.content.?);
    try std.testing.expectEqualStrings("msg_9", completion.generation_id.?);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("toolu_9", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(?u64, 30), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 12), completion.usage.output_tokens);
    try std.testing.expectEqual(@as(?u64, 4), completion.usage.cache_read_tokens);
}

test "gateway.messages_protocol.test.message response maps error bodies and unusable stop reasons" {
    const alloc = std.testing.allocator;
    const error_body = "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"busy\"}}";
    try std.testing.expectError(error.ProviderError, consume_message(alloc, error_body, test_request()));
    const refusal = "{\"id\":\"msg_r\",\"type\":\"message\",\"content\":[],\"stop_reason\":\"refusal\",\"usage\":{}}";
    try std.testing.expectError(error.Refused, consume_message(alloc, refusal, test_request()));
    const unfinished = "{\"id\":\"msg_u\",\"type\":\"message\",\"content\":[{\"type\":\"text\",\"text\":\"x\"}],\"stop_reason\":null,\"usage\":{}}";
    try std.testing.expectError(error.IncompleteStream, consume_message(alloc, unfinished, test_request()));
}
