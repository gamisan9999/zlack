const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});
const vaxis = @import("vaxis");
const Window = vaxis.Window;
const Key = vaxis.Key;
const Cell = vaxis.Cell;

/// Message display pane widget.
/// Renders a list of messages with user name, timestamp, and text.
pub const Messages = struct {
    messages: []const MessageEntry = &.{},
    selected_idx: usize = 0,
    scroll_offset: usize = 0,
    channel_id: []const u8 = "",

    pub const MessageEntry = struct {
        ts: []const u8,
        user_name: []const u8,
        text: []const u8,
        thread_ts: ?[]const u8 = null,
        reply_count: u32 = 0,
    };

    pub const Action = union(enum) {
        open_thread: struct { channel_id: []const u8, thread_ts: []const u8 },
        none,
    };

    pub fn init() Messages {
        return .{};
    }

    pub fn setMessages(self: *Messages, msgs: []const MessageEntry) void {
        self.messages = msgs;
        // Jump to latest message (bottom), same as Slack desktop
        self.selected_idx = if (msgs.len > 0) msgs.len - 1 else 0;
        self.scroll_offset = 0;
    }

    /// Handle key input. Returns an action if a thread was opened.
    pub fn handleInput(self: *Messages, key: Key) ?Action {
        if (self.messages.len == 0) return .none;

        // j / down: move selection down
        if (key.matches('j', .{}) or key.matches(Key.down, .{})) {
            if (self.selected_idx + 1 < self.messages.len) {
                self.selected_idx += 1;
            }
            return .none;
        }
        // k / up: move selection up
        if (key.matches('k', .{}) or key.matches(Key.up, .{})) {
            if (self.selected_idx > 0) {
                self.selected_idx -= 1;
            }
            return .none;
        }
        // Ctrl+F: page down
        if (key.matches('f', .{ .ctrl = true })) {
            const page: usize = if (self.messages.len > 10) 10 else self.messages.len;
            self.selected_idx = @min(self.selected_idx + page, self.messages.len - 1);
            return .none;
        }
        // Ctrl+B: page up
        if (key.matches('b', .{ .ctrl = true })) {
            const page: usize = 10;
            self.selected_idx = if (self.selected_idx > page) self.selected_idx - page else 0;
            return .none;
        }
        // Enter: open thread for selected message
        if (key.matches(Key.enter, .{})) {
            const msg = self.messages[self.selected_idx];
            // Use thread_ts if it's a reply, otherwise use ts as thread parent
            const tts = msg.thread_ts orelse msg.ts;
            return .{ .open_thread = .{ .channel_id = self.channel_id, .thread_ts = tts } };
        }
        return null;
    }

    /// Convert Slack ts ("1773282759.367279") to "YYYY-MM-DD HH:MM:SS" in local timezone.
    fn formatSlackTs(ts: []const u8, buf: *[20]u8) []const u8 {
        // Parse integer part before '.'
        const dot_pos = std.mem.indexOfScalar(u8, ts, '.') orelse ts.len;
        const epoch = std.fmt.parseInt(i64, ts[0..dot_pos], 10) catch return ts;

        var time_val: c.time_t = @intCast(epoch);
        var tm: c.struct_tm = undefined;
        if (c.localtime_r(&time_val, &tm) == null) return ts;

        const result = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            @as(u32, @intCast(tm.tm_year + 1900)),
            @as(u32, @intCast(tm.tm_mon + 1)),
            @as(u32, @intCast(tm.tm_mday)),
            @as(u32, @intCast(tm.tm_hour)),
            @as(u32, @intCast(tm.tm_min)),
            @as(u32, @intCast(tm.tm_sec)),
        }) catch return ts;
        return result;
    }

    /// Render messages into the given window.
    pub fn render(self: *Messages, win: Window) void {
        win.clear();

        if (self.messages.len == 0) {
            _ = win.printSegment(.{ .text = "No messages", .style = .{ .dim = true } }, .{});
            return;
        }

        // Adjust scroll offset
        var scroll = self.scroll_offset;
        const visible_rows: usize = win.height;
        if (visible_rows == 0) return;

        // Each message takes ~2 rows (header + text). Simplified: use selected_idx directly.
        if (self.selected_idx < scroll) {
            scroll = self.selected_idx;
        } else if (self.selected_idx >= scroll + visible_rows / 2) {
            scroll = self.selected_idx -| (visible_rows / 2) + 1;
        }
        self.scroll_offset = scroll;

        var row: u16 = 0;
        for (self.messages[scroll..], 0..) |msg, i| {
            if (row >= win.height) break;

            const is_selected = (scroll + i) == self.selected_idx;
            const name_style: Cell.Style = if (is_selected)
                .{ .bold = true, .reverse = true }
            else
                .{ .bold = true };
            const text_style: Cell.Style = if (is_selected)
                .{ .reverse = true }
            else
                .{};

            // Header line: user_name  YYYY-MM-DD HH:MM:SS
            var time_buf: [20]u8 = undefined;
            const time_str = formatSlackTs(msg.ts, &time_buf);
            _ = win.print(&.{
                .{ .text = msg.user_name, .style = name_style },
                .{ .text = "  ", .style = text_style },
                .{ .text = time_str, .style = .{ .dim = true } },
            }, .{ .row_offset = row });
            row += 1;

            if (row >= win.height) break;

            // Text line
            _ = win.printSegment(.{ .text = msg.text, .style = text_style }, .{ .row_offset = row, .wrap = .word });
            row += 1;

            if (row >= win.height) break;

            // Thread indicator
            if (msg.reply_count > 0) {
                var buf: [32]u8 = undefined;
                const thread_text = std.fmt.bufPrint(&buf, "[{d} replies]", .{msg.reply_count}) catch "[replies]";
                _ = win.printSegment(.{ .text = thread_text, .style = .{ .fg = .{ .index = 6 }, .italic = true } }, .{ .row_offset = row });
                row += 1;
            }
        }
    }
};

// ===========================================================================
// Tests
// ===========================================================================

test "formatSlackTs valid epoch" {
    var buf: [20]u8 = undefined;
    const result = Messages.formatSlackTs("0.000000", &buf);
    // Epoch 0 = 1970-01-01 in UTC (local offset may vary)
    try std.testing.expect(result.len == 19); // "YYYY-MM-DD HH:MM:SS"
    try std.testing.expect(result[4] == '-');
    try std.testing.expect(result[7] == '-');
    try std.testing.expect(result[10] == ' ');
    try std.testing.expect(result[13] == ':');
    try std.testing.expect(result[16] == ':');
}

test "formatSlackTs with decimal part" {
    var buf: [20]u8 = undefined;
    const result = Messages.formatSlackTs("1700000000.123456", &buf);
    try std.testing.expect(result.len == 19);
    // 2023-11-14 in UTC
    try std.testing.expect(std.mem.startsWith(u8, result, "2023-11-1"));
}

test "formatSlackTs invalid returns original" {
    var buf: [20]u8 = undefined;
    const result = Messages.formatSlackTs("not_a_number", &buf);
    try std.testing.expectEqualStrings("not_a_number", result);
}

test "formatSlackTs empty string returns original" {
    var buf: [20]u8 = undefined;
    const result = Messages.formatSlackTs("", &buf);
    try std.testing.expectEqualStrings("", result);
}

test "formatSlackTs no dot" {
    var buf: [20]u8 = undefined;
    const result = Messages.formatSlackTs("1700000000", &buf);
    try std.testing.expect(result.len == 19);
}

test "formatSlackTs_XSS_injection" {
    // Security: ensure script tags in ts are not parsed as epoch
    var buf: [20]u8 = undefined;
    const result = Messages.formatSlackTs("<script>alert(1)</script>", &buf);
    // Should return original since it can't parse
    try std.testing.expectEqualStrings("<script>alert(1)</script>", result);
}

test "formatSlackTs_PathTraversal" {
    var buf: [20]u8 = undefined;
    const result = Messages.formatSlackTs("../../etc/passwd", &buf);
    try std.testing.expectEqualStrings("../../etc/passwd", result);
}
