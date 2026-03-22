const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const Window = vaxis.Window;
const Key = vaxis.Key;
const Cell = vaxis.Cell;

pub const ModalType = enum { workspace_switch, channel_search };

/// Modal popup widget.
/// Centered floating rectangle with dimmed background.
/// Used for workspace switch (Ctrl+W) and channel search (Ctrl+N).
pub const Modal = struct {
    modal_type: ModalType,
    search_text: std.ArrayListUnmanaged(u8) = .{},
    items: []const ModalItem = &.{},
    filtered_indices: std.ArrayListUnmanaged(usize) = .{},
    selected_idx: usize = 0,

    pub const ModalItem = struct {
        id: []const u8,
        display_name: []const u8,
    };

    pub const Action = union(enum) {
        select: []const u8, // selected item id
        cancel,
        none,
    };

    pub fn init(modal_type: ModalType) Modal {
        return .{ .modal_type = modal_type };
    }

    pub fn deinit(self: *Modal, allocator: Allocator) void {
        self.search_text.deinit(allocator);
        self.filtered_indices.deinit(allocator);
    }

    pub fn setItems(self: *Modal, allocator: Allocator, items: []const ModalItem) void {
        self.items = items;
        self.selected_idx = 0;
        self.refilter(allocator);
    }

    fn refilter(self: *Modal, allocator: Allocator) void {
        self.filtered_indices.clearRetainingCapacity();
        const query = self.search_text.items;
        for (self.items, 0..) |item, i| {
            if (query.len == 0 or containsSubstring(item.display_name, query)) {
                self.filtered_indices.append(allocator, i) catch continue;
            }
        }
        if (self.selected_idx >= self.filtered_indices.items.len) {
            self.selected_idx = if (self.filtered_indices.items.len > 0)
                self.filtered_indices.items.len - 1
            else
                0;
        }
    }

    /// Handle key input for the modal.
    pub fn handleInput(self: *Modal, allocator: Allocator, key: Key) ?Action {
        // Escape: cancel
        if (key.matches(Key.escape, .{})) {
            return .cancel;
        }
        // Enter: select current item
        if (key.matches(Key.enter, .{})) {
            if (self.filtered_indices.items.len > 0 and self.selected_idx < self.filtered_indices.items.len) {
                const idx = self.filtered_indices.items[self.selected_idx];
                return .{ .select = self.items[idx].id };
            }
            return .none;
        }
        // Up / Ctrl+P: move selection up
        if (key.matches(Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
            if (self.selected_idx > 0) {
                self.selected_idx -= 1;
            }
            return .none;
        }
        // Down / Ctrl+N: move selection down
        if (key.matches(Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
            if (self.selected_idx + 1 < self.filtered_indices.items.len) {
                self.selected_idx += 1;
            }
            return .none;
        }
        // Backspace: delete character from search
        if (key.matches(Key.backspace, .{})) {
            if (self.search_text.items.len > 0) {
                _ = self.search_text.pop();
                self.refilter(allocator);
            }
            return .none;
        }
        // Text input for search
        if (key.text) |text| {
            self.search_text.appendSlice(allocator, text) catch return .none;
            self.refilter(allocator);
            return .none;
        }
        return null;
    }

    /// Render the modal as a centered floating rectangle.
    pub fn render(self: *const Modal, win: Window) void {
        // Dim background
        win.fill(.{ .style = .{ .dim = true } });

        // Calculate modal dimensions (centered, 40x15 or smaller)
        const modal_w: u16 = @min(40, win.width -| 4);
        const modal_h: u16 = @min(15, win.height -| 4);
        if (modal_w < 10 or modal_h < 5) return;

        const x_off: i17 = @intCast((win.width - modal_w) / 2);
        const y_off: i17 = @intCast((win.height - modal_h) / 2);

        const modal_win = win.child(.{
            .x_off = x_off,
            .y_off = y_off,
            .width = modal_w,
            .height = modal_h,
            .border = .{ .where = .all, .style = .{ .fg = .{ .index = 4 } } },
        });

        modal_win.clear();

        // Title
        const title: []const u8 = switch (self.modal_type) {
            .workspace_switch => "Switch Workspace",
            .channel_search => "Search Channels",
        };
        _ = modal_win.printSegment(.{ .text = title, .style = .{ .bold = true } }, .{});

        // Search input (for channel_search mode)
        if (self.modal_type == .channel_search) {
            if (modal_win.height > 1) {
                _ = modal_win.print(&.{
                    .{ .text = "> ", .style = .{ .bold = true } },
                    .{ .text = if (self.search_text.items.len > 0) self.search_text.items else "", .style = .{} },
                }, .{ .row_offset = 1 });
            }
        }

        // Item list
        const list_start: u16 = if (self.modal_type == .channel_search) 3 else 2;
        for (self.filtered_indices.items, 0..) |item_idx, i| {
            const row = list_start + @as(u16, @intCast(i));
            if (row >= modal_win.height) break;

            const is_selected = i == self.selected_idx;
            const style: Cell.Style = if (is_selected) .{ .reverse = true } else .{};

            _ = modal_win.printSegment(.{
                .text = self.items[item_idx].display_name,
                .style = style,
            }, .{ .row_offset = row });
        }
    }

    /// Simple substring search (case-sensitive).
    fn containsSubstring(haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;
        if (needle.len == 0) return true;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) return true;
        }
        return false;
    }
};
