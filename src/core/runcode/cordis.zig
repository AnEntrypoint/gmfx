const std = @import("std");

const files = [_]struct { name: []const u8, source: []const u8 }{
    .{ .name = "package.json", .source = @embedFile("cordis/package.json") },
    .{ .name = "src/async-hooks.js", .source = @embedFile("cordis/async-hooks.js") },
    .{ .name = "src/buffer.js", .source = @embedFile("cordis/buffer.js") },
    .{ .name = "src/child-process.js", .source = @embedFile("cordis/child-process.js") },
    .{ .name = "src/crypto.js", .source = @embedFile("cordis/crypto.js") },
    .{ .name = "src/dns-promises.js", .source = @embedFile("cordis/dns-promises.js") },
    .{ .name = "src/fs-promises.js", .source = @embedFile("cordis/fs-promises.js") },
    .{ .name = "src/fs.js", .source = @embedFile("cordis/fs.js") },
    .{ .name = "src/fx_runtime.js", .source = @embedFile("cordis/fx_runtime.js") },
    .{ .name = "src/http.js", .source = @embedFile("cordis/http.js") },
    .{ .name = "src/https.js", .source = @embedFile("cordis/https.js") },
    .{ .name = "src/index.js", .source = @embedFile("cordis/index.js") },
    .{ .name = "src/inspector.js", .source = @embedFile("cordis/inspector.js") },
    .{ .name = "src/install-fx.js", .source = @embedFile("cordis/install-fx.js") },
    .{ .name = "src/install-node.js", .source = @embedFile("cordis/install-fx.js") },
    .{ .name = "src/module.js", .source = @embedFile("cordis/module.js") },
    .{ .name = "src/net.js", .source = @embedFile("cordis/net.js") },
    .{ .name = "src/os.js", .source = @embedFile("cordis/os.js") },
    .{ .name = "src/path.js", .source = @embedFile("cordis/path.js") },
    .{ .name = "src/perf-hooks.js", .source = @embedFile("cordis/perf-hooks.js") },
    .{ .name = "src/process.js", .source = @embedFile("cordis/process.js") },
    .{ .name = "src/runtime.js", .source = @embedFile("cordis/runtime.js") },
    .{ .name = "src/stream.js", .source = @embedFile("cordis/stream.js") },
    .{ .name = "src/string-decoder.js", .source = @embedFile("cordis/string-decoder.js") },
    .{ .name = "src/timers-promises.js", .source = @embedFile("cordis/timers-promises.js") },
    .{ .name = "src/url.js", .source = @embedFile("cordis/url.js") },
    .{ .name = "src/util-types.js", .source = @embedFile("cordis/util-types.js") },
    .{ .name = "src/util.js", .source = @embedFile("cordis/util.js") },
    .{ .name = "src/vm.js", .source = @embedFile("cordis/vm.js") },
    .{ .name = "src/worker-threads.js", .source = @embedFile("cordis/worker-threads.js") },
    .{ .name = "src/zlib.js", .source = @embedFile("cordis/zlib.js") },
};

pub fn source(name: []const u8) ?[]const u8 {
    for (files) |file| {
        if (std.mem.eql(u8, file.name, name)) return file.source;
    }
    return null;
}
