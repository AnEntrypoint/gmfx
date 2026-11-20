const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const core_types = @import("../../core/shared/types.zig");
const image_data = @import("../../core/images/image_data.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_result_errors = @import("../../core/tooling/tool_result_errors.zig");
const read_file = @import("read_file.zig");
const png_crop = @import("../../core/image/png_crop.zig");

const Allocator = std.mem.Allocator;

const tool_name = "ReadMediaFile";
const whitespace = " \t\r\n";
const read_buffer_bytes = 8192;

const empty_path_message = "ReadMediaFile field \"path\" must not be empty";
const invalid_region_message = "ReadMediaFile field \"region\" must be an object with integer x and y of at least 0 and integer width and height of at least 1";
const invalid_full_resolution_message = "ReadMediaFile field \"full_resolution\" must be a boolean";
const max_crop_source_bytes: usize = 64 * 1024 * 1024;
const crop_not_png_message_fmt = "ReadMediaFile region cropping supports PNG only in fx, and {s} is {s}. JPEG and WebP need an image pixel decoder that fx does not have. Omit region to read the whole image.";
const crop_source_limit_message_fmt = "{s} is {d} bytes, over the {d}-byte source limit for region crops. Save a smaller copy with an available image tool, then read that copy.";
const crop_bounds_message_fmt = "{s} is {d} by {d} pixels, and region x={d} y={d} starts outside it.";
const crop_unsupported_message_fmt = "{s} is a PNG that region cropping cannot decode: its color type or bit depth is not valid. Omit region to read the whole image.";
const crop_corrupt_message_fmt = "{s} is not a PNG that region cropping can decode.";
const crop_side_limit_message_fmt = "The region of {s} is {d} by {d} pixels, over the {d}-pixel limit on a side. Crop a smaller region.";
const crop_bytes_limit_message_fmt = "The cropped region of {s} is {d} bytes, over the {d}-byte per-image limit. Crop a smaller region.";
const crop_attached_fmt = "<path>{s}</path>\n<content>image attached (image/png, {d} bytes, cropped to region x={d} y={d} width={d} height={d})</content>";

pub const Region = png_crop.Region;

pub const Input = struct {
    path: []u8,
    region: ?Region = null,
    full_resolution: bool = false,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.path);
        self.* = .{ .path = &.{} };
    }
};

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var args: tool_args.ArgsDecoder = .{ .alloc = ctx.allocator, .tool = tool_name };
    var parsed = args.parse(args_json) catch |err| return .{ .failure = try args.takeFailure(err) };
    defer parsed.deinit();
    const object = parsed.value.object;
    const raw_path = args.requiredString(object, "path") catch |err| return .{ .failure = try args.takeFailure(err) };
    const path = std.mem.trim(u8, raw_path, whitespace);
    if (path.len == 0) return .{ .failure = try ctx.allocator.dupe(u8, empty_path_message) };
    const region = parseRegion(object) catch return .{ .failure = try ctx.allocator.dupe(u8, invalid_region_message) };
    const full_resolution = parseFullResolution(object) catch return .{ .failure = try ctx.allocator.dupe(u8, invalid_full_resolution_message) };

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .path = try ctx.allocator.dupe(u8, path), .region = region, .full_resolution = full_resolution };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn parseRegion(object: std.json.ObjectMap) error{InvalidRegion}!?Region {
    const value = object.get("region") orelse return null;
    if (value == .null) return null;
    if (value != .object) return error.InvalidRegion;
    return .{
        .x = try regionField(value.object, "x", 0),
        .y = try regionField(value.object, "y", 0),
        .width = try regionField(value.object, "width", 1),
        .height = try regionField(value.object, "height", 1),
    };
}

fn regionField(region: std.json.ObjectMap, key: []const u8, minimum: i64) error{InvalidRegion}!usize {
    const value = region.get(key) orelse return error.InvalidRegion;
    if (value != .integer or value.integer < minimum) return error.InvalidRegion;
    return std.math.cast(usize, value.integer) orelse return error.InvalidRegion;
}

fn parseFullResolution(object: std.json.ObjectMap) error{InvalidFullResolution}!bool {
    const value = object.get("full_resolution") orelse return false;
    if (value == .null) return false;
    if (value != .bool) return error.InvalidFullResolution;
    return value.bool;
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);

    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const target = pathing.resolveWorkspaceOrExternalPath(arena, ctx.workspace_root, input.path) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return mediaFailure(ctx.allocator, err, input.path);
    };

    const zio = io_mod.getIo();
    var file = io_mod.openExistingReadOnlyRegularFile(std.Io.Dir.cwd(), target, .no_follow) catch |err| {
        return mediaFailure(ctx.allocator, if (err == error.DurablePathUnsafe) error.NotRegularFile else err, target);
    };
    defer file.close(zio);

    const stat = file.stat(zio) catch |err| return mediaFailure(ctx.allocator, err, target);
    const rel = pathing.workspaceRelativePath(arena, ctx.workspace_root, target) catch target;

    const source_limit = if (input.region == null) read_file.max_attach_image_bytes else max_crop_source_bytes;
    const read_len: usize = @intCast(@min(stat.size, source_limit + 1));
    const content = try arena.alloc(u8, read_len);
    var read_buf: [read_buffer_bytes]u8 = undefined;
    var reader = file.reader(zio, &read_buf);
    const actual_len = read_file.readIntoBuffer(&reader.interface, content) catch |err| return mediaFailure(ctx.allocator, err, target);
    const bytes = content[0..actual_len];

    const mime_type = image_data.detectMediaTypeFromBytes(bytes) orelse
        return .{ .failure = try notImageFailure(ctx.allocator, rel) };
    if (input.region) |region| return cropResult(ctx, target, rel, mime_type, bytes, stat.size, actual_len, region);
    if (stat.size > read_file.max_attach_image_bytes) {
        return .{ .failure = try oversizeFailure(ctx.allocator, rel, stat.size, input.full_resolution) };
    }
    if (actual_len != stat.size) return mediaFailure(ctx.allocator, error.IncompleteRead, target);

    const dimensions = image_data.imageDimensions(bytes) orelse
        return .{ .failure = try ctx.allocator.print("{s} has no readable image dimensions, so it cannot be checked against the model's size limits.", .{rel}) };
    if (dimensions.exceeds(image_data.max_single_image_dimension)) {
        return .{ .failure = try ctx.allocator.print("{s} is larger than {d} pixels on a side. Save a smaller copy with an available image tool, then read that copy.", .{ rel, image_data.max_single_image_dimension }) };
    }

    const text = try ctx.allocator.print("<path>{s}</path>\n<content>image attached ({s}, {d} bytes)</content>", .{ rel, mime_type, stat.size });
    return imageResult(ctx, text, mime_type, bytes, true);
}

fn imageResult(
    ctx: tool_dispatch.DispatchContext,
    text: []u8,
    mime_type: []const u8,
    bytes: []const u8,
    covers_full_file: bool,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    errdefer ctx.allocator.free(text);
    const encoded = try ctx.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    errdefer ctx.allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    const owned_mime = try ctx.allocator.dupe(u8, mime_type);
    errdefer ctx.allocator.free(owned_mime);
    const images = try ctx.allocator.alloc(core_types.ToolImage, 1);
    images[0] = .{ .data = encoded, .mime_type = owned_mime };
    tool_dispatch.reportToolResultMemory(ctx, .{ .model_view_covers_full_file = covers_full_file });
    return .{ .rich = .{ .text = text, .images = images, .is_error = false } };
}

fn cropResult(
    ctx: tool_dispatch.DispatchContext,
    target: []const u8,
    rel: []const u8,
    mime_type: []const u8,
    bytes: []const u8,
    file_size: u64,
    actual_len: usize,
    region: Region,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (!std.mem.eql(u8, mime_type, "image/png")) {
        return .{ .failure = try ctx.allocator.print(crop_not_png_message_fmt, .{ rel, mime_type }) };
    }
    if (file_size > max_crop_source_bytes) {
        return .{ .failure = try ctx.allocator.print(crop_source_limit_message_fmt, .{ rel, file_size, max_crop_source_bytes }) };
    }
    if (actual_len != file_size) return mediaFailure(ctx.allocator, error.IncompleteRead, target);
    const cropped = png_crop.cropPng(ctx.allocator, bytes, region) catch |err| return cropFailure(ctx.allocator, rel, bytes, region, err);
    defer ctx.allocator.free(cropped);
    const out = image_data.imageDimensions(cropped) orelse return .{ .failure = try ctx.allocator.print(crop_corrupt_message_fmt, .{rel}) };
    if (out.exceeds(image_data.max_single_image_dimension)) {
        return .{ .failure = try ctx.allocator.print(crop_side_limit_message_fmt, .{ rel, out.width, out.height, image_data.max_single_image_dimension }) };
    }
    if (!image_data.fitsEncodedImageLimit(cropped.len)) {
        return .{ .failure = try ctx.allocator.print(crop_bytes_limit_message_fmt, .{ rel, cropped.len, read_file.max_attach_image_bytes }) };
    }
    const text = try ctx.allocator.print(crop_attached_fmt, .{ rel, cropped.len, region.x, region.y, out.width, out.height });
    return imageResult(ctx, text, "image/png", cropped, false);
}

fn cropFailure(
    alloc: Allocator,
    rel: []const u8,
    bytes: []const u8,
    region: Region,
    err: png_crop.Error,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const dims = image_data.imageDimensions(bytes) orelse image_data.Dimensions{ .width = 0, .height = 0 };
    const message = switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.RegionOutOfBounds => try alloc.print(crop_bounds_message_fmt, .{ rel, dims.width, dims.height, region.x, region.y }),
        error.UnsupportedPng => try alloc.print(crop_unsupported_message_fmt, .{rel}),
        error.NotPng, error.CorruptPng => try alloc.print(crop_corrupt_message_fmt, .{rel}),
    };
    return .{ .failure = message };
}

fn notImageFailure(alloc: Allocator, rel: []const u8) Allocator.Error![]u8 {
    return alloc.print("{s} is not an image this tool can read. ReadMediaFile reads image files; directories, text files and video are not supported.", .{rel});
}

fn oversizeFailure(alloc: Allocator, rel: []const u8, file_size: u64, full_resolution: bool) Allocator.Error![]u8 {
    if (full_resolution) {
        return alloc.print(
            "{s} is {d} bytes, over the {d}-byte per-image limit, so full_resolution cannot be honored. Save a smaller copy with an available image tool, then read that copy.",
            .{ rel, file_size, read_file.max_attach_image_bytes },
        );
    }
    return alloc.print(
        "{s} is {d} bytes, over the {d}-byte per-image limit, so it cannot be attached unchanged. Save a smaller copy with an available image tool, then read that copy.",
        .{ rel, file_size, read_file.max_attach_image_bytes },
    );
}

fn mediaFailure(alloc: Allocator, err: anyerror, path: []const u8) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (tool_result_errors.isFilesystemAccessDenied(err)) {
        return .{ .failure = try tool_result_errors.filesystemAccessDeniedJson(alloc, tool_name, path, err) };
    }
    const message = if (err == error.NotRegularFile) "ReadMediaFile requires a regular file" else "ReadMediaFile failed";
    const details = [_]tool_result_errors.Detail{
        .{ .name = "field", .value = .{ .string = "path" } },
        .{ .name = "path", .value = .{ .string = path } },
        .{ .name = "error", .value = .{ .string = @errorName(err) } },
    };
    return .{ .failure = try tool_result_errors.toolExecutionFailureJson(alloc, .{
        .tool_name = tool_name,
        .message = message,
        .details = &details,
        .suggestion = "Check the path relative to the workspace, and pass an image file.",
    }) };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn expectDecodeFailure(args_json: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
        .failure => |failure| {
            defer alloc.free(failure);
            try std.testing.expectEqualStrings(expected, failure);
        },
    }
}

fn decodeInput(alloc: Allocator, args_json: []const u8) !tool_dispatch.ToolInput {
    const decoded = try decode(.{ .allocator = alloc }, args_json);
    switch (decoded) {
        .input => |input| return input,
        .failure => |failure| {
            defer alloc.free(failure);
            return error.TestUnexpectedResult;
        },
    }
}

fn tmpPath(alloc: Allocator, tmp: std.testing.TmpDir, sub_path: []const u8) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, sub_path);
}

fn callFile(alloc: Allocator, root: []const u8, path: []const u8, full_resolution: bool) !tool_dispatch.ToolResult {
    const args = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\",\"full_resolution\":{}}}", .{ path, full_resolution });
    defer alloc.free(args);
    const input = try decodeInput(alloc, args);
    defer input.deinit(alloc);
    return call(.{ .allocator = alloc, .workspace_root = root }, input);
}

test "ReadMediaFile decodes path, region and full_resolution" {
    const alloc = std.testing.allocator;
    const input = try decodeInput(alloc, "{\"path\":\" frame.png \",\"region\":{\"x\":1,\"y\":2,\"width\":3,\"height\":4},\"full_resolution\":true}");
    defer input.deinit(alloc);
    const typed = input.as(Input);
    try std.testing.expectEqualStrings("frame.png", typed.path);
    try std.testing.expectEqual(Region{ .x = 1, .y = 2, .width = 3, .height = 4 }, typed.region.?);
    try std.testing.expect(typed.full_resolution);
}

test "ReadMediaFile names the argument that fails validation" {
    try expectDecodeFailure("{}", "ReadMediaFile requires string field \"path\"");
    try expectDecodeFailure("{\"path\":\"  \"}", empty_path_message);
    try expectDecodeFailure("{\"path\":\"a.png\",\"region\":{\"x\":0,\"y\":0,\"width\":0,\"height\":1}}", invalid_region_message);
    try expectDecodeFailure("{\"path\":\"a.png\",\"region\":{\"x\":-1,\"y\":0,\"width\":1,\"height\":1}}", invalid_region_message);
    try expectDecodeFailure("{\"path\":\"a.png\",\"region\":{\"x\":0,\"y\":0,\"width\":1}}", invalid_region_message);
    try expectDecodeFailure("{\"path\":\"a.png\",\"full_resolution\":\"yes\"}", invalid_full_resolution_message);
}

const TmpFile = struct {
    root: []u8,
    path: []u8,
};

fn tmpFileAt(alloc: Allocator, tmp: std.testing.TmpDir, sub_path: []const u8, data: []const u8) !TmpFile {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    errdefer alloc.free(root);
    const path = try tmpPath(alloc, tmp, sub_path);
    return .{ .root = root, .path = path };
}

fn callWithArgs(alloc: Allocator, root: []const u8, args: []const u8) !tool_dispatch.ToolResult {
    const input = try decodeInput(alloc, args);
    defer input.deinit(alloc);
    return call(.{ .allocator = alloc, .workspace_root = root }, input);
}

test "ReadMediaFile crops a PNG region and attaches the crop" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pixels: [8 * 6 * 3]u8 = undefined;
    for (&pixels, 0..) |*byte, i| byte.* = @truncate(i);
    const png = try png_crop.testEncodePng(alloc, 8, 6, .rgb, 8, &pixels, "");
    defer alloc.free(png);
    const file = try tmpFileAt(alloc, tmp, "frame.png", png);
    defer alloc.free(file.root);
    defer alloc.free(file.path);
    const args = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\",\"region\":{{\"x\":2,\"y\":1,\"width\":3,\"height\":2}}}}", .{file.path});
    defer alloc.free(args);

    const result = try callWithArgs(alloc, file.root, args);
    defer result.deinit(alloc);

    try std.testing.expect(result == .rich);
    try std.testing.expect(std.mem.find(u8, result.rich.text, "cropped to region x=2 y=1 width=3 height=2") != null);
    try std.testing.expectEqual(@as(usize, 1), result.rich.images.len);
    try std.testing.expectEqualStrings("image/png", result.rich.images[0].mime_type);
    const decoder = std.base64.standard.Decoder;
    const decoded = try alloc.alloc(u8, try decoder.calcSizeForSlice(result.rich.images[0].data));
    defer alloc.free(decoded);
    try decoder.decode(decoded, result.rich.images[0].data);
    const dims = image_data.imageDimensions(decoded) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3), dims.width);
    try std.testing.expectEqual(@as(u32, 2), dims.height);
}

test "ReadMediaFile rejects a region that starts outside the image" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const pixels: [8 * 6 * 3]u8 = @splat(0x40);
    const png = try png_crop.testEncodePng(alloc, 8, 6, .rgb, 8, &pixels, "");
    defer alloc.free(png);
    const file = try tmpFileAt(alloc, tmp, "frame.png", png);
    defer alloc.free(file.root);
    defer alloc.free(file.path);
    const args = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\",\"region\":{{\"x\":8,\"y\":0,\"width\":2,\"height\":1}}}}", .{file.path});
    defer alloc.free(args);

    const result = try callWithArgs(alloc, file.root, args);
    defer result.deinit(alloc);

    try std.testing.expect(result == .failure);
    try std.testing.expect(std.mem.find(u8, result.failure, "8 by 6 pixels") != null);
    try std.testing.expect(std.mem.find(u8, result.failure, "starts outside it") != null);
}

test "ReadMediaFile names the gap for a region on a JPEG, WebP or GIF" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "photo.jpg", .data = "\xff\xd8\xff\xe0\x00\x10JFIF\x00" },
        .{ .name = "anim.gif", .data = "GIF89a\x01\x00\x01\x00\x00\x00\x00" },
        .{ .name = "photo.webp", .data = "RIFF\x00\x00\x00\x00WEBPVP8 " },
    };
    for (cases) |case| {
        const file = try tmpFileAt(alloc, tmp, case.name, case.data);
        defer alloc.free(file.root);
        defer alloc.free(file.path);
        const args = try std.fmt.allocPrint(alloc, "{{\"path\":\"{s}\",\"region\":{{\"x\":0,\"y\":0,\"width\":1,\"height\":1}}}}", .{file.path});
        defer alloc.free(args);

        const result = try callWithArgs(alloc, file.root, args);
        defer result.deinit(alloc);

        try std.testing.expect(result == .failure);
        try std.testing.expect(std.mem.find(u8, result.failure, "cropping supports PNG only") != null);
    }
}

test "ReadMediaFile attaches a PNG within the attach limit unchanged" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "frame.png", .data = &image_data.testPngHeader(3420, 2224) });
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try tmpPath(alloc, tmp, "frame.png");
    defer alloc.free(path);

    const result = try callFile(alloc, root, path, true);
    defer result.deinit(alloc);

    try std.testing.expect(result == .rich);
    try std.testing.expect(std.mem.find(u8, result.rich.text, "image attached (image/png") != null);
    try std.testing.expectEqual(@as(usize, 1), result.rich.images.len);
    try std.testing.expectEqualStrings("image/png", result.rich.images[0].mime_type);
    try std.testing.expectEqual(std.base64.standard.Encoder.calcSize(24), result.rich.images[0].data.len);
}

test "ReadMediaFile rejects a text file as not an image" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.txt", .data = "hello\n" });
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try tmpPath(alloc, tmp, "notes.txt");
    defer alloc.free(path);

    const result = try callFile(alloc, root, path, false);
    defer result.deinit(alloc);

    try std.testing.expect(result == .failure);
    try std.testing.expect(std.mem.find(u8, result.failure, "is not an image this tool can read") != null);
}

test "ReadMediaFile rejects an image over the attach limit and names full_resolution" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile(std.testing.io, "big.png", .{});
        defer file.close(io_mod.getIo());
        const header = "\x89PNG\r\n\x1a\n".*;
        try file.writeStreamingAll(io_mod.getIo(), &header);
        var remaining: usize = read_file.max_attach_image_bytes + 1 - header.len;
        var filler: [8192]u8 = @splat(0xAB);
        while (remaining > 0) {
            const chunk = @min(remaining, filler.len);
            try file.writeStreamingAll(io_mod.getIo(), filler[0..chunk]);
            remaining -= chunk;
        }
    }
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try tmpPath(alloc, tmp, "big.png");
    defer alloc.free(path);

    const result = try callFile(alloc, root, path, true);
    defer result.deinit(alloc);

    try std.testing.expect(result == .failure);
    try std.testing.expect(std.mem.find(u8, result.failure, "full_resolution cannot be honored") != null);
}

test "ReadMediaFile rejects a directory path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "photos", .default_dir);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try tmpPath(alloc, tmp, "photos");
    defer alloc.free(path);

    const result = try callFile(alloc, root, path, false);
    defer result.deinit(alloc);

    try std.testing.expect(result == .failure);
}
