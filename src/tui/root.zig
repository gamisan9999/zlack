const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const Window = vaxis.Window;
const Key = vaxis.Key;
const Cell = vaxis.Cell;

const Sidebar = @import("sidebar.zig").Sidebar;
const Messages = @import("messages.zig").Messages;
const Thread = @import("thread.zig").Thread;
const Input = @import("input.zig").Input;
const Modal = @import("modal.zig").Modal;
const ModalType = @import("modal.zig").ModalType;

pub const Focus = enum { sidebar, messages, thread, input };

/// Root layout widget.
/// Composes sidebar, messages, thread, and input into a 3-pane TUI layout.
///
/// Layout:
/// - Header (1 row): workspace name + help hint
/// - Sidebar (width 20, left)
/// - Messages pane (flex, center)
/// - Thread pane (width 30, right, toggleable with Ctrl+T)
/// - Input bar (2 rows, bottom)
pub const Root = struct {
    sidebar: Sidebar = Sidebar.init(),
    messages: Messages = Messages.init(),
    thread: Thread = Thread.init(),
    input: Input = Input.init(),
    focus: Focus = .sidebar,
    workspace_name: []const u8 = "zlack",
    show_modal: ?ModalType = null,
    modal: ?Modal = null,

    pub const AppAction = union(enum) {
        select_channel: []const u8,
        send_message: struct { text: []const u8, thread_ts: ?[]const u8 },
        send_also_channel: struct { text: []const u8, thread_ts: []const u8 },
        upload_file: []const u8,
        open_thread: struct { channel_id: []const u8, thread_ts: []const u8 },
        toggle_thread,
        quit,
        switch_workspace,
        search_channel,
    };

    pub fn init() Root {
        return .{};
    }

    pub fn deinit(self: *Root, allocator: Allocator) void {
        self.input.deinit(allocator);
        if (self.modal) |*m| {
            m.deinit(allocator);
        }
    }

    /// Handle key input at the root level. Dispatches to focused widget or handles global keys.
    pub fn handleInput(self: *Root, allocator: Allocator, key: Key) ?AppAction {
        // Modal takes priority
        if (self.modal) |*m| {
            if (m.handleInput(allocator, key)) |action| {
                switch (action) {
                    .select => |id| {
                        const modal_type = m.modal_type;
                        m.deinit(allocator);
                        self.modal = null;
                        self.show_modal = null;
                        return switch (modal_type) {
                            .workspace_switch => .switch_workspace,
                            .channel_search => blk: {
                                self.focus = .input;
                                break :blk .{ .select_channel = id };
                            },
                        };
                    },
                    .cancel => {
                        m.deinit(allocator);
                        self.modal = null;
                        self.show_modal = null;
                        return null;
                    },
                    .none => return null,
                }
            }
            return null;
        }

        // Global keybindings
        // Ctrl+C / Ctrl+Q: quit
        if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{ .ctrl = true })) {
            return .quit;
        }
        // Tab: cycle focus forward
        if (key.matches(Key.tab, .{})) {
            self.cycleFocus(true);
            return null;
        }
        // Shift+Tab: cycle focus backward
        if (key.matches(Key.tab, .{ .shift = true })) {
            self.cycleFocus(false);
            return null;
        }
        // Ctrl+T: toggle thread pane
        if (key.matches('t', .{ .ctrl = true })) {
            self.thread.toggle();
            if (!self.thread.visible and self.focus == .thread) {
                self.focus = .messages;
            }
            return .toggle_thread;
        }
        // Ctrl+W: workspace switch modal
        if (key.matches('w', .{ .ctrl = true })) {
            self.show_modal = .workspace_switch;
            self.modal = Modal.init(.workspace_switch);
            return .switch_workspace;
        }
        // Ctrl+K: channel search modal (same as Slack desktop)
        if (key.matches('k', .{ .ctrl = true })) {
            self.show_modal = .channel_search;
            self.modal = Modal.init(.channel_search);
            return .search_channel;
        }
        // Ctrl+U: file upload mode
        if (key.matches('u', .{ .ctrl = true })) {
            self.input.file_mode = true;
            self.input.clear();
            self.focus = .input;
            return null;
        }

        // Dispatch to focused widget
        switch (self.focus) {
            .sidebar => {
                if (self.sidebar.handleInput(key)) |action| {
                    switch (action) {
                        .select_channel => |id| {
                            self.focus = .input;
                            return .{ .select_channel = id };
                        },
                        .none => return null,
                    }
                }
            },
            .messages => {
                if (self.messages.handleInput(key)) |action| {
                    switch (action) {
                        .open_thread => |t| return .{ .open_thread = .{
                            .channel_id = t.channel_id,
                            .thread_ts = t.thread_ts,
                        } },
                        .none => return null,
                    }
                }
            },
            .thread => {
                if (self.thread.handleInput(key)) |action| {
                    switch (action) {
                        .close => {
                            self.focus = .messages;
                            return null;
                        },
                        .none => return null,
                    }
                }
            },
            .input => {
                if (self.input.handleInput(allocator, key)) |action| {
                    switch (action) {
                        .upload_file => |path| {
                            return .{ .upload_file = path };
                        },
                        .send_message => |text| {
                            const thread_ts: ?[]const u8 = if (self.input.thread_mode)
                                if (self.thread.parent_msg) |p| p.ts else null
                            else
                                null;
                            return .{ .send_message = .{ .text = text, .thread_ts = thread_ts } };
                        },
                        .send_message_also_channel => |text| {
                            if (self.thread.parent_msg) |p| {
                                return .{ .send_also_channel = .{ .text = text, .thread_ts = p.ts } };
                            }
                            return null;
                        },
                        .none => return null,
                    }
                }
            },
        }
        return null;
    }

    fn cycleFocus(self: *Root, forward: bool) void {
        const order = [_]Focus{ .sidebar, .messages, .thread, .input };
        var current_idx: usize = 0;
        for (order, 0..) |f, i| {
            if (f == self.focus) {
                current_idx = i;
                break;
            }
        }
        // Cycle, skipping thread if not visible
        var attempts: usize = 0;
        while (attempts < order.len) : (attempts += 1) {
            if (forward) {
                current_idx = (current_idx + 1) % order.len;
            } else {
                current_idx = if (current_idx == 0) order.len - 1 else current_idx - 1;
            }
            const candidate = order[current_idx];
            if (candidate == .thread and !self.thread.visible) continue;
            self.focus = candidate;
            break;
        }
    }

    /// Render the entire TUI layout.
    pub fn render(self: *Root, win: Window) void {
        win.clear();

        const total_h = win.height;
        const total_w = win.width;
        if (total_h < 5 or total_w < 25) return;

        // Header (1 row)
        const header_win = win.child(.{ .height = 1 });
        _ = header_win.print(&.{
            .{ .text = " ", .style = .{} },
            .{ .text = self.workspace_name, .style = .{ .bold = true } },
            .{ .text = "  |  Ctrl+? help", .style = .{ .dim = true } },
        }, .{});

        // Input bar (2 rows at bottom)
        const input_h: u16 = 2;
        const input_win = win.child(.{
            .y_off = @intCast(total_h -| input_h),
            .height = input_h,
        });
        self.input.render(input_win);

        // Content area (between header and input)
        const content_h = total_h -| 1 -| input_h;
        if (content_h == 0) return;

        // Sidebar (fixed width 20)
        const sidebar_w: u16 = @min(20, total_w / 3);
        const sidebar_win = win.child(.{
            .x_off = 0,
            .y_off = 1,
            .width = sidebar_w,
            .height = content_h,
        });

        // Sidebar border (right edge) — highlighted when sidebar is focused
        const border_style: Cell.Style = if (self.focus == .sidebar)
            .{ .fg = .{ .index = 4 }, .bold = true } // blue when focused
        else
            .{ .dim = true };
        var sr: u16 = 0;
        while (sr < content_h) : (sr += 1) {
            win.writeCell(sidebar_w, sr + 1, .{
                .char = .{ .grapheme = "\xe2\x94\x82", .width = 1 }, // "│"
                .style = border_style,
            });
        }

        self.sidebar.render(sidebar_win);

        // Thread pane (width 30, right side, if visible)
        const thread_w: u16 = if (self.thread.visible) @min(30, (total_w -| sidebar_w -| 1) / 2) else 0;

        // Messages pane (flex, fills remaining space)
        const msg_x: u16 = sidebar_w + 1;
        const msg_w: u16 = total_w -| msg_x -| thread_w;
        const msg_win = win.child(.{
            .x_off = @intCast(msg_x),
            .y_off = 1,
            .width = msg_w,
            .height = content_h,
        });
        self.messages.render(msg_win);

        // Thread pane
        if (self.thread.visible and thread_w > 0) {
            const thread_x: u16 = total_w -| thread_w;
            const thread_win = win.child(.{
                .x_off = @intCast(thread_x),
                .y_off = 1,
                .width = thread_w,
                .height = content_h,
            });
            self.thread.render(thread_win);
        }

        // Focus indicator in header
        const focus_label: []const u8 = switch (self.focus) {
            .sidebar => "[Channels]",
            .messages => "[Messages]",
            .thread => "[Thread]",
            .input => "[Input]",
        };
        _ = header_win.printSegment(.{
            .text = focus_label,
            .style = .{ .fg = .{ .index = 4 }, .bold = true },
        }, .{ .col_offset = @intCast(@min(total_w -| 12, self.workspace_name.len + 20)) });

        // Modal overlay (rendered last, on top of everything)
        if (self.modal) |*m| {
            m.render(win);
        }
    }
};
