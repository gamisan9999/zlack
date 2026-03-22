const std = @import("std");
const unicode = std.unicode;
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
    file_mode: bool = false,

    pub const Action = union(enum) {
        send_message: []const u8,
        upload_file: []const u8, // file path
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
        // Escape: cancel file mode
        if (key.matches(Key.escape, .{})) {
            if (self.file_mode) {
                self.file_mode = false;
                self.buffer.clearRetainingCapacity();
                self.cursor_pos = 0;
            }
            return .none;
        }
        // Enter: send message or upload file
        if (key.matches(Key.enter, .{})) {
            if (self.buffer.items.len > 0) {
                if (self.file_mode) {
                    return .{ .upload_file = self.buffer.items };
                }
                return .{ .send_message = self.buffer.items };
            }
            return .none;
        }
        // Backspace: delete codepoint before cursor
        if (key.matches(Key.backspace, .{})) {
            if (self.cursor_pos > 0) {
                const cp_len = prevCodepointLen(self.buffer.items, self.cursor_pos);
                var i: usize = 0;
                while (i < cp_len) : (i += 1) {
                    _ = self.buffer.orderedRemove(self.cursor_pos - cp_len);
                }
                self.cursor_pos -= cp_len;
            }
            return .none;
        }
        // Left arrow: move cursor left by one codepoint
        if (key.matches(Key.left, .{})) {
            if (self.cursor_pos > 0) {
                self.cursor_pos -= prevCodepointLen(self.buffer.items, self.cursor_pos);
            }
            return .none;
        }
        // Right arrow: move cursor right by one codepoint
        if (key.matches(Key.right, .{})) {
            if (self.cursor_pos < self.buffer.items.len) {
                self.cursor_pos += nextCodepointLen(self.buffer.items, self.cursor_pos);
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
            const placeholder: []const u8 = if (self.file_mode)
                "> File path... (Esc to cancel)"
            else if (self.thread_mode)
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

        // Show cursor — calculate display width of text before cursor
        const display_w = displayWidth(self.buffer.items[0..self.cursor_pos]);
        const cursor_col: u16 = @intCast(@min(display_w + 2, win.width -| 1)); // +2 for "> " prefix
        win.showCursor(cursor_col, input_row);
    }

    pub fn clear(self: *Input) void {
        self.buffer.clearRetainingCapacity();
        self.cursor_pos = 0;
    }

    pub fn setThreadMode(self: *Input, is_thread: bool) void {
        self.thread_mode = is_thread;
    }

    /// Calculate display width of a UTF-8 string (ASCII=1, CJK fullwidth=2).
    fn displayWidth(s: []const u8) usize {
        var width: usize = 0;
        var view = unicode.Utf8View.initUnchecked(s);
        var iter = view.iterator();
        while (iter.nextCodepoint()) |cp| {
            width += codepointWidth(cp);
        }
        return width;
    }

    /// Get display width of a single codepoint.
    fn codepointWidth(cp: u21) usize {
        // CJK Unified Ideographs and common fullwidth ranges
        if (cp >= 0x1100 and cp <= 0x115F) return 2; // Hangul Jamo
        if (cp >= 0x2E80 and cp <= 0x303E) return 2; // CJK Radicals, Kangxi, CJK Symbols
        if (cp >= 0x3040 and cp <= 0x33BF) return 2; // Hiragana, Katakana, CJK Compatibility
        if (cp >= 0x3400 and cp <= 0x4DBF) return 2; // CJK Unified Extension A
        if (cp >= 0x4E00 and cp <= 0x9FFF) return 2; // CJK Unified Ideographs
        if (cp >= 0xA000 and cp <= 0xA4CF) return 2; // Yi
        if (cp >= 0xAC00 and cp <= 0xD7AF) return 2; // Hangul Syllables
        if (cp >= 0xF900 and cp <= 0xFAFF) return 2; // CJK Compatibility Ideographs
        if (cp >= 0xFE30 and cp <= 0xFE6F) return 2; // CJK Compatibility Forms
        if (cp >= 0xFF01 and cp <= 0xFF60) return 2; // Fullwidth Forms
        if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2; // Fullwidth Signs
        if (cp >= 0x20000 and cp <= 0x2FA1F) return 2; // CJK Extensions B-F, Compat Supplement
        return 1;
    }

    /// Get byte length of the previous codepoint (looking backwards from pos).
    fn prevCodepointLen(buf: []const u8, pos: usize) usize {
        if (pos == 0) return 0;
        var i: usize = 1;
        while (i < pos and i <= 4) : (i += 1) {
            // UTF-8 continuation bytes start with 10xxxxxx
            if (buf[pos - i] & 0xC0 != 0x80) return i;
        }
        return i;
    }

    /// Get byte length of the codepoint at pos.
    fn nextCodepointLen(buf: []const u8, pos: usize) usize {
        if (pos >= buf.len) return 0;
        const byte = buf[pos];
        if (byte < 0x80) return 1;
        if (byte & 0xE0 == 0xC0) return 2;
        if (byte & 0xF0 == 0xE0) return 3;
        if (byte & 0xF8 == 0xF0) return 4;
        return 1; // invalid, skip one byte
    }
};
