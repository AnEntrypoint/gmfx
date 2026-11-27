const std = @import("std");
const Allocator = std.mem.Allocator;

pub const c = @import("sqlite_c");

pub fn open(path: [:0]const u8) !*c.sqlite3 {
    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null);
    if (rc != c.SQLITE_OK or db == null) {
        if (db) |handle| _ = c.sqlite3_close(handle);
        return error.SqliteOpenFailed;
    }
    return db.?;
}

pub fn close(db: *c.sqlite3) void {
    _ = c.sqlite3_close(db);
}

pub fn exec(db: *c.sqlite3, sql: [:0]const u8) !void {
    var message: [*c]u8 = null;
    if (c.sqlite3_exec(db, sql.ptr, null, null, &message) != c.SQLITE_OK) {
        c.sqlite3_free(message);
        return error.SqliteExecFailed;
    }
}

pub fn all(alloc: Allocator, db: *c.sqlite3, sql: [:0]const u8) ![][][]u8 {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.SqliteExecFailed;
    defer _ = c.sqlite3_finalize(stmt);
    var rows: std.ArrayList([][]u8) = .empty;
    errdefer rows.deinit(alloc);
    while (true) {
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.SqliteExecFailed;
        const count: usize = @intCast(c.sqlite3_column_count(stmt));
        const row = try alloc.alloc([]u8, count);
        for (row, 0..) |*cell, index| {
            const text = c.sqlite3_column_text(stmt, @intCast(index));
            const length: usize = @intCast(c.sqlite3_column_bytes(stmt, @intCast(index)));
            cell.* = if (text == null) try alloc.dupe(u8, "") else try alloc.dupe(u8, @as([*]const u8, @ptrCast(text))[0..length]);
        }
        try rows.append(alloc, row);
    }
    return rows.toOwnedSlice(alloc);
}
