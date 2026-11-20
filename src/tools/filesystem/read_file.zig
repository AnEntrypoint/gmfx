const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const read_tracker = @import("../../core/workspace/read_tracker.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const image_data = @import("../../core/images/image_data.zig");
const png_downscale = @import("../../core/images/png_downscale.zig");
const core_types = @import("../../core/shared/types.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_result_errors = @import("../../core/tooling/tool_result_errors.zig");
const env_redaction = @import("../../core/workspace/env_redaction.zig");
const result_store = @import("../../core/session/result_store.zig");
const file_facts = @import("file_facts.zig");

const Allocator = std.mem.Allocator;

const max_snapshot_file_bytes: usize = 10 * 1024 * 1024;

const max_model_output_bytes: usize = 256 * 1024;

const max_line_count: usize = 2000;
const line_truncated_marker = "... (line truncated";
const line_truncated_suffix_capacity: usize = 128;
const whole_file_envelope_reserve_bytes: usize = 192;
const file_facts_prefix = "[file: ";
const accepted_fields = [_][]const u8{ "path", "start_line", "line_count", "line_offset", "column_offset", "n_lines", "max_chars", "force" };

const whitespace = " \t\r\n";

pub const Input = struct {
    path: []u8,
    start_line: usize = 1,
    tail_lines: ?usize = null,
    column_offset: usize = 0,
    line_count: usize = tool_dispatch.default_max_read_file_lines,
    line_count_explicit: bool = false,
    max_chars: usize = max_model_output_bytes,
    force: bool = false,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.path);
        self.* = .{ .path = &.{} };
    }
};

const start_line_conflict_message = "read_file accepts start_line or line_offset, not both";

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var args: tool_args.ArgsDecoder = .{ .alloc = ctx.allocator, .tool = "read_file" };
    var parsed = args.parse(args_json) catch |err| return .{ .failure = try args.takeFailure(err) };
    defer parsed.deinit();
    const object = parsed.value.object;
    args.rejectUnknown(object, &accepted_fields) catch |err| return .{ .failure = try args.takeFailure(err) };
    const path = args.requiredString(object, "path") catch |err| return .{ .failure = try args.takeFailure(err) };

    var shape: Input = .{ .path = &.{} };
    const has_start_line = object.get("start_line") != null;
    switch (try parseOptionalPositive(ctx.allocator, object, "start_line")) {
        .missing => {},
        .value => |value| shape.start_line = value,
        .failure => |body| return .{ .failure = body },
    }
    switch (try parseLineOffset(ctx.allocator, object)) {
        .missing => {},
        .forward => |value| {
            if (has_start_line) return .{ .failure = try ctx.allocator.dupe(u8, start_line_conflict_message) };
            shape.start_line = value;
        },
        .tail => |value| {
            if (has_start_line) return .{ .failure = try ctx.allocator.dupe(u8, start_line_conflict_message) };
            shape.tail_lines = value;
        },
        .failure => |body| return .{ .failure = body },
    }
    for ([_][]const u8{ "line_count", "n_lines" }) |key| {
        switch (try parseOptionalPositive(ctx.allocator, object, key)) {
            .missing => {},
            .value => |value| {
                shape.line_count = @min(value, max_line_count);
                shape.line_count_explicit = true;
            },
            .failure => |body| return .{ .failure = body },
        }
    }
    switch (try parseOptionalNonNegative(ctx.allocator, object, "column_offset")) {
        .missing => {},
        .value => |value| shape.column_offset = value,
        .failure => |body| return .{ .failure = body },
    }
    switch (try parseOptionalPositive(ctx.allocator, object, "max_chars")) {
        .missing => {},
        .value => |value| shape.max_chars = @min(value, max_model_output_bytes),
        .failure => |body| return .{ .failure = body },
    }
    if (object.get("force")) |value| {
        if (value != .bool) return .{ .failure = try ctx.allocator.dupe(u8, "read_file field \"force\" must be a boolean") };
        shape.force = value.bool;
    }

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = shape;
    input.path = try ctx.allocator.dupe(u8, path);
    errdefer input.deinit(ctx.allocator);

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

const PositiveParse = union(enum) {
    missing,
    value: usize,
    failure: []u8,
};

const LineOffsetParse = union(enum) {
    missing,
    forward: usize,
    tail: usize,
    failure: []u8,
};

fn parseOptionalPositive(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) tool_dispatch.DispatchError!PositiveParse {
    const value = object.get(key) orelse return .missing;
    if (value != .integer or value.integer < 1) {
        return .{ .failure = try alloc.print("read_file field \"{s}\" must be a positive integer", .{key}) };
    }
    return .{ .value = @intCast(value.integer) };
}

fn parseOptionalNonNegative(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) tool_dispatch.DispatchError!PositiveParse {
    const value = object.get(key) orelse return .missing;
    if (value != .integer or value.integer < 0) {
        return .{ .failure = try alloc.print("read_file field \"{s}\" must be a non-negative integer", .{key}) };
    }
    return .{ .value = @intCast(value.integer) };
}

fn parseLineOffset(alloc: Allocator, object: std.json.ObjectMap) tool_dispatch.DispatchError!LineOffsetParse {
    const value = object.get("line_offset") orelse return .missing;
    if (value != .integer or value.integer == 0) {
        return .{ .failure = try alloc.dupe(u8, "read_file field \"line_offset\" must be a non-zero integer; negative values read from the end of the file") };
    }
    const magnitude = std.math.cast(usize, @abs(value.integer)) orelse std.math.maxInt(usize);
    if (value.integer > 0) return .{ .forward = magnitude };
    return .{ .tail = magnitude };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    const trimmed = std.mem.trim(u8, input.path, whitespace);
    try replacePath(ctx.allocator, input, trimmed);

    if (input.path.len == 0) {
        return try ctx.allocator.dupe(u8, "read_file field \"path\" must not be empty");
    }
    return null;
}

fn replacePath(alloc: Allocator, input: *Input, next: []const u8) tool_dispatch.DispatchError!void {
    if (std.mem.eql(u8, input.path, next)) return;
    const owned = try alloc.dupe(u8, next);
    replaceOwnedPath(alloc, input, owned);
}

fn replaceOwnedPath(alloc: Allocator, input: *Input, owned: []u8) void {
    alloc.free(input.path);
    input.path = owned;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const target = pathing.resolveWorkspaceOrExternalPath(arena, ctx.workspace_root, input.path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return readFileFailure(ctx.allocator, err, input.path);
    };

    const zio = io_mod.getIo();
    var file = io_mod.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), target, .no_follow) catch |err| {
        return readFileFailure(
            ctx.allocator,
            if (err == error.DurablePathUnsafe) error.NotRegularFile else err,
            target,
        );
    };
    defer file.close(zio);

    const stat = file.stat(zio) catch |err| {
        return readFileFailure(ctx.allocator, err, target);
    };
    const truncated_by_size = stat.size > max_snapshot_file_bytes;
    const read_len: usize = @intCast(@min(stat.size, max_snapshot_file_bytes));
    const content = try arena.alloc(u8, read_len);
    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(zio, &read_buf);
    const actual_len = readIntoBuffer(&reader.interface, content) catch |err| {
        return readFileFailure(ctx.allocator, err, target);
    };
    const text = content[0..actual_len];
    const rel = pathing.workspaceRelativePath(arena, ctx.workspace_root, target) catch target;

    if (!text_utils.isModelSafeText(text)) {
        if (try imageToolResult(ctx, rel, text, stat.size, truncated_by_size or actual_len != stat.size)) |result| return result;
        tool_dispatch.reportToolResultMemory(ctx, .{
            .model_view_covers_full_file = false,
        });
        return .{ .success = try ctx.allocator.print(
            "<path>{s}</path>\n<content>binary or non-utf8 file omitted ({d} bytes)</content>",
            .{ rel, stat.size },
        ) };
    }

    const content_hash = read_tracker.contentHash(text);
    const snapshot_covers_full_file = !truncated_by_size and actual_len == stat.size;
    const range = requestedRange(input);
    if (!input.force and snapshot_covers_full_file) {
        if (servedUnchangedView(ctx, target, stat, content_hash, range)) |served| {
            tool_dispatch.reportToolResultMemory(ctx, .{ .model_view_covers_full_file = false });
            return .{ .success = try formatUnchangedOutput(ctx.allocator, rel, served, currentStep(ctx)) };
        }
    }

    const redacted = env_redaction.isSensitiveEnvFile(target);
    const shown_text = if (redacted) try env_redaction.redactEnvText(arena, text) else text;

    var selected = input.*;
    if (selected.tail_lines) |tail| selected.start_line = tailStartLine(shown_text, tail);

    var records: std.ArrayList(LineRecord) = .empty;
    defer freeLineRecords(arena, &records);
    const scan = try selectDefaultView(arena, ctx, shown_text, &selected, rel.len, &records);
    const model_view_covers_full_file = snapshot_covers_full_file and !redacted and modelViewCoversFullFile(&selected, scan, records.items.len);
    tool_dispatch.reportToolResultMemory(ctx, .{
        .model_view_covers_full_file = model_view_covers_full_file,
    });

    const output = try formatReadOutput(ctx.allocator, rel, &selected, records.items, scan, snapshot_covers_full_file, .{
        .size_bytes = stat.size,
        .line_count = scan.total_lines,
        .line_count_complete = snapshot_covers_full_file,
        .mtime_ns = stat.mtime.nanoseconds,
    });
    errdefer ctx.allocator.free(output);
    try recordSuccessfulRead(ctx, target, stat, .{
        .content_hash = content_hash,
        .model_view_covers_full_file = model_view_covers_full_file,
        .snapshot_covers_full_file = snapshot_covers_full_file,
        .served_range = if (output.len <= inlineResultBudget(ctx)) range else null,
    });
    return .{ .success = output };
}

fn inlineResultBudget(ctx: tool_dispatch.DispatchContext) usize {
    return @min(ctx.max_tool_result_bytes, result_store.large_result_threshold_bytes);
}

fn requestedRange(input: *const Input) read_tracker.ViewRange {
    return .{
        .start_line = input.start_line,
        .tail_lines = input.tail_lines,
        .column_offset = input.column_offset,
        .line_count = if (input.line_count_explicit) input.line_count else null,
        .max_chars = input.max_chars,
    };
}

fn currentStep(ctx: tool_dispatch.DispatchContext) u64 {
    const tracker = ctx.read_tracker orelse return 0;
    return tracker.currentStep();
}

fn servedUnchangedView(
    ctx: tool_dispatch.DispatchContext,
    path: []const u8,
    stat: std.Io.File.Stat,
    content_hash: read_tracker.ContentHash,
    range: read_tracker.ViewRange,
) ?read_tracker.ServedView {
    const tracker = ctx.read_tracker orelse return null;
    const previous = tracker.lookup(path) orelse return null;
    return previous.servedUnchanged(stat.mtime.nanoseconds, stat.size, content_hash, range);
}

fn formatUnchangedOutput(
    alloc: Allocator,
    rel: []const u8,
    served: read_tracker.ServedView,
    current_step: u64,
) tool_dispatch.DispatchError![]u8 {
    return alloc.print(
        "<path>{s}</path>\n<content>unchanged since your last read at step {d} (now step {d}); pass `force: true` to read again</content>",
        .{ rel, served.step, current_step },
    );
}

fn selectDefaultView(
    alloc: Allocator,
    ctx: tool_dispatch.DispatchContext,
    text: []const u8,
    selected: *Input,
    rel_len: usize,
    records: *std.ArrayList(LineRecord),
) !ReadScan {
    const paged_line_count = @min(selected.line_count, ctx.max_read_file_lines);
    if (!selected.line_count_explicit and ctx.max_read_file_lines != 0) {
        const paged_max_chars = selected.max_chars;
        selected.line_count = std.math.maxInt(usize);
        selected.max_chars = @min(paged_max_chars, inlineResultBudget(ctx) -| (rel_len + whole_file_envelope_reserve_bytes));
        const whole = try selectLinesFromContent(alloc, text, selected, ctx.max_read_file_line_len, records);
        if (!whole.stopped_early) return whole;
        clearLineRecords(alloc, records);
        selected.max_chars = paged_max_chars;
    }
    selected.line_count = paged_line_count;
    return selectLinesFromContent(alloc, text, selected, ctx.max_read_file_line_len, records);
}

fn readFileFailure(alloc: Allocator, err: anyerror, path: []const u8) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (tool_result_errors.isFilesystemAccessDenied(err)) {
        return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(alloc, "read_file", path, err) };
    }

    if (err == error.NotRegularFile) {
        const details = [_]tool_result_errors.Detail{
            .{ .name = "field", .value = .{ .string = "path" } },
            .{ .name = "path", .value = .{ .string = path } },
            .{ .name = "error", .value = .{ .string = @errorName(err) } },
        };
        return .{ .failure = try tool_result_errors.toolExecutionFailureJson(alloc, .{
            .tool_name = "read_file",
            .message = "read_file requires a regular file",
            .details = &details,
            .suggestion = "Use glob_files to inspect directory contents, then choose a regular file.",
        }) };
    }
    const details = [_]tool_result_errors.Detail{
        .{ .name = "field", .value = .{ .string = "path" } },
        .{ .name = "path", .value = .{ .string = path } },
        .{ .name = "error", .value = .{ .string = @errorName(err) } },
    };
    return .{ .failure = try tool_result_errors.toolExecutionFailureJson(alloc, .{
        .tool_name = "read_file",
        .message = "read_file failed",
        .details = &details,
        .suggestion = "Run glob_files to discover matching paths, or check the path relative to the workspace.",
    }) };
}

pub fn readIntoBuffer(reader: *std.Io.Reader, buffer: []u8) !usize {
    var total: usize = 0;
    while (total < buffer.len) {
        const n = try reader.readSliceShort(buffer[total..]);
        if (n == 0) break;
        total += n;
    }
    return total;
}

const base64_chars_per_group: usize = 4;
const base64_bytes_per_group: usize = 3;
pub const max_attach_image_bytes: usize = image_data.max_encoded_image_bytes / base64_chars_per_group * base64_bytes_per_group;

fn imageToolResult(
    ctx: tool_dispatch.DispatchContext,
    rel: []const u8,
    bytes: []const u8,
    file_size: u64,
    incomplete_read: bool,
) tool_dispatch.DispatchError!?tool_dispatch.ToolResult {
    const mime_type = image_data.detectMediaTypeFromBytes(bytes) orelse return null;
    const dimensions = image_data.imageDimensions(bytes);
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    if (incomplete_read or dimensions == null or encoded_len > image_data.max_encoded_image_bytes or
        dimensions.?.exceeds(image_data.max_single_image_dimension))
    {
        tool_dispatch.reportToolResultMemory(ctx, .{ .model_view_covers_full_file = false });
        const reason = if (incomplete_read)
            "the file exceeds read_file's 10 MiB read limit"
        else if (dimensions == null)
            "the image dimensions could not be verified"
        else if (encoded_len > image_data.max_encoded_image_bytes)
            "the image exceeds the 5 MiB encoded attach limit"
        else
            "the image exceeds 8000 pixels per side";
        return .{ .success = try ctx.allocator.print(
            "<path>{s}</path>\n<content>image not attached: {s} ({d} bytes); {s}. Use an available image tool to save a smaller copy to a new file, then read_file the copy. If no image tool is available, ask the user before installing one.</content>",
            .{ rel, mime_type, file_size, reason },
        ) };
    }
    var text: std.Io.Writer.Allocating = .init(ctx.allocator);
    errdefer text.deinit();
    text.writer.print("<path>{s}</path>\n<content>image attached ({s}, {d} bytes)</content>", .{ rel, mime_type, file_size }) catch return error.OutOfMemory;
    const encoded = try ctx.allocator.alloc(u8, encoded_len);
    errdefer ctx.allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    const owned_mime = try ctx.allocator.dupe(u8, mime_type);
    errdefer ctx.allocator.free(owned_mime);
    const images = try ctx.allocator.alloc(core_types.ToolImage, 1);
    errdefer ctx.allocator.free(images);
    images[0] = .{ .data = encoded, .mime_type = owned_mime };
    tool_dispatch.reportToolResultMemory(ctx, .{
        .model_view_covers_full_file = true,
    });
    return .{ .rich = .{
        .text = try text.toOwnedSlice(),
        .images = images,
        .is_error = false,
    } };
}

const LineRecord = struct {
    number: usize,
    text: []u8,
};

const ReadScan = struct {
    total_lines: usize,
    display_truncated: bool,
    stopped_early: bool = false,
    lines_cut: bool = false,
};

const DisplayBudget = struct {
    width: usize = 1,
    bytes: usize = 0,
};

const LineSelectionState = struct {
    alloc: Allocator,
    input: *const Input,
    max_line_len: usize,
    records: *std.ArrayList(LineRecord),
    display_truncated: bool = false,
    stop_display: bool = false,
    lines_cut: bool = false,
    budget: DisplayBudget = .{},

    fn keepLine(self: *LineSelectionState, line_number: usize, text: []const u8) !void {
        if (self.stop_display) return;
        if (line_number < self.input.start_line) return;
        if (self.records.items.len >= self.input.line_count) {
            self.display_truncated = true;
            self.stop_display = true;
            return;
        }
        const column_start = if (self.records.items.len == 0 and self.input.tail_lines == null)
            @min(self.input.column_offset, text.len)
        else
            0;
        const shown = text[column_start..];
        const width = digitCount(line_number);
        if (width > self.budget.width) {
            self.budget.bytes += self.records.items.len * (width - self.budget.width);
            self.budget.width = width;
        }
        const line_truncated = shown.len > self.max_line_len;
        const clipped_len = if (line_truncated) utf8BoundaryAtOrBefore(shown, self.max_line_len) else shown.len;
        var suffix_buf: [line_truncated_suffix_capacity]u8 = undefined;
        const suffix = if (line_truncated)
            lineTruncatedSuffix(&suffix_buf, line_number, column_start + clipped_len)
        else
            "";
        const display_len = clipped_len + suffix.len;
        const rendered_bytes = self.budget.bytes + renderedLineBytes(self.budget.width, display_len);
        if (rendered_bytes > self.input.max_chars) {
            self.display_truncated = true;
            self.stop_display = true;
            return;
        }
        const display_text = try self.alloc.alloc(u8, display_len);
        errdefer self.alloc.free(display_text);
        @memcpy(display_text[0..clipped_len], shown[0..clipped_len]);
        if (line_truncated) {
            self.display_truncated = true;
            self.lines_cut = true;
            @memcpy(display_text[clipped_len..], suffix);
        }
        try self.records.append(self.alloc, .{
            .number = line_number,
            .text = display_text,
        });
        self.budget.bytes = rendered_bytes;
    }
};

fn utf8BoundaryAtOrBefore(text: []const u8, limit: usize) usize {
    var end = @min(limit, text.len);
    while (end > 0 and end < text.len and (text[end] & 0xC0) == 0x80) end -= 1;
    return end;
}

fn lineTruncatedSuffix(buffer: []u8, line_number: usize, continue_column: usize) []const u8 {
    return std.fmt.bufPrint(
        buffer,
        line_truncated_marker ++ "; pass start_line={d}, column_offset={d} to continue it)",
        .{ line_number, continue_column },
    ) catch line_truncated_marker ++ ")";
}

fn selectLinesFromContent(
    alloc: Allocator,
    content: []const u8,
    input: *const Input,
    max_line_len: usize,
    records: *std.ArrayList(LineRecord),
) !ReadScan {
    var selection = LineSelectionState{
        .alloc = alloc,
        .input = input,
        .max_line_len = max_line_len,
        .records = records,
    };
    var line_number: usize = 1;
    var total_lines: usize = 0;

    var start: usize = 0;
    while (start < content.len) : (line_number += 1) {
        const end = std.mem.findScalarPos(u8, content, start, '\n') orelse content.len;
        const line = content[start..end];
        total_lines = line_number;
        try selection.keepLine(line_number, line);
        if (end == content.len) break;
        start = end + 1;
    }

    return .{
        .total_lines = total_lines,
        .display_truncated = selection.display_truncated,
        .stopped_early = selection.stop_display,
        .lines_cut = selection.lines_cut,
    };
}

fn modelViewCoversFullFile(input: *const Input, scan: ReadScan, returned_lines: usize) bool {
    return !scan.display_truncated and input.start_line == 1 and input.column_offset == 0 and returned_lines == scan.total_lines;
}

fn tailStartLine(content: []const u8, tail_lines: usize) usize {
    var total: usize = 0;
    for (content) |byte| total += @intFromBool(byte == '\n');
    if (content.len > 0 and content[content.len - 1] != '\n') total += 1;
    return if (total > tail_lines) total - tail_lines + 1 else 1;
}

const ReadOutcome = struct {
    content_hash: read_tracker.ContentHash,
    model_view_covers_full_file: bool,
    snapshot_covers_full_file: bool,
    served_range: ?read_tracker.ViewRange,
};

fn recordSuccessfulRead(
    ctx: tool_dispatch.DispatchContext,
    path: []const u8,
    stat: std.Io.File.Stat,
    outcome: ReadOutcome,
) tool_dispatch.DispatchError!void {
    const tracker = ctx.read_tracker orelse return;
    try tracker.record(path, .{
        .mtime_ns = stat.mtime.nanoseconds,
        .content_hash = outcome.content_hash,
        .model_view_covers_full_file = outcome.model_view_covers_full_file,
        .snapshot_covers_full_file = outcome.snapshot_covers_full_file,
        .size_bytes = stat.size,
        .served = if (outcome.served_range) |range| .{ .range = range, .step = tracker.currentStep() } else null,
    });
}

fn formatReadOutput(
    alloc: Allocator,
    rel: []const u8,
    input: *const Input,
    records: []const LineRecord,
    scan: ReadScan,
    snapshot_covers_full_file: bool,
    facts: file_facts.Facts,
) tool_dispatch.DispatchError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    out.writer.print("<path>{s}</path>\n<content>\n" ++ file_facts_prefix, .{rel}) catch return error.OutOfMemory;
    file_facts.write(&out.writer, facts) catch return error.OutOfMemory;
    out.writer.writeAll("]\n") catch return error.OutOfMemory;
    if (records.len > 0) {
        writeRecords(&out.writer, records) catch return error.OutOfMemory;
    } else if (scan.total_lines > 0 and input.start_line > scan.total_lines) {
        out.writer.print("... [start_line {d} is beyond end of file; total lines {d}]\n", .{ input.start_line, scan.total_lines }) catch return error.OutOfMemory;
    }

    const include_sentinel = !modelViewCoversFullFile(input, scan, records.len) or !snapshot_covers_full_file;
    if (include_sentinel and (records.len > 0 or scan.display_truncated)) {
        writeTruncationSentinel(&out.writer, .{
            .shown_lines = records.len,
            .total_lines = scan.total_lines,
            .last_shown_line = if (records.len > 0) records[records.len - 1].number else null,
            .start_line = input.start_line,
            .lines_cut = scan.lines_cut,
            .snapshot_covers_full_file = snapshot_covers_full_file,
        }) catch return error.OutOfMemory;
    }
    out.writer.writeAll("</content>") catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

const SentinelFacts = struct {
    shown_lines: usize,
    total_lines: usize,
    last_shown_line: ?usize,
    start_line: usize,
    lines_cut: bool,
    snapshot_covers_full_file: bool,
};

fn writeTruncationSentinel(writer: *std.Io.Writer, facts: SentinelFacts) !void {
    if (!facts.snapshot_covers_full_file) {
        try writer.print("... [showing {d} of at least {d} lines; file snapshot was capped before EOF.]\n", .{ facts.shown_lines, facts.total_lines });
        return;
    }
    const last_shown_line = facts.last_shown_line orelse {
        try writer.print(
            "... [showing 0 of {d} lines; line {d} does not fit max_chars; raise max_chars or pass start_line={d} with a column_offset.]\n",
            .{ facts.total_lines, facts.start_line, facts.start_line },
        );
        return;
    };
    try writer.print("... [showing {d} of {d} lines; ", .{ facts.shown_lines, facts.total_lines });
    if (last_shown_line < facts.total_lines) {
        try writer.print("{d} more after line {d}; pass start_line={d} to continue", .{
            facts.total_lines - last_shown_line,
            last_shown_line,
            last_shown_line + 1,
        });
    } else {
        try writer.print("the read ends at the last line, {d}", .{last_shown_line});
    }
    if (facts.lines_cut) try writer.writeAll("; each cut line names the column_offset that continues it");
    try writer.writeAll(".]\n");
}

fn writeRecords(writer: *std.Io.Writer, records: []const LineRecord) !void {
    const width = digitCount(records[records.len - 1].number);
    try writeRecordsWithWidth(writer, records, width);
}

fn writeRecordsWithWidth(writer: *std.Io.Writer, records: []const LineRecord, width: usize) !void {
    for (records) |record| {
        try writer.print("{d}", .{record.number});
        var pad = width - digitCount(record.number);
        while (pad > 0) : (pad -= 1) try writer.writeByte(' ');
        try writer.writeByte('\t');
        try writer.writeAll(record.text);
        try writer.writeByte('\n');
    }
}

fn renderedLineBytes(width: usize, text_len: usize) usize {
    return width + 1 + text_len + 1;
}

fn freeLineRecords(alloc: Allocator, records: *std.ArrayList(LineRecord)) void {
    clearLineRecords(alloc, records);
    records.deinit(alloc);
}

fn clearLineRecords(alloc: Allocator, records: *std.ArrayList(LineRecord)) void {
    for (records.items) |record| alloc.free(record.text);
    records.clearRetainingCapacity();
}

fn digitCount(value: usize) usize {
    var n = value;
    var count: usize = 1;
    while (n >= 10) : (n /= 10) count += 1;
    return count;
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

const read_file_dispatch_tool = tool_dispatch.Tool{
    .name = "read_file",
    .description = "Read file dispatch test fixture.",
    .model_schema = .{
        .name = "read_file",
        .description = "Read file dispatch test fixture.",
    },
    .executor_kind = .read_file,
    .activity_kind = .read,
    .permission_target_kind = .path_existing,
    .decode = decode,
    .validate = validate,
    .call = call,
    .reads_only_fn = readsOnly,
    .irreversible_fn = isIrreversible,
};

fn dispatchReadFileInWorkspace(alloc: Allocator, workspace_root: []const u8, args_json: []const u8) !tool_dispatch.DispatchResult {
    const registry = tool_dispatch.Registry{ .tools = &.{read_file_dispatch_tool} };
    return tool_dispatch.dispatchToolCall(.{ .allocator = alloc, .permission_mode = .auto, .workspace_root = workspace_root }, registry, .{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = args_json,
    });
}

fn dispatchReadFile(alloc: Allocator, args_json: []const u8) !tool_dispatch.DispatchResult {
    return dispatchReadFileInWorkspace(alloc, "", args_json);
}

fn dispatchReadFileWithTrackerInWorkspace(alloc: Allocator, workspace_root: []const u8, args_json: []const u8, tracker: *read_tracker.ReadTracker) !tool_dispatch.DispatchResult {
    const registry = tool_dispatch.Registry{ .tools = &.{read_file_dispatch_tool} };
    return tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .permission_mode = .auto,
        .workspace_root = workspace_root,
        .read_tracker = tracker,
    }, registry, .{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = args_json,
    });
}

fn dispatchReadFileWithTrackerInWorkspaceWithLimits(alloc: Allocator, args_json: []const u8, tracker: *read_tracker.ReadTracker, max_lines: usize) !tool_dispatch.DispatchResult {
    const registry = tool_dispatch.Registry{ .tools = &.{read_file_dispatch_tool} };
    return tool_dispatch.dispatchToolCall(.{
        .allocator = alloc,
        .permission_mode = .auto,
        .workspace_root = "",
        .read_tracker = tracker,
        .max_read_file_lines = max_lines,
    }, registry, .{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = args_json,
    });
}

fn dispatchReadFileWithTracker(alloc: Allocator, args_json: []const u8, tracker: *read_tracker.ReadTracker) !tool_dispatch.DispatchResult {
    return dispatchReadFileWithTrackerInWorkspace(alloc, "", args_json, tracker);
}

fn tmpPath(alloc: Allocator, tmp: std.testing.TmpDir, sub_path: []const u8) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, sub_path);
}

fn workspaceRoot(alloc: Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
}

fn readAbsolute(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 1024 * 1024);
}

fn noopInputDeinit(_: *anyopaque, _: Allocator) void {}

fn validateStackInput(alloc: Allocator, input: *Input, workspace_root: []const u8) !?[]u8 {
    return validate(.{ .allocator = alloc, .workspace_root = workspace_root }, .{ .ptr = input, .deinit_fn = noopInputDeinit });
}

const paged_fixture_line = text_utils.repeat("x", 63) ++ "\n";

fn longLineText(alloc: Allocator, line_count: usize) ![]u8 {
    return repeatedLines(alloc, paged_fixture_line, line_count);
}

fn repeatedLines(alloc: Allocator, line: []const u8, line_count: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var i: usize = 0;
    while (i < line_count) : (i += 1) {
        try out.appendSlice(alloc, line);
    }
    return try out.toOwnedSlice(alloc);
}

fn withoutFileFacts(alloc: Allocator, body: []const u8) ![]u8 {
    const start = std.mem.find(u8, body, file_facts_prefix) orelse return alloc.dupe(u8, body);
    const end = std.mem.findScalarPos(u8, body, start, '\n') orelse return error.TestUnexpectedResult;
    return std.mem.concat(alloc, u8, &.{ body[0..start], body[end + 1 ..] });
}

fn expectReadBody(expected: []const u8, body: []const u8) !void {
    const stripped = try withoutFileFacts(std.testing.allocator, body);
    defer std.testing.allocator.free(stripped);
    try std.testing.expectEqualStrings(expected, stripped);
}

fn writeTestFile(tmp: std.testing.TmpDir, name: []const u8, content: []const u8) !void {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = content });
}

fn pathArgs(alloc: Allocator, path: []const u8, extra_fields: []const u8) ![]u8 {
    return alloc.print("{{\"path\":\"{s}\"{s}}}", .{ path, extra_fields });
}

fn createTestSymlinkOrSkip(dir: std.Io.Dir, target_path: []const u8, link_path: []const u8) !void {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    dir.symLink(io_mod.getIo(), target_path, link_path, .{ .is_directory = false }) catch |err| {
        if (err == error.AccessDenied or std.mem.eql(u8, @errorName(err), "PermissionDenied")) {
            return error.SkipZigTest;
        }
        return err;
    };
}

test "read_file reads workspace-relative path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "notes");
    {
        var file = try tmp.dir.createFile(std.testing.io, "notes/today.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "hello\n");
    }
    const workspace = try workspaceRoot(alloc, tmp);
    defer alloc.free(workspace);
    const args = try alloc.print("{{\"path\":\"{s}\"}}", .{"notes/today.txt"});
    defer alloc.free(args);

    const result = try dispatchReadFileInWorkspace(alloc, workspace, args);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    try expectReadBody("<path>notes/today.txt</path>\n<content>\n1\thello\n</content>", result.body);
    try std.testing.expect(result.tool_result_memory.?.model_view_covers_full_file.?);
}

test "read_file external absolute path preserves absolute display" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    {
        var file = try tmp.dir.createFile(std.testing.io, "external.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "outside\n");
    }
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const external = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "external.txt");
    defer alloc.free(external);
    const args = try alloc.print("{{\"path\":\"{s}\"}}", .{external});
    defer alloc.free(args);

    const result = try dispatchReadFileInWorkspace(alloc, workspace, args);
    defer result.deinit(std.testing.allocator);

    const expected = try alloc.print("<path>{s}</path>\n<content>\n1\toutside\n</content>", .{external});
    defer alloc.free(expected);
    try std.testing.expectEqual(.success, result.status);
    try expectReadBody(expected, result.body);
}

test "read_file access denial returns structured recovery" {
    const alloc = std.testing.allocator;
    const result = try readFileFailure(alloc, error.AccessDenied, "/tmp/blocked/read.txt");
    switch (result) {
        .rich => return error.TestUnexpectedRichResult,
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expect(tool_result_errors.isToolExecutionFailedOutput(body));
            try std.testing.expect(std.mem.find(u8, body, "\"tool_name\":\"read_file\"") != null);
            try std.testing.expect(std.mem.find(u8, body, "/tmp/blocked/read.txt") != null);
            try std.testing.expect(std.mem.find(u8, body, "AccessDenied") != null);
            try std.testing.expect(std.mem.find(u8, body, "symlink") != null);
        },
        .success => |body| {
            defer alloc.free(body);
            try std.testing.expect(false);
        },
    }
}

test "read_file non-regular paths return structured recovery" {
    const alloc = std.testing.allocator;
    const result = try readFileFailure(alloc, error.NotRegularFile, "/tmp/search-pipe");
    switch (result) {
        .rich => return error.TestUnexpectedRichResult,
        .failure => |body| {
            defer alloc.free(body);
            try std.testing.expect(tool_result_errors.isToolExecutionFailedOutput(body));
            try std.testing.expect(std.mem.find(u8, body, "read_file requires a regular file") != null);
            try std.testing.expect(std.mem.find(u8, body, "NotRegularFile") != null);
            try std.testing.expect(std.mem.find(u8, body, "glob_files") != null);
        },
        .success => |body| {
            defer alloc.free(body);
            try std.testing.expect(false);
        },
    }
}

test "read_file validation keeps active path-only surface" {
    const alloc = std.testing.allocator;
    var input = Input{ .path = try alloc.dupe(u8, " /tmp/report.PDF ") };
    defer input.deinit(alloc);

    try std.testing.expect((try validateStackInput(alloc, &input, "/tmp/workspace")) == null);
    try std.testing.expectEqualStrings("/tmp/report.PDF", input.path);
}

test "read_file trims leading and trailing whitespace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "file.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "hello\n");
    }
    const path = try tmpPath(std.testing.allocator, tmp, "file.txt");
    defer std.testing.allocator.free(path);
    const args = try std.testing.allocator.print("{{\"path\":\"  {s}  \"}}", .{path});
    defer std.testing.allocator.free(args);

    const result = try dispatchReadFile(std.testing.allocator, args);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    const expected = try std.testing.allocator.print("<path>{s}</path>\n<content>\n1\thello\n</content>", .{path});
    defer std.testing.allocator.free(expected);
    try expectReadBody(expected, result.body);
}

test "read_file honors line range fields and uses active output shape" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "file.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "one\ntwo\nthree\n");
    }
    const path = try tmpPath(std.testing.allocator, tmp, "file.txt");
    defer std.testing.allocator.free(path);
    const args = try std.testing.allocator.print("{{\"path\":\"{s}\",\"start_line\":2,\"line_count\":2}}", .{path});
    defer std.testing.allocator.free(args);

    const result = try dispatchReadFile(std.testing.allocator, args);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    const expected = try std.testing.allocator.print("<path>{s}</path>\n<content>\n2\ttwo\n3\tthree\n... [showing 2 of 3 lines; the read ends at the last line, 3.]\n</content>", .{path});
    defer std.testing.allocator.free(expected);
    try expectReadBody(expected, result.body);
}

test "read_file rejects Kimi range shapes outside their bounds" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        json: []const u8,
        reason: []const u8,
    }{
        .{ .json = "{\"path\":\"f.txt\",\"line_offset\":0}", .reason = "read_file field \"line_offset\" must be a non-zero integer; negative values read from the end of the file" },
        .{ .json = "{\"path\":\"f.txt\",\"line_offset\":2,\"start_line\":1}", .reason = "read_file accepts start_line or line_offset, not both" },
        .{ .json = "{\"path\":\"f.txt\",\"column_offset\":-1}", .reason = "read_file field \"column_offset\" must be a non-negative integer" },
        .{ .json = "{\"path\":\"f.txt\",\"n_lines\":0}", .reason = "read_file field \"n_lines\" must be a positive integer" },
        .{ .json = "{\"path\":\"f.txt\",\"max_chars\":0}", .reason = "read_file field \"max_chars\" must be a positive integer" },
    };

    for (cases) |case| {
        const decoded = try decode(.{ .allocator = alloc }, case.json);
        switch (decoded) {
            .failure => |reason| {
                defer alloc.free(reason);
                try std.testing.expectEqualStrings(case.reason, reason);
            },
            .input => |erased| {
                erased.deinit(alloc);
                return error.TestExpectedDecodeFailure;
            },
        }
    }
}

test "read_file decodes line_offset, column_offset, n_lines, and max_chars onto the selection" {
    const alloc = std.testing.allocator;
    const forward = try decode(.{ .allocator = alloc }, "{\"path\":\"f.txt\",\"line_offset\":4}");
    const forward_input = switch (forward) {
        .input => |erased| erased,
        .failure => |reason| {
            defer alloc.free(reason);
            return error.TestExpectedDecodedInput;
        },
    };
    defer forward_input.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 4), forward_input.as(Input).start_line);
    try std.testing.expect(forward_input.as(Input).tail_lines == null);

    const tail = try decode(.{ .allocator = alloc }, "{\"path\":\"f.txt\",\"line_offset\":-3}");
    const tail_input = switch (tail) {
        .input => |erased| erased,
        .failure => |reason| {
            defer alloc.free(reason);
            return error.TestExpectedDecodedInput;
        },
    };
    defer tail_input.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), tail_input.as(Input).tail_lines.?);

    const bounded = try decode(.{ .allocator = alloc }, "{\"path\":\"f.txt\",\"column_offset\":2,\"n_lines\":5,\"max_chars\":99999999}");
    const bounded_input = switch (bounded) {
        .input => |erased| erased,
        .failure => |reason| {
            defer alloc.free(reason);
            return error.TestExpectedDecodedInput;
        },
    };
    defer bounded_input.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), bounded_input.as(Input).column_offset);
    try std.testing.expectEqual(@as(usize, 5), bounded_input.as(Input).line_count);
    try std.testing.expectEqual(max_model_output_bytes, bounded_input.as(Input).max_chars);
}

test "read_file line_offset negative reads the tail of the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "file.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "a\nb\nc\nd\n");
    }
    const path = try tmpPath(std.testing.allocator, tmp, "file.txt");
    defer std.testing.allocator.free(path);
    const args = try std.testing.allocator.print("{{\"path\":\"{s}\",\"line_offset\":-2}}", .{path});
    defer std.testing.allocator.free(args);

    const result = try dispatchReadFile(std.testing.allocator, args);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    const expected = try std.testing.allocator.print("<path>{s}</path>\n<content>\n3\tc\n4\td\n... [showing 2 of 4 lines; the read ends at the last line, 4.]\n</content>", .{path});
    defer std.testing.allocator.free(expected);
    try expectReadBody(expected, result.body);
}

test "read_file column_offset starts the first line mid-line and n_lines bounds the read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "file.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "abcdef\nxyz\nlast\n");
    }
    const path = try tmpPath(std.testing.allocator, tmp, "file.txt");
    defer std.testing.allocator.free(path);
    const args = try std.testing.allocator.print("{{\"path\":\"{s}\",\"column_offset\":2,\"n_lines\":2}}", .{path});
    defer std.testing.allocator.free(args);

    const result = try dispatchReadFile(std.testing.allocator, args);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    const expected = try std.testing.allocator.print("<path>{s}</path>\n<content>\n1\tcdef\n2\txyz\n... [showing 2 of 3 lines; 1 more after line 2; pass start_line=3 to continue.]\n</content>", .{path});
    defer std.testing.allocator.free(expected);
    try expectReadBody(expected, result.body);
}

test "read_file max_chars bounds the rendered output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "file.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "aaaa\naaaa\naaaa\n");
    }
    const path = try tmpPath(std.testing.allocator, tmp, "file.txt");
    defer std.testing.allocator.free(path);
    const args = try std.testing.allocator.print("{{\"path\":\"{s}\",\"max_chars\":12}}", .{path});
    defer std.testing.allocator.free(args);

    const result = try dispatchReadFile(std.testing.allocator, args);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    const expected = try std.testing.allocator.print("<path>{s}</path>\n<content>\n1\taaaa\n... [showing 1 of 3 lines; 2 more after line 1; pass start_line=2 to continue.]\n</content>", .{path});
    defer std.testing.allocator.free(expected);
    try expectReadBody(expected, result.body);
}

test "read_file omits binary content using active success output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "binary.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "hello\x00world\n");
    }
    const path = try tmpPath(std.testing.allocator, tmp, "binary.txt");
    defer std.testing.allocator.free(path);
    const args = try std.testing.allocator.print("{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);

    const result = try dispatchReadFile(std.testing.allocator, args);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "binary or non-utf8 file omitted") != null);
    try std.testing.expect(!result.tool_result_memory.?.model_view_covers_full_file.?);
}

const test_png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

fn writeTestImage(dir: std.Io.Dir, name: []const u8, base64: []const u8) !void {
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(base64);
    const bytes = try std.testing.allocator.alloc(u8, size);
    defer std.testing.allocator.free(bytes);
    try decoder.decode(bytes, base64);
    var file = try dir.createFile(std.testing.io, name, .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), bytes);
}

test "read_file attaches a png image to the tool result" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(tmp.dir, "pixel.png", test_png_base64);
    const path = try tmpPath(std.testing.allocator, tmp, "pixel.png");
    defer std.testing.allocator.free(path);
    const args = try std.testing.allocator.print("{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);

    const result = try dispatchReadFile(std.testing.allocator, args);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "image attached (image/png") != null);
    try std.testing.expectEqual(@as(usize, 1), result.images.len);
    try std.testing.expectEqualStrings("image/png", result.images[0].mime_type);
    try std.testing.expectEqualStrings(test_png_base64, result.images[0].data);
    try std.testing.expect(result.tool_result_memory.?.model_view_covers_full_file.?);
}

test "read_file detects images by magic bytes regardless of extension" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestImage(tmp.dir, "pixel.bin", test_png_base64);
    const path = try tmpPath(std.testing.allocator, tmp, "pixel.bin");
    defer std.testing.allocator.free(path);
    const args = try std.testing.allocator.print("{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);

    const result = try dispatchReadFile(std.testing.allocator, args);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqual(@as(usize, 1), result.images.len);
    try std.testing.expectEqualStrings("image/png", result.images[0].mime_type);
}

test "read_file reports images over the attach limit without pixels" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "big.png", .{});
        defer file.close(io_mod.getIo());
        const header = "\x89PNG\r\n\x1a\n".*;
        try file.writeStreamingAll(io_mod.getIo(), &header);
        var remaining: usize = max_attach_image_bytes + 1 - header.len;
        var filler: [8192]u8 = @splat(0xAB);
        while (remaining > 0) {
            const chunk = @min(remaining, filler.len);
            try file.writeStreamingAll(io_mod.getIo(), filler[0..chunk]);
            remaining -= chunk;
        }
    }
    const path = try tmpPath(std.testing.allocator, tmp, "big.png");
    defer std.testing.allocator.free(path);
    const args = try std.testing.allocator.print("{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);

    const result = try dispatchReadFile(std.testing.allocator, args);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "image not attached") != null);
    try std.testing.expectEqual(@as(usize, 0), result.images.len);
    try std.testing.expect(!result.tool_result_memory.?.model_view_covers_full_file.?);
}

fn writeTestPngHeader(dir: std.Io.Dir, name: []const u8, width: u32, height: u32) !void {
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = &image_data.testPngHeader(width, height) });
}

test "read_file attaches a PNG within the single request limit unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestPngHeader(tmp.dir, "frame.png", 3420, 2224);
    const path = try tmpPath(std.testing.allocator, tmp, "frame.png");
    defer std.testing.allocator.free(path);
    const args = try std.testing.allocator.print("{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);

    const result = try dispatchReadFile(std.testing.allocator, args);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "image attached (image/png") != null);
    try std.testing.expectEqual(@as(usize, 1), result.images.len);
}

test "read_file attaches a JPEG that fits the single request limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "photo.jpg", .data = &image_data.testJpeg(4032, 3024) });
    const path = try tmpPath(std.testing.allocator, tmp, "photo.jpg");
    defer std.testing.allocator.free(path);
    const args = try std.testing.allocator.print("{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);

    const result = try dispatchReadFile(std.testing.allocator, args);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "image attached (image/jpeg") != null);
    try std.testing.expectEqual(@as(usize, 1), result.images.len);
    try std.testing.expectEqual(@as(?image_data.Dimensions, .{ .width = 4032, .height = 3024 }), image_data.encodedImageDimensions(result.images[0].data));
    try std.testing.expect(result.tool_result_memory.?.model_view_covers_full_file.?);
}

test "read_file keeps a byte-oversized PNG at its source path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const png = try png_downscale.testSolidGrayPng(alloc, 2400, 8, 128);
    defer alloc.free(png);
    const padded = try png_downscale.testPaddedPng(alloc, png, image_data.max_encoded_image_bytes);
    defer alloc.free(padded);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "padded.png", .data = padded });
    const path = try tmpPath(alloc, tmp, "padded.png");
    defer alloc.free(path);
    const args = try alloc.print("{{\"path\":\"{s}\"}}", .{path});
    defer alloc.free(args);

    const result = try dispatchReadFile(alloc, args);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "image exceeds the 5 MiB encoded attach limit") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "<path>") != null);
    try std.testing.expectEqual(@as(usize, 0), result.images.len);
    try std.testing.expect(!result.tool_result_memory.?.model_view_covers_full_file.?);
}

test "read_file attaches an image exactly at the model pixel limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestPngHeader(tmp.dir, "edge.png", image_data.max_single_image_dimension, image_data.max_single_image_dimension);
    const path = try tmpPath(std.testing.allocator, tmp, "edge.png");
    defer std.testing.allocator.free(path);
    const args = try std.testing.allocator.print("{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);

    const result = try dispatchReadFile(std.testing.allocator, args);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "image attached (image/png") != null);
    try std.testing.expectEqual(@as(usize, 1), result.images.len);
}

test "read_file gives an actionable path for an image over 8000 pixels" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestPngHeader(tmp.dir, "huge.png", 8001, 1);
    const path = try tmpPath(std.testing.allocator, tmp, "huge.png");
    defer std.testing.allocator.free(path);
    const args = try std.testing.allocator.print("{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);
    const result = try dispatchReadFile(std.testing.allocator, args);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "image exceeds 8000 pixels per side") != null);
    try std.testing.expect(std.mem.find(u8, result.body, path) != null);
    try std.testing.expectEqual(@as(usize, 0), result.images.len);
}

test "read_file reports start_line beyond file length" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "file.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "one\ntwo\n");
    }
    const path = try tmpPath(std.testing.allocator, tmp, "file.txt");
    defer std.testing.allocator.free(path);
    const args = try std.testing.allocator.print("{{\"path\":\"{s}\",\"start_line\":5}}", .{path});
    defer std.testing.allocator.free(args);

    const result = try dispatchReadFile(std.testing.allocator, args);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    const expected = try std.testing.allocator.print("<path>{s}</path>\n<content>\n... [start_line 5 is beyond end of file; total lines 2]\n</content>", .{path});
    defer std.testing.allocator.free(expected);
    try expectReadBody(expected, result.body);
    try std.testing.expect(!result.tool_result_memory.?.model_view_covers_full_file.?);
}

test "read_file reports empty file as success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "empty.txt", .{});
        defer file.close(io_mod.getIo());
    }
    const path = try tmpPath(std.testing.allocator, tmp, "empty.txt");
    defer std.testing.allocator.free(path);
    const args = try std.testing.allocator.print("{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);

    const result = try dispatchReadFile(std.testing.allocator, args);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    const expected = try std.testing.allocator.print("<path>{s}</path>\n<content>\n</content>", .{path});
    defer std.testing.allocator.free(expected);
    try expectReadBody(expected, result.body);
}

test "read_file reports capped snapshots for oversized text files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try std.testing.allocator.alloc(u8, max_snapshot_file_bytes + 1);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'x');
    {
        var file = try tmp.dir.createFile(std.testing.io, "large.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), bytes);
    }
    const path = try tmpPath(std.testing.allocator, tmp, "large.txt");
    defer std.testing.allocator.free(path);
    const args = try std.testing.allocator.print("{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);

    const result = try dispatchReadFile(std.testing.allocator, args);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "file snapshot was capped before EOF") != null);
}

test "read_file sparse oversized files use active byte cap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "too-large.txt", .{});
        defer file.close(io_mod.getIo());
        try file.setLength(io_mod.getIo(), max_snapshot_file_bytes + 1);
    }
    const path = try tmpPath(std.testing.allocator, tmp, "too-large.txt");
    defer std.testing.allocator.free(path);
    const args = try std.testing.allocator.print("{{\"path\":\"{s}\"}}", .{path});
    defer std.testing.allocator.free(args);

    const result = try dispatchReadFile(std.testing.allocator, args);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "binary or non-utf8 file omitted") != null);
}

test "read_file materializes ENOENT like active tool error output" {
    const result = try dispatchReadFile(std.testing.allocator, "{\"path\":\"/tmp/fx-core-read-file-missing\"}");
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(.failure, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "\"type\":\"tool_execution_failed\"") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "\"tool_name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "\"error\":\"FileNotFound\"") != null);
}

test "read_file classifiers are read-only and reversible" {
    const input = try std.testing.allocator.create(Input);
    input.* = .{ .path = try std.testing.allocator.dupe(u8, "/tmp/file.txt") };
    const erased = tool_dispatch.ToolInput{ .ptr = input, .deinit_fn = inputDeinit };
    defer erased.deinit(std.testing.allocator);

    try std.testing.expect(readsOnly(erased));
    try std.testing.expect(!isIrreversible(erased));
}

test "read_file records display-truncated reads with complete snapshot when possible" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = try alloc.alloc(u8, max_model_output_bytes + 128);
    defer alloc.free(content);
    @memset(content, 'a');
    {
        var file = try tmp.dir.createFile(std.testing.io, "between-caps.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), content);
    }
    const path = try tmpPath(alloc, tmp, "between-caps.txt");
    defer alloc.free(path);
    const args = try alloc.print("{{\"path\":\"{s}\"}}", .{path});
    defer alloc.free(args);
    var tracker = read_tracker.ReadTracker.init(alloc);
    defer tracker.deinit();

    const result = try dispatchReadFileWithTracker(alloc, args, &tracker);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, line_truncated_marker) != null);
    const record = tracker.lookup(path).?;
    try std.testing.expect(!record.model_view_covers_full_file);
    try std.testing.expect(record.snapshot_covers_full_file);
    try std.testing.expectEqualSlices(u8, &read_tracker.contentHash(content), &record.content_hash);
}

test "read_file records full coverage for files within both caps" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = "one\ntwo\n";
    {
        var file = try tmp.dir.createFile(std.testing.io, "small.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), content);
    }
    const path = try tmpPath(alloc, tmp, "small.txt");
    defer alloc.free(path);
    const args = try alloc.print("{{\"path\":\"{s}\"}}", .{path});
    defer alloc.free(args);
    var tracker = read_tracker.ReadTracker.init(alloc);
    defer tracker.deinit();

    const result = try dispatchReadFileWithTracker(alloc, args, &tracker);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    const record = tracker.lookup(path).?;
    try std.testing.expect(record.model_view_covers_full_file);
    try std.testing.expect(record.snapshot_covers_full_file);
    try std.testing.expectEqualSlices(u8, &read_tracker.contentHash(content), &record.content_hash);
}

test "read_file display budget tracks line number width growth" {
    const alloc = std.testing.allocator;
    var records: std.ArrayList(LineRecord) = .empty;
    defer freeLineRecords(alloc, &records);
    const input = Input{ .path = &.{}, .start_line = 1, .line_count = max_line_count };
    var selection = LineSelectionState{
        .alloc = alloc,
        .input = &input,
        .max_line_len = max_model_output_bytes,
        .records = &records,
    };

    try selection.keepLine(9, "aa");
    try std.testing.expect(!selection.display_truncated);
    try std.testing.expectEqual(@as(usize, 1), selection.budget.width);
    try std.testing.expectEqual(renderedLineBytes(1, "aa".len), selection.budget.bytes);

    try selection.keepLine(10, "bbb");
    try std.testing.expect(!selection.display_truncated);
    try std.testing.expectEqual(@as(usize, 2), selection.budget.width);
    try std.testing.expectEqual(renderedLineBytes(2, "aa".len) + renderedLineBytes(2, "bbb".len), selection.budget.bytes);
}

test "read_file records full-file hash for successful full read" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "file.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "one\ntwo\n");
    }
    const path = try tmpPath(alloc, tmp, "file.txt");
    defer alloc.free(path);
    const args = try alloc.print("{{\"path\":\"{s}\"}}", .{path});
    defer alloc.free(args);
    var tracker = read_tracker.ReadTracker.init(alloc);
    defer tracker.deinit();

    const result = try dispatchReadFileWithTracker(alloc, args, &tracker);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    const record = tracker.lookup(path).?;
    try std.testing.expect(record.model_view_covers_full_file);
    try std.testing.expect(record.snapshot_covers_full_file);
    try std.testing.expectEqualSlices(u8, &read_tracker.contentHash("one\ntwo\n"), &record.content_hash);
}

test "read_file line range fields narrow model view but preserve full snapshot" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "file.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "one\ntwo\nthree\n");
    }
    const path = try tmpPath(alloc, tmp, "file.txt");
    defer alloc.free(path);
    const args = try alloc.print("{{\"path\":\"{s}\",\"start_line\":2,\"line_count\":1}}", .{path});
    defer alloc.free(args);
    var tracker = read_tracker.ReadTracker.init(alloc);
    defer tracker.deinit();

    const result = try dispatchReadFileWithTracker(alloc, args, &tracker);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    const record = tracker.lookup(path).?;
    try std.testing.expect(!record.model_view_covers_full_file);
    try std.testing.expect(record.snapshot_covers_full_file);
    try std.testing.expectEqualSlices(u8, &read_tracker.contentHash("one\ntwo\nthree\n"), &record.content_hash);
}

test "read_file records capped default reads as truncated model view" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = try longLineText(alloc, tool_dispatch.default_max_read_file_lines + 1);
    defer alloc.free(content);
    {
        var file = try tmp.dir.createFile(std.testing.io, "long.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), content);
    }
    const path = try tmpPath(alloc, tmp, "long.txt");
    defer alloc.free(path);
    const args = try alloc.print("{{\"path\":\"{s}\"}}", .{path});
    defer alloc.free(args);
    var tracker = read_tracker.ReadTracker.init(alloc);
    defer tracker.deinit();

    const result = try dispatchReadFileWithTracker(alloc, args, &tracker);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(!tracker.lookup(path).?.model_view_covers_full_file);
    try std.testing.expect(tracker.lookup(path).?.snapshot_covers_full_file);
}

test "read_file records exact default cap as full" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var content_buf: std.ArrayList(u8) = .empty;
    defer content_buf.deinit(alloc);
    var i: usize = 0;
    while (i < tool_dispatch.default_max_read_file_lines) : (i += 1) {
        if (i != 0) try content_buf.append(alloc, '\n');
        try content_buf.append(alloc, 'x');
    }
    const content = content_buf.items;
    {
        var file = try tmp.dir.createFile(std.testing.io, "exact.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), content);
    }
    const path = try tmpPath(alloc, tmp, "exact.txt");
    defer alloc.free(path);
    const args = try alloc.print("{{\"path\":\"{s}\"}}", .{path});
    defer alloc.free(args);
    var tracker = read_tracker.ReadTracker.init(alloc);
    defer tracker.deinit();

    const result = try dispatchReadFileWithTracker(alloc, args, &tracker);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(tracker.lookup(path).?.model_view_covers_full_file);
    try std.testing.expect(tracker.lookup(path).?.snapshot_covers_full_file);
}

test "read_file preserves complete snapshot for truncated model view" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = try longLineText(alloc, tool_dispatch.default_max_read_file_lines + 1);
    defer alloc.free(content);
    {
        var file = try tmp.dir.createFile(std.testing.io, "long.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), content);
    }
    const path = try tmpPath(alloc, tmp, "long.txt");
    defer alloc.free(path);
    const read_args = try alloc.print("{{\"path\":\"{s}\"}}", .{path});
    defer alloc.free(read_args);
    var tracker = read_tracker.ReadTracker.init(alloc);
    defer tracker.deinit();

    const read_result = try dispatchReadFileWithTracker(alloc, read_args, &tracker);
    defer read_result.deinit(alloc);
    try std.testing.expectEqual(.success, read_result.status);
    try std.testing.expect(!tracker.lookup(path).?.model_view_covers_full_file);
    try std.testing.expect(tracker.lookup(path).?.snapshot_covers_full_file);

    const after = try readAbsolute(alloc, path);
    defer alloc.free(after);
    try std.testing.expectEqualStrings(content, after);
}

test "read_file records empty and beyond-end successes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var empty = try tmp.dir.createFile(std.testing.io, "empty.txt", .{});
        defer empty.close(io_mod.getIo());
        var file = try tmp.dir.createFile(std.testing.io, "file.txt", .{});
        defer file.close(io_mod.getIo());
        try file.writeStreamingAll(io_mod.getIo(), "one\n");
    }
    const empty_path = try tmpPath(alloc, tmp, "empty.txt");
    defer alloc.free(empty_path);
    const file_path = try tmpPath(alloc, tmp, "file.txt");
    defer alloc.free(file_path);
    const empty_args = try alloc.print("{{\"path\":\"{s}\"}}", .{empty_path});
    defer alloc.free(empty_args);
    const beyond_args = try alloc.print("{{\"path\":\"{s}\",\"start_line\":5}}", .{file_path});
    defer alloc.free(beyond_args);
    var tracker = read_tracker.ReadTracker.init(alloc);
    defer tracker.deinit();

    var empty_result = try dispatchReadFileWithTracker(alloc, empty_args, &tracker);
    defer empty_result.deinit(alloc);
    var beyond_result = try dispatchReadFileWithTracker(alloc, beyond_args, &tracker);
    defer beyond_result.deinit(alloc);

    try std.testing.expectEqual(.success, empty_result.status);
    try std.testing.expectEqual(.success, beyond_result.status);
    const empty_record = tracker.lookup(empty_path).?;
    try std.testing.expect(empty_record.model_view_covers_full_file);
    try std.testing.expect(empty_record.snapshot_covers_full_file);
    try std.testing.expectEqualSlices(u8, &read_tracker.contentHash(""), &empty_record.content_hash);
    const beyond_record = tracker.lookup(file_path).?;
    try std.testing.expect(!beyond_record.model_view_covers_full_file);
    try std.testing.expect(beyond_record.snapshot_covers_full_file);
}

test "read_file returns a whole file past the paged line default when it fits inline" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const line_total = tool_dispatch.default_max_read_file_lines + 50;
    const content = try repeatedLines(alloc, "x\n", line_total);
    defer alloc.free(content);
    try writeTestFile(tmp, "many.txt", content);
    const path = try tmpPath(alloc, tmp, "many.txt");
    defer alloc.free(path);
    const args = try pathArgs(alloc, path, "");
    defer alloc.free(args);

    const result = try dispatchReadFile(alloc, args);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "\n450\tx\n</content>") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "... [showing") == null);
    try std.testing.expect(result.tool_result_memory.?.model_view_covers_full_file.?);
}

test "read_file pages a file above the inline budget and names the next start_line" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = try longLineText(alloc, tool_dispatch.default_max_read_file_lines + 7);
    defer alloc.free(content);
    try writeTestFile(tmp, "long.txt", content);
    const path = try tmpPath(alloc, tmp, "long.txt");
    defer alloc.free(path);
    const args = try pathArgs(alloc, path, "");
    defer alloc.free(args);

    const result = try dispatchReadFile(alloc, args);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(
        u8,
        result.body,
        "... [showing 400 of 407 lines; 7 more after line 400; pass start_line=401 to continue.]\n</content>",
    ) != null);
    try std.testing.expect(!result.tool_result_memory.?.model_view_covers_full_file.?);
}

test "read_file opens with one line of size, line count and modification time" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp, "file.txt", "one\ntwo\nthree\n");
    const path = try tmpPath(alloc, tmp, "file.txt");
    defer alloc.free(path);
    const args = try pathArgs(alloc, path, "");
    defer alloc.free(args);

    const result = try dispatchReadFile(alloc, args);
    defer result.deinit(alloc);

    const header_start = std.mem.find(u8, result.body, "<content>\n[file: 14 bytes, 3 lines, modified 2").?;
    const header_end = std.mem.findScalarPos(u8, result.body, header_start + "<content>\n".len, '\n').?;
    try std.testing.expect(std.mem.endsWith(u8, result.body[0..header_end], "Z]"));
    try std.testing.expect(std.mem.startsWith(u8, result.body[header_end..], "\n1\tone\n2\ttwo\n3\tthree\n</content>"));
}

test "read_file names the column_offset that continues a cut line" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const long_line = text_utils.repeat("a", tool_dispatch.default_max_read_file_line_len + 500) ++ "\nshort\n";
    try writeTestFile(tmp, "wide.txt", long_line);
    const path = try tmpPath(alloc, tmp, "wide.txt");
    defer alloc.free(path);
    const args = try pathArgs(alloc, path, "");
    defer alloc.free(args);

    const result = try dispatchReadFile(alloc, args);
    defer result.deinit(alloc);

    try std.testing.expectEqual(.success, result.status);
    try std.testing.expect(std.mem.find(u8, result.body, "... (line truncated; pass start_line=1, column_offset=2000 to continue it)\n2\tshort\n") != null);
    try std.testing.expect(std.mem.find(u8, result.body, "... [showing 2 of 2 lines; the read ends at the last line, 2; each cut line names the column_offset that continues it.]") != null);

    const rest_args = try pathArgs(alloc, path, ",\"start_line\":1,\"column_offset\":2000,\"line_count\":1");
    defer alloc.free(rest_args);
    const rest = try dispatchReadFile(alloc, rest_args);
    defer rest.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, rest.body, "\n1\t" ++ text_utils.repeat("a", 500) ++ "\n") != null);
    try std.testing.expect(std.mem.find(u8, rest.body, line_truncated_marker) == null);
}

test "read_file cuts a long line on a UTF-8 boundary" {
    try std.testing.expectEqual(@as(usize, 2), utf8BoundaryAtOrBefore("ab\xc3\xa9cd", 3));
    try std.testing.expectEqual(@as(usize, 2), utf8BoundaryAtOrBefore("ab\xc3\xa9cd", 2));
    try std.testing.expectEqual(@as(usize, 4), utf8BoundaryAtOrBefore("ab\xc3\xa9cd", 4));
    try std.testing.expectEqual(@as(usize, 1), utf8BoundaryAtOrBefore("a\xf0\x9f\x98\x80", 4));
    try std.testing.expectEqual(@as(usize, 5), utf8BoundaryAtOrBefore("a\xf0\x9f\x98\x80", 9));

    var buffer: [line_truncated_suffix_capacity]u8 = undefined;
    try std.testing.expectEqualStrings(
        "... (line truncated; pass start_line=18446744073709551615, column_offset=18446744073709551615 to continue it)",
        lineTruncatedSuffix(&buffer, std.math.maxInt(usize), std.math.maxInt(usize)),
    );
}

test "read_file refuses an unknown argument by name and lists the accepted fields" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "{\"path\":\"f.txt\",\"offset\":3}");
    switch (decoded) {
        .failure => |reason| {
            defer alloc.free(reason);
            try std.testing.expectEqualStrings(
                "read_file does not take argument \"offset\"; accepted fields: path, start_line, line_count, line_offset, column_offset, n_lines, max_chars, force",
                reason,
            );
        },
        .input => |erased| {
            erased.deinit(alloc);
            return error.TestExpectedDecodeFailure;
        },
    }
}

test "read_file decodes force and rejects a force that is not a boolean" {
    const alloc = std.testing.allocator;
    const forced = try decode(.{ .allocator = alloc }, "{\"path\":\"f.txt\",\"force\":true}");
    switch (forced) {
        .input => |erased| {
            defer erased.deinit(alloc);
            try std.testing.expect(erased.as(Input).force);
            try std.testing.expect(!erased.as(Input).line_count_explicit);
        },
        .failure => |reason| {
            defer alloc.free(reason);
            return error.TestExpectedDecodedInput;
        },
    }

    const invalid = try decode(.{ .allocator = alloc }, "{\"path\":\"f.txt\",\"force\":\"yes\"}");
    switch (invalid) {
        .failure => |reason| {
            defer alloc.free(reason);
            try std.testing.expectEqualStrings("read_file field \"force\" must be a boolean", reason);
        },
        .input => |erased| {
            erased.deinit(alloc);
            return error.TestExpectedDecodeFailure;
        },
    }
}

test "read_file answers a repeat read of an unchanged file in one line" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp, "file.txt", "one\ntwo\n");
    const path = try tmpPath(alloc, tmp, "file.txt");
    defer alloc.free(path);
    const args = try pathArgs(alloc, path, "");
    defer alloc.free(args);
    var tracker = read_tracker.ReadTracker.init(alloc);
    defer tracker.deinit();

    _ = tracker.beginStep();
    const first = try dispatchReadFileWithTracker(alloc, args, &tracker);
    defer first.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, first.body, "1\tone\n2\ttwo\n") != null);

    _ = tracker.beginStep();
    _ = tracker.beginStep();
    const repeat = try dispatchReadFileWithTracker(alloc, args, &tracker);
    defer repeat.deinit(alloc);

    try std.testing.expectEqual(.success, repeat.status);
    const expected = try alloc.print(
        "<path>{s}</path>\n<content>unchanged since your last read at step 1 (now step 3); pass `force: true` to read again</content>",
        .{path},
    );
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, repeat.body);
    try std.testing.expect(!repeat.tool_result_memory.?.model_view_covers_full_file.?);
    try std.testing.expectEqual(@as(u64, 1), tracker.lookup(path).?.served.?.step);
}

test "read_file reads again when force is true" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp, "file.txt", "one\ntwo\n");
    const path = try tmpPath(alloc, tmp, "file.txt");
    defer alloc.free(path);
    const args = try pathArgs(alloc, path, "");
    defer alloc.free(args);
    const forced_args = try pathArgs(alloc, path, ",\"force\":true");
    defer alloc.free(forced_args);
    var tracker = read_tracker.ReadTracker.init(alloc);
    defer tracker.deinit();

    const first = try dispatchReadFileWithTracker(alloc, args, &tracker);
    defer first.deinit(alloc);
    const forced = try dispatchReadFileWithTracker(alloc, forced_args, &tracker);
    defer forced.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, forced.body, "unchanged since") == null);
    try std.testing.expect(std.mem.find(u8, forced.body, "1\tone\n2\ttwo\n") != null);
}

test "read_file reads again when the requested range differs from the one served" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp, "file.txt", "one\ntwo\nthree\n");
    const path = try tmpPath(alloc, tmp, "file.txt");
    defer alloc.free(path);
    const whole_args = try pathArgs(alloc, path, "");
    defer alloc.free(whole_args);
    const ranged_args = try pathArgs(alloc, path, ",\"start_line\":2,\"line_count\":1");
    defer alloc.free(ranged_args);
    var tracker = read_tracker.ReadTracker.init(alloc);
    defer tracker.deinit();

    const whole = try dispatchReadFileWithTracker(alloc, whole_args, &tracker);
    defer whole.deinit(alloc);
    const ranged = try dispatchReadFileWithTracker(alloc, ranged_args, &tracker);
    defer ranged.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, ranged.body, "unchanged since") == null);
    try std.testing.expect(std.mem.find(u8, ranged.body, "2\ttwo\n") != null);

    const whole_again = try dispatchReadFileWithTracker(alloc, whole_args, &tracker);
    defer whole_again.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, whole_again.body, "unchanged since") == null);
    try std.testing.expect(std.mem.find(u8, whole_again.body, "1\tone\n") != null);

    const ranged_again = try dispatchReadFileWithTracker(alloc, ranged_args, &tracker);
    defer ranged_again.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, ranged_again.body, "unchanged since") == null);
}

test "read_file reads again after the file content changes" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp, "file.txt", "one\ntwo\n");
    const path = try tmpPath(alloc, tmp, "file.txt");
    defer alloc.free(path);
    const args = try pathArgs(alloc, path, "");
    defer alloc.free(args);
    var tracker = read_tracker.ReadTracker.init(alloc);
    defer tracker.deinit();

    const first = try dispatchReadFileWithTracker(alloc, args, &tracker);
    defer first.deinit(alloc);
    try writeTestFile(tmp, "file.txt", "one\nTWO\n");
    const second = try dispatchReadFileWithTracker(alloc, args, &tracker);
    defer second.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, second.body, "unchanged since") == null);
    try std.testing.expect(std.mem.find(u8, second.body, "2\tTWO\n") != null);
}

test "read_file reads again once the tracker forgets the path or every served view" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp, "file.txt", "one\ntwo\n");
    const path = try tmpPath(alloc, tmp, "file.txt");
    defer alloc.free(path);
    const args = try pathArgs(alloc, path, "");
    defer alloc.free(args);
    var tracker = read_tracker.ReadTracker.init(alloc);
    defer tracker.deinit();

    const first = try dispatchReadFileWithTracker(alloc, args, &tracker);
    defer first.deinit(alloc);
    tracker.forgetServedViews();
    const after_compaction = try dispatchReadFileWithTracker(alloc, args, &tracker);
    defer after_compaction.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, after_compaction.body, "unchanged since") == null);
    try std.testing.expect(std.mem.find(u8, after_compaction.body, "1\tone\n") != null);

    tracker.forget(path);
    const after_mutation = try dispatchReadFileWithTracker(alloc, args, &tracker);
    defer after_mutation.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, after_mutation.body, "unchanged since") == null);
}

test "read_file does not treat a result above the inline budget as served" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = try longLineText(alloc, 1000);
    defer alloc.free(content);
    try writeTestFile(tmp, "long.txt", content);
    const path = try tmpPath(alloc, tmp, "long.txt");
    defer alloc.free(path);
    const args = try pathArgs(alloc, path, ",\"line_count\":1000");
    defer alloc.free(args);
    var tracker = read_tracker.ReadTracker.init(alloc);
    defer tracker.deinit();

    const first = try dispatchReadFileWithTrackerInWorkspaceWithLimits(alloc, args, &tracker, 2000);
    defer first.deinit(alloc);
    try std.testing.expect(first.body.len > result_store.large_result_threshold_bytes);
    try std.testing.expect(tracker.lookup(path).?.served == null);

    const second = try dispatchReadFileWithTrackerInWorkspaceWithLimits(alloc, args, &tracker, 2000);
    defer second.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, second.body, "unchanged since") == null);
}

test "read_file shows env file values as redacted and keeps templates readable" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp, ".env", "# keys\nAPI_KEY=sk-live-123\nEMPTY=\n");
    try writeTestFile(tmp, ".env.example", "API_KEY=your-key-here\n");
    const env_path = try tmpPath(alloc, tmp, ".env");
    defer alloc.free(env_path);
    const example_path = try tmpPath(alloc, tmp, ".env.example");
    defer alloc.free(example_path);
    const env_args = try pathArgs(alloc, env_path, "");
    defer alloc.free(env_args);
    const example_args = try pathArgs(alloc, example_path, "");
    defer alloc.free(example_args);

    const env_result = try dispatchReadFile(alloc, env_args);
    defer env_result.deinit(alloc);
    try std.testing.expectEqual(.success, env_result.status);
    try std.testing.expect(std.mem.find(u8, env_result.body, "1\t# keys\n2\tAPI_KEY=<redacted>\n3\tEMPTY=\n") != null);
    try std.testing.expect(std.mem.find(u8, env_result.body, "sk-live-123") == null);
    try std.testing.expect(!env_result.tool_result_memory.?.model_view_covers_full_file.?);

    const example_result = try dispatchReadFile(alloc, example_args);
    defer example_result.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, example_result.body, "1\tAPI_KEY=your-key-here\n") != null);
}

test "read_file follows a symlink to the file the permission target resolved" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try writeTestFile(tmp, "workspace/real.txt", "linked\n");
    try writeTestFile(tmp, "outside.txt", "outside\n");
    try createTestSymlinkOrSkip(tmp.dir, "real.txt", "workspace/inside-link.txt");
    try createTestSymlinkOrSkip(tmp.dir, "../outside.txt", "workspace/outside-link.txt");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const outside = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "outside.txt");
    defer alloc.free(outside);

    const inside = try dispatchReadFileInWorkspace(alloc, workspace, "{\"path\":\"inside-link.txt\"}");
    defer inside.deinit(alloc);
    try std.testing.expectEqual(.success, inside.status);
    try expectReadBody("<path>real.txt</path>\n<content>\n1\tlinked\n</content>", inside.body);

    const absolute_link = try std.Io.Dir.path.join(alloc, &.{ workspace, "outside-link.txt" });
    defer alloc.free(absolute_link);
    const absolute_args = try pathArgs(alloc, absolute_link, "");
    defer alloc.free(absolute_args);
    const followed = try dispatchReadFileInWorkspace(alloc, workspace, absolute_args);
    defer followed.deinit(alloc);
    try std.testing.expectEqual(.success, followed.status);
    const expected = try alloc.print("<path>{s}</path>\n<content>\n1\toutside\n</content>", .{outside});
    defer alloc.free(expected);
    try expectReadBody(expected, followed.body);

    const relative_escape = try dispatchReadFileInWorkspace(alloc, workspace, "{\"path\":\"outside-link.txt\"}");
    defer relative_escape.deinit(alloc);
    try std.testing.expectEqual(.failure, relative_escape.status);
}
