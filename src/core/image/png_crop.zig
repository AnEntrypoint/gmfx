const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

const signature = "\x89PNG\r\n\x1a\n";
const ihdr_data_len = 13;
const chunk_overhead = 12;

pub const Region = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

pub const Error = error{
    NotPng,
    UnsupportedPng,
    CorruptPng,
    RegionOutOfBounds,
} || Allocator.Error;

const ColorType = enum(u8) {
    gray = 0,
    rgb = 2,
    palette = 3,
    gray_alpha = 4,
    rgba = 6,
    _,
};

pub const Crop = struct {
    color: ColorType,
    bit_depth: u8,
    channels: usize,
    unit_bytes: usize,
    width: usize,
    height: usize,
    chunks: []const u8,
    pixels: []u8,

    pub fn deinit(self: Crop, alloc: Allocator) void {
        alloc.free(self.pixels);
    }
};

const Header = struct {
    width: usize,
    height: usize,
    color: ColorType,
    bit_depth: u8,
    channels: usize,
    unit_bytes: usize,
    filter_bpp: usize,
    interlaced: bool,
    chunks_start: usize,
};

const Chunk = struct {
    kind: []const u8,
    data: []const u8,
    end: usize,
};

const Stream = struct {
    zlib: []u8,
    first_idat: usize,
};

const Pass = struct {
    x0: usize,
    y0: usize,
    dx: usize,
    dy: usize,
};

const single_pass = [_]Pass{.{ .x0 = 0, .y0 = 0, .dx = 1, .dy = 1 }};

const adam7_passes = [_]Pass{
    .{ .x0 = 0, .y0 = 0, .dx = 8, .dy = 8 },
    .{ .x0 = 4, .y0 = 0, .dx = 8, .dy = 8 },
    .{ .x0 = 0, .y0 = 4, .dx = 4, .dy = 8 },
    .{ .x0 = 2, .y0 = 0, .dx = 4, .dy = 4 },
    .{ .x0 = 0, .y0 = 2, .dx = 2, .dy = 4 },
    .{ .x0 = 1, .y0 = 0, .dx = 2, .dy = 2 },
    .{ .x0 = 0, .y0 = 1, .dx = 1, .dy = 2 },
};

fn channelCount(color: ColorType) ?usize {
    return switch (color) {
        .gray, .palette => 1,
        .gray_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        _ => null,
    };
}

fn validDepth(color: ColorType, bit_depth: u8) bool {
    return switch (color) {
        .gray => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8 or bit_depth == 16,
        .palette => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8,
        .gray_alpha, .rgb, .rgba => bit_depth == 8 or bit_depth == 16,
        _ => false,
    };
}

fn sampleBytes(bit_depth: u8) usize {
    return if (bit_depth == 16) 2 else 1;
}

fn unitBytes(color: ColorType, bit_depth: u8) ?usize {
    const channels = channelCount(color) orelse return null;
    return channels * sampleBytes(bit_depth);
}

fn rowBytes(width: usize, channels: usize, bit_depth: u8) usize {
    return (width * channels * bit_depth + 7) / 8;
}

fn filterBpp(channels: usize, bit_depth: u8) usize {
    return @max(1, channels * bit_depth / 8);
}

fn passSize(total: usize, start: usize, step: usize) usize {
    if (total <= start) return 0;
    return (total - start + step - 1) / step;
}

fn chunkAt(png: []const u8, offset: usize) Error!Chunk {
    if (png.len < offset + chunk_overhead) return error.CorruptPng;
    const len: usize = std.mem.readInt(u32, png[offset..][0..4], .big);
    const data_start = offset + 8;
    if (len > png.len - data_start - 4) return error.CorruptPng;
    return .{
        .kind = png[offset + 4 ..][0..4],
        .data = png[data_start..][0..len],
        .end = data_start + len + 4,
    };
}

fn parseHeader(png: []const u8) Error!Header {
    if (png.len < signature.len or !std.mem.eql(u8, png[0..signature.len], signature)) return error.NotPng;
    const ihdr = try chunkAt(png, signature.len);
    if (!std.mem.eql(u8, ihdr.kind, "IHDR") or ihdr.data.len != ihdr_data_len) return error.CorruptPng;
    const data = ihdr.data;
    const width = std.mem.readInt(u32, data[0..4], .big);
    const height = std.mem.readInt(u32, data[4..8], .big);
    if (width == 0 or height == 0) return error.CorruptPng;
    if (data[10] != 0 or data[11] != 0) return error.CorruptPng;
    const interlaced = switch (data[12]) {
        0 => false,
        1 => true,
        else => return error.CorruptPng,
    };
    const color: ColorType = @fromBackingInt(@intCast(data[9]));
    const bit_depth = data[8];
    if (!validDepth(color, bit_depth)) return error.UnsupportedPng;
    const channels = channelCount(color) orelse return error.UnsupportedPng;
    return .{
        .width = width,
        .height = height,
        .color = color,
        .bit_depth = bit_depth,
        .channels = channels,
        .unit_bytes = channels * sampleBytes(bit_depth),
        .filter_bpp = filterBpp(channels, bit_depth),
        .interlaced = interlaced,
        .chunks_start = ihdr.end,
    };
}

pub fn clipRegion(width: usize, height: usize, region: Region) Error!Region {
    if (region.width == 0 or region.height == 0 or region.x >= width or region.y >= height) return error.RegionOutOfBounds;
    return .{
        .x = region.x,
        .y = region.y,
        .width = @min(region.width, width - region.x),
        .height = @min(region.height, height - region.y),
    };
}

fn gatherIdat(alloc: Allocator, png: []const u8, start: usize) Error!Stream {
    var zlib: std.Io.Writer.Allocating = .init(alloc);
    errdefer zlib.deinit();
    var first_idat: ?usize = null;
    var offset = start;
    while (offset < png.len) {
        const chunk = try chunkAt(png, offset);
        if (std.mem.eql(u8, chunk.kind, "IEND")) break;
        if (std.mem.eql(u8, chunk.kind, "IDAT")) {
            first_idat = first_idat orelse offset;
            zlib.writer.writeAll(chunk.data) catch return error.OutOfMemory;
        }
        offset = chunk.end;
    }
    const first = first_idat orelse return error.CorruptPng;
    return .{ .zlib = try zlib.toOwnedSlice(), .first_idat = first };
}

fn paeth(left: u8, up: u8, up_left: u8) u8 {
    const a: i16 = left;
    const b: i16 = up;
    const c: i16 = up_left;
    const estimate = a + b - c;
    const pa = @abs(estimate - a);
    const pb = @abs(estimate - b);
    const pc = @abs(estimate - c);
    if (pa <= pb and pa <= pc) return left;
    if (pb <= pc) return up;
    return up_left;
}

fn unfilterRow(filter: u8, cur: []u8, prev: []const u8, bpp: usize) Error!void {
    switch (filter) {
        0 => {},
        1 => for (bpp..cur.len) |i| {
            cur[i] +%= cur[i - bpp];
        },
        2 => for (cur, prev) |*c, p| {
            c.* +%= p;
        },
        3 => for (cur, prev, 0..) |*c, p, i| {
            const left: u16 = if (i >= bpp) cur[i - bpp] else 0;
            c.* +%= @intCast((left + p) / 2);
        },
        4 => for (cur, prev, 0..) |*c, p, i| {
            const left = if (i >= bpp) cur[i - bpp] else 0;
            const up_left = if (i >= bpp) prev[i - bpp] else 0;
            c.* +%= paeth(left, p, up_left);
        },
        else => return error.CorruptPng,
    }
}

fn unpackRow(packed_row: []const u8, samples: []u8, bit_depth: u8) void {
    const depth: usize = bit_depth;
    const mask: u8 = @intCast((@as(usize, 1) << @intCast(depth)) - 1);
    for (samples, 0..) |*sample, index| {
        const bit = index * depth;
        const shift: u3 = @intCast(8 - depth - bit % 8);
        sample.* = (packed_row[bit / 8] >> shift) & mask;
    }
}

fn packRow(samples: []const u8, packed_row: []u8, bit_depth: u8) void {
    const depth: usize = bit_depth;
    @memset(packed_row, 0);
    for (samples, 0..) |sample, index| {
        const bit = index * depth;
        const shift: u3 = @intCast(8 - depth - bit % 8);
        packed_row[bit / 8] |= sample << shift;
    }
}

fn unfilterRegion(alloc: Allocator, header: Header, region: Region, zlib: []const u8) Error![]u8 {
    const crop_row_len = region.width * header.unit_bytes;
    const crop = try alloc.alloc(u8, crop_row_len * region.height);
    errdefer alloc.free(crop);

    const max_row_len = rowBytes(header.width, header.channels, header.bit_depth);
    const samples_row_len = header.width * header.unit_bytes;
    const window = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(window);
    const buffers = try alloc.alloc(u8, max_row_len * 2 + samples_row_len);
    defer alloc.free(buffers);
    const prev_all = buffers[0..max_row_len];
    const cur_all = buffers[max_row_len .. max_row_len * 2];
    const samples_all = buffers[max_row_len * 2 ..];

    var input: std.Io.Reader = .fixed(zlib);
    var inflater = flate.Decompress.init(&input, .zlib, window);
    const reader = &inflater.reader;

    const passes: []const Pass = if (header.interlaced) &adam7_passes else &single_pass;
    for (passes) |pass| {
        const pass_width = passSize(header.width, pass.x0, pass.dx);
        const pass_height = passSize(header.height, pass.y0, pass.dy);
        if (pass_width == 0 or pass_height == 0) continue;
        const row_len = rowBytes(pass_width, header.channels, header.bit_depth);
        var prev = prev_all[0..row_len];
        var cur = cur_all[0..row_len];
        @memset(prev, 0);
        for (0..pass_height) |j| {
            const filter = reader.takeByte() catch return error.CorruptPng;
            reader.readSliceAll(cur) catch return error.CorruptPng;
            try unfilterRow(filter, cur, prev, header.filter_bpp);
            var samples: []u8 = cur;
            if (header.bit_depth < 8) {
                samples = samples_all[0 .. pass_width * header.unit_bytes];
                unpackRow(cur, samples, header.bit_depth);
            }
            const y = pass.y0 + j * pass.dy;
            if (y >= region.y and y < region.y + region.height) {
                for (0..pass_width) |i| {
                    const x = pass.x0 + i * pass.dx;
                    if (x < region.x or x >= region.x + region.width) continue;
                    const dst = (y - region.y) * crop_row_len + (x - region.x) * header.unit_bytes;
                    @memcpy(crop[dst..][0..header.unit_bytes], samples[i * header.unit_bytes ..][0..header.unit_bytes]);
                }
            }
            std.mem.swap([]u8, &prev, &cur);
        }
    }
    return crop;
}

fn writeChunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) Error!void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(data.len), .big);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, crc.final(), .big);
    w.writeAll(&length) catch return error.OutOfMemory;
    w.writeAll(kind) catch return error.OutOfMemory;
    w.writeAll(data) catch return error.OutOfMemory;
    w.writeAll(&checksum) catch return error.OutOfMemory;
}

fn encodeScanlines(
    alloc: Allocator,
    width: usize,
    height: usize,
    color: ColorType,
    bit_depth: u8,
    interlaced: bool,
    chunks: []const u8,
    scanlines: []const u8,
) Error![]u8 {
    var zlib = try std.Io.Writer.Allocating.initCapacity(alloc, 1024);
    defer zlib.deinit();
    const window = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(window);
    var compressor = flate.Compress.init(&zlib.writer, window, .zlib, .best) catch return error.OutOfMemory;
    compressor.writer.writeAll(scanlines) catch return error.OutOfMemory;
    compressor.finish() catch return error.OutOfMemory;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    w.writeAll(signature) catch return error.OutOfMemory;
    var ihdr: [ihdr_data_len]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(width), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(height), .big);
    ihdr[8] = bit_depth;
    ihdr[9] = @backingInt(color);
    @memset(ihdr[10..], 0);
    ihdr[12] = @intFromBool(interlaced);
    try writeChunk(w, "IHDR", &ihdr);
    w.writeAll(chunks) catch return error.OutOfMemory;
    try writeChunk(w, "IDAT", zlib.written());
    try writeChunk(w, "IEND", "");
    return out.toOwnedSlice();
}

pub fn decodeRegion(alloc: Allocator, png: []const u8, region: Region) Error!Crop {
    const header = try parseHeader(png);
    const clipped = try clipRegion(header.width, header.height, region);
    const stream = try gatherIdat(alloc, png, header.chunks_start);
    defer alloc.free(stream.zlib);
    const pixels = try unfilterRegion(alloc, header, clipped, stream.zlib);
    return .{
        .color = header.color,
        .bit_depth = header.bit_depth,
        .channels = header.channels,
        .unit_bytes = header.unit_bytes,
        .width = clipped.width,
        .height = clipped.height,
        .chunks = png[header.chunks_start..stream.first_idat],
        .pixels = pixels,
    };
}

pub fn cropPng(alloc: Allocator, png: []const u8, region: Region) Error![]u8 {
    const crop = try decodeRegion(alloc, png, region);
    defer crop.deinit(alloc);
    const packed_len = rowBytes(crop.width, crop.channels, crop.bit_depth);
    const samples_row_len = crop.width * crop.unit_bytes;
    const scanlines = try alloc.alloc(u8, (packed_len + 1) * crop.height);
    defer alloc.free(scanlines);
    for (0..crop.height) |y| {
        const row = scanlines[y * (packed_len + 1) ..][0 .. packed_len + 1];
        row[0] = 0;
        const samples = crop.pixels[y * samples_row_len ..][0..samples_row_len];
        if (crop.bit_depth < 8) {
            packRow(samples, row[1..], crop.bit_depth);
        } else {
            @memcpy(row[1..], samples);
        }
    }
    return encodeScanlines(alloc, crop.width, crop.height, crop.color, crop.bit_depth, false, crop.chunks, scanlines);
}

fn filterRow(filter: u8, cur: []const u8, prev: []const u8, bpp: usize, out: []u8) void {
    for (cur, prev, out, 0..) |byte, up, *dst, i| {
        const left: u8 = if (i >= bpp) cur[i - bpp] else 0;
        const up_left: u8 = if (i >= bpp) prev[i - bpp] else 0;
        const predicted: u8 = switch (filter) {
            0 => 0,
            1 => left,
            2 => up,
            3 => @intCast((@as(u16, left) + up) / 2),
            4 => paeth(left, up, up_left),
            else => unreachable,
        };
        dst.* = byte -% predicted;
    }
}

fn encodeTestImage(
    alloc: Allocator,
    width: usize,
    height: usize,
    color: ColorType,
    bit_depth: u8,
    pixels: []const u8,
    chunks: []const u8,
    interlaced: bool,
) Error![]u8 {
    const channels = channelCount(color).?;
    const unit = unitBytes(color, bit_depth).?;
    const bpp = filterBpp(channels, bit_depth);
    const passes: []const Pass = if (interlaced) &adam7_passes else &single_pass;
    var scanlines: std.Io.Writer.Allocating = .init(alloc);
    defer scanlines.deinit();
    for (passes) |pass| {
        const pass_width = passSize(width, pass.x0, pass.dx);
        const pass_height = passSize(height, pass.y0, pass.dy);
        if (pass_width == 0 or pass_height == 0) continue;
        const row_len = rowBytes(pass_width, channels, bit_depth);
        const samples = try alloc.alloc(u8, pass_width * unit * pass_height);
        defer alloc.free(samples);
        for (0..pass_height) |j| {
            for (0..pass_width) |i| {
                const src = ((pass.y0 + j * pass.dy) * width + pass.x0 + i * pass.dx) * unit;
                @memcpy(samples[(j * pass_width + i) * unit ..][0..unit], pixels[src..][0..unit]);
            }
        }
        const raw = try alloc.alloc(u8, row_len * pass_height);
        defer alloc.free(raw);
        for (0..pass_height) |j| {
            const row_samples = samples[j * pass_width * unit ..][0 .. pass_width * unit];
            const raw_row = raw[j * row_len ..][0..row_len];
            if (bit_depth < 8) {
                packRow(row_samples, raw_row, bit_depth);
            } else {
                @memcpy(raw_row, row_samples);
            }
        }
        const zeros = try alloc.alloc(u8, row_len);
        defer alloc.free(zeros);
        @memset(zeros, 0);
        const filtered = try alloc.alloc(u8, row_len);
        defer alloc.free(filtered);
        for (0..pass_height) |j| {
            const filter: u8 = @intCast(j % 5);
            const cur = raw[j * row_len ..][0..row_len];
            const prev = if (j == 0) zeros else raw[(j - 1) * row_len ..][0..row_len];
            filterRow(filter, cur, prev, bpp, filtered);
            scanlines.writer.writeByte(filter) catch return error.OutOfMemory;
            scanlines.writer.writeAll(filtered) catch return error.OutOfMemory;
        }
    }
    return encodeScanlines(alloc, width, height, color, bit_depth, interlaced, chunks, scanlines.written());
}

pub fn testEncodePng(
    alloc: Allocator,
    width: usize,
    height: usize,
    color: ColorType,
    bit_depth: u8,
    pixels: []const u8,
    chunks: []const u8,
) Error![]u8 {
    return encodeTestImage(alloc, width, height, color, bit_depth, pixels, chunks, false);
}

pub fn testEncodePngInterlaced(
    alloc: Allocator,
    width: usize,
    height: usize,
    color: ColorType,
    bit_depth: u8,
    pixels: []const u8,
    chunks: []const u8,
) Error![]u8 {
    return encodeTestImage(alloc, width, height, color, bit_depth, pixels, chunks, true);
}

fn testChunk(alloc: Allocator, kind: *const [4]u8, data: []const u8) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeChunk(&out.writer, kind, data);
    return out.toOwnedSlice();
}

fn sampleGradient(alloc: Allocator, width: usize, height: usize, color: ColorType, bit_depth: u8) ![]u8 {
    const unit = unitBytes(color, bit_depth).?;
    const mask: u8 = if (bit_depth < 8) @intCast((@as(usize, 1) << @intCast(bit_depth)) - 1) else 0xff;
    const pixels = try alloc.alloc(u8, width * height * unit);
    for (0..height) |y| {
        for (0..width) |x| {
            for (0..unit) |j| {
                const value: u8 = @truncate(x * 37 + y * 91 + j * 53 + x * y * 7);
                pixels[(y * width + x) * unit + j] = value & mask;
            }
        }
    }
    return pixels;
}

fn regionOf(alloc: Allocator, pixels: []const u8, width: usize, unit: usize, region: Region) ![]u8 {
    const row_len = region.width * unit;
    const out = try alloc.alloc(u8, row_len * region.height);
    for (0..region.height) |row| {
        const src = ((region.y + row) * width + region.x) * unit;
        @memcpy(out[row * row_len ..][0..row_len], pixels[src..][0..row_len]);
    }
    return out;
}

test "png crop keeps the requested rgb region pixels" {
    const alloc = std.testing.allocator;
    const pixels = try sampleGradient(alloc, 4, 3, .rgb, 8);
    defer alloc.free(pixels);
    const png = try testEncodePng(alloc, 4, 3, .rgb, 8, pixels, "");
    defer alloc.free(png);
    const region: Region = .{ .x = 1, .y = 1, .width = 2, .height = 2 };
    const crop = try decodeRegion(alloc, png, region);
    defer crop.deinit(alloc);
    const expected = try regionOf(alloc, pixels, 4, 3, region);
    defer alloc.free(expected);
    try std.testing.expectEqualSlices(u8, expected, crop.pixels);
    try std.testing.expectEqual(ColorType.rgb, crop.color);
    try std.testing.expectEqual(@as(usize, 2), crop.width);
}

test "png crop unfilters every filter type back to the source pixels" {
    const alloc = std.testing.allocator;
    const pixels = try sampleGradient(alloc, 5, 5, .rgba, 8);
    defer alloc.free(pixels);
    const png = try testEncodePng(alloc, 5, 5, .rgba, 8, pixels, "");
    defer alloc.free(png);
    const crop = try decodeRegion(alloc, png, .{ .x = 0, .y = 0, .width = 5, .height = 5 });
    defer crop.deinit(alloc);
    try std.testing.expectEqualSlices(u8, pixels, crop.pixels);
}

test "png crop handles grayscale, gray alpha and 16-bit samples" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { color: ColorType, bit_depth: u8 }{
        .{ .color = .gray, .bit_depth = 8 },
        .{ .color = .gray_alpha, .bit_depth = 8 },
        .{ .color = .rgb, .bit_depth = 16 },
        .{ .color = .rgba, .bit_depth = 16 },
    };
    for (cases) |case| {
        const unit = unitBytes(case.color, case.bit_depth).?;
        const pixels = try sampleGradient(alloc, 4, 3, case.color, case.bit_depth);
        defer alloc.free(pixels);
        const png = try testEncodePng(alloc, 4, 3, case.color, case.bit_depth, pixels, "");
        defer alloc.free(png);
        const region: Region = .{ .x = 1, .y = 0, .width = 3, .height = 2 };
        const crop = try decodeRegion(alloc, png, region);
        defer crop.deinit(alloc);
        const expected = try regionOf(alloc, pixels, 4, unit, region);
        defer alloc.free(expected);
        try std.testing.expectEqualSlices(u8, expected, crop.pixels);
        try std.testing.expectEqual(case.color, crop.color);
    }
}

test "png crop keeps gray and palette samples at bit depths 1, 2 and 4" {
    const alloc = std.testing.allocator;
    const colors = [_]ColorType{ .gray, .palette };
    const depths = [_]u8{ 1, 2, 4 };
    for (colors) |color| {
        for (depths) |depth| {
            const pixels = try sampleGradient(alloc, 5, 3, color, depth);
            defer alloc.free(pixels);
            const png = try testEncodePng(alloc, 5, 3, color, depth, pixels, "");
            defer alloc.free(png);
            const region: Region = .{ .x = 1, .y = 1, .width = 3, .height = 2 };
            const crop = try decodeRegion(alloc, png, region);
            defer crop.deinit(alloc);
            const expected = try regionOf(alloc, pixels, 5, 1, region);
            defer alloc.free(expected);
            try std.testing.expectEqualSlices(u8, expected, crop.pixels);
            try std.testing.expectEqual(depth, crop.bit_depth);

            const out = try cropPng(alloc, png, region);
            defer alloc.free(out);
            const back = try decodeRegion(alloc, out, .{ .x = 0, .y = 0, .width = 3, .height = 2 });
            defer back.deinit(alloc);
            try std.testing.expectEqualSlices(u8, expected, back.pixels);
        }
    }
}

test "png crop unfilters interlaced Adam7 PNGs back to the source pixels" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { color: ColorType, bit_depth: u8 }{
        .{ .color = .gray, .bit_depth = 8 },
        .{ .color = .rgba, .bit_depth = 8 },
        .{ .color = .gray, .bit_depth = 16 },
        .{ .color = .palette, .bit_depth = 2 },
    };
    const sizes = [_][2]usize{ .{ 9, 7 }, .{ 1, 1 }, .{ 2, 3 } };
    for (cases) |case| {
        for (sizes) |size| {
            const width = size[0];
            const height = size[1];
            const unit = unitBytes(case.color, case.bit_depth).?;
            const pixels = try sampleGradient(alloc, width, height, case.color, case.bit_depth);
            defer alloc.free(pixels);
            const png = try testEncodePngInterlaced(alloc, width, height, case.color, case.bit_depth, pixels, "");
            defer alloc.free(png);

            const full = try decodeRegion(alloc, png, .{ .x = 0, .y = 0, .width = width, .height = height });
            defer full.deinit(alloc);
            try std.testing.expectEqualSlices(u8, pixels, full.pixels);

            const region: Region = .{ .x = width / 2, .y = height / 2, .width = width - width / 2, .height = height - height / 2 };
            const crop = try decodeRegion(alloc, png, region);
            defer crop.deinit(alloc);
            const expected = try regionOf(alloc, pixels, width, unit, region);
            defer alloc.free(expected);
            try std.testing.expectEqualSlices(u8, expected, crop.pixels);
        }
    }
}

test "png crop keeps a palette image and copies its PLTE chunk" {
    const alloc = std.testing.allocator;
    const pixels = try sampleGradient(alloc, 4, 3, .palette, 8);
    defer alloc.free(pixels);
    const plte = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255 };
    const chunk = try testChunk(alloc, "PLTE", &plte);
    defer alloc.free(chunk);
    const png = try testEncodePng(alloc, 4, 3, .palette, 8, pixels, chunk);
    defer alloc.free(png);
    const region: Region = .{ .x = 1, .y = 1, .width = 2, .height = 2 };
    const out = try cropPng(alloc, png, region);
    defer alloc.free(out);
    const crop = try decodeRegion(alloc, out, .{ .x = 0, .y = 0, .width = 2, .height = 2 });
    defer crop.deinit(alloc);
    try std.testing.expectEqual(ColorType.palette, crop.color);
    try std.testing.expectEqualSlices(u8, chunk, crop.chunks);
    const expected = try regionOf(alloc, pixels, 4, 1, region);
    defer alloc.free(expected);
    try std.testing.expectEqualSlices(u8, expected, crop.pixels);
}

test "png crop writes a PNG of the region size" {
    const alloc = std.testing.allocator;
    const pixels = try sampleGradient(alloc, 4, 3, .rgb, 8);
    defer alloc.free(pixels);
    const png = try testEncodePng(alloc, 4, 3, .rgb, 8, pixels, "");
    defer alloc.free(png);
    const out = try cropPng(alloc, png, .{ .x = 1, .y = 1, .width = 2, .height = 2 });
    defer alloc.free(out);
    const header = try parseHeader(out);
    try std.testing.expectEqual(@as(usize, 2), header.width);
    try std.testing.expectEqual(@as(usize, 2), header.height);
}

test "png crop rejects a region outside the image bounds" {
    const alloc = std.testing.allocator;
    const pixels = try sampleGradient(alloc, 4, 3, .rgb, 8);
    defer alloc.free(pixels);
    const png = try testEncodePng(alloc, 4, 3, .rgb, 8, pixels, "");
    defer alloc.free(png);
    try std.testing.expectError(error.RegionOutOfBounds, decodeRegion(alloc, png, .{ .x = 4, .y = 0, .width = 2, .height = 1 }));
    try std.testing.expectError(error.RegionOutOfBounds, decodeRegion(alloc, png, .{ .x = 0, .y = 3, .width = 1, .height = 2 }));
    try std.testing.expectError(error.RegionOutOfBounds, decodeRegion(alloc, png, .{ .x = std.math.maxInt(usize), .y = 0, .width = 1, .height = 1 }));
    try std.testing.expectError(error.RegionOutOfBounds, decodeRegion(alloc, png, .{ .x = 0, .y = 0, .width = 0, .height = 1 }));
}

test "png crop clips a region that runs past the image edge" {
    const alloc = std.testing.allocator;
    const pixels = try sampleGradient(alloc, 4, 3, .rgb, 8);
    defer alloc.free(pixels);
    const png = try testEncodePng(alloc, 4, 3, .rgb, 8, pixels, "");
    defer alloc.free(png);
    const crop = try decodeRegion(alloc, png, .{ .x = 3, .y = 1, .width = 5, .height = 5 });
    defer crop.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), crop.width);
    try std.testing.expectEqual(@as(usize, 2), crop.height);
    const expected = try regionOf(alloc, pixels, 4, 3, .{ .x = 3, .y = 1, .width = 1, .height = 2 });
    defer alloc.free(expected);
    try std.testing.expectEqualSlices(u8, expected, crop.pixels);
}

test "png crop rejects a bit depth or interlace flag the PNG does not allow" {
    const alloc = std.testing.allocator;
    const rgb_pixels = try sampleGradient(alloc, 4, 3, .rgb, 8);
    defer alloc.free(rgb_pixels);
    const rgb_png = try testEncodePng(alloc, 4, 3, .rgb, 8, rgb_pixels, "");
    defer alloc.free(rgb_png);
    const gray_pixels = try sampleGradient(alloc, 4, 3, .gray, 8);
    defer alloc.free(gray_pixels);
    const gray_png = try testEncodePng(alloc, 4, 3, .gray, 8, gray_pixels, "");
    defer alloc.free(gray_png);
    const palette_png = try testEncodePng(alloc, 4, 3, .palette, 8, gray_pixels, "");
    defer alloc.free(palette_png);
    const region: Region = .{ .x = 0, .y = 0, .width = 1, .height = 1 };

    const rgb_depth_4 = try alloc.dupe(u8, rgb_png);
    defer alloc.free(rgb_depth_4);
    rgb_depth_4[24] = 4;
    try std.testing.expectError(error.UnsupportedPng, decodeRegion(alloc, rgb_depth_4, region));

    const gray_depth_3 = try alloc.dupe(u8, gray_png);
    defer alloc.free(gray_depth_3);
    gray_depth_3[24] = 3;
    try std.testing.expectError(error.UnsupportedPng, decodeRegion(alloc, gray_depth_3, region));

    const palette_depth_16 = try alloc.dupe(u8, palette_png);
    defer alloc.free(palette_depth_16);
    palette_depth_16[24] = 16;
    palette_depth_16[25] = 3;
    try std.testing.expectError(error.UnsupportedPng, decodeRegion(alloc, palette_depth_16, region));

    const bad_interlace = try alloc.dupe(u8, rgb_png);
    defer alloc.free(bad_interlace);
    bad_interlace[28] = 2;
    try std.testing.expectError(error.CorruptPng, decodeRegion(alloc, bad_interlace, region));
}

test "png crop rejects bytes that are not a PNG and a truncated file" {
    const alloc = std.testing.allocator;
    const pixels = try sampleGradient(alloc, 4, 3, .rgb, 8);
    defer alloc.free(pixels);
    const png = try testEncodePng(alloc, 4, 3, .rgb, 8, pixels, "");
    defer alloc.free(png);
    const region: Region = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
    try std.testing.expectError(error.NotPng, decodeRegion(alloc, "GIF89a\x01\x00\x01\x00", region));
    try std.testing.expectError(error.CorruptPng, decodeRegion(alloc, png[0 .. png.len - 13], region));
}
