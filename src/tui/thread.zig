const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});
const vaxis = @import("vaxis");
const Window = vaxis.Window;
const Key = vaxis.Key;
const Cell = vaxis.Cell;
const MessageEntry = @import("messages.zig").Messages.MessageEntry;

/// Thread display pane widget.
/// Shows parent message as header and replies chronologically.
pub const Thread = struct {
    visible: bool = false,
    parent_msg: ?MessageEntry = null,
    replies: []const MessageEntry = &.{},
    scroll_offset: usize = 0,
    selected_idx: usize = 0,

    pub const Action = union(enum) {
        close,
        none,
    };

    pub fn init() Thread {
        return .{};
    }

    pub fn show(self: *Thread, parent: MessageEntry, replies: []const MessageEntry) void {
        self.visible = true;
        self.parent_msg = parent;
        self.replies = replies;
        self.scroll_offset = 0;
        self.selected_idx = 0;
    }

    pub fn hide(self: *Thread) void {
        self.visible = false;
        self.parent_msg = null;
        self.replies = &.{};
    }

    pub fn toggle(self: *Thread) void {
        if (self.visible) {
            self.hide();
        }
        // Cannot toggle on without data; use show() instead
    }

    /// Handle key input for the thread pane.
    pub fn handleInput(self: *Thread, key: Key) ?Action {
        if (!self.visible) return null;

        // j / down: scroll down
        if (key.matches('j', .{}) or key.matches(Key.down, .{})) {
            if (self.selected_idx + 1 < self.replies.len) {
                self.selected_idx += 1;
            }
            return .none;
        }
        // k / up: scroll up
        if (key.matches('k', .{}) or key.matches(Key.up, .{})) {
            if (self.selected_idx > 0) {
                self.selected_idx -= 1;
            }
            return .none;
        }
        // Escape: close thread
        if (key.matches(Key.escape, .{})) {
            self.hide();
            return .close;
        }
        return null;
    }

    fn formatSlackTs(ts: []const u8, buf: *[20]u8) []const u8 {
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

    /// Render the thread pane into the given window.
    pub fn render(self: *const Thread, win: Window) void {
        if (!self.visible) return;
        win.clear();

        // Border: draw a left separator
        var border_row: u16 = 0;
        while (border_row < win.height) : (border_row += 1) {
            win.writeCell(0, border_row, .{
                .char = .{ .grapheme = "\xe2\x94\x82", .width = 1 }, // "│"
                .style = .{ .dim = true },
            });
        }

        // Content area (offset by 2 for border + gap, width limited)
        const content = win.child(.{ .x_off = 2, .width = if (win.width > 2) win.width - 2 else 0 });

        // Header
        content.clear();
        _ = content.printSegment(.{ .text = "Thread", .style = .{ .bold = true, .fg = .{ .index = 4 } } }, .{});

        var row: u16 = 1;

        // Parent message
        if (self.parent_msg) |parent| {
            if (row >= content.height) return;
            var parent_time_buf: [20]u8 = undefined;
            const parent_time = formatSlackTs(parent.ts, &parent_time_buf);
            _ = content.print(&.{
                .{ .text = parent.user_name, .style = .{ .bold = true } },
                .{ .text = "  ", .style = .{} },
                .{ .text = parent_time, .style = .{ .dim = true } },
            }, .{ .row_offset = row });
            row += 1;

            if (row >= content.height) return;
            _ = content.printSegment(.{ .text = parent.text, .style = .{} }, .{ .row_offset = row, .wrap = .word });
            row += 2; // blank line after parent
        }

        // Separator line
        if (row < content.height) {
            _ = content.printSegment(.{
                .text = "────────────────────",
                .style = .{ .dim = true },
            }, .{ .row_offset = row });
            row += 1;
        }

        // Replies
        for (self.replies, 0..) |reply, i| {
            if (row >= content.height) break;

            const is_selected = i == self.selected_idx;
            const name_style: Cell.Style = if (is_selected)
                .{ .bold = true, .reverse = true }
            else
                .{ .bold = true };
            const text_style: Cell.Style = if (is_selected)
                .{ .reverse = true }
            else
                .{};

            var reply_time_buf: [20]u8 = undefined;
            const reply_time = formatSlackTs(reply.ts, &reply_time_buf);
            _ = content.print(&.{
                .{ .text = reply.user_name, .style = name_style },
                .{ .text = "  ", .style = text_style },
                .{ .text = reply_time, .style = .{ .dim = true } },
            }, .{ .row_offset = row });
            row += 1;

            if (row >= content.height) break;
            _ = content.printSegment(.{ .text = reply.text, .style = text_style }, .{ .row_offset = row, .wrap = .word });
            row += 1;
        }
    }
};
