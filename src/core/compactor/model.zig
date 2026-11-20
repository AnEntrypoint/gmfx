const std = @import("std");
const summarize = @import("summarize.zig");
const trace = @import("trace.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

const max_summary_bytes = 8 * 1024 * 1024;

pub const ModelCaller = struct {
    context: *anyopaque,
    vtable: *const VTable,
    model: []const u8,
    provider: model_provider.ProviderId,
    credential_source: ?types.CredentialSource,
    sends_after_conversation: bool = false,
    usage: ?*const types.Usage = null,

    pub const VTable = struct {
        capabilities: *const fn (context: *anyopaque, model: []const u8) model_capabilities.Capabilities,
        send: *const fn (context: *anyopaque, alloc: Allocator, call: Call) CallError!Reply,
    };
};

pub const Call = struct {
    model: []const u8,
    reasoning: ?types.ReasoningEffort,
    system: []const u8,
    user: []const u8,
    after_conversation: bool = false,
    max_bytes: usize,
    cancel_flag: *std.atomic.Value(bool),
    trace_ctx: debug_trace.TraceContext,
};

pub const CallError = error{ Cancelled, OutOfMemory };

pub const FailureReason = enum { transport, provider, tool_call, incomplete, truncated };

pub const Reply = union(enum) {
    text: []u8,
    failed: struct { reason: FailureReason, detail: []u8 },
};

fn fallbackModel(primary: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, primary, "anthropic/")) "openai/gpt-6-sol" else "anthropic/claude-sonnet-5";
}

fn lowestReasoningEffort(capabilities: model_capabilities.Capabilities) ?types.ReasoningEffort {
    const options = capabilities.reasoning_efforts.slice();
    for (options) |option| {
        if (option.eql(types.ReasoningEffort.literal("none"))) return option;
    }
    return if (options.len > 0) options[0] else null;
}

pub const Summarizer = struct {
    caller: ModelCaller,
    cancel_flag: *std.atomic.Value(bool),
    trace_ctx: debug_trace.TraceContext,
    summaries: usize = 0,
    fallback_used: ?[]const u8 = null,
    instruction: []const u8 = "",

    pub fn model(self: *Summarizer) summarize.Model {
        return .{ .context = self, .summarize_fn = summarizeWith };
    }

    fn summarizeWith(context: *anyopaque, alloc: Allocator, prompt: summarize.Prompt) summarize.ModelError![]u8 {
        const self: *Summarizer = @ptrCast(@alignCast(context));
        self.summaries += 1;

        if (prompt.after_conversation) return self.ask(alloc, prompt, prompt.model);
        var primary_error: ?summarize.ModelError = null;
        if (self.ask(alloc, prompt, prompt.model)) |text| {
            if (std.mem.trim(u8, text, " \t\r\n").len > 0) return text;
            alloc.free(text);
        } else |err| {
            if (err == error.Cancelled or err == error.OutOfMemory) return err;
            primary_error = err;
        }

        if (self.caller.provider != .gateway) {
            if (primary_error) |err| return err;
            return alloc.dupe(u8, "");
        }
        const fallback = fallbackModel(prompt.model);
        trace.info(self.trace_ctx, .log, "fallback model={s} after={s}", .{
            fallback,
            if (primary_error) |err| @errorName(err) else "empty_summary",
        });
        self.fallback_used = fallback;
        return self.ask(alloc, prompt, fallback);
    }

    fn ask(self: *Summarizer, alloc: Allocator, prompt: summarize.Prompt, model_name: []const u8) summarize.ModelError![]u8 {
        const caller = self.caller;
        const instruction = std.mem.trim(u8, self.instruction, " \t\r\n");
        const user = if (instruction.len == 0) prompt.user else try alloc.print("{s}\n\n" ++ user_instruction_lead ++ "{s}", .{ prompt.user, instruction });
        defer if (instruction.len > 0) alloc.free(user);
        const reply = try caller.vtable.send(caller.context, alloc, .{
            .model = model_name,
            .reasoning = if (prompt.after_conversation) null else lowestReasoningEffort(caller.vtable.capabilities(caller.context, model_name)),
            .system = prompt.system,
            .user = user,
            .after_conversation = prompt.after_conversation,
            .max_bytes = max_summary_bytes,
            .cancel_flag = self.cancel_flag,
            .trace_ctx = self.trace_ctx,
        });
        const failure = switch (reply) {
            .text => |text| return text,
            .failed => |failure| failure,
        };
        defer alloc.free(failure.detail);
        switch (failure.reason) {
            .transport, .provider => trace.failure(self.trace_ctx, .summary_transport_failed, "model={s} {s}", .{ model_name, failure.detail }),
            .tool_call => trace.failure(self.trace_ctx, .summary_tool_call_rejected, "model={s}", .{model_name}),
            .incomplete => {
                trace.failure(self.trace_ctx, .summary_incomplete, "model={s} {s}", .{ model_name, failure.detail });
                return error.SummaryIncomplete;
            },
            .truncated => trace.failure(self.trace_ctx, .summary_truncated, "model={s} {s}", .{ model_name, failure.detail }),
        }
        return error.ModelFailed;
    }
};

pub const user_instruction_lead = "The user asked for this when starting the compaction; follow it where it does not conflict with the rules above: ";

const InstructionCaller = struct {
    expected_user: []const u8,
    matched: usize = 0,
    calls: usize = 0,

    fn caller(self: *InstructionCaller) ModelCaller {
        return .{
            .context = self,
            .vtable = &.{ .capabilities = capabilities, .send = send },
            .model = "anthropic/claude-opus-5.5",
            .provider = .codex,
            .credential_source = null,
        };
    }

    fn capabilities(_: *anyopaque, _: []const u8) model_capabilities.Capabilities {
        return .{};
    }

    fn send(context: *anyopaque, alloc: Allocator, call: Call) CallError!Reply {
        const self: *InstructionCaller = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.matched += @intFromBool(std.mem.eql(u8, call.user, self.expected_user));
        return .{ .text = try alloc.dupe(u8, "summary") };
    }
};

test "a compaction instruction from the user is added to each summary request and none leaves the request as it was" {
    var cancel = std.atomic.Value(bool).init(false);
    const prompt: summarize.Prompt = .{ .model = "anthropic/claude-opus-5.5", .system = "s", .user = "u" };

    var asked: InstructionCaller = .{ .expected_user = "u\n\n" ++ user_instruction_lead ++ "keep the database schema decisions" };
    var summarizer: Summarizer = .{ .caller = asked.caller(), .cancel_flag = &cancel, .trace_ctx = .{}, .instruction = "  keep the database schema decisions\n" };
    const summary_model = summarizer.model();
    const text = try summary_model.summarize_fn(summary_model.context, std.testing.allocator, prompt);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("summary", text);
    try std.testing.expectEqual(@as(usize, 1), asked.calls);
    try std.testing.expectEqual(@as(usize, 1), asked.matched);

    var plain: InstructionCaller = .{ .expected_user = "u" };
    var plain_summarizer: Summarizer = .{ .caller = plain.caller(), .cancel_flag = &cancel, .trace_ctx = .{}, .instruction = " \n" };
    const plain_model = plain_summarizer.model();
    const plain_text = try plain_model.summarize_fn(plain_model.context, std.testing.allocator, prompt);
    defer std.testing.allocator.free(plain_text);
    try std.testing.expectEqual(@as(usize, 1), plain.matched);
}

test "lowest reasoning effort turns reasoning off when the model allows it" {
    const none = types.ReasoningEffort.literal("none");
    const low = types.ReasoningEffort.literal("low");
    const Options = model_capabilities.ReasoningEffortOptions;
    const with_off = [_]types.ReasoningEffort{ none, types.ReasoningEffort.literal("minimal"), low, types.ReasoningEffort.literal("xhigh") };
    const without_off = [_]types.ReasoningEffort{ low, types.ReasoningEffort.literal("medium"), types.ReasoningEffort.literal("xhigh"), types.ReasoningEffort.literal("max") };
    try std.testing.expect(lowestReasoningEffort(.{ .reasoning_efforts = Options.fromSlice(&with_off) }).?.eql(none));
    try std.testing.expect(lowestReasoningEffort(.{ .reasoning_efforts = Options.fromSlice(&without_off) }).?.eql(low));
    try std.testing.expect(lowestReasoningEffort(.{}) == null);
}

test "the fallback is another model family" {
    try std.testing.expectEqualStrings("openai/gpt-6-sol", fallbackModel("anthropic/claude-opus-5.5"));
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-5", fallbackModel("openai/gpt-6-sol"));
}

const ScriptedCaller = struct {
    replies: []const ?[]const u8,
    calls: std.ArrayList(Call) = .empty,

    fn caller(self: *ScriptedCaller, provider: model_provider.ProviderId) ModelCaller {
        return .{
            .context = self,
            .vtable = &.{ .capabilities = capabilities, .send = send },
            .model = "anthropic/claude-opus-5.5",
            .provider = provider,
            .credential_source = null,
        };
    }

    fn capabilities(_: *anyopaque, model_name: []const u8) model_capabilities.Capabilities {
        const levels = [_]types.ReasoningEffort{ types.ReasoningEffort.literal("low"), types.ReasoningEffort.literal("xhigh") };
        const off = [_]types.ReasoningEffort{ types.ReasoningEffort.literal("none"), types.ReasoningEffort.literal("high") };
        return .{ .reasoning_efforts = .fromSlice(if (std.mem.startsWith(u8, model_name, "openai/")) &off else &levels) };
    }

    fn send(context: *anyopaque, alloc: Allocator, call: Call) CallError!Reply {
        const self: *ScriptedCaller = @ptrCast(@alignCast(context));
        try self.calls.append(std.testing.allocator, call);
        const text = self.replies[self.calls.items.len - 1] orelse
            return .{ .failed = .{ .reason = .provider, .detail = try alloc.dupe(u8, "kind=bad_request detail=refused") } };
        return .{ .text = try alloc.dupe(u8, text) };
    }
};

test "a failed or empty summary falls back to another family at its lowest reasoning" {
    var cancel = std.atomic.Value(bool).init(false);
    const prompt: summarize.Prompt = .{ .model = "anthropic/claude-opus-5.5", .system = "s", .user = "u" };
    for ([_]?[]const u8{ null, " \n" }) |first| {
        var scripted: ScriptedCaller = .{ .replies = &.{ first, "summary" } };
        defer scripted.calls.deinit(std.testing.allocator);
        var summarizer: Summarizer = .{ .caller = scripted.caller(.gateway), .cancel_flag = &cancel, .trace_ctx = .{} };
        const summary_model = summarizer.model();
        const text = try summary_model.summarize_fn(summary_model.context, std.testing.allocator, prompt);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings("summary", text);
        try std.testing.expectEqualStrings("openai/gpt-6-sol", summarizer.fallback_used.?);
        try std.testing.expectEqual(@as(usize, 2), scripted.calls.items.len);
        try std.testing.expect(scripted.calls.items[0].reasoning.?.eql(types.ReasoningEffort.literal("low")));
        try std.testing.expectEqualStrings("openai/gpt-6-sol", scripted.calls.items[1].model);
        try std.testing.expect(scripted.calls.items[1].reasoning.?.eql(types.ReasoningEffort.literal("none")));
    }

    var direct: ScriptedCaller = .{ .replies = &.{null} };
    defer direct.calls.deinit(std.testing.allocator);
    var summarizer: Summarizer = .{ .caller = direct.caller(.codex), .cancel_flag = &cancel, .trace_ctx = .{} };
    const summary_model = summarizer.model();
    try std.testing.expectError(error.ModelFailed, summary_model.summarize_fn(summary_model.context, std.testing.allocator, prompt));
    try std.testing.expectEqual(@as(usize, 1), direct.calls.items.len);
}

test "a request after the conversation goes to its own model only, with the agent's settings" {
    var cancel = std.atomic.Value(bool).init(false);
    const prompt: summarize.Prompt = .{ .model = "anthropic/claude-opus-5.5", .system = "", .user = "u", .after_conversation = true };
    var scripted: ScriptedCaller = .{ .replies = &.{ null, "summary" } };
    defer scripted.calls.deinit(std.testing.allocator);
    var summarizer: Summarizer = .{ .caller = scripted.caller(.gateway), .cancel_flag = &cancel, .trace_ctx = .{} };
    const summary_model = summarizer.model();
    try std.testing.expectError(error.ModelFailed, summary_model.summarize_fn(summary_model.context, std.testing.allocator, prompt));
    try std.testing.expectEqual(@as(usize, 1), scripted.calls.items.len);
    try std.testing.expect(scripted.calls.items[0].after_conversation);
    try std.testing.expect(scripted.calls.items[0].reasoning == null);
    try std.testing.expect(summarizer.fallback_used == null);
}
