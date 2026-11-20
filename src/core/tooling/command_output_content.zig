const std = @import("std");
const display_width = @import("../shared/display_width.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const CanonicalizeError = error{OutOfMemory};

pub const Stream = enum {
    stdout,
    stderr,
};

pub const Callback = *const fn (
    ctx: *anyopaque,
    lifecycle_id: ?types.ToolLifecycleId,
    stream: Stream,
    chunk: []const u8,
) anyerror!void;

pub const max_foreground_result_envelope_bytes: usize =
    "exit_code=-9223372036854775808\n".len +
    "<stdout>\n".len + "\n</stdout>\n".len +
    "<stderr>\n".len + "\n</stderr>\n".len;

const EscapeState = enum {
    none,
    escape,
    csi,
    osc,
    osc_escape,
};

const TransformKind = enum {
    byte_escape,
    c1_escape,
    escape_byte,
    bare_cr,
};

const TransformEvent = struct {
    visible_offset: usize,
    kind: TransformKind,
    byte: u8,
};

pub const Decoder = struct {
    utf8_pending: [4]u8 = undefined,
    utf8_pending_len: usize = 0,
    pending_cr: bool = false,
    escape_state: EscapeState = .none,
    escape_bytes: [64]u8 = undefined,
    escape_len: usize = 0,
    escape_overflow: bool = false,

    pub fn append(self: *Decoder, raw: []const u8, sink: anytype) !void {
        var index: usize = 0;
        while (index < raw.len) : (index += 1) {
            try self.consumeByte(raw[index], sink);
        }
    }

    pub fn finish(self: *Decoder, sink: anytype) !void {
        self.pending_cr = false;
        try self.flushUtf8(sink, true);
        if (self.escape_state != .none) try self.flushIncompleteEscape(sink);
    }

    pub fn isIdle(self: *const Decoder) bool {
        return self.utf8_pending_len == 0 and
            !self.pending_cr and
            self.escape_state == .none;
    }

    fn consumeByte(self: *Decoder, byte: u8, sink: anytype) !void {
        if (self.escape_state != .none) {
            if (try self.consumeEscapeByte(byte, sink)) return;
        }

        if (self.pending_cr) {
            self.pending_cr = false;
            if (byte == '\n') {
                try self.flushUtf8(sink, true);
                try sink.finishLine();
                return;
            }
            try sink.replaceLine();
            try emitTransformProvenance(sink, .bare_cr, '\r');
        }

        if (byte == 0x1b) {
            try self.flushUtf8(sink, true);
            try emitTransformProvenance(sink, .escape_byte, byte);
            self.startEscape();
            return;
        }
        if (byte == '\r') {
            try self.flushUtf8(sink, true);
            self.pending_cr = true;
            return;
        }
        if (byte == '\n') {
            try self.flushUtf8(sink, true);
            try sink.finishLine();
            return;
        }
        if (byte >= 0x80) {
            try self.appendUtf8Byte(byte, sink);
            return;
        }

        try self.flushUtf8(sink, true);
        if (byte == '\t' or (byte >= 0x20 and byte < 0x7f)) {
            const bytes = [_]u8{byte};
            try sink.appendText(&bytes);
            return;
        }
        try emitEscapedByte(sink, .byte_escape, byte);
    }

    fn appendUtf8Byte(self: *Decoder, byte: u8, sink: anytype) !void {
        if (self.utf8_pending_len == self.utf8_pending.len) {
            try emitEscapedByte(sink, .byte_escape, self.utf8_pending[0]);
            self.shiftUtf8Pending(1);
        }
        self.utf8_pending[self.utf8_pending_len] = byte;
        self.utf8_pending_len += 1;
        try self.flushUtf8(sink, false);
    }

    fn flushUtf8(self: *Decoder, sink: anytype, final: bool) !void {
        while (self.utf8_pending_len > 0) {
            const sequence_len = std.unicode.utf8ByteSequenceLength(
                self.utf8_pending[0],
            ) catch 1;
            if (sequence_len == 1) {
                try emitEscapedByte(sink, .byte_escape, self.utf8_pending[0]);
                self.shiftUtf8Pending(1);
                continue;
            }
            if (self.utf8_pending_len < sequence_len) {
                if (!final) return;
                try emitEscapedByte(sink, .byte_escape, self.utf8_pending[0]);
                self.shiftUtf8Pending(1);
                continue;
            }

            const sequence = self.utf8_pending[0..sequence_len];
            const scalar = display_width.decodeUtf8Sequence(sequence) catch {
                try emitEscapedByte(sink, .byte_escape, self.utf8_pending[0]);
                self.shiftUtf8Pending(1);
                continue;
            };
            if (scalar >= 0x80 and scalar <= 0x9f) {
                for (sequence) |byte| {
                    try emitTransformProvenance(sink, .c1_escape, byte);
                }
                const value: u8 = @intCast(scalar);
                const digits = "0123456789abcdef";
                const escaped = [_]u8{
                    '\\',               'u',                  '{', '0', '0',
                    digits[value >> 4], digits[value & 0x0f], '}',
                };
                try sink.appendText(&escaped);
            } else {
                try sink.appendText(sequence);
            }
            self.shiftUtf8Pending(sequence_len);
        }
    }

    fn shiftUtf8Pending(self: *Decoder, count: usize) void {
        const remaining = self.utf8_pending_len - count;
        if (remaining > 0) {
            @memmove(
                self.utf8_pending[0..remaining],
                self.utf8_pending[count..self.utf8_pending_len],
            );
        }
        self.utf8_pending_len = remaining;
    }

    fn startEscape(self: *Decoder) void {
        self.escape_state = .escape;
        self.escape_len = 0;
        self.escape_overflow = false;
        self.recordEscapeByte(0x1b);
    }

    fn consumeEscapeByte(self: *Decoder, byte: u8, sink: anytype) !bool {
        switch (self.escape_state) {
            .none => unreachable,
            .escape => switch (byte) {
                '[' => {
                    try emitTransformProvenance(sink, .escape_byte, byte);
                    self.recordEscapeByte(byte);
                    self.escape_state = .csi;
                    return true;
                },
                ']' => {
                    try emitTransformProvenance(sink, .escape_byte, byte);
                    self.recordEscapeByte(byte);
                    self.escape_state = .osc;
                    return true;
                },
                else => {
                    if (byte >= 0x40 and byte <= 0x5f) {
                        try emitTransformProvenance(sink, .escape_byte, byte);
                        self.resetEscape();
                        return true;
                    }
                    try self.flushIncompleteEscape(sink);
                    return false;
                },
            },
            .csi => {
                try emitTransformProvenance(sink, .escape_byte, byte);
                self.recordEscapeByte(byte);
                if (byte >= 0x40 and byte <= 0x7e) {
                    self.resetEscape();
                } else if (byte < 0x20 or byte == 0x7f) {
                    try self.flushIncompleteEscape(sink);
                }
                return true;
            },
            .osc => {
                try emitTransformProvenance(sink, .escape_byte, byte);
                self.recordEscapeByte(byte);
                if (byte == 0x07) {
                    self.resetEscape();
                } else if (byte == 0x1b) {
                    self.escape_state = .osc_escape;
                }
                return true;
            },
            .osc_escape => {
                try emitTransformProvenance(sink, .escape_byte, byte);
                self.recordEscapeByte(byte);
                if (byte == '\\') {
                    self.resetEscape();
                } else if (byte != 0x1b) {
                    self.escape_state = .osc;
                }
                return true;
            },
        }
    }

    fn recordEscapeByte(self: *Decoder, byte: u8) void {
        if (self.escape_len < self.escape_bytes.len) {
            self.escape_bytes[self.escape_len] = byte;
            self.escape_len += 1;
        } else {
            self.escape_overflow = true;
        }
    }

    fn flushIncompleteEscape(self: *Decoder, sink: anytype) !void {
        for (self.escape_bytes[0..self.escape_len]) |byte| {
            if (byte < 0x20 or byte == 0x7f) {
                try emitByteEscape(sink, byte);
            } else {
                const bytes = [_]u8{byte};
                try sink.appendText(&bytes);
            }
        }
        if (self.escape_overflow) try sink.appendText("...");
        self.resetEscape();
    }

    fn resetEscape(self: *Decoder) void {
        self.escape_state = .none;
        self.escape_len = 0;
        self.escape_overflow = false;
    }
};

fn emitEscapedByte(sink: anytype, kind: TransformKind, byte: u8) !void {
    try emitTransformProvenance(sink, kind, byte);
    try emitByteEscape(sink, byte);
}

fn emitTransformProvenance(
    sink: anytype,
    kind: TransformKind,
    byte: u8,
) !void {
    const Sink = @TypeOf(sink.*);
    if (comptime @hasDecl(Sink, "recordTransform")) {
        try sink.recordTransform(kind, byte);
    }
}

fn emitByteEscape(sink: anytype, byte: u8) !void {
    const digits = "0123456789abcdef";
    const escaped = [_]u8{
        '\\', 'x', digits[byte >> 4], digits[byte & 0x0f],
    };
    try sink.appendText(&escaped);
}

pub const CanonicalRecord = struct {
    stream: Stream,
    text: std.ArrayList(u8) = .empty,
    transforms: std.ArrayList(TransformEvent) = .empty,
    terminated: bool = false,

    fn deinit(self: *CanonicalRecord, alloc: Allocator) void {
        self.text.deinit(alloc);
        self.transforms.deinit(alloc);
    }
};

pub const CanonicalOutput = struct {
    records: std.ArrayList(CanonicalRecord) = .empty,
    decoders: [2]Decoder = .{ .{}, .{} },
    open_record_indices: [2]?usize = .{ null, null },

    pub fn deinit(self: *CanonicalOutput, alloc: Allocator) void {
        for (self.records.items) |*record| record.deinit(alloc);
        self.records.deinit(alloc);
        self.* = undefined;
    }

    pub fn append(
        self: *CanonicalOutput,
        alloc: Allocator,
        stream: Stream,
        raw: []const u8,
    ) CanonicalizeError!void {
        var sink = CollectorSink{
            .alloc = alloc,
            .output = self,
            .stream = stream,
        };

        if (raw.len > 0) try sink.beginRecord();
        try self.decoders[streamIndex(stream)].append(raw, &sink);
    }

    pub fn finish(
        self: *CanonicalOutput,
        alloc: Allocator,
    ) CanonicalizeError!void {
        inline for ([_]Stream{ .stdout, .stderr }) |stream| {
            var sink = CollectorSink{
                .alloc = alloc,
                .output = self,
                .stream = stream,
            };
            try self.decoders[streamIndex(stream)].finish(&sink);
            const index = streamIndex(stream);
            if (self.open_record_indices[index]) |record_index| {
                const record = self.records.items[record_index];
                if (record.text.items.len == 0 and !record.terminated) {
                    self.removeRecord(alloc, record_index);
                }
            }
            self.open_record_indices[index] = null;
        }
    }

    fn removeRecord(
        self: *CanonicalOutput,
        alloc: Allocator,
        record_index: usize,
    ) void {
        var removed = self.records.orderedRemove(record_index);
        removed.deinit(alloc);
        for (&self.open_record_indices) |*maybe_index| {
            const index = maybe_index.* orelse continue;
            if (index == record_index) {
                maybe_index.* = null;
            } else if (index > record_index) {
                maybe_index.* = index - 1;
            }
        }
    }
};

const CollectorSink = struct {
    alloc: Allocator,
    output: *CanonicalOutput,
    stream: Stream,

    fn beginRecord(self: *CollectorSink) !void {
        _ = try self.ensureOpenRecord();
    }

    fn appendText(self: *CollectorSink, bytes: []const u8) !void {
        const index = try self.ensureOpenRecord();
        try self.output.records.items[index].text.appendSlice(self.alloc, bytes);
    }

    pub fn recordTransform(
        self: *CollectorSink,
        kind: TransformKind,
        byte: u8,
    ) !void {
        const index = try self.ensureOpenRecord();
        const record = &self.output.records.items[index];
        try record.transforms.append(self.alloc, .{
            .visible_offset = record.text.items.len,
            .kind = kind,
            .byte = byte,
        });
    }

    fn finishLine(self: *CollectorSink) !void {
        const stream_index = streamIndex(self.stream);
        const index = try self.ensureOpenRecord();
        self.output.records.items[index].terminated = true;
        self.output.open_record_indices[stream_index] = null;
    }

    fn replaceLine(self: *CollectorSink) !void {
        const index = try self.ensureOpenRecord();
        self.output.records.items[index].text.clearRetainingCapacity();
        self.output.records.items[index].transforms.clearRetainingCapacity();
        self.output.records.items[index].terminated = false;
    }

    fn ensureOpenRecord(self: *CollectorSink) !usize {
        const index = streamIndex(self.stream);
        if (self.output.open_record_indices[index]) |record_index| {
            return record_index;
        }
        try self.output.records.append(self.alloc, .{ .stream = self.stream });
        const record_index = self.output.records.items.len - 1;
        self.output.open_record_indices[index] = record_index;
        return record_index;
    }
};

fn streamIndex(stream: Stream) usize {
    return @backingInt(stream);
}

pub fn eql(lhs: CanonicalOutput, rhs: CanonicalOutput) bool {
    if (lhs.records.items.len != rhs.records.items.len) return false;
    for (lhs.records.items, rhs.records.items) |left, right| {
        if (left.stream != right.stream or
            !std.mem.eql(u8, left.text.items, right.text.items) or
            !transformEventsEqual(left.transforms.items, right.transforms.items)) return false;
    }
    return true;
}

fn transformEventsEqual(
    lhs: []const TransformEvent,
    rhs: []const TransformEvent,
) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (left.visible_offset != right.visible_offset or
            left.kind != right.kind or
            left.byte != right.byte) return false;
    }
    return true;
}

pub fn canonicalizeForegroundResult(
    alloc: Allocator,
    result: []const u8,
) CanonicalizeError!?CanonicalOutput {
    const status_end = std.mem.findScalar(u8, result, '\n') orelse return null;
    if (!validForegroundStatus(result[0..status_end])) return null;

    var remaining = result[status_end + 1 ..];
    var output: CanonicalOutput = .{};
    errdefer output.deinit(alloc);
    if (std.mem.eql(u8, remaining, "(no output)\n")) {
        try output.finish(alloc);
        return output;
    }

    var parsed_any = false;
    for ([_]Stream{ .stdout, .stderr }) |stream| {
        const label = @tagName(stream);
        var open_buf: [16]u8 = undefined;
        const open = std.mem.print(&open_buf, "<{s}>\n", .{label}) catch
            unreachable;
        if (!std.mem.startsWith(u8, remaining, open)) continue;

        var close_buf: [20]u8 = undefined;
        const close = std.mem.print(&close_buf, "\n</{s}>\n", .{label}) catch
            unreachable;
        const body_and_tail = remaining[open.len..];
        const close_start = std.mem.find(u8, body_and_tail, close) orelse {
            output.deinit(alloc);
            return null;
        };
        try output.append(alloc, stream, body_and_tail[0..close_start]);
        remaining = body_and_tail[close_start + close.len ..];
        parsed_any = true;
    }
    if (!parsed_any or remaining.len != 0) {
        output.deinit(alloc);
        return null;
    }
    try output.finish(alloc);
    return output;
}

pub fn validForegroundStatus(status: []const u8) bool {
    if (std.mem.eql(u8, status, "process finished")) return true;
    for ([_][]const u8{ "exit_code=", "signal=" }) |prefix| {
        if (!std.mem.startsWith(u8, status, prefix)) continue;
        _ = std.fmt.parseInt(i64, status[prefix.len..], 10) catch return false;
        return true;
    }
    return false;
}

fn normalizeForTest(alloc: Allocator, chunks: []const []const u8) !CanonicalOutput {
    var output: CanonicalOutput = .{};
    errdefer output.deinit(alloc);
    for (chunks) |chunk| try output.append(alloc, .stdout, chunk);
    try output.finish(alloc);
    return output;
}

fn expectCanonicalEqual(expected: CanonicalOutput, actual: CanonicalOutput) !void {
    try std.testing.expectEqual(expected.records.items.len, actual.records.items.len);
    for (expected.records.items, actual.records.items) |left, right| {
        try std.testing.expectEqual(left.stream, right.stream);
        try std.testing.expectEqualStrings(left.text.items, right.text.items);
        try std.testing.expect(transformEventsEqual(
            left.transforms.items,
            right.transforms.items,
        ));
    }
}

test "command output normalization is chunk independent" {
    const alloc = std.testing.allocator;
    const input = "progress 1\rprogress 2\rDONE\n\n" ++
        "\x1b[31mred\x1b[0m\tutf8:\xe2\x82\xac invalid:\xff literal:\\x0d";

    var expected = try normalizeForTest(alloc, &.{input});
    defer expected.deinit(alloc);

    for (0..input.len + 1) |split| {
        var actual = try normalizeForTest(alloc, &.{ input[0..split], input[split..] });
        defer actual.deinit(alloc);
        try expectCanonicalEqual(expected, actual);
    }

    try std.testing.expectEqual(@as(usize, 3), expected.records.items.len);
    try std.testing.expectEqualStrings("DONE", expected.records.items[0].text.items);
    try std.testing.expectEqualStrings("", expected.records.items[1].text.items);
    try std.testing.expectEqualStrings(
        "red\tutf8:\xe2\x82\xac invalid:\\xff literal:\\x0d",
        expected.records.items[2].text.items,
    );
}

test "canonical output keeps first-record stream order across callbacks" {
    const alloc = std.testing.allocator;
    var output: CanonicalOutput = .{};
    defer output.deinit(alloc);

    try output.append(alloc, .stdout, "A");
    try output.append(alloc, .stderr, "B\n");
    try output.append(alloc, .stdout, "\n");
    try output.finish(alloc);

    try std.testing.expectEqual(@as(usize, 2), output.records.items.len);
    try std.testing.expectEqual(Stream.stdout, output.records.items[0].stream);
    try std.testing.expectEqualStrings("A", output.records.items[0].text.items);
    try std.testing.expectEqual(Stream.stderr, output.records.items[1].stream);
    try std.testing.expectEqualStrings("B", output.records.items[1].text.items);
}

test "pending decoder bytes reserve cross-stream record order" {
    const alloc = std.testing.allocator;
    for ([_][3][]const u8{
        .{ "\xe2", "\x82\xac\n", "€" },
        .{ "\x1b[", "31mred\n", "red" },
    }) |case| {
        var output: CanonicalOutput = .{};
        defer output.deinit(alloc);
        try output.append(alloc, .stdout, case[0]);
        try output.append(alloc, .stderr, "err\n");
        try output.append(alloc, .stdout, case[1]);
        try output.finish(alloc);

        try std.testing.expectEqual(@as(usize, 2), output.records.items.len);
        try std.testing.expectEqual(Stream.stdout, output.records.items[0].stream);
        try std.testing.expectEqualStrings(case[2], output.records.items[0].text.items);
        try std.testing.expectEqual(Stream.stderr, output.records.items[1].stream);
        try std.testing.expectEqualStrings("err", output.records.items[1].text.items);
    }
}

test "unterminated ansi-only callback does not create a blank record" {
    const alloc = std.testing.allocator;
    var output: CanonicalOutput = .{};
    defer output.deinit(alloc);
    try output.append(alloc, .stdout, "\x1b[31m");
    try output.finish(alloc);
    try std.testing.expectEqual(@as(usize, 0), output.records.items.len);
}

test "foreground result extraction is exact and rejects delimiter collisions" {
    const alloc = std.testing.allocator;

    var live: CanonicalOutput = .{};
    defer live.deinit(alloc);
    try live.append(alloc, .stdout, "one\n");
    try live.finish(alloc);

    var extracted = (try canonicalizeForegroundResult(
        alloc,
        "exit_code=0\n<stdout>\none\n</stdout>\n",
    )).?;
    defer extracted.deinit(alloc);
    try std.testing.expect(eql(live, extracted));

    var whitespace = (try canonicalizeForegroundResult(
        alloc,
        "exit_code=0\n<stdout>\n one \n</stdout>\n",
    )).?;
    defer whitespace.deinit(alloc);
    try std.testing.expect(!eql(live, whitespace));

    try std.testing.expect((try canonicalizeForegroundResult(
        alloc,
        "exit_code=0\n<stdout>\nliteral\n</stdout>\ntail\n</stdout>\n",
    )) == null);
    try std.testing.expect((try canonicalizeForegroundResult(
        alloc,
        "timeout=true\ncleanup_guarantee=best_effort\n",
    )) == null);
}

test "canonical equality distinguishes transforms from literal projections" {
    const alloc = std.testing.allocator;
    const Case = struct {
        raw: []const u8,
        projected: []const u8,
    };
    for ([_]Case{
        .{ .raw = "\x00\n", .projected = "\\x00\n" },
        .{ .raw = "\xff\n", .projected = "\\xff\n" },
        .{ .raw = "\xc2\x80\n", .projected = "\\u{0080}\n" },
        .{ .raw = "\x1b[31mred\x1b[0m\n", .projected = "red\n" },
        .{ .raw = "old\rnew\n", .projected = "new\n" },
    }) |case| {
        var raw: CanonicalOutput = .{};
        defer raw.deinit(alloc);
        try raw.append(alloc, .stdout, case.raw);
        try raw.finish(alloc);

        var preserved: CanonicalOutput = .{};
        defer preserved.deinit(alloc);
        try preserved.append(alloc, .stdout, case.raw);
        try preserved.finish(alloc);
        try std.testing.expect(eql(raw, preserved));

        var projected: CanonicalOutput = .{};
        defer projected.deinit(alloc);
        try projected.append(alloc, .stdout, case.projected);
        try projected.finish(alloc);
        try std.testing.expect(!eql(raw, projected));
    }

    var literal_live: CanonicalOutput = .{};
    defer literal_live.deinit(alloc);
    try literal_live.append(alloc, .stdout, "\\x00\n");
    try literal_live.finish(alloc);
    var literal_result: CanonicalOutput = .{};
    defer literal_result.deinit(alloc);
    try literal_result.append(alloc, .stdout, "\\x00");
    try literal_result.finish(alloc);
    try std.testing.expect(eql(literal_live, literal_result));
}

fn fuzzCommandOutputContent(_: void, smith: *std.testing.Smith) anyerror!void {
    const alloc = std.testing.allocator;
    var input_buffer: [4096]u8 = undefined;
    const input_len: usize = @intCast(smith.slice(&input_buffer));
    const input = input_buffer[0..input_len];
    const split = input.len / 2;
    var output: CanonicalOutput = .{};
    defer output.deinit(alloc);
    try output.append(alloc, .stdout, input[0..split]);
    try output.append(alloc, .stdout, input[split..]);
    try output.finish(alloc);

    if (try canonicalizeForegroundResult(alloc, input)) |parsed_value| {
        var parsed = parsed_value;
        parsed.deinit(alloc);
    }
}

test "fuzz command output content" {
    try std.testing.fuzz({}, fuzzCommandOutputContent, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "progress\roverwrite\n",
            "\x1b[31mred\x1b[0m\n",
            "exit_code=0\n<stdout>\none\n</stdout>\n",
            "\xff\x00\xe2\x82",
        }) ++ @import("fuzz_corpus").command_output_content.*),
    });
}

pub const condense_min_bytes: usize = 16 * 1024;
pub const condense_min_lines: usize = 200;
pub const condense_max_bytes: usize = 8 * 1024;
pub const condense_head_lines: usize = 20;
pub const condense_tail_lines: usize = 20;
pub const condense_signal_lines: usize = 40;
pub const condense_gap_marker = "[...]";
const condense_stored_line_bytes: usize = 2048;
const condense_line_bytes: usize = 512;
const condense_min_line_bytes: usize = 64;

const strong_signal_words = [_][]const u8{
    "error",     "fail",      "assert",    "panic",  "fatal",
    "traceback", "exception", "exit code", "denied",
};
const weak_signal_words = [_][]const u8{ "warn", "pass" };

const SignalClass = enum { none, weak, strong };

pub fn needsCondensing(text: []const u8) bool {
    return text.len > condense_min_bytes or countLines(text) > condense_min_lines;
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    const terminated = std.mem.countScalar(u8, text, '\n');
    return if (text[text.len - 1] == '\n') terminated else terminated + 1;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(haystack, needle) != null;
}

fn signalClass(line: []const u8) SignalClass {
    for (strong_signal_words) |word| {
        if (containsIgnoreCase(line, word)) return .strong;
    }
    for (weak_signal_words) |word| {
        if (containsIgnoreCase(line, word)) return .weak;
    }
    return .none;
}

fn isBlankByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == 0x0b or byte == 0x0c;
}

fn utf8PrefixEnd(text: []const u8, max_bytes: usize) usize {
    if (text.len <= max_bytes) return text.len;
    var end = max_bytes;
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    return end;
}

const CondensedLine = struct {
    text: []u8,
    full_bytes: usize,
    hash: u64,
    repeats: usize = 1,
    gap_before: bool = false,
    class: SignalClass = .none,

    fn deinit(self: *CondensedLine, alloc: Allocator) void {
        alloc.free(self.text);
        self.* = undefined;
    }
};

pub const CondenseOptions = struct {
    full_output_available: bool = true,
};

pub const Condensed = struct {
    text: []u8,
    original_bytes: usize,
    total_lines: usize,
    kept_lines: usize,
    dropped_lines: usize,

    pub fn deinit(self: *Condensed, alloc: Allocator) void {
        alloc.free(self.text);
        self.* = undefined;
    }
};

pub const Condenser = struct {
    alloc: Allocator,
    escape_state: EscapeState = .none,
    line: std.ArrayList(u8) = .empty,
    line_bytes: usize = 0,
    line_hash: std.hash.Fnv1a_64 = .init(),
    line_blank: bool = true,
    line_open: bool = false,
    pending_cr: usize = 0,
    previous: ?CondensedLine = null,
    head: std.ArrayList(CondensedLine) = .empty,
    signals: std.ArrayList(CondensedLine) = .empty,
    tail: std.ArrayList(CondensedLine) = .empty,
    gap_pending: bool = false,
    original_bytes: usize = 0,
    total_lines: usize = 0,

    pub fn init(alloc: Allocator) Condenser {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Condenser) void {
        self.line.deinit(self.alloc);
        if (self.previous) |*value| value.deinit(self.alloc);
        for ([_]*std.ArrayList(CondensedLine){ &self.head, &self.signals, &self.tail }) |list| {
            for (list.items) |*entry| entry.deinit(self.alloc);
            list.deinit(self.alloc);
        }
        self.* = undefined;
    }

    pub fn append(self: *Condenser, raw: []const u8) Allocator.Error!void {
        self.original_bytes += raw.len;
        for (raw) |byte| {
            if (byte != '\n') self.line_open = true;
            if (self.stripsEscapeByte(byte)) continue;
            try self.acceptVisibleByte(byte);
        }
    }

    pub fn markUnknownGap(self: *Condenser) Allocator.Error!void {
        if (self.line_open) try self.finishLine();
        try self.flushPrevious();
        self.escape_state = .none;
        while (self.tail.items.len > 0) {
            var evicted = self.tail.orderedRemove(0);
            try self.routeMiddle(&evicted);
        }
        self.gap_pending = true;
    }

    fn stripsEscapeByte(self: *Condenser, byte: u8) bool {
        switch (self.escape_state) {
            .none => {
                if (byte != 0x1b) return false;
                self.escape_state = .escape;
                return true;
            },
            .escape => {
                if (byte == '[') {
                    self.escape_state = .csi;
                    return true;
                }
                if (byte == ']') {
                    self.escape_state = .osc;
                    return true;
                }
                if (byte == 0x1b) return true;
                self.escape_state = .none;
                return byte >= 0x40 and byte <= 0x5f;
            },
            .csi => {
                if (byte == '\n') {
                    self.escape_state = .none;
                    return false;
                }
                if (byte >= 0x40 and byte <= 0x7e) self.escape_state = .none;
                return true;
            },
            .osc => {
                if (byte == '\n') {
                    self.escape_state = .none;
                    return false;
                }
                if (byte == 0x07) {
                    self.escape_state = .none;
                } else if (byte == 0x1b) {
                    self.escape_state = .osc_escape;
                }
                return true;
            },
            .osc_escape => {
                if (byte == '\n') {
                    self.escape_state = .none;
                    return false;
                }
                if (byte == '\\') {
                    self.escape_state = .none;
                } else if (byte != 0x1b) {
                    self.escape_state = .osc;
                }
                return true;
            },
        }
    }

    fn acceptVisibleByte(self: *Condenser, byte: u8) Allocator.Error!void {
        if (byte == '\n') return self.finishLine();
        if (byte == '\r') {
            self.pending_cr += 1;
            return;
        }
        while (self.pending_cr > 0) : (self.pending_cr -= 1) {
            try self.appendLineByte('\r');
        }
        try self.appendLineByte(byte);
    }

    fn appendLineByte(self: *Condenser, byte: u8) Allocator.Error!void {
        self.line_bytes += 1;
        self.line_hash.update(&.{byte});
        if (!isBlankByte(byte) and byte != '\r') self.line_blank = false;
        if (self.line.items.len < condense_stored_line_bytes) {
            try self.line.append(self.alloc, byte);
        }
    }

    fn resetLine(self: *Condenser) void {
        self.line.clearRetainingCapacity();
        self.line_bytes = 0;
        self.line_hash = .init();
        self.line_blank = true;
        self.line_open = false;
        self.pending_cr = 0;
    }

    fn finishLine(self: *Condenser) Allocator.Error!void {
        self.total_lines += 1;
        defer self.resetLine();
        if (self.line_blank) return;
        const hash = self.line_hash.final();
        if (self.previous) |*previous| {
            if (previous.hash == hash and
                previous.full_bytes == self.line_bytes and
                std.mem.eql(u8, previous.text, self.line.items))
            {
                previous.repeats += 1;
                return;
            }
        }
        try self.flushPrevious();
        self.previous = .{
            .text = try self.alloc.dupe(u8, self.line.items),
            .full_bytes = self.line_bytes,
            .hash = hash,
        };
    }

    fn flushPrevious(self: *Condenser) Allocator.Error!void {
        var entry = self.previous orelse return;
        self.previous = null;
        const head_open = self.head.items.len < condense_head_lines and
            self.signals.items.len == 0 and
            self.tail.items.len == 0 and
            !self.gap_pending;
        const target = if (head_open) &self.head else &self.tail;
        target.append(self.alloc, entry) catch |err| {
            entry.deinit(self.alloc);
            return err;
        };
        if (self.tail.items.len > condense_tail_lines) {
            var evicted = self.tail.orderedRemove(0);
            try self.routeMiddle(&evicted);
        }
    }

    fn routeMiddle(self: *Condenser, evicted: *CondensedLine) Allocator.Error!void {
        self.signals.ensureTotalCapacity(self.alloc, condense_signal_lines) catch |err| {
            evicted.deinit(self.alloc);
            return err;
        };
        evicted.class = signalClass(evicted.text);
        if (evicted.class == .none) return self.dropMiddle(evicted);
        if (self.signals.items.len == condense_signal_lines) {
            if (evicted.class != .strong) return self.dropMiddle(evicted);
            const weak_index = self.lastWeakSignalIndex() orelse return self.dropMiddle(evicted);
            var removed = self.signals.orderedRemove(weak_index);
            removed.deinit(self.alloc);
            if (weak_index < self.signals.items.len) {
                self.signals.items[weak_index].gap_before = true;
            } else {
                self.gap_pending = true;
            }
        }
        evicted.gap_before = self.gap_pending;
        self.gap_pending = false;
        self.signals.appendAssumeCapacity(evicted.*);
    }

    fn dropMiddle(self: *Condenser, evicted: *CondensedLine) void {
        evicted.deinit(self.alloc);
        self.gap_pending = true;
    }

    fn lastWeakSignalIndex(self: *const Condenser) ?usize {
        var index = self.signals.items.len;
        while (index > 0) {
            index -= 1;
            if (self.signals.items[index].class == .weak) return index;
        }
        return null;
    }

    pub fn finish(self: *Condenser, options: CondenseOptions) Allocator.Error!Condensed {
        if (self.line_open) try self.finishLine();
        try self.flushPrevious();

        var line_limit = condense_line_bytes;
        var signal_count = self.signals.items.len;
        while (true) {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(self.alloc);
            try self.render(&out, line_limit, signal_count);
            if (out.items.len > condense_max_bytes) {
                if (line_limit > condense_min_line_bytes) {
                    line_limit /= 2;
                    out.deinit(self.alloc);
                    continue;
                }
                if (signal_count > 0) {
                    signal_count -= 1;
                    out.deinit(self.alloc);
                    continue;
                }
            }
            const kept_lines = self.head.items.len + signal_count + self.tail.items.len;
            const dropped_lines = self.total_lines -| kept_lines;
            try out.print(
                self.alloc,
                "[output condensed: kept {d} of {d} lines; dropped {d}; {d} original bytes; {s}]",
                .{
                    kept_lines,
                    self.total_lines,
                    dropped_lines,
                    self.original_bytes,
                    if (options.full_output_available)
                        "page the full output with read_tool_result on full_output_handle"
                    else
                        "the full output was not retained",
                },
            );
            return .{
                .text = try out.toOwnedSlice(self.alloc),
                .original_bytes = self.original_bytes,
                .total_lines = self.total_lines,
                .kept_lines = kept_lines,
                .dropped_lines = dropped_lines,
            };
        }
    }

    fn render(
        self: *const Condenser,
        out: *std.ArrayList(u8),
        line_limit: usize,
        signal_count: usize,
    ) Allocator.Error!void {
        for (self.head.items) |entry| try renderLine(self.alloc, out, entry, line_limit);
        for (self.signals.items[0..signal_count]) |entry| {
            if (entry.gap_before) try renderGap(self.alloc, out);
            try renderLine(self.alloc, out, entry, line_limit);
        }
        if (self.gap_pending or signal_count != self.signals.items.len) {
            try renderGap(self.alloc, out);
        }
        for (self.tail.items) |entry| try renderLine(self.alloc, out, entry, line_limit);
    }
};

fn renderGap(alloc: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
    try out.appendSlice(alloc, condense_gap_marker ++ "\n");
}

fn renderLine(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    entry: CondensedLine,
    line_limit: usize,
) Allocator.Error!void {
    if (entry.full_bytes > line_limit) {
        const end = utf8PrefixEnd(entry.text, line_limit);
        try out.appendSlice(alloc, entry.text[0..end]);
        try out.print(alloc, " [+{d} bytes]", .{entry.full_bytes - end});
    } else {
        try out.appendSlice(alloc, entry.text);
    }
    try out.append(alloc, '\n');
    if (entry.repeats > 1) {
        try out.print(alloc, "[repeated {d} times]\n", .{entry.repeats});
    }
}

pub fn condense(
    alloc: Allocator,
    text: []const u8,
    options: CondenseOptions,
) Allocator.Error!?Condensed {
    if (!needsCondensing(text)) return null;
    var condenser = Condenser.init(alloc);
    defer condenser.deinit();
    try condenser.append(text);
    return try condenser.finish(options);
}

fn numberedLines(alloc: Allocator, count: usize, comptime fmt: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (0..count) |index| try out.print(alloc, fmt, .{index});
    return out.toOwnedSlice(alloc);
}

fn expectCondensedFooter(condensed: Condensed, expected: []const u8) !void {
    const footer_start = std.mem.findLast(u8, condensed.text, "\n[output condensed: ").?;
    try std.testing.expectEqualStrings(expected, condensed.text[footer_start + 1 ..]);
}

test "condense leaves output at the byte and line thresholds untouched" {
    const alloc = std.testing.allocator;

    const at_line_threshold = try numberedLines(alloc, condense_min_lines, "l{d}\n");
    defer alloc.free(at_line_threshold);
    try std.testing.expect(!needsCondensing(at_line_threshold));
    try std.testing.expect(try condense(alloc, at_line_threshold, .{}) == null);

    const unterminated = try numberedLines(alloc, condense_min_lines, "l{d}\n");
    defer alloc.free(unterminated);
    try std.testing.expect(try condense(alloc, unterminated[0 .. unterminated.len - 1], .{}) == null);

    const at_byte_threshold: [condense_min_bytes]u8 = @splat('x');
    try std.testing.expect(try condense(alloc, &at_byte_threshold, .{}) == null);
    try std.testing.expect(try condense(alloc, "", .{}) == null);
    try std.testing.expect(try condense(alloc, "exit 1\n", .{}) == null);
}

test "condense starts one line or one byte above the thresholds" {
    const alloc = std.testing.allocator;

    const over_lines = try numberedLines(alloc, condense_min_lines + 1, "l{d}\n");
    defer alloc.free(over_lines);
    var by_lines = (try condense(alloc, over_lines, .{})).?;
    defer by_lines.deinit(alloc);
    try std.testing.expectEqual(condense_min_lines + 1, by_lines.total_lines);
    try std.testing.expectEqual(over_lines.len, by_lines.original_bytes);

    const over_bytes: [condense_min_bytes + 1]u8 = @splat('x');
    var by_bytes = (try condense(alloc, &over_bytes, .{})).?;
    defer by_bytes.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), by_bytes.total_lines);
    try std.testing.expectEqual(@as(usize, 1), by_bytes.kept_lines);
    try std.testing.expectEqual(@as(usize, 0), by_bytes.dropped_lines);
    try std.testing.expect(by_bytes.text.len < condense_max_bytes);
    try std.testing.expect(std.mem.find(u8, by_bytes.text, " bytes]\n") != null);
}

test "condense keeps the first and last twenty lines and counts the rest in the footer" {
    const alloc = std.testing.allocator;
    const input = try numberedLines(alloc, 300, "line-{d}\n");
    defer alloc.free(input);

    var condensed = (try condense(alloc, input, .{})).?;
    defer condensed.deinit(alloc);

    try std.testing.expect(std.mem.startsWith(u8, condensed.text, "line-0\nline-1\n"));
    try std.testing.expect(std.mem.find(u8, condensed.text, "line-19\n" ++ condense_gap_marker ++ "\nline-280\n") != null);
    try std.testing.expect(std.mem.find(u8, condensed.text, "line-20\n") == null);
    try std.testing.expect(std.mem.find(u8, condensed.text, "line-279\n") == null);
    try std.testing.expect(std.mem.find(u8, condensed.text, "line-299\n[output condensed: ") != null);
    try std.testing.expectEqual(@as(usize, 40), condensed.kept_lines);
    try std.testing.expectEqual(@as(usize, 260), condensed.dropped_lines);
    try expectCondensedFooter(
        condensed,
        "[output condensed: kept 40 of 300 lines; dropped 260; 2590 original bytes; page the full output with read_tool_result on full_output_handle]",
    );
}

test "condense footer says when the full output was not retained" {
    const alloc = std.testing.allocator;
    const input = try numberedLines(alloc, 300, "line-{d}\n");
    defer alloc.free(input);

    var condensed = (try condense(alloc, input, .{ .full_output_available = false })).?;
    defer condensed.deinit(alloc);
    try std.testing.expect(std.mem.endsWith(u8, condensed.text, "; the full output was not retained]"));
    try std.testing.expect(std.mem.find(u8, condensed.text, "full_output_handle") == null);
}

test "condense strips ANSI escapes and drops blank lines" {
    const alloc = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    try input.appendSlice(alloc, "\x1b[1;31mred start\x1b[0m\n\n   \t\n\x1b]0;window title\x07titled\n\x1b[2K\n");
    for (0..260) |index| try input.print(alloc, "\x1b[32mrow-{d}\x1b[0m\n\n", .{index});

    var condensed = (try condense(alloc, input.items, .{})).?;
    defer condensed.deinit(alloc);

    try std.testing.expect(std.mem.startsWith(u8, condensed.text, "red start\ntitled\nrow-0\nrow-1\n"));
    try std.testing.expect(std.mem.findScalar(u8, condensed.text, 0x1b) == null);
    try std.testing.expect(std.mem.find(u8, condensed.text, "\n\n") == null);
    try std.testing.expect(std.mem.find(u8, condensed.text, "window title") == null);
    try std.testing.expectEqual(@as(usize, 40), condensed.kept_lines);
    try std.testing.expectEqual(@as(usize, 525), condensed.total_lines);
}

test "condense folds identical consecutive lines into one line and a repeat count" {
    const alloc = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    try input.appendSlice(alloc, "start\n");
    for (0..500) |_| try input.appendSlice(alloc, "downloading...\n");
    try input.appendSlice(alloc, "middle\n");
    for (0..2) |_| try input.appendSlice(alloc, "twice\n");
    try input.appendSlice(alloc, "done\n");

    var condensed = (try condense(alloc, input.items, .{})).?;
    defer condensed.deinit(alloc);

    try std.testing.expect(std.mem.startsWith(
        u8,
        condensed.text,
        "start\ndownloading...\n[repeated 500 times]\nmiddle\ntwice\n[repeated 2 times]\ndone\n[output condensed: kept 5 of 505 lines; dropped 500; ",
    ));
    try std.testing.expect(std.mem.find(u8, condensed.text, condense_gap_marker) == null);
}

test "condense does not fold equal lines separated by a different line" {
    const alloc = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    for (0..150) |_| try input.appendSlice(alloc, "tick\ntock\n");

    var condensed = (try condense(alloc, input.items, .{})).?;
    defer condensed.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, condensed.text, "[repeated ") == null);
    try std.testing.expectEqual(@as(usize, 40), condensed.kept_lines);
}

test "condense keeps middle signal lines case-insensitively with gap markers" {
    const alloc = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    for (0..100) |index| try input.print(alloc, "compile {d}\n", .{index});
    try input.appendSlice(alloc, "src/a.zig:3:1: ERROR: expected type\n");
    try input.appendSlice(alloc, "##[error]step failed\n");
    for (0..100) |index| try input.print(alloc, "link {d}\n", .{index});
    try input.appendSlice(alloc, "Traceback (most recent call last):\n");
    try input.appendSlice(alloc, "process ended with Exit Code 2\n");
    for (0..100) |index| try input.print(alloc, "cleanup {d}\n", .{index});

    var condensed = (try condense(alloc, input.items, .{})).?;
    defer condensed.deinit(alloc);

    try std.testing.expect(std.mem.find(
        u8,
        condensed.text,
        "compile 19\n[...]\nsrc/a.zig:3:1: ERROR: expected type\n##[error]step failed\n[...]\n" ++
            "Traceback (most recent call last):\nprocess ended with Exit Code 2\n[...]\ncleanup 80\n",
    ) != null);
    try std.testing.expectEqual(@as(usize, 44), condensed.kept_lines);
    try std.testing.expectEqual(@as(usize, 260), condensed.dropped_lines);
}

test "condense caps middle signal lines at forty" {
    const alloc = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    for (0..30) |index| try input.print(alloc, "head {d}\n", .{index});
    for (0..200) |index| try input.print(alloc, "test {d} failed\n", .{index});
    for (0..30) |index| try input.print(alloc, "tail {d}\n", .{index});

    var condensed = (try condense(alloc, input.items, .{})).?;
    defer condensed.deinit(alloc);

    try std.testing.expectEqual(
        condense_head_lines + condense_signal_lines + condense_tail_lines,
        condensed.kept_lines,
    );
    try std.testing.expect(std.mem.find(u8, condensed.text, "test 39 failed\n[...]\ntail 10\n") != null);
    try std.testing.expect(std.mem.find(u8, condensed.text, "test 40 failed\n") == null);
    try std.testing.expectEqual(@as(usize, 180), condensed.dropped_lines);
}

test "condense lets a late error replace a kept warning when the signal budget is full" {
    const alloc = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    for (0..25) |index| try input.print(alloc, "head {d}\n", .{index});
    for (0..120) |index| try input.print(alloc, "warning: unused variable {d}\n", .{index});
    try input.appendSlice(alloc, "error: linker command failed\n");
    for (0..80) |index| try input.print(alloc, "tail {d}\n", .{index});

    var condensed = (try condense(alloc, input.items, .{})).?;
    defer condensed.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, condensed.text, "error: linker command failed\n") != null);
    try std.testing.expect(std.mem.find(u8, condensed.text, "warning: unused variable 38\n[...]\nerror: linker command failed\n[...]\ntail 60\n") != null);
    try std.testing.expect(std.mem.find(u8, condensed.text, "warning: unused variable 39\n") == null);
    try std.testing.expectEqual(@as(usize, 80), condensed.kept_lines);
}

test "condense treats CRLF line endings as line breaks" {
    const alloc = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    for (0..250) |index| try input.print(alloc, "row {d}\r\n", .{index});
    try input.appendSlice(alloc, "same\r\nsame\r\n\r\nprogress 1\rprogress 2\r\n");

    var condensed = (try condense(alloc, input.items, .{})).?;
    defer condensed.deinit(alloc);

    try std.testing.expect(std.mem.startsWith(u8, condensed.text, "row 0\nrow 1\n"));
    try std.testing.expect(std.mem.find(u8, condensed.text, "\r\n") == null);
    try std.testing.expect(std.mem.find(u8, condensed.text, "same\n[repeated 2 times]\nprogress 1\rprogress 2\n[output condensed: ") != null);
    try std.testing.expectEqual(@as(usize, 254), condensed.total_lines);
}

test "condense clips long lines on UTF-8 boundaries and stays under the byte cap" {
    const alloc = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    for (0..60) |index| {
        try input.print(alloc, "{d}:", .{index});
        for (0..700) |_| try input.appendSlice(alloc, "\xe2\x82\xac");
        try input.append(alloc, '\n');
    }

    var condensed = (try condense(alloc, input.items, .{})).?;
    defer condensed.deinit(alloc);

    try std.testing.expect(std.unicode.utf8ValidateSlice(condensed.text));
    const footer_start = std.mem.findLast(u8, condensed.text, "\n[output condensed: ").?;
    try std.testing.expect(footer_start + 1 <= condense_max_bytes);
    try std.testing.expectEqual(@as(usize, 40), condensed.kept_lines);
    try std.testing.expect(std.mem.find(u8, condensed.text, " bytes]\n") != null);
    try std.testing.expectEqual(input.items.len, condensed.original_bytes);
}

test "condense shrinks clipped lines until the text fits the byte cap" {
    const alloc = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    for (0..200) |index| {
        try input.print(alloc, "error {d} ", .{index});
        for (0..300) |_| try input.append(alloc, 'e');
        try input.append(alloc, '\n');
        try input.appendSlice(alloc, "same\nsame\n");
    }

    var condensed = (try condense(alloc, input.items, .{})).?;
    defer condensed.deinit(alloc);

    const footer_start = std.mem.findLast(u8, condensed.text, "\n[output condensed: ").?;
    try std.testing.expect(footer_start + 1 <= condense_max_bytes);
    try std.testing.expect(condensed.kept_lines >= condense_head_lines + condense_tail_lines);
    try std.testing.expectEqual(@as(usize, 600), condensed.total_lines);
    try std.testing.expectEqual(condensed.total_lines - condensed.kept_lines, condensed.dropped_lines);
}

test "condenser output does not depend on how the input is chunked" {
    const alloc = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    for (0..120) |index| try input.print(alloc, "\x1b[33mstep {d}\x1b[0m\r\n", .{index});
    try input.appendSlice(alloc, "panic: reached unreachable\n");
    for (0..120) |index| try input.print(alloc, "after {d}\n", .{index});

    var whole = (try condense(alloc, input.items, .{})).?;
    defer whole.deinit(alloc);

    for ([_]usize{ 1, 7, 4096 }) |chunk_bytes| {
        var condenser = Condenser.init(alloc);
        defer condenser.deinit();
        var offset: usize = 0;
        while (offset < input.items.len) {
            const end = @min(input.items.len, offset + chunk_bytes);
            try condenser.append(input.items[offset..end]);
            offset = end;
        }
        var chunked = try condenser.finish(.{});
        defer chunked.deinit(alloc);
        try std.testing.expectEqualStrings(whole.text, chunked.text);
    }
}

test "condenser marks an unknown gap between a head and a separately read tail" {
    const alloc = std.testing.allocator;
    var condenser = Condenser.init(alloc);
    defer condenser.deinit();
    try condenser.append("first\nsecond\n");
    try condenser.markUnknownGap();
    try condenser.append("real last line\n");
    var condensed = try condenser.finish(.{});
    defer condensed.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(u8, condensed.text, "first\nsecond\n[...]\nreal last line\n[output condensed: "));
}
