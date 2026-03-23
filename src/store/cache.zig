const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Cache-local types (this module is compiled independently in test_modules)
// ---------------------------------------------------------------------------

pub const CachedChannel = struct {
    id: []const u8,
    name: []const u8,
    is_member: bool,
    channel_type: []const u8, // "public_channel" or "private_channel"
};

pub const CachedUser = struct {
    id: []const u8,
    name: []const u8,
    display_name: ?[]const u8,
};

pub const CachedMessage = struct {
    ts: []const u8,
    user_id: ?[]const u8,
    text: []const u8,
    thread_ts: ?[]const u8,
    reply_count: u32,
    file_name: ?[]const u8 = null,
    file_url: ?[]const u8 = null,
    file_size: u64 = 0,
};

// ---------------------------------------------------------------------------
// Map / List type aliases
// ---------------------------------------------------------------------------

const ChannelMap = std.StringArrayHashMapUnmanaged(CachedChannel);
const UserMap = std.StringArrayHashMapUnmanaged(CachedUser);
const MessageList = std.ArrayListUnmanaged(CachedMessage);
const MessageMap = std.StringArrayHashMapUnmanaged(MessageList);

// ---------------------------------------------------------------------------
// Cache
// ---------------------------------------------------------------------------

/// Thread-safe in-memory cache for channels, users, and messages.
pub const Cache = struct {
    mutex: std.Thread.Mutex,
    allocator: Allocator,
    channels: ChannelMap,
    users: UserMap,
    messages: MessageMap,

    /// Create a new empty cache.
    pub fn init(allocator: Allocator) Cache {
        return .{
            .mutex = .{},
            .allocator = allocator,
            .channels = ChannelMap{},
            .users = UserMap{},
            .messages = MessageMap{},
        };
    }

    /// Free all owned memory.
    pub fn deinit(self: *Cache) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.clearChannels();
        self.channels.deinit(self.allocator);

        self.clearUsers();
        self.users.deinit(self.allocator);

        self.clearMessages();
        self.messages.deinit(self.allocator);
    }

    // -- Channels -----------------------------------------------------------

    /// Replace all cached channels with the given slice.
    pub fn updateChannels(self: *Cache, channels: []const CachedChannel) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.clearChannels();

        for (channels) |ch| {
            const id_owned = self.allocator.dupe(u8, ch.id) catch return;
            const name_owned = self.allocator.dupe(u8, ch.name) catch return;
            const type_owned = self.allocator.dupe(u8, ch.channel_type) catch return;
            const owned = CachedChannel{
                .id = id_owned,
                .name = name_owned,
                .is_member = ch.is_member,
                .channel_type = type_owned,
            };
            self.channels.put(self.allocator, id_owned, owned) catch return;
        }
    }

    /// Return all cached channels. Caller must NOT free the returned slice
    /// (it is owned by the cache). The backing memory for the returned slice
    /// is allocated via `self.allocator` and must be freed by the caller.
    pub fn getChannels(self: *Cache) []const CachedChannel {
        self.mutex.lock();
        defer self.mutex.unlock();

        const values = self.channels.values();
        const result = self.allocator.alloc(CachedChannel, values.len) catch return &.{};
        @memcpy(result, values);
        return result;
    }

    // -- Users --------------------------------------------------------------

    /// Replace all cached users with the given slice.
    pub fn updateUsers(self: *Cache, users: []const CachedUser) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.clearUsers();

        for (users) |u| {
            const id_owned = self.allocator.dupe(u8, u.id) catch return;
            const name_owned = self.allocator.dupe(u8, u.name) catch return;
            const dn_owned: ?[]const u8 = if (u.display_name) |dn|
                self.allocator.dupe(u8, dn) catch return
            else
                null;
            const owned = CachedUser{
                .id = id_owned,
                .name = name_owned,
                .display_name = dn_owned,
            };
            self.users.put(self.allocator, id_owned, owned) catch return;
        }
    }

    /// Look up a user's display name (or name) by user_id.
    /// Returns null if the user is not cached.
    pub fn getUserName(self: *Cache, user_id: []const u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const user = self.users.get(user_id) orelse return null;
        return user.display_name orelse user.name;
    }

    /// Reverse lookup: find user ID by name or display_name (case-sensitive).
    pub fn getUserIdByName(self: *Cache, name: []const u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.users.values()) |user| {
            if (user.display_name) |dn| {
                if (std.mem.eql(u8, dn, name)) return user.id;
            }
            if (std.mem.eql(u8, user.name, name)) return user.id;
        }
        return null;
    }

    // -- Messages -----------------------------------------------------------

    /// Append a message to the cache for the given channel.
    /// Messages are kept sorted by ts (ascending) after insertion.
    pub fn addMessage(self: *Cache, channel_id: []const u8, msg: CachedMessage) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const duped_key = self.allocator.dupe(u8, channel_id) catch return;
        const gop = self.messages.getOrPut(self.allocator, duped_key) catch {
            self.allocator.free(duped_key);
            return;
        };
        if (!gop.found_existing) {
            gop.value_ptr.* = MessageList{};
        } else {
            // Key already exists; free the duplicate we created.
            self.allocator.free(duped_key);
        }

        const ts_owned = self.allocator.dupe(u8, msg.ts) catch return;
        const text_owned = self.allocator.dupe(u8, msg.text) catch return;
        const uid_owned: ?[]const u8 = if (msg.user_id) |uid|
            self.allocator.dupe(u8, uid) catch return
        else
            null;
        const tts_owned: ?[]const u8 = if (msg.thread_ts) |tts|
            self.allocator.dupe(u8, tts) catch return
        else
            null;

        const fn_owned: ?[]const u8 = if (msg.file_name) |fn_| self.allocator.dupe(u8, fn_) catch null else null;
        const fu_owned: ?[]const u8 = if (msg.file_url) |fu| self.allocator.dupe(u8, fu) catch null else null;

        const owned = CachedMessage{
            .ts = ts_owned,
            .user_id = uid_owned,
            .text = text_owned,
            .thread_ts = tts_owned,
            .reply_count = msg.reply_count,
            .file_name = fn_owned,
            .file_url = fu_owned,
            .file_size = msg.file_size,
        };

        gop.value_ptr.append(self.allocator, owned) catch return;

        // Sort by ts ascending
        std.mem.sort(CachedMessage, gop.value_ptr.items, {}, struct {
            fn lessThan(_: void, a: CachedMessage, b: CachedMessage) bool {
                return std.mem.order(u8, a.ts, b.ts) == .lt;
            }
        }.lessThan);
    }

    /// Clear all cached messages for a specific channel.
    pub fn clearChannelMessages(self: *Cache, channel_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.messages.getPtr(channel_id)) |list| {
            for (list.items) |msg| {
                self.allocator.free(msg.ts);
                self.allocator.free(msg.text);
                if (msg.user_id) |uid| self.allocator.free(uid);
                if (msg.thread_ts) |tts| self.allocator.free(tts);
                if (msg.file_name) |fn_| self.allocator.free(fn_);
                if (msg.file_url) |fu| self.allocator.free(fu);
            }
            list.clearRetainingCapacity();
        }
    }

    /// Get all messages for a channel, sorted by ts ascending.
    /// Returns null if no messages exist for the channel.
    pub fn getMessages(self: *Cache, channel_id: []const u8) ?[]const CachedMessage {
        self.mutex.lock();
        defer self.mutex.unlock();

        const list = self.messages.get(channel_id) orelse return null;
        if (list.items.len == 0) return null;
        return list.items;
    }

    // -- Internal helpers (must be called with mutex held) ------------------

    fn clearChannels(self: *Cache) void {
        for (self.channels.keys(), self.channels.values()) |key, val| {
            // id is the same allocation as key
            self.allocator.free(val.name);
            self.allocator.free(val.channel_type);
            self.allocator.free(key);
        }
        self.channels.clearRetainingCapacity();
    }

    fn clearUsers(self: *Cache) void {
        for (self.users.keys(), self.users.values()) |key, val| {
            self.allocator.free(val.name);
            if (val.display_name) |dn| self.allocator.free(dn);
            self.allocator.free(key);
        }
        self.users.clearRetainingCapacity();
    }

    fn clearMessages(self: *Cache) void {
        for (self.messages.keys(), self.messages.values()) |key, *list| {
            for (list.items) |msg| {
                self.allocator.free(msg.ts);
                self.allocator.free(msg.text);
                if (msg.user_id) |uid| self.allocator.free(uid);
                if (msg.thread_ts) |tts| self.allocator.free(tts);
                if (msg.file_name) |fn_| self.allocator.free(fn_);
                if (msg.file_url) |fu| self.allocator.free(fu);
            }
            list.deinit(self.allocator);
            self.allocator.free(key);
        }
        self.messages.clearRetainingCapacity();
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "updateChannels and getChannels roundtrip" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    const channels = [_]CachedChannel{
        .{ .id = "C001", .name = "general", .is_member = true, .channel_type = "public_channel" },
        .{ .id = "C002", .name = "random", .is_member = false, .channel_type = "public_channel" },
    };
    cache.updateChannels(&channels);

    const result = cache.getChannels();
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 2), result.len);

    // Verify we can find both channels
    var found_general = false;
    var found_random = false;
    for (result) |ch| {
        if (std.mem.eql(u8, ch.name, "general")) found_general = true;
        if (std.mem.eql(u8, ch.name, "random")) found_random = true;
    }
    try std.testing.expect(found_general);
    try std.testing.expect(found_random);
}

test "updateChannels replaces existing" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    const v1 = [_]CachedChannel{
        .{ .id = "C001", .name = "general", .is_member = true, .channel_type = "public_channel" },
        .{ .id = "C002", .name = "random", .is_member = false, .channel_type = "public_channel" },
    };
    cache.updateChannels(&v1);

    // Replace with a single channel
    const v2 = [_]CachedChannel{
        .{ .id = "C003", .name = "dev", .is_member = true, .channel_type = "private_channel" },
    };
    cache.updateChannels(&v2);

    const result = cache.getChannels();
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(std.mem.eql(u8, result[0].name, "dev"));
    try std.testing.expect(std.mem.eql(u8, result[0].channel_type, "private_channel"));
}

test "addMessage and getMessages returns sorted by ts" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    // Add messages in non-sorted order
    cache.addMessage("C001", .{ .ts = "1700000003.000000", .user_id = "U001", .text = "third", .thread_ts = null, .reply_count = 0 });
    cache.addMessage("C001", .{ .ts = "1700000001.000000", .user_id = "U001", .text = "first", .thread_ts = null, .reply_count = 0 });
    cache.addMessage("C001", .{ .ts = "1700000002.000000", .user_id = "U002", .text = "second", .thread_ts = null, .reply_count = 0 });

    const msgs = cache.getMessages("C001") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), msgs.len);

    // Verify ascending ts order
    try std.testing.expect(std.mem.eql(u8, msgs[0].text, "first"));
    try std.testing.expect(std.mem.eql(u8, msgs[1].text, "second"));
    try std.testing.expect(std.mem.eql(u8, msgs[2].text, "third"));
}

test "getUserName returns null for unknown user" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), cache.getUserName("U_UNKNOWN"));
}

test "getUserName returns display_name when available" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    const users = [_]CachedUser{
        .{ .id = "U001", .name = "john.doe", .display_name = "John" },
        .{ .id = "U002", .name = "jane.doe", .display_name = null },
    };
    cache.updateUsers(&users);

    const name1 = cache.getUserName("U001") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.eql(u8, name1, "John"));

    const name2 = cache.getUserName("U002") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.eql(u8, name2, "jane.doe"));
}

test "getMessages returns null for unknown channel" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    try std.testing.expectEqual(@as(?[]const CachedMessage, null), cache.getMessages("C_UNKNOWN"));
}

test "updateUsers replaces existing" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    const v1 = [_]CachedUser{
        .{ .id = "U001", .name = "alice", .display_name = "Alice" },
    };
    cache.updateUsers(&v1);

    const v2 = [_]CachedUser{
        .{ .id = "U002", .name = "bob", .display_name = null },
    };
    cache.updateUsers(&v2);

    // Old user should be gone
    try std.testing.expectEqual(@as(?[]const u8, null), cache.getUserName("U001"));
    // New user should exist
    const name = cache.getUserName("U002") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.eql(u8, name, "bob"));
}

test "getUserIdByName matches display_name" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    const users = [_]CachedUser{
        .{ .id = "U001", .name = "john.doe", .display_name = "John" },
        .{ .id = "U002", .name = "jane.doe", .display_name = "Jane" },
    };
    cache.updateUsers(&users);

    const id = cache.getUserIdByName("John") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.eql(u8, id, "U001"));
}

test "getUserIdByName matches name when no display_name" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    const users = [_]CachedUser{
        .{ .id = "U001", .name = "john.doe", .display_name = null },
    };
    cache.updateUsers(&users);

    const id = cache.getUserIdByName("john.doe") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.eql(u8, id, "U001"));
}

test "getUserIdByName returns null for unknown" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    const users = [_]CachedUser{
        .{ .id = "U001", .name = "john.doe", .display_name = "John" },
    };
    cache.updateUsers(&users);

    try std.testing.expectEqual(@as(?[]const u8, null), cache.getUserIdByName("nobody"));
}

test "getUserIdByName prefers display_name over name" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    const users = [_]CachedUser{
        .{ .id = "U001", .name = "john.doe", .display_name = "John" },
    };
    cache.updateUsers(&users);

    // Should match display_name
    try std.testing.expect(cache.getUserIdByName("John") != null);
    // Should also match name
    try std.testing.expect(cache.getUserIdByName("john.doe") != null);
}

test "addMessage to multiple channels" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    cache.addMessage("C001", .{ .ts = "1700000001.000000", .user_id = "U001", .text = "hello", .thread_ts = null, .reply_count = 0 });
    cache.addMessage("C002", .{ .ts = "1700000002.000000", .user_id = "U002", .text = "world", .thread_ts = null, .reply_count = 0 });

    const msgs1 = cache.getMessages("C001") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), msgs1.len);
    try std.testing.expect(std.mem.eql(u8, msgs1[0].text, "hello"));

    const msgs2 = cache.getMessages("C002") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), msgs2.len);
    try std.testing.expect(std.mem.eql(u8, msgs2[0].text, "world"));
}
