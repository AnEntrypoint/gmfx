const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const definitions = @import("../core/config/configured_provider.zig");
const chat_completions = @import("chat_completions.zig");
const gateway_client = @import("client.zig");
const host_stream = @import("host_stream_provider.zig");

const Allocator = std.mem.Allocator;

pub const Context = struct {
    transport: host_stream.Transport,
    registry: definitions.Registry,

    pub fn init(alloc: Allocator, transport: host_stream.Transport, json: []const u8) !Context {
        var registry = try definitions.Registry.parse_json(alloc, json);
        errdefer registry.deinit(alloc);
        if (registry.definitions.len != 1 or registry.definitions[0].auth != .none) {
            return error.InvalidConfiguredProvider;
        }
        return .{ .transport = transport, .registry = registry };
    }

    pub fn deinit(self: *Context, alloc: Allocator) void {
        self.registry.deinit(alloc);
    }

    pub fn definition(self: *const Context) *const definitions.Definition {
        return &self.registry.definitions[0];
    }
};

pub fn bundle(raw: ?*anyopaque, definition: *const definitions.Definition) provider_set.Bundle {
    const context: *Context = @ptrCast(@alignCast(raw orelse return .{}));
    const own = context.definition();
    if (!std.mem.eql(u8, &own.binding_identity(), &definition.binding_identity())) return .{};
    return .{
        .agent_stream = .{
            .context = context,
            .stream_fn = stream,
            .build_request_fn = buildRequest,
            .project_replay_fn = chat_completions.project_replay,
        },
        .model_catalog = chat_completions.model_catalog_provider(own),
    };
}

fn buildRequest(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.RequestData) anyerror![]u8 {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    return chat_completions.build_for(context.definition(), alloc, request);
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: stream_provider.ModelRequest) anyerror!stream_provider.Result {
    if (host_stream.deadlineExpired(request.deadline)) return error.Timeout;
    if (request.cancel_flag.load(.seq_cst)) return stream_provider.failResult(error.Cancelled);

    if (!hostCarriesCredential(request.credential)) {
        return stream_provider.failResult(error.ConfiguredProviderCredentialRequired);
    }
    const context: *Context = @ptrCast(@alignCast(raw.?));
    const transport = context.transport;
    const definition = context.definition();
    const payload = request.prepared_request_body orelse
        try chat_completions.build_for(definition, alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    const endpoint = try definition.endpoint_url(alloc);
    defer alloc.free(endpoint);
    var headers_buffer: [3]std.http.Header = undefined;
    const headers = chat_completions.host_request_headers(&headers_buffer, definition.protocol, request.streaming);

    const opened = try host_stream.openPost(alloc, transport, request, endpoint, headers, payload);
    defer transport.close(opened.handle);
    if (opened.status != .ok) {
        const body = try host_stream.readErrorBody(alloc, transport, opened.handle, request);
        return .{ .failed = .{
            .kind = gateway_client.httpFailureKind(alloc, .fromHttpStatus(opened.status), body),
            .http_status = opened.status,
            .detail = body,
            .retry_after_seconds = opened.retry_after_seconds,
            .ownership = .owned,
        } };
    }

    var reader: host_stream.HostStreamReader = undefined;
    reader.init(transport, opened.handle, request.cancel_flag, request.deadline, request.cooperative_pulse);
    const result = chat_completions.consume(alloc, &reader.interface, definition.protocol, request, null) catch |err| switch (err) {
        error.ReadFailed => return host_stream.readFailure(&reader, request.cancel_flag),
        else => return err,
    };
    switch (result) {
        .completed => |completed| host_stream.signalConsumed(transport, opened.handle, request, completed.completion),
        else => {},
    }
    return result;
}

fn hostCarriesCredential(lease: stream_provider.CredentialLease) bool {
    const source = lease.credentialSource() orelse return false;
    if (source == .host_managed) return true;
    const secret = lease.secret() orelse "";
    return source == .configured and secret.len == 0;
}

const FakeTransport = @import("host_transport_testing.zig").FakeTransport;

const test_provider =
    \\{"local":{"protocol":"openai-chat-completions","base_url":"https://models.example/v1/","auth":{"type":"none"},
    \\"model_metadata":{"local-model":{"context_window":8192,"supports_tool_use":true}}}}
;

const reply_sse =
    "data: {\"id\":\"chat-1\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"libfx on a custom provider\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

test "host chat completions posts the CLI's request to the provider's base URL without credentials" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .model = "local-model", .responses = &.{.{ .status = 200, .body = reply_sse }} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), test_provider);
    defer context.deinit(alloc);
    const agent_stream = bundle(&context, context.definition()).agent_stream.?;
    var result = try agent_stream.stream(alloc, fake.request(.host_managed));
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("POST", fake.methods[0]);
    try std.testing.expectEqualStrings("https://models.example/v1/chat/completions", fake.urls[0]);
    try std.testing.expectEqualStrings(
        "[{\"name\":\"content-type\",\"value\":\"application/json\"},{\"name\":\"accept\",\"value\":\"text/event-stream\"}]",
        fake.headers[0],
    );
    try std.testing.expectEqualStrings(fake.prepared_body, fake.bodies[0]);
    try std.testing.expectEqualStrings("libfx on a custom provider", result.completed.completion.content.?);
    try std.testing.expectEqual(@as(usize, 1), fake.consumed);
    try std.testing.expectEqual(fake.calls, fake.closed);
}

test "host chat completions returns the error status and body of a rejected request" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .model = "local-model", .responses = &.{.{ .status = 401, .body = "{\"error\":\"invalid key\"}" }} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), test_provider);
    defer context.deinit(alloc);
    var result = try bundle(&context, context.definition()).agent_stream.?.stream(alloc, fake.request(.host_managed));
    defer result.deinit(alloc);

    try std.testing.expectEqual(stream_provider.FailureKind.unauthorized, result.failed.kind);
    try std.testing.expectEqualStrings("{\"error\":\"invalid key\"}", result.failed.detail.?);
    try std.testing.expectEqual(@as(usize, 0), fake.consumed);
    try std.testing.expectEqual(fake.calls, fake.closed);
}

test "host chat completions refuses a credential held by the engine without sending" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .model = "local-model", .responses = &.{.{ .status = 200, .body = reply_sse }} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), test_provider);
    defer context.deinit(alloc);
    const lease: stream_provider.CredentialLease = .{ .direct = .{ .secret_bytes = "provider-key", .source = .configured } };
    try std.testing.expectError(
        error.ConfiguredProviderCredentialRequired,
        bundle(&context, context.definition()).agent_stream.?.stream(alloc, fake.request(lease)),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.calls);
}

test "host chat completions sends for a keyless configured credential, as the terminal surface holds" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .model = "local-model", .responses = &.{.{ .status = 200, .body = reply_sse }} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), test_provider);
    defer context.deinit(alloc);
    const lease: stream_provider.CredentialLease = .{ .direct = .{ .secret_bytes = "", .source = .configured } };
    var result = try bundle(&context, context.definition()).agent_stream.?.stream(alloc, fake.request(lease));
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("libfx on a custom provider", result.completed.completion.content.?);
}

test "host chat completions serves only its own provider and lists the declared models" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .responses = &.{} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), test_provider);
    defer context.deinit(alloc);

    var same = try definitions.Registry.parse_json(alloc, test_provider);
    defer same.deinit(alloc);
    const served = bundle(&context, &same.definitions[0]);
    try std.testing.expect(served.agent_stream != null);
    var listed = try served.model_catalog.?.fetch(alloc, .{ .endpoint = "unused" });
    defer @import("../core/gateway/model_catalog.zig").freeModelCatalog(alloc, &listed.catalog);
    try std.testing.expectEqual(@as(usize, 1), listed.catalog.items.len);
    try std.testing.expectEqualStrings("local-model", listed.catalog.items[0].id);

    var moved = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"https://elsewhere.example/v1","auth":{"type":"none"}}}
    );
    defer moved.deinit(alloc);
    try std.testing.expect(bundle(&context, &moved.definitions[0]).agent_stream == null);
    try std.testing.expect(bundle(null, &same.definitions[0]).agent_stream == null);
}

test "host chat completions context refuses settings it cannot honor" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .responses = &.{} };
    defer fake.deinit();
    for ([_][]const u8{
        \\{}
        ,
        \\{"one":{"protocol":"openai-chat-completions","base_url":"https://a.example/v1","auth":{"type":"none"}},
        \\"two":{"protocol":"openai-chat-completions","base_url":"https://b.example/v1","auth":{"type":"none"}}}
        ,
        \\{"keyed":{"protocol":"openai-chat-completions","base_url":"https://a.example/v1","auth":{"type":"bearer","env":"PROVIDER_KEY"}}}
    }) |json| {
        try std.testing.expectError(error.InvalidConfiguredProvider, Context.init(alloc, fake.transport(), json));
    }
    try std.testing.expectError(error.InsecureBaseUrl, Context.init(alloc, fake.transport(),
        \\{"plain":{"protocol":"openai-chat-completions","base_url":"http://models.example/v1","auth":{"type":"none"}}}
    ));
}


const reply_message = "{\"id\":\"chat-2\",\"model\":\"local-model\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"libfx from a JSON reply\"},\"finish_reason\":\"stop\"}]}";

test "host chat completions answers a non-streaming request with one JSON message" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .model = "local-model", .responses = &.{.{ .status = 200, .body = reply_message }} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), test_provider);
    defer context.deinit(alloc);
    const agent_stream = bundle(&context, context.definition()).agent_stream.?;
    var request = fake.request(.host_managed);
    request.prepared_request_body = null;
    request.messages = &.{.{ .role = .user, .content = "hi" }};
    request.streaming = false;
    var result = try agent_stream.stream(alloc, request);
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings(
        "[{\"name\":\"content-type\",\"value\":\"application/json\"},{\"name\":\"accept\",\"value\":\"application/json\"}]",
        fake.headers[0],
    );
    try std.testing.expect(std.mem.find(u8, fake.bodies[0], "\"stream\":false") != null);
    try std.testing.expectEqualStrings("libfx from a JSON reply", result.completed.completion.content.?);
}

const anthropic_provider = "{\"claude\":{\"protocol\":\"anthropic-messages\",\"base_url\":\"https://models.example/v1/\",\"auth\":{\"type\":\"none\"},\"model_metadata\":{\"claude-test\":{\"context_window\":8192,\"supports_tool_use\":true}}}}";

const anthropic_stream_reply =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_h\",\"usage\":{\"input_tokens\":4,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"libfx over messages\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":2}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "host anthropic messages posts to /messages with anthropic-version and streams text" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .model = "claude-test", .responses = &.{.{ .status = 200, .body = anthropic_stream_reply }} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), anthropic_provider);
    defer context.deinit(alloc);
    const agent_stream = bundle(&context, context.definition()).agent_stream.?;
    var request = fake.request(.host_managed);
    request.prepared_request_body = null;
    request.messages = &.{.{ .role = .user, .content = "hi" }};
    var result = try agent_stream.stream(alloc, request);
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("POST", fake.methods[0]);
    try std.testing.expectEqualStrings("https://models.example/v1/messages", fake.urls[0]);
    try std.testing.expectEqualStrings(
        "[{\"name\":\"content-type\",\"value\":\"application/json\"},{\"name\":\"accept\",\"value\":\"text/event-stream\"},{\"name\":\"anthropic-version\",\"value\":\"2023-06-01\"}]",
        fake.headers[0],
    );
    try std.testing.expect(std.mem.find(u8, fake.bodies[0], "\"stream\":true") != null);
    try std.testing.expectEqualStrings("libfx over messages", result.completed.completion.content.?);
    try std.testing.expectEqual(@as(usize, 1), fake.consumed);
}

const anthropic_reply_message = "{\"id\":\"msg_h2\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-test\",\"content\":[{\"type\":\"text\",\"text\":\"libfx from a messages reply\"}],\"stop_reason\":\"end_turn\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":4,\"output_tokens\":2}}";

test "host anthropic messages answers a non-streaming request with one JSON message" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .model = "claude-test", .responses = &.{.{ .status = 200, .body = anthropic_reply_message }} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), anthropic_provider);
    defer context.deinit(alloc);
    const agent_stream = bundle(&context, context.definition()).agent_stream.?;
    var request = fake.request(.host_managed);
    request.prepared_request_body = null;
    request.messages = &.{.{ .role = .user, .content = "hi" }};
    request.streaming = false;
    var result = try agent_stream.stream(alloc, request);
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings(
        "[{\"name\":\"content-type\",\"value\":\"application/json\"},{\"name\":\"accept\",\"value\":\"application/json\"},{\"name\":\"anthropic-version\",\"value\":\"2023-06-01\"}]",
        fake.headers[0],
    );
    try std.testing.expect(std.mem.find(u8, fake.bodies[0], "\"stream\":false") != null);
    try std.testing.expectEqualStrings("libfx from a messages reply", result.completed.completion.content.?);
    try std.testing.expectEqual(@as(usize, 1), fake.consumed);
}

const anthropic_host_rejected_body = "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"model rejected\"}}";

test "host anthropic messages returns the status and body of a rejected request" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .model = "claude-test", .responses = &.{.{ .status = 400, .body = anthropic_host_rejected_body }} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), anthropic_provider);
    defer context.deinit(alloc);
    const agent_stream = bundle(&context, context.definition()).agent_stream.?;
    var request = fake.request(.host_managed);
    request.prepared_request_body = null;
    request.messages = &.{.{ .role = .user, .content = "hi" }};
    var result = try agent_stream.stream(alloc, request);
    defer result.deinit(alloc);
    try std.testing.expect(std.meta.activeTag(result) == .failed);
    const failure = result.failed;
    try std.testing.expectEqual(std.http.Status.bad_request, failure.http_status.?);
    try std.testing.expectEqual(stream_provider.FailureKind.invalid_request, failure.kind);
    try std.testing.expect(std.mem.find(u8, failure.detail.?, "invalid_request_error") != null);
}

const host_tool_functions = [_]@import("../core/tooling/model_tool_schema.zig").FunctionSchema{.{ .name = "read_file", .description = "Read a file.", .input_schema = .{
    .properties = &.{.{ .name = "path", .json_type = .string }},
    .required = &.{"path"},
    .additional_properties = false,
} }};

const ToolProbe = struct {
    started: usize = 0,
    input: [128]u8 = undefined,
    input_len: usize = 0,

    fn on_event(raw: *anyopaque, event: stream_provider.Event) void {
        const self: *ToolProbe = @ptrCast(@alignCast(raw));
        switch (event) {
            .tool_started => self.started += 1,
            .tool_input_delta => |text| {
                @memcpy(self.input[self.input_len..][0..text.len], text);
                self.input_len += text.len;
            },
            else => {},
        }
    }
};

const openai_tool_reply =
    "data: {\"id\":\"chat-t\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"tool_calls\":[{\"index\":0,\"id\":\"call_h\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"\"}}]},\"finish_reason\":null}]}\n\n" ++
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}}]},\"finish_reason\":null}]}\n\n" ++
    "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
    "data: [DONE]\n\n";

test "host chat completions streams a tool call, reports its start, and sends advertised tools" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .model = "local-model", .responses = &.{.{ .status = 200, .body = openai_tool_reply }} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), test_provider);
    defer context.deinit(alloc);
    const agent_stream = bundle(&context, context.definition()).agent_stream.?;
    var probe: ToolProbe = .{};
    var request = fake.request(.host_managed);
    request.prepared_request_body = null;
    request.messages = &.{.{ .role = .user, .content = "read a.txt" }};
    request.tools = .{ .advertised_names = &.{"read_file"}, .advertised_functions = &host_tool_functions };
    request.events = .{ .context = &probe, .emit_fn = ToolProbe.on_event };
    var result = try agent_stream.stream(alloc, request);
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, fake.bodies[0], "\"tools\":[") != null);
    try std.testing.expect(std.mem.find(u8, fake.bodies[0], "\"name\":\"read_file\"") != null);
    try std.testing.expectEqual(@as(usize, 1), probe.started);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", probe.input[0..probe.input_len]);
    const completion = result.completed.completion;
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_h", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", completion.tool_calls[0].arguments_json);
}

const anthropic_tool_reply =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_ht\",\"usage\":{\"input_tokens\":20,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_h\",\"name\":\"read_file\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"pa\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"th\\\":\\\"a.txt\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":9}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "host anthropic messages streams a tool call, reports its start, and sends advertised tools" {
    const alloc = std.testing.allocator;
    var fake = FakeTransport{ .model = "claude-test", .responses = &.{.{ .status = 200, .body = anthropic_tool_reply }} };
    defer fake.deinit();
    var context = try Context.init(alloc, fake.transport(), anthropic_provider);
    defer context.deinit(alloc);
    const agent_stream = bundle(&context, context.definition()).agent_stream.?;
    var probe: ToolProbe = .{};
    var request = fake.request(.host_managed);
    request.prepared_request_body = null;
    request.messages = &.{.{ .role = .user, .content = "read a.txt" }};
    request.tools = .{ .advertised_names = &.{"read_file"}, .advertised_functions = &host_tool_functions };
    request.events = .{ .context = &probe, .emit_fn = ToolProbe.on_event };
    var result = try agent_stream.stream(alloc, request);
    defer result.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, fake.bodies[0], "\"input_schema\"") != null);
    try std.testing.expect(std.mem.find(u8, fake.bodies[0], "\"name\":\"read_file\"") != null);
    try std.testing.expectEqual(@as(usize, 1), probe.started);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", probe.input[0..probe.input_len]);
    const completion = result.completed.completion;
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("toolu_h", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", completion.tool_calls[0].arguments_json);
}
