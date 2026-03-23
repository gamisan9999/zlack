const std = @import("std");
const Allocator = std.mem.Allocator;
const websocket = @import("websocket");

// ---------------------------------------------------------------------------
// Event types — Socket Mode events pushed from Slack
// ---------------------------------------------------------------------------

pub const MessageEvent = struct {
    channel_id: []const u8,
    ts: []const u8,
    user: ?[]const u8,
    text: []const u8,
    thread_ts: ?[]const u8,
};

pub const ChannelMarkedEvent = struct {
    channel_id: []const u8,
    ts: []const u8,
};

pub const Event = union(enum) {
    message: MessageEvent,
    channel_marked: ChannelMarkedEvent,
    reconnect_requested: void,
    error_event: []const u8,
};

// ---------------------------------------------------------------------------
// EventQueue — thread-safe ring buffer
// ---------------------------------------------------------------------------

pub const EventQueue = struct {
    const CAPACITY = 512;

    buffer: [CAPACITY]?Event,
    write_idx: usize,
    read_idx: usize,
    count: usize,
    mutex: std.Thread.Mutex,

    /// Initialize a new EventQueue with all slots empty.
    pub fn init() EventQueue {
        return .{
            .buffer = [_]?Event{null} ** CAPACITY,
            .write_idx = 0,
            .read_idx = 0,
            .count = 0,
            .mutex = .{},
        };
    }

    /// Push an event into the queue. If the queue is full, the oldest event
    /// is silently dropped (overwritten).
    pub fn push(self: *EventQueue, event: Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.buffer[self.write_idx] = event;
        self.write_idx = (self.write_idx + 1) % CAPACITY;

        if (self.count == CAPACITY) {
            // Queue was full — overwrite oldest, advance read
            self.read_idx = (self.read_idx + 1) % CAPACITY;
        } else {
            self.count += 1;
        }
    }

    /// Pop the oldest event from the queue, or return null if empty.
    pub fn pop(self: *EventQueue) ?Event {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.count == 0) return null;

        const event = self.buffer[self.read_idx];
        self.buffer[self.read_idx] = null;
        self.read_idx = (self.read_idx + 1) % CAPACITY;
        self.count -= 1;
        return event;
    }
};

// ---------------------------------------------------------------------------
// Backoff calculation — pure function
// ---------------------------------------------------------------------------

/// Calculate exponential backoff in milliseconds: 1000 * 2^attempt, capped at 30000.
///
/// Pre-condition: attempt >= 0
/// Post-condition: return value in [1000, 30000]
pub fn calculateBackoff(attempt: u32) u64 {
    const base: u64 = 1000;
    const max_backoff: u64 = 30000;
    const shift: u6 = @intCast(@min(attempt, 63));
    const value = base *| (@as(u64, 1) << shift);
    return @min(value, max_backoff);
}

// ---------------------------------------------------------------------------
// SocketClient — wraps websocket.Client + EventQueue
// ---------------------------------------------------------------------------

pub const SocketClient = struct {
    allocator: Allocator,
    event_queue: *EventQueue,
    ws_client: ?websocket.Client = null,
    running: bool = false,

    /// URL refresh callback type: called to obtain a fresh wss:// URL when
    /// reconnection is needed. Returns the URL or an error.
    pub const UrlRefreshFn = *const fn () error{RefreshFailed}![]const u8;

    pub fn init(allocator: Allocator, event_queue: *EventQueue) SocketClient {
        return .{
            .allocator = allocator,
            .event_queue = event_queue,
        };
    }

    /// Connect to a wss:// URL. Parses host/path from the URL and establishes
    /// the WebSocket handshake.
    pub fn connect(self: *SocketClient, wss_url: []const u8) !void {
        const uri = try std.Uri.parse(wss_url);

        const host_component = uri.host orelse return error.InvalidUrl;
        const host = switch (host_component) {
            .raw => |r| r,
            .percent_encoded => |p| p,
        };

        const scheme = uri.scheme;
        const is_tls = std.mem.eql(u8, scheme, "wss") or std.mem.eql(u8, scheme, "https");
        const port: u16 = if (uri.port) |p| p else if (is_tls) 443 else 80;

        var client = try websocket.Client.init(self.allocator, .{
            .host = host,
            .port = port,
            .tls = is_tls,
        });

        const path = if (uri.path.isEmpty())
            "/"
        else switch (uri.path) {
            .raw => |r| r,
            .percent_encoded => |p| p,
        };

        try client.handshake(path, .{});
        self.ws_client = client;
        self.running = true;
    }

    /// Start the read loop in a dedicated thread. The thread reads WebSocket
    /// messages, parses them into Event values, and pushes them to the queue.
    pub fn startReadLoop(self: *SocketClient) !std.Thread {
        return std.Thread.spawn(.{}, readLoopThread, .{self});
    }

    fn readLoopThread(self: *SocketClient) void {
        var client = &(self.ws_client orelse return);
        while (self.running) {
            const maybe_msg = client.read() catch |err| {
                switch (err) {
                    error.Closed => {
                        self.event_queue.push(.{ .reconnect_requested = {} });
                        return;
                    },
                    else => {
                        self.event_queue.push(.{ .error_event = "websocket read error" });
                        return;
                    },
                }
            };
            const msg = maybe_msg orelse continue;
            defer client.done(msg);

            // Handle ping frames — respond with pong
            if (msg.type == .ping) {
                client.writePong(@constCast(msg.data)) catch {};
                continue;
            }

            // Parse and handle text messages
            self.handleMessage(client, msg.data) catch |err| {
                _ = err;
                self.event_queue.push(.{ .error_event = "message parse error" });
            };
        }
    }

    fn handleMessage(self: *SocketClient, client: *websocket.Client, data: []const u8) !void {
        // Parse the outer envelope. Socket Mode messages have a "type" field
        // and a nested "payload" with an inner "event".
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch {
            self.event_queue.push(.{ .error_event = "json parse error" });
            return;
        };
        defer parsed.deinit();

        const root = parsed.value.object;

        // ACK: Send envelope_id back to Slack (required for all envelope messages)
        if (getStr(root, "envelope_id")) |envelope_id| {
            var ack_buf: [256]u8 = undefined;
            const ack = std.fmt.bufPrint(&ack_buf, "{{\"envelope_id\":\"{s}\"}}", .{envelope_id}) catch null;
            if (ack) |ack_msg| {
                client.writeText(@constCast(ack_msg)) catch {};
            }
        }

        // Extract top-level type
        const type_val = root.get("type") orelse return;
        const type_str = switch (type_val) {
            .string => |s| s,
            else => return,
        };

        if (std.mem.eql(u8, type_str, "disconnect")) {
            self.event_queue.push(.{ .reconnect_requested = {} });
            return;
        }

        // For events_api envelope, drill into payload.event
        if (std.mem.eql(u8, type_str, "events_api")) {
            const payload = root.get("payload") orelse return;
            const payload_obj = switch (payload) {
                .object => |o| o,
                else => return,
            };
            const inner_event = payload_obj.get("event") orelse return;
            const event_obj = switch (inner_event) {
                .object => |o| o,
                else => return,
            };

            const event_type_val = event_obj.get("type") orelse return;
            const event_type = switch (event_type_val) {
                .string => |s| s,
                else => return,
            };

            if (std.mem.eql(u8, event_type, "message")) {
                self.event_queue.push(.{ .message = .{
                    .channel_id = getStr(event_obj, "channel") orelse return,
                    .ts = getStr(event_obj, "ts") orelse return,
                    .user = getStr(event_obj, "user"),
                    .text = getStr(event_obj, "text") orelse return,
                    .thread_ts = getStr(event_obj, "thread_ts"),
                } });
            } else if (std.mem.eql(u8, event_type, "channel_marked")) {
                self.event_queue.push(.{ .channel_marked = .{
                    .channel_id = getStr(event_obj, "channel") orelse return,
                    .ts = getStr(event_obj, "ts") orelse return,
                } });
            }
        }
    }

    fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        const val = obj.get(key) orelse return null;
        return switch (val) {
            .string => |s| s,
            else => null,
        };
    }

    /// Disconnect and clean up the WebSocket connection.
    pub fn disconnect(self: *SocketClient) void {
        self.running = false;
        if (self.ws_client) |*client| {
            client.deinit();
            self.ws_client = null;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "EventQueue single-thread push/pop" {
    var q = EventQueue.init();

    // Push 3 events
    q.push(.{ .message = .{
        .channel_id = "C1",
        .ts = "1.0",
        .user = "U1",
        .text = "hello",
        .thread_ts = null,
    } });
    q.push(.{ .reconnect_requested = {} });
    q.push(.{ .error_event = "oops" });

    // Pop 3 events, verify FIFO order
    const e1 = q.pop().?;
    switch (e1) {
        .message => |m| {
            try std.testing.expectEqualStrings("C1", m.channel_id);
            try std.testing.expectEqualStrings("hello", m.text);
        },
        else => return error.TestUnexpectedResult,
    }

    const e2 = q.pop().?;
    try std.testing.expect(e2 == .reconnect_requested);

    const e3 = q.pop().?;
    switch (e3) {
        .error_event => |msg| try std.testing.expectEqualStrings("oops", msg),
        else => return error.TestUnexpectedResult,
    }
}

test "EventQueue empty pop returns null" {
    var q = EventQueue.init();
    try std.testing.expect(q.pop() == null);
}

test "EventQueue overflow drops oldest" {
    var q = EventQueue.init();

    // Fill to capacity + 1
    for (0..EventQueue.CAPACITY + 1) |i| {
        q.push(.{ .channel_marked = .{
            .channel_id = "C0",
            .ts = if (i == 0) "first" else if (i == EventQueue.CAPACITY) "last" else "mid",
        } });
    }

    // Should be able to pop exactly CAPACITY events (oldest was dropped)
    var count: usize = 0;
    var first_ts: ?[]const u8 = null;
    var last_ts: ?[]const u8 = null;
    while (q.pop()) |ev| {
        switch (ev) {
            .channel_marked => |cm| {
                if (first_ts == null) first_ts = cm.ts;
                last_ts = cm.ts;
            },
            else => {},
        }
        count += 1;
    }

    // CAPACITY events remain (the very first "first" was overwritten)
    try std.testing.expectEqual(EventQueue.CAPACITY, count);
    // The first popped should NOT be the original "first" (it was dropped)
    try std.testing.expect(!std.mem.eql(u8, first_ts.?, "first"));
    // The last should be "last"
    try std.testing.expectEqualStrings("last", last_ts.?);
}

test "EventQueue two-thread concurrent push" {
    var q = EventQueue.init();

    const push_count = 200;

    const Worker = struct {
        fn run(queue: *EventQueue, tag: Event) void {
            for (0..push_count) |_| {
                queue.push(tag);
            }
        }
    };

    const t1 = try std.Thread.spawn(.{}, Worker.run, .{ &q, Event{ .reconnect_requested = {} } });
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{ &q, Event{ .error_event = "t2" } });

    t1.join();
    t2.join();

    // Pop all — should get exactly push_count * 2 events (well within CAPACITY)
    var total: usize = 0;
    while (q.pop() != null) {
        total += 1;
    }
    try std.testing.expectEqual(push_count * 2, total);
}

test "calculateBackoff values" {
    try std.testing.expectEqual(@as(u64, 1000), calculateBackoff(0));
    try std.testing.expectEqual(@as(u64, 2000), calculateBackoff(1));
    try std.testing.expectEqual(@as(u64, 4000), calculateBackoff(2));
    try std.testing.expectEqual(@as(u64, 8000), calculateBackoff(3));
    try std.testing.expectEqual(@as(u64, 16000), calculateBackoff(4));
    try std.testing.expectEqual(@as(u64, 30000), calculateBackoff(5)); // capped
    try std.testing.expectEqual(@as(u64, 30000), calculateBackoff(6)); // still capped
    try std.testing.expectEqual(@as(u64, 30000), calculateBackoff(100)); // extreme
}
