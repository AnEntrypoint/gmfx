const std = @import("std");
const codec = @import("chat_completions_protocol.zig");
const messages_codec = @import("messages_protocol.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");

const max_message_body_bytes = 8 * 1024 * 1024;
const client_mod = @import("client.zig");
const definitions = @import("../core/config/configured_provider.zig");
const streams = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const model_catalog_metadata = @import("../core/gateway/model_catalog_metadata.zig");
const classifier = @import("../core/permissions/auto_classifier.zig");
const gateway_step = @import("../core/agent/runtime/gateway_step.zig");
const review_messages = @import("vercel_protocol.zig");
const io = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const model_provider = @import("../core/config/model_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const sse = @import("sse.zig");
const Allocator = std.mem.Allocator;

pub fn bundle(definition: *const definitions.Definition) provider_set.Bundle {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{
        .agent_stream = .{ .context = context, .stream_fn = stream, .build_request_fn = build, .project_replay_fn = project_replay },
        .model_catalog = model_catalog_provider(definition),
        .cli_model_catalog = .{ .context = context, .fetch_fn = fetch_cli_catalog },
        .permission_reviewer = .{ .context = context, .review_fn = review },
    };
}

pub fn model_catalog_provider(definition: *const definitions.Definition) catalog.Provider {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{ .context = context, .fetch_fn = fetch_catalog, .lookup_capabilities_fn = lookup_capabilities, .provider_id = bound_identity(definition) };
}

fn definition_at(raw: ?*anyopaque) *const definitions.Definition {
    return @ptrCast(@alignCast(raw.?));
}

fn bound_identity(definition: *const definitions.Definition) model_provider.ProviderId {
    var identity = model_provider.parse(definition.id).?;
    identity.configured.binding = definition.binding_identity();
    return identity;
}

fn build(raw: ?*anyopaque, alloc: Allocator, request: streams.RequestData) ![]u8 {
    return build_for(definition_at(raw), alloc, request);
}

pub fn build_for(definition: *const definitions.Definition, alloc: Allocator, request: streams.RequestData) ![]u8 {
    const identity = bound_identity(definition);
    for (request.messages) |message| if (message.provider_replay) |replay| {
        if (!replay.matches(.{ .provider = identity, .model = request.model })) {
            debug_trace.logf("gateway", "provider_replay_omitted reason=source_mismatch", .{});
            break;
        }
    };
    const options: codec.Options = .{ .tool_choice_mode = definition.tool_choice_mode, .provider = &identity };
    return switch (definition.protocol) {
        .@"openai-chat-completions" => codec.build_request(alloc, request, options),
        .@"anthropic-messages" => messages_codec.build_request(alloc, request, options),
    };
}

pub fn project_replay(alloc: Allocator, replay: ?types.ProviderReplay, calls: []const types.ToolCall, text: bool, reasoning: bool) !?types.ProviderReplay {
    const selected = try codec.project_replay(alloc, replay, calls, text, reasoning);
    if (replay != null and selected == null) debug_trace.logf("gateway", "provider_replay_omitted reason={s}", .{if (reasoning) "associated_calls_removed" else "reasoning_removed"});
    return selected;
}

test "chat completions adapter binds replay to endpoint authority and wires projection" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"}}}
    );
    defer registry.deinit(alloc);
    var changed_registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:5678/v1","auth":{"type":"none"}}}
    );
    defer changed_registry.deinit(alloc);
    const definition = registry.get("local").?;
    const adapter = bundle(definition).agent_stream.?;
    const replay: types.ProviderReplay = .{
        .source = .{ .provider = bundle(definition).model_catalog.?.provider_id, .model = "model" },
        .parts_json = "{\"reasoning_details\":[{\"signature\":\"signed\"}],\"_tool_call_ids\":[]}",
    };
    const selected = (try adapter.projectReplay(alloc, replay, &.{}, false, true)).?;
    try std.testing.expect(selected.parts_json.ptr == replay.parts_json.ptr);
    try std.testing.expect(try adapter.projectReplay(alloc, replay, &.{}, true, false) == null);
    const request: streams.RequestData = .{
        .model = "model",
        .instructions = &.{.{ .role = .system, .content = "instructions" }},
        .messages = &.{.{ .role = .assistant, .content = "answer", .provider_replay = replay }},
        .tool_choice = .auto,
        .provider_options = .{},
    };
    const matching = try adapter.build_request_fn.?(adapter.context, alloc, request);
    defer alloc.free(matching);
    try std.testing.expect(std.mem.find(u8, matching, "reasoning_details") != null);
    const other = bundle(changed_registry.get("local").?).agent_stream.?;
    const stripped = try other.build_request_fn.?(other.context, alloc, request);
    defer alloc.free(stripped);
    try std.testing.expect(std.mem.find(u8, stripped, "reasoning_details") == null);
    try std.testing.expect(request.messages[0].provider_replay.?.parts_json.ptr == replay.parts_json.ptr);
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: streams.ModelRequest) !streams.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const definition = definition_at(raw);
    if (request.credential.credentialSource() != .configured) return error.ConfiguredProviderCredentialRequired;
    const token = request.credential.secret();
    if (token) |value| {
        if (value.len > 16 * 1024) return error.InvalidConfiguredProviderCredential;
        for (value) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidConfiguredProviderCredential;
    }
    switch (definition.auth) {
        .none => if (token != null) return error.UnexpectedConfiguredProviderCredential,
        .bearer, .bearer_key => if (token == null) return error.MissingConfiguredProviderCredential,
    }
    const payload = request.prepared_request_body orelse try build(raw, alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    return post(alloc, definition, request, token, payload) catch |err| {
        request.attempt_evidence.network_failure = client_mod.networkFailureEvidence(err, request.delivery.load());
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (request.deadline) |deadline| if (expired(deadline)) return error.Timeout;
        return err;
    };
}

fn expired(deadline: std.Io.Clock.Timestamp) bool {
    return !std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io.getIo(), .awake), .lt, deadline);
}

fn phase_deadline(milliseconds: i64, caller: ?std.Io.Clock.Timestamp) std.Io.Clock.Timestamp {
    const phase = std.Io.Clock.Timestamp.fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(milliseconds) });
    if (caller) |deadline| if (std.Io.Clock.Timestamp.compare(deadline, .lt, phase)) return deadline;
    return phase;
}

fn post(alloc: Allocator, definition: *const definitions.Definition, request: streams.ModelRequest, token: ?[]const u8, payload: []const u8) !streams.Result {
    const url = try definition.endpoint_url(alloc);
    defer alloc.free(url);
    const authorization = if (definition.protocol == .@"anthropic-messages") null else try bearer(alloc, token);
    defer if (authorization) |value| secret.zeroAndFree(alloc, value);
    var headers_buffer: [3]std.http.Header = undefined;
    var uri = try std.Uri.parse(url);
    uri.scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) "https" else if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) "http" else return error.UnsupportedUriScheme;
    try request.admission.admit();
    var opened = try client_mod.openBoundedPost(request.cancel_flag, phase_deadline(30_000, request.deadline), .{
        .uri = uri,
        .authorization = authorization,
        .extra_headers = request_headers(&headers_buffer, definition.protocol, token, request.streaming),
    });
    defer opened.deinit();
    const http = &opened.request;
    var watch: client_mod.ConnectionWatch = .init(.{
        .timeout_ms = 120_000,
        .stall_timeout_ms = client_mod.ConnectionWatch.bodyStallTimeoutMs(request.deadline),
    });
    defer watch.stop();
    if (http.connection) |connection| try watch.start(request.cancel_flag, request.deadline, connection.stream_writer.stream);

    if (watch.armHead()) |err| return err;
    http.transfer_encoding = .{ .content_length = payload.len };
    var buffer: [8192]u8 = undefined;
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    request.delivery.markPossiblySent();
    var body = try http.sendBodyUnflushed(&buffer);
    try body.writer.writeAll(payload);
    try body.end();
    if (http.connection) |connection| try connection.flush();
    var response = http.receiveHead(&.{}) catch |err| return watch.failure(err);
    if (watch.commitHead()) |err| return err;
    if (response.head.status != .ok) {
        watch.stop();
        watch = .init(.{ .patient = true, .stall_timeout_ms = std.math.maxInt(i64) });
        if (http.connection) |connection| try watch.start(request.cancel_flag, phase_deadline(30_000, request.deadline), connection.stream_writer.stream);
    }
    var retry_after: ?u64 = null;
    var headers = response.head.iterateHeaders();
    while (headers.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
        retry_after = std.fmt.parseUnsigned(u64, std.mem.trim(u8, header.value, " \t"), 10) catch null;
        break;
    };
    var transfer: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);
    if (response.head.status != .ok) {
        var detail = reader.allocRemaining(alloc, .limited(64 * 1024)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "Provider error response exceeded the local limit"),
            else => return err,
        };
        errdefer alloc.free(detail);
        if (token) |value| {
            const redacted = try codec.redact_error_detail(alloc, detail, value);
            alloc.free(detail);
            detail = redacted;
        }

        return .{ .failed = .{ .kind = client_mod.httpFailureKind(alloc, .fromHttpStatus(response.head.status), detail), .http_status = response.head.status, .detail = detail, .retry_after_seconds = retry_after, .ownership = .owned } };
    }
    var result = consume(alloc, reader, definition.protocol, request, watch.progress()) catch |err| return watch.failure(err);
    if (watch.finish()) |err| {
        result.deinit(alloc);
        return err;
    }
    return result;
}

fn bearer(alloc: Allocator, token: ?[]const u8) !?[]u8 {
    const value = token orelse return null;
    return try alloc.print("Bearer {s}", .{value});
}

fn request_headers(buffer: *[3]std.http.Header, protocol: definitions.Protocol, token: ?[]const u8, streaming: bool) []const std.http.Header {
    buffer[0] = .{ .name = "accept", .value = if (streaming) "text/event-stream" else "application/json" };
    if (protocol != .@"anthropic-messages") return buffer[0..1];
    buffer[1] = .{ .name = "anthropic-version", .value = messages_codec.api_version };
    const key = token orelse return buffer[0..2];
    buffer[2] = .{ .name = "x-api-key", .value = key };
    return buffer[0..3];
}

pub fn host_request_headers(buffer: *[3]std.http.Header, protocol: definitions.Protocol, streaming: bool) []const std.http.Header {
    buffer[0] = .{ .name = "content-type", .value = "application/json" };
    buffer[1] = .{ .name = "accept", .value = if (streaming) "text/event-stream" else "application/json" };
    if (protocol != .@"anthropic-messages") return buffer[0..2];
    buffer[2] = .{ .name = "anthropic-version", .value = messages_codec.api_version };
    return buffer[0..3];
}

pub fn consume(alloc: Allocator, reader: *std.Io.Reader, protocol: definitions.Protocol, request: streams.ModelRequest, progress: ?sse.Progress) !streams.Result {
    var limits: codec.Limits = .{};
    if (request.content_capture_limit) |limit| limits.content_bytes = @min(limit, limits.content_bytes);
    if (!request.streaming) {
        const body = reader.allocRemaining(alloc, .limited(max_message_body_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.ContentTooLarge,
            else => |failure| return failure,
        };
        defer alloc.free(body);
        return switch (protocol) {
            .@"openai-chat-completions" => codec.consume_message(alloc, body, request.data(), limits, request.cancel_flag),
            .@"anthropic-messages" => messages_codec.consume_message(alloc, body, request.data()),
        };
    }
    return switch (protocol) {
        .@"openai-chat-completions" => codec.consume_stream(alloc, reader, request.data(), limits, request.events, request.cancel_flag, progress),
        .@"anthropic-messages" => messages_codec.consume_stream(alloc, reader, request.data(), limits, request.events, request.cancel_flag, progress),
    };
}

fn metadata_entry(metadata: definitions.ModelMetadata) catalog.ModelCatalogEntry {
    const vision = metadata.supports_vision orelse false;
    return .{
        .id = @constCast(metadata.id),
        .model_type = @constCast("language"),
        .has_tool_use = metadata.supports_tool_use orelse false,

        .has_vision = vision,
        .has_file_input = vision,
        .context_window = metadata.context_window orelse 0,
        .max_tokens = metadata.max_output_tokens orelse 0,
    };
}

fn lookup_capabilities(raw: ?*anyopaque, model: []const u8) model_capabilities.Capabilities {
    const metadata = definition_at(raw).model(model) orelse return .{};
    return model_capabilities.mergeCapabilities(.{}, model_catalog_metadata.fromCatalogEntry(metadata_entry(metadata.*)));
}

fn fetch_catalog(raw: ?*anyopaque, alloc: Allocator, input: catalog.FetchInput) Allocator.Error!catalog.ProviderResult {
    if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    const definition = definition_at(raw);
    var entries: std.ArrayList(catalog.ModelCatalogEntry) = .empty;
    errdefer catalog.freeModelCatalog(alloc, &entries);
    for (definition.model_metadata) |metadata| {
        var entry = metadata_entry(metadata);
        entry.id = try alloc.dupe(u8, entry.id);
        errdefer alloc.free(entry.id);
        entry.model_type = try alloc.dupe(u8, entry.model_type);
        errdefer alloc.free(entry.model_type);
        try entries.append(alloc, entry);
    }
    return .{ .catalog = entries };
}

test "configured capability lookup matches catalog projection and preserves unknowns" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"},"model_metadata":{"small":{"context_window":8192,"max_output_tokens":512,"supports_tool_use":true,"supports_vision":true},"large":{"context_window":32768,"max_output_tokens":1024,"supports_tool_use":false},"partial":{"max_output_tokens":128},"unknown":{}}}}
    );
    defer registry.deinit(alloc);
    const provider = bundle(registry.get("local").?).model_catalog.?;
    var fetched = try provider.fetch(alloc, .{ .endpoint = "unused" });
    defer catalog.freeModelCatalog(alloc, &fetched.catalog);
    for (fetched.catalog.items) |entry| {
        const actual = provider.lookupCapabilities(entry.id).?;
        try model_capabilities.expectCapabilitiesEqualForTest(model_capabilities.mergeCapabilities(.{}, model_catalog_metadata.fromCatalogEntry(entry)), actual);
        const declared_vision = std.mem.eql(u8, entry.id, "small");
        try std.testing.expectEqual(declared_vision, actual.supports_vision);
        try std.testing.expectEqual(
            if (declared_vision) model_capabilities.ImageInputSupport.native else model_capabilities.ImageInputSupport.non_native,
            actual.image_input_support,
        );
    }
    try std.testing.expectEqual(@as(?u32, 512), provider.lookupCapabilities("small").?.max_output_tokens);
    try std.testing.expectEqual(@as(?u32, 1024), provider.lookupCapabilities("large").?.max_output_tokens);
    try std.testing.expect(provider.lookupCapabilities("partial").?.context_window == null);
    try std.testing.expect(provider.lookupCapabilities("unknown").?.max_output_tokens == null);
    try model_capabilities.expectCapabilitiesEqualForTest(.{}, provider.lookupCapabilities("missing-fast").?);
}

fn fetch_cli_catalog(raw: ?*anyopaque, alloc: Allocator, input: gateway_provider.CliModelCatalogInput) gateway_provider.CliModelCatalogResult {
    const provenance = catalog.Provenance{ .access = catalog.AccessMetadata.init(input.access) };
    const result = fetch_catalog(raw, alloc, .{ .access = input.access, .endpoint = input.endpoint, .cancel_flag = input.cancel_flag }) catch
        return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = .{ .category = .resource_exhausted } } };
    switch (result) {
        .failure => |failure| return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = failure } },
        .catalog => |value| {
            var entries = value;
            defer catalog.freeModelCatalog(alloc, &entries);
            const ids = catalog.projectModelIds(alloc, entries.items) catch return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = .{ .category = .resource_exhausted } } };
            return .{ .loaded = .{ .ids = ids, .provenance = provenance } };
        },
    }
}

const Review = struct { definition: *const definitions.Definition, input: classifier.ProviderInput };
fn review(raw: ?*anyopaque, alloc: Allocator, input: classifier.ProviderInput, request: classifier.ReviewRequest) !classifier.ParseOutcome {
    var state = Review{ .definition = definition_at(raw), .input = input };
    return classifier.Reviewer.withTransportModel(.{ .context = &state, .build_fn = build_review, .send_fn = send_review }, input.cancel_flag, classifier.Reviewer.default_timeout_ms, state.definition.reviewer_model orelse request.review_turn.model).review(alloc, request);
}
fn build_review(raw: *anyopaque, alloc: Allocator, model: []const u8, _: []const u8, instructions: []const types.ChatMessage, messages: []const types.ChatMessage, target_id: []const u8, deadline: std.Io.Clock.Timestamp, cancel: *std.atomic.Value(bool)) ![]u8 {
    const state: *Review = @ptrCast(@alignCast(raw));
    const expanded = try review_messages.expandPendingToolReviewMessages(alloc, messages, target_id, deadline, cancel);
    defer alloc.free(expanded);
    const output_limit = if (state.definition.model(model)) |metadata| @min(metadata.max_output_tokens orelse 2048, 2048) else 2048;
    return build(@ptrCast(@constCast(state.definition)), alloc, .{ .model = model, .instructions = instructions, .messages = expanded, .tools = .{ .additional_functions = &.{classifier.function_schema} }, .tool_choice = .required, .provider_options = .{}, .max_output_tokens = output_limit });
}
fn ignore_event(_: *anyopaque, _: streams.Event) void {}
fn free_result(raw: *anyopaque, alloc: Allocator) void {
    const result: *streams.Result = @ptrCast(@alignCast(raw));
    result.deinit(alloc);
    alloc.destroy(result);
}
fn send_review(raw: *anyopaque, alloc: Allocator, model: []const u8, payload: []const u8, deadline: std.Io.Clock.Timestamp, cancel: *std.atomic.Value(bool)) !classifier.TransportOutcome {
    const state: *Review = @ptrCast(@alignCast(raw));
    var delivery: streams.DeliveryCertainty = .init();
    var evidence: streams.AttemptEvidence = .{};
    var event_context: u8 = 0;
    var result = gateway_step.streamModelCompletion(bundle(state.definition).agent_stream.?, alloc, .{
        .credential = .{ .direct = .{ .secret_bytes = state.input.credential, .source = state.input.credential_source } },
        .model = model,
        .retry_count = 1,
        .messages = &.{},
        .tools = .{ .additional_functions = &.{classifier.function_schema} },
        .tool_choice = .required,
        .provider_options = .{},
        .prepared_request_body = payload,
        .trace_ctx = .{},
        .content_capture_limit = 16 * 1024,
        .deadline = deadline,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &event_context, .emit_fn = ignore_event },
        .cancel_flag = cancel,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return .cancelled,
        error.Timeout => return .timed_out,
        error.RequiredToolMissing => return .{ .completion = .{ .completion = .{} } },
        else => return .permanent_failure,
    };
    errdefer result.deinit(alloc);

    const cut_off = result == .completed and result.completed.completion.finish_reason == .length;
    if (result == .failed or cut_off) {
        result.deinit(alloc);
        return .permanent_failure;
    }
    const owned = try alloc.create(streams.Result);
    owned.* = result;
    return .{ .completion = .{ .completion = owned.completed.completion, .context = owned, .deinit_fn = free_result } };
}

const provider_server_testing = @import("provider_server_testing.zig");

const e2e_functions = [_]model_tool_schema.FunctionSchema{.{ .name = "read_file", .description = "Read a file.", .input_schema = .{
    .properties = &.{.{ .name = "path", .json_type = .string }},
    .required = &.{"path"},
    .additional_properties = false,
} }};

const anthropic_fixture_body =
    \\data: {"type":"message_start","message":{"id":"msg_fx","usage":{"input_tokens":20,"output_tokens":1}}}
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

fn fixture_request(delivery: *streams.DeliveryCertainty, evidence: *streams.AttemptEvidence, cancelled: *std.atomic.Value(bool), sink_context: *u8) streams.ModelRequest {
    return .{
        .credential = .{ .direct = .{ .secret_bytes = "test-key", .source = .configured } },
        .model = "fixture-model",
        .retry_count = 0,
        .messages = &.{.{ .role = .user, .content = "read a.txt" }},
        .tools = .{ .advertised_names = &.{"read_file"}, .advertised_functions = &e2e_functions },
        .tool_choice = .auto,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = delivery,
        .attempt_evidence = evidence,
        .events = .{ .context = sink_context, .emit_fn = ignore_event },
        .admission = .{ .context = sink_context, .admit_fn = admit_fixture },
        .cancel_flag = cancelled,
    };
}

fn admit_fixture(_: *anyopaque) anyerror!void {}

test "gateway.chat_completions.test.anthropic-messages posts to /messages with x-api-key and streams a tool call" {
    const alloc = std.testing.allocator;
    var server: provider_server_testing.Scripted = undefined;
    try server.init(anthropic_fixture_body, "text/event-stream", "200 OK");
    defer server.deinit();
    var definition: definitions.Definition = .{ .id = "local", .protocol = .@"anthropic-messages", .base_url = server.url, .auth = .{ .bearer_key = "inline" } };
    var delivery: streams.DeliveryCertainty = .init();
    var evidence: streams.AttemptEvidence = .{};
    var cancelled = std.atomic.Value(bool).init(false);
    var sink_context: u8 = 0;
    const provider = bundle(&definition).agent_stream.?;
    var result = try provider.stream_fn(provider.context, alloc, fixture_request(&delivery, &evidence, &cancelled, &sink_context));
    defer result.deinit(alloc);
    try std.testing.expect(std.meta.activeTag(result) == .completed);
    const completion = result.completed.completion;
    try std.testing.expectEqualStrings("Reading.", completion.content.?);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("toolu_1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", completion.tool_calls[0].arguments_json);
    const recorded = server.recorded();
    try std.testing.expect(std.mem.startsWith(u8, recorded, "POST /v1/messages HTTP/1.1\r\n"));
    try std.testing.expectEqualStrings("test-key", provider_server_testing.header(recorded, "x-api-key").?);
    try std.testing.expectEqualStrings("2023-06-01", provider_server_testing.header(recorded, "anthropic-version").?);
    try std.testing.expect(provider_server_testing.header(recorded, "authorization") == null);
    try std.testing.expect(std.mem.find(u8, recorded, "\"input_schema\":") != null);
    try std.testing.expect(std.mem.find(u8, recorded, "\"stream\":true") != null);
}

const openai_fixture_body =
    \\data: {"id":"chat-1","model":"fixture-model","choices":[{"index":0,"delta":{"role":"assistant","content":"Reading."},"finish_reason":null}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read_file","arguments":"{\"pa"}}]},"finish_reason":null}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"a.txt\"}"}}]},"finish_reason":null}]}
    \\
    \\data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
    \\
    \\data: [DONE]
    \\
    \\
;

test "gateway.chat_completions.test.openai-chat-completions posts to /chat/completions with bearer auth and streams a tool call" {
    const alloc = std.testing.allocator;
    var server: provider_server_testing.Scripted = undefined;
    try server.init(openai_fixture_body, "text/event-stream", "200 OK");
    defer server.deinit();
    var definition: definitions.Definition = .{ .id = "local", .protocol = .@"openai-chat-completions", .base_url = server.url, .auth = .{ .bearer_key = "inline" } };
    var delivery: streams.DeliveryCertainty = .init();
    var evidence: streams.AttemptEvidence = .{};
    var cancelled = std.atomic.Value(bool).init(false);
    var sink_context: u8 = 0;
    const provider = bundle(&definition).agent_stream.?;
    var result = try provider.stream_fn(provider.context, alloc, fixture_request(&delivery, &evidence, &cancelled, &sink_context));
    defer result.deinit(alloc);
    try std.testing.expect(std.meta.activeTag(result) == .completed);
    const completion = result.completed.completion;
    try std.testing.expectEqualStrings("Reading.", completion.content.?);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", completion.tool_calls[0].arguments_json);
    const recorded = server.recorded();
    try std.testing.expect(std.mem.startsWith(u8, recorded, "POST /v1/chat/completions HTTP/1.1\r\n"));
    try std.testing.expectEqualStrings("Bearer test-key", provider_server_testing.header(recorded, "authorization").?);
    try std.testing.expect(provider_server_testing.header(recorded, "x-api-key") == null);
    try std.testing.expect(std.mem.find(u8, recorded, "\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, recorded, "\"stream\":true") != null);
}

const anthropic_message_body = "{\"id\":\"msg_fx\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"fixture-model\",\"content\":[{\"type\":\"text\",\"text\":\"Reading.\"},{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"read_file\",\"input\":{\"path\":\"a.txt\"}}],\"stop_reason\":\"tool_use\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":20,\"output_tokens\":9}}";

test "gateway.chat_completions.test.anthropic-messages non-streaming posts stream false and decodes one JSON message" {
    const alloc = std.testing.allocator;
    var server: provider_server_testing.Scripted = undefined;
    try server.init(anthropic_message_body, "application/json", "200 OK");
    defer server.deinit();
    var definition: definitions.Definition = .{ .id = "local", .protocol = .@"anthropic-messages", .base_url = server.url, .auth = .{ .bearer_key = "inline" } };
    var delivery: streams.DeliveryCertainty = .init();
    var evidence: streams.AttemptEvidence = .{};
    var cancelled = std.atomic.Value(bool).init(false);
    var sink_context: u8 = 0;
    var request = fixture_request(&delivery, &evidence, &cancelled, &sink_context);
    request.streaming = false;
    const provider = bundle(&definition).agent_stream.?;
    var result = try provider.stream_fn(provider.context, alloc, request);
    defer result.deinit(alloc);
    try std.testing.expect(std.meta.activeTag(result) == .completed);
    const completion = result.completed.completion;
    try std.testing.expectEqualStrings("Reading.", completion.content.?);
    try std.testing.expectEqualStrings("msg_fx", completion.generation_id.?);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("toolu_1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", completion.tool_calls[0].arguments_json);
    const recorded = server.recorded();
    try std.testing.expect(std.mem.startsWith(u8, recorded, "POST /v1/messages HTTP/1.1\r\n"));
    try std.testing.expectEqualStrings("application/json", provider_server_testing.header(recorded, "accept").?);
    try std.testing.expect(std.mem.find(u8, recorded, "\"stream\":false") != null);
}


const openai_message_body = "{\"id\":\"chatcmpl_fx\",\"model\":\"fixture-model\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":9,\"total_tokens\":29}}";

test "gateway.chat_completions.test.openai-chat-completions non-streaming posts stream false and decodes one JSON message" {
    const alloc = std.testing.allocator;
    var server: provider_server_testing.Scripted = undefined;
    try server.init(openai_message_body, "application/json", "200 OK");
    defer server.deinit();
    var definition: definitions.Definition = .{ .id = "local", .protocol = .@"openai-chat-completions", .base_url = server.url, .auth = .{ .bearer_key = "inline" } };
    var delivery: streams.DeliveryCertainty = .init();
    var evidence: streams.AttemptEvidence = .{};
    var cancelled = std.atomic.Value(bool).init(false);
    var sink_context: u8 = 0;
    var request = fixture_request(&delivery, &evidence, &cancelled, &sink_context);
    request.streaming = false;
    const provider = bundle(&definition).agent_stream.?;
    var result = try provider.stream_fn(provider.context, alloc, request);
    defer result.deinit(alloc);
    try std.testing.expect(std.meta.activeTag(result) == .completed);
    const completion = result.completed.completion;
    try std.testing.expect(completion.content == null);
    try std.testing.expectEqualStrings("call_1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", completion.tool_calls[0].arguments_json);
    const recorded = server.recorded();
    try std.testing.expect(std.mem.startsWith(u8, recorded, "POST /v1/chat/completions HTTP/1.1\r\n"));
    try std.testing.expectEqualStrings("application/json", provider_server_testing.header(recorded, "accept").?);
    try std.testing.expectEqualStrings("Bearer test-key", provider_server_testing.header(recorded, "authorization").?);
    try std.testing.expect(std.mem.find(u8, recorded, "\"stream\":false") != null);
}

const openai_rejected_body = "{\"error\":{\"message\":\"model rejected for key test-key\",\"type\":\"invalid_request_error\",\"code\":\"bad_model\"}}";

test "gateway.chat_completions.test.openai-chat-completions rejected request returns its status and a redacted failure" {
    const alloc = std.testing.allocator;
    var server: provider_server_testing.Scripted = undefined;
    try server.init(openai_rejected_body, "application/json", "400 Bad Request");
    defer server.deinit();
    var definition: definitions.Definition = .{ .id = "local", .protocol = .@"openai-chat-completions", .base_url = server.url, .auth = .{ .bearer_key = "inline" } };
    var delivery: streams.DeliveryCertainty = .init();
    var evidence: streams.AttemptEvidence = .{};
    var cancelled = std.atomic.Value(bool).init(false);
    var sink_context: u8 = 0;
    const request = fixture_request(&delivery, &evidence, &cancelled, &sink_context);
    const provider = bundle(&definition).agent_stream.?;
    var result = try provider.stream_fn(provider.context, alloc, request);
    defer result.deinit(alloc);
    try std.testing.expect(std.meta.activeTag(result) == .failed);
    const failure = result.failed;
    try std.testing.expectEqual(std.http.Status.bad_request, failure.http_status.?);
    try std.testing.expectEqual(streams.FailureKind.invalid_request, failure.kind);
    try std.testing.expect(std.mem.find(u8, failure.detail.?, "invalid_request_error") != null);
    try std.testing.expect(std.mem.find(u8, failure.detail.?, "test-key") == null);
    try std.testing.expect(std.mem.find(u8, server.recorded(), "Bearer test-key") != null);
}

const anthropic_rejected_body = "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"model rejected for key test-key\"}}";

test "gateway.chat_completions.test.anthropic-messages rejected request returns its status and a redacted failure" {
    const alloc = std.testing.allocator;
    var server: provider_server_testing.Scripted = undefined;
    try server.init(anthropic_rejected_body, "application/json", "400 Bad Request");
    defer server.deinit();
    var definition: definitions.Definition = .{ .id = "local", .protocol = .@"anthropic-messages", .base_url = server.url, .auth = .{ .bearer_key = "inline" } };
    var delivery: streams.DeliveryCertainty = .init();
    var evidence: streams.AttemptEvidence = .{};
    var cancelled = std.atomic.Value(bool).init(false);
    var sink_context: u8 = 0;
    const request = fixture_request(&delivery, &evidence, &cancelled, &sink_context);
    const provider = bundle(&definition).agent_stream.?;
    var result = try provider.stream_fn(provider.context, alloc, request);
    defer result.deinit(alloc);
    try std.testing.expect(std.meta.activeTag(result) == .failed);
    const failure = result.failed;
    try std.testing.expectEqual(std.http.Status.bad_request, failure.http_status.?);
    try std.testing.expectEqual(streams.FailureKind.invalid_request, failure.kind);
    try std.testing.expect(std.mem.find(u8, failure.detail.?, "invalid_request_error") != null);
    try std.testing.expect(std.mem.find(u8, failure.detail.?, "test-key") == null);
    const recorded = server.recorded();
    try std.testing.expectEqualStrings("test-key", provider_server_testing.header(recorded, "x-api-key").?);
    try std.testing.expect(provider_server_testing.header(recorded, "authorization") == null);
}
