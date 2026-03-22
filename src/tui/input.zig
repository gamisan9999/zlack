const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const Window = vaxis.Window;
const Key = vaxis.Key;
const Cell = vaxis.Cell;

/// Message input bar widget.
/// Handles text input with cursor movement, backspace, and Enter to send.
pub const Input = struct {
    buffer: std.ArrayListUnmanaged(u8) = .{},
    cursor_pos: usize = 0,
    thread_mode: bool = false,

    pub const Action = union(enum) {
        send_message: []const u8, // text content (slice of buffer)
        none,
    };

    pub fn init() Input {
        return .{};
    }

    pub fn deinit(self: *Input, allocator: Allocator) void {
        self.buffer.deinit(allocator);
    }

    /// Handle key input. Returns an action if a message should be sent.
    pub fn handleInput(self: *Input, allocator: Allocator, key: Key) ?Action {
        // Enter: send message
        if (key.matches(Key.enter, .{})) {
            if (self.buffer.items.len > 0) {
                return .{ .send_message = self.buffer.items };
            }
            return .none;
        }
        // Backspace: delete character before cursor
        if (key.matches(Key.backspace, .{})) {
            if (self.cursor_pos > 0) {
                _ = self.buffer.orderedRemove(self.cursor_pos - 1);
                self.cursor_pos -= 1;
            }
            return .none;
        }
        // Left arrow: move cursor left
        if (key.matches(Key.left, .{})) {
            if (self.cursor_pos > 0) {
                self.cursor_pos -= 1;
            }
            return .none;
        }
        // Right arrow: move cursor right
        if (key.matches(Key.right, .{})) {
            if (self.cursor_pos < self.buffer.items.len) {
                self.cursor_pos += 1;
            }
            return .none;
        }
        // Ctrl+A: move to beginning
        if (key.matches('a', .{ .ctrl = true })) {
            self.cursor_pos = 0;
            return .none;
        }
        // Ctrl+E: move to end
        if (key.matches('e', .{ .ctrl = true })) {
            self.cursor_pos = self.buffer.items.len;
            return .none;
        }
        // Ctrl+U: clear line
        if (key.matches('u', .{ .ctrl = true })) {
            self.buffer.clearRetainingCapacity();
            self.cursor_pos = 0;
            return .none;
        }
        // Regular text input
        if (key.text) |text| {
            self.buffer.insertSlice(allocator, self.cursor_pos, text) catch return .none;
            self.cursor_pos += text.len;
            return .none;
        }
        return null;
    }

    /// Render the input bar into the given window.
    pub fn render(self: *const Input, win: Window) void {
        win.clear();

        // Draw top border
        var col: u16 = 0;
        while (col < win.width) : (col += 1) {
            win.writeCell(col, 0, .{
                .char = .{ .grapheme = "\xe2\x94\x80", .width = 1 }, // "─"
                .style = .{ .dim = true },
            });
        }

        const input_row: u16 = 1;

        if (self.buffer.items.len == 0) {
            // Show placeholder
            const placeholder: []const u8 = if (self.thread_mode)
                "> Reply in thread..."
            else
                "> Type a message...";
            _ = win.printSegment(.{
                .text = placeholder,
                .style = .{ .dim = true },
            }, .{ .row_offset = input_row });
        } else {
            // Show buffer content
            _ = win.print(&.{
                .{ .text = "> ", .style = .{ .bold = true } },
                .{ .text = self.buffer.items, .style = .{} },
            }, .{ .row_offset = input_row });
        }

        // Show cursor
        const cursor_col: u16 = @intCast(@min(self.cursor_pos + 2, win.width -| 1)); // +2 for "> " prefix
        win.showCursor(cursor_col, input_row);
    }

    pub fn clear(self: *Input) void {
        self.buffer.clearRetainingCapacity();
        self.cursor_pos = 0;
    }

    pub fn setThreadMode(self: *Input, is_thread: bool) void {
        self.thread_mode = is_thread;
    }
};
