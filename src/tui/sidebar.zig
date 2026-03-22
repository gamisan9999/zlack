const std = @import("std");
const vaxis = @import("vaxis");
const Window = vaxis.Window;
const Key = vaxis.Key;
const Cell = vaxis.Cell;

/// Channel list sidebar widget.
/// Renders public/private channels with unread indicators and selection cursor.
pub const Sidebar = struct {
    channels: []const ChannelEntry = &.{},
    selected_idx: usize = 0,
    scroll_offset: usize = 0,

    pub const ChannelEntry = struct {
        id: []const u8,
        name: []const u8,
        is_private: bool,
        has_unread: bool,
    };

    pub const Action = union(enum) {
        select_channel: []const u8, // channel_id
        none,
    };

    pub fn init() Sidebar {
        return .{};
    }

    pub fn setChannels(self: *Sidebar, channels: []const ChannelEntry) void {
        self.channels = channels;
        if (self.selected_idx >= channels.len) {
            self.selected_idx = if (channels.len > 0) channels.len - 1 else 0;
        }
    }

    /// Handle key input. Returns an action if a channel was selected.
    pub fn handleInput(self: *Sidebar, key: Key) ?Action {
        if (self.channels.len == 0) return .none;

        if (key.matches('j', .{}) or key.matches(Key.down, .{})) {
            if (self.selected_idx + 1 < self.channels.len) {
                self.selected_idx += 1;
            }
            return .none;
        }
        if (key.matches('k', .{}) or key.matches(Key.up, .{})) {
            if (self.selected_idx > 0) {
                self.selected_idx -= 1;
            }
            return .none;
        }
        if (key.matches(Key.enter, .{})) {
            return .{ .select_channel = self.channels[self.selected_idx].id };
        }
        return null;
    }

    /// Render the sidebar into the given window.
    pub fn render(self: *const Sidebar, win: Window) void {
        // Clear the window
        win.clear();

        // Header
        _ = win.printSegment(.{ .text = "Channels", .style = .{ .bold = true } }, .{});

        if (self.channels.len == 0) return;

        // Adjust scroll_offset (use a local copy for rendering calculation)
        var scroll = self.scroll_offset;
        const visible_rows: usize = if (win.height > 2) win.height - 2 else 0;
        if (visible_rows == 0) return;

        if (self.selected_idx < scroll) {
            scroll = self.selected_idx;
        } else if (self.selected_idx >= scroll + visible_rows) {
            scroll = self.selected_idx - visible_rows + 1;
        }

        var row: u16 = 2; // start after header + blank line
        for (self.channels[scroll..], 0..) |ch, i| {
            if (row >= win.height) break;

            const is_selected = (scroll + i) == self.selected_idx;
            const style: Cell.Style = if (is_selected)
                .{ .reverse = true }
            else
                .{};

            // Build prefix: unread marker + channel icon
            const icon: []const u8 = if (ch.is_private) "  " else "# ";
            const unread: []const u8 = if (ch.has_unread) "* " else "  ";

            _ = win.print(&.{
                .{ .text = unread, .style = style },
                .{ .text = icon, .style = style },
                .{ .text = ch.name, .style = style },
            }, .{ .row_offset = row });

            row += 1;
        }
    }
};
