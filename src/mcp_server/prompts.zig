const std = @import("std");
const jsonrpc = @import("../acp/jsonrpc.zig");
const skills = @import("skills.zig");
const wire = @import("wire.zig");

const Prompt = struct {
    name: []const u8,
    description: []const u8,
    skill: []const u8,
    file: []const u8,
};

const prompts = [_]Prompt{
    .{
        .name = "fx-working-loop",
        .description = "The fx working loop: the default habits for planning, batching, waiting, verifying and reporting.",
        .skill = "fx",
        .file = "WORKING-LOOP.md",
    },
    .{
        .name = "fx-system",
        .description = "The default fx system prompt, with the working loop as its last section.",
        .skill = "fx",
        .file = "SYSTEM.md",
    },
};

fn find(name: []const u8) ?Prompt {
    for (prompts) |prompt| {
        if (std.mem.eql(u8, prompt.name, name)) return prompt;
    }
    return null;
}

fn servedText(prompt: Prompt) ?[]const u8 {
    const entry = skills.find(prompt.skill, prompt.file) orelse return null;
    return entry.served();
}

pub fn servedNames(alloc: std.mem.Allocator) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (prompts) |prompt| {
        if (servedText(prompt) == null) continue;
        try names.append(alloc, prompt.name);
    }
    return names.items;
}

pub fn writeList(w: *std.Io.Writer, modern: bool) !void {
    try w.writeByte('{');
    try wire.writeCacheable(w, modern);
    try w.writeAll("\"prompts\":[");
    var first = true;
    for (prompts) |prompt| {
        if (servedText(prompt) == null) continue;
        if (first) {
            first = false;
        } else {
            try w.writeByte(',');
        }
        try w.writeAll("{\"name\":");
        try jsonrpc.writeJsonStr(prompt.name, w);
        try w.writeAll(",\"description\":");
        try jsonrpc.writeJsonStr(prompt.description, w);
        try w.writeAll(",\"arguments\":[]}");
    }
    try w.writeAll("]}");
}

pub fn get(w: *std.Io.Writer, name: []const u8, modern: bool) !void {
    const prompt = find(name) orelse return error.PromptNotFound;
    const text = servedText(prompt) orelse return error.PromptNotFound;
    try w.writeByte('{');
    try wire.writeComplete(w, modern);
    try w.writeAll("\"description\":");
    try jsonrpc.writeJsonStr(prompt.description, w);
    try w.writeAll(",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":");
    try jsonrpc.writeJsonStr(text, w);
    try w.writeAll("}}]}");
}
