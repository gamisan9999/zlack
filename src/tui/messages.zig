const std = @import("std");
const vaxis = @import("vaxis");
const time_fmt = @import("../time_fmt.zig");
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

    pub const FileInfo = struct {
        name: []const u8,
        url: []const u8,
        size: u64 = 0,
    };

    pub const MessageEntry = struct {
        ts: []const u8,
        user_name: []const u8,
        text: []const u8,
        thread_ts: ?[]const u8 = null,
        reply_count: u32 = 0,
        file: ?FileInfo = null,
    };

    pub const Action = union(enum) {
        open_thread: struct { channel_id: []const u8, thread_ts: []const u8 },
        download_file: FileInfo,
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
        // Ctrl+D: download file from selected message
        if (key.matches('d', .{ .ctrl = true })) {
            const msg = self.messages[self.selected_idx];
            if (msg.file) |file| {
                return .{ .download_file = file };
            }
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
            const time_str = time_fmt.formatSlackTs(msg.ts, &time_buf);
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

            // File attachment indicator
            if (msg.file) |file| {
                if (row < win.height) {
                    var size_buf: [32]u8 = undefined;
                    const size_str = if (file.size >= 1024 * 1024)
                        std.fmt.bufPrint(&size_buf, " ({d}MB)", .{file.size / (1024 * 1024)}) catch ""
                    else if (file.size >= 1024)
                        std.fmt.bufPrint(&size_buf, " ({d}KB)", .{file.size / 1024}) catch ""
                    else if (file.size > 0)
                        std.fmt.bufPrint(&size_buf, " ({d}B)", .{file.size}) catch ""
                    else
                        "";
                    _ = win.print(&.{
                        .{ .text = "  [Ctrl+D] ", .style = .{ .fg = .{ .index = 3 }, .dim = true } },
                        .{ .text = file.name, .style = .{ .fg = .{ .index = 3 } } },
                        .{ .text = size_str, .style = .{ .fg = .{ .index = 3 }, .dim = true } },
                    }, .{ .row_offset = row });
                    row += 1;
                }
            }

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

// formatSlackTs tests are in src/time_fmt.zig
