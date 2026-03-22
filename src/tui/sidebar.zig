const std = @import("std");
const vaxis = @import("vaxis");
const Window = vaxis.Window;
const Key = vaxis.Key;
const Cell = vaxis.Cell;

/// Channel list sidebar widget with section headers.
pub const Sidebar = struct {
    channels: []const ChannelEntry = &.{},
    selected_idx: usize = 0,
    scroll_offset: usize = 0,

    pub const Section = enum {
        starred,
        external,
        channels,
        dms,
        apps,
    };

    pub const ChannelEntry = struct {
        id: []const u8,
        name: []const u8,
        is_private: bool,
        is_im: bool = false,
        section: Section = .channels,
        has_unread: bool,
    };

    pub const Action = union(enum) {
        select_channel: []const u8,
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
        if (key.matches('f', .{ .ctrl = true })) {
            const page: usize = if (self.channels.len > 10) 10 else self.channels.len;
            self.selected_idx = @min(self.selected_idx + page, self.channels.len -| 1);
            return .none;
        }
        if (key.matches('b', .{ .ctrl = true })) {
            const page: usize = 10;
            self.selected_idx = if (self.selected_idx > page) self.selected_idx - page else 0;
            return .none;
        }
        if (key.matches(Key.enter, .{})) {
            return .{ .select_channel = self.channels[self.selected_idx].id };
        }
        return null;
    }

    pub fn render(self: *Sidebar, win: Window) void {
        win.clear();

        if (self.channels.len == 0) {
            _ = win.printSegment(.{ .text = "No channels", .style = .{ .dim = true } }, .{});
            return;
        }

        // Build a flat list of rows: section headers + channel items
        // We need to map selected_idx (channel index) to a display row
        // and compute scroll based on that.

        // First pass: count total display rows and find the row of selected_idx
        var total_rows: usize = 0;
        var selected_row: usize = 0;
        var prev_section: ?Section = null;
        for (self.channels, 0..) |ch, i| {
            if (prev_section == null or prev_section.? != ch.section) {
                if (prev_section != null) total_rows += 1; // blank line between sections
                total_rows += 1; // section header
                prev_section = ch.section;
            }
            if (i == self.selected_idx) selected_row = total_rows;
            total_rows += 1;
        }

        // Adjust scroll
        var scroll = self.scroll_offset;
        const visible_rows: usize = win.height;
        if (visible_rows == 0) return;

        if (selected_row < scroll) {
            scroll = selected_row;
        } else if (selected_row >= scroll + visible_rows) {
            scroll = selected_row - visible_rows + 1;
        }
        self.scroll_offset = scroll;

        // Second pass: render
        var row: u16 = 0;
        var display_row: usize = 0;
        prev_section = null;
        for (self.channels, 0..) |ch, i| {
            if (prev_section == null or prev_section.? != ch.section) {
                // Blank separator (except before first section)
                if (prev_section != null) {
                    if (display_row >= scroll) {
                        row += 1;
                    }
                    display_row += 1;
                }
                // Section header
                if (display_row >= scroll and row < win.height) {
                    const header = sectionHeader(ch.section);
                    _ = win.printSegment(.{
                        .text = header,
                        .style = .{ .bold = true, .dim = true },
                    }, .{ .row_offset = row });
                    row += 1;
                }
                display_row += 1;
                prev_section = ch.section;
            }

            if (display_row >= scroll and row < win.height) {
                const is_selected = i == self.selected_idx;
                const style: Cell.Style = if (is_selected)
                    .{ .reverse = true }
                else
                    .{};

                const icon: []const u8 = if (ch.is_im) "  " else if (ch.is_private) "  " else "# ";
                const unread: []const u8 = if (ch.has_unread) "* " else "  ";

                _ = win.print(&.{
                    .{ .text = unread, .style = style },
                    .{ .text = icon, .style = style },
                    .{ .text = ch.name, .style = style },
                }, .{ .row_offset = row });
                row += 1;
            }
            display_row += 1;

            if (row >= win.height) break;
        }
    }

    fn sectionHeader(section: Section) []const u8 {
        return switch (section) {
            .starred => "Starred",
            .external => "External",
            .channels => "Channels",
            .dms => "DMs",
            .apps => "Apps",
        };
    }
};
