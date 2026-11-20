const std = @import("std");
const jsonrpc = @import("../acp/jsonrpc.zig");
const skills = @import("skills.zig");
const runs = @import("runs.zig");
const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{ResourceNotFound};

const skill_mime = "text/markdown";
const log_mime = "application/x-ndjson";
const witness_mime = "text/plain";

pub const Content = struct {
    uri: []const u8,
    mime_type: []const u8,
    text: []const u8,
};

const skill_scheme = "skill://";
const session_scheme = "fx://session/";

const SessionPart = enum { log, witness };

const Uri = union(enum) {
    skill: skills.Entry,
    session: struct { id: []const u8, part: SessionPart },
};

fn parseUri(uri: []const u8) ?Uri {
    if (std.mem.startsWith(u8, uri, skill_scheme)) {
        const rest = uri[skill_scheme.len..];
        const slash = std.mem.findScalar(u8, rest, '/') orelse return null;
        const entry = skills.find(rest[0..slash], rest[slash + 1 ..]) orelse return null;
        if (entry.served() == null) return null;
        return .{ .skill = entry };
    }
    if (std.mem.startsWith(u8, uri, session_scheme)) {
        const rest = uri[session_scheme.len..];
        const slash = std.mem.findScalarLast(u8, rest, '/') orelse return null;
        const id = rest[0..slash];
        if (!runs.validId(id)) return null;
        const part = std.meta.stringToEnum(SessionPart, rest[slash + 1 ..]) orelse return null;
        return .{ .session = .{ .id = id, .part = part } };
    }
    return null;
}

pub fn exists(uri: []const u8) bool {
    return parseUri(uri) != null;
}

pub const Digest = [std.crypto.hash.sha2.Sha256.digest_length]u8;

pub const Stamp = struct {
    size: u64,
    mtime: i96,
};

pub fn stamp(root: ?std.Io.Dir, uri: []const u8) ?Stamp {
    const parsed = parseUri(uri) orelse return null;
    return switch (parsed) {
        .skill => .{ .size = 0, .mtime = 0 },
        .session => |session| {
            const dir = root orelse return null;
            const file = runs.logStat(dir, session.id) catch return null;
            return .{ .size = file.size, .mtime = file.mtime.nanoseconds };
        },
    };
}

pub fn listKey(root: ?std.Io.Dir) !u64 {
    const dir = root orelse return 0;
    return runs.stampKey(dir);
}

pub fn listDigest(alloc: Allocator, root: ?std.Io.Dir) !Digest {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeList(alloc, root, &out.writer, true);
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(out.written(), &digest, .{});
    return digest;
}

pub fn writeList(alloc: Allocator, root: ?std.Io.Dir, w: *std.Io.Writer, modern: bool) !void {
    try w.writeByte('{');
    try wire.writeCacheable(w, modern);
    try w.writeAll("\"resources\":[");
    var first = true;
    for (skills.entries) |entry| {
        if (entry.served() == null) continue;
        const uri = try std.fmt.allocPrint(alloc, skill_scheme ++ "{s}/{s}", .{ entry.skill, entry.file });
        const name = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ entry.skill, entry.file });
        try writeSeparator(w, &first);
        try writeItem(w, uri, name, skill_mime);
    }
    if (root) |dir| {
        for (try runs.list(alloc, dir)) |run| {
            try writeSeparator(w, &first);
            try writeItem(
                w,
                try std.fmt.allocPrint(alloc, session_scheme ++ "{s}/log", .{run.id}),
                try std.fmt.allocPrint(alloc, "{s} log", .{run.id}),
                log_mime,
            );
            if (run.witness == null) continue;
            try writeSeparator(w, &first);
            try writeItem(
                w,
                try std.fmt.allocPrint(alloc, session_scheme ++ "{s}/witness", .{run.id}),
                try std.fmt.allocPrint(alloc, "{s} witness", .{run.id}),
                witness_mime,
            );
        }
    }
    try w.writeAll("]}");
}

pub fn writeTemplates(w: *std.Io.Writer, modern: bool) !void {
    try w.writeByte('{');
    try wire.writeCacheable(w, modern);
    try w.writeAll("\"resourceTemplates\":[");
    try writeTemplate(w, skill_scheme ++ "{skill}/{file}", "skill file", skill_mime);
    try w.writeByte(',');
    try writeTemplate(w, session_scheme ++ "{session}/log", "session log", log_mime);
    try w.writeByte(',');
    try writeTemplate(w, session_scheme ++ "{session}/witness", "session witness", witness_mime);
    try w.writeAll("]}");
}

pub fn read(alloc: Allocator, root: ?std.Io.Dir, uri: []const u8) !Content {
    const parsed = parseUri(uri) orelse return error.ResourceNotFound;
    switch (parsed) {
        .skill => |entry| return .{
            .uri = uri,
            .mime_type = skill_mime,
            .text = entry.served() orelse return error.ResourceNotFound,
        },
        .session => |session| {
            const dir = root orelse return error.ResourceNotFound;
            switch (session.part) {
                .log => return .{
                    .uri = uri,
                    .mime_type = log_mime,
                    .text = runs.readLog(alloc, dir, session.id) catch |err| switch (err) {
                        error.FileNotFound => return error.ResourceNotFound,
                        else => return err,
                    },
                },
                .witness => return .{
                    .uri = uri,
                    .mime_type = witness_mime,
                    .text = (try runs.witness(alloc, dir, session.id)) orelse return error.ResourceNotFound,
                },
            }
        },
    }
}

pub fn writeContents(w: *std.Io.Writer, content: Content, modern: bool) !void {
    try w.writeByte('{');
    try wire.writeCacheable(w, modern);
    try w.writeAll("\"contents\":[");
    try writeContent(w, content);
    try w.writeAll("]}");
}

fn writeContent(w: *std.Io.Writer, content: Content) !void {
    try w.writeAll("{\"uri\":");
    try jsonrpc.writeJsonStr(content.uri, w);
    try w.writeAll(",\"mimeType\":");
    try jsonrpc.writeJsonStr(content.mime_type, w);
    try w.writeAll(",\"text\":");
    try jsonrpc.writeJsonStr(content.text, w);
    try w.writeByte('}');
}

fn writeSeparator(w: *std.Io.Writer, first: *bool) !void {
    if (first.*) {
        first.* = false;
    } else {
        try w.writeByte(',');
    }
}

fn writeItem(w: *std.Io.Writer, uri: []const u8, name: []const u8, mime_type: []const u8) !void {
    try w.writeAll("{\"uri\":");
    try jsonrpc.writeJsonStr(uri, w);
    try w.writeAll(",\"name\":");
    try jsonrpc.writeJsonStr(name, w);
    try w.writeAll(",\"mimeType\":");
    try jsonrpc.writeJsonStr(mime_type, w);
    try w.writeByte('}');
}

fn writeTemplate(w: *std.Io.Writer, uri_template: []const u8, name: []const u8, mime_type: []const u8) !void {
    try w.writeAll("{\"uriTemplate\":");
    try jsonrpc.writeJsonStr(uri_template, w);
    try w.writeAll(",\"name\":");
    try jsonrpc.writeJsonStr(name, w);
    try w.writeAll(",\"mimeType\":");
    try jsonrpc.writeJsonStr(mime_type, w);
    try w.writeByte('}');
}
