const std = @import("std");
const c = @cImport(@cInclude("sqlite3.h"));

/// Workspace row
pub const Workspace = struct {
    id: []const u8,
    name: []const u8,
    domain: []const u8,
    user_token_keychain_key: []const u8,
    app_token_keychain_key: []const u8,
};

/// Channel row
pub const Channel = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    channel_type: []const u8,
    is_member: bool,
    last_read_ts: ?[]const u8,
    updated_at: []const u8,
};

/// User row
pub const User = struct {
    id: []const u8,
    workspace_id: []const u8,
    name: []const u8,
    display_name: ?[]const u8,
    is_bot: bool,
};

/// Message row
pub const Message = struct {
    ts: []const u8,
    channel_id: []const u8,
    user_id: ?[]const u8,
    text: []const u8,
    thread_ts: ?[]const u8,
    reply_count: i64,
};

/// Outbox row
pub const OutboxEntry = struct {
    id: i64,
    workspace_id: []const u8,
    channel_id: []const u8,
    thread_ts: ?[]const u8,
    text: []const u8,
    created_at: []const u8,
    status: []const u8,
};

/// SQLite database wrapper for zlack persistent storage.
///
/// Pre-conditions: SQLite3 library must be linked.
/// Post-conditions: All CRUD operations maintain referential integrity
/// via SQL schema constraints.
pub const Database = struct {
    db: *c.sqlite3,
    allocator: std.mem.Allocator,

    const Self = @This();

    const create_tables_sql =
        \\CREATE TABLE IF NOT EXISTS workspaces (
        \\    id TEXT PRIMARY KEY,
        \\    name TEXT NOT NULL,
        \\    domain TEXT NOT NULL,
        \\    user_token_keychain_key TEXT NOT NULL,
        \\    app_token_keychain_key TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS channels (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT NOT NULL REFERENCES workspaces(id),
        \\    name TEXT NOT NULL,
        \\    channel_type TEXT NOT NULL DEFAULT 'public_channel',
        \\    is_member BOOLEAN DEFAULT TRUE,
        \\    last_read_ts TEXT,
        \\    updated_at TEXT NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS users (
        \\    id TEXT PRIMARY KEY,
        \\    workspace_id TEXT NOT NULL REFERENCES workspaces(id),
        \\    name TEXT NOT NULL,
        \\    display_name TEXT,
        \\    is_bot BOOLEAN DEFAULT FALSE
        \\);
        \\CREATE TABLE IF NOT EXISTS messages (
        \\    ts TEXT NOT NULL,
        \\    channel_id TEXT NOT NULL REFERENCES channels(id),
        \\    user_id TEXT,
        \\    text TEXT NOT NULL,
        \\    thread_ts TEXT,
        \\    reply_count INTEGER DEFAULT 0,
        \\    PRIMARY KEY (channel_id, ts)
        \\);
        \\CREATE TABLE IF NOT EXISTS outbox (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    workspace_id TEXT NOT NULL REFERENCES workspaces(id),
        \\    channel_id TEXT NOT NULL,
        \\    thread_ts TEXT,
        \\    text TEXT NOT NULL,
        \\    created_at TEXT NOT NULL,
        \\    status TEXT NOT NULL DEFAULT 'pending'
        \\);
    ;

    /// Open an in-memory SQLite database and create all tables.
    pub fn initInMemory(allocator: std.mem.Allocator) !Self {
        return init(allocator, ":memory:");
    }

    /// Open a file-backed SQLite database and create all tables.
    ///
    /// Pre-conditions: path is a valid filesystem path or ":memory:"
    /// Post-conditions: all 5 tables exist in DB
    pub fn init(allocator: std.mem.Allocator, path: [*:0]const u8) !Self {
        var db_ptr: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path, &db_ptr);
        if (rc != c.SQLITE_OK) {
            if (db_ptr) |p| _ = c.sqlite3_close(p);
            return error.SqliteOpenFailed;
        }
        var self = Self{
            .db = db_ptr.?,
            .allocator = allocator,
        };
        try self.createTables();
        return self;
    }

    /// Close the database connection.
    pub fn deinit(self: *Self) void {
        _ = c.sqlite3_close(self.db);
    }

    /// Create all tables using the schema DDL.
    fn createTables(self: *Self) !void {
        try self.execMulti(create_tables_sql);
    }

    /// Execute a SQL string that may contain multiple statements.
    fn execMulti(self: *Self, sql: [*:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |e| c.sqlite3_free(e);
            return error.SqliteExecFailed;
        }
    }

    /// Execute a query that returns a single integer value.
    pub fn queryScalar(self: *Self, sql: [*:0]const u8) !i64 {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const step_rc = c.sqlite3_step(stmt.?);
        if (step_rc != c.SQLITE_ROW) return error.SqliteNoRow;
        return c.sqlite3_column_int64(stmt.?, 0);
    }

    // ── Workspace CRUD ──

    pub fn insertWorkspace(self: *Self, ws: Workspace) !void {
        const sql = "INSERT INTO workspaces (id, name, domain, user_token_keychain_key, app_token_keychain_key) VALUES (?1, ?2, ?3, ?4, ?5)";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt.?, 1, ws.id);
        bindText(stmt.?, 2, ws.name);
        bindText(stmt.?, 3, ws.domain);
        bindText(stmt.?, 4, ws.user_token_keychain_key);
        bindText(stmt.?, 5, ws.app_token_keychain_key);

        const step_rc = c.sqlite3_step(stmt.?);
        if (step_rc != c.SQLITE_DONE) return error.SqliteStepFailed;
    }

    pub fn getWorkspace(self: *Self, id: []const u8) !?Workspace {
        const sql = "SELECT id, name, domain, user_token_keychain_key, app_token_keychain_key FROM workspaces WHERE id = ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt.?, 1, id);

        const step_rc = c.sqlite3_step(stmt.?);
        if (step_rc != c.SQLITE_ROW) return null;

        return Workspace{
            .id = try self.dupeColumnText(stmt.?, 0),
            .name = try self.dupeColumnText(stmt.?, 1),
            .domain = try self.dupeColumnText(stmt.?, 2),
            .user_token_keychain_key = try self.dupeColumnText(stmt.?, 3),
            .app_token_keychain_key = try self.dupeColumnText(stmt.?, 4),
        };
    }

    // ── Channel CRUD ──

    pub fn insertChannel(self: *Self, ch: Channel) !void {
        const sql = "INSERT INTO channels (id, workspace_id, name, channel_type, is_member, last_read_ts, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt.?, 1, ch.id);
        bindText(stmt.?, 2, ch.workspace_id);
        bindText(stmt.?, 3, ch.name);
        bindText(stmt.?, 4, ch.channel_type);
        bindInt(stmt.?, 5, if (ch.is_member) 1 else 0);
        bindOptionalText(stmt.?, 6, ch.last_read_ts);
        bindText(stmt.?, 7, ch.updated_at);

        const step_rc = c.sqlite3_step(stmt.?);
        if (step_rc != c.SQLITE_DONE) return error.SqliteStepFailed;
    }

    pub fn getChannelsByWorkspace(self: *Self, workspace_id: []const u8) ![]Channel {
        const sql = "SELECT id, workspace_id, name, channel_type, is_member, last_read_ts, updated_at FROM channels WHERE workspace_id = ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt.?, 1, workspace_id);

        var list: std.ArrayList(Channel) = .empty;
        errdefer list.deinit(self.allocator);

        while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
            try list.append(self.allocator, Channel{
                .id = try self.dupeColumnText(stmt.?, 0),
                .workspace_id = try self.dupeColumnText(stmt.?, 1),
                .name = try self.dupeColumnText(stmt.?, 2),
                .channel_type = try self.dupeColumnText(stmt.?, 3),
                .is_member = c.sqlite3_column_int(stmt.?, 4) != 0,
                .last_read_ts = try self.dupeColumnTextOptional(stmt.?, 5),
                .updated_at = try self.dupeColumnText(stmt.?, 6),
            });
        }

        return list.toOwnedSlice(self.allocator);
    }

    // ── User CRUD ──

    pub fn insertUser(self: *Self, user: User) !void {
        const sql = "INSERT INTO users (id, workspace_id, name, display_name, is_bot) VALUES (?1, ?2, ?3, ?4, ?5)";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt.?, 1, user.id);
        bindText(stmt.?, 2, user.workspace_id);
        bindText(stmt.?, 3, user.name);
        bindOptionalText(stmt.?, 4, user.display_name);
        bindInt(stmt.?, 5, if (user.is_bot) 1 else 0);

        const step_rc = c.sqlite3_step(stmt.?);
        if (step_rc != c.SQLITE_DONE) return error.SqliteStepFailed;
    }

    pub fn getUserById(self: *Self, user_id: []const u8) !?User {
        const sql = "SELECT id, workspace_id, name, display_name, is_bot FROM users WHERE id = ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt.?, 1, user_id);

        const step_rc = c.sqlite3_step(stmt.?);
        if (step_rc != c.SQLITE_ROW) return null;

        return User{
            .id = try self.dupeColumnText(stmt.?, 0),
            .workspace_id = try self.dupeColumnText(stmt.?, 1),
            .name = try self.dupeColumnText(stmt.?, 2),
            .display_name = try self.dupeColumnTextOptional(stmt.?, 3),
            .is_bot = c.sqlite3_column_int(stmt.?, 4) != 0,
        };
    }

    // ── Message CRUD ──

    pub fn insertMessage(self: *Self, msg: Message) !void {
        const sql = "INSERT OR REPLACE INTO messages (ts, channel_id, user_id, text, thread_ts, reply_count) VALUES (?1, ?2, ?3, ?4, ?5, ?6)";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt.?, 1, msg.ts);
        bindText(stmt.?, 2, msg.channel_id);
        bindOptionalText(stmt.?, 3, msg.user_id);
        bindText(stmt.?, 4, msg.text);
        bindOptionalText(stmt.?, 5, msg.thread_ts);
        bindInt(stmt.?, 6, msg.reply_count);

        const step_rc = c.sqlite3_step(stmt.?);
        if (step_rc != c.SQLITE_DONE) return error.SqliteStepFailed;
    }

    pub fn getMessagesByChannel(self: *Self, channel_id: []const u8) ![]Message {
        const sql = "SELECT ts, channel_id, user_id, text, thread_ts, reply_count FROM messages WHERE channel_id = ?1 ORDER BY ts DESC";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt.?, 1, channel_id);

        var list: std.ArrayList(Message) = .empty;
        errdefer list.deinit(self.allocator);

        while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
            try list.append(self.allocator, Message{
                .ts = try self.dupeColumnText(stmt.?, 0),
                .channel_id = try self.dupeColumnText(stmt.?, 1),
                .user_id = try self.dupeColumnTextOptional(stmt.?, 2),
                .text = try self.dupeColumnText(stmt.?, 3),
                .thread_ts = try self.dupeColumnTextOptional(stmt.?, 4),
                .reply_count = c.sqlite3_column_int64(stmt.?, 5),
            });
        }

        return list.toOwnedSlice(self.allocator);
    }

    // ── Outbox operations ──

    pub fn enqueueMessage(self: *Self, workspace_id: []const u8, channel_id: []const u8, thread_ts: ?[]const u8, text: []const u8) !void {
        const sql = "INSERT INTO outbox (workspace_id, channel_id, thread_ts, text, created_at, status) VALUES (?1, ?2, ?3, ?4, datetime('now'), 'pending')";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt.?, 1, workspace_id);
        bindText(stmt.?, 2, channel_id);
        bindOptionalText(stmt.?, 3, thread_ts);
        bindText(stmt.?, 4, text);

        const step_rc = c.sqlite3_step(stmt.?);
        if (step_rc != c.SQLITE_DONE) return error.SqliteStepFailed;
    }

    pub fn getPendingMessages(self: *Self) ![]OutboxEntry {
        const sql = "SELECT id, workspace_id, channel_id, thread_ts, text, created_at, status FROM outbox WHERE status = 'pending' ORDER BY id ASC";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        var list: std.ArrayList(OutboxEntry) = .empty;
        errdefer list.deinit(self.allocator);

        while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
            try list.append(self.allocator, OutboxEntry{
                .id = c.sqlite3_column_int64(stmt.?, 0),
                .workspace_id = try self.dupeColumnText(stmt.?, 1),
                .channel_id = try self.dupeColumnText(stmt.?, 2),
                .thread_ts = try self.dupeColumnTextOptional(stmt.?, 3),
                .text = try self.dupeColumnText(stmt.?, 4),
                .created_at = try self.dupeColumnText(stmt.?, 5),
                .status = try self.dupeColumnText(stmt.?, 6),
            });
        }

        return list.toOwnedSlice(self.allocator);
    }

    pub fn markAsSending(self: *Self, id: i64) !void {
        try self.updateOutboxStatus(id, "sending");
    }

    pub fn markAsFailed(self: *Self, id: i64) !void {
        try self.updateOutboxStatus(id, "failed");
    }

    pub fn deleteFromOutbox(self: *Self, id: i64) !void {
        const sql = "DELETE FROM outbox WHERE id = ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt.?, 1, id);

        const step_rc = c.sqlite3_step(stmt.?);
        if (step_rc != c.SQLITE_DONE) return error.SqliteStepFailed;
    }

    fn updateOutboxStatus(self: *Self, id: i64, status: [*:0]const u8) !void {
        const sql = "UPDATE outbox SET status = ?1 WHERE id = ?2";
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt.?, 1, status, -1, c.SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt.?, 2, id);

        const step_rc = c.sqlite3_step(stmt.?);
        if (step_rc != c.SQLITE_DONE) return error.SqliteStepFailed;
    }

    // ── Helpers ──

    fn bindText(stmt: *c.sqlite3_stmt, col: c_int, text: []const u8) void {
        _ = c.sqlite3_bind_text(stmt, col, text.ptr, @intCast(text.len), c.SQLITE_STATIC);
    }

    fn bindOptionalText(stmt: *c.sqlite3_stmt, col: c_int, text: ?[]const u8) void {
        if (text) |t| {
            _ = c.sqlite3_bind_text(stmt, col, t.ptr, @intCast(t.len), c.SQLITE_STATIC);
        } else {
            _ = c.sqlite3_bind_null(stmt, col);
        }
    }

    fn bindInt(stmt: *c.sqlite3_stmt, col: c_int, val: i64) void {
        _ = c.sqlite3_bind_int64(stmt, col, val);
    }

    fn dupeColumnText(self: *Self, stmt: *c.sqlite3_stmt, col: c_int) ![]const u8 {
        const ptr = c.sqlite3_column_text(stmt, col);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
        if (ptr == null) return error.SqliteNullText;
        return try self.allocator.dupe(u8, ptr[0..len]);
    }

    fn dupeColumnTextOptional(self: *Self, stmt: *c.sqlite3_stmt, col: c_int) !?[]const u8 {
        const ptr = c.sqlite3_column_text(stmt, col);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
        if (ptr == null) return null;
        return try self.allocator.dupe(u8, ptr[0..len]);
    }
};

// ════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "initDb creates all tables" {
    var db = try Database.initInMemory(testing.allocator);
    defer db.deinit();

    const tables = [_][]const u8{ "workspaces", "channels", "users", "messages", "outbox" };
    for (tables) |table_name| {
        var buf: [256]u8 = undefined;
        const query = try std.fmt.bufPrintZ(&buf, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='{s}'", .{table_name});
        const count = try db.queryScalar(query);
        try testing.expectEqual(@as(i64, 1), count);
    }
}

test "insertWorkspace and getWorkspace roundtrip" {
    var db = try Database.initInMemory(testing.allocator);
    defer db.deinit();

    try db.insertWorkspace(.{
        .id = "T12345",
        .name = "test-workspace",
        .domain = "test",
        .user_token_keychain_key = "zlack.user.T12345",
        .app_token_keychain_key = "zlack.app.T12345",
    });

    const ws = (try db.getWorkspace("T12345")).?;
    defer {
        testing.allocator.free(ws.id);
        testing.allocator.free(ws.name);
        testing.allocator.free(ws.domain);
        testing.allocator.free(ws.user_token_keychain_key);
        testing.allocator.free(ws.app_token_keychain_key);
    }

    try testing.expectEqualStrings("test-workspace", ws.name);
    try testing.expectEqualStrings("test", ws.domain);
    try testing.expectEqualStrings("zlack.user.T12345", ws.user_token_keychain_key);
    try testing.expectEqualStrings("zlack.app.T12345", ws.app_token_keychain_key);
}

test "getWorkspace returns null for non-existent ID" {
    var db = try Database.initInMemory(testing.allocator);
    defer db.deinit();

    const ws = try db.getWorkspace("NONEXISTENT");
    try testing.expect(ws == null);
}

test "insertChannel and getChannelsByWorkspace roundtrip" {
    var db = try Database.initInMemory(testing.allocator);
    defer db.deinit();

    try db.insertWorkspace(.{
        .id = "W1",
        .name = "ws",
        .domain = "ws",
        .user_token_keychain_key = "k1",
        .app_token_keychain_key = "k2",
    });

    try db.insertChannel(.{
        .id = "C001",
        .workspace_id = "W1",
        .name = "general",
        .channel_type = "public_channel",
        .is_member = true,
        .last_read_ts = "1700000000.000000",
        .updated_at = "2025-01-01T00:00:00Z",
    });
    try db.insertChannel(.{
        .id = "C002",
        .workspace_id = "W1",
        .name = "random",
        .channel_type = "public_channel",
        .is_member = false,
        .last_read_ts = null,
        .updated_at = "2025-01-01T00:00:00Z",
    });

    const channels = try db.getChannelsByWorkspace("W1");
    defer {
        for (channels) |ch| {
            testing.allocator.free(ch.id);
            testing.allocator.free(ch.workspace_id);
            testing.allocator.free(ch.name);
            testing.allocator.free(ch.channel_type);
            if (ch.last_read_ts) |ts| testing.allocator.free(ts);
            testing.allocator.free(ch.updated_at);
        }
        testing.allocator.free(channels);
    }

    try testing.expectEqual(@as(usize, 2), channels.len);
    try testing.expectEqualStrings("general", channels[0].name);
    try testing.expect(channels[0].is_member);
    try testing.expectEqualStrings("random", channels[1].name);
    try testing.expect(!channels[1].is_member);
    try testing.expect(channels[1].last_read_ts == null);
}

test "insertUser and getUserById roundtrip" {
    var db = try Database.initInMemory(testing.allocator);
    defer db.deinit();

    try db.insertWorkspace(.{
        .id = "W1",
        .name = "ws",
        .domain = "ws",
        .user_token_keychain_key = "k1",
        .app_token_keychain_key = "k2",
    });

    try db.insertUser(.{
        .id = "U001",
        .workspace_id = "W1",
        .name = "user_a",
        .display_name = "User A",
        .is_bot = false,
    });

    const user = (try db.getUserById("U001")).?;
    defer {
        testing.allocator.free(user.id);
        testing.allocator.free(user.workspace_id);
        testing.allocator.free(user.name);
        if (user.display_name) |dn| testing.allocator.free(dn);
    }

    try testing.expectEqualStrings("user_a", user.name);
    try testing.expectEqualStrings("User A", user.display_name.?);
    try testing.expect(!user.is_bot);
}

test "getUserById returns null for non-existent user" {
    var db = try Database.initInMemory(testing.allocator);
    defer db.deinit();

    const user = try db.getUserById("NONEXISTENT");
    try testing.expect(user == null);
}

test "insertMessage and getMessagesByChannel returns ts descending" {
    var db = try Database.initInMemory(testing.allocator);
    defer db.deinit();

    try db.insertWorkspace(.{ .id = "W1", .name = "ws", .domain = "ws", .user_token_keychain_key = "k1", .app_token_keychain_key = "k2" });
    try db.insertChannel(.{ .id = "C001", .workspace_id = "W1", .name = "general", .channel_type = "public_channel", .is_member = true, .last_read_ts = null, .updated_at = "2025-01-01" });

    try db.insertMessage(.{ .ts = "1700000001.000000", .channel_id = "C001", .user_id = "U001", .text = "hello", .thread_ts = null, .reply_count = 0 });
    try db.insertMessage(.{ .ts = "1700000003.000000", .channel_id = "C001", .user_id = "U001", .text = "world", .thread_ts = null, .reply_count = 0 });
    try db.insertMessage(.{ .ts = "1700000002.000000", .channel_id = "C001", .user_id = "U002", .text = "middle", .thread_ts = null, .reply_count = 0 });

    const msgs = try db.getMessagesByChannel("C001");
    defer {
        for (msgs) |m| {
            testing.allocator.free(m.ts);
            testing.allocator.free(m.channel_id);
            if (m.user_id) |uid| testing.allocator.free(uid);
            testing.allocator.free(m.text);
            if (m.thread_ts) |tts| testing.allocator.free(tts);
        }
        testing.allocator.free(msgs);
    }

    try testing.expectEqual(@as(usize, 3), msgs.len);
    try testing.expectEqualStrings("1700000003.000000", msgs[0].ts);
    try testing.expectEqualStrings("1700000002.000000", msgs[1].ts);
    try testing.expectEqualStrings("1700000001.000000", msgs[2].ts);
}

test "insertMessage INSERT OR REPLACE with same key does not break" {
    var db = try Database.initInMemory(testing.allocator);
    defer db.deinit();

    try db.insertWorkspace(.{ .id = "W1", .name = "ws", .domain = "ws", .user_token_keychain_key = "k1", .app_token_keychain_key = "k2" });
    try db.insertChannel(.{ .id = "C001", .workspace_id = "W1", .name = "general", .channel_type = "public_channel", .is_member = true, .last_read_ts = null, .updated_at = "2025-01-01" });

    try db.insertMessage(.{ .ts = "1700000001.000000", .channel_id = "C001", .user_id = "U001", .text = "original", .thread_ts = null, .reply_count = 0 });
    try db.insertMessage(.{ .ts = "1700000001.000000", .channel_id = "C001", .user_id = "U001", .text = "updated", .thread_ts = null, .reply_count = 2 });

    const msgs = try db.getMessagesByChannel("C001");
    defer {
        for (msgs) |m| {
            testing.allocator.free(m.ts);
            testing.allocator.free(m.channel_id);
            if (m.user_id) |uid| testing.allocator.free(uid);
            testing.allocator.free(m.text);
            if (m.thread_ts) |tts| testing.allocator.free(tts);
        }
        testing.allocator.free(msgs);
    }

    try testing.expectEqual(@as(usize, 1), msgs.len);
    try testing.expectEqualStrings("updated", msgs[0].text);
    try testing.expectEqual(@as(i64, 2), msgs[0].reply_count);
}

test "outbox: enqueue, getPending, markAsSending, markAsFailed, delete lifecycle" {
    var db = try Database.initInMemory(testing.allocator);
    defer db.deinit();

    try db.insertWorkspace(.{ .id = "W1", .name = "ws", .domain = "ws", .user_token_keychain_key = "k1", .app_token_keychain_key = "k2" });

    try db.enqueueMessage("W1", "C001", null, "hello from outbox");
    try db.enqueueMessage("W1", "C002", "1700000001.000000", "threaded reply");

    const pending = try db.getPendingMessages();
    defer {
        for (pending) |e| {
            testing.allocator.free(e.workspace_id);
            testing.allocator.free(e.channel_id);
            if (e.thread_ts) |ts| testing.allocator.free(ts);
            testing.allocator.free(e.text);
            testing.allocator.free(e.created_at);
            testing.allocator.free(e.status);
        }
        testing.allocator.free(pending);
    }

    try testing.expectEqual(@as(usize, 2), pending.len);
    try testing.expectEqualStrings("hello from outbox", pending[0].text);
    try testing.expectEqualStrings("pending", pending[0].status);
    try testing.expect(pending[0].thread_ts == null);
    try testing.expectEqualStrings("1700000001.000000", pending[1].thread_ts.?);

    const id1 = pending[0].id;
    const id2 = pending[1].id;

    // Mark first as sending
    try db.markAsSending(id1);

    // Pending should now return only second
    const pending2 = try db.getPendingMessages();
    defer {
        for (pending2) |e| {
            testing.allocator.free(e.workspace_id);
            testing.allocator.free(e.channel_id);
            if (e.thread_ts) |ts| testing.allocator.free(ts);
            testing.allocator.free(e.text);
            testing.allocator.free(e.created_at);
            testing.allocator.free(e.status);
        }
        testing.allocator.free(pending2);
    }
    try testing.expectEqual(@as(usize, 1), pending2.len);

    // Mark second as failed
    try db.markAsFailed(id2);

    // No pending left
    const pending3 = try db.getPendingMessages();
    defer testing.allocator.free(pending3);
    try testing.expectEqual(@as(usize, 0), pending3.len);

    // Delete first from outbox
    try db.deleteFromOutbox(id1);

    // Verify outbox count
    const count = try db.queryScalar("SELECT count(*) FROM outbox");
    try testing.expectEqual(@as(i64, 1), count);
}

test "getChannelsByWorkspace returns empty slice for unknown workspace" {
    var db = try Database.initInMemory(testing.allocator);
    defer db.deinit();

    const channels = try db.getChannelsByWorkspace("NONEXISTENT");
    defer testing.allocator.free(channels);
    try testing.expectEqual(@as(usize, 0), channels.len);
}

test "getMessagesByChannel returns empty slice for unknown channel" {
    var db = try Database.initInMemory(testing.allocator);
    defer db.deinit();

    const msgs = try db.getMessagesByChannel("NONEXISTENT");
    defer testing.allocator.free(msgs);
    try testing.expectEqual(@as(usize, 0), msgs.len);
}

// ── Security tests ──

test "SQL injection in workspace ID is safely parameterized" {
    var db = try Database.initInMemory(testing.allocator);
    defer db.deinit();

    const ws = try db.getWorkspace("'; DROP TABLE workspaces; --");
    try testing.expect(ws == null);

    const count = try db.queryScalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='workspaces'");
    try testing.expectEqual(@as(i64, 1), count);
}

test "SQL injection in channel workspace_id is safely parameterized" {
    var db = try Database.initInMemory(testing.allocator);
    defer db.deinit();

    const channels = try db.getChannelsByWorkspace("'; DROP TABLE channels; --");
    defer testing.allocator.free(channels);
    try testing.expectEqual(@as(usize, 0), channels.len);

    const count = try db.queryScalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='channels'");
    try testing.expectEqual(@as(i64, 1), count);
}
