const std = @import("std");
const core = @import("../core/stdio_conn.zig");
const wire = @import("../protocol/wire.zig");
const lines = @import("lines.zig");
const Budget = @import("budget.zig").Budget;
const trace = @import("trace.zig");
const Bell = @import("bell.zig").Bell;

const everyone = struct {
    var mutex: std.Io.Mutex = .init;
    var list: std.DoublyLinkedList = .{};
    var exiting: std.atomic.Value(bool) = .init(false);
};

pub fn signalAllForExit(io: std.Io) void {
    everyone.exiting.store(true, .seq_cst);
    everyone.mutex.lockUncancelable(io);
    defer everyone.mutex.unlock(io);
    var it = everyone.list.first;
    while (it) |node| : (it = node.next) {
        const p: *Process = @fieldParentPtr("node", node);
        p.signal(.term);
    }
}

const helper = struct {
    var mutex: std.Io.Mutex = .init;
    var started = false;
    var stdin: ?std.posix.fd_t = null;
    var pid: std.posix.pid_t = 0;

    const script =
        \\trap '' INT HUP
        \\g=
        \\while read -r m; do
        \\  case $m in
        \\    +*) g="$g ${m#+}" ;;
        \\    -*) k=; for x in $g; do [ "$x" = "${m#-}" ] || k="$k $x"; done; g=$k ;;
        \\  esac
        \\done
        \\[ -n "$g" ] || exit 0
        \\for x in $g; do kill -s TERM -- "-$x"; done
        \\sleep 2
        \\for x in $g; do kill -s KILL -- "-$x"; done
    ;

    fn start(io: std.Io) void {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (started) return;
        started = true;
        const child = std.process.spawn(io, .{
            .argv = &.{ "/bin/sh", "-c", script },
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,

            .pgid = 0,
        }) catch return;
        const fd = child.stdin.?.handle;

        _ = std.posix.system.fcntl(fd, std.posix.F.SETFL, @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK"));
        stdin = fd;
        pid = child.id.?;
    }

    fn tell(io: std.Io, sign: u8, group: std.posix.pid_t) void {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        const fd = stdin orelse return;
        var buffer: [16]u8 = undefined;
        const line = std.mem.print(&buffer, "{c}{d}\n", .{ sign, group }) catch return;
        if (std.c.write(fd, line.ptr, line.len) == line.len) return;
        std.posix.kill(pid, .KILL) catch {};
        stdin = null;
    }
};

pub const Options = struct {
    argv: []const []const u8,
    environ_map: ?*const std.process.Environ.Map = null,
    cwd: ?[]const u8 = null,
    config: core.Config = .{},
    max_line: usize = 16 * 1024 * 1024,
    max_stderr_line: usize = 8 * 1024,
    poll_ms: u32 = 20,
    trace: ?*trace.Writer = null,
    trace_instance: []const u8 = "stdio",
    bell: ?*Bell = null,
    stderr: ?Sink = null,
};

pub const Sink = struct {
    context: *anyopaque,
    line: *const fn (context: *anyopaque, line: []const u8) void,
};

pub const Incoming = union(enum) {
    message: struct { bytes: []const u8, message: wire.Message },
    stderr: []const u8,
    dropped: struct { err: wire.DecodeError, line: []const u8 },
    changed: struct { state: core.State, lost: bool, oversized: bool = false },
    timeout,
};

pub const SpawnError = std.process.SpawnError || std.Io.ConcurrentError;

pub const Exit = union(enum) { code: u8, signal: u8 };

pub fn maskedPrefix(out: []u8, text: []const u8) []const u8 {
    var n: usize = @min(text.len, out.len);
    if (n < text.len) {
        while (n > 0 and (text[n] & 0xC0) == 0x80) n -= 1;
    }
    for (text[0..n], out[0..n]) |c, *e| e.* = if (c < 0x20 or c == 0x7f) '?' else c;
    return out[0..n];
}

test "a masked prefix keeps whole UTF-8 sequences and shows control bytes as '?'" {
    var out: [6]u8 = undefined;
    try std.testing.expectEqualStrings("a?b?", maskedPrefix(&out, "a\x1bb\x7f"));

    try std.testing.expectEqualStrings("abcde", maskedPrefix(&out, "abcde\xc3\xa9"));
    try std.testing.expectEqualStrings("abcd\xc3\xa9", maskedPrefix(&out, "abcd\xc3\xa9z"));
    try std.testing.expectEqualStrings("", maskedPrefix(&out, ""));
}

pub const tail_max = 240;
const tail_lines = 3;

const stderr_drain_ms = 250;

fn exitOf(status: u32) ?Exit {
    if (std.c.W.IFEXITED(status)) return .{ .code = std.c.W.EXITSTATUS(status) };
    if (std.c.W.IFSIGNALED(status)) return .{ .signal = @truncate(@backingInt(std.c.W.TERMSIG(status))) };
    return null;
}

pub const Error = core.StepError || std.Io.Cancelable || std.Io.ConcurrentError || std.mem.Allocator.Error || error{TraceFailed};

const Posted = union(enum) {
    line: struct { generation: core.Generation, bytes: []u8 },
    oversized: core.Generation,
    stderr: []u8,
    exited: core.Generation,
    timer: core.Timer,
    write_failed: core.Generation,

    fn free(posted: Posted, gpa: std.mem.Allocator) void {
        switch (posted) {
            .line => |l| gpa.free(l.bytes),
            .stderr => |s| gpa.free(s),
            else => {},
        }
    }
};

const Stdin = struct {
    file: std.Io.File,
    generation: core.Generation,
    queue: std.Io.Queue([]u8),
    buffer: [256][]u8 = undefined,
    queued: std.atomic.Value(usize) = .init(0),
    refs: std.atomic.Value(u8) = .init(2),

    fn unref(s: *Stdin, p: *Process) void {
        if (s.refs.fetchSub(1, .acq_rel) != 1) return;
        var rest: [16][]u8 = undefined;
        while (true) {
            const n = s.queue.getUncancelable(p.io, &rest, 0) catch break;
            if (n == 0) break;
            for (rest[0..n]) |line| p.gpa.free(line);
        }
        s.file.close(p.io);
        p.gpa.destroy(s);
    }
};

pub const Process = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    options: Options,
    conn: core.Conn,
    queue: std.Io.Queue(Posted),
    queue_buffer: [64]Posted = undefined,
    tasks: std.Io.Group = .init,
    pid_lock: std.Io.Mutex = .init,
    pid: ?std.posix.pid_t = null,
    stdin: ?*Stdin = null,
    held: ?[]u8 = null,
    outgoing: []const u8 = "",
    own: Bell = undefined,
    stderr_dropped: std.atomic.Value(u32) = .init(0),
    budget: Budget,
    spawn_error: ?SpawnError = null,
    killed_oversized: bool = false,
    exit: ?Exit = null,
    tail_lock: std.Io.Mutex = .init,
    tail: [tail_lines][tail_max]u8 = undefined,
    tail_len: [tail_lines]u8 = @splat(0),
    tail_next: u8 = 0,
    tail_count: u8 = 0,
    stderr_done: std.atomic.Value(core.Generation) = .init(0),
    node: std.DoublyLinkedList.Node = .{},

    pub fn init(p: *Process, io: std.Io, gpa: std.mem.Allocator, options: Options) void {
        p.* = .{ .io = io, .gpa = gpa, .options = options, .conn = .init(options.config), .queue = undefined, .budget = .{ .max = options.max_line } };
        p.own.init(io);
        p.queue = .init(&p.queue_buffer);
        everyone.mutex.lockUncancelable(io);
        everyone.list.append(&p.node);
        everyone.mutex.unlock(io);
    }

    pub fn deinit(p: *Process) void {
        everyone.mutex.lockUncancelable(p.io);
        everyone.list.remove(&p.node);
        everyone.mutex.unlock(p.io);
        p.pid_lock.lockUncancelable(p.io);
        if (p.pid) |pid| {
            std.posix.kill(-pid, .KILL) catch std.posix.kill(pid, .KILL) catch {};
            _ = std.c.waitpid(pid, null, 0);
            helper.tell(p.io, '-', pid);
            p.pid = null;
        }
        p.pid_lock.unlock(p.io);
        p.closeStdin();
        p.tasks.cancel(p.io);
        p.queue.close(p.io);
        var rest: [16]Posted = undefined;
        while (true) {
            const n = p.queue.getUncancelable(p.io, &rest, 0) catch break;
            if (n == 0) break;
            for (rest[0..n]) |posted| posted.free(p.gpa);
        }
        p.release();
        p.budget.deinit(p.gpa);
    }

    pub fn start(p: *Process) Error!void {
        _ = try p.apply(.start_requested);
    }

    pub fn stop(p: *Process) Error!void {
        _ = try p.apply(.stop_requested);
    }

    pub fn reconnect(p: *Process) Error!void {
        _ = try p.apply(.reconnect_requested);
    }

    pub fn setEra(p: *Process, era: @FieldType(core.Event, "era_detected")) Error!void {
        _ = try p.apply(.{ .era_detected = era });
    }

    pub fn send(p: *Process, kind: core.MessageKind, message: []const u8) Error!void {
        std.debug.assert(std.mem.findAny(u8, message, "\r\n") == null);
        p.outgoing = message;
        defer p.outgoing = "";
        _ = try p.apply(.{ .send = kind });
    }

    pub fn next(p: *Process, timeout_ms: ?u32) Error!Incoming {
        const deadline = if (timeout_ms) |ms| std.Io.Clock.awake.now(p.io).toMilliseconds() + ms else null;
        while (true) {
            if (try p.poll()) |incoming| return incoming;
            const left: ?u32 = if (deadline) |d| @intCast(@max(0, d - std.Io.Clock.awake.now(p.io).toMilliseconds())) else null;
            if (left == 0) return .timeout;
            try p.own.wait(left);
        }
    }

    pub fn poll(p: *Process) Error!?Incoming {
        p.release();
        var one: [1]Posted = undefined;
        while ((p.queue.get(p.io, &one, 0) catch 0) == 1) {
            switch (one[0]) {
                .line => |l| p.budget.give(p.io, l.bytes.len),
                else => {},
            }
            if (try p.take(one[0])) |incoming| return incoming;
        }
        return null;
    }

    fn take(p: *Process, posted: Posted) Error!?Incoming {
        const before = p.conn.state;
        const lost = switch (posted) {
            .line => |line| {
                const message = wire.decode(line.bytes) catch |err| {
                    if (line.generation != p.conn.generation) {
                        p.gpa.free(line.bytes);
                        return .{ .dropped = .{ .err = err, .line = "" } };
                    }
                    p.held = line.bytes;
                    return .{ .dropped = .{ .err = err, .line = line.bytes } };
                };
                const result = p.apply(.{ .line_received = line.generation }) catch |err| {
                    p.gpa.free(line.bytes);
                    return err;
                };
                if (result.delivered) {
                    p.held = line.bytes;
                    return .{ .message = .{ .bytes = line.bytes, .message = message } };
                }
                p.gpa.free(line.bytes);
                return null;
            },
            .stderr => |bytes| {
                p.held = bytes;
                return .{ .stderr = bytes };
            },
            .oversized => |g| blk: {
                const applied = try p.apply(.{ .oversized_line = g });
                if (before == .running and p.conn.state == .killing) p.killed_oversized = true;
                break :blk applied.lost;
            },
            .exited => |g| (try p.apply(.{ .process_exited = g })).lost,
            .timer => |t| (try p.apply(.{ .timer_fired = t })).lost,

            .write_failed => |g| if (g == p.conn.generation) (try p.apply(.write_failed)).lost else false,
        };
        const oversized = lost and p.killed_oversized;
        if (lost) p.killed_oversized = false;
        if (lost or p.conn.state != before) return .{ .changed = .{ .state = p.conn.state, .lost = lost, .oversized = oversized } };
        return null;
    }

    fn release(p: *Process) void {
        if (p.held) |bytes| p.budget.recycle(p.io, p.gpa, bytes);
        p.held = null;
    }

    const Applied = struct { delivered: bool = false, lost: bool = false };

    fn apply(p: *Process, first: core.Event) Error!Applied {
        var result: Applied = .{};
        var event: ?core.Event = first;
        while (event) |current| {
            event = null;
            var out: core.Output = .{};
            try p.conn.step(current, &out);
            if (trace.on(p.options.trace)) |writer| {
                core.writeTrace(writer, p.options.trace_instance, &out) catch return error.TraceFailed;
            }
            for (out.effects()) |effect| switch (effect) {
                .spawn => |g| {
                    p.spawn_error = null;
                    p.killed_oversized = false;
                    p.pid_lock.lockUncancelable(p.io);
                    p.exit = null;
                    p.pid_lock.unlock(p.io);
                    p.tail_lock.lockUncancelable(p.io);
                    p.tail_count = 0;
                    p.tail_lock.unlock(p.io);
                    event = if (p.spawn(g)) |_| .spawned else |err| blk: {
                        p.spawn_error = err;
                        break :blk .spawn_failed;
                    };
                },
                .close_stdin => p.closeStdin(),
                .signal => |s| p.signal(s.signal),
                .arm_timer => |a| try p.tasks.concurrent(p.io, postAfter, .{ p, .{ .timer = a.timer }, p.delay(a.timer.kind, a.after_ms) }),
                .deliver => result.delivered = true,
                .write => p.write() catch {
                    event = .write_failed;
                },
                .ready => {},
                .lost => {
                    result.lost = true;

                    p.closeStdin();
                },
            };
        }
        return result;
    }

    fn spawn(p: *Process, generation: core.Generation) SpawnError!void {
        std.debug.assert(p.stdin == null);
        helper.start(p.io);
        const stdin = try p.gpa.create(Stdin);
        const child = std.process.spawn(p.io, .{
            .argv = p.options.argv,
            .environ_map = p.options.environ_map,
            .cwd = if (p.options.cwd) |dir| .{ .path = dir } else .inherit,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,

            .pgid = 0,
        }) catch |err| {
            p.gpa.destroy(stdin);
            return err;
        };
        const pid = child.id.?;
        p.pid_lock.lockUncancelable(p.io);
        p.pid = pid;
        p.pid_lock.unlock(p.io);

        helper.tell(p.io, '+', pid);

        if (everyone.exiting.load(.seq_cst)) p.signal(.term);
        stdin.* = .{ .file = child.stdin.?, .generation = generation, .queue = undefined };
        stdin.queue = .init(&stdin.buffer);
        p.tasks.concurrent(p.io, writeLines, .{ p, stdin }) catch |err| {
            stdin.file.close(p.io);
            p.gpa.destroy(stdin);
            p.stopSpawned(child.stdout.?, child.stderr.?);
            return err;
        };
        p.stdin = stdin;

        var unread: [2]?std.Io.File = .{ child.stdout.?, child.stderr.? };
        errdefer p.stopSpawned(unread[0], unread[1]);
        try p.tasks.concurrent(p.io, readLines, .{ p, child.stdout.?, .{ .stdout = generation } });
        unread[0] = null;
        try p.tasks.concurrent(p.io, readLines, .{ p, child.stderr.?, .{ .stderr = generation } });
        unread[1] = null;
        try p.tasks.concurrent(p.io, watch, .{ p, generation, pid });
    }

    fn stopSpawned(p: *Process, stdout: ?std.Io.File, stderr: ?std.Io.File) void {
        p.signal(.kill);
        p.pid_lock.lockUncancelable(p.io);
        if (p.pid) |pid| {
            _ = std.c.waitpid(pid, null, 0);
            helper.tell(p.io, '-', pid);
        }
        p.pid = null;
        p.pid_lock.unlock(p.io);
        p.closeStdin();
        if (stdout) |f| f.close(p.io);
        if (stderr) |f| f.close(p.io);
    }

    fn signal(p: *Process, which: core.Signal) void {
        p.pid_lock.lockUncancelable(p.io);
        defer p.pid_lock.unlock(p.io);
        const pid = p.pid orelse return;
        const sig: std.posix.SIG = switch (which) {
            .term => .TERM,
            .kill => .KILL,
        };

        std.posix.kill(-pid, sig) catch std.posix.kill(pid, sig) catch {};
    }

    fn write(p: *Process) !void {
        const s = p.stdin orelse return error.NotOpen;
        const size = p.outgoing.len + 1;
        const waiting = s.queued.fetchAdd(size, .monotonic);
        if (waiting != 0 and waiting + size > p.options.max_line) {
            _ = s.queued.fetchSub(size, .monotonic);
            return error.Full;
        }
        errdefer _ = s.queued.fetchSub(size, .monotonic);
        const line = try p.gpa.alloc(u8, size);
        errdefer p.gpa.free(line);
        @memcpy(line[0..p.outgoing.len], p.outgoing);
        line[p.outgoing.len] = '\n';
        if (try s.queue.put(p.io, &.{line}, 0) == 0) return error.Full;
    }

    fn writeLines(p: *Process, s: *Stdin) std.Io.Cancelable!void {
        defer s.unref(p);
        while (true) {
            const line = s.queue.getOne(p.io) catch |err| switch (err) {
                error.Closed => return,
                error.Canceled => return error.Canceled,
            };
            defer p.gpa.free(line);
            _ = s.queued.fetchSub(line.len, .monotonic);
            s.file.writeStreamingAll(p.io, line) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return p.post(.{ .write_failed = s.generation }),
            };
        }
    }

    fn closeStdin(p: *Process) void {
        const s = p.stdin orelse return;
        p.stdin = null;
        s.queue.close(p.io);
        s.unref(p);
    }

    fn delay(p: *Process, kind: core.TimerKind, after_ms: u32) u32 {
        if (kind != .backoff or after_ms < 2) return after_ms;
        var bytes: [4]u8 = undefined;
        p.io.random(&bytes);
        const half = after_ms / 2;
        return half + std.mem.readInt(u32, &bytes, .little) % (after_ms - half + 1);
    }

    fn post(p: *Process, posted: Posted) std.Io.Cancelable!void {
        p.queue.putOne(p.io, posted) catch |err| {
            switch (posted) {
                .line => |l| p.budget.give(p.io, l.bytes.len),
                else => {},
            }
            posted.free(p.gpa);
            if (err == error.Canceled) return error.Canceled;
            return;
        };
        p.ring();
    }

    const Stream = union(enum) {
        stdout: core.Generation,
        stderr: core.Generation,
    };

    fn readLines(p: *Process, file: std.Io.File, stream: Stream) std.Io.Cancelable!void {
        defer file.close(p.io);

        defer if (stream == .stderr) {
            _ = p.stderr_done.fetchMax(stream.stderr, .release);
        };
        var buffer: [16 * 1024]u8 = undefined;
        var file_reader = file.reader(p.io, &buffer);
        const reader = &file_reader.interface;
        const limit = if (stream == .stdout) p.options.max_line else p.options.max_stderr_line;
        var line: std.Io.Writer.Allocating = .init(p.gpa);
        defer line.deinit();
        while (true) {
            const got = lines.read(reader, &line, limit) catch return;

            var at_end = got.at_end;
            if (got.too_long) switch (stream) {
                .stdout => |g| return p.post(.{ .oversized = g }),
                .stderr => at_end = lines.skipRest(reader) catch return,
            };

            if (at_end and stream == .stdout) return;

            const bytes = got.bytes;
            if (bytes.len > 0 and stream == .stderr) p.keepTail(bytes);
            if (bytes.len > 0 and stream == .stderr and p.options.stderr != null) {
                const sink = p.options.stderr.?;
                sink.line(sink.context, bytes);
            } else if (bytes.len > 0) {
                const owned = switch (stream) {
                    .stdout => try p.budget.copy(p.io, p.gpa, bytes),
                    .stderr => p.gpa.dupe(u8, bytes) catch null,
                } orelse return;
                switch (stream) {
                    .stdout => |g| try p.post(.{ .line = .{ .generation = g, .bytes = owned } }),

                    .stderr => if ((p.queue.put(p.io, &.{.{ .stderr = owned }}, 0) catch 0) == 0) {
                        p.gpa.free(owned);
                        _ = p.stderr_dropped.fetchAdd(1, .monotonic);
                    } else p.ring(),
                }
            }
            if (at_end) return;
        }
    }

    fn watch(p: *Process, generation: core.Generation, pid: std.posix.pid_t) std.Io.Cancelable!void {
        while (true) {
            p.pid_lock.lockUncancelable(p.io);
            var status: c_int = 0;
            const result = std.c.waitpid(pid, &status, std.c.W.NOHANG);

            const gone = result == pid or result == -1;
            if (result == pid) p.exit = exitOf(@bitCast(status));
            if (gone) {
                helper.tell(p.io, '-', pid);
                p.pid = null;
            }
            p.pid_lock.unlock(p.io);
            if (gone) {
                try p.awaitStderr(generation);
                return p.post(.{ .exited = generation });
            }
            try p.io.sleep(.fromMilliseconds(p.options.poll_ms), .awake);
        }
    }

    fn awaitStderr(p: *Process, generation: core.Generation) std.Io.Cancelable!void {
        const deadline = std.Io.Clock.awake.now(p.io).toMilliseconds() + stderr_drain_ms;
        while (p.stderr_done.load(.acquire) < generation and
            std.Io.Clock.awake.now(p.io).toMilliseconds() < deadline)
        {
            try p.io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    fn keepTail(p: *Process, line: []const u8) void {
        p.tail_lock.lockUncancelable(p.io);
        defer p.tail_lock.unlock(p.io);
        const slot = p.tail_next;
        p.tail_len[slot] = @intCast(maskedPrefix(&p.tail[slot], std.mem.trimEnd(u8, line, " \t\r")).len);
        p.tail_next = (slot + 1) % tail_lines;
        p.tail_count = @min(p.tail_count + 1, tail_lines);
    }

    pub fn exitStatus(p: *Process) ?Exit {
        p.pid_lock.lockUncancelable(p.io);
        defer p.pid_lock.unlock(p.io);
        return p.exit;
    }

    pub fn stderrTail(p: *Process, out: *[tail_max]u8) []const u8 {
        var all: [tail_lines * (tail_max + 3)]u8 = undefined;
        var w: std.Io.Writer = .fixed(&all);
        p.tail_lock.lockUncancelable(p.io);
        var k: u8 = 0;
        while (k < p.tail_count) : (k += 1) {
            const slot = (p.tail_next + tail_lines - p.tail_count + k) % tail_lines;
            if (k > 0) w.writeAll(" / ") catch unreachable;
            w.writeAll(p.tail[slot][0..p.tail_len[slot]]) catch unreachable;
        }
        p.tail_lock.unlock(p.io);
        var text = w.buffered();
        if (text.len > tail_max) {
            text = text[text.len - tail_max ..];
            while (text.len > 0 and (text[0] & 0xC0) == 0x80) text = text[1..];
        }
        @memcpy(out[0..text.len], text);
        return out[0..text.len];
    }

    fn ring(p: *Process) void {
        p.own.ring();
        if (p.options.bell) |b| b.ring();
    }

    fn postAfter(p: *Process, posted: Posted, after_ms: u32) std.Io.Cancelable!void {
        try p.io.sleep(.fromMilliseconds(after_ms), .awake);
        try p.post(posted);
    }
};

const testing = std.testing;

const test_config: core.Config = .{ .max_attempts = 2, .grace_ms = 100, .term_ms = 100, .backoff_ms = 20, .backoff_cap_ms = 40 };

fn shell(script: []const u8) [3][]const u8 {
    return .{ "/bin/sh", "-c", script };
}

fn initTest(p: *Process, argv: []const []const u8) void {
    p.init(testing.io, testing.allocator, .{ .argv = argv, .config = test_config, .poll_ms = 5, .max_line = 64 });
}

fn expectState(p: *Process, state: core.State) !void {
    for (0..200) |_| switch (try p.next(5_000)) {
        .changed => |c| if (c.state == state) return,
        .timeout => return error.TestTimeout,
        else => {},
    };
    return error.TestUnexpectedResult;
}

fn expectStderr(p: *Process, line: []const u8) !void {
    for (0..200) |_| switch (try p.next(5_000)) {
        .stderr => |bytes| if (std.mem.eql(u8, bytes, line)) return,
        .timeout => return error.TestTimeout,
        else => {},
    };
    return error.TestUnexpectedResult;
}

test "messages arrive, and a stop that closes stdin ends the server" {
    const argv = shell("printf '{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\"}\\n'; exec cat >/dev/null");

    var config = test_config;
    config.grace_ms = 5_000;
    var p: Process = undefined;
    p.init(testing.io, testing.allocator, .{ .argv = &argv, .config = config, .poll_ms = 5, .max_line = 64 });
    defer p.deinit();
    try p.start();
    try testing.expectEqual(core.State.running, p.conn.state);
    const first = try p.next(5_000);
    try testing.expectEqualStrings("notifications/message", first.message.message.notification.method);
    try p.send(.request, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}");
    try p.stop();
    try expectState(&p, .stopped);
    try testing.expect(!p.conn.term_sent and !p.conn.kill_sent);
}

test "lines past the budget all arrive, each once the one before it is taken" {
    const argv = shell("for i in 1 2 3 4 5 6; do printf '{\"jsonrpc\":\"2.0\",\"method\":\"notifications/n%s\"}\\n' $i; done; exec cat >/dev/null");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    var got: usize = 0;
    while (got < 6) switch (try p.next(5_000)) {
        .message => got += 1,
        .timeout => return error.TestTimeout,
        else => {},
    };
    try testing.expect(p.budget.used <= 64);
    try p.stop();
    try expectState(&p, .stopped);
}

test "a server starts in the directory it's given" {
    const argv = shell("printf '{\"jsonrpc\":\"2.0\",\"method\":\"%s\"}\\n' \"$(pwd -P)\"; exec cat >/dev/null");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    p.options.cwd = "/";
    try p.start();
    const first = try p.next(5_000);
    try testing.expectEqualStrings("/", first.message.message.notification.method);
    try p.stop();
    try expectState(&p, .stopped);
}

test "a server that ignores closed stdin gets SIGTERM, then SIGKILL if it ignores that too" {
    inline for (.{ .{ "trap 'exit 0' TERM; echo ready >&2; while :; do sleep 0.02; done", false, 5_000 }, .{ "trap '' TERM; echo ready >&2; while :; do sleep 0.02; done", true, test_config.term_ms } }) |case| {
        const argv = shell(case[0]);
        var config = test_config;
        config.term_ms = case[2];
        var p: Process = undefined;
        p.init(testing.io, testing.allocator, .{ .argv = &argv, .config = config, .poll_ms = 5, .max_line = 64 });
        defer p.deinit();
        try p.start();
        try expectStderr(&p, "ready");
        try p.stop();
        try expectState(&p, .stopped);
        try testing.expect(p.conn.term_sent);
        try testing.expectEqual(case[1], p.conn.kill_sent);
    }
}

test "signalAllForExit sends SIGTERM to every server at once, even one that starts after it" {
    defer everyone.exiting.store(false, .seq_cst);

    const argv = shell("trap 'exit 0' TERM; while :; do sleep 0.02; done");
    var running: Process = undefined;
    initTest(&running, &argv);
    defer running.deinit();
    try running.start();
    const before = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    signalAllForExit(testing.io);
    try testing.expect(std.Io.Clock.awake.now(testing.io).toMilliseconds() - before < 500);
    var late: Process = undefined;
    initTest(&late, &argv);
    defer late.deinit();
    try late.start();
    inline for (.{ &running, &late }) |p| {
        try expectState(p, .backoff);

        try testing.expect(!p.conn.term_sent);
    }
}

test "a crashing server backs off, restarts on demand, then fails at the limit" {
    const argv = shell("exit 3");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    try expectState(&p, .backoff);

    try testing.expect(p.stdin == null);
    try expectState(&p, .idle);
    try p.start();
    try expectState(&p, .failed);
    try testing.expectEqual(@as(u8, 2), p.conn.attempts);
}

test "how a server's process ended is kept until it starts again" {
    const argv = shell("exit 3");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    try expectState(&p, .backoff);
    try testing.expectEqual(Exit{ .code = 3 }, p.exitStatus().?);
}

test "a command that can't start counts as a failure" {
    const argv = [_][]const u8{"/nonexistent/mcpv2-test-server"};
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    try testing.expectEqual(core.State.backoff, p.conn.state);
    try testing.expect(p.spawn_error != null);
}

test "a spawn that works clears the last spawn error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testing.allocator.print(".zig-cache/tmp/{s}/server", .{tmp.sub_path});
    defer testing.allocator.free(path);
    const argv = [_][]const u8{path};
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    try testing.expect(p.spawn_error != null);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "server", .data = "#!/bin/sh\nexec cat >/dev/null\n", .flags = .{ .permissions = .executable_file } });
    try expectState(&p, .idle);
    try p.start();
    try testing.expectEqual(core.State.running, p.conn.state);
    try testing.expect(p.spawn_error == null);
}

test "lines that aren't MCP messages are dropped, and CRLF and empty lines are handled" {
    const argv = shell("printf 'server starting\\r\\n\\r\\n{\"jsonrpc\":\"2.0\",\"method\":\"m\"}\\r\\n'; exec cat >/dev/null");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    try testing.expectEqual(wire.DecodeError.InvalidJson, (try p.next(5_000)).dropped.err);
    const message = (try p.next(5_000)).message;
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"m\"}", message.bytes);
}

test "a send to a server that stops reading returns at once; only stdin's writer waits" {
    const argv = shell("exec sleep 30");
    var p: Process = undefined;
    p.init(testing.io, testing.allocator, .{ .argv = &argv, .config = test_config, .poll_ms = 5 });
    defer p.deinit();
    try p.start();
    try testing.expectEqual(core.State.running, p.conn.state);
    const big = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    const started = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    try p.send(.notification, big);
    try p.send(.notification, "{}");
    try testing.expect(std.Io.Clock.awake.now(testing.io).toMilliseconds() - started < 2_000);
    try testing.expectEqual(core.State.running, p.conn.state);
}

test "a server that stops reading is a broken connection once what waits passes the line limit" {
    const argv = shell("exec sleep 30");
    var p: Process = undefined;
    p.init(testing.io, testing.allocator, .{ .argv = &argv, .config = test_config, .poll_ms = 5, .max_line = 4096 });
    defer p.deinit();
    try p.start();
    const big = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(big);
    @memset(big, 'x');

    try p.send(.notification, big);
    try testing.expectEqual(core.State.running, p.conn.state);
    for (0..4) |_| if (p.conn.state == .running) try p.send(.notification, big[0..3000]);
    try testing.expectEqual(core.State.killing, p.conn.state);
    try expectState(&p, .backoff);
}

test "a server that closes its stdin is a broken connection once a write fails" {
    const argv = shell("exec 0<&-; sleep 30");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();

    for (0..250) |_| {
        try p.send(.notification, "{}");
        switch (try p.next(20)) {
            .changed => |c| if (c.state == .killing) return,
            else => {},
        }
    }
    return error.TestTimeout;
}

test "a write failure from an earlier process is ignored" {
    const argv = shell("exec cat >/dev/null");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    try p.post(.{ .write_failed = p.conn.generation -% 1 });
    try testing.expect(try p.next(50) == .timeout);
    try testing.expectEqual(core.State.running, p.conn.state);
    try p.post(.{ .write_failed = p.conn.generation });
    try expectState(&p, .killing);
}

test "an oversized line kills the server" {
    const argv = shell("printf '%0100d\\n' 0; exec cat >/dev/null");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    try expectState(&p, .killing);
    try expectState(&p, .backoff);
    try testing.expect(p.conn.errored and !p.conn.term_sent);
}

test "the loss from killing a server for an oversized line says so, and an ordinary exit's doesn't" {
    const big = shell("printf '%0100d\\n' 0; exec cat >/dev/null");
    var p: Process = undefined;
    initTest(&p, &big);
    defer p.deinit();
    try p.start();
    const lost = for (0..200) |_| switch (try p.next(5_000)) {
        .changed => |c| if (c.lost) break c,
        .timeout => return error.TestTimeout,
        else => {},
    } else return error.TestUnexpectedResult;
    try testing.expect(lost.oversized);
    try testing.expect(!p.killed_oversized);

    const quits = shell("exit 3");
    var q: Process = undefined;
    initTest(&q, &quits);
    defer q.deinit();
    try q.start();
    const gone = for (0..200) |_| switch (try q.next(5_000)) {
        .changed => |c| if (c.lost) break c,
        .timeout => return error.TestTimeout,
        else => {},
    } else return error.TestUnexpectedResult;
    try testing.expect(!gone.oversized);
}

test "stderr lines reach the host and never change the state" {
    const argv = shell("echo warming up >&2; exec cat >/dev/null");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    try testing.expectEqualStrings("warming up", (try p.next(5_000)).stderr);
    try testing.expectEqual(core.State.running, p.conn.state);
}

const SlowSink = struct {
    mutex: std.Io.Mutex = .init,
    seen: [64]u8 = undefined,
    len: usize = 0,

    fn line(context: *anyopaque, bytes: []const u8) void {
        const s: *SlowSink = @ptrCast(@alignCast(context));
        testing.io.sleep(.fromMilliseconds(40), .awake) catch {};
        s.mutex.lockUncancelable(testing.io);
        defer s.mutex.unlock(testing.io);
        s.len = @min(bytes.len, s.seen.len);
        @memcpy(s.seen[0..s.len], bytes[0..s.len]);
    }

    fn text(s: *SlowSink) []const u8 {
        s.mutex.lockUncancelable(testing.io);
        defer s.mutex.unlock(testing.io);
        return s.seen[0..s.len];
    }
};

test "a server's last stderr lines reach the sink and the tail before its exit does" {
    const argv = shell("echo trace-me >&2; exit 3");
    var sink: SlowSink = .{};
    var p: Process = undefined;
    p.init(testing.io, testing.allocator, .{
        .argv = &argv,
        .config = test_config,
        .poll_ms = 5,
        .max_line = 64,
        .stderr = .{ .context = &sink, .line = SlowSink.line },
    });
    defer p.deinit();
    try p.start();
    try expectState(&p, .backoff);
    try testing.expectEqualStrings("trace-me", sink.text());
    var tail: [tail_max]u8 = undefined;
    try testing.expectEqualStrings("trace-me", p.stderrTail(&tail));
}

test "a child that keeps stderr open delays a server's exit by at most stderr_drain_ms" {
    const argv = shell("sleep 30 & echo $! >&2; exit 3");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    const child = try std.fmt.parseInt(std.posix.pid_t, (try p.next(5_000)).stderr, 10);
    defer std.posix.kill(child, .KILL) catch {};
    const started = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    try expectState(&p, .backoff);
    try testing.expect(std.Io.Clock.awake.now(testing.io).toMilliseconds() - started < 2_000);
}

test "a stop signals the server's whole process group, so its children stop too" {
    const argv = shell("sleep 30 & echo $! >&2; wait");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    const child = try std.fmt.parseInt(std.posix.pid_t, (try p.next(5_000)).stderr, 10);
    defer std.posix.kill(child, .KILL) catch {};
    try p.stop();
    try expectState(&p, .stopped);
    try testing.expect(p.conn.term_sent);
    for (0..100) |_| {
        std.posix.kill(child, @fromBackingInt(@intCast(0))) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.ChildStillRunning;
}

test "the helper hears each server group that starts and each one that is reaped, in order" {
    helper.start(testing.io);
    const ends = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    defer for (ends) |fd| {
        _ = std.c.close(fd);
    };
    helper.mutex.lockUncancelable(testing.io);
    const real = helper.stdin;
    helper.stdin = ends[1];
    helper.mutex.unlock(testing.io);
    defer {
        helper.mutex.lockUncancelable(testing.io);
        helper.stdin = real;
        helper.mutex.unlock(testing.io);
    }
    const argv = shell("exec cat >/dev/null");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();
    p.pid_lock.lockUncancelable(testing.io);
    const pid = p.pid.?;
    p.pid_lock.unlock(testing.io);
    try p.stop();
    try expectState(&p, .stopped);
    var heard: [64]u8 = undefined;
    const n = std.c.read(ends[0], &heard, heard.len);
    var want: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.mem.print(&want, "+{d}\n-{d}\n", .{ pid, pid }), heard[0..@intCast(n)]);
}

test "once the program is gone, the helper kills a server that ignores SIGTERM and closed stdin, after 2 s" {
    const argv = shell("trap '' TERM; echo ready >&2; exec 0</dev/null; while :; do sleep 1; done");
    var p: Process = undefined;
    initTest(&p, &argv);
    defer p.deinit();
    try p.start();

    try testing.expectEqualStrings("ready", (try p.next(5_000)).stderr);

    helper.mutex.lockUncancelable(testing.io);
    const fd = helper.stdin;
    if (fd) |f| _ = std.c.close(f);
    helper.stdin = null;
    helper.mutex.unlock(testing.io);
    if (fd == null) return error.NoHelper;
    const closed = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    while (true) switch (try p.next(10_000)) {
        .changed => |c| if (c.state != .running) break,
        .timeout => return error.TestTimeout,
        else => {},
    };
    const waited = std.Io.Clock.awake.now(testing.io).toMilliseconds() - closed;
    try testing.expect(waited >= 1_900 and waited < 6_000);
}

test "deinit kills the server's whole process group, so its children stop too" {
    const argv = shell("sleep 30 & echo $! >&2; wait");
    var p: Process = undefined;
    initTest(&p, &argv);
    try p.start();
    const child = try std.fmt.parseInt(std.posix.pid_t, (try p.next(5_000)).stderr, 10);
    defer std.posix.kill(child, .KILL) catch {};
    p.deinit();
    for (0..100) |_| {
        std.posix.kill(child, @fromBackingInt(@intCast(0))) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.ChildStillRunning;
}

fn stubbornGroup() !std.process.Child {
    var child = try std.process.spawn(testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "trap '' TERM; echo ready >&2; while :; do sleep 1; done" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
        .pgid = 0,
    });
    var buffer: [16]u8 = undefined;
    var reader = child.stderr.?.reader(testing.io, &buffer);
    _ = try reader.interface.takeDelimiterInclusive('\n');
    return child;
}

fn endsWithin(pid: std.posix.pid_t, ms: u32) bool {
    for (0..ms / 10) |_| {
        if (std.c.waitpid(pid, null, std.c.W.NOHANG) == pid) return true;
        testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return false;
}

test "the helper kills the groups it still lists 2 s after its stdin closes, and none it was told are gone" {
    var listed = try stubbornGroup();
    defer listed.stderr.?.close(testing.io);
    var gone = try stubbornGroup();
    defer gone.stderr.?.close(testing.io);
    defer if (!endsWithin(gone.id.?, 10)) {
        std.posix.kill(-gone.id.?, .KILL) catch {};
        _ = std.c.waitpid(gone.id.?, null, 0);
    };
    defer if (!endsWithin(listed.id.?, 10)) {
        std.posix.kill(-listed.id.?, .KILL) catch {};
        _ = std.c.waitpid(listed.id.?, null, 0);
    };
    var reaper = try std.process.spawn(testing.io, .{ .argv = &.{ "/bin/sh", "-c", helper.script }, .stdin = .pipe, .stdout = .ignore, .stderr = .ignore, .pgid = 0 });
    var said: [64]u8 = undefined;
    const told = try std.mem.print(&said, "+{d}\n+{d}\n-{d}\n", .{ listed.id.?, gone.id.?, gone.id.? });
    try testing.expectEqual(@as(isize, @intCast(told.len)), std.c.write(reaper.stdin.?.handle, told.ptr, told.len));
    reaper.stdin.?.close(testing.io);
    const closed = std.Io.Clock.awake.now(testing.io).toMilliseconds();
    try testing.expect(endsWithin(reaper.id.?, 6_000));
    const waited = std.Io.Clock.awake.now(testing.io).toMilliseconds() - closed;
    try testing.expect(waited >= 1_900);
    try testing.expect(endsWithin(listed.id.?, 1_000));
    try testing.expect(!endsWithin(gone.id.?, 100));
}

fn openDescriptors() usize {
    var n: usize = 0;
    for (0..1024) |fd| {
        if (std.posix.system.fcntl(@intCast(fd), std.posix.F.GETFD, @as(usize, 0)) != -1) n += 1;
    }
    return n;
}

test "a start whose tasks can't all run closes each of the server's pipes once" {
    helper.start(testing.io);

    for ([_]usize{ 1, 2, 3 }) |limit| {
        var threaded: std.Io.Threaded = .init(testing.allocator, .{ .concurrent_limit = .limited(limit) });
        defer threaded.deinit();
        const before = openDescriptors();
        const argv = shell("exec cat");
        {
            var p: Process = undefined;
            p.init(threaded.io(), testing.allocator, .{ .argv = &argv, .config = test_config, .poll_ms = 5, .max_line = 64 });
            defer p.deinit();

            p.start() catch |err| try testing.expectEqual(error.ConcurrencyUnavailable, err);
            try testing.expectEqual(@as(?SpawnError, error.ConcurrencyUnavailable), p.spawn_error);
        }

        try testing.expectEqual(before, openDescriptors());
    }
}

test "what a process says wakes a timed wait at once" {
    const scripts = [_][]const u8{
        "printf '{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\"}\\n'; exec cat >/dev/null",
        "echo warming up >&2; exec cat >/dev/null",
    };
    for (scripts, 0..) |script, i| {
        const argv = shell(script);
        var p: Process = undefined;
        initTest(&p, &argv);
        defer p.deinit();
        try p.start();
        const started = std.Io.Clock.awake.now(testing.io).toMilliseconds();
        const incoming = try p.next(10_000);
        if (i == 0)
            try testing.expectEqualStrings("notifications/message", incoming.message.message.notification.method)
        else
            try testing.expectEqualStrings("warming up", incoming.stderr);
        try testing.expect(std.Io.Clock.awake.now(testing.io).toMilliseconds() - started < 3_000);
    }
}

test "a timed wait starts no task, so it works where none can run" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .concurrent_limit = .nothing });
    defer threaded.deinit();
    var p: Process = undefined;
    p.init(threaded.io(), testing.allocator, .{ .argv = &.{"/bin/true"}, .config = test_config });
    defer p.deinit();
    try testing.expect((try p.next(20)) == .timeout);
}
