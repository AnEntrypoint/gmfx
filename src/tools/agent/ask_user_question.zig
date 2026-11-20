const std = @import("std");
const observation = @import("../../core/agent/runtime/observation.zig");
const question_answer = @import("../../core/agent/question_answer.zig");
const core_types = @import("../../core/shared/types.zig");
const testing_allocator = @import("../../core/shared/testing_allocator.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

const whitespace = " \t\r\n";
pub const max_tool_questions = 4;
pub const max_tool_options = 4;
const legacy_permission_request_sentinel =
    "(AskUserQuestion: permission_request_id is no longer supported; use the safety review advice to choose a different action)";

pub const cancel_sentinel = "(user cancelled the question)";
pub const not_available_sentinel = "(AskUserQuestion is only available in the interactive shell; ask the user freeform instead)";

const invalid_args_sentinel = "(AskUserQuestion: invalid arguments; provide {questions})";
const question_count_sentinel = std.fmt.comptimePrint(
    "(AskUserQuestion: provide 1 to {d} questions)",
    .{max_tool_questions},
);

const QuestionBatchParseError = Allocator.Error || error{
    InvalidArguments,
    MissingQuestions,
    QuestionsNotArray,
    QuestionCount,
    QuestionNotObject,
    MissingQuestionText,
    QuestionTextNotString,
    EmptyQuestionText,
    MissingOptions,
    OptionsNotArray,
    OptionCount,
    OptionNotObject,
    MissingOptionLabel,
    OptionLabelNotString,
    EmptyOptionLabel,
    DuplicateOptionLabel,
    HeaderNotString,
    MultiSelectNotBool,
    MultiSelectNotSupported,
    BackgroundNotBool,
    BackgroundNotSupported,
};

pub const Input = struct {
    args_json: []u8,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.args_json);
        self.* = .{ .args_json = &.{} };
    }
};

pub const Requester = struct {
    observer: ?*observation.Observer = null,
    call_id: ?[]const u8 = null,
    ctx: ?*anyopaque,
    response_alloc: Allocator,
    request: tool_dispatch.AskQuestionBatchFn,
    source: question_answer.Source = .human,
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .args_json = try ctx.allocator.dupe(u8, args_json) };
    errdefer input.deinit(ctx.allocator);

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    if (try hasLegacyPermissionRequestId(ctx.allocator, input.args_json)) {
        return try ctx.allocator.dupe(u8, legacy_permission_request_sentinel);
    }
    return null;
}

fn hasLegacyPermissionRequestId(
    alloc: Allocator,
    args_json: []const u8,
) Allocator.Error!bool {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer parsed.deinit();
    return parsed.value == .object and
        parsed.value.object.get("permission_request_id") != null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const request = ctx.ask_question_batch orelse {
        if (ctx.permission_mode == .yolo) return syntheticDefaultResult(ctx.allocator, erased.as(Input).args_json);
        return .{ .success = try ctx.allocator.dupe(u8, not_available_sentinel) };
    };
    const input = erased.as(Input);
    const output = executeWithRequester(ctx.allocator, input.args_json, .{
        .observer = ctx.observer,
        .call_id = ctx.tool_call_id,
        .ctx = ctx.ask_question_ctx,
        .response_alloc = ctx.allocator,
        .request = request,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try ctx.allocator.print("AskUserQuestion failed: {s}", .{@errorName(err)}) },
    };
    return .{ .success = output };
}

fn syntheticDefaultResult(alloc: Allocator, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const output = syntheticDefaultOutput(alloc, args_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try alloc.print("AskUserQuestion failed: {s}", .{@errorName(err)}) },
    };
    return .{ .success = output };
}

pub fn syntheticDefaultOutput(alloc: Allocator, args_json: []const u8) ![]u8 {
    var parse_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer parse_arena_state.deinit();
    const parse_arena = parse_arena_state.allocator();

    const entries = parseQuestionBatch(parse_arena, args_json) catch |err| return invalidArgsBody(alloc, err);
    const answers = try parse_arena.alloc([]const u8, entries.len);
    for (entries, answers) |entry, *answer| answer.* = entry.options[0].label;
    return question_answer.encodeJsonWithSource(alloc, entries, answers, .synthetic);
}

pub fn executeWithRequester(result_alloc: Allocator, args_json: []const u8, requester: Requester) ![]u8 {
    var parse_arena_state = std.heap.ArenaAllocator.init(result_alloc);
    defer parse_arena_state.deinit();
    const parse_arena = parse_arena_state.allocator();

    const entries = parseQuestionBatch(parse_arena, args_json) catch |err| return invalidArgsBody(result_alloc, err);
    const wait = if (requester.observer) |observer| observer.beginWait(.{ .kind = .question, .call_id = requester.call_id, .questions = entries }) else null;
    const answers_opt = requester.request(requester.ctx, requester.response_alloc, entries) catch |err| {
        if (wait) |value| value.end(.failed, &.{}, @errorName(err));
        return err;
    };
    if (wait) |value| value.end(if (answers_opt == null) .cancelled else .accepted, answers_opt orelse &.{}, null);
    if (answers_opt) |answers| {
        defer freeAnswers(requester.response_alloc, answers);
        return question_answer.encodeJsonWithSource(result_alloc, entries, answers, requester.source);
    }
    return result_alloc.dupe(u8, cancel_sentinel);
}

test "question observer records answers cancellation and failure at the real requester" {
    const Fixture = struct {
        cancelled: bool = false,
        failure: bool = false,
        fn request(raw: ?*anyopaque, alloc: Allocator, _: []const core_types.QuestionBatchEntry) Allocator.Error!?[][]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.failure) return error.OutOfMemory;
            if (self.cancelled) return null;
            const answers = try alloc.alloc([]u8, 1);
            errdefer alloc.free(answers);
            answers[0] = try alloc.dupe(u8, "Yes");
            return answers;
        }
    };
    var fixture: Fixture = .{};
    var capture: @import("../../core/agent/runtime/observation_testing.zig").Capture = .{ .expected_call = "question-call" };
    var observer = capture.observer();
    for ([_]bool{ false, true }) |cancelled| {
        fixture.cancelled = cancelled;
        const output = try executeWithRequester(std.testing.allocator, "{\"questions\":[{\"question\":\"Continue?\",\"options\":[{\"label\":\"Yes\"},{\"label\":\"No\"}]}]}", .{
            .ctx = &fixture,
            .response_alloc = std.testing.allocator,
            .request = Fixture.request,
            .observer = &observer,
            .call_id = "question-call",
        });
        defer std.testing.allocator.free(output);
        try std.testing.expect(if (cancelled) std.mem.eql(u8, output, cancel_sentinel) else std.mem.find(u8, output, "Yes") != null);
    }
    fixture.failure = true;
    try std.testing.expectError(error.OutOfMemory, executeWithRequester(std.testing.allocator, "{\"questions\":[{\"question\":\"Continue?\",\"options\":[{\"label\":\"Yes\"},{\"label\":\"No\"}]}]}", .{
        .ctx = &fixture,
        .response_alloc = std.testing.allocator,
        .request = Fixture.request,
        .observer = &observer,
        .call_id = "question-call",
    }));
    try std.testing.expectEqual(@as(usize, 3), capture.count(.wait_start));
    try std.testing.expectEqual(capture.count(.wait_start), capture.count(.wait_end));
    try std.testing.expect(!capture.invalid);
}

fn parseQuestionBatch(arena: Allocator, args_json: []const u8) QuestionBatchParseError![]const core_types.QuestionBatchEntry {
    var parsed = std.json.parseFromSlice(std.json.Value, arena, args_json, .{}) catch {
        return error.InvalidArguments;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidArguments;
    const args = parsed.value.object;
    if (args.get("background")) |background_value| switch (background_value) {
        .null => {},
        .bool => |enabled| if (enabled) return error.BackgroundNotSupported,
        else => return error.BackgroundNotBool,
    };

    var questions_value = args.get("questions") orelse return error.MissingQuestions;

    tool_args.normalizeCompositeArrayValue(arena, &questions_value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.QuestionsNotArray,
    };
    if (questions_value != .array) return error.QuestionsNotArray;

    const questions_arr = questions_value.array;
    if (questions_arr.items.len < 1 or questions_arr.items.len > max_tool_questions) return error.QuestionCount;

    var entries_buf: std.ArrayList(core_types.QuestionBatchEntry) = .empty;
    try entries_buf.ensureTotalCapacity(arena, questions_arr.items.len);

    for (questions_arr.items) |q_item| {
        if (q_item != .object) return error.QuestionNotObject;

        const question_value = q_item.object.get("question") orelse return error.MissingQuestionText;
        if (question_value != .string) return error.QuestionTextNotString;
        const question_trimmed = std.mem.trim(u8, question_value.string, whitespace);
        if (question_trimmed.len == 0) return error.EmptyQuestionText;
        const question_safe = try dupeTerminalSafeQuestionText(arena, question_trimmed);

        var header_safe: []const u8 = "";
        if (q_item.object.get("header")) |header_value| switch (header_value) {
            .null => {},
            .string => |text| {
                const trimmed_header = std.mem.trim(u8, text, whitespace);
                if (trimmed_header.len > 0) header_safe = try dupeTerminalSafeQuestionText(arena, trimmed_header);
            },
            else => return error.HeaderNotString,
        };
        if (q_item.object.get("multi_select")) |multi_value| switch (multi_value) {
            .null => {},
            .bool => |enabled| if (enabled) return error.MultiSelectNotSupported,
            else => return error.MultiSelectNotBool,
        };

        const options_value = q_item.object.get("options") orelse return error.MissingOptions;
        if (options_value != .array) return error.OptionsNotArray;

        const options_arr = options_value.array;
        if (options_arr.items.len < 2 or options_arr.items.len > max_tool_options) return error.OptionCount;

        var options_buf: std.ArrayList(core_types.QuestionOption) = .empty;
        try options_buf.ensureTotalCapacity(arena, options_arr.items.len);

        for (options_arr.items) |item| {
            if (item != .object) return error.OptionNotObject;
            const label_value = item.object.get("label") orelse return error.MissingOptionLabel;
            if (label_value != .string) return error.OptionLabelNotString;
            const label_trimmed = std.mem.trim(u8, label_value.string, whitespace);
            if (label_trimmed.len == 0) return error.EmptyOptionLabel;
            const label_safe = try dupeTerminalSafeQuestionText(arena, label_trimmed);

            for (options_buf.items) |existing| {
                if (std.ascii.eqlIgnoreCase(existing.label, label_safe)) return error.DuplicateOptionLabel;
            }

            var desc_slice: ?[]const u8 = null;
            if (item.object.get("description")) |desc_value| {
                if (desc_value == .string) {
                    const trimmed_desc = std.mem.trim(u8, desc_value.string, whitespace);
                    if (trimmed_desc.len > 0) desc_slice = try dupeTerminalSafeQuestionText(arena, trimmed_desc);
                }
            }

            options_buf.appendAssumeCapacity(.{
                .label = label_safe,
                .description = desc_slice,
            });
        }

        entries_buf.appendAssumeCapacity(.{
            .question = question_safe,
            .header = header_safe,
            .options = try options_buf.toOwnedSlice(arena),
        });
    }

    return entries_buf.toOwnedSlice(arena);
}

fn dupeTerminalSafeQuestionText(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (text_utils.isTerminalSafe(text)) return arena.dupe(u8, text);
    const encoded = try text_utils.encodeTerminalSafeInline(arena, text, std.math.maxInt(usize));
    return encoded.bytes;
}

fn invalidArgsBody(alloc: Allocator, err: QuestionBatchParseError) Allocator.Error![]u8 {
    const body = switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArguments => invalid_args_sentinel,
        error.MissingQuestions => "(AskUserQuestion: missing required array \"questions\")",
        error.QuestionsNotArray => "(AskUserQuestion: \"questions\" must be an array)",
        error.QuestionCount => question_count_sentinel,
        error.QuestionNotObject => "(AskUserQuestion: each question must be an object with a \"question\" and \"options\")",
        error.MissingQuestionText => "(AskUserQuestion: each question requires a \"question\" string)",
        error.QuestionTextNotString => "(AskUserQuestion: question \"question\" must be a string)",
        error.EmptyQuestionText => "(AskUserQuestion: question text must not be empty)",
        error.MissingOptions => "(AskUserQuestion: each question requires an \"options\" array)",
        error.OptionsNotArray => "(AskUserQuestion: \"options\" must be an array)",
        error.OptionCount => "(AskUserQuestion: provide 2 to 4 options per question)",
        error.OptionNotObject => "(AskUserQuestion: each option must be an object with a \"label\")",
        error.MissingOptionLabel => "(AskUserQuestion: each option requires a \"label\" string)",
        error.OptionLabelNotString => "(AskUserQuestion: option \"label\" must be a string)",
        error.EmptyOptionLabel => "(AskUserQuestion: option labels must not be empty)",
        error.DuplicateOptionLabel => "(AskUserQuestion: option labels must be unique within a question)",
        error.HeaderNotString => "(AskUserQuestion: question \"header\" must be a string)",
        error.MultiSelectNotBool => "(AskUserQuestion: question \"multi_select\" must be a boolean)",
        error.MultiSelectNotSupported => "(AskUserQuestion: multi_select is not supported yet; ask one choice per question)",
        error.BackgroundNotBool => "(AskUserQuestion: \"background\" must be a boolean)",
        error.BackgroundNotSupported => "(AskUserQuestion: background is not supported yet; ask in the foreground)",
    };
    return alloc.dupe(u8, body);
}

fn freeAnswers(alloc: Allocator, answers: [][]u8) void {
    for (answers) |answer| alloc.free(answer);
    alloc.free(answers);
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn requesterCancel(_: ?*anyopaque, _: Allocator, _: []const core_types.QuestionBatchEntry) anyerror!?[][]u8 {
    return null;
}

const FakeRequester = struct {
    called: bool = false,
    saw_trimmed: bool = false,

    fn request(raw_ctx: ?*anyopaque, alloc: Allocator, entries: []const core_types.QuestionBatchEntry) anyerror!?[][]u8 {
        const self: *FakeRequester = @ptrCast(@alignCast(raw_ctx.?));
        self.called = true;
        if (entries.len == 1 and
            std.mem.eql(u8, entries[0].question, "Choose?") and
            entries[0].options.len == 2 and
            std.mem.eql(u8, entries[0].options[0].label, "Yes") and
            entries[0].options[0].description != null and
            std.mem.eql(u8, entries[0].options[0].description.?, "Go ahead") and
            entries[0].options[1].description == null)
        {
            self.saw_trimmed = true;
        }

        const answers = try alloc.alloc([]u8, entries.len);
        errdefer alloc.free(answers);
        var filled: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < filled) : (i += 1) alloc.free(answers[i]);
        }
        while (filled < entries.len) : (filled += 1) {
            answers[filled] = try alloc.dupe(u8, entries[filled].options[0].label);
        }
        return answers;
    }
};

const TerminalSafeRequester = struct {
    called: bool = false,
    saw_terminal_safe: bool = false,

    fn request(raw_ctx: ?*anyopaque, alloc: Allocator, entries: []const core_types.QuestionBatchEntry) anyerror!?[][]u8 {
        const self: *TerminalSafeRequester = @ptrCast(@alignCast(raw_ctx.?));
        self.called = true;
        if (entries.len == 1 and
            std.mem.eql(u8, entries[0].question, "Q \\x1b[31m?") and
            entries[0].options.len == 2 and
            std.mem.eql(u8, entries[0].options[0].label, "Alpha Fake") and
            entries[0].options[0].description != null and
            std.mem.eql(u8, entries[0].options[0].description.?, "Desc Gap") and
            std.mem.eql(u8, entries[0].options[1].label, "\\x1b[31mRed\\x1b[0m"))
        {
            self.saw_terminal_safe = true;
        }

        const answers = try alloc.alloc([]u8, entries.len);
        errdefer alloc.free(answers);
        var filled: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < filled) : (i += 1) alloc.free(answers[i]);
        }
        while (filled < entries.len) : (filled += 1) {
            answers[filled] = try alloc.dupe(u8, entries[filled].options[0].label);
        }
        return answers;
    }
};

fn expectRequesterOutput(args_json: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    var fake = FakeRequester{};
    const output = try executeWithRequester(alloc, args_json, .{
        .ctx = &fake,
        .response_alloc = alloc,
        .request = FakeRequester.request,
    });
    defer alloc.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "AskUserQuestion validates arguments and returns active sentinels" {
    try expectRequesterOutput("not-json", invalid_args_sentinel);
    try expectRequesterOutput("[]", invalid_args_sentinel);
    try expectRequesterOutput("{}", "(AskUserQuestion: missing required array \"questions\")");
    try expectRequesterOutput("{\"questions\":{}}", "(AskUserQuestion: \"questions\" must be an array)");
    try expectRequesterOutput("{\"questions\":[]}", "(AskUserQuestion: provide 1 to 4 questions)");
    try expectRequesterOutput("{\"questions\":[1]}", "(AskUserQuestion: each question must be an object with a \"question\" and \"options\")");
    try expectRequesterOutput("{\"questions\":[{}]}", "(AskUserQuestion: each question requires a \"question\" string)");
    try expectRequesterOutput("{\"questions\":[{\"question\":1}]}", "(AskUserQuestion: question \"question\" must be a string)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"  \",\"options\":[]}]}", "(AskUserQuestion: question text must not be empty)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\"}]}", "(AskUserQuestion: each question requires an \"options\" array)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":1}]}", "(AskUserQuestion: \"options\" must be an array)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[]}]}", "(AskUserQuestion: provide 2 to 4 options per question)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[1,2]}]}", "(AskUserQuestion: each option must be an object with a \"label\")");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[{},{}]}]}", "(AskUserQuestion: each option requires a \"label\" string)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[{\"label\":1},{\"label\":\"No\"}]}]}", "(AskUserQuestion: option \"label\" must be a string)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[{\"label\":\"\"},{\"label\":\"No\"}]}]}", "(AskUserQuestion: option labels must not be empty)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[{\"label\":\"Yes\"},{\"label\":\" yes \"}]}]}", "(AskUserQuestion: option labels must be unique within a question)");
}

test "AskUserQuestion answers with each first option, labelled synthetic, when full access has no batch" {
    const alloc = std.testing.allocator;
    const output = try syntheticDefaultOutput(alloc, "{\"questions\":[{\"question\":\"Continue?\",\"options\":[{\"label\":\"Continue\"},{\"label\":\"Stop\"}]},{\"question\":\"Depth?\",\"options\":[{\"label\":\"Quick\"},{\"label\":\"Thorough\"}]}]}");
    defer alloc.free(output);
    try std.testing.expectEqualStrings(
        "[{\"question\":\"Continue?\",\"answer\":\"Continue\",\"synthetic\":true},{\"question\":\"Depth?\",\"answer\":\"Quick\",\"synthetic\":true}]",
        output,
    );
}

test "AskUserQuestion synthetic defaults keep the argument errors" {
    const alloc = std.testing.allocator;
    const output = try syntheticDefaultOutput(alloc, "not-json");
    defer alloc.free(output);
    try std.testing.expectEqualStrings(invalid_args_sentinel, output);
}

test "AskUserQuestion rejects the new fields it cannot honour yet and option counts above four" {
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[{\"label\":\"Yes\"},{\"label\":\"No\"}],\"multi_select\":true}]}", "(AskUserQuestion: multi_select is not supported yet; ask one choice per question)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[{\"label\":\"Yes\"},{\"label\":\"No\"}],\"header\":1}]}", "(AskUserQuestion: question \"header\" must be a string)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[{\"label\":\"Yes\"},{\"label\":\"No\"}]}],\"background\":true}", "(AskUserQuestion: background is not supported yet; ask in the foreground)");
    try expectRequesterOutput("{\"questions\":[{\"question\":\"Q?\",\"options\":[{\"label\":\"A\"},{\"label\":\"B\"},{\"label\":\"C\"},{\"label\":\"D\"},{\"label\":\"E\"}]}]}", "(AskUserQuestion: provide 2 to 4 options per question)");
}

test "AskUserQuestion keeps the header and accepts multi_select false and background false" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const entries = try parseQuestionBatch(arena_state.allocator(), "{\"questions\":[{\"question\":\"Pick?\",\"header\":\"Scope\",\"multi_select\":false,\"options\":[{\"label\":\"A\"},{\"label\":\"B\"}]}],\"background\":false}");
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("Pick?", entries[0].question);
    try std.testing.expectEqualStrings("Scope", entries[0].header);
    try std.testing.expectEqual(@as(usize, 2), entries[0].options.len);
}

test "AskUserQuestion labels answers synthesized without a human" {
    const alloc = std.testing.allocator;
    var fake = FakeRequester{};
    const output = try executeWithRequester(
        alloc,
        "{\"questions\":[{\"question\":\"Choose?\",\"options\":[{\"label\":\"Yes\"},{\"label\":\"No\"}]}]}",
        .{
            .ctx = &fake,
            .response_alloc = alloc,
            .request = FakeRequester.request,
            .source = .synthetic,
        },
    );
    defer alloc.free(output);

    try std.testing.expectEqualStrings("[{\"question\":\"Choose?\",\"answer\":\"Yes\",\"synthetic\":true}]", output);
}

test "AskUserQuestion normalizes descriptions and encodes ordered answers" {
    const alloc = std.testing.allocator;
    var fake = FakeRequester{};
    const output = try executeWithRequester(
        alloc,
        "{\"questions\":[{\"question\":\" Choose? \",\"options\":[{\"label\":\" Yes \",\"description\":\" Go ahead \"},{\"label\":\"No\",\"description\":3}]}]}",
        .{
            .ctx = &fake,
            .response_alloc = alloc,
            .request = FakeRequester.request,
        },
    );
    defer alloc.free(output);

    try std.testing.expect(fake.called);
    try std.testing.expect(fake.saw_trimmed);
    try std.testing.expectEqualStrings("[{\"question\":\"Choose?\",\"answer\":\"Yes\"}]", output);
}

test "AskUserQuestion accepts the questions array sent as JSON text" {
    const alloc = std.testing.allocator;
    var fake = FakeRequester{};
    const output = try executeWithRequester(
        alloc,
        "{\"questions\":\"[{\\\"question\\\":\\\" Choose? \\\",\\\"options\\\":[{\\\"label\\\":\\\" Yes \\\"},{\\\"label\\\":\\\"No\\\"}]}]\"}",
        .{
            .ctx = &fake,
            .response_alloc = alloc,
            .request = FakeRequester.request,
        },
    );
    defer alloc.free(output);

    try std.testing.expect(fake.called);
    try std.testing.expectEqualStrings("[{\"question\":\"Choose?\",\"answer\":\"Yes\"}]", output);
    try expectRequesterOutput("{\"questions\":\"not json\"}", "(AskUserQuestion: \"questions\" must be an array)");
    try expectRequesterOutput("{\"questions\":\"{}\"}", "(AskUserQuestion: \"questions\" must be an array)");
}

const max_fuzz_questions_text_bytes: usize = 16 * 1024;

fn fuzzQuestionsText(_: void, smith: *std.testing.Smith) !void {
    var buffer: [max_fuzz_questions_text_bytes + 1]u8 = undefined;
    const text = buffer[0..smith.slice(&buffer)];

    if (!std.unicode.utf8ValidateSlice(text)) return;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args_json = try std.json.Stringify.valueAlloc(arena, .{ .questions = text }, .{});
    if (parseQuestionBatch(arena, args_json)) |entries| {
        try std.testing.expect(entries.len >= 1 and entries.len <= max_tool_questions);
    } else |err| switch (err) {
        error.OutOfMemory => return err,
        else => {},
    }
}

test "AskUserQuestion questions sent as JSON text decode or refuse arbitrary bytes" {
    try std.testing.fuzz({}, fuzzQuestionsText, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "[{\"question\":\"Pick one?\",\"options\":[{\"label\":\"A\"},{\"label\":\"B\"}]}]",
            "[{\"question\":\"Pick one?\",\"options\":[{\"label\":\"A\"}]}]",
            "[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]",
            "{}",
            "[",
        }) ++ @import("fuzz_corpus").ask_questions_text.*),
    });
}

test "AskUserQuestion flattens model-controlled prompt text for terminal display" {
    const alloc = std.testing.allocator;
    var requester = TerminalSafeRequester{};
    const output = try executeWithRequester(
        alloc,
        "{\"questions\":[{\"question\":\"Q\\n\\u001b[31m?\",\"options\":[{\"label\":\"Alpha\\nFake\",\"description\":\"Desc\\tGap\"},{\"label\":\"\\u001b[31mRed\\u001b[0m\"}]}]}",
        .{
            .ctx = &requester,
            .response_alloc = alloc,
            .request = TerminalSafeRequester.request,
        },
    );
    defer alloc.free(output);

    try std.testing.expect(requester.called);
    try std.testing.expect(requester.saw_terminal_safe);
    try std.testing.expectEqualStrings(
        "[{\"question\":\"Q \\\\x1b[31m?\",\"answer\":\"Alpha Fake\"}]",
        output,
    );
}

const batch_option_count = 4;

fn questionBatchArgs(alloc: Allocator, count: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"questions\":[");
    for (0..count) |question| {
        if (question > 0) try out.writer.writeByte(',');
        try out.writer.print("{{\"question\":\"Question {d}?\",\"options\":[", .{question + 1});
        for (0..batch_option_count) |option| {
            if (option > 0) try out.writer.writeByte(',');
            try out.writer.print(
                "{{\"label\":\"Q{d} option {d}\",\"description\":\"Consequence {d}.{d}\"}}",
                .{ question + 1, option + 1, question + 1, option + 1 },
            );
        }
        try out.writer.writeAll("]}");
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

const FullBatchRequester = struct {
    calls: usize = 0,
    entry_count: usize = 0,
    entries_in_order: bool = true,

    fn request(raw_ctx: ?*anyopaque, alloc: Allocator, entries: []const core_types.QuestionBatchEntry) anyerror!?[][]u8 {
        const self: *FullBatchRequester = @ptrCast(@alignCast(raw_ctx.?));
        self.calls += 1;
        self.entry_count = entries.len;
        for (entries, 0..) |entry, index| {
            var expected_buf: [32]u8 = undefined;
            const expected = try std.mem.print(&expected_buf, "Question {d}?", .{index + 1});
            if (!std.mem.eql(u8, entry.question, expected) or entry.options.len != batch_option_count) {
                self.entries_in_order = false;
            }
        }

        const answers = try alloc.alloc([]u8, entries.len);
        errdefer alloc.free(answers);
        var filled: usize = 0;
        errdefer for (answers[0..filled]) |answer| alloc.free(answer);
        while (filled < entries.len) : (filled += 1) {
            answers[filled] = try alloc.dupe(u8, entries[filled].options[filled % batch_option_count].label);
        }
        return answers;
    }
};

test "AskUserQuestion accepts a full batch and rejects one more question" {
    const alloc = std.testing.allocator;
    const full_args = try questionBatchArgs(alloc, max_tool_questions);
    defer alloc.free(full_args);

    var requester = FullBatchRequester{};
    const output = try executeWithRequester(alloc, full_args, .{
        .ctx = &requester,
        .response_alloc = alloc,
        .request = FullBatchRequester.request,
    });
    defer alloc.free(output);

    try std.testing.expectEqual(@as(usize, 1), requester.calls);
    try std.testing.expectEqual(@as(usize, max_tool_questions), requester.entry_count);
    try std.testing.expect(requester.entries_in_order);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const answers = (try question_answer.decodeJson(arena_state.allocator(), output)).?;
    try std.testing.expectEqual(@as(usize, max_tool_questions), answers.len);
    for (answers, 0..) |pair, index| {
        var question_buf: [32]u8 = undefined;
        var answer_buf: [32]u8 = undefined;
        try std.testing.expectEqualStrings(
            try std.mem.print(&question_buf, "Question {d}?", .{index + 1}),
            pair.question,
        );
        try std.testing.expectEqualStrings(
            try std.mem.print(&answer_buf, "Q{d} option {d}", .{ index + 1, index % batch_option_count + 1 }),
            pair.answer,
        );
    }

    const oversized_args = try questionBatchArgs(alloc, max_tool_questions + 1);
    defer alloc.free(oversized_args);
    var oversized_requester = FullBatchRequester{};
    const rejected = try executeWithRequester(alloc, oversized_args, .{
        .ctx = &oversized_requester,
        .response_alloc = alloc,
        .request = FullBatchRequester.request,
    });
    defer alloc.free(rejected);
    try std.testing.expectEqualStrings("(AskUserQuestion: provide 1 to 4 questions)", rejected);
    try std.testing.expectEqual(@as(usize, 0), oversized_requester.calls);
}

test "AskUserQuestion full batch frees every allocation when any allocation fails" {
    const args = try questionBatchArgs(std.testing.allocator, max_tool_questions);
    defer std.testing.allocator.free(args);

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing_allocator.no_resize, .{ .fail_index = fail_index });
        const alloc = failing.allocator();
        var requester = FullBatchRequester{};
        const completed = if (executeWithRequester(alloc, args, .{
            .ctx = &requester,
            .response_alloc = alloc,
            .request = FullBatchRequester.request,
        })) |output| blk: {
            alloc.free(output);
            break :blk !failing.has_induced_failure;
        } else |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => blk: {
                try std.testing.expect(failing.has_induced_failure);
                break :blk false;
            },
            else => return err,
        };
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        if (completed) break;
    }

    try std.testing.expect(fail_index > max_tool_questions);
}

test "AskUserQuestion cancellation returns sentinel" {
    const alloc = std.testing.allocator;
    const output = try executeWithRequester(
        alloc,
        "{\"questions\":[{\"question\":\"Q?\",\"options\":[{\"label\":\"Yes\"},{\"label\":\"No\"}]}]}",
        .{
            .ctx = null,
            .response_alloc = alloc,
            .request = requesterCancel,
        },
    );
    defer alloc.free(output);

    try std.testing.expectEqualStrings(cancel_sentinel, output);
}

test "AskUserQuestion validation rejects legacy permission references before prompting" {
    const alloc = std.testing.allocator;
    const decoded = try decode(
        .{ .allocator = alloc },
        "{\"permission_request_id\":\"legacy\",\"questions\":[]}",
    );
    const input = switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            return error.TestExpectedEqual;
        },
        .input => |owned| owned,
    };
    defer input.deinit(alloc);
    const failure = (try validate(.{ .allocator = alloc }, input)) orelse
        return error.TestExpectedEqual;
    defer alloc.free(failure);
    try std.testing.expectEqualStrings(legacy_permission_request_sentinel, failure);
}

test "AskUserQuestion noninteractive returns sentinel before parsing" {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, "not-json");
    const input = switch (decoded) {
        .failure => |body| {
            defer alloc.free(body);
            return error.TestExpectedEqual;
        },
        .input => |owned| owned,
    };
    defer input.deinit(alloc);

    const result = try call(.{ .allocator = alloc }, input);
    defer result.deinit(alloc);

    switch (result) {
        .rich => return error.TestUnexpectedRichResult,
        .success => |body| try std.testing.expectEqualStrings(not_available_sentinel, body),
        .failure => return error.TestExpectedEqual,
    }
}
