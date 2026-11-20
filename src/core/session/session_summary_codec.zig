const std = @import("std");
const types = @import("session_store_types.zig");
const sort_utils = @import("../shared/sort_utils.zig");

const Allocator = std.mem.Allocator;
const SessionSummary = types.SessionSummary;
const ResumableSessionContinuation = types.ResumableSessionContinuation;

pub fn cloneSessionSummary(
    alloc: Allocator,
    source: SessionSummary,
) !SessionSummary {
    const id = try alloc.dupe(u8, source.id);
    errdefer alloc.free(id);
    const workspace_root = if (source.workspace_root) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (workspace_root) |value| alloc.free(value);
    const origin_workspace_root = if (source.origin_workspace_root) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (origin_workspace_root) |value| alloc.free(value);
    const title = if (source.title) |value| try alloc.dupe(u8, value) else null;
    errdefer if (title) |value| alloc.free(value);
    const preview = if (source.preview) |value| try alloc.dupe(u8, value) else null;
    errdefer if (preview) |value| alloc.free(value);
    const last_prompt = if (source.last_prompt) |value| try alloc.dupe(u8, value) else null;
    errdefer if (last_prompt) |value| alloc.free(value);
    const last_turn_reason = if (source.last_turn_reason) |value| try alloc.dupe(u8, value) else null;
    errdefer if (last_turn_reason) |value| alloc.free(value);
    return .{
        .id = id,
        .workspace_root = workspace_root,
        .origin_workspace_root = origin_workspace_root,
        .title = title,
        .preview = preview,
        .display_metadata_present = source.display_metadata_present,
        .created_at_ms = source.created_at_ms,
        .updated_at_ms = source.updated_at_ms,
        .conversation_language = source.conversation_language,
        .history_len = source.history_len,
        .has_checkpoint = source.has_checkpoint,
        .has_managed_children = source.has_managed_children,
        .last_prompt = last_prompt,
        .archived = source.archived,
        .archived_at_ms = source.archived_at_ms,
        .last_turn_reason = last_turn_reason,
    };
}

pub fn sessionListPageFromSummaries(
    alloc: Allocator,
    summaries: []const SessionSummary,
    workspace_root: ?[]const u8,
    continuation: ?ResumableSessionContinuation,
    limit: usize,
) !types.SessionListPage {
    var page: types.SessionListPage = .{};
    errdefer page.deinit(alloc);
    for (summaries) |summary| {
        if (workspace_root) |root| {
            const summary_workspace = summary.workspace_root orelse continue;
            if (!std.mem.eql(u8, summary_workspace, root)) continue;
        }
        if (continuation) |position| {
            if (!summaryFollowsContinuation(summary, position)) continue;
        }
        if (page.summaries.items.len == limit) {
            page.has_more = true;
            break;
        }
        var copied = try cloneSessionSummary(alloc, summary);
        page.summaries.append(alloc, copied) catch |err| {
            copied.deinit(alloc);
            return err;
        };
    }
    return page;
}

pub fn summaryFollowsContinuation(
    summary: SessionSummary,
    continuation: ResumableSessionContinuation,
) bool {
    if (summary.updated_at_ms != continuation.updated_at_ms) {
        return summary.updated_at_ms < continuation.updated_at_ms;
    }
    return std.mem.order(u8, summary.id, continuation.id) == .lt;
}

pub fn sortSummariesNewestFirst(items: []SessionSummary) void {
    sort_utils.sort(SessionSummary, items, {}, lessSummaryNewerFirst);
}

fn lessSummaryNewerFirst(_: void, a: SessionSummary, b: SessionSummary) bool {
    if (a.updated_at_ms != b.updated_at_ms) return a.updated_at_ms > b.updated_at_ms;
    return std.mem.order(u8, a.id, b.id) == .gt;
}

test "summary clone owns every string" {
    const alloc = std.testing.allocator;
    var clone = try cloneSessionSummary(alloc, .{
        .id = @constCast("session"),
        .workspace_root = @constCast("/workspace"),
        .origin_workspace_root = @constCast("/origin"),
        .title = @constCast("Title"),
        .preview = @constCast("Preview"),
        .display_metadata_present = true,
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = .literal("en"),
        .history_len = 3,
    });
    defer clone.deinit(alloc);
    try std.testing.expectEqualStrings("session", clone.id);
    try std.testing.expectEqualStrings("Title", clone.title.?);
    try std.testing.expectEqualStrings("Preview", clone.preview.?);
}

test "session summary round trips lastPrompt, timestamps and archive state" {
    const alloc = std.testing.allocator;
    var clone = try cloneSessionSummary(alloc, .{
        .id = @constCast("session"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = .literal("en"),
        .history_len = 1,
        .last_prompt = @constCast("fix the build"),
        .archived = true,
        .archived_at_ms = 3,
        .last_turn_reason = @constCast("cancelled"),
    });
    defer clone.deinit(alloc);
    try std.testing.expectEqual(@as(i64, 1), clone.created_at_ms);
    try std.testing.expectEqual(@as(i64, 2), clone.updated_at_ms);
    try std.testing.expectEqualStrings("fix the build", clone.last_prompt.?);
    try std.testing.expect(clone.archived);
    try std.testing.expectEqual(@as(i64, 3), clone.archived_at_ms.?);
    try std.testing.expectEqualStrings("cancelled", clone.last_turn_reason.?);
}

test "session summary defaults the lifecycle fields when a source has none" {
    const alloc = std.testing.allocator;
    var clone = try cloneSessionSummary(alloc, .{
        .id = @constCast("session"),
        .created_at_ms = 1,
        .updated_at_ms = 2,
        .conversation_language = .literal("en"),
        .history_len = 1,
    });
    defer clone.deinit(alloc);
    try std.testing.expect(clone.last_prompt == null);
    try std.testing.expect(!clone.archived);
    try std.testing.expect(clone.archived_at_ms == null);
    try std.testing.expect(clone.last_turn_reason == null);
}
